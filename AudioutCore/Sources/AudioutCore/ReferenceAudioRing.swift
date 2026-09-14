import Foundation
import AirPlayEngine

/// A rolling history of the outgoing program audio, kept so a mic capture taken
/// moments later can be correlated against what was actually sent (roadmap 085
/// ticket 01 — the reference side of passive drift tracking).
///
/// ``NativeCaptureCoordinator/deliver(_:pts:snapshot:btPCM:btSweepFreePCM:btSweepOwnerUID:)``
/// appends the Bluetooth-bound variant of every block with its monotonic pts;
/// nothing is retained until ``setArmed(_:)`` arms it (the buffer is allocated
/// on first arm and audio is dropped on disarm), so the steady-state pipeline
/// cost is one flag check per block.
///
/// Contiguity is an invariant, not a hope: an appended block whose pts does not
/// continue the retained tail (a tap rebuild, a producer handoff) restarts the
/// history at that block, so a ``slice(fromNanos:toNanos:)`` is always one
/// gapless S16LE run whose first frame is exactly `startPtsNanos`.
///
/// Thread-safety: the delivery thread never waits on a reader. While disarmed
/// `append` reads one atomic word and returns; while armed it takes the lock
/// only for its own memcpy. `slice` copies with the lock released and validates
/// the copy against a generation counter `append` bumps around every mutation,
/// so a reader that raced an append retries instead of returning torn frames.
final class ReferenceAudioRing: @unchecked Sendable {

    private let sampleRate: Double
    private let bytesPerFrame: Int
    private let capacityFrames: Int
    /// How far an appended block's pts may sit from where the retained tail
    /// says it should be before the history restarts. One frame of jitter is
    /// exact; 1 ms is generous.
    private let continuityToleranceNanos: Int64 = 1_000_000

    private let lock = NSLock()
    /// Read by `append` before it takes the lock, so a disarmed block costs one
    /// aligned-word read on the delivery thread (same idiom as
    /// ``NativeCaptureCoordinator``'s feed-gap tracker: `Int` is what makes the
    /// store a single word).
    private let armedPtr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    /// Bumped to odd while the ring or its bookkeeping is being changed and
    /// back to even after. A reader whose copy spans a bump repeats it.
    private let generationPtr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private var ring: UnsafeMutableRawPointer?
    /// Ring write position, oldest-retained count, and the pts of the frame
    /// AFTER the newest retained one (== the next block's expected pts).
    private var writeFrame = 0
    private var retainedFrames = 0
    private var endPtsNanos: Int64 = 0

    init(capacitySeconds: Double = 15,
         sampleRate: Int = PCMFormat.airplay.sampleRate,
         channels: Int = PCMFormat.airplay.channels) {
        self.sampleRate = Double(sampleRate)
        self.bytesPerFrame = channels * MemoryLayout<Int16>.size
        self.capacityFrames = max(1, Int((capacitySeconds * Double(sampleRate)).rounded()))
        armedPtr.initialize(to: 0)
        generationPtr.initialize(to: 0)
    }

    deinit {
        ring?.deallocate()
        armedPtr.deallocate()
        generationPtr.deallocate()
    }

    /// Arm to start retaining; disarm to drop the retained audio (kept audio is
    /// tracking state, not something to hold while nobody is measuring). The
    /// buffer itself is allocated once, on first arm.
    func setArmed(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        beginMutationLocked()
        armedPtr.pointee = on ? 1 : 0
        writeFrame = 0
        retainedFrames = 0
        endPtsNanos = 0
        if on, ring == nil {
            ring = .allocate(byteCount: capacityFrames * bytesPerFrame,
                             alignment: MemoryLayout<Int16>.alignment)
        }
        endMutationLocked()
    }

    var isArmed: Bool {
        armedPtr.pointee != 0
    }

    /// Retain one delivered S16LE block. No-op while disarmed; a pts that does
    /// not continue the retained tail restarts the history at this block.
    func append(_ pcm: Data, pts: timespec) {
        guard armedPtr.pointee != 0 else { return }
        let ptsNanos = SyncTiming.monotonicNanos(pts)
        lock.lock()
        defer { lock.unlock() }
        guard armedPtr.pointee != 0, let ring else { return }
        let frames = pcm.count / bytesPerFrame
        guard frames > 0 else { return }

        beginMutationLocked()
        defer { endMutationLocked() }
        if retainedFrames > 0, abs(ptsNanos - endPtsNanos) > continuityToleranceNanos {
            writeFrame = 0
            retainedFrames = 0
        }

        pcm.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let base = src.baseAddress else { return }
            var srcOffset = 0
            var remaining = min(frames, capacityFrames)
            // A block larger than the whole ring keeps only its newest frames.
            if frames > capacityFrames {
                srcOffset = (frames - capacityFrames) * bytesPerFrame
            }
            while remaining > 0 {
                let run = min(remaining, capacityFrames - writeFrame)
                ring.advanced(by: writeFrame * bytesPerFrame)
                    .copyMemory(from: base + srcOffset, byteCount: run * bytesPerFrame)
                srcOffset += run * bytesPerFrame
                writeFrame = (writeFrame + run) % capacityFrames
                remaining -= run
            }
        }
        retainedFrames = min(retainedFrames + frames, capacityFrames)
        // Anchored to THIS block's own pts, not accumulated from the run's
        // first block: the incoming pts ride the capture device's clock, so
        // adding nominal-rate durations lets a parts-per-million rate offset
        // pile up until it crosses `continuityToleranceNanos` and falsely
        // restarts the history (~every 33 s at 30 ppm, truncating the window).
        // Re-anchoring bounds the mismatch to one block's worth of rate error.
        endPtsNanos = ptsNanos + Int64((Double(frames) / sampleRate * 1_000_000_000).rounded())
    }

    /// The retained pts range, or nil while empty.
    func retainedRangeNanos() -> ClosedRange<Int64>? {
        lock.lock()
        defer { lock.unlock() }
        guard retainedFrames > 0 else { return nil }
        return startPtsNanos()...endPtsNanos
    }

    /// Copy the gapless run covering `[fromNanos, toNanos)`, clamped to what is
    /// retained. Returns the S16LE bytes and the exact pts of their first
    /// frame; nil when the clamped window is empty.
    func slice(fromNanos: Int64, toNanos: Int64) -> (pcm: Data, startPtsNanos: Int64)? {
        // The copy is up to the whole window (~2.6 MB), so it runs with the
        // lock released and is thrown away if an append landed during it.
        // razor: four tries, then one copy under the lock as the floor that
        // guarantees an answer. Upgrade path if that floor is ever reached in
        // the field: copy in lock-released chunks instead.
        for _ in 0..<4 {
            let before = generationPtr.pointee
            guard before % 2 == 0 else { continue }
            OSMemoryBarrier()
            let candidate = sliceUnsynchronized(fromNanos: fromNanos, toNanos: toNanos)
            OSMemoryBarrier()
            if generationPtr.pointee == before { return candidate }
        }
        lock.lock()
        defer { lock.unlock() }
        return sliceUnsynchronized(fromNanos: fromNanos, toNanos: toNanos)
    }

    private func sliceUnsynchronized(fromNanos: Int64,
                                     toNanos: Int64) -> (pcm: Data, startPtsNanos: Int64)? {
        guard retainedFrames > 0, let ring else { return nil }
        let startPts = startPtsNanos()
        let from = max(fromNanos, startPts)
        let to = min(toNanos, endPtsNanos)
        guard to > from else { return nil }

        let firstFrame = Int((Double(from - startPts) * sampleRate / 1_000_000_000).rounded())
        let lastFrameExclusive = Int((Double(to - startPts) * sampleRate / 1_000_000_000).rounded())
        let frameCount = min(lastFrameExclusive, retainedFrames) - firstFrame
        guard frameCount > 0 else { return nil }

        let oldestRingFrame = (writeFrame - retainedFrames + capacityFrames * 2) % capacityFrames
        var out = Data(count: frameCount * bytesPerFrame)
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            guard let dstBase = dst.baseAddress else { return }
            var readFrame = (oldestRingFrame + firstFrame) % capacityFrames
            var remaining = frameCount
            var dstOffset = 0
            while remaining > 0 {
                let run = min(remaining, capacityFrames - readFrame)
                (dstBase + dstOffset).copyMemory(
                    from: ring.advanced(by: readFrame * bytesPerFrame),
                    byteCount: run * bytesPerFrame)
                dstOffset += run * bytesPerFrame
                readFrame = (readFrame + run) % capacityFrames
                remaining -= run
            }
        }
        let sliceStartPts = startPts
            + Int64((Double(firstFrame) / sampleRate * 1_000_000_000).rounded())
        return (out, sliceStartPts)
    }

    /// Lock held. Publishes "a change is in progress" to readers.
    private func beginMutationLocked() {
        generationPtr.pointee &+= 1
        OSMemoryBarrier()
    }

    /// Lock held. Publishes the finished change.
    private func endMutationLocked() {
        OSMemoryBarrier()
        generationPtr.pointee &+= 1
    }

    private func startPtsNanos() -> Int64 {
        endPtsNanos - Int64((Double(retainedFrames) / sampleRate * 1_000_000_000).rounded())
    }
}
