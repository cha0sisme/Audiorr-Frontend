import SwiftUI

/// Synced lyrics overlay for the Now Playing Viewer (Apple Music style).
/// Auto-scrolls to the active line, tap a line to seek.
/// White for active line, faded white for the rest.
struct LyricsView: View {
    private var state = NowPlayingState.shared
    let lyrics: LyricsService.LyricsResult

    init(lyrics: LyricsService.LyricsResult) {
        self.lyrics = lyrics
    }

    @State private var userIsScrolling = false
    @State private var scrollResumeTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    Spacer()
                        .frame(height: 40)

                    ForEach(lyrics.lines) { line in
                        lyricLineView(line)
                            .id(line.id)
                            .onTapGesture {
                                if lyrics.isSynced && line.time >= 0 {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    PlayerService.shared.seekTo(line.time)
                                }
                            }
                    }

                    Spacer()
                        .frame(height: 200)
                }
                .padding(.horizontal, 8)
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear,  location: 0),
                        .init(color: .black,  location: 0.08),
                        .init(color: .black,  location: 0.88),
                        .init(color: .clear,  location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { _ in
                        userIsScrolling = true
                        scrollResumeTask?.cancel()
                    }
                    .onEnded { _ in
                        scrollResumeTask?.cancel()
                        scrollResumeTask = Task {
                            try? await Task.sleep(for: .seconds(3))
                            if !Task.isCancelled {
                                userIsScrolling = false
                            }
                        }
                    }
            )
            .onChange(of: activeLineId) { _, newId in
                guard !userIsScrolling, let id = newId else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Active Line

    private var activeLineId: Int? {
        guard lyrics.isSynced else { return nil }
        let progress = state.progress

        var best: Int?
        for line in lyrics.lines {
            if line.time <= progress {
                best = line.id
            } else {
                break
            }
        }
        return best
    }

    // MARK: - Line View

    private func lyricLineView(_ line: LyricsService.LyricLine) -> some View {
        let isActive = (line.id == activeLineId)
        let distance = distanceFromActive(line)
        let opacity = opacityForDistance(distance)

        return Text(line.text)
            .font(isActive ? .title2.weight(.bold) : .title3.weight(.semibold))
            .foregroundStyle(.white.opacity(isActive ? 1.0 : opacity))
            .scaleEffect(isActive ? 1.0 : 0.95, anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.3), value: isActive)
            .contentShape(Rectangle())
    }

    private func distanceFromActive(_ line: LyricsService.LyricLine) -> Int {
        guard let activeId = activeLineId else { return 0 }
        return abs(line.id - activeId)
    }

    private func opacityForDistance(_ distance: Int) -> Double {
        switch distance {
        case 0:  return 1.0
        case 1:  return 0.48
        case 2:  return 0.22
        case 3:  return 0.10
        default: return 0.04
        }
    }
}
