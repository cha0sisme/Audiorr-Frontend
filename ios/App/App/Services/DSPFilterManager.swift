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
        sampleRate: Double
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
        sampleRate: Double
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
}
