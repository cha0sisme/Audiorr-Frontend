import SwiftUI

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

            // Volume bars
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Vol A").font(.caption).frame(width: 40, alignment: .leading)
                    ProgressView(value: Double(diag.volumeA), total: 1.0)
                        .tint(.red)
                    Text(String(format: "%.3f", diag.volumeA))
                        .font(.caption.monospacedDigit())
                        .frame(width: 50, alignment: .trailing)
                }
                HStack {
                    Text("Vol B").font(.caption).frame(width: 40, alignment: .leading)
                    ProgressView(value: Double(diag.volumeB), total: 1.0)
                        .tint(.green)
                    Text(String(format: "%.3f", diag.volumeB))
                        .font(.caption.monospacedDigit())
                        .frame(width: 50, alignment: .trailing)
                }
            }

            diagRow("Master Vol", value: String(format: "%.2f", diag.masterVolume))
            diagRow("HP Freq A", value: String(format: "%.0f Hz", diag.highpassFreqA))
            diagRow("HP Freq B", value: String(format: "%.0f Hz", diag.highpassFreqB))
            diagRow("Lowshelf A", value: String(format: "%.1f dB", diag.lowshelfGainA))
            diagRow("Lowshelf B", value: String(format: "%.1f dB", diag.lowshelfGainB))
            diagRow("Pan A", value: String(format: "%.3f", diag.panA))
            diagRow("Pan B", value: String(format: "%.3f", diag.panB))
        }
    }

    // MARK: - History

    private var historySection: some View {
        Section("History (last \(diag.history.count))") {
            ForEach(diag.history) { record in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(record.type)
                            .font(.caption.bold())
                            .foregroundStyle(typeColor(record.type))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(typeColor(record.type).opacity(0.15), in: Capsule())
                        Spacer()
                        Text(record.date, format: .dateTime.hour().minute().second())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text("\(record.fromTitle) → \(record.toTitle)")
                        .font(.caption)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Label(String(format: "%.1fs", record.fadeDuration), systemImage: "timer")
                        if record.beatSynced {
                            Label("Beat", systemImage: "metronome")
                                .foregroundStyle(.cyan)
                        }
                        if record.timeStretched {
                            Label("Stretch", systemImage: "waveform")
                                .foregroundStyle(.purple)
                        }
                        Label(record.filtersUsed, systemImage: "slider.horizontal.3")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Log file

    private var logFileSection: some View {
        Section("Log File") {
            diagRow("Path", value: diag.logFilePath)
            diagRow("Size", value: logFileSize)

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
        default:                 return .secondary
        }
    }

    private func presetColor(_ preset: String) -> Color {
        switch preset {
        case "aggressive":   return .red
        case "anticipation": return .purple
        case "energy-down":  return .blue
        case "normal":       return .green
        default:             return .secondary
        }
    }

    private func energyColor(_ energy: Double) -> Color {
        if energy > 0.7 { return .red }
        if energy > 0.4 { return .orange }
        return .green
    }
}
