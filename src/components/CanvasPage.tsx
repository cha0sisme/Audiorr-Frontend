import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import Canvas from './Canvas'
import { usePlayerState } from '../contexts/PlayerContext'
import { ArtistLinks } from './ArtistLinks'

type MarqueeAnimationStyle = CSSProperties & { '--marquee-distance'?: string }

const CloseIcon = ({ className }: { className?: string }) => (
  <svg
    className={className}
    width="24"
    height="24"
    viewBox="0 0 24 24"
    fill="none"
    xmlns="http://www.w3.org/2000/svg"
  >
    <path
      d="M10.5 12L17 12"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
    <path
      d="M14.5 9L17 12"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
    <path
      d="M14.5 15L17 12"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
    <path
      d="M17 17C17 19.2091 15.2091 20 13 20H10C7.79086 20 6 18.2091 6 16V8C6 5.79086 7.79086 4 10 4H13C15.2091 4 17 4.79086 17 7"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </svg>
)

interface CanvasPageProps {
  onClose?: () => void
  canvasUrl: string | null
  isLoading: boolean
  songTitle?: string
  songArtist?: string
}

function normalizeArtistKey(value: unknown): string {
  if (!value) return ''
  if (typeof value === 'string') return value
  if (Array.isArray(value)) {
    return value
      .map(item => {
        if (!item) return ''
        if (typeof item === 'string') return item
        if (typeof item === 'object' && 'name' in (item as Record<string, unknown>)) {
          const name = (item as { name?: unknown }).name
          return typeof name === 'string' ? name : ''
        }
        return String(item)
      })
      .filter(Boolean)
      .join('|')
  }
  if (typeof value === 'object' && 'name' in (value as Record<string, unknown>)) {
    const name = (value as { name?: unknown }).name
    if (typeof name === 'string') {
      return name
    }
  }
  return String(value)
}

function MarqueeText({
  children,
  className = '',
  containerClassName = '',
  isActive,
  dependencyKey = '',
}: {
  children: ReactNode
  className?: string
  containerClassName?: string
  isActive: boolean
  dependencyKey?: string
}) {
  const containerRef = useRef<HTMLDivElement>(null)
  const contentRef = useRef<HTMLSpanElement>(null)
  const [isOverflowing, setIsOverflowing] = useState(false)
  const [scrollDistance, setScrollDistance] = useState(0)
  const [animationDuration, setAnimationDuration] = useState(16)

  useEffect(() => {
    const container = containerRef.current
    const content = contentRef.current
    if (!container || !content) {
      setIsOverflowing(false)
      setScrollDistance(0)
      return
    }

    const updateOverflow = () => {
      if (!container || !content) return
      const containerWidth = container.clientWidth
      const contentWidth = content.scrollWidth
      const overflowAmount = Math.max(0, contentWidth - containerWidth)
      const hasOverflow = overflowAmount > 1
      setIsOverflowing(hasOverflow)
      if (hasOverflow) {
        setScrollDistance(overflowAmount)
        const baseSpeed = 28
        const duration = Math.min(18, Math.max(6, overflowAmount / baseSpeed))
        setAnimationDuration(duration)
      } else {
        setScrollDistance(0)
      }
    }

    const frameId = window.requestAnimationFrame(updateOverflow)

    let resizeObserver: ResizeObserver | null = null
    if (typeof ResizeObserver !== 'undefined') {
      resizeObserver = new ResizeObserver(updateOverflow)
      resizeObserver.observe(container)
      resizeObserver.observe(content)
    }

    window.addEventListener('resize', updateOverflow)

    return () => {
      window.cancelAnimationFrame(frameId)
      if (resizeObserver) {
        resizeObserver.disconnect()
      }
      window.removeEventListener('resize', updateOverflow)
    }
  }, [dependencyKey])

  const hasNoVisibleContent =
    children === null ||
    children === undefined ||
    (typeof children === 'string' && children.trim() === '')

  const containerStyle = isOverflowing
    ? ({
        maskImage: 'linear-gradient(to right, transparent, black 6%, black 94%, transparent)',
        WebkitMaskImage: 'linear-gradient(to right, transparent, black 6%, black 94%, transparent)',
        transition: 'mask-image 200ms ease, -webkit-mask-image 200ms ease',
      } satisfies CSSProperties)
    : undefined

  const marqueeStyle = isOverflowing
    ? ({
        animation: `canvas-marquee-bounce ${animationDuration}s ease-in-out infinite alternate`,
        animationPlayState: isActive ? 'running' : 'paused',
        transform: 'translateX(0)',
        '--marquee-distance': `-${scrollDistance}px`,
      } satisfies MarqueeAnimationStyle)
    : undefined

  if (hasNoVisibleContent) {
    return null
  }

  return (
    <div
      ref={containerRef}
      className={`relative overflow-hidden ${containerClassName}`.trim()}
      style={containerStyle}
    >
      <div
        className={`inline-flex items-center ${isOverflowing ? 'will-change-transform' : ''}`}
        style={marqueeStyle}
      >
        <span ref={contentRef} className={className}>
          {children}
        </span>
      </div>
    </div>
  )
}

export default function CanvasPage({
  onClose,
  canvasUrl,
  isLoading,
  songTitle,
  songArtist,
}: CanvasPageProps) {
  const playerState = usePlayerState()
  const [isHovering, setIsHovering] = useState(false)
  const [isCanvasHovering, setIsCanvasHovering] = useState(false)

  // Cerrar con Escape
  useEffect(() => {
    const handleEscape = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && onClose) {
        onClose()
      }
    }

    document.addEventListener('keydown', handleEscape)
    return () => document.removeEventListener('keydown', handleEscape)
  }, [onClose])

  const displayTitle = songTitle || playerState.currentSong?.title
  const displayArtist = songArtist || playerState.currentSong?.artist

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
    <div
      className="relative flex flex-col h-full overflow-hidden"
      onMouseEnter={() => setIsCanvasHovering(true)}
      onMouseLeave={() => setIsCanvasHovering(false)}
    >
      {/* Canvas de fondo - ocupa todo el espacio */}
      <div className="absolute inset-0">
        {isLoading ? (
          <div className="w-full h-full bg-gray-200 dark:bg-gray-700 flex items-center justify-center">
            <div className="text-center">
              <div className="inline-block w-8 h-8 border-2 border-gray-400 dark:border-gray-500 border-t-transparent rounded-full animate-spin"></div>
              <p className="mt-3 text-xs text-gray-600 dark:text-gray-400">Cargando...</p>
            </div>
          </div>
        ) : canvasUrl ? (
          <Canvas canvasUrl={canvasUrl} isLoading={false} className="w-full h-full" />
        ) : (
          <div className="w-full h-full bg-gray-200 dark:bg-gray-700 flex items-center justify-center">
            <p className="text-gray-500 dark:text-gray-400 text-sm text-center px-4">
              No hay Canvas disponible
            </p>
          </div>
        )}
      </div>

      {/* Overlay sutil con título y botón de cerrar */}
      <div
        className="relative z-10 flex-shrink-0 bg-gradient-to-b from-black/35 via-black/18 to-transparent px-4 sm:px-6 py-3 sm:py-4 transition-colors"
        onMouseEnter={() => setIsHovering(true)}
        onMouseLeave={() => setIsHovering(false)}
      >
        <div className="flex items-center justify-between gap-3 sm:gap-4">
          <div className="flex-1 min-w-0">
            {playerState.currentSong?.id ? (
              <Link
                to={`/songs/${playerState.currentSong.id}`}
                className="group block"
                onClick={e => {
                  // Si el usuario hace Ctrl+Click o Cmd+Click, abrir en nueva pestaña
                  // sino, cerrar el Canvas cuando navegue
                  if (!e.ctrlKey && !e.metaKey && onClose) {
                    onClose()
                  }
                }}
              >
                <MarqueeText
                  dependencyKey={displayTitle || ''}
                  isActive={isHovering || isCanvasHovering}
                  containerClassName="w-full"
                  className="inline-flex text-xl sm:text-3xl font-semibold text-white leading-tight transition-colors group-hover:text-white whitespace-nowrap"
                >
                  {displayTitle}
                </MarqueeText>
              </Link>
            ) : (
              <div className="block">
                <MarqueeText
                  dependencyKey={displayTitle || ''}
                  isActive={isHovering || isCanvasHovering}
                  containerClassName="w-full"
                  className="inline-flex text-xl sm:text-3xl font-semibold text-white leading-tight transition-colors whitespace-nowrap"
                >
                  {displayTitle}
                </MarqueeText>
              </div>
            )}
            {(() => {
              const artistDependencyKey = normalizeArtistKey(displayArtist)
              if (playerState.currentSong?.artist) {
                return (
                  <div className="mt-1">
                    <MarqueeText
                      dependencyKey={artistDependencyKey}
                      isActive={isHovering || isCanvasHovering}
                      containerClassName="w-full"
                      className="inline-flex text-sm sm:text-lg text-white/90 transition-colors group-hover:text-white whitespace-nowrap"
                    >
                      <ArtistLinks
                        artists={playerState.currentSong.artist}
                        className="text-white/90 hover:text-white transition-colors"
                      />
                    </MarqueeText>
                  </div>
                )
              }

              if (typeof displayArtist === 'string' && displayArtist.trim() !== '') {
                return (
                  <div className="mt-1">
                    <MarqueeText
                      dependencyKey={artistDependencyKey}
                      isActive={isHovering || isCanvasHovering}
                      containerClassName="w-full"
                      className="inline-flex text-sm sm:text-lg text-white/90 transition-colors whitespace-nowrap"
                    >
                      {displayArtist}
                    </MarqueeText>
                  </div>
                )
              }

              return null
            })()}
          </div>
          {onClose && (
            <button
              onClick={onClose}
              className={`ml-2 p-1.5 sm:p-2 text-white/80 hover:text-white transition-all duration-300 ease-out flex-shrink-0 touch-manipulation rounded-full bg-white/10 hover:bg-white/15 backdrop-blur-sm ${
                isHovering || isCanvasHovering
                  ? 'opacity-100 translate-x-0 pointer-events-auto'
                  : 'opacity-0 -translate-x-2 pointer-events-none'
              }`}
              aria-label="Cerrar Canvas"
            >
              <CloseIcon className="w-4 h-4 sm:w-5 sm:h-5" />
            </button>
          )}
        </div>
      </div>
    </div>
  )
}
