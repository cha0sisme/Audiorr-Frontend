import SwiftUI
import UIKit

/// Fuente de verdad del tema claro/oscuro de la app.
/// Las vistas SwiftUI lo leen vía @ObservedObject.
final class AppTheme: ObservableObject {
    static let shared = AppTheme()
    @Published var isDark: Bool = UserDefaults.standard.bool(forKey: "audiorr_isDark") {
        didSet {
            UserDefaults.standard.set(isDark, forKey: "audiorr_isDark")
            applyToWindows()
        }
    }

    /// Detail overlays (album, playlist, artist hero) set this to override
    /// the status bar color while the overlay is visible.
    @Published var overlayColorScheme: ColorScheme?

    /// Effective color scheme — overlay takes priority over base theme.
    var colorScheme: ColorScheme { overlayColorScheme ?? (isDark ? .dark : .light) }

    private init() {}

    /// Force-update all UIKit windows so the change is immediately visible
    /// everywhere (status bar, alerts, action sheets, etc.).
    func applyToWindows() {
        let style: UIUserInterfaceStyle = isDark ? .dark : .light
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
