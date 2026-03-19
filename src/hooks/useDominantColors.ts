import { useState, useEffect } from 'react'

import { backendApi } from '../services/backendApi'

interface ColorPalette {
  primary: string
  secondary: string
  accent: string
}

/**
 * Hook para extraer colores dominantes de una imagen
 * Escanea múltiples puntos de la imagen para obtener una paleta
 */
export function useDominantColors(imageUrl: string | null): ColorPalette | null {
  const [colors, setColors] = useState<ColorPalette | null>(null)

  useEffect(() => {
    if (!imageUrl) {
      setColors(null)
      return
    }

    const extractColors = async () => {
      try {
        try {
          const backendColors = await backendApi.extractImageColors(imageUrl)
          if (backendColors) {
            setColors(backendColors)
            return
          }
        } catch (err) {
          console.warn('[DominantColors] Backend extraction failed, falling back to frontend', err)
        }

        // Fallback: usar canvas en el frontend
        const img = new Image()
        img.crossOrigin = 'anonymous'

        // Intentar con credenciales para evitar problemas CORS
        img.setAttribute('crossOrigin', 'anonymous')

        await new Promise((resolve, reject) => {
          img.onload = resolve
          img.onerror = reject
          img.src = imageUrl
        })

        // Crear un canvas temporal para analizar la imagen
        const canvas = document.createElement('canvas')
        const ctx = canvas.getContext('2d')
        if (!ctx) return

        // Redimensionar la imagen para hacer el análisis más rápido
        const maxSize = 200
        const scale = Math.min(maxSize / img.width, maxSize / img.height)
        canvas.width = img.width * scale
        canvas.height = img.height * scale

        // Dibujar la imagen en el canvas
        ctx.drawImage(img, 0, 0, canvas.width, canvas.height)

        // Obtener los datos de la imagen
        const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height)
        const data = imageData.data

        // Definir puntos estratégicos para muestreo
        const samplePoints = [
          // Esquinas
          { x: 0, y: 0 },
          { x: canvas.width - 1, y: 0 },
          { x: 0, y: canvas.height - 1 },
          { x: canvas.width - 1, y: canvas.height - 1 },
          // Centro
          { x: Math.floor(canvas.width / 2), y: Math.floor(canvas.height / 2) },
          // Puntos intermedios
          { x: Math.floor(canvas.width / 4), y: Math.floor(canvas.height / 4) },
          { x: Math.floor((canvas.width * 3) / 4), y: Math.floor(canvas.height / 4) },
          { x: Math.floor(canvas.width / 4), y: Math.floor((canvas.height * 3) / 4) },
          { x: Math.floor((canvas.width * 3) / 4), y: Math.floor((canvas.height * 3) / 4) },
          // Puntos adicionales para mejor muestreo
          { x: Math.floor(canvas.width / 2), y: Math.floor(canvas.height / 4) },
          { x: Math.floor(canvas.width / 2), y: Math.floor((canvas.height * 3) / 4) },
          { x: Math.floor(canvas.width / 4), y: Math.floor(canvas.height / 2) },
          { x: Math.floor((canvas.width * 3) / 4), y: Math.floor(canvas.height / 2) },
        ]

        // Recopilar colores de los puntos de muestra
        const sampledColors: {
          r: number
          g: number
          b: number
          brightness: number
          saturation: number
        }[] = []

        for (const point of samplePoints) {
          const index = (point.y * canvas.width + point.x) * 4
          const r = data[index]
          const g = data[index + 1]
          const b = data[index + 2]

          // Calcular brillo relativo (fórmula estándar)
          const brightness = r * 0.299 + g * 0.587 + b * 0.114

          // Calcular saturación (qué tan intenso es el color, vs gris)
          const max = Math.max(r, g, b)
          const min = Math.min(r, g, b)
          const saturation = max === 0 ? 0 : (max - min) / max

          sampledColors.push({ r, g, b, brightness, saturation })
        }

        // Filtrar colores muy grises (saturación < 0.1) y muy oscuros (brillo < 30)
        const vibrantColors = sampledColors.filter(
          color => color.saturation > 0.1 && color.brightness > 30
        )

        // Si no hay colores vibrantes, usar todos
        const colorsToUse = vibrantColors.length > 0 ? vibrantColors : sampledColors

        // Ordenar por una combinación de saturación y brillo para colores más interesantes
        colorsToUse.sort((a, b) => {
          const scoreA = a.saturation * 0.7 + (a.brightness * 0.3) / 255
          const scoreB = b.saturation * 0.7 + (b.brightness * 0.3) / 255
          return scoreB - scoreA
        })

        // Seleccionar los mejores colores para la paleta
        const primaryIndex = Math.floor(colorsToUse.length / 3)
        const secondaryIndex = Math.floor((colorsToUse.length * 2) / 3)

        const rgbToHex = (r: number, g: number, b: number) => {
          return `#${[r, g, b].map(x => x.toString(16).padStart(2, '0')).join('')}`
        }

        setColors({
          primary: rgbToHex(
            colorsToUse[primaryIndex].r,
            colorsToUse[primaryIndex].g,
            colorsToUse[primaryIndex].b
          ),
          secondary: rgbToHex(
            colorsToUse[secondaryIndex].r,
            colorsToUse[secondaryIndex].g,
            colorsToUse[secondaryIndex].b
          ),
          accent: rgbToHex(colorsToUse[0].r, colorsToUse[0].g, colorsToUse[0].b),
        })
      } catch (error) {
        console.error('Error extracting colors:', error)
        setColors(null)
      }
    }

    extractColors()
  }, [imageUrl])

  return colors
}
