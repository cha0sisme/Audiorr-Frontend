import React from 'react'

interface HorizontalScrollSectionProps {
  title?: string
  action?: React.ReactNode
  children: React.ReactNode
  className?: string
  itemWidth?: string // tailwind class, default 'w-36 md:w-40'
}

/**
 * Reusable horizontal-scroll row — albums, playlists, artists, etc.
 * Bleeds to screen edges on mobile (counteracts parent padding).
 */
export default function HorizontalScrollSection({
  title,
  action,
  children,
  className = '',
}: HorizontalScrollSectionProps) {
  return (
    <div className={className}>
      {(title || action) && (
        <div className="flex items-center justify-between mb-4">
          {title && (
            <h2 className="text-2xl md:text-3xl font-bold text-gray-900 dark:text-white">{title}</h2>
          )}
          {action && <div className="flex-shrink-0">{action}</div>}
        </div>
      )}
      {/* -mx-4 / px-4 breaks out of the RoutesContainer padding so items bleed to the screen edge on mobile */}
      <div className="flex gap-3 md:gap-4 overflow-x-auto scrollbar-hide pb-2 -mx-4 px-4 md:mx-0 md:px-0">
        {children}
      </div>
    </div>
  )
}
