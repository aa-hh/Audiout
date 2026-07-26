// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Fully asynchronous, single-flighted launcher for the `tcc-probe` helper
/// executable (T14) — the fix for the finding documented on
/// ``SystemAudioCaptureTCC`` and exercised end-to-end by ``TCCBucketDiagnostic``:
/// a live-instrumented run proved `TCCAccessPreflight` is cached for the
/// lifetime of the CALLING process, so a long-running app can never see a
/// grant flip without relaunching — even though a real process tap in that
/// same stale process was already capturing audio successfully, proving macOS
/// itself had authorized it. `tcc-probe` (`Sources/tcc-probe/main.swift`) is a
/// brand-new, short-lived process that gets a brand-new cache and therefore a
/// live answer; this type is the seam that spawns it, parses its one line of
/// output, and turns every transient process/parse failure into an explicit
/// "could not resolve" outcome that a caller can never mistake for `.denied`
/// — collapsing an unknown into a denial is the exact bug
/// ``SystemAudioCaptureTCC`` already exists to fix, and this type must not
/// reintroduce it from the helper-process side.
///
/// ## Single-flight, no `Timer`
/// ``requestResolution(completion:)`` returns immediately and never blocks.
/// While a spawn is in flight, further calls do NOT spawn another helper —
/// they set a pending "re-kick" flag and queue their own completion, which
/// fires once, right after the in-flight spawn completes and (if re-kicked) a
/// second spawn resolves. A burst of calls therefore produces AT MOST two
/// spawns total, regardless of burst size — this replaces what would
/// otherwise be a coalescing `Timer`; there is deliberately no `Timer`
/// anywhere in this file.
///
/// ## Injectable spawn, for headless testing
/// The actual `Process` launch is injected (``SpawnHelper``) so
/// `TCCProbeRunnerTests` can drive single-flight, timeout, and parsing edge
/// cases with a fake that never touches `Foundation.Process` — the same
/// closure-seam idiom `CaptureProcess.swift` uses a protocol for, done as a
/// closure here because there is exactly one call shape to fake.
/// ``productionSpawn`` is the real implementation every non-test caller gets
/// by default.
public final class TCCProbeRunner {

    /// The interpreted outcome of one resolution attempt. Reuses
    /// ``SystemAudioCaptureTCC/Preflight`` for the three real TCC answers so a
    /// caller that already branches on that enum needs no new vocabulary for
    /// them — `.unresolved` is the one ADDITIONAL case this type exists to
    /// add, and it is never conflated with `.resolved(.denied)`.
    public enum Result: Equatable {
        case resolved(SystemAudioCaptureTCC.Preflight)
        case unresolved(UnresolvedReason)
    }

    /// Why a resolution attempt could not produce a trustworthy answer.
    public enum UnresolvedReason: Equatable {
        /// No `tcc-probe` at `Contents/MacOS/tcc-probe` next to the running
        /// bundle — e.g. `swift run`/`swift test` outside a packaged `.app`.
        /// Must read as "we don't know," never as a denial.
        case helperMissing
        /// The child didn't exit inside the hard timeout and was killed.
        case timedOut
        /// `Process.run()` itself threw (permissions, missing binary, …).
        case spawnFailed
        /// stdout didn't match the `audio=<int> screen=<int> control=<int>`
        /// contract at all.
        case malformedOutput
        /// The bogus-service CONTROL read back something other than `1` (see
        /// `tcc-probe/main.swift`'s doc comment) — the dlsym path itself is
        /// broken, so `audio`/`screen` on the same line are void, not data.
        case controlMismatch
    }

    /// The exact three integers `tcc-probe` printed, kept alongside the
    /// interpreted ``Result`` ONLY so a diagnostic (``TCCBucketDiagnostic``)
    /// can log the raw numbers macOS returned — the same "report integers,
    /// not this app's opinion of them" posture that file already documents
    /// for its own in-process reads. `nil` whenever the line couldn't even be
    /// parsed (`.helperMissing` / `.timedOut` / `.spawnFailed` /
    /// `.malformedOutput`); present (but not necessarily trustworthy — see
    /// `.controlMismatch`) whenever three integers were actually read.
    public struct RawReading: Equatable {
        public let audio: Int32
        public let screen: Int32
        public let control: Int32
    }

    /// What one spawn attempt hands back before interpretation. Public only
    /// because it appears in ``SpawnHelper``'s (public) signature — a normal
    /// caller never constructs or switches on this directly, it only ever
    /// sees ``Result`` + ``RawReading`` via ``requestResolution(completion:)``;
    /// this is the seam a test's fake spawn closure produces and
    /// ``interpret(_:)`` consumes.
    public enum SpawnOutcome: Equatable {
        case output(String)
        case helperMissing
        case timedOut
        case spawnFailed
    }

    /// Spawns the helper and reports its raw outcome asynchronously — always
    /// off the calling thread, called back exactly once. `timeout` is the
    /// hard wall-clock limit before the child is killed and reaped (see
    /// ``productionSpawn``).
    public typealias SpawnHelper = (_ timeout: TimeInterval, _ completion: @escaping (SpawnOutcome) -> Void) -> Void

    private let spawn: SpawnHelper
    private let hardTimeout: TimeInterval

    /// Guards every field below. A burst of calls from arbitrary threads
    /// (e.g. rapid UI toggles) must coalesce correctly with no lost or
    /// double-fired completions — see ``requestResolution(completion:)``.
    private let lock = NSLock()
    private var inFlight = false
    private var pendingRekick = false
    private var inFlightCompletions: [(Result, RawReading?) -> Void] = []
    private var queuedCompletions: [(Result, RawReading?) -> Void] = []

    /// - Parameters:
    ///   - hardTimeout: wall-clock limit before the child is killed and
    ///     reaped. 2s default — `tcc-probe` does one `dlopen`/`dlsym`/three
    ///     calls and exits; anything near that means it's genuinely stuck.
    ///   - spawn: injected for tests; production callers should accept the
    ///     default (``productionSpawn``).
    public init(hardTimeout: TimeInterval = 2.0, spawn: @escaping SpawnHelper = TCCProbeRunner.productionSpawn) {
        self.hardTimeout = hardTimeout
        self.spawn = spawn
    }

    /// Kicks off a resolution. Returns immediately — never spawns
    /// synchronously, never blocks the caller. See the type doc for the
    /// single-flight/coalescing contract. `completion` (if provided) is
    /// called exactly once, on an arbitrary thread, with the outcome of
    /// WHICHEVER spawn ends up answering this particular call (the already
    /// in-flight one, or the one coalesced re-kick after it) — never zero
    /// times, never twice.
    public func requestResolution(completion: ((Result, RawReading?) -> Void)? = nil) {
        lock.lock()
        if inFlight {
            if let completion { queuedCompletions.append(completion) }
            pendingRekick = true
            lock.unlock()
            return
        }
        inFlight = true
        if let completion { inFlightCompletions.append(completion) }
        lock.unlock()
        spawnOnce()
    }

    // MARK: - Single-flight core

    private func spawnOnce() {
        spawn(hardTimeout) { [weak self] outcome in
            guard let self else { return }
            let (result, raw) = Self.interpret(outcome)

            self.lock.lock()
            let completions = self.inFlightCompletions
            self.inFlightCompletions = []
            let shouldRekick = self.pendingRekick
            if shouldRekick {
                // A request arrived while this spawn was running — state may
                // have changed since, so answer it with a FRESH spawn rather
                // than this one's (possibly stale) result. This is the one
                // re-kick the type doc promises: at most one more spawn per
                // burst, no matter how many calls piled up meanwhile (they
                // all share this same re-kick).
                self.pendingRekick = false
                self.inFlightCompletions = self.queuedCompletions
                self.queuedCompletions = []
            } else {
                self.inFlight = false
            }
            self.lock.unlock()

            for completion in completions { completion(result, raw) }
            if shouldRekick {
                self.spawnOnce()
            }
        }
    }

    // MARK: - Interpretation (pure — unit-testable with zero process spawns)

    static func interpret(_ outcome: SpawnOutcome) -> (Result, RawReading?) {
        switch outcome {
        case .helperMissing:
            return (.unresolved(.helperMissing), nil)
        case .timedOut:
            return (.unresolved(.timedOut), nil)
        case .spawnFailed:
            return (.unresolved(.spawnFailed), nil)
        case .output(let text):
            guard let parsed = parseLine(text) else {
                return (.unresolved(.malformedOutput), nil)
            }
            let raw = RawReading(audio: parsed.audio, screen: parsed.screen, control: parsed.control)
            // The control MUST read back exactly 1 (a bogus service name,
            // verified empirically — see tcc-probe/main.swift) or the whole
            // read is void: the dlsym path itself is broken, so audio/screen
            // on the same line carry no information and must not be trusted
            // as `.resolved(...)`, however tempting a "2 == undetermined"
            // read might look.
            guard parsed.control == 1 else {
                return (.unresolved(.controlMismatch), raw)
            }
            return (.resolved(mapRawPreflight(parsed.audio)), raw)
        }
    }

    /// `TCCAccessPreflight`'s raw `Int32` → the three-valued enum — the same
    /// mapping as `SystemAudioCaptureTCC.preflight(service:)`'s switch
    /// (0 granted / 1 denied / anything else undetermined). Duplicated here
    /// (three lines) rather than shared, since sharing it would be the only
    /// reason for this file to depend on that one's dlopen/dlsym machinery at
    /// all, and it otherwise has none.
    private static func mapRawPreflight(_ value: Int32) -> SystemAudioCaptureTCC.Preflight {
        switch value {
        case 0: return .granted
        case 1: return .denied
        default: return .undetermined
        }
    }

    /// Parses the exact `"audio=<int> screen=<int> control=<int>"` contract
    /// `tcc-probe/main.swift` documents. Returns `nil` for anything else —
    /// extra/missing fields, wrong order, non-integer values — so a future
    /// accidental change to either side of the contract fails loudly as
    /// `.malformedOutput` instead of silently misreading a field.
    private static func parseLine(_ text: String) -> (audio: Int32, screen: Int32, control: Int32)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ")
        guard parts.count == 3 else { return nil }
        var values: [Int32] = []
        for (prefix, part) in zip(["audio=", "screen=", "control="], parts) {
            guard part.hasPrefix(prefix), let value = Int32(part.dropFirst(prefix.count)) else { return nil }
            values.append(value)
        }
        return (values[0], values[1], values[2])
    }

    // MARK: - Production spawn

    /// The real `Foundation.Process` launch: locates `tcc-probe` at
    /// `Contents/MacOS/tcc-probe` next to the running bundle, runs it with a
    /// hard timeout, and reaps the child on every path. `terminationHandler`
    /// only fires once Foundation has actually waited on the child, so both
    /// the normal-exit path and the timeout-kill path reap it — there is no
    /// path here that spawns a process without eventually being notified of
    /// (and thereby reaping) its exit, which is what would otherwise leak a
    /// zombie per resolution over a long session.
    public static func productionSpawn(timeout: TimeInterval, completion: @escaping (SpawnOutcome) -> Void) {
        guard let helperURL = locateHelper() else {
            completion(.helperMissing)
            return
        }

        let process = Process()
        process.executableURL = helperURL
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        // Guards the race between the timeout work item (global queue) and
        // `terminationHandler` (the process's own arbitrary queue) — same
        // "who gets there first, unambiguously" shape as
        // `AudiocapProcess.terminationFired` in `CaptureProcess.swift`.
        let state = SpawnState()
        let timeoutWorkItem = DispatchWorkItem {
            let alreadyDone = state.markTimedOutUnlessCompleted()
            if !alreadyDone {
                process.terminate()   // SIGTERM; terminationHandler still fires and reaps the child.
            }
        }

        process.terminationHandler = { _ in
            timeoutWorkItem.cancel()
            let wasTimedOut = state.markCompleted()
            if wasTimedOut {
                completion(.timedOut)
                return
            }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            completion(.output(String(decoding: data, as: UTF8.self)))
        }

        do {
            try process.run()
        } catch {
            timeoutWorkItem.cancel()
            completion(.spawnFailed)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
    }

    /// `Contents/MacOS/tcc-probe`, sibling of the running executable inside
    /// the app bundle `scripts/make-app.sh` assembles. `nil` outside a
    /// packaged `.app` (`swift run`/`swift test`), which every caller must
    /// treat as `.helperMissing` — an absent helper, not a denial.
    private static func locateHelper() -> URL? {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/tcc-probe")
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { return nil }
        return helperURL
    }

    private final class SpawnState: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var timedOut = false

        /// Called from the timeout work item. Returns whether termination had
        /// ALREADY happened by then — if so there's nothing left to kill, and
        /// the timeout fired too late to matter.
        func markTimedOutUnlessCompleted() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if completed { return true }
            timedOut = true
            return false
        }

        /// Called from `terminationHandler`. Returns whether the timeout had
        /// already fired — if so, the completion reports `.timedOut` rather
        /// than parsing whatever partial output a killed child left behind.
        func markCompleted() -> Bool {
            lock.lock(); defer { lock.unlock() }
            completed = true
            return timedOut
        }
    }
}
