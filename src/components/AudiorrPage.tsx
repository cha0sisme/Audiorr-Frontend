import { useState, useEffect } from 'react'
import { Link } from 'react-router-dom'
import {
  RectangleStackIcon,
  TagIcon,
  Cog6ToothIcon,
  WrenchScrewdriverIcon,
  InformationCircleIcon,
  ArrowRightOnRectangleIcon,
} from '@heroicons/react/24/solid'
import { navidromeApi } from '../services/navidromeApi'
import { usePinnedPlaylists } from '../hooks/usePinnedPlaylists'
import { AboutModal } from './AboutModal'
import ThemeSwitcher from './ThemeSwitcher'
import { PlaylistCover } from './PlaylistCover'
import { getColorForUsername, getInitial } from '../utils/userUtils'

const libraryItems = [
  {
    to: '/albums',
    icon: RectangleStackIcon,
    label: 'Álbumes',
    bg: 'bg-gradient-to-br from-blue-500 to-indigo-600',
  },
  {
    to: '/genres',
    icon: TagIcon,
    label: 'Géneros',
    bg: 'bg-gradient-to-br from-purple-500 to-purple-700',
  },
]

function RowArrow() {
  return (
    <svg className="w-4 h-4 text-gray-300 dark:text-gray-600 flex-shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" />
    </svg>
  )
}

export default function AudiorrPage() {
  const [username, setUsername] = useState<string | null>(null)
  const [isAdmin, setIsAdmin] = useState(false)
  const [showAbout, setShowAbout] = useState(false)
  const { pinnedPlaylists } = usePinnedPlaylists()

  useEffect(() => {
    const config = navidromeApi.getConfig()
    if (config?.username) {
      setUsername(config.username)
      setIsAdmin(config.isAdmin === true)
    }
  }, [])

  const handleLogout = () => {
    if (confirm('¿Cerrar sesión? Se borrará la configuración del servidor.')) {
      navidromeApi.disconnect()
      window.location.reload()
    }
  }

  return (
    <div className="max-w-2xl mx-auto space-y-7">
      {/* Perfil de usuario */}
      <div className="flex items-center gap-4">
        <Link to="/profile">
          <div
            className="w-16 h-16 rounded-full flex items-center justify-center text-white text-2xl font-bold flex-shrink-0 shadow-md"
            style={{ backgroundColor: username ? getColorForUsername(username) : '#6b7280' }}
          >
            {username ? getInitial(username) : '?'}
          </div>
        </Link>
        <div className="flex-1 min-w-0">
          <p className="text-xl font-bold text-gray-900 dark:text-white truncate">
            {username ?? '…'}
          </p>
          <Link to="/profile" className="text-sm text-blue-500 hover:text-blue-600 transition-colors">
            Ver perfil
          </Link>
        </div>
        <ThemeSwitcher />
      </div>

      {/* Biblioteca */}
      <section>
        <p className="text-xs font-semibold uppercase tracking-widest text-gray-500 dark:text-gray-400 mb-3">
          Biblioteca
        </p>
        <div className="bg-white dark:bg-gray-700 rounded-2xl overflow-hidden divide-y divide-gray-100 dark:divide-gray-600">
          {libraryItems.map(item => {
            const Icon = item.icon
            return (
              <Link
                key={item.to}
                to={item.to}
                className="flex items-center gap-4 px-4 py-3.5 hover:bg-gray-50 dark:hover:bg-gray-600 transition-colors"
              >
                <div className={`w-10 h-10 rounded-xl ${item.bg} flex items-center justify-center flex-shrink-0`}>
                  <Icon className="w-5 h-5 text-white" />
                </div>
                <span className="flex-1 font-semibold text-gray-900 dark:text-white">{item.label}</span>
                <RowArrow />
              </Link>
            )
          })}
        </div>
      </section>

      {/* Playlists ancladas */}
      {pinnedPlaylists.length > 0 && (
        <section>
          <p className="text-xs font-semibold uppercase tracking-widest text-gray-500 dark:text-gray-400 mb-3">
            Playlists ancladas
          </p>
          <div className="bg-white dark:bg-gray-700 rounded-2xl overflow-hidden divide-y divide-gray-100 dark:divide-gray-600">
            {pinnedPlaylists.map(pl => (
              <Link
                key={pl.id}
                to={`/playlists/${pl.id}`}
                className="flex items-center gap-4 px-4 py-3 hover:bg-gray-50 dark:hover:bg-gray-600 transition-colors"
              >
                <div className="w-10 h-10 rounded-xl overflow-hidden flex-shrink-0">
                  <PlaylistCover playlistId={pl.id} name={pl.name} className="w-full h-full" rounded={false} />
                </div>
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-semibold text-gray-900 dark:text-white truncate">
                    {pl.name.split(' · ')[0]}
                  </p>
                  <p className="text-xs text-gray-500 dark:text-gray-400">{pl.owner ?? 'Audiorr'}</p>
                </div>
                <RowArrow />
              </Link>
            ))}
          </div>
        </section>
      )}

      {/* Ajustes & más */}
      <section>
        <p className="text-xs font-semibold uppercase tracking-widest text-gray-500 dark:text-gray-400 mb-3">
          General
        </p>
        <div className="bg-white dark:bg-gray-700 rounded-2xl overflow-hidden divide-y divide-gray-100 dark:divide-gray-600">
          <Link
            to="/settings"
            className="flex items-center gap-4 px-4 py-3.5 hover:bg-gray-50 dark:hover:bg-gray-600 transition-colors"
          >
            <div className="w-10 h-10 rounded-xl bg-gray-500 flex items-center justify-center flex-shrink-0">
              <Cog6ToothIcon className="w-5 h-5 text-white" />
            </div>
            <span className="flex-1 font-semibold text-gray-900 dark:text-white">Configuración</span>
            <RowArrow />
          </Link>

          <button
            onClick={() => setShowAbout(true)}
            className="w-full flex items-center gap-4 px-4 py-3.5 hover:bg-gray-50 dark:hover:bg-gray-600 transition-colors text-left"
          >
            <div className="w-10 h-10 rounded-xl bg-blue-500 flex items-center justify-center flex-shrink-0">
              <InformationCircleIcon className="w-5 h-5 text-white" />
            </div>
            <span className="flex-1 font-semibold text-gray-900 dark:text-white">Acerca de Audiorr</span>
          </button>

          {isAdmin && (
            <Link
              to="/admin"
              className="flex items-center gap-4 px-4 py-3.5 hover:bg-gray-50 dark:hover:bg-gray-600 transition-colors"
            >
              <div className="w-10 h-10 rounded-xl bg-orange-500 flex items-center justify-center flex-shrink-0">
                <WrenchScrewdriverIcon className="w-5 h-5 text-white" />
              </div>
              <span className="flex-1 font-semibold text-gray-900 dark:text-white">Gestión</span>
              <RowArrow />
            </Link>
          )}

          <button
            onClick={handleLogout}
            className="w-full flex items-center gap-4 px-4 py-3.5 hover:bg-red-50 dark:hover:bg-red-900/10 transition-colors text-left"
          >
            <div className="w-10 h-10 rounded-xl bg-red-100 dark:bg-red-900/30 flex items-center justify-center flex-shrink-0">
              <ArrowRightOnRectangleIcon className="w-5 h-5 text-red-500" />
            </div>
            <span className="flex-1 font-semibold text-red-500">Cerrar sesión</span>
          </button>
        </div>
      </section>

      <AboutModal isOpen={showAbout} onClose={() => setShowAbout(false)} />
    </div>
  )
}
