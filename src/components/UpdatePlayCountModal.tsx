import { useState, useEffect } from 'react'
import { createPortal } from 'react-dom'
import { motion, AnimatePresence } from 'framer-motion'
import { XMarkIcon, CheckCircleIcon, ExclamationCircleIcon } from '@heroicons/react/24/solid'
import { Song } from '../services/navidromeApi'
import { musicApiService } from '../services/musicApiService'

interface Props {
  song: Song
  onClose: () => void
}

export default function UpdatePlayCountModal({ song, onClose }: Props) {
  const [playCount, setPlayCount] = useState<number>(song.playCount ?? 0)
  const [loading, setLoading] = useState(false)
  const [loadingData, setLoadingData] = useState(true)
  const [result, setResult] = useState<{ success: boolean; message: string } | null>(null)

  // Cargar el play count real desde Music-API al abrir el modal
  useEffect(() => {
    let cancelled = false
    const fetchData = async () => {
      setLoadingData(true)
      const res = await musicApiService.getSongData(song.id)
      if (!cancelled && res.success && res.play_count !== undefined) {
        setPlayCount(res.play_count)
      }
      if (!cancelled) setLoadingData(false)
    }
    fetchData()
    return () => { cancelled = true }
  }, [song.id])

  const handleSave = async () => {
    if (loading) return
    setLoading(true)
    setResult(null)

    const res = await musicApiService.updatePlayCount(song.id, playCount)

    if (res.success) {
      setResult({ success: true, message: res.message || 'Reproducciones actualizadas con éxito.' })
    } else {
      setResult({ success: false, message: res.error || 'Error desconocido.' })
    }
    setLoading(false)
  }

  return createPortal(
    <AnimatePresence>
      <motion.div
        key="overlay"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0 }}
        className="fixed inset-0 z-[10000] flex items-center justify-center bg-black/60 backdrop-blur-sm"
        onClick={(e) => { if (e.target === e.currentTarget) onClose() }}
      >
        <motion.div
          key="modal"
          initial={{ opacity: 0, scale: 0.95, y: 10 }}
          animate={{ opacity: 1, scale: 1, y: 0 }}
          exit={{ opacity: 0, scale: 0.95, y: 10 }}
          transition={{ duration: 0.15 }}
          onClick={(e) => e.stopPropagation()}
          className="relative w-full max-w-sm mx-4 bg-white dark:bg-gray-900 rounded-xl shadow-2xl border border-gray-200 dark:border-gray-700 overflow-hidden"
        >
          {/* Header */}
          <div className="flex items-center justify-between px-5 py-4 border-b border-gray-200 dark:border-gray-700">
            <h2 className="text-base font-semibold text-gray-900 dark:text-white">
              Actualizar reproducciones
            </h2>
            <button
              onClick={onClose}
              className="p-1 rounded-md text-gray-500 hover:text-gray-800 dark:hover:text-white hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
            >
              <XMarkIcon className="w-5 h-5" />
            </button>
          </div>

          {/* Body */}
          <div className="px-5 py-4 space-y-4">
            <div className="text-sm">
              <p className="font-medium text-gray-800 dark:text-gray-100 truncate">{song.title}</p>
              <p className="text-gray-500 dark:text-gray-400 truncate">{song.artist}</p>
            </div>

            <div className="space-y-1">
              <label
                htmlFor="playcount-input"
                className="block text-xs font-medium text-gray-600 dark:text-gray-400 uppercase tracking-wide"
              >
                {loadingData ? 'Cargando...' : `Reproducciones actuales: ${playCount}`}
              </label>
              <input
                id="playcount-input"
                type="number"
                min={0}
                value={playCount}
                onChange={(e) => {
                  const val = parseInt(e.target.value, 10)
                  if (!isNaN(val) && val >= 0) setPlayCount(val)
                }}
                className="w-full px-3 py-2 rounded-lg bg-gray-100 dark:bg-gray-800 border border-gray-300 dark:border-gray-600 text-gray-900 dark:text-white text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 transition"
                disabled={loading || loadingData}
                autoFocus
                onKeyDown={(e) => {
                  if (e.key === 'Enter') handleSave()
                  if (e.key === 'Escape') onClose()
                }}
              />
            </div>

            <AnimatePresence>
              {result && (
                <motion.div
                  key="feedback"
                  initial={{ opacity: 0, y: -4 }}
                  animate={{ opacity: 1, y: 0 }}
                  exit={{ opacity: 0 }}
                  className={`flex items-center gap-2 text-sm px-3 py-2 rounded-lg ${
                    result.success
                      ? 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400'
                      : 'bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-400'
                  }`}
                >
                  {result.success
                    ? <CheckCircleIcon className="w-4 h-4 flex-shrink-0" />
                    : <ExclamationCircleIcon className="w-4 h-4 flex-shrink-0" />}
                  <span>{result.message}</span>
                </motion.div>
              )}
            </AnimatePresence>
          </div>

          {/* Footer */}
          <div className="flex items-center justify-end gap-2 px-5 py-3 border-t border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800/50">
            <button
              onClick={onClose}
              className="px-4 py-2 text-sm rounded-lg text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
            >
              {result?.success ? 'Cerrar' : 'Cancelar'}
            </button>
            {!result?.success && (
              <button
                onClick={handleSave}
                disabled={loading || loadingData}
                className="px-4 py-2 text-sm rounded-lg bg-blue-600 hover:bg-blue-700 disabled:opacity-60 text-white font-medium transition-colors flex items-center gap-2"
              >
                {loading && (
                  <svg className="w-3.5 h-3.5 animate-spin" viewBox="0 0 24 24" fill="none">
                    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z" />
                  </svg>
                )}
                {loading ? 'Guardando...' : 'Guardar'}
              </button>
            )}
          </div>
        </motion.div>
      </motion.div>
    </AnimatePresence>,
    document.body
  )
}
