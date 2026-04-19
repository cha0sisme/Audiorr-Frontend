import Foundation

// MARK: - Credentials

struct NavidromeCredentials: Codable {
    let serverUrl: String
    let username: String
    let token: String?   // "enc:hexpassword"
}

// MARK: - Domain models (mirrors TypeScript interfaces)

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
    let explicitStatus: String?
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
        return d
    }

    /// Deserialize from a Socket.IO dictionary.
    init?(fromDictionary d: [String: Any]) {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
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
            explicitStatus: d["explicitStatus"] as? String,
            replayGainTrackGain: d["replayGainTrackGain"] as? Double,
            replayGainTrackPeak: d["replayGainTrackPeak"] as? Double,
            replayGainAlbumGain: d["replayGainAlbumGain"] as? Double,
            replayGainAlbumPeak: d["replayGainAlbumPeak"] as? Double
        )
    }
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

    var isExplicit: Bool { explicitStatus == "explicit" }
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

    /// True for editorial, smart, or spotify-synced playlists (not user-deletable).
    var isSystemPlaylist: Bool {
        let c = (comment ?? "").lowercased()
        return c.contains("smart playlist")
            || c.contains("[editorial]")
            || c.contains("spotify synced")
            || name.lowercased().hasPrefix("mix diario")
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

struct PlaylistsResponse: Decodable {
    let status: String
    let playlists: PlaylistsContainer?
    struct PlaylistsContainer: Decodable {
        let playlist: [NavidromePlaylist]?
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
    let coverArtId: String?
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
