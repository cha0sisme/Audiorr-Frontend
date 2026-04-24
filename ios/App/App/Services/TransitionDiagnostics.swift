import Foundation
import UIKit

/// Singleton observable que captura el estado de cada crossfade en tiempo real.
/// CrossfadeExecutor publica datos aquí; TransitionDiagnosticsView los muestra.
/// Persiste un log detallado en Documents/transition_diagnostics.log para debugging.
@MainActor @Observable
final class TransitionDiagnostics {

    /// When false, diagnostics data is not collected and the UI section is hidden.
    /// Set to true for internal debug builds only.
    nonisolated(unsafe) static var debugModeEnabled = false

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
    var skipBFilters = false

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
    var panA: Float = 0
    var panB: Float = 0
    var currentRateA: Float = 1.0

    // MARK: - History (last N transitions, in-memory for UI)

    struct TransitionRecord: Identifiable {
        let id = UUID()
        let date: Date
        let fromTitle: String
        let toTitle: String
        let type: String
        let fadeDuration: Double
        let filtersUsed: String
        let beatSynced: Bool
        let timeStretched: Bool
        let energyA: Double
        let energyB: Double
    }

    var history: [TransitionRecord] = []

    // MARK: - Backend status

    var backendConnected = false
    var backendURL = ""
    var lastHealthCheck: Date?

    // MARK: - Persistent log

    /// Path to the log file in Documents.
    var logFilePath: String { logFileURL.path }

    private let logFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("transition_diagnostics.log")
    }()

    /// Ticks collected during active crossfade, flushed on completion.
    private var pendingTicks: [String] = []

    // MARK: - Init

    private init() {
        // Write header on first launch if file doesn't exist
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            let header = "# Audiorr Transition Diagnostics Log\n# Format: human-readable, one block per transition\n# Generated automatically by TransitionDiagnostics\n\n"
            try? header.write(to: logFileURL, atomically: true, encoding: .utf8)
        }
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
        skipBFilters: Bool,
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
        replayGainB: Float
    ) {
        guard Self.debugModeEnabled else { return }
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
            self.skipBFilters = skipBFilters
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
            self.elapsed = 0
            self.volumeA = replayGainA
            self.volumeB = 0
            self.highpassFreqA = 0
            self.highpassFreqB = 0
            self.pendingTicks = []
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
        panA: Float,
        panB: Float,
        currentRateA: Float
    ) {
        guard Self.debugModeEnabled else { return }
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
            self.panA = panA
            self.panB = panB
            self.currentRateA = currentRateA

            // Buffer tick for log
            let label = filterTypeA == "lp" ? "lpA" : "hpA"
            let tick = String(format: "  t+%.1fs | volA=%.3f volB=%.3f master=%.2f | \(label)=%.0fHz hpB=%.0fHz | lsA=%.1fdB lsB=%.1fdB | panA=%.3f panB=%.3f | rateA=%.3f",
                              elapsed, volumeA, volumeB, masterVolume,
                              highpassFreqA, highpassFreqB,
                              lowshelfGainA, lowshelfGainB,
                              panA, panB, currentRateA)
            self.pendingTicks.append(tick)
        }
    }

    /// Called when crossfade completes. Archives into history and writes to log file.
    nonisolated func publishCompletion() {
        guard Self.debugModeEnabled else { return }
        Task { @MainActor in
            // Save to in-memory history
            let record = TransitionRecord(
                date: Date(),
                fromTitle: self.currentTitle,
                toTitle: self.nextTitle,
                type: self.transitionType,
                fadeDuration: self.fadeDuration,
                filtersUsed: self.filterPreset,
                beatSynced: self.isBeatSynced,
                timeStretched: self.useTimeStretch,
                energyA: self.energyA,
                energyB: self.energyB
            )
            self.history.insert(record, at: 0)
            if self.history.count > 50 { self.history.removeLast() }
            self.isActive = false

            // Write full block to log file
            self.writeTransitionToLog()
        }
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

        AUTOMATION TICKS (\(pendingTicks.count) samples):

        """

        for tick in pendingTicks {
            block += tick + "\n"
        }
        block += "\n"

        appendToLog(block)
    }

    private func appendToLog(_ text: String) {
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

    /// Copy log contents to clipboard.
    func copyLogToClipboard() {
        UIPasteboard.general.string = readLog()
    }

    /// Update backend status.
    func updateBackendStatus(connected: Bool, url: String) {
        backendConnected = connected
        backendURL = url
        lastHealthCheck = Date()
    }
}
