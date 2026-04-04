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

        // Botón 1: Playlists
        let playlistsGridButton = CPGridButton(titleVariants: ["Playlists"], image: UIImage(systemName: "music.note.list")!) { [weak self] _ in
            guard let self = self, let plist = self.playlistsTemplate else { return }
            self.interfaceController?.pushTemplate(plist, animated: true, completion: nil)
        }

        // Botón 2: Ahora suena
        let nowPlayingGridButton = CPGridButton(titleVariants: ["Ahora Suena"], image: UIImage(systemName: "play.circle.fill")!) { [weak self] _ in
            self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }

        // Home: Grid Menú (Premium Look)
        let homeGrid = CPGridTemplate(title: "Audiorr", gridButtons: [playlistsGridButton, nowPlayingGridButton])
        
        // Botón de navegación para el reproductor (siempre visible arriba a la derecha)
        let nowPlayingBarButton = CPBarButton(image: UIImage(systemName: "play.circle")!) { [weak self] _ in
            self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }

        // La lista de playlists real se prepara como sub-template
        let plistList = CPListTemplate(title: "Playlists", sections: [
            CPListSection(items: [
                CPListItem(text: "Cargando playlists...", detailText: "Inicia sesión en el iPhone si es necesario", image: nil)
            ])
        ])
        plistList.trailingNavigationBarButtons = [nowPlayingBarButton]
        self.playlistsTemplate = plistList

        interfaceController.setRootTemplate(homeGrid, animated: true, completion: nil)

        // Cargar config y playlists
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

                if let navString = wrapper["navidrome"] as? String,
                   let navData = navString.data(using: .utf8),
                   let config = try? JSONDecoder().decode(NavidromeConfig.self, from: navData) {
                    self?.navidromeConfig = config
                    print("[CarPlay] Navidrome config ok")
                    self?.loadPlaylists()
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
        guard let config = navidromeConfig else { return }

        let urlStr = "\(config.serverUrl)/rest/getPlaylists.view?\(authParams())"
        guard let url = URL(string: urlStr) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self, let data = data else {
                print("[CarPlay] Error cargando playlists: \(error?.localizedDescription ?? "")")
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["subsonic-response"] as? [String: Any],
                  let playlistsObj = response["playlists"] as? [String: Any],
                  let playlistArr = playlistsObj["playlist"] as? [[String: Any]]
            else {
                print("[CarPlay] Error parseando respuesta de playlists")
                return
            }

            let username = config.username
            var items: [CPListItem] = []

            for p in playlistArr {
                let name = p["name"] as? String ?? ""
                let id = p["id"] as? String ?? ""
                let songCount = p["songCount"] as? Int ?? 0
                let coverArt = p["coverArt"] as? String
                let comment = p["comment"] as? String ?? ""
                let owner = p["owner"] as? String ?? ""

                // Solo playlists del usuario, sin smart/editorial/daily/spotify
                let normalizedName = name.lowercased().trimmingCharacters(in: .whitespaces)
                let isSmartPlaylist = comment.contains("Smart Playlist")
                let isEditorial = comment.contains("[Editorial]")
                let isDailyMix = normalizedName.hasPrefix("mix diario")
                let isSpotify = normalizedName.hasPrefix("[spotify] ") || comment.contains("Spotify Synced")

                guard owner == username,
                      !isSmartPlaylist, !isEditorial, !isDailyMix, !isSpotify
                else { continue }

                let item = CPListItem(
                    text: name,
                    detailText: "\(songCount) canciones",
                    image: UIImage(systemName: "music.note.list"),
                    accessoryImage: nil,
                    accessoryType: .disclosureIndicator
                )

                item.handler = { [weak self] _, completion in
                    self?.playPlaylist(id: id, name: name)
                    completion()
                }

                // Cargar cover: primero backend, fallback a Navidrome
                self.loadPlaylistCover(playlistId: id, navidromeCoverArtId: coverArt) { image in
                    if let image = image {
                        DispatchQueue.main.async {
                            item.setImage(image)
                        }
                    }
                }

                items.append(item)
            }

            let section = CPListSection(items: items)
            DispatchQueue.main.async {
                self.playlistsTemplate?.updateSections([section])
                print("[CarPlay] \(items.count) playlists cargadas")
            }
        }.resume()
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

    // MARK: - Reproducir Playlist

    /// Envía un evento al WebView para que JS reproduzca la playlist.
    private func playPlaylist(id: String, name: String) {
        print("[CarPlay] Reproducir playlist: \(name)")

        DispatchQueue.main.async {
            guard let appDelegate = UIApplication.shared.delegate as? AppDelegate,
                  let webView = appDelegate.webViewRef else { return }

            let js = "window.dispatchEvent(new CustomEvent('_carplayPlayPlaylist', { detail: { playlistId: '\(id)' } }))"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // Ir a la pantalla de "Ahora suena" (Now Playing Template)
        // Usamos pushTemplate — esto permite al usuario retroceder a la lista.
        self.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }
}
