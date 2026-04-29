import SwiftUI
import AVFoundation

/// Debug view showing real-time crossfade transition diagnostics.
/// Accessible from Settings for testing transitions, filters, beat sync, time stretch, etc.
struct TransitionDiagnosticsView: View {
    private let diag = TransitionDiagnostics.shared
    private let nowPlaying = NowPlayingState.shared

    var body: some View {
        List {
            // ── Backend ──
            backendSection

            // ── Current Playback ──
            currentPlaybackSection

            // ── Analysis Cache ──
            analysisCacheSection

            // ── Environment ──
            environmentSection

            // ── Active Transition ──
            if diag.isActive {
                activeTransitionSection
                filtersSection
                beatSyncSection
                timeStretchSection
                realTimeSection
            } else {
                Section("Transition") {
                    HStack {
                        Image(systemName: "waveform.slash")
                            .foregroundStyle(.secondary)
                        Text("No active crossfade")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // ── History ──
            if !diag.history.isEmpty {
                historySection
            }

            // ── Log file ──
            logFileSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        diag.copyLogToClipboard()
                        copiedFeedback = true
                    } label: {
                        Label("Copy Log", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        diag.clearLog()
                    } label: {
                        Label("Clear Log", systemImage: "trash")
                    }
                    Button(role: .destructive) {
                        diag.deleteLog()
                    } label: {
                        Label("Delete Log File", systemImage: "trash.slash")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .overlay {
            if copiedFeedback {
                copiedToast
            }
        }
        .task {
            let url = NavidromeService.shared.backendURL() ?? "N/A"
            diag.updateBackendStatus(
                connected: BackendState.shared.isAvailable,
                url: url
            )
        }
    }

    @State private var copiedFeedback = false

    private var copiedToast: some View {
        Text("Log copied to clipboard")
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.green.gradient, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { copiedFeedback = false }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
    }

    // MARK: - Backend

    private var backendSection: some View {
        Section("Audiorr Backend") {
            diagRow("Status", value: BackendState.shared.isAvailable ? "Connected" : "Disconnected",
                    color: BackendState.shared.isAvailable ? .green : .red)
            diagRow("URL", value: NavidromeService.shared.backendURL() ?? "N/A")

            if BackendState.shared.isChecking {
                HStack {
                    Text("Checking...")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }

            Button("Force Recheck") {
                BackendState.shared.invalidateAndRecheck()
            }

            // Hub / Connect
            diagRow("Hub", value: ConnectService.shared.hubConnected ? "Connected" : "Disconnected",
                    color: ConnectService.shared.hubConnected ? .green : .orange)
        }
    }

    // MARK: - Analysis Cache

    @State private var cacheActionFeedback: String?

    private var analysisCacheSection: some View {
        Section("Analysis Cache") {
            // Re-analyze the song currently playing — fixes cases where the backend
            // returned a bad BPM (double-time), wrong vocalStart, or stale data.
            // Next playback of this song will hit the backend fresh.
            // AnalysisCacheService is an actor; methods are async-isolated, so we
            // dispatch via Task and update UI state on completion.
            Button {
                let id = nowPlaying.songId
                let title = nowPlaying.title
                guard !id.isEmpty else {
                    cacheActionFeedback = "No song playing"
                    return
                }
                Task {
                    await AnalysisCacheService.shared.invalidate(songId: id)
                    await MainActor.run {
                        cacheActionFeedback = "Re-analysis queued for ‘\(title)’"
                    }
                }
            } label: {
                Label("Re-analyze Current Track", systemImage: "arrow.clockwise.circle")
            }
            .disabled(nowPlaying.songId.isEmpty)

            Button(role: .destructive) {
                Task {
                    await AnalysisCacheService.shared.invalidateAll()
                    await MainActor.run {
                        cacheActionFeedback = "All analysis cache cleared"
                    }
                }
            } label: {
                Label("Clear All Analysis Cache", systemImage: "trash")
            }

            if let feedback = cacheActionFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Current Playback

    private var currentPlaybackSection: some View {
        Section("Now Playing") {
            if nowPlaying.isVisible {
                diagRow("Song", value: nowPlaying.title)
                diagRow("Artist", value: nowPlaying.artist)
                diagRow("Progress", value: "\(formatTime(nowPlaying.progress)) / \(formatTime(nowPlaying.duration))")
                diagRow("State", value: nowPlaying.isPlaying ? "Playing" : "Paused",
                        color: nowPlaying.isPlaying ? .green : .orange)
                diagRow("Route", value: "\(nowPlaying.audioRouteName) (\(nowPlaying.audioRouteIcon))")
                diagRow("Crossfading", value: nowPlaying.isCrossfading ? "YES" : "No",
                        color: nowPlaying.isCrossfading ? .cyan : .secondary)
            } else {
                Text("Nothing playing")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Active Transition

    private var activeTransitionSection: some View {
        Section("Transition Decision") {
            diagRow("Type", value: diag.transitionType, color: typeColor(diag.transitionType))
            diagRow("From", value: diag.currentTitle)
            diagRow("To", value: diag.nextTitle)
            diagRow("Fade Duration", value: String(format: "%.1fs", diag.fadeDuration))
            diagRow("Entry Point", value: String(format: "%.1fs", diag.entryPoint))
            diagRow("Start Offset", value: String(format: "%.1fs", diag.startOffset))
            if diag.anticipationTime > 0 {
                diagRow("Anticipation", value: String(format: "%.1fs", diag.anticipationTime), color: .purple)
            }
            diagRow("Energy A", value: String(format: "%.2f", diag.energyA), color: energyColor(diag.energyA))
            diagRow("Energy B", value: String(format: "%.2f", diag.energyB), color: energyColor(diag.energyB))
            diagRow("Danceability", value: String(format: "%.2f", diag.danceability))
            diagRow("Outro Instrumental", value: diag.isOutroInstrumental ? "Yes" : "No")
            diagRow("Intro Instrumental", value: diag.isIntroInstrumental ? "Yes" : "No")
            diagRow("ReplayGain A", value: String(format: "%.3f", diag.replayGainA))
            diagRow("ReplayGain B", value: String(format: "%.3f", diag.replayGainB))
        }
    }

    // MARK: - Filters

    private var filtersSection: some View {
        Section("Filters") {
            diagRow("Enabled", value: diag.filtersEnabled ? "YES" : "NO",
                    color: diag.filtersEnabled ? .green : .red)
            diagRow("Preset", value: diag.filterPreset, color: presetColor(diag.filterPreset))
            diagRow("Mid Scoop (vocal)", value: diag.useMidScoop ? "ACTIVE" : "Off",
                    color: diag.useMidScoop ? .orange : .secondary)
            diagRow("Hi-Shelf Cut", value: diag.useHighShelfCut ? "ACTIVE" : "Off",
                    color: diag.useHighShelfCut ? .orange : .secondary)
            diagRow("Bass Kill", value: diag.useBassKill ? "ACTIVE" : "Off",
                    color: diag.useBassKill ? .red : .secondary)
            diagRow("Dynamic Q (A+B)", value: diag.useDynamicQ ? "ACTIVE" : "Off",
                    color: diag.useDynamicQ ? .cyan : .secondary)
            diagRow("Notch Sweep (B)", value: diag.useNotchSweep ? "ACTIVE" : "Off",
                    color: diag.useNotchSweep ? .purple : .secondary)
            diagRow("Stutter Cut (A)", value: diag.useStutterCut ? "ACTIVE" : "Off",
                    color: diag.useStutterCut ? .orange : .secondary)
            diagRow("B Filters", value: diag.skipBFilters ? "SKIPPED" : "Active",
                    color: diag.skipBFilters ? .yellow : .green)
        }
    }

    // MARK: - Beat Sync

    private var beatSyncSection: some View {
        Section("Beat Sync") {
            diagRow("Beat Data", value: diag.isBeatSynced ? "YES" : "No",
                    color: diag.isBeatSynced ? .green : .secondary)
            if diag.bpmA > 0 {
                diagRow("BPM A", value: String(format: "%.1f", diag.bpmA))
            }
            if diag.bpmB > 0 {
                diagRow("BPM B", value: String(format: "%.1f", diag.bpmB))
            }
            if diag.bpmA > 0 && diag.bpmB > 0 {
                let diff = abs(diag.bpmA - diag.bpmB)
                diagRow("BPM Diff", value: String(format: "%.1f", diff),
                        color: diff < 3 ? .green : diff < 8 ? .yellow : .red)
            }
            if !diag.beatSyncInfo.isEmpty {
                diagRow("Info", value: diag.beatSyncInfo)
            }
        }
    }

    // MARK: - Time Stretch

    private var timeStretchSection: some View {
        Section("Time Stretch") {
            diagRow("Enabled", value: diag.useTimeStretch ? "YES" : "No",
                    color: diag.useTimeStretch ? .cyan : .secondary)
            if diag.useTimeStretch {
                diagRow("Target Rate A", value: String(format: "%.3f", diag.rateA))
                diagRow("Target Rate B", value: String(format: "%.3f", diag.rateB))
                diagRow("Current Rate A", value: String(format: "%.3f", diag.currentRateA),
                        color: diag.currentRateA != 1.0 ? .cyan : .secondary)
            }
        }
    }

    // MARK: - Real-time

    private var realTimeSection: some View {
        Section("Real-time (1Hz)") {
            diagRow("Elapsed", value: String(format: "%.1fs / %.1fs", diag.elapsed, diag.fadeDuration))

            // Volume bars — plain rectangles, no ProgressView animation
            VStack(alignment: .leading, spacing: 4) {
                volumeBar(label: "Vol A", value: diag.volumeA, color: .red)
                volumeBar(label: "Vol B", value: diag.volumeB, color: .green)
            }

            diagRow("Master Vol", value: String(format: "%.2f", diag.masterVolume))
            diagRow("HP Freq A", value: String(format: "%.0f Hz", diag.highpassFreqA))
            diagRow("HP Freq B", value: String(format: "%.0f Hz", diag.highpassFreqB))
            if diag.useDynamicQ {
                diagRow("Q-A (Dynamic)", value: String(format: "%.2f", diag.dynamicQA),
                        color: diag.dynamicQA > 2.0 ? .cyan : .secondary)
                diagRow("Q-B (Twin)", value: String(format: "%.2f", diag.dynamicQB),
                        color: diag.dynamicQB > 2.0 ? .cyan : .secondary)
            }
            if diag.useNotchSweep {
                diagRow("Notch Freq B", value: String(format: "%.0f Hz", diag.notchFreqB),
                        color: .purple)
                diagRow("Notch Depth B", value: String(format: "%.1f dB", diag.notchGainB),
                        color: diag.notchGainB < -18 ? .purple : .secondary)
            }
            diagRow("Lowshelf A", value: String(format: "%.1f dB", diag.lowshelfGainA),
                    color: diag.useBassKill && diag.lowshelfGainA < -30 ? .red : .primary)
            diagRow("Lowshelf B", value: String(format: "%.1f dB", diag.lowshelfGainB))
            diagRow("Pan A", value: String(format: "%.3f", diag.panA))
            diagRow("Pan B", value: String(format: "%.3f", diag.panB))
        }
    }

    /// Static volume bar — no implicit animation, no AnimatablePair issues.
    private func volumeBar(label: String, value: Float, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(color.opacity(0.15))
                    Capsule()
                        .fill(color)
                        .frame(width: max(0, geo.size.width * CGFloat(min(1, max(0, value)))))
                }
            }
            .frame(height: 6)
            Text(String(format: "%.3f", value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }

    // MARK: - Environment

    private var environmentSection: some View {
        Section("Environment") {
            let session = AVAudioSession.sharedInstance()
            let route = session.currentRoute
            let outputName = route.outputs.first?.portName ?? "Unknown"
            let isBT = route.outputs.contains { [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0.portType) }
            let isCP = route.outputs.contains { $0.portType == .carAudio }

            diagRow("Audio Route", value: outputName)
            diagRow("Bluetooth", value: isBT ? "Active" : "No", color: isBT ? .blue : .secondary)
            diagRow("CarPlay", value: isCP ? "Active" : "No", color: isCP ? .green : .secondary)
            diagRow("IO Buffer", value: String(format: "%.1f ms", session.ioBufferDuration * 1000))
            diagRow("Sample Rate", value: String(format: "%.0f Hz", session.sampleRate))
            diagRow("Output Latency", value: String(format: "%.1f ms", session.outputLatency * 1000))

            if let snap = diag.networkSnapshotStart, diag.isActive {
                Divider()
                diagRow("Route at start", value: snap.audioRoute)
                diagRow("App state at start", value: snap.appState)
            }
        }
    }

    // MARK: - History

    private var historySection: some View {
        Section("History (last \(diag.history.count))") {
            ForEach(diag.history) { record in
                NavigationLink {
                    TransitionDetailView(record: record)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        // Row 1: Type + timestamp
                        HStack(alignment: .firstTextBaseline) {
                            Text(record.type)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(typeColor(record.type))
                            Text(String(format: "%.1fs", record.fadeDuration))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text(record.date, format: .dateTime.hour().minute().second())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.quaternary)
                        }

                        // Row 2: Song titles
                        Text("\(record.fromTitle) → \(record.toTitle)")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        // Row 3: Compact summary — colored text tokens, no icons
                        HStack(spacing: 4) {
                            historyToken(record.filterPreset, color: presetColor(record.filterPreset))
                            if record.beatSynced   { historyToken("beat", color: .cyan) }
                            if record.timeStretched { historyToken("stretch", color: .purple) }
                            if record.useBassKill   { historyToken("kill", color: .red) }
                            if record.useDynamicQ   { historyToken("dynQ", color: .teal) }
                            if record.useNotchSweep { historyToken("notch", color: .purple) }
                            if record.useStutterCut { historyToken("stutter", color: .orange) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// Minimal colored text token for history rows — no icons, no backgrounds.
    private func historyToken(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
    }

    // MARK: - Log file

    @State private var showShareSheet = false

    private var logFileSection: some View {
        Section("Log File") {
            diagRow("Path", value: diag.logFilePath)
            diagRow("Size", value: logFileSize)

            Button {
                showShareSheet = true
            } label: {
                Label("Export Log File", systemImage: "square.and.arrow.up")
            }
            .sheet(isPresented: $showShareSheet) {
                let url = URL(fileURLWithPath: diag.logFilePath)
                ShareSheet(activityItems: [url])
            }

            Button {
                diag.copyLogToClipboard()
                withAnimation { copiedFeedback = true }
            } label: {
                Label("Copy Full Log to Clipboard", systemImage: "doc.on.doc")
            }

            Button(role: .destructive) {
                diag.clearLog()
            } label: {
                Label("Clear Log", systemImage: "trash")
            }

            Button(role: .destructive) {
                diag.deleteLog()
            } label: {
                Label("Delete Log File", systemImage: "trash.slash")
            }
        }
    }

    private var logFileSize: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: diag.logFilePath),
              let size = attrs[.size] as? Int else { return "0 B" }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
        return String(format: "%.1f MB", Double(size) / (1024 * 1024))
    }

    // MARK: - Helpers

    private func diagRow(_ label: String, value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    private func formatTime(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "CROSSFADE":        return .blue
        case "EQ_MIX":           return .purple
        case "CUT":              return .red
        case "NATURAL_BLEND":    return .green
        case "BEAT_MATCH_BLEND": return .cyan
        case "CUT_A_FADE_IN_B":  return .orange
        case "FADE_OUT_A_CUT_B": return .yellow
        case "STEM_MIX":         return .mint
        case "DROP_MIX":         return .pink
        case "CLEAN_HANDOFF":    return .gray
        case "VINYL_STOP":       return .indigo
        default:                 return .secondary
        }
    }

    private func presetColor(_ preset: String) -> Color {
        switch preset {
        case "aggressive":     return .red
        case "anticipation":   return .purple
        case "energy-down":    return .blue
        case "gentle":         return .mint
        case "stem-mix":       return .teal
        case "drop-mix":       return .pink
        case "normal":         return .green
        case "clean-handoff":  return .gray
        default:               return .secondary
        }
    }

    private func energyColor(_ energy: Double) -> Color {
        if energy > 0.7 { return .red }
        if energy > 0.4 { return .orange }
        return .green
    }
}

// MARK: - Share Sheet

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Transition Detail View

struct TransitionDetailView: View {
    let record: TransitionDiagnostics.TransitionRecord

    var body: some View {
        List {
            // ── Decision ──
            Section("Decision") {
                row("Type", value: record.type, color: typeColor(record.type))
                row("Reason", value: record.transitionReason)
                row("From", value: record.fromTitle)
                row("To", value: record.toTitle)
                row("Time", value: record.date.formatted(.dateTime.month().day().hour().minute().second()))
            }

            // ── Timing ──
            Section("Timing") {
                row("Fade Duration", value: String(format: "%.1fs", record.fadeDuration))
                row("Entry Point", value: String(format: "%.1fs", record.entryPoint))
                row("Start Offset", value: String(format: "%.1fs", record.startOffset))
                if record.anticipationTime > 0 {
                    row("Anticipation", value: String(format: "%.1fs", record.anticipationTime), color: .purple)
                }
            }

            // ── Filters ──
            Section("Filters") {
                row("Enabled", value: record.filtersEnabled ? "YES" : "NO",
                    color: record.filtersEnabled ? .green : .red)
                row("Preset", value: record.filterPreset, color: presetColor(record.filterPreset))
                row("Mid Scoop", value: record.useMidScoop ? "ACTIVE" : "Off",
                    color: record.useMidScoop ? .orange : .secondary)
                row("Hi-Shelf Cut", value: record.useHighShelfCut ? "ACTIVE" : "Off",
                    color: record.useHighShelfCut ? .orange : .secondary)
                row("Bass Kill", value: record.useBassKill ? "ACTIVE" : "Off",
                    color: record.useBassKill ? .red : .secondary)
                row("Dynamic Q (A+B)", value: record.useDynamicQ ? "ACTIVE" : "Off",
                    color: record.useDynamicQ ? .cyan : .secondary)
                row("Notch Sweep (B)", value: record.useNotchSweep ? "ACTIVE" : "Off",
                    color: record.useNotchSweep ? .purple : .secondary)
                row("Stutter Cut (A)", value: record.useStutterCut ? "ACTIVE" : "Off",
                    color: record.useStutterCut ? .orange : .secondary)
                row("B Filters", value: record.skipBFilters ? "SKIPPED" : "Active",
                    color: record.skipBFilters ? .yellow : .green)
            }

            // ── Beat Sync ──
            Section("Beat Sync") {
                row("Beat Synced", value: record.beatSynced ? "YES" : "No",
                    color: record.beatSynced ? .green : .secondary)
                if record.bpmA > 0 {
                    row("BPM A", value: String(format: "%.1f", record.bpmA))
                }
                if record.bpmB > 0 {
                    row("BPM B", value: String(format: "%.1f", record.bpmB))
                }
                if record.bpmA > 0 && record.bpmB > 0 {
                    let diff = abs(record.bpmA - record.bpmB)
                    row("BPM Diff", value: String(format: "%.1f", diff),
                        color: diff < 3 ? .green : diff < 8 ? .yellow : .red)
                }
                if !record.beatSyncInfo.isEmpty {
                    row("Info", value: record.beatSyncInfo)
                }
            }

            // ── Time Stretch ──
            Section("Time Stretch") {
                row("Enabled", value: record.timeStretched ? "YES" : "No",
                    color: record.timeStretched ? .cyan : .secondary)
                if record.timeStretched {
                    row("Rate A", value: String(format: "%.3f", record.rateA))
                    row("Rate B", value: String(format: "%.3f", record.rateB))
                }
            }

            // ── Energy / Analysis ──
            Section("Analysis") {
                row("Energy A", value: String(format: "%.3f", record.energyA), color: energyColor(record.energyA))
                row("Energy B", value: String(format: "%.3f", record.energyB), color: energyColor(record.energyB))
                row("Danceability", value: String(format: "%.3f", record.danceability))
                row("Outro Instrumental", value: record.isOutroInstrumental ? "Yes" : "No",
                    color: record.isOutroInstrumental ? .cyan : .secondary)
                row("Intro Instrumental", value: record.isIntroInstrumental ? "Yes" : "No",
                    color: record.isIntroInstrumental ? .cyan : .secondary)
            }

            // ── ReplayGain ──
            Section("ReplayGain") {
                row("Track A", value: String(format: "%.3f", record.replayGainA))
                row("Track B", value: String(format: "%.3f", record.replayGainB))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Transition")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ label: String, value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "CROSSFADE":        return .blue
        case "EQ_MIX":           return .purple
        case "CUT":              return .red
        case "NATURAL_BLEND":    return .green
        case "BEAT_MATCH_BLEND": return .cyan
        case "CUT_A_FADE_IN_B":  return .orange
        case "FADE_OUT_A_CUT_B": return .yellow
        case "STEM_MIX":         return .mint
        case "DROP_MIX":         return .pink
        case "CLEAN_HANDOFF":    return .gray
        case "VINYL_STOP":       return .indigo
        default:                 return .secondary
        }
    }

    private func presetColor(_ preset: String) -> Color {
        switch preset {
        case "aggressive":     return .red
        case "anticipation":   return .purple
        case "energy-down":    return .blue
        case "gentle":         return .mint
        case "stem-mix":       return .teal
        case "drop-mix":       return .pink
        case "normal":         return .green
        case "clean-handoff":  return .gray
        default:               return .secondary
        }
    }

    private func energyColor(_ energy: Double) -> Color {
        if energy > 0.7 { return .red }
        if energy > 0.4 { return .orange }
        return .green
    }
}
