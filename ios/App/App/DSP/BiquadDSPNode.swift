// ╔══════════════════════════════════════════════════════════════════════╗
// ║   BiquadDSPNode — Custom AUAudioUnit effect for AVAudioEngine       ║
// ║   Replaces AVAudioUnitEQ for crossfade filter automation            ║
// ║   Audiorr — Audiophile-grade music player                           ║
// ║   Copyright (c) 2025-2026 cha0sisme (github.com/cha0sisme)         ║
// ╚══════════════════════════════════════════════════════════════════════╝

import AVFoundation
import AudioToolbox

// MARK: - Component Description

/// Unique AudioComponentDescription for Audiorr's biquad DSP effect.
private let biquadComponentDescription = AudioComponentDescription(
    componentType: kAudioUnitType_Effect,
    componentSubType: FourCharCode("bqad"),   // "bqad" = biquad
    componentManufacturer: FourCharCode("Audr"), // "Audr" = Audiorr
    componentFlags: 0,
    componentFlagsMask: 0
)

/// Whether the BiquadAudioUnit subclass has been registered with CoreAudio.
private var isRegistered = false

// MARK: - FourCharCode helper

/// Convert a 4-character string to a FourCharCode (UInt32).
private func FourCharCode(_ string: String) -> UInt32 {
    var result: UInt32 = 0
    for char in string.utf8.prefix(4) {
        result = result << 8 + UInt32(char)
    }
    return result
}

// MARK: - BiquadAudioUnit (AUAudioUnit v3 subclass)

/// In-process Audio Unit v3 effect that applies 4 cascaded biquad filters.
/// Registered with `AUAudioUnit.registerSubclass()` and instantiated via
/// `AVAudioUnit.instantiate()` for insertion into an AVAudioEngine graph.
///
/// The render block pulls input audio, passes it through BiquadDSPKernel.process()
/// in-place, and returns the filtered output. Zero allocation in the render path.
final class BiquadAudioUnit: AUAudioUnit {

    /// The DSP kernel that performs the actual filtering.
    /// Shared with BiquadDSPNode for coefficient updates.
    let kernel = BiquadDSPKernel()

    // MARK: - Bus management

    private var _inputBus: AUAudioUnitBus!
    private var _outputBus: AUAudioUnitBus!
    private var _inputBusArray: AUAudioUnitBusArray!
    private var _outputBusArray: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)

        // Default format: stereo Float32 non-interleaved @ 44.1kHz
        // The engine will negotiate the actual format via allocateRenderResources.
        let defaultFormat = AVAudioFormat(
            standardFormatWithSampleRate: 44100, channels: 2
        )!

        _inputBus = try AUAudioUnitBus(format: defaultFormat)
        _outputBus = try AUAudioUnitBus(format: defaultFormat)
        _inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [_inputBus])
        _outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [_outputBus])
    }

    override var inputBusses: AUAudioUnitBusArray { _inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { _outputBusArray }

    /// Maximum frames the host will request per render call.
    /// Used to pre-allocate scratch buffers if needed.
    override var maximumFramesToRender: AUAudioFrameCount {
        get { super.maximumFramesToRender }
        set { super.maximumFramesToRender = newValue }
    }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        // At this point, the actual sample rate and channel count are known
        // via inputBusses[0].format. The kernel works with any format since
        // it reads channel count from the AudioBufferList at render time.
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
    }

    // MARK: - Render block

    override var internalRenderBlock: AUInternalRenderBlock {
        // Capture kernel reference — NOT self — to avoid ARC traffic on audio thread.
        // BiquadDSPKernel is a class, so this is a strong reference that keeps it alive.
        let kernel = self.kernel

        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData, realtimeEventListPointer, pullInputBlock in

            // Pull input audio from the upstream node
            guard let pullInputBlock = pullInputBlock else {
                return kAudioUnitErr_NoConnection
            }

            var pullFlags: AudioUnitRenderActionFlags = []
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }

            // Process audio in-place through 4 biquad filters
            kernel.process(outputData, frameCount: frameCount)

            return noErr
        }
    }
}

// MARK: - BiquadDSPNode (public API)

/// High-level wrapper around BiquadAudioUnit for use in AudioEngineManager.
/// Provides a clean API for coefficient updates and reset, and exposes the
/// underlying AVAudioNode for insertion into the AVAudioEngine graph.
///
/// Usage:
/// ```
/// let dsp = try BiquadDSPNode()
/// engine.attach(dsp.node)
/// engine.connect(timePitch, to: dsp.node, format: nil)
/// engine.connect(dsp.node, to: mixer, format: nil)
///
/// // During crossfade filterTick:
/// dsp.setCoefficients(band0: highpass, band1: lowshelf, band2: midscoop, band3: highshelf)
///
/// // After crossfade completion:
/// dsp.reset()  // Instant. Guaranteed. No CoreAudio black box.
/// ```
final class BiquadDSPNode {

    /// The AVAudioUnit node to insert into the engine graph.
    let node: AVAudioUnit

    /// Direct reference to the DSP kernel for coefficient updates.
    private let kernel: BiquadDSPKernel

    /// Create a BiquadDSPNode with a fresh in-process Audio Unit.
    /// - Throws: If Audio Unit registration or instantiation fails.
    init() throws {
        // Register the AU subclass once (idempotent)
        if !isRegistered {
            AUAudioUnit.registerSubclass(
                BiquadAudioUnit.self,
                as: biquadComponentDescription,
                name: "Audiorr Biquad DSP",
                version: 1
            )
            isRegistered = true
        }

        // Instantiate synchronously using a semaphore.
        // For in-process AUs registered with registerSubclass, the completion
        // handler is called synchronously on the calling thread in practice.
        // The semaphore is a safety net for edge cases.
        var avAudioUnit: AVAudioUnit?
        var instantiationError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        AVAudioUnit.instantiate(with: biquadComponentDescription) { unit, error in
            avAudioUnit = unit
            instantiationError = error
            semaphore.signal()
        }

        // Wait with timeout — should be instant for in-process AUs
        let result = semaphore.wait(timeout: .now() + .milliseconds(500))
        if result == .timedOut {
            throw NSError(domain: "BiquadDSPNode", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "AU instantiation timed out"])
        }
        if let error = instantiationError {
            throw error
        }
        guard let unit = avAudioUnit else {
            throw NSError(domain: "BiquadDSPNode", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "AU instantiation returned nil"])
        }

        self.node = unit

        // Get the kernel reference from the AU for direct coefficient updates
        guard let biquadAU = unit.auAudioUnit as? BiquadAudioUnit else {
            throw NSError(domain: "BiquadDSPNode", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "AU is not BiquadAudioUnit"])
        }
        self.kernel = biquadAU.kernel
    }

    // MARK: - Coefficient API (called from automation thread)

    /// Update all 4 filter band coefficients.
    /// Called from CrossfadeExecutor.filterTick() at ~60Hz.
    /// Lock-free on the render thread side (uses trylock).
    func setCoefficients(
        band0: BiquadCoefficients,
        band1: BiquadCoefficients,
        band2: BiquadCoefficients,
        band3: BiquadCoefficients
    ) {
        kernel.updateCoefficients(band0: band0, band1: band1, band2: band2, band3: band3)
    }

    // MARK: - Reset (called after crossfade completion)

    /// Reset all filters to passthrough and zero all delay lines.
    /// Instant. Guaranteed. No CoreAudio black box. No stale coefficients.
    /// This is the whole reason we migrated from AVAudioUnitEQ.
    func reset() {
        kernel.reset()
    }

    // MARK: - Diagnostics

    /// Read current active coefficients for diagnostic display.
    func currentCoefficients() -> [BiquadCoefficients] {
        kernel.currentCoefficients()
    }
}
