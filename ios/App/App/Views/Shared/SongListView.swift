import SwiftUI
import UIKit

// MARK: - NavigationPath environment

/// Binding al `NavigationPath` del NavigationStack contenedor, expuesto vía
/// Environment.
///
/// Permite que vistas reutilizables y profundas (p.ej. `SongListView`) hagan
/// push a través del ÚNICO conjunto de `navigationDestination(for:)` declarado
/// en la RAÍZ del stack, en vez de declarar sus propios destinos. Declarar
/// destinos dentro de vistas reutilizables que se apilan varias veces en el
/// mismo stack provoca destinos duplicados ("solo se usa el más cercano a la
/// raíz") y rompe la navegación al encadenar pantallas (Album → Artista →
/// Album → …). Si la vista se usa fuera de un stack que inyecte el path, el
/// valor es `nil` y el push se ignora (no crashea).
private struct NavPathKey: EnvironmentKey {
    static let defaultValue: Binding<NavigationPath>? = nil
}

extension EnvironmentValues {
    var navPath: Binding<NavigationPath>? {
        get { self[NavPathKey.self] }
        set { self[NavPathKey.self] = newValue }
    }
}

extension View {
    /// Inyecta el path del stack para que las vistas hijas hagan push por él.
    func navPath(_ path: Binding<NavigationPath>) -> some View {
        environment(\.navPath, path)
    }
}

// MARK: - Detail-active environment

/// `true` mientras la pantalla de detalle contenedora está activa (visible y no
/// saliendo). Las filas de `SongListView` consultan este flag para NO disparar
/// reproducción cuando un "ghost tap" cae sobre la lista de un detalle que ya se
/// abandonó: tras el pop de `.navigationTransition(.zoom)`, SwiftUI puede
/// retener el layer de hit-test de la vista saliente y un toque en otra zona
/// acababa reproduciendo una canción del detalle anterior.
///
/// Default `true`: fuera de un detalle (cualquier otro uso de `SongListView`) la
/// lista funciona con normalidad.
private struct DetailActiveKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var detailIsActive: Bool {
        get { self[DetailActiveKey.self] }
        set { self[DetailActiveKey.self] = newValue }
    }
}

// MARK: - Shared song list (Apple Music style)

/// Reusable song table used by AlbumDetailView, PlaylistDetailView, etc.
/// Handles playback, row dividers, and the ··· context menu.
/// Set `showAlbumInMenu: false` when already inside an album page.
///
/// Layout notes:
/// - Rows expand to fill the available width via `maxWidth: .infinity`.
/// - The row content and the `···` menu live in a flat `HStack` so their
///   gesture recognisers are completely independent — no overlap, no delay.
struct SongListView: View {
    let songs: [NavidromeSong]
    let palette: AlbumPalette
    var showAlbumInMenu: Bool = true
    var showArtistInMenu: Bool = true
    var showArtist: Bool = true
    var showCover: Bool = false
    var contextUri: String? = nil
    var contextName: String? = nil
    /// Si se proporciona, el artista solo se muestra cuando hay featurings
    /// (artistas distintos del titular del álbum) — formato Apple Music
    /// "Drake feat. Snoop Dogg". Sobrescribe a `showArtist`.
    var albumArtist: String? = nil
    /// Si se proporciona, el menú ··· ofrece "Quitar de esta playlist"
    /// (canción + índice de fila). El contenedor decide CUÁNDO pasarlo:
    /// solo playlists propias y no gestionadas (editorial / smart / synced
    /// quedan fuera, mismo gate que "Añadir a playlist").
    var onRemoveFromPlaylist: ((NavidromeSong, Int) -> Void)? = nil

    /// Path del NavigationStack contenedor (inyectado por la raíz del stack).
    /// Los pushes (ir al álbum / al artista) se hacen por aquí, usando los
    /// `navigationDestination(for:)` declarados UNA sola vez en la raíz. Así no
    /// se acumulan destinos duplicados al encadenar Album → Artista → Album → …
    @Environment(\.navPath) private var navPath
    /// Bloquea la reproducción al tocar una fila cuando el detalle contenedor ya
    /// no está activo (ghost tap durante/tras el pop de la transición zoom).
    @Environment(\.detailIsActive) private var detailIsActive
    @State private var addToPlaylistSong: NavidromeSong? = nil
    /// Song cuyo menú "Ver artistas" (plural) está abierto. Vehiculiza la
    /// `ViewArtistsSheet` — cuando es nil, la sheet está cerrada. Identifiable
    /// para que `sheet(item:)` la dismissa/reabra automáticamente al cambiar.
    @State private var viewArtistsSong: NavidromeSong? = nil

    private var isLight: Bool { palette.isPrimaryLight }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                rowView(for: song, at: idx)
                    .frame(maxWidth: .infinity)

                if idx < songs.count - 1 {
                    Divider()
                        .background(
                            isLight ? Color.black.opacity(0.07) : Color.white.opacity(0.07)
                        )
                        .padding(.leading, showCover ? 76 : 58)
                        .padding(.trailing, 16)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .sheet(item: $addToPlaylistSong) { song in
            AddToPlaylistView(songId: song.id, songTitle: song.title)
        }
        // Sheet "Ver artistas": modal nativo iOS, lista los artistas de la
        // song y al elegir uno hace push hacia ArtistDetailView por el path del
        // stack (mismo mecanismo que el caso singular).
        .sheet(item: $viewArtistsSong) { song in
            ViewArtistsSheet(
                artists: song.artists ?? [],
                songTitle: song.title,
                onSelect: { artist in navPath?.wrappedValue.append(artist) }
            )
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func rowView(for song: NavidromeSong, at idx: Int) -> some View {
        HStack(spacing: 0) {
            Button {
                guard detailIsActive else { return }
                PlayerService.shared.playPlaylist(songs, startingAt: idx, contextUri: contextUri, contextName: contextName)
            } label: {
                SongRowView(song: song, index: idx + 1, palette: palette, showArtist: showArtist, showCover: showCover, albumArtist: albumArtist)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            menuButton(for: song, at: idx)
        }
    }

    // MARK: - ··· menu button (UIKit — instant, no gesture delay)

    private func menuButton(for song: NavidromeSong, at idx: Int) -> some View {
        let tint: UIColor = isLight
            ? UIColor.black.withAlphaComponent(0.30)
            : UIColor.white.withAlphaComponent(0.45)

        // Capturar el binding del path AHORA (durante el body) para que las
        // UIActions diferidas del menú no lean @Environment fuera de tiempo.
        let path = navPath
        // Estado de favorito capturado en el body (contexto MainActor): la
        // lectura aquí registra la dependencia en Observation, así el menú
        // se reconstruye fresco cuando cambia el Set de favoritos.
        let isStarred = FavoritesStore.shared.isStarred(song.id)

        return InstantMenuButton(tint: tint) {
            // — Playback section
            let playNext = UIAction(
                title: L.playNext,
                image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
            ) { _ in PlayerService.shared.insertNext(song) }

            let addQueue = UIAction(
                title: L.addToQueue,
                image: UIImage(systemName: "text.badge.plus")
            ) { _ in PlayerService.shared.addToQueue(song) }

            let playbackSection = UIMenu(title: "", options: .displayInline, children: [playNext, addQueue])

            // — Album section
            var sections: [UIMenuElement] = [playbackSection]

            if showAlbumInMenu, let albumId = song.albumId, !albumId.isEmpty {
                let goAlbum = UIAction(
                    title: L.goToAlbum,
                    image: UIImage(systemName: "music.note")
                ) { _ in
                    path?.wrappedValue.append(NavidromeAlbum(
                        id: albumId, name: song.album, artist: song.artist,
                        coverArt: song.coverArt, songCount: nil, duration: nil,
                        year: song.year, genre: song.genre, explicitStatus: nil
                    ))
                }
                sections.append(UIMenu(title: "", options: .displayInline, children: [goAlbum]))
            }

            // — Artist section
            // Multi-artist (OpenSubsonic): si la song trae 2+ artistas en
            // `song.artists[]`, mostramos "Ver artistas" (plural) y al
            // tap abrimos un sheet nativo con la lista. Si trae 1 (o el
            // server no expone el array), queda "Ver artista" (singular)
            // que navega directo al `song.artistId`.
            if showArtistInMenu {
                let songArtists = song.artists ?? []
                if songArtists.count > 1 {
                    let goArtists = UIAction(
                        title: L.goToArtists,
                        image: UIImage(systemName: "person.2.crop.square.stack")
                    ) { _ in
                        DispatchQueue.main.async {
                            viewArtistsSong = song
                        }
                    }
                    sections.append(UIMenu(title: "", options: .displayInline, children: [goArtists]))
                } else if let artistId = song.artistId, !artistId.isEmpty {
                    let goArtist = UIAction(
                        title: L.goToArtist,
                        image: UIImage(systemName: "person.crop.circle")
                    ) { _ in
                        path?.wrappedValue.append(NavidromeArtist(id: artistId, name: song.artist, albumCount: nil))
                    }
                    sections.append(UIMenu(title: "", options: .displayInline, children: [goArtist]))
                }
            }

            // — Favorites + Add to playlist (sección "biblioteca")
            let favoriteAction = UIAction(
                title: isStarred ? L.removeFromFavorites : L.addToFavorites,
                image: UIImage(systemName: isStarred ? "star.slash" : "star")
            ) { _ in
                Task { @MainActor in
                    FavoritesStore.shared.toggle(songId: song.id)
                }
            }

            let addToPlaylist = UIAction(
                title: L.addToPlaylist,
                image: UIImage(systemName: "music.note.list")
            ) { _ in
                DispatchQueue.main.async {
                    addToPlaylistSong = song
                }
            }
            sections.append(UIMenu(title: "", options: .displayInline, children: [favoriteAction, addToPlaylist]))

            // — Quitar de ESTA playlist (Subsonic elimina por índice; el
            // handler del contenedor serializa borrados consecutivos)
            if let onRemoveFromPlaylist {
                let removeAction = UIAction(
                    title: L.removeFromThisPlaylist,
                    image: UIImage(systemName: "minus.circle"),
                    attributes: .destructive
                ) { _ in
                    DispatchQueue.main.async {
                        onRemoveFromPlaylist(song, idx)
                    }
                }
                sections.append(UIMenu(title: "", options: .displayInline, children: [removeAction]))
            }

            return UIMenu(children: sections)
        }
        .frame(width: 48, height: 44)
    }
}

// MARK: - Row view

private struct SongRowView: View {
    let song: NavidromeSong
    let index: Int
    let palette: AlbumPalette
    var showArtist: Bool = true
    var showCover: Bool = false
    /// Cuando se pasa, el artista solo se renderiza si la canción tiene
    /// featurings (artistas distintos al titular del álbum). Estilo
    /// Apple Music en album page.
    var albumArtist: String? = nil

    /// Texto del artista a mostrar bajo el título. Devuelve nil si no
    /// se debe mostrar nada.
    private var artistText: String? {
        if let albumArtist {
            return ItemArtist.featuringText(
                artists: song.artists ?? [],
                fallback: song.artist,
                albumArtist: albumArtist
            )
        }
        guard showArtist else { return nil }
        return ItemArtist.displayName(of: song.artists ?? [], fallback: song.artist)
    }

    private enum CacheState: Equatable {
        case none
        case downloading(Double)
        case cached
    }

    @State private var cacheState: CacheState = .none
    private let nowPlaying = NowPlayingState.shared
    private let favorites = FavoritesStore.shared

    private var isLight: Bool { palette.isPrimaryLight }
    private var primaryText:   Color { isLight ? .black                  : .white }
    private var secondaryText: Color { isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.60) }
    private var tertiaryText:  Color { isLight ? Color.black.opacity(0.30) : Color.white.opacity(0.45) }

    private var isCurrentSong: Bool { nowPlaying.isVisible && nowPlaying.songId == song.id }

    var body: some View {
        HStack(spacing: showCover ? 12 : 14) {
            if showCover {
                // Album cover thumbnail (Apple Music playlist style)
                ZStack(alignment: .center) {
                    CachedCoverThumbnail(coverArt: song.coverArt, size: 44, cornerRadius: 6)

                    if isCurrentSong {
                        // Overlay: dark scrim + equalizer
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 44, height: 44)
                        NowPlayingIndicator(
                            isPlaying: nowPlaying.isPlaying,
                            bpm: nowPlaying.currentBpm,
                            color: .white,
                            barWidth: 2.5,
                            height: 12
                        )
                    }
                }
                .frame(width: 44, height: 44)
            } else {
                if isCurrentSong {
                    NowPlayingIndicator(
                        isPlaying: nowPlaying.isPlaying,
                        bpm: nowPlaying.currentBpm,
                        color: isLight ? Color.black : Color.white,
                        barWidth: 2.5,
                        height: 12
                    )
                    .frame(width: 24)
                } else {
                    Text("\(index)")
                        .font(.system(size: 15).monospacedDigit())
                        .foregroundStyle(tertiaryText)
                        .frame(width: 24, alignment: .trailing)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(song.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if song.isExplicit {
                        ExplicitBadge(color: tertiaryText)
                    }
                }

                if let artistText {
                    Text(artistText)
                        .font(.system(size: 13))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            cacheIndicator

            if let dur = song.duration, dur > 0 {
                Text(formatSeconds(dur))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(tertiaryText)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, showCover ? 6 : 10)
        // Estrella de favorito en el gutter izquierdo (estilo Apple Music):
        // se dibuja SOBRE el padding leading de 16pt existente, sin desplazar
        // ninguna columna — vale tanto para playlist (cover) como para álbum
        // (número de pista) y la fila no salta al togglear.
        .overlay(alignment: .leading) {
            if favorites.isStarred(song.id) {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(tertiaryText)
                    .padding(.leading, 3)
            }
        }
        .task { await checkCacheState() }
        .task(id: cacheState) {
            // Poll while not yet cached: detect download start (none→downloading)
            // and track progress (downloading→cached). Cached songs stop polling.
            guard cacheState != .cached else { return }
            let interval: UInt64 = cacheState == .none ? 2_000_000_000 : 800_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                await checkCacheState()
            }
        }
    }

    // MARK: - Cache indicator (Apple-native micro animation)

    @ViewBuilder
    private var cacheIndicator: some View {
        switch cacheState {
        case .none:
            EmptyView()

        case .downloading(let progress):
            ZStack {
                Circle()
                    .stroke(tertiaryText.opacity(0.3), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tertiaryText, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            .transition(.scale(scale: 0.5).combined(with: .opacity))

        case .cached:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(isLight ? Color.black.opacity(0.3) : Color.white.opacity(0.3))
                .transition(.scale(scale: 0.1).combined(with: .opacity))
                .symbolEffect(.bounce, value: cacheState)
        }
    }

    // MARK: - State

    private func checkCacheState() async {
        let cached = await OfflineStorageManager.shared.isCached(songId: song.id)
        if cached {
            if cacheState != .cached {
                withAnimation(Anim.moderate) { cacheState = .cached }
            }
            return
        }

        if let progress = DownloadManager.shared.downloadProgress(songId: song.id) {
            withAnimation(Anim.micro) { cacheState = .downloading(progress) }
        } else if DownloadManager.shared.isSongQueued(songId: song.id) {
            withAnimation(Anim.micro) { cacheState = .downloading(0) }
        } else if cacheState != .none {
            withAnimation(Anim.small) { cacheState = .none }
        }
    }

    private func formatSeconds(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Instant ··· menu (UIKit, zero gesture delay)

/// Wraps a `UIButton` with `showsMenuAsPrimaryAction = true`.
/// The menu appears on first touch — no SwiftUI gesture disambiguation.
struct InstantMenuButton: UIViewRepresentable {
    let tint: UIColor
    let menuBuilder: () -> UIMenu

    class Coordinator {
        var menuBuilder: () -> UIMenu
        init(menuBuilder: @escaping () -> UIMenu) {
            self.menuBuilder = menuBuilder
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(menuBuilder: menuBuilder)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        button.setImage(UIImage(systemName: "ellipsis", withConfiguration: config), for: .normal)
        button.showsMenuAsPrimaryAction = true
        button.tintColor = tint
        // Construir el menú de forma diferida: solo se ejecuta menuBuilder()
        // cuando el usuario abre el menú, no en cada re-render de SwiftUI.
        // Esto evita que las actualizaciones frecuentes de NowPlayingState (250ms)
        // reconstruyan el UIMenu constantemente y causen parpadeos en la UI.
        let coordinator = context.coordinator
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { completion in
                completion(coordinator.menuBuilder().children)
            }
        ])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.menuBuilder = menuBuilder
        button.tintColor = tint
    }
}

// MARK: - Song list skeleton (loading placeholder)

/// Mirrors SongListView's row layout while data is loading. Use the known
/// song count (e.g. `playlist.songCount`) so the scroll height matches the
/// final list and rows don't shift sideways when real songs arrive.
struct SongListSkeleton: View {
    let count: Int
    let palette: AlbumPalette
    var showCover: Bool = false
    var showArtist: Bool = true

    private var isLight: Bool { palette.isPrimaryLight }
    private var skeletonColor: Color {
        isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.10)
    }

    private static let titleWidths: [CGFloat]    = [180, 220, 150, 200, 165, 195, 175]
    private static let subtitleWidths: [CGFloat] = [110, 140, 95, 125, 100, 130]

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { idx in
                row(at: idx)
                    .frame(maxWidth: .infinity)

                if idx < count - 1 {
                    Divider()
                        .background(
                            isLight ? Color.black.opacity(0.07) : Color.white.opacity(0.07)
                        )
                        .padding(.leading, showCover ? 76 : 58)
                        .padding(.trailing, 16)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func row(at idx: Int) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: showCover ? 12 : 14) {
                if showCover {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(skeletonColor)
                        .frame(width: 44, height: 44)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(skeletonColor)
                        .frame(width: 14, height: 12)
                        .frame(width: 24, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(skeletonColor)
                        .frame(width: Self.titleWidths[idx % Self.titleWidths.count], height: 13)
                    if showArtist {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(skeletonColor)
                            .frame(width: Self.subtitleWidths[idx % Self.subtitleWidths.count], height: 11)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                RoundedRectangle(cornerRadius: 4)
                    .fill(skeletonColor)
                    .frame(width: 28, height: 11)
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .padding(.vertical, showCover ? 6 : 10)

            // Reserves the ··· menu width so the skeleton row's content area
            // matches SongListView's exactly — no horizontal jump on transition.
            Color.clear.frame(width: 48, height: 44)
        }
    }
}

// MARK: - Explicit badge (Apple Music style)

struct ExplicitBadge: View {
    var color: Color = .secondary
    var size: CGFloat = 14

    var body: some View {
        Text("E")
            .font(.system(size: size * 0.64, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

// MARK: - Pop-aware hit testing

/// Hace que el contenido deje de capturar toques mientras el pop de navegación
/// está en curso, de modo que los toques ATRAVIESEN hacia la pantalla anterior.
/// Resuelve dos síntomas del zoom-out de `.navigationTransition(.zoom)`: la grid
/// de detrás recupera el scroll de inmediato y un toque ya no dispara acciones de
/// la pantalla que se abandona (ghost tap DURANTE la animación, que el guard por
/// `onDisappear`/`detailIsActive` no cubre porque llega al final del pop).
///
/// No toca la animación ni los gestos de navegación: el swipe-back y la
/// pinch-to-dismiss viven en el UINavigationController, fuera de este contenido,
/// así que desactivar el hit-test del contenido no los afecta.
private struct PopHitTestGuard: ViewModifier {
    @State private var isPopping = false

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!isPopping)
            .background(
                NavigationTransitionObserver { popping in
                    if isPopping != popping { isPopping = popping }
                }
            )
    }
}

extension View {
    /// Ver `PopHitTestGuard`. Aplicar al contenido raíz de una pantalla de
    /// detalle que se abre con `.navigationTransition(.zoom)`.
    func blocksTouchesDuringPop() -> some View {
        modifier(PopHitTestGuard())
    }
}

/// Observa el ciclo de transición del UINavigationController contenedor desde
/// SwiftUI. Llama `onChange(true)` al INICIO del pop (no en `onDisappear`, que
/// llega al final) y `onChange(false)` si el pop interactivo se cancela
/// (swipe-back soltado a medias) o al (re)aparecer la pantalla.
///
/// Usa el `transitionCoordinator` (UIKit público), no gesture recognizers
/// privados: cubre swipe-back, botón atrás y el gesto del zoom por igual sin
/// tocar ninguno de ellos.
private struct NavigationTransitionObserver: UIViewControllerRepresentable {
    var onChange: (Bool) -> Void

    func makeUIViewController(context: Context) -> ObserverVC {
        let vc = ObserverVC()
        vc.onChange = onChange
        return vc
    }

    func updateUIViewController(_ vc: ObserverVC, context: Context) {
        vc.onChange = onChange
    }

    final class ObserverVC: UIViewController {
        var onChange: ((Bool) -> Void)?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            // (Re)entrar a la pantalla la reactiva.
            onChange?(false)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // La pantalla empieza a salir: el contenido deja pasar los toques
            // durante TODA la transición.
            onChange?(true)
            // Si el pop es interactivo y el usuario lo cancela (suelta el
            // swipe-back a medias), reactivamos el contenido.
            let coordinator = transitionCoordinator ?? navigationController?.transitionCoordinator
            coordinator?.animate(alongsideTransition: nil) { [weak self] ctx in
                if ctx.isCancelled { self?.onChange?(false) }
            }
        }
    }
}
