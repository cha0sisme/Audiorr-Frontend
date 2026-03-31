import Foundation
import Capacitor
import AVFoundation

/// Plugin Capacitor que conecta JS con AudioEngineManager para reproducción nativa.
/// Reemplaza WebAudio API y elimina la dependencia de WKWebView para audio.
@objc(NativeAudioPlugin)
public class NativeAudioPlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "NativeAudioPlugin"
    public let jsName = "NativeAudio"
    public let pluginMethods: [CAPPluginMethod] = [
        // Fase 1: Reproducción
        CAPPluginMethod(name: "play",              returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pause",             returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resume",            returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "seek",              returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop",              returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setVolume",         returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getCurrentTime",    returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getClockSync",      returnType: CAPPluginReturnPromise),
        // Fase 2: Crossfade
        CAPPluginMethod(name: "prepareNext",       returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "executeCrossfade",  returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelCrossfade",   returnType: CAPPluginReturnPromise),
        // Metadata
        CAPPluginMethod(name: "updateNowPlaying",  returnType: CAPPluginReturnPromise),
        // Cache
        CAPPluginMethod(name: "clearCache",        returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isCached",          returnType: CAPPluginReturnPromise),
        // Background automix & state
        CAPPluginMethod(name: "setAutomixTrigger", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearAutomixTrigger", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setNextSongMetadata", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPlaybackState",  returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "ackRemoteCommand",  returnType: CAPPluginReturnPromise),
    ]

    private lazy var audioManager: AudioEngineManager = {
        let mgr = AudioEngineManager()
        mgr.plugin = self
        return mgr
    }()

    // MARK: - Fase 1: Reproducción

    /// Descarga el audio (o lo toma de caché) y lo reproduce.
    /// Params: url (string), songId (string), startAt (double), replayGainDb (double),
    ///         trackPeak (double), duration (double)
    @objc func play(_ call: CAPPluginCall) {
        guard let urlStr = call.getString("url"),
              let remoteURL = URL(string: urlStr),
              let songId = call.getString("songId")
        else {
            call.reject("Missing url or songId")
            return
        }

        let startAt = call.getDouble("startAt") ?? 0
        let replayGainDb = call.getDouble("replayGainDb") ?? Double.nan
        let trackPeak = call.getDouble("trackPeak") ?? 0
        let duration = call.getDouble("duration") ?? 0
        let title = call.getString("title")
        let artist = call.getString("artist")
        let album = call.getString("album")

        let rgMultiplier = AudioEngineManager.computeReplayGainMultiplier(gainDb: replayGainDb, trackPeak: trackPeak)

        Task {
            do {
                let fileURL = try await AudioFileLoader.shared.load(remoteURL: remoteURL, songId: songId)
                await MainActor.run {
                    self.audioManager.play(
                        fileURL: fileURL,
                        startAt: startAt,
                        replayGainMultiplier: rgMultiplier,
                        duration: duration,
                        title: title,
                        artist: artist,
                        album: album
                    )
                    call.resolve()
                }
            } catch {
                if (error as? URLError)?.code == .cancelled {
                    call.resolve() // Cancelación no es un error
                } else {
                    call.reject("Download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc func pause(_ call: CAPPluginCall) {
        audioManager.pause()
        call.resolve()
    }

    @objc func resume(_ call: CAPPluginCall) {
        audioManager.resume()
        call.resolve()
    }

    @objc func seek(_ call: CAPPluginCall) {
        let time = call.getDouble("time") ?? 0
        audioManager.seek(to: time)
        call.resolve()
    }

    @objc func stop(_ call: CAPPluginCall) {
        AudioFileLoader.shared.cancelAllDownloads()
        audioManager.stop()
        call.resolve()
    }

    @objc func setVolume(_ call: CAPPluginCall) {
        let volume = call.getFloat("volume") ?? 0.75
        audioManager.setVolume(volume)
        call.resolve()
    }

    // MARK: - Tiempo y sincronización

    @objc func getCurrentTime(_ call: CAPPluginCall) {
        call.resolve([
            "currentTime": audioManager.currentTime(),
        ])
    }

    /// Clock sync: devuelve tiempo nativo + timestamp epoch para que JS calibre offset.
    @objc func getClockSync(_ call: CAPPluginCall) {
        let nativeTime = audioManager.currentTime()
        let timestamp = Date().timeIntervalSince1970 * 1000 // epoch ms, compatible con Date.now()
        call.resolve([
            "nativeTime": nativeTime,
            "timestamp": timestamp,
        ])
    }

    // MARK: - Fase 2: Crossfade

    /// Pre-descarga la siguiente canción.
    /// Params: url (string), songId (string), replayGainDb (double), trackPeak (double)
    @objc func prepareNext(_ call: CAPPluginCall) {
        guard let urlStr = call.getString("url"),
              let remoteURL = URL(string: urlStr),
              let songId = call.getString("songId")
        else {
            call.reject("Missing url or songId")
            return
        }

        let replayGainDb = call.getDouble("replayGainDb") ?? Double.nan
        let trackPeak = call.getDouble("trackPeak") ?? 0
        let rgMultiplier = AudioEngineManager.computeReplayGainMultiplier(gainDb: replayGainDb, trackPeak: trackPeak)

        Task {
            do {
                let fileURL = try await AudioFileLoader.shared.load(remoteURL: remoteURL, songId: songId)
                await MainActor.run {
                    self.audioManager.prepareNext(fileURL: fileURL, replayGainMultiplier: rgMultiplier)
                    call.resolve()
                }
            } catch {
                if (error as? URLError)?.code == .cancelled {
                    call.resolve()
                } else {
                    call.reject("Preload failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Ejecuta crossfade con la configuración calculada por DJMixingAlgorithms en JS.
    /// Params: entryPoint, fadeDuration, transitionType, useFilters, useAggressiveFilters,
    ///         needsAnticipation, anticipationTime, nextTitle
    @objc func executeCrossfade(_ call: CAPPluginCall) {
        let entryPoint = call.getDouble("entryPoint") ?? 0
        let fadeDuration = call.getDouble("fadeDuration") ?? 6.0
        let transitionTypeStr = call.getString("transitionType") ?? "CROSSFADE"
        let useFilters = call.getBool("useFilters") ?? true
        let useAggressiveFilters = call.getBool("useAggressiveFilters") ?? false
        let needsAnticipation = call.getBool("needsAnticipation") ?? false
        let anticipationTime = call.getDouble("anticipationTime") ?? 0

        let transitionType = CrossfadeExecutor.TransitionType(rawValue: transitionTypeStr) ?? .crossfade

        let config = CrossfadeExecutor.Config(
            entryPoint: entryPoint,
            fadeDuration: fadeDuration,
            transitionType: transitionType,
            useFilters: useFilters,
            useAggressiveFilters: useAggressiveFilters,
            needsAnticipation: needsAnticipation,
            anticipationTime: anticipationTime
        )

        let result = audioManager.executeCrossfade(config: config)
        switch result {
        case .started:
            call.resolve()
        case .noNextFile:
            call.reject("NO_NEXT_FILE", "No next file prepared for crossfade", nil)
        case .alreadyCrossfading:
            call.reject("ALREADY_CROSSFADING", "Crossfade already in progress", nil)
        }
    }

    @objc func cancelCrossfade(_ call: CAPPluginCall) {
        audioManager.cancelCrossfade()
        call.resolve()
    }

    // MARK: - Metadata

    /// Actualiza NowPlaying metadata (título, artista, album, artwork).
    /// Progress se actualiza directamente desde Swift a 4Hz — no necesita JS.
    @objc func updateNowPlaying(_ call: CAPPluginCall) {
        let title = call.getString("title") ?? ""
        let artist = call.getString("artist") ?? ""
        let album = call.getString("album") ?? ""
        let duration = call.getDouble("duration") ?? 0
        let artworkUrl = call.getString("artworkUrl")

        audioManager.updateNowPlayingMetadata(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            artworkUrl: artworkUrl
        )
        call.resolve()
    }

    // MARK: - Cache

    @objc func clearCache(_ call: CAPPluginCall) {
        AudioFileLoader.shared.cancelAllDownloads()
        AudioFileLoader.shared.clearCache()
        call.resolve()
    }

    @objc func isCached(_ call: CAPPluginCall) {
        guard let songId = call.getString("songId") else {
            call.reject("Missing songId")
            return
        }
        call.resolve(["cached": AudioFileLoader.shared.isCached(songId)])
    }

    // MARK: - Background Automix & State

    /// JS envía el trigger time y la config de crossfade calculada por DJMixingAlgorithms.
    /// Si JS se congela en background, el timer nativo dispara el crossfade autónomamente.
    @objc func setAutomixTrigger(_ call: CAPPluginCall) {
        let triggerTime = call.getDouble("triggerTime") ?? 0
        let entryPoint = call.getDouble("entryPoint") ?? 0
        let fadeDuration = call.getDouble("fadeDuration") ?? 6.0
        let transitionTypeStr = call.getString("transitionType") ?? "CROSSFADE"
        let useFilters = call.getBool("useFilters") ?? true
        let useAggressiveFilters = call.getBool("useAggressiveFilters") ?? false
        let needsAnticipation = call.getBool("needsAnticipation") ?? false
        let anticipationTime = call.getDouble("anticipationTime") ?? 0

        let transitionType = CrossfadeExecutor.TransitionType(rawValue: transitionTypeStr) ?? .crossfade
        let config = CrossfadeExecutor.Config(
            entryPoint: entryPoint,
            fadeDuration: fadeDuration,
            transitionType: transitionType,
            useFilters: useFilters,
            useAggressiveFilters: useAggressiveFilters,
            needsAnticipation: needsAnticipation,
            anticipationTime: anticipationTime
        )

        audioManager.setAutomixTrigger(triggerTime: triggerTime, config: config)
        call.resolve()
    }

    @objc func clearAutomixTrigger(_ call: CAPPluginCall) {
        audioManager.clearAutomixTrigger()
        call.resolve()
    }

    /// Almacena metadata de la siguiente canción para NowPlaying en background
    @objc func setNextSongMetadata(_ call: CAPPluginCall) {
        let title = call.getString("title") ?? ""
        let artist = call.getString("artist") ?? ""
        let album = call.getString("album") ?? ""
        let duration = call.getDouble("duration") ?? 0

        audioManager.setNextSongMetadata(title: title, artist: artist, album: album, duration: duration)
        call.resolve()
    }

    /// Devuelve estado completo de reproducción para reconciliación tras background
    @objc func getPlaybackState(_ call: CAPPluginCall) {
        call.resolve(audioManager.getFullState())
    }

    /// JS llama esto al procesar un onRemoteCommand para cancelar el fallback nativo
    @objc func ackRemoteCommand(_ call: CAPPluginCall) {
        audioManager.cancelNativeNextFallback()
        call.resolve()
    }
}
