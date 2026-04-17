import UIKit
import CarPlay
import MediaPlayer

/// Scene delegate para CarPlay Audio.
/// Tab bar con Inicio + Playlists + Now Playing.
@objc(CarPlaySceneDelegate)
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

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

        let nowPlayingBarButton = CPBarButton(image: UIImage(systemName: "play.circle")!) { [weak self] _ in
            self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }

        // Tab 1: Inicio
        let homeList = CPListTemplate(title: "Inicio", sections: [
            CPListSection(items: [CPListItem(text: "Cargando...", detailText: nil, image: nil)])
        ])
        homeList.tabTitle = "Inicio"
        homeList.tabImage = UIImage(systemName: "house.fill")
        homeList.trailingNavigationBarButtons = [nowPlayingBarButton]
        self.homeTemplate = homeList

        // Tab 2: Playlists
        let plistList = CPListTemplate(title: "Playlists", sections: [
            CPListSection(items: [
                CPListItem(text: "Cargando playlists...", detailText: "Inicia sesión en el iPhone si es necesario", image: nil)
            ])
        ])
        plistList.tabTitle = "Playlists"
        plistList.tabImage = UIImage(systemName: "music.note.list")
        plistList.trailingNavigationBarButtons = [nowPlayingBarButton]
        self.playlistsTemplate = plistList

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
            await loadPlaylists()
            await loadHomeContent()
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

    private func loadPlaylists() async {
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

                let normalizedName = name.lowercased().trimmingCharacters(in: .whitespaces)
                let isSmartPlaylist = comment.contains("Smart Playlist")
                let isDailyMix = normalizedName.hasPrefix("mix diario")
                let isEditorial = comment.contains("[Editorial]")
                let isSpotify = normalizedName.hasPrefix("[spotify] ") || comment.contains("Spotify Synced")

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

                loadCover(artId: coverArt) { image in
                    if let image { DispatchQueue.main.async { item.setImage(image) } }
                }

                if isDailyMix { dailyItems.append(item) }
                else if isSmartPlaylist { smartItems.append(item) }
                else if isEditorial || isSpotify { editorialItems.append(item) }
                else { myItems.append(item) }
            }

            var sections: [CPListSection] = []
            if !myItems.isEmpty      { sections.append(CPListSection(items: myItems,      header: "Mis Playlists",   sectionIndexTitle: nil)) }
            if !smartItems.isEmpty   { sections.append(CPListSection(items: smartItems,   header: "Hecho para ti",   sectionIndexTitle: nil)) }
            if !dailyItems.isEmpty   { sections.append(CPListSection(items: dailyItems,   header: "Mixes diarios",   sectionIndexTitle: nil)) }
            if !editorialItems.isEmpty { sections.append(CPListSection(items: editorialItems, header: "Mixes & Radio", sectionIndexTitle: nil)) }

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

    private func loadHomeContent() async {
        guard let creds = NavidromeService.shared.credentials else { return }

        var jumpBackItems: [CPListItem] = []
        var latestItems: [CPListItem] = []

        // 1. Jump Back In (backend)
        if let backendUrl = NavidromeService.shared.backendURL() {
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
                            self?.playAlbum(id: id)
                            completion()
                        }
                        loadCover(artId: coverArtId) { image in
                            if let image { DispatchQueue.main.async { item.setImage(image) } }
                        }
                    } else {
                        item.handler = { [weak self] _, completion in
                            self?.playPlaylist(id: id, name: title)
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
                    self?.playAlbum(id: id)
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
            if !jumpBackItems.isEmpty {
                sections.append(CPListSection(items: jumpBackItems, header: "Volver a escuchar", sectionIndexTitle: nil))
            }
            if !latestItems.isEmpty {
                sections.append(CPListSection(items: latestItems, header: "Últimos álbumes añadidos", sectionIndexTitle: nil))
            }
            if sections.isEmpty {
                let empty = CPListItem(text: "Sin contenido", detailText: "Reproduce algo en el iPhone primero", image: nil)
                sections = [CPListSection(items: [empty])]
            }
            homeTemplate?.updateSections(sections)
        }
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
        songsTemplate.leadingNavigationBarButtons = [playAllButton]

        interfaceController?.pushTemplate(songsTemplate, animated: true, completion: nil)

        Task {
            do {
                let (_, songs) = try await NavidromeService.shared.getPlaylistSongs(playlistId: playlistId)

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

    // MARK: - Reproducción (native)

    private func playPlaylist(id: String, name: String) {
        print("[CarPlay] Reproducir playlist: \(name)")
        Task {
            do {
                let (_, songs) = try await NavidromeService.shared.getPlaylistSongs(playlistId: id)
                await MainActor.run {
                    QueueManager.shared.play(songs: songs, startIndex: 0)
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
                let (_, songs, _) = try await NavidromeService.shared.getAlbumDetail(albumId: id)
                await MainActor.run {
                    QueueManager.shared.play(songs: songs, startIndex: 0)
                }
            } catch {
                print("[CarPlay] Error cargando álbum: \(error)")
            }
        }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func playPlaylistSongs(_ songs: [NavidromeSong], startIndex: Int) {
        Task { @MainActor in
            QueueManager.shared.play(songs: songs, startIndex: startIndex)
        }
    }
}
