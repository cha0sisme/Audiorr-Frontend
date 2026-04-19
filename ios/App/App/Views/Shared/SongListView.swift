import SwiftUI
import UIKit

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
    var showArtistInMenu: Bool = true
    var showArtist: Bool = true
    var contextUri: String? = nil
    var contextName: String? = nil

    @State private var navAlbum:  NavidromeAlbum?  = nil
    @State private var navArtist: NavidromeArtist? = nil

    private var isLight: Bool { palette.isPrimaryLight }

    /// Device screen width — computed once and cached.
    private static let screenWidth: CGFloat = {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 390
    }()

    private var screenWidth: CGFloat { Self.screenWidth }

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
            Button {
                PlayerService.shared.playPlaylist(songs, startingAt: idx, contextUri: contextUri, contextName: contextName)
            } label: {
                SongRowView(song: song, index: idx + 1, palette: palette, showArtist: showArtist)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            menuButton(for: song)
        }
    }

    // MARK: - ··· menu button (UIKit — instant, no gesture delay)

    private func menuButton(for song: NavidromeSong) -> some View {
        let tint: UIColor = isLight
            ? UIColor.black.withAlphaComponent(0.30)
            : UIColor.white.withAlphaComponent(0.45)

        return InstantMenuButton(tint: tint) {
            // — Playback section
            let playNext = UIAction(
                title: "Reproducir a continuación",
                image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
            ) { _ in PlayerService.shared.insertNext(song) }

            let addQueue = UIAction(
                title: "Añadir a la cola",
                image: UIImage(systemName: "text.badge.plus")
            ) { _ in PlayerService.shared.addToQueue(song) }

            let playbackSection = UIMenu(title: "", options: .displayInline, children: [playNext, addQueue])

            // — Album section
            var sections: [UIMenuElement] = [playbackSection]

            if showAlbumInMenu, let albumId = song.albumId, !albumId.isEmpty {
                let goAlbum = UIAction(
                    title: "Ir al álbum",
                    image: UIImage(systemName: "music.note")
                ) { _ in
                    navAlbum = NavidromeAlbum(
                        id: albumId, name: song.album, artist: song.artist,
                        coverArt: song.coverArt, songCount: nil, duration: nil,
                        year: song.year, genre: song.genre, explicitStatus: nil
                    )
                }
                sections.append(UIMenu(title: "", options: .displayInline, children: [goAlbum]))
            }

            // — Artist section
            if showArtistInMenu, let artistId = song.artistId, !artistId.isEmpty {
                let goArtist = UIAction(
                    title: "Ir al artista",
                    image: UIImage(systemName: "person.crop.circle")
                ) { _ in
                    navArtist = NavidromeArtist(id: artistId, name: song.artist, albumCount: nil)
                }
                sections.append(UIMenu(title: "", options: .displayInline, children: [goArtist]))
            }

            return UIMenu(children: sections)
        }
        .frame(width: 48, height: 44)
    }
}

// MARK: - Row view

private struct SongRowView: View {
    let song: NavidromeSong
    let index: Int
    let palette: AlbumPalette
    var showArtist: Bool = true

    @State private var isCached = false
    private let nowPlaying = NowPlayingState.shared

    private var isLight: Bool { palette.isPrimaryLight }
    private var primaryText:   Color { isLight ? .black                  : .white }
    private var secondaryText: Color { isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.60) }
    private var tertiaryText:  Color { isLight ? Color.black.opacity(0.30) : Color.white.opacity(0.45) }

    private var isCurrentSong: Bool { nowPlaying.isVisible && nowPlaying.songId == song.id }

    var body: some View {
        HStack(spacing: 14) {
            if isCurrentSong {
                NowPlayingIndicator(
                    isPlaying: nowPlaying.isPlaying,
                    color: isLight ? Color.black : Color.white,
                    barWidth: 2.5,
                    height: 12
                )
                .frame(width: 24)
            } else {
                Text("\(index)")
                    .font(.system(size: 15).monospacedDigit())
                    .foregroundStyle(tertiaryText)
                    .frame(width: 24, alignment: .trailing)
            }

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

            if isCached {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isLight ? Color.black.opacity(0.3) : Color.white.opacity(0.3))
            }

            if let dur = song.duration, dur > 0 {
                Text(formatSeconds(dur))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(tertiaryText)
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, 10)
        .task {
            isCached = await OfflineStorageManager.shared.isCached(songId: song.id)
        }
    }

    private func formatSeconds(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Instant ··· menu (UIKit, zero gesture delay)

/// Wraps a `UIButton` with `showsMenuAsPrimaryAction = true`.
/// The menu appears on first touch — no SwiftUI gesture disambiguation.
struct InstantMenuButton: UIViewRepresentable {
    let tint: UIColor
    let menuBuilder: () -> UIMenu

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        button.setImage(UIImage(systemName: "ellipsis", withConfiguration: config), for: .normal)
        button.showsMenuAsPrimaryAction = true
        button.tintColor = tint
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.menu = menuBuilder()
        button.tintColor = tint
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
