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
    ]

    private var commandCenterReady = false
    private var artworkTask: URLSessionDataTask?

    /// Diccionario local que mantiene el estado completo de Now Playing.
    /// Siempre escribir a este diccionario y publicar con publishInfo(),
    /// NUNCA leer del singleton MPNowPlayingInfoCenter.default().nowPlayingInfo
    /// (devuelve una copia que puede tener valores stale en escenarios async).
    private var localInfo: [String: Any] = [:]

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
