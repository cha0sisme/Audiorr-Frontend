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

    private var isGrid: Bool { axis == .grid }
    private var titleColor: Color {
        guard let isLight else { return .primary }
        return isLight ? .black : .white
    }
    private var subtitleColor: Color {
        guard let isLight else { return .secondary }
        return isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.55)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlaylistCoverView(playlist: playlist, size: isGrid ? .infinity : size)
                .if(isGrid) { $0.aspectRatio(1, contentMode: .fit) }
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                .if(heroNamespace != nil) { $0.matchedGeometryEffect(id: "cover_\(playlist.id)", in: heroNamespace!) }

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(2)
                    .frame(maxWidth: isGrid ? .infinity : size, alignment: .leading)

                Text("\(playlist.songCount) \(playlist.songCount == 1 ? "cancion" : "canciones")")
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

