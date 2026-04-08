import UIKit
import CarPlay
import MediaPlayer

/// Configuración de conexión a Navidrome (leída del localStorage del WebView)
private struct NavidromeConfig: Codable {
    let serverUrl: String
    let username: String
    let token: String?
    let password: String?
}

/// Scene delegate para CarPlay Audio.
/// Tab bar con Playlists + Now Playing.
@objc(CarPlaySceneDelegate)
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    var interfaceController: CPInterfaceController?
    private var homeTemplate: CPListTemplate?
    private var playlistsTemplate: CPListTemplate?
    private var navidromeConfig: NavidromeConfig?
    private var backendBaseUrl: String?

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

        fetchConfigAndLoadPlaylists()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        self.interfaceController = nil
        self.navidromeConfig = nil
        self.backendBaseUrl = nil
        print("[CarPlay] Desconectado")
    }

    // MARK: - Config

    /// Lee la configuración de Navidrome y la URL del backend del WKWebView.
    private func fetchConfigAndLoadPlaylists() {
        DispatchQueue.main.async { [weak self] in
            guard let appDelegate = UIApplication.shared.delegate as? AppDelegate,
                  let webView = appDelegate.webViewRef else {
                print("[CarPlay] No hay webView — reintentando en 2s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.fetchConfigAndLoadPlaylists()
                }
                return
            }

            // Leer Navidrome config y backend URL en paralelo
            let js = """
            JSON.stringify({
                navidrome: localStorage.getItem('navidromeConfig'),
                backendUrl: window.__AUDIORR_BACKEND_URL__ || null
            })
            """

            webView.evaluateJavaScript(js) { [weak self] result, error in
                guard let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    print("[CarPlay] Error leyendo config: \(error?.localizedDescription ?? "nil")")
                    return
                }

                // Guardar backend URL (necesario para covers)
                self?.backendBaseUrl = wrapper["backendUrl"] as? String
                print("[CarPlay] backendBaseUrl=\(self?.backendBaseUrl ?? "nil")")

                if let navString = wrapper["navidrome"] as? String,
                   let navData = navString.data(using: .utf8),
                   let config = try? JSONDecoder().decode(NavidromeConfig.self, from: navData) {
                    self?.navidromeConfig = config
                    print("[CarPlay] Navidrome config ok")
                    self?.loadPlaylists()
                    self?.loadHomeContent()
                } else {
                    print("[CarPlay] No hay configuración de Navidrome — ¿usuario inició sesión?")
                    let placeholder = CPListItem(text: "Inicia sesión en el iPhone", detailText: "Configura tu servidor en la app", image: nil)
                    self?.playlistsTemplate?.updateSections([CPListSection(items: [placeholder])])
                }
            }
        }
    }

    /// Genera los parámetros de autenticación para la API Subsonic.
    private func authParams() -> String {
        guard let c = navidromeConfig else { return "" }
        let token = c.token ?? c.password ?? ""
        let u = c.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let p = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "u=\(u)&p=\(p)&v=1.16.0&c=audiorr&f=json"
    }

    // MARK: - Cargar Playlists

    private func loadPlaylists() {
        guard let config = navidromeConfig else {
            print("[CarPlay] loadPlaylists: navidromeConfig es nil")
            return
        }

        print("[CarPlay] serverUrl=\(config.serverUrl) username=\(config.username) hasToken=\(config.token != nil) hasPassword=\(config.password != nil)")

        let urlStr = "\(config.serverUrl)/rest/getPlaylists.view?\(authParams())"
        print("[CarPlay] GET \(urlStr)")
        guard let url = URL(string: urlStr) else {
            print("[CarPlay] URL inválida: \(urlStr)")
            DispatchQueue.main.async { [weak self] in
                let errItem = CPListItem(text: "URL inválida", detailText: urlStr, image: nil)
                self?.playlistsTemplate?.updateSections([CPListSection(items: [errItem])])
            }
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                print("[CarPlay] Error de red: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    let errItem = CPListItem(text: "Error de red", detailText: error.localizedDescription, image: nil)
                    self.playlistsTemplate?.updateSections([CPListSection(items: [errItem])])
                }
                return
            }

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[CarPlay] HTTP \(httpStatus), data=\(data?.count ?? 0) bytes")

            guard let data = data else {
                print("[CarPlay] Sin datos en la respuesta")
                DispatchQueue.main.async {
                    let errItem = CPListItem(text: "Sin respuesta", detailText: "El servidor no devolvió datos", image: nil)
                    self.playlistsTemplate?.updateSections([CPListSection(items: [errItem])])
                }
                return
            }

            // Log raw response for debugging
            if let raw = String(data: data.prefix(500), encoding: .utf8) {
                print("[CarPlay] Respuesta (primeros 500 chars): \(raw)")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["subsonic-response"] as? [String: Any]
            else {
                print("[CarPlay] Error parseando respuesta de playlists")
                DispatchQueue.main.async {
                    let errItem = CPListItem(text: "Error cargando playlists", detailText: "Respuesta inesperada del servidor", image: nil)
                    self.playlistsTemplate?.updateSections([CPListSection(items: [errItem])])
                }
                return
            }

            // Comprobar error de autenticación u otros errores Subsonic
            if let status = response["status"] as? String, status != "ok" {
                let errorMsg = (response["error"] as? [String: Any])?["message"] as? String ?? "Error desconocido"
                print("[CarPlay] Error Subsonic: \(errorMsg)")
                DispatchQueue.main.async {
                    let errItem = CPListItem(text: "Error de acceso", detailText: errorMsg, image: nil)
                    self.playlistsTemplate?.updateSections([CPListSection(items: [errItem])])
                }
                return
            }

            let playlistsObj = response["playlists"] as? [String: Any] ?? [:]

            // La API devuelve array si hay >1, diccionario si hay exactamente 1, nada si hay 0
            let playlistArr: [[String: Any]]
            if let arr = playlistsObj["playlist"] as? [[String: Any]] {
                playlistArr = arr
            } else if let single = playlistsObj["playlist"] as? [String: Any] {
                playlistArr = [single]
            } else {
                // Sin playlists
                print("[CarPlay] No hay playlists")
                DispatchQueue.main.async {
                    let emptyItem = CPListItem(text: "Sin playlists", detailText: "Crea una playlist en tu servidor", image: nil)
                    self.playlistsTemplate?.updateSections([CPListSection(items: [emptyItem])])
                }
                return
            }

            let username = config.username

            // Mismas categorías que PlaylistsPage.tsx
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

                self.loadPlaylistCover(playlistId: id, navidromeCoverArtId: coverArt) { image in
                    if let image = image {
                        DispatchQueue.main.async { item.setImage(image) }
                    }
                }

                if isDailyMix {
                    dailyItems.append(item)
                } else if isSmartPlaylist {
                    smartItems.append(item)
                } else if isEditorial || isSpotify {
                    editorialItems.append(item)
                } else {
                    myItems.append(item)
                }
            }

            var sections: [CPListSection] = []
            if !myItems.isEmpty      { sections.append(CPListSection(items: myItems,      header: "Mis Playlists",   sectionIndexTitle: nil)) }
            if !smartItems.isEmpty   { sections.append(CPListSection(items: smartItems,   header: "Hecho para ti",   sectionIndexTitle: nil)) }
            if !dailyItems.isEmpty   { sections.append(CPListSection(items: dailyItems,   header: "Mixes diarios",   sectionIndexTitle: nil)) }
            if !editorialItems.isEmpty { sections.append(CPListSection(items: editorialItems, header: "Mixes & Radio", sectionIndexTitle: nil)) }

            if sections.isEmpty {
                let emptyItem = CPListItem(text: "Sin playlists", detailText: "Crea una playlist en tu servidor", image: nil)
                sections = [CPListSection(items: [emptyItem])]
            }

            let total = myItems.count + smartItems.count + dailyItems.count + editorialItems.count
            DispatchQueue.main.async {
                self.playlistsTemplate?.updateSections(sections)
                print("[CarPlay] \(total) playlists en \(sections.count) secciones")
            }
        }.resume()
    }

    // MARK: - Home Content

    /// Carga "Volver a escuchar" (backend) + "Últimos álbumes" (Navidrome) para la pestaña Inicio.
    private func loadHomeContent() {
        guard let config = navidromeConfig else { return }

        let group = DispatchGroup()
        var jumpBackItems: [CPListItem] = []
        var latestItems: [CPListItem] = []

        // ── 1. Jump Back In (solo si hay backend) ──────────────────────────
        if let backendUrl = backendBaseUrl {
            group.enter()
            let jbiUrl = URL(string: "\(backendUrl)/api/stats/recent-contexts?username=\(config.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!
            URLSession.shared.dataTask(with: jbiUrl) { [weak self] data, _, _ in
                defer { group.leave() }
                guard let self = self,
                      let data = data,
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                else { return }

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
                        // Cover desde Navidrome
                        if let artId = coverArtId {
                            self.loadNavidromeCover(artId: artId, completion: { image in
                                if let image = image { DispatchQueue.main.async { item.setImage(image) } }
                            })
                        }
                    } else {
                        item.handler = { [weak self] _, completion in
                            self?.playPlaylist(id: id, name: title)
                            completion()
                        }
                        // Cover desde backend
                        let coverUrlStr = "\(backendUrl)/api/playlists/\(id)/cover.png"
                        if let coverUrl = URL(string: coverUrlStr) {
                            URLSession.shared.dataTask(with: coverUrl) { data, response, _ in
                                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                                if ok, let data = data, let image = UIImage(data: data) {
                                    DispatchQueue.main.async { item.setImage(image) }
                                }
                            }.resume()
                        }
                    }

                    jumpBackItems.append(item)
                }
            }.resume()
        }

        // ── 2. Últimos álbumes añadidos (Navidrome newest) ─────────────────
        group.enter()
        let albumsUrlStr = "\(config.serverUrl)/rest/getAlbumList2.view?\(authParams())&type=newest&size=15"
        if let albumsUrl = URL(string: albumsUrlStr) {
            URLSession.shared.dataTask(with: albumsUrl) { [weak self] data, _, _ in
                defer { group.leave() }
                guard let self = self,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let response = json["subsonic-response"] as? [String: Any],
                      let albumList = response["albumList2"] as? [String: Any]
                else { return }

                let albums: [[String: Any]]
                if let arr = albumList["album"] as? [[String: Any]] { albums = arr }
                else if let single = albumList["album"] as? [String: Any] { albums = [single] }
                else { return }

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
                    if let artId = coverArt {
                        self.loadNavidromeCover(artId: artId, completion: { image in
                            if let image = image { DispatchQueue.main.async { item.setImage(image) } }
                        })
                    }
                    latestItems.append(item)
                }
            }.resume()
        } else {
            group.leave()
        }

        // ── Actualizar homeTemplate cuando ambas cargas terminen ───────────
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
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
            self.homeTemplate?.updateSections(sections)
            print("[CarPlay] Home: \(jumpBackItems.count) JBI + \(latestItems.count) álbumes")
        }
    }

    // MARK: - Cover Art

    /// Carga la portada de una playlist.
    /// Prioridad: 1) Backend Audiorr  2) Navidrome (fallback)
    private func loadPlaylistCover(playlistId: String, navidromeCoverArtId: String?, completion: @escaping (UIImage?) -> Void) {
        // 1) Intentar backend Audiorr
        if let backendUrl = backendBaseUrl {
            let backendCoverUrl = "\(backendUrl)/api/playlists/\(playlistId)/cover.png"
            guard let url = URL(string: backendCoverUrl) else {
                loadNavidromeCover(artId: navidromeCoverArtId, completion: completion)
                return
            }

            URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
                if httpStatus == 200, let data = data, let image = UIImage(data: data) {
                    completion(image)
                } else {
                    // 2) Fallback a Navidrome
                    self?.loadNavidromeCover(artId: navidromeCoverArtId, completion: completion)
                }
            }.resume()
            return
        }

        // Sin backend disponible → directo a Navidrome
        loadNavidromeCover(artId: navidromeCoverArtId, completion: completion)
    }

    /// Fallback: carga cover art desde Navidrome.
    private func loadNavidromeCover(artId: String?, completion: @escaping (UIImage?) -> Void) {
        guard let artId = artId, let config = navidromeConfig else {
            completion(nil)
            return
        }
        let urlStr = "\(config.serverUrl)/rest/getCoverArt.view?id=\(artId)&\(authParams())&size=256"
        guard let url = URL(string: urlStr) else {
            completion(nil)
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let image = UIImage(data: data) else {
                completion(nil)
                return
            }
            completion(image)
        }.resume()
    }

    // MARK: - Detalle de Playlist (canciones)

    /// Muestra las canciones de una playlist como sub-template de CarPlay.
    private func showPlaylistSongs(playlistId: String, playlistName: String) {
        guard let config = navidromeConfig else { return }

        // Pantalla de carga mientras se buscan las canciones
        let loadingItem = CPListItem(text: "Cargando canciones...", detailText: nil, image: nil)
        let songsTemplate = CPListTemplate(
            title: playlistName,
            sections: [CPListSection(items: [loadingItem])]
        )

        let playAllButton = CPBarButton(image: UIImage(systemName: "play.fill")!) { [weak self] _ in
            self?.playPlaylist(id: playlistId, name: playlistName)
        }
        songsTemplate.leadingNavigationBarButtons = [playAllButton]

        // Botón SmartMix (solo si hay backend disponible)
        if backendBaseUrl != nil {
            let smartMixButton = CPBarButton(image: UIImage(systemName: "sparkles")!) { [weak self] _ in
                self?.dispatchToWebView("""
                    window.dispatchEvent(new CustomEvent('_carplaySmartMix', {
                        detail: { playlistId: '\(playlistId)' }
                    }))
                    """)
                self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
            }
            songsTemplate.trailingNavigationBarButtons = [smartMixButton]
        }

        interfaceController?.pushTemplate(songsTemplate, animated: true, completion: nil)

        let urlStr = "\(config.serverUrl)/rest/getPlaylist.view?\(authParams())&id=\(playlistId)"
        guard let url = URL(string: urlStr) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["subsonic-response"] as? [String: Any],
                  let playlist = response["playlist"] as? [String: Any]
            else { return }

            let entries: [[String: Any]]
            if let arr = playlist["entry"] as? [[String: Any]] { entries = arr }
            else if let single = playlist["entry"] as? [String: Any] { entries = [single] }
            else { entries = [] }

            var songItems: [CPListItem] = []
            for (index, entry) in entries.enumerated() {
                let title  = entry["title"]  as? String ?? "Sin título"
                let artist = entry["artist"] as? String ?? ""
                let songId = entry["id"]     as? String ?? ""
                let durationSec = entry["duration"] as? Int ?? 0
                let mins = durationSec / 60
                let secs = durationSec % 60
                let durationStr = artist.isEmpty ? String(format: "%d:%02d", mins, secs)
                                                 : String(format: "%@ · %d:%02d", artist, mins, secs)

                let item = CPListItem(
                    text: title,
                    detailText: durationStr,
                    image: UIImage(systemName: "music.note"),
                    accessoryImage: nil,
                    accessoryType: .none
                )
                let capturedIndex = index
                let capturedSongId = songId
                item.handler = { [weak self] _, completion in
                    self?.dispatchToWebView("""
                        window.dispatchEvent(new CustomEvent('_carplayPlayPlaylistFromSong', {
                            detail: { playlistId: '\(playlistId)', songId: '\(capturedSongId)', songIndex: \(capturedIndex) }
                        }))
                        """)
                    self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                    completion()
                }
                songItems.append(item)
            }

            DispatchQueue.main.async {
                if songItems.isEmpty {
                    let empty = CPListItem(text: "Playlist vacía", detailText: nil, image: nil)
                    songsTemplate.updateSections([CPListSection(items: [empty])])
                } else {
                    songsTemplate.updateSections([CPListSection(items: songItems)])
                }
            }
        }.resume()
    }

    // MARK: - Reproducción

    private func playPlaylist(id: String, name: String) {
        print("[CarPlay] Reproducir playlist: \(name)")
        dispatchToWebView("window.dispatchEvent(new CustomEvent('_carplayPlayPlaylist', { detail: { playlistId: '\(id)' } }))")
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func playAlbum(id: String) {
        print("[CarPlay] Reproducir álbum: \(id)")
        dispatchToWebView("window.dispatchEvent(new CustomEvent('_carplayPlayAlbum', { detail: { albumId: '\(id)' } }))")
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func dispatchToWebView(_ js: String) {
        DispatchQueue.main.async {
            guard let appDelegate = UIApplication.shared.delegate as? AppDelegate,
                  let webView = appDelegate.webViewRef else { return }
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
