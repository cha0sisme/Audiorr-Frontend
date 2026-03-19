/**
 * Caché global para avatares de artistas
 * Compartido entre todos los componentes que necesitan imágenes de artistas
 * Usa LRU para evitar crecimiento ilimitado de memoria
 * Persiste en sessionStorage para que un reload no vacíe el caché
 */

import { LRUCache } from './LRUCache'

const MAX_CACHED_AVATARS = 200
const STORAGE_KEY = 'audiorr:avatarCache'

const artistAvatarCache = new LRUCache<string, string | null>(MAX_CACHED_AVATARS)
const loadingPromises = new Map<string, Promise<string | null>>()

// Pre-populate from sessionStorage on module init (survives page reload within same tab)
try {
  const stored = sessionStorage.getItem(STORAGE_KEY)
  if (stored) {
    const entries = JSON.parse(stored) as [string, string | null][]
    if (Array.isArray(entries)) {
      entries.forEach(([k, v]) => artistAvatarCache.set(k, v))
    }
  }
} catch {
  // sessionStorage not available or corrupted — start fresh
}

/** Flush current cache entries to sessionStorage (best-effort, non-blocking) */
function persistToSession() {
  try {
    const entries = Array.from(artistAvatarCache.entries())
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify(entries))
  } catch {
    // quota exceeded or unavailable — silently ignore
  }
}

/**
 * Obtener la caché de avatares de artistas
 */
export const getArtistAvatarCache = () => artistAvatarCache

/**
 * Guardar un valor en la caché de avatares y persistir a sessionStorage
 */
export const setArtistAvatarCache = (key: string, value: string | null) => {
  artistAvatarCache.set(key, value)
  persistToSession()
}

/**
 * Obtener la caché de promesas de carga
 */
export const getLoadingPromises = () => loadingPromises
