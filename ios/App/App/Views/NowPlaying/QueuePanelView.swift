import SwiftUI

/// Panel de cola presentado como sheet desde el Now Playing viewer.
struct QueuePanelView: View {
    private var state = NowPlayingState.shared
    private var connect = ConnectService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if state.queue.isEmpty {
                    emptyState
                } else {
                    queueList
                }
            }
            .navigationTitle(L.queue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Empty

    private var emptyState: some View {
        ContentUnavailableView(
            L.emptyQueue,
            systemImage: "music.note.list",
            description: Text(L.noSongsInQueue)
        )
    }

    // MARK: - Queue List

    private var queueList: some View {
        let currentIndex = state.queue.firstIndex(where: { $0.id == state.songId })

        return List {
            // Remote banner
            if state.isRemote, let deviceName = state.remoteDeviceName {
                Section {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L.remoteQueue)
                                .font(.subheadline.weight(.semibold))
                            Text(L.playingOn(deviceName))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                    }
                }
            }

            // Currently playing
            if let idx = currentIndex {
                Section {
                    queueRow(song: state.queue[idx], isCurrent: true)
                } header: {
                    Text(L.nowPlaying)
                }

                // Upcoming songs
                let upcoming = Array(state.queue.suffix(from: idx + 1))
                if !upcoming.isEmpty {
                    Section {
                        ForEach(upcoming) { song in
                            queueRow(song: song, isCurrent: false)
                        }
                        .onDelete { offsets in
                            guard !state.isRemote else { return }
                            deleteUpcoming(offsets: offsets, currentIndex: idx)
                        }
                        .onMove { source, destination in
                            guard !state.isRemote else { return }
                            moveUpcoming(source: source, destination: destination, currentIndex: idx)
                        }
                    } header: {
                        HStack {
                            Text(L.upNext)
                            Spacer()
                            if !state.isRemote {
                                Button(L.clear) {
                                    clearUpcoming(currentIndex: idx)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
            } else {
                // No current song found — show all
                Section {
                    ForEach(state.queue) { song in
                        queueRow(song: song, isCurrent: false)
                    }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, state.isRemote ? .constant(.inactive) : .constant(.active))
    }

    // MARK: - Queue Row

    private func queueRow(song: QueueSong, isCurrent: Bool) -> some View {
        Button {
            guard !isCurrent else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

            if state.isRemote {
                // Remote: send command to play this song on the remote device
                connect.sendRemoteCommand(
                    action: "playFromQueue",
                    value: song.id,
                    targetDeviceId: nil
                )
            } else {
                // Local: play from this position
                if let idx = QueueManager.shared.queue.firstIndex(where: { $0.id == song.id }) {
                    QueueManager.shared.play(queue: QueueManager.shared.queue, startIndex: idx)
                }
            }
        } label: {
            HStack(spacing: 12) {
                // Cover art
                songCover(coverArt: song.coverArt)

                // Song info
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(song.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Duration
                Text(formatDuration(song.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                // Now playing indicator
                if isCurrent {
                    Image(systemName: state.isRemote ? "antenna.radiowaves.left.and.right" : "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(state.isRemote ? .green : .primary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cover

    private func songCover(coverArt: String) -> some View {
        CachedCoverThumbnail(coverArt: coverArt, size: 44)
    }

    // MARK: - Actions

    private func deleteUpcoming(offsets: IndexSet, currentIndex: Int) {
        let qm = QueueManager.shared
        // Map offsets in the "upcoming" sub-list to real queue indices (descending to preserve indices)
        let realIndices = offsets.map { currentIndex + 1 + $0 }.sorted(by: >)
        for idx in realIndices {
            qm.remove(at: idx)
        }
    }

    private func moveUpcoming(source: IndexSet, destination: Int, currentIndex: Int) {
        let qm = QueueManager.shared
        // Translate from upcoming-relative to absolute queue indices
        let realSource = IndexSet(source.map { currentIndex + 1 + $0 })
        let realDestination = currentIndex + 1 + destination
        qm.move(from: realSource, to: realDestination)
    }

    private func clearUpcoming(currentIndex: Int) {
        let qm = QueueManager.shared
        // Remove all songs after currentIndex (descending to preserve indices)
        for idx in stride(from: qm.queue.count - 1, through: currentIndex + 1, by: -1) {
            qm.remove(at: idx)
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
