import { AnimatePresence, motion, Reorder } from 'framer-motion'
import { XMarkIcon } from '@heroicons/react/24/solid'
import AlbumCover from './AlbumCover'
import { Song } from '../services/navidromeApi'
import { useState, useEffect, useRef, useCallback } from 'react'
import { PlayerStateType } from '../contexts/PlayerContext'

interface QueuePanelProps {
  isOpen: boolean
  onClose: () => void
  queue: Song[]
  currentSong: PlayerStateType['currentSong']
  onPlaySong: (song: Song) => void
  onRemoveSong: (songId: string) => void
  onClearQueue: () => void
  onReorderQueue: (newOrder: Song[]) => void
}

// Animaciones premium estilo Spotify/Apple Music
const queueItemVariants = {
  initial: { 
    opacity: 0, 
    x: 40,
    scale: 0.97,
  },
  animate: { 
    opacity: 1, 
    x: 0,
    scale: 1,
    transition: {
      opacity: { duration: 0.25, ease: [0.25, 0.1, 0.25, 1] as const },
      x: { duration: 0.3, ease: [0.25, 0.1, 0.25, 1] as const },
      scale: { duration: 0.25, ease: [0.25, 0.1, 0.25, 1] as const },
    }
  },
  exit: { 
    opacity: 0,
    x: -60,
    scale: 0.92,
    transition: {
      opacity: { duration: 0.2, ease: [0.4, 0, 1, 1] as const },
      x: { duration: 0.25, ease: [0.4, 0, 1, 1] as const },
      scale: { duration: 0.2, ease: [0.4, 0, 1, 1] as const },
    }
  },
}

const QueueItem = ({
  song,
  onPlaySong,
  onRemoveSong,
}: {
  song: Song
  onPlaySong: (song: Song) => void
  onRemoveSong: (songId: string) => void
}) => {
  const formatDuration = (seconds: number) => {
    const minutes = Math.floor(seconds / 60)
    const secs = seconds % 60
    return `${minutes}:${secs.toString().padStart(2, '0')}`
  }

  return (
    <Reorder.Item
      key={song.id}
      value={song}
      className="flex items-center gap-2 sm:gap-3 p-2 rounded-lg hover:bg-gray-100 dark:hover:bg-white/5 cursor-grab group relative touch-manipulation"
      whileDrag={{
        backgroundColor: 'rgba(75, 85, 99, 0.8)',
        scale: 1.03,
        zIndex: 50,
        boxShadow: '0 12px 24px -4px rgba(0, 0, 0, 0.25), 0 4px 8px -2px rgba(0, 0, 0, 0.12)',
      }}
      variants={queueItemVariants}
      initial="initial"
      animate="animate"
      exit="exit"
      layout
      transition={{ 
        layout: { type: "spring", stiffness: 500, damping: 35, mass: 0.8 },
      }}
    >
      <div className="w-10 h-10 sm:w-12 sm:h-12 flex-shrink-0" onDoubleClick={() => onPlaySong(song)}>
        <AlbumCover coverArtId={song.coverArt} size={100} alt={song.album} className="rounded-md" />
      </div>
      <div className="flex-1 min-w-0" onDoubleClick={() => onPlaySong(song)}>
        <p className="text-sm sm:text-base font-semibold truncate text-gray-900 dark:text-gray-200">
          {song.title}
        </p>
        <p className="text-xs sm:text-sm text-gray-500 dark:text-gray-400 truncate">
          {song.artist}
        </p>
      </div>
      <span className="text-xs sm:text-sm text-gray-400 dark:text-gray-500 mr-1 sm:mr-2 flex-shrink-0">
        {formatDuration(song.duration)}
      </span>
      <button
        onClick={() => onRemoveSong(song.id)}
        className="p-1 opacity-100 sm:opacity-0 sm:group-hover:opacity-100 text-gray-500 dark:text-gray-400 hover:text-red-500 dark:hover:text-red-400 touch-manipulation flex-shrink-0 transition-opacity"
        aria-label="Eliminar"
      >
        <XMarkIcon className="w-4 h-4 sm:w-5 sm:h-5" />
      </button>
    </Reorder.Item>
  )
}

export default function QueuePanel({
  isOpen,
  onClose,
  queue,
  currentSong,
  onPlaySong,
  onRemoveSong,
  onClearQueue,
  onReorderQueue,
}: QueuePanelProps) {
  const [upcomingSongs, setUpcomingSongs] = useState<Song[]>([])
  // Ref para rastrear los IDs de la cola anterior y evitar re-renders innecesarios
  const prevQueueSignatureRef = useRef<string>('')

  useEffect(() => {
    // Sincronizar el estado local con la cola del reproductor
    // Solo mostramos las canciones posteriores a la actual
    const currentIndex = queue.findIndex(s => s.id === currentSong?.id)
    const newUpcoming = currentIndex >= 0 ? queue.slice(currentIndex + 1) : queue
    
    // Solo actualizar si los IDs realmente cambiaron (evita que se pierdan los covers cargados)
    const newSignature = newUpcoming.map(s => s.id).join(',')
    if (newSignature !== prevQueueSignatureRef.current) {
      prevQueueSignatureRef.current = newSignature
      setUpcomingSongs(newUpcoming)
    }
  }, [queue, currentSong])

  const handleReorder = useCallback((newUpcomingOrder: Song[]) => {
    prevQueueSignatureRef.current = newUpcomingOrder.map(s => s.id).join(',')
    setUpcomingSongs(newUpcomingOrder)
    if (currentSong) {
      const currentIndex = queue.findIndex(s => s.id === currentSong.id)
      if (currentIndex >= 0) {
        // Mantener las canciones anteriores y anexar el nuevo orden
        const previousSongs = queue.slice(0, currentIndex + 1)
        onReorderQueue([...previousSongs, ...newUpcomingOrder])
      } else {
        onReorderQueue([currentSong, ...newUpcomingOrder])
      }
    }
  }, [currentSong, queue, onReorderQueue])

  return (
    <AnimatePresence>
      {isOpen && (
        <div className="fixed inset-0 z-[9997] overflow-hidden pointer-events-none touch-none">
          <motion.div
            initial={{ x: '100%' }}
            animate={{ x: 0 }}
            exit={{ x: '100%' }}
            transition={{ type: 'spring', stiffness: 350, damping: 35 }}
            className="absolute top-0 right-0 h-full w-full sm:max-w-md bg-white dark:bg-gray-900 shadow-lg pointer-events-auto flex flex-col"
          >
            <div className="flex items-center justify-between p-3 sm:p-4 border-b border-gray-200/80 dark:border-white/[0.08] flex-shrink-0" style={{ paddingTop: 'max(0.75rem, env(safe-area-inset-top))' }}>
              <h2 className="text-base sm:text-lg font-bold text-gray-900 dark:text-white">
                A continuación
              </h2>
              <button
                onClick={onClose}
                className="p-1.5 sm:p-2 rounded-full hover:bg-gray-100 dark:hover:bg-white/[0.08] touch-manipulation"
                aria-label="Cerrar cola"
              >
                <XMarkIcon className="w-5 h-5 sm:w-6 sm:h-6 text-gray-900 dark:text-white" />
              </button>
            </div>
            <div className="overflow-y-auto p-2 sm:p-2 flex-grow" style={{ paddingBottom: 'max(0.5rem, env(safe-area-inset-bottom))' }}>
            {upcomingSongs.length > 0 && (
              <>
                <div className="flex justify-between items-center p-2">
                  <p className="text-xs sm:text-sm font-semibold text-gray-500 dark:text-gray-400">
                    Siguientes
                  </p>
                  <button
                    onClick={onClearQueue}
                    className="text-xs sm:text-sm text-blue-500 dark:text-blue-400 hover:underline touch-manipulation"
                  >
                    Limpiar
                  </button>
                </div>
                <Reorder.Group
                  axis="y"
                  values={upcomingSongs}
                  onReorder={handleReorder}
                  layoutScroll
                  className="space-y-1"
                >
                  <AnimatePresence mode="popLayout">
                    {upcomingSongs.map((song) => (
                      <QueueItem
                        key={song.id}
                        song={song}
                        onPlaySong={onPlaySong}
                        onRemoveSong={onRemoveSong}
                      />
                    ))}
                  </AnimatePresence>
                </Reorder.Group>
              </>
            )}
            {upcomingSongs.length === 0 && (
              <div className="text-center p-6 sm:p-8 text-sm sm:text-base text-gray-400 dark:text-gray-600 mt-10">
                La cola está vacía.
              </div>
            )}
          </div>
          </motion.div>
        </div>
      )}
    </AnimatePresence>
  )
}
