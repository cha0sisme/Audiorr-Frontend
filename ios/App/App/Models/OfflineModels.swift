import Foundation
import SwiftData

// MARK: - Cached Song (persistent offline cache metadata)

@Model
final class CachedSong {
    @Attribute(.unique) var songId: String
    var title: String
    var artist: String
    var album: String
    var albumId: String
    var artistId: String
    var coverArt: String
    var duration: Double
    var replayGainMultiplier: Float

    /// Relative path within the cache root, e.g. "ab/abcdef123.caf"
    var filePath: String
    /// File size in bytes
    var fileSize: Int64
    /// Audio format: "caf", "mp3", etc.
    var format: String

    /// Pinned songs are never auto-evicted
    var isPinned: Bool = false
    /// Download state: "none", "queued", "downloading", "completed", "failed"
    var downloadState: String = "none"
    var downloadedAt: Date?
    var lastPlayedAt: Date?
    var lastAccessedAt: Date?

    /// Server URL for multi-account isolation
    var serverURL: String = ""

    init(songId: String, title: String, artist: String, album: String,
         albumId: String, artistId: String, coverArt: String,
         duration: Double, replayGainMultiplier: Float,
         filePath: String, fileSize: Int64, format: String,
         serverURL: String = "") {
        self.songId = songId
        self.title = title
        self.artist = artist
        self.album = album
        self.albumId = albumId
        self.artistId = artistId
        self.coverArt = coverArt
        self.duration = duration
        self.replayGainMultiplier = replayGainMultiplier
        self.filePath = filePath
        self.fileSize = fileSize
        self.format = format
        self.serverURL = serverURL
    }
}

// MARK: - Download Task (tracks individual file downloads)

@Model
final class DownloadTask {
    @Attribute(.unique) var taskId: String
    var songId: String
    var remoteURL: String
    /// Priority: 0 = auto-cache (played), 1 = pre-cache (next in queue), 2 = user-requested
    var priority: Int
    var progress: Double = 0
    /// State: "pending", "active", "paused", "completed", "failed"
    var state: String = "pending"
    var createdAt: Date
    var groupId: String?
    var groupType: String?  // "album" or "playlist"
    var retryCount: Int = 0

    init(taskId: String = UUID().uuidString, songId: String, remoteURL: String,
         priority: Int = 0, groupId: String? = nil, groupType: String? = nil) {
        self.taskId = taskId
        self.songId = songId
        self.remoteURL = remoteURL
        self.priority = priority
        self.createdAt = Date()
        self.groupId = groupId
        self.groupType = groupType
    }
}

// MARK: - Cached Playlist/Album metadata (for offline browsing)

@Model
final class CachedPlaylistMeta {
    @Attribute(.unique) var playlistId: String
    var name: String
    var owner: String
    var songCount: Int
    var duration: Int
    var coverArt: String
    var isAlbum: Bool  // true = album, false = playlist
    var artist: String  // for albums
    var year: Int?      // for albums
    /// JSON-encoded array of song IDs in order
    var songIdsJSON: String
    var cachedAt: Date

    init(playlistId: String, name: String, owner: String = "", songCount: Int,
         duration: Int = 0, coverArt: String = "", isAlbum: Bool = false,
         artist: String = "", year: Int? = nil, songIds: [String]) {
        self.playlistId = playlistId
        self.name = name
        self.owner = owner
        self.songCount = songCount
        self.duration = duration
        self.coverArt = coverArt
        self.isAlbum = isAlbum
        self.artist = artist
        self.year = year
        self.songIdsJSON = (try? String(data: JSONEncoder().encode(songIds), encoding: .utf8)) ?? "[]"
        self.cachedAt = Date()
    }

    var songIds: [String] {
        guard let data = songIdsJSON.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return ids
    }
}

// MARK: - CachedSong → NavidromeSong conversion

extension CachedSong {
    /// Convert to NavidromeSong for playback via PlayerService / QueueManager.
    func toNavidromeSong() -> NavidromeSong {
        NavidromeSong(
            id: songId, title: title, artist: artist,
            artistId: artistId.isEmpty ? nil : artistId,
            album: album,
            albumId: albumId.isEmpty ? nil : albumId,
            coverArt: coverArt.isEmpty ? nil : coverArt,
            duration: duration, track: nil, year: nil, genre: nil,
            explicitStatus: nil,
            replayGainTrackGain: nil, replayGainTrackPeak: nil,
            replayGainAlbumGain: nil, replayGainAlbumPeak: nil
        )
    }
}

// MARK: - Download Group (batch download tracking for albums/playlists)

@Model
final class DownloadGroup {
    @Attribute(.unique) var groupId: String
    /// "album" or "playlist"
    var groupType: String
    var title: String
    var totalSongs: Int
    var completedSongs: Int = 0
    var isPinned: Bool = false
    var createdAt: Date = Date()

    init(groupId: String, groupType: String, title: String, totalSongs: Int, isPinned: Bool = false) {
        self.groupId = groupId
        self.groupType = groupType
        self.title = title
        self.totalSongs = totalSongs
        self.isPinned = isPinned
    }

    var isComplete: Bool { completedSongs >= totalSongs }
    var progress: Double {
        totalSongs > 0 ? Double(completedSongs) / Double(totalSongs) : 0
    }
}
