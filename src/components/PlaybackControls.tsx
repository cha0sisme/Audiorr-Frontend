import { usePlayerState, usePlayerActions } from '../contexts/PlayerContext'
import { useConnect } from '../hooks/useConnect'

interface PlaybackControlsProps {
  isMobile?: boolean
  accentColor?: string // Primary color from album art — button gets a darkened version
}

function darkenHex(hex: string, factor = 0.60): string {
  const clean = hex.replace('#', '')
  const r = parseInt(clean.slice(0, 2), 16)
  const g = parseInt(clean.slice(2, 4), 16)
  const b = parseInt(clean.slice(4, 6), 16)
  return `rgb(${Math.round(r * factor)},${Math.round(g * factor)},${Math.round(b * factor)})`
}

export default function PlaybackControls({ isMobile = false, accentColor }: PlaybackControlsProps) {
  const playerState = usePlayerState()
  const playerActions = usePlayerActions()
  const { isConnected, activeDeviceId, currentDeviceId, sendRemoteCommand, remotePlaybackState } = useConnect()

  const isRemote = isConnected && activeDeviceId && activeDeviceId !== currentDeviceId

  // Usar metadata de cola remota si hay una
  const currentSong = isRemote ? remotePlaybackState?.metadata : playerState.currentSong
  const isPlaying = isRemote ? remotePlaybackState?.playing : playerState.isPlaying

  const handlePrevious = () => {
    if (isRemote) {
      sendRemoteCommand('previous', null, activeDeviceId);
    } else {
      playerActions.previous();
    }
  }

  const handleNext = () => {
    if (isRemote) {
      sendRemoteCommand('next', null, activeDeviceId);
    } else {
      playerActions.next();
    }
  }

  const handleTogglePlayPause = () => {
    if (isRemote) {
      sendRemoteCommand(isPlaying ? 'pause' : 'play', null, activeDeviceId);
    } else {
      playerActions.togglePlayPause();
    }
  }

  const canGoPrevious = currentSong !== null
  const canGoNext = isRemote
    ? (remotePlaybackState?.queue?.length || 0) > 0
    : playerState.currentSong !== null &&
      playerState.queue.findIndex(s => s.id === playerState.currentSong?.id) <
        playerState.queue.length - 1

  // Desktop play button: accent color > remote green > default blue/dark
  const playBtnStyle = !isMobile && accentColor && !isRemote
    ? { backgroundColor: darkenHex(accentColor) }
    : undefined
  const desktopPlayBtnClass = `p-2.5 ${
    accentColor && !isRemote
      ? ''
      : isRemote
        ? 'bg-green-500'
        : 'bg-blue-500 dark:bg-gray-700'
  } text-white rounded-full shadow-md hover:opacity-90 disabled:bg-gray-400 disabled:cursor-not-allowed transition-all`

  // Mobile: all three buttons identical — no background, white, same size
  const mobileBtnClass = `p-1.5 text-black/80 dark:text-white disabled:opacity-40 disabled:cursor-not-allowed transition-opacity ${
    isRemote ? 'text-green-600 dark:text-green-400' : ''
  }`

  return (
    <div className={`flex items-center justify-center ${isMobile ? 'gap-2' : `gap-4 ${isRemote ? 'border-green-500/20 bg-green-500/5' : ''}`} rounded-full transition-colors`}>
      <button
        onClick={handlePrevious}
        disabled={!canGoPrevious}
        className={isMobile ? mobileBtnClass : `p-2 disabled:opacity-50 disabled:cursor-not-allowed ${isRemote ? 'text-green-600 dark:text-green-500' : ''}`}
        aria-label="Anterior"
      >
        <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
          <path d="M6 6h2v12H6zm3.5 6 8.5 6V6z" />
        </svg>
      </button>
      <button
        onClick={handleTogglePlayPause}
        disabled={!currentSong}
        className={isMobile ? mobileBtnClass : desktopPlayBtnClass}
        style={playBtnStyle}
        aria-label={isPlaying ? 'Pausar' : 'Reproducir'}
      >
        {isPlaying ? (
          <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
            <path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z" />
          </svg>
        ) : (
          <svg className="w-5 h-5" fill="currentColor" viewBox="2 0 24 24">
            <path d="M8 5v14l11-7z" />
          </svg>
        )}
      </button>
      <button
        onClick={handleNext}
        disabled={!canGoNext}
        className={isMobile ? mobileBtnClass : `p-2 disabled:opacity-50 disabled:cursor-not-allowed ${isRemote ? 'text-green-600 dark:text-green-500' : ''}`}
        aria-label="Siguiente"
      >
        <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
          <path d="M6 18l8.5-6L6 6v12zM16 6v12h2V6h-2z" />
        </svg>
      </button>
    </div>
  )
}
