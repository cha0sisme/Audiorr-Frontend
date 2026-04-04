import { useState, useEffect, lazy, Suspense, useMemo, useRef } from 'react'
import { HashRouter as Router } from 'react-router-dom'

import NowPlayingBar from './components/NowPlayingBar'
import Sidebar from './components/Sidebar'
import QueuePanel from './components/QueuePanel'
import { PlayerProvider, usePlayerState, usePlayerActions } from './contexts/PlayerContext'
import { useCanvas } from './hooks/useCanvas'
import { ThemeProvider } from './contexts/ThemeContext'
import { HeroPresenceProvider, useHeroPresence } from './contexts/HeroPresenceContext'
import { Capacitor } from '@capacitor/core'
import { SidebarProvider } from './contexts/SidebarContext'
import { SettingsProvider } from './contexts/SettingsContext'
import { Header } from './components/Header'
import ServerConnection from './components/ServerConnection'
import { navidromeApi } from './services/navidromeApi'
import { PinnedPlaylistsProvider } from './contexts/PinnedPlaylistsContext'
import { ConnectProvider } from './contexts/ConnectContext'
import { BackendAvailableProvider } from './contexts/BackendAvailableContext'
import Spinner from './components/Spinner'
import NavigationStack from './components/NavigationStack'
import { useMemoryCleanup } from './hooks/useMemoryCleanup'
import { useAudioBridge } from './hooks/useAudioBridge'
import { useNativeTabBar } from './hooks/useNativeTabBar'
import { useNativeNowPlaying } from './hooks/useNativeNowPlaying'
import TabBar from './components/TabBar'
import OfflineBanner from './components/OfflineBanner'
import NativeBackButton from './components/NativeBackButton'

// Overlay pages (not routed — toggled in MainApp)
const LyricsPage = lazy(() => import('./components/LyricsPage'))
const CanvasPage = lazy(() => import('./components/CanvasPage'))

function App() {
  const [isConnected, setIsConnected] = useState(() => !!navidromeApi.getConfig())

  if (!isConnected) {
    return <ServerConnection onConnected={() => setIsConnected(true)} />
  }

  return (
    <ThemeProvider>
      <HeroPresenceProvider>
        <Router>
          <BackendAvailableProvider>
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
          </BackendAvailableProvider>
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

  const { heroPresent } = useHeroPresence()

  return (
    <div className={`h-screen flex flex-col bg-gray-50 dark:bg-[#121212] font-sans selection:bg-blue-500/30`}>
      <OfflineBanner />
      {/* Botón nativo de volver atrás — siempre visible y encima de todo */}
      <NativeBackButton />
      {/* TabBar: navegación nativa iOS/móvil (reemplaza el menú hamburguesa) */}
      <TabBar />
      
      {/* Contenedor principal sin paddings restrictivos */}
      <div className="flex flex-1 overflow-hidden relative">
        <Sidebar />
        <main className="flex-1 flex flex-col overflow-hidden relative">
          {/* Solo si NO hay Hero, añadimos un espaciador para no tapar contenido debajo del notch. 
              En iOS nativo con viewport-fit=cover, el body ocupa todo el espacio. */}
          {/* Overlay suave estilo Apple Music para el notch cuando NO hay Hero. 
              Es pegajoso y translúcido, permitiendo que el contenido se vea por debajo al scrollear. */}
          {!heroPresent && (
            <div 
              className="absolute top-0 left-0 right-0 z-[100] md:hidden bg-transparent pointer-events-none" 
              style={{ height: 'env(safe-area-inset-top, 20px)' }} 
            />
          )}
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
              className={`flex-1 relative overflow-hidden transition-all duration-300 min-w-0 ${showCanvas ? 'hidden md:block' : ''}`}
            >
              {showLyrics ? (
                <div className="absolute inset-0 overflow-y-auto overflow-x-hidden overscroll-none">
                  <Suspense fallback={<div className="flex items-center justify-center h-full"><Spinner size="lg" /></div>}>
                    <LyricsPage onClose={handleToggleLyrics} />
                  </Suspense>
                </div>
              ) : (
                <NavigationStack />
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
