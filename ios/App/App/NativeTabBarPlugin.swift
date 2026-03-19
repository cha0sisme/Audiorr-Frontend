import UIKit
import Capacitor

private struct TabItem {
    let title: String
    let systemImage: String
    let route: String
}

/// Plugin Capacitor que renderiza una UITabBar nativa de iOS sobre el WebView.
/// La tab bar usa SF Symbols, UIBlurEffect real del sistema, y haptic feedback nativo.
/// Comunica selecciones al JS via evento "tabChange" y acepta "setActiveTab" desde JS.
@objc(NativeTabBarPlugin)
public class NativeTabBarPlugin: CAPPlugin, CAPBridgedPlugin, UITabBarDelegate {

    public let identifier = "NativeTabBarPlugin"
    public let jsName = "NativeTabBar"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "setActiveTab", returnType: CAPPluginReturnPromise),
    ]

    private var tabBar: UITabBar?
    private var isUpdatingFromJS = false

    private let tabs: [TabItem] = [
        TabItem(title: "Inicio",     systemImage: "house.fill",           route: "/"),
        TabItem(title: "Artistas",   systemImage: "person.2.fill",        route: "/artists"),
        TabItem(title: "Playlists",  systemImage: "music.note.list",      route: "/playlists"),
        TabItem(title: "Buscar",     systemImage: "magnifyingglass",      route: "/search"),
        TabItem(title: "Audiorr",    systemImage: "square.grid.2x2.fill", route: "/audiorr"),
    ]

    @objc override public func load() {
        // Pequeño delay para asegurar que la jerarquía de vistas esté completamente montada
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.setupNativeTabBar()
        }
    }

    private func setupNativeTabBar() {
        guard let rootVC = bridge?.viewController,
              let view = rootVC.view else { return }

        let tabBar = UITabBar()
        tabBar.delegate = self
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        tabBar.items = tabs.enumerated().map { (i, tab) in
            UITabBarItem(
                title: tab.title,
                image: UIImage(systemName: tab.systemImage),
                tag: i
            )
        }
        tabBar.selectedItem = tabBar.items?.first

        view.addSubview(tabBar)
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Asegurar que la tab bar quede por encima del WebView
        view.bringSubviewToFront(tabBar)

        self.tabBar = tabBar

        // Notificar al WebView de la altura visual de la tab bar (49pt estándar iOS)
        // para que env(safe-area-inset-bottom) en CSS se ajuste automáticamente.
        rootVC.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 49, right: 0)
    }

    // MARK: - UITabBarDelegate

    public func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard !isUpdatingFromJS else { return }

        // Haptic feedback nativo en cada tap
        let feedback = UISelectionFeedbackGenerator()
        feedback.selectionChanged()

        notifyListeners("tabChange", data: ["route": tabs[item.tag].route])
    }

    // MARK: - Método callable desde JS

    @objc func setActiveTab(_ call: CAPPluginCall) {
        let index = call.getInt("index") ?? 0
        DispatchQueue.main.async {
            self.isUpdatingFromJS = true
            self.tabBar?.selectedItem = self.tabBar?.items?[safe: index]
            self.isUpdatingFromJS = false
        }
        call.resolve()
    }
}

// MARK: - Helpers

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
