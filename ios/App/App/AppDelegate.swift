import UIKit
import AVFoundation
import CarPlay
import SwiftUI

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    // Auth / Login
    private var loginHostVC: UIHostingController<AnyView>?
    private var isShowingLogin = false

    // MARK: - App Lifecycle

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

        // Apply persisted theme once scene is connected (didSet fires before windows exist)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AppTheme.shared.applyToWindows()
        }

        UIApplication.shared.beginReceivingRemoteControlEvents()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        // Audio interruption is handled solely by AudioEngineManager
        // (tracks wasPlayingBeforeInterruption, handles shouldResume + auto-resume).
        // Do NOT add a duplicate observer here — it races with AudioEngineManager
        // and corrupts wasPlayingBeforeInterruption state.

        // Initialize AudioEngineManager (now standalone, no Capacitor plugin)
        if AudioEngineManager.shared == nil {
            AudioEngineManager.shared = AudioEngineManager()
        }

        // Set QueueManager as the audio engine delegate
        AudioEngineManager.shared?.delegate = QueueManager.shared

        // Retry any pending scrobbles from previous session
        Task { @MainActor in
            ScrobbleService.shared.retryPending()
            QueueManager.shared.restoreLastPlayback()
            ConnectService.shared.connect()
        }

        return true
    }

    // MARK: - Audio Route Change

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        if reason == .oldDeviceUnavailable {
            print("[Audiorr] Audio route lost → pausing")
            AudioEngineManager.shared?.pause()
        }

        configureIOBufferForRoute()
    }

    private func configureIOBufferForRoute() {
        let session = AVAudioSession.sharedInstance()
        let isCarPlay = session.currentRoute.outputs.contains { $0.portType == .carAudio }

        do {
            if isCarPlay {
                try session.setPreferredIOBufferDuration(0.04)
            } else {
                try session.setPreferredIOBufferDuration(0.02)
            }
        } catch {
            print("[Audiorr] Failed to set IO buffer duration: \(error)")
        }
    }

    // MARK: - Auth / Login

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
                .preferredColorScheme(AppTheme.shared.colorScheme)
        ))
        hostVC.view.translatesAutoresizingMaskIntoConstraints = false
        let uiStyle: UIUserInterfaceStyle = {
            switch AppTheme.shared.mode {
            case .system: return .unspecified
            case .light:  return .light
            case .dark:   return .dark
            }
        }()
        hostVC.view.overrideUserInterfaceStyle = uiStyle

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

            // Restore last playback + connect to hub
            Task { @MainActor in
                QueueManager.shared.restoreLastPlayback()
                ConnectService.shared.connect()
            }
        }
    }

    // MARK: - App Lifecycle (forwarded from SceneDelegate)

    func applicationWillResignActive(_ application: UIApplication) {}

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Save playback position immediately — app may be killed without warning
        Task { @MainActor in
            QueueManager.shared.savePositionNow()
        }

        // Release audio hardware when truly idle — saves battery in background.
        //
        // We only deactivate when there's NO audio loaded at all (no file, no stream).
        // When the user is just paused with a song loaded, iOS expects us to keep the
        // session active so the lockscreen Now Playing widget stays bound to our app:
        // deactivating in the paused-with-song state makes iOS revoke our primary-audio
        // status, after which the widget falls back to a system-decided play/pause icon
        // that doesn't match our actual state (typically shows "playing" while we're
        // paused — the bug v6.7 silently introduced).
        //
        // Apple Music / Spotify follow the same rule: session stays active while a
        // track is loaded, even when paused. The only "release" moment is genuine idle
        // (queue exhausted, app launched without playback yet, etc.).
        if let engine = AudioEngineManager.shared, !engine.isPlaying, !engine.hasLoadedAudio {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                print("[Audiorr] Failed to deactivate AVAudioSession on background: \(error)")
            }
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default,
                                    options: [.allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true, options: [])
        } catch {
            print("[Audiorr] Failed to reactivate AVAudioSession on foreground: \(error)")
        }
        configureIOBufferForRoute()

        // Reconcile progress immediately so the UI shows the correct time
        // on the very first frame after returning from background.
        // Without this, state.progress is stale for up to 250ms (one timer tick).
        if let engine = AudioEngineManager.shared, engine.isPlaying {
            let time = engine.currentTime()
            NowPlayingState.shared.progress = time
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Last-chance save — synchronous since app is about to die
        PersistenceService.shared.position = NowPlayingState.shared.progress
    }

    // MARK: - Background URLSession (Downloads)

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            DownloadManager.shared.setBackgroundCompletionHandler(completionHandler)
        }
    }

    // MARK: - Scene Configuration (CarPlay)

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
