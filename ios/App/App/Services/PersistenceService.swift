import Foundation

/// Replaces React localStorage for persistent playback state.
/// Uses UserDefaults with Codable encoding.
final class PersistenceService {

    static let shared = PersistenceService()
    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Keys

    private enum Key {
        static let queue = "audiorr_queue"
        static let currentIndex = "audiorr_currentIndex"
        static let position = "audiorr_position"
        static let shuffleMode = "audiorr_shuffleMode"
        static let repeatMode = "audiorr_repeatMode"
        static let volume = "audiorr_volume"
        static let lastSongId = "audiorr_lastSongId"
    }

    // MARK: - Queue

    func saveQueue(_ songs: [PersistableSong]) {
        guard let data = try? JSONEncoder().encode(songs) else { return }
        defaults.set(data, forKey: Key.queue)
    }

    func loadQueue() -> [PersistableSong] {
        guard let data = defaults.data(forKey: Key.queue),
              let songs = try? JSONDecoder().decode([PersistableSong].self, from: data)
        else { return [] }
        return songs
    }

    // MARK: - Current Index

    var currentIndex: Int {
        get { defaults.integer(forKey: Key.currentIndex) }
        set { defaults.set(newValue, forKey: Key.currentIndex) }
    }

    // MARK: - Playback Position

    var position: Double {
        get { defaults.double(forKey: Key.position) }
        set { defaults.set(newValue, forKey: Key.position) }
    }

    // MARK: - Last Song ID

    var lastSongId: String? {
        get { defaults.string(forKey: Key.lastSongId) }
        set { defaults.set(newValue, forKey: Key.lastSongId) }
    }

    // MARK: - Shuffle / Repeat

    var shuffleMode: Bool {
        get { defaults.bool(forKey: Key.shuffleMode) }
        set { defaults.set(newValue, forKey: Key.shuffleMode) }
    }

    /// "off", "all", "one"
    var repeatMode: String {
        get { defaults.string(forKey: Key.repeatMode) ?? "off" }
        set { defaults.set(newValue, forKey: Key.repeatMode) }
    }

    // MARK: - Volume

    var volume: Float {
        get {
            let v = defaults.float(forKey: Key.volume)
            return v > 0 ? v : 0.75 // default
        }
        set { defaults.set(newValue, forKey: Key.volume) }
    }

    // MARK: - Clear All

    func clearAll() {
        for key in [Key.queue, Key.currentIndex, Key.position,
                    Key.shuffleMode, Key.repeatMode, Key.volume, Key.lastSongId] {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Persistable Song

/// Codable song for queue persistence. Maps 1:1 with QueueSong fields.
struct PersistableSong: Codable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let albumId: String
    let artistId: String
    let coverArt: String
    let duration: Double
    let replayGainMultiplier: Float

    init(id: String, title: String, artist: String, album: String,
         albumId: String, artistId: String, coverArt: String, duration: Double,
         replayGainMultiplier: Float = 1.0) {
        self.id = id; self.title = title; self.artist = artist
        self.album = album; self.albumId = albumId; self.artistId = artistId
        self.coverArt = coverArt; self.duration = duration
        self.replayGainMultiplier = replayGainMultiplier
    }

    init(from queue: QueueSong) {
        id = queue.id
        title = queue.title
        artist = queue.artist
        album = queue.album
        albumId = queue.albumId
        artistId = ""
        coverArt = queue.coverArt
        duration = queue.duration
        replayGainMultiplier = 1.0
    }

    init(from song: NavidromeSong) {
        id = song.id
        title = song.title
        artist = song.artist
        album = song.album
        albumId = song.albumId ?? ""
        artistId = song.artistId ?? ""
        coverArt = song.coverArt ?? ""
        duration = song.duration ?? 0
        replayGainMultiplier = song.replayGainMultiplier
    }

    func toQueueSong() -> QueueSong {
        QueueSong(from: [
            "id": id,
            "title": title,
            "artist": artist,
            "album": album,
            "albumId": albumId,
            "coverArt": coverArt,
            "duration": duration,
        ])
    }
}
