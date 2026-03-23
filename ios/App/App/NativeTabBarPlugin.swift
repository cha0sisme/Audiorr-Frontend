import UIKit
import Capacitor

private struct TabItem {
    let title: String
    let systemImage: String
    let route: String
    /// If non-nil, load from asset catalog instead of SF Symbols
    let assetImage: String?

    init(title: String, systemImage: String, route: String, assetImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.route = route
        self.assetImage = assetImage
    }
}

/// Plugin Capacitor que renderiza una UITabBar nativa de iOS sobre el WebView.
/// Layout estilo iOS 26: tabs principales agrupados + botón de búsqueda circular separado a la derecha.
@objc(NativeTabBarPlugin)
public class NativeTabBarPlugin: CAPPlugin, CAPBridgedPlugin, UITabBarDelegate {

    public let identifier = "NativeTabBarPlugin"
    public let jsName = "NativeTabBar"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "setActiveTab", returnType: CAPPluginReturnPromise),
    ]

    private var tabBar: UITabBar?
    private var searchButton: UIButton?
    private var containerView: UIView?
    private var isUpdatingFromJS = false

    /// Tabs principales (sin búsqueda)
    private let tabs: [TabItem] = [
        TabItem(title: "Inicio",     systemImage: "house.fill",      route: "/"),
        TabItem(title: "Artistas",   systemImage: "person.2.fill",   route: "/artists"),
        TabItem(title: "Playlists",  systemImage: "music.note.list", route: "/playlists"),
        TabItem(title: "Audiorr",    systemImage: "square.grid.2x2.fill", route: "/audiorr", assetImage: "AudiorrTabIcon"),
    ]

    private let searchRoute = "/search"

    @objc override public func load() {
        // Tab bar gestionado por AppDelegate.setupTabBar() — este plugin no crea UI propia.
        // Se mantiene para no romper el registro Capacitor del módulo "NativeTabBar".
    }

    private func setupNativeTabBar() {
        guard let rootVC = bridge?.viewController,
              let view = rootVC.view else { return }

        // ── Container ──
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .clear
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // ── UITabBar (tabs principales) ──
        let tabBar = UITabBar()
        tabBar.delegate = self
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        tabBar.items = tabs.enumerated().map { (i, tab) in
            let image: UIImage?
            if let assetName = tab.assetImage {
                // Cargar desde asset catalog como template (monochrome)
                image = UIImage(named: assetName)?.withRenderingMode(.alwaysTemplate)
            } else {
                image = UIImage(systemName: tab.systemImage)
            }
            return UITabBarItem(title: tab.title, image: image, tag: i)
        }
        tabBar.selectedItem = tabBar.items?.first

        container.addSubview(tabBar)

        // ── Botón de búsqueda circular ──
        let searchBtn = UIButton(type: .system)
        searchBtn.translatesAutoresizingMaskIntoConstraints = false

        let searchIcon = UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        searchBtn.setImage(searchIcon, for: .normal)
        searchBtn.tintColor = .secondaryLabel

        // Estilo: fondo glass circular
        searchBtn.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.01)
        searchBtn.layer.cornerRadius = 22
        searchBtn.clipsToBounds = true

        // Blur background para el botón
        let blurEffect = UIBlurEffect(style: .systemThinMaterial)
        let blurView = UIVisualEffectView(effect: blurEffect)
        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.isUserInteractionEnabled = false
        blurView.layer.cornerRadius = 22
        blurView.clipsToBounds = true
        searchBtn.insertSubview(blurView, at: 0)

        searchBtn.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)

        container.addSubview(searchBtn)

        // ── Layout ──
        NSLayoutConstraint.activate([
            // Tab bar: de izquierda hasta el botón de búsqueda
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // Search button: a la derecha, centrado verticalmente respecto al tab bar
            // (la tab bar estándar mide ~49pt excluyendo safe area)
            searchBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            searchBtn.centerYAnchor.constraint(equalTo: container.topAnchor, constant: 24.5), // centrado en los 49pt
            searchBtn.widthAnchor.constraint(equalToConstant: 44),
            searchBtn.heightAnchor.constraint(equalToConstant: 44),

            // Tab bar termina antes del search button
            tabBar.trailingAnchor.constraint(equalTo: searchBtn.leadingAnchor, constant: -4),

            // Blur view llena el botón
            blurView.leadingAnchor.constraint(equalTo: searchBtn.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: searchBtn.trailingAnchor),
            blurView.topAnchor.constraint(equalTo: searchBtn.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: searchBtn.bottomAnchor),
        ])

        view.bringSubviewToFront(container)

        self.tabBar = tabBar
        self.searchButton = searchBtn
        self.containerView = container

        // Safe area insets para el WebView
        rootVC.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 49, right: 0)
    }

    // MARK: - Search button tap

    @objc private func searchTapped() {
        let feedback = UISelectionFeedbackGenerator()
        feedback.selectionChanged()

        // Deseleccionar tab bar items y activar search
        tabBar?.selectedItem = nil
        updateSearchButtonActive(true)

        notifyListeners("tabChange", data: ["route": searchRoute])
    }

    // MARK: - UITabBarDelegate

    public func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard !isUpdatingFromJS else { return }

        let feedback = UISelectionFeedbackGenerator()
        feedback.selectionChanged()

        // Desactivar búsqueda cuando se selecciona un tab principal
        updateSearchButtonActive(false)

        notifyListeners("tabChange", data: ["route": tabs[item.tag].route])
    }

    // MARK: - Método callable desde JS

    @objc func setActiveTab(_ call: CAPPluginCall) {
        let index = call.getInt("index") ?? 0
        DispatchQueue.main.async {
            self.isUpdatingFromJS = true

            if index == 4 {
                // Índice 4 = búsqueda (no es un tab bar item)
                self.tabBar?.selectedItem = nil
                self.updateSearchButtonActive(true)
            } else {
                self.tabBar?.selectedItem = self.tabBar?.items?[safe: index]
                self.updateSearchButtonActive(false)
            }

            self.isUpdatingFromJS = false
        }
        call.resolve()
    }

    // MARK: - Helpers

    private func updateSearchButtonActive(_ active: Bool) {
        UIView.animate(withDuration: 0.15) {
            self.searchButton?.tintColor = active
                ? self.tabBar?.tintColor ?? .systemBlue
                : .secondaryLabel
        }
    }
}

// MARK: - Array safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
