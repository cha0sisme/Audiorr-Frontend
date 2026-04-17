import SwiftUI

/// Playback controls — Apple Music style.
/// White icons, no color background. Optionally glass over canvas.
struct PlaybackControlsView: View {
    private var state = NowPlayingState.shared
    var glassStyle: Bool

    init(glassStyle: Bool = false) {
        self.glassStyle = glassStyle
    }

    var body: some View {
        HStack(spacing: 52) {
            // Previous
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                PlayerService.shared.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }

            // Play / Pause
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                PlayerService.shared.togglePlayPause()
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }

            // Next
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                PlayerService.shared.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
}
