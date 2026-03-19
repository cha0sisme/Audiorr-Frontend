import { useCallback } from 'react'

import { backendApi } from '../services/backendApi'

export interface AudioAnalysisResult {
  bpm: number
  beats: number[]
  beatInterval: number
  energy: number
  key: string
  danceability: number
  outroStartTime: number
  introEndTime: number
  vocalStartTime: number
  fadeInDuration?: number
  fadeOutDuration?: number
  cuePoint?: number
  fadeOutLeadTime?: number
  energyProfile?: {
    intro: number
    main: number
    outro: number
    outroSlope?: number
    introSlope?: number
    outroVocals?: boolean
    introVocals?: boolean
  }
  speechSegments?: { start: number; end: number }[]
  structure?: { label: string; startTime: number; endTime: number }[]
  structureError?: string
  diagnostics?: {
    intro_detection_method?: string
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
    fade_info?: {
      fadeInDuration: number
      fadeOutDuration: number
      cuePoint: number
      fadeOutLeadTime: number
      energyProfile: {
        intro: number
        main: number
        outro: number
      }
    }
    [key: string]: unknown // Para campos adicionales que puedan agregarse
  }
}

export const useAudioAnalysis = () => {
  const analyze = useCallback(
    async (
      streamUrl: string,
      songId: string,
      isProactive = false,
      signal?: AbortSignal
    ): Promise<AudioAnalysisResult | null> => {
      try {
        const result = await backendApi.analyzeSong({ streamUrl, songId, isProactive }, signal)
        return result as AudioAnalysisResult
      } catch (error) {
        // No loguear errores de cancelación (son normales)
        if (error instanceof Error && error.name === 'AbortError') {
          console.log(`[ANALYSIS] Análisis cancelado para songId: ${songId}`)
          return null
        }
        console.error('Error calling backend analyzeSong:', error)
        return null
      }
    },
    []
  )

  const clearAnalysisCache = useCallback(async (): Promise<boolean> => {
    try {
      const result = await backendApi.clearAnalysisCache()
      return Boolean(result?.success)
    } catch (error) {
      console.error('Error clearing analysis cache via backend:', error)
      return false
    }
  }, [])

  return { analyze, clearAnalysisCache }
}
