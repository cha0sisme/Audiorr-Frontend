// ╔══════════════════════════════════════════════════════════════════════╗
// ║                                                                      ║
// ║   SmartMix Algorithm v4.0 — "Deep Flow"                              ║
// ║                                                                      ║
// ║   Audiorr — Audiophile-grade music player                            ║
// ║   Copyright (c) 2025-2026 cha0sisme (github.com/cha0sisme)          ║
// ║                                                                      ║
// ║   Transition-quality-aware playlist reordering using DJMixingService  ║
// ║   grade analysis: multi-layer vocal clash detection (speechSegments   ║
// ║   fallback chain), BPM confidence gating, structural compatibility   ║
// ║   (instrumental intro/outro pairing), style affinity scoring,         ║
// ║   Essentia BPM cross-validation, cuePoint/fade-aware estimation.     ║
// ║                                                                      ║
// ║   v1.0 — JS smartMixUtils.ts (basic Camelot + BPM sorting)           ║
// ║   v2.0 — Native Swift port (greedy + swap optimization)              ║
// ║   v3.0 — Harmonic Flow: harmonicBPM, energy boost, vocal scoring     ║
// ║   v4.0 — Deep Flow: full backend analysis, structural compatibility, ║
// ║          multi-layer vocal clash, BPM confidence, style affinity      ║
// ║                                                                      ║
// ╚══════════════════════════════════════════════════════════════════════╝

import Foundation
import CryptoKit

/// SmartMix v4.0 "Deep Flow" — transition-quality-aware playlist reordering.
/// Analyzes songs via Audiorr Backend, sorts them using the full analysis data
/// that DJMixingService uses for crossfade decisions: harmonic compatibility,
/// structural intro/outro pairing, multi-layer vocal clash detection,
/// BPM confidence gating, style affinity, and energy arc shaping.
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
        let cacheKey = "\(playlistId)_v4_\(signature)"

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

        // ── Core (v3.0) ──
        var bpm: Double { analysis?.bpm ?? 120 }
        var energy: Double { analysis?.energy ?? 0.5 }
        var key: String? { analysis?.key }
        var danceability: Double { analysis?.danceability ?? 0.5 }

        // ── Energy profile (3-part) ──
        var energyProfile: AnalysisCacheService.AnalysisResult.EnergyProfile? { analysis?.energyProfile }
        var energyIntro: Double { energyProfile?.intro ?? energy }
        var energyMain: Double { energyProfile?.main ?? energy }
        var energyOutro: Double { energyProfile?.outro ?? energy }
        var hasOutroVocals: Bool { energyProfile?.outroVocals ?? false }
        var hasIntroVocals: Bool { energyProfile?.introVocals ?? false }

        // ── Structural boundaries ──
        var outroStartTime: Double? { analysis?.outroStartTime }
        var introEndTime: Double? { analysis?.introEndTime }
        var duration: Double { song.duration ?? 240 }

        // ── Vocal timing ──
        var vocalStartTime: Double? { analysis?.vocalStartTime }
        var lastVocalTime: Double? { analysis?.lastVocalTime }
        var speechSegments: [AnalysisCacheService.AnalysisResult.SpeechSegment] { analysis?.speechSegments ?? [] }

        // ── Transition quality ──
        var cuePoint: Double? { analysis?.cuePoint }
        var fadeInDuration: Double? { analysis?.fadeInDuration }
        var fadeOutDuration: Double? { analysis?.fadeOutDuration }

        // ── BPM confidence ──
        var bpmConfidence: Double { analysis?.bpmConfidence ?? 1.0 }
        var bpmEssentia: Double? { analysis?.bpmEssentia }

        // ── Structure ──
        var chorusStructure: [AnalysisCacheService.AnalysisResult.StructureSegment]? { analysis?.chorusStructure ?? analysis?.structure }

        // ── Pre-computed: instrumental lengths (cached for hot loop performance) ──
        let cachedInstrumentalOutro: Double
        let cachedInstrumentalIntro: Double

        init(song: NavidromeSong, analysis: AnalysisCacheService.AnalysisResult?) {
            self.song = song
            self.analysis = analysis
            let dur = song.duration ?? 240

            // Instrumental outro length
            if let lvt = analysis?.lastVocalTime, lvt > 0 {
                cachedInstrumentalOutro = max(0, dur - lvt)
            } else if analysis?.energyProfile?.outroVocals == true {
                cachedInstrumentalOutro = 0
            } else if let outro = analysis?.outroStartTime, outro > 0 {
                cachedInstrumentalOutro = dur - outro
            } else {
                cachedInstrumentalOutro = 15 // unknown, assume moderate
            }

            // Instrumental intro length
            if analysis?.energyProfile?.introVocals == true {
                cachedInstrumentalIntro = 0
            } else if let vs = analysis?.vocalStartTime, vs > 0 {
                cachedInstrumentalIntro = vs
            } else if let segs = analysis?.speechSegments, let first = segs.first {
                cachedInstrumentalIntro = first.start
            } else if let introEnd = analysis?.introEndTime, introEnd > 0 {
                cachedInstrumentalIntro = introEnd
            } else {
                cachedInstrumentalIntro = 10 // unknown, assume moderate
            }
        }
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
            guard song.analysis != nil else { continue }
            var score: Double = 0

            // Comfortable BPM
            let bpm = song.bpm
            if bpm >= 80 && bpm <= 120 { score += 5 }
            if bpm >= 90 && bpm <= 110 { score += 3 }

            // Moderate energy
            if song.energy < 0.45 { score += 4 }
            if song.energy > 0.85 { score -= 25 }

            // Moderate danceability
            if song.danceability >= 0.35 && song.danceability <= 0.70 { score += 3 }

            // Energy profile: gentle intro that builds
            if let profile = song.energyProfile {
                let intro = profile.intro ?? 0.5
                let main = profile.main ?? 0.5
                if intro < 0.40 { score += 5 }
                if intro < main { score += (main - intro) * 12 }
                if intro < 0.30 && main > 0.65 { score += 20 }
                if let slope = profile.introSlope, slope > 0.05 { score += 4 }
            }

            // v4.0: Instrumental intro — good opener has space to breathe
            if song.cachedInstrumentalIntro > 12 { score += 6 }
            else if song.cachedInstrumentalIntro > 6 { score += 3 }

            // v4.0: BPM confidence — reliable BPM for building the arc
            if song.bpmConfidence >= 0.7 { score += 3 }

            // v4.0: Structural intro section
            if let structure = song.chorusStructure,
               let introSeg = structure.first(where: { $0.label.lowercased().contains("intro") }) {
                let introLength = introSeg.endTime - introSeg.startTime
                if introLength > 10 { score += 5 }
            }

            if score > bestScore {
                bestScore = score
                bestIdx = i
            }
        }
        return bestIdx
    }

    // MARK: - Closing Song Selection

    private func bestClosingIndex(_ songs: [AnalyzedSong]) -> Int {
        var bestIdx = 0
        var bestScore = -Double.infinity

        for (i, song) in songs.enumerated() {
            guard song.analysis != nil else { continue }
            var score: Double = 0

            // Prefer low energy
            if song.energy < 0.40 { score += 8 }
            if song.energy < 0.55 { score += 4 }
            if song.energy > 0.80 { score -= 20 }

            // Comfortable/slow BPM
            if song.bpm >= 70 && song.bpm <= 110 { score += 5 }
            if song.bpm < 90 { score += 3 }

            // Low danceability is fine for closing
            if song.danceability < 0.50 { score += 3 }

            // Good outro (energy fades out)
            if let profile = song.energyProfile {
                let outro = profile.outro ?? 0.5
                if outro < 0.40 { score += 6 }
                if let slope = profile.outroSlope, slope < -0.03 { score += 5 }
            }

            // v4.0: Precise instrumental outro detection
            let outroLen = song.cachedInstrumentalOutro
            if outroLen > 20 { score += 8 }
            else if outroLen > 10 { score += 5 }
            else if outroLen < 3 { score -= 6 }

            // v4.0: Natural fade-out
            if let fadeOut = song.fadeOutDuration, fadeOut > 5 { score += 4 }

            // v4.0: Precise vocal end vs coarse boolean
            if let lvt = song.lastVocalTime {
                if lvt < song.duration - 20 { score += 6 }
            } else if song.hasOutroVocals {
                score -= 4
            }

            if score > bestScore {
                bestScore = score
                bestIdx = i
            }
        }
        return bestIdx
    }

    // MARK: - Compatibility Score (v4.0 — 9 dimensions)

    private func compatibility(_ a: AnalyzedSong, _ b: AnalyzedSong, history: [AnalyzedSong],
                               position: Int = 0, total: Int = 0) -> Double {
        guard a.analysis != nil, b.analysis != nil else { return .infinity }

        let bpmA = a.bpm
        let bpmB = b.bpm
        let energyA = a.energy
        let energyB = b.energy

        // ── 1. Key penalty — delegates to DJMixingService ──
        let camelotA = Self.camelotKey(a.key)
        let camelotB = Self.camelotKey(b.key)
        let harmonic = DJMixingService.harmonicPenalty(keyA: camelotA, keyB: camelotB)
        var keyPenalty: Double
        switch harmonic.compatibility {
        case .compatible: keyPenalty = 0
        case .acceptable: keyPenalty = 5
        case .tense:      keyPenalty = 12
        case .clash:      keyPenalty = 20
        }
        // Energy boost discount: rising energy + large key jump = valid DJ energy boost
        if energyB > energyA + 0.1 && harmonic.distance >= 5 {
            keyPenalty *= 0.6
        }

        // Key fatigue: penalize repeating the same key 3+ times in recent history
        var keyFatiguePenalty: Double = 0
        if history.count >= 3, let kB = camelotB {
            let recentKeys = history.suffix(3).compactMap { Self.camelotKey($0.key) }
            if recentKeys.filter({ $0 == kB }).count >= 2 { keyFatiguePenalty = 8 }
        }

        // ── 2. BPM penalty — confidence-gated, Essentia cross-validated ──
        let harmonicB = DJMixingService.harmonicBPM(bpmA, bpmB)
        let bpmDiff = abs(bpmA - harmonicB)
        var bpmPenalty = pow(bpmDiff, 1.4) / 8

        // Reduce penalty when BPM is unreliable
        let minConf = min(a.bpmConfidence, b.bpmConfidence)
        if minConf < 0.5 {
            bpmPenalty *= minConf / 0.5
        }
        // Essentia cross-validation: disagreement = less trust in BPM
        if let essA = a.bpmEssentia, abs(essA - bpmA) / bpmA > 0.10 { bpmPenalty *= 0.7 }
        if let essB = b.bpmEssentia, abs(essB - bpmB) / bpmB > 0.10 { bpmPenalty *= 0.7 }

        // ── 3. Energy penalty (unchanged from v3.0) ──
        let energyDiff = abs(energyA - energyB)
        var energyPenalty = pow(energyDiff, 2) * 15
        let minEnergy = min(energyA, energyB)
        if minEnergy < 0.45 {
            energyPenalty += pow(0.45 - minEnergy, 1.5) * 60
        }

        // ── 4. Transition quality penalty (v4.0 — multi-layer) ──
        var transitionPenalty: Double = 12
        if let profA = a.energyProfile, let profB = b.energyProfile {
            let outroA = profA.outro ?? 0.5
            let introB = profB.intro ?? 0.5
            transitionPenalty = pow(abs(outroA - introB), 2) * 40

            // Layer 1: Energy slope continuity
            if let slopeA = profA.outroSlope, let slopeB = profB.introSlope {
                if slopeA < -0.05 && slopeB > 0.05 { transitionPenalty -= 8 }
                if slopeA > 0.05 && slopeB > 0.05 { transitionPenalty += 5 }
            }

            // Layer 2: Vocal clash (multi-level detection)
            transitionPenalty += vocalClashPenalty(a, b)

            // Layer 3: Structural compatibility (instrumental outro↔intro pairing)
            let overlapRoom = min(a.cachedInstrumentalOutro, b.cachedInstrumentalIntro)
            if overlapRoom > 15 { transitionPenalty -= 10 }
            else if overlapRoom > 8 { transitionPenalty -= 5 }
            else if overlapRoom < 3 { transitionPenalty += 8 }

            // Layer 4: CuePoint alignment
            if let cue = b.cuePoint, let introEnd = b.introEndTime {
                if abs(cue - introEnd) < 3 { transitionPenalty -= 3 }
            }

            // Layer 5: Fade duration compatibility
            if let fadeOut = a.fadeOutDuration, let fadeIn = b.fadeInDuration {
                if fadeOut > 3 && fadeIn > 3 { transitionPenalty -= 4 }
            }
        }

        // ── 5. Artist penalty (unchanged) ──
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

        // ── 6. Danceability penalty (unchanged) ──
        let dancePenalty = pow(abs(a.danceability - b.danceability), 2) * 15

        // ── 7. BPM arc penalty (unchanged) ──
        var bpmArcPenalty: Double = 0
        if total > 4 && position > 0 {
            let progress = Double(position) / Double(total)
            let idealBpmFactor: Double
            if progress < 0.15 { idealBpmFactor = 0.4 }
            else if progress < 0.65 { idealBpmFactor = 0.3 + progress }
            else { idealBpmFactor = max(0.3, 1.0 - (progress - 0.65) * 1.5) }

            if history.count >= 2 {
                let prevBpm = history.last!.bpm
                let bpmDirection = harmonicB - prevBpm
                if progress < 0.6 && bpmDirection < -8 {
                    bpmArcPenalty = abs(bpmDirection) * 0.3 * idealBpmFactor
                }
                if progress > 0.75 && bpmDirection > 10 {
                    bpmArcPenalty = bpmDirection * 0.4 * (1.0 - idealBpmFactor)
                }
            }
        }

        // ── 8. Style affinity bonus (v4.0 — rewards same-world adjacency) ──
        let bpmAffinity = max(0, 1.0 - abs(bpmA - harmonicB) / 30.0)
        let energyAffinity = max(0, 1.0 - abs(energyA - energyB) / 0.6)
        let danceAffinity = max(0, 1.0 - abs(a.danceability - b.danceability) / 0.5)
        let harmonicAffinity: Double
        switch harmonic.compatibility {
        case .compatible: harmonicAffinity = 1.0
        case .acceptable: harmonicAffinity = 0.7
        case .tense:      harmonicAffinity = 0.4
        case .clash:      harmonicAffinity = 0.1
        }
        let styleAffinity = bpmAffinity * 0.35 + energyAffinity * 0.25
                          + harmonicAffinity * 0.25 + danceAffinity * 0.15
        let affinityBonus = -styleAffinity * 12

        // ── Weighted sum ──
        return keyPenalty * 3.5
             + bpmPenalty * 2.0
             + energyPenalty * 1.2
             + transitionPenalty * 2.0
             + artistPenalty * 1.5
             + keyFatiguePenalty
             + dancePenalty * 0.8
             + bpmArcPenalty
             + affinityBonus
    }

    // MARK: - Vocal Clash Detection (multi-layer fallback)

    /// Multi-layer vocal overlap risk assessment.
    /// Returns 0 (no risk) to ~16 (vocal trainwreck certain).
    /// Mirrors DJMixingService's VocalOverlapRisk detection hierarchy.
    private func vocalClashPenalty(_ a: AnalyzedSong, _ b: AnalyzedSong) -> Double {
        // Detect A outro vocals (fallback chain: speechSegments > lastVocalTime > outroVocals)
        let aOutroVocal: Bool
        let aConfidence: Double

        if !a.speechSegments.isEmpty {
            let outroZone = a.duration - 20
            aOutroVocal = a.speechSegments.contains { $0.end > outroZone }
            aConfidence = 0.9
        } else if let lvt = a.lastVocalTime {
            aOutroVocal = lvt > a.duration - 20
            aConfidence = 0.8
        } else if a.hasOutroVocals {
            aOutroVocal = true
            aConfidence = 0.6
        } else {
            aOutroVocal = false
            aConfidence = 0.4
        }

        // Detect B intro vocals (fallback chain: speechSegments > vocalStartTime > introVocals)
        let bIntroVocal: Bool
        let bConfidence: Double

        if !b.speechSegments.isEmpty {
            bIntroVocal = b.speechSegments.contains { $0.start < 20 }
            bConfidence = 0.9
        } else if let vs = b.vocalStartTime, vs > 0 {
            bIntroVocal = vs < 20
            bConfidence = 0.8
        } else if b.hasIntroVocals {
            bIntroVocal = true
            bConfidence = 0.6
        } else {
            bIntroVocal = false
            bConfidence = 0.4
        }

        let avgConfidence = (aConfidence + bConfidence) / 2
        if aOutroVocal && bIntroVocal {
            return 18 * avgConfidence   // both have vocals in transition zone
        } else if aOutroVocal || bIntroVocal {
            return 5 * (aOutroVocal ? aConfidence : bConfidence)
        }
        return 0
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

    // MARK: - Cache Signature (#9 — robust hash of all song IDs)

    private static func signature(_ songs: [NavidromeSong]) -> String {
        guard !songs.isEmpty else { return "empty" }
        // Hash all song IDs so any change (add, remove, reorder) invalidates cache
        let combined = songs.map(\.id).joined(separator: ",")
        let digest = Insecure.MD5.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
