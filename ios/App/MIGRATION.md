# Plan de migración a SwiftUI nativo

> Documento interno — no subir a GitHub.

## Estado actual

La app es un WebView Capacitor (`AudiorrBridgeViewController`) con capas nativas encima:
- `NativeTabBarPlugin` — UITabBar nativa con SF Symbols y haptics
- `NativeNowPlayingPlugin` — mini-player UIKit con blur real
- `NativeAudioPlugin` + `AudioEngineManager` — AVAudioEngine, crossfade, CarPlay
- `AudioBridgePlugin` — puente lock screen, auriculares, interrupciones

El WebView sigue siendo el host de toda la lógica de negocio (PlayerContext, Connect, SmartMix, scrobbles, backend API).

---

## Principio de la migración

**No reemplazar el WebView — envolverlo.**

El WebView se convierte en un *panel lateral permanente* (invisible o mínimo) que mantiene vivo el estado JS. Las vistas Swift consultan datos vía un bridge ligero y delegan acciones al player JS cuando necesitan.

```
┌─────────────────────────────────────────┐
│  UIWindowScene                          │
│  ┌──────────────────────────────────┐   │
│  │  SwiftUI Navigation Host         │   │
│  │  (TabView + NavigationStack)     │   │
│  │                                  │   │
│  │  Páginas nativas: Albums,        │   │
│  │  Artists, Search, Settings…      │   │
│  └──────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  WKWebView (headless / oculto)  │    │
│  │  PlayerContext + Connect +      │    │
│  │  SmartMix + Backend APIs        │    │
│  └─────────────────────────────────┘    │
│                                         │
│  NativeTabBar / MiniPlayer (existentes) │
└─────────────────────────────────────────┘
```

---

## Estructura de carpetas propuesta

```
ios/App/App/
├── AppDelegate.swift               (existente)
├── MainSceneDelegate.swift         (existente)
├── AudiorrBridgeViewController.swift (existente — WebView headless)
│
├── Bridge/
│   ├── PlayerBridge.swift          — Observable que expone estado del player JS
│   ├── NavidromeBridge.swift       — Fetch de datos vía navidromeApi JS o directo
│   └── BridgeMessages.swift        — Tipos Codable para mensajes JS↔Swift
│
├── Services/
│   ├── NavidromeService.swift      — HTTP directo a la API Subsonic/Navidrome
│   └── ImageCache.swift            — Caché de portadas (NSCache + disco)
│
├── Views/
│   ├── RootTabView.swift           — TabView principal (reemplaza WebView como host)
│   │
│   ├── Search/
│   │   └── SearchView.swift
│   │
│   ├── Albums/
│   │   ├── AlbumsView.swift
│   │   └── AlbumDetailView.swift
│   │
│   ├── Artists/
│   │   ├── ArtistsView.swift
│   │   └── ArtistDetailView.swift
│   │
│   ├── Genres/
│   │   ├── GenresView.swift
│   │   └── GenreDetailView.swift
│   │
│   ├── Playlists/
│   │   ├── PlaylistsView.swift
│   │   └── PlaylistDetailView.swift
│   │
│   ├── Settings/
│   │   └── SettingsView.swift
│   │
│   └── Shared/
│       ├── AlbumCoverView.swift    — AsyncImage con caché + placeholder skeleton
│       ├── SongRowView.swift       — Fila reutilizable (portada, título, duración)
│       ├── SkeletonView.swift      — Modificador animate-pulse equivalente
│       └── HeroHeaderView.swift    — Header con portada grande + gradiente
│
├── NowPlaying/                     (existente, sin cambios)
│   ├── NativeNowPlayingPlugin.swift
│   └── …
│
└── Audio/                          (existente, sin cambios)
    ├── AudioEngineManager.swift
    ├── CrossfadeExecutor.swift
    └── …
```

---

## El bridge JS↔Swift

El WebView sigue corriendo en background. Para comunicación bidireccional:

**Swift → JS (acciones del player):**
```swift
// PlayerBridge.swift
func play() {
    webView.evaluateJavaScript("window.__playerBridge?.play()")
}
func playAlbum(id: String) {
    webView.evaluateJavaScript("window.__playerBridge?.playAlbum('\(id)')")
}
```

**JS → Swift (estado reactivo):**
```swift
// WKScriptMessageHandler existente (ya usado por NativeNowPlayingPlugin)
// Extender con nuevos mensajes: playerState, currentSong, isPlaying…
```

El `PlayerBridge.swift` sería un `@Observable` (Swift 5.9) o `ObservableObject` que mantiene el estado actual del player sincronizado con el WebView, suscrito vía `window.addEventListener('playerStateChange', …)` en JS.

---

## Datos: bridge JS vs. HTTP directo

Para páginas de datos (álbumes, artistas, canciones) hay dos opciones:

| Opción | Pros | Contras |
|--------|------|---------|
| Llamar `navidromeApi` via JS bridge | Reutiliza auth y caché existente | Latencia del puente, async complejo |
| HTTP directo desde Swift (Subsonic API) | Nativo, async/await limpio, sin puente | Duplicar lógica de auth + caché |

**Recomendación:** HTTP directo. La API de Navidrome es Subsonic estándar, bien documentada. `NavidromeService.swift` con `URLSession` + `async/await` es trivial. La caché de portadas con `NSCache` reemplaza el `navidromeApi.getCoverUrl()` de TS.

Las credenciales (servidor, usuario, token) se leen del mismo `UserDefaults`/`Keychain` donde las guarda el WebView al conectarse.

---

## Fases de migración

### Fase 1 — Infraestructura (sin UI visible aún)
- `NavidromeService.swift` con autenticación Subsonic
- `ImageCache.swift`
- `PlayerBridge.swift` conectado al WebView existente
- Añadir `window.__playerBridge` al JS (un objeto pequeño que expone acciones y emite eventos de estado)

### Fase 2 — Páginas simples
Orden: `SearchView` → `GenresView/Detail` → `AlbumsView` → `AlbumDetailView`

Cada página: SwiftUI puro, datos de `NavidromeService`, acción "play" vía `PlayerBridge`.

### Fase 3 — Páginas con más estado
`ArtistsView/Detail` → `PlaylistsView` → `PlaylistDetailView`

Playlists necesita conocer qué playlist está sonando actualmente → `PlayerBridge` ya lo expone.

### Fase 4 — HomePage
La más compleja: DailyMix, JumpBackIn, TopWeekly. Requiere que el backend de Audiorr tenga un SDK Swift o se consuma vía HTTP directamente.

### Fase 5 (opcional/futuro)
NowPlayingViewer en SwiftUI. Implica migrar también la lógica de letras y progreso. Tiene poco sentido hasta que el audio esté 100% en AVAudioEngine.

---

## Lo que NO se migra

- `AudioEngineManager` / `CrossfadeExecutor` — ya son nativos Swift, no hay nada que migrar
- `PlayerContext` / lógica de cola / crossfade logic en TS — permanece en el WebView
- Connect (multi-device) — permanece en TS
- Scrobbles / SmartMix / backend integration — permanece en TS

---

## Riesgo principal

El WebView headless necesita permanecer vivo en background para que el player no muera. Esto ya está resuelto parcialmente por los fixes de background suspension existentes. Al quitar el WebView del primer plano, asegurarse de que `WKWebView` sigue recibiendo tiempo de CPU cuando la app está en foreground con una vista Swift activa.
