import { useState, useEffect, useRef } from 'react'
import { useNavigate, Link } from 'react-router-dom'
import {
  ChevronLeftIcon,
  ChevronRightIcon,
  Cog6ToothIcon,
  WrenchScrewdriverIcon,
} from '@heroicons/react/24/solid'
import { navidromeApi } from '../services/navidromeApi'
import SearchBar from './SearchBar'
import { AboutModal } from './AboutModal'
import { getColorForUsername, getInitial } from '../utils/userUtils'
import { DevicePicker } from './DevicePicker'


export function Header() {
  const navigate = useNavigate()
  const [showDropdown, setShowDropdown] = useState(false)
  const [showAboutModal, setShowAboutModal] = useState(false)
  const [username, setUsername] = useState<string | null>(null)
  const [isAdmin, setIsAdmin] = useState(false)
  const dropdownRef = useRef<HTMLDivElement>(null)

  // Cargar nombre de usuario
  useEffect(() => {
    const config = navidromeApi.getConfig()
    if (config?.username) {
      setUsername(config.username)
      setIsAdmin(config.isAdmin === true)
    }
  }, [])

  // Cerrar dropdown al hacer click fuera
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target as Node)) {
        setShowDropdown(false)
      }
    }

    if (showDropdown) {
      document.addEventListener('mousedown', handleClickOutside)
      return () => document.removeEventListener('mousedown', handleClickOutside)
    }
  }, [showDropdown])

  return (
    <header className="hidden md:flex flex-shrink-0 bg-gray-100 dark:bg-gray-800 p-4 items-center gap-4 relative z-50" style={{ paddingTop: 'max(1rem, env(safe-area-inset-top))' }}>
      <div className="hidden md:flex items-center gap-2">
        <button
          onClick={() => navigate(-1)}
          className="p-2 rounded-full bg-gray-200 dark:bg-gray-700 hover:bg-gray-300 dark:hover:bg-gray-600 transition-colors"
          aria-label="Go back"
        >
          <ChevronLeftIcon className="h-6 w-6 text-gray-700 dark:text-gray-200" />
        </button>
        <button
          onClick={() => navigate(1)}
          className="p-2 rounded-full bg-gray-200 dark:bg-gray-700 hover:bg-gray-300 dark:hover:bg-gray-600 transition-colors"
          aria-label="Go forward"
        >
          <ChevronRightIcon className="h-6 w-6 text-gray-700 dark:text-gray-200" />
        </button>
      </div>
      {/* Barra de búsqueda centrada y más pequeña */}
      <div className="flex-1 flex justify-center">
        <div className="w-full max-w-md">
          <SearchBar />
        </div>
      </div>
      
      <div className="flex items-center gap-2">
        <DevicePicker align="down" buttonClassName="p-2" iconClassName="w-6 h-6" />
        {/* Avatar del usuario con dropdown */}
        <div className="relative" ref={dropdownRef}>
          <button
            onClick={() => setShowDropdown(!showDropdown)}
            className="w-10 h-10 rounded-full transition-opacity overflow-hidden flex items-center justify-center flex-shrink-0 text-white"
            aria-label="Menú de usuario"
            style={{
              backgroundColor: username ? getColorForUsername(username) : '#6b7280',
            }}
          >
            {username ? getInitial(username) : '?'}
          </button>
          {showDropdown && (
            <div className="absolute right-0 mt-2 w-48 bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg shadow-xl z-50">
              <Link
                to="/profile"
                onClick={() => setShowDropdown(false)}
                className="flex items-center gap-3 px-4 py-3 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors rounded-t-lg"
              >
                <svg
                  className="w-5 h-5"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                  xmlns="http://www.w3.org/2000/svg"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"
                  />
                </svg>
                <span>Perfil</span>
              </Link>
              <Link
                to="/settings"
                onClick={() => setShowDropdown(false)}
                className="flex items-center gap-3 px-4 py-3 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
              >
                <Cog6ToothIcon className="w-5 h-5" />
                <span>Configuración</span>
              </Link>
              <button
                type="button"
                onClick={() => {
                  setShowDropdown(false)
                  setShowAboutModal(true)
                }}
                className={`flex w-full items-center gap-3 px-4 py-3 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors ${!isAdmin ? 'rounded-b-lg' : ''}`}
              >
                <svg
                  className="w-5 h-5"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                  xmlns="http://www.w3.org/2000/svg"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                  />
                </svg>
                <span>Acerca de</span>
              </button>
              {isAdmin && (
                <Link
                  to="/admin"
                  onClick={() => setShowDropdown(false)}
                  className="flex items-center gap-3 px-4 py-3 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors rounded-b-lg border-t border-gray-100 dark:border-gray-700"
                >
                  <WrenchScrewdriverIcon className="w-5 h-5" />
                  <span>Gestión</span>
                </Link>
              )}
            </div>
          )}
        </div>
      </div>
      <AboutModal isOpen={showAboutModal} onClose={() => setShowAboutModal(false)} />
    </header>
  )
}
