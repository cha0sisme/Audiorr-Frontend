import { navidromeApi } from './navidromeApi'
import { API_BASE_URL } from './backendApi'

export type PlaylistCoverVariant = 'classic' | 'headline' | 'graphic' | 'artist-gradient'
export type GraphicStyle = 'confetti' | 'diagonals'

export interface PaletteColors {
  primary: string
  secondary: string
  accent: string
}

export interface PlaylistLike {
  id: string
  name: string
  comment?: string
  songCount?: number
  duration?: number
  created?: string
  changed?: string
  coverArt?: string
}

const isDev = import.meta.env.DEV
const apiUrl = isDev ? '' : API_BASE_URL

export function resolveChangeKey(playlist: PlaylistLike): string {
  const baseId = playlist.id
  const songCount =
    typeof playlist.songCount === 'number' && Number.isFinite(playlist.songCount) ? playlist.songCount : ''
  
  const rawTimestamp = playlist.changed || playlist.created || ''
  // Estabilizar timestamp: quitar milisegundos para evitar desajustes entre backend y Navidrome
  // Ej: "2026-03-05T03:00:00.513Z" -> "2026-03-05T03:00:00"
  const timestamp = rawTimestamp.split('.')[0].split('+')[0].replace('Z', '')

  // Eliminamos 'duration' por completo de la firma porque Navidrome a veces 
  // fluctúa o redondea distinto según el endpoint, causando invalidaciones espúreas.
  // 'songCount' y el timestamp 'changed' son matemáticamente suficientes.
  return `${baseId}|tracks:${songCount}|timestamp:${timestamp}`
}

export function pickVariantFromName(name?: string, comment?: string): PlaylistCoverVariant | null {
  if (comment) {
    const coverMatch = comment.match(/\[Cover:(classic|headline|graphic|artist-gradient)\]/i)
    if (coverMatch) {
      return coverMatch[1].toLowerCase() as PlaylistCoverVariant
    }
  }

  if (comment && comment.includes('Spotify Synced')) return 'artist-gradient'
  if (comment && comment.includes('Mix Diario')) return 'classic'
  if (name && name.toLowerCase().includes('mix diario')) return 'classic'
  
  if (comment && comment.includes('[Editorial]')) {
    if (!name) return 'graphic'
    const normalized = name.trim().toLowerCase()
    if (normalized.startsWith('tu mix') || normalized.startsWith('this is')) {
      return 'classic'
    }
    return 'graphic'
  }
  
  return null
}

export function generatePlaylistCoverUrl(
  playlist: PlaylistLike, 
  variant: PlaylistCoverVariant = 'graphic',
  cacheKey: string,
  width?: number,
  height?: number
): string | null {
  const navidromeConfig = navidromeApi.getConfig()
  if (!navidromeConfig) return null

  const params = new URLSearchParams()
  params.append('playlistId', playlist.id)
  
  if (navidromeConfig.serverUrl) params.append('serverUrl', navidromeConfig.serverUrl)
  if (navidromeConfig.username) params.append('username', navidromeConfig.username)
  if (navidromeConfig.token) params.append('token', navidromeConfig.token)
  
  // @ts-expect-error - Some dynamic configs might inject salt
  if (navidromeConfig.salt) params.append('salt', navidromeConfig.salt)
  
  params.append('variant', variant)
  params.append('changeKey', cacheKey)

  if (width) params.append('width', width.toString())
  if (height) params.append('height', height.toString())

  return `${apiUrl}/api/playlists/cover?${params.toString()}`
}

export const generatedCoverService = {
  resolveChangeKey,
  pickVariantFromName,
  generatePlaylistCoverUrl,
}
