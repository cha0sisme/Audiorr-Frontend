import { useState, useEffect, useRef, useMemo, useCallback } from 'react'
import { useParams } from 'react-router-dom'
import { navidromeApi, Album } from '../services/navidromeApi'
import Spinner from './Spinner'
import AlbumCard from './AlbumCard'

type SortOption = 'name' | 'artist' | 'year'

export default function GenreDetail() {
  const { genreName } = useParams<{ genreName: string }>()
  const [albums, setAlbums] = useState<Album[]>([])
  const [loading, setLoading] = useState(true)
  const [hasMore, setHasMore] = useState(true)
  const [totalCount, setTotalCount] = useState<number | null>(null)
  const [offset, setOffset] = useState(0)
  const [sortBy, setSortBy] = useState<SortOption>('name')
  const [sortAscending, setSortAscending] = useState(true)
  const observerTarget = useRef<HTMLDivElement>(null)
  const isFetching = useRef(false)
  const decodedGenreName = genreName ? decodeURIComponent(genreName) : ''

  const loadAlbums = useCallback(async () => {
    if (isFetching.current || !hasMore || !decodedGenreName) return

    isFetching.current = true
    setLoading(true)
    try {
      const currentOffset = offset
      const newAlbums = await navidromeApi.getAlbumsByGenre(decodedGenreName, currentOffset, 50)
      if (newAlbums.length > 0) {
        setAlbums(prevAlbums => {
          const updated = [...prevAlbums, ...newAlbums]
          // Si tenemos el total y ya cargamos todos, marcar hasMore como false
          if (totalCount !== null) {
            const uniqueIds = new Set(updated.map(a => a.id))
            if (uniqueIds.size >= totalCount) {
              setHasMore(false)
            }
          }
          return updated
        })
        setOffset(currentOffset + newAlbums.length)
      } else {
        setHasMore(false)
      }
    } catch (error) {
      console.error(`Failed to fetch albums for genre ${decodedGenreName}`, error)
      setHasMore(false)
    } finally {
      setLoading(false)
      isFetching.current = false
    }
  }, [decodedGenreName, offset, hasMore, totalCount])

  useEffect(() => {
    // Resetear estado cuando cambia el género
    setAlbums([])
    setOffset(0)
    setHasMore(true)
    setTotalCount(null)
    isFetching.current = false

    // Carga inicial y conteo total
    if (decodedGenreName) {
      const initialLoad = async () => {
        if (isFetching.current) return
        isFetching.current = true
        setLoading(true)
        try {
          // Cargar primeros 50 álbumes para mostrar
          const newAlbums = await navidromeApi.getAlbumsByGenre(decodedGenreName, 0, 50)
          if (newAlbums.length > 0) {
            setAlbums(newAlbums)
            setOffset(newAlbums.length)
          } else {
            setHasMore(false)
            setTotalCount(0)
          }

          // Obtener el total real haciendo una petición grande
          // Usamos un tamaño grande para obtener todos los álbumes y contar
          const allAlbums = await navidromeApi.getAlbumsByGenre(decodedGenreName, 0, 10000)
          setTotalCount(allAlbums.length)

          // Si hay menos de 50 álbumes, ya los tenemos todos
          if (allAlbums.length <= 50) {
            setHasMore(false)
            setAlbums(allAlbums)
            setOffset(allAlbums.length)
          }
        } catch (error) {
          console.error(`Failed to fetch albums for genre ${decodedGenreName}`, error)
          setHasMore(false)
        } finally {
          setLoading(false)
          isFetching.current = false
        }
      }
      initialLoad()
    }
  }, [decodedGenreName])

  useEffect(() => {
    const observer = new IntersectionObserver(
      entries => {
        if (entries[0].isIntersecting && hasMore && !loading) {
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
  }, [loadAlbums, hasMore, loading])

  const uniqueAlbums = useMemo(() => {
    const seen = new Set<string>()
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
      <div className="flex justify-center items-center h-full">
        <Spinner />
      </div>
    )
  }

  return (
    <div className="p-4 sm:p-6">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-6">
        <h1 className="text-3xl font-bold text-gray-900 dark:text-white flex items-center gap-3">
          {decodedGenreName}
          {!loading && (
            <span className="text-sm font-medium bg-gray-200 dark:bg-gray-700 text-gray-800 dark:text-gray-300 rounded-full px-2.5 py-1 leading-none flex items-center">
              {totalCount !== null
                ? totalCount
                : hasMore
                  ? `${uniqueAlbums.length}+`
                  : uniqueAlbums.length}
            </span>
          )}
        </h1>

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
      <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-6">
        {sortedAlbums.map(album => (
          <AlbumCard key={album.id} album={album} />
        ))}
      </div>
      <div ref={observerTarget} style={{ height: '1px' }} />
      {loading && hasMore && (
        <div className="text-center mt-4">
          <Spinner />
          <p className="text-gray-600 dark:text-gray-400 mt-2">Cargando más álbumes...</p>
        </div>
      )}
    </div>
  )
}
