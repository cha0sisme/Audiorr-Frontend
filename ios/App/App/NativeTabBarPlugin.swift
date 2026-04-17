import Capacitor

/// Plugin Capacitor que mantiene el registro del módulo "NativeTabBar" en JS.
/// La tab bar real es ahora un SwiftUI TabView gestionado por ContentView.
/// Este plugin solo existe para no romper el registro Capacitor si JS lo referencia.
@objc(NativeTabBarPlugin)
public class NativeTabBarPlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "NativeTabBarPlugin"
    public let jsName = "NativeTabBar"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "setActiveTab", returnType: CAPPluginReturnPromise),
    ]

    @objc func setActiveTab(_ call: CAPPluginCall) {
        // Tab selection is now managed by SwiftUI TabView — no-op.
        call.resolve()
    }
}
