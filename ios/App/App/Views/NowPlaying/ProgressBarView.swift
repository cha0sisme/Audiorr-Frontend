import SwiftUI

/// Barra de progreso estilo Apple Music.
/// Track blanco fino, knob circular, drag-to-seek.
struct ProgressBarView: View {
    private var state = NowPlayingState.shared

    @State private var isDragging = false
    @State private var dragFraction: CGFloat = 0

    // Local interpolation: smooths the 2s sync jumps from React
    @State private var interpolatedProgress: Double = 0
    @State private var lastSyncTime: Date = .now
    @State private var lastSyncProgress: Double = 0
    @State private var interpolationTimer: Timer?

    init() {}

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

                            // Update local interpolation to the seek position
                            interpolatedProgress = seekTime
                            lastSyncProgress = seekTime
                            lastSyncTime = .now
                        }
                )
                .animation(.easeInOut(duration: 0.15), value: isDragging)
            }
            .frame(height: 16)

            // Time labels + AutoMix indicator
            HStack {
                Text(formatTime(displayedTime))
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))

                Spacer()

                if state.isCrossfading {
                    Text("AutoMix")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.cyan)
                        .transition(.opacity.combined(with: .scale))
                }

                Spacer()

                Text("-" + formatTime(max(0, state.duration - displayedTime)))
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .animation(.easeInOut(duration: 0.3), value: state.isCrossfading)
        }
        .onAppear { startInterpolation() }
        .onDisappear { stopInterpolation() }
        .onChange(of: state.progress) { _, newProgress in
            // React synced a new progress value — reset interpolation anchor
            lastSyncProgress = newProgress
            lastSyncTime = .now
            interpolatedProgress = newProgress
        }
    }

    // MARK: - Interpolation

    /// Smoothly advance progress between 2s React syncs
    private func startInterpolation() {
        interpolatedProgress = state.progress
        lastSyncProgress = state.progress
        lastSyncTime = .now

        interpolationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in
                guard state.isPlaying, !isDragging else { return }
                let elapsed = Date.now.timeIntervalSince(lastSyncTime)
                interpolatedProgress = min(lastSyncProgress + elapsed, state.duration)
            }
        }
    }

    private func stopInterpolation() {
        interpolationTimer?.invalidate()
        interpolationTimer = nil
    }

    // MARK: - Helpers

    private var smoothFraction: CGFloat {
        state.duration > 0 ? CGFloat(interpolatedProgress / state.duration) : 0
    }

    private var displayedTime: Double {
        if isDragging {
            return Double(dragFraction) * state.duration
        }
        return interpolatedProgress
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
