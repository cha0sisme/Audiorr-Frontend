import { useEffect, useRef, useState } from 'react'
import { XMarkIcon } from '@heroicons/react/24/outline'
import Canvas from './Canvas'
import { AnimatePresence, motion } from 'framer-motion'

interface CanvasPanelProps {
  isOpen: boolean
  onClose: () => void
  canvasUrl: string | null
  isLoading: boolean
  songTitle?: string
  songArtist?: string
}

function PanelHeader({
  songTitle,
  songArtist,
  onClose,
  isVisible,
}: {
  songTitle?: string
  songArtist?: string
  onClose: () => void
  isVisible: boolean
}) {
  return (
    <div className="flex items-center justify-between p-4 border-b border-gray-800/60 dark:border-gray-700/60">
      <div className="flex-1 min-w-0">
        {songTitle && (
          <h3 className="text-white font-semibold text-lg truncate drop-shadow-[0_2px_8px_rgba(0,0,0,0.45)]">
            {songTitle}
          </h3>
        )}
        {songArtist && (
          <p className="text-gray-400 text-sm truncate drop-shadow-[0_1px_6px_rgba(0,0,0,0.35)] mt-0.5">
            {songArtist}
          </p>
        )}
      </div>
      <button
        onClick={onClose}
        className={`ml-4 p-2 text-gray-300 hover:text-white transition-all duration-300 ease-out rounded-full bg-white/5 hover:bg-white/10 backdrop-blur-sm ${
          isVisible
            ? 'opacity-100 translate-x-0 pointer-events-auto'
            : 'opacity-0 -translate-x-2 pointer-events-none'
        }`}
        aria-label="Cerrar Canvas"
      >
        <XMarkIcon className="w-5 h-5" />
      </button>
    </div>
  )
}

export default function CanvasPanel({
  isOpen,
  onClose,
  canvasUrl,
  isLoading,
  songTitle,
  songArtist,
}: CanvasPanelProps) {
  const panelRef = useRef<HTMLDivElement>(null)
  const [isHovering, setIsHovering] = useState(false)

  // Cerrar con Escape
  useEffect(() => {
    const handleEscape = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && isOpen) {
        onClose()
      }
    }

    document.addEventListener('keydown', handleEscape)
    return () => document.removeEventListener('keydown', handleEscape)
  }, [isOpen, onClose])

  return (
    <AnimatePresence>
      {isOpen && (
        <>
          {/* Overlay */}
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.2 }}
            className="fixed inset-0 bg-black/35 backdrop-blur-sm z-40"
            onClick={onClose}
          />

          {/* Panel de Canvas */}
          <motion.div
            ref={panelRef}
            initial={{ x: '100%' }}
            animate={{ x: 0 }}
            exit={{ x: '100%' }}
            transition={{ type: 'spring', damping: 30, stiffness: 300 }}
            className="fixed top-0 right-0 h-full w-80 bg-gray-900 dark:bg-gray-950 z-50 shadow-2xl flex flex-col"
            onMouseEnter={() => setIsHovering(true)}
            onMouseLeave={() => setIsHovering(false)}
          >
            {/* Header */}
            <PanelHeader
              songTitle={songTitle}
              songArtist={songArtist}
              onClose={onClose}
              isVisible={isHovering}
            />

            {/* Canvas Container - Formato vertical */}
            <div className="flex-1 flex items-center justify-center p-4 overflow-hidden">
              {isLoading ? (
                <div className="w-full max-w-xs aspect-[9/16] bg-gray-800 rounded-lg flex items-center justify-center">
                  <div className="w-8 h-8 border-2 border-gray-600 border-t-transparent rounded-full animate-spin" />
                </div>
              ) : canvasUrl ? (
                <div className="w-full max-w-xs aspect-[9/16]">
                  <Canvas canvasUrl={canvasUrl} isLoading={false} className="w-full h-full" />
                </div>
              ) : (
                <div className="w-full max-w-xs aspect-[9/16] bg-gray-800 rounded-lg flex items-center justify-center">
                  <p className="text-gray-500 text-sm text-center px-4">
                    No hay Canvas disponible para esta canción
                  </p>
                </div>
              )}
            </div>
          </motion.div>
        </>
      )}
    </AnimatePresence>
  )
}
