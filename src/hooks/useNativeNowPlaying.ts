import { useEffect, useRef } from 'react'
import { usePlayerState, usePlayerProgress, usePlayerActions } from '../contexts/PlayerContext'
import { nativeNowPlaying, isNative } from '../services/nativeNowPlaying'
import { navidromeApi } from '../services/navidromeApi'
import { useConnect } from './useConnect'
import { useTheme } from '../contexts/ThemeContext'

export function useNativeNowPlaying() {
  const playerState    = usePlayerState()
  const playerProgress = usePlayerProgress()
  const playerActions  = usePlayerActions()
  const { isConnected, activeDeviceId, currentDeviceId, devices } = useConnect()
  const { isDark } = useTheme()

  // AutoMix tiene prioridad sobre el indicador de dispositivo remoto
  const getSubtitle = (): string | undefined => {
    if (playerState.isCrossfading) return 'AutoMix'
    const isRemote = isConnected && activeDeviceId && activeDeviceId !== currentDeviceId
    if (isRemote) {
      const activeDevice = devices.find(d => d.id === activeDeviceId)
      if (activeDevice) return `Reproduciendo en ${activeDevice.name}`
    }
    return undefined
  }

  // Ref para acceder siempre a las últimas acciones del player desde los listeners nativos.
  // Sin esto, los listeners capturan una closure vieja y togglePlayPause usa
  // shouldUseWebAudio() con el valor del mount inicial (HTMLAudio), no el actual.
  const playerActionsRef = useRef(playerActions)
  useEffect(() => { playerActionsRef.current = playerActions }, [playerActions])

  const progressRef = useRef(playerProgress.progress)
  useEffect(() => { progressRef.current = playerProgress.progress }, [playerProgress.progress])

  // Actualizar cuando cambia la canción
  useEffect(() => {
    if (!isNative) return

    const song = playerState.currentSong
    if (!song) {
      nativeNowPlaying.hide()
      return
    }

    const artistText = Array.isArray(song.artist)
      ? (song.artist as unknown as { name: string }[]).map(a => a.name).join(', ')
      : String(song.artist || '')

    const rawCoverUrl = song.coverArt ? navidromeApi.getCoverUrl(song.coverArt, 300) : ''
    nativeNowPlaying.update({
      title:      song.title  || '',
      artist:     artistText,
      artworkUrl: rawCoverUrl || undefined,
      isPlaying:  playerState.isPlaying,
      progress:   progressRef.current,
      duration:   song.duration ?? 1,
      isVisible:  true,
      subtitle:   getSubtitle(),
      isDark,
    })
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, playerState.currentSong?.id])

  // Helper para obtener artworkUrl y artistText de la canción actual
  const getSongUpdateFields = (song: typeof playerState.currentSong) => {
    if (!song) return { artworkUrl: undefined, artistText: '' }
    const artistText = Array.isArray(song.artist)
      ? (song.artist as unknown as { name: string }[]).map(a => a.name).join(', ')
      : String(song.artist || '')
    const rawUrl = song.coverArt ? navidromeApi.getCoverUrl(song.coverArt, 300) : ''
    const artworkUrl = rawUrl || undefined  // evitar string vacío si config aún no cargó
    return { artworkUrl, artistText }
  }

  // Actualizar play/pause
  useEffect(() => {
    if (!isNative || !playerState.currentSong) return
    const { artworkUrl, artistText } = getSongUpdateFields(playerState.currentSong)
    nativeNowPlaying.update({
      title:      playerState.currentSong.title || '',
      artist:     artistText,
      artworkUrl,
      isPlaying:  playerState.isPlaying,
      progress:   progressRef.current,
      duration:   playerState.currentSong.duration ?? 1,
      isVisible:  true,
      subtitle:   getSubtitle(),
      isDark,
    })
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, playerState.isPlaying, playerState.currentSong?.id])

  // Sync progreso periódico
  useEffect(() => {
    if (!isNative || !playerState.isPlaying || !playerState.currentSong) return
    const timer = setInterval(() => {
      if (!playerState.currentSong) return
      const { artworkUrl, artistText } = getSongUpdateFields(playerState.currentSong)
      nativeNowPlaying.update({
        title:      playerState.currentSong.title || '',
        artist:     artistText,
        artworkUrl,
        isPlaying:  true,
        progress:   progressRef.current,
        duration:   playerState.currentSong.duration ?? 1,
        isVisible:  true,
        subtitle:   getSubtitle(),
        isDark,
      })
    }, 2000)
    return () => clearInterval(timer)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, playerState.isPlaying, playerState.currentSong?.id])

  // Actualizar subtitle cuando cambia AutoMix o dispositivo activo
  useEffect(() => {
    if (!isNative || !playerState.currentSong) return
    const { artworkUrl, artistText } = getSongUpdateFields(playerState.currentSong)
    nativeNowPlaying.update({
      title:      playerState.currentSong.title || '',
      artist:     artistText,
      artworkUrl,
      isPlaying:  playerState.isPlaying,
      progress:   progressRef.current,
      duration:   playerState.currentSong.duration ?? 1,
      isVisible:  true,
      subtitle:   getSubtitle(),
      isDark,
    })
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, playerState.isCrossfading, activeDeviceId, isDark])

  // Refs para acceder al estado actual desde el listener de _nativeReady
  const playerStateRef = useRef(playerState)
  useEffect(() => { playerStateRef.current = playerState }, [playerState])

  const isDarkRef = useRef(isDark)
  useEffect(() => { isDarkRef.current = isDark }, [isDark])

  // Cuando el lado nativo termina de registrar los message handlers,
  // re-enviamos el estado actual del player. Esto resuelve el race condition
  // donde React envía nativeUpdateNowPlaying antes de que los handlers existan.
  useEffect(() => {
    if (!isNative) return

    const handleNativeReady = () => {
      const song = playerStateRef.current.currentSong
      if (!song) return
      const { artworkUrl, artistText } = getSongUpdateFields(song)
      nativeNowPlaying.update({
        title:      song.title || '',
        artist:     artistText,
        artworkUrl,
        isPlaying:  playerStateRef.current.isPlaying,
        progress:   progressRef.current,
        duration:   song.duration ?? 1,
        isVisible:  true,
        subtitle:   getSubtitle(),
        isDark:     isDarkRef.current,
      })
    }

    window.addEventListener('_nativeReady', handleNativeReady)
    return () => window.removeEventListener('_nativeReady', handleNativeReady)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative])

  // Escuchar eventos del native mini-player
  useEffect(() => {
    if (!isNative) return

    const tapHandle       = nativeNowPlaying.addListener('tap',       () => {
      window.dispatchEvent(new CustomEvent('native-nowplaying-tap'))
    })
    const playHandle      = nativeNowPlaying.addListener('playPause', () => playerActionsRef.current.togglePlayPause())
    const nextHandle      = nativeNowPlaying.addListener('next',      () => playerActionsRef.current.next())
    const prevHandle      = nativeNowPlaying.addListener('previous',  () => playerActionsRef.current.previous())

    return () => {
      tapHandle.remove()
      playHandle.remove()
      nextHandle.remove()
      prevHandle.remove()
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative])
}
