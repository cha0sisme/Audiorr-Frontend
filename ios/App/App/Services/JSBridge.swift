import WebKit

/// Singleton para evaluar JavaScript en el WKWebView de Capacitor.
/// Reemplaza AppDelegate.evalJSPublic() — cualquier vista o servicio Swift
/// puede enviar eventos o ejecutar scripts sin depender de AppDelegate.
@MainActor
final class JSBridge {
    static let shared = JSBridge()
    weak var webView: WKWebView?

    private init() {}

    /// Despacha un CustomEvent en la window del WebView.
    func send(_ eventName: String) {
        eval("window.dispatchEvent(new CustomEvent('\(eventName)'))")
    }

    /// Despacha un CustomEvent con un detail object (JSON string).
    func send(_ eventName: String, detail: String) {
        eval("window.dispatchEvent(new CustomEvent('\(eventName)', { detail: \(detail) }))")
    }

    /// Evalúa un script JS arbitrario en el WKWebView.
    func eval(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }
}
