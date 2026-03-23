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
  const [isMobile] = useState(() => typeof window !== 'undefined' && window.innerWidth < 768)

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

  const handleInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const val = parseInt(e.target.value, 10)
    if (!isNaN(val) && val >= 0) setPlayCount(val)
  }

  const spinner = (
    <div className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin" />
  )

  // ── Feedback banner ──────────────────────────────────────────────────────────
  const feedbackBanner = result && (
    <div className={`flex items-center gap-2 text-sm px-3 py-2.5 rounded-xl ${
      result.success
        ? isMobile
          ? 'bg-green-500/15 text-green-400'
          : 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400'
        : isMobile
          ? 'bg-red-500/15 text-red-400'
          : 'bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-400'
    }`}>
      {result.success
        ? <CheckCircleIcon className="w-4 h-4 flex-shrink-0" />
        : <ExclamationCircleIcon className="w-4 h-4 flex-shrink-0" />}
      <span>{result.message}</span>
    </div>
  )

  // ── Mobile: iOS bottom sheet ─────────────────────────────────────────────────
  if (isMobile) {
    return createPortal(
      <>
        <div
          className="fixed inset-0 z-[10000] bg-black/60 ctx-backdrop"
          onClick={onClose}
        />
        <motion.div
          key="upc-sheet"
          initial={{ y: '100%' }}
          animate={{ y: 0 }}
          exit={{ y: '100%' }}
          transition={{ type: 'spring', damping: 32, stiffness: 320 }}
          className="fixed bottom-0 left-0 right-0 z-[10001] bg-[#1c1c1e] rounded-t-[20px] overflow-hidden"
          style={{ paddingBottom: 'env(safe-area-inset-bottom)' }}
        >
          {/* Header */}
          <div className="flex items-center justify-between px-5 pt-5 pb-4 border-b border-white/[0.08]">
            <h2 className="text-white font-semibold text-[17px]">Actualizar reproducciones</h2>
            <button
              onClick={onClose}
              disabled={loading}
              className="text-[#0a84ff] font-medium text-[17px] disabled:opacity-40"
            >
              {result?.success ? 'Listo' : 'Cancelar'}
            </button>
          </div>

          {/* Body */}
          <div className="px-5 py-4 space-y-4">
            {/* Song info */}
            <div>
              <p className="text-white text-sm font-semibold truncate">{song.title}</p>
              <p className="text-white/50 text-xs truncate">{song.artist}</p>
            </div>

            {/* Input */}
            <div className="space-y-1.5">
              <label className="block text-xs font-medium text-white/40 uppercase tracking-wide">
                {loadingData ? 'Cargando...' : `Reproducciones actuales: ${playCount}`}
              </label>
              <input
                type="number"
                inputMode="numeric"
                min={0}
                value={playCount}
                onChange={handleInputChange}
                disabled={loading || loadingData}
                autoFocus
                onKeyDown={(e) => {
                  if (e.key === 'Enter') handleSave()
                  if (e.key === 'Escape') onClose()
                }}
                className="w-full px-4 py-3 rounded-xl bg-white/[0.08] text-white text-[16px] placeholder-white/30 focus:outline-none focus:ring-1 focus:ring-[#0a84ff]/50 border border-white/[0.08] disabled:opacity-40"
              />
            </div>

            {/* Feedback */}
            {feedbackBanner}

            {/* Save button */}
            {!result?.success && (
              <button
                onClick={handleSave}
                disabled={loading || loadingData}
                className="w-full py-4 rounded-xl bg-[#0a84ff] text-white font-semibold text-[17px] disabled:opacity-40 flex items-center justify-center gap-2"
              >
                {loading ? <>{spinner}<span>Guardando...</span></> : 'Guardar'}
              </button>
            )}
          </div>
        </motion.div>
      </>,
      document.body
    )
  }

  // ── Desktop: centered modal ────────────────────────────────────────────────
  return createPortal(
    <AnimatePresence>
      <motion.div
        key="overlay"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0 }}
        className="fixed inset-0 z-[10000] flex items-center justify-center p-4 bg-black/50 backdrop-blur-sm"
        onClick={(e) => { if (e.target === e.currentTarget) onClose() }}
      >
        <motion.div
          key="modal"
          initial={{ opacity: 0, scale: 0.95, y: 10 }}
          animate={{ opacity: 1, scale: 1, y: 0 }}
          exit={{ opacity: 0, scale: 0.95, y: 10 }}
          transition={{ duration: 0.15 }}
          onClick={(e) => e.stopPropagation()}
          className="relative w-full max-w-sm bg-white dark:bg-gray-900 rounded-2xl shadow-2xl border border-gray-200 dark:border-gray-800 overflow-hidden"
        >
          {/* Header */}
          <div className="flex items-center justify-between px-6 py-4 border-b border-gray-200 dark:border-gray-800">
            <h2 className="text-base font-semibold text-gray-900 dark:text-white">
              Actualizar reproducciones
            </h2>
            <button
              onClick={onClose}
              className="rounded-full p-2 text-gray-500 hover:text-gray-700 hover:bg-gray-100 dark:text-gray-400 dark:hover:text-gray-200 dark:hover:bg-gray-800 transition-colors"
            >
              <XMarkIcon className="w-5 h-5" />
            </button>
          </div>

          {/* Body */}
          <div className="px-6 py-5 space-y-4">
            <div className="text-sm">
              <p className="font-medium text-gray-800 dark:text-gray-100 truncate">{song.title}</p>
              <p className="text-gray-500 dark:text-gray-400 truncate">{song.artist}</p>
            </div>

            <div className="space-y-1.5">
              <label
                htmlFor="playcount-input"
                className="block text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide"
              >
                {loadingData ? 'Cargando...' : `Reproducciones actuales: ${playCount}`}
              </label>
              <input
                id="playcount-input"
                type="number"
                min={0}
                value={playCount}
                onChange={handleInputChange}
                className="w-full px-4 py-3 rounded-xl border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-[16px] focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent transition-all disabled:opacity-50"
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
                >
                  {feedbackBanner}
                </motion.div>
              )}
            </AnimatePresence>
          </div>

          {/* Footer */}
          <div className="flex items-center gap-3 px-6 py-4 border-t border-gray-200 dark:border-gray-800 bg-gray-50 dark:bg-gray-800/50">
            <button
              onClick={onClose}
              className="flex-1 px-4 py-3 text-sm rounded-xl border border-gray-300 dark:border-gray-700 text-gray-700 dark:text-gray-300 font-semibold hover:bg-gray-100 dark:hover:bg-gray-800 transition-colors"
            >
              {result?.success ? 'Cerrar' : 'Cancelar'}
            </button>
            {!result?.success && (
              <button
                onClick={handleSave}
                disabled={loading || loadingData}
                className="flex-1 px-4 py-3 text-sm rounded-xl bg-blue-500 text-white font-semibold hover:bg-blue-600 transition-colors disabled:opacity-50 flex items-center justify-center gap-2"
              >
                {loading ? <>{spinner}<span>Guardando...</span></> : 'Guardar'}
              </button>
            )}
          </div>
        </motion.div>
      </motion.div>
    </AnimatePresence>,
    document.body
  )
}
