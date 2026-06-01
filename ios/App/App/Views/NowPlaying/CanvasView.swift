import SwiftUI
import AVKit

/// Full-screen looping video canvas (like Spotify canvas / Apple Music MV).
/// Muted, loops.
///
/// Por defecto **sincroniza play/pause con `NowPlayingState.isPlaying`**:
/// el vídeo es "ambiente de la canción" y se pausa cuando se pausa el audio
/// (uso en el NowPlaying viewer fullscreen).
///
/// Con `autoplay = true` el vídeo arranca y se mantiene siempre que la
/// view esté en pantalla, **sin** mirar `isPlaying`. Apple Music usa este
/// modo en el album/playlist page: el motion es decorativo del header, no
/// está atado al estado de reproducción del audio.
struct CanvasView: View {
    let url: URL
    let autoplay: Bool
    /// Desplaza visualmente el centro del vídeo hacia abajo dentro del
    /// frame, sin dejar gap. Implementado extendiendo el AVPlayerLayer
    /// hacia abajo más allá del bounds y recortando con `masksToBounds`.
    /// El centro del vídeo baja `videoOffsetY / 2` puntos respecto al
    /// centro del frame. Default cero = comportamiento histórico (centrado).
    /// Apple Music usa este desplazamiento en el album page para que la
    /// parte clave de la cover quede mejor compuesta con el título debajo.
    let videoOffsetY: CGFloat

    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?

    init(url: URL, autoplay: Bool = false, videoOffsetY: CGFloat = 0) {
        self.url = url
        self.autoplay = autoplay
        self.videoOffsetY = videoOffsetY
    }

    var body: some View {
        CanvasPlayerView(player: player, videoOffsetY: videoOffsetY)
            .ignoresSafeArea()
            .onAppear { setupPlayer() }
            .onDisappear { teardownPlayer() }
            .onChange(of: NowPlayingState.shared.isPlaying) { _, playing in
                guard !autoplay else { return }
                syncPlayback(playing)
            }
            .onChange(of: url) { _, newUrl in
                replaceItem(with: newUrl)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                // AVPlayer pauses video rendering when the app enters background.
                // On return, resume if we should still be playing.
                if shouldBePlaying {
                    player?.play()
                }
            }
    }

    /// Único punto de verdad para decidir si el vídeo debe estar reproduciéndose.
    /// En modo autoplay, siempre. En modo sync, sigue al estado del audio.
    private var shouldBePlaying: Bool {
        autoplay || NowPlayingState.shared.isPlaying
    }

    private func setupPlayer() {
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.allowsExternalPlayback = false
        player = p

        addLoopObserver(for: item, player: p)

        if shouldBePlaying { p.play() }
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

        if shouldBePlaying { player?.play() }
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
///
/// Usa un sublayer manual (no `layerClass = AVPlayerLayer`) para poder
/// ajustar el `frame` del player layer independientemente del bounds del
/// UIView. Con `videoOffsetY > 0`, el player layer se extiende hacia
/// abajo más allá del bounds visible; `masksToBounds = true` recorta el
/// excedente. El resultado: el centro del vídeo baja `videoOffsetY / 2`
/// puntos respecto al centro del frame, sin dejar gap visible arriba.
struct CanvasPlayerView: UIViewRepresentable {
    let player: AVPlayer?
    let videoOffsetY: CGFloat

    func makeUIView(context: Context) -> PlayerUIView {
        PlayerUIView()
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.setPlayer(player)
        uiView.videoOffsetY = videoOffsetY
    }

    class PlayerUIView: UIView {
        private let avPlayerLayer = AVPlayerLayer()

        var videoOffsetY: CGFloat = 0 {
            didSet {
                guard oldValue != videoOffsetY else { return }
                setNeedsLayout()
            }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            commonInit()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            commonInit()
        }

        private func commonInit() {
            layer.masksToBounds = true
            avPlayerLayer.videoGravity = .resizeAspectFill
            layer.addSublayer(avPlayerLayer)
        }

        func setPlayer(_ p: AVPlayer?) {
            avPlayerLayer.player = p
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Sin offset: layer cubre el bounds exactamente (comportamiento
            // histórico). Con offset: layer se extiende hacia abajo;
            // `masksToBounds` recorta lo que sobresale. El centro del
            // contenido del vídeo baja `videoOffsetY / 2`.
            avPlayerLayer.frame = CGRect(
                x: 0,
                y: 0,
                width: bounds.width,
                height: bounds.height + videoOffsetY
            )
        }
    }
}
