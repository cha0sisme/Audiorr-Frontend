import { useState, useEffect, useCallback, useRef, useMemo } from 'react'
import { springPress } from '../utils/springPress'
import { createPortal } from 'react-dom'
import { useParams, useNavigate, useLocation } from 'react-router-dom'
import { navidromeApi, Song } from '../services/navidromeApi'
import { usePlayerState, usePlayerActions } from '../contexts/PlayerContext'
import PageHero from './PageHero'
import {
  ArrowPathIcon,
  XCircleIcon,
  TrashIcon,
  SparklesIcon,
  CheckIcon,
} from '@heroicons/react/24/solid'
import { customCoverService } from '../services/customCoverService'
import { useContextMenu } from '../hooks/useContextMenu'
import SongContextMenu from './SongContextMenu'
import { usePinnedPlaylists } from '../hooks/usePinnedPlaylists'
import { PinFilledIcon, PinOutlinedIcon } from './icons/PinIcons'
import { useDominantColors } from '../hooks/useDominantColors'
import { SongTable } from './SongTable'

function computePageBgColor(hex: string): string {
  if (!hex.startsWith('#') || hex.length < 7) return '#1a1212'
  const r = parseInt(hex.slice(1, 3), 16)
  const g = parseInt(hex.slice(3, 5), 16)
  const b = parseInt(hex.slice(5, 7), 16)
  const nr = Math.round(r * 0.30 + 14 * 0.70)
  const ng = Math.round(g * 0.30 + 14 * 0.70)
  const nb = Math.round(b * 0.30 + 14 * 0.70)
  return `#${nr.toString(16).padStart(2, '0')}${ng.toString(16).padStart(2, '0')}${nb.toString(16).padStart(2, '0')}`
}


import { API_BASE_URL } from '../services/backendApi'
import { useConnect } from '../hooks/useConnect'
import { useBackendAvailable } from '../contexts/BackendAvailableContext'

type PlaylistDetails = {
  id: string
  name: string
  coverArt?: string
  owner?: string
  comment?: string
  songCount: number
  duration: number
  public: boolean
  created?: string
  changed?: string
  path?: string
}





export default function PlaylistDetail() {
  const { id } = useParams<{ id: string }>()
  const location = useLocation()
  const navigate = useNavigate()
  const playerState = usePlayerState()
  const playerActions = usePlayerActions()
  const { isConnected, activeDeviceId, currentDeviceId, remotePlaybackState, sendRemoteCommand } = useConnect()
  const backendAvailable = useBackendAvailable()
  
  // Utilizar metadata pasada por el router para carga instantánea
  const initialPlaylist = useMemo(() => {
    return (location.state as { playlist?: PlaylistDetails })?.playlist || null
  }, [location.state])

  const [playlist, setPlaylist] = useState<PlaylistDetails | null>(initialPlaylist)
  const [songs, setSongs] = useState<Song[]>([])
  const [customCoverArt, setCustomCoverArt] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false)
  const [isDeleting, setIsDeleting] = useState(false)
  

  const fileInputRef = useRef<HTMLInputElement>(null)
  const isUpdatingRef = useRef(false) // Prevenir actualizaciones concurrentes
  const playlistChangedRef = useRef<string | undefined>(undefined) // Rastrear cambios sin causar re-renders

  const { menu, handleContextMenu, closeContextMenu } = useContextMenu()
  const { isPinned, togglePinnedPlaylist, updatePinnedPlaylist, pinnedPlaylists } = usePinnedPlaylists()
  const navidromeConfig = navidromeApi.getConfig()

  // Memoizar valores extraídos del playerState para prevenir re-renders cuando cambian otros valores
  const smartMixStatus = useMemo(() => playerState.smartMixStatus, [playerState.smartMixStatus])
  const smartMixPlaylistId = useMemo(() => playerState.smartMixPlaylistId, [playerState.smartMixPlaylistId])
  const currentSongId = useMemo(() => playerState.currentSong?.id, [playerState.currentSong?.id])
  const isPlayerAnalyzing = useMemo(() => playerState.isAnalyzing, [playerState.isAnalyzing])
  const analysisCurrentSongId = useMemo(() => playerState.analysisProgress.currentSongId, [playerState.analysisProgress.currentSongId])
  const playerQueue = useMemo(() => playerState.queue, [playerState.queue])

  const { generateSmartMix, playGeneratedSmartMix } = playerActions

  const isCurrentPlaylistSmartMixed = useMemo(() => smartMixPlaylistId === id, [smartMixPlaylistId, id])

  const generatedSmartMix = useMemo(() => playerState.generatedSmartMix, [playerState.generatedSmartMix])

  // "Mezcla activa" = la cola del player ES la smart mix (no solo que la canción actual esté en la lista)
  // Esto evita falsos positivos cuando la canción actual aparece en el mix pero la cola no fue cambiada.
  const isSmartMixPlaying = useMemo(() => {
    if (!isCurrentPlaylistSmartMixed || smartMixStatus !== 'ready') return false
    if (generatedSmartMix.length === 0 || playerQueue.length === 0) return false
    return (
      playerQueue.length === generatedSmartMix.length &&
      playerQueue[0]?.id === generatedSmartMix[0]?.id &&
      playerQueue[playerQueue.length - 1]?.id === generatedSmartMix[generatedSmartMix.length - 1]?.id
    )
  }, [isCurrentPlaylistSmartMixed, smartMixStatus, generatedSmartMix, playerQueue])

  const pinnedFallback = useMemo(() => {
    if (!id || !isPinned(id)) return null
    return pinnedPlaylists.find(item => item.id === id) ?? null
  }, [pinnedPlaylists, id, isPinned])

  const displayPlaylist = playlist ?? pinnedFallback

  // Lógica de reproducción remota vs local
  const isRemote = isConnected && activeDeviceId && activeDeviceId !== currentDeviceId
  const currentSource = isRemote ? remotePlaybackState?.currentSource : playerState.currentSource
  const isPlaying = isRemote ? remotePlaybackState?.playing : playerState.isPlaying
  
  // Verificar si esta playlist es la que suena (normal o smartmix)
  const isThisPlaylistPlaying = currentSource === `playlist:${id}` || currentSource === `smartmix:${id}`
  const effectiveCurrentSongId = isRemote ? remotePlaybackState?.trackId : currentSongId

  const displayPlaylistComment = useMemo(() => {
    let comment = displayPlaylist?.comment || ''
    comment = comment.replace(/\[Editorial\]/gi, '').replace(/\[Cover:[a-zA-Z-]+\]/gi, '').trim()
    return comment || undefined
  }, [displayPlaylist?.comment])

  const displayPlaylistPublic = playlist?.public ?? false





  const timeQuery = useMemo(() => Math.floor(Date.now() / 300000), [])
  const generatedCoverUrl = id && backendAvailable ? `${API_BASE_URL}/api/playlists/${id}/cover.png?_t=${timeQuery}` : null
  const isGeneratingCover = false

  const coverImageUrl =
    customCoverArt ??
    generatedCoverUrl

  const [activeCoverUrl, setActiveCoverUrl] = useState<string | null>(coverImageUrl ?? null)

  useEffect(() => {
    setActiveCoverUrl(coverImageUrl ?? null)
  }, [coverImageUrl])

  const dominantColors = useDominantColors(activeCoverUrl)

  const pageBgColor = dominantColors
    ? computePageBgColor(dominantColors.primary)
    : null

  const rootRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const el = rootRef.current
    if (!el) return
    let parent: HTMLElement | null = el.parentElement
    while (parent) {
      const ov = window.getComputedStyle(parent).overflowY
      if (ov === 'auto' || ov === 'scroll') {
        parent.style.backgroundColor = pageBgColor ?? ''
        const captured = parent
        return () => { captured.style.backgroundColor = '' }
      }
      parent = parent.parentElement
    }
  }, [pageBgColor])

  const accentButtonStyle = useMemo<{ backgroundColor: string; color: string } | null>(() => {
    if (!dominantColors || !dominantColors.primary.startsWith('#') || dominantColors.primary.length < 7) {
      return null
    }
    // For flat-color albums use the accent color for buttons (e.g. Motomami: red on white bg).
    const hex = (dominantColors.isSolid && dominantColors.accent?.startsWith('#'))
      ? dominantColors.accent
      : dominantColors.primary
    const r = parseInt(hex.slice(1, 3), 16)
    const g = parseInt(hex.slice(3, 5), 16)
    const b = parseInt(hex.slice(5, 7), 16)
    const dr = Math.min(255, Math.round(r * 1.1))
    const dg = Math.min(255, Math.round(g * 1.1))
    const db = Math.min(255, Math.round(b * 1.1))
    const brightness = (dr * 299 + dg * 587 + db * 114) / 1000
    return {
      backgroundColor: `rgb(${dr}, ${dg}, ${db})`,
      color: brightness > 180 ? '#000000' : '#ffffff',
    }
  }, [dominantColors])


  const timeAgo = useCallback((isoDate: string): string => {
    const diff = Date.now() - new Date(isoDate).getTime()
    const minutes = Math.floor(diff / 60_000)
    if (minutes < 1) return 'hace un momento'
    if (minutes < 60) return `hace ${minutes} min`
    const hours = Math.floor(minutes / 60)
    if (hours < 24) return `hace ${hours} h`
    const days = Math.floor(hours / 24)
    if (days < 7) return `hace ${days} día${days !== 1 ? 's' : ''}`
    const weeks = Math.floor(days / 7)
    if (weeks < 5) return `hace ${weeks} semana${weeks !== 1 ? 's' : ''}`
    const months = Math.floor(days / 30)
    return `hace ${months} mes${months !== 1 ? 'es' : ''}`
  }, [])

  const formatTotalDuration = useCallback((seconds: number) => {
    if (!seconds) return ''
    const hours = Math.floor(seconds / 3600)
    const minutes = Math.floor((seconds % 3600) / 60)
    const parts: string[] = []
    if (hours > 0) {
      parts.push(`${hours} h`)
    }
    if (minutes > 0 || hours === 0) {
      parts.push(`${minutes} min`)
    }
    return parts.join(' ')
  }, [])

  const isDailyMix = useMemo(() => {
    const name = displayPlaylist?.name ?? ''
    return /mix diario/i.test(name) || /daily mix/i.test(name)
  }, [displayPlaylist?.name])

  const trackCount = displayPlaylist?.songCount ?? songs.length
  const totalDurationSeconds =
    displayPlaylist?.duration ?? songs.reduce((acc, song) => acc + (song.duration || 0), 0)
  const totalDurationFormatted = formatTotalDuration(totalDurationSeconds)
  const songCountLabel = `${trackCount} ${trackCount === 1 ? 'canción' : 'canciones'}`
  const ownerName = displayPlaylist?.owner || navidromeConfig?.username || 'Sin propietario'
  const playlistVisibility = displayPlaylistPublic ? 'Lista pública' : 'Lista privada'

  const loadSongs = useCallback(async () => {
    if (!id || isUpdatingRef.current) return
    
    try {
      isUpdatingRef.current = true
      setLoading(true)
      
      // Verificar si la playlist cambió desde la última vez usando el ref
      // Esto previene ciclos de dependencias porque el ref no causa re-renders
      if (playlistChangedRef.current) {
        const hasChanged = await navidromeApi.hasPlaylistChanged(id, playlistChangedRef.current)
        if (hasChanged) {
          console.log('[PlaylistDetail] Playlist cambió en el servidor, invalidando caché')
          navidromeApi.invalidatePlaylistsCache()
        }
      }
      
      // Obtener la info de la playlist y las canciones
      const [playlistInfo, playlistSongs] = await Promise.all([
        navidromeApi.getPlaylist(id),
        navidromeApi.getPlaylistSongs(id),
      ])
      
      // Obtener allPlaylists para metadata (comment, owner, songCount, etc.)
      // El 'comment' es crítico para detectar playlists Spotify Synced
      let metadata = null
      if (!playlistInfo?.coverArt || !playlistInfo?.owner || (playlistInfo as { comment?: string } | null)?.comment === undefined) {
        const allPlaylists = await navidromeApi.getPlaylists()
        metadata = allPlaylists.find(p => p.id === id)
      }
      
      const aggregatedDuration = playlistSongs.reduce((acc, song) => acc + (song.duration || 0), 0)
      const fallbackName = playlistInfo?.name ?? metadata?.name ?? 'Playlist sin nombre'
      const normalizedName = fallbackName.trim().length > 0 ? fallbackName.trim() : 'Playlist sin nombre'

      const playlistDetails: PlaylistDetails | null =
        playlistInfo || metadata
          ? {
              id,
              name: normalizedName.split(' · ')[0],
              coverArt: playlistInfo?.coverArt ?? metadata?.coverArt,
              owner: playlistInfo?.owner ?? metadata?.owner ?? navidromeConfig?.username ?? undefined,
              comment: metadata?.comment ?? (playlistInfo as { comment?: string } | null)?.comment ?? undefined,
              songCount: metadata?.songCount ?? playlistSongs.length,
              duration: metadata?.duration ?? aggregatedDuration,
              public: metadata?.public ?? false,
              created: metadata?.created,
              changed: playlistInfo?.changed ?? metadata?.changed,
              path: metadata?.path,
            }
          : null

      // Actualizar el ref con el nuevo timestamp changed (sin causar re-render)
      if (playlistDetails?.changed) {
        playlistChangedRef.current = playlistDetails.changed
      }

      setPlaylist(playlistDetails)
      setSongs(playlistSongs)
      
      // Actualizar playlist anclada solo si realmente está anclada Y hay cambios significativos
      // Capturamos isPinned y updatePinnedPlaylist en el momento de la ejecución, no como dependencias
      if (playlistDetails?.name && isPinned(id)) {
        const currentPinned = pinnedPlaylists.find(p => p.id === id)
        const needsUpdate = 
          currentPinned && (
            playlistDetails.changed !== currentPinned.changed ||
            playlistDetails.songCount !== currentPinned.songCount
          )
        
        if (needsUpdate) {
          console.log('[PlaylistDetail] Actualizando metadata de playlist anclada')
          updatePinnedPlaylist({
            id,
            name: playlistDetails.name,
            owner: playlistDetails.owner,
            songCount: playlistDetails.songCount,
            duration: playlistDetails.duration,
            created: playlistDetails.created,
            changed: playlistDetails.changed,
            coverArt: playlistDetails.coverArt,
            comment: playlistDetails.comment,
          })
        }
      }
      
      const savedCover = customCoverService.getCustomCover(id)
      setCustomCoverArt(savedCover)
    } catch (error) {
      console.error('Failed to fetch playlist songs', error)
    } finally {
      setLoading(false)
      isUpdatingRef.current = false
    }
    // ⚠️ IMPORTANTE: Solo dependemos de 'id' y 'navidromeConfig?.username'
    // Capturamos isPinned, updatePinnedPlaylist y pinnedPlaylists del scope sin incluirlos como dependencias
    // para evitar re-creaciones del callback cuando cambian las playlists pinned
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, navidromeConfig?.username])

  // Refs para evitar dependencias circulares
  const loadSongsRef = useRef(loadSongs)
  loadSongsRef.current = loadSongs

  // Usar ref para songs para evitar recrear callbacks innecesariamente
  const songsRef = useRef(songs)
  useEffect(() => { songsRef.current = songs }, [songs])

  // Smart Mix — guardia para no llamar autoCheckSmartMix múltiples veces por la misma playlist+canciones
  const autoCheckCalledRef = useRef<string | null>(null)

  useEffect(() => {
    playlistChangedRef.current = undefined
    isUpdatingRef.current = false
    // Resetear la guardia al cambiar de playlist
    autoCheckCalledRef.current = null
    loadSongsRef.current()
    // El smart mix NO se limpia al navegar: persiste en PlayerContext y expira a los 30 min
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id])

  // Cuando las canciones cargan, lanzar el chequeo automático de Smart Mix:
  //   1. Comprueba localStorage (instantáneo)
  //   2. Si no está, consulta la DB del backend
  //   Si todas las canciones están analizadas → botón "Reproducir SmartMix" aparece solo
  useEffect(() => {
    if (!backendAvailable || !id || songs.length === 0) return
    const key = `${id}_${songs.length}`
    if (autoCheckCalledRef.current === key) return
    autoCheckCalledRef.current = key
    playerActions.autoCheckSmartMix?.(id, songs)
  }, [id, songs, playerActions, backendAvailable])



  const handleFileChange = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0]
    if (!file || !id) return

    const reader = new FileReader()
    reader.onload = e => {
      const imageDataUrl = e.target?.result as string
      if (imageDataUrl) {
        customCoverService.setCustomCover(id, imageDataUrl)
        setCustomCoverArt(imageDataUrl)
      }
    }
    reader.readAsDataURL(file)

  }

  const handleSmartMixClick = useCallback(() => {
    if (!id) return
    if (isCurrentPlaylistSmartMixed && smartMixStatus === 'ready') {
      playGeneratedSmartMix()
    } else if (isCurrentPlaylistSmartMixed && smartMixStatus === 'idle') {
      generateSmartMix(id, songsRef.current)
    } else if (!isCurrentPlaylistSmartMixed) {
      generateSmartMix(id, songsRef.current)
    }
  }, [id, isCurrentPlaylistSmartMixed, smartMixStatus, playGeneratedSmartMix, generateSmartMix])

  const handlePlaySong = useCallback((song: Song) => {
    // La lógica de reproducción ahora se gestiona globalmente
    // El contexto decidirá si usar la cola normal o la de smart mix
    playerActions.playPlaylistFromSong(songsRef.current, song)
  }, [playerActions])

  const handleMainPlayClick = useCallback(() => {
    if (isThisPlaylistPlaying) {
      if (isRemote) {
        sendRemoteCommand(isPlaying ? 'pause' : 'play', null, activeDeviceId!)
      } else {
        playerActions.togglePlayPause()
      }
    } else {
      playerActions.playPlaylist(songsRef.current)
    }
  }, [isThisPlaylistPlaying, isRemote, isPlaying, sendRemoteCommand, activeDeviceId, playerActions])

  const handleDeletePlaylist = async () => {
    if (!id || !playlist) return

    setIsDeleting(true)
    try {
      const success = await navidromeApi.deletePlaylist(id)
      
      if (success) {
        console.log('[PlaylistDetail] Playlist eliminada exitosamente')
        
        // Si estaba anclada, desanclarla
        if (isPinned(id)) {
          togglePinnedPlaylist({
            id: playlist.id,
            name: playlist.name,
            owner: playlist.owner,
            songCount: playlist.songCount,
            duration: playlist.duration,
            created: playlist.created,
            changed: playlist.changed,
            coverArt: playlist.coverArt,
            comment: playlist.comment,
          })
        }
        
        // Navegar de vuelta a la página de playlists
        navigate('/playlists')
      } else {
        console.error('[PlaylistDetail] Error al eliminar playlist')
        alert('No se pudo eliminar la playlist. Inténtalo de nuevo.')
      }
    } catch (error) {
      console.error('[PlaylistDetail] Error al eliminar playlist:', error)
      alert('Ocurrió un error al eliminar la playlist.')
    } finally {
      setIsDeleting(false)
      setShowDeleteConfirm(false)
    }
  }


  return (
    <div ref={rootRef} style={pageBgColor ? { ['--bg-base' as string]: pageBgColor } : undefined}>
      {loading && !pinnedFallback ? (
        <div className="flex flex-col items-center justify-center gap-3 py-32 text-center text-gray-500 dark:text-gray-400">
          <div className="w-10 h-10 border-2 border-current border-t-transparent rounded-full animate-spin" />
          <p>Cargando playlist...</p>
        </div>
      ) : (
        <>
          <PageHero
            type="playlist"
            title={(displayPlaylist?.name ?? 'Playlist').split(' · ')[0]}
            subtitle={playlistVisibility}
            coverImageUrl={coverImageUrl || null}
            dominantColors={dominantColors || null}
            onPlay={handleMainPlayClick}
            isPlaying={!!(isThisPlaylistPlaying && isPlaying)}
            isRemote={!!isRemote}
            coverArtId={displayPlaylist?.coverArt}
            customCoverUrl={activeCoverUrl}
            isGeneratingCover={isGeneratingCover}
            metadata={
              <div className="mt-5 flex flex-wrap items-center justify-center md:justify-start gap-x-1 gap-y-1 text-xs md:text-base text-[var(--hero-text-muted)]">
                <button
                  onClick={() => navigate(`/user/${displayPlaylist?.owner || ownerName}`)}
                  className="hover:underline transition-all cursor-pointer whitespace-nowrap"
                >
                  {ownerName}
                </button>
                {!isDailyMix && (
                  <>
                    <span className="text-[var(--hero-text-dim)] text-[8px]">·</span>
                    <span className="whitespace-nowrap">{songCountLabel}</span>
                  </>
                )}
                {totalDurationFormatted && (
                  <>
                    <span className="text-[var(--hero-text-dim)] text-[8px]">·</span>
                    <span className="whitespace-nowrap">{totalDurationFormatted}</span>
                  </>
                )}
                {displayPlaylistComment && !isDailyMix && (
                  <>
                    <span className="text-[var(--hero-text-dim)] text-[8px]">·</span>
                    <span className="italic text-[var(--hero-text-muted)]">{displayPlaylistComment}</span>
                  </>
                )}
                {isDailyMix && (
                  <>
                    <span className="text-[var(--hero-text-dim)] text-[8px]">·</span>
                    <span className="inline-flex items-center gap-1.5 text-[var(--hero-text-muted)] whitespace-nowrap">
                      <img
                        src="/assets/logo-icon.svg"
                        alt="Audiorr"
                        className="w-4 h-4 opacity-70"
                        style={{ filter: 'var(--hero-logo-filter, brightness(0) invert(1))' }}
                      />
                      <span title={displayPlaylist?.changed ? new Date(displayPlaylist.changed).toLocaleString() : undefined}>
                        {displayPlaylist?.changed
                          ? `Generado ${timeAgo(displayPlaylist.changed)}`
                          : 'Generado hace un momento'}
                      </span>
                    </span>
                  </>
                )}
              </div>
            }
            actions={
              <div className="flex items-center gap-2">
                {backendAvailable && (
                  <button
                    onClick={handleSmartMixClick}
                    disabled={isSmartMixPlaying || (isCurrentPlaylistSmartMixed && smartMixStatus === 'analyzing')}
                    {...springPress}
                    className={`group inline-flex h-11 items-center justify-center gap-2 rounded-full px-4 text-sm font-semibold transition-all duration-200 focus:outline-none select-none ${
                      isSmartMixPlaying
                        ? 'smartmix-playing-btn text-gray-900 dark:text-white'
                        : isCurrentPlaylistSmartMixed && smartMixStatus === 'analyzing'
                          ? 'border border-white/15 bg-white/[.08] text-white/50 cursor-not-allowed'
                          : isCurrentPlaylistSmartMixed && smartMixStatus === 'error'
                            ? 'border border-red-400/30 bg-red-900/30 text-red-300'
                            : accentButtonStyle
                              ? `border-none shadow-md ${isCurrentPlaylistSmartMixed && smartMixStatus === 'ready' ? 'smartmix-ready' : ''}`
                              : 'bg-white/[.15] text-white border border-white/20'
                    }`}
                    style={
                      isSmartMixPlaying
                        ? undefined
                        : {
                            backdropFilter: 'blur(24px) saturate(1.8)',
                            WebkitBackdropFilter: 'blur(24px) saturate(1.8)',
                            ...(accentButtonStyle ?? {}),
                          }
                    }
                  >
                    {isCurrentPlaylistSmartMixed && smartMixStatus === 'analyzing' && (
                      <ArrowPathIcon className="w-4 h-4 animate-spin opacity-60" />
                    )}
                    {(!isCurrentPlaylistSmartMixed || smartMixStatus === 'idle') && (
                      <SparklesIcon className="w-4 h-4 group-hover:scale-110 transition-transform duration-300" />
                    )}
                    {isCurrentPlaylistSmartMixed && smartMixStatus === 'ready' && !isSmartMixPlaying && (
                      <SparklesIcon className="w-4 h-4 smartmix-icon-ready" />
                    )}
                    {isSmartMixPlaying && <CheckIcon className="w-4 h-4" />}
                    {isCurrentPlaylistSmartMixed && smartMixStatus === 'error' && (
                      <XCircleIcon className="w-4 h-4 text-red-300" />
                    )}
                    <span className="whitespace-nowrap tracking-normal">
                      {isSmartMixPlaying && 'Mezcla activa'}
                      {isCurrentPlaylistSmartMixed && smartMixStatus === 'analyzing' && 'Analizando...'}
                      {(!isCurrentPlaylistSmartMixed || smartMixStatus === 'idle') && 'Mezcla Inteligente'}
                      {isCurrentPlaylistSmartMixed && smartMixStatus === 'ready' && !isSmartMixPlaying && 'SmartMix'}
                      {isCurrentPlaylistSmartMixed && smartMixStatus === 'error' && 'Reintentar'}
                    </span>
                  </button>
                )}
                {id && (
                  <button
                    onClick={() =>
                      togglePinnedPlaylist({
                        id,
                        name: displayPlaylist?.name ?? '',
                        owner: displayPlaylist?.owner ?? ownerName,
                        songCount: displayPlaylist?.songCount ?? songs.length,
                        duration: displayPlaylist?.duration ?? totalDurationSeconds,
                        created: displayPlaylist?.created,
                        changed: displayPlaylist?.changed,
                        coverArt: displayPlaylist?.coverArt,
                        comment: displayPlaylist?.comment,
                      })
                    }
                    {...springPress}
                    className={`flex-shrink-0 flex h-11 w-11 items-center justify-center rounded-full select-none focus:outline-none ${
                      accentButtonStyle ? 'border-none shadow-md' : 'text-white bg-white/[.15] border border-white/20'
                    }`}
                    style={{
                      backdropFilter: 'blur(24px) saturate(1.8)',
                      WebkitBackdropFilter: 'blur(24px) saturate(1.8)',
                      ...(accentButtonStyle ?? {}),
                    }}
                    aria-pressed={isPinned(id)}
                    aria-label={isPinned(id) ? 'Desanclar playlist' : 'Anclar playlist'}
                  >
                    {isPinned(id) ? <PinFilledIcon className="w-5 h-5 opacity-90" /> : <PinOutlinedIcon className="w-5 h-5" />}
                  </button>
                )}
              </div>
            }
          />

        <input
          hidden
          type="file"
          ref={fileInputRef}
          onChange={handleFileChange}
          accept="image/*"
        />

        <div className="px-5 md:px-8 lg:px-10 space-y-8 mt-6">
          <SongTable
            songs={songs}
            currentSongId={effectiveCurrentSongId}
            isPlaying={isPlaying}
            isAnalyzing={isPlayerAnalyzing}
            analysisCurrentSongId={analysisCurrentSongId}
            onSongDoubleClick={handlePlaySong}
            onSongContextMenu={handleContextMenu}
            showAlbum={true}
            showCover={true}
            accentColor={dominantColors?.accent}
            immersive={!!pageBgColor}
          />
        </div>

      {menu && (
        <SongContextMenu
          x={menu.x}
          y={menu.y}
          song={menu.song}
          onClose={closeContextMenu}
          showGoToArtist={true}
          showGoToAlbum={true}
          isAdmin={navidromeApi.getConfig()?.isAdmin === true}
        />
      )}

      {/* Modal de confirmación para eliminar */}
      {showDeleteConfirm && createPortal(
        <div 
          className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/50 backdrop-blur-sm animate-in fade-in duration-200"
          onClick={(e) => {
            if (e.target === e.currentTarget && !isDeleting) {
              setShowDeleteConfirm(false)
            }
          }}
        >
          <div className="bg-white dark:bg-gray-900 rounded-2xl shadow-2xl w-full max-w-md overflow-hidden animate-in zoom-in-95 duration-200">
            <div className="p-6">
              <div className="flex items-center gap-4 mb-4">
                <div className="flex-shrink-0 w-12 h-12 bg-red-100 dark:bg-red-900/30 rounded-full flex items-center justify-center">
                  <TrashIcon className="w-6 h-6 text-red-600 dark:text-red-400" />
                </div>
                <div>
                  <h3 className="text-lg font-bold text-gray-900 dark:text-white">
                    Eliminar Playlist
                  </h3>
                  <p className="text-sm text-gray-500 dark:text-gray-400">
                    Esta acción no se puede deshacer
                  </p>
                </div>
              </div>
              
              <p className="text-gray-700 dark:text-gray-300 mb-6">
                ¿Estás seguro de que quieres eliminar <strong>"{playlist?.name}"</strong>? 
                Esta playlist y todas sus canciones se eliminarán permanentemente.
              </p>

              <div className="flex items-center gap-3">
                <button
                  onClick={() => setShowDeleteConfirm(false)}
                  disabled={isDeleting}
                  className="flex-1 px-4 py-3 rounded-xl border border-gray-300 dark:border-gray-700 text-gray-700 dark:text-gray-300 font-semibold hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  Cancelar
                </button>
                <button
                  onClick={handleDeletePlaylist}
                  disabled={isDeleting}
                  className="flex-1 px-4 py-3 rounded-xl bg-red-500 text-white font-semibold hover:bg-red-600 transition-colors disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2"
                >
                  {isDeleting ? (
                    <>
                      <div className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin" />
                      <span>Eliminando...</span>
                    </>
                  ) : (
                    <>
                      <TrashIcon className="w-5 h-5" />
                      <span>Eliminar</span>
                    </>
                  )}
                </button>
              </div>
            </div>
          </div>
        </div>,
        document.body
      )}
        </>
      )}
    </div>
  )
}
