// AirPlayEngine — the single owned engine thread + libevent base (T-API-1).
//
// Implements seam-map §8 / build-notes §6 item 1 (risk R-B): the whole vendored
// cluster assumes ONE event_base owned by ONE thread ("evbase_player"), and
// airplay_write() plus every device_* op must run on that thread with no
// cross-thread calls into the cluster. This type is that thread.
//
// It exposes exactly one way to touch the cluster: `run { ... }` marshals a
// closure onto the engine thread. Callers NEVER call a C entry point directly.

import Foundation
import CAirPlayEngine

/// A dedicated OS thread that owns a libevent `event_base` and runs
/// `event_base_dispatch` on it. All interaction with the vendored C cluster is
/// funneled through `run`, which schedules work onto this thread via
/// `event_base_once` (thread-safe to call from any thread) and wakes the loop.
final class EngineThread: @unchecked Sendable {

    /// The owned base. Set on `start()`, read by the wrapper to assign
    /// `evbase_player`. `OpaquePointer` bridges libevent's `struct event_base *`.
    private(set) var base: OpaquePointer?

    private let thread: Thread
    private let startSem = DispatchSemaphore(value: 0)
    private var stopped = false

    // A persistent "keep-alive" timer so event_base_dispatch never returns for
    // lack of pending events before we've scheduled anything. Without at least
    // one registered event, dispatch exits immediately.
    private var keepAlive: OpaquePointer?

    // libevent event-flag constants (see <event2/event.h>). Named here because
    // Darwin's <sys/event.h> defines colliding EV_* macros that Swift imports
    // ambiguously.
    private static let evTimeout: Int16 = 0x01
    private static let evPersist: Int16 = 0x10

    init(name: String = "com.airplayengine.engine") {
        // Use a Thread subclass so the run body can call back into `self`
        // without a capture-before-init of a stored `thread` property.
        let t = BodyThread()
        t.name = name
        // A generous stack — the RTSP/pairing state machine is deep.
        t.stackSize = 4 * 1024 * 1024
        self.thread = t
        t.body = { [weak self] in self?.threadMain() }
    }

    /// Start the thread and block until the base exists and the loop is running.
    /// Returns false if the base could not be created.
    @discardableResult
    func start() -> Bool {
        thread.start()
        startSem.wait()
        return base != nil
    }

    private func threadMain() {
        thread_setname("com.airplayengine.engine")

        guard let b = event_base_new() else {
            base = nil
            startSem.signal()
            return
        }
        base = b

        // Register a long-period persistent timer so the loop has a pending
        // event and event_base_dispatch blocks (rather than returning). It
        // fires rarely and does nothing; scheduled work arrives via run().
        // libevent flag constants (Darwin's <sys/event.h> shadows the libevent
        // EV_* macros in Swift, so use the numeric values libevent defines).
        let ka = event_new(b, -1, EngineThread.evPersist, { _, _, _ in }, nil)
        keepAlive = ka
        if let ka {
            var tv = timeval(tv_sec: 3600, tv_usec: 0)
            event_add(ka, &tv)
        }

        startSem.signal()

        // Runs until event_base_loopbreak() is called from stop().
        event_base_dispatch(b)

        if let ka = keepAlive {
            event_free(ka)
            keepAlive = nil
        }
        event_base_free(b)
        base = nil
    }

    /// Marshal `work` onto the engine thread. If already on the engine thread,
    /// runs inline. Otherwise schedules via `event_base_once` (safe from any
    /// thread) and returns immediately (fire-and-forget). Used by the hot write
    /// path and internal scheduling.
    func enqueue(_ work: @escaping () -> Void) {
        guard let base else { return }
        if isEngineThread {
            work()
            return
        }
        // Heap-box the closure; the C trampoline frees it after invoking once.
        let box = Unmanaged.passRetained(ClosureBox(work)).toOpaque()
        event_base_once(
            base,
            -1,
            EngineThread.evTimeout,
            { _, _, arg in
                guard let arg else { return }
                let box = Unmanaged<ClosureBox>.fromOpaque(arg).takeRetainedValue()
                box.body()
            },
            box,
            nil // fire immediately
        )
    }

    /// Marshal `work` onto the engine thread and await its result. The engine
    /// thread never blocks on itself (inline fast-path), so this is safe to call
    /// from any other thread/task.
    func run<T: Sendable>(_ work: @escaping () -> T) async -> T {
        if isEngineThread {
            return work()
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            enqueue {
                cont.resume(returning: work())
            }
        }
    }

    /// Whether the caller is currently executing on the engine thread. Used to
    /// avoid dead-locking `run` when the completion hook (which fires on the
    /// engine thread) needs to schedule more work.
    var isEngineThread: Bool { Thread.current === thread }

    /// Break the loop and join. Idempotent.
    func stop() {
        guard !stopped, let base else { return }
        stopped = true
        // loopbreak is thread-safe; it unblocks event_base_dispatch.
        event_base_loopbreak(base)
        // Give the loop a moment to unwind; the thread frees the base itself.
        while thread.isExecuting {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}

/// Heap box so a Swift closure can round-trip through a C void* trampoline.
private final class ClosureBox {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
}

/// A Thread whose run body is a closure assignable after construction (so the
/// owner can wire `self` into it without a stored-property capture-before-init).
private final class BodyThread: Thread {
    var body: (() -> Void)?
    override func main() { body?() }
}

/// A tiny lock-guarded bool the hot write path can read without hopping the
/// engine actor's executor. (Foundation-only; no stdlib atomics dependency.)
final class AtomicBool: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()
    init(_ initial: Bool) { value = initial }
    func load() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func store(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
}
