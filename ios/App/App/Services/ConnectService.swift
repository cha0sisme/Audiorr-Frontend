import Foundation
import UIKit

/// Native Audiorr Connect service — connects to the backend Socket.IO hub
/// to receive playback state from other devices (desktop, other iOS).
///
/// Uses the Engine.IO v4 / Socket.IO v4 protocol over URLSessionWebSocketTask
/// (no third-party library required).
// MARK: - Device model

struct ConnectDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let type: DeviceType
    var isThisDevice: Bool = false

    enum DeviceType: String {
        case controller, receiver, hybrid, lanDevice = "lan_device"
        case local // "Este iPhone"

        var icon: String {
            switch self {
            case .local: return "iphone"
            case .controller: return "desktopcomputer"
            case .receiver: return "hifispeaker"
            case .hybrid: return "laptopcomputer"
            case .lanDevice: return "tv"
            }
        }
    }
}

@MainActor @Observable
final class ConnectService {
    static let shared = ConnectService()

    // Public observable state
    var connectedDevices: [ConnectDevice] = []
    var lanDevices: [ConnectDevice] = []
    var activeDeviceId: String? // nil = local playback
    private(set) var hubConnected = false

    private var webSocket: URLSessionWebSocketTask?
    private var sessionToken: String?
    private var engineSid: String?
    private var pingInterval: TimeInterval = 25
    private var pingTimeout: TimeInterval = 20
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var isConnected = false
    private var shouldReconnect = true
    let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    /// Maps deviceId → friendly name from devices_list events
    private var knownDevices: [String: String] = [:]
    /// The device ID whose playback we're currently showing in remote mode
    private var remoteSourceDeviceId: String?
    /// Last time we received a playback_state_update from the remote source
    private var lastRemoteUpdateTime: Date?
    /// Timer to detect stale remote connections (device went offline without clean disconnect)
    private var staleRemoteTimer: Timer?

    private init() {}

    // MARK: - Public API

    /// Connect to the Audiorr Hub. Call after login / on app launch if backend is available.
    private var isConnecting = false

    func connect() {
        guard !isConnected, !isConnecting else { return }
        shouldReconnect = true

        // Don't attempt connection when offline — wait for network to return
        guard NetworkMonitor.shared.isConnected else {
            print("[Connect] Offline — waiting for network before connecting")
            observeNetworkForReconnect()
            return
        }

        isConnecting = true

        Task {
            defer { isConnecting = false }
            do {
                let token = try await authenticate()
                self.sessionToken = token
                try await openWebSocket(token: token)
            } catch {
                print("[Connect] Auth/connect failed: \(error)")
                scheduleReconnect()
            }
        }
    }

    /// Disconnect from the hub.
    func disconnect() {
        shouldReconnect = false
        remoteSourceDeviceId = nil
        tearDown()

        // Clear remote state and restore local
        if NowPlayingState.shared.isRemote {
            restoreAfterRemoteDisconnect()
        }
    }

    /// Cast current song to a LAN device (Chromecast, etc.)
    func castToDevice(_ device: ConnectDevice) {
        guard isConnected else { return }
        let state = NowPlayingState.shared
        guard !state.songId.isEmpty else { return }

        // Build stream URL for the current song
        guard let creds = NavidromeService.shared.credentials,
              let token = creds.token,
              let streamUrl = URL(string: "\(creds.serverUrl)/rest/stream.view?u=\(creds.username)&p=\(token)&v=1.16.0&c=audiorr&f=json&id=\(state.songId)")
        else { return }

        let metadata: [String: Any] = [
            "title": state.title,
            "artist": state.artist,
            "album": "",
        ]

        let payload: [String: Any] = [
            "deviceId": device.id,
            "url": streamUrl.absoluteString,
            "metadata": metadata,
        ]

        sendEvent("cast_to_device", data: payload)
        activeDeviceId = device.id
    }

    /// Stop casting and return to local playback.
    func stopCasting() {
        guard isConnected else { return }
        sendEvent("cast_control", data: ["action": "stop"])
        activeDeviceId = nil
    }

    /// Switch from remote control back to local playback.
    func switchToLocal() {
        stopCasting()
        activeDeviceId = nil
        remoteSourceDeviceId = nil

        let state = NowPlayingState.shared
        state.isRemote = false
        state.remoteDeviceName = nil
        state.subtitle = nil
        state.queue = []

        // Restore local last playback so mini player has valid state
        QueueManager.shared.restoreLastPlayback()
    }

    /// Request playback sync from the hub (gets current state from other devices).
    func requestSync() {
        guard isConnected else { return }
        sendEvent("request_sync", data: nil)
    }

    /// Send a remote command to a specific device.
    func sendRemoteCommand(action: String, value: Any? = nil, targetDeviceId: String? = nil) {
        guard isConnected else { return }
        var payload: [String: Any] = ["action": action]
        if let value { payload["value"] = value }
        if let target = targetDeviceId { payload["targetDeviceId"] = target }
        sendEvent("remote_command", data: payload)
    }

    /// Send a full playlist to the remote device to replace its queue and start playing.
    func sendRemotePlaylist(_ songs: [NavidromeSong], startIndex: Int) {
        let queue = songs.map { $0.toDictionary() }
        sendRemoteCommand(action: "playPlaylist", value: [
            "queue": queue,
            "startIndex": startIndex,
        ] as [String: Any])
    }

    /// Send local playback state to other devices.
    /// Called automatically by QueueManager on song change, play/pause, and throttled progress.
    func broadcastPlaybackState(includeQueue: Bool = true) {
        guard isConnected else { return }

        let state = NowPlayingState.shared
        guard state.isVisible, !state.isRemote else { return }

        let metadata: [String: Any] = [
            "title": state.title,
            "artist": state.artist,
            "album": "",
            "coverArt": state.coverArt,
            "duration": state.duration,
        ]

        // Only include full queue on significant changes (song change, play/pause)
        // to avoid sending large payloads every second
        let queueData: [[String: Any]]
        if includeQueue {
            queueData = state.queue.map { song in
                [
                    "id": song.id,
                    "trackId": song.id,
                    "title": song.title,
                    "artist": song.artist,
                    "album": song.album,
                    "albumId": song.albumId,
                    "coverArt": song.coverArt,
                    "duration": song.duration,
                    "metadata": [
                        "title": song.title,
                        "artist": song.artist,
                        "album": song.album,
                        "coverArt": song.coverArt,
                        "duration": song.duration,
                    ],
                ] as [String: Any]
            }
        } else {
            queueData = []
        }

        let payload: [String: Any] = [
            "trackId": state.songId,
            "metadata": metadata,
            "position": state.progress,
            "startedAt": Date().timeIntervalSince1970 * 1000,
            "playing": state.isPlaying,
            "volume": 1.0,
            "queue": queueData,
            "deviceId": deviceId,
            "contextUri": state.contextUri,
        ]

        sendEvent("playback_state_update", data: payload)
    }

    // MARK: - Throttled broadcast

    private var lastBroadcastTime: Date = .distantPast

    /// Broadcast on significant events (song change, play/pause). Throttle progress-only updates.
    func broadcastStateIfNeeded(significantChange: Bool = false) {
        guard isConnected else { return }
        if significantChange {
            lastBroadcastTime = Date()
            broadcastPlaybackState(includeQueue: true)
        } else {
            // Throttle progress-only to every 1 second (no queue payload)
            let now = Date()
            if now.timeIntervalSince(lastBroadcastTime) >= 1.0 {
                lastBroadcastTime = now
                broadcastPlaybackState(includeQueue: false)
            }
        }
    }

    // MARK: - Authentication

    private func authenticate() async throws -> String {
        guard let creds = NavidromeService.shared.credentials,
              let navidromeToken = creds.token
        else { throw ConnectError.noCredentials }

        let result = try await BackendService.shared.login(
            serverUrl: creds.serverUrl,
            username: creds.username,
            token: navidromeToken
        )
        return result.token
    }

    // MARK: - WebSocket (Engine.IO v4 + Socket.IO v4)

    private func openWebSocket(token: String) async throws {
        guard let baseURL = NavidromeService.shared.backendURL() else {
            throw ConnectError.noBackendURL
        }

        // Convert http(s) to ws(s)
        let wsBase = baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")

        let ts = Int(Date().timeIntervalSince1970 * 1000)
        guard let url = URL(string: "\(wsBase)/socket.io/?EIO=4&transport=websocket&t=\(ts)") else {
            throw ConnectError.invalidURL
        }

        let ws = URLSession.shared.webSocketTask(with: url)
        self.webSocket = ws
        ws.resume()

        // 1. Receive Engine.IO OPEN packet
        let openMsg = try await ws.receive()
        guard let openText = openMsg.text, openText.hasPrefix("0") else {
            throw ConnectError.protocolError("Expected Engine.IO OPEN, got: \(openMsg)")
        }

        // Parse sid and pingInterval
        if let jsonData = openText.dropFirst().data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            engineSid = dict["sid"] as? String
            if let pi = dict["pingInterval"] as? Double {
                pingInterval = pi / 1000.0
            }
            if let pt = dict["pingTimeout"] as? Double {
                pingTimeout = pt / 1000.0
            }
        }

        // 2. Send Socket.IO CONNECT with auth
        let authPayload = try JSONSerialization.data(withJSONObject: ["token": token])
        let authString = "40" + String(data: authPayload, encoding: .utf8)!
        ws.send(.string(authString)) { _ in }

        // 3. Receive Socket.IO CONNECT ACK
        let ackMsg = try await ws.receive()
        guard let ackText = ackMsg.text, ackText.hasPrefix("40") else {
            throw ConnectError.protocolError("Expected Socket.IO CONNECT ACK, got: \(ackMsg)")
        }

        isConnected = true
        hubConnected = true
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        // Hub connection confirms backend is reachable — refresh centralized state
        BackendState.shared.invalidateAndRecheck()
        print("[Connect] Connected to hub (sid: \(engineSid ?? "?"))")

        // 4. Register this device
        let deviceInfo: [String: Any] = [
            "id": deviceId,
            "name": UIDevice.current.name,
            "type": "hybrid",
        ]
        sendEvent("register_device", data: deviceInfo)

        // 5. Request sync to get current playback from other devices
        sendEvent("request_sync", data: nil)

        // 6. Start ping timer
        startPingTimer()

        // 7. Start listening for messages
        listenForMessages()
    }

    private func listenForMessages() {
        guard let ws = webSocket else { return }

        ws.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }

                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    self.listenForMessages() // Continue listening
                case .failure(let error):
                    print("[Connect] WebSocket error: \(error)")
                    self.handleDisconnect()
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard let text = message.text else { return }

        // Engine.IO ping from server → respond with pong + reset watchdog
        if text == "2" {
            webSocket?.send(.string("3")) { _ in }
            resetPingWatchdog()
            return
        }

        // Engine.IO pong (response to our ping, if any) — ignore
        if text == "3" { return }

        // Engine.IO noop
        if text == "6" { return }

        // Socket.IO DISCONNECT from server
        if text == "41" || text.hasPrefix("41") {
            print("[Connect] Server sent Socket.IO DISCONNECT")
            handleDisconnect()
            return
        }

        // Socket.IO CONNECT_ERROR: 44{...}
        if text.hasPrefix("44") {
            print("[Connect] Socket.IO CONNECT_ERROR: \(text)")
            handleDisconnect()
            return
        }

        // Socket.IO EVENT: 42["eventName", {data}]
        if text.hasPrefix("42") {
            let jsonStr = String(text.dropFirst(2))
            guard let data = jsonStr.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let eventName = arr.first as? String
            else { return }

            let eventData = arr.count > 1 ? arr[1] : nil
            handleSocketEvent(eventName, data: eventData)
        }
    }

    private func handleSocketEvent(_ event: String, data: Any?) {
        switch event {
        case "playback_state_update":
            guard let dict = data as? [String: Any] else { return }
            handlePlaybackStateUpdate(dict)

        case "devices_list":
            if let devices = data as? [[String: Any]] {
                connectedDevices = devices.compactMap { d in
                    guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
                    let typeStr = d["type"] as? String ?? "hybrid"
                    knownDevices[id] = name
                    return ConnectDevice(
                        id: id,
                        name: name,
                        type: ConnectDevice.DeviceType(rawValue: typeStr) ?? .hybrid,
                        isThisDevice: id == deviceId
                    )
                }
                print("[Connect] Devices: \(connectedDevices.map(\.name))")

                // Check if the remote source device went offline
                if let sourceId = remoteSourceDeviceId,
                   NowPlayingState.shared.isRemote,
                   !connectedDevices.contains(where: { $0.id == sourceId }) {
                    print("[Connect] Remote source device \(sourceId) disconnected")
                    remoteSourceDeviceId = nil
                    restoreAfterRemoteDisconnect()
                }
            }

        case "lan_devices_discovered":
            if let devices = data as? [[String: Any]] {
                lanDevices = devices.compactMap { d in
                    guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
                    return ConnectDevice(id: id, name: name, type: .lanDevice)
                }
                print("[Connect] LAN devices: \(lanDevices.map(\.name))")
            }

        case "remote_command":
            guard let dict = data as? [String: Any] else { return }
            handleRemoteCommand(dict)

        case "cast_session_update":
            // Could track active cast session here
            break

        default:
            break
        }
    }

    // MARK: - Playback state from other devices

    private func handlePlaybackStateUpdate(_ dict: [String: Any]) {
        let remoteDeviceId = dict["deviceId"] as? String ?? ""

        // Ignore our own broadcasts
        guard remoteDeviceId != deviceId else { return }

        // Ignore updates from devices not in the current devices list.
        // Prevents stale state from ghost devices (crashed desktop, hub lag, etc.)
        guard connectedDevices.contains(where: { $0.id == remoteDeviceId }) else {
            print("[Connect] Ignoring playback update from unknown device \(remoteDeviceId)")
            return
        }

        let playing = dict["playing"] as? Bool ?? false
        let trackId = dict["trackId"] as? String
        let position = dict["position"] as? Double ?? 0
        let metadata = dict["metadata"] as? [String: Any]

        let state = NowPlayingState.shared

        // If remote stopped and we were showing remote state, restore local
        if trackId == nil || (trackId?.isEmpty == true) {
            if state.isRemote {
                remoteSourceDeviceId = nil
                restoreAfterRemoteDisconnect()
            }
            return
        }

        // Don't override local playback that's actively playing
        if state.isVisible && !state.isRemote && state.isPlaying {
            return
        }

        let title = metadata?["title"] as? String ?? ""
        let artist = metadata?["artist"] as? String ?? ""
        let coverArt = metadata?["coverArt"] as? String ?? ""
        let duration = metadata?["duration"] as? Double ?? 0

        state.songId = trackId ?? ""
        state.title = title
        state.artist = artist
        state.coverArt = coverArt
        state.duration = duration
        state.progress = position
        state.isPlaying = playing
        state.contextUri = dict["contextUri"] as? String ?? ""
        state.isRemote = true
        remoteSourceDeviceId = remoteDeviceId
        lastRemoteUpdateTime = Date()
        resetStaleRemoteTimer()
        let deviceName = knownDevices[remoteDeviceId] ?? remoteDeviceId
        state.remoteDeviceName = deviceName
        state.subtitle = "Reproduciendo en \(deviceName)"
        state.isVisible = true

        // Build artwork URL from coverArt ID
        if !coverArt.isEmpty {
            state.artworkUrl = NavidromeService.shared.coverURL(id: coverArt, size: 300)?.absoluteString
        }

        // Parse remote queue and sync to QueueManager (not just UI display)
        if let queueArr = dict["queue"] as? [[String: Any]], !queueArr.isEmpty {
            let parsedQueue: [QueueSong] = queueArr.compactMap { item -> QueueSong? in
                let meta = item["metadata"] as? [String: Any]
                let songId: String = (item["id"] as? String) ?? (item["trackId"] as? String) ?? ""
                guard !songId.isEmpty else { return nil }

                let songTitle: String = (meta?["title"] as? String) ?? (item["title"] as? String) ?? ""
                let songArtist: String = (meta?["artist"] as? String) ?? (item["artist"] as? String) ?? ""
                let songAlbum: String = (meta?["album"] as? String) ?? (item["album"] as? String) ?? ""
                let songAlbumId: String = (item["albumId"] as? String) ?? ""
                let songCoverArt: String = (meta?["coverArt"] as? String) ?? (item["coverArt"] as? String) ?? ""
                let songDuration: Double = (meta?["duration"] as? Double) ?? (item["duration"] as? Double) ?? 0

                var d: [String: Any] = [:]
                d["id"] = songId
                d["title"] = songTitle
                d["artist"] = songArtist
                d["album"] = songAlbum
                d["albumId"] = songAlbumId
                d["coverArt"] = songCoverArt
                d["duration"] = songDuration
                return QueueSong(from: d)
            }
            state.queue = parsedQueue

            // Load queue into QueueManager so it persists locally and is ready to play.
            // Only do this when local player is idle (no active playback).
            let qm = QueueManager.shared
            if !qm.isPlaying {
                let songs = parsedQueue.map { PersistableSong(from: $0) }
                let targetIndex = songs.firstIndex(where: { $0.id == (trackId ?? "") }) ?? 0
                qm.loadRemoteQueue(songs: songs, currentIndex: targetIndex, position: position)
            }
        }
    }

    // MARK: - Remote commands

    private func handleRemoteCommand(_ dict: [String: Any]) {
        guard let action = dict["action"] as? String else { return }
        let targetDeviceId = dict["targetDeviceId"] as? String

        // If we're the remote controller, ignore echoed commands from the hub
        // (we sent them — the other device will execute them)
        if NowPlayingState.shared.isRemote { return }

        // Only handle if targeted at us or broadcast
        if let target = targetDeviceId, target != deviceId { return }

        // We're being controlled �� execute locally, bypass PlayerService
        // to avoid the remote routing check
        switch action {
        case "play":
            AudioEngineManager.shared?.resume()
        case "pause":
            AudioEngineManager.shared?.pause()
        case "togglePlayPause":
            AudioEngineManager.shared?.togglePlayPause()
        case "next":
            QueueManager.shared.skipNext()
        case "previous":
            QueueManager.shared.skipPrevious()
        case "seekTo":
            if let time = dict["value"] as? Double {
                QueueManager.shared.seekTo(time)
            }
        case "playFromQueue":
            if let songId = dict["value"] as? String,
               let idx = QueueManager.shared.queue.firstIndex(where: { $0.id == songId }) {
                QueueManager.shared.play(queue: QueueManager.shared.queue, startIndex: idx)
            }
        case "playPlaylist":
            if let value = dict["value"] as? [String: Any],
               let queueArr = value["queue"] as? [[String: Any]],
               let startIndex = value["startIndex"] as? Int {
                let songs = queueArr.compactMap { NavidromeSong(fromDictionary: $0) }
                guard !songs.isEmpty else { break }
                QueueManager.shared.play(songs: songs, startIndex: min(startIndex, songs.count - 1))
            }
        case "insertNext":
            if let songDict = dict["value"] as? [String: Any],
               let song = NavidromeSong(fromDictionary: songDict) {
                QueueManager.shared.insertNext(song)
            }
        case "addToQueue":
            if let songDict = dict["value"] as? [String: Any],
               let song = NavidromeSong(fromDictionary: songDict) {
                QueueManager.shared.addToQueue(song)
            }
        default:
            print("[Connect] Unknown remote command: \(action)")
        }

        // After executing a remote command, broadcast updated state back to the controller
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            self.broadcastPlaybackState()
        }
    }

    // MARK: - Restore after remote disconnect

    private func restoreAfterRemoteDisconnect() {
        staleRemoteTimer?.invalidate()
        staleRemoteTimer = nil
        lastRemoteUpdateTime = nil

        let state = NowPlayingState.shared
        state.isRemote = false
        state.remoteDeviceName = nil
        state.subtitle = nil
        state.queue = []

        // Close the viewer if it was open showing remote content
        if state.viewerIsOpen {
            state.viewerIsOpen = false
        }

        // Restore last playback from backend so mini player shows something useful
        Task {
            QueueManager.shared.restoreLastPlayback()
        }
    }

    /// Reset the stale-remote watchdog. If we don't receive a playback update
    /// from the remote source within 30s, assume the device is gone and restore local.
    private func resetStaleRemoteTimer() {
        staleRemoteTimer?.invalidate()
        staleRemoteTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, NowPlayingState.shared.isRemote else { return }
                print("[Connect] Stale remote: no update for 30s — restoring local")
                self.remoteSourceDeviceId = nil
                self.restoreAfterRemoteDisconnect()
            }
        }
    }

    // MARK: - Send events

    private func sendEvent(_ event: String, data: Any?) {
        guard let ws = webSocket else { return }

        let arr: [Any]
        if let data {
            arr = [event, data]
        } else {
            arr = [event]
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: arr),
              let jsonStr = String(data: jsonData, encoding: .utf8)
        else { return }

        ws.send(.string("42" + jsonStr)) { error in
            if let error {
                print("[Connect] Send error: \(error)")
            }
        }
    }

    // MARK: - Ping / keepalive

    /// Reset the watchdog timer every time we receive a server ping.
    /// If the server doesn't ping within (pingInterval + pingTimeout), assume dead.
    private func resetPingWatchdog() {
        pingTimer?.invalidate()
        let deadline = pingInterval + pingTimeout
        pingTimer = Timer.scheduledTimer(withTimeInterval: deadline, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isConnected else { return }
                print("[Connect] Server ping timeout (\(deadline)s) — disconnecting")
                self.handleDisconnect()
            }
        }
    }

    private func startPingTimer() {
        resetPingWatchdog()
    }

    // MARK: - Reconnection

    private func handleDisconnect() {
        let wasShowingRemote = NowPlayingState.shared.isRemote
        remoteSourceDeviceId = nil
        tearDown()

        // If we were showing remote content, restore local state immediately
        if wasShowingRemote {
            restoreAfterRemoteDisconnect()
        }

        if shouldReconnect {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect, reconnectTimer == nil else { return }

        // Don't schedule reconnect timer when offline — observe network instead
        guard NetworkMonitor.shared.isConnected else {
            print("[Connect] Offline — pausing reconnect until network returns")
            observeNetworkForReconnect()
            return
        }

        print("[Connect] Will reconnect in 5s...")
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.reconnectTimer = nil
                self?.connect()
            }
        }
    }

    /// Observe network state and trigger reconnect when connectivity returns.
    private var networkWaitTimer: Timer?

    private func observeNetworkForReconnect() {
        guard networkWaitTimer == nil else { return }

        networkWaitTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                guard self.shouldReconnect else {
                    t.invalidate()
                    self.networkWaitTimer = nil
                    return
                }
                if NetworkMonitor.shared.isConnected {
                    t.invalidate()
                    self.networkWaitTimer = nil
                    print("[Connect] Network restored — attempting reconnect")
                    self.connect()
                }
            }
        }
    }

    private func tearDown() {
        pingTimer?.invalidate()
        pingTimer = nil
        staleRemoteTimer?.invalidate()
        staleRemoteTimer = nil
        lastRemoteUpdateTime = nil
        networkWaitTimer?.invalidate()
        networkWaitTimer = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        isConnected = false
        hubConnected = false
        engineSid = nil
        connectedDevices = []
        lanDevices = []
    }
}

// MARK: - Errors

enum ConnectError: LocalizedError {
    case noCredentials
    case noBackendURL
    case invalidURL
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials: "No Navidrome credentials available"
        case .noBackendURL: "No Audiorr backend URL configured"
        case .invalidURL: "Invalid WebSocket URL"
        case .protocolError(let msg): "Socket.IO protocol error: \(msg)"
        }
    }
}

// MARK: - URLSessionWebSocketTask.Message helper

private extension URLSessionWebSocketTask.Message {
    var text: String? {
        switch self {
        case .string(let s): return s
        case .data(let d): return String(data: d, encoding: .utf8)
        @unknown default: return nil
        }
    }
}
