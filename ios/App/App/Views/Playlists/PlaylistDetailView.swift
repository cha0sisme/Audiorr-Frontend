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
        if let u = api.coverURL(id: initialPlaylist.coverArt, size: 600) { urls.append(u) }
        return await cache.loadCover(
            playlistId: initialPlaylist.id, urls: urls, maxPixels: 600
        )
    }
}

// MARK: - Main View

struct PlaylistDetailView: View {
    @StateObject private var vm: PlaylistDetailViewModel
    @State private var scrollY: CGFloat = 0
    @State private var showDeleteConfirm = false
    // See AlbumDetailView for rationale: defends against ghost taps after
    // .navigationTransition(.zoom) pop firing the play action of a no-longer-visible view.
    @State private var isViewVisible = false
    var onDismiss: (() -> Void)?
    var onDeleted: (() -> Void)?

    private let heroHeight: CGFloat = 440

    init(playlist: NavidromePlaylist, onDismiss: (() -> Void)? = nil, onDeleted: (() -> Void)? = nil) {
        _vm = StateObject(wrappedValue: PlaylistDetailViewModel(playlist: playlist))
        self.onDismiss = onDismiss
        self.onDeleted = onDeleted
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
            // Background only gets the fade mask
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

            // Action buttons — centered
            actionButtons
                .padding(.top, 18)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
    }

    private var metadataLine: some View {
        let textColor: Color = isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.75)
        let pl = vm.displayPlaylist
        var parts: [String] = []
        if pl.songCount > 0 { parts.append(L.songCount(pl.songCount)) }
        if pl.duration > 0  { parts.append(formatDuration(pl.duration)) }
        if let owner = pl.owner, !owner.isEmpty { parts.append(owner) }

        return Text(parts.joined(separator: " · "))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(textColor)
            .lineLimit(1)
    }

    private var actionButtons: some View {
        let fillColor: Color  = Color(vm.palette.buttonFillColor)
        let labelColor: Color = vm.palette.buttonUsesBlackText ? .black : .white
        let nowPlaying = NowPlayingState.shared
        let isPlaylistContext = nowPlaying.isVisible && nowPlaying.contextUri == "playlist:\(vm.displayPlaylist.id)"
        let isPlaylistPlaying = isPlaylistContext && nowPlaying.isPlaying
        let smartMixReady = vm.smartMixStatus == .ready && BackendState.shared.isAvailable
        let isSmartMixContext = nowPlaying.isVisible && PlayerService.shared.smartMixPlaylistId == vm.initialPlaylist.id && vm.smartMixStatus != .idle
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
                HStack(spacing: 7) {
                    Image(systemName: isPlaylistPlaying ? "pause.fill" : "play.fill")
                    if !collapsePlay {
                        Text(isPlaylistContext ? L.pause : L.play)
                            .fontWeight(.semibold)
                            .transition(.blurReplace)
                    }
                }
                .font(.system(size: 15))
                .foregroundStyle(labelColor)
                .padding(.horizontal, collapsePlay ? 0 : 22)
                .padding(.vertical, 10)
                .frame(width: collapsePlay ? 40 : nil, height: 40)
                .background(fillColor, in: Capsule())
                .animation(Anim.moderate, value: isPlaylistPlaying)
            }

            // Shuffle
            Button {
                guard isViewVisible, !vm.songs.isEmpty else { return }
                PlayerService.shared.playPlaylist(vm.songs.shuffled(), contextUri: "playlist:\(vm.displayPlaylist.id)", contextName: vm.displayPlaylist.name)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(labelColor)
                    .frame(width: 40, height: 40)
                    .background(fillColor, in: Circle())
            }

            // SmartMix (only when backend is available)
            if BackendState.shared.isAvailable {
                smartMixButton(fillColor: fillColor, labelColor: labelColor)
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

                // Delete (user playlists only)
                if !pl.isSystemPlaylist {
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
                    .foregroundStyle(isLight ? Color.accentColor : .white)
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
        let isSmartMixContext = nowPlaying.isVisible && PlayerService.shared.smartMixPlaylistId == vm.initialPlaylist.id && status != .idle
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
            HStack(spacing: 7) {
                ZStack {
                    if isSmartMixPlaying {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(labelColor)
                            .transition(.blurReplace)
                    } else if isSmartMixContext {
                        // Paused but still the active context
                        Image(systemName: "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(labelColor)
                            .transition(.blurReplace)
                    } else {
                        switch status {
                        case .idle:
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(labelColor)
                                .transition(.blurReplace)

                        case .analyzing:
                            ProgressView()
                                .controlSize(.small)
                                .tint(labelColor)
                                .transition(.blurReplace)

                        case .ready:
                            Image(systemName: "play.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(labelColor)
                                .transition(.blurReplace)

                        case .error:
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(labelColor.opacity(0.6))
                                .transition(.blurReplace)
                        }
                    }
                }

                if isExpanded {
                    Text("SmartMix")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(labelColor)
                        .transition(.blurReplace)
                }
            }
            .padding(.horizontal, isExpanded ? 22 : 0)
            .padding(.vertical, 10)
            .frame(width: isExpanded ? nil : 40, height: 40)
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
                ProgressView()
                    .tint(isLight ? .secondary : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
            } else {
                SongListView(songs: vm.songs, palette: vm.palette, showAlbumInMenu: true, showCover: true, contextUri: "playlist:\(vm.displayPlaylist.id)", contextName: vm.displayPlaylist.name)
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
        let hashes = cachedHashes
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
        if let hash = contentHashes[playlistId] {
            cachedHashes[playlistId] = hash
            persistHashes()
        }
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
        cachedHashes.removeValue(forKey: playlistId)
        persistHashes()
        let path = diskPath(for: playlistId)
        ioQueue.async { try? FileManager.default.removeItem(at: path) }
        // Palette is derived from the cover — keep them in sync.
        PaletteCache.shared.invalidate(key: playlistId)
        coverInvalidated.send(playlistId)
    }

    // MARK: Content hash management

    /// Returns the known content hash for a playlist (nil for user playlists or unknown).
    func contentHash(for playlistId: String) -> String? {
        contentHashes[playlistId]
    }

    /// Register content hashes from backend API responses.
    /// Automatically invalidates covers whose hash changed or that were cached
    /// without hash tracking (legacy entries from before content-addressed caching).
    func registerContentHashes(_ hashes: [String: String]) {
        for (id, newHash) in hashes {
            let oldHash = contentHashes[id]
            contentHashes[id] = newHash

            if let cachedHash = cachedHashes[id] {
                // Cover was cached with a known hash — only invalidate if hash changed
                if cachedHash != newHash {
                    invalidate(playlistId: id)
                }
            } else if oldHash != nil && oldHash != newHash {
                // Hash changed within this session
                invalidate(playlistId: id)
            } else if oldHash == nil {
                // No hash record on disk — cover may be stale (pre-hash-tracking legacy).
                // Invalidate to force re-fetch with proper ?v= content-addressed URL.
                invalidate(playlistId: id)
            }
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

                    guard let (data, resp) = try? await URLSession.shared.data(from: url),
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
            let hash = contentHashes[pl.id]
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

