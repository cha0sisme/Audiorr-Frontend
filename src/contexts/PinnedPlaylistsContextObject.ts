import { createContext } from 'react'
import type { PinnedPlaylistsContextValue } from '../types/playlist'

export const PinnedPlaylistsContext = createContext<PinnedPlaylistsContextValue | undefined>(undefined)
