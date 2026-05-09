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
    /// Lista plural de géneros de B vista por el algoritmo en el momento del
    /// cálculo. Poblada siempre que el path se ejecute (vía SongAnalysis.genres
    /// que copia de NavidromeSong.genres).
    var bGenres: [String] = []

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

    struct TransitionRecord: Identifiable, Codable {
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
        // v12 (audit 2026-05-05) — opinion del usuario adjunta a la transicion.
        // Persistida en Documents/transition_diagnostics_history.json.
        // userRating: 0-10 (en pasos de 1, equivalente a 5 estrellas con halves).
        // userComment: texto libre para notas del usuario.
        // ratedAt: timestamp del rating (para distinguir vs. nunca rated).
        var userRating: Int? = nil
        var userComment: String? = nil
        var ratedAt: Date? = nil
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

    // MARK: - Persistent log

    /// Path to the log file in Documents.
    var logFilePath: String { logFileURL.path }

    private let logFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("transition_diagnostics.log")
    }()

    /// v12 (audit 2026-05-05) — JSON persistente con la history completa
    /// (transiciones + opiniones del usuario). El .log de texto sigue activo
    /// para legibilidad humana, pero el JSON es el source of truth para
    /// reconstruir history al arrancar y para hacer export estructurado.
    private let historyFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("transition_diagnostics_history.json")
    }()

    /// Limit de records persistidos. Los mas antiguos se descartan FIFO cuando
    /// se supera. 200 cubre ~3 sesiones largas de coche (50-70 transiciones
    /// cada una) sin saturar el archivo ni perder contexto reciente.
    private let historyLimit = 200

    /// Ticks collected during active crossfade, flushed on completion.
    private var pendingTicks: [String] = []

    // MARK: - Init

    private init() {
        // Write header on first launch if file doesn't exist
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            let header = "# Audiorr Transition Diagnostics Log\n# Format: human-readable, one block per transition\n# Generated automatically by TransitionDiagnostics\n\n"
            try? header.write(to: logFileURL, atomically: true, encoding: .utf8)
        }
        loadHistory()
    }

    // MARK: - History persistence (v12)

    /// Carga history desde JSON al arrancar. Si el archivo no existe o esta
    /// corrupto, history queda vacia (no es error fatal — solo perdimos sesiones
    /// previas). Aplica el limite FIFO por si el archivo viene de una version
    /// anterior con limite distinto.
    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: historyFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: historyFileURL)
            let decoded = try JSONDecoder().decode([TransitionRecord].self, from: data)
            self.history = Array(decoded.prefix(historyLimit))
        } catch {
            print("[TransitionDiagnostics] ⚠️ Failed to load history JSON: \(error.localizedDescription)")
        }
    }

    /// Persiste history a JSON. Llamar tras cada cambio (nuevo record, rating
    /// update, comment edit). FIFO al limite. Errores se loguean pero no
    /// propagan — perder un guardado puntual no debe romper el flujo de la app.
    private func saveHistory() {
        if history.count > historyLimit {
            history = Array(history.prefix(historyLimit))
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(history)
            try data.write(to: historyFileURL, options: [.atomic])
        } catch {
            print("[TransitionDiagnostics] ⚠️ Failed to save history JSON: \(error.localizedDescription)")
        }
    }

    /// Actualiza rating y/o comment de una transicion del history. Persiste
    /// inmediatamente. Llamado desde TransitionDetailView al cambiar la opinion.
    func updateOpinion(recordId: UUID, rating: Int?, comment: String?) {
        guard let idx = history.firstIndex(where: { $0.id == recordId }) else { return }
        var record = history[idx]
        record.userRating = rating
        record.userComment = comment?.isEmpty == true ? nil : comment
        record.ratedAt = (rating != nil || (comment?.isEmpty == false)) ? Date() : nil
        history[idx] = record
        saveHistory()
    }

    /// Cuando el backend pasa a no-disponible: deshabilita captura, persiste
    /// history actual (por si quedaba algun cambio sin guardar) y NO borra los
    /// datos existentes (el usuario debe poder exportar lo que ya tenia incluso
    /// si pierde conexion temporalmente). Llamado desde SettingsView observando
    /// BackendState.isAvailable.
    func handleBackendUnavailable() {
        Self.debugModeEnabled = false
        UserDefaults.standard.set(false, forKey: "audiorr_diagnostics_enabled")
        saveHistory()
    }

    // MARK: - Export Session (v12)

    /// Genera un archivo combinado con la sesion completa: header (device, app
    /// version, fecha, stats), un bloque por transicion con sus AUTOMATION TICKS
    /// + post-reset audits + seccion OPINION (rating + comment), y footer con
    /// agregados (promedio, distribucion, conteo de Tier 4 / DJ effects).
    /// Diseñado para que un agente externo (Claude) pueda leer todo el set de
    /// una vez sin necesitar dos archivos separados.
    nonisolated func exportSessionFile() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let stamp = formatter.string(from: Date())
        let url = docs.appendingPathComponent("audiorr_session_\(stamp).txt")

        var content = "# Audiorr Session Export — \(stamp)\n"
        content += "# Combina diagnosticos tecnicos + opiniones del usuario.\n\n"

        // Append the existing transition log (if any).
        let logURL = docs.appendingPathComponent("transition_diagnostics.log")
        if let logText = try? String(contentsOf: logURL, encoding: .utf8) {
            content += "## TECHNICAL LOG\n\n"
            content += logText
            content += "\n\n"
        }

        // Append per-transition opinions and final stats from history.
        let snapshot: [TransitionRecord] = MainActor.assumeIsolated { Self.shared.history }
        if !snapshot.isEmpty {
            content += "## USER OPINIONS\n\n"
            let dateFmt = ISO8601DateFormatter()
            for record in snapshot.reversed() {
                let rating = record.userRating.map { "\($0)/10" } ?? "—"
                let comment = record.userComment ?? ""
                content += "[\(dateFmt.string(from: record.date))] \(record.type)\n"
                content += "  FROM: \(record.fromTitle)\n"
                content += "  TO:   \(record.toTitle)\n"
                content += "  RATING: \(rating)\n"
                if !comment.isEmpty {
                    content += "  COMMENT: \(comment)\n"
                }
                content += "\n"
            }

            // Aggregates.
            let rated = snapshot.compactMap { $0.userRating }
            if !rated.isEmpty {
                let avg = Double(rated.reduce(0, +)) / Double(rated.count)
                content += "## AGGREGATES\n\n"
                content += "  Total transitions: \(snapshot.count)\n"
                content += "  Rated: \(rated.count)\n"
                content += "  Average rating: \(String(format: "%.2f", avg))/10\n"
                let tier4Count = snapshot.filter { $0.tier4Active }.count
                let bassKillCount = snapshot.filter { $0.useBassKill }.count
                let stutterCount = snapshot.filter { $0.useStutterCut }.count
                content += "  Tier4 fires: \(tier4Count)/\(snapshot.count)\n"
                content += "  bassKill: \(bassKillCount)/\(snapshot.count)\n"
                content += "  stutterCut: \(stutterCount)/\(snapshot.count)\n"
            }
        }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("[TransitionDiagnostics] ⚠️ Failed to export session: \(error.localizedDescription)")
            return nil
        }
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
            self.pendingTicks = []
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

            // Buffer tick for log
            let label = filterTypeA == "lp" ? "lpA" : "hpA"
            let qLabel = self.useDynamicQ ? String(format: " Q=%.2f", dynamicQA) : ""
            let qBLabel = self.useDynamicQ ? String(format: " Qb=%.2f", dynamicQB) : ""
            let notchLabel = self.useNotchSweep
                ? String(format: " notch=%.0fHz/%.1fdB", notchFreqB, notchGainB)
                : ""
            let tick = String(format: "  t+%.1fs | volA=%.3f volB=%.3f master=%.2f | \(label)=%.0fHz\(qLabel) hpB=%.0fHz\(qBLabel)\(notchLabel) | lsA=%.1fdB lsB=%.1fdB | panA=%.3f panB=%.3f | rateA=%.3f",
                              elapsed, volumeA, volumeB, masterVolume,
                              highpassFreqA, highpassFreqB,
                              lowshelfGainA, lowshelfGainB,
                              panA, panB, currentRateA)
            self.pendingTicks.append(tick)
        }
    }

    /// Called when crossfade completes. Archives into history and writes to log file.
    nonisolated func publishCompletion() {
        guard Self.collectingEnabled else { return }
        Task { @MainActor in
            // Save to in-memory history
            let record = TransitionRecord(
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
                bGenres: self.bGenres.isEmpty ? nil : self.bGenres
            )
            self.history.insert(record, at: 0)
            if self.history.count > self.historyLimit { self.history.removeLast() }
            // v12: persistir cada nueva transicion al JSON inmediatamente.
            // Asi, si el usuario fuerza-cierra la app despues del crossfade, no
            // pierde el record (era el bug que reportaba: "se borra al cerrar").
            self.saveHistory()
            self.isActive = false
            self.networkSnapshotEnd = Self.captureNetworkSnapshot()

            // Write full block to log file
            self.writeTransitionToLog()
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
    }

    /// Whether the last audit detected stuck filters (non-neutral values).
    var lastAuditFailed = false
    var lastAuditDetails = ""

    /// Pending audits to be flushed to log on next writeTransitionToLog or standalone.
    private var pendingAudits: [String] = []

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
            self.pendingAudits.append(line)

            if !self.isActive {
                self.flushAuditsToLog()
            }
        }
    }

    /// Flush pending audits to the log file.
    private func flushAuditsToLog() {
        guard !pendingAudits.isEmpty else { return }
        var block = "\n  ── POST-RESET AUDITS ──\n"
        for audit in pendingAudits {
            block += audit + "\n"
        }
        block += "\n"
        pendingAudits.removeAll()
        appendToLog(block)
    }

    // MARK: - Log file

    private func writeTransitionToLog() {
        let ts = ISO8601DateFormatter().string(from: Date())
        var block = """
        ═══════════════════════════════════════════════════════════
        [\(ts)] \(transitionType)
        REASON: \(transitionReason.isEmpty ? "N/A" : transitionReason)
        FROM: \(currentTitle)
        TO:   \(nextTitle)

        TIMING:
          fade=\(String(format: "%.1f", fadeDuration))s  entry=\(String(format: "%.1f", entryPoint))s  offset=\(String(format: "%.1f", startOffset))s  anticipation=\(String(format: "%.1f", anticipationTime))s

        FILTERS:
          enabled=\(filtersEnabled)  preset=\(filterPreset)
          midScoop=\(useMidScoop)  hiShelfCut=\(useHighShelfCut)  skipBFilters=\(skipBFilters)
          bassKill=\(useBassKill)  dynamicQ=\(useDynamicQ)  notchSweep=\(useNotchSweep)  stutterCut=\(useStutterCut)
          bRapidFadeIn=\(bRapidFadeIn)  tier4Active=\(tier4Active)

        ANALYSIS:
          energyA=\(String(format: "%.2f", energyA))  energyB=\(String(format: "%.2f", energyB))  danceability=\(String(format: "%.2f", danceability))
          outroInstrumental=\(isOutroInstrumental)  introInstrumental=\(isIntroInstrumental)
          outroStartA=\(String(format: "%.1f", outroStartA))s  introEndB=\(String(format: "%.1f", introEndB))s  vocalStartB=\(String(format: "%.1f", vocalStartB))s  chorusStartB=\(String(format: "%.1f", chorusStartB))s  introVocalsB=\(hasIntroVocalsB)

        BEAT SYNC:
          hasBeatData=\(isBeatSynced)  info=\(beatSyncInfo)
          bpmA=\(String(format: "%.1f", bpmA))  bpmB=\(String(format: "%.1f", bpmB))  diff=\(String(format: "%.1f", abs(bpmA - bpmB)))

        TIME STRETCH:
          enabled=\(useTimeStretch)  rateA=\(String(format: "%.3f", rateA))  rateB=\(String(format: "%.3f", rateB))

        REPLAY GAIN:
          rgA=\(String(format: "%.3f", replayGainA))  rgB=\(String(format: "%.3f", replayGainB))

        """

        // Environment snapshot (start vs end)
        if let s = networkSnapshotStart {
            block += "\n  ENVIRONMENT (start):\n"
            block += "    route=\(s.audioRoute)  bluetooth=\(s.isBluetoothActive)  carplay=\(s.isCarPlayActive)\n"
            block += "    appState=\(s.appState)  ioBuffer=\(String(format: "%.1f", s.ioBufferDuration * 1000))ms  sampleRate=\(String(format: "%.0f", s.sampleRate))Hz  outputLatency=\(String(format: "%.1f", s.outputLatency * 1000))ms\n"
        }
        if let e = networkSnapshotEnd {
            block += "  ENVIRONMENT (end):\n"
            block += "    route=\(e.audioRoute)  bluetooth=\(e.isBluetoothActive)  carplay=\(e.isCarPlayActive)\n"
            block += "    appState=\(e.appState)  ioBuffer=\(String(format: "%.1f", e.ioBufferDuration * 1000))ms  sampleRate=\(String(format: "%.0f", e.sampleRate))Hz  outputLatency=\(String(format: "%.1f", e.outputLatency * 1000))ms\n"
            // Flag route change during crossfade
            if let s = networkSnapshotStart, s.audioRoute != e.audioRoute {
                block += "    ⚠️ ROUTE CHANGED DURING CROSSFADE: \(s.audioRoute) → \(e.audioRoute)\n"
            }
            if let s = networkSnapshotStart, s.appState != e.appState {
                block += "    ⚠️ APP STATE CHANGED DURING CROSSFADE: \(s.appState) → \(e.appState)\n"
            }
        }

        block += "\n  AUTOMATION TICKS (\(pendingTicks.count) samples):\n"

        for tick in pendingTicks {
            block += tick + "\n"
        }
        block += "\n"

        // Include any post-reset audits that arrived before or at completion
        if !pendingAudits.isEmpty {
            block += "  ── POST-RESET AUDITS ──\n"
            for audit in pendingAudits {
                block += audit + "\n"
            }
            block += "\n"
            pendingAudits.removeAll()
        }

        appendToLog(block)
    }

    private nonisolated func appendToLog(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: logFileURL, options: .atomic)
        }
    }

    /// Read the full log file contents.
    func readLog() -> String {
        (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? "(empty log)"
    }

    /// Clear the log file.
    func clearLog() {
        let header = "# Audiorr Transition Diagnostics Log\n# Cleared: \(ISO8601DateFormatter().string(from: Date()))\n\n"
        try? header.write(to: logFileURL, atomically: true, encoding: .utf8)
        history.removeAll()
    }

    /// Delete the log file entirely from disk.
    func deleteLog() {
        try? FileManager.default.removeItem(at: logFileURL)
        history.removeAll()
    }

    /// Log file size in bytes (0 if missing).
    var logFileSize: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: logFileURL.path)[.size] as? Int64) ?? 0
    }

    /// Copy log contents to clipboard.
    func copyLogToClipboard() {
        UIPasteboard.general.string = readLog()
    }

    /// Append a raw line to the diagnostics log (for nuclear reconnect events, etc.)
    /// nonisolated because this is called from automationQueue and other non-main contexts.
    nonisolated func logEvent(_ text: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        appendToLog("[\(timestamp)] \(text)\n")
    }

    /// Update backend status.
    func updateBackendStatus(connected: Bool, url: String) {
        backendConnected = connected
        backendURL = url
        lastHealthCheck = Date()
    }
}
