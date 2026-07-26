// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AudiouterCore

/// T14: exercises ``TCCProbeRunner``'s single-flight coalescing, timeout
/// reporting, and output parsing entirely headlessly — never spawns a real
/// `tcc-probe` process. Every test injects a fake ``TCCProbeRunner/SpawnHelper``
/// that hands back a scripted ``TCCProbeRunner/SpawnOutcome`` on a background
/// queue, mirroring how the real `Process`-backed implementation would call
/// back asynchronously.
final class TCCProbeRunnerTests: XCTestCase {

    // MARK: - Parsing / interpretation (pure — no runner instance needed)

    func test_interpret_grantedLine_resolvesGranted() {
        let (result, raw) = TCCProbeRunner.interpret(.output("audio=0 screen=1 control=1\n"))
        XCTAssertEqual(result, .resolved(.granted))
        XCTAssertEqual(raw, .init(audio: 0, screen: 1, control: 1))
    }

    func test_interpret_deniedLine_resolvesDenied() {
        let (result, raw) = TCCProbeRunner.interpret(.output("audio=1 screen=1 control=1"))
        XCTAssertEqual(result, .resolved(.denied))
        XCTAssertEqual(raw, .init(audio: 1, screen: 1, control: 1))
    }

    func test_interpret_undeterminedLine_resolvesUndetermined() {
        let (result, raw) = TCCProbeRunner.interpret(.output("audio=2 screen=0 control=1"))
        XCTAssertEqual(result, .resolved(.undetermined))
        XCTAssertEqual(raw, .init(audio: 2, screen: 0, control: 1))
    }

    /// The load-bearing check from `tcc-probe/main.swift`'s doc comment: a
    /// control that isn't exactly 1 means the whole read is void — this must
    /// report `.unresolved(.controlMismatch)`, NEVER a `.resolved(...)` built
    /// from the (meaningless) audio/screen values on the same line.
    func test_interpret_controlMismatch_isUnresolvedNeverDenied() {
        let (result, raw) = TCCProbeRunner.interpret(.output("audio=1 screen=1 control=0"))
        XCTAssertEqual(result, .unresolved(.controlMismatch))
        // The raw numbers are still surfaced for diagnostics (TCCBucketDiagnostic
        // logs them either way) — only the INTERPRETED result must refuse to
        // trust them.
        XCTAssertEqual(raw, .init(audio: 1, screen: 1, control: 0))
    }

    func test_interpret_malformedOutput_isUnresolved() {
        for bad in ["", "garbage", "audio=0 screen=1", "audio=x screen=1 control=1", "screen=1 audio=0 control=1"] {
            let (result, raw) = TCCProbeRunner.interpret(.output(bad))
            XCTAssertEqual(result, .unresolved(.malformedOutput), "input: \(bad)")
            XCTAssertNil(raw, "input: \(bad)")
        }
    }

    func test_interpret_helperMissing_spawnFailed_timedOut_areUnresolvedWithNoRawReading() {
        XCTAssertEqual(TCCProbeRunner.interpret(.helperMissing).0, .unresolved(.helperMissing))
        XCTAssertNil(TCCProbeRunner.interpret(.helperMissing).1)
        XCTAssertEqual(TCCProbeRunner.interpret(.spawnFailed).0, .unresolved(.spawnFailed))
        XCTAssertNil(TCCProbeRunner.interpret(.spawnFailed).1)
        XCTAssertEqual(TCCProbeRunner.interpret(.timedOut).0, .unresolved(.timedOut))
        XCTAssertNil(TCCProbeRunner.interpret(.timedOut).1)
    }

    // MARK: - Single resolution round-trip

    func test_requestResolution_singleCall_deliversResolvedResult() {
        let runner = TCCProbeRunner(spawn: fakeSpawn { timeout, completion in
            DispatchQueue.global().async { completion(.output("audio=0 screen=0 control=1")) }
        })
        let done = expectation(description: "resolved")
        runner.requestResolution { result, raw in
            XCTAssertEqual(result, .resolved(.granted))
            XCTAssertEqual(raw?.audio, 0)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    // MARK: - Single-flight coalescing (the core contract)

    /// A burst of calls that all arrive while the first spawn is still
    /// running must produce AT MOST TWO spawns total: the one already
    /// running, plus one coalesced re-kick that answers every call queued
    /// during it. This is what replaces a coalescing `Timer`.
    func test_burstOfCallsWhileInFlight_producesAtMostTwoSpawns() {
        let spawnCount = Locked(0)
        // Held open until the test explicitly releases it, so every burst
        // call below is guaranteed to land while spawn #1 is still running.
        let releaseFirstSpawn = DispatchSemaphore(value: 0)
        var secondSpawnCompletion: ((TCCProbeRunner.SpawnOutcome) -> Void)?
        let secondSpawnStarted = expectation(description: "second spawn started")

        let runner = TCCProbeRunner(spawn: { _, completion in
            let n = spawnCount.increment()
            if n == 1 {
                DispatchQueue.global().async {
                    releaseFirstSpawn.wait()
                    completion(.output("audio=2 screen=2 control=1"))
                }
            } else {
                secondSpawnCompletion = completion
                secondSpawnStarted.fulfill()
            }
        })

        let completions = Locked(0)
        let burstSize = 20
        for _ in 0..<burstSize {
            runner.requestResolution { _, _ in _ = completions.increment() }
        }

        releaseFirstSpawn.signal()
        wait(for: [secondSpawnStarted], timeout: 2)

        // The re-kick (spawn #2) is what answers every coalesced call from
        // the burst — finish it now.
        secondSpawnCompletion?(.output("audio=0 screen=0 control=1"))

        // Give the completions a moment to run, then assert the totals.
        let flush = expectation(description: "flush")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { flush.fulfill() }
        wait(for: [flush], timeout: 2)

        XCTAssertEqual(spawnCount.value, 2, "a burst behind one in-flight spawn must coalesce into exactly one re-kick")
        XCTAssertEqual(completions.value, burstSize, "every queued caller must still get answered exactly once")
    }

    /// Two calls made back-to-back with NOTHING in flight (the common case —
    /// no burst) must each get their own spawn; single-flight only coalesces
    /// concurrent/overlapping requests, it doesn't rate-limit sequential ones.
    func test_sequentialCallsAfterCompletion_eachGetOwnSpawn() {
        let spawnCount = Locked(0)
        let runner = TCCProbeRunner(spawn: { _, completion in
            _ = spawnCount.increment()
            DispatchQueue.global().async { completion(.output("audio=0 screen=0 control=1")) }
        })

        let first = expectation(description: "first")
        runner.requestResolution { _, _ in first.fulfill() }
        wait(for: [first], timeout: 2)

        let second = expectation(description: "second")
        runner.requestResolution { _, _ in second.fulfill() }
        wait(for: [second], timeout: 2)

        XCTAssertEqual(spawnCount.value, 2)
    }

    // MARK: - Timeout / reap

    func test_timeout_reportsTimedOutNotMalformedOutput() {
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
        let done = expectation(description: "timed out")
        runner.requestResolution { result, raw in
            XCTAssertEqual(result, .unresolved(.timedOut))
            XCTAssertNil(raw)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    // MARK: - Helpers

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
