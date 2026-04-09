import { memo } from 'react'

interface Props {
  isPlaying: boolean
  className?: string
  colorClass?: string
  color?: string // inline fill color, overrides colorClass
}

function EqualizerIcon({
  isPlaying,
  className = 'w-3 h-3',
  colorClass = 'fill-gray-900 dark:fill-white',
  color,
}: Props) {
  const svgClassName = `${className} equalizer-icon`.trim()
  const groupClassName = isPlaying ? 'equalizer-icon-bars playing' : 'equalizer-icon-bars'
  const barClassName = (suffix: number) => `bar bar-${suffix}${!color ? ` ${colorClass}` : ''}`.trim()

  return (
    <svg
      viewBox="0 0 18 16"
      xmlns="http://www.w3.org/2000/svg"
      className={svgClassName}
      style={{
        // GPU acceleration y optimizaciones
        willChange: isPlaying ? 'transform' : 'auto',
        contain: 'layout style paint',
      }}
    >
      <g className={groupClassName} style={color ? { fill: color } : undefined}>
        <rect className={barClassName(1)} x="0" y="0" width="3" height="16" rx="1.5" />
        <rect className={barClassName(2)} x="5" y="0" width="3" height="16" rx="1.5" />
        <rect className={barClassName(3)} x="10" y="0" width="3" height="16" rx="1.5" />
        <rect className={barClassName(4)} x="15" y="0" width="3" height="16" rx="1.5" />
      </g>
    </svg>
  )
}

// Memoizar con comparación estricta
export default memo(EqualizerIcon, (prev, next) => {
  return prev.isPlaying === next.isPlaying &&
         prev.className === next.className &&
         prev.colorClass === next.colorClass &&
         prev.color === next.color
})
