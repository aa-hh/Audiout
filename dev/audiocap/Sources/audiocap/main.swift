import AudioToolbox
import AVFoundation
import Foundation

// ============================================================================
// audiocap — system-audio capture CLI (Core Audio process taps, macOS 14.4+)
//
// Default: global stereo tap of ALL system audio (excludes nothing).
// Writes raw interleaved Float32 PCM to a file (--out) and/or stdout (--stdout).
// See README.md for usage and the TCC caveats.
// ============================================================================

// MARK: - Argument parsing (dependency-free)

struct Options {
    var outPath: String?
    var toStdout = false
    var pipePath: String?      // --pipe => S16LE FIFO writer (T-0f-2)
    var duration: Double?      // seconds; nil => run until SIGINT
    var muteLocal = false      // --mute-local => .mutedWhenTapped
    var showHelp = false
    var selfTest = false       // --selftest => run conversion checks and exit
    // Tap targeting (T-0e-3).
    var pid: pid_t?            // --pid => single-process tap
    var bundleID: String?     // --bundle => resolve to a pid, then single-process tap
    var excludePIDs: [pid_t] = []  // --exclude => global tap minus these pids
}

func parseArgs(_ args: [String]) throws -> Options {
    var opts = Options()
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--out":
            i += 1
            guard i < args.count else { throw CAError("--out requires a file path") }
            opts.outPath = args[i]
        case "--stdout":
            opts.toStdout = true
        case "--pipe":
            i += 1
            guard i < args.count else { throw CAError("--pipe requires a FIFO path") }
            opts.pipePath = args[i]
        case "--duration":
            i += 1
            guard i < args.count, let d = Double(args[i]), d > 0 else {
                throw CAError("--duration requires a positive number of seconds")
            }
            opts.duration = d
        case "--mute-local":
            opts.muteLocal = true
        case "--pid":
            i += 1
            guard i < args.count, let p = Int32(args[i]), p > 0 else {
                throw CAError("--pid requires a positive process id")
            }
            opts.pid = pid_t(p)
        case "--bundle":
            i += 1
            guard i < args.count else { throw CAError("--bundle requires a bundle identifier") }
            opts.bundleID = args[i]
        case "--exclude":
            i += 1
            guard i < args.count else { throw CAError("--exclude requires pid[,pid...]") }
            let parts = args[i].split(separator: ",").map(String.init)
            for p in parts {
                guard let v = Int32(p), v > 0 else {
                    throw CAError("--exclude: '\(p)' is not a valid pid")
                }
                opts.excludePIDs.append(pid_t(v))
            }
        case "--selftest":
            opts.selfTest = true
        case "-h", "--help":
            opts.showHelp = true
        default:
            throw CAError("unknown argument: \(a)")
        }
        i += 1
    }
    return opts
}

let usage = """
audiocap — capture all system audio via Core Audio process taps (macOS 14.4+)

USAGE:
  audiocap [SINK...] [TARGET] [--duration <s>] [--mute-local]
  audiocap --selftest

SINKS (choose one or more; default = verify-only, bytes discarded):
  --out <file.pcm>    Write raw captured Float32 PCM to this file.
  --stdout            Write raw Float32 PCM to stdout (for piping). Diagnostics -> stderr.
  --pipe <fifo>       Convert to S16LE interleaved and write to a named FIFO
                      (OwnTone pipe input). Blocks on open() until OwnTone reads.

TARGET (choose at most one; default = whole system):
  --pid <n>           Tap ONLY this process id (single-app capture).
  --bundle <id>       Resolve a running app's bundle id (e.g. com.spotify.client)
                      to its pid, then tap only that app.
  --exclude <p[,p]>   Global tap of everything EXCEPT these pids (feedback-loop
                      guard). Global-tap only; not combinable with --pid/--bundle.

OTHER:
  --duration <sec>    Auto-stop after N seconds. Default: run until SIGINT (Ctrl-C).
  --mute-local        Silence local playback while tapping (.mutedWhenTapped).
                      Default is .unmuted (you still hear audio locally).
  --selftest          Run float32->S16LE conversion checks (no TCC, no audio) and exit.
  -h, --help          Show this help.

OUTPUT FORMAT:
  --out/--stdout: raw interleaved Float32 LE PCM at the tap's ACTUAL sample rate /
  channel count. --pipe: raw interleaved S16LE at the SAME rate (OwnTone does NOT
  sniff the rate; its pipe_sample_rate config MUST equal the tap rate — currently
  44100 — or playback is pitch-shifted). Never assume 48 kHz — it follows the default output
  device. Play back e.g.:
    ffplay -f f32le -ar <rate> -ch_layout stereo <file.pcm>

TCC:
  First run triggers the macOS system-audio-capture permission dialog. Approve it
  (or System Settings > Privacy & Security > Screen & System Audio Recording) and
  re-run. An unsigned CLI's grant may reset after a rebuild — re-grant if needed.
"""

// MARK: - Writer thread
//
// Drains the ring buffer to the output sink(s) off the realtime thread.
final class WriterThread {
    private let ring: RingBuffer
    private let fileHandle: FileHandle?
    private let toStdout: Bool
    private var thread: Thread?
    private var running = true
    private let chunkSize = 64 * 1024
    private(set) var bytesWritten: UInt64 = 0
    // Peak |sample| over all captured Float32 samples (silence detector). Written
    // only on the writer thread, read after join — no cross-thread hazard.
    private(set) var peakSample: Float = 0

    init(ring: RingBuffer, fileHandle: FileHandle?, toStdout: Bool) {
        self.ring = ring
        self.fileHandle = fileHandle
        self.toStdout = toStdout
    }

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "audiocap.writer"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    private func run() {
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buf.deallocate() }
        while running {
            let n = ring.read(into: buf, maxCount: chunkSize)
            if n == 0 {
                usleep(2000) // 2ms; nothing ready, yield
                continue
            }
            emit(buf, n)
        }
        // Final drain after stop signal.
        while true {
            let n = ring.read(into: buf, maxCount: chunkSize)
            if n == 0 { break }
            emit(buf, n)
        }
    }

    private func emit(_ ptr: UnsafeMutableRawPointer, _ n: Int) {
        // Track peak amplitude for a built-in silence check (Float32 samples).
        let sampleCount = n / MemoryLayout<Float>.size
        if sampleCount > 0 {
            let fp = ptr.assumingMemoryBound(to: Float.self)
            var local = peakSample
            for i in 0..<sampleCount {
                let a = abs(fp[i])
                if a > local { local = a }
            }
            peakSample = local
        }
        let data = Data(bytesNoCopy: ptr, count: n, deallocator: .none)
        if let fh = fileHandle {
            fh.write(data)
        }
        if toStdout {
            FileHandle.standardOutput.write(data)
        }
        bytesWritten &+= UInt64(n)
    }

    /// Signal stop and wait for the final drain to finish.
    func stopAndJoin() {
        running = false
        // Busy-wait for the thread to exit its drain loop.
        while let t = thread, !t.isFinished {
            usleep(2000)
        }
    }
}

// MARK: - Signal handling
//
// SIGINT/SIGTERM set a flag; the main thread polls it and tears down cleanly.
// (Handlers themselves must be async-signal-safe, so they only touch a sig_atomic.)
private var gStopFlag: sig_atomic_t = 0
func installSignalHandlers() {
    signal(SIGINT) { _ in gStopFlag = 1 }
    signal(SIGTERM) { _ in gStopFlag = 1 }
}

// MARK: - Main

func run() -> Int32 {
    let opts: Options
    do {
        opts = try parseArgs(Array(CommandLine.arguments.dropFirst()))
    } catch {
        elog("error: \(error)")
        elog("")
        elog(usage)
        return 2
    }

    if opts.showHelp {
        elog(usage)
        return 0
    }

    // ---- --selftest: no TCC, no audio; verify the conversion math and exit. ----
    if opts.selfTest {
        return runSelfTest()
    }

    // ---- Resolve the tap mode from the target flags (T-0e-3). ----
    // Mutually-exclusive target selection: --pid / --bundle (single-app) vs
    // --exclude (global minus pids). Default = whole system.
    let targetCount = (opts.pid != nil ? 1 : 0)
        + (opts.bundleID != nil ? 1 : 0)
        + (opts.excludePIDs.isEmpty ? 0 : 1)
    if targetCount > 1 {
        elog("error: choose at most one of --pid, --bundle, --exclude (they are mutually exclusive).")
        return 2
    }

    let tapMode: TapMode
    do {
        if let pid = opts.pid {
            let obj = try translatePIDToProcessObject(pid)
            elog("audiocap: per-app tap on pid \(pid) (process object \(obj)).")
            tapMode = .processes([obj])
        } else if let bundle = opts.bundleID {
            let pid = try pidForBundleID(bundle)
            let obj = try translatePIDToProcessObject(pid)
            elog("audiocap: per-app tap on bundle '\(bundle)' -> pid \(pid) (process object \(obj)).")
            tapMode = .processes([obj])
        } else if !opts.excludePIDs.isEmpty {
            let objs = try opts.excludePIDs.map { pid -> AudioObjectID in
                let o = try translatePIDToProcessObject(pid)
                elog("audiocap: excluding pid \(pid) (process object \(o)).")
                return o
            }
            tapMode = .globalExcluding(objs)
        } else {
            tapMode = .globalExcluding([])
        }
    } catch {
        elog("error resolving tap target: \(error)")
        return 1
    }

    // Keep the process responsive (avoid App Nap starving the audio thread; brief §7).
    let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled],
        reason: "system audio capture")
    defer { ProcessInfo.processInfo.endActivity(activity) }

    // Writing to a closed FIFO must not kill us with SIGPIPE — handle EPIPE in the
    // pipe writer instead (T-0f-2). Harmless for the other sinks.
    signal(SIGPIPE, SIG_IGN)

    // Prepare output file if requested.
    var fileHandle: FileHandle?
    if let outPath = opts.outPath {
        FileManager.default.createFile(atPath: outPath, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: outPath) else {
            elog("error: cannot open --out file for writing: \(outPath)")
            return 1
        }
        fileHandle = fh
    }
    let usePipe = opts.pipePath != nil
    if opts.outPath == nil && !opts.toStdout && !usePipe {
        elog("note: no --out/--stdout/--pipe given; capturing to verify only (bytes discarded).")
    }

    // Ring buffer sized for ~1s of audio at a generous 48kHz*2ch*4B ~= 384KB;
    // round up so brief slice bursts + writer latency never overflow.
    let ring = RingBuffer(minimumCapacityBytes: 2 * 1024 * 1024)

    let engine = TapEngine(name: "audiocap", ring: ring)
    let muteBehavior: CATapMuteBehavior = opts.muteLocal ? .mutedWhenTapped : .unmuted

    // ---- Create tap (this is where the TCC dialog fires on first run) ----
    do {
        try engine.createTapAndReadFormat(mode: tapMode, muteBehavior: muteBehavior)
    } catch {
        elog("error creating process tap: \(error)")
        return 1
    }

    // Print the ACTUAL observed ASBD to stderr (never assume 48k; requirement 1).
    elog("audiocap: tap created. Observed tap format:")
    elog(describeASBD(engine.asbd))
    let outASBD = engine.outputASBD
    elog("audiocap: output PCM (interleaved) — rate=\(outASBD.mSampleRate) "
         + "channels=\(outASBD.mChannelsPerFrame) bytes/frame=\(outASBD.mBytesPerFrame) "
         + "(Float32 LE interleaved)")

    if usePipe {
        let rate = Int(outASBD.mSampleRate.rounded())
        elog("audiocap: PIPE MODE — writing S16LE interleaved (\(Int(outASBD.mChannelsPerFrame))ch) "
             + "at \(rate) Hz to the FIFO.")
        elog("audiocap: OwnTone does NOT autodetect rate — set library { pipe_sample_rate = \(rate) } "
             + "in owntone.conf and restart, or playback is pitch-shifted (config-follows-tap).")
    }

    do {
        try engine.createAggregate()
        try engine.startCapture()
    } catch {
        elog("error starting capture: \(error)")
        engine.teardown()
        return 1
    }

    // Start draining. Pipe mode uses a dedicated S16LE-converting FIFO writer;
    // otherwise the raw Float32 file/stdout writer.
    var writer: WriterThread?
    var pipeWriter: PipeWriterThread?
    if let fifo = opts.pipePath {
        let pw = PipeWriterThread(ring: ring, fifoPath: fifo)
        pw.start()
        pipeWriter = pw
    } else {
        let w = WriterThread(ring: ring, fileHandle: fileHandle, toStdout: opts.toStdout)
        w.start()
        writer = w
    }

    installSignalHandlers()

    if let d = opts.duration {
        elog("audiocap: capturing for \(d)s (or until Ctrl-C)...")
    } else {
        elog("audiocap: capturing until Ctrl-C...")
    }

    // Poll loop: stop on signal or when duration elapses.
    let startTime = Date()
    while true {
        if gStopFlag != 0 {
            elog("audiocap: received stop signal, tearing down...")
            break
        }
        if let d = opts.duration, Date().timeIntervalSince(startTime) >= d {
            elog("audiocap: duration elapsed, tearing down...")
            break
        }
        usleep(50_000) // 50ms poll
    }

    // ---- Clean teardown, in order ----
    engine.teardown()        // Stop -> DestroyIOProcID -> DestroyAggregate -> DestroyTap
    writer?.stopAndJoin()    // final drain of the ring (file/stdout)
    pipeWriter?.stopAndJoin() // final drain + FIFO close (clean EOF for OwnTone)
    if let fh = fileHandle {
        try? fh.synchronize()
        try? fh.close()
    }

    // Unify the two writer paths' stats for reporting.
    let peak = writer?.peakSample ?? pipeWriter?.peakSample ?? 0
    let bytesOut = UInt64(writer?.bytesWritten ?? 0) + (pipeWriter?.s16BytesWritten ?? 0)

    let over = ring.overflowCount
    if over > 0 {
        elog("audiocap: WARNING dropped \(over) bytes to ring overflow "
             + "(writer/OwnTone too slow to drain).")
    }
    if let pw = pipeWriter {
        if pw.openFailed {
            elog("audiocap: WARNING FIFO never opened for writing — check the path and that "
                 + "OwnTone is configured to read it.")
        } else if !pw.opened {
            elog("audiocap: NOTE FIFO open did not complete (no reader attached during the run). "
                 + "Nothing was written; start OwnTone reading the pipe first.")
        }
        if pw.writeErrorCount > 0 {
            elog("audiocap: WARNING \(pw.writeErrorCount) FIFO write error(s) — OwnTone closed the pipe mid-stream.")
        }
    }
    elog("audiocap: IOProc callbacks=\(engine.callbackCount) inputBytesSeen=\(engine.inputBytesSeen) "
         + "ringWriteOK=\(engine.ringWriteOK) ringWriteFail=\(engine.ringWriteFail) nilData=\(engine.nilDataCount)")
    elog("audiocap: peak|sample| = \(peak)")
    if engine.callbackCount == 0 {
        elog("audiocap: WARNING the IOProc never fired — aggregate/device did not deliver audio.")
    } else if peak == 0 {
        elog("audiocap: WARNING captured audio is ALL SILENCE (peak 0). The IOProc delivered "
             + "\(engine.inputBytesSeen) bytes of correctly-sized buffers, but they are zeroed — "
             + "this is the signature of the system-audio-capture permission NOT being granted. "
             + "Approve the TCC dialog (System Settings > Privacy & Security > Screen & System "
             + "Audio Recording, enable this binary / its parent terminal), then re-run. Note: an "
             + "ad-hoc-signed CLI's grant can reset after a rebuild.")
    } else {
        elog("audiocap: OK captured NON-SILENT audio (peak \(peak)).")
    }
    elog("audiocap: wrote \(bytesOut) bytes\(pipeWriter != nil ? " (S16LE to FIFO)" : "" ). Done.")
    return 0
}

exit(run())
