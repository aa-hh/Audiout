// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header, unlike most
// siblings. The filter coefficients are derived from the published RBJ
// Audio-EQ-Cookbook formulas and the code around them is original to this
// project, so the license-clean Bluetooth sink (`BTSyncedSink.swift`) can run
// the SAME processor the AirPlay path does — one sound signature across
// transports. Do not add a GPL header to this file, and do not move
// GPL-derived code into it.

import Accelerate
import Foundation

/// Applies one ``DeviceEQ`` to interleaved stereo audio.
///
/// **One processing owner, and parameters change only through the mailbox.**
/// Each instance is driven by exactly ONE thread (the capture delivery thread
/// for the whole-system path, a sink's render thread for Bluetooth), the same
/// single-caller discipline `AVFormatConverter` runs under; sharing one instance
/// between two feeds would interleave their biquad histories. A settings change
/// goes through ``retarget(to:)``, which builds the new engine off-thread and
/// posts it to a one-slot mailbox; the processing thread adopts it at the top of
/// the next buffer and carries the matching sections' delay memory across, so a
/// slider drag never zeroes the filter state mid-signal. Nothing else may write
/// a live instance, and its filter state must never be READ from another thread
/// either — the processing thread may be inside ``process(_:)`` this instant.
///
/// **A flat EQ must never reach this class.** Widening to float and requantizing
/// is not bit-exact, so a flat device has to bypass the processor entirely to
/// stay byte-identical passthrough.
///
/// Scratch buffers are allocated once at ``EQProcessor/maxChunkFrames`` and work
/// is chunked to that size, so no allocation ever depends on the incoming buffer
/// length.
public final class EQProcessor: @unchecked Sendable {

    /// Longest run of frames processed in one pass. Caps the scratch buffers.
    public static let maxChunkFrames = 4_096

    /// Interleaved stereo everywhere: the AirPlay wire format and both sink
    /// render formats are 2-channel.
    private static let channels = 2

    /// A section whose corner sits at or above this fraction of the sample rate
    /// is skipped — at Bluetooth HFP's 24 kHz the top bands would otherwise
    /// fold, and a bilinear-warped filter that close to Nyquist is meaningless
    /// anyway.
    private static let nyquistFraction = 0.45

    /// Which filter section a coefficient slot belongs to — identity rather than
    /// position. It is what lets ``retarget(to:)`` tell "the same bass shelf at a
    /// new gain", whose delay memory carries over, from "a section that wasn't
    /// running a moment ago", which has to be seeded.
    enum SectionKey: Equatable {
        case band(Int)
        case bass
        case treble
        case loudnessLow
        case loudnessHigh
    }

    /// Everything one ``DeviceEQ`` value decides, in one box: the vDSP setup,
    /// which sections it holds, their delay memory, and the balance trim.
    /// Swapped as a unit, so coefficients and delays can never disagree.
    private final class Engine {
        let setup: vDSP_biquad_Setup?
        let keys: [SectionKey]
        var delaysLeft: [Float]
        var delaysRight: [Float]
        let leftGain: Float
        let rightGain: Float

        init(eq: DeviceEQ, sampleRate: Double) {
            let built = EQProcessor.sections(for: eq, sampleRate: sampleRate)
            keys = built.keys
            setup = built.keys.isEmpty
                ? nil
                : vDSP_biquad_CreateSetup(built.coefficients, vDSP_Length(built.keys.count))
            delaysLeft = [Float](repeating: 0, count: 2 * built.keys.count + 2)
            delaysRight = [Float](repeating: 0, count: 2 * built.keys.count + 2)
            let gains = EQProcessor.channelGains(balance: eq.balance)
            leftGain = gains.left
            rightGain = gains.right
        }

        deinit { if let setup { vDSP_biquad_DestroySetup(setup) } }
    }

    /// An engine waiting in the mailbox, with the delay-pair map that carries the
    /// live engine's state into it.
    private struct Pending {
        let engine: Engine
        let carryMap: [Int]
    }

    /// What a swap displaced. Both halves are heap memory, and freeing on the
    /// processing thread is exactly what this class must never do — the next
    /// ``retarget(to:)`` releases them instead.
    private struct Retired {
        let engine: Engine
        let spent: Pending
    }

    private let sampleRate: Double

    /// The live engine. Read and swapped by the PROCESSING thread only.
    private var engine: Engine

    /// Guards the one-slot mailbox below. The processing thread takes it with
    /// `try()`, never `lock()`.
    private let mailbox = NSLock()
    private var pending: Pending?        // mailbox
    private var retired: Retired?        // mailbox
    /// The live engine's section list, mirrored here so ``retarget(to:)`` can
    /// build a carry map without reading the live instance. Written by the
    /// processing thread at swap time, under the lock it is already holding.
    private var liveKeys: [SectionKey]   // mailbox

    private let chanLeft: UnsafeMutablePointer<Float>
    private let chanRight: UnsafeMutablePointer<Float>
    private let filteredLeft: UnsafeMutablePointer<Float>
    private let filteredRight: UnsafeMutablePointer<Float>

    /// - Parameter sampleRate: the rate of the audio this instance will be fed.
    ///   Coefficients are baked for it, so a rate change means a new processor.
    public init(eq: DeviceEQ, sampleRate: Double) {
        self.sampleRate = sampleRate
        let engine = Engine(eq: eq, sampleRate: sampleRate)
        self.engine = engine
        liveKeys = engine.keys

        chanLeft = .allocate(capacity: Self.maxChunkFrames)
        chanRight = .allocate(capacity: Self.maxChunkFrames)
        filteredLeft = .allocate(capacity: Self.maxChunkFrames)
        filteredRight = .allocate(capacity: Self.maxChunkFrames)
    }

    deinit {
        chanLeft.deallocate()
        chanRight.deallocate()
        filteredLeft.deallocate()
        filteredRight.deallocate()
    }

    // MARK: Entry points

    /// Filter interleaved S16LE stereo in place — the whole-system path, run on
    /// the buffer `AVFormatConverter` just produced.
    public func process(_ pcm: inout Data) {
        adoptPendingEngine()
        let bytesPerFrame = Self.channels * MemoryLayout<Int16>.size
        let totalFrames = pcm.count / bytesPerFrame
        guard totalFrames > 0 else { return }

        pcm.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            var frame = 0
            while frame < totalFrames {
                let count = Swift.min(Self.maxChunkFrames, totalFrames - frame)
                let chunk = base + frame * Self.channels
                widen(chunk, frameCount: count)
                filterBalanceAndClip(frameCount: count)
                requantize(into: chunk, frameCount: count)
                frame += count
            }
        }
    }

    /// Filter interleaved float stereo in place, clamped to ±1 — the Bluetooth
    /// render path, which never touches S16.
    public func process(floatInterleaved: UnsafeMutablePointer<Float>, frameCount: Int) {
        adoptPendingEngine()
        guard frameCount > 0 else { return }
        var frame = 0
        while frame < frameCount {
            let count = Swift.min(Self.maxChunkFrames, frameCount - frame)
            let chunk = floatInterleaved + frame * Self.channels
            deinterleave(chunk, frameCount: count)
            filterBalanceAndClip(frameCount: count)
            interleave(into: chunk, frameCount: count)
            frame += count
        }
    }

    // MARK: Per-chunk stages

    private func widen(_ chunk: UnsafeMutablePointer<Int16>, frameCount: Int) {
        let count = vDSP_Length(frameCount)
        vDSP_vflt16(chunk, 2, chanLeft, 1, count)
        vDSP_vflt16(chunk + 1, 2, chanRight, 1, count)
        var scale = Float(1.0 / 32768.0)
        vDSP_vsmul(chanLeft, 1, &scale, chanLeft, 1, count)
        vDSP_vsmul(chanRight, 1, &scale, chanRight, 1, count)
    }

    // razor: The limiter IS this clamp — a hard clip at the float→S16 boundary,
    // matching `AppRouteMixer.clip(_:)`. It makes wrap-into-noise impossible on a
    // boosted stream; a flat stream bypasses the processor entirely and cannot
    // have been boosted, so it needs none. Upgrade path when a hot mix audibly
    // crunches: a soft-knee/lookahead limiter stage immediately before this
    // clamp, same call site.
    private func requantize(into chunk: UnsafeMutablePointer<Int16>, frameCount: Int) {
        let count = vDSP_Length(frameCount)
        var scale = Float(32_767.0)
        vDSP_vsmul(chanLeft, 1, &scale, chanLeft, 1, count)
        vDSP_vsmul(chanRight, 1, &scale, chanRight, 1, count)
        vDSP_vfixr16(chanLeft, 1, chunk, 2, count)
        vDSP_vfixr16(chanRight, 1, chunk + 1, 2, count)
    }

    private func deinterleave(_ chunk: UnsafeMutablePointer<Float>, frameCount: Int) {
        var split = DSPSplitComplex(realp: chanLeft, imagp: chanRight)
        chunk.withMemoryRebound(to: DSPComplex.self, capacity: frameCount) { complex in
            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(frameCount))
        }
    }

    private func interleave(into chunk: UnsafeMutablePointer<Float>, frameCount: Int) {
        var split = DSPSplitComplex(realp: chanLeft, imagp: chanRight)
        chunk.withMemoryRebound(to: DSPComplex.self, capacity: frameCount) { complex in
            vDSP_ztoc(&split, 1, complex, 2, vDSP_Length(frameCount))
        }
    }

    private func filterBalanceAndClip(frameCount: Int) {
        let count = vDSP_Length(frameCount)

        if let setup = engine.setup {
            vDSP_biquad(setup, &engine.delaysLeft, chanLeft, 1, filteredLeft, 1, count)
            vDSP_biquad(setup, &engine.delaysRight, chanRight, 1, filteredRight, 1, count)
            chanLeft.update(from: filteredLeft, count: frameCount)
            chanRight.update(from: filteredRight, count: frameCount)
        }

        if engine.leftGain != 1 {
            var gain = engine.leftGain
            vDSP_vsmul(chanLeft, 1, &gain, chanLeft, 1, count)
        }
        if engine.rightGain != 1 {
            var gain = engine.rightGain
            vDSP_vsmul(chanRight, 1, &gain, chanRight, 1, count)
        }

        var low = Float(-1), high = Float(1)
        vDSP_vclip(chanLeft, 1, &low, &high, chanLeft, 1, count)
        vDSP_vclip(chanRight, 1, &low, &high, chanRight, 1, count)
    }

    // MARK: Retargeting

    /// Point this processor at a NEW ``DeviceEQ`` WITHOUT zeroing its filter
    /// memory — what makes a slider drag on the speaker being edited silent
    /// instead of a crackle for the whole drag.
    ///
    /// Non-real-time: call it from the thread that owns the settings
    /// (`stateQueue` on the whole-system path). Every allocation and every free
    /// happens here; the processing thread only copies a handful of floats.
    public func retarget(to eq: DeviceEQ) {
        let next = Engine(eq: eq, sampleRate: sampleRate)
        mailbox.lock()
        pending = Pending(engine: next, carryMap: Self.delayCarryMap(from: liveKeys, to: next.keys))
        // Both of these free an engine, which is precisely why they happen on
        // THIS thread: the line above released a mailbox entry the processing
        // thread never picked up, and this one releases whatever the last swap
        // displaced.
        retired = nil
        mailbox.unlock()
    }

    /// Adopt a mailboxed engine if one is waiting. PROCESSING thread, at the top
    /// of a buffer. `try()` rather than `lock()` — the same shape
    /// `NativeCaptureCoordinator.handleBuffer` uses for its snapshot read — so
    /// audio is never parked behind a writer: a miss simply runs this buffer on
    /// the current engine and the swap lands on the next one. Allocates nothing
    /// and frees nothing.
    private func adoptPendingEngine() {
        guard mailbox.try() else { return }
        if let next = pending {
            Self.carry(from: engine.delaysLeft, map: next.carryMap, into: &next.engine.delaysLeft)
            Self.carry(from: engine.delaysRight, map: next.carryMap, into: &next.engine.delaysRight)
            // `retired` is nil here — ``retarget(to:)`` clears it before posting —
            // so parking the old engine and emptying the mailbox both release
            // references that something else still holds. Nothing is freed.
            retired = Retired(engine: engine, spent: next)
            engine = next.engine
            pending = nil
            liveKeys = engine.keys
        }
        mailbox.unlock()
    }

    // MARK: Delay carry

    /// Carry `delays` from one section list onto another — the rule, as one pure
    /// function.
    ///
    /// vDSP's delay array is PAIRS: pair 0 is the input history the chain starts
    /// from, and pair `i+1` is section `i`'s output history, which is also
    /// section `i+1`'s input history. So pair 0 always carries; a section present
    /// in both lists keeps its own output pair; a genuinely new section seeds
    /// from its INPUT pair — the preceding pair, already carried. That last rule
    /// is a steady-state-unity approximation, and it is what keeps a band
    /// crossing 0 dB (which adds or drops a whole section) free of a first-order
    /// step. A section that went away simply takes its pair with it.
    static func carriedDelays(
        _ delays: [Float], from oldKeys: [SectionKey], to newKeys: [SectionKey]
    ) -> [Float] {
        var carried = [Float](repeating: 0, count: 2 * newKeys.count + 2)
        carry(from: delays, map: delayCarryMap(from: oldKeys, to: newKeys), into: &carried)
        return carried
    }

    /// Where each delay pair of `newKeys` comes from: a pair index into the old
    /// array, or `-1` for "seed from the preceding new pair".
    private static func delayCarryMap(from oldKeys: [SectionKey], to newKeys: [SectionKey]) -> [Int] {
        var map = [Int](repeating: -1, count: newKeys.count + 1)
        map[0] = 0
        for (index, key) in newKeys.enumerated() {
            if let old = oldKeys.firstIndex(of: key) { map[index + 1] = old + 1 }
        }
        return map
    }

    /// Apply a ``delayCarryMap(from:to:)``. `destination` must already be sized
    /// for the new section list. Allocation-free, so the processing thread can
    /// run it.
    private static func carry(from source: [Float], map: [Int], into destination: inout [Float]) {
        for pair in map.indices {
            let slot = 2 * pair
            let from = map[pair]
            if from >= 0 {
                destination[slot] = source[2 * from]
                destination[slot + 1] = source[2 * from + 1]
            } else if pair > 0 {
                destination[slot] = destination[slot - 2]
                destination[slot + 1] = destination[slot - 1]
            }
        }
    }

    // MARK: Coefficients (RBJ Audio-EQ-Cookbook)

    /// Balance is ATTENUATE-ONLY: panning right turns the left channel down
    /// rather than the right channel up, so it can never add headroom pressure
    /// to a channel that was already near full scale.
    private static func channelGains(balance: Double) -> (left: Float, right: Float) {
        if balance >= 0 { return (Float(1 - balance), 1) }
        return (1, Float(1 + balance))
    }

    /// Flattened `[b0, b1, b2, a1, a2]` per section, plus the parallel identity
    /// of each, in the fixed order the sections run: bands (ascending), bass,
    /// treble, loudness low, loudness high. The identities are what
    /// ``carriedDelays(_:from:to:)`` matches on.
    private static func sections(
        for eq: DeviceEQ, sampleRate: Double
    ) -> (coefficients: [Double], keys: [SectionKey]) {
        guard sampleRate > 0 else { return ([], []) }
        let ceiling = nyquistFraction * sampleRate
        var coefficients: [Double] = []
        var keys: [SectionKey] = []

        for (index, gainDB) in eq.bandGainsDB.enumerated() {
            guard gainDB != 0, index < DeviceEQ.bandCentresHz.count else { continue }
            let centre = DeviceEQ.bandCentresHz[index]
            guard centre < ceiling else { continue }
            coefficients += peaking(frequency: centre, q: 1.41, gainDB: gainDB, sampleRate: sampleRate)
            keys.append(.band(index))
        }

        if eq.bassDB != 0, 120 < ceiling {
            coefficients += lowShelf(frequency: 120, q: 0.707, gainDB: eq.bassDB, sampleRate: sampleRate)
            keys.append(.bass)
        }
        if eq.trebleDB != 0, 8_000 < ceiling {
            coefficients += highShelf(frequency: 8_000, q: 0.707, gainDB: eq.trebleDB, sampleRate: sampleRate)
            keys.append(.treble)
        }
        if eq.loudness {
            // razor: a FIXED smile curve, not a volume-tracking one. Real
            // loudness compensation needs a calibrated reference level the app
            // has no way to know yet; upgrade path is to scale these two gains
            // by the composed output level once one exists.
            if 100 < ceiling {
                coefficients += lowShelf(frequency: 100, q: 0.707, gainDB: 6, sampleRate: sampleRate)
                keys.append(.loudnessLow)
            }
            if 10_000 < ceiling {
                coefficients += highShelf(frequency: 10_000, q: 0.707, gainDB: 3, sampleRate: sampleRate)
                keys.append(.loudnessHigh)
            }
        }

        return (coefficients, keys)
    }

    /// The flattened `[b0, b1, b2, a1, a2]` coefficients `responseDB(sections:atHz:sampleRate:)`
    /// evaluates — the expensive half of a response query, so a caller that needs
    /// many frequencies (the Equalizer curve) builds this ONCE and evaluates it
    /// per point instead of rebuilding the whole filter design each time.
    public static func responseSections(for eq: DeviceEQ, sampleRate: Double) -> [Double] {
        Self.sections(for: eq, sampleRate: sampleRate).coefficients
    }

    /// The magnitude response of a pre-built coefficient array (from
    /// ``responseSections(for:sampleRate:)``) at `hz`, in dB. Sums each biquad
    /// section's `20·log10|H(e^{jω})|`, so it reads from the SAME coefficients
    /// the DSP runs and can never drift from what is heard.
    public static func responseDB(sections: [Double], atHz hz: Double, sampleRate: Double) -> Double {
        guard sampleRate > 0, hz > 0 else { return 0 }
        let w = 2 * Double.pi * hz / sampleRate
        let cos1 = cos(w), sin1 = sin(w)
        let cos2 = cos(2 * w), sin2 = sin(2 * w)
        var total: Double = 0

        for start in stride(from: 0, to: sections.count, by: 5) {
            let b0 = sections[start], b1 = sections[start + 1], b2 = sections[start + 2]
            let a1 = sections[start + 3], a2 = sections[start + 4]
            // z⁻¹ = cos(ω) − j·sin(ω), z⁻² = cos(2ω) − j·sin(2ω).
            let numeratorReal = b0 + b1 * cos1 + b2 * cos2
            let numeratorImag = -(b1 * sin1 + b2 * sin2)
            let denominatorReal = 1 + a1 * cos1 + a2 * cos2
            let denominatorImag = -(a1 * sin1 + a2 * sin2)
            let numeratorSq = numeratorReal * numeratorReal + numeratorImag * numeratorImag
            let denominatorSq = denominatorReal * denominatorReal + denominatorImag * denominatorImag
            guard numeratorSq > 0, denominatorSq > 0 else { continue }
            total += 10 * log10(numeratorSq / denominatorSq)
        }

        return total
    }

    /// The magnitude response of `eq` at `hz`, in dB — what the curve drawn in
    /// the Equalizer page shows. Balance is excluded: it is a channel trim, not
    /// a frequency-dependent one. Rebuilds the coefficient array on every call —
    /// callers evaluating many points should use ``responseSections(for:sampleRate:)``
    /// once and ``responseDB(sections:atHz:sampleRate:)`` per point instead.
    public static func responseDB(for eq: DeviceEQ, atHz hz: Double, sampleRate: Double) -> Double {
        responseDB(sections: responseSections(for: eq, sampleRate: sampleRate), atHz: hz, sampleRate: sampleRate)
    }

    private static func peaking(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> [Double] {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        return normalized(
            b0: 1 + alpha * a,
            b1: -2 * cos(w0),
            b2: 1 - alpha * a,
            a0: 1 + alpha / a,
            a1: -2 * cos(w0),
            a2: 1 - alpha / a)
    }

    private static func lowShelf(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> [Double] {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        return normalized(
            b0: a * ((a + 1) - (a - 1) * cos(w0) + twoSqrtAAlpha),
            b1: 2 * a * ((a - 1) - (a + 1) * cos(w0)),
            b2: a * ((a + 1) - (a - 1) * cos(w0) - twoSqrtAAlpha),
            a0: (a + 1) + (a - 1) * cos(w0) + twoSqrtAAlpha,
            a1: -2 * ((a - 1) + (a + 1) * cos(w0)),
            a2: (a + 1) + (a - 1) * cos(w0) - twoSqrtAAlpha)
    }

    private static func highShelf(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> [Double] {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        return normalized(
            b0: a * ((a + 1) + (a - 1) * cos(w0) + twoSqrtAAlpha),
            b1: -2 * a * ((a - 1) + (a + 1) * cos(w0)),
            b2: a * ((a + 1) + (a - 1) * cos(w0) - twoSqrtAAlpha),
            a0: (a + 1) - (a - 1) * cos(w0) + twoSqrtAAlpha,
            a1: 2 * ((a - 1) - (a + 1) * cos(w0)),
            a2: (a + 1) - (a - 1) * cos(w0) - twoSqrtAAlpha)
    }

    /// `vDSP_biquad` wants `a0` divided out and subtracts the `a` terms, which is
    /// exactly the cookbook's own normalized form.
    private static func normalized(
        b0: Double, b1: Double, b2: Double,
        a0: Double, a1: Double, a2: Double
    ) -> [Double] {
        [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }
}

// MARK: - Plan

/// What the capture coordinator applies to one delivered buffer: the Main Out
/// stage (before every fan-out, so the local Mac and Bluetooth inherit it), then
/// one write per AirPlay stream.
///
/// ``passthrough`` is the default and the ONLY shape that stays byte-identical:
/// no main stage, one write to stream 0 with no per-device stage.
public struct WholeSystemEQPlan: Sendable {

    public struct Stream: Sendable {
        public let streamID: UInt32
        public let processor: EQProcessor?

        public init(streamID: UInt32, processor: EQProcessor?) {
            self.streamID = streamID
            self.processor = processor
        }
    }

    public let main: EQProcessor?
    public let streams: [Stream]

    public init(main: EQProcessor?, streams: [Stream]) {
        self.main = main
        self.streams = streams
    }

    public static let passthrough = WholeSystemEQPlan(
        main: nil,
        streams: [Stream(streamID: 0, processor: nil)])

    /// True when the plan can be served by the existing single stream-0 write.
    public var isPassthrough: Bool {
        main == nil && streams.count == 1 && streams[0].streamID == 0 && streams[0].processor == nil
    }
}
