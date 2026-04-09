import { useState, useEffect, useRef, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { navidromeApi, Album, Song } from '../services/navidromeApi'
import {
  MagnifyingGlassIcon,
  XMarkIcon,
  ClockIcon,
} from '@heroicons/react/24/outline'
import { TrashIcon } from '@heroicons/react/24/solid'
import { usePlayerActions } from '../contexts/PlayerContext'
import { getArtistAvatarCache, setArtistAvatarCache } from '../utils/artistAvatarCache'
import AlbumCover from './AlbumCover'

interface SearchResult {
  artists: Array<{ id: string; name: string }>
  albums: Album[]
  songs: Song[]
}

const SEARCH_HISTORY_KEY = 'audiorr_search_history'
const MAX_HISTORY_ITEMS = 5

export default function SearchPage() {
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<SearchResult>({ artists: [], albums: [], songs: [] })
  const [isSearching, setIsSearching] = useState(false)
  const [searchHistory, setSearchHistory] = useState<string[]>([])
  const [artistAvatars, setArtistAvatars] = useState<Map<string, string | null>>(new Map())
  const [failedAvatars, setFailedAvatars] = useState<Set<string>>(new Set())
  const inputRef = useRef<HTMLInputElement>(null)
  const navigate = useNavigate()
  const playerActions = usePlayerActions()

  // Sin auto-focus: en iOS nativo el teclado no debe aparecer solo al entrar al tab

  // Cargar historial
  useEffect(() => {
    try {
      const stored = localStorage.getItem(SEARCH_HISTORY_KEY)
      if (stored) setSearchHistory((JSON.parse(stored) as string[]).slice(0, MAX_HISTORY_ITEMS))
    } catch {}
  }, [])

  // Guardar en historial
  const saveToHistory = useCallback((q: string) => {
    if (!q.trim()) return
    setSearchHistory(prev => {
      const filtered = prev.filter(h => h.toLowerCase() !== q.toLowerCase())
      const next = [q, ...filtered].slice(0, MAX_HISTORY_ITEMS)
      try { localStorage.setItem(SEARCH_HISTORY_KEY, JSON.stringify(next)) } catch {}
      return next
    })
  }, [])

  const removeFromHistory = (item: string) => {
    setSearchHistory(prev => {
      const next = prev.filter(h => h !== item)
      try { localStorage.setItem(SEARCH_HISTORY_KEY, JSON.stringify(next)) } catch {}
      return next
    })
  }

  // Cargar avatares de artistas
  useEffect(() => {
    if (!results.artists.length) { setArtistAvatars(new Map()); setFailedAvatars(new Set()); return }
    setFailedAvatars(new Set())
    const load = async () => {
      const map = new Map<string, string | null>()
      await Promise.all(
        results.artists.map(async artist => {
          const key = artist.name.toLowerCase().trim()
          const cached = getArtistAvatarCache().get(key)
          if (cached !== undefined) { map.set(artist.id, cached); return }
          try {
            const url = await navidromeApi.getArtistImage(artist.name)
            map.set(artist.id, url ?? null)
            setArtistAvatarCache(key, url ?? null)
          } catch {
            map.set(artist.id, null)
            setArtistAvatarCache(key, null)
          }
        })
      )
      setArtistAvatars(map)
    }
    load()
  }, [results.artists])

  // Búsqueda con debounce
  useEffect(() => {
    if (!query.trim()) {
      setResults({ artists: [], albums: [], songs: [] })
      return
    }
    const id = setTimeout(async () => {
      setIsSearching(true)
      try {
        const res = await navidromeApi.searchAll(query.trim(), 5, 5, 5)
        setResults(res)
      } catch {
        setResults({ artists: [], albums: [], songs: [] })
      } finally {
        setIsSearching(false)
      }
    }, 300)
    return () => clearTimeout(id)
  }, [query])

  const goArtist = (name: string) => {
    saveToHistory(query)
    navigate(`/artists/${encodeURIComponent(name)}`)
    setQuery('')
  }
  const goAlbum = (id: string) => {
    saveToHistory(query)
    navigate(`/albums/${id}`)
    setQuery('')
  }
  const playSong = (song: Song) => {
    saveToHistory(query)
    playerActions.playSong(song)
    setQuery('')
  }

  const hasResults =
    results.artists.length > 0 || results.albums.length > 0 || results.songs.length > 0
  const showHistory = !query.trim() && searchHistory.length > 0
  const showEmpty = !!query.trim() && !isSearching && !hasResults

  return (
    <div>
      {/* Título grande estilo iOS */}
      <h1 className="text-[34px] font-bold leading-tight text-gray-900 dark:text-white mb-4 px-1">
        Buscar
      </h1>

      {/* Search bar estilo UISearchBar nativa */}
      <div className="sticky top-0 pb-4 bg-gray-100 dark:bg-gray-900 z-10">
        <div className="relative">
          <MagnifyingGlassIcon className="absolute left-3 top-1/2 -translate-y-1/2 h-[17px] w-[17px] text-gray-500 dark:text-gray-400 pointer-events-none" />
          <input
            ref={inputRef}
            type="text"
            inputMode="search"
            enterKeyHint="search"
            autoCorrect="off"
            autoCapitalize="none"
            spellCheck={false}
            value={query}
            onChange={e => setQuery(e.target.value)}
            placeholder="Artistas, álbumes, canciones..."
            className="w-full pl-9 pr-9 py-[8px] bg-[rgba(118,118,128,0.12)] dark:bg-[rgba(118,118,128,0.24)] rounded-[10px] text-gray-900 dark:text-white placeholder-gray-500 dark:placeholder-gray-400 focus:outline-none text-[17px]"
          />
          {query && (
            <button
              onClick={() => { setQuery(''); inputRef.current?.focus() }}
              className="absolute right-2.5 top-1/2 -translate-y-1/2 text-gray-500 dark:text-gray-400"
              aria-label="Limpiar"
            >
              <XMarkIcon className="h-[18px] w-[18px]" />
            </button>
          )}
        </div>
      </div>

      {/* Historial */}
      {showHistory && (
        <div className="mb-6">
          <p className="text-xs font-semibold uppercase tracking-widest text-gray-500 dark:text-gray-400 mb-3">
            Búsquedas recientes
          </p>
          <div className="bg-white dark:bg-gray-900/40 rounded-2xl overflow-hidden border border-gray-200/80 dark:border-white/5 divide-y divide-gray-100/80 dark:divide-white/[0.04]">
            {searchHistory.map((item, i) => (
              <div key={i} className="flex items-center group">
                <button
                  onClick={() => setQuery(item)}
                  className="flex-1 flex items-center gap-3 px-4 py-3.5 text-left"
                >
                  <ClockIcon className="h-4 w-4 text-gray-400 flex-shrink-0" />
                  <span className="text-sm font-medium text-gray-900 dark:text-white truncate">{item}</span>
                </button>
                <button
                  onClick={() => removeFromHistory(item)}
                  className="pr-4 pl-2 py-3.5 opacity-0 group-hover:opacity-100 transition-opacity text-gray-400 hover:text-red-500"
                  aria-label="Eliminar"
                >
                  <TrashIcon className="h-4 w-4" />
                </button>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Buscando… */}
      {isSearching && (
        <div className="flex justify-center py-12">
          <div className="w-6 h-6 border-2 border-gray-300 dark:border-gray-600 border-t-blue-500 dark:border-t-blue-400 rounded-full animate-spin" />
        </div>
      )}

      {/* Sin resultados */}
      {showEmpty && (
        <div className="flex flex-col items-center py-16 text-gray-400 dark:text-gray-400">
          <MagnifyingGlassIcon className="w-14 h-14 mb-4 opacity-40" />
          <p className="text-base">Sin resultados para «{query}»</p>
        </div>
      )}

      {/* Resultados */}
      {!isSearching && hasResults && (
        <div className="space-y-7">
          {/* Artistas */}
          {results.artists.length > 0 && (
            <section>
              <p className="text-xs font-semibold uppercase tracking-widest text-gray-500 dark:text-gray-400 mb-3">
                Artistas
              </p>
              <div className="bg-white dark:bg-gray-900/40 rounded-2xl overflow-hidden border border-gray-200/80 dark:border-white/5 divide-y divide-gray-100/80 dark:divide-white/[0.04]">
                {results.artists.map(artist => {
                  const av = artistAvatars.get(artist.id)
                  const failed = failedAvatars.has(artist.id)
                  return (
                    <button
                      key={artist.id}
                      onClick={() => goArtist(artist.name)}
                      className="w-full flex items-center gap-4 px-4 py-3 text-left hover:bg-gray-50 dark:hover:bg-white/[0.06] transition-colors"
                    >
                      <div className="w-11 h-11 rounded-full overflow-hidden bg-gray-200 dark:bg-white/[0.08] flex-shrink-0 flex items-center justify-center text-gray-400">
                        {av && !failed ? (
                          <img src={av} alt={artist.name} className="w-full h-full object-cover" onError={() => setFailedAvatars(p => new Set(p).add(artist.id))} />
                        ) : (
                          <svg className="w-6 h-6" fill="currentColor" viewBox="0 0 24 24">
                            <path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z" />
                          </svg>
                        )}
                      </div>
                      <div className="flex-1 min-w-0">
                        <p className="font-semibold text-gray-900 dark:text-white truncate">{artist.name}</p>
                        <p className="text-xs text-gray-500 dark:text-gray-400">Artista</p>
                      </div>
                    </button>
                  )
                })}
              </div>
            </section>
          )}

          {/* Álbumes */}
          {results.albums.length > 0 && (
            <section>
              <p className="text-xs font-semibold uppercase tracking-widest text-gray-500 dark:text-gray-400 mb-3">
                Álbumes
              </p>
              <div className="bg-white dark:bg-gray-900/40 rounded-2xl overflow-hidden border border-gray-200/80 dark:border-white/5 divide-y divide-gray-100/80 dark:divide-white/[0.04]">
                {results.albums.map(album => (
                  <button
                    key={album.id}
                    onClick={() => goAlbum(album.id)}
                    className="w-full flex items-center gap-4 px-4 py-3 text-left hover:bg-gray-50 dark:hover:bg-white/[0.06] transition-colors"
                  >
                    <div className="w-11 h-11 rounded-lg overflow-hidden flex-shrink-0">
                      <AlbumCover coverArtId={album.coverArt} size={100} className="w-full h-full" />
                    </div>
                    <div className="flex-1 min-w-0">
                      <p className="font-semibold text-gray-900 dark:text-white truncate">{album.name}</p>
                      <p className="text-xs text-gray-500 dark:text-gray-400 truncate">{album.artist}</p>
                    </div>
                  </button>
                ))}
              </div>
            </section>
          )}

          {/* Canciones */}
          {results.songs.length > 0 && (
            <section>
              <p className="text-xs font-semibold uppercase tracking-widest text-gray-500 dark:text-gray-400 mb-3">
                Canciones
              </p>
              <div className="bg-white dark:bg-gray-900/40 rounded-2xl overflow-hidden border border-gray-200/80 dark:border-white/5 divide-y divide-gray-100/80 dark:divide-white/[0.04]">
                {results.songs.map(song => (
                  <button
                    key={song.id}
                    onClick={() => playSong(song)}
                    className="w-full flex items-center gap-4 px-4 py-3 text-left hover:bg-gray-50 dark:hover:bg-white/[0.06] transition-colors"
                  >
                    <div className="w-11 h-11 rounded-lg overflow-hidden flex-shrink-0">
                      <AlbumCover coverArtId={song.coverArt} size={100} className="w-full h-full" />
                    </div>
                    <div className="flex-1 min-w-0">
                      <p className="font-semibold text-gray-900 dark:text-white truncate">{song.title}</p>
                      <p className="text-xs text-gray-500 dark:text-gray-400 truncate">
                        {song.artist} · {song.album}
                      </p>
                    </div>
                  </button>
                ))}
              </div>
            </section>
          )}
        </div>
      )}
    </div>
  )
}
