import { useEffect, useState } from 'react'
import { motion } from 'framer-motion'
import { useNavigate } from 'react-router-dom'
import { navidromeApi, type Album, type Song } from '../services/navidromeApi'
import { usePlayerActions } from '../contexts/PlayerContext'
import { API_BASE_URL } from '../services/backendApi'
import AlbumCard from './AlbumCard'
import AlbumCover from './AlbumCover'
import DailyMixSection from './DailyMixSection'
import JumpBackInSection from './JumpBackInSection'
import HorizontalScrollSection from './HorizontalScrollSection'
import { useContextMenu } from '../hooks/useContextMenu'
import SongContextMenu from './SongContextMenu'
import { useBackendAvailable } from '../contexts/BackendAvailableContext'

interface TopWeeklySong {
  song_id: string
  title: string
  artist: string
  album: string
  album_id: string
  cover_art: string
  plays: number
  rank: number
  previousRank: number | null
  trend: 'up' | 'down' | 'same' | 'new'
  change: number | null
}

function TrendIndicator({ trend, change }: { trend: TopWeeklySong['trend']; change: number | null }) {
  if (trend === 'new') {
    return (
      <span className="text-[9px] font-bold tracking-widest text-sky-400 uppercase">new</span>
    )
  }
  if (trend === 'up') {
    return (
      <span className="flex items-center gap-px text-sky-400">
        <svg className="w-2.5 h-2.5 flex-shrink-0" fill="currentColor" viewBox="0 0 24 24">
          <path d="M7 14l5-5 5 5z" />
        </svg>
        {change != null && <span className="text-[10px] font-semibold tabular-nums leading-none">{change}</span>}
      </span>
    )
  }
  if (trend === 'down') {
    return (
      <span className="flex items-center gap-px text-red-400">
        <svg className="w-2.5 h-2.5 flex-shrink-0" fill="currentColor" viewBox="0 0 24 24">
          <path d="M7 10l5 5 5-5z" />
        </svg>
        {change != null && <span className="text-[10px] font-semibold tabular-nums leading-none">{change}</span>}
      </span>
    )
  }
  // same
  return <span className="text-gray-400 dark:text-gray-600 text-[13px] font-medium leading-none">—</span>
}

export default function HomePage() {
  const navigate = useNavigate()
  const playerActions = usePlayerActions()
  const [albums, setAlbums] = useState<Album[]>([])
  const [recentReleases, setRecentReleases] = useState<Album[]>([])
  const [topWeekly, setTopWeekly] = useState<TopWeeklySong[]>([])
  const [loading, setLoading] = useState(true)
  const [loadingRecent, setLoadingRecent] = useState(true)
  const [showWrapped, setShowWrapped] = useState(false)
  const { menu, handleContextMenu, closeContextMenu } = useContextMenu()
  const backendAvailable = useBackendAvailable()

  useEffect(() => {
    const now = new Date()
    const currentMonth = now.getMonth() + 1
    const currentYear = now.getFullYear()
    if (currentYear >= 2026 && currentMonth === 12) {
      setShowWrapped(true)
    }
  }, [])

  useEffect(() => {
    const fetchAlbums = async () => {
      try {
        setLoading(true)
        const latestAlbums = await navidromeApi.getLatestAlbums(50)
        setAlbums(latestAlbums)
      } catch (err) {
        console.error(err)
      } finally {
        setLoading(false)
      }
    }
    fetchAlbums()
  }, [])

  useEffect(() => {
    if (!backendAvailable) return
    fetch(`${API_BASE_URL}/api/stats/top-weekly`)
      .then(r => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`)
        return r.json()
      })
      .then((data: unknown) => {
        if (Array.isArray(data)) setTopWeekly(data as TopWeeklySong[])
        else console.error('[TopWeekly] Unexpected response:', data)
      })
      .catch(err => console.error('[TopWeekly] Fetch failed:', err))
  }, [backendAvailable])

  useEffect(() => {
    const fetchRecentReleases = async () => {
      try {
        setLoadingRecent(true)
        const recent = await navidromeApi.getRecentReleases(6, 40)
        setRecentReleases(recent)
      } catch (err) {
        console.error(err)
      } finally {
        setLoadingRecent(false)
      }
    }
    fetchRecentReleases()
  }, [])

  const currentYear = new Date().getFullYear()

  const AlbumCardSkeleton = () => (
    <div className="flex-shrink-0 w-36 md:w-44 animate-pulse">
      <div className="aspect-square rounded-lg bg-gray-200 dark:bg-white/[0.08]" />
      <div className="mt-2 space-y-1.5">
        <div className="h-3.5 w-3/4 rounded-full bg-gray-200 dark:bg-white/[0.08]" />
        <div className="h-3 w-1/2 rounded-full bg-gray-100 dark:bg-white/[0.05]" />
      </div>
    </div>
  )

  const TopWeeklySkeleton = () => (
    <div className="flex-shrink-0 w-[calc(100vw-2rem)] max-w-sm flex flex-col">
      {[...Array(5)].map((_, i) => (
        <div key={i} className="flex items-center gap-2.5 py-2 px-2 animate-pulse">
          <div className="w-5 h-3 flex-shrink-0 rounded-full bg-gray-200 dark:bg-white/[0.08]" />
          <div className="w-10 h-10 flex-shrink-0 rounded-md bg-gray-200 dark:bg-white/[0.08]" />
          <div className="flex-1 min-w-0 space-y-1.5">
            <div className="h-3 w-3/4 rounded-full bg-gray-200 dark:bg-white/[0.08]" />
            <div className="h-2.5 w-1/2 rounded-full bg-gray-100 dark:bg-white/[0.05]" />
          </div>
        </div>
      ))}
    </div>
  )

  const toSong = (entry: TopWeeklySong): Song => ({
    id: entry.song_id,
    title: entry.title,
    artist: entry.artist,
    album: entry.album,
    albumId: entry.album_id,
    coverArt: entry.cover_art,
    duration: 0,
    path: '',
  })

  return (
    <div className="space-y-10">
      {/* Banner Wrapped (solo diciembre) */}
      {showWrapped && (
        <motion.section
          initial={{ opacity: 0, y: -20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5 }}
        >
          <motion.div
            whileHover={{ scale: 1.02 }}
            whileTap={{ scale: 0.98 }}
            onClick={() => navigate('/wrapped')}
            className="relative overflow-hidden rounded-2xl bg-gradient-to-r from-purple-600 via-pink-600 to-red-600 p-8 cursor-pointer shadow-lg"
          >
            <div className="relative z-10">
              <h2 className="text-4xl md:text-5xl font-bold text-white mb-2">Wrapped {currentYear}</h2>
              <p className="text-xl md:text-2xl text-white/90">Descubre tus estadísticas musicales</p>
              <motion.div className="mt-4 inline-flex items-center text-white font-semibold" whileHover={{ x: 5 }}>
                Ver mi Wrapped
                <svg className="ml-2 w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" />
                </svg>
              </motion.div>
            </div>
            <motion.div
              className="absolute inset-0 bg-gradient-to-r from-transparent via-white/20 to-transparent"
              animate={{ x: ['-100%', '200%'] }}
              transition={{ repeat: Infinity, duration: 3, ease: 'linear' }}
              style={{ transform: 'skewX(-20deg)' }}
            />
          </motion.div>
        </motion.section>
      )}

      {/* 1. Lo más escuchado — horizontal scroll, 2 columnas de 5 canciones */}
      {backendAvailable && (
        <HorizontalScrollSection title="Lo más escuchado">
          {topWeekly.length > 0
            ? [topWeekly.slice(0, 5), topWeekly.slice(5, 10)].map((group, groupIdx) => (
                <div key={groupIdx} className="flex-shrink-0 w-[calc(100vw-2rem)] max-w-sm flex flex-col">
                  {group.map((entry, i) => {
                    const idx = groupIdx * 5 + i
                    return (
                      <div
                        key={entry.song_id}
                        className="flex items-center gap-2.5 py-2 px-2 rounded-xl cursor-pointer select-none active:bg-black/5 dark:active:bg-white/5 transition-colors"
                        onClick={() => {
                          const allSongs = topWeekly.slice(0, 10).map(toSong)
                          playerActions.playPlaylistFromSong(allSongs, allSongs[idx], `album:${entry.album_id}`)
                        }}
                      >
                        <span className="w-5 text-center font-bold tabular-nums text-gray-400 dark:text-gray-500 text-xs flex-shrink-0">
                          {entry.rank}
                        </span>
                        <div className="w-10 h-10 flex-shrink-0 rounded-md overflow-hidden shadow">
                          <AlbumCover coverArtId={entry.cover_art} size={80} className="w-full h-full" />
                        </div>
                        <div className="flex-1 min-w-0">
                          <p className="text-[13px] font-semibold leading-tight truncate text-gray-900 dark:text-white">
                            {entry.title}
                          </p>
                          <p className="text-[11px] text-gray-500 dark:text-gray-400 truncate mt-0.5">{entry.artist}</p>
                        </div>
                        <div className="flex items-center gap-0.5 flex-shrink-0">
                          <TrendIndicator trend={entry.trend} change={entry.change} />
                          <button
                            className="flex items-center justify-center w-7 h-7 rounded-full text-gray-400 dark:text-gray-500 hover:text-gray-600 dark:hover:text-gray-300 active:bg-gray-200/70 dark:active:bg-white/10 transition-colors"
                            aria-label="Más opciones"
                            onClick={e => { e.stopPropagation(); handleContextMenu(e, toSong(entry)) }}
                          >
                            <svg className="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
                              <circle cx="5" cy="12" r="1.75" />
                              <circle cx="12" cy="12" r="1.75" />
                              <circle cx="19" cy="12" r="1.75" />
                            </svg>
                          </button>
                        </div>
                      </div>
                    )
                  })}
                </div>
              ))
            : [0, 1].map(groupIdx => <TopWeeklySkeleton key={groupIdx} />)
          }
        </HorizontalScrollSection>
      )}

      {/* 2. Volver a escuchar */}
      {backendAvailable && <JumpBackInSection />}

      {/* 3. Lanzamientos recientes */}
      <HorizontalScrollSection title="Lanzamientos recientes">
        {loadingRecent
          ? [...Array(6)].map((_, i) => <AlbumCardSkeleton key={i} />)
          : recentReleases.slice(0, 18).map(album => (
              <div key={album.id} className="flex-shrink-0 w-36 md:w-44">
                <AlbumCard album={album} showPlayButton={true} />
              </div>
            ))
        }
      </HorizontalScrollSection>

      {/* 4. Tus mixes diarios (solo con backend) */}
      {backendAvailable && <DailyMixSection />}

      {/* 5. Últimos álbumes añadidos */}
      <HorizontalScrollSection title="Últimos álbumes añadidos">
        {loading
          ? [...Array(8)].map((_, i) => <AlbumCardSkeleton key={i} />)
          : albums.map(album => (
              <div key={album.id} className="flex-shrink-0 w-36 md:w-44">
                <AlbumCard album={album} showPlayButton={true} />
              </div>
            ))
        }
      </HorizontalScrollSection>

      {menu && (
        <SongContextMenu
          x={menu.x}
          y={menu.y}
          song={menu.song}
          onClose={closeContextMenu}
          showGoToArtist={true}
          showGoToAlbum={true}
        />
      )}
    </div>
  )
}
