import { useState, useEffect, useCallback, useRef } from 'react'
import { useParams, Link } from 'react-router-dom'
import { navidromeApi, Song } from '../services/navidromeApi'
import { usePlayerActions, usePlayerState } from '../contexts/PlayerContext'
import { Capacitor } from '@capacitor/core'
import PageHero from './PageHero'
import { ArtistLinks } from './ArtistLinks'
import AlbumCoverModal from './AlbumCoverModal'
import { useDominantColors } from '../hooks/useDominantColors'
import { useConnect } from '../hooks/useConnect'
import { SongTable } from './SongTable'
import { useHeroPresence } from '../contexts/HeroPresenceContext'

const isNativeSong = Capacitor.isNativePlatform()

function SongDetailSkeleton() {
  const { incHero, decHero } = useHeroPresence()
  useEffect(() => {
    incHero()
    return () => { decHero() }
  }, [incHero, decHero])

  const rows = 5
  const widths = ['w-3/4', 'w-1/2', 'w-2/3', 'w-4/5', 'w-2/5']
  const artistWidths = ['w-1/3', 'w-1/4', 'w-2/5', 'w-1/3', 'w-1/4']
  return (
    <div className="animate-pulse">
      {/* Hero */}
      <div
        className="relative overflow-hidden rounded-none md:rounded-3xl bg-gray-900 dark:bg-gray-900/80 flex flex-col md:flex-row items-center md:items-end gap-3 md:gap-6 px-5 md:px-8 lg:px-10 pb-9"
        style={{ minHeight: 340, paddingTop: isNativeSong ? 'calc(env(safe-area-inset-top) + 24px)' : '3.5rem' }}
      >
        <div className="w-[148px] h-[148px] md:w-[200px] md:h-[200px] lg:w-[232px] lg:h-[232px] flex-shrink-0 rounded-xl md:rounded-2xl bg-white/10" />
        <div className="flex-1 min-w-0 text-center md:text-left space-y-3 w-full">
          <div className="h-2.5 w-16 rounded-full bg-white/15 mx-auto md:mx-0" />
          <div className="h-9 md:h-14 w-3/4 rounded-xl bg-white/15 mx-auto md:mx-0" />
          <div className="h-5 w-1/3 rounded-full bg-white/10 mx-auto md:mx-0" />
          <div className="flex items-center gap-2 justify-center md:justify-start mt-2">
            <div className="h-3.5 w-20 rounded-full bg-white/10" />
            <div className="h-2 w-1 rounded-full bg-white/8" />
            <div className="h-3.5 w-14 rounded-full bg-white/10" />
          </div>
        </div>
        <div className="absolute bottom-0 left-0 right-0 h-[30%] bg-gradient-to-b from-transparent to-gray-950/80 pointer-events-none" />
      </div>
      {/* Song row + similar songs */}
      <div className="px-5 md:px-8 lg:px-10 mt-6 space-y-8">
        <div className="overflow-hidden rounded-none md:rounded-2xl border-y md:border border-gray-200/80 bg-white dark:border-white/5 dark:bg-gray-900/40 -mx-5 md:mx-0">
          <div className="grid grid-cols-[1fr,auto] md:grid-cols-[1fr,2.5rem] items-center gap-2 md:gap-3 px-3 md:px-4 py-2">
            <div className="min-w-0 space-y-1.5">
              <div className="h-4 w-2/5 rounded-full bg-gray-200 dark:bg-white/10" />
              <div className="h-3 w-1/4 rounded-full bg-gray-100 dark:bg-white/[0.06]" />
            </div>
            <div className="h-3 w-8 rounded-full bg-gray-100 dark:bg-white/[0.06]" />
          </div>
        </div>
        <div>
          <div className="h-7 w-44 rounded-lg mb-6 bg-gray-200 dark:bg-white/10" />
          <div className="overflow-hidden rounded-none md:rounded-2xl border-y md:border border-gray-200/80 bg-white dark:border-white/5 dark:bg-gray-900/40 -mx-5 md:mx-0 divide-y divide-gray-100/80 dark:divide-white/[0.04]">
            {Array.from({ length: rows }).map((_, i) => (
              <div key={i} className="grid grid-cols-[1fr,auto] md:grid-cols-[1fr,2.5rem] items-center gap-2 md:gap-3 px-3 md:px-4 py-2">
                <div className="flex items-center gap-3 min-w-0">
                  <div className="w-10 h-10 rounded-md flex-shrink-0 bg-gray-200 dark:bg-white/10" />
                  <div className="min-w-0 space-y-1.5">
                    <div className={`h-4 ${widths[i]} rounded-full bg-gray-200 dark:bg-white/10`} />
                    <div className={`h-3 ${artistWidths[i]} rounded-full bg-gray-100 dark:bg-white/[0.06]`} />
                  </div>
                </div>
                <div className="h-3 w-8 rounded-full bg-gray-100 dark:bg-white/[0.06]" />
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}

function computePageBgColor(hex: string, solidOnLight = false): string {
  if (!hex.startsWith('#') || hex.length < 7) return solidOnLight ? '#f5f5f0' : '#1a1212'
  const r = parseInt(hex.slice(1, 3), 16)
  const g = parseInt(hex.slice(3, 5), 16)
  const b = parseInt(hex.slice(5, 7), 16)
  if (solidOnLight) {
    const nr = Math.round(r * 0.65 + 255 * 0.35)
    const ng = Math.round(g * 0.65 + 255 * 0.35)
    const nb = Math.round(b * 0.65 + 255 * 0.35)
    return `#${nr.toString(16).padStart(2, '0')}${ng.toString(16).padStart(2, '0')}${nb.toString(16).padStart(2, '0')}`
  }
  const nr = Math.round(r * 0.30 + 14 * 0.70)
  const ng = Math.round(g * 0.30 + 14 * 0.70)
  const nb = Math.round(b * 0.30 + 14 * 0.70)
  return `#${nr.toString(16).padStart(2, '0')}${ng.toString(16).padStart(2, '0')}${nb.toString(16).padStart(2, '0')}`
}


export default function SongDetail() {
  const { id } = useParams<{ id: string }>()
  const [song, setSong] = useState<Song | null>(null)
  const [albumInfo, setAlbumInfo] = useState<{
    mbReleaseType?: string
    originalReleaseDate?: { year: number; month?: number; day?: number }
    releaseDate?: { year: number; month?: number; day?: number }
    recordLabels?: Array<{ name: string }>
    year?: number
  } | null>(null)
  const [similarSongs, setSimilarSongs] = useState<Song[]>([])
  const [loading, setLoading] = useState(true)
  const [loadingSimilar, setLoadingSimilar] = useState(false)
  const [showCoverModal, setShowCoverModal] = useState(false)
  const [coverImageUrl, setCoverImageUrl] = useState<string | null>(null)
  const playerActions = usePlayerActions()
  const playerState = usePlayerState()
  const { isConnected, activeDeviceId, currentDeviceId, remotePlaybackState, sendRemoteCommand } = useConnect()

  const dominantColors = useDominantColors(coverImageUrl)

  const solidOnLight = !!(dominantColors?.isSolid && dominantColors.primary.startsWith('#') &&
    parseInt(dominantColors.primary.slice(1, 3), 16) * 0.299 +
    parseInt(dominantColors.primary.slice(3, 5), 16) * 0.587 +
    parseInt(dominantColors.primary.slice(5, 7), 16) * 0.114 > 160)

  const pageBgColor = dominantColors
    ? computePageBgColor(dominantColors.primary, solidOnLight)
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

  // Lógica de reproducción remota vs local
  const isRemote = isConnected && activeDeviceId && activeDeviceId !== currentDeviceId
  const currentSongId = isRemote ? remotePlaybackState?.trackId : playerState.currentSong?.id
  const isPlaying = isRemote ? remotePlaybackState?.playing : playerState.isPlaying
  
  // Verificar si esta canción es la que suena
  const isThisSongPlaying = currentSongId === id

  const handleMainPlayClick = useCallback(() => {
    if (isThisSongPlaying && song) {
      if (isRemote) {
        sendRemoteCommand(isPlaying ? 'pause' : 'play', null, activeDeviceId!)
      } else {
        playerActions.togglePlayPause()
      }
    } else if (song) {
      playerActions.setCurrentContextUri(`song:${id}`)
      playerActions.playSong(song)
    }
  }, [isThisSongPlaying, isRemote, isPlaying, sendRemoteCommand, activeDeviceId, playerActions, song, id])

  // Carga de la información principal de la canción
  useEffect(() => {
    const fetchSong = async () => {
      if (!id) return
      // Reiniciar estado para navegación
      setSong(null)
      setAlbumInfo(null)
      setSimilarSongs([])
      setLoading(true)

      try {
        const detailedSong = await navidromeApi.getSong(id)
        if (!detailedSong) return
        setSong(detailedSong)

        // Obtener URL de la carátula para el modal (alta calidad para modal pero razonable para red)
        if (detailedSong.coverArt) {
          setCoverImageUrl(navidromeApi.getCoverUrl(detailedSong.coverArt, 2000))
        }

        // Obtener información del álbum si tenemos el albumId
        if (detailedSong.albumId) {
          try {
            const albumData = await navidromeApi.getAlbumInfo(detailedSong.albumId)
            if (albumData) {
              setAlbumInfo({
                mbReleaseType: albumData.mbReleaseType,
                originalReleaseDate: albumData.originalReleaseDate,
                releaseDate: albumData.releaseDate,
                recordLabels: albumData.recordLabels,
                year: albumData.year,
              })
            }
          } catch (albumError) {
            console.error('Failed to fetch album info', albumError)
          }
        }
      } catch (error) {
        console.error('Failed to fetch song details', error)
      } finally {
        setLoading(false)
      }
    }
    fetchSong()
  }, [id])

  // Carga de canciones similares en segundo plano
  useEffect(() => {
    if (!song) return

    const fetchSimilar = async () => {
      setLoadingSimilar(true)
      try {
        const similar = await navidromeApi.getSimilarSongs(song.artist, song.title)
        const filteredSimilar = similar.filter(s => s.id !== id) // Filtrar la propia canción
        setSimilarSongs(filteredSimilar)
      } catch (similarError) {
        console.error('[SongDetail] Error al buscar canciones similares:', similarError)
        setSimilarSongs([])
      } finally {
        setLoadingSimilar(false)
      }
    }

    fetchSimilar()
  }, [song, id])



  if (loading) {
    return <SongDetailSkeleton />
  }

  if (!song) {
    return (
      <div className="text-center text-red-500">
        No se pudo cargar la información de la canción.
      </div>
    )
  }

  const handlePlaySong = (songToPlay: Song) => {
    playerActions.setCurrentContextUri(`song:${songToPlay.id}`)
    playerActions.playSong(songToPlay)
  }



  const formatDate = (date?: { year: number; month?: number; day?: number }) => {
    if (!date || !date.year) return null

    const monthNames = [
      'enero',
      'febrero',
      'marzo',
      'abril',
      'mayo',
      'junio',
      'julio',
      'agosto',
      'septiembre',
      'octubre',
      'noviembre',
      'diciembre',
    ]

    const parts: string[] = []

    if (date.day) {
      parts.push(date.day.toString())
    }

    if (date.month) {
      parts.push(monthNames[date.month - 1])
    }

    parts.push(date.year.toString())

    if (parts.length === 3) {
      return `${parts[0]} de ${parts[1]} de ${parts[2]}`
    } else if (parts.length === 2) {
      // Solo mes y año
      return `${parts[0]} de ${parts[1]}`
    } else {
      // Solo año
      return parts[0]
    }
  }

  const getReleaseTypeLabel = (mbReleaseType?: string): string | null => {
    if (!mbReleaseType) return null

    const typeMap: Record<string, string> = {
      album: 'Álbum',
      single: 'Sencillo',
      ep: 'EP',
      compilation: 'Compilación',
      live: 'En Vivo',
      soundtrack: 'Banda Sonora',
      remix: 'Remix',
      demo: 'Demo',
      other: 'Otro',
    }

    return typeMap[mbReleaseType.toLowerCase()] || mbReleaseType
  }

  const handleCoverClick = () => {
    if (coverImageUrl) {
      setShowCoverModal(true)
    }
  }

  return (
    <div ref={rootRef} style={pageBgColor ? { ['--bg-base' as string]: pageBgColor } : undefined}>
      <PageHero
        type="song"
        title={song.title}
        subtitle="Canción"
        coverImageUrl={coverImageUrl}
        dominantColors={dominantColors || null}
        onPlay={handleMainPlayClick}
        isPlaying={!!(isThisSongPlaying && isPlaying)}
        isRemote={!!isRemote}
        coverArtId={song.coverArt}
        onCoverClick={handleCoverClick}
        widePlayButton
        metadata={
          <>
            <div className="mt-5 flex flex-wrap items-center gap-x-2 gap-y-1 text-lg md:text-xl text-[var(--hero-text-muted)]">
              <ArtistLinks
                artists={song.artist}
                className="hover:text-[var(--hero-text)] transition-colors inline-block font-semibold"
              />
              <span className="text-[var(--hero-text-dim)]">•</span>
              <Link
                to={`/albums/${song.albumId}`}
                className="hover:text-[var(--hero-text)] transition-colors font-semibold"
              >
                {song.album}
              </Link>
            </div>
            <div className="mt-4 flex flex-wrap items-center justify-center md:justify-start gap-x-1.5 gap-y-1 text-xs md:text-base text-[var(--hero-text-muted)]">
              {getReleaseTypeLabel(albumInfo?.mbReleaseType) && (
                <>
                  <span className="whitespace-nowrap">{getReleaseTypeLabel(albumInfo?.mbReleaseType)}</span>
                  <span className="text-[var(--hero-text-dim)] text-[10px] mx-0.5">•</span>
                </>
              )}
              {formatDate(albumInfo?.originalReleaseDate) && (
                <>
                  <span className="whitespace-nowrap">{formatDate(albumInfo?.originalReleaseDate)}</span>
                  {song.genre && <span className="text-[var(--hero-text-dim)] text-[10px] mx-0.5">•</span>}
                </>
              )}
              {song.genre && (
                <div className="flex items-center flex-wrap justify-center md:justify-start gap-x-1.5">
                  {song.genre.split(',').map((g, idx, arr) => (
                    <span key={g.trim()} className="flex items-center gap-x-1.5">
                      <Link
                        to={`/genre/${encodeURIComponent(g.trim())}`}
                        className="text-[var(--hero-text-muted)] hover:text-[var(--hero-text)] hover:underline transition-colors cursor-pointer whitespace-nowrap"
                      >
                        {g.trim()}
                      </Link>
                      {idx < arr.length - 1 && <span className="text-[var(--hero-text-dim)] text-[10px] mx-0.5">•</span>}
                    </span>
                  ))}
                </div>
              )}
            </div>
          </>
        }
      />

      <div className="px-5 md:px-8 lg:px-10 space-y-8 mt-6">
        <SongTable
          songs={[song]}
          currentSongId={playerState.currentSong?.id}
          isPlaying={playerState.isPlaying}
          onSongDoubleClick={handlePlaySong}
          onSongContextMenu={() => {}} // No context menu for the main song card here
          showAlbum={false}
          showCover={false}
          showIndex={false}
          accentColor={dominantColors?.accent}
          immersive={pageBgColor ? (solidOnLight ? 'light' : true) : false}
        />

        {albumInfo?.recordLabels && albumInfo.recordLabels.length > 0 && (
          <div className={`mt-6 pt-2 text-xs ${pageBgColor ? (solidOnLight ? 'text-gray-500' : 'text-white/35') : 'text-gray-400 dark:text-gray-500'}`}>
            ©{' '}
            {albumInfo.originalReleaseDate?.year ||
              albumInfo.year ||
              song.year ||
              new Date().getFullYear()}{' '}
            {albumInfo.recordLabels.map(label => label.name).join(', ')}
          </div>
        )}

        {/* --- Sección de Canciones Similares --- */}
        <div>
          <h2 className={`text-2xl font-bold mb-6 ${pageBgColor ? (solidOnLight ? 'text-gray-900' : 'text-white') : 'text-gray-900 dark:text-white'}`}>
            Canciones Similares
          </h2>
          {loadingSimilar && (
            <div className="space-y-1">
              {Array.from({ length: 5 }).map((_, i) => (
                <div key={i} className="flex items-center gap-3 px-2 py-2 rounded-lg animate-pulse">
                  <div className={`w-10 h-10 rounded flex-shrink-0 ${pageBgColor ? (solidOnLight ? 'bg-black/10' : 'bg-white/10') : 'bg-gray-200 dark:bg-white/[0.08]'}`} />
                  <div className="flex-1 min-w-0 space-y-2">
                    <div className={`h-3.5 w-2/5 rounded-full ${pageBgColor ? (solidOnLight ? 'bg-black/10' : 'bg-white/10') : 'bg-gray-200 dark:bg-white/[0.08]'}`} />
                    <div className={`h-3 w-1/4 rounded-full ${pageBgColor ? (solidOnLight ? 'bg-black/[0.06]' : 'bg-white/[0.06]') : 'bg-gray-100 dark:bg-white/[0.05]'}`} />
                  </div>
                  <div className={`h-3 w-8 rounded-full flex-shrink-0 ${pageBgColor ? (solidOnLight ? 'bg-black/[0.06]' : 'bg-white/[0.06]') : 'bg-gray-100 dark:bg-white/[0.05]'}`} />
                </div>
              ))}
            </div>
          )}
          {!loadingSimilar && similarSongs.length === 0 && (
            <p className={`text-center py-8 ${pageBgColor ? (solidOnLight ? 'text-gray-500' : 'text-white/50') : 'text-gray-500 dark:text-gray-400'}`}>
              No se encontraron canciones similares en tu biblioteca.
            </p>
          )}
          {!loadingSimilar && similarSongs.length > 0 && (
            <SongTable
              songs={similarSongs}
              currentSongId={playerState.currentSong?.id}
              isPlaying={playerState.isPlaying}
              onSongDoubleClick={(s) => { playerActions.setCurrentContextUri(`song:${s.id}`); playerActions.playSong(s) }}
              onSongContextMenu={() => {}} // Context menu not implemented for similar songs yet
              showAlbum={false}
              showCover={true}
              showIndex={false}
              accentColor={dominantColors?.accent}
              immersive={pageBgColor ? (solidOnLight ? 'light' : true) : false}
            />
          )}
        </div>
      </div>

      <AlbumCoverModal
        imageUrl={coverImageUrl}
        alt={song.album}
        isOpen={showCoverModal}
        onClose={() => setShowCoverModal(false)}
      />
    </div>
  )
}
