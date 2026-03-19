import { useEffect, useState, useCallback } from 'react'
import { motion, AnimatePresence, PanInfo } from 'framer-motion'
import { useNavigate } from 'react-router-dom'
import { backendApi } from '../services/backendApi'
import { navidromeApi } from '../services/navidromeApi'
import Spinner from './Spinner'
import ArtistAvatar from './ArtistAvatar'

interface WrappedStats {
  total_plays: number
  weighted_average_release_year: number | null
  weighted_average_BPM: number | null
  weighted_average_Energy: number | null
  top_songs: Array<{
    title: string
    artist: string
    album: string
    album_id: string
    cover_art: string | null
    plays: number
  }>
  top_artists: Array<{
    artist: string
    plays: number
  }>
  top_genres: Array<{
    genre: string
    plays: number
  }>
}

interface WrappedPageProps {
  onClose?: () => void
  year?: number
}

const slideVariants = {
  enter: (direction: number) => ({
    x: direction > 0 ? '100%' : '-100%',
    opacity: 0,
  }),
  center: {
    x: 0,
    opacity: 1,
  },
  exit: (direction: number) => ({
    x: direction < 0 ? '100%' : '-100%',
    opacity: 0,
  }),
}

export default function WrappedPage({ onClose, year }: WrappedPageProps) {
  const navigate = useNavigate()
  const [stats, setStats] = useState<WrappedStats | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [currentSlide, setCurrentSlide] = useState(0)
  const [direction, setDirection] = useState(0)
  const [isDragging, setIsDragging] = useState(false)

  const currentYear = year || new Date().getFullYear()
  const totalSlides = 6

  useEffect(() => {
    const fetchStats = async () => {
      try {
        setLoading(true)
        setError(null)
        const config = navidromeApi.getConfig()
        if (!config?.username) {
          setError('No hay usuario conectado')
          return
        }

        const data = await backendApi.getWrappedStats(config.username, currentYear, config)
        setStats(data)
      } catch (err) {
        console.error('Error fetching wrapped stats:', err)
        setError(err instanceof Error ? err.message : 'Error desconocido')
      } finally {
        setLoading(false)
      }
    }

    fetchStats()
  }, [currentYear])

  // Auto-avanzar slides cada 25 segundos (solo si no está arrastrando)
  useEffect(() => {
    if (!stats || isDragging) return

    const interval = setInterval(() => {
      setDirection(1)
      setCurrentSlide(prev => (prev + 1) % totalSlides)
    }, 25000)

    return () => clearInterval(interval)
  }, [stats, isDragging, totalSlides])

  const handleClose = useCallback(() => {
    if (onClose) {
      onClose()
    } else {
      navigate('/')
    }
  }, [onClose, navigate])

  const goToNextSlide = useCallback(() => {
    setDirection(1)
    setCurrentSlide(prev => (prev + 1) % totalSlides)
  }, [totalSlides])

  const goToPrevSlide = useCallback(() => {
    setDirection(-1)
    setCurrentSlide(prev => (prev - 1 + totalSlides) % totalSlides)
  }, [totalSlides])

  const handleDragEnd = useCallback(
    (_event: MouseEvent | TouchEvent | PointerEvent, info: PanInfo) => {
      setIsDragging(false)
      const threshold = 100

      if (info.offset.x > threshold) {
        goToPrevSlide()
      } else if (info.offset.x < -threshold) {
        goToNextSlide()
      }
    },
    [goToNextSlide, goToPrevSlide]
  )

  // Manejar teclado
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
        goToNextSlide()
      } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
        goToPrevSlide()
      } else if (e.key === 'Escape') {
        handleClose()
      }
    }

    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [goToNextSlide, goToPrevSlide, handleClose])

  if (loading) {
    return (
      <div className="fixed inset-0 z-50 flex items-center justify-center bg-gradient-to-br from-[#1e1e1e] via-[#2d1b4e] to-[#1a1a2e]">
        <Spinner size="lg" />
      </div>
    )
  }

  if (error) {
    return (
      <div className="fixed inset-0 z-50 flex flex-col items-center justify-center bg-gradient-to-br from-[#1e1e1e] via-[#2d1b4e] to-[#1a1a2e] text-white">
        <p className="text-red-400 text-xl mb-4">Error al cargar estadísticas</p>
        <p className="text-gray-300 mb-6">{error}</p>
        <button
          onClick={handleClose}
          className="px-6 py-3 bg-white/10 hover:bg-white/20 rounded-full transition-colors backdrop-blur-sm font-medium"
        >
          Cerrar
        </button>
      </div>
    )
  }

  if (!stats) {
    return (
      <div className="fixed inset-0 z-50 flex items-center justify-center bg-gradient-to-br from-[#1e1e1e] via-[#2d1b4e] to-[#1a1a2e] text-white">
        <p className="text-gray-300">No hay datos disponibles</p>
      </div>
    )
  }

  const calculateMusicalAge = (): number | null => {
    if (!stats.weighted_average_release_year) return null
    const currentYear = new Date().getFullYear()
    return currentYear - Math.round(stats.weighted_average_release_year)
  }

  const getVibeLabel = (): { label: string; emoji: string; color: string } => {
    if (!stats.weighted_average_BPM || !stats.weighted_average_Energy) {
      return { label: 'Vibra Desconocida', emoji: '🎵', color: 'from-gray-400 to-gray-600' }
    }

    const bpm = stats.weighted_average_BPM
    const energy = stats.weighted_average_Energy

    if (energy >= 70 && bpm >= 120) {
      return { label: 'High Energy Banger', emoji: '🔥', color: 'from-red-500 to-orange-500' }
    } else if (energy >= 70 && bpm < 120) {
      return { label: 'Powerful Groove', emoji: '💪', color: 'from-purple-500 to-pink-500' }
    } else if (energy >= 50 && bpm >= 120) {
      return { label: 'Energetic Flow', emoji: '⚡', color: 'from-yellow-400 to-orange-400' }
    } else if (energy >= 50 && bpm < 120) {
      return { label: 'Relaxed Groove', emoji: '🌊', color: 'from-blue-400 to-cyan-400' }
    } else if (energy < 50 && bpm >= 100) {
      return { label: 'Chill Vibes', emoji: '🌙', color: 'from-indigo-400 to-purple-400' }
    } else {
      return { label: 'Ambient Mood', emoji: '☁️', color: 'from-gray-400 to-blue-400' }
    }
  }

  const musicalAge = calculateMusicalAge()
  const vibe = getVibeLabel()

  // Separar el top 1 de artistas
  const topArtist = stats.top_artists && stats.top_artists.length > 0 ? stats.top_artists[0] : null
  const remainingArtists = stats.top_artists && stats.top_artists.length > 1 ? stats.top_artists.slice(1) : []

  const slides = [
    {
      id: 'vibra-musical',
      component: (
        <div className="flex flex-col items-center justify-center h-full px-8">
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6 }}
            className="text-center max-w-2xl"
          >
            <motion.h2
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ delay: 0.2 }}
              className="text-5xl md:text-6xl font-black mb-8 bg-clip-text text-transparent bg-gradient-to-r from-white to-gray-300"
            >
              Tu Edad Musical
            </motion.h2>
            {musicalAge !== null ? (
              <>
                <motion.div
                  initial={{ scale: 0, opacity: 0 }}
                  animate={{ scale: 1, opacity: 1 }}
                  transition={{ delay: 0.4, type: 'spring', stiffness: 150, damping: 15 }}
                  className="text-[120px] md:text-[180px] font-black mb-6 leading-none bg-clip-text text-transparent bg-gradient-to-r from-[#1db954] via-[#1ed760] to-[#1db954]"
                  style={{ textShadow: '0 0 80px rgba(29, 185, 84, 0.5)' }}
                >
                  {musicalAge}
                </motion.div>
                <motion.p
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  transition={{ delay: 0.6 }}
                  className="text-2xl md:text-3xl text-gray-300 mb-4 font-light"
                >
                  años de música en tu alma
                </motion.p>
                {stats.weighted_average_release_year && (
                  <motion.p
                    initial={{ opacity: 0 }}
                    animate={{ opacity: 1 }}
                    transition={{ delay: 0.8 }}
                    className="text-lg text-gray-400"
                  >
                    Promedio ponderado: {Math.round(stats.weighted_average_release_year)}
                  </motion.p>
                )}
              </>
            ) : (
              <p className="text-2xl text-gray-400">No hay datos suficientes</p>
            )}
          </motion.div>
        </div>
      ),
    },
    {
      id: 'top-genres',
      component: (
        <div className="flex flex-col items-center justify-center h-full px-8 py-12 overflow-y-auto">
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6 }}
            className="w-full max-w-3xl"
          >
            <motion.h2
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ delay: 0.2 }}
              className="text-5xl md:text-6xl font-black mb-12 text-center bg-clip-text text-transparent bg-gradient-to-r from-white to-gray-300"
            >
              Tus Géneros Favoritos
            </motion.h2>
            <div className="space-y-3">
              {stats.top_genres && stats.top_genres.length > 0 ? (
                stats.top_genres.map((genre, index) => (
                  <motion.div
                    key={genre.genre}
                    initial={{ x: -50, opacity: 0 }}
                    animate={{ x: 0, opacity: 1 }}
                    transition={{ delay: 0.3 + index * 0.1, type: 'spring', stiffness: 100 }}
                    className="group bg-white/5 hover:bg-white/10 backdrop-blur-sm rounded-xl p-5 flex items-center justify-between border border-white/10 hover:border-white/20 transition-all duration-300"
                  >
                    <div className="flex items-center space-x-5 flex-1 min-w-0">
                      <div className="text-4xl font-black text-gray-500 group-hover:text-[#1db954] transition-colors w-12 text-center flex-shrink-0">
                        {index + 1}
                      </div>
                      <div className="text-2xl font-bold text-white truncate">{genre.genre}</div>
                    </div>
                    <div className="text-right ml-4 flex-shrink-0">
                      <div className="text-3xl font-black text-white">{genre.plays.toLocaleString()}</div>
                      <div className="text-xs text-gray-400 uppercase tracking-wider">plays</div>
                    </div>
                  </motion.div>
                ))
              ) : (
                <p className="text-center text-gray-400 text-xl">No hay géneros disponibles</p>
              )}
            </div>
          </motion.div>
        </div>
      ),
    },
    {
      id: 'edad-musical',
      component: (
        <div className="flex flex-col items-center justify-center h-full px-8">
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6 }}
            className="text-center max-w-3xl"
          >
            <motion.h2
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ delay: 0.2 }}
              className="text-5xl md:text-6xl font-black mb-12 bg-clip-text text-transparent bg-gradient-to-r from-white to-gray-300"
            >
              Tu Vibra Musical
            </motion.h2>
            <motion.div
              initial={{ scale: 0.8, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              transition={{ delay: 0.4, type: 'spring', stiffness: 150 }}
              className="mb-8"
            >
              <div className={`text-8xl md:text-9xl mb-6`}>{vibe.emoji}</div>
              <div
                className={`text-4xl md:text-5xl font-black bg-clip-text text-transparent bg-gradient-to-r ${vibe.color}`}
              >
                {vibe.label}
              </div>
            </motion.div>
            {stats.weighted_average_BPM && (
              <motion.div
                initial={{ opacity: 0, y: 20 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ delay: 0.6 }}
                className="flex justify-center text-xl"
              >
                <div className="bg-white/5 backdrop-blur-sm rounded-2xl px-6 py-4 border border-white/10">
                  <div className="text-gray-400 text-sm mb-1">BPM Promedio</div>
                  <div className="text-3xl font-bold text-white">{Math.round(stats.weighted_average_BPM)}</div>
                </div>
              </motion.div>
            )}
          </motion.div>
        </div>
      ),
    },
    {
      id: 'top-songs',
      component: (
        <div className="flex flex-col items-center justify-center h-full px-8 py-12 overflow-y-auto">
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6 }}
            className="w-full max-w-3xl"
          >
            <motion.h2
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ delay: 0.2 }}
              className="text-5xl md:text-6xl font-black mb-12 text-center bg-clip-text text-transparent bg-gradient-to-r from-white to-gray-300"
            >
              Tus Top 5 Canciones
            </motion.h2>
            <div className="space-y-3">
              {stats.top_songs.map((song, index) => (
                <motion.div
                  key={`${song.title}-${song.artist}`}
                  initial={{ x: -50, opacity: 0 }}
                  animate={{ x: 0, opacity: 1 }}
                  transition={{ delay: 0.3 + index * 0.1, type: 'spring', stiffness: 100 }}
                  className="group bg-white/5 hover:bg-white/10 backdrop-blur-sm rounded-xl p-5 flex items-center justify-between border border-white/10 hover:border-white/20 transition-all duration-300"
                >
                  <div className="flex items-center space-x-5 flex-1 min-w-0">
                    <div className="text-4xl font-black text-gray-500 group-hover:text-[#1db954] transition-colors w-12 text-center flex-shrink-0">
                      {index + 1}
                    </div>
                    {/* Album Cover */}
                    {song.album_id && (
                      <div className="w-16 h-16 flex-shrink-0 rounded-lg overflow-hidden bg-gray-800">
                        <img
                          src={navidromeApi.getCoverUrl(song.album_id)}
                          alt={song.album}
                          className="w-full h-full object-cover"
                          onError={e => {
                            const target = e.target as HTMLImageElement
                            target.style.display = 'none'
                          }}
                        />
                      </div>
                    )}
                    <div className="flex-1 min-w-0">
                      <div className="text-2xl font-bold text-white truncate mb-1">{song.title}</div>
                      <div className="text-lg text-gray-300 truncate">{song.artist}</div>
                      <div className="text-sm text-gray-500 truncate">{song.album}</div>
                    </div>
                  </div>
                  <div className="text-right ml-4 flex-shrink-0">
                    <div className="text-3xl font-black text-white">{song.plays.toLocaleString()}</div>
                    <div className="text-xs text-gray-400 uppercase tracking-wider">plays</div>
                  </div>
                </motion.div>
              ))}
            </div>
          </motion.div>
        </div>
      ),
    },
    {
      id: 'top-artists',
      component: (
        <div className="flex flex-col items-center justify-center h-full px-8 py-12 overflow-y-auto">
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6 }}
            className="w-full max-w-3xl"
          >
            <motion.h2
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ delay: 0.2 }}
              className="text-5xl md:text-6xl font-black mb-12 text-center bg-clip-text text-transparent bg-gradient-to-r from-white to-gray-300"
            >
              Tus Top 5 Artistas
            </motion.h2>
            <div className="space-y-3">
              {remainingArtists.map((artist, index) => (
                <motion.div
                  key={artist.artist}
                  initial={{ x: -50, opacity: 0 }}
                  animate={{ x: 0, opacity: 1 }}
                  transition={{ delay: 0.3 + index * 0.1, type: 'spring', stiffness: 100 }}
                  className="group bg-white/5 hover:bg-white/10 backdrop-blur-sm rounded-xl p-5 flex items-center justify-between border border-white/10 hover:border-white/20 transition-all duration-300"
                >
                  <div className="flex items-center space-x-5 flex-1 min-w-0">
                    <div className="text-4xl font-black text-gray-500 group-hover:text-[#1db954] transition-colors w-12 text-center flex-shrink-0">
                      {index + 2}
                    </div>
                    {/* Artist Avatar */}
                    <div className="w-16 h-16 flex-shrink-0 rounded-full overflow-hidden bg-gray-800">
                      <ArtistAvatar artistName={artist.artist} className="w-full h-full" />
                    </div>
                    <div className="text-2xl font-bold text-white truncate">{artist.artist}</div>
                  </div>
                  <div className="text-right ml-4 flex-shrink-0">
                    <div className="text-3xl font-black text-white">{artist.plays.toLocaleString()}</div>
                    <div className="text-xs text-gray-400 uppercase tracking-wider">plays</div>
                  </div>
                </motion.div>
              ))}
            </div>
          </motion.div>
        </div>
      ),
    },
    {
      id: 'top-artist-solo',
      component: topArtist ? (
        <div className="flex flex-col items-center justify-center h-full px-8">
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6 }}
            className="text-center max-w-3xl"
          >
            <motion.h2
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              transition={{ delay: 0.2 }}
              className="text-4xl md:text-5xl font-black mb-8 bg-clip-text text-transparent bg-gradient-to-r from-white to-gray-300"
            >
              Tu artista más escuchado
            </motion.h2>
            <motion.div
              initial={{ scale: 0.8, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              transition={{ delay: 0.4, type: 'spring', stiffness: 150 }}
              className="mb-8"
            >
              <div className="w-48 h-48 md:w-64 md:h-64 mx-auto mb-8 rounded-full overflow-hidden bg-gray-800 shadow-2xl">
                <ArtistAvatar artistName={topArtist.artist} className="w-full h-full" />
              </div>
              <motion.div
                initial={{ opacity: 0, y: 20 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ delay: 0.6 }}
                className="text-5xl md:text-6xl font-black mb-4 bg-clip-text text-transparent bg-gradient-to-r from-[#1db954] to-[#1ed760]"
              >
                {topArtist.artist}
              </motion.div>
              <motion.div
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                transition={{ delay: 0.8 }}
                className="text-3xl md:text-4xl font-bold text-white mb-2"
              >
                {topArtist.plays.toLocaleString()}
              </motion.div>
              <motion.p
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                transition={{ delay: 1 }}
                className="text-xl text-gray-400"
              >
                reproducciones
              </motion.p>
            </motion.div>
          </motion.div>
        </div>
      ) : (
        <div className="flex items-center justify-center h-full">
          <p className="text-gray-400">No hay datos disponibles</p>
        </div>
      ),
    },
  ]

  return (
    <div className="fixed inset-0 z-50 bg-gradient-to-br from-[#1e1e1e] via-[#2d1b4e] to-[#1a1a2e] text-white overflow-hidden">
      {/* Botón cerrar */}
      <motion.button
        initial={{ opacity: 0, scale: 0.8 }}
        animate={{ opacity: 1, scale: 1 }}
        transition={{ delay: 0.3 }}
        onClick={handleClose}
        className="absolute top-6 right-6 z-50 w-12 h-12 flex items-center justify-center bg-black/40 hover:bg-black/60 rounded-full transition-all backdrop-blur-md border border-white/10 hover:border-white/20"
        aria-label="Cerrar"
      >
        <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2.5} d="M6 18L18 6M6 6l12 12" />
        </svg>
      </motion.button>

      {/* Contenedor principal de slides */}
      <div className="relative w-full h-full">
        <AnimatePresence mode="wait" custom={direction}>
          <motion.div
            key={currentSlide}
            custom={direction}
            variants={slideVariants}
            initial="enter"
            animate="center"
            exit="exit"
            transition={{
              x: { type: 'spring', stiffness: 300, damping: 30 },
              opacity: { duration: 0.3 },
            }}
            drag="x"
            dragConstraints={{ left: 0, right: 0 }}
            dragElastic={0.2}
            onDragStart={() => setIsDragging(true)}
            onDragEnd={handleDragEnd}
            className="absolute inset-0"
          >
            {slides[currentSlide]?.component}
          </motion.div>
        </AnimatePresence>
      </div>

      {/* Indicadores de progreso (arriba) */}
      <div className="absolute top-6 left-1/2 transform -translate-x-1/2 flex space-x-2 z-40">
        {Array.from({ length: totalSlides }).map((_, index) => (
          <button
            key={index}
            onClick={() => {
              setDirection(index > currentSlide ? 1 : -1)
              setCurrentSlide(index)
            }}
            className={`h-1.5 rounded-full transition-all duration-300 ${
              currentSlide === index ? 'bg-white w-12' : 'bg-white/30 w-1.5 hover:bg-white/50'
            }`}
            aria-label={`Ir a slide ${index + 1}`}
          />
        ))}
      </div>

      {/* Resumen total (abajo) */}
      <motion.div
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.5 }}
        className="absolute bottom-8 left-1/2 transform -translate-x-1/2 text-center z-40"
      >
        <div className="bg-white/5 backdrop-blur-md rounded-2xl px-8 py-4 border border-white/10">
          <div className="text-4xl font-black mb-1 bg-clip-text text-transparent bg-gradient-to-r from-[#1db954] to-[#1ed760]">
            {stats.total_plays.toLocaleString()}
          </div>
          <div className="text-sm text-gray-400 uppercase tracking-wider">Total de reproducciones</div>
        </div>
      </motion.div>

      {/* Instrucciones de navegación (solo en desktop) */}
      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ delay: 1 }}
        className="hidden md:block absolute bottom-6 left-6 text-white/40 text-xs z-40"
      >
        <p>← → para navegar | ESC para cerrar</p>
      </motion.div>
    </div>
  )
}
