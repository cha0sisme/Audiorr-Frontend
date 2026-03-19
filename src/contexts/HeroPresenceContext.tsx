import { createContext, useContext, useState, ReactNode } from 'react'

interface HeroPresenceContextType {
  heroPresent: boolean
  setHeroPresent: (present: boolean) => void
}

const HeroPresenceContext = createContext<HeroPresenceContextType | undefined>(undefined)

export function HeroPresenceProvider({ children }: { children: ReactNode }) {
  const [heroPresent, setHeroPresent] = useState(false)

  return (
    <HeroPresenceContext.Provider value={{ heroPresent, setHeroPresent }}>
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
