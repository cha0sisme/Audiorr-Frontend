import { useState, useEffect } from 'react'
import ThemeSwitcher from './ThemeSwitcher'
import { navidromeApi } from '../services/navidromeApi'
import { backendApi } from '../services/backendApi'
import { useSettings } from '../contexts/SettingsContext'
import { PaintBrushIcon } from '@heroicons/react/24/outline'
import { CheckCircleIcon, XCircleIcon } from '@heroicons/react/24/outline'
import { SpeakerWaveIcon } from '@heroicons/react/24/outline'
import { useAudioCache } from '../hooks/useAudioCache'
import { useBackendAvailable } from '../contexts/BackendAvailableContext'

const LastFmIcon = ({ className }: { className?: string }) => (
  <svg
    className={className}
    viewBox="0 0 20 20"
    xmlns="http://www.w3.org/2000/svg"
    fill="currentColor"
    aria-hidden="true"
  >
    <path d="M8.574 14.576c-.477.348-1.455 1.024-3.381 1.024C2.532 15.6 0 13.707 0 10.195 0 6.547 2.637 4.4 5.354 4.4c3.047 0 4.183 1.108 5.144 4.109l.756 2.309c.551 1.688 1.713 2.91 4.026 2.91 1.558 0 2.382-.346 2.382-1.199 0-.67-.389-1.156-1.557-1.434l-1.559-.369c-1.9-.461-2.656-1.455-2.656-3.025 0-2.516 2.016-3.301 4.077-3.301 2.337 0 3.757.854 3.94 2.932l-2.291.277c-.092-.992-.688-1.408-1.787-1.408-1.008 0-1.627.461-1.627 1.246 0 .693.299 1.109 1.307 1.34l1.466.324c1.97.461 3.025 1.432 3.025 3.303 0 2.309-1.924 3.186-4.766 3.186-3.963 0-5.338-1.801-6.07-4.041L8.43 9.25c-.549-1.687-.99-2.902-3.006-2.902-1.398 0-3.219.916-3.219 3.756 0 2.217 1.523 3.604 3.104 3.604 1.34 0 2.146-.754 2.564-1.131l.701 1.999z" />
  </svg>
)

const DjIcon = ({ className }: { className?: string }) => (
  <svg
    className={className}
    version="1.1"
    id="_x32_"
    xmlns="http://www.w3.org/2000/svg"
    xmlnsXlink="http://www.w3.org/1999/xlink"
    viewBox="0 0 512 512"
    xmlSpace="preserve"
    fill="currentColor"
  >
    <g>
      <path
        className="st0"
        d="M230.632,191.368c-22.969,0-41.573,18.612-41.573,41.573c0,22.977,18.604,41.574,41.573,41.574 c22.97,0,41.574-18.596,41.574-41.574C272.205,209.98,253.601,191.368,230.632,191.368z"
      />
      <path
        className="st0"
        d="M482.062,249.793v-0.082h-4.102v0.082c-1.179,0.082-2.35,0.172-3.44,0.336 c-1.679-8.303-6.542-15.509-13.421-20.119C459.593,103.979,356.957,2.35,230.59,2.35C103.307,2.35,0,105.568,0,232.941 s103.307,230.591,230.59,230.591c28.767,0,56.272-5.282,81.673-14.928c9.565,15.428,21.389,29.012,34.966,39.92 c16.688,13.413,40.419,21.126,65.238,21.126c44.104,0,79.83-23.648,93.244-61.799c4.11-11.57,6.207-23.141,6.289-33.622V281.655 C512,264.72,498.751,250.8,482.062,249.793z M136.029,232.949c0-52.252,42.351-94.602,94.602-94.602 c52.251,0,94.603,42.351,94.603,94.602c0,52.251-42.352,94.603-94.603,94.603C178.38,327.552,136.029,285.2,136.029,232.949z M493.051,407.858c0,0,0,0.917,0,3.185v3.186c-0.09,8.05-1.678,17.36-5.2,27.334c-12.242,34.711-44.358,49.14-75.384,49.14 c-20.291,0-40.001-6.207-53.414-16.942c-10.98-8.884-20.963-20.037-29.012-32.697c-4.528-6.796-8.467-14.092-11.816-21.634 c-12.332-28.005-19.21-45.618-22.978-56.517c-3.774-10.817-4.618-14.838-4.782-15.935c-0.671-4.021,0.508-8.049,3.268-10.981 c2.432-2.767,5.871-4.274,9.556-4.274l1.098,0.082c1.588,0.164,3.095,0.59,4.356,1.089c1.261,0.589,2.35,1.261,3.357,2.015 c1.933,1.507,3.603,3.267,5.617,5.781c3.857,5.036,8.894,13.167,16.263,28.43c3.112,6.534,6.289,11.153,8.974,14.084 c2.686,2.932,4.782,4.275,6.207,4.782c0.835,0.418,1.425,0.418,1.843,0.418c0.499,0,0.843,0,1.261-0.253 c0.418-0.164,0.925-0.5,1.334-1.007c0.926-0.918,1.426-2.433,1.344-2.932V278.47c0-7.124,5.871-12.995,13.004-12.995 c7.205,0,13.076,5.871,13.076,12.995v75.384h12.324V253.232c0-7.124,5.789-12.995,13.003-12.995 c7.206,0,13.078,5.871,13.078,12.995v100.622h7.55h3.185V348.4v-91.982c0-7.206,5.872-12.995,12.996-12.995 c7.214,0,13.077,5.789,13.077,12.995v24.066v73.37h10.735v-72.198c0-7.206,5.871-12.995,12.995-12.995 c7.214,0,13.086,5.789,13.086,12.995V407.858z"
      />
    </g>
  </svg>
)

const SettingCard = ({
  icon,
  title,
  description,
  children,
}: {
  icon: React.ReactNode
  title: string
  description: string
  children: React.ReactNode
}) => (
  <div className="bg-white dark:bg-[#1c1c1e] rounded-2xl sm:rounded-3xl p-5 sm:p-8 border border-gray-200/80 dark:border-white/[0.08]">
    <div className="flex items-center gap-3 sm:gap-4 mb-5 sm:mb-6">
      <div className="p-3 sm:p-4 bg-gradient-to-br from-blue-500 to-purple-600 rounded-xl sm:rounded-2xl text-white flex-shrink-0">
        {icon}
      </div>
      <div className="min-w-0">
        <h2 className="text-xl sm:text-2xl font-bold text-gray-900 dark:text-white">{title}</h2>
        <p className="text-sm text-gray-600 dark:text-gray-400">{description}</p>
      </div>
    </div>
    {children}
  </div>
)

const AutomixModeSelector = () => {
  const { settings, toggleDjMode } = useSettings()
  const [isLocked, setIsLocked] = useState(false)

  const handleToggle = () => {
    if (isLocked) return
    toggleDjMode()
    setIsLocked(true)
    setTimeout(() => setIsLocked(false), 1200)
  }

  return (
    <button
      onClick={handleToggle}
      disabled={isLocked}
      className={`${
        settings.isDjMode ? 'bg-blue-600' : 'bg-gray-200 dark:bg-[#2c2c2e]'
      } relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-blue-600 focus:ring-offset-2 disabled:opacity-60 disabled:cursor-not-allowed`}
    >
      <span className="sr-only">Cambiar modo Automix</span>
      <span
        className={`${
          settings.isDjMode ? 'translate-x-5' : 'translate-x-0'
        } pointer-events-none relative inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out`}
      />
    </button>
  )
}

const WebAudioToggle = () => {
  const { settings, toggleWebAudio } = useSettings()
  const [isLocked, setIsLocked] = useState(false)

  const handleToggle = () => {
    if (isLocked) return
    toggleWebAudio()
    setIsLocked(true)
    setTimeout(() => setIsLocked(false), 1200)
  }

  return (
    <button
      onClick={handleToggle}
      disabled={isLocked}
      className={`${
        settings.useWebAudio ? 'bg-gradient-to-r from-green-500 to-emerald-600' : 'bg-gray-200 dark:bg-[#2c2c2e]'
      } relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-green-500 focus:ring-offset-2 disabled:opacity-60 disabled:cursor-not-allowed`}
    >
      <span className="sr-only">Alternar Web Audio API</span>
      <span
        className={`${
          settings.useWebAudio ? 'translate-x-5' : 'translate-x-0'
        } pointer-events-none relative inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out`}
      />
    </button>
  )
}

const ReplayGainToggle = () => {
  const { settings, toggleReplayGain } = useSettings()

  return (
    <button
      onClick={toggleReplayGain}
      className={`${
        settings.useReplayGain ? 'bg-gradient-to-r from-green-500 to-emerald-600' : 'bg-gray-200 dark:bg-[#2c2c2e]'
      } relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-green-500 focus:ring-offset-2`}
    >
      <span className="sr-only">Activar ReplayGain</span>
      <span
        className={`${
          settings.useReplayGain ? 'translate-x-5' : 'translate-x-0'
        } pointer-events-none relative inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out`}
      />
    </button>
  )
}

const OfflineIcon = ({ className }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75}>
    <path strokeLinecap="round" strokeLinejoin="round" d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2H5a2 2 0 00-2 2z" />
    <path strokeLinecap="round" strokeLinejoin="round" d="M8 12h.01M12 12h.01M16 12h.01" />
    <path strokeLinecap="round" strokeLinejoin="round" d="M12 7V3M8 3h8" />
  </svg>
)

export default function SettingsPage() {
  const { settings } = useSettings()
  const audioCache = useAudioCache()
  const backendAvailable = useBackendAvailable()
  const [lastfmApiKey, setLastfmApiKey] = useState('')
  const [lastfmHasSecret, setLastfmHasSecret] = useState(false)
  
  // Scrobbling state
  const [scrobbleEnabled, setScrobbleEnabled] = useState(() => {
    try {
      const saved = localStorage.getItem('scrobbleEnabled')
      return saved ? JSON.parse(saved) : false
    } catch {
      return false
    }
  })
  const [scrobbleStatus, setScrobbleStatus] = useState<'idle' | 'testing' | 'success' | 'error'>('idle')

  useEffect(() => {
    if (!backendAvailable) return
    const loadLastFmConfig = async () => {
      try {
        const config = await backendApi.getLastFmConfig()
        if (config?.apiKey) {
          setLastfmApiKey(config.apiKey)
          localStorage.setItem('lastfmApiKey', config.apiKey)
          setLastfmHasSecret(Boolean(config.hasSecret))
        } else {
          setLastfmApiKey('')
          localStorage.removeItem('lastfmApiKey')
          setLastfmHasSecret(false)
        }
      } catch (error) {
        console.error('Error loading Last.fm config:', error)
        setLastfmApiKey('')
        localStorage.removeItem('lastfmApiKey')
        setLastfmHasSecret(false)
      }
    }

    loadLastFmConfig()
  }, [backendAvailable])

  const handleLastFmApiKeyChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setLastfmApiKey(e.target.value)
  }

  const handleSaveLastFmApiKey = async () => {
    const trimmedKey = lastfmApiKey.trim()
    if (!trimmedKey) {
      alert('Por favor, ingresa una clave válida antes de guardar.')
      return
    }

    try {
      await backendApi.saveLastFmConfig({ apiKey: trimmedKey })
      localStorage.setItem('lastfmApiKey', trimmedKey)
      setLastfmHasSecret(false)
      alert('Clave de API guardada.')
    } catch (error) {
      console.error('Error guardando Last.fm API key:', error)
      alert('No se pudo guardar la clave. Revisa los logs.')
    }
  }

  const handleDeleteLastFmApiKey = async () => {
    try {
      await backendApi.deleteLastFmConfig()
      setLastfmApiKey('')
      localStorage.removeItem('lastfmApiKey')
      setLastfmHasSecret(false)
      alert('Clave eliminada.')
    } catch (error) {
      console.error('Error eliminando Last.fm API key:', error)
      alert('No se pudo eliminar la clave.')
    }
  }

  const handleScrobbleToggle = (enabled: boolean) => {
    setScrobbleEnabled(enabled)
    localStorage.setItem('scrobbleEnabled', JSON.stringify(enabled))
    setScrobbleStatus('idle')
  }

  const testScrobble = async () => {
    setScrobbleStatus('testing')
    try {
      setScrobbleStatus('success')
      setTimeout(() => setScrobbleStatus('idle'), 3000)
    } catch (error) {
      console.error('Error testing scrobble:', error)
      setScrobbleStatus('error')
      setTimeout(() => setScrobbleStatus('idle'), 3000)
    }
  }

  return (
    <div className="max-w-5xl mx-auto space-y-6 sm:space-y-8">
      <div className="mb-6 sm:mb-8">
        <h1 className="text-2xl sm:text-4xl font-bold text-gray-900 dark:text-white">Configuración</h1>
        <p className="mt-1 sm:mt-2 text-sm sm:text-base text-gray-600 dark:text-gray-400">
          Personaliza tu experiencia en Audiorr
        </p>
      </div>

      {/* Apariencia */}
      <SettingCard
        icon={<PaintBrushIcon className="w-8 h-8" />}
        title="Apariencia"
        description="Personaliza el aspecto de la aplicación"
      >
        <div className="flex flex-wrap items-center justify-between gap-4 p-4 bg-gray-50 dark:bg-white/[0.04] rounded-2xl">
          <div className="flex-1 min-w-0">
            <p className="font-semibold text-gray-900 dark:text-white">Tema</p>
            <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
              Cambia entre modo claro y oscuro
            </p>
          </div>
          <ThemeSwitcher />
        </div>
      </SettingCard>

      {/* Automix (requiere backend) */}
      {backendAvailable && <SettingCard
        icon={<DjIcon className="w-8 h-8" />}
        title="Automix"
        description="Controla cómo se mezclan las canciones"
      >
        <div className="flex flex-wrap items-start justify-between gap-4 p-4 bg-gray-50 dark:bg-white/[0.04] rounded-2xl">
          <div className="flex-1 min-w-0">
            <p className="font-semibold text-gray-900 dark:text-white mb-2">Modo DJ</p>
            <p className="text-sm text-gray-600 dark:text-gray-400 leading-relaxed">
              Activado para mezclas dinámicas y cortes agresivos, desactivado para respetar la canción completa
            </p>
          </div>
          <AutomixModeSelector />
        </div>
      </SettingCard>}

      {/* Motor de Audio (requiere backend para análisis) */}
      {backendAvailable &&
      <SettingCard
        icon={<SpeakerWaveIcon className="w-8 h-8" />}
        title="Motor de Audio"
        description="Tecnología de reproducción y mezcla de audio"
      >
        <div className="flex flex-wrap items-start justify-between gap-4 p-4 bg-gray-50 dark:bg-white/[0.04] rounded-2xl">
          <div className="flex-1 min-w-0">
            <p className="font-semibold text-gray-900 dark:text-white mb-2">Web Audio API</p>
            <p className="text-sm text-gray-600 dark:text-gray-400 leading-relaxed mb-3">
              Motor de audio avanzado con mejor precisión en crossfade y efectos. Experimental - puede tener comportamientos inesperados.
            </p>
            <div className="flex items-center gap-2">
              <span className={`inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-medium ${
                settings.useWebAudio
                  ? 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400'
                  : 'bg-gray-100 dark:bg-white/[0.08] text-gray-600 dark:text-white/40'
              }`}>
                <div className={`w-2 h-2 rounded-full ${
                  settings.useWebAudio ? 'bg-green-500 dark:bg-green-400' : 'bg-gray-400'
                }`} />
                {settings.useWebAudio ? 'Activo (Experimental)' : 'Inactivo'}
              </span>
            </div>
          </div>
          <WebAudioToggle />
        </div>

        <div className="mt-4 flex flex-wrap items-start justify-between gap-4 p-4 bg-gray-50 dark:bg-white/[0.04] rounded-2xl">
          <div className="flex-1 min-w-0">
            <p className="font-semibold text-gray-900 dark:text-white mb-2">ReplayGain (Normalización de Volumen)</p>
            <p className="text-sm text-gray-600 dark:text-gray-400 leading-relaxed mb-3">
              Ajusta automáticamente el volumen de cada canción para que todas suenen al mismo nivel. Requiere que tu biblioteca tenga las etiquetas ReplayGain (`REPLAYGAIN_TRACK_GAIN`).
            </p>
            <div className="flex items-center gap-2">
              <span className={`inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-medium ${
                settings.useReplayGain
                  ? 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400'
                  : 'bg-gray-100 dark:bg-white/[0.08] text-gray-600 dark:text-white/40'
              }`}>
                <div className={`w-2 h-2 rounded-full ${
                  settings.useReplayGain ? 'bg-green-500 dark:bg-green-400' : 'bg-gray-400'
                }`} />
                {settings.useReplayGain ? 'Activo' : 'Inactivo'}
              </span>
            </div>
          </div>
          <ReplayGainToggle />
        </div>

        {settings.useWebAudio && (
          <div className="mt-4 rounded-2xl border border-orange-200 dark:border-orange-800 bg-gradient-to-r from-orange-50 to-yellow-50 dark:from-orange-900/20 dark:to-yellow-900/20 p-4">
            <div className="flex items-start gap-3">
              <div className="flex-shrink-0">
                <div className="w-5 h-5 bg-orange-500 rounded-full flex items-center justify-center">
                  <span className="text-white text-xs font-bold">!</span>
                </div>
              </div>
              <div>
                <p className="text-sm font-medium text-orange-900 dark:text-orange-100 mb-1">
                  Modo Experimental
                </p>
                <p className="text-sm text-orange-800 dark:text-orange-200">
                  Web Audio API está en fase experimental. Puede haber problemas de rendimiento o compatibilidad.
                  Recomendamos hacer pruebas antes de usarlo en producción.
                </p>
              </div>
            </div>
          </div>
        )}
      </SettingCard>}

      {/* Last.fm - API & Scrobbling (requiere backend) */}
      {backendAvailable && <SettingCard
        icon={<LastFmIcon className="w-8 h-8" />}
        title="Last.fm"
        description="Integración con Last.fm para recomendaciones y scrobbling"
      >
        <div className="space-y-6">
          {/* API Key Section */}
          <div className="space-y-3">
            <div>
              <label className="block font-semibold text-gray-900 dark:text-white mb-2">
                Clave de API
              </label>
              <p className="text-sm text-gray-600 dark:text-gray-400 mb-3">
                Necesaria para obtener recomendaciones desde Last.fm
              </p>
            </div>
            <input
              type="text"
              value={lastfmApiKey}
              onChange={handleLastFmApiKeyChange}
              placeholder="Introduce tu clave de API"
              className="w-full px-4 py-3 bg-gray-50 dark:bg-white/[0.06] border border-gray-300 dark:border-white/[0.15] rounded-xl text-sm focus:ring-2 focus:ring-blue-500 focus:border-transparent transition-all"
            />
            <div className="flex gap-3">
              <button
                onClick={handleSaveLastFmApiKey}
                className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white font-semibold rounded-xl transition-colors text-sm"
              >
                Guardar clave
              </button>
              <button
                onClick={handleDeleteLastFmApiKey}
                className="px-4 py-2 bg-gray-200 hover:bg-gray-300 dark:bg-white/10 dark:hover:bg-white/[0.15] text-gray-800 dark:text-white/80 font-semibold rounded-xl transition-colors text-sm"
              >
                Eliminar clave
              </button>
            </div>
            {lastfmHasSecret && !lastfmApiKey && (
              <p className="text-sm text-gray-500 dark:text-gray-400">
                Hay un secreto guardado en el backend que seguirá activo hasta que lo elimines.
              </p>
            )}
          </div>

          <div className="h-px bg-gray-200 dark:bg-white/10" />

          {/* Scrobbling Section */}
          <div className="space-y-4">
            <div className="flex items-start justify-between gap-4">
              <div className="flex-1">
                <p className="font-semibold text-gray-900 dark:text-white mb-2">Scrobbling automático</p>
                <p className="text-sm text-gray-600 dark:text-gray-400 leading-relaxed">
                  Cuando está activo, Audiorr registrará las canciones que escuches en Last.fm una vez
                  hayas reproducido al menos el 50% o cuatro minutos de la canción (lo que ocurra primero)
                </p>
              </div>
              <label className="relative inline-flex items-center cursor-pointer select-none flex-shrink-0">
                <input
                  type="checkbox"
                  checked={scrobbleEnabled}
                  onChange={event => handleScrobbleToggle(event.target.checked)}
                  className="sr-only peer"
                />
                <div className="w-14 h-7 bg-gray-200 peer-focus:outline-none rounded-full peer dark:bg-[#2c2c2e] peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:border-gray-300 after:border after:rounded-full after:h-6 after:w-6 after:transition-all dark:border-white/20 peer-checked:bg-gradient-to-r peer-checked:from-blue-600 peer-checked:to-purple-600" />
              </label>
            </div>

            <div className="flex flex-wrap items-center justify-between gap-4 p-4 bg-gray-50 dark:bg-white/[0.04] rounded-2xl">
              <div className="flex items-center gap-3">
                <span className="text-sm font-medium text-gray-700 dark:text-gray-300">Estado:</span>
                {scrobbleStatus === 'testing' && (
                  <span className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-gray-200 dark:bg-white/[0.08] text-sm text-gray-700 dark:text-white/60">
                    <div className="w-2 h-2 bg-gray-500 rounded-full animate-pulse" />
                    Probando…
                  </span>
                )}
                {scrobbleStatus === 'success' && (
                  <span className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-green-100 dark:bg-green-900/30 text-sm text-green-700 dark:text-green-400">
                    <CheckCircleIcon className="w-4 h-4" />
                    Configuración correcta
                  </span>
                )}
                {scrobbleStatus === 'error' && (
                  <span className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-red-100 dark:bg-red-900/30 text-sm text-red-700 dark:text-red-400">
                    <XCircleIcon className="w-4 h-4" />
                    Error al verificar
                  </span>
                )}
                {scrobbleStatus === 'idle' && (
                  <span className={`inline-flex items-center gap-2 px-3 py-1 rounded-full text-sm ${
                    scrobbleEnabled 
                      ? 'bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-400' 
                      : 'bg-gray-100 dark:bg-white/[0.08] text-gray-600 dark:text-white/40'
                  }`}>
                    <div className={`w-2 h-2 rounded-full ${scrobbleEnabled ? 'bg-blue-500 dark:bg-blue-400' : 'bg-gray-400'}`} />
                    {scrobbleEnabled ? 'Activo' : 'Inactivo'}
                  </span>
                )}
              </div>

              <div className="flex items-center gap-3">
                <button
                  onClick={testScrobble}
                  disabled={!scrobbleEnabled || scrobbleStatus === 'testing'}
                  className="px-4 py-2 text-sm font-medium text-gray-700 dark:text-white/70 bg-white dark:bg-white/[0.08] rounded-xl hover:bg-gray-50 dark:hover:bg-white/[0.13] transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed border border-gray-200 dark:border-white/[0.12]"
                >
                  Probar scrobble
                </button>
                <a
                  href="https://www.last.fm/api/account/create"
                  target="_blank"
                  rel="noreferrer"
                  className="px-4 py-2 text-sm font-medium bg-gradient-to-r from-red-500 to-pink-600 text-white rounded-xl hover:from-red-600 hover:to-pink-700 transition-all duration-200"
                >
                  Gestionar credenciales
                </a>
              </div>
            </div>

            {scrobbleEnabled && (
              <div className="rounded-2xl border border-blue-200 dark:border-blue-800 bg-gradient-to-r from-blue-50 to-purple-50 dark:from-blue-900/20 dark:to-purple-900/20 p-4">
                <p className="text-sm text-blue-900 dark:text-blue-100">
                  <strong className="font-semibold">Scrobbling activo.</strong> Las escuchas se sincronizarán con tu cuenta de
                  Last.fm automáticamente.
                </p>
              </div>
            )}
          </div>
        </div>
      </SettingCard>}

      {/* Caché Offline */}
      {audioCache.isAvailable && (
        <SettingCard
          icon={<OfflineIcon className="w-8 h-8" />}
          title="Caché offline"
          description="Canciones almacenadas para escucha sin conexión"
        >
          <div className="space-y-4">
            {/* Stats row */}
            <div className="grid grid-cols-2 gap-3">
              <div className="p-4 bg-gray-50 dark:bg-white/[0.04] rounded-2xl text-center">
                <p className="text-2xl font-bold text-gray-900 dark:text-white">
                  {audioCache.loading ? '…' : audioCache.entries.length}
                </p>
                <p className="text-sm text-gray-500 dark:text-gray-400 mt-0.5">canciones</p>
              </div>
              <div className="p-4 bg-gray-50 dark:bg-white/[0.04] rounded-2xl text-center">
                <p className="text-2xl font-bold text-gray-900 dark:text-white">
                  {audioCache.loading ? '…' : audioCache.formatSize(audioCache.totalSize)}
                </p>
                <p className="text-sm text-gray-500 dark:text-gray-400 mt-0.5">almacenado</p>
              </div>
            </div>

            {/* How it works info */}
            <div className="p-4 bg-blue-50 dark:bg-blue-900/20 rounded-2xl border border-blue-100 dark:border-blue-800">
              <p className="text-sm text-blue-900 dark:text-blue-100 leading-relaxed">
                <strong className="font-semibold">Automático.</strong> Las canciones se guardan la primera vez que las escuchas hasta el final. La próxima reproducción es instantánea y funciona sin conexión.
              </p>
            </div>

            {/* Cached songs list */}
            {!audioCache.loading && audioCache.entries.length > 0 && (
              <div className="rounded-2xl border border-gray-200/80 dark:border-white/5 overflow-hidden">
                <div className="max-h-[280px] overflow-y-auto divide-y divide-gray-100 dark:divide-white/[0.04]">
                  {audioCache.entries.map(entry => (
                    <div
                      key={entry.songId}
                      className="flex items-center gap-3 px-4 py-3 bg-white dark:bg-white/[0.03]"
                    >
                      <div className="flex-1 min-w-0">
                        <p className="text-sm font-semibold text-gray-900 dark:text-white truncate">
                          {entry.title || entry.songId}
                        </p>
                        {entry.artist && (
                          <p className="text-xs text-gray-500 dark:text-gray-400 truncate mt-0.5">
                            {entry.artist}
                          </p>
                        )}
                      </div>
                      <span className="text-xs text-gray-400 dark:text-gray-500 flex-shrink-0 tabular-nums">
                        {audioCache.formatSize(entry.size)}
                      </span>
                      <button
                        onClick={() => audioCache.remove(entry.songId)}
                        className="flex-shrink-0 p-1.5 text-gray-400 hover:text-red-500 dark:hover:text-red-400 transition-colors rounded-lg hover:bg-red-50 dark:hover:bg-red-900/20"
                        aria-label="Eliminar de caché"
                      >
                        <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                          <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                        </svg>
                      </button>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {/* Clear all */}
            {audioCache.entries.length > 0 && (
              <button
                onClick={async () => {
                  if (confirm(`¿Eliminar las ${audioCache.entries.length} canciones del caché (${audioCache.formatSize(audioCache.totalSize)})?`)) {
                    await audioCache.clearAll()
                  }
                }}
                className="w-full py-2.5 bg-red-50 hover:bg-red-100 dark:bg-red-900/20 dark:hover:bg-red-900/30 text-red-600 dark:text-red-400 font-semibold rounded-xl transition-colors text-sm border border-red-200 dark:border-red-800"
              >
                Limpiar caché
              </button>
            )}
          </div>
        </SettingCard>
      )}

      {/* Logout */}
      <div className="bg-white dark:bg-[#1c1c1e] rounded-2xl sm:rounded-3xl p-5 sm:p-8 border border-gray-200/80 dark:border-white/[0.08]">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h2 className="text-xl font-bold text-gray-900 dark:text-white mb-1">Cerrar sesión</h2>
            <p className="text-sm text-gray-600 dark:text-gray-400">
              Desconectar de tu servidor Navidrome
            </p>
          </div>
          <button
            onClick={() => {
              if (
                confirm(
                  '¿Estás seguro de que quieres cerrar la sesión? Se borrará la configuración del servidor.'
                )
              ) {
                navidromeApi.disconnect()
                window.location.reload()
              }
            }}
            className="px-6 py-3 bg-red-600 hover:bg-red-700 text-white font-semibold rounded-xl transition-colors text-sm"
          >
            Cerrar sesión
          </button>
        </div>
      </div>
    </div>
  )
}

