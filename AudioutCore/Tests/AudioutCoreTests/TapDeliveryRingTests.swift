import Foundation
import Testing
@testable import AudioutCore

#if canImport(CoreAudio)
import CoreAudio

/// ``TapDeliveryRing`` on its own: the IO-block side is driven from the test
/// thread with hand-built buffer lists, the consumer is the ring's real thread,
/// and every wait is a handshake with that thread.
@Suite struct TapDeliveryRingTests {

    // MARK: Helpers

    /// Thread-safe record of what the consumer delivered.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [CapturedBuffer] = []
        func add(_ buffer: CapturedBuffer) { lock.lock(); items.append(buffer); lock.unlock() }
        var buffers: [CapturedBuffer] { lock.lock(); defer { lock.unlock() }; return items }
        var count: Int { buffers.count }
    }

    /// Holds the consumer inside its first delivery until ``open()``.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var entered = 0
        private var opened = false
        var enteredCount: Int { lock.lock(); defer { lock.unlock() }; return entered }
        func pass() {
            lock.lock()
            entered += 1
            let isOpen = opened
            lock.unlock()
            if !isOpen { release.wait() }
        }
        func open() {
            lock.lock()
            let wasOpen = opened
            opened = true
            lock.unlock()
            if !wasOpen { release.signal() }
        }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Push one planar cycle of `buffers` buffers, `frames` Float32 frames
    /// each, every sample `value`; pts seconds and sample time follow `index`.
    @discardableResult
    private func push(_ ring: TapDeliveryRing, index: Int, frames: Int = 4, buffers: Int = 2,
                      counters: TapIOCounters = TapIOCounters()) -> Bool {
        let list = AudioBufferList.allocate(maximumBuffers: buffers)
        defer {
            for buffer in list { buffer.mData?.deallocate() }
            free(list.unsafeMutablePointer)
        }
        for i in 0..<buffers {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            samples.initialize(repeating: Float(index), count: frames)
            list[i] = AudioBuffer(mNumberChannels: 1,
                                  mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                                  mData: samples)
        }
        return ring.push(list, nonInterleaved: true, frameCount: frames,
                         pts: timespec(tv_sec: index, tv_nsec: 0),
                         sampleTime: Double(index * 512), counters: counters)
    }

    private func firstSample(_ data: Data) -> Float {
        data.withUnsafeBytes { $0.load(as: Float.self) }
    }

    // MARK: Tests

    // Turns red if the consumer reads the wrong slot, stamps a new pts when it
    // pops, or loses a cycle's bytes, counts or IO block time on the way.
    @Test func cyclesArriveInCaptureOrderWithTheirOwnStamps() async {
        let ring = TapDeliveryRing(slotCount: 16, chunkCount: 2, slotBytes: 64)
        let collector = Collector()
        ring.start(threadName: "test.ring.order") { collector.add($0) }
        defer { ring.stop() }

        var accepted = 0
        for i in 0..<10 {
            var counters = TapIOCounters()
            counters.callbacks = i + 1
            if i == 3 { ring.noteIoBlock(nanos: 7_000) }
            if push(ring, index: i, counters: counters) { accepted += 1 }
        }
        #expect(accepted == 10)
        await SuiteWait.until("all ten cycles are delivered") { collector.count == 10 }

        let buffers = collector.buffers
        #expect(buffers.map(\.pts.tv_sec) == Array(0..<10))
        #expect(buffers.map(\.sampleTime) == (0..<10).map { Double?(Double($0 * 512)) })
        #expect(buffers.map(\.ioCounters.callbacks) == Array(1...10))
        #expect(buffers.allSatisfy { $0.frameCount == 4 && $0.channelData.count == 2 })
        #expect(buffers.map { firstSample($0.channelData[1]) } == (0..<10).map(Float.init))
        #expect(buffers[3].maxIoBlockNanos == 7_000)
        #expect(buffers[4].maxIoBlockNanos == 0, "an IO block's time rides on one entry only")
    }

    // Turns red if push waits for the consumer (a lock held across `deliver`,
    // say), which would put the slow path back inside Core Audio's IO cycle.
    @Test func aSlowConsumerDoesNotHoldUpThePush() async {
        let ring = TapDeliveryRing(slotCount: 8, chunkCount: 2, slotBytes: 64)
        let gate = Gate()
        let collector = Collector()
        ring.start(threadName: "test.ring.slow") { gate.pass(); collector.add($0) }
        defer { gate.open(); ring.stop() }

        push(ring, index: 0)
        await SuiteWait.until("the consumer is held inside its first delivery") { gate.enteredCount == 1 }
        var accepted = 0
        for i in 1...8 {
            if push(ring, index: i) { accepted += 1 }
        }
        #expect(accepted == 8, "eight free slots behind the held entry, all taken without waiting")
        #expect(collector.count == 0, "the consumer is still held, so every push returned while it was busy")

        gate.open()
        await SuiteWait.until("the backlog drains") { collector.count == 9 }
        #expect(collector.buffers.map(\.pts.tv_sec) == Array(0...8))
    }

    // Turns red if a push into a full ring blocks, traps or goes uncounted, or
    // if the count and the full depth stop riding on the next delivered entry.
    @Test func aFullRingDropsTheCycleAndCountsIt() async {
        let ring = TapDeliveryRing(slotCount: 2, chunkCount: 2, slotBytes: 64)
        let gate = Gate()
        let collector = Collector()
        ring.start(threadName: "test.ring.full") { gate.pass(); collector.add($0) }
        defer { gate.open(); ring.stop() }

        push(ring, index: 0)
        await SuiteWait.until("the consumer holds entry 0") { gate.enteredCount == 1 }
        let filled = push(ring, index: 1) && push(ring, index: 2)
        let dropped = !push(ring, index: 3)
        #expect(filled)
        #expect(dropped)
        #expect(ring.overflowCountForTesting == 1)

        gate.open()
        await SuiteWait.until("the three accepted cycles are delivered") { collector.count == 3 }
        push(ring, index: 4)
        await SuiteWait.until("the next cycle is delivered") { collector.count == 4 }
        let buffers = collector.buffers
        #expect(buffers.map(\.pts.tv_sec) == [0, 1, 2, 4], "the dropped cycle leaves a hole, nothing reordered")
        #expect(buffers[3].ioCounters.ringOverflows == 1)
        #expect(buffers[3].ringMaxDepth == 2, "a push that found the ring full saw it at capacity")
    }

    // Turns red if a cycle larger than a slot is copied anyway (writing past
    // the slot) or dropped without being counted.
    @Test func aCycleLargerThanASlotIsDroppedAndCounted() async {
        let ring = TapDeliveryRing(slotCount: 4, chunkCount: 2, slotBytes: 32)
        let collector = Collector()
        ring.start(threadName: "test.ring.oversize") { collector.add($0) }
        defer { ring.stop() }

        let tooManyBytes = !push(ring, index: 0, frames: 5)
        let tooManyBuffers = !push(ring, index: 1, frames: 1, buffers: 3)
        #expect(tooManyBytes)
        #expect(tooManyBuffers)
        #expect(ring.oversizeCountForTesting == 2)

        let fits = push(ring, index: 2, frames: 4)
        #expect(fits, "two buffers of 16 bytes fill a 32-byte slot exactly")
        await SuiteWait.until("the cycle that fits is delivered") { collector.count == 1 }
        #expect(collector.buffers.first?.ioCounters.ringOversize == 2)
        #expect(collector.buffers.first?.pts.tv_sec == 2)
    }

    // Turns red if `stop()` returns while the consumer can still deliver, or if
    // the cycles still waiting at stop reach `deliver` afterwards.
    @Test func stopWaitsForTheConsumerAndDiscardsWaitingCycles() async {
        let ring = TapDeliveryRing(slotCount: 8, chunkCount: 2, slotBytes: 64)
        let gate = Gate()
        let collector = Collector()
        ring.start(threadName: "test.ring.stop") { gate.pass(); collector.add($0) }
        defer { gate.open() }

        push(ring, index: 0)
        await SuiteWait.until("the consumer holds entry 0") { gate.enteredCount == 1 }
        for i in 1...3 { push(ring, index: i) }

        let stopReturned = Flag()
        Thread.detachNewThread {
            ring.stop()
            stopReturned.set()
        }
        await SuiteWait.until("stop has been asked for") { ring.stopRequestedForTesting }
        #expect(!stopReturned.isSet, "stop must wait while the consumer is still inside deliver")

        gate.open()
        await SuiteWait.until("stop returns once the consumer exits") { stopReturned.isSet }
        #expect(collector.count == 1, "only the cycle already being delivered gets through")
        let acceptedAfterStop = push(ring, index: 4)
        #expect(!acceptedAfterStop)
        #expect(collector.count == 1)
    }
}
#endif
