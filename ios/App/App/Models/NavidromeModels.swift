import Foundation

// MARK: - Credentials

struct NavidromeCredentials: Codable {
    let serverUrl: String
    let username: String
    let token: String?   // "enc:hexpassword"
}

// MARK: - Domain models (mirrors TypeScript interfaces)

/// OpenSubsonic `ItemArtist` — `{ id, name }` por cada artista de una pista o
/// álbum. Navidrome lo expone en `song.artists[]` / `album.artists[]` cuando el
/// ID3 multi-artist está poblado. Permite detectar features por id (en lugar de
/// hacer string-matching contra `artist`, que solo trae el primary). Si el
/// servidor no expone este campo, viene `nil` y los call-sites hacen fallback
/// al `artistId` singular.
struct ItemArtist: Identifiable, Codable, Hashable {
    let id: String
    let name: String

    /// Formatea una lista de artistas al estilo Apple Music:
    /// 1 → "A", 2 → "A & B", 3+ → "A, B & C" (último con `&`, resto comas).
    /// El `feat.` (lowercase, en inglés) lo manda Apple en el TÍTULO de la
    /// canción, no en el campo de artista, así que aquí solo concatenamos
    /// nombres con el separador correcto.
    static func displayName(of artists: [ItemArtist], fallback: String = "") -> String {
        let names = artists.map(\.name).filter { !$0.isEmpty }
        switch names.count {
        case 0: return fallback
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default:
            let head = names.dropLast().joined(separator: ", ")
            return "\(head) & \(names.last!)"
        }
    }

    /// Para una canción dentro del contexto de un álbum, devuelve el texto
    /// del artista solo si hay **featurings reales** (artistas distintos del
    /// principal del álbum), formateado Apple-style: "Drake feat. Snoop Dogg".
    /// Si la canción es del artista del álbum sin invitados, devuelve nil
    /// (el caller no renderiza nada — coincide con cómo Apple Music
    /// omite el artista en las pistas que son solo del titular del álbum).
    static func featuringText(
        artists: [ItemArtist],
        fallback: String,
        albumArtist: String
    ) -> String? {
        let names = artists.map(\.name).filter { !$0.isEmpty }

        // Solo 1 artista — coincide con el del álbum → ocultar.
        if names.count <= 1 {
            let only = names.first ?? fallback
            return only == albumArtist || only.isEmpty ? nil : only
        }

        // Múltiples artistas. Si el álbum aparece, los demás son featurings.
        if names.contains(albumArtist) {
            let featuring = names.filter { $0 != albumArtist }
            guard !featuring.isEmpty else { return nil }
            let featList: String
            switch featuring.count {
            case 1: featList = featuring[0]
            case 2: featList = "\(featuring[0]) & \(featuring[1])"
            default:
                let head = featuring.dropLast().joined(separator: ", ")
                featList = "\(head) & \(featuring.last!)"
            }
            return "\(albumArtist) feat. \(featList)"
        }

        // El álbum no está en la lista → canción de invitado, mostrar todo.
        return displayName(of: artists, fallback: fallback)
    }
}

struct NavidromeSong: Identifiable, Decodable, Hashable {
    let id: String
    let title: String
    let artist: String
    let artistId: String?
    let album: String
    let albumId: String?
    let coverArt: String?
    let duration: Double?
    let track: Int?
    let year: Int?
    let genre: String?
    /// Multi-genre array from Navidrome `search3`/`getSong` (`genres: [{name,id}]`).
    /// Falls back to `[genre]` when the array is empty/absent. Used by DJMixingService
    /// gates (v13.M/N) to evaluate cross-genre transitions correctly — a track tagged
    /// "Pop+Hip-Hop+R&B" must match Hip-Hop rules even if `genre` singular returned
    /// "Pop" (Navidrome serializes only the primary tag in the singular field).
    let genres: [String]
    let explicitStatus: String?
    /// OpenSubsonic extension. Lista completa de artistas de la pista
    /// (incluyendo features). Si el server no la expone, viene `nil` y hay
    /// que fallback al string `artist`. La usa el "Aparece en" del perfil
    /// de artista para detectar collabs canción-a-canción, y el menú
    /// contextual de SongRow para el toggle "Ver artista" / "Ver artistas".
    let artists: [ItemArtist]?
    let replayGainTrackGain: Double?
    let replayGainTrackPeak: Double?
    let replayGainAlbumGain: Double?
    let replayGainAlbumPeak: Double?

    var isExplicit: Bool { explicitStatus == "explicit" }

    /// Compute the ReplayGain multiplier for this track (track gain preferred, album gain fallback).
    /// When no RG tags exist, uses -8 dB default (matches React behavior for consistent loudness).
    var replayGainMultiplier: Float {
        let db = replayGainTrackGain ?? replayGainAlbumGain ?? -8.0
        let peak = replayGainTrackPeak ?? replayGainAlbumPeak ?? 0.0
        return AudioEngineManager.computeReplayGainMultiplier(gainDb: db, trackPeak: peak)
    }

    // Subsonic API sends ReplayGain as a nested object: { "replayGain": { "trackGain": ..., "trackPeak": ..., "albumGain": ..., "albumPeak": ... } }
    // We flatten it into our top-level properties during decoding.

    private struct ReplayGainData: Decodable {
        let trackGain: Double?
        let trackPeak: Double?
        let albumGain: Double?
        let albumPeak: Double?
    }

    /// Subsonic / Navidrome `genres` entry: `{ "name": "Hip-Hop", "id": "..." }`.
    /// Some legacy responses may emit a plain string array — both shapes are
    /// handled in the custom decoder below.
    private struct GenreEntry: Decodable {
        let name: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, artistId, album, albumId, coverArt
        case duration, track, year, genre, genres, explicitStatus
        case artists
        case replayGain
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        artistId = try c.decodeIfPresent(String.self, forKey: .artistId)
        album = try c.decode(String.self, forKey: .album)
        albumId = try c.decodeIfPresent(String.self, forKey: .albumId)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        track = try c.decodeIfPresent(Int.self, forKey: .track)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        // Plural `genres` array. Navidrome emits `[{name, id}, ...]` in newer
        // versions; some forks emit `[String]`. Try the dict shape first, fall
        // back to plain strings, and finally fall back to the singular `genre`
        // so the field is never nil for downstream consumers.
        var parsedGenres: [String] = []
        if let dicts = try? c.decodeIfPresent([GenreEntry].self, forKey: .genres) {
            parsedGenres = dicts.compactMap { $0.name }.filter { !$0.isEmpty }
        } else if let plain = try? c.decodeIfPresent([String].self, forKey: .genres) {
            parsedGenres = plain.filter { !$0.isEmpty }
        }
        if parsedGenres.isEmpty, let g = genre, !g.isEmpty {
            parsedGenres = [g]
        }
        genres = parsedGenres
        explicitStatus = try c.decodeIfPresent(String.self, forKey: .explicitStatus)
        // OpenSubsonic `artists` array. Filtramos entradas con id vacío para
        // no propagar basura. Si el server no lo emite, queda `nil` y los
        // consumidores hacen fallback al `artistId` singular.
        if let arr = try? c.decodeIfPresent([ItemArtist].self, forKey: .artists) {
            let cleaned = arr.filter { !$0.id.isEmpty && !$0.name.isEmpty }
            artists = cleaned.isEmpty ? nil : cleaned
        } else {
            artists = nil
        }
        let rg = try c.decodeIfPresent(ReplayGainData.self, forKey: .replayGain)
        replayGainTrackGain = rg?.trackGain
        replayGainTrackPeak = rg?.trackPeak
        replayGainAlbumGain = rg?.albumGain
        replayGainAlbumPeak = rg?.albumPeak
    }

    init(id: String, title: String, artist: String, artistId: String?,
         album: String, albumId: String?, coverArt: String?,
         duration: Double?, track: Int?, year: Int?, genre: String?,
         genres: [String] = [],
         explicitStatus: String?,
         artists: [ItemArtist]? = nil,
         replayGainTrackGain: Double?, replayGainTrackPeak: Double?,
         replayGainAlbumGain: Double?, replayGainAlbumPeak: Double?) {
        self.id = id; self.title = title; self.artist = artist; self.artistId = artistId
        self.album = album; self.albumId = albumId; self.coverArt = coverArt
        self.duration = duration; self.track = track; self.year = year; self.genre = genre
        // Mirror the decoder fallback: empty `genres` parameter falls back to
        // `[genre]` so call-sites never have to remember the rule.
        if genres.isEmpty, let g = genre, !g.isEmpty {
            self.genres = [g]
        } else {
            self.genres = genres
        }
        self.explicitStatus = explicitStatus
        self.artists = artists
        self.replayGainTrackGain = replayGainTrackGain; self.replayGainTrackPeak = replayGainTrackPeak
        self.replayGainAlbumGain = replayGainAlbumGain; self.replayGainAlbumPeak = replayGainAlbumPeak
    }
}

extension NavidromeSong {
    /// Serialize to dictionary for Socket.IO remote commands.
    func toDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "id": id, "title": title, "artist": artist, "album": album,
        ]
        if let v = artistId   { d["artistId"] = v }
        if let v = albumId    { d["albumId"] = v }
        if let v = coverArt   { d["coverArt"] = v }
        if let v = duration   { d["duration"] = v }
        if let v = track      { d["track"] = v }
        if let v = year       { d["year"] = v }
        if let v = genre      { d["genre"] = v }
        if !genres.isEmpty    { d["genres"] = genres }
        if let v = artists, !v.isEmpty {
            d["artists"] = v.map { ["id": $0.id, "name": $0.name] }
        }
        return d
    }

    /// Deserialize from a Socket.IO dictionary.
    init?(fromDictionary d: [String: Any]) {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        // OpenSubsonic `artists`: array de `{id, name}`. Reconstruimos solo si
        // todos los items tienen ambos campos, si no, dejamos `nil` para que
        // los call-sites caigan al fallback con `artistId` singular.
        let parsedArtists: [ItemArtist]?
        if let raw = d["artists"] as? [[String: Any]] {
            let mapped = raw.compactMap { item -> ItemArtist? in
                guard let aid = item["id"] as? String, !aid.isEmpty,
                      let nm  = item["name"] as? String, !nm.isEmpty
                else { return nil }
                return ItemArtist(id: aid, name: nm)
            }
            parsedArtists = mapped.isEmpty ? nil : mapped
        } else {
            parsedArtists = nil
        }
        self.init(
            id: id,
            title: d["title"] as? String ?? "",
            artist: d["artist"] as? String ?? "",
            artistId: d["artistId"] as? String,
            album: d["album"] as? String ?? "",
            albumId: d["albumId"] as? String,
            coverArt: d["coverArt"] as? String,
            duration: d["duration"] as? Double,
            track: d["track"] as? Int,
            year: d["year"] as? Int,
            genre: d["genre"] as? String,
            genres: d["genres"] as? [String] ?? [],
            explicitStatus: d["explicitStatus"] as? String,
            artists: parsedArtists,
            replayGainTrackGain: d["replayGainTrackGain"] as? Double,
            replayGainTrackPeak: d["replayGainTrackPeak"] as? Double,
            replayGainAlbumGain: d["replayGainAlbumGain"] as? Double,
            replayGainAlbumPeak: d["replayGainAlbumPeak"] as? Double
        )
    }
}

/// Fecha estructurada de OpenSubsonic (`originalReleaseDate` / `releaseDate`):
/// objeto `{ year, month, day }`. Cualquiera puede faltar.
struct ItemDate: Decodable, Hashable {
    let year: Int?
    let month: Int?
    let day: Int?
}

struct NavidromeAlbum: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let artist: String
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let year: Int?
    let genre: String?
    let explicitStatus: String?
    /// ISO 8601 timestamp de cuándo se añadió a la biblioteca Navidrome.
    /// Tiebreaker cronológico cuando `year` es igual entre álbumes (sort de
    /// "Lanzamientos recientes" lo necesita para devolver lo más nuevo primero
    /// cuando todos son del año actual). Opcional para compatibilidad con
    /// construcciones manuales antiguas (HomeView, SongListView, contexts).
    let created: String?
    /// Fecha de lanzamiento (OpenSubsonic). Da granularidad mes/día para ordenar
    /// "Lanzamientos recientes" de verdad (no solo por año).
    let releaseDate: ItemDate?
    let originalReleaseDate: ItemDate?

    var isExplicit: Bool { explicitStatus == "explicit" }

    /// Clave de orden por fecha de lanzamiento (desc = más reciente primero).
    /// Prefiere `releaseDate`, luego `originalReleaseDate`, y cae a `year`.
    /// year*10000 + month*100 + day → comparable como entero.
    var releaseSortValue: Int {
        func value(_ d: ItemDate?) -> Int? {
            guard let d, let y = d.year else { return nil }
            return y * 10000 + (d.month ?? 0) * 100 + (d.day ?? 0)
        }
        return value(releaseDate) ?? value(originalReleaseDate) ?? ((year ?? 0) * 10000)
    }

    /// Init explícito que mantiene compatibilidad con los callsites que
    /// construyen `NavidromeAlbum` sin `created` (HomeView contexts, SongListView,
    /// NavidromeService.getAlbumDetail). Los campos se decodifican automáticamente
    /// desde Subsonic cuando vienen en el JSON.
    init(
        id: String, name: String, artist: String, coverArt: String?,
        songCount: Int?, duration: Int?, year: Int?, genre: String?,
        explicitStatus: String?, created: String? = nil,
        releaseDate: ItemDate? = nil, originalReleaseDate: ItemDate? = nil
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.coverArt = coverArt
        self.songCount = songCount
        self.duration = duration
        self.year = year
        self.genre = genre
        self.explicitStatus = explicitStatus
        self.created = created
        self.releaseDate = releaseDate
        self.originalReleaseDate = originalReleaseDate
    }
}

struct NavidromeArtist: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let albumCount: Int?
}

struct SearchResults {
    var artists: [NavidromeArtist] = []
    var albums: [NavidromeAlbum] = []
    var songs: [NavidromeSong] = []

    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
}

struct NavidromePlaylist: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let comment: String?
    let songCount: Int
    let duration: Int
    let owner: String?
    let coverArt: String?
    let changed: String?

    /// True for editorial, smart, spotify-synced, or starred-synced playlists
    /// (not user-deletable). 'Starred Synced' es la playlist "Favoritos" que
    /// materializa el backend desde los star del propio usuario: el owner es
    /// el usuario pero el resync periódico sobreescribiría cualquier edición
    /// manual (borrarla, quitar/añadir pistas) — se gestiona vía star/unstar.
    var isSystemPlaylist: Bool {
        let c = (comment ?? "").lowercased()
        return c.contains("smart playlist")
            || c.contains("[editorial]")
            || c.contains("spotify synced")
            || c.contains("starred synced")
            || name.lowercased().hasPrefix("mix diario")
    }

    /// True when this playlist's `owner` matches the currently authenticated
    /// Navidrome user (case-insensitive). Editorial / "This is X" / smart
    /// playlists may belong to a service account so this returns false even
    /// when the user has them favourited. Used by the toolbar menu to gate
    /// the "Eliminar" action — the user can only delete their own playlists.
    var isOwnedByCurrentUser: Bool {
        guard let owner = owner?.lowercased(),
              let me = NavidromeService.shared.credentials?.username.lowercased()
        else { return false }
        return owner == me
    }
}

// MARK: - Homepage layout sections (mirrors backend PlaylistSection type)

struct PlaylistSection: Decodable, Identifiable {
    let id: String
    let title: String
    let type: SectionType
    let playlists: [String]?   // playlist IDs for dynamic sections

    enum SectionType: String, Decodable {
        case fixedDaily  = "fixed_daily"
        case fixedUser   = "fixed_user"
        case fixedSmart  = "fixed_smart"
        case dynamic
    }
}

// MARK: - Ranked layout (GET /api/user/:username/ranked-layout)
//
// Per-user affinity-reordered layout. Dynamic sections come with playlists
// already sorted by `rankPredicted`. Fixed sections (fixed_daily / fixed_user
// / fixed_smart) come with playlists empty — client resolves them from its
// own filtered lists (dailyMixes / userPlaylists / smartPlaylists).

struct RankedPlaylistEntry: Decodable {
    let playlistId: String
    let playlistName: String?
    let pinned: Bool?
    let rankOriginal: Int?
    let rankPredicted: Int?
    let score: Double?
}

struct RankedSection: Decodable {
    let sectionId: String
    let title: String
    let rowType: String        // "fixed_daily" | "fixed_smart" | "fixed_user" | "dynamic"
    let playlists: [RankedPlaylistEntry]?
    let note: String?
}

struct RankedUserProfile: Decodable {
    let scrobbleCount90d: Int?
    let confidence: Double?
}

struct RankedAffinityWeights: Decodable {
    let genre: Double?
    let bpm: Double?
    let energy: Double?
    let longTerm: Double?
}

struct RankedLayoutResponse: Decodable {
    let username: String
    let computedAt: String?
    let userProfile: RankedUserProfile?
    let weights: RankedAffinityWeights?
    let sections: [RankedSection]
}

extension RankedLayoutResponse {
    /// Maps the ranked response to the legacy `PlaylistSection` shape so the
    /// existing rendering layer needs no change. Dynamic rows preserve the
    /// backend ordering (playlists already sorted by `rankPredicted`). Fixed
    /// rows leave `playlists` as nil so the page resolves them from its own
    /// filtered lists (same path as the legacy layout flow).
    func mapToLegacyLayout() -> [PlaylistSection] {
        sections.compactMap { sec in
            guard let kind = PlaylistSection.SectionType(rawValue: sec.rowType) else {
                // Unknown rowType: skip the row instead of crashing — backend may
                // introduce new types over time, the client tolerates them by
                // dropping the row (rendering keeps working with the rest).
                return nil
            }
            let ids: [String]? = (kind == .dynamic)
                ? (sec.playlists ?? []).map { $0.playlistId }
                : nil
            return PlaylistSection(id: sec.sectionId, title: sec.title, type: kind, playlists: ids)
        }
    }
}

// MARK: - Subsonic API response wrappers

private struct SubsonicWrapper<T: Decodable>: Decodable {
    let subsonicResponse: T
    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct SubsonicBaseResponse: Decodable {
    let status: String
}

/// Género de la biblioteca (Subsonic `getGenres`). `value` es el nombre.
struct NavidromeGenre: Identifiable, Decodable, Hashable {
    let value: String
    let songCount: Int?
    let albumCount: Int?

    var id: String { value }
    var name: String { value }
}

struct GenresResponse: Decodable {
    let status: String
    let genres: GenresContainer?
    struct GenresContainer: Decodable {
        let genre: [NavidromeGenre]?
    }
}

struct PlaylistsResponse: Decodable {
    let status: String
    let playlists: PlaylistsContainer?
    struct PlaylistsContainer: Decodable {
        let playlist: [NavidromePlaylist]?
    }
}

/// Subsonic `getStarred2` — canciones marcadas como favoritas por el usuario.
/// Solo consumimos `song`; `album`/`artist` starred no tienen UI todavía.
struct StarredResponse: Decodable {
    let status: String
    let starred2: StarredContainer?
    struct StarredContainer: Decodable {
        let song: [NavidromeSong]?
    }
}

struct CreatePlaylistResponse: Decodable {
    let status: String
    let playlist: CreatedPlaylist?
    struct CreatedPlaylist: Decodable {
        let id: String
        let name: String
    }
}

struct PlaylistDetailResponse: Decodable {
    let status: String
    let playlist: PlaylistDetail?
    struct PlaylistDetail: Decodable {
        let id: String
        let name: String
        let coverArt: String?
        let entry: [NavidromeSong]?
    }
}

struct Search2Response: Decodable {
    let status: String
    let searchResult2: Search2Results?

    struct Search2Results: Decodable {
        let artist: [NavidromeArtist]?
        let album: [NavidromeAlbum]?
        let song: [NavidromeSong]?
    }
}

/// `search3.view` — variante con IDs no-legacy y soporte completo de OpenSubsonic
/// extensions (incluye `song.artists[]`). Estructuralmente idéntica a `search2`,
/// pero la usamos cuando necesitamos campos OpenSubsonic — `getArtistCollaborations`
/// la consume para filtrar songs por `artists[].id`.
struct Search3Response: Decodable {
    let status: String
    let searchResult3: Search3Results?

    struct Search3Results: Decodable {
        let artist: [NavidromeArtist]?
        let album: [NavidromeAlbum]?
        let song: [NavidromeSong]?
    }
}

struct ArtistDetailResponse: Decodable {
    let status: String
    let artist: ArtistDetailPayload?

    struct ArtistDetailPayload: Decodable {
        let id: String
        let name: String
        let albumCount: Int?
        let album: [NavidromeAlbum]?
    }
}

struct RecordLabel: Decodable, Hashable {
    let name: String
}

struct AlbumDetailResponse: Decodable {
    let status: String
    let album: AlbumDetailPayload?

    struct AlbumDetailPayload: Decodable {
        let id: String
        let name: String
        let artist: String
        let artistId: String?
        let coverArt: String?
        let year: Int?
        let genre: String?
        let duration: Int?
        let songCount: Int?
        let song: [NavidromeSong]?
        let recordLabels: [RecordLabel]
        let explicitStatus: String?

        private enum CodingKeys: String, CodingKey {
            case id, name, artist, artistId, coverArt, year, genre, duration, songCount, song, recordLabels, explicitStatus
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id             = try c.decode(String.self, forKey: .id)
            name           = try c.decode(String.self, forKey: .name)
            artist         = try c.decode(String.self, forKey: .artist)
            artistId       = try c.decodeIfPresent(String.self, forKey: .artistId)
            coverArt       = try c.decodeIfPresent(String.self, forKey: .coverArt)
            year           = try c.decodeIfPresent(Int.self, forKey: .year)
            genre          = try c.decodeIfPresent(String.self, forKey: .genre)
            duration       = try c.decodeIfPresent(Int.self, forKey: .duration)
            songCount      = try c.decodeIfPresent(Int.self, forKey: .songCount)
            song           = try c.decodeIfPresent([NavidromeSong].self, forKey: .song)
            explicitStatus = try c.decodeIfPresent(String.self, forKey: .explicitStatus)

            if let arr = try? c.decode([RecordLabel].self, forKey: .recordLabels) {
                recordLabels = arr
            } else if let single = try? c.decode(RecordLabel.self, forKey: .recordLabels) {
                recordLabels = [single]
            } else {
                recordLabels = []
            }
        }
    }
}

struct ArtistInfoResponse: Decodable {
    let status: String
    let artistInfo2: ArtistInfo2?

    struct ArtistInfo2: Decodable {
        let largeImageUrl: String?
        let mediumImageUrl: String?
        let smallImageUrl: String?
        let biography: String?
        /// Subsonic returns this as an array when multiple, as a single object
        /// when just one — so we decode via `ArrayOrSingle` to accept both shapes.
        let similarArtist: [SimilarArtist]

        private enum CodingKeys: String, CodingKey {
            case largeImageUrl, mediumImageUrl, smallImageUrl, biography, similarArtist
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            largeImageUrl  = try c.decodeIfPresent(String.self, forKey: .largeImageUrl)
            mediumImageUrl = try c.decodeIfPresent(String.self, forKey: .mediumImageUrl)
            smallImageUrl  = try c.decodeIfPresent(String.self, forKey: .smallImageUrl)
            biography      = try c.decodeIfPresent(String.self, forKey: .biography)

            if let arr = try? c.decode([SimilarArtist].self, forKey: .similarArtist) {
                similarArtist = arr
            } else if let single = try? c.decode(SimilarArtist.self, forKey: .similarArtist) {
                similarArtist = [single]
            } else {
                similarArtist = []
            }
        }
    }
}

struct SimilarArtist: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
}

/// Full artist info — biography + similar artists.
struct ArtistInfo: Hashable {
    let biography: String
    let similarArtists: [SimilarArtist]
}

// MARK: - Album Info (getAlbumInfo2)

struct AlbumInfoResponse: Decodable {
    let status: String
    let albumInfo: AlbumInfo2?

    struct AlbumInfo2: Decodable {
        let notes: String?
        let musicBrainzId: String?
        let lastFmUrl: String?
    }
}

// MARK: - getSong response

struct GetSongResponse: Decodable {
    let status: String
    let song: NavidromeSong?
}

// MARK: - getTopSongs response

struct TopSongsResponse: Decodable {
    let status: String
    let topSongs: TopSongsContainer?

    struct TopSongsContainer: Decodable {
        let song: [NavidromeSong]

        private enum CodingKeys: String, CodingKey { case song }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let arr = try? c.decode([NavidromeSong].self, forKey: .song) {
                song = arr
            } else if let single = try? c.decode(NavidromeSong.self, forKey: .song) {
                song = [single]
            } else {
                song = []
            }
        }
    }
}

// MARK: - getArtists response (Subsonic getArtists.view)

struct ArtistsResponse: Decodable {
    let status: String
    let artists: ArtistsIndex?

    struct ArtistsIndex: Decodable {
        let index: [ArtistIndexEntry]?

        private enum CodingKeys: String, CodingKey { case index }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let arr = try? c.decode([ArtistIndexEntry].self, forKey: .index) {
                index = arr
            } else if let single = try? c.decode(ArtistIndexEntry.self, forKey: .index) {
                index = [single]
            } else {
                index = nil
            }
        }
    }

    struct ArtistIndexEntry: Decodable {
        let name: String
        let artist: [NavidromeArtist]

        private enum CodingKeys: String, CodingKey { case name, artist }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            if let arr = try? c.decode([NavidromeArtist].self, forKey: .artist) {
                artist = arr
            } else if let single = try? c.decode(NavidromeArtist.self, forKey: .artist) {
                artist = [single]
            } else {
                artist = []
            }
        }
    }
}

// MARK: - getAlbumList2 response

struct AlbumListResponse: Decodable {
    let status: String
    let albumList2: AlbumList2?

    struct AlbumList2: Decodable {
        let album: [NavidromeAlbum]?

        private enum CodingKeys: String, CodingKey { case album }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let arr = try? c.decode([NavidromeAlbum].self, forKey: .album) {
                album = arr
            } else if let single = try? c.decode(NavidromeAlbum.self, forKey: .album) {
                album = [single]
            } else {
                album = nil
            }
        }
    }
}

// MARK: - Home page models (backend API)

struct TopWeeklySong: Identifiable, Decodable {
    let songId: String
    let title: String
    let artist: String
    let artistId: String?
    let album: String
    let albumId: String
    let coverArt: String
    let plays: Int
    let rank: Int
    let previousRank: Int?
    let trend: String       // "up" | "down" | "same" | "new"
    let change: Int?

    var id: String { songId }

    private enum CodingKeys: String, CodingKey {
        case songId = "song_id"
        case title, artist
        case artistId = "artist_id"
        case album
        case albumId = "album_id"
        case coverArt = "cover_art"
        case plays, rank, previousRank, trend, change
    }
}

struct RecentContext: Identifiable, Decodable {
    let contextUri: String
    let type: String        // "album" | "playlist" | "smartmix" | "artist" | "other"
    let id: String
    var title: String
    let artist: String
    var coverArtId: String?
    let lastPlayedAt: String
    var songCount: Int?
}

struct DailyMix: Identifiable, Decodable {
    let mixNumber: Int
    let username: String
    let navidromeId: String?
    let name: String
    let clusterSeed: String?
    let trackCount: Int
    let lastGenerated: String?
    let enabled: Bool
    let createdAt: String
    let updatedAt: String
    let coverContentHash: String?
    let coverVersion: Int?

    var id: Int { mixNumber }
}

struct GenerateMixesResult: Decodable {
    let generated: Int
    let mixes: [DailyMix]
    let reason: String?
}

// MARK: - Helpers to decode "subsonic-response" wrapper

extension JSONDecoder {
    static func decodeSubsonic<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let wrapper = try JSONDecoder().decode(SubsonicWrapper<T>.self, from: data)
        return wrapper.subsonicResponse
    }
}
