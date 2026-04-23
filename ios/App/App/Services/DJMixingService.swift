// ╔══════════════════════════════════════════════════════════════════════╗
// ║                                                                      ║
// ║   DJMixingService — "Crossfade Intelligence Engine" v4.0             ║
// ║   Codename: "Chameleon Mix"                                          ║
// ║                                                                      ║
// ║   Audiorr — Audiophile-grade music player                            ║
// ║   Copyright (c) 2025-2026 cha0sisme (github.com/cha0sisme)          ║
// ║                                                                      ║
// ║   Pure crossfade intelligence — no side effects, no audio playback.  ║
// ║   Analyzes the RELATIONSHIP between any two tracks to decide         ║
// ║   the optimal transition. The same song B will sound different       ║
// ║   depending on what song A precedes it — like a chameleon adapting   ║
// ║   to its context.                                                     ║
// ║                                                                      ║
// ║   v1.0 — JS DJMixingAlgorithms.ts (basic crossfade + beat sync)     ║
// ║   v2.0 — Velvet Transition: equal-power curves, bass swap,           ║
// ║          harmonic BPM detection (half/double tempo), 4-level          ║
// ║          harmonic compatibility, energy compensation, lowpass sweep, ║
// ║          beat-aligned bass swap on downbeats, time-stretch with       ║
// ║          beat-quantized rate ramp, vocal trainwreck detection,       ║
// ║          forced bass management for BEAT_MATCH_BLEND/EQ_MIX          ║
// ║   v3.0 — Phantom Cut: structural fade anchoring (idealFade =         ║
// ║          entryPoint), skipBFilters for short fades/outros,            ║
// ║          phrase/downbeat trigger snapping, PeakLimiter + stereo      ║
// ║          micro-separation in executor                                 ║
// ║   v4.0 — Chameleon Mix: TransitionProfile captures the A↔B           ║
// ║          relationship as a unit. Entry point, fade, filters, and      ║
// ║          transition type all derive from the pairing — the same       ║
// ║          song transitions differently in a Pop mix vs Hip Hop mix.   ║
// ║          Outro-anchored triggers (DJ exits at outro, not at end).    ║
// ║          Calibrated energy thresholds (danceability-aware).           ║
// ║          Conservative harmonic BPM (half/double only, 6% max stretch)║
// ║                                                                      ║
// ╚══════════════════════════════════════════════════════════════════════╝

import Foundation

/// DJMixingService v4.0 "Relational Mix" — pure crossfade intelligence calculations.
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
        case stemMix = "STEM_MIX"
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
        var danceability: Double = 0.5
        var key: String?
        var outroStartTime: Double = 0
        var introEndTime: Double = 0
        var vocalStartTime: Double = 0
        var chorusStartTime: Double = 0
        var phraseBoundaries: [Double] = []
        var downbeatTimes: [Double] = []
        var speechSegments: [(start: Double, end: Double)] = []
        var hasError: Bool = false
        var hasOutroData: Bool = false
        var hasIntroData: Bool = false
        var cuePoint: Double = 0
        var hasCuePoint: Bool = false
        var energyIntro: Double = 0
        var energyMain: Double = 0
        var energyOutro: Double = 0
        var hasEnergyProfile: Bool = false
        var hasIntroVocals: Bool = false
        var hasOutroVocals: Bool = false
        var hasVocalData: Bool = false
        var backendFadeInDuration: Double?
        var backendFadeOutDuration: Double?
        var backendFadeOutLeadTime: Double?
        var lastVocalTime: Double = 0
        var hasVocalEndData: Bool = false
        // BPM confidence system (Essentia cross-validation)
        var bpmConfidence: Double = 1.0   // 0-1, default 1.0 (trust) when backend doesn't provide
        var bpmEssentia: Double?          // second opinion from Essentia
        var hasBpmConfidence: Bool = false // true when backend provided bpmConfidence
        // ML override tracking
        var modelUsed: Bool = false       // true when ML overrode intro/outro values
        var introEndTimeHeuristic: Double? // heuristic value (before ML override)
        var outroStartTimeHeuristic: Double? // heuristic value (before ML override)
    }

    // MARK: - Transition Profile (A↔B Relationship)

    enum BPMRelationship {
        case identical      // diff < 3 after harmonic normalization
        case compatible     // diff 3-12 (stretchable)
        case incompatible   // diff > 12 (no beat match)
    }

    enum EnergyFlow {
        case energyUp       // B intro > A outro + 0.15
        case energyDown     // B intro < A outro - 0.15
        case steady         // within ±0.15
    }

    enum VocalOverlapRisk {
        case none           // neither has vocals in overlap zone
        case aOnly          // A has outro vocals, B intro instrumental
        case bOnly          // B has intro vocals, A outro instrumental
        case both           // vocal trainwreck risk
    }

    enum TransitionCharacter {
        case punch          // target structural moment in B (compatible BPMs, good energy)
        case smooth         // invisible blend, B starts early (incompatible BPMs)
        case dramatic       // big energy change, needs special handling
        case minimal        // both low energy, gentle handoff
    }

    /// Captures the full A↔B relationship. Computed ONCE, drives ALL downstream decisions.
    struct TransitionProfile {
        // ── Energy relationship ──
        let energyA: Double
        let energyB: Double
        let energyGap: Double       // signed: positive = B is hotter
        let energyFlow: EnergyFlow

        // ── Rhythm relationship ──
        let bpmA: Double
        let bpmB: Double            // raw
        let bpmBNormalized: Double  // after harmonic normalization
        let bpmDiff: Double         // abs(bpmA - bpmBNormalized)
        let bpmRelationship: BPMRelationship
        /// True when BOTH songs have confident BPM (≥0.5).
        /// When false, BPM-dependent decisions (beat sync, time-stretch) should be conservative.
        let bpmTrusted: Bool

        // ── Harmonic relationship ──
        let harmonic: HarmonicPenalty

        // ── Vocal relationship ──
        let vocalOverlapRisk: VocalOverlapRisk
        let aHasOutroVocals: Bool
        let bHasIntroVocals: Bool

        // ── Groove/style relationship ──
        let danceabilityA: Double
        let danceabilityB: Double
        let avgDanceability: Double
        let bassConflictRisk: Bool  // both high danceability = bass overlap

        // ── High-level character derived from the relationship ──
        let character: TransitionCharacter

        /// 0-1: how stylistically similar A and B appear.
        /// Inferred from BPM range, energy range, danceability correlation.
        /// High = same "world" (both EDM, both chill). Low = genre jump.
        let styleAffinity: Double

        let mode: MixMode
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
        let useTimeStretch: Bool
        let rateA: Float
        let rateB: Float
        let energyA: Double
        let energyB: Double
        let beatIntervalA: Double
        let beatIntervalB: Double
        let downbeatTimesA: [Double]
        let downbeatTimesB: [Double]
        let useMidScoop: Bool
        let useHighShelfCut: Bool
        let isOutroInstrumental: Bool
        let isIntroInstrumental: Bool
        let danceability: Double
        let skipBFilters: Bool
        let transitionReason: String
        /// Trigger bias: how many seconds earlier (negative) or later (positive) the trigger
        /// should fire relative to the default "latest possible" position.
        /// Driven by the A↔B relationship:
        ///   - minimal/smooth character → negative (trigger earlier for longer, invisible blend)
        ///   - punch character → 0 or positive (trigger late for maximum impact)
        ///   - bass conflict → negative (trigger earlier to give filters time to clean)
        ///   - energy-down → negative (start earlier for graceful descent)
        let triggerBias: Double
        /// Human-readable reason for the trigger bias.
        let triggerBiasReason: String
    }

    // MARK: - Build Transition Profile

    /// Analyzes the A↔B relationship and produces a unified profile that drives all decisions.
    /// Called ONCE at the top of calculateCrossfadeConfig.
    private static func buildTransitionProfile(
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        mode: MixMode,
        bufferADuration: Double,
        bufferBDuration: Double
    ) -> TransitionProfile {
        let hasCurrent = currentAnalysis != nil && currentAnalysis?.hasError != true
        let hasNext = nextAnalysis != nil && nextAnalysis?.hasError != true

        // ── Energy (per-section preferred) ──
        let eA: Double
        if let cur = currentAnalysis, hasCurrent, cur.hasEnergyProfile {
            eA = cur.energyOutro
        } else {
            eA = hasCurrent ? (currentAnalysis?.energy ?? 0.5) : 0.5
        }
        let eB: Double
        if let nxt = nextAnalysis, hasNext, nxt.hasEnergyProfile {
            eB = nxt.energyIntro
        } else {
            eB = hasNext ? (nextAnalysis?.energy ?? 0.5) : 0.5
        }
        let gap = eB - eA
        let flow: EnergyFlow
        if gap > 0.15 { flow = .energyUp }
        else if gap < -0.15 { flow = .energyDown }
        else { flow = .steady }

        // ── BPM (with confidence system) ──
        let bA = hasCurrent ? (currentAnalysis?.bpm ?? 120) : 120
        let bB = hasNext ? (nextAnalysis?.bpm ?? 120) : 120
        let bBNorm = harmonicBPM(bA, bB)
        let diff = abs(bA - bBNorm)
        let bpmRel: BPMRelationship
        if diff < 3 { bpmRel = .identical }
        else if diff <= 12 { bpmRel = .compatible }
        else { bpmRel = .incompatible }

        // BPM confidence: both songs must have confidence ≥ 0.5 for trusted BPM decisions.
        // When untrusted, time-stretch and aggressive beat sync should be disabled.
        let confA = currentAnalysis?.bpmConfidence ?? 1.0
        let confB = nextAnalysis?.bpmConfidence ?? 1.0
        let trusted = confA >= 0.5 && confB >= 0.5
        if !trusted {
            let lowConf = confA < 0.5 ? "A" : "B"
            let val = confA < 0.5 ? confA : confB
            print("[DJMixingService] ⚠️ BPM untrusted (\(lowConf) confidence=\(String(format: "%.2f", val))) — conservative beat decisions")
        }

        // ── Harmonic ──
        let harm = harmonicPenalty(keyA: currentAnalysis?.key, keyB: nextAnalysis?.key)

        // ── Vocal overlap (conservative estimate: A's last ~15s, B's first ~20s) ──
        let conservativeCrossfadeZoneA = max(0, bufferADuration - 15)
        let conservativeBEnd: Double = 20

        let aVocals: Bool
        if let cur = currentAnalysis, hasCurrent {
            if cur.hasVocalData && cur.hasOutroVocals {
                aVocals = true
            } else if cur.hasVocalEndData {
                aVocals = cur.lastVocalTime > conservativeCrossfadeZoneA
            } else if !cur.speechSegments.isEmpty {
                aVocals = cur.speechSegments.contains { $0.end > conservativeCrossfadeZoneA }
            } else {
                aVocals = cur.vocalStartTime > 0 &&
                    (cur.outroStartTime <= 0 || cur.outroStartTime > conservativeCrossfadeZoneA)
            }
        } else { aVocals = false }

        let bVocals: Bool
        if let nxt = nextAnalysis, hasNext {
            if nxt.hasVocalData && nxt.hasIntroVocals {
                bVocals = true
            } else if !nxt.speechSegments.isEmpty {
                bVocals = nxt.speechSegments.contains { $0.start < conservativeBEnd }
            } else {
                bVocals = nxt.vocalStartTime > 0 && nxt.vocalStartTime < conservativeBEnd
            }
        } else { bVocals = false }

        let vocalRisk: VocalOverlapRisk
        switch (aVocals, bVocals) {
        case (true, true):   vocalRisk = .both
        case (true, false):  vocalRisk = .aOnly
        case (false, true):  vocalRisk = .bOnly
        case (false, false): vocalRisk = .none
        }

        // ── Danceability / bass conflict ──
        let dA = hasCurrent ? (currentAnalysis?.danceability ?? 0.5) : 0.5
        let dB = hasNext ? (nextAnalysis?.danceability ?? 0.5) : 0.5
        let avgDance = (dA + dB) / 2.0
        let bassConflict = dA > 0.65 && dB > 0.65

        // ── Style affinity (0-1) ──
        // How "similar" the two songs are stylistically. Inferred from BPM, energy, danceability.
        // Songs in the same BPM bracket, similar energy, similar danceability = same "world".
        let bpmAffinity = max(0, 1.0 - diff / 30.0)                   // 0 diff = 1.0, 30+ diff = 0
        let energyAffinity = max(0, 1.0 - abs(gap) / 0.6)             // 0 gap = 1.0, 0.6+ gap = 0
        let danceAffinity = max(0, 1.0 - abs(dA - dB) / 0.5)          // 0 diff = 1.0, 0.5+ = 0
        let harmonicAffinity: Double
        switch harm.compatibility {
        case .compatible: harmonicAffinity = 1.0
        case .acceptable: harmonicAffinity = 0.7
        case .tense:      harmonicAffinity = 0.4
        case .clash:      harmonicAffinity = 0.1
        }
        // Weighted: BPM matters most (genre identifier), then energy, then harmony, then danceability
        let affinity = min(1.0, max(0,
            bpmAffinity * 0.35 + energyAffinity * 0.25 + harmonicAffinity * 0.25 + danceAffinity * 0.15
        ))

        // ── Character: what kind of transition does this pairing call for? ──
        // NOTE: Backend energy values are compressed (most music falls 0.05-0.30).
        // "Minimal" should only apply to truly ambient/quiet tracks, not to
        // Kanye, Bruno Mars, Bad Bunny etc. that happen to have low RMS energy.
        // Danceability is a strong signal: high danceability = NOT minimal.
        let character: TransitionCharacter
        if mode != .dj {
            character = .smooth
        } else if eA < 0.15 && eB < 0.15 && avgDance < 0.5 {
            // Truly ambient/quiet: both very low energy AND low danceability
            character = .minimal
        } else if abs(gap) > 0.35 || harm.compatibility == .clash {
            character = .dramatic
        } else if bpmRel != .incompatible && affinity > 0.4 {
            character = .punch
        } else {
            character = .smooth
        }

        let profile = TransitionProfile(
            energyA: eA, energyB: eB, energyGap: gap, energyFlow: flow,
            bpmA: bA, bpmB: bB, bpmBNormalized: bBNorm, bpmDiff: diff,
            bpmRelationship: bpmRel, bpmTrusted: trusted,
            harmonic: harm,
            vocalOverlapRisk: vocalRisk, aHasOutroVocals: aVocals, bHasIntroVocals: bVocals,
            danceabilityA: dA, danceabilityB: dB, avgDanceability: avgDance,
            bassConflictRisk: bassConflict,
            character: character,
            styleAffinity: affinity,
            mode: mode
        )

        print("[DJMixingService] 🎛️ Profile: character=\(character) affinity=\(String(format: "%.2f", affinity)) " +
              "energy=\(String(format: "%.2f→%.2f", eA, eB)) flow=\(flow) " +
              "bpm=\(Int(bA))→\(Int(bB))(norm:\(Int(bBNorm))) rel=\(bpmRel) trusted=\(trusted) " +
              "vocal=\(vocalRisk) harmonic=\(harm.compatibility) bassConflict=\(bassConflict)")

        return profile
    }

    // MARK: - Main Entry Point

    /// Calculate full crossfade configuration.
    static func calculateCrossfadeConfig(
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        bufferADuration: Double,
        bufferBDuration: Double,
        mode: MixMode,
        currentPlaybackTimeA: Double? = nil,
        userFadeDuration: Double? = nil
    ) -> CrossfadeResult {
        let safeCurrent = currentAnalysis.map { sanitize($0, duration: bufferADuration) }
        let safeNext = nextAnalysis.map { sanitize($0, duration: bufferBDuration) }

        // ── 1. Build relationship profile (computed ONCE, drives everything) ──
        let profile = buildTransitionProfile(
            currentAnalysis: safeCurrent,
            nextAnalysis: safeNext,
            mode: mode,
            bufferADuration: bufferADuration,
            bufferBDuration: bufferBDuration
        )

        // ── 2. Entry point (where B starts playing) — driven by profile ──
        let entry = calculateSmartEntryPoint(
            nextAnalysis: safeNext,
            currentAnalysis: safeCurrent,
            bufferDuration: bufferBDuration,
            profile: profile,
            currentPlaybackTimeA: currentPlaybackTimeA
        )

        // ── 3. Fade duration — driven by profile ──
        let fade = calculateAdaptiveFadeDuration(
            entryPoint: entry.entryPoint,
            bufferADuration: bufferADuration,
            bufferBDuration: bufferBDuration,
            currentAnalysis: safeCurrent,
            nextAnalysis: safeNext,
            profile: profile,
            userFadeDuration: userFadeDuration
        )

        // ── 4. Filter decisions — driven by profile ──
        let filter = decideFilterUsage(profile: profile, fadeDuration: fade.duration)

        // ── 5. Anticipation ──
        let anticipation = decideAnticipation(fadeDuration: fade.duration, entryPoint: entry.entryPoint)

        // ── 6. DJ-grade filters (mid scoop + high shelf) — refined with actual fade zone ──
        let djFilters = decideDJFilters(
            currentAnalysis: safeCurrent,
            nextAnalysis: safeNext,
            profile: profile,
            fadeDuration: fade.duration,
            entryPoint: entry.entryPoint,
            bufferADuration: bufferADuration
        )

        // ── 7. Transition type — driven by profile ──
        let transition = decideTransitionType(
            currentAnalysis: safeCurrent,
            nextAnalysis: safeNext,
            profile: profile,
            entryPoint: entry.entryPoint,
            fadeDuration: fade.duration,
            isBeatSynced: entry.isBeatSynced,
            useFilters: filter.useFilters,
            bufferADuration: bufferADuration,
            hasVocalOverlap: djFilters.useMidScoop
        )

        // ── 8. Time-stretch ──
        let timeStretch = decideTimeStretch(profile: profile, transitionType: transition.type)
        print("[DJMixingService] \(timeStretch.useTimeStretch ? "⚡ TIME-STRETCH ACTIVE" : "Time-stretch OFF"): \(timeStretch.reason)")

        // ── Beat grid (adjusted for time-stretch) ──
        let biA = (safeCurrent?.hasError != true) ? (safeCurrent?.beatInterval ?? 0) : 0
        let rawBiB = (safeNext?.hasError != true) ? (safeNext?.beatInterval ?? 0) : 0
        let biB = timeStretch.useTimeStretch && timeStretch.rateB > 0
            ? rawBiB / Double(timeStretch.rateB) : rawBiB
        let dbA = (safeCurrent?.hasError != true) ? (safeCurrent?.downbeatTimes ?? []) : []
        let rawDbB = (safeNext?.hasError != true) ? (safeNext?.downbeatTimes ?? []) : []
        let dbB: [Double] = timeStretch.useTimeStretch && timeStretch.rateB > 0
            ? rawDbB.map { $0 / Double(timeStretch.rateB) } : rawDbB

        // ── Instrumental detection (refined with actual fade zone) ──
        let outroInstrumental = detectOutroInstrumental(
            currentAnalysis: safeCurrent, profile: profile,
            bufferADuration: bufferADuration, fadeDuration: fade.duration
        )
        let introInstrumental = detectIntroInstrumental(
            nextAnalysis: safeNext, profile: profile,
            entryPoint: entry.entryPoint, fadeDuration: fade.duration
        )

        // Only skip B filters for very short fades where there's no time for a sweep
        let skipBFilters = fade.duration <= 3.0

        // ── 9. Trigger bias — how much earlier/later A should start the crossfade ──
        let trigger = calculateTriggerBias(profile: profile, fadeDuration: fade.duration)

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
            energyA: profile.energyA,
            energyB: profile.energyB,
            beatIntervalA: biA,
            beatIntervalB: biB,
            downbeatTimesA: dbA,
            downbeatTimesB: dbB,
            useMidScoop: djFilters.useMidScoop,
            useHighShelfCut: djFilters.useHighShelfCut,
            isOutroInstrumental: outroInstrumental,
            isIntroInstrumental: introInstrumental,
            danceability: profile.avgDanceability,
            skipBFilters: skipBFilters,
            transitionReason: transition.reason,
            triggerBias: trigger.bias,
            triggerBiasReason: trigger.reason
        )
    }

    // MARK: - Entry Point

    struct EntryPointResult {
        let entryPoint: Double
        let beatSyncInfo: String
        let usedFallback: Bool
        let isBeatSynced: Bool
    }

    /// Calculate where B starts playing. Driven by the A↔B relationship profile.
    /// The same song B will get different entry points depending on what A precedes it.
    static func calculateSmartEntryPoint(
        nextAnalysis: SongAnalysis?,
        currentAnalysis: SongAnalysis?,
        bufferDuration: Double,
        profile: TransitionProfile,
        currentPlaybackTimeA: Double? = nil
    ) -> EntryPointResult {
        let config = configs[profile.mode]!

        var entryPoint: Double = 0
        var beatSyncInfo = ""
        var usedFallback = false
        var isBeatSynced = false

        guard let rawNext = nextAnalysis, !rawNext.hasError else {
            entryPoint = min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)
            return EntryPointResult(entryPoint: entryPoint, beatSyncInfo: "", usedFallback: true, isBeatSynced: false)
        }

        let next = sanitize(rawNext, duration: bufferDuration)

        // ── Character-driven entry strategy ──
        switch profile.character {
        case .minimal:
            // Both low energy — very early entry, invisible handoff.
            // No structural targeting at all. B plays from the beginning.
            let earlyEntry = min(2.0, bufferDuration * config.fallbackPercent)
            entryPoint = max(0, earlyEntry)
            print("[DJMixingService] 🌙 Minimal: entry=\(String(format: "%.1f", entryPoint))s (both low energy, gentle handoff)")
            return EntryPointResult(entryPoint: entryPoint, beatSyncInfo: "Minimal (low energy)", usedFallback: false, isBeatSynced: false)

        case .smooth:
            // Incompatible BPMs or low style affinity — no punch targeting.
            // But still skip past boring instrumental intros (guitars, ambient pads)
            // so the listener hears the song's "real start."
            let baseEntry = min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)

            // Prefer entering after the intro if the intro is long enough to matter
            if next.hasIntroData && next.introEndTime > baseEntry + 3 {
                entryPoint = next.introEndTime
            } else if next.chorusStartTime > baseEntry + 3 && next.chorusStartTime < 25 {
                // Chorus as fallback when intro data isn't useful
                entryPoint = next.chorusStartTime
            } else {
                entryPoint = baseEntry
            }
            entryPoint = max(0, min(entryPoint, bufferDuration - 1))
            print("[DJMixingService] 🌊 Smooth: entry=\(String(format: "%.1f", entryPoint))s (introEnd=\(String(format: "%.1f", next.introEndTime))s, affinity=\(String(format: "%.2f", profile.styleAffinity)))")
            return EntryPointResult(entryPoint: entryPoint, beatSyncInfo: "Smooth blend", usedFallback: false, isBeatSynced: false)

        case .dramatic:
            // Big energy change or harmonic clash — entry strategy depends on direction.
            entryPoint = calculateDramaticEntry(next: next, profile: profile, bufferDuration: bufferDuration, config: config)

        case .punch:
            // Compatible BPMs, good style affinity — target a structural moment.
            entryPoint = calculatePunchEntry(next: next, profile: profile, bufferDuration: bufferDuration, config: config)
        }

        // ── Phrase snapping (punch + dramatic only, not smooth/minimal) ──
        if !next.phraseBoundaries.isEmpty {
            let maxAhead: Double = profile.character == .dramatic ? 8 : 16
            if let nextPhrase = next.phraseBoundaries.first(where: { $0 >= entryPoint && $0 <= entryPoint + maxAhead }) {
                entryPoint = nextPhrase
            }
        }

        // ── Beat sync (only when BPMs are compatible AND trusted) ──
        if profile.bpmRelationship != .incompatible && profile.bpmTrusted {
            let beatResult = applyBeatSync(
                entryPoint: entryPoint,
                currentAnalysis: currentAnalysis,
                nextAnalysis: next,
                currentPlaybackTimeA: currentPlaybackTimeA,
                mode: profile.mode
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

    /// Entry for `.dramatic` character — big energy changes or harmonic clash.
    private static func calculateDramaticEntry(
        next: SongAnalysis,
        profile: TransitionProfile,
        bufferDuration: Double,
        config: MixModeConfig
    ) -> Double {
        let introEnd = next.introEndTime
        let vocalStart = next.vocalStartTime
        let chorusStart = next.chorusStartTime

        switch profile.energyFlow {
        case .energyUp:
            // Energy rising (A chill → B hot): prefer chorus or vocalStart for impact.
            // The dramatic energy jump benefits from landing on a strong moment.
            if chorusStart > 4 && chorusStart < bufferDuration * 0.4 {
                print("[DJMixingService] 🔥 Dramatic UP: chorus entry at \(String(format: "%.1f", chorusStart))s")
                return chorusStart
            } else if vocalStart > 3 {
                print("[DJMixingService] 🔥 Dramatic UP: vocal entry at \(String(format: "%.1f", vocalStart))s")
                return vocalStart
            } else if next.hasIntroData && introEnd > 3 {
                return introEnd
            } else {
                return min(config.fallbackMaxSeconds, bufferDuration * 0.03)
            }

        case .energyDown:
            // Energy dropping (A hot → B chill): early entry, let B build gradually.
            // Don't punch — B needs space to breathe as A's energy fades.
            let earlyEntry = min(4.0, bufferDuration * 0.02)
            print("[DJMixingService] 🌅 Dramatic DOWN: early entry at \(String(format: "%.1f", earlyEntry))s (energy dropping)")
            return earlyEntry

        case .steady:
            // Harmonic clash with steady energy: moderate entry, avoid extending overlap.
            if vocalStart > 3 {
                return vocalStart
            } else if next.hasIntroData && introEnd > 3 {
                return introEnd
            } else {
                return min(config.fallbackMaxSeconds, bufferDuration * 0.02)
            }
        }
    }

    /// Entry for `.punch` character — compatible BPMs, targeting a structural moment in B.
    private static func calculatePunchEntry(
        next: SongAnalysis,
        profile: TransitionProfile,
        bufferDuration: Double,
        config: MixModeConfig
    ) -> Double {
        let introEnd = next.introEndTime
        let vocalStart = next.vocalStartTime
        let chorusStart = next.chorusStartTime

        // Cross-validate intro/vocal timing
        let hasReliableIntro = next.hasIntroData && introEnd > 3
        let introVocalDiverge: Bool = {
            guard hasReliableIntro, vocalStart > 0 else { return false }
            return vocalStart < introEnd - 8
        }()

        if introVocalDiverge {
            print("[DJMixingService] ⚠️ Entry confidence low: introEnd=\(String(format: "%.1f", introEnd))s but vocalStart=\(String(format: "%.1f", vocalStart))s (diverge >8s)")
        }

        var entry: Double

        // ── Cross-validate vocalStartTime against early speech/vocal data ──
        // If speech segments show vocals in the first 10s, but backend says vocalStart is
        // way later, the backend value is unreliable (it may be detecting a different vocal
        // section, not the first occurrence). Only trust vocalStart for entry logic when
        // the intro is genuinely instrumental.
        let hasEarlyVocals = next.hasIntroVocals ||
            next.speechSegments.contains(where: { $0.start < 10 })
        let introIsInstrumental = !hasEarlyVocals
        // vocalStart is only reliable for "enter before vocals" if the intro is truly
        // instrumental, OR if the value is reasonably small (< 20s).
        let vocalStartReliable = vocalStart > 0 && (introIsInstrumental || vocalStart < 20)

        // ── Vocal overlap avoidance: if both songs have vocals, prefer entering B
        // at an instrumental section so A's vocals can fade before B's vocals start ──
        // ONLY when the intro is confirmed instrumental — if B already has vocals in the
        // intro, there is no clean instrumental window and this strategy produces wrong
        // entry points deep into the song.
        if profile.vocalOverlapRisk == .both && vocalStart > 3
            && introIsInstrumental && vocalStartReliable {
            let safeEntry = max(0, vocalStart - 6)
            if safeEntry > 2 {
                print("[DJMixingService] 🎤 Punch w/ vocal avoidance: entry=\(String(format: "%.1f", safeEntry))s (vocals at \(String(format: "%.1f", vocalStart))s)")
                return safeEntry
            }
        }

        // ── Style affinity modulates how aggressively we target ──
        // High affinity (>0.7): same genre feel — aggressive targeting (chorus, introEnd)
        // Medium affinity (0.4-0.7): compatible — moderate targeting (vocalStart, introEnd)
        // Low affinity (<0.4): would have been .smooth, shouldn't reach here

        if profile.styleAffinity > 0.7 {
            // Same "world" — go for the most impactful entry
            if vocalStartReliable && vocalStart > 3 && !introVocalDiverge {
                entry = vocalStart
            } else if hasReliableIntro && !introVocalDiverge {
                entry = introEnd
            } else if chorusStart > 4 {
                entry = chorusStart
            } else if vocalStartReliable && vocalStart > 2 {
                entry = vocalStart
            } else if hasReliableIntro {
                entry = introEnd
            } else {
                entry = min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)
            }
        } else {
            // Moderate affinity — less aggressive, prefer introEnd over chorus
            if hasReliableIntro && !introVocalDiverge {
                entry = introEnd
            } else if vocalStartReliable && vocalStart > 3 && !introVocalDiverge {
                entry = vocalStart
            } else if vocalStartReliable && vocalStart > 2 {
                entry = vocalStart
            } else if hasReliableIntro {
                entry = introEnd
            } else {
                entry = min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)
            }
        }

        // ── Energy boost: rising energy → prefer chorus if nearby ──
        if profile.energyFlow == .energyUp && profile.energyGap > 0.25 {
            if chorusStart > entry && chorusStart < entry + 30 {
                entry = chorusStart
            }
        }

        return entry
    }

    // MARK: - Sanitize

    private static func sanitize(_ analysis: SongAnalysis, duration: Double) -> SongAnalysis {
        var a = analysis
        let maxT = max(0, duration)

        a.introEndTime = min(max(0, a.introEndTime), maxT)
        a.outroStartTime = min(max(0, a.outroStartTime), maxT)
        a.vocalStartTime = min(max(0, a.vocalStartTime), maxT)
        a.chorusStartTime = min(max(0, a.chorusStartTime), maxT)
        if a.hasCuePoint { a.cuePoint = min(max(0, a.cuePoint), maxT) }
        if a.hasVocalEndData { a.lastVocalTime = min(max(0, a.lastVocalTime), maxT) }
        a.phraseBoundaries = a.phraseBoundaries.filter { $0 >= 0 && $0 <= maxT }
        a.downbeatTimes = a.downbeatTimes.filter { $0 >= 0 && $0 <= maxT }
        a.speechSegments = a.speechSegments.compactMap { seg in
            let s = max(0, seg.start)
            let e = min(maxT, seg.end)
            return s < e ? (start: s, end: e) : nil
        }

        if a.bpm < 30 || a.bpm > 300 { a.bpm = 120 }
        a.energy = min(max(0, a.energy), 1)
        if a.hasEnergyProfile {
            a.energyIntro = min(max(0, a.energyIntro), 1)
            a.energyMain = min(max(0, a.energyMain), 1)
            a.energyOutro = min(max(0, a.energyOutro), 1)
        }

        if a.hasOutroData && a.hasVocalEndData
            && a.lastVocalTime > a.outroStartTime + 3 {
            print("[DJMixingService] ⚠️ Sanitize: lastVocal (\(String(format: "%.1f", a.lastVocalTime))s) > outroStart (\(String(format: "%.1f", a.outroStartTime))s) — adjusting outro to vocal end")
            a.outroStartTime = a.lastVocalTime
        }

        // ── 1. ML override cross-validation (FIRST — before any caps) ──
        // When the ML model overrode intro/outro values, cross-check with heuristics.
        // If ML and heuristic diverge wildly (>15s), the ML may have hallucinated — fall back to heuristic.
        // This MUST run before chorus/speechSegment/hard caps so they see the corrected value.
        if a.modelUsed {
            if let hIntro = a.introEndTimeHeuristic, a.hasIntroData {
                let mlIntro = a.introEndTime
                if abs(mlIntro - hIntro) > 15 {
                    print("[DJMixingService] ⚠️ Sanitize: ML introEnd (\(String(format: "%.1f", mlIntro))s) diverges >15s from heuristic (\(String(format: "%.1f", hIntro))s) — using heuristic")
                    a.introEndTime = hIntro
                }
            }
            if let hOutro = a.outroStartTimeHeuristic, a.hasOutroData {
                let mlOutro = a.outroStartTime
                if abs(mlOutro - hOutro) > 15 {
                    print("[DJMixingService] ⚠️ Sanitize: ML outroStart (\(String(format: "%.1f", mlOutro))s) diverges >15s from heuristic (\(String(format: "%.1f", hOutro))s) — using heuristic")
                    a.outroStartTime = hOutro
                }
            }
        }

        // ── 2. Cross-validate introEnd against structural landmarks (safety nets) ──
        // These run AFTER the ML check, so they operate on already-corrected values.

        // 2a. Chorus before introEnd: the intro must end before the chorus starts
        if a.hasIntroData && a.chorusStartTime > 4 && a.chorusStartTime < a.introEndTime - 5 {
            print("[DJMixingService] ⚠️ Sanitize: chorusStart (\(String(format: "%.1f", a.chorusStartTime))s) << introEnd (\(String(format: "%.1f", a.introEndTime))s) — capping introEnd to chorus")
            a.introEndTime = a.chorusStartTime
        }

        // 2b. Speech segments (vocals) starting well before introEnd
        if a.hasIntroData && !a.speechSegments.isEmpty {
            let earlyVocal = a.speechSegments.first(where: { $0.end - $0.start > 3 && $0.start < a.introEndTime - 5 })
            if let ev = earlyVocal {
                let cappedIntro = ev.start
                if cappedIntro < a.introEndTime - 5 && cappedIntro >= 2 {
                    print("[DJMixingService] ⚠️ Sanitize: vocal segment at \(String(format: "%.1f", ev.start))s << introEnd (\(String(format: "%.1f", a.introEndTime))s) — capping introEnd to vocal start")
                    a.introEndTime = cappedIntro
                }
            }
        }

        // 2c. Hard cap: intros > 30s are extremely rare outside ambient/classical.
        if a.hasIntroData && a.introEndTime > 30 {
            print("[DJMixingService] ⚠️ Sanitize: introEnd (\(String(format: "%.1f", a.introEndTime))s) > 30s hard cap — capping")
            a.introEndTime = min(a.introEndTime, 30)
        }

        if a.beatInterval > 0 && a.bpm > 0 {
            let bpmDerived = 60.0 / a.bpm
            if abs(a.beatInterval - bpmDerived) / bpmDerived > 0.15 {
                print("[DJMixingService] ⚠️ Sanitize: beatInterval (\(String(format: "%.3f", a.beatInterval))s) diverges >15% from BPM-derived (\(String(format: "%.3f", bpmDerived))s) — using BPM-derived")
                a.beatInterval = bpmDerived
            }
        }
        if a.beatInterval < 0.15 || a.beatInterval > 3.0 {
            a.beatInterval = a.bpm > 0 ? 60.0 / a.bpm : 0
        }

        if a.beatInterval > 0 && a.downbeatTimes.count >= 4 {
            let expectedMeasure = a.beatInterval * 4
            var spacings: [Double] = []
            for i in 1..<a.downbeatTimes.count {
                spacings.append(a.downbeatTimes[i] - a.downbeatTimes[i - 1])
            }
            spacings.sort()
            let median = spacings[spacings.count / 2]
            if abs(median - expectedMeasure) / expectedMeasure > 0.30 {
                print("[DJMixingService] ⚠️ Sanitize: downbeat spacing (\(String(format: "%.3f", median))s) diverges >30% from beatInterval*4 (\(String(format: "%.3f", expectedMeasure))s) — clearing downbeats")
                a.downbeatTimes = []
            }
        }

        a.danceability = min(max(0, a.danceability), 1)
        return a
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
        guard !nextAnalysis.hasError, nextAnalysis.beatInterval > 0 else {
            return BeatSyncResult(adjustedEntryPoint: entryPoint, info: "", isSynced: false)
        }

        let hasCurrentBeats = currentAnalysis != nil && currentAnalysis?.hasError != true
            && (currentAnalysis?.beatInterval ?? 0) > 0
        let beatIntervalA = currentAnalysis?.beatInterval ?? nextAnalysis.beatInterval
        let beatIntervalB = nextAnalysis.beatInterval
        let targetBeats = nextAnalysis.downbeatTimes

        let searchRange = beatIntervalB * 1.0

        var adjustedEntryPoint = entryPoint
        var info = ""
        var isBeatSynced = false

        // Phase 1: Align B to its nearest downbeat (tight snap)
        if !targetBeats.isEmpty {
            let candidates = targetBeats.filter { abs($0 - entryPoint) <= searchRange }
            if let best = candidates.min(by: { abs($0 - entryPoint) < abs($1 - entryPoint) }) {
                let adj = best - entryPoint
                adjustedEntryPoint = best
                isBeatSynced = true
                info = "Downbeat real: \(adj >= 0 ? "+" : "")\(String(format: "%.3f", adj))s"
            } else {
                let gridSnap = snapToMeasureGrid(entryPoint, measureLength: beatIntervalB * 4, beatInterval: beatIntervalB)
                if abs(gridSnap) <= beatIntervalB * 0.5 {
                    adjustedEntryPoint = entryPoint + gridSnap
                    isBeatSynced = true
                    info = "Grid snap: \(gridSnap >= 0 ? "+" : "")\(String(format: "%.3f", gridSnap))s"
                }
            }
        } else {
            let gridSnap = snapToMeasureGrid(entryPoint, measureLength: beatIntervalB * 4, beatInterval: beatIntervalB)
            if abs(gridSnap) <= beatIntervalB * 0.5 {
                adjustedEntryPoint = entryPoint + gridSnap
                isBeatSynced = true
                info = "Grid snap: \(gridSnap >= 0 ? "+" : "")\(String(format: "%.3f", gridSnap))s"
            }
        }

        // Phase 2: Cross-phase alignment A↔B (DJ mode only)
        if mode == .dj, hasCurrentBeats, let playbackA = currentPlaybackTimeA, playbackA > 0 {
            let beatFractionA = playbackA.truncatingRemainder(dividingBy: beatIntervalA) / beatIntervalA
            let targetPhaseOffsetB = beatFractionA * beatIntervalB
            let currentPhaseB = adjustedEntryPoint.truncatingRemainder(dividingBy: beatIntervalB)
            var phaseError = targetPhaseOffsetB - currentPhaseB
            if phaseError > beatIntervalB / 2 { phaseError -= beatIntervalB }
            if phaseError < -beatIntervalB / 2 { phaseError += beatIntervalB }

            if abs(phaseError) > beatIntervalB * 0.15 {
                if !targetBeats.isEmpty {
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
                    if abs(phaseAdj) <= beatIntervalB * 0.5 {
                        adjustedEntryPoint = bestCandidate
                        info += " + fase A↔B: \(phaseAdj >= 0 ? "+" : "")\(String(format: "%.3f", phaseAdj))s"
                    }
                } else {
                    let phaseAdj = max(-searchRange, min(searchRange, phaseError))
                    if abs(phaseAdj) <= beatIntervalB * 0.5 {
                        adjustedEntryPoint += phaseAdj
                        info += " + fase A↔B: \(phaseAdj >= 0 ? "+" : "")\(String(format: "%.3f", phaseAdj))s"
                    }
                }
            }
        }

        if !isBeatSynced {
            print("[DJMixingService] Beat sync: no snap applied (no downbeats within ±1 beat of entry)")
        }
        return BeatSyncResult(adjustedEntryPoint: max(0, adjustedEntryPoint), info: info, isSynced: isBeatSynced)
    }

    private static func snapToMeasureGrid(_ time: Double, measureLength: Double, beatInterval: Double) -> Double {
        guard measureLength > 0 else { return 0 }
        let timeIntoMeasure = time.truncatingRemainder(dividingBy: measureLength)
        if timeIntoMeasure < beatInterval * 0.5 && timeIntoMeasure > 0.001 {
            return -timeIntoMeasure
        }
        let distToNext = measureLength - timeIntoMeasure
        if distToNext < beatInterval * 0.5 {
            return distToNext
        }
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

    /// Fade duration — driven by profile relationship.
    /// High style affinity allows longer fades; low affinity prefers shorter.
    /// Bass conflict shortens fade; energy-down extends it.
    static func calculateAdaptiveFadeDuration(
        entryPoint: Double,
        bufferADuration: Double,
        bufferBDuration: Double,
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        profile: TransitionProfile,
        userFadeDuration: Double? = nil
    ) -> FadeDurationResult {
        let config = configs[profile.mode]!
        let baseDuration = userFadeDuration ?? config.baseFadeDuration
        var fadeDuration = baseDuration
        var decision = "Base (\(fadeDuration)s)."

        let hasCurrent = currentAnalysis != nil && currentAnalysis?.hasError == false
        let hasNext = nextAnalysis != nil && nextAnalysis?.hasError == false

        if hasCurrent, hasNext, let current = currentAnalysis, let next = nextAnalysis {
            let backendFadeIn = next.backendFadeInDuration
            let backendFadeOut = current.backendFadeOutDuration

            if userFadeDuration == nil, let bfi = backendFadeIn, bfi >= 2 {
                fadeDuration = max(config.minFadeDuration, min(config.maxFadeDuration, bfi))
                decision = "Backend fadeIn: \(String(format: "%.1f", bfi))s → \(String(format: "%.1f", fadeDuration))s."

                if let bfo = backendFadeOut, bfo >= 2 {
                    let avg = (fadeDuration + max(config.minFadeDuration, min(config.maxFadeDuration, bfo))) / 2
                    fadeDuration = avg
                    decision = "Backend fadeIn/Out: \(String(format: "%.1f", bfi))/\(String(format: "%.1f", bfo))s → avg \(String(format: "%.1f", fadeDuration))s."
                }

                if entryPoint > 0 && fadeDuration * 1.2 > entryPoint {
                    let localMin = profile.mode == .dj ? 2.0 : config.minFadeDuration
                    fadeDuration = max(localMin, entryPoint / 1.2)
                    decision += " Capped por punch a \(String(format: "%.1f", fadeDuration))s."
                }
            } else {
                let outroAStart = current.outroStartTime > 0 ? current.outroStartTime : bufferADuration
                let outroADuration = bufferADuration - outroAStart
                let hasValidOutro = outroADuration >= 2
                let localMin = profile.mode == .dj ? 2.0 : config.minFadeDuration

                let idealFade = entryPoint
                let outroConstraint = hasValidOutro ? outroADuration : config.maxFadeDuration

                if idealFade >= localMin {
                    fadeDuration = max(localMin, min(config.maxFadeDuration, idealFade, outroConstraint))
                    decision = "Estructural: intro=\(String(format: "%.1f", idealFade))s outro=\(String(format: "%.1f", outroADuration))s → \(String(format: "%.1f", fadeDuration))s."
                } else if hasValidOutro {
                    fadeDuration = max(localMin, min(config.maxFadeDuration, outroADuration * 0.8))
                    decision = "Punch temprano (\(String(format: "%.1f", idealFade))s), outro=\(String(format: "%.1f", outroADuration))s → \(String(format: "%.1f", fadeDuration))s."
                } else {
                    fadeDuration = userFadeDuration ?? (profile.mode == .dj ? 5 : 6)
                    decision = "Sin estructura clara: \(String(format: "%.1f", fadeDuration))s."
                }

                if entryPoint > 0 && fadeDuration * 1.2 > entryPoint {
                    fadeDuration = max(localMin, entryPoint / 1.2)
                    decision += " Capped por punch a \(String(format: "%.1f", fadeDuration))s."
                }
            }

            // ── Profile-driven modulations ──

            // Character: minimal → extend for gentler handoff
            if profile.character == .minimal && fadeDuration < 8 {
                fadeDuration = min(config.maxFadeDuration, max(fadeDuration, 8))
                decision += " Extendido por minimal a \(String(format: "%.1f", fadeDuration))s."
            }

            // Energy flow: energy-down with long outro → extend for graceful descent
            if profile.energyFlow == .energyDown {
                let outroAStart2 = current.outroStartTime > 0 ? current.outroStartTime : bufferADuration
                let outroLen = bufferADuration - outroAStart2
                if outroLen > 12 {
                    fadeDuration = min(15, max(fadeDuration, outroLen * 0.9))
                    decision += " Extendido por caida de energia a \(String(format: "%.1f", fadeDuration))s."
                }
            }

            // Bass conflict: shorten slightly to reduce bass overlap time
            if profile.bassConflictRisk && fadeDuration > 6 {
                fadeDuration = max(5, fadeDuration * 0.85)
                decision += " Acortado por bass conflict a \(String(format: "%.1f", fadeDuration))s."
            }

            // Style affinity: low affinity → shorter fade (they sound foreign together)
            if profile.styleAffinity < 0.35 && fadeDuration > 5 {
                fadeDuration = max(4, fadeDuration * 0.8)
                decision += " Acortado por baja afinidad (\(String(format: "%.2f", profile.styleAffinity))) a \(String(format: "%.1f", fadeDuration))s."
            }

            // Harmonic penalty
            switch profile.harmonic.compatibility {
            case .compatible, .acceptable:
                break
            case .tense:
                fadeDuration = max(2, fadeDuration * 0.85)
                decision += " Reducido 15% por tension armonica a \(String(format: "%.2f", fadeDuration))s."
            case .clash:
                fadeDuration = max(2, fadeDuration * 0.75)
                decision += " Reducido 25% por clash armonico a \(String(format: "%.2f", fadeDuration))s."
            }
        } else {
            fadeDuration = userFadeDuration ?? (bufferADuration < 30 ? 3 : baseDuration)
            decision = "Sin analisis — duracion \(String(format: "%.0f", fadeDuration))s."
        }

        // Absolute max: 25% of the shorter track
        let absoluteMax = min(bufferADuration * 0.25, bufferBDuration * 0.25)
        if fadeDuration > absoluteMax {
            fadeDuration = max(2, absoluteMax)
            decision += " Acortado por limite 25% a \(String(format: "%.2f", fadeDuration))s."
        }

        // Cap to B's available audio after entry point
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

    /// Filter decision — driven by profile. No more re-deriving energy/BPM/vocal data.
    static func decideFilterUsage(
        profile: TransitionProfile,
        fadeDuration: Double
    ) -> FilterDecisionResult {
        let hasVocals = profile.aHasOutroVocals || profile.bHasIntroVocals
        let isVeryShort = fadeDuration < 3
        let isShort = fadeDuration < 4

        let useFilters = hasVocals ||
            abs(profile.energyGap) > 0.3 ||
            profile.bpmDiff > 20 ||
            profile.harmonic.isClash ||
            profile.bassConflictRisk ||
            isVeryShort

        let useAggressive = (hasVocals || isShort ||
            profile.harmonic.compatibility == .clash ||
            profile.vocalOverlapRisk == .both ||
            profile.bassConflictRisk) && useFilters

        var reasons: [String] = []
        if hasVocals { reasons.append("voces") }
        if abs(profile.energyGap) > 0.3 { reasons.append("energia \(Int(abs(profile.energyGap) * 100))%") }
        if profile.bpmDiff > 20 { reasons.append("BPM ±\(Int(profile.bpmDiff))") }
        if profile.harmonic.compatibility == .tense { reasons.append("tension tonal") }
        if profile.harmonic.compatibility == .clash { reasons.append("clash tonal") }
        if profile.bassConflictRisk { reasons.append("bass conflict") }
        if isVeryShort { reasons.append("fade<3s") }

        let reason = useFilters ? "Filtros ON: \(reasons.joined(separator: ", "))" : "Filtros OFF: mezcla simple"

        return FilterDecisionResult(
            useFilters: useFilters, useAggressiveFilters: useAggressive,
            energyDiff: abs(profile.energyGap), bpmDiff: profile.bpmDiff, reason: reason
        )
    }

    // MARK: - DJ-Grade Filters (Mid Scoop + High-Shelf)

    struct DJFilterResult {
        let useMidScoop: Bool
        let useHighShelfCut: Bool
        let reason: String
    }

    /// Refined DJ filter decisions using actual fade zone (entry point + fade duration known).
    /// The profile provides the initial vocal assessment; this refines with precise zone info.
    static func decideDJFilters(
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        profile: TransitionProfile,
        fadeDuration: Double,
        entryPoint: Double,
        bufferADuration: Double
    ) -> DJFilterResult {
        guard currentAnalysis != nil || nextAnalysis != nil else {
            return DJFilterResult(useMidScoop: false, useHighShelfCut: false, reason: "Sin analisis")
        }

        var useMidScoop = false
        var useHighShelf = false
        var reasons: [String] = []

        // ── Mid Scoop: refine vocal overlap with actual crossfade zone ──
        if let current = currentAnalysis, let next = nextAnalysis {
            let crossfadeStartA = bufferADuration - fadeDuration
            let bOverlapEnd = entryPoint + fadeDuration

            // Detect A vocals in crossfade zone (precise)
            let aVocalsInZone: Bool
            if current.hasVocalData && current.hasOutroVocals {
                aVocalsInZone = true
            } else if current.hasVocalEndData && current.lastVocalTime > crossfadeStartA {
                aVocalsInZone = true
            } else if !current.speechSegments.isEmpty {
                aVocalsInZone = current.speechSegments.contains { $0.end > crossfadeStartA }
            } else {
                aVocalsInZone = current.vocalStartTime > 0 &&
                    (current.outroStartTime <= 0 || current.outroStartTime > crossfadeStartA)
            }

            // Detect B vocals in entry zone (precise)
            let bVocalsInZone: Bool
            if next.hasVocalData && next.hasIntroVocals {
                bVocalsInZone = true
            } else if !next.speechSegments.isEmpty {
                bVocalsInZone = next.speechSegments.contains { $0.start < bOverlapEnd && $0.end > entryPoint }
            } else {
                bVocalsInZone = next.vocalStartTime > 0 && next.vocalStartTime < bOverlapEnd
            }

            if aVocalsInZone && bVocalsInZone {
                useMidScoop = true
                reasons.append("mid scoop: voces solapadas")
            }
        }

        // ── High-Shelf: energy-based hi-hat detection ──
        if profile.energyA > 0.45 && profile.energyB > 0.35 {
            useHighShelf = true
            reasons.append("hi-shelf: energia A=\(String(format: "%.2f", profile.energyA)) B=\(String(format: "%.2f", profile.energyB))")
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

    // MARK: - Trigger Bias (outro side of the A↔B relationship)

    struct TriggerBiasResult {
        let bias: Double    // negative = earlier, positive = later, 0 = default
        let reason: String
    }

    /// Calculates how much earlier or later the crossfade should trigger on A,
    /// based on the A↔B relationship. This is the "outro" side of the profile.
    ///
    /// Default trigger = "as late as possible so fade fits before A ends".
    /// Bias shifts it: negative = start earlier (longer overlap), positive = start later (tighter).
    private static func calculateTriggerBias(
        profile: TransitionProfile,
        fadeDuration: Double
    ) -> TriggerBiasResult {
        var bias: Double = 0
        var reasons: [String] = []

        switch profile.character {
        case .minimal:
            // Both low energy — start much earlier for invisible, extended blend.
            // The listener shouldn't notice the transition at all.
            bias -= min(5, fadeDuration * 0.4)
            reasons.append("minimal: trigger \(String(format: "%.1f", abs(bias)))s antes")

        case .smooth:
            // Incompatible BPMs or low affinity — start a bit earlier.
            // More overlap time helps mask the genre/tempo jump.
            bias -= min(3, fadeDuration * 0.25)
            reasons.append("smooth: trigger \(String(format: "%.1f", abs(bias)))s antes")

        case .dramatic:
            if profile.energyFlow == .energyDown {
                // A is hot, B is chill — start earlier for graceful descent.
                // A needs time to die while B creeps in underneath.
                bias -= min(4, fadeDuration * 0.3)
                reasons.append("dramatic DOWN: trigger \(String(format: "%.1f", abs(bias)))s antes")
            } else if profile.energyFlow == .energyUp {
                // A is chill, B is hot — trigger late for maximum impact.
                // B should arrive like a surprise, not a slow build.
                bias += min(2, fadeDuration * 0.15)
                reasons.append("dramatic UP: trigger \(String(format: "%.1f", bias))s despues")
            }
            // steady + dramatic (harmonic clash): default timing, just get through it

        case .punch:
            // Compatible BPMs — default timing is fine.
            // But adjust for vocal/bass situations:
            break
        }

        // ── Bass conflict: start earlier so filters have time to separate the low end ──
        if profile.bassConflictRisk && bias > -3 {
            let bassAdj = min(2, fadeDuration * 0.15)
            bias -= bassAdj
            reasons.append("bass conflict: -\(String(format: "%.1f", bassAdj))s")
        }

        // ── Vocal overlap: if both songs have vocals, start earlier
        // so A's vocals have time to fade before B's vocals enter ──
        if profile.vocalOverlapRisk == .both && bias > -2 {
            let vocalAdj = min(2, fadeDuration * 0.2)
            bias -= vocalAdj
            reasons.append("vocal overlap: -\(String(format: "%.1f", vocalAdj))s")
        }

        // ── High style affinity: can afford slightly later trigger (they blend naturally) ──
        if profile.styleAffinity > 0.8 && profile.character == .punch {
            bias += 1.0
            reasons.append("alta afinidad: +1s")
        }

        let reason = reasons.isEmpty
            ? "Trigger bias: 0 (default)"
            : "Trigger bias: \(bias >= 0 ? "+" : "")\(String(format: "%.1f", bias))s (\(reasons.joined(separator: ", ")))"
        print("[DJMixingService] \(reason)")

        return TriggerBiasResult(bias: bias, reason: reason)
    }

    // MARK: - Transition Type

    struct TransitionTypeResult {
        let type: TransitionType
        let reason: String
    }

    /// Transition type — driven by profile relationship.
    /// The character biases the selection: punch→BEAT_MATCH, smooth→NATURAL_BLEND, etc.
    static func decideTransitionType(
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        profile: TransitionProfile,
        entryPoint: Double,
        fadeDuration: Double,
        isBeatSynced: Bool,
        useFilters: Bool,
        bufferADuration: Double,
        hasVocalOverlap: Bool = false
    ) -> TransitionTypeResult {
        // ── Abruptness detection ──
        var isAAbrupt = false
        if let current = currentAnalysis, current.hasError != true {
            if current.hasOutroData {
                isAAbrupt = current.outroStartTime >= bufferADuration - 2 && current.outroStartTime > 0
            }
        } else if currentAnalysis == nil {
            isAAbrupt = fadeDuration < 3
        }

        var isBAbrupt = false
        if let next = nextAnalysis, next.hasError != true {
            if next.hasIntroData {
                // Only consider B truly abrupt when intro is extremely short AND
                // entry point is near the start. Previously introEndTime < 2 triggered
                // too often for pop songs with quick verse entries.
                isBAbrupt = next.introEndTime < 1 && entryPoint < 2
            }
        } else if nextAnalysis == nil {
            isBAbrupt = fadeDuration < 3
        }

        let bpmCompatible = profile.bpmRelationship != .incompatible

        var type: TransitionType = .crossfade
        var reason = "Transicion normal"

        // Very short fades: force CUT
        if fadeDuration < 3 {
            type = .cut
            reason = "Fade muy corto (\(String(format: "%.1f", fadeDuration))s) → CUT directo"
        }
        // ── Character-biased selection ──
        else {
            switch profile.character {
            case .minimal:
                // Both low energy — gentle blend, no beat matching needed
                type = .naturalBlend
                reason = "Minimal (ambos baja energia) → NATURAL_BLEND suave"

            case .smooth:
                // Incompatible BPMs or low affinity — smooth crossfade
                if profile.bpmRelationship == .incompatible {
                    type = .naturalBlend
                    reason = "BPMs incompatibles (diff=\(String(format: "%.1f", profile.bpmDiff))) → NATURAL_BLEND"
                } else {
                    type = .crossfade
                    reason = "Smooth blend (afinidad=\(String(format: "%.2f", profile.styleAffinity))) → CROSSFADE"
                }

            case .dramatic:
                // Big energy change or harmonic clash
                if profile.energyFlow == .energyUp && bpmCompatible && isBeatSynced {
                    // Energy rising with compatible BPMs — can do an impactful beat-matched entry
                    type = .beatMatchBlend
                    reason = "Dramatic UP + BPMs compatibles → BEAT_MATCH_BLEND (energia \(String(format: "%.2f→%.2f", profile.energyA, profile.energyB)))"
                } else if profile.energyFlow == .energyDown {
                    // Energy dropping — gentle fade, let A die gracefully
                    type = .naturalBlend
                    reason = "Dramatic DOWN → NATURAL_BLEND (energia \(String(format: "%.2f→%.2f", profile.energyA, profile.energyB)))"
                } else if profile.harmonic.compatibility == .clash {
                    // Harmonic clash with steady energy — crossfade (shorter, from fade duration)
                    type = .crossfade
                    reason = "Clash armonico → CROSSFADE corto"
                } else {
                    type = .crossfade
                    reason = "Dramatic steady → CROSSFADE"
                }

            case .punch:
                // Compatible BPMs, good affinity — full DJ treatment
                if isBeatSynced && !isAAbrupt && !isBAbrupt && fadeDuration >= 6 && hasVocalOverlap {
                    type = .stemMix
                    reason = "Punch + vocales solapadas + fade≥6s → STEM_MIX (diff=\(String(format: "%.1f", profile.bpmDiff)))"
                } else if isBeatSynced && !isAAbrupt && !isBAbrupt {
                    type = .beatMatchBlend
                    reason = "Punch + beats sync (diff=\(String(format: "%.1f", profile.bpmDiff))) → BEAT_MATCH_BLEND"
                } else if isAAbrupt && isBAbrupt {
                    if fadeDuration < 4 {
                        type = .cut
                        reason = "Ambos abruptos + fade corto → CUT"
                    } else {
                        type = .eqMix
                        reason = "Ambos abruptos + fade largo → EQ_MIX"
                    }
                } else if isAAbrupt && !isBAbrupt {
                    type = .cutAFadeInB
                    reason = "A abrupto, B suave → CUT_A_FADE_IN_B"
                } else if !isAAbrupt && isBAbrupt {
                    type = .fadeOutACutB
                    reason = "A suave, B abrupto → FADE_OUT_A_CUT_B"
                } else {
                    // Punch but not beat synced — still try to sound intentional
                    type = .crossfade
                    reason = "Punch sin beat sync → CROSSFADE"
                }
            }
        }

        // ── Safety: extreme BPM jump override ──
        let bpmCutThreshold: Double = useFilters ? 25 : 15
        if profile.bpmDiff > bpmCutThreshold && fadeDuration > 3 && type != .cut {
            type = .cut
            let normalizedNote = profile.bpmBNormalized != profile.bpmB ? " (norm:\(Int(profile.bpmBNormalized)))" : ""
            reason = "Polirritmia evitada (A:\(Int(profile.bpmA)) B:\(Int(profile.bpmB))\(normalizedNote) diff=\(String(format: "%.1f", profile.bpmDiff))) → CUT forzado"
        }

        // ── Safety: vocal trainwreck — refine with actual fade zone ──
        if let current = currentAnalysis, current.hasError != true,
           let next = nextAnalysis, next.hasError != true,
           type != .cut && type != .stemMix {

            let vocalBStart = next.vocalStartTime - entryPoint
            let bHasVocalsInFade = next.vocalStartTime > 0 && vocalBStart < fadeDuration
            let bIntroVocalOverlap = next.hasIntroVocals || bHasVocalsInFade

            if bIntroVocalOverlap {
                let safeOutroA = bufferADuration - fadeDuration

                var aHasVocalsAtEnd = false
                if current.hasOutroVocals {
                    aHasVocalsAtEnd = true
                } else if current.hasVocalEndData {
                    aHasVocalsAtEnd = current.lastVocalTime > safeOutroA
                } else if !current.speechSegments.isEmpty {
                    aHasVocalsAtEnd = current.speechSegments.contains { $0.end > safeOutroA }
                } else {
                    aHasVocalsAtEnd = (current.outroStartTime <= 0 || current.outroStartTime > safeOutroA)
                        && current.vocalStartTime > 0
                }

                if aHasVocalsAtEnd {
                    let bInstrumentalWindow = next.vocalStartTime - entryPoint
                    if bInstrumentalWindow > fadeDuration * 0.6 {
                        reason += " (vocal overlap OK: B vocals after \(String(format: "%.0f", bInstrumentalWindow))s)"
                    } else {
                        type = .cut
                        reason = "Vocal Trainwreck evitado → CUT forzado"
                    }
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

    static func decideTimeStretch(
        profile: TransitionProfile,
        transitionType: TransitionType
    ) -> TimeStretchResult {
        switch transitionType {
        case .cut, .cutAFadeInB, .fadeOutACutB:
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: transicion tipo cut")
        default: break
        }

        guard profile.bpmA > 50 && profile.bpmA < 250 &&
              profile.bpmB > 50 && profile.bpmB < 250 else {
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: BPM fuera de rango")
        }

        // Don't stretch when BPM confidence is low — stretching to a wrong BPM sounds terrible
        if !profile.bpmTrusted {
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: BPM no confiable (confidence < 0.5)")
        }

        let diff = profile.bpmDiff
        // Maximum allowed rate change — beyond this the pitch shift is audible
        let maxRateChange: Float = 0.06  // 6%

        if diff < 3 {
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: BPMs casi iguales (±\(String(format: "%.1f", diff)))")
        } else if diff <= 8 {
            let rateB = Float(profile.bpmA / profile.bpmBNormalized)
            if abs(rateB - 1.0) > maxRateChange {
                return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                         reason: "No stretch: rate \(String(format: "%.1f", abs(rateB - 1.0) * 100))% > 6% (audible)")
            }
            return TimeStretchResult(useTimeStretch: true, rateA: 1.0, rateB: rateB,
                                     reason: "Stretch B→A: \(Int(profile.bpmBNormalized))→\(Int(profile.bpmA)) BPM (rate=\(String(format: "%.3f", rateB)))")
        } else if diff <= 12 {
            let mid = (profile.bpmA + profile.bpmBNormalized) / 2.0
            let rateA = Float(mid / profile.bpmA)
            let rateB = Float(mid / profile.bpmBNormalized)
            if abs(rateA - 1.0) > maxRateChange || abs(rateB - 1.0) > maxRateChange {
                return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                         reason: "No stretch: rate change > 6% (A:\(String(format: "%.1f", abs(rateA - 1.0) * 100))% B:\(String(format: "%.1f", abs(rateB - 1.0) * 100))%)")
            }
            return TimeStretchResult(useTimeStretch: true, rateA: rateA, rateB: rateB,
                                     reason: "Stretch ambos→\(Int(mid)) BPM: A=\(String(format: "%.3f", rateA)) B=\(String(format: "%.3f", rateB))")
        } else {
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: diferencia demasiado grande (±\(Int(diff)) BPM)")
        }
    }

    // MARK: - Instrumental Detection (refined with actual fade zone)

    /// Detect if A's outro is instrumental in the actual crossfade zone.
    private static func detectOutroInstrumental(
        currentAnalysis: SongAnalysis?,
        profile: TransitionProfile,
        bufferADuration: Double,
        fadeDuration: Double
    ) -> Bool {
        guard let cur = currentAnalysis, cur.hasError != true else { return false }
        let crossfadeStartA = bufferADuration - fadeDuration

        if cur.hasVocalEndData {
            return cur.lastVocalTime < crossfadeStartA
        } else if cur.hasVocalData && !cur.hasOutroVocals && cur.hasEnergyProfile {
            if !cur.speechSegments.isEmpty {
                let vocalsInOutro = cur.speechSegments.contains { $0.end > crossfadeStartA }
                if vocalsInOutro {
                    print("[DJMixingService] ⚠️ Backend says no outro vocals, but speechSegments disagree")
                }
                return !vocalsInOutro
            }
            return true
        }
        return false
    }

    /// Detect if B's intro is instrumental in the actual entry zone.
    private static func detectIntroInstrumental(
        nextAnalysis: SongAnalysis?,
        profile: TransitionProfile,
        entryPoint: Double,
        fadeDuration: Double
    ) -> Bool {
        guard let nxt = nextAnalysis, nxt.hasError != true else { return false }
        let bEnd = entryPoint + fadeDuration

        if nxt.hasVocalData && nxt.hasEnergyProfile && !nxt.hasIntroVocals {
            if nxt.vocalStartTime > 0 && nxt.vocalStartTime <= bEnd {
                print("[DJMixingService] ⚠️ Backend says no intro vocals, but vocalStart (\(String(format: "%.1f", nxt.vocalStartTime))s) is within fade zone")
                return false
            }
            return true
        } else if nxt.vocalStartTime > bEnd {
            return true
        } else if !nxt.speechSegments.isEmpty {
            return !nxt.speechSegments.contains { $0.start < bEnd && $0.end > entryPoint }
        }
        return false
    }

    // MARK: - Harmonic BPM Normalization

    static func harmonicBPM(_ bpmA: Double, _ bpmB: Double) -> Double {
        guard bpmA > 0 && bpmB > 0 else { return bpmB }
        // Only half-time and double-time are musically valid for beat matching.
        // Ratios like 3:2 (e.g., 80→120) create false compatibles that require
        // extreme time-stretch (>10%) and sound terrible in practice.
        let ratios: [Double] = [0.5, 1.0, 2.0]
        let bestRatio = ratios.min(by: {
            abs(bpmB * $0 - bpmA) < abs(bpmB * $1 - bpmA)
        }) ?? 1.0
        let adjusted = bpmB * bestRatio
        return abs(adjusted - bpmA) < abs(bpmB - bpmA) ? adjusted : bpmB
    }

    // MARK: - Harmonic Mixing (Camelot Wheel)

    enum HarmonicCompatibility: Int {
        case compatible = 0
        case acceptable = 1
        case tense = 2
        case clash = 3
    }

    struct HarmonicPenalty {
        let distance: Int
        let compatibility: HarmonicCompatibility
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
