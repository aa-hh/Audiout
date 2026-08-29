// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design (PLAN-UNIVERSAL-SYNC Decision 5): this file carries NO
// GPL SPDX header, unlike most siblings. It is a fresh Apple-only implementation
// (AVFoundation + Core Audio) written for this project against the shared
// license-clean `SyncCore.swift` seams. The GPL-headered `SyncedLocalSink.swift`
// was studied for its architectural SHAPE only — no code was copied from it; the
// engine wiring and ring here are re-derived from the plan
// (`docs/plans/PLAN-UNIVERSAL-SYNC.md` E/F/G) and the spike findings
// (`dev/notes/bt-spike-findings-2026-08-07.md`). Do not add a GPL header to this
// file, and do not move GPL-derived code into it.

import AudioToolbox
import AVFoundation
import Foundation

// MARK: - BT-REFSEL — reference-timeline selection

/// Which kinds of outputs currently share the group with the Bluetooth devices.
/// Drives ``BTReferenceTimeline``'s choice of reference; recomputed (via a sink
/// rebuild) whenever the group's composition changes.
struct BTGroupComposition: Equatable, Sendable {
    /// At least one AirPlay receiver is streaming — its presentation timeline
    /// (authored by us as PTP grandmaster) is the one reference every other
    /// output delays to.
    var airPlayPresent: Bool
    /// The Mac's own speakers are in the mix. Deliberately carried even though
    /// it never changes a BT delay (see ``BTReferenceTimeline/delayNanos``):
    /// the "Mac joining changes nothing for BT" rule is explicit and testable
    /// instead of implicit in a missing parameter.
    var macLocalPresent: Bool
    /// CAST-SYNC: at least one Cast receiver is in the mix. Like AirPlay it
    /// authors a presentation timeline everything else delays to, so it selects
    /// the same reference branch — the room delay handed in, not the BT-only
    /// scheduling buffer. Defaulted so the many call sites that predate Cast
    /// read as what they are: compositions with no Cast device in them.
    var castPresent: Bool = false

    /// Whether the reference handed to ``BTReferenceTimeline`` is the room's
    /// presentation timeline (AirPlay and/or Cast author one) rather than the
    /// Mac's own host clock with a small scheduling buffer.
    var usesPresentationReference: Bool { airPlayPresent || castPresent }
}

/// The BT-REFSEL rule (plan §E): AirPlay present → the AirPlay presentation
/// timeline is the reference and each BT device delays by
/// `presentationDelay − perDeviceOffset (+ trim)`; BT-only (with or without the
/// Mac's own speakers) → the Mac `hostTime` timeline is the reference and the
/// presentation term is a small fixed scheduling buffer instead. Always clamped
/// ≥ 0 (inside `SyncTiming.totalDelayNanos`).
enum BTReferenceTimeline {

    /// `presentationDelayMs` MUST be the LIVE engine value
    /// (`currentPresentationDelayMs()`), never a hardcoded copy of the 250 ms
    /// constant — plan risk R4: a buffer-size tune must move the AirPlay
    /// schedule and every BT delay together.
    ///
    /// `deviceOffsetMs` is the device's own output latency (BT stack + speaker,
    /// ~100–400 ms in the wild): it plays that much LATE on its own, so we
    /// schedule it that much EARLIER. `trimMs` is the signed manual nudge
    /// (BT-OFFSET-UI persists it later).
    ///
    /// `macLocalPresent` never changes the result: with AirPlay present the
    /// AirPlay timeline stays the single reference (the Mac's own sink delays
    /// itself to it separately); without AirPlay the Mac IS the reference
    /// clock whether or not its speakers play.
    static func delayNanos(
        composition: BTGroupComposition,
        presentationDelayMs: Int,
        btOnlyBufferMs: Int,
        deviceOffsetMs: Int,
        trimMs: Double,
        castTermMs: Int? = nil
    ) -> Int64 {
        SyncTiming.totalDelayNanos(
            presentationDelayMs: roomDelayMs(
                composition: composition,
                presentationDelayMs: presentationDelayMs,
                btOnlyBufferMs: btOnlyBufferMs,
                castTermMs: castTermMs),
            localOutputLatencySeconds: Double(deviceOffsetMs) / 1_000,
            safetyMarginMs: 0,
            userOffsetMs: trimMs)
    }

    /// CAST-SYNC — the N-way generalisation of the rule above (sync
    /// architecture brief §3): the room delay `R` is the LONGEST intrinsic
    /// delay any active output has, and every output then delays itself by
    /// `R − its own intrinsic delay`. Delay-to-worst is the only workable
    /// direction, because no output's own latency can be shortened.
    ///
    /// `castTermMs` is how far behind live the furthest Cast receiver plays,
    /// or `nil` when no Cast device contributes a term. That `nil` is the
    /// invariant: an absent operand makes the `max` the identity, so every
    /// composition that ships today returns precisely the number it returns
    /// today — proven case by case rather than gated behind a flag.
    static func roomDelayMs(
        composition: BTGroupComposition,
        presentationDelayMs: Int,
        btOnlyBufferMs: Int,
        castTermMs: Int?
    ) -> Int {
        let reference = composition.usesPresentationReference
            ? presentationDelayMs : btOnlyBufferMs
        return castTermMs.map { Swift.max(reference, $0) } ?? reference
    }
}

// MARK: - Frame ring (delay line)

/// Single-producer / single-consumer wait-free ring of whole interleaved
/// FRAMES — the per-device delay line between the capture (producer) thread and
/// that device's render (consumer) thread. Monotonically-increasing head/tail
/// frame counters live in dedicated heap words (aligned word loads/stores are
/// atomic on Apple silicon) with `OSMemoryBarrier()` for acquire/release
/// ordering; the counters are masked only for addressing, so full-vs-empty is a
/// plain subtraction and the whole capacity is usable. The producer never
/// blocks and never splits a chunk: a chunk that does not fit is dropped
/// wholesale — and every such drop is counted (``droppedChunks``), which is
/// what makes "the ring ran dry / the ring overflowed" a fact in the log rather
/// than a guess.
final class BTFrameRing {
    private let channelCount: Int
    private let capacityFrames: Int
    private let frameMask: Int
    private let samples: UnsafeMutablePointer<Float>
    private let writeCounter: UnsafeMutablePointer<Int>   // producer-owned
    private let readCounter: UnsafeMutablePointer<Int>    // consumer-owned
    /// Chunks the producer dropped for lack of space, monotonic since init. A
    /// producer-owned word like `writeCounter` — one writer, so no atomics —
    /// read by whoever is surfacing it (the gate opening).
    private let dropCounter: UnsafeMutablePointer<Int>    // producer-owned

    init(minimumCapacityFrames: Int, channelCount: Int) {
        var capacity = 1
        while capacity < max(2, minimumCapacityFrames) { capacity <<= 1 }
        self.channelCount = max(1, channelCount)
        self.capacityFrames = capacity
        self.frameMask = capacity - 1
        let sampleCount = capacity * self.channelCount
        self.samples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        self.samples.initialize(repeating: 0, count: sampleCount)
        self.writeCounter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        self.readCounter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        self.dropCounter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        writeCounter.initialize(to: 0)
        readCounter.initialize(to: 0)
        dropCounter.initialize(to: 0)
    }

    deinit {
        samples.deallocate()
        writeCounter.deallocate()
        readCounter.deallocate()
        dropCounter.deallocate()
    }

    /// Frames written but not yet read. Two aligned word loads, so it is safe
    /// from any thread; a cycle stale at worst, which every caller allows for.
    var usedFrames: Int {
        OSMemoryBarrier()
        return writeCounter.pointee &- readCounter.pointee
    }

    /// Chunks dropped since init. Monotonic on purpose: the consumer takes
    /// differences against its own baseline rather than zeroing a word it does
    /// not own.
    var droppedChunks: Int {
        OSMemoryBarrier()
        return dropCounter.pointee
    }

    /// Producer side; real-time safe (no allocation, no locks). Returns false
    /// when the chunk was dropped for lack of space.
    @discardableResult
    func write(interleavedFrames src: UnsafePointer<Float>, frameCount: Int) -> Bool {
        guard frameCount > 0 else { return true }
        let w = writeCounter.pointee
        OSMemoryBarrier()                       // acquire: see the consumer's counter
        let used = w &- readCounter.pointee
        guard frameCount <= capacityFrames &- used else {
            dropCounter.pointee = dropCounter.pointee &+ 1
            return false
        }
        var copied = 0
        while copied < frameCount {
            let dstFrame = (w &+ copied) & frameMask
            let span = min(frameCount - copied, capacityFrames - dstFrame)
            samples.advanced(by: dstFrame * channelCount)
                .update(from: src.advanced(by: copied * channelCount), count: span * channelCount)
            copied += span
        }
        OSMemoryBarrier()                       // release: publish data before the counter
        writeCounter.pointee = w &+ frameCount
        return true
    }

    /// Consumer side: copies exactly one interleaved frame, or returns false on
    /// empty. Shaped for `FractionalResampler.render`'s `pullFrame`.
    func readFrame(into dst: UnsafeMutablePointer<Float>) -> Bool {
        let r = readCounter.pointee
        OSMemoryBarrier()                       // acquire: see the producer's data
        guard writeCounter.pointee &- r > 0 else { return false }
        dst.update(from: samples.advanced(by: (r & frameMask) * channelCount), count: channelCount)
        OSMemoryBarrier()                       // release: finish the copy before the counter
        readCounter.pointee = r &+ 1
        return true
    }

    /// Move the read position by `frames` (negative = replay history, positive
    /// = skip ahead) and return the delta actually applied after clamping.
    /// Backward it reaches as far as the intact history behind the read pointer
    /// — `capacity − used`, which is real audio precisely because the producer
    /// drops a chunk rather than overwrite unread data. Forward it stops at the
    /// write pointer.
    ///
    /// CONSUMER THREAD ONLY. `readCounter` has exactly one writer — the
    /// consumer — so moving it needs no lock and cannot race the producer,
    /// which only ever reads it. A seek merely makes the ring look fuller
    /// (backward) or emptier (forward), both of which the producer's existing
    /// space check already handles.
    @discardableResult
    func seek(byFrames frames: Int) -> Int {
        guard frames != 0 else { return 0 }
        let r = readCounter.pointee
        OSMemoryBarrier()                       // acquire: see the producer's counter
        let used = writeCounter.pointee &- r
        let applied = frames < 0
            ? -min(-frames, capacityFrames &- used)
            : min(frames, used)
        guard applied != 0 else { return 0 }
        OSMemoryBarrier()                       // release: reads land before the producer can reclaim
        readCounter.pointee = r &+ applied
        return applied
    }

    /// Drop everything buffered. Only while neither thread is active (engine
    /// stopped / offline tests).
    func reset() {
        OSMemoryBarrier()
        readCounter.pointee = writeCounter.pointee
        OSMemoryBarrier()
    }
}

/// The consumer's view of one device's delay line: the ring plus the seek and
/// crossfade state that let a trim change land while the music plays.
///
/// The delay physically IS the audio piled up in the ring at the moment the
/// release gate opened (PLAN-BT-SYNC-DRAWER §2), so once a device is audible
/// the only lever left is the read position. This type owns that move and hides
/// it behind the ring's own one-frame read, so `FractionalResampler.render`'s
/// `pullFrame` closure never learns a seek happened.
///
/// Thread contract, an extension of the ring's own: `write` is producer-only,
/// `readFrame` is consumer-only, `requestShift` is control-thread-only (one
/// serial queue, so it is the single writer of its counter). `readFrame` runs
/// on the render thread and is REAL-TIME: no allocation, no locks, no logging,
/// no Obj-C messaging — the same contract `BTDeviceSink.render` documents.
final class BTDelayLine {

    /// 5 ms. Long enough that a splice in music is inaudible, short enough that
    /// a fast scrub's overlapping shifts stay perceptually continuous.
    static let crossfadeMs: Double = 5

    private let ring: BTFrameRing
    private let channelCount: Int
    private let crossfadeFrames: Int

    /// The output being faded OUT (captured from the pre-seek position), and
    /// the buffer the next capture writes into. TWO buffers, swapped rather
    /// than copied, so a shift arriving mid-fade can read the old tail and
    /// write the new one in the same pass with no aliasing to reason about.
    private var fadeOutFrames: UnsafeMutablePointer<Float>
    private var captureFrames: UnsafeMutablePointer<Float>
    /// How many frames of `fadeOutFrames` are valid, and how far through them
    /// the fade has got. `fadeIndex == fadeLength` means no fade is running.
    private var fadeLength = 0
    private var fadeIndex = 0

    /// Two monotonically-increasing words with exactly ONE writer each — the
    /// same discipline as the ring's head/tail counters, and the reason this
    /// needs no atomics. A single "pending" word that the control thread
    /// accumulates into and the render thread zeroes would have two writers and
    /// could silently swallow a shift mid-scrub; here the consumer only ever
    /// advances its own word to a value it has already read.
    private let requestedShiftFrames: UnsafeMutablePointer<Int>   // control-thread-owned
    private let appliedShiftFrames: UnsafeMutablePointer<Int>     // consumer-owned
    /// The ring's drop total as of the last ``takeDroppedChunks()``. Only the
    /// consumer side touches it, so differencing a producer-owned monotonic
    /// word needs no atomics on either end.
    private var dropBaseline = 0

    init(minimumCapacityFrames: Int, channelCount: Int, crossfadeFrames: Int) {
        let channels = max(1, channelCount)
        self.ring = BTFrameRing(
            minimumCapacityFrames: minimumCapacityFrames, channelCount: channels)
        self.channelCount = channels
        self.crossfadeFrames = max(1, crossfadeFrames)
        let sampleCount = self.crossfadeFrames * channels
        self.fadeOutFrames = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        self.captureFrames = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        self.fadeOutFrames.initialize(repeating: 0, count: sampleCount)
        self.captureFrames.initialize(repeating: 0, count: sampleCount)
        self.requestedShiftFrames = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        self.appliedShiftFrames = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        self.requestedShiftFrames.initialize(to: 0)
        self.appliedShiftFrames.initialize(to: 0)
    }

    deinit {
        fadeOutFrames.deallocate()
        captureFrames.deallocate()
        requestedShiftFrames.deallocate()
        appliedShiftFrames.deallocate()
    }

    /// Producer side; forwards straight to the ring.
    @discardableResult
    func write(interleavedFrames src: UnsafePointer<Float>, frameCount: Int) -> Bool {
        ring.write(interleavedFrames: src, frameCount: frameCount)
    }

    /// Ask the render thread to move the read position by `frames` (negative =
    /// replay history = a LONGER delay). Non-blocking and lossless: the word
    /// only ever grows by the requested amount, so a fast scrub's shifts
    /// accumulate instead of a newer one overwriting one not yet consumed.
    /// Control thread ONLY.
    func requestShift(frames: Int) {
        guard frames != 0 else { return }
        requestedShiftFrames.pointee = requestedShiftFrames.pointee &+ frames
        OSMemoryBarrier()                       // release: publish before the consumer's acquire
    }

    /// Consumer side: exactly one interleaved frame, false on empty. Shaped for
    /// `FractionalResampler.render`'s `pullFrame`, which is why the seek has to
    /// live behind it rather than beside it.
    func readFrame(into dst: UnsafeMutablePointer<Float>) -> Bool {
        applyPendingShift()
        let hasFrame = ring.readFrame(into: dst)
        guard fadeIndex < fadeLength else { return hasFrame }
        // Ring dry mid-fade: the new side contributes zero, so the crossfade
        // degrades to a plain fade-out of the old tail. Still click-free, which
        // returning `false` here (an abrupt cut) would not be.
        if !hasFrame { dst.update(repeating: 0, count: channelCount) }
        mixFadeStep(into: dst)
        return true
    }

    /// Consumer side: drop up to `frames` of buffered content outright and
    /// report how many were actually dropped (the ring clamps at the write
    /// pointer). No crossfade — the one caller is the release gate, where
    /// nothing has been emitted yet for a splice to be continuous WITH.
    ///
    /// Deliberately not routed through ``requestShift(frames:)``: that word has
    /// exactly one writer, the control thread, and the render thread joining it
    /// would make two. The ring's own seek is already consumer-owned, which the
    /// render thread is. Real-time safe — counter arithmetic, no copying.
    @discardableResult
    func skipForward(frames: Int) -> Int {
        frames > 0 ? ring.seek(byFrames: frames) : 0
    }

    /// How far the read pointer could still travel FORWARD before it reaches
    /// the write pointer — the buffered frames, less any shift the control
    /// thread has already asked for and the render thread has not consumed yet
    /// (a fast scrub's shifts accumulate, so ignoring them would let two
    /// requests each spend the same room). Control thread ONLY, and advisory:
    /// the producer is adding frames concurrently, so this is a floor, never an
    /// over-estimate.
    func forwardShiftRoomFrames() -> Int {
        OSMemoryBarrier()                       // acquire: see the consumer's word
        let unconsumed = requestedShiftFrames.pointee &- appliedShiftFrames.pointee
        return ring.usedFrames &- unconsumed
    }

    /// Chunks the producer dropped since the last call. Consumer/control side.
    func takeDroppedChunks() -> Int {
        let total = ring.droppedChunks
        defer { dropBaseline = total }
        return total &- dropBaseline
    }

    /// Drop everything buffered and any un-consumed shift. Only while neither
    /// thread is active (engine stopped / offline tests) — the ring's contract.
    func reset() {
        ring.reset()
        appliedShiftFrames.pointee = requestedShiftFrames.pointee
        dropBaseline = ring.droppedChunks
        fadeLength = 0
        fadeIndex = 0
    }

    /// Take whatever shift the control thread has asked for since the last
    /// call, move the read position by it, and arm the crossfade that hides the
    /// splice.
    private func applyPendingShift() {
        OSMemoryBarrier()                       // acquire: see the control thread's word
        let requested = requestedShiftFrames.pointee
        let delta = requested &- appliedShiftFrames.pointee
        guard delta != 0 else { return }
        appliedShiftFrames.pointee = requested

        // Capture what the output WOULD have been for the next `crossfadeFrames`
        // frames — mixing any fade still in flight, so overlapping shifts during
        // a fast scrub always fade from the real current output and never leave
        // one half-applied — then rewind the peek before the real seek.
        var captured = 0
        while captured < crossfadeFrames {
            let slot = captureFrames + captured * channelCount
            guard ring.readFrame(into: slot) else { break }
            if fadeIndex < fadeLength { mixFadeStep(into: slot) }
            captured += 1
        }
        ring.seek(byFrames: -captured)          // rewind the peek
        ring.seek(byFrames: delta)              // then the shift the user asked for

        // Swapped by hand rather than with `swap(&_:&_:)`: that takes both
        // properties `inout`, which on a class is an exclusivity-checked access,
        // and this runs on the render thread.
        let previousTail = fadeOutFrames
        fadeOutFrames = captureFrames
        captureFrames = previousTail
        fadeLength = captured
        fadeIndex = 0
    }

    /// One crossfade step, in place: `dst` holds the new (post-seek) side on
    /// entry and the mixed output on exit. Caller has checked a fade is running.
    ///
    /// Equal-power (`cos² + sin² = 1`) rather than linear, because the two
    /// sides are two different stretches of the same music and so are
    /// uncorrelated: a linear pair sums to a 3 dB dip in the middle, which is
    /// audible as a hole. The fade runs over `fadeLength`, not the nominal
    /// `crossfadeFrames`, so a fade shortened by a near-dry ring still
    /// completes instead of ending part-way up the curve.
    private func mixFadeStep(into dst: UnsafeMutablePointer<Float>) {
        let old = fadeOutFrames + fadeIndex * channelCount
        let theta = Double.pi / 2 * Double(fadeIndex) / Double(fadeLength)
        let fadeOut = Float(cos(theta)), fadeIn = Float(sin(theta))
        for ch in 0..<channelCount { dst[ch] = old[ch] * fadeOut + dst[ch] * fadeIn }
        fadeIndex += 1
    }
}

// MARK: - Per-device sink

enum BTDeviceSinkError: Error, CustomStringConvertible {
    /// AVAudioEngine SILENTLY NO-OPS when pinned to an aggregate device
    /// (spike-verified): everything reports success and no audio flows. Refuse
    /// up front instead of debugging silence later.
    case aggregateDevice
    case engineNotRunning

    var description: String {
        switch self {
        case .aggregateDevice: return "aggregate/virtual devices silently no-op under AVAudioEngine"
        case .engineNotRunning: return "engine not running after start"
        }
    }
}

/// One Bluetooth device's delayed render endpoint (BT-SINK): an `AVAudioEngine`
/// pinned to that device via `outputNode.auAudioUnit.setDeviceID` (spike-proven;
/// pinned BEFORE the first start), whose `AVAudioSourceNode` stays silent until
/// the reference timeline reaches `capture_pts + delay`, then drains the ring
/// through the shared `FractionalResampler` at unity rate.
///
/// There is no drift correction: A2DP sinks servo to the host delivery rate, and
/// measured inter-speaker drift was −0.02 ppm (≈ 0 over 30 minutes) on
/// 2026-08-12, so a fixed trim holds for a whole session.
///
/// NEVER install a tap on `engine.outputNode` — that raises an uncatchable
/// AVFAudio exception at install time (spike gotcha, live-verified); if a tap
/// is ever needed here, it goes on `mainMixerNode`.
///
/// `@unchecked Sendable`: producer (enqueue) and consumer (render) meet only
/// through the wait-free ``BTFrameRing``; the scalar gate state is behind
/// `stateLock`, taken non-blockingly on the render path. Graph mutation is
/// serialized on `graphQueue`.
///
/// Lock order: a device's `stateLock` may take the manager's table lock (the
/// one-time anchor samples `delayNanosProvider`); the manager must NEVER call
/// into a sink while holding its table lock.
final class BTDeviceSink: @unchecked Sendable {

    let deviceID: AudioObjectID
    let deviceUID: String
    let renderSampleRate: Double
    private let channelCount: Int
    private let maxRenderFrames: Int
    /// Sampled at the anchor (on the enqueue thread) and again on a pre-release
    /// trim change (``applyTrimDelta(ms:)``) — never on the render path. A
    /// structural delay change (offset, composition, rate) still lands via
    /// `requestRebuild(cause:)` + re-anchor.
    private let delayNanosProvider: @Sendable () -> Int64

    // Producer/consumer state.
    private let delayLine: BTDelayLine
    private let resampler: FractionalResampler
    private let stateLock = NSLock()
    private var anchored = false
    private var released = false
    /// The capture pts the session anchored on, kept so a pre-release trim
    /// change can recompute the target through the same one expression the
    /// anchor used instead of nudging the old value by hand.
    private var anchorPtsNanos: Int64 = 0
    private var targetReleaseNanos: Int64 = 0
    /// The pts→playout mapping the session is actually running on:
    /// `targetReleaseNanos − anchorPtsNanos`, kept as its own field so a rebuild
    /// can carry it (below) instead of re-deriving it from a provider whose
    /// inputs moved. Maintained at the anchor and by ``applyTrimDelta(ms:)``.
    private var sessionDelayNanos: Int64 = 0
    /// Set when a `config_change` rebuild tore down an anchored session: the
    /// next anchor uses THIS delay instead of asking the provider, so adding or
    /// removing a speaker cannot shift an alignment the user has already made
    /// by ear (spec Part 3a). Every other rebuild cause clears it — those ARE
    /// new timeline contexts and must re-derive.
    private var pendingCarriedDelayNanos: Int64?
    /// A consumed carry waiting to be logged. `enqueue` runs on the capture
    /// tap's real-time thread, where `Telemetry.log`'s dictionary and
    /// `String(format:)` allocations could overrun the tap deadline at exactly
    /// the moment the carry exists to protect — so the anchor only records the
    /// fact here and `graphQueue` emits it.
    private var carryToLogNanos: Int64?
    /// What the release gate did when it opened, waiting to be logged. Same
    /// reason as `carryToLogNanos`, one thread stricter: this one is recorded on
    /// the RENDER thread, which must not allocate, format or log — so the
    /// numbers are stashed here and `graphQueue` emits them.
    private struct ReleaseRecord {
        let overshootNanos: Int64
        let caughtUpFrames: Int
        let partial: Bool
        /// Producer chunks dropped since the previous gate opening — the ring's
        /// overflow counter, surfaced on the same once-per-gate cadence.
        let droppedChunks: Int
    }
    private var releaseToLog: ReleaseRecord?
    /// An anchor (carried or fresh) waiting to be logged. Same reason as
    /// `carryToLogNanos`: `enqueue` runs on the capture tap's real-time
    /// thread, which must not allocate/format/log, so the anchor's facts are
    /// stashed here and `graphQueue` emits them. Not cleared by the
    /// session-reset path — a recorded anchor is history, same as the carry
    /// line.
    private struct AnchorRecord {
        let anchorPtsNanos: Int64
        let delayNanos: Int64
    }
    private var anchorToLog: AnchorRecord?

    /// How close a forward seek may bring the read pointer to the write
    /// pointer. A forward seek IS how a larger measured latency lands, and one
    /// that reaches the write pointer leaves the ring dry with no way back —
    /// the wizard's permanent silence (roadmap 056). 100 ms is a few render
    /// cycles' worth of headroom, well below the smallest reference.
    static let seekSafetyMarginMs: Double = 100

    // Engine (all mutation on `graphQueue`).
    private let graphQueue: DispatchQueue
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let connectionFormat: AVAudioFormat
    private var running = false
    /// Current render gain (graphQueue). 1 unless the hold-silent path set it.
    private var gain: Float = 1
    /// This device's tone (graphQueue). Stored so a rebuild re-derives its
    /// processor at whatever rate the device comes back on.
    private var eq: DeviceEQ = .flat
    /// The baked processor the render path applies, published under `stateLock`
    /// like `driftPpm`. `nil` = flat, and flat stays untouched audio.
    private var eqProcessor: EQProcessor?   // stateLock
    private var configChangeObserver: NSObjectProtocol?
    private var rateListenerBlock: AudioObjectPropertyListenerBlock?
    private let listenerQueue: DispatchQueue
    /// Interleaved render scratch (the source node's connection format is
    /// deinterleaved standard Float32 — an interleaved source-node format blows
    /// up in Core Audio with an uncatchable -10868; render fills this
    /// interleaved buffer, then deinterleaves into the node's planes).
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int

    /// The device's live nominal sample rate, re-read on every (re)start. Only
    /// the HFP-collapse detection below reads it — there is no drift loop.
    private var nominalRate: Double
    /// R-A2DP/HFP: `true` while the device's nominal rate reads narrowband
    /// (≤ 24 kHz — the mic-open HFP collapse). Set on every (re)start from the
    /// live rate; the rate listener's rebuild is what refreshes it both ways.
    private(set) var hfpDegraded = false
    /// Diagnostics only — gates ``bt_device_reported_latency`` to once per
    /// connect: a rebuild restarts the same physical connection, not a new
    /// one, so this must not reset in ``clearSessionStateLocked(carryDelay:)``.
    private var hasLoggedReportedLatency = false

    init(
        deviceID: AudioObjectID,
        deviceUID: String,
        renderSampleRate: Double,
        channelCount: Int,
        // CAST-SYNC capacity (sync architecture brief §6): the ring IS the
        // delay line, so it must hold the deepest room delay the Cast policy
        // can ask for (9.5 s) plus the BT-only buffer. 11 s and 8 s both round
        // up to the same 2^19 frames, so this costs nothing.
        maxBufferedSeconds: Double = 11,
        maxRenderFrames: Int = 8192,
        delayNanosProvider: @escaping @Sendable () -> Int64
    ) {
        let channels = max(1, channelCount)
        self.deviceID = deviceID
        self.deviceUID = deviceUID
        self.renderSampleRate = renderSampleRate
        self.channelCount = channels
        self.maxRenderFrames = max(1, maxRenderFrames)
        self.delayNanosProvider = delayNanosProvider
        self.nominalRate = renderSampleRate
        self.graphQueue = DispatchQueue(label: "com.audiout.btsink.graph.\(deviceUID)")
        self.listenerQueue = DispatchQueue(label: "com.audiout.btsink.listener.\(deviceUID)")

        // The delay line must hold the full delay's worth of pre-roll (the
        // BT-only buffer or the ~2 s AirPlay presentation delay) AND, behind
        // the read pointer, enough history for a live trim to seek back into.
        // 8 s rounds up to 11.9 s of ring at 44.1 kHz, so a 500 ms delay still
        // leaves ~11 s of replayable history — far more than the ±500 ms trim.
        self.delayLine = BTDelayLine(
            minimumCapacityFrames: Int((maxBufferedSeconds * renderSampleRate).rounded()),
            channelCount: channels,
            crossfadeFrames: Int((BTDelayLine.crossfadeMs / 1_000 * renderSampleRate).rounded()))
        self.resampler = FractionalResampler(channelCount: channels)
        self.scratchCapacity = self.maxRenderFrames * channels
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        self.scratch.initialize(repeating: 0, count: scratchCapacity)

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: renderSampleRate,
            channels: AVAudioChannelCount(channels))
        else {
            fatalError("BTDeviceSink: no standard \(renderSampleRate)/\(channels)ch format")
        }
        self.connectionFormat = format
    }

    deinit {
        // Direct, no graphQueue hop: a pending `requestRebuild` block retains
        // self, so deinit can run ON graphQueue (as that last block releases
        // the final reference) — a `graphQueue.sync` here would deadlock. By
        // deinit nothing else references the sink, so the direct calls are
        // exclusive whichever thread this runs on.
        stopLocked()
        scratch.deallocate()
    }

    // MARK: Lifecycle

    /// Pin to the device and start the engine (idempotent). Throws on an
    /// aggregate/virtual device (silent no-op trap) or a failed start.
    func start() throws {
        try graphQueue.sync { try startLocked() }
    }

    func stop() {
        graphQueue.sync { stopLocked() }
    }

    /// Tear down and (if the sink was running) rebuild against the device's
    /// current configuration — a config change or nominal-rate renegotiation
    /// (the silent-tap bug family applied to BT: a rebuilt route keeps "working"
    /// while the timeline it renders on has moved) voids the session anchor.
    func requestRebuild(cause: String) {
        graphQueue.async { self.rebuildLocked(cause: cause) }
    }

    /// This device's render gain (W3 hold-silent + first-mix intercept):
    /// applied to `mainMixerNode.outputVolume`, the stock AVAudioEngine level
    /// stage between the source node and the pinned output — so 0 keeps the
    /// whole session (anchor, delay gate) running while the
    /// speaker stays silent, and releasing the hold is a glitch-free property
    /// write, not a rebuild. Stored so a rebuild's fresh `startLocked` pass
    /// re-applies it.
    func setGain(_ gain: Float) {
        graphQueue.async {
            self.gain = gain
            self.engine.mainMixerNode.outputVolume = gain
        }
    }

    /// This device's tone. Like the gain above, a live session absorbs it as a
    /// property swap — the coefficients are baked into a NEW ``EQProcessor``
    /// built here on `graphQueue` (never on the render thread, and never by
    /// re-parameterizing a live one, whose biquad state belongs to the render
    /// thread alone) and published under the same `stateLock` snapshot the drift
    /// figure uses. Stored so a rebuild's fresh `startLocked` pass re-derives it
    /// at whatever rate the device came back on.
    func setEQ(_ eq: DeviceEQ) {
        graphQueue.async {
            self.eq = eq
            self.rebuildEQProcessorLocked()
        }
    }

    /// Bake `eq` for the CURRENT render rate and publish it to the render path.
    /// A flat setting publishes `nil` — a flat device must never be filtered.
    /// Stereo only: ``EQProcessor`` is interleaved-stereo by construction, so a
    /// mono/multichannel sink simply runs untouched. On `graphQueue`.
    private func rebuildEQProcessorLocked() {   // on graphQueue
        let processor: EQProcessor? = (eq.isFlat || channelCount != 2)
            ? nil
            : EQProcessor(eq: eq, sampleRate: renderSampleRate)
        stateLock.withLock { eqProcessor = processor }
    }

    private func startLocked() throws {
        guard !running else { return }
        if let transport = Self.transportType(deviceID),
           transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeAutoAggregate
            || transport == kAudioDeviceTransportTypeVirtual {
            Telemetry.log(.localPlayback, "bt_sink_refused_aggregate", ["uid": deviceUID])
            throw BTDeviceSinkError.aggregateDevice
        }
        // Pin BEFORE the first start — a pin after start is silently ignored.
        // A failed transport read above falls OPEN (a momentarily unreadable
        // real speaker must not be refused); the pin below still targets the
        // exact device either way.
        try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
        if !hasLoggedReportedLatency {
            hasLoggedReportedLatency = true
            if let measurement = try? LocalOutputLatency.measure(deviceID: deviceID) {
                Telemetry.log(.localPlayback, "bt_device_reported_latency", [
                    "uid": deviceUID,
                    "ms": String(Int(measurement.totalMilliseconds.rounded())),
                ])
            }
        }
        if let liveRate = Self.nominalSampleRate(deviceID) { nominalRate = liveRate }
        // R-A2DP/HFP (Wave 4, detection only): a narrowband nominal rate means
        // some app opened this device's MIC and macOS collapsed the link to
        // HFP — audio is degraded until the mic closes, when the rate listener
        // rebuilds us right back through here and the flag clears. The UI badge
        // hangs off this in the UI wave; policy stays "keep playing, degraded"
        // — silent rows read as broken, degraded ones read as a call.
        hfpDegraded = nominalRate <= 24_000
        if hfpDegraded {
            Telemetry.log(.localPlayback, "bt_sink_hfp_degraded", [
                "uid": deviceUID, "rate": "\(nominalRate)",
            ])
        }

        let node = sourceNode ?? makeSourceNode()
        sourceNode = node
        if node.engine == nil { engine.attach(node) }
        try catchingObjCException {
            engine.connect(node, to: engine.mainMixerNode, format: connectionFormat)
        }
        engine.mainMixerNode.outputVolume = gain
        // Re-derive the tone from the remembered value, exactly as the gain
        // above is re-applied: a rebuild throws away the old processor along
        // with the session, and the device may have come back on a different
        // configuration.
        rebuildEQProcessorLocked()
        engine.prepare()
        try engine.start()
        running = engine.isRunning
        guard running else { throw BTDeviceSinkError.engineNotRunning }
        installEventListenersLocked()
    }

    private func stopLocked(carryDelay: Bool = false) {
        removeEventListenersLocked()
        if running || engine.isRunning {
            sourceNode?.reset()
            engine.stop()
        }
        running = false
        // Anchored, i.e. the session was actually handed audio — a sink that
        // never produced has no ring history worth a line.
        if stateLock.withLock({ anchored }) {
            // The OTHER moment the ring's overflow count is worth knowing.
            // Surfaced only at gate openings it never reached a wizard run's log
            // at all (live report, 2026-08-22): a run has exactly one gate
            // opening and it is at the start, so every drop after it went
            // unreported. Every `stopLocked` caller — `stop()`, `rebuildLocked`,
            // `deinit` — is already off the render and tap threads, which is the
            // whole reason the gate's own line has to be stashed and posted
            // later and this one does not.
            Telemetry.log(.localPlayback, "bt_sink_ring_drops", [
                "uid": deviceUID,
                "chunks": String(delayLine.takeDroppedChunks()),
                "at": "session_end",
            ])
        }
        clearSessionStateLocked(carryDelay: carryDelay)
    }

    private func rebuildLocked(cause: String) {
        let wasRunning = running
        // Part 3a: a lineup change (`config_change`) is the SAME timeline with a
        // different set of speakers on it, so the session's pts→playout mapping
        // survives it. Every other cause is a genuinely new context and
        // re-derives from the provider.
        stopLocked(carryDelay: cause == "config_change")
        Telemetry.log(.localPlayback, "bt_sink_rebuild", ["uid": deviceUID, "cause": cause])
        guard wasRunning else { return }
        do {
            try startLocked()
        } catch {
            Telemetry.log(.localPlayback, "bt_sink_restart_failed", [
                "uid": deviceUID, "cause": cause, "error": String(describing: error),
            ])
        }
    }

    /// Whether the delay gate has OPENED — this device is emitting real audio,
    /// not pre-release silence. A started engine is not yet audible (the gate
    /// holds silence for the whole reference delay), so this, not `running`, is
    /// the "music is playing here" fact the Bluetooth row's `.connecting →
    /// .connected` promotion waits on. Read off the render thread; the render
    /// path itself only ever takes `stateLock` non-blockingly, so this read
    /// cannot stall it. A rebuild clears it along with the rest of the session.
    var hasStartedRendering: Bool { stateLock.withLock { released } }

    /// Whether this sink has been handed any captured audio at all. False the
    /// whole time the Mac is silent — see ``BTSyncedSink/anchoredDeviceUIDs()``.
    var hasAnchored: Bool { stateLock.withLock { anchored } }

    /// Test seam: the delay (ns) the CURRENT session actually anchored on, read
    /// straight off the gate rather than off the bookkeeping field, so a carry
    /// that failed to reach `targetReleaseNanos` cannot pass.
    var test_anchoredDelayNanos: Int64 {
        stateLock.withLock { targetReleaseNanos &- anchorPtsNanos }
    }

    /// Test seam: block until any `requestRebuild` queued so far has run.
    func test_waitForPendingRebuild() { graphQueue.sync {} }

    /// Test seam: the tone this sink is holding — proof that a value remembered
    /// by the manager before this sink existed actually reached it.
    var eqForTesting: DeviceEQ { graphQueue.sync { eq } }

    /// Void the session (anchor, ring, resampler). The render thread is stopped
    /// by every caller (engine down), so resetting the render-owned resampler is
    /// safe.
    ///
    /// `carryDelay` stashes the session's delay for the next anchor to reuse
    /// (Part 3a). Stashing and clearing happen in ONE `stateLock` critical
    /// section on purpose: `enqueue` runs concurrently on the tap thread and may
    /// re-anchor the instant `anchored` clears, so a two-step read-then-clear
    /// could hand that anchor the provider's value instead of the carried one.
    private func clearSessionStateLocked(carryDelay: Bool = false) {
        stateLock.withLock {
            // A carrying cause only OVERWRITES the stash when there is a live
            // session to take the delay from; back-to-back `config_change`
            // rebuilds with no enqueue in between (paused music, or the
            // multi-fire `AVAudioEngineConfigurationChange` a single route
            // change produces) find `anchored` already false and must keep the
            // first rebuild's stash rather than drop the alignment.
            if carryDelay {
                if anchored { pendingCarriedDelayNanos = sessionDelayNanos }
            } else {
                pendingCarriedDelayNanos = nil
            }
            anchored = false
            released = false
            anchorPtsNanos = 0
            targetReleaseNanos = 0
            sessionDelayNanos = 0
        }
        delayLine.reset()
        resampler.reset()
    }

    // MARK: Producer (capture → delay line)

    /// Enqueue one captured block of interleaved Float32 frames with its
    /// capture `pts` (`CLOCK_MONOTONIC` — the same `CapturedBuffer.pts`
    /// timeline the AirPlay sessions consume). Called on the tap delivery
    /// thread; real-time safe — a wait-free ring write plus a one-time
    /// non-blocking anchor set (a missed `try()` defers the anchor one buffer:
    /// a sub-ms pts shift, never a wrong order). Format conversion to this
    /// sink's rate/channel layout is the caller's job (BT-FANOUT).
    func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {
        guard frameCount > 0 else { return }
        var carriedDelayNanos: Int64?
        var hasReleaseToLog = false
        var hasAnchorToLog = false
        if stateLock.try() {
            if !anchored {
                anchored = true
                anchorPtsNanos = SyncTiming.monotonicNanos(pts)
                carriedDelayNanos = pendingCarriedDelayNanos
                pendingCarriedDelayNanos = nil
                // Only a real carry overwrites the pending line. A plain
                // anchor must not clobber a stashed record whose emit block
                // has not run yet — that would drop the line the live check
                // reads.
                if carriedDelayNanos != nil { carryToLogNanos = carriedDelayNanos }
                let delayNanos = carriedDelayNanos ?? delayNanosProvider()
                sessionDelayNanos = delayNanos
                targetReleaseNanos = SyncTiming.targetReleaseMonotonicNanos(
                    anchorPtsNanos: anchorPtsNanos,
                    totalDelayNanos: delayNanos)
                anchorToLog = AnchorRecord(anchorPtsNanos: anchorPtsNanos, delayNanos: delayNanos)
            }
            // The render thread cannot hand its own record to `graphQueue`
            // (dispatch allocates), so the producer — which is here every
            // buffer anyway, and already takes this lock — posts it instead.
            hasReleaseToLog = releaseToLog != nil
            hasAnchorToLog = anchorToLog != nil
            stateLock.unlock()
        }
        delayLine.write(interleavedFrames: interleavedFrames, frameCount: frameCount)
        if carriedDelayNanos != nil || hasReleaseToLog || hasAnchorToLog {
            // Once per lineup change / once per gate opening / once per
            // anchor, never per buffer, and never ON this thread — see
            // `carryToLogNanos`.
            graphQueue.async { [weak self] in
                self?.emitPendingCarryTelemetry()
                self?.emitPendingReleaseTelemetry()
                self?.emitPendingAnchorTelemetry()
            }
        }
    }

    /// Emit the carry line for a carry the anchor consumed. `graphQueue` — off
    /// the tap's real-time thread. Also drained by `test_waitForPendingRebuild`.
    private func emitPendingCarryTelemetry() {
        guard let carriedDelayNanos = stateLock.withLock({
            defer { carryToLogNanos = nil }
            return carryToLogNanos
        }) else { return }
        // This is the line the live check reads to confirm the alignment
        // survived the rebuild.
        Telemetry.log(.localPlayback, "bt_sink_anchor_carried", [
            "uid": deviceUID,
            "delayMs": String(format: "%.1f", Double(carriedDelayNanos) / 1_000_000),
        ])
    }

    /// Emit the anchor line for an anchor `enqueue` just recorded — carried or
    /// fresh, every time. `graphQueue` — off the tap's real-time thread, same
    /// reason as `emitPendingCarryTelemetry`. Also drained by
    /// `test_waitForPendingRebuild`.
    private func emitPendingAnchorTelemetry() {
        guard let anchor = stateLock.withLock({
            defer { anchorToLog = nil }
            return anchorToLog
        }) else { return }
        Telemetry.log(.localPlayback, "bt_sink_anchored", [
            "uid": deviceUID,
            "anchorPtsNanos": "\(anchor.anchorPtsNanos)",
            "delayNanos": "\(anchor.delayNanos)",
        ])
    }

    /// Emit the release-gate line for a gate that has opened. `graphQueue` —
    /// off the render thread that recorded it, for the same reason
    /// `carryToLogNanos` exists.
    ///
    /// Emitted for a CLEAN start too (`overshootMs` 0). A zero line is the
    /// evidence that the session's engine start did not eat into the delay;
    /// without it, "no line" would be indistinguishable from "never released".
    private func emitPendingReleaseTelemetry() {
        guard let record = stateLock.withLock({
            defer { releaseToLog = nil }
            return releaseToLog
        }) else { return }
        Telemetry.log(.localPlayback, "bt_sink_release_overshoot", [
            "uid": deviceUID,
            "overshootMs": String(format: "%.1f", Double(record.overshootNanos) / 1_000_000),
            "caughtUpMs": String(
                format: "%.1f", Double(record.caughtUpFrames) / renderSampleRate * 1_000),
            "partial": record.partial ? "1" : "0",
        ])
        // Its own line, on the same once-per-gate cadence and for the same
        // reason a zero overshoot is worth printing: "0" is the evidence the
        // producer kept up, which "no line at all" could never be.
        Telemetry.log(.localPlayback, "bt_sink_ring_drops", [
            "uid": deviceUID,
            "chunks": String(record.droppedChunks),
            "at": "gate_open",
        ])
    }

    /// Apply a live trim change of `deltaMs` (positive = this device plays
    /// LATER). Called from the control queue; never rebuilds the sink, so the
    /// music does not stop.
    ///
    /// Three cases, chosen by how far the session has got:
    ///
    ///  - **Not anchored** — nothing captured yet. The anchor has not sampled
    ///    the delay, so it will pick the new trim up by itself; do nothing.
    ///  - **Anchored, gate still closed** — silence so far, nothing emitted to
    ///    be continuous with, so move the gate rather than the audio. Cheaper
    ///    and exact.
    ///  - **Released** — the delay IS the audio piled up behind the read
    ///    pointer, so the read position is the only lever. A LARGER trim plays
    ///    the device LATER ⇒ a LONGER delay ⇒ MORE audio must sit between read
    ///    and write ⇒ the read pointer moves BACKWARD, replaying history.
    ///    Hence the negation. (Plan trap 4.1: this is a 50/50 that compiles
    ///    either way — `positiveTrimSeeksTheReadPointerBackward` pins it.)
    ///
    /// A SHORTER delay seeks the read pointer forward instead, and that
    /// direction has a floor: run it into the write pointer and the ring is dry
    /// with nothing left to play and no way back. The move is clamped
    /// ``seekSafetyMarginMs`` short of the write pointer and the clamp is
    /// logged (`bt_sink_seek_clamped`) — the caller asking for more than the
    /// ring holds is the bug, and silently obeying it is what made a wizard
    /// trial kill the speaker for the rest of the session.
    ///
    /// Deliberately does NOT run `clearSessionStateLocked`: a seek is not a new
    /// session, so the anchor, the ring's contents and the resampler all stay
    /// exactly as they are (plan trap 4.3).
    func applyTrimDelta(ms deltaMs: Double) {
        let requestedFrames = Int((deltaMs / 1_000 * renderSampleRate).rounded())
        // Negative delta = shorter delay = FORWARD seek, the direction that can
        // empty the ring. Computed before the lock: both reads are lock-free
        // counter loads, and the pre-release branch below ignores the result.
        let marginFrames = Int((Self.seekSafetyMarginMs / 1_000 * renderSampleRate).rounded())
        let frames = requestedFrames < 0
            ? -Swift.min(-requestedFrames,
                         Swift.max(0, delayLine.forwardShiftRoomFrames() - marginFrames))
            : requestedFrames
        let appliedMs = Double(frames) / renderSampleRate * 1_000
        stateLock.lock()
        let isAnchored = anchored, hasReleased = released
        if isAnchored, !hasReleased {
            // Recomputed from the provider, not nudged by `deltaMs`, so this
            // and the anchor can never drift apart. Taking `tableLock` (inside
            // the provider) under `stateLock` is the sanctioned nesting — the
            // manager drops its table lock before calling in here.
            let delayNanos = delayNanosProvider()
            sessionDelayNanos = delayNanos
            targetReleaseNanos = SyncTiming.targetReleaseMonotonicNanos(
                anchorPtsNanos: anchorPtsNanos, totalDelayNanos: delayNanos)
        } else if isAnchored {
            // Released: the seek below IS the delay change, so record it here
            // too — a later `config_change` carry must reflect the trims the
            // user has made since the anchor. The APPLIED move, not the asked
            // one: a clamped seek that booked the full delta would leave the
            // session's mapping describing audio the ring never moved.
            sessionDelayNanos &+= Int64((appliedMs * 1_000_000).rounded())
        }
        stateLock.unlock()
        guard isAnchored, hasReleased else { return }
        if frames != requestedFrames {
            // Off the control queue — the queue that owns every sink operation
            // is not the place to format and write a log line.
            graphQueue.async { [weak self] in
                guard let self else { return }
                Telemetry.log(.localPlayback, "bt_sink_seek_clamped", [
                    "uid": self.deviceUID,
                    "requestedMs": String(format: "%.1f", deltaMs),
                    "appliedMs": String(format: "%.1f", appliedMs),
                ])
            }
        }
        guard frames != 0 else { return }
        delayLine.requestShift(frames: -frames)
    }

    // MARK: Consumer (delay line → render)

    private func makeSourceNode() -> AVAudioSourceNode {
        AVAudioSourceNode(format: connectionFormat) { [weak self] isSilence, timestamp, frameCount, audioBufferList in
            guard let self else {
                isSilence.pointee = true
                return noErr
            }
            return self.render(
                isSilence: isSilence, timestamp: timestamp,
                frameCount: frameCount, audioBufferList: audioBufferList)
        }
    }

    private func render(
        isSilence: UnsafeMutablePointer<ObjCBool>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let frames = Int(frameCount)
        guard frames > 0, frames * channelCount <= scratchCapacity,
              #available(macOS 14.2, *)   // the capture path feeding us needs 14.2 anyway
        else {
            isSilence.pointee = true
            return noErr
        }
        // Rebase the cycle's mach host time onto CLOCK_MONOTONIC with the
        // shared sleep-aware helper — the pts timeline the gate compares on.
        let cycleStart = SyncTiming.monotonicNanos(
            CoreAudioSystemTap.timespec(fromHostTime: timestamp.pointee.mHostTime))

        let buffer = UnsafeMutableBufferPointer(start: scratch, count: frames * channelCount)
        let producedAudio = renderInterleaved(
            into: buffer, frameCount: frames, cycleStartMonotonicNanos: cycleStart)

        let planes = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for ch in 0..<min(channelCount, planes.count) {
            guard let dst = planes[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for f in 0..<frames { dst[f] = scratch[f * channelCount + ch] }
        }
        isSilence.pointee = ObjCBool(!producedAudio)
        return noErr
    }

    /// The testable render core (no engine, no clocks): fills `frameCount`
    /// interleaved frames for a cycle starting at `cycleStartMonotonicNanos`
    /// and reports whether any real audio was emitted. Silent (and
    /// non-draining) until the gate opens at the anchored target; after that,
    /// the ring drains through the resampler at unity rate.
    @discardableResult
    func renderInterleaved(
        into out: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        cycleStartMonotonicNanos: Int64
    ) -> Bool {
        guard let base = out.baseAddress, frameCount > 0,
              frameCount * channelCount <= out.count else { return false }
        // Silence-first: real audio overwrites its slice; whatever the drain
        // cannot fill (pre-release frames, a ring underrun tail) stays zero.
        base.update(repeating: 0, count: frameCount * channelCount)

        var plan = SyncTiming.RenderPlan(silentFrames: frameCount, releasesThisCycle: false)
        // A2DP sinks servo to the host delivery rate — measured inter-speaker
        // drift is ~0 over 30 minutes (2026-08-12), so there is no rate
        // correction to apply and the resampler runs at unity.
        let ratio = 1.0
        var processor: EQProcessor?
        guard stateLock.try() else { return false }   // no snapshot → silent cycle
        processor = eqProcessor
        if anchored {
            if released {
                plan = SyncTiming.RenderPlan(silentFrames: 0, releasesThisCycle: true)
            } else {
                plan = SyncTiming.plan(
                    cycleStartMonotonicNanos: cycleStartMonotonicNanos,
                    frameCount: frameCount,
                    sampleRate: renderSampleRate,
                    targetReleaseMonotonicNanos: targetReleaseNanos)
                if plan.releasesThisCycle {
                    released = true
                    catchUpToTargetLocked(cycleStartMonotonicNanos: cycleStartMonotonicNanos)
                }
            }
        }
        stateLock.unlock()
        guard plan.releasesThisCycle else { return false }

        let produced = resampler.render(
            into: out,
            outFrameOffset: plan.silentFrames,
            outFrames: frameCount - plan.silentFrames,
            ratio: ratio
        ) { frame in
            self.delayLine.readFrame(into: frame)
        }
        // Tone, applied to the frames this cycle actually produced — the same
        // `DeviceEQ` and the same `EQProcessor` the AirPlay path runs, so one
        // speaker sounds the same however it is fed. Flat publishes no processor
        // at all, which is what keeps "EQ off" untouched audio.
        if let processor, produced > 0 {
            processor.process(
                floatInterleaved: base + plan.silentFrames * channelCount,
                frameCount: produced)
        }
        return produced > 0
    }

    /// The gate has just opened; make the first frame released the frame that
    /// is due NOW rather than the oldest one in the ring.
    ///
    /// The producer anchors on the first captured buffer and never waits for
    /// the engine, so the two can be far apart: an A2DP `engine.start()` can
    /// take well over half a second, and every rebuild (`config_change`,
    /// `composition_change`, `wizard_feed`) pays it again. When that start runs
    /// past `targetReleaseNanos`, the first cycle the render thread ever sees is
    /// already `overshoot` LATE — and the ring is a plain FIFO with no catch-up,
    /// so releasing its oldest frame here would make the effective delay
    /// "however long the engine took to start", permanently, for the whole
    /// session. Skipping the overshoot's worth of frames keeps playout pts-true.
    ///
    /// A ring holding less than the overshoot releases what it has (`partial`):
    /// it is empty rather than stale, so it goes pts-true on its own as the
    /// producer refills it.
    ///
    /// Called with `stateLock` HELD, on the render thread. The skip is counter
    /// arithmetic only — no copying, no allocation, no second lock — and doing
    /// it inside the same critical section is what lets a thread that may never
    /// block on this lock stash a COMPLETE telemetry record in one take.
    private func catchUpToTargetLocked(cycleStartMonotonicNanos: Int64) {
        let overshootNanos = max(0, cycleStartMonotonicNanos &- targetReleaseNanos)
        let wanted = Int((Double(overshootNanos) / 1_000_000_000 * renderSampleRate).rounded())
        let skipped = delayLine.skipForward(frames: wanted)
        releaseToLog = ReleaseRecord(
            overshootNanos: overshootNanos, caughtUpFrames: skipped, partial: skipped < wanted,
            droppedChunks: delayLine.takeDroppedChunks())
    }

    // MARK: Rebuild triggers (config change / nominal-rate renegotiation)

    private func installEventListenersLocked() {
        if configChangeObserver == nil {
            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                self?.requestRebuild(cause: "config_change")
            }
        }
        if rateListenerBlock == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.requestRebuild(cause: "rate_change")
            }
            rateListenerBlock = block
            var address = Self.nominalRateAddress
            AudioObjectAddPropertyListenerBlock(deviceID, &address, listenerQueue, block)
        }
    }

    private func removeEventListenersLocked() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if let block = rateListenerBlock {
            var address = Self.nominalRateAddress
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, listenerQueue, block)
            rateListenerBlock = nil
        }
    }

    // MARK: Core Audio property helpers

    private static let nominalRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var address = nominalRateAddress
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr,
              rate > 0 else { return nil }
        return rate
    }

    private static func transportType(_ device: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr
        else { return nil }
        return transport
    }
}

// MARK: - Manager (BT-SINK: the N-instance owner)

/// The N-instance Bluetooth sink manager: one ``BTDeviceSink`` per selected BT
/// device, all fed the SAME captured PCM+pts (`enqueue` fans out), each delayed
/// to the current reference timeline (``BTReferenceTimeline``) with its own
/// offset/trim.
///
/// Feeding it from the whole-system capture and driving it from selection
/// transitions is BT-FANOUT/BT-BACKEND's partition
/// (`docs/plans/PLAN-UNIVERSAL-SYNC.md` §G), not a missing hookup here.
///
/// `@unchecked Sendable`: `tableLock` guards the tables below and is NEVER held
/// across a call into a sink (sinks are collected under the lock, called after
/// it drops) — the reverse order (a sink's anchor sampling its delay provider,
/// which takes `tableLock`) is the sanctioned nesting.
final class BTSyncedSink: @unchecked Sendable {

    struct DeviceSpec: Equatable, Sendable {
        let deviceID: AudioObjectID
        /// Stable identity (`kAudioDevicePropertyDeviceUID`) — the key offsets
        /// and trims survive a disconnect/rejoin under.
        let uid: String
    }

    /// BT-only reference: the scheduling buffer ahead of the Mac `hostTime`
    /// timeline this manager STARTS on. 500 ms clears the typical real-world BT
    /// output-latency spread, so per-device offsets keep their full relative
    /// effect without hitting the zero clamp; latency is a non-goal (music, not
    /// lip-sync — Decision 1).
    ///
    /// It is a FLOOR, not the whole answer: a speaker whose measured latency is
    /// larger than the buffer cannot be fed early enough to reach the group, so
    /// ``NativeBackend`` raises the reference past the slowest known device
    /// (and again, higher still, for the duration of a wizard run) through
    /// ``setBTOnlyBufferMs(_:)``.
    static let defaultBTOnlyBufferMs = 500

    /// Internal (not `private`) — ``SyncedLocalPCMSink``'s requirement: the
    /// capture fan-out reads it to build the base-rate converter that feeds
    /// `enqueue` (identity at the default airplay rate).
    let renderSampleRate: Double
    private let channelCount: Int
    /// Guarded by `tableLock` — see ``setBTOnlyBufferMs(_:)``.
    private var btOnlyBufferMs: Int
    /// The LIVE AirPlay presentation delay (`currentPresentationDelayMs()` in
    /// production — plan risk R4 forbids a hardcoded copy). Sampled per session
    /// anchor via each sink's delay provider.
    private let presentationDelayMs: @Sendable () -> Int

    private let tableLock = NSLock()
    private var sinksByUID: [String: BTDeviceSink] = [:]
    private var composition = BTGroupComposition(airPlayPresent: false, macLocalPresent: false)
    private var offsetMsByUID: [String: Int] = [:]
    private var trimMsByUID: [String: Double] = [:]
    private var gainByUID: [String: Float] = [:]
    private var eqByUID: [String: DeviceEQ] = [:]
    private var desiredRunning = false

    init(
        renderSampleRate: Double = 44_100,
        channelCount: Int = 2,
        btOnlyBufferMs: Int = BTSyncedSink.defaultBTOnlyBufferMs,
        presentationDelayMs: @escaping @Sendable () -> Int
    ) {
        self.renderSampleRate = renderSampleRate
        self.channelCount = max(1, channelCount)
        self.btOnlyBufferMs = btOnlyBufferMs
        self.presentationDelayMs = presentationDelayMs
    }

    deinit {
        stop()
    }

    // MARK: Selection / lifecycle

    /// Arm the manager: current and future sinks start their engines.
    func start() {
        let sinks = tableLock.withLock { () -> [BTDeviceSink] in
            desiredRunning = true
            return Array(sinksByUID.values)
        }
        for sink in sinks { startSink(sink) }
    }

    func stop() {
        let sinks = tableLock.withLock { () -> [BTDeviceSink] in
            desiredRunning = false
            return Array(sinksByUID.values)
        }
        for sink in sinks { sink.stop() }
    }

    /// Reconcile toward exactly `specs`: new devices get a sink (started only
    /// while the manager is armed), vanished devices' sinks stop and drop.
    /// Unchanged devices are untouched — their sessions keep playing.
    func setDevices(_ specs: [DeviceSpec]) {
        var added: [(sink: BTDeviceSink, gain: Float, eq: DeviceEQ)] = []
        var removed: [BTDeviceSink] = []
        var shouldStart = false
        tableLock.lock()
        let wantedByUID = Dictionary(specs.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        for (uid, sink) in sinksByUID where wantedByUID[uid] == nil {
            sinksByUID[uid] = nil
            removed.append(sink)
        }
        for (uid, spec) in wantedByUID where sinksByUID[uid] == nil {
            let sink = makeSink(spec)
            sinksByUID[uid] = sink
            added.append((sink, gainByUID[uid] ?? 1, eqByUID[uid] ?? .flat))
        }
        shouldStart = desiredRunning
        tableLock.unlock()

        for sink in removed { sink.stop() }
        for (sink, gain, _) in added where gain != 1 {
            // A remembered hold (W3) applies BEFORE the engine starts, so a
            // held device never gets an audible blip ahead of the mute.
            sink.setGain(gain)
        }
        // Same ordering rule for tone: applied before the engine starts, so the
        // device never plays a few unshaped buffers first.
        for (sink, _, eq) in added where !eq.isFlat {
            sink.setEQ(eq)
        }
        if shouldStart {
            for (sink, _, _) in added { startSink(sink) }
        }
    }

    /// BT-REFSEL: recompute every device's delay when the group's composition
    /// changes. Applied as a rebuild + re-anchor per sink — the reference
    /// timeline itself moved, so the running sessions' targets are void.
    func setComposition(_ newComposition: BTGroupComposition) {
        let sinks = tableLock.withLock { () -> [BTDeviceSink] in
            guard composition != newComposition else { return [] }
            composition = newComposition
            return Array(sinksByUID.values)
        }
        for sink in sinks { sink.requestRebuild(cause: "composition_change") }
    }

    /// Move the BT-only reference timeline. Every sink's delay is measured from
    /// it, so this re-anchors them all through the SAME path a composition
    /// change uses — the reference moved, which is exactly what
    /// `composition_change` means, and it is deliberately not a new rebuild
    /// kind. No-op when the group renders against a presentation timeline
    /// (AirPlay's or a Cast receiver's) instead, and a same-value write costs
    /// nothing.
    func setBTOnlyBufferMs(_ ms: Int) {
        let sinks = tableLock.withLock { () -> [BTDeviceSink] in
            guard btOnlyBufferMs != ms else { return [] }
            btOnlyBufferMs = ms
            return composition.usesPresentationReference ? [] : Array(sinksByUID.values)
        }
        for sink in sinks { sink.requestRebuild(cause: "composition_change") }
    }

    /// Rebuild every live sink under `cause`, so the next captured buffer
    /// re-anchors it against a fresh delay. The alignment wizard's feed handoff
    /// is the caller (`cause: "wizard_feed"`), on both edges of its run.
    func reanchorAll(cause: String) {
        let sinks = tableLock.withLock { Array(sinksByUID.values) }
        for sink in sinks { sink.requestRebuild(cause: cause) }
    }

    /// The per-device MEASURED output latency (ms) — how late this speaker
    /// plays on its own, so a LARGER value feeds it EARLIER
    /// (`SyncTiming.totalDelayNanos` subtracts it). The alignment wizard
    /// measures it and ``BTTrimStore`` persists it per device UID.
    ///
    /// Applied LIVE, exactly like ``setTrimMs(_:forDeviceUID:)`` and for the
    /// same reason: latency and trim are the same linear term in the delay
    /// (`reference − latency + trim`), so a change is a move of the read
    /// position, never a new session. The wizard pushes one of these per trial
    /// — a rebuild each time would drop the speaker into silence for the whole
    /// delay and there would be nothing left to judge. The delay delta is the
    /// NEGATIVE of the latency delta, which is the whole sign convention in one
    /// line.
    func setOffsetMs(_ ms: Int, forDeviceUID uid: String) {
        let change = tableLock.withLock { () -> (sink: BTDeviceSink, deltaMs: Double)? in
            let previous = offsetMsByUID[uid] ?? 0
            guard previous != ms else { return nil }
            offsetMsByUID[uid] = ms
            guard let sink = sinksByUID[uid] else { return nil }
            return (sink, Double(ms - previous))
        }
        if let change { change.sink.applyTrimDelta(ms: -change.deltaMs) }
    }

    /// The measured latency currently in force for a device (0 when unknown).
    func offsetMs(forDeviceUID uid: String) -> Int {
        tableLock.withLock { offsetMsByUID[uid] ?? 0 }
    }

    /// The settable per-device signed manual trim (ms), applied LIVE — while
    /// the music plays, with no gap (PLAN-BT-SYNC-DRAWER D6: the whole point is
    /// nudging by ear).
    ///
    /// A trim is NOT a structural change — same device, same rate, same
    /// reference timeline — so unlike offset/composition/rate it must not
    /// rebuild the sink. A rebuild re-arms the release gate and the device
    /// falls silent for the whole delay, about half a second per edit, which is
    /// what made the old stepper unusable for scrubbing.
    ///
    /// Sub-quantum float dust in `ms` cannot leak through: the delta is
    /// converted to whole frames, and anything below half a frame rounds to a
    /// no-op shift.
    func setTrimMs(_ ms: Double, forDeviceUID uid: String) {
        let change = tableLock.withLock { () -> (sink: BTDeviceSink, deltaMs: Double)? in
            let previous = trimMsByUID[uid] ?? 0
            guard previous != ms else { return nil }
            trimMsByUID[uid] = ms
            guard let sink = sinksByUID[uid] else { return nil }
            return (sink, ms - previous)
        }
        if let change { change.sink.applyTrimDelta(ms: change.deltaMs) }
    }

    /// D11/T3: the trim range this device's drawer may actually move within.
    /// Below `lowerBound` (or above `upperBound`, which never moves — see
    /// below) the ≥ 0 clamp inside `SyncTiming.totalDelayNanos` already eats
    /// the change, so a ruler/field that let the value run further would be
    /// showing motion that does nothing.
    ///
    /// Solves `delayNanos(forUID:)`'s own formula
    /// (`reference − deviceOffset + trim`, clamped ≥ 0) for the trim that
    /// lands exactly on zero: `lower = max(-rangeMs, -(reference −
    /// deviceOffset))`. `upper` stays the plain `±rangeMs` ceiling — a large
    /// *positive* trim is never the thing the zero clamp eats, only a large
    /// negative one is.
    ///
    /// LIVE QUERY — do not cache the result. `reference` is
    /// `presentationDelayMs()` (the live AirPlay figure) when the group's
    /// composition currently includes AirPlay, else the fixed
    /// `btOnlyBufferMs`; `BTReferenceTimeline` swaps between them on every
    /// composition change (BT-REFSEL), so the floor genuinely moves the
    /// instant an AirPlay device joins or leaves the selection. Callers must
    /// re-read this every time they need it, never memoize it (e.g. at
    /// drawer-open time).
    ///
    /// A uid with no sink — never selected, or already dropped — has no
    /// device offset to solve against, so it gets the full ±`rangeMs`.
    func usableTrimRangeMs(forDeviceUID uid: String) -> ClosedRange<Double> {
        tableLock.lock()
        guard sinksByUID[uid] != nil else {
            tableLock.unlock()
            return -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs
        }
        let currentComposition = composition
        let offsetMs = offsetMsByUID[uid] ?? 0
        let bufferMs = btOnlyBufferMs
        tableLock.unlock()
        let reference = currentComposition.usesPresentationReference
            ? presentationDelayMs() : bufferMs
        let lowerBound = Swift.min(
            BTSyncTrim.rangeMs,
            Swift.max(-BTSyncTrim.rangeMs, -(Double(reference) - Double(offsetMs))))
        return lowerBound...BTSyncTrim.rangeMs
    }

    /// Per-device render gain (W3 hold-silent): remembered in the table so a
    /// sink created LATER (the usual first-mix case — the hold is decided in
    /// the same selection change that creates the sink) starts at the held
    /// level, never with an audible blip before the mute lands.
    func setGain(_ gain: Float, forDeviceUID uid: String) {
        let sink = tableLock.withLock { () -> BTDeviceSink? in
            guard gainByUID[uid] != gain else { return nil }
            gainByUID[uid] = gain
            return sinksByUID[uid]
        }
        sink?.setGain(gain)
    }

    /// Per-device tone — remembered in the table exactly like the gain above, so
    /// a sink created LATER starts already shaped instead of playing its first
    /// buffers flat. Never a rebuild: the sink swaps its filter coefficients on
    /// the running session (a rebuild would re-arm the delay gate and drop the
    /// device into silence for the whole reference delay, which is what makes
    /// live scrubbing unusable).
    func setEQ(_ eq: DeviceEQ, forDeviceUID uid: String) {
        let sink = tableLock.withLock { () -> BTDeviceSink? in
            guard eqByUID[uid] != eq else { return nil }
            eqByUID[uid] = eq
            return sinksByUID[uid]
        }
        sink?.setEQ(eq)
    }

    /// The UIDs whose delay gate has opened — the devices actually hearing
    /// audio right now. A uid with no sink (its `AudioObjectID` never resolved)
    /// or whose engine failed to start is simply absent, which is what makes
    /// the caller's `.connecting` hold degrade instead of hang.
    func renderingDeviceUIDs() -> Set<String> {
        let sinks = tableLock.withLock { Array(sinksByUID.values) }
        return Set(sinks.lazy.filter(\.hasStartedRendering).map(\.deviceUID))
    }

    /// The UIDs that have been HANDED at least one captured buffer, whether or
    /// not their delay gate has opened yet. This is the "is there anything to
    /// wait for" question, and it is not the same as
    /// ``renderingDeviceUIDs()``: with nothing playing on the Mac, the capture
    /// fan-out never calls `enqueue`, so no sink ever anchors and none can ever
    /// render. A caller holding a `.connecting` state must treat that as an
    /// IDLE speaker (connected, nothing to play) rather than a failure —
    /// otherwise selecting a healthy speaker while paused reports "no audio
    /// started" once its ceiling expires.
    /// Optional to MATCH ``BTSyncedSinkControlling``'s requirement exactly. A
    /// non-optional return does not witness an optional requirement, so Swift
    /// silently falls back to the protocol's "can't tell" default — the real
    /// sink's answer never reaches the caller and nothing fails to compile.
    /// This one always answers; only lifecycle-only spies return nil.
    func anchoredDeviceUIDs() -> Set<String>? {
        let sinks = tableLock.withLock { Array(sinksByUID.values) }
        return Set(sinks.lazy.filter(\.hasAnchored).map(\.deviceUID))
    }

    // MARK: Feed

    /// Fan one captured block to every device's delay line. Called on the tap
    /// delivery thread; the sink list is snapshotted under `tableLock`, the
    /// per-sink work happens after it drops (lock-order rule above).
    func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {
        let sinks = tableLock.withLock { Array(sinksByUID.values) }
        for sink in sinks {
            sink.enqueue(interleavedFrames: interleavedFrames, frameCount: frameCount, pts: pts)
        }
    }

    // MARK: Internals

    private func makeSink(_ spec: DeviceSpec) -> BTDeviceSink {
        let uid = spec.uid
        return BTDeviceSink(
            deviceID: spec.deviceID,
            deviceUID: uid,
            renderSampleRate: renderSampleRate,
            channelCount: channelCount,
            delayNanosProvider: { [weak self] in self?.delayNanos(forUID: uid) ?? 0 })
    }

    private func delayNanos(forUID uid: String) -> Int64 {
        tableLock.lock()
        let currentComposition = composition
        let offsetMs = offsetMsByUID[uid] ?? 0
        let trimMs = trimMsByUID[uid] ?? 0
        let bufferMs = btOnlyBufferMs
        tableLock.unlock()
        return BTReferenceTimeline.delayNanos(
            composition: currentComposition,
            presentationDelayMs: presentationDelayMs(),
            btOnlyBufferMs: bufferMs,
            deviceOffsetMs: offsetMs,
            trimMs: trimMs)
    }

    private func startSink(_ sink: BTDeviceSink) {
        do {
            try sink.start()
        } catch {
            Telemetry.log(.localPlayback, "bt_sink_start_failed", [
                "uid": sink.deviceUID, "error": String(describing: error),
            ])
        }
    }

    // MARK: Test seam

    /// The live sink for a UID — offline tests drive its render core directly.
    func sinkForTesting(uid: String) -> BTDeviceSink? {
        tableLock.withLock { sinksByUID[uid] }
    }
}

/// The manager IS a fan-out target (BT-FANOUT): `enqueue`/`renderSampleRate`
/// already match the protocol, so `NativeCaptureCoordinator.setBTSink` feeds it
/// through the same seam the synced-local sink uses.
extension BTSyncedSink: SyncedLocalPCMSink {}
