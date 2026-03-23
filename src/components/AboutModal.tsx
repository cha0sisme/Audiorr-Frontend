import { useEffect } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import { XMarkIcon } from '@heroicons/react/24/outline'

const BUILD_DATE = typeof __BUILD_DATE__ === 'string' ? __BUILD_DATE__ : ''
const BUILD_ID = typeof __BUILD_ID__ === 'string' ? __BUILD_ID__ : ''

interface AboutModalProps {
  isOpen: boolean
  onClose: () => void
}

export function AboutModal({ isOpen, onClose }: AboutModalProps) {
  useEffect(() => {
    if (!isOpen) return

    const handleEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }

    document.addEventListener('keydown', handleEscape)
    document.body.style.overflow = 'hidden'

    return () => {
      document.removeEventListener('keydown', handleEscape)
      document.body.style.overflow = 'unset'
    }
  }, [isOpen, onClose])

  return (
    <AnimatePresence>
      {isOpen && (
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.2 }}
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-xl"
          onClick={onClose}
        >
          <motion.div
            initial={{ opacity: 0, scale: 0.94, y: 12 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            exit={{ opacity: 0, scale: 0.94, y: 12 }}
            transition={{ duration: 0.25, ease: [0.16, 1, 0.3, 1] }}
            className="relative w-full max-w-sm mx-4 bg-white/10 dark:bg-white/5 backdrop-blur-2xl rounded-3xl shadow-2xl border border-white/20 dark:border-white/10 overflow-hidden"
            onClick={e => e.stopPropagation()}
          >
            {/* Botón cerrar */}
            <button
              onClick={onClose}
              className="absolute top-4 right-4 z-10 p-1.5 rounded-full bg-white/10 hover:bg-white/20 transition-colors"
              aria-label="Cerrar"
            >
              <XMarkIcon className="w-4 h-4 text-white/70" />
            </button>

            {/* Contenido */}
            <div className="px-8 pt-12 pb-8 flex flex-col items-center text-center">
              {/* Icono */}
              <div className="mb-6 w-24 h-24 rounded-[22px] overflow-hidden shadow-xl shadow-black/40">
                <img
                  src="/assets/logo.png"
                  alt="Audiorr"
                  className="w-full h-full object-cover"
                  onError={e => {
                    e.currentTarget.style.display = 'none'
                    e.currentTarget.parentElement!.classList.add(
                      'bg-gradient-to-br', 'from-blue-500', 'to-purple-600',
                      'flex', 'items-center', 'justify-center'
                    )
                    const span = document.createElement('span')
                    span.className = 'text-4xl font-bold text-white'
                    span.textContent = 'A'
                    e.currentTarget.parentElement!.appendChild(span)
                  }}
                />
              </div>

              {/* Nombre */}
              <h1
                className="text-4xl text-white mb-1"
                style={{ fontFamily: "'Space Grotesk', sans-serif", fontWeight: 900, letterSpacing: '-0.03em' }}
              >
                Audiorr
              </h1>

              {/* Fecha de build */}
              {BUILD_DATE && (
                <p className="text-sm text-white/50 mb-4">
                  {BUILD_DATE}
                </p>
              )}

              {/* Build ID badge */}
              {BUILD_ID && (
                <div className="inline-flex items-center gap-1.5 px-3 py-1 rounded-full bg-white/10 border border-white/15 mb-8">
                  <svg className="w-3 h-3 text-white/50" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M17.25 6.75 22.5 12l-5.25 5.25m-10.5 0L1.5 12l5.25-5.25m7.5-3-4.5 16.5" />
                  </svg>
                  <span className="text-xs font-mono text-white/50">
                    build {BUILD_ID}
                  </span>
                </div>
              )}

              {/* Footer */}
              <p className="text-xs text-white/30">
                Made with <span className="text-red-500">&hearts;</span> by Leandro PB
              </p>
            </div>
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  )
}
