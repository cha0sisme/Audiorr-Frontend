import { app, BrowserWindow, ipcMain, session, protocol, shell } from 'electron'
import { join } from 'path'
import { existsSync, mkdirSync, createWriteStream, unlinkSync, rmSync } from 'fs'
import { get } from 'http'
import { AudioAnalyzer } from '../electron-main/audioAnalyzer'
import { CacheManager } from '../electron-main/cacheManager'
import { CanvasCacheManager } from '../electron-main/canvasCacheManager'
import path from 'node:path'
import fetch from 'node-fetch'
// import { StretchGoalManager } from './electron-main/audioStretcher' // Comentado por ahora, ruta/nombre incorrecto
import sqlite3 from 'better-sqlite3'
import dotenv from 'dotenv'

// Cargar .env desde la raíz (donde se ejecuta npm run dev)
dotenv.config()

// ============================================================================
// 🖼️ WINDOWS TASKBAR ICON FIX
// Configurar AppUserModelId ANTES de que la app esté lista
// Esto es CRÍTICO para que Windows muestre el icono correcto en la barra de tareas
// ============================================================================
if (process.platform === 'win32') {
  // El AppUserModelId debe coincidir con el appId en package.json build config
  app.setAppUserModelId('com.audiorr.app')
}

// Sistema de perfiles para backend
const BACKEND_URLS = {
  local: 'http://localhost:3001',                              // Backend local (desarrollo)
  homelab: 'http://audiorr-backend.homelab.local',            // Homelab con reverse proxy (funciona en LAN y VPN)
  lan: 'http://192.168.1.43:2999',                            // IP directa sin proxy (fallback)
  production: 'https://audiorr.tu-dominio.com',               // Producción pública
} as const

type BackendProfile = keyof typeof BACKEND_URLS
const BACKEND_PROFILE = (process.env.BACKEND_PROFILE || 'homelab') as BackendProfile

// Forzar URL según perfil
process.env.VITE_API_URL = BACKEND_URLS[BACKEND_PROFILE] || BACKEND_URLS.homelab
console.log('[ELECTRON] 🎯 Backend Profile:', BACKEND_PROFILE)
console.log('[ELECTRON] ✅ Backend URL:', process.env.VITE_API_URL)

const APP_VERSION = app.getVersion()
const BUILD_VERSION = process.env.BUILD_VERSION || 'dev'

// Mover la declaración de mainWindow a un ámbito superior
let mainWindow: BrowserWindow | null = null
let allowedNavidromeOrigin = '' // Variable para la CSP dinámica
let allowedCanvasServerOrigin = '' // Variable para la CSP del servidor de Canvas

// Helper para descargar archivos (REESCRITO con node-fetch para mayor robustez)
async function downloadFile(url: string, destPath: string): Promise<void> {
  const response = await fetch(url)
  if (!response.ok) {
    throw new Error(`Failed to get '${url}' (${response.status} ${response.statusText})`)
  }

  return new Promise((resolve, reject) => {
    const fileStream = createWriteStream(destPath)
    response.body.pipe(fileStream)
    response.body.on('error', err => {
      // Limpiar el archivo si la descarga falla
      try {
        if (existsSync(destPath)) {
          unlinkSync(destPath)
        }
      } catch (cleanupError) {
        // Silenciar errores de limpieza para no ocultar el error principal
      }
      reject(err)
    })
    fileStream.on('finish', () => {
      fileStream.close()
      resolve()
    })
    fileStream.on('error', err => {
      reject(err)
    })
  })
}

// Inicializar analizador y caché
let audioAnalyzer: AudioAnalyzer | null = null
// cacheManager se inicializa una sola vez y se pasa a AudioAnalyzer.
let cacheManager: CacheManager | null = null
// Canvas cache manager para almacenar datos de Canvas persistentemente
let canvasCacheManager: CanvasCacheManager | null = null

// Registrar handlers IPC para análisis de audio
function setupAudioAnalysisHandlers() {
  try {
    cacheManager = new CacheManager()
    audioAnalyzer = new AudioAnalyzer(cacheManager)

    // Crear carpeta temporal para descargas si no existe
    const tempDir = join(app.getPath('userData'), 'temp-audio')
    if (!existsSync(tempDir)) {
      mkdirSync(tempDir)
    }

    // Handler para análisis de canción
    ipcMain.handle('analyze:song', async (event, { streamUrl, songId, isProactive }) => {
      const tempFilePath = join(tempDir, `${songId}.mp3`)
      try {
        // La lógica de caché ahora está DENTRO de analyzeWithCache.
        // Primero, aseguramos la descarga del archivo.
        await downloadFile(streamUrl, tempFilePath)
        // Luego, llamamos al método que gestiona la caché internamente.
        const result = await audioAnalyzer!.analyzeWithCache(songId, tempFilePath, isProactive)
        return result
      } catch (error) {
        console.error(`[IPC] Error analyzing song ${songId}:`, error)
        return null
      } finally {
        // Cleanup temp file with a small delay to prevent EBUSY error
        setTimeout(() => {
          try {
            if (existsSync(tempFilePath)) {
              unlinkSync(tempFilePath)
            }
          } catch (cleanupError) {
            console.error(`[IPC] Error cleaning up temp file for ${songId}:`, cleanupError)
          }
        }, 500) // 500ms delay
      }
    })

    // Handler para limpiar caché
    ipcMain.handle('analyze:clearCache', async () => {
      try {
        const result = await cacheManager!.clearAll()
        return result
      } catch (error) {
        console.error('[IPC] Error clearing cache:', error)
        return { success: false, error: String(error) }
      }
    })
  } catch (error) {
    console.error('[IPC] Failed to setup audio analysis handlers:', error)
  }
}

// Registrar handlers IPC para caché de Canvas
function setupCanvasCacheHandlers() {
  try {
    canvasCacheManager = new CanvasCacheManager()

    // Handler para obtener entrada de caché por songId
    ipcMain.handle('canvas-cache:get-by-song-id', async (_, songId: string) => {
      try {
        await canvasCacheManager!.waitForInitialization()
        return canvasCacheManager!.getBySongId(songId)
      } catch (error) {
        console.error('[IPC] Error getting canvas cache by songId:', error)
        return null
      }
    })

    // Handler para obtener entrada de caché por título y artista
    ipcMain.handle(
      'canvas-cache:get-by-title-artist',
      async (_, title: string, artist: string, album?: string) => {
        try {
          await canvasCacheManager!.waitForInitialization()
          return canvasCacheManager!.getByTitleAndArtist(title, artist, album)
        } catch (error) {
          console.error('[IPC] Error getting canvas cache by title/artist:', error)
          return null
        }
      }
    )

    // Handler para guardar entrada en caché
    ipcMain.handle(
      'canvas-cache:set',
      async (
        _,
        songId: string,
        title: string,
        artist: string,
        album: string | undefined,
        spotifyTrackId: string | null,
        canvasUrl: string | null
      ) => {
        try {
          await canvasCacheManager!.waitForInitialization()
          canvasCacheManager!.set(songId, title, artist, album, spotifyTrackId, canvasUrl)
          return { success: true }
        } catch (error) {
          console.error('[IPC] Error setting canvas cache:', error)
          return { success: false, error: String(error) }
        }
      }
    )

    // Handler para limpiar caché de Canvas
    ipcMain.handle('canvas-cache:clear', async () => {
      try {
        await canvasCacheManager!.waitForInitialization()
        return await canvasCacheManager!.clearAll()
      } catch (error) {
        console.error('[IPC] Error clearing canvas cache:', error)
        return { success: false, error: String(error) }
      }
    })

    // Handler para obtener tamaño de caché
    ipcMain.handle('canvas-cache:get-size', async () => {
      try {
        await canvasCacheManager!.waitForInitialization()
        return canvasCacheManager!.getCacheSize()
      } catch (error) {
        console.error('[IPC] Error getting canvas cache size:', error)
        return 0
      }
    })
  } catch (error) {
    console.error('[IPC] Failed to setup canvas cache handlers:', error)
  }
}

// Configurar Media Session API para controles de medios del sistema
function setupMediaSession() {
  if (!mainWindow) return

  // Configurar acciones de medios cada vez que la página carga
  mainWindow.webContents.on('did-finish-load', () => {
    mainWindow?.webContents
      .executeJavaScript(
        `
        if (navigator.mediaSession) {
          // Configurar acciones de medios usando el método seguro
          navigator.mediaSession.setActionHandler('play', () => {
            window.electron.sendMediaSessionAction('play');
          });

          navigator.mediaSession.setActionHandler('pause', () => {
            window.electron.sendMediaSessionAction('pause');
          });

          navigator.mediaSession.setActionHandler('previoustrack', () => {
            window.electron.sendMediaSessionAction('previoustrack');
          });

          navigator.mediaSession.setActionHandler('nexttrack', () => {
            window.electron.sendMediaSessionAction('nexttrack');
          });

          navigator.mediaSession.setActionHandler('seekbackward', (details) => {
            window.electron.sendMediaSessionAction('seekbackward', details.seekOffset || 10);
          });

          navigator.mediaSession.setActionHandler('seekforward', (details) => {
            window.electron.sendMediaSessionAction('seekforward', details.seekOffset || 10);
          });

          console.log('[MediaSession] Acciones configuradas');
        }
      `
      )
      .catch(err => {
        console.error('[MediaSession] Error configurando acciones:', err)
      })
  })
}

function createWindow(): void {
  // Create the browser window.
  const preloadPath = join(__dirname, 'preload.js')

  // ============================================================================
  // 🖼️ ICON PATH RESOLUTION
  // Obtener la ruta del icono según la plataforma
  // Windows: usar .ico, otras plataformas: usar .png
  // ============================================================================
  const getIconPath = () => {
    const possiblePaths: string[] = []
    
    if (process.platform === 'win32') {
      // Windows: buscar icono .ico en varios lugares posibles
      possiblePaths.push(
        join(__dirname, '../../assets/icon.ico'),           // Desarrollo (dist-electron está en raíz)
        join(process.resourcesPath, 'assets', 'icon.ico'),  // Producción (extraFiles)
        join(process.resourcesPath, 'icon.ico'),            // Producción (extraResources)
        join(app.getAppPath(), 'assets', 'icon.ico'),       // Dentro del asar
        // Rutas adicionales para el ejecutable compilado
        join(process.resourcesPath, '..', 'assets', 'icon.ico'),
        join(__dirname, '..', '..', '..', 'assets', 'icon.ico'),
      )
    } else {
      // Otras plataformas: usar logo.png
      possiblePaths.push(
        join(__dirname, '../../assets/logo.png'),
        join(process.resourcesPath, 'assets', 'logo.png'),
        join(app.getAppPath(), 'assets', 'logo.png'),
      )
    }
    
    // Buscar el primer icono que exista
    for (const iconPath of possiblePaths) {
      if (existsSync(iconPath)) {
        console.log('[Electron] ✅ Icono encontrado en:', iconPath)
        return iconPath
      }
    }
    
    // Si no encontramos el icono, mostrar error detallado
    console.error('[Electron] ❌ NO SE ENCONTRÓ EL ICONO')
    console.error('[Electron] Directorio actual:', __dirname)
    console.error('[Electron] process.resourcesPath:', process.resourcesPath)
    console.error('[Electron] app.getAppPath():', app.getAppPath())
    console.error('[Electron] Rutas probadas:', possiblePaths)
    
    // Devolver la primera ruta como fallback
    return possiblePaths[0]
  }

  const iconPath = getIconPath()
  console.log('[Electron] 🖼️ Usando icono:', iconPath)
  console.log('[Electron] 🔍 Icono existe:', existsSync(iconPath))

  // ============================================================================
  // 🪟 CREATE BROWSER WINDOW
  // ============================================================================
  const localMainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    show: false,
    autoHideMenuBar: true,
    title: 'Audiorr',
    // ⚠️ IMPORTANTE: En Windows, el icono debe pasarse aquí para la barra de tareas
    icon: iconPath,
    webPreferences: {
      preload: preloadPath,
      nodeIntegration: false,
      contextIsolation: true,
      // 🔊 WEB AUDIO API: Desactivar webSecurity para evitar problemas de CORS
      // Esto permite cargar audio directamente con Web Audio API sin restricciones
      webSecurity: false,
    },
  })

  // Asignar la ventana local a la variable global
  mainWindow = localMainWindow

  // Open DevTools solo en desarrollo
  if (process.env.NODE_ENV === 'development' || !app.isPackaged) {
    localMainWindow.webContents.openDevTools()
  }

  // Añadir atajo para abrir/cerrar DevTools (solo en desarrollo)
  if (process.env.NODE_ENV === 'development' || !app.isPackaged) {
    localMainWindow.webContents.on('before-input-event', (event, input) => {
      if (input.control && input.shift && input.key.toLowerCase() === 'i') {
        localMainWindow.webContents.toggleDevTools()
      }
    })
  }

  localMainWindow.on('ready-to-show', () => {
    localMainWindow.show()
    // Configurar Media Session después de que la ventana esté lista
    setupMediaSession()
  })

  // Eliminar el bloque 'did-finish-load' que inyectaba código erróneamente
  // El script de preload ya se encarga de esto de forma segura.

  localMainWindow.webContents.setWindowOpenHandler(details => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    shell.openExternal(details.url)
    return { action: 'deny' }
  })

  // Load the remote URL for development or the local html file for production.
  // Try to load from Vite dev server first
  const viteUrl = 'http://localhost:5173'

  // In development, always try to load from Vite
  localMainWindow.loadURL(viteUrl).catch(() => {
    console.log('Failed to load from Vite dev server, trying local file')
    localMainWindow.loadFile(join(__dirname, '../../dist/index.html'))
  })

  // Log errors
  localMainWindow.webContents.on(
    'did-fail-load',
    (event, errorCode, errorDescription, validatedURL) => {
      console.error('Failed to load:', errorCode, errorDescription, validatedURL)
    }
  )

  // Filtrar errores de las DevTools (son benignos y no afectan la aplicación)
  // Estos errores se muestran en la consola pero no afectan la funcionalidad
  localMainWindow.webContents.on('console-message', (event, level, message, line, sourceId) => {
    // Ignorar errores de "Failed to fetch" que provienen de las DevTools
    // Estos son errores internos de las DevTools y no de la aplicación
    if (sourceId?.startsWith('devtools://')) {
      // No registrar nada, simplemente ignorar estos errores
      return
    }
  })
}

function clearStretchedCache() {
  const cacheDir = join(app.getPath('userData'), 'StretchedCache')
  if (existsSync(cacheDir)) {
    try {
      rmSync(cacheDir, { recursive: true, force: true })
      console.log('[CACHE] Stretched audio cache cleared successfully.')
    } catch (error) {
      console.error('[CACHE] Failed to clear stretched audio cache:', error)
    }
  }
}

// This method will be called when Electron has finished initialization.
// Some APIs can only be used after this event occurs.
app.whenReady().then(() => {
  // Configurar el nombre de la aplicación para que aparezca correctamente en los controles de medios
  app.setName('Audiorr')

  // Configurar el ID del modelo de usuario de la aplicación (Windows)
  // Esto ayuda a que Windows muestre el icono correctamente en la barra de tareas
  if (process.platform === 'win32') {
    app.setAppUserModelId('com.audiorr.app')
  }

  // Registrar un protocolo personalizado para servir archivos locales de forma segura
  protocol.registerFileProtocol('audiourl', (request, callback) => {
    const url = request.url.substr('audiourl://'.length)
    callback({ path: decodeURI(url) })
  })

  // Limpiar el caché de audio "estirado" al iniciar
  clearStretchedCache()

  // Configurar Content Security Policy
  session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
    let connectSrc = `'self' https://lrclib.net https://ws.audioscrobbler.com https://api.deezer.com`
    let imgSrc = `'self' data: https://lastfm.freetls.fastly.net https://cdn-images.dzcdn.net`
    let mediaSrc = `'self' blob: audiourl:`

    // Añadir origen de Navidrome si está configurado
    if (allowedNavidromeOrigin) {
      connectSrc += ` ${allowedNavidromeOrigin}`
      imgSrc += ` ${allowedNavidromeOrigin}`
      mediaSrc += ` ${allowedNavidromeOrigin}`
    }

    // Añadir origen del servidor de Canvas si está configurado
    if (allowedCanvasServerOrigin) {
      connectSrc += ` ${allowedCanvasServerOrigin}`
      imgSrc += ` ${allowedCanvasServerOrigin}`
      mediaSrc += ` ${allowedCanvasServerOrigin}`
    }

    // Permitir conexiones HTTP/HTTPS para permitir la configuración inicial
    // Esto permite que la app funcione incluso si los orígenes no están configurados todavía
    // Se puede hacer más estricto en el futuro si es necesario
    connectSrc += ` http: https:`
    imgSrc += ` http: https:`
    mediaSrc += ` http: https:`

    callback({
      responseHeaders: {
        ...details.responseHeaders,
        'Content-Security-Policy': [
          `default-src 'self'; ` +
            `script-src 'self' 'unsafe-inline'; ` +
            `style-src 'self' 'unsafe-inline'; ` +
            `connect-src ${connectSrc}; ` +
            `img-src ${imgSrc}; ` +
            `media-src ${mediaSrc};`,
        ],
      },
    })
  })

  // Configurar handlers IPC solo si NO se usa backend remoto
  const useRemoteBackend = process.env.VITE_API_URL && !process.env.VITE_API_URL.includes('localhost')
  
  if (useRemoteBackend) {
    console.log('[ELECTRON] 🌐 Usando backend remoto:', process.env.VITE_API_URL)
    console.log('[ELECTRON] ⏭️  Omitiendo inicialización de servicios locales')
  } else {
    console.log('[ELECTRON] 💻 Usando backend local')
    // Configurar handlers IPC para análisis de audio
    setupAudioAnalysisHandlers()
    // Configurar handlers IPC para caché de Canvas
    setupCanvasCacheHandlers()
  }

  // Cache para avatares de artistas (en memoria durante la sesión)
  const artistImageCache: Map<string, string | null> = new Map()

  // Handler para configurar el origen de Navidrome para la CSP
  ipcMain.handle('set-navidrome-origin', (_, serverUrl: string) => {
    try {
      if (serverUrl) {
        const url = new URL(serverUrl)
        allowedNavidromeOrigin = url.origin
        console.log(`[CSP] Allowed Navidrome origin set to: ${allowedNavidromeOrigin}`)
      } else {
        allowedNavidromeOrigin = ''
      }
    } catch (error) {
      console.error('[IPC] Invalid URL provided for Navidrome origin:', serverUrl)
      allowedNavidromeOrigin = ''
    }
  })

  // Handler para configurar el origen del servidor de Canvas para la CSP
  ipcMain.handle('set-canvas-server-origin', (_, serverUrl: string) => {
    try {
      if (serverUrl) {
        const url = new URL(serverUrl)
        allowedCanvasServerOrigin = url.origin
        console.log(`[CSP] Allowed Canvas server origin set to: ${allowedCanvasServerOrigin}`)
      } else {
        allowedCanvasServerOrigin = ''
      }
    } catch (error) {
      console.error('[IPC] Invalid URL provided for Canvas server origin:', serverUrl)
      allowedCanvasServerOrigin = ''
    }
  })

  // Handler para extraer colores dominantes de una imagen
  ipcMain.handle('extract-image-colors', async (event, imageUrl: string) => {
    try {
      const { createCanvas, loadImage } = await import('canvas')

      // Cargar la imagen
      const img = await loadImage(imageUrl)

      // Crear un canvas temporal
      const canvas = createCanvas(200, 200)
      const ctx = canvas.getContext('2d')

      // Redimensionar la imagen
      const scale = Math.min(200 / img.width, 200 / img.height)
      const width = img.width * scale
      const height = img.height * scale
      canvas.width = width
      canvas.height = height

      // Dibujar la imagen
      ctx.drawImage(img, 0, 0, width, height)

      // Obtener datos de la imagen
      const imageData = ctx.getImageData(0, 0, width, height)
      const data = imageData.data

      // Definir puntos estratégicos para muestreo
      const samplePoints = [
        // Esquinas
        { x: 0, y: 0 },
        { x: width - 1, y: 0 },
        { x: 0, y: height - 1 },
        { x: width - 1, y: height - 1 },
        // Centro
        { x: Math.floor(width / 2), y: Math.floor(height / 2) },
        // Puntos intermedios
        { x: Math.floor(width / 4), y: Math.floor(height / 4) },
        { x: Math.floor((width * 3) / 4), y: Math.floor(height / 4) },
        { x: Math.floor(width / 4), y: Math.floor((height * 3) / 4) },
        { x: Math.floor((width * 3) / 4), y: Math.floor((height * 3) / 4) },
        // Puntos adicionales
        { x: Math.floor(width / 2), y: Math.floor(height / 4) },
        { x: Math.floor(width / 2), y: Math.floor((height * 3) / 4) },
        { x: Math.floor(width / 4), y: Math.floor(height / 2) },
        { x: Math.floor((width * 3) / 4), y: Math.floor(height / 2) },
      ]

      // Recopilar colores
      const sampledColors: {
        r: number
        g: number
        b: number
        brightness: number
        saturation: number
      }[] = []

      for (const point of samplePoints) {
        const index = (point.y * width + point.x) * 4
        const r = data[index]
        const g = data[index + 1]
        const b = data[index + 2]
        const brightness = r * 0.299 + g * 0.587 + b * 0.114

        // Calcular saturación
        const max = Math.max(r, g, b)
        const min = Math.min(r, g, b)
        const saturation = max === 0 ? 0 : (max - min) / max

        sampledColors.push({ r, g, b, brightness, saturation })
      }

      // Filtrar colores muy grises (saturación < 0.1) y muy oscuros (brillo < 30)
      const vibrantColors = sampledColors.filter(
        color => color.saturation > 0.1 && color.brightness > 30
      )

      // Si no hay colores vibrantes, usar todos
      const colorsToUse = vibrantColors.length > 0 ? vibrantColors : sampledColors

      // Ordenar por una combinación de saturación y brillo
      colorsToUse.sort((a, b) => {
        const scoreA = a.saturation * 0.7 + (a.brightness * 0.3) / 255
        const scoreB = b.saturation * 0.7 + (b.brightness * 0.3) / 255
        return scoreB - scoreA
      })

      // Seleccionar colores para la paleta
      const primaryIndex = Math.floor(colorsToUse.length / 3)
      const secondaryIndex = Math.floor((colorsToUse.length * 2) / 3)

      const rgbToHex = (r: number, g: number, b: number) => {
        return `#${[r, g, b].map(x => x.toString(16).padStart(2, '0')).join('')}`
      }

      return {
        primary: rgbToHex(
          colorsToUse[primaryIndex].r,
          colorsToUse[primaryIndex].g,
          colorsToUse[primaryIndex].b
        ),
        secondary: rgbToHex(
          colorsToUse[secondaryIndex].r,
          colorsToUse[secondaryIndex].g,
          colorsToUse[secondaryIndex].b
        ),
        accent: rgbToHex(colorsToUse[0].r, colorsToUse[0].g, colorsToUse[0].b),
      }
    } catch (error) {
      console.error('[IPC] Error al extraer colores:', error)
      return null
    }
  })

  // Handler para obtener imagen de artista desde Deezer API
  ipcMain.handle('get-artist-image', async (event, artistName: string) => {
    try {
      // Normalizar el nombre del artista para la caché (lowercase, trim)
      const cacheKey = artistName.toLowerCase().trim()

      // Verificar si está en caché
      if (artistImageCache.has(cacheKey)) {
        const cachedImage = artistImageCache.get(cacheKey)
        return cachedImage !== undefined ? cachedImage : null
      }

      const url = `https://api.deezer.com/search/artist?q=${encodeURIComponent(artistName)}&limit=1`
      const response = await fetch(url)

      if (!response.ok) {
        // Guardar null en caché para evitar reintentos frecuentes
        artistImageCache.set(cacheKey, null)
        return null
      }

      const jsonData: any = await response.json()

      if (jsonData && jsonData.data && Array.isArray(jsonData.data) && jsonData.data.length > 0) {
        const artist = jsonData.data[0]

        // Intentar obtener la imagen de mayor calidad disponible
        const imageUrl =
          artist.picture_xl ||
          artist.picture_big ||
          artist.picture_medium ||
          artist.picture_small ||
          artist.picture

        // Verificar que la URL sea válida (no esté vacía y no sea un placeholder)
        // Los placeholders de Deezer tienen "/artist//" (sin hash)
        // Las URLs válidas tienen "/artist/[hash]/" donde hash es un string alfanumérico de 32 caracteres
        // También aceptamos URLs de api.deezer.com que son válidas
        const isValidDeezerImage =
          imageUrl &&
          imageUrl.trim() !== '' &&
          (imageUrl.match(/\/artist\/[a-f0-9]{32}\//) || // Hash de 32 caracteres hex
            imageUrl.includes('api.deezer.com/artist/')) // URLs directas de la API

        const isPlaceholder =
          !imageUrl ||
          imageUrl.trim() === '' ||
          imageUrl.includes('artist//') || // Doble barra indica placeholder
          !isValidDeezerImage

        const finalImageUrl = !isPlaceholder ? imageUrl : null

        // Guardar en caché (incluso si es null para evitar reintentos)
        artistImageCache.set(cacheKey, finalImageUrl)

        return finalImageUrl
      }

      // No se encontró el artista, guardar null en caché
      artistImageCache.set(cacheKey, null)
      return null
    } catch (error) {
      console.error('[IPC] Error al obtener imagen del artista:', error)
      return null
    }
  })

  // Handler para obtener la versión de la app
  ipcMain.handle('get-app-version', () => {
    return {
      version: APP_VERSION,
      build: BUILD_VERSION,
    }
  })

  // Configurar handlers IPC para Media Session API
  // Handler IPC para actualizar metadatos de medios
  ipcMain.handle(
    'media-session:update-metadata',
    (
      _,
      metadata: {
        title: string
        artist: string
        album: string
        artwork?: string
        duration?: number
      }
    ) => {
      if (!mainWindow) return

      try {
        // Construir el objeto de metadatos para MediaMetadata
        const mediaMetadataObj: {
          title: string
          artist: string
          album: string
          artwork?: Array<{ src: string; sizes: string; type: string }>
        } = {
          title: metadata.title,
          artist: metadata.artist,
          album: metadata.album,
        }

        // Agregar artwork si está disponible
        if (metadata.artwork) {
          mediaMetadataObj.artwork = [
            {
              src: metadata.artwork,
              sizes: '512x512',
              type: 'image/jpeg',
            },
          ]
        }

        // Usar la API de Media Session de Electron
        mainWindow.webContents
          .executeJavaScript(
            `
          if (navigator.mediaSession) {
            navigator.mediaSession.metadata = new MediaMetadata(${JSON.stringify(mediaMetadataObj)});
          }
        `
          )
          .catch(err => {
            console.error('[MediaSession] Error actualizando metadatos:', err)
          })
      } catch (error) {
        console.error('[MediaSession] Error configurando metadatos:', error)
      }
    }
  )

  // Handler IPC para actualizar el estado de reproducción
  ipcMain.handle('media-session:update-playback-state', (_, state: 'playing' | 'paused') => {
    if (!mainWindow) return

    try {
      mainWindow.webContents
        .executeJavaScript(
          `
          if (navigator.mediaSession) {
            navigator.mediaSession.playbackState = '${state}';
          }
        `
        )
        .catch(err => {
          console.error('[MediaSession] Error actualizando estado:', err)
        })
    } catch (error) {
      console.error('[MediaSession] Error configurando estado:', error)
    }
  })

  // Handler IPC para recibir acciones de medios desde el sistema operativo
  ipcMain.on('media-session:action', (_, action: string, ...args: unknown[]) => {
    if (!mainWindow) return

    // Enviar la acción al renderer process
    mainWindow.webContents.send('media-session:action-received', action, ...args)
  })

  // Handler para DevTools con comprobación de seguridad
  ipcMain.on('toggle-devtools', () => {
    if (mainWindow) {
      if (mainWindow.webContents.isDevToolsOpened()) {
        mainWindow.webContents.closeDevTools()
      } else {
        mainWindow.webContents.openDevTools()
      }
    }
  })

  // Handler para obtener el uso de memoria
  ipcMain.handle('get-memory-usage', () => {
    return process.memoryUsage().heapUsed / 1024 / 1024 // en MB
  })

  ipcMain.handle('get-cache-size', () => {
    if (cacheManager) {
      return cacheManager.getCacheSize() // en MB
    }
    return 0
  })

  // --- Deezer API for artist images ---
  ipcMain.handle('deezer:getArtistImage', async (_, artistName: string) => {
    try {
      // Normalizar el nombre del artista para la caché (lowercase, trim)
      const cacheKey = artistName.toLowerCase().trim()

      // Verificar si está en caché
      if (artistImageCache.has(cacheKey)) {
        const cachedImage = artistImageCache.get(cacheKey)
        return cachedImage !== undefined ? cachedImage : null
      }

      const url = `https://api.deezer.com/search/artist?q=${encodeURIComponent(artistName)}&limit=1`
      const response = await fetch(url)

      if (!response.ok) {
        // Guardar null en caché para evitar reintentos frecuentes
        artistImageCache.set(cacheKey, null)
        return null
      }

      const jsonData: any = await response.json()

      if (jsonData && jsonData.data && Array.isArray(jsonData.data) && jsonData.data.length > 0) {
        const artist = jsonData.data[0]

        // Intentar obtener la imagen de mayor calidad disponible
        const imageUrl =
          artist.picture_xl ||
          artist.picture_big ||
          artist.picture_medium ||
          artist.picture_small ||
          artist.picture

        // Verificar que la URL sea válida (no esté vacía y no sea un placeholder)
        // Los placeholders de Deezer tienen "/artist//" (sin hash)
        // Las URLs válidas tienen "/artist/[hash]/" donde hash es un string alfanumérico de 32 caracteres
        // También aceptamos URLs de api.deezer.com que son válidas
        const isValidDeezerImage =
          imageUrl &&
          imageUrl.trim() !== '' &&
          (imageUrl.match(/\/artist\/[a-f0-9]{32}\//) || // Hash de 32 caracteres hex
            imageUrl.includes('api.deezer.com/artist/')) // URLs directas de la API

        const isPlaceholder =
          !imageUrl ||
          imageUrl.trim() === '' ||
          imageUrl.includes('artist//') || // Doble barra indica placeholder
          !isValidDeezerImage

        const finalImageUrl = !isPlaceholder ? imageUrl : null

        // Guardar en caché (incluso si es null para evitar reintentos)
        artistImageCache.set(cacheKey, finalImageUrl)

        return finalImageUrl
      }

      // No se encontró el artista, guardar null en caché
      artistImageCache.set(cacheKey, null)
      return null
    } catch (error) {
      console.error('[IPC] Error al obtener imagen del artista:', error)
      return null
    }
  })

  // IPC handler para obtener canciones similares de Last.fm
  ipcMain.handle('getSimilarSongs', async (_, { artist, track, navidromeConfig, apiKey }) => {
    if (!apiKey) {
      // No logueamos nada si no hay key, es un estado esperado.
      return []
    }

    try {
      const url = `https://ws.audioscrobbler.com/2.0/?method=track.getsimilar&artist=${encodeURIComponent(
        artist
      )}&track=${encodeURIComponent(track)}&api_key=${apiKey}&format=json&limit=8` // Pedir 8 para tener margen

      const response = await fetch(url)
      if (!response.ok) {
        return []
      }
      const data = await response.json()

      if (data.error || !data.similartracks?.track || data.similartracks.track.length === 0) {
        return []
      }

      const similarTracks = data.similartracks.track

      const { serverUrl, username, token } = navidromeConfig
      const searchPromises = similarTracks.map(async (t: any) => {
        // FIX: Buscar por "Artista Título" para mayor precisión
        const query = `${t.artist.name} ${t.name}`
        const searchUrl = `${serverUrl}/rest/search3.view?u=${encodeURIComponent(
          username
        )}&p=${encodeURIComponent(
          token
        )}&v=1.16.0&c=audiorr&f=json&query=${encodeURIComponent(query)}&songCount=5`
        try {
          const navidromeResponse = await fetch(searchUrl)
          if (!navidromeResponse.ok) return null
          const navidromeData = await navidromeResponse.json()
          const songs = navidromeData['subsonic-response']?.searchResult3?.song

          if (!songs || songs.length === 0) {
            return null
          }

          // FIX: De los resultados, encontrar el que coincida exactamente con el artista
          const lastFmArtist = t.artist.name.toLowerCase()
          const bestMatch = songs.find((s: any) => s.artist.toLowerCase() === lastFmArtist)

          return bestMatch || null // Devolver solo si hay coincidencia de artista
        } catch (e) {
          // No loguear errores de fetch individuales para no llenar la consola
          return null
        }
      })

      const foundSongs = (await Promise.all(searchPromises)).filter(Boolean) // Filtrar nulos
      const finalSongs = foundSongs.slice(0, 5) // Devolver solo los primeros 5 encontrados
      return finalSongs
    } catch (error) {
      return []
    }
  })

  createWindow()

  app.on('activate', () => {
    // On macOS it's common to re-create a window in the app when the
    // dock icon is clicked and there are no other windows open.
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow()
    }
  })
})

// 🔒 SEGURIDAD: Limpiar procesos Python antes de cerrar la app
app.on('before-quit', event => {
  console.log('[APP] Limpiando recursos antes de cerrar...')
  if (audioAnalyzer) {
    audioAnalyzer.killAllProcesses()
  }
})

// 🔒 SEGURIDAD: Segunda capa de limpieza en will-quit
app.on('will-quit', event => {
  console.log('[APP] Última limpieza antes de salir...')
  if (audioAnalyzer) {
    audioAnalyzer.killAllProcesses()
  }
})

// Quitta when all windows are closed, except on macOS. There, it's common
// for applications and their menu bar to stay active until the user quits
// explicitly with Cmd + Q.
app.on('window-all-closed', () => {
  // 🔒 SEGURIDAD: Limpiar procesos Python al cerrar todas las ventanas
  if (audioAnalyzer) {
    audioAnalyzer.killAllProcesses()
  }
  
  if (process.platform !== 'darwin') {
    app.quit()
  }
})

// 🔒 SEGURIDAD: Manejar señales del sistema para limpieza en cierres forzosos
// Esto cubre casos como Task Manager (Windows), kill (Linux/Mac), Ctrl+C en terminal, etc.
process.on('SIGINT', () => {
  console.log('[APP] SIGINT recibido - Limpiando procesos...')
  if (audioAnalyzer) {
    audioAnalyzer.killAllProcesses()
  }
  app.quit()
})

process.on('SIGTERM', () => {
  console.log('[APP] SIGTERM recibido - Limpiando procesos...')
  if (audioAnalyzer) {
    audioAnalyzer.killAllProcesses()
  }
  app.quit()
})

// 🔒 SEGURIDAD: Manejar excepciones no capturadas para evitar crashes sin limpieza
process.on('uncaughtException', error => {
  console.error('[APP] Excepción no capturada:', error)
  if (audioAnalyzer) {
    audioAnalyzer.killAllProcesses()
  }
  // No salir inmediatamente, solo limpiar recursos
})

// In this file you can include the rest of your app"s specific main process
// code. You can also put them in separate files and require them here.
