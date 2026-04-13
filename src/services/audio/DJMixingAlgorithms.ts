/**
 * 🎧 DJ Mixing Algorithms - Cálculos puros para mezcla profesional
 * 
 * Este módulo contiene funciones puras (sin side effects) que calculan:
 * - Puntos de entrada inteligentes
 * - Duraciones adaptativas de fade
 * - Decisiones de uso de filtros
 * - Sincronización de beats
 * 
 * Soporta dos modos: DJ (agresivo) y Normal (conservador)
 * 
 * Nuevos tipos asumidos en AudioAnalysisResult (añadidos para mejoras v2):
 * - phraseBoundaries?: number[] // Array de tiempos (s) donde empiezan nuevas frases (ej. cada 8-bars)
 * - downbeatTimes?: number[] // Array de tiempos (s) de los downbeats (el primer beat del compás)
 * - key?: string // Tonalidad en formato Camelot (ej. "8A", "12B")
 */

import {
  AudioAnalysisResult,
  CrossfadeConfig,
  MixMode,
  MIX_MODE_CONFIGS,
  TransitionType,
} from './types'

interface ExtendedAudioAnalysis extends AudioAnalysisResult {
  phraseBoundaries?: number[]
  downbeatTimes?: number[]
}

// =============================================================================
// HARMONIC MIXING (Mejora v2)
// =============================================================================

/**
 * Calcula la distancia en la rueda Camelot.
 * Devuelve la distancia y si se considera un "clash" armónico.
 */
function getHarmonicPenalty(keyA?: string, keyB?: string): { distance: number, isClash: boolean } {
  if (!keyA || !keyB) return { distance: 0, isClash: false }
  
  const matchA = keyA.match(/(\d+)([AB])/i)
  const matchB = keyB.match(/(\d+)([AB])/i)
  if (!matchA || !matchB) return { distance: 0, isClash: false }

  const numA = parseInt(matchA[1], 10)
  const letterA = matchA[2].toUpperCase()
  const numB = parseInt(matchB[1], 10)
  const letterB = matchB[2].toUpperCase()

  const diffNum = Math.min(Math.abs(numA - numB), 12 - Math.abs(numA - numB))
  const diffLetter = letterA !== letterB ? 1 : 0
  
  const totalDistance = diffNum + diffLetter
  // Incompatible si la distancia es > 2, o > 1 pero cambiando major/minor
  const isClash = totalDistance > 2 || (diffLetter === 1 && totalDistance > 1)

  return { distance: totalDistance, isClash }
}
// Mejora v2: Añadido cálculo de distancia armónica Camelot para prevenir mezclas disonantes.

// =============================================================================
// CÁLCULO DE PUNTO DE ENTRADA
// =============================================================================

export interface EntryPointInput {
  /** Análisis de la canción B (siguiente) */
  nextAnalysis: AudioAnalysisResult | null
  /** Análisis de la canción A (actual) - para beat sync */
  currentAnalysis: AudioAnalysisResult | null
  /** Duración del buffer de B */
  bufferDuration: number
  /** Modo de mezcla */
  mode: MixMode
  /** Posición de reproducción actual de A (segundos) — para beat-sync de fase cruzada */
  currentPlaybackTimeA?: number
}

export interface EntryPointResult {
  /** Punto de entrada calculado (segundos) */
  entryPoint: number
  /** Información de beat-sync para logging */
  beatSyncInfo: string
  /** Si se usó fallback (sin datos de análisis) */
  usedFallback: boolean
  /** Si fue posible sincronizar el beat de ambas canciones */
  isBeatSynced: boolean
}

/**
 * Calcula el punto de entrada inteligente para la siguiente canción.
 * 
 * En modo DJ: Más agresivo, busca maximizar el impacto
 * En modo Normal: Conservador, transiciones suaves
 */
export function calculateSmartEntryPoint(input: EntryPointInput): EntryPointResult {
  const { nextAnalysis, currentAnalysis, bufferDuration, mode, currentPlaybackTimeA } = input
  const config = MIX_MODE_CONFIGS[mode]
  
  let entryPoint = 0
  let beatSyncInfo = ''
  let usedFallback = false
  let isBeatSynced = false

  if (!nextAnalysis || 'error' in nextAnalysis) {
    // Sin análisis: usar fallback
    entryPoint = Math.min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)
    usedFallback = true
    console.log(`[DJMixingAlgorithms] ⚠️ Sin análisis, usando fallback: ${entryPoint.toFixed(2)}s`)
  } else {
    const introEndTime = nextAnalysis.introEndTime || 0
    const vocalStartTime = nextAnalysis.vocalStartTime || 0
    const chorusStartTime = nextAnalysis.structure?.[0]?.startTime || 0

    if (mode === 'dj') {
      // MODO DJ: Agresivo, optimizado para DJing
      if (introEndTime > 3) {
        entryPoint = Math.max(0, introEndTime - config.introLeadTime)
      } else if (chorusStartTime > 4) {
        entryPoint = chorusStartTime - 4 // Pre-estribillo
      } else if (vocalStartTime > 2) {
        entryPoint = vocalStartTime - config.vocalLeadTime
      } else {
        entryPoint = Math.min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)
        usedFallback = true
      }
    } else {
      // MODO NORMAL: Conservador pero inteligente
      if (introEndTime > 2.5) {
        entryPoint = Math.max(0, introEndTime - config.introLeadTime)
      } else if (vocalStartTime > 1) {
        entryPoint = Math.max(0, vocalStartTime - config.vocalLeadTime)
      } else if (chorusStartTime > 4) {
        entryPoint = Math.max(0, chorusStartTime - 4)
      } else {
        entryPoint = Math.min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)
        usedFallback = true
      }
    }

    // Mejora v2: Energy flow (Build-up/Boost)
    const energyA = currentAnalysis && !('error' in currentAnalysis) ? (currentAnalysis.energy || 0.5) : 0.5
    const energyB = nextAnalysis.energy || 0.5

    if (energyB > energyA + 0.25) {
      if (chorusStartTime > entryPoint && chorusStartTime < entryPoint + 30) {
        // Adelantar hacia pre-chorus/drop para crear un build-up de energía
        entryPoint = Math.max(0, chorusStartTime - (mode === 'dj' ? 4 : 8))
        console.log(`[DJMixingAlgorithms] ⚡ Energy boost detectado. Adelantando entryPoint a pre-chorus/drop: ${entryPoint.toFixed(2)}s`)
      }
    }

    // Mejora v2: Phrasing (Fraseo musical)
    const phraseBoundaries = (nextAnalysis as ExtendedAudioAnalysis).phraseBoundaries as number[] | undefined
    if (phraseBoundaries && phraseBoundaries.length > 0) {
      const maxAhead = 16 // Máximo adelanto de 16s
      const nextPhrase = phraseBoundaries.find(p => p >= entryPoint && p <= entryPoint + maxAhead)
      if (nextPhrase) {
        entryPoint = nextPhrase
        console.log(`[DJMixingAlgorithms] 🎵 Phrasing activo. Alineado a inicio de frase fuerte: ${entryPoint.toFixed(2)}s`)
      }
    }
  }

  // Beat matching (solo en modo DJ)
  if (mode === 'dj') {
    const beatResult = applyBeatSync(entryPoint, currentAnalysis, nextAnalysis, currentPlaybackTimeA)
    entryPoint = beatResult.adjustedEntryPoint
    beatSyncInfo = beatResult.info
    isBeatSynced = beatResult.isSynced
  }

  // Asegurar que el punto de entrada sea válido
  entryPoint = Math.max(0, Math.min(entryPoint, bufferDuration - 1))

  return { entryPoint, beatSyncInfo, usedFallback, isBeatSynced }
}
// Mejora v2: Incorporada lógica de "Energy Flow" para buscar drops cuando la canción B es más enérgica, 
// y "Phrasing" para encajar la mezcla en el comienzo de bloques de 8 compases exactos si la data existe.

// =============================================================================
// SINCRONIZACIÓN DE BEATS
// =============================================================================

interface BeatSyncResult {
  adjustedEntryPoint: number
  info: string
  isSynced: boolean
}

/**
 * Ajusta el punto de entrada para sincronizar con el beat o downbeat.
 *
 * Con currentPlaybackTimeA: sincronización de fase cruzada real — B entra alineado
 * con la fase de beat de A en ese momento, no solo con la rejilla propia de B.
 * Sin currentPlaybackTimeA: alineación a la rejilla propia de B (comportamiento previo).
 */
function applyBeatSync(
  entryPoint: number,
  currentAnalysis: AudioAnalysisResult | null,
  nextAnalysis: AudioAnalysisResult | null,
  currentPlaybackTimeA?: number
): BeatSyncResult {
  if (
    !currentAnalysis ||
    !nextAnalysis ||
    'error' in currentAnalysis ||
    'error' in nextAnalysis ||
    !currentAnalysis.beatInterval ||
    !nextAnalysis.beatInterval ||
    currentAnalysis.beatInterval <= 0 ||
    nextAnalysis.beatInterval <= 0
  ) {
    return { adjustedEntryPoint: entryPoint, info: '', isSynced: false }
  }

  const beatIntervalA = currentAnalysis.beatInterval
  const beatIntervalB = nextAnalysis.beatInterval

  const downbeatsB = (nextAnalysis as ExtendedAudioAnalysis).downbeatTimes as number[] | undefined
  const targetBeats = (downbeatsB && downbeatsB.length > 0) ? downbeatsB : []

  let adjustedEntryPoint = entryPoint
  let info = ''

  // =========================================================================
  // FASE 1: Alinear B a su propia rejilla de downbeats/compases
  // =========================================================================
  if (targetBeats.length > 0) {
    const nearest = targetBeats.reduce((prev, curr) => Math.abs(curr - entryPoint) < Math.abs(prev - entryPoint) ? curr : prev)
    const rawAdjustment = nearest - entryPoint
    const adjustment = Math.max(-beatIntervalB, Math.min(beatIntervalB, rawAdjustment))
    adjustedEntryPoint = entryPoint + adjustment
    info = `Downbeat real: ${adjustment > 0 ? '+' : ''}${adjustment.toFixed(3)}s`
  } else {
    const measureB = beatIntervalB * 4
    const timeIntoMeasure = entryPoint % measureB
    let rawAdjustment = 0
    if (timeIntoMeasure > measureB * 0.1) {
      rawAdjustment = measureB - timeIntoMeasure
    } else if (timeIntoMeasure > 0.001) {
      rawAdjustment = -timeIntoMeasure
    }
    const adjustment = Math.max(-beatIntervalB, Math.min(beatIntervalB, rawAdjustment))
    adjustedEntryPoint = entryPoint + adjustment
    info = `Estimación 4-beats: ${adjustment > 0 ? '+' : ''}${adjustment.toFixed(3)}s`
  }

  // =========================================================================
  // FASE 2: Alineación de fase cruzada A↔B (requiere posición actual de A)
  //
  // B ya está en su downbeat, pero A puede estar a mitad de compás.
  // Buscamos el downbeat de B más cercano que esté en fase con A:
  //   fase de A ahora = currentPlaybackTimeA % beatIntervalA
  //   B debe estar en esa misma fracción de beat cuando el crossfade arranca.
  //   Ajustamos entryPoint en pasos de beatIntervalB hasta minimizar la diferencia de fase.
  // =========================================================================
  if (currentPlaybackTimeA !== undefined && currentPlaybackTimeA > 0) {
    const beatFractionA = (currentPlaybackTimeA % beatIntervalA) / beatIntervalA // 0..1
    const targetPhaseOffsetB = beatFractionA * beatIntervalB // fase equiv. en rejilla B

    const currentPhaseB = adjustedEntryPoint % beatIntervalB
    let phaseError = targetPhaseOffsetB - currentPhaseB
    // Normalizar a ±0.5 beat
    if (phaseError > beatIntervalB / 2) phaseError -= beatIntervalB
    if (phaseError < -beatIntervalB / 2) phaseError += beatIntervalB

    // Solo aplicar si el error supera 10% del beat (ruido de análisis)
    if (Math.abs(phaseError) > beatIntervalB * 0.10) {
      const phaseAdj = Math.max(-beatIntervalB, Math.min(beatIntervalB, phaseError))
      adjustedEntryPoint += phaseAdj
      info += ` + fase A↔B: ${phaseAdj > 0 ? '+' : ''}${phaseAdj.toFixed(3)}s`
      console.log(
        `[BEAT-SYNC] Fase cruzada: A en ${(beatFractionA * 100).toFixed(0)}% de su beat → ajuste B ${phaseAdj > 0 ? '+' : ''}${phaseAdj.toFixed(3)}s`
      )
    }
  }

  const fullInfo = `Beat-sync (${info}): ${entryPoint.toFixed(2)}s → ${adjustedEntryPoint.toFixed(2)}s`
  console.log(`[BEAT-SYNC] ${fullInfo}`)
  console.log(
    `[BEAT-SYNC] A: ${beatIntervalA.toFixed(3)}s/beat (${(60 / beatIntervalA).toFixed(1)} BPM), ` +
    `B: ${beatIntervalB.toFixed(3)}s/beat (${(60 / beatIntervalB).toFixed(1)} BPM)`
  )

  return { adjustedEntryPoint, info: fullInfo, isSynced: true }
}

// =============================================================================
// CÁLCULO DE DURACIÓN DE FADE
// =============================================================================

export interface FadeDurationInput {
  /** Punto de entrada calculado para B */
  entryPoint: number
  /** Duración del buffer de A */
  bufferADuration: number
  /** Análisis de A (actual) */
  currentAnalysis: AudioAnalysisResult | null
  /** Análisis de B (siguiente) */
  nextAnalysis: AudioAnalysisResult | null
  /** Modo de mezcla */
  mode: MixMode
  /** Duración del buffer de B */
  bufferBDuration: number
}

export interface FadeDurationResult {
  /** Duración del fade calculada */
  duration: number
  /** Explicación de la decisión para logging */
  decision: string
}

/**
 * Calcula la duración adaptativa del crossfade basada en análisis.
 * Considera: intro de B, outro de A, BPM, modo de mezcla, compatibilidad armónica y energía.
 */
export function calculateAdaptiveFadeDuration(input: FadeDurationInput): FadeDurationResult {
  const { entryPoint, bufferADuration, bufferBDuration, currentAnalysis, nextAnalysis, mode } = input
  const config = MIX_MODE_CONFIGS[mode]
  
  let fadeDuration = config.baseFadeDuration
  let decision = `Usando duración base (${fadeDuration}s).`

  const hasCurrentAnalysis = currentAnalysis && !('error' in currentAnalysis)
  const hasNextAnalysis = nextAnalysis && !('error' in nextAnalysis)

  if (hasCurrentAnalysis && hasNextAnalysis) {
    const introB = nextAnalysis!.introEndTime || 0
    const vocalB = nextAnalysis!.vocalStartTime || 0
    
    const energyA = currentAnalysis!.energy || 0.5
    const energyB = nextAnalysis!.energy || 0.5
    
    const keyA = (currentAnalysis as ExtendedAudioAnalysis).key as string | undefined
    const keyB = (nextAnalysis as ExtendedAudioAnalysis).key as string | undefined
    const { isClash } = getHarmonicPenalty(keyA, keyB)
    
    // Calcular duración del outro de A
    const outroAStart = currentAnalysis!.outroStartTime || bufferADuration
    const outroADuration = bufferADuration - outroAStart
    const hasValidOutro = outroADuration >= 2

    // Determinar el punto de "drop" o entrada fuerte de B
    const dropB = introB > 1.0 ? introB : vocalB

    if (dropB > entryPoint) {
      const idealFade = dropB - entryPoint

      if (hasValidOutro) {
        const constrainedDuration = Math.min(idealFade, outroADuration)
        const localMinFade = mode === 'dj' ? 2 : config.minFadeDuration
        fadeDuration = Math.max(localMinFade, Math.min(config.maxFadeDuration, constrainedDuration))
        decision = `Adaptada a intro de ${idealFade.toFixed(2)}s limitada por outro (${outroADuration.toFixed(2)}s) → ${fadeDuration.toFixed(2)}s.`
      } else {
        const localMinFade = mode === 'dj' ? 2 : config.minFadeDuration
        fadeDuration = Math.max(localMinFade, Math.min(config.maxFadeDuration, idealFade))
        decision = `Adaptada a intro de ${idealFade.toFixed(2)}s (outro inválido: ${outroADuration.toFixed(2)}s) → ${fadeDuration.toFixed(2)}s.`
      }
    } else if (hasValidOutro) {
      fadeDuration = Math.max(config.minFadeDuration, Math.min(config.maxFadeDuration - 2, outroADuration * 0.8))
      decision = `Adaptada a outro (${outroADuration.toFixed(2)}s) → ${fadeDuration.toFixed(2)}s.`
    } else {
      fadeDuration = mode === 'dj' ? 5 : 6
      decision = `Usando duración extendida por ser canción abrupta para adelantar transición: ${fadeDuration}s.`
    }

    // Mejora v2: Energy flow dropdown
    if (energyB < energyA - 0.25 && hasValidOutro && outroADuration > 12) {
      // Bajar revoluciones requiere un fade-out muy largo y suave si el outro lo permite
      fadeDuration = Math.min(15, Math.max(fadeDuration, outroADuration * 0.9))
      decision += ` Extendido por caída de energía (Smooth down) a ${fadeDuration.toFixed(2)}s.`
    }

    // Mejora v2: Harmonic mixing (reducir fade por clash)
    if (isClash) {
      // Reducir fade un ~25% para no mantener acordes disonantes sonando juntos demasiado tiempo
      fadeDuration = Math.max(2, fadeDuration * 0.75)
      decision += ` Reducido 25% por incompatibilidad armónica (Clash) a ${fadeDuration.toFixed(2)}s.`
    }

  } else {
    // Si no hay análisis pero el buffer es muy corto, ajustar también.
    if (bufferADuration < 30 || nextAnalysis === null) {
      fadeDuration = 3
      decision = `Usando duración corta de seguridad (sin análisis o pista corta): ${fadeDuration}s.`
    } else {
      decision = `Usando duración base (sin análisis): ${fadeDuration}s.`
    }
  }

  // Mejora v3: Límite absoluto por pistas cortas (nunca más del 25% de la más corta)
  const maxAllowedA = bufferADuration * 0.25
  const maxAllowedB = bufferBDuration * 0.25
  const absoluteMaxFade = Math.min(maxAllowedA, maxAllowedB)

  if (fadeDuration > absoluteMaxFade) {
    fadeDuration = Math.max(2, absoluteMaxFade)
    decision += ` Acortado por límite de 25% por pista corta (A:${bufferADuration.toFixed(0)}s, B:${bufferBDuration.toFixed(0)}s) a ${fadeDuration.toFixed(2)}s.`
  }

  const finalDuration = Math.max(2, fadeDuration)
  
  console.log(`[DJMixingAlgorithms] Duración Fade: ${decision}`)
  
  return {
    duration: finalDuration,
    decision,
  }
}
// Mejora v2: Implementada la reducción de fade en un 25% para "clashes" armónicos (Camelot) limitando las 
// disonancias, y extendiendo los fades hasta 15s si la canción saliente tiene un outro largo y B tiene menor energía.

// =============================================================================
// DECISIÓN DE FILTROS
// =============================================================================

export interface FilterDecisionInput {
  /** Análisis de A (actual) */
  currentAnalysis: AudioAnalysisResult | null
  /** Análisis de B (siguiente) */
  nextAnalysis: AudioAnalysisResult | null
  /** Duración del fade calculada */
  fadeDuration: number
  /** Modo de mezcla */
  mode: MixMode
}

export interface FilterDecisionResult {
  /** Si usar filtros */
  useFilters: boolean
  /** Si usar filtros agresivos */
  useAggressiveFilters: boolean
  /** Si hay voces en el outro de A */
  hasVocalsInOutro: boolean
  /** Si hay voces en el intro de B */
  hasVocalsInIntro: boolean
  /** Diferencia de energía entre canciones */
  energyDiff: number
  /** Diferencia de BPM entre canciones */
  bpmDiff: number
  /** Explicación de la decisión */
  reason: string
}

/**
 * Decide si usar filtros y con qué agresividad.
 * 
 * Los filtros son útiles cuando:
 * - Hay voces en outro/intro (evita que choquen)
 * - Diferencia de energía > 30%
 * - Diferencia de BPM > 20
 * - Clash armónico importante
 * - Crossfade muy corto (< 3s)
 */
export function decideFilterUsage(input: FilterDecisionInput): FilterDecisionResult {
  const { currentAnalysis, nextAnalysis, fadeDuration } = input

  // Detectar voces
  const hasVocalsInOutro = !!(
    currentAnalysis &&
    !('error' in currentAnalysis) &&
    currentAnalysis.vocalStartTime &&
    currentAnalysis.vocalStartTime > 0
  )

  const hasVocalsInIntro = !!(
    nextAnalysis &&
    !('error' in nextAnalysis) &&
    nextAnalysis.vocalStartTime &&
    nextAnalysis.vocalStartTime > 0
  )

  // Obtener características
  const energyA = currentAnalysis && !('error' in currentAnalysis)
    ? (currentAnalysis.energy || 0.5) : 0.5
  const energyB = nextAnalysis && !('error' in nextAnalysis)
    ? (nextAnalysis.energy || 0.5) : 0.5
  const bpmA = currentAnalysis && !('error' in currentAnalysis)
    ? (currentAnalysis.bpm || 120) : 120
  const bpmB = nextAnalysis && !('error' in nextAnalysis)
    ? (nextAnalysis.bpm || 120) : 120

  const keyA = currentAnalysis && !('error' in currentAnalysis) ? (currentAnalysis as ExtendedAudioAnalysis).key as string | undefined : undefined
  const keyB = nextAnalysis && !('error' in nextAnalysis) ? (nextAnalysis as ExtendedAudioAnalysis).key as string | undefined : undefined
  const { isClash } = getHarmonicPenalty(keyA, keyB)

  const energyDiff = Math.abs(energyA - energyB)
  const bpmDiff = Math.abs(bpmA - bpmB)
  const isShortCrossfade = fadeDuration < 4
  const isVeryShortCrossfade = fadeDuration < 3

  // Decidir si usar filtros
  const useFilters = hasVocalsInOutro || hasVocalsInIntro ||
                     energyDiff > 0.3 ||
                     bpmDiff > 20 ||
                     isClash ||
                     isVeryShortCrossfade

  const useAggressiveFilters = (hasVocalsInOutro || hasVocalsInIntro || isShortCrossfade || isClash) && useFilters

  // Construir razón
  const reasons: string[] = []
  if (hasVocalsInOutro || hasVocalsInIntro) reasons.push('voces')
  if (energyDiff > 0.3) reasons.push(`energía ${(energyDiff * 100).toFixed(0)}%`)
  if (bpmDiff > 20) reasons.push(`BPM ±${bpmDiff.toFixed(0)}`)
  if (isClash) reasons.push(`clash tonal`)
  if (isVeryShortCrossfade) reasons.push(`fade<3s`)

  const reason = useFilters
    ? `Filtros ON: ${reasons.join(', ')}`
    : 'Filtros OFF: mezcla simple'

  console.log(`[DJMixingAlgorithms] 🎛️ ${reason}`)

  return {
    useFilters,
    useAggressiveFilters,
    hasVocalsInOutro,
    hasVocalsInIntro,
    energyDiff,
    bpmDiff,
    reason,
  }
}
// Mejora v2: Incorporada validación "isClash" que detecta si la tonalidad de las canciones está muy alejada en la rueda
// Camelot para aplicar barridos de filtros paramétricos que enmascaren la disonancia armónica de forma limpia.

// =============================================================================
// DECISIÓN DE ANTICIPACIÓN
// =============================================================================

export interface AnticipationDecisionInput {
  /** Duración del fade */
  fadeDuration: number
  /** Punto de entrada en B */
  entryPoint: number
}

export interface AnticipationDecisionResult {
  /** Si necesita anticipación */
  needsAnticipation: boolean
  /** Tiempo de anticipación (segundos) */
  anticipationTime: number
  /** Razón de la decisión */
  reason: string
}

/**
 * Decide si usar anticipación para crossfades cortos.
 */
export function decideAnticipation(input: AnticipationDecisionInput): AnticipationDecisionResult {
  const { fadeDuration, entryPoint } = input

  const hasEnoughIntro = entryPoint >= 5
  const needsAnticipation = fadeDuration < 8 && hasEnoughIntro
  
  let anticipationTime = 0
  let reason = ''

  if (needsAnticipation) {
    const maxAnticipation = Math.min(4, entryPoint * 0.3)
    anticipationTime = Math.min(maxAnticipation, Math.max(2, 10 - fadeDuration))
    reason = `Anticipación: +${anticipationTime.toFixed(1)}s (fade corto: ${fadeDuration.toFixed(1)}s)`
  } else if (fadeDuration >= 8) {
    reason = 'Sin anticipación: fade suficientemente largo'
  } else {
    reason = `Sin anticipación: intro insuficiente (${entryPoint.toFixed(1)}s < 5s)`
  }

  return { needsAnticipation, anticipationTime, reason }
}

// =============================================================================
// DECISIÓN DE TIPO DE TRANSICIÓN
// =============================================================================

export interface TransitionTypeDecisionInput {
  /** Análisis de A (actual) */
  currentAnalysis: AudioAnalysisResult | null
  /** Análisis de B (siguiente) */
  nextAnalysis: AudioAnalysisResult | null
  /** Configuración parcial del crossfade */
  config: Omit<CrossfadeConfig, 'transitionType'>
  /** Duración de la canción A */
  bufferADuration: number
}

export interface TransitionTypeDecisionResult {
  /** Tipo de transición elegido */
  type: TransitionType
  /** Razón de la elección para logging */
  reason: string
}

/**
 * Decide qué tipo de transición visual y de volumen aplicar.
 */
export function decideTransitionType(input: TransitionTypeDecisionInput): TransitionTypeDecisionResult {
  const { currentAnalysis, nextAnalysis, config, bufferADuration } = input
  
  const hasCurrentAnalysis = currentAnalysis && !('error' in currentAnalysis)
  const hasNextAnalysis = nextAnalysis && !('error' in nextAnalysis)
  
  let isAAbrupt = false
  if (hasCurrentAnalysis) {
    const outroStart = currentAnalysis!.outroStartTime
    if (!outroStart || outroStart >= bufferADuration - 2) {
      isAAbrupt = true
    }
  } else {
    isAAbrupt = config.fadeDuration < 4
  }

  let isBAbrupt = false
  if (hasNextAnalysis) {
    const introEnd = nextAnalysis!.introEndTime
    // Solo es "abrupto" si B no tiene intro real (< 2s).
    // Entrar en o después del vocal start es lo normal en modo DJ (vocalLeadTime = 0);
    // no implica que la canción sea abrupta, y la condición anterior bloqueaba
    // BEAT_MATCH_BLEND en prácticamente todos los casos con voz.
    if (!introEnd || introEnd < 2) {
      isBAbrupt = true
    }
  } else {
    isBAbrupt = config.fadeDuration < 4
  }
  
  let type: TransitionType = 'CROSSFADE'
  let reason = 'Transición normal'

  if (config.isBeatSynced && !isAAbrupt && !isBAbrupt) {
    type = 'BEAT_MATCH_BLEND'
    reason = 'Beats sincronizados y no abrupto → BEAT_MATCH_BLEND'
  } else if (isAAbrupt && isBAbrupt) {
    if (config.fadeDuration < 4) {
      type = 'CUT'
      reason = 'Ambos abruptos + Fade corto (<4s) → CUT'
    } else {
      type = 'EQ_MIX'
      reason = 'Ambos abruptos + Fade mantenido → EQ_MIX'
    }
  } else if (isAAbrupt && !isBAbrupt) {
    type = 'CUT_A_FADE_IN_B'
    reason = 'A termina abruptamente, B entra suave → CUT_A_FADE_IN_B'
  } else if (!isAAbrupt && isBAbrupt) {
    type = 'FADE_OUT_A_CUT_B'
    reason = 'A termina suave, B entra abruptamente → FADE_OUT_A_CUT_B'
  } else {
    // A es suave y B es suave
    type = 'NATURAL_BLEND'
    reason = 'Ambos suaves (Outro relajado + Intro relajada) → NATURAL_BLEND'
  }

  // Mejora v3: Intervenciones de seguridad crítioca
  
  // 1. Detección de salto extremo de tempo (Caballos al galope)
  const bpmA = currentAnalysis?.bpm || 120
  const bpmB = nextAnalysis?.bpm || 120
  const isExtremeBpmJump = Math.abs(bpmA - bpmB) > 15 && (!config.isBeatSynced)

  if (isExtremeBpmJump && config.fadeDuration > 3) {
    type = 'CUT'
    reason = `Polirritmia evitada (A:${bpmA.toFixed(0)} B:${bpmB.toFixed(0)}) → CUT forzado`
  }

  // 2. Detección de Choque de Voces (Vocal Trainwreck)
  let isVocalTrainwreck = false
  if (hasCurrentAnalysis && hasNextAnalysis) {
    const vocalBStartFromEntry = (nextAnalysis!.vocalStartTime || 0) - config.entryPoint
    
    // Si B empieza a cantar durante el fundido...
    if (vocalBStartFromEntry >= 0 && vocalBStartFromEntry < config.fadeDuration) {
      // Verificamos si A todavía está cantando en ese momento.
      // Un método simple es ver si el outro de A tiene voces o si no hay un outro claro.
      // Usaremos speechSegments si existen para ver si hay voces en A al final.
      const safeOutroA = bufferADuration - config.fadeDuration
      
      let aHasVocalsAtEnd = false
      if (currentAnalysis!.speechSegments && currentAnalysis!.speechSegments.length > 0) {
        // ¿Alguna voz de A cruza el safeOutroA?
        aHasVocalsAtEnd = currentAnalysis!.speechSegments.some(seg => seg.end > safeOutroA)
      } else {
        // Heurística de respaldo: Si no hay outro detectado o es abrupto, y A tiene voz, asumimos que sigue cantando.
        aHasVocalsAtEnd = (!currentAnalysis!.outroStartTime || currentAnalysis!.outroStartTime > safeOutroA) && (currentAnalysis!.vocalStartTime! > 0)
      }
      
      isVocalTrainwreck = aHasVocalsAtEnd
    }
  }

  if (isVocalTrainwreck && type !== 'CUT') {
    type = 'CUT'
    reason = `Vocal Trainwreck evitado (Voces solapadas) → CUT forzado`
  }

  console.log(`[DJMixingAlgorithms] 🎚️ Decisión de Transición: ${type} (${reason})`)

  return { type, reason }
}

// =============================================================================
// FUNCIÓN PRINCIPAL: CALCULAR CONFIGURACIÓN COMPLETA DE CROSSFADE
// =============================================================================

export interface CrossfadeCalculationInput {
  /** Análisis de A (actual) */
  currentAnalysis: AudioAnalysisResult | null
  /** Análisis de B (siguiente) */
  bufferADuration: number
  /** Duración del buffer de B */
  bufferBDuration: number
  /** Modo de mezcla */
  mode: MixMode
  /** Análisis (siguiente) */
  nextAnalysis: AudioAnalysisResult | null
  /** Posición de reproducción actual de A (segundos) — para beat-sync de fase cruzada */
  currentPlaybackTimeA?: number
}

/**
 * Calcula toda la configuración necesaria para el crossfade.
 */
export function calculateCrossfadeConfig(input: CrossfadeCalculationInput): CrossfadeConfig {
  const { currentAnalysis, nextAnalysis, bufferADuration, bufferBDuration, mode, currentPlaybackTimeA } = input

  const entryResult = calculateSmartEntryPoint({
    nextAnalysis,
    currentAnalysis,
    bufferDuration: bufferBDuration,
    mode,
    currentPlaybackTimeA,
  })

  // 2. Calcular duración de fade
  const fadeResult = calculateAdaptiveFadeDuration({
    entryPoint: entryResult.entryPoint,
    bufferADuration,
    bufferBDuration,
    currentAnalysis,
    nextAnalysis,
    mode,
  })

  // 3. Decidir uso de filtros
  const filterResult = decideFilterUsage({
    currentAnalysis,
    nextAnalysis,
    fadeDuration: fadeResult.duration,
    mode,
  })

  // 4. Decidir anticipación
  const anticipationResult = decideAnticipation({
    fadeDuration: fadeResult.duration,
    entryPoint: entryResult.entryPoint,
  })

  // 5. Decidir el tipo de transición
  const baseConfig: Omit<CrossfadeConfig, 'transitionType'> = {
    entryPoint: entryResult.entryPoint,
    fadeDuration: fadeResult.duration,
    useFilters: filterResult.useFilters,
    useAggressiveFilters: filterResult.useAggressiveFilters,
    needsAnticipation: anticipationResult.needsAnticipation,
    anticipationTime: anticipationResult.anticipationTime,
    beatSyncInfo: entryResult.beatSyncInfo,
    isBeatSynced: entryResult.isBeatSynced,
  }

  const transitionTypeResult = decideTransitionType({
    currentAnalysis,
    nextAnalysis,
    config: baseConfig,
    bufferADuration,
  })

  console.log(`[DJMixingAlgorithms] 📊 Config calculada:
    - Modo: ${mode.toUpperCase()}
    - Tipo de Transición: ${transitionTypeResult.type}
    - Entry: ${entryResult.entryPoint.toFixed(2)}s ${entryResult.beatSyncInfo ? `(${entryResult.beatSyncInfo})` : ''}
    - Fade: ${fadeResult.duration.toFixed(2)}s
    - Filtros: ${filterResult.useFilters ? (filterResult.useAggressiveFilters ? 'AGRESIVOS' : 'normales') : 'OFF'}
    - Anticipación: ${anticipationResult.needsAnticipation ? `${anticipationResult.anticipationTime.toFixed(1)}s` : 'OFF'}`)

  return {
    ...baseConfig,
    transitionType: transitionTypeResult.type,
  }
}
