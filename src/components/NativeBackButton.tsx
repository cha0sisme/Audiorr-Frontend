import { useNavigate, useLocation } from 'react-router-dom'
import { Capacitor } from '@capacitor/core'
import { useTheme } from '../contexts/ThemeContext'
import { useHeroPresence } from '../contexts/HeroPresenceContext'

// Páginas raíz (tabs) — no mostrar botón de volver
const ROOT_TABS = new Set(['/', '/artists', '/playlists', '/search', '/audiorr'])

const isNative = Capacitor.isNativePlatform()

export default function NativeBackButton() {
  const navigate = useNavigate()
  const location = useLocation()
  const { isDark } = useTheme()
  const { heroPresent } = useHeroPresence()

  // Solo en iOS/Android nativo
  if (!isNative) return null

  const isRootTab = ROOT_TABS.has(location.pathname)

  // Usar estilo oscuro cuando hay hero (fondo siempre oscuro) o cuando el tema es oscuro
  const useDarkStyle = isDark || heroPresent

  return (
    <button
      onClick={() => navigate(-1)}
      className={`fixed z-[9990] flex items-center justify-center rounded-full select-none active:scale-95 ${
        isRootTab ? 'opacity-0 pointer-events-none' : 'opacity-100'
      } ${useDarkStyle ? 'text-white' : 'text-gray-900'}`}
      style={{
        top: 'calc(env(safe-area-inset-top) + 14px)',
        left: '12px',
        width: '34px',
        height: '34px',
        backdropFilter: 'blur(24px) saturate(1.8)',
        WebkitBackdropFilter: 'blur(24px) saturate(1.8)',
        transition: 'opacity 0.15s ease, background 0.2s ease, border-color 0.2s ease, color 0.2s ease, box-shadow 0.2s ease',
        ...(useDarkStyle
          ? {
              background: 'rgba(255, 255, 255, 0.13)',
              border: '1px solid rgba(255, 255, 255, 0.20)',
              boxShadow: '0 2px 14px rgba(0,0,0,0.25), inset 0 1px 0 rgba(255,255,255,0.16)',
            }
          : {
              background: 'rgba(0, 0, 0, 0.07)',
              border: '1px solid rgba(0, 0, 0, 0.12)',
              boxShadow: '0 2px 14px rgba(0,0,0,0.10), inset 0 1px 0 rgba(255,255,255,0.50)',
            }),
      }}
      aria-label="Volver atrás"
    >
      <svg
        className="w-[18px] h-[18px]"
        fill="none"
        viewBox="0 0 24 24"
        stroke="currentColor"
        strokeWidth={2.8}
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <path d="M15 19l-7-7 7-7" />
      </svg>
    </button>
  )
}
