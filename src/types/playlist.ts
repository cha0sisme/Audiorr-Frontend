export interface PinnedPlaylist {
  id: string
  name: string
  owner?: string
  songCount?: number
  duration?: number
  created?: string
  changed?: string
  coverArt?: string
  comment?: string
}

export interface PinnedPlaylistsContextValue {
  pinnedPlaylists: PinnedPlaylist[]
  pinPlaylist: (playlist: PinnedPlaylist) => void
  unpinPlaylist: (playlistId: string) => void
  togglePinnedPlaylist: (playlist: PinnedPlaylist) => void
  isPinned: (playlistId: string) => boolean
  updatePinnedPlaylist: (playlist: PinnedPlaylist) => void
}
