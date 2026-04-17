import SwiftUI

// MARK: - View Model

@MainActor
final class ArtistsViewModel: ObservableObject {
    @Published var allArtists: [NavidromeArtist] = []
    @Published var featuredArtists: [NavidromeArtist] = []
    @Published var recentArtists: [NavidromeArtist] = []
    @Published var genreArtists: [NavidromeArtist] = []
    @Published var currentGenre: String = ""
    @Published var isLoading = true
    @Published var showAllArtists = false

    private let api = NavidromeService.shared

    var isConfigured: Bool { api.isConfigured }

    /// Grouped alphabetically for the "Explorar todos" section.
    var groupedByLetter: [(letter: String, artists: [NavidromeArtist])] {
        var groups: [String: [NavidromeArtist]] = [:]
        for artist in allArtists {
            let first = artist.name.first.map { String($0).uppercased() } ?? "#"
            let letter = first.range(of: "[A-Z0-9]", options: .regularExpression) != nil ? first : "#"
            groups[letter, default: []].append(artist)
        }
        return groups.sorted { a, b in
            if a.key == "#" { return false }
            if b.key == "#" { return true }
            return a.key < b.key
        }.map { (letter: $0.key, artists: $0.value) }
    }

    var letters: [String] { groupedByLetter.map(\.letter) }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        api.reloadCredentials()
        guard api.isConfigured else { return }

        allArtists = await api.getArtists()

        async let featuredTask: Void = loadFeatured()
        async let recentTask: Void = loadRecent()
        async let genreTask: Void = loadRandomGenre()

        _ = await (featuredTask, recentTask, genreTask)
    }

    // MARK: Featured (most frequent albums → top artists)

    private func loadFeatured() async {
        let frequentAlbums = await api.getAlbumList(type: "frequent", size: 50)
        var countByName: [String: Int] = [:]
        for album in frequentAlbums {
            countByName[album.artist, default: 0] += 1
        }

        let topNames = countByName.sorted { $0.value > $1.value }
            .prefix(12)
            .map(\.key)

        let artistLookup = Dictionary(uniqueKeysWithValues: allArtists.map { ($0.name, $0) })
        featuredArtists = topNames.compactMap { artistLookup[$0] }
    }

    // MARK: Recent releases → artists

    private func loadRecent() async {
        let latestAlbums = await api.getAlbumList(type: "newest", size: 30)
        var seen = Set<String>()
        var result: [NavidromeArtist] = []
        let lookup = Dictionary(uniqueKeysWithValues: allArtists.map { ($0.name, $0) })

        for album in latestAlbums {
            if !seen.contains(album.artist), let artist = lookup[album.artist] {
                seen.insert(album.artist)
                result.append(artist)
                if result.count >= 12 { break }
            }
        }
        recentArtists = result
    }

    // MARK: Random genre

    private func loadRandomGenre() async {
        let albums = await api.getAlbumList(type: "newest", size: 100)
        var genres = Set<String>()
        for album in albums {
            if let genre = album.genre {
                for g in genre.split(separator: ",") {
                    let trimmed = g.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { genres.insert(trimmed) }
                }
            }
        }

        let genreList = Array(genres).filter { $0 != currentGenre }
        guard !genreList.isEmpty else { return }
        let picked = genreList.randomElement()!

        currentGenre = picked
        await loadGenreArtists(genre: picked)
    }

    func changeGenre() async {
        await loadRandomGenre()
    }

    private func loadGenreArtists(genre: String) async {
        let albums = await api.getAlbumList(type: "byGenre", size: 50, genre: genre)
        var seen = Set<String>()
        var result: [NavidromeArtist] = []
        let lookup = Dictionary(uniqueKeysWithValues: allArtists.map { ($0.name, $0) })

        for album in albums {
            if !seen.contains(album.artist), let artist = lookup[album.artist] {
                seen.insert(album.artist)
                result.append(artist)
                if result.count >= 12 { break }
            }
        }
        genreArtists = result
    }
}

// MARK: - ArtistsView

struct ArtistsView: View {
    @StateObject private var vm = ArtistsViewModel()
    @State private var showSettings = false
    @State private var scrollY: CGFloat = 0

    private let collapseThreshold: CGFloat = 44

    private var stickyOpacity: CGFloat {
        min(max((scrollY - collapseThreshold * 0.4) / (collapseThreshold * 0.6), 0), 1)
    }
    private var largeTitleOpacity: CGFloat {
        1 - min(max(scrollY / collapseThreshold, 0), 1)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        largeHeader
                        content(proxy: proxy)
                    }
                }
                .ignoresSafeArea(edges: .top)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                    scrollY = y
                }
            }
            .background(Color(.systemBackground))
            .toolbarBackground(stickyOpacity > 0.5 ? .visible : .hidden, for: .navigationBar)
            .task { await vm.load() }
            .refreshable { await vm.load() }
            .navigationDestination(for: NavidromeArtist.self) { artist in
                ArtistDetailView(artist: artist)
            }
            .navigationDestination(for: NavidromeAlbum.self) { album in
                AlbumDetailView(album: album)
            }
            .navigationDestination(for: NavidromePlaylist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
            .navigationDestination(for: SeeAllDestination.self) { dest in
                SeeAllGridView(destination: dest)
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Artistas")
                        .font(.headline)
                        .lineLimit(1)
                        .opacity(stickyOpacity)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .opacity(stickyOpacity)
                }
            }
        }
    }

    // MARK: - Large title header

    private var largeHeader: some View {
        HStack(alignment: .bottom) {
            Text("Artistas")
                .font(.system(size: 34, weight: .bold))
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .padding(.top, UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 59)
        .opacity(largeTitleOpacity)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(proxy: ScrollViewProxy) -> some View {
        if vm.isLoading {
            VStack(spacing: 16) {
                ProgressView()
                Text("Cargando artistas...")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        } else if !vm.isConfigured {
            notConfiguredView
        } else if vm.allArtists.isEmpty {
            ContentUnavailableView(
                "Sin artistas",
                systemImage: "person.2",
                description: Text("No se encontraron artistas en tu servidor.")
            )
            .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                featuredSection
                recentSection
                genreSection
                exploreAllSection(proxy: proxy)
            }
            .padding(.bottom, 100)
        }
    }

    // MARK: - Not configured

    private var notConfiguredView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "music.note.house")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("Sin servidor configurado")
                    .font(.title3.bold())
                Text("Conecta tu servidor de Navidrome para ver tus artistas.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Conectar a Navidrome") { showSettings = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Mas escuchados (horizontal scroll, Apple Music style)

    @ViewBuilder
    private var featuredSection: some View {
        if !vm.featuredArtists.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Mas escuchados")
                    .padding(.bottom, 14)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(vm.featuredArtists) { artist in
                            NavigationLink(value: artist) {
                                ArtistCardView(artist: artist, size: 140)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 32)
            }
        }
    }

    // MARK: - Nuevos descubrimientos (horizontal scroll)

    @ViewBuilder
    private var recentSection: some View {
        if !vm.recentArtists.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Novedades")
                    .padding(.bottom, 14)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(vm.recentArtists) { artist in
                            NavigationLink(value: artist) {
                                ArtistCardView(artist: artist, size: 140)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 32)
            }
        }
    }

    // MARK: - Genre section (horizontal scroll + shuffle button)

    @ViewBuilder
    private var genreSection: some View {
        if !vm.genreArtists.isEmpty && !vm.currentGenre.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    sectionHeader(vm.currentGenre)
                    Spacer()
                    Button {
                        Task { await vm.changeGenre() }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 14)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(vm.genreArtists) { artist in
                            NavigationLink(value: artist) {
                                ArtistCardView(artist: artist, size: 140)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 32)
            }
        }
    }

    // MARK: - Explorar todos (list-style, Apple Music A-Z)

    @ViewBuilder
    private func exploreAllSection(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section divider
            Rectangle()
                .fill(Color(.separator).opacity(0.3))
                .frame(height: 1)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    vm.showAllArtists.toggle()
                }
            } label: {
                HStack(spacing: 0) {
                    Text("Todos los artistas")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.primary)
                    Text("  \(vm.allArtists.count)")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(vm.showAllArtists ? 90 : 0))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            if vm.showAllArtists {
                // Alphabet scrubber
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(vm.letters, id: \.self) { letter in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(letter, anchor: .top)
                                }
                            } label: {
                                Text(letter)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.tint)
                                    .frame(width: 28, height: 28)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 8)

                // A-Z list
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(vm.groupedByLetter, id: \.letter) { group in
                        Section {
                            ForEach(group.artists) { artist in
                                NavigationLink(value: artist) {
                                    ArtistRowCell(artist: artist)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text(group.letter)
                                .id(group.letter)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.bar)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Section header (Apple Music style)

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 22, weight: .bold))
            .padding(.horizontal, 16)
    }
}

// MARK: - Artist Row Cell (A-Z list — Apple Music style)

private struct ArtistRowCell: View {
    let artist: NavidromeArtist
    @State private var avatarImage: UIImage?
    @State private var didFinishLoading = false

    private let thumbSize: CGFloat = 48

    private var nameColor: Color {
        let hash = artist.name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 360 }
        return Color(hue: Double(hash) / 360.0, saturation: 0.45, brightness: 0.50)
    }

    var body: some View {
        HStack(spacing: 14) {
            // Circular thumbnail
            ZStack {
                if let img = avatarImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if didFinishLoading {
                    nameColor.opacity(0.20)
                        .overlay(
                            Text(String(artist.name.prefix(1)).uppercased())
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(nameColor)
                        )
                        .transition(.opacity)
                } else {
                    Color(.systemGray5)
                        .overlay(
                            Color(.systemGray4)
                                .phaseAnimator([false, true]) { content, phase in
                                    content.opacity(phase ? 0.6 : 0.3)
                                } animation: { _ in .easeInOut(duration: 0.9) }
                        )
                }
            }
            .frame(width: thumbSize, height: thumbSize)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .task(id: artist.id) {
            if let cached = ArtistImageCache.shared.image(for: artist.id) {
                avatarImage = cached
                didFinishLoading = true
                return
            }
            guard let url = await NavidromeService.shared.artistAvatarURL(artistId: artist.id) else {
                withAnimation(.easeOut(duration: 0.25)) { didFinishLoading = true }
                return
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else {
                withAnimation(.easeOut(duration: 0.25)) { didFinishLoading = true }
                return
            }
            ArtistImageCache.shared.setImage(img, for: artist.id)
            withAnimation(.easeOut(duration: 0.25)) {
                avatarImage = img
                didFinishLoading = true
            }
        }
    }
}
