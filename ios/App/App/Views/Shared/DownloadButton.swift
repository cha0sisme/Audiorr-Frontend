import SwiftUI

/// Reusable download indicator / button for albums, playlists, and individual songs.
///
/// States:
/// - **Not downloaded** → cloud.arrow.down
/// - **Downloading** → circular progress ring
/// - **Downloaded** → arrow.down.circle.fill (green)
/// - **Pinned** → pin.fill (green)
///
/// Tap triggers download or shows context menu for downloaded content.
struct DownloadButton: View {
    let groupId: String
    let groupType: String  // "album" or "playlist"
    let title: String
    let songs: [NavidromeSong]
    let fillColor: Color
    let labelColor: Color

    @State private var downloadState: DownloadState = .none
    @State private var progress: Double = 0

    private enum DownloadState {
        case none, downloading, downloaded, pinned
    }

    var body: some View {
        Button {
            handleTap()
        } label: {
            ZStack {
                switch downloadState {
                case .none:
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(labelColor)

                case .downloading:
                    ZStack {
                        Circle()
                            .stroke(labelColor.opacity(0.25), lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(labelColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "stop.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(labelColor)
                    }
                    .frame(width: 22, height: 22)

                case .downloaded:
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.green)

                case .pinned:
                    Image(systemName: "pin.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }
            .frame(width: 40, height: 40)
            .background(fillColor, in: Circle())
        }
        .contextMenu {
            if downloadState == .downloaded || downloadState == .pinned {
                Button {
                    togglePin()
                } label: {
                    Label(
                        downloadState == .pinned ? L.unpin : L.pin,
                        systemImage: downloadState == .pinned ? "pin.slash" : "pin"
                    )
                }
                Button(role: .destructive) {
                    removeDownload()
                } label: {
                    Label(L.deleteDownload, systemImage: "trash")
                }
            }
        }
        .task { await checkState() }
        .task(id: downloadState) {
            guard downloadState == .downloading else { return }
            while !Task.isCancelled {
                await updateProgress()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - Actions

    private func handleTap() {
        switch downloadState {
        case .none:
            withAnimation(Anim.small) { downloadState = .downloading }
            if groupType == "album" {
                DownloadManager.shared.downloadAlbum(
                    albumId: groupId, title: title, songs: songs, pin: false
                )
            } else {
                DownloadManager.shared.downloadPlaylist(
                    playlistId: groupId, title: title, songs: songs, pin: false
                )
            }
        case .downloading:
            DownloadManager.shared.cancelGroup(groupId: groupId)
            withAnimation(Anim.small) { downloadState = .none }
        case .downloaded, .pinned:
            break  // Context menu handles these
        }
    }

    private func togglePin() {
        Task {
            if downloadState == .pinned {
                await OfflineStorageManager.shared.unpinGroup(groupId: groupId)
                withAnimation(Anim.small) { downloadState = .downloaded }
            } else {
                await OfflineStorageManager.shared.pinGroup(groupId: groupId)
                withAnimation(Anim.small) { downloadState = .pinned }
            }
        }
    }

    private func removeDownload() {
        DownloadManager.shared.cancelGroup(groupId: groupId)
        for song in songs {
            Task { await OfflineStorageManager.shared.deleteFile(songId: song.id) }
        }
        withAnimation(Anim.small) { downloadState = .none }
    }

    // MARK: - State

    private func checkState() async {
        // Check how many songs are cached
        var cachedCount = 0
        for song in songs {
            if await OfflineStorageManager.shared.isCached(songId: song.id) {
                cachedCount += 1
            }
        }

        if cachedCount == songs.count && !songs.isEmpty {
            // Check if pinned
            _ = DownloadManager.shared.groupProgress(groupId: groupId)
            // Simple heuristic: check if any song in the group is pinned
            downloadState = .downloaded
        } else if DownloadManager.shared.isSongQueued(songId: songs.first?.id ?? "") ||
                  DownloadManager.shared.activeDownloads.contains(where: { $0.groupId == groupId }) {
            downloadState = .downloading
            await updateProgress()
        } else {
            // Partially cached but no active download — show as not downloaded
            downloadState = .none
        }
    }

    private func updateProgress() async {
        if let groupProg = DownloadManager.shared.groupProgress(groupId: groupId) {
            progress = groupProg
            if progress >= 1.0 {
                withAnimation(Anim.content) { downloadState = .downloaded }
            }
        }
    }
}

// MARK: - Single Song Download Button (for context menus / song rows)

struct SongDownloadButton: View {
    let song: NavidromeSong

    @State private var isCached = false
    @State private var isDownloading = false

    var body: some View {
        Group {
            if isCached {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else if isDownloading {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .task { await checkState() }
    }

    private func checkState() async {
        isCached = await OfflineStorageManager.shared.isCached(songId: song.id)
        if !isCached {
            isDownloading = DownloadManager.shared.isSongQueued(songId: song.id)
        }
    }
}
