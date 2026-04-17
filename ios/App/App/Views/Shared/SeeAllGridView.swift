import SwiftUI

// MARK: - Navigation destination

/// Hashable value that drives `NavigationLink(value:)` → `SeeAllGridView`.
/// Wraps the title + items for each supported content type.
enum SeeAllDestination: Hashable {
    case albums(title: String, items: [NavidromeAlbum])
    case playlists(title: String, items: [NavidromePlaylist])
    case artists(title: String, items: [NavidromeArtist])

    var title: String {
        switch self {
        case .albums(let t, _):    return t
        case .playlists(let t, _): return t
        case .artists(let t, _):   return t
        }
    }
}

// MARK: - "Ver todo" pill shown at the end of a HorizontalScrollSection

/// Card appended as the last element in a horizontal row when there are more
/// items than the visible limit. Tapping navigates to `SeeAllGridView`.
struct SeeAllCard: View {
    let remaining: Int
    /// `nil` uses system colors; `true`/`false` for palette-driven pages.
    var isLight: Bool? = nil
    /// Match the height of the sibling cells (albums = 150, artists = 120).
    var size: CGFloat = 150

    private var bg: Color {
        guard let isLight else { return Color(.tertiarySystemFill) }
        return isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.10)
    }
    private var fg: Color {
        guard let isLight else { return .secondary }
        return isLight ? Color.secondary : Color.white.opacity(0.70)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(bg)

                VStack(spacing: 6) {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(fg)

                    Text("+\(remaining)")
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .foregroundStyle(fg)
                }
            }
            .frame(width: size, height: size)

            Text("Ver todo")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(fg)
                .frame(width: size, alignment: .center)
        }
    }
}

/// Round variant for artist sections.
struct SeeAllArtistCard: View {
    let remaining: Int
    /// `nil` uses system colors; `true`/`false` for palette-driven pages.
    var isLight: Bool? = nil
    var size: CGFloat = 120

    private var bg: Color {
        guard let isLight else { return Color(.tertiarySystemFill) }
        return isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.10)
    }
    private var fg: Color {
        guard let isLight else { return .secondary }
        return isLight ? Color.secondary : Color.white.opacity(0.70)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(bg)

                VStack(spacing: 4) {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(fg)
                    Text("+\(remaining)")
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundStyle(fg)
                }
            }
            .frame(width: size, height: size)

            Text("Ver todo")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(fg)
                .frame(width: size)
        }
    }
}

// MARK: - Full-screen grid view

struct SeeAllGridView: View {
    let destination: SeeAllDestination

    private let albumColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]
    private let artistColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            switch destination {
            case .albums(_, let items):
                LazyVGrid(columns: albumColumns, spacing: 20) {
                    ForEach(items) { album in
                        NavigationLink(value: album) {
                            AlbumCardView(album: album, axis: .grid)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)

            case .playlists(_, let items):
                LazyVGrid(columns: albumColumns, spacing: 20) {
                    ForEach(items) { playlist in
                        NavigationLink(value: playlist) {
                            PlaylistCardView(playlist: playlist, axis: .grid)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)

            case .artists(_, let items):
                LazyVGrid(columns: artistColumns, spacing: 24) {
                    ForEach(items) { artist in
                        NavigationLink(value: artist) {
                            ArtistCardView(artist: artist, size: 110)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }

            Spacer(minLength: 120)
        }
        .navigationTitle(destination.title)
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: NavidromeAlbum.self) { AlbumDetailView(album: $0) }
        .navigationDestination(for: NavidromePlaylist.self) { PlaylistDetailView(playlist: $0) }
        .navigationDestination(for: NavidromeArtist.self) { ArtistDetailView(artist: $0) }
    }
}

