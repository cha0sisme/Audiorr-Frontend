import { audioCacheService } from './audioCacheService'
import { navidromeApi, type Song } from './navidromeApi'

/**
 * Queue Prefetcher — descarga proactivamente las próximas canciones de la cola
 * a IndexedDB para reproducción sin cortes en escenarios de red inestable
 * (coche, VPN, cambios de antena 4G/5G).
 *
 * Similar a cómo Spotify/Apple Music pre-descargan canciones.
 */

const PREFETCH_AHEAD = 3 // Número de canciones a pre-cachear
const MAX_CONCURRENT = 1 // Descargas simultáneas (1 para no saturar la red)

class QueuePrefetcher {
  private activeFetches = new Map<string, AbortController>()
  private prefetchedIds = new Set<string>()
  private enabled = true

  /**
   * Llamar cada vez que cambia la canción actual o la cola.
   * Evalúa qué canciones faltan en cache y las descarga en background.
   */
  async prefetchQueue(queue: Song[], currentSongId: string): Promise<void> {
    if (!this.enabled || !audioCacheService.isAvailable()) return

    const currentIndex = queue.findIndex(s => s.id === currentSongId)
    if (currentIndex < 0) return

    // Canciones siguientes que necesitan pre-cache
    const upcoming = queue.slice(currentIndex + 1, currentIndex + 1 + PREFETCH_AHEAD)
    if (upcoming.length === 0) return

    // Cancelar fetches de canciones que ya no están en el rango
    const upcomingIds = new Set(upcoming.map(s => s.id))
    for (const [id, controller] of this.activeFetches) {
      if (!upcomingIds.has(id)) {
        controller.abort()
        this.activeFetches.delete(id)
      }
    }

    // Descargar las que faltan (secuencialmente para no saturar)
    let concurrent = 0
    for (const song of upcoming) {
      if (concurrent >= MAX_CONCURRENT) break
      if (this.activeFetches.has(song.id)) continue // Ya descargando
      if (this.prefetchedIds.has(song.id)) continue // Ya verificada en esta sesión

      // Verificar si ya está en IndexedDB
      const inCache = await audioCacheService.has(song.id)
      if (inCache) {
        this.prefetchedIds.add(song.id)
        continue
      }

      concurrent++
      this.fetchSong(song).catch(() => {
        // Silencioso — la descarga se reintentará en el siguiente ciclo
      })
    }
  }

  /**
   * Descarga una canción completa a IndexedDB.
   */
  private async fetchSong(song: Song): Promise<void> {
    const controller = new AbortController()
    this.activeFetches.set(song.id, controller)

    try {
      const streamUrl = navidromeApi.getStreamUrl(song.id, song.path)
      if (!streamUrl) return

      console.log(`[Prefetch] ⬇️ Descargando: "${song.title}" — ${song.artist}`)

      const response = await fetch(streamUrl, {
        signal: controller.signal,
      })

      if (!response.ok) {
        console.warn(`[Prefetch] ❌ HTTP ${response.status} para "${song.title}"`)
        return
      }

      const buffer = await response.arrayBuffer()

      // Verificar que no fue abortado durante la descarga
      if (controller.signal.aborted) return

      await audioCacheService.put(song.id, buffer, {
        title: song.title,
        artist: song.artist,
      })

      this.prefetchedIds.add(song.id)
      console.log(`[Prefetch] ✅ Cacheada: "${song.title}" (${(buffer.byteLength / 1024 / 1024).toFixed(1)} MB)`)
    } catch (err) {
      if (err instanceof DOMException && err.name === 'AbortError') return
      // Network error — silencioso, se reintentará
      console.debug(`[Prefetch] ⏳ Fallo temporal para "${song.title}":`, err)
    } finally {
      this.activeFetches.delete(song.id)
    }
  }

  /**
   * Obtiene un Blob URL para una canción cacheada, o null si no está en cache.
   * Usado por PlayerContext para reproducir desde cache local.
   */
  async getCachedBlobUrl(songId: string): Promise<string | null> {
    if (!audioCacheService.isAvailable()) return null

    const buffer = await audioCacheService.getBuffer(songId)
    if (!buffer) return null

    const blob = new Blob([buffer], { type: 'audio/mpeg' })
    return URL.createObjectURL(blob)
  }

  /**
   * Cancela todas las descargas activas.
   */
  cancelAll(): void {
    for (const [, controller] of this.activeFetches) {
      controller.abort()
    }
    this.activeFetches.clear()
  }

  setEnabled(enabled: boolean): void {
    this.enabled = enabled
    if (!enabled) this.cancelAll()
  }
}

export const queuePrefetcher = new QueuePrefetcher()
