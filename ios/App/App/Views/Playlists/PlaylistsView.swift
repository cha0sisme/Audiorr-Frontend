import SwiftUI

// MARK: - Default layout (mirrors React DEFAULT_LAYOUT)

private let defaultSections: [PlaylistSection] = [
    PlaylistSection(id: "daily-mixes",     title: "Tus mixes diarios",           type: .fixedDaily,  playlists: nil),
    PlaylistSection(id: "smart-playlists", title: "Hecho especialmente para ti", type: .fixedSmart,  playlists: nil),
    PlaylistSection(id: "my-playlists",    title: "Mis playlists",               type: .fixedUser,   playlists: nil),
]

// MARK: - View Model

@MainActor
final class PlaylistsViewModel: ObservableObject {
    static let shared = PlaylistsViewModel()

    @Published var playlists: [NavidromePlaylist] = []
    @Published var sections:  [PlaylistSection]   = []
    @Published var isLoading  = true
    @Published var isCreating = false

    private let api = NavidromeService.shared
    private var lastLoadedAt: Date?
    private let cacheTTL: TimeInterval = 120

    var isConfigured: Bool { api.isConfigured }

    func loadIfNeeded() async {
        if let last = lastLoadedAt, Date().timeIntervalSince(last) < cacheTTL, !playlists.isEmpty {
            return
        }
        await load()
    }

    private var hasData: Bool { !playlists.isEmpty }

    func load() async {
        // Only show skeleton on first load — subsequent refreshes keep existing data visible
        if !hasData { isLoading = true }

        api.reloadCredentials()
        guard api.isConfigured else {
            isLoading = false
            lastLoadedAt = Date()
            return
        }

        // Fetch playlists from Navidrome
        playlists = (try? await api.getPlaylists()) ?? []

        // Playlists ready — show them immediately
        isLoading = false
        lastLoadedAt = Date()

        // Load backend-dependent sections (BackendState already checked centrally)
        if BackendState.shared.isAvailable {
            let fetched = await api.getHomepageLayout()
            sections = fetched.isEmpty ? defaultSections : fetched
        } else {
            sections = []
        }
    }

    func createPlaylist(name: String) async -> NavidromePlaylist? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        isCreating = true
        defer { isCreating = false }

        guard let id = try? await api.createPlaylist(name: trimmed) else { return nil }
        // Reload playlists to get the new one
        playlists = (try? await api.getPlaylists()) ?? playlists
        return playlists.first { $0.id == id }
    }

    // MARK: Filtered lists per section type

    private var currentUsername: String? {
        api.credentials?.username.lowercased()
    }

    var dailyMixes: [NavidromePlaylist] {
        let user = currentUsername
        return playlists.filter {
            $0.name.lowercased().hasPrefix("mix diario")
            && (user == nil || $0.owner?.lowercased() == user)
        }
    }

    var smartPlaylists: [NavidromePlaylist] {
        playlists.filter { $0.comment?.contains("Smart Playlist") == true }
    }

    var userPlaylists: [NavidromePlaylist] {
        let user = currentUsername
        return playlists.filter { pl in
            !pl.name.lowercased().hasPrefix("mix diario")
            && pl.comment?.contains("Smart Playlist") != true
            && pl.comment?.contains("[Editorial]")    != true
            && (user == nil || pl.owner?.lowercased() == user)
        }
    }

    func playlistsForSection(_ section: PlaylistSection) -> [NavidromePlaylist] {
        switch section.type {
        case .fixedDaily:  return dailyMixes
        case .fixedSmart:  return smartPlaylists
        case .fixedUser:   return userPlaylists
        case .dynamic:
            let ids = Set(section.playlists ?? [])
            return playlists.filter { ids.contains($0.id) }
        }
    }
}

// MARK: - PlaylistsView

struct PlaylistsView: View {
    @ObservedObject private var vm = PlaylistsViewModel.shared
    @State private var showSettings = false
    @State private var showCreateSheet = false
    @State private var newPlaylistName = ""
    @Namespace private var heroNS
    @State private var cachedSongCount = 0
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                content
            }
            .background(Color(.systemBackground))
            .navigationTitle(L.playlists)
            .navigationBarTitleDisplayMode(.large)
            .task {
                await vm.loadIfNeeded()
                cachedSongCount = await OfflineContentProvider.shared.allCachedSongs().count
            }
            .refreshable {
                await vm.load()
                cachedSongCount = await OfflineContentProvider.shared.allCachedSongs().count
            }
            .navigationDestination(for: NavidromePlaylist.self) {
                PlaylistDetailView(playlist: $0, onDeleted: {
                    Task { await vm.load() }
                })
                .navigationTransition(.zoom(sourceID: $0.id, in: heroNS))
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .toolbar {
                if vm.isConfigured {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showCreateSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                        }
                    }
                }
            }
            .alert(L.newPlaylist, isPresented: $showCreateSheet) {
                TextField(L.name, text: $newPlaylistName)
                Button(L.createPlaylist) {
                    let name = newPlaylistName
                    newPlaylistName = ""
                    Task {
                        if let playlist = await vm.createPlaylist(name: name) {
                            navigationPath.append(playlist)
                        }
                    }
                }
                Button(L.cancel, role: .cancel) { newPlaylistName = "" }
            } message: {
                Text(L.newPlaylistPrompt)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading {
            playlistSkeleton
        } else if !vm.isConfigured {
            notConfiguredView
        } else if vm.playlists.isEmpty {
            downloadsCard
            if !NetworkMonitor.shared.isConnected {
                ContentUnavailableView(
                    L.noConnection,
                    systemImage: "wifi.slash",
                    description: Text(L.connectOfflinePlaylists)
                )
                .padding(.top, 40)
            } else {
                ContentUnavailableView(
                    L.noPlaylists,
                    systemImage: "music.note.list",
                    description: Text(L.createPlaylistHint)
                )
                .padding(.top, 40)
            }
        } else if BackendState.shared.isAvailable {
            downloadsCard
            sectionsContent
        } else {
            downloadsCard
            gridContent
        }
    }

    // MARK: - Not configured state

    private var notConfiguredView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "music.note.house")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text(L.noServerConfigured)
                    .font(.title3.bold())
                Text(L.connectNavidromePlaylists)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(L.connectToNavidrome) {
                showSettings = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Virtual "Downloads" playlist card

    @ViewBuilder
    private var downloadsCard: some View {
        if cachedSongCount > 0 {
            NavigationLink(destination: DownloadsPlaylistView()) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.blue.opacity(0.7), .purple.opacity(0.7)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L.downloads)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(L.songCount(cachedSongCount))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Con backend: secciones horizontales

    private var sectionsContent: some View {
        VStack(alignment: .leading, spacing: 32) {
            ForEach(vm.sections) { section in
                let items = vm.playlistsForSection(section)
                if !items.isEmpty {
                    HorizontalScrollSection(title: section.title) {
                        ForEach(items) { playlist in
                            NavigationLink(value: playlist) {
                                PlaylistCardView(playlist: playlist, size: 140, heroNamespace: heroNS)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 100)
    }

    // MARK: - Loading skeleton

    private var playlistSkeleton: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Grid skeleton: 2 columns of playlist cards
            let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(0..<6, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                            .aspectRatio(1, contentMode: .fit)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.tertiarySystemFill))
                            .frame(height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.tertiarySystemFill))
                            .frame(width: 80, height: 12)
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Sin backend: grid 2 columnas

    private let gridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    private var gridContent: some View {
        LazyVGrid(columns: gridColumns, spacing: 20) {
            ForEach(vm.playlists) { playlist in
                NavigationLink(value: playlist) {
                    PlaylistCardView(playlist: playlist, axis: .grid, heroNamespace: heroNS)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .padding(.bottom, 100)
    }
}

// MARK: - Downloads virtual playlist

/// Virtual "Downloads" playlist — shows all cached songs as a playlist-like view.
/// Not backed by Navidrome — reads from OfflineContentProvider (SwiftData).
/// Layout mirrors PlaylistDetailView for consistency.
struct DownloadsPlaylistView: View {
    @State private var songs: [NavidromeSong] = []
    @State private var isLoading = true
    @State private var scrollY: CGFloat = 0

    private let palette = AlbumPalette(
        primary:   UIColor(red: 0.12, green: 0.15, blue: 0.35, alpha: 1),
        secondary: UIColor(red: 0.08, green: 0.1, blue: 0.28, alpha: 1),
        accent:    UIColor(red: 0.45, green: 0.55, blue: 1.0, alpha: 1),
        isSolid:   false
    )

    private let heroHeight: CGFloat = 440

    private var scrollProgress: CGFloat { min(max(scrollY / heroHeight, 0), 1) }
    private var heroOpacity: CGFloat    { 1 - min(scrollProgress * 1.2, 0.92) }
    private var stickyOpacity: CGFloat  { min(max((scrollProgress - 0.55) / 0.25, 0), 1) }
    private var overscrollScale: CGFloat { 1 + max(0, -scrollY) / 900 }

    private var pageBg: Color { Color(palette.pageBackgroundColor) }

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
        .toolbarColorScheme(.dark, for: .navigationBar)
        .environment(\.colorScheme, .dark)
        .tint(.white)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(L.downloads)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .opacity(stickyOpacity)
            }
        }
        .task { await loadSongs() }
    }

    private func loadSongs() async {
        isLoading = true
        let cached = await OfflineContentProvider.shared.allCachedSongs()
        songs = cached.map { $0.toNavidromeSong() }
        isLoading = false
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            // Background
            ZStack {
                LinearGradient(
                    colors: [.blue.opacity(0.6), .purple.opacity(0.6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
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

            // Content
            VStack(spacing: 0) {
                Spacer(minLength: 100)

                // Cover icon
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.blue.opacity(0.5), .purple.opacity(0.5)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 64, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(width: 190, height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.55), radius: 22, x: 0, y: 8)

                Spacer(minLength: 20)

                // Title + metadata
                VStack(alignment: .center, spacing: 5) {
                    Text(L.downloads)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)

                    Text(L.songCount(songs.count))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20)

                // Action buttons
                if !songs.isEmpty {
                    actionButtons
                        .padding(.top, 18)
                }

                Spacer(minLength: 28)
            }
            .frame(maxWidth: .infinity)
            .opacity(heroOpacity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
        .clipped()
    }

    private var actionButtons: some View {
        let fillColor = Color(palette.buttonFillColor)
        let labelColor: Color = palette.buttonUsesBlackText ? .black : .white

        return HStack(spacing: 12) {
            Button {
                PlayerService.shared.playPlaylist(songs, startingAt: 0,
                    contextUri: "downloads:all", contextName: L.downloads)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(labelColor)
                    .frame(width: 40, height: 40)
                    .background(fillColor, in: Circle())
            }

            Button {
                PlayerService.shared.playPlaylist(songs.shuffled(), startingAt: 0,
                    contextUri: "downloads:all", contextName: L.downloads)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(labelColor)
                    .frame(width: 40, height: 40)
                    .background(fillColor, in: Circle())
            }
        }
    }

    // MARK: - Song List

    @ViewBuilder
    private var songListSection: some View {
        if isLoading {
            ProgressView()
                .tint(.white)
                .padding(.top, 40)
        } else if songs.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.3))
                Text(L.noDownloadedSongs)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                Text(L.songsAutoSaved)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)
            .padding(.horizontal, 32)
        } else {
            SongListView(
                songs: songs,
                palette: palette,
                contextUri: "downloads:all",
                contextName: L.downloads
            )
        }
    }
}
