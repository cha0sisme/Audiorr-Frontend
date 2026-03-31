import {
  createContext,
  useContext,
  useState,
  useEffect,
  useRef,
  ReactNode,
  useMemo,
  useCallback,
} from 'react'
import { Capacitor } from '@capacitor/core'
import { navidromeApi, type Song } from '../services/navidromeApi'
import { useAudioAnalysis, type AudioAnalysisResult } from '../hooks/useAudioAnalysis'
import { useSettings } from './SettingsContext'
import { AnalyzedSong, sortSongs } from '../utils/smartMixUtils'
import { analysisQueue, AnalysisPriority } from '../services/analysisQueue'
import { backendApi } from '../services/backendApi'
import { WebAudioPlayer } from '../services/webAudioPlayer'
import { NativeAudioPlayer } from '../services/nativeAudioPlayer'
import { nativeAudio } from '../services/nativeAudio'
import { calculateCrossfadeConfig } from '../services/audio/DJMixingAlgorithms'
import { queuePrefetcher } from '../services/queuePrefetcher'
import { streamRetryManager } from '../services/streamRetry'

// En iOS nativo, HTMLAudioElement.volume es de solo lectura (iOS lo ignora).
// Esto afecta al crossfade basado en volumen: ambas canciones suenan simultáneamente.
const IS_NATIVE = Capacitor.isNativePlatform()

/** Devuelve una clave de localStorage prefijada con el username para aislar estado entre usuarios */
function userKey(key: string): string {
  const username = navidromeApi.getConfig()?.username
  return username ? `${key}_${username}` : key
}

// --- NUEVA FUNCIÓN HELPER para generar un ID de caché estable ---
function generateStableCacheId(song: Song): string {
  return song.id
}

export type SmartMixStatus = 'idle' | 'analyzing' | 'ready' | 'error'

export interface AnalysisProgress {
  total: number
  completed: number
  currentSongId: string | null
  currentSongTitle: string | null
}

// --- Tipos de los diferentes contextos ---

export interface PlayerStateType {
  currentSong: {
    title: string
    artist: string
    album: string
    coverArt?: string
    duration: number
    id: string
    path: string
    albumId?: string
    playlistId?: string
  } | null
  currentSource: string | null
  isPlaying: boolean
  volume: number
  queue: Song[]
  isCrossfading: boolean
  crossfadeDuration: number
  analysisCacheRef: React.MutableRefObject<Map<string, AudioAnalysisResult | { error: string }>>
  isAnalyzing: boolean
  analysisProgress: AnalysisProgress
  smartMixStatus: SmartMixStatus
  smartMixPlaylistId: string | null
  generatedSmartMix: AnalyzedSong[]
  isReconnecting: boolean
}

interface PlayerProgressType {
  progress: number
  duration: number
}

interface PlayerActionsType {
  setVolume: (volume: number) => void
  playSong: (song: Song, keepPosition?: boolean) => void
  playAlbum: (albumId: string) => void
  playPlaylist: (songs: Song[], contextUri?: string | null) => void
  playPlaylistFromSong: (songs: Song[], startSong: Song, contextUri?: string | null) => void
  playSongAtPosition: (songs: Song[], startSong: Song, position: number, autoPlay?: boolean) => void
  removeFromQueue: (songId: string) => void
  clearQueue: () => void
  reorderQueue: (newOrder: Song[]) => void
  addToQueue: (song: Song) => void
  togglePlayPause: () => void
  seek: (time: number) => void
  next: () => void
  previous: () => void
  startPlaylistAnalysis: (songs: Song[]) => void
  clearMemoryCache: () => void
  generateSmartMix: (playlistId: string, songs: Song[]) => Promise<void>
  playGeneratedSmartMix: () => void
  clearSmartMix: () => void
  checkCachedSmartMix: (playlistId: string, signature: string) => void
  autoCheckSmartMix: (playlistId: string, songs: Song[]) => Promise<void>
  registerRemoteHandlers: (handlers: RemoteHandlers | null) => void
  setScrobblingSuppressed: (disabled: boolean) => void
  setScrobbleCallback: (fn: ((data: ScrobbleEventData) => void) | null) => void
  setCurrentContextUri: (uri: string | null) => void
}

export interface ScrobbleEventData {
  songId: string
  title: string
  artist: string
  album: string
  albumId?: string
  duration: number
  playedAt: string
  year?: number
  genre?: string
  contextUri?: string | null
}

export interface RemoteHandlers {
  playSong?: (song: Song, queue: Song[]) => void
  playPlaylist?: (songs: Song[]) => void
  togglePlayPause?: () => void
  seek?: (time: number) => void
  next?: () => void
  previous?: () => void
  setVolume?: (volume: number) => void
}

// --- Creación de los contextos ---

const PlayerStateContext = createContext<PlayerStateType | undefined>(undefined)
const PlayerProgressContext = createContext<PlayerProgressType | undefined>(undefined)
const PlayerActionsContext = createContext<PlayerActionsType | undefined>(undefined)

// --- Utilidades de localStorage (quota-safe) ---

/** Solo los campos mínimos de un Song necesarios para restaurar la reproducción */
function minimalSong(song: Song): Song {
  return {
    id: song.id,
    title: song.title,
    artist: song.artist,
    album: song.album,
    albumId: song.albumId,
    duration: song.duration,
    coverArt: song.coverArt,
    path: song.path,
    track: song.track,
    year: song.year,
    genre: song.genre,
  }
}

/** Para el caché de smart mix solo necesitamos las canciones en orden (sin datos de análisis).
 *  La reproducción solo usa los campos básicos de Song; el análisis puede re-obtenerse de la DB si hace falta. */
function minimalSmartMixSongs(sorted: Song[]): Song[] {
  return sorted.map(minimalSong)
}

/** Elimina entradas antiguas de smart mix (prefijo `smartMix_`) para liberar espacio.
 *  Mantiene hasta `keep` entradas más recientes (por timestamp en el valor). */
function evictSmartMixCaches(exceptKey?: string) {
  try {
    const keys = Object.keys(localStorage).filter(k => k.startsWith('smartMix_'))
    // Eliminar todas salvo la que acabamos de guardar
    keys.forEach(k => {
      if (k !== exceptKey) localStorage.removeItem(k)
    })
  } catch { /* ignorar */ }
}

/** Wrapper seguro para localStorage.setItem que intenta liberar espacio en caso de QuotaExceededError */
function safeSetItem(key: string, value: string) {
  try {
    localStorage.setItem(key, value)
  } catch (e) {
    if (e instanceof DOMException && e.name === 'QuotaExceededError') {
      // Liberar entradas de smart mix antiguas y reintentar una vez
      evictSmartMixCaches(key)
      try {
        localStorage.setItem(key, value)
      } catch {
        // Si sigue sin caber, ignorar silenciosamente
        console.warn('[localStorage] Quota excedida incluso tras limpiar. Entrada no guardada:', key)
      }
    }
  }
}

// --- Provider Component ---
export function PlayerProvider({ children }: { children: ReactNode }) {
  // --- Estado para la canción actual (con persistencia) ---
  const [currentSong, setCurrentSong] = useState<PlayerStateType['currentSong']>(() => {
    try {
      if (typeof localStorage !== 'undefined') {
        const savedSong = localStorage.getItem(userKey('playerCurrentSong'))
        return savedSong ? JSON.parse(savedSong) : null
      }
    } catch (e) {
      console.error('Failed to restore playerCurrentSong', e)
    }
    return null
  })

  const remoteHandlersRef = useRef<RemoteHandlers | null>(null)
  const registerRemoteHandlers = useCallback((handlers: RemoteHandlers | null) => {
    remoteHandlersRef.current = handlers
  }, [])

  const [isPlaying, setIsPlaying] = useState(false)
  // Loading guard: true while playSong() is awaiting native play().
  // Prevents togglePlayPause/seek from creating conflicting state during load.
  const isLoadingRef = useRef(false)

  // --- Estado para progreso (con persistencia) ---
  const [progress, setProgress] = useState(() => {
    try {
      if (typeof localStorage !== 'undefined') {
        const savedProgress = localStorage.getItem(userKey('playerProgress'))
        return savedProgress ? parseFloat(savedProgress) : 0
      }
      return 0
    } catch (error) {
      console.error('Error reading progress from localStorage', error)
      return 0
    }
  })
  const [duration, setDuration] = useState(() => {
    try {
      if (typeof localStorage !== 'undefined') {
        const savedSong = localStorage.getItem(userKey('playerCurrentSong'))
        const parsedSong = savedSong ? JSON.parse(savedSong) : null
        return parsedSong?.duration || 0
      }
      return 0
    } catch (error) {
      return 0
    }
  })
  // Volumen fijo al máximo — se controla desde el sistema operativo
  const [volume] = useState(100)
  const [isCrossfading, setIsCrossfading] = useState(false)
  const [crossfadeDuration, setCrossfadeDuration] = useState(8)
  const [isReconnecting, setIsReconnecting] = useState(false)
  const [currentSource, setCurrentSource] = useState<string | null>(() => {
    try {
      if (typeof localStorage !== 'undefined') {
        return localStorage.getItem(userKey('playerSource'))
      }
      return null
    } catch (error) {
      return null
    }
  })

  const [queueState, setQueueState] = useState<Song[]>(() => {
    try {
      if (typeof localStorage !== 'undefined') {
        const savedQueue = localStorage.getItem(userKey('playerQueue'))
        return savedQueue ? JSON.parse(savedQueue) : []
      }
      return []
    } catch (error) {
      console.error('Error reading queue from localStorage', error)
      return []
    }
  })

  // --- Estado para Smart Mix ---
  const [smartMixStatus, setSmartMixStatus] = useState<SmartMixStatus>('idle')
  const [smartMixPlaylistId, setSmartMixPlaylistId] = useState<string | null>(null)
  const [generatedSmartMix, setGeneratedSmartMix] = useState<AnalyzedSong[]>([])
  const [smartMixTimestamp, setSmartMixTimestamp] = useState<number | null>(null)
  // Refs para leer estado en callbacks con deps vacías
  const smartMixStatusRef = useRef<SmartMixStatus>('idle')
  smartMixStatusRef.current = smartMixStatus
  const smartMixPlaylistIdRef = useRef<string | null>(null)
  smartMixPlaylistIdRef.current = smartMixPlaylistId

  // --- Lógica de la Cola de Análisis (ahora manejada por analysisQueue) ---
  const [isAnalyzing] = useState(false)
  const [analysisProgress] = useState<AnalysisProgress>({
    total: 0,
    completed: 0,
    currentSongId: null,
    currentSongTitle: null,
  })
  // --- Refs ---
  const audioRef = useRef<HTMLAudioElement | null>(null)
  const nextAudioRef = useRef<HTMLAudioElement | null>(null)
  const webAudioPlayerRef = useRef<WebAudioPlayer | NativeAudioPlayer | null>(null)
  const currentSongRef = useRef<Song | null>(currentSong)
  const queueRef = useRef<Song[]>(queueState)
  const currentSourceRef = useRef<string | null>(currentSource)
  const isCrossfadingRef = useRef(false)
  const crossfadeStartTimeRef = useRef(0) // Timestamp de inicio del crossfade para timeout de seguridad
  const lastPauseTimeRef = useRef(0)
  const volumeRef = useRef(volume)
  const analysisCacheRef = useRef<Map<string, AudioAnalysisResult | { error: string }>>(new Map())
  const outroRefinedForCurrentSongRef = useRef(false)
  const automixTriggerSentRef = useRef(false) // true cuando ya enviamos trigger a nativo para esta canción
  // Play sequence counter: prevents stale async play() results from corrupting state
  // when the user taps multiple songs rapidly. Only the latest playSong() call matters.
  const playSongSequenceRef = useRef(0)
  const nextCallbackRef = useRef<(forAutomix?: boolean) => void>()
  const timeUpdateHandlerRef = useRef<() => void>()
  const endedHandlerRef = useRef<() => void>()
  const loadedMetadataHandlerRef = useRef<() => void>()
  const errorHandlerRef = useRef<((event: Event) => void) | null>(null)
  const stalledHandlerRef = useRef<(() => void) | null>(null)
  const isResettingAudioRef = useRef(false)
  const crossfadeDurationRef = useRef(8) // Default crossfade duration
  // ⚡ PERFORMANCE: Refs para optimizar actualizaciones de progreso
  const progressRef = useRef(progress) // Progreso real en tiempo real (para cálculos)
  const streamOffsetRef = useRef(0) // timeOffset del stream actual (para streams HTML Audio con transcodificación)
  const lastProgressUpdateRef = useRef(0) // Última vez que actualizamos el estado (throttling)
  // Ref para rastrear qué canciones ya han sido scrobbeadas en esta sesión
  // Usamos un Map para rastrear también el tiempo de inicio de reproducción
  const scrobbledSongsRef = useRef<Map<string, { scrobbled: boolean; startTime: number; wrappedScrobbled: boolean }>>(
    new Map()
  )
  const scrobblingDisabledRef = useRef(false)
  const scrobbleCallbackRef = useRef<((data: ScrobbleEventData) => void) | null>(null)
  const currentContextUriRef = useRef<string | null>(null)

  // --- Hooks ---
  const { settings } = useSettings()
  const { analyze } = useAudioAnalysis()

  // --- Helper: determinar qué sistema de audio usar ---
  // En iOS nativo, siempre usamos NativeAudioPlayer (que comparte interfaz con WebAudioPlayer)
  const shouldUseWebAudio = useCallback(() => IS_NATIVE || settings.useWebAudio, [settings.useWebAudio])

  // --- Helper para actualizar Media Session ---
  const updateMediaSession = useCallback(
    (song: PlayerStateType['currentSong'], isPlayingState: boolean) => {
      // En nativo, Swift controla MPNowPlayingInfoCenter directamente.
      // Tocar navigator.mediaSession desde WKWebView causa que WebKit registre
      // sus propios handlers en MPRemoteCommandCenter, conflictuando con los nativos.
      if (IS_NATIVE) return

      if (typeof navigator === 'undefined' || !('mediaSession' in navigator)) {
        return
      }

      const metadataInit: MediaMetadataInit = song
        ? {
            title: song.title,
            artist: song.artist,
            album: song.album,
            artwork:
              song.coverArt && song.coverArt.length > 0
                ? [
                    {
                      src: navidromeApi.getCoverUrl(song.coverArt),
                      sizes: '512x512',
                    },
                  ]
                : [],
          }
        : {
            title: '',
            artist: '',
            album: '',
            artwork: [],
          }

      try {
        navigator.mediaSession.metadata = new MediaMetadata(metadataInit)
      } catch (error) {
        console.warn('[MediaSession] Metadata not supported:', error)
      }

      try {
        navigator.mediaSession.playbackState = isPlayingState ? 'playing' : 'paused'
      } catch (error) {
        console.warn('[MediaSession] Playback state not supported:', error)
      }

      if (song?.duration && song.duration > 0) {
        try {
          const pos = Math.min(progressRef.current, song.duration)
          navigator.mediaSession.setPositionState({
            duration: song.duration,
            playbackRate: isPlayingState ? 1 : 0,
            position: pos,
          })
        } catch {
          // setPositionState no soportado en algunos navegadores
        }
      }
    },
    []
  )

  // =================================================================================
  // INICIO: BLOQUE DE FUNCIONES REESTRUCTURADO
  // =================================================================================

  // --- FUNCIONES CORE Y SMART MIX (agrupadas al inicio) ---
  const clearMemoryCache = useCallback(() => {
    // Ya no limpiamos `analysisCacheRef` entero porque contiene datos muy ligeros
    // (metadatos y números cortos) necesarios para la generación de SmartMix.
    // Limpiarlo cancelaba silenciosamente la generación en segundo plano si 
    // el usuario cambiaba de pestaña durante el proceso de análisis.
    
    // Liberar memoria no esencial del reproductor de audio (buffers pesados)
    if (shouldUseWebAudio() && webAudioPlayerRef.current) {
      webAudioPlayerRef.current.releaseNonEssentialMemory()
    }
    
    // Sugerir GC
    if (typeof window !== 'undefined' && 'gc' in window) {
      try {
        (window as Window & { gc?: () => void }).gc?.()
      } catch { /* ignorar */ }
    }
  }, [shouldUseWebAudio])

  const updateQueue = useCallback((newQueue: Song[]) => {
    queueRef.current = newQueue
    setQueueState([...newQueue])
    safeSetItem(userKey('playerQueue'), JSON.stringify(newQueue.map(minimalSong)))
  }, [])

  const updateSource = useCallback((source: string | null) => {
    currentSourceRef.current = source
    setCurrentSource(source)
    if (typeof localStorage !== 'undefined') {
      if (source) {
        localStorage.setItem(userKey('playerSource'), source)
      } else {
        localStorage.removeItem(userKey('playerSource'))
      }
    }
    console.log(`[PlayerContext] Source actualizado: ${source}`)
  }, [])

  const checkCachedSmartMix = useCallback((playlistId: string, signature: string) => {
    if (!playlistId || typeof window === 'undefined') return
    try {
      let cachedItem: string | null = null
      
      if (signature === 'fast_check') {
        // En el chequeo rápido, buscamos cualquier entrada que empiece por el ID de la playlist
        const keys = Object.keys(localStorage)
        const match = keys.find(k => k.startsWith(`smartMix_${playlistId}_`))
        if (match) cachedItem = localStorage.getItem(match)
      } else {
        const cacheKey = `smartMix_${playlistId}_${signature}`
        cachedItem = localStorage.getItem(cacheKey)
      }

      if (cachedItem) {
        const parsed = JSON.parse(cachedItem)
        if (parsed && parsed.songs && parsed.songs.length > 0) {
          setSmartMixPlaylistId(playlistId)
          setGeneratedSmartMix(parsed.songs)
          setSmartMixStatus('ready')
          setSmartMixTimestamp(parsed.timestamp || Date.now())
          console.log(`[SMART MIX] ♻️ Caché persistida detectada y restaurada (${signature}): ${parsed.songs.length} canciones`)
        }
      }
    } catch (e) {
      console.warn('Error leyendo SmartMix persistente', e)
    }
  }, [])

  const clearSmartMix = useCallback(() => {
    setSmartMixStatus('idle')
    setGeneratedSmartMix([])
    setSmartMixPlaylistId(null)
    setSmartMixTimestamp(null)
  }, [])

  /**
   * Comprueba automáticamente si una playlist ya tiene todas sus canciones analizadas en la DB.
   * Si las tiene (o están en localStorage), prepara la SmartMix y muestra el botón
   * "Reproducir SmartMix" sin que el usuario tenga que hacer nada.
   * NO inicia la reproducción, NO encola análisis pendientes.
   */
  const autoCheckSmartMix = useCallback(async (playlistId: string, songs: Song[]) => {
    if (!playlistId || songs.length === 0) return
    // Si ya está procesando o lista para esta playlist, no hacer nada
    if (smartMixPlaylistIdRef.current === playlistId && smartMixStatusRef.current !== 'idle') return

    const signature = `${songs.length}_${songs[0].id}_${songs[Math.floor(songs.length / 2)].id}_${songs[songs.length - 1].id}`

    // 1. Comprobar localStorage (instantáneo) — primero con la firma exacta, luego con prefijo
    try {
      const exactKey = `smartMix_${playlistId}_${signature}`
      const exactItem = localStorage.getItem(exactKey)
      if (exactItem) {
        const parsed = JSON.parse(exactItem)
        if (parsed?.songs?.length > 0) {
          setSmartMixPlaylistId(playlistId)
          setGeneratedSmartMix(parsed.songs)
          setSmartMixStatus('ready')
          setSmartMixTimestamp(parsed.timestamp || Date.now())
          return
        }
      }
      // Búsqueda por prefijo (si la firma exacta difiere, p.ej. orden de canciones cambió)
      const prefixKey = `smartMix_${playlistId}_`
      const match = Object.keys(localStorage).find(k => k.startsWith(prefixKey))
      if (match) {
        const item = localStorage.getItem(match)
        if (item) {
          const parsed = JSON.parse(item)
          if (parsed?.songs?.length > 0) {
            setSmartMixPlaylistId(playlistId)
            setGeneratedSmartMix(parsed.songs)
            setSmartMixStatus('ready')
            setSmartMixTimestamp(parsed.timestamp || Date.now())
            return
          }
        }
      }
    } catch (e) {
      console.warn('[AUTO SMART MIX] Error leyendo localStorage:', e)
    }

    // 2. Consultar la DB del backend para ver si todas las canciones están analizadas
    try {
      const songIds = songs.map(s => generateStableCacheId(s))
      const bulkResults = await backendApi.getBulkAnalysisStatus(songIds)
      const analyzedCount = Object.keys(bulkResults).length

      if (analyzedCount < songs.length) return // No están todas → el usuario decide cuándo analizar

      // ¡Todas analizadas! Cargar en caché y generar el mix ordenado
      Object.entries(bulkResults).forEach(([id, analysis]) => {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        analysisCacheRef.current.set(id, analysis as any)
      })

      const orderedSongs = songs.map(song => {
        const cacheId = generateStableCacheId(song)
        const analysis = analysisCacheRef.current.get(cacheId)
        return { ...song, analysis }
      }) as AnalyzedSong[]

      const sorted = sortSongs(orderedSongs)

      setSmartMixPlaylistId(playlistId)
      setGeneratedSmartMix(sorted)
      setSmartMixStatus('ready')
      setSmartMixTimestamp(Date.now())

      // Guardar en localStorage para la próxima vez (solo campos mínimos, sin datos de análisis)
      const cacheKey = `smartMix_${playlistId}_${signature}`
      evictSmartMixCaches(cacheKey)
      safeSetItem(cacheKey, JSON.stringify({
        timestamp: Date.now(),
        songs: minimalSmartMixSongs(sorted),
      }))

      console.log(`[AUTO SMART MIX] ✅ ${sorted.length} canciones listas en DB → botón habilitado automáticamente`)
    } catch (e) {
      // Silencioso: si el backend no responde, el usuario puede iniciar el análisis manualmente
    }
  }, [])

  const generateSmartMix = useCallback(
    async (playlistId: string, songs: Song[]) => {
      setSmartMixStatus('analyzing')
      setSmartMixPlaylistId(playlistId)
      setGeneratedSmartMix([])
      
      const generateSignature = (s: Song[]) => {
        if (!s || s.length === 0) return 'empty'
        return `${s.length}_${s[0].id}_${s[Math.floor(s.length / 2)].id}_${s[s.length - 1].id}`
      }
      const signature = generateSignature(songs)

      try {
        const cacheKey = `smartMix_${playlistId}_${signature}`
        const cachedItem = localStorage.getItem(cacheKey)
        if (cachedItem) {
           const parsed = JSON.parse(cachedItem)
           if (parsed && parsed.songs && parsed.songs.length > 0) {
              setGeneratedSmartMix(parsed.songs)
              setSmartMixStatus('ready')
              setSmartMixTimestamp(Date.now()) // Refresh timestamp to avoid instant 30m eviction
              console.log(`[SMART MIX] ✅ Mezcla cargada en instantes desde la caché local persistente: ${parsed.songs.length} canciones`)
              return
           }
        }
      } catch (e) {
        console.warn('Error leyendo SmartMix de LocalStorage', e)
      }

      console.log(`[SMART MIX] Encolando análisis de ${songs.length} canciones...`)
      
      try {
        // Encolar todas las canciones que necesitan análisis
        const songsToAnalyze: Song[] = []
        const cacheIdsNeeded: string[] = []
        
        songs.forEach(song => {
          const cacheId = generateStableCacheId(song)
          const cached = analysisCacheRef.current.get(cacheId)
          if (!cached || ('error' in cached)) {
            cacheIdsNeeded.push(cacheId)
          }
        })

        if (cacheIdsNeeded.length > 0) {
          console.log(`[SMART MIX] Consultando backend para ${cacheIdsNeeded.length} canciones...`)
          try {
            const bulkResults = await backendApi.getBulkAnalysisStatus(cacheIdsNeeded)
            Object.entries(bulkResults).forEach(([id, analysis]) => {
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              analysisCacheRef.current.set(id, analysis as any)
            })
            console.log(`[SMART MIX] ${Object.keys(bulkResults).length} recuperadas directo de la DB`)
          } catch (e) {
            console.warn('[SMART MIX] Error consultando backend bulk status:', e)
          }
        }

        songs.forEach(song => {
          const cacheId = generateStableCacheId(song)
          const cached = analysisCacheRef.current.get(cacheId)
          if (!cached || ('error' in cached)) {
            // Mantiene la necesidad de análisis si tampoco estaba en DB
            songsToAnalyze.push(song)
            if (!analysisQueue.has(cacheId)) {
              const streamUrl = navidromeApi.getStreamUrl(song.id, song.path)
              analysisQueue.enqueue({
                id: `smartmix-${song.id}`,
                songId: cacheId,
                songTitle: song.title,
                streamUrl,
                priority: AnalysisPriority.LOW,
                isProactive: true,
              })
            }
          }
        })
        
        console.log(`[SMART MIX] ${songs.length - songsToAnalyze.length} en caché, ${songsToAnalyze.length} encoladas`)
        
        // Polling para verificar cuando todas estén listas
        if (songsToAnalyze.length > 0) {
          const checkInterval = setInterval(() => {
            const allReadyOrFailed = songsToAnalyze.every(song => {
              const cacheId = generateStableCacheId(song)
              return analysisCacheRef.current.has(cacheId)
            })
            
            if (allReadyOrFailed) {
              clearInterval(checkInterval)
              
              const orderedAnalyzedSongs = songs.map(song => {
                const cacheId = generateStableCacheId(song)
                const analysis = analysisCacheRef.current.get(cacheId)
                // Pass everything, even if analysis is undefined or has an error.
                return { ...song, analysis }
              }) as AnalyzedSong[]
              
              // Ordenar y actualizar estado
              const sorted = sortSongs(orderedAnalyzedSongs)
              setGeneratedSmartMix(sorted)
              setSmartMixStatus('ready')
              setSmartMixTimestamp(Date.now())
              // Guardar en localStorage (solo campos mínimos, sin análisis)
              { const ck = `smartMix_${playlistId}_${signature}`; evictSmartMixCaches(ck); safeSetItem(ck, JSON.stringify({ timestamp: Date.now(), songs: minimalSmartMixSongs(sorted) })) }
              console.log(`[SMART MIX] ✅ Completado: ${sorted.length} canciones analizadas y ordenadas`)
            }
          }, 500)
          
          // Timeout de seguridad (5 minutos)
          setTimeout(() => {
            clearInterval(checkInterval)
            const orderedAnalyzedSongs = songs.map(song => {
              const cacheId = generateStableCacheId(song)
              const analysis = analysisCacheRef.current.get(cacheId)
              return { ...song, analysis }
            }) as AnalyzedSong[]

            const sorted = sortSongs(orderedAnalyzedSongs)
            // Even on timeout, try to use whatever we have, or simply play the original list
            if (sorted.length > 0) {
              setGeneratedSmartMix(sorted)
              setSmartMixStatus('ready')
              setSmartMixTimestamp(Date.now())
              { const ck = `smartMix_${playlistId}_${signature}`; evictSmartMixCaches(ck); safeSetItem(ck, JSON.stringify({ timestamp: Date.now(), songs: minimalSmartMixSongs(sorted) })) }
              console.log(`[SMART MIX] ⚠️ Timeout: usando ${sorted.length} canciones analizadas`)
            } else {
              setSmartMixStatus('error')
            }
          }, 300000) // 5 minutos
        } else {
          // Todas ya están en caché
          const orderedAnalyzedSongs = songs.map(song => {
            const cacheId = generateStableCacheId(song)
            const analysis = analysisCacheRef.current.get(cacheId)
            return { ...song, analysis }
          }) as AnalyzedSong[]

          const sorted = sortSongs(orderedAnalyzedSongs)
          setGeneratedSmartMix(sorted)
          setSmartMixStatus('ready')
          setSmartMixTimestamp(Date.now())
          { const ck = `smartMix_${playlistId}_${signature}`; evictSmartMixCaches(ck); safeSetItem(ck, JSON.stringify({ timestamp: Date.now(), songs: minimalSmartMixSongs(sorted) })) }
          console.log(`[SMART MIX] ✅ Completado con caché: ${sorted.length} canciones`)
        }
      } catch (error) {
        console.error('[SMART MIX] Error:', error)
        setSmartMixStatus('error')
      }
    },
    []
  )

  // --- FUNCIONES DE REPRODUCCIÓN (dependen de las anteriores) ---
  const playSong = useCallback(
    async (song: Song, keepPosition = false) => {
      // If a remote device is active and this is a new song request (not a resume/restart),
      // route through the remote handler instead of playing locally.
      if (!keepPosition && remoteHandlersRef.current?.playSong) {
        const queue = queueRef.current.length > 0 ? queueRef.current : [song]
        remoteHandlersRef.current.playSong(song, queue)
        return
      }

      // Sequence counter: invalidate any in-flight playSong() calls immediately.
      // If the user taps 6 songs rapidly, only the last one's post-load logic runs.
      const thisPlaySeq = ++playSongSequenceRef.current

      outroRefinedForCurrentSongRef.current = false
      automixTriggerSentRef.current = false

      // CRÍTICO: Cancelar crossfade/automix nativo ANTES de cualquier otra cosa.
      if (IS_NATIVE && webAudioPlayerRef.current instanceof NativeAudioPlayer) {
        webAudioPlayerRef.current.clearAutomixTrigger()
        nativeAudio.cancelCrossfade().catch(() => {})
      }

      // Repriorizar análisis cuando se cambia de canción
      if (currentSongRef.current?.id !== song.id) {
        console.log('[PLAYER] Cambiando de canción, repriorizando análisis...')
        // Bajar prioridad de tareas HIGH obsoletas
        analysisQueue.demoteStaleHighPriority(song.id)
        // Dar alta prioridad a la nueva canción si no está en caché
        const cacheId = generateStableCacheId(song)
        if (!analysisCacheRef.current.has(cacheId) && !analysisQueue.has(song.id)) {
          const streamUrl = navidromeApi.getStreamUrl(song.id, song.path)
          analysisQueue.enqueue({
            id: `current-${song.id}`,
            songId: cacheId,
            songTitle: song.title,
            streamUrl,
            priority: AnalysisPriority.HIGH,
            isProactive: false,
          })
        } else if (analysisQueue.has(song.id)) {
          // Si ya está en cola, subir su prioridad
          analysisQueue.reprioritize(song.id, AnalysisPriority.HIGH)
        }
      }

      // Si es una canción nueva, limpiar el scrobble de la canción anterior
      // Si es la misma canción pero se reinicia desde el principio, también limpiar
      if (!keepPosition) {
        // Asegurar que scrobbledSongsRef.current sea un Map
        if (!(scrobbledSongsRef.current instanceof Map)) {
          scrobbledSongsRef.current = new Map()
        }

        if (currentSongRef.current?.id !== song.id) {
          // Canción diferente: limpiar la anterior
          scrobbledSongsRef.current.delete(currentSongRef.current?.id || '')
        }
        // Si es la misma canción pero keepPosition es false, significa que se reinició
        // así que también limpiamos para permitir scrobblear de nuevo
        if (currentSongRef.current?.id === song.id) {
          scrobbledSongsRef.current.delete(song.id)
        }
      }

      if (isCrossfadingRef.current) {
        setIsCrossfading(false)
        isCrossfadingRef.current = false
        if (shouldUseWebAudio()) {
          // Web Audio maneja el crossfade internamente
        } else {
          if (nextAudioRef.current) {
            nextAudioRef.current.pause()
            nextAudioRef.current.volume = 0
          }
        }
      }

      try {
        // Notificar al manager de retry que cambió la canción
        streamRetryManager.onSongChange(song.id)
        setIsReconnecting(false)

        // Comprobar si la canción está en el cache de audio local (pre-descargada)
        const cachedBlobUrl = await queuePrefetcher.getCachedBlobUrl(song.id)
        const streamUrl = cachedBlobUrl || navidromeApi.getStreamUrl(song.id, song.path)
        if (cachedBlobUrl) {
          console.log(`[Player] 🚀 Reproduciendo desde caché local: "${song.title}"`)
        }

        // === SISTEMA CONDICIONAL: Web Audio vs HTML Audio ===
        if (shouldUseWebAudio()) {
          console.log('[Player] Usando Web Audio API para reproducir:', song.title)

          // En nativo, limpiar cualquier HTML Audio residual que pudiera haber
          // quedado de un fallback anterior (evita reproducción paralela fantasma).
          if (IS_NATIVE && audioRef.current) {
            audioRef.current.pause()
            audioRef.current.src = ''
            audioRef.current = null
          }
          
          // 🚀 ACTUALIZAR UI INMEDIATAMENTE (antes de cargar el audio)
          // Esto hace que la respuesta se sienta instantánea
          const newCurrentSong = {
            title: song.title,
            artist: song.artist,
            album: song.album,
            coverArt: song.coverArt,
            duration: song.duration,
            id: song.id,
            path: song.path,
            albumId: song.albumId,
            playlistId: song.playlistId,
          }
          setCurrentSong(newCurrentSong)
          currentSongRef.current = song
          // Usar progressRef.current (siempre actualizado) en vez del estado React (puede ser stale)
          const positionToRestore = keepPosition ? progressRef.current : 0
          setProgress(positionToRestore)
          setDuration(song.duration)
          
          // Actualizar Media Session inmediatamente
          updateMediaSession(newCurrentSong, false) // false = aún no está reproduciendo
          
          // Cargar y reproducir audio (puede tardar para archivos grandes)
          isLoadingRef.current = true
          try {
            // ⚡ FIX: Si keepPosition, sincronizar pauseTime del WebAudioPlayer ANTES de play()
            // Esto es necesario porque tras un refresh el WebAudioPlayer tiene pauseTime=0
            if (keepPosition && positionToRestore > 0 && webAudioPlayerRef.current) {
              webAudioPlayerRef.current.setPauseTime(positionToRestore)
            }
            await webAudioPlayerRef.current!.play(song, streamUrl, keepPosition)

            // ─── Stale call guard ───────────────────────────────────────
            // If the user tapped another song while this one was loading,
            // discard this result. The newer playSong() owns the state now.
            if (playSongSequenceRef.current !== thisPlaySeq) {
              console.log(`[Player] Descartando resultado stale de play() (seq=${thisPlaySeq}, actual=${playSongSequenceRef.current})`)
              return
            }

            // Audio cargado exitosamente - actualizar estado de reproducción
            isLoadingRef.current = false
            setIsPlaying(true)
            updateMediaSession(newCurrentSong, true) // true = ahora sí está reproduciendo

            // Sincronizar análisis de la canción actual con el WebAudioPlayer
            const cacheId = generateStableCacheId(song)
            const analysis = analysisCacheRef.current.get(cacheId)
            if (analysis && !('error' in analysis)) {
              webAudioPlayerRef.current!.setCurrentAnalysis(analysis)
            } else {
              webAudioPlayerRef.current!.setCurrentAnalysis(null)
            }
          } catch (loadError) {
            isLoadingRef.current = false
            // Si fue cancelación (usuario cambió de canción), ignorar silenciosamente
            if (loadError instanceof DOMException && loadError.name === 'AbortError') {
              console.log('[Player] Carga cancelada - usuario cambió de canción')
              return
            }
            // Stale error: user already moved to another song, don't touch state
            if (playSongSequenceRef.current !== thisPlaySeq) return
            
            // En nativo, el NativeAudioPlayer maneja todo — no crear fallback HTML Audio
            // que podría seguir reproduciéndose en paralelo y actualizando progress.
            if (IS_NATIVE) {
              console.error('[Player] NativeAudioPlayer.play() falló:', loadError)
              // CRÍTICO: Sincronizar UI con el estado real — sin esto, la UI muestra
              // "reproduciendo" pero no suena nada, y la barra de progreso se queda congelada.
              // El usuario queda atrapado sin poder reproducir ninguna canción.
              setIsPlaying(false)
              progressRef.current = 0
              setProgress(0)
              return
            }

            // 🔄 FALLBACK A HTML AUDIO para formatos no soportados (M4A, etc.)
            // decodeAudioData puede fallar con ciertos codecs dependiendo del navegador
            console.warn('[Player] Web Audio falló, usando fallback a HTML Audio:', loadError)

            // Usar HTML Audio como fallback para esta canción
            const fallbackAudio = audioRef.current || new Audio()
            if (!audioRef.current) {
              audioRef.current = fallbackAudio
            }

            fallbackAudio.src = streamUrl
            fallbackAudio.volume = volumeRef.current / 100 // Usar ref para valor más actualizado

            // Aplicar listeners básicos para el fallback
            fallbackAudio.oncanplay = () => {
              fallbackAudio.play()
                .then(() => {
                  setIsPlaying(true)
                  updateMediaSession(newCurrentSong, true)
                  console.log('[Player] Fallback HTML Audio reproduciendo:', song.title)
                })
                .catch(playError => {
                  console.error('[Player] Error en fallback HTML Audio:', playError)
                })
            }

            fallbackAudio.ontimeupdate = () => {
              progressRef.current = fallbackAudio.currentTime
              const now = Date.now()
              if (now - lastProgressUpdateRef.current >= 500) {
                setProgress(fallbackAudio.currentTime)
                lastProgressUpdateRef.current = now
              }
            }

            fallbackAudio.onended = () => {
              // Avanzar a la siguiente canción
              const currentIndex = queueRef.current.findIndex(s => s.id === song.id)
              if (currentIndex >= 0 && currentIndex < queueRef.current.length - 1) {
                const nextSong = queueRef.current[currentIndex + 1]
                playSong(nextSong).catch(console.error)
              } else {
                setIsPlaying(false)
              }
            }

            fallbackAudio.load()
            return // No continuar con el resto del código de Web Audio
          }

          // 🎯 Registrar el tiempo de inicio de reproducción para scrobble (Web Audio)
          // Solo si no está ya registrada o si se reinició desde el principio
          if (!keepPosition) {
            // Asegurar que scrobbledSongsRef.current sea un Map
            if (!(scrobbledSongsRef.current instanceof Map)) {
              scrobbledSongsRef.current = new Map()
            }
            // Registrar el tiempo de inicio solo si no está ya registrada
            // o si es una canción diferente
            const existingData = scrobbledSongsRef.current.get(song.id)
            if (!existingData || existingData.scrobbled) {
              scrobbledSongsRef.current.set(song.id, {
                scrobbled: false,
                wrappedScrobbled: false,
                startTime: Date.now(),
              })
            }
          }

          // Enviar "now playing" a Last.fm cuando empieza una nueva canción (Web Audio)
          try {
            const scrobbleEnabled = localStorage.getItem('scrobbleEnabled')
            if (scrobbleEnabled === 'true') {
              navidromeApi.scrobble(song.id, undefined, false).catch(error => {
                console.error('[Scrobble - WebAudio] Error al enviar "now playing":', error)
              })
            }
          } catch (error) {
            console.error('[Scrobble - WebAudio] Error en lógica de "now playing":', error)
          }

        } else {
          // === SISTEMA TRADICIONAL: HTML Audio ===
          console.log('[Player] Usando HTML Audio para reproducir:', song.title)
        // Usar timeOffset para streams transcodificados al restaurar posición.
        // Esto evita que el stream arranque desde 0 y el seek mediante currentTime falle.
        const positionForHtmlOffset = keepPosition ? progressRef.current : 0
        const htmlTimeOffset = positionForHtmlOffset > 2 ? Math.floor(positionForHtmlOffset) : 0
        streamOffsetRef.current = cachedBlobUrl ? 0 : htmlTimeOffset
        // Si tenemos blob cacheado, usarlo directamente (no soporta timeOffset pero podemos seek después)
        const htmlStreamUrl = cachedBlobUrl || navidromeApi.getStreamUrl(song.id, song.path, htmlTimeOffset > 0 ? htmlTimeOffset : undefined)
        const audio = audioRef.current
        if (!audio) return

        // Logs de diagnóstico
        console.log('[Player] Intentando reproducir canción:', {
          id: song.id,
          title: song.title,
          artist: song.artist,
          album: song.album,
          path: song.path,
          duration: song.duration,
          streamUrl: htmlStreamUrl,
          urlLength: htmlStreamUrl.length,
          hasConfig: !!navidromeApi.getConfig(),
          fromCache: !!cachedBlobUrl,
        })

        // Resetear el audio completamente antes de cargar nueva canción
        // Esto ayuda a recuperarse de errores previos
        isResettingAudioRef.current = true
        try {
          // Remover el src antes de pause para evitar errores
          audio.src = ''
          audio.pause()
          audio.load()
        } catch (resetErr) {
          // Ignorar errores durante el reset
          console.warn('[Player] Error durante reset de audio (ignorado):', resetErr)
        } finally {
          // Resetear la bandera después de un delay más largo para asegurar que termine
          setTimeout(() => {
            isResettingAudioRef.current = false
          }, 300)
        }

        // Verificar que la URL no esté vacía
        if (!htmlStreamUrl || htmlStreamUrl.trim() === '') {
          throw new Error('URL de stream vacía o inválida')
        }

        // Ahora cargar la nueva canción
        audio.src = htmlStreamUrl

        // Aplicaremos currenTime después de cargar metadatos

        console.log('[Player] Cargando audio con URL:', htmlStreamUrl.substring(0, 100) + '...')
        audio.load()

        // Esperar a que se carguen los metadatos antes de reproducir
        await new Promise<void>((resolve, reject) => {
          const onLoadedMetadata = () => {
            audio.removeEventListener('loadedmetadata', onLoadedMetadata)
            audio.removeEventListener('error', onError)
            // Sincronizar posición una vez cargados los metadatos.
            // Si el stream usa timeOffset, ya empieza en la posición correcta → currentTime=0.
            // Si no hay offset (archivo nativo corto o sin keepPosition), intentar seek estándar.
            if (keepPosition && progressRef.current > 0 && streamOffsetRef.current === 0) {
              audio.currentTime = progressRef.current
            } else {
              audio.currentTime = 0
            }
            
            console.log('[Player] Metadatos cargados correctamente:', {
              duration: audio.duration,
              readyState: audio.readyState,
              networkState: audio.networkState,
            })
            resolve()
          }

          const onError = (event: Event) => {
            audio.removeEventListener('loadedmetadata', onLoadedMetadata)
            audio.removeEventListener('error', onError)
            const error = audio.error
            console.error('[Player] Error al cargar metadatos:', {
              errorCode: error?.code,
              errorMessage: error?.message,
              networkState: audio.networkState,
              readyState: audio.readyState,
              src: audio.src,
              event,
            })
            reject(
              new Error(
                `Error al cargar audio: ${error?.message || 'Error desconocido'} (código: ${error?.code})`
              )
            )
          }

          audio.addEventListener('loadedmetadata', onLoadedMetadata)
          audio.addEventListener('error', onError)

          // Timeout de seguridad
          setTimeout(() => {
            audio.removeEventListener('loadedmetadata', onLoadedMetadata)
            audio.removeEventListener('error', onError)
            if (audio.readyState < 2) {
              reject(
                new Error(
                  `Timeout esperando metadatos. ReadyState: ${audio.readyState}, NetworkState: ${audio.networkState}`
                )
              )
            } else {
              resolve()
            }
          }, 10000) // 10 segundos de timeout
        })

        try {
          await audio.play()
          setIsPlaying(true)
          console.log('[Player] Reproducción iniciada correctamente')
        } catch (playError) {
          console.error('[Player] Error al reproducir audio:', {
            error: playError,
            errorType: playError instanceof Error ? playError.constructor.name : typeof playError,
            errorMessage: playError instanceof Error ? playError.message : String(playError),
            audioError: audio.error,
            audioErrorCode: audio.error?.code,
            audioErrorMessage: audio.error?.message,
            readyState: audio.readyState,
            networkState: audio.networkState,
            src: audio.src,
          })
          // Resetear el estado del audio
          isResettingAudioRef.current = true
          try {
            audio.pause()
            audio.src = ''
            audio.load()
            setIsPlaying(false)
          } finally {
            setTimeout(() => {
              isResettingAudioRef.current = false
            }, 100)
          }
          throw playError // Re-lanzar para que el catch externo lo maneje
        }

        const newCurrentSong = {
          title: song.title,
          artist: song.artist,
          album: song.album,
          coverArt: song.coverArt,
          duration: song.duration,
          id: song.id,
          path: song.path,
          albumId: song.albumId,
          playlistId: song.playlistId,
        }
        setCurrentSong(newCurrentSong)
        currentSongRef.current = song
        // ⚡ PERFORMANCE: Resetear o mantener refs de progreso
        const targetPosition = keepPosition ? progressRef.current : 0
        progressRef.current = targetPosition
        lastProgressUpdateRef.current = Date.now()
        setProgress(targetPosition)
        setDuration(song.duration)
        audio.volume = volumeRef.current / 100 // Usar ref para valor más actualizado

        // Actualizar Media Session con la nueva canción
        updateMediaSession(newCurrentSong, true)

        // Registrar el tiempo de inicio de reproducción para esta canción
        // Solo si no está ya registrada o si se reinició desde el principio
        if (!keepPosition) {
          // Asegurar que scrobbledSongsRef.current sea un Map
          if (!(scrobbledSongsRef.current instanceof Map)) {
            scrobbledSongsRef.current = new Map()
          }
          // Registrar el tiempo de inicio solo si no está ya registrada
          // o si es una canción diferente
          const existingData = scrobbledSongsRef.current.get(song.id)
          if (!existingData || existingData.scrobbled) {
            scrobbledSongsRef.current.set(song.id, {
              scrobbled: false,
              wrappedScrobbled: false,
              startTime: Date.now(),
            })
          }
        }

        // Enviar "now playing" a Last.fm cuando empieza una nueva canción
        try {
          const scrobbleEnabled = localStorage.getItem('scrobbleEnabled')
          if (scrobbleEnabled === 'true') {
            navidromeApi.scrobble(song.id, undefined, false).catch(error => {
              console.error('[Scrobble] Error al enviar "now playing":', error)
            })
          }
        } catch (error) {
          console.error('[Scrobble] Error en lógica de "now playing":', error)
        }

        // Limpiar el scrobble de la canción anterior para permitir scrobblear de nuevo si se reproduce
        // (solo si cambió de canción)
        if (keepPosition === false) {
          // Solo limpiar si es una canción nueva (no si estamos manteniendo posición)
          // Esto permite que si vuelves a reproducir la misma canción, se pueda scrobblear de nuevo
        }

        // Lógica de cola (extraída para claridad)
        const songInQueue = queueRef.current.find(s => s.id === song.id)
        if (!songInQueue) {
          if (song.playlistId) {
            navidromeApi.getPlaylistSongs(song.playlistId).then(playlistSongs => {
              if (playlistSongs?.length > 0) {
                const currentIndex = playlistSongs.findIndex(s => s.id === song.id)
                if (currentIndex >= 0) {
                  updateQueue(playlistSongs.slice(currentIndex))
                  updateSource(`playlist:${song.playlistId}`)
                }
              }
            })
          } else if (song.albumId) {
            navidromeApi.getAlbumSongs(song.albumId).then(albumSongs => {
              if (albumSongs?.length > 0) {
                const sortedSongs = albumSongs.sort((a, b) => (a.track || 0) - (b.track || 0))
                const currentIndex = sortedSongs.findIndex(s => s.id === song.id)
                if (currentIndex >= 0) {
                  updateQueue(sortedSongs.slice(currentIndex))
                  updateSource(`album:${song.albumId}`)
                }
              }
            })
          }
        }
        } // Fin del bloque condicional Web Audio vs HTML Audio

      } catch (error) {
        console.error('[Player] Error al reproducir canción:', {
          error,
          errorType: error instanceof Error ? error.constructor.name : typeof error,
          errorMessage: error instanceof Error ? error.message : String(error),
          errorStack: error instanceof Error ? error.stack : undefined,
          song: {
            id: song.id,
            title: song.title,
            artist: song.artist,
            album: song.album,
            path: song.path,
            duration: song.duration,
          },
          streamUrl: navidromeApi.getStreamUrl(song.id, song.path),
          audioState: audioRef.current
            ? {
                readyState: audioRef.current.readyState,
                networkState: audioRef.current.networkState,
                error: audioRef.current.error,
                src: audioRef.current.src,
              }
            : null,
        })
        setIsPlaying(false)
        // Resetear completamente el elemento de audio en caso de error
        const audio = audioRef.current
        if (audio) {
          isResettingAudioRef.current = true
          try {
            audio.pause()
            audio.src = ''
            audio.load()
          } catch (resetError) {
            console.error('[Player] Error al resetear audio después de fallo:', resetError)
          } finally {
            setTimeout(() => {
              isResettingAudioRef.current = false
            }, 100)
          }
        }
      }
    },
    [updateQueue, updateMediaSession, shouldUseWebAudio, updateSource]
  )

  const playAlbum = useCallback(
    (albumId: string) => {
      // No usar await - hacer la carga en background
      navidromeApi.getAlbumSongs(albumId)
        .then(songs => {
          if (songs.length > 0) {
            const sortedSongs = songs.sort((a, b) => (a.track || 0) - (b.track || 0))
            const songsWithAlbumId = sortedSongs.map(s => ({ ...s, albumId }))
            if (remoteHandlersRef.current?.playPlaylist) {
              remoteHandlersRef.current.playPlaylist(songsWithAlbumId)
              return
            }
            updateQueue(songsWithAlbumId)
            updateSource(`album:${albumId}`)
            currentContextUriRef.current = `album:${albumId}`
            playSong(songsWithAlbumId[0]).catch(error => {
              console.error('Error al reproducir canción del álbum:', error)
            })
          }
        })
        .catch(error => {
          console.error('Error al obtener canciones del álbum:', error)
        })
    },
    [playSong, updateQueue, updateSource]
  )

  const playPlaylist = useCallback(
    (songs: Song[], contextUri?: string | null) => {
      if (songs.length === 0) return
      if (remoteHandlersRef.current?.playPlaylist) {
        remoteHandlersRef.current.playPlaylist(songs)
        return
      }
      updateQueue(songs)
      if (contextUri !== undefined) {
        if (contextUri) updateSource(contextUri)
        currentContextUriRef.current = contextUri
      } else if (songs[0]?.playlistId) {
        updateSource(`playlist:${songs[0].playlistId}`)
        currentContextUriRef.current = `playlist:${songs[0].playlistId}`
      } else {
        currentContextUriRef.current = null
      }
      // No usar await - playSong ya actualiza la UI inmediatamente
      playSong(songs[0]).catch(error => {
        console.error('Error al reproducir playlist:', error)
      })
    },
    [playSong, updateQueue, updateSource]
  )

  const playGeneratedSmartMix = useCallback(() => {
    if (generatedSmartMix.length > 0) {
      playPlaylist(generatedSmartMix)
      if (smartMixPlaylistId) {
        currentContextUriRef.current = `smartmix:${smartMixPlaylistId}`
      }
      // Ya no limpiamos inmediatamente para que el botón pueda mostrar "Mezcla activa"
      // Se limpiará cuando cambie la firma o expire por tiempo (30m)
    }
  }, [generatedSmartMix, playPlaylist, smartMixPlaylistId])

  const seek = useCallback((time: number) => {
    if (remoteHandlersRef.current?.seek) {
      remoteHandlersRef.current.seek(time)
      return
    }
    if (shouldUseWebAudio()) {
      if (webAudioPlayerRef.current) {
        webAudioPlayerRef.current.seek(time)
        // Actualizar estado inmediatamente
        progressRef.current = time
        setProgress(time)
        const now = Date.now()
        lastProgressUpdateRef.current = now
        // Bloquear automix unos segundos después de un seek manual
        lastPauseTimeRef.current = now
        // Resetear automix trigger para que se recalcule con la nueva posición.
        // El nativo también tiene su propio cooldown de 5s tras seek.
        automixTriggerSentRef.current = false
      }
    } else {
      if (audioRef.current) {
        // Ajustar el tiempo relativo al offset del stream actual.
        // Si el stream arrancó con timeOffset=125, audio.currentTime va de 0 a (dur-125).
        // Para seek a posición real T: streamTime = T - offset.
        const streamTime = time - streamOffsetRef.current
        if (streamTime >= 0) {
          audioRef.current.currentTime = streamTime
        } else {
          // Seek antes del inicio del stream: reiniciamos el offset y buscamos directamente.
          // Para streams nativos funciona via Range requests; para transcodificados puede no ir.
          streamOffsetRef.current = 0
          audioRef.current.currentTime = time
        }
        // ⚡ PERFORMANCE: Actualizar ref y estado inmediatamente en seek (acción de usuario)
        progressRef.current = time
        setProgress(time)
        lastProgressUpdateRef.current = Date.now() // Reset throttle timer
      }
    }
  }, [shouldUseWebAudio])

  const prepareNextSong = useCallback(
    async (currentPlayingSong: Song) => {
      const currentIndex = queueRef.current.findIndex(s => s.id === currentPlayingSong.id)
      if (currentIndex < 0 || currentIndex >= queueRef.current.length - 1) return

      const nextSong = queueRef.current[currentIndex + 1]
      const cacheId = generateStableCacheId(nextSong)

      // Si ya está en memoria, nada que hacer
      if (analysisCacheRef.current.has(cacheId)) {
        if (analysisQueue.has(cacheId)) {
          analysisQueue.reprioritize(cacheId, AnalysisPriority.MEDIUM)
        }
        return
      }

      // ── DB fast-path: intentar recuperar desde la base de datos del backend ──
      // Esto es mucho más rápido que un análisis completo cuando la canción ya fue analizada.
      try {
        const dbResults = await backendApi.getBulkAnalysisStatus([cacheId])
        const dbAnalysis = dbResults[cacheId]
        if (dbAnalysis && !('error' in dbAnalysis)) {
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          analysisCacheRef.current.set(cacheId, dbAnalysis as any)
          console.log(`[PROACTIVO] ✅ Análisis de "${nextSong.title}" recuperado de DB sin análisis nuevo`)
          // Inyectar dinámicamente en el player si es la siguiente canción
          const nextSongInQueue = queueRef.current[queueRef.current.findIndex(s => s.id === currentPlayingSong.id) + 1]
          if (nextSongInQueue?.id === nextSong.id && webAudioPlayerRef.current) {
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            webAudioPlayerRef.current.setNextAnalysis(dbAnalysis as any)
          }
          return
        }
      } catch {
        // Si falla el DB check, caer en el flujo de encolado normal
      }

      // ── Encolar análisis si no está en DB ──
      if (!analysisQueue.has(cacheId)) {
        console.log(`[PROACTIVO] Encolando siguiente canción: "${nextSong.title}"`)
        const streamUrl = navidromeApi.getStreamUrl(nextSong.id, nextSong.path)
        analysisQueue.enqueue({
          id: `next-${nextSong.id}`,
          songId: cacheId,
          songTitle: nextSong.title,
          streamUrl,
          priority: AnalysisPriority.MEDIUM,
          isProactive: true,
        })
      } else {
        analysisQueue.reprioritize(cacheId, AnalysisPriority.MEDIUM)
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    []
  )

  const playPlaylistFromSong = useCallback(
    (songs: Song[], startSong: Song, contextUri?: string | null) => {
      if (remoteHandlersRef.current?.playSong) {
        remoteHandlersRef.current.playSong(startSong, songs)
        return
      }
      if (currentSongRef.current?.id === startSong.id) {
        if (!isPlaying) setIsPlaying(true)
        return
      }
      const startIndex = songs.findIndex(s => s.id === startSong.id)
      if (startIndex !== -1) {
        // 🔥 FIX: No cortar la cola, mantener la lista completa para contexto (Premium)
        updateQueue(songs)

        if (contextUri !== undefined) {
          if (contextUri) updateSource(contextUri)
          currentContextUriRef.current = contextUri
        } else {
          // Determinar ID de playlist de los metadatos de la canción
          const pId = startSong.playlistId || songs[0]?.playlistId
          if (pId) {
            updateSource(`playlist:${pId}`)
            currentContextUriRef.current = `playlist:${pId}`
          } else {
            currentContextUriRef.current = null
          }
        }

        // No usar await - playSong ya actualiza la UI inmediatamente
        playSong(startSong).catch(error => {
          console.error('Error al reproducir desde canción:', error)
        })
      }
    },
    [playSong, updateQueue, isPlaying, updateSource]
  )

  /**
   * Inicia la reproducción de una canción desde una posición específica.
   * Usado principalmente para sincronización multidispositivo (Connect), donde
   * debemos arrancar la canción exactamente en el punto en que está el otro dispositivo.
   * A diferencia de playPlaylistFromSong + seek(), aquí el seek se hace ANTES de
   * iniciar la descarga del audio, evitando la race condition donde seek() se ignora
   * porque !currentBuffer aún no está cargado.
   */
  const playSongAtPosition = useCallback(
    (songs: Song[], startSong: Song, position: number, autoPlay = true) => {
      if (remoteHandlersRef.current?.playSong) {
        remoteHandlersRef.current.playSong(startSong, songs)
        return
      }
      const startIndex = songs.findIndex(s => s.id === startSong.id)
      if (startIndex === -1) return

      updateQueue(songs)
      const pId = startSong.playlistId || songs[0]?.playlistId
      if (pId) updateSource(`playlist:${pId}`)

      // Establecer la posición ANTES de llamar a playSong para que keepPosition=true la use
      progressRef.current = position
      setProgress(position)

      if (autoPlay) {
        playSong(startSong, true).catch(error => {
          console.error('[playSongAtPosition] Error al reproducir:', error)
        })
      } else {
        // Restaurar estado visible sin cargar audio. togglePlayPause detectará
        // la ausencia de fuente y llamará playSong(currentSong, true) cuando el usuario pulse play.
        setCurrentSong(startSong)
        currentSongRef.current = startSong
      }
    },
    [playSong, updateQueue, updateSource]
  )


  const previous = useCallback(() => {
    if (remoteHandlersRef.current?.previous) {
      remoteHandlersRef.current.previous()
      return
    }
    // Limpiar automix nativo inmediatamente (evitar race condition con timer nativo)
    if (IS_NATIVE && webAudioPlayerRef.current instanceof NativeAudioPlayer) {
      webAudioPlayerRef.current.clearAutomixTrigger()
      nativeAudio.cancelCrossfade().catch(() => {})
    }
    isCrossfadingRef.current = false
    setIsCrossfading(false)
    automixTriggerSentRef.current = false

    // Si llevamos más de 3s reproducidos, reiniciar la canción actual.
    // En nativo, audioRef no existe — usar progressRef que siempre está sincronizado.
    const currentTime = IS_NATIVE ? progressRef.current : (audioRef.current?.currentTime ?? 0)
    if (currentTime > 3) {
      seek(0)
      return
    }
    const currentIndex = queueRef.current.findIndex(s => s.id === currentSongRef.current?.id)
    if (currentIndex > 0) {
      playSong(queueRef.current[currentIndex - 1]).catch(error => {
        console.error('Error al ir a canción anterior:', error)
      })
    }
  }, [playSong, seek])

  const togglePlayPause = useCallback(() => {
    if (remoteHandlersRef.current?.togglePlayPause) {
      remoteHandlersRef.current.togglePlayPause()
      return
    }
    // Guard: if a playSong() is currently loading (network download in flight),
    // ignore togglePlayPause to prevent conflicting state mutations.
    // The user will see the song loading UI; tapping play/pause during load is a no-op.
    if (isLoadingRef.current) {
      console.log('[PlayerContext] togglePlayPause ignored — playSong() loading in flight')
      return
    }
    console.log('[PlayerContext] togglePlayPause called - useWebAudio:', shouldUseWebAudio())

    if (shouldUseWebAudio()) {
      if (!webAudioPlayerRef.current) {
        console.log('[PlayerContext] No hay WebAudioPlayer instance')
        return
      }

      const isPlaying = webAudioPlayerRef.current.isCurrentlyPlaying()
      const hasSource = webAudioPlayerRef.current.hasSource()
      console.log(`[PlayerContext] togglePlayPause: isPlaying=${isPlaying}, hasSource=${hasSource}, currentSong=${currentSong?.title ?? 'null'}`)

      if (isPlaying) {
        console.log('[PlayerContext] Pausando WebAudio')
        webAudioPlayerRef.current.pause()
        lastPauseTimeRef.current = Date.now()
        setIsPlaying(false)
        updateMediaSession(currentSong, false)
      } else {
        console.log(`[PlayerContext] Reanudando WebAudio (hasSource=${hasSource})`)

        // FIX: Si WebAudio no tiene canción cargada (ej. refresh), cargarla
        if (!hasSource && currentSong) {
             console.log('[PlayerContext] WebAudio sin fuente, cargando canción actual...')
             playSong(currentSong, true).catch(err => console.error('[PlayerContext] Error al reanudar WebAudio:', err))
             return
        }

        // resume() ahora es async para manejar AudioContext suspended en Electron
        // Si resume falla, intentar recargar la canción completa (recovery post-suspensión iOS)
        webAudioPlayerRef.current.resume()
          .then(() => {
            setIsPlaying(true)
            updateMediaSession(currentSong, true)
          })
          .catch(error => {
            console.error('[PlayerContext] Error al reanudar WebAudio, intentando recarga completa:', error)
            if (currentSong) {
              playSong(currentSong, true).catch(err =>
                console.error('[PlayerContext] Error en recarga completa:', err)
              )
            }
          })
      }
    } else {
      if (!audioRef.current) return

      // FIX: Si el audio no tiene fuente (ej. recarga de página), cargar la canción actual
      if ((!audioRef.current.src || audioRef.current.src === window.location.href) && currentSong) {
          console.log('[PlayerContext] togglePlayPause: Audio sin fuente, cargando canción actual...')
          // Usar playSong con keepPosition=true para mantener el progreso guardado
          // playSong ya se encarga de setear setIsPlaying(true)
          playSong(currentSong, true).catch(err => console.error('[PlayerContext] Error al reanudar:', err))
          return
      }

      if (audioRef.current.paused) {
        audioRef.current.play().then(() => {
          setIsPlaying(true)
          // Actualizar Media Session
          updateMediaSession(currentSong, true)
        })
      } else {
        audioRef.current.pause()
        lastPauseTimeRef.current = Date.now()
        setIsPlaying(false)
        // Actualizar Media Session
        updateMediaSession(currentSong, false)
      }
    }
  }, [currentSong, updateMediaSession, shouldUseWebAudio, playSong])

  // Volume is fixed at 100 (system volume controls audio level).
  // setVolume kept for ConnectContext compatibility (remote device control).
  const setVolume = useCallback((_newVolume: number) => {
    // No-op: volume is always max, controlled by OS
  }, [])

  const removeFromQueue = useCallback(
    (songId: string) => {
      updateQueue(queueRef.current.filter(song => song.id !== songId))
    },
    [updateQueue]
  )

  const clearQueue = useCallback(() => {
    updateQueue(currentSongRef.current ? [currentSongRef.current] : [])
  }, [updateQueue])

  const reorderQueue = useCallback(
    (newOrder: Song[]) => {
      updateQueue(newOrder)
      if (currentSongRef.current) {
        prepareNextSong(currentSongRef.current)
      }
    },
    [updateQueue, prepareNextSong]
  )

  const addToQueue = useCallback(
    (song: Song) => {
      if (queueRef.current.some(s => s.id === song.id)) return
      const newQueue = [...queueRef.current, song]
      updateQueue(newQueue)
      if (currentSongRef.current) {
        prepareNextSong(currentSongRef.current)
      }
    },
    [updateQueue, prepareNextSong]
  )

  // Conexión entre playSong y prepareNextSong a través de useEffect
  useEffect(() => {
    if (currentSong && currentSongRef.current) {
      const songRef = currentSongRef.current
      prepareNextSong(songRef)

      // Pre-cachear las próximas canciones de la cola para resiliencia de red
      queuePrefetcher.prefetchQueue(queueRef.current, songRef.id).catch(() => {})
      
      const cacheId = generateStableCacheId(songRef)
      
      // Encolar análisis de la canción actual con alta prioridad si no está en caché
      if (!analysisCacheRef.current.has(cacheId) && !analysisQueue.has(cacheId)) {
        const streamUrl = navidromeApi.getStreamUrl(songRef.id, songRef.path)
        analysisQueue.enqueue({
          id: `current-${songRef.id}`,
          songId: cacheId,
          songTitle: songRef.title,
          streamUrl,
          priority: AnalysisPriority.HIGH,
          isProactive: false,
        })
      }
    }
  }, [currentSong, prepareNextSong])

  // --- FUNCIÓN PARA APLICAR LISTENERS AL AUDIO ACTUAL ---
  const applyAudioListeners = useCallback(
    (audio: HTMLAudioElement) => {
      if (!audio) return

      // Remover listeners anteriores si existen
      if (timeUpdateHandlerRef.current) {
        audio.removeEventListener('timeupdate', timeUpdateHandlerRef.current)
      }
      if (endedHandlerRef.current) {
        audio.removeEventListener('ended', endedHandlerRef.current)
      }
      if (loadedMetadataHandlerRef.current) {
        audio.removeEventListener('loadedmetadata', loadedMetadataHandlerRef.current)
      }
      // Remover listener de error y stalled si existen
      if (errorHandlerRef.current) {
        audio.removeEventListener('error', errorHandlerRef.current)
      }
      if (stalledHandlerRef.current) {
        audio.removeEventListener('stalled', stalledHandlerRef.current)
      }

      // Crear nuevos handlers
      const onTimeUpdate = () => {
        if (!audioRef.current) return
        
        const { currentTime, duration } = audioRef.current
        // El stream puede haber empezado con timeOffset: sumamos el offset al currentTime local
        // para obtener la posición real dentro de la canción original.
        const realTime = streamOffsetRef.current + currentTime

        // ⚡ PERFORMANCE: Actualizar ref inmediatamente (para cálculos precisos)
        progressRef.current = realTime

        // ⚡ PERFORMANCE: Throttle de actualizaciones del estado - solo cada 500ms
        // Esto reduce re-renders de ~4/s a ~2/s sin perder precisión en la lógica
        const now = Date.now()
        if (now - lastProgressUpdateRef.current >= 500) {
          setProgress(realTime)
          lastProgressUpdateRef.current = now
        }
        if (!duration || isCrossfadingRef.current) return

        // --- LÓGICA DE SCROBBLING ---
        const currentSong = currentSongRef.current
        if (currentSong && duration > 0) {
          try {
            const scrobbleEnabled = localStorage.getItem('scrobbleEnabled')
            if (scrobbleEnabled === 'true' && !scrobblingDisabledRef.current) {
              // Asegurar que scrobbledSongsRef.current sea un Map
              if (!(scrobbledSongsRef.current instanceof Map)) {
                scrobbledSongsRef.current = new Map()
              }

              const songData = scrobbledSongsRef.current.get(currentSong.id)

              // Solo procesar si la canción está registrada y aún no ha sido scrobbeada
              if (songData && !songData.scrobbled) {
                // Calcular el umbral de scrobble: 50% de duración o 4 minutos, lo que sea menor
                const scrobbleThreshold = Math.min(duration * 0.5, 240) // 240 segundos = 4 minutos

                // Calcular el tiempo transcurrido desde que empezó la reproducción
                const timeSinceStart = (Date.now() - songData.startTime) / 1000

                // Solo scrobble por tiempo real transcurrido — jamás por currentTime.
                // El currentTime puede llegar ya alto cuando el receiver sincroniza posición,
                // disparando un falso scrobble inmediato sin que el usuario haya escuchado nada.
                if (timeSinceStart >= scrobbleThreshold) {
                  // Marcar como scrobbeada INMEDIATAMENTE para evitar duplicados
                  songData.scrobbled = true
                  scrobbledSongsRef.current.set(currentSong.id, songData)

                  // Timestamp en segundos Unix - tiempo de inicio de la canción
                  const timestampSeconds = Math.floor(songData.startTime / 1000)

                  // Enviar scrobble a Navidrome (play count)
                  navidromeApi
                    .scrobble(currentSong.id, timestampSeconds, true)
                    .then(success => {
                      if (success) {
                        console.log(
                          `[Scrobble] Canción scrobbeada: ${currentSong.title} - ${currentSong.artist} (${Math.round(currentTime)}s/${Math.round(duration)}s)`
                        )
                        // Notificar al backend via Socket.io para wrapped.db
                        scrobbleCallbackRef.current?.({
                          songId: currentSong.id,
                          title: currentSong.title,
                          artist: currentSong.artist,
                          album: currentSong.album,
                          albumId: currentSong.albumId,
                          duration,
                          playedAt: new Date(songData.startTime).toISOString(),
                          year: currentSong.year,
                          genre: currentSong.genre,
                          contextUri: currentContextUriRef.current,
                        })
                      } else {
                        // Si falla, permitir intentar de nuevo
                        songData.scrobbled = false
                        scrobbledSongsRef.current.set(currentSong.id, songData)
                      }
                    })
                    .catch(error => {
                      console.error('[Scrobble] Error al enviar scrobble:', error)
                      // Si falla, permitir intentar de nuevo
                      songData.scrobbled = false
                      scrobbledSongsRef.current.set(currentSong.id, songData)
                    })
                }
              }
            }
            // wrapped.db: gestionado por Socket.io callback (si conectado) o NowPlayingPoller (externo)
          } catch (error) {
            console.error('[Scrobble] Error en lógica de scrobbling:', error)
          }
        }
        // --- FIN LÓGICA DE SCROBBLING ---

        const isPlaylist = currentSourceRef.current?.startsWith('playlist:')
        const currentIndex = queueRef.current.findIndex(s => s.id === currentSongRef.current?.id)
        const hasNextSong = currentIndex >= 0 && currentIndex < queueRef.current.length - 1
        
        if (!isPlaylist || !hasNextSong) return

        const currentSongForAnalysis = currentSongRef.current
        const cacheId = currentSongForAnalysis
          ? generateStableCacheId(currentSongForAnalysis)
          : null
        const currentAnalysis = cacheId ? analysisCacheRef.current.get(cacheId) : undefined

        // Si no hay análisis, encolarlo con alta prioridad (solo una vez)
        if (!currentAnalysis && currentSongForAnalysis && cacheId) {
          // Verificar que no esté ya en cola o procesándose
          if (!analysisQueue.has(cacheId)) {
            console.log(`[AUTOMIX] ⚠️ Análisis de canción actual no encontrado, encolando con prioridad alta...`)
            const streamUrl = navidromeApi.getStreamUrl(currentSongForAnalysis.id, currentSongForAnalysis.path)
            analysisQueue.enqueue({
              id: `automix-current-${currentSongForAnalysis.id}`,
              songId: cacheId,
              songTitle: currentSongForAnalysis.title,
              streamUrl,
              priority: AnalysisPriority.HIGH,
              isProactive: false,
            })
          }
        }

        let triggerTime: number | null = null
        let reason = ''
        const fadeDuration = crossfadeDurationRef.current
        const fallbackSeconds = settings.isDjMode ? 12 : 8
        const fallbackTriggerTime =
          duration > fallbackSeconds ? duration - fallbackSeconds : duration - 1

        // CRÍTICO: Buffer de tiempo para cargar la siguiente canción antes del fade
        // Damos 2.5 segundos de margen para la carga de metadatos y buffering
        const LOAD_BUFFER_TIME = 2.5

        if (
          currentAnalysis &&
          !('error' in currentAnalysis) &&
          currentAnalysis.outroStartTime &&
          currentAnalysis.outroStartTime > 0 // Asegurarse de que no es 0
        ) {
          let shouldUseSmartOutro = true
          const smartOutroTime = currentAnalysis.outroStartTime
          const diagnostics = currentAnalysis.diagnostics
          const structure = currentAnalysis.structure

          if (!settings.isDjMode) {
            const lastChorusFromStructure =
              structure && structure.length > 0
                ? Math.max(...structure.map(section => section.endTime ?? 0))
                : null
            const lastChorusCandidate = diagnostics?.candidates?.last_chorus_end ?? null

            const lastRelevantSection = Math.max(
              lastChorusFromStructure ?? 0,
              lastChorusCandidate ?? 0
            )

            const MIN_GAP_BEFORE_LAST_CHORUS = 4 // segundos de margen mínimos

            if (
              lastRelevantSection > 0 &&
              smartOutroTime < lastRelevantSection - MIN_GAP_BEFORE_LAST_CHORUS
            ) {
              shouldUseSmartOutro = false
              reason = `Fallback Normal: último bloque relevante termina en ${lastRelevantSection.toFixed(
                2
              )}s`
            }
          }

          if (shouldUseSmartOutro && smartOutroTime < fallbackTriggerTime) {
            // IMPORTANTE: Restar el buffer de carga para que el fade empiece justo en smartOutroTime
            triggerTime = Math.max(0, smartOutroTime - LOAD_BUFFER_TIME)
            reason = `Punto de mezcla inteligente en ${smartOutroTime.toFixed(2)}s (trigger anticipado: ${triggerTime.toFixed(2)}s para compensar carga)`
            if (settings.isDjMode) {
              reason = `Modo DJ: ${reason}`
            }
          } else {
            triggerTime = fallbackTriggerTime
            const ignoredOutro = smartOutroTime.toFixed(2)
            reason =
              reason ||
              `Fallback forzado (${settings.isDjMode ? 'DJ' : 'Normal'}): ${fallbackSeconds}s restantes (análisis de ${ignoredOutro}s ignorado por estar muy cerca del final)`
          }
        } else {
          // Fallback normal si no hay análisis o punto de outro.
          triggerTime = fallbackTriggerTime
          reason = `Fallback ${settings.isDjMode ? 'DJ' : 'Normal'}: ${fallbackSeconds}s restantes`
        }

        if (triggerTime && currentTime >= triggerTime) {
          // Si queda muy poco tiempo, dejar que onEnded haga transición directa
          const remaining = duration - currentTime
          if (remaining < 3) {
            console.log(`[AUTOMIX-A] Omitiendo crossfade: solo quedan ${remaining.toFixed(1)}s`)
            return
          }
          console.log(
            `[AUTOMIX-A] Lanzando siguiente. Razón: ${reason}. (tiempoActual: ${currentTime.toFixed(
              2
            )}s, trigger: ${triggerTime.toFixed(2)}s, durFundido: ${fadeDuration.toFixed(2)}s)`
          )
          nextCallbackRef.current?.(true) // true = usar crossfade para automix
          return
        }
      }

      const onEnded = () => {
        // Nota: Ya no registramos scrobbles aquí porque con crossfade las canciones
        // raramente llegan al 100%. El scrobble se registra cuando se alcanza el umbral
        // (50% o 4 minutos) en la lógica de onTimeUpdate.

        if (!isCrossfadingRef.current) {
          nextCallbackRef.current?.(true) // true = usar crossfade para automix
        }
      }

      const onLoadedMetadata = () => {
        if (audioRef.current) setDuration(audioRef.current.duration)
      }

      const onError = (_event: Event) => {
        // Ignorar errores si estamos reseteando el audio intencionalmente
        if (isResettingAudioRef.current) {
          return
        }

        const audio = audioRef.current
        if (!audio) return

        // Ignorar errores cuando el src está vacío (normal durante inicialización)
        if (!audio.src || audio.src.trim() === '') {
          return
        }

        // Verificar el código de error del elemento de audio
        const error = audio.error
        if (error) {
          // Código 4 (MEDIA_ERR_SRC_NOT_SUPPORTED) puede ocurrir durante reseteos normales
          if (error.code === 4) return

          const songId = currentSongRef.current?.id
          const song = currentSongRef.current

          // === STREAM RETRY: reintentar en errores de red en vez de resetear ===
          if (songId && song && error.code === 2 /* MEDIA_ERR_NETWORK */ && streamRetryManager.shouldRetry(songId, error.code)) {
            console.warn(`[Player] Error de red en stream, programando retry...`)
            const currentPosition = progressRef.current

            streamRetryManager.scheduleRetry(async () => {
              const retryOffset = currentPosition > 2 ? Math.floor(currentPosition) : 0
              const retryUrl = navidromeApi.getStreamUrl(song.id, song.path, retryOffset > 0 ? retryOffset : undefined)
              if (!audioRef.current) throw new Error('No audio element')

              streamOffsetRef.current = retryOffset
              audioRef.current.src = retryUrl
              audioRef.current.load()

              await new Promise<void>((resolve, reject) => {
                const a = audioRef.current!
                const onOk = () => { a.removeEventListener('canplay', onOk); a.removeEventListener('error', onFail); resolve() }
                const onFail = () => { a.removeEventListener('canplay', onOk); a.removeEventListener('error', onFail); reject(new Error('Retry load failed')) }
                a.addEventListener('canplay', onOk, { once: true })
                a.addEventListener('error', onFail, { once: true })
                setTimeout(() => { a.removeEventListener('canplay', onOk); a.removeEventListener('error', onFail); reject(new Error('Retry timeout')) }, 15000)
              })

              await audioRef.current.play()
              setIsPlaying(true)
            })
            return // No resetear — el retry se encarga
          }

          // Log detallado del error (solo para errores no recuperables)
          console.error('[Player] Error en elemento de audio:', {
            code: error.code,
            message: error.message || 'Error desconocido',
            networkState: audio.networkState,
            readyState: audio.readyState,
            currentSong: currentSongRef.current
              ? { id: currentSongRef.current.id, title: currentSongRef.current.title }
              : null,
          })

          // Marcar que estamos reseteando para evitar bucles infinitos
          isResettingAudioRef.current = true

          // Resetear el audio cuando hay un error no recuperable
          try {
            audio.pause()
            audio.src = ''
            audio.load()
            setIsPlaying(false)
            setCurrentSong(null)
            currentSongRef.current = null
          } catch (resetError) {
            console.error('[Player] Error al resetear audio después de error:', resetError)
          } finally {
            setTimeout(() => {
              isResettingAudioRef.current = false
            }, 200)
          }
        }
      }

      // Handler de stall: cuando el stream se congela por red
      const onStalled = () => {
        if (isResettingAudioRef.current) return
        const songId = currentSongRef.current?.id
        const song = currentSongRef.current
        if (!songId || !song || !audioRef.current) return

        // Solo actuar si llevamos un rato sin datos (evitar falsos positivos)
        const audio = audioRef.current
        if (audio.networkState !== 2 /* NETWORK_LOADING */) return

        console.warn(`[Player] Stream stalled para "${song.title}" en ${progressRef.current.toFixed(1)}s`)

        if (streamRetryManager.shouldRetry(songId)) {
          const currentPosition = progressRef.current
          streamRetryManager.scheduleRetry(async () => {
            const retryOffset = currentPosition > 2 ? Math.floor(currentPosition) : 0
            const retryUrl = navidromeApi.getStreamUrl(song.id, song.path, retryOffset > 0 ? retryOffset : undefined)
            if (!audioRef.current) throw new Error('No audio element')

            streamOffsetRef.current = retryOffset
            audioRef.current.src = retryUrl
            audioRef.current.load()

            await new Promise<void>((resolve, reject) => {
              const a = audioRef.current!
              const onOk = () => { a.removeEventListener('canplay', onOk); a.removeEventListener('error', onFail); resolve() }
              const onFail = () => { a.removeEventListener('canplay', onOk); a.removeEventListener('error', onFail); reject(new Error('Retry load failed')) }
              a.addEventListener('canplay', onOk, { once: true })
              a.addEventListener('error', onFail, { once: true })
              setTimeout(() => { a.removeEventListener('canplay', onOk); a.removeEventListener('error', onFail); reject(new Error('Retry timeout')) }, 15000)
            })

            await audioRef.current.play()
            setIsPlaying(true)
          })
        }
      }

      // Guardar referencias para poder removerlos después
      timeUpdateHandlerRef.current = onTimeUpdate
      endedHandlerRef.current = onEnded
      loadedMetadataHandlerRef.current = onLoadedMetadata
      errorHandlerRef.current = onError
      stalledHandlerRef.current = onStalled

      // Aplicar listeners
      audio.addEventListener('timeupdate', onTimeUpdate)
      audio.addEventListener('ended', onEnded)
      audio.addEventListener('loadedmetadata', onLoadedMetadata)
      audio.addEventListener('error', onError)
      audio.addEventListener('stalled', onStalled)
    },
    [settings.isDjMode]
  )

  const startCrossfade = useCallback(
    async (nextSong: Song) => {
      // NOTA: La protección contra múltiples llamadas ya está en next()
      // que establece isCrossfadingRef.current = true antes de llamar aquí
      setIsCrossfading(true)
      isCrossfadingRef.current = true
      crossfadeStartTimeRef.current = Date.now() // Para timeout de seguridad

      const audioA = audioRef.current
      const audioB = nextAudioRef.current

      if (!audioA || !audioB) {
        setIsCrossfading(false)
        isCrossfadingRef.current = false
        return
      }

      try {
        // LOG: Verificar datos de entrada
        console.log(
          `[CROSSFADE INIT] Iniciando crossfade a "${nextSong.title}" (id: ${nextSong.id}, duration: ${nextSong.duration}s)`
        )
        console.log(`[CROSSFADE] Tiempo actual de canción A: ${audioA.currentTime.toFixed(2)}s / ${audioA.duration.toFixed(2)}s`)

        const audioBSrcUrl = navidromeApi.getStreamUrl(nextSong.id, nextSong.path)
        audioB.src = audioBSrcUrl
        audioB.load()

        // Esperar a que los metadatos del nuevo audio estén cargados
        await new Promise<void>((resolve) => {
          if (audioB.readyState >= 1) { // HAVE_METADATA o superior
            console.log(`[CROSSFADE] Metadatos ya disponibles (readyState: ${audioB.readyState})`)
            resolve()
          } else {
            let resolved = false
            const onLoadedMetadata = () => {
              if (resolved) return
              resolved = true
              console.log(`[CROSSFADE] Metadatos cargados (duration: ${audioB.duration}s)`)
              audioB.removeEventListener('loadedmetadata', onLoadedMetadata)
              resolve()
            }
            audioB.addEventListener('loadedmetadata', onLoadedMetadata)
            // Timeout de seguridad por si nunca se carga
            setTimeout(() => {
              if (resolved) return
              resolved = true
              console.warn('[CROSSFADE] Timeout esperando metadatos, continuando...')
              audioB.removeEventListener('loadedmetadata', onLoadedMetadata)
              resolve()
            }, 2000)
          }
        })

        const cacheIdA = currentSongRef.current
          ? generateStableCacheId(currentSongRef.current)
          : null
        const cacheIdB = generateStableCacheId(nextSong)
        const analysisA = cacheIdA ? analysisCacheRef.current.get(cacheIdA) : null
        const analysisB = analysisCacheRef.current.get(cacheIdB)

        // Si no está en caché, intentar obtenerlo del backend solo UNA vez
        if (!analysisB) {
          // Encolar con prioridad media (no bloquear el crossfade)
          if (!analysisQueue.has(cacheIdB)) {
            console.log(`[CROSSFADE] ⚠️ Análisis no disponible para "${nextSong.title}", encolando para siguiente vez`)
            const streamUrl = navidromeApi.getStreamUrl(nextSong.id, nextSong.path)
            analysisQueue.enqueue({
              id: `crossfade-${nextSong.id}`,
              songId: cacheIdB,
              songTitle: nextSong.title,
              streamUrl,
              priority: AnalysisPriority.MEDIUM,
              isProactive: false,
            })
          }
          // Usar fallback para este crossfade (el análisis estará para la próxima)
          console.log(`[CROSSFADE] Usando fallback para "${nextSong.title}" (análisis disponible en próximo crossfade)`)
        }

        // =======================================================================
        // INICIO: Lógica de Automix Avanzado v3 (Con Fade Times)
        // =======================================================================
        let entradaB = 0
        let fadeDuration = settings.isDjMode ? 6 : 8 // Duración base del fundido

        let decisionEntrada = 'Usando inicio (0s).'
        let decisionDuracion = `Usando duracin base (${fadeDuration}s).`

        const computeLeadSeconds = (dropTime: number, isDj: boolean) => {
          if (!dropTime || dropTime <= 2.5) return 0
          const scale = isDj ? 0.22 : 0.35
          const minLead = isDj ? 2.5 : 4.5
          const maxLead = isDj ? 6 : 10
          const desired = dropTime * scale
          const clamped = Math.min(Math.max(desired, minLead), maxLead)
          const maxAllowed = Math.max(dropTime - 0.5, 1.5)
          return Math.max(1.5, Math.min(clamped, maxAllowed))
        }

        if (analysisB && !('error' in analysisB)) {
          const {
            introEndTime = 0,
            vocalStartTime = 0,
            structure,
            beatInterval,
            fadeInDuration,
          } = analysisB
          const chorusStartTime = structure?.[0]?.startTime || 0
          const beats4 = (beatInterval || 0.5) * 4 // 4 beats

          const dropCandidates: number[] = []
          if (introEndTime > 3) dropCandidates.push(introEndTime)
          else if (introEndTime > 0 && introEndTime <= 3) dropCandidates.push(introEndTime) // para intros super cortas
          if (fadeInDuration && fadeInDuration > 3) dropCandidates.push(fadeInDuration)
          if (vocalStartTime > 2) dropCandidates.push(vocalStartTime)
          const primaryDrop = dropCandidates.find(time => typeof time === 'number' && time > 0) || 0

          if (settings.isDjMode) {
            // Lógica de entrada para MODO DJ (más agresivo, apuntando al drop)
            if (primaryDrop > 1.5) {
              const djLead = computeLeadSeconds(primaryDrop, true)
              entradaB = Math.max(0, primaryDrop - djLead)
              decisionEntrada = `DJ drop dinámico: ${primaryDrop.toFixed(
                2
              )}s (lead ${djLead.toFixed(2)}s).`
            } else if (chorusStartTime > beats4) {
              entradaB = chorusStartTime - beats4
              decisionEntrada = `Salto pre-estribillo en ${entradaB.toFixed(2)}s.`
            } else if (introEndTime > beats4 * 2) {
              entradaB = introEndTime - beats4
              decisionEntrada = `Intro larga en ${entradaB.toFixed(2)}s.`
            } else if (vocalStartTime > beats4) {
              entradaB = vocalStartTime
              decisionEntrada = `Salto a vocales en ${vocalStartTime.toFixed(2)}s.`
            }
          } else {
            // Lógica de entrada para MODO NORMAL (conservadora pero dinámica)
            if (primaryDrop > 2.5) {
              const normalLead = computeLeadSeconds(primaryDrop, false)
              entradaB = Math.max(0, primaryDrop - normalLead)
              decisionEntrada = `Intro dinámica: drop en ${primaryDrop.toFixed(
                2
              )}s (fade ${normalLead.toFixed(2)}s).`
            }
            // Inicio de vocales detectado (fallback)
            else if (vocalStartTime > 1.0 && vocalStartTime < 60.0) {
              const preVocalOffset = Math.min(3, vocalStartTime * 0.1)
              entradaB = Math.max(0, vocalStartTime - preVocalOffset)
              decisionEntrada = `Pre-vocal en ${entradaB.toFixed(2)}s (vocales en ${vocalStartTime.toFixed(2)}s).`
            }
            // Estribillo detectado (fallback)
            else if (chorusStartTime > beats4 * 2) {
              entradaB = Math.max(0, chorusStartTime - beats4)
              decisionEntrada = `Pre-estribillo en ${entradaB.toFixed(2)}s.`
            }
            // Intro muy larga sin vocales claras (último recurso)
            else if (introEndTime > 12.0) {
              entradaB = Math.max(0, introEndTime - 8)
              decisionEntrada = `Intro larga en ${entradaB.toFixed(2)}s.`
            }
          }
        }

        // --- Lógica de Duración de Fundido Adaptativa (v4 - Mejorada) ---
        if (analysisA && !('error' in analysisA) && analysisB && !('error' in analysisB)) {
          const {
            introEndTime: introB_time = 0,
            vocalStartTime: vocalB_time = 0,
          } = analysisB

          // Calcular duración del outro de la canción A
          const outroA_start = analysisA.outroStartTime || audioA.duration
          const outroA_duration = audioA.duration - outroA_start
          
          // CRÍTICO: Si el outro está al final (menos de 2s de outro), ignorarlo
          const hasValidOutro = outroA_duration >= 2

          // Determinar el punto de "drop" o entrada fuerte de la canción B
          const dropB_time = introB_time > 1.0 ? introB_time : vocalB_time

          // Si hay un drop significativo después del punto de entrada
          if (dropB_time > entradaB) {
            // Calcular duración ideal basada en la distancia al drop
            const idealFadeDuration = dropB_time - entradaB

            const minFade = settings.isDjMode ? 5 : 6
            const maxFade = settings.isDjMode ? 10 : 12
            
            // Solo limitar por outro si es válido (>= 2s)
            if (hasValidOutro) {
              const constrainedDuration = Math.min(idealFadeDuration, outroA_duration)
              fadeDuration = Math.max(minFade, Math.min(maxFade, constrainedDuration))
              decisionDuracion = `Adaptada a intro de ${idealFadeDuration.toFixed(
                2
              )}s limitada por outro (${outroA_duration.toFixed(2)}s) -> ${fadeDuration.toFixed(2)}s.`
            } else {
              // Si no hay outro válido, usar la duración ideal sin límite de outro
              fadeDuration = Math.max(minFade, Math.min(maxFade, idealFadeDuration))
              decisionDuracion = `Adaptada a intro de ${idealFadeDuration.toFixed(
                2
              )}s (outro inválido: ${outroA_duration.toFixed(2)}s, ignorado) -> ${fadeDuration.toFixed(2)}s.`
            }
          } 
          // Si no hay drop claro pero hay un outro razonable
          else if (hasValidOutro) {
            const minFade = settings.isDjMode ? 5 : 6
            const maxFade = settings.isDjMode ? 8 : 10
            fadeDuration = Math.max(minFade, Math.min(maxFade, outroA_duration * 0.8))
            decisionDuracion = `Adaptada a duración de outro (${outroA_duration.toFixed(
              2
            )}s) -> ${fadeDuration.toFixed(2)}s.`
          } else {
            // Sin drop claro y sin outro válido, usar duración base
            decisionDuracion = `Usando duración base (sin drop ni outro válido): ${fadeDuration}s.`
          }
        } else {
          // Si no hay análisis, se mantiene la duración base definida al principio.
          decisionDuracion = `Usando duración base (sin análisis): ${fadeDuration}s.`
        }

        // Guardar la duración calculada para que onTimeUpdate la use
        crossfadeDurationRef.current = fadeDuration
        setCrossfadeDuration(fadeDuration)

        console.log(
          `[AUTOMIX v3] Decisión Entrada (${settings.isDjMode ? 'DJ' : 'Normal'}): ${decisionEntrada}`
        )
        console.log(`[AUTOMIX v3] Decisión Duración Fundido: ${decisionDuracion}`)
        // =======================================================================
        // FIN: Lógica de Automix Avanzado v3
        // =======================================================================

        // =======================================================================
        // INICIO: Sincronización de Beats (Beat-Matching)
        // =======================================================================
        let adjustedEntradaB = entradaB
        let beatSyncInfo = ''

        // Solo sincronizar beats si:
        // 1. Estamos en modo DJ
        // 2. Tenemos análisis de ambas canciones
        // 3. Ambas tienen beatInterval válido
        if (
          settings.isDjMode &&
          analysisA &&
          !('error' in analysisA) &&
          analysisB &&
          !('error' in analysisB) &&
          analysisA.beatInterval &&
          analysisB.beatInterval &&
          analysisA.beatInterval > 0 &&
          analysisB.beatInterval > 0
        ) {
          const beatIntervalA = analysisA.beatInterval
          const beatIntervalB = analysisB.beatInterval

          // Ajustar el punto de entrada de B para que su beat inicial coincida con un beat
          // Calculamos en qué fase del beat estaría B en el punto de entrada original
          const timeIntoBeatB = entradaB % beatIntervalB

          // Si el punto de entrada no está en el beat, ajustarlo al beat más cercano
          if (timeIntoBeatB > beatIntervalB * 0.1) {
            // Si estamos a más del 10% dentro del beat, avanzar al siguiente beat
            const adjustment = beatIntervalB - timeIntoBeatB
            adjustedEntradaB = entradaB + adjustment
            beatSyncInfo = `Beat-sync: ajustado +${adjustment.toFixed(3)}s (de ${entradaB.toFixed(2)}s a ${adjustedEntradaB.toFixed(2)}s)`
          } else if (timeIntoBeatB > 0.001) {
            // Si estamos muy cerca del beat, retroceder al beat actual
            adjustedEntradaB = entradaB - timeIntoBeatB
            beatSyncInfo = `Beat-sync: ajustado -${timeIntoBeatB.toFixed(3)}s (de ${entradaB.toFixed(2)}s a ${adjustedEntradaB.toFixed(2)}s)`
          } else {
            beatSyncInfo = `Beat-sync: ya alineado en ${entradaB.toFixed(2)}s`
          }

          console.log(`[BEAT-SYNC] ${beatSyncInfo}`)
          console.log(
            `[BEAT-SYNC] A: ${beatIntervalA.toFixed(3)}s/beat (${(60 / beatIntervalA).toFixed(1)} BPM), B: ${beatIntervalB.toFixed(3)}s/beat (${(60 / beatIntervalB).toFixed(1)} BPM)`
          )
        }
        // =======================================================================
        // FIN: Sincronización de Beats
        // =======================================================================

        // Registrar el tiempo de inicio de reproducción para scrobble
        // Asegurar que scrobbledSongsRef.current sea un Map
        if (!(scrobbledSongsRef.current instanceof Map)) {
          scrobbledSongsRef.current = new Map()
        }
        // Registrar el tiempo de inicio solo si no está ya registrada o si ya fue scrobbeada
        const existingData = scrobbledSongsRef.current.get(nextSong.id)
        if (!existingData || existingData.scrobbled) {
          scrobbledSongsRef.current.set(nextSong.id, {
            scrobbled: false,
            wrappedScrobbled: false,
            startTime: Date.now(),
          })
        }

        // Enviar "now playing" a Last.fm cuando empieza una nueva canción en crossfade
        try {
          const scrobbleEnabled = localStorage.getItem('scrobbleEnabled')
          if (scrobbleEnabled === 'true') {
            navidromeApi.scrobble(nextSong.id, undefined, false).catch(error => {
              console.error('[Scrobble] Error al enviar "now playing" en crossfade:', error)
            })
          }
        } catch (error) {
          console.error('[Scrobble] Error en lógica de "now playing" en crossfade:', error)
        }

        // Helper que finaliza el crossfade (intercambia referencias, actualiza estado)
        const finalizeCrossfade = () => {
          if (!isCrossfadingRef.current) return

          // Detener y limpiar audioA
          audioA.pause()
          audioA.currentTime = 0

          // Intercambiar referencias de audio: B se convierte en current
          audioRef.current = audioB
          nextAudioRef.current = audioA

          // En no-iOS, restaurar volumen correcto (en iOS es read-only pero no perjudica)
          audioRef.current.volume = volumeRef.current / 100

          // Re-aplicar listeners al nuevo audio
          applyAudioListeners(audioRef.current)

          const validDuration = nextSong.duration && isFinite(nextSong.duration) && nextSong.duration > 0
            ? nextSong.duration
            : audioRef.current.duration && isFinite(audioRef.current.duration) && audioRef.current.duration > 0
              ? audioRef.current.duration
              : 0

          const newCurrentSong = {
            title: nextSong.title,
            artist: nextSong.artist,
            album: nextSong.album,
            coverArt: nextSong.coverArt,
            duration: validDuration,
            id: nextSong.id,
            path: nextSong.path,
            albumId: nextSong.albumId,
            playlistId: nextSong.playlistId,
          }

          setCurrentSong(newCurrentSong)
          currentSongRef.current = nextSong
          setDuration(validDuration)

          const validProgress = audioRef.current.currentTime && isFinite(audioRef.current.currentTime)
            ? audioRef.current.currentTime
            : 0
          progressRef.current = validProgress
          lastProgressUpdateRef.current = Date.now()
          setProgress(validProgress)

          setIsCrossfading(false)
          isCrossfadingRef.current = false

          updateMediaSession(newCurrentSong, true)

          console.log(`[CROSSFADE] ✅ Transición completada: "${nextSong.title}" (progress: ${validProgress.toFixed(1)}s)`)
        }

        // =======================================================================
        // iOS NATIVO: HTMLAudioElement.volume es read-only → el fade basado en
        // volumen no funciona. Ambas canciones sonarían a volumen completo durante
        // toda la transición. Hacemos un corte limpio en el punto musical correcto.
        // =======================================================================
        if (IS_NATIVE) {
          // En iOS, siempre empezar desde 0 para evitar stalls por posiciones no cacheadas.
          // HTMLAudioElement en iOS puede tardar mucho en resolver play() si el audio
          // no está bufferizado en la posición indicada, manteniendo ambas canciones sonando.
          console.log(`[CROSSFADE] 📱 iOS nativo — corte limpio (inicio desde 0)`)
          audioB.currentTime = 0
          await audioB.play()
          finalizeCrossfade()
          return
        }

        // =======================================================================
        // NO iOS: fade basado en volumen (comportamiento original)
        // =======================================================================
        const mainVolume = volumeRef.current / 100
        audioA.volume = mainVolume
        audioB.volume = 0
        audioB.currentTime = adjustedEntradaB

        await audioB.play()

        console.log(`[CROSSFADE] Iniciando fundido simultáneo (${fadeDuration.toFixed(2)}s)...`)
        if (beatSyncInfo) console.log(`[CROSSFADE] ${beatSyncInfo}`)

        const steps = 100
        const transitionTimeMs = fadeDuration * 1000
        const stepDuration = transitionTimeMs / steps

        for (let i = 0; i <= steps; i++) {
          setTimeout(() => {
            if (!isCrossfadingRef.current) return
            const currentMainVolume = volumeRef.current / 100
            const progress = i / steps
            audioA.volume = currentMainVolume * (1 - progress)
            audioB.volume = currentMainVolume * progress
          }, i * stepDuration)
        }

        setTimeout(() => {
          if (!isCrossfadingRef.current) {
            audioB.pause()
            audioB.volume = 0
            return
          }
          finalizeCrossfade()
        }, transitionTimeMs)
      } catch (error) {
        console.error('[CROSSFADE] Error:', error)
        setIsCrossfading(false)
        isCrossfadingRef.current = false
        await playSong(nextSong)
      }
    },
    [playSong, settings.isDjMode, applyAudioListeners, updateMediaSession]
  )

  // next() con parámetro opcional para crossfade
  // - forAutomix=false (default): Cambio directo de canción (botón manual)
  // - forAutomix=true: Usar crossfade inteligente (llamado por automix)
  const next = useCallback((maybeForAutomix: unknown = false) => {
    if (remoteHandlersRef.current?.next) {
      remoteHandlersRef.current.next()
      return
    }
    const forAutomix = maybeForAutomix === true
    const currentIndex = queueRef.current.findIndex(s => s.id === currentSongRef.current?.id)
    if (currentIndex >= 0 && currentIndex < queueRef.current.length - 1) {
      const nextSong = queueRef.current[currentIndex + 1]

      // Si NO es para automix (botón manual), usar playSong directo para un cambio instantáneo
      if (!forAutomix) {
        console.log(`[PlayerContext] next() manual - saltando a: ${nextSong?.title}`)
        // CRÍTICO: Limpiar automix nativo ANTES de playSong (que es async y tarda en descargar).
        // Si no, el timer nativo puede disparar crossfade mientras descargamos la siguiente canción.
        if (IS_NATIVE && webAudioPlayerRef.current instanceof NativeAudioPlayer) {
          webAudioPlayerRef.current.clearAutomixTrigger()
          nativeAudio.cancelCrossfade().catch(() => {})
        }
        isCrossfadingRef.current = false
        setIsCrossfading(false)
        automixTriggerSentRef.current = false
        playSong(nextSong).catch(error => {
          console.error('Error al ir a siguiente canción:', error)
        })
        return
      }

      // === MODO AUTOMIX: Usar crossfade inteligente ===
      // Timeout de seguridad: si el crossfade ha estado activo por más de 30s, resetear
      const CROSSFADE_TIMEOUT_MS = 30000
      if (isCrossfadingRef.current) {
        const elapsedTime = Date.now() - crossfadeStartTimeRef.current
        if (elapsedTime > CROSSFADE_TIMEOUT_MS) {
          console.warn(`[PlayerContext] ⚠️ Crossfade timeout (${(elapsedTime / 1000).toFixed(1)}s), reseteando flag...`)
          isCrossfadingRef.current = false
          setIsCrossfading(false)
        } else {
          console.log('[PlayerContext] next() automix ignorado - crossfade ya en curso')
          return
        }
      }

      // Verificar si Web Audio soporta crossfade (no en modo MediaElement/Electron)
      const useWebAudio = shouldUseWebAudio()
      const crossfadeSupported = webAudioPlayerRef.current?.isCrossfadeSupported() ?? false
      const webAudioSupportsCrossfade = useWebAudio && crossfadeSupported

      console.log(`[PlayerContext] next() automix - useWebAudio: ${useWebAudio}, crossfadeSupported: ${crossfadeSupported}, nextSong: ${nextSong?.title}`)

      // Activar bandera ref Y estado INMEDIATAMENTE para que la UI refleje AutoMix
      // desde el primer momento (antes de que el engine dispare onCrossfadeStart)
      isCrossfadingRef.current = true
      setIsCrossfading(true)
      crossfadeStartTimeRef.current = Date.now()

      if (webAudioSupportsCrossfade) {
        // Web Audio con Buffer: usar crossfade inteligente para automix
        console.log('[PlayerContext] Web Audio next - preparando crossfade')
        const streamUrl = navidromeApi.getStreamUrl(nextSong.id, nextSong.path)
        const cacheId = generateStableCacheId(nextSong)
        const cachedAnalysis = analysisCacheRef.current.get(cacheId)
        const analysis = (cachedAnalysis && !('error' in cachedAnalysis)) ? cachedAnalysis : undefined

        if (webAudioPlayerRef.current) {
          webAudioPlayerRef.current.prepareNextSong(nextSong, streamUrl, analysis)
            .then(() => {
              // CRÍTICO: Re-leer el cache justo antes del crossfade.
              // El análisis puede haber llegado mientras se cargaba el audio de la siguiente canción.
              const freshCachedAnalysis = analysisCacheRef.current.get(cacheId)
              const freshAnalysis = (freshCachedAnalysis && !('error' in freshCachedAnalysis)) ? freshCachedAnalysis : undefined
              if (freshAnalysis && !analysis) {
                // El análisis llegó durante la carga - inyectarlo antes del crossfade
                console.log(`[PlayerContext] ✅ Análisis de "${nextSong.title}" llegó durante carga - inyectando antes del crossfade`)
                webAudioPlayerRef.current?.setNextAnalysis(freshAnalysis)
              }
              webAudioPlayerRef.current?.startCrossfade()
            })
            .catch(error => {
              console.error('Error preparando siguiente canción para crossfade:', error)
              console.log('[PlayerContext] Fallback: reproduciendo siguiente canción directamente')
              isCrossfadingRef.current = false
              setIsCrossfading(false)
              playSong(nextSong).catch(e => console.error('Error en fallback playSong:', e))
            })
        }
      } else {
        // HTML Audio o MediaElement (Electron): usar sistema tradicional
        console.log(`[PlayerContext] Usando sistema tradicional - currentSource: ${currentSourceRef.current}`)
        if (currentSourceRef.current?.startsWith('playlist:')) {
          console.log('[PlayerContext] Llamando startCrossfade (HTML Audio)')
          startCrossfade(nextSong).catch(error => {
            console.error('Error en crossfade:', error)
            isCrossfadingRef.current = false
            setIsCrossfading(false)
          })
        } else {
          console.log('[PlayerContext] Llamando playSong directamente')
          playSong(nextSong).catch(error => {
            console.error('Error al ir a siguiente canción:', error)
            isCrossfadingRef.current = false
            setIsCrossfading(false)
          })
        }
      }
    } else {
      setIsPlaying(false)
    }
  }, [playSong, startCrossfade, shouldUseWebAudio])

  // --- Funciones de la Cola de Análisis (Batch) ---
  const startPlaylistAnalysis = useCallback(
    async (songs: Song[]) => {
      console.log(`[BATCH] Encolando análisis para ${songs.length} canciones de la lista.`)
      
      let enqueued = 0
      songs.forEach(song => {
        const cacheId = generateStableCacheId(song)
        // Solo encolar si no está en caché y no está ya en cola
        if (!analysisCacheRef.current.has(cacheId) && !analysisQueue.has(cacheId)) {
          const streamUrl = navidromeApi.getStreamUrl(song.id, song.path)
          analysisQueue.enqueue({
            id: `batch-${song.id}`,
            songId: cacheId,
            songTitle: song.title,
            streamUrl,
            priority: AnalysisPriority.LOW,
            isProactive: true,
          })
          enqueued++
        }
      })
      
      console.log(`[BATCH] ${enqueued} canciones encoladas (${songs.length - enqueued} ya en caché o en cola)`)
    },
    []
  )

  // =================================================================================
  // FIN: BLOQUE DE FUNCIONES REESTRUCTURADO
  // =================================================================================

  // --- Helper: configurar callbacks de WebAudioPlayer (progreso + automix) ---
  const configureWebAudioCallbacks = (player: WebAudioPlayer | NativeAudioPlayer) => {
    player.setCallbacks({
      onTimeUpdate: (currentTime, duration) => {
        setDuration(duration)

        // --- Sincronizar progreso (similar a HTML Audio, con throttle) ---
        progressRef.current = currentTime
        const now = Date.now()
        if (now - lastProgressUpdateRef.current >= 500) {
          setProgress(currentTime)
          lastProgressUpdateRef.current = now
        }

        // =================================================================================
        // 🎯 LÓGICA DE SCROBBLING (Last.fm y Wrapped) - Web Audio
        // =================================================================================
        
        // 1️⃣ Scrobble a Last.fm
        const currentSong = currentSongRef.current
        if (currentSong && duration > 0) {
          try {
            const scrobbleEnabled = localStorage.getItem('scrobbleEnabled')
            if (scrobbleEnabled === 'true' && !scrobblingDisabledRef.current) {
              // Asegurar que scrobbledSongsRef.current sea un Map
              if (!(scrobbledSongsRef.current instanceof Map)) {
                scrobbledSongsRef.current = new Map()
              }

              const songData = scrobbledSongsRef.current.get(currentSong.id)

              // Solo procesar si la canción está registrada y aún no ha sido scrobbeada
              if (songData && !songData.scrobbled) {
                // Calcular el umbral de scrobble: 50% de duración o 4 minutos, lo que sea menor
                const scrobbleThreshold = Math.min(duration * 0.5, 240) // 240 segundos = 4 minutos

                // Calcular el tiempo transcurrido desde que empezó la reproducción
                const timeSinceStart = (Date.now() - songData.startTime) / 1000

                // Solo scrobble por tiempo real transcurrido — jamás por currentTime.
                // El currentTime puede llegar ya alto cuando el receiver sincroniza posición,
                // disparando un falso scrobble inmediato sin que el usuario haya escuchado nada.
                if (timeSinceStart >= scrobbleThreshold) {
                  // Marcar como scrobbeada INMEDIATAMENTE para evitar duplicados
                  songData.scrobbled = true
                  scrobbledSongsRef.current.set(currentSong.id, songData)

                  // Timestamp en segundos Unix - tiempo de inicio de la canción
                  const timestampSeconds = Math.floor(songData.startTime / 1000)

                  // Enviar scrobble a Navidrome (play count)
                  navidromeApi
                    .scrobble(currentSong.id, timestampSeconds, true)
                    .then(success => {
                      if (success) {
                        console.log(
                          `[Scrobble - WebAudio] Canción scrobbeada: ${currentSong.title} - ${currentSong.artist} (${Math.round(currentTime)}s/${Math.round(duration)}s)`
                        )
                        // Notificar al backend via Socket.io para wrapped.db
                        scrobbleCallbackRef.current?.({
                          songId: currentSong.id,
                          title: currentSong.title,
                          artist: currentSong.artist,
                          album: currentSong.album,
                          albumId: currentSong.albumId,
                          duration,
                          playedAt: new Date(songData.startTime).toISOString(),
                          year: currentSong.year,
                          genre: currentSong.genre,
                          contextUri: currentContextUriRef.current,
                        })
                      } else {
                        // Si falla, permitir intentar de nuevo
                        songData.scrobbled = false
                        scrobbledSongsRef.current.set(currentSong.id, songData)
                      }
                    })
                    .catch(error => {
                      console.error('[Scrobble - WebAudio] Error al enviar scrobble:', error)
                      // Si falla, permitir intentar de nuevo
                      songData.scrobbled = false
                      scrobbledSongsRef.current.set(currentSong.id, songData)
                    })
                }
              }
            }
            // wrapped.db: gestionado por Socket.io callback (si conectado) o NowPlayingPoller (externo)
          } catch (error) {
            console.error('[WebAudio] Error en lógica de scrobbling:', error)
          }
        }

        // =================================================================================
        // 🎵 LÓGICA DE AUTOMIX - Web Audio
        // =================================================================================
        
        // Lógica de automix para Web Audio (similar a HTML Audio)
        // Solo ejecutar si está reproduciendo activamente, no en crossfade, no acaba de seek/pausa reciente, y hay canción actual
        // Usamos 5s de bloqueo tras seek para dar tiempo a la preparación del siguiente archivo
        const timeSincePause = Date.now() - lastPauseTimeRef.current
        const currentIndex = queueRef.current.findIndex(s => s.id === currentSongRef.current?.id)
        const hasNextSong = currentIndex >= 0 && currentIndex < queueRef.current.length - 1

        if (
          player.isCurrentlyPlaying() &&
          !isCrossfadingRef.current &&
          timeSincePause > 5000 &&
          currentSongRef.current &&
          duration > 0 &&
          hasNextSong
        ) {
          // === LÓGICA DE AUTOMIX (COPIADA DEL HTML AUDIO) ===
          let triggerTime: number | null = null
          let reason = ''
          const fadeDuration = crossfadeDurationRef.current
          const fallbackSeconds = settings.isDjMode ? 12 : 8
          const fallbackTriggerTime =
            duration > fallbackSeconds ? duration - fallbackSeconds : duration - 1

          // CRÍTICO: Buffer de tiempo para cargar la siguiente canción antes del fade
          const LOAD_BUFFER_TIME = 2.5

          const cacheId = currentSongRef.current
            ? generateStableCacheId(currentSongRef.current)
            : null
          const currentAnalysis = cacheId ? analysisCacheRef.current.get(cacheId) : undefined

          if (
            currentAnalysis &&
            !('error' in currentAnalysis) &&
            currentAnalysis.outroStartTime &&
            currentAnalysis.outroStartTime > 0 // Asegurarse de que no es 0
          ) {
            let shouldUseSmartOutro = true
            const smartOutroTime = currentAnalysis.outroStartTime
            const diagnostics = currentAnalysis.diagnostics
            const structure = currentAnalysis.structure

            if (!settings.isDjMode) {
              const lastChorusFromStructure =
                structure && structure.length > 0
                  ? Math.max(...structure.map(section => section.endTime ?? 0))
                  : null
              const lastChorusCandidate = diagnostics?.candidates?.last_chorus_end ?? null

              const lastRelevantSection = Math.max(
                lastChorusFromStructure ?? 0,
                lastChorusCandidate ?? 0
              )

              const MIN_GAP_BEFORE_LAST_CHORUS = 4 // segundos de margen mínimos

              if (
                lastRelevantSection > 0 &&
                smartOutroTime < lastRelevantSection - MIN_GAP_BEFORE_LAST_CHORUS
              ) {
                shouldUseSmartOutro = false
                reason = `Fallback Normal: último bloque relevante termina en ${lastRelevantSection.toFixed(
                  2
                )}s`
              }
            }

            if (shouldUseSmartOutro && smartOutroTime < fallbackTriggerTime) {
              // IMPORTANTE: Restar el buffer de carga para que el fade empiece justo en smartOutroTime
              triggerTime = Math.max(0, smartOutroTime - LOAD_BUFFER_TIME)
              reason = `Punto de mezcla inteligente en ${smartOutroTime.toFixed(
                2
              )}s (trigger anticipado: ${triggerTime.toFixed(2)}s para compensar carga)`
              if (settings.isDjMode) {
                reason = `Modo DJ: ${reason}`
              }
            } else {
              triggerTime = fallbackTriggerTime
              const ignoredOutro = smartOutroTime.toFixed(2)
              reason =
                reason ||
                `Fallback forzado (${settings.isDjMode ? 'DJ' : 'Normal'}): ${fallbackSeconds}s restantes (análisis de ${ignoredOutro}s ignorado por estar muy cerca del final)`
            }
          } else {
            // Fallback normal si no hay análisis o punto de outro.
            triggerTime = fallbackTriggerTime
            reason = `Fallback ${settings.isDjMode ? 'DJ' : 'Normal'}: ${fallbackSeconds}s restantes`
          }

          // Enviar trigger time a nativo (una vez por canción) para automix en background.
          // Si JS se congela (pantalla bloqueada), el timer nativo dispara el crossfade.
          if (triggerTime && !automixTriggerSentRef.current && IS_NATIVE && player instanceof NativeAudioPlayer) {
            automixTriggerSentRef.current = true
            const nextSongForAutomix = queueRef.current[currentIndex + 1]
            const nextCacheId = nextSongForAutomix ? generateStableCacheId(nextSongForAutomix) : null
            const nextCachedAnalysis = nextCacheId ? analysisCacheRef.current.get(nextCacheId) : undefined
            const nextAnalysisForConfig = (nextCachedAnalysis && !('error' in nextCachedAnalysis)) ? nextCachedAnalysis : undefined
            const currentAnalysisForConfig = (currentAnalysis && !('error' in currentAnalysis)) ? currentAnalysis : undefined

            // Pre-calcular config de crossfade para que nativo pueda ejecutarla autónomamente
            const automixConfig = calculateCrossfadeConfig({
              currentAnalysis: currentAnalysisForConfig ?? null,
              nextAnalysis: nextAnalysisForConfig ?? null,
              bufferADuration: duration,
              bufferBDuration: nextSongForAutomix?.duration || 180,
              mode: settings.isDjMode ? 'dj' : 'normal',
            })
            player.setAutomixTrigger(triggerTime, {
              entryPoint: automixConfig.entryPoint,
              fadeDuration: automixConfig.fadeDuration,
              transitionType: automixConfig.transitionType,
              useFilters: automixConfig.useFilters,
              useAggressiveFilters: automixConfig.useAggressiveFilters,
              needsAnticipation: automixConfig.needsAnticipation,
              anticipationTime: automixConfig.anticipationTime,
            })
            console.log(`[AUTOMIX-WEB] Trigger nativo configurado: ${triggerTime.toFixed(1)}s (${automixConfig.transitionType})`)
          }

          if (triggerTime && currentTime >= triggerTime) {
            // Si queda muy poco tiempo (< 3s), no intentar crossfade — la canción
            // terminará antes de que la descarga/preparación del siguiente archivo complete.
            // Dejar que onEnded haga la transición directa.
            const remaining = duration - currentTime
            if (remaining < 3) {
              console.log(`[AUTOMIX-WEB] Omitiendo crossfade: solo quedan ${remaining.toFixed(1)}s — se usará transición directa al terminar`)
              return
            }
            // Limpiar trigger nativo (JS lo va a manejar)
            if (IS_NATIVE && player instanceof NativeAudioPlayer) {
              player.clearAutomixTrigger()
            }
            console.log(
              `[AUTOMIX-WEB] Lanzando crossfade. Razón: ${reason}. (tiempoActual: ${currentTime.toFixed(
                2
              )}s, trigger: ${triggerTime.toFixed(2)}s, durFundido: ${fadeDuration.toFixed(2)}s)`
            )
            nextCallbackRef.current?.(true) // true = usar crossfade para automix
            return
          }
        }
      },


      onEnded: () => {
        // Si el crossfade estaba "en curso" pero la canción terminó de todas formas,
        // significa que el crossfade se rompió/nunca arrancó. Resetear antes de avanzar.
        if (isCrossfadingRef.current) {
          console.warn('[WebAudioPlayer] Canción terminó con crossfade supuestamente en curso — reseteando crossfade roto')
          isCrossfadingRef.current = false
          setIsCrossfading(false)
        }
        console.log('[WebAudioPlayer] Canción terminó, llamando next()')
        nextCallbackRef.current?.(true) // true = usar crossfade para transición suave
      },
      onRecoveryNeeded: (song, position) => {
        // El pipeline de audio se reconstruyó tras una suspensión profunda de iOS
        // pero el buffer se perdió — necesitamos recargar la canción
        console.log(`[WebAudioPlayer] 🔄 Recovery needed: recargando "${song.title}" desde ${position.toFixed(1)}s`)
        const streamUrl = navidromeApi.getStreamUrl(song.id, song.path)
        webAudioPlayerRef.current?.play(song, streamUrl, true).then(() => {
          if (position > 0) {
            webAudioPlayerRef.current?.seek(position)
          }
          setIsPlaying(true)
          updateMediaSession(song, true)
        }).catch(err => {
          console.error('[WebAudioPlayer] ❌ Error en recovery:', err)
          setIsPlaying(false)
        })
      },
      onError: (error) => {
        console.error('[WebAudioPlayer] Error:', error)
        const songId = currentSongRef.current?.id
        const song = currentSongRef.current
        const errorMsg = error instanceof Error ? error.message : String(error)

        // Watchdog recovery: native audio stopped responding silently.
        // Attempt to reload the current song from its last known position.
        const isWatchdog = errorMsg.includes('Watchdog')
        if (isWatchdog && song) {
          console.warn('[PlayerContext] 🔄 Watchdog recovery: reloading current song')
          const currentPosition = progressRef.current
          playSong(song, true).then(() => {
            if (currentPosition > 1) {
              webAudioPlayerRef.current?.seek(currentPosition)
            }
          }).catch(err => {
            console.error('[PlayerContext] Watchdog recovery failed:', err)
            setIsPlaying(false)
          })
          return
        }

        // Retry on network errors (timeout, fetch failure, etc.)
        const isRetryable = errorMsg.includes('fetch') || errorMsg.includes('network')
          || errorMsg.includes('Failed') || errorMsg.includes('abort') || errorMsg.includes('timeout')

        if (songId && song && isRetryable && streamRetryManager.shouldRetry(songId)) {
          const currentPosition = progressRef.current
          streamRetryManager.scheduleRetry(async () => {
            if (!webAudioPlayerRef.current || !currentSongRef.current) throw new Error('No player')
            const retryUrl = navidromeApi.getStreamUrl(song.id, song.path)
            await webAudioPlayerRef.current.play(song, retryUrl, false)
            if (currentPosition > 0) {
              webAudioPlayerRef.current.seek(currentPosition)
            }
            setIsPlaying(true)
          })
          return
        }
        setIsPlaying(false)
      },
      onCrossfadeStart: () => {
        setIsCrossfading(true)
      },
      onCrossfadeComplete: (nextSong, startOffset = 0) => {
        console.log(
          '[WebAudioPlayer] Crossfade completado - cambiando a:',
          nextSong.title,
          'offset inicial:',
          startOffset.toFixed(2)
        )
        setIsCrossfading(false)
        setIsPlaying(true)
        // Actualizar canción actual
        const newCurrentSong = {
          title: nextSong.title,
          artist: nextSong.artist,
          album: nextSong.album,
          coverArt: nextSong.coverArt,
          duration: nextSong.duration,
          id: nextSong.id,
          path: nextSong.path,
          albumId: nextSong.albumId,
          playlistId: nextSong.playlistId,
        }
        setCurrentSong(newCurrentSong)
        currentSongRef.current = nextSong
        // Establecer progreso inicial basado en el offset donde empezó la canción
        progressRef.current = startOffset
        // Forzar que el siguiente onTimeUpdate refresque inmediatamente el progreso en UI
        lastProgressUpdateRef.current = Date.now() - 501
        setProgress(startOffset)
        setDuration(nextSong.duration)
        updateMediaSession(newCurrentSong, true)

        // 🎯 Registrar el tiempo de inicio de reproducción para scrobble (Web Audio)
        // Asegurar que scrobbledSongsRef.current sea un Map
        if (!(scrobbledSongsRef.current instanceof Map)) {
          scrobbledSongsRef.current = new Map()
        }
        // Registrar el tiempo de inicio solo si no está ya registrada o si ya fue scrobbeada
        const existingData = scrobbledSongsRef.current.get(nextSong.id)
        if (!existingData || existingData.scrobbled) {
          scrobbledSongsRef.current.set(nextSong.id, {
            scrobbled: false,
            wrappedScrobbled: false,
            startTime: Date.now(),
          })
        }

        // Enviar "now playing" a Last.fm cuando empieza una nueva canción en crossfade
        const scrobbleEnabled = localStorage.getItem('scrobbleEnabled')
        if (scrobbleEnabled === 'true') {
          navidromeApi.scrobble(nextSong.id, undefined, false).catch(error => {
            console.error('[Scrobble - WebAudio] Error al enviar "now playing" en crossfade:', error)
          })
        }

        console.log(
          '[WebAudioPlayer] Estado actualizado - nueva canción:',
          newCurrentSong.title,
          'duración:',
          nextSong.duration,
          'progreso inicial:',
          startOffset.toFixed(2)
        )
      },
      onPlaybackStateChanged: (playing, currentTime, reason) => {
        // Swift pausa/reanuda por causa externa (llamada, BT desconectado, nota de voz, etc.)
        console.log(`[NativeAudio] Estado externo: isPlaying=${playing}, time=${currentTime.toFixed(1)}, reason=${reason}`)
        setIsPlaying(playing)
        if (!playing) {
          // Congelar progreso en el punto exacto de pausa nativo
          progressRef.current = currentTime
          setProgress(currentTime)
        }
        updateMediaSession(currentSongRef.current, playing)
      },
      onCrossfadeFailed: () => {
        // El crossfade no pudo ejecutarse (archivo siguiente no preparado, etc.)
        // Resetear estado de crossfade y hacer transición directa a la siguiente canción
        console.warn('[PlayerContext] Crossfade falló — fallback a playSong directo')
        isCrossfadingRef.current = false
        setIsCrossfading(false)
        automixTriggerSentRef.current = false
        // Buscar la siguiente canción y reproducirla directamente
        const currentIndex = queueRef.current.findIndex(s => s.id === currentSongRef.current?.id)
        if (currentIndex >= 0 && currentIndex < queueRef.current.length - 1) {
          const nextSong = queueRef.current[currentIndex + 1]
          playSong(nextSong).catch(error => {
            console.error('[PlayerContext] Error en fallback playSong tras crossfade fallido:', error)
            // Si el fallback también falla, asegurar que la UI refleje que no está reproduciendo
            setIsPlaying(false)
          })
        } else {
          // No hay siguiente canción — asegurar que la UI no quede en estado "reproduciendo"
          setIsPlaying(false)
        }
      },
      onNativeNext: (data) => {
        // Nativo cambió de canción mientras JS estaba congelado en background.
        // Sincronizar estado de React con lo que nativo ya está reproduciendo.
        console.log(`[PlayerContext] Native next en background: "${data.title}"`)
        isCrossfadingRef.current = false
        setIsCrossfading(false)
        setIsPlaying(true)

        // Buscar la canción en la cola por título/artista (no tenemos songId desde nativo)
        const currentIndex = queueRef.current.findIndex(s => s.id === currentSongRef.current?.id)
        if (currentIndex >= 0 && currentIndex < queueRef.current.length - 1) {
          const nextSong = queueRef.current[currentIndex + 1]
          setCurrentSong(nextSong)
          currentSongRef.current = nextSong
          progressRef.current = 0
          setProgress(0)
          setDuration(data.duration || nextSong.duration)
          updateMediaSession(nextSong, true)
        }
      },
    })
  }

  // --- EFECTOS DE CICLO DE VIDA ---

  // Efecto 1: Inicialización de los elementos de audio y cola de análisis
  useEffect(() => {
    // Solo log en desarrollo y si no hay elementos ya inicializados
    if (process.env.NODE_ENV === 'development' && !audioRef.current) {
      console.log('[PlayerContext] Inicializando elementos de audio y cola de análisis')
    }

    // Inicializar elementos de audio según configuración
    if (IS_NATIVE) {
      // iOS nativo: usar AVAudioEngine via NativeAudioPlayer
      console.log('[PlayerContext] Inicializando Native Audio Engine (AVAudioEngine)')
      webAudioPlayerRef.current = new NativeAudioPlayer()
      configureWebAudioCallbacks(webAudioPlayerRef.current)
      webAudioPlayerRef.current.setConfig({
        crossfadeDuration: 8,
        volume: volume,
        isDjMode: settings.isDjMode,
        useReplayGain: settings.useReplayGain,
      })
      // Listener para next/prev remotos (lock screen, Dynamic Island)
      nativeAudio.addListener('onRemoteCommand', ({ action }) => {
        // Ack al nativo para cancelar fallback (JS está vivo y procesó el comando)
        nativeAudio.ackRemoteCommand().catch(() => {})
        if (action === 'next') nextCallbackRef.current?.()
        if (action === 'previous') previous()
      })
    } else if (shouldUseWebAudio()) {
      console.log('[PlayerContext] Inicializando Web Audio API')
      webAudioPlayerRef.current = new WebAudioPlayer()
      configureWebAudioCallbacks(webAudioPlayerRef.current)
      // Configurar settings iniciales
      webAudioPlayerRef.current.setConfig({
        crossfadeDuration: 8,
        volume: volume,
        isDjMode: settings.isDjMode,
        useReplayGain: settings.useReplayGain,
      })
    } else {
      console.log('[PlayerContext] Inicializando HTML Audio Elements')
      audioRef.current = new Audio()
      nextAudioRef.current = new Audio()
    }

    // Configurar callbacks de reconexión de stream
    streamRetryManager.setCallbacks({
      onRetrying: (attempt, max) => {
        console.log(`[StreamRetry] Reconectando... (${attempt}/${max})`)
        setIsReconnecting(true)
      },
      onRecovered: () => {
        setIsReconnecting(false)
      },
      onGaveUp: () => {
        console.warn('[StreamRetry] Se agotaron los reintentos')
        setIsReconnecting(false)
      },
    })

    // Inicializar cola de análisis con la función analyze
    analysisQueue.setAnalyzeFunction(async (streamUrl, songId, isProactive) => {
      const result = await analyze(streamUrl, songId, isProactive)
      if (result) {
        analysisCacheRef.current.set(songId, result)

        // Sincronizar dinámicamente con WebAudioPlayer si es la canción actual o la siguiente
        if (webAudioPlayerRef.current) {
          const currentId = currentSongRef.current ? generateStableCacheId(currentSongRef.current) : null

          if (currentId && currentId === songId) {
            // Es la canción actual → actualizar currentAnalysis
            webAudioPlayerRef.current.setCurrentAnalysis(result)
            console.log(`[SYNC] ✅ currentAnalysis actualizado para canción en reproducción`)
          } else {
            // Verificar si es la siguiente canción en la cola
            const currentIdx = currentId
              ? queueRef.current.findIndex(s => generateStableCacheId(s) === currentId)
              : -1
            const nextSongInQueue = currentIdx >= 0 && currentIdx < queueRef.current.length - 1
              ? queueRef.current[currentIdx + 1]
              : null
            const nextId = nextSongInQueue ? generateStableCacheId(nextSongInQueue) : null

            if (nextId && nextId === songId) {
              // Es la siguiente canción → actualizar nextAnalysis en el player
              webAudioPlayerRef.current.setNextAnalysis(result)
              console.log(`[SYNC] ✅ nextAnalysis actualizado dinámicamente para: "${nextSongInQueue?.title}"`)
            }
          }
        }

        // LOG DE DIAGNÓSTICO
        if (result.diagnostics) {
          const songData = queueRef.current.find(s => generateStableCacheId(s) === songId)
          console.log(
            `[DIAGNÓSTICO ANÁLISIS] para "${songData?.title || songId}":`,
            result.diagnostics
          )
        }
      } else {
        // Guardar error en caché para evitar bucles infinitos en Smart Mix
        analysisCacheRef.current.set(songId, { error: 'Failed analysis' })
      }
      return result
    })

    // Función de limpieza para cuando el componente se desmonte
    return () => {
      // Solo log en desarrollo
      if (process.env.NODE_ENV === 'development') {
        console.log('[PlayerContext] Limpiando elementos de audio y cola')
      }
      if (audioRef.current) {
        audioRef.current.pause()
        audioRef.current.src = ''
      }
      if (nextAudioRef.current) {
        nextAudioRef.current.pause()
        nextAudioRef.current.src = ''
      }
      if (webAudioPlayerRef.current) {
        webAudioPlayerRef.current.dispose()
      }
      // Limpiar cola de análisis y servicios de resiliencia
      analysisQueue.clear()
      queuePrefetcher.cancelAll()
      streamRetryManager.dispose()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [analyze]) // Incluir analyze como dependencia

  // Efecto: Cambios en configuración de Web Audio (permitir alternancia en runtime)
  // En nativo, siempre usamos NativeAudioPlayer — no hay alternancia.
  useEffect(() => {
    if (IS_NATIVE) return
    const currentUseWebAudio = shouldUseWebAudio()

    // Estado actual de reproducción antes del cambio
    const wasPlayingHtmlAudio = audioRef.current && !audioRef.current.paused
    const wasPlayingWebAudio = webAudioPlayerRef.current?.isCurrentlyPlaying() || false
    const isCurrentlyPlaying = wasPlayingHtmlAudio || wasPlayingWebAudio

    const currentSong = currentSongRef.current
    const currentProgress = wasPlayingWebAudio
      ? webAudioPlayerRef.current?.getCurrentTime() || progress
      : progress

    // Solo log cuando realmente hay un cambio significativo
    if (currentUseWebAudio !== (webAudioPlayerRef.current ? true : false)) {
      console.log(`[PlayerContext] Cambiando sistema de audio: ${currentUseWebAudio ? 'Web Audio' : 'HTML Audio'}, estaba reproduciendo: ${isCurrentlyPlaying}`)
    }

    // Si cambió la configuración, necesitamos hacer transición
    if (currentUseWebAudio && !webAudioPlayerRef.current) {
      console.log('[PlayerContext] Creando nueva instancia de WebAudioPlayer')
      console.log('[PlayerContext] Cambiando a Web Audio API')

      // Limpiar HTML Audio
      if (audioRef.current) {
        audioRef.current.pause()
        audioRef.current.src = ''
        audioRef.current = null
      }
      if (nextAudioRef.current) {
        nextAudioRef.current.pause()
        nextAudioRef.current.src = ''
        nextAudioRef.current = null
      }

      // Inicializar Web Audio
      webAudioPlayerRef.current = new WebAudioPlayer()
      configureWebAudioCallbacks(webAudioPlayerRef.current)

      // Si había música reproduciéndose, continuar desde el mismo punto
        if (isCurrentlyPlaying && currentSong) {
          console.log('[PlayerContext] Reanudando reproducción en Web Audio desde:', currentProgress)
          lastPauseTimeRef.current = Date.now() // Evitar que automix se active inmediatamente
          setTimeout(async () => {
            try {
              if (webAudioPlayerRef.current) {
                const streamUrl = navidromeApi.getStreamUrl(currentSong.id, currentSong.path)
                await webAudioPlayerRef.current.play(currentSong, streamUrl, false)
                if (currentProgress > 0) {
                  webAudioPlayerRef.current.seek(currentProgress)
                }
              }
            } catch (error) {
              console.error('[PlayerContext] Error reanudando en Web Audio:', error)
            }
          }, 100) // Pequeño delay para asegurar inicialización
        } else if (currentSong && !isCurrentlyPlaying) {
          // RESTAURACIÓN DE ESTADO Web Audio (Pausa)
          console.log('[PlayerContext] Restaurando estado pausado Web Audio:', currentSong.title)
          setTimeout(async () => {
             try {
               if (webAudioPlayerRef.current && currentSong) {
                 // Por ahora, al menos pongamos el progreso visual.
                 setProgress(currentProgress)
                 progressRef.current = currentProgress
                 setDuration(currentSong.duration)
               }
             } catch (e) { console.error(e) }
          }, 100)
        }

    } else if (!currentUseWebAudio && !audioRef.current) {
      console.log('[PlayerContext] Cambiando a HTML Audio')

      // Limpiar Web Audio
      if (webAudioPlayerRef.current) {
        webAudioPlayerRef.current.dispose()
        webAudioPlayerRef.current = null
      }

      // Inicializar HTML Audio
      audioRef.current = new Audio()
      nextAudioRef.current = new Audio()

      // Aplicar listeners al nuevo HTML Audio
      if (audioRef.current) {
        applyAudioListeners(audioRef.current)
      }

      // Si había música reproduciéndose, continuar desde el mismo punto
      if (isCurrentlyPlaying && currentSong) {
        console.log('[PlayerContext] Reanudando reproducción en HTML Audio desde:', currentProgress)
        lastPauseTimeRef.current = Date.now() // Evitar que automix se active inmediatamente
        setTimeout(async () => {
          try {
            await playSong(currentSong, false)
            if (currentProgress > 0) {
              seek(currentProgress)
            }
          } catch (error) {
            console.error('[PlayerContext] Error reanudando en HTML Audio:', error)
          }
        }, 100) // Pequeño delay para asegurar inicialización
      } else if (currentSong && !isCurrentlyPlaying) {
        // RESTAURACIÓN DE ESTADO (Página recargada / Pestaña cerrada)
        // Si hay canción guardada pero no estaba reproduciendo, restaurar src y currentTime sin reproducir
        console.log('[PlayerContext] Restaurando estado pausado HTML Audio:', currentSong.title)
        const streamUrl = navidromeApi.getStreamUrl(currentSong.id, currentSong.path)
        
        if (audioRef.current) {
            audioRef.current.src = streamUrl
            
            // Importante: No llamar a load() aquí si no queremos buffer inmediato, 
            // pero para seek necesitamos metadata.
            audioRef.current.load() 
            
            // Esperar metadata para seek
            const onLoadedMetadataRestored = () => {
                if (audioRef.current) {
                    audioRef.current.currentTime = currentProgress
                    setProgress(currentProgress)
                    setDuration(audioRef.current.duration)
                }
            }
            audioRef.current.addEventListener('loadedmetadata', onLoadedMetadataRestored, { once: true })
        }
      }
    }

    // Actualizar configuración en Web Audio si está activo
    if (webAudioPlayerRef.current) {
      webAudioPlayerRef.current.setConfig({
        crossfadeDuration: 8,
        volume: volume,
        isDjMode: settings.isDjMode,
        useReplayGain: settings.useReplayGain,
      })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [settings.useWebAudio, settings.isDjMode, settings.useReplayGain, volume, playSong, seek])

  // Efecto 2: Aplicar y re-aplicar los listeners de eventos de audio
  useEffect(() => {
    const audio = audioRef.current
    if (audio) {
      applyAudioListeners(audio)
    }
    // No necesita una función de limpieza aquí porque applyAudioListeners ya se encarga
    // de remover los listeners antiguos antes de poner los nuevos.
  }, [applyAudioListeners])

  // Efecto 3: Sincronizar el estado del volumen con el elemento de audio
  useEffect(() => {
    // Sincroniza la ref del volumen para que el crossfade use el valor más reciente
    volumeRef.current = volume

    // Aplica el volumen al elemento de audio principal, solo si no hay un crossfade en curso
    if (audioRef.current && !isCrossfadingRef.current) {
      audioRef.current.volume = volume / 100
    }
  }, [volume])

  // Efecto: Sincronizar la referencia de crossfade con el estado
  useEffect(() => {
    isCrossfadingRef.current = isCrossfading
  }, [isCrossfading])

  // --- EFECTO: Expiración del Smart Mix después de 30 minutos ---
  useEffect(() => {
    if (smartMixTimestamp && generatedSmartMix.length > 0) {
      const expirationTime = 30 * 60 * 1000 // 30 minutos en milisegundos
      const timeRemaining = expirationTime - (Date.now() - smartMixTimestamp)

      if (timeRemaining <= 0) {
        clearSmartMix()
        return
      }

      const timeoutId = setTimeout(() => {
        clearSmartMix()
      }, timeRemaining)

      return () => clearTimeout(timeoutId)
    }
  }, [smartMixTimestamp, generatedSmartMix.length, clearSmartMix])

  // Sincronizar la ref de `next` para los listeners
  useEffect(() => {
    nextCallbackRef.current = next
  })

  // Efecto: Escuchar acciones de medios del sistema operativo (lock screen,
  // Dynamic Island, Control Center, auriculares).
  // En iOS nativo (WKWebView), setActionHandler DEBE estar registrado para que
  // WebKit mantenga la media session activa y setPositionState funcione (barra
  // de progreso en lock screen). WebKit internamente toma control de
  // MPRemoteCommandCenter cuando hay action handlers registrados, así que estos
  // handlers son el camino principal para recibir comandos remotos.
  //
  // Importante: usamos refs en los handlers para evitar tener progress/duration
  // en las dependencias del efecto, lo que causaba churn constante (re-registro
  // de handlers cada frame) y ventanas donde los handlers estaban en null.
  useEffect(() => {
    // En nativo, los remote commands (play/pause/seek) se manejan directamente
    // en Swift via MPRemoteCommandCenter → AudioEngineManager. Next/prev llegan
    // via evento onRemoteCommand. No registrar mediaSession handlers en JS
    // para evitar el double-toggle (WebKit + nativo ambos interceptando).
    if (IS_NATIVE) return

    if (typeof navigator === 'undefined' || !('mediaSession' in navigator)) {
      return
    }

    const handlers: Array<[MediaSessionAction, (details?: MediaSessionActionDetails) => void]> = [
      [
        'play',
        () => {
          console.log('[MediaSession] play action received')
          togglePlayPause()
        },
      ],
      [
        'pause',
        () => {
          console.log('[MediaSession] pause action received')
          togglePlayPause()
        },
      ],
      ['previoustrack', () => {
        console.log('[MediaSession] previoustrack action received')
        previous()
      }],
      ['nexttrack', () => {
        console.log('[MediaSession] nexttrack action received')
        nextCallbackRef.current?.()
      }],
      [
        'seekbackward',
        details => {
          const offset = details?.seekOffset ?? 10
          seek(Math.max(0, progressRef.current - offset))
        },
      ],
      [
        'seekforward',
        details => {
          const offset = details?.seekOffset ?? 10
          const dur = currentSong?.duration ?? Infinity
          seek(Math.min(dur, progressRef.current + offset))
        },
      ],
      [
        'seekto',
        details => {
          if (details?.seekTime != null) {
            const dur = currentSong?.duration ?? Infinity
            seek(Math.min(dur, Math.max(0, details.seekTime)))
          }
        },
      ],
    ]

    for (const [action, handler] of handlers) {
      try {
        navigator.mediaSession.setActionHandler(action, handler)
      } catch (error) {
        console.warn(`[MediaSession] Acción no soportada: ${action}`, error)
      }
    }

    return () => {
      for (const [action] of handlers) {
        try {
          navigator.mediaSession.setActionHandler(action, null)
        } catch (error) {
          /* ignore cleanup errors */
        }
      }
    }
  // Dependencias estables: togglePlayPause, previous, seek son useCallback con
  // deps estables. nextCallbackRef y progressRef son refs (nunca cambian).
  // currentSong?.duration cambia solo al cambiar de canción.
  // NO incluir progress ni duration como valores directos — usar refs.
  }, [togglePlayPause, previous, seek, currentSong?.duration])

  // Efecto: Actualizar Media Session cuando cambie la canción o el estado de reproducción
  useEffect(() => {
    updateMediaSession(currentSong, isPlaying)
  }, [currentSong, isPlaying, updateMediaSession])

  // Efecto: Re-afirmar positionState periódicamente en iOS nativo.
  // Con NativeAudioPlayer, Swift actualiza MPNowPlayingInfoCenter directamente
  // a 4Hz — este workaround ya no es necesario. Solo se mantiene si se usa
  // WebAudioPlayer (no debería ocurrir en nativo, pero por seguridad).
  useEffect(() => {
    if (!IS_NATIVE || !isPlaying || !currentSong?.duration) return
    // Con NativeAudioPlayer, progress se actualiza directamente en Swift
    if (webAudioPlayerRef.current instanceof NativeAudioPlayer) return

    const timer = setInterval(() => {
      try {
        const pos = Math.min(progressRef.current, currentSong.duration!)
        navigator.mediaSession.setPositionState({
          duration: currentSong.duration!,
          playbackRate: 1,
          position: Math.max(0, pos),
        })
      } catch { /* ignore */ }
    }, 3000)

    return () => clearInterval(timer)
  }, [isPlaying, currentSong?.id, currentSong?.duration])

  // --- PERSISTENCIA DEL ESTADO REPRODUCTOR ---

  // 1. Guardar canción actual inmediatamente al cambiar
  useEffect(() => {
    if (currentSong) {
      console.log(`[PlayerContext] Persistiendo canción actual: ${currentSong.title}`)
      localStorage.setItem(userKey('playerCurrentSong'), JSON.stringify(currentSong))
      // Intentar deducir la fuente si no está mapeada pero el objeto song la tiene
      if (!currentSourceRef.current) {
        if (currentSong.playlistId) {
             const newSource = `playlist:${currentSong.playlistId}`
             currentSourceRef.current = newSource
             setCurrentSource(newSource)
             localStorage.setItem(userKey('playerSource'), newSource)
        } else if (currentSong.albumId) {
             const newSource = `album:${currentSong.albumId}`
             currentSourceRef.current = newSource
             setCurrentSource(newSource)
             localStorage.setItem(userKey('playerSource'), newSource)
        }
      }
    } else {
      localStorage.removeItem(userKey('playerCurrentSong'))
      localStorage.removeItem(userKey('playerSource'))
    }
  }, [currentSong])

  // 2.b Guardar fuente de reproducción
  useEffect(() => {
    if (currentSource) {
      localStorage.setItem(userKey('playerSource'), currentSource)
    } else {
      localStorage.removeItem(userKey('playerSource'))
    }
  }, [currentSource])

  // 3. Guardar progreso periódicamente (cada 2s) y al pausar/desmontar
  useEffect(() => {
    // No guardar si no hay canción
    if (!currentSong) return

    const saveProgress = () => {
      // Guardar en localStorage
      const now = new Date().toISOString()
      localStorage.setItem(userKey('playerProgress'), progressRef.current.toString())
      localStorage.setItem(userKey('playerSavedAt'), now)

      // Guardar en Backend (si hay usuario)
      const config = navidromeApi.getConfig()
      if (config?.username) {
        // Usar los refs para tener los valores más actualizados posible
        const currentProgress = progressRef.current
                backendApi.saveLastPlayback(config.username, {
          songId: currentSong.id,
          title: currentSong.title,
          artist: currentSong.artist,
          album: currentSong.album,
          coverArt: currentSong.coverArt,
          albumId: currentSong.albumId,
          path: currentSong.path,
          duration: duration,
          position: currentProgress,
          savedAt: new Date().toISOString(),
          queue: queueRef.current, // Guardar la cola
        })
      }
    }

    // Intervalo para guardar periódicamente mientras se reproduce
    const intervalId = setInterval(() => {
        if (isPlaying) {
            saveProgress()
        }
    }, 2000)

    // Guardar también al desmontar o cambiar canción/estado (cleanup)
    return () => {
        clearInterval(intervalId)
        saveProgress()
    }
  }, [currentSong, isPlaying, duration])
  
  // 4. Guardar al cerrar la pestaña, ir a background, o cambiar de app
  // NOTA: En iOS/WKWebView, beforeunload NO se dispara de forma fiable al cerrar
  // la app. Usamos visibilitychange + pagehide como fallback robusto.
  useEffect(() => {
    const saveFullState = (useBeacon: boolean) => {
      if (!currentSongRef.current) return
      // Guardar local
      const now = new Date().toISOString()
      localStorage.setItem(userKey('playerProgress'), progressRef.current.toString())
      localStorage.setItem(userKey('playerSavedAt'), now)
      safeSetItem(userKey('playerQueue'), JSON.stringify(queueRef.current.map(minimalSong)))

      const config = navidromeApi.getConfig()
      if (config?.username) {
        backendApi.saveLastPlayback(config.username, {
          songId: currentSongRef.current.id,
          title: currentSongRef.current.title,
          artist: currentSongRef.current.artist,
          album: currentSongRef.current.album,
          coverArt: currentSongRef.current.coverArt,
          albumId: currentSongRef.current.albumId,
          path: currentSongRef.current.path,
          duration: duration,
          position: progressRef.current,
          savedAt: new Date().toISOString(),
          queue: queueRef.current,
        }, useBeacon)
      }
    }

    const handleBeforeUnload = () => saveFullState(true)
    const handleVisibilityChange = () => {
      if (document.visibilityState === 'hidden') saveFullState(true)
    }
    const handlePageHide = () => saveFullState(true)

    window.addEventListener('beforeunload', handleBeforeUnload)
    document.addEventListener('visibilitychange', handleVisibilityChange)
    window.addEventListener('pagehide', handlePageHide)
    return () => {
      window.removeEventListener('beforeunload', handleBeforeUnload)
      document.removeEventListener('visibilitychange', handleVisibilityChange)
      window.removeEventListener('pagehide', handlePageHide)
    }
  }, [duration])

  // 4b. Reconciliar estado nativo al volver de background (pantalla bloqueada → desbloqueo)
  // Sincroniza TODO: isPlaying, progress, duration, canción actual (puede haber cambiado
  // por crossfade/next nativo mientras JS estaba congelado).
  useEffect(() => {
    if (!IS_NATIVE) return
    const handleVisibility = async () => {
      if (document.visibilityState !== 'visible') return
      if (!(webAudioPlayerRef.current instanceof NativeAudioPlayer)) return
      const player = webAudioPlayerRef.current as NativeAudioPlayer

      try {
        await player.reconcileState()
        const nativeState = await nativeAudio.getPlaybackState()

        // 1. Reconciliar estado básico de reproducción
        setIsPlaying(nativeState.isPlaying)
        progressRef.current = nativeState.currentTime
        setProgress(nativeState.currentTime)
        setDuration(nativeState.duration)
        setIsCrossfading(nativeState.isCrossfading)
        isCrossfadingRef.current = nativeState.isCrossfading

        // 2. Reconciliar canción actual: comparar título nativo con la canción actual de React.
        //    Si no coincide, nativo cambió de canción en background (automix/next nativo).
        const nativeTitle = nativeState.title
        const jsTitle = currentSongRef.current?.title
        if (nativeTitle && nativeTitle !== jsTitle) {
          console.log(`[PlayerContext] Canción cambió en background: JS="${jsTitle}" → Nativo="${nativeTitle}"`)
          // Buscar en la cola por título+artista para encontrar la canción correcta
          const matchingSong = queueRef.current.find(s =>
            s.title === nativeTitle && (
              (typeof s.artist === 'string' ? s.artist : '') === nativeState.artist
            )
          )
          if (matchingSong) {
            setCurrentSong(matchingSong)
            currentSongRef.current = matchingSong
            setDuration(nativeState.duration || matchingSong.duration)
            updateMediaSession(matchingSong, nativeState.isPlaying)
            console.log(`[PlayerContext] Canción reconciliada: "${matchingSong.title}" (queue match)`)
          } else {
            // Fallback: buscar por título adelante en la cola desde la última posición conocida
            // (puede haber avanzado múltiples canciones por automix en background)
            const lastIdx = queueRef.current.findIndex(s => s.id === currentSongRef.current?.id)
            if (lastIdx >= 0) {
              let found = false
              for (let i = lastIdx + 1; i < queueRef.current.length; i++) {
                if (queueRef.current[i].title === nativeTitle) {
                  const match = queueRef.current[i]
                  setCurrentSong(match)
                  currentSongRef.current = match
                  setDuration(nativeState.duration || match.duration)
                  updateMediaSession(match, nativeState.isPlaying)
                  console.log(`[PlayerContext] Canción reconciliada por posición: "${match.title}" (idx ${i})`)
                  found = true
                  break
                }
              }
              if (!found && lastIdx < queueRef.current.length - 1) {
                // Último recurso: avanzar una posición
                const nextInQueue = queueRef.current[lastIdx + 1]
                setCurrentSong(nextInQueue)
                currentSongRef.current = nextInQueue
                setDuration(nativeState.duration || nextInQueue.duration)
                updateMediaSession(nextInQueue, nativeState.isPlaying)
                console.log(`[PlayerContext] Canción reconciliada por posición+1: "${nextInQueue.title}"`)
              }
            }
          }
          // Resetear automix para la nueva canción
          automixTriggerSentRef.current = false
          outroRefinedForCurrentSongRef.current = false
        }

        console.log(`[PlayerContext] Reconciliación completa: playing=${nativeState.isPlaying}, time=${nativeState.currentTime.toFixed(1)}s, song="${nativeState.title}"`)
      } catch (err) {
        console.error('[PlayerContext] Error en reconciliación:', err)
      }
    }
    document.addEventListener('visibilitychange', handleVisibility)
    return () => document.removeEventListener('visibilitychange', handleVisibility)
  }, [])

  // 5. RESTAURAR ESTADO DESDE BACKEND (Sincronización multidispositivo)
  // Compara timestamps: si el backend tiene datos más recientes que localStorage,
  // los usa (el usuario escuchó algo en otro dispositivo). Esto permite que al abrir
  // el PC después de escuchar en el móvil, se vea la misma canción y posición.
  useEffect(() => {
    const restoreFromBackend = async () => {
        const config = navidromeApi.getConfig()
        if (!config?.username) return

        try {
            const state = await backendApi.getLastPlayback(config.username)
            if (!state || !state.songId) return

            console.log('[PlayerContext] Estado recuperado del backend:', state)

            // Comparar timestamps: ¿el backend es más reciente que lo local?
            const localSavedAt = localStorage.getItem(userKey('playerSavedAt'))
            const backendTime = state.savedAt ? new Date(state.savedAt).getTime() : 0
            const localTime = localSavedAt ? new Date(localSavedAt).getTime() : 0
            const backendIsNewer = backendTime > localTime
            const hasLocalSong = !!currentSongRef.current
            const localSongDiffers = hasLocalSong && currentSongRef.current?.id !== state.songId

            // Usar backend si: no hay canción local, o el backend es más reciente
            // (incluye caso donde usuario escuchó otra canción en otro dispositivo)
            const shouldRestoreSong = !isPlaying && (!hasLocalSong || (backendIsNewer && localSongDiffers))
            const shouldRestoreQueue = !queueRef.current?.length || (backendIsNewer && localSongDiffers)

            // 1. Restaurar Cola
            if (shouldRestoreQueue && state.queue && Array.isArray(state.queue) && state.queue.length > 0) {
                console.log(`[PlayerContext] Restaurando cola de ${state.queue.length} canciones desde backend`)
                const restoredQueue = state.queue as Song[]
                setQueueState(restoredQueue)
                queueRef.current = restoredQueue
                safeSetItem(userKey('playerQueue'), JSON.stringify(restoredQueue.map(minimalSong)))
            }

            // 2. Restaurar Canción y Posición
            if (shouldRestoreSong) {
                 const restoredSong: Song = {
                     id: state.songId,
                     title: state.title,
                     artist: state.artist,
                     album: state.album,
                     coverArt: state.coverArt,
                     albumId: state.albumId,
                     path: state.path,
                     duration: state.duration,
                     year: 0,
                     track: 0,
                     genre: '',
                 }

                 console.log(`[PlayerContext] Restaurando canción desde backend: ${restoredSong.title} @ ${state.position}s (backend ${backendIsNewer ? 'más reciente' : 'mismo timestamp'})`)
                 setCurrentSong(restoredSong)
                 currentSongRef.current = restoredSong

                 // Restaurar posición
                 setProgress(state.position)
                 progressRef.current = state.position
                 if (state.duration) setDuration(state.duration)

                 // Sincronizar savedAt local
                 if (state.savedAt) localStorage.setItem(userKey('playerSavedAt'), state.savedAt)

                 // Actualizar MediaSession para que el mini-player / Lock Screen reflejen la canción restaurada
                 updateMediaSession(restoredSong, false)

                 // Restaurar audio source: priorizar caché local (no necesita red ni timeOffset),
                 // si no, usar timeOffset para evitar Range requests que colapsan el transcodificador.
                 const cachedBlobUrl = await queuePrefetcher.getCachedBlobUrl(restoredSong.id)
                 let streamUrl: string
                 let restoreOffset: number

                 if (cachedBlobUrl) {
                   // Blob local: archivo completo en memoria, seek directo sin problemas
                   streamUrl = cachedBlobUrl
                   restoreOffset = 0
                   streamOffsetRef.current = 0
                   console.log(`[PlayerContext] 🚀 Restaurando desde caché local: "${restoredSong.title}"`)
                 } else {
                   restoreOffset = state.position > 2 ? Math.floor(state.position) : 0
                   streamUrl = navidromeApi.getStreamUrl(restoredSong.id, restoredSong.path, restoreOffset > 0 ? restoreOffset : undefined)
                   streamOffsetRef.current = restoreOffset
                 }

                 if (audioRef.current && (!audioRef.current.src || audioRef.current.src === window.location.href)) {
                     audioRef.current.src = streamUrl

                     const onRestoreMetadata = () => {
                       if (audioRef.current) {
                           if (cachedBlobUrl) {
                             // Blob local: seek directo a la posición guardada
                             audioRef.current.currentTime = state.position
                           } else if (restoreOffset > 0) {
                             // Stream recortado con timeOffset: solo ajustar fracción sub-segundo
                             const subSecondRemainder = state.position - restoreOffset
                             audioRef.current.currentTime = subSecondRemainder > 0.5 ? subSecondRemainder : 0
                           } else if (state.position > 0) {
                             // Posición <= 2s: seek estándar (dato cercano al inicio, sin Range issues)
                             audioRef.current.currentTime = state.position
                           }
                           console.log('[PlayerContext] Posición restaurada:', state.position, cachedBlobUrl ? '(caché local)' : `(timeOffset: ${restoreOffset})`)
                       }
                       audioRef.current?.removeEventListener('loadedmetadata', onRestoreMetadata)
                     }
                     audioRef.current.addEventListener('loadedmetadata', onRestoreMetadata)
                 }
            } else if (hasLocalSong && backendIsNewer && !localSongDiffers) {
                // Misma canción pero posición más reciente del backend → actualizar posición
                console.log(`[PlayerContext] Misma canción, actualizando posición desde backend: ${state.position}s`)
                setProgress(state.position)
                progressRef.current = state.position
                if (audioRef.current && !isPlaying) {
                    // Ajustar seek relativo al streamOffset actual para evitar Range requests
                    // en streams transcodificados que ya arrancaron con timeOffset.
                    const streamTime = state.position - streamOffsetRef.current
                    if (streamTime >= 0) {
                      audioRef.current.currentTime = streamTime
                    } else {
                      // La nueva posición está antes del inicio del stream actual:
                      // no hacemos seek (se corregirá al pulsar play, que recarga con timeOffset)
                      console.log('[PlayerContext] Posición backend antes del stream offset, se corregirá al reanudar')
                    }
                }
                if (state.savedAt) localStorage.setItem(userKey('playerSavedAt'), state.savedAt)
            }
        } catch (error) {
            console.error('[PlayerContext] Error restaurando desde backend:', error)
        }
    }

    restoreFromBackend()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []) // Solo al montar

  // --- Memoización de los valores del contexto ---
  const stateValue = useMemo(
    () => ({
      currentSong,
      currentSource,
      isPlaying,
      volume,
      queue: queueState,
      isCrossfading,
      crossfadeDuration,
      analysisCacheRef,
      isAnalyzing,
      analysisProgress,
      smartMixStatus,
      smartMixPlaylistId,
      generatedSmartMix,
      isReconnecting,
    }),
    [
      currentSong,
      currentSource,
      isPlaying,
      volume,
      queueState,
      isCrossfading,
      crossfadeDuration,
      isAnalyzing,
      analysisProgress,
      smartMixStatus,
      smartMixPlaylistId,
      generatedSmartMix,
      isReconnecting,
    ]
  )

  const progressValue = useMemo(
    () => ({
      progress,
      duration,
    }),
    [progress, duration]
  )

  const actionsValue = useMemo(
    () => ({
      setVolume,
      playSong,
      playAlbum,
      playPlaylist,
      playPlaylistFromSong,
      playSongAtPosition,
      removeFromQueue,
      clearQueue,
      reorderQueue,
      addToQueue,
      togglePlayPause,
      seek,
      next,
      previous,
      startPlaylistAnalysis,
      clearMemoryCache,
      generateSmartMix,
      playGeneratedSmartMix,
      clearSmartMix,
      checkCachedSmartMix,
      autoCheckSmartMix,
      registerRemoteHandlers,
      setScrobblingSuppressed: (disabled: boolean) => { scrobblingDisabledRef.current = disabled },
      setScrobbleCallback: (fn: ((data: ScrobbleEventData) => void) | null) => { scrobbleCallbackRef.current = fn },
      setCurrentContextUri: (uri: string | null) => { currentContextUriRef.current = uri },
    }),
    // Añadir todas las dependencias aquí
    [
      setVolume,
      playSong,
      playAlbum,
      playPlaylist,
      playPlaylistFromSong,
      playSongAtPosition,
      removeFromQueue,
      clearQueue,
      reorderQueue,
      addToQueue,
      togglePlayPause,
      seek,
      next,
      previous,
      startPlaylistAnalysis,
      clearMemoryCache,
      generateSmartMix,
      playGeneratedSmartMix,
      clearSmartMix,
      checkCachedSmartMix,
      autoCheckSmartMix,
      registerRemoteHandlers,
    ]
  )

  // --- RETURN del Provider ---
  return (
    <PlayerStateContext.Provider value={stateValue}>
      <PlayerProgressContext.Provider value={progressValue}>
        <PlayerActionsContext.Provider value={actionsValue}>
          {children}
        </PlayerActionsContext.Provider>
      </PlayerProgressContext.Provider>
    </PlayerStateContext.Provider>
  )
}

// --- Hooks personalizados para consumir los contextos ---
// eslint-disable-next-line react-refresh/only-export-components
export function usePlayerState() {
  const context = useContext(PlayerStateContext)
  if (context === undefined) {
    throw new Error('usePlayerState must be used within a PlayerProvider')
  }
  return context
}

// eslint-disable-next-line react-refresh/only-export-components
export function usePlayerProgress() {
  const context = useContext(PlayerProgressContext)
  if (context === undefined) {
    throw new Error('usePlayerProgress must be used within a PlayerProvider')
  }
  return context
}

// eslint-disable-next-line react-refresh/only-export-components
export function usePlayerActions() {
  const context = useContext(PlayerActionsContext)
  if (context === undefined) {
    throw new Error('usePlayerActions must be used within a PlayerProvider')
  }
  return context
}
