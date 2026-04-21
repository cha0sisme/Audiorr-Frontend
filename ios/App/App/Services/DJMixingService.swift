// ╔══════════════════════════════════════════════════════════════════════╗
// ║                                                                      ║
// ║   DJMixingService — "Crossfade Intelligence Engine" v2.0             ║
// ║   Codename: "Velvet Transition"                                      ║
// ║                                                                      ║
// ║   Audiorr — Audiophile-grade music player                            ║
// ║   Copyright (c) 2025-2026 cha0sisme (github.com/cha0sisme)          ║
// ║                                                                      ║
// ║   Pure crossfade intelligence — no side effects, no audio playback.  ║
// ║   Analyzes song structure, energy, harmony, and rhythm to decide     ║
// ║   the optimal transition between any two tracks.                     ║
// ║                                                                      ║
// ║   v1.0 — JS DJMixingAlgorithms.ts (basic crossfade + beat sync)     ║
// ║   v2.0 — Velvet Transition: equal-power curves, bass swap,           ║
// ║          harmonic BPM detection (half/double tempo), 4-level          ║
// ║          harmonic compatibility, energy compensation, lowpass sweep, ║
// ║          beat-aligned bass swap on downbeats, time-stretch with       ║
// ║          beat-quantized rate ramp, vocal trainwreck detection,       ║
// ║          forced bass management for BEAT_MATCH_BLEND/EQ_MIX          ║
// ║                                                                      ║
// ╚══════════════════════════════════════════════════════════════════════╝

import Foundation

/// DJMixingService v2.0 "Velvet Transition" — pure crossfade intelligence calculations.
/// No side effects, no audio playback — just math.
enum DJMixingService {

    // MARK: - Types

    enum MixMode: String {
        case dj, normal
    }

    enum TransitionType: String {
        case crossfade = "CROSSFADE"
        case eqMix = "EQ_MIX"
        case cut = "CUT"
        case naturalBlend = "NATURAL_BLEND"
        case beatMatchBlend = "BEAT_MATCH_BLEND"
        case cutAFadeInB = "CUT_A_FADE_IN_B"
        case fadeOutACutB = "FADE_OUT_A_CUT_B"
    }

    struct MixModeConfig {
        let minFadeDuration: Double
        let maxFadeDuration: Double
        let baseFadeDuration: Double
        let fallbackPercent: Double
        let fallbackMaxSeconds: Double
    }

    static let configs: [MixMode: MixModeConfig] = [
        .dj: MixModeConfig(
            minFadeDuration: 5, maxFadeDuration: 10, baseFadeDuration: 6,
            fallbackPercent: 0.02, fallbackMaxSeconds: 3
        ),
        .normal: MixModeConfig(
            minFadeDuration: 6, maxFadeDuration: 12, baseFadeDuration: 8,
            fallbackPercent: 0.01, fallbackMaxSeconds: 2
        ),
    ]

    /// Song analysis data (from backend or local analysis).
    struct SongAnalysis {
        var bpm: Double = 120
        var beatInterval: Double = 0
        var energy: Double = 0.5
        var key: String?
        var outroStartTime: Double = 0
        var introEndTime: Double = 0
        var vocalStartTime: Double = 0
        var chorusStartTime: Double = 0
        var phraseBoundaries: [Double] = []
        var downbeatTimes: [Double] = []
        var speechSegments: [(start: Double, end: Double)] = []
        var hasError: Bool = false
        /// True when outroStartTime comes from real analysis data (not a default).
        var hasOutroData: Bool = false
        /// True when introEndTime comes from real analysis data (not a default).
        var hasIntroData: Bool = false
        /// Backend-calculated cue point — ideal time to start crossfade on this song.
        /// When present, overrides the heuristic trigger calculation in QueueManager.
        var cuePoint: Double = 0
        var hasCuePoint: Bool = false
        /// Per-section energy from backend (more useful than global `energy`).
        var energyIntro: Double = 0
        var energyMain: Double = 0
        var energyOutro: Double = 0
        var hasEnergyProfile: Bool = false
    }

    /// Complete crossfade configuration output.
    struct CrossfadeResult {
        let entryPoint: Double
        let fadeDuration: Double
        let transitionType: TransitionType
        let useFilters: Bool
        let useAggressiveFilters: Bool
        let needsAnticipation: Bool
        let anticipationTime: Double
        let beatSyncInfo: String
        let isBeatSynced: Bool
        /// Time-stretch: whether to adjust playback rate to match BPMs during crossfade.
        let useTimeStretch: Bool
        /// Target playback rate for song A during crossfade (1.0 = no change).
        let rateA: Float
        /// Target playback rate for song B during crossfade (1.0 = no change).
        let rateB: Float
        /// Energy levels for preset selection and volume compensation.
        let energyA: Double
        let energyB: Double
        /// Beat grid info for beat-aware automation in CrossfadeExecutor.
        let beatIntervalA: Double
        let beatIntervalB: Double
        let downbeatTimesA: [Double]
        let downbeatTimesB: [Double]
        /// DJ-grade filters: mid scoop (vocal anti-clash) and high-shelf (hi-hat cleanup).
        let useMidScoop: Bool
        let useHighShelfCut: Bool
    }

    // MARK: - Main Entry Point

    /// Calculate full crossfade configuration (replaces calculateCrossfadeConfig in JS).
    static func calculateCrossfadeConfig(
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        bufferADuration: Double,
        bufferBDuration: Double,
        mode: MixMode,
        currentPlaybackTimeA: Double? = nil,
        userFadeDuration: Double? = nil
    ) -> CrossfadeResult {
        // Sanitize all analysis data before any calculations.
        // Protects against out-of-range values from the backend.
        let safeCurrent = currentAnalysis.map { sanitize($0, duration: bufferADuration) }
        let safeNext = nextAnalysis.map { sanitize($0, duration: bufferBDuration) }

        let entry = calculateSmartEntryPoint(
            nextAnalysis: safeNext,
            currentAnalysis: safeCurrent,
            bufferDuration: bufferBDuration,
            mode: mode,
            currentPlaybackTimeA: currentPlaybackTimeA
        )

        let fade = calculateAdaptiveFadeDuration(
            entryPoint: entry.entryPoint,
            bufferADuration: bufferADuration,
            bufferBDuration: bufferBDuration,
            currentAnalysis: safeCurrent,
            nextAnalysis: safeNext,
            mode: mode,
            userFadeDuration: userFadeDuration
        )

        let filter = decideFilterUsage(
            currentAnalysis: safeCurrent,
            nextAnalysis: safeNext,
            fadeDuration: fade.duration,
            mode: mode
        )

        let anticipation = decideAnticipation(
            fadeDuration: fade.duration,
            entryPoint: entry.entryPoint
        )

        let transition = decideTransitionType(
            currentAnalysis: safeCurrent,
            nextAnalysis: safeNext,
            entryPoint: entry.entryPoint,
            fadeDuration: fade.duration,
            isBeatSynced: entry.isBeatSynced,
            useFilters: filter.useFilters,
            useAggressiveFilters: filter.useAggressiveFilters,
            needsAnticipation: anticipation.needsAnticipation,
            anticipationTime: anticipation.anticipationTime,
            bufferADuration: bufferADuration
        )

        let timeStretch = decideTimeStretch(
            currentAnalysis: safeCurrent,
            nextAnalysis: safeNext,
            transitionType: transition.type
        )

        // ── DJ-grade filter decisions ──
        let djFilters = decideDJFilters(
            currentAnalysis: safeCurrent,
            nextAnalysis: safeNext,
            fadeDuration: fade.duration,
            entryPoint: entry.entryPoint,
            bufferADuration: bufferADuration
        )

        // Use per-section energy when available: A's outro energy and B's intro energy
        // are what actually overlap during the crossfade — much more accurate than global average.
        let eA: Double
        if let cur = safeCurrent, cur.hasEnergyProfile {
            eA = cur.energyOutro
        } else {
            eA = (safeCurrent?.hasError != true) ? (safeCurrent?.energy ?? 0.5) : 0.5
        }
        let eB: Double
        if let nxt = safeNext, nxt.hasEnergyProfile {
            eB = nxt.energyIntro
        } else {
            eB = (safeNext?.hasError != true) ? (safeNext?.energy ?? 0.5) : 0.5
        }

        let biA = (safeCurrent?.hasError != true) ? (safeCurrent?.beatInterval ?? 0) : 0
        let rawBiB = (safeNext?.hasError != true) ? (safeNext?.beatInterval ?? 0) : 0
        // When time-stretch is active, B's effective beat interval changes by 1/rateB
        // (faster playback = shorter beat intervals in wall-clock time)
        let biB = timeStretch.useTimeStretch && timeStretch.rateB > 0
            ? rawBiB / Double(timeStretch.rateB) : rawBiB
        let dbA = (safeCurrent?.hasError != true) ? (safeCurrent?.downbeatTimes ?? []) : []
        let rawDbB = (safeNext?.hasError != true) ? (safeNext?.downbeatTimes ?? []) : []
        // Adjust B's downbeat times for time-stretch (wall-clock positions shift)
        let dbB: [Double] = timeStretch.useTimeStretch && timeStretch.rateB > 0
            ? rawDbB.map { $0 / Double(timeStretch.rateB) } : rawDbB

        return CrossfadeResult(
            entryPoint: entry.entryPoint,
            fadeDuration: fade.duration,
            transitionType: transition.type,
            useFilters: filter.useFilters,
            useAggressiveFilters: filter.useAggressiveFilters,
            needsAnticipation: anticipation.needsAnticipation,
            anticipationTime: anticipation.anticipationTime,
            beatSyncInfo: entry.beatSyncInfo,
            isBeatSynced: entry.isBeatSynced,
            useTimeStretch: timeStretch.useTimeStretch,
            rateA: timeStretch.rateA,
            rateB: timeStretch.rateB,
            energyA: eA,
            energyB: eB,
            beatIntervalA: biA,
            beatIntervalB: biB,
            downbeatTimesA: dbA,
            downbeatTimesB: dbB,
            useMidScoop: djFilters.useMidScoop,
            useHighShelfCut: djFilters.useHighShelfCut
        )
    }

    // MARK: - Entry Point

    struct EntryPointResult {
        let entryPoint: Double
        let beatSyncInfo: String
        let usedFallback: Bool
        let isBeatSynced: Bool
    }

    /// Clamp analysis timing values to valid range [0, duration].
    /// Protects against bad backend data (e.g. introEndTime=500 for a 200s song).
    private static func sanitize(_ analysis: SongAnalysis, duration: Double) -> SongAnalysis {
        var a = analysis
        let maxT = max(0, duration)
        a.introEndTime = min(max(0, a.introEndTime), maxT)
        a.outroStartTime = min(max(0, a.outroStartTime), maxT)
        a.vocalStartTime = min(max(0, a.vocalStartTime), maxT)
        a.chorusStartTime = min(max(0, a.chorusStartTime), maxT)
        if a.hasCuePoint { a.cuePoint = min(max(0, a.cuePoint), maxT) }
        a.phraseBoundaries = a.phraseBoundaries.filter { $0 >= 0 && $0 <= maxT }
        a.downbeatTimes = a.downbeatTimes.filter { $0 >= 0 && $0 <= maxT }
        a.speechSegments = a.speechSegments.compactMap { seg in
            let s = max(0, seg.start)
            let e = min(maxT, seg.end)
            return s < e ? (start: s, end: e) : nil
        }
        // BPM sanity: reject extreme values
        if a.bpm < 30 || a.bpm > 300 { a.bpm = 120 }
        // Energy sanity: clamp to [0, 1]
        a.energy = min(max(0, a.energy), 1)
        return a
    }

    static func calculateSmartEntryPoint(
        nextAnalysis: SongAnalysis?,
        currentAnalysis: SongAnalysis?,
        bufferDuration: Double,
        mode: MixMode,
        currentPlaybackTimeA: Double? = nil
    ) -> EntryPointResult {
        let config = configs[mode]!

        var entryPoint: Double = 0
        var beatSyncInfo = ""
        var usedFallback = false
        var isBeatSynced = false

        guard let rawNext = nextAnalysis, !rawNext.hasError else {
            entryPoint = min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)
            return EntryPointResult(entryPoint: entryPoint, beatSyncInfo: "", usedFallback: true, isBeatSynced: false)
        }

        let next = sanitize(rawNext, duration: bufferDuration)

        let introEndTime = next.introEndTime
        let vocalStartTime = next.vocalStartTime
        let chorusStartTime = next.chorusStartTime

        // Entry point = the energy moment itself (intro end, vocal start, chorus).
        // The fade duration provides the natural lead-in before the punch.
        // Previously we subtracted introLeadTime/vocalLeadTime, which left a
        // "dead zone" where both songs were at full volume with no energy transition.
        if mode == .dj {
            if introEndTime > 3 {
                entryPoint = introEndTime
            } else if chorusStartTime > 4 {
                entryPoint = chorusStartTime
            } else if vocalStartTime > 2 {
                entryPoint = vocalStartTime
            } else {
                entryPoint = min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)
                usedFallback = true
            }
        } else {
            if introEndTime > 2.5 {
                entryPoint = introEndTime
            } else if vocalStartTime > 1 {
                entryPoint = vocalStartTime
            } else if chorusStartTime > 4 {
                entryPoint = chorusStartTime
            } else {
                entryPoint = min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)
                usedFallback = true
            }
        }

        // Energy flow (Build-up/Boost)
        let energyA = (currentAnalysis?.hasError == false) ? (currentAnalysis?.energy ?? 0.5) : 0.5
        let energyB = next.energy

        if energyB > energyA + 0.25 {
            if chorusStartTime > entryPoint && chorusStartTime < entryPoint + 30 {
                entryPoint = chorusStartTime
            }
        }

        // Phrasing
        if !next.phraseBoundaries.isEmpty {
            let maxAhead: Double = 16
            if let nextPhrase = next.phraseBoundaries.first(where: { $0 >= entryPoint && $0 <= entryPoint + maxAhead }) {
                entryPoint = nextPhrase
            }
        }

        // Beat matching — enabled for both DJ and normal modes when beat data is available.
        // In normal mode, only align to downbeats (no cross-phase alignment) for subtle sync.
        let beatResult = applyBeatSync(
            entryPoint: entryPoint,
            currentAnalysis: currentAnalysis,
            nextAnalysis: next,
            currentPlaybackTimeA: currentPlaybackTimeA,
            mode: mode
        )
        entryPoint = beatResult.adjustedEntryPoint
        beatSyncInfo = beatResult.info
        isBeatSynced = beatResult.isSynced

        entryPoint = max(0, min(entryPoint, bufferDuration - 1))

        return EntryPointResult(
            entryPoint: entryPoint,
            beatSyncInfo: beatSyncInfo,
            usedFallback: usedFallback,
            isBeatSynced: isBeatSynced
        )
    }

    // MARK: - Beat Sync

    private struct BeatSyncResult {
        let adjustedEntryPoint: Double
        let info: String
        let isSynced: Bool
    }

    private static func applyBeatSync(
        entryPoint: Double,
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis,
        currentPlaybackTimeA: Double?,
        mode: MixMode
    ) -> BeatSyncResult {
        // Need valid beat intervals from at least B to sync
        guard !nextAnalysis.hasError, nextAnalysis.beatInterval > 0 else {
            return BeatSyncResult(adjustedEntryPoint: entryPoint, info: "", isSynced: false)
        }

        let hasCurrentBeats = currentAnalysis != nil && currentAnalysis?.hasError != true
            && (currentAnalysis?.beatInterval ?? 0) > 0
        let beatIntervalA = currentAnalysis?.beatInterval ?? nextAnalysis.beatInterval
        let beatIntervalB = nextAnalysis.beatInterval
        let targetBeats = nextAnalysis.downbeatTimes

        // Search range: ±1 beat — tight snap to preserve the punch/energy moment.
        // The entry point now targets the exact energy moment (introEnd, vocalStart, etc.),
        // so we only allow minimal displacement to land on a beat.
        let searchRange = beatIntervalB * 1.0

        var adjustedEntryPoint = entryPoint
        var info = ""

        // Phase 1: Align B to its nearest downbeat (tight snap)
        if !targetBeats.isEmpty {
            let candidates = targetBeats.filter { abs($0 - entryPoint) <= searchRange }
            if let best = candidates.min(by: { abs($0 - entryPoint) < abs($1 - entryPoint) }) {
                let adj = best - entryPoint
                adjustedEntryPoint = best
                info = "Downbeat real: \(adj >= 0 ? "+" : "")\(String(format: "%.3f", adj))s"
            } else {
                // No downbeat within ±1 beat — snap to nearest beat grid position
                let gridSnap = snapToMeasureGrid(entryPoint, measureLength: beatIntervalB * 4, beatInterval: beatIntervalB)
                // Only apply if the snap is small (within half a beat)
                if abs(gridSnap) <= beatIntervalB * 0.5 {
                    adjustedEntryPoint = entryPoint + gridSnap
                    info = "Grid snap: \(gridSnap >= 0 ? "+" : "")\(String(format: "%.3f", gridSnap))s"
                }
                // Otherwise keep the exact punch position
            }
        } else {
            // No downbeat data — snap to beat grid only if very close
            let gridSnap = snapToMeasureGrid(entryPoint, measureLength: beatIntervalB * 4, beatInterval: beatIntervalB)
            if abs(gridSnap) <= beatIntervalB * 0.5 {
                adjustedEntryPoint = entryPoint + gridSnap
                info = "Grid snap: \(gridSnap >= 0 ? "+" : "")\(String(format: "%.3f", gridSnap))s"
            }
        }

        // Phase 2: Cross-phase alignment A↔B (DJ mode only — too aggressive for normal)
        if mode == .dj, hasCurrentBeats, let playbackA = currentPlaybackTimeA, playbackA > 0 {
            let beatFractionA = playbackA.truncatingRemainder(dividingBy: beatIntervalA) / beatIntervalA
            let targetPhaseOffsetB = beatFractionA * beatIntervalB
            let currentPhaseB = adjustedEntryPoint.truncatingRemainder(dividingBy: beatIntervalB)
            var phaseError = targetPhaseOffsetB - currentPhaseB
            if phaseError > beatIntervalB / 2 { phaseError -= beatIntervalB }
            if phaseError < -beatIntervalB / 2 { phaseError += beatIntervalB }

            // Only correct if the phase error is significant (>15% of a beat)
            // and only apply small corrections to preserve the punch alignment
            if abs(phaseError) > beatIntervalB * 0.15 {
                // Search nearby downbeats for one that also satisfies phase alignment
                if !targetBeats.isEmpty {
                    // Only consider downbeats within ±1 beat (tight range to preserve punch)
                    let candidates = targetBeats.filter {
                        abs($0 - adjustedEntryPoint) <= searchRange && $0 >= 0
                    }
                    var bestCandidate = adjustedEntryPoint
                    var bestError = abs(phaseError)
                    for candidate in candidates {
                        let candPhase = candidate.truncatingRemainder(dividingBy: beatIntervalB)
                        var candError = targetPhaseOffsetB - candPhase
                        if candError > beatIntervalB / 2 { candError -= beatIntervalB }
                        if candError < -beatIntervalB / 2 { candError += beatIntervalB }
                        if abs(candError) < bestError {
                            bestError = abs(candError)
                            bestCandidate = candidate
                        }
                    }
                    let phaseAdj = bestCandidate - adjustedEntryPoint
                    // Only apply if the adjustment is small (within half a beat)
                    if abs(phaseAdj) <= beatIntervalB * 0.5 {
                        adjustedEntryPoint = bestCandidate
                        info += " + fase A↔B: \(phaseAdj >= 0 ? "+" : "")\(String(format: "%.3f", phaseAdj))s"
                    }
                } else {
                    // No downbeats — only apply phase correction if small
                    let phaseAdj = max(-searchRange, min(searchRange, phaseError))
                    if abs(phaseAdj) <= beatIntervalB * 0.5 {
                        adjustedEntryPoint += phaseAdj
                        info += " + fase A↔B: \(phaseAdj >= 0 ? "+" : "")\(String(format: "%.3f", phaseAdj))s"
                    }
                }
            }
        }

        return BeatSyncResult(adjustedEntryPoint: max(0, adjustedEntryPoint), info: info, isSynced: true)
    }

    /// Snap a time position to the nearest measure boundary within ±1 beat.
    private static func snapToMeasureGrid(_ time: Double, measureLength: Double, beatInterval: Double) -> Double {
        guard measureLength > 0 else { return 0 }
        let timeIntoMeasure = time.truncatingRemainder(dividingBy: measureLength)
        // Close to start of measure — snap backward
        if timeIntoMeasure < beatInterval * 0.5 && timeIntoMeasure > 0.001 {
            return -timeIntoMeasure
        }
        // Close to end of measure — snap forward
        let distToNext = measureLength - timeIntoMeasure
        if distToNext < beatInterval * 0.5 {
            return distToNext
        }
        // Not near a measure boundary — snap to nearest beat
        let timeIntoBeat = timeIntoMeasure.truncatingRemainder(dividingBy: beatInterval)
        if timeIntoBeat < beatInterval * 0.25 {
            return -timeIntoBeat
        } else if timeIntoBeat > beatInterval * 0.75 {
            return beatInterval - timeIntoBeat
        }
        return 0
    }

    // MARK: - Fade Duration

    struct FadeDurationResult {
        let duration: Double
        let decision: String
    }

    static func calculateAdaptiveFadeDuration(
        entryPoint: Double,
        bufferADuration: Double,
        bufferBDuration: Double,
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        mode: MixMode,
        userFadeDuration: Double? = nil
    ) -> FadeDurationResult {
        let config = configs[mode]!
        // Use user's custom duration as the base when provided.
        // The intelligent algorithm (DJ/Normal) will still adapt it based on analysis,
        // but the user's preference anchors the starting point.
        let baseDuration = userFadeDuration ?? config.baseFadeDuration
        var fadeDuration = baseDuration
        var decision = "Usando duracion base (\(fadeDuration)s)."

        let hasCurrent = currentAnalysis != nil && currentAnalysis?.hasError == false
        let hasNext = nextAnalysis != nil && nextAnalysis?.hasError == false

        if hasCurrent, hasNext, let current = currentAnalysis, let next = nextAnalysis {
            let introB = next.introEndTime
            let vocalB = next.vocalStartTime
            // Use per-section energy when available
            let energyA = current.hasEnergyProfile ? current.energyOutro : current.energy
            let energyB = next.hasEnergyProfile ? next.energyIntro : next.energy

            let outroAStart = current.outroStartTime > 0 ? current.outroStartTime : bufferADuration
            let outroADuration = bufferADuration - outroAStart
            let hasValidOutro = outroADuration >= 2

            let dropB = introB > 1.0 ? introB : vocalB

            if dropB > entryPoint {
                let idealFade = dropB - entryPoint
                if hasValidOutro {
                    let constrained = min(idealFade, outroADuration)
                    let localMin = mode == .dj ? 2.0 : config.minFadeDuration
                    fadeDuration = max(localMin, min(config.maxFadeDuration, constrained))
                } else {
                    let localMin = mode == .dj ? 2.0 : config.minFadeDuration
                    fadeDuration = max(localMin, min(config.maxFadeDuration, idealFade))
                }
                decision = "Adaptada a intro \(String(format: "%.2f", idealFade))s → \(String(format: "%.2f", fadeDuration))s."
            } else if hasValidOutro {
                fadeDuration = max(config.minFadeDuration, min(config.maxFadeDuration - 2, outroADuration * 0.8))
                decision = "Adaptada a outro (\(String(format: "%.2f", outroADuration))s) → \(String(format: "%.2f", fadeDuration))s."
            } else {
                fadeDuration = userFadeDuration ?? (mode == .dj ? 5 : 6)
                decision = "Duración por canción abrupta: \(fadeDuration)s."
            }

            // Energy flow dropdown
            if energyB < energyA - 0.25 && hasValidOutro && outroADuration > 12 {
                fadeDuration = min(15, max(fadeDuration, outroADuration * 0.9))
                decision += " Extendido por caida de energia a \(String(format: "%.2f", fadeDuration))s."
            }

            // Gradual harmonic penalty
            let harmonic = harmonicPenalty(keyA: current.key, keyB: next.key)
            switch harmonic.compatibility {
            case .compatible, .acceptable:
                break  // no penalty
            case .tense:
                fadeDuration = max(2, fadeDuration * 0.85)
                decision += " Reducido 15% por tension armonica a \(String(format: "%.2f", fadeDuration))s."
            case .clash:
                fadeDuration = max(2, fadeDuration * 0.75)
                decision += " Reducido 25% por clash armonico a \(String(format: "%.2f", fadeDuration))s."
            }
        } else {
            // No analysis available — use user's duration or a safe default.
            fadeDuration = userFadeDuration ?? (bufferADuration < 30 ? 3 : baseDuration)
            decision = "Sin analisis — duracion \(String(format: "%.0f", fadeDuration))s."
        }

        // Absolute max: 25% of the shorter track
        let absoluteMax = min(bufferADuration * 0.25, bufferBDuration * 0.25)
        if fadeDuration > absoluteMax {
            fadeDuration = max(2, absoluteMax)
            decision += " Acortado por limite 25% a \(String(format: "%.2f", fadeDuration))s."
        }

        // Cap fade to B's available audio after entry point.
        // Without this, if B is 20s and entry is at 5s, a 6s fade would end at 11s
        // but B only has 15s of audio — if B ends before fade completes, there's a gap.
        // Leave 2s buffer so B doesn't end right as the fade finishes.
        let bAvailable = bufferBDuration - entryPoint - 2.0
        if bAvailable > 0 && fadeDuration > bAvailable {
            fadeDuration = max(2, bAvailable)
            decision += " Acortado por B corta (disponible: \(String(format: "%.1f", bAvailable + 2))s) a \(String(format: "%.2f", fadeDuration))s."
        }

        return FadeDurationResult(duration: max(2, fadeDuration), decision: decision)
    }

    // MARK: - Filter Decision

    struct FilterDecisionResult {
        let useFilters: Bool
        let useAggressiveFilters: Bool
        let energyDiff: Double
        let bpmDiff: Double
        let reason: String
    }

    static func decideFilterUsage(
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        fadeDuration: Double,
        mode: MixMode
    ) -> FilterDecisionResult {
        let hasVocalsOutro = currentAnalysis?.vocalStartTime ?? 0 > 0 && currentAnalysis?.hasError != true
        let hasVocalsIntro = nextAnalysis?.vocalStartTime ?? 0 > 0 && nextAnalysis?.hasError != true

        // Use per-section energy: outro of A and intro of B are what overlap
        let energyA: Double
        if let cur = currentAnalysis, cur.hasEnergyProfile {
            energyA = cur.energyOutro
        } else {
            energyA = (currentAnalysis?.hasError != true) ? (currentAnalysis?.energy ?? 0.5) : 0.5
        }
        let energyB: Double
        if let nxt = nextAnalysis, nxt.hasEnergyProfile {
            energyB = nxt.energyIntro
        } else {
            energyB = (nextAnalysis?.hasError != true) ? (nextAnalysis?.energy ?? 0.5) : 0.5
        }
        let bpmA = (currentAnalysis?.hasError != true) ? (currentAnalysis?.bpm ?? 120) : 120
        let bpmB = (nextAnalysis?.hasError != true) ? (nextAnalysis?.bpm ?? 120) : 120

        let keyA = currentAnalysis?.key
        let keyB = nextAnalysis?.key
        let harmonic = harmonicPenalty(keyA: keyA, keyB: keyB)

        let energyDiff = abs(energyA - energyB)
        // Use harmonic BPM for filter decision (half/double tempo shouldn't trigger filters)
        let bpmDiff = abs(bpmA - harmonicBPM(bpmA, bpmB))
        let isVeryShort = fadeDuration < 3
        let isShort = fadeDuration < 4

        let useFilters = hasVocalsOutro || hasVocalsIntro ||
            energyDiff > 0.3 || bpmDiff > 20 || harmonic.isClash || isVeryShort

        let useAggressive = (hasVocalsOutro || hasVocalsIntro || isShort ||
            harmonic.compatibility == .clash) && useFilters

        var reasons: [String] = []
        if hasVocalsOutro || hasVocalsIntro { reasons.append("voces") }
        if energyDiff > 0.3 { reasons.append("energia \(Int(energyDiff * 100))%") }
        if bpmDiff > 20 { reasons.append("BPM ±\(Int(bpmDiff))") }
        if harmonic.compatibility == .tense { reasons.append("tension tonal") }
        if harmonic.compatibility == .clash { reasons.append("clash tonal") }
        if isVeryShort { reasons.append("fade<3s") }

        let reason = useFilters ? "Filtros ON: \(reasons.joined(separator: ", "))" : "Filtros OFF: mezcla simple"

        return FilterDecisionResult(
            useFilters: useFilters, useAggressiveFilters: useAggressive,
            energyDiff: energyDiff, bpmDiff: bpmDiff, reason: reason
        )
    }

    // MARK: - DJ-Grade Filters (Mid Scoop + High-Shelf)

    struct DJFilterResult {
        let useMidScoop: Bool
        let useHighShelfCut: Bool
        let reason: String
    }

    /// Decides whether to activate mid-range scoop and high-shelf cut on A.
    /// - Mid scoop: activated when A has vocals in its outro AND B has vocals in its intro.
    ///   This prevents the "vocal trainwreck" muddiness without cutting to a hard CUT transition.
    /// - High-shelf: activated when A has moderate-to-high energy (>0.45), indicating
    ///   hi-hats/cymbals that would clash with B's transients during overlap.
    static func decideDJFilters(
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        fadeDuration: Double,
        entryPoint: Double,
        bufferADuration: Double
    ) -> DJFilterResult {
        let hasCurrent = currentAnalysis != nil && currentAnalysis?.hasError != true
        let hasNext = nextAnalysis != nil && nextAnalysis?.hasError != true
        guard hasCurrent || hasNext else {
            return DJFilterResult(useMidScoop: false, useHighShelfCut: false, reason: "Sin analisis")
        }

        var useMidScoop = false
        var useHighShelf = false
        var reasons: [String] = []

        // ── Mid Scoop: vocal overlap detection ──
        // Check if A has vocals in the crossfade zone AND B has vocals in its entry zone.
        if let current = currentAnalysis, let next = nextAnalysis {
            let crossfadeStartA = bufferADuration - fadeDuration
            let aHasVocalsInOutro: Bool
            if !current.speechSegments.isEmpty {
                // Precise: any speech segment overlaps with the crossfade zone
                aHasVocalsInOutro = current.speechSegments.contains { $0.end > crossfadeStartA }
            } else {
                // Fallback: vocalStartTime > 0 means song has vocals, and outro isn't pure instrumental
                aHasVocalsInOutro = current.vocalStartTime > 0 &&
                    (current.outroStartTime <= 0 || current.outroStartTime > crossfadeStartA)
            }

            let bVocalStart = next.vocalStartTime
            let bHasVocalsInIntro: Bool
            if !next.speechSegments.isEmpty {
                // Precise: B has speech in the entry zone (entryPoint to entryPoint + fadeDuration)
                let bOverlapEnd = entryPoint + fadeDuration
                bHasVocalsInIntro = next.speechSegments.contains { $0.start < bOverlapEnd && $0.end > entryPoint }
            } else {
                // Fallback: vocals start within the fade window
                bHasVocalsInIntro = bVocalStart > 0 && bVocalStart < entryPoint + fadeDuration
            }

            if aHasVocalsInOutro && bHasVocalsInIntro {
                useMidScoop = true
                reasons.append("mid scoop: voces solapadas")
            }
        }

        // ── High-Shelf: energy-based hi-hat detection ──
        // Songs with energy > 0.45 typically have prominent hi-hats/cymbals.
        // Cut highs on A to let B's transients breathe.
        // Use per-section energy: outro of A, intro of B (the overlapping sections).
        let energyA: Double
        if let cur = currentAnalysis, cur.hasEnergyProfile {
            energyA = cur.energyOutro
        } else {
            energyA = currentAnalysis?.energy ?? 0.5
        }
        let energyB: Double
        if let nxt = nextAnalysis, nxt.hasEnergyProfile {
            energyB = nxt.energyIntro
        } else {
            energyB = nextAnalysis?.energy ?? 0.5
        }
        if energyA > 0.45 && energyB > 0.35 {
            useHighShelf = true
            reasons.append("hi-shelf: energia A=\(String(format: "%.2f", energyA)) B=\(String(format: "%.2f", energyB))")
        }

        let reason = reasons.isEmpty ? "DJ filters OFF" : "DJ filters ON: \(reasons.joined(separator: ", "))"
        return DJFilterResult(useMidScoop: useMidScoop, useHighShelfCut: useHighShelf, reason: reason)
    }

    // MARK: - Anticipation

    struct AnticipationResult {
        let needsAnticipation: Bool
        let anticipationTime: Double
        let reason: String
    }

    static func decideAnticipation(fadeDuration: Double, entryPoint: Double) -> AnticipationResult {
        let hasEnoughIntro = entryPoint >= 5
        let needs = fadeDuration < 8 && hasEnoughIntro

        if needs {
            let maxAnticipation = min(4, entryPoint * 0.3)
            let time = min(maxAnticipation, max(2, 10 - fadeDuration))
            return AnticipationResult(needsAnticipation: true, anticipationTime: time,
                                      reason: "Anticipacion: +\(String(format: "%.1f", time))s (fade corto)")
        } else if fadeDuration >= 8 {
            return AnticipationResult(needsAnticipation: false, anticipationTime: 0,
                                      reason: "Sin anticipacion: fade largo")
        } else {
            return AnticipationResult(needsAnticipation: false, anticipationTime: 0,
                                      reason: "Sin anticipacion: intro insuficiente")
        }
    }

    // MARK: - Transition Type

    struct TransitionTypeResult {
        let type: TransitionType
        let reason: String
    }

    static func decideTransitionType(
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        entryPoint: Double,
        fadeDuration: Double,
        isBeatSynced: Bool,
        useFilters: Bool,
        useAggressiveFilters: Bool,
        needsAnticipation: Bool,
        anticipationTime: Double,
        bufferADuration: Double
    ) -> TransitionTypeResult {
        let hasCurrent = currentAnalysis != nil && currentAnalysis?.hasError != true
        let hasNext = nextAnalysis != nil && nextAnalysis?.hasError != true

        // Determine if A ends abruptly.
        // CRITICAL: only mark as abrupt when we have REAL outro data that confirms it.
        // Without data (hasOutroData=false), assume normal ending → NATURAL_BLEND (safe default).
        var isAAbrupt = false
        if hasCurrent, let current = currentAnalysis {
            if current.hasOutroData {
                // Real data: abrupt if outro starts very late or is missing
                isAAbrupt = current.outroStartTime <= 0 || current.outroStartTime >= bufferADuration - 2
            }
            // No outro data → assume normal (not abrupt)
        } else {
            // No analysis at all → conservative: only abrupt if fade is very short
            isAAbrupt = fadeDuration < 3
        }

        // Determine if B starts abruptly.
        // Same logic: only trust real intro data.
        var isBAbrupt = false
        if hasNext, let next = nextAnalysis {
            if next.hasIntroData {
                isBAbrupt = next.introEndTime < 2
            }
            // No intro data → assume normal (not abrupt)
        } else {
            isBAbrupt = fadeDuration < 3
        }

        var type: TransitionType = .crossfade
        var reason = "Transicion normal"

        if isBeatSynced && !isAAbrupt && !isBAbrupt {
            type = .beatMatchBlend
            reason = "Beats sincronizados → BEAT_MATCH_BLEND"
        } else if isAAbrupt && isBAbrupt {
            if fadeDuration < 4 {
                type = .cut
                reason = "Ambos abruptos + fade corto → CUT"
            } else {
                type = .eqMix
                reason = "Ambos abruptos + fade mantenido ��� EQ_MIX"
            }
        } else if isAAbrupt && !isBAbrupt {
            type = .cutAFadeInB
            reason = "A abrupto, B suave → CUT_A_FADE_IN_B"
        } else if !isAAbrupt && isBAbrupt {
            type = .fadeOutACutB
            reason = "A suave, B abrupto → FADE_OUT_A_CUT_B"
        } else {
            type = .naturalBlend
            reason = "Ambos suaves → NATURAL_BLEND"
        }

        // Safety: extreme BPM jump (with harmonic BPM detection for half/double tempo)
        let rawBpmA = currentAnalysis?.bpm ?? 120
        let rawBpmB = nextAnalysis?.bpm ?? 120
        let bpmB_normalized = harmonicBPM(rawBpmA, rawBpmB)
        let effectiveBpmDiff = abs(rawBpmA - bpmB_normalized)
        // Threshold is higher when filters are active (they mask rhythmic clashing)
        let bpmCutThreshold: Double = useFilters ? 25 : 15
        if effectiveBpmDiff > bpmCutThreshold && !isBeatSynced && fadeDuration > 3 {
            type = .cut
            let normalizedNote = bpmB_normalized != rawBpmB ? " (norm:\(Int(bpmB_normalized)))" : ""
            reason = "Polirritmia evitada (A:\(Int(rawBpmA)) B:\(Int(rawBpmB))\(normalizedNote)) → CUT forzado"
        }

        // Safety: vocal trainwreck
        if hasCurrent, hasNext, let current = currentAnalysis, let next = nextAnalysis {
            let vocalBStart = next.vocalStartTime - entryPoint
            if vocalBStart >= 0 && vocalBStart < fadeDuration {
                let safeOutroA = bufferADuration - fadeDuration
                var aHasVocalsAtEnd = false

                if !current.speechSegments.isEmpty {
                    aHasVocalsAtEnd = current.speechSegments.contains { $0.end > safeOutroA }
                } else {
                    aHasVocalsAtEnd = (current.outroStartTime <= 0 || current.outroStartTime > safeOutroA) && current.vocalStartTime > 0
                }

                if aHasVocalsAtEnd && type != .cut {
                    type = .cut
                    reason = "Vocal Trainwreck evitado → CUT forzado"
                }
            }
        }

        return TransitionTypeResult(type: type, reason: reason)
    }

    // MARK: - Time-Stretch Decision

    struct TimeStretchResult {
        let useTimeStretch: Bool
        let rateA: Float
        let rateB: Float
        let reason: String
    }

    /// Decides whether to apply time-stretching during crossfade to match BPMs.
    /// Only stretches when BPM difference is in the safe range (3-12 BPM).
    /// Outside that range the quality loss isn't worth it.
    static func decideTimeStretch(
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        transitionType: TransitionType
    ) -> TimeStretchResult {
        // Only stretch on blend-type transitions — CUT transitions are too short
        switch transitionType {
        case .cut, .cutAFadeInB, .fadeOutACutB:
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: transicion tipo cut")
        default: break
        }

        let bpmA = (currentAnalysis?.hasError != true) ? (currentAnalysis?.bpm ?? 0) : 0
        let rawBpmB = (nextAnalysis?.hasError != true) ? (nextAnalysis?.bpm ?? 0) : 0

        // Need valid BPMs from both songs
        guard bpmA > 50 && bpmA < 250 && rawBpmB > 50 && rawBpmB < 250 else {
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: BPM fuera de rango o desconocido")
        }

        // Use harmonic BPM to detect half/double tempo (70 vs 140 = compatible)
        let bpmB = harmonicBPM(bpmA, rawBpmB)
        let diff = abs(bpmA - bpmB)

        if diff < 3 {
            // Close enough — no need to stretch
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: BPMs casi iguales (±\(String(format: "%.1f", diff)))")
        } else if diff <= 8 {
            // Small difference — stretch B to match A (less noticeable)
            let rateB = Float(bpmA / bpmB)
            return TimeStretchResult(useTimeStretch: true, rateA: 1.0, rateB: rateB,
                                     reason: "Stretch B→A: \(Int(bpmB))→\(Int(bpmA)) BPM (rate=\(String(format: "%.3f", rateB)))")
        } else if diff <= 12 {
            // Medium difference — both stretch to midpoint
            let mid = (bpmA + bpmB) / 2.0
            let rateA = Float(mid / bpmA)
            let rateB = Float(mid / bpmB)
            return TimeStretchResult(useTimeStretch: true, rateA: rateA, rateB: rateB,
                                     reason: "Stretch ambos→\(Int(mid)) BPM: A=\(String(format: "%.3f", rateA)) B=\(String(format: "%.3f", rateB))")
        } else {
            // >12 BPM — too much stretching, quality will suffer
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: diferencia demasiado grande (±\(Int(diff)) BPM)")
        }
    }

    // MARK: - Harmonic Mixing (Camelot Wheel)

    // MARK: - Harmonic BPM Normalization (double/half tempo detection)

    /// Normalizes BPM of B to the harmonically closest ratio with A.
    /// Detects half-time (70 vs 140), double-time (170 vs 85), and triplet/swing
    /// relationships (e.g. 93 vs 140 ≈ 2/3 ratio).
    /// Ratios: 1/3, 1/2, 2/3, 1, 3/2, 2, 3 — covers all common tempo relationships.
    static func harmonicBPM(_ bpmA: Double, _ bpmB: Double) -> Double {
        guard bpmA > 0 && bpmB > 0 else { return bpmB }
        let ratios: [Double] = [1.0/3, 0.5, 2.0/3, 1.0, 3.0/2, 2.0, 3.0]
        let bestRatio = ratios.min(by: {
            abs(bpmB * $0 - bpmA) < abs(bpmB * $1 - bpmA)
        }) ?? 1.0
        let adjusted = bpmB * bestRatio
        // Only apply if the adjusted BPM is actually closer to A
        return abs(adjusted - bpmA) < abs(bpmB - bpmA) ? adjusted : bpmB
    }

    // MARK: - Harmonic Mixing (Camelot Wheel)

    enum HarmonicCompatibility: Int {
        case compatible = 0   // distance 0-1: perfect/excellent
        case acceptable = 1   // distance 2: fine with filters
        case tense = 2        // distance 3: needs aggressive filters
        case clash = 3        // distance 4+: shorten fade, aggressive filters
    }

    struct HarmonicPenalty {
        let distance: Int
        let compatibility: HarmonicCompatibility
        /// Legacy convenience — true for tense and clash
        var isClash: Bool { compatibility == .tense || compatibility == .clash }
    }

    static func harmonicPenalty(keyA: String?, keyB: String?) -> HarmonicPenalty {
        guard let keyA, let keyB else {
            return HarmonicPenalty(distance: 0, compatibility: .compatible)
        }

        let pattern = #"(\d+)([AB])"#
        guard let regexA = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let regexB = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let matchA = regexA.firstMatch(in: keyA, range: NSRange(keyA.startIndex..., in: keyA)),
              let matchB = regexB.firstMatch(in: keyB, range: NSRange(keyB.startIndex..., in: keyB)),
              let numRangeA = Range(matchA.range(at: 1), in: keyA),
              let letterRangeA = Range(matchA.range(at: 2), in: keyA),
              let numRangeB = Range(matchB.range(at: 1), in: keyB),
              let letterRangeB = Range(matchB.range(at: 2), in: keyB),
              let numA = Int(keyA[numRangeA]),
              let numB = Int(keyB[numRangeB])
        else {
            return HarmonicPenalty(distance: 0, compatibility: .compatible)
        }

        let letterA = keyA[letterRangeA].uppercased()
        let letterB = keyB[letterRangeB].uppercased()

        let diffNum = min(abs(numA - numB), 12 - abs(numA - numB))
        let diffLetter = letterA != letterB ? 1 : 0
        let totalDistance = diffNum + diffLetter

        let compatibility: HarmonicCompatibility
        switch totalDistance {
        case 0...1: compatibility = .compatible
        case 2:     compatibility = diffLetter == 1 ? .tense : .acceptable
        case 3:     compatibility = .tense
        default:    compatibility = .clash
        }

        return HarmonicPenalty(distance: totalDistance, compatibility: compatibility)
    }

}
