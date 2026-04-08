import { useState, useEffect, useMemo, memo, useCallback } from 'react'
import { useParams, Link } from 'react-router-dom'
import { navidromeApi, Album, Song, Playlist, ArtistInfo } from '../services/navidromeApi'
import { usePlayerActions, usePlayerState } from '../contexts/PlayerContext'
import { useDominantColors } from '../hooks/useDominantColors'
import { useContextMenu } from '../hooks/useContextMenu'
import { useConnect } from '../hooks/useConnect'
import SongContextMenu from './SongContextMenu'
import HorizontalScrollSection from './HorizontalScrollSection'
import AlbumCard from './AlbumCard'
import AlbumCoverModal from './AlbumCoverModal'
import { SongTable } from './SongTable'
import UniversalCover from './UniversalCover'
import { PlaylistCover } from './PlaylistCover'
import PageHero from './PageHero'

const ArtistPlaylistItem = memo(({ playlist }: { playlist: Playlist }) => {
  const isEditorial = playlist.comment?.includes('[Editorial]')
  const isSpotify = playlist.name.startsWith('[Spotify] ') || playlist.comment?.includes('Spotify Synced')
  
  return (
    <Link
      to={`/playlists/${playlist.id}`}
      state={{ playlist }}
      className="group bg-gray-50 dark:bg-gray-800/40 rounded-2xl border border-gray-200/50 dark:border-white/5 overflow-hidden hover:bg-white dark:hover:bg-gray-800 transition-all duration-300 relative block"
    >
      <div className="relative aspect-square">
        <PlaylistCover 
          playlistId={playlist.id}
          name={playlist.name}
          className="w-full h-full object-cover"
          rounded={false}
        />
        <div className="absolute top-2 right-2 z-20 flex items-center gap-1.5 opacity-0 group-hover:opacity-100 transition-opacity duration-300">
          {isSpotify && (
             <div className="bg-[#1DB954] text-white p-1 rounded-full shadow-lg" title="Sincronizado con Spotify">
               <svg className="w-3" fill="currentColor" viewBox="0 0 24 24">
                 <path d="M12 0C5.373 0 0 5.373 0 12s5.373 12 12 12 12-5.373 12-12S18.627 0 12 0zm5.492 17.31c-.218.358-.684.47-1.042.252-2.857-1.745-6.45-2.14-10.684-1.173-.41.094-.823-.16-.917-.57-.094-.41.16-.823.57-.917 4.623-1.057 8.583-.61 11.782 1.345.358.218.47.684.252 1.042zm1.464-3.26c-.275.446-.86.592-1.306.317-3.27-2.01-8.254-2.593-12.122-1.417-.5.152-1.026-.134-1.178-.633-.152-.5.134-1.026.633-1.178 4.417-1.34 9.907-.69 13.655 1.614.447.275.592.86.317 1.306zm.126-3.414C15.345 8.35 9.176 8.145 5.62 9.223c-.563.17-1.16-.148-1.332-.71-.17-.563.15-1.16.712-1.332 4.102-1.246 10.92-1.008 15.226 1.55.51.3.67.954.37 1.464-.3.51-.954.67-1.464.37z" />
               </svg>
             </div>
          )}
          {isEditorial && (
             <div className="bg-white/90 dark:bg-gray-800/90 backdrop-blur-sm p-1 rounded-full shadow-lg flex items-center justify-center" title="Hecho por Audiorr">
               <img src="/assets/logo-icon.svg" alt="Audiorr" className="w-3 h-3 object-contain brightness-0 dark:invert" />
             </div>
          )}
        </div>
      </div>
      <div className="p-3">
        <h3
          className="font-sans font-bold text-sm text-gray-900 dark:text-gray-100 truncate group-hover:text-blue-500 transition-colors"
          title={playlist.name.replace('[Spotify] ', '')}
        >
          {playlist.name.replace('[Spotify] ', '')}
        </h3>
        <p className="font-sans text-[10px] uppercase tracking-wider font-medium text-gray-500 dark:text-gray-400 mt-1">
          {playlist.songCount} {playlist.songCount === 1 ? 'canción' : 'canciones'}
        </p>
      </div>
    </Link>
  )
})

ArtistPlaylistItem.displayName = 'ArtistPlaylistItem'

export default function ArtistsDetail() {
  const { name } = useParams<{ name: string }>()
  const [artistInfo, setArtistInfo] = useState<ArtistInfo | null>(null)
  const [albums, setAlbums] = useState<Album[]>([])
  const [collaborations, setCollaborations] = useState<Album[]>([])
  const [songs, setSongs] = useState<Song[]>([])
  const [playlists, setPlaylists] = useState<Playlist[]>([])
  const [artistImage, setArtistImage] = useState<string | null>(null)
  const [showAvatarModal, setShowAvatarModal] = useState(false)
  const [loading, setLoading] = useState(true)
  const [playlistsLoading, setPlaylistsLoading] = useState(true)
  const [showAllSongs, setShowAllSongs] = useState(false)
  const [showAllAlbums, setShowAllAlbums] = useState(false)

  const playerActions = usePlayerActions()
  const playerState = usePlayerState()
  const { isConnected, activeDeviceId, currentDeviceId, remotePlaybackState, sendRemoteCommand } = useConnect()
  const { menu, handleContextMenu, closeContextMenu } = useContextMenu()

  const dominantColors = useDominantColors(artistImage)

  // Lógica de reproducción remota vs local
  const isRemote = isConnected && activeDeviceId && activeDeviceId !== currentDeviceId
  const currentSource = isRemote ? remotePlaybackState?.currentSource : playerState.currentSource
  const isPlaying = isRemote ? remotePlaybackState?.playing : playerState.isPlaying
  
  // Verificar si este artista es el que suena
  const isThisArtistPlaying = currentSource === `artist:${decodeURIComponent(name || '')}`
  const currentSongId = isRemote ? remotePlaybackState?.trackId : playerState.currentSong?.id

  const handleMainPlayClick = useCallback(() => {
    if (isThisArtistPlaying) {
      if (isRemote) {
        sendRemoteCommand(isPlaying ? 'pause' : 'play', null, activeDeviceId!)
      } else {
        playerActions.togglePlayPause()
      }
    } else {
      const decodedArtist = name ? decodeURIComponent(name) : ''
      playerActions.playPlaylist(songs, `artist:${decodedArtist}`)
    }
  }, [isThisArtistPlaying, isRemote, isPlaying, sendRemoteCommand, activeDeviceId, playerActions, songs, name])

  const biographyBgStyle = useMemo(() => {
    if (!dominantColors) return {}
    const { primary, secondary } = dominantColors
    return {
      background: `linear-gradient(140deg, ${primary}05 0%, ${secondary}08 100%)`,
      border: `1px solid ${primary}10`,
    }
  }, [dominantColors])

  useEffect(() => {
    const fetchCriticalData = async () => {
      if (!name) return

      setLoading(true)
      setArtistInfo(null)
      setAlbums([])
      setSongs([])
      setCollaborations([])
      setPlaylists([])
      setArtistImage(null)

      try {
        const decodedName = decodeURIComponent(name)
        const [artistAlbums, artistSongs] = await Promise.all([
          navidromeApi.getArtistAlbums(decodedName),
          navidromeApi.getArtistSongs(decodedName, 10),
        ])
        setAlbums(artistAlbums)
        setSongs(artistSongs)
      } catch (error) {
        console.error('Failed to fetch critical artist data', error)
      } finally {
        setLoading(false)
      }
    }
    fetchCriticalData()
  }, [name])

  useEffect(() => {
    if (!name || loading) return

    const fetchSecondaryData = async () => {
      const decodedName = decodeURIComponent(name)

      navidromeApi.getArtistIdByName(decodedName).then(artistId => {
        if (artistId) {
          navidromeApi.getArtistInfo(artistId).then(info => {
            setArtistInfo(info)
          })
        }
      })

      navidromeApi.getArtistCollaborations(decodedName).then(collabs => {
        setCollaborations(collabs)
      })

      setPlaylistsLoading(true)
      Promise.all([
        navidromeApi.getPlaylistsByArtist(decodedName),
        navidromeApi.getPlaylists()
      ])
        .then(([artistPlaylists, allPlaylists]) => {
          const combined = [...artistPlaylists]
          const thisIsPlaylists = allPlaylists.filter(p => p.name.toLowerCase() === `this is ${decodedName.toLowerCase()}`)
          
          for (const p of thisIsPlaylists) {
            if (!combined.some(existing => existing.id === p.id)) {
              combined.unshift(p)
            }
          }
          const finalPlaylists = combined.filter(p => {
            const nameLower = p.name?.toLowerCase() || ''
            const comment = p.comment || ''
            return (
              !nameLower.includes('mix diario') &&
              !comment.toLowerCase().includes('mix diario') &&
              !comment.includes('Smart Playlist')
            )
          })
          setPlaylists(finalPlaylists)
        })
        .finally(() => {
          setPlaylistsLoading(false)
        })
    }
    fetchSecondaryData()
  }, [name, loading])


  const decodedName = name ? decodeURIComponent(name) : 'Artista'

  if (!name) {
    return <div className="text-center text-red-500">No se encontró el artista.</div>
  }

  const handlePlaySong = (song: Song) => {
    const decodedArtist = name ? decodeURIComponent(name) : ''
    playerActions.playPlaylistFromSong(songs, song, `artist:${decodedArtist}`)
  }

  const totalSongs = albums.reduce((sum, album) => sum + album.songCount, 0)
  const displayedSongs = showAllSongs ? songs : songs.slice(0, 5)

  return (
    <div>
      <PageHero
        type="artist"
        title={decodedName}
        subtitle="Artista"
        coverImageUrl={artistImage}
        dominantColors={dominantColors || null}
        onPlay={handleMainPlayClick}
        isPlaying={!!(isThisArtistPlaying && isPlaying)}
        isRemote={!!isRemote}
        artistName={decodedName}
        onCoverClick={() => artistImage && setShowAvatarModal(true)}
        onImageLoaded={setArtistImage}
        widePlayButton
        metadata={
          <div className="mt-5 flex flex-wrap items-center gap-x-1.5 gap-y-1 text-sm md:text-base text-[var(--hero-text-muted)]">
            {albums.length > 0 && (
              <>
                <span className="font-semibold">
                  {albums.length} {albums.length === 1 ? 'álbum' : 'álbumes'}
                </span>
                <span className="text-[var(--hero-text-dim)] text-[10px] mx-0.5">•</span>
              </>
            )}
            {totalSongs > 0 && (
              <span className="font-semibold">
                {totalSongs} {totalSongs === 1 ? 'canción' : 'canciones'}
              </span>
            )}
          </div>
        }
      />

      <div className="px-5 md:px-8 lg:px-10 space-y-8 mt-6">
        {loading ? (
          <section>
            <div className="flex items-center gap-3 py-6 text-gray-400 dark:text-gray-500">
              <div className="w-5 h-5 border-2 border-current border-t-transparent rounded-full animate-spin flex-shrink-0" />
              <span className="text-sm">Cargando canciones y álbumes...</span>
            </div>
          </section>
        ) : songs.length > 0 && (
          <section>
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-2xl font-bold text-gray-900 dark:text-white">Populares</h2>
              {songs.length > 5 && (
                <button
                  onClick={() => setShowAllSongs(!showAllSongs)}
                  className="text-sm font-semibold text-blue-500 hover:text-blue-600 dark:text-blue-400 dark:hover:text-blue-300 transition-colors"
                >
                  {showAllSongs ? 'Ver menos' : 'Ver más'}
                </button>
              )}
            </div>
            <SongTable
              songs={displayedSongs}
              currentSongId={currentSongId}
              isPlaying={isPlaying}
              onSongDoubleClick={handlePlaySong}
              onSongContextMenu={handleContextMenu}
              showAlbum={false}
              showCover={true}
            />
          </section>
        )}

        {albums.length > 0 && (
          <section>
            <div className="flex items-center justify-between mb-6">
              <h2 className="text-2xl font-bold text-gray-900 dark:text-white">Álbumes</h2>
              <button
                onClick={() => setShowAllAlbums(!showAllAlbums)}
                className="text-sm font-semibold text-blue-500 hover:text-blue-600 dark:text-blue-400 dark:hover:text-blue-300 transition-colors"
              >
                {showAllAlbums ? 'Ver menos' : 'Ver más'}
              </button>
            </div>

            {!showAllAlbums ? (
              <HorizontalScrollSection>
                {albums.map(album => (
                  <div key={album.id} className="flex-shrink-0 w-36 md:w-44">
                    <AlbumCard album={album} showPlayButton={true} />
                  </div>
                ))}
              </HorizontalScrollSection>
            ) : (
              <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-6">
                {albums.map(album => (
                  <AlbumCard key={album.id} album={album} showPlayButton={true} />
                ))}
              </div>
            )}
          </section>
        )}

        {collaborations.length > 0 && (
          <section>
            <h2 className="text-2xl font-bold text-gray-900 dark:text-white mb-6">Aparece en</h2>
            <HorizontalScrollSection>
              {collaborations.map(album => (
                <div key={album.id} className="flex-shrink-0 w-36 md:w-44">
                  <AlbumCard album={album} showPlayButton={true} />
                </div>
              ))}
            </HorizontalScrollSection>
          </section>
        )}

        {!playlistsLoading && playlists.length > 0 && (
          <section>
            <h2 className="text-2xl font-bold text-gray-900 dark:text-white mb-6">Playlists con {decodedName}</h2>
            <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4 md:gap-6">
              {playlists.map(playlist => (
                <ArtistPlaylistItem key={playlist.id} playlist={playlist} />
              ))}
            </div>
          </section>
        )}

        {artistInfo && artistInfo.similarArtists.length > 0 && (
          <section>
            <HorizontalScrollSection title="Fans también escuchan">
              {artistInfo.similarArtists.slice(0, 15).map(artist => (
                <Link
                  key={artist.id}
                  to={`/artists/${encodeURIComponent(artist.name)}`}
                  className="flex-shrink-0 w-32 text-center group"
                >
                  <div className="w-32 h-32 mx-auto mb-3">
                    <UniversalCover type="artist" artistName={artist.name} context="grid" />
                  </div>
                  <p className="font-bold text-gray-900 dark:text-gray-100 truncate group-hover:text-blue-500 transition-colors text-sm">
                    {artist.name}
                  </p>
                </Link>
              ))}
            </HorizontalScrollSection>
          </section>
        )}

        {artistInfo?.biography && (
          <section className="mt-12 rounded-3xl p-6 md:p-10 transition-all duration-500" style={biographyBgStyle}>
            <h2 className="text-2xl font-extrabold text-gray-900 dark:text-white mb-6">
              Acerca de {decodedName}
            </h2>
            <div 
              className="prose prose-sm md:prose-base dark:prose-invert max-w-none text-gray-600 dark:text-gray-300 leading-relaxed font-normal"
              dangerouslySetInnerHTML={{ 
                __html: artistInfo.biography
                  .replace(/<a[^>]*>.*?Read more on Last\.fm.*?<\/a>/gi, '')
                  .replace(/<a[^>]*>.*?/gi, '<span class="text-blue-500 hover:underline cursor-pointer">')
                  .replace(/<\/a>/gi, '</span>')
                  .replace(/Read more on Last\.fm/gi, '') 
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
          showGoToArtist={false}
          isAdmin={navidromeApi.getConfig()?.isAdmin === true}
        />
      )}

      <AlbumCoverModal
        imageUrl={artistImage}
        alt={decodedName}
        isOpen={showAvatarModal}
        onClose={() => setShowAvatarModal(false)}
      />
    </div>
  )
}
