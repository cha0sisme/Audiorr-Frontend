/**
 * 🎵 Audio Types - Interfaces y tipos compartidos para el sistema de audio
 */

import { Song } from '../navidromeApi'
import { AudioAnalysisResult } from '../../hooks/useAudioAnalysis'

// =============================================================================
// CONFIGURACIÓN
// =============================================================================

export interface WebAudioPlayerConfig {
  crossfadeDuration: number
  volume: number
  isDjMode: boolean
  useReplayGain?: boolean
}

export interface PlaybackState {
  currentSong: Song | null
  isPlaying: boolean
  currentTime: number
  duration: number
  volume: number
  isCrossfading: boolean
}

// =============================================================================
// CALLBACKS
// =============================================================================

export interface WebAudioPlayerCallbacks {
  onTimeUpdate?: (currentTime: number, duration: number) => void
  onEnded?: () => void
  onError?: (error: Error) => void
  onCrossfadeStart?: () => void
  onCrossfadeComplete?: (nextSong: Song, startOffset?: number) => void
  onLoadStart?: () => void
  onLoadedMetadata?: (duration: number) => void
  onCanPlay?: () => void
  onAutomixTrigger?: () => void
  /** Llamado cuando el pipeline de audio necesita recarga tras suspensión profunda de iOS */
  onRecoveryNeeded?: (song: Song, position: number) => void
  /** Llamado cuando el estado de reproducción cambia por causa externa (interrupción, route change, etc.) */
  onPlaybackStateChanged?: (isPlaying: boolean, currentTime: number, reason?: string) => void
  /** Llamado cuando el crossfade no puede ejecutarse (ej: archivo siguiente no preparado) */
  onCrossfadeFailed?: () => void
  /** Llamado cuando nativo cambió de canción autónomamente (JS estaba congelado en background) */
  onNativeNext?: (data: { title: string; artist: string; album: string; duration: number }) => void
}

// =============================================================================
// CROSSFADE
// =============================================================================

export type TransitionType = 
  | 'CROSSFADE' 
  | 'EQ_MIX' 
  | 'CUT' 
  | 'NATURAL_BLEND'
  | 'BEAT_MATCH_BLEND' 
  | 'CUT_A_FADE_IN_B' 
  | 'FADE_OUT_A_CUT_B'

export interface CrossfadeConfig {
  /** Punto de entrada en la canción B (segundos) */
  entryPoint: number
  /** Duración del fade (segundos) */
  fadeDuration: number
  /** Tipo de transición calculada dinámicamente */
  transitionType: TransitionType
  /** Si usar filtros highpass/lowpass */
  useFilters: boolean
  /** Si los filtros deben ser más agresivos */
  useAggressiveFilters: boolean
  /** Si necesita tiempo de anticipación */
  needsAnticipation: boolean
  /** Tiempo de anticipación extra (segundos) */
  anticipationTime: number
  /** Información de beat-sync para logging */
  beatSyncInfo: string
  /** Indica si la mezcla fue sincronizada al beat y es armónica/estable */
  isBeatSynced: boolean
}

export interface CrossfadeTimings {
  /** Momento actual del AudioContext */
  now: number
  /** Cuando empieza la anticipación (B muy bajo) */
  anticipationStartTime: number
  /** Cuando empiezan los filtros de A */
  filterStartTime: number
  /** Cuando empieza el fade de volumen */
  volumeFadeStartTime: number
  /** Cuando termina la transición */
  transitionEndTime: number
  /** Duración del pre-filtro */
  filterLead: number
  /** Duración del fade-out de A */
  fadeOutDuration: number
  /** Tiempo total incluyendo anticipación */
  totalTime: number
  /** Tiempo de inicio del fade-in de B */
  fadeInStartTime: number
  /** Tiempo de fin del fade-in de B */
  fadeInEndTime: number
  /** Offset donde empieza B en su buffer */
  startOffset: number
}

// =============================================================================
// EFECTOS Y FILTROS
// =============================================================================

export interface FilterConfig {
  /** Frecuencia inicial */
  startFreq: number
  /** Frecuencia media (punto intermedio) */
  midFreq: number
  /** Frecuencia final */
  endFreq: number
  /** Factor Q del filtro */
  q: number
}

export interface HighpassFilterConfig extends FilterConfig {
  type: 'highpass'
}

export interface LowshelfFilterConfig {
  type: 'lowshelf'
  frequency: number
  /** Ganancia inicial (dB) */
  startGain: number
  /** Ganancia media (dB) */
  midGain: number
  /** Ganancia final (dB) */
  endGain: number
}

export interface EffectsChainA {
  /** Filtro highpass para A (opcional) */
  highpass: BiquadFilterNode | null
  /** Gain temporal para A */
  gain: GainNode
  /** Configuración del highpass */
  highpassConfig: HighpassFilterConfig | null
}

export interface EffectsChainB {
  /** Filtro highpass para B (opcional) */
  highpass: BiquadFilterNode | null
  /** Filtro lowshelf para B (opcional) */
  lowshelf: BiquadFilterNode | null
  /** Gain temporal para B */
  gain: GainNode
  /** Configuración del highpass */
  highpassConfig: FilterConfig | null
  /** Configuración del lowshelf */
  lowshelfConfig: LowshelfFilterConfig | null
}

// =============================================================================
// ANÁLISIS DE AUDIO (re-export para conveniencia)
// =============================================================================

export type { AudioAnalysisResult }
export type { Song }

// =============================================================================
// MODO DE MEZCLA
// =============================================================================

export type MixMode = 'dj' | 'normal'

export interface MixModeConfig {
  /** Lead time antes del intro end (segundos) */
  introLeadTime: number
  /** Lead time antes de vocales (segundos) */
  vocalLeadTime: number
  /** Duración mínima del fade (segundos) */
  minFadeDuration: number
  /** Duración máxima del fade (segundos) */
  maxFadeDuration: number
  /** Duración base del fade (segundos) */
  baseFadeDuration: number
  /** Fallback si no hay análisis (porcentaje de duración) */
  fallbackPercent: number
  /** Máximo fallback en segundos */
  fallbackMaxSeconds: number
}

/** Configuraciones predefinidas para cada modo */
export const MIX_MODE_CONFIGS: Record<MixMode, MixModeConfig> = {
  dj: {
    introLeadTime: 2.5,
    vocalLeadTime: 0, // Empieza en las vocales
    minFadeDuration: 5,
    maxFadeDuration: 10,
    baseFadeDuration: 6,
    fallbackPercent: 0.02, // 2%
    fallbackMaxSeconds: 3,
  },
  normal: {
    introLeadTime: 4.5,
    vocalLeadTime: 3, // 3s antes de vocales
    minFadeDuration: 6,
    maxFadeDuration: 12,
    baseFadeDuration: 8,
    fallbackPercent: 0.01, // 1%
    fallbackMaxSeconds: 2,
  },
}

