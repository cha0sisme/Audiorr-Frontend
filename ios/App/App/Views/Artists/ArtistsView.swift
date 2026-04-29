import SwiftUI

// MARK: - View Model

@MainActor
final class ArtistsViewModel: ObservableObject {
    static let shared = ArtistsViewModel()

    @Published var allArtists: [NavidromeArtist] = []
    @Published var featuredArtists: [NavidromeArtist] = []
    @Published var recentArtists: [NavidromeArtist] = []
    @Published var genreArtists: [NavidromeArtist] = []
    @Published var currentGenre: String = ""
    @Published var isLoading = true

    private let api = NavidromeService.shared
    private var lastLoadedAt: Date?
    private let cacheTTL: TimeInterval = 120
    private var isChangingGenre = false
    /// Recent picks to avoid cycling between the same 2-3 genres.
    private var recentGenreHistory: [String] = []
    private let genreHistoryDepth = 3

    var isConfigured: Bool { api.isConfigured }

    /// Tolerates duplicate artist names by keeping the first one seen.
    /// Subsonic libraries can have multiple artists sharing a name; using
    /// `Dictionary(uniqueKeysWithValues:)` here would TRAP on the duplicate.
    private func artistLookupByName() -> [String: NavidromeArtist] {
        Dictionary(allArtists.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Grouped alphabetically for the "Explorar todos" section.
    @Published private(set) var groupedByLetter: [(letter: String, artists: [NavidromeArtist])] = []
    @Published private(set) var letters: [String] = []

    private func rebuildGroupedByLetter() {
        var groups: [String: [NavidromeArtist]] = [:]
        for artist in allArtists {
            let first = artist.name.first.map { String($0).uppercased() } ?? "#"
            let letter = first.range(of: "[A-Z0-9]", options: .regularExpression) != nil ? first : "#"
            groups[letter, default: []].append(artist)
        }
        groupedByLetter = groups.sorted { a, b in
            if a.key == "#" { return false }
            if b.key == "#" { return true }
            return a.key < b.key
        }.map { (letter: $0.key, artists: $0.value) }
        letters = groupedByLetter.map(\.letter)
    }

    func loadIfNeeded() async {
        if let last = lastLoadedAt, Date().timeIntervalSince(last) < cacheTTL, !allArtists.isEmpty {
            return
        }
        await load()
    }

    private var hasData: Bool { !allArtists.isEmpty }

    func load() async {
        // Only show skeleton on first load — subsequent refreshes keep existing data visible
        if !hasData { isLoading = true }
        defer {
            isLoading = false
            lastLoadedAt = Date()
        }

        api.reloadCredentials()
        guard api.isConfigured else { return }

        allArtists = await api.getArtists()
        rebuildGroupedByLetter()

        async let featuredTask: Void = loadFeatured()
        async let recentTask: Void = loadRecent()
        async let genreTask: Void = loadRandomGenre()

        _ = await (featuredTask, recentTask, genreTask)

        // Pre-warm avatar URLs + images for visible artists in background
        prefetchAvatars(for: featuredArtists + recentArtists + genreArtists)
    }

    /// Pre-fetch avatar URLs and images in background so cards render instantly.
    private func prefetchAvatars(for artists: [NavidromeArtist]) {
        let unique = Array(Set(artists.map(\.id)))
            .filter { ArtistImageCache.shared.image(for: $0) == nil }
        guard !unique.isEmpty else { return }

        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for artistId in unique {
                    group.addTask {
                        // 1. Resolve avatar URL (caches in NavidromeService)
                        guard let url = await NavidromeService.shared.artistAvatarURL(artistId: artistId) else { return }
                        // 2. Download image (caches in ArtistImageCache disk + RAM)
                        _ = await ArtistImageCache.shared.loadImage(artistId: artistId, url: url)
                    }
                }
            }
        }
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

        let artistLookup = artistLookupByName()
        featuredArtists = topNames.compactMap { artistLookup[$0] }
    }

    // MARK: Recent releases → artists

    private func loadRecent() async {
        let latestAlbums = await api.getAlbumList(type: "newest", size: 30)
        var seen = Set<String>()
        var result: [NavidromeArtist] = []
        let lookup = artistLookupByName()

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

    /// Pools genres from multiple album-list types so users with libraries that
    /// have a small "newest" cohort still see varied genres. Also keeps a short
    /// history to avoid cycling between the same two genres on rapid refresh.
    private func loadRandomGenre() async {
        // Pool from three sources concurrently for max variety.
        async let newest = api.getAlbumList(type: "newest", size: 100)
        async let frequent = api.getAlbumList(type: "frequent", size: 100)
        async let random = api.getAlbumList(type: "random", size: 100)
        let (n, f, r) = await (newest, frequent, random)
        let pool = n + f + r

        var genres = Set<String>()
        for album in pool {
            guard let genre = album.genre else { continue }
            for g in genre.split(separator: ",") {
                let trimmed = g.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { genres.insert(trimmed) }
            }
        }

        let blocked = Set([currentGenre] + recentGenreHistory)
        var candidates = Array(genres).filter { !blocked.contains($0) }

        // Fallback: if every known genre is in the recent history (very small
        // libraries), allow any except currentGenre.
        if candidates.isEmpty {
            candidates = Array(genres).filter { $0 != currentGenre }
        }
        guard let picked = candidates.randomElement() else { return }

        currentGenre = picked
        recentGenreHistory.append(picked)
        if recentGenreHistory.count > genreHistoryDepth {
            recentGenreHistory.removeFirst()
        }
        await loadGenreArtists(genre: picked)
    }

    /// Triggered by the shuffle button. Coalesces rapid double-taps so the
    /// previous fetch finishes before a new one starts — prevents racy state
    /// where currentGenre and genreArtists end up mismatched.
    func changeGenre() async {
        guard !isChangingGenre else { return }
        isChangingGenre = true
        defer { isChangingGenre = false }
        await loadRandomGenre()
    }

    private func loadGenreArtists(genre: String) async {
        let albums = await api.getAlbumList(type: "byGenre", size: 50, genre: genre)
        var seen = Set<String>()
        var result: [NavidromeArtist] = []
        let lookup = artistLookupByName()

        for album in albums {
            if !seen.contains(album.artist), let artist = lookup[album.artist] {
                seen.insert(album.artist)
                result.append(artist)
                if result.count >= 12 { break }
            }
        }
        // Don't blank the section on a transient empty fetch — keep the last
        // good list so the section doesn't disappear after a refresh hiccup.
        if !result.isEmpty {
            genreArtists = result
        }
    }
}

// MARK: - ArtistsView

struct ArtistsView: View {
    @ObservedObject private var vm = ArtistsViewModel.shared
    @State private var showSettings = false
    @Namespace private var heroNS

    var body: some View {
        NavigationStack {
            ScrollView {
                content
            }
            .background(Color(.systemBackground))
            .navigationTitle(L.artists)
            .navigationBarTitleDisplayMode(.large)
            .task { await vm.loadIfNeeded() }
            .refreshable { await vm.load() }
            .navigationDestination(for: NavidromeArtist.self) {
                ArtistDetailView(artist: $0, heroNamespace: heroNS)
                    .navigationTransition(.zoom(sourceID: $0.id, in: heroNS))
            }
            .navigationDestination(for: NavidromeAlbum.self) {
                AlbumDetailView(album: $0)
                    .navigationTransition(.zoom(sourceID: $0.id, in: heroNS))
            }
            .navigationDestination(for: NavidromePlaylist.self) {
                PlaylistDetailView(playlist: $0)
                    .navigationTransition(.zoom(sourceID: $0.id, in: heroNS))
            }
            .navigationDestination(for: SeeAllDestination.self) { SeeAllGridView(destination: $0) }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.isLoading {
            loadingSkeleton
        } else if !vm.isConfigured {
            notConfiguredView
        } else if vm.allArtists.isEmpty {
            if !NetworkMonitor.shared.isConnected {
                ContentUnavailableView(
                    L.noConnection,
                    systemImage: "wifi.slash",
                    description: Text(L.connectOfflineArtists)
                )
                .padding(.top, 40)
            } else {
                ContentUnavailableView(
                    L.noArtistsFound,
                    systemImage: "person.2",
                    description: Text(L.noArtistsFound)
                )
                .padding(.top, 40)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                featuredSection
                recentSection
                genreSection
                allArtistsLink
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
                Text(L.noServerConfigured)
                    .font(.title3.bold())
                Text(L.connectNavidromeArtists)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(L.connectToNavidrome) { showSettings = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Más escuchados (horizontal scroll, Apple Music style)

    @ViewBuilder
    private var featuredSection: some View {
        if !vm.featuredArtists.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(L.mostListened)
                    .padding(.bottom, 14)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(vm.featuredArtists) { artist in
                            NavigationLink(value: artist) {
                                ArtistCardView(artist: artist, size: 140, showStats: true, heroNamespace: heroNS)
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
                sectionHeader(L.recent)
                    .padding(.bottom, 14)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(vm.recentArtists) { artist in
                            NavigationLink(value: artist) {
                                ArtistCardView(artist: artist, size: 140, showStats: true, heroNamespace: heroNS)
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
                                ArtistCardView(artist: artist, size: 140, showStats: true, heroNamespace: heroNS)
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

    // MARK: - All artists entry (navigates to AllArtistsView)

    private var allArtistsLink: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color(.separator).opacity(0.3))
                .frame(height: 1)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

            NavigationLink {
                AllArtistsView(vm: vm, heroNamespace: heroNS)
            } label: {
                HStack(spacing: 0) {
                    Text(L.allArtists)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.primary)
                    Text("  \(vm.allArtists.count)")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Loading skeleton

    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Two horizontal sections mimicking featured / recent
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 180, height: 22)
                        .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(0..<5, id: \.self) { _ in
                                VStack(spacing: 8) {
                                    Circle()
                                        .fill(Color(.tertiarySystemFill))
                                        .frame(width: 140, height: 140)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color(.tertiarySystemFill))
                                        .frame(width: 100, height: 14)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }

            // List rows mimicking the A-Z section
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 200, height: 22)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                ForEach(0..<6, id: \.self) { _ in
                    HStack(spacing: 14) {
                        Circle()
                            .fill(Color(.tertiarySystemFill))
                            .frame(width: 48, height: 48)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.tertiarySystemFill))
                            .frame(width: 140, height: 16)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
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
                withAnimation(Anim.small) { didFinishLoading = true }
                return
            }
            if let img = await ArtistImageCache.shared.loadImage(artistId: artist.id, url: url) {
                withAnimation(Anim.small) {
                    avatarImage = img
                    didFinishLoading = true
                }
            } else {
                withAnimation(Anim.small) { didFinishLoading = true }
            }
        }
    }
}

// MARK: - All Artists Page (A-Z with lateral alphabet)

/// Pushed from ArtistsView's "Ver todos los artistas" link.
/// Apple Music–style: pinned section headers + a draggable lateral alphabet
/// on the right that scrubs through letters with haptics + a floating preview.
struct AllArtistsView: View {
    @ObservedObject var vm: ArtistsViewModel
    var heroNamespace: Namespace.ID

    @State private var activeLetter: String?

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(vm.groupedByLetter, id: \.letter) { group in
                            Section {
                                // Scroll anchor — see ArtistsView's earlier note:
                                // .id() on a pinned header is unreliable, so we
                                // place the anchor inside the section content.
                                Color.clear
                                    .frame(height: 0)
                                    .id(group.letter)

                                ForEach(group.artists) { artist in
                                    NavigationLink(value: artist) {
                                        ArtistRowCell(artist: artist)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                Text(group.letter)
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.bar)
                            }
                        }
                    }
                    .padding(.bottom, 100)
                }

                // Lateral alphabet — only when there are enough letters to be useful
                if vm.letters.count >= 4 {
                    AlphabetSidebar(letters: vm.letters, activeLetter: $activeLetter) { letter in
                        proxy.scrollTo(letter, anchor: .top)
                    }
                    .padding(.trailing, 4)
                }
            }
            .overlay {
                // Floating letter preview while scrubbing
                if let active = activeLetter {
                    Text(active)
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .frame(width: 120, height: 120)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(Anim.small, value: activeLetter)
        }
        .background(Color(.systemBackground))
        .navigationTitle(L.allArtists)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Lateral alphabet sidebar (Apple Music / Contacts style)

/// Thin vertical strip of letters on the right edge. Tap or drag to scrub
/// through sections. Calls `onLetterChange` whenever the active letter shifts,
/// so the host can `proxy.scrollTo(letter, anchor: .top)` and show a preview
/// bubble. Plays a light haptic on each letter change.
private struct AlphabetSidebar: View {
    let letters: [String]
    @Binding var activeLetter: String?
    var onLetterChange: (String) -> Void

    private let letterHeight: CGFloat = 14
    private let stripWidth: CGFloat = 18

    private var totalHeight: CGFloat {
        CGFloat(letters.count) * letterHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: stripWidth, height: letterHeight)
            }
        }
        .frame(width: stripWidth, height: totalHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    handleScrub(at: value.location.y)
                }
                .onEnded { _ in
                    // Fade the preview bubble out shortly after release
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        activeLetter = nil
                    }
                }
        )
    }

    private func handleScrub(at y: CGFloat) {
        let raw = Int(y / letterHeight)
        let clamped = max(0, min(letters.count - 1, raw))
        let letter = letters[clamped]
        guard letter != activeLetter else { return }
        activeLetter = letter
        onLetterChange(letter)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
