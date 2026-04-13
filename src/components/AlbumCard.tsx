import { memo } from 'react'
import { Link } from 'react-router-dom'
import { Album } from '../services/navidromeApi'
import AlbumCover from './AlbumCover'
import { ArtistLinks } from './ArtistLinks'

interface AlbumCardProps {
  album: Album
  showPlayButton?: boolean
  immersive?: boolean
}

function AlbumCard({ album, immersive = false }: AlbumCardProps) {
  return (
    <div className="group">
      <div className="relative">
        <Link to={`/albums/${album.id}`} state={{ album }}>
          <div className="relative rounded-lg overflow-hidden active:scale-95 transition-transform duration-150">
            <AlbumCover
              coverArtId={album.coverArt}
              size={400}
              alt={album.name}
              className="w-full h-full object-cover"
            />
          </div>
        </Link>
      </div>
      <div className="mt-2">
        <Link
          to={`/albums/${album.id}`}
          state={{ album }}
          className={`font-semibold transition-colors duration-150 block truncate ${immersive ? 'text-white hover:text-white/80' : 'text-gray-800 dark:text-gray-200'}`}
          title={album.name}
        >
          {album.name}
        </Link>
        <div className="flex justify-between items-center mt-1">
          <div className="truncate pr-2">
            <ArtistLinks
              artists={album.artist}
              className={`text-sm ${immersive ? 'text-white/55' : 'text-gray-500 dark:text-gray-400'}`}
            />
          </div>
          {album.year && (
            <p className={`text-sm flex-shrink-0 ${immersive ? 'text-white/40' : 'text-gray-400 dark:text-gray-500'}`}>
              {album.year}
            </p>
          )}
        </div>
      </div>
    </div>
  )
}

// Memoizar para evitar re-renders innecesarios
export default memo(AlbumCard, (prevProps, nextProps) => {
  return prevProps.album.id === nextProps.album.id &&
         prevProps.showPlayButton === nextProps.showPlayButton &&
         prevProps.immersive === nextProps.immersive
})
