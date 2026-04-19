// ╔══════════════════════════════════════════════════════════════════════╗
// ║                                                                      ║
// ║   CrossfadeExecutor — Part of "Velvet Transition" v2.0               ║
// ║                                                                      ║
// ║   Audiorr — Audiophile-grade music player                            ║
// ║   Copyright (c) 2025-2026 cha0sisme (github.com/cha0sisme)          ║
// ║                                                                      ║
// ║   Real-time crossfade execution engine. Drives volume curves,        ║
// ║   EQ automation, beat-aligned bass swap, time-stretch rate ramp,    ║
// ║   and energy compensation at ~60Hz via DispatchSourceTimer.           ║
// ║                                                                      ║
// ╚══════════════════════════════════════════════════════════════════════╝

import AVFoundation
import QuartzCore
import Foundation

/// CrossfadeExecutor — real-time crossfade state machine.
/// Part of the "Velvet Transition" v2.0 engine.
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

        init(entryPoint: Double, fadeDuration: Double, transitionType: TransitionType,
             useFilters: Bool, useAggressiveFilters: Bool, needsAnticipation: Bool,
             anticipationTime: Double, useTimeStretch: Bool = false,
             rateA: Float = 1.0, rateB: Float = 1.0,
             energyA: Double = 0.5, energyB: Double = 0.5,
             beatIntervalA: Double = 0, beatIntervalB: Double = 0,
             downbeatTimesA: [Double] = [], downbeatTimesB: [Double] = []) {
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
        let highpassA: Highpass
        let highpassB: Highpass
        let lowshelfA: Lowshelf?     // Bass swap: atenúa bajos de A coordinado con B
        let lowshelfB: Lowshelf
        let lowpassA: Lowpass?       // Lowpass sweep para energy-down transitions
    }

    // MARK: - Presets (port exacto de AudioEffectsChain.ts líneas 20-83)

    static let presetNormal = FilterPreset(
        highpassA: .init(startFreq: 400, midFreq: 4000, endFreq: 8000, q: 0.7),
        highpassB: .init(startFreq: 400, midFreq: 200, endFreq: 60, q: 0.5),
        lowshelfA: .init(frequency: 200, startGain: 0, midGain: -6, endGain: -14),
        lowshelfB: .init(frequency: 200, startGain: -8, midGain: -4, endGain: 0),
        lowpassA: nil
    )

    static let presetAggressive = FilterPreset(
        highpassA: .init(startFreq: 600, midFreq: 2500, endFreq: 5000, q: 0.7),
        highpassB: .init(startFreq: 800, midFreq: 200, endFreq: 60, q: 0.5),
        lowshelfA: .init(frequency: 200, startGain: 0, midGain: -10, endGain: -18),
        lowshelfB: .init(frequency: 200, startGain: -12, midGain: -6, endGain: 0),
        lowpassA: nil
    )

    static let presetAnticipation = FilterPreset(
        highpassA: .init(startFreq: 600, midFreq: 2500, endFreq: 5000, q: 0.7),
        highpassB: .init(startFreq: 1200, midFreq: 600, endFreq: 40, q: 0.5),
        lowshelfA: .init(frequency: 200, startGain: 0, midGain: -8, endGain: -16),
        lowshelfB: .init(frequency: 200, startGain: -15, midGain: -9, endGain: 0),
        lowpassA: nil
    )

    /// Energy-down preset: uses lowpass sweep on A instead of highpass (song "fades away" darkly)
    static let presetEnergyDown = FilterPreset(
        highpassA: .init(startFreq: 40, midFreq: 40, endFreq: 40, q: 0.7),  // bypassed effectively
        highpassB: .init(startFreq: 400, midFreq: 200, endFreq: 60, q: 0.5),
        lowshelfA: .init(frequency: 200, startGain: 0, midGain: -4, endGain: -10),
        lowshelfB: .init(frequency: 200, startGain: -8, midGain: -4, endGain: 0),
        lowpassA: .init(startFreq: 20000, endFreq: 800, q: 0.7)
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
    private var filterTimer: DispatchSourceTimer?
    private var safetyWatchdog: DispatchSourceTimer?
    private var secondaryWatchdog: DispatchSourceTimer?
    private var isCancelled = false
    private var lastLogTime: Double = 0

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

        // Seleccionar preset
        // Energy-down: if B is significantly less energetic, use lowpass sweep on A
        let isEnergyDown = config.energyB < config.energyA - 0.2 && config.useFilters
        if config.needsAnticipation {
            preset = Self.presetAnticipation
        } else if isEnergyDown {
            preset = Self.presetEnergyDown
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
        let anticDesc = config.needsAnticipation ? String(format: "%.1fs", config.anticipationTime) : "OFF"
        print("""
        [CrossfadeExecutor] ═══════════════════════════════════════
          \(config.transitionType.rawValue): "\(currentTitle)" → "\(nextTitle)"
          Entry: \(String(format: "%.2f", config.entryPoint))s | Fade: \(String(format: "%.2f", config.fadeDuration))s
          Filters: \(filtersDesc) | Anticipation: \(anticDesc)
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

        // FadeOut multiplier varies by transition type:
        // - naturalBlend/crossfade: 1.3x (ambient tail of A adds depth)
        // - eqMix/beatMatchBlend: 1.1x (less tail — cleaner cut of beats)
        // - cut types: 1.0x (no extra tail)
        let fadeOutMultiplier: Double
        switch config.transitionType {
        case .naturalBlend, .crossfade, .fadeOutACutB: fadeOutMultiplier = 1.3
        case .eqMix, .beatMatchBlend:                  fadeOutMultiplier = 1.1
        case .cut, .cutAFadeInB:                       fadeOutMultiplier = 1.0
        }
        let fadeOutDuration = config.fadeDuration * fadeOutMultiplier
        let totalTransition = fadeOutDuration + filterLead

        let anticipationStartTime = now
        let filterStartTime = now + config.anticipationTime
        let volumeFadeStartTime = filterStartTime + filterLead
        let transitionEndTime = filterStartTime + totalTransition
        let totalTime = config.anticipationTime + totalTransition

        let fadeInDelay = fadeOutDuration * 0.1
        let fadeInStartTime = volumeFadeStartTime + fadeInDelay
        let fadeInEndTime = fadeInStartTime + config.fadeDuration

        let startOffset: Double
        if config.needsAnticipation {
            startOffset = max(0, config.entryPoint - config.fadeDuration - config.anticipationTime)
        } else {
            startOffset = max(0, config.entryPoint - config.fadeDuration)
        }

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

        // Target: 40-50% of crossfade (bass swap slightly early sounds more natural)
        let targetTime = fadeStart + fadeDur * 0.45
        let beatInterval = config.beatIntervalB > 0 ? config.beatIntervalB : config.beatIntervalA

        guard beatInterval > 0 else {
            // No beat data — use linear 50%
            return fadeStart + fadeDur * 0.5
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
                // Only consider downbeats within the crossfade window (20%-70% range)
                let minT = fadeStart + fadeDur * 0.2
                let maxT = fadeStart + fadeDur * 0.7
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
        let offsetInFade = fadeDur * 0.45
        let nearestBeat = round(offsetInFade / beatInterval) * beatInterval
        let clampedBeat = max(fadeDur * 0.2, min(fadeDur * 0.7, nearestBeat))
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
        playerB.stop()
        mixerA.outputVolume = maxVolumeA
        mixerB.outputVolume = 0
        // Reset EQ to bypass so cancelled crossfades don't leave filters active
        for i in 0..<min(eqA.bands.count, 2) {
            eqA.bands[i].bypass = true
            eqB.bands[i].bypass = true
        }
        // Reset time-stretch rates
        resetTimeStretch()
    }

    // MARK: - Time-Stretch Setup

    private func setupTimeStretch() {
        guard config.useTimeStretch else { return }
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

    // MARK: - Setup

    /// Whether bass management (lowshelf A + lowshelf B) is active for this crossfade.
    /// Forced ON for BEAT_MATCH_BLEND to prevent kick drum clashing.
    private var useBassManagement: Bool = false
    /// Whether lowpass sweep is active on A (energy-down transitions).
    private var useLowpassA: Bool = false

    /// Beat-aligned bass swap: the wall-clock time at which bass should be fully swapped
    /// (nearest downbeat to ~40-50% of the crossfade). Computed once at init.
    private var bassSwapTime: Double = 0
    /// Whether we have valid beat data for beat-aligned automation.
    private var hasBeatData: Bool = false

    private func setupInitialEQ() {
        // Determine if bass management is needed:
        // - Always for BEAT_MATCH_BLEND (two kicks without bass swap = flamming)
        // - Whenever filters are active and we have a lowshelfA preset
        useBassManagement = (config.useFilters && preset.lowshelfA != nil) ||
            config.transitionType == .beatMatchBlend || config.transitionType == .eqMix
        useLowpassA = preset.lowpassA != nil && config.useFilters

        if config.useFilters {
            // Highpass A
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

        // Lowpass sweep on A for energy-down transitions
        // Reuse band[0] as lowpass instead of highpass when lowpassA is set
        if useLowpassA, let lpA = preset.lowpassA {
            eqA.bands[0].bypass = false
            eqA.bands[0].filterType = .lowPass
            eqA.bands[0].frequency = lpA.startFreq
            eqA.bands[0].bandwidth = qToBandwidth(lpA.q)
        }

        if config.useFilters || config.needsAnticipation {
            eqB.bands[0].bypass = false
            eqB.bands[0].frequency = preset.highpassB.startFreq
            eqB.bands[0].bandwidth = qToBandwidth(preset.highpassB.q)

            eqB.bands[1].bypass = false
            eqB.bands[1].filterType = .lowShelf
            eqB.bands[1].frequency = preset.lowshelfB.frequency
            eqB.bands[1].gain = preset.lowshelfB.startGain
        } else if useBassManagement {
            // Force bass management on B even without general filters
            // (BEAT_MATCH_BLEND without filters still needs bass coordination)
            eqB.bands[1].bypass = false
            eqB.bands[1].filterType = .lowShelf
            eqB.bands[1].frequency = preset.lowshelfB.frequency
            eqB.bands[1].gain = preset.lowshelfB.startGain
        }

        // Copy global EQ (bands 2-5) from A to B
        for i in 2..<6 {
            eqB.bands[i].bypass = eqA.bands[i].bypass
            eqB.bands[i].filterType = eqA.bands[i].filterType
            eqB.bands[i].frequency = eqA.bands[i].frequency
            eqB.bands[i].bandwidth = eqA.bands[i].bandwidth
            eqB.bands[i].gain = eqA.bands[i].gain
        }

        if !config.useFilters && !config.needsAnticipation && !useBassManagement {
            for i in 0..<2 {
                eqB.bands[i].bypass = eqA.bands[i].bypass
                eqB.bands[i].filterType = eqA.bands[i].filterType
                eqB.bands[i].frequency = eqA.bands[i].frequency
                eqB.bands[i].bandwidth = eqA.bands[i].bandwidth
                eqB.bands[i].gain = eqA.bands[i].gain
            }
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
            let cutStart = max(0, 1.0 - 0.2 / duration)
            if progress < cutStart { return maxVolumeA }
            let cutP = Float((progress - cutStart) / (1.0 - cutStart))
            return maxVolumeA * powf(0.0001 / maxVolumeA, cutP)

        case .eqMix:
            if progress < 0.5 {
                let p = Float(progress * 2)
                return maxVolumeA * powf(maxVolumeA * 0.7 / maxVolumeA, p)
            }
            let remaining = Float((progress - 0.5) / 0.5)
            return maxVolumeA * 0.7 * powf(0.0001 / (maxVolumeA * 0.7), remaining)

        case .beatMatchBlend:
            if progress < 0.8 {
                let p = Float(progress / 0.8)
                return maxVolumeA * powf(maxVolumeA * 0.8 / maxVolumeA, p)
            }
            let drop = Float((progress - 0.8) / 0.2)
            return maxVolumeA * 0.8 * powf(0.0001 / (maxVolumeA * 0.8), drop)

        case .naturalBlend:
            // Equal-power crossfade: cos²(π/2 * t) — constant perceived energy
            let angle = Float(progress) * .pi / 2.0
            return maxVolumeA * cosf(angle) * cosf(angle)

        case .crossfade, .fadeOutACutB:
            return maxVolumeA * powf(0.0001 / maxVolumeA, Float(progress))
        }
    }

    // MARK: - Volume curves for B (port exacto de AudioEffectsChain.ts líneas 308-394)

    func gainForPlayerB(at t: Double) -> Float {
        if config.needsAnticipation {
            if t < timings.anticipationStartTime {
                return 0
            } else if t < timings.filterStartTime {
                let dur = timings.filterStartTime - timings.anticipationStartTime
                guard dur > 0 else { return 0 }
                let p = Float((t - timings.anticipationStartTime) / dur)
                return maxVolumeB * 0.30 * max(0, p)
            } else if t < timings.fadeInStartTime {
                let dur = timings.fadeInStartTime - timings.filterStartTime
                guard dur > 0 else { return maxVolumeB * 0.30 }
                let p = Float((t - timings.filterStartTime) / dur)
                return maxVolumeB * (0.30 + 0.20 * p)
            } else if t < timings.fadeInEndTime {
                let dur = timings.fadeInEndTime - timings.fadeInStartTime
                guard dur > 0 else { return maxVolumeB * 0.50 }
                let p = Float((t - timings.fadeInStartTime) / dur)
                return maxVolumeB * (0.50 + 0.50 * p)
            }
            return maxVolumeB
        }

        guard t >= timings.fadeInStartTime else { return 0 }
        let fadeInDuration = timings.fadeInEndTime - timings.fadeInStartTime
        guard fadeInDuration > 0 else { return maxVolumeB }
        let progress = min(1.0, (t - timings.fadeInStartTime) / fadeInDuration)

        switch config.transitionType {
        case .fadeOutACutB, .cut:
            return maxVolumeB * Float(min(1.0, (t - timings.fadeInStartTime) / 0.1))

        case .eqMix, .beatMatchBlend:
            return maxVolumeB * Float(min(1.0, progress / 0.3))

        case .naturalBlend:
            // Equal-power crossfade: sin²(π/2 * t) — mirrors A's cos²
            let angle = Float(progress) * .pi / 2.0
            return maxVolumeB * sinf(angle) * sinf(angle)

        case .crossfade, .cutAFadeInB:
            return maxVolumeB * Float(progress)
        }
    }

    // MARK: - Filter automation via DispatchSourceTimer (background-safe, ~60Hz)

    private func startFilterAutomation() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.filterTick()
        }
        filterTimer = timer
        timer.resume()
    }

    private func filterTick() {
        guard !isCancelled else {
            filterTimer?.cancel()
            filterTimer = nil
            return
        }

        let t = CACurrentMediaTime()

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

        // ── Filter automation ──
        if config.useFilters || useLowpassA || useBassManagement {
            applyFiltersA(at: t)
        }

        if config.useFilters || config.needsAnticipation || useBassManagement {
            applyFiltersB(at: t)
        }

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

        // ── Lowpass sweep (energy-down) OR highpass (normal) ──
        if useLowpassA, let lpA = preset.lowpassA {
            // Lowpass sweep: 20kHz → 800Hz — song "goes dark"
            let dur = timings.transitionEndTime - timings.filterStartTime
            guard dur > 0 else { return }
            let p = Float(min(1, (t - timings.filterStartTime) / dur))
            eqA.bands[0].frequency = expInterp(lpA.startFreq, lpA.endFreq, p)
        } else {
            let bandA = eqA.bands[0]
            if config.transitionType == .eqMix || config.transitionType == .beatMatchBlend {
                let pivotTime = timings.volumeFadeStartTime + (timings.transitionEndTime - timings.volumeFadeStartTime) * 0.3
                if t < pivotTime {
                    let dur = pivotTime - timings.filterStartTime
                    guard dur > 0 else { return }
                    let p = (t - timings.filterStartTime) / dur
                    bandA.frequency = expInterp(preset.highpassA.startFreq, preset.highpassA.midFreq, Float(min(1, p)))
                } else {
                    let dur = timings.transitionEndTime - pivotTime
                    guard dur > 0 else { return }
                    let p = (t - pivotTime) / dur
                    bandA.frequency = expInterp(preset.highpassA.midFreq, preset.highpassA.endFreq, Float(min(1, p)))
                }
            } else {
                if t < timings.volumeFadeStartTime {
                    let dur = timings.volumeFadeStartTime - timings.filterStartTime
                    guard dur > 0 else { return }
                    let p = (t - timings.filterStartTime) / dur
                    bandA.frequency = linInterp(preset.highpassA.startFreq, preset.highpassA.midFreq, Float(p))
                } else {
                    let dur = timings.transitionEndTime - timings.volumeFadeStartTime
                    guard dur > 0 else { return }
                    let p = (t - timings.volumeFadeStartTime) / dur
                    bandA.frequency = linInterp(preset.highpassA.midFreq, preset.highpassA.endFreq, Float(min(1, p)))
                }
            }
        }

        // ── Bass swap: lowshelf on A — beat-aligned coordinated bass cut ──
        // Bass swaps on the nearest downbeat to ~45% of the crossfade (bassSwapTime)
        // instead of a linear midpoint, so the kick drum handoff happens on a beat.
        if useBassManagement, let lsA = preset.lowshelfA {
            let filterDur = timings.transitionEndTime - timings.filterStartTime
            guard filterDur > 0 else { return }

            if t < bassSwapTime {
                // Before swap point: ease bass down to midGain
                let preDur = bassSwapTime - timings.filterStartTime
                let preP = preDur > 0 ? Float((t - timings.filterStartTime) / preDur) : 1.0
                eqA.bands[1].gain = linInterp(lsA.startGain, lsA.midGain, preP)
            } else {
                // After swap point: cut bass aggressively to endGain
                let postDur = timings.transitionEndTime - bassSwapTime
                let postP = postDur > 0 ? Float((t - bassSwapTime) / postDur) : 1.0
                eqA.bands[1].gain = linInterp(lsA.midGain, lsA.endGain, postP)
            }
        }
    }

    // MARK: - Filter B automation (port exacto de AudioEffectsChain.ts líneas 332-394)

    private func applyFiltersB(at t: Double) {
        let hpB = eqB.bands[0]
        let lsB = eqB.bands[1]

        if config.needsAnticipation {
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
        } else if config.useFilters {
            guard t >= timings.fadeInStartTime else { return }
            let dur = timings.fadeInEndTime - timings.fadeInStartTime
            guard dur > 0 else { return }
            let p = Float(min(1, (t - timings.fadeInStartTime) / dur))
            hpB.frequency = linInterp(preset.highpassB.startFreq, preset.highpassB.endFreq, p)
            // Beat-aligned bass ramp: B's bass reaches full at bassSwapTime
            if useBassManagement {
                let bassDur = bassSwapTime - timings.fadeInStartTime
                let bassP = bassDur > 0 ? Float(min(1, (t - timings.fadeInStartTime) / bassDur)) : 1.0
                lsB.gain = linInterp(preset.lowshelfB.startGain, preset.lowshelfB.endGain, bassP)
            } else {
                lsB.gain = linInterp(preset.lowshelfB.startGain, preset.lowshelfB.endGain, p)
            }
        } else if useBassManagement {
            // Bass management only (no general filters) — BEAT_MATCH_BLEND without filters
            // Beat-aligned: B's bass reaches full at bassSwapTime
            guard t >= timings.fadeInStartTime else { return }
            let bassDur = bassSwapTime - timings.fadeInStartTime
            let bassP = bassDur > 0 ? Float(min(1, (t - timings.fadeInStartTime) / bassDur)) : 1.0
            lsB.gain = linInterp(preset.lowshelfB.startGain, preset.lowshelfB.endGain, bassP)
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

        mixerA.outputVolume = 0
        mixerB.outputVolume = maxVolumeB

        // Reset time-stretch rates — B continues at normal speed after crossfade
        resetTimeStretch()

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
        let timer = DispatchSource.makeTimerSource(queue: .main)
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
        let timer = DispatchSource.makeTimerSource(queue: .main)
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
