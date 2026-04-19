import Foundation

/// Native port of DJMixingAlgorithms.ts — pure crossfade intelligence calculations.
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
        let introLeadTime: Double
        let vocalLeadTime: Double
        let minFadeDuration: Double
        let maxFadeDuration: Double
        let baseFadeDuration: Double
        let fallbackPercent: Double
        let fallbackMaxSeconds: Double
    }

    static let configs: [MixMode: MixModeConfig] = [
        .dj: MixModeConfig(
            introLeadTime: 2.5, vocalLeadTime: 0,
            minFadeDuration: 5, maxFadeDuration: 10, baseFadeDuration: 6,
            fallbackPercent: 0.02, fallbackMaxSeconds: 3
        ),
        .normal: MixModeConfig(
            introLeadTime: 4.5, vocalLeadTime: 3,
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
    }

    // MARK: - Main Entry Point

    /// Calculate full crossfade configuration (replaces calculateCrossfadeConfig in JS).
    static func calculateCrossfadeConfig(
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        bufferADuration: Double,
        bufferBDuration: Double,
        mode: MixMode,
        currentPlaybackTimeA: Double? = nil
    ) -> CrossfadeResult {
        let entry = calculateSmartEntryPoint(
            nextAnalysis: nextAnalysis,
            currentAnalysis: currentAnalysis,
            bufferDuration: bufferBDuration,
            mode: mode,
            currentPlaybackTimeA: currentPlaybackTimeA
        )

        let fade = calculateAdaptiveFadeDuration(
            entryPoint: entry.entryPoint,
            bufferADuration: bufferADuration,
            bufferBDuration: bufferBDuration,
            currentAnalysis: currentAnalysis,
            nextAnalysis: nextAnalysis,
            mode: mode
        )

        let filter = decideFilterUsage(
            currentAnalysis: currentAnalysis,
            nextAnalysis: nextAnalysis,
            fadeDuration: fade.duration,
            mode: mode
        )

        let anticipation = decideAnticipation(
            fadeDuration: fade.duration,
            entryPoint: entry.entryPoint
        )

        let transition = decideTransitionType(
            currentAnalysis: currentAnalysis,
            nextAnalysis: nextAnalysis,
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
            currentAnalysis: currentAnalysis,
            nextAnalysis: nextAnalysis,
            transitionType: transition.type
        )

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
            rateB: timeStretch.rateB
        )
    }

    // MARK: - Entry Point

    struct EntryPointResult {
        let entryPoint: Double
        let beatSyncInfo: String
        let usedFallback: Bool
        let isBeatSynced: Bool
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

        guard let next = nextAnalysis, !next.hasError else {
            entryPoint = min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)
            return EntryPointResult(entryPoint: entryPoint, beatSyncInfo: "", usedFallback: true, isBeatSynced: false)
        }

        let introEndTime = next.introEndTime
        let vocalStartTime = next.vocalStartTime
        let chorusStartTime = next.chorusStartTime

        if mode == .dj {
            if introEndTime > 3 {
                entryPoint = max(0, introEndTime - config.introLeadTime)
            } else if chorusStartTime > 4 {
                entryPoint = chorusStartTime - 4
            } else if vocalStartTime > 2 {
                entryPoint = vocalStartTime - config.vocalLeadTime
            } else {
                entryPoint = min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)
                usedFallback = true
            }
        } else {
            if introEndTime > 2.5 {
                entryPoint = max(0, introEndTime - config.introLeadTime)
            } else if vocalStartTime > 1 {
                entryPoint = max(0, vocalStartTime - config.vocalLeadTime)
            } else if chorusStartTime > 4 {
                entryPoint = max(0, chorusStartTime - 4)
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
                entryPoint = max(0, chorusStartTime - (mode == .dj ? 4 : 8))
            }
        }

        // Phrasing
        if !next.phraseBoundaries.isEmpty {
            let maxAhead: Double = 16
            if let nextPhrase = next.phraseBoundaries.first(where: { $0 >= entryPoint && $0 <= entryPoint + maxAhead }) {
                entryPoint = nextPhrase
            }
        }

        // Beat matching (DJ mode only)
        if mode == .dj {
            let beatResult = applyBeatSync(
                entryPoint: entryPoint,
                currentAnalysis: currentAnalysis,
                nextAnalysis: next,
                currentPlaybackTimeA: currentPlaybackTimeA
            )
            entryPoint = beatResult.adjustedEntryPoint
            beatSyncInfo = beatResult.info
            isBeatSynced = beatResult.isSynced
        }

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
        currentPlaybackTimeA: Double?
    ) -> BeatSyncResult {
        guard let current = currentAnalysis,
              !current.hasError, !nextAnalysis.hasError,
              current.beatInterval > 0, nextAnalysis.beatInterval > 0
        else {
            return BeatSyncResult(adjustedEntryPoint: entryPoint, info: "", isSynced: false)
        }

        let beatIntervalA = current.beatInterval
        let beatIntervalB = nextAnalysis.beatInterval
        let targetBeats = nextAnalysis.downbeatTimes

        var adjustedEntryPoint = entryPoint
        var info = ""

        // Phase 1: Align B to its own downbeat/measure grid
        if !targetBeats.isEmpty {
            let nearest = targetBeats.min(by: { abs($0 - entryPoint) < abs($1 - entryPoint) }) ?? entryPoint
            let rawAdj = nearest - entryPoint
            let adj = max(-beatIntervalB, min(beatIntervalB, rawAdj))
            adjustedEntryPoint = entryPoint + adj
            info = "Downbeat real: \(adj >= 0 ? "+" : "")\(String(format: "%.3f", adj))s"
        } else {
            let measureB = beatIntervalB * 4
            let timeIntoMeasure = entryPoint.truncatingRemainder(dividingBy: measureB)
            var rawAdj: Double = 0
            if timeIntoMeasure > measureB * 0.1 {
                rawAdj = measureB - timeIntoMeasure
            } else if timeIntoMeasure > 0.001 {
                rawAdj = -timeIntoMeasure
            }
            let adj = max(-beatIntervalB, min(beatIntervalB, rawAdj))
            adjustedEntryPoint = entryPoint + adj
            info = "Estimacion 4-beats: \(adj >= 0 ? "+" : "")\(String(format: "%.3f", adj))s"
        }

        // Phase 2: Cross-phase alignment A↔B
        if let playbackA = currentPlaybackTimeA, playbackA > 0 {
            let beatFractionA = playbackA.truncatingRemainder(dividingBy: beatIntervalA) / beatIntervalA
            let targetPhaseOffsetB = beatFractionA * beatIntervalB
            let currentPhaseB = adjustedEntryPoint.truncatingRemainder(dividingBy: beatIntervalB)
            var phaseError = targetPhaseOffsetB - currentPhaseB
            if phaseError > beatIntervalB / 2 { phaseError -= beatIntervalB }
            if phaseError < -beatIntervalB / 2 { phaseError += beatIntervalB }

            if abs(phaseError) > beatIntervalB * 0.10 {
                let phaseAdj = max(-beatIntervalB, min(beatIntervalB, phaseError))
                adjustedEntryPoint += phaseAdj
                info += " + fase A↔B: \(phaseAdj >= 0 ? "+" : "")\(String(format: "%.3f", phaseAdj))s"
            }
        }

        return BeatSyncResult(adjustedEntryPoint: adjustedEntryPoint, info: info, isSynced: true)
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
        mode: MixMode
    ) -> FadeDurationResult {
        let config = configs[mode]!
        var fadeDuration = config.baseFadeDuration
        var decision = "Usando duracion base (\(fadeDuration)s)."

        let hasCurrent = currentAnalysis != nil && currentAnalysis?.hasError == false
        let hasNext = nextAnalysis != nil && nextAnalysis?.hasError == false

        if hasCurrent, hasNext, let current = currentAnalysis, let next = nextAnalysis {
            let introB = next.introEndTime
            let vocalB = next.vocalStartTime
            let energyA = current.energy
            let energyB = next.energy

            let keyA = current.key
            let keyB = next.key
            let isClash = harmonicPenalty(keyA: keyA, keyB: keyB).isClash

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
                fadeDuration = mode == .dj ? 5 : 6
                decision = "Duración extendida por canción abrupta: \(fadeDuration)s."
            }

            // Energy flow dropdown
            if energyB < energyA - 0.25 && hasValidOutro && outroADuration > 12 {
                fadeDuration = min(15, max(fadeDuration, outroADuration * 0.9))
                decision += " Extendido por caida de energia a \(String(format: "%.2f", fadeDuration))s."
            }

            // Harmonic clash
            if isClash {
                fadeDuration = max(2, fadeDuration * 0.75)
                decision += " Reducido 25% por clash armonico a \(String(format: "%.2f", fadeDuration))s."
            }
        } else {
            if bufferADuration < 30 || nextAnalysis == nil {
                fadeDuration = 3
                decision = "Duracion corta de seguridad: \(fadeDuration)s."
            }
        }

        // Absolute max: 25% of the shorter track
        let absoluteMax = min(bufferADuration * 0.25, bufferBDuration * 0.25)
        if fadeDuration > absoluteMax {
            fadeDuration = max(2, absoluteMax)
            decision += " Acortado por limite 25% a \(String(format: "%.2f", fadeDuration))s."
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

        let energyA = (currentAnalysis?.hasError != true) ? (currentAnalysis?.energy ?? 0.5) : 0.5
        let energyB = (nextAnalysis?.hasError != true) ? (nextAnalysis?.energy ?? 0.5) : 0.5
        let bpmA = (currentAnalysis?.hasError != true) ? (currentAnalysis?.bpm ?? 120) : 120
        let bpmB = (nextAnalysis?.hasError != true) ? (nextAnalysis?.bpm ?? 120) : 120

        let keyA = currentAnalysis?.key
        let keyB = nextAnalysis?.key
        let isClash = harmonicPenalty(keyA: keyA, keyB: keyB).isClash

        let energyDiff = abs(energyA - energyB)
        let bpmDiff = abs(bpmA - bpmB)
        let isVeryShort = fadeDuration < 3
        let isShort = fadeDuration < 4

        let useFilters = hasVocalsOutro || hasVocalsIntro ||
            energyDiff > 0.3 || bpmDiff > 20 || isClash || isVeryShort

        let useAggressive = (hasVocalsOutro || hasVocalsIntro || isShort || isClash) && useFilters

        var reasons: [String] = []
        if hasVocalsOutro || hasVocalsIntro { reasons.append("voces") }
        if energyDiff > 0.3 { reasons.append("energia \(Int(energyDiff * 100))%") }
        if bpmDiff > 20 { reasons.append("BPM ±\(Int(bpmDiff))") }
        if isClash { reasons.append("clash tonal") }
        if isVeryShort { reasons.append("fade<3s") }

        let reason = useFilters ? "Filtros ON: \(reasons.joined(separator: ", "))" : "Filtros OFF: mezcla simple"

        return FilterDecisionResult(
            useFilters: useFilters, useAggressiveFilters: useAggressive,
            energyDiff: energyDiff, bpmDiff: bpmDiff, reason: reason
        )
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

        // Safety: extreme BPM jump
        let bpmA = currentAnalysis?.bpm ?? 120
        let bpmB = nextAnalysis?.bpm ?? 120
        if abs(bpmA - bpmB) > 15 && !isBeatSynced && fadeDuration > 3 {
            type = .cut
            reason = "Polirritmia evitada (A:\(Int(bpmA)) B:\(Int(bpmB))) → CUT forzado"
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
        let bpmB = (nextAnalysis?.hasError != true) ? (nextAnalysis?.bpm ?? 0) : 0

        // Need valid BPMs from both songs
        guard bpmA > 50 && bpmA < 250 && bpmB > 50 && bpmB < 250 else {
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: BPM fuera de rango o desconocido")
        }

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

    struct HarmonicPenalty {
        let distance: Int
        let isClash: Bool
    }

    static func harmonicPenalty(keyA: String?, keyB: String?) -> HarmonicPenalty {
        guard let keyA, let keyB else { return HarmonicPenalty(distance: 0, isClash: false) }

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
        else { return HarmonicPenalty(distance: 0, isClash: false) }

        let letterA = keyA[letterRangeA].uppercased()
        let letterB = keyB[letterRangeB].uppercased()

        let diffNum = min(abs(numA - numB), 12 - abs(numA - numB))
        let diffLetter = letterA != letterB ? 1 : 0

        let totalDistance = diffNum + diffLetter
        let isClash = totalDistance > 2 || (diffLetter == 1 && totalDistance > 1)

        return HarmonicPenalty(distance: totalDistance, isClash: isClash)
    }
}
