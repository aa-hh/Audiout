// T-ENG-CADENCE-1 headless tests for write-cadence deficit/overrun detection
// (first-light backlog #4).
//
// SCOPE: BUILD + HEADLESS ONLY. No real event loop, no sockets, no PTP.
//
// Two levels are exercised:
//   1. `WriteCadenceTracker` directly — deterministic control over the
//      "wall-clock elapsed" input via a fixed, injected sample count/rate and
//      real (but tiny, sleep-based) delays, so the deficit/overrun math is
//      verified without any dependency on the full engine/dispatcher.
//   2. `AirPlayEngine.write(pcm:pts:)` end-to-end in headless test mode —
//      proves the hot path actually feeds the tracker, and that
//      `writeCadenceSnapshot()` reflects it.

import Testing
import Foundation
@testable import AirPlayEngine
import CAirPlayEngine

@Suite struct WriteCadenceTests {

    // MARK: - WriteCadenceTracker unit tests

    /// A nominal (real-time-paced) feed should stay ~zero on both deficit and
    /// overrun: each write's wall-clock gap to the audio time it represents is
    /// small and roughly symmetric, so it should not accumulate a meaningful
    /// running deficit OR overrun.
    @Test func nominalFeedStaysNearZero() async throws {
        let tracker = WriteCadenceTracker()
        let sampleRate = 44100
        let samplesPerWrite = 352 // AirPlay frame size
        let audioSeconds = Double(samplesPerWrite) / Double(sampleRate)

        // First call only seeds the baseline (no prior write to compare
        // against) — matches the tracker's documented behavior.
        tracker.record(samples: samplesPerWrite, sampleRate: sampleRate)

        for _ in 0..<20 {
            // Sleep for exactly the audio duration this write represents, so
            // wall-clock elapsed ~= audio time delivered (nominal cadence).
            try await Task.sleep(nanoseconds: UInt64(audioSeconds * 1e9))
            tracker.record(samples: samplesPerWrite, sampleRate: sampleRate)
        }

        let snapshot = tracker.snapshot()
        #expect(snapshot.writeCount == 21)
        // Scheduling jitter under CI/parallel-agent load is real but bounded;
        // the nominal feed should never accumulate anywhere near the underfed
        // feed's magnitude (asserted below at >> 0.15s over a much shorter,
        // deliberately-stalled run).
        #expect(snapshot.deficitSeconds < 0.15, "nominal feed should not accrue a meaningful deficit")
        #expect(snapshot.overrunSeconds < 0.15, "nominal feed should not accrue a meaningful overrun")
    }

    /// A paced/underfed feed — where each write's wall-clock gap is much
    /// larger than the audio time it represents (e.g. the producer stalls) —
    /// must show up as a growing deficit, not get silently absorbed.
    @Test func underfedFeedReflectsDeficit() {
        let tracker = WriteCadenceTracker()
        let sampleRate = 44100
        let samplesPerWrite = 352
        let audioSeconds = Double(samplesPerWrite) / Double(sampleRate) // ~8ms

        tracker.record(samples: samplesPerWrite, sampleRate: sampleRate) // seed baseline

        // Simulate 5 writes, each arriving ~50ms late relative to the ~8ms of
        // audio it represents -> ~42ms deficit per write, ~210ms cumulative.
        let stallSeconds = 0.05
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: stallSeconds)
            tracker.record(samples: samplesPerWrite, sampleRate: sampleRate)
        }

        let snapshot = tracker.snapshot()
        #expect(snapshot.writeCount == 6)
        let expectedDeficitPerWrite = stallSeconds - audioSeconds
        let expectedTotal = expectedDeficitPerWrite * 5
        // Allow generous scheduling slop (Thread.sleep is not exact) but the
        // deficit must clearly reflect the stall, not be near zero.
        #expect(snapshot.deficitSeconds > expectedTotal * 0.5)
        #expect(snapshot.lastGapSeconds > 0, "last gap should be positive (behind) after a stall")
        #expect(abs(snapshot.overrunSeconds - 0) <= 0.01, "an underfed feed should not also register overrun")
    }

    /// The inverse: a burst of writes delivered faster than the audio time
    /// they represent (e.g. catching up after a stall) must register as
    /// overrun, tracked separately from deficit (never allowed to cancel a
    /// prior deficit out silently).
    @Test func burstFeedReflectsOverrun() {
        let tracker = WriteCadenceTracker()
        let sampleRate = 44100
        // A large sample count per write so its audio-time is much bigger
        // than the (near-zero) wall-clock time consumed issuing the calls
        // back-to-back with no sleep in between.
        let samplesPerWrite = 44100 // 1 full second of audio per write

        tracker.record(samples: samplesPerWrite, sampleRate: sampleRate) // seed baseline
        for _ in 0..<3 {
            tracker.record(samples: samplesPerWrite, sampleRate: sampleRate)
        }

        let snapshot = tracker.snapshot()
        #expect(snapshot.writeCount == 4)
        #expect(snapshot.overrunSeconds > 2.5, "back-to-back big-audio-time writes should register as overrun")
        #expect(snapshot.lastGapSeconds < 0, "last gap should be negative (ahead) during a burst")
        #expect(abs(snapshot.deficitSeconds - 0) <= 0.01)
    }

    /// `reset()` clears counters AND forgets the last-write baseline, so the
    /// write immediately after a reset seeds fresh rather than comparing
    /// against a stale (now-ancient) timestamp and reporting a bogus deficit.
    @Test func resetClearsCountersAndBaseline() {
        let tracker = WriteCadenceTracker()
        tracker.record(samples: 352, sampleRate: 44100)
        Thread.sleep(forTimeInterval: 0.05)
        tracker.record(samples: 352, sampleRate: 44100)
        #expect(tracker.snapshot().deficitSeconds > 0)

        tracker.reset()
        let afterReset = tracker.snapshot()
        #expect(afterReset.writeCount == 0)
        #expect(afterReset.deficitSeconds == 0)
        #expect(afterReset.overrunSeconds == 0)
        #expect(afterReset.lastGapSeconds == 0)

        // The very next record() call must seed the baseline again (no huge
        // deficit from comparing against the pre-reset timestamp).
        tracker.record(samples: 352, sampleRate: 44100)
        #expect(tracker.snapshot().writeCount == 1)
        #expect(tracker.snapshot().deficitSeconds == 0, "first record after reset only seeds the baseline")
    }

    /// Degenerate inputs (zero samples/rate) must be ignored, not corrupt the
    /// tracker or crash on a division.
    @Test func degenerateInputsAreIgnored() {
        let tracker = WriteCadenceTracker()
        tracker.record(samples: 0, sampleRate: 44100)
        tracker.record(samples: 352, sampleRate: 0)
        #expect(tracker.snapshot().writeCount == 0)
    }

    /// A backpressure-refused write (recorded first as every producer write is,
    /// then charged back via `recordRefused`) must ADD its audio time to the
    /// cumulative deficit — refused audio was never delivered, so counting it
    /// as delivered under-reports the receiver-visible shortfall — while
    /// leaving the producer-cadence fields (`writeCount`, `lastGapSeconds`,
    /// `overrunSeconds`) untouched, and must stay separately visible via the
    /// refused counters.
    @Test func refusedWriteChargesDeficitAndStaysSeparatelyVisible() {
        let tracker = WriteCadenceTracker()
        let sampleRate = 44100
        let samples = 4410 // 0.1s of audio per write
        let audioSeconds = Double(samples) / Double(sampleRate)

        tracker.record(samples: samples, sampleRate: sampleRate) // seed baseline
        tracker.record(samples: samples, sampleRate: sampleRate) // the write that gets refused
        let before = tracker.snapshot()

        tracker.recordRefused(samples: samples, sampleRate: sampleRate)
        let after = tracker.snapshot()

        #expect(after.refusedWrites == 1)
        #expect(abs(after.refusedSeconds - audioSeconds) <= 1e-9)
        #expect(abs((after.deficitSeconds - before.deficitSeconds) - audioSeconds) <= 1e-9,
                "the refused write's audio time must be charged back into the deficit")
        // The paired `record` already measured this write's producer gap —
        // a refusal must not double-touch the producer-cadence fields.
        #expect(after.writeCount == before.writeCount)
        #expect(after.lastGapSeconds == before.lastGapSeconds)
        #expect(after.overrunSeconds == before.overrunSeconds)

        // Degenerate refusals are ignored, like degenerate records.
        tracker.recordRefused(samples: 0, sampleRate: sampleRate)
        tracker.recordRefused(samples: samples, sampleRate: 0)
        #expect(tracker.snapshot().refusedWrites == 1)

        // And `reset()` clears the refused counters with everything else.
        tracker.reset()
        let cleared = tracker.snapshot()
        #expect(cleared.refusedWrites == 0)
        #expect(cleared.refusedSeconds == 0)
        #expect(cleared.deficitSeconds == 0)
    }

    /// Deficit and overrun are one-sided sums, so a feed that wobbles evenly
    /// around real time drives BOTH up without losing a single sample. Reading
    /// `deficitSeconds` alone therefore reports drift that is not happening;
    /// `netDriftSeconds` must stay near zero across that same feed.
    ///
    /// Assertions are RELATIVE (net small *compared to* the buckets) rather
    /// than absolute: `Thread.sleep` only ever overshoots, so each write adds a
    /// little one-sided noise to the deficit side. The margin absorbs that
    /// without hiding the bug — a one-sided sum mistaken for drift puts the net
    /// at ~100% of a bucket, not under 30%.
    @Test func symmetricJitterInflatesBucketsButNotNetDrift() {
        let tracker = WriteCadenceTracker()
        let sampleRate = 44100
        let pauseSeconds = 0.05
        // Alternate a write claiming ~2x the elapsed audio (runs ahead ->
        // overrun) with one claiming almost none (runs behind -> deficit).
        let aheadSamples = Int(pauseSeconds * 2 * Double(sampleRate))
        let behindSamples = 64

        tracker.record(samples: aheadSamples, sampleRate: sampleRate) // seed
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: pauseSeconds)
            tracker.record(samples: aheadSamples, sampleRate: sampleRate)
            Thread.sleep(forTimeInterval: pauseSeconds)
            tracker.record(samples: behindSamples, sampleRate: sampleRate)
        }

        let snap = tracker.snapshot()
        #expect(snap.deficitSeconds > 0.1, "the wobble must actually reach the deficit bucket")
        #expect(snap.overrunSeconds > 0.1, "and the overrun bucket too")
        let bucket = min(snap.deficitSeconds, snap.overrunSeconds)
        #expect(abs(snap.netDriftSeconds) < 0.3 * bucket,
                """
                net drift \(snap.netDriftSeconds)s should be small beside \
                deficit \(snap.deficitSeconds)s / overrun \(snap.overrunSeconds)s \
                — symmetric jitter is not lost audio
                """)
        #expect(snap.stallCount == 0, "ordinary jitter is not a discontinuity")
    }

    /// A gap far longer than the audio it spans is a discontinuity — playback
    /// paused, the Mac slept, the tap was rebuilt — not slow feeding. It must
    /// land in `stalledSeconds`, leaving the drift totals alone: charged to the
    /// deficit, a single sleep contributes more than every real gap combined.
    @Test func longGapIsChargedToStallNotDrift() {
        // Threshold injected so the discontinuity is reachable without a real
        // five-second sleep; production keeps the default.
        let tracker = WriteCadenceTracker(stallGapSeconds: 0.05)
        let sampleRate = 44100

        tracker.record(samples: 64, sampleRate: sampleRate) // seed
        Thread.sleep(forTimeInterval: 0.15)                 // the "pause"
        tracker.record(samples: 64, sampleRate: sampleRate)

        let snap = tracker.snapshot()
        #expect(snap.stallCount == 1)
        #expect(snap.stalledSeconds > 0.05, "the whole gap belongs to the stall bucket")
        #expect(snap.deficitSeconds == 0, "a discontinuity must not read as drift")
        #expect(snap.netDriftSeconds == 0)

        // A gap under the threshold still counts as ordinary deficit.
        Thread.sleep(forTimeInterval: 0.01)
        tracker.record(samples: 64, sampleRate: sampleRate)
        #expect(tracker.snapshot().deficitSeconds > 0)
        #expect(tracker.snapshot().stallCount == 1)

        tracker.reset()
        #expect(tracker.snapshot().stalledSeconds == 0)
        #expect(tracker.snapshot().stallCount == 0)
    }

    /// Refused audio never reached the receiver, so unlike symmetric jitter it
    /// is real loss and MUST move the net — the counter-check to
    /// `symmetricJitterInflatesBucketsButNotNetDrift`.
    @Test func refusedWriteMovesNetDrift() {
        let tracker = WriteCadenceTracker()
        let samples = 4410 // 0.1s
        let audioSeconds = Double(samples) / 44100.0

        tracker.record(samples: samples, sampleRate: 44100)
        let before = tracker.snapshot().netDriftSeconds
        tracker.recordRefused(samples: samples, sampleRate: 44100)

        #expect(abs((tracker.snapshot().netDriftSeconds - before) - audioSeconds) <= 1e-9)
    }
}

// MARK: - AirPlayEngine.write(pcm:pts:) end-to-end
//
// Split out of `WriteCadenceTests` above and nested into
// `SerializedEngineState` because these two — unlike the pure
// `WriteCadenceTracker` cases — build a real `AirPlayEngine` and call
// `enterHeadlessTestMode()`, which overwrites THREE process-wide `static
// shared` hook targets (`CompletionRegistry.shared`, `StateStreamHub.shared`,
// `RemoteEventHub.shared` — each `install()` re-points the C hook at the new
// engine's hub) plus the shared `shims/outputs.c` registry. Under XCTest's
// one-process-per-test-METHOD model only ever one engine existed at a time;
// under swift-testing's in-process concurrency a second engine entering
// headless mode mid-test steals the hooks from whichever engine
// `StateStreamTests` / `RemoteEventStreamTests` / `AirPlayEngineAPITests` /
// `E1StabilityTests` / `MultiStreamWriteRoutingTests` /
// `StartBufferAndLatencyProbeTests` is driving — those tests then simply never
// see their events and time out. Every `enterHeadlessTestMode()` caller
// in this target nests here.
// (These two also stall on `Task.sleep` and assert tight cadence bounds, so
// serialising them removes a second, independent source of flake.)
//
// The pure tracker suite above deliberately stays OUT of the serialized parent
// — it touches nothing global, and over-adding costs real wall-clock since
// everything under the parent runs strictly one at a time. Same split as
// `AirPlayEngineScaffoldTests` / `AirPlayEngineScaffoldLinkTests`.
extension SerializedEngineState {

@Suite struct WriteCadenceEngineWritePathTests {

    /// The hot `write` path actually feeds the tracker: a paced/underfed
    /// synthetic feed through the real public API reflects a deficit via
    /// `writeCadenceSnapshot()`.
    @Test func engineWritePathFeedsCadenceTracker() async throws {
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode()

        let samplesPerWrite = 352
        let bytesPerSample = 2 * 2 // S16LE, stereo
        let pcm = Data(repeating: 0, count: samplesPerWrite * bytesPerSample)
        let pts = timespec(tv_sec: 0, tv_nsec: 0)

        engine.write(pcm: pcm, pts: pts) // seeds baseline

        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 50_000_000) // stall well beyond the ~8ms frame
            engine.write(pcm: pcm, pts: pts)
        }

        let snapshot = engine.writeCadenceSnapshot()
        #expect(snapshot.writeCount == 6)
        #expect(snapshot.deficitSeconds > 0.1, "underfed real writes through the public API must show a deficit")
    }

    /// A nominal feed through the public API stays ~zero, mirroring the unit
    /// test above but exercised through the actual hot path.
    @Test func engineWritePathNominalFeedStaysNearZero() async throws {
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode()

        let samplesPerWrite = 352
        let sampleRate = 44100
        let audioSeconds = Double(samplesPerWrite) / Double(sampleRate)
        let pcm = Data(repeating: 0, count: samplesPerWrite * 4)
        let pts = timespec(tv_sec: 0, tv_nsec: 0)

        engine.write(pcm: pcm, pts: pts)
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: UInt64(audioSeconds * 1e9))
            engine.write(pcm: pcm, pts: pts)
        }

        let snapshot = engine.writeCadenceSnapshot()
        #expect(snapshot.writeCount == 11)
        #expect(snapshot.deficitSeconds < 0.15)
        #expect(snapshot.overrunSeconds < 0.15)
    }

    /// Wiring proof for the refusal accounting through the REAL public write
    /// path: a write the backpressure guard refuses (stream preloaded to the
    /// cap, same idiom as `WriteBacklogTests.engineDropsSaturatedStreamThenSelfHeals`)
    /// must surface in `writeCadenceSnapshot()` as a refused write whose audio
    /// time is folded into the deficit — the engine's own drop site no longer
    /// counts as delivered audio.
    @Test func engineRefusedWriteIsChargedToCadenceDeficit() async {
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode()

        let samplesPerWrite = 352
        let audioSeconds = Double(samplesPerWrite) / 44100.0
        let pcm = Data(repeating: 0xAB, count: samplesPerWrite * 4) // S16LE stereo
        let pts = timespec(tv_sec: 0, tv_nsec: 0)

        // Saturate stream 9's backlog WITHOUT draining it — models
        // enqueued-but-not-yet-run write bodies during an engine-thread stall.
        let reservation: [(streamId: UInt32, audioSeconds: Double)] =
            [(streamId: 9, audioSeconds: engine.writeBacklog.capSeconds)]
        #expect(engine.writeBacklog.admit(reservation))

        engine.write(pcm: pcm, streamId: 9, pts: pts) // refused by backpressure

        let snap = engine.writeCadenceSnapshot()
        #expect(engine.writeBacklogSnapshot().droppedWrites == 1)
        #expect(snap.refusedWrites == 1, "the refused write must be counted")
        #expect(abs(snap.refusedSeconds - audioSeconds) <= 1e-9)
        // The first record only seeds the baseline (zero gap contribution), so
        // the whole deficit here is exactly the refused audio time.
        #expect(abs(snap.deficitSeconds - audioSeconds) <= 1e-9,
                "refused audio must be charged into the cumulative deficit")

        engine.writeBacklog.release(reservation)
    }
}

} // extension SerializedEngineState
