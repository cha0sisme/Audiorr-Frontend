import SwiftUI

// MARK: - Constants

private let historyKey = "audiorr_search_history"
private let maxHistory = 5

// MARK: - View Model

@MainActor
final class SearchViewModel: ObservableObject {
    static let shared = SearchViewModel()

    @Published var query = ""
    @Published var results = SearchResults()
    @Published var isSearching = false
    @Published var history: [String] = []

    private let api = NavidromeService.shared
    fileprivate var debounceTask: Task<Void, Never>?

    private init() {
        loadHistory()
    }

    // MARK: - Search

    func onQueryChange(_ q: String) {
        debounceTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            results = SearchResults()
            isSearching = false
            return
        }
        isSearching = true
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms debounce
            guard !Task.isCancelled else { return }
            await performSearch(trimmed)
        }
    }

    private func performSearch(_ q: String) async {
        // Offline fallback: search cached songs
        if !NetworkMonitor.shared.isConnected {
            let cached = await OfflineContentProvider.shared.search(query: q)
            guard !Task.isCancelled else { return }
            results = SearchResults(songs: cached.map { $0.toNavidromeSong() })
            isSearching = false
            return
        }

        api.reloadCredentials()
        guard api.isConfigured else {
            isSearching = false
            return
        }

        do {
            let r = try await api.searchAll(query: q, artistCount: 6, albumCount: 6, songCount: 8)
            guard !Task.isCancelled else { return }
            results = r
            isSearching = false

            // Pre-warm artist avatar cache in background (non-blocking)
            for artist in r.artists {
                Task.detached(priority: .utility) {
                    _ = await NavidromeService.shared.artistAvatarURL(artistId: artist.id)
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            results = SearchResults()
            isSearching = false
        }
    }

    // MARK: - History

    func saveToHistory(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        history.removeAll { $0.lowercased() == trimmed.lowercased() }
        history.insert(trimmed, at: 0)
        history = Array(history.prefix(maxHistory))
        persistHistory()
    }

    func removeFromHistory(_ item: String) {
        history.removeAll { $0 == item }
        persistHistory()
    }

    func clearHistory() {
        history.removeAll()
        persistHistory()
    }

    private func loadHistory() {
        history = (UserDefaults.standard.array(forKey: historyKey) as? [String] ?? [])
            .prefix(maxHistory).map { $0 }
    }

    private func persistHistory() {
        UserDefaults.standard.set(history, forKey: historyKey)
    }
}

// MARK: - SearchView

struct SearchView: View {
    @ObservedObject private var vm = SearchViewModel.shared
    @FocusState private var searchFocused: Bool
    @State private var scrollY: CGFloat = 0
    @Namespace private var heroNS

    var onPlaySong: ((NavidromeSong) -> Void)?

    private let collapseThreshold: CGFloat = 44

    private var stickyOpacity: CGFloat {
        min(max((scrollY - collapseThreshold * 0.4) / (collapseThreshold * 0.6), 0), 1)
    }
    private var largeTitleOpacity: CGFloat {
        1 - min(max(scrollY / collapseThreshold, 0), 1)
    }

    private var hasQuery: Bool {
        !vm.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    largeHeader
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)

                    if !NetworkMonitor.shared.isConnected && !hasQuery {
                        offlineBanner
                    }

                    if vm.isSearching && vm.results.isEmpty {
                        searchingSection
                    } else if hasQuery && vm.results.isEmpty && !vm.isSearching {
                        emptySection
                    } else if hasQuery {
                        resultsContent
                    } else if !vm.history.isEmpty {
                        historySection
                    }

                    Spacer(minLength: 80)
                }
            }
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                scrollY = y
            }
            .background(Color(.systemBackground))
            .toolbarBackground(stickyOpacity > 0.5 ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(L.search)
                        .font(.headline)
                        .lineLimit(1)
                        .opacity(stickyOpacity)
                }
            }
            .onChange(of: vm.query) { _, newValue in
                vm.onQueryChange(newValue)
            }
            .onDisappear {
                vm.debounceTask?.cancel()
            }
            .navigationDestination(for: NavidromeAlbum.self) { album in
                AlbumDetailView(album: album)
                    .navigationTransition(.zoom(sourceID: album.id, in: heroNS))
            }
            .navigationDestination(for: NavidromeArtist.self) { artist in
                ArtistDetailView(artist: artist, heroNamespace: heroNS)
                    .navigationTransition(.zoom(sourceID: artist.id, in: heroNS))
            }
            .navigationDestination(for: NavidromePlaylist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
                    .navigationTransition(.zoom(sourceID: playlist.id, in: heroNS))
            }
        }
    }

    // MARK: - Large title header

    private var largeHeader: some View {
        HStack(alignment: .bottom) {
            Text(L.search)
                .font(.system(size: 34, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 59)
        .opacity(largeTitleOpacity)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 15))

            TextField(L.searchPlaceholder, text: $vm.query)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { vm.saveToHistory(vm.query) }

            if !vm.query.isEmpty {
                Button {
                    vm.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Offline banner

    private var offlineBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
            Text(L.offlineSearchOnly)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L.recents)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if vm.history.count > 1 {
                    Button(L.clearHistory) {
                        withAnimation(Anim.small) { vm.clearHistory() }
                    }
                    .font(.subheadline)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            ForEach(vm.history, id: \.self) { item in
                Button {
                    vm.query = item
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 15))
                            .frame(width: 20)

                        Text(item)
                            .foregroundStyle(.primary)

                        Spacer()

                        Image(systemName: "arrow.up.left")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 13))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)

                if item != vm.history.last {
                    Divider().padding(.leading, 48)
                }
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !vm.results.artists.isEmpty {
                resultSection(title: L.artists) {
                    ForEach(vm.results.artists) { artist in
                        NavigationLink(value: artist) {
                            ArtistSearchRow(artist: artist)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            vm.saveToHistory(vm.query)
                        })

                        if artist.id != vm.results.artists.last?.id {
                            Divider().padding(.leading, 62)
                        }
                    }
                }
            }

            if !vm.results.albums.isEmpty {
                resultSection(title: L.albumsSearch) {
                    ForEach(vm.results.albums) { album in
                        NavigationLink(value: album) {
                            AlbumSearchRow(album: album)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            vm.saveToHistory(vm.query)
                        })

                        if album.id != vm.results.albums.last?.id {
                            Divider().padding(.leading, 62)
                        }
                    }
                }
            }

            if !vm.results.songs.isEmpty {
                resultSection(title: L.songsLabel) {
                    ForEach(vm.results.songs) { song in
                        Button {
                            vm.saveToHistory(vm.query)
                            onPlaySong?(song)
                        } label: {
                            SongSearchRow(song: song)
                        }
                        .buttonStyle(.plain)

                        if song.id != vm.results.songs.last?.id {
                            Divider().padding(.leading, 62)
                        }
                    }
                }
            }
        }
    }

    private func resultSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            content()
                .padding(.horizontal, 16)
        }
    }

    // MARK: - States

    private var searchingSection: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, 32)
    }

    private var emptySection: some View {
        VStack(spacing: 12) {
            if !NetworkMonitor.shared.isConnected {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text(L.noConnection)
                    .foregroundStyle(.secondary)
                    .font(.subheadline.bold())
                Text(L.offlineNoResults(vm.query))
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text(L.noResultsFor(vm.query))
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Artist search row — avatar loads from cache, then async

private struct ArtistSearchRow: View {
    let artist: NavidromeArtist

    @State private var avatarImage: UIImage?
    @State private var didLoad = false

    private var fallbackColor: Color {
        let hash = artist.name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 360 }
        return Color(hue: Double(hash) / 360.0, saturation: 0.35, brightness: 0.55)
    }

    var body: some View {
        HStack(spacing: 14) {
            // Circular avatar — Apple Music style
            ZStack {
                if let img = avatarImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else if didLoad {
                    fallbackColor.opacity(0.25)
                        .overlay(
                            Text(String(artist.name.prefix(1)).uppercased())
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(fallbackColor)
                        )
                } else {
                    Color(.tertiarySystemFill)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(L.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .task(id: artist.id) {
            // 1) Check shared image cache first (instant)
            if let cached = ArtistImageCache.shared.image(for: artist.id) {
                avatarImage = cached
                didLoad = true
                return
            }

            // 2) Get avatar URL (may be cached in NavidromeService)
            guard let url = await NavidromeService.shared.artistAvatarURL(artistId: artist.id) else {
                didLoad = true
                return
            }

            // 3) Download image
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else {
                didLoad = true
                return
            }

            ArtistImageCache.shared.setImage(img, for: artist.id)
            withAnimation(Anim.small) {
                avatarImage = img
                didLoad = true
            }
        }
    }
}

// MARK: - Album search row — cached cover

private struct AlbumSearchRow: View {
    let album: NavidromeAlbum

    var body: some View {
        HStack(spacing: 14) {
            CachedCoverThumbnail(id: album.coverArt, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(album.artist)
                    if let year = album.year {
                        Text("·")
                        Text(String(year))
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Song search row — cached cover

private struct SongSearchRow: View {
    let song: NavidromeSong

    var body: some View {
        HStack(spacing: 14) {
            CachedCoverThumbnail(id: song.coverArt, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(song.artist) · \(song.album)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Cached cover thumbnail (uses AlbumCoverCache + URLSession instead of AsyncImage)

// CachedCoverThumbnail is now shared — defined in AlbumCardView.swift

// MARK: - Preview

#Preview {
    SearchView()
}
