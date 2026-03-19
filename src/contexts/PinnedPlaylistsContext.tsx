import {
  useCallback,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react'
import type { PinnedPlaylist } from '../types/playlist'
import { PinnedPlaylistsContext } from './PinnedPlaylistsContextObject'
import { navidromeApi } from '../services/navidromeApi'
import { backendApi } from '../services/backendApi'


function loadPinnedPlaylists(storageKey: string | null): PinnedPlaylist[] {
  if (!storageKey) return []
  try {
    const stored = localStorage.getItem(storageKey)
    if (!stored) return []
    const parsed = JSON.parse(stored)
    if (Array.isArray(parsed)) {
      return parsed
        .filter(item => typeof item?.id === 'string' && typeof item?.name === 'string')
        .map(item => normalizePinnedPlaylist(item as PinnedPlaylist))
    }
    return []
  } catch (error) {
    console.warn('[PinnedPlaylists] No se pudo cargar desde localStorage:', error)
    return []
  }
}

function persistPinnedPlaylists(storageKey: string | null, playlists: PinnedPlaylist[]) {
  if (!storageKey) return
  try {
    localStorage.setItem(storageKey, JSON.stringify(playlists))
  } catch (error) {
    console.warn('[PinnedPlaylists] No se pudo guardar en localStorage:', error)
  }
}

function normalizePinnedPlaylist(playlist: PinnedPlaylist): PinnedPlaylist {
  const trimmedName = playlist.name.trim()
  const trimmedOwner = typeof playlist.owner === 'string' ? playlist.owner.trim() : undefined
  const trimmedComment = typeof playlist.comment === 'string' ? playlist.comment.trim() : undefined
  const coverArt = typeof playlist.coverArt === 'string' ? playlist.coverArt.trim() : undefined
  const songCount = typeof playlist.songCount === 'number' && Number.isFinite(playlist.songCount) ? playlist.songCount : undefined
  const duration = typeof playlist.duration === 'number' && Number.isFinite(playlist.duration) ? playlist.duration : undefined
  const created = typeof playlist.created === 'string' ? playlist.created : undefined
  const changed = typeof playlist.changed === 'string' ? playlist.changed : undefined

  return {
    id: playlist.id,
    name: trimmedName.length > 0 ? trimmedName : 'Playlist sin nombre',
    owner: trimmedOwner && trimmedOwner.length > 0 ? trimmedOwner : undefined,
    comment: trimmedComment && trimmedComment.length > 0 ? trimmedComment : undefined,
    songCount,
    duration,
    created,
    changed,
    coverArt: coverArt && coverArt.length > 0 ? coverArt : undefined,
  }
}

// Cache global para evitar múltiples fetches simultáneos
let fetchPromise: Promise<PinnedPlaylist[]> | null = null
let lastFetchTime = 0
const FETCH_DEBOUNCE_MS = 1000 // No hacer más de 1 fetch por segundo

// Cache de sesión para evitar cargar las pinned playlists múltiples veces en la misma sesión
const SESSION_CACHE_KEY = 'audiorr:session:pinnedPlaylists:loaded'
const SESSION_CACHE_TTL = 1800000 // 30 minutos

function getSessionCache(username: string): PinnedPlaylist[] | null {
  try {
    const cached = sessionStorage.getItem(`${SESSION_CACHE_KEY}:${username}`)
    if (!cached) return null
    
    const { data, timestamp } = JSON.parse(cached)
    const now = Date.now()
    
    // Verificar si el cache sigue válido
    if (now - timestamp < SESSION_CACHE_TTL) {
      console.log('[PinnedPlaylists] 📦 Usando cache de sesión')
      return data
    }
    
    // Cache expirado, limpiar
    sessionStorage.removeItem(`${SESSION_CACHE_KEY}:${username}`)
    return null
  } catch (error) {
    return null
  }
}

function setSessionCache(username: string, data: PinnedPlaylist[]) {
  try {
    sessionStorage.setItem(`${SESSION_CACHE_KEY}:${username}`, JSON.stringify({
      data,
      timestamp: Date.now()
    }))
  } catch (error) {
    console.warn('[PinnedPlaylists] No se pudo guardar en sessionStorage:', error)
  }
}

export function PinnedPlaylistsProvider({ children }: { children: ReactNode }) {
  const initialConfig = navidromeApi.getConfig()
  const initialKey = initialConfig?.username ? `audiorr:pinnedPlaylists:${initialConfig.username}` : null

  const [storageKey, setStorageKey] = useState<string | null>(initialKey)
  const [pinnedPlaylists, setPinnedPlaylists] = useState<PinnedPlaylist[]>(() => loadPinnedPlaylists(initialKey))
  const [useBackend, setUseBackend] = useState(true) // Flag para saber si usar backend o localStorage

  // Cargar desde el backend al iniciar (con cache de sesión)
  useEffect(() => {
    const loadFromBackend = async () => {
      const config = navidromeApi.getConfig()
      if (!config?.username) {
        setStorageKey(null)
        setPinnedPlaylists([])
        return
      }

      const key = `audiorr:pinnedPlaylists:${config.username}`
      setStorageKey(key)

      // 📦 Verificar cache de sesión primero
      const sessionCached = getSessionCache(config.username)
        if (sessionCached) {
          setPinnedPlaylists(sessionCached)
          setUseBackend(true)
          return
        }

      // 🔒 Debounce: evitar múltiples fetches simultáneos
      const now = Date.now()
      if (fetchPromise && now - lastFetchTime < FETCH_DEBOUNCE_MS) {
        console.log('[PinnedPlaylists] ⚠️ Fetch ya en curso, reutilizando promesa existente')
        try {
          const backendPlaylists = await fetchPromise
          setPinnedPlaylists(backendPlaylists)
          persistPinnedPlaylists(key, backendPlaylists)
          setSessionCache(config.username, backendPlaylists)
          setUseBackend(true)
        } catch (error) {
          console.warn('[PinnedPlaylists] Error usando cache de fetch:', error)
          const localPlaylists = loadPinnedPlaylists(key)
          setPinnedPlaylists(localPlaylists)
          setUseBackend(false)
        }
        return
      }

      // Intentar cargar desde el backend
      lastFetchTime = now
      fetchPromise = backendApi.getPinnedPlaylists(config.username).then(playlists => {
        const normalized = playlists
          .filter(item => typeof item?.id === 'string' && typeof item?.name === 'string')
          .map(item => normalizePinnedPlaylist(item as PinnedPlaylist))
        return normalized
      })

      try {
        const backendPlaylists = await fetchPromise
        setPinnedPlaylists(backendPlaylists)
        // Sincronizar con localStorage y sessionStorage como caché
        persistPinnedPlaylists(key, backendPlaylists)
        setSessionCache(config.username, backendPlaylists)
        setUseBackend(true)
        console.log('[PinnedPlaylists] ✅ Playlists cargadas desde backend:', backendPlaylists.length)
      } catch (error) {
        console.warn('[PinnedPlaylists] No se pudo cargar desde el backend, usando localStorage:', error)
        // Fallback a localStorage si el backend no está disponible
        const localPlaylists = loadPinnedPlaylists(key)
        setPinnedPlaylists(localPlaylists)
        setUseBackend(false)
      } finally {
        // Limpiar la promesa después de 1 segundo
        setTimeout(() => {
          fetchPromise = null
        }, FETCH_DEBOUNCE_MS)
      }
    }

    loadFromBackend()
  }, [])

  useEffect(() => {
    if (!storageKey) return
    const handleStorage = (event: StorageEvent) => {
      if (event.key === storageKey) {
        setPinnedPlaylists(loadPinnedPlaylists(storageKey))
      }
    }
    window.addEventListener('storage', handleStorage)
    return () => window.removeEventListener('storage', handleStorage)
  }, [storageKey])

  const pinPlaylist = useCallback(
    async (playlist: PinnedPlaylist) => {
      const normalized = normalizePinnedPlaylist(playlist)
      setPinnedPlaylists(prev => {
        const existing = prev.find(item => item.id === normalized.id)
        if (existing) {
          if (
            existing.name === normalized.name &&
            existing.owner === normalized.owner &&
            existing.songCount === normalized.songCount &&
            existing.duration === normalized.duration &&
            existing.created === normalized.created &&
            existing.changed === normalized.changed &&
            existing.coverArt === normalized.coverArt &&
            existing.comment === normalized.comment
          ) {
            return prev
          }
          const updated = prev.map(item => (item.id === normalized.id ? normalized : item))
          persistPinnedPlaylists(storageKey, updated)
          // Guardar en backend y session cache si está disponible
          if (useBackend && storageKey) {
            const config = navidromeApi.getConfig()
            if (config?.username) {
              setSessionCache(config.username, updated) // Actualizar cache de sesión
              backendApi.savePinnedPlaylists(config.username, updated).catch(error => {
                console.error('[PinnedPlaylists] Error guardando en backend:', error)
              })
            }
          }
          return updated
        }
        const updated = [...prev, normalized]
        persistPinnedPlaylists(storageKey, updated)
        // Guardar en backend y session cache si está disponible
        if (useBackend && storageKey) {
          const config = navidromeApi.getConfig()
          if (config?.username) {
            setSessionCache(config.username, updated) // Actualizar cache de sesión
            backendApi.savePinnedPlaylists(config.username, updated).catch(error => {
              console.error('[PinnedPlaylists] Error guardando en backend:', error)
            })
          }
        }
        return updated
      })
    },
    [storageKey, useBackend],
  )

  const unpinPlaylist = useCallback(
    async (playlistId: string) => {
      setPinnedPlaylists(prev => {
        if (!prev.some(item => item.id === playlistId)) {
          return prev
        }
        const updated = prev.filter(item => item.id !== playlistId)
        persistPinnedPlaylists(storageKey, updated)
        // Guardar en backend y session cache si está disponible
        if (useBackend && storageKey) {
          const config = navidromeApi.getConfig()
          if (config?.username) {
            setSessionCache(config.username, updated) // Actualizar cache de sesión
            backendApi.savePinnedPlaylists(config.username, updated).catch(error => {
              console.error('[PinnedPlaylists] Error guardando en backend:', error)
            })
          }
        }
        return updated
      })
    },
    [storageKey, useBackend],
  )

  const togglePinnedPlaylist = useCallback(
    async (playlist: PinnedPlaylist) => {
      const normalized = normalizePinnedPlaylist(playlist)
      setPinnedPlaylists(prev => {
        const exists = prev.some(item => item.id === normalized.id)
        let updated: PinnedPlaylist[]
        if (exists) {
          updated = prev.filter(item => item.id !== normalized.id)
        } else {
          updated = [...prev, normalized]
        }
        persistPinnedPlaylists(storageKey, updated)
        // Guardar en backend y session cache si está disponible
        if (useBackend && storageKey) {
          const config = navidromeApi.getConfig()
          if (config?.username) {
            setSessionCache(config.username, updated) // Actualizar cache de sesión
            backendApi.savePinnedPlaylists(config.username, updated).catch(error => {
              console.error('[PinnedPlaylists] Error guardando en backend:', error)
            })
          }
        }
        return updated
      })
    },
    [storageKey, useBackend],
  )

  const isPinned = useCallback(
    (playlistId: string) => pinnedPlaylists.some(item => item.id === playlistId),
    [pinnedPlaylists],
  )

  const updatePinnedPlaylist = useCallback(
    async (playlist: PinnedPlaylist) => {
      const normalized = normalizePinnedPlaylist(playlist)
      setPinnedPlaylists(prev => {
        const existing = prev.find(item => item.id === normalized.id)
        if (!existing) {
          return prev
        }
        if (
          existing.name === normalized.name &&
          existing.owner === normalized.owner &&
          existing.songCount === normalized.songCount &&
          existing.duration === normalized.duration &&
          existing.created === normalized.created &&
          existing.changed === normalized.changed &&
          existing.coverArt === normalized.coverArt &&
          existing.comment === normalized.comment
        ) {
          return prev
        }
        const updated = prev.map(item => (item.id === normalized.id ? normalized : item))
        persistPinnedPlaylists(storageKey, updated)
        // Guardar en backend y session cache si está disponible
        if (useBackend && storageKey) {
          const config = navidromeApi.getConfig()
          if (config?.username) {
            setSessionCache(config.username, updated) // Actualizar cache de sesión
            backendApi.savePinnedPlaylists(config.username, updated).catch(error => {
              console.error('[PinnedPlaylists] Error guardando en backend:', error)
            })
          }
        }
        return updated
      })
    },
    [storageKey, useBackend],
  )

  const value = useMemo(
    () => ({
      pinnedPlaylists,
      pinPlaylist,
      unpinPlaylist,
      togglePinnedPlaylist,
      isPinned,
      updatePinnedPlaylist,
    }),
    [pinnedPlaylists, pinPlaylist, unpinPlaylist, togglePinnedPlaylist, isPinned, updatePinnedPlaylist],
  )

  return <PinnedPlaylistsContext.Provider value={value}>{children}</PinnedPlaylistsContext.Provider>
}



