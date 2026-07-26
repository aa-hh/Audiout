// Write-path backpressure guard tests (memory-leak audit 2026-07-23).
//
// The audit found exactly one unbounded-growth site in this layer:
// `AirPlayEngine.write(streams:pts:)` heap-copies each PCM buffer and enqueues a
// closure onto the single engine thread with NO queue-depth cap. If that thread
// stops draining (a wedged vendored callback — the mode `EngineThread.stop()`
// leaks the thread for), producers pile PCM-carrying closures onto libevent's
// pending list without bound. `WriteBacklogGuard` caps the un-drained audio per
// stream and drops writes past it.
//
// SCOPE: BUILD + HEADLESS ONLY. No real event loop, no sockets, no PTP.
//
// Two levels, mirroring WriteCadenceTests:
//   1. `WriteBacklogGuard` directly — deterministic control over admit/release,
//      which is where the cap logic, per-stream isolation, and the self-healing
//      (NOT one-shot) property live. This is the authoritative proof, because in
//      headless mode `write`'s body runs INLINE (admit then immediate release),
//      so the engine path alone can never let a backlog accumulate.
//   2. `AirPlayEngine.write(streams:pts:)` end-to-end in headless mode — proves
//      the guard is actually WIRED into the hot path: healthy writes all reach
//      the C fan-out with no spurious drops, a write for a stream already at the
//      cap is dropped (never reaches `airplay_write`) while an unrelated stream
//      is unaffected, and once the backlog drains the same stream admits again.

import Foundation
import Testing
@testable import AirPlayEngine
import CAirPlayEngine

// `shims/outputs.c`'s device/callback registry is process-global C state, so
// this suite nests into the package's one `.serialized` parent (see
// SerializedEngineStateSuite.swift). Do NOT repeat `.serialized` here.
extension SerializedEngineState {

    @Suite struct WriteBacklogTests {

        // MARK: - Level 1: WriteBacklogGuard direct

        private typealias Additions = [(streamId: UInt32, audioSeconds: Double)]

        /// (a) Writes whose per-stream backlog stays under the cap all admit — no
        /// drops, and the tracked backlog grows by exactly the audio-time added.
        @Test func writesUnderCapAllAdmit() {
            let guardUnit = WriteBacklogGuard(capSeconds: 1.0)
            let add: Additions = [(streamId: 1, audioSeconds: 0.1)] // 100ms/write

            for i in 1...9 {
                #expect(guardUnit.admit(add), "write \(i) under cap must admit")
                #expect(abs(guardUnit.inFlightSeconds(streamId: 1) - Double(i) * 0.1) <= 1e-9)
            }
            #expect(guardUnit.snapshot().droppedWrites == 0, "nothing under the cap should drop")
        }

        /// (b) A write whose stream is already AT the cap is dropped (admit returns
        /// false) and the drop is observable via the snapshot's dropped counter. The
        /// backlog is not grown by a dropped write.
        @Test func writeAtCapIsDroppedAndObservable() {
            let guardUnit = WriteBacklogGuard(capSeconds: 0.1)
            let add: Additions = [(streamId: 1, audioSeconds: 0.05)] // 50ms/write

            #expect(guardUnit.admit(add))  // 50ms
            #expect(guardUnit.admit(add))  // 100ms == cap
            let atCap = guardUnit.inFlightSeconds(streamId: 1)

            #expect(!guardUnit.admit(add), "a write for a stream at the cap must be dropped")
            #expect(guardUnit.inFlightSeconds(streamId: 1) == atCap,
                       "a dropped write must not grow the backlog")
            #expect(guardUnit.snapshot().droppedWrites == 1, "the drop must be observable")
        }

        /// (c) THE KEY CORRECTNESS PROPERTY: the cap self-heals — it is NOT a one-shot
        /// trip. Once a briefly-congested stream drains back below the cap (a body
        /// actually RAN, i.e. `release`), the very next write admits again.
        @Test func capSelfHealsAfterDrain_notOneShot() {
            let guardUnit = WriteBacklogGuard(capSeconds: 0.1)
            let add: Additions = [(streamId: 1, audioSeconds: 0.05)]

            #expect(guardUnit.admit(add))   // 50ms
            #expect(guardUnit.admit(add))   // 100ms == cap
            #expect(!guardUnit.admit(add))  // dropped
            #expect(!guardUnit.admit(add))  // still dropping while at the ceiling
            #expect(guardUnit.snapshot().droppedWrites == 2)

            // A body drains (release) -> backlog falls below the cap.
            guardUnit.release(add)                // back to 50ms
            #expect(guardUnit.inFlightSeconds(streamId: 1) < guardUnit.capSeconds)

            // ...and the stream accepts writes again with no further drop. This is the
            // property the spec calls out: the cap must not permanently refuse writes
            // after ever hitting the ceiling once.
            #expect(guardUnit.admit(add), "after draining below the cap the stream must admit again")
            #expect(guardUnit.snapshot().droppedWrites == 2, "self-heal must not record a new drop")
        }

        /// A single write LARGER than the whole cap is still admitted on an empty
        /// stream (admit tests the CURRENT backlog, not the post-add total), then
        /// drops until it drains — so an oversized write can never permanently wedge a
        /// stream. Guards against a subtle one-shot the "would exceed after adding"
        /// formulation would introduce.
        @Test func oversizedSingleWriteNeverPermanentlyWedges() {
            let guardUnit = WriteBacklogGuard(capSeconds: 0.1)
            let big: Additions = [(streamId: 1, audioSeconds: 0.5)] // 5x the cap in one write

            #expect(guardUnit.admit(big), "an empty stream must admit even an oversized write")
            #expect(!guardUnit.admit(big), "now over cap -> drop")
            guardUnit.release(big)                                   // drains
            #expect(guardUnit.admit(big), "must admit again once drained — never a permanent wedge")
        }

        /// A stalled stream at the cap must NOT block writes for an unrelated stream:
        /// per-stream isolation, the reason the guard keys on `streamId`.
        @Test func perStreamIsolation() {
            let guardUnit = WriteBacklogGuard(capSeconds: 0.1)
            let s1: Additions = [(streamId: 1, audioSeconds: 0.1)] // fills stream 1 to the cap
            let s2: Additions = [(streamId: 2, audioSeconds: 0.05)]

            #expect(guardUnit.admit(s1))    // stream 1 at cap
            #expect(!guardUnit.admit(s1), "stream 1 is at the cap -> dropped")

            // Stream 2 is untouched by stream 1's congestion.
            #expect(guardUnit.admit(s2), "an unrelated stream must not be blocked by a stalled one")
            #expect(guardUnit.admit(s2))
            #expect(abs(guardUnit.inFlightSeconds(streamId: 2) - 0.1) <= 1e-9)
        }

        /// Balanced admit/release returns the backlog to exactly zero and PRUNES the
        /// stream from the tracking dictionary (so it stays bounded by active streams).
        @Test func balancedAdmitReleaseReturnsToZeroAndPrunes() {
            let guardUnit = WriteBacklogGuard(capSeconds: 5.0)
            let add: Additions = [(streamId: 7, audioSeconds: 0.05)]

            for _ in 0..<10 { #expect(guardUnit.admit(add)) }
            #expect(guardUnit.snapshot().streamsTracked == 1)
            for _ in 0..<10 { guardUnit.release(add) }

            #expect(guardUnit.inFlightSeconds(streamId: 7) == 0)
            #expect(guardUnit.snapshot().streamsTracked == 0, "a fully-drained stream must be pruned")
            #expect(guardUnit.snapshot().maxInFlightSeconds == 0)
        }

        /// A batch (several streams in one call, sharing one phase-aligned pts) is
        /// admitted or dropped as a UNIT: if any one of its streams is at the cap, the
        /// whole call is dropped (a phase-aligned batch can't be partially delivered).
        @Test func batchAdmittedOrDroppedAsAUnit() {
            let guardUnit = WriteBacklogGuard(capSeconds: 0.1)

            // Push stream 2 to the cap on its own.
            #expect(guardUnit.admit([(streamId: 2, audioSeconds: 0.1)]))

            // A batch touching streams 1, 2, 3 must be dropped because stream 2 is full
            // — and streams 1 and 3 must NOT have been charged for the dropped batch.
            let batch: Additions = [
                (streamId: 1, audioSeconds: 0.02),
                (streamId: 2, audioSeconds: 0.02),
                (streamId: 3, audioSeconds: 0.02),
            ]
            #expect(!guardUnit.admit(batch), "a batch with any at-cap stream is dropped as a unit")
            #expect(guardUnit.inFlightSeconds(streamId: 1) == 0, "an under-cap member of a dropped batch is not charged")
            #expect(guardUnit.inFlightSeconds(streamId: 3) == 0)

            // With stream 2 drained, the same batch now admits and charges every member.
            guardUnit.release([(streamId: 2, audioSeconds: 0.1)])
            #expect(guardUnit.admit(batch))
            #expect(abs(guardUnit.inFlightSeconds(streamId: 1) - 0.02) <= 1e-9)
            #expect(abs(guardUnit.inFlightSeconds(streamId: 3) - 0.02) <= 1e-9)
        }

        /// `reset()` clears backlog, dropping-state, and counters (fresh session).
        @Test func resetClearsEverything() {
            let guardUnit = WriteBacklogGuard(capSeconds: 0.1)
            let add: Additions = [(streamId: 1, audioSeconds: 0.1)]
            #expect(guardUnit.admit(add))
            #expect(!guardUnit.admit(add)) // one drop recorded, stream at cap

            guardUnit.reset()

            let snap = guardUnit.snapshot()
            #expect(snap.droppedWrites == 0)
            #expect(snap.streamsTracked == 0)
            #expect(guardUnit.inFlightSeconds(streamId: 1) == 0)
            // And a reset stream admits immediately (dropping-state cleared too).
            #expect(guardUnit.admit(add))
        }

        // MARK: - Level 2: AirPlayEngine.write(streams:pts:) end-to-end (headless)

        private func defaultQuality() -> media_quality {
            media_quality(sample_rate: 44100, bits_per_sample: 16, channels: 2, bit_rate: 0)
        }

        /// Interleaved S16LE stereo PCM of exactly `samples` sample-frames.
        private func pcm(samples: Int, fill: UInt8 = 0xAB) -> Data {
            Data(repeating: fill, count: samples * 2 /* channels */ * 2 /* bytes/sample */)
        }

        // setUp/tearDown were symmetric (both reset the master-session table +
        // dispatcher + drain the registry), so per the cookbook's §11(a) guidance
        // the reset folds into `init` alone — no `deinit` needed, so this stays a
        // `struct`.
        init() {
            airplay_test_master_sessions_reset()
            outputs_dispatcher_reset()
            drainRegistry()
        }

        private func drainRegistry() {
            while let head = outputs_list() { outputs_device_remove(head) }
        }

        /// Healthy path: several nominal writes all reach the C fan-out (the master
        /// session's input_buffer accumulates the full sample count), the guard
        /// records ZERO drops, and — because the headless body drains inline — the
        /// per-stream backlog returns to zero (proving `release` is wired into the
        /// body, so a real drain would decrement the same way).
        @Test func engineHealthyWritesAllLandWithNoDrops() async {
            var q = defaultQuality()
            let ams = airplay_test_master_session_make(5, &q, false)
            #expect(ams != nil)

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode()
            let pts = timespec(tv_sec: 0, tv_nsec: 0)

            // Keep the total under one AirPlay packet (352 samples) so the fan-out
            // only ever appends to input_buffer and never crosses into the
            // ALAC-encode/RTP flush path (same constraint as MultiStreamWriteRoutingTests).
            let writes = 6, samplesEach = 50 // 300 total, < 352
            for _ in 0..<writes { engine.write(pcm: pcm(samples: samplesEach), streamId: 5, pts: pts) }
            try? await Task.sleep(nanoseconds: 20_000_000)

            #expect(airplay_test_master_session_input_buffer_samples(ams) == UInt32(writes * samplesEach),
                       "every healthy write must reach the fan-out — the guard must not spuriously drop")
            let snap = engine.writeBacklogSnapshot()
            #expect(snap.droppedWrites == 0)
            #expect(engine.writeBacklog.inFlightSeconds(streamId: 5) == 0,
                       "inline drain must release the reservation — backlog returns to zero")
        }

        /// Wiring proof for the DROP and SELF-HEAL paths through the REAL engine.write
        /// path. Headless bodies drain inline, so to exercise a saturated stream we
        /// preload the guard to the cap for stream 1 (simulating undrained closures),
        /// then drive the actual public write API:
        ///   - a write for the saturated stream 1 is DROPPED (never reaches its master
        ///     session), and the engine's dropped counter increments;
        ///   - a write for the unrelated stream 2 in the same window LANDS (per-stream
        ///     isolation end-to-end);
        ///   - after the stream-1 backlog is released, a stream-1 write LANDS again
        ///     (self-heal end-to-end — the cap is not a one-shot).
        @Test func engineDropsSaturatedStreamThenSelfHeals() async {
            var q = defaultQuality()
            let ams1 = airplay_test_master_session_make(1, &q, false)
            let ams2 = airplay_test_master_session_make(2, &q, false)
            #expect(ams1 != nil); #expect(ams2 != nil)

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode()
            let pts = timespec(tv_sec: 0, tv_nsec: 0)

            // Saturate stream 1's backlog to the cap WITHOUT draining it — models
            // enqueued-but-not-yet-run write bodies during an engine-thread stall.
            let cap = engine.writeBacklog.capSeconds
            let stream1Reservation: Additions = [(streamId: 1, audioSeconds: cap)]
            #expect(engine.writeBacklog.admit(stream1Reservation))

            // Write to the saturated stream 1 (dropped) and the free stream 2 (lands).
            engine.write(pcm: pcm(samples: 100), streamId: 1, pts: pts)
            engine.write(pcm: pcm(samples: 40), streamId: 2, pts: pts)
            try? await Task.sleep(nanoseconds: 20_000_000)

            #expect(airplay_test_master_session_input_buffer_samples(ams1) == 0,
                       "a write for a stream at the cap must be dropped before the fan-out")
            #expect(airplay_test_master_session_input_buffer_samples(ams2) == 40,
                       "an unrelated stream must keep flowing while stream 1 is saturated")
            #expect(engine.writeBacklogSnapshot().droppedWrites >= 1,
                       "the engine's write path must record the drop")

            // Release stream 1's backlog (its bodies drained) and write again: it flows.
            engine.writeBacklog.release(stream1Reservation)
            engine.write(pcm: pcm(samples: 100), streamId: 1, pts: pts)
            try? await Task.sleep(nanoseconds: 20_000_000)

            #expect(airplay_test_master_session_input_buffer_samples(ams1) == 100,
                       "once its backlog drains, the previously-saturated stream must flow again")
        }
    }
}
