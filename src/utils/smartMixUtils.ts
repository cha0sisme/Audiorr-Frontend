import { Song } from '../services/navidromeApi'
import { AudioAnalysisResult } from '../hooks/useAudioAnalysis'

export const keyToCamelot = new Map<string, string>([
  // Tonalidades Mayores
  ['B', '1B'],
  ['F#', '2B'],
  ['C#', '3B'],
  ['G#', '4B'],
  ['D#', '5B'],
  ['A#', '6B'],
  ['F', '7B'],
  ['C', '8B'],
  ['G', '9B'],
  ['D', '10B'],
  ['A', '11B'],
  ['E', '12B'],
  // Tonalidades Menores
  ['G#m', '1A'],
  ['D#m', '2A'],
  ['A#m', '3A'],
  ['Fm', '4A'],
  ['Cm', '5A'],
  ['Gm', '6A'],
  ['Dm', '7A'],
  ['Am', '8A'],
  ['Em', '9A'],
  ['Bm', '10A'],
  ['F#m', '11A'],
  ['C#m', '12A'],
  // Enarmónicos (equivalentes)
  ['Gb', '2B'],
  ['Db', '3B'],
  ['Ab', '4B'],
  ['Eb', '5B'],
  ['Bb', '6B'],
  ['Ebm', '2A'],
  ['Bbm', '3A'],
])

export const parseCamelot = (code: string): { key: number; mode: 'A' | 'B' } => {
  const key = parseInt(code.slice(0, -1), 10)
  const mode = code.slice(-1) as 'A' | 'B'
  return { key, mode }
}

export const camelotDistance = (code1: string, code2: string): number => {
  const c1 = parseCamelot(code1)
  const c2 = parseCamelot(code2)

  // Misma tonalidad y modo
  if (code1 === code2) return 0

  // Misma tonalidad, modo diferente (ej. 8A y 8B)
  if (c1.key === c2.key) return 1

  // Distancia en la rueda (circular)
  let diff = Math.abs(c1.key - c2.key)
  if (diff > 6) {
    diff = 12 - diff // Distancia por el otro lado del círculo
  }

  // Si los modos son diferentes, añadimos una pequeña penalización (cambio de modo)
  if (c1.mode !== c2.mode) {
    diff += 1
  }

  return diff
}

export interface AnalyzedSong extends Song {
  analysis?: AudioAnalysisResult
}

/**
 * Evalúa los puntos de penalización individuales para el arco de energía global.
 * // Mejora SmartMix v3: Heurística para construir progresiones de energía naturales.
 */
const getPointArcPenalty = (energy: number, index: number, total: number): number => {
  const progress = index / total
  let penalty = 0
  
  // 1. Fase de subida (0-70%)
  if (progress < 0.7) {
    // Penaliza picos muy tempranos (picos de energía en el primer 20% rompen el build-up)
    if (progress < 0.2 && energy > 0.8) penalty += 15
    // Penaliza valles profundos (queremos que la energía no caiga de 0.35 en el cuerpo central)
    if (progress > 0.2 && energy < 0.35) penalty += 10
  } 
  // 2. Fase de cooldown (70-100%)
  else {
    // Penaliza si la energía no baja (evitar fatiga extrema al final de la playlist)
    if (energy > 0.85) penalty += 12
  }
  return penalty
}

/**
 * Calcula el score de arco de energía global.
 * // Mejora SmartMix v3: Función dedicada para validar la estructura de la sesión.
 */
const calculateGlobalEnergyArcScore = (songs: AnalyzedSong[]): number => {
  if (songs.length < 5) return 0
  let totalPenalty = 0
  songs.forEach((song, i) => {
    totalPenalty += getPointArcPenalty(song.analysis?.energy || 0, i, songs.length)
  })
  return totalPenalty
}

/**
 * Calcula la compatibilidad entre dos canciones analizadas.
 * v3: Añade análisis de pendiente de energía y protección contra vocal clash.
 * 
 * @param songA Canción previa.
 * @param songB Canción candidata.
 * @param history (Opcional) Historial de canciones ya mezcladas.
 * @returns Un número que representa la "penalización" (menor es mejor).
 */
export const calculateCompatibility = (
  songA: AnalyzedSong, 
  songB: AnalyzedSong,
  history: AnalyzedSong[] = []
): number => {
  const analysisA = songA.analysis
  const analysisB = songB.analysis

  // Si alguna canción no tiene análisis o tiene error, la penalización es máxima para evitarla.
  if (!analysisA || !analysisB || 'error' in analysisA || 'error' in analysisB) {
    return Infinity
  }

  // 1. Penalización por tonalidad (Peso: ~40%)
  const keyA = keyToCamelot.get(analysisA.key)
  const keyB = keyToCamelot.get(analysisB.key)
  let keyPenalty = 15 // Penalización base si no hay tonalidad clara
  if (keyA && keyB) {
    keyPenalty = camelotDistance(keyA, keyB)
  }

  // Variedad de tonalidad reciente
  let keyFatiguePenalty = 0
  if (history.length >= 3 && keyB) {
    const recentKeys = history.slice(-3).map(s => keyToCamelot.get(s.analysis?.key || ''))
    const sameKeyCount = recentKeys.filter(k => k === keyB).length
    if (sameKeyCount >= 2) keyFatiguePenalty = 8
  }

  // 2. Penalización por BPM (Peso: ~20%)
  const bpmDiff = Math.abs(analysisA.bpm - analysisB.bpm)
  const bpmPenalty = Math.pow(bpmDiff, 1.4) / 8

  // 3. Penalización por energía general (Peso: ~7%)
  const energyDiff = Math.abs(analysisA.energy - analysisB.energy)
  let energyPenalty = Math.pow(energyDiff, 2) * 15

  // // Mejora SmartMix v3: Protección contra "valle de energía" (evitar 2 canciones muy flojas seguidas)
  if (analysisA.energy < 0.35 && analysisB.energy < 0.35) {
    energyPenalty += 15
  }

  // 4. Perfil de transición Outro -> Intro (Peso: ~23%)
  let transitionPenalty = 0
  if (analysisA.energyProfile && analysisB.energyProfile) {
    const {
      outro: outroA,
      outroSlope: slopeA,
      outroVocals: vocalsA
    } = analysisA.energyProfile
    const {
      intro: introB,
      introSlope: slopeB,
      introVocals: vocalsB
    } = analysisB.energyProfile

    // Proximidad de energía local
    const profileDiff = Math.abs(outroA - introB)
    transitionPenalty = Math.pow(profileDiff, 2) * 40

    // // Mejora SmartMix v3: Bonus por flow natural (outro baja e intro sube)
    if (slopeA !== undefined && slopeB !== undefined) {
      if (slopeA < -0.05 && slopeB > 0.05) {
        transitionPenalty -= 8
      }
    }

    // // Mejora SmartMix v3: Penalización por Vocal Clash (vocales en ambos lados de la mezcla)
    if (vocalsA && vocalsB) {
      transitionPenalty += 12
    }
  } else {
    transitionPenalty = 12
  }

  // 5. Penalización por variedad de artista
  let artistPenalty = 0
  if (songA.artist === songB.artist) {
    artistPenalty = 15
  } else {
    const lastIndices = history.slice(-4).reverse()
    const artistIndex = lastIndices.findIndex(s => s.artist === songB.artist)
    if (artistIndex !== -1) {
      artistPenalty = 10 - (artistIndex * 2)
    }
  }

  // 6. Penalización por danceability (Peso: ~10%)
  // Evita pasar de una canción muy bailable a una casi estática o viceversa.
  const danceabilityDiff = Math.abs((analysisA.danceability || 0) - (analysisB.danceability || 0))
  const danceabilityPenalty = Math.pow(danceabilityDiff, 2) * 15

  const totalPenalty = (keyPenalty * 0.40) + (bpmPenalty * 0.20) + (energyPenalty * 0.07) + (transitionPenalty * 0.23) + artistPenalty + keyFatiguePenalty + danceabilityPenalty

  return totalPenalty
}

/**
 * Optimización global mediante Intercambio (Swap Search).
 * // Mejora SmartMix v3: Cambiado de 2-opt reverse a simple Swap para preservar el flow regional.
 */
const optimizeSequence = (songs: AnalyzedSong[]): AnalyzedSong[] => {
  const result = [...songs]
  const n = result.length
  let improved = true
  let passes = 0
  const maxPasses = 3 
  
  while (improved && passes < maxPasses) {
    improved = false
    for (let i = 1; i < n - 1; i++) {
      for (let j = i + 1; j < n - 1; j++) {
        // Calculamos el coste de los enlaces que se romperían/crearían
        let currentCost = 0
        let newCost = 0
        
        if (j === i + 1) {
          // Caso canciones consecutivas: i-1 -> i -> j -> j+1
          currentCost = calculateCompatibility(result[i-1], result[i]) + 
                        calculateCompatibility(result[i], result[j]) + 
                        calculateCompatibility(result[j], result[j+1])
          newCost = calculateCompatibility(result[i-1], result[j]) + 
                    calculateCompatibility(result[j], result[i]) + 
                    calculateCompatibility(result[i], result[j+1])
        } else {
          // Caso no consecutivas: i-1 -> i -> i+1  y  j-1 -> j -> j+1
          currentCost = calculateCompatibility(result[i-1], result[i]) + 
                        calculateCompatibility(result[i], result[i+1]) +
                        calculateCompatibility(result[j-1], result[j]) + 
                        calculateCompatibility(result[j], result[j+1])
          newCost = calculateCompatibility(result[i-1], result[j]) + 
                    calculateCompatibility(result[j], result[i+1]) +
                    calculateCompatibility(result[j-1], result[i]) + 
                    calculateCompatibility(result[i], result[j+1])
        }
        
        // // Mejora SmartMix v3: Influencia del arco de energía global en la decisión del swap
        const energyI = result[i].analysis?.energy || 0
        const energyJ = result[j].analysis?.energy || 0
        const arcDelta = (getPointArcPenalty(energyJ, i, n) + getPointArcPenalty(energyI, j, n)) -
                        (getPointArcPenalty(energyI, i, n) + getPointArcPenalty(energyJ, j, n))

        if (newCost + (arcDelta * 1.5) < currentCost) {
          const temp = result[i]
          result[i] = result[j]
          result[j] = temp
          improved = true
        }
      }
    }
    passes++
  }
  return result
}

/**
 * Ordena una lista de canciones aplicando el algoritmo SmartMix v3.
 */
export const sortSongs = (songs: AnalyzedSong[]): AnalyzedSong[] => {
  if (songs.length < 2) return songs

  const validSongs = songs.filter(s => s.analysis && !('error' in s.analysis))
  const invalidSongs = songs.filter(s => !s.analysis || ('error' in s.analysis))

  if (validSongs.length < 2) return [...validSongs, ...invalidSongs]

  const unmixed = [...validSongs]
  const mixed: AnalyzedSong[] = []

  // 1. ELECCIÓN DEL STARTING SONG
  // Buscamos la canción con mejor perfil para abrir: energía moderada, intro suave que construye,
  // BPM en rango cómodo y danceability media (no un pico de baile ni un tema muy lento).
  // IMPORTANTE: sin penalización por índice — la posición original es irrelevante.
  let bestStartIdx = 0
  let bestStartScore = -Infinity

  for (let i = 0; i < unmixed.length; i++) {
    const song = unmixed[i]
    const ana = song.analysis!
    let score = 0

    // BPM confortable para abrir (80-120)
    if (ana.bpm >= 80 && ana.bpm <= 120) score += 5
    // Bonus extra para rango más preciso (90-110: groove natural)
    if (ana.bpm >= 90 && ana.bpm <= 110) score += 3

    // Energía moderada al abrir (no empezar con un pico)
    if (ana.energy < 0.45) score += 4
    if (ana.energy > 0.85) score -= 25

    // Danceability moderada es ideal para abrir (no demasiado flat ni pico bailable)
    if (ana.danceability >= 0.35 && ana.danceability <= 0.70) score += 3

    if (ana.energyProfile) {
      const { intro, main, introSlope } = ana.energyProfile
      // Intro suave
      if (intro < 0.40) score += 5
      // Canción que construye (intro < main)
      if (intro < main) score += (main - intro) * 12
      // Premio máximo: intro muy tranquila que lleva a cuerpo potente
      if (intro < 0.30 && main > 0.65) score += 20
      // Bonus por intro con pendiente positiva (build-up natural)
      if (introSlope !== undefined && introSlope > 0.05) score += 4
    }

    if (score > bestStartScore) {
      bestStartScore = score
      bestStartIdx = i
    }
  }

  let currentSong = unmixed.splice(bestStartIdx, 1)[0]
  if (currentSong) mixed.push(currentSong)

  // 2. FASE GREEDY (Construcción con memoria)
  while (unmixed.length > 0) {
    let bestCandidateIndex = -1
    let bestCompatibility = Infinity

    const forceDiversity = mixed.length > 0 && mixed.length % 5 === 0

    for (let i = 0; i < unmixed.length; i++) {
      const candidate = unmixed[i]
      let compatibility = calculateCompatibility(currentSong!, candidate, mixed)
      
      if (forceDiversity && mixed.length >= 2) {
        const lastKeys = mixed.slice(-3).map(s => s.analysis?.key)
        if (lastKeys.includes(candidate.analysis?.key)) {
          compatibility += 12 
        }
      }

      if (compatibility < bestCompatibility) {
        bestCompatibility = compatibility
        bestCandidateIndex = i
      }
    }

    if (bestCandidateIndex !== -1) {
      const nextSong = unmixed.splice(bestCandidateIndex, 1)[0]
      currentSong = nextSong
      mixed.push(nextSong)
    } else {
      const nextSong = unmixed.shift()!
      currentSong = nextSong
      mixed.push(nextSong)
    }
  }

  // 3. OPTIMIZACIÓN GLOBAL (Swap Search)
  // // Mejora SmartMix v3: Optimización con arco de energía global integrado en el Swap Search.
  const optimized = mixed.length > 4 && mixed.length < 500 ? optimizeSequence(mixed) : mixed

  // // Mejora SmartMix v3: Log del score de arco final para diagnóstico.
  const finalArcScore = calculateGlobalEnergyArcScore(optimized)
  console.log(`[SmartMix v3] Finalizado. Mezcla optimizada. Arc Penalty Score: ${finalArcScore.toFixed(2)} for ${optimized.length} tracks.`)

  return [...optimized, ...invalidSongs]
} // Mejora SmartMix v3: Evolución con arcos progresivos de energía y swaps conservadores de flow.
