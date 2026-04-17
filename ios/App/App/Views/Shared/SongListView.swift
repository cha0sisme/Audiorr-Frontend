import SwiftUI

// MARK: - Shared song list (Apple Music style)

/// Reusable song table used by AlbumDetailView, PlaylistDetailView, etc.
/// Handles playback, row dividers, and the ··· context menu.
/// Set `showAlbumInMenu: false` when already inside an album page.
///
/// Layout notes:
/// - Each row's width is hard-pinned to `UIScreen.main.bounds.width` via a
///   fixed `.frame(width:)` — `containerRelativeFrame` proved unreliable.
/// - The row content and the `···` menu live in a flat `HStack` so their
///   gesture recognisers are completely independent — no overlap, no delay.
struct SongListView: View {
    let songs: [NavidromeSong]
    let palette: AlbumPalette
    var showAlbumInMenu: Bool = true
    var showArtist: Bool = true

    @State private var navAlbum:  NavidromeAlbum?  = nil
    @State private var navArtist: NavidromeArtist? = nil

    private var isLight: Bool { palette.isPrimaryLight }

    /// Device screen width. iPhone-only app, portrait: this equals the
    /// ScrollView's viewport width. Used to hard-clamp every row so content
    /// (long titles, etc.) cannot expand the row beyond the viewport.
    private var screenWidth: CGFloat {
        UIScreen.main.bounds.width
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                rowView(for: song, at: idx)
                    .frame(width: screenWidth)

                if idx < songs.count - 1 {
                    Divider()
                        .background(
                            isLight ? Color.black.opacity(0.07) : Color.white.opacity(0.07)
                        )
                        .padding(.leading, 58)
                        .padding(.trailing, 16)
                        .frame(width: screenWidth)
                }
            }
        }
        .frame(width: screenWidth)
        // Navigation driven by Button state — avoids NavigationLink-inside-Menu bug
        .navigationDestination(item: $navAlbum)  { album  in AlbumDetailView(album: album) }
        .navigationDestination(item: $navArtist) { artist in ArtistDetailView(artist: artist) }
    }

    // MARK: - Row

    @ViewBuilder
    private func rowView(for song: NavidromeSong, at idx: Int) -> some View {
        HStack(spacing: 0) {
            SongRowView(song: song, index: idx + 1, palette: palette, showArtist: showArtist)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    PlayerService.shared.playPlaylist(songs, startingAt: idx)
                }

            menuButton(for: song)
                .frame(width: 48)
        }
    }

    // MARK: - ··· menu button

    @ViewBuilder
    private func menuButton(for song: NavidromeSong) -> some View {
        let textColor: Color = isLight ? Color.black.opacity(0.30) : Color.white.opacity(0.45)

        Menu {
            Button {
                PlayerService.shared.insertNext(song)
            } label: {
                Label("Reproducir a continuación", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                PlayerService.shared.addToQueue(song)
            } label: {
                Label("Añadir a la cola", systemImage: "text.badge.plus")
            }

            if showAlbumInMenu, let albumId = song.albumId, !albumId.isEmpty {
                Divider()
                Button {
                    navAlbum = NavidromeAlbum(
                        id: albumId, name: song.album, artist: song.artist,
                        coverArt: song.coverArt, songCount: nil, duration: nil,
                        year: song.year, genre: song.genre, explicitStatus: nil
                    )
                } label: {
                    Label("Ir al álbum", systemImage: "music.note")
                }
            }

            if let artistId = song.artistId, !artistId.isEmpty {
                Divider()
                Button {
                    navArtist = NavidromeArtist(id: artistId, name: song.artist, albumCount: nil)
                } label: {
                    Label("Ir al artista", systemImage: "person.crop.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(textColor)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .tint(.primary)
    }
}

// MARK: - Row view

private struct SongRowView: View {
    let song: NavidromeSong
    let index: Int
    let palette: AlbumPalette
    var showArtist: Bool = true

    private var isLight: Bool { palette.isPrimaryLight }
    private var primaryText:   Color { isLight ? .black                  : .white }
    private var secondaryText: Color { isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.60) }
    private var tertiaryText:  Color { isLight ? Color.black.opacity(0.30) : Color.white.opacity(0.45) }

    var body: some View {
        HStack(spacing: 14) {
            Text("\(index)")
                .font(.system(size: 15).monospacedDigit())
                .foregroundStyle(tertiaryText)
                .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(song.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if song.isExplicit {
                        ExplicitBadge(color: tertiaryText)
                    }
                }

                if showArtist {
                    Text(song.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let dur = song.duration, dur > 0 {
                Text(formatSeconds(dur))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(tertiaryText)
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, 10)
    }

    private func formatSeconds(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Explicit badge (Apple Music style)

struct ExplicitBadge: View {
    var color: Color = .secondary
    var size: CGFloat = 14

    var body: some View {
        Text("E")
            .font(.system(size: size * 0.64, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}
