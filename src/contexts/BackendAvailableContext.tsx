import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react'
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
  const availableRef = useRef(available)
  availableRef.current = available

  useEffect(() => {
    let mounted = true
    let interval: ReturnType<typeof setInterval>

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

    // Adaptive polling: when backend is unavailable, poll every 15s so network
    // changes (VPN on, WiFi switch) are detected quickly without waiting minutes.
    // When available, relax to every 2 minutes.
    const startPolling = () => {
      clearInterval(interval)
      const delay = availableRef.current ? 2 * 60 * 1000 : 15_000
      interval = setInterval(() => {
        check().then(() => {
          // If availability changed, restart polling with the appropriate interval
          const newDelay = availableRef.current ? 2 * 60 * 1000 : 15_000
          if (newDelay !== delay) startPolling()
        })
      }, delay)
    }

    check().then(startPolling)

    // Re-check immediately when network comes back
    const onOnline = () => { check().then(startPolling) }
    window.addEventListener('online', onOnline)

    // Re-check when user returns to the app (tab/app focus)
    const onVisible = () => {
      if (document.visibilityState === 'visible') check().then(startPolling)
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
