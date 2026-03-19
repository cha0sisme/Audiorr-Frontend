import { Link } from 'react-router-dom'
import { splitArtists } from '../utils/artistUtils'

interface ArtistLinksProps {
  artists: string
  className?: string
  maxArtists?: number // Número máximo de artistas a mostrar antes de truncar
}

/**
 * Componente para renderizar artistas con links separados
 */
export function ArtistLinks({ artists, className = '', maxArtists }: ArtistLinksProps) {
  const artistList = splitArtists(artists)

  if (artistList.length === 0) return null

  if (artistList.length === 1) {
    // Un solo artista, renderizar como link simple
    return (
      <Link
        to={`/artists/${encodeURIComponent(artistList[0])}`}
        onClick={e => e.stopPropagation()}
        className={className}
      >
        {artistList[0]}
      </Link>
    )
  }

  // Determinar cuántos artistas mostrar
  const shouldTruncate = maxArtists !== undefined && artistList.length > maxArtists
  const displayedArtists = shouldTruncate ? artistList.slice(0, maxArtists) : artistList
  const remainingCount = shouldTruncate ? artistList.length - maxArtists : 0

  // Múltiples artistas, renderizar separados por comas
  // Extraer las clases de hover y transición de className para aplicarlas a los links individuales
  const linkClassName = className.replace(/truncate/g, '').trim()

  return (
    <span className={`${className.includes('truncate') ? 'block min-w-0 truncate' : ''}`}>
      {displayedArtists.map((artist, index) => (
        <span key={index}>
          <Link
            to={`/artists/${encodeURIComponent(artist)}`}
            onClick={e => e.stopPropagation()}
            className={linkClassName}
          >
            {artist}
          </Link>
          {index < displayedArtists.length - 1 && (
            <span className="text-gray-500 dark:text-gray-400">, </span>
          )}
        </span>
      ))}
      {shouldTruncate && remainingCount > 0 && (
        <span className="text-gray-500 dark:text-gray-400">
          {' '}
          y {remainingCount} {remainingCount === 1 ? 'más' : 'más'}
        </span>
      )}
    </span>
  )
}
