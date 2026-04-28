// ╔══════════════════════════════════════════════════════════════════════╗
// ║   BiquadCoefficientCalculator — Audio EQ Cookbook formulas          ║
// ║   Reference: Robert Bristow-Johnson "Audio EQ Cookbook" (1998)      ║
// ║   Audiorr — Audiophile-grade music player                           ║
// ║   Copyright (c) 2025-2026 cha0sisme (github.com/cha0sisme)         ║
// ╚══════════════════════════════════════════════════════════════════════╝

import Foundation

/// Pure math functions to compute normalized biquad filter coefficients.
/// No framework dependencies — safe to call from any thread.
///
/// All formulas from the Audio EQ Cookbook by Robert Bristow-Johnson.
/// Coefficients are pre-normalized (divided by a0) for Direct Form II Transposed.
enum BiquadCoefficientCalculator {

    // MARK: - Input clamping

    /// Clamp frequency to safe range for biquad stability.
    /// Below 20Hz → effectively transparent. Above Nyquist → unstable.
    private static func clampFreq(_ freq: Float, sampleRate: Float) -> Float {
        min(max(freq, 20), sampleRate * 0.5 - 1)
    }

    /// Clamp gain to safe range to prevent coefficient overflow.
    /// ±60 dB covers any practical audio scenario.
    private static func clampGain(_ gainDB: Float) -> Float {
        min(max(gainDB, -60), 60)
    }

    /// Validate and normalize coefficients. Returns passthrough if any value is
    /// non-finite (NaN/Inf), which can happen from degenerate input combinations.
    private static func safeNormalize(b0: Float, b1: Float, b2: Float,
                                      a0: Float, a1: Float, a2: Float) -> BiquadCoefficients {
        guard a0.isFinite && a0 > 1e-10 else { return .passthrough }
        let invA0 = 1.0 / a0
        let result = BiquadCoefficients(
            b0: b0 * invA0, b1: b1 * invA0, b2: b2 * invA0,
            a1: a1 * invA0, a2: a2 * invA0
        )
        // If any coefficient went non-finite, fall back to passthrough
        guard result.b0.isFinite && result.b1.isFinite && result.b2.isFinite
              && result.a1.isFinite && result.a2.isFinite else { return .passthrough }
        return result
    }

    // MARK: - Highpass (Band 0 — normal/aggressive/gentle/stem presets)

    /// Second-order highpass filter.
    /// Attenuates frequencies below cutoff. Used for A's upward sweep
    /// (thins out the outgoing song) and B's downward sweep (opens up).
    ///
    /// - Parameters:
    ///   - frequency: Cutoff frequency in Hz
    ///   - sampleRate: Audio sample rate in Hz
    ///   - Q: Quality factor (higher = narrower resonance at cutoff)
    static func highpass(frequency: Float, sampleRate: Float, Q: Float) -> BiquadCoefficients {
        let f = clampFreq(frequency, sampleRate: sampleRate)
        let q = max(Q, 0.1)

        let w0 = 2.0 * Float.pi * f / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * q)

        let b0 = (1.0 + cosW0) / 2.0
        let b1 = -(1.0 + cosW0)
        let b2 = (1.0 + cosW0) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha

        return safeNormalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    // MARK: - Lowpass (Band 0 — energy-down preset)

    /// Second-order lowpass filter.
    /// Attenuates frequencies above cutoff. Used for energy-down transitions
    /// where A "goes dark" (sweep from 20kHz → 800Hz).
    static func lowpass(frequency: Float, sampleRate: Float, Q: Float) -> BiquadCoefficients {
        let f = clampFreq(frequency, sampleRate: sampleRate)
        let q = max(Q, 0.1)

        let w0 = 2.0 * Float.pi * f / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * q)

        let b0 = (1.0 - cosW0) / 2.0
        let b1 = 1.0 - cosW0
        let b2 = (1.0 - cosW0) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha

        return safeNormalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    // MARK: - Low Shelf (Band 1 — bass management)

    /// Second-order low shelf filter.
    /// Boosts or cuts frequencies below the shelf frequency.
    /// Used for coordinated bass swap between A and B during crossfade.
    ///
    /// - Parameters:
    ///   - frequency: Shelf frequency in Hz (typically 200Hz)
    ///   - sampleRate: Audio sample rate in Hz
    ///   - gainDB: Gain in dB (negative = cut, 0 = flat)
    ///   - S: Shelf slope (1.0 = maximally steep, 0.5 = gentle). Default 1.0.
    static func lowShelf(frequency: Float, sampleRate: Float, gainDB: Float, S: Float = 1.0) -> BiquadCoefficients {
        let gain = clampGain(gainDB)
        // Shortcut: 0 dB gain = passthrough (avoids numerical noise)
        guard abs(gain) > 0.01 else { return .passthrough }

        let f = clampFreq(frequency, sampleRate: sampleRate)
        let s = max(S, 0.1)

        let A = powf(10.0, gain / 40.0)  // = 10^(dBgain/40)
        let w0 = 2.0 * Float.pi * f / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / 2.0 * sqrt((A + 1.0 / A) * (1.0 / s - 1.0) + 2.0)
        let sqrtAalpha = 2.0 * sqrt(A) * alpha

        let b0 = A * ((A + 1.0) - (A - 1.0) * cosW0 + sqrtAalpha)
        let b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosW0)
        let b2 = A * ((A + 1.0) - (A - 1.0) * cosW0 - sqrtAalpha)
        let a0 = (A + 1.0) + (A - 1.0) * cosW0 + sqrtAalpha
        let a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosW0)
        let a2 = (A + 1.0) + (A - 1.0) * cosW0 - sqrtAalpha

        return safeNormalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    // MARK: - Parametric / Peaking EQ (Band 2 — mid scoop)

    /// Second-order parametric (peaking) EQ filter.
    /// Boosts or cuts a band around the center frequency.
    /// Used for vocal anti-clash mid-scoop on A (~1.5kHz, -6 to -16 dB).
    ///
    /// - Parameters:
    ///   - frequency: Center frequency in Hz
    ///   - sampleRate: Audio sample rate in Hz
    ///   - gainDB: Gain in dB (negative = cut)
    ///   - bandwidth: Bandwidth in octaves (e.g., 1.0-1.5 for mid scoop)
    static func parametric(frequency: Float, sampleRate: Float, gainDB: Float, bandwidth: Float) -> BiquadCoefficients {
        let gain = clampGain(gainDB)
        guard abs(gain) > 0.01 else { return .passthrough }

        let f = clampFreq(frequency, sampleRate: sampleRate)
        let bw = max(bandwidth, 0.1)

        let A = powf(10.0, gain / 40.0)
        let w0 = 2.0 * Float.pi * f / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        // Guard: sinW0 near zero at DC or Nyquist (clamped freq prevents exact 0,
        // but defensive against float edge cases)
        guard abs(sinW0) > 1e-10 else { return .passthrough }
        // alpha from bandwidth in octaves:
        // alpha = sin(w0) * sinh(ln(2)/2 * BW * w0/sin(w0))
        let alpha = sinW0 * sinh(log(2.0) / 2.0 * bw * w0 / sinW0)

        let b0 = 1.0 + alpha * A
        let b1 = -2.0 * cosW0
        let b2 = 1.0 - alpha * A
        let a0 = 1.0 + alpha / A
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha / A

        return safeNormalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    // MARK: - High Shelf (Band 3 — hi-hat/cymbal cleanup)

    /// Second-order high shelf filter.
    /// Boosts or cuts frequencies above the shelf frequency.
    /// Used for hi-hat/cymbal cleanup on A (~8kHz, -4 to -10 dB).
    static func highShelf(frequency: Float, sampleRate: Float, gainDB: Float, S: Float = 1.0) -> BiquadCoefficients {
        let gain = clampGain(gainDB)
        guard abs(gain) > 0.01 else { return .passthrough }

        let f = clampFreq(frequency, sampleRate: sampleRate)
        let s = max(S, 0.1)

        let A = powf(10.0, gain / 40.0)
        let w0 = 2.0 * Float.pi * f / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / 2.0 * sqrt((A + 1.0 / A) * (1.0 / s - 1.0) + 2.0)
        let sqrtAalpha = 2.0 * sqrt(A) * alpha

        let b0 = A * ((A + 1.0) + (A - 1.0) * cosW0 + sqrtAalpha)
        let b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW0)
        let b2 = A * ((A + 1.0) + (A - 1.0) * cosW0 - sqrtAalpha)
        let a0 = (A + 1.0) - (A - 1.0) * cosW0 + sqrtAalpha
        let a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosW0)
        let a2 = (A + 1.0) - (A - 1.0) * cosW0 - sqrtAalpha

        return safeNormalize(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }
}
