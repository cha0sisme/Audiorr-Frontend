/**
 * Separa una cadena de artistas por múltiples delimitadores
 * Maneja: commas, ", ", " & ", " and ", " with ", " feat. ", " ft. ", " featuring "
 * Maneja casos especiales como "Tyler, The Creator" donde la coma es parte del nombre
 */
export function splitArtists(artistString: string): string[] {
  if (!artistString) return []

  // Patrones donde la coma es parte del nombre del artista
  // Ejemplos: "Tyler, The Creator", "Artist, A Tribe Called Quest"
  const protectedPatterns: Array<{ pattern: RegExp; placeholder: string }> = [
    { pattern: /,\s+The\s+([A-Z][a-zA-Z\s]+?)(?=,|$|&|with|feat|ft|featuring)/gi, placeholder: '|||THE_$1|||' },
    { pattern: /,\s+A\s+([A-Z][a-zA-Z\s]+?)(?=,|$|&|with|feat|ft|featuring)/gi, placeholder: '|||A_$1|||' },
  ]

  // Nombres exactos que no deben separarse por sus delimitadores internos
  const protectedExactNames = [
    { name: 'Ca7riel & Paco Amoroso', placeholder: '|||CA7RIEL_PACO|||' },
    { name: 'Fito & Fitipaldis', placeholder: '|||FITO_FITIPALDIS|||' },
    { name: 'Earth, Wind & Fire', placeholder: '|||EWF|||' },
    { name: '¡Silencio, Ahora, Silencio!', placeholder: '|||SAS|||' },
  ]

  let normalized = artistString
  const replacements: Array<{ placeholder: string; original: string }> = []

  // Reemplazar nombres exactos primero
  protectedExactNames.forEach(({ name, placeholder }) => {
    if (new RegExp(name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi').test(normalized)) {
      const regex = new RegExp(name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi')
      const matches = Array.from(normalized.matchAll(regex))
      for (let i = matches.length - 1; i >= 0; i--) {
        const match = matches[i]
        const original = match[0]
        replacements.push({ placeholder, original })
        normalized =
          normalized.substring(0, match.index) +
          placeholder +
          normalized.substring(match.index! + original.length)
      }
    }
  })

  // Reemplazar temporalmente los patrones protegidos (de atrás hacia adelante para mantener índices)
  protectedPatterns.forEach(({ pattern, placeholder }) => {
    const matches = Array.from(normalized.matchAll(pattern))
    // Procesar de atrás hacia adelante para no afectar los índices
    for (let i = matches.length - 1; i >= 0; i--) {
      const match = matches[i]
      const original = match[0]
      const capturedText = match[1]
      const uniquePlaceholder = placeholder.replace('$1', capturedText)
      replacements.push({ placeholder: uniquePlaceholder, original })
      // Reemplazar desde el inicio del match
      normalized =
        normalized.substring(0, match.index) +
        uniquePlaceholder +
        normalized.substring(match.index! + original.length)
    }
  })

  // Normalizar la cadena y dividir por múltiples delimitadores
  // Orden: primero los más específicos (feat., ft.) luego los más generales (with, and)
  normalized = normalized
    .replace(/\s+feat\.?\s+/gi, ', ') // Maneja feat y feat.
    .replace(/\s+ft\.?\s+/gi, ', ')   // Maneja ft y ft.
    .replace(/\s+featuring\s+/gi, ', ')
    .replace(/\s+with\s+/gi, ', ')
    .replace(/\s+&\s+/g, ', ')
    .replace(/\s+and\s+/gi, ', ')
    .replace(/\s+x\s+/gi, ', ')      // Separador "x"
    .replace(/\s+•\s+/g, ', ')       // Separador "•"

  // Dividir por commas y limpiar espacios
  const artists = normalized
    .split(',')
    .map(artist => artist.trim())
    .filter(artist => artist.length > 0)

  // Restaurar los patrones originales
  return artists.map(artist => {
    let restored = artist
    replacements.forEach(({ placeholder, original }) => {
      if (restored.includes(placeholder)) {
        restored = restored.replace(placeholder, original)
      }
    })
    return restored
  })
}

/**
 * Verifica si un artista específico está en una cadena de artistas (incluyendo colaboraciones)
 */
export function isArtistInString(artistName: string, artistString: string): boolean {
  if (!artistName || !artistString) return false

  const normalized = artistString.toLowerCase()
  const searchName = artistName.toLowerCase()

  // Verificar si el artista está en la lista de artistas
  const artistsList = splitArtists(artistString)
  const found = artistsList.some(artist => artist.toLowerCase() === searchName)

  if (found) return true

  // Fallback: verificación básica por si acaso
  return (
    normalized === searchName ||
    normalized.includes(searchName + ',') ||
    normalized.includes(', ' + searchName) ||
    normalized.includes(searchName + ' &') ||
    normalized.includes('& ' + searchName) ||
    normalized.includes(searchName + ' and') ||
    normalized.includes('and ' + searchName) ||
    normalized.includes(searchName + ' with') ||
    normalized.includes('with ' + searchName) ||
    normalized.includes(' ' + searchName + ' ') ||
    normalized.startsWith(searchName + ' ') ||
    normalized.endsWith(' ' + searchName)
  )
}
