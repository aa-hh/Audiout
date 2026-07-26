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
// see their events and time out. Every other `enterHeadlessTestMode()` caller
// in this target already nests here; this file was the one that did not.
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
}

} // extension SerializedEngineState
