import { useState, useEffect, useMemo, useCallback, memo } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { navidromeApi, Playlist } from '../services/navidromeApi'
import { backendApi, SyncedPlaylist } from '../services/backendApi'

import { usePlayerState } from '../contexts/PlayerContext'
import EqualizerIcon from './EqualizerIcon'
import Spinner from './Spinner'
import { usePinnedPlaylists } from '../hooks/usePinnedPlaylists'
import { PinFilledIcon, PinOutlinedIcon } from './icons/PinIcons'
import { PlaylistCover } from './PlaylistCover'
import CreatePlaylistModal from './CreatePlaylistModal'
import { PlusIcon } from '@heroicons/react/24/solid'
import DailyMixSection from './DailyMixSection'
import HorizontalScrollSection from './HorizontalScrollSection'
import { useBackendAvailable } from '../contexts/BackendAvailableContext'

type PlaylistSection = {
  id: string
  title: string
  type: 'fixed_daily' | 'fixed_user' | 'fixed_smart' | 'dynamic'
  playlists?: string[]
}

const DEFAULT_LAYOUT: PlaylistSection[] = [
  { id: 'daily-mixes', title: 'Tus mixes diarios', type: 'fixed_daily' },
  { id: 'smart-playlists', title: 'Hecho especialmente para ti', type: 'fixed_smart' },
  { id: 'my-playlists', title: 'Mis playlists', type: 'fixed_user' },
]

// ─── Matched Tracks Modal ────────────────────────────────────────────────────
// (moved to AdminPage.tsx)

// ─── Playlist Item ────────────────────────────────────────────────────────────

export const PlaylistItem = memo(
  ({
    playlist,
    isPlayingFromThisPlaylist,
    isPinned,
    onTogglePin,
    isSpotifySynced,
  }: {
    playlist: Playlist
    isPlayingFromThisPlaylist: boolean
    isPinned: boolean
    onTogglePin: (playlist: Playlist) => void
    isSpotifySynced?: boolean
  }) => {
    // Si está sincronizada, forzamos el comentario para que el hook de portada
    // sepa que debe usar el estilo 'artist-gradient'
    const effectivePlaylist = useMemo(() => {
        if (isSpotifySynced) {
            return { ...playlist, comment: 'Spotify Synced ' + (playlist.comment || '') }
        }
        return playlist
    }, [playlist, isSpotifySynced])

    return (
      <Link 
        to={`/playlists/${playlist.id}`} 
        state={{ playlist: effectivePlaylist }}
        className="group relative block"
      >
        <div className="relative active:scale-95 transition-transform duration-150">
          <PlaylistCover
            playlistId={playlist.id}
            name={playlist.name}
            className="w-full h-full"
            rounded={true}
            fallbackUrl={navidromeApi.getCoverUrl(playlist.coverArt)}
          />
          <div className="absolute top-2 right-2 z-20 flex items-center gap-2">
            {isSpotifySynced && (
               <div className="bg-[#1DB954] text-white p-1 rounded-full shadow-lg" title="Sincronizado con Spotify">
                 <svg className="w-3.5 h-3.5" fill="currentColor" viewBox="0 0 24 24">
                   <path d="M12 0C5.373 0 0 5.373 0 12s5.373 12 12 12 12-5.373 12-12S18.627 0 12 0zm5.492 17.31c-.218.358-.684.47-1.042.252-2.857-1.745-6.45-2.14-10.684-1.173-.41.094-.823-.16-.917-.57-.094-.41.16-.823.57-.917 4.623-1.057 8.583-.61 11.782 1.345.358.218.47.684.252 1.042zm1.464-3.26c-.275.446-.86.592-1.306.317-3.27-2.01-8.254-2.593-12.122-1.417-.5.152-1.026-.134-1.178-.633-.152-.5.134-1.026.633-1.178 4.417-1.34 9.907-.69 13.655 1.614.447.275.592.86.317 1.306zm.126-3.414C15.345 8.35 9.176 8.145 5.62 9.223c-.563.17-1.16-.148-1.332-.71-.17-.563.15-1.16.712-1.332 4.102-1.246 10.92-1.008 15.226 1.55.51.3.67.954.37 1.464-.3.51-.954.67-1.464.37z" />
                 </svg>
               </div>
            )}

            {isPlayingFromThisPlaylist && (
              <div className="w-8 h-8 bg-white/20 dark:bg-black/40 rounded-full shadow-xl border border-white/40 dark:border-white/10 backdrop-blur-md flex items-center justify-center">
                <EqualizerIcon isPlaying={true} />
              </div>
            )}
          </div>
        </div>
        <div className="mt-3 flex items-start justify-between gap-2">
          <div className="min-w-0">
            <p className="font-semibold text-sm tracking-normal truncate text-gray-900 dark:text-white transition-colors group-hover:text-blue-600 dark:group-hover:text-blue-400">
              {playlist.name.replace('[Spotify] ', '')}
            </p>
            <p className="text-xs text-gray-500 dark:text-gray-400 truncate">{playlist.songCount} canciones</p>
          </div>
          <div className="opacity-0 group-hover:opacity-100 transition-opacity duration-150">
            <button
              onClick={e => {
                e.preventDefault()
                e.stopPropagation()
                onTogglePin(playlist)
              }}
              className="rounded-full bg-gray-100 dark:bg-gray-800 p-1.5 text-gray-500 hover:text-gray-900 dark:hover:text-white"
              aria-label={isPinned ? `Desanclar ${playlist.name}` : `Anclar ${playlist.name}`}
            >
              {isPinned ? <PinFilledIcon className="w-3.5 h-3.5" /> : <PinOutlinedIcon className="w-3.5 h-3.5" />}
            </button>
          </div>
        </div>
      </Link>
    )
  }
)


// ─── Main Page ────────────────────────────────────────────────────────────────

export default function PlaylistsPage() {
  const [playlists, setPlaylists] = useState<Playlist[]>(() => {
    try { const cached = sessionStorage.getItem('audiorr:playlists'); return cached ? JSON.parse(cached) : []; } catch { return []; }
  })
  const [syncs, setSyncs] = useState<SyncedPlaylist[]>(() => {
    try { const cached = sessionStorage.getItem('audiorr:syncs'); return cached ? JSON.parse(cached) : []; } catch { return []; }
  })
  const [sections, setSections] = useState<PlaylistSection[]>(() => {
    try { const cached = sessionStorage.getItem('audiorr:sections'); return cached ? JSON.parse(cached) : []; } catch { return []; }
  })
  const [loading, setLoading] = useState(() => {
    try { return !sessionStorage.getItem('audiorr:playlists'); } catch { return true; }
  })
  const [isCreateModalOpen, setIsCreateModalOpen] = useState(false)
  const playerState = usePlayerState()

  const { pinnedPlaylists, togglePinnedPlaylist, isPinned } = usePinnedPlaylists()
  const navidromeConfig = navidromeApi.getConfig()
  const navigate = useNavigate()
  const backendAvailable = useBackendAvailable()

  const isPlaying = playerState.isPlaying
  const currentSource = playerState.currentSource

  const fetchData = useCallback(async () => {
    try {
      const fetchedPlaylists = await navidromeApi.getPlaylists()
      const [fetchedSyncs, fetchedSections] = backendAvailable
        ? await Promise.all([
            backendApi.listSyncs().catch(() => [] as SyncedPlaylist[]),
            backendApi.getGlobalSetting<PlaylistSection[]>('homepage_layout').catch(() => null)
          ])
        : [[] as SyncedPlaylist[], null]
      setPlaylists(fetchedPlaylists)
      setSyncs(fetchedSyncs)
      let newSections = fetchedSections && fetchedSections.length > 0 ? fetchedSections : DEFAULT_LAYOUT
      // Migrar título antiguo de fixed_smart al nuevo nombre
      newSections = newSections.map(s =>
        s.type === 'fixed_smart' && s.title === 'Mis Smart Playlists'
          ? { ...s, title: 'Hecho especialmente para ti' }
          : s
      )
      // Si el layout guardado no tiene fixed_smart, insertarlo después de fixed_daily
      if (!newSections.some(s => s.type === 'fixed_smart')) {
        const dailyIdx = newSections.findIndex(s => s.type === 'fixed_daily')
        const insert = { id: 'smart-playlists', title: 'Hecho especialmente para ti', type: 'fixed_smart' as const }
        newSections = dailyIdx >= 0
          ? [...newSections.slice(0, dailyIdx + 1), insert, ...newSections.slice(dailyIdx + 1)]
          : [insert, ...newSections]
      }
      setSections(newSections)
      try {
        sessionStorage.setItem('audiorr:playlists', JSON.stringify(fetchedPlaylists))
        sessionStorage.setItem('audiorr:syncs', JSON.stringify(fetchedSyncs))
        sessionStorage.setItem('audiorr:sections', JSON.stringify(newSections))
      } catch {
        // ignorar errores de sessionStorage
      }
    } catch (error) {
      console.error('Failed to fetch playlists/syncs', error)
    } finally {
      setLoading(false)
    }
  }, [backendAvailable])

  useEffect(() => {
    fetchData()
    const intervalId = setInterval(() => { fetchData() }, 2 * 60 * 1000)
    return () => clearInterval(intervalId)
  }, [fetchData])

  const sortedPlaylists = useMemo(() => {
    let sorted = [...playlists]
    const pinnedIds = new Set(pinnedPlaylists.map(item => item.id))

    if (pinnedIds.size > 0) {
      sorted.sort((a, b) => {
        const aPinned = pinnedIds.has(a.id)
        const bPinned = pinnedIds.has(b.id)
        if (aPinned === bPinned) return 0
        return aPinned ? -1 : 1
      })
    }

    if (currentSource && currentSource.startsWith('playlist:')) {
      const activePlaylistId = currentSource.split(':')[1]
      const activePlaylist = sorted.find(p => p.id === activePlaylistId)
      if (activePlaylist) {
        sorted = [activePlaylist, ...sorted.filter(p => p.id !== activePlaylistId)]
      }
    }
    return sorted
  }, [playlists, currentSource, pinnedPlaylists])

  const { myPlaylists, smartPlaylists, playlistMap } = useMemo(() => {
    const my: Playlist[] = []
    const smart: Playlist[] = []
    const map = new Map<string, Playlist>()

    const currentUsername = navidromeConfig?.username

    for (const playlist of sortedPlaylists) {
      map.set(playlist.id, playlist)
      const normalizedName = playlist.name?.trim().toLowerCase() ?? ''

      const isSpotify = normalizedName.startsWith('[spotify] ') || playlist.comment?.includes('Spotify Synced') || syncs.some(s => s.navidromeId === playlist.id)
      const isSmartPlaylist = playlist.comment?.includes('Smart Playlist')

      if (normalizedName.startsWith('mix diario')) {
         // Omitirlas ya que se muestran en su propia sección fija
      } else if (isSmartPlaylist) {
        smart.push(playlist)
      } else if (
        playlist.owner === currentUsername &&
        !playlist.comment?.includes('[Editorial]') &&
        !isSpotify
      ) {
        my.push(playlist)
      }
    }

    return { myPlaylists: my, smartPlaylists: smart, playlistMap: map }
  }, [sortedPlaylists, navidromeConfig?.username, syncs])

  const handleTogglePinned = useCallback(
    (playlist: Playlist) => {
      togglePinnedPlaylist({
        id: playlist.id,
        name: playlist.name,
        owner: playlist.owner,
        songCount: playlist.songCount,
        duration: playlist.duration,
        created: playlist.created,
        changed: playlist.changed,
        coverArt: playlist.coverArt,
        comment: playlist.comment,
      })
    },
    [togglePinnedPlaylist],
  )

  const handleCreatePlaylist = useCallback(async (name: string, description?: string) => {
    try {
      const playlistId = await navidromeApi.createPlaylist(name)
      
      if (!playlistId) {
        throw new Error('No se pudo crear la playlist')
      }

      if (description) {
        await navidromeApi.updatePlaylist(playlistId, { comment: description })
      }

      fetchData()
      navigate(`/playlists/${playlistId}`)
    } catch (error) {
      console.error('[PlaylistsPage] Error al crear playlist:', error)
      throw error
    }
  }, [navigate, fetchData])

  if (loading) {
    return (
      <div className="flex justify-center items-center h-64">
        <Spinner size="lg" />
      </div>
    )
  }

  return (
    <div className="space-y-10 optimize-scroll">
      <div className="flex items-center justify-between mb-6">
        <h1 className="text-3xl md:text-4xl font-bold text-gray-900 dark:text-white">
          Playlists
        </h1>
        <button
          onClick={() => setIsCreateModalOpen(true)}
          className="flex h-11 items-center gap-2 px-5 bg-gray-700 hover:bg-gray-600 active:bg-gray-500 text-white font-semibold rounded-full transition-all duration-200 focus:outline-none"
          aria-label="Crear nueva playlist"
        >
          <PlusIcon className="w-5 h-5" />
          <span className="hidden sm:inline">Nueva Playlist</span>
        </button>
      </div>
      
      {!backendAvailable && sortedPlaylists.length > 0 && (
        <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4 md:gap-6">
          {sortedPlaylists.map(playlist => {
            const isPlayingFromThisPlaylist =
              isPlaying && currentSource === `playlist:${playlist.id}`
            return (
              <PlaylistItem
                key={playlist.id}
                playlist={playlist}
                isPlayingFromThisPlaylist={isPlayingFromThisPlaylist}
                isPinned={isPinned(playlist.id)}
                onTogglePin={handleTogglePinned}
              />
            )
          })}
        </div>
      )}

      {backendAvailable && sections.map(section => {
        if (section.type === 'fixed_daily') {
          return <DailyMixSection key={section.id} format="playlists" />
        }

        if (section.type === 'fixed_user') {
          if (myPlaylists.length === 0) return null
          return (
            <HorizontalScrollSection key={section.id} title={section.title}>
              {myPlaylists.map(playlist => {
                const isPlayingFromThisPlaylist =
                  isPlaying && currentSource === `playlist:${playlist.id}`
                return (
                  <div key={playlist.id} className="flex-shrink-0 w-36 md:w-44">
                    <PlaylistItem
                      playlist={playlist}
                      isPlayingFromThisPlaylist={isPlayingFromThisPlaylist}
                      isPinned={isPinned(playlist.id)}
                      onTogglePin={handleTogglePinned}
                    />
                  </div>
                )
              })}
            </HorizontalScrollSection>
          )
        }

        if (section.type === 'fixed_smart') {
          if (smartPlaylists.length === 0) return null
          return (
            <HorizontalScrollSection key={section.id} title={section.title}>
              {smartPlaylists.map(playlist => {
                const isPlayingFromThisPlaylist =
                  isPlaying && currentSource === `playlist:${playlist.id}`
                return (
                  <div key={playlist.id} className="flex-shrink-0 w-36 md:w-44">
                    <PlaylistItem
                      playlist={playlist}
                      isPlayingFromThisPlaylist={isPlayingFromThisPlaylist}
                      isPinned={isPinned(playlist.id)}
                      onTogglePin={handleTogglePinned}
                    />
                  </div>
                )
              })}
            </HorizontalScrollSection>
          )
        }

        if (section.type === 'dynamic') {
          const sectionPlaylists = (section.playlists || [])
            .map(id => playlistMap.get(id))
            .filter((p): p is Playlist => !!p && !p.comment?.includes('Smart Playlist'))

          if (sectionPlaylists.length === 0) return null

          return (
            <HorizontalScrollSection key={section.id} title={section.title}>
              {sectionPlaylists.map(playlist => {
                const isPlayingFromThisPlaylist =
                  isPlaying && currentSource === `playlist:${playlist.id}`
                const isSpotify = playlist.name.startsWith('[Spotify] ') || playlist.comment?.includes('Spotify Synced') || syncs.some(s => s.navidromeId === playlist.id)
                return (
                  <div key={playlist.id} className="flex-shrink-0 w-36 md:w-44">
                    <PlaylistItem
                      playlist={playlist}
                      isPlayingFromThisPlaylist={isPlayingFromThisPlaylist}
                      isPinned={isPinned(playlist.id)}
                      onTogglePin={handleTogglePinned}
                      isSpotifySynced={isSpotify}
                    />
                  </div>
                )
              })}
            </HorizontalScrollSection>
          )
        }

        return null
      })}

      {!backendAvailable && sortedPlaylists.length === 0 && !loading && (
        <div className="text-center mt-8 text-gray-500">No se encontraron playlists.</div>
      )}

      {backendAvailable && playlists.length === 0 && !loading && (
        <div className="text-center mt-8 text-gray-500">No se encontraron playlists.</div>
      )}

      {/* Modal para crear nueva playlist */}
      <CreatePlaylistModal
        isOpen={isCreateModalOpen}
        onClose={() => setIsCreateModalOpen(false)}
        onConfirm={handleCreatePlaylist}
      />
    </div>
  )
}
