import SwiftUI

// MARK: - Constants

private let historyKey = "audiorr_search_history"
private let maxHistory = 5
private let minQueryLength = 2

// MARK: - Scoring helpers (ported from Audiorr-web)

/// Match score por calidad de coincidencia. Menor = mejor.
///   0 = exacto (lower == q)
///   1 = empieza por la query
///   2 = la query es palabra completa dentro del campo (\bquery\b)
///   3 = la query aparece como substring en cualquier posición
///   Int.max = no match → filtrado fuera
private let NO_MATCH = Int.max

private func matchScore(_ value: String?, _ q: String) -> Int {
    guard let value, !value.isEmpty else { return NO_MATCH }
    let lower = value.lowercased()
    if lower == q { return 0 }
    if lower.hasPrefix(q) { return 1 }
    let escaped = NSRegularExpression.escapedPattern(for: q)
    if let re = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: .caseInsensitive) {
        let range = NSRange(value.startIndex..., in: value)
        if re.firstMatch(in: value, range: range) != nil { return 2 }
    }
    if lower.contains(q) { return 3 }
    return NO_MATCH
}

/// Combina varios campos por prioridad: primary +0, secondary +10, tertiary +20.
/// El mejor campo gana. Permite que un exact match en `title` (score 0) gane a
/// un exact match en `album` (score 0 + 20 = 20).
private func bestFieldScore(_ fields: [String?], _ q: String) -> Int {
    var best = NO_MATCH
    for (i, f) in fields.enumerated() {
        let s = matchScore(f, q)
        if s == NO_MATCH { continue }
        let withOffset = s &+ i * 10
        if withOffset < best { best = withOffset }
    }
    return best
}

// MARK: - Top Result

/// Mejor coincidencia cruzando tipos. Se renderiza como tarjeta destacada.
enum TopResultItem: Identifiable, Hashable {
    case artist(NavidromeArtist)
    case album(NavidromeAlbum)
    case song(NavidromeSong)
    case playlist(NavidromePlaylist)

    var id: String {
        switch self {
        case .artist(let a):   return "a-\(a.id)"
        case .album(let a):    return "al-\(a.id)"
        case .song(let s):     return "s-\(s.id)"
        case .playlist(let p): return "pl-\(p.id)"
        }
    }

    var typeLabel: String {
        switch self {
        case .artist:   return L.artist
        case .album:    return L.album
        case .song:     return L.song
        case .playlist: return L.playlist
        }
    }

    var name: String {
        switch self {
        case .artist(let a):   return a.name
        case .album(let a):    return a.name
        case .song(let s):     return s.title
        case .playlist(let p): return p.name
        }
    }

    var subtitle: String? {
        switch self {
        case .artist:          return nil
        case .album(let a):    return a.artist
        case .song(let s):     return s.artist
        case .playlist(let p): return p.owner
        }
    }

    var coverArt: String? {
        switch self {
        case .artist:          return nil
        case .album(let a):    return a.coverArt
        case .song(let s):     return s.coverArt
        case .playlist(let p): return p.coverArt
        }
    }

    var artistId: String? {
        if case .artist(let a) = self { return a.id }
        return nil
    }

    var artistName: String? {
        if case .artist(let a) = self { return a.name }
        return nil
    }
}

// MARK: - Tab filter

enum SearchTab: Hashable, CaseIterable, Identifiable {
    case all, artists, albums, songs, playlists
    var id: Self { self }

    var label: String {
        switch self {
        case .all:       return L.all
        case .artists:   return L.artists
        case .albums:    return L.albumsSearch
        case .songs:     return L.songsLabel
        case .playlists: return L.playlists
        }
    }
}

// MARK: - View Model

@MainActor
final class SearchViewModel: ObservableObject {
    static let shared = SearchViewModel()

    // Resultados rerankeados (post-filter client-side).
    @Published var artists: [NavidromeArtist] = []
    @Published var albums: [NavidromeAlbum] = []
    @Published var songs: [NavidromeSong] = []
    @Published var playlists: [NavidromePlaylist] = []
    @Published var topResult: TopResultItem?
    @Published var isSearching = false
    @Published var history: [String] = []

    private let api = NavidromeService.shared
    fileprivate var debounceTask: Task<Void, Never>?

    // Cache de playlists (Subsonic no tiene endpoint de search de playlists,
    // filtramos client-side de la lista completa).
    private var playlistsCache: [NavidromePlaylist] = []
    private var playlistsCacheTime: Date?
    private let playlistsCacheTTL: TimeInterval = 5 * 60

    private init() {
        loadHistory()
    }

    var isEmpty: Bool {
        artists.isEmpty && albums.isEmpty && songs.isEmpty && playlists.isEmpty
    }

    // MARK: - Search

    func onQueryChange(_ q: String) {
        debounceTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        if trimmed.count < minQueryLength {
            artists = []
            albums = []
            songs = []
            playlists = []
            topResult = nil
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
        let lowered = q.lowercased()

        // Offline: search cached songs only.
        if !NetworkMonitor.shared.isConnected {
            let cached = await OfflineContentProvider.shared.search(query: q)
            guard !Task.isCancelled else { return }
            artists = []
            albums = []
            songs = cached.map { $0.toNavidromeSong() }
            playlists = []
            topResult = nil
            isSearching = false
            return
        }

        api.reloadCredentials()
        guard api.isConfigured else {
            isSearching = false
            return
        }

        // Sobre-pedimos (20/20/40 como en Audiorr-web) — luego filtramos
        // client-side por substring real en campos visibles y rankeamos.
        async let raw = api.searchAll(query: q, artistCount: 20, albumCount: 20, songCount: 40)
        async let playlistsAll = loadPlaylistsCached()

        let rawResults: SearchResults
        do {
            rawResults = try await raw
        } catch {
            _ = await playlistsAll
            guard !Task.isCancelled else { return }
            artists = []
            albums = []
            songs = []
            playlists = []
            topResult = nil
            isSearching = false
            return
        }
        let allPlaylists = await playlistsAll
        guard !Task.isCancelled else { return }

        // Albums: rerank por [name, artist].
        let filteredAlbums = rawResults.albums
            .map { (a: $0, score: bestFieldScore([$0.name, $0.artist], lowered)) }
            .filter { $0.score != NO_MATCH }
            .sorted { $0.score < $1.score }
            .map { $0.a }

        // Songs: rerank por [title, artist, album]. Esto hace que "POWER"
        // exact en title gane a un álbum llamado "Power Symphony".
        let scoredSongs: [(s: NavidromeSong, score: Int)] = rawResults.songs
            .map { (s: $0, score: bestFieldScore([$0.title, $0.artist, $0.album], lowered)) }
            .filter { $0.score != NO_MATCH }
            .sorted { $0.score < $1.score }
        let filteredSongs = scoredSongs.map { $0.s }

        // Artists: rerank + complementa con artistas extraídos de songs
        // (Navidrome a veces no devuelve artistas que solo aparecen como
        // `artist` de tracks, sin álbumes propios indexados).
        var seenArtistIds = Set<String>()
        var artistCandidates: [NavidromeArtist] = []
        for a in rawResults.artists where matchScore(a.name, lowered) != NO_MATCH {
            seenArtistIds.insert(a.id)
            artistCandidates.append(a)
        }
        for s in rawResults.songs {
            guard let aid = s.artistId, !seenArtistIds.contains(aid),
                  matchScore(s.artist, lowered) != NO_MATCH else { continue }
            seenArtistIds.insert(aid)
            artistCandidates.append(NavidromeArtist(id: aid, name: s.artist, albumCount: nil))
        }
        let filteredArtists = artistCandidates
            .map { (a: $0, score: matchScore($0.name, lowered)) }
            .sorted { $0.score < $1.score }
            .map { $0.a }

        // Playlists: filter client-side por [name, owner, comment].
        let filteredPlaylists = allPlaylists
            .map { (p: $0, score: bestFieldScore([$0.name, $0.owner, $0.comment], lowered)) }
            .filter { $0.score != NO_MATCH }
            .sorted { $0.score < $1.score }
            .prefix(20)
            .map { $0.p }

        // Top Result: el mejor score absoluto cruzando tipos. Tie-break por
        // tipo: artista > canción > álbum > playlist (lo más útil al usuario
        // según el caso típico "busco POWER → quiero la canción", "busco
        // Kanye → quiero el artista").
        let top = computeTopResult(
            query: lowered,
            artists: filteredArtists,
            songs: scoredSongs,
            albums: filteredAlbums,
            playlists: filteredPlaylists
        )

        // Quitamos el top result de su sección para no duplicarlo en la lista.
        var finalArtists = filteredArtists
        var finalAlbums = filteredAlbums
        var finalSongs = filteredSongs
        var finalPlaylists = Array(filteredPlaylists)
        if let top {
            switch top {
            case .artist(let a):   finalArtists.removeAll { $0.id == a.id }
            case .album(let a):    finalAlbums.removeAll { $0.id == a.id }
            case .song(let s):     finalSongs.removeAll { $0.id == s.id }
            case .playlist(let p): finalPlaylists.removeAll { $0.id == p.id }
            }
        }

        artists = finalArtists
        albums = finalAlbums
        songs = finalSongs
        playlists = finalPlaylists
        topResult = top
        isSearching = false

        // Pre-warm avatares de artistas en background (no bloqueante).
        for artist in filteredArtists.prefix(6) {
            Task.detached(priority: .utility) {
                _ = await NavidromeService.shared.artistAvatarURL(artistId: artist.id)
            }
        }
    }

    private func computeTopResult(
        query: String,
        artists: [NavidromeArtist],
        songs: [(s: NavidromeSong, score: Int)],
        albums: [NavidromeAlbum],
        playlists: [NavidromePlaylist]
    ) -> TopResultItem? {
        // Mejor candidato de cada tipo.
        let bestArtist: (item: TopResultItem, score: Int)? = artists.first.map {
            (.artist($0), matchScore($0.name, query))
        }
        let bestSong: (item: TopResultItem, score: Int)? = songs.first.map {
            (.song($0.s), $0.score)
        }
        let bestAlbum: (item: TopResultItem, score: Int)? = albums.first.map {
            (.album($0), bestFieldScore([$0.name, $0.artist], query))
        }
        let bestPlaylist: (item: TopResultItem, score: Int)? = playlists.first.map {
            (.playlist($0), bestFieldScore([$0.name, $0.owner, $0.comment], query))
        }

        // Orden de tie-break: artist > song > album > playlist.
        let candidates = [bestArtist, bestSong, bestAlbum, bestPlaylist].compactMap { $0 }
        return candidates.min { $0.score < $1.score }?.item
    }

    private func loadPlaylistsCached() async -> [NavidromePlaylist] {
        if let t = playlistsCacheTime,
           Date().timeIntervalSince(t) < playlistsCacheTTL,
           !playlistsCache.isEmpty {
            return playlistsCache
        }
        let fresh = (try? await api.getPlaylists()) ?? []
        playlistsCache = fresh
        playlistsCacheTime = Date()
        return fresh
    }

    // MARK: - History

    func saveToHistory(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= minQueryLength else { return }
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
    @State private var searchText = ""
    @State private var currentTab: SearchTab = .all
    @State private var navigationPath = NavigationPath()
    @FocusState private var searchFocused: Bool
    @Namespace private var heroNS

    var onPlaySong: ((NavidromeSong) -> Void)?

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }
    private var hasQuery: Bool { trimmedQuery.count >= minQueryLength }
    private var hasAnyResult: Bool {
        vm.topResult != nil || !vm.isEmpty
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if vm.isSearching && !hasAnyResult {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if hasQuery && !hasAnyResult && !vm.isSearching {
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
            .toolbar {
                // Cancel manual en lugar del Cancel del sistema. SearchView
                // vive dentro de `Tab(role: .search)` (iOS 26 pill), donde el
                // Cancel automático del `.searchable` no aparece. Como hay
                // NavigationStack con navigationTitle, los ToolbarItems en
                // `.topBarTrailing` se renderizan en la barra de navegación.
                ToolbarItem(placement: .topBarTrailing) {
                    // Solo cuando hay texto. Apple Music no muestra Cancel al
                    // entrar con el campo enfocado pero vacío — sería ruido.
                    if !searchText.isEmpty {
                        Button(L.cancel) {
                            searchText = ""
                            searchFocused = false
                        }
                    }
                }
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
            .navigationDestination(for: SeeAllDestination.self) { SeeAllGridView(destination: $0) }
        }
        // En el NavigationStack: el path llega a los destinos empujados.
        .navPath($navigationPath)
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
            searchFocused = false
        }
        .onDisappear {
            vm.debounceTask?.cancel()
        }
    }

    // MARK: - Browse (empty state when no query)

    private var browseContent: some View {
        ScrollView {
            VStack(spacing: 32) {
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
                                vm.saveToHistory(item)
                                searchFocused = false
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24)
                                    Text(item).foregroundStyle(.primary)
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
                tabPicker
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                if let top = vm.topResult, showSection(for: top) {
                    topResultSection(top)
                }

                if showArtists, !vm.artists.isEmpty {
                    resultSection(title: L.artists) {
                        ForEach(visibleArtists) { artist in
                            NavigationLink(value: artist) {
                                ArtistSearchRow(artist: artist)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded {
                                vm.saveToHistory(searchText)
                            })

                            if artist.id != visibleArtists.last?.id {
                                Divider().padding(.leading, 62)
                            }
                        }
                    }
                }

                if showAlbums, !vm.albums.isEmpty {
                    resultSection(title: L.albumsSearch) {
                        ForEach(visibleAlbums) { album in
                            NavigationLink(value: album) {
                                AlbumSearchRow(album: album)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded {
                                vm.saveToHistory(searchText)
                            })

                            if album.id != visibleAlbums.last?.id {
                                Divider().padding(.leading, 62)
                            }
                        }
                    }
                }

                if showSongs, !vm.songs.isEmpty {
                    resultSection(title: L.songsLabel) {
                        ForEach(visibleSongs) { song in
                            Button {
                                vm.saveToHistory(searchText)
                                onPlaySong?(song)
                            } label: {
                                SongSearchRow(song: song)
                            }
                            .buttonStyle(.plain)

                            if song.id != visibleSongs.last?.id {
                                Divider().padding(.leading, 62)
                            }
                        }
                    }
                }

                if showPlaylists, !vm.playlists.isEmpty {
                    resultSection(title: L.playlists) {
                        ForEach(visiblePlaylists) { playlist in
                            NavigationLink(value: playlist) {
                                PlaylistSearchRow(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded {
                                vm.saveToHistory(searchText)
                            })

                            if playlist.id != visiblePlaylists.last?.id {
                                Divider().padding(.leading, 62)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 80)
        }
    }

    // MARK: - Tab picker (segmented)

    private var tabPicker: some View {
        Picker(L.search, selection: $currentTab) {
            ForEach(SearchTab.allCases) { tab in
                Text(tab.label).tag(tab)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Top Result section

    @ViewBuilder
    private func topResultSection(_ top: TopResultItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L.topResult)
                .font(.title3.bold())
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

            topResultDestination(top)
                .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private func topResultDestination(_ top: TopResultItem) -> some View {
        switch top {
        case .artist(let a):
            NavigationLink(value: a) {
                TopResultCard(item: top)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                vm.saveToHistory(searchText)
            })
        case .album(let al):
            NavigationLink(value: al) {
                TopResultCard(item: top)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                vm.saveToHistory(searchText)
            })
        case .playlist(let p):
            NavigationLink(value: p) {
                TopResultCard(item: top)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                vm.saveToHistory(searchText)
            })
        case .song(let s):
            Button {
                vm.saveToHistory(searchText)
                onPlaySong?(s)
            } label: {
                TopResultCard(item: top)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Section visibility (driven by current tab)

    private var showArtists:   Bool { currentTab == .all || currentTab == .artists }
    private var showAlbums:    Bool { currentTab == .all || currentTab == .albums }
    private var showSongs:     Bool { currentTab == .all || currentTab == .songs }
    private var showPlaylists: Bool { currentTab == .all || currentTab == .playlists }

    private func showSection(for top: TopResultItem) -> Bool {
        switch (currentTab, top) {
        case (.all, _):                              return true
        case (.artists,   .artist):                  return true
        case (.albums,    .album):                   return true
        case (.songs,     .song):                    return true
        case (.playlists, .playlist):                return true
        default:                                     return false
        }
    }

    private var visibleArtists: [NavidromeArtist] {
        currentTab == .all ? Array(vm.artists.prefix(6)) : vm.artists
    }
    private var visibleAlbums: [NavidromeAlbum] {
        currentTab == .all ? Array(vm.albums.prefix(6)) : vm.albums
    }
    private var visibleSongs: [NavidromeSong] {
        currentTab == .all ? Array(vm.songs.prefix(5)) : vm.songs
    }
    private var visiblePlaylists: [NavidromePlaylist] {
        currentTab == .all ? Array(vm.playlists.prefix(6)) : vm.playlists
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

// MARK: - Top Result Card (estilo Apple Music)

private struct TopResultCard: View {
    let item: TopResultItem

    var body: some View {
        HStack(spacing: 16) {
            cover
                .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.typeLabel.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)

                Text(item.name)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let sub = item.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cover: some View {
        switch item {
        case .artist(let a):
            TopResultArtistAvatar(artistId: a.id, name: a.name)
        case .album, .song, .playlist:
            CachedCoverThumbnail(coverArt: item.coverArt, size: 84, cornerRadius: 10)
        }
    }
}

/// Avatar circular grande para el artista en Top Result.
private struct TopResultArtistAvatar: View {
    let artistId: String
    let name: String

    @State private var image: UIImage?
    @State private var didLoad = false

    private var fallbackColor: Color {
        let hash = name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 360 }
        return Color(hue: Double(hash) / 360.0, saturation: 0.35, brightness: 0.55)
    }

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else if didLoad {
                fallbackColor.opacity(0.25)
                    .overlay(
                        Text(String(name.prefix(1)).uppercased())
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(fallbackColor)
                    )
            } else {
                Color(.tertiarySystemFill)
            }
        }
        .clipShape(Circle())
        .task(id: artistId) {
            if let cached = ArtistImageCache.shared.image(for: artistId) {
                image = cached
                didLoad = true
                return
            }
            guard let url = await NavidromeService.shared.artistAvatarURL(artistId: artistId) else {
                didLoad = true
                return
            }
            guard let (data, _) = try? await AudiorrNetwork.background.data(from: url),
                  let img = UIImage(data: data) else {
                didLoad = true
                return
            }
            ArtistImageCache.shared.setImage(img, for: artistId)
            withAnimation(Anim.small) {
                image = img
                didLoad = true
            }
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

            guard let (data, _) = try? await AudiorrNetwork.background.data(from: url),
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
            CachedCoverThumbnail(coverArt: album.coverArt, cornerRadius: 8)
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
            CachedCoverThumbnail(coverArt: song.coverArt, cornerRadius: 8)
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

// MARK: - Playlist search row

private struct PlaylistSearchRow: View {
    let playlist: NavidromePlaylist

    var body: some View {
        HStack(spacing: 14) {
            CachedCoverThumbnail(coverArt: playlist.coverArt, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(L.playlist)
                    Text("·")
                    Text(L.songCount(playlist.songCount))
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

// MARK: - Preview

#Preview {
    SearchView()
}
