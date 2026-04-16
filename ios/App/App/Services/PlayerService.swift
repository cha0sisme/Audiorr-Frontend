import Foundation
import UIKit

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

        // Notificar a React para que PlayerContext y el mini-player estén sincronizados
        notifyReact(song: song, streamURL: streamURL)
    }

    /// Reproduce una lista de canciones completa, empezando por `startingAt`.
    @MainActor
    func playPlaylist(_ songs: [NavidromeSong], startingAt index: Int = 0) {
        guard index < songs.count else { return }
        // Notificar a React la cola completa para que gestione crossfade y next/prev
        let songsJSON = songs.enumerated().map { i, s in
            let esc: (String) -> String = { str in
                str.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "'", with: "\\'")
            }
            let url = api.streamURL(songId: s.id)?.absoluteString ?? ""
            return """
            {id:'\(esc(s.id))',title:'\(esc(s.title))',artist:'\(esc(s.artist))',\
            album:'\(esc(s.album))',albumId:'\(esc(s.albumId ?? ""))',\
            coverArt:'\(esc(s.coverArt ?? ""))',duration:\(s.duration ?? 0),path:'\(esc(url))'}
            """
        }.joined(separator: ",")

        let js = """
        window.dispatchEvent(new CustomEvent('_swiftPlayPlaylist', {
            detail: { songs: [\(songsJSON)], startIndex: \(index) }
        }));
        """
        DispatchQueue.main.async {
            guard let app = UIApplication.shared.delegate as? AppDelegate else { return }
            app.evalJSPublic(js)
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

        let js = """
        window.dispatchEvent(new CustomEvent('_swiftPlaySong', { detail: {
            id:       '\(esc(song.id))',
            title:    '\(esc(song.title))',
            artist:   '\(esc(song.artist))',
            album:    '\(esc(song.album))',
            albumId:  '\(esc(albumId))',
            coverArt: '\(esc(coverArt))',
            duration: \(duration),
            url:      '\(streamURL.absoluteString)'
        }}));
        """

        DispatchQueue.main.async {
            guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
            appDelegate.evalJSPublic(js)
        }
    }
}
