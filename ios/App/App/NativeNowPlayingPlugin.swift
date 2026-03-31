import UIKit
import Capacitor

/// Plugin Capacitor que renderiza un mini-player nativo sobre el WebView.
/// UIBlurEffect real del sistema, SF Symbols, haptic feedback nativo.
/// El NowPlayingViewer (pantalla completa) sigue siendo React/WebView.
@objc(NativeNowPlayingPlugin)
public class NativeNowPlayingPlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier  = "NativeNowPlayingPlugin"
    public let jsName      = "NativeNowPlaying"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "update", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "show",   returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "hide",   returnType: CAPPluginReturnPromise),
    ]

    // MARK: - Subviews

    private var container:       UIView?
    private var shadowView:      UIView?
    private var artworkView:     UIImageView?
    private var titleLabel:      UILabel?
    private var artistLabel:     UILabel?
    private var playPauseButton: UIButton?
    private var progressFill:    NSLayoutConstraint?  // width constraint
    private var progressTrackWidth: CGFloat = 0

    private var currentArtworkUrl: String?
    private var artworkTask:        URLSessionDataTask?

    private static let barHeight: CGFloat = 70

    // MARK: - Lifecycle

    @objc override public func load() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.setupBar()
        }
    }

    // MARK: - Setup

    private func setupBar() {
        guard let rootVC = bridge?.viewController,
              let view   = rootVC.view else { return }

        // ── Contenedor principal ───────────────────────────────────────────────
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 26
        container.layer.cornerCurve  = .continuous
        container.clipsToBounds      = true
        container.isHidden           = true   // se muestra cuando llega la primera canción

        // Sombra (en la superview, fuera del clipsToBounds)
        let shadow = UIView()
        shadow.translatesAutoresizingMaskIntoConstraints = false
        shadow.layer.shadowColor   = UIColor.black.cgColor
        shadow.layer.shadowOpacity = 0.14
        shadow.layer.shadowRadius  = 20
        shadow.layer.shadowOffset  = CGSize(width: 0, height: -4)
        shadow.layer.cornerRadius  = 26
        // Desactivar interacción: este mini-player es gestionado por AppDelegate.
        // Sin esto, el shadow view (visible en la jerarquía aunque container está
        // hidden) intercepta toques destinados al WKWebView (ej. botones inferiores
        // del NowPlayingViewer).
        shadow.isUserInteractionEnabled = false
        view.addSubview(shadow)
        shadow.addSubview(container)

        // ── Fondo: UIVisualEffectView — iOS 26+ usa UIGlassEffect (Liquid Glass,
        //    mismo material que UITabBar); versiones anteriores usan UIBlurEffect. ─────
        let glassEffect: UIVisualEffect
        if #available(iOS 26.0, *) {
            glassEffect = UIGlassEffect()
        } else {
            glassEffect = UIBlurEffect(style: .systemChromeMaterial)
        }
        let blur = UIVisualEffectView(effect: glassEffect)
        blur.translatesAutoresizingMaskIntoConstraints = false

        // Color overlay — solo en iOS < 26; en iOS 26 UIGlassEffect gestiona su
        // propio color/material exactamente igual que UITabBar.
        let colorOverlay = UIView()
        colorOverlay.translatesAutoresizingMaskIntoConstraints = false
        colorOverlay.backgroundColor = UIColor { traits in
            if #available(iOS 26.0, *) { return .clear }
            return traits.userInterfaceStyle == .dark
                ? UIColor(red: 28/255, green: 28/255, blue: 30/255, alpha: 0.80)
                : UIColor.white.withAlphaComponent(0.55)
        }

        container.addSubview(blur)
        blur.contentView.addSubview(colorOverlay)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            colorOverlay.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
            colorOverlay.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
            colorOverlay.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
            colorOverlay.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor),
        ])

        // ── Barra de progreso (franja superior) ────────────────────────────────
        let progressTrack = UIView()
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.backgroundColor = UIColor.label.withAlphaComponent(0.07)
        container.addSubview(progressTrack)

        let fill = UIView()
        fill.translatesAutoresizingMaskIntoConstraints = false
        fill.backgroundColor = UIColor.label.withAlphaComponent(0.30)
        container.addSubview(fill)

        let fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        fillWidth.isActive = true
        self.progressFill = fillWidth

        NSLayoutConstraint.activate([
            progressTrack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            progressTrack.topAnchor.constraint(equalTo: container.topAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 2.5),

            fill.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fill.topAnchor.constraint(equalTo: container.topAnchor),
            fill.heightAnchor.constraint(equalToConstant: 2.5),
        ])

        // ── Album art ──────────────────────────────────────────────────────────
        let artwork = UIImageView()
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.layer.cornerRadius = 9
        artwork.layer.cornerCurve  = .continuous
        artwork.clipsToBounds      = true
        artwork.contentMode        = .scaleAspectFill
        artwork.backgroundColor    = UIColor.secondarySystemFill
        container.addSubview(artwork)

        // ── Botón next ─────────────────────────────────────────────────────────
        let nextBtn = makeIconButton(
            symbol: "forward.fill",
            size:   20,
            action: #selector(nextTapped)
        )
        container.addSubview(nextBtn)

        // ── Botón play/pause ───────────────────────────────────────────────────
        let playBtn = makeIconButton(
            symbol: "play.fill",
            size:   23,
            action: #selector(playPauseTapped)
        )
        container.addSubview(playBtn)

        // ── Etiquetas título / artista ─────────────────────────────────────────
        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font          = .systemFont(ofSize: 13.5, weight: .semibold)
        title.textColor     = .label
        title.lineBreakMode = .byTruncatingTail
        container.addSubview(title)

        let artist = UILabel()
        artist.translatesAutoresizingMaskIntoConstraints = false
        artist.font          = .systemFont(ofSize: 12, weight: .regular)
        artist.textColor     = .secondaryLabel
        artist.lineBreakMode = .byTruncatingTail
        container.addSubview(artist)

        // ── Constraints de layout ──────────────────────────────────────────────
        NSLayoutConstraint.activate([
            // next
            nextBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            nextBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            nextBtn.widthAnchor.constraint(equalToConstant: 40),
            nextBtn.heightAnchor.constraint(equalToConstant: 44),

            // play/pause
            playBtn.trailingAnchor.constraint(equalTo: nextBtn.leadingAnchor, constant: -2),
            playBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            playBtn.widthAnchor.constraint(equalToConstant: 40),
            playBtn.heightAnchor.constraint(equalToConstant: 44),

            // artwork
            artwork.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            artwork.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            artwork.widthAnchor.constraint(equalToConstant: 42),
            artwork.heightAnchor.constraint(equalToConstant: 42),

            // title
            title.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: playBtn.leadingAnchor, constant: -8),
            title.bottomAnchor.constraint(equalTo: container.centerYAnchor, constant: -1),

            // artist
            artist.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 10),
            artist.trailingAnchor.constraint(equalTo: playBtn.leadingAnchor, constant: -8),
            artist.topAnchor.constraint(equalTo: container.centerYAnchor, constant: 2),
        ])

        // ── Posición del contenedor (sobre la tab bar nativa) ──────────────────
        NSLayoutConstraint.activate([
            // shadow wrapper
            shadow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            shadow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            shadow.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            shadow.heightAnchor.constraint(equalToConstant: NativeNowPlayingPlugin.barHeight),

            // container llena el shadow wrapper
            container.leadingAnchor.constraint(equalTo: shadow.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: shadow.trailingAnchor),
            container.topAnchor.constraint(equalTo: shadow.topAnchor),
            container.bottomAnchor.constraint(equalTo: shadow.bottomAnchor),
        ])

        // ── Tap para abrir el full player ──────────────────────────────────────
        let tap = UITapGestureRecognizer(target: self, action: #selector(barTapped))
        container.addGestureRecognizer(tap)

        view.bringSubviewToFront(shadow)

        self.container       = container
        self.shadowView      = shadow
        self.artworkView     = artwork
        self.titleLabel      = title
        self.artistLabel     = artist
        self.playPauseButton = playBtn
    }

    // MARK: - Acciones

    @objc private func barTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        notifyListeners("tap", data: [:])
    }

    @objc private func playPauseTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        notifyListeners("playPause", data: [:])
    }

    @objc private func nextTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        notifyListeners("next", data: [:])
    }

    // MARK: - Métodos JS-callable

    @objc func update(_ call: CAPPluginCall) {
        let titleText  = call.getString("title")     ?? ""
        let artistText = call.getString("artist")    ?? ""
        let artworkUrl = call.getString("artworkUrl")
        let isPlaying  = call.getBool("isPlaying")   ?? false
        let progress   = call.getDouble("progress")  ?? 0
        let duration   = call.getDouble("duration")  ?? 1
        let isVisible  = call.getBool("isVisible")   ?? true
        let isDark     = call.getBool("isDark")      ?? false

        DispatchQueue.main.async { [weak self] in
            guard let s = self else { return }

            // Forzar modo oscuro/claro en todo el mini-player (blur + labels + botones)
            // independientemente del modo del sistema iOS
            s.shadowView?.overrideUserInterfaceStyle = isDark ? .dark : .light

            s.container?.isHidden = !isVisible
            s.titleLabel?.text    = titleText
            s.artistLabel?.text   = artistText

            // Icono play/pause
            let symConf = UIImage.SymbolConfiguration(pointSize: 23, weight: .regular)
            let symName = isPlaying ? "pause.fill" : "play.fill"
            s.playPauseButton?.setImage(
                UIImage(systemName: symName, withConfiguration: symConf),
                for: .normal
            )

            // Barra de progreso
            if let container = s.container {
                let width = container.bounds.width
                if width > 0 {
                    let fraction = duration > 0 ? CGFloat(progress / duration) : 0
                    s.progressFill?.constant = width * fraction
                }
            }

            // Artwork (solo carga si la URL cambió)
            if artworkUrl != s.currentArtworkUrl {
                s.currentArtworkUrl = artworkUrl
                s.artworkTask?.cancel()
                s.artworkView?.image = nil

                if let urlStr = artworkUrl, let url = URL(string: urlStr) {
                    s.artworkTask = URLSession.shared.dataTask(with: url) { [weak s] data, _, _ in
                        guard let data = data, let image = UIImage(data: data) else { return }
                        DispatchQueue.main.async { s?.artworkView?.image = image }
                    }
                    s.artworkTask?.resume()
                }
            }
        }

        call.resolve()
    }

    @objc func show(_ call: CAPPluginCall) {
        DispatchQueue.main.async { self.container?.isHidden = false }
        call.resolve()
    }

    @objc func hide(_ call: CAPPluginCall) {
        DispatchQueue.main.async { self.container?.isHidden = true }
        call.resolve()
    }

    // MARK: - Helpers

    private func makeIconButton(symbol: String, size: CGFloat, action: Selector) -> UIButton {
        let btn  = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        let conf = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
        btn.setImage(UIImage(systemName: symbol, withConfiguration: conf), for: .normal)
        btn.tintColor = .label
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }
}
