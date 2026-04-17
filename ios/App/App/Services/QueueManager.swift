import Foundation
import AVFoundation

/// Native queue manager — replaces PlayerContext.tsx queue logic.
/// Source of truth for the playback queue, shuffle, repeat, and track advancement.
/// Conforms to AudioEngineDelegate to react to engine events (track end, progress, etc.).
@MainActor @Observable
final class QueueManager: @preconcurrency AudioEngineDelegate {

    static let shared = QueueManager()

    // MARK: - Queue State

    private(set) var queue: [PersistableSong] = []
    private(set) var currentIndex: Int = -1
    private(set) var history: [PersistableSong] = []

    var shuffleMode: Bool = false {
        didSet { PersistenceService.shared.shuffleMode = shuffleMode }
    }

    enum RepeatMode: String { case off, all, one }
    var repeatMode: RepeatMode = .off {
        didSet { PersistenceService.shared.repeatMode = repeatMode.rawValue }
    }

    // MARK: - Playback State (fed by AudioEngineManager delegate)

    private(set) var isPlaying: Bool = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    // MARK: - Current Song helpers

    var currentSong: PersistableSong? {
        guard currentIndex >= 0 && currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    var isEmpty: Bool { queue.isEmpty }

    // MARK: - Private

    private let persistence = PersistenceService.shared
    private let api = NavidromeService.shared
    private var isAdvancingTrack = false

    /// Read user settings for DJ mode and ReplayGain from UserDefaults.
    private var isDjMode: Bool {
        guard let json = UserDefaults.standard.string(forKey: "audiorr_settings"),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return dict["isDjMode"] as? Bool ?? false
    }

    private var useReplayGain: Bool {
        guard let json = UserDefaults.standard.string(forKey: "audiorr_settings"),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return true }
        return dict["useReplayGain"] as? Bool ?? true
    }

    /// Get the effective ReplayGain multiplier for a song (1.0 if disabled).
    private func effectiveReplayGain(for song: PersistableSong) -> Float {
        useReplayGain ? song.replayGainMultiplier : 1.0
    }

    // Shuffle: original order preserved for unshuffle
    private var originalQueue: [PersistableSong] = []

    // Guards stale async results from prepareNextForCrossfade
    private var crossfadePreparationId: Int = 0

    private init() {
        restoreState()
    }

    // MARK: - Play

    /// Play a list of songs starting at the given index.
    func play(songs: [NavidromeSong], startIndex: Int = 0) {
        let persistable = songs.map { PersistableSong(from: $0) }
        queue = persistable
        originalQueue = persistable
        currentIndex = min(startIndex, persistable.count - 1)

        if shuffleMode {
            applyShuffle(pinCurrentIndex: true)
        }

        persistState()
        playCurrentSong()
    }

    /// Play a list of already-persistable songs.
    func play(queue newQueue: [PersistableSong], startIndex: Int = 0) {
        queue = newQueue
        originalQueue = newQueue
        currentIndex = min(startIndex, newQueue.count - 1)

        if shuffleMode {
            applyShuffle(pinCurrentIndex: true)
        }

        persistState()
        playCurrentSong()
    }

    // MARK: - Next / Previous

    func next() {
        guard !queue.isEmpty else { return }

        if repeatMode == .one {
            // Repeat one: replay same song
            playCurrentSong()
            return
        }

        // During crossfade (N → N+1), the user already hears N+1 fading in.
        // "Next" should skip to N+2 (not restart N+1).
        // Advance index by 2: one for the crossfade that was in progress,
        // one for the actual skip.
        let wasCrossfading = AudioEngineManager.shared?.isCrossfading == true

        if currentIndex < queue.count - 1 {
            // Save to history
            if let song = currentSong { history.append(song) }
            currentIndex += 1

            // If we were mid-crossfade, N+1 was already playing — skip past it too
            if wasCrossfading && currentIndex < queue.count - 1 {
                if let song = currentSong { history.append(song) }
                currentIndex += 1
            }
        } else if repeatMode == .all {
            if let song = currentSong { history.append(song) }
            currentIndex = 0
        } else {
            // End of queue, no repeat
            isPlaying = false
            syncNowPlayingState()
            return
        }

        persistState()
        playCurrentSong()
    }

    func previous() {
        guard !queue.isEmpty else { return }

        // During crossfade, "previous" means: cancel crossfade and restart current song.
        // currentIndex hasn't advanced yet (crossfadeCompleted does that), so currentSong
        // is still the outgoing song N. playCurrentSong() will cancel the crossfade via
        // engine.play()/playStreaming() and start N from the beginning.
        let engine = AudioEngineManager.shared
        if engine?.isCrossfading == true {
            playCurrentSong()
            return
        }

        // If we're more than 3 seconds in, restart the current song
        if currentTime > 3.0 {
            seekTo(0)
            return
        }

        if currentIndex > 0 {
            currentIndex -= 1
        } else if repeatMode == .all {
            currentIndex = queue.count - 1
        } else {
            // Beginning of queue, just restart
            seekTo(0)
            return
        }

        persistState()
        playCurrentSong()
    }

    /// Skip to next song (user-initiated — ignores repeat-one).
    func skipNext() {
        guard !queue.isEmpty else { return }

        // During crossfade (N → N+1), skip to N+2 (same logic as next())
        let wasCrossfading = AudioEngineManager.shared?.isCrossfading == true

        if currentIndex < queue.count - 1 {
            if let song = currentSong { history.append(song) }
            currentIndex += 1

            if wasCrossfading && currentIndex < queue.count - 1 {
                if let song = currentSong { history.append(song) }
                currentIndex += 1
            }
        } else if repeatMode == .all {
            if let song = currentSong { history.append(song) }
            currentIndex = 0
        } else {
            isPlaying = false
            syncNowPlayingState()
            return
        }

        persistState()
        playCurrentSong()
    }

    /// Skip to previous song (user-initiated — ignores repeat-one, still has 3s restart).
    func skipPrevious() {
        guard !queue.isEmpty else { return }

        if currentTime > 3.0 {
            seekTo(0)
            return
        }

        if currentIndex > 0 {
            currentIndex -= 1
        } else if repeatMode == .all {
            currentIndex = queue.count - 1
        } else {
            seekTo(0)
            return
        }

        persistState()
        playCurrentSong()
    }

    // MARK: - Queue Operations

    func insertNext(_ song: NavidromeSong) {
        let p = PersistableSong(from: song)
        let insertAt = currentIndex + 1
        if insertAt <= queue.count {
            queue.insert(p, at: insertAt)
            originalQueue.insert(p, at: min(insertAt, originalQueue.count))
        } else {
            queue.append(p)
            originalQueue.append(p)
        }
        persistState()
    }

    func addToQueue(_ song: NavidromeSong) {
        let p = PersistableSong(from: song)
        queue.append(p)
        originalQueue.append(p)
        persistState()
    }

    func remove(at index: Int) {
        guard index >= 0 && index < queue.count else { return }
        let removed = queue.remove(at: index)
        originalQueue.removeAll { $0.id == removed.id }

        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            // Removed current song — play next or stop
            if queue.isEmpty {
                currentIndex = -1
                AudioEngineManager.shared?.stop()
                isPlaying = false
                syncNowPlayingState()
            } else {
                currentIndex = min(currentIndex, queue.count - 1)
                playCurrentSong()
            }
        }
        persistState()
    }

    func move(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        // Recalculate currentIndex if needed
        if let first = source.first {
            if first == currentIndex {
                currentIndex = destination > first ? destination - 1 : destination
            } else if first < currentIndex && destination > currentIndex {
                currentIndex -= 1
            } else if first > currentIndex && destination <= currentIndex {
                currentIndex += 1
            }
        }
        persistState()
    }

    func clearUpcoming() {
        guard currentIndex >= 0 else { return }
        queue = Array(queue.prefix(currentIndex + 1))
        persistState()
    }

    func clear() {
        AudioEngineManager.shared?.stop()
        queue = []
        originalQueue = []
        currentIndex = -1
        history = []
        isPlaying = false
        syncNowPlayingState()
        persistState()
    }

    // MARK: - Shuffle

    func toggleShuffle() {
        shuffleMode.toggle()
        if shuffleMode {
            applyShuffle(pinCurrentIndex: true)
        } else {
            unshuffle()
        }
        persistState()
    }

    private func applyShuffle(pinCurrentIndex: Bool) {
        guard !queue.isEmpty else { return }
        let current = pinCurrentIndex ? currentSong : nil

        // Fisher-Yates shuffle
        var shuffled = queue
        for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
            let j = Int.random(in: 0...i)
            shuffled.swapAt(i, j)
        }

        // Pin current song at current index
        if let song = current, let idx = shuffled.firstIndex(where: { $0.id == song.id }) {
            shuffled.swapAt(idx, currentIndex)
        }

        queue = shuffled
    }

    private func unshuffle() {
        guard let current = currentSong else { return }
        queue = originalQueue
        currentIndex = queue.firstIndex(where: { $0.id == current.id }) ?? 0
    }

    // MARK: - Repeat

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: - Seek

    func seekTo(_ time: Double) {
        AudioEngineManager.shared?.seek(to: time)
    }

    // MARK: - AudioEngineDelegate

    nonisolated func audioEngineDidFinishSong() {
        Task { @MainActor in
            guard !isAdvancingTrack else { return }
            isAdvancingTrack = true
            defer { isAdvancingTrack = false }
            next()
        }
    }

    nonisolated func audioEngineProgressUpdate(current: Double, duration: Double) {
        Task { @MainActor in
            let previousDuration = self.duration
            self.currentTime = current
            self.duration = duration
            syncNowPlayingState()

            // Throttled progress broadcast to Audiorr Connect
            ConnectService.shared.broadcastStateIfNeeded(significantChange: false)

            // Scrobble tracking
            if let songId = self.currentSong?.id {
                ScrobbleService.shared.progressUpdate(songId: songId, currentTime: current, duration: duration)
            }

            // When duration resolves from 0 to a real value (AVPlayerItem became ready),
            // retry crossfade preparation if no trigger is set yet.
            if previousDuration <= 0 && duration > 0 {
                let hasTrigger = AudioEngineManager.shared?.automixHasTrigger ?? false
                if !hasTrigger {
                    print("[QueueManager] Duration resolved to \(String(format: "%.1f", duration))s — preparing crossfade")
                    prepareNextForCrossfade()
                }
            }
        }
    }

    nonisolated func audioEnginePlaybackStateChanged(isPlaying: Bool, currentTime: Double) {
        Task { @MainActor in
            self.isPlaying = isPlaying
            self.currentTime = currentTime
            syncNowPlayingState()

            // Play/pause is a significant change — broadcast immediately
            ConnectService.shared.broadcastStateIfNeeded(significantChange: true)
        }
    }

    nonisolated func audioEngineCrossfadeStarted() {
        Task { @MainActor in
            NowPlayingState.shared.isCrossfading = true
        }
    }

    nonisolated func audioEngineCrossfadeCompleted(startOffset: Double) {
        Task { @MainActor in
            NowPlayingState.shared.isCrossfading = false
            // After crossfade, the engine already swapped players.
            // Advance our index to match.
            if currentIndex < queue.count - 1 {
                if let song = currentSong { history.append(song) }
                currentIndex += 1
                persistState()
                syncNowPlayingState()

                // Broadcast to Audiorr Connect (song changed = significant)
                ConnectService.shared.broadcastStateIfNeeded(significantChange: true)

                // Notify scrobble service
                if let newSong = currentSong {
                    ScrobbleService.shared.songDidStart(newSong)
                }

                // CRITICAL: Prepare the NEXT crossfade in the chain.
                // Without this, after a successful crossfade, the next song
                // would play to the end without any transition.
                prepareNextForCrossfade()
            }
        }
    }

    nonisolated func audioEngineDidSeek(to time: Double) {
        Task { @MainActor in
            // Re-prepare crossfade trigger after seek since the old one was cleared
            prepareNextForCrossfade()
        }
    }

    nonisolated func audioEngineError(_ message: String, code: String) {
        print("[QueueManager] Engine error: \(code) — \(message)")
    }

    nonisolated func audioEngineNativeNext(title: String, artist: String, album: String, duration: Double) {
        Task { @MainActor in
            // Engine played next directly (lock screen skip while JS frozen)
            if currentIndex < queue.count - 1 {
                if let song = currentSong { history.append(song) }
                currentIndex += 1
                persistState()
                syncNowPlayingState()
            }
        }
    }

    // MARK: - Automix / Crossfade Preparation

    /// Prepare next song for crossfade. Called after advancing queue or after seek.
    private func prepareNextForCrossfade() {
        guard let current = currentSong,
              currentIndex + 1 < queue.count else { return }
        let nextSong = queue[currentIndex + 1]

        guard let streamURL = api.streamURL(songId: nextSong.id) else { return }
        let currentStreamURL = api.streamURL(songId: current.id)

        // Increment preparation ID so stale async results are discarded
        crossfadePreparationId += 1
        let thisPreparationId = crossfadePreparationId

        // Set next song metadata on engine
        AudioEngineManager.shared?.setNextSongMetadata(
            title: nextSong.title,
            artist: nextSong.artist,
            album: nextSong.album,
            duration: nextSong.duration
        )

        // Set stream URL as fallback for crossfade
        let nextRG = effectiveReplayGain(for: nextSong)
        AudioEngineManager.shared?.setNextStreamURL(streamURL, replayGainMultiplier: nextRG)

        // Pre-fetch analysis for upcoming songs
        let upcoming = Array(queue.suffix(from: min(currentIndex + 1, queue.count)))
        Task { await AnalysisCacheService.shared.prefetch(songs: Array(upcoming)) }

        // Try to preload the file + calculate crossfade intelligence
        Task {
            // Parallel: load file + get analysis for both songs
            async let fileLoad = AudioFileLoader.shared.load(remoteURL: streamURL, songId: nextSong.id)
            async let currentAnalysis = AnalysisCacheService.shared.getAnalysis(
                songId: current.id, streamURL: currentStreamURL
            )
            async let nextAnalysis = AnalysisCacheService.shared.getAnalysis(
                songId: nextSong.id, streamURL: streamURL
            )

            let fileURL = try? await fileLoad
            let curAn = await currentAnalysis
            let nxtAn = await nextAnalysis

            await MainActor.run {
                // Discard stale results if song changed or another preparation started
                guard self.crossfadePreparationId == thisPreparationId else {
                    print("[QueueManager] Discarding stale crossfade preparation")
                    return
                }

                // Prepare the audio file
                if let fileURL {
                    AudioEngineManager.shared?.prepareNext(fileURL: fileURL, replayGainMultiplier: nextRG)
                }

                // Calculate crossfade config using DJ mixing intelligence.
                // Use the engine's actual duration if the metadata duration is 0
                // (Navidrome sometimes returns null duration; AVPlayerItem resolves it later).
                let metaDuration = current.duration
                let engineDuration = self.duration  // fed by audioEngineProgressUpdate
                let currentDuration = metaDuration > 0 ? metaDuration : (engineDuration > 0 ? engineDuration : 0)
                let nextMetaDuration = nextSong.duration
                // When next song duration is unknown, use a generous default (5 min).
                // This prevents the 25%-of-shortest-track cap from crushing the fade to 2s.
                // The actual duration will be resolved when the next song starts playing.
                let nextDuration = nextMetaDuration > 0 ? nextMetaDuration : 300.0

                // If we still don't know the duration, we can't calculate crossfade timing.
                // The safety net in notifyTimeUpdate will handle advancing at song end.
                guard currentDuration > 0 else {
                    print("[QueueManager] ⚠️ Cannot prepare crossfade: unknown song duration (meta=\(metaDuration), engine=\(engineDuration))")
                    return
                }

                var currentSongAnalysis = DJMixingService.SongAnalysis()
                var nextSongAnalysis = DJMixingService.SongAnalysis()

                if let curAn {
                    // We need to call this synchronously but it's on an actor
                    // Use defaults + direct mapping instead
                    currentSongAnalysis.bpm = curAn.bpm ?? 120
                    currentSongAnalysis.beatInterval = curAn.beatInterval ?? (60.0 / currentSongAnalysis.bpm)
                    currentSongAnalysis.energy = curAn.energy ?? 0.5
                    currentSongAnalysis.key = curAn.key
                    currentSongAnalysis.outroStartTime = curAn.outroStartTime ?? max(currentDuration - 30, 0)
                    currentSongAnalysis.introEndTime = curAn.introEndTime ?? min(30, currentDuration)
                    currentSongAnalysis.vocalStartTime = curAn.vocalStartTime ?? 0
                    if let beats = curAn.beats { currentSongAnalysis.downbeatTimes = beats }
                    if let segs = curAn.speechSegments {
                        currentSongAnalysis.speechSegments = segs.map { (start: $0.start, end: $0.end) }
                    }
                }

                if let nxtAn {
                    nextSongAnalysis.bpm = nxtAn.bpm ?? 120
                    nextSongAnalysis.beatInterval = nxtAn.beatInterval ?? (60.0 / nextSongAnalysis.bpm)
                    nextSongAnalysis.energy = nxtAn.energy ?? 0.5
                    nextSongAnalysis.key = nxtAn.key
                    nextSongAnalysis.outroStartTime = nxtAn.outroStartTime ?? max(nextDuration - 30, 0)
                    nextSongAnalysis.introEndTime = nxtAn.introEndTime ?? min(30, nextDuration)
                    nextSongAnalysis.vocalStartTime = nxtAn.vocalStartTime ?? 0
                    if let beats = nxtAn.beats { nextSongAnalysis.downbeatTimes = beats }
                    if let segs = nxtAn.speechSegments {
                        nextSongAnalysis.speechSegments = segs.map { (start: $0.start, end: $0.end) }
                    }
                }

                // Calculate crossfade
                let crossfadeResult = DJMixingService.calculateCrossfadeConfig(
                    currentAnalysis: currentSongAnalysis,
                    nextAnalysis: nextSongAnalysis,
                    bufferADuration: currentDuration,
                    bufferBDuration: nextDuration,
                    mode: self.isDjMode ? .dj : .normal
                )

                // Map to CrossfadeExecutor.Config
                let executorType: CrossfadeExecutor.TransitionType
                switch crossfadeResult.transitionType {
                case .crossfade:      executorType = .crossfade
                case .eqMix:          executorType = .eqMix
                case .cut:            executorType = .cut
                case .naturalBlend:   executorType = .naturalBlend
                case .beatMatchBlend: executorType = .beatMatchBlend
                case .cutAFadeInB:    executorType = .cutAFadeInB
                case .fadeOutACutB:   executorType = .fadeOutACutB
                }

                let config = CrossfadeExecutor.Config(
                    entryPoint: crossfadeResult.entryPoint,
                    fadeDuration: crossfadeResult.fadeDuration,
                    transitionType: executorType,
                    useFilters: crossfadeResult.useFilters,
                    useAggressiveFilters: crossfadeResult.useAggressiveFilters,
                    needsAnticipation: crossfadeResult.needsAnticipation,
                    anticipationTime: crossfadeResult.anticipationTime
                )

                // Set automix trigger on engine.
                // triggerTime = when in song A the crossfade should START.
                // entryPoint = where in song B to begin playing (NOT the trigger).
                // Use outroStartTime of song A, falling back to (duration - fadeDuration).
                let outroStart = currentSongAnalysis.outroStartTime
                var triggerTime: Double
                if outroStart > 0 && outroStart < currentDuration - 5 {
                    // Use analysis-based outro start
                    triggerTime = outroStart
                } else {
                    // Fallback: start crossfade `fadeDuration` seconds before song A ends
                    triggerTime = max(0, currentDuration - crossfadeResult.fadeDuration - 2)
                }

                // Safety: if we already passed the trigger point (e.g. after a seek),
                // don't set a trigger that would fire immediately.
                // Instead, set a safe fallback near the end of the song.
                let nowTime = AudioEngineManager.shared?.currentTime() ?? 0
                if nowTime >= triggerTime {
                    // We're already past the ideal crossfade point.
                    // Set trigger to (duration - 3s) to at least transition at the very end,
                    // but only if there's still enough time left.
                    let safeTime = currentDuration - 3.0
                    if nowTime < safeTime {
                        triggerTime = safeTime
                        print("[QueueManager] ⚠️ Already past trigger \(String(format: "%.1f", outroStart))s, moving to safe fallback \(String(format: "%.1f", triggerTime))s")
                    } else {
                        // We're within the last 3 seconds — don't set any trigger,
                        // let the song end naturally and audioEngineDidFinishSong will advance.
                        print("[QueueManager] ⚠️ Already past trigger and near end, skipping automix trigger")
                        return
                    }
                }

                AudioEngineManager.shared?.setAutomixTrigger(triggerTime: triggerTime, config: config)

                print("[QueueManager] Crossfade prepared: \(executorType.rawValue) trigger=\(String(format: "%.1f", triggerTime))s (outro=\(String(format: "%.1f", outroStart))s, dur=\(String(format: "%.1f", currentDuration))s, now=\(String(format: "%.1f", nowTime))s), fade=\(String(format: "%.1f", crossfadeResult.fadeDuration))s, B-entry=\(String(format: "%.1f", crossfadeResult.entryPoint))s")
            }
        }
    }

    // MARK: - Private: Play Current Song

    private func playCurrentSong() {
        guard let song = currentSong else { return }
        guard let streamURL = api.streamURL(songId: song.id) else {
            print("[QueueManager] No stream URL for \(song.id)")
            return
        }

        guard let engine = AudioEngineManager.shared else {
            print("[QueueManager] AudioEngineManager not ready")
            return
        }

        // Ensure we're the delegate
        engine.delegate = self

        let duration = song.duration

        // Try cached file first (fast path).
        // Some MP3s (VBR, unusual headers) fail AVAudioFile but play fine via AVPlayer.
        // If play() fails, fall through to the streaming path.
        var usedCachedFile = false
        if let cachedURL = AudioFileLoader.shared.cachedFileURL(for: song.id) {
            // Validate file can be opened by AVAudioFile before committing
            if (try? AVAudioFile(forReading: cachedURL)) != nil {
                engine.play(
                    fileURL: cachedURL,
                    startAt: 0,
                    replayGainMultiplier: effectiveReplayGain(for: song),
                    duration: duration,
                    title: song.title,
                    artist: song.artist,
                    album: song.album
                )
                usedCachedFile = true
            } else {
                print("[QueueManager] Cached file incompatible with AVAudioFile, falling back to stream: \(song.id)")
            }
        }

        if !usedCachedFile {
            // Streaming path — AVPlayer handles any format
            engine.playStreaming(
                remoteURL: streamURL,
                startAt: 0,
                replayGainMultiplier: effectiveReplayGain(for: song),
                duration: duration,
                title: song.title,
                artist: song.artist,
                album: song.album
            )
            // Download in background for cache (handoff will validate before switching)
            Task {
                guard let fileURL = try? await AudioFileLoader.shared.load(
                    remoteURL: streamURL,
                    songId: song.id
                ) else { return }
                await MainActor.run {
                    guard engine.isStreamMode else { return }
                    engine.handoffStreamToEngine(fileURL: fileURL)
                }
            }
        }

        isPlaying = true
        self.duration = duration
        self.currentTime = 0
        syncNowPlayingState()

        // Broadcast to Audiorr Connect (song changed = significant)
        ConnectService.shared.broadcastStateIfNeeded(significantChange: true)

        // Notify scrobble service
        ScrobbleService.shared.songDidStart(song)

        // Prepare next song for crossfade
        prepareNextForCrossfade()
    }

    // MARK: - Sync with NowPlayingState

    private func syncNowPlayingState() {
        let state = NowPlayingState.shared

        // Local playback overrides remote state
        if state.isRemote {
            state.isRemote = false
            state.remoteDeviceName = nil
            state.subtitle = nil
        }

        if let song = currentSong {
            state.title = song.title
            state.artist = song.artist
            state.songId = song.id
            state.albumId = song.albumId
            state.artistId = song.artistId
            state.coverArt = song.coverArt
            state.artworkUrl = NavidromeService.shared.coverURL(id: song.coverArt, size: 300)?.absoluteString
            state.isVisible = true
        }

        state.isPlaying = isPlaying
        state.progress = currentTime
        state.duration = duration > 0 ? duration : 1

        // Sync queue for the viewer
        state.queue = queue.map { $0.toQueueSong() }
    }

    // MARK: - Persistence

    private func persistState() {
        persistence.saveQueue(queue)
        persistence.currentIndex = currentIndex
        persistence.lastSongId = currentSong?.id
    }

    private func restoreState() {
        queue = persistence.loadQueue()
        originalQueue = queue
        currentIndex = persistence.currentIndex
        shuffleMode = persistence.shuffleMode
        repeatMode = RepeatMode(rawValue: persistence.repeatMode) ?? .off

        // Validate index
        if currentIndex >= queue.count { currentIndex = max(0, queue.count - 1) }
        if queue.isEmpty { currentIndex = -1 }

        // Don't auto-play on restore — just sync state
        if let song = currentSong {
            let state = NowPlayingState.shared
            state.title = song.title
            state.artist = song.artist
            state.songId = song.id
            state.albumId = song.albumId
            state.coverArt = song.coverArt
            state.artworkUrl = NavidromeService.shared.coverURL(id: song.coverArt, size: 300)?.absoluteString
            state.isVisible = true
            state.duration = song.duration
        }

        // Sync queue to NowPlayingState
        NowPlayingState.shared.queue = queue.map { $0.toQueueSong() }
    }

    // MARK: - Restore Last Playback from Backend

    /// Fetch last playback state from backend and populate mini player (no auto-play).
    func restoreLastPlayback() {
        guard queue.isEmpty,
              let username = NavidromeService.shared.credentials?.username
        else { return }

        Task {
            guard let last = await BackendService.shared.getLastPlayback(username: username) else { return }

            let song = PersistableSong(
                id: last.songId, title: last.title, artist: last.artist,
                album: last.album, albumId: last.albumId ?? "",
                artistId: "", coverArt: last.coverArt ?? "",
                duration: last.duration
            )

            await MainActor.run {
                queue = [song]
                originalQueue = [song]
                currentIndex = 0
                persistState()

                let state = NowPlayingState.shared
                state.title = song.title
                state.artist = song.artist
                state.songId = song.id
                state.albumId = song.albumId
                state.coverArt = song.coverArt
                state.artworkUrl = NavidromeService.shared.coverURL(id: song.coverArt, size: 300)?.absoluteString
                state.isVisible = true
                state.duration = song.duration
                state.progress = last.position
                state.queue = [song.toQueueSong()]
            }
        }
    }
}

// MARK: - AudioEngineDelegate Protocol

/// Protocol for AudioEngineManager to notify its owner about playback events.
/// Replaces CAPPlugin.notifyListeners() — no Capacitor dependency.
protocol AudioEngineDelegate: AnyObject {
    func audioEngineDidFinishSong()
    func audioEngineProgressUpdate(current: Double, duration: Double)
    func audioEnginePlaybackStateChanged(isPlaying: Bool, currentTime: Double)
    func audioEngineCrossfadeStarted()
    func audioEngineCrossfadeCompleted(startOffset: Double)
    func audioEngineDidSeek(to time: Double)
    func audioEngineError(_ message: String, code: String)
    func audioEngineNativeNext(title: String, artist: String, album: String, duration: Double)
}
