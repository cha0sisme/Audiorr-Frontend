import UIKit

/// Scene delegate para la ventana principal de la app.
/// Crea NativeAwareWindow (igual que hacía AppDelegate) y se la transfiere
/// para que todo el setup nativo (tab bar, mini-player, hit-test) funcione.
@objc(MainSceneDelegate)
class MainSceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = NativeAwareWindow(windowScene: windowScene)
        window.rootViewController = UIStoryboard(name: "Main", bundle: nil).instantiateInitialViewController()
        window.makeKeyAndVisible()
        self.window = window

        // Transferir la window al AppDelegate para que su setup nativo funcione
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.window = window
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Redirigir al AppDelegate para que ejecute su setup de UI nativa
        if let app = UIApplication.shared.delegate as? AppDelegate {
            app.applicationDidBecomeActive(UIApplication.shared)
        }
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
