export interface CachedSongMeta {
  songId: string
  title: string
  artist: string
  size: number
  cachedAt: number
}

interface CachedSongEntry extends CachedSongMeta {
  data: ArrayBuffer
}

class AudioCacheService {
  private readonly DB_NAME = 'audiorr-audio-cache'
  private readonly DB_VERSION = 1
  private readonly STORE = 'audio'
  private db: IDBDatabase | null = null

  private openDb(): Promise<IDBDatabase> {
    if (this.db) return Promise.resolve(this.db)
    return new Promise((resolve, reject) => {
      const req = indexedDB.open(this.DB_NAME, this.DB_VERSION)
      req.onupgradeneeded = () => {
        const db = req.result
        if (!db.objectStoreNames.contains(this.STORE)) {
          db.createObjectStore(this.STORE, { keyPath: 'songId' })
        }
      }
      req.onsuccess = () => {
        this.db = req.result
        resolve(this.db)
      }
      req.onerror = () => reject(req.error)
    })
  }

  isAvailable(): boolean {
    return typeof indexedDB !== 'undefined'
  }

  async has(songId: string): Promise<boolean> {
    try {
      const db = await this.openDb()
      return new Promise(resolve => {
        const req = db.transaction(this.STORE, 'readonly').objectStore(this.STORE).count(songId)
        req.onsuccess = () => resolve(req.result > 0)
        req.onerror = () => resolve(false)
      })
    } catch {
      return false
    }
  }

  async getBuffer(songId: string): Promise<ArrayBuffer | null> {
    try {
      const db = await this.openDb()
      return new Promise(resolve => {
        const req = db.transaction(this.STORE, 'readonly').objectStore(this.STORE).get(songId)
        req.onsuccess = () => resolve((req.result as CachedSongEntry | undefined)?.data ?? null)
        req.onerror = () => resolve(null)
      })
    } catch {
      return null
    }
  }

  async put(
    songId: string,
    data: ArrayBuffer,
    meta: { title: string; artist: string }
  ): Promise<void> {
    try {
      const db = await this.openDb()
      await new Promise<void>((resolve, reject) => {
        const entry: CachedSongEntry = {
          songId,
          ...meta,
          data,
          size: data.byteLength,
          cachedAt: Date.now(),
        }
        const req = db.transaction(this.STORE, 'readwrite').objectStore(this.STORE).put(entry)
        req.onsuccess = () => resolve()
        req.onerror = () => reject(req.error)
      })
    } catch (err) {
      // Silently ignore QuotaExceededError and similar storage errors
      if (err instanceof DOMException && err.name === 'QuotaExceededError') return
    }
  }

  async remove(songId: string): Promise<void> {
    try {
      const db = await this.openDb()
      await new Promise<void>((resolve, reject) => {
        const req = db.transaction(this.STORE, 'readwrite').objectStore(this.STORE).delete(songId)
        req.onsuccess = () => resolve()
        req.onerror = () => reject(req.error)
      })
    } catch {
      // ignore
    }
  }

  async clearAll(): Promise<void> {
    try {
      const db = await this.openDb()
      await new Promise<void>((resolve, reject) => {
        const req = db.transaction(this.STORE, 'readwrite').objectStore(this.STORE).clear()
        req.onsuccess = () => resolve()
        req.onerror = () => reject(req.error)
      })
    } catch {
      // ignore
    }
  }

  async getAll(): Promise<CachedSongMeta[]> {
    try {
      const db = await this.openDb()
      return new Promise(resolve => {
        const results: CachedSongMeta[] = []
        const req = db
          .transaction(this.STORE, 'readonly')
          .objectStore(this.STORE)
          .openCursor()
        req.onsuccess = e => {
          const cursor = (e.target as IDBRequest<IDBCursorWithValue | null>).result
          if (cursor) {
            // eslint-disable-next-line @typescript-eslint/no-unused-vars
            const { data: _data, ...meta } = cursor.value as CachedSongEntry
            results.push(meta)
            cursor.continue()
          } else {
            resolve(results)
          }
        }
        req.onerror = () => resolve([])
      })
    } catch {
      return []
    }
  }

  async getTotalSize(): Promise<number> {
    const all = await this.getAll()
    return all.reduce((sum, s) => sum + s.size, 0)
  }
}

export const audioCacheService = new AudioCacheService()
