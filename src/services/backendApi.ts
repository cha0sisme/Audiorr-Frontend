import type { NavidromeConfig } from './navidromeApi'
import type { PinnedPlaylist } from '../types/playlist'

// En desarrollo, usar el proxy de Vite para evitar CORS
// En producción/build, usar la URL directa del backend
const isDev = import.meta.env.DEV
// Prioridad: 1) runtime (env.js inyectado por Docker) → 2) baked en el build → 3) fallback por hostname
const runtimeUrl = typeof window !== 'undefined' ? (window as any).__AUDIORR_BACKEND_URL__ as string | undefined : undefined
const envUrl = import.meta.env.VITE_API_URL as string | undefined
const defaultBackendUrl = typeof window !== 'undefined'
  ? `${window.location.protocol}//${window.location.hostname}:2999`
  : 'http://localhost:2999'

const backendUrl = (runtimeUrl || envUrl || defaultBackendUrl).replace(/\/$/, '')
export const API_BASE_URL = isDev ? '' : backendUrl // En dev, usar proxy relativo; en prod, URL completa
console.log('[backendApi] Using API Base:', isDev ? `proxy (dev) -> ${backendUrl}` : API_BASE_URL)

interface AnalyzeSongPayload {
  streamUrl: string
  songId: string
  isProactive?: boolean
}

interface CanvasPayload {
  songId: string
  title: string
  artist: string
  album?: string
  spotifyTrackId?: string | null
  canvasUrl?: string | null
}

interface LastFmConfigPayload {
  apiKey: string
  apiSecret?: string
}


export interface SpotifyTrack {
  id: string
  name: string
  artist: string
  album: string
  duration_ms: number
}

export interface SyncPreviewResult {
  id?: string
  name: string
  trackCount: number
  matchCount: number
  percentage: number
  tracks: {
    spotify: SpotifyTrack
    found: boolean
    navidromeId?: string
    isManual?: boolean
  }[]
}

export interface SyncedPlaylist {
  spotifyId: string
  navidromeId: string | null
  name: string
  lastSync: string | null
  trackCount: number
  matchCount: number
  enabled: boolean
  createdAt: string
  updatedAt: string
}

export interface DailyMix {
  mixNumber: number
  username: string
  navidromeId: string | null
  name: string
  clusterSeed: string | null
  trackCount: number
  lastGenerated: string | null
  enabled: boolean
  createdAt: string
  updatedAt: string
}

export interface GenerateMixesResult {
  generated: number
  mixes: DailyMix[]
  reason?: string
}

export interface GenerateAllMixesResult {
  users: string[]
  totalGenerated: number
  results: Record<string, { generated: number; reason?: string }>
}

export interface CronStatus {
  status: 'idle' | 'running' | 'error' | 'success'
  lastRun?: string
  nextRun?: string
  lastError?: string
}

export interface SmartPlaylist {
  playlistKey: string
  username: string
  navidromeId: string | null
  name: string
  coverVariant: string
  homePosition: number | null
  trackCount: number
  lastGenerated: string | null
  enabled: boolean
  createdAt: string
  updatedAt: string
}

export const backendApi = {
  async analyzeSong(payload: AnalyzeSongPayload, signal?: AbortSignal) {
    const response = await fetch(`${API_BASE_URL}/api/analysis/song`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal, // Añadir soporte para AbortSignal
    })
    if (!response.ok) throw new Error('Analysis failed')
    return response.json()
  },

  async getBulkAnalysisStatus(songIds: string[]) {
    const response = await fetch(`${API_BASE_URL}/api/analysis/bulk-status`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ songIds }),
    })
    if (!response.ok) throw new Error('Bulk analysis status failed')
    const data = await response.json()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return data.results as Record<string, any>
  },

  async clearAnalysisCache() {
    const response = await fetch(`${API_BASE_URL}/api/analysis/cache`, {
      method: 'DELETE',
    })
    if (!response.ok) throw new Error('Failed to clear analysis cache')
    return response.json()
  },

  async getCanvasBySongId(songId: string) {
    const response = await fetch(`${API_BASE_URL}/api/canvas/${encodeURIComponent(songId)}`)
    if (response.status === 404) return null
    if (!response.ok) throw new Error('Canvas fetch failed')
    return response.json()
  },

  async saveCanvas(payload: CanvasPayload) {
    const response = await fetch(`${API_BASE_URL}/api/canvas`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })
    if (!response.ok) throw new Error('Canvas save failed')
    return response.json()
  },

  async extractImageColors(imageUrl: string) {
    if (imageUrl.startsWith('data:')) {
      return null
    }
    const response = await fetch(`${API_BASE_URL}/api/image/colors`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ imageUrl }),
    })
    if (!response.ok) throw new Error('Image color extraction failed')
    return response.json()
  },

  async getArtistImage(name: string): Promise<{ imageUrl: string | null; source: string }> {
    const params = new URLSearchParams({ name })
    const response = await fetch(`${API_BASE_URL}/api/artist/image?${params.toString()}`)
    if (!response.ok) throw new Error('Artist image fetch failed')
    return response.json()
  },

  async fetchSpotifyCanvas(trackId: string) {
    const params = new URLSearchParams({ trackId })
    const response = await fetch(`${API_BASE_URL}/api/spotify/canvas?${params.toString()}`)
    if (!response.ok) throw new Error('Spotify canvas fetch failed')
    return response.json()
  },

  async searchSpotifyTrack(title: string, artist: string, album?: string) {
    const params = new URLSearchParams({ title, artist })
    if (album) params.set('album', album)

    const response = await fetch(`${API_BASE_URL}/api/spotify/search?${params.toString()}`)
    if (!response.ok) throw new Error('Spotify track search failed')
    return response.json()
  },

  async getSimilarSongs(payload: {
    artist: string
    track: string
    navidromeConfig: Record<string, unknown>
    apiKey?: string
  }) {
    const response = await fetch(`${API_BASE_URL}/api/similar-songs`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })
    if (!response.ok) throw new Error('Similar songs fetch failed')
    return response.json()
  },

  async getLastFmConfig() {
    const response = await fetch(`${API_BASE_URL}/api/config/lastfm`)
    if (!response.ok) throw new Error('Failed to fetch Last.fm config')
    return response.json()
  },

  async saveLastFmConfig(config: LastFmConfigPayload) {
    const response = await fetch(`${API_BASE_URL}/api/config/lastfm`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(config),
    })
    if (!response.ok) throw new Error('Failed to save Last.fm config')
  },

  async deleteLastFmConfig() {
    const response = await fetch(`${API_BASE_URL}/api/config/lastfm`, {
      method: 'DELETE',
    })
    if (!response.ok) throw new Error('Failed to delete Last.fm config')
  },

  // User Preferences API
  async getPinnedPlaylists(username: string) {
    const response = await fetch(`${API_BASE_URL}/api/user/${encodeURIComponent(username)}/pinned-playlists`)
    if (!response.ok) throw new Error('Failed to fetch pinned playlists')
    const data = await response.json()
    return data.pinnedPlaylists as PinnedPlaylist[]
  },

  async savePinnedPlaylists(username: string, pinnedPlaylists: PinnedPlaylist[]) {
    const response = await fetch(`${API_BASE_URL}/api/user/${encodeURIComponent(username)}/pinned-playlists`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pinnedPlaylists }),
    })
    if (!response.ok) throw new Error('Failed to save pinned playlists')
    const data = await response.json()
    return data.pinnedPlaylists as PinnedPlaylist[]
  },

  async deletePinnedPlaylist(username: string, playlistId: string) {
    const response = await fetch(
      `${API_BASE_URL}/api/user/${encodeURIComponent(username)}/pinned-playlists/${encodeURIComponent(playlistId)}`,
      {
        method: 'DELETE',
      }
    )
    if (!response.ok) throw new Error('Failed to delete pinned playlist')
    const data = await response.json()
    return data.pinnedPlaylists as PinnedPlaylist[]
  },

  async getUserPreferences(username: string) {
    const response = await fetch(`${API_BASE_URL}/api/user/${encodeURIComponent(username)}/preferences`)
    if (!response.ok) throw new Error('Failed to fetch user preferences')
    return response.json()
  },

  async updateAvatar(username: string, avatarUrl: string | null) {
    const response = await fetch(`${API_BASE_URL}/api/user/${encodeURIComponent(username)}/avatar`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ avatarUrl }),
    })
    if (!response.ok) throw new Error('Failed to update avatar')
    const data = await response.json()
    return data.avatarUrl as string | null
  },

  async getWrappedStats(username: string, year?: number, navidromeConfig?: NavidromeConfig | null) {
    const params = new URLSearchParams({ username })
    if (year) params.set('year', year.toString())
    
    // Añadir credenciales de Navidrome si están disponibles
    const headers: HeadersInit = { 'Content-Type': 'application/json' }
    if (navidromeConfig) {
      // Enviar las credenciales de Navidrome para verificación en el backend
      headers['X-Navidrome-User'] = navidromeConfig.username
      if (navidromeConfig.token) {
        headers['X-Navidrome-Token'] = navidromeConfig.token
      }
    }
    
    const response = await fetch(`${API_BASE_URL}/api/stats/wrapped?${params.toString()}`, {
      headers
    })
    if (!response.ok) {
      const error = await response.json().catch(() => ({ error: 'Failed to fetch wrapped stats' }))
      throw new Error(error.error || 'Failed to fetch wrapped stats')
    }
    return response.json()
  },

  // Estadísticas de usuario (sin restricción de fecha, para perfil)
  async getUserStats(username: string, period: 'week' | 'month' = 'week') {
    const params = new URLSearchParams({ username, period })
    
    const response = await fetch(`${API_BASE_URL}/api/stats/user-stats?${params.toString()}`)
    if (!response.ok) {
      const error = await response.json().catch(() => ({ error: 'Failed to fetch user stats' }))
      throw new Error(error.error || 'Failed to fetch user stats')
    }
    return response.json()
  },

  async recordScrobble(data: {
    username: string
    songId: string
    title: string
    artist: string
    album: string
    albumId?: string
    duration: number
    playedAt: string
    year?: number
    genre?: string
    bpm?: number
    energy?: number
    alpha?: number
    beta?: number
    contextUri?: string | null
  }) {
    const response = await fetch(`${API_BASE_URL}/api/scrobble/scrobble`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    })
    if (!response.ok) {
      const error = await response.json().catch(() => ({ error: 'Failed to record scrobble' }))
      throw new Error(error.error || 'Failed to record scrobble')
    }
    return response.json()
  },

  // Spotify Sync API
  async saveSyncNavidromeConfig(config: NavidromeConfig) {
    const response = await fetch(`${API_BASE_URL}/api/sync/config`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(config),
    })
    if (!response.ok) throw new Error('Failed to save sync config')
    return response.json()
  },

  async getSyncPreview(spotifyId: string) {
    const response = await fetch(`${API_BASE_URL}/api/sync/preview/${encodeURIComponent(spotifyId)}`)
    if (!response.ok) {
      const error = await response.json().catch(() => ({ error: 'Failed to fetch preview' }))
      throw new Error(error.error || 'Failed to fetch preview')
    }
    return response.json() as Promise<SyncPreviewResult>
  },

  async startSync(spotifyId: string, name?: string): Promise<SyncedPlaylist> {
    const response = await fetch(`${API_BASE_URL}/api/sync/start`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ spotifyId, name }),
    })
    if (!response.ok) throw new Error('Failed to start sync')
    return response.json() as Promise<SyncedPlaylist>
  },

  async listSyncs() {
    const response = await fetch(`${API_BASE_URL}/api/sync/list`)
    if (!response.ok) throw new Error('Failed to list syncs')
    return response.json() as Promise<SyncedPlaylist[]>
  },

  async deleteSync(spotifyId: string) {
    const response = await fetch(`${API_BASE_URL}/api/sync/${encodeURIComponent(spotifyId)}`, {
      method: 'DELETE',
    })
    if (!response.ok) throw new Error('Failed to delete sync')
    return response.json()
  },

  async searchNavidromeSongs(query: string): Promise<{ id: string; title: string; artist: string; album: string }[]> {
    const params = new URLSearchParams({ q: query })
    const response = await fetch(`${API_BASE_URL}/api/sync/search-songs?${params.toString()}`)
    if (!response.ok) {
      const err = await response.json().catch(() => ({ error: 'Search failed' }))
      throw new Error(err.error || 'Search failed')
    }
    const data = await response.json()
    return data.songs as { id: string; title: string; artist: string; album: string }[]
  },

  async saveManualMatch(params: {
    spotifyTrackId: string
    navidromeSongId: string
    spotifyTrackName?: string
    spotifyArtist?: string
    navidromeTitle?: string
    navidromeArtist?: string
  }): Promise<void> {
    const response = await fetch(`${API_BASE_URL}/api/sync/manual-match`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(params),
    })
    if (!response.ok) {
      const err = await response.json().catch(() => ({ error: 'Failed to save match' }))
      throw new Error(err.error || 'Failed to save match')
    }
  },

  async triggerSync(spotifyId: string) {
    const response = await fetch(`${API_BASE_URL}/api/sync/sync/${encodeURIComponent(spotifyId)}`, {
      method: 'POST',
    })
    if (!response.ok) throw new Error('Failed to trigger sync')
    return response.json()
  },

  // Daily Mix API
  async getDailyMixes(navidromeConfig?: NavidromeConfig | null): Promise<DailyMix[]> {
    const headers: HeadersInit = {}
    if (navidromeConfig) {
      headers['X-Navidrome-User'] = navidromeConfig.username
      if (navidromeConfig.token) {
        headers['X-Navidrome-Token'] = navidromeConfig.token
      }
    }

    const response = await fetch(`${API_BASE_URL}/api/daily-mixes`, { headers })
    if (!response.ok) throw new Error('Failed to fetch daily mixes')
    const data = await response.json()
    return data.mixes as DailyMix[]
  },

  async generateDailyMixes(navidromeConfig?: NavidromeConfig | null): Promise<GenerateMixesResult> {
    const headers: HeadersInit = { 'Content-Type': 'application/json' }
    if (navidromeConfig) {
      headers['X-Navidrome-User'] = navidromeConfig.username
      if (navidromeConfig.token) {
        headers['X-Navidrome-Token'] = navidromeConfig.token
      }
    }

    const response = await fetch(`${API_BASE_URL}/api/daily-mixes/generate`, {
      method: 'POST',
      headers
    })
    if (!response.ok) throw new Error('Failed to generate daily mixes')
    return response.json() as Promise<GenerateMixesResult>
  },

  async generateAllDailyMixes(): Promise<GenerateAllMixesResult> {
    const response = await fetch(`${API_BASE_URL}/api/daily-mixes/generate-all`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
    })
    if (response.status === 429) {
      const data = await response.json()
      throw new Error(data.message || 'Too many requests — please wait before retrying')
    }
    if (!response.ok) throw new Error('Failed to generate all daily mixes')
    return response.json() as Promise<GenerateAllMixesResult>
  },

  async getDailyMixesCronStatus(): Promise<CronStatus> {
    const response = await fetch(`${API_BASE_URL}/api/daily-mixes/cron-status`)
    if (!response.ok) throw new Error('Failed to fetch cron status')
    return response.json() as Promise<CronStatus>
  },

  async deleteDailyMix(mixNumber: number, navidromeConfig?: NavidromeConfig | null): Promise<void> {
    const headers: HeadersInit = {}
    if (navidromeConfig) {
      headers['X-Navidrome-User'] = navidromeConfig.username
      if (navidromeConfig.token) {
        headers['X-Navidrome-Token'] = navidromeConfig.token
      }
    }

    const response = await fetch(`${API_BASE_URL}/api/daily-mixes/${mixNumber}`, {
      method: 'DELETE',
      headers
    })
    if (!response.ok) throw new Error('Failed to delete daily mix')
  },

  async regenerateAllCovers() {
    const response = await fetch(`${API_BASE_URL}/api/playlists/regenerate-all`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
    })
    if (!response.ok) {
      const err = await response.json().catch(() => ({ error: 'Failed to regenerate covers' }))
      throw new Error(err.error || 'Failed to regenerate covers')
    }
    return response.json()
  },

  // ─── Global Settings API ─────────────────────────────────────────────────────

  async getGlobalSetting<T>(key: string): Promise<T | null> {
    try {
      const response = await fetch(`${API_BASE_URL}/api/settings/${encodeURIComponent(key)}`)
      if (!response.ok) return null
      const data = await response.json()
      return data.value as T
    } catch {
      return null
    }
  },

  async setGlobalSetting<T>(key: string, value: T): Promise<T> {
    const response = await fetch(`${API_BASE_URL}/api/settings/${encodeURIComponent(key)}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ value }),
    })
    if (!response.ok) throw new Error('Failed to save global setting')
    const data = await response.json()
    return data.value as T
  },

  // ─── Playback Position Persistence ───────────────────────────────────────────

  async getLastPlayback(username: string): Promise<LastPlaybackState | null> {
    try {
      const response = await fetch(`${API_BASE_URL}/api/user/${encodeURIComponent(username)}/last-playback`)
      if (!response.ok) return null
      const data = await response.json()
      return data.lastPlayback as LastPlaybackState | null
    } catch {
      return null
    }
  },

  /**
   * Guarda la posición de reproducción.
   * En beforeunload usa sendBeacon para garantizar el envío aunque la página se cierre.
   */
  saveLastPlayback(username: string, state: LastPlaybackState, useBeacon = false): void {
    const url = `${API_BASE_URL}/api/user/${encodeURIComponent(username)}/last-playback`
    const body = JSON.stringify(state)

    if (useBeacon && typeof navigator !== 'undefined' && navigator.sendBeacon) {
      // sendBeacon garantiza el envío aunque la página se esté cerrando
      // Envía como text/plain (el backend lo parsea manualmente)
      navigator.sendBeacon(url, body)
      return
    }

    // Guardado normal (periódico / visibilitychange)
    fetch(url, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body,
      // keepalive permite que la petición sobreviva al cierre de la página
      keepalive: true,
    }).catch(() => { /* silencioso — no crítico */ })
  },

  // Audiorr Connect Hub — estado del servidor
  async getHubStatus(): Promise<{ ok: boolean; sessions: number; users: number; totalDevices: number; uptimeSeconds: number; serverIp?: string }> {
    const response = await fetch(`${API_BASE_URL}/api/auth/hub-status`)
    if (!response.ok) throw new Error(`Hub unreachable (HTTP ${response.status})`)
    return response.json()
  },

  // Admin
  async getAdminUsers(): Promise<Array<{ username: string; avatarUrl: string | null; createdAt: string; updatedAt: string; lastScrobble: { title: string; artist: string; album: string; playedAt: string } | null }>> {
    const response = await fetch(`${API_BASE_URL}/api/user/admin/users`)
    if (!response.ok) throw new Error(`Failed to fetch users (HTTP ${response.status})`)
    return response.json()
  },

  // Smart Playlists API
  async getSmartPlaylists(navidromeConfig?: NavidromeConfig | null): Promise<SmartPlaylist[]> {
    const headers: HeadersInit = {}
    if (navidromeConfig) {
      headers['X-Navidrome-User'] = navidromeConfig.username
      if (navidromeConfig.token) headers['X-Navidrome-Token'] = navidromeConfig.token
    }
    const response = await fetch(`${API_BASE_URL}/api/smart-playlists`, { headers })
    if (!response.ok) throw new Error('Failed to fetch smart playlists')
    const data = await response.json()
    return data.playlists as SmartPlaylist[]
  },

  async generateSmartPlaylist(
    key: string,
    navidromeConfig?: NavidromeConfig | null,
  ): Promise<{ generated: boolean; playlist: SmartPlaylist | null; reason?: string }> {
    const headers: HeadersInit = { 'Content-Type': 'application/json' }
    if (navidromeConfig) {
      headers['X-Navidrome-User'] = navidromeConfig.username
      if (navidromeConfig.token) headers['X-Navidrome-Token'] = navidromeConfig.token
    }
    const response = await fetch(`${API_BASE_URL}/api/smart-playlists/${encodeURIComponent(key)}/generate`, {
      method: 'POST',
      headers,
    })
    if (!response.ok) throw new Error('Failed to generate smart playlist')
    return response.json()
  },

  async generateAllSmartPlaylists(): Promise<{ results: Record<string, boolean> }> {
    const response = await fetch(`${API_BASE_URL}/api/smart-playlists/generate-all`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
    })
    if (response.status === 429) {
      const data = await response.json()
      throw new Error(data.message || 'Too many requests — please wait before retrying')
    }
    if (!response.ok) throw new Error('Failed to generate all smart playlists')
    return response.json()
  },

  async updateSmartPlaylistConfig(
    key: string,
    patch: { coverVariant?: string; homePosition?: number | null; enabled?: boolean; name?: string },
  ): Promise<SmartPlaylist> {
    const response = await fetch(`${API_BASE_URL}/api/smart-playlists/${encodeURIComponent(key)}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(patch),
    })
    if (!response.ok) throw new Error('Failed to update smart playlist config')
    const data = await response.json()
    return data.playlist as SmartPlaylist
  },

  // Audiorr Connect Auth
  async login(config: NavidromeConfig): Promise<{ token: string; username: string; expiresIn: number }> {
    const response = await fetch(`${API_BASE_URL}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(config),
    })
    if (!response.ok) {
      const error = await response.json().catch(() => ({ error: 'Login failed' }))
      throw new Error(error.error || 'Login failed')
    }
    return response.json()
  },
}

export interface LastPlaybackState {
  songId: string
  title: string
  artist: string
  album: string
  coverArt?: string
  albumId?: string
  path: string
  duration: number
  position: number
  savedAt: string
  queue?: unknown[]
}

