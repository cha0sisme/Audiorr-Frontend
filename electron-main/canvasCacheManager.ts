import initSqlJs, { Database } from 'sql.js'
import path from 'path'
import fs from 'fs'
import { app } from 'electron'

export interface CanvasCacheEntry {
  songId: string
  spotifyTrackId: string | null
  canvasUrl: string | null
  title: string
  artist: string
  album?: string
  cachedAt: string
}

export class CanvasCacheManager {
  private db: Database | null = null
  private dbPath: string
  private initialized = false

  constructor() {
    this.dbPath = path.join(app.getPath('userData'), 'canvas-cache.db')
    this.initialize()
  }

  private async initialize() {
    try {
      const SQL = await initSqlJs()

      // Intentar cargar DB existente
      if (fs.existsSync(this.dbPath)) {
        const fileContent = fs.readFileSync(this.dbPath)
        this.db = new SQL.Database(fileContent)
        console.log('[CANVAS-CACHE] ✓ Database loaded from disk')
      } else {
        // Crear nueva DB
        this.db = new SQL.Database()
        console.log('[CANVAS-CACHE] ✓ New database created')
      }

      this.createTables()
      this.initialized = true
      console.log('[CANVAS-CACHE] ✓ Database initialized:', this.dbPath)
    } catch (error) {
      console.error('[CANVAS-CACHE] Failed to initialize database:', error)
    }
  }

  private createTables() {
    if (!this.db) return

    try {
      this.db.run(`
        CREATE TABLE IF NOT EXISTS canvas_cache (
          id INTEGER PRIMARY KEY,
          songId TEXT UNIQUE NOT NULL,
          spotifyTrackId TEXT,
          canvasUrl TEXT,
          title TEXT NOT NULL,
          artist TEXT NOT NULL,
          album TEXT,
          cachedAt DATETIME DEFAULT CURRENT_TIMESTAMP
        )
      `)

      // Crear índices para búsquedas rápidas
      try {
        this.db.run('CREATE INDEX IF NOT EXISTS idx_songId ON canvas_cache(songId)')
      } catch (e) {
        // Index might already exist
      }

      try {
        this.db.run('CREATE INDEX IF NOT EXISTS idx_title_artist ON canvas_cache(title, artist)')
      } catch (e) {
        // Index might already exist
      }

      console.log('[CANVAS-CACHE] Database tables ready')
      this.save()
    } catch (error) {
      console.error('[CANVAS-CACHE] Error creating tables:', error)
    }
  }

  private save() {
    if (!this.db) return

    try {
      const data = this.db.export()
      const buffer = Buffer.from(data)
      fs.writeFileSync(this.dbPath, buffer)
    } catch (error) {
      console.error('[CANVAS-CACHE] Error saving database:', error)
    }
  }

  /**
   * Obtiene la entrada de caché por songId
   */
  getBySongId(songId: string): CanvasCacheEntry | null {
    if (!this.initialized || !this.db) return null

    try {
      const stmt = this.db.prepare('SELECT * FROM canvas_cache WHERE songId = ?')
      stmt.bind([songId])

      if (stmt.step()) {
        const row = stmt.getAsObject()
        stmt.free()

        return {
          songId: row.songId as string,
          spotifyTrackId: (row.spotifyTrackId as string) || null,
          canvasUrl: (row.canvasUrl as string) || null,
          title: row.title as string,
          artist: row.artist as string,
          album: (row.album as string) || undefined,
          cachedAt: row.cachedAt as string,
        }
      }

      stmt.free()
      return null
    } catch (error) {
      console.error('[CANVAS-CACHE] Error reading by songId:', error)
      return null
    }
  }

  /**
   * Obtiene la entrada de caché por título y artista (útil si no tenemos songId)
   */
  getByTitleAndArtist(title: string, artist: string, album?: string): CanvasCacheEntry | null {
    if (!this.initialized || !this.db) return null

    try {
      let stmt
      if (album) {
        stmt = this.db.prepare(
          'SELECT * FROM canvas_cache WHERE title = ? AND artist = ? AND album = ? LIMIT 1'
        )
        stmt.bind([title, artist, album])
      } else {
        stmt = this.db.prepare('SELECT * FROM canvas_cache WHERE title = ? AND artist = ? LIMIT 1')
        stmt.bind([title, artist])
      }

      if (stmt.step()) {
        const row = stmt.getAsObject()
        stmt.free()

        return {
          songId: row.songId as string,
          spotifyTrackId: (row.spotifyTrackId as string) || null,
          canvasUrl: (row.canvasUrl as string) || null,
          title: row.title as string,
          artist: row.artist as string,
          album: (row.album as string) || undefined,
          cachedAt: row.cachedAt as string,
        }
      }

      stmt.free()
      return null
    } catch (error) {
      console.error('[CANVAS-CACHE] Error reading by title/artist:', error)
      return null
    }
  }

  /**
   * Guarda o actualiza una entrada en la caché
   */
  set(
    songId: string,
    title: string,
    artist: string,
    album: string | undefined,
    spotifyTrackId: string | null,
    canvasUrl: string | null
  ) {
    if (!this.initialized || !this.db) return

    try {
      const stmt = this.db.prepare(`
        INSERT OR REPLACE INTO canvas_cache 
        (songId, spotifyTrackId, canvasUrl, title, artist, album, cachedAt)
        VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
      `)

      stmt.bind([songId, spotifyTrackId || null, canvasUrl || null, title, artist, album || null])

      stmt.step()
      stmt.free()

      this.save()
      console.log(`[CANVAS-CACHE] ✓ Saved cache for: ${songId} (${title} - ${artist})`)
    } catch (error) {
      console.error('[CANVAS-CACHE] Error writing:', error)
    }
  }

  /**
   * Limpia toda la caché
   */
  async clearAll(): Promise<{ success: boolean; error?: string }> {
    if (!this.initialized || !this.db) {
      return { success: false, error: 'Database not initialized' }
    }

    try {
      this.db.run('DELETE FROM canvas_cache')
      this.db.run('VACUUM') // Reclama el espacio liberado
      this.save()
      console.log('[CANVAS-CACHE] ✓ Cache cleared and vacuumed')
      return { success: true }
    } catch (error) {
      console.error('[CANVAS-CACHE] Error clearing:', error)
      return { success: false, error: (error as Error).message }
    }
  }

  /**
   * Obtiene el tamaño de la caché en MB
   */
  getCacheSize(): number {
    if (!this.initialized || !fs.existsSync(this.dbPath)) {
      return 0
    }
    try {
      const stats = fs.statSync(this.dbPath)
      // Devolver tamaño en MB
      return stats.size / (1024 * 1024)
    } catch (error) {
      console.error('[CANVAS-CACHE] Error getting cache size:', error)
      return 0
    }
  }

  /**
   * Espera a que la base de datos esté inicializada
   */
  async waitForInitialization(): Promise<void> {
    const maxWait = 5000 // 5 segundos máximo
    const interval = 100 // Verificar cada 100ms
    let elapsed = 0

    while (!this.initialized && elapsed < maxWait) {
      await new Promise(resolve => setTimeout(resolve, interval))
      elapsed += interval
    }

    if (!this.initialized) {
      console.warn('[CANVAS-CACHE] Database initialization timeout')
    }
  }

  close() {
    if (this.db) {
      this.db.close()
      console.log('[CANVAS-CACHE] Database closed')
    }
  }
}
