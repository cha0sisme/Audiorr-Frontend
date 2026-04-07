import { useState, useEffect } from 'react'

import { backendApi } from '../services/backendApi'

interface ColorPalette {
  primary: string
  secondary: string
  accent: string
  /** True when the image is dominated by a single flat color (e.g. Donda, Black Album, TLOP) */
  isSolid?: boolean
}

type BucketEntry = { count: number; sumR: number; sumG: number; sumB: number }

/**
 * Detects whether an image is dominated by a single flat color.
 * Uses RGB bucket quantization (64-step buckets = 4×4×4 = 64 possible buckets).
 * If ≥62% of sampled pixels fall in the same bucket → solid color.
 *
 * Also returns the most vibrant non-background color found (accentColor), so
 * buttons can use it instead of the background.
 * Example: Motomami (white bg, red text) → solidColor=#fff, accentColor=#e00
 */
function detectSolidColor(
  data: Uint8ClampedArray,
  width: number,
  height: number
): { isSolid: boolean; solidColor: string | null; accentColor: string | null } {
  const step = 6
  const buckets = new Map<string, BucketEntry>()
  let total = 0

  for (let y = 0; y < height; y += step) {
    for (let x = 0; x < width; x += step) {
      const idx = (y * width + x) * 4
      // Quantize each channel into 64-step buckets (0→0, 1–63→0, 64–127→64, …)
      const bR = Math.floor(data[idx] / 64) * 64
      const bG = Math.floor(data[idx + 1] / 64) * 64
      const bB = Math.floor(data[idx + 2] / 64) * 64
      const key = `${bR},${bG},${bB}`
      const existing = buckets.get(key)
      if (existing) {
        existing.count++
        existing.sumR += data[idx]
        existing.sumG += data[idx + 1]
        existing.sumB += data[idx + 2]
      } else {
        buckets.set(key, { count: 1, sumR: data[idx], sumG: data[idx + 1], sumB: data[idx + 2] })
      }
      total++
    }
  }

  if (total === 0) return { isSolid: false, solidColor: null, accentColor: null }

  // Find the most populated bucket (background color)
  let dominant: BucketEntry | null = null
  for (const entry of buckets.values()) {
    if (!dominant || entry.count > dominant.count) dominant = entry
  }

  if (!dominant || dominant.count / total < 0.62) {
    return { isSolid: false, solidColor: null, accentColor: null }
  }

  // Compute the average color within the dominant bucket for precise representation
  const bucketAvg = (e: BucketEntry) => ({
    r: Math.round(e.sumR / e.count),
    g: Math.round(e.sumG / e.count),
    b: Math.round(e.sumB / e.count),
  })
  const toHex = ({ r, g, b }: { r: number; g: number; b: number }) =>
    `#${[r, g, b].map(x => x.toString(16).padStart(2, '0')).join('')}`

  const solidColor = toHex(bucketAvg(dominant))

  // Find the most vibrant secondary color from the remaining buckets.
  // Requirements: ≥3% of total pixels, saturation ≥0.25, and colorfully distinct
  // from the background (so neutral grays/whites don't become the accent).
  let bestAccent: BucketEntry | null = null
  let bestScore = 0

  for (const entry of buckets.values()) {
    if (entry === dominant) continue
    if (entry.count / total < 0.03) continue  // too few pixels → likely noise

    const { r, g, b } = bucketAvg(entry)
    const max = Math.max(r, g, b)
    const min = Math.min(r, g, b)
    const saturation = max === 0 ? 0 : (max - min) / max
    if (saturation < 0.25) continue  // not colorful enough to be a useful accent

    // Score = saturation × relative pixel weight (rewards vivid + present colors)
    const score = saturation * (entry.count / total)
    if (score > bestScore) {
      bestScore = score
      bestAccent = entry
    }
  }

  const accentColor = bestAccent ? toHex(bucketAvg(bestAccent)) : null

  return { isSolid: true, solidColor, accentColor }
}

/**
 * Extracts a color palette from pre-computed canvas image data using strategic sampling.
 */
function extractCanvasPalette(
  data: Uint8ClampedArray,
  width: number,
  height: number
): ColorPalette {
  const samplePoints = [
    { x: 0, y: 0 },
    { x: width - 1, y: 0 },
    { x: 0, y: height - 1 },
    { x: width - 1, y: height - 1 },
    { x: Math.floor(width / 2), y: Math.floor(height / 2) },
    { x: Math.floor(width / 4), y: Math.floor(height / 4) },
    { x: Math.floor((width * 3) / 4), y: Math.floor(height / 4) },
    { x: Math.floor(width / 4), y: Math.floor((height * 3) / 4) },
    { x: Math.floor((width * 3) / 4), y: Math.floor((height * 3) / 4) },
    { x: Math.floor(width / 2), y: Math.floor(height / 4) },
    { x: Math.floor(width / 2), y: Math.floor((height * 3) / 4) },
    { x: Math.floor(width / 4), y: Math.floor(height / 2) },
    { x: Math.floor((width * 3) / 4), y: Math.floor(height / 2) },
  ]

  const sampledColors: { r: number; g: number; b: number; brightness: number; saturation: number }[] = []

  for (const point of samplePoints) {
    const index = (point.y * width + point.x) * 4
    const r = data[index]
    const g = data[index + 1]
    const b = data[index + 2]
    const brightness = r * 0.299 + g * 0.587 + b * 0.114
    const max = Math.max(r, g, b)
    const min = Math.min(r, g, b)
    const saturation = max === 0 ? 0 : (max - min) / max
    sampledColors.push({ r, g, b, brightness, saturation })
  }

  const vibrantColors = sampledColors.filter(c => c.saturation > 0.1 && c.brightness > 30)
  const colorsToUse = vibrantColors.length > 0 ? vibrantColors : sampledColors

  colorsToUse.sort((a, b) => {
    const scoreA = a.saturation * 0.7 + (a.brightness * 0.3) / 255
    const scoreB = b.saturation * 0.7 + (b.brightness * 0.3) / 255
    return scoreB - scoreA
  })

  const primaryIndex = Math.floor(colorsToUse.length / 3)
  const secondaryIndex = Math.floor((colorsToUse.length * 2) / 3)

  const rgbToHex = (r: number, g: number, b: number) =>
    `#${[r, g, b].map(x => x.toString(16).padStart(2, '0')).join('')}`

  return {
    primary: rgbToHex(colorsToUse[primaryIndex].r, colorsToUse[primaryIndex].g, colorsToUse[primaryIndex].b),
    secondary: rgbToHex(colorsToUse[secondaryIndex].r, colorsToUse[secondaryIndex].g, colorsToUse[secondaryIndex].b),
    accent: rgbToHex(colorsToUse[0].r, colorsToUse[0].g, colorsToUse[0].b),
  }
}

/**
 * Hook to extract dominant colors from an image.
 * Runs canvas analysis and backend extraction in parallel.
 * Canvas analysis also detects flat/solid-color albums (isSolid flag).
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
        // Load image into canvas for solid detection + fallback palette extraction.
        // Runs in parallel with the backend request.
        const canvasPromise = new Promise<{
          data: Uint8ClampedArray
          width: number
          height: number
        } | null>(resolve => {
          const img = new Image()
          img.crossOrigin = 'anonymous'
          img.onload = () => {
            const canvas = document.createElement('canvas')
            const ctx = canvas.getContext('2d')
            if (!ctx) { resolve(null); return }
            const maxSize = 200
            const scale = Math.min(maxSize / img.width, maxSize / img.height)
            canvas.width = Math.max(1, Math.round(img.width * scale))
            canvas.height = Math.max(1, Math.round(img.height * scale))
            ctx.drawImage(img, 0, 0, canvas.width, canvas.height)
            try {
              const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height)
              resolve({ data: imageData.data, width: canvas.width, height: canvas.height })
            } catch {
              resolve(null) // CORS taint — canvas read blocked
            }
          }
          img.onerror = () => resolve(null)
          img.src = imageUrl
        })

        const backendPromise = backendApi.extractImageColors(imageUrl).catch(() => null)

        const [canvasResult, backendColors] = await Promise.all([canvasPromise, backendPromise])

        let isSolid = false
        let solidColor: string | null = null
        let accentColor: string | null = null
        let canvasPalette: ColorPalette | null = null

        if (canvasResult) {
          const solidResult = detectSolidColor(canvasResult.data, canvasResult.width, canvasResult.height)
          isSolid = solidResult.isSolid
          solidColor = solidResult.solidColor
          accentColor = solidResult.accentColor

          if (!backendColors) {
            canvasPalette = extractCanvasPalette(canvasResult.data, canvasResult.width, canvasResult.height)
          }
        }

        const palette = backendColors ?? canvasPalette
        if (palette) {
          // When solid:
          //   primary  → exact background color (dominant bucket)
          //   accent   → most vibrant non-background color found (e.g. red on Motomami's white)
          //              falls back to palette.accent if no vivid secondary color was detected
          const primary = isSolid && solidColor ? solidColor : palette.primary
          const accent = isSolid && accentColor ? accentColor : palette.accent
          setColors({ ...palette, primary, accent, isSolid })
        }
      } catch (error) {
        console.error('Error extracting colors:', error)
        setColors(null)
      }
    }

    extractColors()
  }, [imageUrl])

  return colors
}
