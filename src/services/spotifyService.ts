import { backendApi } from './backendApi'

export async function searchSpotifyTrackId(
  title: string,
  artist: string,
  album?: string
): Promise<string | null> {
  try {
    const response = await backendApi.searchSpotifyTrack(title, artist, album)
    return response?.trackId ?? null
  } catch (error) {
    console.error('[Canvas] Error buscando TrackID de Spotify:', error)
    return null
  }
}
