/**
 * 🎵 Audio Module - Sistema de audio avanzado con crossfade profesional
 * 
 * Este módulo exporta todos los componentes del sistema de audio:
 * - WebAudioPlayer: Reproductor base
 * - CrossfadeEngine: Motor de transiciones
 * - DJMixingAlgorithms: Cálculos de mezcla
 * - AudioEffectsChain: Filtros y efectos
 * - Types: Interfaces compartidas
 */

// Tipos principales
export type {
  WebAudioPlayerConfig,
  PlaybackState,
  WebAudioPlayerCallbacks,
  CrossfadeConfig,
  CrossfadeTimings,
  EffectsChainA,
  EffectsChainB,
  MixMode,
  MixModeConfig,
  AudioAnalysisResult,
  Song,
} from './types'

export { MIX_MODE_CONFIGS } from './types'

// Algoritmos de mezcla DJ
export {
  calculateSmartEntryPoint,
  calculateAdaptiveFadeDuration,
  decideFilterUsage,
  decideAnticipation,
  calculateCrossfadeConfig,
} from './DJMixingAlgorithms'

export type {
  EntryPointInput,
  EntryPointResult,
  FadeDurationInput,
  FadeDurationResult,
  FilterDecisionInput,
  FilterDecisionResult,
  AnticipationDecisionInput,
  AnticipationDecisionResult,
  CrossfadeCalculationInput,
} from './DJMixingAlgorithms'

// Cadena de efectos de audio
export {
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

export type {
  CreateEffectsChainAInput,
  CreateEffectsChainBInput,
} from './AudioEffectsChain'

// Motor de crossfade
export {
  CrossfadeEngine,
  getCrossfadeEngine,
  resetCrossfadeEngine,
} from './CrossfadeEngine'

export type {
  CrossfadeEngineCallbacks,
  CrossfadeResources,
  CrossfadeResult,
} from './CrossfadeEngine'

