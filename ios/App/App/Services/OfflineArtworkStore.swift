import UIKit

/// Caché en DISCO para las portadas de álbumes/playlists descargados, para que
/// el modo offline muestre las covers aunque el servidor no esté accesible
/// (`AlbumCoverCache` es solo memoria y se pierde al reiniciar la app).
///
/// Clave: el id de coverArt (lo que reciben las vistas) o, en su defecto, el id
/// del álbum/playlist. Se guarda como JPEG en `Caches/Audiorr/Covers/`.
final class OfflineArtworkStore: @unchecked Sendable {
    static let shared = OfflineArtworkStore()

    private let dir: URL
    private let memory = NSCache<NSString, UIImage>()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("Audiorr/Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.countLimit = 200
    }

    /// Imagen cacheada (memoria → disco). Síncrono, apto para vistas.
    func image(forKey key: String) -> UIImage? {
        guard !key.isEmpty else { return nil }
        let nsKey = key as NSString
        if let m = memory.object(forKey: nsKey) { return m }
        guard let data = try? Data(contentsOf: fileURL(key)), let img = UIImage(data: data) else { return nil }
        memory.setObject(img, forKey: nsKey)
        return img
    }

    func store(_ image: UIImage, forKey key: String) {
        guard !key.isEmpty else { return }
        memory.setObject(image, forKey: key as NSString)
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: fileURL(key))
    }

    /// Descarga (si no está ya) y guarda. Idempotente: no hace red si ya existe.
    func ensure(key: String, url: URL?) async {
        guard !key.isEmpty, let url, image(forKey: key) == nil else { return }
        guard let (data, _) = try? await AudiorrNetwork.background.data(from: url),
              let img = UIImage(data: data) else { return }
        store(img, forKey: key)
    }

    private func fileURL(_ key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? String(key.hashValue)
        return dir.appendingPathComponent(safe + ".jpg")
    }
}

extension UIImage {
    /// Recorta (centrado) la imagen a la relación de aspecto del tamaño pedido.
    /// Se usa para el preview del motion artwork: la cover suele ser 1:1 y el
    /// sistema pide 3:4, y `MPMediaItemAnimatedArtwork` puede rechazar imágenes
    /// con aspecto muy divergente. Recortando garantizamos que coincida.
    func croppedToAspect(of size: CGSize) -> UIImage {
        guard size.width > 0, size.height > 0, self.size.width > 0, self.size.height > 0 else { return self }
        let targetAspect = size.width / size.height
        let w = self.size.width
        let h = self.size.height
        var cropW = w
        var cropH = h
        if w / h > targetAspect {
            // Demasiado ancha → recortar los lados.
            cropW = h * targetAspect
        } else {
            // Demasiado alta → recortar arriba/abajo.
            cropH = w / targetAspect
        }
        let originX = (w - cropW) / 2
        let originY = (h - cropH) / 2
        let scale = self.scale
        let rect = CGRect(x: originX * scale, y: originY * scale,
                          width: cropW * scale, height: cropH * scale)
        guard let cg = self.cgImage?.cropping(to: rect) else { return self }
        return UIImage(cgImage: cg, scale: scale, orientation: imageOrientation)
    }
}
