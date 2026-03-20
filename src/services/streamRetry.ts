/**
 * Stream Retry — maneja reconexión automática cuando el stream de audio se corta.
 *
 * En escenarios de coche con VPN, el audio puede cortarse cuando:
 * - El móvil cambia de antena 4G/5G
 * - La VPN reconecta
 * - Se atraviesa una zona sin cobertura
 *
 * En vez de saltar a la siguiente canción (comportamiento actual),
 * este servicio reintenta el stream desde la posición actual con
 * exponential backoff.
 */

export interface StreamRetryCallbacks {
  /** Se llama cuando el retry está en curso (para mostrar indicador "Reconectando...") */
  onRetrying: (attempt: number, maxAttempts: number) => void
  /** Se llama cuando la reconexión fue exitosa */
  onRecovered: () => void
  /** Se llama cuando se agotan los reintentos */
  onGaveUp: () => void
}

export class StreamRetryManager {
  private retryCount = 0
  private retryTimer: ReturnType<typeof setTimeout> | null = null
  private currentSongId: string | null = null
  private isRetrying = false
  private callbacks: StreamRetryCallbacks | null = null

  // Configuración
  private readonly MAX_RETRIES = 8
  private readonly INITIAL_DELAY_MS = 1000
  private readonly MAX_DELAY_MS = 30000

  setCallbacks(callbacks: StreamRetryCallbacks): void {
    this.callbacks = callbacks
  }

  /**
   * Notifica que se cambió de canción. Resetea el estado de retry.
   */
  onSongChange(songId: string): void {
    this.reset()
    this.currentSongId = songId
  }

  /**
   * Llamar cuando el audio emite 'stalled' o 'error' por red.
   * Devuelve true si va a reintentar (el caller NO debe saltar canción).
   * Devuelve false si se agotaron los reintentos (el caller puede saltar).
   */
  shouldRetry(songId: string, errorCode?: number): boolean {
    // Solo reintentar errores de red (code 2 = MEDIA_ERR_NETWORK)
    // y stalls (sin errorCode)
    if (errorCode && errorCode !== 2) return false

    // No reintentar si cambió la canción
    if (songId !== this.currentSongId) return false

    if (this.retryCount >= this.MAX_RETRIES) {
      this.callbacks?.onGaveUp()
      this.reset()
      return false
    }

    return true
  }

  /**
   * Programa un reintento con exponential backoff.
   * Llama a `retryFn` cuando sea el momento de reintentar.
   */
  scheduleRetry(
    retryFn: () => Promise<void>
  ): void {
    if (this.isRetrying) return // Ya hay un retry programado

    this.retryCount++
    this.isRetrying = true

    const delay = Math.min(
      this.INITIAL_DELAY_MS * Math.pow(2, this.retryCount - 1),
      this.MAX_DELAY_MS
    )

    console.log(
      `[StreamRetry] Reintento ${this.retryCount}/${this.MAX_RETRIES} en ${(delay / 1000).toFixed(1)}s`
    )
    this.callbacks?.onRetrying(this.retryCount, this.MAX_RETRIES)

    this.retryTimer = setTimeout(async () => {
      try {
        await retryFn()
        // Si llegamos aquí, el retry fue exitoso
        console.log('[StreamRetry] ✅ Stream recuperado')
        this.callbacks?.onRecovered()
        this.retryCount = 0 // Resetear contador pero mantener currentSongId
      } catch {
        // El retry falló — se llamará shouldRetry() de nuevo desde el error handler
        console.debug('[StreamRetry] Reintento falló, esperando próximo ciclo')
      } finally {
        this.isRetrying = false
      }
    }, delay)
  }

  /**
   * Cancela cualquier retry pendiente y resetea el estado.
   */
  reset(): void {
    if (this.retryTimer) {
      clearTimeout(this.retryTimer)
      this.retryTimer = null
    }
    this.retryCount = 0
    this.isRetrying = false
  }

  getRetryCount(): number {
    return this.retryCount
  }

  getIsRetrying(): boolean {
    return this.isRetrying
  }

  dispose(): void {
    this.reset()
    this.callbacks = null
  }
}

export const streamRetryManager = new StreamRetryManager()
