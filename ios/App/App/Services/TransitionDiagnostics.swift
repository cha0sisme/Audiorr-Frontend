import Foundation
import UIKit
import AVFoundation

/// Singleton observable que captura el estado de cada crossfade en tiempo real.
/// CrossfadeExecutor publica datos aquí; TransitionDiagnosticsView los muestra.
/// Persiste un log detallado en Documents/transition_diagnostics.log para debugging.
@MainActor @Observable
final class TransitionDiagnostics {

    /// When false, diagnostics data is not collected and detail views are hidden.
    /// The settings section itself is gated by BackendState.isAvailable.
    nonisolated(unsafe) static var debugModeEnabled = true

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

    struct TransitionRecord: Identifiable {
        let id = UUID()
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
        let skipBFilters: Bool
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
            self.useBassKill = useBassKill
            self.useDynamicQ = useDynamicQ
            self.useNotchSweep = useNotchSweep
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
        guard Self.debugModeEnabled else { return }
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
                skipBFilters: self.skipBFilters,
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
                replayGainB: self.replayGainB
            )
            self.history.insert(record, at: 0)
            if self.history.count > 50 { self.history.removeLast() }
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
        let source: String          // "completeCrossfade", "cancel", "cancel+150ms"
        let bandsA: [EQBandSnapshot]
        let bandsB: [EQBandSnapshot]
        var dspBandsA: [DSPBandSnapshot] = []
        var dspBandsB: [DSPBandSnapshot] = []
        let panA: Float
        let panB: Float
        let rateA: Float            // Swift property
        let rateB: Float            // Swift property
        var dspRateA: Float = 1.0   // AudioUnitGetParameter
        var dspRateB: Float = 1.0   // AudioUnitGetParameter
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
          bassKill=\(useBassKill)  dynamicQ=\(useDynamicQ)  notchSweep=\(useNotchSweep)

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
