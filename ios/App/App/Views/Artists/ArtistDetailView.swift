import SwiftUI

// MARK: - View Model

@MainActor
final class ArtistDetailViewModel: ObservableObject {
    @Published var artist: NavidromeArtist
    @Published var albums: [NavidromeAlbum] = []
    @Published var topSongs: [NavidromeSong] = []
    @Published var collaborations: [NavidromeAlbum] = []
    @Published var playlists: [NavidromePlaylist] = []
    @Published var info: ArtistInfo?

    @Published var isLoadingAlbums = true
    @Published var isLoadingSongs = true
    @Published var isLoadingPlayback = false
    @Published var infoIsLoading = true
    @Published var playlistsAreLoading = true

    @Published var avatarImage: UIImage?
    @Published var palette: AlbumPalette = .default

    @Published var showAllSongs = false

    private let api = NavidromeService.shared
    private var paletteReady = false

    init(artist: NavidromeArtist) {
        self.artist = artist
        // Pre-populate from cache so the hero transition shows the real avatar
        if let cached = ArtistImageCache.shared.image(for: artist.id) {
            self.avatarImage = cached
            // Palette from cache → colors appear WITH the zoom transition
            if let p = PaletteCache.shared.palette(for: artist.id) {
                self.palette = p
                self.paletteReady = true
            }
        }
    }

    /// Each section loads and publishes independently — no global spinner.
    /// The hero (avatar + palette) loads first, then albums and songs arrive
    /// in parallel. Each section appears as soon as its data is ready.
    func load() async {
        guard albums.isEmpty else { return }

        // Fire all three in parallel — each publishes independently
        async let avatarDone: Void = loadAvatar()
        async let albumsDone: Void = loadAlbums()
        async let songsDone: Void = loadSongs()

        _ = await (avatarDone, albumsDone, songsDone)
    }

    private func loadAlbums() async {
        if let (ar, albums) = try? await api.getArtistDetail(artistId: artist.id) {
            self.albums = albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
            if let ar { self.artist = ar }
        }
        isLoadingAlbums = false
    }

    private func loadSongs() async {
        self.topSongs = await api.getArtistSongs(artistName: artist.name, count: 10)
        isLoadingSongs = false
    }

    private func loadAvatar() async {
        if let img = await fetchAvatar() {
            self.avatarImage = img
            if !paletteReady {
                let artistId = artist.id
                let extracted = await Task.detached(priority: .userInitiated) {
                    ColorExtractor.extract(from: img)
                }.value
                guard !Task.isCancelled else { return }
                self.palette = extracted
                PaletteCache.shared.set(extracted, for: artistId)
            }
        }
    }

    /// Secondary pass: biography, similar artists, collaborations, playlists.
    /// Triggered once the hero + critical lists are visible.
    func loadSecondary() async {
        guard info == nil else { return }
        infoIsLoading = true
        playlistsAreLoading = true

        // Info + collaborations are Navidrome-only — safe to run always
        async let infoTask    = api.getArtistInfo(artistId: artist.id)
        async let collabsTask = api.getArtistCollaborations(artistName: artist.name)

        self.info = await infoTask
        self.collaborations = await collabsTask
        self.infoIsLoading = false

        // Playlist matching fetches every playlist's songs — expensive and
        // requires Navidrome to be responsive. Run separately so it never
        // blocks the sections above.
        self.playlists = await api.getPlaylistsByArtist(artistName: artist.name)
        self.playlistsAreLoading = false
    }

    func loadAndPlay() async {
        guard !albums.isEmpty else { return }
        isLoadingPlayback = true
        defer { isLoadingPlayback = false }
        if let (_, songs, _) = try? await api.getAlbumDetail(albumId: albums[0].id) {
            await MainActor.run { PlayerService.shared.playPlaylist(songs, contextUri: "artist:\(artist.id)", contextName: artist.name) }
        }
    }

    private func fetchAvatar() async -> UIImage? {
        if let cached = ArtistImageCache.shared.image(for: artist.id) {
            return cached
        }
        guard let avatarURL = await api.artistAvatarURL(artistId: artist.id) else { return nil }
        return await ArtistImageCache.shared.loadImage(artistId: artist.id, url: avatarURL)
    }
}

// MARK: - Main View

struct ArtistDetailView: View {
    @StateObject private var vm: ArtistDetailViewModel
    @State private var scrollY: CGFloat = 0
    /// Namespace provided by the NavigationStack owner so that
    /// `matchedTransitionSource` on cards aligns with the root-level
    /// `navigationDestination(.zoom)` — SwiftUI only honours destinations
    /// declared closest to the stack root.
    var heroNamespace: Namespace.ID?
    @Namespace private var localHeroNS
    var onDismiss: (() -> Void)?

    /// Use parent namespace when available, local fallback otherwise.
    private var heroNS: Namespace.ID { heroNamespace ?? localHeroNS }

    private let heroHeight: CGFloat = 400
    private let avatarSize: CGFloat = 160

    init(artist: NavidromeArtist, heroNamespace: Namespace.ID? = nil, onDismiss: (() -> Void)? = nil) {
        _vm = StateObject(wrappedValue: ArtistDetailViewModel(artist: artist))
        self.heroNamespace = heroNamespace
        self.onDismiss = onDismiss
    }

    private var scrollProgress: CGFloat  { min(max(scrollY / heroHeight, 0), 1) }
    private var heroOpacity: CGFloat     { 1 - min(scrollProgress * 1.3, 0.92) }
    private var stickyOpacity: CGFloat   { min(max((scrollProgress - 0.50) / 0.30, 0), 1) }
    private var overscrollScale: CGFloat { 1 + max(0, -scrollY) / 900 }

    private var isLight: Bool { vm.palette.isPrimaryLight }
    private var pageBg: Color { Color(vm.palette.pageBackgroundColor) }
    private var skeletonColor: Color { isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.10) }

    // Deterministic color from artist name (fallback when no avatar)
    private var nameColor: Color {
        let hash = vm.artist.name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 360 }
        return Color(hue: Double(hash) / 360.0, saturation: 0.55, brightness: 0.40)
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            pageBg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    heroSection
                    contentSections
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
        .toolbarColorScheme(isLight ? .light : .dark, for: .navigationBar)
        .environment(\.colorScheme, isLight ? .light : .dark)
        .tint(isLight ? .accentColor : .white)
        .task {
            AppTheme.shared.overlayColorScheme = .dark
            async let primary: Void = vm.load()
            async let secondary: Void = vm.loadSecondary()
            _ = await (primary, secondary)
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
                Text(vm.artist.name)
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
            // Flat-cover avatars — match album/playlist page, use the solid primary.
            Color(vm.palette.primary)
                .ignoresSafeArea(edges: .top)
        } else if let img = vm.avatarImage {
            ZStack {
                // Gradient overlay at 140° (top-trailing → bottom-leading)
                LinearGradient(
                    colors: [
                        Color(vm.palette.primary).opacity(0.82),
                        Color(vm.palette.secondary).opacity(0.76)
                    ],
                    startPoint: .topTrailing, endPoint: .bottomLeading
                )

                // Dark scrim for legible text (same as album/playlist)
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.38),
                        Color.black.opacity(0.22),
                        Color.black.opacity(0.06)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .background {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 55)
                    .scaleEffect(1.25)
            }
            .clipped()
            .ignoresSafeArea(edges: .top)
        } else {
            ZStack {
                LinearGradient(
                    colors: [nameColor.opacity(0.9), nameColor.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Color.black.opacity(0.20)
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    private var heroContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 90)

            avatarView
                .shadow(color: .black.opacity(0.45), radius: 20, y: 8)

            Spacer(minLength: 16)

            VStack(spacing: 4) {
                Text(vm.artist.name)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(isLight ? Color.black : .white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                if let count = vm.artist.albumCount, count > 0 {
                    Text(L.albumCount(count))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)

            playButton
                .padding(.bottom, 28)
        }
    }

    private var playButton: some View {
        let fillColor  = Color(vm.palette.buttonFillColor)
        let labelColor: Color = vm.palette.buttonUsesBlackText ? .black : .white

        return Button {
            Task { await vm.loadAndPlay() }
        } label: {
            Group {
                if vm.isLoadingPlayback {
                    ProgressView().tint(labelColor)
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill")
                        Text(L.play).fontWeight(.semibold)
                    }
                    .font(.system(size: 15))
                }
            }
            .foregroundStyle(labelColor)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(fillColor, in: Capsule())
        }
        .disabled(vm.isLoadingAlbums || vm.isLoadingPlayback || vm.albums.isEmpty)
    }

    @ViewBuilder
    private var avatarView: some View {
        if let img = vm.avatarImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(nameColor.opacity(0.35))
                .frame(width: avatarSize, height: avatarSize)
                .overlay(
                    Text(String(vm.artist.name.prefix(1)).uppercased())
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                )
        }
    }

    // MARK: - Content sections

    private var contentSections: some View {
        VStack(alignment: .leading, spacing: 28) {
            popularesSection
            discographySection
            collaborationsSection
            playlistsSection
            similarArtistsSection
            biographySection
        }
        .padding(.top, 8)
    }

    // MARK: Populares (top songs)

    @ViewBuilder
    private var popularesSection: some View {
        if vm.isLoadingSongs {
            // Skeleton while loading
            VStack(alignment: .leading, spacing: 12) {
                Text(L.popular)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(isLight ? Color.black : .white)
                    .padding(.horizontal, 16)

                ForEach(0..<4, id: \.self) { _ in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 6).fill(skeletonColor).frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 4).fill(skeletonColor).frame(width: 140, height: 14)
                            RoundedRectangle(cornerRadius: 4).fill(skeletonColor).frame(width: 90, height: 12)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                }
            }
        } else if !vm.topSongs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L.popular)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(isLight ? Color.black : .white)
                    Spacer()
                    if vm.topSongs.count > 5 {
                        Button {
                            withAnimation(Anim.small) { vm.showAllSongs.toggle() }
                        } label: {
                            Text(vm.showAllSongs ? L.showLess : L.showMore)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.60))
                        }
                    }
                }
                .padding(.horizontal, 16)

                let visible = vm.showAllSongs ? vm.topSongs : Array(vm.topSongs.prefix(5))
                SongListView(songs: visible, palette: vm.palette, showAlbumInMenu: true, showArtistInMenu: false, showArtist: false, contextUri: "artist:\(vm.artist.id)", contextName: vm.artist.name)
                    .id(vm.showAllSongs)
            }
        }
    }

    // MARK: Álbumes

    private let albumsVisibleLimit = 8

    @ViewBuilder
    private var discographySection: some View {
        if vm.isLoadingAlbums {
            HorizontalScrollSection(title: L.albums, isLight: isLight) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 10).fill(skeletonColor).frame(width: 150, height: 150)
                        RoundedRectangle(cornerRadius: 4).fill(skeletonColor).frame(width: 100, height: 14)
                        RoundedRectangle(cornerRadius: 4).fill(skeletonColor).frame(width: 60, height: 12)
                    }
                }
            }
        } else if !vm.albums.isEmpty {
            let visible = Array(vm.albums.prefix(albumsVisibleLimit))
            let overflow = vm.albums.count - albumsVisibleLimit

            HorizontalScrollSection(title: L.albums, isLight: isLight) {
                ForEach(visible) { album in
                    NavigationLink(value: album) {
                        AlbumCardView(album: album, subtitle: .year, isLight: isLight, heroNamespace: heroNS)
                    }
                    .buttonStyle(.plain)
                }
                if overflow > 0 {
                    NavigationLink(value: SeeAllDestination.albums(
                        title: L.albums, items: vm.albums
                    )) {
                        SeeAllCard(remaining: overflow, isLight: isLight)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Aparece en (collaborations)

    private let collabsVisibleLimit = 8

    @ViewBuilder
    private var collaborationsSection: some View {
        if !vm.collaborations.isEmpty {
            let visible = Array(vm.collaborations.prefix(collabsVisibleLimit))
            let overflow = vm.collaborations.count - collabsVisibleLimit

            HorizontalScrollSection(title: L.appearsIn, isLight: isLight) {
                ForEach(visible) { album in
                    NavigationLink(value: album) {
                        AlbumCardView(album: album, subtitle: .artist, isLight: isLight, heroNamespace: heroNS)
                    }
                    .buttonStyle(.plain)
                }
                if overflow > 0 {
                    NavigationLink(value: SeeAllDestination.albums(
                        title: L.appearsIn, items: vm.collaborations
                    )) {
                        SeeAllCard(remaining: overflow, isLight: isLight)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Playlists con X

    private let playlistsVisibleLimit = 8

    @ViewBuilder
    private var playlistsSection: some View {
        if !vm.playlistsAreLoading && !vm.playlists.isEmpty {
            let visible = Array(vm.playlists.prefix(playlistsVisibleLimit))
            let overflow = vm.playlists.count - playlistsVisibleLimit

            HorizontalScrollSection(
                title: L.playlistsWith(vm.artist.name),
                isLight: isLight
            ) {
                ForEach(visible) { playlist in
                    NavigationLink(value: playlist) {
                        PlaylistCardView(playlist: playlist, isLight: isLight, heroNamespace: heroNS)
                    }
                    .buttonStyle(.plain)
                }
                if overflow > 0 {
                    NavigationLink(value: SeeAllDestination.playlists(
                        title: L.playlistsWith(vm.artist.name), items: vm.playlists
                    )) {
                        SeeAllCard(remaining: overflow, isLight: isLight)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Fans también escuchan (similar artists)

    private let similarVisibleLimit = 8

    @ViewBuilder
    private var similarArtistsSection: some View {
        if vm.infoIsLoading {
            HorizontalScrollSection(title: L.fansAlsoListen, isLight: isLight) {
                ForEach(0..<6, id: \.self) { _ in
                    SimilarArtistPlaceholder(isLight: isLight)
                }
            }
        } else if let info = vm.info, !info.similarArtists.isEmpty {
            let artists = info.similarArtists.map {
                NavidromeArtist(id: $0.id, name: $0.name, albumCount: nil)
            }
            let visible = Array(artists.prefix(similarVisibleLimit))
            let overflow = artists.count - similarVisibleLimit

            HorizontalScrollSection(title: L.fansAlsoListen, isLight: isLight) {
                ForEach(visible) { artist in
                    NavigationLink(value: artist) {
                        ArtistCardView(artist: artist, size: 120, isLight: isLight, heroNamespace: heroNS)
                    }
                    .buttonStyle(.plain)
                }
                if overflow > 0 {
                    NavigationLink(value: SeeAllDestination.artists(
                        title: L.fansAlsoListen, items: artists
                    )) {
                        SeeAllArtistCard(remaining: overflow, isLight: isLight)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Acerca de (biography)

    @ViewBuilder
    private var biographySection: some View {
        let cardBG: Color = isLight ? Color.black.opacity(0.05) : Color.white.opacity(0.08)
        let cardBorder: Color = isLight ? Color.black.opacity(0.10) : Color.white.opacity(0.10)

        if vm.infoIsLoading {
            VStack(alignment: .leading, spacing: 14) {
                Rectangle()
                    .fill(cardBG)
                    .frame(width: 160, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<4, id: \.self) { i in
                        Rectangle()
                            .fill(cardBG)
                            .frame(height: 14)
                            .frame(maxWidth: i == 3 ? 220 : .infinity, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .padding(20)
            .background(cardBG, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(cardBorder, lineWidth: 1)
            )
            .padding(.horizontal, 16)
        } else if let bio = vm.info?.biography, !bio.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(L.aboutArtist(vm.artist.name))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(isLight ? Color.black : .white)

                Text(cleanBiography(bio))
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
        }
    }

    /// Strip Last.fm's `<a>` tags and the trailing "Read more on Last.fm" link.
    private func cleanBiography(_ html: String) -> String {
        var cleaned = html
        // Remove entire "Read more on Last.fm" anchors.
        cleaned = cleaned.replacingOccurrences(
            of: "<a[^>]*>[^<]*Read more on Last\\.fm[^<]*</a>",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: "Read more on Last.fm", with: "")
        // Strip remaining HTML tags.
        cleaned = cleaned.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        // Unescape common HTML entities.
        let entities = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">"]
        for (k, v) in entities { cleaned = cleaned.replacingOccurrences(of: k, with: v) }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Similar artist placeholder (loading skeleton)

private struct SimilarArtistPlaceholder: View {
    let isLight: Bool
    private let size: CGFloat = 120
    private var bg: Color { isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.10) }

    var body: some View {
        VStack(spacing: 10) {
            Circle().fill(bg).frame(width: size, height: size)
            Rectangle().fill(bg).frame(width: 80, height: 10).clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

