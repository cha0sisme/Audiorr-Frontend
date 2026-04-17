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

    // MARK: - Play

    /// Play a single song.
    @MainActor
    func play(song: NavidromeSong) {
        QueueManager.shared.play(songs: [song], startIndex: 0)
    }

    /// Play a list of songs starting at the given index.
    @MainActor
    func playPlaylist(_ songs: [NavidromeSong], startingAt index: Int = 0) {
        guard index < songs.count else { return }
        QueueManager.shared.play(songs: songs, startIndex: index)
    }

    // MARK: - Queue operations

    /// Insert a song immediately after the current one.
    @MainActor
    func insertNext(_ song: NavidromeSong) {
        QueueManager.shared.insertNext(song)
    }

    /// Add a song to the end of the queue.
    @MainActor
    func addToQueue(_ song: NavidromeSong) {
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
    func playSmartMix(playlistId: String) {
        SmartMixManager.shared.playGenerated()
    }

    func updateSmartMixStatus(playlistId: String, status: String) {
        DispatchQueue.main.async {
            self.smartMixPlaylistId = playlistId
            self.smartMixStatus = SmartMixStatus(rawValue: status) ?? .idle
        }
    }
}
