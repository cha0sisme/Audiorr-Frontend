import SwiftUI

/// Panel de cola presentado como sheet desde el Now Playing viewer.
struct QueuePanelView: View {
    private var state = NowPlayingState.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if state.queue.isEmpty {
                emptyState
            } else {
                queueList
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .preferredColorScheme(.dark)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.2))
            Text("Cola vacía")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Queue List

    private var queueList: some View {
        let currentIndex = state.queue.firstIndex(where: { $0.id == state.songId })

        return List {
            // Currently playing
            if let idx = currentIndex {
                Section {
                    queueRow(song: state.queue[idx], isCurrent: true)
                        .listRowBackground(Color.white.opacity(0.08))
                } header: {
                    Text("Reproduciendo")
                        .foregroundStyle(.white.opacity(0.5))
                }

                // Upcoming songs
                let upcoming = Array(state.queue.suffix(from: idx + 1))
                if !upcoming.isEmpty {
                    Section {
                        ForEach(upcoming) { song in
                            queueRow(song: song, isCurrent: false)
                                .listRowBackground(Color.clear)
                        }
                        .onDelete { offsets in
                            deleteUpcoming(offsets: offsets, currentIndex: idx)
                        }
                        .onMove { source, destination in
                            moveUpcoming(source: source, destination: destination, currentIndex: idx)
                        }
                    } header: {
                        HStack {
                            Text("A continuación")
                                .foregroundStyle(.white.opacity(0.5))
                            Spacer()
                            Button("Limpiar") {
                                clearUpcoming(currentIndex: idx)
                            }
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
            } else {
                // No current song found — show all
                Section {
                    ForEach(state.queue) { song in
                        queueRow(song: song, isCurrent: false)
                            .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(.active))
    }

    // MARK: - Queue Row

    private func queueRow(song: QueueSong, isCurrent: Bool) -> some View {
        Button {
            guard !isCurrent else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            JSBridge.shared.send("_nativeQueuePlay", detail: "{ songId: \"\(song.id)\" }")
        } label: {
            HStack(spacing: 12) {
                // Cover art
                if let url = NavidromeService.shared.coverURL(id: song.coverArt, size: 80) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            coverPlaceholder
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    coverPlaceholder
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                // Song info
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.subheadline.weight(isCurrent ? .bold : .regular))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(song.artist)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer()

                // Duration
                Text(formatDuration(song.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))

                // Now playing indicator
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func deleteUpcoming(offsets: IndexSet, currentIndex: Int) {
        var q = state.queue
        let upcomingStart = currentIndex + 1
        let indicesToRemove = offsets.map { upcomingStart + $0 }
        q.removeAll { song in indicesToRemove.contains(state.queue.firstIndex(where: { $0.id == song.id }) ?? -1) }
        state.queue = q
    }

    private func moveUpcoming(source: IndexSet, destination: Int, currentIndex: Int) {
        var upcoming = Array(state.queue.suffix(from: currentIndex + 1))
        upcoming.move(fromOffsets: source, toOffset: destination)
        let kept = Array(state.queue.prefix(through: currentIndex))
        state.queue = kept + upcoming
    }

    private func clearUpcoming(currentIndex: Int) {
        state.queue = Array(state.queue.prefix(through: currentIndex))
    }

    // MARK: - Helpers

    private var coverPlaceholder: some View {
        ZStack {
            Color(.secondarySystemFill)
            Image(systemName: "music.note")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
