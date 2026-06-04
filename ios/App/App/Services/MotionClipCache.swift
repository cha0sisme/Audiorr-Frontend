import Foundation

/// Caché LRU en disco para los clips de vídeo del motion artwork de la pantalla
/// de bloqueo (`MPMediaItemAnimatedArtwork` exige una URL de FICHERO LOCAL).
///
/// Vive en `Caches/Audiorr/Motion/`, SEPARADA de la caché de música. Los clips
/// se deduplican por clave (`{albumId}_{aspecto}`) y comparten fichero entre
/// todas las canciones de un mismo álbum. Las entradas `pinned` (descargadas
/// junto a un álbum offline) nunca se evictan; el resto se reciclan por LRU
/// cuando se supera `PersistenceService.motionMaxCacheBytes`.
actor MotionClipCache {
    static let shared = MotionClipCache()

    private struct Entry: Codable {
        var fileName: String
        var size: Int64
        var lastAccessed: Date
        var pinned: Bool
    }

    private let dir: URL
    private let indexURL: URL
    private var index: [String: Entry] = [:]
    private var pending: [String: Task<URL?, Never>] = [:]
    private var loaded = false

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("Audiorr/Motion", isDirectory: true)
        indexURL = dir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Public

    /// URL local del clip, descargándolo si hace falta. `pin` lo marca como
    /// no-evictable (uso: descarga offline del álbum). Devuelve nil si falla.
    func localURL(key: String, remoteURL: URL, pin: Bool = false) async -> URL? {
        loadIndexIfNeeded()

        if var entry = index[key], FileManager.default.fileExists(atPath: fileURL(entry.fileName).path) {
            entry.lastAccessed = Date()
            if pin { entry.pinned = true }
            index[key] = entry
            persistIndex()
            return fileURL(entry.fileName)
        }

        let task: Task<URL?, Never>
        if let inflight = pending[key] {
            task = inflight
        } else {
            task = Task<URL?, Never> { await download(key: key, remoteURL: remoteURL, pin: pin) }
            pending[key] = task
        }
        // Propaga la cancelación del caller (p.ej. un skip de canción) a la
        // descarga: si el tema cambia mientras el clip se está bajando —típico
        // con poca cobertura, donde la descarga es lenta— se aborta la petición
        // de red en vez de seguir gastando datos por un tema ya saltado.
        let url = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        pending[key] = nil
        return url
    }

    /// Descarga y fija (pin) un clip sin devolverlo — para la descarga offline.
    func prefetchPinned(key: String, remoteURL: URL) async {
        _ = await localURL(key: key, remoteURL: remoteURL, pin: true)
    }

    /// Quita el pin de un clip (al borrar la descarga offline del álbum); queda
    /// sujeto a evicción LRU como cualquier otro.
    func unpin(key: String) {
        loadIndexIfNeeded()
        guard var entry = index[key] else { return }
        entry.pinned = false
        index[key] = entry
        persistIndex()
    }

    // MARK: - Private

    private func download(key: String, remoteURL: URL, pin: Bool) async -> URL? {
        let ext = remoteURL.pathExtension.isEmpty ? "mp4" : remoteURL.pathExtension
        let name = "\(key).\(ext)"
        let dest = fileURL(name)
        guard let (data, response) = try? await AudiorrNetwork.background.data(from: remoteURL),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              !data.isEmpty else {
            return nil
        }
        try? FileManager.default.removeItem(at: dest)
        guard (try? data.write(to: dest)) != nil else { return nil }

        index[key] = Entry(fileName: name, size: Int64(data.count), lastAccessed: Date(), pinned: pin)
        persistIndex()
        evictIfNeeded()
        return dest
    }

    private func evictIfNeeded() {
        let cap = PersistenceService.shared.motionMaxCacheBytes
        guard cap > 0 else { return }
        var total = index.values.reduce(Int64(0)) { $0 + $1.size }
        guard total > cap else { return }
        // LRU solo entre los NO fijados.
        let victims = index
            .filter { !$0.value.pinned }
            .sorted { $0.value.lastAccessed < $1.value.lastAccessed }
        for (k, e) in victims {
            if total <= cap { break }
            try? FileManager.default.removeItem(at: fileURL(e.fileName))
            index.removeValue(forKey: k)
            total -= e.size
        }
        persistIndex()
    }

    private func fileURL(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private func loadIndexIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            index = decoded
        }
        // Purga entradas cuyo fichero ya no existe (limpieza externa de Caches).
        for (k, e) in index where !FileManager.default.fileExists(atPath: fileURL(e.fileName).path) {
            index.removeValue(forKey: k)
        }
    }

    private func persistIndex() {
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL)
        }
    }
}
