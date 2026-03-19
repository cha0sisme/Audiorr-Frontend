import { useState, useEffect } from 'react'
import { Link } from 'react-router-dom'
import { navidromeApi } from '../services/navidromeApi'
import Spinner from './Spinner'

export default function GenresPage() {
  const [genres, setGenres] = useState<string[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const fetchGenres = async () => {
      try {
        setLoading(true)
        const genreList = await navidromeApi.getGenres()
        setGenres(genreList)
      } catch (error) {
        console.error('Failed to fetch genres', error)
      } finally {
        setLoading(false)
      }
    }

    fetchGenres()
  }, [])

  if (loading) {
    return (
      <div className="flex justify-center items-center h-full">
        <Spinner />
      </div>
    )
  }

  return (
    <div className="p-4 sm:p-6">
      <h1 className="text-3xl font-bold mb-6 text-gray-900 dark:text-white">Géneros</h1>
      <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4">
        {genres.map(genre => (
          <Link
            to={`/genre/${encodeURIComponent(genre)}`}
            key={genre}
            className="block p-4 rounded-lg bg-gray-100 dark:bg-gray-800 hover:bg-gray-200 dark:hover:bg-gray-700 transition-colors text-center"
          >
            <span className="font-semibold text-gray-800 dark:text-gray-200">{genre}</span>
          </Link>
        ))}
      </div>
    </div>
  )
}
