import UIKit
import Capacitor
import AVFoundation
import WebKit
import CarPlay
import SwiftUI

// Extensión para buscar el WKWebView en la jerarquía de vistas
private extension UIView {
    var firstWKWebView: WKWebView? {
        if let self = self as? WKWebView { return self }
        return subviews.lazy.compactMap { $0.firstWKWebView }.first
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
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    // ── Estado interno ─────────────���────────────────────────────────────────
    private var nativeUIReady = false
    weak var webViewRef: WKWebView?

    // Auth / Login
    private var loginHostVC: UIHostingController<AnyView>?
    private var isShowingLogin = false

    // ── App lifecycle ─────────────────────��──────────────────────────────────

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true)
        } catch {
            print("[Audiorr] AVAudioSession setup failed: \(error)")
        }

        configureIOBufferForRoute()

        // Restore persisted theme preference
        if UserDefaults.standard.object(forKey: "audiorr_isDark") != nil {
            AppTheme.shared.isDark = UserDefaults.standard.bool(forKey: "audiorr_isDark")
        }

        UIApplication.shared.beginReceivingRemoteControlEvents()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let webView = self.window?.rootViewController?.view.firstWKWebView else { return }

            webView.allowsBackForwardNavigationGestures = true
            webView.scrollView.delaysContentTouches = false

            // Setup nativo (solo una vez)
            if !self.nativeUIReady {
                self.nativeUIReady = true
                self.webViewRef    = webView
                JSBridge.shared.webView = webView
                self.setupMessageHandlers(webView: webView)

                JSBridge.shared.send("_nativeReady")

                // Puente de credenciales + backend URL
                JSBridge.shared.eval("""
                    (function(){
                        var cfg = localStorage.getItem('navidromeConfig');
                        if (cfg) window.webkit.messageHandlers.nativeSyncConfig.postMessage(cfg);
                        var bu = window.__AUDIORR_BACKEND_URL__;
                        if (!bu || bu.indexOf('capacitor:') === 0) {
                            var keys = Object.keys(localStorage);
                            for (var i = 0; i < keys.length; i++) {
                                if (keys[i].indexOf('backendUrl') >= 0) {
                                    var v = localStorage.getItem(keys[i]);
                                    if (v && v.indexOf('http') === 0) { bu = v; break; }
                                }
                            }
                        }
                        if (bu && bu.indexOf('capacitor:') !== 0) {
                            window.webkit.messageHandlers.nativeSyncBackendUrl.postMessage(bu);
                        }
                    })();
                """)

                // Check auth — show login if no credentials
                if !self.isShowingLogin {
                    self.checkAuthAndShowLoginIfNeeded()
                }
            }
        }
    }

    // ── JS → Native: message handlers ───────────────��───────────────────────

    private func setupMessageHandlers(webView: WKWebView) {
        let ucc     = webView.configuration.userContentController
        let handler = WeakMessageHandler(self)
        ucc.add(handler, name: "nativeSetActiveTab")
        ucc.add(handler, name: "nativeUpdateNowPlaying")
        ucc.add(handler, name: "nativeHideNowPlaying")
        ucc.add(handler, name: "nativeViewerOpen")
        ucc.add(handler, name: "nativeViewerClose")
        ucc.add(handler, name: "nativeSyncConfig")
        ucc.add(handler, name: "nativeSyncBackendUrl")
        ucc.add(handler, name: "nativeSmartMixStatus")
        ucc.add(handler, name: "nativeUpdateViewerState")
    }

    func handleScriptMessage(_ message: WKScriptMessage) {
        switch message.name {

        case "nativeSetActiveTab":
            // Tab selection now handled by SwiftUI TabView — no-op
            break

        case "nativeUpdateNowPlaying":
            guard let body = message.body as? [String: Any] else { return }
            DispatchQueue.main.async {
                NowPlayingState.shared.update(from: body)
            }

        case "nativeHideNowPlaying":
            DispatchQueue.main.async {
                NowPlayingState.shared.hide()
            }

        case "nativeViewerOpen":
            DispatchQueue.main.async {
                NowPlayingState.shared.viewerIsOpen = true
            }

        case "nativeViewerClose":
            DispatchQueue.main.async {
                NowPlayingState.shared.viewerIsOpen = false
            }

        case "nativeSyncConfig":
            if let configString = message.body as? String {
                UserDefaults.standard.set(configString, forKey: "navidromeConfig")
                NavidromeService.shared.reloadCredentials()
            }

        case "nativeSyncBackendUrl":
            if let urlString = message.body as? String, !urlString.isEmpty {
                UserDefaults.standard.set(urlString, forKey: "audiorr_backend_url")
            }

        case "nativeUpdateViewerState":
            print("[AppDelegate] nativeUpdateViewerState received, body type: \(type(of: message.body))")
            guard let body = message.body as? [String: Any] else {
                print("[AppDelegate] nativeUpdateViewerState FAILED: body is not [String: Any]")
                return
            }
            print("[AppDelegate] nativeUpdateViewerState OK: keys=\(body.keys.sorted())")
            DispatchQueue.main.async {
                NowPlayingState.shared.updateViewerState(from: body)
            }

        case "nativeSmartMixStatus":
            if let body = message.body as? [String: Any],
               let playlistId = body["playlistId"] as? String,
               let status = body["status"] as? String {
                PlayerService.shared.updateSmartMixStatus(playlistId: playlistId, status: status)
            }

        default:
            break
        }
    }

    // ── Audio route change (Bluetooth / CarPlay desconectado) ──────────────

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        if reason == .oldDeviceUnavailable {
            print("[Audiorr] Audio route lost (Bluetooth/CarPlay/headphones disconnected) → pausing")
            JSBridge.shared.send("_audioRouteLost")
        }

        configureIOBufferForRoute()
    }

    private func configureIOBufferForRoute() {
        let session = AVAudioSession.sharedInstance()
        let isCarPlay = session.currentRoute.outputs.contains { $0.portType == .carAudio }

        do {
            if isCarPlay {
                try session.setPreferredIOBufferDuration(0.04)
                print("[Audiorr] CarPlay detected — IO buffer set to 0.04s (actual: \(session.ioBufferDuration)s)")
            } else {
                try session.setPreferredIOBufferDuration(0.02)
                print("[Audiorr] Standard output — IO buffer set to 0.02s (actual: \(session.ioBufferDuration)s)")
            }
        } catch {
            print("[Audiorr] Failed to set IO buffer duration: \(error)")
        }
    }

    // ── Audio session interruption (llamada, Siri, otra app) ────────────────

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            print("[Audiorr] Audio session interrupted")
            JSBridge.shared.send("_audioSessionInterrupted")

        case .ended:
            print("[Audiorr] Audio session interruption ended — reactivating")
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("[Audiorr] Failed to reactivate audio session after interruption: \(error)")
            }

            let options = AVAudioSession.InterruptionOptions(
                rawValue: (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            )
            let shouldResume = options.contains(.shouldResume)
            JSBridge.shared.send("_audioSessionResumed", detail: "{ shouldResume: \(shouldResume) }")

        @unknown default:
            break
        }
    }

    // ── Native → JS (legacy, kept for evalJSPublic callers) ─────────────────

    /// Versión pública para uso desde servicios Swift (PlayerService, etc.)
    /// Prefer JSBridge.shared.eval() for new code.
    func evalJSPublic(_ script: String) {
        JSBridge.shared.eval(script)
    }

    /// Apply dark/light theme from SwiftUI settings toggle.
    func applyTheme(isDark: Bool) {
        AppTheme.shared.isDark = isDark
        UserDefaults.standard.set(isDark, forKey: "audiorr_isDark")

        // Sync to JS side
        let script = "document.documentElement.classList.toggle('dark', \(isDark))"
        JSBridge.shared.eval(script)
    }

    // ── Auth / Login ─────���──────────────────────────────────────────────────

    func checkAuthAndShowLoginIfNeeded() {
        if NavidromeService.shared.credentials == nil {
            showLogin()
        }
    }

    func showLogin() {
        guard let win = window, !isShowingLogin else { return }
        isShowingLogin = true

        let loginView = LoginView(onSuccess: { [weak self] in
            self?.dismissLogin()
        })
        let hostVC = UIHostingController(rootView: AnyView(
            loginView
                .preferredColorScheme(AppTheme.shared.isDark ? .dark : .light)
        ))
        hostVC.view.translatesAutoresizingMaskIntoConstraints = false
        hostVC.view.overrideUserInterfaceStyle = AppTheme.shared.isDark ? .dark : .light

        guard let rootVC = win.rootViewController else { return }
        rootVC.addChild(hostVC)
        rootVC.view.addSubview(hostVC.view)
        NSLayoutConstraint.activate([
            hostVC.view.leadingAnchor.constraint(equalTo: rootVC.view.leadingAnchor),
            hostVC.view.trailingAnchor.constraint(equalTo: rootVC.view.trailingAnchor),
            hostVC.view.topAnchor.constraint(equalTo: rootVC.view.topAnchor),
            hostVC.view.bottomAnchor.constraint(equalTo: rootVC.view.bottomAnchor),
        ])
        hostVC.didMove(toParent: rootVC)

        rootVC.view.bringSubviewToFront(hostVC.view)
        loginHostVC = hostVC
    }

    private func dismissLogin() {
        guard isShowingLogin else { return }
        isShowingLogin = false

        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: []) {
            self.loginHostVC?.view.alpha = 0
            self.loginHostVC?.view.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        } completion: { _ in
            self.loginHostVC?.willMove(toParent: nil)
            self.loginHostVC?.view.removeFromSuperview()
            self.loginHostVC?.removeFromParent()
            self.loginHostVC = nil

            // Re-sync credentials with JS side
            JSBridge.shared.eval("""
                (function(){
                    var cfg = localStorage.getItem('navidromeConfig');
                    if (cfg) window.webkit.messageHandlers.nativeSyncConfig.postMessage(cfg);
                    var bu = window.__AUDIORR_BACKEND_URL__
                        || (window.location.protocol + '//' + window.location.hostname + ':2999');
                    window.webkit.messageHandlers.nativeSyncBackendUrl.postMessage(bu);
                    window.location.reload();
                })();
            """)
        }
    }

    // ── ApplicationDelegateProxy (Capacitor) ─────────────────────────────────

    func applicationWillResignActive(_ application: UIApplication) {}
    func applicationDidEnterBackground(_ application: UIApplication) {}

    func applicationWillEnterForeground(_ application: UIApplication) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default,
                                    options: [.allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true, options: [])
            print("[Audiorr] AVAudioSession reactivated on foreground (category: \(session.category.rawValue))")
        } catch {
            print("[Audiorr] Failed to reactivate AVAudioSession on foreground: \(error)")
        }

        configureIOBufferForRoute()
    }

    func applicationWillTerminate(_ application: UIApplication) {}

    // Capacitor's ApplicationDelegateProxy requires this method.
    @available(iOS, deprecated: 26.0)
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity,
                                                           restorationHandler: restorationHandler)
    }

    // ── Scene configuration (CarPlay) ───────────���───────────────────────────

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }
}
