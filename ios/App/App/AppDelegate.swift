import UIKit
import Capacitor
import AVFoundation
import WebKit

// Extensión para buscar el WKWebView en la jerarquía de vistas
private extension UIView {
    var firstWKWebView: WKWebView? {
        if let self = self as? WKWebView { return self }
        return subviews.lazy.compactMap { $0.firstWKWebView }.first
    }
}

// UIWindow personalizada: garantiza que las vistas nativas (tab bar, mini-player)
// reciban los toques ANTES que WKWebView, independientemente del z-order.
private class NativeAwareWindow: UIWindow {
    // Vistas nativas registradas para tener prioridad de hit-test
    var priorityViews: [UIView] = []

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Probamos las vistas prioritarias de arriba hacia abajo (último añadido = encima)
        for view in priorityViews.reversed() {
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { continue }
            let local = view.convert(point, from: self)
            if let hit = view.hitTest(local, with: event) { return hit }
        }
        return super.hitTest(point, with: event)
    }
}

// Wrapper para evitar retain cycle con WKUserContentController
private class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: AppDelegate?
    init(_ delegate: AppDelegate) { self.delegate = delegate }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.handleScriptMessage(message)
    }
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UITabBarDelegate, UIGestureRecognizerDelegate {

    var window: UIWindow?

    // ── Estado interno ──────────────────────────────────────────────────────
    private var nativeUIReady    = false
    private weak var webViewRef: WKWebView?

    // Tab bar
    private var tabBar: UITabBar?

    // Mini-player
    private var nowPlayingContainer:   UIView?
    private var miniPlayerShadow:      UIView?
    private var artworkView:           UIImageView?
    private var titleLabel:            UILabel?
    private var artistLabel:           UILabel?
    private var playPauseButton:       UIButton?
    private var subtitleLabel:         UILabel?
    private var progressFill:          NSLayoutConstraint?
    private var currentArtworkUrl:     String?
    private var artworkTask:           URLSessionDataTask?
    // Indica si el mini-player debería mostrarse (hay canción activa)
    private var miniPlayerShouldShow = false
    // Indica si el full-screen viewer está abierto (para no interferir con sus animaciones)
    private var viewerIsOpen         = false

    // ── App lifecycle ────────────────────────────────────────────────────────

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true)
        } catch {
            print("[Audiorr] AVAudioSession setup failed: \(error)")
        }

        // Reemplazar UIWindow con NativeAwareWindow para que UITabBar y el mini-player
        // reciban los toques antes que WKWebView (fix: "solo funciona tras hacer scroll")
        if let existing = window {
            let native: NativeAwareWindow
            if #available(iOS 13.0, *), let scene = existing.windowScene {
                native = NativeAwareWindow(windowScene: scene)
            } else {
                native = NativeAwareWindow(frame: existing.frame)
            }
            native.rootViewController = existing.rootViewController
            self.window = native
            native.makeKeyAndVisible()
        }

        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let webView = self.window?.rootViewController?.view.firstWKWebView else { return }

            // Swipe-back nativo
            webView.allowsBackForwardNavigationGestures = true
            // Evita que el UIScrollView de WKWebView retenga los toques (causaba que
            // el tab bar nativo no respondiera hasta hacer scroll)
            webView.scrollView.delaysContentTouches = false

            // Setup nativo (solo una vez)
            if !self.nativeUIReady {
                self.nativeUIReady = true
                self.webViewRef    = webView
                self.setupMessageHandlers(webView: webView)
                self.setupTabBar()
                self.setupNowPlayingBar()
            }
        }
    }

    // ── JS → Native: message handlers ───────────────────────────────────────

    private func setupMessageHandlers(webView: WKWebView) {
        let ucc     = webView.configuration.userContentController
        let handler = WeakMessageHandler(self)
        ucc.add(handler, name: "nativeSetActiveTab")
        ucc.add(handler, name: "nativeUpdateNowPlaying")
        ucc.add(handler, name: "nativeHideNowPlaying")
        ucc.add(handler, name: "nativeViewerOpen")
        ucc.add(handler, name: "nativeViewerClose")
    }

    func handleScriptMessage(_ message: WKScriptMessage) {
        switch message.name {

        case "nativeSetActiveTab":
            guard let body  = message.body as? [String: Any],
                  let index = body["index"] as? Int else { return }
            DispatchQueue.main.async {
                self.tabBar?.selectedItem = self.tabBar?.items?[safe: index]
            }

        case "nativeUpdateNowPlaying":
            guard let body = message.body as? [String: Any] else { return }
            let titleText    = body["title"]     as? String ?? ""
            let artistText   = body["artist"]    as? String ?? ""
            let artworkUrl   = body["artworkUrl"] as? String
            let isPlaying    = body["isPlaying"] as? Bool   ?? false
            let progress     = body["progress"]  as? Double ?? 0
            let duration     = body["duration"]  as? Double ?? 1
            let isVisible    = body["isVisible"] as? Bool   ?? true
            let isDark       = body["isDark"]    as? Bool   ?? false
            let subtitleText = body["subtitle"]  as? String
            DispatchQueue.main.async {
                self.updateNowPlaying(
                    title: titleText, artist: artistText,
                    artworkUrl: artworkUrl, isPlaying: isPlaying,
                    progress: progress, duration: duration, isVisible: isVisible,
                    isDark: isDark, subtitle: subtitleText
                )
            }

        case "nativeHideNowPlaying":
            DispatchQueue.main.async {
                self.miniPlayerShouldShow = false
                self.nowPlayingContainer?.isHidden = true
            }

        case "nativeViewerOpen":
            DispatchQueue.main.async {
                self.viewerIsOpen = true
                let tabBarH = self.tabBar?.frame.height ?? 80
                // Desactivar interacción del shadow INMEDIATAMENTE para que
                // NativeAwareWindow.hitTest lo omita y los toques lleguen al WKWebView.
                // (El shadow wrapper nunca se ocultaba — solo el container interior —
                // lo que hacía que interceptara los toques en la zona de los controles.)
                self.miniPlayerShadow?.isUserInteractionEnabled = false
                UIView.animate(withDuration: 0.24, delay: 0, options: .curveEaseIn) {
                    self.nowPlayingContainer?.alpha     = 0
                    self.nowPlayingContainer?.transform = CGAffineTransform(translationX: 0, y: 16)
                    self.tabBar?.transform              = CGAffineTransform(translationX: 0, y: tabBarH)
                } completion: { _ in
                    self.nowPlayingContainer?.isHidden = true
                    self.miniPlayerShadow?.isHidden    = true
                    self.tabBar?.isHidden              = true
                    // Preparar para la entrada posterior
                    self.nowPlayingContainer?.transform = CGAffineTransform(translationX: 0, y: 16)
                }
            }

        case "nativeViewerClose":
            DispatchQueue.main.async {
                self.viewerIsOpen = false
                let tabBarH = self.tabBar?.frame.height ?? 80
                // Restaurar shadow antes de la animación de reaparición
                self.miniPlayerShadow?.isHidden              = false
                self.miniPlayerShadow?.isUserInteractionEnabled = true
                // Preparar posiciones de entrada (fuera de pantalla / invisible)
                self.tabBar?.transform = CGAffineTransform(translationX: 0, y: tabBarH)
                self.tabBar?.isHidden  = false
                if self.miniPlayerShouldShow {
                    self.nowPlayingContainer?.isHidden = false
                }
                UIView.animate(withDuration: 0.38, delay: 0.06,
                               usingSpringWithDamping: 0.82, initialSpringVelocity: 0, options: []) {
                    self.nowPlayingContainer?.alpha     = self.miniPlayerShouldShow ? 1 : 0
                    self.nowPlayingContainer?.transform = .identity
                    self.tabBar?.transform              = .identity
                }
            }

        default:
            break
        }
    }

    // ── Native → JS ──────────────────────────────────────────────────────────

    private func evalJS(_ script: String) {
        DispatchQueue.main.async {
            self.webViewRef?.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    // ── Tab bar nativa ───────────────────────────────────────────────────────

    private func setupTabBar() {
        guard let win   = window,
              let rootVC = win.rootViewController else { return }

        let tabs = [
            UITabBarItem(title: "Inicio",    image: UIImage(systemName: "house.fill"),           tag: 0),
            UITabBarItem(title: "Artistas",  image: UIImage(systemName: "person.2.fill"),        tag: 1),
            UITabBarItem(title: "Playlists", image: UIImage(systemName: "music.note.list"),      tag: 2),
            UITabBarItem(title: "Buscar",    image: UIImage(systemName: "magnifyingglass"),      tag: 3),
            UITabBarItem(title: "Audiorr",   image: UIImage(systemName: "square.grid.2x2.fill"), tag: 4),
        ]

        let bar = UITabBar()
        bar.delegate     = self
        bar.items        = tabs
        bar.selectedItem = tabs[0]

        // Apariencia explícita
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        bar.standardAppearance = appearance
        if #available(iOS 15.0, *) { bar.scrollEdgeAppearance = appearance }

        // Añadir a la UIWindow directamente — coordenadas siempre exactas al screen
        let safeBottom = win.safeAreaInsets.bottom
        let barHeight  = CGFloat(49) + safeBottom
        bar.frame = CGRect(x: 0,
                           y: win.bounds.height - barHeight,
                           width: win.bounds.width,
                           height: barHeight)
        bar.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]

        win.addSubview(bar)
        win.bringSubviewToFront(bar)

        // Registrar en NativeAwareWindow para hit-test prioritario
        (win as? NativeAwareWindow)?.priorityViews.append(bar)

        // Ampliar safe area del WebView para que el contenido CSS se ajuste
        rootVC.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 49, right: 0)

        self.tabBar = bar
    }

    // UITabBarDelegate
    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        let routes = ["/", "/artists", "/playlists", "/search", "/audiorr"]
        guard item.tag < routes.count else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        let route = routes[item.tag]
        // HashRouter escucha cambios en window.location.hash directamente — siempre funciona
        evalJS("window.location.hash = '#\(route)'")
    }

    // ── Mini-player nativo ───────────────────────────────────────────────────

    private func setupNowPlayingBar() {
        guard let win = window else { return }

        // Shadow wrapper (fuera del clipsToBounds)
        let shadow = UIView()
        shadow.translatesAutoresizingMaskIntoConstraints = false
        shadow.layer.shadowColor   = UIColor.black.cgColor
        shadow.layer.shadowOpacity = 0.14
        shadow.layer.shadowRadius  = 20
        shadow.layer.shadowOffset  = CGSize(width: 0, height: -4)
        shadow.layer.cornerRadius  = 26

        // Contenedor con blur
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 26
        container.layer.cornerCurve  = .continuous
        container.clipsToBounds      = true
        container.isHidden           = true

        // Blur base — iOS 26+ usa UIGlassEffect (Liquid Glass, mismo material que UITabBar);
        // versiones anteriores usan UIBlurEffect con systemChromeMaterial.
        let glassEffect: UIVisualEffect
        if #available(iOS 26.0, *) {
            glassEffect = UIGlassEffect()
        } else {
            glassEffect = UIBlurEffect(style: .systemChromeMaterial)
        }
        let blur = UIVisualEffectView(effect: glassEffect)
        blur.translatesAutoresizingMaskIntoConstraints = false

        // Color overlay — solo necesario en iOS < 26; en iOS 26 UIGlassEffect
        // gestiona su propio color/material igual que UITabBar.
        let colorOverlay = UIView()
        colorOverlay.translatesAutoresizingMaskIntoConstraints = false
        colorOverlay.backgroundColor = UIColor { traits in
            if #available(iOS 26.0, *) { return .clear }
            return traits.userInterfaceStyle == .dark
                ? UIColor(red: 28/255, green: 28/255, blue: 30/255, alpha: 0.80)
                : UIColor.white.withAlphaComponent(0.55)
        }

        // Progress track
        let track = UIView()
        track.translatesAutoresizingMaskIntoConstraints = false
        track.backgroundColor = UIColor.label.withAlphaComponent(0.07)

        let fill = UIView()
        fill.translatesAutoresizingMaskIntoConstraints = false
        fill.backgroundColor = UIColor.label.withAlphaComponent(0.30)

        // Artwork
        let artwork = UIImageView()
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.layer.cornerRadius = 9
        artwork.layer.cornerCurve  = .continuous
        artwork.clipsToBounds      = true
        artwork.contentMode        = .scaleAspectFill
        artwork.backgroundColor    = UIColor.secondarySystemFill

        // Botones
        let prevBtn  = buildButton(symbol: "backward.fill", size: 20, action: #selector(previousTapped))
        let nextBtn  = buildButton(symbol: "forward.fill",  size: 20, action: #selector(nextTapped))
        let playBtn  = buildButton(symbol: "play.fill",     size: 23, action: #selector(playPauseTapped))

        // Etiquetas
        let titleLbl = UILabel()
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.font          = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLbl.textColor     = .label
        titleLbl.lineBreakMode = .byTruncatingTail

        let artistLbl = UILabel()
        artistLbl.translatesAutoresizingMaskIntoConstraints = false
        artistLbl.font          = .systemFont(ofSize: 12, weight: .regular)
        artistLbl.textColor     = .secondaryLabel
        artistLbl.lineBreakMode = .byTruncatingTail

        let subtitleLbl = UILabel()
        subtitleLbl.translatesAutoresizingMaskIntoConstraints = false
        subtitleLbl.font          = .systemFont(ofSize: 10, weight: .semibold)
        subtitleLbl.textColor     = .systemCyan
        subtitleLbl.lineBreakMode = .byTruncatingTail
        subtitleLbl.isHidden      = true

        // Jerarquía
        container.addSubview(blur)
        blur.contentView.addSubview(colorOverlay)
        container.addSubview(track)
        container.addSubview(fill)
        container.addSubview(artwork)
        container.addSubview(prevBtn)
        container.addSubview(nextBtn)
        container.addSubview(playBtn)
        container.addSubview(titleLbl)
        container.addSubview(artistLbl)
        container.addSubview(subtitleLbl)
        shadow.addSubview(container)
        win.addSubview(shadow)
        win.bringSubviewToFront(shadow)
        // Registrar en NativeAwareWindow para hit-test prioritario
        (win as? NativeAwareWindow)?.priorityViews.append(shadow)

        // Fill width constraint (actualizado dinámicamente)
        let fillWidthConstraint = fill.widthAnchor.constraint(equalToConstant: 0)
        fillWidthConstraint.isActive = true

        NSLayoutConstraint.activate([
            // Blur llena el contenedor (mismo material que UITabBar)
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // Color overlay llena el contentView del blur
            colorOverlay.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
            colorOverlay.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
            colorOverlay.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
            colorOverlay.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor),

            // Progress track
            track.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            track.topAnchor.constraint(equalTo: container.topAnchor),
            track.heightAnchor.constraint(equalToConstant: 2.5),

            // Progress fill
            fill.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fill.topAnchor.constraint(equalTo: container.topAnchor),
            fill.heightAnchor.constraint(equalToConstant: 2.5),

            // Artwork
            artwork.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            artwork.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            artwork.widthAnchor.constraint(equalToConstant: 42),
            artwork.heightAnchor.constraint(equalToConstant: 42),

            // Next
            nextBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            nextBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            nextBtn.widthAnchor.constraint(equalToConstant: 40),
            nextBtn.heightAnchor.constraint(equalToConstant: 44),

            // Play/pause
            playBtn.trailingAnchor.constraint(equalTo: nextBtn.leadingAnchor, constant: -2),
            playBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            playBtn.widthAnchor.constraint(equalToConstant: 40),
            playBtn.heightAnchor.constraint(equalToConstant: 44),

            // Previous
            prevBtn.trailingAnchor.constraint(equalTo: playBtn.leadingAnchor, constant: -2),
            prevBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            prevBtn.widthAnchor.constraint(equalToConstant: 40),
            prevBtn.heightAnchor.constraint(equalToConstant: 44),

            // Title
            titleLbl.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 10),
            titleLbl.trailingAnchor.constraint(equalTo: prevBtn.leadingAnchor, constant: -8),
            titleLbl.bottomAnchor.constraint(equalTo: container.centerYAnchor, constant: -1),

            // Artist
            artistLbl.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 10),
            artistLbl.trailingAnchor.constraint(equalTo: prevBtn.leadingAnchor, constant: -8),
            artistLbl.topAnchor.constraint(equalTo: container.centerYAnchor, constant: 2),

            // Subtitle (shown below artist when active)
            subtitleLbl.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 10),
            subtitleLbl.trailingAnchor.constraint(equalTo: prevBtn.leadingAnchor, constant: -8),
            subtitleLbl.topAnchor.constraint(equalTo: artistLbl.bottomAnchor, constant: 1),

            // Shadow wrapper posición — relativo a la window
            // El tab bar ocupa 49pt por encima del safe-area bottom → sumamos ese offset
            shadow.leadingAnchor.constraint(equalTo: win.leadingAnchor, constant: 16),
            shadow.trailingAnchor.constraint(equalTo: win.trailingAnchor, constant: -16),
            shadow.bottomAnchor.constraint(equalTo: win.safeAreaLayoutGuide.bottomAnchor, constant: -(49 + 8)),
            shadow.heightAnchor.constraint(equalToConstant: 70),

            // Container llena el shadow
            container.leadingAnchor.constraint(equalTo: shadow.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: shadow.trailingAnchor),
            container.topAnchor.constraint(equalTo: shadow.topAnchor),
            container.bottomAnchor.constraint(equalTo: shadow.bottomAnchor),
        ])

        // Tap para abrir full player — delegate evita que intercepte taps en botones
        let tap = UITapGestureRecognizer(target: self, action: #selector(nowPlayingTapped))
        tap.delegate = self
        container.addGestureRecognizer(tap)

        self.nowPlayingContainer = container
        self.miniPlayerShadow    = shadow
        self.artworkView         = artwork
        self.titleLabel          = titleLbl
        self.artistLabel         = artistLbl
        self.subtitleLabel       = subtitleLbl
        self.playPauseButton     = playBtn
        self.progressFill        = fillWidthConstraint
    }

    private func updateNowPlaying(title: String, artist: String, artworkUrl: String?,
                                  isPlaying: Bool, progress: Double, duration: Double,
                                  isVisible: Bool, isDark: Bool = false, subtitle: String? = nil) {
        // Forzar modo oscuro/claro en todo el mini-player (blur + labels + botones)
        // independientemente del modo del sistema iOS
        miniPlayerShadow?.overrideUserInterfaceStyle = isDark ? .dark : .light

        miniPlayerShouldShow = isVisible
        if isVisible && !viewerIsOpen {
            // Restaurar estado visual por si una animación anterior lo dejó oculto
            nowPlayingContainer?.isHidden  = false
            nowPlayingContainer?.alpha     = 1
            nowPlayingContainer?.transform = .identity
        } else if !isVisible {
            nowPlayingContainer?.isHidden = true
        }
        titleLabel?.text  = title
        artistLabel?.text = artist

        // Subtitle (AutoMix · Xs / Reproduciendo en…) — smooth fade transitions
        let newSubtitle = (subtitle ?? "").isEmpty ? nil : subtitle
        let currentSubtitle = subtitleLabel?.text
        let wasVisible = !(subtitleLabel?.isHidden ?? true)

        if let sub = newSubtitle {
            let isAutoMix = sub.hasPrefix("AutoMix")
            subtitleLabel?.textColor = isAutoMix ? .systemCyan : .systemGreen

            if !wasVisible {
                // Fade in
                subtitleLabel?.text    = sub
                subtitleLabel?.alpha   = 0
                subtitleLabel?.isHidden = false
                UIView.animate(withDuration: 0.2) {
                    self.subtitleLabel?.alpha = 1
                }
            } else if currentSubtitle != sub {
                // Cross-fade between different subtitles
                UIView.animate(withDuration: 0.15, animations: {
                    self.subtitleLabel?.alpha = 0
                }) { _ in
                    self.subtitleLabel?.text = sub
                    UIView.animate(withDuration: 0.15) {
                        self.subtitleLabel?.alpha = 1
                    }
                }
            }
        } else if wasVisible {
            // Fade out
            UIView.animate(withDuration: 0.2, animations: {
                self.subtitleLabel?.alpha = 0
            }) { _ in
                self.subtitleLabel?.isHidden = true
            }
        }

        let conf    = UIImage.SymbolConfiguration(pointSize: 23, weight: .regular)
        let symbol  = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton?.setImage(UIImage(systemName: symbol, withConfiguration: conf), for: .normal)

        if let container = nowPlayingContainer {
            let w        = container.bounds.width
            let fraction = duration > 0 ? CGFloat(progress / duration) : 0
            progressFill?.constant = w * fraction
        }

        if artworkUrl != currentArtworkUrl {
            currentArtworkUrl = artworkUrl
            artworkTask?.cancel()
            artworkView?.image = nil

            if let urlStr = artworkUrl, let url = URL(string: urlStr) {
                artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                    guard let data = data, let image = UIImage(data: data) else { return }
                    DispatchQueue.main.async { self?.artworkView?.image = image }
                }
                artworkTask?.resume()
            }
        }
    }

    // ── Acciones del mini-player ─────────────────────────────────────────────

    @objc private func nowPlayingTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        evalJS("window.dispatchEvent(new CustomEvent('native-nowplaying-tap'))")
    }

    @objc private func playPauseTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        evalJS("window.dispatchEvent(new CustomEvent('_nativePlayPause'))")
    }

    @objc private func previousTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        evalJS("window.dispatchEvent(new CustomEvent('_nativePrevious'))")
    }

    @objc private func nextTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        evalJS("window.dispatchEvent(new CustomEvent('_nativeNext'))")
    }

    // ── UIGestureRecognizerDelegate ──────────────────────────────────────────
    // Evita que el tap gesture del mini-player intercepte taps destinados a botones
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return !(touch.view is UIControl)
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private func buildButton(symbol: String, size: CGFloat, action: Selector) -> UIButton {
        let btn  = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        let conf = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
        btn.setImage(UIImage(systemName: symbol, withConfiguration: conf), for: .normal)
        btn.tintColor = .label
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    // ── ApplicationDelegateProxy (Capacitor) ─────────────────────────────────

    func applicationWillResignActive(_ application: UIApplication) {}
    func applicationDidEnterBackground(_ application: UIApplication) {}
    func applicationWillEnterForeground(_ application: UIApplication) {}
    func applicationWillTerminate(_ application: UIApplication) {}

    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity,
                                                           restorationHandler: restorationHandler)
    }
}

// ── Extensión Array safe subscript ──────────────────────────────────────────

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
