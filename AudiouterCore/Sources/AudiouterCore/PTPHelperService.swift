// SPDX-License-Identifier: GPL-2.0-or-later

import AirPlayEngine
import Foundation
import ServiceManagement
import XPC

/// The state of the privileged PTP helper daemon — the root `SMAppService`
/// launchd daemon that owns UDP 319/320 and the PTP master clock so AirPlay 2
/// speakers can share one timing source (AirPlayEngine/docs/ptp-helper-design.md
/// §2). A re-mapping of `SMAppService.Status`, not the raw enum itself, so
/// ``SetupModel`` and the onboarding UI never import `ServiceManagement` and a
/// test can construct any state with zero system dependency.
public enum PTPHelperStatus: Equatable, Sendable {
    /// Never registered, or unregistered since (`register()` hasn't run, or
    /// failed — see ``PTPHelperManaging/register()``'s doc comment).
    case notRegistered
    /// Registered, but not yet approved in System Settings › General › Login
    /// Items & Extensions. PTP is NOT usable in this state — treat it exactly
    /// like a stale/missing `airptp_shm` find (design doc §5.2): no PTP-timed
    /// session, "clock unavailable" surfaced to the UI.
    case requiresApproval
    /// Approved and running under launchd. `airptp_daemon_find()` can be
    /// expected to succeed (mirrors `SMAppService.Status.enabled`).
    case enabled
    /// The daemon is missing from the bundle, or launchd doesn't recognize the
    /// label at all (mirrors `.notFound`) — a packaging bug, not a user
    /// decision. There is nothing the approval UX can do about it, same
    /// posture as ``PermissionStatus/unsupported``.
    case notFound
}

/// The app-side seam for the PTP helper's `SMAppService` daemon registration —
/// mirrors `AudiouterSettingsUI`'s `LoginItemManaging` pattern exactly: a
/// protocol, not a bare `SMAppService` call, so ``SetupModel`` and its UI are
/// unit-testable without registering a real launchd daemon as a side effect of
/// a test run.
///
/// NOTE (Developer-ID gating, PROGRESS.md T5/T6): `register()` cannot reach
/// `.enabled` on this branch's ad-hoc-signed build — `SMAppService` daemon
/// registration validates the bundled launchd plist's code signature, which
/// ad-hoc signing does not satisfy. The real register()→approve→enabled path
/// is build/bundle-tested only (T5) and unit-tested only via the injected fake
/// (T6) until Developer ID signing lands; never call the real
/// `SMAppServicePTPHelper` from a test.
public protocol PTPHelperManaging {
    /// The live status, mapped from `SMAppService.Status`. Read fresh, not
    /// cached — the user can flip the Login Items toggle, or macOS can revoke
    /// it, at any time outside the app's control.
    var status: PTPHelperStatus { get }

    /// Register the daemon. Idempotent — `SMAppService.register()` is a no-op
    /// if already registered — and registering itself shows NO system prompt
    /// (unlike the audio/network/Accessibility seams): the daemon merely
    /// appears, disabled, in Login Items. The user-facing step is the
    /// *approval* afterwards, surfaced by `.requiresApproval`. Throws if the
    /// system refuses (e.g. a loose dev binary outside a proper bundle — same
    /// failure mode ``LoginItemManaging`` documents).
    func register() throws

    /// Deep-link to System Settings › General › Login Items & Extensions,
    /// where the user approves (or later revokes) the helper. Wraps the
    /// static `SMAppService.openSystemSettingsLoginItems()`.
    func openSystemSettingsLoginItems()
}

/// Production `PTPHelperManaging` over `SMAppService.daemon(plistName:)`.
///
/// The plist name below MUST equal the bundled launchd plist's filename
/// (`Contents/Library/LaunchDaemons/<name>`, `Label` + ".plist") — see
/// `scripts/ptp-helper.plist`'s own comment and `scripts/make-app.sh`'s
/// `HELPER_LABEL`. `SMAppService.daemon(plistName:)` resolves the plist by
/// this exact string; a mismatch fails registration silently into `.notFound`.
public struct SMAppServicePTPHelper: PTPHelperManaging {

    /// Mirrors `scripts/make-app.sh`'s `HELPER_LABEL` + ".plist" and
    /// `scripts/ptp-helper.plist`'s `Label` — BOTH are `${BUNDLE_ID}.ptphelper`
    /// at build time, so this reads the RUNNING bundle's own identifier rather
    /// than a hardcoded default. Without this, a side-by-side dev build under a
    /// distinct `BUNDLE_ID` override would ask `SMAppService` for a DIFFERENT
    /// app's already-claimed daemon identity, and `register()` would silently
    /// no-op instead of registering its own (2026-07-24 live-testing bug — see
    /// `scripts/ptp-helper.plist`'s comment for the full story). Falls back to
    /// the shipped default only if `Bundle.main.bundleIdentifier` is somehow
    /// unavailable (never true for a real app bundle).
    public static var plistName: String {
        "\(Bundle.main.bundleIdentifier ?? "com.audiouter.Audiouter").ptphelper.plist"
    }

    private let service: SMAppService

    public init(plistName: String = SMAppServicePTPHelper.plistName) {
        self.service = .daemon(plistName: plistName)
    }

    public var status: PTPHelperStatus {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    public func register() throws {
        try service.register()
    }

    public func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

// MARK: - Connect-time activation (T4, PLAN-AIRPLAY-COEXISTENCE.md)

/// Outcome of asking the on-demand PTP helper to be ready for an about-to-run
/// connect. Declared here (not derived ad hoc by a caller) because a later
/// task (T6, the "Taking over…" UI) consumes this same type — one shared
/// definition, not two.
public enum PTPHelperActivationOutcome: Equatable, Sendable {
    /// The helper is up and its clock is readable right now — safe to
    /// `addOutput`.
    case ready
    /// The user hasn't approved the helper in Login Items & Extensions (or it
    /// isn't registered/found at all). Carries the exact status so a caller
    /// can tell "never registered" from "waiting on the user". No Mach touch,
    /// no wait happened — launchd will not demand-start an unapproved job, so
    /// there was nothing to wait for.
    case needsApproval(PTPHelperStatus)
    /// Approved and touched, but no clock became readable before the
    /// timeout — the bind may still be racing macOS's own AirPlay off the
    /// ports (G1: ~1-3 s typical), or the daemon failed to come up at all.
    case timingPortsUnavailable
}

/// Demand-starts the PTP helper for an about-to-connect session and waits,
/// bounded, until its clock is actually readable. This is the ONE connect-time
/// seam `NativeBackend.convergeDevice` calls, immediately before `addOutput` —
/// never at `engine.start()`, which would be the launch-time wake the locked
/// decision (Q1=B, PLAN-AIRPLAY-COEXISTENCE.md) forbids. A protocol so tests
/// inject a fake with no real Mach service, launchd, or root daemon involved.
public protocol PTPHelperActivating: Sendable {
    /// Cheap, synchronous peek at whether the NEXT `activate(timeout:)` call
    /// will actually wait (status already `.enabled`) or short-circuit
    /// instantly (T6, the takeover status strip) — the exact same read
    /// `activate` itself performs first. Exposed separately so a caller can
    /// decide whether to show a transient "taking over" state BEFORE
    /// starting the (possibly-blocking) call, without duplicating the
    /// outcome logic or ever showing that state for the instant-return cases.
    var willWaitForClock: Bool { get }

    /// - Parameter timeout: total budget, after the Mach touch, to wait for
    ///   the clock to become readable.
    func activate(timeout: TimeInterval) async -> PTPHelperActivationOutcome
}

/// Production ``PTPHelperActivating``. Reads ``PTPHelperManaging/status``
/// FIRST — this ordering is the point of the task, not an optimization: only
/// when it is already `.enabled` does this touch the Mach service or wait at
/// all, so the most common real-world failure (never approved) returns
/// `.needsApproval` instantly instead of hanging out the full `timeout`.
/// Reuses the existing ``PTPHelperManaging`` seam (``PermissionProviders/ptpHelper``,
/// ``SimulatedPTPHelper``) for that read rather than inventing a parallel one.
public struct PTPHelperActivator: PTPHelperActivating {
    /// Mirrors ``SMAppServicePTPHelper/plistName`` minus the trailing
    /// `.plist` — the exact string `scripts/ptp-helper.plist`'s
    /// `MachServices` key registers (`__BUNDLE_ID__.ptphelper`) and the
    /// helper's own `AUDIOUTER_PTP_MACH_SERVICE` check-ins on
    /// (`AirPlayEngine/Sources/ptp-helper/main.c`).
    public static var machServiceName: String {
        "\(Bundle.main.bundleIdentifier ?? "com.audiouter.Audiouter").ptphelper"
    }

    private let ptpHelper: PTPHelperManaging
    private let machServiceName: String
    private let pollInterval: TimeInterval

    public init(
        ptpHelper: PTPHelperManaging = SMAppServicePTPHelper(),
        machServiceName: String = PTPHelperActivator.machServiceName,
        pollInterval: TimeInterval = 0.2
    ) {
        self.ptpHelper = ptpHelper
        self.machServiceName = machServiceName
        self.pollInterval = pollInterval
    }

    public var willWaitForClock: Bool { ptpHelper.status == .enabled }

    public func activate(timeout: TimeInterval) async -> PTPHelperActivationOutcome {
        let status = ptpHelper.status
        guard status == .enabled else { return .needsApproval(status) }

        // Held for the whole wait below via `withExtendedLifetime` — releasing
        // it early would let ARC invalidate the connection mid-handshake.
        let touch = Self.touchMachService(named: machServiceName)

        let deadline = Date().addingTimeInterval(max(0, timeout))
        while Date() < deadline {
            if PTPClockProbe.isReady() { break }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        let ready = PTPClockProbe.isReady()
        withExtendedLifetime(touch) {}
        return ready ? .ready : .timingPortsUnavailable
    }

    /// One fire-and-forget touch of `name`'s Mach service: launchd
    /// demand-starts the helper the moment a lookup for its `MachServices`
    /// name occurs. `.privileged` because the service is registered by a ROOT
    /// launchd job — macOS requires that flag for a non-root client to reach
    /// it. The daemon's own listener accepts the connection and ignores
    /// every message it's sent (`ptp_helper_mach_checkin`,
    /// `AirPlayEngine/Sources/ptp-helper/main.c`) — shm + loopback UDP stay
    /// the only real data path (`ptp-helper-design.md` §4) — so the message
    /// sent here carries no payload; it only exists to force the lookup to
    /// happen now rather than whenever XPC feels like it.
    private static func touchMachService(named name: String) -> xpc_connection_t {
        let queue = DispatchQueue(label: "com.audiouter.ptphelper.touch")
        let connection = xpc_connection_create_mach_service(
            name, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        xpc_connection_send_message(connection, xpc_dictionary_create_empty())
        return connection
    }
}
