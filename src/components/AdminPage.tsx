import { useCallback, useEffect, useRef, useState } from 'react'
import CanvasBulkPanel from './CanvasBulkPanel'
import AdminEditorialPanel from './AdminEditorialPanel'
import { createPortal } from 'react-dom'
import { useNavigate, useParams } from 'react-router-dom'
import { navidromeApi } from '../services/navidromeApi'
import { backendApi, SyncedPlaylist, SyncPreviewResult, CronStatus, SmartPlaylist } from '../services/backendApi'
import { useConnect } from '../hooks/useConnect'
import {
  ServerIcon,
  UsersIcon,
  MusicalNoteIcon,
  CircleStackIcon,
  ArrowPathIcon,
  XMarkIcon,
  MagnifyingGlassIcon,
  CheckIcon,
  SparklesIcon,
  QueueListIcon,
  ClockIcon,
  SignalIcon,
  ExclamationTriangleIcon,
  ComputerDesktopIcon,
  DevicePhoneMobileIcon,
  TvIcon,
} from '@heroicons/react/24/outline'
import { CheckCircleIcon, XCircleIcon } from '@heroicons/react/24/solid'
import Spinner from './Spinner'
import UniversalCover from './UniversalCover'
import { getColorForUsername, getInitial } from '../utils/userUtils'

/** Extrae el ID puro de Spotify de una URL o devuelve el string tal cual */
function extractSpotifyId(input: string): string {
  const match = input.match(/playlist\/([a-zA-Z0-9]+)/)
  return match ? match[1] : input.trim()
}

// ─── Types ───────────────────────────────────────────────────────────────────

interface NavidromeSong {
  id: string
  title: string
  artist: string
  album: string
}

// Key = spotify track ID (persisted), value = selected navidrome song
type ManualOverrides = Record<string, NavidromeSong & { spotifyTrackName?: string; spotifyArtist?: string }>

// ─── Song search sub-component ───────────────────────────────────────────────

function SongSearchPanel({
  spotifyTrackName,
  spotifyArtist,
  onSelect,
  onClose,
}: {
  spotifyTrackName: string
  spotifyArtist: string
  onSelect: (song: NavidromeSong) => void
  onClose: () => void
}) {
  const [query, setQuery] = useState(`${spotifyTrackName} ${spotifyArtist}`)
  const [results, setResults] = useState<NavidromeSong[]>([])
  const [isSearching, setIsSearching] = useState(false)
  const [hasSearched, setHasSearched] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)

  const doSearch = useCallback(async (q: string) => {
    if (!q.trim()) return
    setIsSearching(true)
    setHasSearched(false)
    try {
      const songs = await backendApi.searchNavidromeSongs(q.trim())
      setResults(songs)
    } catch {
      setResults([])
    } finally {
      setIsSearching(false)
      setHasSearched(true)
    }
  }, [])

  // Auto-search with default query on mount
  useEffect(() => {
    doSearch(query)
    inputRef.current?.focus()
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') doSearch(query)
    if (e.key === 'Escape') onClose()
  }

  return (
    <div className="mt-2 p-3 bg-gray-900/60 rounded-xl border border-gray-700/60 backdrop-blur-sm">
      {/* Search bar */}
      <div className="flex gap-2 mb-3">
        <div className="relative flex-1">
          <MagnifyingGlassIcon className="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-gray-400" />
          <input
            ref={inputRef}
            type="text"
            value={query}
            onChange={e => setQuery(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Buscar en la DB..."
            className="w-full pl-8 pr-3 py-1.5 bg-gray-800 border border-gray-600 rounded-lg text-xs text-white placeholder-gray-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
          />
        </div>
        <button
          onClick={() => doSearch(query)}
          disabled={isSearching}
          className="px-3 py-1.5 bg-indigo-600 hover:bg-indigo-700 disabled:opacity-50 text-white text-xs rounded-lg transition-colors flex items-center gap-1"
        >
          {isSearching ? <Spinner size="sm" /> : 'Buscar'}
        </button>
        <button
          onClick={onClose}
          className="p-1.5 text-gray-400 hover:text-white hover:bg-gray-700 rounded-lg transition-colors"
        >
          <XMarkIcon className="w-4 h-4" />
        </button>
      </div>

      {/* Results */}
      {isSearching && (
        <div className="flex justify-center py-4">
          <Spinner size="sm" />
        </div>
      )}
      {!isSearching && hasSearched && results.length === 0 && (
        <p className="text-xs text-gray-500 text-center py-3">Sin resultados para esta búsqueda</p>
      )}
      {!isSearching && results.length > 0 && (
        <div className="space-y-1 max-h-48 overflow-y-auto pr-1">
          {results.map(song => (
            <button
              key={song.id}
              onClick={() => onSelect(song)}
              className="w-full text-left flex items-center gap-3 px-2.5 py-2 rounded-lg hover:bg-indigo-600/20 border border-transparent hover:border-indigo-500/40 transition-all group"
            >
              <MusicalNoteIcon className="w-3.5 h-3.5 text-gray-500 group-hover:text-indigo-400 flex-shrink-0 transition-colors" />
              <div className="min-w-0 flex-1">
                <p className="text-xs font-medium text-white truncate">{song.title}</p>
                <p className="text-[10px] text-gray-400 truncate">{song.artist} · {song.album}</p>
              </div>
              <CheckIcon className="w-3.5 h-3.5 text-indigo-400 opacity-0 group-hover:opacity-100 flex-shrink-0 transition-opacity" />
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

// ─── Not Found Track Row ─────────────────────────────────────────────────────

function NotFoundTrackRow({
  track,
  override,
  onOverride,
}: {
  track: SyncPreviewResult['tracks'][0]
  override?: NavidromeSong
  onOverride: (song: NavidromeSong) => void
}) {
  const [showSearch, setShowSearch] = useState(false)

  return (
    <div className={`rounded-xl border transition-all ${
      override
        ? 'border-emerald-500/30 bg-emerald-500/5'
        : 'border-gray-700/40 bg-gray-800/20'
    }`}>
      <div className="flex items-center gap-3 px-3 py-2.5">
        {override ? (
          <CheckCircleIcon className="w-4 h-4 text-emerald-400 flex-shrink-0" />
        ) : (
          <XCircleIcon className="w-4 h-4 text-red-400/70 flex-shrink-0" />
        )}

        <div className="min-w-0 flex-1">
          <p className={`text-sm font-medium truncate ${override ? 'text-emerald-300' : 'text-gray-300 line-through decoration-red-400/50'}`}>
            {track.spotify.name}
          </p>
          <p className="text-xs text-gray-500 truncate">{track.spotify.artist}</p>
          {override && (
            <p className="text-[10px] text-emerald-400/80 truncate mt-0.5">
              ✓ Asignado: {override.title} — {override.artist}
            </p>
          )}
        </div>

        <button
          onClick={() => setShowSearch(s => !s)}
          title={override ? 'Cambiar asignación manual' : 'Asignar manualmente'}
          className={`flex-shrink-0 flex items-center gap-1 px-2.5 py-1 rounded-lg text-[10px] font-semibold transition-all ${
            showSearch
              ? 'bg-indigo-600 text-white'
              : override
              ? 'bg-emerald-600/20 text-emerald-300 hover:bg-emerald-600/40 border border-emerald-500/30'
              : 'bg-gray-700 text-gray-300 hover:bg-indigo-600/30 hover:text-indigo-300 border border-gray-600'
          }`}
        >
          {override ? (
            <><SparklesIcon className="w-3 h-3" /> Cambiar</>
          ) : (
            <><MagnifyingGlassIcon className="w-3 h-3" /> Asignar</>
          )}
        </button>
      </div>

      {showSearch && (
        <div className="px-3 pb-3">
          <SongSearchPanel
            spotifyTrackName={track.spotify.name}
            spotifyArtist={track.spotify.artist}
            onSelect={song => {
              onOverride(song)
              setShowSearch(false)
            }}
            onClose={() => setShowSearch(false)}
          />
        </div>
      )}
    </div>
  )
}

// ─── Matched Tracks Modal ─────────────────────────────────────────────────────

function MatchedTracksModal({
  sync,
  onClose,
  onResync,
}: {
  sync: SyncedPlaylist
  onClose: () => void
  onResync?: () => void
}) {
  const [preview, setPreview] = useState<SyncPreviewResult | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [overrides, setOverrides] = useState<ManualOverrides>({})
  const [isSaving, setIsSaving] = useState(false)

  useEffect(() => {
    setLoading(true)
    setError(null)
    backendApi
      .getSyncPreview(sync.spotifyId)
      .then(data => setPreview(data))
      .catch(err => setError(err instanceof Error ? err.message : 'Error al cargar'))
      .finally(() => setLoading(false))
  }, [sync.spotifyId])

  // Close on Escape
  useEffect(() => {
    const handler = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    document.addEventListener('keydown', handler)
    return () => document.removeEventListener('keydown', handler)
  }, [onClose])

  const found = preview?.tracks.filter(t => t.found) ?? []
  const notFound = preview?.tracks.filter(t => !t.found) ?? []
  const pendingOverrides = Object.keys(overrides).length

  const handleSaveAndSync = async () => {
    setIsSaving(true)
    try {
      // 1. Persistir todos los matches manuales en el backend
      const overrideEntries = Object.entries(overrides)
      if (overrideEntries.length > 0) {
        await Promise.all(
          overrideEntries.map(([spotifyTrackId, song]) =>
            backendApi.saveManualMatch({
              spotifyTrackId,
              navidromeSongId: song.id,
              spotifyTrackName: song.spotifyTrackName,
              spotifyArtist: song.spotifyArtist,
              navidromeTitle: song.title,
              navidromeArtist: song.artist,
            })
          )
        )
      }
      // 2. Re-sincronizar (ahora el sync leerá los matches persistidos)
      await backendApi.triggerSync(sync.spotifyId)
      onResync?.()
      onClose()
    } catch (err) {
      alert('Error al guardar y re-sincronizar: ' + (err instanceof Error ? err.message : String(err)))
    } finally {
      setIsSaving(false)
    }
  }

  const modal = (
    <div
      className="fixed inset-0 z-[9999] flex items-center justify-center p-4"
      style={{ backgroundColor: 'rgba(0,0,0,0.7)', backdropFilter: 'blur(8px)' }}
      onClick={e => e.target === e.currentTarget && onClose()}
    >
      <div
        className="bg-gray-900 rounded-2xl shadow-2xl flex flex-col border border-gray-700/60"
        style={{ width: '100%', maxWidth: '900px', maxHeight: '90vh' }}
        onClick={e => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-start justify-between p-5 border-b border-gray-800 flex-shrink-0">
          <div>
            <h2 className="text-lg font-bold text-white">{sync.name}</h2>
            <p className="text-sm text-gray-400 mt-0.5">
              {sync.matchCount} de {sync.trackCount} canciones encontradas
            </p>
          </div>
          <button
            onClick={onClose}
            className="p-2 rounded-xl hover:bg-gray-800 text-gray-400 hover:text-white transition-colors"
          >
            <XMarkIcon className="w-5 h-5" />
          </button>
        </div>

        {/* Progress bar */}
        <div className="px-5 pt-4 flex-shrink-0">
          <div className="flex items-center justify-between text-xs text-gray-500 mb-1.5">
            <span>Coincidencia automática</span>
            <span className="font-bold text-emerald-400">
              {preview ? Math.round(preview.percentage) : Math.round((sync.matchCount / sync.trackCount) * 100)}%
            </span>
          </div>
          <div className="w-full bg-gray-800 h-2 rounded-full overflow-hidden">
            <div
              className="bg-emerald-500 h-full transition-all duration-700"
              style={{ width: `${preview ? preview.percentage : (sync.matchCount / sync.trackCount) * 100}%` }}
            />
          </div>
          {pendingOverrides > 0 && (
            <p className="text-xs text-indigo-400 mt-1.5">
              ✦ {pendingOverrides} asignación{pendingOverrides > 1 ? 'es' : ''} manual{pendingOverrides > 1 ? 'es' : ''} pendiente{pendingOverrides > 1 ? 's' : ''}
            </p>
          )}
        </div>

        {/* Body */}
        <div className="flex-1 overflow-y-auto p-5 min-h-0">
          {loading && (
            <div className="flex justify-center py-16">
              <Spinner size="lg" />
            </div>
          )}
          {error && <div className="text-center py-8 text-red-400">{error}</div>}

          {preview && !loading && (
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
              {/* Found column */}
              <div>
                <div className="flex items-center gap-2 mb-3">
                  <CheckCircleIcon className="w-4 h-4 text-emerald-400" />
                  <p className="text-xs font-bold text-gray-400 uppercase tracking-wider">
                    Encontradas ({found.length})
                  </p>
                </div>
                <div className="space-y-1">
                  {found.map((t, i) => (
                    <div
                      key={i}
                      className="flex items-center gap-3 px-3 py-2 rounded-xl hover:bg-gray-800/50 transition-colors"
                    >
                      <div className="w-1.5 h-1.5 rounded-full bg-emerald-500 flex-shrink-0" />
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-2">
                          <p className="text-sm font-medium text-white truncate">{t.spotify.name}</p>
                          {t.isManual && (
                            <span className="px-1.5 py-0.5 rounded-md bg-indigo-500/20 text-indigo-400 text-[9px] font-bold uppercase tracking-wider border border-indigo-500/30">
                              Manual
                            </span>
                          )}
                        </div>
                        <p className="text-xs text-gray-500 truncate">{t.spotify.artist}</p>
                      </div>
                    </div>
                  ))}
                </div>
              </div>

              {/* Not Found column */}
              {notFound.length > 0 && (
                <div>
                  <div className="flex items-center gap-2 mb-3">
                    <XCircleIcon className="w-4 h-4 text-red-400" />
                    <p className="text-xs font-bold text-gray-400 uppercase tracking-wider">
                      No encontradas ({notFound.length}) — asigna manualmente
                    </p>
                  </div>
                  <div className="space-y-2">
                    {notFound.map((t, i) => (
                      <NotFoundTrackRow
                        key={i}
                        track={t}
                        override={overrides[t.spotify.id]}
                        onOverride={song =>
                          setOverrides(prev => ({
                            ...prev,
                            [t.spotify.id]: {
                              ...song,
                              spotifyTrackName: t.spotify.name,
                              spotifyArtist: t.spotify.artist,
                            },
                          }))
                        }
                      />
                    ))}
                  </div>
                </div>
              )}
            </div>
          )}
        </div>

        {/* Footer */}
        {preview && !loading && pendingOverrides > 0 && (
          <div className="flex items-center justify-end gap-3 px-5 py-4 border-t border-gray-800 flex-shrink-0">
            <p className="text-xs text-gray-500 flex-1">
              {pendingOverrides} canción{pendingOverrides > 1 ? 'es' : ''} asignada{pendingOverrides > 1 ? 's' : ''} manualmente. Re-sincroniza para aplicar los cambios.
            </p>
            <button
              onClick={onClose}
              className="px-4 py-2 text-sm text-gray-400 hover:text-white transition-colors"
            >
              Cancelar
            </button>
            <button
              onClick={handleSaveAndSync}
              disabled={isSaving}
              className="px-5 py-2 bg-indigo-600 hover:bg-indigo-700 disabled:opacity-50 text-white text-sm font-semibold rounded-xl transition-colors flex items-center gap-2"
            >
              {isSaving ? <Spinner size="sm" /> : <ArrowPathIcon className="w-4 h-4" />}
              Re-sincronizar
            </button>
          </div>
        )}
      </div>
    </div>
  )

  // Use a portal so the modal renders at document body level,
  // escaping any overflow:hidden or transform contexts from Framer Motion.
  return createPortal(modal, document.body)
}

// ─── Connect Hub Widget ───────────────────────────────────────────────────────

function ConnectHubWidget() {
  const {
    isConnected, isConnecting, lastError, devices, lanDevices,
    currentDeviceId, activeDeviceId, transferPlayback, reconnect,
  } = useConnect()
  const [isReconnecting, setIsReconnecting] = useState(false)

  const handleReconnect = () => {
    setIsReconnecting(true)
    reconnect()
    setTimeout(() => setIsReconnecting(false), 3000)
  }

  const handleForceRelogin = () => {
    const username = navidromeApi.getConfig()?.username
    localStorage.removeItem(username ? `audiorr_session_token_${username}` : 'audiorr_session_token')
    window.location.reload()
  }

  const formatLastSeen = (lastSeen?: number) => {
    if (!lastSeen) return ''
    const diff = Date.now() - lastSeen
    if (diff < 30000) return 'Ahora'
    if (diff < 3600000) return `hace ${Math.round(diff / 60000)}m`
    return `hace ${Math.round(diff / 3600000)}h`
  }

  const getDeviceIcon = (device: { name: string; type: string }) => {
    const name = device.name.toLowerCase()
    if (device.type === 'lan_device') return <TvIcon className="w-4 h-4 text-indigo-400" />
    if (name.includes('mobile') || name.includes('iphone') || name.includes('android'))
      return <DevicePhoneMobileIcon className="w-4 h-4 text-gray-400" />
    return <ComputerDesktopIcon className="w-4 h-4 text-gray-400" />
  }

  const getTypeLabel = (type: string) => {
    const map: Record<string, string> = {
      receiver: 'Receiver', controller: 'Controlador',
      hybrid: 'Híbrido', lan_device: 'LAN', casting: 'Cast',
    }
    return map[type] ?? type
  }

  const socketStatus = isConnected ? 'connected' : isConnecting ? 'connecting' : 'disconnected'
  const otherDevices = devices.filter(d => d.id !== currentDeviceId)

  return (
    <div className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 shadow-sm overflow-hidden">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 px-4 py-4 sm:px-6 sm:py-4 border-b border-gray-100 dark:border-gray-800">
        <div className="flex items-center gap-3">
          <span className="relative flex h-2 w-2">
            {socketStatus === 'connecting' && (
              <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-amber-400 opacity-75" />
            )}
            <span className={`relative inline-flex rounded-full h-2 w-2 ${
              socketStatus === 'connected' ? 'bg-emerald-500' :
              socketStatus === 'connecting' ? 'bg-amber-500' : 'bg-red-500'
            }`} />
          </span>
          <p className="font-semibold text-sm text-gray-900 dark:text-white">Audiorr Connect</p>
          <span className={`text-[11px] font-semibold px-2 py-0.5 rounded-full ${
            socketStatus === 'connected'
              ? 'bg-emerald-100 text-emerald-700 dark:bg-emerald-500/15 dark:text-emerald-400'
              : socketStatus === 'connecting'
              ? 'bg-amber-100 text-amber-700 dark:bg-amber-500/15 dark:text-amber-400'
              : 'bg-red-100 text-red-700 dark:bg-red-500/15 dark:text-red-400'
          }`}>
            {socketStatus === 'connected' ? 'Conectado' : socketStatus === 'connecting' ? 'Conectando...' : 'Sin conexión'}
          </span>
        </div>
        <div className="flex items-center gap-2">
          <button
            onClick={handleReconnect}
            disabled={isReconnecting || isConnecting}
            className="flex items-center gap-1.5 px-3 py-1.5 text-xs font-semibold bg-indigo-600 hover:bg-indigo-500 disabled:opacity-50 disabled:cursor-not-allowed text-white rounded-xl transition-all active:scale-95"
          >
            {isReconnecting || isConnecting ? <Spinner size="sm" /> : <ArrowPathIcon className="w-3.5 h-3.5" />}
            Reconectar
          </button>
          <button
            onClick={handleForceRelogin}
            className="flex items-center gap-1.5 px-3 py-1.5 text-xs font-semibold bg-red-50 dark:bg-red-500/10 hover:bg-red-100 dark:hover:bg-red-500/20 text-red-600 dark:text-red-400 rounded-xl transition-all"
          >
            <XMarkIcon className="w-3.5 h-3.5" />
            Re-login
          </button>
        </div>
      </div>

      {/* Error */}
      {lastError && (
        <div className="mx-6 mt-4 flex items-center gap-2 p-3 bg-red-50 dark:bg-red-500/10 rounded-xl border border-red-200 dark:border-red-500/20">
          <ExclamationTriangleIcon className="w-4 h-4 text-red-500 flex-shrink-0" />
          <p className="text-xs text-red-600 dark:text-red-400 font-medium">{lastError}</p>
        </div>
      )}

      {/* Device map */}
      <div className="p-6">
        <p className="text-[10px] font-bold text-gray-400 uppercase tracking-wider mb-3">
          Dispositivos ({devices.length + lanDevices.length})
        </p>
        {!isConnected && devices.length === 0 ? (
          <p className="text-sm text-gray-400 py-2">Sin conexión al hub.</p>
        ) : (
          <div className="space-y-2">
            {/* This device */}
            <div className="flex items-center gap-3 px-4 py-3 bg-indigo-50 dark:bg-indigo-500/10 rounded-xl border border-indigo-100 dark:border-indigo-500/20">
              <ComputerDesktopIcon className="w-4 h-4 text-indigo-500 flex-shrink-0" />
              <div className="flex-1 min-w-0">
                <p className="text-sm font-semibold text-indigo-700 dark:text-indigo-300 truncate">Este equipo</p>
                <p className="text-[10px] text-indigo-500/70">Admin · En uso ahora</p>
              </div>
              <span className="text-[10px] font-bold text-indigo-600 dark:text-indigo-400 bg-indigo-100 dark:bg-indigo-500/20 px-2 py-0.5 rounded-full shrink-0">
                Activo
              </span>
            </div>

            {/* Other Audiorr Connect devices */}
            {otherDevices.map(device => {
              const isActive = activeDeviceId === device.id
              return (
                <div
                  key={device.id}
                  className="flex items-center gap-3 px-4 py-3 bg-gray-50 dark:bg-gray-800/60 rounded-xl border border-gray-200 dark:border-gray-700/50 hover:border-gray-300 dark:hover:border-gray-600 transition-colors"
                >
                  <div className="flex-shrink-0">{getDeviceIcon(device)}</div>
                  <div className="flex-1 min-w-0">
                    <p className="text-sm font-medium text-gray-900 dark:text-white truncate">{device.name}</p>
                    <p className="text-[10px] text-gray-400">{getTypeLabel(device.type)} · {formatLastSeen(device.lastSeen)}</p>
                  </div>
                  {isActive && (
                    <span className="text-[10px] font-bold text-emerald-600 dark:text-emerald-400 bg-emerald-50 dark:bg-emerald-500/10 px-2 py-0.5 rounded-full border border-emerald-200 dark:border-emerald-500/20 shrink-0">
                      Controlando
                    </span>
                  )}
                  <button
                    onClick={() => transferPlayback(device.id)}
                    className="shrink-0 text-[11px] font-semibold px-3 py-1.5 bg-gray-100 dark:bg-gray-700 hover:bg-indigo-50 dark:hover:bg-indigo-500/10 hover:text-indigo-600 dark:hover:text-indigo-400 text-gray-600 dark:text-gray-300 rounded-xl transition-all"
                  >
                    Controlar
                  </button>
                </div>
              )
            })}

            {/* LAN devices */}
            {lanDevices.length > 0 && (
              <>
                <p className="text-[10px] font-bold text-gray-400 uppercase tracking-wider mt-5 mb-2">Red local (Cast)</p>
                {lanDevices.map(device => (
                  <div key={device.id} className="flex items-center gap-3 px-4 py-3 bg-gray-50 dark:bg-gray-800/60 rounded-xl border border-gray-200 dark:border-gray-700/50">
                    <TvIcon className="w-4 h-4 text-indigo-400 flex-shrink-0" />
                    <div className="flex-1 min-w-0">
                      <p className="text-sm font-medium text-indigo-600 dark:text-indigo-400 truncate">{device.name}</p>
                      <p className="text-[10px] text-gray-400 font-mono">{device.lanType} · {device.ip}</p>
                    </div>
                  </div>
                ))}
              </>
            )}

            {otherDevices.length === 0 && lanDevices.length === 0 && (
              <p className="text-xs text-gray-400 py-2">Solo este dispositivo está conectado. Abre Audiorr en otro equipo para verlo aquí.</p>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

// ─── Server Stats interface ───────────────────────────────────────────────────

interface ServerStats {
  serverUrl: string
  username: string
  version: string | null
}

// ─── UsersTab ────────────────────────────────────────────────────────────────

interface AdminUser {
  username: string
  avatarUrl: string | null
  createdAt: string
  updatedAt: string
  lastScrobble: { title: string; artist: string; album: string; playedAt: string } | null
}

function UsersTab() {
  const [users, setUsers] = useState<AdminUser[]>([])
  const [loading, setLoading] = useState(true)
  const { subscribeToEvent } = useConnect()

  useEffect(() => {
    backendApi.getAdminUsers()
      .then(setUsers)
      .catch(err => console.error('[UsersTab] Error fetching users:', err))
      .finally(() => setLoading(false))
  }, [])

  useEffect(() => {
    return subscribeToEvent('admin_scrobble', (data) => {
      const payload = data as { username: string; title: string; artist: string; album: string; playedAt: string }
      setUsers(prev => prev.map(u =>
        u.username === payload.username
          ? { ...u, lastScrobble: { title: payload.title, artist: payload.artist, album: payload.album, playedAt: payload.playedAt } }
          : u
      ))
    })
  }, [subscribeToEvent])

  if (loading) {
    return (
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        {[1, 2].map(i => (
          <div key={i} className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 h-36 animate-pulse" />
        ))}
      </div>
    )
  }

  if (users.length === 0) {
    return (
      <div className="text-center py-20 text-gray-500">
        <UsersIcon className="w-10 h-10 mx-auto mb-3 opacity-30" />
        <p className="font-semibold">No hay usuarios registrados aún.</p>
      </div>
    )
  }

  return (
    <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
      {users.map(user => (
        <div key={user.username} className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 shadow-sm p-4 sm:p-5">
          <div className="flex items-center gap-3 mb-4">
            <div className="w-10 h-10">
              <UniversalCover
                type="user"
                initial={getInitial(user.username)}
                backgroundColor={getColorForUsername(user.username)}
                context="grid"
              />
            </div>
            <div className="min-w-0">
              <p className="font-semibold text-gray-900 dark:text-white truncate">{user.username}</p>
              <p className="text-xs text-gray-400">Desde {new Date(user.createdAt).toLocaleDateString(undefined, { month: 'short', year: 'numeric' })}</p>
            </div>
          </div>

          <div className="space-y-3">
            <div>
              <p className="text-[10px] font-bold text-gray-400 uppercase tracking-wider mb-1">Último scrobble</p>
              {user.lastScrobble ? (
                <>
                  <p className="text-sm font-semibold text-gray-900 dark:text-white truncate">{user.lastScrobble.title}</p>
                  <p className="text-xs text-gray-500 truncate">{user.lastScrobble.artist}</p>
                  <p className="text-[11px] text-gray-400 mt-0.5">
                    {new Date(user.lastScrobble.playedAt).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })}
                  </p>
                </>
              ) : (
                <p className="text-xs text-gray-400">Sin scrobbles</p>
              )}
            </div>

            <div>
              <p className="text-[10px] font-bold text-gray-400 uppercase tracking-wider mb-1">Último login</p>
              <p className="text-sm font-semibold text-gray-900 dark:text-white">
                {new Date(user.updatedAt).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })}
              </p>
            </div>
          </div>
        </div>
      ))}
    </div>
  )
}

// ─── This Is Panel ───────────────────────────────────────────────────────────

function ThisIsPanel() {
  const [mapping, setMapping]     = useState<Record<string, string>>({})
  const [playlists, setPlaylists] = useState<{ id: string; name: string }[]>([])
  const [loading, setLoading]     = useState(true)
  const [saving, setSaving]       = useState(false)
  const [search, setSearch]       = useState('')
  const [selectedId, setSelectedId]     = useState('')
  const [artistName, setArtistName]     = useState('')
  const [dropdownOpen, setDropdownOpen] = useState(false)
  const [saveMsg, setSaveMsg]     = useState<{ ok: boolean; text: string } | null>(null)

  useEffect(() => {
    const load = async () => {
      setLoading(true)
      try {
        const [all, saved] = await Promise.all([
          navidromeApi.getPlaylists(),
          backendApi.getGlobalSetting<Record<string, string>>('this_is_playlists'),
        ])
        setPlaylists(all.map(p => ({ id: p.id, name: p.name })))
        setMapping(saved ?? {})
      } catch (e) {
        console.error('[ThisIsPanel]', e)
      } finally {
        setLoading(false)
      }
    }
    load()
  }, [])

  const filtered = playlists.filter(p =>
    p.name.toLowerCase().includes(search.toLowerCase())
  ).slice(0, 20)

  const selectedPlaylist = playlists.find(p => p.id === selectedId)

  const handleAdd = async () => {
    if (!selectedId) return
    setSaving(true)
    setSaveMsg(null)
    try {
      // Si el artista está vacío, guardamos string vacío — el backend lo extrae del nombre de la playlist
      const next = { ...mapping, [selectedId]: artistName.trim() }
      await backendApi.setGlobalSetting('this_is_playlists', next)
      setMapping(next)
      setSelectedId('')
      setArtistName('')
      setSearch('')
      setSaveMsg({ ok: true, text: 'Guardado correctamente' })
    } catch {
      setSaveMsg({ ok: false, text: 'Error al guardar' })
    } finally {
      setSaving(false)
      setTimeout(() => setSaveMsg(null), 3000)
    }
  }

  const handleRemove = async (playlistId: string) => {
    const next = { ...mapping }
    delete next[playlistId]
    try {
      await backendApi.setGlobalSetting('this_is_playlists', next)
      setMapping(next)
    } catch {
      alert('Error al eliminar')
    }
  }

  if (loading) {
    return <div className="h-24 rounded-2xl bg-gray-100 dark:bg-gray-800 animate-pulse" />
  }

  const entries = Object.entries(mapping)

  return (
    <div className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 p-5 shadow-sm space-y-5">
      {/* Existing entries */}
      {entries.length > 0 && (
        <div className="space-y-2">
          {entries.map(([pid, artist]) => {
            const pl = playlists.find(p => p.id === pid)
            return (
              <div key={pid} className="flex items-center justify-between gap-3 px-3 py-2.5 rounded-xl bg-gray-50 dark:bg-gray-800/60 border border-gray-100 dark:border-gray-700/50">
                <div className="min-w-0">
                  <p className="text-sm font-semibold text-gray-900 dark:text-white truncate">{pl?.name ?? pid}</p>
                  <p className="text-xs text-indigo-500 dark:text-indigo-400 truncate">This Is {artist}</p>
                </div>
                <button
                  onClick={() => handleRemove(pid)}
                  className="flex-shrink-0 p-1.5 text-gray-400 hover:text-red-500 hover:bg-red-50 dark:hover:bg-red-500/10 rounded-lg transition-colors"
                >
                  <XMarkIcon className="w-4 h-4" />
                </button>
              </div>
            )
          })}
        </div>
      )}

      {entries.length === 0 && (
        <p className="text-sm text-gray-400 text-center py-2">Sin playlists configuradas aún</p>
      )}

      {/* Add new */}
      <div className="border-t border-gray-100 dark:border-gray-800 pt-4 space-y-3">
        <p className="text-[10px] font-bold text-gray-400 uppercase tracking-wider">Añadir nueva</p>

        {/* Playlist picker */}
        <div className="relative">
          <div
            onClick={() => setDropdownOpen(o => !o)}
            className="w-full flex items-center justify-between gap-2 px-3 py-2.5 bg-gray-50 dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl cursor-pointer text-sm text-gray-900 dark:text-white"
          >
            <span className="truncate">{selectedPlaylist?.name ?? 'Seleccionar playlist…'}</span>
            <svg className="w-4 h-4 text-gray-400 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
            </svg>
          </div>

          {dropdownOpen && (
            <div className="absolute z-20 top-full mt-1 w-full bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl shadow-lg overflow-hidden">
              <div className="p-2 border-b border-gray-100 dark:border-gray-700">
                <div className="relative">
                  <MagnifyingGlassIcon className="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-gray-400" />
                  <input
                    type="text"
                    value={search}
                    onChange={e => setSearch(e.target.value)}
                    placeholder="Buscar playlist…"
                    className="w-full pl-8 pr-3 py-1.5 bg-gray-100 dark:bg-gray-700 rounded-lg text-xs text-gray-900 dark:text-white placeholder-gray-400 focus:outline-none"
                    autoFocus
                  />
                </div>
              </div>
              <div className="max-h-48 overflow-y-auto">
                {filtered.map(p => (
                  <button
                    key={p.id}
                    onClick={() => {
                      setSelectedId(p.id)
                      setDropdownOpen(false)
                      setSearch('')
                      // Auto-extraer artista si el nombre sigue el patrón "This is X"
                      const match = p.name.replace(/^\[spotify\]\s*/i, '').match(/^this is (.+)$/i)
                      if (match) setArtistName(match[1].trim())
                    }}
                    className="w-full text-left px-3 py-2 text-sm text-gray-900 dark:text-white hover:bg-indigo-50 dark:hover:bg-indigo-500/10 truncate"
                  >
                    {p.name}
                  </button>
                ))}
                {filtered.length === 0 && (
                  <p className="text-xs text-gray-400 text-center py-3">Sin resultados</p>
                )}
              </div>
            </div>
          )}
        </div>

        {/* Artist name input */}
        {(() => {
          const sel = playlists.find(p => p.id === selectedId)
          const autoMatch = sel?.name.replace(/^\[spotify\]\s*/i, '').match(/^this is (.+)$/i)
          const isAutoDetected = !!autoMatch && artistName === (autoMatch[1]?.trim() ?? '')
          return (
            <div className="space-y-1">
              <input
                type="text"
                value={artistName}
                onChange={e => setArtistName(e.target.value)}
                onKeyDown={e => e.key === 'Enter' && handleAdd()}
                placeholder="Nombre del artista (ej: Bad Bunny)"
                className="w-full px-3 py-2.5 bg-gray-50 dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl text-sm text-gray-900 dark:text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-indigo-500"
              />
              {isAutoDetected ? (
                <p className="text-[11px] text-emerald-500 dark:text-emerald-400 pl-1">Extraído del nombre de la playlist automáticamente</p>
              ) : !selectedId ? (
                <p className="text-[11px] text-gray-400 pl-1">Solo necesario si el nombre no sigue el patrón "This is [Artista]"</p>
              ) : null}
            </div>
          )
        })()}

        <div className="flex items-center gap-3">
          <button
            onClick={handleAdd}
            disabled={!selectedId || saving}
            className="flex-1 flex items-center justify-center gap-2 py-2.5 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 disabled:cursor-not-allowed text-white text-sm font-semibold rounded-xl transition-colors"
          >
            {saving ? <Spinner size="sm" /> : <><CheckIcon className="w-4 h-4" />Añadir</>}
          </button>
          {saveMsg && (
            <span className={`text-xs font-medium ${saveMsg.ok ? 'text-emerald-500' : 'text-red-500'}`}>
              {saveMsg.text}
            </span>
          )}
        </div>
      </div>
    </div>
  )
}

// ─── Smart Playlists Tab ──────────────────────────────────────────────────────

const COVER_VARIANT_LABELS: Record<string, string> = {
  'classic':         'Clásico',
  'headline':        'Titular',
  'graphic':         'Gráfico',
  'artist-gradient': 'Artista + Gradiente',
}

const PLAYLIST_DESCRIPTIONS: Record<string, { description: string; cadence: string }> = {
  en_bucle:     { description: 'Canciones que estás escuchando en repeat esta semana.', cadence: 'Se regenera cada día a las 3:15h' },
  tiempo_atras: { description: 'Canciones que escuchabas mucho y llevas meses sin poner.', cadence: 'Se regenera cada domingo a las 3:30h' },
}

function SmartPlaylistCard({
  playlistKey,
  playlist,
  onRefresh,
}: {
  playlistKey: string
  playlist: SmartPlaylist | undefined
  onRefresh: () => void
}) {
  const meta = PLAYLIST_DESCRIPTIONS[playlistKey] ?? { description: '', cadence: '' }

  const [status, setStatus]     = useState<'idle' | 'loading' | 'success' | 'error'>('idle')
  const [message, setMessage]   = useState('')
  const [cooldown, setCooldown] = useState(0)
  const cooldownRef = useRef<ReturnType<typeof setInterval> | null>(null)

  const [coverVariant, setCoverVariant] = useState(playlist?.coverVariant ?? 'classic')
  const [isDirty, setIsDirty]           = useState(false)

  useEffect(() => {
    if (playlist) {
      setCoverVariant(playlist.coverVariant)
      setIsDirty(false)
    }
  }, [playlist])

  const startCooldown = (seconds: number) => {
    setCooldown(seconds)
    cooldownRef.current = setInterval(() => {
      setCooldown(prev => {
        if (prev <= 1) { clearInterval(cooldownRef.current!); cooldownRef.current = null; return 0 }
        return prev - 1
      })
    }, 1000)
  }

  const handleSaveConfig = async () => {
    try {
      await backendApi.updateSmartPlaylistConfig(playlistKey, { coverVariant })
      setIsDirty(false)
      onRefresh()
    } catch (err) {
      alert('Error al guardar: ' + (err instanceof Error ? err.message : String(err)))
    }
  }

  const handleRegenerate = async () => {
    if (status === 'loading' || cooldown > 0) return
    setStatus('loading')
    setMessage('')
    try {
      const config = await import('../services/navidromeApi').then(m => m.navidromeApi.getConfig())
      const result = await backendApi.generateSmartPlaylist(playlistKey, config)
      if (result.generated) {
        setStatus('success')
        setMessage(`✓ ${result.playlist?.trackCount ?? 0} canciones generadas`)
        onRefresh()
      } else {
        setStatus('error')
        setMessage(result.reason === 'insufficient_data' ? 'Datos insuficientes — sigue escuchando música' : 'Error al generar')
      }
      startCooldown(15)
    } catch (err) {
      setStatus('error')
      setMessage(err instanceof Error ? err.message : 'Error desconocido')
      startCooldown(15)
    } finally {
      setTimeout(() => setStatus('idle'), 6000)
    }
  }

  return (
    <div className={`bg-white dark:bg-gray-900 rounded-2xl border shadow-sm p-4 sm:p-5 flex flex-col gap-4 ${
      status === 'success' ? 'border-emerald-300 dark:border-emerald-600/40' :
      status === 'error'   ? 'border-red-300 dark:border-red-600/40' :
      'border-gray-200 dark:border-gray-800'
    }`}>
      {/* Header */}
      <div className="flex items-start justify-between gap-2">
        <div>
          <div className="flex items-center gap-2 mb-1">
            <p className="font-semibold text-gray-900 dark:text-white">
              {playlist?.name ?? (playlistKey === 'en_bucle' ? 'En Bucle' : 'Tiempo Atrás')}
            </p>
            <span className="text-[10px] font-bold px-2 py-0.5 rounded-full bg-indigo-100 dark:bg-indigo-500/15 text-indigo-700 dark:text-indigo-400 uppercase tracking-wider">
              {playlistKey === 'en_bucle' ? 'Diaria' : 'Semanal'}
            </span>
          </div>
          <p className="text-xs text-gray-500 dark:text-gray-400">{meta.description}</p>
          <p className="text-[10px] text-gray-400 mt-0.5">{meta.cadence}</p>
        </div>
        <div className="flex flex-col items-end gap-1 shrink-0">
          {playlist?.navidromeId ? (
            <span className="text-[10px] font-bold px-2 py-0.5 rounded-full bg-emerald-100 dark:bg-emerald-500/15 text-emerald-700 dark:text-emerald-400">
              Vinculada
            </span>
          ) : (
            <span className="text-[10px] font-bold px-2 py-0.5 rounded-full bg-gray-100 dark:bg-gray-800 text-gray-500">
              Sin vincular
            </span>
          )}
          {playlist?.trackCount != null && playlist.trackCount > 0 && (
            <span className="text-[10px] text-gray-400">{playlist.trackCount} canciones</span>
          )}
        </div>
      </div>

      {/* Last generated */}
      {playlist?.lastGenerated && (
        <p className="text-[11px] text-gray-400">
          Última generación: {new Date(playlist.lastGenerated).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })}
        </p>
      )}

      {/* Cover variant */}
      <div className="flex flex-col gap-1.5">
        <label className="text-[10px] font-bold text-gray-400 uppercase tracking-wider">Estilo de portada</label>
        <select
          value={coverVariant}
          onChange={e => { setCoverVariant(e.target.value); setIsDirty(true) }}
          className="w-full bg-gray-50 dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl px-3 py-2 text-sm text-gray-900 dark:text-white focus:outline-none focus:ring-2 focus:ring-indigo-500"
        >
          {Object.entries(COVER_VARIANT_LABELS).map(([val, label]) => (
            <option key={val} value={val}>{label}</option>
          ))}
        </select>
        <p className="text-[10px] text-gray-400">Se aplica en la siguiente regeneración</p>
      </div>

      {/* Save config */}
      {isDirty && (
        <button
          onClick={handleSaveConfig}
          className="w-full py-2 text-sm font-semibold bg-gray-100 dark:bg-gray-800 hover:bg-indigo-50 dark:hover:bg-indigo-500/10 text-gray-700 dark:text-gray-300 hover:text-indigo-600 dark:hover:text-indigo-400 rounded-xl transition-colors border border-gray-200 dark:border-gray-700"
        >
          Guardar configuración
        </button>
      )}

      {/* Regenerate */}
      <div className="mt-auto">
        {message && (
          <p className={`text-xs mb-2 font-medium ${
            status === 'success' || message.startsWith('✓') ? 'text-emerald-600 dark:text-emerald-400' : 'text-red-500 dark:text-red-400'
          }`}>{message}</p>
        )}
        <button
          onClick={handleRegenerate}
          disabled={status === 'loading' || cooldown > 0}
          className={`w-full flex items-center justify-center gap-2 px-4 py-2.5 rounded-xl text-sm font-semibold transition-all active:scale-95 ${
            status === 'loading' || cooldown > 0
              ? 'bg-gray-100 dark:bg-gray-800 text-gray-400 cursor-not-allowed'
              : 'bg-indigo-600 hover:bg-indigo-500 text-white shadow-sm shadow-indigo-500/20'
          }`}
        >
          {status === 'loading' ? (
            <><Spinner size="sm" /><span>Generando…</span></>
          ) : cooldown > 0 ? (
            <><ArrowPathIcon className="w-4 h-4" /><span>Espera {cooldown}s</span></>
          ) : (
            <><ArrowPathIcon className="w-4 h-4" /><span>Regenerar ahora</span></>
          )}
        </button>
      </div>
    </div>
  )
}

function SmartPlaylistsTab({ cronStatus }: { cronStatus: CronStatus | null }) {
  const [playlists, setPlaylists] = useState<SmartPlaylist[]>([])
  const [loading, setLoading]     = useState(true)
  const [allStatus, setAllStatus] = useState<'idle' | 'loading'>('idle')
  const [allCooldown, setAllCooldown] = useState(0)
  const allCooldownRef = useRef<ReturnType<typeof setInterval> | null>(null)

  // ─── Daily Mixes ──────────────────────────────────────────────────────────
  const [dailyMixStatus, setDailyMixStatus] = useState<'idle' | 'loading' | 'success' | 'error'>('idle')
  const [dailyMixMessage, setDailyMixMessage] = useState('')
  const [dailyMixCooldown, setDailyMixCooldown] = useState(0)
  const dailyMixCooldownRef = useRef<ReturnType<typeof setInterval> | null>(null)

  const startDailyMixCooldown = (seconds: number) => {
    setDailyMixCooldown(seconds)
    dailyMixCooldownRef.current = setInterval(() => {
      setDailyMixCooldown(prev => {
        if (prev <= 1) { clearInterval(dailyMixCooldownRef.current!); dailyMixCooldownRef.current = null; return 0 }
        return prev - 1
      })
    }, 1000)
  }

  const handleGenerateAllMixes = async () => {
    if (dailyMixStatus === 'loading' || dailyMixCooldown > 0) return
    if (!confirm('¿Regenerar los Daily Mixes de todos los usuarios del sistema?')) return
    setDailyMixStatus('loading')
    setDailyMixMessage('')
    try {
      const result = await backendApi.generateAllDailyMixes()
      const userCount = result.users.length
      setDailyMixStatus('success')
      setDailyMixMessage(`✓ ${result.totalGenerated} mixes generados para ${userCount} usuario${userCount !== 1 ? 's' : ''}`)
      startDailyMixCooldown(15)
    } catch (err) {
      setDailyMixStatus('error')
      setDailyMixMessage(err instanceof Error ? err.message : 'Error desconocido')
      startDailyMixCooldown(15)
    } finally {
      setTimeout(() => setDailyMixStatus('idle'), 6000)
    }
  }

  const load = async () => {
    try {
      const { navidromeApi } = await import('../services/navidromeApi')
      const config = navidromeApi.getConfig()
      const data = await backendApi.getSmartPlaylists(config)
      setPlaylists(data)
    } catch { /* silencioso */ } finally {
      setLoading(false)
    }
  }

  useEffect(() => { load() }, [])

  const startAllCooldown = (seconds: number) => {
    setAllCooldown(seconds)
    allCooldownRef.current = setInterval(() => {
      setAllCooldown(prev => {
        if (prev <= 1) { clearInterval(allCooldownRef.current!); allCooldownRef.current = null; return 0 }
        return prev - 1
      })
    }, 1000)
  }

  const handleGenerateAll = async () => {
    if (allStatus === 'loading' || allCooldown > 0) return
    if (!confirm('¿Regenerar todas las Smart Playlists ahora?')) return
    setAllStatus('loading')
    try {
      await backendApi.generateAllSmartPlaylists()
      await load()
      startAllCooldown(30)
    } catch (err) {
      alert('Error: ' + (err instanceof Error ? err.message : String(err)))
    } finally {
      setAllStatus('idle')
    }
  }

  const KEYS = ['en_bucle', 'tiempo_atras'] as const

  if (loading) {
    return (
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        {[1, 2].map(i => <div key={i} className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 h-72 animate-pulse" />)}
      </div>
    )
  }

  return (
    <div className="space-y-10">

      {/* ── Daily Mixes ─────────────────────────────────────────────────────── */}
      <section>
        <div className="flex items-center justify-between mb-4">
          <div>
            <h2 className="text-lg font-semibold text-gray-900 dark:text-white flex items-center gap-2">
              <QueueListIcon className="w-5 h-5 text-gray-400" />
              Daily Mixes
            </h2>
            <p className="text-sm text-gray-500 mt-0.5">Un mix personalizado por usuario, generado cada día a partir de su historial de escucha</p>
          </div>
          <button
            id="btn-regenerate-daily-mixes"
            onClick={handleGenerateAllMixes}
            disabled={dailyMixStatus === 'loading' || dailyMixCooldown > 0}
            className={`flex items-center gap-2 px-4 py-2 rounded-xl text-sm font-semibold transition-all active:scale-95 ${
              dailyMixStatus === 'loading' || dailyMixCooldown > 0
                ? 'bg-gray-100 dark:bg-gray-800 text-gray-400 cursor-not-allowed'
                : 'bg-indigo-600 hover:bg-indigo-500 text-white'
            }`}
          >
            {dailyMixStatus === 'loading' ? <><Spinner size="sm" /><span>Generando...</span></> :
             dailyMixCooldown > 0         ? <><ArrowPathIcon className="w-4 h-4" /><span>Espera {dailyMixCooldown}s</span></> :
                                            <><SparklesIcon className="w-4 h-4" /><span>Regenerar todos</span></>}
          </button>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {/* Status card */}
          <div className={`bg-white dark:bg-gray-900 rounded-2xl border shadow-sm p-5 flex flex-col gap-3 ${
            dailyMixStatus === 'success' ? 'border-emerald-300 dark:border-emerald-600/40' :
            dailyMixStatus === 'error'   ? 'border-red-300 dark:border-red-600/40' :
            'border-gray-200 dark:border-gray-800'
          }`}>
            <div className="flex items-center justify-between">
              <span className="text-[10px] font-bold text-gray-400 uppercase tracking-wider">Última generación</span>
              {cronStatus && (
                <span className={`flex items-center gap-1.5 text-[11px] font-semibold px-2 py-0.5 rounded-full ${
                  cronStatus.status === 'running' ? 'bg-amber-100 text-amber-700 dark:bg-amber-500/15 dark:text-amber-400' :
                  cronStatus.status === 'error'   ? 'bg-red-100 text-red-700 dark:bg-red-500/15 dark:text-red-400' :
                  cronStatus.status === 'success' ? 'bg-emerald-100 text-emerald-700 dark:bg-emerald-500/15 dark:text-emerald-400' :
                  'bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400'
                }`}>
                  <span className={`w-1.5 h-1.5 rounded-full ${
                    cronStatus.status === 'running' ? 'bg-amber-500 animate-pulse' :
                    cronStatus.status === 'error'   ? 'bg-red-500' :
                    cronStatus.status === 'success' ? 'bg-emerald-500' : 'bg-gray-400'
                  }`} />
                  {cronStatus.status === 'running' ? 'Generando' : cronStatus.status === 'error' ? 'Fallido' : cronStatus.status === 'success' ? 'OK' : 'En espera'}
                </span>
              )}
            </div>
            <p className="text-sm font-semibold text-gray-900 dark:text-gray-100">
              {cronStatus?.lastRun
                ? new Date(cronStatus.lastRun).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })
                : 'Pendiente'}
            </p>
            {cronStatus?.lastError && (
              <p className="text-[11px] text-red-500 line-clamp-2" title={cronStatus.lastError}>⚠ {cronStatus.lastError}</p>
            )}
            {dailyMixMessage && (
              <p className={`text-xs font-medium mt-1 ${
                dailyMixStatus === 'success' || dailyMixMessage.startsWith('✓') ? 'text-emerald-600 dark:text-emerald-400' : 'text-red-500 dark:text-red-400'
              }`}>{dailyMixMessage}</p>
            )}
          </div>

          {/* Cron next run */}
          <div className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 shadow-sm p-5 flex flex-col gap-3">
            <span className="text-[10px] font-bold text-gray-400 uppercase tracking-wider">Próxima ejecución automática</span>
            <p className="text-sm font-semibold text-gray-900 dark:text-gray-100">
              {cronStatus?.nextRun
                ? new Date(cronStatus.nextRun).toLocaleString(undefined, { weekday: 'short', hour: '2-digit', minute: '2-digit' })
                : 'Calculando...'}
            </p>
            <p className="text-xs text-gray-400">Se ejecuta cada noche a las 3:00h para todos los usuarios</p>
          </div>
        </div>
      </section>

      {/* ── Smart Playlists ──────────────────────────────────────────────────── */}
      <section>
        <div className="flex items-center justify-between mb-4">
          <div>
            <h2 className="text-lg font-semibold text-gray-900 dark:text-white flex items-center gap-2">
              <SparklesIcon className="w-5 h-5 text-gray-400" />
              Smart Playlists
            </h2>
            <p className="text-sm text-gray-500 mt-0.5">Playlists generadas automáticamente a partir del historial de cada usuario</p>
          </div>
          <button
            onClick={handleGenerateAll}
            disabled={allStatus === 'loading' || allCooldown > 0}
            className={`flex items-center gap-2 px-4 py-2 rounded-xl text-sm font-semibold transition-all active:scale-95 ${
              allStatus === 'loading' || allCooldown > 0
                ? 'bg-gray-100 dark:bg-gray-800 text-gray-400 cursor-not-allowed'
                : 'bg-indigo-600 hover:bg-indigo-500 text-white'
            }`}
          >
            {allStatus === 'loading' ? <><Spinner size="sm" /><span>Generando…</span></> :
             allCooldown > 0         ? <><ArrowPathIcon className="w-4 h-4" /><span>Espera {allCooldown}s</span></> :
                                       <><SparklesIcon className="w-4 h-4" /><span>Regenerar todas</span></>}
          </button>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {KEYS.map(key => (
            <SmartPlaylistCard
              key={key}
              playlistKey={key}
              playlist={playlists.find(p => p.playlistKey === key)}
              onRefresh={load}
            />
          ))}
        </div>
      </section>

      {/* ── This Is — Portadas personalizadas ────────────────────────────────── */}
      <section>
        <div className="mb-4">
          <h2 className="text-lg font-semibold text-gray-900 dark:text-white flex items-center gap-2">
            <MusicalNoteIcon className="w-5 h-5 text-gray-400" />
            This Is — Portadas personalizadas
          </h2>
          <p className="text-sm text-gray-500 mt-0.5">
            Asigna una portada estilo "This Is" a cualquier playlist, con la foto del artista y su nombre
          </p>
        </div>
        <ThisIsPanel />
      </section>
    </div>
  )
}

// (HubStatusWidget removed — replaced by ConnectHubWidget above)
// ─── AdminPage ────────────────────────────────────────────────────────────────

export default function AdminPage() {
  const navigate = useNavigate()
  const { tab } = useParams<{ tab?: string }>()
  const activeTab = (tab as 'stats' | 'media' | 'editorial' | 'users' | 'playlists') || 'stats'
  const { devices } = useConnect()
  const [latencyMs, setLatencyMs] = useState<number | null>(null)
  const [stats, setStats] = useState<ServerStats | null>(null)
  const [isLoading, setIsLoading] = useState(true)
  const [isAdmin, setIsAdmin] = useState(false)

  // Sync state
  const [spotifyId, setSpotifyId] = useState('')
  const [customName, setCustomName] = useState('')
  const [preview, setPreview] = useState<SyncPreviewResult | null>(null)
  const [isSearching, setIsSearching] = useState(false)
  const [syncs, setSyncs] = useState<SyncedPlaylist[]>([])
  const [isSyncing, setIsSyncing] = useState(false)
  
  // Cron Status
  const [cronStatus, setCronStatus] = useState<CronStatus | null>(null)
  // Guardar el ID extraído para usarlo en handleStartSync
  const resolvedSpotifyIdRef = useRef('')
  // Modal de canciones matcheadas
  const [selectedSync, setSelectedSync] = useState<SyncedPlaylist | null>(null)
  // Estado para saber qué playlist se está sincronizando manualmente
  const [syncingId, setSyncingId] = useState<string | null>(null)

  useEffect(() => {
    const config = navidromeApi.getConfig()

    if (!config || !config.isAdmin) {
      setIsAdmin(false)
      navigate('/', { replace: true })
      return
    }

    setIsAdmin(true)

    const loadData = async () => {
      setIsLoading(true)
      // Medir latencia a Navidrome en paralelo con la carga de datos
      const t0 = Date.now()
      navidromeApi.pingForStatus().then(() => setLatencyMs(Date.now() - t0)).catch(() => setLatencyMs(null))
      try {
        const [serverInfo, syncList] = await Promise.all([
          navidromeApi.ping(),
          backendApi.listSyncs(),
        ])
        
        setStats({
          serverUrl: config.serverUrl,
          username: config.username,
          version: serverInfo?.version || null,
        })
        setSyncs(syncList)

        // Asegurarse de que el backend tenga la config para el scheduler
        await backendApi.saveSyncNavidromeConfig({
          serverUrl: config.serverUrl,
          username: config.username,
          token: config.token!,
        })
      } catch (error) {
        console.error('[AdminPage] Error loading data:', error)
      } finally {
        setIsLoading(false)
      }
    }

    loadData()
  }, [navigate])

  const handlePreview = async () => {
    if (!spotifyId) return
    setIsSearching(true)
    setPreview(null)
    try {
      const cleanId = extractSpotifyId(spotifyId)
      resolvedSpotifyIdRef.current = cleanId
      const data = await backendApi.getSyncPreview(cleanId)
      setPreview(data)
    } catch (error) {
      alert('Error buscando playlist: ' + (error instanceof Error ? error.message : String(error)))
    } finally {
      setIsSearching(false)
    }
  }

  const handleStartSync = async () => {
    if (!preview) return
    setIsSyncing(true)
    try {
      const idToSync = resolvedSpotifyIdRef.current || extractSpotifyId(spotifyId)
      await backendApi.startSync(idToSync, customName || undefined)
      const updatedSyncs = await backendApi.listSyncs()
      setSyncs(updatedSyncs)
      setPreview(null)
      setSpotifyId('')
      setCustomName('')
      resolvedSpotifyIdRef.current = ''
      navigate('/admin/media')
    } catch (error) {
      alert('Error iniciando sincronización: ' + (error instanceof Error ? error.message : String(error)))
    } finally {
      setIsSyncing(false)
    }
  }

  const handleDeleteSync = async (id: string) => {
    if (!confirm('¿Detener sincronización de esta playlist?')) return
    try {
      await backendApi.deleteSync(id)
      setSyncs(prev => prev.filter(s => s.spotifyId !== id))
    } catch (error) {
      alert('Error al eliminar: ' + (error instanceof Error ? error.message : String(error)))
    }
  }

  const handleManualSync = async (id: string) => {
    setSyncingId(id)
    try {
      await backendApi.triggerSync(id)
      const updatedSyncs = await backendApi.listSyncs()
      setSyncs(updatedSyncs)
    } catch (error) {
      alert('Error al sincronizar: ' + (error instanceof Error ? error.message : String(error)))
    } finally {
        setSyncingId(null)
    }
  }

  // Covers regeneration (All)
  const [coversStatus, setCoversStatus] = useState<'idle' | 'loading' | 'success' | 'error'>('idle')
  const [coversMessage, setCoversMessage] = useState<string>('')
  const [coversCooldown, setCoversCooldown] = useState(0)
  const coversCooldownRef = useRef<ReturnType<typeof setInterval> | null>(null)

  const startCoversCooldown = (seconds: number) => {
    setCoversCooldown(seconds)
    coversCooldownRef.current = setInterval(() => {
      setCoversCooldown(prev => {
        if (prev <= 1) {
          clearInterval(coversCooldownRef.current!)
          coversCooldownRef.current = null
          return 0
        }
        return prev - 1
      })
    }, 1000)
  }

  const handleRegenerateAllCovers = async () => {
    if (coversStatus === 'loading' || coversCooldown > 0) return
    if (!confirm('¿Forzar la regeneración de todas las portadas del sistema?')) return

    setCoversStatus('loading')
    setCoversMessage('')
    try {
      const res = await backendApi.regenerateAllCovers()
      setCoversStatus('success')
      setCoversMessage(`✓ ${res.queuedCount} portadas encoladas para generación.`)
      startCoversCooldown(15)
    } catch(err) {
      setCoversStatus('error')
      setCoversMessage(err instanceof Error ? err.message : 'Error desconocido')
      startCoversCooldown(15)
    } finally {
      setTimeout(() => setCoversStatus('idle'), 6000)
    }
  }

  // Poll cron status periodically
  useEffect(() => {
    if (!isAdmin) return
    let mounted = true
    const fetchCron = async () => {
      try {
        const status = await backendApi.getDailyMixesCronStatus()
        if (mounted) setCronStatus(status)
      } catch { /* si falla, ignorar logs pesados en loop */ }
    }
    fetchCron()
    const interval = setInterval(fetchCron, 15000)
    return () => {
      mounted = false
      clearInterval(interval)
    }
  }, [isAdmin])

  const refreshSyncs = async () => {
    try {
      const updatedSyncs = await backendApi.listSyncs()
      setSyncs(updatedSyncs)
    } catch { /* silencioso */ }
  }

  if (!isAdmin) return null

  return (
    <div className="min-h-full px-4 py-4 md:px-8 md:py-8 max-w-6xl mx-auto">
      {/* Tab bar */}
      <div className="mb-8 border-b border-gray-200 dark:border-gray-700 overflow-x-auto scrollbar-hide">
        <nav className="-mb-px flex gap-4 md:gap-6 min-w-max pb-1" aria-label="Tabs">
          {(['stats', 'media', 'editorial', 'users', 'playlists'] as const).map(t => {
            const labels: Record<string, string> = { stats: 'General', media: 'Contenido', editorial: 'Editorial', users: 'Usuarios', playlists: 'Playlists de Audiorr' }
            return (
              <button
                key={t}
                onClick={() => navigate(`/admin/${t}`)}
                className={`whitespace-nowrap py-3 px-1 border-b-2 font-medium text-sm transition-colors ${
                  activeTab === t
                    ? 'border-indigo-500 text-indigo-600 dark:text-indigo-400'
                    : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300 dark:text-gray-400 dark:hover:text-gray-300 dark:hover:border-gray-600'
                }`}
              >
                {labels[t]}
              </button>
            )
          })}
        </nav>
      </div>

      {activeTab === 'media' ? (
        <div className="space-y-6 max-w-5xl mx-auto">
          {/* Sección: Spotify Sync */}
          <section>
            <div className="mb-4">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white flex items-center gap-2">
                <svg className="w-5 h-5 text-[#1DB954]" viewBox="0 0 24 24" fill="currentColor">
                  <path d="M12 0C5.4 0 0 5.4 0 12s5.4 12 12 12 12-5.4 12-12S18.66 0 12 0zm5.521 17.34c-.24.359-.66.48-1.021.24-2.82-1.74-6.36-2.101-10.561-1.141-.418.122-.779-.179-.899-.539-.12-.421.18-.78.54-.9 4.56-1.021 8.52-.6 11.64 1.32.42.18.479.659.301 1.02zm1.44-3.3c-.301.42-.84.6-1.262.3-3.239-1.98-8.159-2.58-11.939-1.38-.479.12-1.02-.12-1.14-.6-.12-.48.12-1.021.6-1.141C9.6 9.9 15 10.561 18.72 12.84c.361.181.54.78.241 1.2zm.12-3.36C15.24 8.4 8.82 8.16 5.16 9.301c-.6.179-1.2-.181-1.38-.721-.18-.6.18-1.2.72-1.38 4.26-1.26 11.28-1.02 15.721 1.621.539.3.719 1.02.419 1.56-.299.421-1.02.599-1.559.3z" />
                </svg>
                Spotify Sync
              </h2>
            </div>

            <div className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 p-5 sm:p-8 shadow-sm">
              <div className="space-y-5">
                <div className="flex flex-col sm:flex-row gap-5">
                  <div className="flex flex-col gap-2 flex-1">
                    <label className="text-[11px] font-bold text-gray-500 dark:text-gray-400 uppercase tracking-wider ml-1">ID o Enlace de Spotify</label>
                    <input
                      type="text"
                      placeholder="https://open.spotify.com/playlist/..."
                      value={spotifyId}
                      onChange={e => setSpotifyId(e.target.value)}
                      className="w-full bg-gray-50 dark:bg-gray-800/80 border border-gray-200 dark:border-gray-700 rounded-2xl px-5 py-3.5 text-gray-900 dark:text-white font-medium focus:outline-none focus:ring-2 focus:ring-[#1DB954] transition-all"
                    />
                  </div>

                  <div className="flex flex-col gap-2 flex-1">
                    <label className="text-[11px] font-bold text-gray-500 dark:text-gray-400 uppercase tracking-wider ml-1">Nombre Personalizado <span className="text-gray-400 dark:text-gray-600">(Opcional)</span></label>
                    <input
                      type="text"
                      placeholder="Ej: Mis Favoritos de Spotify"
                      value={customName}
                      onChange={e => setCustomName(e.target.value)}
                      className="w-full bg-gray-50 dark:bg-gray-800/80 border border-gray-200 dark:border-gray-700 rounded-2xl px-5 py-3.5 text-gray-900 dark:text-white font-medium focus:outline-none focus:ring-2 focus:ring-[#1DB954] transition-all"
                    />
                  </div>
                </div>

                <div className="flex justify-end pt-2">
                  <button
                    onClick={handlePreview}
                    disabled={isSearching || !spotifyId}
                    className="w-full sm:w-auto bg-[#1DB954] hover:bg-[#1ed760] disabled:opacity-50 text-white px-8 py-3.5 rounded-2xl font-bold transition-all flex items-center justify-center gap-2 shadow-lg shadow-[#1DB954]/20 active:scale-95"
                  >
                    {isSearching ? <Spinner size="sm" /> : 'Analizar Playlist'}
                  </button>
                </div>
              </div>

              {preview && (
                <div className="mt-6 p-5 sm:p-6 bg-gray-50 dark:bg-gray-800/50 rounded-2xl border border-gray-200 dark:border-gray-700/50">
                  <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 mb-6">
                    <div>
                      <h3 className="text-base font-bold text-gray-900 dark:text-white leading-tight">{preview.name}</h3>
                      <p className="text-sm font-medium text-gray-500 mt-1">{preview.trackCount} canciones en total</p>
                    </div>
                    <div className="text-left sm:text-right bg-white dark:bg-gray-900 px-4 py-3 rounded-xl border border-gray-200 dark:border-gray-700/50 shadow-sm w-fit">
                      <div className="text-2xl font-black text-[#1DB954]">
                        {Math.round((preview as SyncPreviewResult).percentage || 0)}%
                      </div>
                      <p className="text-[10px] text-gray-500 uppercase tracking-wider font-bold mt-0.5">Coincidencia</p>
                    </div>
                  </div>

                  <div className="mb-6">
                    <div className="flex justify-between text-xs sm:text-sm font-bold text-gray-600 dark:text-gray-400 mb-2.5">
                      <span>Encontradas en el servidor</span>
                      <span className="font-mono text-gray-900 dark:text-white">{Math.round(preview.matchCount)} / {preview.trackCount}</span>
                    </div>
                    <div className="w-full bg-gray-200 dark:bg-gray-700/50 h-3 rounded-full overflow-hidden shadow-inner">
                      <div
                        className="bg-[#1DB954] h-full transition-all duration-1000 ease-out"
                        style={{ width: `${(preview as SyncPreviewResult).percentage || 0}%` }}
                      />
                    </div>
                  </div>

                  <div className="flex flex-col-reverse sm:flex-row justify-end gap-3">
                    <button
                      onClick={() => setPreview(null)}
                      className="px-5 py-2.5 text-sm font-semibold text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white bg-transparent hover:bg-gray-100 dark:hover:bg-gray-800 rounded-xl transition-all w-full sm:w-auto text-center"
                    >
                      Cancelar
                    </button>
                    <button
                      onClick={handleStartSync}
                      disabled={isSyncing}
                      className="bg-indigo-600 hover:bg-indigo-500 active:scale-95 text-white px-6 py-2.5 rounded-xl text-sm font-semibold transition-all flex items-center justify-center gap-2 shadow-sm w-full sm:w-auto"
                    >
                      {isSyncing ? <Spinner size="sm" /> : 'Sincronizar ahora'}
                    </button>
                  </div>
                </div>
              )}
            </div>
          </section>

          <section>
            <div className="mb-3">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white">Playlists Sincronizadas</h2>
            </div>

            <div className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 p-2 sm:p-5 shadow-sm overflow-hidden max-h-[500px] overflow-y-auto">
              {syncs.length === 0 ? (
                <div className="text-center py-16 text-gray-500">
                  <div className="w-16 h-16 rounded-full bg-gray-100 dark:bg-gray-800 flex items-center justify-center mx-auto mb-4">
                    <MusicalNoteIcon className="w-8 h-8 opacity-40 text-gray-400" />
                  </div>
                  <p className="font-semibold">No hay playlists sincronizadas.</p>
                  <p className="text-sm mt-1 opacity-70">Añade una indicando su link de Spotify arriba.</p>
                </div>
              ) : (
                <ul className="divide-y divide-gray-100 dark:divide-gray-800/60">
                  {syncs.map(sync => {
                    const pct = sync.trackCount > 0 ? Math.round((sync.matchCount / sync.trackCount) * 100) : 0
                    return (
                      <li key={sync.spotifyId} className="group relative flex flex-col sm:flex-row sm:items-center justify-between gap-4 p-4 hover:bg-white/80 dark:hover:bg-gray-800/40 rounded-2xl transition-colors">
                        <div className="flex-1 min-w-0 pr-24 sm:pr-0">
                          <p className="text-base font-bold text-gray-900 dark:text-white truncate mb-1" title={sync.name}>{sync.name}</p>
                          <div className="flex flex-wrap items-center gap-2 sm:gap-3">
                            <span className="text-xs text-gray-500 font-mono tracking-tight bg-gray-100 dark:bg-gray-800 px-2 py-0.5 rounded-md select-all truncate max-w-[120px] sm:max-w-none">
                              {sync.spotifyId}
                            </span>
                            <span className={`inline-flex items-center text-[10px] uppercase tracking-wider font-black px-2 py-0.5 rounded-full ${
                              pct >= 80 ? 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400' :
                              pct >= 50 ? 'bg-amber-100 dark:bg-amber-900/30 text-amber-700 dark:text-amber-400' :
                              'bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-400'
                            }`}>
                              {pct}% · {sync.matchCount}/{sync.trackCount}
                            </span>
                            <span className={`inline-flex items-center text-[10px] uppercase tracking-wider font-black px-2 py-0.5 rounded-full ${
                              sync.enabled ? 'bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400' : 'bg-gray-200 text-gray-600 dark:bg-gray-700 dark:text-gray-400'
                            }`}>
                              {sync.enabled ? 'Activa' : 'Pausada'}
                            </span>
                          </div>
                          <p className="text-[11px] text-gray-400 font-medium mt-1.5 sm:hidden block">
                            Ult. vez: {sync.lastSync ? new Date(sync.lastSync).toLocaleString() : 'Nunca'}
                          </p>
                        </div>

                        <div className="hidden sm:block text-right">
                          <p className="text-xs font-medium text-gray-400 mb-1">Última Sincro.</p>
                          <p className="text-sm font-semibold text-gray-700 dark:text-gray-300">
                            {sync.lastSync ? new Date(sync.lastSync).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : 'Nunca'}
                          </p>
                        </div>

                        <div className="absolute top-4 right-4 sm:relative sm:top-auto sm:right-auto flex justify-end gap-1.5 opacity-100 sm:opacity-0 sm:group-hover:opacity-100 transition-opacity">
                          <button
                            onClick={() => setSelectedSync(sync)}
                            title="Ver canciones / Editar"
                            className="p-2.5 text-gray-500 hover:text-indigo-600 dark:text-gray-400 dark:hover:text-indigo-400 bg-gray-100 hover:bg-indigo-50 dark:bg-gray-800 dark:hover:bg-indigo-900/30 rounded-xl transition-colors shrink-0"
                          >
                            <MusicalNoteIcon className="w-5 h-5" />
                          </button>
                          <button
                            onClick={() => handleManualSync(sync.spotifyId)}
                            title="Sincronizar ahora"
                            disabled={syncingId === sync.spotifyId}
                            className={`p-2.5 text-blue-500 hover:text-blue-600 dark:text-blue-400 dark:hover:text-blue-300 bg-blue-50 hover:bg-blue-100 dark:bg-blue-500/10 dark:hover:bg-blue-500/20 rounded-xl transition-colors shrink-0 ${syncingId === sync.spotifyId ? 'opacity-50 cursor-not-allowed' : ''}`}
                          >
                            <ArrowPathIcon className={`w-5 h-5 ${syncingId === sync.spotifyId ? 'animate-spin' : ''}`} />
                          </button>
                          <button
                            onClick={() => handleDeleteSync(sync.spotifyId)}
                            title="Eliminar sincronización"
                            className="p-2.5 text-red-500 hover:text-red-600 dark:text-red-400 dark:hover:text-red-300 bg-red-50 hover:bg-red-100 dark:bg-red-500/10 dark:hover:bg-red-500/20 rounded-xl transition-colors shrink-0"
                          >
                            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" /></svg>
                          </button>
                        </div>
                      </li>
                    )
                  })}
                </ul>
              )}
            </div>
          </section>

          {/* Sección: Canvas */}
          <section>
            <div className="mb-4">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white">Canvas</h2>
            </div>
            <div className="bg-white dark:bg-gray-900 rounded-2xl p-4 sm:p-6 border border-gray-200 dark:border-gray-800 shadow-sm">
              <CanvasBulkPanel />
            </div>
          </section>
        </div>
      ) : activeTab === 'editorial' ? (
        <div className="bg-white dark:bg-gray-900 rounded-2xl p-4 sm:p-6 border border-gray-200 dark:border-gray-800 shadow-sm">
          <AdminEditorialPanel />
        </div>
      ) : activeTab === 'users' ? (
        <UsersTab />
      ) : activeTab === 'playlists' ? (
        <SmartPlaylistsTab cronStatus={cronStatus} />
      ) : activeTab === 'stats' ? (
        <>
          {/* Row 1: Stat cards */}
          {isLoading ? (
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
              {[1, 2, 3].map(i => (
                <div key={i} className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 h-28 animate-pulse" />
              ))}
            </div>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
              <div className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 shadow-sm p-4 sm:p-5">
                <div className="flex items-center gap-2 mb-3">
                  <ServerIcon className="w-4 h-4 text-gray-400" />
                  <span className="text-[10px] font-bold text-gray-400 uppercase tracking-wider">Servidor</span>
                </div>
                <p className="text-sm font-bold text-gray-900 dark:text-white truncate">{stats?.serverUrl || '—'}</p>
                {stats?.version && <p className="text-xs text-gray-400 mt-1">Navidrome v{stats.version}</p>}
              </div>

              <div className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 shadow-sm p-4 sm:p-5">
                <div className="flex items-center gap-2 mb-3">
                  <SignalIcon className="w-4 h-4 text-gray-400" />
                  <span className="text-[10px] font-bold text-gray-400 uppercase tracking-wider">Latencia Navidrome</span>
                </div>
                <p className={`text-2xl font-black ${
                  latencyMs === null ? 'text-gray-300 dark:text-gray-600' :
                  latencyMs < 100 ? 'text-emerald-500' :
                  latencyMs < 300 ? 'text-amber-500' : 'text-red-500'
                }`}>
                  {latencyMs === null ? '—' : `${latencyMs}ms`}
                </p>
                <p className="text-xs text-gray-400 mt-1">
                  {latencyMs === null ? 'Midiendo...' : latencyMs < 100 ? 'Excelente' : latencyMs < 300 ? 'Normal' : 'Alta latencia'}
                </p>
              </div>

              <div className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 shadow-sm p-4 sm:p-5">
                <div className="flex items-center gap-2 mb-3">
                  <UsersIcon className="w-4 h-4 text-gray-400" />
                  <span className="text-[10px] font-bold text-gray-400 uppercase tracking-wider">Dispositivos online</span>
                </div>
                <p className="text-2xl font-black text-gray-900 dark:text-white">{devices.length}</p>
                <p className="text-xs text-gray-400 mt-1">
                  {devices.length === 1 ? '1 dispositivo conectado' : `${devices.length} dispositivos conectados`}
                </p>
              </div>
            </div>
          )}

          {/* Row 2: Connect Hub */}
          <div className="mb-4">
            <ConnectHubWidget />
          </div>

          {/* Row 3: Tool cards */}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">

            {/* Portadas Server */}
            <div className={`bg-white dark:bg-gray-900 rounded-2xl border shadow-sm p-4 sm:p-5 flex flex-col ${
              coversStatus === 'success' ? 'border-emerald-300 dark:border-emerald-600/40' :
              coversStatus === 'error' ? 'border-red-300 dark:border-red-600/40' :
              'border-gray-200 dark:border-gray-800'
            }`}>
              <div className="flex items-center gap-2.5 mb-2">
                <CircleStackIcon className="w-4 h-4 text-gray-400" />
                <h3 className="font-semibold text-sm text-gray-900 dark:text-white">Portadas Server</h3>
              </div>
              <p className="text-xs text-gray-500 dark:text-gray-400 mb-5 leading-relaxed">
                Fuerza la regeneración de todas las portadas en el servidor.
              </p>
              <div className="mt-auto">
                {coversMessage && (
                  <p className={`text-xs mb-3 font-medium ${
                    coversStatus === 'success' || coversMessage.startsWith('✓')
                      ? 'text-emerald-600 dark:text-emerald-400'
                      : 'text-red-500 dark:text-red-400'
                  }`}>{coversMessage}</p>
                )}
                <button
                  onClick={handleRegenerateAllCovers}
                  disabled={coversStatus === 'loading' || coversCooldown > 0}
                  className={`w-full flex items-center justify-center gap-2 px-4 py-2.5 rounded-xl text-sm font-semibold transition-all active:scale-95 ${
                    coversStatus === 'loading' || coversCooldown > 0
                      ? 'bg-gray-100 dark:bg-gray-800 text-gray-400 cursor-not-allowed'
                      : 'bg-indigo-600 hover:bg-indigo-500 text-white shadow-sm shadow-indigo-500/20'
                  }`}
                >
                  {coversStatus === 'loading' ? (
                    <><Spinner size="sm" /><span>Encolando...</span></>
                  ) : coversCooldown > 0 ? (
                    <><ArrowPathIcon className="w-4 h-4" /><span>Espera {coversCooldown}s</span></>
                  ) : (
                    <><ArrowPathIcon className="w-4 h-4" /><span>Regenerar todas</span></>
                  )}
                </button>
              </div>
            </div>

            {/* Cron / Automatización */}
            <div className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 shadow-sm p-4 sm:p-5">
              <div className="flex items-center justify-between mb-4">
                <div className="flex items-center gap-2.5">
                  <ClockIcon className="w-4 h-4 text-gray-400" />
                  <h3 className="font-semibold text-sm text-gray-900 dark:text-white">Automatización</h3>
                </div>
                <span className={`flex items-center gap-1.5 text-[11px] font-semibold px-2 py-0.5 rounded-full ${
                  cronStatus?.status === 'running' ? 'bg-amber-100 text-amber-700 dark:bg-amber-500/15 dark:text-amber-400' :
                  cronStatus?.status === 'error' ? 'bg-red-100 text-red-700 dark:bg-red-500/15 dark:text-red-400' :
                  cronStatus?.status === 'success' ? 'bg-emerald-100 text-emerald-700 dark:bg-emerald-500/15 dark:text-emerald-400' :
                  'bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400'
                }`}>
                  <span className={`w-1.5 h-1.5 rounded-full ${
                    cronStatus?.status === 'running' ? 'bg-amber-500 animate-pulse' :
                    cronStatus?.status === 'error' ? 'bg-red-500' :
                    cronStatus?.status === 'success' ? 'bg-emerald-500' : 'bg-gray-400'
                  }`} />
                  {cronStatus?.status === 'running' ? 'En progreso' :
                   cronStatus?.status === 'error' ? 'Fallido' :
                   cronStatus?.status === 'success' ? 'Operativo' : 'En espera'}
                </span>
              </div>
              <div className="space-y-3">
                <div>
                  <p className="text-[10px] font-bold text-gray-400 uppercase tracking-wider mb-1">Próxima ejecución</p>
                  <p className="text-sm font-semibold text-gray-900 dark:text-gray-100">
                    {cronStatus?.nextRun
                      ? new Date(cronStatus.nextRun).toLocaleString(undefined, { weekday: 'short', hour: '2-digit', minute: '2-digit' })
                      : 'Calculando...'}
                  </p>
                </div>
                <div>
                  <p className="text-[10px] font-bold text-gray-400 uppercase tracking-wider mb-1">Última ejecución</p>
                  <p className="text-sm font-semibold text-gray-900 dark:text-gray-100">
                    {cronStatus?.lastRun
                      ? new Date(cronStatus.lastRun).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })
                      : 'Pendiente'}
                  </p>
                  {cronStatus?.lastError && (
                    <p className="text-[11px] text-red-500 mt-1.5 line-clamp-2" title={cronStatus.lastError}>
                      ⚠ {cronStatus.lastError}
                    </p>
                  )}
                </div>
              </div>
            </div>

          </div>
        </>
      ) : null}

      {/* Modal de canciones matcheadas — renderizado via portal en document.body */}
      {selectedSync && (
        <MatchedTracksModal
          sync={selectedSync}
          onClose={() => setSelectedSync(null)}
          onResync={refreshSyncs}
        />
      )}
    </div>
  )
}
