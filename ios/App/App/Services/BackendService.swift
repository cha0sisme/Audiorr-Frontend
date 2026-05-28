import Foundation

/// Native HTTP client for the Audiorr backend (replaces backendApi.ts).
/// Uses URLSession async/await. Base URL derived from NavidromeService.
final class BackendService {

    static let shared = BackendService()
    // Sesión `background`: cliente del backend Audiorr (catálogo, settings, etc).
    // Bajo congestión cede a audio + interactive.
    private let session = AudiorrNetwork.background
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
        let data = try await performRequest(request)
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
        // Opcionales — backend puede no emitirlos. iOS los aprovecha cuando llegan
        // (cross-device restore de modo DJ + contexto). Mientras backend no los
        // emita, el restore local desde UserDefaults cubre el device mismo.
        var contextUri: String?
        var playbackMode: String?  // "normal" | "dj"
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
        let data = try await performRequest(request)
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
        let data = try await performRequest(request)
        let dict = try jsonDict(from: data)
        return dict["mixes"] as? [[String: Any]] ?? []
    }

    func generateDailyMixes() async throws -> [String: Any] {
        var request = try makeRequest(path: "/api/daily-mixes/generate", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in navidromeHeaders { request.setValue(v, forHTTPHeaderField: k) }
        let data = try await performRequest(request)
        return try jsonDict(from: data)
    }

    // MARK: - Smart Playlists

    func getSmartPlaylists() async throws -> [[String: Any]] {
        var request = try makeRequest(path: "/api/smart-playlists", method: "GET")
        for (k, v) in navidromeHeaders { request.setValue(v, forHTTPHeaderField: k) }
        let data = try await performRequest(request)
        let dict = try jsonDict(from: data)
        return dict["playlists"] as? [[String: Any]] ?? []
    }

    func generateSmartPlaylist(key: String) async throws -> [String: Any] {
        var request = try makeRequest(path: "/api/smart-playlists/\(key.urlEncoded)/generate", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in navidromeHeaders { request.setValue(v, forHTTPHeaderField: k) }
        let data = try await performRequest(request)
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
        // Campos additivos del contrato Bearer (Cloudflare Zero Trust migration).
        // Opcionales por retrocompat: backends previos a `523d837` no los emiten.
        // JSON Decoder ignora keys ausentes en propiedades Optional.
        let refreshToken: String?
        let refreshExpiresIn: Int?
        let isAdmin: Bool?
    }

    /// Resultado de `POST /api/auth/refresh`. Mismos campos que `LoginResult`
    /// salvo `username` (el backend no lo devuelve en refresh — el caller debe
    /// reusar el guardado de la sesion previa).
    struct RefreshResult: Decodable {
        let token: String
        let refreshToken: String
        let expiresIn: Int
        let refreshExpiresIn: Int
        let isAdmin: Bool?
    }

    func login(serverUrl: String, username: String, token: String) async throws -> LoginResult {
        var request = try makeRequest(path: "/api/auth/login", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["serverUrl": serverUrl, "username": username, "token": token]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Login NO lleva Bearer (es el que lo emite). performRequest sigue
        // traduciendo status codes y persistiendo 429 en lockedUntil.
        let data = try await performRequest(request, injectBearer: false)
        return try jsonDecoder.decode(LoginResult.self, from: data)
    }

    /// Rota el par sessionToken+refreshToken. El backend acepta solo el
    /// refreshToken en el body (NO en cabecera Authorization) y devuelve el
    /// par nuevo. Si responde 401, el refreshToken esta expirado o invalidado
    /// y el caller (`AuthTokenStore.refresh()`) debe limpiar la sesion.
    func refresh(refreshToken: String) async throws -> RefreshResult {
        var request = try makeRequest(path: "/api/auth/refresh", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refreshToken])
        let data = try await performRequest(request, injectBearer: false)
        return try jsonDecoder.decode(RefreshResult.self, from: data)
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
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return false }
        // Validate service identity when field is present
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let service = json["service"] as? String {
            return service == "audiorr"
        }
        // No service field → legacy backend, accept transitionally
        // TODO(backend-v2.0): Return false here once all backends include service field.
        return true
    }

    // MARK: - Private HTTP helpers

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        return request
    }

    private func get(path: String) async throws -> Data {
        let request = try makeRequest(path: path, method: "GET")
        return try await performRequest(request)
    }

    private func post(path: String, body: some Encodable) async throws -> Data {
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(body)
        return try await performRequest(request)
    }

    private func post(path: String, jsonObject: Any) async throws -> Data {
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
        return try await performRequest(request)
    }

    private func post(path: String, rawBody: Data) async throws -> Data {
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = rawBody
        return try await performRequest(request)
    }

    private func put(path: String, jsonObject: Any) async throws -> Data {
        var request = try makeRequest(path: path, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
        return try await performRequest(request)
    }

    private func put(path: String, rawBody: Data) async throws -> Data {
        var request = try makeRequest(path: path, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = rawBody
        return try await performRequest(request)
    }

    private func delete(path: String) async throws -> Data {
        let request = try makeRequest(path: path, method: "DELETE")
        return try await performRequest(request)
    }

    /// Traduce el status code de la respuesta backend en un error tipado.
    /// `performRequest()` captura `.unauthorized` y `.rateLimited` para
    /// orquestar refresh + lockout persistente; el resto sube al caller tal cual.
    private func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw BackendError.unauthorized
        case 403:
            throw BackendError.forbidden(reason: nil)
        case 429:
            let header = http.value(forHTTPHeaderField: "Retry-After")
            let retryAfter = header.flatMap { TimeInterval($0) } ?? 60
            throw BackendError.rateLimited(retryAfter: retryAfter)
        case 503:
            throw BackendError.serviceUnavailable
        default:
            throw BackendError.httpError(http.statusCode)
        }
    }

    /// Wrapper async que inyecta `Authorization: Bearer` cuando hay sesion en
    /// `AuthTokenStore`, ejecuta la request, traduce el status code y orquesta
    /// el path de recuperacion 401 → refresh → retry una vez.
    ///
    /// `injectBearer=false` para endpoints que **emiten** el token (login,
    /// refresh): sin Bearer, sin retry-on-401 (no tendria sentido). Las
    /// demas semanticas (status codes tipados, persistir 429 en lockedUntil)
    /// se mantienen.
    ///
    /// Si el refresh falla o el reintento vuelve a recibir 401, limpia la
    /// sesion en cache. Si recibe 429, persiste el `Retry-After` en
    /// `AuthTokenStore.setLockedUntil` para que sobreviva cold launch y
    /// otros callers tambien lo respeten.
    ///
    /// Cuando `AuthTokenStore.currentToken()` devuelve `nil` (sin sesion, o
    /// `backendUnauthorized` activo), la request sale sin Bearer — equivalente
    /// al comportamiento previo a la migracion, sin overhead anadido.
    private func performRequest(_ request: URLRequest,
                                allowRetry: Bool = true,
                                injectBearer: Bool = true) async throws -> Data {
        var finalRequest = request
        // `ensureSession()` devuelve el token cacheado (fast-path) o, si no hay
        // sesion, hace login + persiste de forma serializada. Asi la primera REST
        // tras un cold launch ya viaja con Bearer sin depender de que el Connect
        // Hub haya logueado antes. Si no hay sesion establecible (sin creds, gate
        // activo, backend legacy), devuelve nil y la request sale sin Bearer
        // (degradacion a modo Navidrome puro, comportamiento pre-migracion).
        if injectBearer, let token = try? await AuthTokenStore.shared.ensureSession() {
            finalRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: finalRequest)

        do {
            try checkResponse(response)
            return data
        } catch BackendError.unauthorized {
            guard injectBearer, allowRetry else {
                throw BackendError.unauthorized
            }
            do {
                _ = try await AuthTokenStore.shared.refresh()
            } catch {
                await AuthTokenStore.shared.clear()
                throw BackendError.unauthorized
            }
            return try await performRequest(request, allowRetry: false, injectBearer: true)
        } catch BackendError.rateLimited(let retryAfter) {
            AuthTokenStore.shared.setLockedUntil(Date().addingTimeInterval(retryAfter))
            throw BackendError.rateLimited(retryAfter: retryAfter)
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
    case unauthorized                            // 401: sin/mal Bearer y refresh ha fallado
    case forbidden(reason: String?)              // 403: cuenta no autorizada (whitelist) o sin admin
    case rateLimited(retryAfter: TimeInterval)   // 429: respeta `Retry-After`
    case serviceUnavailable                      // 503: backend o Navidrome temporalmente caído
    case httpError(Int)                          // resto, fallback
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .noBaseURL:               "Audiorr backend URL not configured"
        case .invalidResponse:         "Invalid response from backend"
        case .unauthorized:            "Audiorr backend session unauthorized"
        case .forbidden(let reason):   reason.map { "Audiorr backend forbidden: \($0)" } ?? "Audiorr backend forbidden"
        case .rateLimited(let after):  "Audiorr backend rate limited (retry in \(Int(after))s)"
        case .serviceUnavailable:      "Audiorr backend temporarily unavailable"
        case .httpError(let code):     "Backend HTTP error \(code)"
        case .invalidJSON:             "Invalid JSON response"
        }
    }
}

// MARK: - URL encoding helper

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
