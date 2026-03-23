import initSqlJs, { Database } from 'sql.js'
import path from 'path'
import fs from 'fs'
import { app } from 'electron'
import { AnalysisResult } from './audioAnalyzer'

export class CacheManager {
  private db: Database | null = null
  private dbPath: string
  private initialized = false

  constructor() {
    this.dbPath = path.join(app.getPath('userData'), 'analysis-cache.db')
    this.initialize()
  }

  private async initialize() {
    try {
      const SQL = await initSqlJs()

      // Intentar cargar DB existente
      if (fs.existsSync(this.dbPath)) {
        const fileContent = fs.readFileSync(this.dbPath)
        this.db = new SQL.Database(fileContent)
        console.log('[CACHE] ✓ Database loaded from disk')
      } else {
        // Crear nueva DB
        this.db = new SQL.Database()
        console.log('[CACHE] ✓ New database created')
      }

      this.createTables()
      this.initialized = true
      console.log('[CACHE] ✓ Database initialized:', this.dbPath)
    } catch (error) {
      console.error('[CACHE] Failed to initialize database:', error)
    }
  }

  private createTables() {
    if (!this.db) return

    try {
      this.db.run(`
        CREATE TABLE IF NOT EXISTS analysis_cache (
          id INTEGER PRIMARY KEY,
          songId TEXT UNIQUE NOT NULL,
          filePath TEXT,
          bpm REAL,
          beats TEXT,
          beatInterval REAL,
          energy REAL,
          key TEXT,
          danceability REAL,
          outroStartTime REAL,
          introEndTime REAL,
          analyzedAt DATETIME DEFAULT CURRENT_TIMESTAMP
        )
      `)

      // Crear índice
      try {
        this.db.run('CREATE INDEX IF NOT EXISTS idx_songId ON analysis_cache(songId)')
      } catch (e) {
        // Index might already exist
      }

      // Add a new column if it doesn't exist
      try {
        this.db.run('ALTER TABLE analysis_cache ADD COLUMN outroStartTime REAL')
      } catch (e) {
        // Column might already exist, which is fine
      }

      // Add a new column if it doesn't exist
      try {
        this.db.run('ALTER TABLE analysis_cache ADD COLUMN introEndTime REAL')
      } catch (e) {
        // Column might already exist, which is fine
      }

      // Add a new column for diagnostics if it doesn't exist
      try {
        this.db.run('ALTER TABLE analysis_cache ADD COLUMN diagnostics TEXT')
      } catch (e) {
        // Column might already exist, which is fine
      }

      console.log('[CACHE] Database tables ready')
      this.save()
    } catch (error) {
      console.error('[CACHE] Error creating tables:', error)
    }
  }

  private save() {
    if (!this.db) return

    try {
      const data = this.db.export()
      const buffer = Buffer.from(data)
      fs.writeFileSync(this.dbPath, buffer)
    } catch (error) {
      console.error('[CACHE] Error saving database:', error)
    }
  }

  get(songId: string): AnalysisResult | null {
    if (!this.initialized || !this.db) return null

    try {
      const stmt = this.db.prepare('SELECT * FROM analysis_cache WHERE songId = ?')
      stmt.bind([songId])

      if (stmt.step()) {
        const row = stmt.getAsObject()
        stmt.free()

        return {
          bpm: row.bpm as number,
          beats: row.beats ? JSON.parse(row.beats as string) : [],
          beatInterval: row.beatInterval as number,
          energy: row.energy as number,
          key: row.key as string | undefined,
          danceability: row.danceability as number | undefined,
          outroStartTime: row.outroStartTime as number | undefined,
          introEndTime: row.introEndTime as number | undefined,
          diagnostics: row.diagnostics ? JSON.parse(row.diagnostics as string) : undefined,
        }
      }

      stmt.free()
      return null
    } catch (error) {
      console.error('[CACHE] Error reading:', error)
      return null
    }
  }

  set(songId: string, filePath: string, result: AnalysisResult, isProactive = false) {
    if (!this.initialized || !this.db) return

    try {
      const stmt = this.db.prepare(`
        INSERT OR REPLACE INTO analysis_cache 
        (songId, filePath, bpm, beats, beatInterval, energy, key, danceability, outroStartTime, introEndTime, diagnostics)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `)

      stmt.bind([
        songId,
        filePath,
        result.bpm,
        JSON.stringify(result.beats || []),
        result.beatInterval,
        result.energy,
        result.key || null,
        result.danceability || null,
        result.outroStartTime || null,
        result.introEndTime || null,
        result.diagnostics ? JSON.stringify(result.diagnostics) : null,
      ])

      stmt.step()
      stmt.free()

      this.save()
      const logPrefix = isProactive ? '[PROACTIVE]' : '[CACHE]'
      console.log(`${logPrefix} ✓ Saved analysis for: ${songId}`)
    } catch (error) {
      console.error('[CACHE] Error writing:', error)
    }
  }

  async clearAll(): Promise<{ success: boolean; error?: string }> {
    if (!this.initialized || !this.db) {
      return { success: false, error: 'Database not initialized' }
    }

    try {
      this.db.run('DELETE FROM analysis_cache')
      this.db.run('VACUUM') // Reclama el espacio liberado en el fichero.
      this.save()
      console.log('[CACHE] ✓ Cache cleared and vacuumed')
      return { success: true }
    } catch (error) {
      console.error('[CACHE] Error clearing:', error)
      return { success: false, error: (error as Error).message }
    }
  }

  getCacheSize(): number {
    if (!this.initialized || !fs.existsSync(this.dbPath)) {
      return 0
    }
    try {
      const stats = fs.statSync(this.dbPath)
      // Devolver tamaño en MB
      return stats.size / (1024 * 1024)
    } catch (error) {
      console.error('[CACHE] Error getting cache size:', error)
      return 0
    }
  }

  close() {
    if (this.db) {
      this.db.close()
      console.log('[CACHE] Database closed')
    }
  }
}
