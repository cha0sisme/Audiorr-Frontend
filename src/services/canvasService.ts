import { backendApi } from './backendApi'

export async function fetchSpotifyCanvas(trackId: string): Promise<string | null> {
  try {
    const response = await backendApi.fetchSpotifyCanvas(trackId)
    const canvases = response?.canvasesList ?? []
    return canvases.length > 0 ? canvases[0].canvasUrl ?? null : null
  } catch (error) {
    console.error('[Canvas] Error obteniendo Canvas desde el backend:', error)
    return null
  }
}

export async function getCanvasFromBackend(songId: string): Promise<string | null> {
  try {
    const entry = await backendApi.getCanvasBySongId(songId)
    return entry?.canvasUrl ?? null
  } catch (error) {
    console.error('[Canvas] Error fetching canvas from backend:', error)
    return null
  }
}

export async function saveCanvasToBackend(params: {
  songId: string
  title: string
  artist: string
  album?: string
  spotifyTrackId?: string | null
  canvasUrl?: string | null
}) {
  try {
    await backendApi.saveCanvas(params)
  } catch (error) {
    console.error('[Canvas] Error saving canvas to backend:', error)
    throw error
  }
}
