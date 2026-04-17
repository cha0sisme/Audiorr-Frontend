import UIKit
import SwiftUI

/// Scene delegate for the main app window.
/// Pure SwiftUI — no WKWebView or Capacitor layer.
@objc(MainSceneDelegate)
class MainSceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)

        let contentView = ContentView()
            .preferredColorScheme(AppTheme.shared.colorScheme)
        let hostVC = UIHostingController(rootView: AnyView(contentView))

        window.rootViewController = hostVC
        window.makeKeyAndVisible()
        self.window = window

        // Transfer window to AppDelegate for login overlay
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.window = window
            appDelegate.checkAuthAndShowLoginIfNeeded()
        }
    }

    // MARK: - Scene Lifecycle → forward to AppDelegate

    func sceneDidBecomeActive(_ scene: UIScene) {
        // No-op — no WKWebView setup needed anymore
    }

    func sceneWillResignActive(_ scene: UIScene) {
        if let app = UIApplication.shared.delegate as? AppDelegate {
            app.applicationWillResignActive(UIApplication.shared)
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        if let app = UIApplication.shared.delegate as? AppDelegate {
            app.applicationDidEnterBackground(UIApplication.shared)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        if let app = UIApplication.shared.delegate as? AppDelegate {
            app.applicationWillEnterForeground(UIApplication.shared)
        }
    }
}
