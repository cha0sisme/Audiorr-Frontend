import { Capacitor } from '@capacitor/core'

export const isNative = Capacitor.isNativePlatform()

export interface NowPlayingUpdateOptions {
  title:      string
  artist:     string
  artworkUrl: string | undefined
  isPlaying:  boolean
  progress:   number
  duration:   number
  isVisible:  boolean
  /** coverArt ID para construir URL de alta resolución en el viewer nativo */
  coverArt?:  string
  /** IDs for viewer navigation */
  songId?:    string
  albumId?:   string
  artistId?:  string
  /** Texto de estado opcional: "AutoMix" o "Reproduciendo en {device}" */
  subtitle?:  string
  /** true = modo oscuro activo — el lado Swift debe adaptar sus colores */
  isDark?:    boolean
}

function postMessage(name: string, data: unknown) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const handler = (window as any).webkit?.messageHandlers?.[name]
  if (!handler) {
    console.warn('[nativeNowPlaying] postMessage FAILED: no handler for', name)
  }
  handler?.postMessage(data)
}

export const nativeNowPlaying = {
  update(options: NowPlayingUpdateOptions): void {
    if (!isNative) return
    postMessage('nativeUpdateNowPlaying', options)
  },

  hide(): void {
    if (!isNative) return
    postMessage('nativeHideNowPlaying', {})
  },

  showViewer(): void {
    if (!isNative) return
    postMessage('nativeViewerOpen', {})
  },

  hideViewer(): void {
    if (!isNative) return
    postMessage('nativeViewerClose', {})
  },

  /** Envía estado enriquecido al viewer nativo (queue, shuffle, repeat, remote, etc.) */
  updateViewerState(data: {
    songId: string
    albumId: string
    artistId: string
    coverArt: string
    shuffle: boolean
    repeat: string
    isCrossfading: boolean
    isRemote: boolean
    remoteDeviceName?: string
    queue: Array<{ id: string; title: string; artist: string; album: string; albumId: string; coverArt: string; duration: number }>
  }): void {
    if (!isNative) return
    postMessage('nativeUpdateViewerState', data)
  },

  addListener(event: 'tap' | 'playPause' | 'next' | 'previous', fn: () => void): { remove: () => void } {
    const eventMap = {
      tap:       'native-nowplaying-tap',
      playPause: '_nativePlayPause',
      next:      '_nativeNext',
      previous:  '_nativePrevious',
    }
    const domEvent = eventMap[event]
    window.addEventListener(domEvent, fn)
    return { remove: () => window.removeEventListener(domEvent, fn) }
  },
}
