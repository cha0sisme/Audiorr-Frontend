import { Capacitor } from '@capacitor/core'

export const isNative = Capacitor.isNativePlatform()

export const TAB_ROUTES = ['/', '/artists', '/playlists', '/audiorr', '/search']

export function routeToTabIndex(pathname: string): number {
  if (pathname === '/') return 0
  const idx = TAB_ROUTES.findIndex((r, i) => i > 0 && pathname.startsWith(r))
  return idx >= 0 ? idx : 0
}

function postMessage(name: string, data: unknown) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  ;(window as any).webkit?.messageHandlers?.[name]?.postMessage(data)
}

export const nativeTabBar = {
  setActiveTab(index: number): void {
    if (!isNative) return
    postMessage('nativeSetActiveTab', { index })
  },

  addListener(fn: (data: { route: string }) => void): { remove: () => void } {
    const handler = (e: Event) => fn((e as CustomEvent).detail)
    window.addEventListener('_nativeTabTap', handler as EventListener)
    return { remove: () => window.removeEventListener('_nativeTabTap', handler as EventListener) }
  },
}
