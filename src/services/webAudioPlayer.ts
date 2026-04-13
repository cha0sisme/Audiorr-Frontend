/**
 * 🎵 Web Audio API Player - Sistema avanzado de reproducción
 * 
 * Reproductor simplificado que delega el crossfade al CrossfadeEngine.
 * 
 * Responsabilidades de este módulo:
 * - Cargar y decodificar audio
 * - Play, pause, seek, volume
 * - Gestión de buffers y memoria
 * - Coordinar con CrossfadeEngine para transiciones
 */

import { Capacitor } from '@capacitor/core'
import { Song } from './navidromeApi'
import { audioBridge } from './audioBridge'
import { AudioAnalysisResult } from '../hooks/useAudioAnalysis'
import { audioCacheService } from './audioCacheService'
import {
  WebAudioPlayerConfig,
  PlaybackState,
  WebAudioPlayerCallbacks,
  MixMode,
} from './audio/types'
import { CrossfadeEngine, CrossfadeResources } from './audio/CrossfadeEngine'
import { calculateCrossfadeConfig } from './audio/DJMixingAlgorithms'

// Re-exportar tipos para compatibilidad con código existente
export type { WebAudioPlayerConfig, PlaybackState, WebAudioPlayerCallbacks }

export class WebAudioPlayer {
  // Audio Context y nodos principales
  private audioContext: AudioContext | null = null
  private gainNode: GainNode | null = null
  
  // Sources y buffers (modo buffer - puede crashear en Electron)
  private currentSource: AudioBufferSourceNode | null = null
  private nextSource: AudioBufferSourceNode | null = null
  private currentBuffer: AudioBuffer | null = null
  private nextBuffer: AudioBuffer | null = null
  
  // ⚡ PRE-DECODE CACHE: buffers ya decodificados listos para reproducir instantáneamente
  // Clave: songId, Valor: AudioBuffer ya decodificado
  private preDecodeCache: Map<string, AudioBuffer> = new Map()
  // AbortControllers para pre-cargas en vuelo (evitar memory leaks al cancelar)
  private preDecodeAbortControllers: Map<string, AbortController> = new Map()
  // Máximo de buffers en caché (LRU simple: eliminar el más antiguo)
  private readonly MAX_PREDECODE_CACHE = 4
  
  // 🔧 ELECTRON FIX: Modo MediaElement (más estable)
  private useMediaElementMode = false
  private mediaElement: HTMLAudioElement | null = null
  private mediaElementSource: MediaElementAudioSourceNode | null = null
  private mediaElementGain: GainNode | null = null
  private mediaElementLowpass: BiquadFilterNode | null = null // Para outro (salida)
  
  // MediaElement para crossfade (siguiente canción)
  private nextMediaElement: HTMLAudioElement | null = null
  private nextMediaElementSource: MediaElementAudioSourceNode | null = null
  private nextMediaElementGain: GainNode | null = null
  private nextMediaElementHighpass: BiquadFilterNode | null = null // Para intro (entrada)

  // 🔇 iOS KEEPALIVE: AVAudioPlayer nativo (via AudioBridgePlugin) que reproduce
  // silencio para mantener AVAudioSession activa cuando la pantalla se bloquea.
  // Antes era un HTMLAudioElement, pero WKWebView lo detectaba como media activa
  // y sobreescribía MPNowPlayingInfoCenter con duration=1s, elapsed=0.
  private iosKeepAliveStarted = false

  // ⚡ HTML FALLBACK: reproducción instantánea para canciones no cacheadas
  // Fase 1: HTML audio empieza inmediatamente; Fase 2: decode en background;
  // Fase 3: switch silencioso (80ms) a WebAudio; Fase 4: CrossfadeEngine disponible
  private htmlFallback: HTMLAudioElement | null = null
  private htmlFallbackGain: GainNode | null = null
  private htmlFallbackSource: MediaElementAudioSourceNode | null = null
  private htmlFallbackAbortController: AbortController | null = null
  private isHtmlFallbackActive = false
  private isSwitchingToWebAudio = false
  private htmlFallbackTimeInterval: NodeJS.Timeout | null = null
  
  // Canciones
  private currentSong: Song | null = null
  private nextSong: Song | null = null

  // Estado de reproducción
  private isPlaying = false
  private duration = 0
  private volume = 0.75
  private isCrossfading = false
  /** Timestamp (ms) en que arrancó el último crossfade — para detectar estado estancado */
  private crossfadeStartedAt = 0

  // Blob URL for currently cached song served from IndexedDB
  private currentBlobUrl: string | null = null

  // Callbacks
  private callbacks: WebAudioPlayerCallbacks = {}

  // Análisis y configuración
  private currentAnalysis: AudioAnalysisResult | null = null
  private nextAnalysis: AudioAnalysisResult | null = null
  private isDjMode = false
  private useReplayGain = true
  private crossfadeInterval: NodeJS.Timeout | null = null

  private getReplayGainMultiplier(song: Song | null): number {
    if (!this.useReplayGain || !song) return 1
    
    // Si la canción no tiene etiqueta, atenuamos -8.0 dB por defecto para igualar la 
    // reducción promedio del ReplayGain (-18 LUFS) y evitar que suenen brutalmente más fuertes.
    let targetDb = -8.0 
    
    if (song.replayGain) {
      const rawGain = song.replayGain.trackGain ?? song.replayGain.albumGain
      if (rawGain !== undefined && rawGain !== null) {
        // Manejar comas como puntos si la API las devuelve así: "-8,40 dB" -> "-8.40"
        const parsedGain = typeof rawGain === 'number' ? rawGain : parseFloat(String(rawGain).replace(',', '.'))
        if (!isNaN(parsedGain)) {
          targetDb = parsedGain
        }
      }
    }

    // Calcular multiplicador base (V = 10 ^ (dB / 20))
    let multiplier = Math.pow(10, targetDb / 20)

    // Prevenir True Peak Clipping si tenemos el track peak o album peak
    if (song.replayGain) {
      const rawPeak = song.replayGain.trackPeak ?? song.replayGain.albumPeak
      if (rawPeak !== undefined && rawPeak !== null) {
        const parsedPeak = typeof rawPeak === 'number' ? rawPeak : parseFloat(String(rawPeak).replace(',', '.'))
        // Si el pico multiplicador supera 1.0 (0 dBFS digital clip), reducir la ganancia
        if (!isNaN(parsedPeak) && parsedPeak > 0) {
          const maxMultiplier = 0.99 / parsedPeak // Dejamos un ínfimo headroom (0.99)
          if (multiplier > maxMultiplier) {
            console.log(`[ReplayGain] Clipping prevenido para "${song.title}": De ${multiplier.toFixed(2)} -> ${maxMultiplier.toFixed(2)} (Peak: ${parsedPeak})`)
            multiplier = maxMultiplier
          }
        }
      }
    }

    return multiplier
  }

  private updateGain(): void {
    if (this.useMediaElementMode) {
      // In MediaElement mode the audio chain is: source → lowpass → mediaElementGain → gainNode.
      // To avoid applying volume twice we keep gainNode as a unity pass-through (1.0) and
      // apply volume + ReplayGain exclusively through mediaElementGain.
      if (this.gainNode) {
        this.gainNode.gain.value = 1.0
      }
      if (this.mediaElementGain) {
        const multiplier = this.getReplayGainMultiplier(this.currentSong)
        const targetGain = this.volume * multiplier
        if (this.audioContext && this.audioContext.state === 'running') {
          const now = this.audioContext.currentTime
          this.mediaElementGain.gain.cancelScheduledValues(now)
          this.mediaElementGain.gain.linearRampToValueAtTime(targetGain, now + 0.1)
        } else {
          this.mediaElementGain.gain.value = targetGain
        }
      }
      return
    }

    // Buffer mode: gainNode is the sole volume control.
    if (this.gainNode) {
      if (this.isCrossfading) {
        // CrossfadeEngine manages per-source multipliers; master gain = pure volume.
        const targetGain = this.volume
        if (this.audioContext && this.audioContext.state === 'running') {
          const now = this.audioContext.currentTime
          this.gainNode.gain.cancelScheduledValues(now)
          this.gainNode.gain.linearRampToValueAtTime(targetGain, now + 0.1)
        } else {
          this.gainNode.gain.value = targetGain
        }
      } else {
        const multiplier = this.getReplayGainMultiplier(this.currentSong)
        const targetGain = this.volume * multiplier
        if (this.audioContext && this.audioContext.state === 'running') {
          const now = this.audioContext.currentTime
          this.gainNode.gain.cancelScheduledValues(now)
          this.gainNode.gain.linearRampToValueAtTime(targetGain, now + 0.1)
        } else {
          this.gainNode.gain.value = targetGain
        }
      }
    }
  }

  // ── Audio cache helpers ──────────────────────────────────────────────────────

  private static songArtistString(song: Song): string {
    if (!song.artist) return ''
    if (Array.isArray(song.artist)) {
      return song.artist
        .map((a: unknown) =>
          typeof a === 'object' && a !== null && 'name' in a
            ? String((a as { name: unknown }).name)
            : String(a)
        )
        .join(', ')
    }
    return String(song.artist)
  }

  /**
   * After the current song finishes playing from the network, store its MP3
   * bytes in IndexedDB so future plays are instant and work offline.
   */
  private scheduleMediaElementCache(song: Song, streamUrl: string): void {
    if (!audioCacheService.isAvailable() || !this.mediaElement) return

    const handler = () => {
      this.mediaElement?.removeEventListener('ended', handler)
      audioCacheService.has(song.id).then(exists => {
        if (exists) return
        fetch(streamUrl)
          .then(r => (r.ok ? r.arrayBuffer() : null))
          .then(buf => {
            if (buf) {
              audioCacheService.put(song.id, buf, {
                title: song.title,
                artist: WebAudioPlayer.songArtistString(song),
              }).catch(() => {})
            }
          })
          .catch(() => {})
      })
    }

    this.mediaElement.addEventListener('ended', handler, { once: true })
  }

  // Control de preparación
  private isPreparingNext = false
  
  // Control de cancelación de carga
  private currentLoadAbortController: AbortController | null = null

  // Control de tiempo
  private playStartTime: number = 0
  private playOffset: number = 0
  private pauseTime = 0
  private timeUpdateInterval: NodeJS.Timeout | null = null

  // Protección contra background/foreground: cuando iOS suspende WKWebView,
  // los setInterval se acumulan y disparan todos de golpe al volver.
  // Esto corrompe crossfades (100 steps de golpe), rompe AutoMix, y desincroniza tiempos.
  private isBackgrounded = false
  private visibilityHandler: (() => void) | null = null
  private backgroundTimestamp = 0 // Cuándo entró al background (ms)
  private suppressOnEnded = false // Suprimir onended falsos al volver del background

  // Motor de crossfade
  private crossfadeEngine: CrossfadeEngine

  // Detectar si estamos en Electron
  private isElectron = typeof window !== 'undefined' &&
    (window.navigator.userAgent.toLowerCase().includes('electron') ||
     'electron' in window)

  // En iOS/Android nativo (Capacitor), HTMLAudioElement.play() falla tras múltiples awaits
  // porque se rompe la cadena de gesto de usuario — usar buffer mode directamente
  private isNative = Capacitor.isNativePlatform()

  constructor() {
    this.crossfadeEngine = new CrossfadeEngine()
    // En Electron, usar MediaElement (decodeAudioData crashea silenciosamente)
    // Pero usamos DJMixingAlgorithms para los cálculos (misma lógica que web)
    this.useMediaElementMode = this.isElectron
    if (this.isElectron) {
      console.log('[WebAudioPlayer] 🖥️ Electron detectado - usando MediaElement + DJMixingAlgorithms')
    }
    this.initializeAudioContext()
  }
  
  // Método público para saber si crossfade está disponible
  isCrossfadeSupported(): boolean {
    // Crossfade está soportado en ambos modos ahora
    return true
  }

  // Método público para saber si hay una fuente de audio cargada
  hasSource(): boolean {
    if (this.useMediaElementMode) {
      return !!(this.mediaElement && this.mediaElement.src && this.mediaElement.src !== '')
    }
    return !!this.currentBuffer || this.isHtmlFallbackActive
  }

  // Método público para forzar la posición de pausa antes de play(keepPosition=true)
  // Necesario cuando se restaura estado tras un refresh, donde pauseTime interno es 0
  setPauseTime(time: number): void {
    if (isFinite(time) && time >= 0) {
      this.pauseTime = time
    }
  }

  // ===========================================================================
  // INICIALIZACIÓN
  // ===========================================================================

  private async initializeAudioContext() {
    try {
      // latencyHint: 'playback' usa buffers grandes, evitando underruns por latencia
      // de red (WiFi, Bluetooth, CarPlay inalámbrico). 'interactive' (default) usa
      // buffers mínimos que causan tirones en conexiones wireless.
      this.audioContext = new (window.AudioContext ||
        (window as Window & typeof globalThis & { webkitAudioContext: typeof AudioContext })
          .webkitAudioContext)({ latencyHint: 'playback' })

      this.gainNode = this.audioContext.createGain()
      this.gainNode.connect(this.audioContext.destination)
      this.gainNode.gain.value = this.volume

      // DOM AudioSession: indica a WebKit que esto es reproducción de medios.
      // Esto evita que iOS suspenda el AudioContext cuando la app pasa a background
      // o la pantalla se bloquea (webkit.org/b/237878, webkit.org/b/261554).
      if ('audioSession' in navigator) {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        ;(navigator as any).audioSession.type = 'playback'
      }

      // Bucle silencioso en el AudioContext — mantiene el scheduler activo en TODOS los modos.
      // En iOS, esto evita que el sistema suspenda el AudioContext durante el background/bloqueo.
      const silentBuffer = this.audioContext.createBuffer(1, 1, this.audioContext.sampleRate)
      const silentSource = this.audioContext.createBufferSource()
      silentSource.buffer = silentBuffer
      silentSource.loop = true
      silentSource.connect(this.audioContext.destination)
      silentSource.start(0)

      // El keepalive nativo (AVAudioPlayer) se arranca bajo demanda en _startKeepAlive()
      // al llamar a play(), no hace falta pre-inicializarlo aquí.

      // Si iOS suspende el contexto, reanudar SIEMPRE que estemos reproduciendo.
      // Esto es CRÍTICO para que los crossfades en background funcionen: las automaciones
      // de Web Audio (linearRampToValueAtTime etc.) necesitan que el contexto esté "running".
      // NO filtrar por isBackgrounded — el contexto DEBE estar vivo en background para audio.
      // La protección contra Bluetooth/CarPlay ya está en _audioRouteLost que pone isPlaying=false.
      this.audioContext.onstatechange = () => {
        const state = this.audioContext?.state
        if ((state === 'suspended' || state === ('interrupted' as AudioContextState)) && this.isPlaying) {
          console.log(`[WebAudioPlayer] AudioContext ${state} mientras reproduciendo — reanudando`)
          this.audioContext!.resume().catch((err) => {
            console.warn('[WebAudioPlayer] onstatechange resume() falló:', err)
          })
        }
      }

      // Gestión de background/foreground:
      // - Al ir a background: marcar estado para que los timers se ignoren
      // - Al volver: reanudar AudioContext, cancelar crossfade corrupto, resincronizar
      if (this.visibilityHandler) {
        document.removeEventListener('visibilitychange', this.visibilityHandler)
      }
      this.visibilityHandler = () => {
        if (document.hidden) {
          this.isBackgrounded = true
          this.backgroundTimestamp = Date.now()
        } else {
          this._handleReturnFromBackground()
        }
      }
      document.addEventListener('visibilitychange', this.visibilityHandler)

      console.log('[WebAudioPlayer] AudioContext inicializado correctamente, estado:', this.audioContext.state)
    } catch (error) {
      console.error('[WebAudioPlayer] Error inicializando AudioContext:', error)
      throw error
    }
  }

  // ===========================================================================
  // 🔇 iOS KEEPALIVE — AVAudioPlayer nativo via AudioBridgePlugin
  // ===========================================================================
  // Antes usaba un HTMLAudioElement con un WAV de 1s en loop. WKWebView lo
  // detectaba como media activa y sobreescribía MPNowPlayingInfoCenter con
  // duration=1s, elapsed=0 → la barra de progreso del lock screen se quedaba
  // en 0:00-0:01. Ahora el keepalive es un AVAudioPlayer nativo que iOS no
  // asocia con WKWebView, eliminando el conflicto de raíz.

  /**
   * Arranca el keepalive nativo. Llamar ANTES de cualquier await en play()
   * para que el gesto de usuario aún esté activo.
   */
  private _startKeepAlive(): void {
    if (!this.isNative || this.iosKeepAliveStarted) return
    this.iosKeepAliveStarted = true
    audioBridge.startKeepAlive()
    console.log('[WebAudioPlayer] 🔇 Keepalive nativo solicitado')
  }

  /**
   * Detiene el keepalive nativo. Solo llamar al destruir el player,
   * NUNCA al pausar — si se para, iOS suspende el WKWebView y los
   * remote commands del lock screen dejan de llegar a JavaScript.
   */
  private _stopKeepAlive(): void {
    if (!this.isNative || !this.iosKeepAliveStarted) return
    this.iosKeepAliveStarted = false
    audioBridge.stopKeepAlive()
  }

  // ===========================================================================
  // PROTECCIÓN BACKGROUND → FOREGROUND
  // ===========================================================================
  // iOS suspende WKWebView al bloquear pantalla. Los setInterval se acumulan y
  // al volver disparan TODOS de golpe. Esto causa: crossfade corrupto (100 steps
  // instantáneos), AutoMix se dispara múltiples veces, tiempos desincronizados.

  private _handleReturnFromBackground(): void {
    if (!this.isBackgrounded) return
    this.isBackgrounded = false

    const suspensionDuration = Date.now() - this.backgroundTimestamp
    const isDeepSuspension = suspensionDuration > 120_000 // >2 minutos
    const wasPlaying = this.isPlaying
    const savedPosition = this.getCurrentTime()
    const savedSong = this.currentSong
    const savedDuration = this.duration

    console.log(`[WebAudioPlayer] 📱 Volviendo del background (suspendido ${(suspensionDuration / 1000).toFixed(0)}s, wasPlaying: ${wasPlaying}, deep: ${isDeepSuspension})`)

    // PROTECCIÓN CRÍTICA: suprimir onended falsos durante la recuperación.
    // iOS puede disparar onended en el BufferSourceNode al reanudar el AudioContext
    // después de una suspensión, lo que haría que la app intente next() en lugar de
    // continuar la canción actual. Suprimimos durante 2 segundos.
    if (wasPlaying && !this.useMediaElementMode) {
      this.suppressOnEnded = true
      setTimeout(() => { this.suppressOnEnded = false }, 2000)
    }

    // 1. Si hay un crossfade en curso, finalizarlo inmediatamente.
    //    Los steps acumulados ya lo corrompieron — mejor terminar limpio.
    if (this.isCrossfading && this.crossfadeInterval) {
      console.log('[WebAudioPlayer] ⚠️ Crossfade corrupto tras background — finalizando')
      clearInterval(this.crossfadeInterval)
      this.crossfadeInterval = null

      if (this.useMediaElementMode) {
        if (this.nextMediaElementGain) {
          const gainB = this.getReplayGainMultiplier(this.nextSong) * this.volume
          this.nextMediaElementGain.gain.value = gainB
        }
        if (this.mediaElementGain) {
          this.mediaElementGain.gain.value = 0
        }
        if (this.mediaElementLowpass) this.mediaElementLowpass.frequency.value = 20000
        if (this.nextMediaElementHighpass) this.nextMediaElementHighpass.frequency.value = 60
        if (this.nextSong) {
          this.finalizeCrossfadeMediaElement(0)
        }
      } else {
        this.isCrossfading = false
      }
    }

    // 2. Reanudar AudioContext — con reintentos y reconstrucción si falla
    this._resumeAudioContextRobust(wasPlaying, savedPosition, savedSong, savedDuration, isDeepSuspension)
  }

  /**
   * Reanuda el AudioContext de forma robusta tras una suspensión de iOS.
   * Si resume() falla o el contexto queda en estado inválido, reconstruye
   * todo el pipeline de audio y reanuda la reproducción desde donde estaba.
   */
  private async _resumeAudioContextRobust(
    wasPlaying: boolean,
    savedPosition: number,
    savedSong: Song | null,
    savedDuration: number,
    isDeepSuspension: boolean
  ): Promise<void> {
    if (!this.audioContext) return

    const contextState = this.audioContext.state
    console.log(`[WebAudioPlayer] 🔧 Estado AudioContext: ${contextState}`)

    // Intentar resume() estándar primero
    if (contextState === 'suspended' || contextState === ('interrupted' as AudioContextState)) {
      try {
        await this.audioContext.resume()
        console.log(`[WebAudioPlayer] ✅ AudioContext resumido: ${this.audioContext.state}`)
      } catch (err) {
        console.warn('[WebAudioPlayer] ⚠️ resume() falló:', err)
      }
    }

    // Verificar si el contexto realmente está funcionando
    const contextOk = this.audioContext.state === 'running'

    // Si fue una suspensión profunda O el contexto no se recuperó,
    // reconstruir todo el pipeline de audio
    if (!contextOk || (isDeepSuspension && wasPlaying && !this.useMediaElementMode)) {
      console.log('[WebAudioPlayer] 🔄 Reconstruyendo pipeline de audio...')
      await this._reconstructAudioPipeline(wasPlaying, savedPosition, savedSong, savedDuration)
      return
    }

    // El contexto se recuperó correctamente — solo resincronizar
    if (wasPlaying) {
      // En modo buffer, verificar que el source sigue vivo
      if (!this.useMediaElementMode && !this.isHtmlFallbackActive) {
        if (!this.currentSource) {
          // El source murió durante la suspensión — reconstruir
          console.log('[WebAudioPlayer] ⚠️ currentSource perdido — reconstruyendo')
          await this._reconstructAudioPipeline(wasPlaying, savedPosition, savedSong, savedDuration)
          return
        }
      }

      // Reiniciar los time updates para evitar callbacks acumulados
      if (this.useMediaElementMode && this.mediaElement) {
        this.startMediaElementTimeUpdates()
      } else if (this.isHtmlFallbackActive) {
        this._startHtmlFallbackTimeUpdates()
      } else if (this.currentSource) {
        this.startTimeUpdates()
      }

      // Emitir un time update fresco para resincronizar la UI
      if (this.duration > 0) {
        const currentTime = this.getCurrentTime()
        if (isFinite(currentTime)) {
          this.callbacks.onTimeUpdate?.(currentTime, this.duration)
        }
      }
    }
  }

  /**
   * Reconstruye completamente el pipeline de audio: cierra el contexto antiguo,
   * crea uno nuevo, y reanuda la canción desde la posición guardada.
   * Este es el "nuclear option" para cuando iOS deja el audio en un estado irrecuperable.
   */
  private async _reconstructAudioPipeline(
    wasPlaying: boolean,
    savedPosition: number,
    savedSong: Song | null,
    savedDuration: number
  ): Promise<void> {
    // Guardar el estado antes de destruir
    const position = isFinite(savedPosition) && savedPosition > 0 ? savedPosition : this.pauseTime
    const song = savedSong || this.currentSong
    const buffer = this.currentBuffer // Preservar el buffer decodificado

    // Limpiar el source actual sin que dispare onended
    if (this.currentSource) {
      this.currentSource.onended = null
      try { this.currentSource.stop() } catch { /* ya parado */ }
      this.currentSource = null
    }
    this.stopTimeUpdates()
    this.isPlaying = false
    this.isCrossfading = false
    this.crossfadeEngine.forceReset()

    // Cerrar el contexto viejo
    try {
      this.audioContext?.close()
    } catch { /* ignorar */ }
    this.audioContext = null
    this.gainNode = null

    // Recrear AudioContext fresco
    await this.initializeAudioContext()

    // Asignar a variables locales DESPUÉS de initializeAudioContext para que TS
    // pueda hacer narrowing correctamente (this.audioContext fue reasignado dentro)
    const freshCtx = this.audioContext as AudioContext | null
    const freshGain = this.gainNode as GainNode | null
    if (!freshCtx || !freshGain || !song) {
      console.error('[WebAudioPlayer] ❌ No se pudo reconstruir el AudioContext')
      return
    }

    console.log(`[WebAudioPlayer] 🔄 Pipeline reconstruido. Reanudando "${song.title}" desde ${position.toFixed(1)}s`)

    // Si tenemos el buffer en memoria, reanudar directamente
    if (buffer && !this.useMediaElementMode) {
      this.currentBuffer = buffer
      this.currentSong = song
      this.duration = savedDuration > 0 ? savedDuration : buffer.duration

      // Crear nuevo source y reanudar desde la posición
      this.currentSource = freshCtx.createBufferSource()
      this.currentSource.buffer = buffer
      this.currentSource.connect(freshGain)
      this.updateGain()

      this.playStartTime = freshCtx.currentTime
      this.playOffset = Math.min(position, this.duration - 0.5)
      this.pauseTime = this.playOffset

      if (wasPlaying) {
        this.currentSource.start(this.playStartTime, this.playOffset)
        this.isPlaying = true

        this.currentSource.onended = () => {
          if (this.suppressOnEnded) {
            console.log('[WebAudioPlayer] ⚡ onended suprimido (post-reconstrucción)')
            return
          }
          this.isPlaying = false
          this.callbacks.onEnded?.()
        }

        this.startTimeUpdates()

        // Notificar a la UI que seguimos reproduciendo
        this.callbacks.onTimeUpdate?.(this.playOffset, this.duration)
        console.log('[WebAudioPlayer] ✅ Reproducción reanudada tras reconstrucción')
      }
    } else {
      // No tenemos buffer — forzar que el PlayerContext recargue la canción
      // Guardar posición para que se restaure
      this.pauseTime = position
      this.currentSong = song
      this.duration = savedDuration

      if (wasPlaying) {
        // Notificar al PlayerContext vía callback especial que necesitamos recargar
        console.log('[WebAudioPlayer] ⚠️ Buffer perdido — solicitando recarga al PlayerContext')
        this.callbacks.onRecoveryNeeded?.(song, position)
      }
    }
  }

  // 🔧 Método para asegurar que AudioContext está activo (importante para Electron)
  private async ensureAudioContextReady(): Promise<void> {
    if (!this.audioContext) {
      await this.initializeAudioContext()
    }
    
    // En Electron, el AudioContext puede quedar en estado "suspended"
    // Necesitamos resumirlo explícitamente
    if (this.audioContext && this.audioContext.state === 'suspended') {
      console.log('[WebAudioPlayer] AudioContext suspended, resumiendo...')
      try {
        await this.audioContext.resume()
        console.log('[WebAudioPlayer] AudioContext resumido correctamente, nuevo estado:', this.audioContext.state)
      } catch (error) {
        console.error('[WebAudioPlayer] Error resumiendo AudioContext:', error)
        // Intentar recrear el contexto
        try {
          this.audioContext.close()
        } catch { /* ignorar */ }
        this.audioContext = null
        await this.initializeAudioContext()
      }
    }
    
    // Verificar que el contexto está realmente activo
    if (this.audioContext?.state !== 'running') {
      console.warn('[WebAudioPlayer] AudioContext no está en estado running:', this.audioContext?.state)
    }
  }

  // ===========================================================================
  // CONFIGURACIÓN
  // ===========================================================================

  setCallbacks(callbacks: WebAudioPlayerCallbacks) {
    this.callbacks = { ...this.callbacks, ...callbacks }
    
    // Configurar callbacks del CrossfadeEngine
    this.crossfadeEngine.setCallbacks({
      onCrossfadeStart: () => this.callbacks.onCrossfadeStart?.(),
      onCrossfadeComplete: (nextSong, startOffset) => {
        this.callbacks.onCrossfadeComplete?.(nextSong, startOffset)
      },
    })
  }

  setConfig(config: Partial<WebAudioPlayerConfig>) {
    let requiresGainUpdate = false
    
    if (config.useReplayGain !== undefined && this.useReplayGain !== config.useReplayGain) {
      this.useReplayGain = config.useReplayGain
      requiresGainUpdate = true
    }

    if (config.volume !== undefined && Math.abs((this.volume * 100) - config.volume) > 1) {
      this.volume = Math.max(0, Math.min(1, config.volume / 100))
      requiresGainUpdate = true
    }
    
    if (requiresGainUpdate) {
      this.updateGain()
    }

    if (config.isDjMode !== undefined) {
      this.isDjMode = config.isDjMode
    }
  }

  setCurrentAnalysis(analysis: AudioAnalysisResult | null): void {
    this.currentAnalysis = analysis
  }

  setNextAnalysis(analysis: AudioAnalysisResult | null): void {
    this.nextAnalysis = analysis
    if (analysis) {
      console.log('[WebAudioPlayer] 🔄 nextAnalysis actualizado dinámicamente:', analysis.introEndTime ?? '?')
    }
  }

  // ===========================================================================
  // ⚡ PRE-DECODE CACHE
  // ===========================================================================

  /**
   * Pre-decodifica una canción en background y la guarda en caché.
   * Cuando el usuario haga click en esa canción, play() la usará instantáneamente.
   * Solo funciona en modo Buffer (no Electron/MediaElement).
   */
  async preloadBuffer(songId: string, url: string): Promise<void> {
    // No hacer nada en modo MediaElement (Electron) - ya tiene streaming
    if (this.useMediaElementMode) return
    // Ya está en caché
    if (this.preDecodeCache.has(songId)) return
    // Ya se está cargando
    if (this.preDecodeAbortControllers.has(songId)) return
    // No hay AudioContext aún
    if (!this.audioContext) return

    const abortController = new AbortController()
    this.preDecodeAbortControllers.set(songId, abortController)
    const { signal } = abortController

    console.log(`[PreDecode] 📥 Pre-decodificando en background: ${songId}`)

    try {
      // Fetch con baja prioridad para no competir con la reproducción actual
      const response = await fetch(url, {
        signal,
        priority: 'low',
      } as RequestInit)
      if (!response.ok) throw new Error(`HTTP ${response.status}`)

      const arrayBuffer = await response.arrayBuffer()

      // Verificar que no fue cancelado ni que el AudioContext desapareció
      if (signal.aborted || !this.audioContext) return

      const audioBuffer = await this.audioContext.decodeAudioData(arrayBuffer.slice(0))

      // Verificar de nuevo tras la decodificación (puede tardar segundos)
      if (signal.aborted) return

      // Evición LRU simple: si el caché está lleno, eliminar la entrada más antigua
      if (this.preDecodeCache.size >= this.MAX_PREDECODE_CACHE) {
        const oldestKey = this.preDecodeCache.keys().next().value
        if (oldestKey) {
          this.preDecodeCache.delete(oldestKey)
          console.log(`[PreDecode] 🗑️ Evicted oldest buffer: ${oldestKey}`)
        }
      }

      this.preDecodeCache.set(songId, audioBuffer)
      console.log(`[PreDecode] ✅ Buffer listo en caché: ${songId} (${audioBuffer.duration.toFixed(1)}s)`)
    } catch (error) {
      // AbortError es esperado cuando se cancela - no loguear como error
      if (error instanceof DOMException && error.name === 'AbortError') {
        console.log(`[PreDecode] 🚫 Pre-carga cancelada: ${songId}`)
        return
      }
      // Otros errores son silenciosos - es solo pre-carga, no es crítico
      console.log(`[PreDecode] ⚠️ No se pudo pre-decodificar ${songId}:`, error)
    } finally {
      this.preDecodeAbortControllers.delete(songId)
    }
  }

  /** Cancela y elimina una pre-carga en vuelo y/o su buffer del caché */
  private evictFromPreDecodeCache(songId: string): void {
    // Cancelar pre-carga en vuelo si existe
    const controller = this.preDecodeAbortControllers.get(songId)
    if (controller) {
      controller.abort()
      this.preDecodeAbortControllers.delete(songId)
    }
    if (this.preDecodeCache.delete(songId)) {
      console.log(`[PreDecode] 🗑️ Evicted from cache after use: ${songId}`)
    }
  }

  /** Cancela todas las pre-cargas en vuelo y limpia el caché */
  clearPreDecodeCache(): void {
    // Abortar todas las pre-cargas en vuelo para evitar memory leaks
    for (const [songId, controller] of this.preDecodeAbortControllers) {
      controller.abort()
      console.log(`[PreDecode] 🚫 Abortando pre-carga en vuelo: ${songId}`)
    }
    this.preDecodeAbortControllers.clear()
    this.preDecodeCache.clear()
    console.log('[PreDecode] 🧹 Cache limpiado')
  }

  // ===========================================================================
  // CARGA DE AUDIO
  // ===========================================================================

  async loadAudio(
    url: string,
    signal?: AbortSignal,
    songId?: string,
    songMeta?: { title: string; artist: string }
  ): Promise<AudioBuffer> {
    if (!this.audioContext) {
      throw new Error('AudioContext no inicializado')
    }

    try {
      this.callbacks.onLoadStart?.()

      // ── Cache hit: decode stored MP3 bytes without network ──────────────────
      if (songId && audioCacheService.isAvailable()) {
        const cached = await audioCacheService.getBuffer(songId)
        if (cached) {
          if (signal?.aborted) throw new DOMException('Carga cancelada', 'AbortError')
          let audioBuffer: AudioBuffer
          try {
            audioBuffer = await this.audioContext.decodeAudioData(cached.slice(0))
          } catch {
            // Corrupted cache entry — remove and fall through to network
            await audioCacheService.remove(songId)
            return this.loadAudio(url, signal, undefined)
          }
          this.callbacks.onLoadedMetadata?.(audioBuffer.duration)
          this.callbacks.onCanPlay?.()
          return audioBuffer
        }
      }

      // ── Network fetch ────────────────────────────────────────────────────────
      const response = await fetch(url, { signal } as RequestInit)
      if (!response.ok) throw new Error(`HTTP ${response.status}: ${response.statusText}`)
      if (signal?.aborted) throw new DOMException('Carga cancelada', 'AbortError')

      const arrayBuffer = await response.arrayBuffer()
      if (signal?.aborted) throw new DOMException('Carga cancelada', 'AbortError')

      // ── Store in cache (buffer mode gets this for free) ──────────────────────
      if (songId && audioCacheService.isAvailable()) {
        audioCacheService
          .put(songId, arrayBuffer.slice(0), songMeta ?? { title: '', artist: '' })
          .catch(() => {})
      }

      let audioBuffer: AudioBuffer
      try {
        audioBuffer = await this.audioContext.decodeAudioData(arrayBuffer.slice(0))
      } catch (decodeError) {
        console.error('[WebAudioPlayer] ❌ Error decodificando audio:', decodeError)
        throw new Error(`Formato de audio no soportado por Web Audio API: ${decodeError}`)
      }

      this.callbacks.onLoadedMetadata?.(audioBuffer.duration)
      this.callbacks.onCanPlay?.()
      return audioBuffer
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') {
        throw error
      }
      console.error('[WebAudioPlayer] ❌ Error cargando audio:', error)
      this.callbacks.onError?.(error instanceof Error ? error : new Error(String(error)))
      throw error
    }
  }

  // ===========================================================================
  // REPRODUCCIÓN
  // ===========================================================================

  async play(song: Song, streamUrl: string, keepPosition = false): Promise<void> {
    try {
      // 🔑 iOS: arrancar keepalive AQUÍ, antes de cualquier await, mientras el
      // gesto del usuario sigue activo en la cadena de llamadas
      this._startKeepAlive()

      console.log('[WebAudioPlayer] Reproduciendo canción:', song.title)
      console.log('[WebAudioPlayer] Modo:', this.useMediaElementMode ? 'MediaElement (Electron)' : 'AudioBuffer (Web)')

      // 🔧 ELECTRON FIX: Asegurar que AudioContext está listo antes de reproducir
      await this.ensureAudioContextReady()

      // =========================================================================
      // 🖥️ MODO MEDIA ELEMENT (Electron) - Evita decodeAudioData que crashea
      // =========================================================================
      if (this.useMediaElementMode) {
        await this.playWithMediaElement(song, streamUrl, keepPosition)
        return
      }

      // =========================================================================
      // 🌐 MODO BUFFER (Web) - Usa decodeAudioData tradicional
      // =========================================================================

      // 🚀 Cancelar cualquier carga pendiente inmediatamente
      if (this.currentLoadAbortController) {
        console.log('[WebAudioPlayer] Cancelando carga anterior...')
        this.currentLoadAbortController.abort()
        this.currentLoadAbortController = null
      }

      // Crear nuevo AbortController para esta carga
      this.currentLoadAbortController = new AbortController()
      const signal = this.currentLoadAbortController.signal

      // Guardar referencia a buffers anteriores para logging
      const oldCurrentBuffer = this.currentBuffer
      const oldNextBuffer = this.nextBuffer

      this.stop()

      // 🧹 Liberar memoria explícitamente antes de cargar nuevo audio
      if (oldCurrentBuffer || oldNextBuffer) {
        this.currentBuffer = null
        this.nextBuffer = null
        if (typeof window !== 'undefined' && 'gc' in window) {
          try { (window as Window & { gc?: () => void }).gc?.() } catch { /* ignorar */ }
        }
      }

      // Log de liberación de memoria
      if (oldCurrentBuffer) {
        console.log(`[WebAudioPlayer] 💾 Buffer anterior liberado (${(oldCurrentBuffer.duration * 44100 * 2 * 2 / 1024 / 1024).toFixed(1)}MB aprox)`)
      }
      if (oldNextBuffer) {
        console.log(`[WebAudioPlayer] 💾 NextBuffer anterior liberado (${(oldNextBuffer.duration * 44100 * 2 * 2 / 1024 / 1024).toFixed(1)}MB aprox)`)
      }

      // ⚡ CACHE HIT: usar buffer pre-decodificado si está disponible
      const cachedBuffer = this.preDecodeCache.get(song.id)
      if (cachedBuffer) {
        console.log(`[WebAudioPlayer] ⚡ CACHE HIT para "${song.title}" - reproducción instantánea!`)
        this.currentBuffer = cachedBuffer
        this.evictFromPreDecodeCache(song.id)
      } else {
        // Comprobar si está en IndexedDB (~200ms) o solo en red (2-10s)
        const isInIndexedDB = audioCacheService.isAvailable() && await audioCacheService.has(song.id)
        if (signal.aborted) {
          console.log('[WebAudioPlayer] Reproducción cancelada durante check de caché')
          return
        }

        if (isInIndexedDB) {
          console.log(`[WebAudioPlayer] 💾 IndexedDB HIT para "${song.title}" - cargando buffer...`)
          this.currentBuffer = await this.loadAudio(streamUrl, signal, song.id, {
            title: song.title,
            artist: WebAudioPlayer.songArtistString(song),
          })
        } else if (!this.isNative) {
          // ⚡ INSTANT PLAY (web): la canción no está en caché — arrancar HTML audio
          // inmediatamente mientras se descarga y decodifica en background,
          // luego switch silencioso a WebAudio.
          // En iOS/Android nativo se omite: HTMLAudioElement.play() falla tras múltiples
          // awaits (cadena de gesto rota). El buffer mode ya funciona vía AudioContext.
          console.log(`[WebAudioPlayer] ⚡ INSTANT PLAY para "${song.title}" - HTML fallback...`)
          this.currentSong = song
          this.duration = song.duration || 0
          await this._startHtmlFallback(song, streamUrl, signal)
          return // retornar para que PlayerContext llame setIsPlaying(true) al instante
        } else {
          // Nativo (iOS/Android): buffer mode normal — la canción se carga por red
          console.log(`[WebAudioPlayer] 📥 Nativo: cargando buffer para "${song.title}"...`)
          this.currentBuffer = await this.loadAudio(streamUrl, signal, song.id, {
            title: song.title,
            artist: WebAudioPlayer.songArtistString(song),
          })
        }
      }
      
      // Verificar si fue cancelado después de cargar
      if (signal.aborted) {
        console.log('[WebAudioPlayer] Reproducción cancelada después de cargar')
        this.currentBuffer = null
        return
      }

      this.currentSong = song
      this.duration = this.currentBuffer.duration
      const bufferMemoryMB = (this.currentBuffer.duration * this.currentBuffer.sampleRate * this.currentBuffer.numberOfChannels * 4 / 1024 / 1024).toFixed(1)
      console.log(`[WebAudioPlayer] 💾 Buffer en memoria: ~${bufferMemoryMB}MB (${this.currentBuffer.duration.toFixed(1)}s @ ${this.currentBuffer.sampleRate}Hz)`)

      // Verificar de nuevo que el contexto está activo
      console.log('[WebAudioPlayer] 🔄 Verificando AudioContext antes de crear source...')
      if (this.audioContext?.state !== 'running') {
        console.log('[WebAudioPlayer] ⚠️ AudioContext no está running, intentando reanudar...')
        await this.ensureAudioContextReady()
      }
      console.log('[WebAudioPlayer] ✅ AudioContext state:', this.audioContext?.state)

      // Crear source
      console.log('[WebAudioPlayer] 🎚️ Creando BufferSourceNode...')
      this.currentSource = this.audioContext!.createBufferSource()
      console.log('[WebAudioPlayer] 🎚️ Asignando buffer al source...')
      this.currentSource.buffer = this.currentBuffer
      console.log('[WebAudioPlayer] 🔊 Conectando source al gainNode...')
      this.currentSource.connect(this.gainNode!)
      
      // 🔊 IMPORTANTE: Aplicar volumen y ReplayGain ANTES de empezar a sonar
      // Esto corrige el bug donde la primera canción de un SmartMix ignora el volumen
      this.updateGain()

      // Configurar tiempo
      console.log('[WebAudioPlayer] ⏱️ Configurando tiempos de reproducción...')
      this.playStartTime = this.audioContext!.currentTime
      if (!keepPosition) {
        this.pauseTime = 0
      }
      this.playOffset = this.pauseTime
      console.log(`[WebAudioPlayer] playStartTime: ${this.playStartTime}, playOffset: ${this.playOffset}`)

      // Iniciar
      console.log('[WebAudioPlayer] ▶️ Llamando a source.start()...')
      try {
        this.currentSource.start(this.playStartTime, this.playOffset)
        console.log('[WebAudioPlayer] ✅ source.start() ejecutado correctamente')
      } catch (startError) {
        console.error('[WebAudioPlayer] ❌ Error en source.start():', startError)
        throw startError
      }
      
      this.isPlaying = true

      // Evento de finalización — protegido contra disparos falsos post-suspensión iOS
      this.currentSource.onended = () => {
        if (this.suppressOnEnded) {
          console.log('[WebAudioPlayer] ⚡ onended suprimido (suspensión iOS detectada)')
          return
        }
        this.isPlaying = false
        this.callbacks.onEnded?.()
      }

      console.log('[WebAudioPlayer] 🔄 Iniciando time updates...')
      this.startTimeUpdates()
      console.log('[WebAudioPlayer] ✅ Reproducción iniciada correctamente')

    } catch (error) {
      console.error('[WebAudioPlayer] Error reproduciendo canción:', error)
      this.callbacks.onError?.(error instanceof Error ? error : new Error(String(error)))
      throw error
    }
  }

  // ===========================================================================
  // 🖥️ MODO MEDIA ELEMENT (Para Electron - evita decodeAudioData)
  // ===========================================================================
  
  private async playWithMediaElement(song: Song, streamUrl: string, keepPosition = false): Promise<void> {
    console.log('[WebAudioPlayer] 🖥️ Usando modo MediaElement para Electron')
    
    // Detener reproducción anterior
    this.stopMediaElement()
    this.stop()
    
    // Si el MediaElement existe pero tuvo un error, recrearlo
    if (this.mediaElement && this.mediaElement.error) {
      console.warn('[WebAudioPlayer] ⚠️ MediaElement en estado de error, recreando...')
      // Desconectar y limpiar
      if (this.mediaElementSource) {
        try {
          this.mediaElementSource.disconnect()
        } catch (e) { /* ignorar */ }
      }
      if (this.mediaElementGain) {
        try {
          this.mediaElementGain.disconnect()
        } catch (e) { /* ignorar */ }
      }
      this.mediaElement.pause()
      this.mediaElement.src = ''
      this.mediaElement = null
      this.mediaElementSource = null
      this.mediaElementGain = null
    }
    
    // Crear elemento de audio HTML con su propio GainNode
    if (!this.mediaElement) {
      console.log('[WebAudioPlayer] 🎵 Creando nuevo elemento <audio>...')
      this.mediaElement = new Audio()
      // En Electron, crossOrigin puede causar problemas - solo usar en web
      if (!this.isElectron) {
        this.mediaElement.crossOrigin = 'anonymous'
      }
      
      // Conectar al AudioContext con cadena: Source → Lowpass → Gain → Master
      console.log('[WebAudioPlayer] 🔊 Conectando MediaElement al AudioContext con filtros...')
      this.mediaElementSource = this.audioContext!.createMediaElementSource(this.mediaElement)
      
      // Crear filtro lowpass (para outro/salida)
      this.mediaElementLowpass = this.audioContext!.createBiquadFilter()
      this.mediaElementLowpass.type = 'lowpass'
      this.mediaElementLowpass.frequency.value = 20000 // Sin filtro inicialmente (deja pasar todo)
      this.mediaElementLowpass.Q.value = 0.7 // Resonancia suave
      
      // Crear GainNode
      this.mediaElementGain = this.audioContext!.createGain()
      this.mediaElementGain.gain.value = 1.0
      
      // Conectar cadena: Source → Lowpass → Gain → Master
      this.mediaElementSource.connect(this.mediaElementLowpass)
      this.mediaElementLowpass.connect(this.mediaElementGain)
      this.mediaElementGain.connect(this.gainNode!)
      
      console.log('[WebAudioPlayer] ✅ MediaElement conectado: Source → Lowpass → Gain → Master')
    }
    
    // Guardar la duración de la canción como fallback (viene del servidor)
    const songDuration = song.duration || 0
    
    // Configurar callbacks del elemento
    this.mediaElement.onloadedmetadata = () => {
      const mediaDuration = this.mediaElement!.duration
      console.log(`[WebAudioPlayer] 📊 Metadata cargada - Duración raw: ${mediaDuration}`)
      
      // Usar duración del MediaElement solo si es válida, sino usar la de la canción
      if (isFinite(mediaDuration) && mediaDuration > 0) {
        this.duration = mediaDuration
        console.log(`[WebAudioPlayer] 📊 Usando duración del MediaElement: ${this.duration.toFixed(2)}s`)
      } else if (songDuration > 0) {
        this.duration = songDuration
        console.log(`[WebAudioPlayer] 📊 Usando duración de la canción (fallback): ${this.duration.toFixed(2)}s`)
      }
      
      this.callbacks.onLoadedMetadata?.(this.duration)
    }
    
    this.mediaElement.oncanplay = () => {
      console.log('[WebAudioPlayer] ✅ Audio listo para reproducir')
      this.callbacks.onCanPlay?.()
    }
    
    this.mediaElement.ondurationchange = () => {
      // Algunos streams actualizan la duración después de cargar
      const newDuration = this.mediaElement!.duration
      if (isFinite(newDuration) && newDuration > 0 && newDuration !== this.duration) {
        console.log(`[WebAudioPlayer] 📊 Duración actualizada: ${newDuration.toFixed(2)}s`)
        this.duration = newDuration
      }
    }
    
    this.mediaElement.onended = () => {
      console.log('[WebAudioPlayer] 🏁 Reproducción terminada')
      this.isPlaying = false
      this.callbacks.onEnded?.()
    }
    
    this.mediaElement.onerror = () => {
      // Pequeño delay para dar tiempo a que mediaElement.error se establezca
      setTimeout(() => {
        const error = this.mediaElement?.error
        let errorMessage = 'Error cargando audio'
        
        if (error) {
          switch (error.code) {
            case error.MEDIA_ERR_ABORTED:
              errorMessage = 'Carga de audio abortada por el usuario'
              break
            case error.MEDIA_ERR_NETWORK:
              errorMessage = 'Error de red al cargar el audio'
              break
            case error.MEDIA_ERR_DECODE:
              errorMessage = 'Error decodificando el audio'
              break
            case error.MEDIA_ERR_SRC_NOT_SUPPORTED:
              errorMessage = 'Formato de audio no soportado o URL inválida'
              break
            default:
              errorMessage = `Error desconocido (código: ${error.code})`
          }
          console.error('[WebAudioPlayer] ❌ Error en MediaElement:', errorMessage, error)
          if (error.message) {
            console.error('[WebAudioPlayer] Mensaje del error:', error.message)
          }
        } else {
          // Si aún no hay error, es probablemente un error transitorio
          console.warn('[WebAudioPlayer] ⚠️ Error transitorio en MediaElement (sin código de error)')
          console.warn('[WebAudioPlayer] Esto puede ocurrir al cambiar de canción rápidamente')
          // No notificar error si es transitorio
          return
        }
        
        console.error('[WebAudioPlayer] URL que falló:', this.mediaElement?.src)
        this.callbacks.onError?.(new Error(errorMessage))
      }, 10)
    }
    
    // Usar la duración de la canción inicialmente (antes de que el metadata cargue)
    if (songDuration > 0) {
      this.duration = songDuration
      console.log(`[WebAudioPlayer] 📊 Duración inicial de la canción: ${this.duration.toFixed(2)}s`)
    }
    
    // ── Serve from IndexedDB cache when available (instant + works offline) ────
    let effectiveStreamUrl = streamUrl
    if (audioCacheService.isAvailable()) {
      const cached = await audioCacheService.getBuffer(song.id)
      if (cached) {
        const blob = new Blob([cached], { type: 'audio/mpeg' })
        if (this.currentBlobUrl) URL.revokeObjectURL(this.currentBlobUrl)
        this.currentBlobUrl = URL.createObjectURL(blob)
        effectiveStreamUrl = this.currentBlobUrl
      } else {
        // Playing from network — cache once the song finishes
        this.scheduleMediaElementCache(song, streamUrl)
      }
    }

    this.mediaElement.src = effectiveStreamUrl
    this.mediaElement.volume = 1 // El volumen se controla via gainNode
    
    if (!keepPosition) {
      this.pauseTime = 0
    }
    
    this.currentSong = song
    
    // Aplicar ReplayGain para el nuevo source
    this.updateGain()
    
    // Esperar a que el audio esté listo para reproducir
    console.log('[WebAudioPlayer] ⏳ Esperando a que el audio esté listo...')
    console.log('[WebAudioPlayer] ReadyState actual:', this.mediaElement.readyState)
    
    if (this.mediaElement.readyState < 2) { // Menos de HAVE_CURRENT_DATA
      await new Promise<void>((resolve, reject) => {
        const timeout = setTimeout(() => {
          reject(new Error('Timeout esperando a que el audio esté listo'))
        }, 15000) // 15 segundos de timeout
        
        const onCanPlay = () => {
          clearTimeout(timeout)
          this.mediaElement?.removeEventListener('canplay', onCanPlay)
          console.log('[WebAudioPlayer] ✅ Audio listo para reproducir (canplay event)')
          resolve()
        }
        
        this.mediaElement?.addEventListener('canplay', onCanPlay)
        
    if (this.mediaElement && this.mediaElement.readyState >= 2) {
          clearTimeout(timeout)
          this.mediaElement.removeEventListener('canplay', onCanPlay)
          resolve()
        }
      })
    }
    
    // 🔥 FIX: Posición inicial (después de que el audio esté listo para recibir comandos)
    if (this.mediaElement && keepPosition && this.pauseTime > 0) {
      console.log(`[WebAudioPlayer] ⏱️ Restaurando posición en MediaElement: ${this.pauseTime.toFixed(1)}s`)
      this.mediaElement.currentTime = this.pauseTime
    }
    
    // Iniciar reproducción
    console.log('[WebAudioPlayer] ▶️ Iniciando reproducción...')
    try {
      await this.mediaElement.play()
      this.isPlaying = true
      console.log('[WebAudioPlayer] ✅ Reproducción iniciada correctamente (modo MediaElement)')
      
      // Iniciar actualizaciones de tiempo
      this.startMediaElementTimeUpdates()
    } catch (playError) {
      console.error('[WebAudioPlayer] ❌ Error al iniciar reproducción:', playError)
      throw playError
    }
  }
  
  private stopMediaElement(): void {
    if (this.crossfadeInterval) {
      clearInterval(this.crossfadeInterval)
      this.crossfadeInterval = null
    }

    if (this.mediaElement) {
      this.mediaElement.pause()
      this.mediaElement.currentTime = 0
    }
    
    if (this.nextMediaElement) {
      this.nextMediaElement.pause()
      this.nextMediaElement.currentTime = 0
      this.nextMediaElement.src = ''
    }

    this.stopMediaElementTimeUpdates()
    this.isCrossfading = false
  }
  
  private mediaElementTimeUpdateInterval: NodeJS.Timeout | null = null
  
  private startMediaElementTimeUpdates(): void {
    this.stopMediaElementTimeUpdates()
    this.mediaElementTimeUpdateInterval = setInterval(() => {
      if (this.isBackgrounded) return // Ignorar callbacks acumulados de iOS
      if (this.mediaElement && this.isPlaying) {
        const currentTime = this.mediaElement.currentTime
        const mediaDuration = this.mediaElement.duration

        // Usar duración válida: preferir la del MediaElement si es finita, sino usar this.duration
        const duration = (isFinite(mediaDuration) && mediaDuration > 0)
          ? mediaDuration
          : this.duration

        // Solo llamar callback si tenemos valores válidos
        if (isFinite(currentTime) && isFinite(duration) && duration > 0) {
          this.callbacks.onTimeUpdate?.(currentTime, duration)
        }
      }
    }, 100)
  }
  
  private stopMediaElementTimeUpdates(): void {
    if (this.mediaElementTimeUpdateInterval) {
      clearInterval(this.mediaElementTimeUpdateInterval)
      this.mediaElementTimeUpdateInterval = null
    }
  }

  pause(): void {
    // HTML fallback mode
    if (this.isHtmlFallbackActive && this.htmlFallback) {
      if (!this.isPlaying) return
      this.pauseTime = this.htmlFallback.currentTime
      this.htmlFallback.pause()
      this.isPlaying = false
      this._stopHtmlFallbackTimeUpdates()
      // Cancelar background fetch/decode
      this.htmlFallbackAbortController?.abort()
      this.htmlFallbackAbortController = null
      return
    }

    // Modo MediaElement
    if (this.useMediaElementMode && this.mediaElement) {
      if (!this.isPlaying) return
      console.log('[WebAudioPlayer] Pausando reproducción (MediaElement) - tiempo actual:', this.mediaElement.currentTime)
      this.pauseTime = this.mediaElement.currentTime
      this.mediaElement.pause()
      this.isPlaying = false
      // NO pausar keepalive aquí — debe seguir activo para que iOS mantenga
      // el WKWebView vivo y los remote commands del lock screen funcionen.
      this.stopMediaElementTimeUpdates()
      console.log('[WebAudioPlayer] Pausa completada - tiempo guardado:', this.pauseTime)
      return
    }
    
    // Modo Buffer tradicional
    if (!this.isPlaying || !this.currentSource) return

    console.log('[WebAudioPlayer] Pausando reproducción - tiempo actual:', this.getCurrentTime())

    this.currentSource.onended = null
    this.pauseTime = this.getCurrentTime()
    this.currentSource.stop()
    this.currentSource = null
    this.isPlaying = false
    // NO pausar keepalive aquí — debe seguir activo para que iOS mantenga
    // el WKWebView vivo y los remote commands del lock screen funcionen.

    console.log('[WebAudioPlayer] Pausa completada - tiempo guardado:', this.pauseTime)
    this.stopTimeUpdates()
  }

  async resume(): Promise<void> {
    // HTML fallback mode
    if (this.isHtmlFallbackActive && this.htmlFallback) {
      if (this.isPlaying) return
      this._startKeepAlive() // Asegurar keepalive activo al reanudar
      await this.ensureAudioContextReady()
      await this.htmlFallback.play()
      this.isPlaying = true
      this._startHtmlFallbackTimeUpdates()
      return
    }

    // Modo MediaElement
    if (this.useMediaElementMode && this.mediaElement) {
      if (this.isPlaying) return
      console.log('[WebAudioPlayer] Reanudando reproducción (MediaElement) desde tiempo:', this.pauseTime)
      this._startKeepAlive() // Asegurar keepalive activo al reanudar
      await this.ensureAudioContextReady()
      try {
        await this.mediaElement.play()
        this.isPlaying = true
        this.startMediaElementTimeUpdates()
        console.log('[WebAudioPlayer] Reanudación completada (MediaElement)')
      } catch (error) {
        console.error('[WebAudioPlayer] Error al reanudar (MediaElement):', error)
      }
      return
    }
    
    // Modo Buffer tradicional
    if (this.isPlaying || !this.currentBuffer || !this.currentSong) return

    console.log('[WebAudioPlayer] Reanudando reproducción desde tiempo:', this.pauseTime)

    // 🔑 iOS: arrancar keepalive antes del await (gesto de usuario todavía activo)
    this._startKeepAlive()

    // 🔧 ELECTRON FIX: Asegurar que AudioContext está activo antes de reanudar
    await this.ensureAudioContextReady()

    this.currentSource = this.audioContext!.createBufferSource()
    this.currentSource.buffer = this.currentBuffer
    this.currentSource.connect(this.gainNode!)

    this.playStartTime = this.audioContext!.currentTime
    this.playOffset = this.pauseTime

    this.currentSource.start(this.playStartTime, this.playOffset)
    this.isPlaying = true

    this.currentSource.onended = () => {
      if (this.suppressOnEnded) {
        console.log('[WebAudioPlayer] ⚡ onended suprimido en resume (suspensión iOS)')
        return
      }
      this.isPlaying = false
      this.callbacks.onEnded?.()
    }

    console.log('[WebAudioPlayer] Reanudación iniciada')
    this.startTimeUpdates()
  }

  seek(time: number): void {
    // Protección contra valores inválidos
    if (!isFinite(time) || isNaN(time) || time < 0) {
      console.warn(`[WebAudioPlayer] Seek ignorado - tiempo inválido: ${time}`)
      return
    }
    
    console.log(`[WebAudioPlayer] Seek a ${time.toFixed(2)}s`)
    
    // HTML fallback mode
    if (this.isHtmlFallbackActive && this.htmlFallback) {
      const targetTime = Math.max(0, Math.min(time, this.duration))
      this.htmlFallback.currentTime = targetTime
      this.pauseTime = targetTime
      this.callbacks.onTimeUpdate?.(targetTime, this.duration)
      return
    }

    // Modo MediaElement
    if (this.useMediaElementMode && this.mediaElement) {
      try {
        const mediaDuration = this.mediaElement.duration
        const safeDuration = isFinite(mediaDuration) ? mediaDuration : this.duration
        const targetTime = Math.max(0, Math.min(time, safeDuration || 0))
        
        if (targetTime === 0 && safeDuration === 0) {
          console.warn('[WebAudioPlayer] Seek ignorado - duración no disponible aún')
          return
        }
        
        this.mediaElement.currentTime = targetTime
        this.pauseTime = targetTime
        this.callbacks.onTimeUpdate?.(targetTime, this.duration)
      } catch (error) {
        console.error('[WebAudioPlayer] Error en seek (MediaElement):', error)
      }
      return
    }
    
    // Modo Buffer tradicional
    if (!this.currentBuffer) {
      console.warn('[WebAudioPlayer] Seek ignorado - no hay buffer cargado')
      return
    }

    const wasPlaying = this.isPlaying

    try {
      if (wasPlaying) {
        this.pause()
      }

      this.pauseTime = Math.max(0, Math.min(time, this.duration))

      if (wasPlaying) {
        this.resume()
        setTimeout(() => {
          if (this.isPlaying) {
            const currentTime = this.getCurrentTime()
            this.callbacks.onTimeUpdate?.(currentTime, this.duration)
          }
        }, 10)
      } else {
        this.callbacks.onTimeUpdate?.(this.pauseTime, this.duration)
      }
    } catch (error) {
      console.error('[WebAudioPlayer] Error en seek (Buffer):', error)
    }
  }

  setVolume(volume: number): void {
    const newVolume = Math.max(0, Math.min(1, volume / 100))
    if (Math.abs(this.volume - newVolume) > 0.01) {
      this.volume = newVolume
      this.updateGain()
      console.log(`[WebAudioPlayer] Volumen base establecido a ${this.volume.toFixed(2)}`)
    } else {
      this.volume = newVolume
      this.updateGain()
    }
  }

  stop(): void {
    console.log('[WebAudioPlayer] Deteniendo reproducción completamente')

    // Limpiar HTML fallback si está activo
    if (this.isHtmlFallbackActive) {
      this._cleanupHtmlFallback()
    }

    if (this.crossfadeInterval) {
      clearInterval(this.crossfadeInterval)
      this.crossfadeInterval = null
    }

    if (this.currentSource) {
      try {
        this.currentSource.onended = null
        this.currentSource.stop()
      } catch (e) {
        // Puede fallar si ya terminó
      }
      this.currentSource = null
    }

    if (this.nextSource) {
      try {
        this.nextSource.stop()
      } catch (e) {
        // Puede fallar si ya terminó
      }
      this.nextSource = null
    }

    if (this.useMediaElementMode) {
      if (this.mediaElement) {
        this.mediaElement.pause()
        this.mediaElement.currentTime = 0
      }
      if (this.nextMediaElement) {
        this.nextMediaElement.pause()
        this.nextMediaElement.currentTime = 0
        this.nextMediaElement.src = ''
      }
      this.stopMediaElementTimeUpdates()
    }

    this.currentBuffer = null
    this.nextBuffer = null
    this.isPlaying = false
    this.isCrossfading = false
    this.pauseTime = 0
    this.playStartTime = 0
    this.playOffset = 0

    this.stopTimeUpdates()
  }

  // ===========================================================================
  // CROSSFADE
  // ===========================================================================

  async prepareNextSong(song: Song, streamUrl: string, analysis?: AudioAnalysisResult): Promise<void> {
    console.log('[WebAudioPlayer] 📋 prepareNextSong llamado para:', song.title)
    console.log('[WebAudioPlayer] Modo:', this.useMediaElementMode ? 'MediaElement' : 'Buffer')
    console.log('[WebAudioPlayer] Tiene análisis:', !!analysis)
    
    if (this.isPreparingNext) {
      console.warn('[WebAudioPlayer] ⚠️ Ya hay una preparación en curso')
      return
    }

    try {
      this.isPreparingNext = true
      console.log('[WebAudioPlayer] Preparando siguiente canción:', song.title)

      // === MODO MEDIAELEMENT (Electron) ===
      if (this.useMediaElementMode) {
        console.log('[WebAudioPlayer] 🖥️ Preparando siguiente canción en modo MediaElement')
        
        // Limpiar nextMediaElement anterior si existe
        if (this.nextMediaElement) {
          this.nextMediaElement.pause()
          this.nextMediaElement.src = ''
        }
        
        // Crear nuevo elemento de audio para la siguiente canción
        this.nextMediaElement = new Audio()
        // En Electron, crossOrigin puede causar problemas - solo usar en web
        if (!this.isElectron) {
          this.nextMediaElement.crossOrigin = 'anonymous'
        }
        this.nextMediaElement.src = streamUrl
        this.nextMediaElement.volume = 1.0
        
        // Crear cadena de audio para siguiente canción: Source → Highpass → Gain → Master
        if (this.nextMediaElementSource) {
          this.nextMediaElementSource.disconnect()
        }
        if (this.nextMediaElementHighpass) {
          this.nextMediaElementHighpass.disconnect()
        }
        if (this.nextMediaElementGain) {
          this.nextMediaElementGain.disconnect()
        }
        
        this.nextMediaElementSource = this.audioContext!.createMediaElementSource(this.nextMediaElement)
        
        // Crear filtro highpass (para intro/entrada)
        this.nextMediaElementHighpass = this.audioContext!.createBiquadFilter()
        this.nextMediaElementHighpass.type = 'highpass'
        this.nextMediaElementHighpass.frequency.value = 5000 // Filtrado inicial (solo agudos)
        this.nextMediaElementHighpass.Q.value = 0.7 // Resonancia suave
        
        // Crear GainNode
        this.nextMediaElementGain = this.audioContext!.createGain()
        this.nextMediaElementGain.gain.value = 0 // Empezar en silencio
        
        // Conectar cadena: Source → Highpass → Gain → Master
        this.nextMediaElementSource.connect(this.nextMediaElementHighpass)
        this.nextMediaElementHighpass.connect(this.nextMediaElementGain)
        this.nextMediaElementGain.connect(this.gainNode!)
        
        console.log('[WebAudioPlayer] ✅ Next MediaElement conectado: Source → Highpass → Gain → Master')
        
        this.nextSong = song
        this.nextAnalysis = analysis || null
        
        // Precargar el audio
        this.nextMediaElement.load()
        
        // Esperar a que esté listo para reproducir
        await new Promise<void>((resolve, reject) => {
          const timeout = setTimeout(() => {
            reject(new Error('Timeout cargando siguiente canción'))
          }, 10000)
          
          this.nextMediaElement!.oncanplaythrough = () => {
            clearTimeout(timeout)
            console.log('[WebAudioPlayer] ✅ Siguiente canción lista para crossfade (MediaElement)')
            resolve()
          }
          
          this.nextMediaElement!.onerror = () => {
            clearTimeout(timeout)
            reject(new Error('Error cargando siguiente canción'))
          }
        })
        
        console.log('[WebAudioPlayer] Siguiente canción preparada (MediaElement)')
        return
      }

      // === MODO BUFFER (Web tradicional) ===
      // Liberar buffer anterior si existe
      if (this.nextBuffer) {
        const oldNextBuffer = this.nextBuffer
        this.nextBuffer = null
        console.log(`[WebAudioPlayer] 💾 Liberando nextBuffer anterior (${(oldNextBuffer.duration * 44100 * 2 * 2 / 1024 / 1024).toFixed(1)}MB aprox)`)
      }

      this.nextBuffer = await this.loadAudio(streamUrl, undefined, song.id, {
        title: song.title,
        artist: WebAudioPlayer.songArtistString(song),
      })
      this.nextSong = song
      this.nextAnalysis = analysis || null

      console.log(`[WebAudioPlayer] Siguiente canción preparada (${(this.nextBuffer.duration * 44100 * 2 * 2 / 1024 / 1024).toFixed(1)}MB aprox)`)
    } catch (error) {
      console.error('[WebAudioPlayer] Error preparando siguiente canción:', error)
      this.callbacks.onError?.(error instanceof Error ? error : new Error(String(error)))
      throw error
    } finally {
      this.isPreparingNext = false
    }
  }

  startCrossfade(): void {
    console.log('[WebAudioPlayer] Iniciando crossfade:', this.currentSong?.title, '->', this.nextSong?.title)

    // Detección de crossfade estancado: si isCrossfading lleva más tiempo del
    // máximo esperado (fade + 20s de margen), probablemente el watchdog no llegó
    // a tiempo (iOS background). Forzamos reset para no bloquear la próxima transición.
    if (this.isCrossfading && this.crossfadeStartedAt > 0) {
      const elapsed = Date.now() - this.crossfadeStartedAt
      const maxExpected = 45_000 // 45s: máximo teórico (fade 15s + anticipación 10s + margen)
      if (elapsed > maxExpected) {
        console.warn(`[WebAudioPlayer] ⚠️ Crossfade estancado (${(elapsed / 1000).toFixed(1)}s), forzando reset`)
        this.isCrossfading = false
        this.crossfadeEngine.forceReset()
      }
    }

    // === MODO MEDIAELEMENT (Electron) ===
    if (this.useMediaElementMode) {
      if (!this.mediaElement || !this.nextMediaElement || !this.nextSong || this.isCrossfading) {
        console.warn('[WebAudioPlayer] ❌ No se puede iniciar crossfade (MediaElement) - elementos no listos')
        return
      }

      if (!this.mediaElementGain || !this.nextMediaElementGain) {
        console.warn('[WebAudioPlayer] ❌ No se puede iniciar crossfade (MediaElement) - gain nodes no listos')
        return
      }

      this.isCrossfading = true
      this.crossfadeStartedAt = Date.now()
      console.log('[WebAudioPlayer] 🖥️ Iniciando crossfade en modo MediaElement')

      // =======================================================================
      // USAR DJMixingAlgorithms (misma lógica que modo Buffer/Web)
      // =======================================================================
      
      const currentDuration = this.mediaElement?.duration || this.duration
      const nextDuration = this.nextMediaElement?.duration || this.nextSong.duration || 180
      const mode: MixMode = this.isDjMode ? 'dj' : 'normal'
      
      // Calcular configuración usando el mismo algoritmo que la web
      const config = calculateCrossfadeConfig({
        currentAnalysis: this.currentAnalysis,
        nextAnalysis: this.nextAnalysis,
        bufferADuration: currentDuration,
        bufferBDuration: nextDuration,
        mode,
        currentPlaybackTimeA: this.mediaElement?.currentTime ?? undefined,
      })

      console.log(`[CROSSFADE] ${this.isDjMode ? 'MODO DJ' : 'MODO NORMAL'}`)
      console.log(`[CROSSFADE] "${this.currentSong?.title}" → "${this.nextSong?.title}"`)
      console.log(`[CROSSFADE] Entry: ${config.entryPoint.toFixed(2)}s, Fade: ${config.fadeDuration.toFixed(2)}s`)
      console.log(`[CROSSFADE] Filtros: ${config.useFilters ? (config.useAggressiveFilters ? 'agresivos' : 'normales') : 'no'}`)
      if (config.beatSyncInfo) {
        console.log(`[CROSSFADE] ${config.beatSyncInfo}`)
      }

      // =======================================================================
      // EJECUTAR CROSSFADE
      // =======================================================================
      
      const fadeSteps = 100
      const stepDuration = (config.fadeDuration * 1000) / fadeSteps

      // Iniciar reproducción de la siguiente canción desde el punto correcto
      this.nextMediaElement.currentTime = config.entryPoint
      this.nextMediaElement.play().catch(error => {
        console.error('[WebAudioPlayer] Error iniciando siguiente canción:', error)
      })

      // Notificar que el crossfade comenzó
      this.callbacks.onCrossfadeStart?.()

      // Configuración de filtros (basada en config de DJMixingAlgorithms)
      const useFilters = config.useFilters
      
      // Frecuencias de corte
      const LOWPASS_START = 20000  // Hz (sin filtro)
      const LOWPASS_END = config.useAggressiveFilters ? 300 : 500
      const HIGHPASS_START = config.useAggressiveFilters ? 800 : 400
      const HIGHPASS_END = 60     // Hz (deja pasar todo)
      
      if (useFilters) {
        console.log(`[DJ-FILTERS] Lowpass ${LOWPASS_START}→${LOWPASS_END}Hz, Highpass ${HIGHPASS_START}→${HIGHPASS_END}Hz`)
      }

      // Hacer fade gradual entre las dos canciones CON FILTROS
      let step = 0
      if (this.crossfadeInterval) clearInterval(this.crossfadeInterval)
      
      this.crossfadeInterval = setInterval(() => {
        // Protección background: si la app estuvo suspendida, los steps acumulados
        // disparan todos de golpe. _handleReturnFromBackground() limpia esto.
        if (this.isBackgrounded) return

        step++
        const progress = step / fadeSteps

        // Multiplicadores ReplayGain
        const gainA = this.getReplayGainMultiplier(this.currentSong) * this.volume
        const gainB = this.getReplayGainMultiplier(this.nextSong) * this.volume

        // === CANCIÓN SALIENTE (A) ===
        if (this.mediaElementGain) {
          if (config.transitionType === 'BEAT_MATCH_BLEND') {
            // Mantiene 80%+ de volumen la mayor parte de la transición
            this.mediaElementGain.gain.value = gainA * (progress < 0.8 ? 1.0 - (progress * 0.25) : (1.0 - progress) * 4)
          } else if (config.transitionType === 'EQ_MIX') {
            // Curva cóncava suave
            this.mediaElementGain.gain.value = gainA * Math.pow(1 - progress, 2)
          } else if (config.transitionType === 'CUT' || config.transitionType === 'CUT_A_FADE_IN_B') {
            // Corte abrupto al final
            this.mediaElementGain.gain.value = gainA * (progress < 0.9 ? 1.0 : 0)
          } else {
            // Linear fade out
            this.mediaElementGain.gain.value = gainA * (1 - progress)
          }
        }
        if (useFilters && this.mediaElementLowpass) {
          const freq = LOWPASS_START - (LOWPASS_START - LOWPASS_END) * progress
          this.mediaElementLowpass.frequency.value = freq
        }

        // === CANCIÓN ENTRANTE (B) ===
        if (this.nextMediaElementGain) {
          this.nextMediaElementGain.gain.value = gainB * progress
        }
        if (useFilters && this.nextMediaElementHighpass) {
          const freq = HIGHPASS_START - (HIGHPASS_START - HIGHPASS_END) * progress
          this.nextMediaElementHighpass.frequency.value = freq
        }

        // Cuando termina el fade
        if (step >= fadeSteps) {
          if (this.crossfadeInterval) {
            clearInterval(this.crossfadeInterval)
            this.crossfadeInterval = null
          }
          if (useFilters) {
            console.log(`[DJ-FILTERS] Completado`)
          }
          this.finalizeCrossfadeMediaElement(config.entryPoint)
        }
      }, stepDuration)

      return
    }

    // === MODO BUFFER (Web tradicional) ===
    if (!this.currentBuffer || !this.nextBuffer || !this.nextSong || this.isCrossfading) {
      console.warn('[WebAudioPlayer] ❌ No se puede iniciar crossfade - buffers no listos')
      return
    }

    if (!this.currentSource || !this.audioContext || !this.gainNode) {
      console.warn('[WebAudioPlayer] ❌ No se puede iniciar crossfade - contexto no listo')
      return
    }

    this.isCrossfading = true
    this.crossfadeStartedAt = Date.now()

    // Crear nextSource
    this.nextSource = this.audioContext.createBufferSource()
    this.nextSource.buffer = this.nextBuffer

    // Guardar duración del buffer A antes de liberarlo
    const bufferADuration = this.currentBuffer.duration

    // Preparar recursos para el engine
    const resources: CrossfadeResources = {
      currentSource: this.currentSource,
      nextSource: this.nextSource,
      currentBuffer: this.currentBuffer,
      nextBuffer: this.nextBuffer,
      currentSong: this.currentSong!,
      nextSong: this.nextSong,
      currentAnalysis: this.currentAnalysis,
      nextAnalysis: this.nextAnalysis,
      audioContext: this.audioContext,
      masterGain: this.gainNode,
      volume: this.volume,
      trackGainA: this.getReplayGainMultiplier(this.currentSong),
      trackGainB: this.getReplayGainMultiplier(this.nextSong),
      currentPlaybackTimeA: this.getCurrentTime(),
    }

    // Liberar buffer A anticipadamente para ahorrar memoria
    console.log(`[WebAudioPlayer] 💾 Liberando buffer A (${(bufferADuration * 44100 * 2 * 2 / 1024 / 1024).toFixed(1)}MB aprox)`)
    this.currentBuffer = null

    // Determinar modo
    const mode: MixMode = this.isDjMode ? 'dj' : 'normal'

    // Ejecutar crossfade
    this.crossfadeEngine.executeCrossfade(resources, mode)
      .then((result) => {
        // Promocionar B a actual
        this.currentSource = result.newCurrentSource
        this.currentBuffer = result.newCurrentBuffer
        this.currentSong = result.newCurrentSong
        this.currentAnalysis = result.newCurrentAnalysis
        this.duration = result.duration

        // Configurar evento de finalización — protegido contra suspensión iOS
        if (this.currentSource) {
          this.currentSource.onended = () => {
            if (this.suppressOnEnded) {
              console.log('[WebAudioPlayer] ⚡ onended suprimido en crossfade (suspensión iOS)')
              return
            }
            this.isPlaying = false
            this.callbacks.onEnded?.()
          }
        }

        // Resetear tiempos
        this.playStartTime = this.audioContext!.currentTime
        this.playOffset = result.startOffset
        this.isPlaying = true

        // Actualizar tiempo
        this.startTimeUpdates()
        const initialTime = this.getCurrentTime()
        this.callbacks.onTimeUpdate?.(initialTime, this.duration)

        this.isCrossfading = false

        // Limpiar referencias de next
        this.nextSource = null
        this.nextBuffer = null
        this.nextSong = null
        this.nextAnalysis = null

        console.log('[WebAudioPlayer] Crossfade completado')

        // Sugerir GC
        if (typeof window !== 'undefined' && 'gc' in window) {
          // @ts-expect-error - solo en modo debug de Chrome
          window.gc()
        }
      })
      .catch((error) => {
        console.error('[WebAudioPlayer] Error en crossfade:', error)
        this.isCrossfading = false
        this.callbacks.onError?.(error instanceof Error ? error : new Error(String(error)))
      })
  }

  // ===========================================================================
  // FINALIZACIÓN DE CROSSFADE (MediaElement)
  // ===========================================================================

  private finalizeCrossfadeMediaElement(startOffset: number): void {
    console.log('[WebAudioPlayer] 🎯 Finalizando crossfade (MediaElement)')

    if (!this.nextMediaElement || !this.nextSong) {
      console.error('[WebAudioPlayer] Error: no hay siguiente canción para finalizar crossfade')
      this.isCrossfading = false
      return
    }

    // Detener el MediaElement actual
    if (this.mediaElement) {
      this.mediaElement.pause()
      this.mediaElement.currentTime = 0
    }

    // Intercambiar elementos: next se convierte en current
    const oldMediaElement = this.mediaElement
    const oldSource = this.mediaElementSource
    const oldGain = this.mediaElementGain
    const oldLowpass = this.mediaElementLowpass

    this.mediaElement = this.nextMediaElement
    this.mediaElementSource = this.nextMediaElementSource
    this.mediaElementGain = this.nextMediaElementGain
    this.mediaElementLowpass = this.nextMediaElementHighpass // El highpass de entrada se convierte en el lowpass de salida
    this.currentSong = this.nextSong
    this.currentAnalysis = this.nextAnalysis

    // Actualizar ganancia normal (por el ReplayGain que ya está fijo al 100% * config local)
    this.updateGain()

    this.nextMediaElement = oldMediaElement
    this.nextMediaElementSource = oldSource
    this.nextMediaElementGain = oldGain
    this.nextMediaElementHighpass = oldLowpass

    // Resetear el nuevo filtro (que era highpass, ahora es lowpass) a sin filtro
    if (this.mediaElementLowpass) {
      this.mediaElementLowpass.type = 'lowpass'
      this.mediaElementLowpass.frequency.value = 20000 // Sin filtro (deja pasar todo)
      this.mediaElementLowpass.Q.value = 0.7
      console.log('[DJ-FILTERS] 🔄 Filtro reseteado para siguiente uso (lowpass @ 20kHz)')
    }

    // Asegurar que el nuevo current esté a volumen completo
    if (this.mediaElementGain) {
      this.mediaElementGain.gain.value = 1.0 * this.getReplayGainMultiplier(this.currentSong) * this.volume
    }

    // Reutilizar el antiguo MediaElement para futuros crossfades
    if (this.nextMediaElement) { // Now `this.nextMediaElement` is `oldMediaElement`
      this.nextMediaElement.pause()
      this.nextMediaElement.src = ''
      // No need to reassign, it's already done above
      
      // Resetear el filtro reutilizado como highpass
      if (this.nextMediaElementHighpass) {
        this.nextMediaElementHighpass.type = 'highpass'
        this.nextMediaElementHighpass.frequency.value = 5000 // Filtrado inicial para próximo uso
        this.nextMediaElementHighpass.Q.value = 0.7
      }
    } else {
      this.nextMediaElement = null
      this.nextMediaElementSource = null
      this.nextMediaElementGain = null
      this.nextMediaElementHighpass = null
    }

    // Actualizar duración
    const mediaDuration = this.mediaElement.duration
    this.duration = (isFinite(mediaDuration) && mediaDuration > 0) 
      ? mediaDuration 
      : this.currentSong.duration || 0

    // Resetear estado
    this.nextSong = null
    this.nextAnalysis = null
    this.isCrossfading = false
    this.isPlaying = true

    // Configurar evento de finalización
    this.mediaElement.onended = () => {
      console.log('[WebAudioPlayer] 🏁 Reproducción terminada')
      this.isPlaying = false
      this.callbacks.onEnded?.()
    }

    // Reiniciar time updates
    this.startMediaElementTimeUpdates()

    // Notificar completado
    this.callbacks.onCrossfadeComplete?.(this.currentSong, startOffset)

    console.log('[WebAudioPlayer] ✅ Crossfade completado (MediaElement):', this.currentSong.title)
  }

  // ===========================================================================
  // UTILIDADES DE TIEMPO
  // ===========================================================================

  private lastTimeUpdateTimestamp = 0

  private startTimeUpdates(): void {
    this.stopTimeUpdates()

    this.timeUpdateInterval = setInterval(() => {
      // En background (pantalla bloqueada), los time updates DEBEN seguir activos
      // para que AutoMix pueda disparar el crossfade a tiempo. Si los bloqueamos,
      // la canción A llega al final sin fadeOut y B entra en seco.
      //
      // Protección contra timers acumulados: si WKWebView fue suspendido de verdad
      // (deep background), los setInterval se acumulan y disparan todos de golpe.
      // Filtramos por intervalo mínimo: si el último update fue hace <200ms, ignorar.
      const now = Date.now()
      if (now - this.lastTimeUpdateTimestamp < 200) return
      this.lastTimeUpdateTimestamp = now

      if (this.isPlaying) {
        const currentTime = this.getCurrentTime()
        this.callbacks.onTimeUpdate?.(currentTime, this.duration)
      }
    }, 500)
  }

  private stopTimeUpdates(): void {
    if (this.timeUpdateInterval) {
      clearInterval(this.timeUpdateInterval)
      this.timeUpdateInterval = null
    }
  }

  getCurrentTime(): number {
    // HTML fallback mode
    if (this.isHtmlFallbackActive && this.htmlFallback) {
      return this.htmlFallback.currentTime
    }

    // Modo MediaElement
    if (this.useMediaElementMode && this.mediaElement) {
      return this.mediaElement.currentTime
    }
    
    // Modo Buffer tradicional
    if (!this.audioContext) {
      return 0
    }

    if (this.isPlaying) {
      return this.playOffset + (this.audioContext.currentTime - this.playStartTime)
    } else {
      return this.pauseTime
    }
  }

  // ===========================================================================
  // GETTERS DE ESTADO
  // ===========================================================================

  // Método para verificar si hay media activa (buffer o elemento)
  hasActiveMedia(): boolean {
    if (this.useMediaElementMode) {
      return !!this.mediaElement && !!this.mediaElement.src && this.mediaElement.readyState >= 1
    }
    return !!this.currentBuffer || this.isHtmlFallbackActive
  }

  getPlaybackState(): PlaybackState {
    return {
      currentSong: this.currentSong,
      isPlaying: this.isPlaying,
      currentTime: this.getCurrentTime(),
      duration: this.duration,
      volume: this.volume * 100,
      isCrossfading: this.isCrossfading,
    }
  }

  isCurrentlyPlaying(): boolean {
    return this.isPlaying
  }

  // ===========================================================================
  // GESTIÓN DE MEMORIA
  // ===========================================================================

  /**
   * Libera memoria de buffers no esenciales
   * Llamar periódicamente para evitar memory leaks
   */
  releaseNonEssentialMemory(): void {
    console.log('[WebAudioPlayer] 🧹 Liberando memoria no esencial...')
    
    // Liberar nextBuffer si existe y no estamos en crossfade
    if (!this.isCrossfading && this.nextBuffer) {
      const bufferSize = (this.nextBuffer.duration * this.nextBuffer.sampleRate * this.nextBuffer.numberOfChannels * 4 / 1024 / 1024).toFixed(1)
      console.log(`[WebAudioPlayer] 💾 Liberando nextBuffer: ~${bufferSize}MB`)
      this.nextBuffer = null
      this.nextSong = null
      this.nextAnalysis = null
    }
    
    // Limpiar next MediaElement si no está en uso
    if (!this.isCrossfading && this.nextMediaElement) {
      console.log('[WebAudioPlayer] 💾 Liberando nextMediaElement')
      this.nextMediaElement.pause()
      this.nextMediaElement.src = ''
      this.nextMediaElement.load() // Forzar liberación de recursos internos
    }
    
    // Sugerir GC
    this.suggestGarbageCollection()
  }

  /**
   * Obtiene estadísticas de uso de memoria del reproductor
   */
  getMemoryStats(): { currentBuffer: number; nextBuffer: number; total: number } {
    const calculateBufferSize = (buffer: AudioBuffer | null): number => {
      if (!buffer) return 0
      return buffer.duration * buffer.sampleRate * buffer.numberOfChannels * 4 / 1024 / 1024
    }

    const currentBufferMB = calculateBufferSize(this.currentBuffer)
    const nextBufferMB = calculateBufferSize(this.nextBuffer)

    return {
      currentBuffer: currentBufferMB,
      nextBuffer: nextBufferMB,
      total: currentBufferMB + nextBufferMB,
    }
  }

  /**
   * Sugiere al navegador que ejecute el garbage collector
   */
  private suggestGarbageCollection(): void {
    if (typeof window !== 'undefined' && 'gc' in window) {
      try {
        (window as Window & { gc?: () => void }).gc?.()
        console.log('[WebAudioPlayer] 🗑️ GC sugerido')
      } catch {
        // Ignorar si no está disponible
      }
    }
  }

  /**
   * Limpieza agresiva de memoria - usar con cuidado
   * Puede interrumpir la reproducción si se usa incorrectamente
   */
  aggressiveMemoryCleanup(): void {
    console.log('[WebAudioPlayer] ⚠️ Limpieza agresiva de memoria')
    
    // Liberar memoria no esencial
    this.releaseNonEssentialMemory()
    
    // Cancelar y limpiar pre-decode cache (libera buffers y aborta fetches en vuelo)
    this.clearPreDecodeCache()
    
    // Cancelar cualquier carga en progreso
    if (this.currentLoadAbortController) {
      this.currentLoadAbortController.abort()
      this.currentLoadAbortController = null
    }
    
    // Limpiar análisis almacenados
    this.currentAnalysis = null
    this.nextAnalysis = null
    
    // Forzar GC múltiples veces (a veces ayuda)
    for (let i = 0; i < 3; i++) {
      setTimeout(() => this.suggestGarbageCollection(), i * 100)
    }
  }

  // ===========================================================================
  // ⚡ HTML FALLBACK — reproducción instantánea + switch silencioso a WebAudio
  // ===========================================================================

  /**
   * Arranca reproducción inmediata via HTMLAudioElement y lanza decode en background.
   * Cadena de audio: htmlFallback → htmlFallbackSource → htmlFallbackGain(1.0) → gainNode(vol*RG)
   * gainNode ya tiene el valor correcto (volume*RG), no se toca.
   */
  private async _startHtmlFallback(song: Song, streamUrl: string, parentSignal: AbortSignal): Promise<void> {
    if (!this.audioContext || !this.gainNode) return

    this.htmlFallbackAbortController = new AbortController()

    this.htmlFallback = new Audio()
    this.htmlFallback.src = streamUrl
    this.htmlFallback.volume = 1

    // Conectar: htmlFallback → htmlFallbackSource → htmlFallbackGain(1.0) → gainNode(vol*RG)
    // gainNode ya está en volume*RG por updateGain(), htmlFallbackGain en 1.0 es passthrough
    this.htmlFallbackSource = this.audioContext.createMediaElementSource(this.htmlFallback)
    this.htmlFallbackGain = this.audioContext.createGain()
    this.htmlFallbackGain.gain.value = 1.0
    this.htmlFallbackSource.connect(this.htmlFallbackGain)
    this.htmlFallbackGain.connect(this.gainNode)
    this.isHtmlFallbackActive = true

    this.htmlFallback.onloadedmetadata = () => {
      const d = this.htmlFallback?.duration
      if (d && isFinite(d) && d > 0) {
        this.duration = d
      }
    }

    this.htmlFallback.onended = () => {
      if (!this.isSwitchingToWebAudio) {
        this.isPlaying = false
        this._cleanupHtmlFallback()
        this.callbacks.onEnded?.()
      }
    }

    await this.htmlFallback.play()
    this.isPlaying = true
    this._startHtmlFallbackTimeUpdates()

    // Background: fetch + decode + switch (fire and forget)
    this._fetchDecodeAndSwitch(song, streamUrl, parentSignal).catch(err => {
      if (!(err instanceof DOMException && err.name === 'AbortError')) {
        console.warn('[WebAudioPlayer] ⚠️ Background decode fallido, canción continúa en HTML audio:', err)
      }
    })
  }

  /**
   * Descarga y decodifica en background. Cuando termina, inicia el switch silencioso.
   */
  private async _fetchDecodeAndSwitch(song: Song, streamUrl: string, parentSignal: AbortSignal): Promise<void> {
    if (!this.htmlFallbackAbortController) return
    const { signal } = this.htmlFallbackAbortController

    console.log(`[WebAudioPlayer] 📥 Background fetch+decode para "${song.title}"...`)
    const response = await fetch(streamUrl, { signal } as RequestInit)
    if (!response.ok) throw new Error(`HTTP ${response.status}`)

    const arrayBuffer = await response.arrayBuffer()
    if (signal.aborted || parentSignal.aborted || !this.audioContext) return

    // Guardar en IndexedDB en background (sin bloquear)
    audioCacheService.put(song.id, arrayBuffer.slice(0), {
      title: song.title,
      artist: WebAudioPlayer.songArtistString(song),
    }).catch(() => {})

    const audioBuffer = await this.audioContext.decodeAudioData(arrayBuffer.slice(0))
    if (signal.aborted || parentSignal.aborted || !this.isHtmlFallbackActive) return

    console.log(`[WebAudioPlayer] ✅ Decode completado para "${song.title}", iniciando switch silencioso...`)
    await this._switchToBufferSource(audioBuffer, song)
  }

  /**
   * Crossfade de 80ms (inaudible) de HTMLAudioElement a AudioBufferSourceNode.
   * Durante el crossfade, ambas fuentes suenan solapadas en fase;
   * htmlFallbackGain va de 1→0 y switchGain va de 0→1, ambos sobre gainNode(vol*RG).
   */
  private async _switchToBufferSource(buffer: AudioBuffer, song: Song): Promise<void> {
    if (!this.htmlFallback || !this.htmlFallbackGain || !this.audioContext || !this.gainNode) return

    this.isSwitchingToWebAudio = true
    const position = this.htmlFallback.currentTime
    const now = this.audioContext.currentTime
    const SWITCH_DURATION = 0.08 // 80ms — inaudible

    // Crear buffer source y gain temporal para el switch (0 → 1.0)
    // La cadena: source → switchGain(0→1) → gainNode(vol*RG)
    // El total efectivo va de 0 a vol*RG en 80ms
    const source = this.audioContext.createBufferSource()
    source.buffer = buffer
    const switchGain = this.audioContext.createGain()
    switchGain.gain.setValueAtTime(0, now)
    switchGain.gain.linearRampToValueAtTime(1.0, now + SWITCH_DURATION)
    source.connect(switchGain)
    switchGain.connect(this.gainNode)

    // Fade out HTML audio: htmlFallbackGain 1.0 → 0 en 80ms
    this.htmlFallbackGain.gain.cancelScheduledValues(now)
    this.htmlFallbackGain.gain.setValueAtTime(1.0, now)
    this.htmlFallbackGain.gain.linearRampToValueAtTime(0, now + SWITCH_DURATION)

    // Arrancar buffer source en la misma posición que el HTML audio (sync intra-frame)
    source.start(now, position)

    // Esperar a que termine el crossfade
    await new Promise<void>(resolve => setTimeout(resolve, SWITCH_DURATION * 1000 + 20))

    // Limpiar HTML fallback
    if (this.htmlFallback) {
      this.htmlFallback.pause()
      this.htmlFallback.src = ''
      this.htmlFallback.onended = null
      this.htmlFallback.onloadedmetadata = null
    }
    try { this.htmlFallbackSource?.disconnect() } catch { /* ignorar */ }
    try { this.htmlFallbackGain?.disconnect() } catch { /* ignorar */ }
    this._stopHtmlFallbackTimeUpdates()
    this.htmlFallback = null
    this.htmlFallbackSource = null
    this.htmlFallbackGain = null
    this.htmlFallbackAbortController = null

    // Reconectar source directamente a gainNode (saltar switchGain)
    // Antes: source → switchGain(1.0) → gainNode(vol*RG) = vol*RG
    // Después: source → gainNode(vol*RG) = vol*RG — mismo valor, sin click
    try { source.disconnect(switchGain) } catch { /* ignorar */ }
    try { switchGain.disconnect() } catch { /* ignorar */ }
    source.connect(this.gainNode)

    // Actualizar estado para modo buffer normal
    this.currentSource = source
    this.currentBuffer = buffer
    this.currentSong = song
    this.duration = buffer.duration
    this.playStartTime = now     // cuando se llamó source.start
    this.playOffset = position   // posición en el buffer
    this.isHtmlFallbackActive = false
    this.isSwitchingToWebAudio = false

    source.onended = () => {
      if (this.suppressOnEnded) {
        console.log('[WebAudioPlayer] ⚡ onended suprimido en switch (suspensión iOS)')
        return
      }
      this.isPlaying = false
      this.callbacks.onEnded?.()
    }

    // Cambiar a time updates basados en AudioContext
    this.startTimeUpdates()
    console.log(`[WebAudioPlayer] ⚡ Switch completado: WebAudio activo desde ${position.toFixed(2)}s`)
  }

  /**
   * Limpia completamente el estado de HTML fallback.
   * Seguro de llamar en cualquier momento (stop, nueva canción, error).
   */
  private _cleanupHtmlFallback(): void {
    this.htmlFallbackAbortController?.abort()
    this.htmlFallbackAbortController = null

    if (this.htmlFallback) {
      this.htmlFallback.pause()
      this.htmlFallback.src = ''
      this.htmlFallback.onended = null
      this.htmlFallback.onloadedmetadata = null
    }
    try { this.htmlFallbackSource?.disconnect() } catch { /* ignorar */ }
    try { this.htmlFallbackGain?.disconnect() } catch { /* ignorar */ }

    this.htmlFallback = null
    this.htmlFallbackSource = null
    this.htmlFallbackGain = null
    this.isHtmlFallbackActive = false
    this.isSwitchingToWebAudio = false

    this._stopHtmlFallbackTimeUpdates()
  }

  private _startHtmlFallbackTimeUpdates(): void {
    this._stopHtmlFallbackTimeUpdates()
    this.htmlFallbackTimeInterval = setInterval(() => {
      // Misma protección que startTimeUpdates: permitir en background para AutoMix,
      // pero filtrar ráfagas acumuladas de deep suspension
      const now = Date.now()
      if (now - this.lastTimeUpdateTimestamp < 200) return
      this.lastTimeUpdateTimestamp = now

      if (this.htmlFallback && this.isPlaying) {
        const currentTime = this.htmlFallback.currentTime
        if (isFinite(currentTime) && this.duration > 0) {
          this.callbacks.onTimeUpdate?.(currentTime, this.duration)
        }
      }
    }, 100)
  }

  private _stopHtmlFallbackTimeUpdates(): void {
    if (this.htmlFallbackTimeInterval) {
      clearInterval(this.htmlFallbackTimeInterval)
      this.htmlFallbackTimeInterval = null
    }
  }

  // ===========================================================================
  // LIMPIEZA
  // ===========================================================================

  dispose(): void {
    console.log('[WebAudioPlayer] Liberando recursos')

    // Limpiar listener de visibilitychange
    if (this.visibilityHandler) {
      document.removeEventListener('visibilitychange', this.visibilityHandler)
      this.visibilityHandler = null
    }

    // Limpiar keepalive nativo
    this._stopKeepAlive()

    // Cancelar y limpiar pre-decode cache primero
    this.clearPreDecodeCache()

    // Cancelar carga en progreso
    if (this.currentLoadAbortController) {
      this.currentLoadAbortController.abort()
      this.currentLoadAbortController = null
    }

    this.stop()
    this.stopTimeUpdates()
    this.stopMediaElementTimeUpdates()
    
    // Limpiar MediaElements
    if (this.mediaElement) {
      this.mediaElement.pause()
      this.mediaElement.src = ''
      this.mediaElement.load() // Forzar liberación
      this.mediaElement = null
    }
    if (this.mediaElementSource) {
      try {
        this.mediaElementSource.disconnect()
      } catch { /* ignorar */ }
      this.mediaElementSource = null
    }
    if (this.mediaElementLowpass) {
      try {
        this.mediaElementLowpass.disconnect()
      } catch { /* ignorar */ }
      this.mediaElementLowpass = null
    }
    if (this.mediaElementGain) {
      try {
        this.mediaElementGain.disconnect()
      } catch { /* ignorar */ }
      this.mediaElementGain = null
    }
    
    // Limpiar next MediaElement
    if (this.nextMediaElement) {
      this.nextMediaElement.pause()
      this.nextMediaElement.src = ''
      this.nextMediaElement.load() // Forzar liberación
      this.nextMediaElement = null
    }
    if (this.nextMediaElementSource) {
      try {
        this.nextMediaElementSource.disconnect()
      } catch { /* ignorar */ }
      this.nextMediaElementSource = null
    }
    if (this.nextMediaElementHighpass) {
      try {
        this.nextMediaElementHighpass.disconnect()
      } catch { /* ignorar */ }
      this.nextMediaElementHighpass = null
    }
    if (this.nextMediaElementGain) {
      try {
        this.nextMediaElementGain.disconnect()
      } catch { /* ignorar */ }
      this.nextMediaElementGain = null
    }

    // Limpiar buffers
    this.currentBuffer = null
    this.nextBuffer = null
    this.currentAnalysis = null
    this.nextAnalysis = null

    if (this.audioContext) {
      try {
        this.audioContext.close()
      } catch { /* ignorar */ }
      this.audioContext = null
    }

    this.gainNode = null
    this.callbacks = {}

    // Sugerir GC final
    this.suggestGarbageCollection()
    
    console.log('[WebAudioPlayer] ✅ Todos los recursos liberados')
  }
}
