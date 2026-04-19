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

    // MARK: - Audio Session Interruption

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            print("[Audiorr] Audio session interrupted")
            AudioEngineManager.shared?.pause()

        case .ended:
            print("[Audiorr] Audio session interruption ended — reactivating")
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("[Audiorr] Failed to reactivate audio session: \(error)")
            }

            let options = AVAudioSession.InterruptionOptions(
                rawValue: (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            )
            if options.contains(.shouldResume) {
                AudioEngineManager.shared?.resume()
            }

        @unknown default:
            break
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

            // Restore last playback + connect to hub
            Task { @MainActor in
                QueueManager.shared.restoreLastPlayback()
                ConnectService.shared.connect()
            }
        }
    }

    // MARK: - App Lifecycle (forwarded from SceneDelegate)

    func applicationWillResignActive(_ application: UIApplication) {}
    func applicationDidEnterBackground(_ application: UIApplication) {}

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
    }

    func applicationWillTerminate(_ application: UIApplication) {}

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
