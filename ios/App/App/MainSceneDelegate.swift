import UIKit
import SwiftUI
import WebKit

/// Scene delegate para la ventana principal de la app.
/// Crea un container con dos capas:
///   - Capa 0 (atrás): Capacitor WKWebView (oculto — solo JS bridge + audio engine)
///   - Capa 1 (frente): UIHostingController<ContentView> (SwiftUI TabView + MiniPlayer + Viewer)
@objc(MainSceneDelegate)
class MainSceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    private var swiftUIHostVC: UIHostingController<AnyView>?
    private var capacitorVC: UIViewController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)

        // Container root VC
        let containerVC = UIViewController()
        containerVC.view.backgroundColor = .systemBackground

        // Capa 0: Capacitor / WKWebView (desde storyboard)
        let capVC = UIStoryboard(name: "Main", bundle: nil).instantiateInitialViewController()!
        containerVC.addChild(capVC)
        containerVC.view.addSubview(capVC.view)
        capVC.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            capVC.view.leadingAnchor.constraint(equalTo: containerVC.view.leadingAnchor),
            capVC.view.trailingAnchor.constraint(equalTo: containerVC.view.trailingAnchor),
            capVC.view.topAnchor.constraint(equalTo: containerVC.view.topAnchor),
            capVC.view.bottomAnchor.constraint(equalTo: containerVC.view.bottomAnchor),
        ])
        capVC.didMove(toParent: containerVC)
        capVC.view.isHidden = true // Oculto por defecto — SwiftUI está encima
        self.capacitorVC = capVC

        // Capa 1: SwiftUI TabView + MiniPlayer
        let contentView = ContentView()
            .preferredColorScheme(AppTheme.shared.colorScheme)
        let hostVC = UIHostingController(rootView: AnyView(contentView))
        hostVC.view.translatesAutoresizingMaskIntoConstraints = false
        containerVC.addChild(hostVC)
        containerVC.view.addSubview(hostVC.view)
        NSLayoutConstraint.activate([
            hostVC.view.leadingAnchor.constraint(equalTo: containerVC.view.leadingAnchor),
            hostVC.view.trailingAnchor.constraint(equalTo: containerVC.view.trailingAnchor),
            hostVC.view.topAnchor.constraint(equalTo: containerVC.view.topAnchor),
            hostVC.view.bottomAnchor.constraint(equalTo: containerVC.view.bottomAnchor),
        ])
        hostVC.didMove(toParent: containerVC)
        self.swiftUIHostVC = hostVC

        window.rootViewController = containerVC
        window.makeKeyAndVisible()
        self.window = window

        // Transferir la window al AppDelegate para que su setup nativo funcione
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.window = window
            appDelegate.checkAuthAndShowLoginIfNeeded()
        }

    }

    // MARK: - Scene lifecycle → forward to AppDelegate

    func sceneDidBecomeActive(_ scene: UIScene) {
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
