import Foundation
import SwiftData
import AVFoundation

/// Persistent offline cache for audio files.
/// Stores files in `Library/Caches/Audiorr/Music/{2-char prefix}/{songId}.{ext}`.
/// Metadata tracked in SwiftData. LRU eviction of unpinned content.
actor OfflineStorageManager {

    static let shared = OfflineStorageManager()

    // MARK: - Shared ModelContainer (one instance for the whole app)

    static let modelContainer: ModelContainer = {
        let schema = Schema([CachedSong.self, DownloadTask.self, DownloadGroup.self, CachedPlaylistMeta.self])
        let storeURL = URL.libraryDirectory
            .appending(path: "Application Support/Audiorr", directoryHint: .isDirectory)
            .appending(path: "offline.store")

        // Ensure directory exists
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let config = ModelConfiguration("OfflineCache", schema: schema, url: storeURL)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("[OfflineStorageManager] Failed to create ModelContainer: \(error)")
        }
    }()

    // MARK: - State

    private let musicDir: URL
    private let context: ModelContext

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Audiorr/Music", isDirectory: true)
        self.musicDir = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        // Exclude from iCloud backup
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableBase = base
        try? mutableBase.setResourceValues(resourceValues)

        self.context = ModelContext(Self.modelContainer)
        self.context.autosaveEnabled = true
    }

    // MARK: - Sync API (for AudioFileLoader, called from non-async context)

    /// Synchronous cache lookup — uses a dedicated ModelContext on the calling thread.
    /// Safe to call from any thread. Does NOT update lastAccessedAt (use markAccessed for that).
    nonisolated func cachedFileURLSync(for songId: String) -> URL? {
        let ctx = ModelContext(Self.modelContainer)
        let descriptor = FetchDescriptor<CachedSong>(
            predicate: #Predicate { $0.songId == songId }
        )
        guard let cached = try? ctx.fetch(descriptor).first,
              cached.downloadState == "completed" else { return nil }

        let fileURL = musicDir.appendingPathComponent(cached.filePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }

    // MARK: - Public API: Query

    /// Returns the local file URL if the song is cached and the file exists on disk.
    func cachedFileURL(for songId: String) -> URL? {
        guard let cached = fetchCachedSong(songId: songId),
              cached.downloadState == "completed" else { return nil }

        let fileURL = musicDir.appendingPathComponent(cached.filePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // File was deleted externally — clean up the record
            context.delete(cached)
            try? context.save()
            return nil
        }

        // Update access time (fire-and-forget within actor)
        cached.lastAccessedAt = Date()
        try? context.save()

        return fileURL
    }

    /// Whether a song is fully cached.
    func isCached(songId: String) -> Bool {
        guard let cached = fetchCachedSong(songId: songId) else { return false }
        return cached.downloadState == "completed"
            && FileManager.default.fileExists(atPath: musicDir.appendingPathComponent(cached.filePath).path)
    }

    // MARK: - Public API: Store

    /// Copy a downloaded file into the persistent cache and create/update SwiftData record.
    /// `sourceURL` is typically the temp-cache file from AudioFileLoader.
    /// `song` provides metadata for the CachedSong record.
    @discardableResult
    func storeFile(from sourceURL: URL, songId: String, song: PersistableSong? = nil) -> URL? {
        let ext = sourceURL.pathExtension.isEmpty ? "mp3" : sourceURL.pathExtension
        let prefix = String(songId.prefix(2))
        let relPath = "\(prefix)/\(songId).\(ext)"
        let destURL = musicDir.appendingPathComponent(relPath)

        // Ensure subdirectory exists
        let subdir = destURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        // Copy file (don't move — AudioFileLoader still needs the temp copy for hot cache)
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            print("[OfflineStorage] Failed to copy file: \(error)")
            return nil
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0

        // Create or update SwiftData record
        if let existing = fetchCachedSong(songId: songId) {
            existing.filePath = relPath
            existing.fileSize = fileSize
            existing.format = ext
            existing.downloadState = "completed"
            existing.downloadedAt = Date()
            existing.lastAccessedAt = Date()
            if let song {
                existing.title = song.title
                existing.artist = song.artist
                existing.album = song.album
                existing.albumId = song.albumId
                existing.artistId = song.artistId
                existing.coverArt = song.coverArt
                existing.duration = song.duration
                existing.replayGainMultiplier = song.replayGainMultiplier
            }
        } else {
            let cached = CachedSong(
                songId: songId,
                title: song?.title ?? "",
                artist: song?.artist ?? "",
                album: song?.album ?? "",
                albumId: song?.albumId ?? "",
                artistId: song?.artistId ?? "",
                coverArt: song?.coverArt ?? "",
                duration: song?.duration ?? 0,
                replayGainMultiplier: song?.replayGainMultiplier ?? 1.0,
                filePath: relPath,
                fileSize: fileSize,
                format: ext,
                serverURL: NavidromeService.shared.credentials?.serverUrl ?? ""
            )
            cached.downloadState = "completed"
            cached.downloadedAt = Date()
            cached.lastAccessedAt = Date()
            context.insert(cached)
        }

        try? context.save()

        // Run eviction after storing
        evictIfNeeded()

        let sizeMB = Double(fileSize) / 1024.0 / 1024.0
        print("[OfflineStorage] Stored: \(songId) (\(String(format: "%.1f", sizeMB))MB) → \(relPath)")

        return destURL
    }

    // MARK: - Public API: Timestamps

    func markAccessed(songId: String) {
        guard let cached = fetchCachedSong(songId: songId) else { return }
        cached.lastAccessedAt = Date()
        try? context.save()
    }

    func markPlayed(songId: String) {
        guard let cached = fetchCachedSong(songId: songId) else { return }
        cached.lastPlayedAt = Date()
        cached.lastAccessedAt = Date()
        try? context.save()
    }

    // MARK: - Public API: Pin/Unpin

    func pin(songId: String) {
        guard let cached = fetchCachedSong(songId: songId) else { return }
        cached.isPinned = true
        try? context.save()
    }

    func unpin(songId: String) {
        guard let cached = fetchCachedSong(songId: songId) else { return }
        cached.isPinned = false
        try? context.save()
    }

    func pinGroup(groupId: String) {
        let descriptor = FetchDescriptor<CachedSong>(
            predicate: #Predicate { $0.albumId == groupId }
        )
        guard let songs = try? context.fetch(descriptor) else { return }
        for song in songs { song.isPinned = true }
        try? context.save()
    }

    func unpinGroup(groupId: String) {
        let descriptor = FetchDescriptor<CachedSong>(
            predicate: #Predicate { $0.albumId == groupId }
        )
        guard let songs = try? context.fetch(descriptor) else { return }
        for song in songs { song.isPinned = false }
        try? context.save()
    }

    // MARK: - Public API: Storage Stats

    func totalCacheSize() -> Int64 {
        let descriptor = FetchDescriptor<CachedSong>(
            predicate: #Predicate { $0.downloadState == "completed" }
        )
        guard let songs = try? context.fetch(descriptor) else { return 0 }
        return songs.reduce(0) { $0 + $1.fileSize }
    }

    func pinnedSize() -> Int64 {
        let descriptor = FetchDescriptor<CachedSong>(
            predicate: #Predicate { $0.downloadState == "completed" && $0.isPinned == true }
        )
        guard let songs = try? context.fetch(descriptor) else { return 0 }
        return songs.reduce(0) { $0 + $1.fileSize }
    }

    func cachedSongCount() -> Int {
        let descriptor = FetchDescriptor<CachedSong>(
            predicate: #Predicate { $0.downloadState == "completed" }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    // MARK: - Public API: Delete

    func deleteFile(songId: String) {
        guard let cached = fetchCachedSong(songId: songId) else { return }
        let fileURL = musicDir.appendingPathComponent(cached.filePath)
        try? FileManager.default.removeItem(at: fileURL)
        context.delete(cached)
        try? context.save()
        print("[OfflineStorage] Deleted: \(songId)")
    }

    func deleteUnpinned() {
        let descriptor = FetchDescriptor<CachedSong>(
            predicate: #Predicate { $0.isPinned == false }
        )
        guard let songs = try? context.fetch(descriptor) else { return }
        for song in songs {
            let fileURL = musicDir.appendingPathComponent(song.filePath)
            try? FileManager.default.removeItem(at: fileURL)
            context.delete(song)
        }
        try? context.save()
        print("[OfflineStorage] Deleted all unpinned cache")
    }

    func deleteAll() {
        let descriptor = FetchDescriptor<CachedSong>()
        guard let songs = try? context.fetch(descriptor) else { return }
        for song in songs {
            let fileURL = musicDir.appendingPathComponent(song.filePath)
            try? FileManager.default.removeItem(at: fileURL)
            context.delete(song)
        }
        try? context.save()
        print("[OfflineStorage] Deleted all cache")
    }

    // MARK: - LRU Eviction

    /// Evict unpinned songs (oldest accessed first) until total size is under the configured limit.
    func evictIfNeeded() {
        let maxBytes = PersistenceService.shared.offlineMaxCacheBytes
        guard maxBytes > 0 else { return } // 0 = unlimited

        var currentSize = totalCacheSize()
        guard currentSize > maxBytes else { return }

        // Fetch unpinned songs sorted by lastAccessedAt ascending (oldest first)
        var descriptor = FetchDescriptor<CachedSong>(
            predicate: #Predicate { $0.isPinned == false && $0.downloadState == "completed" },
            sortBy: [SortDescriptor(\CachedSong.lastAccessedAt, order: .forward)]
        )
        descriptor.fetchLimit = 100 // Process in batches

        guard let candidates = try? context.fetch(descriptor) else { return }

        for song in candidates {
            guard currentSize > maxBytes else { break }

            let fileURL = musicDir.appendingPathComponent(song.filePath)
            try? FileManager.default.removeItem(at: fileURL)
            currentSize -= song.fileSize
            context.delete(song)
            print("[OfflineStorage] Evicted: \(song.songId) (\(song.fileSize / 1024)KB)")
        }

        try? context.save()
    }

    // MARK: - Private Helpers

    private func fetchCachedSong(songId: String) -> CachedSong? {
        let descriptor = FetchDescriptor<CachedSong>(
            predicate: #Predicate { $0.songId == songId }
        )
        return try? context.fetch(descriptor).first
    }
}
