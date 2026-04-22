import SwiftUI

/// Sheet to pick a private playlist and add the current song to it.
struct AddToPlaylistView: View {
    @Environment(\.dismiss) private var dismiss
    let songId: String
    let songTitle: String

    @State private var playlists: [NavidromePlaylist] = []
    @State private var isLoading = true
    @State private var addedTo: String?          // playlist name after success
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if playlists.isEmpty {
                    ContentUnavailableView(
                        L.noPlaylistsAvailable,
                        systemImage: "music.note.list",
                        description: Text(L.noPrivatePlaylists)
                    )
                } else {
                    List(playlists) { playlist in
                        Button {
                            addSong(to: playlist)
                        } label: {
                            HStack(spacing: 12) {
                                playlistCover(playlist)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Text(L.songCount(playlist.songCount))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if addedTo == playlist.name {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(L.addToPlaylist)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.close) { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.red, in: Capsule())
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await loadPlaylists() }
        .animation(Anim.small, value: addedTo)
        .animation(Anim.small, value: errorMessage)
    }

    // MARK: - Load

    private func loadPlaylists() async {
        playlists = await NavidromeService.shared.getUserPrivatePlaylists()
        isLoading = false
    }

    // MARK: - Add

    private func addSong(to playlist: NavidromePlaylist) {
        Task {
            do {
                try await NavidromeService.shared.addSongToPlaylist(
                    playlistId: playlist.id,
                    songId: songId
                )
                addedTo = playlist.name
                UINotificationFeedbackGenerator().notificationOccurred(.success)

                // Auto-dismiss after brief delay
                try? await Task.sleep(for: .seconds(1))
                dismiss()
            } catch {
                errorMessage = L.addToPlaylistError
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                try? await Task.sleep(for: .seconds(2))
                errorMessage = nil
            }
        }
    }

    // MARK: - Cover

    private func playlistCover(_ playlist: NavidromePlaylist) -> some View {
        CachedCoverThumbnail(coverArt: playlist.coverArt, size: 44)
    }
}
