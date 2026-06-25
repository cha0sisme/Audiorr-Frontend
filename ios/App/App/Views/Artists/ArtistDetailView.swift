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

        // Si los albums principales aún no llegaron (loadAlbums corre en
        // paralelo y suele resolver antes, pero no está garantizado), esperamos
        // — `getArtistCollaborations` necesita `primaryAlbumIds` para no
        // duplicar discografía en "Aparece en".
        if albums.isEmpty && isLoadingAlbums {
            for _ in 0..<20 {  // ~2s max
                if !isLoadingAlbums { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let primaryIds = Set(albums.map(\.id))

        // Info + collaborations are Navidrome-only — safe to run always
        async let infoTask    = api.getArtistInfo(artistId: artist.id)
        async let collabsTask = api.getArtistCollaborations(
            artistId: artist.id,
            artistName: artist.name,
            primaryAlbumIds: primaryIds
        )

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

    /// Carga el primer álbum y pone su tracklist en reproducción aleatoria.
    /// Mismo patrón que `loadAndPlay`, solo cambia el orden final. Si en el
    /// futuro queremos shuffle "todos los tracks del artista", habrá que
    /// pre-cargar varios álbumes — coste de red proporcional al catálogo.
    func loadAndShuffle() async {
        guard !albums.isEmpty else { return }
        isLoadingPlayback = true
        defer { isLoadingPlayback = false }
        if let (_, songs, _) = try? await api.getAlbumDetail(albumId: albums[0].id) {
            await MainActor.run { PlayerService.shared.playPlaylist(songs.shuffled(), contextUri: "artist:\(artist.id)", contextName: artist.name) }
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
    /// Ver AlbumDetailView: defiende contra ghost taps tras el pop de
    /// `.navigationTransition(.zoom)`. Se propaga a SongListView vía
    /// `\.detailIsActive` para que sus filas no reproduzcan al tocar una lista
    /// de un artista que ya se abandonó.
    @State private var isViewVisible = false
    /// Namespace provided by the NavigationStack owner so that
    /// `matchedTransitionSource` on cards aligns with the root-level
    /// `navigationDestination(.zoom)` — SwiftUI only honours destinations
    /// declared closest to the stack root.
    var heroNamespace: Namespace.ID?
    @Namespace private var localHeroNS
    var onDismiss: (() -> Void)?

    /// Use parent namespace when available, local fallback otherwise.
    private var heroNS: Namespace.ID { heroNamespace ?? localHeroNS }

    /// Pequeño margen bajo la foto antes del contenido (la bio). El botón de
    /// Play ahora va en la MISMA línea que el nombre (sobre la foto), así que ya
    /// no se reserva la franja grande de antes — la bio sube a esa posición.
    private let bottomArea: CGFloat = 14

    /// Ancho visual de la pantalla.
    private var screenWidth: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 393
    }

    /// Altura de la foto del artista. Apple Music iOS 26 sube la foto
    /// hasta el TOP de la pantalla cubriendo el notch (no deja la
    /// status bar con un color sólido distinto). Por eso el alto lógico
    /// de la foto es `screenWidth + safeAreaTop`: visualmente es
    /// ligeramente más alta que ancha, pero permite que la cara
    /// (situada en el upper 40% del cuadrado de Apple) quede
    /// principalmente debajo del notch sin recortes severos.
    private var photoHeight: CGFloat { screenWidth + safeAreaTop }

    /// Altura total del hero = foto + área de botones.
    private var heroHeight: CGFloat { photoHeight + bottomArea }

    init(artist: NavidromeArtist, heroNamespace: Namespace.ID? = nil, onDismiss: (() -> Void)? = nil) {
        _vm = StateObject(wrappedValue: ArtistDetailViewModel(artist: artist))
        self.heroNamespace = heroNamespace
        self.onDismiss = onDismiss
    }

    private var scrollProgress: CGFloat  { min(max(scrollY / heroHeight, 0), 1) }
    private var heroOpacity: CGFloat     { 1 - min(scrollProgress * 1.3, 0.92) }
    private var stickyOpacity: CGFloat   { min(max((scrollProgress - 0.50) / 0.30, 0), 1) }
    /// Stretchy header scale: proporcional al pull-down. Anchor `.bottom`
    /// para que el header gane altura hacia arriba en el rebound.
    private var stretchScale: CGFloat {
        let pullDown = max(0, -scrollY)
        return (heroHeight + pullDown) / heroHeight
    }

    private var isLight: Bool { vm.palette.isPrimaryLight }
    private var pageBg: Color { Color(vm.palette.pageBackgroundColor) }
    private var skeletonColor: Color { isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.10) }

    /// Safe area top de la ventana actual. Necesario para extender el
    /// heroBackground HASTA el notch — el ScrollView con `.ignoresSafeArea`
    /// no propaga insets cero a sus children dentro del scroll content,
    /// lo que dejaba un gap visible bajo la status bar.
    private var safeAreaTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .safeAreaInsets.top ?? 47
    }

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
        .onAppear { isViewVisible = true }
        .onDisappear {
            isViewVisible = false
            AppTheme.shared.overlayColorScheme = nil
        }
        // Propaga el estado activo a SongListView para que sus filas no
        // disparen reproducción ante un ghost tap durante/tras el pop zoom.
        .environment(\.detailIsActive, isViewVisible)
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
            // ArtistDetail: la foto vive DENTRO del heroBackground (no en
            // heroContent como en AlbumDetail). Por eso el truco del
            // doble offset (frame +safeAreaTop + offset -safeAreaTop) que
            // usa AlbumDetail NO se aplica aquí: desplazaría la foto y
            // dejaría el nombre/scrim donde la imagen ya no está. La
            // extensión al notch se resuelve internamente en `heroBackground`
            // poniendo `Color.clear.frame(height: safeAreaTop)` al top del
            // VStack y `Color(palette.primary)` detrás cubriendo el área
            // del notch.
            heroBackground
                .frame(height: heroHeight)
                .overlay(alignment: .bottom) {
                    LinearGradient.heroFade(to: pageBg)
                        .frame(height: heroHeight * 0.55)
                        .allowsHitTesting(false)
                }
                .scaleEffect(stretchScale, anchor: .bottom)

            heroContent
                .opacity(heroOpacity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
    }

    private var heroBackground: some View {
        // Banner Apple Music iOS 26: foto edge-to-edge SUBIDA AL TOP del
        // todo (cubre incluso el área del notch). `Color(palette.primary)`
        // sigue de fondo por si la foto no llena el frame del banner.
        //
        // El contenido de la imagen se alinea al TOP del frame con
        // `aspectRatio(.fill)` + `frame(alignment: .top)`: preserva el
        // upper 40% del cuadrado de Apple (la cara) cuando el backend
        // devuelve una imagen con aspect ratio distinto de 1:1.
        ZStack(alignment: .top) {
            Color(vm.palette.primary)

            artistPhotoView
                .frame(width: screenWidth, height: photoHeight, alignment: .top)
                .clipped()
                .overlay(alignment: .bottom) {
                    // Único fade hacia `palette.primary` — el color del
                    // área debajo de la foto. La opacidad final llega a
                    // 1.0 exacto, por lo que el último pixel de la foto
                    // ES `palette.primary` sólido, idéntico al área de
                    // botones. CERO escalón visual independientemente
                    // del color de la imagen.
                    LinearGradient(
                        stops: [
                            .init(color: Color(vm.palette.primary).opacity(0.00), location: 0.00),
                            .init(color: Color(vm.palette.primary).opacity(0.40), location: 0.45),
                            .init(color: Color(vm.palette.primary).opacity(0.85), location: 0.80),
                            .init(color: Color(vm.palette.primary).opacity(1.00), location: 1.00)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 320)
                    .allowsHitTesting(false)
                }
        }
    }

    private var heroContent: some View {
        // Nombre del artista anclado al BOTTOM de la foto, con el botón de Play
        // (circular) en la MISMA línea, a la derecha. Sin shuffle. El nombre se
        // acorta (lineLimit + minimumScaleFactor) y el botón tiene tamaño fijo
        // con prioridad de layout para que nunca lo desplace un nombre largo.
        let playBg = Color(vm.palette.playButtonBackground(motionPresent: false))
        let playFg = Color(vm.palette.playButtonForeground(motionPresent: false))

        return VStack(spacing: 0) {
            Spacer()
            HStack(alignment: .center, spacing: 12) {
                Text(vm.artist.name)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(isLight ? Color.black : .white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)

                Spacer(minLength: 8)

                Button {
                    Task { await vm.loadAndPlay() }
                } label: {
                    Group {
                        if vm.isLoadingPlayback {
                            ProgressView().tint(playFg)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(playFg)
                        }
                    }
                    .frame(width: 54, height: 54)
                    .background(playBg, in: Circle())
                }
                .disabled(vm.isLoadingAlbums || vm.isLoadingPlayback || vm.albums.isEmpty)
                .layoutPriority(1)   // el botón nunca se comprime
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)

            // Pequeño margen antes del contenido (la bio sube hasta aquí).
            Color.clear.frame(height: bottomArea)
        }
        .frame(height: heroHeight)
    }

    /// Foto del artista en formato cuadrado 1:1, edge-to-edge horizontal,
    /// estilo Apple Music iOS 26. `aspectRatio(.fill)` permite que la
    /// imagen llene el frame del padre independientemente de su aspect
    /// nativo, y el `alignment: .top` que el caller aplica al frame
    /// preserva el upper 40% (donde Apple obliga al artista a colocar la
    /// cara). Si no hay imagen, fallback con gradient determinístico
    /// (basado en hash del nombre) y la inicial centrada.
    @ViewBuilder
    private var artistPhotoView: some View {
        if let img = vm.avatarImage {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: [nameColor.opacity(0.95), nameColor.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Text(String(vm.artist.name.prefix(1)).uppercased())
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    // MARK: - Content sections

    private var contentSections: some View {
        VStack(alignment: .leading, spacing: 28) {
            biographySection
            popularesSection
            discographySection
            collaborationsSection
            playlistsSection
            similarArtistsSection
        }
        .padding(.top, 8)
    }

    // MARK: Populares (top songs)

    @ViewBuilder
    private var popularesSection: some View {
        if vm.isLoadingSongs {
            VStack(alignment: .leading, spacing: 12) {
                Text(L.popular)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(isLight ? Color.black : .white)
                    .padding(.horizontal, 16)

                SongListSkeleton(count: 5, palette: vm.palette, showCover: true)
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

            HorizontalScrollSection(
                title: L.albums,
                isLight: isLight,
                seeAll: overflow > 0 ? .albums(title: L.albums, items: vm.albums) : nil
            ) {
                ForEach(visible) { album in
                    NavigationLink(value: album) {
                        AlbumCardView(album: album, subtitle: .year, isLight: isLight, heroNamespace: heroNS)
                    }
                    .buttonStyle(.plain)
                }
                // Tarjeta "Ver todo" al final del scroll (además del chevron del
                // encabezado): ambas vías llevan al mismo SeeAllGridView.
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

            HorizontalScrollSection(
                title: L.appearsIn,
                isLight: isLight,
                seeAll: overflow > 0 ? .albums(title: L.appearsIn, items: vm.collaborations) : nil
            ) {
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
                isLight: isLight,
                seeAll: overflow > 0
                    ? .playlists(title: L.playlistsWith(vm.artist.name), items: vm.playlists)
                    : nil
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

            HorizontalScrollSection(
                title: L.fansAlsoListen,
                isLight: isLight,
                seeAll: overflow > 0 ? .artists(title: L.fansAlsoListen, items: artists) : nil
            ) {
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

    // MARK: Biografía (Apple Music style — sube del final del scroll a justo
    // bajo los botones de reproducción, sin tarjeta, sin título)

    /// Bio del artista en el formato 2 líneas + MÁS estilo Apple Music. Sale al
    /// principio de `contentSections`, antes que populares / discografía. Si no
    /// hay bio disponible (carga o sin datos de last.fm), no se renderiza nada
    /// y el divider tampoco aparece — la transición hero → populares queda
    /// limpia como antes del refactor.
    @ViewBuilder
    private var biographySection: some View {
        let dividerColor: Color = isLight ? Color.black.opacity(0.15) : Color.white.opacity(0.15)
        let skeletonBlock: Color = isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.10)

        if vm.infoIsLoading {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(skeletonBlock)
                        .frame(height: 14)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(skeletonBlock)
                        .frame(height: 14)
                        .frame(maxWidth: 240, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
                Divider()
                    .background(dividerColor)
                    .padding(.horizontal, 16)
            }
        } else if let bio = vm.info?.biography, !bio.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ExpandableBio(
                    text: cleanBiography(bio),
                    pageBg: pageBg,
                    textColor: isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.75),
                    sheetTitle: vm.artist.name
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
                Divider()
                    .background(dividerColor)
                    .padding(.horizontal, 16)
            }
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

