// ╔══════════════════════════════════════════════════════════════════════╗
// ║                                                                      ║
// ║   SmartMix Algorithm v3.0 — "Harmonic Flow"                          ║
// ║                                                                      ║
// ║   Audiorr — Audiophile-grade music player                            ║
// ║   Copyright (c) 2025-2026 cha0sisme (github.com/cha0sisme)          ║
// ║                                                                      ║
// ║   Intelligent playlist reordering using Camelot harmonic analysis,   ║
// ║   BPM arc shaping, energy flow optimization, vocal clash avoidance,  ║
// ║   and greedy sequencing with local 2-opt refinement.                  ║
// ║                                                                      ║
// ║   v1.0 — JS smartMixUtils.ts (basic Camelot + BPM sorting)           ║
// ║   v2.0 — Native Swift port (greedy + swap optimization)              ║
// ║   v3.0 — Harmonic Flow: harmonicBPM, energy boost key jumps,         ║
// ║          smooth energy valley detection, vocal trainwreck scoring,    ║
// ║          closing song selection, BPM arc shaping, robust caching,    ║
// ║          balanced scoring weights, efficient 2-opt with windowing    ║
// ║                                                                      ║
// ╚══════════════════════════════════════════════════════════════════════╝

import Foundation
import CryptoKit

/// SmartMix v3.0 "Harmonic Flow" — intelligent playlist reordering for optimal DJ flow.
/// Analyzes songs via Audiorr Backend, sorts them using harmonic compatibility,
/// energy arc shaping, BPM progression, and vocal clash avoidance.
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

    // MARK: - SmartMix Sorting Algorithm

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

        // 2. Choose closing song: gentle energy, comfortable BPM, good outro
        let closeIdx = bestClosingIndex(unmixed)
        let closingSong = unmixed.remove(at: closeIdx)

        // 3. Greedy phase with memory
        while !unmixed.isEmpty {
            var bestIdx = 0
            var bestScore = Double.infinity
            let forceDiversity = mixed.count > 0 && mixed.count % 5 == 0

            for i in 0..<unmixed.count {
                var score = compatibility(mixed.last!, unmixed[i], history: mixed, position: mixed.count, total: valid.count)
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

        // 4. Append closing song
        mixed.append(closingSong)

        // 5. Optimization pass (swap search — skip first and last)
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
            let bpm = ana.bpm ?? 120
            if bpm >= 80 && bpm <= 120 { score += 5 }
            if bpm >= 90 && bpm <= 110 { score += 3 }

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

    // MARK: - Closing Song Selection (#6)

    /// Picks the best song to end the set: low energy, gentle outro, comfortable BPM.
    private func bestClosingIndex(_ songs: [AnalyzedSong]) -> Int {
        var bestIdx = 0
        var bestScore = -Double.infinity

        for (i, song) in songs.enumerated() {
            guard let ana = song.analysis else { continue }
            var score: Double = 0

            let energy = ana.energy ?? 0.5
            let bpm = ana.bpm ?? 120

            // Prefer low energy
            if energy < 0.40 { score += 8 }
            if energy < 0.55 { score += 4 }
            if energy > 0.80 { score -= 20 }

            // Comfortable/slow BPM
            if bpm >= 70 && bpm <= 110 { score += 5 }
            if bpm < 90 { score += 3 }

            // Low danceability is fine for closing
            let dance = ana.danceability ?? 0.5
            if dance < 0.50 { score += 3 }

            // Good outro (energy fades out)
            if let profile = ana.energyProfile {
                let outro = profile.outro ?? 0.5
                if outro < 0.40 { score += 6 }
                if let slope = profile.outroSlope, slope < -0.03 { score += 5 }
                // Avoid songs with vocals at the very end (awkward cut)
                if profile.outroVocals == true { score -= 4 }
            }

            if score > bestScore {
                bestScore = score
                bestIdx = i
            }
        }
        return bestIdx
    }

    // MARK: - Compatibility Score

    private func compatibility(_ a: AnalyzedSong, _ b: AnalyzedSong, history: [AnalyzedSong],
                               position: Int = 0, total: Int = 0) -> Double {
        guard let anaA = a.analysis, let anaB = b.analysis else { return .infinity }

        let bpmA = anaA.bpm ?? 120
        let bpmB = anaB.bpm ?? 120
        let energyA = anaA.energy ?? 0.5
        let energyB = anaB.energy ?? 0.5

        // ── Key penalty ──
        let keyA = Self.camelotKey(anaA.key)
        let keyB = Self.camelotKey(anaB.key)
        var keyPenalty: Double = 15
        if let kA = keyA, let kB = keyB {
            keyPenalty = Self.camelotDistanceWeighted(kA, kB, energyA: energyA, energyB: energyB)
        }

        // Key fatigue: penalize repeating the same key 3+ times in recent history
        var keyFatiguePenalty: Double = 0
        if history.count >= 3, let kB = keyB {
            let recentKeys = history.suffix(3).compactMap { Self.camelotKey($0.analysis?.key) }
            if recentKeys.filter({ $0 == kB }).count >= 2 { keyFatiguePenalty = 8 }
        }

        // ── BPM penalty — uses harmonicBPM for half/double tempo detection (#1) ──
        let harmonicB = DJMixingService.harmonicBPM(bpmA, bpmB)
        let bpmDiff = abs(bpmA - harmonicB)
        let bpmPenalty = pow(bpmDiff, 1.4) / 8

        // ── Energy penalty — smooth gradient, no cliff (#3) ──
        let energyDiff = abs(energyA - energyB)
        var energyPenalty = pow(energyDiff, 2) * 15
        // Progressive energy valley penalty: the lower both are, the bigger the penalty
        let minEnergy = min(energyA, energyB)
        if minEnergy < 0.45 {
            // 0.44 → small penalty, 0.20 → big penalty (smooth ramp)
            energyPenalty += pow(0.45 - minEnergy, 1.5) * 60
        }

        // ── Transition penalty — vocal clash detection (#4) ──
        var transitionPenalty: Double = 12
        if let profA = anaA.energyProfile, let profB = anaB.energyProfile {
            let outroA = profA.outro ?? 0.5
            let introB = profB.intro ?? 0.5
            let profileDiff = abs(outroA - introB)
            transitionPenalty = pow(profileDiff, 2) * 40

            // Bonus for natural energy flow (A descending → B ascending)
            if let slopeA = profA.outroSlope, let slopeB = profB.introSlope {
                if slopeA < -0.05 && slopeB > 0.05 { transitionPenalty -= 8 }
            }

            // Vocal trainwreck: graduated penalty based on vocal overlap risk
            let outroVocals = profA.outroVocals == true
            let introVocals = profB.introVocals == true
            if outroVocals && introVocals {
                transitionPenalty += 18  // high risk — both have vocals at transition point
            } else if outroVocals || introVocals {
                transitionPenalty += 5   // moderate risk — one side has vocals
            }
        }

        // ── Artist penalty — normalized to same scale as other penalties (#2) ──
        var artistPenalty: Double = 0
        if a.song.artist == b.song.artist {
            artistPenalty = 10
        } else {
            let recent = history.suffix(4).reversed()
            if let idx = recent.firstIndex(where: { $0.song.artist == b.song.artist }) {
                let dist = recent.distance(from: recent.startIndex, to: idx)
                artistPenalty = max(0, 6 - Double(dist * 2))
            }
        }

        // ── Danceability penalty ──
        let danceDiff = abs((anaA.danceability ?? 0.5) - (anaB.danceability ?? 0.5))
        let dancePenalty = pow(danceDiff, 2) * 15

        // ── BPM arc penalty — favor gradual BPM progression (#10) ──
        var bpmArcPenalty: Double = 0
        if total > 4 && position > 0 {
            let progress = Double(position) / Double(total)
            // Ideal BPM arc: start moderate, peak at 60-70%, descend
            let idealBpmFactor: Double
            if progress < 0.15 {
                idealBpmFactor = 0.4  // start moderate
            } else if progress < 0.65 {
                idealBpmFactor = 0.3 + progress  // ramp up
            } else {
                idealBpmFactor = max(0.3, 1.0 - (progress - 0.65) * 1.5)  // descend
            }
            // Penalize large BPM deviations from the arc's expected direction
            if history.count >= 2 {
                let prevBpm = history.last!.bpm
                let bpmDirection = harmonicB - prevBpm
                // In the ascending phase, penalize going slower
                if progress < 0.6 && bpmDirection < -8 {
                    bpmArcPenalty = abs(bpmDirection) * 0.3 * idealBpmFactor
                }
                // In the descending phase, penalize going much faster
                if progress > 0.75 && bpmDirection > 10 {
                    bpmArcPenalty = bpmDirection * 0.4 * (1.0 - idealBpmFactor)
                }
            }
        }

        // ── Weighted sum — all penalties are on comparable scales (#2) ──
        return keyPenalty * 3.5
             + bpmPenalty * 2.0
             + energyPenalty * 1.2
             + transitionPenalty * 2.0
             + artistPenalty * 1.5
             + keyFatiguePenalty
             + dancePenalty * 0.8
             + bpmArcPenalty
    }

    // MARK: - Swap Optimization (#5 — limited 2-opt for efficiency)

    private func optimizeSequence(_ songs: [AnalyzedSong]) -> [AnalyzedSong] {
        var result = songs
        let n = result.count
        var improved = true
        var passes = 0

        // Skip index 0 (starting song) and n-1 (closing song) — those are pinned
        let lo = 1
        let hi = n - 2

        while improved && passes < 3 {
            improved = false
            for i in lo...hi {
                // Limit inner search window to ±20 positions for large playlists
                let jStart = i + 1
                let jEnd = min(hi, i + 20)
                guard jStart <= jEnd else { continue }

                for j in jStart...jEnd {
                    let currentCost: Double
                    let newCost: Double

                    if j == i + 1 {
                        currentCost = pairCost(result[i-1], result[i])
                            + pairCost(result[i], result[j])
                            + pairCost(result[j], result[j+1])
                        newCost = pairCost(result[i-1], result[j])
                            + pairCost(result[j], result[i])
                            + pairCost(result[i], result[j+1])
                    } else {
                        currentCost = pairCost(result[i-1], result[i])
                            + pairCost(result[i], result[i+1])
                            + pairCost(result[j-1], result[j])
                            + pairCost(result[j], result[j+1])
                        newCost = pairCost(result[i-1], result[j])
                            + pairCost(result[j], result[i+1])
                            + pairCost(result[j-1], result[i])
                            + pairCost(result[i], result[j+1])
                    }

                    // Energy + BPM arc influence
                    let arcDelta = (Self.arcPenalty(result[j], j, n) + Self.arcPenalty(result[i], i, n))
                        - (Self.arcPenalty(result[i], i, n) + Self.arcPenalty(result[j], j, n))
                    let bpmArcDelta = (Self.bpmArcPenalty(result[j], j, n) + Self.bpmArcPenalty(result[i], i, n))
                        - (Self.bpmArcPenalty(result[i], i, n) + Self.bpmArcPenalty(result[j], j, n))

                    if newCost + (arcDelta + bpmArcDelta) * 1.5 < currentCost {
                        result.swapAt(i, j)
                        improved = true
                    }
                }
            }
            passes += 1
        }
        return result
    }

    /// Simplified pair cost for optimization pass (no history context needed).
    private func pairCost(_ a: AnalyzedSong, _ b: AnalyzedSong) -> Double {
        compatibility(a, b, history: [])
    }

    // MARK: - Energy Arc

    private static func arcPenalty(_ song: AnalyzedSong, _ index: Int, _ total: Int) -> Double {
        let energy = song.energy
        let progress = Double(index) / Double(total)
        var penalty: Double = 0
        if progress < 0.15 {
            // Opening: penalize high energy starts
            if energy > 0.75 { penalty += 15 }
        } else if progress < 0.7 {
            // Build-up/plateau: penalize very low energy
            if energy < 0.30 { penalty += 12 }
        } else {
            // Closing: penalize very high energy
            if energy > 0.80 { penalty += 15 }
            // Reward gentle closing
            if energy < 0.45 { penalty -= 3 }
        }
        return penalty
    }

    // MARK: - BPM Arc (#10)

    private static func bpmArcPenalty(_ song: AnalyzedSong, _ index: Int, _ total: Int) -> Double {
        let bpm = song.bpm
        let progress = Double(index) / Double(total)
        var penalty: Double = 0

        if progress < 0.15 {
            // Opening: penalize very fast BPMs
            if bpm > 140 { penalty += 8 }
        } else if progress > 0.8 {
            // Closing: penalize very fast BPMs
            if bpm > 135 { penalty += 10 }
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

    /// Camelot distance with energy boost recognition (#7).
    /// A +7 semitone jump (e.g. 5B→12B) is a valid energy boost move in DJ sets,
    /// so it gets a reduced penalty when energy is rising.
    private static func camelotDistanceWeighted(_ a: String, _ b: String,
                                                 energyA: Double, energyB: Double) -> Double {
        guard a.count >= 2, b.count >= 2 else { return 15 }
        let numA = Int(a.dropLast()) ?? 0
        let modeA = a.last!
        let numB = Int(b.dropLast()) ?? 0
        let modeB = b.last!

        if a == b { return 0 }
        if numA == numB { return 1 }  // same number, different mode = relative major/minor

        var diff = abs(numA - numB)
        if diff > 6 { diff = 12 - diff }
        if modeA != modeB { diff += 1 }

        // Energy boost: +7 semitone jump (diff=5 after wrapping) is a valid DJ move
        // when transitioning to higher energy. Reduce penalty.
        let rawDiff = abs(numA - numB)
        let wrappedDiff = min(rawDiff, 12 - rawDiff)
        if wrappedDiff >= 5 && wrappedDiff <= 7 && modeA == modeB && energyB > energyA + 0.1 {
            return Double(diff) * 0.6  // 40% discount for energy boost moves
        }

        return Double(diff)
    }

    /// Legacy distance (unweighted) for cases where energy context isn't available.
    private static func camelotDistance(_ a: String, _ b: String) -> Int {
        guard a.count >= 2, b.count >= 2 else { return 15 }
        let keyA = Int(a.dropLast()) ?? 0
        let keyB = Int(b.dropLast()) ?? 0
        let modeA = a.last!
        let modeB = b.last!

        if a == b { return 0 }
        if keyA == keyB { return 1 }

        var diff = abs(keyA - keyB)
        if diff > 6 { diff = 12 - diff }
        if modeA != modeB { diff += 1 }
        return diff
    }

    // MARK: - Cache Signature (#9 — robust hash of all song IDs)

    private static func signature(_ songs: [NavidromeSong]) -> String {
        guard !songs.isEmpty else { return "empty" }
        // Hash all song IDs so any change (add, remove, reorder) invalidates cache
        let combined = songs.map(\.id).joined(separator: ",")
        let digest = Insecure.MD5.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
