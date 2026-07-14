import Foundation

// Single-producer / single-consumer lock-free byte ring buffer.
//
// Producer = the realtime IOProc thread (audio HAL). It calls `write` only, and
// must never allocate, lock, or log. Consumer = a dedicated writer thread that
// drains bytes to the output sink (file / stdout).
//
// Dependency-free design: head/tail are word-sized indices in heap storage. On
// arm64 (and every Apple platform) aligned word loads/stores are atomic; we pair
// them with OSMemoryBarrier() to get the acquire/release ordering an SPSC ring
// needs (producer publishes data before advancing head; consumer reads head
// before touching data). This avoids pulling in swift-atomics over the network.
//
// Capacity is rounded up to a power of two so wraparound is a mask. One slot is
// left unused to distinguish full from empty. On overflow the producer drops the
// incoming chunk and bumps an overflow counter, so the audio thread never blocks.
final class RingBuffer {
    private let storage: UnsafeMutableRawPointer
    private let capacity: Int
    private let mask: Int

    // Each index lives in its own heap word so producer and consumer never share
    // a cache line for the counters they each own.
    private let headPtr: UnsafeMutablePointer<Int>   // next write index; producer owns
    private let tailPtr: UnsafeMutablePointer<Int>   // next read index; consumer owns
    private let overflowPtr: UnsafeMutablePointer<UInt64>

    init(minimumCapacityBytes: Int) {
        var cap = 1
        while cap < minimumCapacityBytes { cap <<= 1 }
        self.capacity = cap
        self.mask = cap - 1
        self.storage = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
        self.headPtr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        self.tailPtr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        self.overflowPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        headPtr.initialize(to: 0)
        tailPtr.initialize(to: 0)
        overflowPtr.initialize(to: 0)
    }

    deinit {
        storage.deallocate()
        headPtr.deallocate()
        tailPtr.deallocate()
        overflowPtr.deallocate()
    }

    var overflowCount: UInt64 {
        OSMemoryBarrier()
        return overflowPtr.pointee
    }

    /// Producer side. Realtime-safe: no allocation, no locks, no logging.
    /// Returns true if the whole chunk was written, false if dropped (overflow).
    func write(_ src: UnsafeRawPointer, _ count: Int) -> Bool {
        let h = headPtr.pointee
        let t = tailPtr.pointee           // consumer-owned; load is atomic on aligned word
        OSMemoryBarrier()                 // acquire: see consumer's tail before computing free
        let used = (h &- t) & mask
        let free = capacity - 1 - used
        if count > free {
            overflowPtr.pointee &+= UInt64(count)
            return false
        }
        let first = min(count, capacity - (h & mask))
        memcpy(storage.advanced(by: h & mask), src, first)
        if count > first {
            memcpy(storage, src.advanced(by: first), count - first)
        }
        OSMemoryBarrier()                 // release: publish data before advancing head
        headPtr.pointee = (h &+ count) & mask
        return true
    }

    /// Consumer side. Copies up to `maxCount` available bytes into `dst`.
    /// Returns the number of bytes copied.
    func read(into dst: UnsafeMutableRawPointer, maxCount: Int) -> Int {
        let t = tailPtr.pointee
        let h = headPtr.pointee            // producer-owned; load is atomic on aligned word
        OSMemoryBarrier()                  // acquire: see producer's data before reading it
        let available = (h &- t) & mask
        if available == 0 { return 0 }
        let count = min(available, maxCount)
        let first = min(count, capacity - (t & mask))
        memcpy(dst, storage.advanced(by: t & mask), first)
        if count > first {
            memcpy(dst.advanced(by: first), storage, count - first)
        }
        OSMemoryBarrier()                  // release: finish reading before advancing tail
        tailPtr.pointee = (t &+ count) & mask
        return count
    }
}
