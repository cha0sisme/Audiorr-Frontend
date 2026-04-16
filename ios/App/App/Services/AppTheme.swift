import SwiftUI

/// Fuente de verdad del tema claro/oscuro de la app.
/// AppDelegate lo actualiza cuando JS envía nativeUpdateNowPlaying (isDark).
/// Las vistas SwiftUI lo leen vía @EnvironmentObject o directamente.
final class AppTheme: ObservableObject {
    static let shared = AppTheme()
    @Published var isDark: Bool = false
    var colorScheme: ColorScheme { isDark ? .dark : .light }
    private init() {}
}
