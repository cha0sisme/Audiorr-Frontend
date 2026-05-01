import Foundation

/// Swift equivalent of navidromeApi.ts — reads credentials from UserDefaults
/// (AppDelegate bridges them from WKWebView localStorage on first launch).
final class NavidromeService: ObservableObject {

    static let shared = NavidromeService()

    private(set) var credentials: NavidromeCredentials?

    // Simple in-memory cache: key → (value, expiry)
    private var cache: [String: (Any, Date)] = [:]
    private let cacheLock = NSLock()
    private let cacheTTL: TimeInterval = 300  // 5 minutes
    private let maxCacheSize = 200

    /// Playlist IDs currently mid-HEAD in `revalidateCoverETags`. Two refresh
    /// triggers (foreground + view task) firing within the same handful of ms
    /// would otherwise both build their `needsCheck` lists before either had
    /// set the TTL tick, double-HEADing each playlist. Set membership is
    /// inserted under the lock, removed once the result is registered.
    private var inflightCoverETagChecks: Set<String> = []
    private let inflightCoverETagLock = NSLock()

    private func cacheGet(_ key: String) -> Any? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let (value, expiry) = cache[key], Date() < expiry else {
            cache.removeValue(forKey: key)
            return nil
        }
        return value
    }

    private func cacheSet(_ key: String, value: Any, ttl: TimeInterval? = nil) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if cache.count >= maxCacheSize {
            let now = Date()
            cache = cache.filter { $0.value.1 > now }
        }
        cache[key] = (value, Date().addingTimeInterval(ttl ?? cacheTTL))
    }

    /// Invalidate the cached backend availability so the next check hits the network.
    func invalidateBackendAvailableCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeValue(forKey: "backendAvailable")
    }

    private init() {
        reloadCredentials()
    }

    // MARK: - Credentials

    /// Reload from Keychain (primary) or UserDefaults migration fallback.
    func reloadCredentials() {
        credentials = CredentialsStore.shared.load()
    }

    /// Save credentials natively.
    func saveCredentials(_ creds: NavidromeCredentials) {
        credentials = creds
        CredentialsStore.shared.save(creds)
        invalidateBackendAvailableCache()
        Task { @MainActor in BackendState.shared.invalidateAndRecheck() }
        NotificationCenter.default.post(name: .audiorrDidLogin, object: nil)
    }

    func clearCredentials() {
        credentials = nil
        CredentialsStore.shared.delete()
        Task { @MainActor in BackendState.shared.reset() }
    }

    var isConfigured: Bool { credentials != nil }

    // MARK: - Auth

    /// Public auth query for external callers (ScrobbleService, etc.).
    func authQueryPublic() -> String { authQuery() }

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



    /// URL base del backend de Audiorr (puerto 2999).
    /// Uses manual override from UserDefaults if set, otherwise derived from Navidrome host.
    func backendURL() -> String? {
        // Manual override for testing
        if let override = UserDefaults.standard.string(forKey: "audiorr_backend_url"),
           !override.isEmpty {
            return override
        }
        guard let serverUrl = credentials?.serverUrl,
              let components = URLComponents(string: serverUrl),
              let host = components.host else { return nil }
        let scheme = components.scheme ?? "http"
        return "\(scheme)://\(host):2999"
    }

    /// Whether a manual backend URL override is active.
    var hasBackendOverride: Bool {
        guard let override = UserDefaults.standard.string(forKey: "audiorr_backend_url") else { return false }
        return !override.isEmpty
    }

    /// Set or clear the manual backend URL override.
    func setBackendOverride(_ url: String?) {
        if let url, !url.isEmpty {
            UserDefaults.standard.set(url, forKey: "audiorr_backend_url")
        } else {
            UserDefaults.standard.removeObject(forKey: "audiorr_backend_url")
        }
        invalidateBackendAvailableCache()
        Task { @MainActor in BackendState.shared.invalidateAndRecheck() }
    }

    /// URL de la cover generada por el backend para una playlist.
    /// When `contentHash` is provided, appends `?v=` for immutable caching.
    func playlistBackendCoverURL(playlistId: String, contentHash: String? = nil) -> URL? {
        guard let base = backendURL() else { return nil }
        let baseURL = "\(base)/api/playlists/\(playlistId)/cover.png"
        if let hash = contentHash, !hash.isEmpty {
            return URL(string: "\(baseURL)?v=\(hash)")
        }
        return URL(string: baseURL)
    }

    /// Check if the Audiorr backend is reachable and verified.
    /// Validates `service: "audiorr"` in the response body to avoid connecting to unrelated services.
    /// Positive results cached for 30s, negative for 10s (retry sooner on failure).
    func checkBackendAvailable() async -> Bool {
        let cacheKey = "backendAvailable"
        if let cached = cacheGet(cacheKey) as? Bool { return cached }

        guard let base = backendURL() else { return false }

        let available = await verifyAudiorrBackend(base: base)
        cacheSet(cacheKey, value: available, ttl: available ? 30 : 10)
        return available
    }

    /// Verifies that the service at `base` is actually Audiorr.
    /// Logic:
    /// - Try GET /api/health first.
    ///   - If response contains `"service"` field: accept only if value is `"audiorr"`, otherwise ABORT (no fallback).
    ///   - If 404 / network error / response has no `"service"` field: fall through to legacy endpoint.
    /// - Fallback: GET /health (legacy Docker healthcheck endpoint).
    ///   - Same validation: if `"service"` field present, must be `"audiorr"`.
    ///   - If no `"service"` field (legacy `{"status":"ok"}`): accept as valid (transitional).
    private func verifyAudiorrBackend(base: String) async -> Bool {
        // --- Primary: /api/health ---
        if let url = URL(string: "\(base)/api/health") {
            switch await checkEndpoint(url: url) {
            case .confirmed: return true
            case .rejected: return false  // service field present but not "audiorr" → abort
            case .legacyResponse, .networkError: break  // try fallback
            }
        }

        // --- Fallback: /health (DEPRECATED — remove when backend >= v2.0 ships /api/health) ---
        // TODO(backend-v2.0): Remove this fallback once all backends serve /api/health with service field.
        if let url = URL(string: "\(base)/health") {
            switch await checkEndpoint(url: url) {
            case .confirmed: return true
            case .rejected: return false
            case .legacyResponse: return true   // 200 OK without service field → accept as legacy
            case .networkError: return false    // unreachable → backend doesn't exist
            }
        }

        return false
    }

    private enum HealthCheckResult {
        case confirmed       // service == "audiorr"
        case rejected        // service field present but != "audiorr"
        case legacyResponse  // 200 OK, no service field in body — possibly legacy backend
        case networkError    // no response, timeout, or non-200 status — backend unreachable
    }

    private func checkEndpoint(url: URL) async -> HealthCheckResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            return .networkError
        }

        // Try to parse service identifier from body
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .legacyResponse
        }

        if let service = json["service"] as? String {
            return service == "audiorr" ? .confirmed : .rejected
        }

        // 200 OK with valid JSON but no "service" field → legacy format
        return .legacyResponse
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

    /// Add a song to a playlist (Subsonic updatePlaylist with songIdToAdd).
    func addSongToPlaylist(playlistId: String, songId: String) async throws {
        guard let base = baseURL() else { return }
        let url = URL(string: "\(base)/rest/updatePlaylist.view?\(authQuery())&playlistId=\(playlistId)&songIdToAdd=\(songId)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder.decodeSubsonic(SubsonicBaseResponse.self, from: data)
        guard response.status == "ok" else {
            throw NSError(domain: "NavidromeService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to add song to playlist"])
        }
    }

    /// Create a new playlist (Subsonic createPlaylist).
    func createPlaylist(name: String) async throws -> String? {
        guard let base = baseURL() else { return nil }
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let url = URL(string: "\(base)/rest/createPlaylist.view?\(authQuery())&name=\(encodedName)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder.decodeSubsonic(CreatePlaylistResponse.self, from: data)
        guard response.status == "ok" else { return nil }
        return response.playlist?.id
    }

    /// Delete a playlist (Subsonic deletePlaylist).
    func deletePlaylist(playlistId: String) async throws {
        guard let base = baseURL() else { return }
        let url = URL(string: "\(base)/rest/deletePlaylist.view?\(authQuery())&id=\(playlistId)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder.decodeSubsonic(SubsonicBaseResponse.self, from: data)
        guard response.status == "ok" else {
            throw NSError(domain: "NavidromeService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to delete playlist"])
        }
    }

    /// Returns only private user playlists (no editorial, spotify, smart, daily mixes).
    func getUserPrivatePlaylists() async -> [NavidromePlaylist] {
        guard let all = try? await getPlaylists(),
              let username = credentials?.username.lowercased()
        else { return [] }

        return all.filter { pl in
            let name = pl.name.lowercased()
            let comment = (pl.comment ?? "").lowercased()
            let owner = (pl.owner ?? "").lowercased()

            // Must be owned by current user
            guard owner == username else { return false }

            // Exclude special playlist types
            if comment.contains("smart playlist") { return false }
            if comment.contains("[editorial]") { return false }
            if comment.contains("spotify synced") { return false }
            if name.hasPrefix("[spotify] ") { return false }
            if name.hasPrefix("mix diario") { return false }

            return true
        }
    }

    // MARK: - All artists (getArtists.view)

    func getArtists() async -> [NavidromeArtist] {
        let cacheKey = "allArtists"
        if let cached = cacheGet(cacheKey) as? [NavidromeArtist] { return cached }

        guard let base = baseURL() else { return [] }
        let urlStr = "\(base)/rest/getArtists.view?\(authQuery())"
        guard let url = URL(string: urlStr) else { return [] }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder.decodeSubsonic(ArtistsResponse.self, from: data),
              response.status == "ok"
        else { return [] }

        let artists = (response.artists?.index ?? [])
            .flatMap { $0.artist }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        cacheSet(cacheKey, value: artists)
        return artists
    }

    // MARK: - Album lists (getAlbumList2.view)

    func getAlbumList(type: String, size: Int = 20, genre: String? = nil) async -> [NavidromeAlbum] {
        guard let base = baseURL() else { return [] }
        var urlStr = "\(base)/rest/getAlbumList2.view?\(authQuery())&type=\(type)&size=\(size)"
        if let genre, let encoded = genre.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlStr += "&genre=\(encoded)"
        }
        guard let url = URL(string: urlStr) else { return [] }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder.decodeSubsonic(AlbumListResponse.self, from: data),
              response.status == "ok"
        else { return [] }

        return response.albumList2?.album ?? []
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

    // MARK: - Song

    func getSong(id: String) async -> NavidromeSong? {
        guard let base = baseURL() else { return nil }
        let urlStr = "\(base)/rest/getSong.view?\(authQuery())&id=\(id)"
        guard let url = URL(string: urlStr),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder.decodeSubsonic(GetSongResponse.self, from: data),
              response.status == "ok"
        else { return nil }
        return response.song
    }

    // MARK: - Album

    func getAlbumDetail(albumId: String) async throws -> (album: NavidromeAlbum?, songs: [NavidromeSong], recordLabels: [RecordLabel]) {
        guard let base = baseURL() else { return (nil, [], []) }
        let url = URL(string: "\(base)/rest/getAlbum.view?\(authQuery())&id=\(albumId)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder.decodeSubsonic(AlbumDetailResponse.self, from: data)
        guard response.status == "ok", let d = response.album else { return (nil, [], []) }
        let album = NavidromeAlbum(
            id: d.id, name: d.name, artist: d.artist,
            coverArt: d.coverArt, songCount: d.songCount ?? d.song?.count,
            duration: d.duration, year: d.year, genre: d.genre,
            explicitStatus: d.explicitStatus
        )
        return (album, d.song ?? [], d.recordLabels)
    }

    /// Album notes/description via `getAlbumInfo2` (Last.fm or manually set in Navidrome).
    func getAlbumInfo(albumId: String) async -> String? {
        let cacheKey = "albumInfo_\(albumId)"
        if let cached = cacheGet(cacheKey) as? String { return cached.isEmpty ? nil : cached }

        guard let base = baseURL() else { return nil }
        let urlStr = "\(base)/rest/getAlbumInfo2.view?\(authQuery())&id=\(albumId)"
        guard let url = URL(string: urlStr) else { return nil }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder.decodeSubsonic(AlbumInfoResponse.self, from: data),
              response.status == "ok",
              let notes = response.albumInfo?.notes,
              !notes.isEmpty
        else {
            cacheSet(cacheKey, value: "", ttl: 3600)
            return nil
        }

        cacheSet(cacheKey, value: notes, ttl: 3600)
        return notes
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

    // MARK: - Artist detail — extra sections (mirrors navidromeApi.ts)

    /// Full artist info (biography + similar artists) via `getArtistInfo2`.
    func getArtistInfo(artistId: String) async -> ArtistInfo? {
        let cacheKey = "artistInfo_\(artistId)"
        if let cached = cacheGet(cacheKey) as? ArtistInfo { return cached }

        guard let base = baseURL() else { return nil }
        let urlStr = "\(base)/rest/getArtistInfo2.view?\(authQuery())&id=\(artistId)"
        guard let url = URL(string: urlStr) else { return nil }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder.decodeSubsonic(ArtistInfoResponse.self, from: data),
              response.status == "ok",
              let info = response.artistInfo2
        else { return nil }

        let result = ArtistInfo(
            biography: info.biography ?? "",
            similarArtists: info.similarArtist
        )
        cacheSet(cacheKey, value: result, ttl: 3600)
        return result
    }

    /// Top songs for an artist — tries `getTopSongs` (Last.fm) then falls back
    /// to flattening songs from the artist's albums via `getArtist`.
    func getArtistSongs(artistName: String, count: Int = 10) async -> [NavidromeSong] {
        guard let base = baseURL() else { return [] }
        let q = artistName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? artistName

        // 1. Try getTopSongs.view (Last.fm-powered).
        var topSongs: [NavidromeSong] = []
        let topURLStr = "\(base)/rest/getTopSongs.view?\(authQuery())&artist=\(q)&count=\(count)"
        if let url = URL(string: topURLStr),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let response = try? JSONDecoder.decodeSubsonic(TopSongsResponse.self, from: data),
           response.status == "ok" {
            topSongs = response.topSongs?.song ?? []
        }

        if topSongs.count >= count { return Array(topSongs.prefix(count)) }

        // 2. Fallback: flatten songs from artist albums via search2.
        let searchURL = "\(base)/rest/search2.view?\(authQuery())&query=\(q)&artistCount=0&albumCount=0&songCount=\(count * 3)"
        var fallbackSongs: [NavidromeSong] = []
        if let url = URL(string: searchURL),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let response = try? JSONDecoder.decodeSubsonic(Search2Response.self, from: data),
           response.status == "ok" {
            let lower = artistName.lowercased()
            fallbackSongs = (response.searchResult2?.song ?? []).filter {
                $0.artist.lowercased().contains(lower)
            }
        }

        // Merge — top first, then fallback (dedup by id).
        var seen = Set<String>()
        var merged: [NavidromeSong] = []
        for s in topSongs + fallbackSongs where !seen.contains(s.id) {
            seen.insert(s.id); merged.append(s)
        }
        return Array(merged.prefix(count))
    }

    /// Albums where the artist appears as a collaborator (not the main artist).
    /// Mirrors navidromeApi.ts `getArtistCollaborations`.
    func getArtistCollaborations(artistName: String) async -> [NavidromeAlbum] {
        guard let base = baseURL() else { return [] }
        let q = artistName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? artistName
        let urlStr = "\(base)/rest/search2.view?\(authQuery())&query=\(q)&artistCount=0&albumCount=1000&songCount=0"
        guard let url = URL(string: urlStr),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder.decodeSubsonic(Search2Response.self, from: data),
              response.status == "ok"
        else { return [] }

        let lower = artistName.lowercased()
        let mainPrefixes = [",", " &", " and", " ", " feat", " ft", " featuring"]

        return (response.searchResult2?.album ?? [])
            .filter { album in
                let a = album.artist.lowercased()
                let isMain = a == lower || mainPrefixes.contains { a.hasPrefix(lower + $0) }
                return !isMain && a.contains(lower)
            }
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    /// Playlists containing at least one song by the artist (excludes smart +
    /// daily-mix playlists). Mirrors navidromeApi.ts `getPlaylistsByArtist`.
    func getPlaylistsByArtist(artistName: String) async -> [NavidromePlaylist] {
        guard let all = try? await getPlaylists() else { return [] }

        // Pre-filter: skip smart + daily mixes.
        let candidates = all.filter { pl in
            let name = pl.name.lowercased()
            let comment = pl.comment ?? ""
            return !comment.contains("Smart Playlist")
                && !name.contains("mix diario")
                && !comment.lowercased().contains("mix diario")
        }

        let lower = artistName.lowercased()

        // Parallelise playlist-song checks.
        return await withTaskGroup(of: (Int, NavidromePlaylist?).self) { group in
            for (idx, pl) in candidates.enumerated() {
                group.addTask {
                    guard let (_, songs) = try? await NavidromeService.shared.getPlaylistSongs(playlistId: pl.id) else {
                        return (idx, nil)
                    }
                    let match = songs.contains { song in
                        Self.artistMatches(needle: lower, in: song.artist.lowercased())
                    }
                    return (idx, match ? pl : nil)
                }
            }

            var results: [(Int, NavidromePlaylist)] = []
            for await (idx, pl) in group {
                if let pl { results.append((idx, pl)) }
            }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    /// Loose match for artist names embedded in a "feat.", "&", or comma-joined
    /// artist string — same semantics as the React `getPlaylistsByArtist`.
    private static func artistMatches(needle: String, in haystack: String) -> Bool {
        if haystack == needle { return true }
        if haystack.contains("\(needle),") { return true }
        if haystack.contains(", \(needle)") { return true }
        if haystack.contains("\(needle) &") { return true }
        if haystack.contains("& \(needle)") { return true }
        if haystack.contains("\(needle) and") { return true }
        if haystack.contains("and \(needle)") { return true }
        if haystack.contains(needle)
            && (haystack.hasPrefix("\(needle) ") || haystack.hasSuffix(" \(needle)")) {
            return true
        }
        return false
    }

    // MARK: - Home page: albums by year range

    func getAlbumsByYearRange(fromYear: Int, toYear: Int, size: Int = 100) async -> [NavidromeAlbum] {
        guard let base = baseURL() else { return [] }
        let urlStr = "\(base)/rest/getAlbumList2.view?\(authQuery())&type=byYear&fromYear=\(fromYear)&toYear=\(toYear)&size=\(size)"
        guard let url = URL(string: urlStr) else { return [] }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder.decodeSubsonic(AlbumListResponse.self, from: data),
              response.status == "ok"
        else { return [] }
        return response.albumList2?.album ?? []
    }

    /// Recent releases — albums released in the last `months` months, sorted newest first.
    func getRecentReleases(months: Int = 6, size: Int = 18) async -> [NavidromeAlbum] {
        let cacheKey = "recentReleases_\(months)_\(size)"
        if let cached = cacheGet(cacheKey) as? [NavidromeAlbum] { return cached }

        let now = Date()
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .month, value: -months, to: now) else { return [] }
        let fromYear = calendar.component(.year, from: cutoff)
        let toYear = calendar.component(.year, from: now)

        let desiredSize = max(size * 2, 100)
        var pool = await getAlbumsByYearRange(fromYear: fromYear, toYear: toYear, size: desiredSize)
        if pool.isEmpty {
            pool = await getAlbumList(type: "newest", size: desiredSize)
        }

        // Filter by year and sort newest first
        let filtered = pool
            .filter { ($0.year ?? 0) >= fromYear }
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        let result = Array(filtered.prefix(size))
        cacheSet(cacheKey, value: result)
        return result
    }

    // MARK: - Home page: backend API endpoints

    /// Build a URLRequest with Navidrome auth headers for backend API calls.
    /// The backend uses `X-Navidrome-User` / `X-Navidrome-Token` to identify the user.
    private func backendRequest(url: URL, method: String = "GET") -> URLRequest? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let creds = credentials {
            request.setValue(creds.username, forHTTPHeaderField: "X-Navidrome-User")
            if let token = creds.token {
                request.setValue(token, forHTTPHeaderField: "X-Navidrome-Token")
            }
        }
        return request
    }

    /// Top 10 most played songs this week.
    func getTopWeekly() async -> [TopWeeklySong] {
        guard let base = backendURL(),
              let url = URL(string: "\(base)/api/stats/top-weekly"),
              let request = backendRequest(url: url)
        else { return [] }

        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        return (try? JSONDecoder().decode([TopWeeklySong].self, from: data)) ?? []
    }

    /// Recently played contexts (albums, playlists, artists).
    func getRecentContexts() async -> [RecentContext] {
        guard let base = backendURL(),
              let username = credentials?.username
        else { return [] }

        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username
        guard let url = URL(string: "\(base)/api/stats/recent-contexts?username=\(encoded)"),
              let request = backendRequest(url: url)
        else { return [] }

        guard let (data, resp) = try? await URLSession.shared.data(for: request) else {
            print("[NavidromeService] getRecentContexts: request failed")
            return []
        }

        let httpStatus = (resp as? HTTPURLResponse)?.statusCode ?? -1
        print("[NavidromeService] getRecentContexts: HTTP \(httpStatus), \(data.count) bytes")

        // Try direct array first
        if let contexts = try? JSONDecoder().decode([RecentContext].self, from: data) {
            print("[NavidromeService] getRecentContexts: decoded \(contexts.count) contexts")
            return contexts
        }

        // Try wrapped response { recentContexts: [...] } or { data: [...] }
        struct Wrapped: Decodable {
            let recentContexts: [RecentContext]?
            let data: [RecentContext]?
        }
        if let wrapped = try? JSONDecoder().decode(Wrapped.self, from: data) {
            let contexts = wrapped.recentContexts ?? wrapped.data ?? []
            print("[NavidromeService] getRecentContexts: decoded wrapped \(contexts.count) contexts")
            return contexts
        }

        // Log raw response for debugging
        if let raw = String(data: data, encoding: .utf8) {
            print("[NavidromeService] getRecentContexts: decode failed, raw: \(raw.prefix(500))")
        }
        return []
    }

    /// User's daily mixes. Response is `{ mixes: [...] }`.
    func getDailyMixes() async -> [DailyMix] {
        guard let base = backendURL(),
              let url = URL(string: "\(base)/api/daily-mixes"),
              let request = backendRequest(url: url)
        else { return [] }

        struct Response: Decodable { let mixes: [DailyMix] }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        return (try? JSONDecoder().decode(Response.self, from: data))?.mixes ?? []
    }

    /// Generate daily mixes.
    func generateDailyMixes() async -> GenerateMixesResult? {
        guard let base = backendURL(),
              let url = URL(string: "\(base)/api/daily-mixes/generate"),
              var request = backendRequest(url: url, method: "POST")
        else { return nil }

        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(GenerateMixesResult.self, from: data)
    }

    /// Refresh cover content hashes for every playlist with a custom backend cover.
    ///
    /// Two layers:
    ///   1. Bulk JSON endpoints — `/api/smart-playlists` and `/api/daily-mixes`
    ///      return `coverContentHash` per playlist. One HTTP call covers many.
    ///   2. ETag fallback — for editorial / Spotify-synced / dynamic / user
    ///      playlists not listed in the bulk endpoints, do a HEAD on each
    ///      `/api/playlists/{id}/cover.png` and read the `ETag` (or
    ///      `Last-Modified`) header. The bulk endpoints don't carry these so
    ///      without this layer their covers go stale forever after backend
    ///      regeneration. HEADs are concurrency-limited (8 parallel),
    ///      per-playlist 60 s TTL'd, and individual failures don't block the
    ///      others.
    ///
    /// Layer 1 always runs first; only IDs not already covered there are
    /// HEAD-checked. Hash registration is single-pass via
    /// `registerContentHashes`, which compares old vs new and triggers cover
    /// invalidation in subscribed views.
    func refreshPlaylistCoverHashes() async {
        guard let base = backendURL() else {
            print("[NavidromeService] refreshPlaylistCoverHashes: no backend URL configured")
            return
        }
        var hashes: [String: String] = [:]
        var coveredIds = Set<String>()

        // ── Layer 1a: Smart playlists JSON ──
        if let url = URL(string: "\(base)/api/smart-playlists"),
           let request = backendRequest(url: url) {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let playlists = dict["playlists"] as? [[String: Any]] {
                    var withHash = 0
                    for pl in playlists {
                        if let id = pl["navidromeId"] as? String {
                            coveredIds.insert(id)
                            if let hash = pl["coverContentHash"] as? String, !hash.isEmpty {
                                hashes[id] = hash
                                withHash += 1
                            }
                        }
                    }
                    print("[NavidromeService] smart-playlists: \(playlists.count) playlists, \(withHash) with coverContentHash")
                } else {
                    print("[NavidromeService] smart-playlists: response shape unexpected (no `playlists` array)")
                }
            } catch {
                print("[NavidromeService] smart-playlists fetch failed: \(error)")
            }
        }

        // ── Layer 1b: Daily mixes JSON ──
        let mixes = await getDailyMixes()
        var mixWithHash = 0
        for mix in mixes {
            if let id = mix.navidromeId {
                coveredIds.insert(id)
                if let hash = mix.coverContentHash, !hash.isEmpty {
                    hashes[id] = hash
                    mixWithHash += 1
                }
            }
        }
        print("[NavidromeService] daily-mixes: \(mixes.count) playlists, \(mixWithHash) with coverContentHash")

        if !hashes.isEmpty {
            PlaylistCoverCache.shared.registerContentHashes(hashes)
        }

        // ── Layer 2: ETag fallback for playlists not in bulk endpoints ──
        // Editorial, Spotify-synced, dynamic homepage sections, and user-created
        // playlists with backend-rendered covers all live here. Without ETag
        // checks the only way to detect a backend regeneration would be a cold
        // launch with cleared URLCache.
        if let allPlaylists = try? await getPlaylists() {
            let uncovered = allPlaylists.map { $0.id }.filter { !coveredIds.contains($0) }
            if !uncovered.isEmpty {
                await revalidateCoverETags(playlistIds: uncovered, base: base)
            }
        }
    }

    /// HEAD-based ETag revalidation for playlists with backend-rendered covers
    /// that the JSON endpoints don't list. Safe to call frequently — a 60 s
    /// per-playlist TTL skips repeated checks, parallelism is capped at 8,
    /// and individual network failures (timeout, 5xx) don't propagate.
    private func revalidateCoverETags(playlistIds: [String], base: String) async {
        // Two-stage filter, atomic against concurrent callers:
        //   1. TTL cache (cacheGet) — checked recently, not by us.
        //   2. inflight set under lock — currently being HEAD-checked by
        //      another invocation of this function. Insert here so a parallel
        //      caller arriving microseconds later sees us already on it.
        let needsCheck: [String] = {
            var picked: [String] = []
            inflightCoverETagLock.lock()
            defer { inflightCoverETagLock.unlock() }
            for id in playlistIds {
                if cacheGet("coverEtag.tick:\(id)") != nil { continue }
                if inflightCoverETagChecks.contains(id) { continue }
                inflightCoverETagChecks.insert(id)
                picked.append(id)
            }
            return picked
        }()
        guard !needsCheck.isEmpty else {
            print("[NavidromeService] ETag revalidation: all \(playlistIds.count) playlists checked recently or in-flight — skipping HEAD")
            return
        }
        print("[NavidromeService] ETag revalidation: HEAD on \(needsCheck.count) playlists (\(playlistIds.count - needsCheck.count) skipped by TTL/inflight)")
        defer {
            // Always release the inflight slots, even if the task group above
            // throws or this function is cancelled mid-flight.
            inflightCoverETagLock.lock()
            for id in needsCheck { inflightCoverETagChecks.remove(id) }
            inflightCoverETagLock.unlock()
        }

        var newHashes: [String: String] = [:]
        var ok = 0, missing = 0, failed = 0
        let maxConcurrent = 8

        await withTaskGroup(of: (id: String, result: ETagResult).self) { group in
            var iterator = needsCheck.makeIterator()
            var inflight = 0

            // Seed the worker pool
            while inflight < maxConcurrent, let id = iterator.next() {
                inflight += 1
                let next = id
                group.addTask {
                    let result = await self.fetchCoverETag(playlistId: next, base: base)
                    return (next, result)
                }
            }

            while let (id, result) = await group.next() {
                // Mark this playlist as checked regardless of outcome — the TTL
                // throttles all retries equally so a backend that's transiently
                // 5xx doesn't get hammered.
                cacheSet("coverEtag.tick:\(id)", value: true, ttl: 60)
                switch result {
                case .ok(let etag):
                    newHashes[id] = etag
                    ok += 1
                case .noCover:
                    missing += 1
                case .failed:
                    failed += 1
                }
                if let nextId = iterator.next() {
                    let next = nextId
                    group.addTask {
                        let result = await self.fetchCoverETag(playlistId: next, base: base)
                        return (next, result)
                    }
                }
            }
        }

        print("[NavidromeService] ETag revalidation done: \(ok) with cover, \(missing) without, \(failed) failed")
        if !newHashes.isEmpty {
            PlaylistCoverCache.shared.registerContentHashes(newHashes)
        }
    }

    private enum ETagResult {
        case ok(String)
        /// Server returned 404 — no custom backend cover for this playlist.
        /// The Navidrome fallback in `loadCover` will surface its art.
        case noCover
        /// Network error or non-200/404 response. Don't update the hash; let
        /// the next refresh cycle retry.
        case failed
    }

    private func fetchCoverETag(playlistId: String, base: String) async -> ETagResult {
        guard let url = URL(string: "\(base)/api/playlists/\(playlistId)/cover.png"),
              var request = backendRequest(url: url, method: "HEAD") else {
            return .failed
        }
        request.timeoutInterval = 10

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .failed
        }
        if http.statusCode == 404 { return .noCover }
        guard http.statusCode == 200 else { return .failed }

        // Prefer ETag (content-derived hash). Fall back to Last-Modified for
        // proxies that strip ETag. URL-encode the value so weak ETags
        // (`W/"abc/def"`) and HTTP-date Last-Modified strings (`Sun, 06 Nov
        // 1994 08:49:37 GMT`) survive concatenation into the cover URL.
        // Stable input string → stable encoded output, so the hash registered
        // here matches what's compared on the next refresh cycle.
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
        if let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
            let cleaned = etag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty {
                return .ok(encoded)
            }
        }
        if let lastMod = http.value(forHTTPHeaderField: "Last-Modified"), !lastMod.isEmpty {
            if let encoded = lastMod.addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty {
                return .ok(encoded)
            }
        }
        // 200 but no validators — server isn't helping us. Treat as failed so
        // we retry rather than register an empty hash that would lock the
        // current cover in place.
        return .failed
    }

    /// Artist image URL from backend (Last.fm / Spotify).
    func artistImageURL(name: String) async -> URL? {
        guard let base = backendURL(),
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(base)/api/artist/image?name=\(encoded)")
        else { return nil }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let imageUrl = dict["imageUrl"] as? String,
              let result = URL(string: imageUrl)
        else { return nil }
        return result
    }

    // MARK: - Artist avatar

    func artistAvatarURL(artistId: String) async -> URL? {
        let cacheKey = "avatar_\(artistId)"
        // Check cache — sentinel NSNull means "no avatar".
        if let cached = cacheGet(cacheKey) {
            return cached as? URL
        }

        guard let base = baseURL() else { return nil }
        let urlStr = "\(base)/rest/getArtistInfo2.view?\(authQuery())&id=\(artistId)"
        guard let url = URL(string: urlStr) else { return nil }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder.decodeSubsonic(ArtistInfoResponse.self, from: data),
              response.status == "ok"
        else {
            cacheSet(cacheKey, value: NSNull())
            return nil
        }

        let info = response.artistInfo2
        let imageUrl = [info?.largeImageUrl, info?.mediumImageUrl, info?.smallImageUrl]
            .compactMap { $0 }
            .compactMap { URL(string: $0) }
            .first

        cacheSet(cacheKey, value: imageUrl ?? NSNull(), ttl: 3600) // 1 hour — URLs rarely change
        return imageUrl
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let audiorrDidLogin = Notification.Name("audiorrDidLogin")
}
