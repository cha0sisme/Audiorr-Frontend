import SwiftUI

// MARK: - View Model

@MainActor
final class ArtistDetailViewModel: ObservableObject {
    @Published var artist: NavidromeArtist
    @Published var albums: [NavidromeAlbum] = []
    @Published var isLoading = true
    @Published var avatarImage: UIImage?
    @Published var palette: AlbumPalette = .default

    private let api = NavidromeService.shared

    init(artist: NavidromeArtist) {
        self.artist = artist
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        // Fetch albums and avatar concurrently
        async let albumsTask  = api.getArtistDetail(artistId: artist.id)
        async let avatarTask  = fetchAvatar()

        if let (ar, albums) = try? await albumsTask {
            // Newest first, then alphabetical
            self.albums = albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
            if let ar { self.artist = ar }
        }

        if let img = await avatarTask {
            self.avatarImage = img
            let extracted = await Task.detached(priority: .userInitiated) {
                ColorExtractor.extract(from: img)
            }.value
            self.palette = extracted
        }
    }

    private func fetchAvatar() async -> UIImage? {
        guard let avatarURL = await api.artistAvatarURL(artistId: artist.id) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: avatarURL) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - Main View

struct ArtistDetailView: View {
    @StateObject private var vm: ArtistDetailViewModel
    @State private var scrollY: CGFloat = 0

    private let heroHeight: CGFloat = 300

    init(artist: NavidromeArtist) {
        _vm = StateObject(wrappedValue: ArtistDetailViewModel(artist: artist))
    }

    private var scrollProgress: CGFloat  { min(max(scrollY / heroHeight, 0), 1) }
    private var heroOpacity: CGFloat     { 1 - min(scrollProgress * 1.3, 0.92) }
    private var stickyOpacity: CGFloat   { min(max((scrollProgress - 0.50) / 0.30, 0), 1) }
    private var overscrollScale: CGFloat { 1 + max(0, -scrollY) / 900 }

    private var isLight: Bool { vm.palette.isPrimaryLight }
    private var pageBg: Color { Color(vm.palette.pageBackgroundColor) }

    // Deterministic color from artist name (fallback when no avatar)
    private var nameColor: Color {
        let hash = vm.artist.name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 360 }
        return Color(hue: Double(hash) / 360.0, saturation: 0.55, brightness: 0.40)
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            pageBg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    heroSection
                    discographySection
                    Spacer(minLength: 120)
                }
            }
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                scrollY = y
            }

            stickyHeader
                .opacity(stickyOpacity)
                .animation(.linear(duration: 0.15), value: stickyOpacity)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(isLight ? .accentColor : .white)
        .navigationDestination(for: NavidromeAlbum.self) { album in
            AlbumDetailView(album: album)
        }
        .task { await vm.load() }
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            heroBackground
                .scaleEffect(overscrollScale, anchor: .top)
                .frame(height: heroHeight)
                .mask(alignment: .top) {
                    LinearGradient(
                        stops: [
                            .init(color: .black,               location: 0.00),
                            .init(color: .black,               location: 0.55),
                            .init(color: .black.opacity(0.80), location: 0.78),
                            .init(color: .black.opacity(0.30), location: 0.92),
                            .init(color: .clear,               location: 1.00)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .clipped()

            heroContent
                .opacity(heroOpacity)
        }
        .frame(height: heroHeight)
    }

    @ViewBuilder
    private var heroBackground: some View {
        if let img = vm.avatarImage {
            ZStack {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 50)
                    .scaleEffect(1.3)
                    .clipped()

                LinearGradient(
                    colors: [
                        Color(vm.palette.primary).opacity(0.80),
                        Color(vm.palette.secondary).opacity(0.72)
                    ],
                    startPoint: .topTrailing, endPoint: .bottomLeading
                )

                Color.black.opacity(0.25)
            }
            .ignoresSafeArea(edges: .top)
        } else {
            ZStack {
                LinearGradient(
                    colors: [nameColor.opacity(0.9), nameColor.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Color.black.opacity(0.20)
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    private var heroContent: some View {
        VStack(spacing: 0) {
            Spacer()

            // Circular avatar or initial placeholder
            avatarView
                .shadow(color: .black.opacity(0.45), radius: 18, y: 6)

            Spacer(minLength: 14)

            VStack(spacing: 4) {
                Text(vm.artist.name)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                if let count = vm.artist.albumCount, count > 0 {
                    Text("\(count) álbumes")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        if let img = vm.avatarImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 130, height: 130)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(nameColor.opacity(0.35))
                .frame(width: 130, height: 130)
                .overlay(
                    Text(String(vm.artist.name.prefix(1)).uppercased())
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                )
        }
    }

    // MARK: - Discography

    private let gridColumns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    private var discographySection: some View {
        Group {
            if vm.isLoading {
                ProgressView()
                    .tint(isLight ? .secondary : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
            } else if vm.albums.isEmpty {
                Text("Sin álbumes")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Discografía")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(isLight ? Color.primary : .white)
                        .padding(.horizontal, 16)
                        .padding(.top, 20)

                    LazyVGrid(columns: gridColumns, spacing: 20) {
                        ForEach(vm.albums) { album in
                            NavigationLink(value: album) {
                                AlbumGridCell(album: album, isLight: isLight)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    // MARK: - Sticky header

    private var stickyHeader: some View {
        HStack(spacing: 12) {
            avatarMini
            Text(vm.artist.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isLight ? Color.primary : .white)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .padding(.top, 48)
        .background(
            Color(vm.palette.stickyBgColor).opacity(0.92)
                .background(.ultraThinMaterial)
                .ignoresSafeArea(edges: .top)
        )
    }

    @ViewBuilder
    private var avatarMini: some View {
        if let img = vm.avatarImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 30, height: 30)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(nameColor.opacity(0.5))
                .frame(width: 30, height: 30)
                .overlay(
                    Text(String(vm.artist.name.prefix(1)).uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
    }
}

// MARK: - Album grid cell

private struct AlbumGridCell: View {
    let album: NavidromeAlbum
    let isLight: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            AsyncImage(url: NavidromeService.shared.coverURL(id: album.coverArt, size: 300)) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default:
                    ZStack {
                        Color(.tertiarySystemFill)
                        Image(systemName: "music.note")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

            Text(album.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isLight ? Color.primary : .white)
                .lineLimit(2)

            if let year = album.year {
                Text(String(year))
                    .font(.caption)
                    .foregroundStyle(isLight ? Color.secondary : Color.white.opacity(0.55))
            }
        }
    }
}
