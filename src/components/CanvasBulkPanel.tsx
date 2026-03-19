import { useEffect, useState, useRef, useCallback } from 'react'
import {
  PlayIcon,
  PauseIcon,
  StopIcon,
  ArrowDownTrayIcon,
  ArrowPathIcon,
  FilmIcon,
  SparklesIcon,
  MagnifyingGlassIcon,
  CheckIcon,
  XMarkIcon,
} from '@heroicons/react/24/outline'
import { backendApi } from '../services/backendApi'

// Use same URL resolution as backendApi.ts:
// In dev mode Vite proxies /api/* so we use relative paths.
// In production we use the direct backend URL.
const isDev = import.meta.env.DEV
const backendUrl = (import.meta.env.VITE_API_URL || 'http://localhost:3001').replace(/\/$/, '')
const API_BASE = isDev ? '' : backendUrl

type WorkerStatus = 'idle' | 'running' | 'paused' | 'stopping' | 'done' | 'error'

interface WorkerProgress {
  status: WorkerStatus
  navidromeTotal: number
  navidromeOffset: number
  processed: number
  withCanvas: number
  withoutCanvas: number
  errors: number
  skipped: number
  retried: number
  lastSong: string | null
  startedAt: string | null
  estimatedRemainingMin: number | null
  newOnlyMode: boolean
  newSongsFound: number
}

interface DownloadProgress {
  total: number
  done: number
  failed: number
  skipped: number
  lastFile: string | null
  running: boolean
}

interface CanvasStats {
  total: number
  withCanvas: number
  withLocalFile: number
  needingCanvas: number
  needingDownload: number
}

const STATUS_COLORS: Record<WorkerStatus, string> = {
  idle: 'bg-gray-100 text-gray-500 border-gray-200 dark:bg-gray-800 dark:text-gray-400 dark:border-gray-700/50',
  running: 'bg-green-100 text-green-700 border-green-200 dark:bg-green-900/30 dark:text-green-400 dark:border-green-800/50',
  paused: 'bg-amber-100 text-amber-700 border-amber-200 dark:bg-amber-900/30 dark:text-amber-400 dark:border-amber-800/50',
  stopping: 'bg-orange-100 text-orange-700 border-orange-200 dark:bg-orange-900/30 dark:text-orange-400 dark:border-orange-800/50',
  done: 'bg-emerald-100 text-emerald-700 border-emerald-200 dark:bg-emerald-900/30 dark:text-emerald-400 dark:border-emerald-800/50',
  error: 'bg-red-100 text-red-700 border-red-200 dark:bg-red-900/30 dark:text-red-400 dark:border-red-800/50',
}

const STATUS_LABELS: Record<WorkerStatus, string> = {
  idle: 'Inactivo',
  running: 'Buscando',
  paused: 'Pausado',
  stopping: 'Deteniendo',
  done: 'Completado',
  error: 'Fallo',
}

async function apiPost(path: string, body?: object) {
  const res = await fetch(`${API_BASE}/api/canvas${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  return res.json()
}

async function apiGet<T>(path: string): Promise<T> {
  const res = await fetch(`${API_BASE}/api/canvas${path}`)
  return res.json()
}

export default function CanvasBulkPanel() {
  const [workerProgress, setWorkerProgress] = useState<WorkerProgress | null>(null)
  const [downloadProgress, setDownloadProgress] = useState<DownloadProgress | null>(null)
  const [stats, setStats] = useState<CanvasStats | null>(null)
  const [isActioning, setIsActioning] = useState(false)
  const pollingRef = useRef<ReturnType<typeof setInterval> | null>(null)

  const fetchAll = async () => {
    try {
      const [prog, dl, st] = await Promise.all([
        apiGet<WorkerProgress>('/bulk/status').catch(() => null),
        apiGet<DownloadProgress>('/download-local/status').catch(() => null),
        apiGet<CanvasStats>('/stats').catch(() => null),
      ])
      if (prog && !('error' in (prog as object))) setWorkerProgress(prog)
      if (dl) setDownloadProgress(dl)
      if (st) setStats(st)
    } catch {/* silencioso */}
  }

  useEffect(() => {
    fetchAll()
    pollingRef.current = setInterval(fetchAll, 3000)
    return () => {
      if (pollingRef.current) clearInterval(pollingRef.current)
    }
  }, [])

  const action = async (fn: () => Promise<unknown>) => {
    setIsActioning(true)
    try {
      await fn()
      await fetchAll()
    } catch (e) {
      console.error(e)
    } finally {
      setIsActioning(false)
    }
  }

  const status = workerProgress?.status ?? 'idle'
  const isRunning = status === 'running'
  const isPaused = status === 'paused'
  const isIdle = status === 'idle' || status === 'done' || status === 'error'

  const processedPct = workerProgress && workerProgress.navidromeTotal > 0
    ? Math.min(100, Math.round((workerProgress.navidromeOffset / workerProgress.navidromeTotal) * 100))
    : 0

  const canvasPct = stats && stats.total > 0
    ? Math.round((stats.withCanvas / stats.total) * 100)
    : 0

  const localPct = stats && stats.withCanvas > 0
    ? Math.round((stats.withLocalFile / stats.withCanvas) * 100)
    : 0

  const dlPct = downloadProgress && downloadProgress.total > 0
    ? Math.round(((downloadProgress.done + downloadProgress.failed) / downloadProgress.total) * 100)
    : 0

  return (
    <div className="space-y-6 max-w-5xl mx-auto">
      {/* Header */}
      <section>
        <div className="mb-4">
          <h2 className="text-lg font-semibold text-gray-900 dark:text-white flex items-center gap-2">
            <FilmIcon className="w-5 h-5 text-purple-500" />
            Spotify Canvas
          </h2>
          <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">
            Obtén y descarga de manera masiva los videos en bucle (Canvas) de Spotify para toda tu biblioteca. Configura la descarga local para que estén disponibles sin conexión.
          </p>
          {workerProgress?.newOnlyMode && isRunning && (
            <span className="inline-block mt-3 text-xs font-bold uppercase tracking-widest px-3 py-1.5 rounded-full bg-indigo-50 text-indigo-600 dark:bg-indigo-900/40 dark:text-indigo-400 border border-indigo-200 dark:border-indigo-700/40">
              Modo: Sólo Canciones Nuevas
            </span>
          )}
        </div>

        {/* Stats row */}
        {stats && (
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-4">
            <StatCard label="En Biblioteca" value={stats.total} sub="canciones indexadas" color="blue" />
            <StatCard label="Con Canvas" value={stats.withCanvas} sub={`${canvasPct}% del total`} color="green" />
            <StatCard label="Descargados" value={stats.withLocalFile} sub={`${localPct}% disponibles offline`} color="purple" />
          </div>
        )}
      </section>

      {/* Worker card */}
      <section>
        <div className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 p-5 sm:p-8 shadow-sm">
          <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 mb-6">
            <div>
              <h3 className="text-base font-semibold text-gray-900 dark:text-white flex items-center gap-2">
                Búsqueda Masiva
                <span className={`text-[10px] font-black uppercase tracking-widest px-2.5 py-1 rounded-full border ${STATUS_COLORS[status]}`}>
                  {STATUS_LABELS[status]}
                </span>
              </h3>
            </div>
            {workerProgress?.estimatedRemainingMin !== null && isRunning && (
              <span className="text-sm font-medium text-gray-500 bg-gray-100 dark:bg-gray-800 px-3 py-1 rounded-xl">
                ~{workerProgress?.estimatedRemainingMin} min restantes
              </span>
            )}
          </div>

          {/* Progress bar */}
          <div className="mb-6 bg-gray-50 dark:bg-gray-800/40 p-4 rounded-2xl border border-gray-100 dark:border-gray-700/50">
            <div className="flex justify-between text-xs sm:text-sm font-medium text-gray-500 dark:text-gray-400 mb-2">
              <span>
                {workerProgress?.newOnlyMode
                  ? workerProgress.newSongsFound > 0
                    ? `Buscando en ${workerProgress.newSongsFound} nuevas canciones`
                    : 'Escaneando Navidrome...'
                  : 'Canciones procesadas en servidor'
                }
              </span>
              <span className="font-mono text-gray-700 dark:text-gray-300 font-bold">{workerProgress?.navidromeOffset ?? 0} / {workerProgress?.navidromeTotal ?? '?'}</span>
            </div>
            <div className="w-full bg-gray-200 dark:bg-gray-800 h-2.5 rounded-full overflow-hidden shadow-inner">
              <div
                className="h-full bg-purple-500 transition-all duration-500 ease-out"
                style={{ width: `${processedPct}%` }}
              />
            </div>
          </div>

          {/* Stats row */}
          {workerProgress && (workerProgress.processed > 0 || isRunning) && (
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6 font-mono">
              <MiniStat label="Con Canvas" value={workerProgress.withCanvas} color="text-green-600 dark:text-green-400" />
              <MiniStat label="Sin Canvas" value={workerProgress.withoutCanvas} color="text-gray-600 dark:text-gray-400" />
              <MiniStat label="Reintentados" value={workerProgress.retried} color="text-yellow-600 dark:text-yellow-400" />
              <MiniStat label="Errores" value={workerProgress.errors} color="text-red-500 dark:text-red-400" />
            </div>
          )}

          {/* Last song */}
          {workerProgress?.lastSong && (
            <div className="bg-purple-50 dark:bg-purple-900/10 rounded-xl p-3 mb-6">
              <p className="text-[11px] uppercase font-bold text-purple-600 dark:text-purple-400 tracking-wider mb-1">Última procesada</p>
              <p className="text-sm font-medium text-gray-900 dark:text-gray-200 truncate">
                {workerProgress.lastSong}
              </p>
            </div>
          )}

          {/* Controls */}
          <div className="flex flex-col sm:flex-row gap-3 flex-wrap">
            {isIdle && (
              <>
                <ControlButton
                  icon={<PlayIcon className="w-5 h-5" />}
                  label={status === 'done' ? 'Reiniciar Todos' : 'Iniciar Búsqueda'}
                  color="bg-purple-600 hover:bg-purple-700 text-white shadow-md shadow-purple-500/20"
                  disabled={isActioning}
                  onClick={() => action(() => apiPost('/bulk/start', status === 'done' ? { reset: true } : undefined))}
                />
                <ControlButton
                  icon={<SparklesIcon className="w-5 h-5" />}
                  label="Sólo Canciones Nuevas"
                  color="bg-indigo-600 hover:bg-indigo-700 text-white shadow-md shadow-indigo-500/20"
                  disabled={isActioning}
                  onClick={() => action(() => apiPost('/bulk/start-new-only'))}
                />
              </>
            )}
            {isRunning && (
              <ControlButton
                icon={<PauseIcon className="w-5 h-5" />}
                label="Pausar Búsqueda"
                color="bg-amber-500 hover:bg-amber-600 text-white shadow-md shadow-amber-500/20"
                disabled={isActioning}
                onClick={() => action(() => apiPost('/bulk/pause'))}
              />
            )}
            {isPaused && (
              <ControlButton
                icon={<PlayIcon className="w-5 h-5" />}
                label="Reanudar Búsqueda"
                color="bg-green-600 hover:bg-green-700 text-white shadow-md shadow-green-500/20"
                disabled={isActioning}
                onClick={() => action(() => apiPost('/bulk/resume'))}
              />
            )}
            {(isRunning || isPaused) && (
              <ControlButton
                icon={<StopIcon className="w-5 h-5" />}
                label="Detener"
                color="bg-red-500 hover:bg-red-600 text-white shadow-md shadow-red-500/20"
                disabled={isActioning}
                onClick={() => action(() => apiPost('/bulk/stop'))}
              />
            )}
            <div className="w-full sm:w-px sm:h-8 bg-gray-200 dark:bg-gray-700 my-1 sm:my-auto" />
            <ControlButton
              icon={<ArrowPathIcon className="w-5 h-5" />}
              label="Refrescar"
              color="bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700"
              disabled={isActioning}
              onClick={fetchAll}
            />
          </div>

          {status === 'error' && (
            <div className="mt-6 flex items-start gap-3 p-4 bg-red-50 dark:bg-red-900/20 text-red-600 dark:text-red-400 rounded-2xl border border-red-200 dark:border-red-800/50 text-sm">
              <span className="text-xl">⚠️</span>
              <p>Error crítico en el servicio. Revisa los logs. Las variables NAVIDROME_URL, NAVIDROME_USERNAME y NAVIDROME_TOKEN deben estar correctas.</p>
            </div>
          )}
        </div>
      </section>

      {/* Manual canvas by Spotify Track ID */}
      <ManualCanvasPanel onSaved={fetchAll} />

      {/* Local download card */}
      <section>
        <div className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 p-5 sm:p-8 shadow-sm mb-4">
          <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 mb-4">
            <div>
              <h3 className="text-base font-semibold text-gray-900 dark:text-white flex items-center gap-2">
                Descarga Local
                {downloadProgress?.running && (
                  <span className="text-[10px] font-black uppercase tracking-widest px-2.5 py-1 rounded-full border border-green-200 bg-green-50 text-green-600 dark:border-green-800/50 dark:bg-green-900/30 dark:text-green-400 flex items-center gap-1.5">
                    <span className="w-1.5 h-1.5 rounded-full bg-green-500 animate-pulse" />
                    Descargando
                  </span>
                )}
              </h3>
            </div>
            {stats && (
              <span className="text-sm font-medium text-gray-500 bg-gray-100 dark:bg-gray-800 px-3 py-1 rounded-xl whitespace-nowrap">
                {stats.needingDownload} pendientes
              </span>
            )}
          </div>

          <p className="text-sm text-gray-500 dark:text-gray-400 mb-6 leading-relaxed">
            Descarga los archivos multimedia <code className="bg-gray-100 dark:bg-gray-800 px-1.5 py-0.5 rounded text-gray-700 dark:text-gray-300 font-mono text-xs">.mp4</code> desde el CDN a tu servidor local.
          </p>

          {/* Download progress */}
          {downloadProgress && (downloadProgress.running || downloadProgress.done > 0 || downloadProgress.failed > 0) && (
            <div className="mb-6 bg-gray-50 dark:bg-gray-800/40 p-4 rounded-2xl border border-gray-100 dark:border-gray-700/50">
              <div className="flex justify-between text-xs sm:text-sm font-medium text-gray-500 dark:text-gray-400 mb-2">
                <span>Progreso de descarga</span>
                <span className="font-mono text-gray-700 dark:text-gray-300 font-bold">{downloadProgress.done} / {downloadProgress.total}</span>
              </div>
              <div className="w-full bg-gray-200 dark:bg-gray-800 h-2.5 rounded-full overflow-hidden shadow-inner">
                <div
                  className="h-full bg-green-500 transition-all duration-500 ease-out"
                  style={{ width: `${dlPct}%` }}
                />
              </div>
              {downloadProgress.lastFile && (
                <p className="text-[11px] text-gray-500 dark:text-gray-400 truncate mt-3 font-mono bg-white dark:bg-gray-900 p-2 rounded-lg border border-gray-100 dark:border-gray-700/50">
                  <span className="text-green-500 font-bold mr-1">↓</span> {downloadProgress.lastFile}
                </p>
              )}
              {downloadProgress.failed > 0 && (
                <p className="text-xs font-bold text-red-500 mt-2">
                  ⚠️ {downloadProgress.failed} descargas fallidas
                </p>
              )}
            </div>
          )}

          <div className="flex flex-col sm:flex-row justify-start">
             <ControlButton
               icon={<ArrowDownTrayIcon className="w-5 h-5" />}
               label={downloadProgress?.running ? 'Descargando Archivos...' : 'Descargar Archivos Locales'}
               color="bg-green-600 hover:bg-green-700 text-white shadow-md shadow-green-500/20 active:scale-95"
               disabled={isActioning || downloadProgress?.running || stats?.needingDownload === 0}
               onClick={() => action(() => apiPost('/download-local'))}
             />
          </div>
        </div>
      </section>
    </div>
  )
}

// ─── Manual Canvas Panel ──────────────────────────────────────────────────────

interface NavSong { id: string; title: string; artist: string; album: string }

function ManualCanvasPanel({ onSaved }: { onSaved: () => void }) {
  const [query, setQuery]           = useState('')
  const [results, setResults]       = useState<NavSong[]>([])
  const [isSearching, setIsSearching] = useState(false)
  const [selectedSong, setSelectedSong] = useState<NavSong | null>(null)
  const [spotifyTrackId, setSpotifyTrackId] = useState('')
  const [canvasUrl, setCanvasUrl]   = useState<string | null>(null)
  const [isFetching, setIsFetching] = useState(false)
  const [isSaving, setIsSaving]     = useState(false)
  const [saveMsg, setSaveMsg]       = useState<{ ok: boolean; text: string } | null>(null)

  const search = useCallback(async (q: string) => {
    if (!q.trim()) return
    setIsSearching(true)
    setResults([])
    try {
      const songs = await backendApi.searchNavidromeSongs(q.trim())
      setResults(songs)
    } catch { setResults([]) }
    finally { setIsSearching(false) }
  }, [])

  const handleFetchCanvas = async () => {
    const cleanId = spotifyTrackId.trim().replace(/.*track\/([a-zA-Z0-9]+).*/, '$1')
    if (!cleanId) return
    setIsFetching(true)
    setCanvasUrl(null)
    setSaveMsg(null)
    try {
      const data = await backendApi.fetchSpotifyCanvas(cleanId)
      const url = data?.canvasesList?.[0]?.canvasUrl ?? null
      setCanvasUrl(url)
      if (!url) setSaveMsg({ ok: false, text: 'Spotify no devolvió canvas para este track' })
    } catch {
      setSaveMsg({ ok: false, text: 'Error al contactar con Spotify — puede que el token haya caducado' })
    } finally { setIsFetching(false) }
  }

  const handleSave = async () => {
    if (!selectedSong || !canvasUrl) return
    setIsSaving(true)
    setSaveMsg(null)
    const cleanId = spotifyTrackId.trim().replace(/.*track\/([a-zA-Z0-9]+).*/, '$1')
    try {
      await backendApi.saveCanvas({
        songId: selectedSong.id,
        title: selectedSong.title,
        artist: selectedSong.artist,
        album: selectedSong.album,
        spotifyTrackId: cleanId,
        canvasUrl,
      })
      setSaveMsg({ ok: true, text: `Canvas guardado para "${selectedSong.title}"` })
      onSaved()
    } catch {
      setSaveMsg({ ok: false, text: 'Error al guardar el canvas' })
    } finally { setIsSaving(false) }
  }

  const reset = () => {
    setSelectedSong(null)
    setSpotifyTrackId('')
    setCanvasUrl(null)
    setSaveMsg(null)
    setResults([])
    setQuery('')
  }

  return (
    <section>
      <div className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 p-5 sm:p-8 shadow-sm">
        <div className="mb-5">
          <h3 className="text-base font-semibold text-gray-900 dark:text-white flex items-center gap-2 mb-1">
            <MagnifyingGlassIcon className="w-5 h-5 text-purple-500" />
            Canvas Manual por ID de Spotify
          </h3>
          <p className="text-sm text-gray-500 dark:text-gray-400">
            Si la búsqueda masiva no funciona, introduce directamente el ID o enlace del track en Spotify para obtener su Canvas.
          </p>
        </div>

        {/* Step 1 — pick navidrome song */}
        {!selectedSong ? (
          <div className="space-y-3">
            <label className="text-[10px] font-bold text-gray-400 uppercase tracking-wider">1. Buscar canción en tu biblioteca</label>
            <div className="flex gap-2">
              <div className="relative flex-1">
                <MagnifyingGlassIcon className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
                <input
                  type="text"
                  value={query}
                  onChange={e => setQuery(e.target.value)}
                  onKeyDown={e => e.key === 'Enter' && search(query)}
                  placeholder="Título, artista..."
                  className="w-full pl-9 pr-3 py-2.5 bg-gray-50 dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl text-sm text-gray-900 dark:text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-purple-500"
                />
              </div>
              <button
                onClick={() => search(query)}
                disabled={isSearching || !query.trim()}
                className="px-4 py-2.5 bg-purple-600 hover:bg-purple-700 disabled:opacity-50 text-white text-sm font-semibold rounded-xl transition-colors"
              >
                {isSearching ? <ArrowPathIcon className="w-4 h-4 animate-spin" /> : 'Buscar'}
              </button>
            </div>
            {results.length > 0 && (
              <div className="space-y-1 max-h-48 overflow-y-auto pr-1 mt-2">
                {results.map(song => (
                  <button
                    key={song.id}
                    onClick={() => { setSelectedSong(song); setResults([]) }}
                    className="w-full text-left flex items-center gap-3 px-3 py-2.5 rounded-xl hover:bg-purple-50 dark:hover:bg-purple-500/10 border border-transparent hover:border-purple-200 dark:hover:border-purple-500/30 transition-all group"
                  >
                    <FilmIcon className="w-4 h-4 text-gray-400 group-hover:text-purple-500 flex-shrink-0 transition-colors" />
                    <div className="min-w-0 flex-1">
                      <p className="text-sm font-medium text-gray-900 dark:text-white truncate">{song.title}</p>
                      <p className="text-xs text-gray-500 truncate">{song.artist} · {song.album}</p>
                    </div>
                    <CheckIcon className="w-4 h-4 text-purple-400 opacity-0 group-hover:opacity-100 flex-shrink-0" />
                  </button>
                ))}
              </div>
            )}
          </div>
        ) : (
          <div className="space-y-4">
            {/* Selected song chip */}
            <div className="flex items-center gap-3 p-3 bg-purple-50 dark:bg-purple-500/10 rounded-xl border border-purple-200 dark:border-purple-500/30">
              <FilmIcon className="w-5 h-5 text-purple-500 flex-shrink-0" />
              <div className="flex-1 min-w-0">
                <p className="text-sm font-semibold text-gray-900 dark:text-white truncate">{selectedSong.title}</p>
                <p className="text-xs text-gray-500 truncate">{selectedSong.artist} · {selectedSong.album}</p>
              </div>
              <button onClick={reset} className="p-1 text-gray-400 hover:text-gray-600 dark:hover:text-gray-200">
                <XMarkIcon className="w-4 h-4" />
              </button>
            </div>

            {/* Step 2 — Spotify track ID */}
            <div>
              <label className="text-[10px] font-bold text-gray-400 uppercase tracking-wider block mb-2">2. ID o enlace del track en Spotify</label>
              <div className="flex gap-2">
                <input
                  type="text"
                  value={spotifyTrackId}
                  onChange={e => setSpotifyTrackId(e.target.value)}
                  onKeyDown={e => e.key === 'Enter' && handleFetchCanvas()}
                  placeholder="https://open.spotify.com/track/... o ID"
                  className="flex-1 px-3 py-2.5 bg-gray-50 dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl text-sm text-gray-900 dark:text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-purple-500"
                />
                <button
                  onClick={handleFetchCanvas}
                  disabled={isFetching || !spotifyTrackId.trim()}
                  className="px-4 py-2.5 bg-purple-600 hover:bg-purple-700 disabled:opacity-50 text-white text-sm font-semibold rounded-xl transition-colors flex items-center gap-2"
                >
                  {isFetching ? <ArrowPathIcon className="w-4 h-4 animate-spin" /> : <SparklesIcon className="w-4 h-4" />}
                  Obtener
                </button>
              </div>
            </div>

            {/* Canvas preview */}
            {canvasUrl && (
              <div className="space-y-3">
                <label className="text-[10px] font-bold text-gray-400 uppercase tracking-wider block">Vista previa</label>
                <video
                  src={canvasUrl}
                  autoPlay
                  loop
                  muted
                  playsInline
                  className="w-32 h-48 object-cover rounded-xl border border-gray-200 dark:border-gray-700"
                />
                <button
                  onClick={handleSave}
                  disabled={isSaving}
                  className="flex items-center gap-2 px-5 py-2.5 bg-green-600 hover:bg-green-700 disabled:opacity-50 text-white text-sm font-semibold rounded-xl transition-colors"
                >
                  {isSaving ? <ArrowPathIcon className="w-4 h-4 animate-spin" /> : <ArrowDownTrayIcon className="w-4 h-4" />}
                  Guardar Canvas
                </button>
              </div>
            )}

            {saveMsg && (
              <p className={`text-sm font-medium ${saveMsg.ok ? 'text-green-600 dark:text-green-400' : 'text-red-500 dark:text-red-400'}`}>
                {saveMsg.ok ? '✓ ' : '⚠ '}{saveMsg.text}
              </p>
            )}
          </div>
        )}
      </div>
    </section>
  )
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function StatCard({ label, value, sub }: {
  label: string; value: number; sub: string; color?: 'blue' | 'green' | 'purple'
}) {
  return (
    <div className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 shadow-sm p-5">
      <p className="text-[10px] font-bold text-gray-400 uppercase tracking-widest mb-2">{label}</p>
      <p className="text-2xl font-black text-gray-900 dark:text-white mb-1">{value.toLocaleString()}</p>
      <p className="text-xs text-gray-500 truncate">{sub}</p>
    </div>
  )
}

function MiniStat({ label, value, color }: { label: string; value: number; color: string }) {
  return (
    <div className="bg-white dark:bg-gray-900 rounded-xl p-3 border border-gray-200 dark:border-gray-800 shadow-sm flex flex-col items-center justify-center text-center cursor-default mt-1">
      <p className={`text-xl sm:text-2xl font-black ${color} leading-none mb-1`}>{value}</p>
      <p className="text-[10px] sm:text-xs text-gray-500 dark:text-gray-400 font-bold uppercase tracking-wider">{label}</p>
    </div>
  )
}

function ControlButton({ icon, label, color, disabled, onClick }: {
  icon: React.ReactNode
  label: string
  color: string
  disabled?: boolean
  onClick: () => void
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className={`flex items-center justify-center gap-2 px-5 py-2.5 rounded-xl text-sm font-semibold transition-all sm:flex-none flex-1 disabled:opacity-50 disabled:cursor-not-allowed ${color}`}
    >
      {icon}
      {label}
    </button>
  )
}
