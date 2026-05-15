import Foundation

/// Sesiones URLSession con QoS jerárquico — separa el ancho de banda entre el
/// streaming de audio (crítico), recursos del Now Playing visible (cover, canvas,
/// lyrics, lock screen, CarPlay, búsquedas) y trabajo no-interactivo (grids de
/// covers, catálogo masivo, scrobble, telemetría diagnostics).
///
/// Bajo buena cobertura LAN/WiFi las 3 sesiones funcionan en paralelo y no hay
/// diferencia perceptible. Bajo congestión real (cellular constrained, 1-2 rayas
/// 5G), la jerarquía permite que el audio se sirva primero, después la vista
/// actual y finalmente el resto.
///
/// Decisiones de tuneo (validadas con devils-advocate antes de codear):
/// - `waitsForConnectivity=false` en `audio` e `interactive`: bajo red intermitente
///   queremos fail-fast para que los retries con backoff de AudioFileLoader hagan
///   su trabajo. Si dejásemos `true`, la dataTask quedaría colgada hasta el timeout
///   de recurso (minutos), produciendo sensación de app pillada.
/// - `httpMaximumConnectionsPerHost` bajo (2/4/2): menos conexiones simultáneas =
///   menos handshakes TLS bajo mala cobertura. Sobrecomprometer paralelismo bajo
///   1 raya degrada en lugar de ayudar.
/// - `networkServiceType=.responsiveData` en `audio`: hint a iOS de que es tráfico
///   interactivo crítico, no bulk.
///
/// Limitación conocida:
/// - `executeStreamFallbackCrossfade` en AudioEngineManager usa AVPlayer directo
///   (no URLSession) → fuera del alcance de este fix. El streaming bufferizado vía
///   AudioFileLoader sí queda priorizado.
///
/// NO sustituye a `DownloadManager.backgroundSession` (descargas offline manuales),
/// que ya tiene su propia `URLSessionConfiguration.background(withIdentifier:)`.
enum AudiorrNetwork {

    /// Streaming del audio que está sonando. Máxima prioridad.
    static let audio: URLSession = {
        let config = URLSessionConfiguration.default
        config.networkServiceType = .responsiveData
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 2
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: config)
    }()

    /// Recursos del Now Playing y UI visible: cover del viewer, canvas, LRCLib,
    /// artwork de lock screen / Control Center / CarPlay, MiniPlayer, búsquedas
    /// que el usuario está esperando, login.
    static let interactive: URLSession = {
        let config = URLSessionConfiguration.default
        config.networkServiceType = .default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    /// Trabajo no-interactivo: grids de cover en Home/Search/Albums/Playlist,
    /// catálogo masivo de Navidrome, scrobble, telemetría diagnostics, cliente
    /// del backend Audiorr. Bajo congestión, se cede el paso a `audio` e
    /// `interactive`.
    static let background: URLSession = {
        let config = URLSessionConfiguration.default
        config.networkServiceType = .background
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()
}
