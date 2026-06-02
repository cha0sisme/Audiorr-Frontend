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
    @Namespace private var overlayHeroNS

    var body: some View {
        ZStack(alignment: .top) {
            TabView {
                Tab(L.home, systemImage: "house.fill") {
                    HomeView()
                }

                Tab(L.artists, systemImage: "person.2.fill") {
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

                Tab(L.search, systemImage: "magnifyingglass", role: .search) {
                    searchView
                }
            }
            .tabViewBottomAccessory {
                MiniPlayerView()
            }
            .tabBarMinimizeBehavior(.onScrollDown)

            // Now Playing Viewer — overlay con transición de scale+opacity
            // anclada a la posición del cover del miniplayer. El viewer
            // "explota" desde el cover del mini al abrir y colapsa de vuelta
            // al cerrar — sensación zoom estilo Apple Music sin las
            // complicaciones de `matchedGeometryEffect` cruzando jerarquías
            // de SwiftUI (TabView accessory ↔ overlay).
            //
            // `anchor: (0.12, 0.95)` aproxima la posición visual del artwork
            // del miniplayer (esquina inferior izquierda del tabbar).
            // `scale: 0.10` da una expansión visible pero sin distorsión.
            // Asymmetric: entrada con bounce sutil, salida más rápida.
            if nowPlaying.viewerIsOpen {
                // Transiciones NATIVAS de SwiftUI: `move(edge: .bottom)` +
                // `opacity`. La animación la conduce una ÚNICA transacción de
                // contenedor (`.animation(value: viewerIsOpen)` más abajo), NO
                // una animación adosada a la transición. Adosarla hacía la
                // transición frágil ante interrupciones: abrir/cerrar rápido
                // varias veces interrumpía la salida con la entrada y el viewer
                // quedaba "a medio abrir". Con una sola transacción de
                // contenedor, SwiftUI resuelve la interrupción de forma
                // determinista y cubre por igual todos los orígenes del toggle
                // (miniplayer, drag, menú contextual, Dynamic Island…).
                NowPlayingViewerView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
                    ArtistDetailView(artist: artist, heroNamespace: overlayHeroNS, onDismiss: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                            navigationArtist = nil
                        }
                    })
                    .navigationDestination(for: NavidromeAlbum.self) {
                        AlbumDetailView(album: $0)
                            .navigationTransition(.zoom(sourceID: $0.id, in: overlayHeroNS))
                    }
                    .navigationDestination(for: NavidromePlaylist.self) {
                        PlaylistDetailView(playlist: $0)
                            .navigationTransition(.zoom(sourceID: $0.id, in: overlayHeroNS))
                    }
                    .navigationDestination(for: NavidromeArtist.self) {
                        ArtistDetailView(artist: $0, heroNamespace: overlayHeroNS)
                            .navigationTransition(.zoom(sourceID: $0.id, in: overlayHeroNS))
                    }
                    .navigationDestination(for: SeeAllDestination.self) { SeeAllGridView(destination: $0) }
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
        // Única fuente de animación del viewer: la transición ya NO lleva
        // animación adosada (ver arriba), así que esta transacción de
        // contenedor es la que conduce entrada y salida. No hay "dos fases"
        // porque solo existe esta.
        .animation(.spring(duration: 0.45, bounce: 0), value: nowPlaying.viewerIsOpen)
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
            Text(L.offlineDownloadsAvailable)
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

// MARK: - Viewer expand transition

/// Modifier animable para la transición de entrada/salida del
/// NowPlayingViewer. Imita la sensación de "sheet from bottom" que usa
/// Apple Music iOS 26: slide vertical sutil + scale mínimo + fade,
/// todo animado como UN ÚNICO movimiento continuo.
///
/// Decisiones clave:
///  - `scale` solo entre 0.94 y 1.0 (muy sutil). Un scale dramático
///    crea "dos fases" perceptuales: un pop inicial + el final del
///    movimiento.
///  - `offset` slide-up suave de 80pt → 0. Más impactante visualmente
///    que el scale, da la sensación de "subir desde el miniplayer".
///  - `opacity` 0 → 1 ligero para fade-in.
///  - Sin `clipShape`: rompe `ignoresSafeArea` y bloquea el fullscreen.
private struct ViewerExpandTransition: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let scale = 0.94 + 0.06 * progress
        let offsetY = (1 - progress) * 80
        let opacity = progress
        return content
            .scaleEffect(scale, anchor: .center)
            .offset(y: offsetY)
            .opacity(opacity)
    }
}
