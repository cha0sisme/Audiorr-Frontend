import Foundation
import UIKit
import Combine

// MARK: - SmartMix status (will be migrated to SmartMixManager in Phase 4)

enum SmartMixStatus: String {
    case idle, analyzing, ready, error
}

/// Bridge between SwiftUI views and QueueManager/AudioEngineManager.
/// All playback actions go through QueueManager — no JS/React dependency.
final class PlayerService {

    static let shared = PlayerService()
    private let api = NavidromeService.shared
    private init() {}

    // MARK: - SmartMix observable state (Phase 4 will move this to SmartMixManager)

    @Published private(set) var smartMixStatus: SmartMixStatus = .idle
    @Published private(set) var smartMixPlaylistId: String?

    // MARK: - Playback Context (feeds Jump Back In / wrapped stats)

    /// Current playback context — e.g. "playlist:abc123", "album:xyz", "smartmix:abc123"
    private(set) var currentContextUri: String?
    /// Human-readable name of the current context.
    private(set) var currentContextName: String?

    // MARK: - Play

    /// Play a single song.
    @MainActor
    func play(song: NavidromeSong) {
        if NowPlayingState.shared.isRemote {
            ConnectService.shared.sendRemotePlaylist([song], startIndex: 0)
            return
        }
        currentContextUri = nil
        currentContextName = nil
        QueueManager.shared.play(songs: [song], startIndex: 0)
    }

    /// Play a list of songs starting at the given index.
    @MainActor
    func playPlaylist(_ songs: [NavidromeSong], startingAt index: Int = 0, contextUri: String? = nil, contextName: String? = nil) {
        guard index < songs.count else { return }
        if NowPlayingState.shared.isRemote {
            ConnectService.shared.sendRemotePlaylist(songs, startIndex: index)
            return
        }
        currentContextUri = contextUri
        currentContextName = contextName
        QueueManager.shared.play(songs: songs, startIndex: index)
    }

    // MARK: - Queue operations

    /// Insert a song immediately after the current one.
    @MainActor
    func insertNext(_ song: NavidromeSong) {
        if NowPlayingState.shared.isRemote {
            ConnectService.shared.sendRemoteCommand(action: "insertNext", value: song.toDictionary())
            return
        }
        QueueManager.shared.insertNext(song)
    }

    /// Add a song to the end of the queue.
    @MainActor
    func addToQueue(_ song: NavidromeSong) {
        if NowPlayingState.shared.isRemote {
            ConnectService.shared.sendRemoteCommand(action: "addToQueue", value: song.toDictionary())
            return
        }
        QueueManager.shared.addToQueue(song)
    }

    // MARK: - Playback controls

    @MainActor
    func togglePlayPause() {
        if NowPlayingState.shared.isRemote {
            let action = NowPlayingState.shared.isPlaying ? "pause" : "play"
            ConnectService.shared.sendRemoteCommand(action: action)
            NowPlayingState.shared.isPlaying.toggle()
            return
        }
        AudioEngineManager.shared?.togglePlayPause()
    }

    @MainActor
    func next() {
        if NowPlayingState.shared.isRemote {
            ConnectService.shared.sendRemoteCommand(action: "next")
            return
        }
        QueueManager.shared.skipNext()
    }

    @MainActor
    func previous() {
        if NowPlayingState.shared.isRemote {
            ConnectService.shared.sendRemoteCommand(action: "previous")
            return
        }
        QueueManager.shared.skipPrevious()
    }

    @MainActor
    func seekTo(_ time: Double) {
        if NowPlayingState.shared.isRemote {
            ConnectService.shared.sendRemoteCommand(action: "seekTo", value: time)
            return
        }
        QueueManager.shared.seekTo(time)
    }

    // MARK: - SmartMix

    @MainActor
    func generateSmartMix(playlistId: String, songs: [NavidromeSong]) {
        smartMixPlaylistId = playlistId
        smartMixStatus = .analyzing
        SmartMixManager.shared.generate(playlistId: playlistId, songs: songs)
    }

    @MainActor
    func playSmartMix(playlistId: String, playlistName: String? = nil) {
        let mix = SmartMixManager.shared.generatedMix
        guard !mix.isEmpty else { return }

        // Always start from position 0 — the algorithm chose the best opening
        // song. Starting from the currently playing track defeats the purpose
        // of the curated order.
        if NowPlayingState.shared.isRemote {
            ConnectService.shared.sendRemotePlaylist(mix, startIndex: 0)
            return
        }
        currentContextUri = "smartmix:\(playlistId)"
        currentContextName = playlistName ?? "SmartMix"
        QueueManager.shared.play(songs: mix, startIndex: 0)
    }

    func updateSmartMixStatus(playlistId: String, status: String) {
        DispatchQueue.main.async {
            self.smartMixPlaylistId = playlistId
            self.smartMixStatus = SmartMixStatus(rawValue: status) ?? .idle
        }
    }
}
