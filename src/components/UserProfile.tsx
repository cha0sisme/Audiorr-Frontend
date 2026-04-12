import { useState, useEffect } from 'react'
import { useParams, useNavigate, Link } from 'react-router-dom'
import { navidromeApi, type Playlist } from '../services/navidromeApi'
import { MusicalNoteIcon, ClockIcon } from '@heroicons/react/24/outline'
import { Capacitor } from '@capacitor/core'
import { backendApi } from '../services/backendApi'
import { PlaylistCover } from './PlaylistCover'
import UniversalCover from './UniversalCover'
import PageHero from './PageHero'
import { getColorForUsername, getInitial } from '../utils/userUtils'

const isNativeUser = Capacitor.isNativePlatform()

function UserProfileSkeleton() {
  return (
    <div className="animate-pulse">
      {/* Hero */}
      <div
        className="relative overflow-hidden rounded-none md:rounded-3xl bg-gray-200 dark:bg-gray-800/60 flex flex-col md:flex-row items-center md:items-end gap-3 md:gap-6 px-5 md:px-8 lg:px-10 pb-9"
        style={{ minHeight: 340, paddingTop: isNativeUser ? 'calc(env(safe-area-inset-top) + 24px)' : '3.5rem' }}
      >
        <div className="w-[148px] h-[148px] md:w-[200px] md:h-[200px] rounded-full bg-gray-300 dark:bg-white/10 flex-shrink-0" />
        <div className="flex-1 min-w-0 text-center md:text-left space-y-3 w-full">
          <div className="h-2.5 w-20 rounded-full bg-gray-300/60 dark:bg-white/10 mx-auto md:mx-0" />
          <div className="h-10 md:h-14 w-1/2 rounded-xl bg-gray-300/60 dark:bg-white/15 mx-auto md:mx-0" />
          <div className="h-4 w-1/3 rounded-full bg-gray-300/50 dark:bg-white/10 mx-auto md:mx-0" />
        </div>
      </div>
      {/* Stats */}
      <div className="px-5 md:px-8 lg:px-10 mt-6 space-y-6">
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
          {Array.from({ length: 3 }).map((_, i) => (
            <div key={i} className="rounded-2xl p-6 border border-gray-200 dark:border-white/10 bg-gray-100 dark:bg-white/5 space-y-3">
              <div className="h-3 w-28 rounded-full bg-gray-200 dark:bg-white/10" />
              <div className="h-10 w-20 rounded-lg bg-gray-200 dark:bg-white/15" />
            </div>
          ))}
        </div>
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          {Array.from({ length: 2 }).map((_, i) => (
            <div key={i} className="rounded-2xl p-6 border border-gray-200/80 dark:border-white/5 bg-white dark:bg-gray-900/40 space-y-4">
              <div className="h-5 w-28 rounded-lg bg-gray-200 dark:bg-white/10" />
              {Array.from({ length: 5 }).map((_, j) => (
                <div key={j} className="flex items-center gap-3">
                  <div className="w-8 h-3 rounded-full bg-gray-100 dark:bg-white/[0.06]" />
                  <div className="w-12 h-12 rounded-lg bg-gray-200 dark:bg-white/10 flex-shrink-0" />
                  <div className="flex-1 space-y-1.5">
                    <div className="h-3.5 w-3/4 rounded-full bg-gray-200 dark:bg-white/10" />
                    <div className="h-3 w-1/2 rounded-full bg-gray-100 dark:bg-white/[0.06]" />
                  </div>
                </div>
              ))}
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}



interface WrappedStats {
  total_plays: number
  weighted_average_release_year: number | null
  weighted_average_BPM: number | null
  weighted_average_Energy: number | null
  top_songs: Array<{
    id: string
    title: string
    artist: string
    album: string
    album_id: string
    cover_art: string | null
    plays: number
  }>
  top_artists: Array<{
    artist: string
    plays: number
  }>
  top_genres: Array<{
    genre: string
    plays: number
  }>
}

interface UserProfileData {
  username: string
  avatarUrl: string | null
  createdAt: string
  updatedAt: string
  lastScrobble: { title: string; artist: string; album: string; playedAt: string } | null
}

type Period = 'week' | 'month'

const MiniWrappedSection = ({ username }: { username: string }) => {
  const [period, setPeriod] = useState<Period>('week')
  const [stats, setStats] = useState<WrappedStats | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [userData, setUserData] = useState<UserProfileData | null>(null)

  useEffect(() => {
    // Fetch last scrobble and last login from admin users endpoint
    backendApi.getAdminUsers()
      .then(users => {
        const found = users.find(u => u.username === username)
        if (found) setUserData(found)
      })
      .catch(err => console.error('[UserProfile] Error loading user profile data:', err))
  }, [username])

  useEffect(() => {
    const fetchStats = async () => {
      try {
        setLoading(true)
        setError(null)
        
        // Usar el nuevo endpoint que no tiene restricción de fecha
        const data = await backendApi.getUserStats(username, period)
        setStats(data)
      } catch (err) {
        console.error('Error fetching user stats:', err)
        setError('No hay datos disponibles')
      } finally {
        setLoading(false)
      }
    }

    fetchStats()
  }, [username, period])

  if (loading) {
    return (
      <div className="bg-white dark:bg-gray-900/40 rounded-3xl p-8 border border-gray-200/80 dark:border-white/5 animate-pulse space-y-4">
        <div className="h-6 w-48 rounded-lg bg-gray-200 dark:bg-white/10" />
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
          {Array.from({ length: 3 }).map((_, i) => (
            <div key={i} className="rounded-2xl p-6 border border-gray-200 dark:border-white/10 bg-gray-100 dark:bg-white/5 space-y-3">
              <div className="h-3 w-28 rounded-full bg-gray-200 dark:bg-white/10" />
              <div className="h-10 w-20 rounded-lg bg-gray-200 dark:bg-white/15" />
            </div>
          ))}
        </div>
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          {Array.from({ length: 2 }).map((_, i) => (
            <div key={i} className="rounded-2xl p-6 border border-gray-200/80 dark:border-white/5 bg-white dark:bg-gray-900/40 space-y-3">
              <div className="h-5 w-28 rounded-lg bg-gray-200 dark:bg-white/10" />
              {Array.from({ length: 5 }).map((_, j) => (
                <div key={j} className="flex items-center gap-3">
                  <div className="w-12 h-12 rounded-lg bg-gray-200 dark:bg-white/10 flex-shrink-0" />
                  <div className="flex-1 space-y-1.5">
                    <div className="h-3.5 w-3/4 rounded-full bg-gray-200 dark:bg-white/10" />
                    <div className="h-3 w-1/2 rounded-full bg-gray-100 dark:bg-white/[0.06]" />
                  </div>
                </div>
              ))}
            </div>
          ))}
        </div>
      </div>
    )
  }

  if (error || !stats || stats.total_plays === 0) {
    return (
      <div className="bg-white dark:bg-gray-900/40 rounded-3xl p-8 border border-gray-200/80 dark:border-white/5">
      <div className="text-center py-8">
        <MusicalNoteIcon className="w-16 h-16 text-gray-300 dark:text-gray-600 mx-auto mb-4 opacity-20" />
        <p className="text-gray-500 dark:text-gray-400 font-medium">
          {error || 'No hay reproducciones registradas aún'}
        </p>
      </div>
      </div>
    )
  }

  const topSongs = stats.top_songs.slice(0, 5)
  const topArtists = stats.top_artists.slice(0, 5)

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div>
            <h2 className="text-2xl font-bold text-gray-900 dark:text-white">
              Estadísticas de escucha
            </h2>
            <p className="text-sm text-gray-500 dark:text-gray-400 mt-0.5">
              {period === 'week' ? 'Últimos 7 días' : 'Último mes'}
            </p>
          </div>
        </div>
        
        {/* Selector de período estilo Apple */}
        <div className="inline-flex items-center bg-gray-100 dark:bg-gray-700/50 rounded-full p-1">
          <button
            onClick={() => setPeriod('week')}
            className={`px-4 py-2 rounded-full text-sm font-medium transition-all duration-200 ${
              period === 'week'
                ? 'bg-white dark:bg-gray-600 text-gray-900 dark:text-white shadow-sm'
                : 'text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white'
            }`}
          >
            Semanal
          </button>
          <button
            onClick={() => setPeriod('month')}
            className={`px-4 py-2 rounded-full text-sm font-medium transition-all duration-200 ${
              period === 'month'
                ? 'bg-white dark:bg-gray-600 text-gray-900 dark:text-white shadow-sm'
                : 'text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white'
            }`}
          >
            Mensual
          </button>
        </div>
      </div>

      {/* Grid de estadísticas */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        {/* Reproducciones totales */}
        <div className="bg-white/5 dark:bg-white/5 rounded-2xl p-6 border border-gray-200/50 dark:border-white/10 backdrop-blur-sm shadow-sm transition-all hover:bg-white/10 dark:hover:bg-white/10">
          <div className="flex items-center justify-between mb-2">
            <span className="text-gray-600 dark:text-gray-400 text-sm font-semibold uppercase tracking-wider">Reproducciones</span>
          </div>
          <p className="text-4xl font-black text-gray-900 dark:text-white">{stats.total_plays.toLocaleString()}</p>
        </div>

        {/* Género más escuchado */}
        {stats.top_genres && stats.top_genres.length > 0 && (
          <div className="bg-white/5 dark:bg-white/5 rounded-2xl p-6 border border-gray-200/50 dark:border-white/10 backdrop-blur-sm shadow-sm transition-all hover:bg-white/10 dark:hover:bg-white/10">
            <div className="flex items-center justify-between mb-2">
              <span className="text-gray-600 dark:text-gray-400 text-sm font-semibold uppercase tracking-wider">Género favorito</span>
            </div>
            <p className="text-4xl font-black text-gray-900 dark:text-white truncate">
              {stats.top_genres[0].genre}
            </p>
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-1 font-medium italic">
              {period === 'week' ? 'Esta semana' : 'Este mes'}
            </p>
          </div>
        )}

        {/* Último scrobble */}
        <div className="bg-white/5 dark:bg-white/5 rounded-2xl p-6 border border-gray-200/50 dark:border-white/10 backdrop-blur-sm shadow-sm transition-all hover:bg-white/10 dark:hover:bg-white/10">
          <div className="flex items-center justify-between mb-2">
            <span className="text-gray-600 dark:text-gray-400 text-sm font-semibold uppercase tracking-wider">Último scrobble</span>
          </div>
          {userData?.lastScrobble ? (
            <div className="min-w-0">
              <p className="text-xl font-bold text-gray-900 dark:text-white truncate leading-tight">
                {userData.lastScrobble.title}
              </p>
              <p className="text-sm font-medium text-blue-600 dark:text-blue-400 truncate mt-1">
                {userData.lastScrobble.artist}
              </p>
              <p className="text-[10px] text-gray-500 dark:text-gray-400 mt-3 uppercase tracking-wider font-bold">
                {new Date(userData.lastScrobble.playedAt).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })}
              </p>
            </div>
          ) : (
            <p className="text-sm text-gray-400 mt-1 animate-pulse italic">Esperando actividad...</p>
          )}
        </div>
      </div>

      {/* Top Canciones y Artistas */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Top Canciones */}
        <div className="bg-white dark:bg-gray-900/40 rounded-2xl p-6 border border-gray-200/80 dark:border-white/5">
          <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
            Top Canciones
          </h3>
          <div className="space-y-3">
            {topSongs.map((song, index) => (
              <div
                key={`${song.title}-${song.artist}-${index}`}
                className="flex items-center gap-3 group hover:bg-gray-50 dark:hover:bg-white/[0.05] rounded-xl p-2 transition-colors"
              >
                <div className="flex-shrink-0 w-8 text-center">
                  <span className="text-lg font-bold text-gray-400 dark:text-gray-500">
                    {index + 1}
                  </span>
                </div>
                <div className="w-12 h-12 flex-shrink-0 rounded-lg overflow-hidden bg-gray-100 dark:bg-white/[0.07] shadow-sm">
                  {song.cover_art ? (
                    <img
                      src={navidromeApi.getCoverUrl(song.cover_art)}
                      alt={song.title}
                      className="w-full h-full object-cover"
                    />
                  ) : (
                    <div className="w-full h-full flex items-center justify-center">
                      <MusicalNoteIcon className="w-6 h-6 text-gray-400" />
                    </div>
                  )}
                </div>
                <div className="flex-1 min-w-0">
                  <Link 
                    to={`/songs/${song.id}`}
                    className="text-sm font-semibold text-gray-900 dark:text-white truncate block hover:text-blue-500 dark:hover:text-blue-400 hover:underline transition-all"
                    onClick={(e) => e.stopPropagation()}
                  >
                    {song.title}
                  </Link>
                  <Link 
                    to={`/artists/${encodeURIComponent(song.artist)}`}
                    className="text-xs text-gray-500 dark:text-gray-400 truncate block hover:text-blue-500 dark:hover:text-blue-400 hover:underline transition-all"
                    onClick={(e) => e.stopPropagation()}
                  >
                    {song.artist}
                  </Link>
                </div>
                <div className="flex-shrink-0 text-right">
                  <span className="text-sm font-semibold text-gray-600 dark:text-gray-300">
                    {song.plays}
                  </span>
                  <p className="text-xs text-gray-400 dark:text-gray-500">plays</p>
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Top Artistas */}
        <div className="bg-white dark:bg-gray-900/40 rounded-2xl p-6 border border-gray-200/80 dark:border-white/5">
          <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
            Top Artistas
          </h3>
          <div className="space-y-3">
            {topArtists.map((artist, index) => (
              <div
                key={`${artist.artist}-${index}`}
                className="flex items-center gap-3 group hover:bg-gray-50 dark:hover:bg-white/[0.05] rounded-xl p-2 transition-colors"
              >
                <div className="flex-shrink-0 w-8 text-center">
                  <span className="text-lg font-bold text-gray-400 dark:text-gray-500">
                    {index + 1}
                  </span>
                </div>
                <div className="w-12 h-12 flex-shrink-0">
                  <UniversalCover type="artist" artistName={artist.artist} context="grid" />
                </div>
                <div className="flex-1 min-w-0">
                  <Link 
                    to={`/artists/${encodeURIComponent(artist.artist)}`}
                    className="text-sm font-semibold text-gray-900 dark:text-white truncate block hover:text-blue-500 dark:hover:text-blue-400 hover:underline transition-all"
                    onClick={(e) => e.stopPropagation()}
                  >
                    {artist.artist}
                  </Link>
                </div>
                <div className="flex-shrink-0 text-right">
                  <span className="text-sm font-semibold text-gray-600 dark:text-gray-300">
                    {artist.plays}
                  </span>
                  <p className="text-xs text-gray-400 dark:text-gray-500">plays</p>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}

const PlaylistCard = ({ playlist, onClick }: { playlist: Playlist; onClick: () => void }) => {
  const isEditorial = playlist.comment?.includes('[Editorial]')
  const isSpotify = playlist.name.startsWith('[Spotify] ') || playlist.comment?.includes('Spotify Synced')
  
  return (
    <button
      onClick={onClick}
      className="group w-full text-left transition-all duration-300 relative"
    >
      <div className="bg-gray-50 dark:bg-white/[0.04] rounded-2xl overflow-hidden border border-gray-200/50 dark:border-white/[0.06] relative">
        <PlaylistCover
          playlistId={playlist.id}
          name={playlist.name}
          className="aspect-square relative w-full h-full object-cover"
          rounded={false}
        />
        <div className="absolute top-2 right-2 z-20 flex items-center gap-2">
          {isSpotify && (
             <div className="bg-[#1DB954] text-white p-1 rounded-full shadow-lg" title="Sincronizado con Spotify">
               <svg className="w-3.5 h-3.5" fill="currentColor" viewBox="0 0 24 24">
                 <path d="M12 0C5.373 0 0 5.373 0 12s5.373 12 12 12 12-5.373 12-12S18.627 0 12 0zm5.492 17.31c-.218.358-.684.47-1.042.252-2.857-1.745-6.45-2.14-10.684-1.173-.41.094-.823-.16-.917-.57-.094-.41.16-.823.57-.917 4.623-1.057 8.583-.61 11.782 1.345.358.218.47.684.252 1.042zm1.464-3.26c-.275.446-.86.592-1.306.317-3.27-2.01-8.254-2.593-12.122-1.417-.5.152-1.026-.134-1.178-.633-.152-.5.134-1.026.633-1.178 4.417-1.34 9.907-.69 13.655 1.614.447.275.592.86.317 1.306zm.126-3.414C15.345 8.35 9.176 8.145 5.62 9.223c-.563.17-1.16-.148-1.332-.71-.17-.563.15-1.16.712-1.332 4.102-1.246 10.92-1.008 15.226 1.55.51.3.67.954.37 1.464-.3.51-.954.67-1.464.37z" />
               </svg>
             </div>
          )}
          {isEditorial && (
             <div className="bg-white/90 dark:bg-gray-800/90 backdrop-blur-sm p-1 rounded-full shadow-lg flex items-center justify-center" title="Hecho por Audiorr">
               <img src="/assets/logo-icon.svg" alt="Audiorr" className="w-4 h-4 object-contain drop-shadow-sm brightness-0 dark:invert" />
             </div>
          )}
        </div>
        <div className="p-4">
          <p
            className="font-semibold text-gray-900 dark:text-white truncate group-hover:text-blue-600 dark:group-hover:text-blue-400 transition-colors"
            title={playlist.name.replace('[Spotify] ', '')}
          >
            {playlist.name.replace('[Spotify] ', '')}
          </p>
          <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">
            {playlist.songCount} {playlist.songCount === 1 ? 'canción' : 'canciones'}
          </p>
        </div>
      </div>
    </button>
  )
}

export default function UserProfile() {
  const { username } = useParams<{ username: string }>()
  const navigate = useNavigate()
  const [playlists, setPlaylists] = useState<Playlist[]>([])
  const [loading, setLoading] = useState(true)
  const [userExists, setUserExists] = useState(true)
  const [userData, setUserData] = useState<UserProfileData | null>(null)

  // No se necesitan colores ni gradientes manuales aquí, PageHero lo gestiona
  

  useEffect(() => {
    if (!username) return

    const loadUserPlaylists = async () => {
      try {
        setLoading(true)
        const allPlaylists = await navidromeApi.getPlaylists()
        
        // Filtrar solo las playlists públicas del usuario.
        // Ocultamos las editoriales para no contaminar su perfil personal (sobre todo si es admin)
        const userPlaylists = allPlaylists.filter(
          p => p.owner === username && p.public && !p.comment?.includes('[Editorial]')
        )
        
        // Ya no validamos la "existencia" del usuario basada en si tiene playlists,
        // porque un usuario puede tener 0 playlists pero sí tener estadísticas de escucha
        // en el backend. Mostraremos el perfil de todos modos.
        setUserExists(true)
        setPlaylists(userPlaylists)
      } catch (error) {
        console.error('Error loading user playlists:', error)
        // Solo fallamos en casos muy graves de red
        setUserExists(true) 
      } finally {
        setLoading(false)
      }
    }

      loadUserPlaylists()

      // Cargar datos de admin (login, scrobble)
      backendApi.getAdminUsers()
        .then(users => {
          const found = users.find(u => u.username === username)
          if (found) setUserData(found)
        })
        .catch(err => console.error('[UserProfile] Error loading admin profile data:', err))
    }, [username])

  if (loading) {
    return <UserProfileSkeleton />
  }

  if (!userExists) {
    return (
      <div className="w-full max-w-7xl mx-auto pb-12 px-8">
        <div className="text-center py-16">
          <div className="inline-flex items-center justify-center w-20 h-20 rounded-full bg-gray-100 dark:bg-gray-800 mb-4">
            <span className="text-4xl">🔍</span>
          </div>
          <h3 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">
            Usuario no encontrado
          </h3>
          <p className="text-gray-600 dark:text-gray-400 mb-6">
            El usuario <strong>{username}</strong> no existe o no tiene playlists públicas
          </p>
          <button
            onClick={() => navigate('/playlists')}
            className="px-6 py-3 bg-blue-600 text-white rounded-xl hover:bg-blue-700 transition-colors"
          >
            Volver a Playlists
          </button>
        </div>
      </div>
    )
  }

  return (
    <div>
      <PageHero
        type="user"
        title={username || ''}
        subtitle="Perfil Público"
        coverImageUrl={null}
        initial={username ? getInitial(username) : '?'}
        backgroundColor={username ? getColorForUsername(username) : '#6b7280'}
        dominantColors={username ? {
          primary: getColorForUsername(username),
          secondary: getColorForUsername(username + 'alt'),
          accent: getColorForUsername(username + 'acc')
        } : null}
        artistName={username}
        metadata={
          <div className="mt-5 flex flex-wrap items-center justify-center md:justify-start gap-x-1.5 gap-y-1 text-sm md:text-base text-[var(--hero-text)]">
            <span className="font-bold">
              {playlists.length} {playlists.length === 1 ? 'playlist pública' : 'playlists públicas'}
            </span>
            {userData?.updatedAt && (
              <span className="flex items-center gap-1.5 font-medium" style={{ color: 'var(--hero-text-muted)' }}>
                <span className="text-[var(--hero-text-dim)] text-[10px] mx-0.5">•</span>
                <ClockIcon className="w-4 h-4 opacity-70" />
                <span>Última conexión {new Date(userData.updatedAt).toLocaleDateString(undefined, { day: 'numeric', month: 'short' })}</span>
              </span>
            )}
          </div>
        }
      />

      <div className="px-5 md:px-8 lg:px-10 space-y-8 mt-6">
        {/* Mini Wrapped Section */}
        <MiniWrappedSection username={username || ''} />

        {/* Playlists Section */}
        {playlists.length > 0 && (
          <div className="space-y-6">
            <div>
              <h2 className="text-3xl font-bold text-gray-900 dark:text-white mb-2">
                Playlists Públicas
              </h2>
            <p className="text-gray-600 dark:text-gray-400">
              Explora las playlists compartidas por {username || 'este usuario'}
            </p>
            </div>

            <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 gap-6">
              {playlists.map(playlist => (
                <PlaylistCard
                  key={playlist.id}
                  playlist={playlist}
                  onClick={() => navigate(`/playlists/${playlist.id}`)}
                />
              ))}
            </div>
          </div>
        )}

        {playlists.length === 0 && (
          <div className="text-center py-16">
            <div className="inline-flex items-center justify-center w-20 h-20 rounded-full bg-gray-100 dark:bg-gray-800 mb-4">
              <MusicalNoteIcon className="w-10 h-10 text-gray-400 dark:text-gray-600" />
            </div>
            <h3 className="text-xl font-semibold text-gray-900 dark:text-white mb-2">
              No hay playlists públicas
            </h3>
            <p className="text-gray-600 dark:text-gray-400">
              {username || 'Este usuario'} aún no ha compartido ninguna playlist públicamente
            </p>
          </div>
        )}
      </div>
    </div>
  )
}

