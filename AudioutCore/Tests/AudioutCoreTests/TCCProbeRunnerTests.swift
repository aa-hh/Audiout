// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// T14: exercises ``TCCProbeRunner``'s single-flight coalescing, timeout
/// reporting, and output parsing entirely headlessly — never spawns a real
/// `tcc-probe` process. Every test injects a fake ``TCCProbeRunner/SpawnHelper``
/// that hands back a scripted ``TCCProbeRunner/SpawnOutcome`` on a background
/// queue, mirroring how the real `Process`-backed implementation would call
/// back asynchronously.
@Suite struct TCCProbeRunnerTests {

    // MARK: - Parsing / interpretation (pure — no runner instance needed)

    @Test func interpret_grantedLine_resolvesGranted() {
        let (result, raw) = TCCProbeRunner.interpret(.output("audio=0 screen=1 control=1\n"))
        #expect(result == .resolved(.granted))
        #expect(raw == .init(audio: 0, screen: 1, control: 1))
    }

    @Test func interpret_deniedLine_resolvesDenied() {
        let (result, raw) = TCCProbeRunner.interpret(.output("audio=1 screen=1 control=1"))
        #expect(result == .resolved(.denied))
        #expect(raw == .init(audio: 1, screen: 1, control: 1))
    }

    @Test func interpret_undeterminedLine_resolvesUndetermined() {
        let (result, raw) = TCCProbeRunner.interpret(.output("audio=2 screen=0 control=1"))
        #expect(result == .resolved(.undetermined))
        #expect(raw == .init(audio: 2, screen: 0, control: 1))
    }

    /// The load-bearing check from `tcc-probe/main.swift`'s doc comment: a
    /// control that isn't exactly 1 means the whole read is void — this must
    /// report `.unresolved(.controlMismatch)`, NEVER a `.resolved(...)` built
    /// from the (meaningless) audio/screen values on the same line.
    @Test func interpret_controlMismatch_isUnresolvedNeverDenied() {
        let (result, raw) = TCCProbeRunner.interpret(.output("audio=1 screen=1 control=0"))
        #expect(result == .unresolved(.controlMismatch))
        // The raw numbers are still surfaced for diagnostics (TCCBucketDiagnostic
        // logs them either way) — only the INTERPRETED result must refuse to
        // trust them.
        #expect(raw == .init(audio: 1, screen: 1, control: 0))
    }

    @Test func interpret_malformedOutput_isUnresolved() {
        for bad in ["", "garbage", "audio=0 screen=1", "audio=x screen=1 control=1", "screen=1 audio=0 control=1"] {
            let (result, raw) = TCCProbeRunner.interpret(.output(bad))
            #expect(result == .unresolved(.malformedOutput), "input: \(bad)")
            #expect(raw == nil, "input: \(bad)")
        }
    }

    @Test func interpret_helperMissing_spawnFailed_timedOut_areUnresolvedWithNoRawReading() {
        #expect(TCCProbeRunner.interpret(.helperMissing).0 == .unresolved(.helperMissing))
        #expect(TCCProbeRunner.interpret(.helperMissing).1 == nil)
        #expect(TCCProbeRunner.interpret(.spawnFailed).0 == .unresolved(.spawnFailed))
        #expect(TCCProbeRunner.interpret(.spawnFailed).1 == nil)
        #expect(TCCProbeRunner.interpret(.timedOut).0 == .unresolved(.timedOut))
        #expect(TCCProbeRunner.interpret(.timedOut).1 == nil)
    }

    // MARK: - Single resolution round-trip

    @Test func requestResolution_singleCall_deliversResolvedResult() async throws {
        let runner = TCCProbeRunner(spawn: fakeSpawn { timeout, completion in
            DispatchQueue.global().async { completion(.output("audio=0 screen=0 control=1")) }
        })
        let answered = Locked(0)
        try await confirmation(expectedCount: 1) { done in
            runner.requestResolution { result, raw in
                #expect(result == .resolved(.granted))
                #expect(raw?.audio == 0)
                done()
                _ = answered.increment()
            }
            await waitForCompletion { answered.value > 0 }
        }
    }

    // MARK: - Single-flight coalescing (the core contract)

    /// A burst of calls that all arrive while the first spawn is still
    /// running must produce AT MOST TWO spawns total: the one already
    /// running, plus one coalesced re-kick that answers every call queued
    /// during it. This is what replaces a coalescing `Timer`.
    @Test func burstOfCallsWhileInFlight_producesAtMostTwoSpawns() async throws {
        let spawnCount = Locked(0)
        // Held open until the test explicitly releases it, so every burst
        // call below is guaranteed to land while spawn #1 is still running.
        let releaseFirstSpawn = DispatchSemaphore(value: 0)
        var secondSpawnCompletion: ((TCCProbeRunner.SpawnOutcome) -> Void)?
        let secondSpawnStarted = DispatchSemaphore(value: 0)

        let runner = TCCProbeRunner(spawn: { _, completion in
            let n = spawnCount.increment()
            if n == 1 {
                DispatchQueue.global().async {
                    releaseFirstSpawn.wait()
                    completion(.output("audio=2 screen=2 control=1"))
                }
            } else {
                secondSpawnCompletion = completion
                secondSpawnStarted.signal()
            }
        })

        let completions = Locked(0)
        let burstSize = 20
        for _ in 0..<burstSize {
            runner.requestResolution { _, _ in _ = completions.increment() }
        }

        releaseFirstSpawn.signal()
        secondSpawnStarted.wait()

        // The re-kick (spawn #2) is what answers every coalesced call from
        // the burst — finish it now.
        secondSpawnCompletion?(.output("audio=0 screen=0 control=1"))

        // Wait for the completions to run, then assert the totals. A fixed
        // pause here would be the same wall-clock bet the other tests used to
        // make: it passes on an idle machine and loses under a full run.
        await waitForCompletion { completions.value == burstSize }

        #expect(spawnCount.value == 2, "a burst behind one in-flight spawn must coalesce into exactly one re-kick")
        #expect(completions.value == burstSize, "every queued caller must still get answered exactly once")
    }

    /// Two calls made back-to-back with NOTHING in flight (the common case —
    /// no burst) must each get their own spawn; single-flight only coalesces
    /// concurrent/overlapping requests, it doesn't rate-limit sequential ones.
    @Test func sequentialCallsAfterCompletion_eachGetOwnSpawn() async throws {
        let spawnCount = Locked(0)
        let runner = TCCProbeRunner(spawn: { _, completion in
            _ = spawnCount.increment()
            DispatchQueue.global().async { completion(.output("audio=0 screen=0 control=1")) }
        })

        let answered = Locked(0)
        try await confirmation("first") { done in
            runner.requestResolution { _, _ in done(); _ = answered.increment() }
            await waitForCompletion { answered.value > 0 }
        }

        try await confirmation("second") { done in
            runner.requestResolution { _, _ in done(); _ = answered.increment() }
            await waitForCompletion { answered.value > 1 }
        }

        #expect(spawnCount.value == 2)
    }

    // MARK: - Timeout / reap

    @Test func timeout_reportsTimedOutNotMalformedOutput() async throws {
        let runner = TCCProbeRunner(hardTimeout: 0.05, spawn: fakeSpawn { timeout, completion in
            // Never calls completion on its own — simulates a hung child;
            // the runner's own timeout plumbing is what the PRODUCTION spawn
            // would enforce. This fake proves `interpret` never sees a
            // dangling call: TCCProbeRunnerTests only needs to prove the
            // TIMEOUT case is reported correctly when it happens, which the
            // production `productionSpawn` implements via a real
            // `DispatchWorkItem` + `Process.terminate()` (see
            // `TCCProbeRunner.swift`) — not re-tested here since that would
            // require an actual process.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 0.05) {
                completion(.timedOut)
            }
        })
        let answered = Locked(0)
        try await confirmation("timed out") { done in
            runner.requestResolution { result, raw in
                #expect(result == .unresolved(.timedOut))
                #expect(raw == nil)
                done()
                _ = answered.increment()
            }
            await waitForCompletion { answered.value > 0 }
        }
    }

    // MARK: - Helpers

    /// Generous ceiling, NOT an expected wait: returns the moment `cond()`
    /// holds, so a high bound only ever costs time in the failure case.
    ///
    /// These tests hand their result back through `DispatchQueue.global()`, and
    /// they used to hold the `confirmation` body open with a fixed
    /// `Task.sleep(for: .seconds(2))`. That is a bet that the global queue will
    /// schedule the block inside two seconds, and across a full ~3,000-test run
    /// it loses: the callback lands after the window, the confirmation records
    /// 0 of 1, and three tests fail for no reason but a busy machine. The
    /// margin was never there to begin with — one of them measured 2.126 s on
    /// an IDLE machine. Serial mode does not help, because the contention is
    /// the global queue rather than the runner's workers.
    private func waitForCompletion(
        timeout: TimeInterval? = nil,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ cond: @escaping () -> Bool
    ) async {
        await SuiteWait.until(timeout: timeout, sourceLocation: sourceLocation, cond)
    }

    /// Wraps a `SpawnHelper` closure with nothing extra — named purely so
    /// each test's spawn logic reads as "this is the fake" at the call site.
    private func fakeSpawn(_ body: @escaping TCCProbeRunner.SpawnHelper) -> TCCProbeRunner.SpawnHelper {
        body
    }

    /// Minimal `NSLock`-guarded counter — mirrors `Telemetry.Locked`'s idiom
    /// in this same package for cheap cross-thread state in a test.
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Value
        init(_ value: Value) { _value = value }
        var value: Value { lock.lock(); defer { lock.unlock() }; return _value }
        @discardableResult
        func increment() -> Int where Value == Int {
            lock.lock(); defer { lock.unlock() }
            _value += 1
            return _value
        }
    }
}
