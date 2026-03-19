import { useState, useEffect, useRef, memo } from 'react'
import { navidromeApi } from '../services/navidromeApi'
import { getArtistAvatarCache, setArtistAvatarCache, getLoadingPromises } from '../utils/artistAvatarCache'

interface ArtistAvatarProps {
  artistName: string
  className?: string
  onImageLoaded?: (url: string | null) => void
}

function ArtistAvatar({ artistName, className, onImageLoaded }: ArtistAvatarProps) {
  const [imageUrl, setImageUrl] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const ref = useRef<HTMLDivElement>(null)
  const isMounted = useRef(true)

  useEffect(() => {
    isMounted.current = true
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          observer.disconnect()

          const fetchAvatar = async () => {
            const cacheKey = artistName.toLowerCase().trim()

            // 1. Buscar en caché LRU (memoria local — instantáneo)
            const cachedImage = getArtistAvatarCache().get(cacheKey)
            if (cachedImage !== undefined) {
              if (isMounted.current) {
                setImageUrl(cachedImage)
                setLoading(false)
                onImageLoaded?.(cachedImage)
              }
              return
            }

            // 2. Deduplicar: si ya hay una petición en vuelo para este artista, reutilizarla
            const loadingPromises = getLoadingPromises()
            const existingPromise = loadingPromises.get(cacheKey)
            if (existingPromise) {
              try {
                const result = await existingPromise
                if (isMounted.current) {
                  setImageUrl(result)
                  setLoading(false)
                  onImageLoaded?.(result)
                }
              } catch {
                if (isMounted.current) {
                  setLoading(false)
                  onImageLoaded?.(null)
                }
              }
              return
            }

            // 3. Llamar a Navidrome local
            try {
              if (isMounted.current) setLoading(true)

              const promise = navidromeApi.getArtistImage(artistName).then(url => {
                // Guardar en caché LRU del frontend
                setArtistAvatarCache(cacheKey, url)
                return url
              })

              loadingPromises.set(cacheKey, promise)

              const result = await promise
              if (isMounted.current) {
                setImageUrl(result)
                onImageLoaded?.(result)
              }
            } catch (error) {
              console.error(`Failed to fetch avatar for ${artistName}`, error)
              if (isMounted.current) {
                setArtistAvatarCache(cacheKey, null)
                onImageLoaded?.(null)
              }
            } finally {
              loadingPromises.delete(cacheKey)
              if (isMounted.current) setLoading(false)
            }
          }

          fetchAvatar()
        }
      },
      {
        rootMargin: '400px',
      }
    )

    if (ref.current) {
      observer.observe(ref.current)
    }

    return () => {
      isMounted.current = false
      observer.disconnect()
    }
  }, [artistName, onImageLoaded])

  return (
    <div
      ref={ref}
      className={`w-full h-full rounded-full overflow-hidden bg-gray-200 dark:bg-gray-800 flex items-center justify-center relative ${className}`}
    >
      {/* Placeholder / Skeleton */}
      {(loading || !imageUrl) && (
        <div className="absolute inset-0 z-10 bg-gray-200 dark:bg-gray-800 animate-pulse flex items-center justify-center">
          {!imageUrl && !loading && (
             <span className="font-bold text-5xl text-gray-500 dark:text-gray-400 select-none">
               {artistName.charAt(0).toUpperCase()}
             </span>
          )}
        </div>
      )}

      {imageUrl && (
        <img
          src={imageUrl}
          alt={artistName}
          className={`w-full h-full object-cover transition-opacity duration-500 ${!loading ? 'opacity-100' : 'opacity-0'}`}
          loading="lazy"
          onDragStart={e => e.preventDefault()}
          onContextMenu={e => e.preventDefault()}
        />
      )}
    </div>
  )
}

// Memoizar para evitar re-renders innecesarios
export default memo(ArtistAvatar, (prevProps, nextProps) => {
  return prevProps.artistName === nextProps.artistName
})
