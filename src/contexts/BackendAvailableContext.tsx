import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { API_BASE_URL } from '../services/backendApi'

const BackendAvailableContext = createContext<boolean>(true)

export function useBackendAvailable() {
  return useContext(BackendAvailableContext)
}

export function BackendAvailableProvider({ children }: { children: ReactNode }) {
  const [available, setAvailable] = useState<boolean>(() => {
    try {
      const cached = sessionStorage.getItem('audiorr:backendAvailable')
      return cached !== null ? JSON.parse(cached) : true // optimistic default
    } catch {
      return true
    }
  })

  useEffect(() => {
    let mounted = true

    const check = async () => {
      try {
        // Any response (even 404) means the backend server is reachable
        await fetch(`${API_BASE_URL}/api/health`, {
          method: 'HEAD',
          signal: AbortSignal.timeout(5000),
        })
        if (mounted) {
          setAvailable(true)
          try { sessionStorage.setItem('audiorr:backendAvailable', 'true') } catch {}
        }
      } catch {
        if (mounted) {
          setAvailable(false)
          try { sessionStorage.setItem('audiorr:backendAvailable', 'false') } catch {}
        }
      }
    }

    check()

    // Re-check every 5 minutes as a fallback
    const interval = setInterval(check, 5 * 60 * 1000)

    // Re-check immediately when network comes back (e.g. VPN connected)
    const onOnline = () => { check() }
    window.addEventListener('online', onOnline)

    // Re-check when user returns to the app (tab/app focus)
    const onVisible = () => {
      if (document.visibilityState === 'visible') check()
    }
    document.addEventListener('visibilitychange', onVisible)

    return () => {
      mounted = false
      clearInterval(interval)
      window.removeEventListener('online', onOnline)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [])

  return (
    <BackendAvailableContext.Provider value={available}>
      {children}
    </BackendAvailableContext.Provider>
  )
}
