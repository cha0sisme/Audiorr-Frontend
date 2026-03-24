import Foundation
import Capacitor
import MediaPlayer
import AVFoundation
import UIKit

/// Plugin Capacitor que expone MPNowPlayingInfoCenter y MPRemoteCommandCenter al lado JS.
/// Permite mostrar info en la pantalla de bloqueo, Control Center, auriculares, CarPlay.
@objc(AudioBridgePlugin)
public class AudioBridgePlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier  = "AudioBridgePlugin"
    public let jsName      = "AudioBridge"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "updateNowPlaying",    returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updatePlaybackState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearNowPlaying",     returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startKeepAlive",      returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopKeepAlive",       returnType: CAPPluginReturnPromise),
    ]

    private var commandCenterReady = false
    private var artworkTask: URLSessionDataTask?

    /// Diccionario local que mantiene el estado completo de Now Playing.
    /// Siempre escribir a este diccionario y publicar con publishInfo(),
    /// NUNCA leer del singleton MPNowPlayingInfoCenter.default().nowPlayingInfo
    /// (devuelve una copia que puede tener valores stale en escenarios async).
    private var localInfo: [String: Any] = [:]

    // MARK: - Native AVAudioPlayer keepalive
    // Mantiene AVAudioSession activa en background/pantalla bloqueada reproduciendo
    // silencio a nivel nativo. A diferencia del HTMLAudioElement anterior, un
    // AVAudioPlayer nativo NO es detectado por WKWebView como media elegible
    // para NowPlaying, así que no sobreescribe MPNowPlayingInfoCenter.
    private var keepAlivePlayer: AVAudioPlayer?
    private var keepAliveUrl: URL?

    // MARK: - JS-callable methods

    /// Actualiza la info de la canción en la pantalla de bloqueo / CarPlay.
    @objc func updateNowPlaying(_ call: CAPPluginCall) {
        let title      = call.getString("title")      ?? ""
        let artist     = call.getString("artist")     ?? ""
        let album      = call.getString("album")      ?? ""
        let duration   = call.getDouble("duration")   ?? 0
        let elapsed    = call.getDouble("elapsedTime") ?? 0
        let isPlaying  = call.getBool("isPlaying")     ?? true
        let artworkUrl = call.getString("artworkUrl")

        let rate: Double = isPlaying ? 1.0 : 0.0

        // Actualizar diccionario local (preserva artwork si ya existe)
        localInfo[MPMediaItemPropertyTitle]                    = title
        localInfo[MPMediaItemPropertyArtist]                   = artist
        localInfo[MPMediaItemPropertyAlbumTitle]               = album
        localInfo[MPMediaItemPropertyPlaybackDuration]         = duration
        localInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        localInfo[MPNowPlayingInfoPropertyPlaybackRate]        = rate

        setupCommandCenter()
        publishInfo()
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused

        // Descargar artwork nuevo en background y mergear en diccionario local.
        if let urlStr = artworkUrl, let url = URL(string: urlStr) {
            artworkTask?.cancel()
            artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self = self,
                      let data = data,
                      let image = UIImage(data: data) else {
                    self?.artworkTask = nil
                    return
                }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                DispatchQueue.main.async {
                    self.localInfo[MPMediaItemPropertyArtwork] = artwork
                    self.publishInfo()
                    self.artworkTask = nil
                }
            }
            artworkTask?.resume()
        }

        call.resolve()
    }

    /// Actualiza el estado play/pause y el tiempo transcurrido (barra de progreso en pantalla bloqueo).
    @objc func updatePlaybackState(_ call: CAPPluginCall) {
        let isPlaying = call.getBool("isPlaying") ?? false
        let elapsed   = call.getDouble("elapsedTime") ?? 0

        localInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        localInfo[MPNowPlayingInfoPropertyPlaybackRate]        = isPlaying ? 1.0 : 0.0
        publishInfo()
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused

        call.resolve()
    }

    /// Limpia la info de Now Playing (cuando no hay canción activa).
    @objc func clearNowPlaying(_ call: CAPPluginCall) {
        artworkTask?.cancel()
        localInfo = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        call.resolve()
    }

    // MARK: - Keepalive (AVAudioPlayer nativo)

    /// Arranca el keepalive nativo. JS debe llamar esto ANTES de cualquier await
    /// en play() para que el gesto de usuario siga activo.
    @objc func startKeepAlive(_ call: CAPPluginCall) {
        if keepAlivePlayer?.isPlaying == true {
            call.resolve()
            return
        }

        do {
            // Asegurar sesión activa con categoría playback
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default,
                                    options: [.allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true)

            // Generar WAV silencioso de 1 segundo en un fichero temporal
            if keepAliveUrl == nil {
                keepAliveUrl = createSilentWavFile()
            }

            guard let url = keepAliveUrl else {
                print("[AudioBridge] No se pudo crear fichero WAV silencioso")
                call.resolve()
                return
            }

            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1 // loop infinito
            player.volume = 0.01      // volumen mínimo (0 podría no activar sesión)
            player.prepareToPlay()
            player.play()
            keepAlivePlayer = player
            print("[AudioBridge] Keepalive nativo arrancado")
        } catch {
            print("[AudioBridge] Error arrancando keepalive: \(error)")
        }

        call.resolve()
    }

    /// Detiene el keepalive nativo. Solo llamar al destruir el player.
    @objc func stopKeepAlive(_ call: CAPPluginCall) {
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
        print("[AudioBridge] Keepalive nativo detenido")
        call.resolve()
    }

    /// Genera un fichero WAV de 1 segundo de silencio en el directorio temporal.
    private func createSilentWavFile() -> URL? {
        let sampleRate: Int = 44100
        let numChannels: Int = 1
        let bitsPerSample: Int = 16
        let numSamples = sampleRate  // 1 segundo
        let dataSize = numSamples * numChannels * (bitsPerSample / 8)

        var buffer = Data(count: 44 + dataSize)

        // RIFF header
        buffer.replaceSubrange(0..<4,   with: "RIFF".data(using: .ascii)!)
        withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { buffer.replaceSubrange(4..<8, with: $0) }
        buffer.replaceSubrange(8..<12,  with: "WAVE".data(using: .ascii)!)

        // fmt chunk
        buffer.replaceSubrange(12..<16, with: "fmt ".data(using: .ascii)!)
        withUnsafeBytes(of: UInt32(16).littleEndian)                                         { buffer.replaceSubrange(16..<20, with: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian)                                          { buffer.replaceSubrange(20..<22, with: $0) } // PCM
        withUnsafeBytes(of: UInt16(numChannels).littleEndian)                                { buffer.replaceSubrange(22..<24, with: $0) }
        withUnsafeBytes(of: UInt32(sampleRate).littleEndian)                                 { buffer.replaceSubrange(24..<28, with: $0) }
        withUnsafeBytes(of: UInt32(sampleRate * numChannels * bitsPerSample / 8).littleEndian) { buffer.replaceSubrange(28..<32, with: $0) }
        withUnsafeBytes(of: UInt16(numChannels * bitsPerSample / 8).littleEndian)            { buffer.replaceSubrange(32..<34, with: $0) }
        withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian)                              { buffer.replaceSubrange(34..<36, with: $0) }

        // data chunk (bytes a 0 = silencio)
        buffer.replaceSubrange(36..<40, with: "data".data(using: .ascii)!)
        withUnsafeBytes(of: UInt32(dataSize).littleEndian) { buffer.replaceSubrange(40..<44, with: $0) }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audiorr_silence.wav")
        do {
            try buffer.write(to: url)
            return url
        } catch {
            print("[AudioBridge] Error escribiendo WAV silencioso: \(error)")
            return nil
        }
    }

    /// Publica el diccionario local como una escritura atómica al singleton.
    private func publishInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = localInfo
    }

    // MARK: - Remote Command Center

    /// Re-activa la AVAudioSession antes de despachar un comando remoto.
    /// Cuando el usuario pausa y bloquea la pantalla, iOS puede desactivar la
    /// sesión de audio; sin reactivarla, el play desde lock screen falla silenciosamente.
    private func ensureAudioSessionActive() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AudioBridge] Failed to reactivate AVAudioSession: \(error)")
        }
    }

    private func setupCommandCenter() {
        guard !commandCenterReady else { return }
        commandCenterReady = true

        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            self?.ensureAudioSessionActive()
            // Marcar como .playing inmediatamente para que iOS no retire el widget
            // mientras JS procesa el comando (WKWebView puede tener latencia)
            MPNowPlayingInfoCenter.default().playbackState = .playing
            self?.notifyListeners("remoteCommand", data: ["command": "play"])
            return .success
        }

        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            MPNowPlayingInfoCenter.default().playbackState = .paused
            self?.notifyListeners("remoteCommand", data: ["command": "pause"])
            return .success
        }

        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.ensureAudioSessionActive()
            // No cambiar playbackState aquí (no sabemos si va a play o pause).
            // JS lo actualizará via updatePlaybackState una vez procese el toggle.
            self?.notifyListeners("remoteCommand", data: ["command": "togglePlayPause"])
            return .success
        }

        cc.nextTrackCommand.isEnabled = true
        cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.ensureAudioSessionActive()
            self?.notifyListeners("remoteCommand", data: ["command": "next"])
            return .success
        }

        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { [weak self] _ in
            self?.ensureAudioSessionActive()
            self?.notifyListeners("remoteCommand", data: ["command": "previous"])
            return .success
        }

        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                self?.notifyListeners("remoteCommand", data: [
                    "command":  "seek",
                    "position": e.positionTime,
                ])
            }
            return .success
        }
    }
}
