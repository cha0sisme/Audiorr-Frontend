/* eslint-disable @typescript-eslint/no-explicit-any */
import { backendApi } from './backendApi'
import { apiCacheService } from './apiCacheService'

/**
 * Servicio para conectarse con Navidrome usando Subsonic API
 * Documentación: https://www.subsonic.org/pages/api.jsp
 */

export interface NavidromeConfig {
  serverUrl: string
  username: string
  // La contraseña en texto plano solo se usa para la conexión inicial
  // y se convierte a un token hexadecimal que es lo que se guarda.
  password?: string
  token?: string // El token es la contraseña en formato 'enc:hex'
  isAdmin?: boolean // Si el usuario es administrador de Navidrome
}

export interface Song {
  id: string
  title: string
  artist: string
  album: string
  albumId?: string
  playlistId?: string
  duration: number
  coverArt?: string
  path: string
  track?: number
  year?: number
  genre?: string
  playCount?: number
  replayGain?: {
    trackGain?: number
    trackPeak?: number
    albumGain?: number
    albumPeak?: number
  }
}

interface NavidromeDate {
  year: number
  month?: number
  day?: number
}

export interface Album {
  id: string
  name: string
  artist: string
  coverArt?: string
  songCount: number
  duration: number
  playCount?: number
  year?: number
  genre?: string
  created?: string
  originalReleaseDate?: NavidromeDate
  releaseDate?: NavidromeDate
}

export interface ArtistInfo {
  biography: string
  lastFmUrl: string
  smallImageUrl?: string
  mediumImageUrl?: string
  largeImageUrl?: string
  similarArtists: {
    id: string
    name: string
  }[]
}

export interface Playlist {
  id: string
  name: string
  comment?: string
  songCount: number
  duration: number
  public: boolean
  created: string
  changed?: string
  owner: string
  coverArt?: string
  path?: string // Path del archivo (las smart playlists tienen extensión .nsp)
}

/**
 * Helper para detectar si una playlist es smart playlist
 * Las smart playlists en Navidrome tienen extensión .nsp
 */
export function isSmartPlaylist(playlist: Playlist): boolean {
  if (playlist.path && playlist.path.toLowerCase().endsWith('.nsp')) return true
  if (playlist.name && /^\d{5}-.*\.nsp$/i.test(playlist.name)) return true
  if (playlist.comment && playlist.comment.toLowerCase().startsWith('nsp:')) return true
  if (playlist.id && playlist.id.startsWith('sm_')) return true

  const smartPlaylistPatterns = [
    /^tu mix/i,
    /^this is/i,
    /^tus favoritos$/i,
    /^best of/i,
    /^top rated/i,
    /^recently played/i,
    /^most played/i,
    /^random songs/i,
    /^trending$/i,
    /^mix diario/i,
  ]

  return smartPlaylistPatterns.some(pattern => pattern.test(playlist.name))
}

/**
 * Helper para detectar si una playlist es Editorial basándose en su comentario.
 * Audiorr inyecta la etiqueta oculta "[Editorial]" en el comentario de las playlists
 * gestionadas por el sistema.
 */
export function isEditorialPlaylist(playlist: Pick<Playlist, 'comment'>): boolean {
  return !!(playlist.comment && playlist.comment.includes('[Editorial]'))
}

export interface ServerInfo {
  version: string
  name: string
}

export interface Artist {
  name: string
  albumCount?: number
  id?: string
}

class NavidromeAPI {
  private config: NavidromeConfig | null = null
  private lyricsCache: Map<string, string> = new Map()
  private artistIdCache = new Map<string, string | null>()
  
   // Caché genérico en memoria (TTL por defecto: 5 minutos)
  private genericCache = new Map<string, { data: any; timestamp: number }>()
  private defaultTTL = 300000 // 5 minutos

  constructor() {
    // Cargar configuración guardada
    this.loadConfig()
  }

  getUsername(): string | null {
    return this.config?.username ?? null
  }

  // --- NUEVO SISTEMA DE AUTENTICACIÓN ---
  private getAuthParams(format: 'json' | 'binary' = 'json'): string {
    if (!this.config || !this.config.token) return ''

    const baseParams = `u=${encodeURIComponent(
      this.config.username
    )}&p=${encodeURIComponent(this.config.token)}&v=1.16.0&c=audiorr`

    if (format === 'json') {
      return `${baseParams}&f=json`
    }
    return baseParams
  }

  /**
   * Helper para envolver peticiones con caché
   */
  private async withCache<T>(
    key: string,
    fetcher: () => Promise<T>,
    ttl: number = this.defaultTTL
  ): Promise<T> {
    const now = Date.now()
    const cached = this.genericCache.get(key)

    // In-memory hit (fast path)
    if (cached && now - cached.timestamp < ttl) {
      return cached.data as T
    }

    // Offline: serve persisted data regardless of freshness
    if (!navigator.onLine && apiCacheService.isAvailable()) {
      const persisted = await apiCacheService.get<T>(key)
      if (persisted !== null) return persisted
      // Fall through to in-memory stale data if nothing persisted
      if (cached) return cached.data as T
    }

    // Online: fetch from network
    try {
      const data = await fetcher()
      if (data !== null && data !== undefined) {
        this.genericCache.set(key, { data, timestamp: now })
        // Persist to IndexedDB in background (fire and forget)
        if (apiCacheService.isAvailable()) {
          apiCacheService.put(key, data).catch(() => {})
        }
      }
      return data
    } catch (networkError) {
      // Network failed despite being "online" — fall back to persisted data
      if (apiCacheService.isAvailable()) {
        const persisted = await apiCacheService.get<T>(key)
        if (persisted !== null) return persisted
      }
      if (cached) return cached.data as T
      throw networkError
    }
  }

  /**
   * Limpiar el caché genérico
   */
  clearCache() {
    this.genericCache.clear()
    this.playlistsCache = null
    console.debug('[NavidromeAPI] Todo el caché limpiado')
  }

  /**
   * Conectar con el servidor de Navidrome
   */
  async connect(config: NavidromeConfig): Promise<boolean> {
    try {
      if (!config.password) {
        throw new Error('Password is required for initial connection.')
      }

      // 1. Convertir contraseña a formato 'enc:hex'
      const passwordHex = Array.from(new TextEncoder().encode(config.password))
        .map(b => b.toString(16).padStart(2, '0'))
        .join('')
      const token = `enc:${passwordHex}`

      // 2. Verificar que la autenticación es válida haciendo un ping
      const authParams = `u=${encodeURIComponent(
        config.username
      )}&p=${encodeURIComponent(token)}&v=1.16.0&c=audiorr&f=json`
      const verifyUrl = `${config.serverUrl}/rest/ping.view?${authParams}`
      const verifyResponse = await fetch(verifyUrl)
      const verifyData = await verifyResponse.json()

      if (verifyData['subsonic-response']?.status === 'ok') {
        // 3. Conexión exitosa, guardar configuración con el token
        this.config = {
          serverUrl: config.serverUrl,
          username: config.username,
          token: token,
        }

        // 4. Intentar obtener isAdmin desde el endpoint de login de Navidrome
        try {
          const loginResponse = await fetch(`${config.serverUrl}/auth/login`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              username: config.username,
              password: config.password,
            }),
          })
          if (loginResponse.ok) {
            const loginData = await loginResponse.json()
            this.config.isAdmin = loginData.isAdmin === true
            console.log(`[NavidromeAPI] Usuario ${config.username} isAdmin: ${this.config.isAdmin}`)
          }
        } catch (loginError) {
          console.warn('[NavidromeAPI] No se pudo verificar isAdmin:', loginError)
          this.config.isAdmin = false
        }

        this.saveConfig(this.config)

        return true
      } else {
        console.error('Ping with hex password failed. Server response:', verifyData)
        throw new Error('Invalid username or password.')
      }
    } catch (error) {
      console.error('Error connecting to Navidrome:', error)
      this.disconnect() // Limpiar cualquier configuración parcial
      return false
    }
  }

  /**
   * Verificar conexión con el servidor (versión para la página de ajustes)
   */
  async pingForStatus(): Promise<{ status: 'ok' | 'failed' }> {
    if (!this.config) return { status: 'failed' }
    try {
      const url = `${this.config.serverUrl}/rest/ping.view?${this.getAuthParams()}`
      const response = await fetch(url)
      const data = await response.json()
      if (data['subsonic-response']?.status === 'ok') {
        return { status: 'ok' }
      }
      return { status: 'failed' }
    } catch (error) {
      console.error('Ping for status failed:', error)
      return { status: 'failed' }
    }
  }

  /**
   * Obtener información de la licencia del servidor
   */
  async getLicense(): Promise<{ valid: boolean; email: string; expires: string } | null> {
    if (!this.config) return null
    try {
      const url = `${this.config.serverUrl}/rest/getLicense.view?${this.getAuthParams()}`
      const response = await fetch(url)
      const data = await response.json()
      if (data['subsonic-response']?.status === 'ok') {
        return data['subsonic-response'].license
      }
      return null
    } catch (error) {
      console.error('Get license failed:', error)
      return null
    }
  }

  /**
   * Verificar conexión con el servidor
   */
  async ping(): Promise<ServerInfo | null> {
    if (!this.config) return null

    try {
      const url = `${this.config.serverUrl}/rest/ping.view?${this.getAuthParams()}`
      console.log('Trying connection with token to:', this.config.serverUrl)

      const response = await fetch(url, {
        method: 'GET',
        headers: {
          Accept: 'application/json',
        },
      })

      console.log('Response status:', response.status)

      if (!response.ok) {
        console.log('Plain password auth failed, server may require token auth')
        return null
      }

      const data = await response.json()
      console.log('Response data:', data)

      if (data['subsonic-response']?.status === 'ok') {
        return {
          version: data['subsonic-response'].version || 'unknown',
          name: data['subsonic-response'].serverName || 'Navidrome',
        }
      }

      if (data['subsonic-response']?.error) {
        console.error('API Error:', data['subsonic-response'].error)
      }

      return null
    } catch (error) {
      console.error('Ping failed:', error)
      if (error instanceof TypeError && error.message.includes('fetch')) {
        console.error('Network error - check server URL and CORS settings')
      }
      return null
    }
  }

  /**
   * Buscar música
   */
  async search(query: string, count: number = 50): Promise<Song[]> {
    if (!this.config) return []

    try {
      const url = `${this.config.serverUrl}/rest/search3.view?${this.getAuthParams()}&query=${encodeURIComponent(query)}&songCount=${count}`
      const response = await fetch(url)

      const data = await response.json()

      if (data['subsonic-response']?.status === 'ok') {
        const results = data['subsonic-response'].searchResult3
        return this.mapSongs(results?.song || [])
      }

      return []
    } catch (error) {
      console.error('Search failed:', error)
      return []
    }
  }

  /**
   * Búsqueda completa (artistas, álbumes y canciones)
   */
  async searchAll(
    query: string,
    artistCount: number = 10,
    albumCount: number = 10,
    songCount: number = 10
  ): Promise<{
    artists: Array<{ id: string; name: string }>
    albums: Album[]
    songs: Song[]
  }> {
    if (!this.config) return { artists: [], albums: [], songs: [] }

    try {
      const url = `${this.config.serverUrl}/rest/search2.view?${this.getAuthParams()}&query=${encodeURIComponent(
        query
      )}&artistCount=${artistCount}&albumCount=${albumCount}&songCount=${songCount}`
      const response = await fetch(url)

      const data = await response.json()

      if (data['subsonic-response']?.status === 'ok') {
        const results = data['subsonic-response'].searchResult2

        // Mapear artistas (puede ser array o objeto único)
        const artistArray = Array.isArray(results?.artist)
          ? results.artist
          : results?.artist
            ? [results.artist]
            : []
        const artists = artistArray.map((artist: { id: string; name: string }) => ({
          id: artist.id,
          name: artist.name,
        }))

        // Mapear álbumes (puede ser array o objeto único)
        const albumArray = Array.isArray(results?.album)
          ? results.album
          : results?.album
            ? [results.album]
            : []
        const albums = this.mapAlbums(albumArray)

        // Mapear canciones (puede ser array o objeto único)
        const songArray = Array.isArray(results?.song)
          ? results.song
          : results?.song
            ? [results.song]
            : []
        const songs = this.mapSongs(songArray)

        return { artists, albums, songs }
      }

      return { artists: [], albums: [], songs: [] }
    } catch (error) {
      console.error('Search all failed:', error)
      return { artists: [], albums: [], songs: [] }
    }
  }

  /**
   * Obtener los últimos álbumes añadidos
   */
  async getLatestAlbums(size: number = 20): Promise<Album[]> {
    if (!this.config) return []

    try {
      const config = this.config
      const key = `latestAlbums_${size}`
      return this.withCache(key, async () => {
        const url = `${config.serverUrl}/rest/getAlbumList2.view?${this.getAuthParams()}&type=newest&size=${size}`
        const response = await fetch(url)
        const data = await response.json()

        if (data['subsonic-response']?.status === 'ok') {
          const albumList = data['subsonic-response'].albumList2
          return this.mapAlbums(albumList?.album || [])
        }
        return []
      })
    } catch (error) {
      console.error('Get latest albums failed:', error)
      return []
    }
  }

  /**
   * Obtener los álbumes más reproducidos frecuentemente
   */
  async getFrequentAlbums(size: number = 20): Promise<Album[]> {
    if (!this.config) return []

    try {
      const config = this.config
      const key = `frequentAlbums_${size}`
      return this.withCache(key, async () => {
        const url = `${config.serverUrl}/rest/getAlbumList2.view?${this.getAuthParams()}&type=frequent&size=${size}`
        const response = await fetch(url)
        const data = await response.json()

        if (data['subsonic-response']?.status === 'ok') {
          const albumList = data['subsonic-response'].albumList2
          return this.mapAlbums(albumList?.album || [])
        }
        return []
      })
    } catch (error) {
      console.error('Get frequent albums failed:', error)
      return []
    }
  }

  /**
   * Obtener álbumes por rango de años de lanzamiento (Subsonic type=byYear)
   */
  private async getAlbumsByYearRange(
    fromYear: number,
    toYear: number,
    size: number = 100
  ): Promise<Album[]> {
    if (!this.config) return []

    try {
      const config = this.config
      const key = `albumsByYear_${fromYear}_${toYear}_${size}`
      return this.withCache(key, async () => {
        const url = `${config.serverUrl}/rest/getAlbumList2.view?${this.getAuthParams()}&type=byYear&fromYear=${fromYear}&toYear=${toYear}&size=${size}`
        const response = await fetch(url)
        const data = await response.json()

        if (data['subsonic-response']?.status === 'ok') {
          const albumList = data['subsonic-response'].albumList2
          return this.mapAlbums(albumList?.album || [])
        }
        return []
      })
    } catch (error) {
      console.error('Get albums by year range failed:', error)
      return []
    }
  }

  /**
   * Obtener álbumes lanzados recientemente (≈ últimos X meses según metadatos de year)
   */
  async getRecentReleases(maxMonths: number = 6, size: number = 50): Promise<Album[]> {
    const now = new Date()
    const cutoffDate = new Date()
    cutoffDate.setMonth(cutoffDate.getMonth() - maxMonths)
    const cutoffMs = cutoffDate.getTime()
    const fromYear = cutoffDate.getFullYear()
    const toYear = now.getFullYear()

    const getReleaseTimestamp = (album: Album): number | null => {
      const dateSource = album.originalReleaseDate || album.releaseDate
      if (dateSource?.year) {
        const month = dateSource.month ? dateSource.month - 1 : 0
        const day = dateSource.day ?? 1
        return Date.UTC(dateSource.year, month, day)
      }

      if (album.year) {
        return Date.UTC(album.year, 0, 1)
      }

      return null
    }

    const desiredSize = Math.max(size * 2, 100)
    const byYearAlbums = await this.getAlbumsByYearRange(fromYear, toYear, desiredSize)
    const fallbackPool = byYearAlbums.length ? byYearAlbums : await this.getLatestAlbums(desiredSize)
    if (!fallbackPool.length) return []

    const albumsWithRelease = fallbackPool
      .map(album => {
        const releaseTime = getReleaseTimestamp(album)
        return releaseTime ? { album, releaseTime } : null
      })
      .filter((entry): entry is { album: Album; releaseTime: number } => !!entry)

    const filtered = albumsWithRelease.filter(entry => entry.releaseTime >= cutoffMs)

    const selectionSource =
      filtered.length >= size
        ? filtered
        : albumsWithRelease.length
        ? albumsWithRelease
        : []

    return selectionSource
      .sort((a, b) => b.releaseTime - a.releaseTime)
      .map(entry => entry.album)
      .slice(0, size)
  }

  /**
   * Obtener las canciones de una playlist
   */
  async getPlaylistSongs(playlistId: string): Promise<Song[]> {
    if (!this.config) return []

    try {
      const config = this.config
      const key = `playlistSongs_${playlistId}`
      return this.withCache(key, async () => {
        const url = `${config.serverUrl}/rest/getPlaylist.view?${this.getAuthParams()}&id=${playlistId}`
        const response = await fetch(url)
        const data = await response.json()

        if (data['subsonic-response']?.status === 'ok') {
          const playlist = data['subsonic-response'].playlist
          return this.mapSongs(playlist?.entry || [], undefined, playlistId)
        }
        return []
      }, 60000) // 1 minuto (las playlists pueden cambiar más a menudo)
    } catch (error) {
      console.error('Get playlist songs failed:', error)
      return []
    }
  }

  /**
   * Fetch raw getAlbum.view response, shared by getAlbumSongs and getAlbumInfo
   * so both callers reuse a single network request and cache entry.
   */
  private async _getAlbumRaw(albumId: string): Promise<any> {
    if (!this.config) return null
    const config = this.config
    return this.withCache(`album_raw_${albumId}`, async () => {
      const url = `${config.serverUrl}/rest/getAlbum.view?${this.getAuthParams()}&id=${albumId}`
      const response = await fetch(url)
      const data = await response.json()
      return data['subsonic-response']?.status === 'ok' ? data['subsonic-response'].album : null
    }, 300000) // 5 minutos
  }

  /**
   * Obtener las canciones de un álbum
   */
  async getAlbumSongs(albumId: string): Promise<Song[]> {
    if (!this.config) return []
    try {
      const album = await this._getAlbumRaw(albumId)
      return album ? this.mapSongs(album.song || [], albumId) : []
    } catch (error) {
      console.error('Get album songs failed:', error)
      return []
    }
  }

  /**
   * Obtener información completa del álbum (incluyendo tipo de lanzamiento)
   */
  async getAlbumInfo(albumId: string): Promise<{
    name: string
    artist: string
    coverArt?: string
    year?: number
    originalReleaseDate?: { year: number; month?: number; day?: number }
    releaseDate?: { year: number; month?: number; day?: number }
    genre?: string
    mbReleaseType?: string // MusicBrainz release type: album, single, ep, compilation, etc.
    songCount?: number
    duration?: number
    recordLabels?: Array<{ name: string }>
    explicitStatus?: string
  } | null> {
    if (!this.config) return null
    try {
      const album = await this._getAlbumRaw(albumId)
      if (!album) return null

      let releaseType: string | undefined = undefined
      if (album.releaseTypes && Array.isArray(album.releaseTypes) && album.releaseTypes.length > 0) {
        releaseType = album.releaseTypes[0]
      } else {
        releaseType = album.mbReleaseType || album.type || album.albumType || album.releaseType || undefined
      }

      return {
        name: album.name || '',
        artist: album.artist || '',
        coverArt: album.coverArt,
        year: album.year,
        originalReleaseDate: album.originalReleaseDate,
        releaseDate: album.releaseDate,
        genre: album.genre,
        mbReleaseType: releaseType,
        songCount: album.songCount,
        duration: album.duration,
        recordLabels: album.recordLabels,
        explicitStatus: album.explicitStatus,
      }
    } catch (error) {
      console.error('Get album info failed:', error)
      return null
    }
  }

  /**
   * Obtener notas/biografía de un álbum desde el endpoint getAlbumInfo
   */
  async getAlbumNotes(albumId: string): Promise<string | null> {
    if (!this.config) return null
    try {
      const config = this.config
      const key = `albumNotes_${albumId}`
      return this.withCache(key, async () => {
        const url = `${config.serverUrl}/rest/getAlbumInfo.view?${this.getAuthParams()}&id=${albumId}`
        const response = await fetch(url)
        const data = await response.json()
        const notes = data['subsonic-response']?.albumInfo?.notes
        return notes ? String(notes) : null
      }, 600000)
    } catch (error) {
      console.error('Get album notes failed:', error)
      return null
    }
  }

  /**
   * Obtener detalles de una playlist (nombre, portada, etc.)
   */
  async getPlaylist(playlistId: string): Promise<{ 
    name?: string
    coverArt?: string
    changed?: string
    owner?: string
  } | null> {
    if (!this.config) return null

    try {
      const config = this.config
      const key = `playlistDetails_${playlistId}`
      return this.withCache(key, async () => {
        const url = `${config.serverUrl}/rest/getPlaylist.view?${this.getAuthParams()}&id=${playlistId}`
        const response = await fetch(url)
        const data = await response.json()

        if (data['subsonic-response']?.status === 'ok') {
          const playlist = data['subsonic-response'].playlist
          return {
            name: playlist.name,
            coverArt: playlist.coverArt,
            changed: playlist.changed,
            owner: playlist.owner,
          }
        }
        return null
      }, 60000) // 1 minuto (las playlists pueden cambiar rápido)
    } catch (error) {
      console.error('Get playlist details failed:', error)
      return null
    }
  }

  /**
   * Obtener letras de una canción
   */
  async getLyrics(artist: string, title: string): Promise<string> {
    if (!this.config) return ''

    const cacheKey = `${artist.toLowerCase().trim()}-${title.toLowerCase().trim()}`
    if (this.lyricsCache.has(cacheKey)) {
      return this.lyricsCache.get(cacheKey)!
    }

    try {
      // Primero intentar con LRCLib API para obtener letras sincronizadas
      try {
        const lrclibUrl = `https://lrclib.net/api/get?artist_name=${encodeURIComponent(
          artist
        )}&track_name=${encodeURIComponent(title)}`
        const lrclibResponse = await fetch(lrclibUrl)

        if (lrclibResponse.ok) {
          const lrclibData = await lrclibResponse.json()

          // Si hay letras sincronizadas, usarlas
          if (lrclibData.syncedLyrics) {
            this.lyricsCache.set(cacheKey, lrclibData.syncedLyrics)
            return lrclibData.syncedLyrics
          }

          // Si no, usar las letras sin sincronizar
          if (lrclibData.plainLyrics) {
            this.lyricsCache.set(cacheKey, lrclibData.plainLyrics)
            return lrclibData.plainLyrics
          }
        }
      } catch (lrclibError) {
        console.error('LRCLib request failed, falling back to Navidrome:', lrclibError)
      }

      // Fallback: usar la API de Navidrome
      const url = `${this.config.serverUrl}/rest/getLyrics.view?${this.getAuthParams()}&artist=${encodeURIComponent(
        artist
      )}&title=${encodeURIComponent(title)}`
      const response = await fetch(url)

      const data = await response.json()

      if (data['subsonic-response']?.status === 'ok') {
        const lyrics = data['subsonic-response'].lyrics
        const lyricsText = lyrics?.value || ''
        this.lyricsCache.set(cacheKey, lyricsText)
        return lyricsText
      }

      // Si no se encuentra nada, cachear un string vacío para no volver a preguntar
      this.lyricsCache.set(cacheKey, '')
      return ''
    } catch (error) {
      console.error('Get lyrics failed:', error)
      return ''
    }
  }

  /**
   * Obtener canciones similares a una dada
   */
  async getSimilarSongs(artist: string, track: string): Promise<Song[]> {
    const apiKey = localStorage.getItem('lastfmApiKey') ?? undefined
    if (!this.config) {
      console.warn('Navidrome config not available. Cannot fetch similar songs.')
      return []
    }

    try {
      const rawSongs = await backendApi.getSimilarSongs({
        artist,
        track,
        navidromeConfig: this.config as unknown as Record<string, unknown>,
        apiKey,
      })

      return this.mapSongs(rawSongs ?? [])
    } catch (error) {
      console.error('Error fetching similar songs from backend:', error)
      return []
    }
  }

  /**
   * Obtener URL de streaming de una canción
   * @param songId - ID de la canción
   * @param offset - Offset en segundos para empezar la reproducción (opcional)
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  getStreamUrl(songId: string, _songPath?: string, offset?: number): string {
    if (!this.config) return ''

    // Always request MP3 transcoding for fast, efficient loading across all devices
    let url = `${this.config.serverUrl}/rest/stream.view?id=${encodeURIComponent(
      songId
    )}&${this.getAuthParams('binary')}&format=mp3`

    if (offset && offset > 0) {
      url += `&timeOffset=${Math.floor(offset)}`
    }

    return url
  }

  /**
   * Convertir canciones de API a formato interno
   */
  private mapSongs(songs: any[], albumId?: string, playlistId?: string): Song[] {
    return songs.map(song => ({
      id: song.id,
      title: song.title,
      artist: song.artist,
      album: song.album,
      albumId: albumId || song.albumId,
      playlistId: playlistId || song.playlistId,
      duration: song.duration,
      coverArt: song.coverArt,
      path: song.path,
      track: song.track,
      year: song.year,
      genre: song.genre,
      playCount: song.playCount,
      replayGain: song.replayGain || (song.trackGain ? { 
        trackGain: song.trackGain, 
        trackPeak: song.trackPeak, 
        albumGain: song.albumGain, 
        albumPeak: song.albumPeak 
      } : undefined),
    }))
  }

  /**
   * Convertir álbumes de API a formato interno
   */
  private mapAlbums(albums: any[]): Album[] {
    return albums.map(album => ({
      id: album.id,
      name: album.name,
      artist: album.artist,
      coverArt: album.coverArt,
      songCount: album.songCount || 0,
      duration: album.duration || 0,
      playCount: album.playCount,
      year: album.year,
      genre: album.genre,
      created: album.created,
      originalReleaseDate: album.originalReleaseDate,
      releaseDate: album.releaseDate,
    }))
  }

  /**
   * Obtener URL de imagen de portada
   * @param coverArtId - ID de la portada
   * @param size - Tamaño deseado (px)
   */
  getCoverUrl(coverArtId?: string, size?: number): string {
    if (!this.config || !coverArtId) return ''

    let url = `${this.config.serverUrl}/rest/getCoverArt.view?id=${coverArtId}&${this.getAuthParams(
      'binary'
    )}`
    
    if (size) {
      url += `&size=${size}`
    }
    
    return url
  }

  /**
   * Obtener URL del avatar del usuario
   */
  getAvatarUrl(): string {
    if (!this.config) {
      return ''
    }
    return `${this.config.serverUrl}/rest/getAvatar.view?${this.getAuthParams('binary')}`
  }

  /**
   * Enviar scrobble a Last.fm a través de Navidrome
   * @param songId - ID de la canción
   * @param time - Timestamp en segundos Unix (opcional, por defecto ahora)
   * @param submission - true para scrobble, false para "now playing" (por defecto true)
   */
  async scrobble(songId: string, time?: number, submission: boolean = true): Promise<boolean> {
    if (!this.config) return false

    try {
      // Construir parámetros de autenticación con formato JSON
      const authParamsStr = this.getAuthParams('json')
      const params = new URLSearchParams(authParamsStr)

      // Añadir parámetros específicos del scrobble
      params.append('id', songId)
      params.append('submission', submission.toString())

      // El parámetro time en Subsonic es en milisegundos (timestamp Unix * 1000)
      if (time !== undefined) {
        // Si time es menor que 10000000000, asumimos que está en segundos y lo convertimos a ms
        // Si es mayor, asumimos que ya está en milisegundos
        const timeMs = time < 10000000000 ? time * 1000 : time
        params.append('time', Math.floor(timeMs).toString())
      }

      const url = `${this.config.serverUrl}/rest/scrobble.view?${params.toString()}`
      const response = await fetch(url)

      // Verificar el content-type de la respuesta
      const contentType = response.headers.get('content-type') || ''

      let data
      if (contentType.includes('application/json')) {
        data = await response.json()
      } else {
        // Si es XML, intentar parsearlo o simplemente verificar el status
        const text = await response.text()
        // Si contiene '<subsonic-response status="ok"', es exitoso
        if (text.includes('status="ok"') || text.includes("status='ok'")) {
          console.log('[Scrobble] Scrobble enviado exitosamente (XML)')
          return true
        }
        console.error('[Scrobble] Error en respuesta XML:', text.substring(0, 200))
        return false
      }

      if (data['subsonic-response']?.status === 'ok') {
        console.log('[Scrobble] Scrobble enviado exitosamente')
        return true
      }

      console.error('[Scrobble] Error en respuesta:', data['subsonic-response']?.error)
      return false
    } catch (error) {
      console.error('[Scrobble] Error al enviar scrobble:', error)
      return false
    }
  }

  // Caché en memoria para getPlaylists (TTL: 1 hora)
  // Balance entre performance y sincronización con cambios del servidor
  // Las playlists cambian cada 6h en el servidor, pero no sabemos la hora exacta
  // Por eso usamos 1h como compromiso razonable
  // Para invalidar manualmente después de crear/editar, usar invalidatePlaylistsCache()
  private playlistsCache: { data: Playlist[]; timestamp: number } | null = null
  private playlistsCacheTTL = 3600000 // 1 hora (3600000 ms)
  private pendingPlaylistsRequest: Promise<Playlist[]> | null = null

  /**
   * Invalidar caché de playlists (llamar después de crear/eliminar playlists)
   */
  invalidatePlaylistsCache() {
    this.playlistsCache = null
    const keysToDelete: string[] = []
    for (const key of this.genericCache.keys()) {
      if (key.startsWith('playlistDetails_') || key.startsWith('playlistSongs_')) {
        keysToDelete.push(key)
      }
    }
    keysToDelete.forEach(k => this.genericCache.delete(k))
    console.debug('[NavidromeAPI] Caché de playlists invalidada')
  }

  /**
   * Verificar si una playlist específica ha cambiado comparando el timestamp
   * Útil para detectar cambios sin invalidar todo el caché
   */
  async hasPlaylistChanged(playlistId: string, lastKnownChanged?: string): Promise<boolean> {
    if (!lastKnownChanged) return true // Si no sabemos el último estado, asumimos que cambió
    
    try {
      // Hacer una petición ligera solo para esta playlist
      const currentPlaylist = await this.getPlaylist(playlistId)
      
      // Comparar el timestamp 'changed'
      if (currentPlaylist?.changed && currentPlaylist.changed !== lastKnownChanged) {
        console.debug('[NavidromeAPI] Playlist cambió:', playlistId, 'old:', lastKnownChanged, 'new:', currentPlaylist.changed)
        return true
      }
      
      return false
    } catch (error) {
      console.error('[NavidromeAPI] Error verificando cambios de playlist:', error)
      return false // En caso de error, asumimos que no cambió para no invalidar el caché innecesariamente
    }
  }

  /**
   * Obtener todos los playlists del usuario (con caché)
   */
  async getPlaylists(): Promise<Playlist[]> {
    if (!this.config) return []

    // Verificar caché
    const now = Date.now()
    if (this.playlistsCache && now - this.playlistsCache.timestamp < this.playlistsCacheTTL) {
      // Solo mostrar log en modo verbose (comentado para evitar spam)
      // console.debug('[NavidromeAPI] Usando caché de playlists')
      return this.playlistsCache.data
    }

    // Si hay una petición en curso, esperarla
    if (this.pendingPlaylistsRequest) {
      console.debug('[NavidromeAPI] Petición de playlists ya en curso, esperando...')
      return this.pendingPlaylistsRequest
    }

    // Crear nueva petición
    this.pendingPlaylistsRequest = (async () => {
      try {
        if (!this.config) return []
        const url = `${this.config.serverUrl}/rest/getPlaylists.view?${this.getAuthParams()}`
        const response = await fetch(url)

        const data = await response.json()

        if (data['subsonic-response']?.status === 'ok') {
          const playlists = data['subsonic-response'].playlists
          const result = this.mapPlaylists(playlists?.playlist || [])
          
          // Guardar en caché
          this.playlistsCache = { data: result, timestamp: Date.now() }
          console.debug('[NavidromeAPI] Playlists obtenidas y almacenadas en caché')
          
          return result
        }

        return []
      } catch (error) {
        console.error('Get playlists failed:', error)
        return []
      } finally {
        this.pendingPlaylistsRequest = null
      }
    })()

    return this.pendingPlaylistsRequest
  }

  /**
   * Crear una nueva playlist
   * @param name - Nombre de la playlist
   * @param songIds - IDs de canciones a añadir (opcional)
   * @returns ID de la playlist creada
   */
  async createPlaylist(name: string, songIds?: string[]): Promise<string | null> {
    if (!this.config) return null

    try {
      const params = new URLSearchParams(this.getAuthParams())
      params.append('name', name)
      
      // Si se proporcionan canciones, añadirlas
      if (songIds && songIds.length > 0) {
        songIds.forEach(id => params.append('songId', id))
      }

      const url = `${this.config.serverUrl}/rest/createPlaylist.view?${params.toString()}`
      const response = await fetch(url)
      const data = await response.json()

      if (data['subsonic-response']?.status === 'ok') {
        const playlist = data['subsonic-response'].playlist
        console.log('[NavidromeAPI] Playlist creada exitosamente:', playlist.id)
        
        // Invalidar caché para forzar recarga
        this.invalidatePlaylistsCache()
        
        return playlist.id
      }

      console.error('[NavidromeAPI] Error al crear playlist:', data['subsonic-response']?.error)
      return null
    } catch (error) {
      console.error('[NavidromeAPI] Error al crear playlist:', error)
      return null
    }
  }

  /**
   * Actualizar una playlist existente
   * @param playlistId - ID de la playlist
   * @param options - Opciones de actualización
   */
  async updatePlaylist(
    playlistId: string,
    options: {
      name?: string
      comment?: string
      public?: boolean
      songIdsToAdd?: string[]
      songIndexesToRemove?: number[]
    }
  ): Promise<boolean> {
    if (!this.config) return false

    try {
      const params = new URLSearchParams(this.getAuthParams())
      params.append('playlistId', playlistId)

      if (options.name !== undefined) params.append('name', options.name)
      if (options.comment !== undefined) params.append('comment', options.comment)
      if (options.public !== undefined) params.append('public', options.public.toString())

      // Añadir canciones
      if (options.songIdsToAdd && options.songIdsToAdd.length > 0) {
        options.songIdsToAdd.forEach(id => params.append('songIdToAdd', id))
      }

      // Remover canciones por índice
      if (options.songIndexesToRemove && options.songIndexesToRemove.length > 0) {
        options.songIndexesToRemove.forEach(index => params.append('songIndexToRemove', index.toString()))
      }

      const url = `${this.config.serverUrl}/rest/updatePlaylist.view?${params.toString()}`
      const response = await fetch(url)
      const data = await response.json()

      if (data['subsonic-response']?.status === 'ok') {
        console.log('[NavidromeAPI] Playlist actualizada exitosamente')
        
        // Invalidar caché
        this.invalidatePlaylistsCache()
        
        return true
      }

      console.error('[NavidromeAPI] Error al actualizar playlist:', data['subsonic-response']?.error)
      return false
    } catch (error) {
      console.error('[NavidromeAPI] Error al actualizar playlist:', error)
      return false
    }
  }

  /**
   * Añadir una canción a una playlist
   * @param playlistId - ID de la playlist
   * @param songId - ID de la canción a añadir
   */
  async addSongToPlaylist(playlistId: string, songId: string): Promise<boolean> {
    return this.updatePlaylist(playlistId, { songIdsToAdd: [songId] })
  }

  /**
   * Eliminar una playlist
   * @param playlistId - ID de la playlist a eliminar
   */
  async deletePlaylist(playlistId: string): Promise<boolean> {
    if (!this.config) return false

    try {
      const url = `${this.config.serverUrl}/rest/deletePlaylist.view?${this.getAuthParams()}&id=${playlistId}`
      const response = await fetch(url)
      const data = await response.json()

      if (data['subsonic-response']?.status === 'ok') {
        console.log('[NavidromeAPI] Playlist eliminada exitosamente')
        
        // Invalidar caché
        this.invalidatePlaylistsCache()
        
        return true
      }

      console.error('[NavidromeAPI] Error al eliminar playlist:', data['subsonic-response']?.error)
      return false
    } catch (error) {
      console.error('[NavidromeAPI] Error al eliminar playlist:', error)
      return false
    }
  }

  /**
   * Obtener álbumes con paginación (para lazy loading)
   */
  async getAlbums(offset: number = 0, size: number = 50): Promise<Album[]> {
    if (!this.config) return []

    try {
      const url = `${this.config.serverUrl}/rest/getAlbumList2.view?${this.getAuthParams()}&type=alphabeticalByName&size=${size}&offset=${offset}`
      const response = await fetch(url)

      const data = await response.json()

      if (data['subsonic-response']?.status === 'ok') {
        const albumList = data['subsonic-response'].albumList2
        return this.mapAlbums(albumList?.album || [])
      }

      return []
    } catch (error) {
      console.error('Get albums failed:', error)
      return []
    }
  }

  /**
   * Obtener álbumes de un género específico
   */
  async getAlbumsByGenre(genre: string, offset: number = 0, size: number = 50): Promise<Album[]> {
    if (!this.config) return []

    try {
      const url = `${
        this.config.serverUrl
      }/rest/getAlbumList2.view?${this.getAuthParams()}&type=byGenre&genre=${encodeURIComponent(
        genre
      )}&size=${size}&offset=${offset}`
      const response = await fetch(url)
      const data = await response.json()

      if (data['subsonic-response']?.status === 'ok') {
        const albumList = data['subsonic-response'].albumList2
        return this.mapAlbums(albumList?.album || [])
      }

      return []
    } catch (error) {
      console.error(`Get albums for genre "${genre}" failed:`, error)
      return []
    }
  }

  /**
   * Obtener todos los artistas
   */
  async getArtists(): Promise<Artist[]> {
    if (!this.config) return []

    try {
      const config = this.config
      return this.withCache('allArtists', async () => {
        const url = `${config.serverUrl}/rest/getArtists.view?${this.getAuthParams()}`
        const response = await fetch(url)
        const data = await response.json()

        if (data['subsonic-response']?.status === 'ok') {
          const artists = data['subsonic-response'].artists
          const allArtists: Artist[] = []

          if (artists.index) {
            artists.index.forEach((index: any) => {
              if (index.artist) {
                const indexArtists = Array.isArray(index.artist) ? index.artist : [index.artist]
                indexArtists.forEach((artist: any) => {
                  allArtists.push({
                    name: artist.name,
                    albumCount: artist.albumCount,
                    id: artist.id,
                  })
                })
              }
            })
          }

          // Pre-populate artistIdCache so getArtistIdByName() never needs a search3 call
          // for artists already returned here — cuts avatar load from 2 API calls to 1
          allArtists.forEach(artist => {
            const key = artist.name.trim().toLowerCase()
            if (!this.artistIdCache.has(key)) {
              this.artistIdCache.set(key, artist.id)
            }
          })

          return allArtists.sort((a, b) => a.name.localeCompare(b.name))
        }
        return []
      }, 600000) // 10 minutos para la lista completa de artistas
    } catch (error) {
      console.error('Get artists failed:', error)
      return []
    }
  }

  /**
   * Obtener el ID de un artista a partir de su nombre (usando búsqueda rápida y caché)
   */
  async getArtistIdByName(name: string): Promise<string | null> {
    if (!this.config || !name) return null
    const normalized = name.trim().toLowerCase()

    // Si ya lo tenemos en caché, devolverlo
    if (this.artistIdCache.has(normalized)) {
      return this.artistIdCache.get(normalized)!
    }

    // Si el caché está vacío (primera llamada en esta sesión), hacer una carga masiva con
    // getArtists() en lugar de N llamadas a search3. Esto convierte N peticiones → 1.
    if (this.artistIdCache.size === 0) {
      await this.getArtists() // side-effect: rellena artistIdCache para todos los artistas
      if (this.artistIdCache.has(normalized)) {
        return this.artistIdCache.get(normalized)!
      }
    }

    try {
      const auth = this.getAuthParams('json')
      const url = `${this.config.serverUrl}/rest/search3.view?${auth}&query=${encodeURIComponent(name)}&artistCount=1`
      const res = await fetch(url)
      if (!res.ok) return null

      const data = await res.json()
      const artistId = data?.['subsonic-response']?.searchResult3?.artist?.[0]?.id ?? null

      this.artistIdCache.set(normalized, artistId)
      return artistId
    } catch {
      return null
    }
  }

  /**
   * Obtener álbumes de un artista específico (solo álbumes donde es artista principal)
   */
  async getArtistAlbums(artistName: string): Promise<Album[]> {
    if (!this.config) return []

    try {
      const config = this.config
      const key = `artistAlbums_${artistName}`
      return this.withCache(key, async () => {
        // Usar search2 para encontrar álbumes del artista
        const url = `${config.serverUrl}/rest/search2.view?${this.getAuthParams()}&query=${encodeURIComponent(
          artistName
        )}&artistCount=0&albumCount=1000&songCount=0`
        const response = await fetch(url)
        const data = await response.json()

        if (data['subsonic-response']?.status === 'ok') {
          const results = data['subsonic-response'].searchResult2
          const allAlbums = results?.album || []
          const searchName = artistName.toLowerCase()

          // Filtrar álbumes donde el artista es el artista principal (no colaboración)
          const artistAlbums = allAlbums
            .filter((album: any) => {
              const albumArtist = album.artist.toLowerCase()
              return (
                albumArtist === searchName ||
                albumArtist.startsWith(searchName + ',') ||
                albumArtist.startsWith(searchName + ' &') ||
                albumArtist.startsWith(searchName + ' and') ||
                albumArtist.startsWith(searchName + ' ') ||
                albumArtist.startsWith(searchName + ' feat') ||
                albumArtist.startsWith(searchName + ' ft') ||
                albumArtist.startsWith(searchName + ' featuring')
              )
            })
            .map((album: any) => ({
              id: album.id,
              name: album.name,
              artist: album.artist,
              coverArt: album.coverArt,
              songCount: album.songCount || 0,
              duration: album.duration || 0,
              year: album.year,
              genre: album.genre,
            }))

          return artistAlbums.sort((a: Album, b: Album) => (b.year || 0) - (a.year || 0))
        }
        return []
      }, 300000) // 5 minutos
    } catch (error) {
      console.error('Get artist albums failed:', error)
      return []
    }
  }

  /**
   * Obtener información detallada de un artista (biografía, similares, etc.)
   */
  async getArtistInfo(artistId: string): Promise<ArtistInfo | null> {
    if (!this.config) return null

    try {
      const config = this.config
      const key = `artistInfo_${artistId}`
      return this.withCache(key, async () => {
        const url = `${config.serverUrl}/rest/getArtistInfo2.view?${this.getAuthParams()}&id=${artistId}`
        const response = await fetch(url)
        const data = await response.json()

        if (data['subsonic-response']?.status === 'ok') {
          const info = data['subsonic-response'].artistInfo2
          return {
            biography: info.biography || '',
            lastFmUrl: info.lastFmUrl || '',
            smallImageUrl: info.smallImageUrl,
            mediumImageUrl: info.mediumImageUrl,
            largeImageUrl: info.largeImageUrl,
            similarArtists: info.similarArtist ? (Array.isArray(info.similarArtist) ? info.similarArtist : [info.similarArtist]) : [],
          }
        }
        return null
      }, 3600000) // 1 hora (la info del artista no suele cambiar)
    } catch (error) {
      console.error(`Get artist info for ID ${artistId} failed:`, error)
      return null
    }
  }

  /**
   * Obtener álbumes donde el artista aparece como colaboración
   */
  async getArtistCollaborations(artistName: string): Promise<Album[]> {
    if (!this.config) return []

    try {
      const config = this.config
      const key = `artistCollabs_${artistName}`
      return this.withCache(key, async () => {
        const url = `${config.serverUrl}/rest/search2.view?${this.getAuthParams()}&query=${encodeURIComponent(
          artistName
        )}&artistCount=0&albumCount=1000&songCount=0`
        const response = await fetch(url)
        const data = await response.json()

        if (data['subsonic-response']?.status === 'ok') {
          const results = data['subsonic-response'].searchResult2
          const allAlbums = results?.album || []
          const searchName = artistName.toLowerCase()

          // Filtrar álbumes donde el artista aparece como colaboración
          const collaborations = allAlbums
            .filter((album: any) => {
              const albumArtist = album.artist.toLowerCase()
              const isMain = albumArtist === searchName ||
                albumArtist.startsWith(searchName + ',') ||
                albumArtist.startsWith(searchName + ' &') ||
                albumArtist.startsWith(searchName + ' and') ||
                albumArtist.startsWith(searchName + ' ') ||
                albumArtist.startsWith(searchName + ' feat') ||
                albumArtist.startsWith(searchName + ' ft') ||
                albumArtist.startsWith(searchName + ' featuring')
              
              return !isMain && albumArtist.includes(searchName)
            })
            .map((album: any) => ({
              id: album.id,
              name: album.name,
              artist: album.artist,
              coverArt: album.coverArt,
              songCount: album.songCount || 0,
              duration: album.duration || 0,
              year: album.year,
              genre: album.genre,
            }))

          return collaborations.sort((a: Album, b: Album) => (b.year || 0) - (a.year || 0))
        }
        return []
      }, 300000) // 5 minutos
    } catch (error) {
      console.error('Get artist collaborations failed:', error)
      return []
    }
  }

  /**
   * Obtener todos los géneros musicales
   */
  async getGenres(): Promise<string[]> {
    if (!this.config) return []
    try {
      const allGenres = new Set<string>()
      let offset = 0
      const size = 100 // Número de álbumes a pedir en cada llamada
      let hasMore = true

      while (hasMore) {
        const albums = await this.getAlbums(offset, size)
        if (albums.length > 0) {
          albums.forEach(album => {
            if (album.genre) {
              album.genre.split(',').forEach(g => {
                const trimmedGenre = g.trim()
                if (trimmedGenre) {
                  allGenres.add(trimmedGenre)
                }
              })
            }
          })
          offset += size
        } else {
          hasMore = false
        }
      }

      return Array.from(allGenres).sort((a, b) => a.localeCompare(b))
    } catch (error) {
      console.error('Get genres failed:', error)
      return []
    }
  }

  /**
   * Obtener detalles de una canción
   */
  async getSong(songId: string): Promise<Song | null> {
    if (!this.config) return null

    try {
      const url = `${this.config.serverUrl}/rest/getSong.view?${this.getAuthParams()}&id=${songId}`
      const response = await fetch(url)
      const data = await response.json()

      if (data['subsonic-response']?.status === 'ok') {
        const songData = data['subsonic-response'].song
        // getSong devuelve un solo objeto, pero mapSongs espera un array
        const mappedSong = this.mapSongs([songData])
        return mappedSong[0] || null
      }

      return null
    } catch (error) {
      console.error('Get song failed:', error)
      return null
    }
  }

  /**
   * Obtener canciones de un artista (para Top canciones)
   */
  async getArtistSongs(artistName: string, limit: number = 10): Promise<Song[]> {
    if (!this.config) return []

    try {
      const config = this.config
      const key = `artistSongs_${artistName}_${limit}`
      return this.withCache(key, async () => {
        // Obtener canciones con getTopSongs (Last.fm) y también con fallback para incluir colaboraciones
        const [topSongsResult, fallbackResult] = await Promise.allSettled([
          // Intentar con getTopSongs
          (async () => {
            const url = `${config.serverUrl}/rest/getTopSongs.view?${this.getAuthParams()}&artist=${encodeURIComponent(
              artistName
            )}&count=${limit}`
            const response = await fetch(url)
            const data = await response.json()

            if (data['subsonic-response']?.status === 'ok') {
              const topSongs = data['subsonic-response'].topSongs?.song || []
              const songsArray = Array.isArray(topSongs) ? topSongs : [topSongs]
              return this.mapSongs(songsArray)
            }
            return []
          })(),
          // Obtener también con fallback para incluir colaboraciones
          this.getArtistSongsFallback(artistName, limit * 2),
        ])

        const topSongs = topSongsResult.status === 'fulfilled' ? topSongsResult.value : []
        const fallbackSongs = fallbackResult.status === 'fulfilled' ? fallbackResult.value : []

        // Combinar y deduplicar por ID
        const combinedSongs: Song[] = []
        const seenIds = new Set<string>()

        // Primero agregar topSongs de Last.fm (más relevantes)
        for (const song of topSongs) {
          if (!seenIds.has(song.id)) {
            combinedSongs.push(song)
            seenIds.add(song.id)
          }
        }

        // Luego agregar canciones del fallback que incluyen colaboraciones
        for (const song of fallbackSongs) {
          if (!seenIds.has(song.id)) {
            combinedSongs.push(song)
            seenIds.add(song.id)
          }
        }

        // Ordenar por playCount y limitar
        return combinedSongs.sort((a, b) => (b.playCount || 0) - (a.playCount || 0)).slice(0, limit)
      }, 300000) // 5 minutos
    } catch (error) {
      console.error('Get top songs failed:', error)
      return this.getArtistSongsFallback(artistName, limit)
    }
  }

  /**
   * Fallback para obtener canciones del artista cuando getTopSongs no está disponible
   */
  private async getArtistSongsFallback(artistName: string, limit: number): Promise<Song[]> {
    if (!this.config) return []

    try {
      // Primero obtener el ID del artista
      const artistUrl = `${this.config.serverUrl}/rest/getArtist.view?${this.getAuthParams()}&name=${encodeURIComponent(
        artistName
      )}`
      const artistResponse = await fetch(artistUrl)
      const artistData = await artistResponse.json()

      let allSongs: any[] = []

      if (artistData['subsonic-response']?.status === 'ok') {
        const artist = artistData['subsonic-response'].artist

        // Obtener canciones de todos los álbumes del artista
        if (artist.album) {
          const albumPromises = Array.isArray(artist.album)
            ? artist.album.map((album: any) => this.getAlbumSongs(album.id))
            : [this.getAlbumSongs(artist.album.id)]

          const albumSongsArrays = await Promise.all(albumPromises)
          allSongs = albumSongsArrays.flat()
        }
      }

      // Si no encontramos canciones con getArtist, usar search2 como fallback
      if (allSongs.length === 0) {
        const url = `${
          this.config.serverUrl
        }/rest/search2.view?${this.getAuthParams()}&query=${encodeURIComponent(
          artistName
        )}&artistCount=0&albumCount=0&songCount=${limit * 3}`
        const response = await fetch(url)
        const data = await response.json()

        if (data['subsonic-response']?.status === 'ok') {
          const results = data['subsonic-response'].searchResult2
          allSongs = results?.song || []
        }
      }

      // Importar la función helper
      const { isArtistInString } = await import('../utils/artistUtils')

      // Filtrar canciones del artista específico y ordenar por playCount
      const artistSongs = allSongs
        .filter((song: any) => isArtistInString(artistName, song.artist))
        .sort((a: Song, b: Song) => (b.playCount || 0) - (a.playCount || 0))
        .slice(0, limit)

      return artistSongs
    } catch (error) {
      console.error('Get artist songs fallback failed:', error)
      return []
    }
  }

  /**
   * Obtener playlists que contienen canciones de un artista
   */
  async getPlaylistsByArtist(artistName: string): Promise<Playlist[]> {
    if (!this.config) return []

    try {
      const allPlaylists = await this.getPlaylists()

      // Pre-filter: skip smart playlists and daily mixes entirely —
      // no need to fetch their songs, and they should not appear on artist pages
      const candidates = allPlaylists.filter(p => {
        const nameLower = p.name?.toLowerCase() || ''
        const comment = p.comment || ''
        return (
          !comment.includes('Smart Playlist') &&
          !nameLower.includes('mix diario') &&
          !comment.toLowerCase().includes('mix diario')
        )
      })

      // Parallelise all song-checks instead of sequential await in for-loop
      const artistLower = artistName.toLowerCase()
      const results = await Promise.all(
        candidates.map(async playlist => {
          const songs = await this.getPlaylistSongs(playlist.id)
          const match = songs.some(song => {
            const sa = song.artist.toLowerCase()
            return (
              sa === artistLower ||
              sa.includes(artistLower + ',') ||
              sa.includes(', ' + artistLower) ||
              sa.includes(artistLower + ' &') ||
              sa.includes('& ' + artistLower) ||
              sa.includes(artistLower + ' and') ||
              sa.includes('and ' + artistLower) ||
              (sa.includes(artistLower) &&
                (sa.startsWith(artistLower + ' ') || sa.endsWith(' ' + artistLower)))
            )
          })
          return match ? playlist : null
        })
      )

      return results.filter((p): p is Playlist => p !== null)
    } catch (error) {
      console.error('Get playlists by artist failed:', error)
      return []
    }
  }

  /**
   * Convertir playlists de API a formato interno
   */
  private mapPlaylists(playlists: any[]): Playlist[] {
    const mapped = playlists.map(playlist => ({
      id: playlist.id,
      name: playlist.name,
      comment: playlist.comment,
      songCount: playlist.songCount || 0,
      duration: playlist.duration || 0,
      public: playlist.public || false,
      created: playlist.created,
      changed: playlist.changed,
      owner: playlist.owner,
      coverArt: playlist.coverArt,
      path: playlist.path, // Incluir path para detectar smart playlists
    }))

    // Log temporal para debugging (solo primera playlist)
    if (import.meta.env.DEV && mapped.length > 0) {
      const sample = mapped[0]
      console.log('[mapPlaylists] DEBUG - Primera playlist mapeada:', {
        id: sample.id,
        name: sample.name,
        created: sample.created,
        changed: sample.changed,
        hasChanged: !!sample.changed,
        path: sample.path,
        isSmartPlaylist: isSmartPlaylist(sample)
      })
    }

    return mapped
  }

  /**
   * Guardar configuración en localStorage
   */
  private saveConfig(config: NavidromeConfig): void {
    localStorage.setItem('navidromeConfig', JSON.stringify(config))
  }

  /**
   * Cargar configuración de localStorage
   */
  private loadConfig(): void {
    try {
      const saved = localStorage.getItem('navidromeConfig')
      if (saved) {
        this.config = JSON.parse(saved)
      }
    } catch (error) {
      console.error('Error loading config:', error)
    }
  }

  /**
   * Obtener configuración actual
   */
  getConfig(): NavidromeConfig | null {
    return this.config
  }



  /**
   * Obtener imagen de artista desde Navidrome exclusivamente
   */
  async getArtistImage(artistName: string): Promise<string | null> {
    try {
      if (!this.config) return null
      
      const id = await this.getArtistIdByName(artistName)
      if (!id) return null

      const auth = this.getAuthParams('json')
      const url = `${this.config.serverUrl}/rest/getArtistInfo2.view?${auth}&id=${id}`
      const res = await fetch(url)
      if (!res.ok) return null
      
      const data = await res.json()
      const info = data?.['subsonic-response']?.artistInfo2
      
      // Navidrome internamente gestiona Last.fm / Spotify de forma transparente 
      // Las devuelve redimensionadas o del servicio con mejor hit rate
      return info?.largeImageUrl ?? info?.mediumImageUrl ?? info?.smallImageUrl ?? null
    } catch (error) {
      console.error('💥 Error al obtener imagen del artista local desde Navidrome:', error)
      return null
    }
  }

  /**
   * Desconectar y limpiar configuración
   */
  disconnect(): void {
    this.config = null
    localStorage.removeItem('navidromeConfig')

  }
}

// Exportar instancia singleton
export const navidromeApi = new NavidromeAPI()
