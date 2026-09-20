import Foundation
import AudioToolbox
import AirPlayEngine
import CastSender

extension NativeBackend {

    /// Test-only (`@testable`): whether a `.processNotYetAudible` retry
    /// `DispatchWorkItem` is currently sitting in `pendingRetries` for
    /// `bundleID` — lets a test prove the map doesn't leak a stale reference
    /// past a non-retryable failure.
    func test_hasPendingRetry(bundleID: String) -> Bool {
        stateQueue.sync { pendingRetries[bundleID] != nil }
    }

    /// Test-only (`@testable`): whether a rebind-recovery retry
    /// `DispatchWorkItem` is currently sitting in `pendingRebindRecoveries`
    /// for `deviceID` — lets a test prove the map doesn't leak a stale
    /// reference past a superseding topology-driven `.rebind`.
    func test_hasPendingRebindRecovery(deviceID: String) -> Bool {
        stateQueue.sync { pendingRebindRecoveries[deviceID] != nil }
    }

    /// Test-only (`@testable`): whether a whole-system-tap `.failed` retry
    /// `DispatchWorkItem` (T16, E10) is currently sitting in
    /// `pendingCaptureRetry` — lets a test prove a `.failed` schedules exactly
    /// one in-flight retry (single-flighting) and that it's cancelled on
    /// recovery (`.capturing`) or a deliberate deselect.
    func test_hasPendingCaptureRetry() -> Bool {
        stateQueue.sync { pendingCaptureRetry != nil }
    }

    /// Test-only (`@testable`): whether the scheduling-snapshot poll (T2,
    /// `send_sched` telemetry) currently has a work item scheduled in
    /// `schedulingSnapshotPollWork` — lets a test prove the poll (re-)arms on
    /// the `captureRunning` false→true edge and is cancelled on the true→false
    /// edge, mirroring `test_hasPendingCaptureRetry()` above.
    func test_hasPendingSchedulingPoll() -> Bool {
        stateQueue.sync { schedulingSnapshotPollWork != nil }
    }

    /// Test-only (`@testable`): how many `send_sched` lines this backend has
    /// logged. Proves "selecting a second device while already capturing must
    /// not double the log rate" without reading the telemetry sink, which is
    /// process-global and unattributable — see ``schedulingSnapshotLogCount``.
    func test_schedulingPollLogCount() -> Int {
        stateQueue.sync { schedulingSnapshotLogCount }
    }

    /// Test-only (`@testable`): run one scheduling-snapshot poll NOW, instead of
    /// waiting out the live ~5 s cadence, so a test can read the `stream_health`
    /// line it writes. Goes through the real arming path, so it leaves exactly
    /// one poll armed, exactly as a capture start does.
    func test_pollSchedulingSnapshotNow() {
        stateQueue.sync { self.startSchedulingSnapshotPolling() }
    }

    /// Test-only (`@testable`): the whole-system-tap retry attempt counter
    /// (T16, E10) — lets a test prove the backoff actually grows across
    /// consecutive failures (rather than resetting or stacking) and resets to 0
    /// on recovery.
    func test_captureRetryCount() -> Int {
        stateQueue.sync { captureRetryCount }
    }

    /// Test-only (`@testable`): whether `bundleID` is currently recorded in
    /// `everCapturedBundleIDs`. Asserted DIRECTLY (rather than via an
    /// engine-bind side effect) because `resetAirPlaySessionForRoutedApp` —
    /// the consumer of a stale entry here — is a guaranteed no-op via its own
    /// `routeMixer.streamIDs(for:)` guard when triggered from
    /// `handleAppLaunched`'s synchronous relaunch path (the topology republish
    /// that would bind a stream hasn't run yet), so a test built on engine
    /// binds alone cannot distinguish a fixed `handleAppTerminated` from a
    /// broken one for that path.
    func test_hasEverCaptured(bundleID: String) -> Bool {
        stateQueue.sync { everCapturedBundleIDs.contains(bundleID) }
    }
}

extension NativeBackend {

    /// Test-only (`@testable`): the raw selection INTENT the app last asked for
    /// (`expectedSelected`) — distinct from `Device.isSelected` (streaming-now).
    /// Lets B6b tests assert intent survives a sleep/wake/watchdog cycle even when a
    /// failed reconnect legitimately deselects the model row.
    var test_expectedSelected: Set<String> { stateQueue.sync { expectedSelected } }

    /// Test-only (`@testable`): the settle window this instance was built with,
    /// so a test can pin the production default rather than trust it.
    var test_syncedLocalSettleWindow: TimeInterval { syncedLocalSettleWindow }

    /// Test-only (`@testable`): the churn horizon this instance was built with,
    /// pinned for the same reason as the window above.
    var test_syncedLocalTransitionHorizon: TimeInterval { syncedLocalTransitionHorizon }

    /// Test-only (`@testable`): whether a trailing-edge synced-local settle is
    /// currently armed. `stop()` enqueues the clear on `stateQueue`, so a read
    /// right after `stop()` returns can still see `true`: poll it, never read it once.
    var test_hasPendingSyncedLocalSettle: Bool { stateQueue.sync { pendingSyncedLocalSettle != nil } }

    /// Test-only (`@testable`): whether the app currently holds the Mac's default
    /// output with its aggregate, and the pre-takeover output it remembers — the
    /// two pieces of state the deselect-to-Mac-only restore turns over.
    var test_aggregateDefaultActive: Bool { stateQueue.sync { aggregateDefaultActive } }
    var test_priorDefaultUID: String? { stateQueue.sync { priorDefaultUID } }

    /// Test-only (`@testable`): whether the silence watchdog has un-gated capture
    /// (the Mac is audible as a fallback because zero desired devices are connected).
    var test_silenceFallbackActive: Bool { stateQueue.sync { silenceCaptureOverride } }

    /// Test-only (`@testable`): whether a silence-watchdog countdown is currently
    /// armed (awaiting either a reconnect or its own fire).
    var test_silenceWatchdogArmed: Bool { stateQueue.sync { silenceWatchdog != nil } }

    /// Test-only (`@testable`): whether the system-AirPlay double-path/echo note
    /// (W3-T3) is currently active.
    var test_systemAirPlayGuardActive: Bool { stateQueue.sync { systemAirPlayGuardActive } }

    /// Test-only (`@testable`): whether any per-device converge is still in flight —
    /// lets a Fix A test wait until a connect has fully released its `converging`
    /// slot before firing the whole-system tap-recreate reset (which skips a device
    /// still mid-converge, since that device's own fresh add re-anchors it).
    var test_isConverging: Bool { stateQueue.sync { !converging.isEmpty } }

    /// Test-only (`@testable`): the active scope-conflict record for `deviceID`
    /// (roadmap 008), or `nil` when no conflict is engaged — a `.device` route
    /// whose target is a Selected Device is demoted for the duration and recorded
    /// here (removed again on deselect/route edit). Diagnostic only; never read by
    /// any decision path.
    func test_scopeConflict(deviceID: String) -> ScopeConflict? {
        stateQueue.sync { lastScopeConflicts[deviceID] }
    }
}
