import { useEffect, useState, useRef } from 'react'
import { Album } from '../services/navidromeApi'
import AlbumCard from './AlbumCard'

interface AlbumCarouselProps {
  albums: Album[]
  autoPlayInterval?: number // Intervalo en milisegundos (por defecto 3000ms)
}

export default function AlbumCarousel({ albums, autoPlayInterval = 3000 }: AlbumCarouselProps) {
  const [currentIndex, setCurrentIndex] = useState(0)
  const [isPaused, setIsPaused] = useState(false)
  const [isHoveringCarousel, setIsHoveringCarousel] = useState(false)
  const carouselRef = useRef<HTMLDivElement>(null)
  const intervalRef = useRef<NodeJS.Timeout | null>(null)

  // Calcular cuántos álbumes mostrar según el tamaño de pantalla
  const getVisibleCount = () => {
    if (typeof window === 'undefined') return 5
    const width = window.innerWidth
    if (width >= 1280) return 6 // xl
    if (width >= 1024) return 5 // lg
    if (width >= 768) return 4 // md
    if (width >= 640) return 3 // sm
    return 2 // mobile
  }

  const [visibleCount, setVisibleCount] = useState(getVisibleCount)

  useEffect(() => {
    const handleResize = () => {
      setVisibleCount(getVisibleCount())
    }

    window.addEventListener('resize', handleResize)
    return () => window.removeEventListener('resize', handleResize)
  }, [])

  // Auto-play del carousel
  useEffect(() => {
    if (albums.length === 0 || isPaused) {
      if (intervalRef.current) {
        clearInterval(intervalRef.current)
        intervalRef.current = null
      }
      return
    }

    intervalRef.current = setInterval(() => {
      setCurrentIndex(prev => {
        const maxIndex = Math.max(0, albums.length - visibleCount)
        if (maxIndex === 0) return 0
        return (prev + 1) % (maxIndex + 1)
      })
    }, autoPlayInterval)

    return () => {
      if (intervalRef.current) {
        clearInterval(intervalRef.current)
      }
    }
  }, [albums.length, visibleCount, autoPlayInterval, isPaused])

  if (albums.length === 0) {
    return null
  }

  const maxIndex = Math.max(0, albums.length - visibleCount)
  const translateX = -currentIndex * (100 / visibleCount)

  return (
    <div className="mb-12 -mx-4 md:-mx-6 lg:-mx-8">
      <h1 className="text-3xl md:text-4xl font-bold mb-6 text-gray-900 dark:text-white px-4 md:px-6 lg:px-8">
        Lanzamientos recientes
      </h1>
      <p className="text-gray-600 dark:text-gray-300 mb-6 px-4 md:px-6 lg:px-8">
        Álbumes estrenados en los últimos meses
      </p>
      <div
        ref={carouselRef}
        className="relative overflow-hidden"
        onMouseEnter={() => {
          setIsPaused(true)
          setIsHoveringCarousel(true)
        }}
        onMouseLeave={() => {
          setIsPaused(false)
          setIsHoveringCarousel(false)
        }}
      >
        <div
          className="flex transition-transform duration-700 ease-in-out"
          style={{
            transform: `translateX(${translateX}%)`,
          }}
        >
          {albums.map(album => (
            <div
              key={album.id}
              className="flex-shrink-0 px-3"
              style={{ width: `${100 / visibleCount}%` }}
            >
              <AlbumCard album={album} showPlayButton={true} />
            </div>
          ))}
        </div>

        {/* Indicadores de posición */}
        {maxIndex > 0 && (
          <div className="flex justify-center gap-2 mt-6">
            {Array.from({ length: maxIndex + 1 }).map((_, index) => (
              <button
                key={index}
                onClick={() => setCurrentIndex(index)}
                className={`h-2 rounded-full transition-all duration-300 ${
                  index === currentIndex
                    ? 'bg-blue-500 dark:bg-blue-400 w-8'
                    : 'bg-gray-300 dark:bg-gray-600 w-2 hover:bg-gray-400 dark:hover:bg-gray-500'
                }`}
                aria-label={`Ir al slide ${index + 1}`}
              />
            ))}
          </div>
        )}

        {/* Botones de navegación */}
        {maxIndex > 0 && (
          <>
            <button
              onClick={() => setCurrentIndex(prev => (prev === 0 ? maxIndex : prev - 1))}
              className={`absolute left-2 top-1/2 -translate-y-1/2 z-10 bg-white/90 dark:bg-gray-800/90 hover:bg-white dark:hover:bg-gray-800 rounded-full p-2 shadow-lg backdrop-blur-sm transition-all ${
                isHoveringCarousel ? 'opacity-100' : 'opacity-0'
              }`}
              aria-label="Álbum anterior"
            >
              <svg
                className="w-6 h-6 text-gray-700 dark:text-gray-200"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M15 19l-7-7 7-7"
                />
              </svg>
            </button>
            <button
              onClick={() => setCurrentIndex(prev => (prev === maxIndex ? 0 : prev + 1))}
              className={`absolute right-2 top-1/2 -translate-y-1/2 z-10 bg-white/90 dark:bg-gray-800/90 hover:bg-white dark:hover:bg-gray-800 rounded-full p-2 shadow-lg backdrop-blur-sm transition-all ${
                isHoveringCarousel ? 'opacity-100' : 'opacity-0'
              }`}
              aria-label="Siguiente álbum"
            >
              <svg
                className="w-6 h-6 text-gray-700 dark:text-gray-200"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M9 5l7 7-7 7"
                />
              </svg>
            </button>
          </>
        )}
      </div>
    </div>
  )
}
