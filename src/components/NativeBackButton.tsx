import { motion, AnimatePresence } from 'framer-motion'
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

  const buttonStyle = useDarkStyle
    ? {
        background: 'rgba(255, 255, 255, 0.13)',
        border: '1px solid rgba(255, 255, 255, 0.20)',
        boxShadow: '0 2px 14px rgba(0,0,0,0.25), inset 0 1px 0 rgba(255,255,255,0.16)',
      }
    : {
        background: 'rgba(0, 0, 0, 0.07)',
        border: '1px solid rgba(0, 0, 0, 0.12)',
        boxShadow: '0 2px 14px rgba(0,0,0,0.10), inset 0 1px 0 rgba(255,255,255,0.50)',
      }

  const textColor = useDarkStyle ? 'text-white' : 'text-gray-900'

  return (
    <AnimatePresence>
      {!isRootTab && (
        <motion.button
          key="native-back-btn"
          initial={{ opacity: 0, x: -10 }}
          animate={{ opacity: 1, x: 0 }}
          exit={{ opacity: 0, x: -10 }}
          transition={{ duration: 0.18, ease: [0.0, 0.0, 0.2, 1] }}
          onClick={() => navigate(-1)}
          className={`fixed z-[9990] flex items-center gap-[3px] pl-[6px] pr-[11px] rounded-full select-none active:scale-95 transition-transform ${textColor}`}
          style={{
            top: 'calc(env(safe-area-inset-top) + 14px)',
            left: '12px',
            height: '36px',
            backdropFilter: 'blur(24px) saturate(1.8)',
            WebkitBackdropFilter: 'blur(24px) saturate(1.8)',
            ...buttonStyle,
          }}
          aria-label="Volver atrás"
        >
          <svg
            className={`w-[18px] h-[18px] ${textColor}`}
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={2.8}
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <path d="M15 19l-7-7 7-7" />
          </svg>
          <span
            className={`font-semibold ${textColor}`}
            style={{ fontSize: '15px', lineHeight: 1 }}
          >
            Atrás
          </span>
        </motion.button>
      )}
    </AnimatePresence>
  )
}
