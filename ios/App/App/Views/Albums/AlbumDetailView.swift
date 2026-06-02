import SwiftUI

// MARK: - View Model

@MainActor
final class AlbumDetailViewModel: ObservableObject {
    @Published var songs: [NavidromeSong] = []
    @Published var album: NavidromeAlbum?
    @Published var isLoadingSongs = true
    @Published var isLoadingNotes = true
    @Published var palette: AlbumPalette = .default
    @Published var coverImage: UIImage?
    @Published var recordLabels: [RecordLabel] = []
    @Published var albumNotes: String?
    /// Motion artwork (Apple Music) si el álbum lo tiene. Apple lo usa de
    /// fondo del header con la cover estática encima — bucle decorativo,
    /// independiente del estado de reproducción.
    @Published var animatedArtworkUrl: URL?

    private let api = NavidromeService.shared
    let initialAlbum: NavidromeAlbum
    private var paletteReady = false

    init(album: NavidromeAlbum) {
        self.initialAlbum = album
        self.album = album
        // Pre-load cached cover immediately so the hero transition doesn't flash a placeholder
        if let cached = AlbumCoverCache.shared.image(for: album.coverArt) {
            self.coverImage = cached
            // Palette from cache → colors appear WITH the zoom transition, zero delay
            if let id = album.coverArt, let p = PaletteCache.shared.palette(for: id) {
                self.palette = p
                self.paletteReady = true
            }
        }
    }

    var displayAlbum: NavidromeAlbum { album ?? initialAlbum }

    /// Each section publishes independently — songs, notes and cover land
    /// when their own request resolves, so the UI fills in progressively
    /// instead of waiting on the slowest of the three.
    func load() async {
        isLoadingSongs = true
        isLoadingNotes = true

        async let songsDone: Void = loadSongs()
        async let notesDone: Void = loadNotes()
        async let coverDone: Void = loadCoverAndPalette()
        async let motionDone: Void = loadAnimatedArtwork()

        _ = await (songsDone, notesDone, coverDone, motionDone)
    }

    private func loadAnimatedArtwork() async {
        let result = await AlbumArtworkService.shared.resolve(albumId: initialAlbum.id)
        if case .video(let url) = result {
            self.animatedArtworkUrl = url
        }
    }

    private func loadSongs() async {
        if let (al, songs, labels) = try? await api.getAlbumDetail(albumId: initialAlbum.id) {
            self.songs = songs
            self.recordLabels = labels
            if let al { self.album = al }
        }
        isLoadingSongs = false
    }

    private func loadNotes() async {
        let notes = await api.getAlbumInfo(albumId: initialAlbum.id)
        self.albumNotes = notes
        isLoadingNotes = false
    }

    private func loadCoverAndPalette() async {
        guard let image = await fetchCover() else { return }
        self.coverImage = image
        // Skip extraction if palette was already loaded from cache in init
        if !paletteReady {
            let extracted = await Task.detached(priority: .userInitiated) {
                ColorExtractor.extract(from: image)
            }.value
            self.palette = extracted
            if let key = initialAlbum.coverArt {
                PaletteCache.shared.set(extracted, for: key)
            }
        }
    }

    private func fetchCover() async -> UIImage? {
        // Cache propio del detalle (`#hires`): el cache de la card guarda la
        // cover a baja resolución (300/400px) bajo el id pelado; si el detalle
        // lo reutilizara —flujo normal grid→tap— se vería blando. Con una clave
        // separada el detalle pide su propia resolución sin colisionar. El
        // preview instantáneo durante la transición sí usa el cache de la card
        // (ver init), y aquí se sustituye por la versión nítida al cargar.
        let hiresKey = initialAlbum.coverArt.map { $0 + "#hires" }
        if let cached = AlbumCoverCache.shared.image(for: hiresKey) {
            return cached
        }
        // size=1200 para el cover de detalle grande (~267–300pt) nítido @3x.
        guard let url = api.coverURL(id: initialAlbum.coverArt, size: 1200) else { return nil }
        guard let (data, _) = try? await AudiorrNetwork.background.data(from: url) else { return nil }
        guard let img = UIImage(data: data) else { return nil }
        AlbumCoverCache.shared.setImage(img, for: hiresKey)
        return img
    }
}

// MARK: - Main View

struct AlbumDetailView: View {
    @StateObject private var vm: AlbumDetailViewModel
    @State private var scrollY: CGFloat = 0
    // Defends against ghost taps after .navigationTransition(.zoom) pop:
    // SwiftUI may retain a hit-test layer for this view's play buttons even
    // after the user navigates back, causing the next tap on a different
    // card to fire this view's playPlaylist action.
    @State private var isViewVisible = false
    var onDismiss: (() -> Void)?

    /// Altura del hero. Se ata a `safeAreaTop + coverSize` (ambos estables
    /// desde el arranque, NO dependen de datos async como el motion artwork,
    /// así que la geometría inicial del ScrollView no se rompe). Como el
    /// contenido del hero está anclado abajo, fijar la altura en función de
    /// `safeAreaTop` garantiza que la cover quede SIEMPRE por debajo de la
    /// barra de navegación —botón atrás y menú— en cualquier dispositivo y
    /// largo de título. El espacio sobrante queda como aire sobre la cover
    /// (estilo Apple Music), no como hueco antes de la lista.
    private var heroHeight: CGFloat { safeAreaTop + coverSize + 270 }

    init(album: NavidromeAlbum, onDismiss: (() -> Void)? = nil) {
        _vm = StateObject(wrappedValue: AlbumDetailViewModel(album: album))
        self.onDismiss = onDismiss
    }

    // MARK: Scroll-derived values

    /// 0 at top → 1 when hero fully scrolled past
    private var scrollProgress: CGFloat { min(max(scrollY / heroHeight, 0), 1) }
    /// Hero content opacity
    private var heroOpacity: CGFloat { 1 - min(scrollProgress * 1.2, 0.92) }
    /// Sticky header opacity — fades in after 55% scroll
    private var stickyOpacity: CGFloat { min(max((scrollProgress - 0.55) / 0.25, 0), 1) }
    /// Stretchy header scale: proporcional al pull-down. Con anchor .bottom
    /// el header gana altura hacia arriba, llenando el área de rebound.
    /// Basado en `scrollY` (vía `onScrollGeometryChange`) en vez de
    /// `visualEffect`, que no re-evalúa de forma fiable al volver al top
    /// desde un scroll largo.
    private var stretchScale: CGFloat {
        let pullDown = max(0, -scrollY)
        return (heroHeight + pullDown) / heroHeight
    }

    private var isLight: Bool { vm.palette.isPrimaryLight }
    private var pageBg: Color { Color(vm.palette.pageBackgroundColor) }

    /// Tamaño del cover en el hero — escalado con el ancho de pantalla al
    /// estilo Apple Music: ~68% del width con cap a 300pt para no inflar
    /// en iPad. En iPhone 15/16 ≈ 267pt, en Pro Max ≈ 292pt, en SE ≈ 255pt.
    /// Más grande que antes (55%/260) para aprovechar los bordes y que la
    /// cover suba hacia la barra de navegación, como hace Apple Music.
    /// Usa `connectedScenes` porque `UIScreen.main` está deprecado en iOS 26.
    private var coverSize: CGFloat {
        let width: CGFloat = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 393
        return min(width * 0.68, 300)
    }

    /// Safe area top de la ventana actual. Necesario para extender el
    /// heroBackground HASTA el notch — el ScrollView con `.ignoresSafeArea`
    /// no propaga insets cero a sus children dentro del scroll content,
    /// lo que dejaba un gap visible bajo la status bar.
    private var safeAreaTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .safeAreaInsets.top ?? 47
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            // Full-screen background fills behind nav bar + content
            pageBg.ignoresSafeArea()

            // Scrollable content
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    heroSection
                    albumNotesSection
                    songListSection
                    Spacer(minLength: 120) // mini-player clearance
                }
                .frame(maxWidth: .infinity)
            }
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                scrollY = y
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(isLight ? .light : .dark, for: .navigationBar)
        .environment(\.colorScheme, isLight ? .light : .dark)
        .tint(isLight ? .accentColor : .white)
        .task {
            AppTheme.shared.overlayColorScheme = .dark
            await vm.load()
            AppTheme.shared.overlayColorScheme = isLight ? .light : .dark
        }
        .onChange(of: isLight) { _, light in
            AppTheme.shared.overlayColorScheme = light ? .light : .dark
        }
        .onAppear { isViewVisible = true }
        .onDisappear {
            isViewVisible = false
            AppTheme.shared.overlayColorScheme = nil
        }
        .toolbar {
            if onDismiss != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onDismiss?() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(isLight ? Color.accentColor : .white)
                    }
                }
            }
            ToolbarItem(placement: .principal) {
                Text(vm.displayAlbum.name)
                    .font(.headline)
                    .foregroundStyle(isLight ? Color.black : .white)
                    .lineLimit(1)
                    .opacity(stickyOpacity)
            }
            if !vm.songs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    toolbarMenu
                }
            }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            // Stretchy header + extensión al notch + heroFade hacia pageBg.
            //
            // Mecánica:
            //  - `frame(height: heroHeight + safeAreaTop)` da al backdrop
            //    el espacio para cubrir también el área del notch.
            //  - `.overlay(alignment: .bottom)` con heroFade dimensionado a
            //    `heroHeight * 0.55` se aplica ANTES del offset, así que el
            //    fade queda alineado al bottom del frame extendido y viaja
            //    con el view cuando se aplica el offset (se mantiene en su
            //    sitio relativo al bottom visual del hero, donde están los
            //    botones — exactamente como antes del notch fix).
            //  - `.offset(y: -safeAreaTop)` desplaza todo visualmente hacia
            //    arriba para cubrir el notch. El layout del ZStack sigue
            //    siendo `heroHeight` (frame externo), así que el flow del
            //    scroll content NO cambia.
            //  - `.scaleEffect(anchor: .bottom)` aplica el stretchy desde el
            //    bottom del view ya offseteado (y=heroHeight).
            heroBackground
                .frame(height: heroHeight + safeAreaTop)
                .overlay(alignment: .bottom) {
                    LinearGradient.heroFade(to: pageBg)
                        .frame(height: heroHeight * 0.55)
                        .allowsHitTesting(false)
                }
                .offset(y: -safeAreaTop)
                .scaleEffect(stretchScale, anchor: .bottom)

            heroContent
                .opacity(heroOpacity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
    }

    @ViewBuilder
    private var heroBackground: some View {
        // Prioridad de backdrop (Apple Music iOS 26):
        //  1. Motion artwork — vídeo edge-to-edge. Sin gradientes de color
        //     encima que lo tapen; el vídeo es la identidad visual del header.
        //     Solo un scrim oscuro en el tercio inferior para legibilidad
        //     del título/metadata sobre el clip.
        //  2. Paleta solid (covers planos tipo cream/blanco) — flat color.
        //  3. Resto — gradientes de paleta sobre blurred cover (comportamiento
        //     histórico cuando no hay motion).
        if let motionUrl = vm.animatedArtworkUrl {
            ZStack(alignment: .bottom) {
                // `videoOffsetY: 80` baja el centro del clip 40pt — Apple
                // Music compone la parte clave de la cover algo más abajo
                // del centro geométrico del header para dar respiro al
                // título y los botones. Sin gap visible: el layer se
                // extiende hacia abajo, recortado por `masksToBounds`.
                CanvasView(url: motionUrl, autoplay: true, videoOffsetY: 80)

                LinearGradient(
                    colors: [
                        Color.black.opacity(0),
                        Color.black.opacity(0.18),
                        Color.black.opacity(0.45)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 220)
                .allowsHitTesting(false)
            }
            .ignoresSafeArea(edges: .top)
        } else if vm.palette.isSolid {
            Color(vm.palette.primary)
                .ignoresSafeArea(edges: .top)
        } else {
            ZStack {
                // Gradient overlay at 140° (top-trailing → bottom-leading)
                LinearGradient(
                    colors: [
                        Color(vm.palette.primary).opacity(0.82),
                        Color(vm.palette.secondary).opacity(0.76)
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )

                // Dark scrim for legible text
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
            // Blurred cover backdrop tras los gradientes. `.background()`
            // evita que el contenido infle el layout del padre. El
            // `.clipped()` contiene el halo del blur al frame natural; el
            // stretchy header se aplica con `.scaleEffect` externo en el
            // chain del `heroSection` y no se ve afectado.
            .background {
                if let img = vm.coverImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 55)
                        .scaleEffect(1.25)
                } else {
                    Color(vm.palette.primary)
                }
            }
            .clipped()
            .ignoresSafeArea(edges: .top)
        }
    }

    private var heroContent: some View {
        VStack(spacing: 0) {
            if vm.animatedArtworkUrl == nil {
                // Sin motion: cover estática grande, anclada abajo (los botones
                // quedan sobre la lista). SOLO este spacer superior es flexible;
                // absorbe todo el sobrante, de modo que la cover queda por debajo
                // de la barra. El hueco cover↔título es FIJO: si fuera flexible,
                // SwiftUI repartiría el sobrante entre ambos spacers y la cover
                // subiría a media altura, solapando el botón atrás y el menú.
                Spacer(minLength: 40)

                // When the cover is solid + light (white, cream, warm pastels), drop the
                // shadow so the artwork blends seamlessly into the background.
                coverArtImage
                    .frame(width: coverSize, height: coverSize)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(
                        color: vm.palette.isSolid
                            ? .black.opacity(vm.palette.isPrimaryLight ? 0 : 0.15)
                            : .black.opacity(0.55),
                        radius: vm.palette.isSolid ? 8 : 22,
                        x: 0,
                        y: vm.palette.isSolid ? 2 : 8
                    )

                Spacer().frame(height: 14)   // hueco FIJO cover↔título
            } else {
                // Con motion: el vídeo es la identidad visual del header.
                // Empujamos título/botones al fondo del hero, sobre el scrim.
                Spacer(minLength: 0)
            }

            // Title + metadata — centered.
            // Con motion, forzamos blanco siempre: el vídeo de fondo puede
            // tener cualquier dominante de color y `isLight` (calculado desde
            // la cover estática) no es fiable sobre el clip.
            let titleColor: Color = vm.animatedArtworkUrl != nil
                ? .white
                : (isLight ? Color.black : .white)
            let badgeColor: Color = vm.animatedArtworkUrl != nil
                ? Color.white.opacity(0.75)
                : (isLight ? Color.black.opacity(0.45) : Color.white.opacity(0.75))

            VStack(alignment: .center, spacing: 5) {
                HStack(spacing: 8) {
                    Text(vm.displayAlbum.name)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(titleColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)

                    if vm.displayAlbum.isExplicit {
                        ExplicitBadge(color: badgeColor, size: 18)
                    }
                }

                metadataLine
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 20)

            // Play + shuffle buttons — centered. Más aire respecto al
            // songlist de debajo (estilo Apple Music iOS 26.4).
            playButtons
                .padding(.top, 18)
                .padding(.bottom, 44)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var coverArtImage: some View {
        if let img = vm.coverImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            // Placeholder while loading
            ZStack {
                Color(vm.palette.primary).opacity(0.4)
                Image(systemName: "music.note")
                    .font(.system(size: 52))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var metadataLine: some View {
        let textColor: Color = isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.75)
        let album = vm.displayAlbum
        var parts: [String] = [album.artist]
        if let year = album.year  { parts.append(String(year)) }
        if let genre = album.genre { parts.append(genre) }

        return Text(parts.joined(separator: " · "))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(textColor)
            .lineLimit(1)
    }

    private var playButtons: some View {
        // Estilo Apple Music iOS 26.4: play = pill que contrasta con el
        // fondo del hero (blanco sobre hero oscuro o vídeo, negro sobre
        // hero claro), texto en color de acento. Shuffle = círculo del
        // color de acento con icono blanco/negro según luminancia del accent.
        // Lógica centralizada en `AlbumPalette` (ver ColorExtractor.swift).
        let motionPresent = vm.animatedArtworkUrl != nil
        let playBg = Color(vm.palette.playButtonBackground(motionPresent: motionPresent))
        let playFg = Color(vm.palette.playButtonForeground(motionPresent: motionPresent))
        let shuffleBg = Color(vm.palette.shuffleButtonBackground(motionPresent: motionPresent))
        let shuffleFg = Color(vm.palette.shuffleButtonForeground(motionPresent: motionPresent))

        return HStack(spacing: 14) {
            Button {
                guard isViewVisible, !vm.songs.isEmpty else { return }
                PlayerService.shared.playPlaylist(vm.songs, contextUri: "album:\(vm.displayAlbum.id)", contextName: vm.displayAlbum.name)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text(L.play)
                        .fontWeight(.semibold)
                }
                .font(.system(size: 17))
                .foregroundStyle(playFg)
                .padding(.horizontal, 28)
                .padding(.vertical, 13)
                .background(playBg, in: Capsule())
            }

            Button {
                guard isViewVisible, !vm.songs.isEmpty else { return }
                PlayerService.shared.playPlaylist(vm.songs.shuffled(), contextUri: "album:\(vm.displayAlbum.id)", contextName: vm.displayAlbum.name)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(shuffleFg)
                    .frame(width: 48, height: 48)
                    .background(shuffleBg, in: Circle())
            }
        }
        .disabled(vm.isLoadingSongs)
    }

    // MARK: - Toolbar Menu

    @ViewBuilder
    private var toolbarMenu: some View {
        Menu {
            Button {
                DownloadManager.shared.downloadAlbum(
                    albumId: vm.displayAlbum.id,
                    title: vm.displayAlbum.name,
                    songs: vm.songs,
                    pin: false
                )
            } label: {
                Label(L.download, systemImage: "arrow.down.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isLight ? Color.black : .white)
        }
    }

    // MARK: - Song list

    private var recordLabelFooter: some View {
        let year = String(vm.displayAlbum.year ?? Calendar.current.component(.year, from: Date()))
        let labels = vm.recordLabels.map(\.name).joined(separator: ", ")
        return Text("© \(year) \(labels)")
            .font(.system(size: 12))
            .foregroundStyle(isLight ? Color.black.opacity(0.30) : Color.white.opacity(0.35))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
    }

    /// Línea "N canciones · M min" estilo Apple Music. Aparece debajo del
    /// tracklist y encima del `recordLabelFooter`. Se calcula desde `vm.songs`
    /// (no desde `displayAlbum.duration`) para que sea coherente con lo que el
    /// usuario realmente ve listado, incluso si Subsonic reporta una duración
    /// distinta a la suma de pistas tras filtros / extended editions.
    @ViewBuilder
    private var albumStatsLine: some View {
        if !vm.songs.isEmpty {
            let totalSeconds = vm.songs.reduce(0.0) { $0 + ($1.duration ?? 0) }
            let total = Int(totalSeconds)
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            let durationText: String = hours > 0
                ? "\(hours) h \(minutes) min"
                : "\(minutes) min"
            Text("\(L.songCount(vm.songs.count)) · \(durationText)")
                .font(.system(size: 12))
                .foregroundStyle(isLight ? Color.black.opacity(0.30) : Color.white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 16)
        }
    }

    // MARK: - Album notes

    /// Bio del álbum justo bajo el bloque de botones de reproducción, estilo
    /// Apple Music: 2 líneas + "MÁS" inline, expandible. Sin tarjeta, sin
    /// título "Acerca de". El divider que la separa del tracklist es
    /// `albumNotesSection`-local para que cuando no haya notas (album sin bio
    /// disponible) tampoco aparezca el divider y la transición hero → tracklist
    /// quede limpia.
    @ViewBuilder
    private var albumNotesSection: some View {
        let dividerColor: Color = isLight ? Color.black.opacity(0.15) : Color.white.opacity(0.15)
        let skeletonBlock: Color = isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.10)

        if vm.isLoadingNotes {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(skeletonBlock)
                    .frame(height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(skeletonBlock)
                    .frame(height: 14)
                    .frame(maxWidth: 240, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 18)
            Divider()
                .background(dividerColor)
                .padding(.horizontal, 16)
        } else if let notes = vm.albumNotes, !notes.isEmpty {
            ExpandableBio(
                text: cleanNotes(notes),
                pageBg: pageBg,
                textColor: isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.75),
                sheetTitle: vm.displayAlbum.name
            )
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 18)
            Divider()
                .background(dividerColor)
                .padding(.horizontal, 16)
        }
    }

    private func cleanNotes(_ html: String) -> String {
        var cleaned = html
        cleaned = cleaned.replacingOccurrences(
            of: "<a[^>]*>[^<]*Read more on Last\\.fm[^<]*</a>",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: "Read more on Last.fm", with: "")
        cleaned = cleaned.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        let entities = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">"]
        for (k, v) in entities { cleaned = cleaned.replacingOccurrences(of: k, with: v) }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Song list

    private var songListSection: some View {
        VStack(spacing: 0) {
            if vm.isLoadingSongs {
                SongListSkeleton(
                    count: max(vm.displayAlbum.songCount ?? 0, 8),
                    palette: vm.palette,
                    showCover: false,
                    showArtist: false
                )
            } else {
                // `albumArtist` activa el modo "solo featurings": el
                // artista de cada canción solo se renderiza si difiere del
                // titular del álbum o trae invitados (Drake feat. Snoop Dogg).
                SongListView(songs: vm.songs, palette: vm.palette, showAlbumInMenu: false, showArtist: false, contextUri: "album:\(vm.displayAlbum.id)", contextName: vm.displayAlbum.name, albumArtist: vm.displayAlbum.artist)

                albumStatsLine

                if !vm.recordLabels.isEmpty {
                    recordLabelFooter
                }
            }
        }
    }

}
