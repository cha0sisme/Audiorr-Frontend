/**
 * Persistent API response cache using IndexedDB.
 * Mirrors the in-memory `withCache` in navidromeApi but survives page reloads
 * and serves stale data when the device is offline.
 */

interface ApiCacheEntry {
  key: string
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  data: any
  savedAt: number
}

class ApiCacheService {
  private readonly DB_NAME = 'audiorr-api-cache'
  private readonly DB_VERSION = 1
  private readonly STORE = 'responses'
  private db: IDBDatabase | null = null

  private openDb(): Promise<IDBDatabase> {
    if (this.db) return Promise.resolve(this.db)
    return new Promise((resolve, reject) => {
      const req = indexedDB.open(this.DB_NAME, this.DB_VERSION)
      req.onupgradeneeded = () => {
        const db = req.result
        if (!db.objectStoreNames.contains(this.STORE)) {
          db.createObjectStore(this.STORE, { keyPath: 'key' })
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

  async get<T>(key: string): Promise<T | null> {
    try {
      const db = await this.openDb()
      return new Promise(resolve => {
        const req = db.transaction(this.STORE, 'readonly').objectStore(this.STORE).get(key)
        req.onsuccess = () =>
          resolve((req.result as ApiCacheEntry | undefined)?.data ?? null)
        req.onerror = () => resolve(null)
      })
    } catch {
      return null
    }
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  async put(key: string, data: any): Promise<void> {
    try {
      const db = await this.openDb()
      await new Promise<void>((resolve, reject) => {
        const entry: ApiCacheEntry = { key, data, savedAt: Date.now() }
        const req = db.transaction(this.STORE, 'readwrite').objectStore(this.STORE).put(entry)
        req.onsuccess = () => resolve()
        req.onerror = () => reject(req.error)
      })
    } catch {
      // Silently ignore storage errors (QuotaExceeded, etc.)
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
}

export const apiCacheService = new ApiCacheService()
