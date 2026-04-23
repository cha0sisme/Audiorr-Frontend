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

    /// Get analysis for a song, fetching from backend if not cached.
    func getAnalysis(songId: String, streamURL: URL?) async -> AnalysisResult? {
        // Memory cache
        if let cached = memoryCache[songId] {
            return cached
        }

        // Disk cache
        if let disk = loadFromDisk(songId: songId) {
            memoryCache[songId] = disk
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
        analysis.vocalStartTime = result.vocalStartTime ?? 0

        if let beats = result.beats, !beats.isEmpty {
            analysis.downbeatTimes = beats
        }

        if let segments = result.speechSegments {
            analysis.speechSegments = segments.map { (start: $0.start, end: $0.end) }
        }

        // Extract chorus — prefer diagnostics chorus_structure, fall back to top-level structure
        let chorusSource = result.chorusStructure ?? result.structure
        if let structure = chorusSource,
           let chorus = structure.first(where: { $0.label.lowercased().contains("chorus") }) {
            analysis.chorusStartTime = chorus.startTime
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
