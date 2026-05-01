import Foundation

/// Caches audio analysis results for crossfade intelligence.
/// Fetches from Audiorr backend, caches in memory + disk (Caches directory).
/// Pre-fetches analysis for upcoming songs in the queue.
actor AnalysisCacheService {

    static let shared = AnalysisCacheService()

    // MARK: - Types

    /// Full analysis result from the backend — maps to AudioAnalysisResult in JS.
    /// Top-level fields come from the JSON root. Fields like cuePoint, energyProfile,
    /// fadeInDuration, fadeOutDuration live inside `diagnostics.fade_info` in the real JSON.
    struct AnalysisResult: Codable {
        // Top-level fields (always present in backend JSON)
        let bpm: Double?
        let beats: [Double]?
        let beatInterval: Double?
        let energy: Double?
        let key: String?
        let danceability: Double?
        let outroStartTime: Double?
        let introEndTime: Double?
        let vocalStartTime: Double?
        let speechSegments: [SpeechSegment]?
        let structure: [StructureSegment]?
        // New fields from backend v2
        let bpmEssentia: Double?
        let bpmConfidence: Double?
        let introEndTimeHeuristic: Double?
        let outroStartTimeHeuristic: Double?
        let modelUsed: Bool?
        // Temporal curves (normalized 0-1, 5s windows) — for future ML/visualization
        let rmsCurve: [Double]?
        let percussiveCurve: [Double]?
        let harmonicCurve: [Double]?
        let onsetDensity: [Double]?
        let rmsTailCurve: [Double]?
        // Diagnostics object — contains fade_info with cuePoint, energyProfile, etc.
        let diagnostics: Diagnostics?

        // Convenience accessors that pull from diagnostics.fade_info
        var fadeInDuration: Double? { diagnostics?.fadeInfo?.fadeInDuration }
        var fadeOutDuration: Double? { diagnostics?.fadeInfo?.fadeOutDuration }
        var cuePoint: Double? { diagnostics?.fadeInfo?.cuePoint }
        var fadeOutLeadTime: Double? { diagnostics?.fadeInfo?.fadeOutLeadTime }
        var energyProfile: EnergyProfile? { diagnostics?.fadeInfo?.energyProfile }
        /// Chorus structure from diagnostics — more complete than top-level `structure`
        var chorusStructure: [StructureSegment]? { diagnostics?.analysisLog?.lastChorusEnd?.chorusStructure }
        /// Last vocal time — where vocals actually end in the song (more precise than outroStartTime)
        var lastVocalTime: Double? { diagnostics?.analysisLog?.instrumentalOutro?.lastVocalTimeCandidate }
        /// Vocal start time — prefer top-level (once backend persists it), fallback to diagnostics
        var vocalStartFromDiagnostics: Double? { diagnostics?.analysisLog?.introDecision?.candidates?.vocal }
        /// Heuristic intro end — prefer top-level field, fallback to diagnostics
        var introEndHeuristic: Double? { introEndTimeHeuristic ?? diagnostics?.introEndTime }
        /// Heuristic outro start — prefer top-level field, fallback to diagnostics
        var outroStartHeuristic: Double? { outroStartTimeHeuristic ?? diagnostics?.finalOutroStartTime }

        struct Diagnostics: Codable {
            let fadeInfo: FadeInfo?
            let analysisLog: AnalysisLog?
            /// The diagnostics-level intro end time (from percussive/vocal/energy detection).
            /// Often more accurate than the top-level introEndTime.
            let introEndTime: Double?
            /// The final outro start time after hierarchy checks.
            let finalOutroStartTime: Double?

            enum CodingKeys: String, CodingKey {
                case fadeInfo = "fade_info"
                case analysisLog = "analysis_log"
                case introEndTime = "intro_end_time"
                case finalOutroStartTime = "final_outro_start_time"
            }
        }

        struct FadeInfo: Codable {
            let fadeInDuration: Double?
            let fadeOutDuration: Double?
            let cuePoint: Double?
            let fadeOutLeadTime: Double?
            let energyProfile: EnergyProfile?
        }

        struct AnalysisLog: Codable {
            let lastChorusEnd: LastChorusEnd?
            let instrumentalOutro: InstrumentalOutro?
            let introDecision: IntroDecision?
            let speechSegmentLog: SpeechSegmentLog?

            enum CodingKeys: String, CodingKey {
                case lastChorusEnd = "Last Chorus End"
                case instrumentalOutro = "Instrumental Outro"
                case introDecision = "Intro Decision"
                case speechSegmentLog = "Speech Segment"
            }
        }

        struct IntroDecision: Codable {
            let candidates: IntroCandidates?

            struct IntroCandidates: Codable {
                let vocal: Double?
                let percussive: Double?
                let energyBeat: Double?

                enum CodingKeys: String, CodingKey {
                    case vocal
                    case percussive
                    case energyBeat = "energy_beat"
                }
            }
        }

        struct SpeechSegmentLog: Codable {
            let decision: String?
            let segments: [SpeechSegment]?
        }

        struct InstrumentalOutro: Codable {
            let lastVocalTimeCandidate: Double?
            let decision: String?

            enum CodingKeys: String, CodingKey {
                case lastVocalTimeCandidate = "last_vocal_time_candidate"
                case decision
            }
        }

        struct LastChorusEnd: Codable {
            let chorusStructure: [StructureSegment]?

            enum CodingKeys: String, CodingKey {
                case chorusStructure = "chorus_structure"
            }
        }

        struct EnergyProfile: Codable {
            let intro: Double?
            let main: Double?
            let outro: Double?
            let introSlope: Double?
            let outroSlope: Double?
            let introVocals: Bool?
            let outroVocals: Bool?
        }

        struct SpeechSegment: Codable {
            let start: Double
            let end: Double
        }

        struct StructureSegment: Codable {
            let label: String
            let startTime: Double
            let endTime: Double
        }
    }

    // MARK: - Cache

    private var memoryCache: [String: AnalysisResult] = [:]
    private var inFlightTasks: [String: Task<AnalysisResult?, Never>] = [:]
    private let cacheDir: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = caches.appendingPathComponent("AudioAnalysis", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Get Analysis

    /// Track songs already queued for speechSegments revalidation (prevent repeated re-fetches).
    private var revalidatingIds: Set<String> = []

    /// Instant cache-only lookup (memory + disk). No network requests.
    func getCachedAnalysis(songId: String) -> AnalysisResult? {
        if let cached = memoryCache[songId] { return cached }
        if let disk = loadFromDisk(songId: songId) {
            memoryCache[songId] = disk
            return disk
        }
        return nil
    }

    /// Get analysis for a song, fetching from backend if not cached.
    /// When the cached result lacks speechSegments, a background re-fetch
    /// updates the cache for future crossfades (stale-while-revalidate).
    func getAnalysis(songId: String, streamURL: URL?) async -> AnalysisResult? {
        // Memory cache
        if let cached = memoryCache[songId] {
            revalidateCacheIfNeeded(songId: songId, cached: cached, streamURL: streamURL)
            return cached
        }

        // Disk cache
        if let disk = loadFromDisk(songId: songId) {
            memoryCache[songId] = disk
            revalidateCacheIfNeeded(songId: songId, cached: disk, streamURL: streamURL)
            return disk
        }

        // In-flight dedup
        if let existing = inFlightTasks[songId] {
            return await existing.value
        }

        // Fetch from backend
        guard let streamURL else { return nil }

        let task = Task<AnalysisResult?, Never> {
            await fetchFromBackend(songId: songId, streamURL: streamURL)
        }
        inFlightTasks[songId] = task
        let result = await task.value
        inFlightTasks[songId] = nil

        if let result {
            memoryCache[songId] = result
            saveToDisk(songId: songId, result: result)
        }

        return result
    }

    /// Get analysis with a maximum wait time. Returns cached result instantly.
    /// If not cached, starts a backend fetch and waits up to `timeout` seconds.
    /// The fetch continues in background even if timeout fires — result is cached
    /// for future calls or Phase 2 recalculation.
    func getAnalysisWithTimeout(songId: String, streamURL: URL?, timeout: TimeInterval) async -> AnalysisResult? {
        // Instant cache hit (memory + disk)
        if let cached = getCachedAnalysis(songId: songId) {
            revalidateCacheIfNeeded(songId: songId, cached: cached, streamURL: streamURL)
            return cached
        }
        guard let streamURL else { return nil }

        // Ensure backend fetch is running (deduped via inFlightTasks).
        // This unstructured Task continues even if our timeout fires.
        if inFlightTasks[songId] == nil {
            let sid = songId
            let url = streamURL
            inFlightTasks[sid] = Task<AnalysisResult?, Never> {
                let result = await self.fetchFromBackend(songId: sid, streamURL: url)
                if let result {
                    self.memoryCache[sid] = result
                    self.saveToDisk(songId: sid, result: result)
                }
                self.inFlightTasks[sid] = nil
                return result
            }
        }

        guard let fetchTask = inFlightTasks[songId] else { return nil }

        // Race: await fetch vs timeout.
        // cancelAll() only cancels the child wrapper tasks, NOT the underlying
        // unstructured fetchTask which continues caching in background.
        return await withTaskGroup(of: AnalysisResult?.self) { group in
            group.addTask {
                await fetchTask.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }

            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Convert analysis result to DJMixingService.SongAnalysis for crossfade calculations.
    func toSongAnalysis(_ result: AnalysisResult, duration: Double) -> DJMixingService.SongAnalysis {
        var analysis = DJMixingService.SongAnalysis()
        analysis.bpm = result.bpm ?? 120
        analysis.beatInterval = result.beatInterval ?? (60.0 / analysis.bpm)
        analysis.energy = result.energy ?? 0.5
        analysis.danceability = result.danceability ?? 0.5
        analysis.key = result.key
        analysis.outroStartTime = result.outroStartTime ?? max(duration - 30, 0)
        analysis.introEndTime = result.introEndTime ?? min(30, duration)
        // Top-level vocalStartTime is not yet persisted by all backend versions;
        // fall back to diagnostics.analysis_log.intro_decision.candidates.vocal.
        // Keep `nil` semantics — backend (2026-05-01) confirmed vocalStartTime
        // null means "unknown / no detection" (track has instrumental intro
        // or detector failed) and 0.0 means LITERAL vocal-at-t=0. Don't
        // collapse nil to 0 here: downstream paths handle the optional.
        analysis.vocalStartTime = result.vocalStartTime ?? result.vocalStartFromDiagnostics

        if let beats = result.beats, !beats.isEmpty {
            analysis.downbeatTimes = beats
        }

        if let segments = result.speechSegments {
            analysis.speechSegments = segments.map { (start: $0.start, end: $0.end) }
        }

        // Extract chorus — prefer diagnostics chorus_structure, fall back to top-level structure.
        // Backend labels like "pre_chorus" / "pre-chorus" must be skipped: matching them as
        // "chorus" placed chorusStartTime BEFORE introEndTime in 3 of the v6 log transitions
        // (Ghost Town, WAKARIMASEN, Midnight Tokyo). Also require startTime ≥ introEnd - 2s
        // so a hook segment that the backend mislabels can't trip the heuristic.
        let chorusSource = result.chorusStructure ?? result.structure
        if let structure = chorusSource {
            let introEnd = analysis.introEndTime
            let chorus = structure.first(where: { seg in
                let label = seg.label.lowercased()
                let isChorus = label.contains("chorus")
                let isPreChorus = label.contains("pre")
                return isChorus && !isPreChorus && seg.startTime >= introEnd - 2
            }) ?? structure.first(where: { seg in
                let label = seg.label.lowercased()
                return label.contains("chorus") && !label.contains("pre")
            })
            if let chorus {
                analysis.chorusStartTime = chorus.startTime
            }
        }

        // Extract phrase boundaries from structure
        let structureSource = chorusSource ?? result.structure
        if let structure = structureSource {
            analysis.phraseBoundaries = structure.map { $0.startTime }
        }

        // Backend-calculated cue point (from diagnostics.fade_info)
        if let cue = result.cuePoint, cue > 0 && cue < duration {
            analysis.cuePoint = cue
            analysis.hasCuePoint = true
        }

        // Per-section energy profile (from diagnostics.fade_info)
        if let ep = result.energyProfile {
            analysis.energyIntro = ep.intro ?? analysis.energy
            analysis.energyMain = ep.main ?? analysis.energy
            analysis.energyOutro = ep.outro ?? analysis.energy
            analysis.hasEnergyProfile = true
            // Only set vocal flags when the backend explicitly provided them.
            // When nil, leave as false + hasVocalData=false so downstream code
            // doesn't assume "no vocals" (which would wrongly mark everything as instrumental).
            if let iv = ep.introVocals {
                analysis.hasIntroVocals = iv
                analysis.hasVocalData = true
            }
            if let ov = ep.outroVocals {
                analysis.hasOutroVocals = ov
                analysis.hasVocalData = true
            }
        }

        // Backend-suggested fade durations (from diagnostics.fade_info)
        if let fi = result.fadeInDuration, fi > 0 { analysis.backendFadeInDuration = fi }
        if let fo = result.fadeOutDuration, fo > 0 { analysis.backendFadeOutDuration = fo }
        if let fol = result.fadeOutLeadTime, fol > 0 { analysis.backendFadeOutLeadTime = fol }

        // Last vocal time — where vocals actually end (from analysis_log.Instrumental Outro)
        if let lvt = result.lastVocalTime, lvt > 0 && lvt < duration {
            analysis.lastVocalTime = lvt
            analysis.hasVocalEndData = true
        }

        // Mark whether backend provided real intro/outro data
        analysis.hasIntroData = result.introEndTime != nil
        analysis.hasOutroData = result.outroStartTime != nil

        // BPM confidence system (Essentia cross-validation)
        if let conf = result.bpmConfidence {
            analysis.bpmConfidence = conf
            analysis.hasBpmConfidence = true
        }
        analysis.bpmEssentia = result.bpmEssentia

        // ML override tracking
        analysis.modelUsed = result.modelUsed ?? false
        analysis.introEndTimeHeuristic = result.introEndHeuristic
        analysis.outroStartTimeHeuristic = result.outroStartHeuristic

        return analysis
    }

    // MARK: - Pre-fetch

    /// Pre-fetch analysis for the next N songs in the queue.
    func prefetch(songs: [PersistableSong], count: Int = 3) {
        let api = NavidromeService.shared
        for song in songs.prefix(count) {
            guard memoryCache[song.id] == nil else { continue }
            guard inFlightTasks[song.id] == nil else { continue }
            guard let streamURL = api.streamURL(songId: song.id) else { continue }

            let songId = song.id
            inFlightTasks[songId] = Task {
                let result = await fetchFromBackend(songId: songId, streamURL: streamURL)
                if let result {
                    memoryCache[songId] = result
                    saveToDisk(songId: songId, result: result)
                }
                inFlightTasks[songId] = nil
                return result
            }
        }
    }

    // MARK: - Backend Fetch

    private func fetchFromBackend(songId: String, streamURL: URL) async -> AnalysisResult? {
        let payload = BackendService.AnalysisPayload(
            streamUrl: streamURL.absoluteString,
            songId: songId,
            isProactive: true
        )

        do {
            let dict = try await BackendService.shared.analyzeSong(payload)
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try JSONDecoder().decode(AnalysisResult.self, from: data)
        } catch {
            print("[AnalysisCacheService] Fetch failed for \(songId): \(error)")
            return nil
        }
    }

    // MARK: - Cache Revalidation

    /// Stale-while-revalidate: re-fetch when cache predates a backend detector.
    /// Triggers when speechSegments are empty OR vocalStartFromDiagnostics is missing —
    /// both signal a JSON written before the v2 backend started populating those fields.
    /// Returns the stale cache immediately; the refreshed data is available on next access.
    private func revalidateCacheIfNeeded(songId: String, cached: AnalysisResult, streamURL: URL?) {
        let speechMissing = cached.speechSegments?.isEmpty != false
        let vocalStartMissing = cached.vocalStartTime == nil && cached.vocalStartFromDiagnostics == nil
        guard speechMissing || vocalStartMissing else { return }
        guard let streamURL else { return }
        guard !revalidatingIds.contains(songId), inFlightTasks[songId] == nil else { return }

        revalidatingIds.insert(songId)
        let reason = [speechMissing ? "speechSegments" : nil, vocalStartMissing ? "vocalStart" : nil]
            .compactMap { $0 }.joined(separator: "+")
        print("[AnalysisCacheService] Revalidating \(reason) for \(songId)")

        Task {
            if let fresh = await fetchFromBackend(songId: songId, streamURL: streamURL) {
                let gotSpeech = fresh.speechSegments?.isEmpty == false
                let gotVocalStart = fresh.vocalStartTime != nil || fresh.vocalStartFromDiagnostics != nil
                let improved = (speechMissing && gotSpeech) || (vocalStartMissing && gotVocalStart)
                if improved {
                    memoryCache[songId] = fresh
                    saveToDisk(songId: songId, result: fresh)
                    print("[AnalysisCacheService] ✅ Refreshed \(songId): speech=\(gotSpeech) vocalStart=\(gotVocalStart)")
                } else {
                    print("[AnalysisCacheService] \(reason) still missing for \(songId) — backend may not have backfilled yet")
                }
            }
            revalidatingIds.remove(songId)
        }
    }

    // MARK: - Invalidation

    /// Drops memory + disk cache for a single song so the next fetch hits the backend
    /// fresh. Cancels any in-flight task to avoid the cancelled fetch overwriting disk.
    func invalidate(songId: String) {
        inFlightTasks[songId]?.cancel()
        inFlightTasks[songId] = nil
        memoryCache[songId] = nil
        try? FileManager.default.removeItem(at: diskPath(songId: songId))
    }

    /// Drops every cached analysis. Useful when a backend version bump means all
    /// previous results are stale.
    func invalidateAll() {
        for (_, task) in inFlightTasks { task.cancel() }
        inFlightTasks.removeAll()
        memoryCache.removeAll()
        if let entries = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for url in entries where url.pathExtension == "json" {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Disk Cache

    private func diskPath(songId: String) -> URL {
        cacheDir.appendingPathComponent("\(songId).json")
    }

    private func loadFromDisk(songId: String) -> AnalysisResult? {
        let path = diskPath(songId: songId)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(AnalysisResult.self, from: data)
    }

    private func saveToDisk(songId: String, result: AnalysisResult) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        try? data.write(to: diskPath(songId: songId))
    }
}
