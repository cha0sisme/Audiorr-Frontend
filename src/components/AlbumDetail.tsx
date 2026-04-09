import { useState, useEffect, useCallback, useRef } from 'react'
import { useParams, Link } from 'react-router-dom'
import { navidromeApi, Song } from '../services/navidromeApi'
import { usePlayerState, usePlayerActions } from '../contexts/PlayerContext'
import PageHero from './PageHero'
import { ArtistLinks } from './ArtistLinks'
import { useContextMenu } from '../hooks/useContextMenu'
import SongContextMenu from './SongContextMenu'
import AlbumCoverModal from './AlbumCoverModal'
import { useDominantColors } from '../hooks/useDominantColors'
import { useConnect } from '../hooks/useConnect'
import { SongTable } from './SongTable'

/** Returns a darkened page background color derived from the album's primary color.
 *  Blends 30% primary + 70% near-black so the result is clearly dark but tinted. */
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


export default function AlbumDetail() {
  const { id } = useParams<{ id: string }>()
  const [songs, setSongs] = useState<Song[]>([])
  const [albumInfo, setAlbumInfo] = useState<{
    name: string
    artist: string
    coverArt?: string
    year?: number
    originalReleaseDate?: { year: number; month?: number; day?: number }
    releaseDate?: { year: number; month?: number; day?: number }
    genre?: string
    mbReleaseType?: string
    recordLabels?: Array<{ name: string }>
    explicitStatus?: string
  } | null>(null)
  const [loading, setLoading] = useState(true)
  const [albumNotes, setAlbumNotes] = useState<string | null>(null)
  const [showCoverModal, setShowCoverModal] = useState(false)
  const [coverImageUrl, setCoverImageUrl] = useState<string | null>(null)
  const playerActions = usePlayerActions()
  const playerState = usePlayerState()
  const { isConnected, activeDeviceId, currentDeviceId, remotePlaybackState, sendRemoteCommand } = useConnect()
  const { menu, handleContextMenu, closeContextMenu } = useContextMenu()

  const dominantColors = useDominantColors(coverImageUrl)


  const pageBgColor = dominantColors
    ? computePageBgColor(dominantColors.primary)
    : null

  // Paint the StackPage scrollable container with the album color so the
  // background fills the full viewport (including the 200px bottom padding)
  // without adding any fake scroll height.
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
  const currentSource = isRemote ? remotePlaybackState?.currentSource : playerState.currentSource
  const isPlaying = isRemote ? remotePlaybackState?.playing : playerState.isPlaying
  
  // Verificar si este álbum es el que suena
  const isThisAlbumPlaying = currentSource === `album:${id}`
  const currentSongId = isRemote ? remotePlaybackState?.trackId : playerState.currentSong?.id

  const handleMainPlayClick = useCallback(() => {
    if (isThisAlbumPlaying) {
      if (isRemote) {
        sendRemoteCommand(isPlaying ? 'pause' : 'play', null, activeDeviceId!)
      } else {
        playerActions.togglePlayPause()
      }
    } else {
      playerActions.playPlaylist(songs, `album:${id}`)
    }
  }, [isThisAlbumPlaying, isRemote, isPlaying, sendRemoteCommand, activeDeviceId, playerActions, songs, id])

  useEffect(() => {
    const fetchAlbumSongs = async () => {
      if (!id) return
      try {
        setLoading(true)
        const [albumSongs, albumInfoData] = await Promise.all([
          navidromeApi.getAlbumSongs(id),
          navidromeApi.getAlbumInfo(id),
        ])

        if (albumSongs.length > 0) {
          const sortedSongs = albumSongs.sort((a, b) => (a.track || 0) - (b.track || 0))
          setSongs(sortedSongs)

          let finalCoverArtId: string | undefined
          if (albumInfoData) {
            setAlbumInfo({
              name: albumInfoData.name,
              artist: albumInfoData.artist,
              coverArt: albumInfoData.coverArt,
              year: albumInfoData.year,
              originalReleaseDate: albumInfoData.originalReleaseDate,
              releaseDate: albumInfoData.releaseDate,
              genre: albumInfoData.genre,
              mbReleaseType: albumInfoData.mbReleaseType,
              recordLabels: albumInfoData.recordLabels,
              explicitStatus: albumInfoData.explicitStatus,
            })
            finalCoverArtId = albumInfoData.coverArt
          } else {
            setAlbumInfo({
              name: sortedSongs[0].album,
              artist: sortedSongs[0].artist,
              coverArt: sortedSongs[0].coverArt,
              year: sortedSongs[0].year,
              genre: sortedSongs[0].genre,
            })
            finalCoverArtId = sortedSongs[0].coverArt
          }

          if (finalCoverArtId) {
            setCoverImageUrl(navidromeApi.getCoverUrl(finalCoverArtId, 2000))
          }
        }
      } catch (error) {
        console.error('Failed to fetch album songs', error)
      } finally {
        setLoading(false)
      }
    }

    fetchAlbumSongs()
  }, [id])

  useEffect(() => {
    if (!id) return
    setAlbumNotes(null)
    navidromeApi.getAlbumNotes(id).then(notes => {
      if (notes) setAlbumNotes(notes)
    })
  }, [id])

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-16 text-center text-gray-500 dark:text-gray-400">
        <div className="w-10 h-10 border-2 border-current border-t-transparent rounded-full animate-spin" />
        <p>Cargando canciones del álbum...</p>
      </div>
    )
  }

  if (!albumInfo) {
    return (
      <div className="text-center text-red-500">No se pudo cargar la información del álbum.</div>
    )
  }

  const handlePlaySong = (song: Song) => {
    playerActions.playPlaylistFromSong(songs, song, `album:${id}`)
  }

  const formatDate = (date?: { year: number; month?: number; day?: number }) => {
    if (!date || !date.year) return null

    const monthNames = [
      'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
      'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
    ]

    const parts: string[] = []
    if (date.day) parts.push(date.day.toString())
    if (date.month) parts.push(monthNames[date.month - 1])
    parts.push(date.year.toString())

    if (parts.length === 3) return `${parts[0]} de ${parts[1]} de ${parts[2]}`
    if (parts.length === 2) return `${parts[0]} de ${parts[1]}`
    return parts[0]
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
    // --bg-base is read by PageHero's color bridge so it fades into the album color.
    // backgroundColor is set on the StackPage scrollable container via the ref effect above.
    <div ref={rootRef} style={pageBgColor ? { ['--bg-base' as string]: pageBgColor } : undefined}>
      <PageHero
        type="album"
        title={albumInfo.name}
        subtitle={getReleaseTypeLabel(albumInfo.mbReleaseType) || 'Álbum'}
        coverImageUrl={coverImageUrl}
        dominantColors={dominantColors || null}
        isExplicit={albumInfo.explicitStatus === 'explicit'}
        onPlay={handleMainPlayClick}
        isPlaying={!!(isThisAlbumPlaying && isPlaying)}
        isRemote={!!isRemote}
        coverArtId={albumInfo.coverArt}
        onCoverClick={handleCoverClick}
        widePlayButton={true}
        metadata={
          <>
            <div className="mt-2 text-center md:text-left">
              <ArtistLinks
                artists={albumInfo.artist}
                className="text-lg md:text-xl text-[var(--hero-text-muted)] hover:text-[var(--hero-text)] transition-colors inline-block font-semibold"
              />
            </div>
            <div className="mt-4 flex flex-wrap items-center justify-center md:justify-start gap-x-1 gap-y-1 text-xs md:text-base text-[var(--hero-text-muted)]">
              {formatDate(albumInfo.originalReleaseDate) && (
                <>
                  <span className="whitespace-nowrap">{formatDate(albumInfo.originalReleaseDate)}</span>
                  {albumInfo.genre && <span className="text-[var(--hero-text-dim)] text-[8px]">·</span>}
                </>
              )}
                <div className="flex items-center flex-wrap justify-center md:justify-start gap-x-1">
                  {albumInfo.genre?.split(',').map((g, idx, arr) => (
                    <span key={g.trim()} className="flex items-center gap-x-1">
                      <Link
                        to={`/genre/${encodeURIComponent(g.trim())}`}
                        className="text-[var(--hero-text-muted)] hover:text-[var(--hero-text)] hover:underline transition-colors cursor-pointer whitespace-nowrap"
                      >
                        {g.trim()}
                      </Link>
                      {idx < arr.length - 1 && <span className="text-[var(--hero-text-dim)] text-[8px]">·</span>}
                    </span>
                  ))}
                </div>
            </div>
          </>
        }
      />

      <div className="px-5 md:px-8 lg:px-10 space-y-8 mt-6">
        <SongTable
          songs={songs}
          currentSongId={currentSongId}
          isPlaying={isPlaying && isThisAlbumPlaying}
          onSongDoubleClick={handlePlaySong}
          onSongContextMenu={handleContextMenu}
          showAlbum={false}
          showArtist={false}
          showCover={false}
          useTrackNumber={true}
          accentColor={dominantColors?.accent}
          immersive={!!pageBgColor}
        />

        {albumInfo.recordLabels && albumInfo.recordLabels.length > 0 && (
          <div className="mt-4 pt-2 text-xs text-gray-400 dark:text-gray-500">
            © {albumInfo.originalReleaseDate?.year || albumInfo.year || new Date().getFullYear()}{' '}
            {albumInfo.recordLabels.map(label => label.name).join(', ')}
          </div>
        )}

        {albumNotes && (
          <section className={`mt-12 rounded-3xl p-6 md:p-10 transition-all duration-500 ${pageBgColor ? 'bg-white/[0.08] border border-white/10' : 'bg-gray-50 dark:bg-white/[0.05] border border-gray-200/50 dark:border-white/[0.08]'}`}>
            <h2 className="text-2xl font-extrabold text-gray-900 dark:text-white mb-6">
              Acerca de {albumInfo.name}
            </h2>
            <div
              className="prose prose-sm md:prose-base dark:prose-invert max-w-none text-gray-600 dark:text-gray-300 leading-relaxed font-normal"
              dangerouslySetInnerHTML={{
                __html: albumNotes
                  .replace(/<a[^>]*>.*?Read more on Last\.fm.*?<\/a>/gi, '')
                  .replace(/Read more on Last\.fm/gi, '')
                  .replace(/<a[^>]*>(.*?)<\/a>/gi, '<span class="text-blue-500 hover:underline cursor-pointer">$1</span>')
                  .trim(),
              }}
            />
          </section>
        )}
      </div>

      {menu && (
        <SongContextMenu
          x={menu.x}
          y={menu.y}
          song={menu.song}
          onClose={closeContextMenu}
          showGoToAlbum={false}
          showGoToSong={true}
          isAdmin={navidromeApi.getConfig()?.isAdmin === true}
        />
      )}

      <AlbumCoverModal
        imageUrl={coverImageUrl}
        alt={albumInfo.name}
        isOpen={showCoverModal}
        onClose={() => setShowCoverModal(false)}
      />
    </div>
  )
}
