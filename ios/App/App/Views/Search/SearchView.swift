import SwiftUI

// MARK: - Constants

private let historyKey = "audiorr_search_history"
private let maxHistory = 5

// MARK: - View Model

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var results = SearchResults()
    @Published var isSearching = false
    @Published var history: [String] = []
    @Published var artistAvatars: [String: URL?] = [:]   // artistId → URL?

    private let api = NavidromeService.shared
    private var debounceTask: Task<Void, Never>?

    init() {
        loadHistory()
    }

    // MARK: - Search

    func onQueryChange(_ q: String) {
        debounceTask?.cancel()
        if q.trimmingCharacters(in: .whitespaces).isEmpty {
            results = SearchResults()
            artistAvatars = [:]
            return
        }
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
            guard !Task.isCancelled else { return }
            await performSearch(q.trimmingCharacters(in: .whitespaces))
        }
    }

    private func performSearch(_ q: String) async {
        isSearching = true
        defer { isSearching = false }

        api.reloadCredentials()
        guard api.isConfigured else { return }

        do {
            let r = try await api.searchAll(query: q, artistCount: 5, albumCount: 5, songCount: 5)
            results = r
            await loadArtistAvatars(for: r.artists)
        } catch {
            results = SearchResults()
        }
    }

    private func loadArtistAvatars(for artists: [NavidromeArtist]) async {
        artistAvatars = [:]
        await withTaskGroup(of: (String, URL?).self) { group in
            for artist in artists {
                group.addTask { [weak self] in
                    guard let self else { return (artist.id, nil) }
                    let url = await self.api.artistAvatarURL(artistId: artist.id)
                    return (artist.id, url)
                }
            }
            for await (id, url) in group {
                artistAvatars[id] = url
            }
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
    @StateObject private var vm = SearchViewModel()
    @FocusState private var searchFocused: Bool

    // Song playback callback (still used — no push navigation needed)
    var onPlaySong: ((NavidromeSong) -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Buscar")
                        .font(.system(size: 34, weight: .bold))
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 12)

                    // Search bar
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)

                    // Content
                    if vm.isSearching {
                        spinner
                    } else if !vm.query.trimmingCharacters(in: .whitespaces).isEmpty && vm.results.isEmpty {
                        emptyState
                    } else if !vm.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        resultsView
                    } else if !vm.history.isEmpty {
                        historyView
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: vm.query) { _, newValue in
                vm.onQueryChange(newValue)
            }
            .navigationBarHidden(true)
            .navigationDestination(for: NavidromeAlbum.self) { album in
                AlbumDetailView(album: album)
            }
            .navigationDestination(for: NavidromeArtist.self) { artist in
                ArtistDetailView(artist: artist)
            }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 15))

            TextField("Artistas, álbumes, canciones...", text: $vm.query)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - History

    private var historyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Búsquedas recientes")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                ForEach(vm.history, id: \.self) { item in
                    HStack {
                        Button {
                            vm.query = item
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(item)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            vm.removeFromHistory(item)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    if item != vm.history.last {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Results

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !vm.results.artists.isEmpty { artistsSection }
            if !vm.results.albums.isEmpty  { albumsSection  }
            if !vm.results.songs.isEmpty   { songsSection   }
        }
        .padding(.bottom, 32)
    }

    private var artistsSection: some View {
        resultSection(title: "Artistas") {
            ForEach(vm.results.artists) { artist in
                NavigationLink(value: artist) {
                    ArtistRow(artist: artist, avatarURL: vm.artistAvatars[artist.id] ?? nil)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    vm.saveToHistory(vm.query)
                    vm.query = ""
                })

                if artist.id != vm.results.artists.last?.id {
                    Divider().padding(.leading, 68)
                }
            }
        }
    }

    private var albumsSection: some View {
        resultSection(title: "Álbumes") {
            ForEach(vm.results.albums) { album in
                NavigationLink(value: album) {
                    AlbumRow(album: album)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    vm.saveToHistory(vm.query)
                    vm.query = ""
                })

                if album.id != vm.results.albums.last?.id {
                    Divider().padding(.leading, 68)
                }
            }
        }
    }

    private var songsSection: some View {
        resultSection(title: "Canciones") {
            ForEach(vm.results.songs) { song in
                Button {
                    vm.saveToHistory(vm.query)
                    vm.query = ""
                    onPlaySong?(song)
                } label: {
                    SongRow(song: song)
                }
                .buttonStyle(.plain)

                if song.id != vm.results.songs.last?.id {
                    Divider().padding(.leading, 68)
                }
            }
        }
    }

    private func resultSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                content()
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - States

    private var spinner: some View {
        HStack { Spacer(); ProgressView(); Spacer() }
            .padding(.top, 48)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Sin resultados para «\(vm.query)»")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }
}

// MARK: - Row components

private struct ArtistRow: View {
    let artist: NavidromeArtist
    let avatarURL: URL?

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: avatarURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Image(systemName: "person.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 22))
                }
            }
            .frame(width: 44, height: 44)
            .background(Color(.tertiarySystemFill))
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Artista")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

private struct AlbumRow: View {
    let album: NavidromeAlbum

    var body: some View {
        HStack(spacing: 14) {
            CoverThumbnail(id: album.coverArt, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(album.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

private struct SongRow: View {
    let song: NavidromeSong

    var body: some View {
        HStack(spacing: 14) {
            CoverThumbnail(id: song.coverArt, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(song.artist) · \(song.album)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Cover thumbnail helper

private struct CoverThumbnail: View {
    let id: String?
    var size: Int = 100
    var cornerRadius: CGFloat = 6

    private var url: URL? { NavidromeService.shared.coverURL(id: id, size: size) }

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            default:               Color(.tertiarySystemFill)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Preview

#Preview {
    SearchView()
}
