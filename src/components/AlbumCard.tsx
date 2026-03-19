import { memo } from 'react'
import { Link } from 'react-router-dom'
import { Album } from '../services/navidromeApi'
import AlbumCover from './AlbumCover'
import { ArtistLinks } from './ArtistLinks'
import { usePlayerActions } from '../contexts/PlayerContext'
import { PlayIcon } from '@heroicons/react/24/solid'

interface AlbumCardProps {
  album: Album
  showPlayButton?: boolean
}

function AlbumCard({ album, showPlayButton = false }: AlbumCardProps) {
  const playerActions = usePlayerActions()

  const handlePlayClick = (e: React.MouseEvent) => {
    e.stopPropagation()
    playerActions.playAlbum(album.id)
  }

  return (
    <div className="group">
      <div className="relative">
        <Link to={`/albums/${album.id}`}>
          <div className="relative rounded-lg overflow-hidden">
            <AlbumCover
              coverArtId={album.coverArt}
              size={400}
              alt={album.name}
              className="w-full h-full object-cover"
            />
            {/* Sombra con GPU acceleration */}
            <div className="absolute inset-0 shadow-md group-hover:shadow-xl transition-shadow duration-200 rounded-lg pointer-events-none" />
          </div>
        </Link>
        {showPlayButton && (
          <>
            {/* Overlay optimizado con opacity (GPU accelerated) — fuera del Link para no bloquear navegación */}
            <div className="absolute inset-0 bg-black opacity-0 group-hover:opacity-40 transition-opacity duration-200 rounded-lg pointer-events-none" />
            <div className="absolute inset-0 flex items-center justify-center pointer-events-none">
              <button
                onClick={handlePlayClick}
                className="pointer-events-auto opacity-0 group-hover:opacity-100 will-change-transform translate-y-2 group-hover:translate-y-0 transition-all duration-200 ease-out bg-white text-gray-900 rounded-full p-3 shadow-lg hover:scale-105"
                aria-label={`Reproducir ${album.name}`}
              >
                <PlayIcon className="w-8 h-8" />
              </button>
            </div>
          </>
        )}
      </div>
      <div className="mt-2">
        <Link
          to={`/albums/${album.id}`}
          className="font-semibold text-gray-800 dark:text-gray-200 group-hover:text-blue-500 dark:group-hover:text-blue-400 transition-colors duration-150 block truncate"
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
