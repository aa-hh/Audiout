// AirPlayEngine — the C completion hook -> Swift async bridge (T-API-1).
//
// Implements build-notes §6 item 2. The vendored dispatcher (shims/outputs.c)
// fires outputs_engine_completion(callback_id, device_id, state, ctx) exactly
// once per armed callback_id (contract in docs/outputs-dispatcher-contract.md),
// on the engine thread. We register a @convention(c) hook that routes each
// completion to the async continuation that armed that callback_id.
//
// HOW THE ASYNC BRIDGE WORKS (the core of T-API-1):
//   1. addOutput arms a waiter: it stores a continuation under a fresh
//      callback_id via `outputs_callback_add(device, statusCb)` (that call, plus
//      registering the continuation, both happen on the engine thread).
//   2. It then calls output_airplay.device_start(device, callback_id); the
//      backend returns N (1 in this cluster) meaning "one deferred completion
//      will arrive for this id".
//   3. Later, on the engine thread, the dispatcher delivers outputs_cb -> the
//      deferred drain -> our @convention(c) completion hook, which looks up and
//      resumes the stored continuation with the terminal OutputState.
//
// A @convention(c) function pointer can't capture Swift state, so the hook reads
// a process-wide registry (there is one engine instance per process in practice;
// the registry is keyed by callback_id which the vendored dispatcher guarantees
// unique-in-flight).

import Foundation
import CAirPlayEngine
import os

/// Bridges C completions to Swift continuations, keyed by the dispatcher's
/// `callback_id`. Waiters are armed and delivered on the engine thread, but
/// the per-op timeout timers fire on `timerQueue` and resolve under the same
/// `lock` — the lock is load-bearing, not defensive.
final class CompletionRegistry: @unchecked Sendable {

    /// The single active registry the C hook reads. Set by `install()`.
    static private(set) var shared: CompletionRegistry?

    /// Default per-op timeout. An armed op whose deferred completion doesn't
    /// arrive within this window is resolved by THROWING ``AirPlayEngineError/opTimedOut``
    /// (and removed from the table) instead of leaking its continuation forever.
    ///
    /// RATIONALE: this is a backstop for a receiver whose media/PTP path stalls
    /// mid-op (e.g. a bad IPv6 link-local address in the descriptor, or any
    /// mid-op drop) so the completion the dispatcher promised never fires. It must
    /// be comfortably LONGER than a slow-but-real RTSP SETUP + PTP handshake so it
    /// never false-trips a legitimately-slow-but-succeeding session — a real AP2
    /// pair+setup against a cold receiver is on the order of a few seconds — but
    /// short enough that a stalled op surfaces (and NativeBackend parks + recovers
    /// the device) well before a user notices a wedged toggle. 12 s balances both.
    static let defaultOpTimeout: TimeInterval = 12.0

    /// One armed waiter. `deliver` is invoked (once) with the terminal state when
    /// the dispatcher completes normally; `cancel` is invoked (once) instead when
    /// the engine tears down with the op still in flight; `timeout` is invoked
    /// (once) instead when the bounded timeout elapses with no completion. EXACTLY
    /// ONE of the three ever fires (each removes the waiter under `lock` before
    /// resolving), so the awaiting continuation is RESUMED exactly once rather
    /// than leaked — a leaked `withCheckedThrowingContinuation` both trips
    /// "CONTINUATION MISUSE" and hangs `stop()`/app-quit forever (first-light
    /// backlog, toggle-spam session 2026-07-17: 177 such leaks when a stalled op
    /// never completed during NORMAL running, which `uninstall()`'s stop-only
    /// cancellation did not cover).
    ///
    /// `timer` is the DispatchSource backing this op's timeout; whichever of the
    /// three paths fires cancels it so the timeout can't fire after a real
    /// delivery (and the timer's own handler is a no-op if the waiter is already
    /// gone — the removal-under-lock is the single source of truth).
    private struct Waiter {
        let deliver: (OutputState) -> Void
        let cancel: () -> Void
        let timeout: () -> Void
        let timer: DispatchSourceTimer?
    }

    private var waiters: [Int32: Waiter] = [:]
    private let lock = NSLock()

    /// Serial queue the per-op timeout timers fire on. Off the engine thread on
    /// purpose (the engine thread may itself be wedged inside a stalled op), so a
    /// timeout can always fire; the resolution it triggers only touches the
    /// lock-guarded `waiters` table and resumes a continuation — never the C
    /// cluster — so it needs no engine-thread affinity.
    private let timerQueue = DispatchQueue(label: "com.airplayengine.completion-timeout")

    /// Install this registry as the process-wide target and wire the C hook.
    /// Called once, on the engine thread, right after `evbase_player` is set.
    func install() {
        CompletionRegistry.shared = self
        outputs_engine_completion_set({ callbackId, _, state, _ in
            CompletionRegistry.shared?.deliver(callbackId: callbackId, state: state)
        }, nil)
    }

    /// Tear down the hook (on stop). CANCELS every still-armed waiter so no
    /// in-flight `startOp` continuation is dropped: each is resumed (throwing
    /// ``AirPlayEngineError/engineNotRunning``) before the table is cleared, so
    /// `engine.stop()` / app-quit can never hang awaiting a completion the
    /// dispatcher will now never deliver (the C hook is unset first).
    func uninstall() {
        outputs_engine_completion_set(nil, nil)
        lock.lock()
        let cancelled = waiters
        waiters.removeAll()
        lock.unlock()
        for (_, waiter) in cancelled {
            // Cancel the timeout timer first so it can't race after we resume the
            // continuation here (its handler no-ops anyway once the waiter is gone).
            waiter.timer?.cancel()
            waiter.cancel()
        }
        if CompletionRegistry.shared === self { CompletionRegistry.shared = nil }
    }

    /// Arm a waiter for `callbackId`. `completion` is invoked once with the
    /// terminal state on normal delivery; `onCancel` is invoked once instead if
    /// the registry is torn down (uninstall) with this waiter still armed;
    /// `onTimeout` is invoked once instead if no completion arrives within
    /// `timeout` (a mid-op receiver stall — the completion the dispatcher promised
    /// never fires). EXACTLY ONE of the three fires (each removes the waiter under
    /// `lock`). Must be called on the engine thread (same thread the hook fires
    /// on) so the arm-then-report ordering can't race.
    ///
    /// A non-positive `timeout` disables the timer (used by tests that only
    /// exercise the deliver/cancel paths); production always passes a positive
    /// interval so a stalled op can never leak its continuation.
    /// Returns `false` and arms NOTHING if a waiter is ALREADY armed for
    /// `callbackId` (B5.3): overwriting it would drop the existing op's
    /// continuation (a permanent hang + a false timeout on the other op). The
    /// per-``OutputID`` op serialization in ``AirPlayEngine`` makes a same-id
    /// collision unreachable in normal flow; this is the belt-and-suspenders that
    /// refuses rather than silently clobbers if that guard is ever bypassed. The
    /// caller must resolve its own continuation (and release the C slot) on false.
    @discardableResult
    func arm(
        callbackId: Int32,
        timeout: TimeInterval,
        onCancel: @escaping () -> Void,
        onTimeout: @escaping () -> Void,
        _ completion: @escaping (OutputState) -> Void
    ) -> Bool {
        var timer: DispatchSourceTimer?
        if timeout > 0 {
            let t = DispatchSource.makeTimerSource(queue: timerQueue)
            t.schedule(deadline: .now() + timeout, repeating: .never)
            t.setEventHandler { [weak self] in
                self?.fireTimeout(callbackId: callbackId)
            }
            timer = t
        }
        lock.lock()
        if waiters[callbackId] != nil {
            lock.unlock()
            timer?.cancel()
            Logger(subsystem: "com.airplayengine", category: "completion")
                .error("CompletionRegistry.arm refused: waiter already armed for callbackId \(callbackId) — refusing to overwrite (would strand a continuation)")
            return false
        }
        waiters[callbackId] = Waiter(
            deliver: completion, cancel: onCancel, timeout: onTimeout, timer: timer
        )
        lock.unlock()
        // Activate only after the waiter is in the table, so the handler (which
        // resolves by looking the waiter up under the lock) can never observe a
        // half-armed state.
        timer?.activate()
        return true
    }

    /// Test-only: whether a waiter is currently armed for `callbackId`. Lets a
    /// headless test fire its synthetic completion only AFTER the registry waiter
    /// exists (not merely after `outputs_callback_add` returned), closing the
    /// arm-window race where a too-early completion is delivered to an absent
    /// waiter and silently dropped.
    func hasWaiter(callbackId: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return waiters[callbackId] != nil
    }

    /// Drop a waiter without delivering, cancelling, or timing out (used if arming
    /// an op is aborted before the backend was invoked — the caller resolves it
    /// directly). Cancels the timeout timer so it can't fire for a spent id.
    func disarm(callbackId: Int32) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: callbackId)
        lock.unlock()
        waiter?.timer?.cancel()
    }

    /// The DispatchSource timeout handler. Removes the waiter under the SAME lock
    /// the deliver/cancel paths use so at most one of {deliver, cancel, timeout}
    /// ever resolves — if a real completion (or uninstall) already removed the
    /// waiter, this finds nothing and is a no-op (the timer may have already been
    /// in flight when the completion cancelled it). Otherwise it resumes the
    /// awaiting continuation by throwing (via the stored `timeout` closure).
    private func fireTimeout(callbackId: Int32) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: callbackId)
        lock.unlock()
        waiter?.timeout()
    }

    /// Test seam: drive `deliver` directly (the C hook path is exercised
    /// elsewhere) so a unit test can resolve an armed waiter without a dispatcher.
    func deliverForTest(callbackId: Int32, state: output_device_state) {
        deliver(callbackId: callbackId, state: state)
    }

    /// Called by the C hook on the engine thread. Resolves the state enum and
    /// resumes the matching waiter (once). Intermediate progress states
    /// (startup) do NOT resolve the waiter — only terminal states do,
    /// matching the dispatcher's completion semantics (contract: STARTUP is
    /// intermediate).
    private func deliver(callbackId: Int32, state: output_device_state) {
        let mapped = OutputState(state)
        guard mapped.isTerminal else { return }
        lock.lock()
        let waiter = waiters.removeValue(forKey: callbackId)
        lock.unlock()
        // Cancel the timeout first: removing the waiter under the lock is what
        // guarantees single-resolution, but cancelling stops the timer from
        // needlessly firing (and its handler would no-op anyway — the waiter is
        // gone). The real completion won the race.
        waiter?.timer?.cancel()
        waiter?.deliver(mapped)
    }
}

extension OutputState {
    /// Map the vendored `enum output_device_state` (negative FAILED/PASSWORD) to
    /// the neutral Swift enum.
    init(_ c: output_device_state) {
        switch c {
        case OUTPUT_STATE_STOPPED:   self = .stopped
        case OUTPUT_STATE_STARTUP:   self = .startup
        case OUTPUT_STATE_CONNECTED: self = .connected
        case OUTPUT_STATE_STREAMING: self = .streaming
        case OUTPUT_STATE_FAILED:    self = .failed
        case OUTPUT_STATE_PASSWORD:  self = .passwordRequired
        default:                     self = .failed
        }
    }
}
