import SwiftUI

/// Barra de progreso estilo Apple Music.
/// Track blanco fino, knob circular, drag-to-seek.
struct ProgressBarView: View {
    private var state = NowPlayingState.shared

    @State private var isDragging = false
    @State private var dragFraction: CGFloat = 0

    var body: some View {
        VStack(spacing: 8) {
            // Track
            GeometryReader { geo in
                let fraction = isDragging ? dragFraction : smoothFraction

                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(height: isDragging ? 8 : 6)

                    // Filled portion
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: max(0, geo.size.width * fraction), height: isDragging ? 8 : 6)

                    // Knob (only visible when dragging)
                    if isDragging {
                        Circle()
                            .fill(.white)
                            .frame(width: 16, height: 16)
                            .offset(x: max(0, min(geo.size.width * fraction - 8, geo.size.width - 16)))
                    }
                }
                .frame(height: 16, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            dragFraction = min(max(value.location.x / geo.size.width, 0), 1)
                        }
                        .onEnded { value in
                            let seekFraction = min(max(value.location.x / geo.size.width, 0), 1)
                            let seekTime = seekFraction * state.duration
                            isDragging = false

                            PlayerService.shared.seekTo(seekTime)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                )
                .animation(Anim.micro, value: isDragging)
            }
            .frame(height: 16)

            // Time labels + AutoMix indicator
            HStack {
                Text(formatTime(displayedTime))
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))

                Spacer()

                if state.isCrossfading {
                    WaveText("AutoMix", font: .caption2.weight(.bold), color: .white)
                        .transition(.opacity.combined(with: .scale))
                }

                Spacer()

                Text("-" + formatTime(max(0, state.duration - displayedTime)))
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .animation(Anim.content, value: state.isCrossfading)
        }
    }

    // MARK: - Helpers

    /// Progress fraction for the bar. Reads directly from NowPlayingState (updated at 4Hz
    /// by AudioEngineManager). No local @State interpolation needed — the native timer
    /// already provides smooth updates, and using @State caused time resets when the
    /// viewer was destroyed/recreated (inside `if viewerIsOpen`).
    private var smoothFraction: CGFloat {
        guard state.duration > 0 else { return 0 }
        return min(max(CGFloat(state.progress / state.duration), 0), 1)
    }

    private var displayedTime: Double {
        if isDragging {
            return Double(dragFraction) * state.duration
        }
        return min(max(state.progress, 0), state.duration)
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Wave Text Animation

/// Displays text with a CSS-like wave animation where each character oscillates
/// in opacity with a staggered delay, creating a loading/shimmer effect.
/// Uses TimelineView for continuous per-frame updates.
struct WaveText: View {
    let text: String
    let font: Font
    let color: Color
    let cycleDuration: Double

    @State private var startDate: Date?

    init(_ text: String, font: Font = .caption2.weight(.bold), color: Color = .white,
         cycleDuration: Double = 2.8) {
        self.text = text
        self.font = font
        self.color = color
        self.cycleDuration = cycleDuration
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = startDate.map { timeline.date.timeIntervalSince($0) } ?? 0
            let phase = elapsed / cycleDuration

            HStack(spacing: 0) {
                ForEach(Array(text.enumerated()), id: \.offset) { index, char in
                    let delay = Double(index) / Double(max(1, text.count))
                    let wave = sin((phase - delay) * 2.0 * .pi)
                    let opacity = 0.5 + 0.5 * ((wave + 1.0) / 2.0)

                    Text(String(char))
                        .font(font)
                        .foregroundStyle(color.opacity(opacity))
                }
            }
        }
        .onAppear { startDate = .now }
    }
}
