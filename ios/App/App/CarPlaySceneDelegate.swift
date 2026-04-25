import UIKit
import CarPlay
import MediaPlayer

/// Scene delegate para CarPlay Audio.
/// Tab bar con Inicio + Playlists + Buscar + Now Playing.
@objc(CarPlaySceneDelegate)
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {

    var interfaceController: CPInterfaceController?
    private var homeTemplate: CPListTemplate?
    private var playlistsTemplate: CPListTemplate?

    // MARK: - CPTemplateApplicationSceneDelegate

    @objc func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        print("[CarPlay] Conectado")

        // Tab 1: Inicio
        let homeList = CPListTemplate(title: "Inicio", sections: [
            CPListSection(items: [CPListItem(text: "Cargando...", detailText: nil, image: nil)])
        ])
        homeList.tabTitle = "Inicio"
        homeList.tabImage = UIImage(systemName: "house.fill")
        self.homeTemplate = homeList

        // Tab 2: Playlists
        let plistList = CPListTemplate(title: "Playlists", sections: [
            CPListSection(items: [
                CPListItem(text: "Cargando playlists...", detailText: "Inicia sesión en el iPhone si es necesario", image: nil)
            ])
        ])
        plistList.tabTitle = "Playlists"
        plistList.tabImage = UIImage(systemName: "music.note.list")
        self.playlistsTemplate = plistList

        // Configure NowPlaying template
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isAlbumArtistButtonEnabled = true
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.add(self)

        let tabBar = CPTabBarTemplate(templates: [homeList, plistList])
        interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)

        loadContent()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        self.interfaceController = nil
        print("[CarPlay] Desconectado")
    }

    // MARK: - Load Content

    private func loadContent() {
        guard NavidromeService.shared.credentials != nil else {
            print("[CarPlay] Sin credenciales — esperando login")
            let placeholder = CPListItem(text: "Inicia sesión en el iPhone", detailText: "Configura tu servidor en la app", image: nil)
            playlistsTemplate?.updateSections([CPListSection(items: [placeholder])])
            homeTemplate?.updateSections([CPListSection(items: [placeholder])])
            return
        }

        Task {
            if NetworkMonitor.shared.isConnected {
                // Check backend availability first (cached, fast)
                let backendAvailable = await NavidromeService.shared.checkBackendAvailable()
                await loadPlaylists(backendAvailable: backendAvailable)
                await loadHomeContent(backendAvailable: backendAvailable)
            } else {
                await loadOfflineContent()
            }
        }
    }

    // MARK: - Auth helpers

    private func authQuery() -> String {
        NavidromeService.shared.authQueryPublic()
    }

    private func serverUrl() -> String? {
        NavidromeService.shared.credentials?.serverUrl
    }

    // MARK: - Cargar Playlists

    private func loadPlaylists(backendAvailable: Bool) async {
        guard let creds = NavidromeService.shared.credentials else { return }

        let urlStr = "\(creds.serverUrl)/rest/getPlaylists.view?\(authQuery())"
        guard let url = URL(string: urlStr) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["subsonic-response"] as? [String: Any],
                  let status = response["status"] as? String, status == "ok"
            else {
                await MainActor.run {
                    let errItem = CPListItem(text: "Error cargando playlists", detailText: nil, image: nil)
                    playlistsTemplate?.updateSections([CPListSection(items: [errItem])])
                }
                return
            }

            let playlistsObj = response["playlists"] as? [String: Any] ?? [:]
            let playlistArr: [[String: Any]]
            if let arr = playlistsObj["playlist"] as? [[String: Any]] { playlistArr = arr }
            else if let single = playlistsObj["playlist"] as? [String: Any] { playlistArr = [single] }
            else {
                await MainActor.run {
                    let emptyItem = CPListItem(text: "Sin playlists", detailText: nil, image: nil)
                    playlistsTemplate?.updateSections([CPListSection(items: [emptyItem])])
                }
                return
            }

            let username = creds.username

            var allItems: [CPListItem] = []
            var myItems: [CPListItem] = []
            var smartItems: [CPListItem] = []
            var dailyItems: [CPListItem] = []
            var editorialItems: [CPListItem] = []

            for p in playlistArr {
                let name = p["name"] as? String ?? ""
                let id = p["id"] as? String ?? ""
                let songCount = p["songCount"] as? Int ?? 0
                let coverArt = p["coverArt"] as? String
                let owner = p["owner"] as? String ?? ""
                let comment = p["comment"] as? String ?? ""

                guard owner.lowercased() == username.lowercased() else { continue }

                let item = CPListItem(
                    text: name,
                    detailText: "\(songCount) canciones",
                    image: UIImage(systemName: "music.note.list"),
                    accessoryImage: nil,
                    accessoryType: .disclosureIndicator
                )

                item.handler = { [weak self] _, completion in
                    self?.showPlaylistSongs(playlistId: id, playlistName: name)
                    completion()
                }

                // Load cover: try backend first if available, else Navidrome directly
                if backendAvailable, let backendUrl = NavidromeService.shared.backendURL() {
                    let coverUrlStr = "\(backendUrl)/api/playlists/\(id)/cover.png"
                    if let coverUrl = URL(string: coverUrlStr) {
                        URLSession.shared.dataTask(with: coverUrl) { [weak self] data, response, _ in
                            if (response as? HTTPURLResponse)?.statusCode == 200,
                               let data, let image = UIImage(data: data) {
                                DispatchQueue.main.async { item.setImage(image) }
                            } else {
                                self?.loadCover(artId: coverArt) { image in
                                    if let image { DispatchQueue.main.async { item.setImage(image) } }
                                }
                            }
                        }.resume()
                    } else {
                        loadCover(artId: coverArt) { image in
                            if let image { DispatchQueue.main.async { item.setImage(image) } }
                        }
                    }
                } else {
                    loadCover(artId: coverArt) { image in
                        if let image { DispatchQueue.main.async { item.setImage(image) } }
                    }
                }

                if backendAvailable {
                    // Categorize into sections
                    let normalizedName = name.lowercased().trimmingCharacters(in: .whitespaces)
                    let isSmartPlaylist = comment.contains("Smart Playlist")
                    let isDailyMix = normalizedName.hasPrefix("mix diario")
                    let isEditorial = comment.contains("[Editorial]")
                    let isSpotify = normalizedName.hasPrefix("[spotify] ") || comment.contains("Spotify Synced")

                    if isDailyMix { dailyItems.append(item) }
                    else if isSmartPlaylist { smartItems.append(item) }
                    else if isEditorial || isSpotify { editorialItems.append(item) }
                    else { myItems.append(item) }
                } else {
                    // Flat list — no sections
                    allItems.append(item)
                }
            }

            var sections: [CPListSection] = []

            if backendAvailable {
                if !myItems.isEmpty      { sections.append(CPListSection(items: myItems,      header: "Mis Playlists",   sectionIndexTitle: nil)) }
                if !smartItems.isEmpty   { sections.append(CPListSection(items: smartItems,   header: "Hecho para ti",   sectionIndexTitle: nil)) }
                if !dailyItems.isEmpty   { sections.append(CPListSection(items: dailyItems,   header: "Mixes diarios",   sectionIndexTitle: nil)) }
                if !editorialItems.isEmpty { sections.append(CPListSection(items: editorialItems, header: "Mixes & Radio", sectionIndexTitle: nil)) }
            } else {
                if !allItems.isEmpty {
                    sections.append(CPListSection(items: allItems))
                }
            }

            if sections.isEmpty {
                let emptyItem = CPListItem(text: "Sin playlists", detailText: nil, image: nil)
                sections = [CPListSection(items: [emptyItem])]
            }

            await MainActor.run {
                playlistsTemplate?.updateSections(sections)
            }
        } catch {
            print("[CarPlay] Error de red: \(error.localizedDescription)")
        }
    }

    // MARK: - Home Content

    private func loadHomeContent(backendAvailable: Bool) async {
        guard let creds = NavidromeService.shared.credentials else { return }

        var jumpBackItems: [CPListItem] = []
        var latestItems: [CPListItem] = []

        // 1. Jump Back In (backend) — only if backend is reachable
        if backendAvailable, let backendUrl = NavidromeService.shared.backendURL() {
            let jbiUrlStr = "\(backendUrl)/api/stats/recent-contexts?username=\(creds.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            if let jbiUrl = URL(string: jbiUrlStr),
               let (data, _) = try? await URLSession.shared.data(from: jbiUrl),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {

                for entry in arr.prefix(10) {
                    let type   = entry["type"]   as? String ?? ""
                    let id     = entry["id"]     as? String ?? ""
                    let title  = entry["title"]  as? String ?? id
                    let artist = entry["artist"] as? String ?? ""
                    let coverArtId = entry["coverArtId"] as? String

                    guard type == "album" || type == "playlist" || type == "smartmix" else { continue }

                    let detail = type == "album" ? artist : nil
                    let item = CPListItem(
                        text: title,
                        detailText: detail,
                        image: UIImage(systemName: "music.note"),
                        accessoryImage: nil,
                        accessoryType: .disclosureIndicator
                    )

                    if type == "album" {
                        item.handler = { [weak self] _, completion in
                            self?.showAlbumSongs(albumId: id, albumName: title)
                            completion()
                        }
                        loadCover(artId: coverArtId) { image in
                            if let image { DispatchQueue.main.async { item.setImage(image) } }
                        }
                    } else {
                        item.handler = { [weak self] _, completion in
                            self?.showPlaylistSongs(playlistId: id, playlistName: title)
                            completion()
                        }
                        // Cover from backend
                        let coverUrlStr = "\(backendUrl)/api/playlists/\(id)/cover.png"
                        if let coverUrl = URL(string: coverUrlStr) {
                            URLSession.shared.dataTask(with: coverUrl) { data, response, _ in
                                if (response as? HTTPURLResponse)?.statusCode == 200,
                                   let data, let image = UIImage(data: data) {
                                    DispatchQueue.main.async { item.setImage(image) }
                                }
                            }.resume()
                        }
                    }
                    jumpBackItems.append(item)
                }
            }
        }

        // 2. Últimos álbumes (Navidrome)
        let albumsUrlStr = "\(creds.serverUrl)/rest/getAlbumList2.view?\(authQuery())&type=newest&size=15"
        if let albumsUrl = URL(string: albumsUrlStr),
           let (data, _) = try? await URLSession.shared.data(from: albumsUrl),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let response = json["subsonic-response"] as? [String: Any],
           let albumList = response["albumList2"] as? [String: Any] {

            let albums: [[String: Any]]
            if let arr = albumList["album"] as? [[String: Any]] { albums = arr }
            else if let single = albumList["album"] as? [String: Any] { albums = [single] }
            else { albums = [] }

            for album in albums {
                let name  = album["name"]   as? String ?? ""
                let id    = album["id"]     as? String ?? ""
                let artist = album["artist"] as? String ?? ""
                let coverArt = album["coverArt"] as? String

                let item = CPListItem(
                    text: name,
                    detailText: artist,
                    image: UIImage(systemName: "music.note"),
                    accessoryImage: nil,
                    accessoryType: .disclosureIndicator
                )
                item.handler = { [weak self] _, completion in
                    self?.showAlbumSongs(albumId: id, albumName: name)
                    completion()
                }
                loadCover(artId: coverArt) { image in
                    if let image { DispatchQueue.main.async { item.setImage(image) } }
                }
                latestItems.append(item)
            }
        }

        await MainActor.run {
            var sections: [CPListSection] = []

            // Quick actions: Explore + Now Playing
            let exploreItem = CPListItem(
                text: "Explorar",
                detailText: "Artistas, álbumes, géneros",
                image: UIImage(systemName: "magnifyingglass"),
                accessoryImage: nil,
                accessoryType: .disclosureIndicator
            )
            exploreItem.handler = { [weak self] _, completion in
                self?.showExploreBrowser()
                completion()
            }

            let nowPlayingItem = CPListItem(
                text: "Reproduciendo",
                detailText: "Volver al reproductor",
                image: UIImage(systemName: "play.circle.fill"),
                accessoryImage: nil,
                accessoryType: .disclosureIndicator
            )
            nowPlayingItem.handler = { [weak self] _, completion in
                self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                completion()
            }

            sections.append(CPListSection(items: [exploreItem, nowPlayingItem]))

            if !jumpBackItems.isEmpty {
                sections.append(CPListSection(items: jumpBackItems, header: "Volver a escuchar", sectionIndexTitle: nil))
            }
            if !latestItems.isEmpty {
                sections.append(CPListSection(items: latestItems, header: "Últimos álbumes añadidos", sectionIndexTitle: nil))
            }
            if jumpBackItems.isEmpty && latestItems.isEmpty {
                let empty = CPListItem(text: "Sin contenido", detailText: "Reproduce algo en el iPhone primero", image: nil)
                sections.append(CPListSection(items: [empty]))
            }
            homeTemplate?.updateSections(sections)
        }
    }

    // MARK: - Offline Content

    private func loadOfflineContent() async {
        let cached = await OfflineContentProvider.shared.allCachedSongs()
        let songs = cached.map { $0.toNavidromeSong() }

        guard !songs.isEmpty else {
            await MainActor.run {
                let empty = CPListItem(text: "Sin canciones descargadas", detailText: "Descarga música desde el iPhone", image: nil)
                homeTemplate?.updateSections([CPListSection(items: [empty])])
                playlistsTemplate?.updateSections([CPListSection(items: [empty])])
            }
            return
        }

        // Home tab: "Descargas" as a playable list
        let playAllItem = CPListItem(
            text: "Reproducir todo (\(songs.count) canciones)",
            detailText: "Contenido descargado",
            image: UIImage(systemName: "play.fill"),
            accessoryImage: nil,
            accessoryType: .none
        )
        playAllItem.handler = { [weak self] _, completion in
            self?.playPlaylistSongs(songs, startIndex: 0)
            self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
            completion()
        }

        let shuffleItem = CPListItem(
            text: "Aleatorio",
            detailText: "\(songs.count) canciones descargadas",
            image: UIImage(systemName: "shuffle"),
            accessoryImage: nil,
            accessoryType: .none
        )
        shuffleItem.handler = { [weak self] _, completion in
            self?.playPlaylistSongs(songs.shuffled(), startIndex: 0)
            self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
            completion()
        }

        // Group by album
        let albums = await OfflineContentProvider.shared.cachedAlbums()
        var albumItems: [CPListItem] = []
        for album in albums {
            let item = CPListItem(
                text: album.name,
                detailText: "\(album.artist) · \(album.songCount) canciones",
                image: UIImage(systemName: "square.stack"),
                accessoryImage: nil,
                accessoryType: .disclosureIndicator
            )
            let albumSongs = songs.filter { $0.albumId == album.albumId }
            item.handler = { [weak self] _, completion in
                self?.showOfflineAlbum(name: album.name, songs: albumSongs)
                completion()
            }
            albumItems.append(item)
        }

        await MainActor.run {
            var homeSections: [CPListSection] = []
            homeSections.append(CPListSection(items: [playAllItem, shuffleItem], header: "Descargas", sectionIndexTitle: nil))
            if !albumItems.isEmpty {
                homeSections.append(CPListSection(items: albumItems, header: "Álbumes descargados", sectionIndexTitle: nil))
            }
            homeTemplate?.updateSections(homeSections)

            // Playlists tab: same offline info
            let offlineInfo = CPListItem(text: "Sin conexión", detailText: "Solo contenido descargado disponible", image: UIImage(systemName: "wifi.slash"))
            playlistsTemplate?.updateSections([CPListSection(items: [offlineInfo])])
        }
    }

    private func showOfflineAlbum(name: String, songs: [NavidromeSong]) {
        let songsTemplate = CPListTemplate(
            title: name,
            sections: [CPListSection(items: [])]
        )

        let playAllButton = CPBarButton(image: UIImage(systemName: "play.fill")!) { [weak self] _ in
            self?.playPlaylistSongs(songs, startIndex: 0)
            self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
        let shuffleButton = CPBarButton(image: UIImage(systemName: "shuffle")!) { [weak self] _ in
            self?.playPlaylistSongs(songs.shuffled(), startIndex: 0)
            self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
        songsTemplate.leadingNavigationBarButtons = [playAllButton]
        songsTemplate.trailingNavigationBarButtons = [shuffleButton]

        let songItems: [CPListItem] = songs.enumerated().map { index, song in
            let dur = Int(song.duration ?? 0)
            let detail = song.artist.isEmpty
                ? String(format: "%d:%02d", dur / 60, dur % 60)
                : String(format: "%@ · %d:%02d", song.artist, dur / 60, dur % 60)

            let item = CPListItem(
                text: song.title,
                detailText: detail,
                image: UIImage(systemName: "music.note"),
                accessoryImage: nil,
                accessoryType: .none
            )
            item.handler = { [weak self] _, completion in
                self?.playPlaylistSongs(songs, startIndex: index)
                self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                completion()
            }
            return item
        }

        songsTemplate.updateSections([CPListSection(items: songItems)])
        interfaceController?.pushTemplate(songsTemplate, animated: true, completion: nil)
    }

    // MARK: - Cover Art

    private func loadCover(artId: String?, completion: @escaping (UIImage?) -> Void) {
        guard let artId, let base = serverUrl() else {
            completion(nil)
            return
        }
        let urlStr = "\(base)/rest/getCoverArt.view?id=\(artId)&\(authQuery())&size=256"
        guard let url = URL(string: urlStr) else {
            completion(nil)
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = UIImage(data: data) else {
                completion(nil)
                return
            }
            completion(image)
        }.resume()
    }

    // MARK: - Detalle de Playlist

    private func showPlaylistSongs(playlistId: String, playlistName: String) {
        let loadingItem = CPListItem(text: "Cargando canciones...", detailText: nil, image: nil)
        let songsTemplate = CPListTemplate(
            title: playlistName,
            sections: [CPListSection(items: [loadingItem])]
        )

        let playAllButton = CPBarButton(image: UIImage(systemName: "play.fill")!) { [weak self] _ in
            self?.playPlaylist(id: playlistId, name: playlistName)
        }
        let shuffleButton = CPBarButton(image: UIImage(systemName: "shuffle")!) { [weak self] _ in
            self?.playPlaylistShuffled(id: playlistId, name: playlistName)
        }
        songsTemplate.leadingNavigationBarButtons = [playAllButton]
        songsTemplate.trailingNavigationBarButtons = [shuffleButton]

        interfaceController?.pushTemplate(songsTemplate, animated: true, completion: nil)

        Task {
            do {
                let (_, songs) = try await NavidromeService.shared.getPlaylistSongs(playlistId: playlistId)

                var songItems: [CPListItem] = []

                // SmartMix action row — only when backend is available
                let backendUp = await NavidromeService.shared.checkBackendAvailable()
                if backendUp {
                    let smartMixItem = CPListItem(
                        text: "SmartMix",
                        detailText: "Orden inteligente DJ",
                        image: UIImage(systemName: "wand.and.stars"),
                        accessoryImage: nil,
                        accessoryType: .disclosureIndicator
                    )
                    smartMixItem.handler = { [weak self] _, completion in
                        self?.playSmartMix(playlistId: playlistId, playlistName: playlistName, songs: songs)
                        completion()
                    }
                    songItems.append(smartMixItem)
                }

                for (index, song) in songs.enumerated() {
                    let dur = Int(song.duration ?? 0)
                    let mins = dur / 60
                    let secs = dur % 60
                    let detail = song.artist.isEmpty
                        ? String(format: "%d:%02d", mins, secs)
                        : String(format: "%@ · %d:%02d", song.artist, mins, secs)

                    let item = CPListItem(
                        text: song.title,
                        detailText: detail,
                        image: UIImage(systemName: "music.note"),
                        accessoryImage: nil,
                        accessoryType: .none
                    )
                    item.handler = { [weak self] _, completion in
                        self?.playPlaylistSongs(songs, startIndex: index)
                        self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                        completion()
                    }
                    songItems.append(item)
                }

                await MainActor.run {
                    if songs.isEmpty {
                        let empty = CPListItem(text: "Playlist vacía", detailText: nil, image: nil)
                        songsTemplate.updateSections([CPListSection(items: [empty])])
                    } else {
                        songsTemplate.updateSections([CPListSection(items: songItems)])
                    }
                }
            } catch {
                print("[CarPlay] Error cargando canciones: \(error)")
            }
        }
    }

    // MARK: - Detalle de Álbum

    private func showAlbumSongs(albumId: String, albumName: String) {
        let loadingItem = CPListItem(text: "Cargando canciones...", detailText: nil, image: nil)
        let songsTemplate = CPListTemplate(
            title: albumName,
            sections: [CPListSection(items: [loadingItem])]
        )

        let playAllButton = CPBarButton(image: UIImage(systemName: "play.fill")!) { [weak self] _ in
            self?.playAlbum(id: albumId)
        }
        let shuffleButton = CPBarButton(image: UIImage(systemName: "shuffle")!) { [weak self] _ in
            self?.playAlbumShuffled(id: albumId)
        }
        songsTemplate.leadingNavigationBarButtons = [playAllButton]
        songsTemplate.trailingNavigationBarButtons = [shuffleButton]

        interfaceController?.pushTemplate(songsTemplate, animated: true, completion: nil)

        Task {
            do {
                let (_, songs, _) = try await NavidromeService.shared.getAlbumDetail(albumId: albumId)

                let songItems: [CPListItem] = songs.enumerated().map { index, song in
                    let dur = Int(song.duration ?? 0)
                    let mins = dur / 60
                    let secs = dur % 60
                    let detail = song.artist.isEmpty
                        ? String(format: "%d:%02d", mins, secs)
                        : String(format: "%@ · %d:%02d", song.artist, mins, secs)

                    let item = CPListItem(
                        text: song.title,
                        detailText: detail,
                        image: UIImage(systemName: "music.note"),
                        accessoryImage: nil,
                        accessoryType: .none
                    )
                    item.handler = { [weak self] _, completion in
                        self?.playPlaylistSongs(songs, startIndex: index)
                        self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                        completion()
                    }
                    return item
                }

                await MainActor.run {
                    if songItems.isEmpty {
                        let empty = CPListItem(text: "Álbum vacío", detailText: nil, image: nil)
                        songsTemplate.updateSections([CPListSection(items: [empty])])
                    } else {
                        songsTemplate.updateSections([CPListSection(items: songItems)])
                    }
                }
            } catch {
                print("[CarPlay] Error cargando álbum: \(error)")
            }
        }
    }

    // MARK: - Reproducción (native)

    private func playPlaylist(id: String, name: String) {
        print("[CarPlay] Reproducir playlist: \(name)")
        Task {
            do {
                let (_, songs) = try await NavidromeService.shared.getPlaylistSongs(playlistId: id)
                await MainActor.run {
                    PlayerService.shared.playPlaylist(songs, contextUri: "playlist:\(id)", contextName: name)
                }
            } catch {
                print("[CarPlay] Error cargando playlist: \(error)")
            }
        }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func playPlaylistShuffled(id: String, name: String) {
        print("[CarPlay] Shuffle playlist: \(name)")
        Task {
            do {
                let (_, songs) = try await NavidromeService.shared.getPlaylistSongs(playlistId: id)
                await MainActor.run {
                    let shuffled = songs.shuffled()
                    PlayerService.shared.playPlaylist(shuffled, contextUri: "playlist:\(id)", contextName: name)
                }
            } catch {
                print("[CarPlay] Error cargando playlist: \(error)")
            }
        }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func playAlbum(id: String) {
        print("[CarPlay] Reproducir álbum: \(id)")
        Task {
            do {
                let (album, songs, _) = try await NavidromeService.shared.getAlbumDetail(albumId: id)
                await MainActor.run {
                    PlayerService.shared.playPlaylist(songs, contextUri: "album:\(id)", contextName: album?.name ?? "")
                }
            } catch {
                print("[CarPlay] Error cargando álbum: \(error)")
            }
        }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func playAlbumShuffled(id: String) {
        print("[CarPlay] Shuffle álbum: \(id)")
        Task {
            do {
                let (album, songs, _) = try await NavidromeService.shared.getAlbumDetail(albumId: id)
                await MainActor.run {
                    let shuffled = songs.shuffled()
                    PlayerService.shared.playPlaylist(shuffled, contextUri: "album:\(id)", contextName: album?.name ?? "")
                }
            } catch {
                print("[CarPlay] Error cargando álbum: \(error)")
            }
        }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func playSmartMix(playlistId: String, playlistName: String, songs: [NavidromeSong]) {
        print("[CarPlay] SmartMix playlist: \(playlistName)")
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        Task { @MainActor in
            SmartMixManager.shared.generate(playlistId: playlistId, songs: songs)
            // Wait for SmartMix to finish analyzing
            while SmartMixManager.shared.status == .analyzing {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if SmartMixManager.shared.status == .ready {
                PlayerService.shared.playSmartMix(playlistId: playlistId)
            } else {
                // Fallback: play in original order
                PlayerService.shared.playPlaylist(songs, contextUri: "playlist:\(playlistId)", contextName: playlistName)
            }
        }
    }

    private func playPlaylistSongs(_ songs: [NavidromeSong], startIndex: Int) {
        Task { @MainActor in
            PlayerService.shared.playPlaylist(songs, startingAt: startIndex)
        }
    }

    // MARK: - Explorar (browse)

    private func showExploreBrowser() {
        let artistsItem = CPListItem(
            text: "Artistas",
            detailText: "Explorar por artista",
            image: UIImage(systemName: "person.2.fill"),
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        artistsItem.handler = { [weak self] _, completion in
            self?.showAllArtists()
            completion()
        }

        let albumsItem = CPListItem(
            text: "Álbumes",
            detailText: "Explorar por álbum",
            image: UIImage(systemName: "square.stack.fill"),
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        albumsItem.handler = { [weak self] _, completion in
            self?.showAllAlbums()
            completion()
        }

        let genresItem = CPListItem(
            text: "Géneros",
            detailText: "Explorar por género",
            image: UIImage(systemName: "guitars.fill"),
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        genresItem.handler = { [weak self] _, completion in
            self?.showAllGenres()
            completion()
        }

        let randomItem = CPListItem(
            text: "Aleatorio",
            detailText: "Álbumes al azar",
            image: UIImage(systemName: "shuffle"),
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        randomItem.handler = { [weak self] _, completion in
            self?.showRandomAlbums()
            completion()
        }

        let exploreTemplate = CPListTemplate(
            title: "Explorar",
            sections: [CPListSection(items: [artistsItem, albumsItem, genresItem, randomItem])]
        )
        interfaceController?.pushTemplate(exploreTemplate, animated: true, completion: nil)
    }

    private func showAllArtists() {
        let loadingItem = CPListItem(text: "Cargando artistas...", detailText: nil, image: nil)
        let template = CPListTemplate(title: "Artistas", sections: [CPListSection(items: [loadingItem])])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)

        Task {
            guard let creds = NavidromeService.shared.credentials else { return }
            let urlStr = "\(creds.serverUrl)/rest/getArtists.view?\(authQuery())"
            guard let url = URL(string: urlStr) else { return }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let response = json["subsonic-response"] as? [String: Any],
                      let artistsObj = response["artists"] as? [String: Any] else { return }

                // Navidrome returns artists grouped by index letter
                let indices: [[String: Any]]
                if let arr = artistsObj["index"] as? [[String: Any]] { indices = arr }
                else if let single = artistsObj["index"] as? [String: Any] { indices = [single] }
                else { indices = [] }

                var sections: [CPListSection] = []
                for idx in indices {
                    let letter = idx["name"] as? String ?? ""
                    let artists: [[String: Any]]
                    if let arr = idx["artist"] as? [[String: Any]] { artists = arr }
                    else if let single = idx["artist"] as? [String: Any] { artists = [single] }
                    else { continue }

                    let items: [CPListItem] = artists.map { a in
                        let name = a["name"] as? String ?? ""
                        let id = a["id"] as? String ?? ""
                        let albumCount = a["albumCount"] as? Int ?? 0
                        let coverArt = a["coverArt"] as? String

                        let item = CPListItem(
                            text: name,
                            detailText: "\(albumCount) álbumes",
                            image: UIImage(systemName: "person.fill"),
                            accessoryImage: nil,
                            accessoryType: .disclosureIndicator
                        )
                        item.handler = { [weak self] _, completion in
                            self?.showArtistAlbums(artistId: id, artistName: name)
                            completion()
                        }
                        self.loadCover(artId: coverArt) { image in
                            if let image { DispatchQueue.main.async { item.setImage(image) } }
                        }
                        return item
                    }
                    sections.append(CPListSection(items: items, header: letter, sectionIndexTitle: letter))
                }

                await MainActor.run {
                    if sections.isEmpty {
                        let empty = CPListItem(text: "Sin artistas", detailText: nil, image: nil)
                        template.updateSections([CPListSection(items: [empty])])
                    } else {
                        template.updateSections(sections)
                    }
                }
            } catch {
                print("[CarPlay] Error cargando artistas: \(error)")
            }
        }
    }

    private func showAllAlbums() {
        let loadingItem = CPListItem(text: "Cargando álbumes...", detailText: nil, image: nil)
        let template = CPListTemplate(title: "Álbumes", sections: [CPListSection(items: [loadingItem])])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)

        Task {
            guard let creds = NavidromeService.shared.credentials else { return }
            let urlStr = "\(creds.serverUrl)/rest/getAlbumList2.view?\(authQuery())&type=alphabeticalByName&size=50"
            guard let url = URL(string: urlStr) else { return }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let response = json["subsonic-response"] as? [String: Any],
                      let albumList = response["albumList2"] as? [String: Any] else { return }

                let albums: [[String: Any]]
                if let arr = albumList["album"] as? [[String: Any]] { albums = arr }
                else if let single = albumList["album"] as? [String: Any] { albums = [single] }
                else { albums = [] }

                let items: [CPListItem] = albums.map { album in
                    let name = album["name"] as? String ?? ""
                    let id = album["id"] as? String ?? ""
                    let artist = album["artist"] as? String ?? ""
                    let coverArt = album["coverArt"] as? String

                    let item = CPListItem(
                        text: name,
                        detailText: artist,
                        image: UIImage(systemName: "square.stack"),
                        accessoryImage: nil,
                        accessoryType: .disclosureIndicator
                    )
                    item.handler = { [weak self] _, completion in
                        self?.showAlbumSongs(albumId: id, albumName: name)
                        completion()
                    }
                    self.loadCover(artId: coverArt) { image in
                        if let image { DispatchQueue.main.async { item.setImage(image) } }
                    }
                    return item
                }

                await MainActor.run {
                    if items.isEmpty {
                        let empty = CPListItem(text: "Sin álbumes", detailText: nil, image: nil)
                        template.updateSections([CPListSection(items: [empty])])
                    } else {
                        template.updateSections([CPListSection(items: items)])
                    }
                }
            } catch {
                print("[CarPlay] Error cargando álbumes: \(error)")
            }
        }
    }

    private func showAllGenres() {
        let loadingItem = CPListItem(text: "Cargando géneros...", detailText: nil, image: nil)
        let template = CPListTemplate(title: "Géneros", sections: [CPListSection(items: [loadingItem])])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)

        Task {
            guard let creds = NavidromeService.shared.credentials else { return }
            let urlStr = "\(creds.serverUrl)/rest/getGenres.view?\(authQuery())"
            guard let url = URL(string: urlStr) else { return }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let response = json["subsonic-response"] as? [String: Any],
                      let genresObj = response["genres"] as? [String: Any] else { return }

                let genres: [[String: Any]]
                if let arr = genresObj["genre"] as? [[String: Any]] { genres = arr }
                else if let single = genresObj["genre"] as? [String: Any] { genres = [single] }
                else { genres = [] }

                // Sort by song count descending
                let sorted = genres.sorted {
                    ($0["songCount"] as? Int ?? 0) > ($1["songCount"] as? Int ?? 0)
                }

                let items: [CPListItem] = sorted.prefix(40).map { genre in
                    let name = genre["value"] as? String ?? ""
                    let songCount = genre["songCount"] as? Int ?? 0
                    let albumCount = genre["albumCount"] as? Int ?? 0

                    let item = CPListItem(
                        text: name,
                        detailText: "\(albumCount) álbumes · \(songCount) canciones",
                        image: UIImage(systemName: "guitars.fill"),
                        accessoryImage: nil,
                        accessoryType: .disclosureIndicator
                    )
                    item.handler = { [weak self] _, completion in
                        self?.showGenreAlbums(genre: name)
                        completion()
                    }
                    return item
                }

                await MainActor.run {
                    if items.isEmpty {
                        let empty = CPListItem(text: "Sin géneros", detailText: nil, image: nil)
                        template.updateSections([CPListSection(items: [empty])])
                    } else {
                        template.updateSections([CPListSection(items: items)])
                    }
                }
            } catch {
                print("[CarPlay] Error cargando géneros: \(error)")
            }
        }
    }

    private func showGenreAlbums(genre: String) {
        let loadingItem = CPListItem(text: "Cargando...", detailText: nil, image: nil)
        let template = CPListTemplate(title: genre, sections: [CPListSection(items: [loadingItem])])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)

        Task {
            guard let creds = NavidromeService.shared.credentials else { return }
            let encoded = genre.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let urlStr = "\(creds.serverUrl)/rest/getAlbumList2.view?\(authQuery())&type=byGenre&genre=\(encoded)&size=40"
            guard let url = URL(string: urlStr) else { return }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let response = json["subsonic-response"] as? [String: Any],
                      let albumList = response["albumList2"] as? [String: Any] else { return }

                let albums: [[String: Any]]
                if let arr = albumList["album"] as? [[String: Any]] { albums = arr }
                else if let single = albumList["album"] as? [String: Any] { albums = [single] }
                else { albums = [] }

                let items: [CPListItem] = albums.map { album in
                    let name = album["name"] as? String ?? ""
                    let id = album["id"] as? String ?? ""
                    let artist = album["artist"] as? String ?? ""
                    let coverArt = album["coverArt"] as? String

                    let item = CPListItem(
                        text: name,
                        detailText: artist,
                        image: UIImage(systemName: "square.stack"),
                        accessoryImage: nil,
                        accessoryType: .disclosureIndicator
                    )
                    item.handler = { [weak self] _, completion in
                        self?.showAlbumSongs(albumId: id, albumName: name)
                        completion()
                    }
                    self.loadCover(artId: coverArt) { image in
                        if let image { DispatchQueue.main.async { item.setImage(image) } }
                    }
                    return item
                }

                await MainActor.run {
                    if items.isEmpty {
                        let empty = CPListItem(text: "Sin álbumes", detailText: nil, image: nil)
                        template.updateSections([CPListSection(items: [empty])])
                    } else {
                        template.updateSections([CPListSection(items: items)])
                    }
                }
            } catch {
                print("[CarPlay] Error cargando género: \(error)")
            }
        }
    }

    private func showRandomAlbums() {
        let loadingItem = CPListItem(text: "Cargando...", detailText: nil, image: nil)
        let template = CPListTemplate(title: "Aleatorio", sections: [CPListSection(items: [loadingItem])])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)

        Task {
            guard let creds = NavidromeService.shared.credentials else { return }
            let urlStr = "\(creds.serverUrl)/rest/getAlbumList2.view?\(authQuery())&type=random&size=25"
            guard let url = URL(string: urlStr) else { return }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let response = json["subsonic-response"] as? [String: Any],
                      let albumList = response["albumList2"] as? [String: Any] else { return }

                let albums: [[String: Any]]
                if let arr = albumList["album"] as? [[String: Any]] { albums = arr }
                else if let single = albumList["album"] as? [String: Any] { albums = [single] }
                else { albums = [] }

                let items: [CPListItem] = albums.map { album in
                    let name = album["name"] as? String ?? ""
                    let id = album["id"] as? String ?? ""
                    let artist = album["artist"] as? String ?? ""
                    let coverArt = album["coverArt"] as? String

                    let item = CPListItem(
                        text: name,
                        detailText: artist,
                        image: UIImage(systemName: "square.stack"),
                        accessoryImage: nil,
                        accessoryType: .disclosureIndicator
                    )
                    item.handler = { [weak self] _, completion in
                        self?.showAlbumSongs(albumId: id, albumName: name)
                        completion()
                    }
                    self.loadCover(artId: coverArt) { image in
                        if let image { DispatchQueue.main.async { item.setImage(image) } }
                    }
                    return item
                }

                await MainActor.run {
                    if items.isEmpty {
                        let empty = CPListItem(text: "Sin álbumes", detailText: nil, image: nil)
                        template.updateSections([CPListSection(items: [empty])])
                    } else {
                        template.updateSections([CPListSection(items: items)])
                    }
                }
            } catch {
                print("[CarPlay] Error cargando aleatorio: \(error)")
            }
        }
    }

    // MARK: - Artist Albums (drill-down)

    private func showArtistAlbums(artistId: String, artistName: String) {
        let loadingItem = CPListItem(text: "Cargando álbumes...", detailText: nil, image: nil)
        let artistTemplate = CPListTemplate(
            title: artistName,
            sections: [CPListSection(items: [loadingItem])]
        )
        interfaceController?.pushTemplate(artistTemplate, animated: true, completion: nil)

        Task {
            guard let creds = NavidromeService.shared.credentials else { return }
            let urlStr = "\(creds.serverUrl)/rest/getArtist.view?\(authQuery())&id=\(artistId)"
            guard let url = URL(string: urlStr) else { return }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let response = json["subsonic-response"] as? [String: Any],
                      let artistObj = response["artist"] as? [String: Any] else { return }

                let albumsArr: [[String: Any]]
                if let arr = artistObj["album"] as? [[String: Any]] { albumsArr = arr }
                else if let single = artistObj["album"] as? [String: Any] { albumsArr = [single] }
                else { albumsArr = [] }

                var items: [CPListItem] = []
                for album in albumsArr {
                    let name = album["name"] as? String ?? ""
                    let id = album["id"] as? String ?? ""
                    let year = album["year"] as? Int
                    let coverArt = album["coverArt"] as? String

                    let item = CPListItem(
                        text: name,
                        detailText: year != nil ? "\(year!)" : nil,
                        image: UIImage(systemName: "square.stack"),
                        accessoryImage: nil,
                        accessoryType: .disclosureIndicator
                    )
                    item.handler = { [weak self] _, completion in
                        self?.showAlbumSongs(albumId: id, albumName: name)
                        completion()
                    }
                    loadCover(artId: coverArt) { image in
                        if let image { DispatchQueue.main.async { item.setImage(image) } }
                    }
                    items.append(item)
                }

                await MainActor.run {
                    if items.isEmpty {
                        let empty = CPListItem(text: "Sin álbumes", detailText: nil, image: nil)
                        artistTemplate.updateSections([CPListSection(items: [empty])])
                    } else {
                        artistTemplate.updateSections([CPListSection(items: items)])
                    }
                }
            } catch {
                print("[CarPlay] Error cargando artista: \(error)")
            }
        }
    }

    // MARK: - CPNowPlayingTemplateObserver

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard let song = QueueManager.shared.currentSong else { return }

        // Show menu with options to go to artist or album
        let artistItem = CPListItem(
            text: song.artist.isEmpty ? "Artista desconocido" : song.artist,
            detailText: "Ver todos los álbumes",
            image: UIImage(systemName: "person.fill"),
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        artistItem.handler = { [weak self] _, completion in
            guard !song.artistId.isEmpty else { completion(); return }
            self?.showArtistAlbums(artistId: song.artistId, artistName: song.artist)
            completion()
        }

        let albumItem = CPListItem(
            text: song.album.isEmpty ? "Álbum desconocido" : song.album,
            detailText: "Ver canciones del álbum",
            image: UIImage(systemName: "square.stack"),
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        albumItem.handler = { [weak self] _, completion in
            guard !song.albumId.isEmpty else { completion(); return }
            self?.showAlbumSongs(albumId: song.albumId, albumName: song.album)
            completion()
        }

        let menuTemplate = CPListTemplate(
            title: "Reproduciendo",
            sections: [CPListSection(items: [artistItem, albumItem])]
        )
        interfaceController?.pushTemplate(menuTemplate, animated: true, completion: nil)
    }

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        let queue = QueueManager.shared.queue
        let currentIdx = QueueManager.shared.currentIndex
        let upcoming = Array(queue.dropFirst(currentIdx + 1))

        guard !upcoming.isEmpty else {
            let emptyTemplate = CPListTemplate(
                title: "Siguiente",
                sections: [CPListSection(items: [
                    CPListItem(text: "No hay más canciones", detailText: nil, image: nil)
                ])]
            )
            interfaceController?.pushTemplate(emptyTemplate, animated: true, completion: nil)
            return
        }

        let items: [CPListItem] = upcoming.prefix(20).enumerated().map { index, song in
            let dur = Int(song.duration)
            let detail = song.artist.isEmpty
                ? String(format: "%d:%02d", dur / 60, dur % 60)
                : String(format: "%@ · %d:%02d", song.artist, dur / 60, dur % 60)

            let item = CPListItem(
                text: song.title,
                detailText: detail,
                image: UIImage(systemName: "music.note"),
                accessoryImage: nil,
                accessoryType: .none
            )
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    let currentQueue = QueueManager.shared.queue
                    let targetIndex = currentIdx + 1 + index
                    QueueManager.shared.play(queue: currentQueue, startIndex: targetIndex)
                }
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
                completion()
            }
            return item
        }

        let upNextTemplate = CPListTemplate(
            title: "Siguiente",
            sections: [CPListSection(items: items)]
        )
        interfaceController?.pushTemplate(upNextTemplate, animated: true, completion: nil)
    }
}
