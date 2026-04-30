import SwiftUI
import UIKit

// MARK: - Shared song list (Apple Music style)

/// Reusable song table used by AlbumDetailView, PlaylistDetailView, etc.
/// Handles playback, row dividers, and the ··· context menu.
/// Set `showAlbumInMenu: false` when already inside an album page.
///
/// Layout notes:
/// - Rows expand to fill the available width via `maxWidth: .infinity`.
/// - The row content and the `···` menu live in a flat `HStack` so their
///   gesture recognisers are completely independent — no overlap, no delay.
struct SongListView: View {
    let songs: [NavidromeSong]
    let palette: AlbumPalette
    var showAlbumInMenu: Bool = true
    var showArtistInMenu: Bool = true
    var showArtist: Bool = true
    var showCover: Bool = false
    var contextUri: String? = nil
    var contextName: String? = nil

    @State private var navAlbum:  NavidromeAlbum?  = nil
    @State private var navArtist: NavidromeArtist? = nil
    @State private var addToPlaylistSong: NavidromeSong? = nil

    private var isLight: Bool { palette.isPrimaryLight }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                rowView(for: song, at: idx)
                    .frame(maxWidth: .infinity)

                if idx < songs.count - 1 {
                    Divider()
                        .background(
                            isLight ? Color.black.opacity(0.07) : Color.white.opacity(0.07)
                        )
                        .padding(.leading, showCover ? 76 : 58)
                        .padding(.trailing, 16)
                }
            }
        }
        .frame(maxWidth: .infinity)
        // Navigation driven by Button state — avoids NavigationLink-inside-Menu bug
        .navigationDestination(item: $navAlbum)  { album  in AlbumDetailView(album: album) }
        .navigationDestination(item: $navArtist) { artist in ArtistDetailView(artist: artist) }
        .sheet(item: $addToPlaylistSong) { song in
            AddToPlaylistView(songId: song.id, songTitle: song.title)
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func rowView(for song: NavidromeSong, at idx: Int) -> some View {
        HStack(spacing: 0) {
            Button {
                PlayerService.shared.playPlaylist(songs, startingAt: idx, contextUri: contextUri, contextName: contextName)
            } label: {
                SongRowView(song: song, index: idx + 1, palette: palette, showArtist: showArtist, showCover: showCover)
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
                title: L.playNext,
                image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
            ) { _ in PlayerService.shared.insertNext(song) }

            let addQueue = UIAction(
                title: L.addToQueue,
                image: UIImage(systemName: "text.badge.plus")
            ) { _ in PlayerService.shared.addToQueue(song) }

            let playbackSection = UIMenu(title: "", options: .displayInline, children: [playNext, addQueue])

            // — Album section
            var sections: [UIMenuElement] = [playbackSection]

            if showAlbumInMenu, let albumId = song.albumId, !albumId.isEmpty {
                let goAlbum = UIAction(
                    title: L.goToAlbum,
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
                    title: L.goToArtist,
                    image: UIImage(systemName: "person.crop.circle")
                ) { _ in
                    navArtist = NavidromeArtist(id: artistId, name: song.artist, albumCount: nil)
                }
                sections.append(UIMenu(title: "", options: .displayInline, children: [goArtist]))
            }

            // — Add to playlist
            let addToPlaylist = UIAction(
                title: L.addToPlaylist,
                image: UIImage(systemName: "music.note.list")
            ) { _ in
                DispatchQueue.main.async {
                    addToPlaylistSong = song
                }
            }
            sections.append(UIMenu(title: "", options: .displayInline, children: [addToPlaylist]))

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
    var showCover: Bool = false

    private enum CacheState: Equatable {
        case none
        case downloading(Double)
        case cached
    }

    @State private var cacheState: CacheState = .none
    private let nowPlaying = NowPlayingState.shared

    private var isLight: Bool { palette.isPrimaryLight }
    private var primaryText:   Color { isLight ? .black                  : .white }
    private var secondaryText: Color { isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.60) }
    private var tertiaryText:  Color { isLight ? Color.black.opacity(0.30) : Color.white.opacity(0.45) }

    private var isCurrentSong: Bool { nowPlaying.isVisible && nowPlaying.songId == song.id }

    var body: some View {
        HStack(spacing: showCover ? 12 : 14) {
            if showCover {
                // Album cover thumbnail (Apple Music playlist style)
                ZStack(alignment: .center) {
                    CachedCoverThumbnail(coverArt: song.coverArt, size: 44, cornerRadius: 6)

                    if isCurrentSong {
                        // Overlay: dark scrim + equalizer
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 44, height: 44)
                        NowPlayingIndicator(
                            isPlaying: nowPlaying.isPlaying,
                            bpm: nowPlaying.currentBpm,
                            color: .white,
                            barWidth: 2.5,
                            height: 12
                        )
                    }
                }
                .frame(width: 44, height: 44)
            } else {
                if isCurrentSong {
                    NowPlayingIndicator(
                        isPlaying: nowPlaying.isPlaying,
                        bpm: nowPlaying.currentBpm,
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

            cacheIndicator

            if let dur = song.duration, dur > 0 {
                Text(formatSeconds(dur))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(tertiaryText)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, showCover ? 6 : 10)
        .task { await checkCacheState() }
        .task(id: cacheState) {
            // Poll while not yet cached: detect download start (none→downloading)
            // and track progress (downloading→cached). Cached songs stop polling.
            guard cacheState != .cached else { return }
            let interval: UInt64 = cacheState == .none ? 2_000_000_000 : 800_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                await checkCacheState()
            }
        }
    }

    // MARK: - Cache indicator (Apple-native micro animation)

    @ViewBuilder
    private var cacheIndicator: some View {
        switch cacheState {
        case .none:
            EmptyView()

        case .downloading(let progress):
            ZStack {
                Circle()
                    .stroke(tertiaryText.opacity(0.3), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tertiaryText, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            .transition(.scale(scale: 0.5).combined(with: .opacity))

        case .cached:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(isLight ? Color.black.opacity(0.3) : Color.white.opacity(0.3))
                .transition(.scale(scale: 0.1).combined(with: .opacity))
                .symbolEffect(.bounce, value: cacheState)
        }
    }

    // MARK: - State

    private func checkCacheState() async {
        let cached = await OfflineStorageManager.shared.isCached(songId: song.id)
        if cached {
            if cacheState != .cached {
                withAnimation(Anim.moderate) { cacheState = .cached }
            }
            return
        }

        if let progress = DownloadManager.shared.downloadProgress(songId: song.id) {
            withAnimation(Anim.micro) { cacheState = .downloading(progress) }
        } else if DownloadManager.shared.isSongQueued(songId: song.id) {
            withAnimation(Anim.micro) { cacheState = .downloading(0) }
        } else if cacheState != .none {
            withAnimation(Anim.small) { cacheState = .none }
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

    class Coordinator {
        var menuBuilder: () -> UIMenu
        init(menuBuilder: @escaping () -> UIMenu) {
            self.menuBuilder = menuBuilder
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(menuBuilder: menuBuilder)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        button.setImage(UIImage(systemName: "ellipsis", withConfiguration: config), for: .normal)
        button.showsMenuAsPrimaryAction = true
        button.tintColor = tint
        // Construir el menú de forma diferida: solo se ejecuta menuBuilder()
        // cuando el usuario abre el menú, no en cada re-render de SwiftUI.
        // Esto evita que las actualizaciones frecuentes de NowPlayingState (250ms)
        // reconstruyan el UIMenu constantemente y causen parpadeos en la UI.
        let coordinator = context.coordinator
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { completion in
                completion(coordinator.menuBuilder().children)
            }
        ])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.menuBuilder = menuBuilder
        button.tintColor = tint
    }
}

// MARK: - Song list skeleton (loading placeholder)

/// Mirrors SongListView's row layout while data is loading. Use the known
/// song count (e.g. `playlist.songCount`) so the scroll height matches the
/// final list and rows don't shift sideways when real songs arrive.
struct SongListSkeleton: View {
    let count: Int
    let palette: AlbumPalette
    var showCover: Bool = false
    var showArtist: Bool = true

    private var isLight: Bool { palette.isPrimaryLight }
    private var skeletonColor: Color {
        isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.10)
    }

    private static let titleWidths: [CGFloat]    = [180, 220, 150, 200, 165, 195, 175]
    private static let subtitleWidths: [CGFloat] = [110, 140, 95, 125, 100, 130]

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { idx in
                row(at: idx)
                    .frame(maxWidth: .infinity)

                if idx < count - 1 {
                    Divider()
                        .background(
                            isLight ? Color.black.opacity(0.07) : Color.white.opacity(0.07)
                        )
                        .padding(.leading, showCover ? 76 : 58)
                        .padding(.trailing, 16)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func row(at idx: Int) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: showCover ? 12 : 14) {
                if showCover {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(skeletonColor)
                        .frame(width: 44, height: 44)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(skeletonColor)
                        .frame(width: 14, height: 12)
                        .frame(width: 24, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(skeletonColor)
                        .frame(width: Self.titleWidths[idx % Self.titleWidths.count], height: 13)
                    if showArtist {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(skeletonColor)
                            .frame(width: Self.subtitleWidths[idx % Self.subtitleWidths.count], height: 11)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                RoundedRectangle(cornerRadius: 4)
                    .fill(skeletonColor)
                    .frame(width: 28, height: 11)
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .padding(.vertical, showCover ? 6 : 10)

            // Reserves the ··· menu width so the skeleton row's content area
            // matches SongListView's exactly — no horizontal jump on transition.
            Color.clear.frame(width: 48, height: 44)
        }
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
