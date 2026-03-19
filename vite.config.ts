import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import { resolve } from 'path'
import { execSync } from 'child_process'
import crypto from 'crypto'

const commitHash = (() => {
  try {
    return execSync('git rev-parse --short HEAD').toString().trim()
  } catch (error) {
    console.warn('[vite.config] No se pudo obtener el hash de Git (esto es normal en Docker):', error.message)
    return 'docker-build'
  }
})()

const now = new Date()
const buildDate = `${String(now.getDate()).padStart(2, '0')}.${String(now.getMonth() + 1).padStart(2, '0')}.${now.getFullYear()}`
const buildId = crypto.createHash('sha1').update(now.toISOString()).digest('hex').slice(0, 7)

// https://vitejs.dev/config/
export default defineConfig(({ mode }) => {
  // Sistema de perfiles: cambia entre 'local', 'homelab', 'production'
  const BACKEND_PROFILE = process.env.BACKEND_PROFILE || 'homelab'
  
  const BACKEND_URLS = {
    local: 'http://localhost:3001',                              // Backend local (desarrollo)
    homelab: 'http://audiorr-backend.homelab.local:2999',       // Homelab (puerto 2999 host → 3001 contenedor)
    lan: 'http://192.168.1.43:2999',                            // IP directa (fallback sin DNS)
    production: 'https://audiorr.tu-dominio.com',
    ios: process.env.TUNNEL_URL || 'https://therapeutic-hawk-vsnet-stroke.trycloudflare.com/',
  }
  
  const API_URL = BACKEND_URLS[BACKEND_PROFILE] || BACKEND_URLS.homelab
  console.log('[vite.config] 🎯 Backend Profile:', BACKEND_PROFILE)
  console.log('[vite.config] ✅ Using API_URL:', API_URL)
  
  return {
    plugins: [
      react({
        // Habilitar Fast Refresh
        fastRefresh: true,
      }),
    ],
    base: './',
    build: {
      outDir: 'dist',
      // Optimizaciones de build
      minify: 'esbuild',
      target: 'esnext',
      cssCodeSplit: true,
      // Aumentar límite de warnings de chunk size
      chunkSizeWarningLimit: 1000,
      rollupOptions: {
        output: {
          // Code splitting manual para vendors grandes
          manualChunks: {
            'react-vendor': ['react', 'react-dom', 'react-router-dom'],
            'player': ['./src/contexts/PlayerContext'],
            'components-heavy': [
              './src/components/NowPlayingBar',
              './src/components/QueuePanel',
            ],
          },
        },
      },
    },
    resolve: {
      alias: {
        '@': resolve(__dirname, './src'),
      },
    },
    assetsInclude: ['**/*.svg'],
    server: {
      port: 5173,
      strictPort: true,
      // Proxy para evitar problemas de CORS con el backend
      proxy: {
        '/api': {
          target: API_URL,
          changeOrigin: true,
          secure: false,
          rewrite: (path) => path, // Mantener la ruta original
        },
      },
    },
    // Optimizaciones
    optimizeDeps: {
      include: ['react', 'react-dom', 'react-router-dom'],
      exclude: ['framer-motion'], // Lazy load si no se usa mucho
    },
    define: {
      __APP_COMMIT__: JSON.stringify(commitHash),
      __BUILD_DATE__: JSON.stringify(buildDate),
      __BUILD_ID__: JSON.stringify(buildId),
      // Inyectar VITE_API_URL explícitamente con valor forzado
      'import.meta.env.VITE_API_URL': JSON.stringify(API_URL),
    },
    // Configuración para preview server (producción)
    preview: {
      allowedHosts: [
        'localhost',
        '127.0.0.1',
        'audiorr.homelab.local',
        // Permitir cualquier subdominio de homelab.local
        /\.homelab\.local$/,
        // Permitir IPs locales
        /^192\.168\.\d+\.\d+$/,
        /^10\.\d+\.\d+\.\d+$/,
        /^172\.\d+\.\d+\.\d+$/,
      ],
    },
  }
})

