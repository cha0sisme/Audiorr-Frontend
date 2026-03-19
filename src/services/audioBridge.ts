import { Capacitor, registerPlugin } from '@capacitor/core'
import type { PluginListenerHandle } from '@capacitor/core'

// ─── Tipos ────────────────────────────────────────────────────────────────────

export interface NowPlayingInfo {
  title: string
  artist: string
  album: string
  duration: number
  elapsedTime: number
  artworkUrl?: string
}

export interface PlaybackStateInfo {
  isPlaying: boolean
  elapsedTime: number
}

export type RemoteCommand =
  | 'play'
  | 'pause'
  | 'togglePlayPause'
  | 'next'
  | 'previous'
  | 'seek'

export interface RemoteCommandEvent {
  command: RemoteCommand
  position?: number // solo en 'seek'
}

interface AudioBridgePluginInterface {
  updateNowPlaying(options: NowPlayingInfo): Promise<void>
  updatePlaybackState(options: PlaybackStateInfo): Promise<void>
  clearNowPlaying(): Promise<void>
  addListener(
    eventName: 'remoteCommand',
    listenerFunc: (event: RemoteCommandEvent) => void
  ): Promise<PluginListenerHandle>
}

// ─── Registro del plugin ──────────────────────────────────────────────────────

const _plugin = registerPlugin<AudioBridgePluginInterface>('AudioBridge')
const isNative = Capacitor.isNativePlatform()

// ─── API pública ──────────────────────────────────────────────────────────────

async function safeCall<T>(fn: () => Promise<T>): Promise<T | undefined> {
  if (!isNative) return undefined
  try {
    return await fn()
  } catch (e) {
    console.warn('[AudioBridge]', e)
    return undefined
  }
}

export const audioBridge = {
  updateNowPlaying: (info: NowPlayingInfo) =>
    safeCall(() => _plugin.updateNowPlaying(info)),

  updatePlaybackState: (state: PlaybackStateInfo) =>
    safeCall(() => _plugin.updatePlaybackState(state)),

  clearNowPlaying: () =>
    safeCall(() => _plugin.clearNowPlaying()),

  addRemoteCommandListener: (handler: (e: RemoteCommandEvent) => void) => {
    if (!isNative) return Promise.resolve({ remove: async () => {} } as PluginListenerHandle)
    return _plugin.addListener('remoteCommand', handler)
  },
}
