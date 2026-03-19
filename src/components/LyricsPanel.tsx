import { useRef, useEffect, useCallback } from 'react'
import { motion, AnimatePresence } from 'framer-motion'

export interface LyricLine {
  time: number
  text: string
}

interface LyricsPanelProps {
  isOpen: boolean
  lyrics: LyricLine[]
  loadingLyrics: boolean
  currentLineIndex: number
  onSeek: (time: number) => void
}

export default function LyricsPanel({
  isOpen,
  lyrics,
  loadingLyrics,
  currentLineIndex,
  onSeek,
}: LyricsPanelProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const lineRefs = useRef<(HTMLDivElement | null)[]>([])
  const userScrollingRef = useRef(false)
  const scrollResumeTimer = useRef<ReturnType<typeof setTimeout>>()

  const handleScroll = useCallback(() => {
    userScrollingRef.current = true
    clearTimeout(scrollResumeTimer.current)
    scrollResumeTimer.current = setTimeout(() => { userScrollingRef.current = false }, 3000)
  }, [])

  // Auto-scroll para mantener la línea activa centrada
  useEffect(() => {
    if (userScrollingRef.current) return
    const container = containerRef.current
    const lineEl = lineRefs.current[currentLineIndex]
    if (!container || !lineEl) return
    container.scrollTo({
      top: lineEl.offsetTop - container.clientHeight / 2 + lineEl.clientHeight / 2,
      behavior: 'smooth',
    })
  }, [currentLineIndex])

  const hasSynced = lyrics.some(l => l.time !== Infinity)

  return (
    <AnimatePresence>
      {isOpen && (
        <motion.div
          initial={{ height: 0, opacity: 0 }}
          animate={{ height: 136, opacity: 1 }}
          exit={{ height: 0, opacity: 0 }}
          transition={{ duration: 0.35, ease: [0.4, 0, 0.2, 1] }}
          className="flex-shrink-0 overflow-hidden"
        >
          {loadingLyrics ? (
            <div className="h-full flex items-center justify-center">
              <p className="text-white/30 text-sm">Cargando letras…</p>
            </div>
          ) : (
            <div
              ref={containerRef}
              className="h-full overflow-y-auto overscroll-contain px-7"
              style={{
                maskImage: 'linear-gradient(to bottom, transparent 0%, black 20%, black 80%, transparent 100%)',
                WebkitMaskImage: 'linear-gradient(to bottom, transparent 0%, black 20%, black 80%, transparent 100%)',
              }}
              onScroll={handleScroll}
            >
              <div style={{ paddingTop: 48, paddingBottom: 48 }}>
                {lyrics.map((line, index) => {
                  const dist = Math.abs(index - currentLineIndex)
                  const isActive = hasSynced && dist === 0
                  const opacity = dist === 0 ? 1 : dist === 1 ? 0.38 : dist === 2 ? 0.18 : 0.08
                  return (
                    <div
                      key={index}
                      ref={el => { lineRefs.current[index] = el }}
                      onClick={() => {
                        if (hasSynced && line.time !== Infinity) onSeek(line.time)
                      }}
                      className="cursor-pointer select-none font-bold leading-snug tracking-tight text-white transition-all duration-300"
                      style={{
                        opacity,
                        fontSize: isActive ? '1.45rem' : '1.3rem',
                        marginBottom: '0.6rem',
                        textShadow: isActive ? '0 0 24px rgba(255,255,255,0.2)' : 'none',
                      }}
                    >
                      {line.text}
                    </div>
                  )
                })}
              </div>
            </div>
          )}
        </motion.div>
      )}
    </AnimatePresence>
  )
}
