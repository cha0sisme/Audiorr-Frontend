import Foundation

/// Native SmartMix manager — replaces JS SmartMix logic from PlayerContext.tsx + smartMixUtils.ts.
/// Analyzes playlist songs, sorts them for optimal DJ flow, caches results.
@MainActor @Observable
final class SmartMixManager {

    static let shared = SmartMixManager()

    // MARK: - State

    enum Status: String { case idle, analyzing, ready, error }

    private(set) var status: Status = .idle
    private(set) var playlistId: String?
    private(set) var generatedMix: [NavidromeSong] = []
    private(set) var progress: (analyzed: Int, total: Int) = (0, 0)

    // MARK: - Private

    private let api = NavidromeService.shared
    private let backend = BackendService.shared
    private var currentTask: Task<Void, Never>?

    // Cache: playlistId+signature → sorted songs
    private var cache: [String: [NavidromeSong]] = [:]

    private init() {}

    // MARK: - Generate

    /// Generate a SmartMix for the given playlist songs.
    func generate(playlistId: String, songs: [NavidromeSong]) {
        currentTask?.cancel()
        self.playlistId = playlistId
        status = .analyzing
        generatedMix = []
        progress = (0, songs.count)

        let signature = Self.signature(songs)
        let cacheKey = "\(playlistId)_\(signature)"

        // Check cache
        if let cached = cache[cacheKey] {
            generatedMix = cached
            status = .ready
            return
        }

        currentTask = Task {
            do {
                let sorted = try await analyzeAndSort(songs: songs)
                guard !Task.isCancelled else { return }

                generatedMix = sorted
                status = .ready
                cache[cacheKey] = sorted

                // Update PlayerService for UI compatibility
                PlayerService.shared.updateSmartMixStatus(playlistId: playlistId, status: "ready")
            } catch {
                guard !Task.isCancelled else { return }
                status = .error
                print("[SmartMixManager] Error: \(error)")
                PlayerService.shared.updateSmartMixStatus(playlistId: playlistId, status: "error")
            }
        }
    }

    /// Play the generated SmartMix.
    func playGenerated() {
        guard !generatedMix.isEmpty else { return }
        QueueManager.shared.play(songs: generatedMix, startIndex: 0)
    }

    func clear() {
        currentTask?.cancel()
        status = .idle
        playlistId = nil
        generatedMix = []
    }

    // MARK: - Analysis + Sorting

    private func analyzeAndSort(songs: [NavidromeSong]) async throws -> [NavidromeSong] {
        // 1. Bulk check which songs already have analysis in backend
        let songIds = songs.map { $0.id }
        var analysisMap: [String: AnalysisCacheService.AnalysisResult] = [:]

        // Try bulk status first
        do {
            let bulkResults = try await backend.getBulkAnalysisStatus(songIds: songIds)
            for (id, value) in bulkResults {
                if let dict = value as? [String: Any],
                   let data = try? JSONSerialization.data(withJSONObject: dict),
                   let result = try? JSONDecoder().decode(AnalysisCacheService.AnalysisResult.self, from: data) {
                    analysisMap[id] = result
                }
            }
        } catch {
            print("[SmartMixManager] Bulk status failed: \(error)")
        }

        // 2. Analyze missing songs
        let missing = songs.filter { analysisMap[$0.id] == nil }
        var analyzed = analysisMap.count

        for song in missing {
            guard !Task.isCancelled else { throw CancellationError() }
            guard let streamURL = api.streamURL(songId: song.id) else { continue }

            if let result = await AnalysisCacheService.shared.getAnalysis(
                songId: song.id, streamURL: streamURL
            ) {
                analysisMap[song.id] = result
            }

            analyzed += 1
            progress = (analyzed, songs.count)
        }

        // 3. Sort using SmartMix algorithm
        return sortSongs(songs: songs, analysisMap: analysisMap)
    }

    // MARK: - SmartMix Sorting Algorithm (port of smartMixUtils.ts)

    private struct AnalyzedSong {
        let song: NavidromeSong
        let analysis: AnalysisCacheService.AnalysisResult?

        var bpm: Double { analysis?.bpm ?? 120 }
        var energy: Double { analysis?.energy ?? 0.5 }
        var key: String? { analysis?.key }
        var danceability: Double { analysis?.danceability ?? 0.5 }
    }

    private func sortSongs(songs: [NavidromeSong], analysisMap: [String: AnalysisCacheService.AnalysisResult]) -> [NavidromeSong] {
        guard songs.count >= 2 else { return songs }

        let analyzed = songs.map { AnalyzedSong(song: $0, analysis: analysisMap[$0.id]) }
        let valid = analyzed.filter { $0.analysis != nil }
        let invalid = analyzed.filter { $0.analysis == nil }

        guard valid.count >= 2 else { return (valid + invalid).map(\.song) }

        var unmixed = valid
        var mixed: [AnalyzedSong] = []

        // 1. Choose starting song: moderate energy, gentle intro, comfortable BPM
        let startIdx = bestStartingIndex(unmixed)
        mixed.append(unmixed.remove(at: startIdx))

        // 2. Greedy phase with memory
        while !unmixed.isEmpty {
            var bestIdx = 0
            var bestScore = Double.infinity
            let forceDiversity = mixed.count > 0 && mixed.count % 5 == 0

            for i in 0..<unmixed.count {
                var score = compatibility(mixed.last!, unmixed[i], history: mixed)
                if forceDiversity && mixed.count >= 2 {
                    let recentKeys = mixed.suffix(3).compactMap(\.key)
                    if let candidateKey = unmixed[i].key, recentKeys.contains(candidateKey) {
                        score += 12
                    }
                }
                if score < bestScore {
                    bestScore = score
                    bestIdx = i
                }
            }
            mixed.append(unmixed.remove(at: bestIdx))
        }

        // 3. Optimization pass (swap search)
        let optimized = mixed.count > 4 && mixed.count < 500 ? optimizeSequence(mixed) : mixed

        return (optimized + invalid).map(\.song)
    }

    // MARK: - Starting Song Selection

    private func bestStartingIndex(_ songs: [AnalyzedSong]) -> Int {
        var bestIdx = 0
        var bestScore = -Double.infinity

        for (i, song) in songs.enumerated() {
            guard let ana = song.analysis else { continue }
            var score: Double = 0

            // Comfortable BPM
            if ana.bpm ?? 120 >= 80 && ana.bpm ?? 120 <= 120 { score += 5 }
            if ana.bpm ?? 120 >= 90 && ana.bpm ?? 120 <= 110 { score += 3 }

            // Moderate energy
            let energy = ana.energy ?? 0.5
            if energy < 0.45 { score += 4 }
            if energy > 0.85 { score -= 25 }

            // Moderate danceability
            let dance = ana.danceability ?? 0.5
            if dance >= 0.35 && dance <= 0.70 { score += 3 }

            // Energy profile
            if let profile = ana.energyProfile {
                let intro = profile.intro ?? 0.5
                let main = profile.main ?? 0.5
                if intro < 0.40 { score += 5 }
                if intro < main { score += (main - intro) * 12 }
                if intro < 0.30 && main > 0.65 { score += 20 }
                if let slope = profile.introSlope, slope > 0.05 { score += 4 }
            }

            if score > bestScore {
                bestScore = score
                bestIdx = i
            }
        }
        return bestIdx
    }

    // MARK: - Compatibility Score

    private func compatibility(_ a: AnalyzedSong, _ b: AnalyzedSong, history: [AnalyzedSong]) -> Double {
        guard let anaA = a.analysis, let anaB = b.analysis else { return .infinity }

        // Key penalty (~40%)
        let keyA = Self.camelotKey(anaA.key)
        let keyB = Self.camelotKey(anaB.key)
        var keyPenalty: Double = 15
        if let kA = keyA, let kB = keyB {
            keyPenalty = Double(Self.camelotDistance(kA, kB))
        }

        // Key fatigue
        var keyFatiguePenalty: Double = 0
        if history.count >= 3, let kB = keyB {
            let recentKeys = history.suffix(3).compactMap { Self.camelotKey($0.analysis?.key) }
            if recentKeys.filter({ $0 == kB }).count >= 2 { keyFatiguePenalty = 8 }
        }

        // BPM penalty (~20%)
        let bpmDiff = abs((anaA.bpm ?? 120) - (anaB.bpm ?? 120))
        let bpmPenalty = pow(bpmDiff, 1.4) / 8

        // Energy penalty (~7%)
        let energyDiff = abs((anaA.energy ?? 0.5) - (anaB.energy ?? 0.5))
        var energyPenalty = pow(energyDiff, 2) * 15
        if (anaA.energy ?? 0.5) < 0.35 && (anaB.energy ?? 0.5) < 0.35 {
            energyPenalty += 15
        }

        // Transition penalty (~23%)
        var transitionPenalty: Double = 12
        if let profA = anaA.energyProfile, let profB = anaB.energyProfile {
            let outroA = profA.outro ?? 0.5
            let introB = profB.intro ?? 0.5
            let profileDiff = abs(outroA - introB)
            transitionPenalty = pow(profileDiff, 2) * 40

            if let slopeA = profA.outroSlope, let slopeB = profB.introSlope {
                if slopeA < -0.05 && slopeB > 0.05 { transitionPenalty -= 8 }
            }
            if profA.outroVocals == true && profB.introVocals == true {
                transitionPenalty += 12
            }
        }

        // Artist penalty
        var artistPenalty: Double = 0
        if a.song.artist == b.song.artist {
            artistPenalty = 15
        } else {
            let recent = history.suffix(4).reversed()
            if let idx = recent.firstIndex(where: { $0.song.artist == b.song.artist }) {
                let dist = recent.distance(from: recent.startIndex, to: idx)
                artistPenalty = max(0, 10 - Double(dist * 2))
            }
        }

        // Danceability penalty (~10%)
        let danceDiff = abs((anaA.danceability ?? 0.5) - (anaB.danceability ?? 0.5))
        let dancePenalty = pow(danceDiff, 2) * 15

        return (keyPenalty * 0.40) + (bpmPenalty * 0.20) + (energyPenalty * 0.07)
             + (transitionPenalty * 0.23) + artistPenalty + keyFatiguePenalty + dancePenalty
    }

    // MARK: - Swap Optimization

    private func optimizeSequence(_ songs: [AnalyzedSong]) -> [AnalyzedSong] {
        var result = songs
        let n = result.count
        var improved = true
        var passes = 0

        while improved && passes < 3 {
            improved = false
            for i in 1..<(n - 1) {
                for j in (i + 1)..<(n - 1) {
                    let currentCost: Double
                    let newCost: Double

                    if j == i + 1 {
                        currentCost = compatibility(result[i-1], result[i], history: [])
                            + compatibility(result[i], result[j], history: [])
                            + compatibility(result[j], result[j+1], history: [])
                        newCost = compatibility(result[i-1], result[j], history: [])
                            + compatibility(result[j], result[i], history: [])
                            + compatibility(result[i], result[j+1], history: [])
                    } else {
                        currentCost = compatibility(result[i-1], result[i], history: [])
                            + compatibility(result[i], result[i+1], history: [])
                            + compatibility(result[j-1], result[j], history: [])
                            + compatibility(result[j], result[j+1], history: [])
                        newCost = compatibility(result[i-1], result[j], history: [])
                            + compatibility(result[j], result[i+1], history: [])
                            + compatibility(result[j-1], result[i], history: [])
                            + compatibility(result[i], result[j+1], history: [])
                    }

                    // Energy arc influence
                    let eI = result[i].energy
                    let eJ = result[j].energy
                    let arcDelta = (Self.arcPenalty(eJ, i, n) + Self.arcPenalty(eI, j, n))
                        - (Self.arcPenalty(eI, i, n) + Self.arcPenalty(eJ, j, n))

                    if newCost + (arcDelta * 1.5) < currentCost {
                        result.swapAt(i, j)
                        improved = true
                    }
                }
            }
            passes += 1
        }
        return result
    }

    // MARK: - Energy Arc

    private static func arcPenalty(_ energy: Double, _ index: Int, _ total: Int) -> Double {
        let progress = Double(index) / Double(total)
        var penalty: Double = 0
        if progress < 0.7 {
            if progress < 0.2 && energy > 0.8 { penalty += 15 }
            if progress > 0.2 && energy < 0.35 { penalty += 10 }
        } else {
            if energy > 0.85 { penalty += 12 }
        }
        return penalty
    }

    // MARK: - Camelot Key Helpers

    private static let keyToCamelot: [String: String] = [
        "B": "1B", "F#": "2B", "C#": "3B", "G#": "4B", "D#": "5B", "A#": "6B",
        "F": "7B", "C": "8B", "G": "9B", "D": "10B", "A": "11B", "E": "12B",
        "G#m": "1A", "D#m": "2A", "A#m": "3A", "Fm": "4A", "Cm": "5A", "Gm": "6A",
        "Dm": "7A", "Am": "8A", "Em": "9A", "Bm": "10A", "F#m": "11A", "C#m": "12A",
        "Gb": "2B", "Db": "3B", "Ab": "4B", "Eb": "5B", "Bb": "6B",
        "Ebm": "2A", "Bbm": "3A",
    ]

    private static func camelotKey(_ key: String?) -> String? {
        guard let key else { return nil }
        return keyToCamelot[key]
    }

    private static func camelotDistance(_ a: String, _ b: String) -> Int {
        guard a.count >= 2, b.count >= 2 else { return 15 }
        let keyA = Int(a.dropLast()) ?? 0
        let modeA = a.last!
        let keyB = Int(b.dropLast()) ?? 0
        let modeB = b.last!

        if a == b { return 0 }
        if keyA == keyB { return 1 }

        var diff = abs(keyA - keyB)
        if diff > 6 { diff = 12 - diff }
        if modeA != modeB { diff += 1 }
        return diff
    }

    private static func signature(_ songs: [NavidromeSong]) -> String {
        guard !songs.isEmpty else { return "empty" }
        let mid = songs[songs.count / 2]
        return "\(songs.count)_\(songs.first!.id)_\(mid.id)_\(songs.last!.id)"
    }
}
