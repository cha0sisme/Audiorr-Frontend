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
    @Published var isBackendAvailable = false
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

    func load() async {
        isLoading = true
        defer {
            isLoading = false
            lastLoadedAt = Date()
        }

        api.reloadCredentials()
        guard api.isConfigured else { return }

        playlists = (try? await api.getPlaylists()) ?? []

        isBackendAvailable = await api.checkBackendAvailable()

        if isBackendAvailable {
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

    var dailyMixes: [NavidromePlaylist] {
        playlists.filter { $0.name.lowercased().hasPrefix("mix diario") }
    }

    var smartPlaylists: [NavidromePlaylist] {
        playlists.filter { $0.comment?.contains("Smart Playlist") == true }
    }

    var userPlaylists: [NavidromePlaylist] {
        playlists.filter { pl in
            !pl.name.lowercased().hasPrefix("mix diario")
            && pl.comment?.contains("Smart Playlist") != true
            && pl.comment?.contains("[Editorial]")    != true
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
    @State private var scrollY: CGFloat = 0
    @Namespace private var heroNS
    @State private var selectedPlaylist: NavidromePlaylist?
    @State private var cachedSongCount = 0

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
                    content
                }
            }
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                scrollY = y
            }
            .modifier(PlaylistHeroOverlay(selectedPlaylist: $selectedPlaylist, namespace: heroNS, onDeleted: {
                Task { await vm.load() }
            }))
            .background(Color(.systemBackground))
            .toolbarBackground(selectedPlaylist != nil ? .hidden : (stickyOpacity > 0.5 ? .visible : .hidden), for: .navigationBar)
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
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .toolbar {
                if selectedPlaylist == nil {
                    ToolbarItem(placement: .principal) {
                        Text("Playlists")
                            .font(.headline)
                            .lineLimit(1)
                            .opacity(stickyOpacity)
                    }
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
            }
            .alert("Nueva playlist", isPresented: $showCreateSheet) {
                TextField("Nombre", text: $newPlaylistName)
                Button("Crear") {
                    let name = newPlaylistName
                    newPlaylistName = ""
                    Task {
                        if let playlist = await vm.createPlaylist(name: name) {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                                selectedPlaylist = playlist
                            }
                        }
                    }
                }
                Button("Cancelar", role: .cancel) { newPlaylistName = "" }
            } message: {
                Text("Introduce el nombre de la nueva playlist.")
            }
        }
    }

    // MARK: - Large title header

    private var largeHeader: some View {
        HStack(alignment: .bottom) {
            Text("Playlists")
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

    @ViewBuilder
    private var content: some View {
        if vm.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
        } else if !vm.isConfigured {
            notConfiguredView
        } else if vm.playlists.isEmpty {
            downloadsCard
            if !NetworkMonitor.shared.isConnected {
                ContentUnavailableView(
                    "Sin conexión",
                    systemImage: "wifi.slash",
                    description: Text("Conecta a internet para ver tus playlists. Las canciones descargadas siguen disponibles.")
                )
                .padding(.top, 40)
            } else {
                ContentUnavailableView(
                    "Sin playlists",
                    systemImage: "music.note.list",
                    description: Text("Crea una playlist en Navidrome para verla aquí.")
                )
                .padding(.top, 40)
            }
        } else if vm.isBackendAvailable {
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
                Text("Sin servidor configurado")
                    .font(.title3.bold())
                Text("Conecta tu servidor de Navidrome para ver tus playlists.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Conectar a Navidrome") {
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
                        Text("Descargas")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("\(cachedSongCount) canciones")
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
                            Button {
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                                    selectedPlaylist = playlist
                                }
                            } label: {
                                PlaylistCardView(playlist: playlist, size: 140, heroNamespace: heroNS)
                            }
                            .buttonStyle(.plain)
                            .opacity(selectedPlaylist?.id == playlist.id ? 0 : 1)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 100)
    }

    // MARK: - Sin backend: grid 2 columnas

    private let gridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    private var gridContent: some View {
        LazyVGrid(columns: gridColumns, spacing: 20) {
            ForEach(vm.playlists) { playlist in
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                        selectedPlaylist = playlist
                    }
                } label: {
                    PlaylistCardView(playlist: playlist, axis: .grid, heroNamespace: heroNS)
                }
                .buttonStyle(.plain)
                .opacity(selectedPlaylist?.id == playlist.id ? 0 : 1)
            }
        }
        .padding(16)
        .padding(.bottom, 100)
    }
}

// MARK: - Downloads virtual playlist

/// Virtual "Downloads" playlist — shows all cached songs as a playlist-like view.
/// Not backed by Navidrome — reads from OfflineContentProvider (SwiftData).
struct DownloadsPlaylistView: View {
    @State private var songs: [NavidromeSong] = []
    @State private var isLoading = true
    @State private var palette: AlbumPalette = AlbumPalette(
        primary:   UIColor(red: 0.15, green: 0.2, blue: 0.45, alpha: 1),
        secondary: UIColor(red: 0.1, green: 0.15, blue: 0.35, alpha: 1),
        accent:    UIColor(red: 0.4, green: 0.5, blue: 0.9, alpha: 1),
        isSolid:   false
    )
    @State private var scrollY: CGFloat = 0

    private let heroHeight: CGFloat = 340

    private var scrollProgress: CGFloat { min(max(scrollY / heroHeight, 0), 1) }
    private var heroOpacity: CGFloat    { 1 - min(scrollProgress * 1.2, 0.92) }
    private var stickyOpacity: CGFloat  { min(max((scrollProgress - 0.55) / 0.25, 0), 1) }

    var body: some View {
        ZStack(alignment: .top) {
            Color(palette.pageBackgroundColor).ignoresSafeArea()

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
                Text("Descargas")
                    .font(.headline)
                    .foregroundStyle(.white)
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

    private var heroSection: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 80)

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.6), .purple.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 180, height: 180)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }

            VStack(spacing: 6) {
                Text("Descargas")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)

                Text("\(songs.count) canciones")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }

            if !songs.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        PlayerService.shared.playPlaylist(songs, startingAt: 0,
                            contextUri: "downloads:all", contextName: "Descargas")
                    } label: {
                        Label("Reproducir", systemImage: "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(.white)
                    }

                    Button {
                        let shuffled = songs.shuffled()
                        PlayerService.shared.playPlaylist(shuffled, startingAt: 0,
                            contextUri: "downloads:all", contextName: "Descargas")
                    } label: {
                        Label("Aleatorio", systemImage: "shuffle")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 32)
            }

            Spacer(minLength: 16)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .opacity(heroOpacity)
    }

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
                Text("No hay canciones descargadas")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                Text("Las canciones que reproduzcas se guardarán automáticamente.")
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
                contextName: "Descargas"
            )
        }
    }
}
