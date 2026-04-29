import SwiftUI

// MARK: - Constants

private let historyKey = "audiorr_search_history"
private let maxHistory = 5

// MARK: - View Model

@MainActor
final class SearchViewModel: ObservableObject {
    static let shared = SearchViewModel()

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

// MARK: - SearchView (iOS 26 — system .searchable with Tab(role: .search))

struct SearchView: View {
    @ObservedObject private var vm = SearchViewModel.shared
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @Namespace private var heroNS

    var onPlaySong: ((NavidromeSong) -> Void)?

    private var hasQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isSearching && vm.results.isEmpty {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if hasQuery && vm.results.isEmpty && !vm.isSearching {
                    ContentUnavailableView.search(text: searchText)
                } else if hasQuery {
                    resultsContent
                } else if !NetworkMonitor.shared.isConnected {
                    offlineEmptyState
                } else {
                    browseContent
                }
            }
            .navigationTitle(L.search)
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
            .navigationDestination(for: SeeAllDestination.self) { SeeAllGridView(destination: $0) }
        }
        .searchable(text: $searchText, prompt: Text(L.searchPlaceholder))
        .searchFocused($searchFocused)
        .onAppear { searchFocused = true }
        .searchSuggestions {
            if !hasQuery && !vm.history.isEmpty {
                ForEach(vm.history, id: \.self) { item in
                    Label(item, systemImage: "clock")
                        .searchCompletion(item)
                }
                Button(role: .destructive) {
                    withAnimation { vm.clearHistory() }
                } label: {
                    Label(L.clearHistory, systemImage: "trash")
                }
            }
        }
        .onChange(of: searchText) { _, newValue in
            vm.onQueryChange(newValue)
        }
        .onSubmit(of: .search) {
            vm.saveToHistory(searchText)
        }
        .onDisappear {
            vm.debounceTask?.cancel()
        }
    }

    // MARK: - Browse (empty state when no query)

    private var browseContent: some View {
        ScrollView {
            VStack(spacing: 32) {
                // History section (when suggestions overlay is dismissed)
                if !vm.history.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(L.recents)
                                .font(.title3.bold())
                            Spacer()
                            Button(L.clearHistory) {
                                withAnimation { vm.clearHistory() }
                            }
                            .font(.subheadline)
                        }
                        .padding(.horizontal, 20)

                        ForEach(vm.history, id: \.self) { item in
                            Button {
                                searchText = item
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24)

                                    Text(item)
                                        .foregroundStyle(.primary)

                                    Spacer()

                                    Image(systemName: "arrow.up.left")
                                        .foregroundStyle(.tertiary)
                                        .font(.system(size: 13))
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 80)
        }
    }

    // MARK: - Offline empty state

    private var offlineEmptyState: some View {
        ContentUnavailableView {
            Label(L.noConnection, systemImage: "wifi.slash")
        } description: {
            Text(L.offlineSearchOnly)
        }
    }

    // MARK: - Results

    private var resultsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !vm.results.artists.isEmpty {
                    resultSection(title: L.artists) {
                        ForEach(vm.results.artists) { artist in
                            NavigationLink(value: artist) {
                                ArtistSearchRow(artist: artist)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded {
                                vm.saveToHistory(searchText)
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
                                vm.saveToHistory(searchText)
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
                                vm.saveToHistory(searchText)
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
            .padding(.bottom, 80)
        }
    }

    private func resultSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

            content()
                .padding(.horizontal, 20)
        }
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
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .task(id: artist.id) {
            if let cached = ArtistImageCache.shared.image(for: artist.id) {
                avatarImage = cached
                didLoad = true
                return
            }

            guard let url = await NavidromeService.shared.artistAvatarURL(artistId: artist.id) else {
                didLoad = true
                return
            }

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
        .padding(.vertical, 8)
        .contentShape(Rectangle())
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
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Preview

#Preview {
    SearchView()
}
