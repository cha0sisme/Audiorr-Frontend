import SwiftUI
import Combine

// MARK: - View Model

@MainActor
final class PlaylistDetailViewModel: ObservableObject {
    @Published var songs: [NavidromeSong] = []
    @Published var playlist: NavidromePlaylist?
    @Published var isLoading = true
    @Published var palette: AlbumPalette = .default
    @Published var coverImage: UIImage?
    @Published var smartMixStatus: SmartMixStatus = .idle
    @Published var isPinned = false
    @Published var isDeleting = false

    private let api = NavidromeService.shared
    private var cancellables = Set<AnyCancellable>()
    let initialPlaylist: NavidromePlaylist
    private var paletteReady = false

    init(playlist: NavidromePlaylist) {
        self.initialPlaylist = playlist
        self.playlist = playlist

        // Pre-load cached cover so hero transition doesn't flash placeholder
        let coverId = playlist.id  // playlist covers keyed by playlistId
        if let cached = PlaylistCoverCache.shared.image(for: playlist.id) {
            self.coverImage = cached
            if let p = PaletteCache.shared.palette(for: coverId) {
                self.palette = p
                self.paletteReady = true
            }
        } else if let cached = AlbumCoverCache.shared.image(for: playlist.coverArt) {
            self.coverImage = cached
            if let id = playlist.coverArt, let p = PaletteCache.shared.palette(for: id) {
                self.palette = p
                self.paletteReady = true
            }
        }

        // Observe SmartMix status from PlayerService
        PlayerService.shared.$smartMixStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self,
                      PlayerService.shared.smartMixPlaylistId == self.initialPlaylist.id
                else { return }
                self.smartMixStatus = status
            }
            .store(in: &cancellables)

        PlayerService.shared.$smartMixPlaylistId
            .receive(on: RunLoop.main)
            .sink { [weak self] pid in
                guard let self else { return }
                if pid != self.initialPlaylist.id {
                    self.smartMixStatus = .idle
                }
            }
            .store(in: &cancellables)

        // Refresh cover + palette when the cache invalidates this playlist
        // (e.g. backend hash changed mid-session). Without this, the @Published
        // image preloaded for the hero transition would stick around stale.
        let myId = playlist.id
        PlaylistCoverCache.shared.coverInvalidated
            .filter { $0 == myId }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.coverImage = nil
                self.paletteReady = false
                Task { await self.loadCover() }
            }
            .store(in: &cancellables)
    }

    var displayPlaylist: NavidromePlaylist { playlist ?? initialPlaylist }

    func load() async {
        guard songs.isEmpty else { return }
        isLoading = true

        // Fire-and-forget hash refresh: if the backend reports a newer cover
        // for this playlist, the cache invalidates and our subscription above
        // re-fetches. Closes the race when the user opens detail before the
        // grid has had a chance to refresh hashes.
        if BackendState.shared.isAvailable {
            Task.detached(priority: .utility) {
                await NavidromeService.shared.refreshPlaylistCoverHashes()
            }
        }

        // Songs first — don't let cover fetch block the list
        if let (pl, songs) = try? await api.getPlaylistSongs(playlistId: initialPlaylist.id) {
            self.songs = songs
            if let pl { self.playlist = pl }
        }

        // Songs ready — show them immediately
        isLoading = false

        // Cover + backend features load in background without blocking UI
        async let coverTask: Void = loadCover()
        async let pinnedTask: Void = loadPinnedIfAvailable()
        _ = await (coverTask, pinnedTask)
    }

    private func loadCover() async {
        if let image = await fetchCover() {
            self.coverImage = image
            if !paletteReady {
                let playlistId = initialPlaylist.id
                let extracted = await Task.detached(priority: .userInitiated) {
                    ColorExtractor.extract(from: image)
                }.value
                self.palette = extracted
                PaletteCache.shared.set(extracted, for: playlistId)
            }
        }
    }

    private func loadPinnedIfAvailable() async {
        if BackendState.shared.isAvailable { await loadPinnedStatus() }
    }

    // MARK: - Pinned Playlists (backend-synced)

    func loadPinnedStatus() async {
        guard let username = api.credentials?.username else { return }
        let pinned = (try? await BackendService.shared.getPinnedPlaylists(username: username)) ?? []
        isPinned = pinned.contains { $0.id == initialPlaylist.id }
    }

    func togglePinned() {
        guard let username = api.credentials?.username else { return }
        let wasPin = isPinned
        isPinned.toggle()

        Task {
            do {
                var pinned = (try? await BackendService.shared.getPinnedPlaylists(username: username)) ?? []
                if wasPin {
                    pinned.removeAll { $0.id == initialPlaylist.id }
                } else {
                    let pl = displayPlaylist
                    pinned.append(BackendService.PinnedPlaylist(
                        id: pl.id, name: pl.name, position: pinned.count
                    ))
                }
                _ = try await BackendService.shared.savePinnedPlaylists(username: username, playlists: pinned)
            } catch {
                // Revert on failure
                isPinned = wasPin
            }
        }
    }

    // MARK: - Delete Playlist

    func deletePlaylist() async -> Bool {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await api.deletePlaylist(playlistId: initialPlaylist.id)
            // Also remove from pinned if it was pinned
            if isPinned, let username = api.credentials?.username {
                var pinned = (try? await BackendService.shared.getPinnedPlaylists(username: username)) ?? []
                pinned.removeAll { $0.id == initialPlaylist.id }
                _ = try? await BackendService.shared.savePinnedPlaylists(username: username, playlists: pinned)
            }
            return true
        } catch {
            return false
        }
    }

    /// Backend cover first, Navidrome as fallback — uses shared PlaylistCoverCache
    /// with disk persistence, downsampling, and request deduplication.
    private func fetchCover() async -> UIImage? {
        let cache = PlaylistCoverCache.shared
        let hash = cache.contentHash(for: initialPlaylist.id)
        var urls: [URL] = []
        if BackendState.shared.isAvailable,
           let u = api.playlistBackendCoverURL(playlistId: initialPlaylist.id, contentHash: hash) { urls.append(u) }
        // size=1000 para el cover del hero (~236pt @3x ≈ 708px).
        // El prefetch de miniaturas de listado sigue en 600 (no se toca).
        if let u = api.coverURL(id: initialPlaylist.coverArt, size: 1000) { urls.append(u) }
        return await cache.loadCover(
            playlistId: initialPlaylist.id, urls: urls, maxPixels: 1000
        )
    }
}

// MARK: - Main View

/// Propaga la altura medida del bloque de título del hero hacia PlaylistDetailView.
private struct PlaylistTitleBlockHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 52
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct PlaylistDetailView: View {
    @StateObject private var vm: PlaylistDetailViewModel
    @State private var scrollY: CGFloat = 0
    @State private var showDeleteConfirm = false
    // See AlbumDetailView for rationale: defends against ghost taps after
    // .navigationTransition(.zoom) pop firing the play action of a no-longer-visible view.
    @State private var isViewVisible = false
    /// Altura medida del bloque de título+metadata (para que heroHeight la
    /// incluya y los huecos del hero no dependan del nº de líneas). Igual que
    /// AlbumDetailView.
    @State private var titleBlockHeight: CGFloat = 52
    var onDismiss: (() -> Void)?
    var onDeleted: (() -> Void)?

    /// Altura del hero = inset + cover + título (medido) + huecos fijos. Misma
    /// mecánica que AlbumDetailView: la cover queda anclada bajo la barra y el
    /// hueco hacia la lista es constante. 164 = inset extra (88) + 3 huecos de
    /// 20 + bloque de botones (~48), menos el hueco final reducido.
    private var heroHeight: CGFloat { safeAreaTop + coverSize + titleBlockHeight + 164 }

    init(playlist: NavidromePlaylist, onDismiss: (() -> Void)? = nil, onDeleted: (() -> Void)? = nil) {
        _vm = StateObject(wrappedValue: PlaylistDetailViewModel(playlist: playlist))
        self.onDismiss = onDismiss
        self.onDeleted = onDeleted
    }

    // MARK: Scroll-derived values

    private var scrollProgress: CGFloat { min(max(scrollY / heroHeight, 0), 1) }
    private var heroOpacity: CGFloat    { 1 - min(scrollProgress * 1.2, 0.92) }
    private var stickyOpacity: CGFloat  { min(max((scrollProgress - 0.55) / 0.25, 0), 1) }
    /// Stretchy header scale: proporcional al pull-down. Anchor `.bottom`
    /// para que el header gane altura hacia arriba en el rebound.
    private var stretchScale: CGFloat {
        let pullDown = max(0, -scrollY)
        return (heroHeight + pullDown) / heroHeight
    }

    private var isLight: Bool { vm.palette.isPrimaryLight }
    private var pageBg: Color { Color(vm.palette.pageBackgroundColor) }

    /// Tamaño del cover en el hero — escalado con el ancho de pantalla al
    /// estilo Apple Music: ~72% del width con cap a 320pt. En iPhone 15/16
    /// ≈ 283pt, en Pro Max ≈ 310pt, en SE ≈ 270pt. (Igual que AlbumDetail.)
    /// Usa `connectedScenes` porque `UIScreen.main` está deprecado en iOS 26.
    private var coverSize: CGFloat {
        let width: CGFloat = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 393
        return min(width * 0.72, 320)
    }

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

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            pageBg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    heroSection
                    songListSection
                    statsFooter
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
            await vm.load()
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
                Text(vm.displayPlaylist.name)
                    .font(.headline)
                    .foregroundStyle(isLight ? Color.black : .white)
                    .lineLimit(1)
                    .opacity(stickyOpacity)
            }
            ToolbarItem(placement: .topBarTrailing) {
                toolbarMenu
            }
        }
        .confirmationDialog(
            L.deleteConfirm(vm.displayPlaylist.name),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L.deletePlaylist, role: .destructive) {
                Task {
                    if await vm.deletePlaylist() {
                        if let onDismiss {
                            onDismiss()
                        }
                        onDeleted?()
                    }
                }
            }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.irreversibleAction)
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            // Stretchy header + extensión al notch + heroFade hacia pageBg.
            // Mismo patrón que AlbumDetailView: frame extendido + overlay del
            // fade ANTES del offset (viaja con el backdrop) + offset compensatorio.
            // El ZStack mantiene `frame(height: heroHeight)` para no romper el
            // flow del scroll content; el offset es puramente visual.
            heroBackground
                .frame(height: heroHeight + safeAreaTop)
                .overlay(alignment: .bottom) {
                    LinearGradient.heroFade(to: pageBg)
                        .frame(height: heroHeight * 0.55)
                        .allowsHitTesting(false)
                }
                .offset(y: -safeAreaTop)
                .scaleEffect(stretchScale, anchor: .bottom)

            // Content sits above the masked background — no fade applied to it
            heroContent
                .opacity(heroOpacity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
    }

    @ViewBuilder
    private var heroBackground: some View {
        if vm.palette.isSolid {
            Color(vm.palette.primary).ignoresSafeArea(edges: .top)
        } else {
            ZStack {
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
            // Cover anclada ARRIBA, por debajo de la barra de navegación. Misma
            // mecánica que AlbumDetailView: safeAreaTop no incluye la barra
            // (~44pt) y la ScrollView con ignoresSafeArea sube el contenido
            // ~32pt, por eso el inset es safeAreaTop+88 (cover en ~y118).
            Spacer().frame(height: safeAreaTop + 88)

            // Cover art — centered
            PlaylistCoverImage(playlist: vm.displayPlaylist, image: vm.coverImage)
                .frame(width: coverSize, height: coverSize)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.55), radius: 22, x: 0, y: 8)

            Spacer().frame(height: 20)   // hueco FIJO cover↔título

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
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: PlaylistTitleBlockHeightKey.self, value: g.size.height)
                }
            )

            // Action buttons. Hueco superior fijo (20pt); el inferior, hacia la
            // lista, lo da el spacer final (pequeño y constante).
            actionButtons
                .padding(.top, 20)

            Spacer(minLength: 8)   // hueco FIJO botones↔lista (≈18pt con heroHeight)
        }
        .frame(maxWidth: .infinity)
        .onPreferenceChange(PlaylistTitleBlockHeightKey.self) { titleBlockHeight = $0 }
    }

    /// Subtítulo del hero, dependiente del tipo de playlist:
    /// - System (editorial / smart / spotify-synced / mix diario): "Incluye X,
    ///   Y y Z" con los tres primeros artistas únicos por orden de aparición
    ///   en la tracklist. Si hay <3 artistas únicos, ajusta gramaticalmente
    ///   (1 → "Incluye X", 2 → "Incluye X y Y").
    /// - Propia / pública de otro usuario: "Creada por {owner}" (legacy).
    /// El contador songCount + duration se movió al footer del scroll
    /// (`statsFooter`) por coherencia con AlbumDetailView.
    @ViewBuilder
    private var metadataLine: some View {
        let textColor: Color = isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.75)
        // Usamos `initialPlaylist` (de la lista) y NO `displayPlaylist`: el
        // detalle de Subsonic (`getPlaylistSongs`) llega con `comment` y `owner`
        // a nil, así que `displayPlaylist.isSystemPlaylist` solo detectaría las
        // Mix Diario (por nombre). `initialPlaylist` conserva el comment, de
        // modo que "Incluye X, Y y Z" sale también en editorial, smart y spotify.
        let pl = vm.initialPlaylist
        let text: String? = {
            if pl.isSystemPlaylist {
                let included = firstUniqueArtists(in: vm.songs, max: 3)
                if included.isEmpty { return nil } // tracklist aún cargando
                return "Incluye \(joinedArtists(included))"
            }
            if let owner = pl.owner, !owner.isEmpty {
                return "Creada por \(owner)"
            }
            return nil
        }()

        if let text {
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(textColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    /// Recorre `songs` en orden y devuelve hasta `max` nombres de artista
    /// únicos. Usa un Set local para dedupe sin alterar el orden de aparición.
    /// Limita el scan a las primeras 200 pistas para que playlists enormes no
    /// recorran la lista completa en cada re-render — los 3 primeros artistas
    /// salen siempre del top.
    private func firstUniqueArtists(in songs: [NavidromeSong], max: Int) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for song in songs.prefix(200) {
            let name = song.artist
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            ordered.append(name)
            if ordered.count >= max { break }
        }
        return ordered
    }

    /// Une artistas en castellano: 1 → "X", 2 → "X y Y", 3+ → "X, Y y Z".
    private func joinedArtists(_ artists: [String]) -> String {
        switch artists.count {
        case 0: return ""
        case 1: return artists[0]
        case 2: return "\(artists[0]) y \(artists[1])"
        default:
            let head = artists.dropLast().joined(separator: ", ")
            return "\(head) y \(artists.last!)"
        }
    }

    private var actionButtons: some View {
        // Mismo estilo Apple Music iOS 26.4 (centralizado en `AlbumPalette`).
        // PlaylistDetail no expone motion artwork hoy (no hay endpoint backend),
        // así que motionPresent es siempre false. SmartMix recibe el mismo
        // par accent (shuffleBg/shuffleFg) para mantener consistencia visual.
        let playBg = Color(vm.palette.playButtonBackground(motionPresent: false))
        let playFg = Color(vm.palette.playButtonForeground(motionPresent: false))
        let shuffleBg = Color(vm.palette.shuffleButtonBackground(motionPresent: false))
        let shuffleFg = Color(vm.palette.shuffleButtonForeground(motionPresent: false))
        let nowPlaying = NowPlayingState.shared
        let isPlaylistContext = nowPlaying.isVisible && nowPlaying.contextUri == "playlist:\(vm.displayPlaylist.id)"
        let isPlaylistPlaying = isPlaylistContext && nowPlaying.isPlaying
        let smartMixReady = vm.smartMixStatus == .ready && BackendState.shared.isAvailable
        // SmartMix is the live context only when its dedicated URI scheme is
        // active — not just because it was generated for this playlist.
        let isSmartMixContext = nowPlaying.isVisible && nowPlaying.contextUri == "smartmix:\(vm.initialPlaylist.id)"
        let collapsePlay = smartMixReady || isSmartMixContext

        return HStack(spacing: 12) {
            // Play — capsule with text normally, collapses to circle when SmartMix active
            Button {
                guard isViewVisible else { return }
                if isPlaylistContext {
                    PlayerService.shared.togglePlayPause()
                } else {
                    guard !vm.songs.isEmpty else { return }
                    PlayerService.shared.playPlaylist(vm.songs, contextUri: "playlist:\(vm.displayPlaylist.id)", contextName: vm.displayPlaylist.name)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isPlaylistPlaying ? "pause.fill" : "play.fill")
                    if !collapsePlay {
                        Text(isPlaylistContext ? L.pause : L.play)
                            .fontWeight(.semibold)
                            .transition(.blurReplace)
                    }
                }
                .font(.system(size: 17))
                .foregroundStyle(playFg)
                .padding(.horizontal, collapsePlay ? 0 : 28)
                .padding(.vertical, 13)
                .frame(width: collapsePlay ? 48 : nil, height: 48)
                .background(playBg, in: Capsule())
                .animation(Anim.moderate, value: isPlaylistPlaying)
            }

            // Shuffle
            Button {
                guard isViewVisible, !vm.songs.isEmpty else { return }
                PlayerService.shared.playPlaylist(vm.songs.shuffled(), contextUri: "playlist:\(vm.displayPlaylist.id)", contextName: vm.displayPlaylist.name)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(shuffleFg)
                    .frame(width: 48, height: 48)
                    .background(shuffleBg, in: Circle())
            }

            // SmartMix (only when backend is available) — usa el par accent
            // del shuffle para que se integre visualmente con el resto.
            if BackendState.shared.isAvailable {
                smartMixButton(fillColor: shuffleBg, labelColor: shuffleFg)
            }
        }
        .animation(Anim.moderate, value: smartMixReady)
        .disabled(vm.isLoading)
    }

    @ViewBuilder
    private var toolbarMenu: some View {
        let pl = vm.displayPlaylist
        let hasSongs = !vm.songs.isEmpty
        let hasMenuItems = hasSongs || BackendState.shared.isAvailable || !pl.isSystemPlaylist

        if hasMenuItems {
            Menu {
                // Download (user playlists only)
                if hasSongs && !pl.isSystemPlaylist {
                    Button {
                        DownloadManager.shared.downloadPlaylist(
                            playlistId: pl.id,
                            title: pl.name,
                            songs: vm.songs,
                            pin: false
                        )
                    } label: {
                        Label(L.download, systemImage: "arrow.down.circle")
                    }
                }

                // Pin / Unpin (backend only)
                if BackendState.shared.isAvailable {
                    Button {
                        vm.togglePinned()
                    } label: {
                        Label(
                            vm.isPinned ? L.unpin : L.pin,
                            systemImage: vm.isPinned ? "star.slash.fill" : "star.fill"
                        )
                    }
                }

                // Delete — only playlists OWNED by the current user, and never
                // for editorial / smart / spotify-synced / mix diario (covered
                // by `isSystemPlaylist`). A user can favourite or follow another
                // user's public playlist; we must not let them delete it.
                if !pl.isSystemPlaylist && pl.isOwnedByCurrentUser {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label(L.deletePlaylist, systemImage: "trash")
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isLight ? Color.black : .white)
            }
        }
    }

    /// SmartMix button — idle/analyzing/error show a compact circle;
    /// ready expands into a capsule with "SmartMix" label, mirroring the
    /// Play button's capsule shape. The Play button simultaneously collapses
    /// to a circle, creating a smooth hand-off of visual prominence.
    @ViewBuilder
    private func smartMixButton(fillColor: Color, labelColor: Color) -> some View {
        let status = vm.smartMixStatus
        let nowPlaying = NowPlayingState.shared
        // True only while the SmartMix queue is the live playback context;
        // status alone (.ready / .analyzing) does NOT imply SmartMix is sounding.
        let isSmartMixContext = nowPlaying.isVisible && nowPlaying.contextUri == "smartmix:\(vm.initialPlaylist.id)"
        let isSmartMixPlaying = isSmartMixContext && nowPlaying.isPlaying
        let isExpanded = status == .ready || isSmartMixContext

        Button {
            guard isViewVisible else { return }
            if isSmartMixContext {
                // SmartMix is the current context — toggle play/pause
                PlayerService.shared.togglePlayPause()
            } else {
                switch status {
                case .idle, .error:
                    PlayerService.shared.generateSmartMix(
                        playlistId: vm.initialPlaylist.id,
                        songs: vm.songs
                    )
                case .ready:
                    PlayerService.shared.playSmartMix(playlistId: vm.initialPlaylist.id, playlistName: vm.displayPlaylist.name)
                case .analyzing:
                    break
                }
            }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    if isSmartMixPlaying {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(labelColor)
                            .transition(.blurReplace)
                    } else if isSmartMixContext {
                        // Paused but still the active context
                        Image(systemName: "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(labelColor)
                            .transition(.blurReplace)
                    } else {
                        switch status {
                        case .idle:
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(labelColor)
                                .transition(.blurReplace)

                        case .analyzing:
                            ProgressView()
                                .controlSize(.small)
                                .tint(labelColor)
                                .transition(.blurReplace)

                        case .ready:
                            Image(systemName: "play.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(labelColor)
                                .transition(.blurReplace)

                        case .error:
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(labelColor.opacity(0.6))
                                .transition(.blurReplace)
                        }
                    }
                }

                if isExpanded {
                    Text("SmartMix")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(labelColor)
                        .transition(.blurReplace)
                }
            }
            .padding(.horizontal, isExpanded ? 28 : 0)
            .padding(.vertical, 13)
            .frame(width: isExpanded ? nil : 48, height: 48)
            .background(fillColor, in: Capsule())
            .animation(Anim.moderate, value: status)
            .animation(Anim.moderate, value: isSmartMixPlaying)
        }
        .disabled(status == .analyzing || vm.songs.isEmpty)
        .sensoryFeedback(.success, trigger: status == .ready)
    }


    // MARK: - Song list

    private var songListSection: some View {
        Group {
            if vm.isLoading {
                SongListSkeleton(
                    count: max(vm.displayPlaylist.songCount, 6),
                    palette: vm.palette,
                    showCover: true
                )
            } else {
                SongListView(songs: vm.songs, palette: vm.palette, showAlbumInMenu: true, showCover: true, contextUri: "playlist:\(vm.displayPlaylist.id)", contextName: vm.displayPlaylist.name)
            }
        }
    }

    /// Footer "N canciones · M min" estilo Apple Music, alineado a la izquierda
    /// debajo del tracklist. Se basa en `displayPlaylist.songCount` y
    /// `displayPlaylist.duration` (datos del header de Subsonic) para que
    /// aparezca antes incluso de que `vm.songs` termine de cargar. Si la
    /// playlist está vacía, no se renderiza.
    @ViewBuilder
    private var statsFooter: some View {
        let pl = vm.displayPlaylist
        if pl.songCount > 0 {
            let durationText = pl.duration > 0 ? " · \(formatDuration(pl.duration))" : ""
            Text("\(L.songCount(pl.songCount))\(durationText)")
                .font(.system(size: 12))
                .foregroundStyle(isLight ? Color.black.opacity(0.30) : Color.white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 16)
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

    @State private var loadedImage: UIImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let img = image ?? loadedImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else if didFail {
                placeholderView
            } else {
                placeholderView
            }
        }
        .task(id: playlist.id) {
            guard image == nil else { return }
            await loadCover()
        }
        .onAppear {
            if image == nil && loadedImage == nil && !didFail {
                Task { await loadCover() }
            }
        }
    }

    private func loadCover() async {
        guard loadedImage == nil else { return }
        let api = NavidromeService.shared
        let cache = PlaylistCoverCache.shared
        let hash = cache.contentHash(for: playlist.id)
        var urls: [URL] = []
        if BackendState.shared.isAvailable,
           let u = api.playlistBackendCoverURL(playlistId: playlist.id, contentHash: hash) { urls.append(u) }
        if let u = api.coverURL(id: playlist.coverArt, size: 600) { urls.append(u) }

        if let img = await cache.loadCover(
            playlistId: playlist.id, urls: urls, maxPixels: 600
        ) {
            loadedImage = img
        } else {
            didFail = true
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

// MARK: - Playlist cover cache (RAM + disk, with downsampling & dedup)

final class PlaylistCoverCache: @unchecked Sendable {
    static let shared = PlaylistCoverCache()

    private let memory = NSCache<NSString, UIImage>()
    private let diskDir: URL
    private let ioQueue = DispatchQueue(label: "playlist.cover.cache", qos: .utility)
    private let coordinator = PlaylistCoverDownloadCoordinator()

    /// Serializes mutation/read of `contentHashes` and `cachedHashes`. The cache
    /// is hit concurrently from MainActor (prefetch, body re-renders) and from
    /// background async tasks (refreshPlaylistCoverHashes, loadCover→setImage).
    /// Without this, reading a Swift Dictionary while another thread reallocates
    /// its buffer dereferences a freed pointer (EXC_BAD_ACCESS at low address).
    private let hashLock = NSLock()

    /// Known content hashes from backend (playlistId → coverContentHash).
    /// Used to append ?v= for immutable caching and to detect stale covers.
    private var contentHashes: [String: String] = [:]
    /// Hashes that were active when covers were last cached to disk.
    private var cachedHashes: [String: String] = [:]

    /// Fires the playlistId whenever a cover entry is invalidated. Views that
    /// hold the previous image in @State subscribe and reload — without this,
    /// a cached image survives in the view tree even after the disk entry was
    /// dropped on hash change.
    let coverInvalidated = PassthroughSubject<String, Never>()

    private init() {
        memory.countLimit = 200
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = caches.appendingPathComponent("playlist_covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)

        // Restore persisted hashes
        let hashesFile = diskDir.appendingPathComponent("_hashes.json")
        if let data = try? Data(contentsOf: hashesFile),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            cachedHashes = dict
        }
    }

    private func diskPath(for playlistId: String) -> URL {
        diskDir.appendingPathComponent(playlistId + ".jpg")
    }

    private func persistHashes() {
        let path = diskDir.appendingPathComponent("_hashes.json")
        hashLock.lock()
        let hashes = cachedHashes
        hashLock.unlock()
        ioQueue.async {
            if let data = try? JSONEncoder().encode(hashes) {
                try? data.write(to: path, options: .atomic)
            }
        }
    }

    // MARK: Read (RAM → disk)

    func image(for playlistId: String) -> UIImage? {
        if let img = memory.object(forKey: playlistId as NSString) { return img }
        let path = diskPath(for: playlistId)
        guard let data = try? Data(contentsOf: path),
              let img = UIImage(data: data) else { return nil }
        memory.setObject(img, forKey: playlistId as NSString)
        return img
    }

    // MARK: Write (RAM + async disk as compressed JPEG)

    func setImage(_ image: UIImage, for playlistId: String) {
        memory.setObject(image, forKey: playlistId as NSString)
        // Track which hash this cover was saved under
        hashLock.lock()
        let hash = contentHashes[playlistId]
        if let hash {
            cachedHashes[playlistId] = hash
        }
        hashLock.unlock()
        if hash != nil { persistHashes() }
        let path = diskPath(for: playlistId)
        ioQueue.async {
            if let data = image.jpegData(compressionQuality: 0.82) {
                try? data.write(to: path, options: .atomic)
            }
        }
    }

    // MARK: Invalidate

    func invalidate(playlistId: String) {
        memory.removeObject(forKey: playlistId as NSString)
        hashLock.lock()
        cachedHashes.removeValue(forKey: playlistId)
        hashLock.unlock()
        persistHashes()
        let path = diskPath(for: playlistId)
        // SYNC delete is load-bearing: image(for:) reads disk synchronously, so any
        // caller that runs between this line and the async drain (prefetch on the
        // same run loop, onReceive→loadCover subscribers) would otherwise find the
        // stale JPG, repopulate the memory cache, and silently undo the invalidation.
        ioQueue.sync { try? FileManager.default.removeItem(at: path) }
        // Palette is derived from the cover — keep them in sync.
        PaletteCache.shared.invalidate(key: playlistId)
        coverInvalidated.send(playlistId)
    }

    // MARK: Content hash management

    /// Returns the known content hash for a playlist (nil for user playlists or unknown).
    func contentHash(for playlistId: String) -> String? {
        hashLock.lock(); defer { hashLock.unlock() }
        return contentHashes[playlistId]
    }

    /// Register content hashes from backend API responses.
    /// Automatically invalidates covers whose hash changed or that were cached
    /// without hash tracking (legacy entries from before content-addressed caching).
    func registerContentHashes(_ hashes: [String: String]) {
        // Decide invalidations under the lock, but call invalidate() outside it —
        // invalidate() takes the same lock, so doing it inline would deadlock.
        var toInvalidate: [String] = []
        hashLock.lock()
        for (id, newHash) in hashes {
            let oldHash = contentHashes[id]
            contentHashes[id] = newHash

            if let cachedHash = cachedHashes[id] {
                // Cover was cached with a known hash — only invalidate if hash changed
                if cachedHash != newHash { toInvalidate.append(id) }
            } else if oldHash != nil && oldHash != newHash {
                // Hash changed within this session
                toInvalidate.append(id)
            } else if oldHash == nil {
                // No hash record on disk — cover may be stale (pre-hash-tracking legacy).
                // Invalidate to force re-fetch with proper ?v= content-addressed URL.
                toInvalidate.append(id)
            }
        }
        hashLock.unlock()
        for id in toInvalidate {
            invalidate(playlistId: id)
        }
    }

    // MARK: Coalesced download with downsampling

    /// Downloads a cover, downsizing to `maxPixels` during decode to save RAM.
    /// Concurrent requests for the same playlist coalesce into a single download.
    ///
    /// URL ordering convention: `urls[0]` is the *preferred* source (backend custom
    /// cover when available); subsequent URLs are progressively cheaper fallbacks
    /// (Navidrome 4-tile mosaic). Transient failures on the preferred URL retry
    /// with backoff before falling through, so a single timeout/5xx doesn't
    /// downgrade the user to the mosaic when a custom cover actually exists.
    /// 404 falls through immediately (no custom cover for this playlist).
    func loadCover(playlistId: String, urls: [URL], maxPixels: Int = 600) async -> UIImage? {
        if let cached = image(for: playlistId) { return cached }
        let cache = self
        let maxPx = maxPixels
        return await coordinator.download(id: playlistId) {
            for (index, url) in urls.enumerated() {
                let isPreferred = index == 0 && urls.count > 1
                let maxAttempts = isPreferred ? 3 : 1

                for attempt in 0..<maxAttempts {
                    if attempt > 0 {
                        // Backoff: 600ms, 1.4s
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 800_000_000 - 200_000_000)
                    }

                    guard let (data, resp) = try? await AudiorrNetwork.background.data(from: url),
                          let http = resp as? HTTPURLResponse else {
                        continue  // network error → retry (or fall through if last attempt)
                    }

                    // 404 = cover doesn't exist on this server. No point retrying — fall through.
                    if http.statusCode == 404 { break }

                    // Non-200 (5xx, etc.) = transient → retry within this URL's attempts.
                    guard http.statusCode == 200 else { continue }

                    let img = Self.downsample(data: data, maxPixels: maxPx) ?? UIImage(data: data)
                    if let img {
                        cache.setImage(img, for: playlistId)
                        return img
                    }
                    // Decoded nil → don't retry (data won't change), fall through.
                    break
                }
            }
            return nil
        }
    }

    // MARK: Prefetch (fire-and-forget for a batch)

    @MainActor func prefetch(playlists: [NavidromePlaylist], maxPixels: Int = 600) {
        let api = NavidromeService.shared
        let backendAvailable = BackendState.shared.isAvailable
        for pl in playlists {
            guard image(for: pl.id) == nil else { continue }
            hashLock.lock()
            let hash = contentHashes[pl.id]
            hashLock.unlock()
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                var urls: [URL] = []
                if backendAvailable, let u = api.playlistBackendCoverURL(playlistId: pl.id, contentHash: hash) { urls.append(u) }
                if let u = api.coverURL(id: pl.coverArt, size: maxPixels) { urls.append(u) }
                guard !urls.isEmpty else { return }
                _ = await self.loadCover(playlistId: pl.id, urls: urls, maxPixels: maxPixels)
            }
        }
    }

    // MARK: Downsample via CGImageSource (decode directly at target size)

    private static func downsample(data: Data, maxPixels: Int) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Actor that deduplicates concurrent cover downloads for the same playlist.
private actor PlaylistCoverDownloadCoordinator {
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func download(id: String, work: @Sendable @escaping () async -> UIImage?) async -> UIImage? {
        if let existing = inFlight[id] { return await existing.value }
        let task = Task<UIImage?, Never> { await work() }
        inFlight[id] = task
        let result = await task.value
        inFlight.removeValue(forKey: id)
        return result
    }
}

// MARK: - PlaylistCoverView (grid thumbnail — PlaylistsView.swift)

/// Thumbnail variant used in the playlists grid.
/// Loads Navidrome cover instantly, then upgrades to backend cover if available.
/// Cached in PlaylistCoverCache to survive tab switches without flashing.
struct PlaylistCoverView: View {
    let playlist: NavidromePlaylist
    var size: CGFloat = 160

    @State private var coverImage: UIImage?
    @State private var didFail = false

    private var isFlexible: Bool { size.isInfinite }
    private var cornerRadius: CGFloat { isFlexible ? 12 : size * 0.12 }
    private var imageSize: Int { isFlexible ? 300 : Int(size * 2) }

    var body: some View {
        imageContent
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: playlist.id) { await loadCover() }
            .onAppear {
                if coverImage == nil && !didFail {
                    if let cached = PlaylistCoverCache.shared.image(for: playlist.id) {
                        coverImage = cached
                    } else {
                        Task { await loadCover() }
                    }
                }
            }
            .onReceive(PlaylistCoverCache.shared.coverInvalidated.receive(on: RunLoop.main)) { id in
                guard id == playlist.id else { return }
                coverImage = nil
                didFail = false
                Task { await loadCover() }
            }
    }

    @ViewBuilder
    private var imageContent: some View {
        let content: some View = Group {
            if let img = coverImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else if didFail {
                placeholder
            } else {
                SkeletonView()
            }
        }

        if isFlexible {
            content
        } else {
            content.frame(width: size, height: size)
        }
    }

    private func loadCover() async {
        let api = NavidromeService.shared
        let cache = PlaylistCoverCache.shared
        let hash = cache.contentHash(for: playlist.id)
        var urls: [URL] = []
        if BackendState.shared.isAvailable,
           let u = api.playlistBackendCoverURL(playlistId: playlist.id, contentHash: hash) { urls.append(u) }
        if let u = api.coverURL(id: playlist.coverArt, size: imageSize) { urls.append(u) }
        guard !urls.isEmpty else { didFail = true; return }

        if let img = await cache.loadCover(
            playlistId: playlist.id, urls: urls, maxPixels: imageSize
        ) {
            coverImage = img
        } else {
            didFail = true
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

// MARK: - Skeleton shimmer

struct SkeletonView: View {
    @State private var shimmer = false

    var body: some View {
        Color(.tertiarySystemFill)
            .overlay(
                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.12), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: shimmer ? 300 : -300)
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    shimmer = true
                }
            }
    }
}

// MARK: - Playlist hero overlay modifier

