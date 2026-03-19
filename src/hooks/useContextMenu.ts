import { useState, useCallback, useEffect } from 'react'
import { Song } from '../services/navidromeApi'

export const useContextMenu = () => {
  const [menu, setMenu] = useState<{
    x: number
    y: number
    song: Song
  } | null>(null)

  const handleContextMenu = useCallback((event: React.MouseEvent, song: Song) => {
    event.preventDefault()
    // Usar clientX/clientY para coordenadas relativas al viewport (compatible con position: fixed)
    const { innerWidth, innerHeight } = window
    let x = event.clientX
    let y = event.clientY

    // Estos valores son aproximados para el tamaño del menú
    if (x + 200 > innerWidth) {
      x = innerWidth - 200
    }
    if (y + 180 > innerHeight) {
      y = innerHeight - 180
    }

    setMenu({ x, y, song })
  }, [])

  const closeContextMenu = useCallback(() => {
    setMenu(null)
  }, [])

  useEffect(() => {
    // Delay registering the outside-click listener by one frame so the click
    // that opened the menu (or any iOS ghost click) doesn't close it immediately.
    let active = false
    const timer = setTimeout(() => { active = true }, 150)

    const handleClick = () => { if (active) closeContextMenu() }
    const handleEsc = (event: KeyboardEvent) => {
      if (event.key === 'Escape') closeContextMenu()
    }

    document.addEventListener('click', handleClick)
    document.addEventListener('keydown', handleEsc)

    return () => {
      clearTimeout(timer)
      document.removeEventListener('click', handleClick)
      document.removeEventListener('keydown', handleEsc)
    }
  }, [closeContextMenu])

  return {
    menu,
    handleContextMenu,
    closeContextMenu,
  }
}
