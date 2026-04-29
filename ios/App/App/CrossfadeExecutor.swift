// ╔══════════════════════════════════════════════════════════════════════╗
// ║                                                                      ║
// ║   CrossfadeExecutor — Part of "Velvet Transition" v3.0               ║
// ║   Codename: "Phantom Cut"                                            ║
// ║                                                                      ║
// ║   Audiorr — Audiophile-grade music player                            ║
// ║   Copyright (c) 2025-2026 cha0sisme (github.com/cha0sisme)          ║
// ║                                                                      ║
// ║   Real-time crossfade execution engine. Drives volume curves,        ║
// ║   EQ automation, beat-aligned bass swap, time-stretch rate ramp,    ║
// ║   energy compensation, and stereo micro-separation at ~60Hz          ║
// ║   via DispatchSourceTimer.                                           ║
// ║                                                                      ║
// ║   v2.0 — Velvet Transition: equal-power curves, bass swap,           ║
// ║          beat-aligned automation, filter presets                      ║
// ║   v3.0 — Phantom Cut: hold→drop volume curves, complementary B      ║
// ║          curve, hold→drop-aligned filter pivot (60%), punch           ║
// ║          alignment (startOffset = entryPoint - totalTime),            ║
// ║          bass-first mixing (25%), stereo micro-separation (±0.08),   ║
// ║          PeakLimiter on mainMixer, skipBFilters for short fades      ║
// ║                                                                      ║
// ╚══════════════════════════════════════════════════════════════════════╝

import AVFoundation
import QuartzCore
import Foundation
import UIKit

/// CrossfadeExecutor — real-time crossfade state machine.
/// Part of the "Phantom Cut" v3.0 engine.
/// Drives volume curves (equal-power, beat-match, EQ mix), filter automation,
/// beat-aligned bass swap, time-stretch rate ramp, and energy compensation.
class CrossfadeExecutor {

    // MARK: - Tipos

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
        /// Sequential handoff: A descends cos² (no overlap with B), tiny silent gap
        /// (~10% of window = 300ms in a 3s fade), then B sin² ramps in. Used for
        /// fundamentally unmixable pairings.
        case cleanHandoff = "CLEAN_HANDOFF"
        /// Vinyl-stop / spin-down: A's playback rate ramps 1.0→0 over ~450ms with
        /// curve `1 - p^0.6`, then ~200ms of silence, then B sin² ramps. Used for
        /// dramatic energy crashes or incompatible BPMs with a big drop.
        /// Mirrors DJMixingService.TransitionType.vinylStop — rawValues must match.
        case vinylStop = "VINYL_STOP"
    }

    struct Config {
        let entryPoint: Double
        let fadeDuration: Double
        let transitionType: TransitionType
        let useFilters: Bool
        let useAggressiveFilters: Bool
        let needsAnticipation: Bool
        let anticipationTime: Double
        // Time-stretch
        let useTimeStretch: Bool
        let rateA: Float
        let rateB: Float
        // Energy (for preset selection + volume compensation)
        let energyA: Double
        let energyB: Double
        // Beat grid (for beat-aware bass swap and time-stretch alignment)
        let beatIntervalA: Double
        let beatIntervalB: Double
        let downbeatTimesA: [Double]
        let downbeatTimesB: [Double]
        // DJ-grade filters: activated by analysis
        let useMidScoop: Bool       // Anti-clash vocal: dip mids on A when vocals overlap
        let useHighShelfCut: Bool   // Hi-hat cleanup: attenuate highs on A
        // Backend analysis intelligence
        let isOutroInstrumental: Bool   // A's outro is instrumental — lighter filters
        let isIntroInstrumental: Bool   // B's intro is instrumental — skip mid-scoop
        let danceability: Double        // High = preserve bass/groove (less aggressive HPF/lowshelf)
        let skipBFilters: Bool          // Short outro/fade — B enters clean (no highpass/lowshelf)
        // DJ effects (Sprint 1)
        let useBassKill: Bool           // Instant bass cut at bassSwapTime (DJ bass kill fader)
        let useDynamicQ: Bool           // Bell-shaped Q resonance sweep on highpass A (+ B mirror, see useNotchSweep paragraph)
        // DJ effects (Sprint 2 — companion sweeps on B for "DJ knob ride" handoff)
        /// Phaser-style narrow parametric notch on B's band 2: center freq sweeps
        /// 250→6000Hz exponentially while depth follows a bell (-6 → -24 → -6 dB).
        /// Always rides alongside Twin dynQ (the Q bell on B's band 0) so B sounds
        /// like a DJ "riding the filter knob" as it comes in.
        let useNotchSweep: Bool
        // DJ effects (Sprint 3 — hip-hop signature)
        /// Stutter Cut: 1/8-note volume gate over A's last 2 beats before a CUT.
        /// Gated by decideDJEffects to bpmTrusted + bpmA in [80,180] + danceability
        /// > 0.55 + hasBeatGridA. The executor still performs an additional runtime
        /// check (cut moment within beatInterval/4 of a real beat) before activating.
        let useStutterCut: Bool

        init(entryPoint: Double, fadeDuration: Double, transitionType: TransitionType,
             useFilters: Bool, useAggressiveFilters: Bool, needsAnticipation: Bool,
             anticipationTime: Double, useTimeStretch: Bool = false,
             rateA: Float = 1.0, rateB: Float = 1.0,
             energyA: Double = 0.5, energyB: Double = 0.5,
             beatIntervalA: Double = 0, beatIntervalB: Double = 0,
             downbeatTimesA: [Double] = [], downbeatTimesB: [Double] = [],
             useMidScoop: Bool = false, useHighShelfCut: Bool = false,
             isOutroInstrumental: Bool = false, isIntroInstrumental: Bool = false,
             danceability: Double = 0.5, skipBFilters: Bool = false,
             useBassKill: Bool = false, useDynamicQ: Bool = false,
             useNotchSweep: Bool = false,
             useStutterCut: Bool = false) {
            self.entryPoint = entryPoint
            self.fadeDuration = fadeDuration
            self.transitionType = transitionType
            self.useFilters = useFilters
            self.useAggressiveFilters = useAggressiveFilters
            self.needsAnticipation = needsAnticipation
            self.anticipationTime = anticipationTime
            self.useTimeStretch = useTimeStretch
            self.rateA = rateA
            self.rateB = rateB
            self.energyA = energyA
            self.energyB = energyB
            self.beatIntervalA = beatIntervalA
            self.beatIntervalB = beatIntervalB
            self.downbeatTimesA = downbeatTimesA
            self.downbeatTimesB = downbeatTimesB
            self.useMidScoop = useMidScoop
            self.useHighShelfCut = useHighShelfCut
            self.isOutroInstrumental = isOutroInstrumental
            self.isIntroInstrumental = isIntroInstrumental
            self.danceability = danceability
            self.skipBFilters = skipBFilters
            self.useBassKill = useBassKill
            self.useDynamicQ = useDynamicQ
            self.useNotchSweep = useNotchSweep
            self.useStutterCut = useStutterCut
        }
    }

    struct Timings {
        let startTime: Double              // CACurrentMediaTime() al iniciar
        let anticipationStartTime: Double
        let filterStartTime: Double
        let volumeFadeStartTime: Double
        let transitionEndTime: Double
        let filterLead: Double
        let fadeOutDuration: Double
        let totalTime: Double
        let fadeInStartTime: Double
        let fadeInEndTime: Double
        let startOffset: Double            // donde B empieza en su archivo
    }

    struct FilterPreset {
        struct Highpass { let startFreq: Float; let midFreq: Float; let endFreq: Float; let q: Float }
        struct Lowpass { let startFreq: Float; let endFreq: Float; let q: Float }
        struct Lowshelf { let frequency: Float; let startGain: Float; let midGain: Float; let endGain: Float }
        /// Parametric mid scoop: dips midrange on A to avoid vocal clashing with B.
        struct MidScoop { let frequency: Float; let bandwidth: Float; let startGain: Float; let endGain: Float }
        /// High-shelf cut: attenuates hi-hats/cymbals on A so B's highs come through clean.
        struct HighShelfCut { let frequency: Float; let startGain: Float; let endGain: Float }
        let highpassA: Highpass
        let highpassB: Highpass
        let lowshelfA: Lowshelf?     // Bass swap: atenúa bajos de A coordinado con B
        let lowshelfB: Lowshelf
        let lowpassA: Lowpass?       // Lowpass sweep para energy-down transitions
        let midScoopA: MidScoop?     // Anti-clash vocal: parametric dip ~1.5kHz on A
        let highShelfA: HighShelfCut? // Hi-hat cleanup: shelf cut ~8kHz on A
    }

    // MARK: - Presets (port exacto de AudioEffectsChain.ts líneas 20-83)

    static let presetNormal = FilterPreset(
        highpassA: .init(startFreq: 400, midFreq: 4000, endFreq: 8000, q: 1.1),
        highpassB: .init(startFreq: 400, midFreq: 200, endFreq: 60, q: 0.6),
        lowshelfA: .init(frequency: 200, startGain: 0, midGain: -6, endGain: -14),
        lowshelfB: .init(frequency: 200, startGain: -8, midGain: -4, endGain: 0),
        lowpassA: nil,
        midScoopA: .init(frequency: 1500, bandwidth: 1.2, startGain: 0, endGain: -12),
        highShelfA: .init(frequency: 8000, startGain: 0, endGain: -8)
    )

    static let presetAggressive = FilterPreset(
        highpassA: .init(startFreq: 600, midFreq: 2500, endFreq: 5000, q: 1.2),
        highpassB: .init(startFreq: 800, midFreq: 200, endFreq: 60, q: 0.6),
        lowshelfA: .init(frequency: 200, startGain: 0, midGain: -10, endGain: -18),
        lowshelfB: .init(frequency: 200, startGain: -12, midGain: -6, endGain: 0),
        lowpassA: nil,
        midScoopA: .init(frequency: 1500, bandwidth: 1.5, startGain: 0, endGain: -16),
        highShelfA: .init(frequency: 8000, startGain: 0, endGain: -10)
    )

    static let presetAnticipation = FilterPreset(
        highpassA: .init(startFreq: 600, midFreq: 2500, endFreq: 5000, q: 1.2),
        highpassB: .init(startFreq: 1200, midFreq: 600, endFreq: 40, q: 0.6),
        lowshelfA: .init(frequency: 200, startGain: 0, midGain: -8, endGain: -16),
        lowshelfB: .init(frequency: 200, startGain: -15, midGain: -9, endGain: 0),
        lowpassA: nil,
        midScoopA: .init(frequency: 1500, bandwidth: 1.5, startGain: 0, endGain: -15),
        highShelfA: .init(frequency: 8000, startGain: 0, endGain: -10)
    )

    /// Energy-down preset: uses lowpass sweep on A instead of highpass (song "fades away" darkly)
    static let presetEnergyDown = FilterPreset(
        highpassA: .init(startFreq: 40, midFreq: 40, endFreq: 40, q: 0.7),  // bypassed effectively
        highpassB: .init(startFreq: 400, midFreq: 200, endFreq: 60, q: 0.6),
        lowshelfA: .init(frequency: 200, startGain: 0, midGain: -4, endGain: -10),
        lowshelfB: .init(frequency: 200, startGain: -8, midGain: -4, endGain: 0),
        lowpassA: .init(startFreq: 20000, endFreq: 800, q: 1.0),
        // Energy-down: lighter mid scoop (lowpass already darkens), no hi-hat shelf (lowpass handles it)
        midScoopA: .init(frequency: 1500, bandwidth: 1.0, startGain: 0, endGain: -8),
        highShelfA: nil
    )

    /// Gentle preset: smooth transition with subtle but real spectral separation.
    /// B enters with noticeable bass reduction that sweeps open gradually, while A
    /// thins out enough to leave room for B in the lower mids. Q stays at 0.5 (no
    /// resonance) so the filtering is colourless — never sounds "DJ-y", just clean.
    /// Used for NATURAL_BLEND (cases where the songs CAN actually share space —
    /// minimal/ambient pairs, dramatic energy-down pairs, conservative non-DJ mode).
    /// Incompatible-BPM pairs are routed to CLEAN_HANDOFF instead, not here.
    static let presetGentle = FilterPreset(
        // endFreq raised 300→500Hz: previous value left A almost full-spectrum
        // through the entire fade, undermining the "spectral separation" intent.
        // 500Hz is still well below the vocal range — A keeps body and presence.
        highpassA: .init(startFreq: 60, midFreq: 200, endFreq: 500, q: 0.5),
        highpassB: .init(startFreq: 250, midFreq: 150, endFreq: 40, q: 0.5),
        // endGain -8→-10dB: a touch more bass cut on A by the end so B's
        // bass swap (rising to 0dB) doesn't fight residual low end from A.
        lowshelfA: .init(frequency: 200, startGain: 0, midGain: -4, endGain: -10),
        lowshelfB: .init(frequency: 200, startGain: -8, midGain: -4, endGain: 0),
        lowpassA: nil,
        // endGain -6→-10dB: -6dB barely separated overlapping vocals. -10dB at
        // 1.5kHz with 1-octave bandwidth audibly carves out a hole for B's voice
        // without making A sound chewed-up.
        midScoopA: .init(frequency: 1500, bandwidth: 1.0, startGain: 0, endGain: -10),
        highShelfA: .init(frequency: 8000, startGain: 0, endGain: -4)
    )

    /// Drop-mix preset: aggressive HPF ramp on A pulling it out fast, B enters clean.
    /// Used for hip hop/R&B drops where B's intro is short and needs to hit immediately.
    /// A sweeps 600→6000Hz in the fade window (fast, punchy), B bypassed via skipBFilters.
    static let presetDropMix = FilterPreset(
        highpassA: .init(startFreq: 600, midFreq: 3000, endFreq: 6000, q: 1.3),
        highpassB: .init(startFreq: 200, midFreq: 100, endFreq: 40, q: 0.5),
        lowshelfA: .init(frequency: 200, startGain: 0, midGain: -14, endGain: -22),
        lowshelfB: .init(frequency: 200, startGain: -10, midGain: -5, endGain: 0),
        lowpassA: nil,
        midScoopA: .init(frequency: 1500, bandwidth: 1.5, startGain: 0, endGain: -14),
        highShelfA: .init(frequency: 8000, startGain: 0, endGain: -10)
    )

    /// Stem-mix preset: B enters filtered to vocals/mids only, A stays full then exits via highpass.
    /// Simulates DJ stem mixing without real stem separation.
    static let presetStemMix = FilterPreset(
        highpassA: .init(startFreq: 200, midFreq: 1500, endFreq: 6000, q: 1.0),
        highpassB: .init(startFreq: 300, midFreq: 200, endFreq: 40, q: 0.5),
        lowshelfA: .init(frequency: 200, startGain: 0, midGain: -12, endGain: -20),
        lowshelfB: .init(frequency: 200, startGain: -18, midGain: -12, endGain: 0),
        lowpassA: nil,
        midScoopA: .init(frequency: 1500, bandwidth: 1.5, startGain: 0, endGain: -14),
        highShelfA: .init(frequency: 8000, startGain: 0, endGain: -10)
    )

    // MARK: - DJ Effects: Twin dynQ + Phaser Notch Sweep tuning constants

    /// Center of A's existing Q resonance bell (0..1 of the filter window).
    /// Kept here next to B's center for easy comparison — A's value still lives
    /// hard-coded inside applyFiltersA so the pre-existing dynQ behavior is byte-identical.
    private static let dynQBellCenterA: Float = 0.55
    /// Center of B's mirror Q bell — slightly earlier than A's so B's resonance
    /// peak fires BEFORE A's, producing the "knob handoff" perception.
    private static let dynQBellCenterB: Float = 0.40
    /// Bell width (Gaussian sigma equivalent) for both A and B Q sweeps.
    private static let dynQBellWidth: Float = 0.30
    /// Peak Q reached at the bell center for B (matches A's peak for perceptual symmetry).
    private static let dynQPeakQ: Float = 3.5
    /// Hard ceiling — biquad self-oscillates above ~5.0; 4.0 is a safe musical max.
    private static let dynQMaxQ: Float = 4.0

    /// Phaser Notch Sweep — start frequency of the exponential center-freq sweep on B band 2.
    private static let notchStartFreq: Float = 250
    /// Phaser Notch Sweep — end frequency of the exponential center-freq sweep on B band 2.
    private static let notchEndFreq: Float = 6000
    /// Phaser Notch Sweep — bandwidth in octaves (narrower = more "phasey").
    private static let notchBandwidth: Float = 0.3
    /// Phaser Notch Sweep — gain at bell tails (start and end of sweep).
    private static let notchTailGain: Float = -6
    /// Phaser Notch Sweep — gain at bell peak (deepest cut, mid-sweep).
    private static let notchPeakGain: Float = -24
    /// Phaser Notch Sweep — bell center within B's filter window (0.50 = exact middle).
    private static let notchBellCenter: Float = 0.50
    /// Phaser Notch Sweep — bell width.
    private static let notchBellWidth: Float = 0.30

    // MARK: - Estado

    let config: Config
    let timings: Timings
    let preset: FilterPreset
    let maxVolumeA: Float
    private(set) var maxVolumeB: Float
    var getMasterVolume: (() -> Float)?

    private let engine: AVAudioEngine
    private let playerA: AVAudioPlayerNode
    private let playerB: AVAudioPlayerNode
    private let dspA: BiquadDSPNode
    private let dspB: BiquadDSPNode
    private let mixerA: AVAudioMixerNode
    private let mixerB: AVAudioMixerNode
    private let timePitchA: AVAudioUnitTimePitch?
    private let timePitchB: AVAudioUnitTimePitch?
    /// Sample rate for biquad coefficient computation (from nextFile's processing format)
    private let sampleRate: Float
    private let currentFile: AVAudioFile?
    private let nextFile: AVAudioFile

    // DispatchSourceTimer en vez de CADisplayLink — funciona en background
    // Uses a dedicated high-priority queue instead of .main to avoid iOS
    // throttling/suspending the timer during background audio or CarPlay.
    private static let queueKey = DispatchSpecificKey<Bool>()
    static let automationQueue: DispatchQueue = {
        let q = DispatchQueue(label: "com.audiorr.crossfade.automation", qos: .userInteractive)
        q.setSpecific(key: queueKey, value: true)
        return q
    }()
    private var filterTimer: DispatchSourceTimer?
    private var safetyWatchdog: DispatchSourceTimer?
    private var secondaryWatchdog: DispatchSourceTimer?
    private var isCancelled = false
    private var lastLogTime: Double = 0
    private var lastTickTime: Double = 0
    private var foregroundObserver: Any?
    /// Diagnostic tracking: current filter parameter values (for logging, not audio-critical)
    private var diagFreqA: Float = 20
    private var diagFreqB: Float = 20
    private var diagLsGainA: Float = 0
    private var diagLsGainB: Float = 0
    private var diagQA: Float = 0.707
    /// Twin dynQ — current Q value on B's highpass (mirrors diagQA for handoff visualization).
    private var diagQB: Float = 0.707
    /// Phaser Notch Sweep — current parametric notch center frequency on B's band 2.
    private var diagNotchFreqB: Float = 0
    /// Phaser Notch Sweep — current notch depth (gain dB, negative = cut).
    private var diagNotchGainB: Float = 0

    // MARK: - Stutter Cut state (Sprint 3)

    /// A's file-time at executor start. Captured from caller. Only used by Stutter Cut.
    private let startFileTimeA: Double
    /// True when Stutter Cut passed BOTH the decision-layer gates and the runtime
    /// beat-anchor check. Set in init after pre-computing the anchor; if false,
    /// gainForPlayerA bypasses the gate entirely (graceful degradation — the CUT
    /// still happens, just without the chop).
    private var stutterActive: Bool = false
    /// Wall-clock time at which the stutter pattern STARTS (= 2 beats before the
    /// anchor). gainForPlayerA only applies the gate while t is in [start, anchor].
    private var stutterStartWall: Double = 0
    /// Wall-clock time at which the stutter pattern ENDS (= the anchor itself,
    /// which is the wall-clock translation of A's nearest real beat to the cut).
    private var stutterAnchorWall: Double = 0
    /// Cell duration = beatInterval / 2 (1/8 note). Cached for the gate calculation.
    private var stutterCellDuration: Double = 0

    var onComplete: ((Double) -> Void)?
    /// Llamado si playerB termina de forma natural sin que completeCrossfade() haya sido invocado.
    /// Permite que AudioEngineManager notifique onTrackEnd como safety net.
    var onPlayerBEndedNaturally: (() -> Void)?

    deinit {
        filterTimer?.cancel()
        filterTimer = nil
        safetyWatchdog?.cancel()
        safetyWatchdog = nil
        secondaryWatchdog?.cancel()
        secondaryWatchdog = nil
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Init

    init(
        config: Config,
        engine: AVAudioEngine,
        playerA: AVAudioPlayerNode,
        playerB: AVAudioPlayerNode,
        dspA: BiquadDSPNode,
        dspB: BiquadDSPNode,
        mixerA: AVAudioMixerNode,
        mixerB: AVAudioMixerNode,
        timePitchA: AVAudioUnitTimePitch? = nil,
        timePitchB: AVAudioUnitTimePitch? = nil,
        currentFile: AVAudioFile?,
        nextFile: AVAudioFile,
        maxVolumeA: Float,
        maxVolumeB: Float,
        getMasterVolume: @escaping () -> Float,
        currentTitle: String,
        nextTitle: String,
        /// A's file-time at the moment this executor is created. Required by Stutter
        /// Cut to map wall-clock time back to A's beat grid. Captured by the caller
        /// from AudioEngineManager.currentTime() to avoid coupling the executor to
        /// player internals. Only meaningful when A plays at rate 1.0 (always true
        /// for CUT — see decideTimeStretch).
        startFileTimeA: Double = 0
    ) {
        self.config = config
        self.engine = engine
        self.playerA = playerA
        self.playerB = playerB
        self.dspA = dspA
        self.dspB = dspB
        self.mixerA = mixerA
        self.mixerB = mixerB
        self.timePitchA = timePitchA
        self.timePitchB = timePitchB
        self.sampleRate = Float(nextFile.processingFormat.sampleRate)
        self.currentFile = currentFile
        self.nextFile = nextFile
        self.maxVolumeA = maxVolumeA
        self.maxVolumeB = maxVolumeB
        self.getMasterVolume = getMasterVolume
        self.startFileTimeA = startFileTimeA

        // Seleccionar preset — informed by backend analysis
        // Energy-down: if B is significantly less energetic, use lowpass sweep on A
        let isEnergyDown = config.energyB < config.energyA - 0.2
        // Both sides instrumental = clean transition, lighter filters suffice
        let bothInstrumental = config.isOutroInstrumental && config.isIntroInstrumental
        if config.transitionType == .dropMix {
            preset = Self.presetDropMix
        } else if config.transitionType == .stemMix {
            preset = Self.presetStemMix
        } else if config.transitionType == .naturalBlend
                  || config.transitionType == .cleanHandoff
                  || config.transitionType == .vinylStop {
            // Natural blend = invisible transition with subtle spectral separation.
            // Clean handoff / Vinyl stop = sequential A→silence→B (or rate-ramp→
            // silence→B). Filters bypassed at runtime (skipBFilters=true +
            // applyFiltersA early return) so the preset choice here only seeds
            // initial coefficients, which never get exercised. The vinyl-stop
            // gesture is the rate ramp; we don't add filter sweeps on top.
            preset = Self.presetGentle
        } else if config.needsAnticipation {
            preset = Self.presetAnticipation
        } else if isEnergyDown {
            preset = Self.presetEnergyDown
        } else if bothInstrumental {
            // Instrumental-to-instrumental: no vocal clash risk, use normal (lighter) preset
            preset = Self.presetNormal
        } else if config.useAggressiveFilters {
            preset = Self.presetAggressive
        } else {
            preset = Self.presetNormal
        }

        // Energy compensation: if B is much quieter, boost its volume slightly
        // to prevent perceived loudness drop during crossfade
        let energyDiff = config.energyA - config.energyB
        if energyDiff > 0.2 {
            // +2dB to +4dB compensation (1.26 to 1.58 linear)
            let compensation = Float(1.0 + min(0.58, energyDiff * 0.8))
            self.maxVolumeB = min(1.0, maxVolumeB * compensation)
        }
        // CUT-specific: rapid B entry makes energy drops more noticeable
        if config.transitionType == .cut && energyDiff > 0.15 {
            let cutBoost = Float(1.0 + min(0.3, (energyDiff - 0.15) * 0.6))
            self.maxVolumeB = min(1.0, maxVolumeB * cutBoost)
        }

        // Calcular timings (port exacto de CrossfadeEngine.calculateTimings líneas 244-289)
        timings = Self.calculateTimings(config: config)

        // Compute beat-aligned bass swap point
        hasBeatData = config.beatIntervalA > 0 || config.beatIntervalB > 0
        bassSwapTime = Self.computeBassSwapTime(config: config, timings: timings)

        // ── Stutter Cut anchor pre-computation (Sprint 3) ──
        //
        // The decision layer (DJMixingService.decideDJEffects) already gated on
        // bpmTrusted, BPM range, danceability, beatGrid presence, etc. Here we do
        // the FINAL runtime check: is the cut moment actually close enough to a
        // real beat in A's grid? If not, we can't anchor the stutter musically and
        // the effect must be bypassed (graceful degradation — CUT still happens
        // cleanly, just no chop).
        //
        // Math:
        //   1. cutFileTimeA = where A's playhead lands at transitionEndTime in
        //      A's file-time coordinate system. Since useTimeStretch is forced
        //      false for CUT (decideTimeStretch line 1791), A advances 1:1 with
        //      wall-clock from startTime onward.
        //   2. nearestBeat = closest entry in downbeatTimesA to cutFileTimeA.
        //   3. If |nearestBeat - cutFileTimeA| > beatInterval/4, the cut is
        //      mid-beat and the stutter would land off-grid. Skip.
        //   4. Otherwise, anchor the stutter so its LAST 1/8 cell ends at the
        //      anchor's wall-clock equivalent. Pattern: ON/OFF/ON/OFF (4 cells
        //      of beatInterval/2 each, totaling 2 beats).
        if config.useStutterCut
            && config.beatIntervalA > 0
            && !config.downbeatTimesA.isEmpty
            && (config.transitionType == .cut || config.transitionType == .cutAFadeInB) {

            let totalTime = timings.totalTime
            let cutFileTimeA = startFileTimeA + totalTime
            let beatInterval = config.beatIntervalA

            // Find the beat closest to cutFileTimeA — could be slightly after
            // (typical when trigger snapped to a downbeat) or slightly before.
            if let nearestBeat = config.downbeatTimesA.min(by: {
                abs($0 - cutFileTimeA) < abs($1 - cutFileTimeA)
            }) {
                let beatOffset = abs(nearestBeat - cutFileTimeA)
                let snapTolerance = beatInterval / 4.0  // ±25% of a beat = ±125ms at 120 BPM

                if beatOffset <= snapTolerance {
                    // Convert anchor's file-time back to wall-clock.
                    // Wall-clock at startTime corresponds to file-time startFileTimeA.
                    let anchorWall = timings.startTime + (nearestBeat - startFileTimeA)
                    // Stutter zone = 2 beats ending at the anchor.
                    stutterStartWall = anchorWall - 2.0 * beatInterval
                    stutterAnchorWall = anchorWall
                    stutterCellDuration = beatInterval / 2.0
                    stutterActive = true
                    print("[CrossfadeExecutor] 🎚️ Stutter Cut ARMED: anchor=\(String(format: "%.3f", nearestBeat))s file (offset \(String(format: "%.0f", beatOffset * 1000))ms from cut), cell=\(String(format: "%.0f", stutterCellDuration * 1000))ms, BPM=\(String(format: "%.0f", 60.0 / beatInterval))")
                } else {
                    print("[CrossfadeExecutor] Stutter Cut bypassed: cut is \(String(format: "%.0f", beatOffset * 1000))ms from nearest beat (>\(Int(snapTolerance * 1000))ms tolerance)")
                }
            }
        }

        // Pre-compute ALL effect flags so diagnostics/logging reflect the final state.
        // These are also set in setupInitialEQ() but we need them here for the log below.
        useMidScoop = config.useMidScoop && !config.isIntroInstrumental && preset.midScoopA != nil
        useHighShelfCut = config.useHighShelfCut && !config.isOutroInstrumental && preset.highShelfA != nil
        let useLowpass = preset.lowpassA != nil
        let hasBassManagement = preset.lowshelfA != nil ||
            config.transitionType == .beatMatchBlend || config.transitionType == .eqMix || config.transitionType == .stemMix
        useBassKill = config.useBassKill && hasBassManagement && preset.lowshelfA != nil
        useDynamicQ = config.useDynamicQ && !useLowpass
        // Phaser Notch Sweep guards (in addition to the decideDJEffects gate):
        //   - skipBFilters off (notch lives on B's band 2 — needs B filtering active)
        //   - needsAnticipation off (B's anticipation curve is multi-stage; don't stack)
        //   - useDynamicQ on (philosophical pairing — same musical context)
        useNotchSweep = config.useNotchSweep && !config.skipBFilters
            && !config.needsAnticipation && useDynamicQ

        // Log
        let filtersDesc = config.useFilters ? (config.useAggressiveFilters ? "AGGRESSIVE" : "normal") : "OFF"
        let djDesc = [useMidScoop ? "midScoop" : nil, useHighShelfCut ? "hiShelf" : nil,
                      useBassKill ? "bassKill" : nil, useDynamicQ ? "dynQ" : nil,
                      useNotchSweep ? "notch" : nil, stutterActive ? "stutter" : nil]
            .compactMap { $0 }.joined(separator: "+")
        let analysisDesc = [config.isOutroInstrumental ? "outroInst" : nil,
                           config.isIntroInstrumental ? "introInst" : nil,
                           config.danceability > 0.7 ? String(format: "dance=%.2f", config.danceability) : nil]
            .compactMap { $0 }.joined(separator: "+")
        let anticDesc = config.needsAnticipation ? String(format: "%.1fs", config.anticipationTime) : "OFF"
        print("""
        [CrossfadeExecutor] ═══════════════════════════════════════
          \(config.transitionType.rawValue): "\(currentTitle)" → "\(nextTitle)"
          Entry: \(String(format: "%.2f", config.entryPoint))s | Fade: \(String(format: "%.2f", config.fadeDuration))s
          Filters: \(filtersDesc) | DJ: \(djDesc.isEmpty ? "OFF" : djDesc) | B-filters: \(config.skipBFilters ? "SKIP" : "ON") | Anticipation: \(anticDesc) | Analysis: \(analysisDesc.isEmpty ? "—" : analysisDesc)
          RG A: \(String(format: "%.3f", maxVolumeA)) | B: \(String(format: "%.3f", maxVolumeB)) | Vol: \(String(format: "%.2f", getMasterVolume()))
          Beat: A=\(String(format: "%.3f", config.beatIntervalA))s B=\(String(format: "%.3f", config.beatIntervalB))s | swap@\(String(format: "%.2f", bassSwapTime - timings.startTime))s | beats:\(hasBeatData ? "YES" : "NO")
          Timings:
            filterStart:  \(String(format: "%.2f", timings.filterStartTime - timings.startTime))s
            volFadeStart: \(String(format: "%.2f", timings.volumeFadeStartTime - timings.startTime))s
            fadeInStart:  \(String(format: "%.2f", timings.fadeInStartTime - timings.startTime))s
            fadeInEnd:    \(String(format: "%.2f", timings.fadeInEndTime - timings.startTime))s
            transEnd:     \(String(format: "%.2f", timings.transitionEndTime - timings.startTime))s
            startOffset:  \(String(format: "%.2f", timings.startOffset))s
        ═══════════════════════════════════════
        """)

        // Publish to diagnostics UI
        let presetName: String
        if config.transitionType == .dropMix { presetName = "drop-mix" }
        else if config.transitionType == .stemMix { presetName = "stem-mix" }
        else if config.transitionType == .naturalBlend { presetName = "gentle" }
        else if config.transitionType == .cleanHandoff { presetName = "clean-handoff" }
        else if config.transitionType == .vinylStop { presetName = "vinyl-stop" }
        else if config.needsAnticipation { presetName = "anticipation" }
        else if preset.lowpassA != nil { presetName = "energy-down" }
        else if config.useAggressiveFilters { presetName = "aggressive" }
        else { presetName = "normal" }

        TransitionDiagnostics.shared.publishDecision(
            transitionType: config.transitionType.rawValue,
            currentTitle: currentTitle,
            nextTitle: nextTitle,
            fadeDuration: config.fadeDuration,
            entryPoint: config.entryPoint,
            startOffset: timings.startOffset,
            anticipationTime: config.anticipationTime,
            filtersEnabled: true,  // Filters always run during crossfade (useFilters only affects preset selection)
            filterPreset: presetName,
            useMidScoop: useMidScoop,
            useHighShelfCut: useHighShelfCut,
            useBassKill: useBassKill,
            useDynamicQ: useDynamicQ,
            useNotchSweep: useNotchSweep,
            useStutterCut: stutterActive,
            skipBFilters: config.skipBFilters,
            energyA: config.energyA,
            energyB: config.energyB,
            isOutroInstrumental: config.isOutroInstrumental,
            isIntroInstrumental: config.isIntroInstrumental,
            danceability: config.danceability,
            isBeatSynced: hasBeatData,
            beatSyncInfo: {
                let bpmA = config.beatIntervalA > 0.15 ? String(format: "%.1f", 60.0 / config.beatIntervalA) : "N/A"
                let bpmB = config.beatIntervalB > 0.15 ? String(format: "%.1f", 60.0 / config.beatIntervalB) : "N/A"
                return config.beatIntervalA > 0 || config.beatIntervalB > 0
                    ? "A=\(bpmA)bpm B=\(bpmB)bpm" : "No beat data"
            }(),
            beatIntervalA: config.beatIntervalA,
            beatIntervalB: config.beatIntervalB,
            useTimeStretch: config.useTimeStretch,
            rateA: config.rateA,
            rateB: config.rateB,
            replayGainA: maxVolumeA,
            replayGainB: maxVolumeB
        )
    }

    // MARK: - Timing calculation (port exacto de CrossfadeEngine.calculateTimings)

    static func calculateTimings(config: Config) -> Timings {
        let now = CACurrentMediaTime()

        // CLEAN_HANDOFF / VINYL_STOP: zero filterLead so A's volume drop and rate
        // ramp start immediately at trigger. Otherwise filterLead would let A play
        // at full volume for ~0.7s before the fade-out begins, padding the
        // transition with unintended music and pushing B's entry beyond the user's
        // perceived "transition moment".
        let filterLead: Double
        if config.transitionType == .cleanHandoff || config.transitionType == .vinylStop {
            filterLead = 0
        } else {
            filterLead = config.useFilters ? min(1.5, config.fadeDuration * 0.2) : 0
        }

        // FadeOut = fadeDuration (1:1). No multiplier — A disappears cleanly
        // within the fade window so B arrives at its punch with A already gone.
        // The old 1.3x tail created muddiness from overlapping at partial volumes.
        let fadeOutDuration = config.fadeDuration
        let totalTransition = fadeOutDuration + filterLead

        let anticipationStartTime = now
        let filterStartTime = now + config.anticipationTime
        let volumeFadeStartTime = filterStartTime + filterLead
        let transitionEndTime = filterStartTime + totalTransition
        let totalTime = config.anticipationTime + totalTransition

        // B's fade-in starts when A's volume fade starts — no delay.
        // B should reach full volume at or slightly before transitionEnd (punch).
        let fadeInStartTime = volumeFadeStartTime
        let fadeInEndTime = fadeInStartTime + config.fadeDuration

        // totalTime includes anticipation + filterLead + fadeOutDuration.
        // This ensures B reaches exactly entryPoint when the transition ends.
        let startOffset = max(0, config.entryPoint - totalTime)

        return Timings(
            startTime: now,
            anticipationStartTime: anticipationStartTime,
            filterStartTime: filterStartTime,
            volumeFadeStartTime: volumeFadeStartTime,
            transitionEndTime: transitionEndTime,
            filterLead: filterLead,
            fadeOutDuration: fadeOutDuration,
            totalTime: totalTime,
            fadeInStartTime: fadeInStartTime,
            fadeInEndTime: fadeInEndTime,
            startOffset: startOffset
        )
    }

    // MARK: - Beat-aligned bass swap computation

    /// Find the best wall-clock time for the bass swap point.
    /// Targets ~40-50% of the crossfade, snapped to the nearest downbeat of B.
    /// Falls back to linear 50% if no beat data is available.
    private static func computeBassSwapTime(config: Config, timings: Timings) -> Double {
        let fadeStart = timings.volumeFadeStartTime
        let fadeEnd = timings.transitionEndTime
        let fadeDur = fadeEnd - fadeStart
        guard fadeDur > 0 else { return fadeStart }

        // Bass-first mixing: a DJ cuts A's bass BEFORE dropping volume.
        // Bass swap early in the fade (25%) so B's bass enters while A still has mids/highs.
        // Instrumental outro: even earlier (15%) since A has no bass to clash with.
        // Stem mix: later (35%) — B's vocals need to be established before bass swap.
        let targetPercent: Double
        if config.transitionType == .cut || config.transitionType == .cutAFadeInB {
            // CUT: bass swap when B actually enters — at ~75% of fade.
            // A holds full volume until the last 3s, so swapping bass at 25%
            // creates a bass-less hole. Align with B's entry.
            targetPercent = 0.75
        } else if config.transitionType == .dropMix {
            // DROP_MIX: early bass swap (20%) — A drops fast, B needs bass immediately.
            targetPercent = 0.20
        } else if config.transitionType == .stemMix {
            targetPercent = 0.35
        } else {
            targetPercent = config.isOutroInstrumental ? 0.15 : 0.25
        }
        let targetTime = fadeStart + fadeDur * targetPercent
        let beatInterval = config.beatIntervalB > 0 ? config.beatIntervalB : config.beatIntervalA

        guard beatInterval > 0 else {
            // No beat data — bass swap at target percent
            return fadeStart + fadeDur * targetPercent
        }

        // If we have downbeat times for B, find the nearest one to our target
        if !config.downbeatTimesB.isEmpty {
            // Convert B's downbeat times to wall-clock times relative to the crossfade
            // B starts playing at timings.startOffset in the file, so:
            // wall_clock = fadeStart + (downbeat_in_file - entryPoint_adjusted) / rateB
            // But downbeatTimesB are already adjusted for time-stretch by DJMixingService
            let bFileStart = timings.startOffset
            var bestTime = targetTime
            var bestDist = Double.infinity
            for db in config.downbeatTimesB {
                // Convert file-time to wall-clock
                let wallTime = fadeStart + (db - bFileStart)
                // Downbeat window — CUT swaps late (near B's entry), others swap early
                let minT: Double
                let maxT: Double
                if config.transitionType == .cut || config.transitionType == .cutAFadeInB {
                    minT = fadeStart + fadeDur * 0.60
                    maxT = fadeStart + fadeDur * 0.85
                } else {
                    minT = fadeStart + fadeDur * (config.isOutroInstrumental ? 0.05 : 0.10)
                    maxT = fadeStart + fadeDur * (config.isOutroInstrumental ? 0.35 : 0.45)
                }
                guard wallTime >= minT && wallTime <= maxT else { continue }
                let dist = abs(wallTime - targetTime)
                if dist < bestDist {
                    bestDist = dist
                    bestTime = wallTime
                }
            }
            return bestTime
        }

        // No downbeat array — snap to nearest beat grid of B
        let offsetInFade = fadeDur * targetPercent
        let nearestBeat = round(offsetInFade / beatInterval) * beatInterval
        let minClamp: Double
        let maxClamp: Double
        if config.transitionType == .cut || config.transitionType == .cutAFadeInB {
            minClamp = fadeDur * 0.60
            maxClamp = fadeDur * 0.85
        } else {
            minClamp = fadeDur * (config.isOutroInstrumental ? 0.05 : 0.10)
            maxClamp = fadeDur * (config.isOutroInstrumental ? 0.35 : 0.45)
        }
        let clampedBeat = max(minClamp, min(maxClamp, nearestBeat))
        return fadeStart + clampedBeat
    }

    // MARK: - Start

    func start() {
        // Keep mixerA at its current replayGain level (set by AudioEngineManager)
        // Keep mainMixerNode at user volume (set by AudioEngineManager)
        // mixerB starts at 0 (set in schedulePlayerB)
        // Volume automation is handled by filterTick() updating mixer.outputVolume at ~60Hz

        setupInitialEQ()
        setupTimeStretch()

        guard schedulePlayerB() else {
            // B tiene 0 frames — no hay nada que reproducir.
            // Restauramos A y llamamos onComplete para que AudioEngineManager
            // limpie isCrossfading y no quede en estado fantasma.
            print("[CrossfadeExecutor] ⚠️ Setup falló (sin frames en B) — restaurando A")
            mixerA.outputVolume = maxVolumeA
            // Reset DSP and time-stretch that setupInitialEQ/setupTimeStretch already applied
            dspA.reset()
            dspB.reset()
            mixerA.pan = 0
            mixerB.pan = 0
            resetTimeStretch()
            isCancelled = true
            DispatchQueue.main.async { [weak self] in
                self?.onComplete?(0)
            }
            return
        }

        playerB.play()

        startFilterAutomation()

        startSafetyWatchdog()
        startSecondaryWatchdog()
    }

    func cancel() {
        isCancelled = true
        filterTimer?.cancel()
        filterTimer = nil
        safetyWatchdog?.cancel()
        safetyWatchdog = nil
        secondaryWatchdog?.cancel()
        secondaryWatchdog = nil
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
            foregroundObserver = nil
        }
        playerB.stop()
        mixerA.outputVolume = maxVolumeA
        mixerB.outputVolume = 0

        // Immediate DSP reset on calling thread
        dspA.reset()
        dspB.reset()
        mixerA.pan = 0
        mixerB.pan = 0
        resetTimeStretch()

        // Backstop on automationQueue: serialize after any in-flight filterTick
        let dA = self.dspA, dB = self.dspB
        let mA = self.mixerA, mB = self.mixerB
        let tpA = self.timePitchA
        Self.automationQueue.asyncAfter(deadline: .now() + 0.15) {
            dA.reset()
            dB.reset()
            mA.pan = 0
            mB.pan = 0
            if let tpA { Self.resetTimePitchSoft(tpA) }
        }
    }

    // MARK: - Time-Stretch Setup

    private func setupTimeStretch() {
        guard config.useTimeStretch else {
            print("[CrossfadeExecutor] Time-stretch OFF")
            return
        }
        // Set initial rates — B starts at target rate immediately,
        // A ramps gradually during the crossfade (handled in filterTick).
        timePitchA?.rate = 1.0  // A starts at normal rate, ramps toward config.rateA
        timePitchB?.rate = config.rateB
        print("[CrossfadeExecutor] Time-stretch ON: A→\(String(format: "%.3f", config.rateA)) B=\(String(format: "%.3f", config.rateB))")
    }

    private func resetTimeStretch() {
        // A (outgoing, about to be stopped) — full reset is safe
        if let tpA = timePitchA { Self.resetTimePitchStatic(tpA) }
        // B (active, will become playerA after swap) — soft reset only!
        // AudioUnitReset on a rendering chain permanently breaks playerTime(forNodeTime:)
        if let tpB = timePitchB { Self.resetTimePitchSoft(tpB) }
    }

    /// Resets a TimePitch node to neutral (rate 1.0) and flushes its CoreAudio DSP state.
    /// ⚠️ ONLY safe on IDLE (stopped) players — AudioUnitReset permanently breaks
    /// playerTime(forNodeTime:) on active (rendering) chains.
    static func resetTimePitchStatic(_ tp: AVAudioUnitTimePitch) {
        tp.rate = 1.0
        tp.pitch = 0       // semitones
        tp.overlap = 8.0   // default
        let au = tp.audioUnit
        AudioUnitReset(au, kAudioUnitScope_Global, 0)
    }

    /// Soft reset: sets TimePitch parameters to neutral WITHOUT AudioUnitReset.
    /// Safe for actively-rendering chains — preserves playerTime(forNodeTime:)
    /// mapping which AudioUnitReset would permanently destroy on a playing node.
    static func resetTimePitchSoft(_ tp: AVAudioUnitTimePitch) {
        tp.rate = 1.0
        tp.pitch = 0       // semitones
        tp.overlap = 8.0   // default
    }

    // MARK: - Post-reset audit

    /// Reads current biquad coefficients from DSP nodes and publishes to diagnostics.
    static func auditDSPState(source: String, dspA: BiquadDSPNode, dspB: BiquadDSPNode,
                              mixerA: AVAudioMixerNode, mixerB: AVAudioMixerNode,
                              timePitchA: AVAudioUnitTimePitch?, timePitchB: AVAudioUnitTimePitch?) {
        func coeffSnapshot(_ dsp: BiquadDSPNode) -> [TransitionDiagnostics.EQBandSnapshot] {
            let coeffs = dsp.currentCoefficients()
            let labels = ["highPass", "lowShelf", "parametric", "highShelf"]
            return coeffs.enumerated().map { i, c in
                TransitionDiagnostics.EQBandSnapshot(
                    filterType: labels[min(i, labels.count - 1)],
                    frequency: 0, // coefficients don't expose frequency directly
                    gain: c.isPassthrough ? 0 : 1,  // 0=passthrough, 1=active
                    bandwidth: 0,
                    bypass: c.isPassthrough
                )
            }
        }

        func dspSnapshot(_ dsp: BiquadDSPNode) -> [TransitionDiagnostics.DSPBandSnapshot] {
            let coeffs = dsp.currentCoefficients()
            return coeffs.map { c in
                TransitionDiagnostics.DSPBandSnapshot(
                    gain: c.isPassthrough ? 0 : 1,
                    frequency: 0,
                    bandwidth: 0
                )
            }
        }

        func dspRate(_ tp: AVAudioUnitTimePitch?) -> Float {
            guard let tp else { return 1.0 }
            var rate: Float = 1.0
            AudioUnitGetParameter(tp.audioUnit, 0, kAudioUnitScope_Global, 0, &rate)
            return rate
        }

        let audit = TransitionDiagnostics.PostResetAudit(
            source: source,
            bandsA: coeffSnapshot(dspA),
            bandsB: coeffSnapshot(dspB),
            dspBandsA: dspSnapshot(dspA),
            dspBandsB: dspSnapshot(dspB),
            panA: mixerA.pan,
            panB: mixerB.pan,
            rateA: timePitchA?.rate ?? 1.0,
            rateB: timePitchB?.rate ?? 1.0,
            dspRateA: dspRate(timePitchA),
            dspRateB: dspRate(timePitchB)
        )
        TransitionDiagnostics.shared.publishPostResetAudit(audit)
    }

    // MARK: - Setup

    /// Whether bass management (lowshelf A + lowshelf B) is active for this crossfade.
    /// Forced ON for BEAT_MATCH_BLEND to prevent kick drum clashing.
    private var useBassManagement: Bool = false
    /// Whether lowpass sweep is active on A (energy-down transitions).
    private var useLowpassA: Bool = false
    /// Whether mid-range parametric scoop is active on A (vocal anti-clash).
    private var useMidScoop: Bool = false
    /// Whether high-shelf cut is active on A (hi-hat/cymbal cleanup).
    private var useHighShelfCut: Bool = false
    /// Whether Bass Kill DJ effect is active (instant low-frequency cut at bassSwapTime).
    private var useBassKill: Bool = false
    /// Whether Dynamic Q Resonance is active (bell-shaped Q sweep on highpass Band 0).
    /// When true, the same flag also enables the **Twin dynQ** mirror on B's band 0 —
    /// B's Q follows a bell with center 0.40 (vs A's 0.55) so B's resonance peak
    /// fires slightly before A's, creating the "knob handoff" feeling.
    private var useDynamicQ: Bool = false
    /// Whether Phaser Notch Sweep is active on B's band 2 (Sprint 2 DJ effect).
    /// Narrow parametric (BW≈0.3 oct) with depth bell (-6 → -24 → -6 dB) and freq
    /// sweep 250→6000Hz exponentially. Decided by DJMixingService — see decideDJEffects.
    private var useNotchSweep: Bool = false
    /// Danceability scaling factor for bass filters (0.5–1.0).
    /// High danceability → less aggressive bass cut to preserve groove.
    private var danceabilityBassScale: Float = 1.0

    /// Beat-aligned bass swap: the wall-clock time at which bass should be fully swapped
    /// (nearest downbeat to ~40-50% of the crossfade). Computed once at init.
    private var bassSwapTime: Double = 0
    /// Whether we have valid beat data for beat-aligned automation.
    private var hasBeatData: Bool = false

    private func setupInitialEQ() {
        // EQ filters ALWAYS active during crossfade — they are the core of a
        // professional-sounding transition. config.useFilters/useAggressiveFilters
        // now only influence preset selection (normal vs aggressive), not whether
        // filters run at all.

        // Bass management: always when preset supports it, forced for beat-match types
        useBassManagement = preset.lowshelfA != nil ||
            config.transitionType == .beatMatchBlend || config.transitionType == .eqMix || config.transitionType == .stemMix
        useLowpassA = preset.lowpassA != nil

        // High danceability (>0.7) = preserve bass/groove: scale lowshelf cuts to 50-100%.
        if config.danceability > 0.7 {
            danceabilityBassScale = Float(1.0 - (config.danceability - 0.7) / 0.3 * 0.5)
        }

        // ── Band 2: Mid scoop on A (vocal anti-clash) ──
        useMidScoop = config.useMidScoop && !config.isIntroInstrumental && preset.midScoopA != nil
        // ── Band 3: High-shelf cut on A (hi-hat/cymbal cleanup) ──
        useHighShelfCut = config.useHighShelfCut && !config.isOutroInstrumental && preset.highShelfA != nil
        // ── DJ effects: Bass Kill + Dynamic Q Resonance + Phaser Notch Sweep ──
        useBassKill = config.useBassKill && useBassManagement && preset.lowshelfA != nil
        useDynamicQ = config.useDynamicQ && !useLowpassA  // Only with highpass sweep, not lowpass
        // Notch sweep on B's band 2 — same gates as the init() block (kept in sync intentionally
        // so that both the published log line and the actual automation see identical state).
        useNotchSweep = config.useNotchSweep && !config.skipBFilters
            && !config.needsAnticipation && useDynamicQ

        // ── Compute initial biquad coefficients for A ──
        let band0A: BiquadCoefficients
        if useLowpassA, let lpA = preset.lowpassA {
            band0A = BiquadCoefficientCalculator.lowpass(frequency: lpA.startFreq, sampleRate: sampleRate, Q: lpA.q)
            diagFreqA = lpA.startFreq
        } else {
            band0A = BiquadCoefficientCalculator.highpass(frequency: preset.highpassA.startFreq, sampleRate: sampleRate, Q: preset.highpassA.q)
            diagFreqA = preset.highpassA.startFreq
        }

        let band1A: BiquadCoefficients
        if useBassManagement, let lsA = preset.lowshelfA {
            band1A = BiquadCoefficientCalculator.lowShelf(frequency: lsA.frequency, sampleRate: sampleRate, gainDB: lsA.startGain)
            diagLsGainA = lsA.startGain
        } else {
            band1A = .passthrough
        }

        let band2A: BiquadCoefficients
        if useMidScoop, let ms = preset.midScoopA {
            band2A = BiquadCoefficientCalculator.parametric(frequency: ms.frequency, sampleRate: sampleRate, gainDB: ms.startGain, bandwidth: ms.bandwidth)
        } else {
            band2A = .passthrough
        }

        let band3A: BiquadCoefficients
        if useHighShelfCut, let hs = preset.highShelfA {
            band3A = BiquadCoefficientCalculator.highShelf(frequency: hs.frequency, sampleRate: sampleRate, gainDB: hs.startGain)
        } else {
            band3A = .passthrough
        }

        dspA.setCoefficients(band0: band0A, band1: band1A, band2: band2A, band3: band3A)

        // ── Compute initial biquad coefficients for B ──
        let band0B: BiquadCoefficients
        let band1B: BiquadCoefficients
        if !config.skipBFilters {
            // Twin dynQ shares B's preset Q at start of fade — bell value ≈ 0 at progress 0,
            // so initial Q = baseQ. Identical to old behavior; bell only swells later.
            band0B = BiquadCoefficientCalculator.highpass(frequency: preset.highpassB.startFreq, sampleRate: sampleRate, Q: preset.highpassB.q)
            band1B = BiquadCoefficientCalculator.lowShelf(frequency: preset.lowshelfB.frequency, sampleRate: sampleRate, gainDB: preset.lowshelfB.startGain)
            diagFreqB = preset.highpassB.startFreq
            diagLsGainB = preset.lowshelfB.startGain
            diagQB = preset.highpassB.q
        } else {
            band0B = .passthrough
            band1B = .passthrough
        }
        // ── Band 2: Phaser Notch Sweep on B (Sprint 2) ──
        // Bell value at progress=0 is near 0 (Gaussian tail), so initial gain is the
        // tail value (-6dB). This means the notch is *audible from frame 0* — no surprise
        // pop when automation kicks in. If notch is off, band 2 stays passthrough.
        let band2B: BiquadCoefficients
        if useNotchSweep {
            band2B = BiquadCoefficientCalculator.parametric(
                frequency: Self.notchStartFreq,
                sampleRate: sampleRate,
                gainDB: Self.notchTailGain,
                bandwidth: Self.notchBandwidth
            )
            diagNotchFreqB = Self.notchStartFreq
            diagNotchGainB = Self.notchTailGain
        } else {
            band2B = .passthrough
        }
        // B band 3 still passthrough — Sprint 2 reserves it for future companion effects.
        dspB.setCoefficients(band0: band0B, band1: band1B, band2: band2B, band3: .passthrough)
    }

    @discardableResult
    private func schedulePlayerB() -> Bool {
        let sampleRate = nextFile.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(timings.startOffset * sampleRate)
        let totalFrames = nextFile.length
        let framesToPlay = AVAudioFrameCount(max(0, totalFrames - startFrame))

        guard framesToPlay > 0 else {
            print("[CrossfadeExecutor] No hay frames en B para reproducir")
            return false
        }

        mixerB.outputVolume = 0  // B starts silent; filterTick ramps it up

        playerB.scheduleSegment(nextFile, startingFrame: startFrame, frameCount: framesToPlay, at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, !self.isCancelled else { return }
                // Si llegamos aquí sin que completeCrossfade() haya corrido, el automix
                // no disparó a tiempo. Notificar para que onTrackEnd recupere el flujo.
                self.onPlayerBEndedNaturally?()
            }
        }
        return true
    }

    // MARK: - Volume automation via mixer.outputVolume (updated from filterTick at ~60Hz)
    // NOTE: installTap buffers are read-only copies — modifying them does NOT affect audio output.
    // We use mixer.outputVolume instead, which is the documented and reliable API for volume control.

    // MARK: - Volume curves for A (port exacto de AudioEffectsChain.ts líneas 152-204)

    func gainForPlayerA(at t: Double) -> Float {
        let baseGain = unstutteredGainForPlayerA(at: t)
        return applyStutterGate(baseGain: baseGain, at: t)
    }

    /// Stutter Cut gate: 1/8-note ON/OFF/ON/OFF pattern over A's last 2 beats.
    /// No-op when stutterActive is false or t is outside [stutterStartWall, stutterAnchorWall).
    /// Includes a 3ms anti-click ramp at each cell boundary to suppress pops.
    private func applyStutterGate(baseGain: Float, at t: Double) -> Float {
        guard stutterActive, t >= stutterStartWall, t < stutterAnchorWall, stutterCellDuration > 0 else {
            return baseGain
        }
        let elapsed = t - stutterStartWall
        let cellIndex = Int(floor(elapsed / stutterCellDuration))
        let timeInCell = elapsed - Double(cellIndex) * stutterCellDuration
        let isOnCell = (cellIndex % 2 == 0)
        let targetGate: Float = isOnCell ? 1.0 : 0.0
        // 3ms anti-click ramp at each cell start. Inaudible musically but eliminates
        // the click that would otherwise come from instant 1↔0 gain transitions
        // through the biquad filter chain.
        let antiClick: Double = 0.003
        let gate: Float
        if timeInCell < antiClick && cellIndex > 0 {
            let prevGate: Float = ((cellIndex - 1) % 2 == 0) ? 1.0 : 0.0
            let p = Float(timeInCell / antiClick)
            gate = prevGate + (targetGate - prevGate) * p
        } else {
            gate = targetGate
        }
        return baseGain * gate
    }

    private func unstutteredGainForPlayerA(at t: Double) -> Float {
        guard t >= timings.volumeFadeStartTime else { return maxVolumeA }
        guard t < timings.transitionEndTime else { return 0 }

        let duration = timings.transitionEndTime - timings.volumeFadeStartTime
        let progress = (t - timings.volumeFadeStartTime) / duration

        switch config.transitionType {
        case .cut, .cutAFadeInB:
            // Hard cut: A stays full, then drops exponentially over 3s.
            // Wider drop zone prevents the jarring "BAM" effect of 1.5s cuts.
            let cutDuration = min(3.0, duration)
            let cutStart = max(0, 1.0 - cutDuration / duration)
            if progress < cutStart { return maxVolumeA }
            let cutP = Float((progress - cutStart) / (1.0 - cutStart))
            return maxVolumeA * powf(0.0001 / maxVolumeA, cutP)

        case .eqMix, .beatMatchBlend:
            // Gradual descent: A eases down to 65% by midpoint, then cos² drop.
            // This gives B time to establish before A exits, avoiding the "cliff" effect.
            // The EQ filters do most of the separation work — volume just needs a smooth handoff.
            let holdLevel: Float = 0.65
            let holdEnd = 0.50
            if progress < holdEnd {
                let p = Float(progress / holdEnd)
                // Smooth S-curve descent: gentle at start, steeper in middle, gentle at holdEnd
                let eased = p * p * (3.0 - 2.0 * p)
                return maxVolumeA * (1.0 - (1.0 - holdLevel) * eased)
            }
            // cos² drop: maintains equal-power with B's sin² ramp
            let dropP = Float((progress - holdEnd) / (1.0 - holdEnd))
            let angle = dropP * .pi / 2.0
            return maxVolumeA * holdLevel * cosf(angle) * cosf(angle)

        case .naturalBlend:
            // Equal-power crossfade: smooth cos² curve the entire duration.
            // No hold phase — A descends gradually from the start.
            // Combined with B's sin² curve, total perceived loudness stays constant.
            let angle = Float(progress) * .pi / 2.0
            return maxVolumeA * cosf(angle) * cosf(angle)

        case .cleanHandoff:
            // Sequential: A descends with cos² over the first 55% of the window,
            // then stays muted through the gap (55–65%) and B's ramp-in (65–100%).
            // No overlap with B at any point — the whole purpose of this type is to
            // avoid two unmixable tracks sounding simultaneously.
            // cos² (not exp) so A stays audible across most of the window. Old exp
            // 0.001^p went sub-audible by p≈0.4 of aFadeEnd, leaving ~1.3s of dead
            // air in a 3s fade. cos² hits true silence exactly at aFadeEnd, giving
            // a clean "respiro" of ~10% of the window (300ms in 3s, 350ms in 3.5s).
            let aFadeEnd = 0.55
            if progress < aFadeEnd {
                let p = Float(progress / aFadeEnd)
                let angle = p * .pi / 2.0
                return maxVolumeA * cosf(angle) * cosf(angle)
            }
            return 0

        case .fadeOutACutB:
            // A fades out ahead of B's firm entry at ~55%.
            // Shorter hold, earlier drop so A is low when B enters.
            let holdLevel: Float = 0.85
            let holdEnd = 0.45
            if progress < holdEnd {
                let p = Float(progress / holdEnd)
                let eased = p * p
                return maxVolumeA * (1.0 - (1.0 - holdLevel) * eased)
            }
            let dropP = Float((progress - holdEnd) / (1.0 - holdEnd))
            return maxVolumeA * holdLevel * powf(0.0001 / holdLevel, dropP)

        case .stemMix:
            // Stem mix: A holds at full volume while B enters filtered to vocals/mids.
            // Very late drop — A stays at ~95% until 75%, then fast exponential exit.
            let holdLevel: Float = 0.95
            let holdEnd = 0.75
            if progress < holdEnd {
                let p = Float(progress / holdEnd)
                let eased = p * p
                return maxVolumeA * (1.0 - (1.0 - holdLevel) * eased)
            }
            let dropP = Float((progress - holdEnd) / (1.0 - holdEnd))
            return maxVolumeA * holdLevel * powf(0.0001 / holdLevel, dropP)

        case .dropMix:
            // Drop mix: A drops fast — short hold then aggressive exponential exit.
            // Designed for 2-7s fades where B needs to take over quickly.
            let holdLevel: Float = 0.80
            let holdEnd = 0.30
            if progress < holdEnd {
                let p = Float(progress / holdEnd)
                let eased = p * p
                return maxVolumeA * (1.0 - (1.0 - holdLevel) * eased)
            }
            let dropP = Float((progress - holdEnd) / (1.0 - holdEnd))
            return maxVolumeA * holdLevel * powf(0.0001 / holdLevel, dropP)

        case .crossfade:
            // Standard crossfade: gentle descent with S-curve character.
            // A eases to 70% by 45%, then cos² drop for smooth power handoff.
            let holdLevel: Float = 0.70
            let holdEnd = 0.45
            if progress < holdEnd {
                let p = Float(progress / holdEnd)
                let eased = p * p * (3.0 - 2.0 * p)
                return maxVolumeA * (1.0 - (1.0 - holdLevel) * eased)
            }
            let dropP = Float((progress - holdEnd) / (1.0 - holdEnd))
            let angle = dropP * .pi / 2.0
            return maxVolumeA * holdLevel * cosf(angle) * cosf(angle)

        case .vinylStop:
            // Spin-down: A's volume drops cos² in parallel to its rate ramp
            // (rate animation is driven separately in applyEnvelopes). The vol
            // mirrors the rate so the spin-down doesn't feel "loud all the way
            // down". Reaches 0 at the same point as the rate (aFadeEnd).
            let aFadeEnd = 0.225  // ~450ms in a 2s fade
            if progress < aFadeEnd {
                let p = Float(progress / aFadeEnd)
                let angle = p * .pi / 2.0
                return maxVolumeA * cosf(angle) * cosf(angle)
            }
            return 0
        }
    }

    // MARK: - Volume curves for B (complementary to A's "hold → drop")
    //
    // B stays low while A holds, then ramps up as A drops.
    // This prevents both songs from being loud simultaneously (muddiness)
    // and creates the energy handoff that sounds like a DJ.

    func gainForPlayerB(at t: Double) -> Float {
        if config.needsAnticipation {
            if t < timings.anticipationStartTime {
                return 0
            } else if t < timings.filterStartTime {
                let dur = timings.filterStartTime - timings.anticipationStartTime
                guard dur > 0 else { return 0 }
                let p = Float((t - timings.anticipationStartTime) / dur)
                return maxVolumeB * 0.25 * max(0, p)
            } else if t < timings.fadeInStartTime {
                let dur = timings.fadeInStartTime - timings.filterStartTime
                guard dur > 0 else { return maxVolumeB * 0.25 }
                let p = Float((t - timings.filterStartTime) / dur)
                return maxVolumeB * (0.25 + 0.10 * p)
            }
            // Falls through to main curve from fadeInStartTime onward
        }

        guard t >= timings.fadeInStartTime else { return 0 }
        let fadeInDuration = timings.fadeInEndTime - timings.fadeInStartTime
        guard fadeInDuration > 0 else { return maxVolumeB }
        let progress = min(1.0, (t - timings.fadeInStartTime) / fadeInDuration)

        // Anticipation base: if B was already playing at ~35%, continue from there
        let baseLevel: Float = config.needsAnticipation ? 0.35 : 0.0

        switch config.transitionType {
        case .cut:
            // Cut: B enters during the last 3s (matching A's drop zone),
            // ramping over 1.5s to avoid the jarring "BAM" effect.
            // With anticipation, B was already teasing at 35% filtered.
            let cutZone = min(3.0, fadeInDuration)
            let bRampStart = timings.fadeInEndTime - cutZone
            if t < bRampStart {
                if config.needsAnticipation {
                    // Don't freeze B at a flat level for long fades.
                    // Gradually creep from 0.35 → 0.45 over max 4s, then hold at 0.45.
                    let holdStart = timings.fadeInStartTime
                    let holdDur = bRampStart - holdStart
                    if holdDur > 0 {
                        let elapsed = t - holdStart
                        let creepDur = min(4.0, holdDur)
                        let creepP = Float(min(1.0, elapsed / creepDur))
                        return maxVolumeB * (0.35 + 0.10 * creepP)
                    }
                    return maxVolumeB * 0.35
                }
                return 0
            }
            let startLevel: Float = config.needsAnticipation ? 0.45 : 0.0
            let rampP = Float(min(1.0, (t - bRampStart) / 1.5))
            return maxVolumeB * (startLevel + (1.0 - startLevel) * rampP)

        case .fadeOutACutB:
            // A fades out gradually → B should wait until A is low enough (~60% of fade),
            // then enter firmly. This prevents both songs being loud simultaneously.
            let waitUntil = 0.55  // A is at ~holdLevel dropping at this point
            if progress < waitUntil {
                // B stays very low during A's hold phase
                let p = Float(progress / waitUntil)
                return maxVolumeB * 0.15 * p
            }
            // Quick ramp to full once A is dropping
            let rampP = Float((progress - waitUntil) / (1.0 - waitUntil))
            let eased = rampP * rampP * (3.0 - 2.0 * rampP)
            return maxVolumeB * (0.15 + 0.85 * eased)

        case .eqMix, .beatMatchBlend:
            // Complementary to A's gradual descent (holdEnd=0.50):
            // B eases to 50% by midpoint (audible, establishes presence),
            // then sin² ramp to 100% as A's cos² drops — constant total power.
            let rampStart = 0.45  // B starts ramping slightly before A's drop phase
            if progress < rampStart {
                let p = Float(progress / rampStart)
                let target: Float = 0.50
                let eased = p * p * (3.0 - 2.0 * p)
                return maxVolumeB * (baseLevel + (target - baseLevel) * eased)
            }
            // sin² ramp complementary to A's cos²
            let rampP = Float((progress - rampStart) / (1.0 - rampStart))
            let angle = rampP * .pi / 2.0
            let sinSq = sinf(angle) * sinf(angle)
            return maxVolumeB * (0.50 + 0.50 * sinSq)

        case .naturalBlend:
            // Perfect complement to A's cos² curve: pure sin² ramp.
            // Together: cos²(x) + sin²(x) = 1 → constant total power, zero volume holes.
            let angle = Float(progress) * .pi / 2.0
            let sinSq = sinf(angle) * sinf(angle)
            return maxVolumeB * (baseLevel + (1.0 - baseLevel) * sinSq)

        case .cleanHandoff:
            // Sequential complement to A: silent until the gap ends (65% of window),
            // then sin² ramp to full over the last 35%. The 10% gap (55–65%) is the
            // "respiro" — short enough to not feel like dead air, long enough that the
            // ear perceives B as a fresh start rather than a continuation of A.
            // anticipation is forced off in the decision layer for cleanHandoff, so
            // baseLevel is always 0 here — no need to apply it.
            let bRampStart = 0.65
            if progress < bRampStart {
                return 0
            }
            let rampP = Float((progress - bRampStart) / (1.0 - bRampStart))
            let angle = rampP * .pi / 2.0
            let sinSq = sinf(angle) * sinf(angle)
            return maxVolumeB * sinSq

        case .cutAFadeInB:
            // A stays full then hard-cuts → B must be at ~100% BEFORE the cut.
            // Faster ramp: ease to 60% by midpoint, reach 100% at 80% of fade
            // (well before A's cut at ~98%). This avoids the volume hole.
            let rampEnd = 0.80
            if progress < rampEnd {
                let p = Float(progress / rampEnd)
                let eased = p * p * (3.0 - 2.0 * p)
                return maxVolumeB * (baseLevel + (1.0 - baseLevel) * eased)
            }
            return maxVolumeB

        case .stemMix:
            // Stem mix: B enters filtered (safe to be louder early — only vocals/mids pass).
            // Ease to 40% while A holds, then ramp to 100% as filters open and A drops.
            let rampStart = 0.50
            if progress < rampStart {
                let p = Float(progress / rampStart)
                let target: Float = 0.40
                let eased = p * p * (3.0 - 2.0 * p)
                return maxVolumeB * (baseLevel + (target - baseLevel) * eased)
            }
            let rampP = Float((progress - rampStart) / (1.0 - rampStart))
            let eased = rampP * rampP * (3.0 - 2.0 * rampP)
            return maxVolumeB * (0.40 + 0.60 * eased)

        case .dropMix:
            // Drop mix: B enters fast and reaches full volume by 60% of the fade.
            // Complements A's aggressive exit — minimal overlap at high volumes.
            let rampEnd = 0.60
            if progress < rampEnd {
                let p = Float(progress / rampEnd)
                let eased = p * p * (3.0 - 2.0 * p)
                return maxVolumeB * (baseLevel + (1.0 - baseLevel) * eased)
            }
            return maxVolumeB

        case .crossfade:
            // Complementary to A's gradual descent (holdEnd=0.45):
            // B eases to 45% by 40%, then sin² ramp for smooth power handoff.
            let rampStart = 0.40
            if progress < rampStart {
                let p = Float(progress / rampStart)
                let target: Float = 0.45
                let eased = p * p * (3.0 - 2.0 * p)
                return maxVolumeB * (baseLevel + (target - baseLevel) * eased)
            }
            let rampP = Float((progress - rampStart) / (1.0 - rampStart))
            let angle = rampP * .pi / 2.0
            let sinSq = sinf(angle) * sinf(angle)
            return maxVolumeB * (0.45 + 0.55 * sinSq)

        case .vinylStop:
            // Silent until A's rate has fully wound down (aFadeEnd=0.225) plus
            // a 100-tick "aire" buffer (~10% of window = 200ms in a 2s fade).
            // Then sin² ramp for the rest. This is the "DJ leaves a beat of
            // silence between two unmixable tracks" gesture, formalized.
            let bRampStart = 0.325
            if progress < bRampStart { return 0 }
            let rampP = Float((progress - bRampStart) / (1.0 - bRampStart))
            let angle = rampP * .pi / 2.0
            let sinSq = sinf(angle) * sinf(angle)
            return maxVolumeB * sinSq
        }
    }

    // MARK: - Filter automation via DispatchSourceTimer (background-safe, ~60Hz)

    private func startFilterAutomation() {
        lastTickTime = CACurrentMediaTime()
        let timer = DispatchSource.makeTimerSource(queue: Self.automationQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.filterTick()
        }
        filterTimer = timer
        timer.resume()

        // Safety net: when app returns to foreground after background suspension,
        // check if the crossfade should have already completed and force it.
        // Uses willEnterForegroundNotification (fires before didBecomeActive) for earliest possible recovery.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.checkAndForceCompleteIfStale()
        }
    }

    /// Called from foreground notification — if crossfade should have ended, force-complete.
    private func checkAndForceCompleteIfStale() {
        let t = CACurrentMediaTime()
        guard !isCancelled, t >= timings.transitionEndTime else { return }
        print("[CrossfadeExecutor] ⚠️ Foreground wake: crossfade overdue by \(String(format: "%.1f", t - timings.transitionEndTime))s — forcing completion")
        completeCrossfade()
    }

    private func filterTick() {
        guard !isCancelled else {
            filterTimer?.cancel()
            filterTimer = nil
            return
        }

        let t = CACurrentMediaTime()

        // Detect timer suspension gaps (iOS background throttling / CarPlay).
        // If we were suspended and have already passed the transition end, force-complete
        // immediately so B doesn't keep playing with frozen crossfade filters.
        let gap = t - lastTickTime
        lastTickTime = t
        if gap > 1.0 {
            print("[CrossfadeExecutor] ⚠️ Timer gap detected: \(String(format: "%.1f", gap))s")
            if t >= timings.transitionEndTime {
                print("[CrossfadeExecutor] ⚠️ Past transition end — forcing completion after suspension")
                completeCrossfade()
                return
            }
            // Not past end yet — continue and let the interpolation snap to correct values
            // (all filter math uses absolute time, so it self-corrects)
        }

        if t >= timings.transitionEndTime + 0.5 {
            completeCrossfade()
            return
        }

        // ── Volume automation via mixer.outputVolume ──
        // gainForPlayerA/B already incorporate ReplayGain (maxVolumeA/B).
        // mainMixerNode.outputVolume stays at user volume (untouched).
        let gA = gainForPlayerA(at: t)
        let gB = gainForPlayerB(at: t)
        mixerA.outputVolume = gA
        mixerB.outputVolume = gB

        // ── Stereo micro-separation: reduces masking during overlap ──
        // A drifts slightly left, B slightly right. Max ±0.08 (barely perceptible).
        // Ramps with crossfade progress so it's not a sudden shift.
        let fadeDur = timings.transitionEndTime - timings.volumeFadeStartTime
        if fadeDur > 0 && t >= timings.volumeFadeStartTime {
            let panProgress = Float(min(1.0, (t - timings.volumeFadeStartTime) / fadeDur))
            let panAmount: Float = 0.08 * panProgress
            mixerA.pan = -panAmount  // A slightly left
            mixerB.pan = panAmount   // B slightly right
        }

        // ── Filter automation (always active on both players) ──
        applyFiltersA(at: t)
        applyFiltersB(at: t)

        // ── Time-stretch rate automation for A ──
        // A ramps from 1.0 → config.rateA during the fade, using a stepped curve
        // that changes on beat boundaries to avoid mid-beat tempo jumps.
        // B stays at config.rateB (set in setupTimeStretch).
        if config.useTimeStretch, let tpA = timePitchA, t >= timings.volumeFadeStartTime {
            let duration = timings.transitionEndTime - timings.volumeFadeStartTime
            if duration > 0 {
                var p = Float(min(1.0, (t - timings.volumeFadeStartTime) / duration))
                // If we have beat data, quantize the ramp to beat boundaries
                // This means A's rate changes in steps aligned to beats, not continuously
                if hasBeatData && config.beatIntervalA > 0 {
                    let elapsed = t - timings.volumeFadeStartTime
                    let beatsElapsed = floor(elapsed / config.beatIntervalA)
                    let totalBeats = max(1, floor(duration / config.beatIntervalA))
                    p = Float(min(1.0, beatsElapsed / totalBeats))
                }
                // S-curve for smoother perceptual ramp (ease-in/ease-out)
                let smoothP = p * p * (3.0 - 2.0 * p)
                tpA.rate = 1.0 + (config.rateA - 1.0) * smoothP
            }
        }

        // ── Vinyl-stop rate ramp (independent of useTimeStretch) ──
        // A's rate decays from 1.0 → 0 over the first 22.5% of the fade window
        // with a fast-attack curve `1 - p^0.6` (real turntables decelerate
        // quadratically due to torque drop, but 0.6 reads as more "punchy").
        // The volume curve in gainForPlayerA mirrors this so we don't get a
        // half-pitched track audible at full volume.
        if config.transitionType == .vinylStop, let tpA = timePitchA, t >= timings.volumeFadeStartTime {
            let duration = timings.transitionEndTime - timings.volumeFadeStartTime
            if duration > 0 {
                let progress = min(1.0, (t - timings.volumeFadeStartTime) / duration)
                let aFadeEnd = 0.225
                if progress < aFadeEnd {
                    let p = Float(progress / aFadeEnd)
                    // y = 1 - p^0.6 — fast initial decay, gentle tail
                    let rate = 1.0 - powf(p, 0.6)
                    // AVAudioUnitTimePitch.rate has min 1/32 (~0.03). Below that,
                    // hold at minimum to avoid runtime errors; volume will be 0
                    // anyway by the time we hit the floor.
                    tpA.rate = max(1.0 / 32.0, rate)
                } else {
                    tpA.rate = 1.0 / 32.0  // hold at floor; track is silent
                }
            }
        }

        if t - lastLogTime >= 1.0 {
            lastLogTime = t
            let elapsed = t - timings.startTime
            let vol = getMasterVolume?() ?? 1.0
            let filterLabelA = useLowpassA ? "lp" : "hp"
            print("[CrossfadeExecutor] t+\(String(format: "%.1f", elapsed))s | A: vol=\(String(format: "%.3f", gA * vol)) \(filterLabelA)=\(String(format: "%.0f", diagFreqA))Hz | B: vol=\(String(format: "%.3f", gB * vol)) hp=\(String(format: "%.0f", diagFreqB))Hz | master=\(String(format: "%.2f", vol))")

            TransitionDiagnostics.shared.publishTick(
                elapsed: elapsed,
                volumeA: gA,
                volumeB: gB,
                masterVolume: vol,
                highpassFreqA: diagFreqA,
                highpassFreqB: diagFreqB,
                filterTypeA: useLowpassA ? "lp" : "hp",
                lowshelfGainA: diagLsGainA,
                lowshelfGainB: diagLsGainB,
                dynamicQA: diagQA,
                dynamicQB: diagQB,
                notchFreqB: diagNotchFreqB,
                notchGainB: diagNotchGainB,
                panA: mixerA.pan,
                panB: mixerB.pan,
                currentRateA: timePitchA?.rate ?? 1.0
            )
        }
    }

    // MARK: - Filter A automation (port exacto de AudioEffectsChain.ts líneas 209-224)

    private func applyFiltersA(at t: Double) {
        guard t >= timings.filterStartTime else { return }

        // Short CUT: highpass ramp is pointless — the quick fade handles separation.
        if (config.transitionType == .cut || config.transitionType == .cutAFadeInB),
           config.fadeDuration < 5.0 {
            return
        }

        // CLEAN_HANDOFF / VINYL_STOP: A and B never overlap, so spectral shaping
        // serves no purpose. The volume curve (and rate ramp for vinyl-stop) does
        // all the work. Skipping filter automation also avoids the audible "swept"
        // character that would otherwise bleed into A's outro and contradict the
        // "clean radio handoff" intent — and for vinyl-stop, layering a filter
        // sweep on top of a spin-down sounds gimmicky.
        if config.transitionType == .cleanHandoff || config.transitionType == .vinylStop {
            return
        }

        let totalFilterDur = timings.transitionEndTime - timings.filterStartTime
        guard totalFilterDur > 0 else { return }

        // Pivot = where filters shift from gentle to aggressive (aligned with volume drop)
        let pivotTime = timings.filterStartTime + totalFilterDur * 0.60

        // ── Band 0: Lowpass (energy-down) OR highpass (normal) ──
        var freqA: Float
        let band0A: BiquadCoefficients
        if useLowpassA, let lpA = preset.lowpassA {
            let midFreq = lpA.startFreq * 0.7 + lpA.endFreq * 0.3
            if t < pivotTime {
                let p = Float((t - timings.filterStartTime) / (pivotTime - timings.filterStartTime))
                freqA = expInterp(lpA.startFreq, midFreq, min(1, p))
            } else {
                let p = Float((t - pivotTime) / (timings.transitionEndTime - pivotTime))
                freqA = expInterp(midFreq, lpA.endFreq, min(1, p))
            }
            band0A = BiquadCoefficientCalculator.lowpass(frequency: freqA, sampleRate: sampleRate, Q: lpA.q)
        } else {
            if t < pivotTime {
                let p = Float((t - timings.filterStartTime) / (pivotTime - timings.filterStartTime))
                freqA = expInterp(preset.highpassA.startFreq, preset.highpassA.midFreq, min(1, p))
            } else {
                let p = Float((t - pivotTime) / (timings.transitionEndTime - pivotTime))
                freqA = expInterp(preset.highpassA.midFreq, preset.highpassA.endFreq, min(1, p))
            }
            // Dynamic Q Resonance: bell-shaped Q curve that peaks mid-crossfade.
            // Creates the classic DJ "sweeping filter" resonance at the cutoff frequency.
            // Q rises from the preset's base Q to a peak (3.5) and back down.
            // Hard-clamped at 4.0 to prevent filter instability/self-oscillation.
            let qValue: Float
            if useDynamicQ, totalFilterDur > 0 {
                let qProgress = Float((t - timings.filterStartTime) / totalFilterDur)
                // Gaussian bell: center at 55% of crossfade, width 30% — peaks during
                // the most active filter sweep phase (around pivotTime).
                let bellCenter: Float = 0.55
                let bellWidth: Float = 0.30
                let exponent = -powf((qProgress - bellCenter) / bellWidth, 2) / 2.0
                // Clamp exponent to avoid expf underflow on extreme values
                let bellValue = expf(max(-10, exponent))
                let baseQ = preset.highpassA.q
                let peakQ: Float = 3.5
                qValue = min(4.0, baseQ + (peakQ - baseQ) * bellValue)
            } else {
                qValue = preset.highpassA.q
            }
            diagQA = qValue
            band0A = BiquadCoefficientCalculator.highpass(frequency: freqA, sampleRate: sampleRate, Q: qValue)
        }
        diagFreqA = freqA

        // ── Band 1: Bass swap lowshelf (or Bass Kill) ──
        var band1A: BiquadCoefficients = .passthrough
        if useBassManagement, let lsA = preset.lowshelfA {
            let filterDur = timings.transitionEndTime - timings.filterStartTime
            if filterDur > 0 {
                var lsGain: Float
                if useBassKill {
                    // Bass Kill: hold at natural level, then instant cut at bassSwapTime.
                    // 100ms anti-click ramp — imperceptible but prevents clicks/pops
                    // from abrupt coefficient changes in the biquad delay line.
                    let killRampDuration: Double = 0.1
                    let killDepth: Float = -60.0  // effectively silence below shelf freq
                    if t < bassSwapTime {
                        lsGain = lsA.startGain  // 0dB — full bass until the kill
                    } else if t < bassSwapTime + killRampDuration {
                        let rampP = Float((t - bassSwapTime) / killRampDuration)
                        lsGain = linInterp(lsA.startGain, killDepth, rampP)
                    } else {
                        lsGain = killDepth  // -60dB — bass is dead
                    }
                } else {
                    // Standard gradual bass swap
                    let scaledMidGain = lsA.midGain * danceabilityBassScale
                    let scaledEndGain = lsA.endGain * danceabilityBassScale
                    if t < bassSwapTime {
                        let preDur = bassSwapTime - timings.filterStartTime
                        let preP = preDur > 0 ? Float((t - timings.filterStartTime) / preDur) : 1.0
                        lsGain = linInterp(lsA.startGain, scaledMidGain, preP)
                    } else {
                        let postDur = timings.transitionEndTime - bassSwapTime
                        let postP = postDur > 0 ? Float((t - bassSwapTime) / postDur) : 1.0
                        lsGain = linInterp(scaledMidGain, scaledEndGain, postP)
                    }
                }
                diagLsGainA = lsGain
                band1A = BiquadCoefficientCalculator.lowShelf(frequency: lsA.frequency, sampleRate: sampleRate, gainDB: lsGain)
            }
        }

        // ── Band 2: Mid scoop ──
        var band2A: BiquadCoefficients = .passthrough
        if useMidScoop, let ms = preset.midScoopA {
            var msGain: Float
            let holdTarget = ms.startGain + (ms.endGain - ms.startGain) * 0.35
            if t < pivotTime {
                let p = Float((t - timings.filterStartTime) / (pivotTime - timings.filterStartTime))
                msGain = linInterp(ms.startGain, holdTarget, min(1, p))
            } else {
                let p = Float((t - pivotTime) / (timings.transitionEndTime - pivotTime))
                msGain = linInterp(holdTarget, ms.endGain, min(1, p))
            }
            band2A = BiquadCoefficientCalculator.parametric(frequency: ms.frequency, sampleRate: sampleRate, gainDB: msGain, bandwidth: ms.bandwidth)
        }

        // ── Band 3: High-shelf cut ──
        var band3A: BiquadCoefficients = .passthrough
        if useHighShelfCut, let hs = preset.highShelfA {
            var hsGain: Float
            let holdTarget = hs.startGain + (hs.endGain - hs.startGain) * 0.30
            if t < pivotTime {
                let p = Float((t - timings.filterStartTime) / (pivotTime - timings.filterStartTime))
                hsGain = linInterp(hs.startGain, holdTarget, min(1, p))
            } else {
                let p = Float((t - pivotTime) / (timings.transitionEndTime - pivotTime))
                hsGain = linInterp(holdTarget, hs.endGain, min(1, p))
            }
            band3A = BiquadCoefficientCalculator.highShelf(frequency: hs.frequency, sampleRate: sampleRate, gainDB: hsGain)
        }

        dspA.setCoefficients(band0: band0A, band1: band1A, band2: band2A, band3: band3A)
    }

    // MARK: - Filter B automation (port exacto de AudioEffectsChain.ts líneas 332-394)

    private func applyFiltersB(at t: Double) {
        guard !config.skipBFilters else { return }

        var hpFreq: Float
        var lsGain: Float

        if config.needsAnticipation {
            if t < timings.filterStartTime {
                let dur = timings.filterStartTime - timings.anticipationStartTime
                guard dur > 0 else { return }
                let p = Float((t - timings.anticipationStartTime) / dur)
                hpFreq = linInterp(preset.highpassB.startFreq, preset.highpassB.midFreq, p)
                lsGain = linInterp(preset.lowshelfB.startGain, preset.lowshelfB.midGain, p)
            } else if t < timings.fadeInStartTime {
                let dur = timings.fadeInStartTime - timings.filterStartTime
                guard dur > 0 else { return }
                let p = Float((t - timings.filterStartTime) / dur)
                hpFreq = linInterp(preset.highpassB.midFreq, 300, p)
                lsGain = linInterp(preset.lowshelfB.midGain, -4, p)
            } else if t < timings.fadeInEndTime {
                let dur = timings.fadeInEndTime - timings.fadeInStartTime
                guard dur > 0 else { return }
                let p = Float((t - timings.fadeInStartTime) / dur)
                hpFreq = linInterp(300, preset.highpassB.endFreq, p)
                lsGain = linInterp(-4, preset.lowshelfB.endGain, p)
            } else {
                hpFreq = preset.highpassB.endFreq
                lsGain = preset.lowshelfB.endGain
            }
            // Bass Kill override: even with anticipation, B's bass must stay held
            // until the kill moment. Without this, anticipation gradually opens B's
            // lowshelf while A still has full bass → bass pile-up before the kill.
            if useBassKill {
                let killRampDuration: Double = 0.1
                if t < bassSwapTime {
                    lsGain = preset.lowshelfB.startGain
                } else if t < bassSwapTime + killRampDuration {
                    let rampP = Float((t - bassSwapTime) / killRampDuration)
                    lsGain = linInterp(preset.lowshelfB.startGain, preset.lowshelfB.endGain, rampP)
                } else {
                    lsGain = preset.lowshelfB.endGain
                }
            }
        } else {
            guard t >= timings.fadeInStartTime else { return }
            let dur = timings.fadeInEndTime - timings.fadeInStartTime
            guard dur > 0 else { return }
            let p = Float(min(1, (t - timings.fadeInStartTime) / dur))
            hpFreq = linInterp(preset.highpassB.startFreq, preset.highpassB.endFreq, p)
            if useBassManagement {
                if useBassKill {
                    // Bass Kill coordination: B keeps bass filtered (startGain, e.g. -8dB)
                    // until bassSwapTime, then opens instantly via same 100ms ramp.
                    // This prevents bass pile-up: A has full bass + B with partial bass
                    // would create excess low-end before the kill moment.
                    let killRampDuration: Double = 0.1
                    if t < bassSwapTime {
                        lsGain = preset.lowshelfB.startGain  // held filtered
                    } else if t < bassSwapTime + killRampDuration {
                        let rampP = Float((t - bassSwapTime) / killRampDuration)
                        lsGain = linInterp(preset.lowshelfB.startGain, preset.lowshelfB.endGain, rampP)
                    } else {
                        lsGain = preset.lowshelfB.endGain  // 0dB — B bass fully open
                    }
                } else {
                    let bassDur = bassSwapTime - timings.fadeInStartTime
                    let bassP = bassDur > 0 ? Float(min(1, (t - timings.fadeInStartTime) / bassDur)) : 1.0
                    lsGain = linInterp(preset.lowshelfB.startGain, preset.lowshelfB.endGain, bassP)
                }
            } else {
                lsGain = linInterp(preset.lowshelfB.startGain, preset.lowshelfB.endGain, p)
            }
        }

        diagFreqB = hpFreq
        diagLsGainB = lsGain

        // ── Band 0: highpass with optional Twin dynQ ──
        // Twin dynQ mirrors A's Q resonance bell on B's incoming highpass with an
        // earlier center (0.40 vs A's 0.55). The two bells overlap in time, but
        // B's peak fires first → listener perceives the Q "handing off" from B to A,
        // exactly like a DJ rolling the resonance knob between two channels.
        // Anchored to B's own filter window (fadeInStart → fadeInEnd) so the curve is
        // independent of A's filterLead. Disabled in anticipation mode to preserve
        // that path's careful multi-stage shape.
        let qBValue: Float
        let bWindowDur = timings.fadeInEndTime - timings.fadeInStartTime
        if useDynamicQ && !config.needsAnticipation && bWindowDur > 0 {
            let qProgress = Float((t - timings.fadeInStartTime) / bWindowDur)
            // Clamp progress to [0, 1] so values outside the window (early reads or
            // post-fade lingering) just produce bell tails, not extrapolated noise.
            let qProgressClamped = min(1, max(0, qProgress))
            let exponent = -powf((qProgressClamped - Self.dynQBellCenterB) / Self.dynQBellWidth, 2) / 2.0
            let bellValue = expf(max(-10, exponent))
            let baseQ = preset.highpassB.q
            qBValue = min(Self.dynQMaxQ, baseQ + (Self.dynQPeakQ - baseQ) * bellValue)
        } else {
            qBValue = preset.highpassB.q
        }
        diagQB = qBValue
        let band0B = BiquadCoefficientCalculator.highpass(frequency: hpFreq, sampleRate: sampleRate, Q: qBValue)

        let band1B = BiquadCoefficientCalculator.lowShelf(frequency: preset.lowshelfB.frequency, sampleRate: sampleRate, gainDB: lsGain)

        // ── Band 2: Phaser Notch Sweep on B (Sprint 2) ──
        // Narrow parametric notch (BW ≈ 0.3 oct) whose center frequency sweeps
        // exponentially 250 → 6000 Hz over B's filter window, while depth follows a
        // bell (-6 → -24 → -6 dB). Sounds like a static phaser sweep "riding through" B.
        // Pre-gated in setupInitialEQ + init: useNotchSweep already implies
        // !skipBFilters && !needsAnticipation && useDynamicQ.
        let band2B: BiquadCoefficients
        if useNotchSweep && bWindowDur > 0 {
            let notchProgress = Float((t - timings.fadeInStartTime) / bWindowDur)
            let p = min(1, max(0, notchProgress))
            // Exponential frequency sweep — perceptually linear (octaves per second).
            let notchFreq = expInterp(Self.notchStartFreq, Self.notchEndFreq, p)
            // Bell-shaped depth: peaks at notchPeakGain at notchBellCenter, returns
            // to notchTailGain at the edges. Same Gaussian shape as dynQ for consistency.
            let exponent = -powf((p - Self.notchBellCenter) / Self.notchBellWidth, 2) / 2.0
            let bellValue = expf(max(-10, exponent))
            let notchGain = Self.notchTailGain + (Self.notchPeakGain - Self.notchTailGain) * bellValue
            diagNotchFreqB = notchFreq
            diagNotchGainB = notchGain
            band2B = BiquadCoefficientCalculator.parametric(
                frequency: notchFreq,
                sampleRate: sampleRate,
                gainDB: notchGain,
                bandwidth: Self.notchBandwidth
            )
        } else {
            band2B = .passthrough
        }

        dspB.setCoefficients(band0: band0B, band1: band1B, band2: band2B, band3: .passthrough)
    }

    // MARK: - Completion

    /// Completion must ALWAYS run on automationQueue to serialize with filterTick.
    /// This prevents the race where filterTick re-applies filters after reset
    /// because isCancelled is not atomic across threads.
    private func completeCrossfade() {
        if DispatchQueue.getSpecific(key: Self.queueKey) == nil {
            // Called from main/other thread — dispatch to automationQueue
            Self.automationQueue.async { [weak self] in
                self?.completeCrossfade()
            }
            return
        }

        // Now guaranteed to be on automationQueue (serialized with filterTick)
        guard !isCancelled else { return }
        isCancelled = true

        filterTimer?.cancel()
        filterTimer = nil
        safetyWatchdog?.cancel()
        safetyWatchdog = nil
        secondaryWatchdog?.cancel()
        secondaryWatchdog = nil
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
            foregroundObserver = nil
        }

        mixerA.outputVolume = 0
        mixerB.outputVolume = maxVolumeB

        // Reset crossfade DSP to passthrough + reset time-stretch
        dspA.reset()
        dspB.reset()
        mixerA.pan = 0
        mixerB.pan = 0
        resetTimeStretch()

        let vol = getMasterVolume?() ?? 1.0
        engine.mainMixerNode.outputVolume = vol

        print("[CrossfadeExecutor] Crossfade completado — B vol=\(String(format: "%.3f", maxVolumeB)) master=\(String(format: "%.2f", vol))")

        // Audit after reset
        Self.auditDSPState(source: "completeCrossfade", dspA: dspA, dspB: dspB,
                           mixerA: mixerA, mixerB: mixerB,
                           timePitchA: timePitchA, timePitchB: timePitchB)

        TransitionDiagnostics.shared.publishCompletion()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onComplete?(self.timings.startOffset)
        }
    }

    // MARK: - Watchdog

    private func startSafetyWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: Self.automationQueue)
        let timeout = timings.totalTime + 2.0
        timer.schedule(deadline: .now() + timeout, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.isCancelled else { return }
            print("[CrossfadeExecutor] ⚠️ Watchdog disparado — abortando crossfade por timeout")
            self.completeCrossfade()
        }
        safetyWatchdog = timer
        timer.resume()
    }

    /// Watchdog secundario: backstop para casos extremos donde el watchdog principal
    /// fue retrasado por suspensión agresiva de iOS. Dispara ~50% más tarde que el principal.
    private func startSecondaryWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: Self.automationQueue)
        let timeout = timings.totalTime + 2.0 + max(5.0, timings.totalTime * 0.5)
        timer.schedule(deadline: .now() + timeout, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.isCancelled else { return }
            print("[CrossfadeExecutor] ⚠️ Watchdog secundario disparado — forzando completado")
            self.completeCrossfade()
        }
        secondaryWatchdog = timer
        timer.resume()
    }

    // MARK: - Interpolation helpers

    private func linInterp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * min(1, max(0, t))
    }

    private func expInterp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        let safeA = max(a, 0.001)
        let safeB = max(b, 0.001)
        let clampedT = min(1, max(0, t))
        return safeA * powf(safeB / safeA, clampedT)
    }

    /// Convierte Q factor a bandwidth en octavas (aproximación).
    /// Q=0.7 ≈ 2.0 octavas, Q=0.5 ≈ 2.8 octavas
    private func qToBandwidth(_ q: Float) -> Float {
        guard q > 0 else { return 2.0 }
        // BW = 2 * asinh(1/(2*Q)) / ln(2)
        let val = 1.0 / (2.0 * q)
        return 2.0 * asinh(val) / logf(2.0)
    }
}
