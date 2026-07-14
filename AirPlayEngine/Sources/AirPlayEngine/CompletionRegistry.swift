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

/// Bridges C completions to Swift continuations, keyed by the dispatcher's
/// `callback_id`. All mutation happens on the engine thread (the hook fires
/// there, and waiters are armed there), so no lock is needed — but we guard with
/// one anyway for defensiveness against a stray call.
final class CompletionRegistry: @unchecked Sendable {

    /// The single active registry the C hook reads. Set by `install()`.
    static private(set) var shared: CompletionRegistry?

    private var waiters: [Int32: (OutputState) -> Void] = [:]
    private let lock = NSLock()

    /// Install this registry as the process-wide target and wire the C hook.
    /// Called once, on the engine thread, right after `evbase_player` is set.
    func install() {
        CompletionRegistry.shared = self
        outputs_engine_completion_set({ callbackId, _, state, _ in
            CompletionRegistry.shared?.deliver(callbackId: callbackId, state: state)
        }, nil)
    }

    /// Tear down the hook (on stop).
    func uninstall() {
        outputs_engine_completion_set(nil, nil)
        lock.lock(); waiters.removeAll(); lock.unlock()
        if CompletionRegistry.shared === self { CompletionRegistry.shared = nil }
    }

    /// Arm a waiter for `callbackId`. The completion closure is invoked once,
    /// with the terminal state, when the dispatcher delivers. Must be called on
    /// the engine thread (same thread the hook fires on) so the arm-then-report
    /// ordering can't race.
    func arm(callbackId: Int32, _ completion: @escaping (OutputState) -> Void) {
        lock.lock(); waiters[callbackId] = completion; lock.unlock()
    }

    /// Drop a waiter without delivering (used if arming an op is aborted before
    /// the backend was invoked).
    func disarm(callbackId: Int32) {
        lock.lock(); waiters.removeValue(forKey: callbackId); lock.unlock()
    }

    /// Called by the C hook on the engine thread. Resolves the state enum and
    /// resumes the matching waiter (once). Intermediate progress states
    /// (startup/connected) do NOT resolve the waiter — only terminal states do,
    /// matching the dispatcher's completion semantics (contract: STARTUP is
    /// intermediate).
    private func deliver(callbackId: Int32, state: output_device_state) {
        let mapped = OutputState(state)
        guard mapped.isTerminal else { return }
        lock.lock()
        let waiter = waiters.removeValue(forKey: callbackId)
        lock.unlock()
        waiter?(mapped)
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
