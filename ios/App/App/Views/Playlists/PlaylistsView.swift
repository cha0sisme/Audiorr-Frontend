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
            .task { await vm.loadIfNeeded() }
            .refreshable { await vm.load() }
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
            if vm.isConfigured {
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                }
            }
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
            ContentUnavailableView(
                "Sin playlists",
                systemImage: "music.note.list",
                description: Text("Crea una playlist en Navidrome para verla aquí.")
            )
            .padding(.top, 40)
        } else if vm.isBackendAvailable {
            sectionsContent
        } else {
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
