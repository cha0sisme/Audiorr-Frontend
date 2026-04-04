# Audiorr

<div align="center">

**A modern, audiophile-grade music player for Navidrome**

*Web · Desktop · iOS*

[![React](https://img.shields.io/badge/React-18-61DAFB?logo=react&logoColor=white)](https://react.dev)
[![TypeScript](https://img.shields.io/badge/TypeScript-5-3178C6?logo=typescript&logoColor=white)](https://www.typescriptlang.org)
[![Vite](https://img.shields.io/badge/Vite-5-646CFF?logo=vite&logoColor=white)](https://vitejs.dev)
[![Tailwind CSS](https://img.shields.io/badge/Tailwind_CSS-3-06B6D4?logo=tailwindcss&logoColor=white)](https://tailwindcss.com)
[![Capacitor](https://img.shields.io/badge/iOS-Capacitor-119EFF?logo=ionic&logoColor=white)](https://capacitorjs.com)
[![Swift](https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white)](https://developer.apple.com/swift/)

</div>

---

Audiorr is a full-featured music streaming frontend that connects to a [Navidrome](https://www.navidrome.org/) server (Subsonic-compatible). It is designed for audiophiles who want more than just a generic stream — with intelligent DJ-grade crossfade, harmonic Smart Mix, synchronized lyrics, a global weekly top chart, and seamless multi-device playback via **Audiorr Connect**.

> **Note:** Audiorr is a frontend client that requires a [Navidrome](https://www.navidrome.org/) server for your music library and optionally the **Audiorr Backend** for advanced features (Smart Mix, Daily Mixes, multi-device sync, weekly statistics). Basic playback and browsing work with any Subsonic/Navidrome server alone.

---

## ✨ Feature Overview

### 🎵 Playback Engine
- **Dual-mode audio system:** Runs on **Web Audio API** (primary) with automatic fallback to HTML Audio for unsupported formats (M4A, etc.)
- **Smart Crossfade — Normal & DJ Modes:** Professional transition engine that reads the acoustic structure of each song (intro, outro, energy) and decides the optimal blend type automatically:
  - `NATURAL_BLEND` — organic ambient superimposition between two soft tracks
  - `FADE_OUT_A / CUT_B` — natural decay from A, hard entry of B
  - `CUT_A / FADE_IN_B` — A holds energy to the last millisecond, B fades in
  - `EQ_MIX / BEAT_MATCH_BLEND` — bass crossover synchronized to the beat grid
  - `CUT` — instant, clean switch for short fade settings
- **Safety mechanisms** modeled after Rekordbox: Vocal Trainwreck evasion (no two singers at once), anti-polyrhythm lock (BPM difference threshold), 25% limit on short tracks.
- **ReplayGain v2 / EBU R128 normalization:** Automatic level normalization per track with True Peak limiter to prevent clipping.
- **Queue management:** Full drag-and-drop reordering, add/remove at any point.
- **Persistent state:** Song, position, queue, and volume are saved and restored on next launch.

### 🎤 Synchronized Lyrics
- Fetched automatically via **LRCLib** for every song playing.
- Real-time karaoke-style scroll locked to audio position.
- Tap any line to seek directly to that timestamp.
- Graceful fallback to plain text lyrics when no timed data is available.

### 🧠 Smart Mix (Harmonic DJ Ordering)
- Reorders any playlist using **Camelot Wheel harmonic compatibility** (60% weight) and BPM proximity (40% weight) for a natural DJ flow with no jarring key changes.
- Analysis results are cached locally and in the backend SQLite database — mixing a 100-song playlist takes milliseconds on repeat runs.

### 📅 Daily Mixes
- Audiorr generates up to 5 **personalized daily mixes** based entirely on your local listening history — no external ML services, 100% deterministic cluster algorithm.
- Mixes follow a **70/30 familiarity/discovery rule**: familiar songs from your genre clusters plus new undiscovered tracks from your library that fit the same acoustic profile.
- Auto-generated at 03:00 UTC daily; on first launch if no mixes exist yet.

### 📊 Global Weekly Top 10 — *Lo más escuchado*
- Shows the server-wide top 10 most-played songs for the current week.
- Tracks rank movement with trend indicators (↑ up, ↓ down, — same, **New** badge) by comparing to last week's rankings.
- Playing a song from the top chart automatically queues the full top 10 from that position.

### 📱 Multi-Device Sync — Audiorr Connect
Audiorr Connect is a **Spotify Connect-style** system built on **Socket.io**. All devices logged into the same Navidrome account on the same network see each other and can share or transfer playback in real time.

| Capability | Details |
|---|---|
| **Device discovery** | Automatic; devices appear instantly when Audiorr is opened |
| **Transfer playback** | Hand off the current song + queue + position to another device |
| **Remote control** | Control play/pause, next, previous, seek, and volume from any device |
| **Receiver mode** | Turn any device (TV, Raspberry Pi, smart hub) into a pure speaker |
| **Google Cast** | Cast music to Chromecast, Google Nest Hub, or Android TV |
| **Scrobble awareness** | Only the controlling device (not receivers) records listening history |
| **Drift compensation** | 2-second tolerance for position sync between devices |
| **Session persistence** | Close the tab and your queue + position are waiting when you return |

### 🖼️ Canvas — Spotify-like Video Loops
- Each song can display a looping video or image sourced from a local proxy to the Spotify Canvas API.
- Available in a side panel, or as an immersive fullscreen overlay.
- Requires a local Spotify search proxy to be configured.

### 🎨 Rich UI & UX
- **Dark / Light / System** theme support.
- **Framer Motion animations** throughout: page transitions, panel slides, list reorders.
- **Dominant color extraction** from album art to create dynamic gradients behind artist profiles.
- **Infinite scroll** on Albums, Genres, and Artist pages.
- **Virtual lists** for large libraries.
- **Context menus** on every song with full playlist management (add, remove, create new).
- **Smart Playlist detection:** Navidrome smart playlists are automatically detected and protected from accidental modification.
- **Playlist management:** Create, rename, delete playlists; add songs from any context menu.
- **Spotify Sync:** Automatically mirrors your Spotify playlists into Navidrome on a 24-hour cron cycle (requires local Spotify proxy).
- **Artist profiles:** Full biography, avatar, collaborations, dynamic gradient background.
- **Album detail:** Full metadata (release date, label, explicit flag), cover art modal, per-song context menu.
- **Song detail:** Advanced metadata, similar tracks, playback shortcuts.
- **Genre browser:** All genres with infinite scroll and per-genre album views.
- **Global search:** Debounced, results grouped by type (songs, albums, artists, playlists).
- **Scrobbling:** Listens are reported to Navidrome (for Last.fm) and to `wrapped.db` on the backend simultaneously.

---

## 📱 iOS App

Audiorr is available as a native iOS application built with **Capacitor**, wrapping the React frontend in a **WKWebView** with native Swift extensions for iOS-specific features.

### Native iOS Features
| Feature | Implementation |
|---|---|
| **Background audio** | `AVAudioSession` plugin (Swift) — music continues when screen is locked or app is in background |
| **Lock screen & Control Center** | `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` — full Now Playing card with artwork, seek bar, and transport controls |
| **Interruption handling** | `AVAudioSessionInterruptionNotification` — pauses on phone call, Siri, or other audio apps; resumes after |
| **Safe areas** | Dynamic Island, notch, and home indicator are respected with `env(safe-area-inset-*)` CSS |
| **Status bar** | Styled per theme (dark/light) via `@capacitor/status-bar` |
| **Network resilience** | Instant reconnect on WiFi ↔ cellular transitions via `@capacitor/network` listener |
| **Haptic feedback** | Subtle vibration on key actions via `@capacitor/haptics` |

### What works identically to the web version
All UI, routing, animations, Smart Mix, Daily Mixes, Audiorr Connect multi-device sync, lyrics, Canvas, playlist management, search, and artist/album/genre browsing function identically on iOS. The Capacitor bridge is transparent to the React application.

### What requires your own server
Audiorr connects to **your own Navidrome server** — the iOS app does not stream from any third-party service. You must have a Navidrome instance accessible on your network (or via HTTPS from outside). This is a self-hosted music player.

---

## 🔧 Technology Stack

| Layer | Technology | Role |
|---|---|---|
| **UI Framework** | React 18 + TypeScript | Component architecture, typed throughout |
| **Build tool** | Vite 5 | Fast dev server, optimized production builds |
| **Styling** | Tailwind CSS 3 + Framer Motion | Responsive design, fluid animations |
| **Audio** | Web Audio API + HTML Audio (fallback) | Crossfade, ReplayGain, analysis hooks |
| **Real-time** | Socket.io client v4 | Audiorr Connect multi-device sync |
| **iOS** | Capacitor 6 + Swift plugins | Native audio session, lock screen, safe areas |
| **Lyrics** | [LRCLib](https://lrclib.net/) | Synchronized and plain-text lyrics |
| **Artist images** | Deezer API | Artist avatars |
| **Music library** | Navidrome (Subsonic API) | All browsing, playback, and playlist API |
| **Device discovery** | mDNS / Bonjour | LAN device discovery for Connect |
| **State** | React Context (Player, Connect, Settings, Theme, Sidebar) | Global state without external lib |

---

## 📁 Project Structure

```
src/
├── components/       UI components (pages, panels, modals, controls)
├── contexts/         Global state (PlayerContext, ConnectContext, SettingsContext, ThemeContext, SidebarContext)
├── hooks/            Custom hooks (useCanvas, useDominantColors, useContextMenu, usePinnedPlaylists, …)
├── services/         API clients and utilities
│   ├── navidromeApi.ts      Navidrome / Subsonic client
│   ├── backendApi.ts        Audiorr Backend client (Connect, mixes, analysis, stats)
│   ├── audio/               Modular Web Audio system (CrossfadeEngine, DJMixingAlgorithms, AudioEffectsChain)
│   └── webAudioPlayer.ts    Main audio player
├── utils/            Shared helpers (Smart Mix sorting, artist utils, cache helpers)
├── types/            TypeScript interfaces (Device, PlaybackState, Session, …)
└── assets/           Icons, logos, static assets
```

---

## 🚀 Running Locally (Web)

```bash
# Install dependencies
npm install

# Start development server
npm run dev

# Build for production
npm run build

# Preview production build
npm run preview
```

On first launch, enter your Navidrome server URL and credentials in the connection screen. The app will connect directly to your Navidrome instance.

---

## 📦 Deployment (Docker)

The frontend can be served as a static build or via Docker:

```bash
# Build image
docker build -t audiorr-web:latest .

# Run
docker run -p 2998:2998 audiorr-web:latest
```

The frontend is exposed on port `2998` by default.

> For full functionality (Smart Mix, Daily Mixes, weekly stats, multi-device sync), deploy the **Audiorr Backend** on the same network. See [`backend/README.md`](backend/README.md).

---

## 🔗 Backend Integration

The Audiorr Backend (`backend/`) is a separate Node.js service that unlocks advanced features:

| Feature | Without Backend | With Backend |
|---|---|---|
| Browse & play music | ✅ | ✅ |
| Playlists & search | ✅ | ✅ |
| Synchronized lyrics | ✅ (LRCLib direct) | ✅ |
| Smart Crossfade (simple) | ✅ | ✅ |
| Audiorr Connect multi-device | ❌ | ✅ |
| Smart Mix (harmonic ordering) | ❌ | ✅ |
| Daily Mixes | ❌ | ✅ |
| Weekly Top 10 chart | ❌ | ✅ |
| Listening history (Wrapped) | ❌ | ✅ |
| Spotify playlist sync | ❌ | ✅ |
| Canvas (video loops) | ❌ | ✅ |

The backend communicates over local HTTP and WebSocket and is designed to run as a Docker container on your homelab.

---

## 🔒 Privacy & Data

- **All music is streamed from your own Navidrome server.** Audiorr does not have access to any music files or metadata other than what your server exposes.
- **Listening history** is stored in a local SQLite database on your backend server, never sent anywhere externally.
- **LRCLib** is queried for lyrics by song title and artist — no account or identifier is sent.
- **Deezer** is queried for artist images by artist name only.
- **No tracking, no analytics, no ads.**

---

## 🧩 Key Components Reference

| Component | Description |
|---|---|
| `NowPlayingBar` | Persistent playback bar: progress, volume, queue/lyrics/canvas toggles, analysis indicator |
| `PlayerContext` | Central audio engine: queue, crossfade, Smart Mix, scrobble, media session |
| `ConnectContext` | Socket.io client: device sync, remote control, scrobble relay |
| `LyricsPage` | Auto-scrolling synchronized lyrics with seek-on-tap |
| `PlaylistDetail` | Playlist view with Smart Mix, drag reorder, context menus |
| `DailyMixSection` | Daily Mix grid with auto-generate on first load |
| `HomePage` | Landing: Weekly Top 10, recent releases carousel, daily mixes, latest albums |
| `DevicePicker` | Connect device selector with type-aware icons |
| `ReceiverPage` | Full-screen receiver mode for TV/hub devices |
| `CanvasPanel` / `CanvasPage` | Side panel and fullscreen Canvas video viewer |
| `QueuePanel` | Drag-and-drop queue with clear/remove actions |
| `SongContextMenu` | Per-song action menu: queue, playlists, navigate to artist/album/detail |
| `SearchBar` | Global debounced search with grouped results |
| `AlbumCarousel` | Auto-play carousel for recent releases |

---

## 🎛️ Audiorr Connect — Architecture Summary

```
                    LOCAL NETWORK
┌──────────────────────────────────────────────────────┐
│                                                      │
│  ┌──────────────────────────────────────────────┐    │
│  │       Audiorr Backend (Socket.io Hub)        │    │
│  │  • Session tokens (UUID, 24h TTL)             │    │
│  │  • Device registry (max 10/user)              │    │
│  │  • Playback state sync                        │    │
│  │  • Remote command routing                     │    │
│  │  • Scrobble dedup → listening history         │    │
│  └──────────────────────────────────────────────┘    │
│        ▲ WebSocket (token auth in handshake)          │
│        │                                              │
│   ┌────┴─────┐    ┌──────────┐    ┌───────────────┐  │
│   │  Mobile  │    │ Desktop  │    │  TV / Hub     │  │
│   │ (hybrid) │    │ (hybrid) │    │  (receiver)   │  │
│   │ ✅ scrobble  │  ✅ scrobble  │  🔇 suppressed │  │
│   └──────────┘    └──────────┘    └───────────────┘  │
└──────────────────────────────────────────────────────┘
```

- Devices are discovered automatically when Audiorr is opened on the same network.
- The controlling device emits scrobbles; receivers silently suppress duplicates.
- Google Cast / Chromecast is supported via the backend's mDNS discovery.

---

## 📝 License

This project is for personal use. All rights reserved.

---

<div align="center">
<i>Built with ❤️ for audiophiles who demand more from their music.</i>
</div>
