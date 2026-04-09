import { useState, useEffect } from 'react'
import { Capacitor } from '@capacitor/core'
import { Link } from 'react-router-dom'
import AlbumCover from './AlbumCover'
import NowPlayingViewer from './NowPlayingViewer'
import PlaybackControls from './PlaybackControls'
import { MusicalNoteIcon } from '@heroicons/react/24/solid'
import { usePlayerState, usePlayerProgress, usePlayerActions } from '../contexts/PlayerContext'
import { AnimatePresence, motion } from 'framer-motion'
import { ArtistLinks } from './ArtistLinks'
import { useCanvas } from '../hooks/useCanvas'
import { useConnect } from '../hooks/useConnect'
import { DevicePicker } from './DevicePicker'
import { nativeNowPlaying } from '../services/nativeNowPlaying'


// Icono de micrófono desde assets
const MicrophoneIcon = ({ className }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
    <circle
      cx="16.5649"
      cy="8"
      r="3"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
    <path
      d="M13.5649 8L6.06491 16.5L7.15688 17.7218L8.06491 18.5L16.5649 11"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
    <path
      d="M5 19.5L7 17.5"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </svg>
)

// Icono de video desde assets
const VideoIcon = ({ className }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
    <path
      d="M20.5245 6.00694C20.3025 5.81544 20.0333 5.70603 19.836 5.63863C19.6156 5.56337 19.3637 5.50148 19.0989 5.44892C18.5677 5.34348 17.9037 5.26005 17.1675 5.19491C15.6904 5.06419 13.8392 5 12 5C10.1608 5 8.30956 5.06419 6.83246 5.1949C6.09632 5.26005 5.43231 5.34348 4.9011 5.44891C4.63628 5.50147 4.38443 5.56337 4.16403 5.63863C3.96667 5.70603 3.69746 5.81544 3.47552 6.00694C3.26514 6.18846 3.14612 6.41237 3.07941 6.55976C3.00507 6.724 2.94831 6.90201 2.90314 7.07448C2.81255 7.42043 2.74448 7.83867 2.69272 8.28448C2.58852 9.18195 2.53846 10.299 2.53846 11.409C2.53846 12.5198 2.58859 13.6529 2.69218 14.5835C2.74378 15.047 2.81086 15.4809 2.89786 15.8453C2.97306 16.1603 3.09841 16.5895 3.35221 16.9023C3.58757 17.1925 3.92217 17.324 4.08755 17.3836C4.30223 17.461 4.55045 17.5218 4.80667 17.572C5.32337 17.6733 5.98609 17.7527 6.72664 17.8146C8.2145 17.9389 10.1134 18 12 18C13.8865 18 15.7855 17.9389 17.2733 17.8146C18.0139 17.7527 18.6766 17.6733 19.1933 17.572C19.4495 17.5218 19.6978 17.461 19.9124 17.3836C20.0778 17.324 20.4124 17.1925 20.6478 16.9023C20.9016 16.5895 21.0269 16.1603 21.1021 15.8453C21.1891 15.4809 21.2562 15.047 21.3078 14.5835C21.4114 13.6529 21.4615 12.5198 21.4615 11.409C21.4615 10.299 21.4115 9.18195 21.3073 8.28448C21.2555 7.83868 21.1874 7.42043 21.0969 7.07448C21.0517 6.90201 20.9949 6.72401 20.9206 6.55976C20.8539 6.41236 20.7349 6.18846 20.5245 6.00694Z"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
    <path
      d="M14.5385 11.5L10.0962 14.3578L10.0962 8.64207L14.5385 11.5Z"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </svg>
)

// Icono de cola desde assets
const QueueIcon = ({ className }: { className?: string }) => (
  <svg
    className={className}
    viewBox="0 0 24 24"
    fill="currentColor"
    xmlns="http://www.w3.org/2000/svg"
  >
    <path d="M22,4H2A1,1,0,0,0,1,5v6a1,1,0,0,0,1,1H22a1,1,0,0,0,1-1V5A1,1,0,0,0,22,4Zm-1,6H3V6H21Zm2,5a1,1,0,0,1-1,1H2a1,1,0,0,1,0-2H22A1,1,0,0,1,23,15Zm0,4a1,1,0,0,1-1,1H2a1,1,0,0,1,0-2H22A1,1,0,0,1,23,19Z" />
  </svg>
)

// Iconos de volumen desde assets
interface NowPlayingBarProps {
  onShowQueue: () => void
  onToggleLyrics: () => void
  showLyrics: boolean
  onToggleCanvas: () => void
  showCanvas: boolean
}

export default function NowPlayingBar({
  onShowQueue,
  onToggleLyrics,
  showLyrics,
  onToggleCanvas,
  showCanvas,
}: NowPlayingBarProps) {
  const playerState = usePlayerState()
  const playerProgress = usePlayerProgress()
  const playerActions = usePlayerActions()
  const [isViewerOpen, setIsViewerOpen] = useState(false)
  const { remotePlaybackState, activeDeviceId, currentDeviceId, devices, isConnected } = useConnect()
  
  const isRemote = isConnected && activeDeviceId && activeDeviceId !== currentDeviceId
  const activeDevice = devices.find(d => d.id === activeDeviceId)

  // Usar estado remoto si aplica, sino el local.
  // Buscamos la Song completa en el queue remoto para tener todos los campos (coverArt, albumId, etc.)
  const remoteSong = isRemote && remotePlaybackState
    ? remotePlaybackState.queue?.find(s => s.id === remotePlaybackState.trackId) ?? null
    : null
  const currentSong = isRemote ? (remoteSong ?? remotePlaybackState?.metadata ?? null) : playerState.currentSong
  const currentProgress = isRemote ? (remotePlaybackState?.position || 0) : playerProgress.progress
  const currentDuration = isRemote ? (remoteSong?.duration || remotePlaybackState?.metadata?.duration || 0) : playerProgress.duration


  // Determinar el máximo de artistas a mostrar según el tamaño de pantalla
  const [maxArtists, setMaxArtists] = useState(() => {
    if (typeof window === 'undefined') return 2
    const width = window.innerWidth
    if (width < 640) return 1 // mobile: 1 artista
    if (width < 1024) return 2 // tablet: 2 artistas
    return 2 // desktop: 2 artistas
  })

  useEffect(() => {
    const handleResize = () => {
      const width = window.innerWidth
      if (width < 640) {
        setMaxArtists(1) // mobile
      } else if (width < 1024) {
        setMaxArtists(2) // tablet
      } else {
        setMaxArtists(2) // desktop
      }
    }

    window.addEventListener('resize', handleResize)
    return () => window.removeEventListener('resize', handleResize)
  }, [])

  // Convertir currentSong a formato Song para el hook useCanvas
  const currentSongForCanvas = currentSong
    ? {
        id: isRemote ? (remotePlaybackState?.trackId || '') : (playerState.currentSong?.id || ''),
        title: currentSong.title,
        artist: currentSong.artist,
        album: currentSong.album,
        duration: currentSong.duration,
        path: isRemote ? '' : (playerState.currentSong?.path || ''),
        coverArt: currentSong.coverArt,
        albumId: isRemote ? '' : (playerState.currentSong?.albumId || ''),
      }
    : null

  // Obtener Canvas para la canción actual
  const { canvasUrl, isLoading: isLoadingCanvas } = useCanvas(currentSongForCanvas)

  // Verificar si hay Canvas disponible
  const hasCanvas = canvasUrl !== null

  // En nativo, el plugin NativeNowPlayingPlugin dispara este evento para abrir el full player
  useEffect(() => {
    if (!Capacitor.isNativePlatform()) return
    const handler = () => setIsViewerOpen(true)
    window.addEventListener('native-nowplaying-tap', handler)
    return () => window.removeEventListener('native-nowplaying-tap', handler)
  }, [])

  // Sincronizar estado del viewer con el native tab bar y mini-player.
  // Siempre enviar el estado actual — si el viewer está abierto al montar
  // (ej. componente re-montado), el tab bar debe ocultarse inmediatamente.
  useEffect(() => {
    if (!Capacitor.isNativePlatform()) return
    if (isViewerOpen) {
      nativeNowPlaying.showViewer()
    } else {
      nativeNowPlaying.hideViewer()
    }
  }, [isViewerOpen])

  const handleSeek = (event: React.MouseEvent<HTMLDivElement>) => {
    // Validar que tengamos una duración válida antes de intentar seek
    const duration = playerProgress.duration
    const progressBar = event.currentTarget
    
    if (!isFinite(duration) || duration <= 0) {
      console.warn('[NowPlayingBar] Seek ignorado - duración inválida:', duration)
      return
    }
    
    const rect = progressBar.getBoundingClientRect()
    
    // Validar que el rect tenga dimensiones válidas
    if (rect.width <= 0) {
      console.warn('[NowPlayingBar] Seek ignorado - barra sin ancho')
      return
    }
    
    const offsetX = event.clientX - rect.left
    const percentage = Math.max(0, Math.min(1, offsetX / rect.width))
    const newTime = percentage * duration
    
    // Última validación antes de enviar
    if (!isFinite(newTime) || newTime < 0) {
      console.warn('[NowPlayingBar] Seek ignorado - tiempo calculado inválido:', newTime)
      return
    }
    
    playerActions.seek(newTime)
  }

  const formatTime = (seconds: number) => {
    // FIX: Proteger contra valores inválidos (Infinity, NaN, negativos)
    if (!isFinite(seconds) || seconds < 0 || isNaN(seconds)) {
      return '0:00'
    }
    const floorSeconds = Math.floor(seconds)
    const min = Math.floor(floorSeconds / 60)
    const sec = floorSeconds % 60
    return `${min}:${sec < 10 ? '0' : ''}${sec}`
  }

  const getSourceLink = () => {
    // 1. Intentar desde currentSource (fuente de reproducción activa)
    if (playerState.currentSource) {
      const parts = playerState.currentSource.split(':')
      if (parts.length >= 2) {
        const [type, id] = parts
        if (type === 'album') return `/albums/${id}`
        if (type === 'playlist') return `/playlists/${id}`
      }
    }
    
    // 2. Fallback a metadatos de la canción si no hay fuente explícita
    if (playerState.currentSong?.playlistId) {
      return `/playlists/${playerState.currentSong.playlistId}`
    }
    if (playerState.currentSong?.albumId) {
      return `/albums/${playerState.currentSong.albumId}`
    }
    
    return null
  }

  const sourceLink = getSourceLink()

  // FIX: Proteger contra valores inválidos para evitar barra de progreso rota.
  // Clamp 0-100: durante crossfade, duration puede cambiar antes que progress.
  const progressPercentage =
    currentDuration > 0 &&
    isFinite(currentDuration) &&
    isFinite(currentProgress)
      ? Math.min(100, Math.max(0, (currentProgress / currentDuration) * 100))
      : 0

  // En nativo, el mini-player es UIKit — solo renderizamos el NowPlayingViewer.
  if (Capacitor.isNativePlatform()) {
    return (
      <NowPlayingViewer
        isOpen={isViewerOpen}
        onClose={() => setIsViewerOpen(false)}
        canvasUrl={canvasUrl}
        isLoadingCanvas={isLoadingCanvas}
        onShowQueue={onShowQueue}
      />
    )
  }

  return (
    // Móvil: fixed encima del TabBar (49px + safe area)
    // Desktop (md+): estático en el flujo del documento
    <footer className="fixed left-4 right-4 md:static md:bg-gray-100 md:dark:bg-[#1a1a1a] md:border-t md:border-gray-200 md:dark:border-white/[0.08] md:p-4 z-50" style={{ bottom: 'calc(57px + env(safe-area-inset-bottom) + 0.5rem)' }}>

      {/* Layout móvil: iOS Liquid Glass style */}
      <div className="flex md:hidden flex-col rounded-[26px] relative z-[100] overflow-hidden bg-white/55 dark:bg-[#1c1c1e]/80 backdrop-blur-3xl backdrop-saturate-200 backdrop-brightness-105 border border-white/50 dark:border-white/10 shadow-[0_8px_32px_-4px_rgba(0,0,0,0.18),0_2px_8px_-2px_rgba(0,0,0,0.10),inset_0_1px_0_rgba(255,255,255,0.65)] dark:shadow-[0_8px_32px_-4px_rgba(0,0,0,0.55),inset_0_1px_0_rgba(255,255,255,0.07)]">
        {/* Reflejo especular superior */}
        <div className="absolute top-0 left-0 right-0 h-1/2 rounded-t-[26px] pointer-events-none bg-gradient-to-b from-white/35 dark:from-white/5 to-transparent" />

        {/* Barra de progreso */}
        <div
          className="absolute top-0 left-0 right-0 h-[3px] cursor-pointer z-20 pointer-events-auto rounded-t-[26px] overflow-hidden bg-black/[0.06] dark:bg-white/10"
          onClick={handleSeek}
        >
          <div
            className={`absolute top-0 left-0 h-full ${isRemote ? 'bg-green-500/60' : 'bg-black/20 dark:bg-white/35'}`}
            style={{ width: `${progressPercentage}%`, transition: playerState.isPlaying ? 'width 300ms linear' : 'none' }}
          />
        </div>

        {/* Contenido principal */}
        <div className="flex items-center gap-3 px-3 pt-4 pb-3 relative z-10">
          {/* Portada — abre el viewer */}
          <button
            onClick={() => currentSong && setIsViewerOpen(true)}
            disabled={!currentSong}
            className="w-[46px] h-[46px] flex-shrink-0 relative disabled:opacity-40"
            aria-label="Ver ahora reproduciendo"
          >
            {currentSong ? (
              <div className="w-full h-full rounded-[10px] overflow-hidden shadow-[0_4px_14px_-2px_rgba(0,0,0,0.28)]">
                <AlbumCover coverArtId={currentSong.coverArt} size={100} className="rounded-[10px]" />
              </div>
            ) : (
              <div className="w-full h-full bg-black/10 dark:bg-white/10 rounded-[10px] flex items-center justify-center">
                <MusicalNoteIcon className="w-5 h-5 text-black/30 dark:text-white/30" />
              </div>
            )}
          </button>

          {/* Info canción */}
          <div className="flex-1 min-w-0 flex flex-col justify-center">
            {currentSong?.title ? (
              <div className="font-semibold truncate text-[13.5px] text-black/88 dark:text-white/90 leading-snug tracking-[-0.01em]">
                {currentSong.title}
              </div>
            ) : (
              <div className="text-[13.5px] text-black/35 dark:text-white/35">Sin reproducción</div>
            )}
            {currentSong?.artist ? (
              <ArtistLinks
                artists={currentSong.artist}
                className="text-[12px] text-black/50 dark:text-white/45 truncate leading-snug mt-[1px]"
                maxArtists={1}
              />
            ) : null}
          </div>

          {/* Controles */}
          <div className="flex-shrink-0 flex items-center">
            <PlaybackControls isMobile={true} />
          </div>

          {/* Acciones secundarias */}
          <div className="flex items-center flex-shrink-0">
            <DevicePicker align="up" buttonClassName="p-1.5" iconClassName="w-5 h-5" />
          </div>
        </div>

        {/* AutoMix / Remote indicator */}
        <AnimatePresence mode="wait">
          {(playerState.isCrossfading || playerState.isReconnecting || (isRemote && activeDevice)) && (
            <motion.div
              key="bottom-indicator-mobile"
              initial={{ opacity: 0, scaleY: 0, transformOrigin: 'top' }}
              animate={{ opacity: 1, scaleY: 1 }}
              exit={{ opacity: 0, scaleY: 0 }}
              transition={{ duration: 0.2, ease: 'easeOut' }}
              className="flex items-center justify-center pb-2.5 relative z-10"
            >
              {playerState.isReconnecting ? (
                <div className="flex items-center gap-1.5">
                  <div className="w-1.5 h-1.5 bg-amber-500 rounded-full animate-pulse" />
                  <span className="text-[10px] font-medium text-amber-600 dark:text-amber-400">
                    Reconectando...
                  </span>
                </div>
              ) : playerState.isCrossfading ? (
                <div className="flex items-center gap-1.5 text-[10px] font-bold wave-text bg-clip-text text-transparent bg-gradient-to-r from-blue-700 via-blue-400 to-blue-700 dark:text-transparent dark:from-sky-400 dark:via-sky-300 dark:to-cyan-400 bg-[length:200%_100%]">
                  <span>AutoMix</span>
                </div>
              ) : isRemote && activeDevice ? (
                <div className="flex items-center gap-1.5">
                  <div className="w-1.5 h-1.5 bg-green-500 rounded-full animate-pulse" />
                  <span className="text-[10px] font-medium text-green-600 dark:text-green-400">
                    Reproduciendo en {activeDevice.name}
                  </span>
                </div>
              ) : null}
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      {/* Layout desktop/tablet: horizontal completo */}
      <div className="hidden md:flex items-center gap-4">
        <div className="w-20 h-20 flex-shrink-0 relative">
          {currentSong ? (
            sourceLink ? (
              <Link to={sourceLink}>
                <AlbumCover coverArtId={currentSong.coverArt} size={200} className="rounded-md" />
              </Link>
            ) : (
              <AlbumCover coverArtId={currentSong.coverArt} size={200} className="rounded-md" />
            )
          ) : (
            <div className="w-full h-full bg-gray-200 dark:bg-white/10 rounded-md flex items-center justify-center">
              <MusicalNoteIcon className="w-8 h-8 text-gray-400" />
            </div>
          )}
        </div>

        <div className="flex-1 min-w-0 flex flex-col justify-center">
          {currentSong?.title && (
            <div className="font-bold truncate text-gray-900 dark:text-white">
              {currentSong.title}
            </div>
          )}
          <div className="flex flex-col items-start min-w-0">
            {currentSong?.artist ? (
              <ArtistLinks
                artists={currentSong.artist}
                className="text-sm text-gray-500 dark:text-gray-400 truncate hover:text-gray-900 dark:hover:text-white transition-colors"
                maxArtists={maxArtists}
              />
            ) : (
              <div className="text-sm text-gray-500 dark:text-gray-400 truncate">...</div>
            )}
            {!isRemote && currentSong && 'albumId' in currentSong && currentSong.albumId ? (
              <Link
                to={`/albums/${currentSong.albumId}`}
                className="text-xs text-gray-500 dark:text-gray-400 truncate hover:text-gray-900 dark:hover:text-white transition-colors"
                title={currentSong.album}
              >
                {currentSong.album}
              </Link>
            ) : (
              <div className="text-xs text-gray-500 dark:text-gray-400 truncate">
                {currentSong?.album || ''}
              </div>
            )}
          </div>
        </div>

        <div className="flex-1 flex flex-col items-center justify-center max-w-xl gap-1">
          <PlaybackControls />
          <div className="w-full flex items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
            <span>{formatTime(currentProgress)}</span>
            <div
              className="w-full h-2 bg-gray-300 dark:bg-gray-600 rounded-full cursor-pointer group"
              onClick={handleSeek}
              style={{ minHeight: '8px', position: 'relative', overflow: 'hidden' }}
            >
              <div
                className={`h-full ${isRemote ? 'bg-green-500' : 'bg-blue-500 dark:bg-white'} rounded-full group-hover:bg-blue-400 dark:group-hover:bg-gray-300`}
                style={{
                  width: `${progressPercentage}%`,
                  minHeight: '8px',
                  transition: playerState.isPlaying ? 'width 500ms linear' : 'none',
                }}
              ></div>
            </div>
            <span>{formatTime(currentDuration)}</span>
          </div>
          <div className="h-5 flex items-center justify-center">
            <AnimatePresence mode="wait">
              {playerState.isReconnecting ? (
                <motion.div
                  key="reconnecting-indicator-desktop"
                  initial={{ opacity: 0, scale: 0.9 }}
                  animate={{ opacity: 1, scale: 1 }}
                  exit={{ opacity: 0, scale: 0.9 }}
                  transition={{ duration: 0.3, ease: 'easeOut' }}
                >
                  <div className="flex items-center gap-1.5">
                    <div className="w-1.5 h-1.5 bg-amber-500 rounded-full animate-pulse flex-shrink-0" />
                    <span className="text-[10px] font-medium text-amber-600 dark:text-amber-400 leading-none">
                      Reconectando...
                    </span>
                  </div>
                </motion.div>
              ) : playerState.isCrossfading ? (
                <motion.div
                  key="crossfade-indicator-desktop"
                  initial={{ opacity: 0, scale: 0.9 }}
                  animate={{ opacity: 1, scale: 1 }}
                  exit={{ opacity: 0, scale: 0.9 }}
                  transition={{ duration: 0.3, ease: 'easeOut' }}
                >
                  <div className="flex items-center gap-1.5 text-xs font-semibold wave-text bg-clip-text text-transparent bg-gradient-to-r from-blue-700 via-blue-400 to-blue-700 dark:text-transparent dark:from-sky-400 dark:via-sky-300 dark:to-cyan-400 bg-[length:200%_100%]">
                    <span>AutoMix</span>
                  </div>
                </motion.div>
              ) : isRemote && activeDevice ? (
                <motion.div
                  key="remote-device-desktop"
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  exit={{ opacity: 0 }}
                  transition={{ duration: 0.3 }}
                >
                  <div className="flex items-center gap-1.5">
                    <div className="w-1.5 h-1.5 bg-green-400 rounded-full animate-pulse flex-shrink-0" />
                    <span className="text-[10px] font-medium text-green-500 dark:text-green-400 leading-none">
                      Reproduciendo en {activeDevice.name}
                    </span>
                  </div>
                </motion.div>
              ) : null}
            </AnimatePresence>
          </div>
        </div>

        <div className="flex-1 flex items-center justify-end gap-1.5">

          <button
            onClick={onToggleLyrics}
            disabled={!playerState.currentSong}
            className="p-2 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <MicrophoneIcon
              className={`w-6 h-6 transition-all ${
                !playerState.currentSong
                  ? 'text-gray-400 dark:text-gray-600 opacity-30'
                  : showLyrics
                    ? 'text-gray-900 dark:text-white opacity-100'
                    : 'text-gray-900/60 dark:text-white/60 opacity-100'
              }`}
            />
          </button>
          <button
            onClick={onToggleCanvas}
            disabled={!playerState.currentSong || !hasCanvas}
            className="p-2 disabled:opacity-50 disabled:cursor-not-allowed"
            title={hasCanvas ? 'Mostrar Canvas' : 'Canvas no disponible'}
          >
            <VideoIcon
              className={`w-6 h-6 transition-all ${
                !playerState.currentSong || !hasCanvas
                  ? 'text-gray-400 dark:text-gray-600 opacity-30'
                  : showCanvas
                    ? 'text-gray-900 dark:text-white opacity-100'
                    : 'text-gray-900/60 dark:text-white/60 opacity-100'
              }`}
            />
          </button>
          <button onClick={onShowQueue} className="p-2">
            <QueueIcon className="w-6 h-6 text-gray-500 dark:text-gray-400" />
          </button>

        </div>
      </div>

      <NowPlayingViewer
        isOpen={isViewerOpen}
        onClose={() => setIsViewerOpen(false)}
        canvasUrl={canvasUrl}
        isLoadingCanvas={isLoadingCanvas}
        onShowQueue={onShowQueue}
      />
    </footer>
  )
}
