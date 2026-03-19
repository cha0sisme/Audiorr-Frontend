/**
 * 🎚️ Audio Effects Chain - Factory para crear y configurar filtros de audio
 * 
 * Este módulo encapsula la creación y configuración de filtros Web Audio API:
 * - Highpass (quitar graves)
 * - Lowpass (quitar agudos)
 * - Lowshelf (ajustar graves)
 * - Highshelf (ajustar agudos)
 * 
 * Diseñado para mezcla DJ con parámetros optimizados para transiciones suaves.
 */

import { CrossfadeConfig, CrossfadeTimings, EffectsChainA, EffectsChainB, TransitionType } from './types'

// =============================================================================
// CONSTANTES DE CONFIGURACIÓN DE FILTROS
// =============================================================================

/** Configuración de filtros para modo normal */
const FILTER_CONFIG_NORMAL = {
  highpassA: {
    startFreq: 200,
    midFreq: 4000,
    endFreq: 8000,
    q: 0.7,
  },
  highpassB: {
    startFreq: 400,
    midFreq: 200,
    endFreq: 60,
    q: 0.5,
  },
  lowshelfB: {
    frequency: 200,
    startGain: -8,
    midGain: -4,
    endGain: 0,
  },
}

/** Configuración de filtros para modo agresivo (voces, crossfade corto) */
const FILTER_CONFIG_AGGRESSIVE = {
  highpassA: {
    startFreq: 600,
    midFreq: 2500,
    endFreq: 5000,
    q: 0.7,
  },
  highpassB: {
    startFreq: 800,
    midFreq: 200,
    endFreq: 60,
    q: 0.5,
  },
  lowshelfB: {
    frequency: 200,
    startGain: -12,
    midGain: -6,
    endGain: 0,
  },
}

/** Configuración de filtros con anticipación */
const FILTER_CONFIG_ANTICIPATION = {
  highpassA: {
    startFreq: 600,
    midFreq: 2500,
    endFreq: 5000,
    q: 0.7,
  },
  highpassB: {
    startFreq: 1200,
    midFreq: 600,
    endFreq: 40,
    q: 0.5,
  },
  lowshelfB: {
    frequency: 200,
    startGain: -15,
    midGain: -9,
    endGain: 0,
  },
}

// =============================================================================
// FACTORY DE CADENA DE EFECTOS PARA CANCIÓN A (SALIENTE)
// =============================================================================

export interface CreateEffectsChainAInput {
  audioContext: AudioContext
  config: CrossfadeConfig
  timings: CrossfadeTimings
  maxVolume?: number
}

/**
 * Crea la cadena de efectos para la canción A (saliente).
 * 
 * La cadena incluye:
 * - Highpass que SUBE (quita graves gradualmente)
 * - Gain para fade-out
 */
export function createEffectsChainA(input: CreateEffectsChainAInput): EffectsChainA {
  const { audioContext, config, timings, maxVolume = 1.0 } = input
  
  // Crear gain temporal para A
  const gain = audioContext.createGain()
  gain.gain.value = maxVolume // A empieza al volumen máximo permitido
  
  // Crear highpass si se usan filtros
  let highpass: BiquadFilterNode | null = null
  let highpassConfig = null
  
  if (config.useFilters) {
    const filterConfig = config.useAggressiveFilters
      ? FILTER_CONFIG_AGGRESSIVE.highpassA
      : FILTER_CONFIG_NORMAL.highpassA
    
    highpass = audioContext.createBiquadFilter()
    highpass.type = 'highpass'
    highpass.frequency.setValueAtTime(Math.max(0.1, filterConfig.startFreq), timings.filterStartTime)
    highpass.Q.setValueAtTime(filterConfig.q, timings.filterStartTime)
    
    highpassConfig = {
      type: 'highpass' as const,
      ...filterConfig,
    }
  }
  
  return { highpass, gain, highpassConfig }
}

/**
 * Programa la automatización de la cadena de efectos de A.
 */
export function scheduleEffectsChainA(
  chain: EffectsChainA,
  config: Omit<CrossfadeConfig, 'useFilters' | 'useAggressiveFilters'> & { transitionType: TransitionType },
  timings: CrossfadeTimings,
  maxVolume: number = 1.0
): void {
  const { highpass, gain, highpassConfig } = chain
  const now = timings.now
  
  // Limpiar valores previos
  gain.gain.cancelScheduledValues(now)
  gain.gain.setValueAtTime(maxVolume, now)

  // =======================================================================
  // CURVAS DE VOLUMEN SEGÚN TIPO DE TRANSICIÓN
  // =======================================================================
  switch (config.transitionType) {
    case 'CUT':
    case 'CUT_A_FADE_IN_B': {
      // A mantiene todo el volumen y se corta drásticamente al final
      gain.gain.setValueAtTime(maxVolume, timings.volumeFadeStartTime)
      // Corte a 0 en los últimos 200ms
      const cutTime = Math.max(timings.volumeFadeStartTime, timings.transitionEndTime - 0.2)
      gain.gain.setValueAtTime(maxVolume, cutTime)
      gain.gain.exponentialRampToValueAtTime(0.0001, timings.transitionEndTime)
      break
    }

    case 'EQ_MIX': {
      // Mantiene volumen alto por más tiempo, bajando suavemente con curva exponencial
      gain.gain.setValueAtTime(maxVolume, timings.volumeFadeStartTime)
      // Baja a ~70% en el centro de la transición para dar espacio a B, luego a 0
      const midTimeEq = timings.volumeFadeStartTime + (timings.transitionEndTime - timings.volumeFadeStartTime) / 2
      gain.gain.exponentialRampToValueAtTime(maxVolume * 0.7, midTimeEq)
      gain.gain.exponentialRampToValueAtTime(0.0001, timings.transitionEndTime)
      break
    }

    case 'BEAT_MATCH_BLEND': {
      // Bebid a que el ritmo cuadra, retenemos A encendido mucho más tiempo.
      // Solo suprimimos su EQ (highpass) más abajo.
      gain.gain.setValueAtTime(maxVolume, timings.volumeFadeStartTime)
      const lateTime = timings.transitionEndTime - (timings.transitionEndTime - timings.volumeFadeStartTime) * 0.2
      // Se mantiene casi al tope (80%) durante el 80% de la transición
      gain.gain.exponentialRampToValueAtTime(maxVolume * 0.8, lateTime)
      // Fuerte apagado al final
      gain.gain.exponentialRampToValueAtTime(0.0001, timings.transitionEndTime)
      break
    }

    case 'NATURAL_BLEND': {
      // Ambos relajados: Evitamos hacer "doble fade" dejando que A mantenga casi todo su volumen 
      // durante la primera mitad, aprovechando su decaimiento natural (Outro). No lo cortamos exponencialmente.
      gain.gain.setValueAtTime(maxVolume, timings.volumeFadeStartTime)
      const midTime = timings.volumeFadeStartTime + (timings.transitionEndTime - timings.volumeFadeStartTime) * 0.5
      gain.gain.linearRampToValueAtTime(maxVolume * 0.9, midTime)
      gain.gain.linearRampToValueAtTime(0.0001, timings.transitionEndTime)
      break
    }

    case 'CROSSFADE':
    case 'FADE_OUT_A_CUT_B':
    default: {
      // Comportamiento clásico: fade out lineal/exponencial
      gain.gain.setValueAtTime(maxVolume, timings.volumeFadeStartTime)
      gain.gain.exponentialRampToValueAtTime(0.0001, timings.transitionEndTime)
      break
    }
  }
  
  // =======================================================================
  // PROGRAMAR FILTROS DE A
  // =======================================================================
  if (highpass && highpassConfig) {
    highpass.frequency.cancelScheduledValues(now)
    
    if (config.transitionType === 'EQ_MIX' || config.transitionType === 'BEAT_MATCH_BLEND') {
      // En EQ_MIX, los graves de A se cortan más rápido para dejar espacio al bombo de B
      const quickCutTime = timings.volumeFadeStartTime + (timings.transitionEndTime - timings.volumeFadeStartTime) * 0.3
      highpass.frequency.setValueAtTime(highpassConfig.startFreq, timings.filterStartTime)
      highpass.frequency.exponentialRampToValueAtTime(highpassConfig.midFreq, quickCutTime)
      highpass.frequency.exponentialRampToValueAtTime(highpassConfig.endFreq, timings.transitionEndTime)
    } else {
      // Normal
      highpass.frequency.setValueAtTime(highpassConfig.startFreq, timings.filterStartTime)
      highpass.frequency.linearRampToValueAtTime(highpassConfig.midFreq, timings.volumeFadeStartTime)
      highpass.frequency.linearRampToValueAtTime(highpassConfig.endFreq, timings.transitionEndTime)
    }
  }
}

// =============================================================================
// FACTORY DE CADENA DE EFECTOS PARA CANCIÓN B (ENTRANTE)
// =============================================================================

export interface CreateEffectsChainBInput {
  audioContext: AudioContext
  config: CrossfadeConfig
  timings: CrossfadeTimings
  maxVolume?: number
}

/**
 * Crea la cadena de efectos para la canción B (entrante).
 * 
 * La cadena incluye:
 * - Highpass que BAJA (trae graves gradualmente)
 * - Lowshelf que SUBE (restaura potencia de graves)
 * - Gain para fade-in
 */
export function createEffectsChainB(input: CreateEffectsChainBInput): EffectsChainB {
  const { audioContext, config, timings } = input
  
  // Crear gain temporal para B
  const gain = audioContext.createGain()
  gain.gain.value = 0 // B empieza silenciado
  
  // Determinar qué configuración usar
  const useHighpass = config.useFilters || config.needsAnticipation
  const useLowshelf = config.useFilters || config.needsAnticipation
  
  let highpass: BiquadFilterNode | null = null
  let lowshelf: BiquadFilterNode | null = null
  let highpassConfig = null
  let lowshelfConfig = null
  
  // Seleccionar configuración base
  const filterConfig = config.needsAnticipation
    ? FILTER_CONFIG_ANTICIPATION
    : (config.useAggressiveFilters ? FILTER_CONFIG_AGGRESSIVE : FILTER_CONFIG_NORMAL)
  
  // Crear highpass B
  if (useHighpass) {
    highpass = audioContext.createBiquadFilter()
    highpass.type = 'highpass'
    highpass.frequency.setValueAtTime(filterConfig.highpassB.startFreq, timings.anticipationStartTime)
    highpass.Q.setValueAtTime(filterConfig.highpassB.q, timings.anticipationStartTime)
    
    highpassConfig = {
      startFreq: filterConfig.highpassB.startFreq,
      midFreq: filterConfig.highpassB.midFreq,
      endFreq: filterConfig.highpassB.endFreq,
      q: filterConfig.highpassB.q,
    }
    
    console.log(`[AudioEffectsChain] 🎚️ B: Highpass ${highpassConfig.startFreq}Hz → ${highpassConfig.endFreq}Hz`)
  }
  
  // Crear lowshelf B
  if (useLowshelf) {
    lowshelf = audioContext.createBiquadFilter()
    lowshelf.type = 'lowshelf'
    lowshelf.frequency.setValueAtTime(filterConfig.lowshelfB.frequency, timings.anticipationStartTime)
    lowshelf.gain.setValueAtTime(filterConfig.lowshelfB.startGain, timings.anticipationStartTime)
    
    lowshelfConfig = {
      type: 'lowshelf' as const,
      frequency: filterConfig.lowshelfB.frequency,
      startGain: filterConfig.lowshelfB.startGain,
      midGain: filterConfig.lowshelfB.midGain,
      endGain: filterConfig.lowshelfB.endGain,
    }
    
    console.log(`[AudioEffectsChain] 🎚️ B: Lowshelf ${lowshelfConfig.startGain}dB → ${lowshelfConfig.endGain}dB`)
  }
  
  return { highpass, lowshelf, gain, highpassConfig, lowshelfConfig }
}

/**
 * Programa la automatización de la cadena de efectos de B.
 */
export function scheduleEffectsChainB(
  chain: EffectsChainB,
  config: CrossfadeConfig,
  timings: CrossfadeTimings,
  maxVolume: number = 1.0
): void {
  const { highpass, lowshelf, gain, highpassConfig, lowshelfConfig } = chain
  
  // Cancelar programaciones previas
  gain.gain.cancelScheduledValues(timings.now)
  gain.gain.setValueAtTime(0, timings.now)
  
  if (config.needsAnticipation) {
    // =======================================================================
    // CON ANTICIPACIÓN: Técnica DJ
    // B entra al 30% con filtros pesados, sube gradualmente
    // =======================================================================
    const anticipationVolume = maxVolume * 0.30 // 30% - audible pero con filtros pesados
    const preMainVolume = maxVolume * 0.50 // 50% - antes del fade principal
    
    gain.gain.linearRampToValueAtTime(anticipationVolume, timings.filterStartTime)
    gain.gain.linearRampToValueAtTime(preMainVolume, timings.fadeInStartTime)
    gain.gain.linearRampToValueAtTime(maxVolume, timings.fadeInEndTime)
    
    // Programar filtros con anticipación
    if (highpass && highpassConfig) {
      // Durante anticipación: bajar gradualmente
      highpass.frequency.linearRampToValueAtTime(highpassConfig.midFreq, timings.filterStartTime)
      // Durante pre-fade: seguir abriendo
      highpass.frequency.linearRampToValueAtTime(300, timings.fadeInStartTime)
      // Durante fade-in: abrir completamente
      highpass.frequency.linearRampToValueAtTime(highpassConfig.endFreq, timings.fadeInEndTime)
    }
    
    if (lowshelf && lowshelfConfig) {
      lowshelf.gain.linearRampToValueAtTime(lowshelfConfig.midGain, timings.filterStartTime)
      lowshelf.gain.linearRampToValueAtTime(-4, timings.fadeInStartTime)
      lowshelf.gain.linearRampToValueAtTime(lowshelfConfig.endGain, timings.fadeInEndTime)
    }
  } else {
    // =======================================================================
    // SIN ANTICIPACIÓN: Respetar modos de transición asimétricos
    // =======================================================================
    gain.gain.setValueAtTime(0, timings.fadeInStartTime)
    
    switch (config.transitionType) {
      case 'FADE_OUT_A_CUT_B':
      case 'CUT': {
        // B entra abruptamente a volumen máximo (casi instanteáneo para evitar click)
        gain.gain.linearRampToValueAtTime(maxVolume, timings.fadeInStartTime + 0.1)
        break
      }
      
      case 'EQ_MIX':
      case 'BEAT_MATCH_BLEND': {
        // B entra más rápido que el crossfade normal (~30% del tiempo total)
        const rapidFadeDuration = (timings.fadeInEndTime - timings.fadeInStartTime) * 0.3
        gain.gain.linearRampToValueAtTime(maxVolume, timings.fadeInStartTime + rapidFadeDuration)
        break
      }
      
      case 'NATURAL_BLEND': {
        // Como están relajados, B puede subir su energía más pronto sin miedo a saturar.
        const midTime = timings.fadeInStartTime + (timings.fadeInEndTime - timings.fadeInStartTime) * 0.4
        gain.gain.linearRampToValueAtTime(maxVolume * 0.8, midTime)
        gain.gain.linearRampToValueAtTime(maxVolume, timings.fadeInEndTime)
        break
      }

      case 'CUT_A_FADE_IN_B':
      case 'CROSSFADE':
      default: {
        // B entra suavemente durante toda la transición
        gain.gain.linearRampToValueAtTime(maxVolume, timings.fadeInEndTime)
        break
      }
    }
    
    // Programar filtros normales
    if (highpass && highpassConfig) {
      highpass.frequency.linearRampToValueAtTime(highpassConfig.endFreq, timings.fadeInEndTime)
    }
    
    if (lowshelf && lowshelfConfig) {
      lowshelf.gain.linearRampToValueAtTime(lowshelfConfig.endGain, timings.fadeInEndTime)
    }
  }
}

// =============================================================================
// UTILIDADES DE CONEXIÓN
// =============================================================================

/**
 * Conecta la cadena de efectos de A.
 * Cadena: source -> [highpass] -> gain -> masterGain
 */
export function connectEffectsChainA(
  source: AudioBufferSourceNode,
  chain: EffectsChainA,
  masterGain: GainNode
): void {
  if (chain.highpass) {
    source.connect(chain.highpass)
    chain.highpass.connect(chain.gain)
  } else {
    source.connect(chain.gain)
  }
  chain.gain.connect(masterGain)
}

/**
 * Conecta la cadena de efectos de B.
 * Cadena: source -> [highpass] -> [lowshelf] -> gain -> masterGain
 */
export function connectEffectsChainB(
  source: AudioBufferSourceNode,
  chain: EffectsChainB,
  masterGain: GainNode
): void {
  let lastNode: AudioNode = source
  
  if (chain.highpass) {
    lastNode.connect(chain.highpass)
    lastNode = chain.highpass
  }
  
  if (chain.lowshelf) {
    lastNode.connect(chain.lowshelf)
    lastNode = chain.lowshelf
  }
  
  lastNode.connect(chain.gain)
  chain.gain.connect(masterGain)
}

/**
 * Desconecta y limpia la cadena de efectos de A.
 */
export function disconnectEffectsChainA(
  source: AudioBufferSourceNode | null,
  chain: EffectsChainA
): void {
  try {
    source?.disconnect()
  } catch (e) { /* Ya desconectado */ }
  
  try {
    chain.highpass?.disconnect()
  } catch (e) { /* Ya desconectado */ }
  
  try {
    chain.gain.disconnect()
  } catch (e) { /* Ya desconectado */ }
}

/**
 * Desconecta y limpia la cadena de efectos de B.
 */
export function disconnectEffectsChainB(
  source: AudioBufferSourceNode | null,
  chain: EffectsChainB
): void {
  try {
    source?.disconnect()
  } catch (e) { /* Ya desconectado */ }
  
  try {
    chain.highpass?.disconnect()
  } catch (e) { /* Ya desconectado */ }
  
  try {
    chain.lowshelf?.disconnect()
  } catch (e) { /* Ya desconectado */ }
  
  try {
    chain.gain.disconnect()
  } catch (e) { /* Ya desconectado */ }
}

// =============================================================================
// UTILIDADES DE LOGGING
// =============================================================================

/**
 * Genera un resumen de los efectos usados para logging.
 */
export function getEffectsSummary(chainB: EffectsChainB): string[] {
  const effects: string[] = []
  if (chainB.highpass) effects.push('highpass↓')
  if (chainB.lowshelf) effects.push('lowshelf↑')
  return effects
}

