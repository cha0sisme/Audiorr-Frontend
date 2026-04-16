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
    @Published var playlists: [NavidromePlaylist] = []
    @Published var sections:  [PlaylistSection]   = []
    @Published var isLoading  = true

    private let api = NavidromeService.shared

    var isConfigured: Bool { api.isConfigured }
    var hasBackend:   Bool { api.backendURL() != nil }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        api.reloadCredentials()
        guard api.isConfigured else { return }

        playlists = (try? await api.getPlaylists()) ?? []

        if api.backendURL() != nil {
            let fetched = await api.getHomepageLayout()
            sections = fetched.isEmpty ? defaultSections : fetched
        } else {
            sections = defaultSections
        }
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
    @StateObject private var vm = PlaylistsViewModel()
    @State private var showLogin = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Playlists")
                .background(Color(.systemGroupedBackground))
                .task { await vm.load() }
                .refreshable { await vm.load() }
                .navigationDestination(for: NavidromePlaylist.self) { playlist in
                    PlaylistDetailView(playlist: playlist)
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showLogin = true
                        } label: {
                            Image(systemName: "server.rack")
                        }
                    }
                }
                .sheet(isPresented: $showLogin) {
                    LoginView {
                        Task { await vm.load() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !vm.isConfigured {
            notConfiguredView
        } else {
            ScrollView {
                if vm.playlists.isEmpty {
                    ContentUnavailableView(
                        "Sin playlists",
                        systemImage: "music.note.list",
                        description: Text("Crea una playlist en Navidrome para verla aquí.")
                    )
                    .padding(.top, 40)
                } else if vm.hasBackend {
                    sectionsContent
                } else {
                    gridContent
                }
            }
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
                showLogin = true
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
                    HorizontalPlaylistSection(title: section.title, playlists: items)
                }
            }
        }
        .padding(.vertical, 8)
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
                NavigationLink(value: playlist) {
                    PlaylistGridCell(playlist: playlist)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .padding(.bottom, 100)
    }
}

// MARK: - Horizontal section

private struct HorizontalPlaylistSection: View {
    let title: String
    let playlists: [NavidromePlaylist]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: playlist) {
                            PlaylistHorizontalCell(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Horizontal cell

private struct PlaylistHorizontalCell: View {
    let playlist: NavidromePlaylist
    private let w: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PlaylistCoverView(playlist: playlist, size: w)

            Text(playlist.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: w, alignment: .leading)

            Text("\(playlist.songCount) canciones")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: w, alignment: .leading)
        }
    }
}

// MARK: - Grid cell

private struct PlaylistGridCell: View {
    let playlist: NavidromePlaylist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlaylistCoverView(playlist: playlist, size: .infinity)
                .aspectRatio(1, contentMode: .fit)

            Text(playlist.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text("\(playlist.songCount) canciones")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
