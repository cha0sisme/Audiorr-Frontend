/**
 * Persistent cover art cache using IndexedDB.
 * Stores raw image bytes keyed by coverArtId so album art is available offline.
 */

interface CoverArtEntry {
  id: string
  data: ArrayBuffer
  mimeType: string
  size: number
  cachedAt: number
}

class CoverArtCacheService {
  private readonly DB_NAME = 'audiorr-coverart-cache'
  private readonly DB_VERSION = 1
  private readonly STORE = 'covers'
  private db: IDBDatabase | null = null

  /** Tracks blob URLs created this session so we can revoke them on cleanup. */
  private blobUrls = new Map<string, string>()

  private cacheKey(coverArtId: string, size?: number): string {
    return size ? `${coverArtId}:${size}` : coverArtId
  }

  private openDb(): Promise<IDBDatabase> {
    if (this.db) return Promise.resolve(this.db)
    return new Promise((resolve, reject) => {
      const req = indexedDB.open(this.DB_NAME, this.DB_VERSION)
      req.onupgradeneeded = () => {
        const db = req.result
        if (!db.objectStoreNames.contains(this.STORE)) {
          db.createObjectStore(this.STORE, { keyPath: 'id' })
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

  /**
   * Returns a blob: URL for the cached image, or null if not cached.
   * Reuses existing blob URLs for the same id within a session.
   */
  async getBlobUrl(coverArtId: string, size?: number): Promise<string | null> {
    const key = this.cacheKey(coverArtId, size)
    // Reuse already-created blob URL for this session
    const existing = this.blobUrls.get(key)
    if (existing) return existing

    try {
      const db = await this.openDb()
      const entry = await new Promise<CoverArtEntry | null>(resolve => {
        const req = db.transaction(this.STORE, 'readonly').objectStore(this.STORE).get(key)
        req.onsuccess = () => resolve((req.result as CoverArtEntry | undefined) ?? null)
        req.onerror = () => resolve(null)
      })

      if (!entry) return null

      const blob = new Blob([entry.data], { type: entry.mimeType })
      const url = URL.createObjectURL(blob)
      this.blobUrls.set(key, url)
      return url
    } catch {
      return null
    }
  }

  /** Fetch and store an image from a URL. Call this in the background after successful load. */
  async cacheFromUrl(coverArtId: string, imageUrl: string, size?: number): Promise<void> {
    const key = this.cacheKey(coverArtId, size)
    try {
      const already = await this.has(coverArtId, size)
      if (already) return

      const response = await fetch(imageUrl)
      if (!response.ok) return

      const mimeType = response.headers.get('content-type') ?? 'image/jpeg'
      const data = await response.arrayBuffer()

      const db = await this.openDb()
      await new Promise<void>((resolve, reject) => {
        const entry: CoverArtEntry = {
          id: key,
          data,
          mimeType,
          size: data.byteLength,
          cachedAt: Date.now(),
        }
        const req = db.transaction(this.STORE, 'readwrite').objectStore(this.STORE).put(entry)
        req.onsuccess = () => resolve()
        req.onerror = () => reject(req.error)
      })
    } catch {
      // Silently ignore — caching is opportunistic
    }
  }

  async has(coverArtId: string, size?: number): Promise<boolean> {
    const key = this.cacheKey(coverArtId, size)
    try {
      const db = await this.openDb()
      return new Promise(resolve => {
        const req = db
          .transaction(this.STORE, 'readonly')
          .objectStore(this.STORE)
          .count(key)
        req.onsuccess = () => resolve(req.result > 0)
        req.onerror = () => resolve(false)
      })
    } catch {
      return false
    }
  }

  async clearAll(): Promise<void> {
    // Revoke all blob URLs
    this.blobUrls.forEach(url => URL.revokeObjectURL(url))
    this.blobUrls.clear()

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

export const coverArtCacheService = new CoverArtCacheService()
