import { useMemo, useState, useEffect } from 'react'
import { navidromeApi } from '../services/navidromeApi'
import { coverArtCacheService } from '../services/coverArtCacheService'

interface Props {
  coverArtId?: string
  customCoverUrl?: string | null
  alt?: string
  className?: string
  isLoading?: boolean
  size?: number
  onImageLoaded?: (url: string) => void
}

// Registro global de imágenes ya cargadas para evitar parpadeos al navegar (unmount/mount)
const globalLoadedImages = new Set<string>()

export default function AlbumCover({ coverArtId, customCoverUrl, alt, className, isLoading, size, onImageLoaded }: Props) {
  const networkUrl = useMemo(() => {
    if (customCoverUrl) return customCoverUrl
    if (coverArtId) return navidromeApi.getCoverUrl(coverArtId, size)
    return null
  }, [coverArtId, customCoverUrl, size])

  // The URL we actually pass to <img>: blob URL from cache or network URL
  const [imageUrl, setImageUrl] = useState<string | null>(() =>
    networkUrl && globalLoadedImages.has(networkUrl) ? networkUrl : null
  )
  const [isLoaded, setIsLoaded] = useState(() =>
    networkUrl ? globalLoadedImages.has(networkUrl) : false
  )

  // When coverArtId changes: check IndexedDB cache first
  useEffect(() => {
    if (!coverArtId || !coverArtCacheService.isAvailable()) {
      setImageUrl(networkUrl)
      setIsLoaded(networkUrl ? globalLoadedImages.has(networkUrl) : false)
      return
    }

    let cancelled = false
    coverArtCacheService.getBlobUrl(coverArtId, size).then(blobUrl => {
      if (cancelled) return
      if (blobUrl) {
        setImageUrl(blobUrl)
        setIsLoaded(true)
      } else {
        setImageUrl(networkUrl)
        setIsLoaded(networkUrl ? globalLoadedImages.has(networkUrl) : false)
      }
    })
    return () => { cancelled = true }
  }, [coverArtId, networkUrl])

  // Notify parent once the image is actually rendered (covers all paths: network, blob, globalLoadedImages)
  useEffect(() => {
    if (isLoaded && networkUrl) {
      onImageLoaded?.(networkUrl)
    }
  }, [isLoaded, networkUrl, onImageLoaded])

  const handleLoad = () => {
    if (networkUrl) {
      globalLoadedImages.add(networkUrl)
      // Cache cover art in the background after it loads from the network
      if (coverArtId && coverArtCacheService.isAvailable() && networkUrl) {
        coverArtCacheService.cacheFromUrl(coverArtId, networkUrl, size).catch(() => {})
      }
    }
    setIsLoaded(true)
  }

  const showPlaceholder = isLoading || !imageUrl || !isLoaded

  return (
    <div className={`aspect-square relative overflow-hidden bg-gray-200 dark:bg-white/[0.08] ${className}`}>
      {/* Placeholder / Skeleton */}
      {showPlaceholder && (
        <div className="absolute inset-0 z-10 flex items-center justify-center bg-gray-200 dark:bg-white/[0.08] animate-pulse">
          {!imageUrl && (
            <svg className="w-1/3 h-1/3 text-gray-400 dark:text-gray-600" fill="currentColor" viewBox="0 0 24 24">
              <path d="M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z" />
            </svg>
          )}
        </div>
      )}

      {imageUrl && (
        <img
          src={imageUrl}
          alt={alt || 'Album cover'}
          className={`w-full h-full object-cover transition-opacity duration-500 ${isLoaded ? 'opacity-100' : 'opacity-0'}`}
          loading="lazy"
          onLoad={handleLoad}
        />
      )}
    </div>
  )
}
