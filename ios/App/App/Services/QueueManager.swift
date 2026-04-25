import Foundation
import AVFoundation

/// Native queue manager — replaces PlayerContext.tsx queue logic.
/// Source of truth for the playback queue, shuffle, repeat, and track advancement.
/// Conforms to AudioEngineDelegate to react to engine events (track end, progress, etc.).
@MainActor @Observable
final class QueueManager: AudioEngineDelegate {

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

    /// Position (seconds) to resume at when user presses play after cold-start restore.
    /// Set during restoreState()/restoreLastPlayback(), consumed by playCurrentSong().
    private var pendingResumePosition: Double = 0

    /// Read user settings from UserDefaults (audiorr_settings JSON dict).
    private var settingsDict: [String: Any]? {
        guard let json = UserDefaults.standard.string(forKey: "audiorr_settings"),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }

    private var isDjMode: Bool {
        settingsDict?["isDjMode"] as? Bool ?? true
    }

    private var useReplayGain: Bool {
        settingsDict?["useReplayGain"] as? Bool ?? true
    }

    private var crossfadeEnabled: Bool {
        // DJ mode always implies crossfade, regardless of the toggle
        if isDjMode { return true }
        // With backend, crossfade is always on (analysis-driven).
        // Without backend, user can toggle it (default off).
        if BackendState.shared.isAvailable { return true }
        return settingsDict?["crossfadeEnabled"] as? Bool ?? false
    }

    /// User-configured crossfade duration (seconds). Used as base/override depending on mode.
    private var crossfadeDuration: Double {
        settingsDict?["crossfadeDuration"] as? Double ?? 8
    }

    /// Get the effective ReplayGain multiplier for a song (1.0 if disabled).
    private func effectiveReplayGain(for song: PersistableSong) -> Float {
        useReplayGain ? song.replayGainMultiplier : 1.0
    }

    // Shuffle: original order preserved for unshuffle
    private var originalQueue: [PersistableSong] = []

    // Guards stale async results from prepareNextForCrossfade
    private var crossfadePreparationId: Int = 0
    private var crossfadePreparationTask: Task<Void, Never>?
    private let maxHistorySize = 500

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
            if let song = currentSong { appendToHistory(song) }
            currentIndex += 1

            // If we were mid-crossfade, N+1 was already playing — skip past it too
            if wasCrossfading && currentIndex < queue.count - 1 {
                if let song = currentSong { appendToHistory(song) }
                currentIndex += 1
            }
        } else if repeatMode == .all {
            if let song = currentSong { appendToHistory(song) }
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
            if let song = currentSong { appendToHistory(song) }
            currentIndex += 1

            if wasCrossfading && currentIndex < queue.count - 1 {
                if let song = currentSong { appendToHistory(song) }
                currentIndex += 1
            }
        } else if repeatMode == .all {
            if let song = currentSong { appendToHistory(song) }
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

        // Track whether we're removing the next song (crossfade target)
        let isNextSong = (index == currentIndex + 1)

        // If removing the NEXT song while crossfading into it, cancel the crossfade.
        // The crossfade is transitioning to queue[currentIndex+1] — removing it would
        // leave the executor playing a song that's no longer in the queue.
        let isCrossfading = AudioEngineManager.shared?.isCrossfading == true
        if isCrossfading && isNextSong {
            AudioEngineManager.shared?.cancelCrossfade()
            print("[QueueManager] Cancelled crossfade: next song removed from queue")
        }

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
            } else {
                currentIndex = min(currentIndex, queue.count - 1)
                playCurrentSong()
            }
        }

        // Sync UI and recalculate crossfade for the new next song
        syncNowPlayingState()
        if isNextSong || index <= currentIndex + 1 {
            prepareNextForCrossfade()
        }
        persistState()
    }

    func move(from source: IndexSet, to destination: Int) {
        // Track if the next song (crossfade target) is being moved
        let nextSongMoved = source.contains(currentIndex + 1)

        // Cancel crossfade if the next song (being faded into) is moved away
        if AudioEngineManager.shared?.isCrossfading == true, nextSongMoved {
            AudioEngineManager.shared?.cancelCrossfade()
            print("[QueueManager] Cancelled crossfade: next song moved in queue")
        }
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

        // Sync UI and recalculate crossfade for the (potentially new) next song
        syncNowPlayingState()
        prepareNextForCrossfade()
        persistState()
    }

    func clearUpcoming() {
        guard currentIndex >= 0 else { return }
        // Cancel crossfade if in progress — the next song is being removed
        if AudioEngineManager.shared?.isCrossfading == true {
            AudioEngineManager.shared?.cancelCrossfade()
            print("[QueueManager] Cancelled crossfade: upcoming queue cleared")
        }
        queue = Array(queue.prefix(currentIndex + 1))
        AudioEngineManager.shared?.clearAutomixTrigger()
        syncNowPlayingState()
        persistState()
    }

    func clear() {
        // stop() already handles crossfade cancellation internally
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

            // Pre-fetch lyrics for the NEXT song so they're cached when crossfade completes.
            // Without this, lyrics only start loading after songId changes (post-swap),
            // causing a visible delay.
            if self.currentIndex + 1 < self.queue.count {
                let next = self.queue[self.currentIndex + 1]
                Task {
                    _ = await LyricsService.shared.fetch(
                        songId: next.id, title: next.title, artist: next.artist
                    )
                }
            }
        }
    }

    nonisolated func audioEngineCrossfadeCompleted(startOffset: Double) {
        Task { @MainActor in
            NowPlayingState.shared.isCrossfading = false
            // After crossfade, the engine already swapped players.
            // Advance our index to match.
            if currentIndex < queue.count - 1 {
                if let song = currentSong { appendToHistory(song) }
                currentIndex += 1

                // CRITICAL: Read fresh values from the engine BEFORE syncing UI.
                // Without this, syncNowPlayingState() uses stale currentTime/duration
                // from the old song, causing progress bar overflow and time glitches.
                if let engine = AudioEngineManager.shared {
                    self.currentTime = engine.currentTime()
                    self.duration = engine.currentSongDuration
                }

                persistState()
                syncNowPlayingState()

                // Push high-res artwork for the new song
                if let newSong = currentSong {
                    let artworkUrl = NavidromeService.shared.coverURL(id: newSong.coverArt, size: 1024)?.absoluteString
                    AudioEngineManager.shared?.updateNowPlayingMetadata(
                        title: newSong.title, artist: newSong.artist, album: newSong.album,
                        duration: newSong.duration, artworkUrl: artworkUrl
                    )
                }

                // Broadcast to Audiorr Connect (song changed = significant)
                ConnectService.shared.broadcastStateIfNeeded(significantChange: true)

                // Notify scrobble service
                if let newSong = currentSong {
                    ScrobbleService.shared.songDidStart(newSong)
                    Task { await OfflineStorageManager.shared.markPlayed(songId: newSong.id) }
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

        // Safe skip: only when truly offline AND song is not cached.
        // Never skip proactively on weak signal — let AVPlayer buffer/retry.
        // Only skip after a real playback failure has been reported by the engine.
        Task { @MainActor in
            guard !NetworkMonitor.shared.isConnected else { return }
            guard let song = self.currentSong else { return }
            guard !AudioFileLoader.shared.isCached(song.id) else { return }

            print("[QueueManager] Offline + uncached + engine error → skipping: \(song.title)")
            self.skipNext()
        }
    }

    nonisolated func audioEngineNativeNext(title: String, artist: String, album: String, duration: Double) {
        Task { @MainActor in
            // Engine played next directly (lock screen skip while JS frozen)
            if currentIndex < queue.count - 1 {
                if let song = currentSong { appendToHistory(song) }
                currentIndex += 1
                persistState()
                syncNowPlayingState()
            }
        }
    }

    nonisolated func audioEngineNeedsReload() {
        Task { @MainActor in
            guard currentSong != nil else {
                print("[QueueManager] audioEngineNeedsReload — no current song")
                return
            }
            // Restore pending position from NowPlayingState (set during restoreState/restoreLastPlayback)
            let savedPos = NowPlayingState.shared.progress
            if savedPos > 0 {
                self.pendingResumePosition = savedPos
            }
            print("[QueueManager] audioEngineNeedsReload — loading song at \(String(format: "%.1f", self.pendingResumePosition))s")
            self.playCurrentSong()
        }
    }

    // MARK: - History (bounded)

    private func appendToHistory(_ song: PersistableSong) {
        history.append(song)
        if history.count > maxHistorySize {
            history.removeFirst(history.count - maxHistorySize)
        }
    }

    // MARK: - Automix / Crossfade Preparation

    /// Prepare next song for crossfade. Called after advancing queue or after seek.
    private func prepareNextForCrossfade() {
        crossfadePreparationTask?.cancel()
        guard let current = currentSong,
              currentIndex + 1 < queue.count else { return }
        let nextSong = queue[currentIndex + 1]

        guard let streamURL = api.streamURL(songId: nextSong.id) else { return }
        let currentStreamURL = api.streamURL(songId: current.id)

        // If crossfade is disabled, don't set any automix trigger.
        // Songs will transition via audioEngineDidFinishSong (natural end).
        guard crossfadeEnabled else {
            print("[QueueManager] Crossfade disabled — skipping automix preparation")
            return
        }

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
        crossfadePreparationTask = Task {
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
                // Prefer engine duration (derived from actual file frames) over metadata.
                // Metadata from Navidrome can be wrong for re-encoded/VBR files.
                let currentDuration = engineDuration > 0 ? engineDuration : (metaDuration > 0 ? metaDuration : 0)
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

                // Mark as "no data" when backend analysis is unavailable
                // so DJMixingService uses userFadeDuration instead of structural calculation
                if curAn == nil { currentSongAnalysis.hasError = true }
                if nxtAn == nil { nextSongAnalysis.hasError = true }

                if let curAn {
                    // We need to call this synchronously but it's on an actor
                    // Use defaults + direct mapping instead
                    currentSongAnalysis.bpm = curAn.bpm ?? 120
                    currentSongAnalysis.beatInterval = curAn.beatInterval ?? (60.0 / currentSongAnalysis.bpm)
                    currentSongAnalysis.energy = curAn.energy ?? 0.5
                    currentSongAnalysis.danceability = curAn.danceability ?? 0.5
                    currentSongAnalysis.key = curAn.key
                    // BPM policy: prefer Essentia when confidence is high.
                    // bpmEssentia is null until backend batch completes — graceful fallback to librosa.
                    if let bpmE = curAn.bpmEssentia, let conf = curAn.bpmConfidence, conf > 0.8 {
                        currentSongAnalysis.bpm = bpmE
                        currentSongAnalysis.beatInterval = 60.0 / bpmE
                    }

                    // Top-level intro/outro = ML prediction (human-labeled training data).
                    // Heuristic = percussive/energy/spectral detection (mechanical boundary).
                    // Use ML as primary. Heuristic is fallback when ML not available.
                    currentSongAnalysis.outroStartTime = curAn.outroStartTime
                        ?? curAn.outroStartHeuristic
                        ?? max(currentDuration - 30, 0)
                    currentSongAnalysis.introEndTime = curAn.introEndTime
                        ?? curAn.introEndHeuristic
                        ?? min(30, currentDuration)
                    // vocalStartTime: top-level once backend persists it, fallback to diagnostics
                    currentSongAnalysis.vocalStartTime = curAn.vocalStartTime
                        ?? curAn.vocalStartFromDiagnostics
                        ?? 0
                    // Mark whether real analysis data was present for outro/intro
                    currentSongAnalysis.hasOutroData = curAn.outroStartTime != nil || curAn.outroStartHeuristic != nil
                    currentSongAnalysis.hasIntroData = curAn.introEndTime != nil || curAn.introEndHeuristic != nil
                    // Backend `beats` contains ALL beats (every hit), not downbeats (first beat of each measure).
                    // Downbeats = every 4th beat in 4/4 time. Extract them for beat sync phase alignment.
                    if let beats = curAn.beats, beats.count >= 4 {
                        currentSongAnalysis.downbeatTimes = stride(from: 0, to: beats.count, by: 4).map { beats[$0] }
                    }
                    if let segs = curAn.speechSegments {
                        currentSongAnalysis.speechSegments = segs.map { (start: $0.start, end: $0.end) }
                    }
                    // Backend-calculated cue point (from diagnostics.fade_info)
                    if let cue = curAn.cuePoint, cue > 0, cue < currentDuration {
                        currentSongAnalysis.cuePoint = cue
                        currentSongAnalysis.hasCuePoint = true
                    }
                    // Per-section energy (from diagnostics.fade_info.energyProfile)
                    if let ep = curAn.energyProfile {
                        currentSongAnalysis.energyIntro = ep.intro ?? currentSongAnalysis.energy
                        currentSongAnalysis.energyMain = ep.main ?? currentSongAnalysis.energy
                        currentSongAnalysis.energyOutro = ep.outro ?? currentSongAnalysis.energy
                        currentSongAnalysis.hasEnergyProfile = true
                        currentSongAnalysis.hasIntroVocals = ep.introVocals ?? false
                        currentSongAnalysis.hasOutroVocals = ep.outroVocals ?? false
                    }
                    // Backend fade durations
                    if let fi = curAn.fadeInDuration, fi > 0 { currentSongAnalysis.backendFadeInDuration = fi }
                    if let fo = curAn.fadeOutDuration, fo > 0 { currentSongAnalysis.backendFadeOutDuration = fo }
                    if let fol = curAn.fadeOutLeadTime, fol > 0 { currentSongAnalysis.backendFadeOutLeadTime = fol }
                    // Last vocal time (from analysis_log.Instrumental Outro)
                    if let lvt = curAn.lastVocalTime, lvt > 0, lvt < currentDuration {
                        currentSongAnalysis.lastVocalTime = lvt
                        currentSongAnalysis.hasVocalEndData = true
                    }
                    // ML override tracking (for sanitize cross-validation)
                    currentSongAnalysis.modelUsed = curAn.modelUsed ?? false
                    currentSongAnalysis.introEndTimeHeuristic = curAn.introEndHeuristic
                    currentSongAnalysis.outroStartTimeHeuristic = curAn.outroStartHeuristic
                }

                if let nxtAn {
                    nextSongAnalysis.bpm = nxtAn.bpm ?? 120
                    nextSongAnalysis.beatInterval = nxtAn.beatInterval ?? (60.0 / nextSongAnalysis.bpm)
                    nextSongAnalysis.energy = nxtAn.energy ?? 0.5
                    nextSongAnalysis.danceability = nxtAn.danceability ?? 0.5
                    nextSongAnalysis.key = nxtAn.key
                    // BPM policy: prefer Essentia when confidence is high
                    if let bpmE = nxtAn.bpmEssentia, let conf = nxtAn.bpmConfidence, conf > 0.8 {
                        nextSongAnalysis.bpm = bpmE
                        nextSongAnalysis.beatInterval = 60.0 / bpmE
                    }
                    // ML primary, heuristic fallback (same policy as currentSong)
                    nextSongAnalysis.outroStartTime = nxtAn.outroStartTime
                        ?? nxtAn.outroStartHeuristic
                        ?? max(nextDuration - 30, 0)
                    nextSongAnalysis.introEndTime = nxtAn.introEndTime
                        ?? nxtAn.introEndHeuristic
                        ?? min(30, nextDuration)
                    nextSongAnalysis.vocalStartTime = nxtAn.vocalStartTime
                        ?? nxtAn.vocalStartFromDiagnostics
                        ?? 0
                    nextSongAnalysis.hasOutroData = nxtAn.outroStartTime != nil || nxtAn.outroStartHeuristic != nil
                    nextSongAnalysis.hasIntroData = nxtAn.introEndTime != nil || nxtAn.introEndHeuristic != nil
                    if let beats = nxtAn.beats, beats.count >= 4 {
                        nextSongAnalysis.downbeatTimes = stride(from: 0, to: beats.count, by: 4).map { beats[$0] }
                    }
                    if let segs = nxtAn.speechSegments {
                        nextSongAnalysis.speechSegments = segs.map { (start: $0.start, end: $0.end) }
                    }
                    // Per-section energy for next song
                    if let ep = nxtAn.energyProfile {
                        nextSongAnalysis.energyIntro = ep.intro ?? nextSongAnalysis.energy
                        nextSongAnalysis.energyMain = ep.main ?? nextSongAnalysis.energy
                        nextSongAnalysis.energyOutro = ep.outro ?? nextSongAnalysis.energy
                        nextSongAnalysis.hasEnergyProfile = true
                        nextSongAnalysis.hasIntroVocals = ep.introVocals ?? false
                        nextSongAnalysis.hasOutroVocals = ep.outroVocals ?? false
                    }
                    // Backend fade durations for next song
                    if let fi = nxtAn.fadeInDuration, fi > 0 { nextSongAnalysis.backendFadeInDuration = fi }
                    if let fo = nxtAn.fadeOutDuration, fo > 0 { nextSongAnalysis.backendFadeOutDuration = fo }
                    // Last vocal time for next song
                    if let lvt = nxtAn.lastVocalTime, lvt > 0, lvt < nextDuration {
                        nextSongAnalysis.lastVocalTime = lvt
                        nextSongAnalysis.hasVocalEndData = true
                    }
                    // ML override tracking for next song
                    nextSongAnalysis.modelUsed = nxtAn.modelUsed ?? false
                    nextSongAnalysis.introEndTimeHeuristic = nxtAn.introEndHeuristic
                    nextSongAnalysis.outroStartTimeHeuristic = nxtAn.outroStartHeuristic
                    // Chorus structure
                    let chorusSource = nxtAn.chorusStructure ?? nxtAn.structure
                    if let structure = chorusSource,
                       let chorus = structure.first(where: { $0.label.lowercased().contains("chorus") }) {
                        nextSongAnalysis.chorusStartTime = chorus.startTime
                    }
                    // Phrase boundaries
                    if let structure = chorusSource ?? nxtAn.structure {
                        nextSongAnalysis.phraseBoundaries = structure.map { $0.startTime }
                    }
                }

                // Calculate crossfade
                let currentPlaybackTime = AudioEngineManager.shared?.currentTime() ?? 0
                let crossfadeResult = DJMixingService.calculateCrossfadeConfig(
                    currentAnalysis: currentSongAnalysis,
                    nextAnalysis: nextSongAnalysis,
                    bufferADuration: currentDuration,
                    bufferBDuration: nextDuration,
                    mode: self.isDjMode ? .dj : .normal,
                    currentPlaybackTimeA: currentPlaybackTime,
                    userFadeDuration: self.crossfadeDuration
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
                case .stemMix:        executorType = .stemMix
                }

                let config = CrossfadeExecutor.Config(
                    entryPoint: crossfadeResult.entryPoint,
                    fadeDuration: crossfadeResult.fadeDuration,
                    transitionType: executorType,
                    useFilters: crossfadeResult.useFilters,
                    useAggressiveFilters: crossfadeResult.useAggressiveFilters,
                    needsAnticipation: crossfadeResult.needsAnticipation,
                    anticipationTime: crossfadeResult.anticipationTime,
                    useTimeStretch: crossfadeResult.useTimeStretch,
                    rateA: crossfadeResult.rateA,
                    rateB: crossfadeResult.rateB,
                    energyA: crossfadeResult.energyA,
                    energyB: crossfadeResult.energyB,
                    beatIntervalA: crossfadeResult.beatIntervalA,
                    beatIntervalB: crossfadeResult.beatIntervalB,
                    downbeatTimesA: crossfadeResult.downbeatTimesA,
                    downbeatTimesB: crossfadeResult.downbeatTimesB,
                    useMidScoop: crossfadeResult.useMidScoop,
                    useHighShelfCut: crossfadeResult.useHighShelfCut,
                    isOutroInstrumental: crossfadeResult.isOutroInstrumental,
                    isIntroInstrumental: crossfadeResult.isIntroInstrumental,
                    danceability: crossfadeResult.danceability,
                    skipBFilters: crossfadeResult.skipBFilters
                )

                // Publish transition reason to diagnostics
                Task { @MainActor in
                    TransitionDiagnostics.shared.transitionReason = crossfadeResult.transitionReason
                    TransitionDiagnostics.shared.outroStartA = currentSongAnalysis.outroStartTime
                    TransitionDiagnostics.shared.introEndB = nextSongAnalysis.introEndTime
                    TransitionDiagnostics.shared.vocalStartB = nextSongAnalysis.vocalStartTime
                    TransitionDiagnostics.shared.chorusStartB = nextSongAnalysis.chorusStartTime
                    TransitionDiagnostics.shared.hasIntroVocalsB = nextSongAnalysis.hasIntroVocals
                }

                // ── Trailing silence on A ──
                // Use AudioEngineManager.currentEffectiveEnd if set from analysis (energy-based).
                // Do NOT use speechSegments for this — speechSegments tracks vocals only.
                // An instrumental outro is NOT silence and must not be trimmed.
                var effectiveDuration = currentDuration
                let engineEffEnd = AudioEngineManager.shared?.currentEffectiveEnd ?? 0
                if engineEffEnd > 0 && engineEffEnd < currentDuration - 3 {
                    effectiveDuration = engineEffEnd + 1.0
                    print("[QueueManager] Trailing silence: effectiveEnd=\(String(format: "%.1f", engineEffEnd))s, file=\(String(format: "%.1f", currentDuration))s")
                }

                // ── Leading silence on B (analysis-based) ──
                // If B's entry point is at 0 but vocal/chorus starts later, skip past silence.
                let adjustedEntryPoint = crossfadeResult.entryPoint

                // Update config with adjusted entry point if needed
                let finalConfig: CrossfadeExecutor.Config
                if adjustedEntryPoint != crossfadeResult.entryPoint {
                    finalConfig = CrossfadeExecutor.Config(
                        entryPoint: adjustedEntryPoint,
                        fadeDuration: config.fadeDuration,
                        transitionType: config.transitionType,
                        useFilters: config.useFilters,
                        useAggressiveFilters: config.useAggressiveFilters,
                        needsAnticipation: config.needsAnticipation,
                        anticipationTime: config.anticipationTime,
                        useTimeStretch: config.useTimeStretch,
                        rateA: config.rateA,
                        rateB: config.rateB,
                        energyA: config.energyA,
                        energyB: config.energyB,
                        beatIntervalA: config.beatIntervalA,
                        beatIntervalB: config.beatIntervalB,
                        downbeatTimesA: config.downbeatTimesA,
                        downbeatTimesB: config.downbeatTimesB,
                        useMidScoop: config.useMidScoop,
                        useHighShelfCut: config.useHighShelfCut,
                        isOutroInstrumental: config.isOutroInstrumental,
                        isIntroInstrumental: config.isIntroInstrumental,
                        danceability: config.danceability,
                        skipBFilters: config.skipBFilters
                    )
                } else {
                    finalConfig = config
                }

                // Set automix trigger on engine.
                // triggerTime = when in song A the crossfade should START.
                // entryPoint = where in song B to begin playing (NOT the trigger).
                //
                // DJ logic: trigger AT the outro (like a real DJ), not at the last moment.
                // A DJ hears the outro starting and begins mixing — they don't wait until
                // the song is almost over. The fade overlaps with A's outro, so the listener
                // never hears the dead outro tail.
                //
                //   1. cuePoint → use it as trigger anchor (backend calculated)
                //   2. outroStart → trigger AT the outro, not after it
                //   3. lastVocalTime → don't trigger while vocals are still playing
                //   4. Fallback: end-based trigger (effectiveDuration - fadeDur - 1)
                let outroStart = currentSongAnalysis.outroStartTime
                let fadeDur = crossfadeResult.fadeDuration
                var triggerTime: Double

                // ── Trigger calculation ──
                // Step 1: Vocal safety floor — don't start crossfade while vocals play
                var vocalFloor: Double = 0
                if currentSongAnalysis.hasVocalEndData
                    && currentSongAnalysis.lastVocalTime > 0
                    && currentSongAnalysis.lastVocalTime < effectiveDuration - 3 {
                    vocalFloor = currentSongAnalysis.lastVocalTime
                }

                // cuePoint from backend — best estimate of transition zone start
                if currentSongAnalysis.hasCuePoint {
                    vocalFloor = max(vocalFloor, currentSongAnalysis.cuePoint)
                    print("[QueueManager] Backend cuePoint=\(String(format: "%.1f", currentSongAnalysis.cuePoint))s used as floor")
                }

                // Step 2: Determine ideal trigger point
                let triggerBias = crossfadeResult.triggerBias
                let endBasedTrigger = max(0, effectiveDuration - fadeDur - 1 + triggerBias)
                if abs(triggerBias) > 0.1 {
                    print("[QueueManager] Trigger bias: \(triggerBias >= 0 ? "+" : "")\(String(format: "%.1f", triggerBias))s — \(crossfadeResult.triggerBiasReason)")
                }

                // Use outroStart as anchor when it's meaningfully before the end.
                // A DJ starts mixing AT the outro — the fade runs over it, the listener
                // never hears the dead outro tail. This is the #1 DJ behavior fix.
                let idealTrigger: Double
                if outroStart > 0 && outroStart < effectiveDuration - 10 {
                    idealTrigger = max(0, outroStart + triggerBias)
                    print("[QueueManager] Outro-anchored trigger: outroStart=\(String(format: "%.1f", outroStart))s → ideal=\(String(format: "%.1f", idealTrigger))s")
                } else {
                    idealTrigger = endBasedTrigger
                }

                // Step 3: Respect vocal floor — don't trigger over vocals
                // But never push past end-based trigger (would leave no room for fade)
                if vocalFloor > idealTrigger && vocalFloor < endBasedTrigger {
                    triggerTime = vocalFloor
                    print("[QueueManager] Vocal floor pushed trigger to \(String(format: "%.1f", vocalFloor))s")
                } else {
                    triggerTime = idealTrigger
                }

                // Safety: if trigger + fade doesn't fit, fall back to end-based
                if triggerTime + fadeDur > effectiveDuration + 1 {
                    triggerTime = endBasedTrigger
                    print("[QueueManager] Trigger too late for fade — falling back to end-based \(String(format: "%.1f", endBasedTrigger))s")
                }

                let anchorDesc: String
                if currentSongAnalysis.hasCuePoint {
                    anchorDesc = "cuePoint"
                } else if outroStart > 0 && outroStart < effectiveDuration - 10 {
                    anchorDesc = "outro"
                } else if vocalFloor > 0 {
                    anchorDesc = currentSongAnalysis.hasVocalEndData ? "lastVocal" : "end"
                } else {
                    anchorDesc = "end"
                }
                print("[QueueManager] Trigger: ideal=\(String(format: "%.1f", idealTrigger))s vocal=\(String(format: "%.1f", vocalFloor))s anchor=\(anchorDesc) → \(String(format: "%.1f", triggerTime))s")

                // ── Snap trigger to A's nearest phrase/downbeat boundary ──
                // A DJ always starts a mix on a musical phrase boundary.
                // Starting mid-phrase sounds amateur and random.
                if !currentSongAnalysis.phraseBoundaries.isEmpty {
                    // Prefer phrase boundaries (8/16 bar groupings)
                    let maxEarly = crossfadeResult.fadeDuration * 0.3  // don't shift more than 30% of fade
                    if let best = currentSongAnalysis.phraseBoundaries
                        .filter({ $0 >= triggerTime - maxEarly && $0 <= triggerTime + maxEarly && $0 > 0 })
                        .min(by: { abs($0 - triggerTime) < abs($1 - triggerTime) }) {
                        let adj = best - triggerTime
                        triggerTime = best
                        print("[QueueManager] Trigger snapped to phrase boundary: \(adj >= 0 ? "+" : "")\(String(format: "%.2f", adj))s")
                    }
                } else if !currentSongAnalysis.downbeatTimes.isEmpty
                            && currentSongAnalysis.beatInterval > 0 {
                    // Fallback: snap to nearest downbeat
                    let maxShift = currentSongAnalysis.beatInterval * 2
                    if let best = currentSongAnalysis.downbeatTimes
                        .filter({ $0 >= triggerTime - maxShift && $0 <= triggerTime + maxShift && $0 > 0 })
                        .min(by: { abs($0 - triggerTime) < abs($1 - triggerTime) }) {
                        let adj = best - triggerTime
                        triggerTime = best
                        print("[QueueManager] Trigger snapped to downbeat: \(adj >= 0 ? "+" : "")\(String(format: "%.2f", adj))s")
                    }
                }

                // CRITICAL: For CUT_A type transitions (A ends abruptly), the trigger must be
                // early enough so B reaches full volume BEFORE A cuts. The fade duration is the
                // time B needs to ramp up — trigger must be at least fadeDuration before effective end.
                // Without this, A cuts while B is still at partial volume → audible gap.
                if executorType == .cutAFadeInB || executorType == .cut || executorType == .eqMix {
                    let minTrigger = effectiveDuration - crossfadeResult.fadeDuration - 1
                    if triggerTime > minTrigger {
                        triggerTime = max(0, minTrigger)
                        print("[QueueManager] Adjusted trigger for abrupt-A transition: \(String(format: "%.1f", triggerTime))s (ensures B reaches full volume)")
                    }
                }

                // Post-snap safety: if trigger was snapped forward (by phrase/downbeat alignment),
                // the remaining time (effectiveDuration - triggerTime) may be too short for the
                // full fade duration. This causes B to still be ramping when A ends → audible gap.
                // Fix: clamp trigger so at least fadeDur + 0.5s fits before A's end.
                let remainingAfterTrigger = effectiveDuration - triggerTime
                if remainingAfterTrigger < fadeDur + 0.5 && remainingAfterTrigger > 2.0 {
                    // Enough room for a shorter fade — pull trigger back
                    triggerTime = max(0, effectiveDuration - fadeDur - 0.5)
                    print("[QueueManager] Post-snap clamp: remaining too short, trigger moved to \(String(format: "%.1f", triggerTime))s")
                } else if remainingAfterTrigger <= 2.0 && triggerTime > 5.0 {
                    // Less than 2s left — not enough for any meaningful fade.
                    // Pull trigger back to idealTrigger (let the full fade play out).
                    let idealFallback = max(0, effectiveDuration - fadeDur - 1)
                    triggerTime = idealFallback
                    print("[QueueManager] Post-snap clamp: <2s remaining, reverted to ideal trigger \(String(format: "%.1f", triggerTime))s")
                }

                // Safety: if we already passed the trigger point (e.g. after a seek),
                // don't set a trigger that would fire immediately.
                // Instead, set a safe fallback near the end of the song.
                let nowTime = AudioEngineManager.shared?.currentTime() ?? 0
                if nowTime >= triggerTime {
                    // We're already past the ideal crossfade point.
                    // Set trigger to (effectiveDuration - 3s) to at least transition at the very end,
                    // but only if there's still enough time left.
                    let safeTime = effectiveDuration - 3.0
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

                AudioEngineManager.shared?.setAutomixTrigger(triggerTime: triggerTime, config: finalConfig)

                print("[QueueManager] Crossfade prepared: \(executorType.rawValue) trigger=\(String(format: "%.1f", triggerTime))s (outro=\(String(format: "%.1f", outroStart))s, effDur=\(String(format: "%.1f", effectiveDuration))s, dur=\(String(format: "%.1f", currentDuration))s, now=\(String(format: "%.1f", nowTime))s), fade=\(String(format: "%.1f", crossfadeResult.fadeDuration))s, B-entry=\(String(format: "%.1f", adjustedEntryPoint))s")
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

        // Consume pending resume position (cold-start restore).
        // Clamp to valid range — don't resume within last 5s (would trigger crossfade immediately).
        var startAt = pendingResumePosition
        if startAt > 0 && duration > 0 && startAt >= duration - 5 {
            startAt = 0 // Too close to end, start from beginning
        }
        pendingResumePosition = 0
        if startAt > 0 {
            print("[QueueManager] Resuming at \(String(format: "%.1f", startAt))s (restored position)")
        }

        // Try cached file first (fast path).
        // Some MP3s (VBR, unusual headers) fail AVAudioFile but play fine via AVPlayer.
        // If play() fails, fall through to the streaming path.
        var usedCachedFile = false
        if let cachedURL = AudioFileLoader.shared.cachedFileURL(for: song.id) {
            // Validate file can be opened by AVAudioFile before committing
            if (try? AVAudioFile(forReading: cachedURL)) != nil {
                engine.play(
                    fileURL: cachedURL,
                    startAt: startAt,
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
                startAt: startAt,
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
        // Prefer engine-resolved duration (from file frames) over metadata.
        // TopWeekly songs have duration=0 in metadata — the engine resolves
        // the real duration from the cached file immediately in play(fileURL:).
        let engineDuration = AudioEngineManager.shared?.currentSongDuration ?? 0
        self.duration = engineDuration > 0 ? engineDuration : duration
        self.currentTime = startAt
        syncNowPlayingState()

        // Push high-res artwork to lock screen / Dynamic Island / Control Center
        let artworkUrl = NavidromeService.shared.coverURL(id: song.coverArt, size: 1024)?.absoluteString
        engine.updateNowPlayingMetadata(
            title: song.title, artist: song.artist, album: song.album,
            duration: duration, artworkUrl: artworkUrl
        )

        // Broadcast to Audiorr Connect (song changed = significant)
        ConnectService.shared.broadcastStateIfNeeded(significantChange: true)

        // Notify scrobble service
        ScrobbleService.shared.songDidStart(song)

        // Mark song as played in offline cache (for LRU ordering)
        Task { await OfflineStorageManager.shared.markPlayed(songId: song.id) }

        // Prepare next song for crossfade
        prepareNextForCrossfade()

        // Pre-cache next 3 songs in queue for offline (priority 1)
        preCacheUpcoming()
    }

    /// Pre-cache the next 3 songs in the queue via DownloadManager.
    private func preCacheUpcoming() {
        guard PersistenceService.shared.offlineAutoCacheEnabled else { return }
        let start = currentIndex + 1
        let end = min(start + 3, queue.count)
        guard start < end else { return }
        let upcoming = Array(queue[start..<end])
        DownloadManager.shared.preCacheSongs(upcoming)
    }

    // MARK: - Sync with NowPlayingState

    private func syncNowPlayingState() {
        let state = NowPlayingState.shared

        // Don't overwrite remote state when local player is idle
        if state.isRemote && !isPlaying && currentSong == nil {
            return
        }

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
            state.isExplicit = song.isExplicit
            state.artworkUrl = NavidromeService.shared.coverURL(id: song.coverArt, size: 300)?.absoluteString
            state.isVisible = true
        }

        state.isPlaying = isPlaying
        state.progress = currentTime
        state.duration = duration > 0 ? duration : 1
        state.contextUri = PlayerService.shared.currentContextUri ?? ""

        // Sync queue for the viewer
        state.queue = queue.map { $0.toQueueSong() }
    }

    // MARK: - Persistence

    private func persistState() {
        persistence.saveQueue(queue)
        persistence.currentIndex = currentIndex
        persistence.lastSongId = currentSong?.id
        persistence.position = NowPlayingState.shared.progress
        saveToBackend()
    }

    /// Save position immediately (called from app lifecycle events).
    func savePositionNow() {
        let pos = AudioEngineManager.shared?.currentTime() ?? NowPlayingState.shared.progress
        persistence.position = pos
        NowPlayingState.shared.progress = pos
        // Also fire backend save (non-debounced)
        saveToBackend()
        print("[QueueManager] Position saved: \(String(format: "%.1f", pos))s")
    }

    /// Debounced save to backend — persists current song + queue for cross-device restore.
    private var saveToBackendWork: DispatchWorkItem?

    private func saveToBackend() {
        saveToBackendWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let song = self.currentSong,
                  let username = NavidromeService.shared.credentials?.username
            else { return }

            let queueItems = self.queue.map { s in
                BackendService.LastPlaybackQueueItem(
                    id: s.id, title: s.title, artist: s.artist,
                    album: s.album, albumId: s.albumId, coverArt: s.coverArt,
                    duration: s.duration
                )
            }

            let state = BackendService.LastPlaybackState(
                songId: song.id, title: song.title, artist: song.artist,
                album: song.album, coverArt: song.coverArt, albumId: song.albumId,
                path: "", duration: song.duration,
                position: NowPlayingState.shared.progress,
                savedAt: ISO8601DateFormatter().string(from: Date()),
                queue: queueItems,
                currentIndex: self.currentIndex
            )

            BackendService.shared.saveLastPlayback(username: username, state: state)
        }
        saveToBackendWork = work
        // Debounce 2 seconds to avoid flooding the backend on rapid queue changes
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
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

        // Restore saved position (local) for cold-start resume
        let savedPos = persistence.position
        pendingResumePosition = savedPos

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
            state.progress = savedPos
        }

        // Sync queue to NowPlayingState
        NowPlayingState.shared.queue = queue.map { $0.toQueueSong() }
    }

    // MARK: - Restore Last Playback from Backend

    /// Fetch last playback state from backend and populate mini player + queue (no auto-play).
    func restoreLastPlayback() {
        guard queue.isEmpty,
              let username = NavidromeService.shared.credentials?.username
        else { return }

        Task {
            guard let last = await BackendService.shared.getLastPlayback(username: username) else { return }

            await MainActor.run {
                // Restore full queue if available, otherwise just the single song
                if let queueItems = last.queue, !queueItems.isEmpty {
                    let restoredQueue = queueItems.map { item in
                        PersistableSong(
                            id: item.id, title: item.title, artist: item.artist,
                            album: item.album, albumId: item.albumId ?? "",
                            artistId: "", coverArt: item.coverArt ?? "",
                            duration: item.duration
                        )
                    }
                    queue = restoredQueue
                    originalQueue = restoredQueue
                    currentIndex = last.currentIndex ?? restoredQueue.firstIndex(where: { $0.id == last.songId }) ?? 0
                } else {
                    let song = PersistableSong(
                        id: last.songId, title: last.title, artist: last.artist,
                        album: last.album, albumId: last.albumId ?? "",
                        artistId: "", coverArt: last.coverArt ?? "",
                        duration: last.duration
                    )
                    queue = [song]
                    originalQueue = [song]
                    currentIndex = 0
                }

                // Validate index
                if currentIndex >= queue.count { currentIndex = max(0, queue.count - 1) }

                // Persist locally (but don't re-save to backend — we just loaded from there)
                persistence.saveQueue(queue)
                persistence.currentIndex = currentIndex
                persistence.lastSongId = currentSong?.id

                // Update UI state
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
                    state.progress = last.position
                    state.queue = queue.map { $0.toQueueSong() }
                }
            }
        }
    }

    // MARK: - Remote Queue Loading (from ConnectService sync)

    /// Load a queue received from another device via Socket.IO.
    /// Sets the queue and current index without starting playback.
    func loadRemoteQueue(songs: [PersistableSong], currentIndex: Int, position: Double) {
        guard !songs.isEmpty else { return }

        queue = songs
        originalQueue = songs
        self.currentIndex = min(currentIndex, songs.count - 1)

        // Persist locally
        persistence.saveQueue(queue)
        persistence.currentIndex = self.currentIndex
        persistence.lastSongId = currentSong?.id

        // Update UI
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
            state.progress = position
            state.queue = queue.map { $0.toQueueSong() }
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
    /// Called when resume() is invoked but no file/stream is loaded (cold-start).
    /// Delegate should call playCurrentSong() to load and start playback.
    func audioEngineNeedsReload()
}
