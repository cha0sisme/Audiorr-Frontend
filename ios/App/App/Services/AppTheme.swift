import SwiftUI

/// Fuente de verdad del tema claro/oscuro de la app.
/// AppDelegate lo actualiza cuando JS envía nativeUpdateNowPlaying (isDark).
/// Las vistas SwiftUI lo leen vía @EnvironmentObject o directamente.
final class AppTheme: ObservableObject {
    static let shared = AppTheme()
    @Published var isDark: Bool = false

    /// Detail overlays (album, playlist, artist hero) set this to override
    /// the status bar color while the overlay is visible.
    @Published var overlayColorScheme: ColorScheme?

    /// Effective color scheme — overlay takes priority over base theme.
    var colorScheme: ColorScheme { overlayColorScheme ?? (isDark ? .dark : .light) }

    private init() {}
}
