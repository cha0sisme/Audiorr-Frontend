import { AnimatePresence, motion } from 'framer-motion'
import { useOnlineStatus } from '../hooks/useOnlineStatus'

export default function OfflineBanner() {
  const isOnline = useOnlineStatus()

  return (
    <AnimatePresence>
      {!isOnline && (
        <motion.div
          key="offline-banner"
          initial={{ y: -48, opacity: 0 }}
          animate={{ y: 0, opacity: 1 }}
          exit={{ y: -48, opacity: 0 }}
          transition={{ type: 'spring', damping: 28, stiffness: 320 }}
          className="fixed top-0 left-0 right-0 z-[9998] flex items-center justify-center gap-2 px-4 py-2.5 bg-amber-500 dark:bg-amber-600 text-white text-sm font-semibold shadow-lg select-none"
          style={{ paddingTop: 'calc(env(safe-area-inset-top) + 0.625rem)' }}
        >
          <svg className="w-4 h-4 flex-shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M18.364 5.636a9 9 0 010 12.728M15.536 8.464a5 5 0 010 7.072M3 3l18 18M10.584 10.587a2 2 0 002.828 2.83" />
          </svg>
          <span>Sin conexión · Mostrando datos guardados</span>
        </motion.div>
      )}
    </AnimatePresence>
  )
}
