/**
 * Servicio básico de Crossfade Player para Automix
 * MVP: Crossfade simple sinplicado sin análisis DSP complejo
 */

export interface CrossfadeConfig {
  fadeDuration: number // en segundos
  songAOutTime?: number // punto de salida (opcional)
  songBInTime?: number // punto de entrada (opcional)
}

export class CrossfadePlayer {
  private audioContext: AudioContext
  private gainNodeA: GainNode
  private gainNodeB: GainNode
  private sourceA: AudioBufferSourceNode | null = null
  private sourceB: AudioBufferSourceNode | null = null
  private bufferA: AudioBuffer | null = null
  private bufferB: AudioBuffer | null = null
  private isCrossfading = false
  private currentConfig: CrossfadeConfig | null = null

  // Callbacks para eventos
  private onCrossfadeStart?: () => void
  private onCrossfadeComplete?: () => void
  private onSongComplete?: () => void

  constructor() {
    this.audioContext = new (window.AudioContext ||
      (window as Window & typeof globalThis & { webkitAudioContext: typeof AudioContext })
        .webkitAudioContext)()
    this.gainNodeA = this.audioContext.createGain()
    this.gainNodeB = this.audioContext.createGain()

    // Conectar a la salida con volumen inicial
    this.gainNodeA.connect(this.audioContext.destination)
    this.gainNodeB.connect(this.audioContext.destination)
    this.gainNodeA.gain.value = 1
    this.gainNodeB.gain.value = 0
  }

  /**
   * Configurar callbacks de eventos
   */
  setCallbacks(callbacks: {
    onCrossfadeStart?: () => void
    onCrossfadeComplete?: () => void
    onSongComplete?: () => void
  }) {
    this.onCrossfadeStart = callbacks.onCrossfadeStart
    this.onCrossfadeComplete = callbacks.onCrossfadeComplete
    this.onSongComplete = callbacks.onSongComplete
  }

  /**
   * Carga un buffer de audio desde una URL
   */
  async loadAudio(url: string): Promise<AudioBuffer> {
    try {
      console.log('[CROSSFADE] Cargando audio desde:', url)
      const response = await fetch(url)
      if (!response.ok) {
        throw new Error(`Failed to load audio: ${response.statusText}`)
      }
      const arrayBuffer = await response.arrayBuffer()
      console.log('[CROSSFADE] Audio cargado, tamaño:', arrayBuffer.byteLength)
      const audioBuffer = await this.audioContext.decodeAudioData(arrayBuffer)
      console.log('[CROSSFADE] Audio decodificado, duración:', audioBuffer.duration)
      return audioBuffer
    } catch (error) {
      console.error('[CROSSFADE] Error loading audio:', error)
      throw error
    }
  }

  /**
   * Prepara el crossfade entre dos canciones
   */
  async prepareCrossfade(
    songAUrl: string,
    songBUrl: string,
    config: CrossfadeConfig
  ): Promise<void> {
    console.log('[CROSSFADE] Preparando crossfade con config:', config)
    try {
      // Cargar ambas canciones en paralelo
      const [bufferA, bufferB] = await Promise.all([
        this.loadAudio(songAUrl),
        this.loadAudio(songBUrl),
      ])

      this.bufferA = bufferA
      this.bufferB = bufferB
      this.currentConfig = config
      console.log('[CROSSFADE] Buffers preparados exitosamente')
    } catch (error) {
      console.error('[CROSSFADE] Error preparando buffers:', error)
      throw error
    }
  }

  /**
   * Ejecuta el crossfade en tiempo real
   */
  startCrossfade(): void {
    console.log('[CROSSFADE] Intentando iniciar crossfade...', {
      hasBufferA: !!this.bufferA,
      hasBufferB: !!this.bufferB,
      isCrossfading: this.isCrossfading,
      hasConfig: !!this.currentConfig,
    })

    if (!this.bufferA || !this.bufferB || this.isCrossfading || !this.currentConfig) {
      throw new Error('Cannot start crossfade: buffers not ready')
    }

    this.isCrossfading = true
    console.log('[CROSSFADE] Crossfade marcado como activo')
    this.onCrossfadeStart?.()

    const now = this.audioContext.currentTime
    const fadeDuration = this.currentConfig.fadeDuration

    // 1. Configurar Source A (canción actual)
    this.sourceA = this.audioContext.createBufferSource()
    this.sourceA.buffer = this.bufferA

    // Usar punto de salida si está configurado, sino usar 0 (inicio)
    const offsetA = this.currentConfig.songAOutTime ?? 0

    this.sourceA.connect(this.gainNodeA)
    this.sourceA.start(now, offsetA)

    // Fade-out de A
    this.gainNodeA.gain.setValueAtTime(1, now)
    this.gainNodeA.gain.linearRampToValueAtTime(0, now + fadeDuration)

    // Al finalizar el fade-out, limpiar sourceA
    setTimeout(() => {
      this.sourceA?.stop()
      this.sourceA = null
    }, fadeDuration * 1000)

    // 2. Configurar Source B (siguiente canción)
    this.sourceB = this.audioContext.createBufferSource()
    this.sourceB.buffer = this.bufferB

    // Usar punto de entrada si está configurado, sino usar 0 (inicio)
    const offsetB = this.currentConfig.songBInTime ?? 0

    this.sourceB.connect(this.gainNodeB)
    this.sourceB.start(now, offsetB)

    // Fade-in de B
    this.gainNodeB.gain.setValueAtTime(0, now)
    this.gainNodeB.gain.linearRampToValueAtTime(1, now + fadeDuration)

    // Detectar cuando termine la canción B para notificar
    const songBDuration = this.bufferB.duration - offsetB
    setTimeout(() => {
      this.onSongComplete?.()
    }, songBDuration * 1000)

    // Notificar que el crossfade ha completado
    setTimeout(() => {
      this.onCrossfadeComplete?.()
    }, fadeDuration * 1000)
  }

  /**
   * Pausa la reproducción actual
   */
  pause(): void {
    if (this.isCrossfading) {
      // Detener ambas fuentes
      this.sourceA?.stop()
      this.sourceB?.stop()
      this.isCrossfading = false
    }
  }

  /**
   * Detiene y limpia todo
   */
  stop(): void {
    this.pause()
    this.bufferA = null
    this.bufferB = null
    this.sourceA = null
    this.sourceB = null
    this.currentConfig = null
  }

  /**
   * Obtiene el tiempo actual del contexto de audio
   */
  getCurrentTime(): number {
    return this.audioContext.currentTime
  }

  /**
   * Verifica si está reproduciendo (crossfade activo)
   */
  isPlaying(): boolean {
    return this.isCrossfading
  }

  /**
   * Limpia los recursos del AudioContext
   */
  dispose(): void {
    this.stop()
    this.audioContext.close()
  }
}
