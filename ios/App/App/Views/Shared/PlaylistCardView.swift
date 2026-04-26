import SwiftUI

// MARK: - Shared playlist card (Apple Music style)

/// Reusable playlist cell — cover art, title, song count.
/// Used in PlaylistsView (horizontal + grid), ArtistDetailView, SeeAllGridView.
///
/// Two variants via `axis`:
/// - `.horizontal`: fixed-width card for horizontal scroll rows.
/// - `.grid`: flexible width that fills its container (LazyVGrid).
struct PlaylistCardView: View {
    let playlist: NavidromePlaylist
    /// Pass `true` when the host page has a light background (palette-driven).
    /// When `nil`, standard system colors are used (PlaylistsView, SeeAllGridView).
    var isLight: Bool? = nil
    var axis: Axis = .horizontal
    var size: CGFloat = 150
    var heroNamespace: Namespace.ID?

    private let nowPlaying = NowPlayingState.shared

    private var isGrid: Bool { axis == .grid }
    private var titleColor: Color {
        guard let isLight else { return .primary }
        return isLight ? .black : .white
    }
    private var subtitleColor: Color {
        guard let isLight else { return .secondary }
        return isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.55)
    }

    private var isCurrentContext: Bool {
        nowPlaying.isVisible && nowPlaying.contextUri == "playlist:\(playlist.id)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                PlaylistCoverView(playlist: playlist, size: isGrid ? .infinity : size)
                    .if(isGrid) { $0.aspectRatio(1, contentMode: .fit) }
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                    .if(heroNamespace != nil) { $0.matchedTransitionSource(id: playlist.id, in: heroNamespace!) }

                if isCurrentContext {
                    NowPlayingIndicator(
                        isPlaying: nowPlaying.isPlaying,
                        bpm: nowPlaying.currentBpm,
                        color: Color.white,
                        barWidth: 3, height: 14
                    )
                    .padding(8)
                    .background(Material.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(2)
                    .frame(maxWidth: isGrid ? .infinity : size, alignment: .leading)

                Text(L.songCount(playlist.songCount))
                    .font(.system(size: 12))
                    .foregroundStyle(subtitleColor)
                    .frame(maxWidth: isGrid ? .infinity : size, alignment: .leading)
            }
        }
    }

    enum Axis {
        case horizontal, grid
    }
}

