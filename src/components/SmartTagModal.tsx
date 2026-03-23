import { useState, useEffect } from 'react'
import { createPortal } from 'react-dom'
import { motion, AnimatePresence } from 'framer-motion'
import {
  XMarkIcon,
  CheckCircleIcon,
  ExclamationCircleIcon,
} from '@heroicons/react/24/solid'
import { Song } from '../services/navidromeApi'
import { musicApiService, SmartTagField } from '../services/musicApiService'

interface Props {
  song: Song
  onClose: () => void
}

interface FieldState {
  value: string
  loading: boolean
  result: { success: boolean; message: string } | null
}

const FIELDS: { key: SmartTagField; label: string; placeholder: string }[] = [
  { key: 'mood',     label: 'Mood',    placeholder: 'ej: happy, sad, energetic...' },
  { key: 'genre',    label: 'Género',  placeholder: 'ej: Rock, Latin Pop...' },
  { key: 'language', label: 'Idioma',  placeholder: 'ej: spa, eng...' },
]

const emptyField = (): FieldState => ({ value: '', loading: false, result: null })

export default function SmartTagModal({ song, onClose }: Props) {
  const [fields, setFields] = useState<Record<SmartTagField, FieldState>>({
    mood:     emptyField(),
    genre:    emptyField(),
    language: emptyField(),
  })
  const [loadingData, setLoadingData] = useState(true)
  const [isMobile] = useState(() => typeof window !== 'undefined' && window.innerWidth < 768)

  useEffect(() => {
    let cancelled = false
    const fetchData = async () => {
      setLoadingData(true)
      const res = await musicApiService.getSongData(song.id)
      if (!cancelled && res.success && res.tags) {
        setFields({
          mood:     { value: res.tags.mood,     loading: false, result: null },
          genre:    { value: res.tags.genre,    loading: false, result: null },
          language: { value: res.tags.language, loading: false, result: null },
        })
      }
      if (!cancelled) setLoadingData(false)
    }
    fetchData()
    return () => { cancelled = true }
  }, [song.id])

  const updateField = (key: SmartTagField, patch: Partial<FieldState>) => {
    setFields(prev => ({ ...prev, [key]: { ...prev[key], ...patch } }))
  }

  const handleSave = async (key: SmartTagField) => {
    const val = fields[key].value.trim()
    if (!val || fields[key].loading) return

    updateField(key, { loading: true, result: null })
    const res = await musicApiService.updateTag(song.id, key, val)

    updateField(key, {
      loading: false,
      result: {
        success: res.success,
        message: res.success
          ? (res.message || 'Tag actualizado.')
          : (res.error || 'Error desconocido.'),
      },
    })
  }

  const spinner = (
    <div className="w-3.5 h-3.5 border-2 border-white border-t-transparent rounded-full animate-spin" />
  )

  const loadingSpinner = (
    <div className={`flex items-center justify-center py-6 text-sm gap-2 ${
      isMobile ? 'text-white/40' : 'text-gray-500 dark:text-gray-400'
    }`}>
      <div className={`w-4 h-4 border-2 rounded-full animate-spin ${
        isMobile ? 'border-white/20 border-t-white/60' : 'border-gray-300 border-t-gray-600 dark:border-gray-600 dark:border-t-gray-300'
      }`} />
      Cargando etiquetas actuales...
    </div>
  )

  // ── Field row renderer ────────────────────────────────────────────────────────
  const renderField = (key: SmartTagField, label: string, placeholder: string) => {
    const field = fields[key]
    return (
      <div key={key} className="space-y-1.5">
        <label className={`block text-xs font-medium uppercase tracking-wide ${
          isMobile ? 'text-white/40' : 'text-gray-500 dark:text-gray-400'
        }`}>
          {label}
        </label>
        <div className="flex gap-2">
          <input
            type="text"
            value={field.value}
            onChange={(e) => updateField(key, { value: e.target.value, result: null })}
            placeholder={placeholder}
            disabled={field.loading}
            onKeyDown={(e) => {
              if (e.key === 'Enter') handleSave(key)
              if (e.key === 'Escape') onClose()
            }}
            className={isMobile
              ? 'flex-1 px-4 py-3 rounded-xl bg-white/[0.08] text-white text-[16px] placeholder-white/30 focus:outline-none focus:ring-1 focus:ring-[#0a84ff]/50 border border-white/[0.08] disabled:opacity-40'
              : 'flex-1 px-4 py-3 rounded-xl border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-[16px] placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent transition-all disabled:opacity-50'
            }
          />
          <button
            onClick={() => handleSave(key)}
            disabled={field.loading || !field.value.trim()}
            className={isMobile
              ? 'px-4 py-3 rounded-xl bg-[#0a84ff] text-white font-semibold text-[15px] disabled:opacity-40 flex items-center gap-1.5 whitespace-nowrap'
              : 'px-4 py-3 rounded-xl bg-blue-500 text-white font-semibold text-sm hover:bg-blue-600 disabled:opacity-50 transition-colors flex items-center gap-1.5 whitespace-nowrap'
            }
          >
            {field.loading ? spinner : 'Guardar'}
          </button>
        </div>

        {/* Inline feedback */}
        {field.result && (
          <div className={`flex items-center gap-1.5 text-xs px-2.5 py-2 rounded-lg ${
            field.result.success
              ? isMobile
                ? 'bg-green-500/15 text-green-400'
                : 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400'
              : isMobile
                ? 'bg-red-500/15 text-red-400'
                : 'bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-400'
          }`}>
            {field.result.success
              ? <CheckCircleIcon className="w-3.5 h-3.5 flex-shrink-0" />
              : <ExclamationCircleIcon className="w-3.5 h-3.5 flex-shrink-0" />}
            <span>{field.result.message}</span>
          </div>
        )}
      </div>
    )
  }

  // ── Mobile: iOS bottom sheet ─────────────────────────────────────────────────
  if (isMobile) {
    return createPortal(
      <>
        <div
          className="fixed inset-0 z-[10000] bg-black/60 ctx-backdrop"
          onClick={onClose}
        />
        <motion.div
          key="stm-sheet"
          initial={{ y: '100%' }}
          animate={{ y: 0 }}
          exit={{ y: '100%' }}
          transition={{ type: 'spring', damping: 32, stiffness: 320 }}
          className="fixed bottom-0 left-0 right-0 z-[10001] bg-[#1c1c1e] rounded-t-[20px] overflow-hidden"
          style={{ paddingBottom: 'env(safe-area-inset-bottom)' }}
        >
          {/* Header */}
          <div className="flex items-center justify-between px-5 pt-5 pb-4 border-b border-white/[0.08]">
            <h2 className="text-white font-semibold text-[17px]">Editar etiquetas</h2>
            <button
              onClick={onClose}
              className="text-[#0a84ff] font-medium text-[17px]"
            >
              Listo
            </button>
          </div>

          {/* Body */}
          <div className="px-5 py-4 space-y-4">
            {/* Song info */}
            <div>
              <p className="text-white text-sm font-semibold truncate">{song.title}</p>
              <p className="text-white/50 text-xs truncate">{song.artist}</p>
            </div>

            {loadingData
              ? loadingSpinner
              : FIELDS.map(({ key, label, placeholder }) => renderField(key, label, placeholder))
            }
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
          className="relative w-full max-w-md bg-white dark:bg-gray-900 rounded-2xl shadow-2xl border border-gray-200 dark:border-gray-800 overflow-hidden"
        >
          {/* Header */}
          <div className="flex items-center justify-between px-6 py-4 border-b border-gray-200 dark:border-gray-800">
            <h2 className="text-base font-semibold text-gray-900 dark:text-white">
              Editar etiquetas
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

            {loadingData
              ? loadingSpinner
              : FIELDS.map(({ key, label, placeholder }) => renderField(key, label, placeholder))
            }
          </div>

          {/* Footer */}
          <div className="flex justify-end px-6 py-4 border-t border-gray-200 dark:border-gray-800 bg-gray-50 dark:bg-gray-800/50">
            <button
              onClick={onClose}
              className="px-5 py-3 text-sm rounded-xl border border-gray-300 dark:border-gray-700 text-gray-700 dark:text-gray-300 font-semibold hover:bg-gray-100 dark:hover:bg-gray-800 transition-colors"
            >
              Cerrar
            </button>
          </div>
        </motion.div>
      </motion.div>
    </AnimatePresence>,
    document.body
  )
}
