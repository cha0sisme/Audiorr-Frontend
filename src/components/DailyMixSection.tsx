import { useEffect, useRef, useState } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import { backendApi, DailyMix } from '../services/backendApi'
import { navidromeApi } from '../services/navidromeApi'
import { ArrowPathIcon } from '@heroicons/react/24/outline'
import { usePlayerState } from '../contexts/PlayerContext'
import { useBackendAvailable } from '../contexts/BackendAvailableContext'
import { usePinnedPlaylists } from '../hooks/usePinnedPlaylists'
import { PlaylistItem } from './PlaylistsPage'
import { Playlist } from '../services/navidromeApi'
import HorizontalScrollSection from './HorizontalScrollSection'

export default function DailyMixSection({ format = 'home' }: { format?: 'home' | 'playlists' }) {
  const hadCache = useRef<boolean>(
    (() => { try { return !!sessionStorage.getItem('audiorr:dailyMixes') } catch { return false } })()
  )
  const [mixes, setMixes] = useState<DailyMix[]>(() => {
    try {
      const cached = sessionStorage.getItem('audiorr:dailyMixes')
      return cached ? JSON.parse(cached) : []
    } catch { return [] }
  })
  const [loading, setLoading] = useState(() => {
    try {
      return !sessionStorage.getItem('audiorr:dailyMixes')
    } catch { return true }
  })
  const [generating, setGenerating] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const playerState = usePlayerState()

  const backendAvailable = useBackendAvailable()
  const hasFetched = useRef(false)
  const { isPinned, togglePinnedPlaylist } = usePinnedPlaylists()

  const loadAndMaybeGenerate = async () => {
    try {
      if (!mixes.length) setLoading(true)
      const config = navidromeApi.getConfig()
      let data = await backendApi.getDailyMixes(config)
      
      // Auto-generación inicial si el usuario no tiene mezclas
      if (data.length === 0) {
        setGenerating(true)
        try {
          const result = await backendApi.generateDailyMixes(config)
          if (result.generated > 0) {
            // Volver a obtener la lista ahora que ya se generaron
            data = await backendApi.getDailyMixes(config)
          }
          // Si reason === 'insufficient_data', `data` seguirá siendo []
          // y le mostraremos su respectiva UI vacía.
        } catch (err) {
          console.error('[DailyMixSection] Auto-gen failed:', err)
        } finally {
          setGenerating(false)
        }
      }

      setMixes(data)
      try { sessionStorage.setItem('audiorr:dailyMixes', JSON.stringify(data)) } catch { /* ignorar quota */ }
    } catch (err) {
      console.error('[DailyMixSection] Failed to load mixes:', err)
      setError('No se pudieron cargar los mixes diarios.')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    if (!backendAvailable) {
      hasFetched.current = false
      return
    }
    if (hasFetched.current) return
    hasFetched.current = true
    loadAndMaybeGenerate()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [backendAvailable])

  const handleGenerate = async () => {
    try {
      setGenerating(true)
      setError(null)
      const config = navidromeApi.getConfig()
      const result = await backendApi.generateDailyMixes(config)
      
      if (result.generated === 0 && result.reason === 'insufficient_data') {
        setError('No hay suficientes datos musicales para generar mixes. ¡Sigue escuchando música!')
      } else {
        navidromeApi.invalidatePlaylistsCache()
        const newData = await backendApi.getDailyMixes(config)
        setMixes(newData)
      }
    } catch (err) {
      console.error('[DailyMixSection] Failed to generate mixes:', err)
      setError('Hubo un error al generar los mixes.')
    } finally {
      setGenerating(false)
    }
  }

  // Si el usuario no tiene mezclas, le mostramos el panel de bienvenida
  // donde podrá usar el botón para actualizarlos por primera vez.

  return (
    <section className="animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="flex flex-col sm:flex-row sm:items-end justify-between gap-4 mb-4">
        {format === 'home' ? (
          <div>
            <h2 className="text-2xl md:text-3xl font-bold text-gray-900 dark:text-white">
              Tus mixes diarios
            </h2>
          </div>
        ) : (
          <div>
            <p className="text-gray-600 dark:text-gray-300 font-medium">Tus mixes diarios</p>
          </div>
        )}

        {mixes.length === 0 && (
          <button
            onClick={handleGenerate}
            disabled={generating || loading}
            className="inline-flex items-center gap-2 px-4 py-2 bg-blue-500/10 hover:bg-blue-500/20 text-blue-600 dark:text-blue-400 font-semibold rounded-xl transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <ArrowPathIcon className={`w-5 h-5 ${generating ? 'animate-spin' : ''}`} />
            {generating ? 'Generando...' : 'Generar mixes por primera vez'}
          </button>
        )}
      </div>

      <AnimatePresence mode="wait">
        {error ? (
          <motion.div
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -10 }}
            className="p-4 bg-red-50 dark:bg-red-500/10 text-red-600 dark:text-red-400 rounded-xl"
          >
            {error}
          </motion.div>
        ) : loading ? (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="flex gap-3 md:gap-4 overflow-x-auto scrollbar-hide pb-2 -mx-4 px-4 md:mx-0 md:px-0"
          >
            {[...Array(5)].map((_, i) => (
              <div key={i} className="flex-shrink-0 w-36 md:w-44 animate-pulse bg-gray-200 dark:bg-gray-800 rounded-2xl aspect-square" />
            ))}
          </motion.div>
        ) : mixes.length === 0 ? (
          <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} className="flex flex-col items-center justify-center p-8 bg-gray-50 dark:bg-gray-800/20 rounded-2xl border border-dashed border-gray-200 dark:border-gray-700">
            <div className="w-16 h-16 bg-blue-100 dark:bg-blue-900/30 rounded-full flex items-center justify-center mb-4">
              <ArrowPathIcon className="w-8 h-8 text-blue-500" />
            </div>
            <h3 className="text-xl font-semibold text-gray-900 dark:text-white mb-2">Aún no tienes mixes</h3>
            <p className="text-gray-500 text-center max-w-md">
              Presiona "Actualizar ahora" para calcular tus listas basadas en lo que has escuchado recientemente.
            </p>
          </motion.div>
        ) : (
          <motion.div initial={{ opacity: hadCache.current ? 1 : 0 }} animate={{ opacity: 1 }}>
            <HorizontalScrollSection>
              {mixes.map((mix) => {
                const playlistObj: Playlist = {
                  id: mix.navidromeId || `mix-${mix.mixNumber}`,
                  name: mix.name.split(' · ')[0],
                  songCount: mix.trackCount,
                  duration: 0,
                  created: mix.lastGenerated || '2000-01-01T00:00:00.000Z',
                  changed: mix.lastGenerated || '2000-01-01T00:00:00.000Z',
                  comment: `Mix Diario ${mix.clusterSeed}`,
                  owner: 'Audiorr',
                  public: false,
                }
                const isPlayingFromThisPlaylist = playerState.isPlaying && playerState.currentSource === `playlist:${playlistObj.id}`
                return (
                  <div key={mix.mixNumber} className="flex-shrink-0 w-36 md:w-44">
                    <PlaylistItem
                      playlist={playlistObj}
                      isPlayingFromThisPlaylist={isPlayingFromThisPlaylist}

                      isPinned={isPinned(playlistObj.id)}
                      onTogglePin={() => togglePinnedPlaylist(playlistObj)}
                    />
                  </div>
                )
              })}
            </HorizontalScrollSection>
          </motion.div>
        )}
      </AnimatePresence>
    </section>
  )
}
