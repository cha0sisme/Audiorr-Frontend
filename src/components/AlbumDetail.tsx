import { useState, useEffect, useCallback } from 'react'
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
  const [showCoverModal, setShowCoverModal] = useState(false)
  const [coverImageUrl, setCoverImageUrl] = useState<string | null>(null)
  const playerActions = usePlayerActions()
  const playerState = usePlayerState()
  const { isConnected, activeDeviceId, currentDeviceId, remotePlaybackState, sendRemoteCommand } = useConnect()
  const { menu, handleContextMenu, closeContextMenu } = useContextMenu()

  const dominantColors = useDominantColors(coverImageUrl)

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
    <div>
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
            <div className="mt-4 flex flex-wrap items-center justify-center md:justify-start gap-x-2 md:gap-x-3 gap-y-1 text-xs md:text-base text-[var(--hero-text-muted)]">
              {formatDate(albumInfo.originalReleaseDate) && (
                <>
                  <span className="whitespace-nowrap">{formatDate(albumInfo.originalReleaseDate)}</span>
                  {albumInfo.genre && <span className="text-[var(--hero-text-dim)] text-[10px] mx-0.5">•</span>}
                </>
              )}
                <div className="flex items-center flex-wrap justify-center md:justify-start gap-x-1.5">
                  {albumInfo.genre?.split(',').map((g, idx, arr) => (
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
          showCover={false}
          useTrackNumber={true}
          accentColor={dominantColors?.accent}
        />

        {albumInfo.recordLabels && albumInfo.recordLabels.length > 0 && (
          <div className="mt-4 pt-2 text-xs text-gray-400 dark:text-gray-500">
            © {albumInfo.originalReleaseDate?.year || albumInfo.year || new Date().getFullYear()}{' '}
            {albumInfo.recordLabels.map(label => label.name).join(', ')}
          </div>
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
