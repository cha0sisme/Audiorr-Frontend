import { motion } from 'framer-motion'
import { ReactNode } from 'react'
import { useNavigationType, useLocation } from 'react-router-dom'
import { Capacitor } from '@capacitor/core'

interface PageTransitionProps {
  children: ReactNode
  className?: string
}

const ROOT_TABS = new Set(['/', '/artists', '/playlists', '/search', '/audiorr'])
const isNative = Capacitor.isNativePlatform()

export default function PageTransition({ children, className = '' }: PageTransitionProps) {
  const navigationType = useNavigationType()
  const location = useLocation()

  const isRootTab = ROOT_TABS.has(location.pathname)
  const isPop = navigationType === 'POP'

  // Tabs raíz en nativo: cambio instantáneo sin animación (como UITabBar nativo de iOS)
  if (isNative && isRootTab) {
    return (
      <motion.div
        initial={false}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0, transition: { duration: 0.05 } }}
        className={className}
      >
        {children}
      </motion.div>
    )
  }

  // En nativo + página de detalle: transición con slide direccional
  if (isNative && !isRootTab) {
    const enterX = isPop ? -28 : 28
    const exitX = isPop ? 28 : -14

    return (
      <motion.div
        initial={{ x: enterX, opacity: 0 }}
        animate={{
          x: 0,
          opacity: 1,
          transition: { duration: 0.22, ease: [0.0, 0.0, 0.2, 1] },
        }}
        exit={{
          x: exitX,
          opacity: 0,
          transition: { duration: 0.12, ease: [0.4, 0.0, 1, 1] },
        }}
        className={className}
        style={{ willChange: 'transform, opacity' }}
      >
        {children}
      </motion.div>
    )
  }

  // Web: fade suave
  return (
    <motion.div
      initial={{ opacity: 0, y: 6 }}
      animate={{
        opacity: 1,
        y: 0,
        transition: { duration: 0.1, ease: [0.0, 0.0, 0.2, 1] },
      }}
      exit={{
        opacity: 0,
        y: -3,
        transition: { duration: 0.08, ease: [0.4, 0.0, 1, 1] },
      }}
      className={className}
      style={{
        backfaceVisibility: 'hidden',
        WebkitBackfaceVisibility: 'hidden',
      }}
    >
      {children}
    </motion.div>
  )
}
