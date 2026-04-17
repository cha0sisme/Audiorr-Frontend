import Foundation

/// Resolves and caches canvas video URLs for songs.
/// Backend API: GET /api/canvas/{songId} → { localPath, canvasUrl }
/// File serving: GET /api/canvas/files/{TRACKID}.mp4
@MainActor
final class CanvasService {
    static let shared = CanvasService()

    /// Result of a canvas lookup.
    enum CanvasResult {
        case video(URL)
        case image(URL)
        case none
    }

    // In-memory cache: songId → resolved URL (nil = confirmed no canvas)
    private var cache: [String: URL?] = [:]
    // Pending fetches to avoid duplicate requests
    private var pending: [String: Task<URL?, Never>] = [:]

    private init() {}

    /// Resolve canvas URL for a song. Returns cached result if available.
    func resolve(songId: String) async -> CanvasResult {
        // Check cache first
        if let cached = cache[songId] {
            if let url = cached { return classify(url) }
            return .none
        }

        // Deduplicate in-flight requests
        if let existing = pending[songId] {
            let result = await existing.value
            if let url = result { return classify(url) }
            return .none
        }

        let task = Task<URL?, Never> {
            await fetchCanvasUrl(songId: songId)
        }
        pending[songId] = task
        let result = await task.value
        pending[songId] = nil
        cache[songId] = result

        if let url = result { return classify(url) }
        return .none
    }

    /// Invalidate cache for a song (e.g. on error).
    func invalidate(songId: String) {
        cache[songId] = nil
    }

    // MARK: - Private

    private func fetchCanvasUrl(songId: String) async -> URL? {
        guard !songId.isEmpty,
              let backendBase = backendBaseURL() else { return nil }

        let endpoint = backendBase.appendingPathComponent("api/canvas/\(songId)")
        do {
            let (data, response) = try await URLSession.shared.data(from: endpoint)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            // Priority: localPath > canvasUrl (same as React resolveCanvasUrl)
            if let localPath = json["localPath"] as? String, !localPath.isEmpty {
                // localPath stored as "/canvas-files/TRACKID.mp4"
                // Rewrite to "/api/canvas/files/TRACKID.mp4"
                let apiPath = localPath.replacingOccurrences(
                    of: "^/canvas-files/",
                    with: "/api/canvas/files/",
                    options: .regularExpression
                )
                return backendBase.appendingPathComponent(apiPath)
            }
            if let canvasUrl = json["canvasUrl"] as? String, !canvasUrl.isEmpty {
                return URL(string: canvasUrl)
            }
            return nil
        } catch {
            return nil
        }
    }

    private func backendBaseURL() -> URL? {
        guard let urlStr = UserDefaults.standard.string(forKey: "audiorr_backend_url"),
              !urlStr.isEmpty,
              let url = URL(string: urlStr) else { return nil }
        return url
    }

    private func classify(_ url: URL) -> CanvasResult {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "webp", "gif"].contains(ext) {
            return .image(url)
        }
        return .video(url) // mp4, default
    }
}
