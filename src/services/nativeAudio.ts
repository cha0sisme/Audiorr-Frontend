import { registerPlugin } from '@capacitor/core'
import type { PluginListenerHandle } from '@capacitor/core'
import type { TransitionType } from './audio/types'

// ─── Tipos ────────────────────────────────────────────────────────────────────

export interface NativeAudioPlayOptions {
  url: string
  songId: string
  startAt?: number
  replayGainDb?: number
  trackPeak?: number
  duration?: number
}

export interface NativeAudioPrepareNextOptions {
  url: string
  songId: string
  replayGainDb?: number
  trackPeak?: number
}

export interface CrossfadeNativeConfig {
  entryPoint: number
  fadeDuration: number
  transitionType: TransitionType
  useFilters: boolean
  useAggressiveFilters: boolean
  needsAnticipation: boolean
  anticipationTime: number
}

export interface NowPlayingOptions {
  title: string
  artist: string
  album: string
  duration: number
  artworkUrl?: string
}

export interface TimeUpdateEvent {
  currentTime: number
  duration: number
  isPlaying: boolean
}

export interface PlaybackStateEvent {
  isPlaying: boolean
  currentTime: number
  reason?: string
}

export interface RemoteCommandEvent {
  action: 'next' | 'previous'
}

export interface CrossfadeCompleteEvent {
  startOffset: number
}

export interface ErrorEvent {
  message: string
  code: string
}

export interface ClockSyncResult {
  nativeTime: number
  timestamp: number
}

export interface NativePlaybackState {
  isPlaying: boolean
  currentTime: number
  duration: number
  isCrossfading: boolean
  title: string
  artist: string
  album: string
}

export interface NativeNextEvent {
  title: string
  artist: string
  album: string
  duration: number
}

// ─── Plugin interface ─────────────────────────────────────────────────────────

interface NativeAudioPlugin {
  // Playback
  play(opts: NativeAudioPlayOptions): Promise<void>
  pause(): Promise<void>
  resume(): Promise<void>
  seek(opts: { time: number }): Promise<void>
  stop(): Promise<void>
  setVolume(opts: { volume: number }): Promise<void>
  getCurrentTime(): Promise<{ currentTime: number }>
  getClockSync(): Promise<ClockSyncResult>

  // Crossfade
  prepareNext(opts: NativeAudioPrepareNextOptions): Promise<void>
  executeCrossfade(opts: CrossfadeNativeConfig): Promise<void>
  cancelCrossfade(): Promise<void>

  // Metadata
  updateNowPlaying(opts: NowPlayingOptions): Promise<void>

  // Cache
  clearCache(): Promise<void>
  isCached(opts: { songId: string }): Promise<{ cached: boolean }>

  // Background automix & state
  setAutomixTrigger(opts: CrossfadeNativeConfig & { triggerTime: number }): Promise<void>
  clearAutomixTrigger(): Promise<void>
  setNextSongMetadata(opts: { title: string; artist: string; album: string; duration: number }): Promise<void>
  getPlaybackState(): Promise<NativePlaybackState>
  ackRemoteCommand(): Promise<void>

  // Events
  addListener(event: 'onTimeUpdate', fn: (data: TimeUpdateEvent) => void): Promise<PluginListenerHandle>
  addListener(event: 'onTrackEnd', fn: (data: Record<string, never>) => void): Promise<PluginListenerHandle>
  addListener(event: 'onCrossfadeStart', fn: (data: Record<string, never>) => void): Promise<PluginListenerHandle>
  addListener(event: 'onCrossfadeComplete', fn: (data: CrossfadeCompleteEvent) => void): Promise<PluginListenerHandle>
  addListener(event: 'onPlaybackStateChanged', fn: (data: PlaybackStateEvent) => void): Promise<PluginListenerHandle>
  addListener(event: 'onRemoteCommand', fn: (data: RemoteCommandEvent) => void): Promise<PluginListenerHandle>
  addListener(event: 'onError', fn: (data: ErrorEvent) => void): Promise<PluginListenerHandle>
  addListener(event: 'onNativeNext', fn: (data: NativeNextEvent) => void): Promise<PluginListenerHandle>
}

// ─── Registro ─────────────────────────────────────────────────────────────────

export const nativeAudio = registerPlugin<NativeAudioPlugin>('NativeAudio')
