import SwiftUI

// MARK: - View Model

@MainActor
final class HomeViewModel: ObservableObject {
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

    func load() async {
        isLoading = true
        defer { isLoading = false }

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
        recentContexts = Array(await api.getRecentContexts().prefix(6))
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
    @StateObject private var vm = HomeViewModel()
    @ObservedObject private var theme = AppTheme.shared
    @State private var scrollY: CGFloat = 0
    @Namespace private var heroNS
    @State private var selectedAlbum: NavidromeAlbum?

    private let collapseThreshold: CGFloat = 44

    private var stickyOpacity: CGFloat {
        min(max((scrollY - collapseThreshold * 0.4) / (collapseThreshold * 0.6), 0), 1)
    }
    private var largeTitleOpacity: CGFloat {
        1 - min(max(scrollY / collapseThreshold, 0), 1)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    largeHeader

                    VStack(alignment: .leading, spacing: 24) {
                        if vm.isLoading {
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
            .background(Color(.systemBackground))
            .toolbarBackground(selectedAlbum != nil ? .hidden : (stickyOpacity > 0.5 ? .visible : .hidden), for: .navigationBar)
            .toolbar {
                if selectedAlbum == nil {
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
            .task { await vm.load() }
            .refreshable { await vm.load() }
            .preferredColorScheme(theme.colorScheme)
        }
    }

    // MARK: - Large header

    private var largeHeader: some View {
        HStack(alignment: .bottom) {
            Text("Inicio")
                .font(.system(size: 34, weight: .bold))
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
                Text("Lo mas escuchado")
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
        Button {
            let allSongs = vm.topWeekly.map { entry in
                NavidromeSong(
                    id: entry.songId, title: entry.title, artist: entry.artist,
                    artistId: nil, album: entry.album, albumId: entry.albumId,
                    coverArt: entry.coverArt, duration: 0, track: nil,
                    year: nil, genre: nil, explicitStatus: nil
                )
            }
            if let idx = allSongs.firstIndex(where: { $0.id == song.songId }) {
                PlayerService.shared.playPlaylist(allSongs, startingAt: idx)
            }
        } label: {
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
        }
        .buttonStyle(.plain)
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
            .foregroundStyle(.cyan)
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
            Text("NEW")
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
                    RecentContextCard(context: ctx)
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
                        NavigationLink(value: playlist) {
                            PlaylistCardView(playlist: playlist, size: 150)
                        }
                        .buttonStyle(.plain)
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

            HorizontalScrollSection(title: "Ultimos albumes anadidos") {
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
                        title: "Ultimos albumes anadidos", items: vm.latestAlbums
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
}

// MARK: - Recent context card (Jump Back In)

private struct RecentContextCard: View {
    let context: RecentContext
    @State private var artistImage: URL?

    private var isArtist: Bool { context.type == "artist" }
    private var isPlaylist: Bool { context.type == "playlist" || context.type == "smartmix" }

    var body: some View {
        NavigationLink(value: navigationValue) {
            VStack(alignment: .leading, spacing: 6) {
                coverImage
                    .frame(width: 150, height: 150)
                    .clipShape(isArtist
                        ? AnyShape(Circle())
                        : AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)

                Text(context.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(width: 150, alignment: .leading)

                if !isArtist {
                    Text(isPlaylist
                        ? "\(context.songCount) canciones"
                        : context.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .task {
            if isArtist {
                artistImage = await NavidromeService.shared.artistImageURL(name: context.id)
            }
        }
    }

    // MARK: - Cover

    @ViewBuilder
    private var coverImage: some View {
        if isPlaylist {
            // Backend cover first, then Navidrome fallback
            PlaylistCoverForContext(context: context)
        } else if isArtist {
            if let artistImage {
                AsyncImage(url: artistImage) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: artistPlaceholder
                    }
                }
            } else {
                artistPlaceholder
            }
        } else if let coverArtId = context.coverArtId {
            // Album
            AsyncImage(url: NavidromeService.shared.coverURL(id: coverArtId, size: 300)) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: albumPlaceholder
                }
            }
        } else {
            albumPlaceholder
        }
    }

    private var artistPlaceholder: some View {
        ZStack {
            let hash = context.title.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 360 }
            Color(hue: Double(hash) / 360.0, saturation: 0.45, brightness: 0.50)
            Image(systemName: "person.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var albumPlaceholder: some View {
        ZStack {
            Color(.tertiarySystemFill)
            Image(systemName: "music.note")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Navigation

    private var navigationValue: AnyHashable {
        switch context.type {
        case "album":
            return NavidromeAlbum(
                id: context.id, name: context.title, artist: context.artist,
                coverArt: context.coverArtId, songCount: nil, duration: nil,
                year: nil, genre: nil, explicitStatus: nil
            )
        case "playlist", "smartmix":
            return NavidromePlaylist(
                id: context.id, name: context.title, comment: nil,
                songCount: context.songCount, duration: 0,
                owner: nil, coverArt: context.coverArtId, changed: nil
            )
        case "artist":
            return NavidromeArtist(
                id: context.id, name: context.title, albumCount: nil
            )
        default:
            return context.id
        }
    }
}

// MARK: - Playlist cover with backend-first fallback (for RecentContext)

private struct PlaylistCoverForContext: View {
    let context: RecentContext
    @State private var useBackend = true

    private var backendURL: URL? {
        NavidromeService.shared.playlistBackendCoverURL(playlistId: context.id)
    }
    private var navidromeURL: URL? {
        NavidromeService.shared.coverURL(id: context.coverArtId, size: 300)
    }
    private var activeURL: URL? {
        useBackend ? (backendURL ?? navidromeURL) : navidromeURL
    }

    var body: some View {
        AsyncImage(url: activeURL) { phase in
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
    }

    private var placeholder: some View {
        ZStack {
            Color(.tertiarySystemFill)
            Image(systemName: "music.note.list")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
        }
    }
}
