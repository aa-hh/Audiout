import Foundation
import os

#if canImport(CoreAudio)
import CoreAudio

/// Carries captured IO cycles from a tap's Core Audio IO block to a thread the
/// tap owns, so the conversion and fan-out after capture never run inside the
/// device's IO cycle.
///
/// Core Audio waits for the IO block before it can start the next cycle. When
/// the block ran the whole delivery path itself, a slow call (measured at 8 to
/// 20 ms under memory pressure, against an 11.6 ms cycle) made Core Audio skip
/// a cycle, which every speaker heard as a tick. Now the IO block calls
/// ``push(_:nonInterleaved:frameCount:pts:sampleTime:counters:)``, which copies
/// the cycle into memory allocated once at init, and returns. The consumer
/// thread started by ``start(threadName:deliver:)`` pops entries in capture
/// order, builds each ``CapturedBuffer`` and hands it on.
///
/// One producer (the IO block) and one consumer (the thread). The lock guards
/// only the waiting-entry count and the stop flag; each holder does a few
/// integer reads or writes under it. A slot's bytes are written by the producer
/// before the count covers it and read by the consumer before the count
/// releases it, so the bytes themselves are never touched by both at once.
///
/// A cycle that finds the ring full is dropped and counted in `ringOverflows`;
/// one larger than a slot is dropped and counted in `ringOversize`. Both counts
/// ride on the next entry's ``TapIOCounters``, so they reach the
/// `capture_health` line like the tap's other counts.
final class TapDeliveryRing: @unchecked Sendable {
    /// Entries the ring holds: 64 cycles is 743 ms at 512 frames and 44.1 kHz.
    static let defaultSlotCount = 64

    let slotCount: Int
    /// Most buffers one entry can hold (one per channel for a planar tap).
    let chunkCount: Int
    /// Bytes one entry can hold, across all its buffers.
    let slotBytes: Int

    private struct Entry {
        var usedChunks = 0
        var frameCount = 0
        var pts = timespec()
        var sampleTime: Double?
        var counters = TapIOCounters()
        var maxIoBlockNanos: Int64 = 0
        var maxDepth = 0
    }

    private let bytes: UnsafeMutableRawPointer
    private let chunkLengths: UnsafeMutablePointer<Int>
    private let entries: UnsafeMutablePointer<Entry>

    private let lock = OSAllocatedUnfairLock()
    /// Entries pushed and not yet popped. Under `lock`.
    private var waiting = 0
    /// Set once by ``stop()``. Under `lock`.
    private var stopped = false

    // Producer only.
    private var writeIndex = 0
    private var overflows = 0
    private var oversize = 0
    private var pendingMaxDepth = 0
    private var pendingMaxIoBlockNanos: Int64 = 0

    // Consumer only.
    private var readIndex = 0

    private let available = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)
    /// Set by ``start(threadName:deliver:)`` and read by ``stop()``, both on the
    /// tap's control side.
    private var thread: Thread?

    init(slotCount: Int = TapDeliveryRing.defaultSlotCount, chunkCount: Int, slotBytes: Int) {
        self.slotCount = max(1, slotCount)
        self.chunkCount = max(1, chunkCount)
        self.slotBytes = max(1, slotBytes)
        bytes = UnsafeMutableRawPointer.allocate(byteCount: self.slotCount * self.slotBytes, alignment: 16)
        chunkLengths = UnsafeMutablePointer<Int>.allocate(capacity: self.slotCount * self.chunkCount)
        chunkLengths.initialize(repeating: 0, count: self.slotCount * self.chunkCount)
        entries = UnsafeMutablePointer<Entry>.allocate(capacity: self.slotCount)
        entries.initialize(repeating: Entry(), count: self.slotCount)
    }

    deinit {
        bytes.deallocate()
        chunkLengths.deallocate()
        entries.deinitialize(count: slotCount)
        entries.deallocate()
    }

    // MARK: Producer (the IO block)

    /// Copy one IO cycle into the next free slot and wake the consumer. Copies
    /// every non-empty buffer in order for a planar list, and buffer 0 alone for
    /// an interleaved one: the same bytes the IO block used to put in
    /// `CapturedBuffer.channelData`. Never allocates, logs or waits on anything
    /// but `lock`. Returns false when the cycle was dropped.
    @discardableResult
    func push(_ list: UnsafeMutableAudioBufferListPointer, nonInterleaved: Bool, frameCount: Int,
              pts: timespec, sampleTime: Double?, counters: TapIOCounters) -> Bool {
        var used = 0
        var total = 0
        let last = nonInterleaved ? list.count : min(1, list.count)
        for i in 0..<last {
            let size = Int(list[i].mDataByteSize)
            guard list[i].mData != nil, size > 0 else { continue }
            used += 1
            total += size
        }
        guard used <= chunkCount, total <= slotBytes else {
            oversize &+= 1
            return false
        }

        lock.lock()
        let depthBefore = waiting
        let isStopped = stopped
        lock.unlock()
        guard !isStopped else { return false }
        guard depthBefore < slotCount else {
            overflows &+= 1
            pendingMaxDepth = slotCount
            return false
        }

        let slot = writeIndex
        var offset = 0
        var chunk = 0
        for i in 0..<last {
            let size = Int(list[i].mDataByteSize)
            guard let source = list[i].mData, size > 0 else { continue }
            (bytes + slot * slotBytes + offset).copyMemory(from: source, byteCount: size)
            chunkLengths[slot * chunkCount + chunk] = size
            offset += size
            chunk += 1
        }
        var stamped = counters
        stamped.ringOverflows = overflows
        stamped.ringOversize = oversize
        entries[slot] = Entry(
            usedChunks: used, frameCount: frameCount, pts: pts, sampleTime: sampleTime,
            counters: stamped, maxIoBlockNanos: pendingMaxIoBlockNanos,
            maxDepth: max(pendingMaxDepth, depthBefore + 1))
        pendingMaxIoBlockNanos = 0
        pendingMaxDepth = 0
        writeIndex = slot + 1 == slotCount ? 0 : slot + 1

        lock.lock()
        waiting += 1
        lock.unlock()
        available.signal()
        return true
    }

    /// Record how long one IO block ran. The longest since the last pushed
    /// entry rides on the next one, so an IO block's own duration reaches the
    /// consumer one entry later.
    func noteIoBlock(nanos: Int64) {
        if nanos > pendingMaxIoBlockNanos { pendingMaxIoBlockNanos = nanos }
    }

    // MARK: Consumer thread

    /// Start the consumer thread. `deliver` runs on it, once per entry, in the
    /// order entries were pushed.
    func start(threadName: String, deliver: @escaping (CapturedBuffer) -> Void) {
        let thread = Thread { [self] in
            runConsumer(deliver)
        }
        thread.name = threadName
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    private func runConsumer(_ deliver: (CapturedBuffer) -> Void) {
        while true {
            available.wait()
            // A plain `Thread` drains its autorelease pool only when it exits,
            // and each pass runs `AVAudioConverter` and builds `Data`, so each
            // pass gets its own pool. The closure returns true to stop.
            let shouldStop = autoreleasepool { () -> Bool in
                lock.lock()
                let isStopped = stopped
                let depth = waiting
                lock.unlock()
                if isStopped { return true }
                guard depth > 0 else { return false }

                let slot = readIndex
                let entry = entries[slot]
                var channelData: [Data] = []
                channelData.reserveCapacity(entry.usedChunks)
                var offset = 0
                for chunk in 0..<entry.usedChunks {
                    let size = chunkLengths[slot * chunkCount + chunk]
                    channelData.append(Data(bytes: bytes + slot * slotBytes + offset, count: size))
                    offset += size
                }
                readIndex = slot + 1 == slotCount ? 0 : slot + 1
                // The slot is copied out: hand it back before the slow part.
                lock.lock()
                waiting -= 1
                lock.unlock()

                var buffer = CapturedBuffer(channelData: channelData, frameCount: entry.frameCount, pts: entry.pts,
                                            sampleTime: entry.sampleTime, ioCounters: entry.counters)
                buffer.ringMaxDepth = entry.maxDepth
                buffer.maxIoBlockNanos = entry.maxIoBlockNanos
                deliver(buffer)
                return false
            }
            if shouldStop { break }
        }
        exited.signal()
    }

    /// Stop the consumer and wait for it to exit, so nothing is delivered once
    /// this returns. Entries still waiting are discarded. Call it after the IO
    /// block can no longer run. Idempotent. Called from the consumer thread
    /// itself it cannot wait for its own exit, so it only asks.
    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard !alreadyStopped, let thread else { return }
        available.signal()
        if Thread.current !== thread { exited.wait() }
    }

    // MARK: Test reads

    /// Producer-side counts; read them from the thread that pushes.
    var overflowCountForTesting: Int { overflows }
    var oversizeCountForTesting: Int { oversize }
    var stopRequestedForTesting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}
#endif
