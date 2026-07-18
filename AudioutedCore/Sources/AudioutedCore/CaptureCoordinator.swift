import Foundation

/// Owns the capture → FIFO → OwnTone playback lifecycle for the REAL path
/// (RESOLVED Q2: capture runs as a SUBPROCESS — the app spawns the `audiocap`
/// helper binary). This is the component that makes ``OwnToneBackend``'s real
/// playback actually carry system audio: `OwnToneBackend` owns *device state*
/// (list / select / volume / zombie re-select); this coordinator owns *the audio
/// pipeline* (spawn capture, feed the FIFO, drive explicit playback) and supplies
/// the play half of zombie recovery via the backend's `replayHook`.
///
/// ## Lifecycle (the state machine — see ``State``)
///
/// ```
///  idle ──start()──▶ creatingFIFO ──▶ startingCapture ──▶ waitingForRate
///                                                              │
///                              (stderr "pipe_sample_rate = N") │
///                                                              ▼
///        rateMismatch ◀──(N ≠ pipe_sample_rate)── reconcileRate ──(match)──▶ startingPlayback
///                                                                                    │
///                                                        (clear→add→play OK)         ▼
///                                                                                running
///  running ──stop()──▶ stopping ──▶ idle
///  <any> ── child crash / OwnTone unreachable / play 500 ──▶ failed(error)
/// ```
///
/// ## The three hard-won 0f invariants this type upholds
/// 1. **Config-follows-tap** (0f-pipe-brief.md:27-38, 162-177): the FIFO/pipe
///    rate MUST equal the tap's real rate. audiocap prints its true rate on every
///    `--pipe` run (`pipe_sample_rate = N`); OwnTone's `pipe_sample_rate` is fixed
///    in `owntone.conf` and NOT sniffed — wrong-rate data plays pitch-shifted.
///    The coordinator parses N and **asserts** it matches the configured rate,
///    surfacing a `rateMismatch` action rather than silently pitch-shifting (per
///    Q7 the app can't restart OwnTone; it reports the reconcile the human must do).
/// 2. **Explicit-play** (0f-pipe-brief.md:69-75, brief §2): never rely on
///    autostart; drive `queue/clear → queue/items/add?uris=… → player/play`.
/// 3. **Suspend-to-pause on EOF + zombie de-select** (0f-pipe-brief.md:76-89):
///    capture ending leaves OwnTone in `pause`; teardown sends `player/stop`.
///    The `replayHook` re-runs the explicit sequence when the backend detects a
///    silently-dropped output.
///
/// ## Testability
/// Every external dependency is injected as a protocol: ``CaptureProcess`` (the
/// subprocess), ``PlaybackController`` (the OwnTone client), ``FIFOManaging``
/// (mkfifo). Unit tests drive the whole state machine hermetically — start →
/// FIFO-created → subprocess-spawned → play-sequence-invoked; crash → restart or
/// surface; stop → teardown; rate-mismatch → refuse/warn — **without spawning
/// audiocap or hitting a live OwnTone**.
public final class CaptureCoordinator: @unchecked Sendable {

    // MARK: State machine

    /// The coordinator's observable lifecycle state — a UI can render this
    /// directly (e.g. "starting capture…", "engine not reachable", "rate mismatch
    /// — restart OwnTone"). Every error path funnels into `.failed`.
    public enum State: Equatable, Sendable {
        /// Not running. `start()` moves out of here; `stop()` returns here.
        case idle
        /// Creating the named FIFO in OwnTone's library dir (`mkfifo`).
        case creatingFIFO
        /// FIFO exists; spawning `audiocap --pipe <fifo>`.
        case startingCapture
        /// Capture spawned; waiting for audiocap to print its `pipe_sample_rate`.
        case waitingForRate
        /// Rate parsed; FIFO has data; driving `clear→add→play`.
        case startingPlayback
        /// Steady state: capture is feeding the FIFO and OwnTone is playing it.
        case running(rate: Int)
        /// Tearing down (SIGINT child + `player/stop`).
        case stopping
        /// A terminal-until-restart error. Start/stop is idempotent; `stop()`
        /// from here still cleans up and returns to `.idle`.
        case failed(CaptureCoordinatorError)
    }

    // MARK: Injected dependencies

    private let fifo: FIFOManaging
    private let makeCaptureProcess: @Sendable () -> CaptureProcess
    private let playback: PlaybackController
    /// The rate OwnTone is configured for (`owntone.conf` `pipe_sample_rate`,
    /// currently 44100). The coordinator ASSERTS audiocap's printed rate equals
    /// this; a mismatch is surfaced, not silently corrected (config-follows-tap).
    private let configuredPipeSampleRate: Int
    /// PIDs to exclude from the tap (feedback-loop guard, PLAN-0e-0f.md:340-342):
    /// on the fake-receiver path the shairport process must be excluded or its
    /// re-played audio loops back into the capture. Injected because pid discovery
    /// is the caller's job (it knows which receiver process to exclude).
    private let excludePIDs: [Int32]
    /// How many times to retry finding the pipe track (rescan + search) before
    /// giving up (brief §2: the FIFO may not be scanned yet right after mkfifo).
    private let pipeSearchRetries: Int
    private let pipeSearchRetryDelay: TimeInterval

    // MARK: State (confined to `queue`)

    private let queue = DispatchQueue(label: "CaptureCoordinator.state")
    private var _state: State = .idle
    private var captureProcess: CaptureProcess?
    private var rateResolved = false
    /// Restart bookkeeping for crash recovery: how many auto-restarts we've done
    /// in the current run. Capped so a crash-looping binary surfaces rather than
    /// spins forever.
    private var restartCount = 0
    private let maxRestarts: Int

    /// Fired on every state transition so a UI (or a test) can observe the
    /// lifecycle. Called on the coordinator's internal queue.
    public var onStateChange: (@Sendable (State) -> Void)?

    /// The current state (thread-safe snapshot).
    public var state: State { queue.sync { _state } }

    // MARK: Init

    /// Production initializer: wires the real `audiocap` subprocess, the real
    /// OwnTone client, and a `mkfifo`-backed FIFO in OwnTone's library dir.
    ///
    /// - Parameters:
    ///   - audiocapBinaryPath: absolute path to the `audiocap` helper. Dev default
    ///     is `dev/audiocap/.build/release/audiocap`; in a shipped `.app` pass the
    ///     embedded binary's path. **Injectable/configurable** — nothing hardcodes
    ///     the dev layout except this default (RESOLVED Q2: embedded in the bundle).
    ///   - libraryDirectory: OwnTone's library dir (dev default `dev/owntone/media`),
    ///     where the FIFO is created so a rescan indexes it.
    ///   - configuredPipeSampleRate: OwnTone's `pipe_sample_rate` (default 44100,
    ///     matching `dev/owntone/etc/owntone.conf`). The rate audiocap reports must
    ///     equal this or the coordinator refuses (config-follows-tap).
    ///   - excludePIDs: PIDs to keep out of the tap (feedback-loop guard).
    ///   - host/port: OwnTone JSON API endpoint (default `localhost:3689`).
    public convenience init(
        audiocapBinaryPath: String = CaptureCoordinator.defaultAudiocapBinaryPath,
        libraryDirectory: String = CaptureCoordinator.defaultLibraryDirectory,
        configuredPipeSampleRate: Int = 44100,
        excludePIDs: [Int32] = [],
        host: String = "localhost",
        port: Int = 3689
    ) {
        self.init(
            fifo: FIFOManager(libraryDirectory: libraryDirectory),
            makeCaptureProcess: { AudiocapProcess(binaryPath: audiocapBinaryPath) },
            playback: OwnToneClient(host: host, port: port),
            configuredPipeSampleRate: configuredPipeSampleRate,
            excludePIDs: excludePIDs
        )
    }

    /// Injectable designated initializer (internal — tests pass fakes for all
    /// three seams so the state machine runs without a subprocess or live OwnTone).
    init(
        fifo: FIFOManaging,
        makeCaptureProcess: @escaping @Sendable () -> CaptureProcess,
        playback: PlaybackController,
        configuredPipeSampleRate: Int = 44100,
        excludePIDs: [Int32] = [],
        pipeSearchRetries: Int = 5,
        pipeSearchRetryDelay: TimeInterval = 0.5,
        maxRestarts: Int = 3
    ) {
        self.fifo = fifo
        self.makeCaptureProcess = makeCaptureProcess
        self.playback = playback
        self.configuredPipeSampleRate = configuredPipeSampleRate
        self.excludePIDs = excludePIDs
        self.pipeSearchRetries = pipeSearchRetries
        self.pipeSearchRetryDelay = pipeSearchRetryDelay
        self.maxRestarts = maxRestarts
    }

    /// Dev default for the `audiocap` binary — the release build in the repo.
    /// Overridden in a shipped `.app` by the embedded binary's path.
    public static var defaultAudiocapBinaryPath: String {
        // Resolve relative to the repo root by walking up from this file at build
        // time is not possible; use the known dev layout. The app passes an
        // explicit path in production, so this is a dev convenience only.
        "dev/audiocap/.build/release/audiocap"
    }

    /// Dev default for OwnTone's library dir (`owntone.conf`'s `directories`).
    public static var defaultLibraryDirectory: String {
        "dev/owntone/media"
    }

    // MARK: Public lifecycle (idempotent)

    /// Start the pipeline: create the FIFO → spawn capture → wait for the rate →
    /// reconcile it → drive explicit playback. Idempotent: calling `start()` while
    /// already starting/running is a no-op. Calling it from `.failed` resets and
    /// retries.
    public func start() {
        queue.sync {
            switch _state {
            case .idle, .failed:
                self.restartCount = 0
                self.beginStart()
            default:
                return // already in flight — idempotent
            }
        }
    }

    /// Stop the pipeline: SIGINT the capture child (clean FIFO EOF) + `player/stop`
    /// (explicit teardown so no paused pipe session wedges the next activation —
    /// 0f-pipe-brief.md:19-20). Idempotent: `stop()` from `.idle` is a no-op.
    public func stop() {
        let shouldTearDown: Bool = queue.sync {
            switch _state {
            case .idle:
                return false
            default:
                self.transition(to: .stopping)
                return true
            }
        }
        guard shouldTearDown else { return }
        tearDown()
    }

    /// The play half of zombie recovery (0f-pipe-brief.md:85-89, brief §4 step 4).
    /// The backend detected a silently-dropped output, re-selected it, and calls
    /// this to re-run the explicit `clear→add→play` sequence (a bare `player/play`
    /// won't unwedge a suspended session). Assign this to
    /// `OwnToneBackend.replayHook`.
    ///
    /// No-op unless we're actually `running` (nothing to replay otherwise).
    public func replayPlayback() async {
        let running = queue.sync { if case .running = _state { return true } else { return false } }
        guard running else { return }
        do {
            try await runExplicitPlaySequence()
        } catch {
            // A replay failure isn't fatal to the coordinator — the backend's
            // recovery logic already gives up after one retry and surfaces the
            // device error. Log via the failed state only if OwnTone went away.
            if isUnreachable(error) {
                queue.sync { self.transition(to: .failed(.ownToneUnreachable)) }
            }
        }
    }

    // MARK: Start sequence (each step runs on `queue`, hands async work to a Task)

    private func beginStart() {   // on queue
        transition(to: .creatingFIFO)
        Task { [weak self] in await self?.performStart() }
    }

    private func performStart() async {
        // 1. FIFO lifecycle: create the named FIFO in OwnTone's library dir.
        do {
            try fifo.create()
        } catch let error as CaptureCoordinatorError {
            fail(error); return
        } catch {
            fail(.fifoCreationFailed(path: fifo.fifoPath, reason: error.localizedDescription)); return
        }

        // 2. Health-check OwnTone up front (Q7 connect-only): if it's down, fail
        //    now rather than spawning capture into a void.
        do {
            try await playback.healthCheck()
        } catch {
            fail(.ownToneUnreachable); return
        }

        // 3. Spawn the capture subprocess in --pipe mode.
        queue.sync { self.transition(to: .startingCapture) }
        spawnCapture()
    }

    private func spawnCapture() {
        queue.sync {
            self.rateResolved = false
            let proc = self.makeCaptureProcess()
            self.captureProcess = proc
            self.transition(to: .waitingForRate)
            do {
                try proc.start(
                    fifoPath: self.fifo.fifoPath,
                    excludePIDs: self.excludePIDs,
                    onStderrLine: { [weak self] line in self?.handleStderrLine(line) },
                    onTermination: { [weak self] termination in self?.handleTermination(termination) }
                )
            } catch let error as CaptureCoordinatorError {
                self.captureProcess = nil
                self.transition(to: .failed(error))
            } catch {
                self.captureProcess = nil
                self.transition(to: .failed(.subprocessSpawnFailed(underlying: error.localizedDescription)))
            }
        }
    }

    // MARK: Rate reconciliation (config-follows-tap invariant)

    /// Parse audiocap's stderr for its printed rate. main.swift:328 emits:
    /// `audiocap: OwnTone does NOT autodetect rate — set library { pipe_sample_rate = 44100 } …`
    /// The rate also appears in `PIPE MODE — writing S16LE interleaved (2ch) at 44100 Hz …`
    /// (main.swift:326). We match either.
    private func handleStderrLine(_ line: String) {
        guard let rate = Self.parsePipeSampleRate(from: line) else { return }
        queue.sync {
            guard !self.rateResolved else { return }
            self.rateResolved = true
            if rate != self.configuredPipeSampleRate {
                // Config-follows-tap violated: the tap runs at a rate OwnTone
                // isn't configured for. Playing anyway would pitch-shift. We
                // cannot restart OwnTone (Q7), so surface the reconcile action
                // and tear the capture down rather than emit garbage.
                self.transition(to: .failed(.rateMismatch(
                    tapRate: rate, configuredRate: self.configuredPipeSampleRate)))
                Task { [weak self] in self?.captureProcess?.stop() }
                return
            }
            // Rates match → proceed to explicit playback.
            self.transition(to: .startingPlayback)
            Task { [weak self] in await self?.startPlayback(rate: rate) }
        }
    }

    /// Extract N from any line containing `pipe_sample_rate = N` or `at N Hz`.
    /// `static` + pure so it's unit-testable in isolation (the rate-parse test).
    static func parsePipeSampleRate(from line: String) -> Int? {
        // Primary: "pipe_sample_rate = 44100"
        if let range = line.range(of: "pipe_sample_rate") {
            let tail = line[range.upperBound...]
            if let n = firstInteger(in: tail) { return n }
        }
        // Secondary: "… at 44100 Hz to the FIFO."
        if let range = line.range(of: " at "), line.contains("Hz") {
            let tail = line[range.upperBound...]
            if let n = firstInteger(in: tail) { return n }
        }
        return nil
    }

    private static func firstInteger<S: StringProtocol>(in text: S) -> Int? {
        var digits = ""
        var started = false
        for ch in text {
            if ch.isNumber { digits.append(ch); started = true }
            else if started { break }
        }
        return digits.isEmpty ? nil : Int(digits)
    }

    // MARK: Explicit playback (0f explicit-play invariant)

    private func startPlayback(rate: Int) async {
        do {
            try await runExplicitPlaySequence()
        } catch let error as CaptureCoordinatorError {
            fail(error); return
        } catch {
            fail(mapUnexpected(error)); return
        }
        queue.sync {
            // Only settle into running if we haven't been torn down meanwhile.
            if case .startingPlayback = self._state {
                self.transition(to: .running(rate: rate))
            }
        }
    }

    /// The explicit `clear → add → play` recipe, with the pipe-track lookup and
    /// its rescan-retry (brief §2). Shared by initial start and `replayPlayback`.
    private func runExplicitPlaySequence() async throws {
        let uri = try await resolvePipeTrackURI()
        try await playback.clearQueue()
        try await playback.addToQueue(uri: uri)
        // player/play 500s on an empty queue — but we just added, so this is safe
        // (brief don't-assume #4). If it still 500s, surface it.
        try await playback.play()
    }

    /// Find the pipe track's `library:track:N` URI, rescanning + retrying if the
    /// freshly-mkfifo'd FIFO hasn't been indexed yet (brief §2:
    /// `expression=data_kind is pipe`, `updateLibrary()` then retry on total==0).
    private func resolvePipeTrackURI() async throws -> String {
        for attempt in 0..<max(1, pipeSearchRetries) {
            if let uri = try await playback.findPipeTrackURI() {
                return uri
            }
            // Not scanned yet → trigger a rescan and retry after a short delay.
            try? await playback.updateLibrary()
            if attempt < pipeSearchRetries - 1 {
                try? await Task.sleep(nanoseconds: UInt64(pipeSearchRetryDelay * 1_000_000_000))
            }
        }
        throw CaptureCoordinatorError.pipeTrackNotFound
    }

    // MARK: Subprocess termination / crash handling

    private func handleTermination(_ termination: CaptureTermination) {
        queue.sync {
            self.captureProcess = nil
            switch self._state {
            case .stopping, .idle:
                // We asked for this — teardown continues elsewhere.
                return
            case .failed:
                // Already failed (e.g. rate mismatch tore the child down); stay.
                return
            default:
                break
            }

            if termination.isCleanTeardown {
                // Clean EOF without us asking (shouldn't normally happen mid-run,
                // but if audiocap exits 0 on its own, treat as capture-ended).
                self.transition(to: .failed(.captureExited(termination)))
                return
            }

            // A crash/non-clean exit. Classify a capture-not-granted TCC exit vs.
            // a generic crash: audiocap exits nonzero (not signal) when TCC/aggregate
            // setup fails; we can't read its logs from here beyond exit code, so we
            // surface a coordinator error the UI can show and attempt a bounded
            // auto-restart for genuine crashes (signal), not for clean nonzero exits.
            if case .signal = termination, self.restartCount < self.maxRestarts {
                self.restartCount += 1
                self.transition(to: .startingCapture)
                Task { [weak self] in self?.spawnCapture() }
            } else {
                self.transition(to: .failed(.captureCrashed(termination, restarts: self.restartCount)))
            }
        }
    }

    // MARK: Teardown

    private func tearDown() {
        // SIGINT the child for a clean FIFO EOF, then stop the player.
        let proc = queue.sync { self.captureProcess }
        proc?.stop()
        Task { [weak self] in
            guard let self else { return }
            // Explicit player/stop so no paused pipe session lingers.
            try? await self.playback.stop()
            self.fifo.cleanup()
            self.queue.sync {
                self.captureProcess = nil
                self.transition(to: .idle)
            }
        }
    }

    // MARK: Failure plumbing

    private func fail(_ error: CaptureCoordinatorError) {
        // Tear the child down (if any) and surface the error.
        let proc = queue.sync { self.captureProcess }
        proc?.stop()
        queue.sync {
            self.captureProcess = nil
            self.transition(to: .failed(error))
        }
    }

    private func mapUnexpected(_ error: Error) -> CaptureCoordinatorError {
        if isUnreachable(error) { return .ownToneUnreachable }
        if let clientError = error as? OwnToneClient.ClientError {
            switch clientError {
            case .unreachable: return .ownToneUnreachable
            case .http(let status): return .playbackFailed(status: status)
            case .decoding: return .playbackFailed(status: -1)
            }
        }
        return .playbackFailed(status: -1)
    }

    private func isUnreachable(_ error: Error) -> Bool {
        if let c = error as? OwnToneClient.ClientError, c == .unreachable { return true }
        return false
    }

    // MARK: Transition helper (on queue)

    private func transition(to newState: State) {   // must hold `queue`
        guard newState != _state else { return }
        _state = newState
        onStateChange?(newState)
    }
}

// MARK: - Error model

/// Every way the capture pipeline can fail, shaped so a UI can render an
/// actionable message and the state machine can decide restart-vs-surface.
public enum CaptureCoordinatorError: Error, Equatable, Sendable {
    /// `mkfifo` failed (bad library dir, path collision with a non-FIFO, perms).
    case fifoCreationFailed(path: String, reason: String)
    /// Couldn't spawn the `audiocap` binary (missing/not-executable path).
    case subprocessSpawnFailed(underlying: String)
    /// audiocap reported a tap rate that doesn't match OwnTone's configured
    /// `pipe_sample_rate`. Playing would pitch-shift. **The reconcile action**:
    /// the human must set `pipe_sample_rate = tapRate` in `owntone.conf` and
    /// restart OwnTone (Q7 — the app cannot restart the server). This is the
    /// config-follows-tap guard firing.
    case rateMismatch(tapRate: Int, configuredRate: Int)
    /// The capture child exited cleanly on its own (EOF) without us asking —
    /// capture ended / the default output device went away.
    case captureExited(CaptureTermination)
    /// The capture child crashed (or exited nonzero — likely a TCC
    /// capture-not-granted failure or an aggregate-device error) and could not be
    /// recovered within the restart budget. `restarts` = auto-restarts attempted.
    case captureCrashed(CaptureTermination, restarts: Int)
    /// OwnTone was unreachable during start or playback (connection refused /
    /// timeout). Q7: surfaced, never supervised.
    case ownToneUnreachable
    /// The pipe track never showed up in the library even after a rescan + retries
    /// (the FIFO isn't in a scanned library dir, or the scan is broken).
    case pipeTrackNotFound
    /// OwnTone answered a playback call with a non-2xx (e.g. `player/play` 500 on
    /// an empty queue — shouldn't happen given the explicit sequence, but surfaced
    /// if it does). `status == -1` = a decode/unexpected error.
    case playbackFailed(status: Int)

    /// A human-readable, UI-renderable description of the failure and its remedy.
    public var userMessage: String {
        switch self {
        case .fifoCreationFailed(let path, let reason):
            return "Couldn't create the audio pipe at \(path): \(reason)"
        case .subprocessSpawnFailed(let underlying):
            return "Couldn't start audio capture: \(underlying)"
        case .rateMismatch(let tapRate, let configuredRate):
            return "Audio rate mismatch: your audio device runs at \(tapRate) Hz but the "
                + "engine is configured for \(configuredRate) Hz. Set pipe_sample_rate = "
                + "\(tapRate) in owntone.conf and restart the engine."
        case .captureExited:
            return "Audio capture stopped."
        case .captureCrashed(_, let restarts):
            return "Audio capture crashed"
                + (restarts > 0 ? " (after \(restarts) restart attempt\(restarts == 1 ? "" : "s"))" : "")
                + ". Check that screen & system-audio recording permission is granted."
        case .ownToneUnreachable:
            return "The audio engine isn't reachable. Make sure it's running."
        case .pipeTrackNotFound:
            return "The audio pipe isn't registered with the engine. Check the library directory."
        case .playbackFailed(let status):
            return "The engine refused to start playback (status \(status))."
        }
    }
}
