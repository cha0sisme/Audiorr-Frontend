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

        init(entryPoint: Double, fadeDuration: Double, transitionType: TransitionType,
             useFilters: Bool, useAggressiveFilters: Bool, needsAnticipation: Bool,
             anticipationTime: Double, useTimeStretch: Bool = false,
             rateA: Float = 1.0, rateB: Float = 1.0,
             energyA: Double = 0.5, energyB: Double = 0.5,
             beatIntervalA: Double = 0, beatIntervalB: Double = 0,
             downbeatTimesA: [Double] = [], downbeatTimesB: [Double] = [],
             useMidScoop: Bool = false, useHighShelfCut: Bool = false,
             isOutroInstrumental: Bool = false, isIntroInstrumental: Bool = false,
             danceability: Double = 0.5, skipBFilters: Bool = false) {
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

    // MARK: - Prototipos de EQ Global
    // Permite que B herede el estado de EQ de A si el usuario tiene un EQ activo.
    struct EQState {
        var band0Frequency: Float = 20
        var band0Bypass: Bool = true
        var band1Frequency: Float = 200
        var band1Gain: Float = 0
        var band1Bypass: Bool = true
    }

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
    private let eqA: AVAudioUnitEQ
    private let eqB: AVAudioUnitEQ
    private let mixerA: AVAudioMixerNode
    private let mixerB: AVAudioMixerNode
    private let timePitchA: AVAudioUnitTimePitch?
    private let timePitchB: AVAudioUnitTimePitch?
    private let currentFile: AVAudioFile?
    private let nextFile: AVAudioFile

    // DispatchSourceTimer en vez de CADisplayLink — funciona en background
    // Uses a dedicated high-priority queue instead of .main to avoid iOS
    // throttling/suspending the timer during background audio or CarPlay.
    static let automationQueue = DispatchQueue(
        label: "com.audiorr.crossfade.automation", qos: .userInteractive
    )
    private var filterTimer: DispatchSourceTimer?
    private var safetyWatchdog: DispatchSourceTimer?
    private var secondaryWatchdog: DispatchSourceTimer?
    private var isCancelled = false
    private var lastLogTime: Double = 0
    private var lastTickTime: Double = 0
    private var foregroundObserver: Any?

    var onComplete: ((Double) -> Void)?
    /// Llamado si playerB termina de forma natural sin que completeCrossfade() haya sido invocado.
    /// Permite que AudioEngineManager notifique onTrackEnd como safety net.
    var onPlayerBEndedNaturally: (() -> Void)?

    // MARK: - Init

    init(
        config: Config,
        engine: AVAudioEngine,
        playerA: AVAudioPlayerNode,
        playerB: AVAudioPlayerNode,
        eqA: AVAudioUnitEQ,
        eqB: AVAudioUnitEQ,
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
        nextTitle: String
    ) {
        self.config = config
        self.engine = engine
        self.playerA = playerA
        self.playerB = playerB
        self.eqA = eqA
        self.eqB = eqB
        self.mixerA = mixerA
        self.mixerB = mixerB
        self.timePitchA = timePitchA
        self.timePitchB = timePitchB
        self.currentFile = currentFile
        self.nextFile = nextFile
        self.maxVolumeA = maxVolumeA
        self.maxVolumeB = maxVolumeB
        self.getMasterVolume = getMasterVolume

        // Seleccionar preset — informed by backend analysis
        // Energy-down: if B is significantly less energetic, use lowpass sweep on A
        let isEnergyDown = config.energyB < config.energyA - 0.2
        // Both sides instrumental = clean transition, lighter filters suffice
        let bothInstrumental = config.isOutroInstrumental && config.isIntroInstrumental
        if config.needsAnticipation {
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

        // Calcular timings (port exacto de CrossfadeEngine.calculateTimings líneas 244-289)
        timings = Self.calculateTimings(config: config)

        // Compute beat-aligned bass swap point
        hasBeatData = config.beatIntervalA > 0 || config.beatIntervalB > 0
        bassSwapTime = Self.computeBassSwapTime(config: config, timings: timings)

        // Log
        let filtersDesc = config.useFilters ? (config.useAggressiveFilters ? "AGGRESSIVE" : "normal") : "OFF"
        let djDesc = [useMidScoop ? "midScoop" : nil, useHighShelfCut ? "hiShelf" : nil]
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
    }

    // MARK: - Timing calculation (port exacto de CrossfadeEngine.calculateTimings)

    static func calculateTimings(config: Config) -> Timings {
        let now = CACurrentMediaTime()

        let filterLead = config.useFilters ? min(1.5, config.fadeDuration * 0.2) : 0

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
        let targetPercent = config.isOutroInstrumental ? 0.15 : 0.25
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
                // Only consider downbeats within the early crossfade window (bass-first)
                let minT = fadeStart + fadeDur * (config.isOutroInstrumental ? 0.05 : 0.10)
                let maxT = fadeStart + fadeDur * (config.isOutroInstrumental ? 0.35 : 0.45)
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
        let minClamp = fadeDur * (config.isOutroInstrumental ? 0.05 : 0.10)
        let maxClamp = fadeDur * (config.isOutroInstrumental ? 0.35 : 0.45)
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
            // Reset EQ and time-stretch that setupInitialEQ/setupTimeStretch already applied
            resetCrossfadeBands(eqA)
            resetCrossfadeBands(eqB)
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

        // Immediate reset on calling thread (best-effort)
        resetCrossfadeBands(eqA)
        resetCrossfadeBands(eqB)
        mixerA.pan = 0
        mixerB.pan = 0
        resetTimeStretch()

        // Dispatch a second reset to automationQueue — this serializes AFTER any
        // in-flight filterTick() that may have already passed the isCancelled guard
        // and is about to write EQ values. DispatchSource.cancel() does NOT stop
        // an already-executing handler, so without this the filterTick can overwrite
        // the reset above. This is the root cause of the "stuck filter on playerB" bug.
        let eqA = self.eqA, eqB = self.eqB
        let mA = self.mixerA, mB = self.mixerB
        let tpA = self.timePitchA, tpB = self.timePitchB
        Self.automationQueue.async {
            Self.resetBandsStatic(eqA)
            Self.resetBandsStatic(eqB)
            mA.pan = 0
            mB.pan = 0
            tpA?.rate = 1.0
            tpB?.rate = 1.0
        }
        // Delayed backstop: 150ms later, reset again in case a stale timer event
        // was queued before cancel() invalidated the source.
        Self.automationQueue.asyncAfter(deadline: .now() + 0.15) {
            Self.resetBandsStatic(eqA)
            Self.resetBandsStatic(eqB)
            mA.pan = 0
            mB.pan = 0
            tpA?.rate = 1.0
            tpB?.rate = 1.0
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
        timePitchA?.rate = 1.0
        timePitchB?.rate = 1.0
    }

    /// Resets crossfade bands (0-3) to neutral: bypass + neutral parameters.
    /// AVAudioUnitEQ bypass can be unreliable in CoreAudio — the DSP may keep
    /// processing even with bypass=true. Setting gain=0 and freq to inaudible
    /// values guarantees no residual filtering even if bypass fails.
    private func resetCrossfadeBands(_ eq: AVAudioUnitEQ) {
        Self.resetBandsStatic(eq)
    }

    /// Static version — callable from closures that capture the EQ ref without `self`.
    /// Used by cancel()'s automationQueue dispatches to serialize after in-flight filterTicks.
    /// Internal access: AudioEngineManager.cancelCrossfade() also needs this for its backstop reset.
    static func resetBandsStatic(_ eq: AVAudioUnitEQ) {
        let count = min(eq.bands.count, 4)
        for i in 0..<count {
            let band = eq.bands[i]
            band.bypass = true
            band.gain = 0           // neutral for lowshelf/parametric/highshelf
            band.bandwidth = 2.0    // wide/flat — no resonance peak even if bypass fails
            if band.filterType == .highPass {
                band.frequency = 20  // below audible — no effect
            } else if band.filterType == .lowPass {
                band.frequency = 20000  // above audible — no effect
            }
        }
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
            config.transitionType == .beatMatchBlend || config.transitionType == .eqMix
        useLowpassA = preset.lowpassA != nil

        // High danceability (>0.7) = preserve bass/groove: scale lowshelf cuts to 50-100%.
        // This keeps the track's energy/groove during the transition.
        if config.danceability > 0.7 {
            // 0.7 → 1.0, 1.0 → 0.5 (linear interpolation)
            danceabilityBassScale = Float(1.0 - (config.danceability - 0.7) / 0.3 * 0.5)
        }

        // ── Player A: highpass (or lowpass for energy-down) ──
        if useLowpassA, let lpA = preset.lowpassA {
            // Lowpass sweep on A for energy-down transitions: song "goes dark"
            eqA.bands[0].bypass = false
            eqA.bands[0].filterType = .lowPass
            eqA.bands[0].frequency = lpA.startFreq
            eqA.bands[0].bandwidth = qToBandwidth(lpA.q)
        } else {
            // Highpass A: sweeps up to thin out the outgoing song
            eqA.bands[0].bypass = false
            eqA.bands[0].filterType = .highPass
            eqA.bands[0].frequency = preset.highpassA.startFreq
            eqA.bands[0].bandwidth = qToBandwidth(preset.highpassA.q)
        }

        // Bass swap: lowshelf on A to cut bass coordinately with B
        if useBassManagement, let lsA = preset.lowshelfA {
            eqA.bands[1].bypass = false
            eqA.bands[1].filterType = .lowShelf
            eqA.bands[1].frequency = lsA.frequency
            eqA.bands[1].gain = lsA.startGain
        }

        // ── Player B: highpass sweep (bass gradually enters) + lowshelf ──
        // Skip when A's outro is short — B enters clean, no filtered sound
        if !config.skipBFilters {
            eqB.bands[0].bypass = false
            eqB.bands[0].filterType = .highPass
            eqB.bands[0].frequency = preset.highpassB.startFreq
            eqB.bands[0].bandwidth = qToBandwidth(preset.highpassB.q)

            eqB.bands[1].bypass = false
            eqB.bands[1].filterType = .lowShelf
            eqB.bands[1].frequency = preset.lowshelfB.frequency
            eqB.bands[1].gain = preset.lowshelfB.startGain
        }

        // ── Band 2: Mid scoop on A (vocal anti-clash, ~1.5kHz parametric dip) ──
        // Skip mid-scoop when B's intro is instrumental — no vocal clash risk
        useMidScoop = config.useMidScoop && !config.isIntroInstrumental && preset.midScoopA != nil
        if useMidScoop, let ms = preset.midScoopA {
            eqA.bands[2].bypass = false
            eqA.bands[2].filterType = .parametric
            eqA.bands[2].frequency = ms.frequency
            eqA.bands[2].bandwidth = ms.bandwidth
            eqA.bands[2].gain = ms.startGain
        }

        // ── Band 3: High-shelf cut on A (hi-hat/cymbal cleanup, ~8kHz) ──
        // Skip high-shelf when A's outro is instrumental — no hi-hat/cymbal clash
        useHighShelfCut = config.useHighShelfCut && !config.isOutroInstrumental && preset.highShelfA != nil
        if useHighShelfCut, let hs = preset.highShelfA {
            eqA.bands[3].bypass = false
            eqA.bands[3].filterType = .highShelf
            eqA.bands[3].frequency = hs.frequency
            eqA.bands[3].gain = hs.startGain
        }

        // Copy global EQ (bands 4-7) from A to B
        for i in 4..<8 {
            eqB.bands[i].bypass = eqA.bands[i].bypass
            eqB.bands[i].filterType = eqA.bands[i].filterType
            eqB.bands[i].frequency = eqA.bands[i].frequency
            eqB.bands[i].bandwidth = eqA.bands[i].bandwidth
            eqB.bands[i].gain = eqA.bands[i].gain
        }
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
        guard t >= timings.volumeFadeStartTime else { return maxVolumeA }
        guard t < timings.transitionEndTime else { return 0 }

        let duration = timings.transitionEndTime - timings.volumeFadeStartTime
        let progress = (t - timings.volumeFadeStartTime) / duration

        switch config.transitionType {
        case .cut, .cutAFadeInB:
            // Hard cut: A stays full until the last 0.2s, then drops instantly
            let cutStart = max(0, 1.0 - 0.2 / duration)
            if progress < cutStart { return maxVolumeA }
            let cutP = Float((progress - cutStart) / (1.0 - cutStart))
            return maxVolumeA * powf(0.0001 / maxVolumeA, cutP)

        case .eqMix, .beatMatchBlend:
            // "Hold → drop": A stays at ~85% until 65% of the fade,
            // then drops exponentially to 0 at the punch.
            // Mimics a DJ holding A while EQ/bass does the work, then pulling the fader.
            let holdLevel: Float = 0.85
            let holdEnd = 0.65
            if progress < holdEnd {
                // Gentle ease from 100% to holdLevel
                let p = Float(progress / holdEnd)
                let eased = p * p  // quadratic ease-in
                return maxVolumeA * (1.0 - (1.0 - holdLevel) * eased)
            }
            // Fast exponential drop from holdLevel to 0
            let dropP = Float((progress - holdEnd) / (1.0 - holdEnd))
            return maxVolumeA * holdLevel * powf(0.0001 / holdLevel, dropP)

        case .naturalBlend:
            // "Hold → drop" with equal-power character.
            // A holds at ~85% until 60%, then cos² drop to 0.
            let holdLevel: Float = 0.85
            let holdEnd = 0.60
            if progress < holdEnd {
                let p = Float(progress / holdEnd)
                let eased = p * p
                return maxVolumeA * (1.0 - (1.0 - holdLevel) * eased)
            }
            // Remap remaining 40% to cos² drop
            let dropP = Float((progress - holdEnd) / (1.0 - holdEnd))
            let angle = dropP * .pi / 2.0
            return maxVolumeA * holdLevel * cosf(angle) * cosf(angle)

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

        case .crossfade:
            // Standard crossfade with "hold → drop" character.
            // A eases to 80% over first 60%, then exponential drop.
            let holdLevel: Float = 0.80
            let holdEnd = 0.60
            if progress < holdEnd {
                let p = Float(progress / holdEnd)
                let eased = p * p
                return maxVolumeA * (1.0 - (1.0 - holdLevel) * eased)
            }
            let dropP = Float((progress - holdEnd) / (1.0 - holdEnd))
            return maxVolumeA * holdLevel * powf(0.0001 / holdLevel, dropP)
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
            // Pure cut: B comes in fast (0.1s)
            return maxVolumeB * Float(min(1.0, (t - timings.fadeInStartTime) / 0.1))

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
            // Complementary to A's hold→drop (holdEnd=0.65):
            // B eases to ~35% during A's hold, then ramps to 100% during A's drop.
            let rampStart = 0.60  // slightly before A drops at 0.65
            if progress < rampStart {
                let p = Float(progress / rampStart)
                let target: Float = 0.35
                let eased = p * p * (3.0 - 2.0 * p)  // smooth S-curve
                return maxVolumeB * (baseLevel + (target - baseLevel) * eased)
            }
            // Ramp: push from 35% to 100%
            let rampP = Float((progress - rampStart) / (1.0 - rampStart))
            let eased = rampP * rampP * (3.0 - 2.0 * rampP)
            return maxVolumeB * (0.35 + 0.65 * eased)

        case .naturalBlend:
            // Complementary to A's hold→drop (holdEnd=0.60):
            // B stays low during hold, then sin² ramp during drop.
            let rampStart = 0.55
            if progress < rampStart {
                let p = Float(progress / rampStart)
                let target: Float = 0.35
                let eased = p * p * (3.0 - 2.0 * p)
                return maxVolumeB * (baseLevel + (target - baseLevel) * eased)
            }
            let rampP = Float((progress - rampStart) / (1.0 - rampStart))
            let angle = rampP * .pi / 2.0
            let sinSq = sinf(angle) * sinf(angle)
            return maxVolumeB * (0.35 + 0.65 * sinSq)

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

        case .crossfade:
            // Complementary to A's hold→drop (holdEnd=0.60):
            // Ease to ~30% during hold, then push to 100%.
            let rampStart = 0.55
            if progress < rampStart {
                let p = Float(progress / rampStart)
                let target: Float = 0.30
                let eased = p * p * (3.0 - 2.0 * p)
                return maxVolumeB * (baseLevel + (target - baseLevel) * eased)
            }
            let rampP = Float((progress - rampStart) / (1.0 - rampStart))
            let eased = rampP * rampP * (3.0 - 2.0 * rampP)
            return maxVolumeB * (0.30 + 0.70 * eased)
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

        if t - lastLogTime >= 1.0 {
            lastLogTime = t
            let elapsed = t - timings.startTime
            let vol = getMasterVolume?() ?? 1.0
            let freqA = eqA.bands[0].frequency
            let freqB = eqB.bands[0].frequency
            print("[CrossfadeExecutor] t+\(String(format: "%.1f", elapsed))s | A: vol=\(String(format: "%.3f", gA * vol)) hp=\(String(format: "%.0f", freqA))Hz | B: vol=\(String(format: "%.3f", gB * vol)) hp=\(String(format: "%.0f", freqB))Hz | master=\(String(format: "%.2f", vol))")
        }
    }

    // MARK: - Filter A automation (port exacto de AudioEffectsChain.ts líneas 209-224)

    private func applyFiltersA(at t: Double) {
        guard t >= timings.filterStartTime else { return }

        // ── Filter pivot aligned with hold→drop ──
        // During A's "hold" phase (~first 60%), filters are gentle (A sounds mostly natural).
        // During A's "drop" phase (~last 40%), filters ramp aggressively (A thins out and vanishes).
        // This matches the volume curve: hold at 85% → exponential drop at 60-65%.
        let totalFilterDur = timings.transitionEndTime - timings.filterStartTime
        guard totalFilterDur > 0 else { return }

        // Pivot = where filters shift from gentle to aggressive (aligned with volume drop)
        let pivotTime = timings.filterStartTime + totalFilterDur * 0.60

        // ── Lowpass sweep (energy-down) OR highpass (normal) ──
        if useLowpassA, let lpA = preset.lowpassA {
            // Lowpass sweep: 20kHz → 800Hz — song "goes dark"
            // Use hold→drop aligned: gentle to midpoint during hold, aggressive during drop
            if t < pivotTime {
                let p = Float((t - timings.filterStartTime) / (pivotTime - timings.filterStartTime))
                let midFreq = lpA.startFreq * 0.7 + lpA.endFreq * 0.3  // ~30% of sweep during hold
                eqA.bands[0].frequency = expInterp(lpA.startFreq, midFreq, min(1, p))
            } else {
                let p = Float((t - pivotTime) / (timings.transitionEndTime - pivotTime))
                let midFreq = lpA.startFreq * 0.7 + lpA.endFreq * 0.3
                eqA.bands[0].frequency = expInterp(midFreq, lpA.endFreq, min(1, p))
            }
        } else {
            let bandA = eqA.bands[0]
            // Hold phase: gentle sweep startFreq → midFreq (~60% of time, ~30% of sweep)
            // Drop phase: aggressive sweep midFreq → endFreq (~40% of time, ~70% of sweep)
            if t < pivotTime {
                let dur = pivotTime - timings.filterStartTime
                let p = Float((t - timings.filterStartTime) / dur)
                bandA.frequency = expInterp(preset.highpassA.startFreq, preset.highpassA.midFreq, min(1, p))
            } else {
                let dur = timings.transitionEndTime - pivotTime
                let p = Float((t - pivotTime) / dur)
                bandA.frequency = expInterp(preset.highpassA.midFreq, preset.highpassA.endFreq, min(1, p))
            }
        }

        // ── Mid scoop on A: hold→drop aligned ──
        // Gentle during hold (reach ~40% of target), aggressive during drop.
        if useMidScoop, let ms = preset.midScoopA {
            if t < pivotTime {
                let p = Float((t - timings.filterStartTime) / (pivotTime - timings.filterStartTime))
                let holdTarget = ms.startGain + (ms.endGain - ms.startGain) * 0.35
                eqA.bands[2].gain = linInterp(ms.startGain, holdTarget, min(1, p))
            } else {
                let p = Float((t - pivotTime) / (timings.transitionEndTime - pivotTime))
                let holdTarget = ms.startGain + (ms.endGain - ms.startGain) * 0.35
                eqA.bands[2].gain = linInterp(holdTarget, ms.endGain, min(1, p))
            }
        }

        // ── High-shelf cut on A: hold→drop aligned ──
        if useHighShelfCut, let hs = preset.highShelfA {
            if t < pivotTime {
                let p = Float((t - timings.filterStartTime) / (pivotTime - timings.filterStartTime))
                let holdTarget = hs.startGain + (hs.endGain - hs.startGain) * 0.30
                eqA.bands[3].gain = linInterp(hs.startGain, holdTarget, min(1, p))
            } else {
                let p = Float((t - pivotTime) / (timings.transitionEndTime - pivotTime))
                let holdTarget = hs.startGain + (hs.endGain - hs.startGain) * 0.30
                eqA.bands[3].gain = linInterp(holdTarget, hs.endGain, min(1, p))
            }
        }

        // ── Bass swap: lowshelf on A — beat-aligned coordinated bass cut ──
        // Bass swaps on the nearest downbeat to ~45% of the crossfade (bassSwapTime)
        // instead of a linear midpoint, so the kick drum handoff happens on a beat.
        if useBassManagement, let lsA = preset.lowshelfA {
            let filterDur = timings.transitionEndTime - timings.filterStartTime
            guard filterDur > 0 else { return }

            // Scale target gains by danceability — high danceability preserves more bass
            let scaledMidGain = lsA.midGain * danceabilityBassScale
            let scaledEndGain = lsA.endGain * danceabilityBassScale

            if t < bassSwapTime {
                // Before swap point: ease bass down to midGain
                let preDur = bassSwapTime - timings.filterStartTime
                let preP = preDur > 0 ? Float((t - timings.filterStartTime) / preDur) : 1.0
                eqA.bands[1].gain = linInterp(lsA.startGain, scaledMidGain, preP)
            } else {
                // After swap point: cut bass aggressively to endGain
                let postDur = timings.transitionEndTime - bassSwapTime
                let postP = postDur > 0 ? Float((t - bassSwapTime) / postDur) : 1.0
                eqA.bands[1].gain = linInterp(scaledMidGain, scaledEndGain, postP)
            }
        }
    }

    // MARK: - Filter B automation (port exacto de AudioEffectsChain.ts líneas 332-394)

    private func applyFiltersB(at t: Double) {
        guard !config.skipBFilters else { return }
        let hpB = eqB.bands[0]
        let lsB = eqB.bands[1]

        if config.needsAnticipation {
            // Anticipation: multi-phase sweep with teaser section
            if t < timings.filterStartTime {
                let dur = timings.filterStartTime - timings.anticipationStartTime
                guard dur > 0 else { return }
                let p = Float((t - timings.anticipationStartTime) / dur)
                hpB.frequency = linInterp(preset.highpassB.startFreq, preset.highpassB.midFreq, p)
                lsB.gain = linInterp(preset.lowshelfB.startGain, preset.lowshelfB.midGain, p)
            } else if t < timings.fadeInStartTime {
                let dur = timings.fadeInStartTime - timings.filterStartTime
                guard dur > 0 else { return }
                let p = Float((t - timings.filterStartTime) / dur)
                hpB.frequency = linInterp(preset.highpassB.midFreq, 300, p)
                lsB.gain = linInterp(preset.lowshelfB.midGain, -4, p)
            } else if t < timings.fadeInEndTime {
                let dur = timings.fadeInEndTime - timings.fadeInStartTime
                guard dur > 0 else { return }
                let p = Float((t - timings.fadeInStartTime) / dur)
                hpB.frequency = linInterp(300, preset.highpassB.endFreq, p)
                lsB.gain = linInterp(-4, preset.lowshelfB.endGain, p)
            } else {
                hpB.frequency = preset.highpassB.endFreq
                lsB.gain = preset.lowshelfB.endGain
            }
        } else {
            // Standard: highpass sweep + bass ramp during fade-in
            guard t >= timings.fadeInStartTime else { return }
            let dur = timings.fadeInEndTime - timings.fadeInStartTime
            guard dur > 0 else { return }
            let p = Float(min(1, (t - timings.fadeInStartTime) / dur))
            hpB.frequency = linInterp(preset.highpassB.startFreq, preset.highpassB.endFreq, p)
            // Beat-aligned bass ramp when available, otherwise linear
            if useBassManagement {
                let bassDur = bassSwapTime - timings.fadeInStartTime
                let bassP = bassDur > 0 ? Float(min(1, (t - timings.fadeInStartTime) / bassDur)) : 1.0
                lsB.gain = linInterp(preset.lowshelfB.startGain, preset.lowshelfB.endGain, bassP)
            } else {
                lsB.gain = linInterp(preset.lowshelfB.startGain, preset.lowshelfB.endGain, p)
            }
        }
    }

    // MARK: - Completion

    private func completeCrossfade() {
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

        // Reset crossfade EQ (bands 0-3) to neutral — bypass alone can be unreliable
        // in CoreAudio, so we also reset parameters to ensure no residual filtering.
        resetCrossfadeBands(eqA)
        resetCrossfadeBands(eqB)

        // Reset stereo pan — both players back to center
        mixerA.pan = 0
        mixerB.pan = 0

        // Reset time-stretch rates — B continues at normal speed after crossfade
        resetTimeStretch()

        // Backstop: serialize a final reset on automationQueue after any stale filterTick.
        // completeCrossfade can be called from main queue (checkAndForceCompleteIfStale)
        // where the same race with in-flight filterTick applies.
        let eqA = self.eqA, eqB = self.eqB
        let mA = self.mixerA, mB = self.mixerB
        let tpA = self.timePitchA, tpB = self.timePitchB
        Self.automationQueue.asyncAfter(deadline: .now() + 0.15) {
            Self.resetBandsStatic(eqA)
            Self.resetBandsStatic(eqB)
            mA.pan = 0
            mB.pan = 0
            tpA?.rate = 1.0
            tpB?.rate = 1.0
        }

        let vol = getMasterVolume?() ?? 1.0
        engine.mainMixerNode.outputVolume = vol

        print("[CrossfadeExecutor] Crossfade completado — B vol=\(String(format: "%.3f", maxVolumeB)) master=\(String(format: "%.2f", vol))")

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
