import Foundation
import UIKit
import AVFoundation

/// Singleton observable que captura el estado de cada crossfade en tiempo real.
/// CrossfadeExecutor publica datos aquí; TransitionDiagnosticsView los muestra.
/// Persiste un log detallado en Documents/transition_diagnostics.log para debugging.
@MainActor @Observable
final class TransitionDiagnostics {

    /// When false, diagnostics data is not collected and detail views are hidden.
    /// The settings section itself is gated by BackendState.isAvailable, but
    /// that's only a UI gate — the static guards in record(...) below run
    /// regardless. Default is true in DEBUG builds (developer convenience —
    /// data starts collecting from app launch) and false in Release builds
    /// (TestFlight / Navidrome-only users have no UI to toggle this and
    /// shouldn't accumulate logs in Documents/transition_diagnostics.log).
    /// SettingsView.onAppear loads the user's saved value from UserDefaults
    /// when backend is available.
    #if DEBUG
    nonisolated(unsafe) static var debugModeEnabled = true
    #else
    nonisolated(unsafe) static var debugModeEnabled = false
    #endif

    /// v12 (audit 2026-05-05) — espejo cacheado de `BackendState.shared.isAvailable`.
    /// Permite que los guards `nonisolated` en publishDecision/publishCompletion/
    /// publishTick chequeen disponibilidad de backend sin cruzar al main actor.
    /// Se actualiza desde `AudiorrApp` observando BackendState. Si el backend pasa
    /// a no-disponible mientras la app esta abierta, los publishers dejan de
    /// recoger datos inmediatamente — no hay "datos zombies" colandose.
    nonisolated(unsafe) static var backendAvailable = false

    /// Helper: solo recogemos diagnosticos cuando AMBAS condiciones son true.
    /// El usuario es explicito: "esa seccion no se activa ni recoge ningun dato
    /// si no hay acceso al backend".
    nonisolated static var collectingEnabled: Bool {
        debugModeEnabled && backendAvailable
    }

    static let shared = TransitionDiagnostics()

    // MARK: - Audit upload coordination (v14.e Alt-3)

    /// Stash con `recordId` discriminador para que el solape entre crossfade
    /// N (Task.detached aún vivo) y crossfade N+1 (skip rápido <750ms
    /// post-swap) no contamine cobertura. Sin discriminador, el delayed
    /// audit del N pisaría el stash justo cuando el waiter del N intenta
    /// leerlo. Caveat duro 1 sec 2.6 review 2.
    private struct StashedAudit: Sendable {
        let recordId: UUID
        let payload: [String: Any]
    }
    private static let auditStashQueue = DispatchQueue(label: "audiorr.audit.stash")
    nonisolated(unsafe) private static var _stashCompleteCrossfade: StashedAudit?
    nonisolated(unsafe) private static var _stashPostSwap: StashedAudit?

    /// Próximo recordId que `publishCompletion` usará. Se asigna al inicio
    /// del crossfade (`CrossfadeExecutor.start()`) para que los audits T+0,
    /// +200ms y post-swap+300ms stashen contra el id correcto antes de que
    /// `publishCompletion` construya el record.
    nonisolated(unsafe) static var upcomingRecordId: UUID = UUID()

    /// Status de la subida del audit. Permite auditar el orden temporal sin
    /// perder señal causal. `failedRaceLost` (caveat duro 8) marca PATCH 404
    /// — POST aún no había commiteado cuando llegó el PATCH. Sin este case,
    /// fallo de orden temporal es invisible (patrón v14.d).
    enum AuditUploadStatus: String, Sendable {
        case pending, postOk, patchOk, postFailed, patchFailed, failedRaceLost
    }
    @MainActor var lastAuditUploadStatus: AuditUploadStatus = .pending

    // Helpers nonisolated: se invocan desde `publishPostResetAudit` (también
    // nonisolated, viene del render/automation thread) y desde Task.detached
    // del POST/PATCH. La sincronización vive en `auditStashQueue.sync`, no
    // necesita el MainActor. Sin `nonisolated`, Xcode Cloud falla con
    // "Main actor-isolated static method cannot be called from outside of
    // the actor" en build estricto (Swift 6 concurrency).
    nonisolated static func stashCompleteCrossfade(recordId: UUID, payload: [String: Any]) {
        auditStashQueue.sync { _stashCompleteCrossfade = StashedAudit(recordId: recordId, payload: payload) }
    }
    nonisolated static func stashPostSwap(recordId: UUID, payload: [String: Any]) {
        auditStashQueue.sync { _stashPostSwap = StashedAudit(recordId: recordId, payload: payload) }
    }
    nonisolated static func consumeCompleteCrossfade(recordId: UUID) -> [String: Any]? {
        auditStashQueue.sync {
            guard let s = _stashCompleteCrossfade, s.recordId == recordId else { return nil }
            _stashCompleteCrossfade = nil
            return s.payload
        }
    }
    nonisolated static func peekPostSwap(recordId: UUID) -> [String: Any]? {
        auditStashQueue.sync {
            guard let s = _stashPostSwap, s.recordId == recordId else { return nil }
            return s.payload
        }
    }
    nonisolated static func consumePostSwap() {
        auditStashQueue.sync { _stashPostSwap = nil }
    }

    /// Serializa los 8 signals del PostResetAudit + source a `[String: Any]`
    /// JSON-friendly. NO incluye bandsA/B, dspBandsA/B, panA/B, rateA/B —
    /// ya están en el record principal o son redundantes para análisis de
    /// divergencia DSP. Slim por diseño.
    nonisolated private static func buildAuditPayload(_ a: PostResetAudit) -> [String: Any] {
        var p: [String: Any] = [
            "source": a.source,
            "stateMagA": a.stateMagA, "stateMagB": a.stateMagB,
            "dspPitchA": a.dspPitchA, "dspPitchB": a.dspPitchB,
            "dspRateA": a.dspRateA, "dspRateB": a.dspRateB,
            "bypassA": a.bypassA, "bypassB": a.bypassB,
        ]
        // v14.g — observabilidad del reset DSP. Aditivos solo cuando hay
        // lectura post-process (call-site `completeCrossfade`). Otras fuentes
        // (cancel, post-swap, +200ms) los dejan nil → omitidos del payload.
        if let v = a.stateMagA_postProcess { p["stateMagA_postProcess"] = v }
        if let v = a.stateMagB_postProcess { p["stateMagB_postProcess"] = v }
        if let v = a.ioBufferDurationMs   { p["ioBufferDurationMs"] = v }
        if let v = a.sleepAppliedMs       { p["sleepAppliedMs"] = v }
        return p
    }

    // MARK: - Transition decision

    var isActive = false
    var transitionType = ""
    var transitionReason = ""
    var currentTitle = ""
    var nextTitle = ""

    // Timing
    var fadeDuration: Double = 0
    var entryPoint: Double = 0
    var startOffset: Double = 0
    var anticipationTime: Double = 0

    // Filters
    var filtersEnabled = false
    var filterPreset = ""       // "normal", "aggressive", "anticipation", "energy-down"
    var useMidScoop = false
    var useHighShelfCut = false
    var useBassKill = false
    var useDynamicQ = false
    /// Phaser Notch Sweep on B band 2 (Sprint 2). True when the narrow parametric
    /// notch with depth bell is active alongside Twin dynQ.
    var useNotchSweep = false
    /// Stutter Cut on A's last 2 beats (Sprint 3). True when the 1/8-note gate is
    /// armed AND the runtime beat-anchor check passed in CrossfadeExecutor init.
    /// (decideDJEffects might say true while the executor bypasses if the cut is
    /// off-grid; this flag reflects the decision-layer intent, not runtime state.)
    var useStutterCut = false
    var skipBFilters = false
    /// Rapid fade-in B (audit v9 2026-05-05). True cuando el decisor detectó
    /// outro instrumental A + impacto inmediato B → curva de B comprime el
    /// fade-in al ramp final firme en vez del crossfade lento. En blendy types
    /// dispara también las "curvas espejo" de A (hold pleno hasta 0.55, cos²
    /// drop después). Sin este log no podiamos auditar si el flag dispara.
    var bRapidFadeIn = false
    /// Tier 4 (audit v10 2026-05-05). True cuando el decisor adelantó el
    /// entryPoint de B al primer kick de su intro instrumental, ANTES del
    /// chorus, para que B acompañe los últimos 6-10 compases de A. Activa la
    /// curva `earlyBlend` en CrossfadeExecutor.
    var tier4Active = false

    // v13.K (audit 2026-05-07) — telemetría perceptual para análisis post-coche.
    // NO modifica comportamiento (read-only diagnostics).
    /// Path por el que `calculateSmartEntryPoint` decidió el entryPoint
    /// (chorus_promotion / vocal_target / entryReference / etc.).
    var entryPointSource: String = "unknown"
    /// Cuando Tier 4 NO disparó, etiqueta del primer gate que cortó.
    /// `nil` cuando Tier 4 disparó con éxito o `kEnableTier4` está off.
    var tier4FailedGate: String? = nil
    /// Pendiente de RMS en los primeros windows de B (slope/segundo).
    /// Computada y persistida aunque Tier 4 falle en gates posteriores.
    var introSlopeB: Double? = nil
    /// Densidad de downbeats por compás en los primeros 20s de B.
    var downbeatDensityB20s: Double? = nil
    /// Cinturón quíntuple chill: true cuando el contexto era chill (energías
    /// bajas + danceability < 0.55 + sin impacto inmediato + espacio vocal/
    /// chorus suficiente). Independiente de si terminó forzando skipBFilters.
    var chillRecipeApplied: Bool = false
    // v13.L/M/N (round 2026-05-09-v13-LMN) — telemetría gates de género.
    /// true cuando v13.N cap=50 chorus_promotion fue aplicado a B (B fuera de
    /// la lista exempt drop-driven). Poblado por v13.N. nil = no aplica
    /// (entryPointSource ≠ chorus_promotion o algoritmo no llegó al gate).
    var genreCapApplied: Bool? = nil
    /// v13.O Commit 2 (round 2026-05-10) — cap defensivo POST-snap+beat-sync.
    /// true = entry final >50s capado a 50 (B no drop-driven). false = entry
    /// >50s pero exempt drop-driven percussive. nil = entry pre-clamp <=50,
    /// no se evaluó. Independiente de `genreCapApplied`.
    var entryFinalCapApplied: Bool? = nil
    /// v13.O Commit 2 (round 2026-05-10) — etiqueta del path de anticipación
    /// nuevo. Solo "outroSlopeSteep" cuando A decae natural (slope < -0.005/s
    /// en últimos 40s) y disparó extra widening. nil para resto de ramas.
    var anticipationReason: String? = nil
    /// Lista plural de géneros de B vista por el algoritmo en el momento del
    /// cálculo. Poblada siempre que el path se ejecute (vía SongAnalysis.genres
    /// que copia de NavidromeSong.genres).
    var bGenres: [String] = []

    // v13.O.6 (round 2026-05-15) — telemetría filtros (F4).
    // Aditiva. Sin impacto en algoritmo. Permite:
    //   1. Validar Filtros-A (tail-easing band 3 A → 0 dB en p=1.0): si
    //      `highShelfGainA_atEnd` queda en 0 cuando antes era -10/-12.
    //   2. Auditar pre-roll Hv5-1 (commit 8df7635): `filterPreRollAppliedA`
    //      true cuando el bloque pre-roll efectivamente disparó.
    //   3. Diseñar el verdadero Fix #3 (filtros B retirada) con `lsGainB_initial`
    //      + `hpFreqB_initial` del preset elegido.
    //   4. Auditar el problema real de la cola de A con `rmsTailCurveA_last`
    //      + `rmsTailSlopeA` (slope tailWindows=4) + `outroEnergyA`.
    /// true cuando el bloque pre-roll de Hv5-1 (CrossfadeExecutor:2088) disparó
    /// efectivamente para esta transición. False cuando se saltó por gate
    /// (CUT family, no-overlap, lowpassA, preRollDur<=0).
    var filterPreRollAppliedA: Bool? = nil
    /// Valor del high-shelf A en el último tick del fade (`progress ≈ 1.0`).
    /// Pre-Filtros-A: -10/-12 dB (endGain del preset). Post-Filtros-A esperado: 0
    /// (passthrough). nil cuando band 3 no aplicó (sin highShelfA o sin
    /// useHighShelfCut).
    var highShelfGainA_atEnd: Double? = nil
    /// `preset.lowshelfB.startGain` del preset que se usó en esta transición.
    /// Permite reconstruir qué tan agresivo era el shelf de B desde el inicio.
    var lsGainB_initial: Double? = nil
    /// `preset.highpassB.startFreq` del preset que se usó en esta transición.
    var hpFreqB_initial: Double? = nil
    /// Último valor de `currentAnalysis.rmsTailCurve` (último window). Útil para
    /// analizar el problema real de Fix #3 (filtros B retirada) con dato crudo.
    var rmsTailCurveA_last: Double? = nil
    /// Slope de `rmsTailCurve` con `tailWindows=4` (último ~16s). Pendiente
    /// negativa significativa = decay natural. Para diseñar gates de filtros con
    /// datos reales en próximo round.
    var rmsTailSlopeA: Double? = nil
    /// Energía outro de A computada en `calculateCrossfadeConfig` (era variable
    /// local). Expone el valor real para correlar con queja "filtros marchosos
    /// en outro instrumental tranquilo".
    var outroEnergyA: Double? = nil

    // v14.12 (round 2026-05-15) — telemetría bassKill A. Aditiva. Permite
    // reconstruir la curva cosSquared real de v14.05+v14.11 muestreada en 3
    // puntos clave del fade, sin necesidad de instrumentar el tick. Si la
    // curva esperada (0 → ~−0.8 dB → −16 dB) no se cumple, hay bug en
    // band1CoefficientA_bassKill o en el cableado de rampStart.
    /// Gain (dB) del bassKill A evaluado en t=rampStart. Esperado ≈ 0.0 con la
    /// cosSquared. Diverge si hay step inicial en la fórmula.
    var bassKillGainA_atRampStart: Double? = nil
    /// Gain (dB) en t=volumeFadeStartTime. Mide cuánto bajó el bass durante el
    /// filterLead (la "ventana de adelanto"). Audita si v14.11 realmente
    /// adelantó la entrada del filtro (esperado ≈ −0.5 a −2.0 dB; si ≈ 0.0
    /// el pre-roll no está enganchando).
    var bassKillGainA_atVolumeFadeStart: Double? = nil
    /// Gain (dB) en t=transitionEndTime − 0.05. Esperado ≈ −16.0 (target
    /// `bassKillTargetDepth`). Diverge si rampEnd no llega a p=1.0.
    var bassKillGainA_atSwap: Double? = nil
    /// Distinto de `filterPreRollAppliedA` (gate estático). Este se marca true
    /// SOLO si el branch pre-roll de `applyFiltersA` se ejecuta al menos una
    /// vez en runtime — detecta el caso edge en que el gate dice "habilitado"
    /// pero el primer tick de filterTimer cayó después de filterStartTime.
    var filterPreRollEffectiveA: Bool? = nil

    // v14.c V1.B — telemetría peak-detector del fade-in entrada del fix V1.A.
    // Capturada por completeCrossfade ANTES de llamar a dspA.reset() / dspB.reset()
    // (el reset limpia los counters del kernel). 4 campos aditivos:
    /// True si la cadena A disparó el fade-in suavizado pasthrough→activo al
    /// menos una vez en este crossfade. False si quedó en passthrough todo el
    /// tiempo (caso CUT family). nil si el kernel no estaba disponible.
    var fadeInTriggeredA: Bool? = nil
    /// True/False/nil simétrico al anterior para la cadena B.
    var fadeInTriggeredB: Bool? = nil
    /// Peak |sample[i]−sample[i−1]| capturado en los 4096 frames post-fade-in
    /// del kernel A. Pre-V1.A: ≥0.3 indica click discreto. Post-V1.A: <0.05
    /// indica que el suavizado eliminó el step. Métrica objetiva del fix.
    var peakTransientDeltaA: Double? = nil
    /// Idem para la cadena B. Usualmente menor porque B arranca con
    /// mixerB.outputVolume=0 (audio inerte durante el fade-in).
    var peakTransientDeltaB: Double? = nil

    /// v14.d V1' — `‖coefficients − passthrough‖₂` del kernel B leído justo
    /// antes de plantar los coefs nuevos en `setupInitialEQ`. Prueba empírica
    /// de la hipótesis raíz V1': si los coefs del kernel B quedaron colgados
    /// intermedios desde el fade-out del swap anterior (player parado, render
    /// thread sin drenar), valor ≥ ~0.5. Tras `resetSync()` post-swap, el
    /// valor debe colapsar a ≈ 0. Si tras V1' este campo no baja → hipótesis
    /// raíz falsa, click viene de otro path (scheduleSegment, encoder AAC).
    var coefMagB_atSetup: Double? = nil

    // v14.d V2' — telemetría inerte para calibrar decisor adaptativo de
    // `lsGainB_initial`. NO modifica audio en v14.d; permite que el
    // log-analyst sobre el coche-test rated reconstruya offline qué casos
    // cumplirían el predicado del decisor (y con qué threshold real). El
    // decisor se activará en v14.e con esta munición.
    /// Bass prominencia de B en sus primeros 15s (ventana corregida vs el
    /// `[3..5]` que el dj-engineer propuso en el diseño v14.d, mismatch
    /// temporal cazado por devils-advocate). Media de `percussiveCurve[0..2]`
    /// (3 samples de 5s cada uno) cuando hay ≥3 muestras; nil si la curva
    /// no está disponible o tiene <3 muestras. Proxy del bajo prominente
    /// que el catálogo Hip-Hop a 86-161 BPM tendría como queja "mala gestión"
    /// cuando `lsGainB_initial=-12` corta demasiado.
    var bassProminenceB_0_15s: Double? = nil
    /// Código del enum `TransitionProfile.vocalOverlapRisk` capturado en el
    /// momento del cálculo de la transición. Valores: "none", "aOnly",
    /// "bOnly", "both". Cinturón propuesto para el decisor V2': relajar
    /// `lsGainB` solo cuando el riesgo de overlap vocal NO sea `both` ni
    /// `aOnly` (donde sí hace falta proteger A del bajo de B).
    var vocalOverlapRiskCode: String? = nil
    /// `nextAnalysis.energyIntro` capturado al construir la config. Solo
    /// cuando `hasEnergyProfile=true` (señal real del backend); nil cuando
    /// cae al default 0.5 (signal ausente). Fallback del decisor V2' cuando
    /// `percussiveCurve` no esté disponible (~99.7% cobertura).
    var energyIntroB_telemetry: Double? = nil

    // v14.g g2 (round 2026-05-17) — valores absolutos de `nextAnalysis` para
    // calcular offsets post-hoc en log-analyst (chorus/vocal/introEnd respecto
    // al entryPoint final). Aditivos, sin impacto en algoritmo. Munición para
    // diseño de gates Frente #2 (entry-point cap=50s) y Frente #3 (fade-in B
    // exagerado) del research v14.g. NULL cuando el backend no proveyó el
    // dato o cuando el valor literal es 0 (caso indistinguible del "no
    // detectado", aplicamos nil para no contaminar análisis).
    /// `nextAnalysis.chorusStartTime` (segundos absolutos desde t=0 de B).
    /// nil cuando el backend no proveyó o cuando es 0 literal.
    var chorusStartTimeB: Double? = nil
    /// Primeros 6 elementos de `nextAnalysis.downbeatTimes` (segundos absolutos
    /// desde t=0 de B). nil cuando la lista está vacía. Truncado a 6 para
    /// acotar peso del payload — suficiente para localizar 1-2 compases tras
    /// el entryPoint en cualquier BPM razonable.
    var downbeatTimesB: [Double]? = nil
    /// `nextAnalysis.vocalStartTime` (segundos absolutos desde t=0 de B).
    /// nil cuando el backend no proveyó (campo Optional en SongAnalysis) o
    /// cuando es 0 literal (apertura cantada vs ausencia de dato — el
    /// log-analyst resuelve la ambigüedad cruzando con `hasIntroVocalsB`).
    var vocalStartTimeB: Double? = nil
    /// `nextAnalysis.introEndTimeHeuristic ?? introEndTime` (segundos absolutos
    /// desde t=0 de B). nil cuando ambos son 0. Prioriza heurística sobre ML
    /// override (paridad con Hv5-2 backend signals que ya viajaban de forma
    /// dispersa).
    var introEndHeuristicB: Double? = nil

    // Analysis
    var energyA: Double = 0
    var energyB: Double = 0
    var isOutroInstrumental = false
    var isIntroInstrumental = false
    var danceability: Double = 0

    // Song B analysis details (for entry point debugging)
    var introEndB: Double = 0
    var vocalStartB: Double = 0
    var chorusStartB: Double = 0
    var outroStartA: Double = 0
    var hasIntroVocalsB = false

    // Beat sync
    var isBeatSynced = false
    var beatSyncInfo = ""
    var beatIntervalA: Double = 0
    var beatIntervalB: Double = 0
    var bpmA: Double = 0
    var bpmB: Double = 0

    // Time stretch
    var useTimeStretch = false
    var rateA: Float = 1.0
    var rateB: Float = 1.0

    // ReplayGain
    var replayGainA: Float = 1.0
    var replayGainB: Float = 1.0

    // MARK: - Real-time tick (updated ~1Hz from CrossfadeExecutor)

    var elapsed: Double = 0
    var volumeA: Float = 0
    var volumeB: Float = 0
    var masterVolume: Float = 1.0
    var highpassFreqA: Float = 0
    var highpassFreqB: Float = 0
    var filterTypeA: String = "hp"  // "hp" or "lp" (lowpass for energy-down)
    var lowshelfGainA: Float = 0
    var lowshelfGainB: Float = 0
    var dynamicQA: Float = 0.707
    /// Twin dynQ — current Q on B's highpass (mirrors dynamicQA, peaks earlier).
    var dynamicQB: Float = 0.707
    /// Phaser Notch Sweep — current notch center frequency on B band 2 (0 if inactive).
    var notchFreqB: Float = 0
    /// Phaser Notch Sweep — current notch depth in dB (0 if inactive, negative when cutting).
    var notchGainB: Float = 0
    var panA: Float = 0
    var panB: Float = 0
    var currentRateA: Float = 1.0

    // MARK: - History (last N transitions, in-memory for UI)

    struct TransitionRecord: Identifiable, Codable, Sendable {
        var id = UUID()
        let date: Date
        let fromTitle: String
        let toTitle: String
        let type: String
        let transitionReason: String
        // Timing
        let fadeDuration: Double
        let entryPoint: Double
        let startOffset: Double
        let anticipationTime: Double
        // Filters
        let filterPreset: String
        let filtersEnabled: Bool
        let useMidScoop: Bool
        let useHighShelfCut: Bool
        let useBassKill: Bool
        let useDynamicQ: Bool
        let useNotchSweep: Bool
        let useStutterCut: Bool
        let skipBFilters: Bool
        let bRapidFadeIn: Bool
        let tier4Active: Bool
        // Beat / BPM
        let beatSynced: Bool
        let beatSyncInfo: String
        let bpmA: Double
        let bpmB: Double
        // Time stretch
        let timeStretched: Bool
        let rateA: Float
        let rateB: Float
        // Energy / Analysis
        let energyA: Double
        let energyB: Double
        let danceability: Double
        let isOutroInstrumental: Bool
        let isIntroInstrumental: Bool
        // ReplayGain
        let replayGainA: Float
        let replayGainB: Float
        // v13.K (audit 2026-05-07) — telemetría perceptual.
        // Optional / con default para compatibilidad con records persistidos
        // antes de v13.K (decoder JSON los rellena con nil/false).
        var entryPointSource: String? = nil
        var tier4FailedGate: String? = nil
        var introSlopeB: Double? = nil
        var downbeatDensityB20s: Double? = nil
        var chillRecipeApplied: Bool? = nil
        // v13.L (round 2026-05-09-v13-LMN) — telemetría gates de género.
        // genreCapApplied: true cuando v13.N cap=50 chorus_promotion fue aplicado
        //                  (B fuera de la lista exempt drop-driven).
        // bGenres: lista completa de géneros de B leída de NavidromeSong.genres
        //          en el momento del cálculo. Permite al log-analyst auditar
        //          qué géneros vio el algoritmo y validar gates post-deploy.
        var genreCapApplied: Bool? = nil
        var bGenres: [String]? = nil
        // v13.O Commit 2 (round 2026-05-10) — cap final post-snap +
        // anticipación por outroSlope. Optional para retrocompat con records
        // persistidos antes de Commit 2 (decoder JSON los rellena con nil).
        var entryFinalCapApplied: Bool? = nil
        var anticipationReason: String? = nil
        // v13.O.6 (round 2026-05-15) — telemetría filtros (F4). Aditiva,
        // sin impacto en algoritmo. Validación post coche-test del tail-easing
        // band 3 A + diseño de gates futuros con datos reales. Optional para
        // retrocompat con records persistidos antes de v13.O.6.
        var filterPreRollAppliedA: Bool? = nil
        var highShelfGainA_atEnd: Double? = nil
        var lsGainB_initial: Double? = nil
        var hpFreqB_initial: Double? = nil
        var rmsTailCurveA_last: Double? = nil
        var rmsTailSlopeA: Double? = nil
        var outroEnergyA: Double? = nil
        // v14.12 — telemetría bassKill A (4 campos aditivos).
        var bassKillGainA_atRampStart: Double? = nil
        var bassKillGainA_atVolumeFadeStart: Double? = nil
        var bassKillGainA_atSwap: Double? = nil
        var filterPreRollEffectiveA: Bool? = nil
        // v14.c V1.B — telemetría peak-detector del fade-in (4 campos aditivos).
        var fadeInTriggeredA: Bool? = nil
        var fadeInTriggeredB: Bool? = nil
        var peakTransientDeltaA: Double? = nil
        var peakTransientDeltaB: Double? = nil
        // v14.d V1' — Prueba empírica de hipótesis raíz "coefs del kernel B
        // colgados intermedios desde el fade-out post-swap" (player parado,
        // render thread sin drenar). Pre-V1' esperado ≥ ~0.5; post-V1'
        // (resetSync) esperado ≈ 0. Optional para retrocompat con records
        // pre-v14.d.
        var coefMagB_atSetup: Double? = nil
        // v14.d V2' — telemetría inerte aditiva para calibrar el decisor
        // adaptativo de lsGainB_initial en v14.e (sin tocar audio en v14.d).
        var bassProminenceB_0_15s: Double? = nil
        var vocalOverlapRiskCode: String? = nil
        var energyIntroB_telemetry: Double? = nil
        // v14.g g2 (round 2026-05-17) — valores absolutos de `nextAnalysis`
        // para que log-analyst derive offsets post-hoc desde entryPoint final
        // (chorusOffsetFromEntryB = chorusStartTimeB − entryPoint, etc.). Sin
        // criterio de filtrado en cliente: persistimos siempre que el backend
        // proveyó dato no-cero. Optional para retrocompat con records pre-g2.
        var chorusStartTimeB: Double? = nil
        var downbeatTimesB: [Double]? = nil
        var vocalStartTimeB: Double? = nil
        var introEndHeuristicB: Double? = nil
        // v12 (audit 2026-05-05) — opinion del usuario adjunta a la transicion.
        // Persistida en backend desde round 2026-05-10 diagnostics-backend-port
        // (antes en Documents/transition_diagnostics_history.json — eliminado).
        // userRating: 0-10 (en pasos de 1, equivalente a 5 estrellas con halves).
        // userComment: texto libre para notas del usuario.
        // ratedAt: timestamp del rating (para distinguir vs. nunca rated).
        var userRating: Int? = nil
        var userComment: String? = nil
        var ratedAt: Date? = nil
        // Round 2026-05-10 diagnostics-backend-port — versionado obligatorio en
        // cada record que se sube al backend. `algorithmVersion` semantico
        // (bumped en cada commit que toque DJMixingService/CrossfadeExecutor),
        // `buildId` git SHA del commit del binario. Permiten al backend correlar
        // ratings con cambios concretos del repo. Optional para retrocompat con
        // records persistidos antes del round (si quedara alguno en memoria).
        var algorithmVersion: String? = nil
        var buildId: String? = nil
        // Round 2026-05-10 — sessionId asignado por el backend (gap-based, ≥30
        // min sin transición = nueva sesión). El cliente NO lo calcula. Se
        // rellena con la respuesta del POST /transitions y queda en memoria
        // para el resto de la sesión activa. nil para el record en el momento
        // de subirlo (el backend lo asigna y lo devuelve).
        var sessionId: UUID? = nil
        /// Marker de soft-delete del comment. Backend setea `deletedAt = now`
        /// cuando se llama DELETE /transitions/:id/comment. El record persiste
        /// con rating intacto; solo `userComment = nil`. Permite distinguir
        /// "nunca tuvo comment" (deletedAt nil) de "tenía y se borró" para
        /// estadísticas.
        var deletedAt: Date? = nil
    }

    var history: [TransitionRecord] = []

    // MARK: - Backend status

    var backendConnected = false
    var backendURL = ""
    var lastHealthCheck: Date?

    // MARK: - Network / Environment diagnostics

    struct NetworkSnapshot {
        let timestamp: Date
        let audioRoute: String
        let isBluetoothActive: Bool
        let isCarPlayActive: Bool
        let appState: String          // "active", "background", "inactive"
        let ioBufferDuration: Double  // actual IO buffer in seconds
        let sampleRate: Double
        let outputLatency: Double
    }

    /// Captured at crossfade start and end for comparison.
    var networkSnapshotStart: NetworkSnapshot?
    var networkSnapshotEnd: NetworkSnapshot?

    /// Round 2026-05-10 (diagnostics-backend-port) — eliminados:
    ///   - JSON local `transition_diagnostics_history.json`.
    ///   - Log textual `transition_diagnostics.log`.
    ///   - Métodos asociados (writeTransitionToLog, appendToLog, readLog,
    ///     clearLog, deleteLog, copyLogToClipboard, exportSessionFile,
    ///     logEvent, logFilePath, logFileSize, logFileURL).
    /// Source of truth = backend `<navidromeHost>:2999/api/diagnostics`. Ver
    /// `TransitionDiagnosticsBackend`. La UI Settings>Diagnostics rediseñada
    /// (sesión iOS parte 2 del round) consume directamente del backend.

    /// Cap del array `history` en memoria. No persiste — al arrancar se
    /// rellena con la primera página del backend (`fetchTransitions(limit: 200)`).
    /// Mantenido para que la UI de Settings>Diagnostics no cargue 1000+ records
    /// en SwiftUI list de golpe; la paginación lazy carga más bajo demanda.
    private let historyLimit = 200

    // MARK: - Init

    private init() {
        // Round 2026-05-10 — borrón y cuenta nueva: housekeeping de los
        // ficheros locales obsoletos. Firmado por director (round-current
        // "Eliminar persistencia local completa"). Si quedan records en el
        // JSON viejo se pierden; el director ya los analizó en
        // `D:\Audiorr-shared\analysis\2026-05-10_v13O-commit2-cochetest132.md`.
        Self.purgeLegacyLocalArtifacts()

        // Carga inicial desde backend en background. Si backend no disponible
        // todavía (BackendStateMonitor no ha hecho el primer health check), el
        // resultado quedará vacío — la primera transición de la sesión vivirá
        // solo en memoria hasta que el backend responda. `BackendState` re-llama
        // a `loadHistoryFromBackend()` en transición unavailable→available
        // (BackendState.swift:101).
        Task { await self.loadHistoryFromBackend() }
    }

    /// Borra los artefactos locales obsoletos del v12 previo (JSON history +
    /// .log textual). Idempotente — si no existen, no-op. Llamado una vez en
    /// init. Round 2026-05-10 sesión iOS parte 2: ahora también borra el .log
    /// (la UI rediseñada ya no lo referencia).
    private static func purgeLegacyLocalArtifacts() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let legacyJSON = docs.appendingPathComponent("transition_diagnostics_history.json")
        try? FileManager.default.removeItem(at: legacyJSON)
        let legacyLog = docs.appendingPathComponent("transition_diagnostics.log")
        try? FileManager.default.removeItem(at: legacyLog)
    }

    // MARK: - Backend sync (round 2026-05-10)

    /// Carga la primera página del backend al arrancar y popula `history`. Si
    /// el backend no responde, `history` queda vacío y se va llenando con
    /// nuevos records mientras la sesión avanza. No reintenta — coherente con
    /// "sin queue, sin sync".
    func loadHistoryFromBackend() async {
        let result = await TransitionDiagnosticsBackend.shared.fetchTransitions(limit: historyLimit, offset: 0)
        switch result {
        case .success(let response):
            await MainActor.run {
                // Sustitución completa: el backend es source of truth. Si había
                // algo en memoria de la sesión actual (poco probable en init,
                // pero defensivo), lo conservamos al final por si llegó algún
                // record antes de que la primera fetch terminase.
                let inMemory = self.history.filter { record in
                    !response.transitions.contains(where: { $0.id == record.id })
                }
                self.history = response.transitions + inMemory
                if self.history.count > self.historyLimit {
                    self.history = Array(self.history.prefix(self.historyLimit))
                }
            }
        case .failure(let error):
            print("[TransitionDiagnostics] ⚠️ loadHistoryFromBackend failed: \(error.localizedDescription)")
        }
    }

    /// Actualiza rating y/o comment de una transicion del history. Update
    /// optimista de la copia en memoria + PATCH al backend. Si el PATCH falla,
    /// NO revertimos local: la UI debe mostrar lo que el user pidió (re-edita
    /// si quiere reintentar). Llamado desde TransitionDetailView al cambiar la
    /// opinion.
    func updateOpinion(recordId: UUID, rating: Int?, comment: String?) {
        guard let idx = history.firstIndex(where: { $0.id == recordId }) else { return }
        var record = history[idx]
        record.userRating = rating
        record.userComment = comment?.isEmpty == true ? nil : comment
        record.ratedAt = (rating != nil || (comment?.isEmpty == false)) ? Date() : nil
        history[idx] = record

        // Backend PATCH en detached task. Sin await desde el caller: la UI no
        // espera la red (LAN <100ms pero no bloqueamos en ningún caso).
        guard Self.backendAvailable else { return }
        Task.detached {
            let result = await TransitionDiagnosticsBackend.shared.updateOpinion(
                id: recordId,
                rating: rating,
                comment: record.userComment
            )
            if case .failure(let error) = result {
                print("[TransitionDiagnostics] ⚠️ updateOpinion(\(recordId)) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Soft-delete del comment del record. Rating preservado. Update local
    /// optimista + DELETE al backend (endpoint dedicado, no via PATCH para
    /// que el backend marque `deletedAt`). Llamado desde la UI cuando el user
    /// quiere borrar específicamente el texto sin perder la valoración.
    func deleteOpinion(recordId: UUID) {
        guard let idx = history.firstIndex(where: { $0.id == recordId }) else { return }
        var record = history[idx]
        record.userComment = nil
        record.deletedAt = Date()
        history[idx] = record

        guard Self.backendAvailable else { return }
        Task.detached {
            let result = await TransitionDiagnosticsBackend.shared.deleteComment(id: recordId)
            if case .failure(let error) = result {
                print("[TransitionDiagnostics] ⚠️ deleteOpinion(\(recordId)) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Cuando el backend pasa a no-disponible: deshabilita captura. Ya no hay
    /// JSON local que persistir — el cierre se reduce a apagar el flag.
    /// Llamado desde BackendStateMonitor observando isAvailable=false.
    func handleBackendUnavailable() {
        Self.debugModeEnabled = false
        UserDefaults.standard.set(false, forKey: "audiorr_diagnostics_enabled")
    }

    // MARK: - Network snapshot capture

    /// Captures current audio session, route, and app state for diagnostics.
    nonisolated static func captureNetworkSnapshot() -> NetworkSnapshot {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let outputName = route.outputs.first?.portName ?? "Unknown"
        let isBT = route.outputs.contains { [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0.portType) }
        let isCP = route.outputs.contains { $0.portType == .carAudio }

        let appState: String
        if Thread.isMainThread {
            switch UIApplication.shared.applicationState {
            case .active: appState = "active"
            case .background: appState = "background"
            case .inactive: appState = "inactive"
            @unknown default: appState = "unknown"
            }
        } else {
            appState = "non-main-thread"
        }

        return NetworkSnapshot(
            timestamp: Date(),
            audioRoute: outputName,
            isBluetoothActive: isBT,
            isCarPlayActive: isCP,
            appState: appState,
            ioBufferDuration: session.ioBufferDuration,
            sampleRate: session.sampleRate,
            outputLatency: session.outputLatency
        )
    }

    // MARK: - Publish from CrossfadeExecutor

    /// Called by CrossfadeExecutor at init to snapshot the decision.
    nonisolated func publishDecision(
        transitionType: String,
        currentTitle: String,
        nextTitle: String,
        fadeDuration: Double,
        entryPoint: Double,
        startOffset: Double,
        anticipationTime: Double,
        filtersEnabled: Bool,
        filterPreset: String,
        useMidScoop: Bool,
        useHighShelfCut: Bool,
        useBassKill: Bool,
        useDynamicQ: Bool,
        useNotchSweep: Bool,
        useStutterCut: Bool,
        skipBFilters: Bool,
        bRapidFadeIn: Bool,
        tier4Active: Bool,
        energyA: Double,
        energyB: Double,
        isOutroInstrumental: Bool,
        isIntroInstrumental: Bool,
        danceability: Double,
        isBeatSynced: Bool,
        beatSyncInfo: String,
        beatIntervalA: Double,
        beatIntervalB: Double,
        useTimeStretch: Bool,
        rateA: Float,
        rateB: Float,
        replayGainA: Float,
        replayGainB: Float,
        entryPointSource: String = "unknown",
        tier4FailedGate: String? = nil,
        introSlopeB: Double? = nil,
        downbeatDensityB20s: Double? = nil,
        chillRecipeApplied: Bool = false
    ) {
        guard Self.collectingEnabled else { return }
        Task { @MainActor in
            self.isActive = true
            self.transitionType = transitionType
            self.currentTitle = currentTitle
            self.nextTitle = nextTitle
            self.fadeDuration = fadeDuration
            self.entryPoint = entryPoint
            self.startOffset = startOffset
            self.anticipationTime = anticipationTime
            self.filtersEnabled = filtersEnabled
            self.filterPreset = filterPreset
            self.useMidScoop = useMidScoop
            self.useHighShelfCut = useHighShelfCut
            self.useBassKill = useBassKill
            self.useDynamicQ = useDynamicQ
            self.useNotchSweep = useNotchSweep
            self.useStutterCut = useStutterCut
            self.skipBFilters = skipBFilters
            self.bRapidFadeIn = bRapidFadeIn
            self.tier4Active = tier4Active
            self.energyA = energyA
            self.energyB = energyB
            self.isOutroInstrumental = isOutroInstrumental
            self.isIntroInstrumental = isIntroInstrumental
            self.danceability = danceability
            self.isBeatSynced = isBeatSynced
            self.beatSyncInfo = beatSyncInfo
            self.beatIntervalA = beatIntervalA
            self.beatIntervalB = beatIntervalB
            self.bpmA = beatIntervalA > 0 ? 60.0 / beatIntervalA : 0
            self.bpmB = beatIntervalB > 0 ? 60.0 / beatIntervalB : 0
            self.useTimeStretch = useTimeStretch
            self.rateA = rateA
            self.rateB = rateB
            self.replayGainA = replayGainA
            self.replayGainB = replayGainB
            self.entryPointSource = entryPointSource
            self.tier4FailedGate = tier4FailedGate
            self.introSlopeB = introSlopeB
            self.downbeatDensityB20s = downbeatDensityB20s
            self.chillRecipeApplied = chillRecipeApplied
            self.elapsed = 0
            self.volumeA = replayGainA
            self.volumeB = 0
            self.highpassFreqA = 0
            self.highpassFreqB = 0
            self.networkSnapshotStart = Self.captureNetworkSnapshot()
            self.networkSnapshotEnd = nil
        }
    }

    /// Called by CrossfadeExecutor ~1Hz to update real-time values.
    nonisolated func publishTick(
        elapsed: Double,
        volumeA: Float,
        volumeB: Float,
        masterVolume: Float,
        highpassFreqA: Float,
        highpassFreqB: Float,
        filterTypeA: String = "hp",
        lowshelfGainA: Float,
        lowshelfGainB: Float,
        dynamicQA: Float = 0.707,
        dynamicQB: Float = 0.707,
        notchFreqB: Float = 0,
        notchGainB: Float = 0,
        panA: Float,
        panB: Float,
        currentRateA: Float
    ) {
        guard Self.collectingEnabled else { return }
        Task { @MainActor in
            self.elapsed = elapsed
            self.volumeA = volumeA
            self.volumeB = volumeB
            self.masterVolume = masterVolume
            self.highpassFreqA = highpassFreqA
            self.highpassFreqB = highpassFreqB
            self.filterTypeA = filterTypeA
            self.lowshelfGainA = lowshelfGainA
            self.lowshelfGainB = lowshelfGainB
            self.dynamicQA = dynamicQA
            self.dynamicQB = dynamicQB
            self.notchFreqB = notchFreqB
            self.notchGainB = notchGainB
            self.panA = panA
            self.panB = panB
            self.currentRateA = currentRateA
            // Round 2026-05-10 — sin buffer textual: el log .log se eliminó.
            // La UI Settings>Diagnostics consume estas mismas propiedades en
            // tiempo real (sección "Real-time" del active transition).
        }
    }

    /// Called when crossfade completes. Archives into in-memory history, then
    /// fires off the upload to the backend in a detached task (fire-and-forget).
    /// Round 2026-05-10 (diagnostics-backend-port): JSON local eliminado, log
    /// textual ya no se escribe — backend es source of truth.
    nonisolated func publishCompletion() {
        guard Self.collectingEnabled else { return }
        Task { @MainActor in
            // Build record con versionado + telemetría completa.
            // v14.e Alt-3 — id anclado al `upcomingRecordId` seteado por
            // `CrossfadeExecutor.start()` para que el stash de audits (T+0,
            // +200ms, post-swap+300ms) consume contra el mismo id que el
            // POST envía al backend.
            let record = TransitionRecord(
                id: Self.upcomingRecordId,
                date: Date(),
                fromTitle: self.currentTitle,
                toTitle: self.nextTitle,
                type: self.transitionType,
                transitionReason: self.transitionReason,
                fadeDuration: self.fadeDuration,
                entryPoint: self.entryPoint,
                startOffset: self.startOffset,
                anticipationTime: self.anticipationTime,
                filterPreset: self.filterPreset,
                filtersEnabled: self.filtersEnabled,
                useMidScoop: self.useMidScoop,
                useHighShelfCut: self.useHighShelfCut,
                useBassKill: self.useBassKill,
                useDynamicQ: self.useDynamicQ,
                useNotchSweep: self.useNotchSweep,
                useStutterCut: self.useStutterCut,
                skipBFilters: self.skipBFilters,
                bRapidFadeIn: self.bRapidFadeIn,
                tier4Active: self.tier4Active,
                beatSynced: self.isBeatSynced,
                beatSyncInfo: self.beatSyncInfo,
                bpmA: self.bpmA,
                bpmB: self.bpmB,
                timeStretched: self.useTimeStretch,
                rateA: self.rateA,
                rateB: self.rateB,
                energyA: self.energyA,
                energyB: self.energyB,
                danceability: self.danceability,
                isOutroInstrumental: self.isOutroInstrumental,
                isIntroInstrumental: self.isIntroInstrumental,
                replayGainA: self.replayGainA,
                replayGainB: self.replayGainB,
                entryPointSource: self.entryPointSource,
                tier4FailedGate: self.tier4FailedGate,
                introSlopeB: self.introSlopeB,
                downbeatDensityB20s: self.downbeatDensityB20s,
                chillRecipeApplied: self.chillRecipeApplied,
                genreCapApplied: self.genreCapApplied,
                bGenres: self.bGenres.isEmpty ? nil : self.bGenres,
                // v13.O.3: serializa siempre con false por defecto. Antes el
                // campo era `Bool?` con default nil y JSONEncoder lo omitía,
                // dejando la cobertura backend al 13% (solo cuando entry>50).
                // El log-analyst no podía distinguir "no aplicó cap" de "no
                // se evaluó" — comparativas contaminadas. Forzar false
                // distingue ambos casos y desbloquea análisis del cap real.
                entryFinalCapApplied: self.entryFinalCapApplied ?? false,
                anticipationReason: self.anticipationReason,
                filterPreRollAppliedA: self.filterPreRollAppliedA,
                highShelfGainA_atEnd: self.highShelfGainA_atEnd,
                lsGainB_initial: self.lsGainB_initial,
                hpFreqB_initial: self.hpFreqB_initial,
                rmsTailCurveA_last: self.rmsTailCurveA_last,
                rmsTailSlopeA: self.rmsTailSlopeA,
                outroEnergyA: self.outroEnergyA,
                bassKillGainA_atRampStart: self.bassKillGainA_atRampStart,
                bassKillGainA_atVolumeFadeStart: self.bassKillGainA_atVolumeFadeStart,
                bassKillGainA_atSwap: self.bassKillGainA_atSwap,
                filterPreRollEffectiveA: self.filterPreRollEffectiveA,
                fadeInTriggeredA: self.fadeInTriggeredA,
                fadeInTriggeredB: self.fadeInTriggeredB,
                peakTransientDeltaA: self.peakTransientDeltaA,
                peakTransientDeltaB: self.peakTransientDeltaB,
                coefMagB_atSetup: self.coefMagB_atSetup,
                bassProminenceB_0_15s: self.bassProminenceB_0_15s,
                vocalOverlapRiskCode: self.vocalOverlapRiskCode,
                energyIntroB_telemetry: self.energyIntroB_telemetry,
                chorusStartTimeB: self.chorusStartTimeB,
                downbeatTimesB: self.downbeatTimesB,
                vocalStartTimeB: self.vocalStartTimeB,
                introEndHeuristicB: self.introEndHeuristicB,
                algorithmVersion: DJMixingService.kAlgorithmVersion,
                buildId: DJMixingService.kBuildId
            )
            self.history.insert(record, at: 0)
            if self.history.count > self.historyLimit { self.history.removeLast() }
            self.isActive = false
            self.networkSnapshotEnd = Self.captureNetworkSnapshot()

            // Upload al backend fire-and-forget con audit stash (v14.e Alt-3).
            // Flujo:
            //   T+0      audit completeCrossfade publica (corre síncrono pre-publishCompletion)
            //   T=ahora  consumimos stash completeCrossfade contra recordId (caveat duro 1)
            //   T+250ms  POST sale con sub-objeto postResetAuditCompleteCrossfade inline
            //   T+~300ms audit post-swap publica (asyncAfter desde swap +100+200ms)
            //   T+~500ms tras .success POST, polling 50ms × 10 lee post-swap stash
            //   T+~500ms PATCH /enrich con { postResetAuditPostSwap: {...} }
            //
            // El filtro `isActive == false` original (sec 2.6 caveat 3) está
            // ELIMINADO: era semánticamente invertido — publishCompletion ya
            // pone isActive=false 3 líneas arriba antes del Task.detached.
            // El gate efectivo es "POST devolvió 201" (continuation natural).
            if Self.backendAvailable {
                let recordId = record.id
                let completePayload = Self.consumeCompleteCrossfade(recordId: recordId)
                self.lastAuditUploadStatus = .pending
                print("[AuditUpload] T=POST_send rid=\(recordId.uuidString.prefix(8)) hasComplete=\(completePayload != nil)")

                Task.detached {
                    let result = await TransitionDiagnosticsBackend.shared.uploadRecord(
                        record,
                        postResetAuditCompleteCrossfade: completePayload
                    )
                    switch result {
                    case .success(let response):
                        await MainActor.run {
                            TransitionDiagnostics.shared.lastAuditUploadStatus = .postOk
                            if let idx = TransitionDiagnostics.shared.history.firstIndex(where: { $0.id == response.id }) {
                                TransitionDiagnostics.shared.history[idx].sessionId = response.sessionId
                            }
                        }

                        // Caveat duro 2 sec 2.6 review 2 — polling 50ms × 10
                        // del stash post-swap. Sin race de registro de
                        // continuation ni leak de waiter. Latencia máx 500ms.
                        var postSwapPayload: [String: Any]? = nil
                        for _ in 0..<10 {
                            if let p = TransitionDiagnostics.peekPostSwap(recordId: recordId) {
                                postSwapPayload = p
                                break
                            }
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }

                        guard let postSwap = postSwapPayload else {
                            print("[AuditUpload] T=PATCH_skip rid=\(recordId.uuidString.prefix(8)) — post-swap stash vacío (timeout 500ms)")
                            return
                        }

                        print("[AuditUpload] T=PATCH_send rid=\(recordId.uuidString.prefix(8))")
                        let patchResult = await TransitionDiagnosticsBackend.shared.enrichRecord(
                            id: recordId,
                            body: ["postResetAuditPostSwap": postSwap]
                        )
                        await MainActor.run {
                            switch patchResult {
                            case .success:
                                TransitionDiagnostics.shared.lastAuditUploadStatus = .patchOk
                            case .failure(.notFound):
                                // Caveat duro 8 sec 2.6 review 2 — PATCH 404
                                // = POST 201 OK pero backend aún no commit
                                // del record (race extremadamente raro con
                                // LAN flaky). Marca explícita para que
                                // log-analyst distinga de otros .failure.
                                TransitionDiagnostics.shared.lastAuditUploadStatus = .failedRaceLost
                                print("[AuditUpload] PATCH 404 rid=\(recordId.uuidString.prefix(8)) — race lost (POST ack llegó pero record aún no commit)")
                            case .failure(let e):
                                TransitionDiagnostics.shared.lastAuditUploadStatus = .patchFailed
                                print("[AuditUpload] PATCH failed: \(e.localizedDescription)")
                            }
                        }
                        TransitionDiagnostics.consumePostSwap()

                    case .failure(let error):
                        await MainActor.run { TransitionDiagnostics.shared.lastAuditUploadStatus = .postFailed }
                        print("[TransitionDiagnostics] ⚠️ uploadRecord(\(record.id)) failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Post-reset audit

    /// Snapshot of biquad filter state read from BiquadDSPNode.
    struct EQBandSnapshot {
        let filterType: String
        let frequency: Float
        let gain: Float
        let bandwidth: Float
        let bypass: Bool
    }

    /// Secondary snapshot for DSP comparison. With BiquadDSPNode, both snapshots
    /// come from the same source (no Swift-vs-CoreAudio divergence possible).
    struct DSPBandSnapshot {
        let gain: Float
        let frequency: Float
        let bandwidth: Float
    }

    struct PostResetAudit {
        let source: String          // "completeCrossfade", "cancel", "cancel+150ms", "completeCrossfade+200ms"
        let bandsA: [EQBandSnapshot]
        let bandsB: [EQBandSnapshot]
        var dspBandsA: [DSPBandSnapshot] = []
        var dspBandsB: [DSPBandSnapshot] = []
        let panA: Float
        let panB: Float
        let rateA: Float            // Swift property
        let rateB: Float            // Swift property
        var dspRateA: Float = 1.0   // AudioUnitGetParameter (rate)
        var dspRateB: Float = 1.0   // AudioUnitGetParameter (rate)
        // Honest-audit additions: catch the residue the coefficient check misses.
        var dspPitchA: Float = 0    // AudioUnitGetParameter (pitch, cents)
        var dspPitchB: Float = 0    // AudioUnitGetParameter (pitch, cents)
        var stateMagA: Float = 0    // BiquadDSPKernel delay-line magnitude
        var stateMagB: Float = 0
        var bypassA: Bool = false   // AVAudioUnit shouldBypassEffect
        var bypassB: Bool = false

        // v14.g (round 2026-05-17) — observabilidad del reset DSP. `stateMagA/B`
        // arriba se leen de `lastStateMagnitude`, que solo se escribe dentro de
        // `process()` cuando hay stage no-passthrough. Entre `resetSync()` y el
        // audit T+0 median ~µs en automationQueue serial → render thread NO ha
        // procesado ≥1 buffer post-reset → la métrica queda congelada en el
        // valor anterior al reset (Caso B, ver issue 2026-05-17-v14g). Los
        // campos `_postProcess` se capturan TRAS dormir `1.5 × ioBufferDuration`
        // en automation thread, garantizando que el render thread haya
        // procesado al menos un buffer con coefs ya en passthrough — entonces
        // `lastStateMagnitude` refleja realmente el estado post-reset (≈0 si
        // resetSync funciona, distinto de 0 si el residue persiste por otro
        // path). Aditivos opcionales: solo se rellenan en el call-site de
        // `completeCrossfade`; resto de fuentes (cancel, post-swap, +200ms)
        // los dejan nil.
        var stateMagA_postProcess: Float? = nil
        var stateMagB_postProcess: Float? = nil
        /// `AVAudioSession.sharedInstance().ioBufferDuration` en ms al momento
        /// del audit. CarPlay típico 40ms, default ~20ms. Sin este campo no
        /// podemos saber si el sleep fue suficiente para garantizar ≥1 buffer
        /// procesado post-reset en cada record.
        var ioBufferDurationMs: Float? = nil
        /// Sleep real aplicado en ms antes de capturar `_postProcess`. Debe ser
        /// ≥ `ioBufferDurationMs × 1.5`. Si log-analyst ve sleep < buffer
        /// significa que la fórmula de cálculo falló.
        var sleepAppliedMs: Float? = nil
    }

    /// Whether the last audit detected stuck filters (non-neutral values).
    var lastAuditFailed = false
    var lastAuditDetails = ""

    /// Called from CrossfadeExecutor after dsp.reset() to verify filter state.
    /// With BiquadDSPNode, both snapshots read from the same kernel — divergence is impossible.
    nonisolated func publishPostResetAudit(_ audit: PostResetAudit) {
        // Check if any band is non-neutral (stuck filter after reset)
        // With BiquadDSPNode: bypass=true means passthrough, gain=0.
        // Any band with bypass=false after reset is stuck.
        let allBands = audit.bandsA + audit.bandsB
        let stuckBands = allBands.filter { band in
            !band.bypass
        }

        // Check DSP-level divergence: compare AudioUnitGetParameter values vs Swift properties
        var dspDivergences: [String] = []
        func checkDivergence(label: String, swift: [EQBandSnapshot], dsp: [DSPBandSnapshot]) {
            for i in 0..<min(swift.count, dsp.count) {
                let sg = swift[i].gain
                let dg = dsp[i].gain
                let sf = swift[i].frequency
                let df = dsp[i].frequency
                // Gain divergence > 0.5dB is significant (catches stale -14dB midScoop, -10dB hiShelfCut)
                if abs(sg - dg) > 0.5 {
                    dspDivergences.append("\(label)b\(i) gain: swift=\(String(format: "%.1f", sg))dB DSP=\(String(format: "%.1f", dg))dB Δ=\(String(format: "%.1f", abs(sg - dg)))dB")
                }
                // Frequency divergence > 50Hz is significant (catches stale highpass sweeps)
                if abs(sf - df) > 50 {
                    dspDivergences.append("\(label)b\(i) freq: swift=\(String(format: "%.0f", sf))Hz DSP=\(String(format: "%.0f", df))Hz")
                }
            }
        }
        checkDivergence(label: "A-", swift: audit.bandsA, dsp: audit.dspBandsA)
        checkDivergence(label: "B-", swift: audit.bandsB, dsp: audit.dspBandsB)

        // Check TimePitch rate divergence (Swift .rate vs AudioUnitGetParameter)
        let rateThreshold: Float = 0.01
        if abs(audit.rateA - audit.dspRateA) > rateThreshold {
            dspDivergences.append("TimePitch-A rate: swift=\(String(format: "%.3f", audit.rateA)) DSP=\(String(format: "%.3f", audit.dspRateA))")
        }
        if abs(audit.rateB - audit.dspRateB) > rateThreshold {
            dspDivergences.append("TimePitch-B rate: swift=\(String(format: "%.3f", audit.rateB)) DSP=\(String(format: "%.3f", audit.dspRateB))")
        }
        // Hard checks against neutral. The audit lies if it only compares Swift↔DSP
        // and both happen to read the same wrong value. After reset, neutral is rate=1.0.
        if abs(audit.dspRateA - 1.0) > rateThreshold {
            dspDivergences.append("TimePitch-A rate NOT NEUTRAL: AU=\(String(format: "%.3f", audit.dspRateA))")
        }
        if abs(audit.dspRateB - 1.0) > rateThreshold {
            dspDivergences.append("TimePitch-B rate NOT NEUTRAL: AU=\(String(format: "%.3f", audit.dspRateB))")
        }
        // Pitch should be 0 cents at neutral. resetTimePitch* sets pitch=0; if AU
        // disagrees, something else wrote pitch (or AudioUnitReset is needed).
        let pitchThreshold: Float = 1.0  // 1 cent ~ inaudible
        if abs(audit.dspPitchA) > pitchThreshold {
            dspDivergences.append("TimePitch-A pitch NOT NEUTRAL: AU=\(String(format: "%.1f", audit.dspPitchA))cents")
        }
        if abs(audit.dspPitchB) > pitchThreshold {
            dspDivergences.append("TimePitch-B pitch NOT NEUTRAL: AU=\(String(format: "%.1f", audit.dspPitchB))cents")
        }
        // Biquad delay-line residue. After reset, render thread should have zeroed
        // state. If still > epsilon when we audit (especially in delayed audits),
        // the render thread didn't process — player stopped, or race window.
        let stateThreshold: Float = 1e-3
        if audit.stateMagA > stateThreshold {
            dspDivergences.append("Biquad-A delay-line residue: |state|=\(String(format: "%.4f", audit.stateMagA))")
        }
        if audit.stateMagB > stateThreshold {
            dspDivergences.append("Biquad-B delay-line residue: |state|=\(String(format: "%.4f", audit.stateMagB))")
        }
        // Bypass should be false for normal playback. If it gets stuck true, audio
        // skips the time-pitch entirely — symptom looks like "no fade applied".
        if audit.bypassA {
            dspDivergences.append("TimePitch-A bypass STUCK ON")
        }
        if audit.bypassB {
            dspDivergences.append("TimePitch-B bypass STUCK ON")
        }

        let hasDivergence = !dspDivergences.isEmpty
        let isClean = stuckBands.isEmpty && !hasDivergence && abs(audit.panA) < 0.01 && abs(audit.panB) < 0.01

        var line = "  POST-RESET AUDIT [\(audit.source)]:"
        if hasDivergence {
            line += " 🔴 DSP DIVERGENCE"
        } else if !stuckBands.isEmpty {
            line += " 🚨 STUCK FILTERS DETECTED"
        } else {
            line += " ✅ CLEAN"
        }

        // Swift property values
        line += "\n    EQ-A (Swift):"
        for (i, b) in audit.bandsA.enumerated() {
            line += " b\(i)[\(b.filterType) \(String(format: "%.0f", b.frequency))Hz g=\(String(format: "%.1f", b.gain))dB]"
        }
        line += "\n    EQ-B (Swift):"
        for (i, b) in audit.bandsB.enumerated() {
            line += " b\(i)[\(b.filterType) \(String(format: "%.0f", b.frequency))Hz g=\(String(format: "%.1f", b.gain))dB]"
        }

        // DSP-level values (raw AudioUnit parameters)
        if !audit.dspBandsA.isEmpty {
            line += "\n    EQ-A (DSP):"
            for (i, b) in audit.dspBandsA.enumerated() {
                line += " b\(i)[\(String(format: "%.0f", b.frequency))Hz g=\(String(format: "%.1f", b.gain))dB]"
            }
        }
        if !audit.dspBandsB.isEmpty {
            line += "\n    EQ-B (DSP):"
            for (i, b) in audit.dspBandsB.enumerated() {
                line += " b\(i)[\(String(format: "%.0f", b.frequency))Hz g=\(String(format: "%.1f", b.gain))dB]"
            }
        }

        line += String(format: "\n    pan: A=%.3f B=%.3f  rate(Swift): A=%.3f B=%.3f  rate(DSP): A=%.3f B=%.3f",
                       audit.panA, audit.panB, audit.rateA, audit.rateB, audit.dspRateA, audit.dspRateB)
        line += String(format: "\n    pitch(DSP): A=%.1fcents B=%.1fcents  bypass: A=%@ B=%@  |state|: A=%.4f B=%.4f",
                       audit.dspPitchA, audit.dspPitchB,
                       audit.bypassA ? "TRUE" : "false", audit.bypassB ? "TRUE" : "false",
                       audit.stateMagA, audit.stateMagB)

        if hasDivergence {
            line += "\n    🔴 DSP DIVERGENCE DETECTED (Swift says neutral but AudioUnit disagrees):"
            for d in dspDivergences {
                line += "\n      → \(d)"
            }
        }
        if !stuckBands.isEmpty {
            line += "\n    ⚠️ STUCK: \(stuckBands.map { "\($0.filterType) \(String(format: "%.0f", $0.frequency))Hz g=\(String(format: "%.1f", $0.gain))dB" }.joined(separator: ", "))"
        }
        if abs(audit.panA) >= 0.01 || abs(audit.panB) >= 0.01 {
            line += "\n    ⚠️ pan not centered"
        }

        // Console output
        let consolePrefix: String
        if hasDivergence { consolePrefix = "[PostResetAudit 🔴 DSP DIVERGE]" }
        else if !stuckBands.isEmpty { consolePrefix = "[PostResetAudit 🚨 STUCK]" }
        else { consolePrefix = "[PostResetAudit ✅]" }
        print("\(consolePrefix) \(audit.source) — Swift: A=\(audit.bandsA.map { "\(String(format: "%.1f", $0.gain))dB" }) B=\(audit.bandsB.map { "\(String(format: "%.1f", $0.gain))dB" }) | DSP: A=\(audit.dspBandsA.map { "\(String(format: "%.1f", $0.gain))dB" }) B=\(audit.dspBandsB.map { "\(String(format: "%.1f", $0.gain))dB" })\(hasDivergence ? " ← MISMATCH" : "")")

        Task { @MainActor in
            self.lastAuditFailed = !isClean
            self.lastAuditDetails = line
            // Round 2026-05-10 — sin pendingAudits ni flush a log: el .log se
            // eliminó. La detección de stuck filters / DSP divergence sigue
            // viva (console output arriba y `lastAuditFailed`/`lastAuditDetails`
            // observables por la UI si hace falta).
        }

        // v14.e Alt-3 — stash del payload slim contra el recordId vigente.
        // El POST (T+250ms) consume el stash de "completeCrossfade*"; el
        // waiter post-201 hace PATCH con el stash de "post-swap*". Sources
        // distintos a esos dos no se stashean (no hay record que enriquecer).
        let payload = Self.buildAuditPayload(audit)
        let rid = Self.upcomingRecordId
        if audit.source.hasPrefix("completeCrossfade") {
            Self.stashCompleteCrossfade(recordId: rid, payload: payload)
            print("[AuditUpload] T=stash source=\(audit.source) rid=\(rid.uuidString.prefix(8))")
        } else if audit.source.hasPrefix("post-swap") {
            Self.stashPostSwap(recordId: rid, payload: payload)
            print("[AuditUpload] T=stash source=\(audit.source) rid=\(rid.uuidString.prefix(8))")
        }
    }

    // MARK: - Removed in round 2026-05-10 (diagnostics-backend-port)
    // Eliminados: writeTransitionToLog, appendToLog, readLog, clearLog,
    // deleteLog, copyLogToClipboard, logEvent, logFilePath, logFileSize,
    // logFileURL, flushAuditsToLog, pendingAudits, exportSessionFile.
    // El backend es la fuente de verdad. Console output (print) sigue siendo
    // útil para debugging en Xcode durante desarrollo.

    /// Update backend status.
    func updateBackendStatus(connected: Bool, url: String) {
        backendConnected = connected
        backendURL = url
        lastHealthCheck = Date()
    }
}
