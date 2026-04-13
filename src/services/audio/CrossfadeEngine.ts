/**
 * 🎛️ Crossfade Engine - Motor de transiciones entre canciones
 * 
 * Este módulo orquesta el proceso completo de crossfade:
 * 1. Calcula configuración usando DJMixingAlgorithms
 * 2. Crea cadenas de efectos usando AudioEffectsChain
 * 3. Programa las automatizaciones de volumen y filtros
 * 4. Gestiona la limpieza de recursos
 * 
 * Soporta modo DJ (agresivo) y modo Normal (conservador).
 */

import { AudioAnalysisResult, CrossfadeConfig, CrossfadeTimings, MixMode, Song, EffectsChainA, EffectsChainB } from './types'
import { calculateCrossfadeConfig } from './DJMixingAlgorithms'
import {
  createEffectsChainA,
  createEffectsChainB,
  scheduleEffectsChainA,
  scheduleEffectsChainB,
  connectEffectsChainA,
  connectEffectsChainB,
  disconnectEffectsChainA,
  disconnectEffectsChainB,
  getEffectsSummary,
} from './AudioEffectsChain'

// =============================================================================
// TIPOS
// =============================================================================

export interface CrossfadeEngineCallbacks {
  onCrossfadeStart?: () => void
  onCrossfadeComplete?: (nextSong: Song, startOffset: number) => void
}

export interface CrossfadeResources {
  /** Source de la canción A (actual) */
  currentSource: AudioBufferSourceNode
  /** Source de la canción B (siguiente) */
  nextSource: AudioBufferSourceNode
  /** Buffer de A */
  currentBuffer: AudioBuffer
  /** Buffer de B */
  nextBuffer: AudioBuffer
  /** Canción A */
  currentSong: Song
  /** Canción B */
  nextSong: Song
  /** Análisis de A */
  currentAnalysis: AudioAnalysisResult | null
  /** Análisis de B */
  nextAnalysis: AudioAnalysisResult | null
  /** AudioContext */
  audioContext: AudioContext
  /** Gain node maestro */
  masterGain: GainNode
  /** Volumen actual del usuario (0-1) */
  volume: number
  /** Multiplicador ReplayGain para A (opcional) */
  trackGainA?: number
  /** Multiplicador ReplayGain para B (opcional) */
  trackGainB?: number
  /** Posición de reproducción actual de A (segundos) — para beat-sync de fase cruzada */
  currentPlaybackTimeA?: number
}

export interface CrossfadeResult {
  /** Nueva canción (B promocionada a actual) */
  newCurrentSong: Song
  /** Nuevo source (B promocionado a actual) */
  newCurrentSource: AudioBufferSourceNode
  /** Nuevo buffer (B promocionado a actual) */
  newCurrentBuffer: AudioBuffer
  /** Nuevo análisis */
  newCurrentAnalysis: AudioAnalysisResult | null
  /** Offset donde empieza la nueva canción */
  startOffset: number
  /** Duración del nuevo buffer */
  duration: number
}

// =============================================================================
// MOTOR DE CROSSFADE
// =============================================================================

/**
 * Motor de crossfade que gestiona las transiciones entre canciones.
 */
export class CrossfadeEngine {
  private callbacks: CrossfadeEngineCallbacks = {}
  private isCrossfading = false

  /**
   * Configura los callbacks del motor.
   */
  setCallbacks(callbacks: CrossfadeEngineCallbacks): void {
    this.callbacks = { ...this.callbacks, ...callbacks }
  }

  /**
   * Verifica si hay un crossfade en progreso.
   */
  isCrossfadeInProgress(): boolean {
    return this.isCrossfading
  }

  /**
   * Resetea el estado del motor. Usar solo tras reconstrucción de AudioContext
   * (suspensión profunda de iOS) donde los nodos del crossfade anterior ya no existen.
   */
  forceReset(): void {
    this.isCrossfading = false
  }

  /**
   * Ejecuta el crossfade completo.
   * 
   * @param resources Recursos necesarios para el crossfade
   * @param mode Modo de mezcla (DJ o Normal)
   * @returns Promise que se resuelve cuando el crossfade completa
   */
  async executeCrossfade(
    resources: CrossfadeResources,
    mode: MixMode
  ): Promise<CrossfadeResult> {
    if (this.isCrossfading) {
      throw new Error('Ya hay un crossfade en progreso')
    }

    this.isCrossfading = true
    this.callbacks.onCrossfadeStart?.()

    const {
      currentSource,
      nextSource,
      currentBuffer,
      nextBuffer,
      currentSong,
      nextSong,
      currentAnalysis,
      nextAnalysis,
      audioContext,
      masterGain,
      volume,
      trackGainA = 1.0,
      trackGainB = 1.0,
      currentPlaybackTimeA,
    } = resources

    console.log(`[CrossfadeEngine] 🎵 Iniciando: "${currentSong.title}" → "${nextSong.title}"`)

    // =======================================================================
    // 1. CALCULAR CONFIGURACIÓN
    // =======================================================================
    const config = calculateCrossfadeConfig({
      currentAnalysis,
      nextAnalysis,
      bufferADuration: currentBuffer.duration,
      bufferBDuration: nextBuffer.duration,
      mode,
      currentPlaybackTimeA,
    })

    console.log(`[CrossfadeEngine] Config: entrada=${config.entryPoint.toFixed(2)}s, fade=${config.fadeDuration.toFixed(2)}s`)

    // =======================================================================
    // 2. CALCULAR TIMINGS
    // =======================================================================
    const timings = this.calculateTimings(audioContext, config)

    // =======================================================================
    // 3. CREAR CADENAS DE EFECTOS
    // =======================================================================
    const chainA = createEffectsChainA({ audioContext, config, timings, maxVolume: trackGainA })
    const chainB = createEffectsChainB({ audioContext, config, timings }) // maxVolume not needed here since it starts at 0

    // =======================================================================
    // 4. DESCONECTAR A DEL MASTER Y RECONECTAR CON EFECTOS
    // =======================================================================
    currentSource.disconnect(masterGain)
    connectEffectsChainA(currentSource, chainA, masterGain)

    // Asegurar volumen maestro correcto (base de usuario, cadenas manejan el ReplayGain)
    masterGain.gain.setValueAtTime(volume, audioContext.currentTime)

    // =======================================================================
    // 5. PROGRAMAR AUTOMATIZACIONES DE A
    // =======================================================================
    scheduleEffectsChainA(chainA, config, timings, trackGainA)

    const filterMode = config.useFilters 
      ? (config.useAggressiveFilters ? 'AGRESIVO' : 'normal') 
      : 'SIN FILTROS'
    
    console.log(
      `[CrossfadeEngine] Fade out A [${config.transitionType}]: 1.0 → 0 en ${(timings.transitionEndTime - timings.filterStartTime).toFixed(2)}s ` +
      `(pre-filtro: ${timings.filterLead.toFixed(2)}s) [${filterMode}]`
    )

    // =======================================================================
    // 6. CONECTAR B CON EFECTOS
    // =======================================================================
    connectEffectsChainB(nextSource, chainB, masterGain)

    // =======================================================================
    // 7. PROGRAMAR AUTOMATIZACIONES DE B
    // =======================================================================
    scheduleEffectsChainB(chainB, config, timings, trackGainB)

    // =======================================================================
    // 8. INICIAR REPRODUCCIÓN DE B
    // =======================================================================
    nextSource.start(timings.anticipationStartTime, timings.startOffset)

    const effectsSummary = getEffectsSummary(chainB)
    const volumeRamp = config.needsAnticipation 
      ? '0%→30%→50%→100%' 
      : '0%→100%'
    
    console.log(
      `[CrossfadeEngine] Fade in B: ${volumeRamp} en ` +
      `${(timings.fadeInEndTime - timings.anticipationStartTime).toFixed(2)}s ` +
      `desde ${timings.startOffset.toFixed(2)}s → ${config.entryPoint.toFixed(2)}s ` +
      `[${effectsSummary.join(', ') || 'sin efectos'}]`
    )

    // =======================================================================
    // 9. ESPERAR Y COMPLETAR
    // =======================================================================
    return new Promise<CrossfadeResult>((resolve) => {
      const cleanupTime = timings.totalTime * 1000 + 500 // +500ms margen

      setTimeout(() => {
        this.completeCrossfade(
          resources,
          chainA,
          chainB,
          config,
          resolve
        )
      }, cleanupTime)
    })
  }

  /**
   * Calcula los timings del crossfade.
   */
  private calculateTimings(
    audioContext: AudioContext,
    config: CrossfadeConfig
  ): CrossfadeTimings {
    const now = audioContext.currentTime

    // Pre-filtro para A
    const filterLead = config.useFilters ? Math.min(1.5, config.fadeDuration * 0.2) : 0

    // Fade-out de A un poco más largo para superposición
    const fadeOutDuration = config.fadeDuration * 1.3
    const totalTransition = fadeOutDuration + filterLead

    // Tiempos de la transición
    const anticipationStartTime = now
    const filterStartTime = now + config.anticipationTime
    const volumeFadeStartTime = filterStartTime + filterLead
    const transitionEndTime = filterStartTime + totalTransition

    // Tiempo total
    const totalTime = config.anticipationTime + totalTransition

    // Fade-in de B
    const fadeInDelay = fadeOutDuration * 0.1
    const fadeInStartTime = volumeFadeStartTime + fadeInDelay
    const fadeInEndTime = fadeInStartTime + config.fadeDuration

    // Offset de B
    const startOffset = config.needsAnticipation
      ? Math.max(0, config.entryPoint - config.fadeDuration - config.anticipationTime)
      : Math.max(0, config.entryPoint - config.fadeDuration)

    return {
      now,
      anticipationStartTime,
      filterStartTime,
      volumeFadeStartTime,
      transitionEndTime,
      filterLead,
      fadeOutDuration,
      totalTime,
      fadeInStartTime,
      fadeInEndTime,
      startOffset,
    }
  }

  /**
   * Completa el crossfade: limpia recursos y promociona B a actual.
   */
  private completeCrossfade(
    resources: CrossfadeResources,
    chainA: EffectsChainA,
    chainB: EffectsChainB,
    config: CrossfadeConfig,
    resolve: (result: CrossfadeResult) => void
  ): void {
    const { currentSource, nextSource, nextBuffer, nextSong, nextAnalysis, masterGain, audioContext, volume } = resources

    console.log(`[CrossfadeEngine] Completando crossfade`)

    // Verificar que los recursos siguen disponibles
    if (!nextSource || !nextBuffer || !nextSong) {
      console.warn('[CrossfadeEngine] ⚠️ Recursos no disponibles al completar')
      this.isCrossfading = false
      return
    }

    // =======================================================================
    // DETENER A
    // =======================================================================
    if (currentSource) {
      try {
        currentSource.onended = null
        currentSource.stop()
      } catch (e) {
        // Ya puede estar detenido
      }
    }

    // =======================================================================
    // LIMPIAR CADENAS DE EFECTOS
    // =======================================================================
    disconnectEffectsChainA(currentSource, chainA)
    disconnectEffectsChainB(nextSource, chainB)

    // =======================================================================
    // RECONECTAR B DIRECTAMENTE AL MASTER
    // =======================================================================
    nextSource.connect(masterGain)

    // Asegurar volumen correcto (incorporando ReplayGain de B ya que la cadena B se destruye)
    const finalVolume = volume * (resources.trackGainB ?? 1.0)
    masterGain.gain.setValueAtTime(finalVolume, audioContext.currentTime)

    // =======================================================================
    // CREAR RESULTADO
    // =======================================================================
    const result: CrossfadeResult = {
      newCurrentSong: nextSong,
      newCurrentSource: nextSource,
      newCurrentBuffer: nextBuffer,
      newCurrentAnalysis: nextAnalysis,
      startOffset: config.entryPoint,
      duration: nextBuffer.duration,
    }

    this.isCrossfading = false
    console.log(`[CrossfadeEngine] ✅ Crossfade completado: "${nextSong.title}"`)

    this.callbacks.onCrossfadeComplete?.(nextSong, config.entryPoint)
    resolve(result)

    // Sugerir GC
    if (typeof window !== 'undefined' && 'gc' in window) {
      // @ts-expect-error - solo en modo debug de Chrome
      window.gc()
    }
  }
}

// =============================================================================
// INSTANCIA SINGLETON
// =============================================================================

/** Instancia singleton del motor de crossfade */
let crossfadeEngineInstance: CrossfadeEngine | null = null

/**
 * Obtiene la instancia singleton del motor de crossfade.
 */
export function getCrossfadeEngine(): CrossfadeEngine {
  if (!crossfadeEngineInstance) {
    crossfadeEngineInstance = new CrossfadeEngine()
  }
  return crossfadeEngineInstance
}

/**
 * Resetea la instancia singleton (útil para testing).
 */
export function resetCrossfadeEngine(): void {
  crossfadeEngineInstance = null
}

