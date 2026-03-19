import { contextBridge, ipcRenderer } from 'electron'

// ⚠️ SEGURIDAD: No exponer ipcRenderer directamente. Solo exponer métodos específicos.
try {
  contextBridge.exposeInMainWorld('electron', {
    // NO exponer ipcRenderer completo - vulnerabilidad de seguridad
    // ipcRenderer, // ❌ REMOVIDO - esto era un agujero de seguridad
    
    toggleDevTools: () => ipcRenderer.send('toggle-devtools'),
    // Exponer la nueva funcionalidad de time-stretching
    stretchAudio: (data: {
      songId: string
      streamUrl: string
      originalBpm: number
      targetBpm: number
    }) => ipcRenderer.invoke('stretch:audio', data),

    checkForStretchedSong: (songId: string) => ipcRenderer.invoke('stretch:check', songId),

    // Obtener imagen de artista desde Deezer API
    getArtistImage: (artistName: string) => ipcRenderer.invoke('get-artist-image', artistName),

    // Extraer colores dominantes de una imagen
    extractImageColors: (imageUrl: string) => ipcRenderer.invoke('extract-image-colors', imageUrl),
    getMemoryUsage: () => ipcRenderer.invoke('get-memory-usage'),
    getCacheSize: () => ipcRenderer.invoke('get-cache-size'),
    getAppVersion: () => ipcRenderer.invoke('get-app-version'),
    analyzeSong: (streamUrl: string, songId: string) =>
      ipcRenderer.invoke('analyze:song', { streamUrl, songId }),
    clearAnalysisCache: (): Promise<{ success: boolean; error?: string }> =>
      ipcRenderer.invoke('analyze:clearCache'),
    getSimilarSongs: (
      artist: string,
      track: string,
      navidromeConfig: { serverUrl: string; username: string; token: string },
      apiKey: string
    ) => ipcRenderer.invoke('getSimilarSongs', { artist, track, navidromeConfig, apiKey }),
    setNavidromeOrigin: (serverUrl: string) =>
      ipcRenderer.invoke('set-navidrome-origin', serverUrl),
    setCanvasServerOrigin: (serverUrl: string) =>
      ipcRenderer.invoke('set-canvas-server-origin', serverUrl),
    // Canvas cache methods
    getCanvasCacheBySongId: (songId: string) =>
      ipcRenderer.invoke('canvas-cache:get-by-song-id', songId),
    getCanvasCacheByTitleArtist: (title: string, artist: string, album?: string) =>
      ipcRenderer.invoke('canvas-cache:get-by-title-artist', title, artist, album),
    setCanvasCache: (
      songId: string,
      title: string,
      artist: string,
      album: string | undefined,
      spotifyTrackId: string | null,
      canvasUrl: string | null
    ) =>
      ipcRenderer.invoke(
        'canvas-cache:set',
        songId,
        title,
        artist,
        album,
        spotifyTrackId,
        canvasUrl
      ),
    clearCanvasCache: () => ipcRenderer.invoke('canvas-cache:clear'),
    getCanvasCacheSize: () => ipcRenderer.invoke('canvas-cache:get-size'),
    // Media Session API
    updateMediaMetadata: (metadata: {
      title: string
      artist: string
      album: string
      artwork?: string
      duration?: number
    }) => ipcRenderer.invoke('media-session:update-metadata', metadata),
    updateMediaPlaybackState: (state: 'playing' | 'paused') =>
      ipcRenderer.invoke('media-session:update-playback-state', state),
    // Método seguro para enviar acciones de media session
    sendMediaSessionAction: (action: string, ...args: unknown[]) => 
      ipcRenderer.send('media-session:action', action, ...args),
    onMediaSessionAction: (callback: (action: string, ...args: unknown[]) => void) => {
      ipcRenderer.on('media-session:action-received', (_, action: string, ...args: unknown[]) => {
        callback(action, ...args)
      })
      // Retornar función de limpieza
      return () => {
        ipcRenderer.removeAllListeners('media-session:action-received')
      }
    },
  })
} catch (error) {
  console.error('[PRELOAD] ✗ ERROR: Failed to execute contextBridge.', error)
}
