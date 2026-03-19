import Foundation
import Capacitor
import MediaPlayer
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

    // MARK: - JS-callable methods

    /// Actualiza la info de la canción en la pantalla de bloqueo / CarPlay.
    @objc func updateNowPlaying(_ call: CAPPluginCall) {
        let title      = call.getString("title")      ?? ""
        let artist     = call.getString("artist")     ?? ""
        let album      = call.getString("album")      ?? ""
        let duration   = call.getDouble("duration")   ?? 0
        let elapsed    = call.getDouble("elapsedTime") ?? 0
        let artworkUrl = call.getString("artworkUrl")

        let info: [String: Any] = [
            MPMediaItemPropertyTitle:                    title,
            MPMediaItemPropertyArtist:                   artist,
            MPMediaItemPropertyAlbumTitle:               album,
            MPMediaItemPropertyPlaybackDuration:         duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate:        1.0,
        ]

        setupCommandCenter()

        if let urlStr = artworkUrl, let url = URL(string: urlStr) {
            artworkTask?.cancel()
            var capturedInfo = info
            artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                if let data = data, let image = UIImage(data: data) {
                    capturedInfo[MPMediaItemPropertyArtwork] =
                        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                }
                DispatchQueue.main.async {
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = capturedInfo
                    self?.artworkTask = nil
                }
            }
            artworkTask?.resume()
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }

        call.resolve()
    }

    /// Actualiza el estado play/pause y el tiempo transcurrido (barra de progreso en pantalla bloqueo).
    @objc func updatePlaybackState(_ call: CAPPluginCall) {
        let isPlaying = call.getBool("isPlaying") ?? false
        let elapsed   = call.getDouble("elapsedTime") ?? 0

        if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
            info[MPNowPlayingInfoPropertyPlaybackRate]        = isPlaying ? 1.0 : 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo   = info
        }
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused

        call.resolve()
    }

    /// Limpia la info de Now Playing (cuando no hay canción activa).
    @objc func clearNowPlaying(_ call: CAPPluginCall) {
        artworkTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        call.resolve()
    }

    // MARK: - Remote Command Center

    private func setupCommandCenter() {
        guard !commandCenterReady else { return }
        commandCenterReady = true

        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            self?.notifyListeners("remoteCommand", data: ["command": "play"])
            return .success
        }

        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            self?.notifyListeners("remoteCommand", data: ["command": "pause"])
            return .success
        }

        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.notifyListeners("remoteCommand", data: ["command": "togglePlayPause"])
            return .success
        }

        cc.nextTrackCommand.isEnabled = true
        cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.notifyListeners("remoteCommand", data: ["command": "next"])
            return .success
        }

        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { [weak self] _ in
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
