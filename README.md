# Audiorr

<div align="center">

**A native iOS music player for your Navidrome library — with a DSP crossfade engine you can hear**

*Your library. Mixed like you mean it.*

[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://developer.apple.com/swift/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-iOS_26+-007AFF?logo=apple&logoColor=white)](https://developer.apple.com/swiftui/)
[![AVAudioEngine](https://img.shields.io/badge/AVAudioEngine-Native_DSP-000000?logo=apple&logoColor=white)](https://developer.apple.com/documentation/avfaudio/avaudioengine)
[![Navidrome](https://img.shields.io/badge/Navidrome-Subsonic_API-1A1A1A?logo=subsonic&logoColor=white)](https://www.navidrome.org/)
[![LRCLib](https://img.shields.io/badge/LRCLib-Synced_Lyrics-0F62FE)](https://lrclib.net/)
[![CarPlay](https://img.shields.io/badge/CarPlay-Supported-333333?logo=apple&logoColor=white)](https://developer.apple.com/carplay/)

</div>

---

## What Audiorr is

Audiorr is a **native iOS client for [Navidrome](https://www.navidrome.org/)** (and any Subsonic-compatible server). Point it at your server, log in, and your entire self-hosted library lives on your iPhone — wrapped in a custom audio pipeline written from scratch in Swift.

The whole audio path is ours: a dual-player engine with sample-level crossfade, four cascaded biquad filters per channel, ReplayGain loudness control and a peak limiter on the master bus. No streaming service, no cloud catalogue, no tracking. Just your music, on your hardware, sounding the way it was recorded.

> **Two tiers, no surprises.** Everything in **[What you get out of the box](#what-you-get-out-of-the-box)** works with nothing but a Navidrome server — that's the complete, self-contained experience. If you also run a homelab, there's an optional second layer in **[Power-user mode](#power-user-mode--audiorr-backend-optional)** that turns the crossfade engine into a full DJ. The app never advertises what you can't use: backend features simply don't appear unless the backend is there.

---

## What you get out of the box

**All you need is a Navidrome (or Subsonic) server.** Connect it and everything below is available immediately, on every device, fully offline-capable. No extra infrastructure, no account, no homelab.

### Your whole library, the way you left it

- Full Subsonic browsing — albums, artists, playlists, search and queue.
- A **Home** built from your own server: recent releases, genres, latest additions, recently played, and a *Discover Something New* shuffle to dig back into your collection.
- Light/Dark theme with system override.

### Playback that sounds right

- **Dual-player gapless crossfade** with a real DSP engine — not a volume dip. Two players run through four cascaded biquad filters per channel, so the outgoing track thins out as the incoming one opens up.
- **Seven filter presets** on a real-time DSP node: highpass sweeps, low-shelf bass swap, parametric mid scoop, high-shelf cleanup.
- **ReplayGain v2** loudness normalization with Apple's `kAudioUnitSubType_PeakLimiter` on the master mixer to catch inter-sample peaks — no track jumps out louder than the rest.
- **Automatic transcoding** of VBR MP3 and other troublesome formats to PCM, transparent to the listener.

> Out of the box, Audiorr blends every transition with a smooth, conservative crossfade. The engine doing the work is the real thing — the same DSP graph the DJ layer drives. What the standalone app *doesn't* do is make the smart calls (which transition, where to come in, beat-matching). That intelligence needs per-track analysis, and that's exactly what the optional **[Audiorr Backend](#power-user-mode--audiorr-backend-optional)** adds. Without it you still get a clean, great-sounding crossfade — you just don't get the DJ.

### Synchronized lyrics

- Pulled from **LRCLib**, plus any lyrics embedded in your own server's files.
- Karaoke-style scroll locked to the audio position.
- Tap any line to seek to that timestamp.
- Falls back to plain text when no timed data is available.

### Offline, done properly

- **Auto-cache** every song you play to a persistent store.
- **Pre-cache** the next three songs in the queue, so you never hit a buffer.
- **Manual downloads** for entire albums or playlists in one tap.
- **Background downloads** that keep going when the app is suspended.
- **Pin protection** for content you never want auto-evicted.
- **LRU eviction** on a configurable cache limit (default 2 GB).
- A fully browsable offline library when there's no network at all.

```
  Triggers                          Engine                           Persistent store
  ┌─────────────────────────┐       ┌──────────────────────┐         ┌───────────────────────┐
  │ Auto-cache              │       │ DownloadManager      │         │ OfflineStorageManager │
  │  every song you play    │──────>│  URLSession          │────────>│  on-disk, survives    │
  │                         │       │  .background(id:)    │         │  cold launch          │
  │ Pre-cache              │──────>│  - keeps going while │         │                       │
  │  next 3 in the queue    │       │    app is suspended  │         │  ┌─────────────────┐  │
  │                         │       │  - resumable         │         │  │ pinned          │  │
  │ Manual download        │──────>│  - progress + dedupe │         │  │ never evicted   │  │
  │  album / playlist · 1 tap│      └──────────────────────┘         │  └─────────────────┘  │
  └─────────────────────────┘                                       │  LRU eviction         │
                                                                    │  (2 GB default cap)   │
  ┌─────────────────────────┐                                       └──────────┬────────────┘
  │ NWPathMonitor          │   no network ──> playback + full browse ──────────┘
  │  reachability watch     │                 served straight from local store
  └─────────────────────────┘
```

### Now Playing, everywhere

- Mini player + full Now Playing viewer with a hero animation on the album art.
- Synced **lock screen, Control Center and Dynamic Island** transport controls.
- **CarPlay** — full template-based browsing and playback, with I/O buffers tuned per connection (40 ms wireless, 20 ms wired).

### Private by design

- **Every track streams from your own Navidrome server.** Audiorr never touches a streaming service or cloud catalogue.
- **No tracking. No analytics. No ads.**
- The only call Audiorr makes on its own is to **LRCLib** for lyrics — by song title and artist name only.
- Credentials live in the iOS Keychain. Your listening data lives only where you put it.

---

## Power-user mode — Audiorr Backend (optional)

> **Heads up:** this entire section is **optional** and requires you to self-host a separate server on your own machine. **Most people will never run it — and they don't need to.** Everything above is the complete Audiorr experience. This is the deep end for people who already run a homelab and want their library to mix itself.

If you also deploy the **[Audiorr Backend](https://github.com/cha0sisme/Audiorr-backend)** (Node.js + SQLite) on your LAN, it analyzes your library offline and unlocks a second layer of features. The app detects the backend on launch and **only shows these features when it's reachable** — without it, none of this appears in the UI, and nothing feels missing.

This is where the crossfade engine stops being a smart fade and becomes a DJ.

### The DJ layer

| Feature | What it does |
|---|---|
| **AutoMix DJ** | The brain that turns the crossfade engine into a real DJ. Reading the backend's per-track analysis, it makes every transition decision: entry point, fade duration, transition type, filter preset, bass-swap timing, time-stretch ratio, anticipation. Beat-aligned bass kills and sweeping resonant filters fire only when the data says they'll sound good. Fields it consumes include `bpm` (with confidence), `key`/`camelotKey`, `energyProfile`, `rmsCurve`, `percussiveCurve`, `harmonicCurve`, `onsetDensity`, vocal segments and song structure. |
| **Smart Mix** | Reorders any playlist for the best possible flow — Camelot-wheel harmonic compatibility, energy arc, BPM progression with half/double-tempo matching, vocal-clash avoidance, artist diversity, key-fatigue tracking. Greedy sequencing followed by windowed 2-opt optimization, run on-device against backend analysis. |

### Knows your taste

| Feature | What it does |
|---|---|
| **Smart Playlists** | Three playlists the backend regenerates nightly from your listening history: forgotten favorites, your current rotation, and new releases from artists you already know. |
| **Daily Mixes** | Up to five personalized mixes, rebuilt every night. Balances the familiar with the new; fewer than five if your recent history is short. |
| **Jump Back In** | Recent listening contexts resurfaced on the Home screen, so you can pick up right where you left off. |
| **Related Albums** | "If you like this" suggestions on every album detail page, drawn from your own library. |

### Stats and presence

| Feature | What it does |
|---|---|
| **Top Weekly & Rewind** | A weekly Top chart, weekly listening stats, and **Audiorr Rewind** — your year in music, generated from plays recorded in the backend's own store. All queryable from your own clients only; nothing is scrobbled to an external service. |
| **Pinned Playlists** | Pin the playlists you live in to the top of your Home. |
| **Listening Now** | See what other users on your server are playing right now, in real time. |
| **Audiorr Connect** | Spotify-Connect-style multi-device control over Socket.io: transfer playback, remote-control any device, run a receiver-only screen. |
| **Canvas & Motion Artwork** | Looping video and animated album art in the Now Playing viewer. Canvas is sourced from Spotify's service via the backend (requires server-side Spotify credentials; only for tracks that exist on Spotify). |

The backend runs in a Docker container on your LAN and is **never required** for the App Store experience. Deploy it if and when you want the deeper integration — setup lives in the backend repository.

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

The crossfade decision system is a pure analyzer with no side effects: it consumes a `TransitionProfile` (BPM relationship, energy flow, vocal overlap risk, harmonic compatibility, style affinity, character) and emits the full plan — entry point, transition type, filter preset, bass-swap time, DJ-effect flags, time-stretch ratios, anticipation — in one pass. Every output is testable in isolation. (This is the analysis the **Audiorr Backend** feeds; standalone, the picker falls back to a single conservative crossfade.)

---

## Companion projects

- **Audiorr Backend** — Node.js + SQLite analysis server. Optional, self-hosted. Powers AutoMix DJ, Smart Mix, Daily Mixes, Connect, Canvas, Rewind and listening stats. Currently kept as a private self-hosted service; release plan TBD.
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
