import SwiftUI

// MARK: - View Model

@MainActor
final class AlbumDetailViewModel: ObservableObject {
    @Published var songs: [NavidromeSong] = []
    @Published var album: NavidromeAlbum?
    @Published var isLoading = true
    @Published var palette: AlbumPalette = .default
    @Published var coverImage: UIImage?

    private let api = NavidromeService.shared
    let initialAlbum: NavidromeAlbum

    init(album: NavidromeAlbum) {
        self.initialAlbum = album
        self.album = album
    }

    var displayAlbum: NavidromeAlbum { album ?? initialAlbum }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        // Fetch songs + cover image concurrently
        async let songsTask = api.getAlbumDetail(albumId: initialAlbum.id)
        async let imageTask = fetchCover()

        let (songsResult, image) = await (try? songsTask, imageTask)

        if let (al, songs) = songsResult {
            self.songs = songs
            if let al { self.album = al }
        }

        if let image {
            self.coverImage = image
            // Extract palette off the main thread
            let extracted = await Task.detached(priority: .userInitiated) {
                ColorExtractor.extract(from: image)
            }.value
            self.palette = extracted
        }
    }

    private func fetchCover() async -> UIImage? {
        guard let url = api.coverURL(id: initialAlbum.coverArt, size: 600) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - Main View

struct AlbumDetailView: View {
    @StateObject private var vm: AlbumDetailViewModel
    @State private var scrollY: CGFloat = 0

    private let heroHeight: CGFloat = 380

    init(album: NavidromeAlbum) {
        _vm = StateObject(wrappedValue: AlbumDetailViewModel(album: album))
    }

    // MARK: Scroll-derived values

    /// 0 at top → 1 when hero fully scrolled past
    private var scrollProgress: CGFloat { min(max(scrollY / heroHeight, 0), 1) }
    /// Hero content opacity
    private var heroOpacity: CGFloat { 1 - min(scrollProgress * 1.2, 0.92) }
    /// Sticky header opacity — fades in after 55% scroll
    private var stickyOpacity: CGFloat { min(max((scrollProgress - 0.55) / 0.25, 0), 1) }
    /// Overscroll scale (iOS bounce)
    private var overscrollScale: CGFloat { 1 + max(0, -scrollY) / 900 }

    private var isLight: Bool { vm.palette.isPrimaryLight }
    private var pageBg: Color { Color(vm.palette.pageBackgroundColor) }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            // Full-screen background fills behind nav bar + content
            pageBg.ignoresSafeArea()

            // Scrollable content
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    heroSection
                    songListSection
                    Spacer(minLength: 120) // mini-player clearance
                }
            }
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                scrollY = y
            }

            // Sticky header overlay
            stickyHeader
                .opacity(stickyOpacity)
                .animation(.linear(duration: 0.15), value: stickyOpacity)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(isLight ? .accentColor : .white)
        .task { await vm.load() }
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
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

            heroContent
                .opacity(heroOpacity)
        }
        .frame(height: heroHeight)
    }

    @ViewBuilder
    private var heroBackground: some View {
        if vm.palette.isSolid {
            Color(vm.palette.primary)
                .ignoresSafeArea(edges: .top)
        } else {
            ZStack {
                // Blurred artwork backdrop
                if let img = vm.coverImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 55)
                        .scaleEffect(1.25)     // prevent blur edges showing
                        .clipped()
                } else {
                    Color(vm.palette.primary)
                }

                // Gradient overlay at 140° (top-trailing → bottom-leading)
                LinearGradient(
                    colors: [
                        Color(vm.palette.primary).opacity(0.82),
                        Color(vm.palette.secondary).opacity(0.76)
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )

                // Dark scrim for legible text
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
            Spacer()

            // Cover art — centered
            coverArtImage
                .frame(width: 190, height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.55), radius: 22, x: 0, y: 8)

            Spacer(minLength: 20)

            // Title + metadata — left aligned
            VStack(alignment: .leading, spacing: 5) {
                Text(vm.displayAlbum.name)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(isLight ? Color.primary : .white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                metadataLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)

            // Play button — centered
            playButton
                .padding(.top, 18)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var coverArtImage: some View {
        if let img = vm.coverImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            // Placeholder while loading
            ZStack {
                Color(vm.palette.primary).opacity(0.4)
                Image(systemName: "music.note")
                    .font(.system(size: 52))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var metadataLine: some View {
        let textColor: Color = isLight ? .secondary : Color.white.opacity(0.75)
        let album = vm.displayAlbum
        var parts: [String] = [album.artist]
        if let year = album.year  { parts.append(String(year)) }
        if let genre = album.genre { parts.append(genre) }

        return Text(parts.joined(separator: " · "))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(textColor)
            .lineLimit(1)
    }

    private var playButton: some View {
        let fillColor  = Color(vm.palette.buttonFillColor)
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
                LazyVStack(spacing: 0) {
                    ForEach(Array(vm.songs.enumerated()), id: \.element.id) { idx, song in
                        Button {
                            PlayerService.shared.playPlaylist(vm.songs, startingAt: idx)
                        } label: {
                            AlbumSongRow(song: song, index: idx + 1, palette: vm.palette)
                        }
                        .buttonStyle(.plain)

                        if idx < vm.songs.count - 1 {
                            Divider()
                                .background(isLight
                                    ? Color.black.opacity(0.07)
                                    : Color.white.opacity(0.07))
                                .padding(.leading, 60)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Sticky header

    private var stickyHeader: some View {
        HStack(spacing: 12) {
            // Mini cover
            if let img = vm.coverImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(vm.displayAlbum.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isLight ? Color.primary : .white)
                    .lineLimit(1)
                Text(vm.displayAlbum.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(isLight ? Color.secondary : Color.white.opacity(0.65))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                guard !vm.songs.isEmpty else { return }
                PlayerService.shared.playPlaylist(vm.songs)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(isLight ? Color.primary : .white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .padding(.top, 48)  // below status bar / Dynamic Island
        .background(
            ZStack {
                Color(vm.palette.stickyBgColor).opacity(0.92)
            }
            .background(.ultraThinMaterial)
            .ignoresSafeArea(edges: .top)
        )
    }
}

// MARK: - Song row

private struct AlbumSongRow: View {
    let song: NavidromeSong
    let index: Int
    let palette: AlbumPalette

    private var isLight: Bool { palette.isPrimaryLight }
    private var primaryText:   Color { isLight ? .primary            : .white }
    private var secondaryText: Color { isLight ? .secondary          : Color.white.opacity(0.55) }
    private var tertiaryText:  Color { isLight ? Color(.tertiaryLabel) : Color.white.opacity(0.40) }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(tertiaryText)
                .frame(width: 28, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                Text(song.artist)
                    .font(.caption)
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            if let dur = song.duration, dur > 0 {
                Text(formatSeconds(dur))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tertiaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func formatSeconds(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
