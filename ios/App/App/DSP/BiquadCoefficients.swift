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
}

/// Delay line state for a single biquad stage (Direct Form II Transposed).
/// Owned exclusively by the render thread — never touched by the automation thread.
struct BiquadState {
    var z1: Float = 0
    var z2: Float = 0
}
