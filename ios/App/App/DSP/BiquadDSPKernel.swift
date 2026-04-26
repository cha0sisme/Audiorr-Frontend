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

    /// Lock for coefficient access. The render thread uses trylock (non-blocking).
    private var lock = os_unfair_lock()

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
        pendingCoefficients[0] = band0
        pendingCoefficients[1] = band1
        pendingCoefficients[2] = band2
        pendingCoefficients[3] = band3
        hasPending = true
        os_unfair_lock_unlock(&lock)
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
            if hasPending {
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
            // the render thread reads/writes state. Coefficients are already
            // passthrough (set by reset()), so the loop below will skip all stages.
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
    }

    // MARK: - Reset

    /// Reset all filter state to clean passthrough. Instant and guaranteed.
    /// Safe to call from any thread (acquires lock for coefficients, then
    /// the render thread will see passthrough and skip processing).
    func reset() {
        os_unfair_lock_lock(&lock)
        for i in 0..<Self.filterCount {
            coefficients[i] = .passthrough
            pendingCoefficients[i] = .passthrough
        }
        hasPending = false
        // Signal render thread to zero delay lines on its next process() call.
        // State arrays are owned exclusively by the render thread — writing them
        // from another thread would be a data race. The render thread will see
        // passthrough coefficients immediately (skipping all processing) and zero
        // the delay lines when it picks up this flag via trylock.
        needsStateReset = true
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
