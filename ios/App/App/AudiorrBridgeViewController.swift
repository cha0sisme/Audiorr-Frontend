import UIKit
import Capacitor

/// Subclase de CAPBridgeViewController que registra los plugins locales.
/// Capacitor 8 solo auto-descubre plugins de npm (via packageClassList),
/// no los definidos en el target de la app. capacitorDidLoad() se ejecuta
/// después de que bridge y webView estén listos.
class AudiorrBridgeViewController: CAPBridgeViewController {

    override func capacitorDidLoad() {
        super.capacitorDidLoad()

        // Registrar plugins locales que no vienen de npm
        bridge?.registerPluginInstance(NativeAudioPlugin())
        // AudioBridgePlugin ELIMINADO: reemplazado por NativeAudioPlugin + AudioEngineManager.
        // El viejo plugin registraba MPRemoteCommandCenter handlers que conflictuaban
        // con los de AudioEngineManager (double-toggle, race conditions).
        bridge?.registerPluginInstance(NativeNowPlayingPlugin())
        bridge?.registerPluginInstance(NativeTabBarPlugin())
    }
}
