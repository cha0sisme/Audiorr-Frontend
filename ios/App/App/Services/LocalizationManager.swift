import Foundation
import SwiftUI

// MARK: - Language

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case es = "es"
    case en = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return resolvedLanguage.nativeName + " (Auto)"
        case .es: return "Español"
        case .en: return "English"
        }
    }

    var nativeName: String {
        switch self {
        case .system: return resolvedLanguage.nativeName
        case .es: return "Español"
        case .en: return "English"
        }
    }

    /// Resolve "system" to an actual language based on device locale.
    var resolvedLanguage: AppLanguage {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("es") { return .es }
        return .en
    }
}

// MARK: - Localization Manager

final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "app_language")
        }
    }

    /// The actual language used for string lookup (never .system).
    var resolved: AppLanguage { language.resolvedLanguage }

    private init() {
        let stored = UserDefaults.standard.string(forKey: "app_language") ?? "system"
        language = AppLanguage(rawValue: stored) ?? .system
    }
}

// MARK: - Localized Strings

/// Usage: `L.settings` returns the localized string for the current language.
/// All user-facing strings are centralized here.
enum L {
    private static var lang: AppLanguage { LocalizationManager.shared.resolved }
    private static var isEn: Bool { lang == .en }

    // MARK: - Tabs

    static var home: String { isEn ? "Home" : "Inicio" }
    static var artists: String { isEn ? "Artists" : "Artistas" }
    static var playlists: String { isEn ? "Playlists" : "Playlists" }
    static var search: String { isEn ? "Search" : "Buscar" }

    // MARK: - Common

    static var play: String { isEn ? "Play" : "Reproducir" }
    static var pause: String { isEn ? "Pause" : "Pausa" }
    static var shuffle: String { isEn ? "Shuffle" : "Aleatorio" }
    static var cancel: String { isEn ? "Cancel" : "Cancelar" }
    static var close: String { isEn ? "Close" : "Cerrar" }
    static var delete: String { isEn ? "Delete" : "Eliminar" }
    static var save: String { isEn ? "Save" : "Guardar" }
    static var error: String { isEn ? "Error" : "Error" }
    static var ok: String { isEn ? "OK" : "OK" }
    static var seeAll: String { isEn ? "See all" : "Ver todo" }
    static var noConnection: String { isEn ? "No connection" : "Sin conexión" }
    static var loading: String { isEn ? "Loading..." : "Cargando..." }
    static var new: String { isEn ? "New" : "Nuevo" }

    // MARK: - Song / Album / Artist counts

    static func songCount(_ n: Int) -> String {
        isEn ? "\(n) song\(n == 1 ? "" : "s")" : "\(n) \(n == 1 ? "canción" : "canciones")"
    }
    static func albumCount(_ n: Int) -> String {
        isEn ? "\(n) album\(n == 1 ? "" : "s")" : "\(n) \(n == 1 ? "álbum" : "álbumes")"
    }

    // MARK: - Queue / Context menu

    static var playNext: String { isEn ? "Play next" : "Reproducir a continuación" }
    static var addToQueue: String { isEn ? "Add to queue" : "Añadir a la cola" }
    static var goToAlbum: String { isEn ? "Go to album" : "Ir al álbum" }
    static var goToArtist: String { isEn ? "Go to artist" : "Ir al artista" }
    static var addToPlaylist: String { isEn ? "Add to playlist" : "Añadir a playlist" }

    // MARK: - Home

    static var goodMorning: String { isEn ? "Good morning" : "Buenos días" }
    static var goodAfternoon: String { isEn ? "Good afternoon" : "Buenas tardes" }
    static var goodEvening: String { isEn ? "Good evening" : "Buenas noches" }
    static var mostPlayed: String { isEn ? "Most played" : "Lo más escuchado" }
    static var heavyRotation: String { isEn ? "Heavy rotation" : "En rotación" }
    static var discoverSomethingNew: String { isEn ? "Discover something new" : "Descubre algo nuevo" }
    static var pinnedPlaylists: String { isEn ? "Pinned playlists" : "Playlists fijadas" }
    static var yourWeek: String { isEn ? "Your week" : "Tu semana" }
    static var yourDailyMixes: String { isEn ? "Your daily mixes" : "Tus mixes diarios" }
    static var generatingMixes: String { isEn ? "Generating mixes..." : "Generando mixes..." }
    static var generateMixesFirstTime: String { isEn ? "Generate mixes for the first time" : "Generar mixes por primera vez" }
    static var downloaded: String { isEn ? "Downloaded" : "Descargado" }
    static var offlineDownloadsAvailable: String { isEn ? "No connection — downloaded content available" : "Sin conexión — contenido descargado disponible" }
    static var downloadAlbumsForOffline: String { isEn ? "Download albums and playlists to listen offline." : "Descarga álbumes y playlists para escuchar sin conexión." }
    static var listenAgain: String { isEn ? "Listen again" : "Volver a escuchar" }
    static var recentReleases: String { isEn ? "Recent releases" : "Lanzamientos recientes" }
    static var latestAlbums: String { isEn ? "Latest albums" : "Últimos álbumes añadidos" }
    static var songs: String { isEn ? "songs" : "canciones" }
    static var hours: String { isEn ? "hours" : "horas" }

    // MARK: - Artists

    static var allArtists: String { isEn ? "All artists" : "Todos los artistas" }
    static var noArtistsFound: String { isEn ? "No artists found on your server." : "No se encontraron artistas en tu servidor." }
    static var popular: String { isEn ? "Popular" : "Populares" }
    static func aboutArtist(_ name: String) -> String { isEn ? "About \(name)" : "Acerca de \(name)" }
    static func aboutAlbum(_ name: String) -> String { isEn ? "About \(name)" : "Acerca de \(name)" }

    // MARK: - Artists / Playlists — not configured

    static var noServerConfigured: String { isEn ? "No server configured" : "Sin servidor configurado" }
    static var connectNavidromeArtists: String { isEn ? "Connect your Navidrome server to see your artists." : "Conecta tu servidor de Navidrome para ver tus artistas." }
    static var connectNavidromePlaylists: String { isEn ? "Connect your Navidrome server to see your playlists." : "Conecta tu servidor de Navidrome para ver tus playlists." }
    static var connectOfflineArtists: String { isEn ? "Connect to the internet to see your artists. Downloaded songs are still available." : "Conecta a internet para ver tus artistas. Las canciones descargadas siguen disponibles." }
    static var connectOfflinePlaylists: String { isEn ? "Connect to the internet to see your playlists. Downloaded songs are still available." : "Conecta a internet para ver tus playlists. Las canciones descargadas siguen disponibles." }
    static var connectToNavidrome: String { isEn ? "Connect to Navidrome" : "Conectar a Navidrome" }

    // MARK: - Playlists

    static var newPlaylist: String { isEn ? "New playlist" : "Nueva playlist" }
    static var newPlaylistPrompt: String { isEn ? "Enter the name of the new playlist." : "Introduce el nombre de la nueva playlist." }
    static var name: String { isEn ? "Name" : "Nombre" }
    static var createPlaylist: String { isEn ? "Create" : "Crear" }
    static var deletePlaylist: String { isEn ? "Delete Playlist" : "Eliminar playlist" }
    static var deletePlaylistConfirm: String { isEn ? "This action cannot be undone." : "Esta acción no se puede deshacer." }
    static var download: String { isEn ? "Download" : "Descargar" }
    static var downloads: String { isEn ? "Downloads" : "Descargas" }
    static var noDownloadedSongs: String { isEn ? "No downloaded songs" : "No hay canciones descargadas" }
    static var songsAutoSaved: String { isEn ? "Songs you play will be saved automatically." : "Las canciones que reproduzcas se guardarán automáticamente." }
    static var noPlaylists: String { isEn ? "No playlists" : "Sin playlists" }
    static var createPlaylistHint: String { isEn ? "Create a playlist in Navidrome to see it here." : "Crea una playlist en Navidrome para verla aquí." }
    static var noPrivatePlaylists: String { isEn ? "You don't have any private playlists." : "No tienes playlists privadas." }

    // MARK: - Search

    static var offlineSearchOnly: String { isEn ? "No connection — searching downloads only" : "Sin conexión — buscando solo en descargas" }
    static var recents: String { isEn ? "Recent" : "Recientes" }
    static func noResultsFor(_ query: String) -> String { isEn ? "No results for \"\(query)\"" : "Sin resultados para «\(query)»" }
    static func offlineNoResults(_ query: String) -> String {
        isEn ? "Only searching downloaded songs. No results for \"\(query)\"."
             : "Solo se busca en canciones descargadas. Sin resultados para «\(query)»."
    }
    static var artist: String { isEn ? "Artist" : "Artista" }

    // MARK: - NowPlaying / MiniPlayer

    static var nothingPlaying: String { isEn ? "Nothing playing" : "Sin reproducción" }

    // MARK: - Queue

    static var queue: String { isEn ? "Queue" : "Cola" }
    static var remoteQueue: String { isEn ? "Remote queue" : "Cola remota" }
    static func playingOn(_ device: String) -> String { isEn ? "Playing on \(device)" : "Reproduciendo en \(device)" }
    static var nowPlaying: String { isEn ? "Now playing" : "Reproduciendo" }
    static var upNext: String { isEn ? "Up next" : "A continuación" }
    static var clear: String { isEn ? "Clear" : "Limpiar" }
    static var noSongsInQueue: String { isEn ? "No songs in queue." : "No hay canciones en cola." }

    // MARK: - Device Picker

    static var playOn: String { isEn ? "Play on" : "Reproducir en" }
    static var connectingToHub: String { isEn ? "Connecting to hub..." : "Conectando al hub..." }
    static var playing: String { isEn ? "Playing" : "Reproduciendo" }
    static var airplayBluetooth: String { isEn ? "AirPlay & Bluetooth" : "AirPlay y Bluetooth" }
    static var audioOutput: String { isEn ? "Audio output" : "Salida de audio" }
    static func connectedTo(_ name: String) -> String { isEn ? "Connected to \(name)" : "Conectado a \(name)" }
    static var streaming: String { isEn ? "Streaming" : "Transmitiendo" }
    static var devicesOnNetwork: String { isEn ? "Devices on network" : "Dispositivos en la red" }

    // MARK: - Add to Playlist

    static var noPlaylistsAvailable: String { isEn ? "No playlists" : "Sin playlists" }

    // MARK: - Downloads / Storage

    static var pin: String { isEn ? "Pin" : "Fijar" }
    static var unpin: String { isEn ? "Unpin" : "Quitar fijado" }
    static var deleteDownload: String { isEn ? "Delete Download" : "Eliminar descarga" }

    // MARK: - Settings

    static var settings: String { isEn ? "Settings" : "Configuración" }
    static var appearance: String { isEn ? "Appearance" : "Apariencia" }
    static var darkMode: String { isEn ? "Dark mode" : "Modo oscuro" }
    static var lightMode: String { isEn ? "Light" : "Claro" }
    static var darkModeShort: String { isEn ? "Dark" : "Oscuro" }
    static var systemMode: String { isEn ? "System" : "Sistema" }
    static var playback: String { isEn ? "Playback" : "Reproducción" }
    static var djMode: String { isEn ? "DJ Mode" : "Modo DJ" }
    static var crossfade: String { isEn ? "Crossfade" : "Crossfade" }
    static var duration: String { isEn ? "Duration" : "Duración" }
    static var replayGain: String { isEn ? "ReplayGain" : "ReplayGain" }
    static var apiKey: String { isEn ? "API Key" : "Clave de API" }
    static var enterApiKey: String { isEn ? "Enter your API key" : "Introduce tu clave de API" }
    static var scrobbling: String { isEn ? "Scrobbling" : "Scrobbling" }
    static var active: String { isEn ? "Active" : "Activo" }
    static var testing: String { isEn ? "Testing..." : "Probando..." }
    static var correct: String { isEn ? "Success" : "Correcto" }
    static var test: String { isEn ? "Test" : "Probar" }
    static var storage: String { isEn ? "Storage" : "Almacenamiento" }
    static var manageStorage: String { isEn ? "Manage storage" : "Gestionar almacenamiento" }
    static var server: String { isEn ? "Server" : "Servidor" }
    static var user: String { isEn ? "User" : "Usuario" }
    static var logout: String { isEn ? "Log out" : "Cerrar sesión" }
    static var logoutConfirm: String { isEn ? "Server configuration will be deleted." : "Se borrará la configuración del servidor." }
    static var keySaved: String { isEn ? "Key saved." : "Clave guardada." }
    static var keySaveError: String { isEn ? "Error saving key." : "Error al guardar." }
    static var keyDeleted: String { isEn ? "Key deleted." : "Clave eliminada." }
    static var keyDeleteError: String { isEn ? "Error deleting key." : "Error al eliminar." }
    static var secretStoredOnBackend: String { isEn ? "A secret is stored on the backend." : "Hay un secreto guardado en el backend." }
    static var language: String { isEn ? "Language" : "Idioma" }

    static func crossfadeFooterDjOn() -> String {
        isEn ? "DJ Mode analyzes songs to create intelligent dynamic mixes. Duration adjusts automatically based on analysis. ReplayGain normalizes volume."
             : "Modo DJ analiza las canciones para crear mezclas dinámicas inteligentes. La duración se ajusta automáticamente según el análisis. ReplayGain normaliza el volumen."
    }
    static func crossfadeFooterBackend() -> String {
        isEn ? "Transitions are automatically optimized with backend analysis. Enable DJ Mode for intelligent dynamic mixes. ReplayGain normalizes volume."
             : "Las transiciones se optimizan automáticamente con el análisis del backend. Activa Modo DJ para mezclas dinámicas inteligentes. ReplayGain normaliza el volumen."
    }
    static func crossfadeFooterOff() -> String {
        isEn ? "Songs will change without transition. ReplayGain normalizes volume between songs."
             : "Las canciones cambiarán sin transición. ReplayGain normaliza el volumen entre canciones."
    }
    static func crossfadeFooterOn(_ seconds: Int) -> String {
        isEn ? "Crossfade blends songs with a \(seconds)s transition. ReplayGain normalizes volume between songs."
             : "Crossfade mezcla las canciones con una transición de \(seconds)s. ReplayGain normaliza el volumen entre canciones."
    }
    static var scrobbleFooter: String {
        isEn ? "Listens will be recorded automatically after playing at least 50% or 4 minutes."
             : "Las escuchas se registraran automaticamente tras reproducir al menos el 50% o 4 minutos."
    }

    // MARK: - User Profile

    static var profile: String { isEn ? "Profile" : "Perfil" }
    static var noActivity: String { isEn ? "No activity" : "Sin actividad" }
    static var listensWillAppear: String { isEn ? "Listens will appear here." : "Las reproducciones aparecerán aquí." }
    static var weekly: String { isEn ? "Weekly" : "Semanal" }
    static var monthly: String { isEn ? "Monthly" : "Mensual" }
    static var period: String { isEn ? "Period" : "Período" }
    static var plays: String { isEn ? "Plays" : "Reproducciones" }
    static var topGenre: String { isEn ? "Top genre" : "Género favorito" }
    static var lastScrobble: String { isEn ? "Last scrobble" : "Último scrobble" }
    static var topSongs: String { isEn ? "Top songs" : "Canciones favoritas" }
    static var topArtists: String { isEn ? "Top artists" : "Artistas favoritos" }
    static func playsCount(_ n: Int) -> String {
        isEn ? "\(n) play\(n == 1 ? "" : "s")" : "\(n) \(n == 1 ? "reproducción" : "reproducciones")"
    }

    // MARK: - Storage Management

    static var cachedSongs: String { isEn ? "Cached songs" : "Canciones en caché" }
    static var totalSize: String { isEn ? "Total size" : "Tamaño total" }
    static var pinned: String { isEn ? "Pinned (protected)" : "Fijado (protegido)" }
    static var storageUsage: String { isEn ? "Storage usage" : "Uso de almacenamiento" }
    static var limit: String { isEn ? "Limit" : "Límite" }
    static var cacheLimitFooter: String {
        isEn ? "Oldest unpinned songs are automatically removed when the limit is exceeded."
             : "Las canciones más antiguas sin fijar se eliminan automáticamente al superar el límite."
    }
    static var autoCacheOnPlay: String { isEn ? "Auto-cache on play" : "Auto-caché al reproducir" }
    static var wifiOnlyDownload: String { isEn ? "Download on Wi-Fi only" : "Solo descargar con Wi-Fi" }
    static var autoDownloads: String { isEn ? "Automatic downloads" : "Descargas automáticas" }
    static var autoCacheFooter: String {
        isEn ? "With auto-cache enabled, every song you play is saved for offline listening."
             : "Con auto-caché activado, cada canción que reproduzcas se guarda para escuchar sin conexión."
    }
    static var activeDownloads: String { isEn ? "Active downloads" : "Descargas activas" }
    static var management: String { isEn ? "Management" : "Gestión" }
    static var clearUnpinnedCache: String { isEn ? "Clear unpinned cache" : "Borrar caché no fijado" }
    static var clearAllCache: String { isEn ? "Clear all cache" : "Borrar todo el caché" }
    static var managementFooter: String {
        isEn ? "\"Clear unpinned cache\" removes everything except pinned content. \"Clear all\" removes absolutely everything."
             : "\"Borrar caché no fijado\" elimina todo excepto el contenido fijado. \"Borrar todo\" elimina absolutamente todo."
    }
    static func clearUnpinnedConfirm(_ size: String) -> String {
        isEn ? "\(size) of cached songs will be removed." : "Se eliminarán \(size) de canciones en caché."
    }
    static var clearAllConfirm: String {
        isEn ? "All downloaded songs will be removed, including pinned ones."
             : "Se eliminarán todas las canciones descargadas, incluyendo las fijadas."
    }
    static var pinnedLegend: String { isEn ? "Pinned" : "Fijado" }
    static var cacheLegend: String { isEn ? "Cache" : "Caché" }
    static func cacheLimit(_ bytes: String) -> String { isEn ? "Limit: \(bytes)" : "Límite: \(bytes)" }
    static var album: String { isEn ? "Album" : "Álbum" }
    static var playlist: String { isEn ? "Playlist" : "Playlist" }

    // MARK: - Login

    static var loginSubtitle: String {
        isEn ? "Connect to your Navidrome server\nto access your music library."
             : "Conecta con tu servidor Navidrome\npara acceder a tu biblioteca de música."
    }
    static var connected: String { isEn ? "Connected" : "Conectado" }
    static var signIn: String { isEn ? "Sign in" : "Iniciar sesión" }
    static var serverUrl: String { isEn ? "Server URL" : "URL del servidor" }
    static var username: String { isEn ? "Username" : "Usuario" }
    static var password: String { isEn ? "Password" : "Contraseña" }
    static var invalidUrl: String { isEn ? "Invalid URL" : "URL invalida" }
    static var invalidCredentials: String { isEn ? "Invalid credentials" : "Credenciales incorrectas" }
    static func connectionFailed(_ desc: String) -> String { isEn ? "Could not connect: \(desc)" : "No se pudo conectar: \(desc)" }

    // MARK: - Artist Detail extra

    static var showMore: String { isEn ? "Show more" : "Ver más" }
    static var showLess: String { isEn ? "Show less" : "Ver menos" }
    static var albums: String { isEn ? "Albums" : "Álbumes" }
    static var appearsIn: String { isEn ? "Appears in" : "Aparece en" }
    static var fansAlsoListen: String { isEn ? "Fans also listen to" : "Fans también escuchan" }
    static func playlistsWith(_ name: String) -> String { isEn ? "Playlists with \(name)" : "Playlists con \(name)" }
    static var analyzing: String { isEn ? "Analyzing…" : "Analizando…" }
    static var retry: String { isEn ? "Retry" : "Reintentar" }
    static var mostListened: String { isEn ? "Most listened" : "Más escuchados" }
    static var recent: String { isEn ? "Recent" : "Novedades" }
    static var emptyQueue: String { isEn ? "Empty queue" : "Cola vacía" }
    static var retryFailed: String { isEn ? "Retry failed" : "Reintentar fallidas" }
    static var deleteAll: String { isEn ? "Delete all" : "Borrar todo" }
    static var noLimit: String { isEn ? "No limit" : "Sin límite" }
    static func addedToPlaylist(_ name: String) -> String { isEn ? "Added to \(name)" : "Añadido a \(name)" }
    static var addToPlaylistError: String { isEn ? "Error adding" : "Error al añadir" }
    static func deleteConfirm(_ name: String) -> String { isEn ? "Delete \"\(name)\"" : "Eliminar «\(name)»" }
    static var irreversibleAction: String { isEn ? "This action cannot be undone." : "Esta acción no se puede deshacer." }
    static var topWeekly: String { isEn ? "Top weekly" : "Top semanal" }
    static var searchPlaceholder: String { isEn ? "Artists, albums, songs..." : "Artistas, álbumes, canciones..." }
    static var clearHistory: String { isEn ? "Clear" : "Borrar" }
    static var songsLabel: String { isEn ? "Songs" : "Canciones" }
    static var albumsSearch: String { isEn ? "Albums" : "Álbumes" }
}
