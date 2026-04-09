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

// Module-level palette cache: imageUrl → final ColorPalette.
// Survives re-renders and page-stack navigations (cached pages, back nav).
// On a cache hit the useState initializer returns the palette synchronously,
// so PageHero renders with the correct colors on the very first paint — no flash.
const paletteCache = new Map<string, ColorPalette>()

/**
 * For solid-color albums with no detected foreground accent (e.g. pure black Donda,
 * pure white album), derive a contrasting neutral so the SongTable playing-row
 * highlight is always visible. Dark solid → light gray; Light solid → dark gray.
 */
function deriveContrastAccent(solidHex: string): string {
  const r = parseInt(solidHex.slice(1, 3), 16)
  const g = parseInt(solidHex.slice(3, 5), 16)
  const b = parseInt(solidHex.slice(5, 7), 16)
  const lum = r * 0.299 + g * 0.587 + b * 0.114
  // Pick a neutral that sits comfortably on the opposite side of the luminance range
  const val = lum < 128 ? 170 : 70
  return `#${val.toString(16).padStart(2, '0').repeat(3)}`
}

/**
 * Detects whether an image has a solid flat background color.
 *
 * Strategy — edge-first (same principle used by professional palette tools):
 *   1. Sample only the border ring (~12% of the smaller dimension).
 *      Album covers almost always show the background at the edges; the subject
 *      (artist face, graphic) occupies the centre.  This lets us detect cases
 *      like More Life (blue-grey border) or Starboy (black border) that a
 *      global pixel-count approach misses because the subject brings the
 *      background percentage below any reasonable global threshold.
 *   2. If ≥55% of edge pixels fall in the same 64-step quantisation bucket
 *      → solid background detected.
 *   3. Accent search runs over ALL pixels (not just edges) so we can still
 *      find a vibrant foreground colour (e.g. Motomami's red on white).
 */
function detectSolidColor(
  data: Uint8ClampedArray,
  width: number,
  height: number
): { isSolid: boolean; solidColor: string | null; accentColor: string | null } {
  const step = 4
  // Border ring width: at least 3px, roughly 12% of the shorter side
  const borderSize = Math.max(3, Math.floor(Math.min(width, height) * 0.12))

  const allBuckets  = new Map<string, BucketEntry>()
  const edgeBuckets = new Map<string, BucketEntry>()
  let allTotal = 0, edgeTotal = 0

  const addToBucket = (map: Map<string, BucketEntry>, key: string, r: number, g: number, b: number) => {
    const e = map.get(key)
    if (e) { e.count++; e.sumR += r; e.sumG += g; e.sumB += b }
    else map.set(key, { count: 1, sumR: r, sumG: g, sumB: b })
  }

  for (let y = 0; y < height; y += step) {
    for (let x = 0; x < width; x += step) {
      const idx = (y * width + x) * 4
      const r = data[idx], g = data[idx + 1], b = data[idx + 2]
      // Quantise each channel into 64-step buckets
      const bR = Math.floor(r / 64) * 64
      const bG = Math.floor(g / 64) * 64
      const bB = Math.floor(b / 64) * 64
      const key = `${bR},${bG},${bB}`

      addToBucket(allBuckets, key, r, g, b)
      allTotal++

      const isEdge = x < borderSize || x >= width - borderSize
                  || y < borderSize || y >= height - borderSize
      if (isEdge) {
        addToBucket(edgeBuckets, key, r, g, b)
        edgeTotal++
      }
    }
  }

  if (edgeTotal === 0) return { isSolid: false, solidColor: null, accentColor: null }

  // Find the most-populated edge bucket (background colour)
  let dominant: BucketEntry | null = null
  let dominantKey = ''
  for (const [key, entry] of edgeBuckets.entries()) {
    if (!dominant || entry.count > dominant.count) { dominant = entry; dominantKey = key }
  }

  // ≥55% of edge pixels must agree — lower than before because we're edge-only
  if (!dominant || dominant.count / edgeTotal < 0.55) {
    return { isSolid: false, solidColor: null, accentColor: null }
  }

  const bucketAvg = (e: BucketEntry) => ({
    r: Math.round(e.sumR / e.count),
    g: Math.round(e.sumG / e.count),
    b: Math.round(e.sumB / e.count),
  })
  const toHex = ({ r, g, b }: { r: number; g: number; b: number }) =>
    `#${[r, g, b].map(x => x.toString(16).padStart(2, '0')).join('')}`

  const solidColor = toHex(bucketAvg(dominant))

  // Accent search: scan ALL pixels so foreground colours in the centre are found.
  //
  // Phase 1 — vibrant accent: saturation ≥0.25, ≥1.5% of total pixels.
  //   Lower threshold than before (was 2.5%) so small but vivid elements like
  //   the red "RED" text on Whole Lotta Red are still captured.
  //
  // Phase 2 — contrast fallback: if no vibrant accent exists, pick the colour
  //   with the greatest luminance distance from the background (e.g. the dark
  //   tones of a monochrome photo on a white background, or vice-versa).
  //   Requires ≥3% of total pixels and a luminance gap of at least 50/255.
  const solidLum = (() => {
    const avg = bucketAvg(dominant)
    return avg.r * 0.299 + avg.g * 0.587 + avg.b * 0.114
  })()

  let bestAccent: BucketEntry | null = null
  let bestScore = 0

  for (const [key, entry] of allBuckets.entries()) {
    if (key === dominantKey) continue
    if (entry.count / allTotal < 0.015) continue  // noise

    const { r, g, b } = bucketAvg(entry)
    const max = Math.max(r, g, b)
    const min = Math.min(r, g, b)
    const saturation = max === 0 ? 0 : (max - min) / max
    if (saturation < 0.25) continue

    const score = saturation * (entry.count / allTotal)
    if (score > bestScore) { bestScore = score; bestAccent = entry }
  }

  // Contrast fallback — used when the foreground has little saturation
  // (e.g. monochrome photo on a white or black background).
  if (!bestAccent) {
    let bestContrast = 0
    for (const [key, entry] of allBuckets.entries()) {
      if (key === dominantKey) continue
      if (entry.count / allTotal < 0.03) continue  // needs meaningful presence

      const { r, g, b } = bucketAvg(entry)
      const lum = r * 0.299 + g * 0.587 + b * 0.114
      const contrast = Math.abs(lum - solidLum)
      if (contrast > 50 && contrast > bestContrast) {
        bestContrast = contrast
        bestAccent = entry
      }
    }
  }

  return { isSolid: true, solidColor, accentColor: bestAccent ? toHex(bucketAvg(bestAccent)) : null }
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
 *
 * Two-stage pipeline:
 *   Stage 1 — Canvas (local, fast): loads the image into an offscreen canvas,
 *     runs solid-color detection + palette extraction, and calls setColors
 *     immediately — no network wait.
 *   Stage 2 — Backend (higher quality): the HTTP request runs in parallel;
 *     when it arrives it overwrites the canvas palette and the result is cached.
 *
 * Module-level paletteCache: on a cache hit the useState initializer returns
 * the palette synchronously so there is zero flash on revisits (back navigation,
 * tab switching back to a page, etc.).
 */
export function useDominantColors(imageUrl: string | null): ColorPalette | null {
  const [colors, setColors] = useState<ColorPalette | null>(() =>
    imageUrl ? (paletteCache.get(imageUrl) ?? null) : null
  )

  useEffect(() => {
    if (!imageUrl) {
      setColors(null)
      return
    }

    // Synchronous cache hit — nothing to do, useState initializer already set it.
    const cached = paletteCache.get(imageUrl)
    if (cached) {
      setColors(cached)
      return
    }

    let cancelled = false

    const extractColors = async () => {
      try {
        // Kick off backend request immediately (runs in parallel with canvas).
        const backendPromise = backendApi.extractImageColors(imageUrl).catch(() => null)

        // Stage 1: canvas analysis — resolves as soon as the image is decoded.
        const canvasResult = await new Promise<{
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

        if (cancelled) return

        let isSolid = false
        let solidColor: string | null = null
        let accentColor: string | null = null
        let canvasPalette: ColorPalette | null = null

        if (canvasResult) {
          const solidResult = detectSolidColor(canvasResult.data, canvasResult.width, canvasResult.height)
          isSolid = solidResult.isSolid
          solidColor = solidResult.solidColor
          accentColor = solidResult.accentColor
          canvasPalette = extractCanvasPalette(canvasResult.data, canvasResult.width, canvasResult.height)
        }

        // Emit canvas colors immediately — no backend wait.
        if (canvasPalette && !cancelled) {
          const primary = isSolid && solidColor ? solidColor : canvasPalette.primary
          // For solid albums with no detected accent, derive a contrasting neutral
          // so the SongTable playing-row is always visible (pure black → #aaaaaa, etc.)
          const accent = isSolid
            ? (accentColor ?? deriveContrastAccent(solidColor ?? canvasPalette.primary))
            : canvasPalette.accent
          setColors({ ...canvasPalette, primary, accent, isSolid })
        }

        // Stage 2: refine with backend palette (better quality) when it arrives.
        const backendColors = await backendPromise
        if (cancelled) return

        const palette = backendColors ?? canvasPalette
        if (palette) {
          const primary = isSolid && solidColor ? solidColor : palette.primary
          const accent = isSolid
            ? (accentColor ?? deriveContrastAccent(solidColor ?? palette.primary))
            : palette.accent
          const final: ColorPalette = { ...palette, primary, accent, isSolid }
          setColors(final)
          paletteCache.set(imageUrl, final)
        }
      } catch (error) {
        console.error('Error extracting colors:', error)
        setColors(null)
      }
    }

    extractColors()
    return () => { cancelled = true }
  }, [imageUrl])

  return colors
}
