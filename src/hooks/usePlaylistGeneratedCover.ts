import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Playlist } from '../services/navidromeApi'
import { generatedCoverService, type PlaylistCoverVariant, type PlaylistLike } from '../services/generatedCoverService'
import { customCoverService } from '../services/customCoverService'

interface UseGeneratedCoverResult {
  coverUrl: string | null
  variant: PlaylistCoverVariant | 'manual' | null
  isLoading: boolean
  regenerate: (force?: boolean) => Promise<void>
}

const DEBUG_PREFIX = '[usePlaylistGeneratedCover]'
const SHOULD_LOG_DEBUG = Boolean(import.meta.env.DEV)
const SHOULD_LOG_VERBOSE = SHOULD_LOG_DEBUG && import.meta.env.VITE_DEBUG_GENERATED_COVERS === 'verbose'

function logDebug(message: string, payload?: Record<string, unknown>, options: { verbose?: boolean } = {}) {
  if (!SHOULD_LOG_DEBUG) return
  if (options.verbose && !SHOULD_LOG_VERBOSE) return

  if (payload) {
    console.debug(DEBUG_PREFIX, message, payload)
  } else {
    console.debug(DEBUG_PREFIX, message)
  }
}

function buildPlaylistInput(playlist: PlaylistLike | Playlist): PlaylistLike {
  return {
    id: playlist.id,
    name: playlist.name,
    comment: 'comment' in playlist ? playlist.comment : undefined,
    songCount: 'songCount' in playlist ? playlist.songCount : undefined,
    duration: 'duration' in playlist ? playlist.duration : undefined,
    created: 'created' in playlist ? playlist.created : undefined,
    changed: 'changed' in playlist ? playlist.changed : undefined,
    coverArt: 'coverArt' in playlist ? playlist.coverArt : undefined,
  }
}

export function usePlaylistGeneratedCover(
  playlist: PlaylistLike | Playlist | null | undefined,
  size?: number
): UseGeneratedCoverResult {
  const [version, setVersion] = useState(0)

  // Escuchar a cambios estáticos en manual covers (customCoverService)
  useEffect(() => {
    const unsubscribe = customCoverService.subscribe(() => setVersion(v => v + 1))
    return unsubscribe
  }, [])

  const playlistInput = useMemo(() => {
    return playlist ? buildPlaylistInput(playlist) : null
  }, [playlist])

  const coverInfo = useMemo(() => {
    void version

    if (!playlistInput) {
      return { url: null, variant: null }
    }

    const manualCover = customCoverService.getCustomCover(playlistInput.id)
    if (manualCover) {
      logDebug('using manual cover', { playlistId: playlistInput.id })
      return { url: manualCover, variant: 'manual' as const }
    }

    const variant = generatedCoverService.pickVariantFromName(playlistInput.name, playlistInput.comment)
    if (!variant) {
      logDebug('playlist is not editorial, skipping generated cover', { playlistId: playlistInput.id })
      return { url: null, variant: null }
    }

    const changeKey = generatedCoverService.resolveChangeKey(playlistInput)
    const coverUrl = generatedCoverService.generatePlaylistCoverUrl(playlistInput, variant, changeKey, size, size)

    logDebug('using generated backend url', { playlistId: playlistInput.id, variant, changeKey, size })
    
    return { url: coverUrl, variant }
  }, [playlistInput, version, size])

  const regenerate = useCallback(async () => {
    // Al usar tags <img> y backend caching, la regeneración forzada normalmente no es necesaria 
    // a nivel del componente frontend porque el "changeKey" detecta los cambios reales usando métricas
    // persistentes de la playlist como `songCount` y `changed`. 
    // Sin embargo, proveemos esta función por compatibilidad con los botones de forzar actualización 
    // (en esos casos el backend ya tiene la invalidación via SQLite si la URL cambia).
    
    // Si queremos obligar al frontend a refetch, engañamos al DOM añadiendo un parámetro random al state
    setVersion(v => v + 1)
  }, [])

  return {
    coverUrl: coverInfo.url,
    variant: coverInfo.variant,
    isLoading: false, // La carga la manejará el componente <img> con onLoad/onError nativo
    regenerate,
  }
}
