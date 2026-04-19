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

    init(playlist: NavidromePlaylist) {
        self.initialPlaylist = playlist
        self.playlist = playlist

        // Pre-load cached cover so hero transition doesn't flash placeholder
        if let cached = AlbumCoverCache.shared.image(for: playlist.coverArt) {
            self.coverImage = cached
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
    }

    var displayPlaylist: NavidromePlaylist { playlist ?? initialPlaylist }

    func load() async {
        guard songs.isEmpty else { return }
        isLoading = true

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
            let extracted = await Task.detached(priority: .userInitiated) {
                ColorExtractor.extract(from: image)
            }.value
            self.palette = extracted
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

    /// Backend cover first, Navidrome as fallback — mirrors PlaylistCoverView logic.
    /// Skips backend when unavailable to avoid long timeouts blocking the UI.
    private func fetchCover() async -> UIImage? {
        // 1. Try backend generated cover (only if backend is reachable)
        if BackendState.shared.isAvailable,
           let backendURL = api.playlistBackendCoverURL(playlistId: initialPlaylist.id),
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
    @State private var showDeleteConfirm = false
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
                Text(vm.displayPlaylist.name)
                    .font(.headline)
                    .foregroundStyle(isLight ? Color.black : .white)
                    .lineLimit(1)
                    .opacity(stickyOpacity)
            }
        }
        .confirmationDialog(
            "Eliminar «\(vm.displayPlaylist.name)»",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Eliminar playlist", role: .destructive) {
                Task {
                    if await vm.deletePlaylist() {
                        if let onDismiss {
                            onDismiss()
                        }
                        onDeleted?()
                    }
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Esta acción no se puede deshacer.")
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
        if pl.songCount > 0 { parts.append("\(pl.songCount) canciones") }
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

        return HStack(spacing: 12) {
            // Play
            Button {
                guard !vm.songs.isEmpty else { return }
                PlayerService.shared.playPlaylist(vm.songs, contextUri: "playlist:\(vm.displayPlaylist.id)", contextName: vm.displayPlaylist.name)
            } label: {
                if BackendState.shared.isAvailable {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(labelColor)
                        .frame(width: 40, height: 40)
                        .background(fillColor, in: Circle())
                } else {
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
            }

            // Shuffle
            Button {
                guard !vm.songs.isEmpty else { return }
                PlayerService.shared.playPlaylist(vm.songs.shuffled(), contextUri: "playlist:\(vm.displayPlaylist.id)", contextName: vm.displayPlaylist.name)
            } label: {
                if BackendState.shared.isAvailable {
                    Image(systemName: "shuffle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(labelColor)
                        .frame(width: 40, height: 40)
                        .background(fillColor, in: Circle())
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: "shuffle")
                        Text("Aleatorio")
                            .fontWeight(.semibold)
                    }
                    .font(.system(size: 15))
                    .foregroundStyle(labelColor)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(fillColor, in: Capsule())
                }
            }

            // Download — only for user playlists (not editorial/smart/spotify)
            if !vm.songs.isEmpty && !vm.displayPlaylist.isSystemPlaylist {
                DownloadButton(
                    groupId: vm.displayPlaylist.id,
                    groupType: "playlist",
                    title: vm.displayPlaylist.name,
                    songs: vm.songs,
                    fillColor: fillColor,
                    labelColor: labelColor
                )
            }

            // SmartMix + Star + More (only when backend is available)
            if BackendState.shared.isAvailable {
                smartMixButton(fillColor: fillColor, labelColor: labelColor)

                Button {
                    vm.togglePinned()
                } label: {
                    Image(systemName: vm.isPinned ? "star.fill" : "star")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(vm.isPinned ? .yellow : labelColor)
                        .frame(width: 40, height: 40)
                        .background(
                            fillColor.opacity(vm.isPinned ? 0.85 : 1),
                            in: Circle()
                        )
                }

                // Context menu (ellipsis) — delete for user playlists
                if !vm.displayPlaylist.isSystemPlaylist {
                    Menu {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Eliminar playlist", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(labelColor)
                            .frame(width: 40, height: 40)
                            .background(fillColor, in: Circle())
                    }
                }
            }
        }
        .disabled(vm.isLoading)
    }

    @ViewBuilder
    private func smartMixButton(fillColor: Color, labelColor: Color) -> some View {
        let status = vm.smartMixStatus

        Button {
            switch status {
            case .idle, .error:
                PlayerService.shared.generateSmartMix(
                    playlistId: vm.initialPlaylist.id,
                    songs: vm.songs
                )
            case .ready:
                PlayerService.shared.playSmartMix(playlistId: vm.initialPlaylist.id)
            case .analyzing:
                break // disabled
            }
        } label: {
            ZStack {
                switch status {
                case .idle, .ready:
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(labelColor)
                case .analyzing:
                    ProgressView()
                        .controlSize(.small)
                        .tint(labelColor)
                case .error:
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(labelColor.opacity(0.5))
                }
            }
            .frame(width: 40, height: 40)
            .background(fillColor, in: Circle())
        }
        .disabled(status == .analyzing || vm.songs.isEmpty)
    }

    private func smartMixLabel(for status: SmartMixStatus) -> String {
        switch status {
        case .idle:      return "SmartMix"
        case .analyzing: return "Analizando…"
        case .ready:     return "SmartMix"
        case .error:     return "Reintentar"
        }
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
                SongListView(songs: vm.songs, palette: vm.palette, showAlbumInMenu: true, contextUri: "playlist:\(vm.displayPlaylist.id)", contextName: vm.displayPlaylist.name)
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
        let urls: [URL] = [
            NavidromeService.shared.playlistBackendCoverURL(playlistId: playlist.id),
            NavidromeService.shared.coverURL(id: playlist.coverArt, size: 600),
        ].compactMap { $0 }

        for url in urls {
            for attempt in 0..<2 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                guard let (data, resp) = try? await URLSession.shared.data(from: url),
                      let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let img = UIImage(data: data) else { continue }
                loadedImage = img
                return
            }
        }
        didFail = true
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
                    Task { await loadCover() }
                }
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
        guard coverImage == nil else { return }

        let backendURL = NavidromeService.shared.playlistBackendCoverURL(playlistId: playlist.id)
        let navidromeURL = NavidromeService.shared.coverURL(id: playlist.coverArt, size: imageSize)

        // Try backend and Navidrome in parallel — use whichever responds first successfully
        if let backendURL, let navidromeURL {
            // Race both: backend cover (richer) vs Navidrome cover (faster fallback)
            let img = await withTaskGroup(of: UIImage?.self, returning: UIImage?.self) { group in
                group.addTask {
                    guard let (data, resp) = try? await URLSession.shared.data(from: backendURL),
                          let http = resp as? HTTPURLResponse, http.statusCode == 200,
                          let img = UIImage(data: data) else { return nil }
                    return img
                }
                group.addTask {
                    // Small delay to prefer backend cover if it's fast
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let (data, resp) = try? await URLSession.shared.data(from: navidromeURL),
                          let http = resp as? HTTPURLResponse, http.statusCode == 200,
                          let img = UIImage(data: data) else { return nil }
                    return img
                }
                // Return the first successful result
                for await result in group {
                    if let result {
                        group.cancelAll()
                        return result
                    }
                }
                return nil
            }
            if let img { coverImage = img; return }
        } else {
            // Only one URL available — try it directly
            let url = backendURL ?? navidromeURL
            if let url,
               let (data, resp) = try? await URLSession.shared.data(from: url),
               let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let img = UIImage(data: data) {
                coverImage = img
                return
            }
        }

        didFail = true
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

