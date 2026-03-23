import { useState, useEffect } from 'react'
import { navidromeApi, type NavidromeConfig, type ServerInfo } from '../services/navidromeApi'
import { backendApi } from '../services/backendApi'

interface Props {
  onConnected: (config: NavidromeConfig) => void
}

export default function ServerConnection({ onConnected }: Props) {
  const [serverUrl, setServerUrl] = useState('')
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [isLoading, setIsLoading] = useState(false)
  const [error, setError] = useState('')
  const [serverInfo, setServerInfo] = useState<ServerInfo | null>(null)
  const [savedConfig, setSavedConfig] = useState<NavidromeConfig | null>(null)
  const [showFullForm, setShowFullForm] = useState(false)

  useEffect(() => {
    // Cargar configuración guardada al montar
    const config = navidromeApi.getConfig()
    if (config) {
      setSavedConfig(config)
      // Pre-llenar el formulario por si el usuario quiere editarlo
      setServerUrl(config.serverUrl)
      setUsername(config.username)
      setPassword(config.password || '')
    } else {
      // Si no hay config, mostrar el formulario completo
      setShowFullForm(true)
    }
  }, [])

  const handleConnect = async (configToUse?: NavidromeConfig) => {
    const config = configToUse || {
      serverUrl: serverUrl.replace(/\/$/, ''), // Remover trailing slash
      username,
      password,
    }

    if (!config.serverUrl || !config.username || !config.password) {
      setError('Por favor completa todos los campos')
      return
    }

    // Validar URL
    try {
      new URL(config.serverUrl)
    } catch {
      setError('URL inválida')
      return
    }

    setIsLoading(true)
    setError('')
    setServerInfo(null)

    try {
      const connected = await navidromeApi.connect(config)

      if (connected) {
        const info = await navidromeApi.ping()
        if (info) {
          // Intentar login en el backend de Audiorr para Connect
          try {
            const connectAuth = await backendApi.login(config)
            const tokenKey = config.username ? `audiorr_session_token_${config.username}` : 'audiorr_session_token'
            localStorage.setItem(tokenKey, connectAuth.token)
            console.log('[ServerConnection] Audiorr Connect session established')
          } catch (connectErr) {
            console.warn('[ServerConnection] Connect login failed, sync disabled', connectErr)
            // No bloqueamos el acceso principal a Navidrome
          }
          
          setServerInfo(info)
          onConnected(config)
        } else {
          setError('No se pudo obtener información del servidor')
        }
      } else {
        setError('Error al conectar. Verifica tus credenciales.')
      }
    } catch (err) {
      setError('Error de conexión: ' + (err instanceof Error ? err.message : 'Error desconocido'))
    } finally {
      setIsLoading(false)
    }
  }

  const handleQuickConnect = () => {
    if (savedConfig) {
      handleConnect(savedConfig)
    }
  }

  const handleDisconnect = () => {
    navidromeApi.disconnect()
    setServerInfo(null)
    setPassword('')
    setError('')
  }

  const renderFullForm = () => (
    <>
      <div>
        <label htmlFor="serverUrl" className="block text-sm font-medium text-gray-700 mb-2">
          URL del servidor
        </label>
        <input
          id="serverUrl"
          type="text"
          value={serverUrl}
          onChange={e => setServerUrl(e.target.value)}
          placeholder="http://localhost:4533"
          disabled={isLoading || !!serverInfo}
          className="w-full px-4 py-3 bg-white/50 backdrop-blur-sm border border-gray-200 text-gray-900 placeholder-gray-400 rounded-xl focus:ring-2 focus:ring-gray-400 focus:border-transparent transition disabled:bg-gray-100/50 disabled:cursor-not-allowed"
        />
      </div>

      <div>
        <label htmlFor="username" className="block text-sm font-medium text-gray-700 mb-2">
          Usuario
        </label>
        <input
          id="username"
          type="text"
          value={username}
          onChange={e => setUsername(e.target.value)}
          placeholder="Tu usuario de Navidrome"
          disabled={isLoading || !!serverInfo}
          className="w-full px-4 py-3 bg-white/50 backdrop-blur-sm border border-gray-200 text-gray-900 placeholder-gray-400 rounded-xl focus:ring-2 focus:ring-gray-400 focus:border-transparent transition disabled:bg-gray-100/50 disabled:cursor-not-allowed"
        />
      </div>

      <div>
        <label htmlFor="password" className="block text-sm font-medium text-gray-700 mb-2">
          Contraseña
        </label>
        <input
          id="password"
          type="password"
          value={password}
          onChange={e => setPassword(e.target.value)}
          placeholder="Tu contraseña"
          disabled={isLoading || !!serverInfo}
          className="w-full px-4 py-3 bg-white/50 backdrop-blur-sm border border-gray-200 text-gray-900 placeholder-gray-400 rounded-xl focus:ring-2 focus:ring-gray-400 focus:border-transparent transition disabled:bg-gray-100/50 disabled:cursor-not-allowed"
        />
      </div>
    </>
  )

  return (
    <div className="min-h-screen bg-gradient-to-br from-gray-100 via-gray-50 to-white flex items-center justify-center p-4">
      <div className="bg-white/60 backdrop-blur-2xl rounded-3xl shadow-2xl p-10 w-full max-w-md border border-white/20">
        <div className="text-center mb-8">
          <h1 className="text-5xl font-black text-gray-900 mb-2 tracking-tight">Audiorr</h1>
          <p className="text-gray-600 text-sm">Conectar con Navidrome</p>
        </div>

        <div className="space-y-5">
          {savedConfig && !showFullForm ? (
            <div className="text-center">
              <p className="text-gray-600 mb-4">
                Conectado previamente como{' '}
                <strong className="font-semibold text-gray-800">{savedConfig.username}</strong>
              </p>
              <button
                onClick={handleQuickConnect}
                disabled={isLoading}
                className="w-full bg-gray-200/80 backdrop-blur-md text-gray-900 py-3.5 rounded-xl font-bold hover:bg-gray-300/80 active:scale-[0.98] focus:outline-none focus:ring-2 focus:ring-gray-400 focus:ring-offset-2 focus:ring-offset-white transition-all disabled:opacity-50 disabled:cursor-not-allowed text-lg shadow-lg"
              >
                {isLoading ? 'Conectando...' : `Conectar`}
              </button>
              <button
                onClick={() => setShowFullForm(true)}
                className="mt-4 text-sm text-gray-600 hover:text-gray-800"
              >
                ¿Usar otra cuenta?
              </button>
            </div>
          ) : (
            renderFullForm()
          )}

          {error && (
            <div className="bg-red-50/80 backdrop-blur-sm border border-red-200 text-red-700 p-4 rounded-xl flex items-center gap-2">
              <span className="text-xl">⚠️</span>
              <span className="flex-1">{error}</span>
            </div>
          )}

          {serverInfo && (
            <div className="bg-gray-100/80 backdrop-blur-sm border border-gray-300 text-gray-700 p-4 rounded-xl">
              <p className="font-semibold flex items-center gap-2 mb-1">
                <span className="text-xl">✓</span> Conectado exitosamente
              </p>
              <p className="text-sm text-gray-600">
                <strong>{serverInfo.name}</strong> v{serverInfo.version}
              </p>
            </div>
          )}

          <div className="pt-2">
            {!serverInfo && showFullForm && (
              <button
                onClick={() => handleConnect()}
                disabled={isLoading}
                className="w-full bg-gray-200/80 backdrop-blur-md text-gray-900 py-3.5 rounded-xl font-bold hover:bg-gray-300/80 active:scale-[0.98] focus:outline-none focus:ring-2 focus:ring-gray-400 focus:ring-offset-2 focus:ring-offset-white transition-all disabled:opacity-50 disabled:cursor-not-allowed text-lg shadow-lg"
              >
                {isLoading ? 'Conectando...' : 'Conectar'}
              </button>
            )}

            {serverInfo && (
              <button
                onClick={handleDisconnect}
                className="w-full bg-gray-300/80 backdrop-blur-md text-gray-900 py-3.5 rounded-xl font-bold hover:bg-gray-400/80 active:scale-[0.98] focus:outline-none focus:ring-2 focus:ring-gray-400 focus:ring-offset-2 focus:ring-offset-white transition-all text-lg"
              >
                Desconectar
              </button>
            )}
          </div>
        </div>

        <div className="mt-6 text-center">
          <p className="text-sm text-gray-500">
            {savedConfig && !showFullForm
              ? `Servidor: ${savedConfig.serverUrl}`
              : 'Ingresa la URL de tu servidor Navidrome'}
          </p>
        </div>
      </div>
    </div>
  )
}
