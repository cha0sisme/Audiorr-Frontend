/**
 * Sistema de Cola con Prioridades para Análisis de Audio
 * Limita la concurrencia y gestiona prioridades de análisis
 */

export enum AnalysisPriority {
  HIGH = 0,    // Canción reproduciéndose actualmente
  MEDIUM = 1,  // Siguiente canción en cola
  LOW = 2,     // Resto (Smart Mix, batch análisis)
}

export interface AnalysisTask {
  id: string // Unique ID para la tarea
  songId: string
  songTitle: string
  streamUrl: string
  priority: AnalysisPriority
  isProactive: boolean
  addedAt: number
}

type AnalysisFunction = (
  streamUrl: string,
  songId: string,
  isProactive: boolean,
  signal?: AbortSignal
) => Promise<unknown>

export class AnalysisQueueManager {
  private queue: AnalysisTask[] = []
  private processing = false
  private currentTask: AnalysisTask | null = null
  private analyzeFn: AnalysisFunction | null = null
  private onProgressCallback?: (current: string | null, total: number) => void

  setAnalyzeFunction(fn: AnalysisFunction) {
    this.analyzeFn = fn
  }

  setProgressCallback(callback: (current: string | null, total: number) => void) {
    this.onProgressCallback = callback
  }

  /**
   * Añade una tarea a la cola con prioridad
   */
  enqueue(task: Omit<AnalysisTask, 'addedAt'>): void {
    // Verificar si ya existe en la cola
    const existingIndex = this.queue.findIndex(t => t.songId === task.songId)
    
    if (existingIndex !== -1) {
      // Si existe y la nueva prioridad es mayor (número menor), actualizar
      if (task.priority < this.queue[existingIndex].priority) {
        console.log(
          `[QUEUE] Actualizando prioridad de "${task.songTitle}" de ${this.queue[existingIndex].priority} a ${task.priority}`
        )
        this.queue[existingIndex] = { ...task, addedAt: Date.now() }
        this.sortQueue()
      } else {
        console.log(`[QUEUE] "${task.songTitle}" ya está en cola con prioridad ${this.queue[existingIndex].priority}`)
      }
      return
    }

    // Si es la canción que se está procesando ahora, ignorar
    if (this.currentTask && this.currentTask.songId === task.songId) {
      console.log(`[QUEUE] "${task.songTitle}" ya se está analizando`)
      return
    }

    const fullTask = { ...task, addedAt: Date.now() }
    this.queue.push(fullTask)
    this.sortQueue()
    
    console.log(
      `[QUEUE] Añadido "${task.songTitle}" con prioridad ${AnalysisPriority[task.priority]} (${this.queue.length} en cola)`
    )
    
    this.notifyProgress()
    
    // Iniciar procesamiento si no está en curso
    if (!this.processing) {
      this.processNext()
    }
  }

  /**
   * Reprioriza una canción específica (útil cuando cambia la canción actual)
   */
  reprioritize(songId: string, newPriority: AnalysisPriority): void {
    const task = this.queue.find(t => t.songId === songId)
    if (task && task.priority !== newPriority) {
      console.log(
        `[QUEUE] Repriorizando "${task.songTitle}" de ${AnalysisPriority[task.priority]} a ${AnalysisPriority[newPriority]}`
      )
      task.priority = newPriority
      this.sortQueue()
    }
  }

  /**
   * Baja la prioridad de todas las tareas de alta prioridad que ya no son actuales
   */
  demoteStaleHighPriority(currentSongId: string): void {
    let changed = false
    this.queue.forEach(task => {
      if (task.priority === AnalysisPriority.HIGH && task.songId !== currentSongId) {
        console.log(`[QUEUE] Bajando prioridad de tarea obsoleta: "${task.songTitle}"`)
        task.priority = AnalysisPriority.LOW
        changed = true
      }
    })
    if (changed) {
      this.sortQueue()
    }
  }

  /**
   * Ordena la cola por prioridad (menor número = mayor prioridad) y luego por tiempo
   */
  private sortQueue(): void {
    this.queue.sort((a, b) => {
      if (a.priority !== b.priority) {
        return a.priority - b.priority
      }
      return a.addedAt - b.addedAt
    })
  }

  /**
   * Procesa la siguiente tarea en la cola
   */
  private async processNext(): Promise<void> {
    if (this.processing || this.queue.length === 0 || !this.analyzeFn) {
      this.processing = false
      this.currentTask = null
      this.notifyProgress()
      return
    }

    this.processing = true
    const task = this.queue.shift()!
    this.currentTask = task
    
    console.log(
      `[QUEUE] Procesando (${AnalysisPriority[task.priority]}): "${task.songTitle}" (${this.queue.length} restantes)`
    )
    
    this.notifyProgress()

    try {
      const result = await this.analyzeFn(task.streamUrl, task.songId, task.isProactive)
      
      if (result) {
        console.log(`[QUEUE] ✅ Análisis completado: "${task.songTitle}"`)
      } else {
        console.log(`[QUEUE] ⚠️ Análisis sin resultado: "${task.songTitle}"`)
      }
    } catch (error) {
      console.error(`[QUEUE] ❌ Error analizando "${task.songTitle}":`, error)
    }

    this.currentTask = null
    this.processing = false

    // Continuar con la siguiente tarea después de un breve delay
    if (this.queue.length > 0) {
      setTimeout(() => this.processNext(), 100)
    } else {
      this.notifyProgress()
    }
  }

  /**
   * Notifica el progreso actual
   */
  private notifyProgress(): void {
    if (this.onProgressCallback) {
      const current = this.currentTask?.songTitle || null
      const total = this.queue.length + (this.currentTask ? 1 : 0)
      this.onProgressCallback(current, total)
    }
  }

  /**
   * Obtiene el estado actual de la cola
   */
  getStatus(): {
    queueLength: number
    processing: boolean
    currentTask: AnalysisTask | null
    nextTasks: AnalysisTask[]
  } {
    return {
      queueLength: this.queue.length,
      processing: this.processing,
      currentTask: this.currentTask,
      nextTasks: this.queue.slice(0, 5), // Primeras 5 tareas
    }
  }

  /**
   * Limpia la cola (útil al cerrar la app)
   */
  clear(): void {
    console.log(`[QUEUE] Limpiando cola (${this.queue.length} tareas descartadas)`)
    this.queue = []
    this.currentTask = null
    this.processing = false
    this.notifyProgress()
  }

  /**
   * Verifica si una canción está en la cola o procesándose
   */
  has(songId: string): boolean {
    if (this.currentTask && this.currentTask.songId === songId) {
      return true
    }
    return this.queue.some(t => t.songId === songId)
  }
}

// Singleton para uso global
export const analysisQueue = new AnalysisQueueManager()

