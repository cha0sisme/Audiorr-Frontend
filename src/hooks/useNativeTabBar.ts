import { useEffect } from 'react'
import { useNavigate, useLocation } from 'react-router-dom'
import { nativeTabBar, isNative, routeToTabIndex } from '../services/nativeTabBar'

export function useNativeTabBar() {
  const navigate = useNavigate()
  const location = useLocation()

  // JS → Native: mantener la UITabBar sincronizada con la ruta actual
  useEffect(() => {
    if (!isNative) return
    nativeTabBar.setActiveTab(routeToTabIndex(location.pathname))
  }, [location.pathname])

  // Native → JS: navegar cuando el usuario toca un tab nativo
  useEffect(() => {
    if (!isNative) return
    const handle = nativeTabBar.addListener((data) => {
      navigate(data.route)
    })
    return () => handle.remove()
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
}
