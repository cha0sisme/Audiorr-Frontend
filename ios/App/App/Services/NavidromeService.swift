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

    private func cacheGet(_ key: String) -> Any? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let (value, expiry) = cache[key], Date() < expiry else { return nil }
        return value
    }

    private func cacheSet(_ key: String, value: Any, ttl: TimeInterval? = nil) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[key] = (value, Date().addingTimeInterval(ttl ?? cacheTTL))
    }

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

        cacheSet(cacheKey, value: imageUrl ?? NSNull())
        return imageUrl
    }
}
