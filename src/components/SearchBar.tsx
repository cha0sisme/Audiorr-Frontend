import { useState, useEffect, useRef, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { navidromeApi, Album, Song } from '../services/navidromeApi'
import { MagnifyingGlassIcon, XMarkIcon, TrashIcon, ClockIcon } from '@heroicons/react/24/outline'
import { usePlayerActions } from '../contexts/PlayerContext'
import { getArtistAvatarCache, setArtistAvatarCache } from '../utils/artistAvatarCache'

interface SearchResult {
  artists: Array<{ id: string; name: string }>
  albums: Album[]
  songs: Song[]
}

const SEARCH_HISTORY_KEY = 'audiorr_search_history'
const MAX_HISTORY_ITEMS = 5

export default function SearchBar() {
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<SearchResult>({ artists: [], albums: [], songs: [] })
  const [isOpen, setIsOpen] = useState(false)
  const [isSearching, setIsSearching] = useState(false)
  const [showHistory, setShowHistory] = useState(false)
  const [searchHistory, setSearchHistory] = useState<string[]>([])
  const [artistAvatars, setArtistAvatars] = useState<Map<string, string | null>>(new Map())
  const [failedAvatars, setFailedAvatars] = useState<Set<string>>(new Set())
  const searchRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const navigate = useNavigate()
  const playerActions = usePlayerActions()

  // Cargar historial desde localStorage
  useEffect(() => {
    try {
      const stored = localStorage.getItem(SEARCH_HISTORY_KEY)
      if (stored) {
        const history = JSON.parse(stored) as string[]
        setSearchHistory(history.slice(0, MAX_HISTORY_ITEMS))
      }
    } catch (error) {
      console.error('Failed to load search history:', error)
    }
  }, [])

  // Guardar en historial
  const saveToHistory = useCallback((searchQuery: string) => {
    if (!searchQuery.trim()) return

    setSearchHistory(prev => {
      const filtered = prev.filter(item => item.toLowerCase() !== searchQuery.toLowerCase())
      const newHistory = [searchQuery, ...filtered].slice(0, MAX_HISTORY_ITEMS)
      try {
        localStorage.setItem(SEARCH_HISTORY_KEY, JSON.stringify(newHistory))
      } catch (error) {
        console.error('Failed to save search history:', error)
      }
      return newHistory
    })
  }, [])

  // Eliminar del historial
  const removeFromHistory = useCallback(
    (searchQuery: string, event: React.MouseEvent | React.KeyboardEvent) => {
      event.stopPropagation()
      event.preventDefault()
      setSearchHistory(prev => {
        const newHistory = prev.filter(item => item !== searchQuery)
        try {
          localStorage.setItem(SEARCH_HISTORY_KEY, JSON.stringify(newHistory))
        } catch (error) {
          console.error('Failed to update search history:', error)
        }
        return newHistory
      })
    },
    []
  )

  // Cargar avatares de artistas
  useEffect(() => {
    if (results.artists.length === 0) {
      setArtistAvatars(new Map())
      setFailedAvatars(new Set())
      return
    }

    // Limpiar avatares fallidos cuando cambian los resultados
    setFailedAvatars(new Set())

    const loadAvatars = async () => {
      const avatarMap = new Map<string, string | null>()
      const avatarPromises = results.artists.map(async artist => {
        const cacheKey = artist.name.toLowerCase().trim()
        const cached = getArtistAvatarCache().get(cacheKey)

        if (cached !== undefined) {
          avatarMap.set(artist.id, cached)
          return
        }

        try {
          // Obtener avatar directamente (el backend maneja LRU, SQLite y Last.fm)
          const imageUrl = await navidromeApi.getArtistImage(artist.name)
          
          if (imageUrl) {
            avatarMap.set(artist.id, imageUrl)
            setArtistAvatarCache(cacheKey, imageUrl)
          } else {
            avatarMap.set(artist.id, null)
            setArtistAvatarCache(cacheKey, null)
          }
        } catch (error) {
          console.error(`Failed to load avatar for ${artist.name}:`, error)
          avatarMap.set(artist.id, null)
          setArtistAvatarCache(cacheKey, null)
        }
      })

      await Promise.all(avatarPromises)
      setArtistAvatars(avatarMap)
    }

    loadAvatars()
  }, [results.artists])

  // Cerrar dropdown al hacer clic fuera
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (searchRef.current && !searchRef.current.contains(event.target as Node)) {
        setIsOpen(false)
        setShowHistory(false)
      }
    }

    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [])

  // Buscar con debounce
  useEffect(() => {
    if (!query.trim()) {
      setResults({ artists: [], albums: [], songs: [] })
      setIsOpen(false)
      // Solo mostrar historial si el input tiene foco
      if (document.activeElement === inputRef.current) {
        setShowHistory(true)
      } else {
        setShowHistory(false)
      }
      return
    }

    setShowHistory(false)

    const timeoutId = setTimeout(async () => {
      setIsSearching(true)
      try {
        const searchResults = await navidromeApi.searchAll(query.trim(), 5, 5, 5)
        setResults(searchResults)
        setIsOpen(true)
      } catch (error) {
        console.error('Search failed:', error)
        setResults({ artists: [], albums: [], songs: [] })
      } finally {
        setIsSearching(false)
      }
    }, 300)

    return () => clearTimeout(timeoutId)
  }, [query])

  const hasResults =
    results.artists.length > 0 || results.albums.length > 0 || results.songs.length > 0

  const handleClear = () => {
    setQuery('')
    setResults({ artists: [], albums: [], songs: [] })
    setIsOpen(false)
    // Solo mostrar historial si el input mantiene el foco
    if (document.activeElement === inputRef.current) {
      setShowHistory(true)
    } else {
      setShowHistory(false)
    }
    inputRef.current?.focus()
  }

  const handleFocus = () => {
    if (!query.trim()) {
      setShowHistory(true)
    } else if (hasResults) {
      setIsOpen(true)
    }
  }

  const handleHistoryClick = (historyQuery: string) => {
    setQuery(historyQuery)
    setShowHistory(false)
    inputRef.current?.blur()
  }

  const handleArtistClick = (artistName: string) => {
    saveToHistory(query.trim())
    inputRef.current?.blur()
    setIsOpen(false)
    setShowHistory(false)
    setQuery('')
    navigate(`/artists/${encodeURIComponent(artistName)}`)
  }

  const handleAlbumClick = (albumId: string) => {
    saveToHistory(query.trim())
    inputRef.current?.blur()
    setIsOpen(false)
    setShowHistory(false)
    setQuery('')
    navigate(`/albums/${albumId}`)
  }

  const handleSongClick = (song: Song) => {
    saveToHistory(query.trim())
    inputRef.current?.blur()
    setIsOpen(false)
    setShowHistory(false)
    setQuery('')
    playerActions.playSong(song)
  }

  return (
    <div ref={searchRef} className="relative w-full">
      <div className="relative">
        <MagnifyingGlassIcon className="absolute left-3 top-1/2 transform -translate-y-1/2 h-5 w-5 text-gray-400 dark:text-gray-500" />
        <input
          ref={inputRef}
          type="text"
          value={query}
          onChange={e => setQuery(e.target.value)}
          onFocus={handleFocus}
          placeholder="Buscar artistas, álbumes, canciones..."
          className="w-full pl-10 pr-10 py-2 bg-white dark:bg-white/[0.07] border border-gray-300/80 dark:border-white/10 rounded-2xl text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500/50 dark:focus:ring-white/20 focus:border-transparent transition-all"
        />
        {query && (
          <button
            onClick={handleClear}
            className="absolute right-3 top-1/2 transform -translate-y-1/2 text-gray-400 dark:text-gray-500 hover:text-gray-600 dark:hover:text-gray-300 transition-colors"
            aria-label="Limpiar búsqueda"
          >
            <XMarkIcon className="h-5 w-5" />
          </button>
        )}
      </div>

      {/* Dropdown de historial */}
      {showHistory && searchHistory.length > 0 && !query.trim() && (
        <div
          className="absolute top-full mt-2 w-full bg-white dark:bg-gray-900/95 border border-gray-200/50 dark:border-white/[0.08] rounded-2xl shadow-xl z-50 max-h-96 overflow-y-auto backdrop-blur-md"
          style={{ animation: 'fadeIn 0.2s ease-in-out forwards' }}
        >
          <div className="p-2">
            <div className="px-3 py-2 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide flex items-center gap-2">
              <ClockIcon className="h-4 w-4" />
              Búsquedas recientes
            </div>
            {searchHistory.map((historyItem, index) => (
              <div
                key={index}
                className="w-full px-3 py-2 hover:bg-gray-50 dark:hover:bg-white/[0.06] rounded-xl transition-colors flex items-center gap-3 group"
              >
                <button
                  onClick={() => handleHistoryClick(historyItem)}
                  className="flex-1 text-left flex items-center gap-3 min-w-0"
                >
                  <ClockIcon className="h-4 w-4 text-gray-400 dark:text-gray-500 flex-shrink-0" />
                  <div className="flex-1 min-w-0">
                    <div className="text-sm font-medium text-gray-900 dark:text-white truncate">
                      {historyItem}
                    </div>
                  </div>
                </button>
                <div
                  onClick={e => removeFromHistory(historyItem, e)}
                  className="opacity-0 group-hover:opacity-100 p-1 text-gray-400 dark:text-gray-500 hover:text-red-500 dark:hover:text-red-400 transition-opacity cursor-pointer"
                  role="button"
                  tabIndex={0}
                  onKeyDown={e => {
                    if (e.key === 'Enter' || e.key === ' ') {
                      removeFromHistory(historyItem, e)
                    }
                  }}
                  aria-label="Eliminar búsqueda"
                >
                  <TrashIcon className="h-4 w-4" />
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Dropdown de resultados */}
      {isOpen && (hasResults || isSearching) && (
        <div
          className="absolute top-full mt-2 w-full bg-white dark:bg-gray-900/95 border border-gray-200/50 dark:border-white/[0.08] rounded-2xl shadow-xl z-50 max-h-96 overflow-y-auto backdrop-blur-md"
          style={{ animation: 'fadeIn 0.2s ease-in-out forwards' }}
        >
          {isSearching ? (
            <div className="p-4 text-center text-gray-500 dark:text-gray-400">Buscando...</div>
          ) : (
            <>
              {/* Artistas */}
              {results.artists.length > 0 && (
                <div className="p-2">
                  <div className="px-3 py-2 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide">
                    Artistas
                  </div>
                  {results.artists.map(artist => {
                    const avatarUrl = artistAvatars.get(artist.id)
                    const hasFailed = failedAvatars.has(artist.id)
                    const shouldShowImage = avatarUrl && !hasFailed
                    return (
                      <button
                        key={artist.id}
                        onClick={() => handleArtistClick(artist.name)}
                        onPointerDown={() => { navidromeApi.getArtistAlbums(artist.name).catch(() => {}); navidromeApi.getArtistSongs(artist.name, 10).catch(() => {}) }}
                        className="w-full px-3 py-2 text-left hover:bg-gray-50 dark:hover:bg-white/[0.06] rounded-xl transition-colors flex items-center gap-3 group"
                      >
                        <div className="w-10 h-10 rounded-full bg-gray-200 dark:bg-white/[0.08] flex items-center justify-center text-gray-600 dark:text-gray-400 group-hover:bg-gray-300 dark:group-hover:bg-white/[0.12] transition-colors overflow-hidden flex-shrink-0">
                          {shouldShowImage ? (
                            <img
                              src={avatarUrl}
                              alt={artist.name}
                              className="w-full h-full object-cover"
                              onError={() => {
                                setFailedAvatars(prev => new Set(prev).add(artist.id))
                              }}
                            />
                          ) : (
                            <svg className="w-6 h-6" fill="currentColor" viewBox="0 0 24 24">
                              <path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z" />
                            </svg>
                          )}
                        </div>
                        <div className="flex-1 min-w-0">
                          <div className="text-sm font-medium text-gray-900 dark:text-white truncate">
                            {artist.name}
                          </div>
                          <div className="text-xs text-gray-500 dark:text-gray-400">Artista</div>
                        </div>
                      </button>
                    )
                  })}
                </div>
              )}

              {/* Álbumes */}
              {results.albums.length > 0 && (
                <div className="p-2 border-t border-gray-100/80 dark:border-white/[0.05]">
                  <div className="px-3 py-2 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide">
                    Álbumes
                  </div>
                  {results.albums.map(album => (
                    <button
                      key={album.id}
                      onClick={() => handleAlbumClick(album.id)}
                      className="w-full px-3 py-2 text-left hover:bg-gray-50 dark:hover:bg-white/[0.06] rounded-xl transition-colors flex items-center gap-3 group"
                    >
                      <div className="w-10 h-10 rounded bg-gray-200 dark:bg-white/[0.08] flex-shrink-0 overflow-hidden">
                        {album.coverArt ? (
                          <img
                            src={navidromeApi.getCoverUrl(album.coverArt)}
                            alt={album.name}
                            className="w-full h-full object-cover"
                          />
                        ) : (
                          <div className="w-full h-full flex items-center justify-center text-gray-400 dark:text-gray-500">
                            <svg className="w-6 h-6" fill="currentColor" viewBox="0 0 24 24">
                              <path d="M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z" />
                            </svg>
                          </div>
                        )}
                      </div>
                      <div className="flex-1 min-w-0">
                        <div className="text-sm font-medium text-gray-900 dark:text-white truncate">
                          {album.name}
                        </div>
                        <div className="text-xs text-gray-500 dark:text-gray-400 truncate">
                          {album.artist}
                        </div>
                      </div>
                      <div className="text-xs text-gray-400 dark:text-gray-500 px-2 py-1 bg-gray-100 dark:bg-white/[0.06] rounded">
                        Álbum
                      </div>
                    </button>
                  ))}
                </div>
              )}

              {/* Canciones */}
              {results.songs.length > 0 && (
                <div className="p-2 border-t border-gray-100/80 dark:border-white/[0.05]">
                  <div className="px-3 py-2 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide">
                    Canciones
                  </div>
                  {results.songs.map(song => (
                    <button
                      key={song.id}
                      onClick={() => handleSongClick(song)}
                      className="w-full px-3 py-2 text-left hover:bg-gray-50 dark:hover:bg-white/[0.06] rounded-xl transition-colors flex items-center gap-3 group"
                    >
                      <div className="w-10 h-10 rounded bg-gray-200 dark:bg-white/[0.08] flex-shrink-0 overflow-hidden">
                        {song.coverArt ? (
                          <img
                            src={navidromeApi.getCoverUrl(song.coverArt)}
                            alt={song.album}
                            className="w-full h-full object-cover"
                          />
                        ) : (
                          <div className="w-full h-full flex items-center justify-center text-gray-400 dark:text-gray-500">
                            <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
                              <path d="M8 5v14l11-7z" />
                            </svg>
                          </div>
                        )}
                      </div>
                      <div className="flex-1 min-w-0">
                        <div className="text-sm font-medium text-gray-900 dark:text-white truncate">
                          {song.title}
                        </div>
                        <div className="text-xs text-gray-500 dark:text-gray-400 truncate">
                          {song.artist} • {song.album}
                        </div>
                      </div>
                      <div className="text-xs text-gray-400 dark:text-gray-500 px-2 py-1 bg-gray-100 dark:bg-white/[0.06] rounded">
                        Canción
                      </div>
                    </button>
                  ))}
                </div>
              )}

              {!hasResults && !isSearching && (
                <div className="p-4 text-center text-gray-500 dark:text-gray-400">
                  No se encontraron resultados
                </div>
              )}
            </>
          )}
        </div>
      )}
    </div>
  )
}
