import { useState, useEffect, useCallback, useRef } from 'react'
import { useParams, Link, useLocation } from 'react-router-dom'
import { Capacitor } from '@capacitor/core'
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
import { useHeroPresence } from '../contexts/HeroPresenceContext'

const isNative = Capacitor.isNativePlatform()

function AlbumDetailSkeleton({ pageBgColor, solidOnLight }: { pageBgColor?: string | null; solidOnLight?: boolean }) {
  const { incHero, decHero } = useHeroPresence()
  useEffect(() => {
    incHero()
    return () => { decHero() }
  }, [incHero, decHero])

  const titleWidths = ['w-2/5', 'w-3/5', 'w-1/2', 'w-4/5', 'w-1/3', 'w-2/3', 'w-3/4', 'w-2/5', 'w-1/2', 'w-3/5', 'w-4/5', 'w-2/3']

  const heroPulse    = pageBgColor ? (solidOnLight ? 'bg-black/[0.12]' : 'bg-white/[0.12]') : 'bg-white/[0.12]'
  const heroPulseMid = pageBgColor ? (solidOnLight ? 'bg-black/[0.18]' : 'bg-white/[0.18]') : 'bg-white/[0.18]'
  const heroPulseAlt = pageBgColor ? (solidOnLight ? 'bg-black/[0.08]' : 'bg-white/20')     : 'bg-white/20'
  const rowPulse     = pageBgColor ? (solidOnLight ? 'bg-black/[0.10]' : 'bg-white/10')      : 'bg-gray-200 dark:bg-white/10'
  const rowPulseAlt  = pageBgColor ? (solidOnLight ? 'bg-black/[0.06]' : 'bg-white/[0.06]') : 'bg-gray-100 dark:bg-white/[0.06]'
  const tableCls     = pageBgColor
    ? (solidOnLight ? 'border-black/10 bg-black/[0.03] divide-black/[0.06]' : 'border-white/5 bg-white/[0.03] divide-white/[0.04]')
    : 'border-gray-200/80 bg-white dark:border-white/5 dark:bg-gray-900/40 divide-gray-100/80 dark:divide-white/[0.04]'

  return (
    <div className="animate-pulse">
      <section
        className={`relative overflow-hidden rounded-none md:rounded-3xl !mt-0 ${!pageBgColor ? 'bg-gray-900 dark:bg-gray-800/70' : ''}`}
        style={{ minHeight: 340, ...(pageBgColor ? { backgroundColor: pageBgColor } : {}) }}
      >
        <div
          className="relative flex flex-col md:flex-row items-center md:items-end gap-3 md:gap-6 px-5 md:px-8 lg:px-10 pt-6 pb-9 md:pb-9"
          style={{ paddingTop: isNative ? 'calc(env(safe-area-inset-top) + 24px)' : '3.5rem' }}
        >
          <div className={`w-48 h-48 md:w-56 md:h-56 flex-shrink-0 rounded-2xl ${heroPulse}`} />
          <div className="flex-1 min-w-0 text-center md:text-left w-full">
            <div className={`h-2 w-12 rounded-full ${heroPulseAlt} mx-auto md:mx-0`} />
            <div className={`mt-2 md:mt-4 h-8 md:h-14 lg:h-16 w-3/5 md:w-2/3 rounded-lg ${heroPulseMid} mx-auto md:mx-0`} />
            <div className={`mt-2 h-5 md:h-6 w-1/3 rounded-full ${heroPulse} mx-auto md:mx-0`} />
            <div className="mt-4 flex flex-wrap items-center gap-x-1 gap-y-1 justify-center md:justify-start">
              <div className={`h-3 md:h-4 w-24 rounded-full ${heroPulseAlt}`} />
              <div className={`h-2 w-0.5 rounded-full ${heroPulseAlt}`} />
              <div className={`h-3 md:h-4 w-16 rounded-full ${heroPulseAlt}`} />
            </div>
            <div className="mt-5 flex justify-center md:justify-start">
              <div className={`h-11 w-36 rounded-full ${heroPulse}`} />
            </div>
          </div>
        </div>
      </section>

      <div className="px-5 md:px-8 lg:px-10 mt-6">
        <div className={`overflow-hidden rounded-none md:rounded-2xl border-y md:border -mx-5 md:mx-0 divide-y ${tableCls}`}>
          {titleWidths.map((w, i) => (
            <div key={i} className="grid grid-cols-[2rem,1fr,2.5rem] items-center gap-2 md:gap-3 px-3 md:px-4 py-[9px]">
              <div className="flex items-center justify-center">
                <div className={`h-3 w-3.5 rounded-full ${rowPulse}`} />
              </div>
              <div className={`h-[17px] ${w} rounded-full ${rowPulse}`} />
              <div className="flex justify-end">
                <div className={`h-3 w-7 rounded-full ${rowPulseAlt}`} />
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}

/** Returns the page background color derived from the album's primary color.
 *  Dark albums: blends 30% primary + 70% near-black (Apple Music dark style).
 *  Light/solid albums (white, yellow…): blends 65% primary + 35% white so the
 *  hue is preserved while keeping a bright, airy feel. */
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


export default function AlbumDetail() {
  const { id } = useParams<{ id: string }>()
  const location = useLocation()
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
  const [colorSourceUrl, setColorSourceUrl] = useState<string | null>(() => {
    // If we navigated here from an album card the thumbnail is already in HTTP
    // cache, so dominant colors resolve before the API call even finishes.
    const stateAlbum = (location.state as { album?: { coverArt?: string } } | null)?.album
    return stateAlbum?.coverArt ? navidromeApi.getCoverUrl(stateAlbum.coverArt, 300) : null
  })
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
            // Use a small thumbnail for color extraction — already in HTTP cache
            // if we navigated here from a page that showed album cards.
            setColorSourceUrl(navidromeApi.getCoverUrl(finalCoverArtId, 300))
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
    <div ref={rootRef} style={pageBgColor ? { ['--bg-base' as string]: pageBgColor } : undefined}>
      {loading ? (
        <AlbumDetailSkeleton pageBgColor={pageBgColor} solidOnLight={solidOnLight} />
      ) : !albumInfo ? (
        <div className="text-center text-red-500">No se pudo cargar la información del álbum.</div>
      ) : (<>
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
          immersive={pageBgColor ? (solidOnLight ? 'light' : true) : false}
        />

        {albumInfo.recordLabels && albumInfo.recordLabels.length > 0 && (
          <div className={`mt-4 pt-2 text-xs ${pageBgColor && solidOnLight ? 'text-gray-500' : 'text-gray-400 dark:text-gray-500'}`}>
            © {albumInfo.originalReleaseDate?.year || albumInfo.year || new Date().getFullYear()}{' '}
            {albumInfo.recordLabels.map(label => label.name).join(', ')}
          </div>
        )}

        {albumNotes && (
          <section className={`mt-12 rounded-3xl p-6 md:p-10 transition-all duration-500 ${
            pageBgColor
              ? (solidOnLight ? 'bg-black/[0.05] border border-black/10' : 'bg-white/[0.08] border border-white/10')
              : 'bg-gray-50 dark:bg-white/[0.05] border border-gray-200/50 dark:border-white/[0.08]'
          }`}>
            <h2
              className={`text-2xl font-extrabold mb-6 ${pageBgColor && dominantColors?.accent ? '' : 'text-gray-900 dark:text-white'}`}
              style={pageBgColor && dominantColors?.accent ? { color: dominantColors.accent } : undefined}
            >
              Acerca de {albumInfo.name}
            </h2>
            <div
              className={`prose prose-sm md:prose-base max-w-none leading-relaxed font-normal ${
                pageBgColor
                  ? (solidOnLight ? 'text-gray-700' : 'prose-invert text-white/70')
                  : 'dark:prose-invert text-gray-600 dark:text-gray-300'
              }`}
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
      </>)}
    </div>
  )
}
