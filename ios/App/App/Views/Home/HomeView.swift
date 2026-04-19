import SwiftUI

// MARK: - View Model

@MainActor
final class HomeViewModel: ObservableObject {
    static let shared = HomeViewModel()

    @Published var topWeekly: [TopWeeklySong] = []
    @Published var recentContexts: [RecentContext] = []
    @Published var recentReleases: [NavidromeAlbum] = []
    @Published var dailyMixes: [DailyMix] = []
    @Published var dailyMixPlaylists: [NavidromePlaylist] = []
    @Published var latestAlbums: [NavidromeAlbum] = []

    @Published var isLoading = true
    @Published var isGeneratingMixes = false
    @Published var isBackendAvailable = false

    private let api = NavidromeService.shared
    private var lastLoadedAt: Date?
    /// Cache TTL — skip network if loaded less than 2 minutes ago.
    private let cacheTTL: TimeInterval = 120

    /// Load only if cache is stale or empty. Pass `force: true` for pull-to-refresh.
    func loadIfNeeded() async {
        if let last = lastLoadedAt, Date().timeIntervalSince(last) < cacheTTL, !topWeekly.isEmpty || !latestAlbums.isEmpty {
            return
        }
        await load()
    }

    func load() async {
        isLoading = true
        defer {
            isLoading = false
            lastLoadedAt = Date()
        }

        api.reloadCredentials()
        guard api.isConfigured else { return }

        // Check backend availability via shared service
        isBackendAvailable = await api.checkBackendAvailable()

        // Load all sections in parallel
        async let topTask: Void = loadTopWeekly()
        async let recentCtxTask: Void = loadRecentContexts()
        async let releasesTask: Void = loadRecentReleases()
        async let mixesTask: Void = loadDailyMixes()
        async let latestTask: Void = loadLatestAlbums()

        _ = await (topTask, recentCtxTask, releasesTask, mixesTask, latestTask)
    }

    // MARK: - Section loaders

    private func loadTopWeekly() async {
        guard isBackendAvailable else { return }
        topWeekly = await api.getTopWeekly()
    }

    private func loadRecentContexts() async {
        guard isBackendAvailable else { return }
        var contexts = Array(await api.getRecentContexts().prefix(6))

        // Enrich playlist/smartmix contexts with real name + song count from Navidrome
        let playlistIndices = contexts.enumerated().compactMap { (i, ctx) -> (Int, String)? in
            (ctx.type == "playlist" || ctx.type == "smartmix") ? (i, ctx.id) : nil
        }
        await withTaskGroup(of: (Int, String?, Int?).self) { group in
            for (index, pid) in playlistIndices {
                group.addTask {
                    let (playlist, _) = (try? await self.api.getPlaylistSongs(playlistId: pid)) ?? (nil, [])
                    return (index, playlist?.name, playlist?.songCount)
                }
            }
            for await (index, name, count) in group {
                if let name { contexts[index].title = name }
                if let count { contexts[index].songCount = count }
            }
        }

        recentContexts = contexts
    }

    private func loadRecentReleases() async {
        recentReleases = await api.getRecentReleases(months: 6, size: 18)
    }

    private func loadDailyMixes() async {
        guard isBackendAvailable else { return }
        let mixes = await api.getDailyMixes()
        dailyMixes = mixes

        if mixes.isEmpty {
            // Auto-generate on first visit
            await generateMixes()
        } else {
            await resolveMixPlaylists(mixes)
        }
    }

    func generateMixes() async {
        isGeneratingMixes = true
        defer { isGeneratingMixes = false }

        guard let result = await api.generateDailyMixes() else { return }
        if result.generated > 0 {
            let mixes = await api.getDailyMixes()
            dailyMixes = mixes
            await resolveMixPlaylists(mixes)
        } else {
            dailyMixes = result.mixes
        }
    }

    private func resolveMixPlaylists(_ mixes: [DailyMix]) async {
        // Convert DailyMix → NavidromePlaylist (for PlaylistCardView)
        let ids = mixes.compactMap(\.navidromeId)
        guard !ids.isEmpty, let allPlaylists = try? await api.getPlaylists() else {
            dailyMixPlaylists = []
            return
        }
        let idSet = Set(ids)
        dailyMixPlaylists = allPlaylists.filter { idSet.contains($0.id) }
    }

    private func loadLatestAlbums() async {
        latestAlbums = await api.getAlbumList(type: "newest", size: 50)
    }
}

// MARK: - HomeView

struct HomeView: View {
    @ObservedObject private var vm = HomeViewModel.shared
    @ObservedObject private var theme = AppTheme.shared
    private var network = NetworkMonitor.shared
    @State private var scrollY: CGFloat = 0
    @State private var offlineAlbums: [(albumId: String, name: String, artist: String, coverArt: String, songCount: Int, year: Int?)] = []
    @Namespace private var heroNS
    @State private var selectedAlbum: NavidromeAlbum?
    @State private var selectedPlaylist: NavidromePlaylist?
    @State private var navigationPath = NavigationPath()

    private let collapseThreshold: CGFloat = 44

    private var stickyOpacity: CGFloat {
        min(max((scrollY - collapseThreshold * 0.4) / (collapseThreshold * 0.6), 0), 1)
    }
    private var largeTitleOpacity: CGFloat {
        1 - min(max(scrollY / collapseThreshold, 0), 1)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    largeHeader

                    VStack(alignment: .leading, spacing: 24) {
                        if !network.isConnected {
                            offlineContentSection
                        } else if vm.isLoading {
                            loadingSkeleton
                        } else {
                            topWeeklySection
                            jumpBackInSection
                            recentReleasesSection
                            dailyMixSection
                            latestAlbumsSection
                        }

                        Spacer(minLength: 80)
                    }
                }
            }
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                scrollY = y
            }
            .modifier(AlbumHeroOverlay(selectedAlbum: $selectedAlbum, namespace: heroNS))
            .modifier(PlaylistHeroOverlay(selectedPlaylist: $selectedPlaylist, namespace: heroNS))
            .background(Color(.systemBackground))
            .toolbarBackground((selectedAlbum != nil || selectedPlaylist != nil) ? .hidden : (stickyOpacity > 0.5 ? .visible : .hidden), for: .navigationBar)
            .toolbar {
                if selectedAlbum == nil && selectedPlaylist == nil {
                    ToolbarItem(placement: .principal) {
                        Text("Inicio")
                            .font(.headline)
                            .lineLimit(1)
                            .opacity(stickyOpacity)
                    }
                }
            }
            .navigationDestination(for: NavidromeAlbum.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: NavidromeArtist.self) { ArtistDetailView(artist: $0) }
            .navigationDestination(for: NavidromePlaylist.self) { PlaylistDetailView(playlist: $0) }
            .navigationDestination(for: SeeAllDestination.self) { SeeAllGridView(destination: $0) }
            .task { await vm.loadIfNeeded() }
            .refreshable { await vm.load() }
            .onReceive(NotificationCenter.default.publisher(for: .audiorrDidLogin)) { _ in
                Task { await vm.load() }
            }
            .preferredColorScheme(theme.colorScheme)
        }
    }

    // MARK: - Programmatic navigation

    private func navigateToArtist(_ artist: NavidromeArtist) {
        navigationPath.append(artist)
    }

    // MARK: - Large header (Audiorr logo)

    private var largeHeader: some View {
        HStack(alignment: .bottom) {
            Image("AudiorrTabIcon")
                .resizable()
                .scaledToFit()
                .frame(height: 32)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .padding(.top, UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 59)
        .opacity(largeTitleOpacity)
    }

    // MARK: - Top Weekly

    @ViewBuilder
    private var topWeeklySection: some View {
        if vm.isBackendAvailable && !vm.topWeekly.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Lo más escuchado")
                    .font(.system(size: 22, weight: .bold))
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        // Split into groups of 5
                        let firstGroup = Array(vm.topWeekly.prefix(5))
                        let secondGroup = Array(vm.topWeekly.dropFirst(5).prefix(5))

                        topWeeklyGroup(firstGroup)
                        if !secondGroup.isEmpty {
                            topWeeklyGroup(secondGroup)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func topWeeklyGroup(_ songs: [TopWeeklySong]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                topWeeklyRow(song)

                if idx < songs.count - 1 {
                    Divider()
                        .padding(.leading, 56)
                }
            }
        }
        .frame(width: ((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 390) - 48)
    }

    private func topWeeklyRow(_ song: TopWeeklySong) -> some View {
        HStack(spacing: 12) {
            // Rank
            Text("\(song.rank)")
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)

            // Cover
            AsyncImage(url: NavidromeService.shared.coverURL(id: song.coverArt, size: 80)) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Color(.tertiarySystemFill)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Title + Artist
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(song.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Trend indicator
            trendBadge(song)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            let allSongs = vm.topWeekly.map { entry in
                NavidromeSong(
                    id: entry.songId, title: entry.title, artist: entry.artist,
                    artistId: entry.artistId, album: entry.album, albumId: entry.albumId,
                    coverArt: entry.coverArt, duration: 0, track: nil,
                    year: nil, genre: nil, explicitStatus: nil,
                    replayGainTrackGain: nil, replayGainTrackPeak: nil,
                    replayGainAlbumGain: nil, replayGainAlbumPeak: nil
                )
            }
            if let idx = allSongs.firstIndex(where: { $0.id == song.songId }) {
                PlayerService.shared.playPlaylist(allSongs, startingAt: idx, contextUri: "top-weekly", contextName: "Top semanal")
            }
        }
        .contextMenu {
            Button {
                let album = NavidromeAlbum(
                    id: song.albumId, name: song.album, artist: song.artist,
                    coverArt: song.coverArt, songCount: nil, duration: nil,
                    year: nil, genre: nil, explicitStatus: nil
                )
                withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                    selectedAlbum = album
                }
            } label: {
                Label("Ir al álbum", systemImage: "square.stack")
            }

            if let artistId = song.artistId {
                Button {
                    navigateToArtist(NavidromeArtist(id: artistId, name: song.artist, albumCount: nil))
                } label: {
                    Label("Ir al artista", systemImage: "person")
                }
            }
        }
    }

    @ViewBuilder
    private func trendBadge(_ song: TopWeeklySong) -> some View {
        switch song.trend {
        case "up":
            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                if let change = song.change {
                    Text("\(abs(change))")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(.green)
        case "down":
            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                if let change = song.change {
                    Text("\(abs(change))")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(.red)
        case "new":
            Text("Nuevo")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.cyan)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.cyan.opacity(0.15), in: Capsule())
        default:
            Text("—")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Jump Back In (Recent Contexts)

    @ViewBuilder
    private var jumpBackInSection: some View {
        if vm.isBackendAvailable && !vm.recentContexts.isEmpty {
            HorizontalScrollSection(title: "Volver a escuchar") {
                ForEach(vm.recentContexts) { ctx in
                    let isAlbum = ctx.type == "album"
                    let isPlaylist = ctx.type == "playlist" || ctx.type == "smartmix"

                    if isAlbum {
                        let album = NavidromeAlbum(
                            id: ctx.id, name: ctx.title, artist: ctx.artist,
                            coverArt: ctx.coverArtId, songCount: nil, duration: nil,
                            year: nil, genre: nil, explicitStatus: nil
                        )
                        Button {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                                selectedAlbum = album
                            }
                        } label: {
                            AlbumCardView(album: album, size: 150, heroNamespace: heroNS)
                        }
                        .buttonStyle(.plain)
                        .opacity(selectedAlbum?.id == ctx.id ? 0 : 1)
                    } else if isPlaylist {
                        let playlist = NavidromePlaylist(
                            id: ctx.id, name: ctx.title, comment: nil,
                            songCount: ctx.songCount ?? 0, duration: 0,
                            owner: nil, coverArt: ctx.coverArtId, changed: nil
                        )
                        Button {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                                selectedPlaylist = playlist
                            }
                        } label: {
                            PlaylistCardView(playlist: playlist, size: 150, heroNamespace: heroNS)
                        }
                        .buttonStyle(.plain)
                        .opacity(selectedPlaylist?.id == ctx.id ? 0 : 1)
                    } else if ctx.type == "artist" {
                        let artist = NavidromeArtist(id: ctx.id, name: ctx.title, albumCount: nil)
                        NavigationLink(value: artist) {
                            ArtistCardView(artist: artist, size: 150)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Recent Releases

    private let releasesVisibleLimit = 8

    @ViewBuilder
    private var recentReleasesSection: some View {
        if !vm.recentReleases.isEmpty {
            let visible = Array(vm.recentReleases.prefix(releasesVisibleLimit))
            let overflow = vm.recentReleases.count - releasesVisibleLimit

            HorizontalScrollSection(title: "Lanzamientos recientes") {
                ForEach(visible) { album in
                    Button {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                            selectedAlbum = album
                        }
                    } label: {
                        AlbumCardView(album: album, size: 150, heroNamespace: heroNS)
                    }
                    .buttonStyle(.plain)
                    .opacity(selectedAlbum?.id == album.id ? 0 : 1)
                }
                if overflow > 0 {
                    NavigationLink(value: SeeAllDestination.albums(
                        title: "Lanzamientos recientes", items: vm.recentReleases
                    )) {
                        SeeAllCard(remaining: overflow)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Daily Mixes

    @ViewBuilder
    private var dailyMixSection: some View {
        if vm.isBackendAvailable {
            if vm.isGeneratingMixes {
                // Generating state
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tus mixes diarios")
                        .font(.system(size: 22, weight: .bold))
                        .padding(.horizontal, 16)
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Generando mixes...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                }
            } else if vm.dailyMixPlaylists.isEmpty && !vm.dailyMixes.isEmpty {
                // Mixes exist but no Navidrome playlists yet
                EmptyView()
            } else if vm.dailyMixPlaylists.isEmpty {
                // No mixes at all — show generate button
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tus mixes diarios")
                        .font(.system(size: 22, weight: .bold))
                        .padding(.horizontal, 16)

                    Button {
                        Task { await vm.generateMixes() }
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                            Text("Generar mixes por primera vez")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.cyan)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.cyan.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.horizontal, 16)
                }
            } else {
                // Show mixes
                HorizontalScrollSection(title: "Tus mixes diarios") {
                    ForEach(vm.dailyMixPlaylists) { playlist in
                        Button {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                                selectedPlaylist = playlist
                            }
                        } label: {
                            PlaylistCardView(playlist: playlist, size: 150, heroNamespace: heroNS)
                        }
                        .buttonStyle(.plain)
                        .opacity(selectedPlaylist?.id == playlist.id ? 0 : 1)
                    }
                }
            }
        }
    }

    // MARK: - Latest Albums

    private let latestVisibleLimit = 8

    @ViewBuilder
    private var latestAlbumsSection: some View {
        if !vm.latestAlbums.isEmpty {
            let visible = Array(vm.latestAlbums.prefix(latestVisibleLimit))
            let overflow = vm.latestAlbums.count - latestVisibleLimit

            HorizontalScrollSection(title: "Últimos álbumes añadidos") {
                ForEach(visible) { album in
                    Button {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                            selectedAlbum = album
                        }
                    } label: {
                        AlbumCardView(album: album, size: 150, heroNamespace: heroNS)
                    }
                    .buttonStyle(.plain)
                    .opacity(selectedAlbum?.id == album.id ? 0 : 1)
                }
                if overflow > 0 {
                    NavigationLink(value: SeeAllDestination.albums(
                        title: "Últimos álbumes añadidos", items: vm.latestAlbums
                    )) {
                        SeeAllCard(remaining: overflow)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Loading skeleton

    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 180, height: 22)
                        .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(0..<5, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 6) {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(.tertiarySystemFill))
                                        .frame(width: 150, height: 150)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color(.tertiarySystemFill))
                                        .frame(width: 120, height: 14)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color(.tertiarySystemFill))
                                        .frame(width: 80, height: 12)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    // MARK: - Offline Content

    @ViewBuilder
    private var offlineContentSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Descargado")
                .font(.system(size: 22, weight: .bold))
                .padding(.horizontal, 16)

            if offlineAlbums.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Sin conexión")
                        .font(.headline)
                    Text("Descarga álbumes y playlists para escuchar sin conexión.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(offlineAlbums, id: \.albumId) { album in
                        Button {
                            selectedAlbum = NavidromeAlbum(
                                id: album.albumId, name: album.name, artist: album.artist,
                                coverArt: album.coverArt, songCount: album.songCount,
                                duration: nil, year: album.year, genre: nil, explicitStatus: nil
                            )
                        } label: {
                            HStack(spacing: 12) {
                                AlbumCoverThumbnail(coverArt: album.coverArt, size: 50)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .lineLimit(1)
                                    Text("\(album.artist) · \(album.songCount) canciones")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.system(size: 14))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task {
            offlineAlbums = await OfflineContentProvider.shared.cachedAlbums()
        }
    }
}

// MARK: - Album Cover Thumbnail (small, for offline list)

private struct AlbumCoverThumbnail: View {
    let coverArt: String?
    let size: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.tertiarySystemFill)
                    .overlay(
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task {
            guard let coverArt, !coverArt.isEmpty,
                  let url = NavidromeService.shared.coverURL(id: coverArt, size: Int(size * 2)),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else { return }
            image = img
        }
    }
}

