// ╔══════════════════════════════════════════════════════════════════════╗
// ║                                                                      ║
// ║   DJMixingService — "Crossfade Intelligence Engine" v5.0             ║
// ║   Codename: "Silent DJ"                                              ║
// ║                                                                      ║
// ║   Audiorr — Audiophile-grade music player                            ║
// ║   Copyright (c) 2025-2026 cha0sisme (github.com/cha0sisme)          ║
// ║                                                                      ║
// ║   Pure crossfade intelligence — no side effects, no audio playback.  ║
// ║   Analyzes the RELATIONSHIP between any two tracks to decide         ║
// ║   the optimal transition. The same song B will sound different       ║
// ║   depending on what song A precedes it. The best DJ is the one you   ║
// ║   don't notice — knows when to apply effects AND when to step back.  ║
// ║                                                                      ║
// ║   v1.0 — JS DJMixingAlgorithms.ts (basic crossfade + beat sync)     ║
// ║   v2.0 — Velvet Transition: equal-power curves, bass swap,           ║
// ║          harmonic BPM detection (half/double tempo), 4-level          ║
// ║          harmonic compatibility, energy compensation, lowpass sweep, ║
// ║          beat-aligned bass swap on downbeats, time-stretch with       ║
// ║          beat-quantized rate ramp, vocal trainwreck detection,       ║
// ║          forced bass management for BEAT_MATCH_BLEND/EQ_MIX          ║
// ║   v3.0 — Phantom Cut: structural fade anchoring (idealFade =         ║
// ║          entryPoint), skipBFilters for short fades/outros,            ║
// ║          phrase/downbeat trigger snapping, PeakLimiter + stereo      ║
// ║          micro-separation in executor                                 ║
// ║   v4.0 — Chameleon Mix: TransitionProfile captures the A↔B           ║
// ║          relationship as a unit. Entry point, fade, filters, and      ║
// ║          transition type all derive from the pairing — the same       ║
// ║          song transitions differently in a Pop mix vs Hip Hop mix.   ║
// ║          Outro-anchored triggers (DJ exits at outro, not at end).    ║
// ║          Calibrated energy thresholds (danceability-aware).           ║
// ║          Conservative harmonic BPM (half/double only, 6% max stretch)║
// ║   v5.0 — Silent DJ: discipline of restraint. The DJ now knows when   ║
// ║          NOT to apply effects. Bidirectional awareness (B→A flags:   ║
// ║          intro bars, immediate impact, harmonic clash level) lets    ║
// ║          A's curve adapt to what's coming. Chill recipe (cinturón    ║
// ║          quíntuple) detects tranquil context and kills moving        ║
// ║          filters (notch sweeps, dynamic Q, bass kill, stutter cut)   ║
// ║          while preserving static hygiene. Bass-of-B guard protects   ║
// ║          incoming tracks where the bass IS the song. CUT timing      ║
// ║          dead-zone snap (entries 0.05–2.5s before chorus snap        ║
// ║          backward by default) and CUT+harmonic-clash midScoop kill   ║
// ║          handle the edge cases of forced cuts. Distinguishes static  ║
// ║          filter hygiene (always-on, invisible) from dynamic filter   ║
// ║          drama (off in chill — listener doesn't want tricks where    ║
// ║          there's no drama to underline).                              ║
// ║                                                                      ║
// ╚══════════════════════════════════════════════════════════════════════╝

import Foundation

// MARK: - v13.K telemetry types (audit 2026-05-07)

/// Path por el que el calculador de entryPoint decidió la posición de B.
/// Persistido en TransitionRecord para análisis post-coche-test (qué rama
/// del entry decisor está produciendo aciertos vs fallos).
enum EntryPointSource: String, Codable {
    case smooth                // .smooth case (inline)
    case smoothChorusFallback  // .smooth con chorusStartTime fallback
    case smoothVocalAligned    // .smooth con shift atrás por chorus alignment
    case dramaticChorus        // calculateDramaticEntry: entry al chorus
    case dramaticVocal         // calculateDramaticEntry: entry vía vocalEntryTarget
    case dramaticReference     // calculateDramaticEntry: entryReference
    case dramaticFallback      // calculateDramaticEntry: bufferDuration fallback
    case punchVocalAvoidance   // calculatePunchEntry: vocalOverlapRisk == .both
    case punchChorusPromotion  // calculatePunchEntry: chorus promotion (línea 1509)
    case punchVocalTarget      // calculatePunchEntry: vocalEntryTarget
    case punchEntryReference   // calculatePunchEntry: entryReference
    case punchChorusFallback   // calculatePunchEntry: chorusStart-2 dentro de styleAffinity
    case punchBufferFallback   // calculatePunchEntry: bufferDuration fallback
    case punchEnergyBoost      // calculatePunchEntry: energyUp boost reasigna entry
    /// v15.e — el cap defensivo anti-vlfs-negativo retrajo el entry a
    /// `vocalEntryTarget` por estar el cálculo original >5s después del
    /// primer evento vocal de B. Permite cohort split en análisis post-coche.
    case punchVocalCappedRollback
    case minimal               // .minimal case (cuando exista)
    case unknown               // sin asignar (no debería ocurrir si todo el switch está cableado)
}

/// Cuando Tier 4 no dispara, etiqueta del primer gate que cortó. Permite
/// calibrar contra distribución real (vs adivinar umbrales a ciegas).
/// `nil` cuando Tier 4 dispara con éxito.
enum Tier4FailedGate: String, Codable {
    case disabled              // kEnableTier4 == false
    case typeIncompat          // gate 1: tipo no blendy (no crossfade/eqMix/BMB)
    case fadeShort             // gate 2: fadeDuration < 4s
    case aMissing              // gate 3a: safeCurrent nil/error
    case noVocalEndData        // gate 3b: cur.hasVocalEndData == false
    case outroVocal            // gate 3c: outro vocal a < 2s del crossfade start
    case bMissing              // gate 4: safeNext nil/error
    case bpmUntrusted          // gate 5a: bpmTrusted == false
    case bpmToxic              // gate 5b: BPM A o B en franja 140-180
    case noDownbeats           // gate 5c: <2 downbeats en B
    case invalidBarDur         // gate 5d: medianDelta fuera de [1, 4]s
    case perceptual            // gate 5.5: pathA/B/C todos false (intro plana)
    case vocalStart            // gate 7: vocalStart nil o ≤ 0
    case noIntroEnd            // gate 8a: introEnd ≤ 0
    case introBarsShort        // gate 8b: vocalStart ≤ introEnd + 4*barDur
    case noFirstEvent          // gate 9a: firstEventB no finite
    case structureCollision    // gate 9b: introEnd + 12*barDur ≥ firstEventB
    case clash                 // gate 10: harmonic compatibility .clash
    case rangeInvalid          // gate 11: lowerBound ≥ upperBound
    case noCandidates          // gate 12: ningún downbeat en rango con paridad correcta
    case notImproving          // gate 13: bestCandidate no mejora ≥1s sobre originalEntry
}

/// Telemetría persistida del intento de Tier 4. Se llena progresivamente
/// dentro de `computeTier4Entry`: las pendientes/densidades se calculan
/// aunque gates posteriores corten — así podemos analizar qué rangos reales
/// produce el repertorio del usuario sin necesidad de re-instrumentar.
struct Tier4Telemetry {
    var introSlopeB: Double? = nil
    var downbeatDensityB20s: Double? = nil
    var failedGate: Tier4FailedGate? = nil
}

/// DJMixingService v4.0 "Relational Mix" — pure crossfade intelligence calculations.
/// No side effects, no audio playback — just math.
enum DJMixingService {

    // MARK: - Algorithm versioning (round 2026-05-10 diagnostics-backend-port)

    /// Version semantica del algoritmo de transiciones. Bumpear en cada commit
    /// que toque `DJMixingService` o `CrossfadeExecutor`. Se persiste en cada
    /// `TransitionRecord` que se sube al backend para vincular ratings con
    /// cambios concretos del repo. Historial completo en
    /// `D:\Audiorr-shared\algorithm-versions.md`.
    public static let kAlgorithmVersion: String = "v15.o"

    /// SHA git corto del commit en el que se construyó esta build. Permite al
    /// backend distinguir "v13.O.2 antes del fix X" vs "v13.O.2 después del fix
    /// X" cuando un mismo `kAlgorithmVersion` cubre varios commits de polish.
    /// TODO(round-cloud-build): extraer en runtime desde `Bundle.main`
    /// (clave `GitCommitSha` inyectada por Xcode Cloud via xcconfig). Mientras
    /// tanto se hardcodea — bumping este string en cada commit de algoritmo
    /// es trivial y no requiere infra extra.
    public static let kBuildId: String = "v15.o-pending"

    // MARK: - Set diversity (cooldowns)

    /// Last N transition types chosen by `decideTransitionType`. Used to enforce
    /// "DJ tics" cooldowns: a VINYL_STOP every transition would feel mechanical
    /// rather than expressive. Reset on app launch — a fresh set starts clean.
    /// Single-threaded access expected (selector runs on main / audio queue).
    private static var recentTypes: [TransitionType] = []
    private static let recentTypesLimit = 12

    // MARK: - Feature flags (audit v10 2026-05-05)

    /// Tier 4 (audit v10 2026-05-05): adelanta entryPoint de B al primer kick
    /// de su intro instrumental, ANTES del chorus, cuando el setup es claro
    /// (A en outro instrumental + B con intro instrumental real + BPMs
    /// confiables fuera de franja toxica + sin ad-libs/speech en intro de B).
    /// Curva nueva `earlyBlend` en CrossfadeExecutor: B entra al ~75% desde el
    /// primer downbeat (escalon, no rampa lenta), A mantiene 100% los primeros
    /// 50% del solape, A cae acelerada en los ultimos 25%, B sube 75→100% en
    /// el downbeat del chorus. Heuristica revisada por architect (mediana de
    /// delta de downbeats vs bi*4, paridad anclada a evento musical) y backend
    /// validator (gates contra half-time franja 140-180, structure rota
    /// chorusStart<5s, vocalStart=0 literal, energy=0 espurio).
    private static let kEnableTier4 = true

    /// v13.O Commit 2 (round 2026-05-10): cap defensivo POST-snap+beat-sync
    /// sobre el entryPoint final. Atrapa los casos en los que `kChorusCap=50`
    /// del Commit 1 fue evadido por las transformaciones posteriores
    /// (phrase snap +8s en punch / +4s en dramatic, beat sync ±1 compás)
    /// o en los que el path de entry no pasa por `calculatePunchEntry`
    /// (.dramatic, .smooth, fallbacks). Gate drop-driven percussive heredado
    /// de `isBDropDrivenByPercussive(ratio>=2.0)` para preservar el oro
    /// (ej. American Wedding→Indecision r=10 con chorusStart>50). Cap=50s
    /// alineado con `kChorusCap` para coherencia perceptual: el listener
    /// no espera entrar a B después del minuto.
    private static let kEntryFinalCap: Double = 50.0

    /// Returns true if `type` should be skipped this round because it was used
    /// too recently. Called inside `decideTransitionType` before committing to
    /// an expressive type (currently only VINYL_STOP — extend as new types
    /// land in P5).
    private static func isOnCooldown(_ type: TransitionType) -> Bool {
        switch type {
        case .vinylStop:
            // Max 1 every 6 transitions (DJ recommendation: ≈2-3 spin-downs per
            // 20-track set). Less, and the gesture is wasted; more, it tics.
            return recentTypes.suffix(6).contains(.vinylStop)
        default:
            return false
        }
    }

    /// Append the chosen type to the cooldown buffer. Trim to keep memory bounded.
    private static func recordTransition(_ type: TransitionType) {
        recentTypes.append(type)
        if recentTypes.count > recentTypesLimit {
            recentTypes.removeFirst(recentTypes.count - recentTypesLimit)
        }
    }

    // MARK: - Types

    enum MixMode: String {
        case dj, normal
    }

    /// Possible high-level shapes a transition can take. CrossfadeExecutor.TransitionType
    /// must mirror this exactly (the rawValue is the wire format used to bridge them).
    enum TransitionType: String {
        case crossfade = "CROSSFADE"
        case eqMix = "EQ_MIX"
        case cut = "CUT"
        case naturalBlend = "NATURAL_BLEND"
        case beatMatchBlend = "BEAT_MATCH_BLEND"
        case cutAFadeInB = "CUT_A_FADE_IN_B"
        case fadeOutACutB = "FADE_OUT_A_CUT_B"
        case stemMix = "STEM_MIX"
        case dropMix = "DROP_MIX"
        /// Sequential handoff with a tiny gap. A fades out (cos² over ~55% of the
        /// window), short respiro of dead air (~10% of the window), then B sin²
        /// ramps in (~35%). NO overlap of the two tracks. Used when the pairing is
        /// fundamentally unmixable (incompatible BPMs) — blending them for several
        /// seconds sounds worse than a clean radio-style handoff.
        case cleanHandoff = "CLEAN_HANDOFF"
        /// Vinyl-stop / spin-down: A's playback rate ramps 1.0→0 over ~450ms with
        /// an exponential curve `y = 1-(t/T)^0.6`, then a short pause before B
        /// enters in seco. Reads as a deliberate DJ gesture for big mood / tempo
        /// drops. Cooldown: max 1 every 6 transitions (avoid making it a tic).
        case vinylStop = "VINYL_STOP"
        /// Sequential handoff (v13.O.6, F5a). A plays to its natural endTime;
        /// B enters with a 50ms cos²/sin² overlap to dodge clicks. No filter
        /// pre-roll, no EQ_MIX, no spectral shaping. Honest fallback when a
        /// pairing isn't blendable — the listener hears the end of A and the
        /// start of B with an inaudible seam. Will be the redirect target of
        /// retired DROP_MIX / STEM_MIX in F5b.
        case sequential = "SEQUENTIAL"
    }

    struct MixModeConfig {
        let minFadeDuration: Double
        let maxFadeDuration: Double
        let baseFadeDuration: Double
        let fallbackPercent: Double
        let fallbackMaxSeconds: Double
    }

    static let configs: [MixMode: MixModeConfig] = [
        .dj: MixModeConfig(
            minFadeDuration: 5, maxFadeDuration: 10, baseFadeDuration: 6,
            fallbackPercent: 0.02, fallbackMaxSeconds: 3
        ),
        .normal: MixModeConfig(
            minFadeDuration: 6, maxFadeDuration: 12, baseFadeDuration: 8,
            fallbackPercent: 0.01, fallbackMaxSeconds: 2
        ),
    ]

    /// Song analysis data (from backend or local analysis).
    struct SongAnalysis {
        var bpm: Double = 120
        var beatInterval: Double = 0
        var energy: Double = 0.5
        var danceability: Double = 0.5
        var key: String?
        var outroStartTime: Double = 0
        var introEndTime: Double = 0
        // Optional semantics (post-backend confirmation 2026-05-01):
        //   nil → unknown / no detection. Code paths must fall back to
        //         introEndHeuristic / speechSegments / introEndTime.
        //   0.0 → literal "vocal at t=0" (track opens singing).
        //   >0  → real vocal onset timestamp.
        // Never collapse nil to 0 — that conflates two distinct cases.
        var vocalStartTime: Double? = nil
        var chorusStartTime: Double = 0
        var phraseBoundaries: [Double] = []
        var downbeatTimes: [Double] = []
        // v15.g — downbeats musicales del backend (primer beat de cada compás).
        // Diferente de `downbeatTimes` que recibe beats[] por compat. Usado por
        // el snap de rampStart en CrossfadeExecutor. Vacío si el backend aún
        // no lo expone (snapshot pre-backfill).
        var realDownbeats: [Double] = []
        var meter: Int = 4
        var speechSegments: [(start: Double, end: Double)] = []
        var hasError: Bool = false
        var hasOutroData: Bool = false
        var hasIntroData: Bool = false
        var cuePoint: Double = 0
        var hasCuePoint: Bool = false
        var energyIntro: Double = 0
        var energyMain: Double = 0
        var energyOutro: Double = 0
        var hasEnergyProfile: Bool = false
        var hasIntroVocals: Bool = false
        var hasOutroVocals: Bool = false
        var hasVocalData: Bool = false
        var backendFadeInDuration: Double?
        var backendFadeOutDuration: Double?
        var backendFadeOutLeadTime: Double?
        var lastVocalTime: Double = 0
        var hasVocalEndData: Bool = false
        // BPM confidence system (Essentia cross-validation)
        var bpmConfidence: Double = 1.0   // 0-1, default 1.0 (trust) when backend doesn't provide
        var bpmEssentia: Double?          // second opinion from Essentia
        var hasBpmConfidence: Bool = false // true when backend provided bpmConfidence
        // ML override tracking
        var modelUsed: Bool = false       // true when ML overrode intro/outro values
        var introEndTimeHeuristic: Double? // heuristic value (before ML override)
        var outroStartTimeHeuristic: Double? // heuristic value (before ML override)
        // v13.G (audit 2026-05-06): perceptual decay data del backend.
        // Hasta ahora estos campos llegaban en el JSON pero nunca se mapeaban.
        // Habilitan v13.D/E (Tier 4-lite perceptual + "Transparent A") con
        // datos reales en lugar de heuristicas. nil = backend no proveyo.
        /// Pendiente de la curva de energia en el outro (>0 sube, <0 baja).
        /// Negativo significativo = A decae natural — habilita ramp-aware.
        var outroSlope: Double? = nil
        /// Pendiente de la curva de energia en el intro (>0 sube, <0 baja).
        var introSlope: Double? = nil
        /// Curva RMS de la cola (normalizada 0-1, ventanas 5s) para detectar
        /// decay perceptual fino aunque outroSlope no sea concluyente.
        var rmsTailCurve: [Double]? = nil
        /// Curva RMS de la cabeza (normalizada 0-1, ventanas 5s sobre primeros 90s).
        /// Backend la emite top-level. v13.D la usa para derivar `introSlope`
        /// localmente cuando el backend no provee EnergyProfile.introSlope.
        var rmsCurve: [Double]? = nil
        /// Curva percusiva (HPSS percussive stem) normalizada 0-1, ventanas 5s
        /// sobre primeros 90s. Backend la emite top-level (`percussiveCurve`).
        /// v13.O usa el ratio `mean[3..5]/mean[0..1]` para detectar build drop-driven
        /// agnóstico al género (Navidrome es generalista — Bruno Mars balada y The
        /// Weeknd trap-soul ambos "Contemporary R&B" en tags). El stem percusivo
        /// aísla el ritmo del intro armónico, separando balada de drop-driven.
        var percussiveCurve: [Double]? = nil
        /// Lista plural de géneros (de NavidromeSong.genres). v13.M/N usan `any()`
        /// sobre esta lista para evaluar gates correctamente en pistas multi-género
        /// (ej. Hip-Hop+Pop+R&B). El populator (QueueManager) la copia de
        /// nextSong.genres antes de invocar calculateCrossfadeConfig.
        var genres: [String] = []
        /// Sub-bass RMS <120 Hz. Medias de los primeros 15s (intro) y últimos 15s
        /// (outro) del stem sub-bass. nil cuando el backend aún no ha analizado
        /// la pista. Permite calibrar magnitud bassKill contra contenido real
        /// sub-bass de A_outro y B_intro (vs proxy broadband rmsTailCurve, que no
        /// discrimina los <120 Hz).
        var subBassIntroRms: Double? = nil
        var subBassOutroRms: Double? = nil
    }

    // MARK: - Transition Profile (A↔B Relationship)

    enum BPMRelationship {
        case identical      // diff < 3 after harmonic normalization
        case compatible     // diff 3-12 (stretchable within 8% rate change)
        /// diff 12-18: too far for invisible beat-match (would need >8% time-stretch),
        /// but close enough that a subtle gentle crossfade still works musically.
        /// Think: a DJ who can't beat-grid but blends with filters and longer fades
        /// to mask the rhythmic mismatch — the most graceful "I can't match these"
        /// move available.
        case borderline
        case incompatible   // diff > 18 (truly unmixable — sequential handoff only)
    }

    enum EnergyFlow {
        case energyUp       // B intro > A outro + 0.15
        case energyDown     // B intro < A outro - 0.15
        case steady         // within ±0.15
    }

    enum VocalOverlapRisk {
        case none           // neither has vocals in overlap zone
        case aOnly          // A has outro vocals, B intro instrumental
        case bOnly          // B has intro vocals, A outro instrumental
        case both           // vocal trainwreck risk
    }

    enum TransitionCharacter {
        case punch          // target structural moment in B (compatible BPMs, good energy)
        case smooth         // invisible blend, B starts early (incompatible BPMs)
        case dramatic       // big energy change, needs special handling
        case minimal        // both low energy, gentle handoff
    }

    /// Captures the full A↔B relationship. Computed ONCE, drives ALL downstream decisions.
    struct TransitionProfile {
        // ── Energy relationship ──
        let energyA: Double
        let energyB: Double
        let energyGap: Double       // signed: positive = B is hotter
        let energyFlow: EnergyFlow

        // ── Rhythm relationship ──
        let bpmA: Double
        let bpmB: Double            // raw
        let bpmBNormalized: Double  // after harmonic normalization
        let bpmDiff: Double         // abs(bpmA - bpmBNormalized)
        let bpmRelationship: BPMRelationship
        /// True when BOTH songs have confident BPM (≥0.5).
        /// When false, BPM-dependent decisions (beat sync, time-stretch) should be conservative.
        let bpmTrusted: Bool

        // ── Harmonic relationship ──
        let harmonic: HarmonicPenalty

        // ── Vocal relationship ──
        let vocalOverlapRisk: VocalOverlapRisk
        let aHasOutroVocals: Bool
        let bHasIntroVocals: Bool

        // ── Groove/style relationship ──
        let danceabilityA: Double
        let danceabilityB: Double
        let avgDanceability: Double
        let bassConflictRisk: Bool  // both high danceability = bass overlap

        // ── High-level character derived from the relationship ──
        let character: TransitionCharacter

        /// 0-1: how stylistically similar A and B appear.
        /// Inferred from BPM range, energy range, danceability correlation.
        /// High = same "world" (both EDM, both chill). Low = genre jump.
        let styleAffinity: Double

        let mode: MixMode
    }

    /// Complete crossfade configuration output.
    struct CrossfadeResult {
        let entryPoint: Double
        let fadeDuration: Double
        let transitionType: TransitionType
        let useFilters: Bool
        let useAggressiveFilters: Bool
        let needsAnticipation: Bool
        let anticipationTime: Double
        /// v13.O Commit 2 (round 2026-05-10): etiqueta interna del path de
        /// anticipación nuevo. nil cuando se eligió rama existente
        /// (CUT-tease / PRE_PUNCH / A2 widening puro / sin anticipación).
        /// "outroSlopeSteep" = caso nuevo de A decayendo natural.
        let anticipationReason: String?
        let beatSyncInfo: String
        let isBeatSynced: Bool
        let useTimeStretch: Bool
        let rateA: Float
        let rateB: Float
        let energyA: Double
        let energyB: Double
        let beatIntervalA: Double
        let beatIntervalB: Double
        let downbeatTimesA: [Double]
        let downbeatTimesB: [Double]
        // v15.g — downbeats musicales del backend (no beats). Vacío si el
        // backend no los expuso aún. Consumido por CrossfadeExecutor para
        // snap de rampStart en el bassKill A.
        let realDownbeatsA: [Double]
        let meterA: Int
        let useMidScoop: Bool
        let useHighShelfCut: Bool
        let isOutroInstrumental: Bool
        let isIntroInstrumental: Bool
        let danceability: Double
        let skipBFilters: Bool
        // DJ effects (Sprint 1)
        let useBassKill: Bool
        let useDynamicQ: Bool
        // DJ effects (Sprint 2 — companion sweeps on B)
        /// Phaser-style narrow parametric notch on B's band 2.
        /// Center freq sweeps 250→6000Hz exponentially while depth follows a bell
        /// (-6 → -24 → -6 dB). Adds a moving spectral hole that "rides" through B
        /// as it opens. Only activates alongside useDynamicQ when conditions allow.
        let useNotchSweep: Bool
        // DJ effects (Sprint 3 — hip-hop signature)
        /// Stutter Cut: 1/8-note volume gate over A's last 2 beats before a CUT,
        /// anchored to A's beat grid. Sounds like a DJ Premier mixtape chop.
        let useStutterCut: Bool
        let transitionReason: String
        /// Trigger bias: how many seconds earlier (negative) or later (positive) the trigger
        /// should fire relative to the default "latest possible" position.
        /// Driven by the A↔B relationship:
        ///   - minimal/smooth character → negative (trigger earlier for longer, invisible blend)
        ///   - punch character → 0 or positive (trigger late for maximum impact)
        ///   - bass conflict → negative (trigger earlier to give filters time to clean)
        ///   - energy-down → negative (start earlier for graceful descent)
        let triggerBias: Double
        /// Human-readable reason for the trigger bias.
        let triggerBiasReason: String
        // B→A communication (audit v8 sesion 3, 2026-05-04): A consulta estos
        // 3 flags de B para ajustar su curva de salida en transiciones blendy.
        let bIntroBars: Int
        let bImmediateImpact: Bool
        let bHarmonicClashLevel: Double
        // v9 (audit 2026-05-05): salta el fade-in lento de B cuando A sale
        // limpio + B abre con punch. CrossfadeExecutor cambia la curva de B
        // a hold-en-0 + ramp final ease, evitando el "lavado" reportado.
        let bRapidFadeIn: Bool
        // v10 (audit 2026-05-05): Tier 4 — entryPoint adelantado a la intro
        // instrumental de B. Cuando true, CrossfadeExecutor activa la curva
        // earlyBlend: B entra al ~75% desde t=0 (escalon, no rampa), A
        // mantiene 100% los primeros 50% del fade, A cae acelerada en los
        // ultimos 25%, B sube 75→100% en el downbeat del chorus.
        let tier4Active: Bool
        // v13.K (audit 2026-05-07): telemetría perceptual. NO modifican
        // comportamiento — solo persistencia para análisis post-coche-test.
        // Permiten ver qué path del entry decisor se eligió, qué gate de
        // Tier 4 cortó (cuando no disparó), y los valores reales de pendiente
        // intro / densidad downbeats de B sin reinstrumentar.
        let entryPointSource: EntryPointSource
        let tier4FailedGate: Tier4FailedGate?
        let introSlopeB: Double?
        let downbeatDensityB20s: Double?
        let chillRecipeApplied: Bool
        /// v13.O round 2026-05-10: cap chorus aplicado por gate percussive.
        /// Origen: `calculatePunchEntry` (solo paths chorusPromotion + chorusFallback).
        /// nil = path no evaluó cap. true = entry capado a 50. false = evaluado pero
        /// chorus≤50 o exempt drop-driven (promotion). Setter MainActor en
        /// `QueueManager.swift:1041` lo escribe en `TransitionDiagnostics.shared`.
        let genreCapApplied: Bool?
        /// v13.O Commit 2 (round 2026-05-10): cap defensivo POST-snap+beat-sync
        /// sobre entry final. Independiente de `genreCapApplied`. nil = entry
        /// pre-clamp <=50, no se evaluó. true = capado. false = >50 pero exempt
        /// drop-driven. Propagado al MainActor mismo patrón que `genreCapApplied`.
        let entryFinalCapApplied: Bool?
        // v13.O.6 (round 2026-05-15, F4) — telemetría filtros aditiva.
        // Pasada al MainActor en `QueueManager` igual que `genreCapApplied`.
        /// Último valor de `currentAnalysis.rmsTailCurve` (último window). nil
        /// si el backend no proveyó la curva.
        let rmsTailCurveA_last: Double?
        /// Slope de `rmsTailCurve` con `tailWindows=4` (último ~16s). nil si
        /// no hay datos suficientes (curva inexistente o <4 puntos).
        let rmsTailSlopeA: Double?
        /// Energía outro de A en `[0..1]` calculada por el bloque `noRealOutro`.
        /// Era variable local; ahora se expone para analizar correlaciones con
        /// quejas sobre filtros marcados en outros tranquilos. nil cuando no
        /// había datos suficientes para evaluar (sin outro, track corto, etc.).
        let outroEnergyA: Double?
    }

    // MARK: - Build Transition Profile

    /// Analyzes the A↔B relationship and produces a unified profile that drives all decisions.
    /// Called ONCE at the top of calculateCrossfadeConfig.
    private static func buildTransitionProfile(
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        mode: MixMode,
        bufferADuration: Double,
        bufferBDuration: Double
    ) -> TransitionProfile {
        let hasCurrent = currentAnalysis != nil && currentAnalysis?.hasError != true
        let hasNext = nextAnalysis != nil && nextAnalysis?.hasError != true

        // ── Energy (per-section preferred) ──
        // Backend bug pendiente de fix: 6/49 pistas en log v7 reportan
        // energy/energyOutro = 0.00 con audio claramente audible (D Rose,
        // LIKE WEEZY, Champion, Vamp Anthem, Down Hill, God Is). El integrador
        // RMS sale en 0 cuando deberia normalizar — el backend NO ha
        // confirmado fix para este. Mientras tanto, floor a 0.10 cuando hay
        // duracion suficiente para asumir que la pista tiene contenido real.
        // 0.10 es el limite inferior plausible para musica con audio audible
        // y NO afecta tracks con energy=0.10 reales (que ya quedaban abajo).
        let eA: Double = {
            let raw: Double
            if let cur = currentAnalysis, hasCurrent, cur.hasEnergyProfile {
                raw = cur.energyOutro
            } else {
                raw = hasCurrent ? (currentAnalysis?.energy ?? 0.5) : 0.5
            }
            // Floor solo si raw es claramente bug (≤ 0.02) Y hay evidencia
            // de pista real (duracion > 30s). Pistas <30s pueden ser jingles
            // / SFX donde energy=0 es legitimo.
            return raw <= 0.02 && bufferADuration > 30 ? 0.10 : raw
        }()
        let eB: Double = {
            let raw: Double
            if let nxt = nextAnalysis, hasNext, nxt.hasEnergyProfile {
                raw = nxt.energyIntro
            } else {
                raw = hasNext ? (nextAnalysis?.energy ?? 0.5) : 0.5
            }
            return raw <= 0.02 && bufferBDuration > 30 ? 0.10 : raw
        }()
        let gap = eB - eA
        let flow: EnergyFlow
        if gap > 0.15 { flow = .energyUp }
        else if gap < -0.15 { flow = .energyDown }
        else { flow = .steady }

        // ── BPM (with confidence system) ──
        let bA = hasCurrent ? (currentAnalysis?.bpm ?? 120) : 120
        let bB = hasNext ? (nextAnalysis?.bpm ?? 120) : 120
        let bBNorm = harmonicBPM(bA, bB)
        let diff = abs(bA - bBNorm)
        let bpmRel: BPMRelationship
        if diff < 3 { bpmRel = .identical }
        else if diff <= 12 { bpmRel = .compatible }
        else if diff <= 18 { bpmRel = .borderline }
        else { bpmRel = .incompatible }

        // BPM confidence: both songs must have confidence ≥ 0.5 AND valid BPM data for trusted decisions.
        // When untrusted, time-stretch, beat sync, and bass kill should be conservative.
        // Fallback 0.5 (no 1.0): si el backend no devolvió confidence, asumimos
        // el límite mínimo confiable en lugar de confianza máxima injustificada.
        let confA = currentAnalysis?.bpmConfidence ?? 0.5
        let confB = nextAnalysis?.bpmConfidence ?? 0.5
        let hasBeatDataA = bA > 20 && bA < 300
        let hasBeatDataB = bB > 20 && bB < 300
        let trusted = confA >= 0.5 && confB >= 0.5 && hasBeatDataA && hasBeatDataB
        if !trusted {
            let lowConf = confA < 0.5 ? "A" : "B"
            let val = confA < 0.5 ? confA : confB
            print("[DJMixingService] ⚠️ BPM untrusted (\(lowConf) confidence=\(String(format: "%.2f", val))) — conservative beat decisions")
        }

        // ── Harmonic ──
        let harm = harmonicPenalty(keyA: currentAnalysis?.key, keyB: nextAnalysis?.key)

        // ── Vocal overlap (conservative estimate: A's last ~15s, B's first ~20s) ──
        let conservativeCrossfadeZoneA = max(0, bufferADuration - 15)
        let conservativeBEnd: Double = 20

        let aVocals: Bool
        if let cur = currentAnalysis, hasCurrent {
            if cur.hasVocalData && cur.hasOutroVocals {
                aVocals = true
            } else if cur.hasVocalEndData {
                aVocals = cur.lastVocalTime > conservativeCrossfadeZoneA
            } else if !cur.speechSegments.isEmpty {
                aVocals = cur.speechSegments.contains { $0.end > conservativeCrossfadeZoneA }
            } else if let vs = cur.vocalStartTime, vs > 0 {
                // vocalStart known and >0 → assume vocals likely until outro
                aVocals = cur.outroStartTime <= 0 || cur.outroStartTime > conservativeCrossfadeZoneA
            } else {
                // vocalStart nil (unknown) or 0 (vocal-at-t=0): without other
                // signals can't claim vocals in the outro window.
                aVocals = false
            }
        } else { aVocals = false }

        let bVocals: Bool
        if let nxt = nextAnalysis, hasNext {
            if nxt.hasVocalData && nxt.hasIntroVocals {
                bVocals = true
            } else if !nxt.speechSegments.isEmpty {
                bVocals = nxt.speechSegments.contains { $0.start < conservativeBEnd }
            } else if let vs = nxt.vocalStartTime, vs > 0 {
                bVocals = vs < conservativeBEnd
            } else {
                // vs == nil (unknown) OR vs == 0 (post-backend would mean
                // literal vocal-at-t=0, but pre-backfill it's still camouflaged
                // null). Stay conservative: no claim. Once the backfill ships,
                // a literal 0 here can be flipped to bVocals=true.
                bVocals = false
            }
        } else { bVocals = false }

        let vocalRisk: VocalOverlapRisk
        switch (aVocals, bVocals) {
        case (true, true):   vocalRisk = .both
        case (true, false):  vocalRisk = .aOnly
        case (false, true):  vocalRisk = .bOnly
        case (false, false): vocalRisk = .none
        }

        // ── Danceability / bass conflict ──
        let dA = hasCurrent ? (currentAnalysis?.danceability ?? 0.5) : 0.5
        let dB = hasNext ? (nextAnalysis?.danceability ?? 0.5) : 0.5
        let avgDance = (dA + dB) / 2.0
        let bassConflict = dA > 0.65 && dB > 0.65

        // ── Style affinity (0-1) ──
        // How "similar" the two songs are stylistically. Inferred from BPM, energy, danceability.
        // Songs in the same BPM bracket, similar energy, similar danceability = same "world".
        let bpmAffinity = max(0, 1.0 - diff / 30.0)                   // 0 diff = 1.0, 30+ diff = 0
        let energyAffinity = max(0, 1.0 - abs(gap) / 0.6)             // 0 gap = 1.0, 0.6+ gap = 0
        let danceAffinity = max(0, 1.0 - abs(dA - dB) / 0.5)          // 0 diff = 1.0, 0.5+ = 0
        let harmonicAffinity: Double
        switch harm.compatibility {
        case .compatible: harmonicAffinity = 1.0
        case .acceptable: harmonicAffinity = 0.7
        case .tense:      harmonicAffinity = 0.4
        case .clash:      harmonicAffinity = 0.1
        }
        // Weighted: BPM matters most (genre identifier), then energy, then harmony, then danceability
        let affinity = min(1.0, max(0,
            bpmAffinity * 0.35 + energyAffinity * 0.25 + harmonicAffinity * 0.25 + danceAffinity * 0.15
        ))

        // ── Character: what kind of transition does this pairing call for? ──
        // NOTE: Backend energy values are compressed (most music falls 0.05-0.30).
        // "Minimal" should only apply to truly ambient/quiet tracks, not to
        // Kanye, Bruno Mars, Bad Bunny etc. that happen to have low RMS energy.
        // Danceability is a strong signal: high danceability = NOT minimal.
        let character: TransitionCharacter
        if mode != .dj {
            character = .smooth
        } else if eA < 0.15 && eB < 0.15 && avgDance < 0.5 {
            // Truly ambient/quiet: both very low energy AND low danceability
            character = .minimal
        } else if abs(gap) > 0.35 || harm.compatibility == .clash {
            character = .dramatic
        } else if bpmRel != .incompatible && affinity > 0.4 {
            character = .punch
        } else {
            character = .smooth
        }

        let profile = TransitionProfile(
            energyA: eA, energyB: eB, energyGap: gap, energyFlow: flow,
            bpmA: bA, bpmB: bB, bpmBNormalized: bBNorm, bpmDiff: diff,
            bpmRelationship: bpmRel, bpmTrusted: trusted,
            harmonic: harm,
            vocalOverlapRisk: vocalRisk, aHasOutroVocals: aVocals, bHasIntroVocals: bVocals,
            danceabilityA: dA, danceabilityB: dB, avgDanceability: avgDance,
            bassConflictRisk: bassConflict,
            character: character,
            styleAffinity: affinity,
            mode: mode
        )

        print("[DJMixingService] 🎛️ Profile: character=\(character) affinity=\(String(format: "%.2f", affinity)) " +
              "energy=\(String(format: "%.2f→%.2f", eA, eB)) flow=\(flow) " +
              "bpm=\(Int(bA))→\(Int(bB))(norm:\(Int(bBNorm))) rel=\(bpmRel) trusted=\(trusted) " +
              "vocal=\(vocalRisk) harmonic=\(harm.compatibility) bassConflict=\(bassConflict)")

        return profile
    }

    // MARK: - Main Entry Point

    /// Calculate full crossfade configuration.
    static func calculateCrossfadeConfig(
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        bufferADuration: Double,
        bufferBDuration: Double,
        mode: MixMode,
        currentPlaybackTimeA: Double? = nil,
        userFadeDuration: Double? = nil
    ) -> CrossfadeResult {
        let safeCurrent = currentAnalysis.map { sanitize($0, duration: bufferADuration) }
        let safeNext = nextAnalysis.map { sanitize($0, duration: bufferBDuration) }

        // ── 1. Build relationship profile (computed ONCE, drives everything) ──
        let profile = buildTransitionProfile(
            currentAnalysis: safeCurrent,
            nextAnalysis: safeNext,
            mode: mode,
            bufferADuration: bufferADuration,
            bufferBDuration: bufferBDuration
        )

        // ── 2. Entry point (where B starts playing) — driven by profile ──
        var entry = calculateSmartEntryPoint(
            nextAnalysis: safeNext,
            currentAnalysis: safeCurrent,
            bufferDuration: bufferBDuration,
            profile: profile,
            currentPlaybackTimeA: currentPlaybackTimeA
        )

        // ── 2b. noRealOutro guard ──
        // Some tracks have outroStartTime pegged within ~3s of file end (Punk
        // Monk → FEAR. case: outroStartA=192.9s on a 196s track, with bajos +
        // baterías hasta el último segundo per the listener). The high
        // outro-aware entry that follows treats those last seconds as if there
        // were a real outro, triggering A's fade-out 25s+ before the end —
        // exactly when A is in full groove. Result: the listener perceives
        // "A salida demasiado pronto."
        //
        // Detect the no-real-outro condition and (a) cap entry to keep the
        // trigger close to A's actual end, and (b) tell decideAnticipation to
        // suppress the anticipation tease (further pre-mutes A).
        // v13.O.6 (F4): el cálculo de `outroEnergyA` se extrae a un tuple
        // (noRealOutro, outroEnergyA) para exponer el valor a telemetría —
        // antes era variable local dentro del closure y se perdía. Misma
        // lógica que la versión previa: outroEnergyA queda nil cuando los
        // guards iniciales no permiten evaluar (sin outro real, track corto,
        // sin OutroData).
        let noRealOutroEval: (flag: Bool, outroEnergy: Double?) = {
            guard let cur = safeCurrent, cur.hasError != true,
                  cur.hasOutroData, bufferADuration > 30 else { return (false, nil) }
            let outroDur = bufferADuration - cur.outroStartTime
            guard outroDur < 4 else { return (false, nil) }
            // Confirm with energy: short outro window + still-energetic =
            // groove vivo, not a 3-second decay. energyOutro is preferred when
            // available; energy global is the fallback.
            // Backend bug guard: when energyOutro collapses to ≤0.02, look at
            // cur.energy as second opinion before assuming bug. Only activate
            // the "groove vivo" default when BOTH signals are suspiciously low
            // (typical of the integrator-fail bug, not legit silent outros).
            // Avoids false positive on baladas with intentional silent fade.
            let primary = cur.hasEnergyProfile ? cur.energyOutro : cur.energy
            let outroEnergy: Double
            if primary > 0.02 {
                outroEnergy = primary
            } else if cur.hasEnergyProfile && cur.energy > 0.02 {
                // energyOutro=0 but global energy>0 — use global as proxy
                outroEnergy = cur.energy
            } else {
                // Both signals zero — true silent track OR backend bug.
                // Don't assume bug: respect the data and treat as quiet outro.
                outroEnergy = primary
            }
            return (outroEnergy > 0.15, outroEnergy)
        }()
        let noRealOutro: Bool = noRealOutroEval.flag
        let outroEnergyAForTelemetry: Double? = noRealOutroEval.outroEnergy

        if noRealOutro && entry.entryPoint > 8.0 {
            let capped = 8.0
            print("[DJMixingService] ⚠️ A sin outro real (energyOutro alto + outroDur<4s): entry \(String(format: "%.1f", entry.entryPoint))s → \(String(format: "%.1f", capped))s")
            entry = EntryPointResult(
                entryPoint: capped,
                beatSyncInfo: entry.beatSyncInfo + " [noRealOutro cap]",
                usedFallback: entry.usedFallback,
                // Drop beat-sync claim — the original sync was tied to the
                // pre-cap downbeat; a 6s cap puts us nowhere near it.
                isBeatSynced: false,
                // Preserva la etiqueta del path original — el cap es modificación
                // posterior, el "source" sigue siendo el path que decidió el
                // entry pre-cap.
                entrySource: entry.entrySource,
                // Preserva el flag chorus-cap del path original. Si chorus se
                // capó a 50 y luego noRealOutro lo capa a 8, el gate chorus se
                // evaluó (`true` legítimo) aunque entry final no esté en 50.
                genreCapApplied: entry.genreCapApplied,
                // Misma lógica para el cap final v13.O C2: el flag refleja la
                // decisión post-snap original; este cap noRealOutro de 8s es
                // siempre más restrictivo, así que el cap final ya no actúa.
                entryFinalCapApplied: entry.entryFinalCapApplied
            )
        }

        // ── 3. Fade duration — driven by profile ──
        let fade = calculateAdaptiveFadeDuration(
            entryPoint: entry.entryPoint,
            bufferADuration: bufferADuration,
            bufferBDuration: bufferBDuration,
            currentAnalysis: safeCurrent,
            nextAnalysis: safeNext,
            profile: profile,
            userFadeDuration: userFadeDuration
        )

        // ── 4. Filter decisions — driven by profile ──
        let filter = decideFilterUsage(profile: profile, fadeDuration: fade.duration)

        // ── 5. DJ-grade filters (mid scoop + high shelf) — refined with actual fade zone ──
        let djFilters = decideDJFilters(
            currentAnalysis: safeCurrent,
            nextAnalysis: safeNext,
            profile: profile,
            fadeDuration: fade.duration,
            entryPoint: entry.entryPoint,
            bufferADuration: bufferADuration
        )

        // ── 5b. Pre-decision instrumental detection ──
        // Computed BEFORE decideTransitionType so the selector can route incompatible
        // pairs that share an instrumental outro/intro to a gentle blend instead of
        // CLEAN_HANDOFF. We re-detect later with effectiveFadeDuration for the runtime
        // config — the small clamp delta (≤ 0.5s on cleanHandoff, ≤ 0.5s on cut) doesn't
        // change which side of the boundary a vocal lands on in practice.
        let preOutroInstrumental = detectOutroInstrumental(
            currentAnalysis: safeCurrent, profile: profile,
            bufferADuration: bufferADuration, fadeDuration: fade.duration
        )
        let preIntroInstrumental = detectIntroInstrumental(
            nextAnalysis: safeNext, profile: profile,
            entryPoint: entry.entryPoint, fadeDuration: fade.duration
        )

        // ── 6. Transition type — decided BEFORE anticipation so CUT can get its own tease ──
        var transition = decideTransitionType(
            currentAnalysis: safeCurrent,
            nextAnalysis: safeNext,
            profile: profile,
            entryPoint: entry.entryPoint,
            fadeDuration: fade.duration,
            isBeatSynced: entry.isBeatSynced,
            useFilters: filter.useFilters,
            bufferADuration: bufferADuration,
            hasVocalOverlap: djFilters.useMidScoop,
            outroInstrumental: preOutroInstrumental,
            introInstrumental: preIntroInstrumental
        )

        // ── 6b. Hv5-3 (v13.O.5): DROP_MIX → BMB redirect para cluster mid-entry ──
        //
        // Coche-test v13.O.4 (N=98): subset DROP_MIX entry [5,15) mean 3.33
        // (N=6 con r≤4: HELICOPTER→BOP, Berghain→The Time, Espresso→I Just
        // Might, Kill Yourself→Teeth, THE zone→The Race, N95→NIP).
        // DROP_MIX seco sin anticipation con entry mediano + BPM divergente
        // suena a "B aparece de la nada al cargo de A en marcha".
        //
        // Cinturones para preservar oro:
        //   - entry ∈ [5, 15): el cluster malo vive aquí. <5 es kick-roll
        //     legítimo (oros r=10 Adan y Eva→Say So, r=9 Raindance→Too Much).
        //     ≥15 incluye Won't Be Late→48 (entry=35.6, r=10, queja real
        //     de filtros A — H1 lo cubre, no de tipo).
        //   - bpmDiff ≥ 5: BPM-perfect match ya protegido por gate línea
        //     ~3308 (bpmPerfectMatch → DROP_MIX seguro). Pero aún hay
        //     bpmDiff=0 en cluster malo (HELICOPTER, Berghain) que ya no
        //     llegan aquí. Este guard ataca pares con desfase rítmico real.
        //   - src != punchVocalAvoidance: 5/5 PVA en DROP_MIX rated tienen
        //     rating bueno (4/5 ≥9). PVA es señal protectora — la rama del
        //     decisor que evita overlap vocal acierta.
        //
        // Si dispara: redirect a BMB (isBeatSynced verificado upstream).
        // BMB hereda fade.duration (default switch línea ~896), corre
        // PRE_PUNCH o anticipation A2 con tipo congelado .beatMatchBlend,
        // chillRecipe en sección 8e si aplica.
        //
        // Bench Python: scripts/bench_v13O5_hv5_3.py sobre N=98 v13.O.4.
        if transition.type == .dropMix
            && entry.entryPoint >= 5.0
            && entry.entryPoint < 15.0
            && profile.bpmDiff >= 5.0
            && entry.entrySource != .punchVocalAvoidance
            && entry.isBeatSynced {
            let oldReason = transition.reason
            transition = TransitionTypeResult(
                type: .beatMatchBlend,
                reason: "Hv5-3 redirect: DROP_MIX→BMB (entry=\(String(format: "%.1f", entry.entryPoint))s, bpmDiff=\(String(format: "%.1f", profile.bpmDiff)), src=\(entry.entrySource.rawValue)) [old: \(oldReason)]"
            )
            print("[DJMixingService] 🔀 Hv5-3 redirect → BMB (entry mid-bucket sin BPM-grid)")
        }

        // ── 6b-ter. v15.b H2: entry tardío vs vocalStartB → SEQUENTIAL ──
        //
        // Cuando el punto de entrada elegido se salta una intro substancial
        // de B (entryPoint − vocalStartB > 5s), la transición queda mal
        // alineada: A entrega su outro pero B ya ha dejado atrás su material
        // introductorio. Caso defensivo: forzar SEQUENTIAL (A termina natural,
        // B desde el inicio) para preservar contexto vocal y armónico de B.
        //
        // Gate auxiliar: pistas con intro instrumental muy silenciosa (energyB
        // < 0.12 + preIntroInstrumental true) usan threshold 20s — el entry
        // tardío no se percibe como ruptura si la intro de B es casi inaudible
        // y la sustitución musical es indistinguible.
        //
        // Drop-driven percussive: isBDropDrivenByPercussive protege la familia
        // donde el drop justifica entry mid-song (kick programado tras una
        // intro larga que el sweep filter del crossfade debe acompañar, no
        // saltar). Si el detector dispara, dejamos el tipo original.
        //
        // Tipos exentos: si el decisor ya escogió .sequential / .vinylStop /
        // .cut / .cutAFadeInB, H2 no toca — cada uno tiene gesto propio
        // (vinylStop su frenada, cut su sweep, sequential ya es destino).
        if let next = safeNext, next.hasError != true,
           transition.type != .sequential,
           transition.type != .vinylStop,
           transition.type != .cut,
           transition.type != .cutAFadeInB {
            let vocalStartB: Double = {
                if let vs = next.vocalStartTime, vs > 0 { return vs }
                if let first = next.speechSegments.first, first.start > 0 { return first.start }
                return 0
            }()
            if vocalStartB > 0 {
                let (bIsDropDriven, _) = Self.isBDropDrivenByPercussive(next.percussiveCurve)
                let isQuietInstrumentalIntro = profile.energyB < 0.12 && preIntroInstrumental
                let h2Threshold: Double = isQuietInstrumentalIntro ? 20.0 : 5.0
                let entryExcess = entry.entryPoint - vocalStartB
                if entryExcess > h2Threshold && !bIsDropDriven {
                    let oldReason = transition.reason
                    transition = TransitionTypeResult(
                        type: .sequential,
                        reason: "Entry tardío vs vocalStartB (entry=\(String(format: "%.1f", entry.entryPoint))s, vocalStartB=\(String(format: "%.1f", vocalStartB))s, excess=\(String(format: "%.1f", entryExcess))s, threshold=\(String(format: "%.0f", h2Threshold))s) → SEQUENTIAL [old: \(oldReason)]"
                    )
                    print("[DJMixingService] 🚧 Entry salta intro útil → SEQUENTIAL")
                }
            }
        }

        // ── 6b-quater. v15.b H3: CUT sin outro instrumental fiable → SEQUENTIAL ──
        //
        // CUT depende de que A acabe en zona instrumental: si el outro lleva
        // voz hasta el final, el corte trunca la palabra y el listener lo
        // percibe como error. La heurística preOutroInstrumental (línea ~835)
        // valida lastVocalTime y speechSegments, pero puede dar false-positive
        // en outros que "no tienen voz" simplemente porque tampoco tienen
        // sonido — pistas que cierran fade-out a silencio. En ese caso el
        // CUT corta sobre material casi-inaudible y el cambio a B suena seco.
        //
        // Salvaguarda complementaria: exigir outroEnergyA > 0.10 para
        // considerar el outro como instrumental defendible para CUT. Si la
        // energía del outro queda por debajo del umbral, escalamos a
        // SEQUENTIAL para que A respire hasta su final natural y B arranque
        // desde el inicio sin trauma de corte.
        //
        // Sólo aplica al tipo .cut. .cutAFadeInB tiene fade-in en B que ya
        // suaviza el handoff incluso sobre outros marginales.
        if transition.type == .cut {
            let h3OutroDefendsCut: Bool = {
                guard preOutroInstrumental else { return false }
                if let oe = outroEnergyAForTelemetry, oe < 0.10 { return false }
                return true
            }()
            if !h3OutroDefendsCut {
                let oldReason = transition.reason
                let oeStr = outroEnergyAForTelemetry.map { String(format: "%.2f", $0) } ?? "nil"
                transition = TransitionTypeResult(
                    type: .sequential,
                    reason: "CUT sin outro instrumental fiable (preOutroInstrumental=\(preOutroInstrumental), outroEnergyA=\(oeStr)) → SEQUENTIAL [old: \(oldReason)]"
                )
                print("[DJMixingService] ✂️→📼 CUT sin outro fiable → SEQUENTIAL")
            }
        }

        // ── 6b-quinquies. Entry chorus tardío sin drop → SEQUENTIAL ──
        //
        // Cuando el entryPoint se calcula vía chorus (punchChorusPromotion /
        // punchChorusFallback) y supera 30s sin que B sea drop-driven, la
        // entrada cae en mitad de un verso/pre-chorus y el oyente no reconoce
        // dónde está la canción. SEQUENTIAL preserva el material introductorio
        // de B: A termina natural y B arranca desde el inicio.
        //
        // Exime drop-driven (mismo criterio percusivo que el gate 6b-ter y el
        // cap final): ahí el entry tardío apunta a un drop legítimo. El umbral
        // 30s queda al filo de algún caso bien valorado, aceptable por el
        // balance. Va ANTES del 6b-bis para que el reset entry=0 lo recoja.
        if let next = safeNext, next.hasError != true,
           transition.type != .sequential,
           transition.type != .vinylStop,
           transition.type != .cut,
           transition.type != .cutAFadeInB,
           (entry.entrySource == .punchChorusPromotion || entry.entrySource == .punchChorusFallback),
           entry.entryPoint > 30.0 {
            let (bIsDropDriven, _) = Self.isBDropDrivenByPercussive(next.percussiveCurve)
            if !bIsDropDriven {
                let oldReason = transition.reason
                transition = TransitionTypeResult(
                    type: .sequential,
                    reason: "Entry chorus tardío sin drop (entry=\(String(format: "%.1f", entry.entryPoint))s, source=\(entry.entrySource.rawValue)) → SEQUENTIAL [old: \(oldReason)]"
                )
                print("[DJMixingService] 🎯→📼 Entry chorus tardío sin drop → SEQUENTIAL")
            }
        }

        // ── 6b-bis. v14.09: SEQUENTIAL fuerza entry=0 ──
        //
        // `decideTransitionType` puede redirigir DROP_MIX/STEM_MIX → .sequential
        // vía F5b (commit 5161c99, v13.O.6). El `entry.entryPoint` se calculó
        // arriba (línea ~724) ANTES de esa redirección, apuntando típicamente
        // a chorus/drop ~30-60s del DROP_MIX original. Sin reset, B arranca a
        // mitad de canción en vez de desde el principio — rompe la promesa
        // SEQUENTIAL ("A termina natural, B empieza desde el principio").
        //
        // Quote director (2026-05-15): *"PlayerA llega más o menos al final
        // y se activa y playerB entra por donde le da la gana. Debería de
        // ser playerA llega a su final, playerB empieza desde el principio,
        // es como skippear transiciones simplemente. Pues eso no funciona."*
        //
        // Fix: SIEMPRE que el tipo final sea .sequential, forzar entry=0.
        // Aplica tanto a redirects F5b como a SEQUENTIAL elegidos directamente
        // por el decisor (BPM incompatible extremo). El snap (6c) y Tier 4
        // (6.5) posteriores no tocan SEQUENTIAL, así que el entry=0 propaga
        // limpio al executor.
        if transition.type == .sequential && entry.entryPoint > 0 {
            print("[DJMixingService] 🔄 v14.09 SEQUENTIAL force entry=0 (was \(String(format: "%.1f", entry.entryPoint))s, src=\(entry.entrySource.rawValue))")
            entry = EntryPointResult(
                entryPoint: 0,
                beatSyncInfo: entry.beatSyncInfo + " [SEQUENTIAL reset]",
                usedFallback: entry.usedFallback,
                isBeatSynced: false,
                entrySource: entry.entrySource,
                genreCapApplied: entry.genreCapApplied,
                entryFinalCapApplied: entry.entryFinalCapApplied
            )
        }

        // ── 6c. CUT entry snap to downbeat ──
        // Done AFTER the type is decided (we only snap CUT-family) and BEFORE
        // anticipation/trigger/instrumental refinement (so they all see the
        // same final entry). The pre-decision calcs (fade, djFilters, pre-detect
        // instrumental) keep the original entry — they're heuristics tolerant
        // of a 1-2s shift.
        // harmonicClashLevel: misma conversion que B→A flag #4 (8d). Computado
        // aqui porque snap lo necesita ANTES de la seccion 8d. Reusable mas
        // abajo via la misma expresion (no DRY-ificado a una let arriba para
        // no extender el scope al inicio del metodo).
        let harmonicClashLevel: Double = {
            switch profile.harmonic.compatibility {
            case .compatible: return 0.0
            case .acceptable: return 0.3
            case .tense:      return 0.6
            case .clash:      return 1.0
            }
        }()
        let snapResult = snapCutEntryToDownbeat(
            entry: entry.entryPoint,
            transitionType: transition.type,
            next: safeNext,
            bufferBDuration: bufferBDuration,
            fadeDuration: fade.duration,
            harmonicClashLevel: harmonicClashLevel
        )
        let snapEntry = snapResult.entry
        if snapResult.snapped {
            print("[DJMixingService] 🎯 \(snapResult.info)")
        }

        // ── 6.5. Tier 4: adelantar entryPoint al primer kick de la intro de B ──
        // Cuando A esta en outro instrumental confiable + B tiene intro
        // instrumental real con kick (sin voz), adelantar entry para que B
        // acompane los ultimos 6-10 compases de A. Curva nueva `earlyBlend`
        // se activa via tier4Active. Si gates fallan, fallback al snapEntry.
        // IMPORTANTE: corre ANTES de los flags B→A (8d) para que
        // bImmediateImpact se recalcule con el entry adelantado.
        var tier4Telemetry = Tier4Telemetry()
        let tier4Result = Self.computeTier4Entry(
            safeCurrent: safeCurrent,
            safeNext: safeNext,
            profile: profile,
            bufferADuration: bufferADuration,
            bufferBDuration: bufferBDuration,
            fadeDuration: fade.duration,
            originalEntry: snapEntry,
            transitionType: transition.type,
            telemetry: &tier4Telemetry
        )
        var finalEntry: Double
        let tier4Active: Bool
        if let result = tier4Result {
            finalEntry = result.entry
            tier4Active = true
            print("[DJMixingService] ⚡ \(result.reason)")
        } else {
            finalEntry = snapEntry
            tier4Active = false
        }

        // ── 6a. Gate defensivo entryPoint tardío vs vocalStartB ──
        // Cuando un blend (BEAT_MATCH_BLEND / EQ_MIX) tiene su entryPoint
        // posterior al inicio de la voz de B + 3s, el blend pisa una vocal
        // ya cantando ≥3s. Cluster medido sobre N=242 rated (pool acumulado):
        // 9 pares cumplen el gate con mean 6.00 vs global 8.33 (delta −2.33);
        // 0 diamantes r=10 entran en el gate. Cobertura 3.7%, daño colateral
        // nulo en el dataset. Reasigna a SEQUENTIAL para que A acabe natural
        // y B arranque desde su inicio musical real ("mirar al principio de
        // playerB").
        //
        // No depende de entrySource (la formulación previa con
        // `entrySource ∈ {chorusFallback, energyBoost, chorusPromotion}` daba
        // 0 redirects porque otro override upstream ya cubre esos paths).
        let vocalStartBForLateEntryGate: Double = (safeNext?.hasError != true)
            ? (safeNext?.vocalStartTime ?? 0)
            : 0
        let isBlendyForLateEntryGate =
            transition.type == .beatMatchBlend || transition.type == .eqMix
        if isBlendyForLateEntryGate
            && vocalStartBForLateEntryGate > 0
            && finalEntry > vocalStartBForLateEntryGate + 3.0 {
            let oldType = transition.type
            let oldEntry = finalEntry
            transition = TransitionTypeResult(
                type: .sequential,
                reason: "[Late entry vs vocalStartB (finalEntry=\(String(format: "%.1f", oldEntry))s > vocalStartB+3s=\(String(format: "%.1f", vocalStartBForLateEntryGate + 3.0))s, era \(oldType.rawValue)) → SEQUENTIAL, entry=0] " + transition.reason
            )
            // SEQUENTIAL implica que B arranca desde su muestra 0. Sin este
            // reset finalEntry conserva el valor calculado para el blend
            // original (puede ser >20s) y B se posicionaria a mitad de la
            // pista pese al tipo SEQUENTIAL.
            finalEntry = 0
        }

        // ── 6b. Fade duration overrides per transition type ──
        // calculateAdaptiveFadeDuration assumes a graceful blend and returns
        // 5–15s based on outro structure. Some transition types (decided AFTER
        // the duration is calculated) don't make musical sense at long durations
        // and need to be clamped post-decision.
        let effectiveFadeDuration: Double
        switch transition.type {
        case .cleanHandoff:
            // Tight 2.5–3.5s: A fades out exponentially, micro-respiro, B sin² ramps.
            // Anything longer becomes dead air or an awkward double-pause.
            effectiveFadeDuration = max(2.5, min(3.5, fade.duration))
        case .vinylStop:
            // Tight 1.5–2.0s window. A's spin-down occupies the first 22.5%
            // (~340–450ms), then ~200ms aire, then B fades in. Anything longer
            // turns the gesture into dead air — a vinyl stop is a punctuation
            // mark, not a long transition.
            effectiveFadeDuration = max(1.5, min(2.0, fade.duration))
        case .cut:
            // CUT forced by polirritmia / vocal trainwreck inherits the long fade
            // computed for a hypothetical blend. The .cut volume curve hard-codes
            // a 3-second drop window at the END of the fade — for a 15s fade,
            // that means A plays normally for 12 seconds with no audible change,
            // followed by a 3-second drop. That's wasted "trigger lead-in" time
            // and the trigger ends up firing 15s before A's outro endpoint
            // instead of ~7s, so A keeps playing 8 unnecessary seconds.
            //
            // Clamp to [3, 7]: the .cut curve always uses the last 3s, and
            // anticipation can run up to 4s before that, so 7s is the sensible
            // ceiling. Below 3s the type is already CUT by another path.
            effectiveFadeDuration = max(3.0, min(7.0, fade.duration))
        case .sequential:
            // v14.13 — SEQUENTIAL pisa el adaptive (5–15s) y clampa a 50ms total.
            // La curva en CrossfadeExecutor ya estaba diseñada para un solape
            // ultracorto de 50ms (cos²/sin² complementarios), pero heredar un
            // fadeDuration de 10s hacía que B reprodujera silenciada desde
            // frame 0 durante 9.95s y solo sonara los últimos 50ms — el director
            // percibía "B empieza por la mitad" porque al sonar ya estaba en
            // t=10s del archivo. Con fadeDuration=50ms, el trigger end-based
            // (QueueManager) dispara casi al final de A y B suena desde su
            // muestra 0 inmediatamente.
            effectiveFadeDuration = 0.050
        case .fadeOutACutB:
            // When the energy-crash override fired (high-energy A into instrumental
            // low-energy B), the original fade may be short (~3s) because of the
            // short outro window. Aim for ≥ 5s so A can breathe out before B's
            // firm entry. Cap at 8s — anything longer turns into a long-tail fade.
            // ALSO cap at A's outro space + 2s so we don't fade through main body
            // material the listener still expects to hear (very short outros).
            // For any other path that lands here, behave neutrally.
            if profile.energyA > 0.40 && profile.energyB < 0.25 {
                let aOutroLimit: Double = {
                    guard let cur = safeCurrent, cur.hasError != true,
                          cur.hasOutroData,
                          bufferADuration > cur.outroStartTime else {
                        return 8.0
                    }
                    return (bufferADuration - cur.outroStartTime) + 2.0
                }()
                let cap = min(8.0, aOutroLimit)
                let target = max(min(5.0, cap), fade.duration)
                effectiveFadeDuration = min(cap, target)
            } else {
                effectiveFadeDuration = fade.duration
            }
        default:
            effectiveFadeDuration = fade.duration
        }

        // ── 7. Anticipation — now CUT-aware, can "tease" B before the swap ──
        // Uses finalEntry so an entry that got snapped forward by P5.a still
        // computes the right tease window relative to where B actually starts.
        // noRealOutro suppresses the tease entirely — A is in full groove
        // until the very end, so pre-muting A would cut material the listener
        // is still expecting.
        // bIntroSpace + vocalStartB para PRE_PUNCH path: cuanto espacio
        // instrumental tiene B antes de su primer evento "fuerte" + posicion
        // del primer vocal (para cap conservador del tease).
        let bIntroSpaceForAnticipation: Double = {
            guard let next = safeNext, next.hasError != true else { return 0 }
            return next.introEndTimeHeuristic ?? (next.hasIntroData ? next.introEndTime : 0)
        }()
        let vocalStartBForAnticipation: Double = {
            guard let next = safeNext, next.hasError != true else { return 0 }
            return next.vocalStartTime ?? 0
        }()
        let bpmAForAnticipation = (safeCurrent?.hasError != true)
            ? (safeCurrent?.bpm ?? 0)
            : 0
        let bGenresForAnticipation: [String] = (safeNext?.hasError != true)
            ? (safeNext?.genres ?? [])
            : []
        // v13.O Commit 2: rmsTailCurve de A para detectar decay natural en
        // últimos 40s. Si A no tiene curva (track corto / backend sin curva),
        // `decideAnticipation` no dispara el caso nuevo (deriveSlope retorna nil).
        let rmsTailCurveAForAnticipation: [Double]? = (safeCurrent?.hasError != true)
            ? safeCurrent?.rmsTailCurve
            : nil
        // v13.O Commit 2 — extensión filtros agresivos (round 2026-05-10):
        // Predicción conservadora de si decideDJEffects activará alguno de
        // bassKill/dynamicQ/notchSweep/stutterCut. Replicamos los gates de
        // activación primarios (los que SÍ son evaluables ANTES de calcular
        // skipBFilters/isEnergyDown/isChillContext, que se construyen más
        // abajo). Para mantenerlo coherente con `decideDJEffects`, también
        // incluimos los killers principales (chill ctx + energyA floor).
        // Falsos positivos (predigo agresivo pero luego se desactiva) son
        // aceptables: solo se traduce en anticipación extra inocua. Falsos
        // negativos NO son aceptables — son la queja del director "filtros
        // de golpe en groove constante".
        let filtersAggressivePredicted: Bool = {
            // Killers (decideDJEffects:2608, 2621): si caemos en chill o en
            // energyA<0.15, los 4 flags se apagan → no predecir agresivo.
            if profile.energyA < 0.30 { return false }      // isChillContext
            if profile.energyA < 0.15 { return false }      // energyA floor (redundante con anterior pero explícito)

            // bassKill primary gate (decideDJEffects:2510-2515)
            let bassKillCompatibleType: Bool = {
                switch transition.type {
                case .eqMix, .beatMatchBlend, .crossfade, .cutAFadeInB, .fadeOutACutB: return true
                default: return false
                }
            }()
            let dramaticEligible = profile.character == .dramatic && profile.energyFlow == .energyUp
            let punchEligible = profile.character == .punch
            let smoothEligible = profile.character == .smooth && profile.avgDanceability >= 0.55
            let bassKillEligible = bassKillCompatibleType
                && profile.bpmTrusted
                && profile.avgDanceability > 0.4
                && effectiveFadeDuration > 4.0
                && profile.energyA >= 0.10 && profile.energyB >= 0.10
                && (punchEligible || dramaticEligible || smoothEligible)
            if bassKillEligible { return true }

            // dynamicQ primary gate (decideDJEffects:2527-2530)
            let isEnergyDownPredicted = profile.energyB < profile.energyA - 0.2
            let dynQEligible = !isEnergyDownPredicted
                && effectiveFadeDuration > 4.0
                && profile.avgDanceability > 0.45
                && (profile.character == .punch
                    || (profile.character == .dramatic && profile.energyFlow != .energyDown))
            if dynQEligible { return true }
            // notchSweep depende de dynQ (ya cubierto arriba); si dynQ true,
            // notchSweep también probablemente.

            // stutterCut primary gate (decideDJEffects:2587-2593)
            let stutterCompatibleType = (transition.type == .cut || transition.type == .cutAFadeInB)
            let stutterEligible = stutterCompatibleType
                && profile.bpmTrusted
                && profile.bpmA >= 80
                && profile.bpmA <= 180
                && profile.avgDanceability > 0.50
                && effectiveFadeDuration >= 1.5
            if stutterEligible { return true }

            return false
        }()

        let anticipation = decideAnticipation(
            fadeDuration: effectiveFadeDuration,
            entryPoint: finalEntry,
            transitionType: transition.type,
            noRealOutro: noRealOutro,
            transitionReason: transition.reason,
            bIntroSpace: bIntroSpaceForAnticipation,
            vocalStartB: vocalStartBForAnticipation,
            bpmA: bpmAForAnticipation,
            bGenres: bGenresForAnticipation,
            rmsTailCurveA: rmsTailCurveAForAnticipation,
            filtersAggressivePredicted: filtersAggressivePredicted
        )

        // ── 8. Time-stretch ──
        let timeStretch = decideTimeStretch(profile: profile, transitionType: transition.type)
        print("[DJMixingService] \(timeStretch.useTimeStretch ? "⚡ TIME-STRETCH ACTIVE" : "Time-stretch OFF"): \(timeStretch.reason)")

        // ── Beat grid (adjusted for time-stretch) ──
        let biA = (safeCurrent?.hasError != true) ? (safeCurrent?.beatInterval ?? 0) : 0
        let rawBiB = (safeNext?.hasError != true) ? (safeNext?.beatInterval ?? 0) : 0
        let biB = timeStretch.useTimeStretch && timeStretch.rateB > 0
            ? rawBiB / Double(timeStretch.rateB) : rawBiB
        let dbA = (safeCurrent?.hasError != true) ? (safeCurrent?.downbeatTimes ?? []) : []
        let rawDbB = (safeNext?.hasError != true) ? (safeNext?.downbeatTimes ?? []) : []
        let dbB: [Double] = timeStretch.useTimeStretch && timeStretch.rateB > 0
            ? rawDbB.map { $0 / Double(timeStretch.rateB) } : rawDbB
        // v15.g — downbeats musicales reales del backend (paralelo a dbA/dbB
        // que recibe beats[]). Usado por el snap de rampStart en
        // CrossfadeExecutor. Cuando vacío, el path cae al fallback (rampStart
        // sin tocar). beatIntervalAFromBackend permite al executor calcular
        // bpm musical sin half-time mismatch.
        let realDbA = (safeCurrent?.hasError != true) ? (safeCurrent?.realDownbeats ?? []) : []
        let meterA = (safeCurrent?.hasError != true) ? (safeCurrent?.meter ?? 4) : 4

        // ── Instrumental detection (refined with actual fade zone) ──
        let outroInstrumental = detectOutroInstrumental(
            currentAnalysis: safeCurrent, profile: profile,
            bufferADuration: bufferADuration, fadeDuration: effectiveFadeDuration
        )
        let introInstrumental = detectIntroInstrumental(
            nextAnalysis: safeNext, profile: profile,
            entryPoint: finalEntry, fadeDuration: effectiveFadeDuration
        )

        // Skip B filters for very short fades, DROP_MIX (B enters clean and full),
        // CLEAN_HANDOFF or VINYL_STOP (sequential — B enters from silence, no
        // spectral shaping needed; the gesture on A is the effect), o PRE_PUNCH
        // (B suena clean varios segundos antes del punch — el TEASE largo NO
        // tiene sentido si B viene filtrada; queremos su beat / intro al aire).
        //
        // v13.O.3 (#7 mínimo): CUT / CUT_A_FADE_IN_B con fade<5s también skip.
        // Quote testigo Y¿Si fuera ella?→If I Were a Boy (CUT fade=3s, r=3):
        // "filtro se aplicó desde el principio en playerB pero se quitaron de
        // repente, quedó fatal". El path de filtros B con fade tan corto deja
        // un sweep audible que se siente como artefacto de edición, no como
        // técnica DJ. Mejor B clean en estas ventanas. Versión completa (gate
        // análogo para CUTs 5-7s en applyFiltersB) diferida v13.O.4.
        let isShortCut = (transition.type == .cut || transition.type == .cutAFadeInB)
            && effectiveFadeDuration < 5.0
        var skipBFilters = effectiveFadeDuration <= 3.0
            || transition.type == .dropMix
            || transition.type == .cleanHandoff
            || transition.type == .vinylStop
            || transition.type == .sequential
            || anticipation.isPrePunch
            || isShortCut
        if anticipation.isPrePunch {
            print("[DJMixingService] 🎬 PRE_PUNCH: forzando skipBFilters (B clean durante tease largo)")
        }

        // ── 8b. Aggressive preset gating ──
        // The aggressive preset stacks bassKill + midScoop + notchSweep + dynamicQ
        // and pulls hpB to 800 Hz with lsB=-12 dB. That density only works when
        // both tracks are energetic enough to share the carved-up spectrum.
        // Two cases force skipBFilters:
        //   (a) Original: A and B both energetic + danceable → A's gesture is the
        //       focal point, let B enter clean (Icon → Off The Grid).
        //   (b) New: A energetic but B almost silent (energyB < 0.15) → applying
        //       notch + dynamicQ + bassKill on top of a quiet entrance leaves it
        //       sounding "synthetic, filtered, dizzy" (ILoveUIHateU → WAKARIMASEN
        //       in v6: energyB=0.11, danceability=0.56). User reported the entry
        //       as "filtros mal en B"; the gate now bails B out.
        // Danceability threshold lowered 0.60 → 0.55 so case (b) catches mid-
        // danceability R&B pairs that were excluded under the previous 0.60 cap.
        let bothEnergetic = profile.energyA > 0.20 && profile.energyB > 0.20
        let aOnlyEnergetic = profile.energyA > 0.25 && profile.energyB < 0.15
        if filter.useAggressiveFilters
            && profile.avgDanceability > 0.55
            && (bothEnergetic || aOnlyEnergetic)
            && !skipBFilters {
            let mode = bothEnergetic ? "both-energetic" : "A-only-energetic"
            print("[DJMixingService] 🎚️ Aggressive \(mode): forcing skipBFilters (dance=\(String(format: "%.2f", profile.avgDanceability)), energyA=\(String(format: "%.2f", profile.energyA)), energyB=\(String(format: "%.2f", profile.energyB)))")
            skipBFilters = true
        }

        // ── 8c. Quiet-B gate when B is being filtered hard ──
        // anticipation/aggressive presets carve B's spectrum (highpass ramp,
        // bass shelf -12 dB, optional mid-scoop / dynamicQ). When B is quiet
        // AND not strongly danceable, those filters land as "filtered fade-in"
        // instead of "DJ technique" — user reported "B con fade innecesario"
        // in: D Rose→PRIDE., PRIDE.→New Magic Wand, Empty→Leave Me Alone,
        // The Alchemist.→Suge (v7); Lento→Cry, Cry→Rich Baby Daddy, Lucid→
        // BIRDS, BIRDS→Black Beatles, Live Sheck→New Magic, A Escondidas→
        // Answer (v8 audit 2026-05-04, 14+ menciones).
        //
        // Thresholds widened (audit v8): backend reportaba el rango habitual
        // de R&B/pop/hip-hop chill como energyB 0.10-0.30 y dance 0.50-0.90;
        // los thresholds antiguos (0.15/0.70 y 0.18/0.50) caian fuera de ese
        // cuadrante en ~0-1 caso de las 14 quejas. Subimos a 0.22/0.85 y
        // 0.25/0.65 para cubrir el cuadrante real sin romper las joyas.
        // Validacion contra positivas conocidas:
        //   T19 AIR FORCE→Can I Kick: dance=0.96 → 0.96 < 0.85 = false → no activa.
        //   T28 BOMB→No Stylist: dance=0.81 → 0.81 < 0.85 = true; energyB > 0.22
        //     debe seguir excluyendo (verificar). Borderline: vigilar en coche.
        //   T31 Silent Hill→2024: era BMB, ya tenia skipBFilters por otra rama.
        //   Black Beatles→Midnight Tokyo: ya activaba quiet-B antes.
        //   Falling Back→All Mine: dance=0.92 → 0.92 < 0.85 = false → no activa.
        let bQuietNotDanceable = profile.energyB < 0.22 && profile.avgDanceability < 0.85
        let bMidQuietLowDance = profile.energyB <= 0.25 && profile.avgDanceability < 0.65
        let bIsBeingFiltered = anticipation.needsAnticipation || filter.useAggressiveFilters
        if bIsBeingFiltered
            && (bQuietNotDanceable || bMidQuietLowDance)
            && !skipBFilters {
            let mode = bQuietNotDanceable ? "B-quiet" : "B-mid-quiet+low-dance"
            print("[DJMixingService] 🎚️ Quiet-B (\(mode)): forcing skipBFilters (energyB=\(String(format: "%.2f", profile.energyB)), dance=\(String(format: "%.2f", profile.avgDanceability)))")
            skipBFilters = true
        }

        // ── 8d. B→A communication flags (audit v8 sesion 3, 2026-05-04) ──
        // 3 flags minimos del analisis de B que la curva de A consulta para
        // ajustar su forma. Solo se aplican en transiciones blendy
        // (.crossfade, .eqMix, .beatMatchBlend) — el resto los ignora en el
        // executor. Defensive contra bugs backend conocidos.
        //
        // Importante: TODOS los flags miden tiempo RELATIVO a finalEntry (el
        // oyente solo "ve" B desde finalEntry hacia adelante). Si entry=10 y
        // vocal=2, el listener nunca oye ese vocal — calcular flags en
        // tiempo absoluto seria un falso positivo.
        //
        // Flag 1 — bIntroBars: compases instrumentales QUE QUEDAN desde
        // finalEntry hasta el primer evento musical fuerte. Usamos
        // introEndTimeHeuristic primero para evitar el bug ML-override
        // (40-60s en hip-hop) visto en v6/v7.
        // entrySafe defensivo: finalEntry no deberia ser negativo, pero si lo
        // fuese (snapResult.entry sin clamp) inflaria las diferencias y
        // dispararia los flags falsamente. Clamp local sin tocar el resto del
        // flujo (que ya espera finalEntry como esta).
        let entrySafe = max(0, finalEntry)
        let bIntroBarsForA: Int = {
            guard let next = safeNext, next.hasError != true else { return 0 }
            let intro = next.introEndTimeHeuristic ?? (next.hasIntroData ? next.introEndTime : 0)
            let bi = next.beatInterval
            // Clamp bi a rango plausible (50-240 BPM) para neutralizar el
            // bug backend de double/half-time. Fuera de ese rango el conteo
            // de compases es ruido — mejor devolver 0 que activar/no-activar
            // por una razon equivocada.
            guard intro > entrySafe, bi >= 0.25, bi <= 1.2 else { return 0 }
            // .rounded() en lugar de truncacion: 3.99 bars → 4 (fires) en
            // vez de 3 (no fires). 0.01s de jitter en el boundary no deberia
            // cambiar comportamiento.
            return Int(((intro - entrySafe) / (bi * 4.0)).rounded())  // asumiendo 4/4
        }()
        // Flag 2 — bImmediateImpact: voz o chorus llegan en los primeros
        // segundos DESPUES de finalEntry. Defensa contra chorusStart <
        // introEnd (37.5% en v6) y contra chorusStart=0 (missing, no
        // "drop al inicio"). vocalStart=0 SI cuenta (literal "voz en t=0",
        // semantica post-2026-05-01) cuando finalEntry tambien es 0.
        let bImmediateImpactForA: Bool = {
            guard let next = safeNext, next.hasError != true else { return false }
            // Mismo fallback que flag 1: si hasIntroData=false el campo
            // introEndTime puede contener basura stale (default 0 o valor
            // viejo de cache), no deberia bloquear el chorus de un track
            // valido. Solo defenderse cuando hay dato fiable.
            let intro = next.introEndTimeHeuristic ?? (next.hasIntroData ? next.introEndTime : 0)
            let chorus = next.chorusStartTime
            let validChorusInRange = chorus > 0 && chorus >= max(0, intro - 1.0)
            let chorusFromEntry: Double = validChorusInRange ? (chorus - entrySafe) : .infinity
            let vocalFromEntry: Double = next.vocalStartTime.map { $0 - entrySafe } ?? .infinity
            let chorusEarly = chorusFromEntry >= 0 && chorusFromEntry < 6.0
            let vocalEarly = vocalFromEntry >= 0 && vocalFromEntry < 4.0
            return chorusEarly || vocalEarly
        }()
        // Flag 3 — bHarmonicClashLevel: 0..1 derivado de profile.harmonic.
        // Solo activa la rama de la curva de A cuando >= 0.7 (clash puro);
        // tense (0.6) ya esta cubierto por el recorte de fadeDuration.
        // Reusamos `harmonicClashLevel` computado en 6c (mismo mapeo).
        let bHarmonicClashLevelForA: Double = harmonicClashLevel
        if bIntroBarsForA >= 4 || bImmediateImpactForA || bHarmonicClashLevelForA >= 0.7 {
            // Resolver que rama de la curva de A actuara (impact gana sobre
            // intro-bars en CrossfadeExecutor; clash es ortogonal y se suma).
            // Solo aplica a .crossfade, .eqMix, .beatMatchBlend; otras ramas
            // ignoran los flags.
            let intoBlendyType = transition.type == .crossfade
                || transition.type == .eqMix
                || transition.type == .beatMatchBlend
            var effective: [String] = []
            if intoBlendyType {
                if bImmediateImpactForA { effective.append("impact-tail") }
                else if bIntroBarsForA >= 4 && !anticipation.needsAnticipation { effective.append("intro-hold") }
                if bHarmonicClashLevelForA >= 0.7 { effective.append("clash-retreat") }
            }
            let effStr = effective.isEmpty ? "ninguno (tipo=\(transition.type) no-blendy o gateado)" : effective.joined(separator: "+")
            print("[DJMixingService] 🎚️ B→A flags: bIntroBars=\(bIntroBarsForA) bImmediateImpact=\(bImmediateImpactForA) bHarmonicClash=\(String(format: "%.1f", bHarmonicClashLevelForA)) → \(effStr)")
        }

        // ── 8e. Chill recipe (audit v8 sesion 4, 2026-05-05) ──
        // Detecta contexto chill global: ambas pistas tranquilas, baile mediocre,
        // sin impacto inmediato en B, B respira (>6s vocal, >8s chorus). Cuando
        // dispara: skipBFilters siempre + suprime DJ effects (bassKill / dynamicQ
        // / notchSweep / stutterCut). NO toca filtros estaticos/higiene del preset
        // (lowshelf -6dB en A para evitar double-bombo, etc.) — solo mata las
        // automatizaciones (lo que se MUEVE) que es lo que el usuario percibe
        // como "filtros que mancha en chill" (Cupid→No Police, Tourner→Save Your
        // Tears, Power→Day in the Life en log 2026-05-05).
        //
        // Triple cinturon vocal/chorus contra ad-libs de R&B moderno (DJ humano:
        // "hay temas que tecnicamente no son lead vocal pero ya es voz en t=2-3"):
        // exigir TODOS de:
        //   - vocalStartB - entry > 6.0  (lead vocal)
        //   - chorusStartB - entry > 8.0 (chorus/drop)
        //   - !bImmediateImpact          (defensa flag #3 v8 incluyendo intro-vocals)
        // Si el backend marca solo lead pero hay ad-libs antes, los flags v8 ya
        // los capturan via chorusStart o intro-vocals; este triple cierra el resto.
        let chillVocalSpace: Double = {
            guard let next = safeNext, next.hasError != true,
                  let v = next.vocalStartTime
            else { return .infinity }  // sin vocal data → asumir espacio sobrado
            // v=0 cuenta literal: si vocal en t=0 y entry en t=5, listener no
            // oye el vocal. chillVocalSpace = -5 < 6 → no chill (correcto).
            return v - entrySafe
        }()
        let chillChorusSpace: Double = {
            guard let next = safeNext, next.hasError != true,
                  next.chorusStartTime > 0
            else { return .infinity }
            return next.chorusStartTime - entrySafe
        }()
        let isChillContext = profile.energyA < 0.30
            && profile.energyB < 0.30
            && profile.avgDanceability < 0.55
            && !bImmediateImpactForA
            && chillVocalSpace > 6.0
            && chillChorusSpace > 8.0
        if isChillContext && !skipBFilters {
            print("[DJMixingService] 🌙 Chill recipe: forcing skipBFilters (energyA=\(String(format: "%.2f", profile.energyA)), energyB=\(String(format: "%.2f", profile.energyB)), dance=\(String(format: "%.2f", profile.avgDanceability)), vocSpace=\(String(format: "%.1f", chillVocalSpace))s, chorusSpace=\(String(format: "%.1f", chillChorusSpace))s)")
            skipBFilters = true
        }

        // ── 8f. Bass-de-B-alta gate (audit v8 sesion 4) ──
        // DJ humano: "no toques nunca el bajo de la entrante en los primeros 8
        // compases si el bajo de B esta en el percentil alto de energia sub".
        // Aproximacion sin subBassEnergy del backend: usar energyB > 0.40 como
        // proxy (Save Your Tears tiene bajo prominente y deberia disparar; chill
        // R&B con energyB ~0.10-0.20 no dispara). Independiente de chill: si
        // energyB es alta, B entra con bajo SI O SI sea cual sea el contexto.
        if profile.energyB > 0.40 && !skipBFilters {
            print("[DJMixingService] 🎸 Bass-of-B high (\(String(format: "%.2f", profile.energyB))): forcing skipBFilters (DJ rule — no tocar bajo de B prominente)")
            skipBFilters = true
        }

        // ── 8g. CUT + clash → kill midScoop on A (audit v8 sesion 4) ──
        // DJ humano: "un cut seco con keys que chocan es el peor escenario; sumar
        // mid-scoop en A durante ese momento agrava la disonancia". Para CUT con
        // tonalidades en tense (>=0.6) o clash (1.0), apagamos midScoop. La fade
        // ya viene recortada -15%/-25% por harmonic en calculateAdaptiveFadeDuration
        // (ventana de superposicion mas corta), y v8 flag #4 ya pone clash-retreat
        // en blendy types — esto cubre la rama .cut que ignora los flags.
        let effectiveMidScoop: Bool = {
            let isCut = transition.type == .cut || transition.type == .cutAFadeInB
            if isCut && harmonicClashLevel >= 0.6 {
                if djFilters.useMidScoop {
                    print("[DJMixingService] 🎚️ CUT+clash (\(String(format: "%.1f", harmonicClashLevel))): killing midScoop on A")
                }
                return false
            }
            return djFilters.useMidScoop
        }()

        // ── 9. Trigger bias — how much earlier/later A should start the crossfade ──
        let trigger = calculateTriggerBias(profile: profile, fadeDuration: effectiveFadeDuration)

        // ── 10. DJ effects (Bass Kill + Dynamic Q Resonance + Phaser Notch Sweep + Stutter Cut) ──
        let isEnergyDown = profile.energyB < profile.energyA - 0.2
        let djEffects = decideDJEffects(
            profile: profile,
            transitionType: transition.type,
            fadeDuration: effectiveFadeDuration,
            isEnergyDown: isEnergyDown,
            needsAnticipation: anticipation.needsAnticipation,
            skipBFilters: skipBFilters,
            hasBeatGridA: !dbA.isEmpty,
            isChillContext: isChillContext
        )

        // ── 11. bRapidFadeIn (audit v9 2026-05-05) ──
        // Activa la curva "B en 0 hasta el ramp final" cuando A sale limpio + B
        // abre con punch. El usuario reporto en el log v8 sesion 4 que el fade-in
        // gradual de B se percibia como "lavado" en transiciones donde A despeja
        // por su cuenta y B tiene material contundente desde el inicio. Ataca
        // 6+ casos del log: Awful Things, BOTL, OPM BABI, WAP, RATHER LIE, F33l
        // Lik3 Dyin (este ultimo entro tarde precisamente porque el fade lento
        // de B comio el espacio).
        //
        // Gates conservadores — si alguno falla, mantenemos curva clasica:
        //   - outroInstrumental A: A sale limpio sin voz/melodia que defender
        //   - bImmediateImpact: B abre con voz/chorus en primeros 4-6s
        //   - tipo "blendy" o CUT con anticipation: las ramas que tienen ramp
        //     audible de B. naturalBlend/cleanHandoff/stemMix/dropMix tienen
        //     curvas con caracter propio que NO debe sustituirse.
        //   - !chillContext: en chill el flujo es invisible, sin cambios bruscos.
        //
        // v11 (2026-05-05) — bRapidFadeIn ELIMINADO. El flag, las ramas en
        // CrossfadeExecutor y el computo se quitaron tras decidir que la
        // solucion correcta es Tier 4 (entry adelantado), no curva-spejo. El
        // field `bRapidFadeIn` en Config y CrossfadeResult se conserva como
        // stub `false` para no romper la API, pero ningun codigo lo lee ya.
        // outroInstrumentalConfident (defensa Tier 3.g) se recomputa dentro de
        // computeTier4Entry — ya no necesita scope mayor.
        let bRapidFadeIn = false

        // v14.d V2' — telemetría inerte para calibrar decisor adaptativo
        // `lsGainB_initial` en v14.e. Captura 3 señales del momento de la
        // decisión que el log-analyst sobre el coche-test v14.d rated podrá
        // cruzar con `lsGainB_initial` (ya viaja) y `userRating` para:
        //   1. Distribución real de `bassProminenceB_0_15s` sobre el catálogo
        //      → threshold percentil calibrado (vs el `0.55` magic-number
        //      del diseño inicial cazado por devils-advocate).
        //   2. Mean rating por bucket de `bassProminenceB_0_15s` + filtro
        //      `lsGainB_initial=-12` → confirmar/refutar la sinergia
        //      "bajo prominente + filtro fuerte = queja mala gestión".
        //   3. Distribución `vocalOverlapRiskCode` × `lsGainB` → validar el
        //      cinturón propuesto (no relajar en `aOnly` ni `both`).
        // Cero efecto sobre audio en v14.d. Ventana `[0..3]` = segundos 0-15
        // de B (corregida vs `[3..5]` = seg 15-25 del diseño inicial, que
        // no coincidía con la ventana audible de las quejas del director).
        let bassProminenceB_telemetry: Double? = {
            guard let pc = safeNext?.percussiveCurve, pc.count >= 3 else { return nil }
            let head = pc.prefix(3)
            return head.reduce(0, +) / Double(head.count)
        }()
        let vocalOverlapRiskCodeForTelemetry: String = {
            switch profile.vocalOverlapRisk {
            case .none:  return "none"
            case .aOnly: return "aOnly"
            case .bOnly: return "bOnly"
            case .both:  return "both"
            }
        }()
        let energyIntroBForTelemetry: Double? = {
            guard let next = safeNext, next.hasEnergyProfile else { return nil }
            return next.energyIntro
        }()
        // Sub-bass RMS <120 Hz. Lectura directa de SongAnalysis. nil cuando el
        // backend no ha analizado la pista (queda como gap en TransitionRecord).
        let subBassRmsA_outro_telemetry: Double? = safeCurrent?.subBassOutroRms
        let subBassRmsB_intro_telemetry: Double? = safeNext?.subBassIntroRms
        // `lastVocalTimeA` desambigua "vocal end no detectado" (nil) de "0
        // literal" via hasVocalEndData. `realDownbeatsACount` permite saber
        // si el path de snap al downbeat pudo ejecutarse (>0) o quedó
        // bypassed por cache sin downbeats poblados (0).
        let lastVocalTimeA_telemetry: Double? = (safeCurrent?.hasVocalEndData == true)
            ? safeCurrent?.lastVocalTime : nil
        let realDownbeatsACount_telemetry: Int? = (safeCurrent?.hasError != true)
            ? realDbA.count : nil
        Task { @MainActor in
            TransitionDiagnostics.shared.bassProminenceB_0_15s = bassProminenceB_telemetry
            TransitionDiagnostics.shared.subBassRmsA_outro = subBassRmsA_outro_telemetry
            TransitionDiagnostics.shared.subBassRmsB_intro = subBassRmsB_intro_telemetry
            TransitionDiagnostics.shared.vocalOverlapRiskCode = vocalOverlapRiskCodeForTelemetry
            TransitionDiagnostics.shared.energyIntroB_telemetry = energyIntroBForTelemetry
            TransitionDiagnostics.shared.lastVocalTimeA = lastVocalTimeA_telemetry
            TransitionDiagnostics.shared.realDownbeatsACount = realDownbeatsACount_telemetry
        }

        return CrossfadeResult(
            entryPoint: finalEntry,
            fadeDuration: effectiveFadeDuration,
            transitionType: transition.type,
            useFilters: filter.useFilters,
            useAggressiveFilters: filter.useAggressiveFilters,
            needsAnticipation: anticipation.needsAnticipation,
            anticipationTime: anticipation.anticipationTime,
            anticipationReason: anticipation.anticipationReason,
            beatSyncInfo: entry.beatSyncInfo,
            isBeatSynced: entry.isBeatSynced,
            useTimeStretch: timeStretch.useTimeStretch,
            rateA: timeStretch.rateA,
            rateB: timeStretch.rateB,
            energyA: profile.energyA,
            energyB: profile.energyB,
            beatIntervalA: biA,
            beatIntervalB: biB,
            downbeatTimesA: dbA,
            downbeatTimesB: dbB,
            realDownbeatsA: realDbA,
            meterA: meterA,
            useMidScoop: effectiveMidScoop,
            useHighShelfCut: djFilters.useHighShelfCut,
            isOutroInstrumental: outroInstrumental,
            isIntroInstrumental: introInstrumental,
            danceability: profile.avgDanceability,
            skipBFilters: skipBFilters,
            useBassKill: djEffects.useBassKill,
            useDynamicQ: djEffects.useDynamicQ,
            useNotchSweep: djEffects.useNotchSweep,
            useStutterCut: djEffects.useStutterCut,
            transitionReason: transition.reason,
            triggerBias: trigger.bias,
            triggerBiasReason: trigger.reason,
            bIntroBars: bIntroBarsForA,
            bImmediateImpact: bImmediateImpactForA,
            bHarmonicClashLevel: bHarmonicClashLevelForA,
            bRapidFadeIn: bRapidFadeIn,
            tier4Active: tier4Active,
            entryPointSource: entry.entrySource,
            tier4FailedGate: tier4Telemetry.failedGate,
            introSlopeB: tier4Telemetry.introSlopeB,
            downbeatDensityB20s: tier4Telemetry.downbeatDensityB20s,
            chillRecipeApplied: isChillContext,
            genreCapApplied: entry.genreCapApplied,
            entryFinalCapApplied: entry.entryFinalCapApplied,
            // v13.O.6 (F4) — telemetría filtros aditiva.
            rmsTailCurveA_last: rmsTailCurveAForAnticipation?.last,
            rmsTailSlopeA: Self.deriveSlope(from: rmsTailCurveAForAnticipation, tailWindows: 4),
            outroEnergyA: outroEnergyAForTelemetry
        )
    }

    // MARK: - Entry Point

    struct EntryPointResult {
        let entryPoint: Double
        let beatSyncInfo: String
        let usedFallback: Bool
        let isBeatSynced: Bool
        /// v13.K (audit 2026-05-07): path por el que se decidió este entryPoint.
        /// Default `.unknown` por compatibilidad — todos los call sites internos
        /// asignan valor concreto, pero un constructor externo sin arg queda
        /// trazable como tal.
        var entrySource: EntryPointSource = .unknown
        /// v13.O round 2026-05-10: cap chorus aplicado (true=capado, false=evaluado
        /// pero no capado, nil=path no evaluó cap). Solo lo escriben paths
        /// `punchChorusPromotion` y `punchChorusFallback`. Propagado a
        /// `CrossfadeResult.genreCapApplied` y de ahí a `TransitionDiagnostics`.
        var genreCapApplied: Bool? = nil
        /// v13.O Commit 2 (round 2026-05-10): cap defensivo POST-snap+beat-sync
        /// disparado (true) cuando el entry final superaba `kEntryFinalCap=50s`
        /// y B NO era drop-driven percussive. nil = nunca evaluado (entry
        /// quedó <=50 antes del clamp). Independiente de `genreCapApplied`:
        /// pueden ser ambos true (path chorusFallback+entry>50 post-snap raro)
        /// o solo este true (paths .dramatic/.smooth que no escriben el otro).
        var entryFinalCapApplied: Bool? = nil
    }

    /// Calculate where B starts playing. Driven by the A↔B relationship profile.
    /// The same song B will get different entry points depending on what A precedes it.
    static func calculateSmartEntryPoint(
        nextAnalysis: SongAnalysis?,
        currentAnalysis: SongAnalysis?,
        bufferDuration: Double,
        profile: TransitionProfile,
        currentPlaybackTimeA: Double? = nil
    ) -> EntryPointResult {
        let config = configs[profile.mode]!

        var entryPoint: Double = 0
        var beatSyncInfo = ""
        var usedFallback = false
        var isBeatSynced = false
        var entrySource: EntryPointSource = .unknown
        // v13.O round 2026-05-10 — propaga el flag desde calculatePunchEntry.
        // Solo lo escribe el case .punch; el resto deja nil.
        var genreCapApplied: Bool? = nil

        guard let rawNext = nextAnalysis, !rawNext.hasError else {
            entryPoint = min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)
            return EntryPointResult(entryPoint: entryPoint, beatSyncInfo: "", usedFallback: true, isBeatSynced: false, entrySource: .unknown)
        }

        let next = sanitize(rawNext, duration: bufferDuration)

        // ── Character-driven entry strategy ──
        switch profile.character {
        case .minimal:
            // Both low energy — gentle handoff. Previously hardcoded to ~2.0s,
            // which dropped the listener mid-instrumental-intro of B (Awful
            // Things → DILEMMA: entry=2.0s but chorus=13.7s; Gyalchester →
            // Father Stretch: entry=2.0s but chorus=51s after a 33s intro).
            // Pick a structural landmark when one is reasonable: prefer the
            // heuristic intro end (percussive/energy-based, robust against
            // backend mislabeling) so B enters at the start of "real content"
            // rather than at file t=0.
            let earlyEntry = min(2.0, bufferDuration * config.fallbackPercent)
            // An early chorus (<8s) means real content starts almost
            // immediately — even a "long" introEndHeuristic is suspect in
            // that case (Vamp Anthem: chorus=4.7s but heuristic=30.7s).
            // Don't trust the heuristic when the chorus contradicts it.
            let chorusEarly = next.chorusStartTime > 0 && next.chorusStartTime < 8
            let candidates: [(Double, String)] = {
                var c: [(Double, String)] = []
                if let h = next.introEndTimeHeuristic, h > 4, h < 35, !chorusEarly {
                    c.append((max(earlyEntry, h - 1.0), "introEndHeuristic"))
                }
                if next.chorusStartTime > 5, next.chorusStartTime < 35,
                   next.chorusStartTime > earlyEntry + 3 {
                    c.append((max(earlyEntry, next.chorusStartTime - 2.0), "chorus-aligned"))
                }
                return c
            }()
            if let pick = candidates.min(by: { $0.0 < $1.0 }) {
                entryPoint = max(0, min(pick.0, bufferDuration - 1))
                print("[DJMixingService] 🌙 Minimal+\(pick.1): entry=\(String(format: "%.1f", entryPoint))s (low energy + structural target)")
                return EntryPointResult(entryPoint: entryPoint, beatSyncInfo: "Minimal (\(pick.1))", usedFallback: false, isBeatSynced: false, entrySource: .minimal)
            }
            entryPoint = max(0, earlyEntry)
            print("[DJMixingService] 🌙 Minimal: entry=\(String(format: "%.1f", entryPoint))s (both low energy, gentle handoff)")
            return EntryPointResult(entryPoint: entryPoint, beatSyncInfo: "Minimal (low energy)", usedFallback: false, isBeatSynced: false, entrySource: .minimal)

        case .smooth:
            // Incompatible BPMs or low style affinity — no punch targeting.
            // But still skip past boring instrumental intros (guitars, ambient pads)
            // so the listener hears the song's "real start."
            let baseEntry = min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)

            // Vocal-aware entry reference: prefer actual vocal/energy onset
            // over ML-derived introEndTime (which can report 40-60s for
            // songs with immediate vocals — it detects "dense section start").
            // Chain: vocalStart → heuristic introEnd → speechSegments → ML introEnd
            let entryRef: Double = {
                if let vs = next.vocalStartTime, vs > 0 { return vs }
                if let h = next.introEndTimeHeuristic, h > 0 { return h }
                if let first = next.speechSegments.first, first.start > 0 { return first.start }
                if next.hasIntroData { return next.introEndTime }
                return 0
            }()
            if entryRef > baseEntry + 3 {
                entryPoint = entryRef
                entrySource = .smooth
            } else if next.chorusStartTime > baseEntry + 3 && next.chorusStartTime < bufferDuration * 0.25 {
                // Chorus as fallback — capped at 25% of song to avoid entering too deep
                entryPoint = next.chorusStartTime
                entrySource = .smoothChorusFallback
            } else {
                entryPoint = baseEntry
                entrySource = .smooth
            }
            entryPoint = max(0, min(entryPoint, bufferDuration - 1))

            // Vocal landmark alignment: if B enters after a clear vocal moment
            // (chorusStart), shift entry back so B becomes audible (~2s fade lead
            // time) right as the vocal hits. Creates a natural "reveal" — the
            // incoming track's vocal is the moment the listener notices the new song.
            // v13.F (audit 2026-05-06): margen unificado a 2s. Antes era -3.0
            // aqui mientras el resto de sites (calculatePunchEntry, dramatic,
            // minimal, PRE_PUNCH) usaban -2.0 — ese 1s extra desplazaba B
            // demasiado pronto en .smooth, contribuyendo a las quejas
            // "demasiado antes del punch" del log v12.
            if next.chorusStartTime > 5 && entryPoint > next.chorusStartTime {
                let vocalAlignedEntry = max(0, next.chorusStartTime - 2.0)
                print("[DJMixingService] 🎯 Smooth vocal alignment: entry \(String(format: "%.1f", entryPoint))s → \(String(format: "%.1f", vocalAlignedEntry))s (chorus at \(String(format: "%.1f", next.chorusStartTime))s)")
                entryPoint = vocalAlignedEntry
                entrySource = .smoothVocalAligned
            }

            print("[DJMixingService] 🌊 Smooth: entry=\(String(format: "%.1f", entryPoint))s (introEnd=\(String(format: "%.1f", next.introEndTime))s, affinity=\(String(format: "%.2f", profile.styleAffinity)))")
            return EntryPointResult(entryPoint: entryPoint, beatSyncInfo: "Smooth blend", usedFallback: false, isBeatSynced: false, entrySource: entrySource)

        case .dramatic:
            // Big energy change or harmonic clash — entry strategy depends on direction.
            let dramaticResult = calculateDramaticEntry(next: next, profile: profile, bufferDuration: bufferDuration, config: config)
            entryPoint = dramaticResult.entry
            entrySource = dramaticResult.source

        case .punch:
            // Compatible BPMs, good style affinity — target a structural moment.
            let punchResult = calculatePunchEntry(next: next, profile: profile, bufferDuration: bufferDuration, config: config)
            entryPoint = punchResult.entry
            entrySource = punchResult.source
            genreCapApplied = punchResult.genreCapApplied
        }

        // ── Phrase snapping (punch + dramatic only, not smooth/minimal) ──
        if !next.phraseBoundaries.isEmpty {
            // Snap forward to nearest phrase boundary, but capped: a generous
            // maxAhead (16s) snaps pre-chorus entries onto the chorus literal,
            // which fights chorus-mislabeled cases (BRINCANDO regression).
            // 8s ≈ 1 musical phrase at typical hip-hop tempos, plenty for
            // alignment without dragging the entry across structural sections.
            let maxAhead: Double = profile.character == .dramatic ? 4 : 8
            if let nextPhrase = next.phraseBoundaries.first(where: { $0 >= entryPoint && $0 <= entryPoint + maxAhead }) {
                entryPoint = nextPhrase
            }
        }

        // ── Beat sync (only when BPMs are compatible AND trusted) ──
        if profile.bpmRelationship != .incompatible && profile.bpmTrusted {
            let beatResult = applyBeatSync(
                entryPoint: entryPoint,
                currentAnalysis: currentAnalysis,
                nextAnalysis: next,
                currentPlaybackTimeA: currentPlaybackTimeA,
                mode: profile.mode
            )
            entryPoint = beatResult.adjustedEntryPoint
            beatSyncInfo = beatResult.info
            isBeatSynced = beatResult.isSynced
        }

        entryPoint = max(0, min(entryPoint, bufferDuration - 1))

        // ── v13.O Commit 2: hard-cap final POST-snap+beat-sync ──
        // Salida común para los paths `.punch` y `.dramatic` (los que producen
        // entries grandes). `.smooth` / `.minimal` retornan early arriba y ya
        // tienen sus propios caps internos (`config.fallbackMaxSeconds`,
        // chorus-as-fallback al 25% de la pista). El cap del Commit 1
        // (`kChorusCap=50` en `calculatePunchEntry`) NO sobrevive al phrase
        // snap (+8s en punch) ni al beat sync (±1 compás), y `.dramatic` no
        // pasa por ese cap. Aquí atrapamos cualquier entry > 50s salvo que B
        // sea drop-driven percussive (gate ratio>=2.0 heredado del Commit 1)
        // — preserva el oro tipo American Wedding→Indecision (ratio 2.18,
        // chorusStart>50).
        var entryFinalCapApplied: Bool? = nil
        if entryPoint > kEntryFinalCap {
            let (isDrop, ratioForLog) = Self.isBDropDrivenByPercussive(next.percussiveCurve)
            if !isDrop {
                let ratioStr = ratioForLog.map { String(format: "%.2f", $0) } ?? "n/a"
                print("[DJMixingService] 🛡️ Entry final cap (v13.O C2): \(String(format: "%.1f", entryPoint))s → \(String(format: "%.1f", kEntryFinalCap))s (ratio=\(ratioStr) BAL, source=\(entrySource.rawValue))")
                entryPoint = kEntryFinalCap
                entryFinalCapApplied = true
            } else {
                let ratioStr = ratioForLog.map { String(format: "%.2f", $0) } ?? "n/a"
                print("[DJMixingService] 🛡️ Entry final cap exempt: entry=\(String(format: "%.1f", entryPoint))s (ratio=\(ratioStr) DROP, source=\(entrySource.rawValue))")
                entryFinalCapApplied = false
            }
        }

        return EntryPointResult(
            entryPoint: entryPoint,
            beatSyncInfo: beatSyncInfo,
            usedFallback: usedFallback,
            isBeatSynced: isBeatSynced,
            entrySource: entrySource,
            genreCapApplied: genreCapApplied,
            entryFinalCapApplied: entryFinalCapApplied
        )
    }

    /// Entry for `.dramatic` character — big energy changes or harmonic clash.
    /// v13.K: retorna tuple con `EntryPointSource` etiquetando el path elegido.
    private static func calculateDramaticEntry(
        next: SongAnalysis,
        profile: TransitionProfile,
        bufferDuration: Double,
        config: MixModeConfig
    ) -> (entry: Double, source: EntryPointSource) {
        let vocalStart = next.vocalStartTime ?? 0
        let chorusStart = next.chorusStartTime

        // Vocal-aware entry reference (same chain as smooth/punch)
        let entryRef: Double = {
            if let vs = next.vocalStartTime, vs > 0 { return vs }
            if let h = next.introEndTimeHeuristic, h > 0 { return h }
            if let first = next.speechSegments.first, first.start > 0 { return first.start }
            if next.hasIntroData { return next.introEndTime }
            return 0
        }()

        // Margen 2s antes de vocalStart — vocalStartTime es "primer evento
        // vocal" (grito, coro, sample) no "primer verso". Entrar 2s antes
        // deja que el evento surja al fadear. Ver calculatePunchEntry para
        // contexto completo.
        let vocalEntryTarget = max(2, vocalStart - 2)

        switch profile.energyFlow {
        case .energyUp:
            // Energy rising (A chill → B hot): prefer chorus or vocalStart for impact.
            // The dramatic energy jump benefits from landing on a strong moment.
            if chorusStart > 4 && chorusStart < bufferDuration * 0.4 {
                // Margen 2s antes del chorus (P1.1, audit v8 2026-05-04):
                // simetria con vocalEntryTarget. El chorus suele empezar con
                // un golpe estructural (kick + voz). Aterrizar 2s antes deja
                // que la anacrusa / build-in entre dentro del fade.
                let chorusEntryTarget = max(2, chorusStart - 2)
                print("[DJMixingService] 🔥 Dramatic UP: chorus entry at \(String(format: "%.1f", chorusEntryTarget))s (chorus at \(String(format: "%.1f", chorusStart))s -2s margin)")
                return (chorusEntryTarget, .dramaticChorus)
            } else if vocalStart > 3 {
                print("[DJMixingService] 🔥 Dramatic UP: vocal entry at \(String(format: "%.1f", vocalEntryTarget))s (vocal at \(String(format: "%.1f", vocalStart))s -2s margin)")
                return (vocalEntryTarget, .dramaticVocal)
            } else if entryRef > 3 {
                return (entryRef, .dramaticReference)
            } else {
                return (min(config.fallbackMaxSeconds, bufferDuration * 0.03), .dramaticFallback)
            }

        case .energyDown:
            // Energy dropping (A hot → B chill): early entry, let B build gradually.
            // Don't punch — B needs space to breathe as A's energy fades.
            let earlyEntry = min(4.0, bufferDuration * 0.02)
            print("[DJMixingService] 🌅 Dramatic DOWN: early entry at \(String(format: "%.1f", earlyEntry))s (energy dropping)")
            return (earlyEntry, .dramaticFallback)

        case .steady:
            // Harmonic clash with steady energy: moderate entry, avoid extending overlap.
            if vocalStart > 3 {
                return (vocalEntryTarget, .dramaticVocal)
            } else if entryRef > 3 {
                return (entryRef, .dramaticReference)
            } else {
                return (min(config.fallbackMaxSeconds, bufferDuration * 0.02), .dramaticFallback)
            }
        }
    }

    /// Entry for `.punch` character — compatible BPMs, targeting a structural moment in B.
    /// v13.K: retorna tuple con `EntryPointSource` etiquetando el path elegido.
    /// Output de `calculatePunchEntry`. Antes era tuple `(Double, EntryPointSource)`.
    /// Ampliado en v13.O round 2026-05-10 para llevar `genreCapApplied`:
    ///   - nil  → el path no evaluó cap (vocal avoidance, vocalTarget, energyBoost que sobrescribió).
    ///   - false → cap evaluado pero NO aplicado (chorus≤50, B drop-driven exempt).
    ///   - true → cap aplicado (entry capado a 50 en promotion no-drop o fallback defensivo).
    /// Permite propagar el flag al `CrossfadeResult` y de ahí a `TransitionDiagnostics`
    /// sin cruzar non-MainActor → @MainActor inline (devils-advocate review 2026-05-10).
    private struct PunchEntryResult {
        let entry: Double
        let source: EntryPointSource
        let genreCapApplied: Bool?
    }

    private static func calculatePunchEntry(
        next: SongAnalysis,
        profile: TransitionProfile,
        bufferDuration: Double,
        config: MixModeConfig
    ) -> PunchEntryResult {
        let introEnd = next.introEndTime
        // vocalStart unwrap: nil → 0 (treat as "no usable target"). The
        // distinction nil/0 doesn't matter for entry computation here —
        // both fall through to the fallback chain via the `vocalStart > 0`
        // guards. Sites where nil semantics matter (detectIntroInstrumental)
        // unwrap explicitly with `if let`.
        let vocalStart = next.vocalStartTime ?? 0
        let chorusStart = next.chorusStartTime

        // Early-vocal-in-intro detection.
        //
        // Originally a "data corruption" guard ("vocal way before intro_end →
        // suspicious"). Backend (2026-05-01) clarified that this is a LEGITIMATE
        // case: vocalStartTime is the first vocal EVENT (grito, coro polifónico,
        // sample, ad-lib, vocoder), not the first verse — and intros frequently
        // contain such events while the structural intro continues afterwards.
        // Example: ROSALÍA "Focu 'ranni" — vocalStart=9.6s (coros), introEnd=14.7s.
        //
        // Behaviour stays the same: when this fires, downstream branches prefer
        // chorusStart over vocalStart as the entry target. That's still musically
        // correct — the chorus is a stronger landing point than a coro/ad-lib in
        // the intro. The flag name is kept for backward-compat with existing
        // print logs and reasoning chains.
        let hasReliableIntro = next.hasIntroData && introEnd > 3
        let introVocalDiverge: Bool = {
            guard hasReliableIntro, vocalStart > 0 else { return false }
            return vocalStart < introEnd - 8
        }()

        if introVocalDiverge {
            print("[DJMixingService] 🎤 Early vocal in intro: introEnd=\(String(format: "%.1f", introEnd))s vocalStart=\(String(format: "%.1f", vocalStart))s — preferring chorus over vocalStart as entry target")
        }

        // ── Chorus-mislabeled safeguard ──
        // Backend chorusStartB sometimes points to a verse drop or 2nd-verse
        // landmark instead of the structural chorus. With our v6 sanitize
        // fallback (`vocalStart = chorus - 8` when backend returns 0), this
        // mislabeled chorus drags the inferred vocalStart into post-intro
        // territory and downstream logic snaps the entry to the chorus literal.
        // This produced the BRINCANDO regression: chorus=38.4s, introH=29.3s,
        // vocalStart inferred=30.4s → entry collapsed to 38.4s.
        //
        // Detection: chorus is 4–15s past the heuristic intro end. Larger gaps
        // (>15s) are genuine deep-chorus tracks (hip-hop with mid-song drop)
        // where chorus targeting is the right call — leave those alone.
        let chorusLikelyMislabeled: Bool = {
            guard let h = next.introEndTimeHeuristic, h > 4 else { return false }
            let gap = chorusStart - h
            return gap > 4 && gap < 15
        }()
        if chorusLikelyMislabeled {
            print("[DJMixingService] ⚠️ Chorus likely mislabeled: chorusStart=\(String(format: "%.1f", chorusStart))s vs introEndHeuristic=\(String(format: "%.1f", next.introEndTimeHeuristic ?? 0))s (gap \(String(format: "%.1f", chorusStart - (next.introEndTimeHeuristic ?? 0)))s) — pinning entry to heuristic")
        }

        var entry: Double
        var source: EntryPointSource = .punchBufferFallback  // se sobrescribe en cada rama
        // v13.O round 2026-05-10 — flag mutable propagado al final del return.
        // Solo lo escriben los paths que evalúan cap chorus (promotion + fallback).
        var genreCapApplied: Bool? = nil

        // ── Vocal-aware entry reference: when B's "real content" starts ──
        // Chain: vocalStart → heuristic introEnd → speechSegments → ML introEnd
        // introEndTime from ML can report 40-60s for songs with immediate vocals.
        // introEndTimeHeuristic (percussive/energy detector) is more reliable.
        // When chorusLikelyMislabeled, prefer heuristic over the (possibly
        // sanitize-poisoned) vocalStart.
        let entryReference: Double = {
            if chorusLikelyMislabeled, let h = next.introEndTimeHeuristic, h > 0 { return h }
            if let vs = next.vocalStartTime, vs > 0 { return vs }
            if let h = next.introEndTimeHeuristic, h > 0 { return h }
            if let first = next.speechSegments.first, first.start > 0 { return first.start }
            if next.hasIntroData { return next.introEndTime }
            return 0
        }()
        let introIsInstrumental = entryReference > 8.0
        let vocalStartReliable: Bool = {
            // Sanitize-inferred vocalStart (chorus-8) is poisoned when the
            // chorus itself is mislabeled — refuse to trust it as a target.
            if chorusLikelyMislabeled { return false }
            return vocalStart > 0 && (introIsInstrumental || vocalStart < 20)
        }()

        // ── Vocal overlap avoidance: if both songs have vocals, prefer entering B
        // at an instrumental section so A's vocals can fade before B's vocals start ──
        // ONLY when the intro is confirmed instrumental — if B already has vocals in the
        // intro, there is no clean instrumental window and this strategy produces wrong
        // entry points deep into the song.
        if profile.vocalOverlapRisk == .both && vocalStart > 3
            && introIsInstrumental && vocalStartReliable {
            let safeEntry = max(0, vocalStart - 6)
            if safeEntry > 2 {
                print("[DJMixingService] 🎤 Punch w/ vocal avoidance: entry=\(String(format: "%.1f", safeEntry))s (vocals at \(String(format: "%.1f", vocalStart))s)")
                return PunchEntryResult(entry: safeEntry, source: .punchVocalAvoidance, genreCapApplied: nil)
            }
        }

        // ── Chorus promotion: enter at the chorus when it's clearly the payoff ──
        // Default punch routing prefers vocalStart, which lands in verse 1. For
        // hip-hop / drill / trap tracks where the chorus is the real impact
        // (EVIL J0RDAN: chorusStart≈59s vs vocalStart≈2s), entering at verse 1
        // wastes the structural payoff and the listener's attention is on the
        // wrong moment.
        //
        // Conditions are intentionally tight to avoid mis-firing on pop / rock
        // where verse 1 IS content the listener wants to hear:
        //
        //   - profile.avgDanceability > 0.55  → bailable / hip-hop / dance only
        //   - bufferDuration > 90s            → short singles don't have a deep chorus
        //   - chorusStart > 35s               → "deep chorus" floor; pop typically <30s
        //   - chorus is at least 20s past the first vocal/intro reference
        //   - chorus stays in the first half of B → don't enter past midpoint
        //
        // referenceForGap tolerates either a known vocalStart OR the fallback
        // entryReference chain (introEndHeuristic / speechSegments / introEnd) —
        // so the promotion still fires when vocalStart is missing, as long as
        // some other "early reference" exists to compare against chorusStart.
        let referenceForGap: Double = vocalStart > 0 ? vocalStart : entryReference
        let isDanceable = profile.avgDanceability > 0.55
        let bufferLongEnough = bufferDuration > 90
        let chorusDeepEnough = chorusStart > 35
        let chorusFarFromReference = referenceForGap > 0 && chorusStart > referenceForGap + 20
        let chorusInUsableHalf = chorusStart < bufferDuration * 0.5
        // v13.O.3 (P3): guardia `vocalStartUsable`. Si vocalStart de B está en
        // ventana razonable [8s, 40s] Y está suficientemente lejos del chorus
        // (>=15s), preferir vocalStart sobre chorus. La promotion histórica
        // disparaba aunque vocalStart fuese una intro perfectamente utilizable.
        // Quote testigo (All Tinted → Mamichula r=3): "playerA dejaba una
        // entrada perfecta para playerB. Sin embargo playerB ha escogido de
        // punto de entrada muy malo y muy lejano a lo que podía ser una intro
        // mejor". Bench v13.O.3 (1026926): 14/27 promotions reasignadas,
        // upside teórico +0.092. La promotion solo dispara cuando vocalStart
        // NO sirve (<8s = inutilizable, >40s = vocal tardía donde chorus gana).
        let vocalStartUsable: Bool = vocalStart >= 8.0
            && vocalStart <= 40.0
            && (chorusStart - vocalStart) >= 15.0
        if isDanceable && bufferLongEnough && chorusDeepEnough
            && chorusFarFromReference && chorusInUsableHalf
            && !chorusLikelyMislabeled
            && !vocalStartUsable {
            // v13.O round 2026-05-10 — cap chorus_promotion con gate percussive.
            //
            // Director descubrió 2026-05-10 que Navidrome es generalista
            // (Bruno Mars balada y The Weeknd trap-soul ambos "Contemporary R&B"
            // → el gate por etiqueta de género no podía distinguir balada de
            // drop-driven). Backend-guardian propuso `percussiveCurve` (HPSS
            // percussive stem, 18 ventanas 5s sobre 90s, 100% backfilled) cuyo
            // ratio main/intro discrimina audio drop-driven de balada agnóstico
            // al género. Validación bench v13O v2 sobre log v13.LMN:
            //   - Cry → Talking to the Moon  ratio=1.87 (BAL) → cap aplica ✓
            //   - Best Part → Summers       ratio=1.01 (BAL) → cap aplica ✓
            //   - American Wedding → Indecision ratio=2.23 (DROP) → exempt ✓
            // Mean predicho 6.16 → 6.37, cola izquierda 22% → 17%, 0 regresiones rated≥7.
            //
            // Default conservador: si percussiveCurve falta o tiene <6 muestras
            // → asumimos NO drop (cap aplica). Cobertura backfill 100% hace
            // este caso muy infrecuente; preferimos fallar al lado del cap
            // defensivo (Bruno Mars indebidamente cappeado pesa menos que
            // Bruno Mars indebidamente exempt).
            let kChorusCap: Double = 50.0
            let (isDrop, ratioForLog) = Self.isBDropDrivenByPercussive(next.percussiveCurve)
            let needsCap = chorusStart > kChorusCap && !isDrop
            // Margen 2s antes del chorus (P1.1, audit v8 2026-05-04): simetria
            // con vocalEntryTarget. Cuando se aplica el cap, el target literal
            // es 50s — sin margen porque NO estamos entrando al chorus, sino
            // truncando defensivamente.
            let chorusEntryTarget: Double = needsCap ? kChorusCap : max(2, chorusStart - 2)
            let ratioStr = ratioForLog.map { String(format: "%.2f", $0) } ?? "n/a"
            if needsCap {
                print("[DJMixingService] 🎯 Punch chorus promotion (CAPPED): entry=\(String(format: "%.1f", chorusEntryTarget))s (chorus=\(String(format: "%.1f", chorusStart))s capado a \(kChorusCap)s, ratio=\(ratioStr) BAL, dance=\(String(format: "%.2f", profile.avgDanceability)))")
            } else if isDrop {
                print("[DJMixingService] 🎯 Punch chorus promotion: entry=\(String(format: "%.1f", chorusEntryTarget))s (chorus=\(String(format: "%.1f", chorusStart))s -2s, ratio=\(ratioStr) DROP exempt, dance=\(String(format: "%.2f", profile.avgDanceability)))")
            } else {
                print("[DJMixingService] 🎯 Punch chorus promotion: entry=\(String(format: "%.1f", chorusEntryTarget))s (chorus=\(String(format: "%.1f", chorusStart))s -2s, chorus≤cap, dance=\(String(format: "%.2f", profile.avgDanceability)))")
            }
            let capped = Self.applyVlfsCap(
                entry: chorusEntryTarget,
                source: .punchChorusPromotion,
                vocalStart: vocalStart,
                vocalStartReliable: vocalStartReliable
            )
            return PunchEntryResult(
                entry: capped.entry,
                source: capped.source,
                genreCapApplied: chorusStart > kChorusCap ? needsCap : false
            )
        }

        // ── Style affinity modulates how aggressively we target ──
        // High affinity (>0.7): same genre feel — aggressive targeting
        // Medium affinity (0.4-0.7): compatible — moderate targeting
        // Low affinity (<0.4): would have been .smooth, shouldn't reach here
        //
        // NOTE: entryReference (vocal-aware) replaces raw introEnd for entry
        // assignment. introEnd from the ML model can report 40-60s for songs
        // with immediate vocals. entryReference uses the fallback chain:
        // vocalStartTime → speechSegments[0] → introEndTime.

        // Margen 2s antes de vocalStart (backend confirmation 2026-05-01):
        // vocalStartTime es "primer evento vocal", no "primer verso" — puede
        // ser un grito ("Beat it!"), un coro polifónico, un sample vocal, etc.
        // Entrar EXACTAMENTE en ese momento se siente abrupto. Entrar 2s antes
        // deja que el evento vocal surja al fadear, comportamiento DJ humano.
        // Floor a 2s para no forzar entry pre-musical en pistas con
        // vocalStart bajo (e.g. ad-lib temprano a t=4 → entry=2 mejor que 0).
        let vocalEntryTarget = max(2, vocalStart - 2)

        if profile.styleAffinity > 0.7 {
            // Same "world" — go for the most impactful entry
            if vocalStartReliable && vocalStart > 3 && !introVocalDiverge {
                entry = vocalEntryTarget
                source = .punchVocalTarget
            } else if entryReference > 3 && !introVocalDiverge {
                entry = entryReference
                source = .punchEntryReference
            } else if chorusStart > 6 {
                // v13.O round 2026-05-10 — cap defensivo SIN gate exempt
                // (decisión director). Floor subido 4→6 (chorus<6 = ad-lib/ruido,
                // mejor caer a bufferFallback que castigar con cap). El fallback
                // se activa cuando vocalStartReliable y entryReference fallaron
                // → escenario degradado, sin landmarks confiables. Caso real:
                // The Time → Como Camarón, chorusStart=141s ("ha empezado al
                // final WTF" rating 1) → entry capado a 50.
                let kChorusCap: Double = 50.0
                let cappedChorus = min(chorusStart, kChorusCap)
                // Margen 2s antes del chorus (P1.1 audit v8) — simetria con vocal.
                entry = max(2, cappedChorus - 2)
                source = .punchChorusFallback
                if chorusStart > kChorusCap {
                    genreCapApplied = true
                    print("[DJMixingService] ⚠️ Punch chorus fallback (CAPPED): entry=\(String(format: "%.1f", entry))s (chorusStart=\(String(format: "%.1f", chorusStart))s capado a \(kChorusCap)s, defensivo)")
                } else {
                    genreCapApplied = false
                }
            } else if vocalStartReliable && vocalStart > 2 {
                entry = vocalEntryTarget
                source = .punchVocalTarget
            } else if entryReference > 3 {
                entry = entryReference
                source = .punchEntryReference
            } else {
                entry = min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)
                source = .punchBufferFallback
            }
        } else {
            // Moderate affinity — less aggressive
            if entryReference > 3 && !introVocalDiverge {
                entry = entryReference
                source = .punchEntryReference
            } else if vocalStartReliable && vocalStart > 3 && !introVocalDiverge {
                entry = vocalEntryTarget
                source = .punchVocalTarget
            } else if vocalStartReliable && vocalStart > 2 {
                entry = vocalEntryTarget
                source = .punchVocalTarget
            } else if entryReference > 3 {
                entry = entryReference
                source = .punchEntryReference
            } else {
                entry = min(config.fallbackMaxSeconds, bufferDuration * config.fallbackPercent)
                source = .punchBufferFallback
            }
        }

        // ── Energy boost: rising energy → prefer chorus if nearby ──
        if profile.energyFlow == .energyUp && profile.energyGap > 0.25 {
            if chorusStart > entry && chorusStart < entry + 30 {
                // Margen 2s antes del chorus (P1.1 audit v8) — simetria con vocal.
                entry = max(2, chorusStart - 2)
                source = .punchEnergyBoost
                // v13.O round 2026-05-10 — si el fallback aplicó cap antes y el
                // energy boost lo sobrescribe (entry pasa de 50 a chorusStart-2),
                // resetear genreCapApplied para no mentir en telemetría.
                // El cap dejó de aplicarse efectivamente cuando entry cambió.
                genreCapApplied = false
            }
        }

        let capped = Self.applyVlfsCap(
            entry: entry,
            source: source,
            vocalStart: vocalStart,
            vocalStartReliable: vocalStartReliable
        )
        return PunchEntryResult(entry: capped.entry, source: capped.source, genreCapApplied: genreCapApplied)
    }

    /// v15.e — Cap defensivo anti-vlfs-negativo aplicado a la salida de
    /// `calculatePunchEntry`. Si `entry` cae más de 5s después del primer
    /// evento vocal de B (vlfs = vocalStart - entry < -5), retraemos a
    /// `vocalEntryTarget = max(2, vocalStart - 2)` para que B se presente
    /// antes del vocal en vez de aterrizar a mitad de verso.
    ///
    /// El threshold -5s prefiere ser conservador: solo dispara cuando el
    /// desfase es claramente perceptible como "B ya está en plena
    /// canción". Aplicado en los dos returns de calculatePunchEntry
    /// (punchChorusPromotion early + return final).
    ///
    /// Guards:
    /// - vocalStartReliable=false → no aplica (chorusLikelyMislabeled o
    ///   vocalStart fuera de [3,20] sin introIsInstrumental).
    /// - vocalStart<3 → no aplica (pista con vocal a t=0, cap daría
    ///   entry=2 sub-musical sobre grito/sample).
    ///
    /// Emite source `.punchVocalCappedRollback` para distinguir en
    /// telemetría los casos donde el cap disparó del path original.
    private static func applyVlfsCap(
        entry: Double,
        source: EntryPointSource,
        vocalStart: Double,
        vocalStartReliable: Bool
    ) -> (entry: Double, source: EntryPointSource) {
        guard vocalStartReliable, vocalStart >= 3.0 else { return (entry, source) }
        let vlfs = vocalStart - entry
        guard vlfs < -5.0 else { return (entry, source) }
        let cappedEntry = max(2.0, vocalStart - 2.0)
        print("[DJMixingService] 🛡️ v15.e VLFS cap: entry=\(String(format: "%.1f", entry))s → \(String(format: "%.1f", cappedEntry))s (vocalStart=\(String(format: "%.1f", vocalStart))s, vlfs=\(String(format: "%.1f", vlfs))s, srcOrig=\(source))")
        return (cappedEntry, .punchVocalCappedRollback)
    }

    // MARK: - Sanitize

    private static func sanitize(_ analysis: SongAnalysis, duration: Double) -> SongAnalysis {
        var a = analysis
        let maxT = max(0, duration)

        a.introEndTime = min(max(0, a.introEndTime), maxT)
        a.outroStartTime = min(max(0, a.outroStartTime), maxT)
        if let vs = a.vocalStartTime { a.vocalStartTime = min(max(0, vs), maxT) }
        a.chorusStartTime = min(max(0, a.chorusStartTime), maxT)
        if a.hasCuePoint { a.cuePoint = min(max(0, a.cuePoint), maxT) }
        if a.hasVocalEndData { a.lastVocalTime = min(max(0, a.lastVocalTime), maxT) }
        a.phraseBoundaries = a.phraseBoundaries.filter { $0 >= 0 && $0 <= maxT }
        a.downbeatTimes = a.downbeatTimes.filter { $0 >= 0 && $0 <= maxT }
        a.speechSegments = a.speechSegments.compactMap { seg in
            let s = max(0, seg.start)
            let e = min(maxT, seg.end)
            return s < e ? (start: s, end: e) : nil
        }

        if a.bpm < 30 || a.bpm > 300 { a.bpm = 120 }
        a.energy = min(max(0, a.energy), 1)
        if a.hasEnergyProfile {
            a.energyIntro = min(max(0, a.energyIntro), 1)
            a.energyMain = min(max(0, a.energyMain), 1)
            a.energyOutro = min(max(0, a.energyOutro), 1)
        }

        if a.hasOutroData && a.hasVocalEndData
            && a.lastVocalTime > a.outroStartTime + 3 {
            print("[DJMixingService] ⚠️ Sanitize: lastVocal (\(String(format: "%.1f", a.lastVocalTime))s) > outroStart (\(String(format: "%.1f", a.outroStartTime))s) — adjusting outro to vocal end")
            a.outroStartTime = a.lastVocalTime
        }

        // ── 0.5. vocalStartTime semantics (post-backend confirmation 2026-05-01) ──
        // Backend confirmed `vocalStartTime == 0` is LITERAL — the track has
        // vocals from t=0. It's NOT a "value missing" sentinel. The earlier
        // sanitize fallback (`vocalStart = chorus - 8`, commit 05d1565)
        // assumed missing semantics and wrote synthetic values into a field
        // that already had a valid meaning, which produced the BRINCANDO
        // regression and other "B tarde" bugs (P0.1 mitigated downstream;
        // removing the sanitize is the actual root-cause fix).
        //
        // With vocalStart=0 left intact, downstream paths that gate on
        // `vocalStart > 0` correctly treat the track as "vocal at t=0 →
        // no clean instrumental window" and fall back to heuristic
        // (`introEndTimeHeuristic` → `speechSegments[0].start` → ML
        // `introEndTime`). That fallback chain is the right behaviour for
        // tracks with immediate vocals; it was being short-circuited by
        // the inferred chorus-8s value.

        // ── 1. Cross-validate introEnd against structural landmarks (safety nets) ──

        // 1a. Chorus before introEnd: the intro must end before the chorus starts
        if a.hasIntroData && a.chorusStartTime > 4 && a.chorusStartTime < a.introEndTime - 5 {
            print("[DJMixingService] ⚠️ Sanitize: chorusStart (\(String(format: "%.1f", a.chorusStartTime))s) << introEnd (\(String(format: "%.1f", a.introEndTime))s) — capping introEnd to chorus")
            a.introEndTime = a.chorusStartTime
        }

        // 1b. Speech segments (vocals) starting well before introEnd
        if a.hasIntroData && !a.speechSegments.isEmpty {
            let earlyVocal = a.speechSegments.first(where: { $0.end - $0.start > 3 && $0.start < a.introEndTime - 5 })
            if let ev = earlyVocal {
                let cappedIntro = ev.start
                if cappedIntro < a.introEndTime - 5 && cappedIntro >= 2 {
                    print("[DJMixingService] ⚠️ Sanitize: vocal segment at \(String(format: "%.1f", ev.start))s << introEnd (\(String(format: "%.1f", a.introEndTime))s) — capping introEnd to vocal start")
                    a.introEndTime = cappedIntro
                }
            }
        }

        // 1c. Hard cap: intros > 30s are extremely rare outside ambient/classical.
        if a.hasIntroData && a.introEndTime > 30 {
            print("[DJMixingService] ⚠️ Sanitize: introEnd (\(String(format: "%.1f", a.introEndTime))s) > 30s hard cap — capping")
            a.introEndTime = min(a.introEndTime, 30)
        }

        if a.beatInterval > 0 && a.bpm > 0 {
            let bpmDerived = 60.0 / a.bpm
            if abs(a.beatInterval - bpmDerived) / bpmDerived > 0.15 {
                print("[DJMixingService] ⚠️ Sanitize: beatInterval (\(String(format: "%.3f", a.beatInterval))s) diverges >15% from BPM-derived (\(String(format: "%.3f", bpmDerived))s) — using BPM-derived")
                a.beatInterval = bpmDerived
            }
        }
        if a.beatInterval < 0.15 || a.beatInterval > 3.0 {
            a.beatInterval = a.bpm > 0 ? 60.0 / a.bpm : 0
        }

        if a.beatInterval > 0 && a.downbeatTimes.count >= 4 {
            let expectedMeasure = a.beatInterval * 4
            var spacings: [Double] = []
            for i in 1..<a.downbeatTimes.count {
                spacings.append(a.downbeatTimes[i] - a.downbeatTimes[i - 1])
            }
            spacings.sort()
            let median = spacings[spacings.count / 2]
            if abs(median - expectedMeasure) / expectedMeasure > 0.30 {
                print("[DJMixingService] ⚠️ Sanitize: downbeat spacing (\(String(format: "%.3f", median))s) diverges >30% from beatInterval*4 (\(String(format: "%.3f", expectedMeasure))s) — clearing downbeats")
                a.downbeatTimes = []
            }
        }

        a.danceability = min(max(0, a.danceability), 1)
        return a
    }

    // MARK: - Beat Sync

    private struct BeatSyncResult {
        let adjustedEntryPoint: Double
        let info: String
        let isSynced: Bool
    }

    private static func applyBeatSync(
        entryPoint: Double,
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis,
        currentPlaybackTimeA: Double?,
        mode: MixMode
    ) -> BeatSyncResult {
        guard !nextAnalysis.hasError, nextAnalysis.beatInterval > 0 else {
            return BeatSyncResult(adjustedEntryPoint: entryPoint, info: "", isSynced: false)
        }

        let hasCurrentBeats = currentAnalysis != nil && currentAnalysis?.hasError != true
            && (currentAnalysis?.beatInterval ?? 0) > 0
        let beatIntervalA = currentAnalysis?.beatInterval ?? nextAnalysis.beatInterval
        let beatIntervalB = nextAnalysis.beatInterval
        let targetBeats = nextAnalysis.downbeatTimes

        let searchRange = beatIntervalB * 1.0

        var adjustedEntryPoint = entryPoint
        var info = ""
        var isBeatSynced = false

        // Phase 1: Align B to its nearest downbeat (tight snap)
        if !targetBeats.isEmpty {
            let candidates = targetBeats.filter { abs($0 - entryPoint) <= searchRange }
            if let best = candidates.min(by: { abs($0 - entryPoint) < abs($1 - entryPoint) }) {
                let adj = best - entryPoint
                adjustedEntryPoint = best
                isBeatSynced = true
                info = "Downbeat real: \(adj >= 0 ? "+" : "")\(String(format: "%.3f", adj))s"
            } else {
                let gridSnap = snapToMeasureGrid(entryPoint, measureLength: beatIntervalB * 4, beatInterval: beatIntervalB)
                if abs(gridSnap) <= beatIntervalB * 0.5 {
                    adjustedEntryPoint = entryPoint + gridSnap
                    isBeatSynced = true
                    info = "Grid snap: \(gridSnap >= 0 ? "+" : "")\(String(format: "%.3f", gridSnap))s"
                }
            }
        } else {
            let gridSnap = snapToMeasureGrid(entryPoint, measureLength: beatIntervalB * 4, beatInterval: beatIntervalB)
            if abs(gridSnap) <= beatIntervalB * 0.5 {
                adjustedEntryPoint = entryPoint + gridSnap
                isBeatSynced = true
                info = "Grid snap: \(gridSnap >= 0 ? "+" : "")\(String(format: "%.3f", gridSnap))s"
            }
        }

        // Phase 2: Cross-phase alignment A↔B (DJ mode only)
        if mode == .dj, hasCurrentBeats, let playbackA = currentPlaybackTimeA, playbackA > 0 {
            let beatFractionA = playbackA.truncatingRemainder(dividingBy: beatIntervalA) / beatIntervalA
            let targetPhaseOffsetB = beatFractionA * beatIntervalB
            let currentPhaseB = adjustedEntryPoint.truncatingRemainder(dividingBy: beatIntervalB)
            var phaseError = targetPhaseOffsetB - currentPhaseB
            if phaseError > beatIntervalB / 2 { phaseError -= beatIntervalB }
            if phaseError < -beatIntervalB / 2 { phaseError += beatIntervalB }

            if abs(phaseError) > beatIntervalB * 0.15 {
                if !targetBeats.isEmpty {
                    let candidates = targetBeats.filter {
                        abs($0 - adjustedEntryPoint) <= searchRange && $0 >= 0
                    }
                    var bestCandidate = adjustedEntryPoint
                    var bestError = abs(phaseError)
                    for candidate in candidates {
                        let candPhase = candidate.truncatingRemainder(dividingBy: beatIntervalB)
                        var candError = targetPhaseOffsetB - candPhase
                        if candError > beatIntervalB / 2 { candError -= beatIntervalB }
                        if candError < -beatIntervalB / 2 { candError += beatIntervalB }
                        if abs(candError) < bestError {
                            bestError = abs(candError)
                            bestCandidate = candidate
                        }
                    }
                    let phaseAdj = bestCandidate - adjustedEntryPoint
                    if abs(phaseAdj) <= beatIntervalB * 0.5 {
                        adjustedEntryPoint = bestCandidate
                        info += " + fase A↔B: \(phaseAdj >= 0 ? "+" : "")\(String(format: "%.3f", phaseAdj))s"
                    }
                } else {
                    let phaseAdj = max(-searchRange, min(searchRange, phaseError))
                    if abs(phaseAdj) <= beatIntervalB * 0.5 {
                        adjustedEntryPoint += phaseAdj
                        info += " + fase A↔B: \(phaseAdj >= 0 ? "+" : "")\(String(format: "%.3f", phaseAdj))s"
                    }
                }
            }
        }

        if !isBeatSynced {
            print("[DJMixingService] Beat sync: no snap applied (no downbeats within ±1 beat of entry)")
        }
        return BeatSyncResult(adjustedEntryPoint: max(0, adjustedEntryPoint), info: info, isSynced: isBeatSynced)
    }

    private static func snapToMeasureGrid(_ time: Double, measureLength: Double, beatInterval: Double) -> Double {
        guard measureLength > 0 else { return 0 }
        let timeIntoMeasure = time.truncatingRemainder(dividingBy: measureLength)
        if timeIntoMeasure < beatInterval * 0.5 && timeIntoMeasure > 0.001 {
            return -timeIntoMeasure
        }
        let distToNext = measureLength - timeIntoMeasure
        if distToNext < beatInterval * 0.5 {
            return distToNext
        }
        let timeIntoBeat = timeIntoMeasure.truncatingRemainder(dividingBy: beatInterval)
        if timeIntoBeat < beatInterval * 0.25 {
            return -timeIntoBeat
        } else if timeIntoBeat > beatInterval * 0.75 {
            return beatInterval - timeIntoBeat
        }
        return 0
    }

    // MARK: - Fade Duration

    struct FadeDurationResult {
        let duration: Double
        let decision: String
    }

    /// Fade duration — driven by profile relationship.
    /// High style affinity allows longer fades; low affinity prefers shorter.
    /// Bass conflict shortens fade; energy-down extends it.
    static func calculateAdaptiveFadeDuration(
        entryPoint: Double,
        bufferADuration: Double,
        bufferBDuration: Double,
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        profile: TransitionProfile,
        userFadeDuration: Double? = nil
    ) -> FadeDurationResult {
        let config = configs[profile.mode]!
        let baseDuration = userFadeDuration ?? config.baseFadeDuration
        var fadeDuration = baseDuration
        var decision = "Base (\(fadeDuration)s)."

        let hasCurrent = currentAnalysis != nil && currentAnalysis?.hasError == false
        let hasNext = nextAnalysis != nil && nextAnalysis?.hasError == false

        if hasCurrent, hasNext, let current = currentAnalysis, let next = nextAnalysis {
            let backendFadeIn = next.backendFadeInDuration
            let backendFadeOut = current.backendFadeOutDuration

            if userFadeDuration == nil, let bfi = backendFadeIn, bfi >= 2 {
                fadeDuration = max(config.minFadeDuration, min(config.maxFadeDuration, bfi))
                decision = "Backend fadeIn: \(String(format: "%.1f", bfi))s → \(String(format: "%.1f", fadeDuration))s."

                if let bfo = backendFadeOut, bfo >= 2 {
                    let avg = (fadeDuration + max(config.minFadeDuration, min(config.maxFadeDuration, bfo))) / 2
                    fadeDuration = avg
                    decision = "Backend fadeIn/Out: \(String(format: "%.1f", bfi))/\(String(format: "%.1f", bfo))s → avg \(String(format: "%.1f", fadeDuration))s."
                }

                if entryPoint > 0 && fadeDuration * 1.2 > entryPoint {
                    let localMin = profile.mode == .dj ? 2.0 : config.minFadeDuration
                    fadeDuration = max(localMin, entryPoint / 1.2)
                    decision += " Capped por punch a \(String(format: "%.1f", fadeDuration))s."
                }
            } else {
                let outroAStart = current.outroStartTime > 0 ? current.outroStartTime : bufferADuration
                let outroADuration = bufferADuration - outroAStart
                let hasValidOutro = outroADuration >= 2
                let localMin = profile.mode == .dj ? 2.0 : config.minFadeDuration

                let idealFade = entryPoint
                let outroConstraint = hasValidOutro ? outroADuration : config.maxFadeDuration

                if idealFade >= localMin {
                    fadeDuration = max(localMin, min(config.maxFadeDuration, idealFade, outroConstraint))
                    decision = "Estructural: intro=\(String(format: "%.1f", idealFade))s outro=\(String(format: "%.1f", outroADuration))s → \(String(format: "%.1f", fadeDuration))s."
                } else if hasValidOutro {
                    fadeDuration = max(localMin, min(config.maxFadeDuration, outroADuration * 0.8))
                    decision = "Punch temprano (\(String(format: "%.1f", idealFade))s), outro=\(String(format: "%.1f", outroADuration))s → \(String(format: "%.1f", fadeDuration))s."
                } else {
                    fadeDuration = userFadeDuration ?? (profile.mode == .dj ? 5 : 6)
                    decision = "Sin estructura clara: \(String(format: "%.1f", fadeDuration))s."
                }

                if entryPoint > 0 && fadeDuration * 1.2 > entryPoint {
                    fadeDuration = max(localMin, entryPoint / 1.2)
                    decision += " Capped por punch a \(String(format: "%.1f", fadeDuration))s."
                }
            }

            // ── Profile-driven modulations ──

            // Character: minimal → extend for gentler handoff
            if profile.character == .minimal && fadeDuration < 8 {
                fadeDuration = min(config.maxFadeDuration, max(fadeDuration, 8))
                decision += " Extendido por minimal a \(String(format: "%.1f", fadeDuration))s."
            }

            // Energy flow: energy-down with long outro → extend for graceful descent
            if profile.energyFlow == .energyDown {
                let outroAStart2 = current.outroStartTime > 0 ? current.outroStartTime : bufferADuration
                let outroLen = bufferADuration - outroAStart2
                if outroLen > 12 {
                    fadeDuration = min(15, max(fadeDuration, outroLen * 0.9))
                    decision += " Extendido por caida de energia a \(String(format: "%.1f", fadeDuration))s."
                }
            }

            // Bass conflict: shorten slightly to reduce bass overlap time
            if profile.bassConflictRisk && fadeDuration > 6 {
                fadeDuration = max(5, fadeDuration * 0.85)
                decision += " Acortado por bass conflict a \(String(format: "%.1f", fadeDuration))s."
            }

            // Style affinity: low affinity → shorter fade (they sound foreign together)
            if profile.styleAffinity < 0.35 && fadeDuration > 5 {
                fadeDuration = max(4, fadeDuration * 0.8)
                decision += " Acortado por baja afinidad (\(String(format: "%.2f", profile.styleAffinity))) a \(String(format: "%.1f", fadeDuration))s."
            }

            // Harmonic penalty
            switch profile.harmonic.compatibility {
            case .compatible, .acceptable:
                break
            case .tense:
                fadeDuration = max(2, fadeDuration * 0.85)
                decision += " Reducido 15% por tension armonica a \(String(format: "%.2f", fadeDuration))s."
            case .clash:
                fadeDuration = max(2, fadeDuration * 0.75)
                decision += " Reducido 25% por clash armonico a \(String(format: "%.2f", fadeDuration))s."
            }
        } else {
            fadeDuration = userFadeDuration ?? (bufferADuration < 30 ? 3 : baseDuration)
            decision = "Sin analisis — duracion \(String(format: "%.0f", fadeDuration))s."
        }

        // ── Cap by B's intro instrumental window ──
        // The fade should not extend past B's vocal entry. Using the heuristic
        // intro end (percussion/energy-based), not the ML model value which is
        // often 2-3x longer and includes vocal sections.
        // Allow 85% of the intro window so the fade finishes before vocals hit.
        if let next = nextAnalysis, next.hasError != true {
            let introWindow = next.introEndTimeHeuristic ?? (next.hasIntroData ? next.introEndTime : 0)
            if introWindow > 2 {
                let introCap = introWindow * 0.85
                if fadeDuration > introCap {
                    fadeDuration = max(2, introCap)
                    decision += " Capped por intro B (\(String(format: "%.1f", introWindow))s×0.85) a \(String(format: "%.1f", fadeDuration))s."
                }
            }

            // v14.h — gate fade-vs-punch. Si introEndHeuristic < entryPoint − 1s,
            // la intro de B ya terminó antes de que B entre en mezcla; el fade
            // largo aplasta el chorus que ya está sonando libre. Acorta el fade
            // al espacio real disponible (entry − introEnd) × 0.85, manteniendo
            // floor 3s para no degenerar en quasi-CUT. No fuerza cambio de tipo;
            // solo limita duración.
            if let introEnd = next.introEndTimeHeuristic,
               introEnd > 0,
               introEnd < entryPoint - 1.0,
               fadeDuration > 5 {
                let punchCap = max(3.0, (entryPoint - introEnd) * 0.85)
                if fadeDuration > punchCap {
                    fadeDuration = punchCap
                    decision += " Capped por fade-vs-punch (introEnd \(String(format: "%.1f", introEnd))s < entry \(String(format: "%.1f", entryPoint))s−1) a \(String(format: "%.1f", fadeDuration))s."
                }
            }
        }

        // ── Shorten when A has no instrumental outro ──
        // If A's outro is vocal (or unconfirmed), A likely has voice until the end.
        // Reduce fade to minimize vocal overlap from the outgoing track — UNLESS
        // B's intro is instrumental, in which case A's tail vocals fall on B's
        // intro section and can't clash. The Bricksquad → MAMA'S case in v6 had
        // its fade chopped from ~5s to 2.7s by this reduction even though MAMA'S
        // opens with a long instrumental intro, forcing a violent CUT.
        if let current = currentAnalysis, current.hasError != true {
            let aOutroVocal = current.hasOutroVocals
                || (!current.hasOutroData && (current.vocalStartTime ?? 0) > 0)
            if aOutroVocal && fadeDuration > 4 {
                let bIntroInstrumental: Bool = {
                    guard let nxt = nextAnalysis, nxt.hasError != true else { return false }
                    if nxt.hasVocalData && !nxt.hasIntroVocals { return true }
                    if let vs = nxt.vocalStartTime, vs > 4 { return true }
                    return false
                }()
                if bIntroInstrumental {
                    decision += " Outro vocal A pero intro B instrumental — sin reduccion."
                } else {
                    fadeDuration = max(3, fadeDuration * 0.80)
                    decision += " Reducido 20% por outro vocal A a \(String(format: "%.1f", fadeDuration))s."
                }
            }
        }

        // Absolute max: 25% of the shorter track
        let absoluteMax = min(bufferADuration * 0.25, bufferBDuration * 0.25)
        if fadeDuration > absoluteMax {
            fadeDuration = max(2, absoluteMax)
            decision += " Acortado por limite 25% a \(String(format: "%.2f", fadeDuration))s."
        }

        // Cap to B's available audio after entry point
        let bAvailable = bufferBDuration - entryPoint - 2.0
        if bAvailable > 0 && fadeDuration > bAvailable {
            fadeDuration = max(2, bAvailable)
            decision += " Acortado por B corta (disponible: \(String(format: "%.1f", bAvailable + 2))s) a \(String(format: "%.2f", fadeDuration))s."
        }

        // Cap final por punch B: si entryPoint marca un punto musical concreto
        // (chorus, vocalStart, energyBoost), fadeDuration no debe pasarse de él
        // con margen, o el punch queda enterrado bajo B aún subiendo volumen.
        // Aplicado después de todos los modificadores (introCap, outroLen,
        // minimal, reducción 20% outro vocal) porque cualquiera de ellos puede
        // inflar el valor sobre el cap pre-modulaciones del calculo principal.
        if entryPoint > 0 && fadeDuration > entryPoint / 1.1 {
            let punchSafeCap = max(2, entryPoint / 1.1)
            fadeDuration = punchSafeCap
            decision += " Cap final por punch B (entry=\(String(format: "%.1f", entryPoint))s) a \(String(format: "%.2f", fadeDuration))s."
        }

        return FadeDurationResult(duration: max(2, fadeDuration), decision: decision)
    }

    // MARK: - Filter Decision

    struct FilterDecisionResult {
        let useFilters: Bool
        let useAggressiveFilters: Bool
        let energyDiff: Double
        let bpmDiff: Double
        let reason: String
    }

    /// Filter decision — driven by profile. No more re-deriving energy/BPM/vocal data.
    static func decideFilterUsage(
        profile: TransitionProfile,
        fadeDuration: Double
    ) -> FilterDecisionResult {
        let hasVocals = profile.aHasOutroVocals || profile.bHasIntroVocals
        let isVeryShort = fadeDuration < 3
        let isShort = fadeDuration < 4

        // v15: umbral energyGap bajado 0.30 → 0.20. El umbral anterior dejaba
        // sin anticipación de filtros transiciones con asimetría energética
        // perceptual 0.20-0.30 (síntoma: A mantiene energía, B entra muy baja),
        // común en catálogo Hip-Hop / R&B. El nuevo umbral cubre esa franja
        // sin introducir filtros en transiciones que estaban funcionando bien.
        let useFilters = hasVocals ||
            abs(profile.energyGap) > 0.20 ||
            profile.bpmDiff > 20 ||
            profile.harmonic.isClash ||
            profile.bassConflictRisk ||
            isVeryShort

        // useAggressive endurecido (audit v8, 2026-05-04): el flag hasVocals
        // se cumple en ~80% del catalogo pop/hip-hop/R&B (cualquier voz en
        // outroA o introB). Eso enviaba a aggressive (notch + dynamicQ +
        // bassKill + midScoop + hpB 800Hz + lsB -12dB) a la mitad de las
        // transiciones de Mix Relajante, donde un blend gentle hubiera sido
        // mas musical. Ahora hasVocals solo dispara aggressive si AMBAS
        // pistas tienen energia suficiente para sostener la densidad
        // espectral (>0.20). Resto de triggers (clash, vocal-overlap,
        // bassConflict, isVeryShort) quedan como antes — son razones de
        // seguridad. Quitamos isShort (<4s) como trigger general porque
        // disparaba aggressive en demasiadas transiciones medianas; isVeryShort
        // (<3s) sigue siendo defensivo.
        let useAggressive = useFilters && (
            (hasVocals && profile.energyA > 0.20 && profile.energyB > 0.20) ||
            profile.harmonic.compatibility == .clash ||
            profile.vocalOverlapRisk == .both ||
            profile.bassConflictRisk ||
            isVeryShort
        )

        var reasons: [String] = []
        if hasVocals { reasons.append("voces") }
        if abs(profile.energyGap) > 0.20 { reasons.append("energia \(Int(abs(profile.energyGap) * 100))%") }
        if profile.bpmDiff > 20 { reasons.append("BPM ±\(Int(profile.bpmDiff))") }
        if profile.harmonic.compatibility == .tense { reasons.append("tension tonal") }
        if profile.harmonic.compatibility == .clash { reasons.append("clash tonal") }
        if profile.bassConflictRisk { reasons.append("bass conflict") }
        if isVeryShort { reasons.append("fade<3s") }
        if isShort && !isVeryShort { reasons.append("fade<4s (no aggressive)") }

        let reason = useFilters ? "Filtros ON: \(reasons.joined(separator: ", "))" : "Filtros OFF: mezcla simple"

        return FilterDecisionResult(
            useFilters: useFilters, useAggressiveFilters: useAggressive,
            energyDiff: abs(profile.energyGap), bpmDiff: profile.bpmDiff, reason: reason
        )
    }

    // MARK: - DJ-Grade Filters (Mid Scoop + High-Shelf)

    struct DJFilterResult {
        let useMidScoop: Bool
        let useHighShelfCut: Bool
        let reason: String
    }

    /// Refined DJ filter decisions using actual fade zone (entry point + fade duration known).
    /// The profile provides the initial vocal assessment; this refines with precise zone info.
    static func decideDJFilters(
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        profile: TransitionProfile,
        fadeDuration: Double,
        entryPoint: Double,
        bufferADuration: Double
    ) -> DJFilterResult {
        guard currentAnalysis != nil || nextAnalysis != nil else {
            return DJFilterResult(useMidScoop: false, useHighShelfCut: false, reason: "Sin analisis")
        }

        var useMidScoop = false
        var useHighShelf = false
        var reasons: [String] = []

        // ── Mid Scoop: refine vocal overlap with actual crossfade zone ──
        if let current = currentAnalysis, let next = nextAnalysis {
            let crossfadeStartA = bufferADuration - fadeDuration
            let bOverlapEnd = entryPoint + fadeDuration

            // Detect A vocals in crossfade zone (precise)
            let aVocalsInZone: Bool
            if current.hasVocalData && current.hasOutroVocals {
                aVocalsInZone = true
            } else if current.hasVocalEndData && current.lastVocalTime > crossfadeStartA {
                aVocalsInZone = true
            } else if !current.speechSegments.isEmpty {
                aVocalsInZone = current.speechSegments.contains { $0.end > crossfadeStartA }
            } else {
                // No vocal data available — assume vocals present (safer for pop/hip-hop).
                // outroInstrumental is a separate, more reliable signal that overrides later.
                aVocalsInZone = true
            }

            // Detect B vocals in entry zone (precise)
            let bVocalsInZone: Bool
            if next.hasVocalData && next.hasIntroVocals {
                bVocalsInZone = true
            } else if !next.speechSegments.isEmpty {
                bVocalsInZone = next.speechSegments.contains { $0.start < bOverlapEnd && $0.end > entryPoint }
            } else {
                // No vocal data — assume vocals present in entry zone.
                // Most songs have vocals starting early; false positives are harmless
                // (mid scoop on instrumental just slightly reduces mids, barely noticeable).
                bVocalsInZone = true
            }

            if aVocalsInZone && bVocalsInZone {
                useMidScoop = true
                reasons.append("mid scoop: voces solapadas")
            }
        }

        // ── High-Shelf: energy-based hi-hat detection ──
        // Backend energy values are compressed (most music 0.05-0.42), so thresholds
        // must be low enough to actually trigger. Hi-hat/cymbal cleanup is subtle and
        // harmless even on false positives, so we err on the side of activating.
        if profile.energyA > 0.20 && profile.energyB > 0.15 {
            useHighShelf = true
            reasons.append("hi-shelf: energia A=\(String(format: "%.2f", profile.energyA)) B=\(String(format: "%.2f", profile.energyB))")
        }

        // v13.O.6 (F1) — gate género: el high-shelf cut quita brillo de
        // hi-hats y voces. En Hip-Hop, R&B, Reggaeton, Trap, Drill y géneros
        // derivados el hi-hat es la firma del groove — el shelf lo enturbia y
        // arruina la transición.
        //
        // Métrica de soporte (catálogo del director, v13.O.5 rated):
        //   useHighShelfCut=true mean 3.85 (N=26) vs false mean 5.43 (N=174)
        //   delta -1.58. Cobertura set: 184/200 canciones rated.
        //
        // Override: si CUALQUIERA de los dos lados (A o B) cae en el set,
        // se fuerza `useHighShelf = false`. Mejor preservar groove de ambos
        // (incluso si solo uno es del set) que recortar brillo asimétrico.
        if useHighShelf {
            let aGenres = currentAnalysis?.genres ?? []
            let bGenres = nextAnalysis?.genres ?? []
            let aHit = aGenres.contains(where: highShelfDisabledGenres.contains)
            let bHit = bGenres.contains(where: highShelfDisabledGenres.contains)
            if aHit || bHit {
                useHighShelf = false
                let side = aHit && bHit ? "A+B" : (aHit ? "A" : "B")
                reasons.append("hi-shelf OFF [genero \(side): hi-hat groove]")
            }
        }

        let reason = reasons.isEmpty ? "DJ filters OFF" : "DJ filters ON: \(reasons.joined(separator: ", "))"
        return DJFilterResult(useMidScoop: useMidScoop, useHighShelfCut: useHighShelf, reason: reason)
    }

    // v13.O.6 (F1) — set de géneros donde el high-shelf cut hace más daño
    // que beneficio. Hi-hat = firma del groove en estas familias; cortar
    // brillo en 7-8kHz enturbia la firma.
    //
    // Set verificado empíricamente contra el catálogo del director:
    // cobertura 184/200 canciones rated v13.O.5. Capitalización exacta a la
    // que viene en NavidromeSong.genres (case-sensitive).
    private static let highShelfDisabledGenres: Set<String> = [
        "Hip-Hop", "Alternative Hip-Hop", "Latin Hip-Hop", "Experimental Hip-Hop",
        "Rap", "UK Rap", "Punk Rap", "Progressive Rap", "Emo Rap",
        "Contemporary R&B", "Latin R&B", "Neo Soul", "Urban Contemporary",
        "Reggaeton", "Dancehall",
        "Trap", "Trap Music", "Latin Trap", "Emo Trap",
        "Drill", "UK Drill", "Plugg", "Grime", "Type Beat"
    ]

    // MARK: - DJ Effects Decision (Bass Kill + Dynamic Q)

    struct DJEffectsResult {
        let useBassKill: Bool
        let useDynamicQ: Bool
        /// Phaser-style narrow notch on B's band 2 (Sprint 2 — pairs with dynQ for "DJ knob ride" feel).
        let useNotchSweep: Bool
        /// Stutter Cut: 1/8-note volume gate over A's last 2 beats before a CUT.
        /// Anchored to A's nearest real beat in downbeatTimesA so the chops align
        /// with the actual rhythmic grid. Strict gates protect against out-of-phase
        /// stuttering that would sound like a glitch instead of a DJ chop.
        let useStutterCut: Bool
        let reason: String
    }

    /// Decide whether to activate DJ effects based on the transition profile.
    /// Both effects are conservative: they only activate when conditions guarantee
    /// they'll sound good and won't interfere with the transition quality.
    static func decideDJEffects(
        profile: TransitionProfile,
        transitionType: TransitionType,
        fadeDuration: Double,
        isEnergyDown: Bool,
        needsAnticipation: Bool = false,
        skipBFilters: Bool = false,
        /// True when A has a non-empty beat grid that the executor can anchor to.
        /// Without this, Stutter Cut would chop blindly relative to wall-clock and
        /// land off-grid — sounding like a glitch rather than a DJ chop.
        hasBeatGridA: Bool = false,
        /// audit v8 sesion 4: contexto chill detectado en seccion 8e. Suprime
        /// dynamicQ / notchSweep / bassKill / stutterCut (todos los efectos que
        /// se MUEVEN — sweeps, automatizaciones, gates ritmicos). Los presets
        /// estaticos de filtro (lowshelf, highpass fijo) siguen vivos.
        isChillContext: Bool = false
    ) -> DJEffectsResult {
        var useBassKill = false
        var useDynamicQ = false
        var useNotchSweep = false
        var useStutterCut = false
        var reasons: [String] = []

        // ── Bass Kill: instant low-frequency cut at bassSwapTime ──
        // Requirements:
        //   1. Transition character is punch or dramatic-up (groove-driven, intentional)
        //   2. BPM is trusted (so bassSwapTime is accurate)
        //   3. Danceability > 0.5 (bass-driven music benefits from the kill)
        //   4. Not a CUT/NATURAL_BLEND (too short or too invisible)
        //   5. Fade is long enough for the effect to register (>4s)
        let bassKillCompatibleType: Bool
        switch transitionType {
        case .eqMix, .beatMatchBlend, .crossfade, .cutAFadeInB, .fadeOutACutB:
            bassKillCompatibleType = true
        case .cut, .naturalBlend, .cleanHandoff, .stemMix, .dropMix, .vinylStop, .sequential:
            // CLEAN_HANDOFF: A and B never overlap, no bass conflict to manage.
            // SEQUENTIAL: 50ms solape, A toca natural — sin bass kill posible.
            // STEM_MIX: the stem swap IS the moment — A drops to stems, B enters
            //   on vocals/mids. Adding a hard bass kill on top muddies the
            //   intentional bass-less holding pattern of stem mix.
            // DROP_MIX: a 2–7s drop already runs an aggressive HPF ramp on A
            //   (600 → 6000Hz) and gradual bass swap. Adding bass kill on top
            //   creates 3 effects fighting in <4 seconds — feels rushed and busy.
            //   Trust the preset to do the work.
            // CUT: too short to register a kill musically.
            // NATURAL_BLEND: deliberately invisible, no DJ-y moments.
            // VINYL_STOP / ECHO_OUT: own gesture is the effect — no extra DJ tricks.
            bassKillCompatibleType = false
        }

        // Both sides need bass content: bassKill exists to prevent "double-bombo"
        // when both tracks have a kicking low-end at the same time. From Florida
        // With Love (energyA=0.06) → Ghost Town (energyB=0.14) had bassKill on
        // and B entering with a -8 dB shelf — neither side had enough bass for
        // the kill to make sense. The user heard it as "B sounds telephonic".
        //
        // Gates relajados (audit v8 2026-05-04): el efecto se disparaba 0/40
        // en el log v8 a pesar de ser la prioridad #1 segun el DJ humano.
        // Bajamos thresholds para que el gesto reconocible-DJ del bass kill
        // empiece a aparecer en el set:
        //   - dance > 0.4 (de 0.5): R&B chill / pop intimo bailable
        //   - energies >= 0.10 cada (de 0.15, audit v9 2026-05-05): el log
        //     v8 sesion 4 mostro bassKill 0/32 — la mitad del set caia bajo
        //     el floor 0.15 porque backend tiene `energy` muy comprimida
        //     (rango tipico 0.05-0.30). Bajar a 0.10 cubre ~80% del log y
        //     deja fuera solo la cola muy baja (tail/decay).
        //   - aceptamos character .smooth con condicion adicional de bpm
        //     trusted Y dance >= 0.55 (proteccion: smooth+dance suele ser
        //     R&B con beat claro tipo Frank Ocean Pyramids; smooth+no-dance
        //     es ambient real, no queremos kill ahi).
        let dramaticEligible = profile.character == .dramatic && profile.energyFlow == .energyUp
        let punchEligible = profile.character == .punch
        let smoothEligible = profile.character == .smooth && profile.avgDanceability >= 0.55
        let characterEligible = punchEligible || dramaticEligible || smoothEligible
        if bassKillCompatibleType
            && profile.bpmTrusted
            && profile.avgDanceability > 0.4
            && fadeDuration > 4.0
            && profile.energyA >= 0.10 && profile.energyB >= 0.10
            && characterEligible {
            useBassKill = true
            let charLabel = punchEligible ? "punch" : (dramaticEligible ? "dramatic-up" : "smooth+dance")
            reasons.append("bassKill[\(charLabel)]: dance=\(String(format: "%.2f", profile.avgDanceability)) energyA=\(String(format: "%.2f", profile.energyA)) energyB=\(String(format: "%.2f", profile.energyB))")
        }

        // ── Dynamic Q Resonance: bell-shaped Q sweep on highpass ──
        // Requirements:
        //   1. Not energy-down (uses lowpass, not highpass)
        //   2. Fade > 4s (sweep needs time for resonance to be audible)
        //   3. Character is punch or dramatic (not minimal/smooth — those should be invisible)
        //   4. Danceability > 0.45 (filter sweeps are a club/DJ technique)
        if !isEnergyDown
            && fadeDuration > 4.0
            && profile.avgDanceability > 0.45
            && (profile.character == .punch || (profile.character == .dramatic && profile.energyFlow != .energyDown)) {
            useDynamicQ = true
            reasons.append("dynQ: dance=\(String(format: "%.2f", profile.avgDanceability)) fade=\(String(format: "%.1f", fadeDuration))s")
        }

        // ── Phaser Notch Sweep (Sprint 2): narrow parametric on B's band 2 ──
        // Pairs with Dynamic Q for the "DJ knob ride" handoff feel — A's resonance
        // peaks late while B's notch sweeps through it from below.
        // Stricter conditions than dynQ — this effect is more colorful and we only
        // want it when there's clear room and intent:
        //   1. Dynamic Q is already on (philosophical pairing — same musical context)
        //   2. B's filters are NOT skipped (the notch lives on band 2 of B)
        //   3. Fade > 5s (notch needs room to sweep musically)
        //   4. Danceability > 0.5 (it's a club/DJ technique, suits groove music)
        //   5. NOT a stem mix (the stem swap is its own dramatic moment — adding
        //      a colorful notch on top obscures the intentional vocal/mid-only
        //      character of B's entry; real DJs don't stack effects on stem moves)
        //
        // Audit v9 2026-05-05: removed !needsAnticipation gate. The gate was
        // disparando notchSweep 0/32 en el log v8 sesion 4 porque CUT siempre
        // lleva needsAnticipation=true. La preocupacion original era que la curva
        // de B en anticipacion (multi-stage hpB+lsB) "se ensucie" al stack-ear.
        // Pero notchSweep vive en band 2 (parametric), no choca matematicamente
        // con band 0 (highpass) ni band 1 (lowshelf) — son biquads independientes.
        // La curva de anticipation queda intacta; el notch añade color complementario.
        if useDynamicQ
            && !skipBFilters
            && transitionType != .stemMix
            && fadeDuration > 5.0
            && profile.avgDanceability > 0.5 {
            useNotchSweep = true
            reasons.append("notchSweep: pair with dynQ, fade=\(String(format: "%.1f", fadeDuration))s")
        }

        // ── Stutter Cut (Sprint 3): 1/8-note volume gate over A's last 2 beats ──
        // Hip-hop DJ signature — DJ Premier mixtape style. The chops MUST land on
        // A's actual beat grid, otherwise it sounds like a glitch instead of music.
        // Strict gates protect against every known failure mode:
        //   1. Only CUT-family transitions — blends already overlap, no need to chop
        //   2. bpmTrusted: untrusted BPM means the beat grid is unreliable, the
        //      stutter would be visibly out of phase
        //   3. bpmA in [80, 180]: at <80, 1/8 = >375ms (too slow, sounds half-time);
        //      at >180, 1/8 = <167ms (sounds like a buzz, not a chop)
        //   4. Danceability > 0.55: rhythmic music only — stutter on ambient/jazz
        //      kills the atmosphere
        //   5. fadeDuration >= 1.5s: need at least 2 beats at 80 BPM (1.5s) to fit
        //      the 4-cell pattern. Shorter fades skip the effect.
        //   6. hasBeatGridA: required for runtime anchor lookup. Without it the
        //      executor can't find the nearest real beat to the cut moment.
        // The executor performs an additional runtime check: it verifies the cut
        // moment is within beatInterval/4 of an actual beat. If not, the gate is
        // bypassed (graceful degradation — the CUT still happens, just no chop).
        let stutterCompatibleType = (transitionType == .cut || transitionType == .cutAFadeInB)
        // v11 (audit 2026-05-05): dance > 0.55 → > 0.50 — el threshold 0.55
        // mataba R&B/hip-hop lento (Frank Ocean, SZA en 0.45-0.55). En log v4
        // stutter disparo 0/74 con 0.55. 0.50 abre el efecto a R&B con beat
        // claro pero suave manteniendo fuera ambient/jazz puro.
        if stutterCompatibleType
            && profile.bpmTrusted
            && profile.bpmA >= 80
            && profile.bpmA <= 180
            && profile.avgDanceability > 0.50
            && fadeDuration >= 1.5
            && hasBeatGridA {
            useStutterCut = true
            reasons.append("stutter: cut@\(Int(profile.bpmA))BPM dance=\(String(format: "%.2f", profile.avgDanceability))")
        }

        // ── Energy-A floor: soften slow-modulating effects when A is low-energy ──
        // Backend energy values are compressed (most music falls 0.05–0.30), so
        // anything under 0.15 is a low-energy passage — either tail/decay (Rich Flex
        // → Earfquake at 0.04) or a quiet bridge/breakdown. notchSweep / dynQ /
        // stutterCut applied to that audio sounds artificial — a filter modulating
        // near-silence reads as "filter weirdness" rather than as DJ technique.
        // bassKill is fine (it's an instant cut, not a sweep) so we leave it intact.
        // The previous 0.10 threshold was too strict — it only covered the bottom
        // ~10% of cases, missing transitions like Rich Flex→Earfquake where energyA
        // is low-but-not-floor and the filters still felt off.
        if profile.energyA < 0.15 && (useDynamicQ || useNotchSweep || useStutterCut) {
            useDynamicQ = false
            useNotchSweep = false
            useStutterCut = false
            reasons.append("⚠️ energyA<0.15: soft (no dynQ/notch/stutter)")
        }

        // ── Chill context override (audit v8 sesion 4) ──
        // Mata TODO efecto que se mueva: bassKill (gate instantaneo en
        // bassSwapTime), dynamicQ (Q sweep en hpA), notchSweep (notch barriendo
        // en B band 2), stutterCut (gate ritmico en A). En chill ninguno de
        // estos efectos suma; al contrario, se perciben como "trucos" donde
        // no se pidio drama. DJ humano: "lo que mato es todo lo que se mueva".
        if isChillContext && (useBassKill || useDynamicQ || useNotchSweep || useStutterCut) {
            useBassKill = false
            useDynamicQ = false
            useNotchSweep = false
            useStutterCut = false
            reasons.append("🌙 chill: kill all dynamic FX")
        }

        let reason = reasons.isEmpty
            ? "DJ effects OFF"
            : "DJ effects ON: \(reasons.joined(separator: ", "))"
        print("[DJMixingService] \(reason)")
        return DJEffectsResult(useBassKill: useBassKill, useDynamicQ: useDynamicQ,
                               useNotchSweep: useNotchSweep, useStutterCut: useStutterCut,
                               reason: reason)
    }

    // MARK: - Anticipation

    struct AnticipationResult {
        let needsAnticipation: Bool
        let anticipationTime: Double
        let reason: String
        // PRE_PUNCH flag (audit v8 sesion 2): cuando B tiene intro instrumental
        // larga (>=6s) y el tipo es blendy, B suena clean varios segundos antes
        // del punch real. El llamador usa este flag para forzar skipBFilters.
        let isPrePunch: Bool
        // v13.O Commit 2 (round 2026-05-10): etiqueta interna del path que
        // disparó la anticipación. Permite distinguir "outroSlopeSteep" (caso
        // nuevo, suma a A2 widening cuando A decae natural) del resto de
        // ramas existentes (CUT-tease / PRE_PUNCH / A2 widening / noRealOutro).
        // Propagado a `TransitionRecord` para auditoría post-coche-test sin
        // re-parsear el `reason` humano. nil cuando no aplica este caso nuevo.
        let anticipationReason: String?

        init(needsAnticipation: Bool, anticipationTime: Double, reason: String, isPrePunch: Bool = false, anticipationReason: String? = nil) {
            self.needsAnticipation = needsAnticipation
            self.anticipationTime = anticipationTime
            self.reason = reason
            self.isPrePunch = isPrePunch
            self.anticipationReason = anticipationReason
        }
    }

    static func decideAnticipation(fadeDuration: Double, entryPoint: Double, transitionType: TransitionType, noRealOutro: Bool = false, transitionReason: String = "", bIntroSpace: Double = 0, vocalStartB: Double = 0, bpmA: Double = 0, bGenres: [String] = [], rmsTailCurveA: [Double]? = nil, filtersAggressivePredicted: Bool = false) -> AnticipationResult {
        // No-real-outro guard: A is in full groove until the very end, so
        // anticipation (which pre-mutes A for 2-4s before the fade starts)
        // would cut material the listener is still expecting. This is one of
        // two coordinated guards — calculateCrossfadeConfig also caps the
        // entry point so the trigger fires close to A's actual end.
        if noRealOutro {
            return AnticipationResult(needsAnticipation: false, anticipationTime: 0,
                                      reason: "Sin anticipacion: A sin outro real (groove hasta el final)")
        }

        // Safety-forced CUT (Vocal Trainwreck / Polirritmia): the goal is to
        // evade a clash, not to artistically preview B. The 4s anticipation
        // tease still arms preset=anticipation and emits filtered B at low
        // gain before the kick — perceived as "B con fade innecesario" in
        // Can I Kick It?→Munch and THE zone~→Girls Want Girls.
        // Outro-instrumental + B-abrupta CUT keeps its tease (T19 AIR FORCE
        // → Can I Kick It? 10/10 depends on this — its reason does not
        // contain these markers).
        if transitionType == .cut && (
            transitionReason.contains("Vocal Trainwreck") ||
            transitionReason.contains("Polirritmia")
        ) {
            return AnticipationResult(needsAnticipation: false, anticipationTime: 0,
                                      reason: "Sin anticipacion: CUT forzado por safety (no tease)")
        }

        let hasEnoughIntro = entryPoint >= 5

        // DROP_MIX: no anticipation — B enters clean and punchy, no teasing.
        if transitionType == .dropMix {
            return AnticipationResult(needsAnticipation: false, anticipationTime: 0,
                                      reason: "Sin anticipacion: DROP_MIX — entrada directa")
        }

        // CLEAN_HANDOFF: no anticipation — B enters from silence after a respiro,
        // there's nothing to "tease" because the whole point is sequentiality.
        if transitionType == .cleanHandoff {
            return AnticipationResult(needsAnticipation: false, anticipationTime: 0,
                                      reason: "Sin anticipacion: CLEAN_HANDOFF — entrada secuencial")
        }

        // VINYL_STOP: same as clean handoff — A's spin-down owns the moment,
        // B should NOT be teased. Teasing during a spin-down kills the drama.
        if transitionType == .vinylStop {
            return AnticipationResult(needsAnticipation: false, anticipationTime: 0,
                                      reason: "Sin anticipacion: VINYL_STOP — gesto de A primero")
        }

        // SEQUENTIAL (v13.O.6, F5a): A toca natural hasta su endTime; el tease
        // pre-mute alteraría el final natural prometido. B entra completa en el
        // solape de 50ms, no necesita lead-in.
        if transitionType == .sequential {
            return AnticipationResult(needsAnticipation: false, anticipationTime: 0,
                                      reason: "Sin anticipacion: SEQUENTIAL — A termina natural")
        }

        // CUT-specific: tease B filtered before the hard swap — this is how DJs
        // preview the next track even when BPMs are incompatible.
        if transitionType == .cut && hasEnoughIntro {
            let time = min(4.0, max(2.5, entryPoint * 0.3))
            return AnticipationResult(needsAnticipation: true, anticipationTime: time,
                                      reason: "Anticipacion CUT: tease +\(String(format: "%.1f", time))s antes del swap")
        }

        // ── PRE_PUNCH path (audit v8 sesion 2, 2026-05-04) ──
        // Cosita #1 del DJ humano + peticion del usuario: "dejamos el beat de
        // playerB sonando mientras playerA va muriendo, posicionados un poco
        // antes del punch para preparar".
        //
        // Cuando B tiene intro instrumental clara (bIntroSpace >= 6s) y el
        // tipo es blendy (crossfade / BMB / EQ), extendemos el tease para que
        // B suene clean los 4-7 segundos previos al fade real. El llamador
        // forza skipBFilters al ver isPrePunch=true → B audible desde el
        // primer instante del tease, con su beat / intro al aire mientras A
        // todavia esta sonando y bajando despacio.
        //
        // Restricciones:
        // - Requiere entryPoint >= 7 (margen suficiente para que el tease
        //   no caiga en zona pre-musical).
        // - Solo blendy types (crossfade, beatMatchBlend, eqMix). CUT, STEM,
        //   DROP, CLEAN, VINYL ya tienen sus gestos propios — no los pisamos.
        // - bIntroSpace debe ser >= 6 (intro instrumental clara, no solo
        //   "B chorus inmediato"). Esa es la senal de que B "se merece"
        //   sonar solo unos segundos.
        let prePunchEligibleType = transitionType == .crossfade
            || transitionType == .beatMatchBlend
            || transitionType == .eqMix
        if bIntroSpace >= 6 && entryPoint >= 7 && prePunchEligibleType {
            // Cap conservador (audit v8 sesion 2 review, 2026-05-04): el tease
            // entero debe quedar ANTES del primer vocal de B con 2s de margen,
            // para garantizar que B suena su intro instrumental durante todo
            // el tease y no que el "punch" del fade real caiga DESPUES del
            // primer evento vocal.
            //
            // Mecanica: B reproduce desde entryPoint. Durante el tease (X
            // segundos), B suena posiciones entryPoint..entryPoint+X. Si
            // vocalStartB es la posicion del primer vocal, queremos
            // entryPoint + X <= vocalStartB - 2  →  X <= vocalStartB - entryPoint - 2.
            //
            // Si vocalSafetyMargin < 4 (minimo prePunchTime razonable), NO
            // activamos PRE_PUNCH y caemos al path tradicional. Si vocalStartB
            // es 0/desconocido, vocalSafetyMargin es negativo → no activamos.
            let vocalSafetyMargin = vocalStartB - entryPoint - 2.0
            if vocalSafetyMargin >= 4.0 {
                let prePunchTime = min(7.0, max(4.0, min(bIntroSpace - 2.0, vocalSafetyMargin)))
                return AnticipationResult(
                    needsAnticipation: true,
                    anticipationTime: prePunchTime,
                    reason: "PRE_PUNCH: B suena clean \(String(format: "%.1f", prePunchTime))s antes (intro instr \(String(format: "%.1f", bIntroSpace))s, vocal margin \(String(format: "%.1f", vocalSafetyMargin))s)",
                    isPrePunch: true
                )
            }
        }

        // ── A2 widening (round 2026-05-09-v13-LMN) ──
        // El rango original "fade < 8 → anticipación" se extiende a "fade < 11"
        // para dar tease también a fades intermedios (validado por bench v13K
        // como GO unánime).
        //
        // Gate skip: cuando A es alto BPM (≥125, eurodance/dance-pop kick
        // four-on-the-floor) Y B es drop-driven (trap/drill/hip-hop/industrial,
        // sub 808), el widening generaba sub-conflict. Caso edge documentado:
        // Barbie (Aqua, 129 BPM) → Quevedo Bzrp (Latin Trap). Mantenemos el
        // comportamiento previo (fade < 8) en ese par.
        //
        // Default conservador (CEO 2026-05-09): si bpmA inválido o bGenres
        // vacío → NO skip (aplica A2 widening). Mainline está validado por
        // bench, el gate es la excepción defensiva.
        let bpmAValid = bpmA.isFinite && bpmA > 0
        let shouldSkipA2Widening = bpmAValid
            && bpmA >= 125.0
            && Self.isBDropDrivenBass(bGenres)
        let widenThreshold: Double = shouldSkipA2Widening ? 8.0 : 11.0

        let needs = fadeDuration < widenThreshold && hasEnoughIntro

        // ── outroSlope steep / filtros agresivos helper (v13.O Commit 2, round 2026-05-10) ──
        // Disparador del extra de anticipación. Dos triggers ortogonales:
        //   (a) outroSlopeSteep: A decae naturalmente (slope < -0.005/s sobre
        //       los últimos 40s = tailWindows=8). Damos aire a B antes del
        //       fade real porque el oyente ya percibe que A "se está yendo".
        //   (b) filtersAggressivePredicted: el llamador anticipa que se
        //       activarán bassKill / dynamicQ / notchSweep / stutterCut. Estos
        //       filtros son automatizaciones que mueven aire — entran de
        //       golpe en `filterStartTime` (que cascadea desde
        //       `anticipationTime` vía Timings). Adelantarles el rampStart
        //       ablanda la queja del director "los filtros se aplican de
        //       golpe" en pistas con groove constante (donde outroSlope no
        //       dispararía). Trigger ADITIVO al outroSlope, no sustituto.
        //
        // Suma a A2 widening (cap total 4s) o dispara solo cuando A2 NO
        // aplicó (fade largo / intro insuficiente). NO pisa noRealOutro /
        // CUT-tease / PRE_PUNCH / DROP_MIX / CLEAN / VINYL (todos retornan
        // antes de aquí). Threshold outroSlope -0.005/s y ventana de 40s
        // buscan decay sostenido, no dip puntual del último compás.
        // hasEnoughIntro gate aplica a AMBOS triggers: si entryPoint < 5
        // no hay margen físico para sumar tease sin caer en zona pre-musical.
        let outroSlopeSteepRaw: Bool = {
            guard let slope = Self.deriveSlope(from: rmsTailCurveA, tailWindows: 8) else { return false }
            // v13.O.3: bajado -0.005 → -0.003. backend-guardian confirmó que
            // rmsTailCurve cobertura backend es 100%. El 38% del trigger era
            // threshold iOS demasiado exigente para pistas con decay gradual.
            // Cobertura esperada: 38% → ~55-60%. Falsos positivos (outro vocal
            // sostenido) acotados sin lastVocalTime guard — diferido v13.O.4.
            return slope < -0.003
        }()
        let outroSlopeSteep = hasEnoughIntro && outroSlopeSteepRaw
        let filtersAggressiveExtra = hasEnoughIntro && filtersAggressivePredicted
        let extraTriggered = outroSlopeSteep || filtersAggressiveExtra
        let outroSlopeExtra: Double = extraTriggered ? min(2.0, fadeDuration * 0.3) : 0
        let extraReasonTag: String = {
            switch (outroSlopeSteep, filtersAggressiveExtra) {
            case (true, true):   return "outroSlopeSteep+filtersAggressive"
            case (true, false):  return "outroSlopeSteep"
            case (false, true):  return "filtersAggressive"
            case (false, false): return ""
            }
        }()

        if needs {
            let maxAnticipation = min(4, entryPoint * 0.3)
            let baseTime = min(maxAnticipation, max(2, 10 - fadeDuration))
            // Cap total 4s: el widening original ya acotaba a 4s. Si outroSlope
            // sumaría por encima, lo recortamos al cap para no romper el
            // contrato de la ventana A2 validada por bench.
            let totalTime = min(4.0, baseTime + outroSlopeExtra)
            let detail = shouldSkipA2Widening
                ? "fade corto, A2 gate skip (bpmA=\(String(format: "%.1f", bpmA)) drop-driven B)"
                : "fade corto"
            if outroSlopeExtra > 0 {
                return AnticipationResult(needsAnticipation: true, anticipationTime: totalTime,
                                          reason: "Anticipacion: +\(String(format: "%.1f", totalTime))s (\(detail) + \(extraReasonTag) +\(String(format: "%.1f", totalTime - baseTime))s)",
                                          anticipationReason: extraReasonTag)
            }
            return AnticipationResult(needsAnticipation: true, anticipationTime: totalTime,
                                      reason: "Anticipacion: +\(String(format: "%.1f", totalTime))s (\(detail))")
        }

        // A2 widening NO aplicó. Si outroSlope steep o filtros agresivos
        // predichos + intro suficiente, disparamos solo el extra (sin base
        // widening): A está decayendo natural o entran filtros automatizados,
        // y aún hay margen para tease. Cubre fades largos (>=11s o >=8s con
        // gate skip) que sin esto no anticipaban nada.
        if extraTriggered {
            let maxAnticipation = min(4, entryPoint * 0.3)
            let time = min(maxAnticipation, outroSlopeExtra)
            if time >= 1.0 {
                return AnticipationResult(needsAnticipation: true, anticipationTime: time,
                                          reason: "Anticipacion: +\(String(format: "%.1f", time))s (\(extraReasonTag), fade largo)",
                                          anticipationReason: extraReasonTag)
            }
        }

        if fadeDuration >= widenThreshold {
            return AnticipationResult(needsAnticipation: false, anticipationTime: 0,
                                      reason: "Sin anticipacion: fade largo")
        } else {
            return AnticipationResult(needsAnticipation: false, anticipationTime: 0,
                                      reason: "Sin anticipacion: intro insuficiente")
        }
    }

    // MARK: - Trigger Bias (outro side of the A↔B relationship)

    struct TriggerBiasResult {
        let bias: Double    // negative = earlier, positive = later, 0 = default
        let reason: String
    }

    /// Calculates how much earlier or later the crossfade should trigger on A,
    /// based on the A↔B relationship. This is the "outro" side of the profile.
    ///
    /// Default trigger = "as late as possible so fade fits before A ends".
    /// Bias shifts it: negative = start earlier (longer overlap), positive = start later (tighter).
    private static func calculateTriggerBias(
        profile: TransitionProfile,
        fadeDuration: Double
    ) -> TriggerBiasResult {
        var bias: Double = 0
        var reasons: [String] = []

        switch profile.character {
        case .minimal:
            // Both low energy — start much earlier for invisible, extended blend.
            // The listener shouldn't notice the transition at all.
            bias -= min(5, fadeDuration * 0.4)
            reasons.append("minimal: trigger \(String(format: "%.1f", abs(bias)))s antes")

        case .smooth:
            // Incompatible BPMs or low affinity — start a bit earlier.
            // More overlap time helps mask the genre/tempo jump.
            bias -= min(3, fadeDuration * 0.25)
            reasons.append("smooth: trigger \(String(format: "%.1f", abs(bias)))s antes")

        case .dramatic:
            if profile.energyFlow == .energyDown {
                // A is hot, B is chill — start earlier for graceful descent.
                // A needs time to die while B creeps in underneath.
                bias -= min(4, fadeDuration * 0.3)
                reasons.append("dramatic DOWN: trigger \(String(format: "%.1f", abs(bias)))s antes")
            } else if profile.energyFlow == .energyUp {
                // A is chill, B is hot — trigger late for maximum impact.
                // B should arrive like a surprise, not a slow build.
                bias += min(2, fadeDuration * 0.15)
                reasons.append("dramatic UP: trigger \(String(format: "%.1f", bias))s despues")
            }
            // steady + dramatic (harmonic clash): default timing, just get through it

        case .punch:
            // Compatible BPMs — default timing is fine.
            // But adjust for vocal/bass situations:
            break
        }

        // ── Bass conflict: start earlier so filters have time to separate the low end ──
        if profile.bassConflictRisk && bias > -3 {
            let bassAdj = min(2, fadeDuration * 0.15)
            bias -= bassAdj
            reasons.append("bass conflict: -\(String(format: "%.1f", bassAdj))s")
        }

        // ── Vocal overlap: if both songs have vocals, start earlier
        // so A's vocals have time to fade before B's vocals enter ──
        if profile.vocalOverlapRisk == .both && bias > -2 {
            let vocalAdj = min(2, fadeDuration * 0.2)
            bias -= vocalAdj
            reasons.append("vocal overlap: -\(String(format: "%.1f", vocalAdj))s")
        }

        // ── High style affinity: can afford slightly later trigger (they blend naturally) ──
        if profile.styleAffinity > 0.8 && profile.character == .punch {
            bias += 1.0
            reasons.append("alta afinidad: +1s")
        }

        let reason = reasons.isEmpty
            ? "Trigger bias: 0 (default)"
            : "Trigger bias: \(bias >= 0 ? "+" : "")\(String(format: "%.1f", bias))s (\(reasons.joined(separator: ", ")))"
        print("[DJMixingService] \(reason)")

        return TriggerBiasResult(bias: bias, reason: reason)
    }

    // MARK: - Transition Type

    struct TransitionTypeResult {
        let type: TransitionType
        let reason: String
    }

    /// Transition type — driven by profile relationship.
    /// The character biases the selection: punch→BEAT_MATCH, smooth→NATURAL_BLEND, etc.
    static func decideTransitionType(
        currentAnalysis: SongAnalysis?,
        nextAnalysis: SongAnalysis?,
        profile: TransitionProfile,
        entryPoint: Double,
        fadeDuration: Double,
        isBeatSynced: Bool,
        useFilters: Bool,
        bufferADuration: Double,
        hasVocalOverlap: Bool = false,
        outroInstrumental: Bool = false,
        introInstrumental: Bool = false
    ) -> TransitionTypeResult {
        // ── Abruptness detection ──
        var isAAbrupt = false
        if let current = currentAnalysis, current.hasError != true {
            if current.hasOutroData {
                isAAbrupt = current.outroStartTime >= bufferADuration - 2 && current.outroStartTime > 0
            }
        } else if currentAnalysis == nil {
            isAAbrupt = fadeDuration < 3
        }

        var isBAbrupt = false
        if let next = nextAnalysis, next.hasError != true {
            if next.hasIntroData {
                // Only consider B truly abrupt when intro is extremely short AND
                // entry point is near the start. Previously introEndTime < 2 triggered
                // too often for pop songs with quick verse entries.
                isBAbrupt = next.introEndTime < 1 && entryPoint < 2
            }
        } else if nextAnalysis == nil {
            isBAbrupt = fadeDuration < 3
        }

        // Beat-match eligibility: stricter than "mixable". A 12–18 BPM diff is
        // close enough to blend gently but too far for time-stretch (>8% rate
        // change becomes audible), and beat-grid alignment without time-stretch
        // produces unaligned kicks across the fade. So beat-match requires
        // identical or compatible (≤12 BPM diff), NOT borderline or incompatible.
        let bpmBeatMatchable = profile.bpmRelationship == .identical
            || profile.bpmRelationship == .compatible

        var type: TransitionType = .crossfade
        var reason = "Transicion normal"

        // v13.O.4 H6 — floor bajado de <3 a <2. En coche-test v13.O.3,
        // 45% de los CUTs (20/44) llevaban "Fade muy corto" — fades raw de
        // 2.0-2.9s calculados upstream que el floor convertía en CUT seco
        // y luego CrossfadeExecutor clampaba a [3,7]. Caso testigo Ps&Qs→
        // Water (raw=2.5s, r=1, comment "para qué hacer fade si literalmente
        // empezamos en el primer segundo de B"): el director NO pide más
        // fade — pide menos ceremonia. Fades 2.0-2.9 son musicalmente válidos
        // (outro corto real / entry temprano legítimo) y deben caer al
        // switch normal en lugar de degradarse a CUT.
        if fadeDuration < 2 {
            type = .cut
            reason = "Fade muy corto (raw=\(String(format: "%.1f", fadeDuration))s, ejecutado=3.0s) → CUT directo"
        }
        // ── Character-biased selection ──
        else {
            // When B was harmonic-normalized (half/double-time), surface the mapping
            // so REASON's diff matches what's in the ANALYSIS block (which prints raw).
            let bpmNote = profile.bpmBNormalized != profile.bpmB
                ? " [B \(Int(profile.bpmB))→\(Int(profile.bpmBNormalized)) half-time]"
                : ""
            switch profile.character {
            case .minimal:
                // Both low energy — gentle blend, no beat matching needed
                type = .naturalBlend
                reason = "Minimal (ambos baja energia) → NATURAL_BLEND suave"

            case .smooth:
                switch profile.bpmRelationship {
                case .incompatible:
                    let energyDrop = profile.energyA - profile.energyB
                    if outroInstrumental && introInstrumental {
                        // Both ends are instrumental — there's no rapping/voice clash to
                        // worry about, only the rhythmic mismatch. A long gentle crossfade
                        // with mid-scoop and bass cut is far better than a clean handoff
                        // here: the instrumentation can blend without sounding muddy.
                        type = .crossfade
                        reason = "BPMs incompatibles (diff=\(String(format: "%.1f", profile.bpmDiff)))\(bpmNote) pero ambos instrumentales → CROSSFADE gentle"
                    } else if outroInstrumental && !introInstrumental {
                        // Mirror → GOOD CREDIT case: A's outro decays into synths/pad while
                        // B opens hard with a kick + vocal. A long blend muddies the synth
                        // tail under the abrupt kick. A clean handoff drops to silence and
                        // the kick re-enters cold. Best human-DJ analogue: punch through
                        // with a short CUT — A's instrumental nature means there's no vocal
                        // to sever, so the cut is musically defensible.
                        type = .cut
                        reason = "Outro instrumental A + intro abrupta B (incompatible)\(bpmNote) → CUT"
                    } else if energyDrop > 0.30 && profile.energyA > 0.25
                              && !isOnCooldown(.vinylStop) {
                        // A is intense and B is markedly quieter — textbook VINYL_STOP.
                        // The spin-down punctuates the energy crash; cooldown ensures
                        // it doesn't fire on every other transition.
                        type = .vinylStop
                        reason = "BPMs incompatibles + energy drop \(String(format: "%.2f→%.2f", profile.energyA, profile.energyB))\(bpmNote) → VINYL_STOP"
                    } else {
                        // Hv5-4: CLEAN_HANDOFF retirado por dead-air audible. Caemos a
                        // NATURAL_BLEND preset Gentle (highpass sutil en A, bass cut
                        // suave, mid scoop). Equal-power + cero efectos DJ. Mejor
                        // overlap suave que silencio entre tracks incompatibles.
                        type = .naturalBlend
                        reason = "Hv5-4: CLEAN_HANDOFF retirado (incompatible BPM diff=\(String(format: "%.1f", profile.bpmDiff)))\(bpmNote) → NB Gentle"
                    }
                case .borderline:
                    // 12–18 BPM diff — too far for invisible beat-match but close enough
                    // that a thoughtful blend still works. Route to NATURAL_BLEND so we
                    // get the gentle preset (subtle highpass on A, mild bass cut, mid
                    // scoop) plus equal-power curve and zero DJ effects. The result
                    // sounds like a DJ who can't beat-grid the pair but is doing the
                    // most graceful blend possible — invisible filtering, no obvious
                    // sweeps, no resonance tricks. Avoids both the rhythmic clash of
                    // a punchy crossfade AND the dead-air of a clean handoff.
                    type = .naturalBlend
                    reason = "BPMs borderline (diff=\(String(format: "%.1f", profile.bpmDiff)))\(bpmNote) → NATURAL_BLEND sutil"
                case .identical, .compatible:
                    type = .crossfade
                    reason = "Smooth blend (afinidad=\(String(format: "%.2f", profile.styleAffinity))) → CROSSFADE"
                }

            case .dramatic:
                // Big energy change or harmonic clash
                if profile.energyFlow == .energyUp && bpmBeatMatchable && isBeatSynced {
                    // Energy rising with compatible BPMs — can do an impactful beat-matched entry
                    type = .beatMatchBlend
                    reason = "Dramatic UP + BPMs compatibles → BEAT_MATCH_BLEND (energia \(String(format: "%.2f→%.2f", profile.energyA, profile.energyB)))"
                } else if profile.energyFlow == .energyDown {
                    let energyDrop = profile.energyA - profile.energyB
                    if energyDrop > 0.35 && profile.energyA > 0.30 && !isOnCooldown(.vinylStop) {
                        // Hard energy crash — A is loud, B is whisper-quiet. A natural
                        // blend would just slowly drown A; a vinyl-stop punctuates the
                        // mood change. Cooldown prevents this firing on every drop.
                        type = .vinylStop
                        reason = "Dramatic DOWN extremo (energia \(String(format: "%.2f→%.2f", profile.energyA, profile.energyB))) → VINYL_STOP"
                    } else {
                        // Energy dropping but not a crash — gentle fade, let A die gracefully.
                        type = .naturalBlend
                        reason = "Dramatic DOWN → NATURAL_BLEND (energia \(String(format: "%.2f→%.2f", profile.energyA, profile.energyB)))"
                    }
                } else if profile.harmonic.compatibility == .clash {
                    // Harmonic clash with steady energy — crossfade (shorter, from fade duration)
                    type = .crossfade
                    reason = "Clash armonico → CROSSFADE corto"
                } else {
                    type = .crossfade
                    reason = "Dramatic steady → CROSSFADE"
                }

            case .punch:
                // ── VINYL_STOP: bass-heavy A handing off to a hard, abrupt B ──
                // Rule (DJ): the spin-down is a "look here, switch incoming" gesture
                // that only works when B re-opens with a kick. If B is slow or
                // atmospheric, the frenada queda colgando. Identical BPMs prefer a
                // clean beat-match (no need for a gesture). The cooldown prevents
                // it firing on every other transition. fadeDuration ≥ 3 because
                // CUT clamps below that and we'd be fighting the safety override.
                let bIntroLen: Double = {
                    guard let next = nextAnalysis, next.hasError != true else { return 30 }
                    return next.introEndTimeHeuristic ?? (next.hasIntroData ? next.introEndTime : 30)
                }()
                let bChorusStart: Double = {
                    guard let next = nextAnalysis, next.hasError != true else { return 30 }
                    return next.chorusStartTime > 0 ? next.chorusStartTime : 30
                }()
                let bIsAbruptIntro = !introInstrumental
                    && (bChorusStart < 3 || bIntroLen < 2)
                    && profile.energyB > 0.20
                // VINYL_STOP gates ablandados conservador (audit v8 sesion 2,
                // 2026-05-04): de 0/40 en log v8 a target ~2-4/40. Solo aqui
                // (ruta "Punch + bass-heavy"); las otras dos rutas (dramatic
                // DOWN extremo + BPMs incompatibles + energy drop) sin tocar.
                // Compensamos el threshold energy mas bajo subiendo dance:
                //   energyA > 0.25 (de 0.30): incluye R&B/hip-hop con bass
                //     claro pero no extremo
                //   dance > 0.55 (de 0.50): exigencia mayor de bailabilidad
                //     para que el gesto de frenada quede justificado
                // Cooldown intacto. bpmRelationship!=.identical intacto.
                let aIsBassHeavy = profile.energyA > 0.25 && profile.avgDanceability > 0.55
                let vinylStopFits = !isOnCooldown(.vinylStop)
                    && aIsBassHeavy
                    && bIsAbruptIntro
                    && profile.bpmRelationship != .identical
                    && fadeDuration >= 3

                // ── DROP_MIX: short intro on B or very short fade ──
                // Hip hop / R&B / K-Pop technique: quick HPF ramp out on A, B enters clean.
                // Triggers when B's intro is too short for a long blend, or the fade
                // was already capped short by the intro window.
                let useDropMix = fadeDuration < 5 || (bIntroLen < 12 && fadeDuration < 7)

                if vinylStopFits {
                    type = .vinylStop
                    reason = "Punch + bass-heavy A + B abrupta (chorus B=\(String(format: "%.0f", bChorusStart))s)\(bpmNote) → VINYL_STOP"
                }
                else if useDropMix && fadeDuration >= 2 {
                    // v13.O.3 (P2-refined-4s-bpm): DROP_MIX gate restrictivo.
                    //
                    // Coche-test v13.O.2: DROP_MIX N=17 mean 4.06 cola 41%.
                    // Quote testigo MOOO!→NotYouToo r=3: "aquí un natural
                    // blend hubiese quedado de 10". DROP_MIX se elegía por
                    // duración (fade<5 o intro<12), ciego a si A decae o B es
                    // realmente drop-driven.
                    //
                    // 3 ramas en cascada (bench v13.O.3 commit 1026926):
                    //
                    //  1. fadeDuration < 4s → DROP_MIX (gesto seco, sin gate).
                    //     El drop con fade tan corto es el gesto musical.
                    //     Preserva Berghain→Don'tStopMusic (fade=3.27s, r=9).
                    //
                    //  2. bpmDiff < 1.0 && beatSynced → DROP_MIX (BPM-guard).
                    //     Cuando 2 pistas comparten grid al milisegundo
                    //     (Psycho→BANGBANG 143.5547 BPM exacto), el corte
                    //     seco no rompe el groove. r=9 preservado.
                    //
                    //  3. Resto → si A decae (rmsTailCurve slope<-0.003) o B
                    //     NO es drop-driven percussive → plan B (BMB/NB).
                    //     Si ni A decae ni B es plano → DROP_MIX legítimo.
                    //
                    // Bench: 15 transiciones reasignadas, 0 oros r≥9 tocados,
                    // upside teórico +0.252, casos testigo confirmados.
                    let aIsDecaying: Bool = {
                        guard let curve = currentAnalysis?.rmsTailCurve else { return false }
                        guard let slope = Self.deriveSlope(from: curve, tailWindows: 6) else { return false }
                        return slope < -0.003
                    }()
                    let (bIsDropDriven, _) = Self.isBDropDrivenByPercussive(nextAnalysis?.percussiveCurve)
                    let bpmPerfectMatch = abs(profile.bpmA - profile.bpmB) < 1.0 && isBeatSynced

                    if fadeDuration < 4 {
                        type = .dropMix
                        reason = "Punch + fade muy corto (\(String(format: "%.1f", fadeDuration))s) → DROP_MIX (gesto seco)"
                    } else if bpmPerfectMatch {
                        type = .dropMix
                        reason = "Punch + BPM-grid perfecto (diff<1.0, sync) → DROP_MIX (corte seguro)"
                    } else if aIsDecaying || !bIsDropDriven {
                        type = isBeatSynced ? .beatMatchBlend : .naturalBlend
                        reason = "Plan B DROP_MIX rechazado (aDecaying=\(aIsDecaying), bDropDriven=\(bIsDropDriven)) → \(isBeatSynced ? "BEAT_MATCH_BLEND" : "NATURAL_BLEND")"
                    } else {
                        type = .dropMix
                        reason = "Punch + intro B corta (\(String(format: "%.0f", bIntroLen))s) → DROP_MIX (\(String(format: "%.1f", fadeDuration))s)"
                    }
                }
                // ── Full DJ treatment ──
                // Guard: STEM_MIX requires bpmDiff < 6. The mid-scoop and dynamic-Q
                // can hide subtle phase drift but not a 16 BPM gap — that becomes
                // audible rhythmic mud no matter how aggressive the EQ shaping.
                // Plus: energyB > 0.10 — STEM_MIX layers B over A's stem-removed
                // outro for 6-12s. When B is nearly inaudible (energyB ≤ 0.10),
                // those long overlaps read as "B fading in slowly" instead of
                // as a stem swap. New Magic Wand → Way 2 Sexy: energyB=0.03,
                // user "B entra con fade, deberia entrar perfecto sin fades".
                // Falls through to beatMatchBlend (shorter, lighter B shaping;
                // the quiet-B gate in step 8c also forces skipBFilters there).
                // Verified preserves T30 Sky→Silent Hill (energyB=0.12, 10/10)
                // and T46 No More Parties→One Beer (energyB=0.17, 10/10).
                else if isBeatSynced && !isAAbrupt && !isBAbrupt && fadeDuration >= 6
                    && hasVocalOverlap && profile.bpmDiff < 6 && profile.energyB > 0.10 {
                    type = .stemMix
                    reason = "Punch + vocales solapadas + fade≥6s → STEM_MIX (diff=\(String(format: "%.1f", profile.bpmDiff)))\(bpmNote)"
                } else if isBeatSynced && !isAAbrupt && !isBAbrupt {
                    type = .beatMatchBlend
                    reason = "Punch + beats sync (diff=\(String(format: "%.1f", profile.bpmDiff)))\(bpmNote) → BEAT_MATCH_BLEND"
                } else if isAAbrupt && isBAbrupt {
                    // v13.O.4 H6 — sincronizado con floor general <2.
                    // Antes fade<4→CUT capturaba fades de 2.0-3.9s y los
                    // degradaba. Ahora 2.0-3.9 pasan a EQ_MIX (mid-scoop
                    // permite limpiar el clash) y solo fade<2 cae a CUT.
                    if fadeDuration < 2 {
                        type = .cut
                        reason = "Ambos abruptos + fade muy corto → CUT"
                    } else {
                        type = .eqMix
                        reason = "Ambos abruptos → EQ_MIX (mid-scoop limpia clash)"
                    }
                } else if isAAbrupt && !isBAbrupt {
                    type = .cutAFadeInB
                    reason = "A abrupto, B suave → CUT_A_FADE_IN_B"
                } else if !isAAbrupt && isBAbrupt {
                    type = .fadeOutACutB
                    reason = "A suave, B abrupto → FADE_OUT_A_CUT_B"
                } else {
                    // Punch but not beat synced — still try to sound intentional
                    type = .crossfade
                    reason = "Punch sin beat sync → CROSSFADE"
                }
            }
        }

        // ── Override: B abre con voz acapella / hablada ──
        // Hv5-4: override retirado. La "presentación" via CLEAN_HANDOFF generaba
        // dead-air audible peor que el blend que reemplazaba. Dejamos que el tipo
        // previo (BMB/NB/EQ_MIX/CROSSFADE) prevalezca — el overlap suave sobre
        // intro vocal es preferible al silencio.
        // (Detección de voz-acapella conservada como no-op por si se reusa.)
        if let next = nextAnalysis, next.hasError != true,
           let vsB = next.vocalStartTime, vsB <= 1.0,
           entryPoint < 3.0,
           next.chorusStartTime > 5.0,
           type == .crossfade || type == .beatMatchBlend || type == .naturalBlend || type == .eqMix {
            reason = "\(reason) (Hv5-4: override voz-acapella retirado)"
        }

        // ── Safety: extreme BPM jump override ──
        let bpmCutThreshold: Double = useFilters ? 35 : 20
        if profile.bpmDiff > bpmCutThreshold && fadeDuration > 3 && type != .cut {
            let normalizedNote = profile.bpmBNormalized != profile.bpmB ? " (norm:\(Int(profile.bpmBNormalized)))" : ""
            // Discriminante isOutroInstrumental:
            //   outroInstrumental=True  → CUT limpio: A sale por zona sin voz,
            //     el corte seco sobre material instrumental no se percibe como error.
            //   outroInstrumental=False → cortar a A en seco con voz/drums activos
            //     suena a error. SEQUENTIAL deja a A terminar natural y B arranca
            //     desde su intro, sin overlap de grids polirrítmicos (lo que este
            //     branch evita) ni trauma de corte. NATURAL_BLEND descartado:
            //     superpondría dos grooves incompatibles, justo lo que se evita.
            // Nota: la rama CUT sigue siendo elegible al override energy-crash
            // →FADE_OUT_A_CUT_B de más abajo, igual que antes (no-cambio); la
            // rama SEQUENTIAL no lo es (su gate no incluye .sequential).
            if outroInstrumental {
                type = .cut
                reason = "Polirritmia evitada (A:\(Int(profile.bpmA)) B:\(Int(profile.bpmB))\(normalizedNote) diff=\(String(format: "%.1f", profile.bpmDiff))) outroInst → CUT forzado"
            } else {
                type = .sequential
                reason = "Polirritmia + A no instrumental (A:\(Int(profile.bpmA)) B:\(Int(profile.bpmB))\(normalizedNote) diff=\(String(format: "%.1f", profile.bpmDiff))) → SEQUENTIAL"
            }
        }

        // ── Override: energy crash A → instrumental B ──
        // Bricksquad → MAMA'S FAVORITE in v6: energyA=0.48 (kick + bass + voice)
        // crashing into MAMA'S energyB=0.22 instrumental intro. CUT or short
        // crossfade lands as a slap; the listener feels "the song slammed shut".
        // FADE_OUT_A_CUT_B with fade ≥ 5s lets A breathe out gracefully while B
        // emerges from its instrumental intro. Guard requires ≥6s of intro on B
        // so the boosted fade fits inside the instrumental window. Skip when BPM
        // is incompatible (CLEAN_HANDOFF / VINYL_STOP already handle that path)
        // or when type was already a sequential gesture.
        let bIntroSpace: Double = {
            guard let next = nextAnalysis, next.hasError != true else { return 0 }
            return next.introEndTimeHeuristic ?? (next.hasIntroData ? next.introEndTime : 0)
        }()
        if profile.energyA > 0.40 && profile.energyB < 0.25
            && introInstrumental
            && bIntroSpace >= 6
            && profile.bpmRelationship != .incompatible
            && (type == .cut || type == .crossfade || type == .naturalBlend) {
            type = .fadeOutACutB
            reason = "Energy crash A→B instrumental (\(String(format: "%.2f→%.2f", profile.energyA, profile.energyB))) → FADE_OUT_A_CUT_B"
        }

        // ── Safety: vocal trainwreck — refine with actual fade zone ──
        if let current = currentAnalysis, current.hasError != true,
           let next = nextAnalysis, next.hasError != true,
           type != .cut && type != .stemMix && type != .sequential {
            // `type != .sequential` añadido: el redirect Polirritmia→SEQUENTIAL
            // (branch de arriba cuando !outroInstrumental) NO debe ser reprocesado
            // a CUT/EQ_MIX por el trainwreck. SEQUENTIAL no tiene overlap (A
            // termina, B desde 0) → no hay colisión vocal posible. Inseparable
            // del vector anterior: mismo flujo de control.

            // vocalStart unwrap: nil → 0 (safe sentinel for arithmetic).
            // The `> 0` guard below filters both nil and the literal 0.0
            // case (vocal-at-t=0 means vocals start AT entryPoint or earlier
            // → vocalBStart ≤ 0 → bHasVocalsInFade still true via direct check).
            let vsB = next.vocalStartTime ?? 0
            let vocalBStart = vsB - entryPoint
            // bHasVocalsInFade: known vocal onset > 0 AND lands inside fade,
            // OR literal vocal-at-t=0 (vsB known to be 0 means voice from
            // file start; if entryPoint>0 we've already missed vocals so
            // they're not "in fade", but hasIntroVocals flag still flags it).
            let bHasVocalsInFade = (next.vocalStartTime ?? -1) > 0 && vocalBStart < fadeDuration
            let bIntroVocalOverlap = next.hasIntroVocals || bHasVocalsInFade

            if bIntroVocalOverlap {
                // v13.O.4 H5 — guard BPM-grid identical+synced: con BPMs
                // idénticos y beat-sync activo, el overlap vocal queda
                // absorbido por groove perfecto. El gate disparaba CUT en
                // pares mixables (caso testigo Sprinter→Fake Love, bpmDiff=0,
                // rachas de 4 CUTs seguidos coche-test v13.O.3). 21 CUTs
                // (mean rating 2.9) llevaban "Vocal Trainwreck evitado".
                let bpmGridPerfect = profile.bpmRelationship == .identical && isBeatSynced
                if bpmGridPerfect {
                    reason += " (vocal overlap absorbed: BPM-grid identical+synced)"
                } else {
                    let safeOutroA = bufferADuration - fadeDuration

                    // v13.O.4 H5 — guard outroInstrumental autoritario.
                    // `outroInstrumental` viene de detectOutroInstrumental
                    // (señal multi-source ya validada en producción desde v8).
                    // El fallback degenerado (rama else original) marcaba
                    // aHasVocalsAtEnd=true por `outroStartTime` nil/0 +
                    // vocalStart>0 — falso positivo en pistas con outro
                    // instrumental real pero outroStartTime mal poblado.
                    var aHasVocalsAtEnd = false
                    if outroInstrumental {
                        aHasVocalsAtEnd = false
                    } else if current.hasOutroVocals {
                        aHasVocalsAtEnd = true
                    } else if current.hasVocalEndData {
                        aHasVocalsAtEnd = current.lastVocalTime > safeOutroA
                    } else if !current.speechSegments.isEmpty {
                        aHasVocalsAtEnd = current.speechSegments.contains { $0.end > safeOutroA }
                    } else {
                        aHasVocalsAtEnd = (current.outroStartTime <= 0 || current.outroStartTime > safeOutroA)
                            && (current.vocalStartTime ?? 0) > 0
                    }

                    if aHasVocalsAtEnd {
                        let bInstrumentalWindow = vsB - entryPoint
                        if bInstrumentalWindow > fadeDuration * 0.6 {
                            reason += " (vocal overlap OK: B vocals after \(String(format: "%.0f", bInstrumentalWindow))s)"
                        } else if fadeDuration >= 6 && hasVocalOverlap {
                            // v13.O.4 H5 — antes de degradar a CUT, intentar
                            // EQ_MIX (mid-scoop preserva el fade separando
                            // vocales por banda). Solo viable con fade≥6s.
                            type = .eqMix
                            reason = "Vocal Trainwreck → EQ_MIX (mid-scoop preserva fade)"
                        } else {
                            type = .cut
                            reason = "Vocal Trainwreck evitado → CUT forzado"
                        }
                    }
                }
            }
        }

        // v13.O.6 (F5b) — retirar DROP_MIX y STEM_MIX del decisor → SEQUENTIAL.
        //
        // Métrica de soporte (v13.O.5 rated):
        //   DROP_MIX: N=42, mean 3.07, 0 diamonds, 71.4% cola r≤3. Tipo más
        //             dañino del dataset; patrón consistente cross-sesión.
        //   STEM_MIX: N=4, mean 4.50 (cayó desde 10.00 en v13.O.4). N pequeña
        //             pero todas las quejas coherentes — dispara filtros
        //             agresivos sin justificación musical en el catálogo del
        //             usuario.
        //
        // Redirect a SEQUENTIAL: A llega a su final natural, B arranca completo,
        // solape 50ms inaudible. Mejor cero transición que una mala.
        //
        // Patrón defensivo (igual que Hv5-4 retiró CLEAN_HANDOFF): los branches
        // residuales `case .dropMix` / `.stemMix` arriba y los switches
        // exhaustivos en el resto del codebase quedan intactos — futura
        // reintroducción posible si datos lo justifican. Esta capa solo cambia
        // el tipo final pasado al executor.
        var f5bRetiredFromForTelemetry: String? = nil
        if type == .dropMix {
            type = .sequential
            reason = "[F5b retirar DROP_MIX → SEQUENTIAL] " + reason
            f5bRetiredFromForTelemetry = "DROP_MIX"
        } else if type == .stemMix {
            type = .sequential
            reason = "[F5b retirar STEM_MIX → SEQUENTIAL] " + reason
            f5bRetiredFromForTelemetry = "STEM_MIX"
        }
        // Telemetría: paralela a sequentialOverrideByVectorD. Permite al
        // backend atribuir saturacion SEQUENTIAL al path origen (DROP_MIX vs
        // STEM_MIX) sin parsear el transitionReason.
        let f5bForCapture = f5bRetiredFromForTelemetry
        Task { @MainActor in
            TransitionDiagnostics.shared.f5bRetiredFrom = f5bForCapture
        }

        // v15: defensa CUT_A_FADE_IN_B con energyB muy baja. Cuando el tipo
        // queda en cutAFadeInB pero B viene con energy < 0.10 (intro casi
        // inaudible), el fade-in de B no tiene cuerpo que sostener — A corta
        // sin contraparte audible. Degradar a SEQUENTIAL deja que A acabe
        // natural y B arranque desde t=0 con su propio dinámica.
        var sequentialOverrideByVectorD = false
        if type == .cutAFadeInB && profile.energyB < 0.10 {
            type = .sequential
            reason = "[v15 energyB<0.10 en CUT_A_FADE_IN_B → SEQUENTIAL] " + reason
            sequentialOverrideByVectorD = true
        }
        // Telemetría: persistir SIEMPRE (true/false). La asignación se
        // autosobrescribe por transición — sin reset entre rounds — porque
        // este setter se encola al MainActor ANTES de publishDecision, y el
        // reset de publishDecision lo borraría si fuera Optional con
        // condición. Permite distinguir SEQUENTIAL orgánico (false) del
        // SEQUENTIAL escalado por defensa (true).
        let overrideAppliedForTelemetry = sequentialOverrideByVectorD
        Task { @MainActor in
            TransitionDiagnostics.shared.sequentialOverrideByVectorD = overrideAppliedForTelemetry
        }

        // Record the final type for cooldown bookkeeping. Done at the end so the
        // safety overrides above (polirritmia, vocal trainwreck) are also tracked.
        recordTransition(type)

        return TransitionTypeResult(type: type, reason: reason)
    }

    // MARK: - Time-Stretch Decision

    struct TimeStretchResult {
        let useTimeStretch: Bool
        let rateA: Float
        let rateB: Float
        let reason: String
    }

    static func decideTimeStretch(
        profile: TransitionProfile,
        transitionType: TransitionType
    ) -> TimeStretchResult {
        switch transitionType {
        case .cut, .cutAFadeInB, .fadeOutACutB, .cleanHandoff, .sequential:
            // SEQUENTIAL (v13.O.6, F5a) — A toca natural hasta su endTime; el
            // time-stretch alteraría la firma rítmica/tonal del material.
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: transicion tipo cut/handoff")
        case .vinylStop:
            // Vinyl stop OWNS the rate ramp on A (1.0 → 0). No global time-stretch
            // decision applies — the curve is driven directly by the executor.
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: rate ramp owned por VINYL_STOP")
        default: break
        }

        guard profile.bpmA > 50 && profile.bpmA < 250 &&
              profile.bpmB > 50 && profile.bpmB < 250 else {
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: BPM fuera de rango")
        }

        // Don't stretch when BPM confidence is low — stretching to a wrong BPM sounds terrible
        if !profile.bpmTrusted {
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: BPM no confiable (confidence < 0.5)")
        }

        let diff = profile.bpmDiff
        // Maximum allowed rate change — beyond this the pitch shift is audible
        let maxRateChange: Float = 0.08  // 8% — still inaudible with time-domain stretching

        if diff < 3 {
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: BPMs casi iguales (±\(String(format: "%.1f", diff)))")
        } else if diff <= 8 {
            let rateB = Float(profile.bpmA / profile.bpmBNormalized)
            if abs(rateB - 1.0) > maxRateChange {
                return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                         reason: "No stretch: rate \(String(format: "%.1f", abs(rateB - 1.0) * 100))% > 8% (audible)")
            }
            return TimeStretchResult(useTimeStretch: true, rateA: 1.0, rateB: rateB,
                                     reason: "Stretch B→A: \(Int(profile.bpmBNormalized))→\(Int(profile.bpmA)) BPM (rate=\(String(format: "%.3f", rateB)))")
        } else if diff <= 15 {
            let mid = (profile.bpmA + profile.bpmBNormalized) / 2.0
            let rateA = Float(mid / profile.bpmA)
            let rateB = Float(mid / profile.bpmBNormalized)
            if abs(rateA - 1.0) > maxRateChange || abs(rateB - 1.0) > maxRateChange {
                return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                         reason: "No stretch: rate change > 8% (A:\(String(format: "%.1f", abs(rateA - 1.0) * 100))% B:\(String(format: "%.1f", abs(rateB - 1.0) * 100))%)")
            }
            return TimeStretchResult(useTimeStretch: true, rateA: rateA, rateB: rateB,
                                     reason: "Stretch ambos→\(Int(mid)) BPM: A=\(String(format: "%.3f", rateA)) B=\(String(format: "%.3f", rateB))")
        } else {
            return TimeStretchResult(useTimeStretch: false, rateA: 1.0, rateB: 1.0,
                                     reason: "No stretch: diferencia demasiado grande (±\(Int(diff)) BPM)")
        }
    }

    // MARK: - v13.D: Derivacion frontend de pendientes perceptuales

    /// v13.D (audit 2026-05-06): umbrales tentativos del DJ-engineer para Tier 4-lite.
    /// Calibrar contra log post-coche-test antes de ajustar. Vienen del analisis
    /// musical: +0.015/seg ≈ +0.30 sobre 20s de intro (build perceptible no exagerado);
    /// 0.45 dbs/bar ≈ 1.8 downbeats por compas 4/4 (percu marcando con consistencia).
    private static let kIntroSlopeMinPerSecond: Double = 0.015
    private static let kDownbeatDensityMinPerBar: Double = 0.45

    /// Calcula la pendiente (regresion lineal) de los primeros `headWindows` o
    /// ultimos `tailWindows` elementos de una curva RMS normalizada 0-1.
    /// Las curvas del backend usan ventanas de 5s, por lo que el resultado se
    /// devuelve en unidades por segundo (slope-por-window dividido por 5).
    /// Retorna nil si la curva es nil o tiene menos elementos que la ventana pedida.
    /// Publico (no private) para que QueueManager pueda derivar slopes cuando
    /// el backend no provee EnergyProfile.introSlope/outroSlope.
    static func deriveSlope(from curve: [Double]?, headWindows: Int? = nil, tailWindows: Int? = nil) -> Double? {
        guard let curve = curve else { return nil }
        let windows: ArraySlice<Double>
        if let n = headWindows {
            guard curve.count >= n, n >= 2 else { return nil }
            windows = curve.prefix(n)
        } else if let n = tailWindows {
            guard curve.count >= n, n >= 2 else { return nil }
            windows = curve.suffix(n)
        } else {
            return nil
        }
        let n = Double(windows.count)
        let xs = (0..<windows.count).map { Double($0) }
        let ys = Array(windows)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).map { $0 * $1 }.reduce(0, +)
        let sumX2 = xs.map { $0 * $0 }.reduce(0, +)
        let denom = n * sumX2 - sumX * sumX
        guard denom != 0 else { return nil }
        let slopePerWindow = (n * sumXY - sumX * sumY) / denom
        return slopePerWindow / 5.0  // 5s por window → unidades/segundo
    }

    /// Densidad de downbeats por compas en la ventana [0, hasta) de B.
    /// Devuelve nil si no hay suficientes downbeats o barDur invalido.
    private static func downbeatDensity(downbeats: [Double], barDur: Double, hasta: Double) -> Double? {
        guard barDur > 0, hasta > 0 else { return nil }
        let inWindow = downbeats.filter { $0 >= 0 && $0 < hasta }.count
        let bars = hasta / barDur
        guard bars > 0 else { return nil }
        return Double(inWindow) / bars
    }

    // MARK: - Tier 4: Adelantar entryPoint al primer kick de la intro de B

    /// Computa un entryPoint adelantado cuando el setup es claro: A en outro
    /// instrumental confiable + B con intro instrumental real con kick + percu.
    /// Retorna nil si cualquier gate falla — fallback al entry original.
    ///
    /// Heuristica revisada por architect (delta de downbeats vs bi*4, paridad
    /// anclada al evento musical) y backend validator (gates contra half-time
    /// franja 140-180, structure rota, vocalStart=0 literal, energy=0 espurio).
    /// DJ profesional confirmo escalado por BPM: 6 compases <90 BPM, 8 90-130,
    /// 10 >130 BPM. Curva `earlyBlend` se activa via flag `tier4Active` en Config.
    private static func computeTier4Entry(
        safeCurrent: SongAnalysis?,
        safeNext: SongAnalysis?,
        profile: TransitionProfile,
        bufferADuration: Double,
        bufferBDuration: Double,
        fadeDuration: Double,
        originalEntry: Double,
        transitionType: TransitionType,
        telemetry: inout Tier4Telemetry
    ) -> (entry: Double, reason: String)? {
        guard kEnableTier4 else { telemetry.failedGate = .disabled; return nil }

        // ── Gate 1: tipo blendy compatible ──
        switch transitionType {
        case .crossfade, .eqMix, .beatMatchBlend:
            break
        default:
            telemetry.failedGate = .typeIncompat
            return nil
        }

        // ── Gate 2: fade ≥ 4s (necesita espacio para que B acompane a A) ──
        guard fadeDuration >= 4.0 else { telemetry.failedGate = .fadeShort; return nil }

        // ── Gate 3: A confiable + outro instrumental (outroInstrumentalConfident) ──
        guard let cur = safeCurrent, cur.hasError != true else { telemetry.failedGate = .aMissing; return nil }
        guard cur.hasVocalEndData else { telemetry.failedGate = .noVocalEndData; return nil }
        let crossfadeStartA = bufferADuration - fadeDuration
        guard (crossfadeStartA - cur.lastVocalTime) >= 2.0 else { telemetry.failedGate = .outroVocal; return nil }

        // ── Gate 4: B confiable ──
        guard let next = safeNext, next.hasError != true else { telemetry.failedGate = .bMissing; return nil }

        // ── Gate 5: BPMs trusted + ambos fuera de franja toxica 140-180 ──
        // (backend validator: half-time bug afecta esa franja silenciosamente)
        guard profile.bpmTrusted else { telemetry.failedGate = .bpmUntrusted; return nil }
        let bpmAToxic = profile.bpmA >= 140 && profile.bpmA <= 180
        let bpmBToxic = profile.bpmB >= 140 && profile.bpmB <= 180
        guard !bpmAToxic, !bpmBToxic else { telemetry.failedGate = .bpmToxic; return nil }

        // ── Compute barDur from downbeat deltas (mediana, robusto a no-4/4) ──
        // (Movido antes del gate 5.5 por v13.D: el camino B necesita barDur.)
        let downbeats = next.downbeatTimes
        guard downbeats.count >= 2 else { telemetry.failedGate = .noDownbeats; return nil }
        var deltas: [Double] = []
        for i in 1..<min(downbeats.count, 8) {
            deltas.append(downbeats[i] - downbeats[i-1])
        }
        let sortedDeltas = deltas.sorted()
        let medianDelta = sortedDeltas[sortedDeltas.count / 2]
        guard medianDelta >= 1.0, medianDelta <= 4.0 else { telemetry.failedGate = .invalidBarDur; return nil }
        let barDur = medianDelta

        // v13.K (audit 2026-05-07): persistir telemetría perceptual incluso si
        // los gates posteriores cortan. Permite ver la distribución real de
        // introSlope y downbeatDensity en pistas del usuario sin reinstrumentar.
        telemetry.introSlopeB = next.introSlope
        telemetry.downbeatDensityB20s = downbeatDensity(downbeats: downbeats, barDur: barDur, hasta: 20.0)

        // ── Gate 5.5 (v13.D, audit 2026-05-06): perceptual energy gate ──
        // Reemplaza el guard unico `energyB >= 0.30` (v13.A) por OR-de-3-caminos.
        // Causa raiz: `energy` viene promediado track-wide, mata hip-hop con intro
        // instrumental real (Tier 4 = 0/51 fires en log v13.H.1 sobre 51 transiciones).
        //   A: introSlope >= +0.015/seg → build perceptual claro.
        //   B: introSlope >= 0 + density downbeats >= 0.45/bar → loop estable.
        //   C: legacy energyB >= 0.30 → fallback para pistas sin curvas pobladas.
        // Caso Too Young→FML preservado: introSlope ≈ 0 + density baja + energy 0.14
        // → 3 caminos fallan, Tier 4 NO activa (mismo guard que pre-v13.D).
        // Densidad: contar downbeats en [0, 20s) — intro hip-hop tipica ≈ 4-5 bars.
        let pathA = (next.introSlope ?? -.infinity) >= kIntroSlopeMinPerSecond
        let pathB: Bool = {
            guard (next.introSlope ?? -.infinity) >= 0 else { return false }
            guard let dens = telemetry.downbeatDensityB20s else { return false }
            return dens >= kDownbeatDensityMinPerBar
        }()
        let pathC = profile.energyB >= 0.30
        guard pathA || pathB || pathC else { telemetry.failedGate = .perceptual; return nil }

        // ── Gate 6: structure intacta — chorusStart>5 (defensa "0.1s literal") ──
        let chorusStart = next.chorusStartTime
        let chorusValid = chorusStart > 5.0

        // ── Gate 7: vocalStart>0 (descarta nil/literal t=0) ──
        guard let vocalStart = next.vocalStartTime, vocalStart > 0 else { telemetry.failedGate = .vocalStart; return nil }

        // ── Gate 8: vocalStart > introEnd + 4 compases (intro real >=4 bars) ──
        let introEnd = next.introEndTimeHeuristic ?? (next.hasIntroData ? next.introEndTime : 0)
        guard introEnd > 0 else { telemetry.failedGate = .noIntroEnd; return nil }
        guard vocalStart > introEnd + 4 * barDur else { telemetry.failedGate = .introBarsShort; return nil }

        let firstEventB = min(vocalStart, chorusValid ? chorusStart : .infinity)
        guard firstEventB.isFinite else { telemetry.failedGate = .noFirstEvent; return nil }
        // ── Gate 9: structure no rota — introEnd + 12bar < firstEventB ──
        // (defensa contra 37.5% de tracks v8 con chorusStart < introEnd)
        guard introEnd + 12 * barDur < firstEventB else { telemetry.failedGate = .structureCollision; return nil }

        // ── Gate 10: clash armonico < 0.7 (sin choque tonal duro) ──
        guard profile.harmonic.compatibility != .clash else { telemetry.failedGate = .clash; return nil }

        // ── Compute target con barsAhead escalado por ventana (v13.A) ──
        // v11.1: constante 6 (BPM-monotonico). v13.A (audit 2026-05-06):
        // cuando fadeDuration es grande (>8s), ventana audible de B antes
        // del punch puede pasar de 12s. Con barsAhead=6 fijo, el clamp puede
        // dejar a B sonando en zona pre-bar-(-6) que no es la intro real.
        // Escalar a 8 cuando fade>8s para que el target caiga mas cerca del
        // primer kick. Caso Too Young→FML fade=8.5s + anticipation=7s eran
        // 15.5s de ventana — barsAhead=6 dejaba ~8s en zona "pre-intro".
        // Ademas relajamos lowerBound de -10*barDur a -12*barDur para que
        // intros largas (>20s) no perdiesen Tier 4 silenciosamente.
        let bpmB = profile.bpmB
        let barsAhead: Double = fadeDuration > 8.0 ? 8 : 6
        let lowerBound = max(introEnd + 4 * barDur, firstEventB - 12 * barDur)
        let upperBound = firstEventB - 4 * barDur
        // Sanity: rango valido. Si la intro es muy corta o esta mal detectada,
        // lowerBound puede igualar/superar upperBound — sin rango no hay snap.
        guard lowerBound < upperBound else { telemetry.failedGate = .rangeInvalid; return nil }
        // Target ideal = barsAhead bars antes del firstEventB. Clamp al rango
        // para evitar fallo silencioso cuando intros largas empujan target
        // antes de lowerBound (bug v11.0: ~30% de candidatos se perdian asi).
        let targetIdeal = firstEventB - barsAhead * barDur
        let target = min(max(targetIdeal, lowerBound), upperBound)

        // ── Snap a downbeat mas cercano a target, paridad anclada al evento musical ──
        let candidates = downbeats.filter { db in
            guard db >= lowerBound, db <= upperBound else { return false }
            let barsFromFirstEvent = (firstEventB - db) / barDur
            let nearestBars = barsFromFirstEvent.rounded()
            guard Int(nearestBars) % 2 == 0 else { return false }
            return abs(barsFromFirstEvent - nearestBars) < 0.25
        }
        guard !candidates.isEmpty else { telemetry.failedGate = .noCandidates; return nil }
        let bestCandidate = candidates.min { abs($0 - target) < abs($1 - target) }!

        // Sanity: nuevo entry debe ser estrictamente menor que el original
        guard bestCandidate < originalEntry - 1.0 else { telemetry.failedGate = .notImproving; return nil }

        let reason = "Tier4: BPM=\(Int(bpmB)) bars=\(Int(barsAhead)) entry: \(String(format: "%.1f", originalEntry))→\(String(format: "%.1f", bestCandidate))s"
        return (entry: bestCandidate, reason: reason)
    }

    // MARK: - Instrumental Detection (refined with actual fade zone)

    /// Detect if A's outro is instrumental in the actual crossfade zone.
    private static func detectOutroInstrumental(
        currentAnalysis: SongAnalysis?,
        profile: TransitionProfile,
        bufferADuration: Double,
        fadeDuration: Double
    ) -> Bool {
        guard let cur = currentAnalysis, cur.hasError != true else { return false }
        let crossfadeStartA = bufferADuration - fadeDuration

        // ── Fake-outro guard ──
        // Trap and conscious hip-hop frequently have a *false outro* — energy dips
        // for 4-8 bars, then a final verse / ad-lib comes back. The backend's
        // hasOutroVocals can lie when the model trained on song-level features.
        // If we have hard evidence of vocals in the last 4 seconds, override to
        // not-instrumental regardless of any other signal. The 4s window is
        // independent of fadeDuration so a long fade (15s) doesn't mask a late
        // vocal that lands inside the perceptual "outro" of the song.
        // Skip for songs shorter than 4s (impossible for real music tracks but
        // defensive against malformed bufferADuration); negative last4sStart
        // would make any positive lastVocalTime trigger the override.
        if bufferADuration >= 4.0 {
            let last4sStart = bufferADuration - 4.0
            if cur.hasVocalEndData && cur.lastVocalTime > last4sStart {
                return false
            }
            if !cur.speechSegments.isEmpty
                && cur.speechSegments.contains(where: { $0.end > last4sStart }) {
                return false
            }
        }

        if cur.hasVocalEndData {
            return cur.lastVocalTime < crossfadeStartA
        } else if cur.hasVocalData && !cur.hasOutroVocals && cur.hasEnergyProfile {
            if !cur.speechSegments.isEmpty {
                let vocalsInOutro = cur.speechSegments.contains { $0.end > crossfadeStartA }
                if vocalsInOutro {
                    print("[DJMixingService] ⚠️ Backend says no outro vocals, but speechSegments disagree")
                }
                return !vocalsInOutro
            }
            return true
        }
        return false
    }

    /// Detect if B's intro is instrumental in the actual entry/fade zone.
    /// Uses the same vocal-aware reference as entry point calculation:
    /// vocalStartTime → speechSegments[0] → backend flags.
    private static func detectIntroInstrumental(
        nextAnalysis: SongAnalysis?,
        profile: TransitionProfile,
        entryPoint: Double,
        fadeDuration: Double
    ) -> Bool {
        guard let nxt = nextAnalysis, nxt.hasError != true else { return false }
        let bEnd = entryPoint + fadeDuration

        // NOTE on vocalStartTime == 0.0 literal semantics (post-backend
        // 2026-05-01): backend confirms 0.0 is "vocal at t=0", but until the
        // backfill batch completes, cached entries written under the old
        // pipeline still have 0.0 as a camouflaged null. Treating 0.0 as
        // literal "no instrumental window" right now would mis-flag tracks
        // like Wu-Tang Forever (real instrumental intro ~50s) cached pre-fix.
        // Once the backfill is done and caches refreshed, swap the chain
        // below to: `if vocalStartTime == 0.0 { return false }` first.

        // Vocal onset: when B's vocals actually start
        let vocalOnset: Double = {
            if let vs = nxt.vocalStartTime, vs > 0 { return vs }
            if let first = nxt.speechSegments.first, first.start > 0 { return first.start }
            return 0
        }()

        if vocalOnset > 0 {
            if vocalOnset <= bEnd {
                if nxt.hasVocalData && !nxt.hasIntroVocals {
                    print("[DJMixingService] ⚠️ Backend says no intro vocals, but vocalOnset (\(String(format: "%.1f", vocalOnset))s) is within fade zone")
                }
                return false
            }
            return true
        }

        // No vocal timing data — fall back to backend flags
        if nxt.hasVocalData && nxt.hasEnergyProfile && !nxt.hasIntroVocals {
            return true
        }
        return false
    }

    // MARK: - CUT entry snap to downbeat

    /// Snap `entry` to a clean musical landmark when the transition is CUT-family
    /// and `next.chorusStartTime` is reachable. Without this, CUT can land in a
    /// "dead zone" — typically 0.1–2.5s before the chorus drop — which sounds
    /// like the cut fired half a beat early ("sosa", per the user's listening on
    /// Stir Fry → Vamp Anthem; "qué ha sido eso?" en Paint the Town Red →
    /// Midnight Tokyo donde entry=46.9s y chorusStart=47.1s).
    ///
    /// Strategy:
    ///   - **Inside dead zone** (entry ∈ (chorusStart − 2.5s, chorusStart − 0.05s)):
    ///     default to BACKWARD (−1 bar). Land AT chorus only when keys are
    ///     compatible (`harmonicClashLevel < 0.3`) AND backward shift ≥ 2.0s.
    ///     DJ humano: "0.1s ya es audible como 'llegué tarde'; un cut seco con
    ///     keys que chocan es el peor escenario — más seguro respirar 1-2 bars".
    ///   - **Outside dead zone** (entry ≤ chorusStart − 2.5s): minimal-shift
    ///     forward, picking among (chorus, −1 bar, −2 bars) the one closest to
    ///     entry that's at least entry + 0.5s away.
    ///
    /// `harmonicClashLevel` ∈ [0, 1] from `profile.harmonic.compatibility`
    /// (compatible=0.0, acceptable=0.3, tense=0.6, clash=1.0). Reusable param
    /// shared with the v8 B→A flag #4 — same conversion in caller.
    ///
    /// Snap to actual downbeat if `downbeatTimes` are available within 0.3s of
    /// the chosen candidate (real grid > theoretical bar).
    ///
    /// No-op for non-cut transitions, missing analysis, original entry already
    /// at/past chorus, or original entry more than 2 bars before chorus (the
    /// user's deliberate "early CUT" intent must be respected). Reggaeton
    /// (STEM_MIX / BEAT_MATCH_BLEND) never reaches this path.
    private static func snapCutEntryToDownbeat(
        entry: Double,
        transitionType: TransitionType,
        next: SongAnalysis?,
        bufferBDuration: Double,
        fadeDuration: Double,
        harmonicClashLevel: Double = 0.0
    ) -> (entry: Double, snapped: Bool, info: String) {
        guard transitionType == .cut || transitionType == .cutAFadeInB else {
            return (entry, false, "")
        }
        guard let next = next, next.hasError != true else { return (entry, false, "") }
        guard next.chorusStartTime > 0.5 else { return (entry, false, "") }

        let chorusStart = next.chorusStartTime
        // Already AT/past chorus (essentially landed on it): don't move.
        // 0.05s threshold (was 0.3s pre-v8.6) — anything between 0.05 and 2.5s
        // before chorus is now treated as "dead zone" and gets snapped.
        if entry >= chorusStart - 0.05 { return (entry, false, "") }

        let beatInterval = next.beatInterval > 0 ? next.beatInterval : 0.5
        let bar = beatInterval * 4

        // Reachability guard. The DJ's rule: cutPoint ∈ {chorus, chorus−1 bar,
        // chorus−2 bars}. So the snap only makes sense when the original entry
        // is WITHIN 2 bars of chorusStart. Beyond that, the user's entry was a
        // deliberate "early CUT" (e.g. DNA → Mask Off at 12.9s vs chorus 23.6s
        // — 10.7s = ~4 bars away — the user wanted the cold cut, not chorus
        // alignment) and we must respect it.
        guard entry >= chorusStart - 2 * bar else { return (entry, false, "") }

        let maxEntry = max(0, bufferBDuration - fadeDuration - 0.5)

        // Dead zone (audit v8 sesion 4, 2026-05-05): entries en
        // (chorusStart − 2.5s, chorusStart − 0.05s) son problematicas — A
        // muere mientras chorus de B arranca sin espacio para procesar el
        // cambio. DJ humano: "0.1s ya es audible como 'llegué tarde'".
        let inDeadZone = entry > chorusStart - 2.5

        // AT-chorus permitido SOLO con tonalidades compatibles puras (clash
        // < 0.3). Tense (0.6) o clash (1.0) → cut seco ON the punch sona
        // peor que esperar 1 bar.
        let allowAtChorus = harmonicClashLevel < 0.3

        // Build candidates with explicit labels for tie-breaking and logging.
        let rawCandidates: [(value: Double, label: String)] = [
            (chorusStart - bar,      "−1 bar"),
            (chorusStart - 2 * bar,  "−2 bars"),
            (chorusStart,            "AT chorus")
        ]
        let candidates = rawCandidates.filter { $0.value >= 0 && $0.value <= maxEntry }

        let target: (value: Double, label: String)
        if inDeadZone {
            // DJ humano explicitamente: "dentro de esa zona, la decision por
            // defecto deberia ser irse atras al compas anterior, no hacia
            // delante". Default = −1 bar (mas cercano al entry); −2 bars como
            // fallback si −1 quedara fuera de rango (raro). AT chorus solo
            // cuando backward fisicamente no existe (back1, back2 < 0 — entry
            // muy cerca del inicio de B) Y keys compatibles. La intuicion del
            // usuario en log 2026-05-05 (Best Part → Rich Baby Daddy) tambien
            // apunta a "podria haber llegado mucho antes del punch" — backward
            // alinea con preferencia del usuario incluso con keys compatibles.
            let back1 = candidates.first(where: { $0.label == "−1 bar"  })
            let back2 = candidates.first(where: { $0.label == "−2 bars" })
            let atCh  = candidates.first(where: { $0.label == "AT chorus" })

            if let back = back1 ?? back2 {
                target = back
            } else if let fwd = atCh, allowAtChorus {
                // Backward physically unavailable (negative) — fall back to AT
                // chorus only with compatible keys. With clash this is unsafe.
                target = fwd
            } else {
                return (entry, false, "")
            }
        } else {
            // Outside dead zone: minimum-shift forward (original behavior),
            // respecting "≥ entry + 0.5" floor to avoid trivial snaps. AT
            // chorus excluido si keys chocan (mismo principio que dead zone).
            let viable = candidates
                .filter { $0.value >= entry + 0.5 }
                .filter { allowAtChorus || $0.label != "AT chorus" }
            guard let best = viable.min(by: {
                abs($0.value - entry) < abs($1.value - entry)
            }) else { return (entry, false, "") }
            target = best
        }

        // Snap to actual downbeat if available within 0.3s.
        let snapped: Double
        if !next.downbeatTimes.isEmpty,
           let nearest = next.downbeatTimes.min(by: { abs($0 - target.value) < abs($1 - target.value) }),
           abs(nearest - target.value) < 0.3 {
            snapped = nearest
        } else {
            snapped = target.value
        }

        let zoneTag = inDeadZone ? " [dead-zone]" : ""
        let clashTag = (!allowAtChorus && target.label != "AT chorus") ? " [clash:no-AT]" : ""
        let info = "CUT snap \(String(format: "%.1f", entry))s → \(String(format: "%.1f", snapped))s (\(target.label) of chorus@\(String(format: "%.1f", chorusStart))s)\(zoneTag)\(clashTag)"
        return (snapped, true, info)
    }

    // MARK: - Harmonic BPM Normalization

    static func harmonicBPM(_ bpmA: Double, _ bpmB: Double) -> Double {
        guard bpmA > 0 && bpmB > 0 else { return bpmB }
        // Only half-time and double-time are musically valid for beat matching.
        // Ratios like 3:2 (e.g., 80→120) create false compatibles that require
        // extreme time-stretch (>10%) and sound terrible in practice.
        let ratios: [Double] = [0.5, 1.0, 2.0]
        let bestRatio = ratios.min(by: {
            abs(bpmB * $0 - bpmA) < abs(bpmB * $1 - bpmA)
        }) ?? 1.0
        let adjusted = bpmB * bestRatio
        return abs(adjusted - bpmA) < abs(bpmB - bpmA) ? adjusted : bpmB
    }

    // MARK: - Harmonic Mixing (Camelot Wheel)

    enum HarmonicCompatibility: Int {
        case compatible = 0
        case acceptable = 1
        case tense = 2
        case clash = 3
    }

    struct HarmonicPenalty {
        let distance: Int
        let compatibility: HarmonicCompatibility
        var isClash: Bool { compatibility == .tense || compatibility == .clash }
    }

    static func harmonicPenalty(keyA: String?, keyB: String?) -> HarmonicPenalty {
        guard let keyA, let keyB else {
            return HarmonicPenalty(distance: 0, compatibility: .compatible)
        }

        let pattern = #"(\d+)([AB])"#
        guard let regexA = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let regexB = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let matchA = regexA.firstMatch(in: keyA, range: NSRange(keyA.startIndex..., in: keyA)),
              let matchB = regexB.firstMatch(in: keyB, range: NSRange(keyB.startIndex..., in: keyB)),
              let numRangeA = Range(matchA.range(at: 1), in: keyA),
              let letterRangeA = Range(matchA.range(at: 2), in: keyA),
              let numRangeB = Range(matchB.range(at: 1), in: keyB),
              let letterRangeB = Range(matchB.range(at: 2), in: keyB),
              let numA = Int(keyA[numRangeA]),
              let numB = Int(keyB[numRangeB])
        else {
            return HarmonicPenalty(distance: 0, compatibility: .compatible)
        }

        let letterA = keyA[letterRangeA].uppercased()
        let letterB = keyB[letterRangeB].uppercased()

        let diffNum = min(abs(numA - numB), 12 - abs(numA - numB))
        let diffLetter = letterA != letterB ? 1 : 0
        let totalDistance = diffNum + diffLetter

        let compatibility: HarmonicCompatibility
        switch totalDistance {
        case 0...1: compatibility = .compatible
        case 2:     compatibility = diffLetter == 1 ? .tense : .acceptable
        case 3:     compatibility = .tense
        default:    compatibility = .clash
        }

        return HarmonicPenalty(distance: totalDistance, compatibility: compatibility)
    }

    // MARK: - Genre gates (v13.M / v13.N)
    //
    // SHARED CONSTANT — sync con `D:\Audiorr-shared\testing\scripts\bench_a2_genre_bpm_gate.py`
    // y `bench_a1_genre_gate.py`. Si añades/quitas un género aquí, actualízalo
    // también en los dos benchs. dj-engineer mantiene esta lista.
    //
    // Match es substring case-insensitive (igual que el bench Python):
    //   "trap" ∈ "Latin Trap" → true (cubre fusion subgenres correctamente)

    /// Géneros con sub-bass / 808 que pueden chocar contra eurodance/dance kick
    /// alto BPM. Usado por v13.M (A2 anticipation skip) — caso edge Barbie→Quevedo.
    static let dropDrivenBassGenres: [String] = [
        "trap", "drill", "hip-hop", "hip hop", "industrial",
    ]

    /// Match substring case-insensitive: cualquier `g` ∈ `genres` que contenga
    /// cualquiera de los `patterns` cuenta. Si `genres` está vacío → false.
    private static func anyGenreMatches(_ genres: [String], in patterns: [String]) -> Bool {
        guard !genres.isEmpty else { return false }
        for g in genres {
            let lower = g.lowercased()
            for pat in patterns where lower.contains(pat) {
                return true
            }
        }
        return false
    }

    /// True si B tiene al menos un género en `dropDrivenBassGenres`.
    static func isBDropDrivenBass(_ genres: [String]) -> Bool {
        anyGenreMatches(genres, in: dropDrivenBassGenres)
    }

    /// Detecta build drop-driven a partir del `percussiveCurve` (HPSS percussive
    /// stem, 18 ventanas 5s sobre primeros 90s). Reemplaza al gate por género
    /// (eliminado en v13.O round 2026-05-10) que no podía distinguir balada de
    /// drop-driven dentro de etiquetas Navidrome generalistas como
    /// "Contemporary R&B" (Bruno Mars vs The Weeknd ambos en la misma etiqueta).
    ///
    /// Lógica: ratio entre la energía percusiva del intro (primeros 10s) y la
    /// del cuerpo temprano (15-30s). Un build dramatic tipo drop tiene ratio
    /// ≥ 2.0 (la percusión sube significativamente); una balada estable se
    /// queda en ratio cercano a 1.0.
    ///
    /// Default conservador: si la curva no está disponible o tiene <6 muestras,
    /// devolvemos `(false, nil)` — asumimos NO drop, el cap aplicará. El backfill
    /// rmsCurve/percussiveCurve está al 100% (verificado 2026-05-10), este caso
    /// será raro; preferimos cappear de más a cappear de menos.
    ///
    /// Devuelve: `(esDrop, ratio?)` para poder loguear el ratio cuando exista.
    /// Validación empírica (8 pistas, backend-guardian 2026-05-10):
    ///   - Kanye ALL THE LOVE  ratio=3.46 → DROP ✓
    ///   - Kendrick Money Trees ratio=3.81 → DROP ✓
    ///   - Bruno Mars Talking to the Moon ratio=1.87 → BAL ✓
    ///   - Drake In My Feelings ratio=0.90 → BAL ✓
    static func isBDropDrivenByPercussive(_ percussiveCurve: [Double]?) -> (Bool, Double?) {
        guard let pc = percussiveCurve, pc.count >= 6 else { return (false, nil) }
        let intro = (pc[0] + pc[1]) / 2.0           // primeros 10s
        let main = (pc[3] + pc[4] + pc[5]) / 3.0    // 15-30s
        let denom = max(intro, 0.01)
        let ratio = main / denom
        return (ratio >= 2.0, ratio)
    }

}
