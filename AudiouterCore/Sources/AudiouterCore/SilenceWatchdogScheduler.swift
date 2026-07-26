// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A cancellable handle to a scheduled silence-watchdog fire (Wave 2, R11).
/// `cancel()` drops the pending body if it hasn't run yet; a body already in
/// flight is harmless because `NativeBackend.fireSilenceWatchdog` re-checks its
/// guards before acting (a late fire is inert).
protocol SilenceWatchdogToken: AnyObject {
    func cancel()
}

/// Injectable timer seam for the generalized silence watchdog (Wave 2 W2-T2,
/// fixes R11). Production schedules on a real dispatch queue; hermetic tests
/// inject a manual scheduler and FIRE the countdown deterministically instead of
/// waiting real wall-clock seconds — so a "T seconds with nothing connected"
/// scenario is a single `fire()` call, never a `sleep`.
protocol SilenceWatchdogScheduling: Sendable {
    /// Run `body` after `delay` seconds. The returned token cancels a not-yet-run
    /// body. `body` is always marshalled onto `NativeBackend`'s `stateQueue` by the
    /// caller, so an implementation may deliver it on any thread.
    func schedule(after delay: TimeInterval, _ body: @escaping @Sendable () -> Void) -> SilenceWatchdogToken
}

/// Production scheduler: a plain `DispatchQueue.asyncAfter`. The caller wraps the
/// body in a `stateQueue.async` hop, so this queue only needs to time the delay,
/// not provide the serialization.
final class DispatchSilenceWatchdogScheduler: SilenceWatchdogScheduling {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) { self.queue = queue }

    func schedule(after delay: TimeInterval, _ body: @escaping @Sendable () -> Void) -> SilenceWatchdogToken {
        let work = DispatchWorkItem(block: body)
        queue.asyncAfter(deadline: .now() + delay, execute: work)
        return Token(work)
    }

    private final class Token: SilenceWatchdogToken {
        private let work: DispatchWorkItem
        init(_ work: DispatchWorkItem) { self.work = work }
        func cancel() { work.cancel() }
    }
}
