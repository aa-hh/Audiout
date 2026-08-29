import Foundation
import Testing
@testable import AudioutCore

/// Hermetic unit tests for `CaptureCoordinator`'s state machine. **Never** spawns
/// the real `audiocap` binary or hits a live OwnTone — every seam is a fake:
/// `FakeCaptureProcess` (scriptable stderr + termination), `FakePlaybackController`
/// (records the call sequence, scriptable failures), `FakeFIFOManager`.
///
/// Grounded in `dev/notes/0f-pipe-brief.md` (config-follows-tap, explicit
/// clear→add→play, suspend-to-pause/zombie) and `p1-owntone-api-brief.md`.
@Suite struct CaptureCoordinatorTests {

    // MARK: Fakes

    /// Records the explicit-play call order and can be scripted to fail.
    private final class FakePlaybackController: PlaybackController, @unchecked Sendable {
        let lock = NSLock()
        private(set) var calls: [String] = []
        var healthCheckError: Error?
        var pipeURI: String? = "library:track:2"
        /// Returns nil this many times before yielding `pipeURI` (simulates a
        /// FIFO not yet scanned → rescan-retry, brief §2).
        var pipeNilCount = 0
        var playError: Error?

        private func record(_ s: String) { lock.lock(); calls.append(s); lock.unlock() }
        func callList() -> [String] { lock.lock(); defer { lock.unlock() }; return calls }

        func healthCheck() async throws { record("health"); if let e = healthCheckError { throw e } }
        func updateLibrary() async throws { record("update") }
        func findPipeTrackURI() async throws -> String? {
            record("find")
            lock.lock(); let remaining = pipeNilCount; if pipeNilCount > 0 { pipeNilCount -= 1 }; lock.unlock()
            return remaining > 0 ? nil : pipeURI
        }
        func clearQueue() async throws { record("clear") }
        func addToQueue(uri: String) async throws { record("add:\(uri)") }
        func play() async throws { record("play"); if let e = playError { throw e } }
        func stop() async throws { record("stop") }
    }

    /// A fake subprocess: `start` captures the callbacks so the test can push
    /// stderr lines / a termination on demand. No real process.
    private final class FakeCaptureProcess: CaptureProcess, @unchecked Sendable {
        let lock = NSLock()
        private(set) var started = false
        private(set) var stopped = false
        private(set) var lastFifoPath: String?
        private(set) var lastExclude: [Int32] = []
        private var onLine: (@Sendable (String) -> Void)?
        private var onTerm: (@Sendable (CaptureTermination) -> Void)?

        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return started && !stopped }

        func start(fifoPath: String, excludePIDs: [Int32],
                   onStderrLine: @escaping @Sendable (String) -> Void,
                   onTermination: @escaping @Sendable (CaptureTermination) -> Void) throws {
            lock.lock()
            started = true; stopped = false
            lastFifoPath = fifoPath; lastExclude = excludePIDs
            onLine = onStderrLine; onTerm = onTermination
            lock.unlock()
        }
        func stop() {
            lock.lock(); let wasRunning = started && !stopped; stopped = true
            let term = onTerm; lock.unlock()
            // Real audiocap fires its terminationHandler after SIGINT; mirror that.
            if wasRunning { term?(.signal(signal: SIGINT)) }
        }
        func emitStderr(_ line: String) { lock.lock(); let cb = onLine; lock.unlock(); cb?(line) }
        func emitTermination(_ t: CaptureTermination) { lock.lock(); let cb = onTerm; stopped = true; lock.unlock(); cb?(t) }
    }

    private final class FakeFIFOManager: FIFOManaging, @unchecked Sendable {
        let fifoPath: String
        var createError: Error?
        let lock = NSLock()
        private(set) var created = false
        private(set) var cleaned = false
        init(fifoPath: String = "/tmp/test.fifo") { self.fifoPath = fifoPath }
        func create() throws { lock.lock(); created = true; lock.unlock(); if let e = createError { throw e } }
        func cleanup() { lock.lock(); cleaned = true; lock.unlock() }
    }

    // MARK: Builder

    private func makeCoordinator(
        fifo: FakeFIFOManager,
        process: FakeCaptureProcess,
        playback: FakePlaybackController,
        configuredRate: Int = 44100,
        excludePIDs: [Int32] = [],
        maxRestarts: Int = 3
    ) -> CaptureCoordinator {
        CaptureCoordinator(
            fifo: fifo,
            makeCaptureProcess: { process },
            playback: playback,
            configuredPipeSampleRate: configuredRate,
            excludePIDs: excludePIDs,
            pipeSearchRetries: 3,
            pipeSearchRetryDelay: 0.01,
            maxRestarts: maxRestarts
        )
    }

    /// Poll the coordinator's state until `predicate` is true or timeout.
    ///
    /// **The deadline is deliberately generous, and shortening it will make this
    /// suite fail intermittently for no reason.** Every seam here is a fake, so
    /// the state transition being waited on is not slow work — it is a hop that
    /// lands the moment this task is scheduled again. That makes the wait a test
    /// of how much CPU the poll loop gets, not of the coordinator: the whole
    /// suite runs unserialised, so at full-suite size this loop competes with
    /// ~3000 other tests and a short wall-clock deadline expires while the
    /// transition is sitting there already satisfied. That is exactly how the
    /// old 3-second default behaved — green at 3091 tests, then 6 and 11 issues
    /// in the SAME run at 3169, all recorded here, on both the local and the
    /// remote Mac. A slow deadline costs nothing on the happy path (the loop
    /// returns on the first satisfied poll) and only spends real time when
    /// something is genuinely wrong, which is the trade a test wants.
    private func waitForState(
        _ coordinator: CaptureCoordinator,
        timeout: TimeInterval = 30,
        _ predicate: @escaping (CaptureCoordinator.State) -> Bool,
        _ message: String = ""
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(coordinator.state) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("timed out waiting for state (last: \(coordinator.state)) \(message)")
    }

    // MARK: Rate parse (pure, isolated)

    @Test func parsePipeSampleRatePrimaryLine() {
        let line = "audiocap: OwnTone does NOT autodetect rate — set library { pipe_sample_rate = 44100 } in owntone.conf and restart, or playback is pitch-shifted (config-follows-tap)."
        #expect(CaptureCoordinator.parsePipeSampleRate(from: line) == 44100)
    }

    @Test func parsePipeSampleRateSecondaryLine() {
        let line = "audiocap: PIPE MODE — writing S16LE interleaved (2ch) at 48000 Hz to the FIFO."
        #expect(CaptureCoordinator.parsePipeSampleRate(from: line) == 48000)
    }

    @Test func parsePipeSampleRateIgnoresUnrelatedLines() {
        #expect(CaptureCoordinator.parsePipeSampleRate(from: "audiocap: tap created. Observed tap format:") == nil)
        #expect(CaptureCoordinator.parsePipeSampleRate(from: "audiocap: IOProc callbacks=42 inputBytesSeen=1000") == nil)
    }

    // MARK: Happy path — start → FIFO → spawn → rate → play sequence

    @Test func startCreatesFIFOSpawnsCaptureAndDrivesExplicitPlaySequence() async {
        let fifo = FakeFIFOManager()
        let process = FakeCaptureProcess()
        let playback = FakePlaybackController()
        let coordinator = makeCoordinator(fifo: fifo, process: process, playback: playback)

        coordinator.start()

        // Advances to waitingForRate once FIFO created + health-checked + spawned.
        await waitForState(coordinator) { $0 == .waitingForRate }
        #expect(fifo.created, "FIFO must be created")
        #expect(process.started, "capture subprocess must be spawned")
        #expect(process.lastFifoPath == fifo.fifoPath, "capture writes to the FIFO in the library dir")

        // audiocap prints its rate → matches config → explicit playback runs.
        process.emitStderr("audiocap: OwnTone does NOT autodetect rate — set library { pipe_sample_rate = 44100 } in owntone.conf and restart.")

        await waitForState(coordinator) { if case .running(let r) = $0 { return r == 44100 } else { return false } }

        // The explicit-play invariant: clear → add → play, in order, after find.
        let calls = playback.callList()
        let clearIdx = calls.firstIndex(of: "clear")
        let addIdx = calls.firstIndex(of: "add:library:track:2")
        let playIdx = calls.firstIndex(of: "play")
        #expect(clearIdx != nil); #expect(addIdx != nil); #expect(playIdx != nil)
        #expect(clearIdx! < addIdx! && addIdx! < playIdx!, "must be clear → add → play, got \(calls)")
        #expect(calls.contains("health"), "must health-check OwnTone first (Q7 connect-only)")
    }

    // MARK: Config-follows-tap — rate mismatch refuses

    @Test func rateMismatchRefusesAndTearsDownWithoutPlaying() async {
        let fifo = FakeFIFOManager()
        let process = FakeCaptureProcess()
        let playback = FakePlaybackController()
        // OwnTone configured for 44100; audiocap reports 48000.
        let coordinator = makeCoordinator(fifo: fifo, process: process, playback: playback, configuredRate: 44100)

        coordinator.start()
        await waitForState(coordinator) { $0 == .waitingForRate }

        process.emitStderr("audiocap: PIPE MODE — writing S16LE interleaved (2ch) at 48000 Hz to the FIFO.")

        await waitForState(coordinator) {
            if case .failed(.rateMismatch(let tap, let cfg)) = $0 { return tap == 48000 && cfg == 44100 }
            return false
        }
        // Never started playback — refusing, not silently pitch-shifting.
        #expect(!playback.callList().contains("play"), "must NOT play on a rate mismatch")
        // And it stopped the capture child.
        await waitForState(coordinator, timeout: 10) { _ in process.stopped } // stop() called on the child
        #expect(process.stopped, "capture must be stopped on a rate mismatch")
    }

    // MARK: Pipe not scanned yet → rescan + retry (brief §2)

    @Test func pipeTrackNotFoundTriggersRescanRetryThenSucceeds() async {
        let fifo = FakeFIFOManager()
        let process = FakeCaptureProcess()
        let playback = FakePlaybackController()
        playback.pipeNilCount = 2  // first two finds return nil → rescan → third finds it
        let coordinator = makeCoordinator(fifo: fifo, process: process, playback: playback)

        coordinator.start()
        await waitForState(coordinator) { $0 == .waitingForRate }
        process.emitStderr("pipe_sample_rate = 44100")

        await waitForState(coordinator) { if case .running = $0 { return true } else { return false } }
        let calls = playback.callList()
        #expect(calls.contains("update"), "a not-yet-scanned pipe must trigger updateLibrary()")
        #expect(calls.filter { $0 == "find" }.count >= 3, "must retry the search after rescan")
    }

    // MARK: OwnTone unreachable at start (Q7 connect-only)

    @Test func ownToneUnreachableAtStartFailsWithoutSpawningCapture() async {
        let fifo = FakeFIFOManager()
        let process = FakeCaptureProcess()
        let playback = FakePlaybackController()
        playback.healthCheckError = OwnToneClient.ClientError.unreachable
        let coordinator = makeCoordinator(fifo: fifo, process: process, playback: playback)

        coordinator.start()
        await waitForState(coordinator) { $0 == .failed(.ownToneUnreachable) }
        #expect(!process.started, "must not spawn capture if OwnTone is unreachable")
    }

    // MARK: Crash → auto-restart within budget

    @Test func captureCrashAutoRestartsWithinBudget() async {
        let fifo = FakeFIFOManager()
        let process = FakeCaptureProcess()
        let playback = FakePlaybackController()
        let coordinator = makeCoordinator(fifo: fifo, process: process, playback: playback, maxRestarts: 2)

        coordinator.start()
        await waitForState(coordinator) { $0 == .waitingForRate }

        // Simulate a crash (uncaught signal, not our SIGINT).
        process.emitTermination(.signal(signal: SIGSEGV))

        // The coordinator re-spawns → back to startingCapture/waitingForRate.
        await waitForState(coordinator) { $0 == .startingCapture || $0 == .waitingForRate }
    }

    // MARK: Crash over budget → surfaced (not looping)

    @Test func captureCrashOverBudgetSurfacesError() async {
        let fifo = FakeFIFOManager()
        let playback = FakePlaybackController()
        // The builder returns the same fake instance on each re-spawn, so we can
        // re-drive termination on it to exceed the restart budget.
        let process = FakeCaptureProcess()
        let coordinator = makeCoordinator(fifo: fifo, process: process, playback: playback, maxRestarts: 1)

        coordinator.start()
        await waitForState(coordinator) { $0 == .waitingForRate }
        process.emitTermination(.signal(signal: SIGSEGV))   // restart #1
        await waitForState(coordinator) { $0 == .startingCapture || $0 == .waitingForRate }
        process.emitTermination(.signal(signal: SIGSEGV))   // over budget → surface

        await waitForState(coordinator) {
            if case .failed(.captureCrashed) = $0 { return true } else { return false }
        }
    }

    // MARK: Nonzero exit (TCC/permission failure) → surfaced, not restarted

    @Test func captureNonzeroExitSurfacesAsError() async {
        let fifo = FakeFIFOManager()
        let process = FakeCaptureProcess()
        let playback = FakePlaybackController()
        let coordinator = makeCoordinator(fifo: fifo, process: process, playback: playback)

        coordinator.start()
        await waitForState(coordinator) { $0 == .waitingForRate }
        // audiocap exits nonzero (e.g. TCC not granted / aggregate failure).
        process.emitTermination(.exit(code: 1))

        await waitForState(coordinator) {
            if case .failed(.captureCrashed) = $0 { return true } else { return false }
        }
    }

    // MARK: stop() → teardown (SIGINT child + player/stop + FIFO cleanup)

    @Test func stopTearsDownChildPlayerAndFIFO() async {
        let fifo = FakeFIFOManager()
        let process = FakeCaptureProcess()
        let playback = FakePlaybackController()
        let coordinator = makeCoordinator(fifo: fifo, process: process, playback: playback)

        coordinator.start()
        await waitForState(coordinator) { $0 == .waitingForRate }
        process.emitStderr("pipe_sample_rate = 44100")
        await waitForState(coordinator) { if case .running = $0 { return true } else { return false } }

        coordinator.stop()
        await waitForState(coordinator) { $0 == .idle }
        #expect(process.stopped, "stop() must SIGINT the capture child")
        #expect(playback.callList().contains("stop"), "stop() must send player/stop (0f teardown)")
        #expect(fifo.cleaned, "stop() must clean up the FIFO")
    }

    // MARK: Idempotence

    @Test func startIsIdempotent() async {
        let fifo = FakeFIFOManager()
        let process = FakeCaptureProcess()
        let playback = FakePlaybackController()
        let coordinator = makeCoordinator(fifo: fifo, process: process, playback: playback)

        coordinator.start()
        coordinator.start()  // second call must no-op
        await waitForState(coordinator) { $0 == .waitingForRate }
        // Only one spawn / one health-check despite two start()s.
        #expect(playback.callList().filter { $0 == "health" }.count == 1, "start() must be idempotent")
    }

    @Test func stopFromIdleIsNoOp() {
        let fifo = FakeFIFOManager()
        let process = FakeCaptureProcess()
        let playback = FakePlaybackController()
        let coordinator = makeCoordinator(fifo: fifo, process: process, playback: playback)
        coordinator.stop()  // from idle
        #expect(coordinator.state == .idle)
        #expect(!process.stopped)
    }

    // MARK: replayPlayback — the replayHook body (zombie recovery play half)

    @Test func replayPlaybackReRunsExplicitSequenceWhenRunning() async {
        let fifo = FakeFIFOManager()
        let process = FakeCaptureProcess()
        let playback = FakePlaybackController()
        let coordinator = makeCoordinator(fifo: fifo, process: process, playback: playback)

        coordinator.start()
        await waitForState(coordinator) { $0 == .waitingForRate }
        process.emitStderr("pipe_sample_rate = 44100")
        await waitForState(coordinator) { if case .running = $0 { return true } else { return false } }

        // Clear the recorded calls' baseline count, then replay.
        let before = playback.callList().filter { $0 == "play" }.count
        await coordinator.replayPlayback()
        let after = playback.callList().filter { $0 == "play" }.count
        #expect(after == before + 1, "replayPlayback must re-run clear→add→play")
    }

    @Test func replayPlaybackIsNoOpWhenNotRunning() async {
        let fifo = FakeFIFOManager()
        let process = FakeCaptureProcess()
        let playback = FakePlaybackController()
        let coordinator = makeCoordinator(fifo: fifo, process: process, playback: playback)
        // Never started → not running.
        await coordinator.replayPlayback()
        #expect(playback.callList().isEmpty, "replay must no-op when not running")
    }

    // MARK: Feedback-loop guard — excludePIDs threaded to the subprocess

    @Test func excludePIDsPassedToCaptureProcess() async {
        let fifo = FakeFIFOManager()
        let process = FakeCaptureProcess()
        let playback = FakePlaybackController()
        let coordinator = makeCoordinator(fifo: fifo, process: process, playback: playback, excludePIDs: [4242])

        coordinator.start()
        await waitForState(coordinator) { $0 == .waitingForRate }
        #expect(process.lastExclude == [4242], "shairport pid must be excluded (feedback-loop guard)")
    }
}
