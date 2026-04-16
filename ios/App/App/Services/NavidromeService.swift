import Foundation

/// Swift equivalent of navidromeApi.ts — reads credentials from UserDefaults
/// (AppDelegate bridges them from WKWebView localStorage on first launch).
final class NavidromeService: ObservableObject {

    static let shared = NavidromeService()

    private(set) var credentials: NavidromeCredentials?

    // Simple in-memory cache: key → (value, expiry)
    private var cache: [String: (Any, Date)] = [:]
    private let cacheTTL: TimeInterval = 300  // 5 minutes

    private init() {
        reloadCredentials()
    }

    // MARK: - Credentials

    /// Reload from Keychain (primary) or UserDefaults migration fallback.
    func reloadCredentials() {
        credentials = CredentialsStore.shared.load()
    }

    /// Save credentials natively. Caller is responsible for bridging to JS if needed.
    func saveCredentials(_ creds: NavidromeCredentials) {
        credentials = creds
        CredentialsStore.shared.save(creds)
    }

    func clearCredentials() {
        credentials = nil
        CredentialsStore.shared.delete()
    }

    var isConfigured: Bool { credentials != nil }

    // MARK: - Auth

    private func authQuery() -> String {
        guard let c = credentials, let token = c.token else { return "" }
        let u = c.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? c.username
        let p = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        return "u=\(u)&p=\(p)&v=1.16.0&c=audiorr&f=json"
    }

    private func baseURL() -> String? { credentials?.serverUrl }

    // MARK: - Cover art URL

    func coverURL(id: String?, size: Int = 300) -> URL? {
        guard let id, !id.isEmpty, let base = baseURL() else { return nil }
        return URL(string: "\(base)/rest/getCoverArt.view?\(authQuery())&id=\(id)&size=\(size)")
    }

    /// URL base del backend de Audiorr (puerto 2999 por defecto).
    /// nil si no está disponible o no se ha bridgeado todavía.
    func backendURL() -> String? {
        UserDefaults.standard.string(forKey: "audiorr_backend_url")
    }

    /// URL de la cover generada por el backend para una playlist.
    /// Se refresca automáticamente cada 5 minutos (mismo _t que el frontend).
    func playlistBackendCoverURL(playlistId: String) -> URL? {
        guard let base = backendURL() else { return nil }
        let t = Int(Date().timeIntervalSince1970 / 300)
        return URL(string: "\(base)/api/playlists/\(playlistId)/cover.png?_t=\(t)")
    }

    func streamURL(songId: String) -> URL? {
        guard let base = baseURL(), !songId.isEmpty else { return nil }
        return URL(string: "\(base)/rest/stream.view?\(authQuery())&id=\(songId)&format=raw")
    }

    // MARK: - Homepage layout

    /// Fetches the sections layout from `GET /api/settings/homepage_layout`.
    /// Returns empty array if backend is unavailable or the key is not set.
    func getHomepageLayout() async -> [PlaylistSection] {
        guard let base = backendURL(),
              let url = URL(string: "\(base)/api/settings/homepage_layout") else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        struct Response: Decodable { let value: [PlaylistSection]? }
        return (try? JSONDecoder().decode(Response.self, from: data))?.value ?? []
    }

    // MARK: - Playlists

    func getPlaylists() async throws -> [NavidromePlaylist] {
        guard let base = baseURL() else { return [] }
        let url = URL(string: "\(base)/rest/getPlaylists.view?\(authQuery())")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder.decodeSubsonic(PlaylistsResponse.self, from: data)
        guard response.status == "ok" else { return [] }
        return response.playlists?.playlist ?? []
    }

    func getPlaylistSongs(playlistId: String) async throws -> (playlist: NavidromePlaylist?, songs: [NavidromeSong]) {
        guard let base = baseURL() else { return (nil, []) }
        let url = URL(string: "\(base)/rest/getPlaylist.view?\(authQuery())&id=\(playlistId)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder.decodeSubsonic(PlaylistDetailResponse.self, from: data)
        guard response.status == "ok", let detail = response.playlist else { return (nil, []) }
        let playlist = NavidromePlaylist(
            id: detail.id, name: detail.name, comment: nil,
            songCount: detail.entry?.count ?? 0, duration: 0,
            owner: nil, coverArt: detail.coverArt, changed: nil
        )
        return (playlist, detail.entry ?? [])
    }

    // MARK: - Artist detail

    func getArtistDetail(artistId: String) async throws -> (artist: NavidromeArtist?, albums: [NavidromeAlbum]) {
        guard let base = baseURL() else { return (nil, []) }
        let url = URL(string: "\(base)/rest/getArtist.view?\(authQuery())&id=\(artistId)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder.decodeSubsonic(ArtistDetailResponse.self, from: data)
        guard response.status == "ok", let d = response.artist else { return (nil, []) }
        let artist = NavidromeArtist(id: d.id, name: d.name, albumCount: d.albumCount)
        return (artist, d.album ?? [])
    }

    // MARK: - Album

    func getAlbumDetail(albumId: String) async throws -> (album: NavidromeAlbum?, songs: [NavidromeSong]) {
        guard let base = baseURL() else { return (nil, []) }
        let url = URL(string: "\(base)/rest/getAlbum.view?\(authQuery())&id=\(albumId)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder.decodeSubsonic(AlbumDetailResponse.self, from: data)
        guard response.status == "ok", let d = response.album else { return (nil, []) }
        let album = NavidromeAlbum(
            id: d.id, name: d.name, artist: d.artist,
            coverArt: d.coverArt, songCount: d.songCount ?? d.song?.count,
            duration: d.duration, year: d.year, genre: d.genre
        )
        return (album, d.song ?? [])
    }

    // MARK: - Search

    func searchAll(query: String, artistCount: Int = 5, albumCount: Int = 5, songCount: Int = 5) async throws -> SearchResults {
        guard let base = baseURL() else { return SearchResults() }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlStr = "\(base)/rest/search2.view?\(authQuery())&query=\(q)&artistCount=\(artistCount)&albumCount=\(albumCount)&songCount=\(songCount)"
        guard let url = URL(string: urlStr) else { return SearchResults() }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder.decodeSubsonic(Search2Response.self, from: data)
        guard response.status == "ok", let r = response.searchResult2 else { return SearchResults() }

        return SearchResults(
            artists: r.artist ?? [],
            albums:  r.album  ?? [],
            songs:   r.song   ?? []
        )
    }

    // MARK: - Artist avatar

    func artistAvatarURL(artistId: String) async -> URL? {
        let cacheKey = "avatar_\(artistId)"
        if let (cached, expiry) = cache[cacheKey], Date() < expiry {
            return cached as? URL
        }

        guard let base = baseURL() else { return nil }
        let urlStr = "\(base)/rest/getArtistInfo2.view?\(authQuery())&id=\(artistId)"
        guard let url = URL(string: urlStr) else { return nil }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder.decodeSubsonic(ArtistInfoResponse.self, from: data),
              response.status == "ok"
        else {
            cache[cacheKey] = (Optional<URL>.none as Any, Date().addingTimeInterval(cacheTTL))
            return nil
        }

        let info = response.artistInfo2
        let imageUrl = [info?.largeImageUrl, info?.mediumImageUrl, info?.smallImageUrl]
            .compactMap { $0 }
            .compactMap { URL(string: $0) }
            .first

        cache[cacheKey] = (imageUrl as Any, Date().addingTimeInterval(cacheTTL))
        return imageUrl
    }
}
