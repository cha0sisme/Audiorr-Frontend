import Foundation
import SwiftUI
import AVFoundation

/// Lightweight song for queue display.
struct QueueSong: Identifiable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let albumId: String
    let coverArt: String
    let duration: Double

    init(from dict: [String: Any]) {
        id       = dict["id"]       as? String ?? ""
        title    = dict["title"]    as? String ?? ""
        artist   = dict["artist"]   as? String ?? ""
        album    = dict["album"]    as? String ?? ""
        albumId  = dict["albumId"]  as? String ?? ""
        coverArt = dict["coverArt"] as? String ?? ""
        duration = dict["duration"] as? Double ?? 0
    }

    init(from song: NavidromeSong) {
        id       = song.id
        title    = song.title
        artist   = song.artist
        album    = song.album
        albumId  = song.albumId ?? ""
        coverArt = song.coverArt ?? ""
        duration = song.duration ?? 0
    }
}

/// Observable state for the mini player and Now Playing viewer.
/// Source of truth for the UI — updated by QueueManager (no JS bridge dependency).
@MainActor @Observable
final class NowPlayingState {
    static let shared = NowPlayingState()

    // -- Mini player --
    var title = ""
    var artist = ""
    var artworkUrl: String?
    var isPlaying = false
    var progress: Double = 0
    var duration: Double = 1
    var isVisible = false
    var subtitle: String?
    var viewerIsOpen = false

    // -- Viewer IDs --
    var songId = ""
    var albumId = ""
    var artistId = ""
    var coverArt = ""

    // -- Playback context (e.g. "playlist:abc", "album:xyz", "top-weekly") --
    var contextUri = ""
    var queue: [QueueSong] = []
    var shuffleMode = false
    var repeatMode = "off"     // "off", "all", "one"
    var isCrossfading = false

    // -- Audio route --
    var audioRouteIcon = "iphone"       // SF Symbol for current output
    var audioRouteName = "iPhone"       // Human-readable name

    // -- Multidevice / Audiorr Hub --
    var isRemote = false
    var remoteDeviceName: String?

    // -- Navigation from viewer --
    enum NavigationRequest: Equatable {
        case album(id: String)
        case artist(id: String, name: String)
    }
    var pendingNavigation: NavigationRequest?

    private init() {
        refreshAudioRoute()
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAudioRoute() }
        }
    }

    func hide() {
        isVisible = false
    }

    // MARK: - Audio Route

    func refreshAudioRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute
        guard let output = route.outputs.first else {
            audioRouteIcon = "iphone"
            audioRouteName = "iPhone"
            return
        }

        switch output.portType {
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            let name = output.portName
            let lowered = name.lowercased()
            if lowered.contains("airpods pro") {
                audioRouteIcon = "airpodspro"
            } else if lowered.contains("airpods max") {
                audioRouteIcon = "airpodsmax"
            } else if lowered.contains("airpods") {
                audioRouteIcon = "airpods.gen3"
            } else if lowered.contains("beats") {
                audioRouteIcon = "beats.headphones"
            } else {
                audioRouteIcon = "headphones"
            }
            audioRouteName = name

        case .headphones:
            audioRouteIcon = "headphones"
            audioRouteName = output.portName

        case .builtInSpeaker:
            audioRouteIcon = "iphone"
            audioRouteName = "iPhone"

        case .builtInReceiver:
            audioRouteIcon = "iphone"
            audioRouteName = "iPhone"

        case .carAudio:
            audioRouteIcon = "car"
            audioRouteName = output.portName.isEmpty ? "CarPlay" : output.portName

        case .airPlay:
            audioRouteIcon = "airplayaudio"
            audioRouteName = output.portName

        case .HDMI:
            audioRouteIcon = "tv"
            audioRouteName = output.portName

        default:
            audioRouteIcon = "speaker.wave.2"
            audioRouteName = output.portName.isEmpty ? "Altavoz" : output.portName
        }
    }

    // MARK: - Queue (native)

    /// Set the queue from Swift (used by QueueManager.syncNowPlayingState).
    func setQueue(songs: [NavidromeSong], startIndex: Int = 0) {
        queue = songs.map { QueueSong(from: $0) }

        if startIndex < songs.count {
            let current = songs[startIndex]
            songId   = current.id
            albumId  = current.albumId ?? ""
            artistId = current.artistId ?? ""
            coverArt = current.coverArt ?? ""
        }
    }
}
