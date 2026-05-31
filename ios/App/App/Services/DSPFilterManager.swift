// DSPFilterManager.swift
// Audiorr — v14.01 scaffold inerte del subsistema de filtros DSP.
//
// Esta clase es el punto único de aplicación de coeficientes biquad durante
// una transición a partir de v14.10. En v14.01 nadie la instancia ni la
// invoca: `applyFiltersA(at:)` y `applyFiltersB(at:)` de CrossfadeExecutor
// siguen siendo el ejecutor real. Cada commit v14.0x posterior migra una
// banda al manager y elimina la rama legacy correspondiente en el mismo
// commit (invariante R-C, sec 2.10 del diseño).
//
// Diseño completo: D:\Audiorr-shared\issues\2026-05-15-dsp-filter-manager-design.md

import Foundation

final class DSPFilterManager {

    // MARK: - Tipos auxiliares (API estable desde v14.01)

    enum FilterID: String {
        case highpassA
        case bassA          // lowshelf A
        case midScoopA
        case highShelfA
        case dynamicQA
        case highpassB
        case bassB          // lowshelf B
        case notchSweepB
        case dynamicQB
    }

    /// Señales perceptuales y estructurales que los gates de activación
    /// pueden consultar para decidir soft-disable de cada banda.
    struct PerceptualState {
        let rmsTailCurveA_last: Double?
        let outroEnergyA: Double?
        let bImmediateImpact: Bool
        let bIntroBars: Int
        let isOutroInstrumental: Bool
        let isIntroInstrumental: Bool
    }

    /// Snapshot inmutable de qué decidió el manager para esta transición.
    /// Se serializa en TransitionDiagnostics (campos F4 extendidos en v14.02+).
    struct FilterDecisionSnapshot {
        let bandsActive: [FilterID]
        let bandsSoftDisabled: [FilterID: String]   // id → gate que falló
        let presetName: String
    }

    // MARK: - Referencias

    private let dspA: BiquadDSPNode
    private let dspB: BiquadDSPNode
    private let config: CrossfadeExecutor.Config
    private let timings: CrossfadeExecutor.Timings
    private let preset: CrossfadeExecutor.FilterPreset
    private let perceptualState: PerceptualState

    // MARK: - Inicialización

    init(config: CrossfadeExecutor.Config,
         timings: CrossfadeExecutor.Timings,
         preset: CrossfadeExecutor.FilterPreset,
         dspA: BiquadDSPNode,
         dspB: BiquadDSPNode,
         perceptualState: PerceptualState) {
        self.config = config
        self.timings = timings
        self.preset = preset
        self.dspA = dspA
        self.dspB = dspB
        self.perceptualState = perceptualState
    }

    // MARK: - API pública

    /// Siembra coeficientes iniciales (passthrough explícito en bandas
    /// soft-disabled, `startValue` en activas) antes del primer `tickAt`.
    /// v14.01 inerte; `setupInitialEQ` legacy del executor sigue ejecutando.
    func primeInitialCoefficients() {
        // Inerte en v14.01. La implementación llega cuando v14.02 migra
        // la primera banda (high-shelf A).
    }

    /// Aplica coeficientes a las bandas activas para el instante de
    /// transición `t` (en segundos absolutos del fade). Llamado desde
    /// `filterTick` a ~60 Hz a partir de v14.10. Único punto de entrada
    /// a `dspA.setCoefficients` / `dspB.setCoefficients` cuando el
    /// refactor esté completo.
    func tickAt(_ t: Double) {
        // Inerte en v14.01. `applyFiltersA/B` siguen siendo el ejecutor.
        _ = t
    }

    /// Reset invariante post-transición. Pone todas las bandas a
    /// `neutralValue` (passthrough explícito) y luego deja que el caller
    /// invoque `dspA.reset()` / `dspB.reset()` (delay-line limpia).
    /// Solo se llama desde `completeCrossfade` y `cancel`, mismos puntos
    /// donde hoy ya se ejecuta `dspA.reset()` — preserva lifecycle.
    /// v14.01 inerte.
    func teardown() {
        // Inerte en v14.01. `completeCrossfade` legacy ya hace
        // `dspA.reset()` + `dspB.reset()` sin pasar por aquí.
    }

    /// Snapshot de decisiones del manager para telemetría F4 extendida.
    /// v14.01 devuelve estado vacío; v14.02+ lo puebla por banda con
    /// `softDisabled`, `gateThatFailed`, `startValue`, `endValue`,
    /// `actualValueAtEndOfFade`.
    func diagnosticsSnapshot() -> FilterDecisionSnapshot {
        return FilterDecisionSnapshot(
            bandsActive: [],
            bandsSoftDisabled: [:],
            presetName: "v14.01-scaffold"
        )
    }

    // MARK: - Migrated band logic (R-C: lógica única, sin double-application)

    /// Coeficiente inicial de band 3 (high-shelf A). Usado por
    /// `setupInitialEQ` y por el pre-roll path (Hv5-1) de
    /// `applyFiltersA`. Migrado en v14.02 desde CrossfadeExecutor
    /// — la rama band3 en esos puntos llama a esta función única.
    static func highShelfCoefficientA_initial(
        useHighShelfCut: Bool,
        preset: CrossfadeExecutor.FilterPreset.HighShelfCut?,
        sampleRate: Float
    ) -> BiquadCoefficients {
        guard useHighShelfCut, let hs = preset else { return .passthrough }
        return BiquadCoefficientCalculator.highShelf(
            frequency: hs.frequency, sampleRate: sampleRate, gainDB: hs.startGain
        )
    }

    /// Coeficiente runtime band 3 (high-shelf A) durante el fade.
    /// Implementa pivot + tail-easing 10% hacia 0 dB en el último
    /// frame del fade (curva v13.O.6 "Filtros-A", commit `e2db8a6`).
    /// Migrado en v14.02 desde CrossfadeExecutor `applyFiltersA`.
    /// Invariante swap path preservada: no toca volumen ni rate,
    /// solo el coeficiente del shelf.
    static func highShelfCoefficientA(
        at t: Double,
        useHighShelfCut: Bool,
        preset: CrossfadeExecutor.FilterPreset.HighShelfCut?,
        rampStart: Double,
        rampEnd: Double,
        pivotTime: Double,
        totalFilterDur: Double,
        sampleRate: Float
    ) -> BiquadCoefficients {
        guard useHighShelfCut, let hs = preset else { return .passthrough }

        var hsGain: Float
        let holdTarget = hs.startGain + (hs.endGain - hs.startGain) * 0.30
        if t < pivotTime {
            let denom = pivotTime - rampStart
            let p = Float(denom > 0 ? (t - rampStart) / denom : 1.0)
            hsGain = hs.startGain + (holdTarget - hs.startGain) * min(1, max(0, p))
        } else {
            let denom = rampEnd - pivotTime
            let p = Float(denom > 0 ? (t - pivotTime) / denom : 1.0)
            hsGain = holdTarget + (hs.endGain - holdTarget) * min(1, max(0, p))
        }

        // Tail-easing 10% — el coeficiente vuelve a 0 dB (passthrough)
        // en el último 10% del fade, evitando residual de high-shelf
        // colgado tras `gainForPlayerA → 0`. (v13.O.6, Filtros-A.)
        let tailEaseStart = rampStart + totalFilterDur * 0.90
        if t >= tailEaseStart {
            let tailDur = rampEnd - tailEaseStart
            let tailP = Float(tailDur > 0 ? (t - tailEaseStart) / tailDur : 1.0)
            hsGain = hsGain + (0.0 - hsGain) * min(1, max(0, tailP))
        }

        return BiquadCoefficientCalculator.highShelf(
            frequency: hs.frequency, sampleRate: sampleRate, gainDB: hsGain
        )
    }

    // MARK: - Helpers internos (replicas inline-expandidas de linInterp/expInterp
    // del executor, que son private func de instancia y no son accesibles aquí).

    private static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        let clamped = min(1, max(0, t))
        return a + (b - a) * clamped
    }

    private static func expLerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        let safeA = max(a, 0.001)
        let safeB = max(b, 0.001)
        let clamped = min(1, max(0, t))
        return safeA * powf(safeB / safeA, clamped)
    }

    // MARK: - Band 0 — Highpass A / Lowpass A (energy-down)

    /// Coeficiente inicial de band 0 A. Usado por `setupInitialEQ`.
    /// En transiciones CUT/CUT_A_FADE_IN_B la banda arranca passthrough
    /// (el sweep cut-local se siembra desde `applyFiltersA`). En energy-down
    /// presets usa lowpass; el resto usa highpass.
    /// Migrado en v14.04 desde CrossfadeExecutor.setupInitialEQ.
    static func band0CoefficientA_initial(
        isCutTransition: Bool,
        useLowpassA: Bool,
        highpassPreset: CrossfadeExecutor.FilterPreset.Highpass,
        lowpassPreset: CrossfadeExecutor.FilterPreset.Lowpass?,
        sampleRate: Float
    ) -> (coefficient: BiquadCoefficients, freq: Float) {
        if isCutTransition {
            return (.passthrough, 0)
        }
        if useLowpassA, let lpA = lowpassPreset {
            return (
                BiquadCoefficientCalculator.lowpass(
                    frequency: lpA.startFreq, sampleRate: sampleRate, Q: lpA.q
                ),
                lpA.startFreq
            )
        }
        return (
            BiquadCoefficientCalculator.highpass(
                frequency: highpassPreset.startFreq, sampleRate: sampleRate, Q: highpassPreset.q
            ),
            highpassPreset.startFreq
        )
    }

    /// Coeficiente runtime band 0 A durante el fade.
    /// Implementa sweep log-uniforme (`expInterp`) con pivot en `pivotTime`
    /// y Q dinámica gaussiana opcional centrada en `qProgress=0.55` cuando
    /// el path es highpass. En energy-down (lowpass) la Q queda fija al
    /// valor del preset (sin bell). Devuelve también `freq` y `qValue` para
    /// telemetría (diagFreqA, diagQA).
    /// Migrado en v14.04 desde CrossfadeExecutor.applyFiltersA banda 0.
    static func band0CoefficientA(
        at t: Double,
        transitionType: CrossfadeExecutor.TransitionType,
        useLowpassA: Bool,
        useDynamicQ: Bool,
        highpassPreset: CrossfadeExecutor.FilterPreset.Highpass,
        lowpassPreset: CrossfadeExecutor.FilterPreset.Lowpass?,
        rampStart: Double,
        rampEnd: Double,
        pivotTime: Double,
        totalFilterDur: Double,
        sampleRate: Float
    ) -> (coefficient: BiquadCoefficients, freq: Float, qValue: Float) {
        if useLowpassA, let lpA = lowpassPreset {
            let midFreq = lpA.startFreq * 0.7 + lpA.endFreq * 0.3
            let freq: Float
            if t < pivotTime {
                let denom = pivotTime - rampStart
                let p = Float(denom > 0 ? (t - rampStart) / denom : 1.0)
                freq = expLerp(lpA.startFreq, midFreq, p)
            } else {
                let denom = rampEnd - pivotTime
                let p = Float(denom > 0 ? (t - pivotTime) / denom : 1.0)
                freq = expLerp(midFreq, lpA.endFreq, p)
            }
            return (
                BiquadCoefficientCalculator.lowpass(
                    frequency: freq, sampleRate: sampleRate, Q: lpA.q
                ),
                freq,
                lpA.q
            )
        }

        // Highpass path con Q dinámica gaussiana opcional.
        let freq: Float
        if t < pivotTime {
            let denom = pivotTime - rampStart
            let p = Float(denom > 0 ? (t - rampStart) / denom : 1.0)
            freq = expLerp(highpassPreset.startFreq, highpassPreset.midFreq, p)
        } else {
            let denom = rampEnd - pivotTime
            let p = Float(denom > 0 ? (t - pivotTime) / denom : 1.0)
            freq = expLerp(highpassPreset.midFreq, highpassPreset.endFreq, p)
        }

        let qValue: Float
        if useDynamicQ, totalFilterDur > 0 {
            // Bell gaussiana — center 0.55, width adapta a CUT-local (ventana
            // ~3s) vs full crossfade (~7s+) para evitar "blink" en ventana
            // comprimida. v9.5 audit 2026-05-05.
            let qProgress = Float((t - rampStart) / totalFilterDur)
            let isCutLocalRamp = transitionType == .cut || transitionType == .cutAFadeInB
            let bellCenter: Float = 0.55
            let bellWidth: Float = isCutLocalRamp ? 0.45 : 0.30
            let exponent = -powf((qProgress - bellCenter) / bellWidth, 2) / 2.0
            let bellValue = expf(max(-10, exponent))
            let baseQ = highpassPreset.q
            let peakQ: Float = 3.5
            qValue = min(4.0, baseQ + (peakQ - baseQ) * bellValue)
        } else {
            qValue = highpassPreset.q
        }

        return (
            BiquadCoefficientCalculator.highpass(
                frequency: freq, sampleRate: sampleRate, Q: qValue
            ),
            freq,
            qValue
        )
    }

    // MARK: - Band 1 — Lowshelf A (path normal sin bassKill)

    /// Coeficiente inicial de band 1 A (lowshelf normal, sin bassKill).
    /// Usado por `setupInitialEQ`. La rama bassKill mantiene su lógica
    /// legacy en CrossfadeExecutor hasta v14.05.
    /// Migrado en v14.04 desde CrossfadeExecutor.setupInitialEQ.
    static func band1CoefficientA_initial(
        isCutTransition: Bool,
        useBassManagement: Bool,
        preset: CrossfadeExecutor.FilterPreset.Lowshelf?,
        sampleRate: Float
    ) -> (coefficient: BiquadCoefficients, gain: Float) {
        if isCutTransition {
            return (.passthrough, 0)
        }
        guard useBassManagement, let lsA = preset else {
            return (.passthrough, 0)
        }
        return (
            BiquadCoefficientCalculator.lowShelf(
                frequency: lsA.frequency, sampleRate: sampleRate, gainDB: lsA.startGain
            ),
            lsA.startGain
        )
    }

    /// Profundidad final del bass-swap A cuando `useBassKill=true` (v14.05).
    /// Reemplaza el `killDepth = -60 dB` del legacy v13.O.6, que el director
    /// percibía como "filtros de repente" en transiciones con cola viva.
    /// -16 dB corresponde a la atenuación que sigue marcando el gesto DJ
    /// (-12 dB es perceptible como swap, -18 dB ya degrada los bajos
    /// audibles fuera del shelf), preservando contenido sub-200 Hz suficiente
    /// para que B abra a 0 dB sin pile-up entre progress 0.5-0.85.
    static let bassKillTargetDepth: Float = -16.0

    /// Coeficiente runtime band 1 A cuando `useBassKill=true` (v14.05).
    /// Reemplaza la curva legacy "hold + 100 ms lineal a -60 dB" por una
    /// rampa progresiva 0 → -16 dB sobre TODO el fade (sin gesto seco).
    /// Mantiene la firma del gate DJ pero sin el snap perceptual.
    /// p = (t − rampStart) / (rampEnd − rampStart). Extremos intactos en
    /// ambas curvas: p=0 → 0 dB, p=1 → target (swap path y profundidad final
    /// sin cambios).
    ///
    /// v15.o — `easeOut` selecciona la forma de la curva:
    ///  - `false` (legacy): `gain(p) = sin²(p·π/2) · target`, ease-in-out.
    ///    Se conserva para la rampa bassKill NO extendida (pre-roll normal,
    ///    bass swap puro) que nunca tuvo queja perceptual.
    ///  - `true`: `gain(p) = p^0.65 · target`, ease-out. SOLO para la rampa
    ///    extendida a la anticipación (`bassKillExtendToAnticipation`). La
    ///    sin² concentraba el descenso en p≈0.5 y sobre la ventana larga
    ///    (~10s) se percibía "rápido / no progresivo"; la ease-out reparte el
    ///    gesto desde el primer instante. k=0.65 calibrable en coche.
    static func band1CoefficientA_bassKill(
        at t: Double,
        lsA: CrossfadeExecutor.FilterPreset.Lowshelf,
        rampStart: Double,
        rampEnd: Double,
        sampleRate: Float,
        easeOut: Bool = false
    ) -> (coefficient: BiquadCoefficients, gain: Float) {
        let totalDur = rampEnd - rampStart
        guard totalDur > 0 else {
            return (
                BiquadCoefficientCalculator.lowShelf(
                    frequency: lsA.frequency, sampleRate: sampleRate, gainDB: 0
                ),
                0
            )
        }
        let p = Float(min(1, max(0, (t - rampStart) / totalDur)))
        // v15.o — ease-out p^0.65 (extendida) vs sin² ease-in-out (legacy).
        let shaped: Float
        if easeOut {
            shaped = powf(p, 0.65)
        } else {
            let angle = p * .pi / 2
            shaped = sinf(angle) * sinf(angle)
        }
        let lsGain = shaped * bassKillTargetDepth
        return (
            BiquadCoefficientCalculator.lowShelf(
                frequency: lsA.frequency, sampleRate: sampleRate, gainDB: lsGain
            ),
            lsGain
        )
    }

    // MARK: - Band 1 — Lowshelf B (bassKill path, simétrico a A)

    /// Coeficiente runtime band 1 B cuando `useBassKill=true` (v14.08).
    /// Reemplaza la curva legacy "hold + 100 ms lineal startGain → endGain"
    /// (idéntica en las 2 ramas anticipation/no-anticipation de applyFiltersB)
    /// por una rampa cosSquared que mantiene `startGain` hasta `bassSwapTime`
    /// y abre suavemente a `endGain` sobre el tiempo restante hasta
    /// `fadeInEndTime`. Simétrico al fix bassKill A v14.05 — pero adaptado
    /// al sistema de coordenadas de B (que vive en el fadeInWindow, no en
    /// rampStart/rampEnd del executor).
    ///
    /// p=0 (en `bassSwapTime`) → `startGain` (-8 dB típico, bass de B
    /// filtrado durante la primera mitad del fade). p=1 (en `fadeInEndTime`)
    /// → `endGain` (0 dB típico, bass de B totalmente abierto al cierre).
    /// Sin pile-up porque A está ya en cosSquared 0→-16 dB (v14.05) en la
    /// misma ventana.
    static func band1CoefficientB_bassKill(
        at t: Double,
        lsB: CrossfadeExecutor.FilterPreset.Lowshelf,
        bassSwapTime: Double,
        fadeInEndTime: Double,
        sampleRate: Float
    ) -> (coefficient: BiquadCoefficients, gain: Float) {
        let lsGain: Float
        if t < bassSwapTime {
            lsGain = lsB.startGain
        } else {
            let dur = fadeInEndTime - bassSwapTime
            if dur > 0 {
                let p = Float(min(1, max(0, (t - bassSwapTime) / dur)))
                let angle = p * .pi / 2
                let sinSq = sinf(angle) * sinf(angle)
                lsGain = lsB.startGain + (lsB.endGain - lsB.startGain) * sinSq
            } else {
                lsGain = lsB.endGain
            }
        }
        return (
            BiquadCoefficientCalculator.lowShelf(
                frequency: lsB.frequency, sampleRate: sampleRate, gainDB: lsGain
            ),
            lsGain
        )
    }

    /// Coeficiente runtime band 1 A para el path normal de bass swap
    /// (rama `else` de bassKill). Implementa linInterp con scaling por
    /// danceability en dos segmentos: pre-bassSwapTime y post-bassSwapTime.
    /// Migrado en v14.04 desde CrossfadeExecutor.applyFiltersA banda 1.
    static func band1CoefficientA_normal(
        at t: Double,
        lsA: CrossfadeExecutor.FilterPreset.Lowshelf,
        danceabilityBassScale: Float,
        rampStart: Double,
        rampEnd: Double,
        effectiveBassSwapTime: Double,
        sampleRate: Float
    ) -> (coefficient: BiquadCoefficients, gain: Float) {
        let scaledMidGain = lsA.midGain * danceabilityBassScale
        let scaledEndGain = lsA.endGain * danceabilityBassScale
        let lsGain: Float
        if t < effectiveBassSwapTime {
            let preDur = effectiveBassSwapTime - rampStart
            let preP = Float(preDur > 0 ? (t - rampStart) / preDur : 1.0)
            lsGain = lerp(lsA.startGain, scaledMidGain, preP)
        } else {
            let postDur = rampEnd - effectiveBassSwapTime
            let postP = Float(postDur > 0 ? (t - effectiveBassSwapTime) / postDur : 1.0)
            lsGain = lerp(scaledMidGain, scaledEndGain, postP)
        }
        return (
            BiquadCoefficientCalculator.lowShelf(
                frequency: lsA.frequency, sampleRate: sampleRate, gainDB: lsGain
            ),
            lsGain
        )
    }
}
