import Foundation
import SwiftData

/// Queries SwiftData for offline browsing — cached albums, playlists, songs, and search.
actor OfflineContentProvider {

    static let shared = OfflineContentProvider()

    private let context: ModelContext

    private init() {
        self.context = ModelContext(OfflineStorageManager.modelContainer)
        self.context.autosaveEnabled = true
    }

    // MARK: - Save Metadata

    /// Save playlist metadata when user downloads a playlist.
    func savePlaylistMeta(playlist: NavidromePlaylist, songs: [NavidromeSong]) {
        let songIds = songs.map(\.id)
        let existing = fetchPlaylistMeta(id: playlist.id)
        if let existing {
            existing.name = playlist.name
            existing.owner = playlist.owner ?? ""
            existing.songCount = playlist.songCount
            existing.duration = playlist.duration
            existing.coverArt = playlist.coverArt ?? ""
            existing.songIdsJSON = (try? String(data: JSONEncoder().encode(songIds), encoding: .utf8)) ?? "[]"
            existing.cachedAt = Date()
        } else {
            let meta = CachedPlaylistMeta(
                playlistId: playlist.id, name: playlist.name,
                owner: playlist.owner ?? "", songCount: playlist.songCount,
                duration: playlist.duration, coverArt: playlist.coverArt ?? "",
                isAlbum: false, songIds: songIds
            )
            context.insert(meta)
        }
        try? context.save()
    }

    /// Save album metadata when user downloads an album.
    func saveAlbumMeta(album: NavidromeAlbum, songs: [NavidromeSong]) {
        let songIds = songs.map(\.id)
        let existing = fetchPlaylistMeta(id: album.id)
        if let existing {
            existing.name = album.name
            existing.artist = album.artist
            existing.songCount = songs.count
            existing.coverArt = album.coverArt ?? ""
            existing.year = album.year
            existing.isAlbum = true
            existing.songIdsJSON = (try? String(data: JSONEncoder().encode(songIds), encoding: .utf8)) ?? "[]"
            existing.cachedAt = Date()
        } else {
            let meta = CachedPlaylistMeta(
                playlistId: album.id, name: album.name,
                songCount: songs.count, coverArt: album.coverArt ?? "",
                isAlbum: true, artist: album.artist, year: album.year,
                songIds: songIds
            )
            context.insert(meta)
        }
        try? context.save()
    }

    // MARK: - Query: Albums

    /// All albums that have at least one cached song.
    func cachedAlbums() -> [(albumId: String, name: String, artist: String, coverArt: String, songCount: Int, year: Int?)] {
        let descriptor = FetchDescriptor<CachedSong>(
            predicate: #Predicate { $0.downloadState == "completed" }
        )
        guard let songs = try? context.fetch(descriptor) else { return [] }

        // Group by albumId
        var albums: [String: (name: String, artist: String, coverArt: String, count: Int, year: Int?)] = [:]
        for song in songs {
            guard !song.albumId.isEmpty else { continue }
            if var existing = albums[song.albumId] {
                existing.count += 1
                albums[song.albumId] = existing
            } else {
                // Try to get year from CachedPlaylistMeta
                let meta = fetchPlaylistMeta(id: song.albumId)
                albums[song.albumId] = (
                    name: song.album,
                    artist: song.artist,
                    coverArt: song.coverArt,
                    count: 1,
                    year: meta?.year
                )
            }
        }

        return albums.map { (albumId: $0.key, name: $0.value.name, artist: $0.value.artist,
                             coverArt: $0.value.coverArt, songCount: $0.value.count, year: $0.value.year) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// All cached playlists (from CachedPlaylistMeta where isAlbum == false).
    func cachedPlaylists() -> [CachedPlaylistMeta] {
        let descriptor = FetchDescriptor<CachedPlaylistMeta>(
            predicate: #Predicate { $0.isAlbum == false },
            sortBy: [SortDescriptor(\CachedPlaylistMeta.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Query: Songs

    /// All cached songs for a given album.
    func cachedSongs(albumId: String) -> [CachedSong] {
        let descriptor = FetchDescriptor<CachedSong>(
            predicate: #Predicate { $0.albumId == albumId && $0.downloadState == "completed" },
            sortBy: [SortDescriptor(\CachedSong.title)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Cached songs for a playlist (using stored song order from CachedPlaylistMeta).
    func cachedSongs(playlistId: String) -> [CachedSong] {
        guard let meta = fetchPlaylistMeta(id: playlistId) else { return [] }
        let orderedIds = meta.songIds

        // Fetch all cached songs
        let descriptor = FetchDescriptor<CachedSong>(
            predicate: #Predicate { $0.downloadState == "completed" }
        )
        guard let allCached = try? context.fetch(descriptor) else { return [] }
        let songMap = Dictionary(uniqueKeysWithValues: allCached.map { ($0.songId, $0) })

        // Return in playlist order, skipping missing
        return orderedIds.compactMap { songMap[$0] }
    }

    /// All cached songs (for general browsing).
    func allCachedSongs() -> [CachedSong] {
        let descriptor = FetchDescriptor<CachedSong>(
            predicate: #Predicate { $0.downloadState == "completed" },
            sortBy: [SortDescriptor(\CachedSong.lastPlayedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Search

    /// Search cached songs by title, artist, or album.
    func search(query: String) -> [CachedSong] {
        let q = query.lowercased()
        let descriptor = FetchDescriptor<CachedSong>(
            predicate: #Predicate { $0.downloadState == "completed" }
        )
        guard let songs = try? context.fetch(descriptor) else { return [] }
        return songs.filter {
            $0.title.localizedCaseInsensitiveContains(q)
            || $0.artist.localizedCaseInsensitiveContains(q)
            || $0.album.localizedCaseInsensitiveContains(q)
        }
    }

    // MARK: - Helpers

    /// Convert CachedSong to PersistableSong for playback.
    nonisolated static func toPersistable(_ cached: CachedSong) -> PersistableSong {
        PersistableSong(
            id: cached.songId, title: cached.title, artist: cached.artist,
            album: cached.album, albumId: cached.albumId, artistId: cached.artistId,
            coverArt: cached.coverArt, duration: cached.duration,
            replayGainMultiplier: cached.replayGainMultiplier
        )
    }

    private func fetchPlaylistMeta(id: String) -> CachedPlaylistMeta? {
        let descriptor = FetchDescriptor<CachedPlaylistMeta>(
            predicate: #Predicate { $0.playlistId == id }
        )
        return try? context.fetch(descriptor).first
    }
}
