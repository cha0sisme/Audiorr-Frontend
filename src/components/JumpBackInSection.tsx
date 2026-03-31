import { useEffect, useState, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { navidromeApi } from '../services/navidromeApi'
import { API_BASE_URL } from '../services/backendApi'
import { usePlayerActions } from '../contexts/PlayerContext'
import { useBackendAvailable } from '../contexts/BackendAvailableContext'
import HorizontalScrollSection from './HorizontalScrollSection'

interface RecentContext {
  contextUri: string
  type: 'album' | 'playlist' | 'smartmix' | 'artist' | 'other'
  id: string
  title: string
  artist: string
  coverArtId: string | null
  lastPlayedAt: string
  songCount: number
}

function useArtistImage(name: string | null) {
  const [imageUrl, setImageUrl] = useState<string | null | undefined>(undefined)

  useEffect(() => {
    if (!name) return
    const params = new URLSearchParams({ name })
    fetch(`${API_BASE_URL}/api/artist/image?${params.toString()}`)
      .then(r => r.ok ? r.json() : null)
      .then((data: { imageUrl: string | null } | null) => {
        setImageUrl(data?.imageUrl ?? null)
      })
      .catch(() => setImageUrl(null))
  }, [name])

  return imageUrl
}

function CoverImage({ item }: { item: RecentContext }) {
  const artistImageUrl = useArtistImage(item.type === 'artist' ? item.id : null)

  if (item.type === 'album' && item.coverArtId) {
    const src = navidromeApi.getCoverUrl(item.coverArtId, 300)
    return (
      <img
        src={src}
        alt={item.title}
        className="w-full h-full object-cover"
        loading="lazy"
      />
    )
  }

  if (item.type === 'playlist' || item.type === 'smartmix') {
    return (
      <img
        src={`${API_BASE_URL}/api/playlists/${item.id}/cover.png`}
        alt={item.id}
        className="w-full h-full object-cover"
        loading="lazy"
        onError={(e) => {
          ;(e.currentTarget as HTMLImageElement).style.display = 'none'
        }}
      />
    )
  }

  if (item.type === 'artist') {
    if (artistImageUrl) {
      return (
        <img
          src={artistImageUrl}
          alt={item.id}
          className="w-full h-full object-cover"
          loading="lazy"
        />
      )
    }
    // Placeholder genérico para artistas sin imagen
    return (
      <div className="w-full h-full flex items-center justify-center bg-gray-200 dark:bg-gray-700">
        <svg className="w-12 h-12 text-gray-400 dark:text-gray-500" fill="currentColor" viewBox="0 0 24 24">
          <path d="M12 12c2.7 0 4.8-2.1 4.8-4.8S14.7 2.4 12 2.4 7.2 4.5 7.2 7.2 9.3 12 12 12zm0 2.4c-3.2 0-9.6 1.6-9.6 4.8v2.4h19.2v-2.4c0-3.2-6.4-4.8-9.6-4.8z" />
        </svg>
      </div>
    )
  }

  return (
    <div className="w-full h-full bg-gray-200 dark:bg-gray-700" />
  )
}

interface PlaylistInfo {
  name: string
  songCount: number
}

interface CardProps {
  item: RecentContext
  playlistData: PlaylistInfo | null
  onClick: () => void
}

function JumpBackInCard({ item, playlistData, onClick }: CardProps) {
  let title: string
  let subtitle: string | null

  if (item.type === 'album') {
    title = item.title
    subtitle = item.artist
  } else if (item.type === 'playlist' || item.type === 'smartmix') {
    title = playlistData?.name ?? 'Playlist'
    subtitle = playlistData ? `${playlistData.songCount} canciones` : null
  } else if (item.type === 'artist') {
    title = item.id
    subtitle = null
  } else {
    title = item.title || item.id
    subtitle = null
  }

  const isRound = item.type === 'artist'

  return (
    <button
      type="button"
      className="flex flex-col items-start text-left flex-shrink-0 w-36 md:w-44 group"
      onClick={onClick}
    >
      <div className={`w-full aspect-square overflow-hidden shadow-md group-active:scale-95 transition-transform duration-150 ${isRound ? 'rounded-full' : 'rounded-lg'}`}>
        <CoverImage item={item} />
      </div>
      <div className="mt-2 w-full">
        <p className="text-[13px] font-semibold text-gray-900 dark:text-white leading-tight truncate" title={title}>
          {title}
        </p>
        {subtitle && (
          <p className="text-[11px] text-gray-500 dark:text-gray-400 mt-0.5 truncate">{subtitle}</p>
        )}
      </div>
    </button>
  )
}

export default function JumpBackInSection() {
  const [items, setItems] = useState<RecentContext[]>([])
  const [playlists, setPlaylists] = useState<Map<string, PlaylistInfo>>(new Map())
  const hasFetched = useRef(false)
  const navigate = useNavigate()
  const playerActions = usePlayerActions()
  const backendAvailable = useBackendAvailable()

  useEffect(() => {
    // Re-fetch when backend becomes available (e.g., VPN activated)
    if (!backendAvailable) {
      // Reset so we re-fetch when it comes back
      hasFetched.current = false
      return
    }
    if (hasFetched.current) return
    hasFetched.current = true

    const config = navidromeApi.getConfig()
    if (!config?.username) return

    const params = new URLSearchParams({ username: config.username })
    fetch(`${API_BASE_URL}/api/stats/recent-contexts?${params.toString()}`)
      .then(r => r.ok ? r.json() : [])
      .then((data: RecentContext[]) => {
        if (!Array.isArray(data) || data.length === 0) return
        setItems(data)

        // Resolver nombres de playlists/smartmix desde el caché de Navidrome
        const needsPlaylistName = data.some(d => d.type === 'playlist' || d.type === 'smartmix')
        if (needsPlaylistName) {
          navidromeApi.getPlaylists().then(all => {
            const map = new Map<string, PlaylistInfo>()
            all.forEach(p => map.set(p.id, { name: p.name, songCount: p.songCount }))
            setPlaylists(map)
          }).catch(() => { /* ignorar */ })
        }
      })
      .catch(() => { /* ignorar — endpoint opcional */ })
  }, [backendAvailable])

  if (items.length === 0) return null

  const handleCardClick = (item: RecentContext) => {
    const uri = `${item.type}:${item.id}`
    playerActions.setCurrentContextUri(uri)

    switch (item.type) {
      case 'album':
        navigate(`/albums/${item.id}`)
        break
      case 'playlist':
      case 'smartmix':
        navigate(`/playlists/${item.id}`)
        break
      case 'artist':
        navigate(`/artists/${encodeURIComponent(item.id)}`)
        break
    }
  }

  return (
    <HorizontalScrollSection title="Volver a escuchar">
      {items.map(item => (
        <JumpBackInCard
          key={item.contextUri}
          item={item}
          playlistData={playlists.get(item.id) ?? null}
          onClick={() => handleCardClick(item)}
        />
      ))}
    </HorizontalScrollSection>
  )
}
