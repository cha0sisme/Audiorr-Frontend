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

    // MARK: - Motion por aspecto (lock screen)

    /// Relación de aspecto del clip. La pantalla de bloqueo iOS 26 expone qué
    /// claves admite (`MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys`):
    /// 3:4 (`tall`, lo habitual en iPhone) o 1:1 (`square`). El caller resuelve
    /// la URL del aspecto que el sistema pide para no enviar un clip cuyo aspect
    /// el sistema rechazaría.
    enum MotionAspect { case square, tall }

    // Caché por (albumId, aspecto): "{albumId}|t" / "{albumId}|s".
    private var aspectCache: [String: URL?] = [:]

    /// URL del clip de motion para el aspecto pedido (sin fallback cruzado:
    /// `tall` devuelve solo `fileUrlTall`, `square` solo `fileUrl`), para que el
    /// clip coincida con la clave del lock screen.
    func motionURL(albumId: String, aspect: MotionAspect) async -> URL? {
        let key = "\(albumId)|\(aspect == .tall ? "t" : "s")"
        if let cached = aspectCache[key] { return cached }
        guard let backendBase = backendBaseURL(),
              let json = await fetchArtworkJSON(albumId: albumId, base: backendBase) else {
            aspectCache[key] = .some(nil)
            return nil
        }
        let field = aspect == .tall ? "fileUrlTall" : "fileUrl"
        var result: URL?
        if let path = json[field] as? String, !path.isEmpty {
            result = backendBase.appendingPathComponent(path)
        }
        aspectCache[key] = .some(result)
        return result
    }

    // MARK: - Private

    private func fetchArtworkUrl(albumId: String) async -> URL? {
        guard let backendBase = backendBaseURL(),
              let json = await fetchArtworkJSON(albumId: albumId, base: backendBase) else { return nil }

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
    }

    /// Descarga y parsea el JSON de `/api/album-artwork/{albumId}`. Devuelve nil
    /// si 404 (sin fila) o si `matchStatus` indica que no hay motion.
    private func fetchArtworkJSON(albumId: String, base backendBase: URL) async -> [String: Any]? {
        guard !albumId.isEmpty else { return nil }
        let endpoint = backendBase.appendingPathComponent("api/album-artwork/\(albumId)")
        do {
            let (data, response) = try await AudiorrNetwork.interactive.data(from: endpoint)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            // El backend es la autoridad: si `matchStatus` indica que no hay
            // motion para este álbum, cortocircuito (blinda contra filas legacy
            // con `fileUrl` poblado pero estado negativo).
            if let matchStatus = json["matchStatus"] as? String,
               matchStatus == "no-motion" || matchStatus == "not-found" {
                return nil
            }
            return json
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
