/**
 * Servicio para comunicarse con Music-API
 * Encapsula las llamadas a http://192.168.1.43:8014/
 * que permite modificar la DB de Navidrome directamente.
 */

const MUSIC_API_BASE = 'http://192.168.1.43:8014'

export type SmartTagField = 'mood' | 'genre' | 'language'

export interface MusicApiResponse {
  success: boolean
  message?: string
  error?: string
}

export const musicApiService = {
  /**
   * Actualiza el play count de una canción
   * Endpoint: POST /api/update_play_count
   */
  async updatePlayCount(songId: string, playCount: number): Promise<MusicApiResponse> {
    try {
      const response = await fetch(`${MUSIC_API_BASE}/api/update_play_count`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ song_id: songId, play_count: playCount }),
      })
      const data: MusicApiResponse = await response.json()
      return data
    } catch (error) {
      console.error('[musicApiService] Error al actualizar play count:', error)
      return { success: false, error: 'Error de red al conectar con Music-API.' }
    }
  },

  /**
   * Actualiza un tag (mood, genre, language) de una canción
   * Endpoint: POST /api/update_tag
   */
  async updateTag(
    songId: string,
    tag: SmartTagField,
    value: string
  ): Promise<MusicApiResponse> {
    try {
      const response = await fetch(`${MUSIC_API_BASE}/api/update_tag`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ song_id: songId, tag, value }),
      })
      const data: MusicApiResponse = await response.json()
      return data
    } catch (error) {
      console.error('[musicApiService] Error al actualizar tag:', error)
      return { success: false, error: 'Error de red al conectar con Music-API.' }
    }
  },

  /**
   * Obtiene el play_count actual y los tags (mood, genre, language) de una canción
   * Endpoint: GET /api/song_tags/<song_id>
   */
  async getSongData(songId: string): Promise<{
    success: boolean
    play_count?: number
    tags?: { mood: string; genre: string; language: string }
    error?: string
  }> {
    try {
      const response = await fetch(`${MUSIC_API_BASE}/api/song_tags/${encodeURIComponent(songId)}`)
      return await response.json()
    } catch (error) {
      console.error('[musicApiService] Error al obtener datos de canción:', error)
      return { success: false, error: 'Error de red al conectar con Music-API.' }
    }
  },
}
