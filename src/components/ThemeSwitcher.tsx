import { useTheme } from '../contexts/ThemeContext'
import { SunIcon, MoonIcon, ComputerDesktopIcon } from '@heroicons/react/24/solid'

export default function ThemeSwitcher() {
  const { theme, setTheme } = useTheme()

  const options = [
    { name: 'light', icon: SunIcon, label: 'Claro' },
    { name: 'system', icon: ComputerDesktopIcon, label: 'Sistema' },
    { name: 'dark', icon: MoonIcon, label: 'Oscuro' },
  ]

  return (
    <div className="flex items-center bg-gray-200 dark:bg-gray-700 rounded-full p-0.5">
      {options.map(option => {
        const Icon = option.icon
        const isActive = theme === option.name
        return (
          <button
            key={option.name}
            onClick={() => setTheme(option.name as 'light' | 'dark' | 'system')}
            title={option.label}
            className={`p-1.5 rounded-full transition-all duration-200 ${
              isActive
                ? 'bg-white dark:bg-gray-500 shadow-sm text-gray-800 dark:text-white'
                : 'text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200'
            }`}
          >
            <Icon className="w-4 h-4" />
          </button>
        )
      })}
    </div>
  )
}
