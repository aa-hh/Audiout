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
import os

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

    private let log = Logger(subsystem: "com.airplayengine", category: "engine-thread")

    // B4: tracked-enqueue registry. A closure scheduled via `event_base_once`
    // that never fires (the loop broke before its immediate timeout) would leak
    // its ClosureBox AND, worse, never resume any continuation it carries — the
    // caller freezes forever. We therefore keep a side table of every *tracked*
    // pending closure, remove-on-run, and SWEEP the leftovers in `stop()` so
    // each still resumes/fails (see `sweepPending`). The hot write path opts out
    // (`tracked: false`): those bodies carry no continuation, so dropping a late
    // audio frame on teardown is correct and we avoid a dict op per write.
    private var pending: [UInt64: () -> Void] = [:]
    private var pendingSeq: UInt64 = 0
    private let pendingLock = NSLock()

    /// How long `stop()` will wait for the engine thread to unwind before it
    /// gives up and deliberately leaks the thread/base rather than hang (C3).
    private static let stopJoinDeadline: TimeInterval = 3.0

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

    /// libevent threading support, enabled once process-wide BEFORE any
    /// event_base exists. REQUIRED: `event_base_once()` from another thread
    /// only wakes a loop blocked in kevent() when the base was created with
    /// evthread support — otherwise the scheduled work sits until the next
    /// timer fires (up to the 1h keep-alive). The engine's first real
    /// `start()` deadlocked exactly this way (gated first-light, 2026-07-16);
    /// headless tests never hit it because they bypass the real init path.
    private static let evthreadEnabled: Bool = evthread_use_pthreads() == 0

    private func threadMain() {
        thread_setname("com.airplayengine.engine")

        guard EngineThread.evthreadEnabled, let b = event_base_new() else {
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
    /// thread) and returns immediately (fire-and-forget).
    ///
    /// Returns `false` when the work could NOT be scheduled — the base doesn't
    /// exist yet (pre-`start()`) or was torn down (post-`stop()`). A caller that
    /// carries a continuation MUST resume/fail it itself when this returns false,
    /// otherwise it freezes forever (B4). Previously this silently `return`ed on a
    /// nil base and the caller's `withCheckedContinuation` never resumed.
    ///
    /// `tracked` (default true): register the closure in `pending` so a leftover
    /// (scheduled but not fired before the loop broke) is swept + run in `stop()`,
    /// guaranteeing any continuation it carries resolves. The hot write path
    /// passes `tracked: false` — its bodies carry no continuation, dropping a late
    /// frame on teardown is correct, and it avoids a per-write dict op.
    @discardableResult
    func enqueue(_ work: @escaping () -> Void, tracked: Bool = true) -> Bool {
        guard let base else { return false }
        if isEngineThread {
            work()
            return true
        }

        let token: UInt64?
        if tracked {
            pendingLock.lock()
            pendingSeq &+= 1
            let t = pendingSeq
            pending[t] = work
            pendingLock.unlock()
            token = t
        } else {
            token = nil
        }

        // Heap-box a trampoline that runs the tracked closure by token (removing
        // it from `pending` first, so `stop()`'s sweep and the fire can't both
        // run it) or the untracked closure directly.
        let payload = ClosureBox { [weak self] in
            if let token, let self {
                self.runPending(token: token)
            } else {
                work()
            }
        }
        let box = Unmanaged.passRetained(payload).toOpaque()
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
        return true
    }

    /// Run (and remove) one tracked pending closure by token. Removal-under-lock
    /// is the single arbiter of who runs a tracked body: whichever of {the fired
    /// once-event, `stop()`'s sweep} takes it out of `pending` first runs it; the
    /// other finds nothing.
    private func runPending(token: UInt64) {
        pendingLock.lock()
        let work = pending.removeValue(forKey: token)
        pendingLock.unlock()
        work?()
    }

    /// Run every still-pending tracked closure (leftovers whose once-event never
    /// fired because the loop broke). Each is expected to resume/fail whatever
    /// continuation it carries; by the time `stop()` calls this the C teardown
    /// (airplay_deinit + `outputs_registry_clear`) has already run on the engine
    /// thread, so a leftover `startOp` body sees an empty registry and resolves by
    /// throwing rather than touching a torn-down cluster.
    private func sweepPending() {
        pendingLock.lock()
        let leftovers = pending
        pending.removeAll()
        pendingLock.unlock()
        for (_, work) in leftovers {
            work()
        }
    }

    /// Marshal `work` onto the engine thread and await its result. The engine
    /// thread never blocks on itself (inline fast-path), so this is safe to call
    /// from any other thread/task. Throws ``AirPlayEngineError/engineNotRunning``
    /// (fail-fast, B4) if the work can't be scheduled because the base is gone —
    /// never hangs waiting for a completion that can never arrive.
    func run<T: Sendable>(_ work: @escaping () -> T) async throws -> T {
        if isEngineThread {
            return work()
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let scheduled = enqueue {
                cont.resume(returning: work())
            }
            if !scheduled {
                cont.resume(throwing: AirPlayEngineError.engineNotRunning)
            }
        }
    }

    /// Whether the caller is currently executing on the engine thread. Used to
    /// avoid dead-locking `run` when the completion hook (which fires on the
    /// engine thread) needs to schedule more work.
    var isEngineThread: Bool { Thread.current === thread }

    /// Break the loop and join, then sweep any leftover pending work so no
    /// continuation is stranded (B4). Idempotent.
    ///
    /// C3: the join is DEADLINED (`stopJoinDeadline`). A vendored callback wedged
    /// in a blocking syscall never returns, so an unbounded spin-wait here would
    /// hang `stop()` forever — and with it the engine actor, since `stop()` runs
    /// under actor isolation. On expiry we log loudly (stderr + os_log) and
    /// DELIBERATELY LEAK the thread + event_base rather than hang: a leaked thread
    /// is a bounded one-time cost; a hung actor wedges every later engine call.
    func stop() {
        guard !stopped, let base else { return }
        stopped = true
        // loopbreak is thread-safe; it unblocks event_base_dispatch.
        event_base_loopbreak(base)
        // Give the loop a moment to unwind; the thread frees the base itself.
        let deadline = Date().addingTimeInterval(EngineThread.stopJoinDeadline)
        while thread.isExecuting {
            if Date() >= deadline {
                let msg = "EngineThread.stop: engine thread still executing after "
                    + "\(EngineThread.stopJoinDeadline)s — a vendored callback is wedged in a "
                    + "blocking call. Leaking the thread + event_base rather than hang the engine actor."
                FileHandle.standardError.write(Data((msg + "\n").utf8))
                log.fault("\(msg, privacy: .public)")
                // Resume any stranded continuations before returning (a hung
                // continuation freezes the app — strictly worse than a leak).
                sweepPending()
                return
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        // Clean exit: the thread has freed the base and returned. Sweep any
        // pending closure whose once-event never fired before the loop broke.
        sweepPending()
    }
}

/// A swappable, lock-guarded slot holding the engine's CURRENT ``EngineThread``.
///
/// C2: the vendored cluster owns ONE OS thread that cannot be restarted (a second
/// `Thread.start()` aborts), so `AirPlayEngine.start()` constructs a FRESH
/// `EngineThread` each time. The hot `write` path is `nonisolated` and must reach
/// the current thread without an actor hop, so the reference lives here (a
/// `nonisolated let` holder) rather than in an actor-isolated `var` the write path
/// couldn't read. `start()` sets it, `stop()` clears it.
final class EngineThreadHolder: @unchecked Sendable {
    private var thread: EngineThread?
    private let lock = NSLock()

    var current: EngineThread? {
        lock.lock(); defer { lock.unlock() }
        return thread
    }

    func set(_ t: EngineThread?) {
        lock.lock(); thread = t; lock.unlock()
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
