import { useContext } from 'react'
import { PinnedPlaylistsContext } from '../contexts/PinnedPlaylistsContextObject'
import type { PinnedPlaylistsContextValue } from '../types/playlist'

export function usePinnedPlaylists(): PinnedPlaylistsContextValue {
  const context = useContext(PinnedPlaylistsContext)
  if (!context) {
    throw new Error('usePinnedPlaylists debe usarse dentro de un PinnedPlaylistsProvider')
  }
  return context
}
