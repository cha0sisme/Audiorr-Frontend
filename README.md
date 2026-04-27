# Audiorr

<div align="center">

**Audiophile-grade music player for Navidrome with native DSP crossfade engine**

*Native iOS — Pure Swift from UI to audio render thread*

[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://developer.apple.com/swift/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-iOS_18+-007AFF?logo=apple&logoColor=white)](https://developer.apple.com/swiftui/)
[![AVAudioEngine](https://img.shields.io/badge/AVAudioEngine-Native_DSP-000000?logo=apple&logoColor=white)](https://developer.apple.com/documentation/avfaudio/avaudioengine)
[![SwiftData](https://img.shields.io/badge/SwiftData-Persistence-34C759?logo=apple&logoColor=white)](https://developer.apple.com/xcode/swiftdata/)
[![CarPlay](https://img.shields.io/badge/CarPlay-Supported-333333?logo=apple&logoColor=white)](https://developer.apple.com/carplay/)

</div>

---

Audiorr is a fully native iOS music player built on [Navidrome](https://www.navidrome.org/) (Subsonic-compatible). It features a custom real-time DSP pipeline written entirely in Swift — 4 cascaded biquad filters per channel with lock-free coefficient passing, beat-aligned bass management, DJ effects, and 8 transition algorithms — all running on CoreAudio's render thread at sample-level precision.

## Standalone vs Bundle

Audiorr ships in two configurations:

| | **Audiorr Standalone** | **Audiorr Bundle** (Frontend + Backend) |
|---|---|---|
| **Requires** | Any Navidrome/Subsonic server | Navidrome + Audiorr Backend (Node.js) |
| **Audio engine** | Full native DSP pipeline | Same |
| **Crossfade** | DJ-grade with 8 transition types | Same + backend audio analysis (BPM, key, energy, vocals, structure) |
| **Smart Mix** | -- | v3.0 "Harmonic Flow" playlist reordering |
| **Daily Mixes** | -- | 5 personalized mixes |
| **Multi-device sync** | -- | Audiorr Connect (Socket.io) |
| **Weekly chart** | -- | Global Top 10 |
| **Canvas** | -- | Spotify-like video loops |
| **Listening stats** | -- | History, Wrapped |
| **Setup** | Connect to Navidrome, play | Deploy backend, connect both |

The app detects backend availability automatically and hides backend-exclusive features when unavailable. Standalone playback is fully functional — no degraded experience.

---

## Audio Engine

### Architecture

```
                          ┌──────────────────────────────────────────────────────────┐
                          │                   AVAudioEngine Graph                     │
                          │                                                          │
  ┌───────────┐    ┌──────┴──────┐    ┌──────────────┐    ┌─────────┐    ┌─────────┐ │
  │ playerA   │───>│ timePitchA  │───>│ BiquadDSPNode│───>│ mixerA  │──┐ │         │ │
  │ (outgoing)│    │ rate/pitch  │    │ 4x biquad    │    │ vol/pan │  │ │         │ │
  └───────────┘    └─────────────┘    │ Band 0: HPF  │    └─────────┘  │ │  main   │ │
                                      │ Band 1: LSF  │                 ├>│  mixer  │───> limiter ───> output
  ┌───────────┐    ┌─────────────┐    │ Band 2: PEQ  │    ┌─────────┐  │ │         │ │
  │ playerB   │───>│ timePitchB  │───>│ Band 3: HSF  │───>│ mixerB  │──┘ │         │ │
  │ (incoming)│    │ rate/pitch  │    └──────────────┘    │ vol/pan │    └─────────┘ │
  └───────────┘    └─────────────┘                        └─────────┘               │
                          └──────────────────────────────────────────────────────────┘

  Automation Thread (60Hz)                     Render Thread (CoreAudio real-time)
  ┌──────────────────────────┐                 ┌────────────────────────────────────┐
  │ CrossfadeExecutor        │                 │ BiquadDSPKernel                    │
  │  filterTick() @ 16ms     │ ── trylock ──>  │  process() per buffer (~5ms)       │
  │  - volume curves         │   coefficients  │  - Direct Form II Transposed       │
  │  - filter coefficient    │                 │  - 5 mul + 4 add per sample/stage  │
  │    calculation           │                 │  - denormal flush                  │
  │  - bass swap logic       │                 │  - isPassthrough skip              │
  │  - DJ effects            │                 └────────────────────────────────────┘
  │  - stereo separation     │
  │  - time-stretch ramp     │
  └──────────────────────────┘
```

### DSP Pipeline — `BiquadDSPNode` (Standalone)

Custom `AUAudioUnit` v3 subclass registered in-process via `AUAudioUnit.registerSubclass()`. Each channel (A and B) has its own DSP node with **4 cascaded second-order IIR filters** (biquad) implementing Direct Form II Transposed — the most numerically stable topology for 32-bit float.

| Band | Filter Type | Purpose | Frequency | Automation |
|------|------------|---------|-----------|------------|
| **0** | Highpass (2nd order) | Spectral separation — thins out outgoing track | 400 Hz -> 8 kHz sweep | Exponential ramp with pivot at 60% |
| **0** | Lowpass (2nd order) | Energy-down transitions — darkening sweep | 20 kHz -> 800 Hz sweep | Exponential ramp (replaces HPF) |
| **1** | Low Shelf | Bass management — coordinated A/B bass swap | 200 Hz fixed | Linear ramp to `bassSwapTime` (downbeat-aligned) |
| **2** | Parametric EQ | Vocal anti-clash — dip mids on outgoing track | 1.5 kHz, 1.0-1.5 oct BW | Linear ramp with pivot |
| **3** | High Shelf | Hi-hat/cymbal cleanup | 8 kHz | Linear ramp with pivot |

**Coefficient formulas:** All from Robert Bristow-Johnson's *Audio EQ Cookbook* (1998). Input clamping (frequency to Nyquist, gain to +/-60 dB) and `safeNormalize()` with NaN/Inf guard ensure numerical stability under all parameter combinations.

**Thread model:**
- **Automation thread** (`com.audiorr.crossfade.automation`, QoS `.userInteractive`): `DispatchSourceTimer` at 16ms (~60 Hz). Computes coefficients and stages them via `os_unfair_lock`.
- **Render thread** (CoreAudio real-time): `BiquadDSPKernel.process()` uses `os_unfair_lock_trylock` (non-blocking). If contended, uses previous coefficients — imperceptible at 60 Hz update rate.
- **Zero allocation** on the render path. All state pre-allocated at init. POD structs (`BiquadCoefficients`, `BiquadState`) — no ARC, no heap.

### DJ Effects (Standalone)

Two DJ effects that augment the filter pipeline during crossfade transitions. Both are conservative — they only activate when analysis data confirms they'll sound good.

#### Bass Kill

Instant low-frequency cut synchronized to the beat grid. Replaces the gradual bass swap (Band 1) with a DJ fader-style kill:

```
Time ──────────────────────────────────────────────────────────►
                           bassSwapTime (downbeat-aligned)
                                │
  A lowshelf (Band 1):   0 dB ─┤── 100ms ramp ──► -60 dB (silence)
                                │
  B lowshelf (Band 1):  -8 dB ─┤── 100ms ramp ──►   0 dB (full)
                                │
                          SYNCHRONIZED SWAP
```

The 100ms anti-click ramp prevents pops from abrupt coefficient changes in the biquad delay line. Both channels are coordinated: B holds at `startGain` until the kill moment, then opens simultaneously — preventing bass pile-up.

**Activation criteria:** `bpmTrusted` + `danceability > 0.5` + `fadeDuration > 4s` + character `punch` or `dramatic-up` + compatible transition type (not CUT/NATURAL_BLEND).

#### Dynamic Q Resonance

Bell-shaped Q modulation on the highpass sweep (Band 0). Creates the classic DJ "sweeping filter" resonance — the audible "wah" at the cutoff frequency as it sweeps up.

```
Q factor
  4.0 ┤         ╭──╮
  3.5 ┤        ╭╯  ╰╮         ← Gaussian bell, peak at 55%
  3.0 ┤       ╭╯    ╰╮
  2.0 ┤      ╭╯      ╰╮
  1.1 ┤──────╯        ╰──────  ← base Q (preset)
      └─────────────────────── crossfade progress (0% → 100%)
           25%  55%  85%
```

Gaussian bell centered at 55% of crossfade duration (aligned with the most active sweep phase before pivot). Hard-clamped at Q = 4.0 to prevent filter self-oscillation. Exponent clamped at -10 to prevent `expf()` underflow.

**Activation criteria:** Not energy-down (no highpass active) + `fadeDuration > 4s` + `danceability > 0.45` + character `punch` or `dramatic`.

### Crossfade Intelligence — `DJMixingService` v4.0 "Chameleon Mix" (Bundle-enhanced)

Pure analysis engine — no side effects, no audio. Computes the optimal transition strategy for any A->B pair.

**Standalone behavior:** Basic crossfade with configurable duration. Filter presets based on transition type.

**Bundle behavior:** Full acoustic analysis from backend (BPM, key, energy profile, vocal segments, structure, danceability, beat grid) drives every decision:

| Decision | Data Used | Output |
|----------|-----------|--------|
| **Entry point** | `introEndTime`, `chorusStartTime`, `vocalStartTime`, `phraseBoundaries`, `downbeatTimes` | Where B starts playing |
| **Fade duration** | `outroStartTime`, `backendFadeInDuration`, energy profile, style affinity | 2-15s adaptive |
| **Transition type** | BPM relationship, energy flow, vocal overlap risk, harmonic compatibility | 1 of 8 types |
| **Filter preset** | Energy direction, instrumental detection, danceability | 1 of 6 presets |
| **Bass swap timing** | `downbeatTimesB`, `beatIntervalB`, transition type | Downbeat-aligned wall-clock time |
| **DJ effects** | `bpmConfidence`, `danceability`, character, energy flow | Bass Kill, Dynamic Q on/off |
| **Time-stretch** | BPM diff (harmonic-normalized), confidence, max 8% rate change | A and B rates |
| **Anticipation** | Entry point headroom, transition type | 0-4s filtered preview |
| **Trigger bias** | Character, bass conflict, vocal overlap, style affinity | -5s to +2s shift |

#### Transition Profile

The A-B relationship is captured as a `TransitionProfile` — computed once, drives all downstream decisions:

- **BPM Relationship**: identical (<3 diff) / compatible (3-12) / incompatible (>12), with harmonic normalization (half/double tempo)
- **Energy Flow**: up / down / steady, from per-section energy profiles (intro/main/outro)
- **Vocal Overlap Risk**: none / A-only / B-only / both — from `speechSegments`, `introVocals`, `outroVocals`, `lastVocalTime`
- **Harmonic Compatibility**: Camelot Wheel distance (compatible / acceptable / tense / clash)
- **Style Affinity**: 0-1 composite (BPM 35%, energy 25%, harmony 25%, danceability 15%)
- **Character**: punch / smooth / dramatic / minimal — determines the transition's personality

#### 8 Transition Types

| Type | Volume Curve A | Volume Curve B | When |
|------|---------------|----------------|------|
| `CROSSFADE` | S-curve hold->drop (70% at 45%) | S-curve sin^2 complement | Default |
| `EQ_MIX` | Gradual descent (65% at 50%), cos^2 drop | S-curve to 50%, sin^2 ramp | Compatible BPMs, filters do separation |
| `BEAT_MATCH_BLEND` | Same as EQ_MIX | Same as EQ_MIX | Beat-synced + compatible BPMs |
| `NATURAL_BLEND` | Pure cos^2 | Pure sin^2 (constant power) | Incompatible BPMs, gentle |
| `CUT` | Hold full, exponential drop (3s) | Late entry, linear ramp (1.5s) | Short fades, extreme BPM diff |
| `CUT_A_FADE_IN_B` | Hold 85% to 45%, exponential drop | S-curve ease | A abrupt ending |
| `FADE_OUT_A_CUT_B` | Hold full to 75%, exponential drop | Late firm entry at 55% | B abrupt start |
| `STEM_MIX` | Hold 95% to 75%, fast exit | Filtered to vocals/mids, late ramp | Vocal overlap + beat sync |

#### 6 Filter Presets

| Preset | HPF A Sweep | Lowshelf A | Mid Scoop | Hi-Shelf | When |
|--------|------------|------------|-----------|----------|------|
| **Normal** | 400 -> 4k -> 8k Hz, Q 1.1 | 0 -> -6 -> -14 dB | 1.5 kHz, -12 dB | 8 kHz, -8 dB | Default |
| **Aggressive** | 600 -> 2.5k -> 5k Hz, Q 1.2 | 0 -> -10 -> -18 dB | 1.5 kHz, -16 dB | 8 kHz, -10 dB | Vocal clash, bass conflict |
| **Anticipation** | 600 -> 2.5k -> 5k Hz, Q 1.2 | 0 -> -8 -> -16 dB | 1.5 kHz, -15 dB | 8 kHz, -10 dB | Short fades with intro headroom |
| **Energy-Down** | Bypassed (40 Hz) | 0 -> -4 -> -10 dB | 1.5 kHz, -8 dB | None (LPF handles) | B less energetic than A |
| **Gentle** | 60 -> 150 -> 300 Hz, Q 0.5 | 0 -> -4 -> -8 dB | 1.5 kHz, -6 dB | 8 kHz, -4 dB | NATURAL_BLEND |
| **Stem Mix** | 200 -> 1.5k -> 6k Hz, Q 1.0 | 0 -> -12 -> -20 dB | 1.5 kHz, -14 dB | 8 kHz, -10 dB | STEM_MIX |

Energy-Down uses a **lowpass sweep** (20 kHz -> 800 Hz) on Band 0 instead of highpass — the outgoing song "goes dark" instead of thinning out.

### Additional Audio Features (Standalone)

- **ReplayGain v2 / EBU R128 normalization:** Per-track level normalization with True Peak limiter on `mainMixerNode`.
- **Automatic transcoding:** VBR MP3 and incompatible formats transcoded to CAF (PCM 16-bit 44.1 kHz) for AVAudioEngine compatibility.
- **Stereo micro-separation:** During crossfade, A pans -0.08 left, B pans +0.08 right (ramps with progress). Reduces spectral masking without audible stereo shift.
- **Energy compensation:** +2 to +4 dB boost on quieter incoming tracks to prevent perceived loudness drops.
- **Time-stretch:** Automatic tempo matching (+/-12 BPM) via `AVAudioUnitTimePitch` with beat-quantized rate ramp (S-curve smoothing, max 8% rate change).
- **Safety mechanisms:** Vocal Trainwreck evasion, anti-polyrhythm CUT override (>35 BPM diff), 25% track length limit, BPM confidence gating.
- **CarPlay:** Full browsing + playback with optimized IO buffer (40ms wireless, 20ms wired).
- **AVPlayer streaming fallback:** Transparent fallback when files need buffering, with seamless handoff to AVAudioEngine once downloaded.

---

## Features

### Standalone (Navidrome only)

#### Playback
- Native AVAudioEngine dual-player pipeline with custom DSP
- Gapless crossfade with 8 transition algorithms and 6 filter presets
- DJ effects: Bass Kill (beat-synced instant low cut) + Dynamic Q Resonance (filter sweep with bell-shaped Q)
- Beat-aligned bass swap on actual downbeats
- ReplayGain v2 / EBU R128 normalization with True Peak limiter
- Time-stretch tempo matching (+/-12 BPM, beat-quantized)
- CarPlay with full browsing and playback

#### Synchronized Lyrics
- Fetched via **LRCLib** for every playing song
- Real-time karaoke-style scroll locked to audio position
- Tap any line to seek directly to that timestamp
- Graceful fallback to plain text when no timed data available

#### Offline Mode
- **Auto-cache:** Every played song saved to persistent storage
- **Pre-cache:** Next 3 songs pre-downloaded in background
- **Manual downloads:** Entire albums or playlists with one tap
- **Background downloads:** Continue when app is suspended (background URLSession)
- **Pin protection:** Pin content to prevent auto-eviction
- **LRU eviction:** Oldest unpinned content removed when cache exceeds limit (default 2 GB)
- **Dual-cache:** Hot temp cache (5 files, instant playback) + persistent SwiftData-tracked cache
- **Offline browsing:** HomeView shows all downloaded albums and playlists when offline
- **Smart skip:** Only skips uncached songs when truly offline AND playback fails
- **Storage management:** Visual storage bar, limit picker, clear cache in Settings

#### Library & Navigation
- Full Subsonic API browsing (albums, artists, playlists, search)
- Queue management with reordering, add/remove, persistent state
- Lock Screen & Control Center with full Now Playing card
- Dynamic Island live activity for current track
- Hero transitions for album/playlist art
- Dark/Light theme with system override

### Bundle-Exclusive (require Audiorr Backend)

#### Smart Mix v3.0 "Harmonic Flow"
- Reorders any playlist using multi-factor scoring:
  - **Camelot Wheel** harmonic compatibility with energy boost key jump recognition
  - **Harmonic BPM matching** (half/double tempo via `harmonicBPM`)
  - **Energy arc** — builds from gentle opener to peak, then descends
  - **BPM arc progression** — gradual tempo build-up with natural descent
  - **Vocal trainwreck avoidance** — graduated penalty when both tracks have vocals
  - **Smooth energy valley detection** — continuous gradient penalty prevents lulls
  - **Artist diversity** — proximity-based same-artist penalty
  - **Key fatigue tracking** — penalizes repeating same key 3+ times
- **Closing song selection** — low energy, slow BPM, fading outro
- Greedy sequencing + local 2-opt optimization (windowed +/-20 positions)

#### Daily Mixes
- Up to 5 personalized mixes based on listening history
- 70/30 familiarity/discovery rule with deterministic clustering
- Auto-generated at 03:00 UTC daily

#### Global Weekly Top 10
- Server-wide top 10 most-played songs
- Trend indicators (up, down, same, New) vs last week

#### Multi-Device Sync — Audiorr Connect
Spotify Connect-style system built on Socket.io:

| Capability | Details |
|---|---|
| **Device discovery** | Automatic — devices appear instantly |
| **Transfer playback** | Song + queue + position to another device |
| **Remote control** | Play/pause, next, previous, seek, volume |
| **Receiver mode** | Turn any device into a pure speaker |
| **Scrobble awareness** | Only controlling device records history |
| **Session persistence** | Queue + position preserved on return |

#### Canvas
- Spotify-like looping video or image per song in Now Playing viewer

#### Jump Back In
- Recently played albums and playlists on HomeView

---

## Architecture

### iOS App — Native SwiftUI

| Layer | Technology | Role |
|---|---|---|
| **UI** | SwiftUI (iOS 18+) | All views, navigation, animations |
| **Audio** | AVAudioEngine + custom AUAudioUnit v3 | DSP pipeline, crossfade, gapless playback |
| **DSP** | BiquadDSPNode (Swift, real-time safe) | 4-stage biquad filter + DJ effects |
| **Persistence** | SwiftData + UserDefaults + Keychain | Offline cache, queue state, credentials |
| **Networking** | URLSession (foreground + background) | Streaming, downloads, API calls |
| **Connectivity** | NWPathMonitor | Offline detection, Wi-Fi/cellular awareness |
| **CarPlay** | CPTemplate API | Full browsing and playback |
| **Lock Screen** | MPNowPlayingInfoCenter + MPRemoteCommandCenter | Now Playing card, transport controls |
| **Real-time** | Socket.io (URLSession WebSocket) | Audiorr Connect multi-device sync |

### Project Structure

```
ios/App/
├── App/
│   ├── AppDelegate.swift              App lifecycle, audio session, CarPlay, background downloads
│   ├── MainSceneDelegate.swift        Main UI scene
│   ├── CarPlaySceneDelegate.swift     CarPlay template browsing + playback
│   ├── AudioEngineManager.swift       AVAudioEngine dual-player pipeline, crossfade, streaming
│   ├── AudioFileLoader.swift          Download + transcode + dual-cache (temp + persistent)
│   ├── CrossfadeExecutor.swift        Crossfade state machine v3.0 "Phantom Cut" + DJ effects
│   │
│   ├── DSP/
│   │   ├── BiquadDSPNode.swift        AUAudioUnit v3 wrapper — public API for engine graph
│   │   ├── BiquadDSPKernel.swift      Real-time render: 4 cascaded biquad, lock-free coefficients
│   │   ├── BiquadCoefficients.swift   POD coefficient struct (zero ARC, audio-thread safe)
│   │   └── BiquadCoefficientCalculator.swift  Audio EQ Cookbook formulas (HPF, LPF, LSF, PEQ, HSF)
│   │
│   ├── Models/
│   │   ├── NavidromeModels.swift      API response models (Song, Album, Artist, Playlist)
│   │   └── OfflineModels.swift        SwiftData models (CachedSong, DownloadTask, DownloadGroup)
│   │
│   ├── Services/
│   │   ├── NavidromeService.swift     Subsonic API client (streaming, browsing, playlists)
│   │   ├── PlayerService.swift        High-level playback API (play, queue, context tracking)
│   │   ├── QueueManager.swift         Queue state, crossfade orchestration, pre-cache, scrobble
│   │   ├── DJMixingService.swift      Crossfade intelligence v4.0 "Chameleon Mix"
│   │   ├── AnalysisCacheService.swift Audio analysis cache (BPM, key, energy, segments)
│   │   ├── SmartMixManager.swift      SmartMix v3.0 "Harmonic Flow" — playlist reordering
│   │   ├── DownloadManager.swift      Background URLSession download engine (priority queue, retry)
│   │   ├── OfflineStorageManager.swift Persistent cache (SwiftData + Library/Caches, LRU eviction)
│   │   ├── OfflineContentProvider.swift Offline browsing queries
│   │   ├── NetworkMonitor.swift       NWPathMonitor connectivity awareness
│   │   ├── PersistenceService.swift   UserDefaults for playback state + offline settings
│   │   ├── CredentialsStore.swift     Keychain storage for server credentials
│   │   ├── ScrobbleService.swift      Navidrome + backend scrobbling with retry queue
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
│       ├── Home/HomeView.swift        Landing: Weekly Top, Jump Back In, releases, mixes
│       ├── Albums/AlbumDetailView.swift Album hero + song list + download
│       ├── Artists/
│       │   ├── ArtistsView.swift      Artist grid with search
│       │   └── ArtistDetailView.swift Artist profile + discography
│       ├── Playlists/
│       │   ├── PlaylistsView.swift    Playlist grid
│       │   └── PlaylistDetailView.swift Playlist hero + SmartMix + download
│       ├── Search/SearchView.swift    Global search (songs, albums, artists)
│       ├── Settings/
│       │   ├── SettingsView.swift     App settings (DJ mode, ReplayGain, scrobbling)
│       │   ├── LoginView.swift        Server connection screen
│       │   └── StorageManagementView.swift Offline cache management UI
│       ├── NowPlaying/
│       │   ├── NowPlayingViewerView.swift Full-screen Now Playing
│       │   ├── ProgressBarView.swift  Seek bar
│       │   ├── PlaybackControlsView.swift Transport controls
│       │   ├── LyricsView.swift       Synchronized lyrics overlay
│       │   ├── QueuePanelView.swift   Queue management panel
│       │   ├── CanvasView.swift       Video loop viewer
│       │   ├── DevicePickerView.swift Audiorr Connect device selector
│       │   └── AddToPlaylistView.swift Playlist picker
│       └── Shared/
│           ├── SongListView.swift     Song table with context menus + cached indicator
│           ├── MiniPlayerView.swift   Persistent mini player
│           ├── AlbumCardView.swift    Album thumbnail with retry
│           ├── ArtistCardView.swift   Artist avatar with retry
│           ├── PlaylistCardView.swift Playlist cover with multi-source fallback
│           ├── DownloadButton.swift   Download indicator (progress ring, states, pin/unpin)
│           ├── HorizontalScrollSection.swift Horizontal carousel container
│           └── SeeAllGridView.swift   Full grid for "See All" navigation
```

### Offline Storage Architecture

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

## DSP Technical Details

### Why Swift for Real-Time DSP

The entire DSP pipeline — from coefficient calculation to sample-level biquad processing — is written in **Swift**, not C/C++. This is a deliberate architectural decision:

1. **Proven in production.** `BiquadDSPKernel` processes audio on CoreAudio's real-time thread. 4 biquad stages x 2 channels x 48 kHz = ~3.5M operations/second. Running in production with zero reported glitches.

2. **Trivial CPU load.** At 48 kHz with 512-frame buffers, the render callback budget is ~10.7ms. The DSP processing path consumes < 0.1ms — including all 4 filter stages. Even with 6 DJ effects active simultaneously, total DSP load stays under 1ms.

3. **Real-time safety by discipline, not language:**
   - `BiquadCoefficients` and `BiquadState` are POD structs — zero ARC, zero heap allocation
   - `os_unfair_lock` with `trylock` on the render thread (never blocks)
   - Pre-allocated arrays with fixed indices (never append/remove in render path)
   - Denormal flush: values < 1e-15 snapped to zero to prevent ARM CPU spikes

4. **Single-language coherence.** No bridging headers, no mixed C++/Swift builds, no dual memory models, no dual debuggers. The coefficient calculator, the kernel, and the automation engine all share the same type system.

**When C++ would be necessary:** DAWs with dozens of simultaneous plugin chains, granular synthesizers with thousands of grains, convolution reverb with multi-second impulse responses, or cross-platform (iOS + Android + Desktop) plugin distribution. Audiorr is none of these — it's a music player with crossfade effects.

### Biquad Filter Implementation

**Topology:** Direct Form II Transposed — chosen for numerical stability with 32-bit float coefficients.

```
y[n] = b0*x[n] + z1
z1   = b1*x[n] - a1*y[n] + z2
z2   = b2*x[n] - a2*y[n]
```

5 multiplies + 4 adds per sample per stage. All coefficients pre-normalized (divided by a0).

**Coefficient Safety:**
- Frequency clamped to [20 Hz, Nyquist - 1 Hz]
- Gain clamped to +/-60 dB
- `safeNormalize()` returns passthrough if any coefficient is NaN/Inf
- `isPassthrough` epsilon comparison (1e-6) to skip inactive stages in the render loop

### Lock-Free Coefficient Passing

```
Automation (60Hz)                    Render (CoreAudio RT)
     │                                    │
     ├── lock(&lock)                      │
     ├── write pendingCoefficients[]      │
     ├── hasPending = true                │
     ├── unlock(&lock)                    │
     │                                    ├── trylock(&lock)
     │                                    │   ├── success: copy pending → active
     │                                    │   └── fail: use previous (skip 1 tick = 16ms)
     │                                    ├── process 4 stages in series
     │                                    └── denormal flush
```

The render thread **never blocks**. If the automation thread is writing coefficients at the exact moment the render thread needs them, the render thread uses the previous values. At 60 Hz coefficient updates, skipping one 16ms frame is imperceptible.

---

## Privacy & Data

- **All music streams from your own Navidrome server.** Audiorr never accesses external music.
- **Listening history** stored in local SQLite on your backend server, never sent externally.
- **LRCLib** queried for lyrics by song title and artist only.
- **No tracking, no analytics, no ads.**

---

## Requirements

- iOS 18.0+
- A Navidrome server (self-hosted)
- Xcode 16+ (to build from source)
- Optional: Audiorr Backend (Node.js) for bundle features

---

## License

This project is for personal use. All rights reserved.

---

<div align="center">
<i>Built for audiophiles who hear the difference.</i>
</div>
