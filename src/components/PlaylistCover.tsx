import React, { useState, useEffect } from 'react';
import { API_BASE_URL } from '../services/backendApi';
import { useBackendAvailable } from '../contexts/BackendAvailableContext';

// Global registry — same pattern as AlbumCover.tsx.
// Prevents skeleton flash when navigating back to a page whose covers are cached by the browser.
const globalLoadedImages = new Set<string>()

interface PlaylistCoverProps {
  playlistId: string;
  name: string; // Used as fallback / aria
  className?: string;
  rounded?: boolean;
  /** Navidrome cover URL used when the backend is unavailable or the backend image fails. */
  fallbackUrl?: string;
}

export const PlaylistCover: React.FC<PlaylistCoverProps> = ({ playlistId, name, className = '', rounded = true, fallbackUrl }) => {
  const backendAvailable = useBackendAvailable()
  const [hasError, setHasError] = useState(false);
  const [retryCount, setRetryCount] = useState(0);

  // Use fallback directly when backend is not available and we have one
  const [useFallback, setUseFallback] = useState(!backendAvailable && !!fallbackUrl)

  useEffect(() => {
    setUseFallback(!backendAvailable && !!fallbackUrl)
    setHasError(false)
    setRetryCount(0)
  }, [backendAvailable, fallbackUrl])

  const timeQuery = Math.floor(Date.now() / 300000);
  const backendUrl = `${API_BASE_URL}/api/playlists/${playlistId}/cover.png?_t=${timeQuery}${retryCount > 0 ? `&r=${retryCount}` : ''}`;
  const imageUrl = useFallback ? fallbackUrl! : backendUrl;

  // Initialize from global cache so navigating back never re-shows skeleton for already-loaded images
  const [isLoaded, setIsLoaded] = useState(() => globalLoadedImages.has(imageUrl))

  // Sync when URL changes (e.g. retry increments the URL, or we switch to fallback)
  useEffect(() => {
    setIsLoaded(globalLoadedImages.has(imageUrl))
  }, [imageUrl])

  const handleLoad = () => {
    globalLoadedImages.add(imageUrl)
    setIsLoaded(true)
  }

  const handleError = () => {
    // If backend URL is failing and we have a fallback, switch to it after a couple retries
    if (!useFallback && fallbackUrl && retryCount >= 2) {
      setUseFallback(true)
      setHasError(false)
      return
    }
    setHasError(true);
    if (retryCount < 10) {
      const waitTime = Math.min(1000 * Math.pow(1.5, retryCount), 10000);
      setTimeout(() => {
        setHasError(false);
        setRetryCount(prev => prev + 1);
      }, waitTime);
    }
  };

  return (
    <div className={`relative aspect-square overflow-hidden ${rounded ? 'rounded-xl' : ''} ${className}`}>
      {/* Skeleton / Fallback — shown while loading OR on error with retry */}
      {(!isLoaded || hasError) && (
        <div
          className="absolute inset-0 z-10 bg-gray-200 dark:bg-white/[0.08] flex items-center justify-center font-bold text-gray-500 dark:text-gray-400 uppercase text-center"
        >
          {/* Pulse overlay while loading (not error) */}
          {!hasError && (
            <div className="absolute inset-0 bg-white/5 animate-pulse" />
          )}

          {/* Name + spinner only shown on error/retry — not during initial load */}
          {hasError && (
            <div className="flex flex-col items-center justify-center px-2">
              <span className="break-words leading-tight drop-shadow-md text-sm">{name}</span>
              {retryCount > 0 && retryCount < 10 && (
                <span className="mt-2 w-4 h-4 rounded-full border-2 border-white/20 border-t-white/80 animate-spin" title="Generando portada..." />
              )}
            </div>
          )}
        </div>
      )}

      {/* Actual image — always in the DOM when no hard error, hidden via opacity until loaded */}
      {!hasError && (
        <img
          src={imageUrl}
          alt={`Cover for ${name}`}
          className={`absolute inset-0 w-full h-full object-cover transition-opacity duration-500 ${isLoaded ? 'opacity-100' : 'opacity-0'}`}
          loading="lazy"
          onLoad={handleLoad}
          onError={handleError}
        />
      )}
    </div>
  );
};
