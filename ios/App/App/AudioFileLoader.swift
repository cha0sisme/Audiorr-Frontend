import Foundation
@preconcurrency import AVFoundation

/// Descarga archivos de audio desde URLs remotas (Navidrome streaming) y los cachea
/// como archivos temporales locales para uso con AVAudioFile.
/// LRU con máximo de archivos y bytes. Soporta cancelación y reintentos.
class AudioFileLoader: @unchecked Sendable {

    static let shared = AudioFileLoader()

    // MARK: - Configuración

    private let maxCachedFiles = 5
    private let maxTotalBytes: Int64 = 250 * 1024 * 1024 // 250 MB (CAF/PCM files are much larger than MP3)
    private let maxRetries = 3
    private let retryDelays: [TimeInterval] = [1, 2, 4] // backoff

    // MARK: - Estado

    private let cacheDir: URL
    private var fileAccessTimes: [String: Date] = [:]       // songId → last access
    private var fileSizes: [String: Int64] = [:]             // songId → bytes
    private var activeDownloads: [String: URLSessionDataTask] = [:]
    private var pendingContinuations: [String: [CheckedContinuation<URL, Error>]] = [:]
    private let queue = DispatchQueue(label: "com.audiorr.audiofileloader")

    // MARK: - Init

    private init() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("audiorr-audio", isDirectory: true)
        self.cacheDir = tmp
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        scanExistingFiles()
    }

    /// Escanea archivos existentes en el directorio de caché al iniciar.
    private func scanExistingFiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        for url in contents {
            let songId = url.deletingPathExtension().lastPathComponent
            let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            fileSizes[songId] = Int64(attrs?.fileSize ?? 0)
            fileAccessTimes[songId] = attrs?.contentModificationDate ?? Date()
        }
    }

    // MARK: - API pública

    /// Descarga (o devuelve de caché) un archivo de audio.
    /// Si ya hay una descarga en curso para el mismo songId, espera a que termine.
    func load(remoteURL: URL, songId: String) async throws -> URL {
        let localURL = localPath(for: songId)

        // Cache hit
        if FileManager.default.fileExists(atPath: localURL.path) {
            touchAccess(songId)

            // If this is an .mp3 that's incompatible with AVAudioFile,
            // transcode it to .caf now (may have been cached before transcoding was added).
            if localURL.pathExtension == "mp3" && (try? AVAudioFile(forReading: localURL)) == nil {
                print("[AudioFileLoader] Cache hit but AVAudioFile incompatible — transcoding: \(songId)")
                return try await withCheckedThrowingContinuation { continuation in
                    self.queue.async(flags: []) {
                        self.pendingContinuations[songId] = [continuation]
                        self.transcodeToCAF(songId: songId, sourceURL: localURL)
                    }
                }
            }

            print("[AudioFileLoader] Cache hit: \(songId)")
            return localURL
        }

        // Si ya hay una descarga en curso, esperar a que termine
        return try await withCheckedThrowingContinuation { continuation in
            queue.async(flags: []) {
                if self.pendingContinuations[songId] != nil {
                    // Ya hay descarga en curso — agregar continuation
                    self.pendingContinuations[songId]?.append(continuation)
                    print("[AudioFileLoader] Joining existing download: \(songId)")
                    return
                }

                // Iniciar nueva descarga
                self.pendingContinuations[songId] = [continuation]
                self.startDownload(remoteURL: remoteURL, songId: songId, attempt: 0)
            }
        }
    }

    /// Pre-carga la siguiente canción en background.
    func preload(remoteURL: URL, songId: String) async throws -> URL {
        return try await load(remoteURL: remoteURL, songId: songId)
    }

    /// Cancela una descarga en curso.
    func cancelDownload(songId: String) {
        queue.async(flags: []) {
            if let task = self.activeDownloads.removeValue(forKey: songId) {
                task.cancel()
                print("[AudioFileLoader] Cancelled download: \(songId)")
            }
            // Resolver continuations pendientes con error de cancelación
            if let continuations = self.pendingContinuations.removeValue(forKey: songId) {
                let error = URLError(.cancelled)
                for c in continuations {
                    c.resume(throwing: error)
                }
            }
        }
    }

    /// Cancela todas las descargas en curso.
    func cancelAllDownloads() {
        queue.async(flags: []) {
            let error = URLError(.cancelled)
            for (songId, task) in self.activeDownloads {
                task.cancel()
                if let continuations = self.pendingContinuations.removeValue(forKey: songId) {
                    for c in continuations {
                        c.resume(throwing: error)
                    }
                }
            }
            self.activeDownloads.removeAll()
            print("[AudioFileLoader] Cancelled all downloads")
        }
    }

    /// Elimina todos los archivos cacheados.
    func clearCache() {
        queue.async(flags: []) {
            try? FileManager.default.removeItem(at: self.cacheDir)
            try? FileManager.default.createDirectory(at: self.cacheDir, withIntermediateDirectories: true)
            self.fileAccessTimes.removeAll()
            self.fileSizes.removeAll()
            print("[AudioFileLoader] Cache cleared")
        }
    }

    /// Verifica si un songId está en caché local (persistent or temp).
    func isCached(_ songId: String) -> Bool {
        if cachedFileURL(for: songId) != nil { return true }
        return false
    }

    /// Devuelve la URL local si el archivo está cacheado, nil si no.
    /// Checks persistent offline cache first, then temp hot cache.
    func cachedFileURL(for songId: String) -> URL? {
        // 1. Persistent offline cache (survives app restarts, LRU-managed)
        if let persistentURL = OfflineStorageManager.shared.cachedFileURLSync(for: songId) {
            return persistentURL
        }
        // 2. Temp hot cache (5-file LRU, can be purged by system)
        let caf = cacheDir.appendingPathComponent("\(songId).caf")
        if FileManager.default.fileExists(atPath: caf.path) { return caf }
        let mp3 = cacheDir.appendingPathComponent("\(songId).mp3")
        if FileManager.default.fileExists(atPath: mp3.path) { return mp3 }
        return nil
    }

    // MARK: - Descarga interna

    private func startDownload(remoteURL: URL, songId: String, attempt: Int) {
        let task = URLSession.shared.dataTask(with: remoteURL) { [weak self] data, response, error in
            guard let self = self else { return }

            self.queue.async(flags: []) {
                self.activeDownloads.removeValue(forKey: songId)

                // Error handling con reintentos
                if let error = error {
                    if (error as? URLError)?.code == .cancelled {
                        // Ya resuelto en cancelDownload()
                        return
                    }

                    if attempt < self.maxRetries - 1 {
                        let delay = self.retryDelays[min(attempt, self.retryDelays.count - 1)]
                        print("[AudioFileLoader] Download failed (attempt \(attempt + 1)/\(self.maxRetries)): \(songId) — retrying in \(delay)s")
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                            self.queue.async(flags: []) {
                                self.startDownload(remoteURL: remoteURL, songId: songId, attempt: attempt + 1)
                            }
                        }
                        return
                    }

                    // Agotar reintentos
                    print("[AudioFileLoader] Download failed after \(self.maxRetries) attempts: \(songId) — \(error.localizedDescription)")
                    self.resolveContinuations(songId: songId, result: .failure(error))
                    return
                }

                // Validar respuesta
                guard let data = data, !data.isEmpty else {
                    let err = NSError(domain: "AudioFileLoader", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "Empty response for \(songId)"])
                    self.resolveContinuations(songId: songId, result: .failure(err))
                    return
                }

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
                    let err = NSError(domain: "AudioFileLoader", code: httpResponse.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode) for \(songId)"])
                    self.resolveContinuations(songId: songId, result: .failure(err))
                    return
                }

                // Escribir a disco
                let localURL = self.localPath(for: songId)
                do {
                    try data.write(to: localURL, options: .atomic)
                    self.fileAccessTimes[songId] = Date()
                    self.fileSizes[songId] = Int64(data.count)
                    self.evictIfNeeded()

                    let sizeMB = Double(data.count) / 1024.0 / 1024.0
                    print("[AudioFileLoader] Downloaded: \(songId) (\(String(format: "%.1f", sizeMB))MB)")

                    // Validate with AVAudioFile. If it fails (VBR MP3, bad headers),
                    // transcode to CAF so AVAudioEngine can always use it for crossfade.
                    if (try? AVAudioFile(forReading: localURL)) == nil {
                        print("[AudioFileLoader] AVAudioFile incompatible — transcoding to CAF: \(songId)")
                        self.transcodeToCAF(songId: songId, sourceURL: localURL)
                        // resolveContinuations called inside transcodeToCAF
                    } else {
                        self.resolveContinuations(songId: songId, result: .success(localURL))
                        // Promote to persistent offline cache
                        self.promoteToOfflineCache(songId: songId, fileURL: localURL)
                    }
                } catch {
                    print("[AudioFileLoader] Write error: \(songId) — \(error)")
                    self.resolveContinuations(songId: songId, result: .failure(error))
                }
            }
        }

        activeDownloads[songId] = task
        task.resume()
        print("[AudioFileLoader] Starting download: \(songId) (attempt \(attempt + 1))")
    }

    private func resolveContinuations(songId: String, result: Result<URL, Error>) {
        guard let continuations = pendingContinuations.removeValue(forKey: songId) else { return }
        for c in continuations {
            switch result {
            case .success(let url): c.resume(returning: url)
            case .failure(let err): c.resume(throwing: err)
            }
        }
    }

    // MARK: - LRU eviction

    private func evictIfNeeded() {
        // Evictar por número de archivos
        while fileAccessTimes.count > maxCachedFiles {
            evictOldest()
        }

        // Evictar por tamaño total
        var totalBytes = fileSizes.values.reduce(0, +)
        while totalBytes > maxTotalBytes && !fileAccessTimes.isEmpty {
            let evicted = evictOldest()
            totalBytes -= fileSizes[evicted] ?? 0
        }
    }

    @discardableResult
    private func evictOldest() -> String {
        guard let oldest = fileAccessTimes.min(by: { $0.value < $1.value })?.key else {
            return ""
        }
        // Remove both .mp3 and .caf variants
        let mp3 = cacheDir.appendingPathComponent("\(oldest).mp3")
        let caf = cacheDir.appendingPathComponent("\(oldest).caf")
        try? FileManager.default.removeItem(at: mp3)
        try? FileManager.default.removeItem(at: caf)
        fileAccessTimes.removeValue(forKey: oldest)
        fileSizes.removeValue(forKey: oldest)
        print("[AudioFileLoader] Evicted: \(oldest)")
        return oldest
    }

    // MARK: - Transcode (MP3 → CAF)

    /// Transcode an AVAudioFile-incompatible file to CAF (PCM 16-bit) using AVAssetReader/Writer.
    /// AVAssetReader uses MediaToolbox (same as AVPlayer) so it handles VBR MP3s, bad headers, etc.
    /// The result is a .caf file that AVAudioEngine can always open.
    private func transcodeToCAF(songId: String, sourceURL: URL) {
        let cafURL = cacheDir.appendingPathComponent("\(songId).caf")

        // Run on background thread to avoid blocking the queue
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            let asset = AVURLAsset(url: sourceURL)
            guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                  let reader = try? AVAssetReader(asset: asset) else {
                print("[AudioFileLoader] Transcode failed: no audio track in \(songId)")
                self.queue.async {
                    self.resolveContinuations(songId: songId, result: .success(sourceURL))
                }
                return
            }

            // Read as PCM 16-bit 44.1kHz stereo
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

            // Remove any existing .caf before writing
            try? FileManager.default.removeItem(at: cafURL)

            // Write as CAF (PCM) — must specify outputSettings (not nil/passthrough)
            guard let writer = try? AVAssetWriter(outputURL: cafURL, fileType: .caf) else {
                print("[AudioFileLoader] Transcode failed: can't create writer for \(songId)")
                self.queue.async(flags: []) {
                    self.resolveContinuations(songId: songId, result: .success(sourceURL))
                }
                return
            }

            let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings)
            writer.add(writerInput)

            reader.startReading()
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            let writeQueue = DispatchQueue(label: "com.audiorr.transcode.\(songId)")
            writerInput.requestMediaDataWhenReady(on: writeQueue) { [weak self] in
                autoreleasepool {
                while writerInput.isReadyForMoreMediaData {
                    guard reader.status == .reading,
                          let buffer = readerOutput.copyNextSampleBuffer() else {
                        writerInput.markAsFinished()

                        if reader.status == .completed {
                            writer.finishWriting { [weak self] in
                                guard let self = self else { return }
                                self.queue.async(flags: []) {
                                    // Replace the MP3 with the CAF
                                    try? FileManager.default.removeItem(at: sourceURL)
                                    let cafSize = (try? FileManager.default.attributesOfItem(atPath: cafURL.path)[.size] as? Int64) ?? 0
                                    self.fileSizes[songId] = cafSize
                                    let sizeMB = Double(cafSize) / 1024.0 / 1024.0
                                    print("[AudioFileLoader] Transcoded: \(songId) → CAF (\(String(format: "%.1f", sizeMB))MB)")
                                    self.resolveContinuations(songId: songId, result: .success(cafURL))
                                    // Promote transcoded file to persistent offline cache
                                    self.promoteToOfflineCache(songId: songId, fileURL: cafURL)
                                }
                            }
                        } else {
                            print("[AudioFileLoader] Transcode read failed: \(songId) — \(reader.error?.localizedDescription ?? "unknown")")
                            writer.cancelWriting()
                            try? FileManager.default.removeItem(at: cafURL)
                            self?.queue.async(flags: []) {
                                self?.resolveContinuations(songId: songId, result: .success(sourceURL))
                            }
                        }
                        return
                    }

                    writerInput.append(buffer)
                }
                } // autoreleasepool
            }
        }
    }

    // MARK: - Utilidades

    /// Returns the cached file path. Prefers .caf (transcoded) over .mp3 (original).
    private func localPath(for songId: String) -> URL {
        let cafURL = cacheDir.appendingPathComponent("\(songId).caf")
        if FileManager.default.fileExists(atPath: cafURL.path) {
            return cafURL
        }
        return cacheDir.appendingPathComponent("\(songId).mp3")
    }

    private func touchAccess(_ songId: String) {
        queue.async(flags: []) {
            self.fileAccessTimes[songId] = Date()
        }
    }

    /// Promote a downloaded file to the persistent offline cache (fire-and-forget).
    private func promoteToOfflineCache(songId: String, fileURL: URL) {
        guard PersistenceService.shared.offlineAutoCacheEnabled else { return }

        Task { @MainActor in
            // Resolve song metadata from the current queue (MainActor for QueueManager access)
            let song: PersistableSong? = {
                if let current = QueueManager.shared.currentSong, current.id == songId {
                    return current
                }
                return QueueManager.shared.queue.first { $0.id == songId }
            }()

            await OfflineStorageManager.shared.storeFile(from: fileURL, songId: songId, song: song)
        }
    }
}
