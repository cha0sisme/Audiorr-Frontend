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

    // MARK: - Set diversity (cooldowns)

    /// Last N transition types chosen by `decideTransitionType`. Used to enforce
    /// "DJ tics" cooldowns: a VINYL_STOP every transition would feel mechanical
    /// rather than expressive. Reset on app launch — a fresh set starts clean.
    /// Single-threaded access expected (selector runs on main / audio queue).
    private static var recentTypes: [TransitionType] = []
    private static let recentTypesLimit = 12

    /// Returns true if `type` should be skipped this round because it was used
    /// too recently. Called inside `decideTransitionType` before committing to
    /// an expressive type (currently only VINYL_STOP — extend as new types
    /// land in P5).
    private static func isOnCooldown(_ type: TransitionType) -> Bool {
        switch type {
        case .vinylStop:
            // Max 1 every 6 transitions (DJ recommendation: ≈2-3 spin-downs per
            // 20-track set). Less, and the gesture is wasted; more, it tics.
            return recentTypes.suffix(6).contains(.vinylStop)
        default:
            return false
        }
    }

    /// Append the chosen type to the cooldown buffer. Trim to keep memory bounded.
    private static func recordTransition(_ type: TransitionType) {
        recentTypes.append(type)
        if recentTypes.count > recentTypesLimit {
            recentTypes.removeFirst(recentTypes.count - recentTypesLimit)
        }
    }

    // MARK: - Types

    enum MixMode: String {
        case dj, normal
    }

    /// Possible high-level shapes a transition can take. CrossfadeExecutor.TransitionType
    /// must mirror this exactly (the rawValue is the wire format used to bridge them).
    enum TransitionType: String {
        case crossfade = "CROSSFADE"
        case eqMix = "EQ_MIX"
        case cut = "CUT"
        case naturalBlend = "NATURAL_BLEND"
        case beatMatchBlend = "BEAT_MATCH_BLEND"
        case cutAFadeInB = "CUT_A_FADE_IN_B"
        case fadeOutACutB = "FADE_OUT_A_CUT_B"
        case stemMix = "STEM_MIX"
        case dropMix = "DROP_MIX"
        /// Sequential handoff with a tiny gap. A fades out (cos² over ~55% of the
        /// window), short respiro of dead air (~10% of the window), then B sin²
        /// ramps in (~35%). NO overlap of the two tracks. Used when the pairing is
        /// fundamentally unmixable (incompatible BPMs) — blending them for several
        /// seconds sounds worse than a clean radio-style handoff.
        case cleanHandoff = "CLEAN_HANDOFF"
        /// Vinyl-stop / spin-down: A's playback rate ramps 1.0→0 over ~450ms with
        /// an exponential curve `y = 1-(t/T)^0.6`, then a short pause before B
        /// enters in seco. Reads as a deliberate DJ gesture for big mood / tempo
        /// drops. Cooldown: max 1 every 6 transitions (avoid making it a tic).
        case vinylStop = "VINYL_STOP"
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
        // Optional semantics (post-backend confirmation 2026-05-01):
        //   nil → unknown / no detection. Code paths must fall back to
        //         introEndHeuristic / speechSegments / introEndTime.
        //   0.0 → literal "vocal at t=0" (track opens singing).
        //   >0  → real vocal onset timestamp.
        // Never collapse nil to 0 — that conflates two distinct cases.
        var vocalStartTime: Double? = nil
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
        case compatible     // diff 3-12 (stretchable within 8% rate change)
        /// diff 12-18: too far for invisible beat-match (would need >8% time-stretch),
        /// but close enough that a subtle gentle crossfade still works musically.
        /// Think: a DJ who can't beat-grid but blends with filters and longer fades
        /// to mask the rhythmic mismatch — the most graceful "I can't match these"
        /// move available.
        case borderline
        case incompatible   // diff > 18 (truly unmixable — sequential handoff only)
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
        // DJ effects (Sprint 1)
        let useBassKill: Bool
        let useDynamicQ: Bool
        // DJ effects (Sprint 2 — companion sweeps on B)
        /// Phaser-style narrow parametric notch on B's band 2.
        /// Center freq sweeps 250→6000Hz exponentially while depth follows a bell
        /// (-6 → -24 → -6 dB). Adds a moving spectral hole that "rides" through B
        /// as it opens. Only activates alongside useDynamicQ when conditions allow.
        let useNotchSweep: Bool
        // DJ effects (Sprint 3 — hip-hop signature)
        /// Stutter Cut: 1/8-note volume gate over A's last 2 beats before a CUT,
        /// anchored to A's beat grid. Sounds like a DJ Premier mixtape chop.
        let useStutterCut: Bool
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
        // Backend bug pendiente de fix: 6/49 pistas en log v7 reportan
        // energy/energyOutro = 0.00 con audio claramente audible (D Rose,
        // LIKE WEEZY, Champion, Vamp Anthem, Down Hill, God Is). El integrador
        // RMS sale en 0 cuando deberia normalizar — el backend NO ha
        // confirmado fix para este. Mientras tanto, floor a 0.10 cuando hay
        // duracion suficiente para asumir que la pista tiene contenido real.
        // 0.10 es el limite inferior plausible para musica con audio audible
        // y NO afecta tracks con energy=0.10 reales (que ya quedaban abajo).
        let eA: Double = {
            let raw: Double
            if let cur = currentAnalysis, hasCurrent, cur.hasEnergyProfile {
                raw = cur.energyOutro
            } else {
                raw = hasCurrent ? (currentAnalysis?.energy ?? 0.5) : 0.5
            }
            // Floor solo si raw es claramente bug (≤ 0.02) Y hay evidencia
            // de pista real (duracion > 30s). Pistas <30s pueden ser jingles
            // / SFX donde energy=0 es legitimo.
            return raw <= 0.02 && bufferADuration > 30 ? 0.10 : raw
        }()
        let eB: Double = {
            let raw: Double
            if let nxt = nextAnalysis, hasNext, nxt.hasEnergyProfile {
                raw = nxt.energyIntro
            } else {
                raw = hasNext ? (nextAnalysis?.energy ?? 0.5) : 0.5
            }
            return raw <= 0.02 && bufferBDuration > 30 ? 0.10 : raw
        }()
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
        else if diff <= 18 { bpmRel = .borderline }
        else { bpmRel = .incompatible }

        // BPM confidence: both songs must have confidence ≥ 0.5 AND valid BPM data for trusted decisions.
        // When untrusted, time-stretch, beat sync, and bass kill should be conservative.
        let confA = currentAnalysis?.bpmConfidence ?? 1.0
        let confB = nextAnalysis?.bpmConfidence ?? 1.0
        let hasBeatDataA = bA > 20 && bA < 300
        let hasBeatDataB = bB > 20 && bB < 300
        let trusted = confA >= 0.5 && confB >= 0.5 && hasBeatDataA && hasBeatDataB
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
            } else if let vs = cur.vocalStartTime, vs > 0 {
                // vocalStart known and >0 → assume vocals likely until outro
                aVocals = cur.outroStartTime <= 0 || cur.outroStartTime > conservativeCrossfadeZoneA
            } else {
                // vocalStart nil (unknown) or 0 (vocal-at-t=0): without other
                // signals can't claim vocals in the outro window.
                aVocals = false
            }
        } else { aVocals = false }

        let bVocals: Bool
        if let nxt = nextAnalysis, hasNext {
            if nxt.hasVocalData && nxt.hasIntroVocals {
                bVocals = true
            } else if !nxt.speechSegments.isEmpty {
                bVocals = nxt.speechSegments.contains { $0.start < conservativeBEnd }
            } else if let vs = nxt.vocalStartTime, vs > 0 {
                bVocals = vs < conservativeBEnd
            } else {
                // vs == nil (unknown) OR vs == 0 (post-backend would mean
                // literal vocal-at-t=0, but pre-backfill it's still camouflaged
                // null). Stay conservative: no claim. Once the backfill ships,
                // a literal 0 here can be flipped to bVocals=true.
                bVocals = false
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
        var entry = calculateSmartEntryPoint(
            nextAnalysis: safeNext,
            currentAnalysis: safeCurrent,
            bufferDuration: bufferBDuration,
            profile: profile,
            currentPlaybackTimeA: currentPlaybackTimeA
        )

        // ── 2b. noRealOutro guard ──
        // Some tracks have outroStartTime pegged within ~3s of file end (Punk
        // Monk → FEAR. case: outroStartA=192.9s on a 196s track, with bajos +
        // baterías hasta el último segundo per the listener). The high
        // outro-aware entry that follows treats those last seconds as if there
        // were a real outro, triggering A's fade-out 25s+ before the end —
        // exactly when A is in full groove. Result: the listener perceives
        // "A salida demasiado pronto."
        //
        // Detect the no-real-outro condition and (a) cap entry to keep the
        // trigger close to A's actual end, and (b) tell decideAnticipation to
        // suppress the anticipation tease (further pre-mutes A).
        let noRealOutro: Bool = {
            guard let cur = safeCurrent, cur.hasError != true,
                  cur.hasOutroData, bufferADuration > 30 else { return false }
            let outroDur = bufferADuration - cur.outroStartTime
            guard outroDur < 4 else { return false }
            // Confirm with energy: short outro window + still-energetic =
            // groove vivo, not a 3-second decay. energyOutro is preferred when
            // available; energy global is the fallback.
            // Backend bug guard: when energyOutro collapses to ≤0.02, look at
            // cur.energy as second opinion before assuming bug. Only activate
            // the "groove vivo" default when BOTH signals are suspiciously low
            // (typical of the integrator-fail bug, not legit silent outros).
            // Avoids false positive on baladas with intentional silent fade.
            let primary = cur.hasEnergyProfile ? cur.energyOutro : cur.energy
            let outroEnergy: Double
            if primary > 0.02 {
                outroEnergy = primary
            } else if cur.hasEnergyProfile && cur.energy > 0.02 {
                // energyOutro=0 but global energy>0 — use global as proxy
                outroEnergy = cur.energy
            } else {
                // Both signals zero — true silent track OR backend bug.
                // Don't assume bug: respect the data and treat as quiet outro.
                outroEnergy = primary
            }
            return outroEnergy > 0.15
        }()

        if noRealOutro && entry.entryPoint > 8.0 {
            let capped = 8.0
            print("[DJMixingService] ⚠️ A sin outro real (energyOutro alto + outroDur<4s): entry \(String(format: "%.1f", entry.entryPoint))s → \(String(format: "%.1f", capped))s")
            entry = EntryPointResult(
                entryPoint: capped,
                beatSyncInfo: entry.beatSyncInfo + " [noRealOutro cap]",
                usedFallback: entry.usedFallback,
                // Drop beat-sync claim — the original sync was tied to the
                // pre-cap downbeat; a 6s cap puts us nowhere near it.
                isBeatSynced: false
            )
        }

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

        // ── 5. DJ-grade filters (mid scoop + high shelf) — refined with actual fade zone ──
        let djFilters = decideDJFilters(
            currentAnalysis: safeCurrent,
            nextAnalysis: safeNext,
            profile: profile,
            fadeDuration: fade.duration,
            entryPoint: entry.entryPoint,
            bufferADuration: bufferADuration
        )

        // ── 5b. Pre-decision instrumental detection ──
        // Computed BEFORE decideTransitionType so the selector can route incompatible
        // pairs that share an instrumental outro/intro to a gentle blend instead of
        // CLEAN_HANDOFF. We re-detect later with effectiveFadeDuration for the runtime
        // config — the small clamp delta (≤ 0.5s on cleanHandoff, ≤ 0.5s on cut) doesn't
        // change which side of the boundary a vocal lands on in practice.
        let preOutroInstrumental = detectOutroInstrumental(
            currentAnalysis: safeCurrent, profile: profile,
            bufferADuration: bufferADuration, fadeDuration: fade.duration
        )
        let preIntroInstrumental = detectIntroInstrumental(
            nextAnalysis: safeNext, profile: profile,
            entryPoint: entry.entryPoint, fadeDuration: fade.duration
        )

        // ── 6. Transition type — decided BEFORE anticipation so CUT can get its own tease ──
        let transition = decideTransitionType(
            currentAnalysis: safeCurrent,
            nextAnalysis: safeNext,
            profile: profile,
            entryPoint: entry.entryPoint,
            fadeDuration: fade.duration,
            isBeatSynced: entry.isBeatSynced,
            useFilters: filter.useFilters,
            bufferADuration: bufferADuration,
            hasVocalOverlap: djFilters.useMidScoop,
            outroInstrumental: preOutroInstrumental,
            introInstrumental: preIntroInstrumental
        )

        // ── 6c. CUT entry snap to downbeat ──
        // Done AFTER the type is decided (we only snap CUT-family) and BEFORE
        // anticipation/trigger/instrumental refinement (so they all see the
        // same final entry). The pre-decision calcs (fade, djFilters, pre-detect
        // instrumental) keep the original entry — they're heuristics tolerant
        // of a 1-2s shift.
        let snapResult = snapCutEntryToDownbeat(
            entry: entry.entryPoint,
            transitionType: transition.type,
            next: safeNext,
            bufferBDuration: bufferBDuration,
            fadeDuration: fade.duration
        )
        let finalEntry = snapResult.entry
        if snapResult.snapped {
            print("[DJMixingService] 🎯 \(snapResult.info)")
        }

        // ── 6b. Fade duration overrides per transition type ──
        // calculateAdaptiveFadeDuration assumes a graceful blend and returns
        // 5–15s based on outro structure. Some transition types (decided AFTER
        // the duration is calculated) don't make musical sense at long durations
        // and need to be clamped post-decision.
        let effectiveFadeDuration: Double
        switch transition.type {
        case .cleanHandoff:
            // Tight 2.5–3.5s: A fades out exponentially, micro-respiro, B sin² ramps.
            // Anything longer becomes dead air or an awkward double-pause.
            effectiveFadeDuration = max(2.5, min(3.5, fade.duration))
        case .vinylStop:
            // Tight 1.5–2.0s window. A's spin-down occupies the first 22.5%
            // (~340–450ms), then ~200ms aire, then B fades in. Anything longer
            // turns the gesture into dead air — a vinyl stop is a punctuation
            // mark, not a long transition.
            effectiveFadeDuration = max(1.5, min(2.0, fade.duration))
        case .cut:
            // CUT forced by polirritmia / vocal trainwreck inherits the long fade
            // computed for a hypothetical blend. The .cut volume curve hard-codes
            // a 3-second drop window at the END of the fade — for a 15s fade,
            // that means A plays normally for 12 seconds with no audible change,
            // followed by a 3-second drop. That's wasted "trigger lead-in" time
            // and the trigger ends up firing 15s before A's outro endpoint
            // instead of ~7s, so A keeps playing 8 unnecessary seconds.
            //
            // Clamp to [3, 7]: the .cut curve always uses the last 3s, and
            // anticipation can run up to 4s before that, so 7s is the sensible
            // ceiling. Below 3s the type is already CUT by another path.
            effectiveFadeDuration = max(3.0, min(7.0, fade.duration))
        case .fadeOutACutB:
            // When the energy-crash override fired (high-energy A into instrumental
            // low-energy B), the original fade may be short (~3s) because of the
            // short outro window. Aim for ≥ 5s so A can breathe out before B's
            // firm entry. Cap at 8s — anything longer turns into a long-tail fade.
            // ALSO cap at A's outro space + 2s so we don't fade through main body
            // material the listener still expects to hear (very short outros).
            // For any other path that lands here, behave neutrally.
            if profile.energyA > 0.40 && profile.energyB < 0.25 {
                let aOutroLimit: Double = {
                    guard let cur = safeCurrent, cur.hasError != true,
                          cur.hasOutroData,
                          bufferADuration > cur.outroStartTime else {
                        return 8.0
                    }
                    return (bufferADuration - cur.outroStartTime) + 2.0
                }()
                let cap = min(8.0, aOutroLimit)
                let target = max(min(5.0, cap), fade.duration)
                effectiveFadeDuration = min(cap, target)
            } else {
                effectiveFadeDuration = fade.duration
            }
        default:
            effectiveFadeDuration = fade.duration
        }

        // ── 7. Anticipation — now CUT-aware, can "tease" B before the swap ──
        // Uses finalEntry so an entry that got snapped forward by P5.a still
        // computes the right tease window relative to where B actually starts.
        // noRealOutro suppresses the tease entirely — A is in full groove
        // until the very end, so pre-muting A would cut material the listener
        // is still expecting.
        let anticipation = decideAnticipation(
            fadeDuration: effectiveFadeDuration,
            entryPoint: finalEntry,
            transitionType: transition.type,
            noRealOutro: noRealOutro,
            transitionReason: transition.reason
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
            bufferADuration: bufferADuration, fadeDuration: effectiveFadeDuration
        )
        let introInstrumental = detectIntroInstrumental(
            nextAnalysis: safeNext, profile: profile,
            entryPoint: finalEntry, fadeDuration: effectiveFadeDuration
        )

        // Skip B filters for very short fades, DROP_MIX (B enters clean and full),
        // CLEAN_HANDOFF or VINYL_STOP (sequential — B enters from silence, no
        // spectral shaping needed; the gesture on A is the effect).
        var skipBFilters = effectiveFadeDuration <= 3.0
            || transition.type == .dropMix
            || transition.type == .cleanHandoff
            || transition.type == .vinylStop

        // ── 8b. Aggressive preset gating ──
        // The aggressive preset stacks bassKill + midScoop + notchSweep + dynamicQ
        // and pulls hpB to 800 Hz with lsB=-12 dB. That density only works when
        // both tracks are energetic enough to share the carved-up spectrum.
        // Two cases force skipBFilters:
        //   (a) Original: A and B both energetic + danceable → A's gesture is the
        //       focal point, let B enter clean (Icon → Off The Grid).
        //   (b) New: A energetic but B almost silent (energyB < 0.15) → applying
        //       notch + dynamicQ + bassKill on top of a quiet entrance leaves it
        //       sounding "synthetic, filtered, dizzy" (ILoveUIHateU → WAKARIMASEN
        //       in v6: energyB=0.11, danceability=0.56). User reported the entry
        //       as "filtros mal en B"; the gate now bails B out.
        // Danceability threshold lowered 0.60 → 0.55 so case (b) catches mid-
        // danceability R&B pairs that were excluded under the previous 0.60 cap.
        let bothEnergetic = profile.energyA > 0.20 && profile.energyB > 0.20
        let aOnlyEnergetic = profile.energyA > 0.25 && profile.energyB < 0.15
        if filter.useAggressiveFilters
            && profile.avgDanceability > 0.55
            && (bothEnergetic || aOnlyEnergetic)
            && !skipBFilters {
            let mode = bothEnergetic ? "both-energetic" : "A-only-energetic"
            print("[DJMixingService] 🎚️ Aggressive \(mode): forcing skipBFilters (dance=\(String(format: "%.2f", profile.avgDanceability)), energyA=\(String(format: "%.2f", profile.energyA)), energyB=\(String(format: "%.2f", profile.energyB)))")
            skipBFilters = true
        }

        // ── 8c. Quiet-B gate when B is being filtered hard ──
        // anticipation/aggressive presets carve B's spectrum (highpass ramp,
        // bass shelf -12 dB, optional mid-scoop / dynamicQ). When B is quiet
        // AND not strongly danceable, those filters land as "filtered fade-in"
        // instead of "DJ technique" — user reported "B con fade innecesario"
        // in: D Rose→PRIDE., PRIDE.→New Magic Wand, Empty→Leave Me Alone,
        // The Alchemist.→Suge (v7); Lento→Cry, Cry→Rich Baby Daddy, Lucid→
        // BIRDS, BIRDS→Black Beatles, Live Sheck→New Magic, A Escondidas→
        // Answer (v8 audit 2026-05-04, 14+ menciones).
        //
        // Thresholds widened (audit v8): backend reportaba el rango habitual
        // de R&B/pop/hip-hop chill como energyB 0.10-0.30 y dance 0.50-0.90;
        // los thresholds antiguos (0.15/0.70 y 0.18/0.50) caian fuera de ese
        // cuadrante en ~0-1 caso de las 14 quejas. Subimos a 0.22/0.85 y
        // 0.25/0.65 para cubrir el cuadrante real sin romper las joyas.
        // Validacion contra positivas conocidas:
        //   T19 AIR FORCE→Can I Kick: dance=0.96 → 0.96 < 0.85 = false → no activa.
        //   T28 BOMB→No Stylist: dance=0.81 → 0.81 < 0.85 = true; energyB > 0.22
        //     debe seguir excluyendo (verificar). Borderline: vigilar en coche.
        //   T31 Silent Hill→2024: era BMB, ya tenia skipBFilters por otra rama.
        //   Black Beatles→Midnight Tokyo: ya activaba quiet-B antes.
        //   Falling Back→All Mine: dance=0.92 → 0.92 < 0.85 = false → no activa.
        let bQuietNotDanceable = profile.energyB < 0.22 && profile.avgDanceability < 0.85
        let bMidQuietLowDance = profile.energyB <= 0.25 && profile.avgDanceability < 0.65
        let bIsBeingFiltered = anticipation.needsAnticipation || filter.useAggressiveFilters
        if bIsBeingFiltered
            && (bQuietNotDanceable || bMidQuietLowDance)
            && !skipBFilters {
            let mode = bQuietNotDanceable ? "B-quiet" : "B-mid-quiet+low-dance"
            print("[DJMixingService] 🎚️ Quiet-B (\(mode)): forcing skipBFilters (energyB=\(String(format: "%.2f", profile.energyB)), dance=\(String(format: "%.2f", profile.avgDanceability)))")
            skipBFilters = true
        }

        // ── 9. Trigger bias — how much earlier/later A should start the crossfade ──
        let trigger = calculateTriggerBias(profile: profile, fadeDuration: effectiveFadeDuration)

        // ── 10. DJ effects (Bass Kill + Dynamic Q Resonance + Phaser Notch Sweep + Stutter Cut) ──
        let isEnergyDown = profile.energyB < profile.energyA - 0.2
        let djEffects = decideDJEffects(
            profile: profile,
            transitionType: transition.type,
            fadeDuration: effectiveFadeDuration,
            isEnergyDown: isEnergyDown,
            needsAnticipation: anticipation.needsAnticipation,
            skipBFilters: skipBFilters,
            hasBeatGridA: !dbA.isEmpty
        )

        return CrossfadeResult(
            entryPoint: finalEntry,
            fadeDuration: effectiveFadeDuration,
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
            useBassKill: djEffects.useBassKill,
            useDynamicQ: djEffects.useDynamicQ,
            useNotchSweep: djEffects.useNotchSweep,
            useStutterCut: djEffects.useStutterCut,
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
            // Both low energy — gentle handoff. Previously hardcoded to ~2.0s,
            // which dropped the listener mid-instrumental-intro of B (Awful
            // Things → DILEMMA: entry=2.0s but chorus=13.7s; Gyalchester →
            // Father Stretch: entry=2.0s but chorus=51s after a 33s intro).
            // Pick a structural landmark when one is reasonable: prefer the
            // heuristic intro end (percussive/energy-based, robust against
            // backend mislabeling) so B enters at the start of "real content"
            // rather than at file t=0.
            let earlyEntry = min(2.0, bufferDuration * config.fallbackPercent)
            // An early chorus (<8s) means real content starts almost
            // immediately — even a "long" introEndHeuristic is suspect in
            // that case (Vamp Anthem: chorus=4.7s but heuristic=30.7s).
            // Don't trust the heuristic when the chorus contradicts it.
            let chorusEarly = next.chorusStartTime > 0 && next.chorusStartTime < 8
            let candidates: [(Double, String)] = {
                var c: [(Double, String)] = []
                if let h = next.introEndTimeHeuristic, h > 4, h < 35, !chorusEarly {
                    c.append((max(earlyEntry, h - 1.0), "introEndHeuristic"))
                }
                if next.chorusStartTime > 5, next.chorusStartTime < 35,
                   next.chorusStartTime > earlyEntry + 3 {
                    c.append((max(earlyEntry, next.chorusStartTime - 2.0), "chorus-aligned"))
                }
                return c
            }()
            if let pick = candidates.min(by: { $0.0 < $1.0 }) {
                entryPoint = max(0, min(pick.0, bufferDuration - 1))
                print("[DJMixingService] 🌙 Minimal+\(pick.1): entry=\(String(format: "%.1f", entryPoint))s (low energy + structural target)")
                return EntryPointResult(entryPoint: entryPoint, beatSyncInfo: "Minimal (\(pick.1))", usedFallback: false, isBeatSynced: false)
            }
            entryPoint = max(0, earlyEntry)
            print("[DJMixingService] 🌙 Minimal: entry=\(String(format: "%.1f", entryPoint))s (both low energy, gentle handoff)")
            return EntryPointResult(entryPoint: entryPoint, beatSyncInfo: "Minimal (low energy)", usedFallback: false, isBeatSynced: false)

        case .smooth:
            // Incompatible BPMs or low style affinity — no punch targeting.
            // But still skip past boring instrumental intros (guitars, ambient pads)
            // so the listener hears the song's "real start."
            let baseEntry = min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)

            // Vocal-aware entry reference: prefer actual vocal/energy onset
            // over ML-derived introEndTime (which can report 40-60s for
            // songs with immediate vocals — it detects "dense section start").
            // Chain: vocalStart → heuristic introEnd → speechSegments → ML introEnd
            let entryRef: Double = {
                if let vs = next.vocalStartTime, vs > 0 { return vs }
                if let h = next.introEndTimeHeuristic, h > 0 { return h }
                if let first = next.speechSegments.first, first.start > 0 { return first.start }
                if next.hasIntroData { return next.introEndTime }
                return 0
            }()
            if entryRef > baseEntry + 3 {
                entryPoint = entryRef
            } else if next.chorusStartTime > baseEntry + 3 && next.chorusStartTime < bufferDuration * 0.25 {
                // Chorus as fallback — capped at 25% of song to avoid entering too deep
                entryPoint = next.chorusStartTime
            } else {
                entryPoint = baseEntry
            }
            entryPoint = max(0, min(entryPoint, bufferDuration - 1))

            // Vocal landmark alignment: if B enters after a clear vocal moment
            // (chorusStart), shift entry back so B becomes audible (~3s fade lead
            // time) right as the vocal hits. Creates a natural "reveal" — the
            // incoming track's vocal is the moment the listener notices the new song.
            if next.chorusStartTime > 5 && entryPoint > next.chorusStartTime {
                let vocalAlignedEntry = max(0, next.chorusStartTime - 3.0)
                print("[DJMixingService] 🎯 Smooth vocal alignment: entry \(String(format: "%.1f", entryPoint))s → \(String(format: "%.1f", vocalAlignedEntry))s (chorus at \(String(format: "%.1f", next.chorusStartTime))s)")
                entryPoint = vocalAlignedEntry
            }

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
            // Snap forward to nearest phrase boundary, but capped: a generous
            // maxAhead (16s) snaps pre-chorus entries onto the chorus literal,
            // which fights chorus-mislabeled cases (BRINCANDO regression).
            // 8s ≈ 1 musical phrase at typical hip-hop tempos, plenty for
            // alignment without dragging the entry across structural sections.
            let maxAhead: Double = profile.character == .dramatic ? 4 : 8
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
        let vocalStart = next.vocalStartTime ?? 0
        let chorusStart = next.chorusStartTime

        // Vocal-aware entry reference (same chain as smooth/punch)
        let entryRef: Double = {
            if let vs = next.vocalStartTime, vs > 0 { return vs }
            if let h = next.introEndTimeHeuristic, h > 0 { return h }
            if let first = next.speechSegments.first, first.start > 0 { return first.start }
            if next.hasIntroData { return next.introEndTime }
            return 0
        }()

        // Margen 2s antes de vocalStart — vocalStartTime es "primer evento
        // vocal" (grito, coro, sample) no "primer verso". Entrar 2s antes
        // deja que el evento surja al fadear. Ver calculatePunchEntry para
        // contexto completo.
        let vocalEntryTarget = max(2, vocalStart - 2)

        switch profile.energyFlow {
        case .energyUp:
            // Energy rising (A chill → B hot): prefer chorus or vocalStart for impact.
            // The dramatic energy jump benefits from landing on a strong moment.
            if chorusStart > 4 && chorusStart < bufferDuration * 0.4 {
                print("[DJMixingService] 🔥 Dramatic UP: chorus entry at \(String(format: "%.1f", chorusStart))s")
                return chorusStart
            } else if vocalStart > 3 {
                print("[DJMixingService] 🔥 Dramatic UP: vocal entry at \(String(format: "%.1f", vocalEntryTarget))s (vocal at \(String(format: "%.1f", vocalStart))s -2s margin)")
                return vocalEntryTarget
            } else if entryRef > 3 {
                return entryRef
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
                return vocalEntryTarget
            } else if entryRef > 3 {
                return entryRef
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
        // vocalStart unwrap: nil → 0 (treat as "no usable target"). The
        // distinction nil/0 doesn't matter for entry computation here —
        // both fall through to the fallback chain via the `vocalStart > 0`
        // guards. Sites where nil semantics matter (detectIntroInstrumental)
        // unwrap explicitly with `if let`.
        let vocalStart = next.vocalStartTime ?? 0
        let chorusStart = next.chorusStartTime

        // Early-vocal-in-intro detection.
        //
        // Originally a "data corruption" guard ("vocal way before intro_end →
        // suspicious"). Backend (2026-05-01) clarified that this is a LEGITIMATE
        // case: vocalStartTime is the first vocal EVENT (grito, coro polifónico,
        // sample, ad-lib, vocoder), not the first verse — and intros frequently
        // contain such events while the structural intro continues afterwards.
        // Example: ROSALÍA "Focu 'ranni" — vocalStart=9.6s (coros), introEnd=14.7s.
        //
        // Behaviour stays the same: when this fires, downstream branches prefer
        // chorusStart over vocalStart as the entry target. That's still musically
        // correct — the chorus is a stronger landing point than a coro/ad-lib in
        // the intro. The flag name is kept for backward-compat with existing
        // print logs and reasoning chains.
        let hasReliableIntro = next.hasIntroData && introEnd > 3
        let introVocalDiverge: Bool = {
            guard hasReliableIntro, vocalStart > 0 else { return false }
            return vocalStart < introEnd - 8
        }()

        if introVocalDiverge {
            print("[DJMixingService] 🎤 Early vocal in intro: introEnd=\(String(format: "%.1f", introEnd))s vocalStart=\(String(format: "%.1f", vocalStart))s — preferring chorus over vocalStart as entry target")
        }

        // ── Chorus-mislabeled safeguard ──
        // Backend chorusStartB sometimes points to a verse drop or 2nd-verse
        // landmark instead of the structural chorus. With our v6 sanitize
        // fallback (`vocalStart = chorus - 8` when backend returns 0), this
        // mislabeled chorus drags the inferred vocalStart into post-intro
        // territory and downstream logic snaps the entry to the chorus literal.
        // This produced the BRINCANDO regression: chorus=38.4s, introH=29.3s,
        // vocalStart inferred=30.4s → entry collapsed to 38.4s.
        //
        // Detection: chorus is 4–15s past the heuristic intro end. Larger gaps
        // (>15s) are genuine deep-chorus tracks (hip-hop with mid-song drop)
        // where chorus targeting is the right call — leave those alone.
        let chorusLikelyMislabeled: Bool = {
            guard let h = next.introEndTimeHeuristic, h > 4 else { return false }
            let gap = chorusStart - h
            return gap > 4 && gap < 15
        }()
        if chorusLikelyMislabeled {
            print("[DJMixingService] ⚠️ Chorus likely mislabeled: chorusStart=\(String(format: "%.1f", chorusStart))s vs introEndHeuristic=\(String(format: "%.1f", next.introEndTimeHeuristic ?? 0))s (gap \(String(format: "%.1f", chorusStart - (next.introEndTimeHeuristic ?? 0)))s) — pinning entry to heuristic")
        }

        var entry: Double

        // ── Vocal-aware entry reference: when B's "real content" starts ──
        // Chain: vocalStart → heuristic introEnd → speechSegments → ML introEnd
        // introEndTime from ML can report 40-60s for songs with immediate vocals.
        // introEndTimeHeuristic (percussive/energy detector) is more reliable.
        // When chorusLikelyMislabeled, prefer heuristic over the (possibly
        // sanitize-poisoned) vocalStart.
        let entryReference: Double = {
            if chorusLikelyMislabeled, let h = next.introEndTimeHeuristic, h > 0 { return h }
            if let vs = next.vocalStartTime, vs > 0 { return vs }
            if let h = next.introEndTimeHeuristic, h > 0 { return h }
            if let first = next.speechSegments.first, first.start > 0 { return first.start }
            if next.hasIntroData { return next.introEndTime }
            return 0
        }()
        let introIsInstrumental = entryReference > 8.0
        let vocalStartReliable: Bool = {
            // Sanitize-inferred vocalStart (chorus-8) is poisoned when the
            // chorus itself is mislabeled — refuse to trust it as a target.
            if chorusLikelyMislabeled { return false }
            return vocalStart > 0 && (introIsInstrumental || vocalStart < 20)
        }()

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

        // ── Chorus promotion: enter at the chorus when it's clearly the payoff ──
        // Default punch routing prefers vocalStart, which lands in verse 1. For
        // hip-hop / drill / trap tracks where the chorus is the real impact
        // (EVIL J0RDAN: chorusStart≈59s vs vocalStart≈2s), entering at verse 1
        // wastes the structural payoff and the listener's attention is on the
        // wrong moment.
        //
        // Conditions are intentionally tight to avoid mis-firing on pop / rock
        // where verse 1 IS content the listener wants to hear:
        //
        //   - profile.avgDanceability > 0.55  → bailable / hip-hop / dance only
        //   - bufferDuration > 90s            → short singles don't have a deep chorus
        //   - chorusStart > 35s               → "deep chorus" floor; pop typically <30s
        //   - chorus is at least 20s past the first vocal/intro reference
        //   - chorus stays in the first half of B → don't enter past midpoint
        //
        // referenceForGap tolerates either a known vocalStart OR the fallback
        // entryReference chain (introEndHeuristic / speechSegments / introEnd) —
        // so the promotion still fires when vocalStart is missing, as long as
        // some other "early reference" exists to compare against chorusStart.
        let referenceForGap: Double = vocalStart > 0 ? vocalStart : entryReference
        let isDanceable = profile.avgDanceability > 0.55
        let bufferLongEnough = bufferDuration > 90
        let chorusDeepEnough = chorusStart > 35
        let chorusFarFromReference = referenceForGap > 0 && chorusStart > referenceForGap + 20
        let chorusInUsableHalf = chorusStart < bufferDuration * 0.5
        if isDanceable && bufferLongEnough && chorusDeepEnough
            && chorusFarFromReference && chorusInUsableHalf
            && !chorusLikelyMislabeled {
            print("[DJMixingService] 🎯 Punch chorus promotion: entry=\(String(format: "%.1f", chorusStart))s (chorus far past reference at \(String(format: "%.1f", referenceForGap))s, dance=\(String(format: "%.2f", profile.avgDanceability)))")
            return chorusStart
        }

        // ── Style affinity modulates how aggressively we target ──
        // High affinity (>0.7): same genre feel — aggressive targeting
        // Medium affinity (0.4-0.7): compatible — moderate targeting
        // Low affinity (<0.4): would have been .smooth, shouldn't reach here
        //
        // NOTE: entryReference (vocal-aware) replaces raw introEnd for entry
        // assignment. introEnd from the ML model can report 40-60s for songs
        // with immediate vocals. entryReference uses the fallback chain:
        // vocalStartTime → speechSegments[0] → introEndTime.

        // Margen 2s antes de vocalStart (backend confirmation 2026-05-01):
        // vocalStartTime es "primer evento vocal", no "primer verso" — puede
        // ser un grito ("Beat it!"), un coro polifónico, un sample vocal, etc.
        // Entrar EXACTAMENTE en ese momento se siente abrupto. Entrar 2s antes
        // deja que el evento vocal surja al fadear, comportamiento DJ humano.
        // Floor a 2s para no forzar entry pre-musical en pistas con
        // vocalStart bajo (e.g. ad-lib temprano a t=4 → entry=2 mejor que 0).
        let vocalEntryTarget = max(2, vocalStart - 2)

        if profile.styleAffinity > 0.7 {
            // Same "world" — go for the most impactful entry
            if vocalStartReliable && vocalStart > 3 && !introVocalDiverge {
                entry = vocalEntryTarget
            } else if entryReference > 3 && !introVocalDiverge {
                entry = entryReference
            } else if chorusStart > 4 {
                entry = chorusStart
            } else if vocalStartReliable && vocalStart > 2 {
                entry = vocalEntryTarget
            } else if entryReference > 3 {
                entry = entryReference
            } else {
                entry = min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)
            }
        } else {
            // Moderate affinity — less aggressive
            if entryReference > 3 && !introVocalDiverge {
                entry = entryReference
            } else if vocalStartReliable && vocalStart > 3 && !introVocalDiverge {
                entry = vocalEntryTarget
            } else if vocalStartReliable && vocalStart > 2 {
                entry = vocalEntryTarget
            } else if entryReference > 3 {
                entry = entryReference
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
        if let vs = a.vocalStartTime { a.vocalStartTime = min(max(0, vs), maxT) }
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

        // ── 0.5. vocalStartTime semantics (post-backend confirmation 2026-05-01) ──
        // Backend confirmed `vocalStartTime == 0` is LITERAL — the track has
        // vocals from t=0. It's NOT a "value missing" sentinel. The earlier
        // sanitize fallback (`vocalStart = chorus - 8`, commit 05d1565)
        // assumed missing semantics and wrote synthetic values into a field
        // that already had a valid meaning, which produced the BRINCANDO
        // regression and other "B tarde" bugs (P0.1 mitigated downstream;
        // removing the sanitize is the actual root-cause fix).
        //
        // With vocalStart=0 left intact, downstream paths that gate on
        // `vocalStart > 0` correctly treat the track as "vocal at t=0 →
        // no clean instrumental window" and fall back to heuristic
        // (`introEndTimeHeuristic` → `speechSegments[0].start` → ML
        // `introEndTime`). That fallback chain is the right behaviour for
        // tracks with immediate vocals; it was being short-circuited by
        // the inferred chorus-8s value.

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

        // ── Cap by B's intro instrumental window ──
        // The fade should not extend past B's vocal entry. Using the heuristic
        // intro end (percussion/energy-based), not the ML model value which is
        // often 2-3x longer and includes vocal sections.
        // Allow 85% of the intro window so the fade finishes before vocals hit.
        if let next = nextAnalysis, next.hasError != true {
            let introWindow = next.introEndTimeHeuristic ?? (next.hasIntroData ? next.introEndTime : 0)
            if introWindow > 2 {
                let introCap = introWindow * 0.85
                if fadeDuration > introCap {
                    fadeDuration = max(2, introCap)
                    decision += " Capped por intro B (\(String(format: "%.1f", introWindow))s×0.85) a \(String(format: "%.1f", fadeDuration))s."
                }
            }
        }

        // ── Shorten when A has no instrumental outro ──
        // If A's outro is vocal (or unconfirmed), A likely has voice until the end.
        // Reduce fade to minimize vocal overlap from the outgoing track — UNLESS
        // B's intro is instrumental, in which case A's tail vocals fall on B's
        // intro section and can't clash. The Bricksquad → MAMA'S case in v6 had
        // its fade chopped from ~5s to 2.7s by this reduction even though MAMA'S
        // opens with a long instrumental intro, forcing a violent CUT.
        if let current = currentAnalysis, current.hasError != true {
            let aOutroVocal = current.hasOutroVocals
                || (!current.hasOutroData && (current.vocalStartTime ?? 0) > 0)
            if aOutroVocal && fadeDuration > 4 {
                let bIntroInstrumental: Bool = {
                    guard let nxt = nextAnalysis, nxt.hasError != true else { return false }
                    if nxt.hasVocalData && !nxt.hasIntroVocals { return true }
                    if let vs = nxt.vocalStartTime, vs > 4 { return true }
                    return false
                }()
                if bIntroInstrumental {
                    decision += " Outro vocal A pero intro B instrumental — sin reduccion."
                } else {
                    fadeDuration = max(3, fadeDuration * 0.80)
                    decision += " Reducido 20% por outro vocal A a \(String(format: "%.1f", fadeDuration))s."
                }
            }
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
                // No vocal data available — assume vocals present (safer for pop/hip-hop).
                // outroInstrumental is a separate, more reliable signal that overrides later.
                aVocalsInZone = true
            }

            // Detect B vocals in entry zone (precise)
            let bVocalsInZone: Bool
            if next.hasVocalData && next.hasIntroVocals {
                bVocalsInZone = true
            } else if !next.speechSegments.isEmpty {
                bVocalsInZone = next.speechSegments.contains { $0.start < bOverlapEnd && $0.end > entryPoint }
            } else {
                // No vocal data — assume vocals present in entry zone.
                // Most songs have vocals starting early; false positives are harmless
                // (mid scoop on instrumental just slightly reduces mids, barely noticeable).
                bVocalsInZone = true
            }

            if aVocalsInZone && bVocalsInZone {
                useMidScoop = true
                reasons.append("mid scoop: voces solapadas")
            }
        }

        // ── High-Shelf: energy-based hi-hat detection ──
        // Backend energy values are compressed (most music 0.05-0.42), so thresholds
        // must be low enough to actually trigger. Hi-hat/cymbal cleanup is subtle and
        // harmless even on false positives, so we err on the side of activating.
        if profile.energyA > 0.20 && profile.energyB > 0.15 {
            useHighShelf = true
            reasons.append("hi-shelf: energia A=\(String(format: "%.2f", profile.energyA)) B=\(String(format: "%.2f", profile.energyB))")
        }

        let reason = reasons.isEmpty ? "DJ filters OFF" : "DJ filters ON: \(reasons.joined(separator: ", "))"
        return DJFilterResult(useMidScoop: useMidScoop, useHighShelfCut: useHighShelf, reason: reason)
    }

    // MARK: - DJ Effects Decision (Bass Kill + Dynamic Q)

    struct DJEffectsResult {
        let useBassKill: Bool
        let useDynamicQ: Bool
        /// Phaser-style narrow notch on B's band 2 (Sprint 2 — pairs with dynQ for "DJ knob ride" feel).
        let useNotchSweep: Bool
        /// Stutter Cut: 1/8-note volume gate over A's last 2 beats before a CUT.
        /// Anchored to A's nearest real beat in downbeatTimesA so the chops align
        /// with the actual rhythmic grid. Strict gates protect against out-of-phase
        /// stuttering that would sound like a glitch instead of a DJ chop.
        let useStutterCut: Bool
        let reason: String
    }

    /// Decide whether to activate DJ effects based on the transition profile.
    /// Both effects are conservative: they only activate when conditions guarantee
    /// they'll sound good and won't interfere with the transition quality.
    static func decideDJEffects(
        profile: TransitionProfile,
        transitionType: TransitionType,
        fadeDuration: Double,
        isEnergyDown: Bool,
        needsAnticipation: Bool = false,
        skipBFilters: Bool = false,
        /// True when A has a non-empty beat grid that the executor can anchor to.
        /// Without this, Stutter Cut would chop blindly relative to wall-clock and
        /// land off-grid — sounding like a glitch rather than a DJ chop.
        hasBeatGridA: Bool = false
    ) -> DJEffectsResult {
        var useBassKill = false
        var useDynamicQ = false
        var useNotchSweep = false
        var useStutterCut = false
        var reasons: [String] = []

        // ── Bass Kill: instant low-frequency cut at bassSwapTime ──
        // Requirements:
        //   1. Transition character is punch or dramatic-up (groove-driven, intentional)
        //   2. BPM is trusted (so bassSwapTime is accurate)
        //   3. Danceability > 0.5 (bass-driven music benefits from the kill)
        //   4. Not a CUT/NATURAL_BLEND (too short or too invisible)
        //   5. Fade is long enough for the effect to register (>4s)
        let bassKillCompatibleType: Bool
        switch transitionType {
        case .eqMix, .beatMatchBlend, .crossfade, .cutAFadeInB, .fadeOutACutB:
            bassKillCompatibleType = true
        case .cut, .naturalBlend, .cleanHandoff, .stemMix, .dropMix, .vinylStop:
            // CLEAN_HANDOFF: A and B never overlap, no bass conflict to manage.
            // STEM_MIX: the stem swap IS the moment — A drops to stems, B enters
            //   on vocals/mids. Adding a hard bass kill on top muddies the
            //   intentional bass-less holding pattern of stem mix.
            // DROP_MIX: a 2–7s drop already runs an aggressive HPF ramp on A
            //   (600 → 6000Hz) and gradual bass swap. Adding bass kill on top
            //   creates 3 effects fighting in <4 seconds — feels rushed and busy.
            //   Trust the preset to do the work.
            // CUT: too short to register a kill musically.
            // NATURAL_BLEND: deliberately invisible, no DJ-y moments.
            // VINYL_STOP / ECHO_OUT: own gesture is the effect — no extra DJ tricks.
            bassKillCompatibleType = false
        }

        // Both sides need ≥ 0.20 energy: bassKill exists to prevent "double-bombo"
        // when both tracks have a kicking low-end at the same time. From Florida
        // With Love (energyA=0.06) → Ghost Town (energyB=0.14) had bassKill on
        // and B entering with a -8 dB shelf — neither side had enough bass for
        // the kill to make sense. The user heard it as "B sounds telephonic".
        if bassKillCompatibleType
            && profile.bpmTrusted
            && profile.avgDanceability > 0.5
            && fadeDuration > 4.0
            && profile.energyA >= 0.20 && profile.energyB >= 0.20
            && (profile.character == .punch || (profile.character == .dramatic && profile.energyFlow == .energyUp)) {
            useBassKill = true
            reasons.append("bassKill: dance=\(String(format: "%.2f", profile.avgDanceability)) energyA=\(String(format: "%.2f", profile.energyA)) energyB=\(String(format: "%.2f", profile.energyB))")
        }

        // ── Dynamic Q Resonance: bell-shaped Q sweep on highpass ──
        // Requirements:
        //   1. Not energy-down (uses lowpass, not highpass)
        //   2. Fade > 4s (sweep needs time for resonance to be audible)
        //   3. Character is punch or dramatic (not minimal/smooth — those should be invisible)
        //   4. Danceability > 0.45 (filter sweeps are a club/DJ technique)
        if !isEnergyDown
            && fadeDuration > 4.0
            && profile.avgDanceability > 0.45
            && (profile.character == .punch || (profile.character == .dramatic && profile.energyFlow != .energyDown)) {
            useDynamicQ = true
            reasons.append("dynQ: dance=\(String(format: "%.2f", profile.avgDanceability)) fade=\(String(format: "%.1f", fadeDuration))s")
        }

        // ── Phaser Notch Sweep (Sprint 2): narrow parametric on B's band 2 ──
        // Pairs with Dynamic Q for the "DJ knob ride" handoff feel — A's resonance
        // peaks late while B's notch sweeps through it from below.
        // Stricter conditions than dynQ — this effect is more colorful and we only
        // want it when there's clear room and intent:
        //   1. Dynamic Q is already on (philosophical pairing — same musical context)
        //   2. B's filters are NOT skipped (the notch lives on band 2 of B)
        //   3. NOT in anticipation mode (B already runs a complex multi-stage curve;
        //      stacking a sweep on top would muddy the careful tease)
        //   4. Fade > 5s (notch needs room to sweep musically)
        //   5. Danceability > 0.5 (it's a club/DJ technique, suits groove music)
        //   6. NOT a stem mix (the stem swap is its own dramatic moment — adding
        //      a colorful notch on top obscures the intentional vocal/mid-only
        //      character of B's entry; real DJs don't stack effects on stem moves)
        if useDynamicQ
            && !skipBFilters
            && !needsAnticipation
            && transitionType != .stemMix
            && fadeDuration > 5.0
            && profile.avgDanceability > 0.5 {
            useNotchSweep = true
            reasons.append("notchSweep: pair with dynQ, fade=\(String(format: "%.1f", fadeDuration))s")
        }

        // ── Stutter Cut (Sprint 3): 1/8-note volume gate over A's last 2 beats ──
        // Hip-hop DJ signature — DJ Premier mixtape style. The chops MUST land on
        // A's actual beat grid, otherwise it sounds like a glitch instead of music.
        // Strict gates protect against every known failure mode:
        //   1. Only CUT-family transitions — blends already overlap, no need to chop
        //   2. bpmTrusted: untrusted BPM means the beat grid is unreliable, the
        //      stutter would be visibly out of phase
        //   3. bpmA in [80, 180]: at <80, 1/8 = >375ms (too slow, sounds half-time);
        //      at >180, 1/8 = <167ms (sounds like a buzz, not a chop)
        //   4. Danceability > 0.55: rhythmic music only — stutter on ambient/jazz
        //      kills the atmosphere
        //   5. fadeDuration >= 1.5s: need at least 2 beats at 80 BPM (1.5s) to fit
        //      the 4-cell pattern. Shorter fades skip the effect.
        //   6. hasBeatGridA: required for runtime anchor lookup. Without it the
        //      executor can't find the nearest real beat to the cut moment.
        // The executor performs an additional runtime check: it verifies the cut
        // moment is within beatInterval/4 of an actual beat. If not, the gate is
        // bypassed (graceful degradation — the CUT still happens, just no chop).
        let stutterCompatibleType = (transitionType == .cut || transitionType == .cutAFadeInB)
        if stutterCompatibleType
            && profile.bpmTrusted
            && profile.bpmA >= 80
            && profile.bpmA <= 180
            && profile.avgDanceability > 0.55
            && fadeDuration >= 1.5
            && hasBeatGridA {
            useStutterCut = true
            reasons.append("stutter: cut@\(Int(profile.bpmA))BPM dance=\(String(format: "%.2f", profile.avgDanceability))")
        }

        // ── Energy-A floor: soften slow-modulating effects when A is low-energy ──
        // Backend energy values are compressed (most music falls 0.05–0.30), so
        // anything under 0.15 is a low-energy passage — either tail/decay (Rich Flex
        // → Earfquake at 0.04) or a quiet bridge/breakdown. notchSweep / dynQ /
        // stutterCut applied to that audio sounds artificial — a filter modulating
        // near-silence reads as "filter weirdness" rather than as DJ technique.
        // bassKill is fine (it's an instant cut, not a sweep) so we leave it intact.
        // The previous 0.10 threshold was too strict — it only covered the bottom
        // ~10% of cases, missing transitions like Rich Flex→Earfquake where energyA
        // is low-but-not-floor and the filters still felt off.
        if profile.energyA < 0.15 && (useDynamicQ || useNotchSweep || useStutterCut) {
            useDynamicQ = false
            useNotchSweep = false
            useStutterCut = false
            reasons.append("⚠️ energyA<0.15: soft (no dynQ/notch/stutter)")
        }

        let reason = reasons.isEmpty
            ? "DJ effects OFF"
            : "DJ effects ON: \(reasons.joined(separator: ", "))"
        print("[DJMixingService] \(reason)")
        return DJEffectsResult(useBassKill: useBassKill, useDynamicQ: useDynamicQ,
                               useNotchSweep: useNotchSweep, useStutterCut: useStutterCut,
                               reason: reason)
    }

    // MARK: - Anticipation

    struct AnticipationResult {
        let needsAnticipation: Bool
        let anticipationTime: Double
        let reason: String
    }

    static func decideAnticipation(fadeDuration: Double, entryPoint: Double, transitionType: TransitionType, noRealOutro: Bool = false, transitionReason: String = "") -> AnticipationResult {
        // No-real-outro guard: A is in full groove until the very end, so
        // anticipation (which pre-mutes A for 2-4s before the fade starts)
        // would cut material the listener is still expecting. This is one of
        // two coordinated guards — calculateCrossfadeConfig also caps the
        // entry point so the trigger fires close to A's actual end.
        if noRealOutro {
            return AnticipationResult(needsAnticipation: false, anticipationTime: 0,
                                      reason: "Sin anticipacion: A sin outro real (groove hasta el final)")
        }

        // Safety-forced CUT (Vocal Trainwreck / Polirritmia): the goal is to
        // evade a clash, not to artistically preview B. The 4s anticipation
        // tease still arms preset=anticipation and emits filtered B at low
        // gain before the kick — perceived as "B con fade innecesario" in
        // Can I Kick It?→Munch and THE zone~→Girls Want Girls.
        // Outro-instrumental + B-abrupta CUT keeps its tease (T19 AIR FORCE
        // → Can I Kick It? 10/10 depends on this — its reason does not
        // contain these markers).
        if transitionType == .cut && (
            transitionReason.contains("Vocal Trainwreck") ||
            transitionReason.contains("Polirritmia")
        ) {
            return AnticipationResult(needsAnticipation: false, anticipationTime: 0,
                                      reason: "Sin anticipacion: CUT forzado por safety (no tease)")
        }

        let hasEnoughIntro = entryPoint >= 5

        // DROP_MIX: no anticipation — B enters clean and punchy, no teasing.
        if transitionType == .dropMix {
            return AnticipationResult(needsAnticipation: false, anticipationTime: 0,
                                      reason: "Sin anticipacion: DROP_MIX — entrada directa")
        }

        // CLEAN_HANDOFF: no anticipation — B enters from silence after a respiro,
        // there's nothing to "tease" because the whole point is sequentiality.
        if transitionType == .cleanHandoff {
            return AnticipationResult(needsAnticipation: false, anticipationTime: 0,
                                      reason: "Sin anticipacion: CLEAN_HANDOFF — entrada secuencial")
        }

        // VINYL_STOP: same as clean handoff — A's spin-down owns the moment,
        // B should NOT be teased. Teasing during a spin-down kills the drama.
        if transitionType == .vinylStop {
            return AnticipationResult(needsAnticipation: false, anticipationTime: 0,
                                      reason: "Sin anticipacion: VINYL_STOP — gesto de A primero")
        }

        // CUT-specific: tease B filtered before the hard swap — this is how DJs
        // preview the next track even when BPMs are incompatible.
        if transitionType == .cut && hasEnoughIntro {
            let time = min(4.0, max(2.5, entryPoint * 0.3))
            return AnticipationResult(needsAnticipation: true, anticipationTime: time,
                                      reason: "Anticipacion CUT: tease +\(String(format: "%.1f", time))s antes del swap")
        }

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
        hasVocalOverlap: Bool = false,
        outroInstrumental: Bool = false,
        introInstrumental: Bool = false
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

        // Beat-match eligibility: stricter than "mixable". A 12–18 BPM diff is
        // close enough to blend gently but too far for time-stretch (>8% rate
        // change becomes audible), and beat-grid alignment without time-stretch
        // produces unaligned kicks across the fade. So beat-match requires
        // identical or compatible (≤12 BPM diff), NOT borderline or incompatible.
        let bpmBeatMatchable = profile.bpmRelationship == .identical
            || profile.bpmRelationship == .compatible

        var type: TransitionType = .crossfade
        var reason = "Transicion normal"

        // Very short fades: force CUT
        if fadeDuration < 3 {
            type = .cut
            // CUT clamps fadeDuration to [3, 7] downstream, so log raw + ejecutado
            // for the diagnostic log to match the TIMING line.
            reason = "Fade muy corto (raw=\(String(format: "%.1f", fadeDuration))s, ejecutado=3.0s) → CUT directo"
        }
        // ── Character-biased selection ──
        else {
            // When B was harmonic-normalized (half/double-time), surface the mapping
            // so REASON's diff matches what's in the ANALYSIS block (which prints raw).
            let bpmNote = profile.bpmBNormalized != profile.bpmB
                ? " [B \(Int(profile.bpmB))→\(Int(profile.bpmBNormalized)) half-time]"
                : ""
            switch profile.character {
            case .minimal:
                // Both low energy — gentle blend, no beat matching needed
                type = .naturalBlend
                reason = "Minimal (ambos baja energia) → NATURAL_BLEND suave"

            case .smooth:
                switch profile.bpmRelationship {
                case .incompatible:
                    let energyDrop = profile.energyA - profile.energyB
                    if outroInstrumental && introInstrumental {
                        // Both ends are instrumental — there's no rapping/voice clash to
                        // worry about, only the rhythmic mismatch. A long gentle crossfade
                        // with mid-scoop and bass cut is far better than a clean handoff
                        // here: the instrumentation can blend without sounding muddy.
                        type = .crossfade
                        reason = "BPMs incompatibles (diff=\(String(format: "%.1f", profile.bpmDiff)))\(bpmNote) pero ambos instrumentales → CROSSFADE gentle"
                    } else if outroInstrumental && !introInstrumental {
                        // Mirror → GOOD CREDIT case: A's outro decays into synths/pad while
                        // B opens hard with a kick + vocal. A long blend muddies the synth
                        // tail under the abrupt kick. A clean handoff drops to silence and
                        // the kick re-enters cold. Best human-DJ analogue: punch through
                        // with a short CUT — A's instrumental nature means there's no vocal
                        // to sever, so the cut is musically defensible.
                        type = .cut
                        reason = "Outro instrumental A + intro abrupta B (incompatible)\(bpmNote) → CUT"
                    } else if energyDrop > 0.30 && profile.energyA > 0.25
                              && !isOnCooldown(.vinylStop) {
                        // A is intense and B is markedly quieter — textbook VINYL_STOP.
                        // The spin-down punctuates the energy crash; cooldown ensures
                        // it doesn't fire on every other transition.
                        type = .vinylStop
                        reason = "BPMs incompatibles + energy drop \(String(format: "%.2f→%.2f", profile.energyA, profile.energyB))\(bpmNote) → VINYL_STOP"
                    } else {
                        // Two unmixable tracks with vocals/punch. A 5–10s blend would
                        // force them to share the mid-crossfade at near-equal volumes
                        // (equal-power curve), and with incompatible tempos that sounds
                        // like rhythmic mud. Use sequential handoff: A exits cleanly,
                        // micro-respiro (~300ms post-P0 fix), B enters fresh.
                        type = .cleanHandoff
                        reason = "BPMs incompatibles (diff=\(String(format: "%.1f", profile.bpmDiff)))\(bpmNote) → CLEAN_HANDOFF (sin overlap)"
                    }
                case .borderline:
                    // 12–18 BPM diff — too far for invisible beat-match but close enough
                    // that a thoughtful blend still works. Route to NATURAL_BLEND so we
                    // get the gentle preset (subtle highpass on A, mild bass cut, mid
                    // scoop) plus equal-power curve and zero DJ effects. The result
                    // sounds like a DJ who can't beat-grid the pair but is doing the
                    // most graceful blend possible — invisible filtering, no obvious
                    // sweeps, no resonance tricks. Avoids both the rhythmic clash of
                    // a punchy crossfade AND the dead-air of a clean handoff.
                    type = .naturalBlend
                    reason = "BPMs borderline (diff=\(String(format: "%.1f", profile.bpmDiff)))\(bpmNote) → NATURAL_BLEND sutil"
                case .identical, .compatible:
                    type = .crossfade
                    reason = "Smooth blend (afinidad=\(String(format: "%.2f", profile.styleAffinity))) → CROSSFADE"
                }

            case .dramatic:
                // Big energy change or harmonic clash
                if profile.energyFlow == .energyUp && bpmBeatMatchable && isBeatSynced {
                    // Energy rising with compatible BPMs — can do an impactful beat-matched entry
                    type = .beatMatchBlend
                    reason = "Dramatic UP + BPMs compatibles → BEAT_MATCH_BLEND (energia \(String(format: "%.2f→%.2f", profile.energyA, profile.energyB)))"
                } else if profile.energyFlow == .energyDown {
                    let energyDrop = profile.energyA - profile.energyB
                    if energyDrop > 0.35 && profile.energyA > 0.30 && !isOnCooldown(.vinylStop) {
                        // Hard energy crash — A is loud, B is whisper-quiet. A natural
                        // blend would just slowly drown A; a vinyl-stop punctuates the
                        // mood change. Cooldown prevents this firing on every drop.
                        type = .vinylStop
                        reason = "Dramatic DOWN extremo (energia \(String(format: "%.2f→%.2f", profile.energyA, profile.energyB))) → VINYL_STOP"
                    } else {
                        // Energy dropping but not a crash — gentle fade, let A die gracefully.
                        type = .naturalBlend
                        reason = "Dramatic DOWN → NATURAL_BLEND (energia \(String(format: "%.2f→%.2f", profile.energyA, profile.energyB)))"
                    }
                } else if profile.harmonic.compatibility == .clash {
                    // Harmonic clash with steady energy — crossfade (shorter, from fade duration)
                    type = .crossfade
                    reason = "Clash armonico → CROSSFADE corto"
                } else {
                    type = .crossfade
                    reason = "Dramatic steady → CROSSFADE"
                }

            case .punch:
                // ── VINYL_STOP: bass-heavy A handing off to a hard, abrupt B ──
                // Rule (DJ): the spin-down is a "look here, switch incoming" gesture
                // that only works when B re-opens with a kick. If B is slow or
                // atmospheric, the frenada queda colgando. Identical BPMs prefer a
                // clean beat-match (no need for a gesture). The cooldown prevents
                // it firing on every other transition. fadeDuration ≥ 3 because
                // CUT clamps below that and we'd be fighting the safety override.
                let bIntroLen: Double = {
                    guard let next = nextAnalysis, next.hasError != true else { return 30 }
                    return next.introEndTimeHeuristic ?? (next.hasIntroData ? next.introEndTime : 30)
                }()
                let bChorusStart: Double = {
                    guard let next = nextAnalysis, next.hasError != true else { return 30 }
                    return next.chorusStartTime > 0 ? next.chorusStartTime : 30
                }()
                let bIsAbruptIntro = !introInstrumental
                    && (bChorusStart < 3 || bIntroLen < 2)
                    && profile.energyB > 0.20
                let aIsBassHeavy = profile.energyA > 0.30 && profile.avgDanceability > 0.50
                let vinylStopFits = !isOnCooldown(.vinylStop)
                    && aIsBassHeavy
                    && bIsAbruptIntro
                    && profile.bpmRelationship != .identical
                    && fadeDuration >= 3

                // ── DROP_MIX: short intro on B or very short fade ──
                // Hip hop / R&B / K-Pop technique: quick HPF ramp out on A, B enters clean.
                // Triggers when B's intro is too short for a long blend, or the fade
                // was already capped short by the intro window.
                let useDropMix = fadeDuration < 5 || (bIntroLen < 12 && fadeDuration < 7)

                if vinylStopFits {
                    type = .vinylStop
                    reason = "Punch + bass-heavy A + B abrupta (chorus B=\(String(format: "%.0f", bChorusStart))s)\(bpmNote) → VINYL_STOP"
                }
                else if useDropMix && fadeDuration >= 2 {
                    type = .dropMix
                    reason = "Punch + intro B corta (\(String(format: "%.0f", bIntroLen))s) → DROP_MIX (\(String(format: "%.1f", fadeDuration))s)"
                }
                // ── Full DJ treatment ──
                // Guard: STEM_MIX requires bpmDiff < 6. The mid-scoop and dynamic-Q
                // can hide subtle phase drift but not a 16 BPM gap — that becomes
                // audible rhythmic mud no matter how aggressive the EQ shaping.
                // Plus: energyB > 0.10 — STEM_MIX layers B over A's stem-removed
                // outro for 6-12s. When B is nearly inaudible (energyB ≤ 0.10),
                // those long overlaps read as "B fading in slowly" instead of
                // as a stem swap. New Magic Wand → Way 2 Sexy: energyB=0.03,
                // user "B entra con fade, deberia entrar perfecto sin fades".
                // Falls through to beatMatchBlend (shorter, lighter B shaping;
                // the quiet-B gate in step 8c also forces skipBFilters there).
                // Verified preserves T30 Sky→Silent Hill (energyB=0.12, 10/10)
                // and T46 No More Parties→One Beer (energyB=0.17, 10/10).
                else if isBeatSynced && !isAAbrupt && !isBAbrupt && fadeDuration >= 6
                    && hasVocalOverlap && profile.bpmDiff < 6 && profile.energyB > 0.10 {
                    type = .stemMix
                    reason = "Punch + vocales solapadas + fade≥6s → STEM_MIX (diff=\(String(format: "%.1f", profile.bpmDiff)))\(bpmNote)"
                } else if isBeatSynced && !isAAbrupt && !isBAbrupt {
                    type = .beatMatchBlend
                    reason = "Punch + beats sync (diff=\(String(format: "%.1f", profile.bpmDiff)))\(bpmNote) → BEAT_MATCH_BLEND"
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
        let bpmCutThreshold: Double = useFilters ? 35 : 20
        if profile.bpmDiff > bpmCutThreshold && fadeDuration > 3 && type != .cut {
            type = .cut
            let normalizedNote = profile.bpmBNormalized != profile.bpmB ? " (norm:\(Int(profile.bpmBNormalized)))" : ""
            reason = "Polirritmia evitada (A:\(Int(profile.bpmA)) B:\(Int(profile.bpmB))\(normalizedNote) diff=\(String(format: "%.1f", profile.bpmDiff))) → CUT forzado"
        }

        // ── Override: energy crash A → instrumental B ──
        // Bricksquad → MAMA'S FAVORITE in v6: energyA=0.48 (kick + bass + voice)
        // crashing into MAMA'S energyB=0.22 instrumental intro. CUT or short
        // crossfade lands as a slap; the listener feels "the song slammed shut".
        // FADE_OUT_A_CUT_B with fade ≥ 5s lets A breathe out gracefully while B
        // emerges from its instrumental intro. Guard requires ≥6s of intro on B
        // so the boosted fade fits inside the instrumental window. Skip when BPM
        // is incompatible (CLEAN_HANDOFF / VINYL_STOP already handle that path)
        // or when type was already a sequential gesture.
        let bIntroSpace: Double = {
            guard let next = nextAnalysis, next.hasError != true else { return 0 }
            return next.introEndTimeHeuristic ?? (next.hasIntroData ? next.introEndTime : 0)
        }()
        if profile.energyA > 0.40 && profile.energyB < 0.25
            && introInstrumental
            && bIntroSpace >= 6
            && profile.bpmRelationship != .incompatible
            && (type == .cut || type == .crossfade || type == .naturalBlend) {
            type = .fadeOutACutB
            reason = "Energy crash A→B instrumental (\(String(format: "%.2f→%.2f", profile.energyA, profile.energyB))) → FADE_OUT_A_CUT_B"
        }

        // ── Safety: vocal trainwreck — refine with actual fade zone ──
        if let current = currentAnalysis, current.hasError != true,
           let next = nextAnalysis, next.hasError != true,
           type != .cut && type != .stemMix {

            // vocalStart unwrap: nil → 0 (safe sentinel for arithmetic).
            // The `> 0` guard below filters both nil and the literal 0.0
            // case (vocal-at-t=0 means vocals start AT entryPoint or earlier
            // → vocalBStart ≤ 0 → bHasVocalsInFade still true via direct check).
            let vsB = next.vocalStartTime ?? 0
            let vocalBStart = vsB - entryPoint
            // bHasVocalsInFade: known vocal onset > 0 AND lands inside fade,
            // OR literal vocal-at-t=0 (vsB known to be 0 means voice from
            // file start; if entryPoint>0 we've already missed vocals so
            // they're not "in fade", but hasIntroVocals flag still flags it).
            let bHasVocalsInFade = (next.vocalStartTime ?? -1) > 0 && vocalBStart < fadeDuration
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
                        && (current.vocalStartTime ?? 0) > 0
                }

                if aHasVocalsAtEnd {
                    let bInstrumentalWindow = vsB - entryPoint
                    if bInstrumentalWindow > fadeDuration * 0.6 {
                        reason += " (vocal overlap OK: B vocals after \(String(format: "%.0f", bInstrumentalWindow))s)"
                    } else {
                        type = .cut
                        reason = "Vocal Trainwreck evitado → CUT forzado"
                    }
                }
            }
        }

        // Record the final type for cooldown bookkeeping. Done at the end so the
        // safety overrides above (polirritmia, vocal trainwreck) are also tracked.
        recordTransition(type)

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
        case .cut, .cutAFadeInB, .fadeOutACutB, .cleanHandoff:
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: transicion tipo cut/handoff")
        case .vinylStop:
            // Vinyl stop OWNS the rate ramp on A (1.0 → 0). No global time-stretch
            // decision applies — the curve is driven directly by the executor.
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: rate ramp owned por VINYL_STOP")
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
        let maxRateChange: Float = 0.08  // 8% — still inaudible with time-domain stretching

        if diff < 3 {
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: BPMs casi iguales (±\(String(format: "%.1f", diff)))")
        } else if diff <= 8 {
            let rateB = Float(profile.bpmA / profile.bpmBNormalized)
            if abs(rateB - 1.0) > maxRateChange {
                return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                         reason: "No stretch: rate \(String(format: "%.1f", abs(rateB - 1.0) * 100))% > 8% (audible)")
            }
            return TimeStretchResult(useTimeStretch: true, rateA: 1.0, rateB: rateB,
                                     reason: "Stretch B→A: \(Int(profile.bpmBNormalized))→\(Int(profile.bpmA)) BPM (rate=\(String(format: "%.3f", rateB)))")
        } else if diff <= 15 {
            let mid = (profile.bpmA + profile.bpmBNormalized) / 2.0
            let rateA = Float(mid / profile.bpmA)
            let rateB = Float(mid / profile.bpmBNormalized)
            if abs(rateA - 1.0) > maxRateChange || abs(rateB - 1.0) > maxRateChange {
                return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                         reason: "No stretch: rate change > 8% (A:\(String(format: "%.1f", abs(rateA - 1.0) * 100))% B:\(String(format: "%.1f", abs(rateB - 1.0) * 100))%)")
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

        // ── Fake-outro guard ──
        // Trap and conscious hip-hop frequently have a *false outro* — energy dips
        // for 4-8 bars, then a final verse / ad-lib comes back. The backend's
        // hasOutroVocals can lie when the model trained on song-level features.
        // If we have hard evidence of vocals in the last 4 seconds, override to
        // not-instrumental regardless of any other signal. The 4s window is
        // independent of fadeDuration so a long fade (15s) doesn't mask a late
        // vocal that lands inside the perceptual "outro" of the song.
        // Skip for songs shorter than 4s (impossible for real music tracks but
        // defensive against malformed bufferADuration); negative last4sStart
        // would make any positive lastVocalTime trigger the override.
        if bufferADuration >= 4.0 {
            let last4sStart = bufferADuration - 4.0
            if cur.hasVocalEndData && cur.lastVocalTime > last4sStart {
                return false
            }
            if !cur.speechSegments.isEmpty
                && cur.speechSegments.contains(where: { $0.end > last4sStart }) {
                return false
            }
        }

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

    /// Detect if B's intro is instrumental in the actual entry/fade zone.
    /// Uses the same vocal-aware reference as entry point calculation:
    /// vocalStartTime → speechSegments[0] → backend flags.
    private static func detectIntroInstrumental(
        nextAnalysis: SongAnalysis?,
        profile: TransitionProfile,
        entryPoint: Double,
        fadeDuration: Double
    ) -> Bool {
        guard let nxt = nextAnalysis, nxt.hasError != true else { return false }
        let bEnd = entryPoint + fadeDuration

        // NOTE on vocalStartTime == 0.0 literal semantics (post-backend
        // 2026-05-01): backend confirms 0.0 is "vocal at t=0", but until the
        // backfill batch completes, cached entries written under the old
        // pipeline still have 0.0 as a camouflaged null. Treating 0.0 as
        // literal "no instrumental window" right now would mis-flag tracks
        // like Wu-Tang Forever (real instrumental intro ~50s) cached pre-fix.
        // Once the backfill is done and caches refreshed, swap the chain
        // below to: `if vocalStartTime == 0.0 { return false }` first.

        // Vocal onset: when B's vocals actually start
        let vocalOnset: Double = {
            if let vs = nxt.vocalStartTime, vs > 0 { return vs }
            if let first = nxt.speechSegments.first, first.start > 0 { return first.start }
            return 0
        }()

        if vocalOnset > 0 {
            if vocalOnset <= bEnd {
                if nxt.hasVocalData && !nxt.hasIntroVocals {
                    print("[DJMixingService] ⚠️ Backend says no intro vocals, but vocalOnset (\(String(format: "%.1f", vocalOnset))s) is within fade zone")
                }
                return false
            }
            return true
        }

        // No vocal timing data — fall back to backend flags
        if nxt.hasVocalData && nxt.hasEnergyProfile && !nxt.hasIntroVocals {
            return true
        }
        return false
    }

    // MARK: - CUT entry snap to downbeat

    /// Snap `entry` to a clean musical landmark when the transition is CUT-family
    /// and `next.chorusStartTime` is reachable. Without this, CUT can land in a
    /// "dead zone" — typically 0.5–1.5s before the chorus drop — which sounds
    /// like the cut fired half a beat early ("sosa", per the user's listening on
    /// Stir Fry → Vamp Anthem).
    ///
    /// Strategy: candidates are `chorusStart`, `chorusStart - 1 bar`, and
    /// `chorusStart - 2 bars`. Pick the candidate CLOSEST to the original entry
    /// — minimises the shift while still leaving the dead zone. Each candidate
    /// must be ≥ entry + 0.5s (avoid trivial sub-perceptual snaps), ≥ 0 and
    /// within reach of B's playable window. If `downbeatTimes` are available
    /// and one sits within 0.3s of the chosen candidate, snap to the actual
    /// downbeat (real grid > theoretical bar).
    ///
    /// No-op for non-cut transitions, missing analysis, original entry already
    /// at/past chorus, or original entry more than 2 bars before chorus (the
    /// user's deliberate "early CUT" intent must be respected). Reggaeton
    /// (STEM_MIX / BEAT_MATCH_BLEND) never reaches this path.
    private static func snapCutEntryToDownbeat(
        entry: Double,
        transitionType: TransitionType,
        next: SongAnalysis?,
        bufferBDuration: Double,
        fadeDuration: Double
    ) -> (entry: Double, snapped: Bool, info: String) {
        guard transitionType == .cut || transitionType == .cutAFadeInB else {
            return (entry, false, "")
        }
        guard let next = next, next.hasError != true else { return (entry, false, "") }
        guard next.chorusStartTime > 0.5 else { return (entry, false, "") }

        let chorusStart = next.chorusStartTime
        // Already at/past the chorus — don't move (the rare case where the entry
        // calc already targeted past the chorus, e.g. for repeat-chorus tracks).
        if entry >= chorusStart - 0.3 { return (entry, false, "") }

        let beatInterval = next.beatInterval > 0 ? next.beatInterval : 0.5
        let bar = beatInterval * 4

        // Reachability guard. The DJ's rule: cutPoint ∈ {chorus, chorus−1 bar,
        // chorus−2 bars}. So the snap only makes sense when the original entry
        // is WITHIN 2 bars of chorusStart. Beyond that, the user's entry was a
        // deliberate "early CUT" (e.g. DNA → Mask Off at 12.9s vs chorus 23.6s
        // — 10.7s = ~4 bars away — the user wanted the cold cut, not chorus
        // alignment) and we must respect it.
        guard entry >= chorusStart - 2 * bar else { return (entry, false, "") }

        let maxEntry = max(0, bufferBDuration - fadeDuration - 0.5)

        // Candidates: AT chorusStart (drop), 1 bar before, 2 bars before. Pick
        // the one CLOSEST to the original entry — minimises the shift while
        // still leaving the dead zone. This means a CUT whose entry was already
        // far before the chorus stays mostly there (just snapped to a clean bar
        // boundary), while a CUT whose entry was in the dead zone gets pushed
        // to either chorusStart itself or the bar before (whichever is closer).
        // Each candidate must be ≥ entry + 0.5s (avoid trivial snaps), ≥ 0 and
        // ≤ maxEntry.
        let candidates: [Double] = [chorusStart, chorusStart - bar, chorusStart - 2 * bar]
            .filter { $0 >= 0 && $0 <= maxEntry && $0 >= entry + 0.5 }

        guard let target = candidates.min(by: { abs($0 - entry) < abs($1 - entry) })
        else { return (entry, false, "") }

        // Snap to actual downbeat if available within 0.3s.
        let snapped: Double
        if !next.downbeatTimes.isEmpty,
           let nearest = next.downbeatTimes.min(by: { abs($0 - target) < abs($1 - target) }),
           abs(nearest - target) < 0.3 {
            snapped = nearest
        } else {
            snapped = target
        }

        let label = snapped >= chorusStart - 0.2 ? "AT chorus" :
                    snapped >= chorusStart - bar - 0.2 ? "−1 bar" : "−2 bars"
        let info = "CUT snap \(String(format: "%.1f", entry))s → \(String(format: "%.1f", snapped))s (\(label) of chorus@\(String(format: "%.1f", chorusStart))s)"
        return (snapped, true, info)
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
