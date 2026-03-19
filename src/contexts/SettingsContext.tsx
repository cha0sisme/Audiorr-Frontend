import { createContext, useContext, useState, useEffect, ReactNode } from 'react'

export type AutomixMode = 'normal' | 'dj' // This can be removed later if not needed elsewhere

interface Settings {
  isDjMode: boolean
  useWebAudio: boolean
  useReplayGain: boolean
}

interface SettingsContextType {
  settings: Settings
  toggleDjMode: () => void
  toggleWebAudio: () => void
  toggleReplayGain: () => void
}

const SettingsContext = createContext<SettingsContextType | undefined>(undefined)

const LS_KEY = 'audiorr_settings'

export function SettingsProvider({ children }: { children: ReactNode }) {
  const [settings, setSettings] = useState<Settings>({
    isDjMode: false, // Default value
    useWebAudio: false, // Default: usar HTML Audio (sistema actual)
    useReplayGain: true, // Default: usar ReplayGain
  })

  useEffect(() => {
    try {
      const savedSettingsRaw = localStorage.getItem(LS_KEY)
      if (savedSettingsRaw) {
        const savedSettings = JSON.parse(savedSettingsRaw)
        // Ensure compatibility with old settings structure
        const newSettings: Settings = {
          isDjMode: savedSettings.isDjMode ?? (savedSettings.automixMode === 'dj' || false),
          useWebAudio: savedSettings.useWebAudio ?? false,
          useReplayGain: savedSettings.useReplayGain ?? true,
        }
        setSettings(newSettings)
      }
    } catch (error) {
      console.error('Failed to load settings from localStorage', error)
    }
  }, [])

  const saveSettings = (newSettings: Settings) => {
    try {
      localStorage.setItem(LS_KEY, JSON.stringify(newSettings))
      setSettings(newSettings)
    } catch (error) {
      console.error('Failed to save settings to localStorage', error)
    }
  }

  const toggleDjMode = () => {
    const newSettings = { ...settings, isDjMode: !settings.isDjMode }
    saveSettings(newSettings)
  }

  const toggleWebAudio = () => {
    const newSettings = { ...settings, useWebAudio: !settings.useWebAudio }
    saveSettings(newSettings)
    // Log para debugging
    console.log(`[Settings] Web Audio ${newSettings.useWebAudio ? 'activado' : 'desactivado'}`)
  }

  const toggleReplayGain = () => {
    const newSettings = { ...settings, useReplayGain: !settings.useReplayGain }
    saveSettings(newSettings)
  }

  const value = {
    settings,
    toggleDjMode,
    toggleWebAudio,
    toggleReplayGain,
  }

  return <SettingsContext.Provider value={value}>{children}</SettingsContext.Provider>
}

export function useSettings() {
  const context = useContext(SettingsContext)
  if (context === undefined) {
    throw new Error('useSettings must be used within a SettingsProvider')
  }
  return context
}
