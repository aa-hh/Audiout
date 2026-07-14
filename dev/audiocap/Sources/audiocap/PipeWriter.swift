import Foundation

// ============================================================================
// PipeWriterThread — drains the ring buffer (interleaved Float32 from the tap),
// converts to S16LE interleaved, and writes to a named FIFO with a BLOCKING
// writer (T-0f-2). Kept entirely off the realtime IOProc thread.
//
// FIFO semantics we must handle (from dev/notes/0f-pipe-brief.md):
//   * open(O_WRONLY) on a FIFO BLOCKS until a reader (OwnTone) opens the read end.
//     We open on this thread, so blocking here is fine — the main thread stays
//     responsive and can still tear us down on signal.
//   * If OwnTone is not draining, write() blocks (or the ring overflows upstream).
//     We use a bounded blocking write; upstream ring overflow already drops-oldest
//     via the RingBuffer producer and counts it.
//   * Clean EOF on stop: we close the fd so OwnTone sees end-of-stream.
// ============================================================================
final class PipeWriterThread {
    private let ring: RingBuffer
    private let fifoPath: String
    private var thread: Thread?
    private var running = true
    private var fd: Int32 = -1

    // Read chunk (Float32 bytes) pulled from the ring per iteration.
    private let readChunkBytes = 64 * 1024

    private(set) var s16BytesWritten: UInt64 = 0
    private(set) var openFailed = false
    private(set) var writeErrorCount: UInt64 = 0
    private(set) var peakSample: Float = 0

    /// Set true once the FIFO open() returns (a reader attached). Read from the
    /// main thread for progress logging; a plain Bool store/load is fine here.
    private(set) var opened = false

    init(ring: RingBuffer, fifoPath: String) {
        self.ring = ring
        self.fifoPath = fifoPath
    }

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "audiocap.pipewriter"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    private func run() {
        // Open the FIFO for writing. This BLOCKS until OwnTone opens the read end.
        // O_WRONLY (blocking) is intentional: OwnTone's pipe input must be reading.
        elog("audiocap: opening FIFO for writing (blocks until OwnTone reads): \(fifoPath)")
        fd = open(fifoPath, O_WRONLY)
        if fd < 0 {
            let e = String(cString: strerror(errno))
            elog("audiocap: ERROR could not open FIFO '\(fifoPath)' O_WRONLY: \(e)")
            openFailed = true
            return
        }
        opened = true
        elog("audiocap: FIFO open — OwnTone attached, streaming S16LE.")

        // Ignore SIGPIPE at the process level (installed in main); also guard writes.
        let inBuf = UnsafeMutableRawPointer.allocate(byteCount: readChunkBytes, alignment: 16)
        // Worst case: every Float32 (4 bytes) becomes 2 S16 bytes -> half the size.
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: readChunkBytes / 2)
        defer {
            inBuf.deallocate()
            outBuf.deallocate()
        }

        while running {
            let n = ring.read(into: inBuf, maxCount: readChunkBytes)
            if n == 0 {
                usleep(2000)
                continue
            }
            convertAndWrite(inBuf, n, outBuf)
        }
        // Final drain after stop signal so OwnTone gets all captured audio.
        while true {
            let n = ring.read(into: inBuf, maxCount: readChunkBytes)
            if n == 0 { break }
            convertAndWrite(inBuf, n, outBuf)
        }

        // Clean EOF: close the write end so OwnTone sees end-of-stream.
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    /// Convert `n` bytes of interleaved Float32 in `raw` to S16LE and write to fd.
    private func convertAndWrite(_ raw: UnsafeMutableRawPointer, _ n: Int,
                                 _ out: UnsafeMutablePointer<UInt8>) {
        let sampleCount = n / MemoryLayout<Float>.size
        if sampleCount == 0 { return }
        let fp = raw.assumingMemoryBound(to: Float.self)

        // Track peak for the diagnostic silence check.
        var local = peakSample
        for i in 0..<sampleCount {
            let a = abs(fp[i])
            if a > local { local = a }
        }
        peakSample = local

        convertFloat32ToS16LE(fp, count: sampleCount, into: out)
        let outBytes = sampleCount * 2
        writeAll(out, outBytes)
    }

    /// Blocking write of exactly `count` bytes, retrying short/interrupted writes.
    /// If OwnTone stalls, write() blocks here — which applies natural backpressure
    /// (the upstream ring will overflow-and-drop-oldest if the tap outruns us).
    private func writeAll(_ ptr: UnsafeMutablePointer<UInt8>, _ count: Int) {
        var offset = 0
        while offset < count {
            let w = write(fd, ptr + offset, count - offset)
            if w > 0 {
                offset += w
                s16BytesWritten &+= UInt64(w)
            } else if w < 0 {
                if errno == EINTR { continue }        // retry
                if errno == EAGAIN { usleep(1000); continue }
                // EPIPE (reader gone) or other fatal error: stop writing.
                writeErrorCount &+= 1
                let e = String(cString: strerror(errno))
                elog("audiocap: FIFO write error (\(e)) — OwnTone likely closed the pipe; stopping writer.")
                running = false
                return
            }
        }
    }

    /// Signal stop and wait for the final drain + FIFO close to finish.
    func stopAndJoin() {
        running = false
        while let t = thread, !t.isFinished {
            usleep(2000)
        }
    }
}
