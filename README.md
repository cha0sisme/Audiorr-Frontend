# Audiorr

<div align="center">

**A modern, audiophile-grade music player for Navidrome**

*Native iOS*

[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://developer.apple.com/swift/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-iOS_18+-007AFF?logo=apple&logoColor=white)](https://developer.apple.com/swiftui/)
[![AVAudioEngine](https://img.shields.io/badge/AVAudioEngine-Native-000000?logo=apple&logoColor=white)](https://developer.apple.com/documentation/avfaudio/avaudioengine)
[![SwiftData](https://img.shields.io/badge/SwiftData-Persistence-34C759?logo=apple&logoColor=white)](https://developer.apple.com/xcode/swiftdata/)
[![CarPlay](https://img.shields.io/badge/CarPlay-Supported-333333?logo=apple&logoColor=white)](https://developer.apple.com/carplay/)

</div>

---

Audiorr is a fully native iOS music player that connects to a [Navidrome](https://www.navidrome.org/) server (Subsonic-compatible). Designed for audiophiles who want more than a generic stream — with intelligent DJ-grade crossfade, harmonic Smart Mix, synchronized lyrics, a global weekly chart, offline playback, and seamless multi-device sync via **Audiorr Connect**.

> **Note:** Audiorr requires a [Navidrome](https://www.navidrome.org/) server for your music library. The optional **Audiorr Backend** unlocks advanced features (Smart Mix, Daily Mixes, multi-device sync, weekly statistics). Basic playback and browsing work with any Subsonic/Navidrome server alone.

---

## Feature Overview

### Core Features (Navidrome only — no backend required)

#### Playback Engine — AVAudioEngine
- **Native AVAudioEngine pipeline:** Direct hardware-accelerated audio with zero WebView overhead. Dual-player architecture (Player A + Player B) for gapless crossfade.
- **AVPlayer streaming fallback:** Automatically streams via AVPlayer when files need buffering, with seamless handoff to AVAudioEngine once downloaded.
- **Smart Crossfade — Normal & DJ Modes:** Professional transition engine that reads acoustic structure (intro, outro, energy) and selects the optimal blend type:
  - `NATURAL_BLEND` — organic ambient superimposition between soft tracks
  - `FADE_OUT_A / CUT_B` — natural decay from A, hard entry of B
  - `CUT_A / FADE_IN_B` — A holds energy, B fades in
  - `EQ_MIX / BEAT_MATCH_BLEND` — bass crossover synchronized to beat grid
  - `CUT` — instant, clean switch for short fade settings
- **Safety mechanisms** modeled after Rekordbox: Vocal Trainwreck evasion, anti-polyrhythm lock, 25% limit on short tracks.
- **ReplayGain v2 / EBU R128 normalization:** Automatic level normalization per track with True Peak limiter.
- **Automatic transcoding:** VBR MP3s and incompatible formats are transparently transcoded to CAF (PCM 16-bit 44.1kHz) for AVAudioEngine compatibility.
- **Queue management:** Full reordering, add/remove, persistent state across launches.
- **CarPlay:** Full browsing (albums, playlists, artists) + playback with optimized IO buffer (40ms wireless, 20ms default).

#### Synchronized Lyrics
- Fetched automatically via **LRCLib** for every playing song.
- Real-time karaoke-style scroll locked to audio position.
- Tap any line to seek directly to that timestamp.
- Graceful fallback to plain text lyrics when no timed data is available.

#### Offline Mode
- **Auto-cache:** Every song you play is automatically saved to persistent storage for offline playback.
- **Pre-cache:** Next 3 songs in queue are pre-downloaded in the background.
- **Manual downloads:** Download entire albums or personal playlists with a single tap.
- **Background downloads:** Downloads continue when the app is suspended (background URLSession).
- **Pin protection:** Pin content to prevent auto-eviction.
- **LRU eviction:** Oldest unpinned content is automatically removed when cache exceeds the configurable limit (default 2 GB).
- **Dual-cache architecture:** Hot temp cache (5 files, for instant playback) + persistent SwiftData-tracked cache (Library/Caches).
- **Offline browsing:** When offline, HomeView shows all downloaded albums and playlists.
- **Smart skip:** Only skips uncached songs when truly offline AND playback fails — never skips proactively on weak signal.
- **Storage management:** Visual storage bar, limit picker, clear cache controls in Settings.

```
┌─────────────────────────────────────────────────────┐
│                    UI Layer                          │
│  DownloadButton · StorageManagementView · Banners   │
└──────────────┬──────────────────────────┬────────────┘
               │                          │
┌──────────────▼──────────┐  ┌────────────▼────────────┐
│    DownloadManager       │  │    NetworkMonitor        │
│  (background URLSession) │  │  (NWPathMonitor)         │
│  - priority queue        │  │  - isConnected           │
│  - 3 concurrent DLs      │  │  - isExpensive           │
│  - retry + backoff        │  └─────────────────────────┘
└──────────────┬───────────┘
               │
┌──────────────▼───────────┐
│  OfflineStorageManager   │
│  (actor)                 │
│  - Library/Caches/Music/ │
│  - hash subdirs          │
│  - LRU eviction          │
│  - pin/unpin             │
└──────────────┬───────────┘
               │
┌──────────────▼───────────┐
│     SwiftData Store      │
│  (Library/App Support/)  │
│  - CachedSong            │
│  - DownloadTask           │
│  - DownloadGroup          │
│  - CachedPlaylistMeta    │
└──────────────────────────┘
```

### Backend-Exclusive Features (require Audiorr Backend)

The following features require the optional **Audiorr Backend** (`backend/`), a separate Node.js service. The app detects backend availability automatically and hides these features when unavailable.

#### Smart Mix (Harmonic DJ Ordering)
- Reorders any playlist using **Camelot Wheel harmonic compatibility** (60% weight) and BPM proximity (40% weight).
- Analysis results cached locally and in the backend SQLite database.

#### Daily Mixes
- Up to 5 **personalized daily mixes** based on listening history — no external ML, 100% deterministic clustering.
- **70/30 familiarity/discovery rule:** familiar songs from genre clusters plus new undiscovered tracks.
- Auto-generated at 03:00 UTC daily; on first launch if none exist.

#### Global Weekly Top 10
- Server-wide top 10 most-played songs for the current week.
- Trend indicators (up, down, same, New badge) comparing to last week.

#### Multi-Device Sync — Audiorr Connect
Spotify Connect-style system built on **Socket.io**. All devices on the same Navidrome account see each other and can share or transfer playback in real time.

| Capability | Details |
|---|---|
| **Device discovery** | Automatic; devices appear instantly |
| **Transfer playback** | Hand off song + queue + position to another device |
| **Remote control** | Play/pause, next, previous, seek, volume from any device |
| **Receiver mode** | Turn any device into a pure speaker |
| **Scrobble awareness** | Only the controlling device records listening history |
| **Session persistence** | Queue + position are waiting when you return |

#### Canvas — Video Loops
- Spotify-like looping video or image for each song.
- Available in the Now Playing viewer.

#### Jump Back In
- Recently played albums and playlists shown on HomeView for quick access.

---

## iOS App — Native SwiftUI

Audiorr is a **fully native iOS app** built with SwiftUI and AVAudioEngine. No WebView, no Capacitor, no React — pure Swift from UI to audio pipeline.

### Architecture

| Layer | Technology | Role |
|---|---|---|
| **UI** | SwiftUI (iOS 18+) | All views, navigation, animations |
| **Audio** | AVAudioEngine + AVPlayer | Crossfade, ReplayGain, gapless playback |
| **Persistence** | SwiftData + UserDefaults + Keychain | Offline cache, queue state, credentials |
| **Networking** | URLSession (foreground + background) | Streaming, downloads, API calls |
| **Connectivity** | NWPathMonitor | Offline detection, Wi-Fi/cellular awareness |
| **CarPlay** | CPTemplate API | Full CarPlay browsing and playback |
| **Lock Screen** | MPNowPlayingInfoCenter + MPRemoteCommandCenter | Now Playing card, transport controls |
| **Real-time** | Socket.io (via URLSession WebSocket) | Audiorr Connect multi-device sync |

### Native Features

| Feature | Implementation |
|---|---|
| **Background audio** | AVAudioSession `.playback` category with interruption handling |
| **Lock Screen & Control Center** | Full Now Playing card with artwork, seek bar, transport controls |
| **Dynamic Island** | Live Activity integration for current track |
| **CarPlay** | Full browsing (albums, playlists, artists) + playback with optimized buffering |
| **Hero transitions** | Matched geometry effect for album/playlist cover art |
| **Context menus** | UIKit `UIButton.showsMenuAsPrimaryAction` for zero-delay menus |
| **Color extraction** | Album art dominant color palette for dynamic gradients |
| **Offline mode** | SwiftData + background URLSession + LRU eviction |
| **Credential storage** | iOS Keychain for server credentials |
| **Theme** | Dark/Light mode with system override |
| **Tab caching** | Singleton ViewModels with TTL to prevent re-fetching on tab switch |

---

## Project Structure

```
ios/App/
├── App/
│   ├── AppDelegate.swift              App lifecycle, audio session, CarPlay, background downloads
│   ├── MainSceneDelegate.swift        Main UI scene
│   ├── CarPlaySceneDelegate.swift     CarPlay template browsing + playback
│   ├── AudioEngineManager.swift       AVAudioEngine dual-player pipeline, crossfade, streaming
│   ├── AudioFileLoader.swift          Download + transcode + dual-cache (temp + persistent)
│   ├── CrossfadeExecutor.swift        Crossfade state machine
│   │
│   ├── Models/
│   │   ├── NavidromeModels.swift      API response models (Song, Album, Artist, Playlist)
│   │   └── OfflineModels.swift        SwiftData models (CachedSong, DownloadTask, DownloadGroup)
│   │
│   ├── Services/
│   │   ├── NavidromeService.swift     Subsonic API client (streaming, browsing, playlists)
│   │   ├── PlayerService.swift        High-level playback API (play, queue, context tracking)
│   │   ├── QueueManager.swift         Queue state, crossfade preparation, pre-cache, scrobble
│   │   ├── DownloadManager.swift      Background URLSession download engine (priority queue, retry)
│   │   ├── OfflineStorageManager.swift Persistent cache (SwiftData + Library/Caches, LRU eviction)
│   │   ├── OfflineContentProvider.swift Offline browsing queries (cached albums, playlists, search)
│   │   ├── NetworkMonitor.swift       NWPathMonitor connectivity awareness
│   │   ├── PersistenceService.swift   UserDefaults for playback state + offline settings
│   │   ├── CredentialsStore.swift     Keychain storage for server credentials
│   │   ├── ScrobbleService.swift      Navidrome + backend scrobbling with retry queue
│   │   ├── DJMixingService.swift      Crossfade intelligence (song analysis, blend selection)
│   │   ├── AnalysisCacheService.swift  Audio analysis cache (BPM, key, energy, segments)
│   │   ├── SmartMixManager.swift      Harmonic playlist reordering
│   │   ├── ConnectService.swift       Audiorr Connect (Socket.io multi-device sync)
│   │   ├── BackendService.swift       Audiorr Backend API client
│   │   ├── LyricsService.swift        LRCLib synchronized lyrics
│   │   ├── CanvasService.swift        Spotify Canvas video loops
│   │   ├── ColorExtractor.swift       Album art dominant color palette
│   │   ├── NowPlayingState.swift      Observable state for Now Playing UI
│   │   └── AppTheme.swift             Dark/Light theme management
│   │
│   └── Views/
│       ├── ContentView.swift          Root TabView with offline banner
│       ├── Home/
│       │   └── HomeView.swift         Landing: Weekly Top, Jump Back In, releases, mixes + offline
│       ├── Albums/
│       │   └── AlbumDetailView.swift  Album hero + song list + download button
│       ├── Artists/
│       │   ├── ArtistsView.swift      Artist grid with search
│       │   └── ArtistDetailView.swift Artist profile + discography
│       ├── Playlists/
│       │   ├── PlaylistsView.swift    Playlist grid
│       │   └── PlaylistDetailView.swift Playlist hero + SmartMix + download
│       ├── Search/
│       │   └── SearchView.swift       Global search (songs, albums, artists)
│       ├── Settings/
│       │   ├── SettingsView.swift     App settings (DJ mode, ReplayGain, scrobbling, Last.fm)
│       │   ├── LoginView.swift        Server connection screen
│       │   └── StorageManagementView.swift Offline cache management UI
│       ├── NowPlaying/
│       │   ├── NowPlayingViewerView.swift Full-screen Now Playing (artwork, controls, lyrics, queue)
│       │   ├── ProgressBarView.swift  Seek bar
│       │   ├── PlaybackControlsView.swift Transport controls
│       │   ├── LyricsView.swift       Synchronized lyrics overlay
│       │   ├── QueuePanelView.swift   Queue management panel
│       │   ├── CanvasView.swift       Video loop viewer
│       │   ├── DevicePickerView.swift Audiorr Connect device selector
│       │   └── AddToPlaylistView.swift Playlist picker
│       └── Shared/
│           ├── SongListView.swift     Reusable song table with context menus + cached indicator
│           ├── MiniPlayerView.swift   Persistent mini player (tab bar accessory)
│           ├── AlbumCardView.swift    Album thumbnail with retry logic
│           ├── ArtistCardView.swift   Artist avatar with retry logic
│           ├── PlaylistCardView.swift Playlist cover with multi-source fallback
│           ├── DownloadButton.swift   Download indicator (progress ring, states, pin/unpin)
│           ├── HorizontalScrollSection.swift Horizontal carousel container
│           └── SeeAllGridView.swift   Full grid for "See All" navigation
```

---

## Offline Storage Architecture

```
Library/
  Application Support/
    Audiorr/
      offline.store              SwiftData SQLite (backed up to iCloud)
        - CachedSong             Song metadata + file reference
        - DownloadTask           Download queue state
        - DownloadGroup          Album/playlist batch tracking
        - CachedPlaylistMeta     Playlist song order for offline browsing
  Caches/
    Audiorr/
      Music/
        ab/abcdef123.caf         Audio files (NOT backed up, 2-char prefix dirs)
        cd/cdef456789.mp3
    AudioAnalysis/               BPM/key/energy analysis cache
tmp/
  audiorr-audio/                 Hot temp cache (5-file LRU for instant playback)
  audiorr-downloads/             In-progress download staging
```

---

## Backend Integration

The Audiorr Backend (`backend/`) is an optional Node.js service. The app is fully functional with just a Navidrome server — the backend unlocks additional social and discovery features.

| Feature | Navidrome only | + Audiorr Backend |
|---|---|---|
| **Playback & crossfade** | AVAudioEngine + DJ modes | -- |
| **Browse, search, playlists** | Full Subsonic API | -- |
| **Synchronized lyrics** | LRCLib direct | -- |
| **Offline mode & downloads** | Full (auto-cache, pre-cache, background DL) | -- |
| **CarPlay** | Full browsing + playback | -- |
| **Lock Screen & Dynamic Island** | Full controls | -- |
| **ReplayGain normalization** | EBU R128 | -- |
| **Audiorr Connect** | -- | Multi-device sync |
| **Smart Mix** | -- | Harmonic playlist reordering |
| **Daily Mixes** | -- | 5 personalized mixes |
| **Weekly Top 10** | -- | Server-wide chart |
| **Canvas** | -- | Video loops |
| **Jump Back In** | -- | Recently played |
| **Listening history** | -- | Stats & wrapped |

---

## Privacy & Data

- **All music is streamed from your own Navidrome server.** Audiorr does not access any music other than what your server exposes.
- **Listening history** is stored in a local SQLite database on your backend server, never sent externally.
- **LRCLib** is queried for lyrics by song title and artist only.
- **No tracking, no analytics, no ads.**

---

## Requirements

- iOS 18.0+
- A Navidrome server (self-hosted)
- Xcode 16+ (to build from source)

---

## License

This project is for personal use. All rights reserved.

---

<div align="center">
<i>Built for audiophiles who demand more from their music.</i>
</div>
