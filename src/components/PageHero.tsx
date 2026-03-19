import React, { useRef, useState, useEffect, useMemo } from 'react'
import { PlayIcon } from '@heroicons/react/24/solid'
import UniversalCover from './UniversalCover'
import { useLocation } from 'react-router-dom'
import { Capacitor } from '@capacitor/core'
import { useHeroPresence } from '../contexts/HeroPresenceContext'

const ROOT_TABS = new Set(['/', '/artists', '/playlists', '/search', '/audiorr'])
const isNative = Capacitor.isNativePlatform()

interface PageHeroProps {
  type: 'playlist' | 'album' | 'song' | 'artist' | 'user'
  title: string
  subtitle: string
  coverImageUrl: string | null
  dominantColors: { primary: string; secondary: string; accent: string } | null
  
  onPlay?: () => void
  isPlaying?: boolean
  isRemote?: boolean
  
  metadata?: React.ReactNode
  
  // Cover config
  coverArtId?: string
  artistName?: string
  customCoverUrl?: string | null
  isGeneratingCover?: boolean
  onCoverClick?: () => void
  onImageLoaded?: (url: string | null) => void
  backgroundColor?: string
  initial?: string
  isExplicit?: boolean
}

function findScrollableParent(element: HTMLElement | null): HTMLElement | Window {
  if (!element) return window
  let parent: HTMLElement | null = element.parentElement
  while (parent) {
    const style = window.getComputedStyle(parent)
    const overflowY = style.overflowY
    if (overflowY === 'auto' || overflowY === 'scroll') {
      return parent
    }
    parent = parent.parentElement
  }
  return window
}

export default function PageHero({
  type,
  title,
  subtitle,
  coverImageUrl,
  dominantColors,
  onPlay,
  isPlaying,
  isRemote,
  metadata,
  coverArtId,
  artistName,
  customCoverUrl,
  isGeneratingCover,
  onCoverClick,
  onImageLoaded,
  backgroundColor,
  initial,
  isExplicit
}: PageHeroProps) {
  const location = useLocation()
  const hasBackButton = isNative && !ROOT_TABS.has(location.pathname)
  const { setHeroPresent } = useHeroPresence()

  useEffect(() => {
    setHeroPresent(true)
    return () => setHeroPresent(false)
  }, [setHeroPresent])

  const [heroProgress, setHeroProgress] = useState(0)
  const heroRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const heroEl = heroRef.current
    if (!heroEl) return

    const scrollable = findScrollableParent(heroEl)

    const handleScroll = () => {
      const rect = heroEl.getBoundingClientRect()
      const height = rect.height || heroEl.offsetHeight || 1
      const progress = Math.min(Math.max((0 - rect.top) / height, 0), 1)
      setHeroProgress(progress)
    }

    handleScroll()

    const target = scrollable instanceof Window ? window : scrollable
    target.addEventListener('scroll', handleScroll, { passive: true })
    if (scrollable !== window) {
      window.addEventListener('scroll', handleScroll, { passive: true })
    }

    const resizeObserver = new ResizeObserver(() => handleScroll())
    resizeObserver.observe(heroEl)

    return () => {
      target.removeEventListener('scroll', handleScroll)
      if (scrollable !== window) {
        window.removeEventListener('scroll', handleScroll)
      }
      resizeObserver.disconnect()
    }
  }, [title])

  const paletteGradient = useMemo(() => {
    if (!dominantColors) return null
    const basePrimary = dominantColors.primary
    const baseSecondary = dominantColors.secondary

    const mix = (color: string, alpha: number) => {
      if (color.startsWith('hsl')) {
        return color.replace('hsl(', 'hsla(').replace(')', `, ${alpha})`)
      }
      const value = color.replace('#', '')
      const r = parseInt(value.substring(0, 2), 16)
      const g = parseInt(value.substring(2, 4), 16)
      const b = parseInt(value.substring(4, 6), 16)
      return `rgba(${r}, ${g}, ${b}, ${alpha})`
    }

    return `linear-gradient(140deg, ${mix(basePrimary, 0.78)} 0%, ${mix(baseSecondary, 0.74)} 100%)`
  }, [dominantColors])

  const fallbackGradient = 'linear-gradient(140deg, rgba(38, 48, 77, 0.78) 0%, rgba(20, 31, 54, 0.74) 100%)'
  const gradientBackground = paletteGradient ?? fallbackGradient

  const heroSectionStyle = {
    backgroundImage: gradientBackground,
    minHeight: 340,
    backdropFilter: 'saturate(130%)',
  }

  const fadeProgress = Math.min(Math.max(heroProgress, 0), 1)
  const stickyOpacity = Math.min(Math.max((fadeProgress - 0.55) / 0.25, 0), 1)
  const heroOpacity = 1 - Math.min(fadeProgress, 0.92)
  const heroTranslate = fadeProgress * 36

  const stickyBgColor = useMemo(() => {
    if (!dominantColors) return undefined
    const c = dominantColors.primary.replace('#', '')
    const r = Math.round(parseInt(c.slice(0, 2), 16) * 0.45)
    const g = Math.round(parseInt(c.slice(2, 4), 16) * 0.45)
    const b = Math.round(parseInt(c.slice(4, 6), 16) * 0.45)
    return `rgb(${r}, ${g}, ${b})`
  }, [dominantColors])

  // Update iOS notch / browser chrome color
  useEffect(() => {
    const color = stickyBgColor ?? '#0a0e19'
    let meta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]')
    if (!meta) {
      meta = document.createElement('meta')
      meta.setAttribute('name', 'theme-color')
      document.head.appendChild(meta)
    }
    meta.setAttribute('content', color)
    return () => { meta?.setAttribute('content', '#0a0e19') }
  }, [stickyBgColor])

  const stickyStyle = useMemo(() => {
    const visible = stickyOpacity > 0.05
    const eased = Math.min(Math.max((stickyOpacity - 0.05) / 0.95, 0), 1)
    if (!visible) {
      return {
        opacity: 0,
        transform: 'translateY(-24px)',
        pointerEvents: 'none' as const,
        visibility: 'hidden' as const,
      }
    }
    const padding = 10 + eased * 6
    return {
      opacity: stickyOpacity,
      transform: 'translateY(0px)',
      pointerEvents: 'auto' as const,
      visibility: 'visible' as const,
      backgroundColor: stickyBgColor ?? 'rgb(10, 14, 25)',
      backgroundImage: 'linear-gradient(140deg, rgba(255,255,255,0.06) 0%, rgba(0,0,0,0.10) 100%)',
      borderBottom: '1px solid rgba(255, 255, 255, 0.06)',
      paddingTop: `${padding}px`,
      paddingBottom: `${padding}px`,
      backdropFilter: 'blur(20px) saturate(150%)',
    }
  }, [stickyOpacity, stickyBgColor])

  // Negative margin para cancelar el padding del RoutesContainer y quedar flush al top.
  // IMPORTANTE: solo se aplica al <section>, no al sticky div.
  // El sticky div debe ser hermano en el Fragment para que su rango de sticking
  // sea el contenedor de la página completa (no solo la altura del hero).
  // Usamos style inline (no className) para que gane sobre space-y-* del componente padre,
  // que tiene mayor especificidad CSS y sobreescribiría un -mt-[60px] via className.
  const sectionWrapperStyle = hasBackButton
    ? { marginTop: '-60px' }  // cancela p-4 (16px) + spacer (44px) → hero flush al top
    : undefined

  // El sticky header siempre se ancla en top-0.
  // El botón de atrás (z-9990) flota encima gracias a su z-index;
  // el pl-[100px] del header evita que el título se solape con él.
  const stickyTopClass = 'top-0'

  return (
    <>
      <div className={`sticky ${stickyTopClass} z-40 h-0 -mx-4 md:-mx-6 lg:-mx-8 pointer-events-none`}>
        <div className="absolute top-0 left-0 right-0 pointer-events-none">
          <div
            className={`flex items-center gap-3 px-4 sm:px-6 lg:px-10 ${hasBackButton ? 'pl-[100px] sm:pl-[100px] lg:pl-[100px]' : ''}`}
            style={stickyStyle}
          >
            <div className={`flex h-10 w-10 items-center justify-center overflow-hidden shadow-md bg-slate-800/60 ${type === 'artist' || type === 'user' ? 'rounded-full' : 'rounded-md'}`}>
              {(type !== 'user' && coverImageUrl) ? (
                <img src={coverImageUrl} alt={title} className="h-full w-full object-cover" />
              ) : (
                <div 
                  className="h-full w-full flex items-center justify-center text-[10px] text-white/100"
                  style={backgroundColor ? { backgroundColor } : undefined}
                >
                  {initial || title.charAt(0).toUpperCase()}
                </div>
              )}
            </div>
            <div className="min-w-0 flex-1">
              <p className="text-[10px] md:text-xs uppercase tracking-[0.3em] text-white/75">{subtitle}</p>
              <div className="flex items-center gap-2 overflow-hidden">
                <p className="font-title truncate text-white">{title}</p>
                {isExplicit && (
                  <span className="flex-shrink-0 px-1 py-0 rounded bg-white/20 text-white text-[8px] border border-white/20">
                    E
                  </span>
                )}
              </div>
            </div>
            {onPlay && (
              <button
                onClick={onPlay}
                className={`hidden sm:flex p-2.5 items-center justify-center rounded-full ${isRemote ? 'bg-green-500 hover:bg-green-400' : 'bg-blue-500 dark:bg-gray-700 hover:bg-blue-400 dark:hover:bg-gray-600'} text-white shadow-sm transition pointer-events-auto active:scale-95`}
                aria-label={isPlaying ? "Pausar" : "Reproducir"}
              >
                {isPlaying ? (
                  <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
                    <path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z" />
                  </svg>
                ) : (
                  <PlayIcon className="w-6 h-6 -translate-x-[1px]" />
                )}
              </button>
            )}
          </div>
        </div>
      </div>

      <div className="-mt-4 md:-mt-6 lg:-mt-8" style={sectionWrapperStyle}>
      <section ref={heroRef} className="relative overflow-hidden rounded-none md:rounded-3xl text-white !mt-0 -mx-4 md:-mx-6 lg:-mx-8" style={heroSectionStyle}>
        <div
          className="absolute inset-0"
          style={{
            opacity: heroOpacity,
            transform: `translateY(${heroTranslate}px) scale(${1 + fadeProgress * 0.04})`,
            transition: 'opacity 120ms linear, transform 140ms linear',
            willChange: 'opacity, transform',
          }}
        >
          {(type !== 'user' && coverImageUrl) && (
            <img
              src={coverImageUrl}
              alt={title}
              className="absolute inset-0 h-full w-full object-cover blur-[120px]"
              aria-hidden="true"
            />
          )}
          <div className="absolute inset-0 bg-gradient-to-br from-black/40 via-black/25 to-black/10" />
          {dominantColors && (
            <>
              <div
                className="absolute inset-0 opacity-40"
                style={{
                  background: `radial-gradient(circle at top right, ${dominantColors.accent}66, transparent 55%)`,
                }}
              />
              <div
                className="absolute inset-0 opacity-25"
                style={{
                  background: `radial-gradient(circle at bottom left, ${dominantColors.secondary}66, transparent 60%)`,
                }}
              />
            </>
          )}
        </div>

        <div
          className="relative flex flex-col md:flex-row items-center md:items-end gap-3 md:gap-6 px-5 md:px-8 lg:px-10 pt-6 pb-6 md:pt-14 md:pb-10"
          style={{
            opacity: heroOpacity,
            transform: `translateY(${heroTranslate * 0.6}px)`,
            transition: 'opacity 120ms linear, transform 140ms linear',
            willChange: 'opacity, transform',
          }}
        >
          <UniversalCover
            type={type}
            coverArtId={coverArtId}
            artistName={artistName}
            alt={title}
            customCoverUrl={customCoverUrl}
            isLoading={isGeneratingCover}
            onClick={onCoverClick}
            context="hero"
            onImageLoaded={onImageLoaded}
            backgroundColor={backgroundColor}
            initial={initial}
          />
          <div className="flex-1 min-w-0 text-center md:text-left">
            <p className="uppercase text-[10px] md:text-xs tracking-[0.2em] text-white/90">{subtitle}</p>
            <h1 className="font-title mt-2 md:mt-4 text-3xl md:text-6xl lg:text-7xl leading-none break-words flex flex-wrap items-center justify-center md:justify-start gap-x-4" style={{ letterSpacing: '-0.04em' }}>
              {title}
              {isExplicit && (
                <span className="inline-flex items-center justify-center px-2 py-1 md:px-3 md:py-1.5 bg-white/20 text-white text-xs md:text-sm rounded-md border border-white/30 backdrop-blur-sm self-center mt-1 md:mt-2">
                  E
                </span>
              )}
            </h1>
            {metadata}
          </div>
        </div>
      </section>
      </div>
    </>
  )
}
