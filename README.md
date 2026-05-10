# Audiorr

<div align="center">

**A native iOS music player for your Navidrome library — with a DSP crossfade engine you can hear**

*Pure Swift from the UI down to the audio render thread.*

[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://developer.apple.com/swift/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-iOS_26+-007AFF?logo=apple&logoColor=white)](https://developer.apple.com/swiftui/)
[![AVAudioEngine](https://img.shields.io/badge/AVAudioEngine-Native_DSP-000000?logo=apple&logoColor=white)](https://developer.apple.com/documentation/avfaudio/avaudioengine)
[![Navidrome](https://img.shields.io/badge/Navidrome-Subsonic_API-1A1A1A?logo=subsonic&logoColor=white)](https://www.navidrome.org/)
[![LRCLib](https://img.shields.io/badge/LRCLib-Synced_Lyrics-0F62FE)](https://lrclib.net/)
[![CarPlay](https://img.shields.io/badge/CarPlay-Supported-333333?logo=apple&logoColor=white)](https://developer.apple.com/carplay/)

</div>

---

## What Audiorr is

Audiorr is a **native iOS client for [Navidrome](https://www.navidrome.org/)** (and any Subsonic-compatible server). Plug your server URL, log in, and you have your entire self-hosted library on your iPhone with a custom audio pipeline that competes with — and in some areas exceeds — the major streaming apps.

The whole audio path is written from scratch in Swift: a dual-player engine with sample-level crossfade, four cascaded biquad filters per channel, and a transition decision system that listens to the music and picks the right blend instead of forcing one default fade for everything.

## What you get out of the box

You only need a Navidrome (or Subsonic) server. Connect, and these features are available immediately on every device:

### Playback that sounds right

- **Dual-player gapless crossfade** with eleven transition algorithms (`CROSSFADE`, `EQ_MIX`, `BEAT_MATCH_BLEND`, `NATURAL_BLEND`, `CUT`, `CUT_A_FADE_IN_B`, `FADE_OUT_A_CUT_B`, `STEM_MIX`, `DROP_MIX`, `CLEAN_HANDOFF`, `VINYL_STOP`). Audiorr picks one per song pair. *Without the optional backend, the picker falls back to a conservative default crossfade — the per-track analysis that drives the smarter choices comes from the backend.*
- **Seven filter presets** running on a real-time DSP node: highpass sweeps, low-shelf bass swap, parametric mid scoop, high-shelf cleanup. The outgoing track thins out while the incoming track opens up.
- **DJ-grade effects**: instant beat-aligned bass kill and bell-shaped Q resonance for the "sweeping filter" sound. Activate when analysis data confirms they'll sound good (the backend supplies that data).
- **ReplayGain v2** loudness normalization with Apple's `kAudioUnitSubType_PeakLimiter` on the master mixer to catch inter-sample peaks.
- **Tempo matching** within ±12 BPM using `AVAudioUnitTimePitch`, beat-quantized so the rate ramp lands on the downbeat. Requires backend BPM data.
- **Automatic transcoding** of VBR MP3 and other troublesome formats to PCM, transparent to the listener.

### Library and navigation

- Full Subsonic API browsing — albums, artists, playlists, search, queue.
- Mini player + Now Playing viewer with hero animation on album art.
- Synced **lock screen, Control Center, and Dynamic Island** with transport controls.
- Light/Dark theme with system override.

### Synchronized lyrics

- Pulled from **LRCLib** for any song that has them.
- Karaoke-style scroll locked to the audio position.
- Tap any line to seek to that timestamp.
- Falls back to plain text when no timed data is available.

### Offline mode

- **Auto-cache** every song you play to a persistent store.
- **Pre-cache** the next three songs in the queue so you never see a buffer.
- **Manual downloads** for entire albums or playlists with one tap.
- **Background downloads** continue when the app is suspended.
- **Pin protection** for content you don't want auto-evicted.
- **LRU eviction** on a configurable cache size limit (default 2 GB).
- Browse and play your offline library when there's no network at all.

### CarPlay

- Full template-based browsing and playback with optimized I/O buffers (40 ms wireless, 20 ms wired).

---

## Privacy and data

- **All your music streams from your own Navidrome server.** Audiorr never reaches out to a streaming service or cloud catalogue.
- **No tracking. No analytics. No ads.**
- The only outbound calls Audiorr makes on its own are to **LRCLib** for lyrics, by song title and artist name only.
- Credentials live in the iOS Keychain. Listening data lives only where you put it.

---

## Power-user mode — Audiorr Backend (optional)

If you also self-host the **[Audiorr Backend](https://github.com/cha0sisme/Audiorr-backend)** (Node.js + SQLite) on your own homelab, Audiorr unlocks a second tier of features that depend on offline audio analysis of your library.

The app detects whether the backend is reachable on launch and only shows these features when it is. **Without the backend, none of this is missed in the UI** — the standalone experience is fully self-contained.

| Feature | What it does |
|---|---|
| **Smart Mix** | The iOS app reorders any playlist using the backend's per-track analysis: Camelot-wheel harmonic compatibility, energy arc, BPM progression with half/double-tempo harmonic matching, vocal-trainwreck avoidance, artist diversity, key-fatigue tracking. Greedy sequencing followed by windowed 2-opt optimization. The algorithm runs on-device; the analysis it consumes lives on the backend. |
| **Smart Playlists** | The backend generates three rotating playlists nightly from your listening history: *Tiempo Atrás* (forgotten tracks), *En Bucle* (your current rotation), *Radar de Novedades* (new releases from artists you know). |
| **Daily Mixes** | Up to five personalized mixes regenerated every night at 03:00 UTC. Familiarity/discovery balance with deterministic clustering. The "five" is the cap — fewer if your 30-day history is short. |
| **AutoMix DJ** | The crossfade engine reads the backend's per-track analysis to drive every transition decision: entry point, fade duration, transition type, filter preset, bass-swap timing, time-stretch ratio, anticipation. Fields consumed include `bpm` with confidence, `key`/`camelotKey`, `energyProfile`, `rmsCurve`, `rmsTailCurve`, `percussiveCurve`, `harmonicCurve`, `onsetDensity`, vocal segments, song structure. |
| **Audiorr Connect** | Spotify-Connect-style multi-device control over Socket.io. Transfer playback, remote-control any device, receiver-only mode. |
| **Canvas** | Looping video or still per song in the Now Playing viewer, sourced from Spotify's Canvas service via the backend. Requires Spotify credentials configured server-side; only works for tracks present on Spotify. |
| **Listening stats** | The backend records every play in its own SQLite store and exposes weekly Top 10 and Wrapped-style yearly summaries — all queryable only from your own clients. The backend itself does not scrobble to external services; that happens on the iOS side if you enable Last.fm there. |

The backend runs in a Docker container on your LAN and is not required for the App Store experience. Deploy when (and if) you want the deeper integration — see the backend repository for setup.

---

## Tech stack

| Layer | Choice |
|---|---|
| UI | SwiftUI on iOS 26+ |
| Audio engine | `AVAudioEngine` with custom dual-player graph |
| DSP | Custom `AUAudioUnit` v3 — 4 cascaded biquads (Direct Form II Transposed), real-time-safe Swift |
| Persistence | SwiftData + UserDefaults + Keychain |
| Networking | `URLSession` foreground + background |
| Connectivity | `NWPathMonitor` |
| CarPlay | `CPTemplate` API |
| Now Playing | `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` |
| Optional remote control | Socket.io over WebSocket |
| Lyrics | LRCLib REST |
| Server protocol | Subsonic API |

---

## For the curious — audio engine deep dive

The DSP pipeline is written entirely in Swift. No C/C++ bridging, no Obj-C wrappers. The reasons are documented in `CrossfadeExecutor.swift` and `BiquadDSPKernel.swift` — short version: at 48 kHz with 512-frame buffers the render budget is ~10.7 ms, the four-stage biquad path consumes <0.1 ms, and Swift gives single-language coherence with the rest of the app. Real-time safety is enforced by discipline (POD structs, `os_unfair_lock_trylock`, no allocations on the render path, denormal flush) rather than by language.

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

  Automation Thread (60 Hz)                    Render Thread (CoreAudio real-time)
  ┌──────────────────────────┐                 ┌────────────────────────────────────┐
  │ CrossfadeExecutor        │                 │ BiquadDSPKernel                    │
  │  filterTick() @ 16 ms    │ ── trylock ──>  │  process() per buffer (~5 ms)      │
  │  - volume curves         │   coefficients  │  - Direct Form II Transposed       │
  │  - filter coefficient    │                 │  - 5 mul + 4 add per sample/stage  │
  │    calculation           │                 │  - denormal flush                  │
  │  - bass swap logic       │                 │  - isPassthrough skip              │
  │  - DJ effects            │                 └────────────────────────────────────┘
  │  - stereo separation     │
  │  - time-stretch ramp     │
  └──────────────────────────┘
```

Filter formulas come from Robert Bristow-Johnson's *Audio EQ Cookbook* (1998). Frequencies clamp to `[20 Hz, Nyquist − 1 Hz]`, gains clamp to ±60 dB, `safeNormalize()` returns passthrough on NaN/Inf, and stages with all-zero coefficients are skipped via `isPassthrough` epsilon comparison.

The crossfade decision system is a pure analyzer with no side effects: it consumes a `TransitionProfile` (BPM relationship, energy flow, vocal overlap risk, harmonic compatibility, style affinity, character) and emits the full plan — entry point, transition type, filter preset, bass-swap time, DJ-effect flags, time-stretch ratios, anticipation — in one pass. Every output is testable in isolation.

---

## Companion projects

- **Audiorr Backend** — Node.js + SQLite analysis server. Optional. Powers Smart Mix, AutoMix, Daily Mixes, Connect, Canvas, listening stats. Currently kept as a private self-hosted service; release plan TBD.
- **[Audiorr Web](https://github.com/cha0sisme/Audiorr-web)** — SvelteKit web client for the same Navidrome + backend setup. Different surface, same philosophy.

---

## Requirements

- iOS 26.0 or later
- A Navidrome (or Subsonic-compatible) server
- Optional: Audiorr Backend on your own LAN for power-user features
- Xcode 16 or later to build from source

---

## License

This project is for personal use. All rights reserved.

---

<div align="center">
<i>Built for people who hear the difference.</i>
</div>
