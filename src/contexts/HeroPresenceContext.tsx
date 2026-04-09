import { createContext, useContext, useCallback, useRef, useSyncExternalStore, ReactNode } from 'react'

interface HeroPresenceContextType {
  heroPresent: boolean
  heroCount: number
  incHero: () => void
  decHero: () => void
}

const HeroPresenceContext = createContext<HeroPresenceContextType | undefined>(undefined)

export function HeroPresenceProvider({ children }: { children: ReactNode }) {
  const countRef = useRef(0)
  const listenersRef = useRef(new Set<() => void>())

  const subscribe = useCallback((cb: () => void) => {
    listenersRef.current.add(cb)
    return () => { listenersRef.current.delete(cb) }
  }, [])

  const getSnapshot = useCallback(() => countRef.current > 0, [])
  const getCountSnapshot = useCallback(() => countRef.current, [])

  const heroPresent = useSyncExternalStore(subscribe, getSnapshot)
  const heroCount = useSyncExternalStore(subscribe, getCountSnapshot)

  const notify = useCallback(() => {
    listenersRef.current.forEach(cb => cb())
  }, [])

  const incHero = useCallback(() => { countRef.current++; notify() }, [notify])
  const decHero = useCallback(() => { countRef.current = Math.max(0, countRef.current - 1); notify() }, [notify])

  return (
    <HeroPresenceContext.Provider value={{ heroPresent, heroCount, incHero, decHero }}>
      {children}
    </HeroPresenceContext.Provider>
  )
}

export function useHeroPresence() {
  const context = useContext(HeroPresenceContext)
  if (context === undefined) {
    throw new Error('useHeroPresence must be used within a HeroPresenceProvider')
  }
  return context
}
