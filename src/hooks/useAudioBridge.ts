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
    if (!isNative) return

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
      artworkUrl,
    })
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, playerState.currentSong?.id])

  // ── 2. Actualizar estado play/pause ────────────────────────────────────────
  useEffect(() => {
    if (!isNative || !playerState.currentSong) return
    audioBridge.updatePlaybackState({
      isPlaying:   playerState.isPlaying,
      elapsedTime: progressRef.current,
    })
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, playerState.isPlaying, playerState.currentSong?.id])

  // ── 3. Sync periódico del tiempo (barra de progreso en pantalla de bloqueo) ─
  useEffect(() => {
    if (!isNative || !playerState.isPlaying || !playerState.currentSong) return

    const timer = setInterval(() => {
      // Calcular elapsedTime con reloj real para que funcione aunque iOS haya
      // suspendido el AudioContext (y audioContext.currentTime esté congelado)
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

  // ── 4. Escuchar comandos remotos (auriculares, lock screen, CarPlay) ────────
  useEffect(() => {
    if (!isNative) return

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
  // iOS envía _audioRouteLost cuando el dispositivo de salida se desconecta.
  // Comportamiento idéntico a Spotify / Apple Music: pausar sin auto-reanudar.
  useEffect(() => {
    if (!isNative) return

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
}
