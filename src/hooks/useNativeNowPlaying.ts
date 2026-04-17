import { useEffect, useRef } from 'react'
import { usePlayerState, usePlayerProgress, usePlayerActions } from '../contexts/PlayerContext'
import { nativeNowPlaying, isNative } from '../services/nativeNowPlaying'
import { navidromeApi, type Song } from '../services/navidromeApi'
import { useConnect } from './useConnect'
import { useTheme } from '../contexts/ThemeContext'
import { useHeroPresence } from '../contexts/HeroPresenceContext'

export function useNativeNowPlaying() {
  const playerState    = usePlayerState()
  const playerProgress = usePlayerProgress()
  const playerActions  = usePlayerActions()
  const { isConnected, activeDeviceId, currentDeviceId, devices, remotePlaybackState } = useConnect()
  const { isDark } = useTheme()
  const { heroDark } = useHeroPresence()
  // isDark del tema de la app + heroDark cuando la página tiene fondo inmersivo oscuro
  const effectiveIsDark = isDark || heroDark

  // --- Estado efectivo: remoto vs local (misma lógica que NowPlayingBar) ---
  const isRemote = isConnected && !!activeDeviceId && activeDeviceId !== currentDeviceId

  // Buscar la Song completa en el queue remoto para tener coverArt, etc.
  const remoteSong = isRemote && remotePlaybackState
    ? remotePlaybackState.queue?.find(s => s.id === remotePlaybackState.trackId) ?? null
    : null
  const effectiveSong = isRemote
    ? (remoteSong ?? remotePlaybackState?.metadata ?? null)
    : playerState.currentSong
  const effectiveProgress = isRemote ? (remotePlaybackState?.position || 0) : playerProgress.progress
  const effectiveDuration = isRemote
    ? (remoteSong?.duration || remotePlaybackState?.metadata?.duration || 0)
    : playerProgress.duration
  const effectivePlaying = isRemote ? (remotePlaybackState?.playing ?? false) : playerState.isPlaying

  // ID estable para detectar cambio de canción
  const effectiveSongId = isRemote ? (remotePlaybackState?.trackId || null) : (playerState.currentSong?.id || null)

  // AutoMix tiene prioridad sobre el indicador de dispositivo remoto
  const getSubtitle = (): string | undefined => {
    if (playerState.isCrossfading) return 'AutoMix'
    if (isRemote) {
      const activeDevice = devices.find(d => d.id === activeDeviceId)
      if (activeDevice) return `Reproduciendo en ${activeDevice.name}`
    }
    return undefined
  }

  // Ref para acceder siempre a las últimas acciones del player desde los listeners nativos.
  const playerActionsRef = useRef(playerActions)
  useEffect(() => { playerActionsRef.current = playerActions }, [playerActions])

  const progressRef = useRef(effectiveProgress)
  useEffect(() => { progressRef.current = effectiveProgress }, [effectiveProgress])

  // Helper para extraer artworkUrl y artistText de cualquier canción/metadata
  const getUpdateFields = (song: typeof effectiveSong) => {
    if (!song) return { artworkUrl: undefined, artistText: '' }
    const artistText = Array.isArray(song.artist)
      ? (song.artist as unknown as { name: string }[]).map(a => a.name).join(', ')
      : String(song.artist || '')
    const coverArt = 'coverArt' in song ? (song as { coverArt?: string }).coverArt : undefined
    const rawUrl = coverArt ? navidromeApi.getCoverUrl(coverArt, 300) : ''
    const artworkUrl = rawUrl || undefined
    return { artworkUrl, artistText }
  }

  // Helper centralizado para enviar update al mini-player nativo.
  // Usa isDarkRef.current en vez del closure isDark para evitar stale closures
  // en los intervalos/effects que no tienen isDark en sus dependencias.
  // Sin esto, el timer de 2s puede mandar isDark=false momentáneamente.
  const sendUpdate = (overrides?: { isDark?: boolean }) => {
    if (!effectiveSong) return
    const { artworkUrl, artistText } = getUpdateFields(effectiveSong)
    nativeNowPlaying.update({
      title:      effectiveSong.title || '',
      artist:     artistText,
      artworkUrl,
      isPlaying:  effectivePlaying,
      progress:   progressRef.current,
      duration:   effectiveDuration || 1,
      isVisible:  true,
      subtitle:   getSubtitle(),
      isDark:     overrides?.isDark ?? isDarkRef.current,
    })
  }

  // Actualizar cuando cambia la canción (local o remota)
  useEffect(() => {
    if (!isNative) return
    if (!effectiveSong) {
      nativeNowPlaying.hide()
      return
    }
    sendUpdate()
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, effectiveSongId])

  // Actualizar play/pause
  useEffect(() => {
    if (!isNative || !effectiveSong) return
    sendUpdate()
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, effectivePlaying, effectiveSongId])

  // Sync progreso periódico
  useEffect(() => {
    if (!isNative || !effectivePlaying || !effectiveSong) return
    const timer = setInterval(() => {
      sendUpdate()
    }, 2000)
    return () => clearInterval(timer)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, effectivePlaying, effectiveSongId])

  // Actualizar cuando cambia el tema o el fondo de la página (hero inmersivo).
  // Pasar effectiveIsDark directamente (no via isDarkRef): el effect que actualiza
  // isDarkRef se declara después y corre después, así que isDarkRef.current aún
  // tendría el valor anterior — causando un desfase de un ciclo.
  useEffect(() => {
    if (!isNative || !effectiveSong) return
    sendUpdate({ isDark: effectiveIsDark })
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, playerState.isCrossfading, activeDeviceId, effectiveIsDark])

  // Actualizar cuando cambia el estado remoto (posición, metadata, etc.)
  useEffect(() => {
    if (!isNative || !isRemote || !effectiveSong) return
    sendUpdate()
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, isRemote, remotePlaybackState?.position, remotePlaybackState?.trackId])

  // Refs para acceder al estado actual desde el listener de _nativeReady
  const effectiveSongRef = useRef(effectiveSong)
  useEffect(() => { effectiveSongRef.current = effectiveSong }, [effectiveSong])

  const effectivePlayingRef = useRef(effectivePlaying)
  useEffect(() => { effectivePlayingRef.current = effectivePlaying }, [effectivePlaying])

  const effectiveDurationRef = useRef(effectiveDuration)
  useEffect(() => { effectiveDurationRef.current = effectiveDuration }, [effectiveDuration])

  const isDarkRef = useRef(effectiveIsDark)
  useEffect(() => { isDarkRef.current = effectiveIsDark }, [effectiveIsDark])

  // Cuando el lado nativo termina de registrar los message handlers,
  // re-enviamos el estado actual del player. Esto resuelve el race condition
  // donde React envía nativeUpdateNowPlaying antes de que los handlers existan.
  useEffect(() => {
    if (!isNative) return

    const handleNativeReady = () => {
      const song = effectiveSongRef.current
      if (!song) return
      const { artworkUrl, artistText } = getUpdateFields(song)
      nativeNowPlaying.update({
        title:      song.title || '',
        artist:     artistText,
        artworkUrl,
        isPlaying:  effectivePlayingRef.current,
        progress:   progressRef.current,
        duration:   effectiveDurationRef.current || 1,
        isVisible:  true,
        subtitle:   getSubtitle(),
        isDark:     isDarkRef.current,
      })
    }

    window.addEventListener('_nativeReady', handleNativeReady)
    return () => window.removeEventListener('_nativeReady', handleNativeReady)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative])

  // Canción reproducida desde una vista SwiftUI nativa (SearchView, etc.)
  // Swift llama a AudioEngineManager directamente y despacha este evento
  // para que React actualice su PlayerContext (mini-player, cola, etc.)
  useEffect(() => {
    if (!isNative) return
    const handle = (e: Event) => {
      const d = (e as CustomEvent).detail as {
        id: string; title: string; artist: string; album: string
        albumId: string; coverArt: string; duration: number; url: string
      }
      playerActions.playSong({
        id: d.id, title: d.title, artist: d.artist,
        album: d.album, albumId: d.albumId, coverArt: d.coverArt,
        duration: d.duration, path: d.url,
      })
    }
    window.addEventListener('_swiftPlaySong', handle)
    return () => window.removeEventListener('_swiftPlaySong', handle)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative])

  // Playlist reproducida desde una vista SwiftUI nativa
  useEffect(() => {
    if (!isNative) return
    const handle = (e: Event) => {
      const d = (e as CustomEvent).detail as { songs: Song[]; startIndex: number }
      if (!d.songs?.length) return
      const startSong = d.songs[d.startIndex] ?? d.songs[0]
      playerActions.playPlaylistFromSong(d.songs, startSong)
    }
    window.addEventListener('_swiftPlayPlaylist', handle)
    return () => window.removeEventListener('_swiftPlayPlaylist', handle)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative])

  // Escuchar eventos del native mini-player
  useEffect(() => {
    if (!isNative) return

    // NO registrar listener de 'tap' aquí: Swift ya despacha 'native-nowplaying-tap'
    // vía evalJS, y NowPlayingBar lo escucha directamente. Re-despacharlo desde aquí
    // crea un loop infinito (listener de 'native-nowplaying-tap' que despacha 'native-nowplaying-tap').
    const playHandle      = nativeNowPlaying.addListener('playPause', () => playerActionsRef.current.togglePlayPause())
    const nextHandle      = nativeNowPlaying.addListener('next',      () => playerActionsRef.current.next())
    const prevHandle      = nativeNowPlaying.addListener('previous',  () => playerActionsRef.current.previous())

    return () => {
      playHandle.remove()
      nextHandle.remove()
      prevHandle.remove()
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative])
}
