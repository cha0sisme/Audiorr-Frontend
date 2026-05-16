// ╔══════════════════════════════════════════════════════════════════════╗
// ║   BiquadDSPKernel — Real-time biquad filter processor              ║
// ║   4 cascaded biquad stages, lock-free coefficient update            ║
// ║   Audiorr — Audiophile-grade music player                           ║
// ║   Copyright (c) 2025-2026 cha0sisme (github.com/cha0sisme)         ║
// ╚══════════════════════════════════════════════════════════════════════╝

import Foundation
import AVFoundation
import AudioToolbox
import os

/// Real-time DSP kernel for 4 cascaded biquad filters.
///
/// Thread model:
/// - **Automation thread** (~60Hz filterTick): calls `updateCoefficients()` to stage new values
/// - **Render thread** (CoreAudio real-time): calls `process()` to apply filters in-place
///
/// Coefficient passing uses `os_unfair_lock` with `os_unfair_lock_trylock` on the render
/// thread. If the lock is contended (automation thread writing), the render thread skips
/// the update and uses the previous coefficients — imperceptible at 60Hz update rate.
///
/// All memory allocated at init, never during rendering. Safe for CoreAudio real-time thread.
final class BiquadDSPKernel {

    // MARK: - Constants

    /// Maximum number of audio channels supported (stereo)
    static let maxChannels = 2
    /// Number of cascaded biquad filter stages (bands 0-3)
    static let filterCount = 4

    // MARK: - Coefficient storage

    /// Coefficients for 4 filter stages. Protected by lock.
    /// Written by automation thread, read by render thread.
    private var coefficients: [BiquadCoefficients] = Array(repeating: .passthrough, count: filterCount)

    /// Pending coefficients staged by the automation thread.
    /// When `hasPending` is true, the render thread will copy these to `coefficients`.
    private var pendingCoefficients: [BiquadCoefficients] = Array(repeating: .passthrough, count: filterCount)
    private var hasPending = false
    /// Flag for render thread to zero delay lines on next process() call.
    private var needsStateReset = false

    /// v14.10 — Frame counter for the reset() fade-out. While > 0 the render
    /// thread interpolates coefficients from `fadeoutStartCoefs` toward
    /// passthrough instead of taking a discrete step. Set by reset() under lock,
    /// decremented by process() under trylock. When it reaches 0 the kernel
    /// snaps to true passthrough and marks `needsStateReset`.
    private var fadeoutFramesRemaining: Int = 0
    private var fadeoutStartCoefs: [BiquadCoefficients] = Array(repeating: .passthrough, count: filterCount)
    /// 512 frames ≈ 10.7 ms @ 48 kHz / 11.6 ms @ 44.1 kHz. Short enough to feel
    /// instant from a timing standpoint, long enough to span 2-3 render buffers
    /// at typical 256-frame I/O sizes — the discrete step that produced the
    /// "bug de filtros" click is broken into 2-3 small steps instead of 1 big one.
    private static let fadeoutFramesTotal: Int = 512

    /// v14.c — Symmetric fade-in counterpart to the v14.10 fade-out. The original
    /// fade-out covered the leaving edge (active coefs → passthrough on reset),
    /// but the entering edge (passthrough → active coefs on the first
    /// `setCoefficients` of a new crossfade) was still a discrete step over hot
    /// audio (mixer A at full volume), producing the residual "bug de filtros"
    /// click reported in coche-test v14.b. The fade-in interpolates from
    /// passthrough toward the target coefs over `fadeinFramesTotal` frames,
    /// gated by an EXACT passthrough check on the live coefficients (no epsilon).
    /// CUT family is excluded by construction: `setupInitialEQ` plants
    /// passthrough on every band for CUT/CUT_A_FADE_IN_B, so pending == current
    /// == passthrough and the gate never fires.
    private var fadeinFramesRemaining: Int = 0
    private var fadeinTargetCoefs: [BiquadCoefficients] = Array(repeating: .passthrough, count: filterCount)
    /// 1024 frames ≈ 21.3 ms @ 48 kHz / 23.2 ms @ 44.1 kHz. Larger than the
    /// fade-out window (512) on purpose: a filterTick lands every ~16.7 ms,
    /// so 1024 absorbs the first incoming tick — `updateCoefficients` arriving
    /// mid-fade-in is dropped (caller path below) so the fade reaches its target
    /// before the rampa real takes over, eliminating the doble-rampa race.
    private static let fadeinFramesTotal: Int = 1024
    /// v14.c telemetry — set to true by `updateCoefficients` whenever the
    /// fade-in gate fires for this kernel since the last `reset()`. Read by the
    /// post-setup audit to confirm whether the suavizado entered for this
    /// transition (validates whether T3 was the actual cause of the click).
    private var fadeinDidTriggerSinceLastReset: Bool = false

    /// Lock for coefficient access. The render thread uses trylock (non-blocking).
    private var lock = os_unfair_lock()

    /// Maximum |z1|,|z2| observed across all stages × channels at end of last
    /// process() call. Used by the post-reset audit to verify the render thread
    /// actually zeroed the delay lines (not just that the flag was set).
    /// Written by render thread, read by audit thread. Float reads/writes on
    /// 32-bit aligned memory are atomic on ARM64 — no lock needed for diagnostics.
    private var lastStateMagnitude: Float = 0

    // MARK: - Filter state (render thread only)

    /// Delay lines for each filter stage × each channel.
    /// Layout: [filterIndex][channelIndex]
    /// Owned exclusively by the render thread — never touched by automation.
    private var state: [[BiquadState]] = Array(
        repeating: Array(repeating: BiquadState(), count: maxChannels),
        count: filterCount
    )

    // MARK: - Init

    init() {}

    // MARK: - Automation thread API

    /// Stage new coefficients for all 4 filter bands.
    /// Called from filterTick (~60Hz) on the automation queue.
    /// Thread-safe — acquires lock briefly to write pending values.
    func updateCoefficients(
        band0: BiquadCoefficients,
        band1: BiquadCoefficients,
        band2: BiquadCoefficients,
        band3: BiquadCoefficients
    ) {
        os_unfair_lock_lock(&lock)

        // v14.c — Symmetric fade-in detection. The gate fires only when EVERY
        // live band is exactly the canonical `.passthrough` struct (b0=1, rest=0)
        // AND at least one pending band is NOT exact passthrough. This identifies
        // the first `setCoefficients` after `reset()` / init, which is exactly
        // the lifecycle point where v14.10 didn't cover and the click survives.
        // Exact comparison (no epsilon) is intentional and safe: every calculator
        // path that yields a passthrough filter returns `BiquadCoefficients.passthrough`
        // directly via the `guard abs(gain) > 0.01 else { return .passthrough }`
        // shortcut, so the kernel sees bit-identical structs from setup.
        // Concurrent fade-in and fade-out are mutually exclusive — entering the
        // fade-in path forces the fadeout counter to zero.
        if fadeinFramesRemaining > 0 {
            // Fade-in already in flight — drop this update. The 1024-frame window
            // is long enough to swallow the first filterTick (16.7ms < 21.3ms),
            // and the rampa real picks up at the next tick from the natural target.
            // This is the doble-rampa mitigation devils-advocate flagged: never
            // let an incoming coefficient stomp the fade-in mid-flight.
            os_unfair_lock_unlock(&lock)
            return
        }

        let currentIsAllPassthrough =
            isExactPassthrough(coefficients[0]) &&
            isExactPassthrough(coefficients[1]) &&
            isExactPassthrough(coefficients[2]) &&
            isExactPassthrough(coefficients[3])
        let anyPendingIsActive =
            !isExactPassthrough(band0) ||
            !isExactPassthrough(band1) ||
            !isExactPassthrough(band2) ||
            !isExactPassthrough(band3)

        if currentIsAllPassthrough && anyPendingIsActive {
            // Fire fade-in. Stage the target coefs; the render thread will
            // interpolate from `.passthrough` toward them over 1024 frames.
            fadeinTargetCoefs[0] = band0
            fadeinTargetCoefs[1] = band1
            fadeinTargetCoefs[2] = band2
            fadeinTargetCoefs[3] = band3
            fadeinFramesRemaining = Self.fadeinFramesTotal
            fadeinDidTriggerSinceLastReset = true
            hasPending = false
            // Mutually exclusive with the fade-out path.
            fadeoutFramesRemaining = 0
            os_unfair_lock_unlock(&lock)
            return
        }

        pendingCoefficients[0] = band0
        pendingCoefficients[1] = band1
        pendingCoefficients[2] = band2
        pendingCoefficients[3] = band3
        hasPending = true
        // v14.10 — an explicit coefficient update cancels any reset() fade-out in
        // flight. Covers the edge case where the next crossfade's setupInitialEQ
        // lands before the previous fade has fully drained. The new coefficients
        // take precedence; the half-faded state is dropped.
        fadeoutFramesRemaining = 0
        os_unfair_lock_unlock(&lock)
    }

    /// v14.c gate helper — strict equality against the canonical passthrough.
    /// Inlined explicit comparisons avoid an epsilon-based mismatch with the
    /// public `isPassthrough` (which uses `1e-6` tolerance) and guarantee the
    /// gate fires only when the kernel really is at identity.
    @inline(__always)
    private func isExactPassthrough(_ c: BiquadCoefficients) -> Bool {
        return c.b0 == 1 && c.b1 == 0 && c.b2 == 0 && c.a1 == 0 && c.a2 == 0
    }

    // MARK: - Render thread API

    /// Process audio buffers in-place through 4 cascaded biquad filters.
    /// Called from CoreAudio's real-time render thread.
    ///
    /// - Parameters:
    ///   - ioData: Audio buffer list (non-interleaved Float32)
    ///   - frameCount: Number of frames to process
    func process(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        guard frameCount > 0 else { return }

        // Try to pick up pending coefficients (non-blocking)
        if os_unfair_lock_trylock(&lock) {
            if fadeinFramesRemaining > 0 {
                // v14.c — Fade-in in flight: interpolate from passthrough toward
                // the staged target over 1024 frames. Progress at END of buffer
                // matches the fade-out convention. When the counter drains, snap
                // to the exact target so subsequent filterTicks rampean desde
                // ahí sin escalón. No `needsStateReset` here: delay lines are
                // already clean (we came from passthrough; nothing to flush).
                let framesInThisBuffer = min(Int(frameCount), fadeinFramesRemaining)
                let total = Self.fadeinFramesTotal
                let progressEnd = Float(total - (fadeinFramesRemaining - framesInThisBuffer)) / Float(total)
                for i in 0..<Self.filterCount {
                    coefficients[i] = BiquadCoefficients.lerp(.passthrough, fadeinTargetCoefs[i], progressEnd)
                }
                fadeinFramesRemaining -= framesInThisBuffer
                if fadeinFramesRemaining <= 0 {
                    for i in 0..<Self.filterCount {
                        coefficients[i] = fadeinTargetCoefs[i]
                    }
                    fadeinFramesRemaining = 0
                }
            } else if fadeoutFramesRemaining > 0 {
                // v14.10 — reset() in flight: interpolate coefs toward passthrough.
                // progress at END of this buffer (so the first buffer of the fade
                // already moves; the last one lands exactly on passthrough).
                let framesInThisBuffer = min(Int(frameCount), fadeoutFramesRemaining)
                let total = Self.fadeoutFramesTotal
                let progressEnd = Float(total - (fadeoutFramesRemaining - framesInThisBuffer)) / Float(total)
                for i in 0..<Self.filterCount {
                    coefficients[i] = BiquadCoefficients.lerp(fadeoutStartCoefs[i], .passthrough, progressEnd)
                }
                fadeoutFramesRemaining -= framesInThisBuffer
                if fadeoutFramesRemaining <= 0 {
                    for i in 0..<Self.filterCount {
                        coefficients[i] = .passthrough
                    }
                    fadeoutFramesRemaining = 0
                    needsStateReset = true
                }
            } else if hasPending {
                coefficients[0] = pendingCoefficients[0]
                coefficients[1] = pendingCoefficients[1]
                coefficients[2] = pendingCoefficients[2]
                coefficients[3] = pendingCoefficients[3]
                hasPending = false
            }
            let shouldReset = needsStateReset
            if shouldReset { needsStateReset = false }
            os_unfair_lock_unlock(&lock)

            // Zero delay lines on the render thread — safe because only
            // the render thread reads/writes state. By the time `shouldReset`
            // is true, coefficients are already passthrough (the fade-out
            // branch above set them so before raising the flag).
            if shouldReset {
                for stage in 0..<Self.filterCount {
                    for ch in 0..<Self.maxChannels {
                        state[stage][ch] = BiquadState()
                    }
                }
            }
        }
        // If trylock failed: automation thread is writing. Use previous coefficients.
        // At 60Hz updates, skipping one frame (5ms) is imperceptible.

        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        let channels = min(abl.count, Self.maxChannels)
        let frames = Int(frameCount)

        // Apply 4 biquad stages in series
        for stage in 0..<Self.filterCount {
            let c = coefficients[stage]

            // Skip passthrough filters (common case: not crossfading)
            guard !c.isPassthrough else { continue }

            for ch in 0..<channels {
                guard let data = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                applyBiquad(data, frames: frames, coeffs: c, state: &state[stage][ch])
            }
        }

        // Diagnostic: capture max delay-line magnitude across active stages.
        // 0 if all stages are passthrough (state untouched). Cheap (<= 8 ops).
        var maxMag: Float = 0
        for stage in 0..<Self.filterCount {
            if coefficients[stage].isPassthrough { continue }
            for ch in 0..<channels {
                let m = max(abs(state[stage][ch].z1), abs(state[stage][ch].z2))
                if m > maxMag { maxMag = m }
            }
        }
        lastStateMagnitude = maxMag
    }

    // MARK: - Reset

    /// Reset all filter state to clean passthrough.
    ///
    /// v14.10 — Two-phase fade-out to avoid the discrete coefficient step that
    /// produced an audible click when this was called from `completeCrossfade`
    /// while the upstream mixer's outputVolume had not yet propagated to 0 on
    /// the render thread. We snapshot the active coefficients as the fade
    /// starting point and let the render thread interpolate toward passthrough
    /// over `fadeoutFramesTotal` frames. The delay-line zeroing (`needsStateReset`)
    /// happens at the end of the fade, when coefficients are truly passthrough.
    ///
    /// Safe to call from any thread (acquires lock briefly).
    func reset() {
        os_unfair_lock_lock(&lock)
        for i in 0..<Self.filterCount {
            fadeoutStartCoefs[i] = coefficients[i]
            pendingCoefficients[i] = .passthrough
        }
        // pending is redundant with the fade — the fade itself ends in passthrough
        hasPending = false
        fadeoutFramesRemaining = Self.fadeoutFramesTotal
        // v14.c — Cancel any in-flight fade-in. A reset takes precedence: if a
        // fade-in was halfway, the fade-out kernel below picks up `coefficients[i]`
        // as the starting point and fades toward passthrough, so the interrupted
        // suavizado still ends on a clean tail. The telemetry flag is cleared so
        // the next crossfade starts fresh.
        fadeinFramesRemaining = 0
        fadeinDidTriggerSinceLastReset = false
        // needsStateReset will be raised by process() when the fade completes.
        // State arrays are owned exclusively by the render thread — writing them
        // from another thread would be a data race.
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Diagnostics

    /// Read current active coefficients (for diagnostics/audit).
    /// NOT real-time safe — acquires lock.
    func currentCoefficients() -> [BiquadCoefficients] {
        os_unfair_lock_lock(&lock)
        let copy = coefficients
        os_unfair_lock_unlock(&lock)
        return copy
    }

    /// Most recent delay-line magnitude observed by the render thread.
    /// 0 == clean. Approximate (no lock); on ARM64 a 32-bit float read is atomic
    /// in practice so we either see the most recent value or one render frame old.
    /// CAVEAT: if the player feeding this kernel is stopped, the render thread
    /// is not running, and this returns whatever value was last written before
    /// the stop. Combine with a small wait after reset() before checking.
    func currentStateMagnitude() -> Float {
        return lastStateMagnitude
    }

    // MARK: - Biquad processing (Direct Form II Transposed)

    /// Apply a single biquad filter stage in-place on Float32 audio data.
    /// Direct Form II Transposed — most numerically stable topology for float.
    ///
    ///   y[n] = b0*x[n] + z1
    ///   z1   = b1*x[n] - a1*y[n] + z2
    ///   z2   = b2*x[n] - a2*y[n]
    ///
    /// 5 multiplies + 4 adds per sample. At 48kHz stereo × 4 stages = 3.5M ops/s.
    /// Trivial on any ARM chip.
    private func applyBiquad(
        _ data: UnsafeMutablePointer<Float>,
        frames: Int,
        coeffs: BiquadCoefficients,
        state: inout BiquadState
    ) {
        let b0 = coeffs.b0, b1 = coeffs.b1, b2 = coeffs.b2
        let a1 = coeffs.a1, a2 = coeffs.a2
        var z1 = state.z1, z2 = state.z2

        for i in 0..<frames {
            let x = data[i]
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            data[i] = y
        }

        // Flush denormals: snap tiny values to zero to prevent CPU spikes.
        // On ARM, denormalized floats can be 10-100x slower to process.
        if abs(z1) < 1e-15 { z1 = 0 }
        if abs(z2) < 1e-15 { z2 = 0 }

        state.z1 = z1
        state.z2 = z2
    }
}
