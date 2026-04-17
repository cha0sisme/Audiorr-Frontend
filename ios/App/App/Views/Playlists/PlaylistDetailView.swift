import SwiftUI

// MARK: - View Model

@MainActor
final class PlaylistDetailViewModel: ObservableObject {
    @Published var songs: [NavidromeSong] = []
    @Published var playlist: NavidromePlaylist?
    @Published var isLoading = true
    @Published var palette: AlbumPalette = .default
    @Published var coverImage: UIImage?

    private let api = NavidromeService.shared
    let initialPlaylist: NavidromePlaylist

    init(playlist: NavidromePlaylist) {
        self.initialPlaylist = playlist
        self.playlist = playlist
    }

    var displayPlaylist: NavidromePlaylist { playlist ?? initialPlaylist }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        async let songsTask = api.getPlaylistSongs(playlistId: initialPlaylist.id)
        async let imageTask = fetchCover()

        let (songsResult, image) = await (try? songsTask, imageTask)

        if let (pl, songs) = songsResult {
            self.songs = songs
            if let pl { self.playlist = pl }
        }

        if let image {
            self.coverImage = image
            let extracted = await Task.detached(priority: .userInitiated) {
                ColorExtractor.extract(from: image)
            }.value
            self.palette = extracted
        }
    }

    /// Backend cover first, Navidrome as fallback — mirrors PlaylistCoverView logic.
    private func fetchCover() async -> UIImage? {
        // 1. Try backend generated cover
        if let backendURL = api.playlistBackendCoverURL(playlistId: initialPlaylist.id),
           let (data, _) = try? await URLSession.shared.data(from: backendURL),
           let img = UIImage(data: data) {
            return img
        }
        // 2. Navidrome getCoverArt fallback
        if let naviURL = api.coverURL(id: initialPlaylist.coverArt, size: 600),
           let (data, _) = try? await URLSession.shared.data(from: naviURL),
           let img = UIImage(data: data) {
            return img
        }
        return nil
    }
}

// MARK: - Main View

struct PlaylistDetailView: View {
    @StateObject private var vm: PlaylistDetailViewModel
    @State private var scrollY: CGFloat = 0

    private let heroHeight: CGFloat = 440

    init(playlist: NavidromePlaylist) {
        _vm = StateObject(wrappedValue: PlaylistDetailViewModel(playlist: playlist))
    }

    // MARK: Scroll-derived values

    private var scrollProgress: CGFloat { min(max(scrollY / heroHeight, 0), 1) }
    private var heroOpacity: CGFloat    { 1 - min(scrollProgress * 1.2, 0.92) }
    private var stickyOpacity: CGFloat  { min(max((scrollProgress - 0.55) / 0.25, 0), 1) }
    private var overscrollScale: CGFloat { 1 + max(0, -scrollY) / 900 }

    private var isLight: Bool { vm.palette.isPrimaryLight }
    private var pageBg: Color { Color(vm.palette.pageBackgroundColor) }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            pageBg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    heroSection
                    songListSection
                    Spacer(minLength: 120)
                }
                .frame(maxWidth: .infinity)
            }
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                scrollY = y
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(isLight ? .accentColor : .white)
        .task { await vm.load() }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(vm.displayPlaylist.name)
                    .font(.headline)
                    .foregroundStyle(isLight ? Color.black : .white)
                    .lineLimit(1)
                    .opacity(stickyOpacity)
            }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            // Background only gets the fade mask
            heroBackground
                .scaleEffect(overscrollScale, anchor: .top)
                .frame(height: heroHeight)
                .mask(alignment: .top) {
                    LinearGradient(
                        stops: [
                            .init(color: .black,               location: 0.00),
                            .init(color: .black,               location: 0.60),
                            .init(color: .black.opacity(0.85), location: 0.76),
                            .init(color: .black.opacity(0.40), location: 0.90),
                            .init(color: .clear,               location: 1.00)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .clipped()

            // Content sits above the masked background — no fade applied to it
            heroContent
                .opacity(heroOpacity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
        .clipped()
    }

    @ViewBuilder
    private var heroBackground: some View {
        if vm.palette.isSolid {
            Color(vm.palette.primary).ignoresSafeArea(edges: .top)
        } else {
            ZStack {
                if let img = vm.coverImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 55)
                        .scaleEffect(1.25)
                        .clipped()
                } else {
                    Color(vm.palette.primary)
                }

                LinearGradient(
                    colors: [
                        Color(vm.palette.primary).opacity(0.82),
                        Color(vm.palette.secondary).opacity(0.76)
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.38),
                        Color.black.opacity(0.22),
                        Color.black.opacity(0.06)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    private var heroContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 100)

            // Cover art — centered
            PlaylistCoverImage(playlist: vm.displayPlaylist, image: vm.coverImage)
                .frame(width: 190, height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.55), radius: 22, x: 0, y: 8)

            Spacer(minLength: 20)

            // Title + metadata — centered
            VStack(alignment: .center, spacing: 5) {
                Text(vm.displayPlaylist.name)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(isLight ? Color.black : .white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                metadataLine
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 20)

            // Play button — centered
            playButton
                .padding(.top, 18)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
    }

    private var metadataLine: some View {
        let textColor: Color = isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.75)
        let pl = vm.displayPlaylist
        var parts: [String] = []
        if pl.songCount > 0 { parts.append("\(pl.songCount) canciones") }
        if pl.duration > 0  { parts.append(formatDuration(pl.duration)) }
        if let owner = pl.owner, !owner.isEmpty { parts.append(owner) }

        return Text(parts.joined(separator: " · "))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(textColor)
            .lineLimit(1)
    }

    private var playButton: some View {
        let fillColor: Color  = Color(vm.palette.buttonFillColor)
        let labelColor: Color = vm.palette.buttonUsesBlackText ? .black : .white

        return Button {
            guard !vm.songs.isEmpty else { return }
            PlayerService.shared.playPlaylist(vm.songs)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "play.fill")
                Text("Reproducir")
                    .fontWeight(.semibold)
            }
            .font(.system(size: 15))
            .foregroundStyle(labelColor)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(fillColor, in: Capsule())
        }
        .disabled(vm.isLoading)
    }

    // MARK: - Song list

    private var songListSection: some View {
        Group {
            if vm.isLoading {
                ProgressView()
                    .tint(isLight ? .secondary : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
            } else {
                SongListView(songs: vm.songs, palette: vm.palette, showAlbumInMenu: true)
            }
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }
}

// MARK: - Playlist cover image (backend → Navidrome fallback)

/// Shows the pre-fetched UIImage if available (used in hero + sticky header).
/// Falls back to AsyncImage with the two-tier URL strategy when UIImage isn't ready yet.
struct PlaylistCoverImage: View {
    let playlist: NavidromePlaylist
    let image: UIImage?

    @State private var useBackend = true

    private var backendURL: URL? { NavidromeService.shared.playlistBackendCoverURL(playlistId: playlist.id) }
    private var navidromeURL: URL? { NavidromeService.shared.coverURL(id: playlist.coverArt, size: 600) }
    private var fallbackURL: URL? { useBackend ? (backendURL ?? navidromeURL) : navidromeURL }

    var body: some View {
        if let img = image {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            AsyncImage(url: fallbackURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    if useBackend && navidromeURL != nil {
                        Color.clear.onAppear { useBackend = false }
                    } else {
                        placeholderView
                    }
                default:
                    placeholderView
                }
            }
        }
    }

    private var placeholderView: some View {
        ZStack {
            Color(.tertiarySystemFill)
            Image(systemName: "music.note.list")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - PlaylistCoverView (grid thumbnail — PlaylistsView.swift)

/// Thumbnail variant used in the playlists grid.
/// Accepts an optional pre-loaded UIImage (nil for grid cells — loads via AsyncImage).
struct PlaylistCoverView: View {
    let playlist: NavidromePlaylist
    var size: CGFloat = 160

    @State private var useBackend = true

    private var isFlexible: Bool { size.isInfinite }
    private var cornerRadius: CGFloat { isFlexible ? 12 : size * 0.12 }

    private var backendURL: URL? { NavidromeService.shared.playlistBackendCoverURL(playlistId: playlist.id) }
    private var navidromeURL: URL? { NavidromeService.shared.coverURL(id: playlist.coverArt, size: isFlexible ? 300 : Int(size * 2)) }
    private var activeURL: URL? { useBackend ? (backendURL ?? navidromeURL) : navidromeURL }

    var body: some View {
        imageContent
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var imageContent: some View {
        let view = AsyncImage(url: activeURL) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFill()
            case .failure:
                if useBackend && navidromeURL != nil {
                    Color.clear.onAppear { useBackend = false }
                } else {
                    placeholder
                }
            default:
                placeholder
            }
        }

        if isFlexible {
            view
        } else {
            view.frame(width: size, height: size)
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(.tertiarySystemFill)
            Image(systemName: "music.note.list")
                .font(.system(size: isFlexible ? 40 : max(size * 0.3, 24)))
                .foregroundStyle(.secondary)
        }
    }
}
