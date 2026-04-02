import AVFoundation
import QuartzCore

/// Ejecuta crossfades con precisión sample-accurate para volumen (installTap)
/// y ~60Hz para filtros EQ (DispatchSourceTimer, funciona en background).
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

    // MARK: - Estado

    let config: Config
    let timings: Timings
    let preset: FilterPreset
    let maxVolumeA: Float
    let maxVolumeB: Float

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
          ReplayGain A: \(String(format: "%.3f", maxVolumeA)) | B: \(String(format: "%.3f", maxVolumeB))
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
        // Poner mixerA a unity ANTES de instalar taps. El tap ya incluye
        // maxVolumeA (ReplayGain) en gainForPlayerA(). Sin esto, el mixer
        // aplica RG una vez y el tap otra → volumen doble (rg²) que baja
        // de golpe al empezar el crossfade.
        mixerA.outputVolume = 1.0

        // Configurar EQ inicial
        setupInitialEQ()

        // Programar playerB
        schedulePlayerB()

        // Instalar taps de gain (sample-accurate)
        installGainTaps()

        // Iniciar DispatchSourceTimer para filtros (~60Hz) — funciona en background
        startFilterAutomation()
    }

    func cancel() {
        isCancelled = true
        filterTimer?.cancel()
        filterTimer = nil
        removeTaps()
        playerB.stop()
        // Restaurar mixer A a su volumen normal
        mixerA.outputVolume = maxVolumeA
        mixerB.outputVolume = 0
    }

    // MARK: - Setup

    private func setupInitialEQ() {
        // Activar EQ bands
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

        // Silenciar mixerB inicialmente — el tap controlará el gain per-sample
        mixerB.outputVolume = 1.0

        playerB.scheduleSegment(nextFile, startingFrame: startFrame, frameCount: framesToPlay, at: nil)
        playerB.play()
    }

    // MARK: - Gain Taps (sample-accurate volume automation)

    private func installGainTaps() {
        let bufferSize: AVAudioFrameCount = 512

        // Tap en mixerA (outgoing)
        let formatA = mixerA.outputFormat(forBus: 0)
        if formatA.sampleRate > 0 && formatA.channelCount > 0 {
            mixerA.installTap(onBus: 0, bufferSize: bufferSize, format: formatA) {
                [weak self] buffer, _ in
                guard let self = self, !self.isCancelled else { return }
                self.applyGainToBuffer(buffer, isPlayerA: true)

                // Verificar finalización desde el render thread (funciona en background)
                let t = CACurrentMediaTime()
                if t >= self.timings.transitionEndTime + 0.3 {
                    self.completeFromRenderThread()
                }
            }
        }

        // Tap en mixerB (incoming)
        let formatB = mixerB.outputFormat(forBus: 0)
        if formatB.sampleRate > 0 && formatB.channelCount > 0 {
            mixerB.installTap(onBus: 0, bufferSize: bufferSize, format: formatB) {
                [weak self] buffer, _ in
                guard let self = self, !self.isCancelled else { return }
                self.applyGainToBuffer(buffer, isPlayerA: false)
            }
        }
    }

    private func applyGainToBuffer(_ buffer: AVAudioPCMBuffer, isPlayerA: Bool) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let sampleRate = buffer.format.sampleRate
        let now = CACurrentMediaTime()

        for ch in 0..<channels {
            guard let samples = buffer.floatChannelData?[ch] else { continue }
            for i in 0..<frames {
                let sampleTime = now + Double(i) / sampleRate
                let gain: Float
                if isPlayerA {
                    gain = gainForPlayerA(at: sampleTime)
                } else {
                    gain = gainForPlayerB(at: sampleTime)
                }
                samples[i] *= gain
            }
        }
    }

    private func removeTaps() {
        mixerA.removeTap(onBus: 0)
        mixerB.removeTap(onBus: 0)
    }

    // MARK: - Volume curves for A (port exacto de AudioEffectsChain.ts líneas 152-204)

    func gainForPlayerA(at t: Double) -> Float {
        guard t >= timings.volumeFadeStartTime else { return maxVolumeA }
        guard t < timings.transitionEndTime else { return 0 }

        let duration = timings.transitionEndTime - timings.volumeFadeStartTime
        let progress = (t - timings.volumeFadeStartTime) / duration

        switch config.transitionType {
        case .cut, .cutAFadeInB:
            // Mantiene maxVol, corte en últimos 200ms
            let cutStart = max(0, 1.0 - 0.2 / duration)
            if progress < cutStart { return maxVolumeA }
            let cutP = Float((progress - cutStart) / (1.0 - cutStart))
            return maxVolumeA * powf(0.0001 / maxVolumeA, cutP)

        case .eqMix:
            // Exponencial a 70% midpoint, luego exponencial a 0
            if progress < 0.5 {
                let p = Float(progress * 2)
                return maxVolumeA * powf(maxVolumeA * 0.7 / maxVolumeA, p)
            }
            let remaining = Float((progress - 0.5) / 0.5)
            return maxVolumeA * 0.7 * powf(0.0001 / (maxVolumeA * 0.7), remaining)

        case .beatMatchBlend:
            // 80% durante 80% del tiempo, luego drop rápido
            if progress < 0.8 {
                let p = Float(progress / 0.8)
                return maxVolumeA * powf(maxVolumeA * 0.8 / maxVolumeA, p)
            }
            let drop = Float((progress - 0.8) / 0.2)
            return maxVolumeA * 0.8 * powf(0.0001 / (maxVolumeA * 0.8), drop)

        case .naturalBlend:
            // Lineal a 90% midpoint, luego lineal a 0
            if progress < 0.5 {
                let p = Float(progress / 0.5)
                return maxVolumeA * (1.0 - 0.1 * p)
            }
            let remaining = Float((progress - 0.5) / 0.5)
            return max(0.0001, maxVolumeA * 0.9 * (1.0 - remaining))

        case .crossfade, .fadeOutACutB:
            // Clásico: exponencial
            return maxVolumeA * powf(0.0001 / maxVolumeA, Float(progress))
        }
    }

    // MARK: - Volume curves for B (port exacto de AudioEffectsChain.ts líneas 308-394)

    func gainForPlayerB(at t: Double) -> Float {
        // CON ANTICIPACIÓN
        if config.needsAnticipation {
            if t < timings.anticipationStartTime {
                return 0
            } else if t < timings.filterStartTime {
                let dur = timings.filterStartTime - timings.anticipationStartTime
                guard dur > 0 else { return 0 }
                let p = Float((t - timings.anticipationStartTime) / dur)
                return maxVolumeB * 0.30 * max(0, p)              // 0→30%
            } else if t < timings.fadeInStartTime {
                let dur = timings.fadeInStartTime - timings.filterStartTime
                guard dur > 0 else { return maxVolumeB * 0.30 }
                let p = Float((t - timings.filterStartTime) / dur)
                return maxVolumeB * (0.30 + 0.20 * p)             // 30→50%
            } else if t < timings.fadeInEndTime {
                let dur = timings.fadeInEndTime - timings.fadeInStartTime
                guard dur > 0 else { return maxVolumeB * 0.50 }
                let p = Float((t - timings.fadeInStartTime) / dur)
                return maxVolumeB * (0.50 + 0.50 * p)             // 50→100%
            }
            return maxVolumeB
        }

        // SIN ANTICIPACIÓN
        guard t >= timings.fadeInStartTime else { return 0 }
        let fadeInDuration = timings.fadeInEndTime - timings.fadeInStartTime
        guard fadeInDuration > 0 else { return maxVolumeB }
        let progress = min(1.0, (t - timings.fadeInStartTime) / fadeInDuration)

        switch config.transitionType {
        case .fadeOutACutB, .cut:
            // 100ms ramp
            return maxVolumeB * Float(min(1.0, (t - timings.fadeInStartTime) / 0.1))

        case .eqMix, .beatMatchBlend:
            // 30% del tiempo a full
            return maxVolumeB * Float(min(1.0, progress / 0.3))

        case .naturalBlend:
            if progress < 0.4 {
                return maxVolumeB * 0.8 * Float(progress / 0.4)
            }
            return maxVolumeB * Float(0.8 + 0.2 * (progress - 0.4) / 0.6)

        case .crossfade, .cutAFadeInB:
            // Lineal completo
            return maxVolumeB * Float(progress)
        }
    }

    // MARK: - Filter automation via DispatchSourceTimer (background-safe, ~60Hz)

    private func startFilterAutomation() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // ~60Hz = 16.67ms intervalo
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

        // Verificar finalización (backup — el render thread tap también lo verifica)
        if t >= timings.transitionEndTime + 0.5 {
            completeCrossfade()
            return
        }

        // Filtros A (highpass que sube — quita graves)
        if config.useFilters {
            applyFiltersA(at: t)
        }

        // Filtros B (highpass que baja + lowshelf que sube — trae graves)
        if config.useFilters || config.needsAnticipation {
            applyFiltersB(at: t)
        }

        // Log periódico cada ~1s
        if t - lastLogTime >= 1.0 {
            lastLogTime = t
            let elapsed = t - timings.startTime
            let gA = gainForPlayerA(at: t)
            let gB = gainForPlayerB(at: t)
            let freqA = eqA.bands[0].frequency
            let freqB = eqB.bands[0].frequency
            print("[CrossfadeExecutor] t+\(String(format: "%.1f", elapsed))s | A: vol=\(String(format: "%.3f", gA)) hp=\(String(format: "%.0f", freqA))Hz | B: vol=\(String(format: "%.3f", gB)) hp=\(String(format: "%.0f", freqB))Hz")
        }
    }

    // MARK: - Filter A automation (port exacto de AudioEffectsChain.ts líneas 209-224)

    private func applyFiltersA(at t: Double) {
        guard t >= timings.filterStartTime else { return }
        let bandA = eqA.bands[0]

        if config.transitionType == .eqMix || config.transitionType == .beatMatchBlend {
            // Corte de graves más rápido: midFreq al 30% del tiempo
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
            // Normal: lineal startFreq→midFreq durante filterLead, luego midFreq→endFreq
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
            // 3 fases
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
            // Sin anticipación: lineal durante fade-in
            guard t >= timings.fadeInStartTime else { return }
            let dur = timings.fadeInEndTime - timings.fadeInStartTime
            guard dur > 0 else { return }
            let p = Float(min(1, (t - timings.fadeInStartTime) / dur))
            hpB.frequency = linInterp(preset.highpassB.startFreq, preset.highpassB.endFreq, p)
            lsB.gain = linInterp(preset.lowshelfB.startGain, preset.lowshelfB.endGain, p)
        }
    }

    // MARK: - Completion

    /// Llamado desde el render thread (installTap) — dispatch al main thread de forma segura
    private func completeFromRenderThread() {
        guard !isCancelled else { return }
        DispatchQueue.main.async { [weak self] in
            self?.completeCrossfade()
        }
    }

    private func completeCrossfade() {
        guard !isCancelled else { return }
        isCancelled = true // Prevent re-entry

        filterTimer?.cancel()
        filterTimer = nil

        // Poner los mixers en su volumen final ANTES de quitar los taps.
        // Sin esto, al quitar el tap de mixerB (que tenía outputVolume=1.0),
        // B pasa de maxVolumeB (tap) a 1.0 (sin tap) → spike de volumen
        // hasta que onComplete (async, siguiente run loop) corrige el valor.
        mixerA.outputVolume = 0            // A ya está silenciado, a punto de pararse
        mixerB.outputVolume = maxVolumeB   // B continúa con su ReplayGain

        removeTaps()

        print("[CrossfadeExecutor] Crossfade completado")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onComplete?(self.timings.startOffset)
        }
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
