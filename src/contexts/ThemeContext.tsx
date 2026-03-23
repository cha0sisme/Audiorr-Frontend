import { createContext, useContext, useState, useEffect, ReactNode, useCallback } from 'react'

type Theme = 'light' | 'dark' | 'system'

interface ThemeContextType {
  theme: Theme
  setTheme: (theme: Theme) => void
  isDark: boolean
}

const ThemeContext = createContext<ThemeContextType | undefined>(undefined)

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [theme, setThemeState] = useState<Theme>(() => {
    const savedTheme = localStorage.getItem('theme') as Theme | null
    return savedTheme || 'light' // Default to light theme
  })

  // Calcular si el tema actual es oscuro
  const getIsDark = useCallback(() => {
    const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)')
    return theme === 'dark' || (theme === 'system' && mediaQuery.matches)
  }, [theme])

  const [isDark, setIsDark] = useState(getIsDark)

  useEffect(() => {
    const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)')
    const root = window.document.documentElement

    const applyTheme = () => {
      const dark = theme === 'dark' || (theme === 'system' && mediaQuery.matches)
      setIsDark(dark)

      // Swap atómico: añadir y quitar en el mismo frame para evitar
      // que ambas clases coexistan y los componentes se desincronicen
      root.classList.toggle('dark', dark)
      root.classList.toggle('light', !dark)

      // Actualizar el color de fondo del html para precarga
      root.style.backgroundColor = dark ? '#1f2937' : '#f3f4f6'
      root.style.colorScheme = dark ? 'dark' : 'light'
    }

    applyTheme() // Aplicar el tema al cargar y al cambiar `theme`

    // Escuchar cambios en el sistema si el tema es 'system'
    mediaQuery.addEventListener('change', applyTheme)
    return () => mediaQuery.removeEventListener('change', applyTheme)
  }, [theme])

  const setTheme = useCallback((newTheme: Theme) => {
    localStorage.setItem('theme', newTheme)
    setThemeState(newTheme)
  }, [])

  return (
    <ThemeContext.Provider value={{ theme, setTheme, isDark }}>
      {children}
    </ThemeContext.Provider>
  )
}

export function useTheme() {
  const context = useContext(ThemeContext)
  if (context === undefined) {
    throw new Error('useTheme must be used within a ThemeProvider')
  }
  return context
}
