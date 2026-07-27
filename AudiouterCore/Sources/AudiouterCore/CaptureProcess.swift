import Foundation

/// The injectable seam for the `audiocap` subprocess (RESOLVED Q2: capture runs
/// as a SUBPROCESS — the app spawns the `audiocap`-derived helper binary and
/// manages its lifecycle). `CaptureCoordinator` drives capture through this
/// protocol so its state machine can be unit-tested hermetically: tests supply a
/// fake that emits scripted stderr lines and simulates crash/exit **without ever
/// spawning the real binary** (which would need TCC + macOS 14.4).
///
/// The real implementation is ``AudiocapProcess`` (wraps `Foundation.Process`).
///
/// Contract (grounded in `dev/audiocap/Sources/audiocap/main.swift` +
/// `dev/notes/0f-pipe-brief.md`):
/// - `start` spawns `audiocap --pipe <fifo>` (plus any `--exclude <pids>`), wires
///   the child's **stderr** to `onStderrLine` line-by-line (audiocap logs the
///   ASBD + the `pipe_sample_rate = N` line there — main.swift:320-329), and
///   calls `onTermination` exactly once when the child exits (cleanly or by
///   crash/signal), carrying the exit status so the coordinator can classify a
///   crash vs. a clean SIGINT teardown.
/// - `stop` sends SIGINT so the FIFO gets a clean EOF (main.swift installs a
///   SIGINT handler that tears down and closes the FIFO — 0f-pipe-brief.md:18).
protocol CaptureProcess: AnyObject {
    /// Spawn the helper. `onStderrLine` is called for each newline-delimited
    /// stderr line as it arrives; `onTermination` is called once when the child
    /// exits. Both may be invoked on arbitrary threads — the coordinator
    /// serialises onto its own queue.
    func start(
        fifoPath: String,
        excludePIDs: [Int32],
        onStderrLine: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (CaptureTermination) -> Void
    ) throws

    /// Ask the child to stop. Real impl sends SIGINT (clean FIFO EOF); the
    /// termination handler still fires afterwards. Idempotent.
    func stop()

    /// Whether a child is currently running (best-effort snapshot).
    var isRunning: Bool { get }
}

/// How an ``CaptureProcess`` child ended — enough for the coordinator to tell a
/// clean SIGINT teardown from a crash/permission failure.
public enum CaptureTermination: Equatable, Sendable {
    /// Normal exit. `code == 0` after a SIGINT teardown is expected; a nonzero
    /// code means audiocap bailed (bad FIFO path, capture-not-granted TCC exit,
    /// aggregate-device failure — see main.swift's nonzero returns).
    case exit(code: Int32)
    /// Killed by a signal. `SIGINT`/`SIGTERM` is our own teardown; anything else
    /// (SIGSEGV, SIGKILL, …) is a crash the coordinator surfaces for restart.
    case signal(signal: Int32)

    /// A clean stop we initiated: exit 0, or terminated by SIGINT/SIGTERM.
    public var isCleanTeardown: Bool {
        switch self {
        case .exit(let code): return code == 0
        case .signal(let signal): return signal == SIGINT || signal == SIGTERM
        }
    }
}

// MARK: - Real subprocess implementation

/// `CaptureProcess` backed by `Foundation.Process`, spawning the real `audiocap`
/// helper in `--pipe` mode. Never instantiated in unit tests (they use a fake) —
/// exercised only by the human/integration verification (T-V1).
final class AudiocapProcess: CaptureProcess, @unchecked Sendable {

    /// Absolute path to the `audiocap` binary. **Injectable/configurable** with a
    /// dev default (`dev/audiocap/.build/release/audiocap`); in a shipped `.app`
    /// the coordinator is handed the embedded binary's path instead
    /// (`…/Contents/MacOS/audiocap` or `…/Contents/Helpers/…`), so nothing here
    /// hardcodes the dev layout beyond the default.
    private let binaryPath: String

    private let lock = NSLock()
    private var process: Process?
    private var stderrPipe: Pipe?
    private var terminationFired = false

    init(binaryPath: String) {
        self.binaryPath = binaryPath
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    func start(
        fifoPath: String,
        excludePIDs: [Int32],
        onStderrLine: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (CaptureTermination) -> Void
    ) throws {
        lock.lock()
        guard process == nil else { lock.unlock(); return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        var args = ["--pipe", fifoPath]
        if !excludePIDs.isEmpty {
            args += ["--exclude", excludePIDs.map(String.init).joined(separator: ",")]
        }
        proc.arguments = args

        let errPipe = Pipe()
        proc.standardError = errPipe
        // audiocap writes only diagnostics to stdout too; discard it (the audio
        // goes to the FIFO, not stdout, in --pipe mode).
        proc.standardOutput = FileHandle.nullDevice

        self.process = proc
        self.stderrPipe = errPipe
        self.terminationFired = false
        lock.unlock()

        // Stream stderr line-by-line as it arrives.
        let buffer = LineBuffer()
        // STABILITY(D6): narrow verified races — see dev/notes/stability-audit-2026-07-18.md
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in buffer.append(data) { onStderrLine(line) }
        }

        proc.terminationHandler = { [weak self] p in
            errPipe.fileHandleForReading.readabilityHandler = nil
            // Flush any trailing partial line.
            for line in buffer.flush() { onStderrLine(line) }
            let termination: CaptureTermination = p.terminationReason == .uncaughtSignal
                ? .signal(signal: p.terminationStatus)
                : .exit(code: p.terminationStatus)
            self?.fireTermination(onTermination, termination)
        }

        do {
            try proc.run()
        } catch {
            lock.lock(); process = nil; stderrPipe = nil; lock.unlock()
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw CaptureCoordinatorError.subprocessSpawnFailed(underlying: error.localizedDescription)
        }
    }

    func stop() {
        lock.lock()
        let proc = process
        lock.unlock()
        guard let proc, proc.isRunning else { return }
        // SIGINT → audiocap's handler tears down and closes the FIFO (clean EOF),
        // 0f-pipe-brief.md:18. The terminationHandler still fires afterwards.
        proc.interrupt()
    }

    private func fireTermination(
        _ handler: @escaping @Sendable (CaptureTermination) -> Void,
        _ termination: CaptureTermination
    ) {
        lock.lock()
        guard !terminationFired else { lock.unlock(); return }
        terminationFired = true
        process = nil
        stderrPipe = nil
        lock.unlock()
        handler(termination)
    }
}

/// Accumulates stream bytes and yields complete newline-delimited lines.
/// Thread-confined to the single `readabilityHandler` callback chain.
final class LineBuffer: @unchecked Sendable {
    private var partial = Data()

    func append(_ data: Data) -> [String] {
        partial.append(data)
        return drainLines()
    }

    func flush() -> [String] {
        guard !partial.isEmpty else { return [] }
        let line = String(decoding: partial, as: UTF8.self)
        partial.removeAll()
        return line.isEmpty ? [] : [line]
    }

    private func drainLines() -> [String] {
        var lines: [String] = []
        let newline = UInt8(ascii: "\n")
        while let idx = partial.firstIndex(of: newline) {
            let lineData = partial[partial.startIndex..<idx]
            lines.append(String(decoding: lineData, as: UTF8.self))
            partial.removeSubrange(partial.startIndex...idx)
        }
        return lines
    }
}
