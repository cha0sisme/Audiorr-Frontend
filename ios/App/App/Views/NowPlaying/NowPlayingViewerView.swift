import SwiftUI
import UIKit

/// Viewer de reproducción a pantalla completa (estilo Apple Music).
/// Presentado como overlay en ContentView (no .fullScreenCover).
struct NowPlayingViewerView: View {
    private var state = NowPlayingState.shared

    // Drag-to-dismiss
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    // Add to playlist
    @State private var showAddToPlaylist = false

    // View artists (multi-artist sheet — OpenSubsonic `song.artists[]`)
    @State private var showViewArtists = false

    // Queue panel
    @State private var showQueue = false

    // Device picker
    @State private var showDevicePicker = false

    // Full-res artwork loaded manually (bypasses AsyncImage cache)
    @State private var fullArtworkImage: UIImage?
    @State private var lastLoadedCoverArt: String?
    @State private var artworkTask: Task<Void, Never>?

    // Accent color extracted from artwork
    @State private var accentColor: Color = .white
    @State private var lastExtractedUrl: String?
    /// Paleta completa de la cover — alimenta el MeshGradient de fondo
    /// (estilo Apple Music iOS 26.4, sin blur).
    @State private var palette: AlbumPalette = .default

    // Canvas video (Fase 4)
    @State private var canvasUrl: URL?
    @State private var lastCanvasSongId: String?

    // Animated artwork (motion artwork por álbum, estilo Apple Music iOS 26)
    @State private var animatedArtworkUrl: URL?
    @State private var lastArtworkAlbumId: String?

    /// Hay vídeo de fondo si existe canvas o animated artwork. Controla el
    /// layout bottom-grouped (sin cover estático) y el scrim extra de lyrics.
    private var hasBackdropVideo: Bool { canvasUrl != nil || animatedArtworkUrl != nil }

    /// Firma que cambia cuando aparece/desaparece un backdrop de vídeo o
    /// cuando se sustituye por otro. Permite que la animación del body
    /// dispare crossfade en cualquiera de esas transiciones.
    private var backdropVideoSignature: String {
        (canvasUrl?.absoluteString ?? "") + "|" + (animatedArtworkUrl?.absoluteString ?? "")
    }

    // Lyrics (Fase 5)
    @State private var lyricsResult: LyricsService.LyricsResult = .empty
    @State private var showLyrics = false
    @State private var lastLyricsSongId: String?

    private var hasLyrics: Bool { !lyricsResult.lines.isEmpty }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Fondo negro base
                Color.black
                    .ignoresSafeArea()

                // Backdrop tiers: Canvas (canción) > Animated Artwork (álbum) > cover difuminado.
                // El Canvas de Spotify es por canción y más específico, así que
                // manda cuando exista. El animated artwork (motion artwork de
                // Apple Music, ratio 3:4) es la segunda fuente, por álbum.
                if let canvasUrl {
                    videoBackdrop(url: canvasUrl)
                } else if let animatedArtworkUrl {
                    videoBackdrop(url: animatedArtworkUrl)
                } else {
                    // MeshGradient con los colores extraídos de la cover.
                    // Apple Music iOS 26 no usa blur del cover: construye un
                    // gradient cromático con los tonos dominantes. La grid
                    // 3×3 entrelaza primary/secondary/accent para evitar
                    // bandas planas y dar la sensación "flowing" de Apple.
                    meshBackground
                        .ignoresSafeArea()
                        .animation(.easeInOut(duration: 0.6), value: palette.primary)

                    Color.black.opacity(0.30)
                        .ignoresSafeArea()
                }

                // Contenido principal
                VStack(spacing: 0) {
                    // Drag handle
                    dragHandle
                        .padding(.top, 8)

                    if showLyrics && hasLyrics {
                        // Lyrics mode (Apple Music style)

                        // Header: small cover + title/artist + 3-dot menu
                        lyricsHeader
                            .padding(.top, 12)

                        // Lyrics fill the remaining space
                        LyricsView(lyrics: lyricsResult)

                        // Progress bar
                        ProgressBarView()

                        Spacer()
                            .frame(height: 12)

                        // Playback controls
                        PlaybackControlsView(glassStyle: hasBackdropVideo)

                        // Push bottom actions down
                        Spacer()

                    } else if hasBackdropVideo {
                        // Canvas mode: all controls grouped at bottom (Spotify-style)
                        Spacer()

                        songInfoView

                        Spacer()
                            .frame(height: 20)

                        ProgressBarView()

                        Spacer()
                            .frame(height: 16)

                        PlaybackControlsView(glassStyle: true)

                        Spacer()
                            .frame(height: 16)

                    } else {
                        // Normal mode: artwork centered, controls below
                        Spacer()
                            .frame(minHeight: 8, maxHeight: 40)

                        artworkView(geo: geo)

                        Spacer()
                            .frame(height: 16)

                        songInfoView

                        Spacer()
                            .frame(height: 20)

                        ProgressBarView()

                        Spacer()
                            .frame(height: 16)

                        PlaybackControlsView(glassStyle: false)

                        // Push bottom actions to the very bottom
                        Spacer()
                    }

                    // Bottom action row (lyrics, queue, connect)
                    bottomActionsRow
                        .padding(.bottom, geo.safeAreaInsets.bottom)
                }
                .padding(.horizontal, 28)

            }
            .offset(y: dragOffset)
            .gesture(dismissDragGesture(screenHeight: geo.size.height))
            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.86), value: isDragging)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onChange(of: state.viewerIsOpen) { _, isOpen in
            // Si el viewer se cierra externamente (Dynamic Island, Remote Command, etc.)
            // mientras hay un drag en curso, resetear el offset para que la transición
            // de salida arranque desde la posición correcta.
            if !isOpen {
                dragOffset = 0
                isDragging = false
            }
        }
        .onChange(of: state.coverArt) { _, _ in
            loadArtwork()
        }
        .onChange(of: state.songId) { _, songId in
            resolveCanvas(songId: songId)
            resolveLyrics(songId: songId)
        }
        .onChange(of: state.albumId) { _, albumId in
            resolveAnimatedArtwork(albumId: albumId)
        }
        .onChange(of: state.title) { _, _ in
            // Title arrives via nativeUpdateNowPlaying (separate from songId).
            // Retry lyrics if we have a songId but lyrics are still empty.
            if !state.songId.isEmpty && lyricsResult.lines.isEmpty {
                lastLyricsSongId = nil
                resolveLyrics(songId: state.songId)
            }
        }
        .onAppear {
            dragOffset = 0
            print("[Viewer] onAppear: songId='\(state.songId)' albumId='\(state.albumId)' artistId='\(state.artistId)' title='\(state.title)' coverArt='\(state.coverArt.prefix(20))' queueCount=\(state.queue.count)")
            // Reset dedup guards so lyrics/canvas/artwork resolve fresh on each open
            lastLyricsSongId = nil
            lastCanvasSongId = nil
            lastArtworkAlbumId = nil
            lastLoadedCoverArt = nil
            lastExtractedUrl = nil
            loadArtwork()
            resolveCanvas(songId: state.songId)
            resolveLyrics(songId: state.songId)
            resolveAnimatedArtwork(albumId: state.albumId)
            // Queue is already synced natively by QueueManager
        }
        // Animaciones para los cambios de layout/modo del viewer.
        // Una `value:` cada cambio importante — SwiftUI las apila y aplica
        // según corresponda. Spring con bounce moderado para los reflows
        // de posición (sensación elástica natural), easeInOut para el
        // crossfade de backdrop (no es un cambio de posición).
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: hasBackdropVideo)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: showLyrics)
        .animation(.easeInOut(duration: 0.5), value: backdropVideoSignature)
        .sheet(isPresented: $showQueue) {
            QueuePanelView()
        }
        .sheet(isPresented: $showDevicePicker) {
            DevicePickerView()
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistView(songId: state.songId, songTitle: state.title)
        }
        // Sheet "Ver artistas" — modal nativo iOS con la lista de
        // `song.artists[]`. Al elegir uno, encadenamos el mismo flow que el
        // "Ver artista" singular: `pendingNavigation` + cerrar el viewer
        // para que ContentView haga el push hacia ArtistDetailView.
        .sheet(isPresented: $showViewArtists) {
            ViewArtistsSheet(
                artists: state.currentArtists,
                songTitle: state.title,
                onSelect: { artist in
                    state.pendingNavigation = .artist(id: artist.id, name: artist.name)
                    state.viewerIsOpen = false
                }
            )
        }
    }

    // MARK: - Context Menu (UIKit instant menu — same style as SongListView)

    private func contextMenuButton(tintColor: UIColor = UIColor.white.withAlphaComponent(0.6)) -> some View {
        InstantMenuButton(tint: tintColor) {
            let state = NowPlayingState.shared

            // — Playback section
            var playbackActions: [UIAction] = []

            if !state.songId.isEmpty {
                // Resolve album name from current queue entry if available
                let albumName = state.queue.first(where: { $0.id == state.songId })?.album ?? ""
                let currentSong = NavidromeSong(
                    id: state.songId, title: state.title, artist: state.artist,
                    artistId: state.artistId.isEmpty ? nil : state.artistId,
                    album: albumName, albumId: state.albumId.isEmpty ? nil : state.albumId,
                    coverArt: state.coverArt, duration: nil, track: nil,
                    year: nil, genre: nil, explicitStatus: nil,
                    replayGainTrackGain: nil, replayGainTrackPeak: nil,
                    replayGainAlbumGain: nil, replayGainAlbumPeak: nil
                )
                playbackActions.append(UIAction(
                    title: "Reproducir a continuación",
                    image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
                ) { _ in PlayerService.shared.insertNext(currentSong) })

                playbackActions.append(UIAction(
                    title: "Añadir a la cola",
                    image: UIImage(systemName: "text.badge.plus")
                ) { _ in PlayerService.shared.addToQueue(currentSong) })
            }

            let playbackSection = UIMenu(title: "", options: .displayInline, children: playbackActions)

            var sections: [UIMenuElement] = [playbackSection]

            // — Add to playlist
            if !state.songId.isEmpty {
                let addToPlaylist = UIAction(
                    title: "Añadir a playlist",
                    image: UIImage(systemName: "music.note.list")
                ) { _ in
                    DispatchQueue.main.async {
                        self.showAddToPlaylist = true
                    }
                }
                sections.append(UIMenu(title: "", options: .displayInline, children: [addToPlaylist]))
            }

            // — Navigation section
            var navActions: [UIAction] = []

            if !state.albumId.isEmpty {
                let albumId = state.albumId
                navActions.append(UIAction(
                    title: "Ir al álbum",
                    image: UIImage(systemName: "music.note")
                ) { _ in
                    DispatchQueue.main.async {
                        state.pendingNavigation = .album(id: albumId)
                        state.viewerIsOpen = false
                    }
                })
            }

            // Multi-artist (OpenSubsonic): si la song actual viene con 2+
            // entradas en `currentArtists`, ofrecemos "Ver artistas"
            // (plural) y al tap abrimos el sheet `ViewArtistsSheet`. Si solo
            // hay 1 (o el server no expone el array), queda "Ver artista"
            // (singular) navegando directo al `state.artistId`.
            if state.currentArtists.count > 1 {
                navActions.append(UIAction(
                    title: L.goToArtists,
                    image: UIImage(systemName: "person.2.crop.square.stack")
                ) { _ in
                    DispatchQueue.main.async {
                        self.showViewArtists = true
                    }
                })
            } else if !state.artistId.isEmpty {
                let artistId = state.artistId
                let artistName = state.artist
                navActions.append(UIAction(
                    title: L.goToArtist,
                    image: UIImage(systemName: "person.crop.circle")
                ) { _ in
                    DispatchQueue.main.async {
                        state.pendingNavigation = .artist(id: artistId, name: artistName)
                        state.viewerIsOpen = false
                    }
                })
            }

            if !navActions.isEmpty {
                sections.append(UIMenu(title: "", options: .displayInline, children: navActions))
            }

            return UIMenu(children: sections)
        }
    }

    // MARK: - Mesh Gradient Backdrop (Apple Music style, sin blur)

    /// `MeshGradient` 3×3 con los colores de la cover. Apple Music iOS 26
    /// construye un gradient fluido a partir de los tonos dominantes en
    /// lugar de difuminar la imagen. La grid entrelaza `primary`,
    /// `secondary` y `accent` para dar profundidad sin bandas planas.
    private var meshBackground: some View {
        let primary = Color(palette.primary)
        let secondary = Color(palette.secondary)
        let accent = Color(palette.accent)

        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
            ],
            colors: [
                primary, accent,    secondary,
                accent,  primary,   accent,
                secondary, accent,  primary
            ]
        )
    }

    // MARK: - Video Backdrop (Canvas / Animated Artwork)

    /// Backdrop común para canvas y animated artwork: vídeo edge-to-edge,
    /// gradiente oscuro abajo para legibilidad, scrim extra si lyrics activas.
    /// Apple Music hace lo mismo: vídeo fullscreen + gradiente abajo, sin
    /// adornos sobre el clip (ningún botón "X" explícito).
    @ViewBuilder
    private func videoBackdrop(url: URL) -> some View {
        CanvasView(url: url)
            .ignoresSafeArea()
            .transition(.opacity)

        canvasGradient
            .ignoresSafeArea()

        if showLyrics && hasLyrics {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .transition(.opacity)
        }
    }

    // MARK: - Canvas Gradient

    private var canvasGradient: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.18), location: 0),
                .init(color: .black.opacity(0),    location: 0.18),
                .init(color: .black.opacity(0),    location: 0.35),
                .init(color: .black.opacity(0.55), location: 0.60),
                .init(color: .black.opacity(0.88), location: 0.78),
                .init(color: .black.opacity(0.97), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Drag Handle

    private var dragHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.4))
            .frame(width: 36, height: 5)
    }

    // MARK: - Artwork

    @ViewBuilder
    private func artworkView(geo: GeometryProxy) -> some View {
        let size = min(max(geo.size.width - 56, 120), 400)
        let artworkScale: CGFloat = state.isPlaying ? 1.0 : 0.88

        Group {
            if let img = fullArtworkImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 28, y: 10)
        .scaleEffect(artworkScale)
        .animation(.spring(response: 0.55, dampingFraction: 0.72), value: state.isPlaying)
    }

    private var artworkPlaceholder: some View {
        ZStack {
            Color(.secondarySystemFill)
            Image(systemName: "music.note")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Song Info

    private var songInfoView: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(state.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if state.isExplicit {
                        ExplicitBadge(color: .white.opacity(0.5), size: 18)
                    }
                }

                Text(ItemArtist.displayName(of: state.currentArtists, fallback: state.artist))
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)

                statusIndicator
            }

            Spacer(minLength: 8)

            contextMenuButton()
                .frame(width: 40, height: 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Lyrics mode header: small cover + title/artist + 3-dot menu (Apple Music style)
    private var lyricsHeader: some View {
        HStack(spacing: 12) {
            // Small album cover. `matchedGeometryEffect` con el mismo id
            // que el mini cover para que la animación zoom funcione también
            // cuando el usuario abre el viewer en modo lyrics.
            Group {
                if let img = fullArtworkImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color(.secondarySystemFill)
                        Image(systemName: "music.note")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Title + artist
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(state.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if state.isExplicit {
                        ExplicitBadge(color: .white.opacity(0.5), size: 13)
                    }
                }

                Text(ItemArtist.displayName(of: state.currentArtists, fallback: state.artist))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            contextMenuButton(tintColor: UIColor.white.withAlphaComponent(0.5))
                .frame(width: 36, height: 36)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if state.isRemote, let deviceName = state.remoteDeviceName {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text("Reproduciendo en \(deviceName)")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Drag-to-Dismiss Gesture

    private func dismissDragGesture(screenHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                guard state.viewerIsOpen else { return }
                let translation = value.translation.height
                if translation > 0 {
                    isDragging = true
                    dragOffset = translation * 0.7
                }
            }
            .onEnded { value in
                isDragging = false
                guard state.viewerIsOpen else {
                    dragOffset = 0
                    return
                }
                let translation = value.translation.height
                let velocity = value.predictedEndTranslation.height - translation

                let thresholdMet = translation > screenHeight * 0.2
                let velocityMet = velocity > 800 && translation > 30

                if thresholdMet || velocityMet {
                    // Close: ContentView's .animation handles the slide-down
                    state.viewerIsOpen = false
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        dragOffset = 0
                    }
                }
            }
    }

    // MARK: - Artwork Loading + Accent Color

    private func loadArtwork() {
        let currentCoverArt = state.coverArt

        // Si el coverArt cambió respecto al anterior, limpiamos el cover viejo
        // antes de empezar la descarga del nuevo. Sin esto se ve el cover de
        // la canción anterior con el título de la nueva durante la ventana de
        // descarga (síntoma reportado bajo cobertura limitada). Mejor placeholder
        // neutro que cover incorrecto.
        if currentCoverArt != lastLoadedCoverArt {
            artworkTask?.cancel()
            fullArtworkImage = nil
            lastExtractedUrl = nil
        }

        // 1. Try high-res via NavidromeService if coverArt ID is available
        if !currentCoverArt.isEmpty, currentCoverArt != lastLoadedCoverArt {
            lastLoadedCoverArt = currentCoverArt
            if let url = NavidromeService.shared.coverURL(id: currentCoverArt, size: 2000) {
                loadImage(from: url)
                return
            }
        }

        // 2. Fallback: derive high-res URL from artworkUrl (replace size=300 → size=2000)
        if fullArtworkImage == nil, let urlStr = state.artworkUrl {
            let hiRes = urlStr.replacingOccurrences(of: "size=300", with: "size=2000")
            if let url = URL(string: hiRes) {
                loadImage(from: url)
            }
        }
    }

    private func loadImage(from url: URL) {
        let urlStr = url.absoluteString
        guard urlStr != lastExtractedUrl else { return }
        lastExtractedUrl = urlStr

        artworkTask?.cancel()
        artworkTask = Task.detached(priority: .userInitiated) {
            var request = URLRequest(url: url)
            request.cachePolicy = .useProtocolCachePolicy
            // Sesión `interactive`: cover del viewer (2000px) — UI visible
            // que el usuario está mirando ahora mismo.
            guard let (data, _) = try? await AudiorrNetwork.interactive.data(for: request),
                  !Task.isCancelled,
                  let image = UIImage(data: data) else { return }
            let extractedPalette = ColorExtractor.extract(from: image)
            let color = Color(extractedPalette.accent)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                fullArtworkImage = image
                withAnimation(.easeInOut(duration: 0.4)) {
                    accentColor = color
                    palette = extractedPalette
                }
            }
        }
    }

    // MARK: - Bottom Actions Row

    private var bottomActionsRow: some View {
        HStack(spacing: 32) {
            // Lyrics — SIEMPRE visible para no remontar el HStack cuando
            // termina la resolución de la letra. Disabled hasta que haya
            // letras (Apple Music: el icono ocupa su sitio desde el primer
            // frame, solo cambia su estado activable).
            bottomActionButton(
                icon: showLyrics ? "quote.bubble.fill" : "quote.bubble",
                isActive: showLyrics,
                isEnabled: hasLyrics
            ) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    showLyrics.toggle()
                }
            }

            // Queue
            bottomActionButton(icon: "list.bullet", isActive: showQueue) {
                showQueue = true
            }

            // Audiorr Connect / Audio Route
            bottomActionButton(
                icon: state.isRemote ? "airplayaudio" : state.audioRouteIcon,
                isActive: state.isRemote || state.audioRouteIcon != "iphone"
            ) {
                showDevicePicker = true
            }
        }
    }

    private func bottomActionButton(icon: String, isActive: Bool, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(
                    isEnabled
                        ? (isActive ? .white : .white.opacity(0.5))
                        : .white.opacity(0.25)
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    // MARK: - Canvas Resolution

    private func resolveCanvas(songId: String) {
        guard !songId.isEmpty, songId != lastCanvasSongId else { return }
        lastCanvasSongId = songId

        Task {
            let result = await CanvasService.shared.resolve(songId: songId)
            switch result {
            case .video(let url):
                withAnimation { canvasUrl = url }
            case .image:
                withAnimation { canvasUrl = nil }
            case .none:
                withAnimation { canvasUrl = nil }
            }
        }
    }

    // MARK: - Animated Artwork Resolution

    private func resolveAnimatedArtwork(albumId: String) {
        guard albumId != lastArtworkAlbumId else { return }
        lastArtworkAlbumId = albumId

        // Sin albumId: limpiar el vídeo si lo había, para no arrastrar el motion
        // del álbum anterior cuando el siguiente track no expone albumId.
        guard !albumId.isEmpty else {
            withAnimation { animatedArtworkUrl = nil }
            return
        }

        Task {
            let result = await AlbumArtworkService.shared.resolve(albumId: albumId)
            switch result {
            case .video(let url):
                withAnimation { animatedArtworkUrl = url }
            case .none:
                withAnimation { animatedArtworkUrl = nil }
            }
        }
    }

    // MARK: - Lyrics Resolution

    private func resolveLyrics(songId: String) {
        guard !songId.isEmpty, songId != lastLyricsSongId else {
            print("[Viewer] resolveLyrics SKIPPED: songId='\(songId)' lastLyricsSongId=\(lastLyricsSongId ?? "nil")")
            return
        }
        lastLyricsSongId = songId
        showLyrics = false
        print("[Viewer] resolveLyrics START: songId=\(songId) title='\(state.title)' artist='\(state.artist)'")

        Task {
            let result = await LyricsService.shared.fetch(
                songId: songId,
                title: state.title,
                artist: state.artist
            )
            print("[Viewer] resolveLyrics DONE: lines=\(result.lines.count) synced=\(result.isSynced) source=\(result.source)")
            withAnimation {
                lyricsResult = result
            }
        }
    }
}
