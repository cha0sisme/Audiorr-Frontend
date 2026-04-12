import { memo } from 'react'
import { Link } from 'react-router-dom'
import { Song } from '../services/navidromeApi'
import AlbumCover from './AlbumCover'
import EqualizerIcon from './EqualizerIcon'
import { ArtistLinks } from './ArtistLinks'

// True if the device has a touch screen (iOS/Android native or mobile browser)
const isTouchDevice = typeof window !== 'undefined' && ('ontouchstart' in window || navigator.maxTouchPoints > 0)

function hexToRgba(hex: string, alpha: number): string {
  if (!hex || !hex.startsWith('#') || hex.length < 7) return `rgba(59,130,246,${alpha})`
  const r = parseInt(hex.slice(1, 3), 16)
  const g = parseInt(hex.slice(3, 5), 16)
  const b = parseInt(hex.slice(5, 7), 16)
  return `rgba(${r},${g},${b},${alpha})`
}

/**
 * Scales the accent color's brightness so it falls in the range [MIN, MAX].
 * - normal mode: cap upper bound so it's readable on light theme bg
 * - immersive dark: only enforce lower bound so accent stays bright on white text
 * - immersive 'light': cap upper bound so accent is dark enough on a light page bg
 */
function ensureAccentContrast(hex: string, immersive: boolean | 'light' = false): string {
  if (!hex || !hex.startsWith('#') || hex.length < 7) return hex
  const r = parseInt(hex.slice(1, 3), 16)
  const g = parseInt(hex.slice(3, 5), 16)
  const b = parseInt(hex.slice(5, 7), 16)
  const lum = r * 0.299 + g * 0.587 + b * 0.114

  const isLight = immersive === 'light'
  const MIN = isLight ? 0 : (immersive ? 130 : 110)
  const MAX = isLight ? 145 : (immersive ? 255 : 190)
  if (lum >= MIN && lum <= MAX) return hex

  const factor = (lum < MIN ? MIN : MAX) / Math.max(lum, 1)
  const clamp = (v: number) => Math.min(255, Math.max(0, Math.round(v * factor)))
  const nr = clamp(r), ng = clamp(g), nb = clamp(b)
  const newLum = nr * 0.299 + ng * 0.587 + nb * 0.114
  if (newLum < MIN || newLum > MAX) return lum < MIN ? (isLight ? '#333333' : (immersive ? '#cccccc' : '#aaaaaa')) : '#555555'
  return `#${nr.toString(16).padStart(2, '0')}${ng.toString(16).padStart(2, '0')}${nb.toString(16).padStart(2, '0')}`
}

export interface SongTableProps {
  songs: Song[]
  currentSongId?: string | null
  isPlaying?: boolean
  isAnalyzing?: boolean
  analysisCurrentSongId?: string | null
  onSongDoubleClick: (song: Song, index: number) => void
  onSongContextMenu: (e: React.MouseEvent, song: Song) => void
  showAlbum?: boolean
  showCover?: boolean
  showArtist?: boolean
  showIndex?: boolean
  useTrackNumber?: boolean
  accentColor?: string
  /** Immersive mode: transparent bg + themed text. Used when the page has a
   *  full-bleed album-color background (Apple Music style).
   *  - `true`    = dark page bg → white text
   *  - `'light'` = light page bg (white/yellow solid) → dark text */
  immersive?: boolean | 'light'
  className?: string
}

function getGridTemplate(showIndex: boolean, showAlbum: boolean) {
  if (showIndex) {
    return showAlbum
      ? 'grid-cols-[2rem,1fr,auto] md:grid-cols-[2rem,1.8fr,1.2fr,2.5rem]'
      : 'grid-cols-[2rem,1fr,auto] md:grid-cols-[2rem,1fr,2.5rem]'
  }
  return showAlbum
    ? 'grid-cols-[1fr,auto] md:grid-cols-[1.8fr,1.2fr,2.5rem]'
    : 'grid-cols-[1fr,auto] md:grid-cols-[1fr,2.5rem]'
}

const SongRow = memo(({
  song,
  index,
  isPlaying,
  isAnalyzingSong,
  onDoubleClick,
  onContextMenu,
  showAlbum = true,
  showCover = true,
  showArtist = true,
  showIndex = true,
  useTrackNumber = false,
  accentColor,
  immersive = false,
}: {
  song: Song
  index: number
  isPlaying: boolean
  isAnalyzingSong: boolean
  onDoubleClick: (song: Song, index: number) => void
  onContextMenu: (e: React.MouseEvent, song: Song) => void
  showAlbum?: boolean
  showCover?: boolean
  showArtist?: boolean
  showIndex?: boolean
  useTrackNumber?: boolean
  accentColor?: string
  immersive?: boolean | 'light'
}) => {
  const gridTemplate = getGridTemplate(showIndex, showAlbum)
  const handlePlay = () => onDoubleClick(song, index)

  const isLight = immersive === 'light'
  const isImmersive = !!immersive

  const safeAccent = accentColor ? ensureAccentContrast(accentColor, immersive) : undefined

  // Row background for the playing song
  const playingRowStyle = isPlaying
    ? (accentColor
        ? { backgroundColor: hexToRgba(accentColor, isLight ? 0.18 : isImmersive ? 0.30 : 0.28) }
        : undefined)
    : undefined

  // Row hover/active classes
  const rowStateClass = isPlaying
    ? (safeAccent
        ? 'hover:brightness-110 active:brightness-125'
        : isLight
          ? 'bg-black/10 hover:bg-black/15 active:bg-black/20'
          : isImmersive
            ? 'bg-white/15 hover:bg-white/20 active:bg-white/30'
            : 'bg-blue-500/15 hover:bg-blue-500/10 active:bg-blue-500/25 dark:bg-blue-500/25 dark:hover:bg-blue-500/20 dark:active:bg-blue-500/40')
    : (isLight
        ? 'hover:bg-black/[0.06] active:bg-black/10'
        : isImmersive
          ? 'hover:bg-white/8 active:bg-white/15'
          : 'hover:bg-gray-100/80 active:bg-gray-200 dark:hover:bg-white/5 dark:active:bg-white/15')

  // Text colors
  const indexTextClass = isLight
    ? 'text-gray-400'
    : isImmersive
      ? 'text-white/45'
      : 'text-gray-400 dark:text-gray-500'

  const titleClass = isLight
    ? (isPlaying && safeAccent ? '' : 'text-gray-900')
    : isImmersive
      ? (isPlaying && safeAccent ? '' : 'text-white')
      : (isPlaying && !safeAccent ? 'text-blue-600 dark:text-blue-400' : 'text-gray-900 dark:text-gray-100')

  const artistClass = isLight
    ? (isPlaying && !accentColor ? 'text-gray-700 hover:text-gray-900' : 'text-gray-500 hover:text-gray-700')
    : isImmersive
      ? (isPlaying && !accentColor ? 'text-white/80 hover:text-white' : 'text-white/55 hover:text-white/80')
      : (isPlaying && !accentColor
          ? 'text-blue-500/80 hover:text-blue-500 dark:text-blue-400/80 dark:hover:text-blue-400'
          : 'text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200')

  const durationClass = isLight ? 'text-gray-400' : isImmersive ? 'text-white/45' : 'text-gray-400 dark:text-gray-500'

  const albumLinkClass = isLight
    ? 'truncate text-sm text-gray-500 hover:text-gray-800'
    : isImmersive
      ? 'truncate text-sm text-white/55 hover:text-white/80'
      : 'truncate text-sm text-gray-500 hover:text-gray-800 dark:text-gray-400 dark:hover:text-gray-200'

  const albumSpanClass = isLight
    ? 'truncate text-sm text-gray-400'
    : isImmersive
      ? 'truncate text-sm text-white/45'
      : 'truncate text-sm text-gray-500 dark:text-gray-400'

  const dotsClass = isLight
    ? 'md:hidden flex items-center justify-center w-7 h-7 -mr-1 rounded-full text-gray-400 hover:text-gray-600 active:bg-black/10 touch-manipulation transition-colors'
    : isImmersive
      ? 'md:hidden flex items-center justify-center w-7 h-7 -mr-1 rounded-full text-white/45 hover:text-white/70 active:bg-white/10 touch-manipulation transition-colors'
      : 'md:hidden flex items-center justify-center w-7 h-7 -mr-1 rounded-full text-gray-400 dark:text-gray-500 hover:text-gray-600 dark:hover:text-gray-300 active:bg-gray-200/70 dark:active:bg-white/10 touch-manipulation transition-colors'

  return (
    <div
      className={`grid items-center gap-2 md:gap-3 px-3 md:px-4 py-2 text-sm transition-colors duration-75 cursor-pointer select-none ${gridTemplate} ${rowStateClass}`}
      style={playingRowStyle}
      onClick={isTouchDevice ? handlePlay : undefined}
      onDoubleClick={!isTouchDevice ? handlePlay : undefined}
      onContextMenu={e => onContextMenu(e, song)}
    >
      {/* # / index / track / equalizer */}
      {showIndex && (
        <div className={`flex items-center justify-center text-xs md:text-sm font-medium tabular-nums ${indexTextClass}`}>
          {isPlaying ? (
            <EqualizerIcon
              isPlaying={true}
              colorClass={safeAccent ? undefined : (isLight ? 'fill-gray-600' : isImmersive ? 'fill-white/70' : 'fill-blue-500 dark:fill-blue-400')}
              color={safeAccent}
              className="w-3.5 h-3.5 md:w-4 md:h-4"
            />
          ) : isAnalyzingSong ? (
            <div className="h-3.5 w-3.5 md:h-4 md:w-4 animate-spin rounded-full border-2 border-blue-500 border-t-transparent" />
          ) : (
            useTrackNumber ? (song.track || index + 1) : (index + 1)
          )}
        </div>
      )}

      {/* Row content (Cover + Title + Artist) */}
      <div className="flex items-center gap-3 min-w-0">
        {showCover && (
          <div className="h-10 w-10 md:h-12 md:w-12 flex-shrink-0 overflow-hidden rounded-md shadow-sm">
            <AlbumCover coverArtId={song.coverArt} size={200} alt={song.album} className="h-full w-full object-cover" />
          </div>
        )}
        <div className="min-w-0">
          <p
            className={`truncate text-base md:text-[17px] font-semibold leading-tight ${titleClass}`}
            style={isPlaying && safeAccent ? { color: safeAccent } : undefined}
          >
            {song.title}
          </p>
          {showArtist && (
            <div className="flex items-center gap-1 mt-0.5">
              <ArtistLinks artists={song.artist} className={`text-sm leading-tight ${artistClass}`} />
            </div>
          )}
        </div>
      </div>

      {/* Album (hidden on mobile) */}
      {showAlbum && (
        <div className="hidden md:flex items-center min-w-0">
          {song.albumId ? (
            <Link to={`/albums/${song.albumId}`} className={albumLinkClass} onClick={(e) => e.stopPropagation()}>
              {song.album || 'Sin álbum'}
            </Link>
          ) : (
            <span className={albumSpanClass}>{song.album || 'Sin álbum'}</span>
          )}
        </div>
      )}

      {/* Duration + three-dots (mobile) */}
      <div className={`flex items-center justify-end gap-1.5 text-sm tabular-nums ${durationClass}`}>
        {`${Math.floor(song.duration / 60)}:${String(song.duration % 60).padStart(2, '0')}`}
        <button
          className={dotsClass}
          aria-label="Más opciones"
          onClick={e => { e.stopPropagation(); onContextMenu(e, song) }}
        >
          <svg className="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
            <circle cx="5" cy="12" r="1.75" />
            <circle cx="12" cy="12" r="1.75" />
            <circle cx="19" cy="12" r="1.75" />
          </svg>
        </button>
      </div>
    </div>
  )
}, (prev, next) => {
  return (
    prev.song.id === next.song.id &&
    prev.isPlaying === next.isPlaying &&
    prev.isAnalyzingSong === next.isAnalyzingSong &&
    prev.index === next.index &&
    prev.showAlbum === next.showAlbum &&
    prev.showCover === next.showCover &&
    prev.showArtist === next.showArtist &&
    prev.showIndex === next.showIndex &&
    prev.useTrackNumber === next.useTrackNumber &&
    prev.accentColor === next.accentColor &&
    prev.immersive === next.immersive
  )
})

SongRow.displayName = 'SongRow'

export function SongTable({
  songs,
  currentSongId,
  isPlaying = false,
  isAnalyzing = false,
  analysisCurrentSongId,
  onSongDoubleClick,
  onSongContextMenu,
  showAlbum = true,
  showCover = true,
  showArtist = true,
  showIndex = true,
  useTrackNumber = false,
  accentColor,
  immersive = false,
  className = "",
}: SongTableProps) {
  const containerClass = immersive === 'light'
    // Light immersive: transparent with dark borders
    ? `overflow-hidden rounded-none md:rounded-2xl border-y md:border border-black/10 -mx-5 md:mx-0 ${className}`
    : immersive
      // Dark immersive: transparent with white borders
      ? `overflow-hidden rounded-none md:rounded-2xl border-y md:border border-white/10 -mx-5 md:mx-0 ${className}`
      : `overflow-hidden rounded-none md:rounded-2xl border-y md:border border-gray-200/80 bg-white shadow-sm dark:border-white/5 dark:bg-gray-900/40 -mx-5 md:mx-0 ${className}`

  const dividerClass = immersive === 'light'
    ? 'divide-y divide-black/[0.06]'
    : immersive
      ? 'divide-y divide-white/[0.08]'
      : 'divide-y divide-gray-100/80 dark:divide-white/[0.04]'

  return (
    <div className={containerClass}>
      <div className={dividerClass}>
        {songs.map((song, index) => (
          <SongRow
            key={song.id}
            song={song}
            index={index}
            isPlaying={isPlaying && currentSongId === song.id}
            isAnalyzingSong={isAnalyzing && analysisCurrentSongId === song.id}
            onDoubleClick={onSongDoubleClick}
            onContextMenu={onSongContextMenu}
            showAlbum={showAlbum}
            showCover={showCover}
            showArtist={showArtist}
            showIndex={showIndex}
            useTrackNumber={useTrackNumber}
            accentColor={accentColor}
            immersive={immersive}
          />
        ))}
      </div>
    </div>
  )
}
