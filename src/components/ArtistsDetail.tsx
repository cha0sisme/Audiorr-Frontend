import { useState, useEffect, memo, useCallback, useRef } from 'react'
import { useParams, Link } from 'react-router-dom'
import { navidromeApi, Album, Song, Playlist, ArtistInfo } from '../services/navidromeApi'
import { usePlayerActions, usePlayerState } from '../contexts/PlayerContext'
import { useDominantColors } from '../hooks/useDominantColors'

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


import { useContextMenu } from '../hooks/useContextMenu'
import { useConnect } from '../hooks/useConnect'
import { getArtistAvatarCache } from '../utils/artistAvatarCache'
import SongContextMenu from './SongContextMenu'
import HorizontalScrollSection from './HorizontalScrollSection'
import AlbumCard from './AlbumCard'
import AlbumCoverModal from './AlbumCoverModal'
import { SongTable } from './SongTable'
import UniversalCover from './UniversalCover'
import { PlaylistCover } from './PlaylistCover'
import PageHero from './PageHero'

const ArtistPlaylistItem = memo(({ playlist, immersive = false }: { playlist: Playlist; immersive?: boolean }) => {
  const isEditorial = playlist.comment?.includes('[Editorial]')
  const isSpotify = playlist.name.startsWith('[Spotify] ') || playlist.comment?.includes('Spotify Synced')

  return (
    <Link
      to={`/playlists/${playlist.id}`}
      state={{ playlist }}
      className={`group rounded-2xl border overflow-hidden transition-all duration-300 relative block ${immersive ? 'bg-white/[0.08] border-white/10 hover:bg-white/[0.13]' : 'bg-gray-50 dark:bg-white/[0.04] border-gray-200/50 dark:border-white/[0.06] hover:bg-white dark:hover:bg-white/[0.07]'}`}
    >
      <div className="relative aspect-square active:scale-95 transition-transform duration-150">
        <PlaylistCover
          playlistId={playlist.id}
          name={playlist.name}
          className="w-full h-full object-cover"
          rounded={false}
          fallbackUrl={navidromeApi.getCoverUrl(playlist.coverArt)}
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
             <div className="bg-white/90 dark:bg-black/70 backdrop-blur-sm p-1 rounded-full shadow-lg flex items-center justify-center" title="Hecho por Audiorr">
               <img src="/assets/logo-icon.svg" alt="Audiorr" className="w-3 h-3 object-contain brightness-0 dark:invert" />
             </div>
          )}
        </div>
      </div>
      <div className="p-3">
        <h3
          className={`font-sans font-bold text-sm truncate group-hover:text-blue-400 transition-colors ${immersive ? 'text-white' : 'text-gray-900 dark:text-gray-100'}`}
          title={playlist.name.replace('[Spotify] ', '')}
        >
          {playlist.name.replace('[Spotify] ', '')}
        </h3>
        <p className={`font-sans text-[10px] uppercase tracking-wider font-medium mt-1 ${immersive ? 'text-white/50' : 'text-gray-500 dark:text-gray-400'}`}>
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
  const [colorSourceUrl, setColorSourceUrl] = useState<string | null>(() => {
    // ArtistAvatar keeps a memory LRU cache — if we came from a page that already
    // rendered this artist's avatar, the URL is available synchronously.
    if (!name) return null
    const decoded = decodeURIComponent(name).toLowerCase().trim()
    return getArtistAvatarCache().get(decoded) || null
  })
  const [showAvatarModal, setShowAvatarModal] = useState(false)
  const [loading, setLoading] = useState(true)
  const [playlistsLoading, setPlaylistsLoading] = useState(true)
  const [showAllSongs, setShowAllSongs] = useState(false)
  const [showAllAlbums, setShowAllAlbums] = useState(false)
  const [artistInfoLoading, setArtistInfoLoading] = useState(true)

  const playerActions = usePlayerActions()
  const playerState = usePlayerState()
  const { isConnected, activeDeviceId, currentDeviceId, remotePlaybackState, sendRemoteCommand } = useConnect()
  const { menu, handleContextMenu, closeContextMenu } = useContextMenu()

  const dominantColors = useDominantColors(colorSourceUrl)

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


  useEffect(() => {
    const fetchCriticalData = async () => {
      if (!name) return

      setLoading(true)
      setArtistInfo(null)
      setArtistInfoLoading(true)
      setAlbums([])
      setSongs([])
      setCollaborations([])
      setPlaylists([])
      setArtistImage(null)
      // Re-seed from LRU cache for the new artist (may be null if not yet visited)
      const decoded = decodeURIComponent(name).toLowerCase().trim()
      setColorSourceUrl(getArtistAvatarCache().get(decoded) || null)

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
            setArtistInfoLoading(false)
          }).catch(() => setArtistInfoLoading(false))
        } else {
          setArtistInfoLoading(false)
        }
      }).catch(() => setArtistInfoLoading(false))

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
    <div ref={rootRef} style={pageBgColor ? { ['--bg-base' as string]: pageBgColor } : undefined}>
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
        onImageLoaded={(url) => { setArtistImage(url); setColorSourceUrl(url) }}
        widePlayButton
        metadata={
          <div className="mt-5 flex flex-wrap items-center gap-x-1 gap-y-1 text-sm md:text-base text-[var(--hero-text-muted)]">
            {albums.length > 0 && (
              <>
                <span className="font-semibold">
                  {albums.length} {albums.length === 1 ? 'álbum' : 'álbumes'}
                </span>
                <span className="text-[var(--hero-text-dim)] text-[8px]">·</span>
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
          <section className="animate-pulse space-y-8">
            {/* Songs skeleton */}
            <div>
              <div className="h-7 w-28 rounded-lg mb-4 bg-gray-200 dark:bg-white/10" />
              <div className="overflow-hidden rounded-none md:rounded-2xl border-y md:border border-gray-200/80 bg-white dark:border-white/5 dark:bg-gray-900/40 -mx-5 md:mx-0 divide-y divide-gray-100/80 dark:divide-white/[0.04]">
                {['w-2/3','w-1/2','w-3/4','w-2/5','w-3/5'].map((w, i) => (
                  <div key={i} className="grid grid-cols-[2rem,1fr,auto] items-center gap-2 md:gap-3 px-3 md:px-4 py-2">
                    <div className="h-3 w-3 rounded-full mx-auto bg-gray-200 dark:bg-white/10" />
                    <div className="flex items-center gap-3 min-w-0">
                      <div className="w-10 h-10 rounded-md flex-shrink-0 bg-gray-200 dark:bg-white/10" />
                      <div className="space-y-1.5 min-w-0 flex-1">
                        <div className={`h-4 ${w} rounded-full bg-gray-200 dark:bg-white/10`} />
                        <div className="h-3 w-1/3 rounded-full bg-gray-100 dark:bg-white/[0.06]" />
                      </div>
                    </div>
                    <div className="h-3 w-8 rounded-full bg-gray-100 dark:bg-white/[0.06]" />
                  </div>
                ))}
              </div>
            </div>
            {/* Albums skeleton */}
            <div>
              <div className="h-7 w-24 rounded-lg mb-6 bg-gray-200 dark:bg-white/10" />
              <div className="flex gap-4 overflow-hidden">
                {Array.from({ length: 6 }).map((_, i) => (
                  <div key={i} className="flex-shrink-0 w-36 md:w-44 space-y-2">
                    <div className="w-full aspect-square rounded-xl bg-gray-200 dark:bg-white/10" />
                    <div className="h-3.5 w-3/4 rounded-full bg-gray-200 dark:bg-white/10" />
                    <div className="h-3 w-1/2 rounded-full bg-gray-100 dark:bg-white/[0.06]" />
                  </div>
                ))}
              </div>
            </div>
          </section>
        ) : songs.length > 0 && (
          <section>
            <div className="flex items-center justify-between mb-4">
              <h2 className={`text-2xl font-bold ${pageBgColor ? (solidOnLight ? 'text-gray-900' : 'text-white') : 'text-gray-900 dark:text-white'}`}>Populares</h2>
              {songs.length > 5 && (
                <button
                  onClick={() => setShowAllSongs(!showAllSongs)}
                  className={`text-sm font-semibold transition-colors ${pageBgColor ? (solidOnLight ? 'text-gray-500 hover:text-gray-800' : 'text-white/50 hover:text-white/90') : 'text-gray-500 hover:text-gray-800 dark:text-white/50 dark:hover:text-white/90'}`}
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
              showArtist={false}
              showCover={true}
              accentColor={dominantColors?.accent}
              immersive={pageBgColor ? (solidOnLight ? 'light' : true) : false}
            />
          </section>
        )}

        {albums.length > 0 && (
          <section>
            <div className="flex items-center justify-between mb-6">
              <h2 className={`text-2xl font-bold ${pageBgColor ? (solidOnLight ? 'text-gray-900' : 'text-white') : 'text-gray-900 dark:text-white'}`}>Álbumes</h2>
              <button
                onClick={() => setShowAllAlbums(!showAllAlbums)}
                className={`text-sm font-semibold transition-colors ${pageBgColor ? (solidOnLight ? 'text-gray-500 hover:text-gray-800' : 'text-white/50 hover:text-white/90') : 'text-gray-500 hover:text-gray-800 dark:text-white/50 dark:hover:text-white/90'}`}
              >
                {showAllAlbums ? 'Ver menos' : 'Ver más'}
              </button>
            </div>

            {!showAllAlbums ? (
              <HorizontalScrollSection>
                {albums.map(album => (
                  <div key={album.id} className="flex-shrink-0 w-36 md:w-44">
                    <AlbumCard album={album} showPlayButton={true} immersive={!!pageBgColor && !solidOnLight} />
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
            <h2 className={`text-2xl font-bold mb-6 ${pageBgColor ? (solidOnLight ? 'text-gray-900' : 'text-white') : 'text-gray-900 dark:text-white'}`}>Aparece en</h2>
            <HorizontalScrollSection>
              {collaborations.map(album => (
                <div key={album.id} className="flex-shrink-0 w-36 md:w-44">
                  <AlbumCard album={album} showPlayButton={true} immersive={!!pageBgColor && !solidOnLight} />
                </div>
              ))}
            </HorizontalScrollSection>
          </section>
        )}

        {!playlistsLoading && playlists.length > 0 && (
          <section>
            <HorizontalScrollSection title={`Playlists con ${decodedName}`} immersive={!!pageBgColor && !solidOnLight}>
              {playlists.map(playlist => (
                <div key={playlist.id} className="flex-shrink-0 w-36 md:w-44">
                  <ArtistPlaylistItem playlist={playlist} immersive={!!pageBgColor && !solidOnLight} />
                </div>
              ))}
            </HorizontalScrollSection>
          </section>
        )}

        {!loading && artistInfoLoading && (
          <section>
            <HorizontalScrollSection title="Fans también escuchan" immersive={!!pageBgColor && !solidOnLight}>
              {Array.from({ length: 6 }).map((_, i) => (
                <div key={i} className="flex-shrink-0 w-32 text-center">
                  <div className={`w-32 h-32 mx-auto mb-3 rounded-full animate-pulse ${pageBgColor ? (solidOnLight ? 'bg-black/10' : 'bg-white/10') : 'bg-gray-200 dark:bg-white/[0.08]'}`} />
                  <div className={`h-3 w-20 mx-auto rounded-full animate-pulse ${pageBgColor ? (solidOnLight ? 'bg-black/10' : 'bg-white/10') : 'bg-gray-200 dark:bg-white/[0.08]'}`} />
                </div>
              ))}
            </HorizontalScrollSection>
          </section>
        )}

        {!artistInfoLoading && artistInfo && artistInfo.similarArtists.length > 0 && (
          <section>
            <HorizontalScrollSection title="Fans también escuchan" immersive={!!pageBgColor && !solidOnLight}>
              {artistInfo.similarArtists.slice(0, 15).map(artist => (
                <Link
                  key={artist.id}
                  to={`/artists/${encodeURIComponent(artist.name)}`}
                  className="flex-shrink-0 w-32 text-center group"
                  onPointerDown={() => { navidromeApi.getArtistAlbums(artist.name).catch(() => {}); navidromeApi.getArtistSongs(artist.name, 10).catch(() => {}) }}
                >
                  <div className="w-32 h-32 mx-auto mb-3 active:scale-95 transition-transform duration-150">
                    <UniversalCover type="artist" artistName={artist.name} context="grid" />
                  </div>
                  <p className={`font-bold truncate group-hover:text-blue-400 transition-colors text-sm ${pageBgColor ? (solidOnLight ? 'text-gray-900' : 'text-white') : 'text-gray-900 dark:text-gray-100'}`}>
                    {artist.name}
                  </p>
                </Link>
              ))}
            </HorizontalScrollSection>
          </section>
        )}

        {!loading && artistInfoLoading && (
          <section className={`mt-12 rounded-3xl p-6 md:p-10 ${pageBgColor ? (solidOnLight ? 'bg-black/[0.05] border border-black/10' : 'bg-white/[0.08] border border-white/10') : 'bg-gray-50 dark:bg-white/[0.05] border border-gray-200/50 dark:border-white/[0.08]'}`}>
            <div className={`h-7 w-40 rounded-lg mb-6 animate-pulse ${pageBgColor ? (solidOnLight ? 'bg-black/10' : 'bg-white/10') : 'bg-gray-200 dark:bg-white/[0.08]'}`} />
            <div className="space-y-3">
              <div className={`h-4 rounded-full animate-pulse ${pageBgColor ? (solidOnLight ? 'bg-black/10' : 'bg-white/10') : 'bg-gray-200 dark:bg-white/[0.08]'}`} />
              <div className={`h-4 w-5/6 rounded-full animate-pulse ${pageBgColor ? (solidOnLight ? 'bg-black/10' : 'bg-white/10') : 'bg-gray-200 dark:bg-white/[0.08]'}`} />
              <div className={`h-4 w-4/6 rounded-full animate-pulse ${pageBgColor ? (solidOnLight ? 'bg-black/10' : 'bg-white/10') : 'bg-gray-200 dark:bg-white/[0.08]'}`} />
              <div className={`h-4 rounded-full animate-pulse ${pageBgColor ? (solidOnLight ? 'bg-black/10' : 'bg-white/10') : 'bg-gray-200 dark:bg-white/[0.08]'}`} />
              <div className={`h-4 w-3/4 rounded-full animate-pulse ${pageBgColor ? (solidOnLight ? 'bg-black/10' : 'bg-white/10') : 'bg-gray-200 dark:bg-white/[0.08]'}`} />
            </div>
          </section>
        )}

        {!artistInfoLoading && artistInfo?.biography && (
          <section className={`mt-12 rounded-3xl p-6 md:p-10 transition-all duration-500 ${pageBgColor ? (solidOnLight ? 'bg-black/[0.05] border border-black/10' : 'bg-white/[0.08] border border-white/10') : 'bg-gray-50 dark:bg-white/[0.05] border border-gray-200/50 dark:border-white/[0.08]'}`}>
            <h2 className={`text-2xl font-extrabold mb-6 ${pageBgColor ? (solidOnLight ? 'text-gray-900' : 'text-white') : 'text-gray-900 dark:text-white'}`}>
              Acerca de {decodedName}
            </h2>
            <div
              className={`prose prose-sm md:prose-base max-w-none leading-relaxed font-normal ${pageBgColor ? (solidOnLight ? 'text-gray-700' : 'prose-invert text-white/70') : 'dark:prose-invert text-gray-600 dark:text-gray-300'}`}
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
