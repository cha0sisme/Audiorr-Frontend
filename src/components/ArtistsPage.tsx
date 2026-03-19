import { useState, useEffect, useRef } from 'react'
import { navidromeApi, Artist } from '../services/navidromeApi'
import ArtistCard from './ArtistCard'
import Spinner from './Spinner'

interface ArtistWithCount {
  name: string
  albumCount: number
}

export default function ArtistsPage() {
  const [allArtists, setAllArtists] = useState<Artist[]>([])
  const [featuredArtists, setFeaturedArtists] = useState<ArtistWithCount[]>([])
  const [recentArtists, setRecentArtists] = useState<Artist[]>([])
  const [genreArtists, setGenreArtists] = useState<Artist[]>([])
  const [currentGenre, setCurrentGenre] = useState<string>('')
  const [loading, setLoading] = useState(true)
  const [showAllArtists, setShowAllArtists] = useState(false)
  const artistRefs = useRef<Map<string, HTMLDivElement>>(new Map())

  // Cargar todos los artistas
  useEffect(() => {
    const fetchAllArtists = async () => {
      try {
        setLoading(true)
        const artists = await navidromeApi.getArtists()
        setAllArtists(artists)
      } catch (error) {
        console.error('Error loading artists:', error)
      } finally {
        setLoading(false)
      }
    }

    fetchAllArtists()
  }, [])

  // Cargar artistas destacados
  useEffect(() => {
    const fetchFeaturedArtists = async () => {
      try {
        // Obtener álbumes más reproducidos
        const frequentAlbums = await navidromeApi.getFrequentAlbums(50)
        
        // Contar cuántos álbumes frecuentes tiene cada artista
        const artistFrequentCount = new Map<string, number>()
        frequentAlbums.forEach(album => {
          const count = artistFrequentCount.get(album.artist) || 0
          artistFrequentCount.set(album.artist, count + 1)
        })
        
        // Ordenar por frecuencia y tomar los top 12
        const topArtistNames = Array.from(artistFrequentCount.entries())
          .sort((a, b) => b[1] - a[1])
          .slice(0, 12)
          .map(([name]) => name)
        
        // Obtener todos los artistas para tener el conteo real de álbumes
        const allArtistsData = await navidromeApi.getArtists()
        const artistLookup = new Map<string, number>()
        allArtistsData.forEach(artist => {
          if (artist.albumCount !== undefined) {
            artistLookup.set(artist.name, artist.albumCount)
          }
        })
        
        // Construir la lista de artistas destacados con el conteo REAL de álbumes
        const featured = topArtistNames.map(name => ({
          name,
          albumCount: artistLookup.get(name) || 0,
        }))
        
        setFeaturedArtists(featured)
      } catch (error) {
        console.error('Error loading featured artists:', error)
      }
    }

    fetchFeaturedArtists()
  }, [])

  // Cargar artistas con lanzamientos recientes
  useEffect(() => {
    const fetchRecentArtists = async () => {
      try {
        const recentReleases = await navidromeApi.getRecentReleases(6, 30)
        
        const recentArtistNames = new Set<string>()
        recentReleases.forEach(album => {
          if (!recentArtistNames.has(album.artist)) {
            recentArtistNames.add(album.artist)
          }
        })
        
        const recent = Array.from(recentArtistNames)
          .slice(0, 12)
          .map(name => ({ name }))
        
        setRecentArtists(recent)
      } catch (error) {
        console.error('Error loading recent artists:', error)
      }
    }

    fetchRecentArtists()
  }, [])

  // Cargar artistas por género aleatorio
  useEffect(() => {
    const fetchGenreArtists = async () => {
      try {
        const latestAlbums = await navidromeApi.getLatestAlbums(100)
        
        const genresSet = new Set<string>()
        latestAlbums.forEach(album => {
          if (album.genre) {
            album.genre.split(',').forEach(g => {
              const trimmed = g.trim()
              if (trimmed) genresSet.add(trimmed)
            })
          }
        })

        const genres = Array.from(genresSet)
        if (genres.length === 0) return

        const randomGenre = genres[Math.floor(Math.random() * genres.length)]
        setCurrentGenre(randomGenre)

        const genreAlbums = await navidromeApi.getAlbumsByGenre(randomGenre, 0, 50)
        
        const genreArtistNames = new Set<string>()
        genreAlbums.forEach(album => {
          if (!genreArtistNames.has(album.artist)) {
            genreArtistNames.add(album.artist)
          }
        })

        const genreArtistsList = Array.from(genreArtistNames)
          .slice(0, 12)
          .map(name => ({ name }))
        
        setGenreArtists(genreArtistsList)
      } catch (error) {
        console.error('Error loading genre artists:', error)
      }
    }

    fetchGenreArtists()
  }, [])

  const handleChangeGenre = async () => {
    try {
      const latestAlbums = await navidromeApi.getLatestAlbums(100)
      
      const genresSet = new Set<string>()
      latestAlbums.forEach(album => {
        if (album.genre) {
          album.genre.split(',').forEach(g => {
            const trimmed = g.trim()
            if (trimmed) genresSet.add(trimmed)
          })
        }
      })

      const genres = Array.from(genresSet).filter(g => g !== currentGenre)
      if (genres.length === 0) return

      const randomGenre = genres[Math.floor(Math.random() * genres.length)]
      setCurrentGenre(randomGenre)

      const genreAlbums = await navidromeApi.getAlbumsByGenre(randomGenre, 0, 50)
      
      const genreArtistNames = new Set<string>()
      genreAlbums.forEach(album => {
        if (!genreArtistNames.has(album.artist)) {
          genreArtistNames.add(album.artist)
        }
      })

      const genreArtistsList = Array.from(genreArtistNames)
        .slice(0, 12)
        .map(name => ({ name }))
      
      setGenreArtists(genreArtistsList)
    } catch (error) {
      console.error('Error changing genre:', error)
    }
  }

  const scrollToLetter = (letter: string) => {
    const ref = artistRefs.current.get(letter)
    if (ref) {
      ref.scrollIntoView({ behavior: 'smooth', block: 'start' })
    }
  }

  if (loading) {
    return (
      <div className="flex justify-center items-center h-64">
        <Spinner size="lg" />
      </div>
    )
  }

  // Agrupar artistas por letra (para la vista completa)
  const groupedArtists = new Map<string, Artist[]>()
  allArtists.forEach(artist => {
    const firstLetter = artist.name.charAt(0).toUpperCase()
    const letter = /[A-Z0-9]/.test(firstLetter) ? firstLetter : '#'

    if (!groupedArtists.has(letter)) {
      groupedArtists.set(letter, [])
    }
    groupedArtists.get(letter)!.push(artist)
  })

  const letters = Array.from(groupedArtists.keys()).sort((a, b) => {
    if (a === '#') return 1
    if (b === '#') return -1
    return a.localeCompare(b)
  })

  return (
    <div className="space-y-12">
      <div>
        <h1 className="text-3xl md:text-4xl font-bold mb-2 text-gray-900 dark:text-white">
          Artistas
        </h1>
        <p className="text-gray-600 dark:text-gray-400">
          Descubre y explora tu colección de artistas
        </p>
      </div>

      {/* Sección: Artistas destacados */}
      {featuredArtists.length > 0 && (
        <section>
          <div className="flex items-center justify-between mb-6">
            <div>
              <h2 className="text-2xl font-bold text-gray-900 dark:text-white">
                Más escuchados
              </h2>
              <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
                Tus artistas con más reproducciones
              </p>
            </div>
          </div>
          
          <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 gap-6">
            {featuredArtists.map(artist => (
              <ArtistCard
                key={artist.name}
                name={artist.name}
                albumCount={artist.albumCount}
              />
            ))}
          </div>
        </section>
      )}

      {/* Sección: Lanzamientos recientes */}
      {recentArtists.length > 0 && (
        <section>
          <div className="flex items-center justify-between mb-6">
            <div>
              <h2 className="text-2xl font-bold text-gray-900 dark:text-white">
                Nuevos descubrimientos
              </h2>
              <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
                Artistas con lanzamientos recientes
              </p>
            </div>
          </div>
          
          <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 gap-6">
            {recentArtists.map(artist => (
              <ArtistCard
                key={artist.name}
                name={artist.name}
              />
            ))}
          </div>
        </section>
      )}

      {/* Sección: Por género */}
      {genreArtists.length > 0 && currentGenre && (
        <section>
          <div className="flex items-center justify-between mb-6">
            <div>
              <h2 className="text-2xl font-bold text-gray-900 dark:text-white">
                {currentGenre}
              </h2>
              <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
                Artistas de este género
              </p>
            </div>
            <button
              onClick={handleChangeGenre}
              className="text-sm text-blue-500 hover:text-blue-600 dark:text-blue-400 dark:hover:text-blue-300 font-medium transition-colors"
            >
              Cambiar género →
            </button>
          </div>
          
          <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 gap-6">
            {genreArtists.map(artist => (
              <ArtistCard
                key={artist.name}
                name={artist.name}
              />
            ))}
          </div>
        </section>
      )}

      {/* Sección: Explorar todos */}
      <section>
        <div className="border-t border-gray-200 dark:border-gray-800 pt-8">
          <button
            onClick={() => setShowAllArtists(!showAllArtists)}
            className="flex items-center gap-2 text-xl font-bold text-gray-900 dark:text-white hover:text-blue-500 dark:hover:text-blue-400 transition-colors mb-6"
          >
            <span>Explorar todos los artistas</span>
            <span className="text-sm text-gray-500 dark:text-gray-400">
              ({allArtists.length})
            </span>
            <svg 
              className={`w-5 h-5 transition-transform ${showAllArtists ? 'rotate-90' : ''}`}
              fill="none" 
              stroke="currentColor" 
              viewBox="0 0 24 24"
            >
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" />
            </svg>
          </button>

          {showAllArtists && (
            <>
              {/* Barra de navegación de letras */}
              <div className="mb-8 sticky top-0 z-20 bg-white/80 dark:bg-gray-900/80 backdrop-blur-sm border-y border-gray-200 dark:border-gray-800 py-3">
                <div className="flex gap-1 justify-center overflow-x-auto scrollbar-hide px-4">
                  {letters.map(letter => (
                    <button
                      key={letter}
                      onClick={() => scrollToLetter(letter)}
                      className="px-3 py-1 text-xs font-medium text-gray-500 dark:text-gray-500 hover:text-gray-900 dark:hover:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800 rounded transition-colors whitespace-nowrap"
                    >
                      {letter}
                    </button>
                  ))}
                </div>
              </div>

              {/* Lista de artistas agrupados por letra */}
              <div>
                {letters.map(letter => {
                  const letterArtists = groupedArtists.get(letter) || []
                  return (
                    <div key={letter} ref={el => artistRefs.current.set(letter, el!)}>
                      <p className="text-lg font-semibold mb-4 text-gray-700 dark:text-gray-300 sticky top-16 bg-white/90 dark:bg-gray-900/90 backdrop-blur-sm py-2 px-1 border-b border-gray-200 dark:border-gray-800 z-10">
                        {letter}
                      </p>
                      <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 xl:grid-cols-8 gap-x-6 gap-y-8 mb-8">
                        {letterArtists.map(artist => (
                          <ArtistCard
                            key={artist.id}
                            name={artist.name}
                          />
                        ))}
                      </div>
                    </div>
                  )
                })}
              </div>
            </>
          )}
        </div>
      </section>
    </div>
  )
}
