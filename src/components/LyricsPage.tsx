import { useState, useEffect, useRef, useCallback } from 'react'
import { usePlayerState, usePlayerActions, usePlayerProgress } from '../contexts/PlayerContext'
import { navidromeApi } from '../services/navidromeApi'

interface LyricLine {
  time: number // Tiempo en segundos (puede ser decimal)
  text: string
}

interface LyricsPageProps {
  onClose?: () => void
}

const parseLyrics = (text: string): LyricLine[] => {
  if (!text) return []

  const lines = text.split('\n')
  const result: LyricLine[] = []

  const regex = /\[(\d+):(\d+(?:\.\d+)?)\]\s*(.*)/

  // Check if there are timestamps in the text
  const hasTimestamps = lines.some(line => regex.test(line))

  if (hasTimestamps) {
    // Parse synchronized lyrics (.lrc)
    for (const line of lines) {
      const match = line.match(regex)
      if (match) {
        const minutes = parseInt(match[1])
        const seconds = parseFloat(match[2]) // Use parseFloat to support decimals
        const time = minutes * 60 + seconds
        const text = match[3]?.trim() || ''

        if (text) {
          result.push({ time, text })
        }
      }
    }

    // Sort by time
    result.sort((a, b) => a.time - b.time)
  } else {
    // Display plain text without timestamps
    // Assign an infinite time so it won't be displayed as "synced"
    for (const line of lines) {
      if (line.trim()) {
        result.push({ time: Infinity, text: line.trim() })
      }
    }
  }

  return result
}

export default function LyricsPage({ onClose }: LyricsPageProps) {
  const playerState = usePlayerState()
  const playerProgress = usePlayerProgress()
  const playerActions = usePlayerActions()
  const [lyrics, setLyrics] = useState<LyricLine[]>([])
  const [loading, setLoading] = useState(true)
  const [currentLineIndex, setCurrentLineIndex] = useState(0)
  const currentIndexRef = useRef(0)
  const lineRefs = useRef<(HTMLDivElement | null)[]>([])

  const fetchLyrics = useCallback(async () => {
    if (playerState.currentSong) {
      try {
        setLoading(true)
        const fetchedLyrics = await navidromeApi.getLyrics(
          playerState.currentSong.artist,
          playerState.currentSong.title
        )
        setLyrics(parseLyrics(fetchedLyrics))
      } catch (error) {
        console.error('Failed to fetch lyrics', error)
        setLyrics([])
      } finally {
        setLoading(false)
      }
    }
  }, [playerState.currentSong])

  useEffect(() => {
    fetchLyrics()
  }, [fetchLyrics])

  useEffect(() => {
    if (lyrics.length === 0) return

    // Verify if lyrics have synchronization (timestamps)
    const hasSynchronizedLyrics = lyrics.some(line => line.time !== Infinity)

    if (!hasSynchronizedLyrics) {
      // If no synchronization, do nothing else
      return
    }

    // Find the current index based on progress
    let currentIndex = -1
    for (let i = 0; i < lyrics.length; i++) {
      const nextLineTime = lyrics[i + 1]?.time || Infinity
      if (playerProgress.progress >= lyrics[i].time && playerProgress.progress < nextLineTime) {
        currentIndex = i
        break
      }
    }

    if (currentIndex !== -1 && currentIndex !== currentIndexRef.current) {
      currentIndexRef.current = currentIndex
      setCurrentLineIndex(currentIndex)

      // Auto-scroll to keep the current line in the center
      if (lineRefs.current[currentIndex]) {
        // Use requestAnimationFrame to smooth the scroll
        requestAnimationFrame(() => {
          lineRefs.current[currentIndex]?.scrollIntoView({
            behavior: 'smooth',
            block: 'center',
          })
        })
      }
    }
  }, [playerProgress.progress, lyrics])

  const handleLineClick = (line: LyricLine) => {
    // Only allow click if lyrics are synchronized
    const hasSynchronizedLyrics = lyrics.some(l => l.time !== Infinity)
    if (hasSynchronizedLyrics && line.time !== Infinity) {
      playerActions.seek(line.time)
    }
  }

  if (!playerState.currentSong) {
    return (
      <div className="flex flex-col items-center justify-center h-full p-4">
        <p className="text-gray-500 dark:text-gray-400 text-lg">
          No hay ninguna canción reproduciéndose
        </p>
      </div>
    )
  }

  return (
    <div>
      {/* Header with title and close button */}
      <div className="sticky top-0 bg-gradient-to-b from-gray-100 to-transparent dark:from-gray-800 backdrop-blur-sm z-10 py-6">
        <div className="max-w-4xl mx-auto flex items-center justify-between px-8">
          <div>
            <h1 className="text-2xl font-bold text-gray-900 dark:text-white mb-1 truncate">
              {playerState.currentSong.title}
            </h1>
            <p className="text-lg text-gray-600 dark:text-gray-400 truncate">
              {playerState.currentSong.artist}
            </p>
          </div>
          {onClose && (
            <button
              onClick={onClose}
              className="p-2 bg-gray-200/50 hover:bg-gray-300/70 dark:bg-gray-700/50 dark:hover:bg-gray-600/70 rounded-full transition-colors flex-shrink-0"
              aria-label="Cerrar letras"
            >
              <svg
                className="w-6 h-6 text-gray-600 dark:text-gray-400"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            </button>
          )}
        </div>
      </div>

      <div className="px-8 pb-8">
        {loading ? (
          <div className="flex items-center justify-center h-full pt-16">
            <div className="text-center">
              <div className="inline-block animate-spin rounded-full h-12 w-12 border-b-2 border-gray-400"></div>
              <p className="mt-4 text-gray-600 dark:text-gray-400">Cargando letras...</p>
            </div>
          </div>
        ) : lyrics.length === 0 ? (
          <div className="flex items-center justify-center h-full pt-16">
            <p className="text-gray-500 dark:text-gray-400 text-lg">
              No hay letras disponibles para esta canción
            </p>
          </div>
        ) : (
          <div className="space-y-6 max-w-4xl mx-auto">
            {lyrics.map((line, index) => {
              const hasSynchronizedLyrics = lyrics.some(l => l.time !== Infinity)
              const isHighlighted = hasSynchronizedLyrics && index === currentLineIndex

              return (
                <div
                  key={index}
                  ref={el => (lineRefs.current[index] = el)}
                  onClick={() => handleLineClick(line)}
                  className={`cursor-pointer transition-all duration-300 py-2 text-5xl font-semibold ${
                    isHighlighted
                      ? 'text-gray-900 dark:text-white'
                      : hasSynchronizedLyrics && index < currentLineIndex
                        ? 'text-gray-400 dark:text-gray-600 opacity-80'
                        : 'text-gray-500 dark:text-gray-400 opacity-80'
                  }`}
                >
                  {line.text}
                </div>
              )
            })}
          </div>
        )}
      </div>
    </div>
  )
}
