import { useState, useEffect, useRef } from 'react'
import { saveCanvasToBackend } from '../services/canvasService'
import { canvasCacheService } from '../services/canvasCacheService'
import type { Song } from '../services/navidromeApi'

// Resolve the best available canvas URL:
// 1. Local file served by backend (/api/canvas/files/TRACKID.mp4)  ← preferred
// 2. Spotify CDN URL (may expire, used as fallback)
const isDev = import.meta.env.DEV
const backendUrl = (import.meta.env.VITE_API_URL || 'http://localhost:3001').replace(/\/$/, '')

function resolveCanvasUrl(localPath: string | null, canvasUrl: string | null): string | null {
  if (localPath) {
    // localPath is stored as "/canvas-files/TRACKID.mp4"
    // The backend serves these at /api/canvas/files/TRACKID.mp4
    // Rewrite: /canvas-files/ → /api/canvas/files/
    const apiPath = localPath.replace(/^\/canvas-files\//, '/api/canvas/files/')
    return isDev ? apiPath : `${backendUrl}${apiPath}`
  }
  return canvasUrl ?? null
}

interface CanvasState {
  canvasUrl: string | null
  isLoading: boolean
  error: string | null
}

/**
 * Hook para obtener y gestionar el Canvas de una canción
 * @param song - Canción actual
 * @param enabled - Si está habilitado (por defecto: true)
 * @param apiBaseUrl - URL base de la API de Canvas (por defecto: http://192.168.1.43:3000)
 * @returns Estado del Canvas (URL, loading, error)
 */
export function useCanvas(song: Song | null, enabled: boolean = true): CanvasState {
  const [canvasUrl, setCanvasUrl] = useState<string | null>(null)
  const [isLoading, setIsLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // Cache en memoria para evitar consultas repetidas durante la misma sesión
  const cacheRef = useRef<Map<string, string | null>>(new Map())

  // Usar una ref para rastrear la canción actual y evitar llamadas duplicadas
  const currentSongIdRef = useRef<string | null>(null)
  
  // Ref para rastrear peticiones en curso y evitar duplicados
  const pendingRequestRef = useRef<Promise<void> | null>(null)
  
  // Ref para rastrear qué canciones ya se sincronizaron con el backend (evita duplicados)
  const syncedToBackendRef = useRef<Set<string>>(new Set())

  useEffect(() => {
    if (!enabled || !song) {
      setCanvasUrl(null)
      setIsLoading(false)
      setError(null)
      currentSongIdRef.current = null
      return
    }

    // Si es la misma canción, no hacer nada
    if (currentSongIdRef.current === song.id) {
      return
    }

    // Si hay una petición en curso para esta canción, esperar a que termine
    if (pendingRequestRef.current) {
      console.log(`[Canvas] Petición ya en curso para: ${song.title}, esperando...`)
      return
    }

    currentSongIdRef.current = song.id

    // Crear clave de caché basada en título y artista (para caché en memoria)
    const cacheKey = `${song.id}`

    // Verificar caché en memoria primero (más rápido)
    if (cacheRef.current.has(cacheKey)) {
      const cachedUrl = cacheRef.current.get(cacheKey) ?? null
      setCanvasUrl(cachedUrl)
      setIsLoading(false)
      return
    }

    setIsLoading(true)
    setError(null)

    // Helper para sincronizar con backend (solo si no se ha hecho antes)
    const syncToBackendIfNeeded = (data: {
      songId: string
      title: string
      artist: string
      album: string
      spotifyTrackId: string | null
      canvasUrl: string | null
    }) => {
      if (syncedToBackendRef.current.has(data.songId)) {
        // Ya se sincronizó esta canción, no hacer nada
        return
      }
      
      // Marcar como sincronizada ANTES de hacer la petición para evitar race conditions
      syncedToBackendRef.current.add(data.songId)
      
      saveCanvasToBackend(data).catch(err => {
        console.warn('[Canvas] Error sincronizando con backend:', err)
        // Si falla, permitir reintento removiendo del Set
        syncedToBackendRef.current.delete(data.songId)
      })
    }

    // Función async para cargar el Canvas
    const loadCanvas = async () => {
      pendingRequestRef.current = (async () => {
      try {
        // PASO 1: Consultar caché persistente (SQLite)
        const cachedEntry = await canvasCacheService.getBySongId(song.id)

        // Si encontramos una entrada en caché
        if (cachedEntry) {
          console.log(`[Canvas] Datos encontrados en caché persistente para: ${song.title}`)

          // Resolver la mejor URL disponible: archivo local primero, CDN como fallback
          const resolvedUrl = resolveCanvasUrl(cachedEntry.localPath ?? null, cachedEntry.canvasUrl)
          cacheRef.current.set(cacheKey, resolvedUrl)
          setCanvasUrl(resolvedUrl)
          setIsLoading(false)
          return
        }

        // Sin entrada en DB → sin canvas disponible
        // (Ya no podemos buscar nuevos TrackIDs — esperamos futura re-habilitación de Spotify API)
        console.log(`[Canvas] Sin canvas en DB para: ${song.title}`)
        cacheRef.current.set(cacheKey, null)
        setCanvasUrl(null)
        setIsLoading(false)
        return
      } catch (err) {
        const errorMessage = err instanceof Error ? err.message : 'Error desconocido'
        console.error('[Canvas] Error cargando Canvas:', err)
        setError(errorMessage)
        setCanvasUrl(null)
        // Guardar error en caché para no repetir búsquedas fallidas
        cacheRef.current.set(cacheKey, null)
        // Intentar guardar en caché persistente (aunque sea null)
        try {
          await canvasCacheService.set(song.id, song.title, song.artist, song.album, null, null)
          // Sincronizar al backend en segundo plano (sin esperar)
          syncToBackendIfNeeded({
            songId: song.id,
            title: song.title,
            artist: song.artist,
            album: song.album,
            spotifyTrackId: null,
            canvasUrl: null,
          })
        } catch (cacheError) {
          console.error('[Canvas] Error guardando en caché persistente:', cacheError)
        }
      } finally {
        setIsLoading(false)
        pendingRequestRef.current = null
      }
      })()
      
      await pendingRequestRef.current
    }

    loadCanvas()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [song?.id, enabled])

  return {
    canvasUrl,
    isLoading,
    error,
  }
}
