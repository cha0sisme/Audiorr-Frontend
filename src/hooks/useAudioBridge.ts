import { useEffect, useRef } from 'react'
import { Capacitor } from '@capacitor/core'
import type { PluginListenerHandle } from '@capacitor/core'
import { usePlayerState, usePlayerProgress, usePlayerActions } from '../contexts/PlayerContext'
import { audioBridge } from '../services/audioBridge'
import { navidromeApi } from '../services/navidromeApi'

/**
 * Conecta el estado del reproductor con la capa nativa de iOS:
 *  - MPNowPlayingInfoCenter → pantalla de bloqueo, Control Center, CarPlay
 *  - MPRemoteCommandCenter → auriculares, pantalla de bloqueo, CarPlay controles
 *
 * Solo activo en plataforma nativa (Capacitor iOS/Android).
 */
export function useAudioBridge() {
  const isNative = Capacitor.isNativePlatform()
  const playerState    = usePlayerState()
  const playerProgress = usePlayerProgress()
  const playerActions  = usePlayerActions()

  // Con NativeAudioPlayer, AudioEngineManager maneja todo directamente en Swift:
  // - NowPlaying (MPNowPlayingInfoCenter) a 4Hz
  // - Remote commands (MPRemoteCommandCenter) → play/pause/seek nativos, next/prev via evento
  // - Interrupciones y route changes
  // - Keepalive no necesario (AVAudioEngine mantiene la sesión)
  // Este hook solo se necesita para el modo WebAudio/HTMLAudio (no nativo).
  const useNativeEngine = isNative // NativeAudioPlayer está activo en nativo

  // Ref para el progreso actual sin crear closures stale en el timer
  const progressRef = useRef(playerProgress.progress)
  useEffect(() => { progressRef.current = playerProgress.progress }, [playerProgress.progress])

  // Refs para calcular elapsedTime con reloj real (Date.now), independiente de
  // audioContext.currentTime que se congela cuando iOS suspende el AudioContext al bloquear pantalla
  const playbackStartTimestampRef = useRef<number>(0)
  const elapsedAtPlayStartRef = useRef<number>(0)

  useEffect(() => {
    if (playerState.isPlaying) {
      playbackStartTimestampRef.current = Date.now()
      elapsedAtPlayStartRef.current = progressRef.current
    }
  }, [playerState.isPlaying, playerState.currentSong?.id])

  // ── 1. Actualizar Now Playing cuando cambia la canción ─────────────────────
  useEffect(() => {
    if (!isNative || useNativeEngine) return

    const song = playerState.currentSong
    if (!song) {
      audioBridge.clearNowPlaying()
      return
    }

    const artist = Array.isArray(song.artist)
      ? (song.artist as unknown as { name: string }[]).map(a => a.name).join(', ')
      : String(song.artist || '')

    const artworkUrl = song.coverArt
      ? navidromeApi.getCoverUrl(song.coverArt, 400)
      : undefined

    audioBridge.updateNowPlaying({
      title:      song.title   || '',
      artist,
      album:      song.album   || '',
      duration:   song.duration ?? 0,
      elapsedTime: progressRef.current,
      isPlaying:  playerState.isPlaying,
      artworkUrl,
    })
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, playerState.currentSong?.id])

  // ── 2. Actualizar estado play/pause ────────────────────────────────────────
  useEffect(() => {
    if (!isNative || useNativeEngine || !playerState.currentSong) return
    audioBridge.updatePlaybackState({
      isPlaying:   playerState.isPlaying,
      elapsedTime: progressRef.current,
    })
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, playerState.isPlaying, playerState.currentSong?.id])

  // ── 3. Sync periódico del tiempo (barra de progreso en pantalla de bloqueo) ─
  // WKWebView sobreescribe MPNowPlayingInfoCenter con los datos del keepalive
  // HTMLAudioElement (WAV silencioso de 1s en loop). El timer nativo de
  // AudioBridgePlugin lo contrarresta cada 1s, pero reforzamos desde JS cada 5s
  // para corregir drift acumulado.
  useEffect(() => {
    if (!isNative || useNativeEngine || !playerState.isPlaying || !playerState.currentSong) return

    const timer = setInterval(() => {
      const realElapsed = elapsedAtPlayStartRef.current +
        (Date.now() - playbackStartTimestampRef.current) / 1000
      audioBridge.updatePlaybackState({
        isPlaying:   true,
        elapsedTime: realElapsed,
      })
    }, 5000)

    return () => clearInterval(timer)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, playerState.isPlaying, playerState.currentSong?.id])

  // ── 3b. Re-sync al volver al foreground ─────────────────────────────────────
  // Cuando el usuario desbloquea la pantalla o vuelve a la app, corregir el
  // elapsed time para que la barra de progreso del lock screen esté en sync.
  useEffect(() => {
    if (!isNative || useNativeEngine || !playerState.currentSong) return

    const handleVisibility = () => {
      if (document.visibilityState === 'visible' && playerState.isPlaying) {
        const realElapsed = elapsedAtPlayStartRef.current +
          (Date.now() - playbackStartTimestampRef.current) / 1000
        audioBridge.updatePlaybackState({
          isPlaying:   true,
          elapsedTime: realElapsed,
        })
      }
    }

    document.addEventListener('visibilitychange', handleVisibility)
    return () => document.removeEventListener('visibilitychange', handleVisibility)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, playerState.isPlaying, playerState.currentSong?.id])

  // ── 4. Escuchar comandos remotos (auriculares, lock screen, CarPlay) ────────
  // Con NativeAudioPlayer, los comandos remotos van directos a AudioEngineManager.
  useEffect(() => {
    if (!isNative || useNativeEngine) return

    let handle: PluginListenerHandle | null = null

    audioBridge.addRemoteCommandListener(event => {
      switch (event.command) {
        case 'play':
        case 'pause':
        case 'togglePlayPause':
          playerActions.togglePlayPause()
          break
        case 'next':
          playerActions.next()
          break
        case 'previous':
          playerActions.previous()
          break
        case 'seek':
          if (typeof event.position === 'number') {
            playerActions.seek(event.position)
          }
          break
      }
    }).then(h => { handle = h })

    return () => { handle?.remove() }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative])

  // ── 5. Pausar al desconectar Bluetooth / CarPlay / auriculares ────────────
  // Con NativeAudioPlayer, AudioEngineManager maneja route changes directamente.
  useEffect(() => {
    if (!isNative || useNativeEngine) return

    const handleRouteLost = () => {
      console.log('[useAudioBridge] Audio route lost — pausing playback')
      if (playerState.isPlaying) {
        playerActions.togglePlayPause()
      }
    }

    window.addEventListener('_audioRouteLost', handleRouteLost)
    return () => window.removeEventListener('_audioRouteLost', handleRouteLost)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, playerState.isPlaying])

  // ── 6. Manejar interrupciones de sesión de audio (llamada, Siri, otra app) ─
  // Con NativeAudioPlayer, AudioEngineManager maneja interrupciones directamente.
  useEffect(() => {
    if (!isNative || useNativeEngine) return

    const handleInterrupted = () => {
      console.log('[useAudioBridge] Audio session interrupted — pausing')
      if (playerState.isPlaying) {
        playerActions.togglePlayPause()
      }
    }

    const handleResumed = (e: Event) => {
      const detail = (e as CustomEvent).detail
      console.log('[useAudioBridge] Audio session resumed, shouldResume:', detail?.shouldResume)
      // Si iOS indica que debemos reanudar (ej: llamada corta terminó) y
      // estábamos reproduciendo, reanudar automáticamente
      if (detail?.shouldResume && !playerState.isPlaying && playerState.currentSong) {
        playerActions.togglePlayPause()
      }
    }

    window.addEventListener('_audioSessionInterrupted', handleInterrupted)
    window.addEventListener('_audioSessionResumed', handleResumed)
    return () => {
      window.removeEventListener('_audioSessionInterrupted', handleInterrupted)
      window.removeEventListener('_audioSessionResumed', handleResumed)
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, playerState.isPlaying, playerState.currentSong?.id])
}
