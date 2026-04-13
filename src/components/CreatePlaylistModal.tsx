import { useState, useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import { motion, AnimatePresence } from 'framer-motion'
import { XMarkIcon } from '@heroicons/react/24/solid'
import { Capacitor } from '@capacitor/core'

interface CreatePlaylistModalProps {
  isOpen: boolean
  onClose: () => void
  onConfirm: (name: string, description?: string) => Promise<void>
}

export default function CreatePlaylistModal({ isOpen, onClose, onConfirm }: CreatePlaylistModalProps) {
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [isCreating, setIsCreating] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const [isMobile] = useState(() => typeof window !== 'undefined' && window.innerWidth < 768)

  useEffect(() => {
    if (isOpen) {
      setName('')
      setDescription('')
      setError(null)
      setIsCreating(false)
      setTimeout(() => { inputRef.current?.focus() }, 150)
    }
  }, [isOpen])

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    const trimmedName = name.trim()
    if (!trimmedName) { setError('El nombre de la playlist es requerido'); return }
    if (trimmedName.length < 2) { setError('El nombre debe tener al menos 2 caracteres'); return }
    setIsCreating(true)
    setError(null)
    try {
      await onConfirm(trimmedName, description.trim() || undefined)
      onClose()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Error al crear la playlist')
      setIsCreating(false)
    }
  }

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Escape' && !isCreating) onClose()
  }

  // ── Mobile: iOS bottom sheet ─────────────────────────────────────────────────
  if (isMobile) {
    return createPortal(
      <AnimatePresence>
        {isOpen && (
          <>
            <motion.div
              key="cpm-backdrop"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              className="fixed inset-0 z-[10000] bg-black/60"
              onClick={!isCreating ? onClose : undefined}
            />
            <motion.div
              key="cpm-sheet"
              initial={{ y: '100%' }}
              animate={{ y: 0 }}
              exit={{ y: '100%' }}
              transition={{ type: 'spring', damping: 32, stiffness: 320 }}
              className="fixed bottom-0 left-0 right-0 z-[10001] bg-[#1c1c1e] rounded-t-[20px] overflow-hidden"
              style={{
                paddingBottom: Capacitor.isNativePlatform()
                  ? 'calc(env(safe-area-inset-bottom) + 130px)'
                  : 'env(safe-area-inset-bottom)',
              }}
              onKeyDown={handleKeyDown}
            >
              <div className="flex items-center justify-between px-5 pt-5 pb-4 border-b border-white/[0.08]">
                <h2 className="text-white font-semibold text-[17px]">Nueva Playlist</h2>
                <button
                  onClick={!isCreating ? onClose : undefined}
                  disabled={isCreating}
                  className="text-[#0a84ff] font-medium text-[17px] disabled:opacity-40"
                >
                  Cancelar
                </button>
              </div>
              <form onSubmit={handleSubmit} className="px-5 py-4 space-y-3">
                <input
                  ref={inputRef}
                  type="text"
                  value={name}
                  onChange={e => setName(e.target.value)}
                  disabled={isCreating}
                  maxLength={100}
                  placeholder="Nombre de la playlist"
                  className="w-full px-4 py-3 rounded-xl bg-white/[0.08] text-white placeholder-white/30 focus:outline-none focus:ring-1 focus:ring-[#0a84ff]/50 border border-white/[0.08]"
                />
                <textarea
                  value={description}
                  onChange={e => setDescription(e.target.value)}
                  disabled={isCreating}
                  maxLength={300}
                  rows={2}
                  placeholder="Descripción (opcional)"
                  className="w-full px-4 py-3 rounded-xl bg-white/[0.08] text-white placeholder-white/30 focus:outline-none focus:ring-1 focus:ring-[#0a84ff]/50 border border-white/[0.08] resize-none"
                />
                {error && <p className="text-red-400 text-sm px-1">{error}</p>}
                <button
                  type="submit"
                  disabled={isCreating || !name.trim()}
                  className="w-full py-4 rounded-xl bg-[#0a84ff] text-white font-semibold text-[17px] disabled:opacity-40 flex items-center justify-center gap-2 mt-2"
                >
                  {isCreating ? (
                    <><div className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin" /><span>Creando...</span></>
                  ) : 'Crear Playlist'}
                </button>
              </form>
            </motion.div>
          </>
        )}
      </AnimatePresence>,
      document.body
    )
  }

  // ── Desktop: centered modal ──────────────────────────────────────────────────
  if (!isOpen) return null

  return createPortal(
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/50 backdrop-blur-sm animate-in fade-in duration-200"
      onClick={(e) => { if (e.target === e.currentTarget && !isCreating) onClose() }}
    >
      <div
        className="bg-white dark:bg-gray-900 rounded-2xl shadow-2xl w-full max-w-md overflow-hidden animate-in zoom-in-95 duration-200"
        onKeyDown={handleKeyDown}
      >
        <div className="flex items-center justify-between px-6 py-4 border-b border-gray-200 dark:border-gray-800">
          <h2 className="text-xl font-bold text-gray-900 dark:text-white">Nueva Playlist</h2>
          <button
            onClick={onClose}
            disabled={isCreating}
            className="rounded-full p-2 text-gray-500 hover:text-gray-700 hover:bg-gray-100 dark:text-gray-400 dark:hover:text-gray-200 dark:hover:bg-gray-800 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            aria-label="Cerrar"
          >
            <XMarkIcon className="w-5 h-5" />
          </button>
        </div>
        <form onSubmit={handleSubmit} className="p-6 space-y-4">
          <div>
            <label htmlFor="playlist-name" className="block text-sm font-semibold text-gray-700 dark:text-gray-300 mb-2">
              Nombre <span className="text-red-500">*</span>
            </label>
            <input
              ref={inputRef}
              id="playlist-name"
              type="text"
              value={name}
              onChange={e => setName(e.target.value)}
              disabled={isCreating}
              maxLength={100}
              placeholder="Mi Playlist Increíble"
              className="w-full px-4 py-3 rounded-xl border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent transition-all disabled:opacity-50 disabled:cursor-not-allowed"
            />
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{name.length}/100 caracteres</p>
          </div>
          <div>
            <label htmlFor="playlist-description" className="block text-sm font-semibold text-gray-700 dark:text-gray-300 mb-2">
              Descripción <span className="text-gray-400 text-xs font-normal">(opcional)</span>
            </label>
            <textarea
              id="playlist-description"
              value={description}
              onChange={e => setDescription(e.target.value)}
              disabled={isCreating}
              maxLength={300}
              rows={3}
              placeholder="Una colección de mis canciones favoritas..."
              className="w-full px-4 py-3 rounded-xl border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent transition-all resize-none disabled:opacity-50 disabled:cursor-not-allowed"
            />
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{description.length}/300 caracteres</p>
          </div>
          {error && (
            <div className="p-3 rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800">
              <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
            </div>
          )}
          <div className="flex items-center gap-3 pt-2">
            <button
              type="button"
              onClick={onClose}
              disabled={isCreating}
              className="flex-1 px-4 py-3 rounded-xl border border-gray-300 dark:border-gray-700 text-gray-700 dark:text-gray-300 font-semibold hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              Cancelar
            </button>
            <button
              type="submit"
              disabled={isCreating || !name.trim()}
              className="flex-1 px-4 py-3 rounded-xl bg-blue-500 text-white font-semibold hover:bg-blue-600 transition-colors disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2"
            >
              {isCreating ? (
                <><div className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin" /><span>Creando...</span></>
              ) : 'Crear Playlist'}
            </button>
          </div>
        </form>
      </div>
    </div>,
    document.body
  )
}
