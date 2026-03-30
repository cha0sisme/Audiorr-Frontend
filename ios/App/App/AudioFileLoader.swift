import Foundation

/// Descarga archivos de audio desde URLs remotas (Navidrome streaming) y los cachea
/// como archivos temporales locales para uso con AVAudioFile.
/// LRU con máximo de archivos y bytes. Soporta cancelación y reintentos.
class AudioFileLoader: @unchecked Sendable {

    static let shared = AudioFileLoader()

    // MARK: - Configuración

    private let maxCachedFiles = 5
    private let maxTotalBytes: Int64 = 60 * 1024 * 1024 // 60 MB
    private let maxRetries = 3
    private let retryDelays: [TimeInterval] = [1, 2, 4] // backoff

    // MARK: - Estado

    private let cacheDir: URL
    private var fileAccessTimes: [String: Date] = [:]       // songId → last access
    private var fileSizes: [String: Int64] = [:]             // songId → bytes
    private var activeDownloads: [String: URLSessionDataTask] = [:]
    private var pendingContinuations: [String: [CheckedContinuation<URL, Error>]] = [:]
    private let queue = DispatchQueue(label: "com.audiorr.audiofileloader", attributes: .concurrent)

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
            print("[AudioFileLoader] Cache hit: \(songId)")
            return localURL
        }

        // Si ya hay una descarga en curso, esperar a que termine
        return try await withCheckedThrowingContinuation { continuation in
            queue.async(flags: .barrier) {
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
        queue.async(flags: .barrier) {
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
        queue.async(flags: .barrier) {
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
        queue.async(flags: .barrier) {
            try? FileManager.default.removeItem(at: self.cacheDir)
            try? FileManager.default.createDirectory(at: self.cacheDir, withIntermediateDirectories: true)
            self.fileAccessTimes.removeAll()
            self.fileSizes.removeAll()
            print("[AudioFileLoader] Cache cleared")
        }
    }

    /// Verifica si un songId está en caché local.
    func isCached(_ songId: String) -> Bool {
        FileManager.default.fileExists(atPath: localPath(for: songId).path)
    }

    // MARK: - Descarga interna

    private func startDownload(remoteURL: URL, songId: String, attempt: Int) {
        let task = URLSession.shared.dataTask(with: remoteURL) { [weak self] data, response, error in
            guard let self = self else { return }

            self.queue.async(flags: .barrier) {
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
                            self.queue.async(flags: .barrier) {
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
                    self.resolveContinuations(songId: songId, result: .success(localURL))
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
        let url = localPath(for: oldest)
        try? FileManager.default.removeItem(at: url)
        fileAccessTimes.removeValue(forKey: oldest)
        fileSizes.removeValue(forKey: oldest)
        print("[AudioFileLoader] Evicted: \(oldest)")
        return oldest
    }

    // MARK: - Utilidades

    private func localPath(for songId: String) -> URL {
        cacheDir.appendingPathComponent("\(songId).mp3")
    }

    private func touchAccess(_ songId: String) {
        queue.async(flags: .barrier) {
            self.fileAccessTimes[songId] = Date()
        }
    }
}
