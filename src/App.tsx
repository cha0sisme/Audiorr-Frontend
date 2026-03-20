import { useState, useEffect, lazy, Suspense, useMemo, useRef, memo } from 'react'
import { HashRouter as Router, Routes, Route, Navigate, useLocation, useNavigationType } from 'react-router-dom'
import { AnimatePresence } from 'framer-motion'

import NowPlayingBar from './components/NowPlayingBar'
import Sidebar from './components/Sidebar'
import QueuePanel from './components/QueuePanel'
import { PlayerProvider, usePlayerState, usePlayerActions } from './contexts/PlayerContext'
import { useCanvas } from './hooks/useCanvas'
import { ThemeProvider } from './contexts/ThemeContext'
import { HeroPresenceProvider } from './contexts/HeroPresenceContext'
import { Capacitor } from '@capacitor/core'
import { SidebarProvider } from './contexts/SidebarContext'
import { SettingsProvider } from './contexts/SettingsContext'
import { Header } from './components/Header'
import ServerConnection from './components/ServerConnection'
import { navidromeApi } from './services/navidromeApi'
import { PinnedPlaylistsProvider } from './contexts/PinnedPlaylistsContext'
import { ConnectProvider } from './contexts/ConnectContext'
import Spinner from './components/Spinner'
import PageTransition from './components/PageTransition'
import { useMemoryCleanup } from './hooks/useMemoryCleanup'
import { useAudioBridge } from './hooks/useAudioBridge'
import { useNativeTabBar } from './hooks/useNativeTabBar'
import { useNativeNowPlaying } from './hooks/useNativeNowPlaying'
import TabBar from './components/TabBar'
import OfflineBanner from './components/OfflineBanner'
import NativeBackButton from './components/NativeBackButton'

const NATIVE_ROOT_TABS = new Set(['/', '/artists', '/playlists', '/search', '/audiorr'])
const isNativePlatform = Capacitor.isNativePlatform()

// Páginas de tabs raíz: carga eager para evitar flash de Suspense al cambiar de pestaña
import HomePage from './components/HomePage'
import ArtistsPage from './components/ArtistsPage'
import PlaylistsPage from './components/PlaylistsPage'
import SearchPage from './components/SearchPage'
import AudiorrPage from './components/AudiorrPage'

// Resto de páginas: lazy load (code splitting)
const AlbumsPage = lazy(() => import('./components/AlbumsPage'))
const AlbumDetail = lazy(() => import('./components/AlbumDetail'))
const ArtistsDetail = lazy(() => import('./components/ArtistsDetail'))
const PlaylistDetail = lazy(() => import('./components/PlaylistDetail'))
const SettingsPage = lazy(() => import('./components/SettingsPage'))
const UserProfile = lazy(() => import('./components/UserProfile'))
const LyricsPage = lazy(() => import('./components/LyricsPage'))
const CanvasPage = lazy(() => import('./components/CanvasPage'))
const SongDetail = lazy(() => import('./components/SongDetail'))
const GenresPage = lazy(() => import('./components/GenresPage'))
const GenreDetail = lazy(() => import('./components/GenreDetail'))
const WrappedPage = lazy(() => import('./components/WrappedPage'))
const AdminPage = lazy(() => import('./components/AdminPage'))
const ReceiverPage = lazy(() => import('./components/ReceiverPage').then(m => ({ default: m.ReceiverPage })))

// Componente para redirigir /profile al perfil del usuario actual
function ProfileRedirect() {
  const config = navidromeApi.getConfig()
  if (!config?.username) {
    return <Navigate to="/" replace />
  }
  return <Navigate to={`/user/${config.username}`} replace />
}

// Componente interno que usa useLocation (debe estar dentro del Router)
function AnimatedRoutes() {
  const location = useLocation()
  const previousPathRef = useRef(location.pathname)
  
  // Limpieza de memoria al cambiar de página
  useEffect(() => {
    if (previousPathRef.current !== location.pathname) {
      previousPathRef.current = location.pathname
      
      // Pequeño delay para que la transición termine antes de limpiar
      const cleanupTimeout = setTimeout(() => {
        // Limpiar imágenes que ya no están en el viewport
        const images = document.querySelectorAll('img[loading="lazy"]')
        images.forEach(img => {
          const rect = img.getBoundingClientRect()
          const isOffscreen = rect.bottom < -500 || rect.top > window.innerHeight + 500
          if (isOffscreen && (img as HTMLImageElement).src) {
            // Solo limpiar imágenes muy fuera de pantalla
            const imgEl = img as HTMLImageElement
            imgEl.loading = 'lazy'
          }
        })
      }, 200)
      
      return () => clearTimeout(cleanupTimeout)
    }
  }, [location.pathname])
  
  return (
    <AnimatePresence mode="popLayout" initial={false}>
      <Routes location={location} key={location.pathname}>
        <Route path="/" element={<PageTransition><HomePage /></PageTransition>} />
        <Route path="/albums" element={<PageTransition><AlbumsPage /></PageTransition>} />
        <Route path="/albums/:id" element={<PageTransition><AlbumDetail /></PageTransition>} />
        <Route path="/artists" element={<PageTransition><ArtistsPage /></PageTransition>} />
        <Route path="/artists/:name" element={<PageTransition><ArtistsDetail /></PageTransition>} />
        <Route path="/playlists" element={<PageTransition><PlaylistsPage /></PageTransition>} />
        <Route path="/playlists/:id" element={<PageTransition><PlaylistDetail /></PageTransition>} />
        <Route path="/songs/:id" element={<PageTransition><SongDetail /></PageTransition>} />
        <Route path="/settings" element={<PageTransition><SettingsPage /></PageTransition>} />
        <Route path="/profile" element={<ProfileRedirect />} />
        <Route path="/user/:username" element={<PageTransition><UserProfile /></PageTransition>} />
        <Route path="/genres" element={<PageTransition><GenresPage /></PageTransition>} />
        <Route path="/genre/:genreName" element={<PageTransition><GenreDetail /></PageTransition>} />
        <Route path="/wrapped" element={<PageTransition><WrappedPage /></PageTransition>} />
        <Route path="/admin" element={<PageTransition><AdminPage /></PageTransition>} />
        <Route path="/admin/:tab" element={<PageTransition><AdminPage /></PageTransition>} />
        <Route path="/search" element={<PageTransition><SearchPage /></PageTransition>} />
        <Route path="/audiorr" element={<PageTransition><AudiorrPage /></PageTransition>} />
        <Route path="/receiver" element={<ReceiverPage />} />
      </Routes>
    </AnimatePresence>
  )
}

// Componente memoizado para las rutas - evita re-renders cuando cambia playerState
const RoutesContainer = memo(function RoutesContainer() {
  const location = useLocation()
  const showNativeSpacer = isNativePlatform && !NATIVE_ROOT_TABS.has(location.pathname)
  return (
    // Extra bottom padding en móvil para que la barra flotante + tab bar no tapen el contenido
    <div className="p-4 pb-[200px] md:p-6 md:pb-6 lg:p-8">
      {/* Spacer en iOS nativo para que el botón de volver atrás no tape el contenido */}
      {showNativeSpacer && <div style={{ height: '44px' }} aria-hidden="true" />}
      <Suspense fallback={<div className="flex items-center justify-center h-64"><Spinner size="lg" /></div>}>
        <AnimatedRoutes />
      </Suspense>
    </div>
  )
})


function App() {
  const [isConnected, setIsConnected] = useState(() => !!navidromeApi.getConfig())

  if (!isConnected) {
    return <ServerConnection onConnected={() => setIsConnected(true)} />
  }

  return (
    <ThemeProvider>
      <HeroPresenceProvider>
        <Router>
          <SettingsProvider>
            <PlayerProvider>
              <ConnectProvider>
                <PinnedPlaylistsProvider>
                  <SidebarProvider>
                    <MainApp />
                  </SidebarProvider>
                </PinnedPlaylistsProvider>
              </ConnectProvider>
            </PlayerProvider>
          </SettingsProvider>
        </Router>
      </HeroPresenceProvider>
    </ThemeProvider>
  )
}

function MainApp() {
  const [showQueue, setShowQueue] = useState(false)
  const [showLyrics, setShowLyrics] = useState(false)
  const [showCanvas, setShowCanvas] = useState(false)
  const playerState = usePlayerState()
  const playerActions = usePlayerActions()
  const location = useLocation()
  const navigationType = useNavigationType()
  const mainContentRef = useRef<HTMLDivElement>(null)

  // Solo reset scroll al navegar hacia adelante (PUSH/REPLACE), no al ir atrás (POP)
  useEffect(() => {
    if (navigationType !== 'POP' && mainContentRef.current) {
      mainContentRef.current.scrollTo(0, 0)
    }
  }, [location.pathname, navigationType])

  // Bridge nativo: pantalla de bloqueo, auriculares, CarPlay
  useAudioBridge()
  // Tab bar nativa de iOS (UITabBar con SF Symbols, UIBlurEffect, haptics)
  useNativeTabBar()
  // Mini-player nativo de iOS (UIBlurEffect real, SF Symbols, haptics)
  useNativeNowPlaying()

  // Control de memoria - limpieza periódica y al cambiar de visibilidad
  useMemoryCleanup({
    cleanupInterval: 120000, // Cada 2 minutos
    memoryThreshold: 400, // 400MB umbral para limpieza agresiva
    onCleanup: () => {
      // Limpieza adicional específica de la app
      playerActions.clearMemoryCache?.()
    },
    debug: import.meta.env.DEV, // Solo en desarrollo
  })

  // Actualizar título de la página con la canción actual
  const currentSong = playerState.currentSong
  const isPlaying = playerState.isPlaying
  
  useEffect(() => {
    if (currentSong && isPlaying) {
      document.title = `${currentSong.title} - ${currentSong.artist} | Audiorr`
    } else if (currentSong) {
      // Pausado pero con canción seleccionada
      document.title = `⏸ ${currentSong.title} - ${currentSong.artist} | Audiorr`
    } else {
      document.title = 'Audiorr'
    }

    // Restaurar título al desmontar
    return () => {
      document.title = 'Audiorr'
    }
  }, [currentSong, isPlaying])

  // Memoizar currentSong para evitar recreaciones innecesarias
  const currentSongForCanvas = useMemo(() => {
    if (!playerState.currentSong) return null
    return {
      id: playerState.currentSong.id,
      title: playerState.currentSong.title,
      artist: playerState.currentSong.artist,
      album: playerState.currentSong.album,
      duration: playerState.currentSong.duration,
      path: playerState.currentSong.path,
      coverArt: playerState.currentSong.coverArt,
      albumId: playerState.currentSong.albumId,
    }
  }, [playerState.currentSong])

  // Obtener Canvas para la canción actual
  const { canvasUrl, isLoading: isLoadingCanvas } = useCanvas(currentSongForCanvas)

  // Refs para gestionar el auto-open/close del Canvas
  const previousCanvasUrlRef = useRef<string | null>(null)
  const previousSongIdRef = useRef<string | null>(null)
  const closeCanvasTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Gestionar apertura/cierre automático del panel de Canvas
  useEffect(() => {
    const currentSongId = playerState.currentSong?.id || null

    // Si cambió la canción, resetear las referencias
    if (currentSongId !== previousSongIdRef.current) {
      previousSongIdRef.current = currentSongId
      previousCanvasUrlRef.current = null
      if (closeCanvasTimeoutRef.current) {
        clearTimeout(closeCanvasTimeoutRef.current)
        closeCanvasTimeoutRef.current = null
      }
    }

    // Cerrar automáticamente si no hay Canvas disponible (con debounce)
    if (showCanvas && !isLoadingCanvas && !canvasUrl) {
      if (!closeCanvasTimeoutRef.current) {
        closeCanvasTimeoutRef.current = setTimeout(() => {
          setShowCanvas(false)
          closeCanvasTimeoutRef.current = null
        }, 500)
      }
    } else if (canvasUrl && closeCanvasTimeoutRef.current) {
      // Si el canvas vuelve a estar disponible, cancelar el cierre pendiente
      clearTimeout(closeCanvasTimeoutRef.current)
      closeCanvasTimeoutRef.current = null
    }

    // Abrir automáticamente si se detecta un Canvas disponible y la ventana no está abierta
    // En app nativa iOS el viewer maneja el canvas internamente — no abrir el panel lateral
    if (
      !showCanvas &&
      !isLoadingCanvas &&
      canvasUrl &&
      previousCanvasUrlRef.current !== canvasUrl &&
      !Capacitor.isNativePlatform()
    ) {
      setShowCanvas(true)
    }

    // Actualizar la referencia del canvasUrl anterior
    if (!isLoadingCanvas) {
      previousCanvasUrlRef.current = canvasUrl
    }

    return () => {
      if (closeCanvasTimeoutRef.current) {
        clearTimeout(closeCanvasTimeoutRef.current)
      }
    }
  }, [canvasUrl, isLoadingCanvas, showCanvas, playerState.currentSong?.id])

  const handleToggleLyrics = () => {
    setShowLyrics(!showLyrics)
  }

  const handleToggleCanvas = () => {
    setShowCanvas(!showCanvas)
  }

  return (
    <div className="h-screen flex flex-col bg-gray-100 dark:bg-gray-800 font-sans">
      <OfflineBanner />
      {/* Botón nativo de volver atrás — solo en iOS/Android, páginas de detalle */}
      <NativeBackButton />
      {/* TabBar: navegación nativa iOS/móvil (reemplaza el menú hamburguesa) */}
      <TabBar />
      <div className="flex flex-1 overflow-hidden">
        <Sidebar />
        <main className="flex-1 flex flex-col overflow-hidden">
          {/* Safe area spacer para móvil — el Header está hidden en mobile */}
          <div className="flex-shrink-0 md:hidden" style={{ height: 'env(safe-area-inset-top)' }} />
          {/* Header solo visible en desktop (md+) */}
          <Header />
          <div className="flex-1 flex overflow-hidden">
            {/* En móvil: Canvas ocupa todo el espacio si está abierto */}
            {showCanvas ? (
              <div className="flex-1 flex flex-col overflow-hidden md:hidden">
                <Suspense fallback={<div className="flex items-center justify-center h-full"><Spinner size="lg" /></div>}>
                  <CanvasPage
                    onClose={handleToggleCanvas}
                    canvasUrl={canvasUrl}
                    isLoading={isLoadingCanvas}
                    songTitle={playerState.currentSong?.title}
                    songArtist={playerState.currentSong?.artist}
                  />
                </Suspense>
              </div>
            ) : null}

            {/* Contenido principal - Lyrics o rutas normales (siempre visible en desktop, oculto en móvil si Canvas está abierto) */}
            <div
              ref={mainContentRef}
              className={`flex-1 overflow-y-auto overflow-x-hidden overscroll-none transition-all duration-300 min-w-0 ${showCanvas ? 'hidden md:block' : ''}`}
            >
              {showLyrics ? (
                <Suspense fallback={<div className="flex items-center justify-center h-full"><Spinner size="lg" /></div>}>
                  <LyricsPage onClose={handleToggleLyrics} />
                </Suspense>
              ) : (
                <RoutesContainer />
              )}
            </div>

            {/* Panel de Canvas - aparece a la derecha cuando está abierto (solo desktop) */}
            {showCanvas && (
              <div className="hidden md:flex w-[420px] flex-shrink-0 border-l border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-900 flex-col overflow-hidden">
                <Suspense fallback={<div className="flex items-center justify-center h-full"><Spinner size="lg" /></div>}>
                  <CanvasPage
                    onClose={handleToggleCanvas}
                    canvasUrl={canvasUrl}
                    isLoading={isLoadingCanvas}
                    songTitle={playerState.currentSong?.title}
                    songArtist={playerState.currentSong?.artist}
                  />
                </Suspense>
              </div>
            )}
          </div>
        </main>
        <QueuePanel
          isOpen={showQueue}
          onClose={() => setShowQueue(false)}
          queue={playerState.queue}
          currentSong={playerState.currentSong}
          onPlaySong={playerActions.playSong}
          onRemoveSong={playerActions.removeFromQueue}
          onClearQueue={playerActions.clearQueue}
          onReorderQueue={playerActions.reorderQueue}
        />
      </div>

      <NowPlayingBar
        onShowQueue={() => setShowQueue(!showQueue)}
        onToggleLyrics={handleToggleLyrics}
        showLyrics={showLyrics}
        onToggleCanvas={handleToggleCanvas}
        showCanvas={showCanvas}
      />
    </div>
  )
}

export default App
