import { useState, useEffect, useRef, useCallback, memo, Suspense, lazy } from 'react'
import { Routes, Route, Navigate, useLocation, useNavigationType } from 'react-router-dom'
import { Capacitor } from '@capacitor/core'
import Spinner from './Spinner'
import { navidromeApi } from '../services/navidromeApi'
import { useHeroPresence } from '../contexts/HeroPresenceContext'

// Root tab pages — eager load to avoid Suspense flash on tab switch
import HomePage from './HomePage'
import ArtistsPage from './ArtistsPage'
import PlaylistsPage from './PlaylistsPage'
import SearchPage from './SearchPage'
import AudiorrPage from './AudiorrPage'

// Detail pages — lazy load (code splitting)
const AlbumsPage = lazy(() => import('./AlbumsPage'))
const AlbumDetail = lazy(() => import('./AlbumDetail'))
const ArtistsDetail = lazy(() => import('./ArtistsDetail'))
const PlaylistDetail = lazy(() => import('./PlaylistDetail'))
const SettingsPage = lazy(() => import('./SettingsPage'))
const UserProfile = lazy(() => import('./UserProfile'))
const SongDetail = lazy(() => import('./SongDetail'))
const GenresPage = lazy(() => import('./GenresPage'))
const GenreDetail = lazy(() => import('./GenreDetail'))
const WrappedPage = lazy(() => import('./WrappedPage'))
const AdminPage = lazy(() => import('./AdminPage'))
const ReceiverPage = lazy(() => import('./ReceiverPage').then(m => ({ default: m.ReceiverPage })))

// === Constants ===
const isNative = Capacitor.isNativePlatform()
const ROOT_TABS = new Set(['/', '/artists', '/playlists', '/search', '/audiorr'])
const MAX_STACK = 8

// Animation durations (seconds)
const PUSH_DURATION = isNative ? 0.35 : 0.2
const POP_DURATION = isNative ? 0.3 : 0.15
const IOS_EASING = 'cubic-bezier(0.32, 0.72, 0, 1)'
const WEB_EASE_IN = 'cubic-bezier(0.0, 0.0, 0.2, 1)'
const WEB_EASE_OUT = 'cubic-bezier(0.4, 0.0, 1, 1)'

// === Types ===
type PageStatus = 'active' | 'cached' | 'entering' | 'exiting'

interface StackEntry {
  id: string
  location: ReturnType<typeof useLocation>
  status: PageStatus
}

// === Helper components ===
function ProfileRedirect() {
  const config = navidromeApi.getConfig()
  if (!config?.username) return <Navigate to="/" replace />
  return <Navigate to={`/user/${config.username}`} replace />
}

// Memoized route renderer — prevents re-renders of cached pages
const PageRoutes = memo(function PageRoutes({ location }: { location: ReturnType<typeof useLocation> }) {
  return (
    <Routes location={location}>
      <Route path="/" element={<HomePage />} />
      <Route path="/albums" element={<AlbumsPage />} />
      <Route path="/albums/:id" element={<AlbumDetail />} />
      <Route path="/artists" element={<ArtistsPage />} />
      <Route path="/artists/:name" element={<ArtistsDetail />} />
      <Route path="/playlists" element={<PlaylistsPage />} />
      <Route path="/playlists/:id" element={<PlaylistDetail />} />
      <Route path="/songs/:id" element={<SongDetail />} />
      <Route path="/settings" element={<SettingsPage />} />
      <Route path="/profile" element={<ProfileRedirect />} />
      <Route path="/user/:username" element={<UserProfile />} />
      <Route path="/genres" element={<GenresPage />} />
      <Route path="/genre/:genreName" element={<GenreDetail />} />
      <Route path="/wrapped" element={<WrappedPage />} />
      <Route path="/admin" element={<AdminPage />} />
      <Route path="/admin/:tab" element={<AdminPage />} />
      <Route path="/search" element={<SearchPage />} />
      <Route path="/audiorr" element={<AudiorrPage />} />
      <Route path="/receiver" element={<ReceiverPage />} />
    </Routes>
  )
})

// === Stack Page ===
// Uses plain div + Web Animations API instead of framer-motion.
// Critical: framer-motion's motion.div applies `transform: translateX(0)` at rest,
// which creates a CSS containing block and breaks `position: sticky` inside pages.
// Web Animations API runs on a separate layer and after cancel() the element
// reverts to its CSS values (no transform), so sticky works correctly.
const StackPage = memo(function StackPage({
  entry,
  onAnimationComplete,
}: {
  entry: StackEntry
  onAnimationComplete: (id: string) => void
}) {
  const { heroPresent } = useHeroPresence()
  const { id, location: loc, status } = entry
  // El spacer nativo de 44px solo se aplica en páginas que NO son root tabs
  // y que NO tienen un Hero (ya que el Hero se encarga del notch)
  
  const pageRef = useRef<HTMLDivElement>(null)
  const animRef = useRef<Animation | null>(null)
  const isAnimating = status === 'entering' || status === 'exiting'

  // ... (rest of the effect stays the same) ...
  useEffect(() => {
    const el = pageRef.current
    if (!el) return

    if (animRef.current) {
      animRef.current.cancel()
      animRef.current = null
    }

    if (status === 'entering') {
      if (isNative) el.style.boxShadow = '-2px 0 8px rgba(0,0,0,0.15)'

      const keyframes = isNative
        ? [
            { transform: 'translateX(100%)', opacity: 1 },
            { transform: 'translateX(0)', opacity: 1 },
          ]
        : [
            { transform: 'translateY(8px)', opacity: 0 },
            { transform: 'translateY(0)', opacity: 1 },
          ]

      const anim = el.animate(keyframes, {
        duration: PUSH_DURATION * 1000,
        easing: isNative ? IOS_EASING : WEB_EASE_IN,
        fill: 'forwards',
      })
      animRef.current = anim

      anim.onfinish = () => {
        anim.cancel()
        animRef.current = null
        el.style.boxShadow = ''
        onAnimationComplete(id)
      }
      return
    }

    if (status === 'exiting') {
      if (isNative) el.style.boxShadow = '-2px 0 8px rgba(0,0,0,0.15)'

      const keyframes = isNative
        ? [
            { transform: 'translateX(0)', opacity: 1 },
            { transform: 'translateX(100%)', opacity: 1 },
          ]
        : [
            { transform: 'translateY(0)', opacity: 1 },
            { transform: 'translateY(-4px)', opacity: 0 },
          ]

      const anim = el.animate(keyframes, {
        duration: POP_DURATION * 1000,
        easing: isNative ? IOS_EASING : WEB_EASE_OUT,
        fill: 'forwards',
      })
      animRef.current = anim

      anim.onfinish = () => {
        anim.cancel()
        animRef.current = null
        onAnimationComplete(id)
      }
      return
    }
  }, [status, id, onAnimationComplete])

  useEffect(() => {
    return () => {
      if (animRef.current) {
        animRef.current.cancel()
        animRef.current = null
      }
    }
  }, [])

  return (
    <div
      ref={pageRef}
      className="bg-gray-100 dark:bg-gray-800"
      style={{
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
        overflowY: 'auto',
        overflowX: 'hidden',
        WebkitOverflowScrolling: 'touch',
        overscrollBehavior: 'none',
        visibility: status === 'cached' ? 'hidden' : 'visible',
        zIndex: isAnimating ? 2 : status === 'active' ? 1 : 0,
        pointerEvents: isAnimating ? 'none' : 'auto',
      }}
    >
      {/* 
        Si hay un Hero, eliminamos paddings y dejamos que el hijo ocupe todo el espacio (p-0).
        En móvil, siempre forzamos p-0 para contenido full-width si hay Hero.
      */}
      <div className={`${heroPresent ? 'p-0 pb-[200px] md:pb-6' : 'p-4 pt-[calc(env(safe-area-inset-top,20px)+12px)] pb-[200px] md:p-6 md:pb-6 lg:p-8'}`}>
        <Suspense
          fallback={
            <div className="flex items-center justify-center h-64">
              <Spinner size="lg" />
            </div>
          }
        >
          <PageRoutes location={loc} />
        </Suspense>
      </div>
    </div>
  )
})

// === Main NavigationStack ===
// Manages an iOS-like navigation stack where pages are kept alive in the DOM.
// On PUSH: new page enters, old page stays cached (hidden but not unmounted).
// On POP: top page exits, cached page below is instantly revealed (no re-mount!).
// On tab switch: stack is cleared for instant swap.
export default function NavigationStack() {
  const location = useLocation()
  const navigationType = useNavigationType()
  const [stack, setStack] = useState<StackEntry[]>(() => [
    {
      id: location.key || 'initial',
      location,
      status: 'active' as PageStatus,
    },
  ])
  // Use location object reference for change detection — more robust than key comparison.
  // React Router creates a new location object for each navigation, so reference
  // comparison works reliably regardless of how navigation was triggered
  // (useNavigate, NavLink, native tab bar via Capacitor, browser back, etc.)
  const prevLocationRef = useRef(location)

  useEffect(() => {
    if (location === prevLocationRef.current) return
    prevLocationRef.current = location

    const isToTab = ROOT_TABS.has(location.pathname)

    setStack(prev => {
      // Tab switch: instant swap, clear entire stack
      if (isToTab) {
        return [
          {
            id: location.key || String(Date.now()),
            location,
            status: 'active' as PageStatus,
          },
        ]
      }

      if (navigationType === 'PUSH') {
        // Clean up any pages still animating out (rapid navigation)
        let updated = prev.filter(e => e.status !== 'exiting')
        // Cache current active/entering page
        updated = updated.map(e =>
          e.status === 'active' || e.status === 'entering'
            ? { ...e, status: 'cached' as PageStatus }
            : e
        )
        // Push new page
        updated.push({
          id: location.key || String(Date.now()),
          location,
          status: 'entering' as PageStatus,
        })
        // Limit stack size from the bottom to prevent memory bloat
        while (updated.length > MAX_STACK) updated.shift()
        return updated
      }

      if (navigationType === 'POP') {
        // Clean up any pages still animating in (rapid navigation)
        let updated = prev.filter(e => e.status !== 'entering')

        if (updated.length <= 1) {
          // No cached page to reveal — render fresh
          return [
            {
              id: location.key || String(Date.now()),
              location,
              status: 'active' as PageStatus,
            },
          ]
        }

        // Mark top as exiting, reveal the one below (already in DOM!)
        return updated.map((entry, i) => {
          if (i === updated.length - 1)
            return { ...entry, status: 'exiting' as PageStatus }
          if (i === updated.length - 2)
            return { ...entry, status: 'active' as PageStatus }
          return entry
        })
      }

      // REPLACE: swap top entry, preserve entering animation if in progress
      const prevTop = prev[prev.length - 1]
      const newStatus =
        prevTop?.status === 'entering'
          ? ('entering' as PageStatus)
          : ('active' as PageStatus)
      return [
        ...prev.slice(0, -1),
        {
          id: location.key || String(Date.now()),
          location,
          status: newStatus,
        },
      ]
    })
  }, [location, navigationType])

  const handleAnimationComplete = useCallback((id: string) => {
    setStack(prev => {
      const entry = prev.find(e => e.id === id)
      if (!entry) return prev
      if (entry.status === 'entering') {
        return prev.map(e =>
          e.id === id ? { ...e, status: 'active' as PageStatus } : e
        )
      }
      if (entry.status === 'exiting') {
        return prev.filter(e => e.id !== id)
      }
      return prev
    })
  }, [])

  // Lazy image cleanup on navigation
  useEffect(() => {
    const timeout = setTimeout(() => {
      const images = document.querySelectorAll('img[loading="lazy"]')
      images.forEach(img => {
        const rect = img.getBoundingClientRect()
        const isOffscreen =
          rect.bottom < -500 || rect.top > window.innerHeight + 500
        if (isOffscreen && (img as HTMLImageElement).src) {
          ;(img as HTMLImageElement).loading = 'lazy'
        }
      })
    }, 200)
    return () => clearTimeout(timeout)
  }, [location.pathname])

  return (
    <div style={{ position: 'absolute', inset: 0, overflow: 'hidden' }}>
      {stack.map(entry => (
        <StackPage
          key={entry.id}
          entry={entry}
          onAnimationComplete={handleAnimationComplete}
        />
      ))}
    </div>
  )
}
