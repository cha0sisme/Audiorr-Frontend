import React, { useRef, useState, useEffect, useMemo } from 'react'
import { PlayIcon } from '@heroicons/react/24/solid'
import UniversalCover from './UniversalCover'
import { useLocation } from 'react-router-dom'
import { Capacitor } from '@capacitor/core'
import { useHeroPresence } from '../contexts/HeroPresenceContext'
import { useTheme } from '../contexts/ThemeContext'

const ROOT_TABS = new Set(['/', '/artists', '/playlists', '/search', '/audiorr'])
const isNative = Capacitor.isNativePlatform()

interface PageHeroProps {
  type: 'playlist' | 'album' | 'song' | 'artist' | 'user'
  title: string
  subtitle: string
  coverImageUrl: string | null
  dominantColors: { primary: string; secondary: string; accent: string; isSolid?: boolean } | null
  
  onPlay?: () => void
  isPlaying?: boolean
  isRemote?: boolean

  metadata?: React.ReactNode
  actions?: React.ReactNode
  noBottomGap?: boolean
  widePlayButton?: boolean

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
  isExplicit,
  actions,
  noBottomGap = false,
  widePlayButton = false,
}: PageHeroProps) {
  const location = useLocation()
  const hasBackButton = isNative && !ROOT_TABS.has(location.pathname)
  const { incHero, decHero } = useHeroPresence()

  useEffect(() => {
    incHero()
    return () => decHero()
  }, [incHero, decHero])

  const [heroProgress, setHeroProgress] = useState(0)
  const [overscroll, setOverscroll] = useState(0)
  const heroRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const heroEl = heroRef.current
    if (!heroEl) return

    const scrollable = findScrollableParent(heroEl)

    const handleScroll = () => {
      const rect = heroEl.getBoundingClientRect()
      const height = rect.height || heroEl.offsetHeight || 1
      
      // Progress calculation for fading/sticky (going up)
      // We subtract the overscroll from rect.top to get the "clean" scroll position
      const scrollPos = -Math.min(0, rect.top)
      const progress = Math.min(Math.max(scrollPos / height, 0), 1)
      setHeroProgress(progress)

      // Overscroll calculation for bounce (pulling down)
      // In some browsers/scrolling modes, rect.top will be positive when overscrolling
      const os = Math.max(0, rect.top)
      setOverscroll(os)
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
    minHeight: 340,
  }


  const fadeProgress = Math.min(Math.max(heroProgress, 0), 1)
  const stickyOpacity = Math.min(Math.max((fadeProgress - 0.55) / 0.25, 0), 1)
  const heroOpacity = 1 - Math.min(fadeProgress, 0.92)
  const heroTranslate = fadeProgress * 36

  // Bounce / Overscroll effects
  const bounceScale = 1 + (overscroll / 1000)
  const bounceTranslate = overscroll * 0.5 // Content moves down slower than scroll to create depth

  const isSolid = dominantColors?.isSolid ?? false

  const combinedBackgroundStyle = {
    // Flat-color albums (Donda, Black Album, TLOP): use solid backgroundColor.
    // Complex artwork: use the multi-stop gradient as before.
    ...(isSolid && dominantColors
      ? { backgroundColor: dominantColors.primary }
      : { backgroundImage: gradientBackground }),
    backdropFilter: 'saturate(130%)',
    WebkitMaskImage: 'linear-gradient(to bottom, black 0%, black 40%, rgba(0, 0, 0, 0.9) 55%, rgba(0, 0, 0, 0.7) 70%, rgba(0, 0, 0, 0.3) 85%, transparent 100%)',
    maskImage: 'linear-gradient(to bottom, black 0%, black 40%, rgba(0, 0, 0, 0.9) 55%, rgba(0, 0, 0, 0.7) 70%, rgba(0, 0, 0, 0.3) 85%, transparent 100%)',
    opacity: heroOpacity,
    transform: `translateY(${heroTranslate + bounceTranslate}px) scale(${(1 + fadeProgress * 0.04) * bounceScale})`,
    transition: overscroll > 0 ? 'none' : 'opacity 120ms linear, transform 140ms linear',
    willChange: 'opacity, transform',
  }

  const stickyBgColor = useMemo(() => {
    if (!dominantColors) return undefined
    const c = dominantColors.primary.replace('#', '')
    const r = Math.round(parseInt(c.slice(0, 2), 16) * 0.45)
    const g = Math.round(parseInt(c.slice(2, 4), 16) * 0.45)
    const b = Math.round(parseInt(c.slice(4, 6), 16) * 0.45)
    return `rgb(${r}, ${g}, ${b})`
  }, [dominantColors])

  const buttonColors = useMemo(() => {
    if (!dominantColors || !dominantColors.primary.startsWith('#') || dominantColors.primary.length < 7) {
      return { bg: 'rgba(255,255,255,0.15)', text: '#ffffff' }
    }
    // For flat-color albums use the accent (e.g. Motomami's red on white bg).
    // For complex artwork keep using primary as before.
    const hex = (isSolid && dominantColors.accent?.startsWith('#'))
      ? dominantColors.accent
      : dominantColors.primary
    const r = parseInt(hex.slice(1, 3), 16)
    const g = parseInt(hex.slice(3, 5), 16)
    const b = parseInt(hex.slice(5, 7), 16)
    
    // Aumentamos la luminosidad para que sea un color plano vibrante (estilo Apple Music)
    // En lugar de multiplicar por 0.58 (oscurecer mucho), usamos un factor más alto o incluso saturamos.
    const dr = Math.min(255, Math.round(r * 1.1))
    const dg = Math.min(255, Math.round(g * 1.1))
    const db = Math.min(255, Math.round(b * 1.1))
    
    // Calculamos el brillo del color resultante para decidir si el texto es blanco o negro
    const brightness = (dr * 299 + dg * 587 + db * 114) / 1000
    
    return {
      bg: `rgb(${dr}, ${dg}, ${db})`,
      text: brightness > 180 ? '#000000' : '#ffffff',
    }
  }, [dominantColors])

  const { isDark } = useTheme()

  // Update iOS notch / browser chrome color
  useEffect(() => {
    const defaultColor = isDark ? '#121212' : '#f9fafb'
    const color = stickyBgColor ?? defaultColor
    let meta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]')
    if (!meta) {
      meta = document.createElement('meta')
      meta.setAttribute('name', 'theme-color')
      document.head.appendChild(meta)
    }
    meta.setAttribute('content', color)
    return () => { 
      meta?.setAttribute('content', defaultColor)
    }
  }, [stickyBgColor, isDark])



  // Ya no necesitamos márgenes negativos agresivos porque NavigationStack 
  // ahora neutraliza el padding del contenedor cuando hay un Hero.
  // Pero en móvil, queremos asegurarnos de que el hero llegue al top absoluto (atrás del notch).
  const sectionWrapperStyle = isNative
    ? { marginTop: '0px' }
    : undefined

  // El sticky header siempre se ancla en top-0.
  // En iOS nativo, env(safe-area-inset-top) nos da el offset del notch.
  const stickyTopClass = 'top-0'

  return (
    <>
      <div className={`sticky ${stickyTopClass} z-40 h-0 pointer-events-none`}>
        {/* Este contenedor absoluto ya empieza en top-0 del scroll container (que es top-0 de la pantalla) */}
        <div 
          className="absolute top-0 left-0 right-0 pointer-events-none transition-opacity duration-200"
          style={{
            opacity: stickyOpacity,
            backgroundColor: stickyBgColor ?? 'rgb(10, 14, 25)',
            backdropFilter: 'blur(24px) saturate(1.8)',
            WebkitBackdropFilter: 'blur(24px) saturate(1.8)',
            borderBottom: '1px solid rgba(255, 255, 255, 0.08)',
            // Importante: el background debe cubrir el notch
            paddingTop: isNative ? 'env(safe-area-inset-top)' : '0px',
            visibility: stickyOpacity > 0 ? 'visible' : 'hidden',
          }}
        >
          {/* El contenido real del header pegajoso */}
          <div
            className={`flex items-center gap-3 px-4 sm:px-6 lg:px-10 h-[60px] ${hasBackButton ? 'pl-[58px] sm:pl-[58px] lg:pl-[58px]' : ''}`}
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

      <div className={`${noBottomGap ? ' -mb-14' : ''}`} style={sectionWrapperStyle}>
      <section ref={heroRef} className="relative overflow-hidden rounded-none md:rounded-3xl text-white !mt-0" style={heroSectionStyle}>
        <div
          className="absolute inset-0"
          style={combinedBackgroundStyle}
        >
          {/* Blurred cover art — only for complex artwork; flat-color albums use the solid bg alone */}
          {!isSolid && (type !== 'user' && coverImageUrl) && (
            <img
              src={coverImageUrl}
              alt={title}
              className="absolute inset-0 h-full w-full object-cover blur-[120px]"
              aria-hidden="true"
            />
          )}
          <div className="absolute inset-0 bg-gradient-to-br from-black/40 via-black/25 to-black/10" />
          {/* Radial color accents — only for gradient (non-solid) albums */}
          {!isSolid && dominantColors && (
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
          className="relative flex flex-col md:flex-row items-center md:items-end gap-3 md:gap-6 px-5 md:px-8 lg:px-10 pt-6 pb-9 md:pt-14 md:pb-9"
          style={{
            paddingTop: isNative ? 'calc(env(safe-area-inset-top) + 24px)' : '3.5rem',
            opacity: heroOpacity,
            transform: `translateY(${heroTranslate * 0.6 + bounceTranslate}px)`,
            transition: overscroll > 0 ? 'none' : 'opacity 120ms linear, transform 140ms linear',
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
            {(onPlay || actions) && (
              <div className="mt-5 flex items-center gap-3 justify-center md:justify-start">
                {onPlay && (
                  <button
                    onClick={onPlay}
                    className={`flex-shrink-0 rounded-full flex items-center justify-center shadow-lg active:scale-95 transition-transform focus:outline-none select-none ${widePlayButton ? 'h-11 px-6 gap-2' : 'w-12 h-12'}`}
                    style={{ backgroundColor: buttonColors.bg, color: buttonColors.text }}
                    aria-label={isPlaying ? 'Pausar' : 'Reproducir'}
                  >
                    {isPlaying ? (
                      <>
                        <svg className={`${widePlayButton ? 'w-5 h-5' : 'w-6 h-6'}`} fill="currentColor" viewBox="0 0 24 24">
                          <path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z" />
                        </svg>
                        {widePlayButton && (
                          <span className="font-bold text-sm tracking-tight">Pausar</span>
                        )}
                      </>
                    ) : (
                      <>
                        <PlayIcon className={`${widePlayButton ? 'w-5 h-5' : 'w-7 h-7 -translate-x-[1px]'}`} />
                        {widePlayButton && (
                          <span className="font-bold text-sm tracking-tight">Reproducir</span>
                        )}
                      </>
                    )}
                  </button>
                )}
                {actions}
              </div>
            )}
          </div>
        </div>
      </section>
      </div>
    </>
  )
}
