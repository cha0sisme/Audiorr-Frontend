
export interface ElectronAPI {
  // ⚠️ SEGURIDAD: NO exponer ipcRenderer completo - removido por seguridad
  // Solo métodos específicos y controlados están expuestos a través del contextBridge
  toggleDevTools: () => void
  stretchAudio: (data: {
    songId: string
    streamUrl: string
    originalBpm: number
    targetBpm: number
  }) => Promise<{ stretchedFilePath: string } | { error: string }>
  checkForStretchedSong: (songId: string) => Promise<string | null>
  getArtistImage: (artistName: string) => Promise<string | null>
  extractImageColors: (
    imageUrl: string
  ) => Promise<{ primary: string; secondary: string; accent: string } | null>
  getMemoryUsage: () => Promise<number>
  getCacheSize: () => Promise<number>
  getAppVersion: () => Promise<{ version: string; build: string }>
  analyzeSong: (streamUrl: string, songId: string) => Promise<unknown>
  clearAnalysisCache: () => Promise<{ success: boolean; error?: string }>
  getSimilarSongs: (
    artist: string,
    track: string,
    navidromeConfig: { serverUrl: string; username: string; token: string },
    apiKey: string
  ) => Promise<unknown[]>
  setNavidromeOrigin: (serverUrl: string) => Promise<void>
  setCanvasServerOrigin: (serverUrl: string) => Promise<void>
  // Canvas cache methods
  getCanvasCacheBySongId: (songId: string) => Promise<CanvasCacheEntry | null>
  getCanvasCacheByTitleArtist: (
    title: string,
    artist: string,
    album?: string
  ) => Promise<CanvasCacheEntry | null>
  setCanvasCache: (
    songId: string,
    title: string,
    artist: string,
    album: string | undefined,
    spotifyTrackId: string | null,
    canvasUrl: string | null
  ) => Promise<{ success: boolean; error?: string }>
  clearCanvasCache: () => Promise<{ success: boolean; error?: string }>
  getCanvasCacheSize: () => Promise<number>
  // Media Session API
  updateMediaMetadata: (metadata: {
    title: string
    artist: string
    album: string
    artwork?: string
    duration?: number
  }) => Promise<void>
  updateMediaPlaybackState: (state: 'playing' | 'paused') => Promise<void>
  sendMediaSessionAction: (action: string, ...args: unknown[]) => void
  onMediaSessionAction: (
    callback: (action: string, ...args: unknown[]) => void
  ) => () => void
}

export interface CanvasCacheEntry {
  songId: string
  spotifyTrackId: string | null
  canvasUrl: string | null
  localPath: string | null
  title: string
  artist: string
  album?: string
  cachedAt: string
}


declare global {
  interface Window {
    electron: ElectronAPI
  }
}
