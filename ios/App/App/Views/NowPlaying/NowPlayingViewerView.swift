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

    // Queue panel
    @State private var showQueue = false

    // Device picker
    @State private var showDevicePicker = false

    // Full-res artwork loaded manually (bypasses AsyncImage cache)
    @State private var fullArtworkImage: UIImage?
    @State private var lastLoadedCoverArt: String?

    // Accent color extracted from artwork
    @State private var accentColor: Color = .white
    @State private var lastExtractedUrl: String?

    // Canvas video (Fase 4)
    @State private var canvasUrl: URL?
    @State private var lastCanvasSongId: String?

    private var hasCanvas: Bool { canvasUrl != nil }

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

                // Backdrop: canvas video or blurred artwork
                if let canvasUrl {
                    CanvasView(url: canvasUrl)
                        .ignoresSafeArea()
                        .transition(.opacity)

                    canvasGradient
                        .ignoresSafeArea()
                } else {
                    // Blurred artwork backdrop
                    if let img = fullArtworkImage {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .blur(radius: 45)
                            .saturation(1.4)
                            .scaleEffect(1.2)
                            .ignoresSafeArea()
                    }

                    Color.black.opacity(0.45)
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
                        PlaybackControlsView(glassStyle: hasCanvas)

                    } else {
                        if hasCanvas {
                            // Canvas mode: push controls to the bottom
                            Spacer()
                        } else {
                            Spacer()
                                .frame(minHeight: 8, maxHeight: 40)

                            artworkView(geo: geo)

                            Spacer()
                                .frame(height: 16)
                        }

                        // Info de canción + menu
                        songInfoView

                        Spacer()
                            .frame(height: 20)

                        // Progress bar
                        ProgressBarView()

                        Spacer()
                            .frame(height: 16)

                        // Playback controls
                        PlaybackControlsView(glassStyle: hasCanvas)
                    }

                    if !hasCanvas {
                        Spacer()
                    } else {
                        Spacer()
                            .frame(height: 24)
                    }

                    // Bottom action row (lyrics, connect, etc.)
                    bottomActionsRow
                        .padding(.bottom, geo.safeAreaInsets.bottom + 12)
                }
                .padding(.horizontal, 28)
            }
            .offset(y: dragOffset)
            .gesture(dismissDragGesture(screenHeight: geo.size.height))
            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.86), value: isDragging)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onChange(of: state.coverArt) { _, _ in
            loadArtwork()
        }
        .onChange(of: state.songId) { _, songId in
            resolveCanvas(songId: songId)
            resolveLyrics(songId: songId)
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
            // Reset dedup guards so lyrics/canvas resolve fresh on each open
            lastLyricsSongId = nil
            lastCanvasSongId = nil
            lastLoadedCoverArt = nil
            lastExtractedUrl = nil
            loadArtwork()
            resolveCanvas(songId: state.songId)
            resolveLyrics(songId: state.songId)
            // Queue is already synced natively by QueueManager
        }
        .animation(.easeInOut(duration: 0.5), value: hasCanvas)
        .sheet(isPresented: $showQueue) {
            QueuePanelView()
        }
        .sheet(isPresented: $showDevicePicker) {
            DevicePickerView()
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistView(songId: state.songId, songTitle: state.title)
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

            if !state.artistId.isEmpty {
                let artistId = state.artistId
                let artistName = state.artist
                navActions.append(UIAction(
                    title: "Ir al artista",
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
                Text(state.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(state.artist)
                    .font(.title3)
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
            // Small album cover
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
                Text(state.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(state.artist)
                    .font(.subheadline)
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
                let translation = value.translation.height
                if translation > 0 {
                    isDragging = true
                    dragOffset = translation * 0.7
                }
            }
            .onEnded { value in
                isDragging = false
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

        Task.detached(priority: .userInitiated) {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let image = UIImage(data: data) else { return }
            let palette = ColorExtractor.extract(from: image)
            let color = Color(palette.accent)
            await MainActor.run {
                fullArtworkImage = image
                withAnimation(.easeInOut(duration: 0.4)) {
                    accentColor = color
                }
            }
        }
    }

    // MARK: - Bottom Actions Row

    private var bottomActionsRow: some View {
        HStack(spacing: 32) {
            // Lyrics
            if hasLyrics {
                bottomActionButton(
                    icon: showLyrics ? "quote.bubble.fill" : "quote.bubble",
                    isActive: showLyrics
                ) {
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

    private func bottomActionButton(icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(isActive ? .white : .white.opacity(0.5))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
