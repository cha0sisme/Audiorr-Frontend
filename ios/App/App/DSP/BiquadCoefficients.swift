// ╔══════════════════════════════════════════════════════════════════════╗
// ║   BiquadCoefficients — Plain-old-data biquad filter coefficients    ║
// ║   Audiorr — Audiophile-grade music player                           ║
// ║   Copyright (c) 2025-2026 cha0sisme (github.com/cha0sisme)         ║
// ╚══════════════════════════════════════════════════════════════════════╝

import Foundation

/// Normalized biquad filter coefficients for Direct Form II Transposed.
///
/// Transfer function: H(z) = (b0 + b1*z⁻¹ + b2*z⁻²) / (1 + a1*z⁻¹ + a2*z⁻²)
///
/// The difference equation (DFII-T):
///   y[n] = b0*x[n] + z1
///   z1   = b1*x[n] - a1*y[n] + z2
///   z2   = b2*x[n] - a2*y[n]
///
/// All coefficients are pre-normalized (divided by a0).
/// This struct is POD — no heap allocation, no ARC, safe for audio thread.
struct BiquadCoefficients {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float

    /// Identity filter — passes audio through unmodified.
    /// b0=1, all others=0 → y[n] = x[n]
    static let passthrough = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// True if this filter is effectively a passthrough (no processing needed).
    /// Used to skip computation in the render loop for inactive filter stages.
    /// Uses epsilon comparison to handle floating-point imprecision from
    /// coefficient calculations that should yield identity but don't exactly.
    var isPassthrough: Bool {
        let eps: Float = 1e-6
        return abs(b0 - 1) < eps && abs(b1) < eps && abs(b2) < eps && abs(a1) < eps && abs(a2) < eps
    }

    /// Linear interpolation between two coefficient sets.
    /// t=0 → a, t=1 → b. Used by the kernel's reset() fade-out to smooth
    /// the transition from an active filter back to passthrough over a few
    /// render buffers, avoiding a discrete step that would click audibly
    /// if the upstream mixer's volume hasn't fully ramped to 0 yet.
    static func lerp(_ a: BiquadCoefficients, _ b: BiquadCoefficients, _ t: Float) -> BiquadCoefficients {
        let u = 1 - t
        return BiquadCoefficients(
            b0: a.b0 * u + b.b0 * t,
            b1: a.b1 * u + b.b1 * t,
            b2: a.b2 * u + b.b2 * t,
            a1: a.a1 * u + b.a1 * t,
            a2: a.a2 * u + b.a2 * t
        )
    }
}

/// Delay line state for a single biquad stage (Direct Form II Transposed).
/// Owned exclusively by the render thread — never touched by the automation thread.
struct BiquadState {
    var z1: Float = 0
    var z2: Float = 0
}
