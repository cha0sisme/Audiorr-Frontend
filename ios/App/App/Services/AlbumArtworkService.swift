import Foundation

/// Resuelve y cachea URLs de animated artwork (motion artwork de Apple Music)
/// por álbum.
///
/// Backend: GET /api/album-artwork/{albumId} → { fileUrl, fileUrlTall, ... }
/// Serving: GET /api/album-artwork/files/{archivo}.mp4
///
/// El backend ya entrega rutas listas (`/api/album-artwork/files/...`), por lo
/// que aquí solo se prefijan con la base del backend. A diferencia de
/// `CanvasService`, **no** hay reescritura de regex.
///
/// Preferimos `fileUrlTall` (3:4 portrait) sobre `fileUrl` (1:1 square),
/// porque el viewer iPhone se ve a pantalla completa vertical y la spec de
/// Apple para motion artwork en iPhone es exactamente 3:4.
@MainActor
final class AlbumArtworkService {
    static let shared = AlbumArtworkService()

    /// Resultado del lookup.
    enum AlbumArtworkResult {
        case video(URL)   // animated artwork disponible (tall preferido)
        case none         // 404 o sin fileUrl* → usar cover estático
    }

    // Caché en memoria: albumId → URL resuelta (nil = sin artwork confirmado).
    private var cache: [String: URL?] = [:]
    private var cacheOrder: [String] = [] // FIFO eviction
    private let maxCacheSize = 200
    // Requests en vuelo para deduplicar.
    private var pending: [String: Task<URL?, Never>] = [:]

    private init() {}

    /// Resuelve el animated artwork para un álbum. Cachea resultados.
    func resolve(albumId: String) async -> AlbumArtworkResult {
        if let cached = cache[albumId] {
            if let url = cached { return .video(url) }
            return .none
        }

        if let existing = pending[albumId] {
            let result = await existing.value
            if let url = result { return .video(url) }
            return .none
        }

        let task = Task<URL?, Never> {
            await fetchArtworkUrl(albumId: albumId)
        }
        pending[albumId] = task
        let result = await task.value
        pending[albumId] = nil

        if cache[albumId] == nil {
            if cacheOrder.count >= maxCacheSize, let oldest = cacheOrder.first {
                cacheOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            }
            cacheOrder.append(albumId)
        }
        cache[albumId] = result

        if let url = result { return .video(url) }
        return .none
    }

    /// Invalidar caché de un álbum (p.ej. tras error de reproducción).
    func invalidate(albumId: String) {
        cache[albumId] = nil
    }

    // MARK: - Private

    private func fetchArtworkUrl(albumId: String) async -> URL? {
        guard !albumId.isEmpty,
              let backendBase = backendBaseURL() else { return nil }

        let endpoint = backendBase.appendingPathComponent("api/album-artwork/\(albumId)")
        do {
            // Sesión `interactive`: UI visible cuando el viewer está abierto.
            let (data, response) = try await AudiorrNetwork.interactive.data(from: endpoint)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                // 404 = álbum sin fila en DB. Caso normal de "sin motion", no
                // error ruidoso. La caché del caller marca el resultado como
                // negativo y no se reintenta.
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            // El backend es la autoridad: si `matchStatus` indica que no hay
            // motion para este álbum, cortocircuito sin mirar URLs. Blinda
            // contra filas legacy con `fileUrl` poblado pero estado negativo.
            if let matchStatus = json["matchStatus"] as? String,
               matchStatus == "no-motion" || matchStatus == "not-found" {
                return nil
            }

            // Fallback obligatorio: tall (3:4, iPhone) → square (1:1) → nil.
            // Un álbum puede tener fileUrl pero fileUrlTall = null (best-effort
            // del backend); en ese caso el square se ve OK con resizeAspectFill,
            // recortado vertical.
            if let tall = json["fileUrlTall"] as? String, !tall.isEmpty {
                return backendBase.appendingPathComponent(tall)
            }
            if let square = json["fileUrl"] as? String, !square.isEmpty {
                return backendBase.appendingPathComponent(square)
            }
            return nil
        } catch {
            return nil
        }
    }

    private func backendBaseURL() -> URL? {
        guard let urlStr = NavidromeService.shared.backendURL(),
              let url = URL(string: urlStr) else { return nil }
        return url
    }
}
