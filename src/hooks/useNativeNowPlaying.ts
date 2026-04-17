import { useEffect, useRef, useState } from 'react'
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
    if (!song) return { artworkUrl: undefined, artistText: '', coverArt: undefined }
    const artistText = Array.isArray(song.artist)
      ? (song.artist as unknown as { name: string }[]).map(a => a.name).join(', ')
      : String(song.artist || '')
    const coverArt = 'coverArt' in song ? (song as { coverArt?: string }).coverArt : undefined
    const rawUrl = coverArt ? navidromeApi.getCoverUrl(coverArt, 300) : ''
    const artworkUrl = rawUrl || undefined
    return { artworkUrl, artistText, coverArt }
  }

  // Helper centralizado para enviar update al mini-player nativo.
  // Usa isDarkRef.current en vez del closure isDark para evitar stale closures
  // en los intervalos/effects que no tienen isDark en sus dependencias.
  // Sin esto, el timer de 2s puede mandar isDark=false momentáneamente.
  const sendUpdate = (overrides?: { isDark?: boolean }) => {
    if (!effectiveSong) return
    const { artworkUrl, artistText, coverArt } = getUpdateFields(effectiveSong)
    const s = effectiveSong as Record<string, unknown>
    nativeNowPlaying.update({
      title:      effectiveSong.title || '',
      artist:     artistText,
      artworkUrl,
      coverArt,
      songId:     String(s.id ?? ''),
      albumId:    String(s.albumId ?? ''),
      artistId:   String(s.artistId ?? ''),
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

  // Refs for queue state (used by _nativeReady + queue actions)
  const queueRef = useRef(playerState.queue)
  useEffect(() => { queueRef.current = playerState.queue }, [playerState.queue])

  const currentSongRef = useRef(playerState.currentSong)
  useEffect(() => { currentSongRef.current = playerState.currentSong }, [playerState.currentSong])

  // Counter bumped by _nativeReady to force re-send of viewer state
  const nativeReadyCountRef = useRef(0)
  const [nativeReadyCount, setNativeReadyCount] = useState(0)

  // Cuando el lado nativo termina de registrar los message handlers,
  // re-enviamos el estado actual del player. Esto resuelve el race condition
  // donde React envía nativeUpdateNowPlaying antes de que los handlers existan.
  useEffect(() => {
    if (!isNative) return

    const handleNativeReady = () => {
      console.log('[useNativeNowPlaying] _nativeReady received, effectiveSong=', !!effectiveSongRef.current)
      const song = effectiveSongRef.current
      if (!song) return
      const { artworkUrl, artistText, coverArt } = getUpdateFields(song)
      const s = song as Record<string, unknown>
      nativeNowPlaying.update({
        title:      song.title || '',
        artist:     artistText,
        artworkUrl,
        coverArt,
        songId:     String(s.id ?? ''),
        albumId:    String(s.albumId ?? ''),
        artistId:   String(s.artistId ?? ''),
        isPlaying:  effectivePlayingRef.current,
        progress:   progressRef.current,
        duration:   effectiveDurationRef.current || 1,
        isVisible:  true,
        subtitle:   getSubtitle(),
        isDark:     isDarkRef.current,
      })

      // Send queue to Swift natively via message handler
      const currentQueue = queueRef.current
      nativeNowPlaying.updateViewerState({
        songId:    String(s.id ?? ''),
        albumId:   String(s.albumId ?? ''),
        artistId:  String(s.artistId ?? ''),
        coverArt:  String(s.coverArt ?? ''),
        shuffle:   false,
        repeat:    'off',
        isCrossfading: false,
        isRemote:  false,
        remoteDeviceName: undefined,
        queue: currentQueue.map(q => ({
          id: q.id, title: q.title,
          artist: typeof q.artist === 'string' ? q.artist : String(q.artist ?? ''),
          album: q.album ?? '', albumId: q.albumId ?? '',
          coverArt: q.coverArt ?? '', duration: q.duration ?? 0,
        })),
      })

      // Force re-send viewer state (with full queue) by bumping the counter
      nativeReadyCountRef.current++
      setNativeReadyCount(c => c + 1)
    }

    window.addEventListener('_nativeReady', handleNativeReady)
    return () => window.removeEventListener('_nativeReady', handleNativeReady)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative])

  // Enviar estado enriquecido al viewer nativo (queue, remote, etc.)
  useEffect(() => {
    if (!isNative || !effectiveSong) {
      console.log('[useNativeNowPlaying] updateViewerState SKIP: isNative=', isNative, 'effectiveSong=', !!effectiveSong)
      return
    }

    const song = effectiveSong as Record<string, unknown>
    console.log('[useNativeNowPlaying] updateViewerState SEND: songId=', song.id, 'albumId=', song.albumId, 'artistId=', song.artistId, 'queueLen=', playerState.queue.length, 'nativeReadyCount=', nativeReadyCount)
    const activeDevice = isRemote ? devices.find(d => d.id === activeDeviceId) : null
    const effectiveQueue = isRemote
      ? (remotePlaybackState?.queue ?? [])
      : playerState.queue

    nativeNowPlaying.updateViewerState({
      songId:    String(song.id ?? ''),
      albumId:   String(song.albumId ?? ''),
      artistId:  String(song.artistId ?? ''),
      coverArt:  String(song.coverArt ?? ''),
      shuffle:   false,  // No shuffle/repeat en la app todavía
      repeat:    'off',
      isCrossfading: playerState.isCrossfading,
      isRemote,
      remoteDeviceName: activeDevice?.name,
      queue: effectiveQueue.map(s => ({
        id:       s.id,
        title:    s.title,
        artist:   typeof s.artist === 'string' ? s.artist : String(s.artist ?? ''),
        album:    s.album ?? '',
        albumId:  s.albumId ?? '',
        coverArt: s.coverArt ?? '',
        duration: s.duration ?? 0,
      })),
    })
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, effectiveSongId, playerState.queue.length, playerState.isCrossfading, isRemote, activeDeviceId, nativeReadyCount])

  // Exponer cola en window para que Swift la lea directamente (bypass message handlers)
  useEffect(() => {
    if (!isNative) return
    const q = playerState.queue.map(s => ({
      id: s.id, title: s.title,
      artist: typeof s.artist === 'string' ? s.artist : String(s.artist ?? ''),
      album: s.album ?? '', albumId: s.albumId ?? '',
      coverArt: s.coverArt ?? '', duration: s.duration ?? 0,
    }))
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(window as any).__nativeQueue = q
  }, [playerState.queue, playerState.queue.length])

  // Canción reproducida desde una vista SwiftUI nativa (SearchView, etc.)
  // Swift llama a AudioEngineManager directamente y despacha este evento
  // para que React actualice su PlayerContext (mini-player, cola, etc.)
  useEffect(() => {
    if (!isNative) return
    const handle = (e: Event) => {
      const d = (e as CustomEvent).detail as {
        id: string; title: string; artist: string; artistId?: string; album: string
        albumId: string; coverArt: string; duration: number; url: string
      }
      playerActionsRef.current.playSong({
        id: d.id, title: d.title, artist: d.artist, artistId: d.artistId,
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
      playerActionsRef.current.playPlaylistFromSong(d.songs, startSong)
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

  // Toggle play/pause desde Swift
  useEffect(() => {
    if (!isNative) return
    const handle = () => playerActionsRef.current.togglePlayPause()
    window.addEventListener('_swiftTogglePlayPause', handle)
    return () => window.removeEventListener('_swiftTogglePlayPause', handle)
  }, [])

  // Seek desde el viewer nativo
  useEffect(() => {
    if (!isNative) return
    const handle = (e: Event) => {
      const time = (e as CustomEvent).detail?.time
      if (typeof time === 'number') playerActionsRef.current.seek(time)
    }
    window.addEventListener('_nativeSeek', handle)
    return () => window.removeEventListener('_nativeSeek', handle)
  }, [])

  // Añadir canción a la cola desde Swift (SongListView context menu)
  useEffect(() => {
    if (!isNative) return

    const parseSongDetail = (e: Event) => {
      const d = (e as CustomEvent).detail as {
        id: string; title: string; artist: string; artistId?: string; album: string
        albumId: string; coverArt: string; duration: number; url: string
      }
      if (!d?.id) return null
      return {
        id: d.id, title: d.title, artist: d.artist, artistId: d.artistId,
        album: d.album, albumId: d.albumId, coverArt: d.coverArt,
        duration: d.duration, path: d.url,
      }
    }

    const handleAddToQueue = (e: Event) => {
      const song = parseSongDetail(e)
      if (song) playerActionsRef.current.addToQueue(song)
    }

    const handleInsertNext = (e: Event) => {
      const song = parseSongDetail(e)
      if (!song) return
      const queue = queueRef.current
      if (queue.some(s => s.id === song.id)) return
      // Add to queue first, then reorder to place after current song
      playerActionsRef.current.addToQueue(song)
      const currentId = currentSongRef.current?.id
      const idx = currentId ? queue.findIndex(s => s.id === currentId) : -1
      const newQueue = [...queue]
      newQueue.splice(idx + 1, 0, song)
      playerActionsRef.current.reorderQueue(newQueue)
    }

    window.addEventListener('_swiftAddToQueue', handleAddToQueue)
    window.addEventListener('_swiftInsertNext', handleInsertNext)
    return () => {
      window.removeEventListener('_swiftAddToQueue', handleAddToQueue)
      window.removeEventListener('_swiftInsertNext', handleInsertNext)
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative])

  // Queue play desde el viewer nativo
  useEffect(() => {
    if (!isNative) return
    const handle = (e: Event) => {
      const songId = (e as CustomEvent).detail?.songId
      if (typeof songId !== 'string') return
      const queue = playerState.queue
      const song = queue.find(s => s.id === songId)
      if (song) playerActionsRef.current.playPlaylistFromSong(queue, song)
    }
    window.addEventListener('_nativeQueuePlay', handle)
    return () => window.removeEventListener('_nativeQueuePlay', handle)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isNative, playerState.queue])

  // SmartMix: Swift pide generar → React ejecuta y reporta estado de vuelta
  useEffect(() => {
    if (!isNative) return

    const sendStatus = (playlistId: string, status: string) => {
      try {
        (window as unknown as { webkit: { messageHandlers: { nativeSmartMixStatus: { postMessage: (body: unknown) => void } } } })
          .webkit.messageHandlers.nativeSmartMixStatus.postMessage({ playlistId, status })
      } catch { /* handler not registered yet */ }
    }

    // SmartMix generation request from Swift
    const handleGenerate = async (e: Event) => {
      const d = (e as CustomEvent).detail as { playlistId: string; songs: Song[] }
      if (!d.playlistId || !d.songs?.length) return
      sendStatus(d.playlistId, 'analyzing')
      try {
        await playerActionsRef.current.generateSmartMix(d.playlistId, d.songs)
        // generateSmartMix sets status internally; read it back after a tick
        // React state updates are batched, so we poll briefly for 'ready'
        setTimeout(() => sendStatus(d.playlistId, 'ready'), 500)
      } catch {
        sendStatus(d.playlistId, 'error')
      }
    }

    // SmartMix play request from Swift
    const handlePlay = () => {
      playerActionsRef.current.playGeneratedSmartMix()
    }

    window.addEventListener('_swiftGenerateSmartMix', handleGenerate)
    window.addEventListener('_swiftPlaySmartMix', handlePlay)
    return () => {
      window.removeEventListener('_swiftGenerateSmartMix', handleGenerate)
      window.removeEventListener('_swiftPlaySmartMix', handlePlay)
    }
  }, [])

  // Sync SmartMix status changes from React → Swift automatically
  const smartMixStatus = playerState.smartMixStatus
  const smartMixPlaylistId = playerState.smartMixPlaylistId
  useEffect(() => {
    if (!isNative || !smartMixPlaylistId) return
    try {
      (window as unknown as { webkit: { messageHandlers: { nativeSmartMixStatus: { postMessage: (body: unknown) => void } } } })
        .webkit.messageHandlers.nativeSmartMixStatus.postMessage({ playlistId: smartMixPlaylistId, status: smartMixStatus })
    } catch { /* handler not registered yet */ }
  }, [smartMixStatus, smartMixPlaylistId])
}
