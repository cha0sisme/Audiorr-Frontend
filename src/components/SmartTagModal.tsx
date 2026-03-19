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

  // Cargar los tags actuales desde Music-API al abrir el modal
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
              Editar etiquetas
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

            {loadingData ? (
              <div className="flex items-center justify-center py-6 text-gray-500 dark:text-gray-400 text-sm gap-2">
                <svg className="w-4 h-4 animate-spin" viewBox="0 0 24 24" fill="none">
                  <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                  <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z" />
                </svg>
                Cargando etiquetas actuales...
              </div>
            ) : (
              FIELDS.map(({ key, label, placeholder }) => {
                const field = fields[key]
                return (
                  <div key={key} className="space-y-1">
                    <label className="block text-xs font-medium text-gray-600 dark:text-gray-400 uppercase tracking-wide">
                      {label}
                    </label>
                    <div className="flex gap-2">
                      <input
                        type="text"
                        value={field.value}
                        onChange={(e) => updateField(key, { value: e.target.value, result: null })}
                        placeholder={placeholder}
                        disabled={field.loading}
                        className="flex-1 px-3 py-2 rounded-lg bg-gray-100 dark:bg-gray-800 border border-gray-300 dark:border-gray-600 text-gray-900 dark:text-white text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 transition placeholder-gray-400 dark:placeholder-gray-600"
                        onKeyDown={(e) => {
                          if (e.key === 'Enter') handleSave(key)
                          if (e.key === 'Escape') onClose()
                        }}
                      />
                      <button
                        onClick={() => handleSave(key)}
                        disabled={field.loading || !field.value.trim()}
                        className="px-3 py-2 text-sm rounded-lg bg-blue-600 hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed text-white font-medium transition-colors flex items-center gap-1.5 whitespace-nowrap"
                      >
                        {field.loading ? (
                          <svg className="w-3.5 h-3.5 animate-spin" viewBox="0 0 24 24" fill="none">
                            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z" />
                          </svg>
                        ) : 'Guardar'}
                      </button>
                    </div>

                    <AnimatePresence>
                      {field.result && (
                        <motion.div
                          key={`${key}-feedback`}
                          initial={{ opacity: 0, height: 0 }}
                          animate={{ opacity: 1, height: 'auto' }}
                          exit={{ opacity: 0, height: 0 }}
                          className={`flex items-center gap-1.5 text-xs px-2 py-1.5 rounded-md ${
                            field.result.success
                              ? 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400'
                              : 'bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-400'
                          }`}
                        >
                          {field.result.success
                            ? <CheckCircleIcon className="w-3.5 h-3.5 flex-shrink-0" />
                            : <ExclamationCircleIcon className="w-3.5 h-3.5 flex-shrink-0" />}
                          <span>{field.result.message}</span>
                        </motion.div>
                      )}
                    </AnimatePresence>
                  </div>
                )
              })
            )}
          </div>

          {/* Footer */}
          <div className="flex justify-end px-5 py-3 border-t border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800/50">
            <button
              onClick={onClose}
              className="px-4 py-2 text-sm rounded-lg text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
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
