import React, { useState, useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import { motion, AnimatePresence } from 'framer-motion'
import { LyricLine } from './LyricsPanel'
import { usePlayerState, usePlayerProgress, usePlayerActions } from '../contexts/PlayerContext'
import { useConnect } from '../hooks/useConnect'
import { navidromeApi } from '../services/navidromeApi'
import SongContextMenu from './SongContextMenu'
import { useDominantColors } from '../hooks/useDominantColors'
import AlbumCover from './AlbumCover'
import Canvas from './Canvas'
import { SpeakerWaveIcon, SpeakerXMarkIcon } from '@heroicons/react/24/solid'
import { DevicePicker } from './DevicePicker'

const QueueIcon = ({ className }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="currentColor" xmlns="http://www.w3.org/2000/svg">
    <path d="M22,4H2A1,1,0,0,0,1,5v6a1,1,0,0,0,1,1H22a1,1,0,0,0,1-1V5A1,1,0,0,0,22,4Zm-1,6H3V6H21Zm2,5a1,1,0,0,1-1,1H2a1,1,0,0,1,0-2H22A1,1,0,0,1,23,15Zm0,4a1,1,0,0,1-1,1H2a1,1,0,0,1,0-2H22A1,1,0,0,1,23,19Z" />
  </svg>
)

// ── Helpers ──────────────────────────────────────────────────────────────────

function getArtistString(artist: unknown): string {
  if (!artist) return ''
  if (Array.isArray(artist)) {
    return (artist as ({ name?: unknown } | string)[])
      .map(a => (typeof a === 'object' && a !== null && 'name' in a ? String(a.name) : String(a)))
      .join(', ')
  }
  return String(artist)
}

function parseLyrics(text: string): LyricLine[] {
  if (!text) return []
  const lines = text.split('\n')
  const result: LyricLine[] = []
  const regex = /\[(\d+):(\d+(?:\.\d+)?)\]\s*(.*)/
  const hasTimestamps = lines.some(line => regex.test(line))
  if (hasTimestamps) {
    for (const line of lines) {
      const match = line.match(regex)
      if (match) {
        const time = parseInt(match[1]) * 60 + parseFloat(match[2])
        const txt = match[3]?.trim() || ''
        if (txt) result.push({ time, text: txt })
      }
    }
    result.sort((a, b) => a.time - b.time)
  } else {
    for (const line of lines) {
      if (line.trim()) result.push({ time: Infinity, text: line.trim() })
    }
  }
  return result
}

// ── Component ─────────────────────────────────────────────────────────────────

interface NowPlayingViewerProps {
  isOpen: boolean
  onClose: () => void
  canvasUrl: string | null
  isLoadingCanvas: boolean
  onShowQueue: () => void
}

export default function NowPlayingViewer({
  isOpen,
  onClose,
  canvasUrl,
  isLoadingCanvas,
  onShowQueue,
}: NowPlayingViewerProps) {
  const playerState = usePlayerState()
  const playerProgress = usePlayerProgress()
  const playerActions = usePlayerActions()

  const [lyrics, setLyrics] = useState<LyricLine[]>([])
  const [loadingLyrics, setLoadingLyrics] = useState(false)
  const [currentLineIndex, setCurrentLineIndex] = useState(0)
  const currentIndexRef = useRef(0)
  const lineRefs = useRef<(HTMLDivElement | null)[]>([])
  const scrollContainerRef = useRef<HTMLDivElement>(null)
  const lyricsBoxRef = useRef<HTMLDivElement>(null)
  const userScrollingLyricsRef = useRef(false)
  const lyricsScrollTimer = useRef<ReturnType<typeof setTimeout>>()
  // Evitar seek accidental al terminar de scrollear dentro del recuadro
  const lyricsJustScrolledRef = useRef(false)
  // Scroll del contenedor principal (sección player ↔ letras)
  const userScrollingRef = useRef(false)
  const scrollResumeTimer = useRef<ReturnType<typeof setTimeout>>()
  // Context menu state
  const [showMenu, setShowMenu] = useState(false)

  const { isConnected, activeDeviceId, currentDeviceId, sendRemoteCommand, remotePlaybackState, devices } = useConnect()
  const isRemote = isConnected && activeDeviceId && activeDeviceId !== currentDeviceId
  const activeDevice = devices.find(d => d.id === activeDeviceId)

  // Usar la canción del dispositivo remoto si estamos en modo controlador
  const remoteSong = isRemote && remotePlaybackState
    ? remotePlaybackState.queue?.find(s => s.id === remotePlaybackState.trackId) ?? null
    : null
  const currentSong = isRemote ? (remoteSong || playerState.currentSong) : playerState.currentSong
  const artistStr = getArtistString(currentSong?.artist)
  const coverUrl = currentSong?.coverArt ? navidromeApi.getCoverUrl(currentSong.coverArt, 2000) : null
  const hasCanvas = !!canvasUrl

  const isPlaying = isRemote ? (remotePlaybackState?.playing ?? false) : playerState.isPlaying
  const canGoPrevious = currentSong !== null
  const canGoNext = isRemote
    ? (remotePlaybackState?.queue?.length || 0) > 0
    : playerState.currentSong !== null &&
      playerState.queue.findIndex(s => s.id === playerState.currentSong?.id) < playerState.queue.length - 1

  const handlePrevious = () => isRemote ? sendRemoteCommand('previous', null, activeDeviceId) : playerActions.previous()
  const handleNext = () => isRemote ? sendRemoteCommand('next', null, activeDeviceId) : playerActions.next()
  const handleTogglePlayPause = () => isRemote
    ? sendRemoteCommand(isPlaying ? 'pause' : 'play', null, activeDeviceId)
    : playerActions.togglePlayPause()

  // Dominant color from album art for play button tint
  const colors = useDominantColors(hasCanvas ? null : coverUrl)
  const accentColor = colors?.accent ?? null
  // Si el color de acento es muy claro (portadas blancas), el icono debe ser oscuro
  const isLightAccent = accentColor
    ? (parseInt(accentColor.slice(1, 3), 16) * 0.299 +
       parseInt(accentColor.slice(3, 5), 16) * 0.587 +
       parseInt(accentColor.slice(5, 7), 16) * 0.114) / 255 > 0.65
    : false
  const playIconColor = accentColor && !isLightAccent ? 'white' : '#111'




  // ── Drag-to-dismiss (iOS style) ──────────────────────────────────────────────
  // Usamos manipulación directa del DOM en lugar de useMotionValue para que
  // Framer Motion NO mantenga will-change:transform activo permanentemente.
  // WebKit congela el mapa de hit-testing del layer compuesto cuando hay un
  // will-change:transform persistente — esto era lo que impedía los taps.
  const motionDivRef = useRef<HTMLDivElement>(null)
  const dragOffsetRef = useRef(0)
  const pointerStartY = useRef(0)
  const pointerStartTime = useRef(0)
  const hasDraggedRef = useRef(false)

  const handleHandlePointerDown = (e: React.PointerEvent) => {
    e.stopPropagation()
    e.currentTarget.setPointerCapture(e.pointerId)
    pointerStartY.current = e.clientY
    pointerStartTime.current = Date.now()
    hasDraggedRef.current = false
    dragOffsetRef.current = 0
    const el = motionDivRef.current
    if (el) {
      el.style.transition = 'none'
      el.style.willChange = 'transform'
    }
  }

  const handleHandlePointerMove = (e: React.PointerEvent) => {
    if (!(e.buttons & 1)) return
    const delta = Math.max(0, e.clientY - pointerStartY.current)
    if (delta > 4) hasDraggedRef.current = true
    dragOffsetRef.current = delta
    const el = motionDivRef.current
    if (el) el.style.transform = `translateY(${delta}px)`
  }

  const handleHandlePointerUp = () => {
    const current = dragOffsetRef.current
    const elapsed = Math.max(1, Date.now() - pointerStartTime.current)
    const velocity = (current / elapsed) * 1000
    const el = motionDivRef.current
    dragOffsetRef.current = 0

    if (current > 120 || (velocity > 500 && current > 20)) {
      // Dismiss: volar fuera de pantalla, luego cerrar
      if (el) {
        el.style.transition = 'transform 0.22s cubic-bezier(0.32,0,0.67,0)'
        el.style.transform = `translateY(${window.innerHeight}px)`
        setTimeout(() => {
          // Ocultar antes de limpiar el transform para que Framer Motion
          // no cause un flash al arrancar el exit desde y=0
          el.style.opacity = '0'
          el.style.transition = ''
          el.style.transform = ''
          el.style.willChange = 'auto'
          onClose()
        }, 220)
      } else {
        onClose()
      }
    } else {
      // Snap back: rebotar hacia 0, luego limpiar transform
      if (el) {
        el.style.transition = 'transform 0.45s cubic-bezier(0.34,1.56,0.64,1)'
        el.style.transform = 'translateY(0)'
        setTimeout(() => {
          el.style.transition = ''
          el.style.transform = ''
          el.style.willChange = 'auto'
        }, 450)
      }
    }
  }


  // ── Fetch lyrics ────────────────────────────────────────────────────────────
  useEffect(() => {
    if (!isOpen || !currentSong) {
      setLyrics([])
      return
    }
    let cancelled = false
    setLoadingLyrics(true)
    const artist = getArtistString(currentSong.artist)
    navidromeApi
      .getLyrics(artist, currentSong.title)
      .then(text => { if (!cancelled) setLyrics(parseLyrics(text)) })
      .catch(() => { if (!cancelled) setLyrics([]) })
      .finally(() => { if (!cancelled) setLoadingLyrics(false) })
    return () => { cancelled = true }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen, currentSong?.id])

  // ── Synced lyrics auto-scroll ────────────────────────────────────────────────
  useEffect(() => {
    if (!lyrics.length) return
    const hasSynced = lyrics.some(l => l.time !== Infinity)
    if (!hasSynced) return
    let idx = -1
    for (let i = 0; i < lyrics.length; i++) {
      const next = lyrics[i + 1]?.time ?? Infinity
      if (playerProgress.progress >= lyrics[i].time && playerProgress.progress < next) {
        idx = i
        break
      }
    }
    if (idx !== -1 && idx !== currentIndexRef.current) {
      currentIndexRef.current = idx
      setCurrentLineIndex(idx)
    }
  }, [playerProgress.progress, lyrics])

  // Auto-scroll del recuadro de letras para mantener la línea activa centrada
  useEffect(() => {
    if (userScrollingLyricsRef.current) return
    const box = lyricsBoxRef.current
    const lineEl = lineRefs.current[currentLineIndex]
    if (!box || !lineEl) return
    box.scrollTo({
      top: lineEl.offsetTop - box.clientHeight / 2 + lineEl.clientHeight / 2,
      behavior: 'smooth',
    })
  }, [currentLineIndex])

  // ── Progress bar drag ────────────────────────────────────────────────────────
  // Estrategia: durante el drag mostramos la posición localmente (sin llamar seek),
  // y sólo hacemos seek() al soltar el dedo. Esto evita miles de seeks rápidos
  // en WebAudio (cada seek destruye/crea un AudioBufferSourceNode) y da mejor UX.
  const progressBarRef = useRef<HTMLDivElement>(null)
  const isDraggingRef = useRef(false)
  const [dragPct, setDragPct] = useState<number | null>(null)

  const getPctFromPointer = (clientX: number): number => {
    const el = progressBarRef.current
    if (!el) return 0
    const rect = el.getBoundingClientRect()
    return Math.max(0, Math.min(1, (clientX - rect.left) / rect.width)) * 100
  }

  const handleProgressPointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    e.currentTarget.setPointerCapture(e.pointerId)
    isDraggingRef.current = true
    setDragPct(getPctFromPointer(e.clientX))
  }

  const handleProgressPointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!isDraggingRef.current) return
    setDragPct(getPctFromPointer(e.clientX))
  }

  const handleProgressPointerUp = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!isDraggingRef.current) return
    isDraggingRef.current = false
    const pct = getPctFromPointer(e.clientX)
    setDragPct(null)
    const duration = playerProgress.duration
    if (!isFinite(duration) || duration <= 0) return
    playerActions.seek((pct / 100) * duration)
  }

  // Cancel: abortar drag sin hacer seek (p.ej. gesto del sistema en iOS)
  const handleProgressPointerCancel = () => {
    isDraggingRef.current = false
    setDragPct(null)
  }

  // ── Volume drag ──────────────────────────────────────────────────────────────
  const volumeBarRef = useRef<HTMLDivElement>(null)
  const isDraggingVolumeRef = useRef(false)

  const getVolumePctFromPointer = (clientX: number): number => {
    const el = volumeBarRef.current
    if (!el) return 0
    const rect = el.getBoundingClientRect()
    return Math.round(Math.max(0, Math.min(1, (clientX - rect.left) / rect.width)) * 100)
  }

  const handleVolumePointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    e.currentTarget.setPointerCapture(e.pointerId)
    isDraggingVolumeRef.current = true
    playerActions.setVolume(getVolumePctFromPointer(e.clientX))
  }

  const handleVolumePointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!isDraggingVolumeRef.current) return
    playerActions.setVolume(getVolumePctFromPointer(e.clientX))
  }

  const handleVolumePointerUp = () => {
    isDraggingVolumeRef.current = false
  }

  // ── Derived ──────────────────────────────────────────────────────────────────
  // Progreso: usar estado remoto si controlamos otro dispositivo
  const effectiveProgress = isRemote ? (remotePlaybackState?.position || 0) : playerProgress.progress
  const effectiveDuration = isRemote ? (remoteSong?.duration || remotePlaybackState?.metadata?.duration || 0) : playerProgress.duration

  const rawProgressPct =
    effectiveDuration > 0 &&
    isFinite(effectiveDuration) &&
    isFinite(effectiveProgress)
      ? (effectiveProgress / effectiveDuration) * 100
      : 0

  // Durante el drag mostramos la posición local (sin esperar a que el seek actualice el estado)
  const progressPct = dragPct !== null ? dragPct : rawProgressPct

  // Tiempo mostrado en el label izquierdo (durante drag = posición estimada)
  const displayTime = dragPct !== null
    ? (dragPct / 100) * (effectiveDuration || 0)
    : effectiveProgress

  const remaining = Math.max(0, (effectiveDuration || 0) - displayTime)

  const formatTime = (s: number) => {
    if (!isFinite(s) || s < 0 || isNaN(s)) return '0:00'
    const m = Math.floor(s / 60)
    const sec = Math.floor(s) % 60
    return `${m}:${sec < 10 ? '0' : ''}${sec}`
  }

  const hasLyrics = lyrics.length > 0 || loadingLyrics


  return createPortal(
    <AnimatePresence>
      {isOpen && (
        <motion.div
          key="now-playing-viewer"
          ref={motionDivRef}
          initial={{ y: '100%' }}
          animate={{ y: 0 }}
          exit={{ y: '100%' }}
          transition={{ type: 'spring', damping: 36, stiffness: 420 }}
          style={{ backgroundColor: '#0a0a0a' }}
          className="fixed inset-0 z-[9995]"
          onAnimationComplete={() => {
            // Framer Motion deja transform:translateY(0px) + will-change:transform
            // al terminar la animación de apertura. Esto congela el hit-testing de
            // WebKit. Limpiamos ambos para que los taps funcionen inmediatamente.
            const el = motionDivRef.current
            if (el) {
              el.style.transform = ''
              el.style.willChange = 'auto'
            }
          }}
        >
          {/* ── Fondos visuales — FUERA del scroll container para evitar stacking
              context interference en iOS WKWebView. Todos pointer-events-none. ── */}
          {coverUrl && !hasCanvas && (
            <div
              className="absolute inset-0 pointer-events-none"
              style={{ isolation: 'isolate', contain: 'strict' }}
            >
              <img
                src={coverUrl}
                aria-hidden
                className="absolute inset-0 w-full h-full object-cover pointer-events-none"
                style={{
                  filter: 'blur(90px) saturate(1.4)',
                  transform: 'scale(1.25) translateZ(0)',
                  opacity: 0.65,
                }}
              />
              <div className="absolute inset-0 bg-black/50 pointer-events-none" />
              <div className="absolute inset-0 bg-gradient-to-b from-transparent via-transparent to-black/60 pointer-events-none" style={{ top: '45%' }} />
            </div>
          )}
          {hasCanvas && (
            <div className="absolute inset-0 pointer-events-none overflow-hidden">
              {/* pointer-events-none también en el className del Canvas para que su
                  div raíz no intercepte eventos (el video interior ya los tenía) */}
              <Canvas
                canvasUrl={canvasUrl}
                isLoading={isLoadingCanvas}
                className="w-full h-full object-cover pointer-events-none"
                isPlaying={playerState.isPlaying}
              />
              <div
                className="absolute inset-0 pointer-events-none"
                style={{
                  background: 'linear-gradient(to bottom, rgba(0,0,0,0.18) 0%, rgba(0,0,0,0) 18%, rgba(0,0,0,0) 35%, rgba(0,0,0,0.55) 60%, rgba(0,0,0,0.88) 78%, rgba(0,0,0,0.97) 100%)',
                }}
              />
            </div>
          )}

          {/* ── Scroll container: Section 1 (player, 100svh) + Section 2 (letras) ── */}
          <div
            ref={scrollContainerRef}
            className="absolute inset-0 overflow-y-auto overscroll-none"
            onScroll={() => {
              userScrollingRef.current = true
              clearTimeout(scrollResumeTimer.current)
              scrollResumeTimer.current = setTimeout(() => { userScrollingRef.current = false }, 3000)
            }}
          >
            {/* ── Section 1: player — ocupa exactamente la pantalla ── */}
            <div
              style={{
                height: '100svh',
                paddingTop: 'env(safe-area-inset-top)',
                display: 'flex',
                flexDirection: 'column',
                boxSizing: 'border-box',
              }}
            >
              {/* Album art — zona de drag (touch-none para que iOS no interfiera) */}
              <div
                className="flex-1 flex flex-col touch-none"
                style={{ cursor: 'grab' }}
                onPointerDown={handleHandlePointerDown}
                onPointerMove={handleHandlePointerMove}
                onPointerUp={handleHandlePointerUp}
                onPointerCancel={handleHandlePointerUp}
              >
                {/* Handle pill */}
                <div className="flex justify-center pt-3 pb-2 select-none">
                  <div className="w-12 h-[5px] bg-white/30 rounded-full pointer-events-none" />
                </div>

                {/* Album art */}
                {!hasCanvas && (
                  <div className="flex-1 flex items-center justify-center px-8 py-2">
                    <motion.div
                      animate={{ scale: isPlaying ? 1 : 0.925 }}
                      transition={{ type: 'spring', stiffness: 260, damping: 26 }}
                      className="w-full max-w-[340px] aspect-square rounded-[22px] overflow-hidden"
                      style={{
                        boxShadow: '0 36px 90px -8px rgba(0,0,0,0.72), 0 12px 32px -4px rgba(0,0,0,0.45)',
                      }}
                    >
                      <AlbumCover
                        coverArtId={currentSong?.coverArt}
                        size={1200}
                        className="w-full h-full"
                      />
                    </motion.div>
                  </div>
                )}

                {/* Canvas spacer */}
                {hasCanvas && <div className="flex-1" />}
              </div>

          {/* ── Controls section — flex-shrink-0.
              transform: translateZ(0) forces its own compositing layer so WebKit
              hit-testing is independent of the parent motion.div's will-change:transform. ── */}
          <div
            data-npv-controls
            className="relative flex-shrink-0 px-6"
            style={{
              paddingBottom: 'calc(env(safe-area-inset-bottom) + 1.5rem)',
              transform: 'translateZ(0)',
              WebkitTransform: 'translateZ(0)',
              touchAction: 'manipulation',
            }}
          >
              {/* Song info + action buttons */}
              <div className="flex items-start justify-between mb-3">
                <div className="flex-1 min-w-0 pr-3">
                  <p
                    className="text-white font-bold leading-tight tracking-tight line-clamp-1"
                    style={{ fontSize: '1.65rem' }}
                  >
                    {currentSong?.title ?? ''}
                  </p>
                  <p className="text-white/55 text-[1.05rem] mt-1 font-medium leading-tight truncate">
                    {artistStr}
                  </p>
                </div>

                {/* Three-dots menu */}
                <button
                  className="p-1 mt-0.5 flex-shrink-0 text-white/35 hover:text-white/65 transition-colors"
                  aria-label="Más opciones"
                  onClick={() => setShowMenu(true)}
                >
                  <svg className="w-6 h-6" fill="currentColor" viewBox="0 0 24 24">
                    <circle cx="5" cy="12" r="1.75" />
                    <circle cx="12" cy="12" r="1.75" />
                    <circle cx="19" cy="12" r="1.75" />
                  </svg>
                </button>
              </div>

              {/* Progress bar */}
              <div className="mb-4">
                {/*
                  Área táctil: h-8 (32px) para que el dedo lo alcance fácilmente en móvil.
                  La barra visual (h-1) está centrada dentro mediante flex items-center.
                  onPointerUp aplica el seek real; durante el drag sólo se actualiza el % local.
                */}
                <div
                  ref={progressBarRef}
                  className="relative h-8 flex items-center cursor-pointer"
                  onPointerDown={handleProgressPointerDown}
                  onPointerMove={handleProgressPointerMove}
                  onPointerUp={handleProgressPointerUp}
                  onPointerCancel={handleProgressPointerCancel}
                >
                  {/* Track visual */}
                  <div
                    className="absolute inset-x-0 h-1 rounded-full overflow-visible"
                    style={{ background: 'rgba(255,255,255,0.22)' }}
                  >
                    <div
                      className="absolute top-0 left-0 h-full rounded-full pointer-events-none"
                      style={{ width: `${progressPct}%`, background: 'white' }}
                    />
                  </div>
                  {/* Thumb — se escala un poco al hacer drag para feedback visual */}
                  <div
                    className="absolute top-1/2 -translate-y-1/2 rounded-full shadow-md pointer-events-none transition-transform duration-100"
                    style={{
                      left: `calc(${progressPct}% - ${dragPct !== null ? 9 : 7}px)`,
                      width: dragPct !== null ? 18 : 14,
                      height: dragPct !== null ? 18 : 14,
                      background: 'white',
                    }}
                  />
                </div>
                <div className="flex justify-between items-center mt-1 text-[11px] font-medium text-white/45 tabular-nums tracking-wide">
                  <span>{formatTime(displayTime)}</span>

                  {/* AutoMix / Remote indicator — inline between time labels */}
                  <AnimatePresence mode="wait">
                    {playerState.isCrossfading ? (
                      <motion.span
                        key="automix"
                        initial={{ opacity: 0, scale: 0.9 }}
                        animate={{ opacity: 1, scale: 1 }}
                        exit={{ opacity: 0, scale: 0.9 }}
                        transition={{ duration: 0.2 }}
                        className="text-[11px] font-bold tracking-wide"
                        style={{
                          background: 'linear-gradient(90deg, #38bdf8 0%, #e0f2fe 40%, #38bdf8 60%, #7dd3fc 100%)',
                          backgroundSize: '200% 100%',
                          WebkitBackgroundClip: 'text',
                          backgroundClip: 'text',
                          WebkitTextFillColor: 'transparent',
                          animation: 'automix-wave 2s linear infinite',
                        }}
                      >
                        AutoMix
                        <style>{`
                          @keyframes automix-wave {
                            0%   { background-position: 100% 0% }
                            100% { background-position: -100% 0% }
                          }
                        `}</style>
                      </motion.span>
                    ) : isRemote && activeDevice ? (
                      <motion.div
                        key="remote"
                        initial={{ opacity: 0, scale: 0.9 }}
                        animate={{ opacity: 1, scale: 1 }}
                        exit={{ opacity: 0, scale: 0.9 }}
                        transition={{ duration: 0.2 }}
                        className="flex items-center gap-1.5"
                      >
                        <div className="w-1.5 h-1.5 bg-green-400 rounded-full animate-pulse flex-shrink-0" />
                        <span className="text-[11px] font-medium text-green-400">
                          Reproduciendo en {activeDevice.name}
                        </span>
                      </motion.div>
                    ) : null}
                  </AnimatePresence>

                  <span>-{formatTime(remaining)}</span>
                </div>
              </div>

              {/* Playback controls — Apple Music style */}
              <div className="flex items-center justify-between mt-4 mb-6 px-2">
                {/* Prev — transparent, large icon */}
                <motion.button
                  whileTap={{ scale: 0.84 }}
                  disabled={!canGoPrevious}
                  onClick={handlePrevious}
                  className="w-[56px] h-[56px] flex items-center justify-center disabled:opacity-30 text-white"
                  aria-label="Anterior"
                >
                  <svg className="w-8 h-8" fill="currentColor" viewBox="0 0 24 24">
                    <path d="M6 6h2v12H6zm3.5 6 8.5 6V6z" />
                  </svg>
                </motion.button>

                {/* Play / Pause — solid white (or accent-tinted) circle */}
                <motion.button
                  whileTap={{ scale: 0.93 }}
                  disabled={!currentSong}
                  onClick={handleTogglePlayPause}
                  className="w-[74px] h-[74px] flex items-center justify-center rounded-full disabled:opacity-30"
                  style={{
                    background: accentColor || 'white',
                    boxShadow: accentColor
                      ? `0 6px 28px ${accentColor}55`
                      : '0 4px 24px rgba(255,255,255,0.28)',
                  }}
                  aria-label={isPlaying ? 'Pausar' : 'Reproducir'}
                >
                  {isPlaying ? (
                    <svg
                      className="w-9 h-9"
                      fill="currentColor"
                      viewBox="0 0 24 24"
                      style={{ color: playIconColor }}
                    >
                      <path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z" />
                    </svg>
                  ) : (
                    <svg
                      className="w-9 h-9"
                      fill="currentColor"
                      viewBox="0 0 24 24"
                      style={{ color: playIconColor }}
                    >
                      <path d="M8 5v14l11-7z" />
                    </svg>
                  )}
                </motion.button>

                {/* Next — transparent, large icon */}
                <motion.button
                  whileTap={{ scale: 0.84 }}
                  disabled={!canGoNext}
                  onClick={handleNext}
                  className="w-[56px] h-[56px] flex items-center justify-center disabled:opacity-30 text-white"
                  aria-label="Siguiente"
                >
                  <svg className="w-8 h-8" fill="currentColor" viewBox="0 0 24 24">
                    <path d="M6 18l8.5-6L6 6v12zM16 6v12h2V6h-2z" />
                  </svg>
                </motion.button>
              </div>

              {/* Volume slider — draggable */}
              <div className="flex items-center gap-3 mb-5">
                <SpeakerXMarkIcon className="w-[18px] h-[18px] text-white/40 flex-shrink-0" />
                <div
                  ref={volumeBarRef}
                  className="flex-1 relative h-8 flex items-center cursor-pointer touch-none"
                  onPointerDown={handleVolumePointerDown}
                  onPointerMove={handleVolumePointerMove}
                  onPointerUp={handleVolumePointerUp}
                  onPointerCancel={handleVolumePointerUp}
                >
                  <div
                    className="absolute inset-x-0 h-1 rounded-full"
                    style={{ background: 'rgba(255,255,255,0.22)' }}
                  >
                    <div
                      className="absolute top-0 left-0 h-full rounded-full pointer-events-none"
                      style={{ width: `${playerState.volume}%`, background: 'rgba(255,255,255,0.7)' }}
                    />
                  </div>
                </div>
                <SpeakerWaveIcon className="w-[18px] h-[18px] text-white/40 flex-shrink-0" />
              </div>

              {/* Bottom actions row */}
              <div className="flex items-center justify-between">
                <button
                  className="p-2 text-white/40 hover:text-white/65 transition-colors"
                  aria-label="Cola de reproducción"
                  onClick={() => onShowQueue()}
                >
                  <QueueIcon className="w-5 h-5" />
                </button>

                {hasLyrics ? (
                  <button
                    className="flex flex-col items-center gap-1 text-white/35 hover:text-white/55 transition-colors text-[10px] font-semibold uppercase tracking-widest"
                    onClick={() => {
                      const c = scrollContainerRef.current
                      if (c) c.scrollTo({ top: c.clientHeight, behavior: 'smooth' })
                    }}
                  >
                    <span>Letras</span>
                    <svg className="w-3 h-3 animate-bounce" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2.5} d="M19 9l-7 7-7-7" />
                    </svg>
                  </button>
                ) : <div className="w-9" />}

                <DevicePicker align="up" theme="player" buttonClassName="p-2 text-white/40 hover:text-white/65" iconClassName="w-5 h-5" />
              </div>
            </div>
            {/* ── fin Section 1 ── */}
            </div>

            {/* ── Section 2: letras — compact fixed-height box below fold ── */}
            {hasLyrics && (
              <div
                style={{
                  paddingTop: '2.5rem',
                  paddingBottom: 'calc(env(safe-area-inset-bottom) + 6rem)',
                  paddingLeft: '1.75rem',
                  paddingRight: '1.75rem',
                  background: 'linear-gradient(to bottom, transparent 0%, rgba(0,0,0,0.45) 100px)',
                }}
              >
                <div className="flex items-center gap-3 mb-4">
                  <div className="flex-1 h-px bg-white/10" />
                  <span className="text-white/25 text-[10px] font-semibold uppercase tracking-[0.18em]">Letras</span>
                  <div className="flex-1 h-px bg-white/10" />
                </div>
                {loadingLyrics ? (
                  <p className="text-white/35 text-sm text-center py-8">Cargando letras…</p>
                ) : (
                  <div style={{ position: 'relative', height: '280px' }}>
                    <div
                      ref={lyricsBoxRef}
                      onScroll={() => {
                        lyricsJustScrolledRef.current = true
                        userScrollingLyricsRef.current = true
                        clearTimeout(lyricsScrollTimer.current)
                        lyricsScrollTimer.current = setTimeout(() => {
                          userScrollingLyricsRef.current = false
                          // Give a small extra window before allowing seek again
                          setTimeout(() => { lyricsJustScrolledRef.current = false }, 400)
                        }, 1500)
                      }}
                      style={{
                        height: '100%',
                        overflowY: 'auto',
                        scrollbarWidth: 'none',
                        maskImage: 'linear-gradient(to bottom, transparent 0%, black 22%, black 78%, transparent 100%)',
                        WebkitMaskImage: 'linear-gradient(to bottom, transparent 0%, black 22%, black 78%, transparent 100%)',
                      }}
                    >
                      <div style={{ paddingTop: 140, paddingBottom: 140 }}>
                        {(() => {
                          const hasSynced = lyrics.some(l => l.time !== Infinity)
                          return lyrics.map((line, index) => {
                            const dist = Math.abs(index - currentLineIndex)
                            const isActive = hasSynced && dist === 0
                            const opacity = dist === 0 ? 1 : dist === 1 ? 0.48 : dist === 2 ? 0.22 : dist === 3 ? 0.10 : 0.04
                            return (
                              <div
                                key={index}
                                ref={el => { lineRefs.current[index] = el }}
                                onClick={() => {
                                  if (lyricsJustScrolledRef.current) return
                                  if (hasSynced && line.time !== Infinity) playerActions.seek(line.time)
                                }}
                                className="cursor-pointer select-none font-bold leading-snug tracking-tight text-white transition-all duration-300"
                                style={{
                                  opacity,
                                  fontSize: isActive ? '1.55rem' : '1.4rem',
                                  marginBottom: '0.65rem',
                                  textShadow: isActive ? '0 0 28px rgba(255,255,255,0.22)' : 'none',
                                }}
                              >
                                {line.text}
                              </div>
                            )
                          })
                        })()}
                      </div>
                    </div>
                  </div>
                )}
              </div>
            )}
          </div>
          {/* ── fin scroll container ── */}

          {/* ── Context menu ── */}
          {showMenu && currentSong && (
            <SongContextMenu
              x={0}
              y={0}
              song={currentSong}
              onClose={() => setShowMenu(false)}
              onBeforeNavigate={onClose}
              showGoToArtist={!!currentSong.artist}
              showGoToAlbum={!!currentSong.albumId}
              showGoToSong={true}
            />
          )}
        </motion.div>
      )}
    </AnimatePresence>,
    document.body
  )
}
