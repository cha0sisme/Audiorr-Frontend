import AVFoundation
import QuartzCore
import Foundation

/// Ejecuta crossfades usando mixer.outputVolume para volumen (~60Hz)
/// y EQ bands para filtros (DispatchSourceTimer, funciona en background).
/// Port exacto de AudioEffectsChain.ts + CrossfadeEngine.ts.
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
        struct Lowshelf { let frequency: Float; let startGain: Float; let midGain: Float; let endGain: Float }
        let highpassA: Highpass
        let highpassB: Highpass
        let lowshelfB: Lowshelf
    }

    // MARK: - Presets (port exacto de AudioEffectsChain.ts líneas 20-83)

    static let presetNormal = FilterPreset(
        highpassA: .init(startFreq: 200, midFreq: 4000, endFreq: 8000, q: 0.7),
        highpassB: .init(startFreq: 400, midFreq: 200, endFreq: 60, q: 0.5),
        lowshelfB: .init(frequency: 200, startGain: -8, midGain: -4, endGain: 0)
    )

    static let presetAggressive = FilterPreset(
        highpassA: .init(startFreq: 600, midFreq: 2500, endFreq: 5000, q: 0.7),
        highpassB: .init(startFreq: 800, midFreq: 200, endFreq: 60, q: 0.5),
        lowshelfB: .init(frequency: 200, startGain: -12, midGain: -6, endGain: 0)
    )

    static let presetAnticipation = FilterPreset(
        highpassA: .init(startFreq: 600, midFreq: 2500, endFreq: 5000, q: 0.7),
        highpassB: .init(startFreq: 1200, midFreq: 600, endFreq: 40, q: 0.5),
        lowshelfB: .init(frequency: 200, startGain: -15, midGain: -9, endGain: 0)
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
    let maxVolumeB: Float
    var getMasterVolume: (() -> Float)?

    private let engine: AVAudioEngine
    private let playerA: AVAudioPlayerNode
    private let playerB: AVAudioPlayerNode
    private let eqA: AVAudioUnitEQ
    private let eqB: AVAudioUnitEQ
    private let mixerA: AVAudioMixerNode
    private let mixerB: AVAudioMixerNode
    private let currentFile: AVAudioFile?
    private let nextFile: AVAudioFile

    // DispatchSourceTimer en vez de CADisplayLink — funciona en background
    private var filterTimer: DispatchSourceTimer?
    private var safetyWatchdog: DispatchSourceTimer?
    private var isCancelled = false
    private var lastLogTime: Double = 0

    var onComplete: ((Double) -> Void)?

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
        self.currentFile = currentFile
        self.nextFile = nextFile
        self.maxVolumeA = maxVolumeA
        self.maxVolumeB = maxVolumeB
        self.getMasterVolume = getMasterVolume

        // Seleccionar preset
        if config.needsAnticipation {
            preset = Self.presetAnticipation
        } else if config.useAggressiveFilters {
            preset = Self.presetAggressive
        } else {
            preset = Self.presetNormal
        }

        // Calcular timings (port exacto de CrossfadeEngine.calculateTimings líneas 244-289)
        timings = Self.calculateTimings(config: config)

        // Log
        let filtersDesc = config.useFilters ? (config.useAggressiveFilters ? "AGGRESSIVE" : "normal") : "OFF"
        let anticDesc = config.needsAnticipation ? String(format: "%.1fs", config.anticipationTime) : "OFF"
        print("""
        [CrossfadeExecutor] ═══════════════════════════════════════
          \(config.transitionType.rawValue): "\(currentTitle)" → "\(nextTitle)"
          Entry: \(String(format: "%.2f", config.entryPoint))s | Fade: \(String(format: "%.2f", config.fadeDuration))s
          Filters: \(filtersDesc) | Anticipation: \(anticDesc)
          RG A: \(String(format: "%.3f", maxVolumeA)) | B: \(String(format: "%.3f", maxVolumeB)) | Vol: \(String(format: "%.2f", getMasterVolume()))
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
        let fadeOutDuration = config.fadeDuration * 1.3
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

    // MARK: - Start

    func start() {
        // Keep mixerA at its current replayGain level (set by AudioEngineManager)
        // Keep mainMixerNode at user volume (set by AudioEngineManager)
        // mixerB starts at 0 (set in schedulePlayerB)
        // Volume automation is handled by filterTick() updating mixer.outputVolume at ~60Hz

        setupInitialEQ()

        schedulePlayerB()

        playerB.play()

        startFilterAutomation()

        startSafetyWatchdog()
    }

    func cancel() {
        isCancelled = true
        filterTimer?.cancel()
        filterTimer = nil
        safetyWatchdog?.cancel()
        safetyWatchdog = nil
        playerB.stop()
        mixerA.outputVolume = maxVolumeA
        mixerB.outputVolume = 0
    }

    // MARK: - Setup

    private func setupInitialEQ() {
        if config.useFilters {
            eqA.bands[0].bypass = false
            eqA.bands[0].frequency = preset.highpassA.startFreq
            eqA.bands[0].bandwidth = qToBandwidth(preset.highpassA.q)
        }

        if config.useFilters || config.needsAnticipation {
            eqB.bands[0].bypass = false
            eqB.bands[0].frequency = preset.highpassB.startFreq
            eqB.bands[0].bandwidth = qToBandwidth(preset.highpassB.q)

            eqB.bands[1].bypass = false
            eqB.bands[1].frequency = preset.lowshelfB.frequency
            eqB.bands[1].gain = preset.lowshelfB.startGain
        }

        for i in 2..<6 {
            eqB.bands[i].bypass = eqA.bands[i].bypass
            eqB.bands[i].filterType = eqA.bands[i].filterType
            eqB.bands[i].frequency = eqA.bands[i].frequency
            eqB.bands[i].bandwidth = eqA.bands[i].bandwidth
            eqB.bands[i].gain = eqA.bands[i].gain
        }

        if !config.useFilters && !config.needsAnticipation {
            for i in 0..<2 {
                eqB.bands[i].bypass = eqA.bands[i].bypass
                eqB.bands[i].filterType = eqA.bands[i].filterType
                eqB.bands[i].frequency = eqA.bands[i].frequency
                eqB.bands[i].bandwidth = eqA.bands[i].bandwidth
                eqB.bands[i].gain = eqA.bands[i].gain
            }
        }
    }

    private func schedulePlayerB() {
        let sampleRate = nextFile.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(timings.startOffset * sampleRate)
        let totalFrames = nextFile.length
        let framesToPlay = AVAudioFrameCount(max(0, totalFrames - startFrame))

        guard framesToPlay > 0 else {
            print("[CrossfadeExecutor] No hay frames en B para reproducir")
            return
        }

        mixerB.outputVolume = 0  // B starts silent; filterTick ramps it up

        playerB.scheduleSegment(nextFile, startingFrame: startFrame, frameCount: framesToPlay, at: nil)
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
            if progress < 0.5 {
                let p = Float(progress / 0.5)
                return maxVolumeA * (1.0 - 0.1 * p)
            }
            let remaining = Float((progress - 0.5) / 0.5)
            return max(0.0001, maxVolumeA * 0.9 * (1.0 - remaining))

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
            if progress < 0.4 {
                return maxVolumeB * 0.8 * Float(progress / 0.4)
            }
            return maxVolumeB * Float(0.8 + 0.2 * (progress - 0.4) / 0.6)

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
        if config.useFilters {
            applyFiltersA(at: t)
        }

        if config.useFilters || config.needsAnticipation {
            applyFiltersB(at: t)
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
        let bandA = eqA.bands[0]

        if config.transitionType == .eqMix || config.transitionType == .beatMatchBlend {
            let totalDur = timings.transitionEndTime - timings.filterStartTime
            guard totalDur > 0 else { return }
            let p = (t - timings.filterStartTime) / totalDur
            let quickCut = 0.3
            if p < quickCut {
                bandA.frequency = expInterp(preset.highpassA.startFreq, preset.highpassA.midFreq, Float(p / quickCut))
            } else {
                bandA.frequency = expInterp(preset.highpassA.midFreq, preset.highpassA.endFreq, Float((p - quickCut) / (1.0 - quickCut)))
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
        } else {
            guard t >= timings.fadeInStartTime else { return }
            let dur = timings.fadeInEndTime - timings.fadeInStartTime
            guard dur > 0 else { return }
            let p = Float(min(1, (t - timings.fadeInStartTime) / dur))
            hpB.frequency = linInterp(preset.highpassB.startFreq, preset.highpassB.endFreq, p)
            lsB.gain = linInterp(preset.lowshelfB.startGain, preset.lowshelfB.endGain, p)
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

        mixerA.outputVolume = 0
        mixerB.outputVolume = maxVolumeB

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
