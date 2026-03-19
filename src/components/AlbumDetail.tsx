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
      playerActions.playPlaylist(songs)
    }
  }, [isThisAlbumPlaying, isRemote, isPlaying, sendRemoteCommand, activeDeviceId, playerActions, songs])

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
    playerActions.playPlaylistFromSong(songs, song)
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
    <div className="space-y-8">
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
        metadata={
          <>
            <div className="mt-2 text-center md:text-left">
              <ArtistLinks
                artists={albumInfo.artist}
                className="text-lg md:text-xl text-white/90 hover:text-white transition-colors inline-block font-semibold"
              />
            </div>
            <div className="mt-4 flex flex-wrap items-center justify-center md:justify-start gap-x-2 md:gap-x-3 gap-y-1 text-xs md:text-base text-white/80">
              {formatDate(albumInfo.originalReleaseDate) && (
                <>
                  <span className="whitespace-nowrap">{formatDate(albumInfo.originalReleaseDate)}</span>
                  {albumInfo.genre && <span className="text-white/40">•</span>}
                </>
              )}
              {albumInfo.genre && (
                <div className="flex items-center flex-wrap justify-center md:justify-start gap-2">
                  {albumInfo.genre.split(',').map(g => (
                    <Link
                      key={g}
                      to={`/genre/${encodeURIComponent(g.trim())}`}
                      className="px-3 py-1 bg-white/20 text-white rounded-full text-[10px] md:text-xs font-semibold transition-colors hover:bg-white/30 cursor-pointer whitespace-nowrap"
                    >
                      {g.trim()}
                    </Link>
                  ))}
                </div>
              )}
            </div>
          </>
        }
      />

      <div className="flex flex-wrap items-center gap-3 md:gap-4">
        <button
          onClick={handleMainPlayClick}
          className={`flex h-11 w-11 items-center justify-center rounded-full text-white select-none active:scale-95 transition-transform focus:outline-none ${
            isRemote
              ? 'bg-green-700/80 dark:bg-green-500/20 border border-green-500/40 dark:border-green-500/35'
              : 'bg-gray-700/80 dark:bg-white/[.13] border border-white/20'
          }`}
          style={{
            backdropFilter: 'blur(24px) saturate(1.8)',
            WebkitBackdropFilter: 'blur(24px) saturate(1.8)',
            boxShadow: '0 2px 14px rgba(0,0,0,0.25), inset 0 1px 0 rgba(255,255,255,0.16)',
          }}
          aria-label={isThisAlbumPlaying && isPlaying ? "Pausar álbum" : "Reproducir álbum"}
        >
          {isThisAlbumPlaying && isPlaying ? (
            <svg className="w-7 h-7" fill="currentColor" viewBox="0 0 24 24">
              <path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z" />
            </svg>
          ) : (
            <svg className="w-7 h-7 -translate-x-[1px]" fill="currentColor" viewBox="0 0 24 24">
              <path d="M8 5v14l11-7z" />
            </svg>
          )}
        </button>
      </div>

      <SongTable
        songs={songs}
        currentSongId={currentSongId}
        isPlaying={isPlaying && isThisAlbumPlaying}
        onSongDoubleClick={handlePlaySong}
        onSongContextMenu={handleContextMenu}
        showAlbum={false}
        showCover={false}
        useTrackNumber={true}
      />

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

      {albumInfo.recordLabels && albumInfo.recordLabels.length > 0 && (
        <div className="mt-4 pt-2 text-xs text-gray-400 dark:text-gray-500">
          © {albumInfo.originalReleaseDate?.year || albumInfo.year || new Date().getFullYear()}{' '}
          {albumInfo.recordLabels.map(label => label.name).join(', ')}
        </div>
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
