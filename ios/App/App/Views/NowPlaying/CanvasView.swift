import SwiftUI
import AVKit

/// Full-screen looping video canvas (like Spotify canvas / Apple Music MV).
/// Muted, loops, syncs play/pause with NowPlayingState.isPlaying.
struct CanvasView: View {
    let url: URL

    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        CanvasPlayerView(player: player)
            .ignoresSafeArea()
            .onAppear { setupPlayer() }
            .onDisappear { teardownPlayer() }
            .onChange(of: NowPlayingState.shared.isPlaying) { _, playing in
                syncPlayback(playing)
            }
            .onChange(of: url) { _, newUrl in
                replaceItem(with: newUrl)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                // AVPlayer pauses video rendering when the app enters background.
                // On return, resume if music is still playing.
                if NowPlayingState.shared.isPlaying {
                    player?.play()
                }
            }
    }

    private func setupPlayer() {
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.allowsExternalPlayback = false
        player = p

        addLoopObserver(for: item, player: p)

        if NowPlayingState.shared.isPlaying { p.play() }
    }

    private func teardownPlayer() {
        removeLoopObserver()
        player?.pause()
        player = nil
    }

    private func syncPlayback(_ playing: Bool) {
        guard let player else { return }
        if playing {
            player.play()
        } else {
            player.pause()
        }
    }

    private func replaceItem(with newUrl: URL) {
        let item = AVPlayerItem(url: newUrl)
        player?.replaceCurrentItem(with: item)

        removeLoopObserver()
        addLoopObserver(for: item, player: player)

        if NowPlayingState.shared.isPlaying { player?.play() }
    }

    private func addLoopObserver(for item: AVPlayerItem, player: AVPlayer?) {
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
    }

    private func removeLoopObserver() {
        if let obs = loopObserver {
            NotificationCenter.default.removeObserver(obs)
            loopObserver = nil
        }
    }
}

// MARK: - UIKit AVPlayerLayer wrapper

/// UIViewRepresentable wrapping AVPlayerLayer for true full-screen video
/// (SwiftUI's VideoPlayer adds transport controls we don't want).
struct CanvasPlayerView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerUIView {
        PlayerUIView()
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = .resizeAspectFill
    }

    class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
