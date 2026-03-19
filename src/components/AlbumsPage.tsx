import { useState, useEffect, useRef, useMemo, useCallback } from 'react'
import { navidromeApi, Album } from '../services/navidromeApi'
import Spinner from './Spinner'
import AlbumCard from './AlbumCard'

type SortOption = 'name' | 'artist' | 'year'

export default function AlbumsPage() {
  const [albums, setAlbums] = useState<Album[]>([])
  const [loading, setLoading] = useState(true)
  const [hasMore, setHasMore] = useState(true)
  const [offset, setOffset] = useState(0)
  const [sortBy, setSortBy] = useState<SortOption>('name')
  const [sortAscending, setSortAscending] = useState(true)
  const observerTarget = useRef(null)
  const isFetching = useRef(false)

  const loadAlbums = useCallback(async () => {
    if (isFetching.current || !hasMore) return

    isFetching.current = true
    setLoading(true)
    try {
      const newAlbums = await navidromeApi.getAlbums(offset, 50)
      if (newAlbums.length > 0) {
        setAlbums(prevAlbums => [...prevAlbums, ...newAlbums])
        setOffset(prevOffset => prevOffset + newAlbums.length)
      } else {
        setHasMore(false)
      }
    } catch (error) {
      console.error('Failed to fetch albums', error)
    } finally {
      setLoading(false)
      isFetching.current = false
    }
  }, [offset, hasMore])

  useEffect(() => {
    // Carga inicial
    loadAlbums()
  }, []) // Solo se ejecuta una vez

  useEffect(() => {
    const observer = new IntersectionObserver(
      entries => {
        if (entries[0].isIntersecting) {
          loadAlbums()
        }
      },
      { threshold: 1.0 }
    )

    const currentTarget = observerTarget.current
    if (currentTarget) {
      observer.observe(currentTarget)
    }

    return () => {
      if (currentTarget) {
        observer.unobserve(currentTarget)
      }
    }
  }, [loadAlbums])

  const uniqueAlbums = useMemo(() => {
    const seen = new Set()
    return albums.filter(album => {
      const duplicate = seen.has(album.id)
      seen.add(album.id)
      return !duplicate
    })
  }, [albums])

  const sortedAlbums = useMemo(() => {
    const sorted = [...uniqueAlbums]

    sorted.sort((a, b) => {
      let comparison = 0

      switch (sortBy) {
        case 'name':
          comparison = a.name.localeCompare(b.name, undefined, { sensitivity: 'base' })
          break
        case 'artist':
          comparison = a.artist.localeCompare(b.artist, undefined, { sensitivity: 'base' })
          break
        case 'year': {
          const yearA = a.year || 0
          const yearB = b.year || 0
          comparison = yearA - yearB
          break
        }
      }

      return sortAscending ? comparison : -comparison
    })

    return sorted
  }, [uniqueAlbums, sortBy, sortAscending])

  if (loading && albums.length === 0) {
    return (
      <div className="flex justify-center items-center h-64">
        <Spinner size="lg" />
      </div>
    )
  }

  return (
    <div>
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-6">
        <h1 className="text-3xl md:text-4xl font-bold text-gray-900 dark:text-white">Álbumes</h1>
        
        <div className="flex items-center gap-2">
          <label className="text-sm text-gray-600 dark:text-gray-400">Ordenar por:</label>
          <select
            value={sortBy}
            onChange={e => setSortBy(e.target.value as SortOption)}
            className="px-3 py-1.5 text-sm border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:outline-none focus:ring-2 focus:ring-blue-500 dark:focus:ring-blue-400"
          >
            <option value="name">Nombre</option>
            <option value="artist">Artista</option>
            <option value="year">Año</option>
          </select>
          <button
            onClick={() => setSortAscending(!sortAscending)}
            className="p-1.5 rounded-md hover:bg-gray-200 dark:hover:bg-gray-700 text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white transition-colors"
            title={sortAscending ? 'Ordenar descendente' : 'Ordenar ascendente'}
            aria-label={sortAscending ? 'Ordenar descendente' : 'Ordenar ascendente'}
          >
            {sortAscending ? (
              <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M5 15l7-7 7 7"
                />
              </svg>
            ) : (
              <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M19 9l-7 7-7-7"
                />
              </svg>
            )}
          </button>
        </div>
      </div>

      <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-x-6 gap-y-8">
        {sortedAlbums.map(album => (
          <AlbumCard key={album.id} album={album} showPlayButton={true} />
        ))}
      </div>
      <div ref={observerTarget} style={{ height: '1px' }} />
      {loading && hasMore && <div className="text-center mt-4">Cargando más...</div>}
      {!hasMore && <div className="text-center mt-4 text-gray-500">No hay más álbumes.</div>}
    </div>
  )
}
