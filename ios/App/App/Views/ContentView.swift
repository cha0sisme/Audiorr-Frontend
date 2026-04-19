import SwiftUI

/// Root view de la app. Usa TabView con APIs de iOS 26:
/// - Tab items con Liquid Glass
/// - .tabViewBottomAccessory para el mini player (merge al scroll como Apple Music)
/// - .tabBarMinimizeBehavior(.onScrollDown) para el efecto de scroll
/// - Tab(role: .search) para el pill de búsqueda separado
struct ContentView: View {
    private var nowPlaying = NowPlayingState.shared
    @ObservedObject private var theme = AppTheme.shared
    private var network = NetworkMonitor.shared

    // Navigation from viewer context menu
    @State private var navigationAlbum: NavidromeAlbum?
    @State private var navigationArtist: NavidromeArtist?

    var body: some View {
        ZStack(alignment: .top) {
            TabView {
                Tab("Inicio", systemImage: "house.fill") {
                    HomeView()
                }

                Tab("Artistas", systemImage: "person.2.fill") {
                    ArtistsView()
                }

                Tab("Playlists", systemImage: "music.note.list") {
                    PlaylistsView()
                }

                Tab("Audiorr", image: "AudiorrTabIcon") {
                    NavigationStack {
                        SettingsView()
                    }
                }

                Tab("Buscar", systemImage: "magnifyingglass", role: .search) {
                    searchView
                }
            }
            .tabViewBottomAccessory {
                MiniPlayerView()
            }
            .tabBarMinimizeBehavior(.onScrollDown)

            // Now Playing Viewer — overlay (no .fullScreenCover, control total de la transición)
            if nowPlaying.viewerIsOpen {
                NowPlayingViewerView()
                    .transition(.move(edge: .bottom))
                    .zIndex(10)
            }

            // Navigation from viewer context menu — full-screen overlay (not sheet)
            if let album = navigationAlbum {
                NavigationStack {
                    AlbumDetailView(album: album, onDismiss: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                            navigationAlbum = nil
                        }
                    })
                }
                .transition(.move(edge: .trailing))
                .zIndex(5)
            }

            if let artist = navigationArtist {
                NavigationStack {
                    ArtistDetailView(artist: artist, onDismiss: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                            navigationArtist = nil
                        }
                    })
                }
                .transition(.move(edge: .trailing))
                .zIndex(5)
            }
            // Offline banner
            if !network.isConnected {
                offlineBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task { BackendState.shared.check() }
        .preferredColorScheme(theme.colorScheme)
        .animation(.easeInOut(duration: 0.3), value: network.isConnected)
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: nowPlaying.viewerIsOpen)
        .animation(.spring(response: 0.35, dampingFraction: 0.88), value: navigationAlbum != nil)
        .animation(.spring(response: 0.35, dampingFraction: 0.88), value: navigationArtist != nil)
        .onChange(of: nowPlaying.viewerIsOpen) { _, isOpen in
            if !isOpen, let nav = nowPlaying.pendingNavigation {
                nowPlaying.pendingNavigation = nil
                handleNavigation(nav)
            }
        }
    }

    private func handleNavigation(_ nav: NowPlayingState.NavigationRequest) {
        Task {
            // Small delay to let the viewer dismiss animation complete
            try? await Task.sleep(for: .milliseconds(350))
            switch nav {
            case .album(let id):
                if let (album, _, _) = try? await NavidromeService.shared.getAlbumDetail(albumId: id), let album {
                    navigationAlbum = album
                }
            case .artist(let id, let name):
                navigationArtist = NavidromeArtist(id: id, name: name, albumCount: nil)
            }
        }
    }

    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 12, weight: .semibold))
            Text("Sin conexión — contenido descargado disponible")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial.opacity(0.9))
        .background(Color.orange.opacity(0.85))
    }

    private var searchView: some View {
        var view = SearchView()
        view.onPlaySong = { song in
            Task { @MainActor in PlayerService.shared.play(song: song) }
        }
        return view
    }
}
