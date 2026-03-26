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

    // Re-check every 5 minutes in case backend comes back
    const interval = setInterval(check, 5 * 60 * 1000)

    return () => {
      mounted = false
      clearInterval(interval)
    }
  }, [])

  return (
    <BackendAvailableContext.Provider value={available}>
      {children}
    </BackendAvailableContext.Provider>
  )
}
