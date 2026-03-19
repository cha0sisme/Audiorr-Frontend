import { Capacitor } from '@capacitor/core'
import { NavLink, useLocation } from 'react-router-dom'
import { motion } from 'framer-motion'
import {
  HomeIcon,
  UsersIcon,
  QueueListIcon,
  MagnifyingGlassIcon,
  Squares2X2Icon,
} from '@heroicons/react/24/solid'

const tabs = [
  { to: '/',         label: 'Inicio',    icon: HomeIcon,            exact: true  },
  { to: '/artists',  label: 'Artistas',  icon: UsersIcon,           exact: false },
  { to: '/playlists',label: 'Playlists', icon: QueueListIcon,       exact: false },
  { to: '/search',   label: 'Buscar',    icon: MagnifyingGlassIcon, exact: true  },
  { to: '/audiorr',  label: 'Audiorr',   icon: Squares2X2Icon,      exact: true  },
]

const isNative = Capacitor.isNativePlatform()

export default function TabBar() {
  const location = useLocation()

  // En plataforma nativa usa la UITabBar del sistema (NativeTabBarPlugin)
  if (isNative) return null

  return (
    <nav
      className="fixed bottom-0 left-0 right-0 z-[60] md:hidden pointer-events-none"
      style={{ paddingBottom: 'env(safe-area-inset-bottom)' }}
    >
      {/* Floating pill — same glass as NowPlayingBar */}
      <div className="px-4 pb-2 pointer-events-auto">
        <div className="relative rounded-[16px] overflow-hidden bg-white/55 dark:bg-[#1c1c1e]/80 backdrop-blur-3xl backdrop-saturate-200 backdrop-brightness-105 border border-white/50 dark:border-white/[0.10] shadow-[0_8px_32px_-4px_rgba(0,0,0,0.18),0_2px_8px_-2px_rgba(0,0,0,0.10),inset_0_1px_0_rgba(255,255,255,0.65)] dark:shadow-[0_8px_32px_-4px_rgba(0,0,0,0.55),inset_0_1px_0_rgba(255,255,255,0.07)]">

          {/* Specular inner gradient — identical to NowPlayingBar */}
          <div className="absolute top-0 left-0 right-0 h-1/2 rounded-t-[16px] pointer-events-none bg-gradient-to-b from-white/35 dark:from-white/5 to-transparent z-10" />

          <div className="flex items-stretch" style={{ height: '49px' }}>
            {tabs.map(tab => {
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

                  <Icon
                    className={`w-[22px] h-[22px] transition-colors duration-150 relative z-10 ${
                      isActive
                        ? 'text-blue-500 dark:text-white'
                        : 'text-gray-400/90 dark:text-[#636366]'
                    }`}
                  />
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
      </div>
    </nav>
  )
}
