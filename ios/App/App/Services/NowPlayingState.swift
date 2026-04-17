import Foundation
import SwiftUI

/// Canción ligera para la cola del viewer.
struct QueueSong: Identifiable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let albumId: String
    let coverArt: String
    let duration: Double

    init(from dict: [String: Any]) {
        id       = dict["id"]       as? String ?? ""
        title    = dict["title"]    as? String ?? ""
        artist   = dict["artist"]   as? String ?? ""
        album    = dict["album"]    as? String ?? ""
        albumId  = dict["albumId"]  as? String ?? ""
        coverArt = dict["coverArt"] as? String ?? ""
        duration = dict["duration"] as? Double ?? 0
    }

    init(from song: NavidromeSong) {
        id       = song.id
        title    = song.title
        artist   = song.artist
        album    = song.album
        albumId  = song.albumId ?? ""
        coverArt = song.coverArt ?? ""
        duration = song.duration ?? 0
    }
}

/// Estado observable del mini player y viewer.
/// Fuente de verdad para la UI — actualizado desde el JS bridge + resolución nativa.
@MainActor @Observable
final class NowPlayingState {
    static let shared = NowPlayingState()

    // ── Mini player (actualizados por nativeUpdateNowPlaying) ───────────
    var title = ""
    var artist = ""
    var artworkUrl: String?
    var isPlaying = false
    var progress: Double = 0
    var duration: Double = 1
    var isVisible = false
    var subtitle: String?
    var viewerIsOpen = false

    // ── Viewer (resueltos nativamente via NavidromeService) ─────────────
    var songId = ""
    var albumId = ""
    var artistId = ""
    var coverArt = ""
    var queue: [QueueSong] = []
    var shuffleMode = false
    var repeatMode = "off"     // "off", "all", "one"
    var isCrossfading = false

    // ── Multidevice / Audiorr Hub ──────────────────────────────────────
    var isRemote = false
    var remoteDeviceName: String?

    // ── Navegación desde el viewer ─────────────────────────────────────
    enum NavigationRequest: Equatable {
        case album(id: String)
        case artist(id: String, name: String)
    }
    var pendingNavigation: NavigationRequest?

    // ── Resolución nativa de metadatos ─────────────────────────────────
    private var lastResolvedTitle = ""
    private var resolveTask: Task<Void, Never>?

    private init() {}

    /// Actualiza estado básico desde nativeUpdateNowPlaying (mini player + progress).
    func update(from body: [String: Any]) {
        let newTitle  = body["title"]  as? String ?? ""
        let newArtist = body["artist"] as? String ?? ""

        title      = newTitle
        artist     = newArtist
        artworkUrl = body["artworkUrl"] as? String
        isPlaying  = body["isPlaying"] as? Bool   ?? false
        progress   = body["progress"]  as? Double ?? 0
        duration   = body["duration"]  as? Double ?? 1
        isVisible  = body["isVisible"] as? Bool   ?? true
        subtitle   = body["subtitle"]  as? String

        // IDs from React (if available — belt & suspenders)
        if let s = body["songId"] as? String, !s.isEmpty   { songId = s }
        if let a = body["albumId"] as? String, !a.isEmpty  { albumId = a }
        if let a = body["artistId"] as? String, !a.isEmpty { artistId = a }
        if let c = body["coverArt"] as? String, !c.isEmpty { coverArt = c }

        // Resolve metadata natively when song changes
        if !newTitle.isEmpty && newTitle != lastResolvedTitle {
            lastResolvedTitle = newTitle
            resolveMetadata(title: newTitle, artist: newArtist)
        }

        // Sync tema
        if let isDark = body["isDark"] as? Bool, AppTheme.shared.isDark != isDark {
            AppTheme.shared.isDark = isDark
        }
    }

    /// Actualiza estado enriquecido desde nativeUpdateViewerState (viewer completo).
    /// Fallback — si React logra enviar este mensaje, lo usamos.
    func updateViewerState(from body: [String: Any]) {
        if let s = body["songId"] as? String, !s.isEmpty    { songId = s }
        if let a = body["albumId"] as? String, !a.isEmpty   { albumId = a }
        if let a = body["artistId"] as? String, !a.isEmpty  { artistId = a }
        if let c = body["coverArt"] as? String, !c.isEmpty  { coverArt = c }

        shuffleMode   = body["shuffle"]   as? Bool   ?? shuffleMode
        repeatMode    = body["repeat"]    as? String ?? repeatMode
        isCrossfading = body["isCrossfading"] as? Bool ?? isCrossfading
        isRemote      = body["isRemote"]  as? Bool   ?? isRemote
        remoteDeviceName = body["remoteDeviceName"] as? String

        if let queueArray = body["queue"] as? [[String: Any]], !queueArray.isEmpty {
            queue = queueArray.map { QueueSong(from: $0) }
        }
    }

    func hide() {
        isVisible = false
    }

    // MARK: - Cola nativa

    /// Establece la cola desde Swift (sin depender del bridge JS).
    func setQueue(songs: [NavidromeSong], startIndex: Int = 0) {
        queue = songs.map { QueueSong(from: $0) }

        // También actualizamos los IDs del song actual
        if startIndex < songs.count {
            let current = songs[startIndex]
            songId   = current.id
            albumId  = current.albumId ?? ""
            artistId = current.artistId ?? ""
            coverArt = current.coverArt ?? ""
        }
    }

    /// Sincroniza la cola leyendo desde localStorage de React (siempre disponible).
    /// Fallback a window.__nativeQueue si localStorage no tiene datos.
    func syncQueueFromJS() {
        Task {
            do {
                guard let webView = JSBridge.shared.webView else {
                    print("[NowPlayingState] syncQueueFromJS: webView is nil")
                    return
                }

                // Leer cola de localStorage (persistida por React — siempre disponible)
                let js = """
                (function() {
                    var keys = Object.keys(localStorage).filter(function(k) { return k.indexOf('playerQueue') === 0; });
                    if (keys.length > 0) return localStorage.getItem(keys[0]);
                    return JSON.stringify(window.__nativeQueue || []);
                })()
                """
                let result = try await webView.evaluateJavaScript(js)
                guard let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                else {
                    print("[NowPlayingState] syncQueueFromJS: parse failed")
                    return
                }
                print("[NowPlayingState] syncQueueFromJS: got \(array.count) songs")
                if !array.isEmpty {
                    queue = array.map { QueueSong(from: $0) }
                }
            } catch {
                print("[NowPlayingState] syncQueueFromJS error: \(error)")
            }
        }
    }

    // MARK: - Resolución nativa de metadatos

    /// Busca la canción en Navidrome por título y rellena songId, albumId, artistId, coverArt.
    private func resolveMetadata(title: String, artist: String) {
        resolveTask?.cancel()
        resolveTask = Task {
            do {
                let results = try await NavidromeService.shared.searchAll(
                    query: title, artistCount: 0, albumCount: 0, songCount: 10
                )
                guard !Task.isCancelled else { return }

                // Find best match: exact title + artist match
                let match = results.songs.first { song in
                    song.title.localizedCaseInsensitiveCompare(title) == .orderedSame &&
                    song.artist.localizedCaseInsensitiveCompare(artist) == .orderedSame
                } ?? results.songs.first { song in
                    song.title.localizedCaseInsensitiveCompare(title) == .orderedSame
                }

                guard let song = match else { return }

                // Only update if still the same song (title hasn't changed while we fetched)
                guard self.title == title else { return }

                self.songId   = song.id
                self.albumId  = song.albumId ?? ""
                self.artistId = song.artistId ?? ""
                self.coverArt = song.coverArt ?? ""

                print("[NowPlayingState] resolved: '\(title)' → songId=\(song.id) albumId=\(song.albumId ?? "") artistId=\(song.artistId ?? "") coverArt=\(String(song.coverArt?.prefix(20) ?? ""))")
            } catch {
                print("[NowPlayingState] resolve failed for '\(title)': \(error)")
            }
        }
    }
}
