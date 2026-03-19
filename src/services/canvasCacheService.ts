import type { CanvasCacheEntry } from '../types/electron'

import { backendApi } from './backendApi'

/**
 * Servicio para gestionar el caché persistente de Canvas consumiendo el backend REST.
 */
export class CanvasCacheService {
  /**
   * Obtiene la entrada de caché por songId
   */
  async getBySongId(songId: string): Promise<CanvasCacheEntry | null> {
    try {
      const entry = await backendApi.getCanvasBySongId(songId)
      return (entry as CanvasCacheEntry) ?? null
    } catch (error) {
      console.error('[CanvasCache] Error getting cache by songId:', error)
      return null
    }
  }

  /**
   * (No soportado) Obtener caché por título/artista.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  async getByTitleAndArtist(
    title: string,
    artist: string,
    album?: string
  ): Promise<CanvasCacheEntry | null> {
    console.warn('[CanvasCache] getByTitleAndArtist no está soportado en el backend')
    return null
  }

  /**
   * Guarda una entrada en la caché
   */
  async set(
    songId: string,
    title: string,
    artist: string,
    album: string | undefined,
    spotifyTrackId: string | null,
    canvasUrl: string | null
  ): Promise<boolean> {
    try {
      await backendApi.saveCanvas({
        songId,
        title,
        artist,
        album,
        spotifyTrackId,
        canvasUrl,
      })
      return true
    } catch (error) {
      console.error('[CanvasCache] Error setting cache:', error)
      return false
    }
  }

  /**
   * Limpia toda la caché (no implementado en backend todavía).
   */
  async clearAll(): Promise<boolean> {
    console.warn('[CanvasCache] clearAll no está implementado en el backend')
    return false
  }

  /**
   * Obtiene el tamaño de la caché en MB (no implementado en backend todavía).
   */
  async getCacheSize(): Promise<number> {
    console.warn('[CanvasCache] getCacheSize no está implementado en el backend')
    return 0
  }
}

// Instancia singleton
export const canvasCacheService = new CanvasCacheService()
