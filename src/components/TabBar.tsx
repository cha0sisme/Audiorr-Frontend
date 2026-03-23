import { Capacitor } from '@capacitor/core'
import { NavLink, useLocation } from 'react-router-dom'
import { motion } from 'framer-motion'
import {
  HomeIcon,
  UsersIcon,
  QueueListIcon,
  MagnifyingGlassIcon,
} from '@heroicons/react/24/solid'

/** Icono Audiorr monochrome via CSS mask — hereda currentColor */
function AudiorrIcon({ className }: { className?: string }) {
  return (
    <span
      className={className}
      style={{
        display: 'inline-block',
        width: 22,
        height: 22,
        backgroundColor: 'currentColor',
        WebkitMaskImage: 'url(/assets/logo-icon.svg)',
        WebkitMaskSize: 'contain',
        WebkitMaskRepeat: 'no-repeat',
        WebkitMaskPosition: 'center',
        maskImage: 'url(/assets/logo-icon.svg)',
        maskSize: 'contain',
        maskRepeat: 'no-repeat',
        maskPosition: 'center',
      }}
    />
  )
}

const mainTabs = [
  { to: '/',          label: 'Inicio',    icon: HomeIcon,      exact: true  },
  { to: '/artists',   label: 'Artistas',  icon: UsersIcon,     exact: false },
  { to: '/playlists', label: 'Playlists', icon: QueueListIcon, exact: false },
  { to: '/audiorr',   label: 'Audiorr',   icon: null,          exact: true  },
]

const isNative = Capacitor.isNativePlatform()

const glassClasses =
  'bg-white/55 dark:bg-[#1c1c1e]/80 backdrop-blur-3xl backdrop-saturate-200 backdrop-brightness-105 border border-white/50 dark:border-white/[0.10]'

const shadowClasses =
  'shadow-[0_8px_32px_-4px_rgba(0,0,0,0.18),0_2px_8px_-2px_rgba(0,0,0,0.10),inset_0_1px_0_rgba(255,255,255,0.65)] dark:shadow-[0_8px_32px_-4px_rgba(0,0,0,0.55),inset_0_1px_0_rgba(255,255,255,0.07)]'

export default function TabBar() {
  const location = useLocation()

  // En plataforma nativa usa la UITabBar del sistema (NativeTabBarPlugin)
  if (isNative) return null

  const isSearchActive = location.pathname === '/search'

  return (
    <nav
      className="fixed bottom-0 left-0 right-0 z-[60] md:hidden pointer-events-none"
      style={{ paddingBottom: 'env(safe-area-inset-bottom)' }}
    >
      <div className="px-4 pb-2 pointer-events-auto flex items-end gap-2">
        {/* ── Tabs principales ── */}
        <div
          className={`flex-1 relative rounded-[16px] overflow-hidden ${glassClasses} ${shadowClasses}`}
        >
          {/* Specular inner gradient */}
          <div className="absolute top-0 left-0 right-0 h-1/2 rounded-t-[16px] pointer-events-none bg-gradient-to-b from-white/35 dark:from-white/5 to-transparent z-10" />

          <div className="flex items-stretch" style={{ height: 49 }}>
            {mainTabs.map((tab) => {
              const Icon = tab.icon
              const isActive = tab.exact
                ? location.pathname === tab.to
                : location.pathname.startsWith(tab.to)

              return (
                <NavLink
                  key={tab.to}
                  to={tab.to}
                  end={tab.exact}
                  className="flex-1 flex flex-col items-center justify-center relative touch-manipulation select-none"
                >
                  {/* Spring-animated pill indicator */}
                  {isActive && (
                    <motion.div
                      layoutId="tab-pill"
                      className="absolute inset-x-[5px] inset-y-[4px] rounded-[8px] bg-black/[0.06] dark:bg-white/[0.10]"
                      transition={{ type: 'spring', damping: 28, stiffness: 340 }}
                    />
                  )}

                  {Icon ? (
                    <Icon
                      className={`w-[22px] h-[22px] transition-colors duration-150 relative z-10 ${
                        isActive
                          ? 'text-blue-500 dark:text-white'
                          : 'text-gray-400/90 dark:text-[#636366]'
                      }`}
                    />
                  ) : (
                    <AudiorrIcon
                      className={`transition-colors duration-150 relative z-10 ${
                        isActive
                          ? 'text-blue-500 dark:text-white'
                          : 'text-gray-400/90 dark:text-[#636366]'
                      }`}
                    />
                  )}

                  <span
                    className={`text-[9.5px] font-semibold leading-none tracking-tight transition-colors duration-150 relative z-10 mt-[2.5px] ${
                      isActive
                        ? 'text-blue-500 dark:text-white'
                        : 'text-gray-400/90 dark:text-[#636366]'
                    }`}
                  >
                    {tab.label}
                  </span>
                </NavLink>
              )
            })}
          </div>
        </div>

        {/* ── Botón de búsqueda separado (estilo iOS 26) ── */}
        <NavLink
          to="/search"
          className="flex-shrink-0 touch-manipulation select-none"
        >
          <div
            className={`w-[49px] h-[49px] rounded-full flex items-center justify-center relative overflow-hidden ${glassClasses} ${shadowClasses}`}
          >
            {/* Specular inner gradient */}
            <div className="absolute top-0 left-0 right-0 h-1/2 pointer-events-none bg-gradient-to-b from-white/35 dark:from-white/5 to-transparent z-10" />

            <MagnifyingGlassIcon
              className={`w-[20px] h-[20px] transition-colors duration-150 relative z-10 ${
                isSearchActive
                  ? 'text-blue-500 dark:text-white'
                  : 'text-gray-400/90 dark:text-[#636366]'
              }`}
            />
          </div>
        </NavLink>
      </div>
    </nav>
  )
}
