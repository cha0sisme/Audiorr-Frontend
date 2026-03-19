import { useState, useEffect, useCallback } from 'react'
import { audioCacheService, CachedSongMeta } from '../services/audioCacheService'

export function useAudioCache() {
  const [entries, setEntries] = useState<CachedSongMeta[]>([])
  const [totalSize, setTotalSize] = useState(0)
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async () => {
    setLoading(true)
    const all = await audioCacheService.getAll()
    const sorted = all.sort((a, b) => b.cachedAt - a.cachedAt)
    setEntries(sorted)
    setTotalSize(sorted.reduce((s, e) => s + e.size, 0))
    setLoading(false)
  }, [])

  useEffect(() => {
    if (audioCacheService.isAvailable()) refresh()
    else setLoading(false)
  }, [refresh])

  const clearAll = useCallback(async () => {
    await audioCacheService.clearAll()
    setEntries([])
    setTotalSize(0)
  }, [])

  const remove = useCallback(
    async (songId: string) => {
      const entry = entries.find(e => e.songId === songId)
      await audioCacheService.remove(songId)
      setEntries(prev => prev.filter(e => e.songId !== songId))
      setTotalSize(prev => prev - (entry?.size ?? 0))
    },
    [entries]
  )

  const formatSize = (bytes: number): string => {
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  }

  return {
    entries,
    totalSize,
    loading,
    refresh,
    clearAll,
    remove,
    formatSize,
    isAvailable: audioCacheService.isAvailable(),
  }
}
