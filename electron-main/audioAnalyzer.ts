import { spawn } from 'child_process'
import path from 'path'
import { app } from 'electron'
import { CacheManager } from './cacheManager'

export interface AnalysisResult {
  bpm: number
  beats: number[]
  beatInterval: number
  energy: number
  key?: string
  danceability?: number
  outroStartTime?: number
  introEndTime?: number
  vocalStartTime?: number
  speechSegments?: { start: number; end: number }[]
  structure?: { label: string; startTime: number; endTime: number }[]
  diagnostics?: {
    outro_detection_method?: string
    song_duration?: number
    final_decision?: string
    final_outro_start_time?: number
    intro_end_time?: number
    analysis_log?: Record<string, unknown>
    candidates?: Record<string, number>
    hierarchy_check?: {
      outro_speech_considered?: boolean
      outro_percussive_considered?: boolean
      outro_energy_considered?: boolean
      outro_instrumental_considered?: boolean
      outro_chorus_considered?: boolean
      final_outro_vs_intro_check?: boolean
    }
    [key: string]: unknown
  }
}

export class AudioAnalyzer {
  private scriptPath: string
  private pythonPath: string
  private cacheManager: CacheManager
  private pendingAnalyses = new Map<string, Promise<AnalysisResult | null>>()
  // 🔒 SEGURIDAD: Rastrear procesos Python activos para limpiarlos al cerrar la app
  private activeProcesses = new Set<ReturnType<typeof spawn>>()

  constructor(cacheManager: CacheManager) {
    this.cacheManager = cacheManager
    // Usar app.isPackaged es la forma canónica de Electron para diferenciar dev de prod.
    const isDev = !app.isPackaged

    this.scriptPath = isDev
      ? // En desarrollo, app.getAppPath() apunta a la raíz del proyecto.
        path.join(app.getAppPath(), 'scripts', 'analyze_audio.py')
      : // En producción, los scripts estarán en la carpeta de recursos.
        path.join(process.resourcesPath, 'scripts', 'analyze_audio.py')
    // Path a Python executable - usar 'python' en Windows
    this.pythonPath = process.env.PYTHON_PATH || 'python'
  }

  async analyzeWithCache(
    songId: string,
    filePath: string,
    isProactive = false
  ): Promise<AnalysisResult | null> {
    // 1. Check persistent cache first
    const cachedResult = this.cacheManager.get(songId)
    if (cachedResult) {
      console.log(`[CACHE] ✓ Hit for: ${songId}`)
      return cachedResult
    }

    // 2. Check if an analysis for this song is already in progress
    if (this.pendingAnalyses.has(songId)) {
      console.log(`[ANALYSIS_LOCK] ✓ Waiting for pending analysis of: ${songId}`)
      return this.pendingAnalyses.get(songId)!
    }

    console.log(`[IPC] Cache miss for: ${songId}`)

    // 3. No pending analysis, so start a new one and store the promise
    const analysisPromise = this.analyze(filePath)
      .then(analysisResult => {
        if (analysisResult) {
          this.cacheManager.set(songId, filePath, analysisResult, isProactive)
        }
        // Clean up the lock after completion
        this.pendingAnalyses.delete(songId)
        return analysisResult
      })
      .catch(error => {
        console.error(`[ANALYSIS_LOCK] Analysis failed for ${songId}:`, error)
        // Clean up the lock even on failure
        this.pendingAnalyses.delete(songId)
        return null
      })

    // Store the promise in the lock map
    this.pendingAnalyses.set(songId, analysisPromise)

    return analysisPromise
  }

  // 🔒 SEGURIDAD: Método público para limpiar todos los procesos Python activos
  public killAllProcesses(): void {
    console.log(`[AUDIO_ANALYZER] Limpiando ${this.activeProcesses.size} procesos Python activos...`)
    for (const process of this.activeProcesses) {
      try {
        if (!process.killed) {
          process.kill('SIGTERM') // Intento de terminación elegante
          // Si no termina en 1 segundo, forzar con SIGKILL
          setTimeout(() => {
            if (!process.killed) {
              process.kill('SIGKILL')
            }
          }, 1000)
        }
      } catch (error) {
        console.error('[AUDIO_ANALYZER] Error al matar proceso:', error)
      }
    }
    this.activeProcesses.clear()
  }

  private analyze(filePath: string): Promise<AnalysisResult | null> {
    return new Promise<AnalysisResult | null>((resolve, reject) => {
      const pythonProcess = spawn(this.pythonPath, ['-u', this.scriptPath, filePath])
      
      // 🔒 SEGURIDAD: Registrar proceso activo
      this.activeProcesses.add(pythonProcess)

      let analysisOutput = ''
      let errorOutput = ''

      pythonProcess.stdout.on('data', data => {
        analysisOutput += data.toString()
      })

      pythonProcess.stderr.on('data', data => {
        errorOutput += data.toString()
      })

      pythonProcess.on('close', code => {
        // 🔒 SEGURIDAD: Remover proceso del registro cuando termina
        this.activeProcesses.delete(pythonProcess)
        // Intenta analizar la salida JSON incluso si el código de salida no es 0.
        // El script de Python puede devolver un error específico en el JSON.
        try {
          if (analysisOutput.trim()) {
            const result: AnalysisResult | { error: string } = JSON.parse(analysisOutput.trim())

            if ('error' in result && result.error) {
              console.error(`[AUDIO_ANALYZER] Script error for ${filePath}:`, result.error)
              resolve(null)
              return
            }

            // Si no hay un campo 'error' pero el código de salida es malo, aún así es un fallo.
            if (code !== 0) {
              console.error(
                `[AUDIO_ANALYZER] Analysis failed for ${filePath} with exit code: ${code}`
              )
              if (errorOutput) console.error('[AUDIO_ANALYZER] Stderr:', errorOutput)
              resolve(null)
              return
            }

            console.log(
              `[AUDIO_ANALYZER] ✓ Analysis complete for ${path.basename(filePath)}: { bpm: ${
                (result as AnalysisResult).bpm
              }, beats: ${(result as AnalysisResult).beats.length}, introEnd: ${
                (result as AnalysisResult).introEndTime
              }, outroStart: ${(result as AnalysisResult).outroStartTime} }`
            )
            resolve(result as AnalysisResult)
          } else {
            // Si no hay salida JSON, recurrir al código de salida y stderr.
            if (code !== 0) {
              console.error(
                `[AUDIO_ANALYZER] Analysis failed for ${filePath} with exit code: ${code}`
              )
              if (errorOutput) {
                console.error('[AUDIO_ANALYZER] Stderr:', errorOutput)
              } else {
                console.error('[AUDIO_ANALYZER] Stderr: (empty)')
              }
            }
            resolve(null) // Resuelve null si no hay salida o si hay un error no JSON.
          }
        } catch (parseError) {
          console.error(
            `[AUDIO_ANALYZER] Failed to parse JSON from script for ${filePath}. Exit code: ${code}.`
          )
          console.error('[AUDIO_ANALYZER] Stdout:', analysisOutput.substring(0, 500))
          if (errorOutput) console.error('[AUDIO_ANALYZER] Stderr:', errorOutput)
          reject(new Error('Invalid JSON from analysis script'))
        }
      })

      pythonProcess.on('error', error => {
        // 🔒 SEGURIDAD: Remover proceso del registro en caso de error
        this.activeProcesses.delete(pythonProcess)
        console.error('[AUDIO_ANALYZER] Error spawning Python process:', error)
        reject(error)
      })
    })
  }
}
