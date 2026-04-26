import SwiftUI

// MARK: - View Model

@MainActor
final class AlbumDetailViewModel: ObservableObject {
    @Published var songs: [NavidromeSong] = []
    @Published var album: NavidromeAlbum?
    @Published var isLoading = true
    @Published var palette: AlbumPalette = .default
    @Published var coverImage: UIImage?
    @Published var recordLabels: [RecordLabel] = []
    @Published var albumNotes: String?

    private let api = NavidromeService.shared
    let initialAlbum: NavidromeAlbum
    private var paletteReady = false

    init(album: NavidromeAlbum) {
        self.initialAlbum = album
        self.album = album
        // Pre-load cached cover immediately so the hero transition doesn't flash a placeholder
        if let cached = AlbumCoverCache.shared.image(for: album.coverArt) {
            self.coverImage = cached
            // Palette from cache → colors appear WITH the zoom transition, zero delay
            if let id = album.coverArt, let p = PaletteCache.shared.palette(for: id) {
                self.palette = p
                self.paletteReady = true
            }
        }
    }

    var displayAlbum: NavidromeAlbum { album ?? initialAlbum }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        // Fetch songs + cover image + album notes concurrently
        async let songsTask = api.getAlbumDetail(albumId: initialAlbum.id)
        async let imageTask = fetchCover()
        async let notesTask = api.getAlbumInfo(albumId: initialAlbum.id)

        let (songsResult, image, notes) = await (try? songsTask, imageTask, notesTask)

        if let (al, songs, labels) = songsResult {
            self.songs = songs
            self.recordLabels = labels
            if let al { self.album = al }
        }
        self.albumNotes = notes

        if let image {
            self.coverImage = image
            // Skip extraction if palette was already loaded from cache in init
            if !paletteReady {
                let extracted = await Task.detached(priority: .userInitiated) {
                    ColorExtractor.extract(from: image)
                }.value
                self.palette = extracted
                if let key = initialAlbum.coverArt {
                    PaletteCache.shared.set(extracted, for: key)
                }
            }
        }
    }

    private func fetchCover() async -> UIImage? {
        if let cached = AlbumCoverCache.shared.image(for: initialAlbum.coverArt) {
            return cached
        }
        guard let url = api.coverURL(id: initialAlbum.coverArt, size: 600) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        guard let img = UIImage(data: data) else { return nil }
        AlbumCoverCache.shared.setImage(img, for: initialAlbum.coverArt)
        return img
    }
}

// MARK: - Main View

struct AlbumDetailView: View {
    @StateObject private var vm: AlbumDetailViewModel
    @State private var scrollY: CGFloat = 0
    var onDismiss: (() -> Void)?

    private let heroHeight: CGFloat = 440

    init(album: NavidromeAlbum, onDismiss: (() -> Void)? = nil) {
        _vm = StateObject(wrappedValue: AlbumDetailViewModel(album: album))
        self.onDismiss = onDismiss
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
                    albumNotesSection
                    Spacer(minLength: 120) // mini-player clearance
                }
                .frame(maxWidth: .infinity)
            }
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                scrollY = y
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(isLight ? .light : .dark, for: .navigationBar)
        .environment(\.colorScheme, isLight ? .light : .dark)
        .tint(isLight ? .accentColor : .white)
        .task {
            AppTheme.shared.overlayColorScheme = .dark
            await vm.load()
            AppTheme.shared.overlayColorScheme = isLight ? .light : .dark
        }
        .onChange(of: isLight) { _, light in
            AppTheme.shared.overlayColorScheme = light ? .light : .dark
        }
        .onDisappear {
            AppTheme.shared.overlayColorScheme = nil
        }
        .toolbar {
            if onDismiss != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onDismiss?() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(isLight ? Color.accentColor : .white)
                    }
                }
            }
            ToolbarItem(placement: .principal) {
                Text(vm.displayAlbum.name)
                    .font(.headline)
                    .foregroundStyle(isLight ? Color.black : .white)
                    .lineLimit(1)
                    .opacity(stickyOpacity)
            }
            if !vm.songs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    toolbarMenu
                }
            }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            if vm.palette.isSolid {
                // Solid cover: flat primary fills the hero, then a short gradient
                // at the very bottom blends into pageBg. No mask = no colour
                // clash around the cover art.
                ZStack(alignment: .bottom) {
                    Color(vm.palette.primary)
                        .scaleEffect(overscrollScale, anchor: .top)
                        .ignoresSafeArea(edges: .top)

                    LinearGradient(
                        colors: [
                            Color(vm.palette.primary),
                            pageBg
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 80)
                }
            } else {
                heroBackground
                    .scaleEffect(overscrollScale, anchor: .top)
                    .frame(height: heroHeight)
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            colors: [.clear, pageBg],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: heroHeight * 0.35)
                    }
                    .clipped()
            }

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
            Color(vm.palette.primary)
                .ignoresSafeArea(edges: .top)
        } else {
            ZStack {
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
            // Blurred artwork in background layer — scaledToFill can overflow
            // its frame but .background() prevents it from inflating the
            // parent's layout size, which was causing width miscalculation
            // on albums with non-square cover art.
            .background {
                if let img = vm.coverImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 55)
                        .scaleEffect(1.25)
                } else {
                    Color(vm.palette.primary)
                }
            }
            .clipped()
            .ignoresSafeArea(edges: .top)
        }
    }

    private var heroContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 100)

            // Cover art — centered.
            // When the cover is solid + light (white, cream, warm pastels), drop the
            // shadow so the artwork blends seamlessly into the background.
            coverArtImage
                .frame(width: 190, height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(
                    color: vm.palette.isSolid
                        ? .black.opacity(vm.palette.isPrimaryLight ? 0 : 0.15)
                        : .black.opacity(0.55),
                    radius: vm.palette.isSolid ? 8 : 22,
                    x: 0,
                    y: vm.palette.isSolid ? 2 : 8
                )

            Spacer(minLength: 20)

            // Title + metadata — centered
            VStack(alignment: .center, spacing: 5) {
                HStack(spacing: 8) {
                    Text(vm.displayAlbum.name)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(isLight ? Color.black : .white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)

                    if vm.displayAlbum.isExplicit {
                        ExplicitBadge(
                            color: isLight ? Color.black.opacity(0.45) : Color.white.opacity(0.75),
                            size: 18
                        )
                    }
                }

                metadataLine
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 20)

            // Play + shuffle buttons — centered
            playButtons
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
        let textColor: Color = isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.75)
        let album = vm.displayAlbum
        var parts: [String] = [album.artist]
        if let year = album.year  { parts.append(String(year)) }
        if let genre = album.genre { parts.append(genre) }

        return Text(parts.joined(separator: " · "))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(textColor)
            .lineLimit(1)
    }

    private var playButtons: some View {
        let fillColor  = Color(vm.palette.buttonFillColor)
        let labelColor: Color = vm.palette.buttonUsesBlackText ? .black : .white

        return HStack(spacing: 14) {
            Button {
                guard !vm.songs.isEmpty else { return }
                PlayerService.shared.playPlaylist(vm.songs, contextUri: "album:\(vm.displayAlbum.id)", contextName: vm.displayAlbum.name)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "play.fill")
                    Text(L.play)
                        .fontWeight(.semibold)
                }
                .font(.system(size: 15))
                .foregroundStyle(labelColor)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(fillColor, in: Capsule())
            }

            Button {
                guard !vm.songs.isEmpty else { return }
                PlayerService.shared.playPlaylist(vm.songs.shuffled(), contextUri: "album:\(vm.displayAlbum.id)", contextName: vm.displayAlbum.name)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(labelColor)
                    .frame(width: 40, height: 40)
                    .background(fillColor, in: Circle())
            }
        }
        .disabled(vm.isLoading)
    }

    // MARK: - Toolbar Menu

    @ViewBuilder
    private var toolbarMenu: some View {
        Menu {
            Button {
                DownloadManager.shared.downloadAlbum(
                    albumId: vm.displayAlbum.id,
                    title: vm.displayAlbum.name,
                    songs: vm.songs,
                    pin: false
                )
            } label: {
                Label(L.download, systemImage: "arrow.down.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isLight ? Color.accentColor : .white)
        }
    }

    // MARK: - Song list

    private var recordLabelFooter: some View {
        let year = String(vm.displayAlbum.year ?? Calendar.current.component(.year, from: Date()))
        let labels = vm.recordLabels.map(\.name).joined(separator: ", ")
        return Text("© \(year) \(labels)")
            .font(.system(size: 12))
            .foregroundStyle(isLight ? Color.black.opacity(0.30) : Color.white.opacity(0.35))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
    }

    // MARK: - Album notes

    @ViewBuilder
    private var albumNotesSection: some View {
        let cardBG: Color = isLight ? Color.black.opacity(0.05) : Color.white.opacity(0.08)
        let cardBorder: Color = isLight ? Color.black.opacity(0.10) : Color.white.opacity(0.10)

        if let notes = vm.albumNotes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(L.aboutAlbum(vm.displayAlbum.name))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(isLight ? Color.black : .white)

                Text(cleanNotes(notes))
                    .font(.system(size: 15))
                    .foregroundStyle(isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.75))
                    .lineSpacing(4)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(cardBG, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(cardBorder, lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.top, 20)
        }
    }

    private func cleanNotes(_ html: String) -> String {
        var cleaned = html
        cleaned = cleaned.replacingOccurrences(
            of: "<a[^>]*>[^<]*Read more on Last\\.fm[^<]*</a>",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: "Read more on Last.fm", with: "")
        cleaned = cleaned.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        let entities = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">"]
        for (k, v) in entities { cleaned = cleaned.replacingOccurrences(of: k, with: v) }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Song list

    private var songListSection: some View {
        VStack(spacing: 0) {
            if vm.isLoading {
                ProgressView()
                    .tint(isLight ? .secondary : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
            } else {
                SongListView(songs: vm.songs, palette: vm.palette, showAlbumInMenu: false, showArtist: false, contextUri: "album:\(vm.displayAlbum.id)", contextName: vm.displayAlbum.name)

                if !vm.recordLabels.isEmpty {
                    recordLabelFooter
                }
            }
        }
    }

}
