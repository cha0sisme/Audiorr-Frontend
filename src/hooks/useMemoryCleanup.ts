import { useEffect, useRef, useCallback } from 'react'

interface MemoryCleanupOptions {
  /** Intervalo de limpieza en milisegundos (default: 60000 = 1 minuto) */
  cleanupInterval?: number
  /** Umbral de memoria en MB para activar limpieza agresiva (default: 500MB) */
  memoryThreshold?: number
  /** Callback para limpieza personalizada */
  onCleanup?: () => void
  /** Habilitar logs de debug */
  debug?: boolean
}

interface MemoryInfo {
  usedJSHeapSize: number
  totalJSHeapSize: number
  jsHeapSizeLimit: number
}

interface PerformanceWithMemory extends Performance {
  memory?: MemoryInfo
}

/**
 * Hook para control y limpieza de memoria
 * Monitorea el uso de memoria y ejecuta limpiezas periódicas
 */
export function useMemoryCleanup(options: MemoryCleanupOptions = {}) {
  const {
    cleanupInterval = 60000,
    memoryThreshold = 500,
    onCleanup,
    debug = false,
  } = options

  const cleanupRef = useRef<NodeJS.Timeout | null>(null)
  const lastCleanupRef = useRef<number>(Date.now())

  // Función para obtener uso de memoria (solo disponible en Chrome)
  const getMemoryUsage = useCallback((): number | null => {
    const perf = performance as PerformanceWithMemory
    if (perf.memory) {
      return perf.memory.usedJSHeapSize / 1024 / 1024 // MB
    }
    return null
  }, [])

  // Función de limpieza de recursos
  const cleanup = useCallback(() => {
    const now = Date.now()
    const memoryBefore = getMemoryUsage()

    if (debug && memoryBefore) {
      console.log(`[MemoryCleanup] Memoria antes: ${memoryBefore.toFixed(2)}MB`)
    }

    // 1. Limpiar imágenes no usadas del DOM
    const images = document.querySelectorAll('img[data-cleanup="true"]')
    images.forEach(img => {
      if (!isElementVisible(img as HTMLElement)) {
        (img as HTMLImageElement).src = ''
      }
    })

    // 2. Limpiar URLs de objetos blob no usados
    cleanupBlobUrls()

    // 3. Limpiar canvas no visibles
    const canvases = document.querySelectorAll('canvas')
    canvases.forEach(canvas => {
      if (!isElementVisible(canvas)) {
        const ctx = canvas.getContext('2d')
        if (ctx) {
          ctx.clearRect(0, 0, canvas.width, canvas.height)
        }
      }
    })

    // 4. Ejecutar callback personalizado
    onCleanup?.()

    // 5. Sugerir garbage collection (solo funciona en modo debug de Chrome)
    if (typeof window !== 'undefined' && 'gc' in window) {
      try {
        (window as Window & { gc?: () => void }).gc?.()
      } catch {
        // Ignorar si no está disponible
      }
    }

    lastCleanupRef.current = now

    if (debug) {
      const memoryAfter = getMemoryUsage()
      if (memoryBefore && memoryAfter) {
        const freed = memoryBefore - memoryAfter
        console.log(`[MemoryCleanup] Memoria después: ${memoryAfter.toFixed(2)}MB (liberado: ${freed.toFixed(2)}MB)`)
      }
    }
  }, [debug, getMemoryUsage, onCleanup])

  // Limpieza agresiva cuando la memoria supera el umbral
  const aggressiveCleanup = useCallback(() => {
    const memoryUsage = getMemoryUsage()
    
    if (memoryUsage && memoryUsage > memoryThreshold) {
      if (debug) {
        console.warn(`[MemoryCleanup] ⚠️ Uso de memoria alto: ${memoryUsage.toFixed(2)}MB > ${memoryThreshold}MB`)
      }

      // Limpieza regular
      cleanup()

      // Además, limpiar todos los caches de imágenes
      const allImages = document.querySelectorAll('img')
      allImages.forEach(img => {
        if (!isElementVisible(img)) {
          img.src = ''
        }
      })

      // Forzar limpieza de estilos computados (puede ayudar en algunos navegadores)
      document.documentElement.style.display = 'none'
      // eslint-disable-next-line @typescript-eslint/no-unused-expressions
      document.documentElement.offsetHeight // Forzar reflow
      document.documentElement.style.display = ''
    }
  }, [cleanup, debug, getMemoryUsage, memoryThreshold])

  // Iniciar monitoreo periódico
  useEffect(() => {
    cleanupRef.current = setInterval(() => {
      aggressiveCleanup()
    }, cleanupInterval)

    // Limpieza al desmontar
    return () => {
      if (cleanupRef.current) {
        clearInterval(cleanupRef.current)
        cleanupRef.current = null
      }
    }
  }, [aggressiveCleanup, cleanupInterval])

  // Limpiar al cambiar de visibilidad (cuando el usuario minimiza o cambia de pestaña)
  useEffect(() => {
    const handleVisibilityChange = () => {
      if (document.visibilityState === 'hidden') {
        cleanup()
      }
    }

    document.addEventListener('visibilitychange', handleVisibilityChange)
    return () => {
      document.removeEventListener('visibilitychange', handleVisibilityChange)
    }
  }, [cleanup])

  return {
    cleanup,
    aggressiveCleanup,
    getMemoryUsage,
  }
}

// Helpers

/** Verifica si un elemento es visible en el viewport */
function isElementVisible(element: HTMLElement): boolean {
  const rect = element.getBoundingClientRect()
  return (
    rect.top < window.innerHeight &&
    rect.bottom > 0 &&
    rect.left < window.innerWidth &&
    rect.right > 0
  )
}

/** Registro de URLs de blob creadas para poder limpiarlas */
const blobUrlRegistry = new Set<string>()

/** Registra una URL de blob para limpieza posterior */
export function registerBlobUrl(url: string): void {
  if (url.startsWith('blob:')) {
    blobUrlRegistry.add(url)
  }
}

/** Revoca una URL de blob específica */
export function revokeBlobUrl(url: string): void {
  if (blobUrlRegistry.has(url)) {
    try {
      URL.revokeObjectURL(url)
      blobUrlRegistry.delete(url)
    } catch {
      // Ignorar errores
    }
  }
}

/** Limpia todas las URLs de blob registradas */
function cleanupBlobUrls(): void {
  blobUrlRegistry.forEach(url => {
    try {
      URL.revokeObjectURL(url)
    } catch {
      // Ignorar errores
    }
  })
  blobUrlRegistry.clear()
}

/**
 * Hook simplificado para componentes que necesitan limpieza al desmontar
 */
export function useCleanupOnUnmount(cleanupFn: () => void) {
  const cleanupFnRef = useRef(cleanupFn)
  cleanupFnRef.current = cleanupFn

  useEffect(() => {
    return () => {
      cleanupFnRef.current()
    }
  }, [])
}
