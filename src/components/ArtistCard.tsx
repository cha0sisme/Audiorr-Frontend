import { useState, useMemo, memo, useCallback } from 'react'
import { Link } from 'react-router-dom'
import { useDominantColors } from '../hooks/useDominantColors'
import UniversalCover from './UniversalCover'
import { usePlayerActions, usePlayerState } from '../contexts/PlayerContext'
import { useConnect } from '../hooks/useConnect'
import { navidromeApi } from '../services/navidromeApi'

interface ArtistCardProps {
  name: string
  albumCount?: number
}

function ArtistCard({ name, albumCount }: ArtistCardProps) {
  const [imageUrl, setImageUrl] = useState<string | null>(null)
  const colors = useDominantColors(imageUrl)
  const playerActions = usePlayerActions()
  const playerState = usePlayerState()
  const { isConnected, activeDeviceId, currentDeviceId, remotePlaybackState, sendRemoteCommand } = useConnect()

  const cardStyle = useMemo(() => {
    if (!colors) return {}
    return {
      '--artist-color': colors.primary,
      '--artist-color-light': colors.secondary,
    } as React.CSSProperties
  }, [colors])

  // Lógica de reproducción remota vs local
  const isRemote = isConnected && activeDeviceId && activeDeviceId !== currentDeviceId
  const currentSource = isRemote ? remotePlaybackState?.currentSource : playerState.currentSource
  const isPlaying = isRemote ? remotePlaybackState?.playing : playerState.isPlaying
  
  // Verificar si este artista es el que suena
  const isThisArtistPlaying = currentSource === `artist:${name}`

  const handlePlayClick = useCallback(async (e: React.MouseEvent) => {
    e.preventDefault()
    e.stopPropagation()

    if (isThisArtistPlaying) {
      if (isRemote) {
        sendRemoteCommand(isPlaying ? 'pause' : 'play', null, activeDeviceId!)
      } else {
        playerActions.togglePlayPause()
      }
    } else {
      try {
        const songs = await navidromeApi.getArtistSongs(name)
        if (songs.length > 0) {
          playerActions.playPlaylist(songs)
        }
      } catch (error) {
        console.error('Error fetching artist songs for quick play:', error)
      }
    }
  }, [isThisArtistPlaying, isRemote, isPlaying, sendRemoteCommand, activeDeviceId, playerActions, name])

  return (
    <Link
      to={`/artists/${encodeURIComponent(name)}`}
      className="group text-center block"
      style={cardStyle}
    >
      <div className="relative mb-4">
        <div className="absolute inset-0 rounded-full opacity-10 blur-2xl pointer-events-none"
             style={{ background: colors ? `radial-gradient(circle, ${colors.primary}, transparent 70%)` : 'transparent' }} />
        
        <div className="relative z-10 rounded-full shadow-lg overflow-hidden ring-1 ring-black/5 dark:ring-white/10 aspect-square">
          <UniversalCover 
            type="artist" 
            artistName={name} 
            context="grid" 
            onImageLoaded={setImageUrl}
          />

          {/* Botón de Play en Hover */}
          <div className="absolute inset-0 flex items-center justify-center pointer-events-none">
            <button
              onClick={handlePlayClick}
              className={`relative z-20 h-14 w-14 flex items-center justify-center rounded-full shadow-2xl backdrop-blur-md transition-all duration-300 pointer-events-auto active:scale-90 ${
                isThisArtistPlaying ? 'opacity-100 scale-100' : 'opacity-0 scale-75 group-hover:opacity-100 group-hover:scale-100'
              } ${isRemote ? 'bg-green-500/90 hover:bg-green-500' : 'bg-white/90 hover:bg-white'} ${isThisArtistPlaying ? 'ring-2 ring-white/50' : ''}`}
            >
              {isThisArtistPlaying && isPlaying ? (
                <svg className={`w-7 h-7 ${isRemote ? 'text-white' : 'text-gray-900'}`} fill="currentColor" viewBox="0 0 24 24">
                  <path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z" />
                </svg>
              ) : (
                <svg className={`w-7 h-7 translate-x-[1px] ${isRemote ? 'text-white' : 'text-gray-900'}`} fill="currentColor" viewBox="0 0 24 24">
                  <path d="M8 5v14l11-7z" />
                </svg>
              )}
            </button>
          </div>
        </div>
      </div>
      
      <p className="font-bold tracking-normal text-gray-900 dark:text-gray-100 truncate w-full group-hover:text-blue-500 dark:group-hover:text-blue-400 transition-colors duration-300">
        {name}
      </p>
      
      {albumCount !== undefined && (
        <p className="text-xs font-medium text-gray-500 dark:text-gray-400 mt-1.5 opacity-80">
          {albumCount} {albumCount === 1 ? 'álbum' : 'álbumes'}
        </p>
      )}
    </Link>
  )
}

export default memo(ArtistCard, (prev, next) => prev.name === next.name && prev.albumCount === next.albumCount)
