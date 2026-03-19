/**
 * Genera un color consistente para un usuario basado en su nombre
 */
export function getColorForUsername(username: string): string {
  let hash = 0
  for (let i = 0; i < username.length; i++) {
    hash = username.charCodeAt(i) + ((hash << 5) - hash)
  }

  const hue = Math.abs(hash) % 360
  const saturation = 60 + (Math.abs(hash) % 21)
  const lightness = 45 + (Math.abs(hash >> 8) % 21)

  return `hsl(${hue}, ${saturation}%, ${lightness}%)`
}

/**
 * Obtiene la inicial del nombre de usuario
 */
export function getInitial(username: string): string {
  if (!username) return '?'
  return username.trim().charAt(0).toUpperCase()
}
