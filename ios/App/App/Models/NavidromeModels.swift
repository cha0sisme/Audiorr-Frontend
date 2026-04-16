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
    let album: String
    let albumId: String?
    let coverArt: String?
    let duration: Double?
    let track: Int?
    let year: Int?
    let genre: String?
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

struct PlaylistsResponse: Decodable {
    let status: String
    let playlists: PlaylistsContainer?
    struct PlaylistsContainer: Decodable {
        let playlist: [NavidromePlaylist]?
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
    }
}

struct ArtistInfoResponse: Decodable {
    let status: String
    let artistInfo2: ArtistInfo2?

    struct ArtistInfo2: Decodable {
        let largeImageUrl: String?
        let mediumImageUrl: String?
        let smallImageUrl: String?
    }
}

// MARK: - Helpers to decode "subsonic-response" wrapper

extension JSONDecoder {
    static func decodeSubsonic<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let wrapper = try JSONDecoder().decode(SubsonicWrapper<T>.self, from: data)
        return wrapper.subsonicResponse
    }
}
