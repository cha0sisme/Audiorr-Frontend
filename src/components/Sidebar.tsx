import { NavLink, useLocation } from 'react-router-dom'
import { HomeIcon, UsersIcon } from '@heroicons/react/24/solid'
import { useSidebar } from '../contexts/SidebarContext'
import { useEffect } from 'react'
import { usePinnedPlaylists } from '../hooks/usePinnedPlaylists'
import type { PinnedPlaylist } from '../types/playlist'
import { PinFilledIcon } from './icons/PinIcons'
import logoIconUrl from '../../assets/logo-icon.svg'
import { navidromeApi } from '../services/navidromeApi'
import { PlaylistCover } from './PlaylistCover'

const PlaylistNavIcon = ({ className }: { className?: string }) => (
  <svg
    className={className}
    viewBox="0 0 24 24"
    fill="none"
    xmlns="http://www.w3.org/2000/svg"
    stroke="currentColor"
    strokeWidth="2.2"
    strokeLinecap="round"
    strokeLinejoin="round"
  >
    <path d="M6 6L3 7.73205V4.26795L6 6Z" />
    <path d="M3 12H21" />
    <path d="M10 6H21" />
    <path d="M3 18H21" />
  </svg>
)

function PinnedPlaylistRow({
  playlist,
  onMetadataUpdate,
}: {
  playlist: PinnedPlaylist
  onMetadataUpdate: (playlist: PinnedPlaylist) => void
}) {


  useEffect(() => {
    const needsMetadata =
      playlist.coverArt === undefined ||
      playlist.songCount === undefined ||
      playlist.duration === undefined ||
      playlist.created === undefined ||
      playlist.changed === undefined ||
      playlist.owner === undefined ||
      playlist.comment === undefined

    if (!needsMetadata) {
      return
    }

    let cancelled = false
    let hasFetched = false

    const fetchMetadata = async () => {
      // Evitar múltiples llamadas para la misma playlist
      if (hasFetched) return
      hasFetched = true

      try {
        const allPlaylists = await navidromeApi.getPlaylists()
        if (cancelled) return
        const info = allPlaylists.find(item => item.id === playlist.id)
        if (!info) return

        onMetadataUpdate({
          id: playlist.id,
          name: info.name ?? playlist.name,
          owner: info.owner ?? playlist.owner,
          songCount: info.songCount ?? playlist.songCount,
          duration: info.duration ?? playlist.duration,
          created: info.created ?? playlist.created,
          changed: info.changed ?? playlist.changed,
          coverArt: info.coverArt ?? playlist.coverArt,
          comment: info.comment ?? playlist.comment,
        })
      } catch (error) {
        console.warn('[Sidebar] No se pudo cargar metadata de playlist anclada:', error)
      }
    }

    fetchMetadata()

    return () => {
      cancelled = true
    }
    // CRÍTICO: Solo dependemos del ID de la playlist para evitar re-fetches constantes
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [playlist.id])

  const ownerName = playlist.owner ?? 'Audiorr'

  return (
    <NavLink
      to={`/playlists/${playlist.id}`}
      className={({ isActive }) =>
        `group flex items-center gap-3 p-2.5 my-1 rounded-2xl transition-colors duration-75 ${
          isActive
            ? 'bg-blue-500 dark:bg-gray-700 hover:bg-blue-400 dark:hover:bg-gray-600 active:bg-blue-600 dark:active:bg-gray-500 text-white'
            : 'text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 active:bg-gray-300 dark:active:bg-gray-500'
        }`
      }
    >
      {({ isActive }) => (
        <>
          <div className="relative h-12 w-12 flex-shrink-0 overflow-hidden rounded-xl shadow-md ring-1 ring-gray-900/5 dark:ring-white/10">
            <PlaylistCover
              playlistId={playlist.id}
              name={playlist.name}
              className="h-full w-full"
              rounded={false}
            />
          </div>
          <div className="min-w-0 flex-1">
            <p
              className={`truncate text-sm font-semibold ${
                isActive ? 'text-white' : 'text-gray-900 dark:text-white'
              }`}
            >
              {playlist.name.split(' · ')[0]}
            </p>
            <div
              className={`flex items-center gap-1 text-xs ${
                isActive ? 'text-white/80' : 'text-gray-500 dark:text-gray-400'
              }`}
            >
              <PinFilledIcon
                className={`h-3.5 w-3.5 ${isActive ? 'text-white/80' : 'text-gray-400 dark:text-gray-500'}`}
              />
              <span className="font-medium">Lista • {ownerName}</span>
            </div>
          </div>
        </>
      )}
    </NavLink>
  )
}

const Sidebar = () => {
  const { isOpen, closeSidebar } = useSidebar()
  const location = useLocation()
  const { pinnedPlaylists, updatePinnedPlaylist } = usePinnedPlaylists()

  // Cerrar el sidebar al cambiar de ruta en móvil
  useEffect(() => {
    if (isOpen) {
      closeSidebar()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [location.pathname]) // Solo cerrar cuando cambia la ruta, no cuando cambia closeSidebar

  const navLinkClass = ({ isActive }: { isActive: boolean }) =>
    `flex items-center p-3 my-1 rounded-2xl transition-colors duration-75 font-semibold ${
      isActive
        ? 'bg-blue-500 dark:bg-gray-700 hover:bg-blue-400 dark:hover:bg-gray-600 active:bg-blue-600 dark:active:bg-gray-500 text-white'
        : 'text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 active:bg-gray-300 dark:active:bg-gray-500'
    }`

  const sidebarContent = (
    <>
      <NavLink
        to="/"
        className="flex items-center gap-2 mb-8 text-gray-800 dark:text-white hover:opacity-80 transition-opacity cursor-pointer select-none"
        style={{ userSelect: 'none' }}
      >
        <img
          src={logoIconUrl}
          alt="Audiorr Logo"
          className="h-6 w-6 select-none object-contain flex-shrink-0 brightness-0 dark:invert pointer-events-none"
          style={{
            userSelect: 'none',
            pointerEvents: 'none',
          }}
          draggable={false}
        />
        <span className="text-3xl font-black font-title select-none">Audiorr</span>
      </NavLink>
      <nav>
        <NavLink to="/" className={navLinkClass}>
          <HomeIcon className="w-6 h-6 mr-3" />
          Inicio
        </NavLink>
        <NavLink to="/artists" className={navLinkClass}>
          <UsersIcon className="w-6 h-6 mr-3" />
          Artistas
        </NavLink>
        <NavLink to="/playlists" className={navLinkClass}>
          <PlaylistNavIcon className="w-6 h-6 mr-3" />
          Playlists
        </NavLink>
        {pinnedPlaylists.length > 0 && (
          <div className="mt-4">
            <p className="px-3 text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400 mb-1">
              Playlists ancladas
            </p>
            {pinnedPlaylists.map(playlist => (
              <PinnedPlaylistRow key={playlist.id} playlist={playlist} onMetadataUpdate={updatePinnedPlaylist} />
            ))}
          </div>
        )}
      </nav>
    </>
  )

  return (
    <>
      {/* --- Sidebar para tablet (sm-md): superposición — en móvil se usa el TabBar --- */}
      <aside
        className={`fixed top-0 left-0 h-full w-64 bg-gray-100 dark:bg-gray-800 z-50 transform transition-transform duration-300 ease-in-out hidden sm:block md:hidden ${
          isOpen ? 'translate-x-0' : '-translate-x-full'
        }`}
        style={{
          paddingTop: 'max(1rem, env(safe-area-inset-top))',
          paddingBottom: 'max(1rem, env(safe-area-inset-bottom))',
          paddingLeft: '1rem',
          paddingRight: '1rem',
        }}
      >
        {sidebarContent}
      </aside>

      {/* --- Overlay para tablet --- */}
      {isOpen && (
        <div
          className="fixed inset-0 bg-black/50 z-40 hidden sm:block md:hidden"
          onClick={closeSidebar}
          aria-hidden="true"
        />
      )}

      {/* --- Sidebar para escritorio (estático) --- */}
      <aside className="hidden md:flex md:w-64 md:flex-shrink-0 md:flex-col md:p-4 bg-gray-100 dark:bg-gray-800">
        {sidebarContent}
      </aside>
    </>
  )
}

export default Sidebar
