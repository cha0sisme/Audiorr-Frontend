import { useEffect, useRef, useState } from 'react'

interface CanvasProps {
  canvasUrl: string | null
  isLoading: boolean
  className?: string
  isPlaying?: boolean
}

/**
 * Detecta si la URL es una imagen o un video basándose en la extensión
 */
function isImageUrl(url: string): boolean {
  const imageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.svg']
  const lowerUrl = url.toLowerCase()
  return imageExtensions.some(ext => lowerUrl.includes(ext))
}

/**
 * Componente Canvas que muestra el video o imagen del Canvas de Spotify
 * Similar al comportamiento de Spotify, el video se reproduce en loop
 * Las imágenes se muestran estáticamente
 */
export default function Canvas({ canvasUrl, isLoading, className = '', isPlaying = true }: CanvasProps) {
  const videoRef = useRef<HTMLVideoElement>(null)
  const [videoError, setVideoError] = useState(false)
  const [imageError, setImageError] = useState(false)
  const [isImage, setIsImage] = useState(false)

  // Ref siempre actualizado: lo usan los callbacks del effect de carga (closure sobre canvasUrl)
  // para conocer el valor *actual* de isPlaying sin necesitar isPlaying como dependencia.
  const isPlayingRef = useRef(isPlaying)
  useEffect(() => { isPlayingRef.current = isPlaying }, [isPlaying])

  // Play / pause the canvas video in sync with the song
  useEffect(() => {
    const video = videoRef.current
    if (!video || isImage) return
    if (isPlaying) {
      video.play().catch(() => {})
    } else {
      video.pause()
    }
  }, [isPlaying, isImage])

  // Detectar si es imagen o video cuando cambia la URL
  useEffect(() => {
    if (!canvasUrl) {
      setIsImage(false)
      setVideoError(false)
      setImageError(false)
      return
    }

    const isImg = isImageUrl(canvasUrl)
    setIsImage(isImg)
    setVideoError(false)
    setImageError(false)
  }, [canvasUrl])

  useEffect(() => {
    const video = videoRef.current
    if (!video || !canvasUrl || isImage) {
      setVideoError(false)
      return
    }

    // Resetear estado de error
    setVideoError(false)

    // Configurar propiedades del video ANTES de cargar
    video.loop = true
    video.muted = true // Muted para que no interfiera con el audio de la canción
    video.playsInline = true // Importante para móviles
    video.preload = 'auto'

    // Función para intentar reproducir el video — respeta el estado de pausa actual
    const attemptPlay = async () => {
      if (!isPlayingRef.current) return
      try {
        await video.play()
      } catch (error) {
        // Ignorar errores de reproducción automática (políticas del navegador)
        console.debug('[Canvas] No se pudo reproducir automáticamente:', error)
      }
    }

    // Manejar cuando el video está listo para reproducir
    const handleCanPlay = () => {
      attemptPlay()
    }

    // Manejar errores de carga
    const handleError = () => {
      console.error('[Canvas] Error cargando video:', canvasUrl)
      setVideoError(true)
    }

    // Manejar cuando el video está cargado
    const handleLoadedData = () => {
      attemptPlay()
    }

    // Agregar event listeners
    video.addEventListener('canplay', handleCanPlay)
    video.addEventListener('loadeddata', handleLoadedData)
    video.addEventListener('error', handleError)

    // Cargar el video
    video.src = canvasUrl
    video.load()

    return () => {
      // Limpiar cuando el componente se desmonte
      if (video) {
        video.removeEventListener('canplay', handleCanPlay)
        video.removeEventListener('loadeddata', handleLoadedData)
        video.removeEventListener('error', handleError)
        // Solo pausar si el video está cargado
        if (video.readyState >= 2) {
          video.pause()
        }
        video.src = ''
        video.load() // Limpiar el buffer
      }
      setVideoError(false)
    }
  }, [canvasUrl])

  if (isLoading) {
    return (
      <div
        className={`bg-gray-200 dark:bg-gray-700 rounded-lg flex items-center justify-center ${className}`}
      >
        <div className="w-8 h-8 border-2 border-gray-400 dark:border-gray-500 border-t-transparent rounded-full animate-spin" />
      </div>
    )
  }

  if (!canvasUrl || (isImage && imageError) || (!isImage && videoError)) {
    return null
  }

  // Si es una imagen, renderizar un elemento img
  if (isImage) {
    return (
      <div
        className={`relative overflow-hidden select-none ${className}`}
        onContextMenu={e => e.preventDefault()}
      >
        <img
          src={canvasUrl}
          alt="Canvas"
          className="w-full h-full object-cover pointer-events-none select-none"
          draggable={false}
          onError={() => {
            console.error('[Canvas] Error cargando imagen:', canvasUrl)
            setImageError(true)
          }}
          onContextMenu={e => e.preventDefault()}
        />
      </div>
    )
  }

  // Si es un video, renderizar el elemento video
  return (
    <div
      className={`relative overflow-hidden select-none ${className}`}
      onContextMenu={e => e.preventDefault()}
    >
      <video
        ref={videoRef}
        className="w-full h-full object-cover pointer-events-none select-none"
        loop
        muted
        playsInline
        preload="auto"
        onContextMenu={e => e.preventDefault()}
      />
    </div>
  )
}

