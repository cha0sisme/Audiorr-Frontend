import Foundation
import AVFoundation
import SwiftData

// MARK: - Active Download (observable progress for UI)

struct ActiveDownload: Identifiable {
    let id: String  // songId
    let title: String
    let artist: String
    var progress: Double
    var state: String  // "pending", "active", "completed", "failed"
    var groupId: String?
}

struct PendingDownload {
    let song: PersistableSong
    let priority: Int
    let groupId: String?
    let groupType: String?
}

// MARK: - Download Manager

/// Manages user-initiated and pre-cache downloads with background URLSession support.
/// Priority queue: user (2) > pre-cache (1) > auto-cache (0). Max 3 concurrent downloads.
@MainActor @Observable
final class DownloadManager: NSObject {

    static let shared = DownloadManager()

    // MARK: - Observable State

    private(set) var activeDownloads: [ActiveDownload] = []
    private(set) var completedCount: Int = 0
    private(set) var failedCount: Int = 0
    private(set) var isDownloading: Bool = false

    // MARK: - Configuration

    private let maxConcurrent = 3
    private let maxRetries = 3
    private let retryDelays: [TimeInterval] = [2, 4, 8]

    // MARK: - Internal State

    @ObservationIgnored private var backgroundSession: URLSession!
    @ObservationIgnored private var backgroundCompletionHandler: (() -> Void)?
    @ObservationIgnored private var taskToSongId: [Int: String] = [:]  // URLSessionTask.taskIdentifier → songId
    @ObservationIgnored private var pendingQueue: [PendingDownload] = []
    @ObservationIgnored private var activeTasks: [String: URLSessionDownloadTask] = [:]  // songId → task
    @ObservationIgnored private let context: ModelContext

    // Temp directory for downloads before promotion
    private let tempDir: URL

    // MARK: - Init

    private override init() {
        let ctx = ModelContext(OfflineStorageManager.modelContainer)
        ctx.autosaveEnabled = true
        self.context = ctx

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiorr-downloads", isDirectory: true)
        self.tempDir = tmp
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        super.init()

        let config = URLSessionConfiguration.background(withIdentifier: "com.audiorr.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = maxConcurrent
        self.backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        // Restore any in-progress tasks from a previous session
        restoreActiveTasks()
    }

    // MARK: - Background Session Handler

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }

    // MARK: - Public API: Download Songs

    /// Download a single song (user-initiated, priority 2).
    func downloadSong(_ song: NavidromeSong) {
        let persistable = PersistableSong(from: song)
        enqueue(song: persistable, priority: 2, groupId: nil, groupType: nil)
    }

    /// Download a single song from PersistableSong.
    func downloadSong(_ song: PersistableSong, priority: Int = 2, groupId: String? = nil, groupType: String? = nil) {
        enqueue(song: song, priority: priority, groupId: groupId, groupType: groupType)
    }

    /// Download all songs in an album.
    func downloadAlbum(albumId: String, title: String, songs: [NavidromeSong], pin: Bool = false, album: NavidromeAlbum? = nil) {
        let group = getOrCreateGroup(groupId: albumId, groupType: "album", title: title, totalSongs: songs.count, pin: pin)

        // Save album metadata for offline browsing
        if let album {
            Task { await OfflineContentProvider.shared.saveAlbumMeta(album: album, songs: songs) }
        }

        for song in songs {
            // Skip already cached
            if isSongDownloaded(songId: song.id) {
                group.completedSongs += 1
                continue
            }
            let persistable = PersistableSong(from: song)
            enqueue(song: persistable, priority: 2, groupId: albumId, groupType: "album")
        }
        try? context.save()
        updateObservableState()
    }

    /// Download all songs in a playlist.
    func downloadPlaylist(playlistId: String, title: String, songs: [NavidromeSong], pin: Bool = false, playlist: NavidromePlaylist? = nil) {
        let group = getOrCreateGroup(groupId: playlistId, groupType: "playlist", title: title, totalSongs: songs.count, pin: pin)

        // Save playlist metadata for offline browsing
        if let playlist {
            Task { await OfflineContentProvider.shared.savePlaylistMeta(playlist: playlist, songs: songs) }
        }

        for song in songs {
            if isSongDownloaded(songId: song.id) {
                group.completedSongs += 1
                continue
            }
            let persistable = PersistableSong(from: song)
            enqueue(song: persistable, priority: 2, groupId: playlistId, groupType: "playlist")
        }
        try? context.save()
        updateObservableState()
    }

    /// Pre-cache next N songs in queue (priority 1, non-blocking).
    func preCacheSongs(_ songs: [PersistableSong]) {
        for song in songs {
            if isSongDownloaded(songId: song.id) { continue }
            enqueue(song: song, priority: 1, groupId: nil, groupType: nil)
        }
    }

    // MARK: - Public API: Cancel

    func cancelDownload(songId: String) {
        // Cancel active task
        if let task = activeTasks.removeValue(forKey: songId) {
            task.cancel()
        }
        // Remove from pending queue
        pendingQueue.removeAll { $0.song.id == songId }
        // Update SwiftData
        if let dlTask = fetchDownloadTask(songId: songId) {
            context.delete(dlTask)
            try? context.save()
        }
        activeDownloads.removeAll { $0.id == songId }
        updateObservableState()
        processQueue()
    }

    func cancelGroup(groupId: String) {
        // Cancel all tasks in this group
        let descriptor = FetchDescriptor<DownloadTask>(
            predicate: #Predicate { $0.groupId == groupId && $0.state != "completed" }
        )
        if let tasks = try? context.fetch(descriptor) {
            for task in tasks {
                if let activeTask = activeTasks.removeValue(forKey: task.songId) {
                    activeTask.cancel()
                }
                context.delete(task)
            }
        }
        pendingQueue.removeAll { $0.groupId == groupId }
        activeDownloads.removeAll { $0.groupId == groupId }
        // Delete group record
        if let group = fetchGroup(groupId: groupId) {
            context.delete(group)
        }
        try? context.save()
        updateObservableState()
        processQueue()
    }

    func cancelAll() {
        backgroundSession.invalidateAndCancel()
        activeTasks.removeAll()
        taskToSongId.removeAll()
        pendingQueue.removeAll()
        activeDownloads.removeAll()

        // Clear all SwiftData download tasks
        let descriptor = FetchDescriptor<DownloadTask>()
        if let tasks = try? context.fetch(descriptor) {
            for task in tasks { context.delete(task) }
        }
        try? context.save()

        // Recreate session
        let config = URLSessionConfiguration.background(withIdentifier: "com.audiorr.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = maxConcurrent
        backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        updateObservableState()
    }

    // MARK: - Public API: Retry

    func retryFailed() {
        let descriptor = FetchDescriptor<DownloadTask>(
            predicate: #Predicate { $0.state == "failed" }
        )
        guard let failedTasks = try? context.fetch(descriptor) else { return }
        for task in failedTasks {
            task.state = "pending"
            task.retryCount = 0

            // Re-enqueue with metadata from CachedSong if available
            if let cached = fetchCachedSong(songId: task.songId) {
                let song = PersistableSong(
                    id: task.songId, title: cached.title, artist: cached.artist,
                    album: cached.album, albumId: cached.albumId, artistId: cached.artistId,
                    coverArt: cached.coverArt, duration: cached.duration,
                    replayGainMultiplier: cached.replayGainMultiplier
                )
                pendingQueue.append(PendingDownload(song: song, priority: task.priority, groupId: task.groupId, groupType: task.groupType))
            }
        }
        try? context.save()
        failedCount = 0
        updateObservableState()
        processQueue()
    }

    // MARK: - Public API: Query

    func isSongDownloaded(songId: String) -> Bool {
        let descriptor = FetchDescriptor<CachedSong>(
            predicate: #Predicate { $0.songId == songId && $0.downloadState == "completed" }
        )
        return (try? context.fetchCount(descriptor)) ?? 0 > 0
    }

    func isSongQueued(songId: String) -> Bool {
        let descriptor = FetchDescriptor<DownloadTask>(
            predicate: #Predicate { $0.songId == songId && $0.state != "completed" && $0.state != "failed" }
        )
        return (try? context.fetchCount(descriptor)) ?? 0 > 0
    }

    func downloadProgress(songId: String) -> Double? {
        activeDownloads.first { $0.id == songId }?.progress
    }

    func groupProgress(groupId: String) -> Double? {
        fetchGroup(groupId: groupId)?.progress
    }

    func groups() -> [DownloadGroup] {
        let descriptor = FetchDescriptor<DownloadGroup>(
            sortBy: [SortDescriptor(\DownloadGroup.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Enqueue & Process

    private func enqueue(song: PersistableSong, priority: Int, groupId: String?, groupType: String?) {
        // Skip if already queued or downloaded
        guard !isSongDownloaded(songId: song.id),
              !isSongQueued(songId: song.id),
              !pendingQueue.contains(where: { $0.song.id == song.id }) else { return }

        guard let streamURL = NavidromeService.shared.streamURL(songId: song.id) else {
            print("[DownloadManager] No stream URL for \(song.id)")
            return
        }

        // Create SwiftData task record
        let dlTask = DownloadTask(songId: song.id, remoteURL: streamURL.absoluteString, priority: priority, groupId: groupId, groupType: groupType)
        context.insert(dlTask)
        try? context.save()

        // Add to in-memory queue
        pendingQueue.append(PendingDownload(song: song, priority: priority, groupId: groupId, groupType: groupType))

        // Sort by priority (highest first)
        pendingQueue.sort { $0.priority > $1.priority }

        activeDownloads.append(ActiveDownload(
            id: song.id, title: song.title, artist: song.artist,
            progress: 0, state: "pending", groupId: groupId
        ))
        updateObservableState()
        processQueue()
    }

    private func processQueue() {
        while activeTasks.count < maxConcurrent, !pendingQueue.isEmpty {
            let item = pendingQueue.removeFirst()
            startDownload(song: item.song, groupId: item.groupId, groupType: item.groupType)
        }
    }

    private func startDownload(song: PersistableSong, groupId: String?, groupType: String?) {
        guard let streamURL = NavidromeService.shared.streamURL(songId: song.id) else { return }

        let task = backgroundSession.downloadTask(with: streamURL)
        task.taskDescription = song.id  // Store songId in taskDescription for recovery
        taskToSongId[task.taskIdentifier] = song.id
        activeTasks[song.id] = task

        // Update SwiftData
        if let dlTask = fetchDownloadTask(songId: song.id) {
            dlTask.state = "active"
        }
        try? context.save()

        // Update observable
        if let idx = activeDownloads.firstIndex(where: { $0.id == song.id }) {
            activeDownloads[idx].state = "active"
        }

        task.resume()
        print("[DownloadManager] Started: \(song.title) — \(song.artist)")
    }

    // MARK: - Download Completion

    private func handleDownloadCompleted(songId: String, tempFileURL: URL) {
        // Move to our temp dir (background session temp files are auto-deleted)
        let destURL = tempDir.appendingPathComponent("\(songId).\(tempFileURL.pathExtension.isEmpty ? "mp3" : tempFileURL.pathExtension)")
        try? FileManager.default.removeItem(at: destURL)
        do {
            try FileManager.default.moveItem(at: tempFileURL, to: destURL)
        } catch {
            print("[DownloadManager] Failed to move temp file: \(error)")
            handleDownloadFailed(songId: songId, error: error)
            return
        }

        // Validate with AVAudioFile — if incompatible, transcode
        if (try? AVAudioFile(forReading: destURL)) == nil {
            print("[DownloadManager] AVAudioFile incompatible — transcoding: \(songId)")
            transcodeAndStore(songId: songId, sourceURL: destURL)
        } else {
            storeCompletedDownload(songId: songId, fileURL: destURL)
        }
    }

    private func storeCompletedDownload(songId: String, fileURL: URL) {
        // Get metadata from the download task
        let song = resolveSongMetadata(songId: songId)

        Task {
            // Store in persistent cache
            await OfflineStorageManager.shared.storeFile(from: fileURL, songId: songId, song: song)

            await MainActor.run {
                // Update SwiftData task
                if let dlTask = self.fetchDownloadTask(songId: songId) {
                    dlTask.state = "completed"
                    dlTask.progress = 1.0
                }

                // Update group progress
                if let dlTask = self.fetchDownloadTask(songId: songId), let gid = dlTask.groupId {
                    if let group = self.fetchGroup(groupId: gid) {
                        group.completedSongs += 1
                        if group.isComplete && group.isPinned {
                            Task { await OfflineStorageManager.shared.pinGroup(groupId: gid) }
                        }
                    }
                }

                try? self.context.save()

                // Clean up
                self.activeTasks.removeValue(forKey: songId)
                if let idx = self.activeDownloads.firstIndex(where: { $0.id == songId }) {
                    self.activeDownloads[idx].state = "completed"
                    self.activeDownloads[idx].progress = 1.0
                }
                self.completedCount += 1

                // Remove completed from active list after a short delay
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    await MainActor.run {
                        self.activeDownloads.removeAll { $0.id == songId && $0.state == "completed" }
                        self.updateObservableState()
                    }
                }

                // Clean temp file
                try? FileManager.default.removeItem(at: fileURL)

                self.updateObservableState()
                self.processQueue()
            }
        }
    }

    private func handleDownloadFailed(songId: String, error: Error) {
        guard let dlTask = fetchDownloadTask(songId: songId) else {
            activeTasks.removeValue(forKey: songId)
            processQueue()
            return
        }

        dlTask.retryCount += 1

        if dlTask.retryCount < maxRetries {
            let delay = retryDelays[min(dlTask.retryCount - 1, retryDelays.count - 1)]
            print("[DownloadManager] Failed (attempt \(dlTask.retryCount)/\(maxRetries)): \(songId) — retrying in \(delay)s")
            dlTask.state = "pending"
            try? context.save()

            activeTasks.removeValue(forKey: songId)

            Task {
                try? await Task.sleep(for: .seconds(delay))
                await MainActor.run {
                    if let song = self.resolveSongMetadata(songId: songId) {
                        self.startDownload(song: song, groupId: dlTask.groupId, groupType: dlTask.groupType)
                    }
                }
            }
        } else {
            print("[DownloadManager] Failed after \(maxRetries) attempts: \(songId)")
            dlTask.state = "failed"
            try? context.save()

            activeTasks.removeValue(forKey: songId)
            if let idx = activeDownloads.firstIndex(where: { $0.id == songId }) {
                activeDownloads[idx].state = "failed"
            }
            failedCount += 1
            updateObservableState()
            processQueue()
        }
    }

    // MARK: - Transcode (MP3 → CAF)

    private func transcodeAndStore(songId: String, sourceURL: URL) {
        let cafURL = tempDir.appendingPathComponent("\(songId).caf")

        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVURLAsset(url: sourceURL)
            var loadedTrack: AVAssetTrack?
            let sem = DispatchSemaphore(value: 0)
            Task {
                loadedTrack = try? await asset.loadTracks(withMediaType: .audio).first
                sem.signal()
            }
            sem.wait()

            guard let reader = try? AVAssetReader(asset: asset),
                  let audioTrack = loadedTrack else {
                print("[DownloadManager] Transcode failed: no audio track in \(songId)")
                // Store as-is — AudioFileLoader can handle it via AVPlayer fallback
                Task { @MainActor in self.storeCompletedDownload(songId: songId, fileURL: sourceURL) }
                return
            }

            let pcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
            ]
            let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
            reader.add(readerOutput)

            try? FileManager.default.removeItem(at: cafURL)
            guard let writer = try? AVAssetWriter(outputURL: cafURL, fileType: .caf) else {
                Task { @MainActor in self.storeCompletedDownload(songId: songId, fileURL: sourceURL) }
                return
            }

            let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings)
            writer.add(writerInput)
            reader.startReading()
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            let writeQueue = DispatchQueue(label: "com.audiorr.dl-transcode.\(songId)")
            writerInput.requestMediaDataWhenReady(on: writeQueue) {
                while writerInput.isReadyForMoreMediaData {
                    guard reader.status == .reading,
                          let buffer = readerOutput.copyNextSampleBuffer() else {
                        writerInput.markAsFinished()
                        if reader.status == .completed {
                            writer.finishWriting {
                                try? FileManager.default.removeItem(at: sourceURL)
                                print("[DownloadManager] Transcoded: \(songId) → CAF")
                                Task { @MainActor in self.storeCompletedDownload(songId: songId, fileURL: cafURL) }
                            }
                        } else {
                            writer.cancelWriting()
                            try? FileManager.default.removeItem(at: cafURL)
                            Task { @MainActor in self.storeCompletedDownload(songId: songId, fileURL: sourceURL) }
                        }
                        return
                    }
                    writerInput.append(buffer)
                }
            }
        }
    }

    // MARK: - Helpers

    private func resolveSongMetadata(songId: String) -> PersistableSong? {
        // Try from QueueManager first
        if let current = QueueManager.shared.currentSong, current.id == songId {
            return current
        }
        if let queued = QueueManager.shared.queue.first(where: { $0.id == songId }) {
            return queued
        }
        // Try from CachedSong in SwiftData
        if let cached = fetchCachedSong(songId: songId) {
            return PersistableSong(
                id: cached.songId, title: cached.title, artist: cached.artist,
                album: cached.album, albumId: cached.albumId, artistId: cached.artistId,
                coverArt: cached.coverArt, duration: cached.duration,
                replayGainMultiplier: cached.replayGainMultiplier
            )
        }
        return nil
    }

    private func updateObservableState() {
        isDownloading = !activeTasks.isEmpty || !pendingQueue.isEmpty
    }

    private func restoreActiveTasks() {
        backgroundSession.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                for task in tasks {
                    if let songId = task.taskDescription {
                        self.taskToSongId[task.taskIdentifier] = songId
                        if task.state == .running || task.state == .suspended {
                            self.activeTasks[songId] = task as? URLSessionDownloadTask
                            // Restore observable entry
                            if !self.activeDownloads.contains(where: { $0.id == songId }) {
                                let meta = self.resolveSongMetadata(songId: songId)
                                self.activeDownloads.append(ActiveDownload(
                                    id: songId,
                                    title: meta?.title ?? songId,
                                    artist: meta?.artist ?? "",
                                    progress: Double(task.countOfBytesReceived) / max(Double(task.countOfBytesExpectedToReceive), 1),
                                    state: "active",
                                    groupId: self.fetchDownloadTask(songId: songId)?.groupId
                                ))
                            }
                        }
                    }
                }
                self.updateObservableState()
            }
        }
    }

    // MARK: - SwiftData Queries

    private func fetchDownloadTask(songId: String) -> DownloadTask? {
        let descriptor = FetchDescriptor<DownloadTask>(
            predicate: #Predicate { $0.songId == songId }
        )
        return try? context.fetch(descriptor).first
    }

    private func fetchCachedSong(songId: String) -> CachedSong? {
        let descriptor = FetchDescriptor<CachedSong>(
            predicate: #Predicate { $0.songId == songId }
        )
        return try? context.fetch(descriptor).first
    }

    private func fetchGroup(groupId: String) -> DownloadGroup? {
        let descriptor = FetchDescriptor<DownloadGroup>(
            predicate: #Predicate { $0.groupId == groupId }
        )
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    private func getOrCreateGroup(groupId: String, groupType: String, title: String, totalSongs: Int, pin: Bool) -> DownloadGroup {
        if let existing = fetchGroup(groupId: groupId) {
            existing.totalSongs = totalSongs
            if pin { existing.isPinned = true }
            return existing
        }
        let group = DownloadGroup(groupId: groupId, groupType: groupType, title: title, totalSongs: totalSongs, isPinned: pin)
        context.insert(group)
        try? context.save()
        return group
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let songId = downloadTask.taskDescription ?? ""
        guard !songId.isEmpty else { return }

        // Copy file immediately — background session will delete the temp file after this method returns
        let safeCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiorr-dl-\(songId).\(location.pathExtension.isEmpty ? "mp3" : location.pathExtension)")
        try? FileManager.default.removeItem(at: safeCopy)
        try? FileManager.default.copyItem(at: location, to: safeCopy)

        Task { @MainActor in
            self.handleDownloadCompleted(songId: songId, tempFileURL: safeCopy)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let songId = downloadTask.taskDescription ?? ""
        guard !songId.isEmpty, totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        Task { @MainActor in
            if let idx = self.activeDownloads.firstIndex(where: { $0.id == songId }) {
                self.activeDownloads[idx].progress = progress
            }
            if let dlTask = self.fetchDownloadTask(songId: songId) {
                dlTask.progress = progress
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error = error else { return }  // Success handled in didFinishDownloadingTo
        let songId = task.taskDescription ?? ""
        guard !songId.isEmpty else { return }

        Task { @MainActor in
            self.handleDownloadFailed(songId: songId, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
