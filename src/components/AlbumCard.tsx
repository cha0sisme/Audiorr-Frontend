import { memo } from 'react'
import { Link } from 'react-router-dom'
import { Album } from '../services/navidromeApi'
import AlbumCover from './AlbumCover'
import { ArtistLinks } from './ArtistLinks'

interface AlbumCardProps {
  album: Album
  showPlayButton?: boolean
}

function AlbumCard({ album }: AlbumCardProps) {
  return (
    <div className="group">
      <div className="relative">
        <Link to={`/albums/${album.id}`}>
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
          className="font-semibold text-gray-800 dark:text-gray-200 transition-colors duration-150 block truncate"
          title={album.name}
        >
          {album.name}
        </Link>
        <div className="flex justify-between items-center mt-1">
          <div className="truncate pr-2">
            <ArtistLinks
              artists={album.artist}
              className="text-sm text-gray-500 dark:text-gray-400"
            />
          </div>
          {album.year && (
            <p className="text-sm text-gray-400 dark:text-gray-500 flex-shrink-0">
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
         prevProps.showPlayButton === nextProps.showPlayButton
})
