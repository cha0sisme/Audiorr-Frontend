import Foundation
import UIKit
import Combine

// MARK: - SmartMix status (mirrors React's SmartMixStatus)

enum SmartMixStatus: String {
    case idle, analyzing, ready, error
}

/// Puente entre las vistas SwiftUI y AudioEngineManager.
/// Permite reproducir canciones directamente desde Swift sin pasar por JS/React.
///
/// AudioEngineManager.shared sigue enviando onTrackEnd / onTimeUpdate a JS vía
/// su plugin reference, por lo que React mantiene el control de la cola y el
/// mini-player nativo de AppDelegate se actualiza igual que siempre.
final class PlayerService {

    static let shared = PlayerService()
    private let api = NavidromeService.shared
    private init() {}

    // MARK: - SmartMix observable state

    /// Current SmartMix status for a given playlist (set by React via nativeSmartMixStatus).
    @Published private(set) var smartMixStatus: SmartMixStatus = .idle
    @Published private(set) var smartMixPlaylistId: String?

    // MARK: - Play

    /// Reproduce una canción desde una vista nativa.
    /// - Fast path: si el archivo está en caché local → AVAudioEngine instantáneo.
    /// - Streaming path: si no → AVPlayer arranca en ~500ms, descarga en background.
    @MainActor
    func play(song: NavidromeSong) {
        guard let streamURL = api.streamURL(songId: song.id) else {
            print("[PlayerService] No stream URL for song \(song.id)")
            return
        }

        let duration  = song.duration ?? 0
        let title     = song.title
        let artist    = song.artist
        let album     = song.album

        guard let engine = AudioEngineManager.shared else {
            print("[PlayerService] AudioEngineManager.shared is nil — Capacitor not loaded yet")
            return
        }

        // Fast path: archivo ya descargado
        if let cachedURL = AudioFileLoader.shared.cachedFileURL(for: song.id) {
            engine.play(
                fileURL: cachedURL,
                startAt: 0,
                replayGainMultiplier: 1.0,
                duration: duration,
                title: title,
                artist: artist,
                album: album
            )
        } else {
            // Streaming path
            engine.playStreaming(
                remoteURL: streamURL,
                startAt: 0,
                replayGainMultiplier: 1.0,
                duration: duration,
                title: title,
                artist: artist,
                album: album
            )
            // Descargar en background para cachear
            Task {
                guard let fileURL = try? await AudioFileLoader.shared.load(
                    remoteURL: streamURL,
                    songId: song.id
                ) else { return }
                await MainActor.run {
                    guard engine.isStreamMode else { return }
                    engine.handoffStreamToEngine(fileURL: fileURL)
                }
            }
        }

        // Guardar en NowPlayingState directamente
        NowPlayingState.shared.setQueue(songs: [song], startIndex: 0)

        // Notificar a React para que PlayerContext y el mini-player estén sincronizados
        notifyReact(song: song, streamURL: streamURL)
    }

    /// Reproduce una lista de canciones completa, empezando por `startingAt`.
    @MainActor
    func playPlaylist(_ songs: [NavidromeSong], startingAt index: Int = 0) {
        guard index < songs.count else { return }

        // Guardar cola nativamente — el viewer la lee directamente
        NowPlayingState.shared.setQueue(songs: songs, startIndex: index)

        // Notificar a React la cola completa para que gestione crossfade y next/prev
        let songsJSON = songs.enumerated().map { i, s in
            let esc: (String) -> String = { str in
                str.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "'", with: "\\'")
            }
            let url = api.streamURL(songId: s.id)?.absoluteString ?? ""
            return """
            {id:'\(esc(s.id))',title:'\(esc(s.title))',artist:'\(esc(s.artist))',\
            artistId:'\(esc(s.artistId ?? ""))',album:'\(esc(s.album))',albumId:'\(esc(s.albumId ?? ""))',\
            coverArt:'\(esc(s.coverArt ?? ""))',duration:\(s.duration ?? 0),path:'\(esc(url))'}
            """
        }.joined(separator: ",")

        let js = """
        window.dispatchEvent(new CustomEvent('_swiftPlayPlaylist', {
            detail: { songs: [\(songsJSON)], startIndex: \(index) }
        }));
        """
        DispatchQueue.main.async {
            JSBridge.shared.eval(js)
        }
    }

    // MARK: - React sync

    /// Despacha un evento JS que PlayerContext.tsx escucha para actualizar su estado
    /// (cola, mini-player, etc.) sin que React tenga que gestionar el audio real.
    private func notifyReact(song: NavidromeSong, streamURL: URL) {
        let coverArt = song.coverArt ?? ""
        let duration = song.duration ?? 0
        let albumId  = song.albumId  ?? ""

        // Escapa los strings para JSON seguro
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "'",  with: "\\'")
        }

        let artistId = song.artistId ?? ""

        let js = """
        window.dispatchEvent(new CustomEvent('_swiftPlaySong', { detail: {
            id:       '\(esc(song.id))',
            title:    '\(esc(song.title))',
            artist:   '\(esc(song.artist))',
            artistId: '\(esc(artistId))',
            album:    '\(esc(song.album))',
            albumId:  '\(esc(albumId))',
            coverArt: '\(esc(coverArt))',
            duration: \(duration),
            url:      '\(streamURL.absoluteString)'
        }}));
        """

        DispatchQueue.main.async {
            JSBridge.shared.eval(js)
        }
    }

    // MARK: - Queue operations

    /// Inserta la canción inmediatamente después de la actual en la cola de React.
    @MainActor
    func insertNext(_ song: NavidromeSong) {
        guard let url = api.streamURL(songId: song.id) else { return }
        let js = songEventJS(song: song, url: url, eventName: "_swiftInsertNext")
        DispatchQueue.main.async {
            JSBridge.shared.eval(js)
        }
    }

    /// Añade la canción al final de la cola de React.
    @MainActor
    func addToQueue(_ song: NavidromeSong) {
        guard let url = api.streamURL(songId: song.id) else { return }
        let js = songEventJS(song: song, url: url, eventName: "_swiftAddToQueue")
        DispatchQueue.main.async {
            JSBridge.shared.eval(js)
        }
    }

    private func songEventJS(song: NavidromeSong, url: URL, eventName: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "'",  with: "\\'")
        }
        return """
        window.dispatchEvent(new CustomEvent('\(eventName)', { detail: {
            id:       '\(esc(song.id))',
            title:    '\(esc(song.title))',
            artist:   '\(esc(song.artist))',
            artistId: '\(esc(song.artistId ?? ""))',
            album:    '\(esc(song.album))',
            albumId:  '\(esc(song.albumId ?? ""))',
            coverArt: '\(esc(song.coverArt ?? ""))',
            duration: \(song.duration ?? 0),
            url:      '\(url.absoluteString)'
        }}));
        """
    }

    // MARK: - Toggle play/pause

    /// Despacha togglePlayPause a React.
    @MainActor
    func togglePlayPause() {
        let js = "window.dispatchEvent(new CustomEvent('_swiftTogglePlayPause'));"
        DispatchQueue.main.async {
            JSBridge.shared.eval(js)
        }
    }

    // MARK: - SmartMix bridge

    /// Pide a React que genere la SmartMix para una playlist.
    @MainActor
    func generateSmartMix(playlistId: String, songs: [NavidromeSong]) {
        let songsJSON = songs.map { s in
            let esc: (String) -> String = { str in
                str.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "'", with: "\\'")
            }
            let url = api.streamURL(songId: s.id)?.absoluteString ?? ""
            return """
            {id:'\(esc(s.id))',title:'\(esc(s.title))',artist:'\(esc(s.artist))',\
            artistId:'\(esc(s.artistId ?? ""))',album:'\(esc(s.album))',albumId:'\(esc(s.albumId ?? ""))',\
            coverArt:'\(esc(s.coverArt ?? ""))',duration:\(s.duration ?? 0),path:'\(esc(url))'}
            """
        }.joined(separator: ",")

        let js = """
        window.dispatchEvent(new CustomEvent('_swiftGenerateSmartMix', {
            detail: { playlistId: '\(playlistId)', songs: [\(songsJSON)] }
        }));
        """
        smartMixPlaylistId = playlistId
        smartMixStatus = .analyzing

        DispatchQueue.main.async {
            JSBridge.shared.eval(js)
        }
    }

    /// Pide a React que reproduzca la SmartMix ya generada.
    @MainActor
    func playSmartMix(playlistId: String) {
        let js = """
        window.dispatchEvent(new CustomEvent('_swiftPlaySmartMix', {
            detail: { playlistId: '\(playlistId)' }
        }));
        """
        DispatchQueue.main.async {
            JSBridge.shared.eval(js)
        }
    }

    /// Called from AppDelegate when React reports SmartMix status change.
    func updateSmartMixStatus(playlistId: String, status: String) {
        DispatchQueue.main.async {
            self.smartMixPlaylistId = playlistId
            self.smartMixStatus = SmartMixStatus(rawValue: status) ?? .idle
        }
    }
}
