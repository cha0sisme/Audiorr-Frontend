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
    /// Color del borde de la cover — fondo del header SIN costura para covers
    /// isSolid (Apple Music). Solo se usa en el modo isSolid.
    @Published var headerBgColor: UIColor?
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
            self.headerBgColor = ColorExtractor.edgeColor(from: cached)
            // Palette from cache → colors appear WITH the zoom transition, zero delay
            if let id = album.coverArt, let p = PaletteCache.shared.palette(for: id) {
                self.palette = p
                self.paletteReady = true
            } else {
                // Cover en caché pero paleta no: extraer YA (síncrono, ~200px,
                // unos ms) para conocer `isSolid` desde el PRIMER frame. Sin
                // esto, el detalle arranca con la paleta por defecto (no-solid →
                // layout normal) y al resolver la extracción salta al layout
                // isSolid (el "expandirse" al entrar desde la card).
                let extracted = ColorExtractor.extract(from: cached)
                self.palette = extracted
                self.paletteReady = true
                if let id = album.coverArt { PaletteCache.shared.set(extracted, for: id) }
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
        let edge = await Task.detached(priority: .userInitiated) {
            ColorExtractor.edgeColor(from: image)
        }.value
        self.headerBgColor = edge
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

/// Propaga la altura medida del bloque de título del hero hacia AlbumDetailView.
private struct TitleBlockHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 52
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct AlbumDetailView: View {
    @StateObject private var vm: AlbumDetailViewModel
    @State private var scrollY: CGFloat = 0
    // Defends against ghost taps after .navigationTransition(.zoom) pop:
    // SwiftUI may retain a hit-test layer for this view's play buttons even
    // after the user navigates back, causing the next tap on a different
    // card to fire this view's playPlaylist action.
    @State private var isViewVisible = false
    /// Altura medida del bloque de título+metadata (para que heroHeight la
    /// incluya y los huecos del hero no dependan del nº de líneas del título).
    /// El default (~87) cubre el caso de 2 líneas, así que el primer frame nunca
    /// infraestima (sobra y se ajusta hacia abajo, nunca colisiona).
    @State private var titleBlockHeight: CGFloat = 87
    var onDismiss: (() -> Void)?

    /// Altura del hero = inset + cover + título (medido) + huecos fijos. Incluir
    /// la altura REAL del título (`titleBlockHeight`) hace que el hueco entre los
    /// botones y la lista sea constante sea cual sea el nº de líneas del título,
    /// manteniendo a la vez la cover anclada (inset fijo) bajo la barra.
    /// Prioridad de efectos (sin mezclar), como pidió el diseño:
    ///   1. animated artwork → MISMO recorte/resolución que NowPlaying: vídeo
    ///      full-width en el 62% superior de pantalla, centrado, fundido a fondo
    ///      y título/botones SUPERPUESTOS sobre el tercio inferior del hero, sobre
    ///      el fundido (motionHeroSection + motionTitleOverlay), estilo Apple Music.
    ///   2. isSolid (y SIN animated) → cover cuadrada full-screen + fondo del
    ///      color del borde (sin costura), título debajo.
    ///   3. normal → layout estándar (cover-tarjeta).
    /// `isSolidMode` solo es true en el caso 2; el animated SIEMPRE gana.
    private var isMotionMode: Bool { vm.animatedArtworkUrl != nil }
    private var isSolidMode: Bool { vm.animatedArtworkUrl == nil && vm.palette.isSolid }

    private var heroHeight: CGFloat {
        // Motion: el hero es el vídeo (62% de pantalla, igual que el backdrop de
        // NowPlaying) con el título/botones SUPERPUESTOS sobre su tercio inferior
        // (overlay, no flujo). La altura del hero es solo la del vídeo.
        if isMotionMode { return motionVideoHeight }
        // 189 = inset extra (88) + hueco cover↔título (20) + hueco info↔botones
        // (21) + alto del bloque de botones (~48) + hueco botones↔bio (12). El
        // frame contiene EXACTAMENTE el contenido, así que el Spacer final
        // descansa en sus 12pt y el botón de play nunca invade la bio. Los huecos
        // (21 y 12) igualan a los de isSolid (titleButtonsSection).
        return isSolidMode ? screenWidth : (safeAreaTop + coverSize + titleBlockHeight + 189)
    }

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

    /// En modo isSolid el fondo es el color del borde de la cover (sin costura);
    /// el resto usa el pageBackgroundColor procesado de la paleta.
    private var headerBgUIColor: UIColor { vm.headerBgColor ?? vm.palette.pageBackgroundColor }
    private var isLight: Bool {
        if isSolidMode {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            headerBgUIColor.getRed(&r, green: &g, blue: &b, alpha: nil)
            return (r * 0.299 + g * 0.587 + b * 0.114) > 0.5
        }
        return vm.palette.isPrimaryLight
    }
    /// Fondo del HERO/header — en isSolid es el color del borde de la cover (sin
    /// costura con la franja superior y el propio cover); en el resto, el
    /// pageBackgroundColor de la paleta.
    private var heroBgColor: Color {
        isSolidMode ? Color(headerBgUIColor) : Color(vm.palette.pageBackgroundColor)
    }

    /// Fondo del CUERPO (de la sección de título hacia abajo: título, bio,
    /// songlist). En isSolid se oscurece ~18% respecto al header para separar el
    /// cuerpo del hero —como el modo animado / Apple Music— SIN tocar el header.
    /// El oscurecido es moderado a propósito: `isLight` se calcula sobre el
    /// header y debe seguir siendo válido en el cuerpo (no cruzar el umbral de
    /// luminancia). En el resto coincide con el pageBackgroundColor.
    private var pageBg: Color {
        guard isSolidMode else { return Color(vm.palette.pageBackgroundColor) }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        headerBgUIColor.getRed(&r, green: &g, blue: &b, alpha: nil)
        // Un color (casi) blanco NO se oscurece: quedaría un gris sucio. Se deja
        // el cuerpo igual que el header. El oscurecido solo aporta separación en
        // covers oscuras/coloreadas/crema.
        let luminance = r * 0.299 + g * 0.587 + b * 0.114
        guard luminance < 0.86 else { return Color(headerBgUIColor) }
        let f: CGFloat = 0.82   // ~18% más oscuro que el header
        return Color(UIColor(red: r * f, green: g * f, blue: b * f, alpha: 1))
    }

    /// Tamaño del cover en el hero — escalado con el ancho de pantalla al
    /// estilo Apple Music: ~72% del width con cap a 320pt para no inflar
    /// en iPad. En iPhone 15/16 ≈ 283pt, en Pro Max ≈ 310pt, en SE ≈ 270pt.
    /// Usa `connectedScenes` porque `UIScreen.main` está deprecado en iOS 26.
    private var coverSize: CGFloat {
        return min(screenWidth * 0.72, 320)
    }

    /// Ancho de pantalla — usado por el cover cuadrado full-width del modo isSolid.
    private var screenWidth: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 393
    }

    /// Alto de pantalla — base para el alto del vídeo de motion.
    private var screenHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.height ?? 852
    }

    /// Alto del vídeo de motion: 62% de la pantalla, EXACTAMENTE el mismo frame
    /// (ancho × 0.62·alto) que el backdrop animado de NowPlaying, para que el
    /// recorte aspect-fill y el zoom coincidan pixel a pixel.
    private var motionVideoHeight: CGFloat { screenHeight * 0.62 }

    /// Fracción del alto del hero (medida desde el FONDO) a la que se ancla el
    /// borde inferior del bloque título/botones SUPERPUESTO en modo motion. El
    /// bloque flota sobre el tercio inferior del hero (zona del heroFade), no
    /// debajo del vídeo, eliminando el "hueco muerto" de los motion con el arte
    /// anclado arriba (p.ej. Beerbongs). Ajustable dentro de [0.10, 0.20] hasta
    /// la posición óptima en dispositivo. Subir el valor → el texto sube; bajarlo
    /// → el texto baja, más metido en el fundido.
    private let motionTextBottomFraction: CGFloat = 0.14

    /// Inset superior del cover en modo isSolid: arranca bajo la barra de
    /// navegación, con heroBgColor (color del borde) en la franja de arriba.
    private var coverTopInset: CGFloat { safeAreaTop + 48 }

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
                    // isSolid: título+botones DEBAJO del cover (flujo). En motion
                    // el bloque va SUPERPUESTO sobre el hero (overlay dentro de
                    // motionHeroSection), no en el flujo del VStack.
                    if isSolidMode { titleButtonsSection }
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

    @ViewBuilder
    private var heroSection: some View {
        if let motionUrl = vm.animatedArtworkUrl {
            motionHeroSection(url: motionUrl)
        } else if isSolidMode {
            solidHeroSection
        } else {
            standardHeroSection
        }
    }

    /// Motion (animated artwork): réplica EXACTA del backdrop de NowPlaying.
    /// Vídeo full-width en el 62% superior de la pantalla, centrado (offset 0 →
    /// mismo recorte/zoom aspect-fill), fundido al fondo con `heroFade`. El
    /// título/botones van DEBAJO (titleButtonsSection), sobre el fondo, igual que
    /// el viewer. Sin scrim sobre el vídeo: el título ya no se compone encima.
    private func motionHeroSection(url: URL) -> some View {
        ZStack(alignment: .top) {
            pageBg

            CanvasView(url: url, autoplay: true)
                .frame(width: screenWidth, height: heroHeight)
                .clipped()
                .overlay(alignment: .bottom) {
                    // Fundido del motion al color de página (mismo lenguaje que
                    // NowPlaying: heroFade a ~50% del alto del vídeo).
                    LinearGradient.heroFade(to: pageBg)
                        .frame(height: heroHeight * 0.5)
                        .allowsHitTesting(false)
                }
                .scaleEffect(stretchScale, anchor: .bottom)
        }
        .frame(width: screenWidth, height: heroHeight)
        // Título + metadata + botones SUPERPUESTOS sobre el tercio inferior del
        // hero (sobre el heroFade), no debajo del vídeo. FUERA del scaleEffect del
        // vídeo: el texto NO se deforma con el stretchy pull-down. Anclado al fondo
        // del hero con una fracción ajustable (motionTextBottomFraction).
        .overlay(alignment: .bottom) {
            motionTitleOverlay
                .padding(.bottom, heroHeight * motionTextBottomFraction)
        }
        .ignoresSafeArea(edges: .top)
    }

    /// isSolid: cover CUADRADA y completa, full-width, bajo la barra de
    /// navegación, sobre el fondo del color del borde (sin costura). El
    /// título/botones van DEBAJO (titleButtonsSection).
    private var solidHeroSection: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: coverTopInset)

            coverArtImage
                .frame(width: screenWidth, height: heroHeight)
                .clipped()
                .overlay(alignment: .bottom) {
                    // Fundido del borde inferior del cover hacia el fondo (color
                    // del borde). Curva heroFade (S suave) a ~22% del alto: lo
                    // bastante corto para no comerse la portada, pero con altura
                    // suficiente para que la curva NO se comprima y el resultado
                    // sea un fundido real, sin costura. A 14% la curva se
                    // aplastaba y dejaba un borde duro.
                    LinearGradient.heroFade(to: pageBg)
                        .frame(height: heroHeight * 0.22)
                        .allowsHitTesting(false)
                }
                .scaleEffect(stretchScale, anchor: .bottom)
        }
        .frame(maxWidth: .infinity)
        // El header conserva el color del borde (franja superior + detrás del
        // cover). La base de pantalla (pageBg) es el cuerpo más oscuro, así que
        // sin esto la franja superior se oscurecería y rompería la costura.
        .background(heroBgColor)
    }

    /// Variante de `titleButtonsSection` para modo motion: MISMO contenido
    /// (título + metadata + botones) compuesto como overlay sobre el tercio
    /// inferior del hero, no en el flujo del VStack. Sin el `padding(.top, -8)`
    /// ni el `.padding(.bottom, 12)` de isSolid (allí pegan el bloque al cover;
    /// aquí el anclaje vertical lo pone el caller con
    /// `padding(.bottom, heroHeight * motionTextBottomFraction)`). Recibe taps
    /// (botones); el heroFade queda por debajo con allowsHitTesting(false).
    private var motionTitleOverlay: some View {
        VStack(alignment: .center, spacing: 5) {
            HStack(spacing: 8) {
                Text(vm.displayAlbum.name)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(isLight ? Color.black : .white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                if vm.displayAlbum.isExplicit {
                    ExplicitBadge(color: isLight ? Color.black.opacity(0.45) : Color.white.opacity(0.75), size: 18)
                }
            }

            metadataLine

            playButtons
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    /// Título + metadata + botones DEBAJO del cover (solo modo isSolid), sobre
    /// el fondo del cuerpo (algo más oscuro que el header). Texto negro/blanco
    /// según la luminancia del header.
    private var titleButtonsSection: some View {
        VStack(alignment: .center, spacing: 5) {
            HStack(spacing: 8) {
                Text(vm.displayAlbum.name)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(isLight ? Color.black : .white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                if vm.displayAlbum.isExplicit {
                    ExplicitBadge(color: isLight ? Color.black.opacity(0.45) : Color.white.opacity(0.75), size: 18)
                }
            }

            metadataLine

            playButtons
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        // Todo el conjunto (título+info+botones) pegado al cover en isSolid. El
        // top negativo lo sube hacia la zona del fundido inferior del cover (que
        // ya está difuminada), sin costura. Mueve el bloque completo, no solo el
        // título.
        .padding(.top, -8)
        .padding(.bottom, 12)
    }

    private var standardHeroSection: some View {
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
        // Prioridad de backdrop (Apple Music iOS 26). El motion ya NO pasa por
        // aquí (lo maneja `motionHeroSection` con el recorte de NowPlaying); este
        // backdrop solo cubre los casos sin vídeo:
        //  1. Paleta solid (covers planos tipo cream/blanco) — flat color.
        //  2. Resto — gradientes de paleta sobre blurred cover (comportamiento
        //     histórico cuando no hay motion).
        if vm.palette.isSolid {
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
            // standardHeroSection solo se usa sin motion ni isSolid: cover JUSTO
            // por debajo de la barra de navegación.
            // CLAVE (medido en simulador): la barra ocupa ~44pt por debajo
            // del safe area (botones terminan en ~safeAreaTop+44 ≈ y106), y
            // la ScrollView con `ignoresSafeArea(.top)` arranca su contenido
            // con un origen global ~32pt POR ENCIMA del top de pantalla, así
            // que la cover acaba en `inset − 32`. Con inset safeAreaTop+88 la
            // cover queda en ~y118: justo debajo de los botones, sin solapar.
            Spacer().frame(height: safeAreaTop + 88)

            // When the cover is solid + light (white, cream, warm pastels), drop the
            // shadow so the artwork blends seamlessly into the background.
            coverArtImage
                .frame(width: coverSize, height: coverSize)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                // Sombra estilo Apple Music (iOS 26.4): dos capas — una ambiental
                // ancha y muy tenue + una de contacto sutil — en lugar de una
                // sombra única y oscura. En covers sólidas se reduce; en sólidas
                // claras se elimina para que se funda con el fondo.
                .shadow(
                    color: vm.palette.isSolid
                        ? .black.opacity(vm.palette.isPrimaryLight ? 0 : 0.10)
                        : .black.opacity(0.20),
                    radius: vm.palette.isSolid ? 6 : 28,
                    x: 0,
                    y: vm.palette.isSolid ? 2 : 13
                )
                .shadow(
                    color: vm.palette.isSolid ? .clear : .black.opacity(0.10),
                    radius: vm.palette.isSolid ? 0 : 7,
                    x: 0,
                    y: vm.palette.isSolid ? 0 : 4
                )

            Spacer().frame(height: 20)   // hueco FIJO cover↔título (= resto)

            // Title + metadata — centered. Color según luminancia (isLight).
            let titleColor: Color = isLight ? Color.black : .white
            let badgeColor: Color = isLight
                ? Color.black.opacity(0.45)
                : Color.white.opacity(0.75)

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
            // Altura natural del título (mismo bloque que isSolid: título a
            // altura natural + metadata, spacing 5). La medimos para que
            // heroHeight la incluya; el hueco inferior es fijo (Spacer minLength
            // 12) y la constante de heroHeight ya contiene exactamente el
            // contenido, así que el botón de play no invade la bio.
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 20)
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: TitleBlockHeightKey.self, value: g.size.height)
                }
            )

            // Play + shuffle buttons. Hueco info↔botones = 21pt para igualar
            // isSolid (allí: spacing 5 del VStack + padding.top 16 = 21).
            playButtons
                .padding(.top, 21)

            // Hueco FIJO botones↔bio = 12pt para igualar isSolid (allí es el
            // padding.bottom 12 de titleButtonsSection). heroHeight está
            // calculado para que este spacer descanse exactamente en 12.
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity)
        .onPreferenceChange(TitleBlockHeightKey.self) { titleBlockHeight = $0 }
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
