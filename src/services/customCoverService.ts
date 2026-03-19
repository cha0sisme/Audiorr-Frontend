import { LRUCache } from '../utils/LRUCache'

const CUSTOM_COVERS_KEY = 'audiorr-custom-playlist-covers'

// Caché en memoria para acceso rápido (LRU para evitar crecimiento ilimitado)
const memoryCache = new LRUCache<string, string>(100)

type Listener = () => void

class CustomCoverService {
  private covers: Record<string, string>
  private listeners: Set<Listener> = new Set()

  constructor() {
    this.covers = this.loadCovers()
    // Llenar la caché en memoria al iniciar
    for (const id in this.covers) {
      memoryCache.set(id, this.covers[id])
    }
  }

  private notify() {
    for (const listener of this.listeners) {
      try {
        listener()
      } catch (error) {
        console.error('Error notifying custom cover listener', error)
      }
    }
  }

  subscribe(listener: Listener) {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  private loadCovers(): Record<string, string> {
    try {
      const storedCovers = localStorage.getItem(CUSTOM_COVERS_KEY)
      return storedCovers ? JSON.parse(storedCovers) : {}
    } catch (error) {
      console.error('Error loading custom covers from localStorage:', error)
      return {}
    }
  }

  private saveCovers(): void {
    try {
      localStorage.setItem(CUSTOM_COVERS_KEY, JSON.stringify(this.covers))
    } catch (error) {
      console.error('Error saving custom covers to localStorage:', error)
    }
  }

  getCustomCover(playlistId: string): string | null {
    // Primero, intentar obtener de la caché en memoria
    if (memoryCache.has(playlistId)) {
      return memoryCache.get(playlistId) || null
    }
    // Si no está en memoria (caso raro), obtener del localStorage
    return this.covers[playlistId] || null
  }

  setCustomCover(playlistId: string, imageDataUrl: string): void {
    this.covers[playlistId] = imageDataUrl
    memoryCache.set(playlistId, imageDataUrl) // Actualizar caché en memoria
    this.saveCovers()
    this.notify()
  }

  removeCustomCover(playlistId: string): void {
    delete this.covers[playlistId]
    memoryCache.delete(playlistId) // Actualizar caché en memoria
    this.saveCovers()
    this.notify()
  }

  clearAll(): void {
    this.covers = {}
    memoryCache.clear()
    this.saveCovers()
    this.notify()
  }
}

export const customCoverService = new CustomCoverService()
