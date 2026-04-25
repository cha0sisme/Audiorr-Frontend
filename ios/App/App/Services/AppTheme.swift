import SwiftUI
import UIKit

/// Fuente de verdad del tema de la app: claro, oscuro, o automático (sistema).
/// Las vistas SwiftUI lo leen vía @ObservedObject.
final class AppTheme: ObservableObject {
    static let shared = AppTheme()

    enum Mode: String, CaseIterable {
        case system, light, dark
    }

    @Published var mode: Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "audiorr_themeMode")
            applyToWindows()
        }
    }

    /// Detail overlays (album, playlist, artist hero) set this to override
    /// the status bar color while the overlay is visible.
    @Published var overlayColorScheme: ColorScheme?

    /// Effective color scheme — overlay takes priority over base theme.
    /// Returns nil for .system so `.preferredColorScheme(nil)` follows the OS.
    var colorScheme: ColorScheme? {
        if let overlay = overlayColorScheme { return overlay }
        switch mode {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Convenience for UIKit code that needs a non-optional Bool.
    var isDark: Bool {
        switch mode {
        case .dark: return true
        case .light: return false
        case .system: return UITraitCollection.current.userInterfaceStyle == .dark
        }
    }

    private init() {
        // Migrate from old bool key if present
        if let raw = UserDefaults.standard.string(forKey: "audiorr_themeMode"),
           let saved = Mode(rawValue: raw) {
            self.mode = saved
        } else if UserDefaults.standard.object(forKey: "audiorr_isDark") != nil {
            // Legacy migration: bool → enum
            self.mode = UserDefaults.standard.bool(forKey: "audiorr_isDark") ? .dark : .light
            UserDefaults.standard.removeObject(forKey: "audiorr_isDark")
            UserDefaults.standard.set(mode.rawValue, forKey: "audiorr_themeMode")
        } else {
            self.mode = .system
        }
    }

    /// Force-update all UIKit windows so the change is immediately visible
    /// everywhere (status bar, alerts, action sheets, etc.).
    func applyToWindows() {
        let style: UIUserInterfaceStyle
        switch mode {
        case .system: style = .unspecified
        case .light:  style = .light
        case .dark:   style = .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
