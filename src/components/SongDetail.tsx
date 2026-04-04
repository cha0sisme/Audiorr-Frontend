import { useState, useEffect, useCallback } from 'react'
import { useParams, Link } from 'react-router-dom'
import { navidromeApi, Song } from '../services/navidromeApi'
import { usePlayerActions, usePlayerState } from '../contexts/PlayerContext'
import PageHero from './PageHero'
import { ArtistLinks } from './ArtistLinks'
import Spinner from './Spinner'
import AlbumCoverModal from './AlbumCoverModal'
import { useDominantColors } from '../hooks/useDominantColors'
import { useConnect } from '../hooks/useConnect'
import { SongTable } from './SongTable'

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
    return (
      <div className="flex justify-center items-center h-64">
        <Spinner size="lg" />
      </div>
    )
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
    <div>
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
            <div className="mt-5 flex flex-wrap items-center gap-x-2 gap-y-1 text-lg md:text-xl text-white/90">
              <ArtistLinks
                artists={song.artist}
                className="hover:text-white transition-colors inline-block font-semibold"
              />
              <span className="text-white/40">•</span>
              <Link
                to={`/albums/${song.albumId}`}
                className="hover:text-white transition-colors font-semibold"
              >
                {song.album}
              </Link>
            </div>
            <div className="mt-4 flex flex-wrap items-center justify-center md:justify-start gap-x-1.5 gap-y-1 text-xs md:text-base text-white/80">
              {getReleaseTypeLabel(albumInfo?.mbReleaseType) && (
                <>
                  <span className="whitespace-nowrap">{getReleaseTypeLabel(albumInfo?.mbReleaseType)}</span>
                  <span className="text-white/30 text-[10px] mx-0.5">•</span>
                </>
              )}
              {formatDate(albumInfo?.originalReleaseDate) && (
                <>
                  <span className="whitespace-nowrap">{formatDate(albumInfo?.originalReleaseDate)}</span>
                  {song.genre && <span className="text-white/30 text-[10px] mx-0.5">•</span>}
                </>
              )}
              {song.genre && (
                <div className="flex items-center flex-wrap justify-center md:justify-start gap-x-1.5">
                  {song.genre.split(',').map((g, idx, arr) => (
                    <span key={g.trim()} className="flex items-center gap-x-1.5">
                      <Link
                        to={`/genre/${encodeURIComponent(g.trim())}`}
                        className="text-white/80 hover:text-white hover:underline transition-colors cursor-pointer whitespace-nowrap"
                      >
                        {g.trim()}
                      </Link>
                      {idx < arr.length - 1 && <span className="text-white/30 text-[10px] mx-0.5">•</span>}
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
        />

        {albumInfo?.recordLabels && albumInfo.recordLabels.length > 0 && (
          <div className="mt-6 pt-2 text-xs text-gray-400 dark:text-gray-500">
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
          <h2 className="text-2xl font-bold text-gray-900 dark:text-white mb-6">
            Canciones Similares
          </h2>
          {loadingSimilar && (
            <div className="flex justify-center py-8">
              <Spinner />
            </div>
          )}
          {!loadingSimilar && similarSongs.length === 0 && (
            <p className="text-center py-8 text-gray-500 dark:text-gray-400">
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
