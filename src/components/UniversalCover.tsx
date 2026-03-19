import { useState } from 'react'
import AlbumCover from './AlbumCover'
import ArtistAvatar from './ArtistAvatar'
import { useDominantColors } from '../hooks/useDominantColors'

interface UniversalCoverProps {
  type: 'playlist' | 'album' | 'song' | 'artist' | 'user'
  coverArtId?: string
  artistName?: string
  alt?: string
  
  // Playlist specifics
  customCoverUrl?: string | null
  isLoading?: boolean
  
  // Interaction
  onClick?: () => void
  
  // Context to render different layouts
  context?: 'hero' | 'grid'
  
  onImageLoaded?: (url: string | null) => void
  backgroundColor?: string
  initial?: string
}

export default function UniversalCover({
  type,
  coverArtId,
  artistName,
  alt = '',
  customCoverUrl,
  isLoading,
  onClick,
  context = 'hero',
  onImageLoaded,
  backgroundColor,
  initial
}: UniversalCoverProps) {
  const [internalImageUrl, setInternalImageUrl] = useState<string | null>(null)
  const colors = useDominantColors(internalImageUrl)

  const handleImageLoaded = (url: string | null) => {
    setInternalImageUrl(url)
    onImageLoaded?.(url)
  }

  if (type === 'user') {
    const isHero = context === 'hero';
    const containerClasses = isHero
      ? `w-48 h-48 md:w-56 md:h-56 flex-shrink-0 rounded-full shadow-2xl transition-all duration-500 ease-out`
      : `w-full h-full rounded-full`;

    return (
      <div 
        className={`${containerClasses} flex items-center justify-center text-white overflow-hidden ${onClick ? 'cursor-pointer' : ''}`}
        onClick={onClick}
        style={{ backgroundColor: backgroundColor || '#6b7280' }}
      >
        <span className={isHero ? 'text-6xl md:text-8xl select-none' : 'text-xl select-none'}>
          {initial || (artistName ? artistName.charAt(0).toUpperCase() : (alt ? alt.charAt(0).toUpperCase() : '?'))}
        </span>
      </div>
    )
  }
  
  if (type === 'artist') {
    if (context === 'hero') {
      return (
        <div 
          className={`w-48 h-48 md:w-56 md:h-56 flex-shrink-0 rounded-full overflow-hidden transition-all duration-500 ease-out ${onClick ? 'cursor-pointer' : ''}`}
          onClick={onClick}
          style={backgroundColor ? { backgroundColor } : undefined}
        >
          <ArtistAvatar artistName={artistName || alt} onImageLoaded={handleImageLoaded} />
        </div>
      )
    } else {
      // grid (e.g., ArtistsPage)
      return (
        <div className="relative group/cover mb-3">
          {/* Sombra / Glow premium basado en colores dominantes */}
          <div 
            className="absolute inset-0 rounded-full opacity-10 blur-2xl pointer-events-none scale-90"
            style={{ 
              background: colors 
                ? `radial-gradient(circle, ${colors.primary}, transparent 70%)` 
                : 'transparent' 
            }} 
          />
          
          <div className="relative z-10 w-full aspect-square rounded-full overflow-hidden shadow-lg">
            <ArtistAvatar artistName={artistName || alt} onImageLoaded={handleImageLoaded} />
          </div>
        </div>
      )
    }
  }

  // Playlist / Album / Song
  if (context === 'hero') {
    return (
      <div 
        className={`w-48 h-48 md:w-56 md:h-56 flex-shrink-0 rounded-2xl overflow-hidden transition-all duration-500 ease-out ${onClick ? 'cursor-pointer' : ''}`}
        onClick={onClick}
      >
        <AlbumCover
          coverArtId={coverArtId}
          customCoverUrl={customCoverUrl}
          size={800}
          alt={alt}
          className="h-full w-full object-cover"
          isLoading={isLoading}
        />
      </div>
    )
  }

  // grid context for generic album/playlist covers
  return (
    <div 
      className={`w-full aspect-square mb-3 transition-all duration-300 rounded-lg bg-gray-800 overflow-hidden ${onClick ? 'cursor-pointer' : ''}`}
      onClick={onClick}
    >
      <AlbumCover
        coverArtId={coverArtId}
        customCoverUrl={customCoverUrl}
        alt={alt}
        className="h-full w-full object-cover"
        isLoading={isLoading}
      />
    </div>
  )
}
