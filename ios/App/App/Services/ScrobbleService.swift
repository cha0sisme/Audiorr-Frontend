import Foundation

/// Native scrobbling service — replaces JS scrobble logic from PlayerContext.tsx.
/// Listens to QueueManager for song changes and progress, scrobbles to Navidrome + Audiorr backend.
@MainActor @Observable
final class ScrobbleService {

    static let shared = ScrobbleService()

    // MARK: - State

    private(set) var isEnabled: Bool = true
    private(set) var lastScrobbledSongId: String?

    // MARK: - Private

    private let api = NavidromeService.shared
    private let backend = BackendService.shared
    private var currentSongId: String?
    private var startTime: Date?
    private var hasScrobbled = false
    private var hasSentNowPlaying = false

    // Offline retry queue
    private var pendingScrobbles: [PendingScrobble] = []
    private let pendingKey = "audiorr_pendingScrobbles"

    private init() {
        loadPendingScrobbles()
        // Check scrobble setting
        isEnabled = UserDefaults.standard.string(forKey: "scrobbleEnabled") != "false"
    }

    // MARK: - Song Change Tracking

    /// Called by QueueManager when a new song starts playing.
    func songDidStart(_ song: PersistableSong) {
        // If we have a pending scrobble for the previous song, check it
        flushCurrentIfNeeded()

        currentSongId = song.id
        startTime = Date()
        hasScrobbled = false
        hasSentNowPlaying = false

        guard isEnabled else { return }

        // Send "now playing" to Navidrome (submission=false)
        Task {
            _ = await scrobbleToNavidrome(songId: song.id, submission: false)
            hasSentNowPlaying = true
        }
    }

    /// Called periodically with progress updates.
    /// Scrobbles when >50% of duration or >4 minutes of real listening time.
    func progressUpdate(songId: String, currentTime: Double, duration: Double) {
        guard isEnabled,
              songId == currentSongId,
              !hasScrobbled,
              duration > 0,
              let startTime else { return }

        // Threshold: 50% of duration or 4 minutes, whichever is less
        let threshold = min(duration * 0.5, 240)

        // Use real wall-clock time since start (not currentTime, which can jump on sync)
        let elapsed = Date().timeIntervalSince(startTime)

        guard elapsed >= threshold else { return }

        // Mark immediately to prevent duplicates
        hasScrobbled = true
        lastScrobbledSongId = songId

        let timestamp = Int(startTime.timeIntervalSince1970)

        // Scrobble to Navidrome
        Task {
            let success = await scrobbleToNavidrome(songId: songId, time: timestamp, submission: true)
            if !success {
                // Queue for retry
                enqueuePending(PendingScrobble(
                    songId: songId,
                    timestamp: timestamp,
                    target: .navidrome
                ))
            }
        }

        // Scrobble to Audiorr backend (for wrapped.db / stats)
        // Prefer socket when connected — avoids double-write with REST
        let song = QueueManager.shared.currentSong
        if let song {
            if ConnectService.shared.hubConnected {
                ConnectService.shared.emitScrobble(
                    song: song,
                    playedAt: startTime,
                    contextUri: PlayerService.shared.currentContextUri,
                    contextName: PlayerService.shared.currentContextName
                )
            } else {
                Task {
                    await scrobbleToBackend(song: song, timestamp: timestamp)
                }
            }
        }

        print("[ScrobbleService] Scrobbled: \(songId) after \(Int(elapsed))s (threshold: \(Int(threshold))s)")
    }

    /// Flush any pending scrobble when song changes or playback stops.
    func flushCurrentIfNeeded() {
        // Nothing special needed — scrobble happens on threshold
        currentSongId = nil
        startTime = nil
    }

    // MARK: - Enable/Disable

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled ? "true" : "false", forKey: "scrobbleEnabled")
    }

    // MARK: - Retry pending scrobbles

    func retryPending() {
        guard !pendingScrobbles.isEmpty else { return }
        let batch = pendingScrobbles
        pendingScrobbles = []
        savePendingScrobbles()

        for item in batch {
            Task {
                let success: Bool
                switch item.target {
                case .navidrome:
                    success = await scrobbleToNavidrome(songId: item.songId, time: item.timestamp, submission: true)
                case .backend:
                    // Can't retry backend without full song data — skip
                    success = true
                }
                if !success {
                    enqueuePending(item)
                }
            }
        }
    }

    // MARK: - Navidrome Scrobble

    private func scrobbleToNavidrome(songId: String, time: Int? = nil, submission: Bool = true) async -> Bool {
        guard let serverURL = api.credentials?.serverUrl,
              !serverURL.isEmpty else { return false }

        var urlString = "\(serverURL)/rest/scrobble.view?\(api.authQueryPublic())&id=\(songId)&submission=\(submission)"
        if let time {
            // Navidrome expects milliseconds
            urlString += "&time=\(time * 1000)"
        }

        guard let url = URL(string: urlString) else { return false }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return false }

            // Check for success in response
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.contains("status=\"ok\"") || text.contains("\"status\":\"ok\"") {
                return true
            }
            print("[ScrobbleService] Navidrome scrobble failed: \(text.prefix(200))")
            return false
        } catch {
            print("[ScrobbleService] Navidrome scrobble error: \(error)")
            return false
        }
    }

    // MARK: - Backend Scrobble

    private func scrobbleToBackend(song: PersistableSong, timestamp: Int) async {
        guard let username = api.credentials?.username else { return }

        let payload = BackendService.ScrobblePayload(
            username: username,
            songId: song.id,
            title: song.title,
            artist: song.artist,
            album: song.album,
            albumId: song.albumId,
            duration: song.duration,
            playedAt: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(timestamp))),
            year: nil,
            genre: nil,
            bpm: nil,
            energy: nil,
            contextUri: PlayerService.shared.currentContextUri,
            contextName: PlayerService.shared.currentContextName
        )

        do {
            _ = try await backend.recordScrobble(payload)
        } catch {
            print("[ScrobbleService] Backend scrobble error: \(error)")
            // Not critical — don't retry backend scrobbles
        }
    }

    // MARK: - Pending Scrobbles Persistence

    private struct PendingScrobble: Codable {
        let songId: String
        let timestamp: Int
        let target: Target

        enum Target: String, Codable {
            case navidrome, backend
        }
    }

    private func enqueuePending(_ item: PendingScrobble) {
        pendingScrobbles.append(item)
        savePendingScrobbles()
    }

    private func savePendingScrobbles() {
        guard let data = try? JSONEncoder().encode(pendingScrobbles) else { return }
        UserDefaults.standard.set(data, forKey: pendingKey)
    }

    private func loadPendingScrobbles() {
        guard let data = UserDefaults.standard.data(forKey: pendingKey),
              let items = try? JSONDecoder().decode([PendingScrobble].self, from: data)
        else { return }
        pendingScrobbles = items
    }
}
