import Foundation

/// Native HTTP client for the Audiorr backend (replaces backendApi.ts).
/// Uses URLSession async/await. Base URL derived from NavidromeService.
final class BackendService {

    static let shared = BackendService()
    private let session = URLSession.shared
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    private init() {}

    // MARK: - Base URL

    private var baseURL: String? {
        NavidromeService.shared.backendURL()
    }

    private func url(_ path: String) throws -> URL {
        guard let base = baseURL, let url = URL(string: "\(base)\(path)") else {
            throw BackendError.noBaseURL
        }
        return url
    }

    // MARK: - Navidrome auth headers (for endpoints that need them)

    private var navidromeHeaders: [String: String] {
        guard let creds = NavidromeService.shared.credentials else { return [:] }
        var headers: [String: String] = ["X-Navidrome-User": creds.username]
        if let token = creds.token { headers["X-Navidrome-Token"] = token }
        return headers
    }

    // MARK: - Analysis

    struct AnalysisPayload: Encodable {
        let streamUrl: String
        let songId: String
        let isProactive: Bool?
    }

    func analyzeSong(_ payload: AnalysisPayload) async throws -> [String: Any] {
        var request = try makeRequest(path: "/api/analysis/song", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(payload)
        request.timeoutInterval = 15  // Analysis can be slow (ML processing) but shouldn't hang
        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        return try jsonDict(from: data)
    }

    func getBulkAnalysisStatus(songIds: [String]) async throws -> [String: Any] {
        let body = ["songIds": songIds]
        let data = try await post(path: "/api/analysis/bulk-status", jsonObject: body)
        let dict = try jsonDict(from: data)
        return dict["results"] as? [String: Any] ?? [:]
    }

    func clearAnalysisCache() async throws {
        _ = try await delete(path: "/api/analysis/cache")
    }

    // MARK: - Canvas

    func getCanvas(songId: String) async throws -> [String: Any]? {
        let data = try await get(path: "/api/canvas/\(songId.urlEncoded)")
        return try? jsonDict(from: data)
    }

    struct CanvasPayload: Encodable {
        let songId: String
        let title: String
        let artist: String
        let album: String?
        let spotifyTrackId: String?
        let canvasUrl: String?
    }

    func saveCanvas(_ payload: CanvasPayload) async throws -> [String: Any] {
        let data = try await post(path: "/api/canvas", body: payload)
        return try jsonDict(from: data)
    }

    // MARK: - Artist Image

    func getArtistImage(name: String) async throws -> (imageUrl: String?, source: String) {
        let data = try await get(path: "/api/artist/image?name=\(name.urlEncoded)")
        let dict = try jsonDict(from: data)
        return (dict["imageUrl"] as? String, dict["source"] as? String ?? "unknown")
    }

    // MARK: - Spotify

    func searchSpotifyTrack(title: String, artist: String, album: String? = nil) async throws -> [String: Any] {
        var params = "title=\(title.urlEncoded)&artist=\(artist.urlEncoded)"
        if let album { params += "&album=\(album.urlEncoded)" }
        let data = try await get(path: "/api/spotify/search?\(params)")
        return try jsonDict(from: data)
    }

    func fetchSpotifyCanvas(trackId: String) async throws -> [String: Any] {
        let data = try await get(path: "/api/spotify/canvas?trackId=\(trackId.urlEncoded)")
        return try jsonDict(from: data)
    }

    // MARK: - Similar Songs

    func getSimilarSongs(artist: String, track: String) async throws -> [String: Any] {
        let body: [String: Any] = ["artist": artist, "track": track]
        let data = try await post(path: "/api/similar-songs", jsonObject: body)
        return try jsonDict(from: data)
    }

    // MARK: - Scrobble

    struct ScrobblePayload: Encodable {
        let username: String
        let songId: String
        let title: String
        let artist: String
        let album: String
        let albumId: String?
        let duration: Double
        let playedAt: String
        let year: Int?
        let genre: String?
        let bpm: Double?
        let energy: Double?
        let contextUri: String?
        let contextName: String?
    }

    func recordScrobble(_ payload: ScrobblePayload) async throws -> [String: Any] {
        let data = try await post(path: "/api/scrobble/scrobble", body: payload)
        return try jsonDict(from: data)
    }

    // MARK: - User Preferences

    struct PinnedPlaylist: Codable {
        let id: String
        let name: String
        let position: Int?
    }

    func getPinnedPlaylists(username: String) async throws -> [PinnedPlaylist] {
        let data = try await get(path: "/api/user/\(username.urlEncoded)/pinned-playlists")
        let dict = try jsonDict(from: data)
        guard let arr = dict["pinnedPlaylists"] else { return [] }
        let arrData = try JSONSerialization.data(withJSONObject: arr)
        return try jsonDecoder.decode([PinnedPlaylist].self, from: arrData)
    }

    func savePinnedPlaylists(username: String, playlists: [PinnedPlaylist]) async throws -> [PinnedPlaylist] {
        let body = try jsonEncoder.encode(["pinnedPlaylists": playlists])
        let data = try await post(path: "/api/user/\(username.urlEncoded)/pinned-playlists", rawBody: body)
        let dict = try jsonDict(from: data)
        guard let arr = dict["pinnedPlaylists"] else { return [] }
        let arrData = try JSONSerialization.data(withJSONObject: arr)
        return try jsonDecoder.decode([PinnedPlaylist].self, from: arrData)
    }

    func getUserPreferences(username: String) async throws -> [String: Any] {
        let data = try await get(path: "/api/user/\(username.urlEncoded)/preferences")
        return try jsonDict(from: data)
    }

    func updateAvatar(username: String, avatarUrl: String?) async throws -> String? {
        let body: [String: Any?] = ["avatarUrl": avatarUrl]
        let data = try await put(path: "/api/user/\(username.urlEncoded)/avatar", jsonObject: body as [String: Any])
        let dict = try jsonDict(from: data)
        return dict["avatarUrl"] as? String
    }

    // MARK: - Playback Position Persistence

    struct LastPlaybackQueueItem: Codable {
        let id: String
        let title: String
        let artist: String
        let album: String
        var albumId: String?
        var coverArt: String?
        var duration: Double
    }

    struct LastPlaybackState: Codable {
        let songId: String
        let title: String
        let artist: String
        let album: String
        var coverArt: String?
        var albumId: String?
        let path: String
        let duration: Double
        var position: Double
        var savedAt: String
        var queue: [LastPlaybackQueueItem]?
        var currentIndex: Int?
    }

    func getLastPlayback(username: String) async -> LastPlaybackState? {
        guard let data = try? await get(path: "/api/user/\(username.urlEncoded)/last-playback"),
              let dict = try? jsonDict(from: data),
              let pb = dict["lastPlayback"],
              !(pb is NSNull)
        else { return nil }
        guard let pbData = try? JSONSerialization.data(withJSONObject: pb) else { return nil }
        return try? jsonDecoder.decode(LastPlaybackState.self, from: pbData)
    }

    func saveLastPlayback(username: String, state: LastPlaybackState) {
        Task {
            guard let body = try? jsonEncoder.encode(state) else { return }
            _ = try? await put(path: "/api/user/\(username.urlEncoded)/last-playback", rawBody: body)
        }
    }

    // MARK: - Stats

    func getUserStats(username: String, period: String = "week") async throws -> [String: Any] {
        let data = try await get(path: "/api/stats/user-stats?username=\(username.urlEncoded)&period=\(period)")
        return try jsonDict(from: data)
    }

    func getWrappedStats(username: String, year: Int? = nil) async throws -> [String: Any] {
        var params = "username=\(username.urlEncoded)"
        if let year { params += "&year=\(year)" }
        var request = try makeRequest(path: "/api/stats/wrapped?\(params)", method: "GET")
        for (k, v) in navidromeHeaders { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        return try jsonDict(from: data)
    }

    func getAdminUsers() async throws -> [[String: Any]] {
        let data = try await get(path: "/api/user/admin/users")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        return array
    }

    // MARK: - Daily Mixes

    func getDailyMixes() async throws -> [[String: Any]] {
        var request = try makeRequest(path: "/api/daily-mixes", method: "GET")
        for (k, v) in navidromeHeaders { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        let dict = try jsonDict(from: data)
        return dict["mixes"] as? [[String: Any]] ?? []
    }

    func generateDailyMixes() async throws -> [String: Any] {
        var request = try makeRequest(path: "/api/daily-mixes/generate", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in navidromeHeaders { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        return try jsonDict(from: data)
    }

    // MARK: - Smart Playlists

    func getSmartPlaylists() async throws -> [[String: Any]] {
        var request = try makeRequest(path: "/api/smart-playlists", method: "GET")
        for (k, v) in navidromeHeaders { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        let dict = try jsonDict(from: data)
        return dict["playlists"] as? [[String: Any]] ?? []
    }

    func generateSmartPlaylist(key: String) async throws -> [String: Any] {
        var request = try makeRequest(path: "/api/smart-playlists/\(key.urlEncoded)/generate", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in navidromeHeaders { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        return try jsonDict(from: data)
    }

    // MARK: - Hub / Connect

    struct HubStatus: Decodable {
        let ok: Bool
        let sessions: Int
        let users: Int
        let totalDevices: Int
        let uptimeSeconds: Int
        var serverIp: String?
    }

    func getHubStatus() async throws -> HubStatus {
        let data = try await get(path: "/api/auth/hub-status")
        return try jsonDecoder.decode(HubStatus.self, from: data)
    }

    struct LoginResult: Decodable {
        let token: String
        let username: String
        let expiresIn: Int
    }

    func login(serverUrl: String, username: String, token: String) async throws -> LoginResult {
        let body: [String: String] = ["serverUrl": serverUrl, "username": username, "token": token]
        let data = try await post(path: "/api/auth/login", jsonObject: body)
        return try jsonDecoder.decode(LoginResult.self, from: data)
    }

    // MARK: - Global Settings

    func getGlobalSetting(key: String) async -> Any? {
        guard let data = try? await get(path: "/api/settings/\(key.urlEncoded)"),
              let dict = try? jsonDict(from: data)
        else { return nil }
        return dict["value"]
    }

    func setGlobalSetting(key: String, value: Any) async throws {
        _ = try await put(path: "/api/settings/\(key.urlEncoded)", jsonObject: ["value": value])
    }

    // MARK: - Health

    func checkHealth() async -> Bool {
        guard let url = try? url("/api/health") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        return (try? await session.data(for: request)).map { _, r in
            (r as? HTTPURLResponse)?.statusCode == 200
        } ?? false
    }

    // MARK: - Private HTTP helpers

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        return request
    }

    private func get(path: String) async throws -> Data {
        let request = try makeRequest(path: path, method: "GET")
        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        return data
    }

    private func post(path: String, body: some Encodable) async throws -> Data {
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        return data
    }

    private func post(path: String, jsonObject: Any) async throws -> Data {
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        return data
    }

    private func post(path: String, rawBody: Data) async throws -> Data {
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = rawBody
        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        return data
    }

    private func put(path: String, jsonObject: Any) async throws -> Data {
        var request = try makeRequest(path: path, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        return data
    }

    private func put(path: String, rawBody: Data) async throws -> Data {
        var request = try makeRequest(path: path, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = rawBody
        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        return data
    }

    private func delete(path: String) async throws -> Data {
        let request = try makeRequest(path: path, method: "DELETE")
        let (data, response) = try await session.data(for: request)
        try checkResponse(response)
        return data
    }

    private func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw BackendError.httpError(http.statusCode)
        }
    }

    private func jsonDict(from data: Data) throws -> [String: Any] {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackendError.invalidJSON
        }
        return dict
    }
}

// MARK: - Errors

enum BackendError: LocalizedError {
    case noBaseURL
    case invalidResponse
    case httpError(Int)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .noBaseURL: "Audiorr backend URL not configured"
        case .invalidResponse: "Invalid response from backend"
        case .httpError(let code): "Backend HTTP error \(code)"
        case .invalidJSON: "Invalid JSON response"
        }
    }
}

// MARK: - URL encoding helper

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
