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

    // MARK: Audio I/O workgroup membership (T7)

    /// This thread's CURRENT `os_workgroup` membership token, or `nil` when it is
    /// not joined to one. `OpaquePointer` bridges the shim's opaque
    /// `engine_workgroup_token *`.
    ///
    /// THREAD IDENTITY IS THE WHOLE POINT. `os_workgroup_join`/`leave` act ONLY on
    /// the calling thread, so both this property's mutations and the C calls that
    /// produce/consume it happen exclusively on THIS thread — every public entry
    /// point below funnels through `enqueue`, and `threadMain`'s own exit path
    /// reads it inline. Nothing else may touch it, which is also why it needs no
    /// lock (single-thread confinement, the same discipline the rest of the C
    /// cluster keeps).
    private var workgroupToken: OpaquePointer?

    /// The `AudioObjectID` whose workgroup `workgroupToken` came from — the
    /// AGGREGATE device the capture tap built, never the default output device
    /// (measured: the two are distinct and do NOT nest, so joining the wrong one
    /// and then the right one returns `EALREADY`). Diagnostic/logging only;
    /// confined to this thread exactly like `workgroupToken`.
    private var workgroupDeviceID: UInt32?

    /// Point this thread's workgroup membership at `deviceID`'s I/O workgroup, or
    /// at nothing when `deviceID` is `nil`.
    ///
    /// Callable from ANY thread: the work is marshaled onto the engine thread,
    /// because that is the thread the join/leave must happen on. Returns `false`
    /// when it could not be scheduled at all (no base — pre-`start()`/post-`stop()`),
    /// in which case there is no membership to worry about anyway.
    ///
    /// LEAVE-THEN-JOIN, ALWAYS, AND IN ONE CLOSURE. The two halves are deliberately
    /// not separate scheduled units: a single closure makes the ordering structural
    /// rather than a property of two racing enqueues. And the order is forced —
    /// `os_workgroup_join` on a thread that is already in a non-nesting workgroup
    /// returns `EALREADY` and joins nothing, so a join-then-leave shape would both
    /// fail to join the new workgroup AND then drop the old membership, leaving the
    /// thread in no workgroup at all. (Apple documents no nesting guarantee between
    /// two unrelated device workgroups; the plan's measurement confirms `EALREADY`
    /// for this exact pair.) Sequential `updateWorkgroup` calls likewise stay
    /// ordered because `enqueue` preserves FIFO order on the engine thread.
    ///
    /// `tracked: false` is REQUIRED here, not an optimization: a tracked closure
    /// left over at teardown is run by `stop()`'s sweep — which executes on the
    /// STOPPING thread, not the engine thread — and a join/leave issued from the
    /// wrong thread is exactly the undefined behavior this file is guarding
    /// against. Dropping a late membership change instead is correct: `threadMain`
    /// unconditionally leaves on its way out.
    @discardableResult
    func updateWorkgroup(deviceID: UInt32?) -> Bool {
        enqueue({ [weak self] in
            self?.applyWorkgroupOnEngineThread(deviceID: deviceID)
        }, tracked: false)
    }

    /// The engine-thread half of `updateWorkgroup`. MUST run on the engine thread.
    private func applyWorkgroupOnEngineThread(deviceID: UInt32?) {
        // Leave first — unconditionally, even when re-joining the same id. See
        // `updateWorkgroup` for why this order is not negotiable.
        leaveWorkgroupOnEngineThread()

        guard let deviceID else { return }

        var token: OpaquePointer?
        let rc = engine_workgroup_join(deviceID, &token)
        switch rc {
        case 0:
            workgroupToken = token
            workgroupDeviceID = deviceID
            log.notice("engine thread joined audio I/O workgroup of device \(deviceID, privacy: .public)")
        case EINVAL:
            // NOT an error worth escalating. EINVAL means the target is gone or
            // never published a workgroup: the aggregate was torn down between the
            // capture coordinator scheduling this and the engine thread running it
            // (a tap mid-teardown when a device-change notification fires is a
            // NORMAL race), or this aggregate simply exposes no
            // kAudioDevicePropertyIOThreadOSWorkgroup at all (plan risk #6 — only a
            // synthetic aggregate was ever measured; a tap-bearing one publishing
            // nothing degrades us to QoS-only, which is a report-it, not a
            // work-around-it, outcome). Skip: no crash, no retry loop. The next
            // real lifecycle edge (a tap recreate) will try again on its own.
            log.info("audio I/O workgroup join skipped for device \(deviceID, privacy: .public): EINVAL (device cancelled/torn down, or it publishes no workgroup) — continuing without workgroup membership")
        case EALREADY:
            // Should be unreachable: the leave above always runs first. If it does
            // fire, the thread is in some OTHER workgroup joined outside this API,
            // which is a real bug — say so loudly rather than paper over it.
            log.fault("audio I/O workgroup join returned EALREADY for device \(deviceID, privacy: .public) — the engine thread is already in a workgroup this one does not nest with, joined outside EngineThread.updateWorkgroup")
        default:
            log.error("audio I/O workgroup join failed for device \(deviceID, privacy: .public): errno \(rc, privacy: .public)")
        }
    }

    /// Drop this thread's workgroup membership, if any. MUST run on the engine
    /// thread — `os_workgroup_leave` acts only on the calling thread. Idempotent
    /// (the shim treats a `nil` token as a no-op, and we clear ours either way).
    private func leaveWorkgroupOnEngineThread() {
        guard let token = workgroupToken else { return }
        let previous = workgroupDeviceID
        workgroupToken = nil
        workgroupDeviceID = nil
        engine_workgroup_leave(token)
        log.notice("engine thread left audio I/O workgroup of device \(previous ?? 0, privacy: .public)")
    }

    init(name: String = "com.airplayengine.engine") {
        // Use a Thread subclass so the run body can call back into `self`
        // without a capture-before-init of a stored `thread` property.
        let t = BodyThread()
        t.name = name
        // A generous stack — the RTSP/pairing state machine is deep.
        t.stackSize = 4 * 1024 * 1024
        // T4 (H1 mitigation, docs/plans/PLAN-AUDIO-THREAD-SCHEDULING.md §E):
        // this thread runs event_base_dispatch, which drives outputs_write →
        // airplay_write → ALAC encode/encrypt → packet send — the whole
        // audio-carrying path today (Stage 2 may split send onto its own RT
        // thread later, but until then this IS the send thread). Left at the
        // default QOS_CLASS_DEFAULT it can be starved for hundreds of ms
        // under heavy system load (H1), blowing through the receiver's
        // buffer. MUST be set before start() — QoS only affects a thread's
        // initial scheduling if set before it begins running; setting it
        // after start() has no effect on work already scheduled. No
        // feature-flag/experiment switch here — Q2 rejected A/B toggles for
        // this class of change, so it is unconditionally .userInteractive.
        //
        // Thread/queue audit performed alongside this change (other threads
        // that touch audio, left UNCHANGED — this task is EngineThread only):
        //   - Capture IOProc queues (NativeCaptureCoordinator.swift
        //     startIOProc, AudiouterCore's PerAppCaptureCoordinator.swift
        //     startIOProc) — NO CHANGE: Core Audio's HAL invokes the IOProc
        //     block at real-time priority regardless of the DispatchQueue's
        //     declared QoS; our setting here doesn't reach it either way.
        //   - Telemetry's writer queue (AudiouterCore/Telemetry.swift,
        //     `Writer.queue`, qos: .utility) — NO CHANGE, correct as-is:
        //     telemetry writes must stay low priority, not compete with
        //     audio for the CPU.
        //   - LocalPlaybackEngine.graphQueue / SyncedLocalSink.graphQueue
        //     (+ .lifecycleQueue) in AudiouterCore — DEFER: control-plane
        //     only, not on this plan's critical path.
        //   - DefaultOutputObserver / SystemOutputVolume / NativeDiscovery /
        //     DACPServer queues in AudiouterCore — DEFER: none carry audio
        //     samples.
        //   - ptp-helper (Sources/ptp-helper, separate root daemon process)
        //     — DEFER, strongest deferred candidate: a distinct process with
        //     no Core Audio device of its own, so there is no workgroup for
        //     it to join; its jitter shows up as multi-room sync drift, not
        //     single-device stutter; and it runs across a privilege boundary
        //     (root) that makes it a delicate thing to touch without strong
        //     justification.
        t.qualityOfService = .userInteractive
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

        // T7 EDGE 2 — a thread joined to an os_workgroup MUST NOT simply exit.
        // Apple's contract is that the join is unwound, on the same thread, before
        // that thread's function returns; not doing so is UNDEFINED BEHAVIOR, not a
        // logged error. `defer` (rather than a call before the last `return`) so it
        // covers EVERY exit path this function has — including the early
        // evthread/event_base_new failure return above, which today cannot hold a
        // membership (nothing can join before `start()` publishes the base) but must
        // not become a hole if this function grows another early return later.
        defer { leaveWorkgroupOnEngineThread() }

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
                // T7 EDGE 4 — ACCEPTED, BOUNDED LEAK: the workgroup membership
                // leaks along with the thread here, and there is NO fix available.
                // `os_workgroup_leave` acts ONLY on the calling thread; there is no
                // "leave on behalf of thread X" in the API. So a wedged engine
                // thread — one stuck in a blocking vendored call, which is the
                // entire reason this deadline exists — cannot be made to leave from
                // out here, and calling `leaveWorkgroupOnEngineThread()` on THIS
                // thread would be worse than the leak: it would be a leave issued
                // from a thread that never joined, i.e. the undefined behavior the
                // whole join/leave discipline exists to avoid, on top of a data race
                // on `workgroupToken` with the thread still running.
                //
                // This is deliberately NOT swallowed and NOT filed as a bug to fix:
                // it is the correct behavior given the API's constraint. The cost is
                // bounded exactly like the leaked thread + event_base it rides
                // along with — one membership per wedged stop(), on a path that
                // already logs `fault`, versus hanging the engine actor forever.
                // If the wedged thread ever DOES unwind, `threadMain`'s `defer`
                // (edge 2) still leaves correctly on its way out.
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
