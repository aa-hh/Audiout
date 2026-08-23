// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design (PLAN-UNIVERSAL-SYNC Decision 5): this file carries NO
// GPL SPDX header, unlike most siblings. Everything in it is ORIGINAL to this
// project — a plain power-of-two sample ring plus the two owner-counter words
// re-derived from the license-clean `BTFrameRing`/`BTDelayLine` idiom in
// `BTSyncedSink.swift`. The GPL-headered `SyncedLocalSink.swift` was NOT read
// or drawn on for any of it. Do not add a GPL header to this file, and do not
// move GPL-derived code into it.

import Foundation

/// A whole-block delay for the interleaved S16LE stereo mix that the capture
/// fan-out hands round (4 bytes per frame, 44.1 kHz).
///
/// **Cadence-preserving.** One block out per block in, always the same frame
/// count: the caller's write rhythm is untouched, so a consumer downstream sees
/// exactly the blocks it would have seen with no delay line at all, only older.
/// That is what lets the line sit between the IOProc and a sink without
/// changing anything about how the sink is driven.
///
/// **The pts is deliberately NOT rewound.** ``exchange(_:)`` moves audio, never
/// timestamps; the caller keeps passing its own live pts downstream (sync
/// architecture brief §1, "Fresh pts is required"). A delayed pts would tell
/// the receiver the audio is old and it would try to catch up, which is the
/// opposite of the point.
///
/// **Thread contract**, the ``BTDelayLine`` one: ``exchange(_:)`` is IOProc-only
/// and REAL-TIME (no allocation, no locks, no logging, no Obj-C messaging);
/// ``setDelayFrames(_:)`` is control-thread-only. They communicate through two
/// monotonic words with exactly one writer each — the control thread only ever
/// writes `requested`, the IOProc only ever writes `applied` — so neither needs
/// a lock or an atomic.
///
/// **Inert until a Cast device is selected.** Phase (ii) wires it into the
/// capture fan-out as an OPTIONAL ``NativeCaptureCoordinator`` slot that stays
/// `nil` — with no Cast device in the mix nothing constructs a line at all, so
/// the AirPlay path costs one nil check and is byte-for-byte what it was.
///
/// razor: stereo S16LE only, and no drop/underrun counters. Both are what the
/// one caller feeds it; widening to N channels or adding observability is a
/// job for whoever first needs to observe it.
final class PCMDelayLine {

    /// Interleaved stereo Int16: 2 samples, 4 bytes.
    private static let channelCount = 2
    private static let bytesPerFrame = 4

    /// Rounded up to a power of two so the wrap is a mask and the whole
    /// capacity stays usable (the ``BTFrameRing`` idiom).
    let capacityFrames: Int
    private let frameMask: Int
    private let samples: UnsafeMutablePointer<Int16>

    /// Where the next block lands. IOProc-owned; monotonically increasing, so
    /// history sits at negative offsets from it and the mask does the wrapping.
    private let writeFrame: UnsafeMutablePointer<Int>

    private let requestedDelayFrames: UnsafeMutablePointer<Int>  // control-thread-owned
    private let appliedDelayFrames: UnsafeMutablePointer<Int>    // IOProc-owned

    init(capacityFrames: Int) {
        var capacity = 1
        while capacity < max(2, capacityFrames) { capacity <<= 1 }
        self.capacityFrames = capacity
        self.frameMask = capacity - 1
        let sampleCount = capacity * Self.channelCount
        self.samples = UnsafeMutablePointer<Int16>.allocate(capacity: sampleCount)
        self.samples.initialize(repeating: 0, count: sampleCount)
        self.writeFrame = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        self.requestedDelayFrames = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        self.appliedDelayFrames = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        writeFrame.initialize(to: 0)
        requestedDelayFrames.initialize(to: 0)
        appliedDelayFrames.initialize(to: 0)
    }

    deinit {
        samples.deallocate()
        writeFrame.deallocate()
        requestedDelayFrames.deallocate()
        appliedDelayFrames.deallocate()
    }

    /// The delay actually in force, in frames — what the last ``exchange(_:)``
    /// settled on after clamping, not what was last asked for.
    var delayFrames: Int { appliedDelayFrames.pointee }

    /// Ask for an ABSOLUTE delay, in frames. Not accumulated: the newest value
    /// wins outright, and the IOProc adopts it on its next block. Control
    /// thread ONLY.
    func setDelayFrames(_ frames: Int) {
        requestedDelayFrames.pointee = max(0, frames)
        OSMemoryBarrier()                       // release: publish before the IOProc's acquire
    }

    /// Value-returning twin of ``exchange(_:)``, for the caller that must keep
    /// its own undelayed block (the capture fan-out hands the SAME buffer to
    /// three more consumers after the engine write, each with its own delay).
    /// IOProc ONLY.
    ///
    /// razor: one `Data` copy per block while the line is live. That cost is
    /// only ever paid with a Cast device selected — the bypass is a `nil` line,
    /// not a zero delay, so the no-Cast path never reaches here. If a live Cast
    /// mix ever shows it on the IOProc's budget, the upgrade is a preallocated
    /// scratch handed back as `Data(bytesNoCopy:)`, which is safe because the
    /// engine copies synchronously before enqueue.
    func exchange(_ pcm: Data) -> Data {
        var delayed = pcm
        exchange(&delayed)
        return delayed
    }

    /// Swap `pcm`'s live frames for the frames that entered the line `delay`
    /// frames ago, in place. IOProc ONLY.
    ///
    /// Trailing bytes that do not complete a frame are left exactly as they
    /// arrived: a partial frame is a caller bug, and silently rounding it away
    /// (or padding it) would corrupt the channel interleave from there on.
    func exchange(_ pcm: inout Data) {
        let frameCount = pcm.count / Self.bytesPerFrame
        guard frameCount > 0 else { return }
        let delay = adoptPendingDelay(blockFrames: frameCount)
        let write = writeFrame.pointee
        pcm.withUnsafeMutableBytes { raw in
            guard let block = raw.baseAddress else { return }
            copyIntoRing(from: UnsafeRawPointer(block), atFrame: write, frameCount: frameCount)
            // Read AFTER the write, so a delay of 0 reads back the very frames
            // just stored and the output is the input, byte for byte.
            copyOutOfRing(into: block, atFrame: write &- delay, frameCount: frameCount)
        }
        writeFrame.pointee = write &+ frameCount
    }

    /// Take whatever delay the control thread has asked for, clamp it to what
    /// the ring can actually hold alongside this block, and — when it GREW —
    /// silence the stretch of history the move newly exposes.
    ///
    /// That zero-fill is the whole reason growing is not just an assignment:
    /// the frames now under the read position are old audio from before the
    /// change, and replaying them would be an audible jump backwards. Silence
    /// is the honest thing to emit while the line fills at the new depth.
    /// Shrinking needs no such care — it jumps forward onto audio the line has
    /// already got, which is a plain skip.
    private func adoptPendingDelay(blockFrames: Int) -> Int {
        OSMemoryBarrier()                       // acquire: see the control thread's word
        let requested = requestedDelayFrames.pointee
        let applied = appliedDelayFrames.pointee
        // The oldest frame still intact is `write + blockFrames - capacity`:
        // this block's own write is what reclaims it. Hence the ceiling.
        let effective = max(0, min(requested, capacityFrames - blockFrames))
        guard effective != applied else { return applied }
        if effective > applied {
            let write = writeFrame.pointee
            zeroRing(fromFrame: write &- effective, frameCount: effective - applied)
        }
        appliedDelayFrames.pointee = effective
        return effective
    }

    // MARK: - Ring primitives
    //
    // `startFrame` is a running counter and may be negative (history behind the
    // write position). Masking a two's-complement Int with `capacity - 1` wraps
    // it correctly either way, which is why the capacity is a power of two.

    private func copyIntoRing(from src: UnsafeRawPointer, atFrame startFrame: Int, frameCount: Int) {
        var done = 0
        while done < frameCount {
            let index = (startFrame &+ done) & frameMask
            let span = min(frameCount - done, capacityFrames - index)
            memcpy(
                samples.advanced(by: index * Self.channelCount),
                src.advanced(by: done * Self.bytesPerFrame),
                span * Self.bytesPerFrame)
            done += span
        }
    }

    private func copyOutOfRing(
        into dst: UnsafeMutableRawPointer, atFrame startFrame: Int, frameCount: Int
    ) {
        var done = 0
        while done < frameCount {
            let index = (startFrame &+ done) & frameMask
            let span = min(frameCount - done, capacityFrames - index)
            memcpy(
                dst.advanced(by: done * Self.bytesPerFrame),
                samples.advanced(by: index * Self.channelCount),
                span * Self.bytesPerFrame)
            done += span
        }
    }

    private func zeroRing(fromFrame startFrame: Int, frameCount: Int) {
        var done = 0
        while done < frameCount {
            let index = (startFrame &+ done) & frameMask
            let span = min(frameCount - done, capacityFrames - index)
            samples.advanced(by: index * Self.channelCount)
                .update(repeating: 0, count: span * Self.channelCount)
            done += span
        }
    }
}
