/**
 * NativeAudioPlayer — Drop-in replacement for WebAudioPlayer.
 * Delegates all audio to native AVAudioEngine via NativeAudioPlugin.
 * JS stays as "brain" (queue, scrobble, DJMixingAlgorithms).
 */

import type { PluginListenerHandle } from '@capacitor/core'
import type { Song } from './navidromeApi'
import { navidromeApi } from './navidromeApi'
import type { AudioAnalysisResult } from '../hooks/useAudioAnalysis'
import type {
  WebAudioPlayerConfig,
  PlaybackState,
  WebAudioPlayerCallbacks,
  MixMode,
} from './audio/types'
import { calculateCrossfadeConfig } from './audio/DJMixingAlgorithms'
import {
  nativeAudio,
  type TimeUpdateEvent,
  type PlaybackStateEvent,
  type CrossfadeCompleteEvent,
  type ErrorEvent,
  type RemoteCommandEvent,
  type NativeNextEvent,
} from './nativeAudio'

// Re-export types for compatibility
export type { WebAudioPlayerConfig, PlaybackState, WebAudioPlayerCallbacks }

export class NativeAudioPlayer {
  // === State (synced via native events) ===
  private currentSong: Song | null = null
  private nextSong: Song | null = null
  private currentAnalysis: AudioAnalysisResult | null = null
  private nextAnalysis: AudioAnalysisResult | null = null
  private isPlayingState = false
  private isCrossfadingState = false
  // True only after a play() call has fully resolved (native confirmed playback).
  // False on construction, after stop(), and after errors.
  // Used by togglePlayPause to decide: resume() (fast, engine has audio) vs playSong() (full reload).
  private nativeEngineLoaded = false
  private duration = 0
  private currentTime_ = 0
  private volume = 0.75
  private isDjMode = false
  private useReplayGain = true
  private callbacks: WebAudioPlayerCallbacks = {}

  // Clock sync
  private lastNativeTime = 0
  private lastTimestamp = 0
  private driftCheckInterval: ReturnType<typeof setInterval> | null = null

  // Play sequence counter: the core mechanism for handling rapid song switching.
  // Each play() call increments playSequence. When the native call resolves,
  // it checks if it's still the latest request. If superseded (user tapped another
  // song while this one was loading), it discards the result silently.
  // This is the same pattern Spotify/Apple Music use internally.
  //
  // Event filtering: onTimeUpdate/onPlaybackStateChanged only process events when
  // playSequence === confirmedSequence (i.e., no play() in flight). This prevents
  // stale events from Song A corrupting Song B's state during the transition.
  private playSequence = 0
  private confirmedSequence = 0

  // Timeout for native play() calls — if native bridge hangs (network stall,
  // bad URL, iOS audio system freeze), the promise would hang indefinitely
  // leaving the app in an unrecoverable state. This mirrors what Spotify does.
  private static readonly PLAY_TIMEOUT_MS = 20_000

  // Heartbeat watchdog: detects "UI says playing but native stopped sending updates".
  // If no onTimeUpdate arrives for WATCHDOG_SILENCE_MS while isPlayingState is true,
  // fires onError so PlayerContext can attempt recovery.
  private static readonly WATCHDOG_SILENCE_MS = 8_000
  private watchdogTimer: ReturnType<typeof setTimeout> | null = null
  private lastEventTimestamp = 0

  // Block stale crossfade events after manual skip.
  // Set true by clearAutomixTrigger(), false by setAutomixTrigger()/startCrossfade().
  private blockCrossfadeEvents = false
  // Timestamp of last play() call — used to detect stale onTrackEnd from playerA.stop()
  private lastPlayTimestamp = 0

  // Native event listeners
  private listeners: PluginListenerHandle[] = []

  constructor() {
    this.setupNativeListeners()
  }

  // === Event listeners from native ===

  private async setupNativeListeners(): Promise<void> {
    this.listeners.push(
      await nativeAudio.addListener('onTimeUpdate', (data: TimeUpdateEvent) => {
        // Ignorar eventos durante transición de canción. Cuando play() está en
        // vuelo (playSequence !== confirmedSequence), los eventos del bridge son
        // de la canción ANTERIOR y corromperían el progreso de la nueva.
        if (this.playSequence !== this.confirmedSequence) return

        // Si el nativo dice que está reproduciendo pero JS cree que no (e.g., tras
        // watchdog timeout o reconexión), sincronizar el estado JS con la realidad.
        // Sin esto, el progreso se congela indefinidamente tras recuperación del watchdog.
        if (!this.isPlayingState && data.isPlaying) {
          console.log('[NativeAudioPlayer] Sincronizando isPlayingState con nativo (was false, native says true)')
          this.isPlayingState = true
          this.nativeEngineLoaded = true
          this.startWatchdog()
          this.callbacks.onPlaybackStateChanged?.(true, data.currentTime, 'native-sync')
        }

        this.lastNativeTime = data.currentTime
        this.lastTimestamp = Date.now()
        this.currentTime_ = data.currentTime
        this.duration = data.duration
        // Feed the watchdog — native is alive and sending updates
        this.lastEventTimestamp = Date.now()
        this.callbacks.onTimeUpdate?.(data.currentTime, data.duration)
      }),
      await nativeAudio.addListener('onTrackEnd', () => {
        // Guard: when play(newSong) calls native play(), Swift does playerA.stop()
        // which fires the OLD song's completion handler → onTrackEnd. This stale event
        // arrives AFTER the new play() resolved (isPlayingState=true). A real track end
        // can't happen within 2s of play() starting, so use a timestamp guard.
        const timeSincePlay = Date.now() - this.lastPlayTimestamp
        if (timeSincePlay < 2000) {
          console.log(`[NativeAudioPlayer] Ignoring stale onTrackEnd — play() was ${timeSincePlay}ms ago`)
          return
        }
        this.isPlayingState = false
        // Sync sequences to unblock events for the next play() call
        this.confirmedSequence = this.playSequence
        // Si el crossfade estaba "activo" cuando la pista terminó, algo salió mal — resetear
        if (this.isCrossfadingState) {
          console.warn('[NativeAudioPlayer] Track ended during crossfade — resetting crossfade state')
          this.isCrossfadingState = false
        }
        this.callbacks.onEnded?.()
      }),
      await nativeAudio.addListener('onCrossfadeStart', () => {
        // Si un skip manual puso blockCrossfadeEvents=true, el timer nativo
        // pudo haber disparado crossfade antes de recibir el clear. Ignorar.
        if (this.blockCrossfadeEvents) {
          console.warn('[NativeAudioPlayer] Ignoring stale onCrossfadeStart — manual skip in progress')
          nativeAudio.cancelCrossfade().catch(() => {})
          return
        }
        this.isCrossfadingState = true
        this.callbacks.onCrossfadeStart?.()
      }),
      await nativeAudio.addListener('onCrossfadeComplete', (data: CrossfadeCompleteEvent) => {
        // Ignorar crossfade complete si fue resultado de un crossfade que debimos haber cancelado.
        if (this.blockCrossfadeEvents) {
          console.warn('[NativeAudioPlayer] Ignoring stale onCrossfadeComplete — manual skip in progress')
          this.isCrossfadingState = false
          return
        }
        this.isCrossfadingState = false
        // Crossfade completed a valid song transition — ensure events flow for the new song
        this.confirmedSequence = this.playSequence
        if (this.nextSong) {
          const completedSong = this.nextSong
          this.currentSong = this.nextSong
          this.currentAnalysis = this.nextAnalysis
          this.nextSong = null
          this.nextAnalysis = null
          this.callbacks.onCrossfadeComplete?.(completedSong, data.startOffset)
        }
      }),
      await nativeAudio.addListener('onPlaybackStateChanged', (data: PlaybackStateEvent) => {
        // Suppress stale state changes during song transition (same reason as onTimeUpdate)
        if (this.playSequence !== this.confirmedSequence) return

        const wasPlaying = this.isPlayingState
        this.isPlayingState = data.isPlaying
        this.currentTime_ = data.currentTime
        // Notificar a React cuando el estado cambia por causa externa
        // (interrupción por llamada, BT desconectado, etc.)
        if (wasPlaying !== data.isPlaying) {
          this.callbacks.onPlaybackStateChanged?.(data.isPlaying, data.currentTime, data.reason)
        }
      }),
      await nativeAudio.addListener('onRemoteCommand', (_data: RemoteCommandEvent) => {
        // Next/previous delegated from native
        // These are handled by PlayerContext via a separate listener
      }),
      await nativeAudio.addListener('onError', (data: ErrorEvent) => {
        console.error(`[NativeAudioPlayer] Error: ${data.code} — ${data.message}`)
        this.callbacks.onError?.(new Error(data.message))
      }),
      await nativeAudio.addListener('onNativeNext', (data: NativeNextEvent) => {
        // Native hizo next directamente (JS estaba congelado en background).
        // Sincronizar estado JS con lo que nativo ya está reproduciendo.
        console.log(`[NativeAudioPlayer] Native next ejecutado en background: ${data.title}`)
        this.currentTime_ = 0
        this.lastNativeTime = 0
        this.lastTimestamp = Date.now()
        this.duration = data.duration || 0
        this.isPlayingState = true
        this.isCrossfadingState = false
        this.nextSong = null
        this.nextAnalysis = null
        // Notificar a PlayerContext que nativo cambió de canción
        this.callbacks.onNativeNext?.(data)
      }),
    )
  }

  // === Public interface (identical to WebAudioPlayer) ===

  setCallbacks(callbacks: WebAudioPlayerCallbacks): void {
    this.callbacks = callbacks
  }

  setConfig(config: Partial<WebAudioPlayerConfig>): void {
    if (config.volume !== undefined) {
      this.volume = config.volume / 100
      nativeAudio.setVolume({ volume: this.volume }).catch(() => {})
    }
    if (config.isDjMode !== undefined) {
      this.isDjMode = config.isDjMode
    }
    if (config.useReplayGain !== undefined) {
      this.useReplayGain = config.useReplayGain
    }
  }

  setCurrentAnalysis(analysis: AudioAnalysisResult | null): void {
    this.currentAnalysis = analysis
  }

  setNextAnalysis(analysis: AudioAnalysisResult | null): void {
    this.nextAnalysis = analysis
  }

  isCrossfadeSupported(): boolean {
    return true
  }

  hasSource(): boolean {
    return this.currentSong !== null
  }

  isCurrentlyPlaying(): boolean {
    return this.isPlayingState
  }

  /** True if a play() call has succeeded and the native engine has audio loaded.
   *  False after construction, stop(), or error. Used by togglePlayPause to decide
   *  between resume() (fast) and playSong() (full reload from network). */
  isEngineLoaded(): boolean {
    return this.nativeEngineLoaded
  }

  // === Playback ===

  async play(song: Song, streamUrl: string, keepPosition = false): Promise<void> {
    // Increment sequence FIRST — this immediately invalidates any in-flight play()
    // calls and suppresses stale native events (onTimeUpdate checks playSequence !== confirmedSequence).
    const seq = ++this.playSequence
    this.lastPlayTimestamp = Date.now()
    console.log(`[NativeAudioPlayer] Play (seq=${seq}): ${song.title}`)

    // Cancel any in-progress or scheduled crossfade/automix from the previous song.
    this.clearAutomixTrigger()
    nativeAudio.cancelCrossfade().catch(() => {})
    this.isCrossfadingState = false

    this.currentSong = song
    const startAt = keepPosition ? this.currentTime_ : 0
    const rg = this.extractReplayGain(song)

    // Resetear estado de tiempo ANTES de la llamada nativa.
    this.currentTime_ = startAt
    this.lastNativeTime = startAt
    this.lastTimestamp = Date.now()

    // Wrap native call with a timeout — if the bridge hangs (network stall,
    // iOS audio system freeze), reject after PLAY_TIMEOUT_MS so the app can recover.
    await Promise.race([
      nativeAudio.play({
        url: streamUrl,
        songId: song.id,
        startAt,
        replayGainDb: rg.gainDb,
        trackPeak: rg.trackPeak,
        duration: song.duration || 0,
        title: song.title || '',
        artist: typeof song.artist === 'string' ? song.artist : '',
        album: song.album || '',
      }),
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error(`play() timeout after ${NativeAudioPlayer.PLAY_TIMEOUT_MS}ms`)),
          NativeAudioPlayer.PLAY_TIMEOUT_MS)
      ),
    ])

    // ─── Stale call guard ───────────────────────────────────────────────
    // If the user tapped another song while this one was loading,
    // playSequence will have been incremented by the newer call.
    // Discard this result silently — only the latest play() matters.
    if (this.playSequence !== seq) {
      console.log(`[NativeAudioPlayer] Discarding stale play() result (seq=${seq}, current=${this.playSequence})`)
      return
    }

    // This is the latest play() — confirm it so events start flowing again
    this.confirmedSequence = seq
    this.isPlayingState = true
    this.nativeEngineLoaded = true
    this.duration = song.duration || 0

    // Update NowPlaying metadata
    this.updateNowPlaying(song)

    // Start clock sync + watchdog
    this.startDriftCorrection()
    this.startWatchdog()

    this.callbacks.onCanPlay?.()
    this.callbacks.onLoadedMetadata?.(this.duration)
  }

  pause(): void {
    console.log(`[NativeAudioPlayer] Pause called (was isPlaying=${this.isPlayingState}, currentTime=${this.currentTime_})`)
    nativeAudio.pause().catch(() => {})
    this.isPlayingState = false
    this.stopWatchdog()
  }

  async resume(): Promise<void> {
    console.log(`[NativeAudioPlayer] Resume called (was isPlaying=${this.isPlayingState}, currentTime=${this.currentTime_})`)
    await nativeAudio.resume()
    this.isPlayingState = true
    this.startWatchdog()
  }

  seek(time: number): void {
    this.currentTime_ = time
    this.lastNativeTime = time
    this.lastTimestamp = Date.now()
    nativeAudio.seek({ time }).catch(() => {})
  }

  setVolume(volume: number): void {
    this.volume = volume / 100
    nativeAudio.setVolume({ volume: this.volume }).catch(() => {})
  }

  stop(): void {
    nativeAudio.stop().catch(() => {})
    this.isPlayingState = false
    this.isCrossfadingState = false
    this.nativeEngineLoaded = false
    // Sync sequences so events aren't blocked after stop
    this.confirmedSequence = this.playSequence
    this.currentSong = null
    this.currentTime_ = 0
    this.duration = 0
    this.stopDriftCorrection()
    this.stopWatchdog()
  }

  // === Preload & Prepare ===

  async preloadBuffer(songId: string, url: string): Promise<void> {
    // Pre-download to native cache
    try {
      await nativeAudio.prepareNext({
        url,
        songId,
      })
    } catch (e) {
      console.warn('[NativeAudioPlayer] Preload failed:', e)
    }
  }

  /** Warms the Swift AudioFileLoader cache for a future song — fire and forget.
   *  Does NOT touch playerB or crossfade config (unlike prepareNextSong).
   *  When the user taps "next", AudioFileLoader returns the cached file instantly. */
  warmCacheFor(songId: string, url: string): void {
    nativeAudio.preloadAudio({ url, songId }).catch(() => {})
  }

  async prepareNextSong(song: Song, streamUrl: string, analysis?: AudioAnalysisResult): Promise<void> {
    console.log(`[NativeAudioPlayer] Preparing next: ${song.title}`)
    this.nextSong = song
    this.nextAnalysis = analysis ?? null

    const rg = this.extractReplayGain(song)

    await nativeAudio.prepareNext({
      url: streamUrl,
      songId: song.id,
      replayGainDb: rg.gainDb,
      trackPeak: rg.trackPeak,
    })

    // Enviar metadata de la siguiente canción al nativo para NowPlaying en background
    nativeAudio.setNextSongMetadata({
      title: song.title || '',
      artist: song.artist || '',
      album: song.album || '',
      duration: song.duration || 0,
    }).catch(() => {})
  }

  // === Crossfade ===

  startCrossfade(): void {
    if (!this.nextSong || this.isCrossfadingState) return
    // JS inicia crossfade deliberadamente — permitir eventos de crossfade
    this.blockCrossfadeEvents = false

    const mode: MixMode = this.isDjMode ? 'dj' : 'normal'

    const config = calculateCrossfadeConfig({
      currentAnalysis: this.currentAnalysis,
      nextAnalysis: this.nextAnalysis,
      bufferADuration: this.duration,
      bufferBDuration: this.nextSong.duration || 180,
      mode,
      currentPlaybackTimeA: this.getCurrentTime(),
    })

    console.log(`[NativeAudioPlayer] Crossfade: ${config.transitionType} | fade=${config.fadeDuration.toFixed(1)}s | entry=${config.entryPoint.toFixed(1)}s`)
    if (config.beatSyncInfo) {
      console.log(`[NativeAudioPlayer] ${config.beatSyncInfo}`)
    }

    nativeAudio.executeCrossfade({
      entryPoint: config.entryPoint,
      fadeDuration: config.fadeDuration,
      transitionType: config.transitionType,
      useFilters: config.useFilters,
      useAggressiveFilters: config.useAggressiveFilters,
      needsAnticipation: config.needsAnticipation,
      anticipationTime: config.anticipationTime,
    }).catch(e => {
      console.error('[NativeAudioPlayer] executeCrossfade failed:', e)
      this.isCrossfadingState = false
      // Sync sequences so events aren't permanently blocked after failed crossfade
      this.confirmedSequence = this.playSequence
      // Notify JS that crossfade couldn't start — PlayerContext will fall back to playSong
      this.callbacks.onCrossfadeFailed?.()
    })

    // Update NowPlaying for the incoming song
    if (this.nextSong) {
      this.updateNowPlaying(this.nextSong)
    }
  }

  // === Time ===

  getCurrentTime(): number {
    if (!this.isPlayingState) return this.currentTime_
    // Interpolate between native updates
    const elapsed = (Date.now() - this.lastTimestamp) / 1000
    const interpolated = this.lastNativeTime + elapsed
    // No permitir que la extrapolación de JS supere la duración de la canción,
    // especialmente durante crossfade esto causa que la bolita salte fuera.
    return this.duration > 0 ? Math.min(this.duration, interpolated) : interpolated
  }

  getPlaybackState(): PlaybackState {
    return {
      currentSong: this.currentSong,
      isPlaying: this.isPlayingState,
      currentTime: this.getCurrentTime(),
      duration: this.duration,
      volume: this.volume * 100,
      isCrossfading: this.isCrossfadingState,
    }
  }

  hasActiveMedia(): boolean {
    return this.currentSong !== null
  }

  // === Background Automix ===

  /** Envía trigger time + config de crossfade al nativo para background automix */
  setAutomixTrigger(triggerTime: number, crossfadeConfig: {
    entryPoint: number; fadeDuration: number; transitionType: string
    useFilters: boolean; useAggressiveFilters: boolean
    needsAnticipation: boolean; anticipationTime: number
  }): void {
    // Nuevo ciclo de automix — desbloquear eventos de crossfade.
    this.blockCrossfadeEvents = false
    nativeAudio.setAutomixTrigger({
      triggerTime,
      ...crossfadeConfig,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any).catch(() => {})
  }

  clearAutomixTrigger(): void {
    // Bloquear eventos de crossfade hasta que JS inicie uno legítimo.
    // Esto previene que un crossfade nativo en vuelo (timer disparó antes del clear)
    // contamine el estado JS durante un skip manual.
    this.blockCrossfadeEvents = true
    nativeAudio.clearAutomixTrigger().catch(() => {})
  }

  /** JS confirma que procesó un remote command — cancela fallback nativo */
  ackRemoteCommand(): void {
    nativeAudio.ackRemoteCommand().catch(() => {})
  }

  /** Reconcilia estado JS con nativo tras volver de background */
  async reconcileState(): Promise<void> {
    try {
      const state = await nativeAudio.getPlaybackState()
      this.isPlayingState = state.isPlaying
      this.currentTime_ = state.currentTime
      this.lastNativeTime = state.currentTime
      this.lastTimestamp = Date.now()
      this.duration = state.duration
      this.isCrossfadingState = state.isCrossfading
      // Ensure events flow after reconciliation
      this.confirmedSequence = this.playSequence
      console.log(`[NativeAudioPlayer] State reconciled: playing=${state.isPlaying}, time=${state.currentTime.toFixed(1)}s, song="${state.title}"`)
    } catch {
      // ignore
    }
  }

  // === Noop methods (not needed with native engine) ===

  setPauseTime(time: number): void {
    // Set currentTime_ so that play() with keepPosition=true uses the correct
    // start position. Critical for resume after app restart, where the saved
    // progress is in localStorage but NativeAudioPlayer was just created with currentTime_=0.
    this.currentTime_ = time
  }

  clearPreDecodeCache(): void {
    // noop — no pre-decode in native
  }

  releaseNonEssentialMemory(): void {
    // noop — AVAudioFile streams from disk
  }

  getMemoryStats(): { currentBuffer: number; nextBuffer: number; total: number } {
    return { currentBuffer: 0, nextBuffer: 0, total: 0 }
  }

  aggressiveMemoryCleanup(): void {
    // noop
  }

  dispose(): void {
    this.stopDriftCorrection()
    this.stopWatchdog()
    nativeAudio.stop().catch(() => {})

    // Remove all listeners
    for (const listener of this.listeners) {
      listener.remove()
    }
    this.listeners = []
  }

  // === Private helpers ===

  private extractReplayGain(song: Song): { gainDb: number; trackPeak: number } {
    if (!this.useReplayGain || !song.replayGain) {
      return { gainDb: -8.0, trackPeak: 0 }
    }

    const rawGain = song.replayGain.trackGain ?? song.replayGain.albumGain
    let gainDb = -8.0
    if (rawGain !== undefined && rawGain !== null) {
      const parsed = typeof rawGain === 'number' ? rawGain : parseFloat(String(rawGain).replace(',', '.'))
      if (!isNaN(parsed)) gainDb = parsed
    }

    const rawPeak = song.replayGain.trackPeak ?? song.replayGain.albumPeak
    let trackPeak = 0
    if (rawPeak !== undefined && rawPeak !== null) {
      const parsed = typeof rawPeak === 'number' ? rawPeak : parseFloat(String(rawPeak).replace(',', '.'))
      if (!isNaN(parsed) && parsed > 0) trackPeak = parsed
    }

    return { gainDb, trackPeak }
  }

  private updateNowPlaying(song: Song): void {
    // Usar navidromeApi.getCoverUrl para obtener URL absoluta con autenticación.
    // La URL relativa (/rest/...) no funciona desde Swift/URLSession.
    const artworkUrl = song.coverArt
      ? navidromeApi.getCoverUrl(song.coverArt, 600)
      : undefined

    nativeAudio.updateNowPlaying({
      title: song.title || '',
      artist: typeof song.artist === 'string' ? song.artist : '',
      album: song.album || '',
      duration: song.duration || 0,
      artworkUrl: artworkUrl || undefined,
    }).catch(() => {})
  }

  // === Clock sync with drift correction ===

  private async calibrateClock(): Promise<void> {
    try {
      const { nativeTime } = await nativeAudio.getClockSync()
      this.lastNativeTime = nativeTime
      this.lastTimestamp = Date.now()
    } catch {
      // ignore
    }
  }

  private startDriftCorrection(): void {
    this.stopDriftCorrection()
    this.calibrateClock()
    this.driftCheckInterval = setInterval(async () => {
      if (!this.isPlayingState) return
      try {
        const { nativeTime } = await nativeAudio.getClockSync()
        const expectedTime = this.getCurrentTime()
        const drift = Math.abs(nativeTime - expectedTime)
        if (drift > 0.4) {
          console.warn(`[ClockSync] Drift: ${(drift * 1000).toFixed(0)}ms, correcting`)
          this.lastNativeTime = nativeTime
          this.lastTimestamp = Date.now()
          this.currentTime_ = nativeTime
          this.callbacks.onTimeUpdate?.(nativeTime, this.duration)
        }
      } catch {
        // ignore
      }
    }, 10_000)
  }

  private stopDriftCorrection(): void {
    if (this.driftCheckInterval) {
      clearInterval(this.driftCheckInterval)
      this.driftCheckInterval = null
    }
  }

  // === Heartbeat watchdog ===
  // Detects "UI says playing but native stopped sending time updates".
  // This can happen if the native audio pipeline dies silently (e.g., after
  // deep iOS suspension, audio route loss, or an unhandled native error).
  // Without this, the user sees "playing" forever with a frozen progress bar
  // and has to force-quit the app.

  private startWatchdog(): void {
    this.stopWatchdog()
    this.lastEventTimestamp = Date.now()
    this.watchdogTimer = setTimeout(() => this.checkWatchdog(), NativeAudioPlayer.WATCHDOG_SILENCE_MS)
  }

  private checkWatchdog(): void {
    if (!this.isPlayingState) {
      // Not playing — no need to watch
      this.watchdogTimer = null
      return
    }
    const silence = Date.now() - this.lastEventTimestamp
    if (silence >= NativeAudioPlayer.WATCHDOG_SILENCE_MS) {
      console.warn(`[NativeAudioPlayer] ⚠️ Watchdog: no native events for ${(silence / 1000).toFixed(1)}s while playing — firing recovery`)
      this.isPlayingState = false
      this.nativeEngineLoaded = false
      this.callbacks.onPlaybackStateChanged?.(false, this.currentTime_, 'watchdog-silence')
      this.callbacks.onError?.(new Error('Watchdog: native audio stopped responding'))
      this.watchdogTimer = null
      return
    }
    // Re-arm
    this.watchdogTimer = setTimeout(() => this.checkWatchdog(), NativeAudioPlayer.WATCHDOG_SILENCE_MS)
  }

  private stopWatchdog(): void {
    if (this.watchdogTimer) {
      clearTimeout(this.watchdogTimer)
      this.watchdogTimer = null
    }
  }
}
