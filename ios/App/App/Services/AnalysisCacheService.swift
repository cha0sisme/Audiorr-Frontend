import Foundation

/// Caches audio analysis results for crossfade intelligence.
/// Fetches from Audiorr backend, caches in memory + disk (Caches directory).
/// Pre-fetches analysis for upcoming songs in the queue.
actor AnalysisCacheService {

    static let shared = AnalysisCacheService()

    // MARK: - Types

    /// Full analysis result from the backend — maps to AudioAnalysisResult in JS.
    struct AnalysisResult: Codable {
        let bpm: Double?
        let beats: [Double]?
        let beatInterval: Double?
        let energy: Double?
        let key: String?
        let danceability: Double?
        let outroStartTime: Double?
        let introEndTime: Double?
        let vocalStartTime: Double?
        let fadeInDuration: Double?
        let fadeOutDuration: Double?
        let cuePoint: Double?
        let fadeOutLeadTime: Double?
        let energyProfile: EnergyProfile?
        let speechSegments: [SpeechSegment]?
        let structure: [StructureSegment]?

        struct EnergyProfile: Codable {
            let intro: Double?
            let main: Double?
            let outro: Double?
            let outroSlope: Double?
            let introSlope: Double?
            let outroVocals: Bool?
            let introVocals: Bool?
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

        // Extract chorus start from structure
        if let structure = result.structure,
           let chorus = structure.first(where: { $0.label.lowercased().contains("chorus") }) {
            analysis.chorusStartTime = chorus.startTime
        }

        // Extract phrase boundaries from structure
        if let structure = result.structure {
            analysis.phraseBoundaries = structure.map { $0.startTime }
        }

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
