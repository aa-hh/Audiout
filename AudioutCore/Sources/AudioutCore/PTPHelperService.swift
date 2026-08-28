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
/// mirrors `AudioutSettingsUI`'s `LoginItemManaging` pattern exactly: a
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
/// `Sendable` so a caller can read ``status`` off the main actor: the read is a
/// synchronous launchd XPC round-trip, and on the main thread it would ride the
/// Setup window's 1.5 s poll (see ``SetupModel/refreshPTPHelperStatus()``).
public protocol PTPHelperManaging: Sendable {
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

    /// Unregister the daemon. Idempotent — `SMAppService.unregister()` is a
    /// no-op if already unregistered (mirrors `register()`'s idempotency
    /// above) — safe to call on a service that was never registered, or was
    /// already torn down by an earlier call. `async throws` because
    /// `SMAppService.unregister()` has no synchronous variant (unlike
    /// `register()`); throws if the system refuses. Same Developer-ID gating
    /// note as `register()` applies in reverse: on this branch's ad-hoc-signed
    /// build the daemon never reaches `.enabled` in the first place, so
    /// `unregister()` is build/bundle-tested only until Developer ID signing
    /// lands; never call the real `SMAppServicePTPHelper` from a test.
    func unregister() async throws
}

/// Production `PTPHelperManaging` over `SMAppService.daemon(plistName:)`.
///
/// The plist name below MUST equal the bundled launchd plist's filename
/// (`Contents/Library/LaunchDaemons/<name>`, `Label` + ".plist") — see
/// `scripts/ptp-helper.plist`'s own comment and `scripts/make-app.sh`'s
/// `HELPER_LABEL`. `SMAppService.daemon(plistName:)` resolves the plist by
/// this exact string; a mismatch fails registration silently into `.notFound`.
/// `@unchecked Sendable`: an immutable struct whose one stored property is an
/// `SMAppService` handle, and whose only cross-thread use is the thread-safe
/// `status` read.
public struct SMAppServicePTPHelper: PTPHelperManaging, @unchecked Sendable {

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
        "\(Bundle.main.bundleIdentifier ?? "com.audiout.Audiout").ptphelper.plist"
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

    public func unregister() async throws {
        try await service.unregister()
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

/// Asks the on-demand helper to exit now, freeing UDP 319/320 without waiting
/// out its ~15 s idle window. Best-effort and fire-and-forget: no reply, no
/// error, no wait. A protocol so a test can assert the call without a daemon.
public protocol PTPHelperReleasing: Sendable {
    func release()
}

public struct PTPHelperReleaser: PTPHelperReleasing {
    private let machServiceName: String

    public init(machServiceName: String = PTPHelperActivator.machServiceName) {
        self.machServiceName = machServiceName
    }

    // razor: unauthenticated. Any local process can send this and stop our
    // clock — repeatedly, indefinitely, holding the daemon down as a
    // persistent denial of AirPlay, not just a one-off blip (impact: our
    // audio blips and re-establishes; no privilege is gained, DoS only, never
    // escalation). Upgrade path once hardened:
    // xpc_connection_set_peer_code_signing_requirement on the helper's peer
    // connections (macOS 13+, deployment target is 14).
    public func release() {
        // Nothing running to release — a send would demand-START the root
        // helper (rebinding 319/320) just to kill it, which is self-defeating
        // during the exact contention window this exists to shorten.
        guard PTPClockProbe.isReady() else { return }

        let queue = DispatchQueue(label: "com.audiout.ptphelper.release")
        let connection = xpc_connection_create_mach_service(
            machServiceName, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)

        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(message, "release", true)
        // Per-call connection lifetime is safe without `withExtendedLifetime`:
        // ARC holds `connection` across this call by virtue of being
        // referenced in it (measured: 200/200 delivered, +0 ports/+0 heap
        // over 500 iterations with the reference dropped immediately after).
        xpc_connection_send_message(connection, message)
    }
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
    /// helper's own `AUDIOUT_PTP_MACH_SERVICE` check-ins on
    /// (`AirPlayEngine/Sources/ptp-helper/main.c`).
    public static var machServiceName: String {
        "\(Bundle.main.bundleIdentifier ?? "com.audiout.Audiout").ptphelper"
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
    /// it. The daemon's own listener ignores every message it's sent except
    /// a dictionary with `{"release": true}` (`ptp_helper_mach_checkin`,
    /// `AirPlayEngine/Sources/ptp-helper/main.c`) — shm + loopback UDP stay
    /// the only real data path (`ptp-helper-design.md` §4). The message sent
    /// here is deliberately an empty dictionary — `release == false` when
    /// read — so this touch only forces the lookup to happen now rather than
    /// whenever XPC feels like it; it never asks the daemon to exit.
    private static func touchMachService(named name: String) -> xpc_connection_t {
        let queue = DispatchQueue(label: "com.audiout.ptphelper.touch")
        let connection = xpc_connection_create_mach_service(
            name, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        xpc_connection_send_message(connection, xpc_dictionary_create_empty())
        return connection
    }
}

// MARK: - Launch-time zombie reconciliation (T2, T-ZOMBIE)

/// What a single liveness probe of the (already-`.enabled`) PTP helper found.
/// Deliberately three-valued, not a `Bool`: the WHOLE point of T-ZOMBIE is that
/// "not healthy right now" splits into two causes that must NOT be treated the
/// same — a genuinely dead launchd job (`.zombie`, heal it) versus a live daemon
/// whose UDP 319/320 ports are merely busy losing the takeover race against
/// macOS's own AirPlay (`.indeterminate`, leave it alone; healing here would
/// tear down a daemon that is about to win the ports). See ``PTPHelperReconciler
/// /realLivenessProbe(machServiceName:pollInterval:timeout:)`` for how each is
/// distinguished, and the SAFETY PROPERTY there for why only one XPC signal may
/// ever mean `.zombie`.
public enum PTPLivenessProbeResult: Equatable, Sendable {
    /// The shared airptpd is up and its heartbeat is fresh (`PTPClockProbe
    /// .isReady()` returned true within the probe's deadline).
    case healthy
    /// launchd has no loaded job under the helper's `MachServices` name — the
    /// XPC connection was invalidated on its very first lookup. The
    /// `SMAppService` "enabled but not loaded" state this whole reconciler
    /// exists to heal.
    case zombie
    /// A VALID connection, but no readable clock before the deadline — the
    /// daemon exists, its ports are just contended. Never healed; this is the
    /// contention-safe branch.
    case indeterminate
}

/// The result of one launch-time reconcile pass, consumed by the launch wiring
/// (T4). Declared here as the ONE shared definition — T4 must not re-derive it —
/// so `.healed` can hand back the RE-READ status after `register()`: T4 presents
/// the Login Items approval screen iff that comes back `.requiresApproval`
/// (Developer-ID signing can land the healed daemon straight in `.enabled`, in
/// which case there is nothing for the user to approve).
public enum PTPZombieReconcileOutcome: Equatable, Sendable {
    /// Status was not `.enabled`, so there is no zombie to heal here — the
    /// never-registered / needs-approval / not-found cases are the onboarding
    /// flow's job, not this reconciler's. The probe was never run.
    case notEnabled
    /// `.enabled` and the clock is readable — nothing to do.
    case healthy
    /// `.enabled` with a valid-but-not-ready connection — legitimate PTP-port
    /// contention, NOT a zombie. Left untouched by design.
    case indeterminate
    /// A zombie was detected and `unregister()`→`register()` completed; carries
    /// the status re-read AFTER `register()` so T4 can decide whether to prompt
    /// for approval.
    case healed(PTPHelperStatus)
    /// A zombie was detected but `unregister()` or `register()` threw — logged;
    /// the helper is left in whatever state the failed call left it.
    case healFailed
}

/// Launch-time auto-repair for the PTP helper's "zombie" state: `SMAppService`
/// reports `.enabled` (the user approved it in Login Items) yet launchd has no
/// loaded job for the label, so `airptp_daemon_find()` can never succeed and
/// every AirPlay 2 session silently loses its shared clock. `SMAppService`
/// offers no direct "is the job actually loaded" query, so this pairs the status
/// read with a one-shot liveness probe and heals ONLY the unambiguous dead-job
/// signal — never legitimate port contention (see ``PTPLivenessProbeResult``).
///
/// Reuses the existing ``PTPHelperManaging`` seam (same one ``PTPHelperActivator``
/// reads) for status/`unregister()`/`register()`, plus an injected liveness probe
/// closure so the whole decision path is unit-testable with zero system deps: a
/// test injects a closure returning any ``PTPLivenessProbeResult`` and asserts the
/// ``PTPZombieReconcileOutcome`` without a real Mach service, launchd, or root
/// daemon. The default closure is the real XPC probe below.
/// `registerRetryDelay`/`registerRetryAttempts` pace BOTH heal phases — the
/// teardown-drain poll and the register retries — one budget each.
public struct PTPHelperReconciler: Sendable {
    private let helper: PTPHelperManaging
    private let probe: @Sendable () async -> PTPLivenessProbeResult
    private let registerRetryDelay: TimeInterval
    private let registerRetryAttempts: Int

    public init(
        helper: PTPHelperManaging,
        probe: @escaping @Sendable () async -> PTPLivenessProbeResult
            = { await PTPHelperReconciler.realLivenessProbe() },
        registerRetryDelay: TimeInterval = 0.5,
        registerRetryAttempts: Int = 10
    ) {
        self.helper = helper
        self.probe = probe
        self.registerRetryDelay = registerRetryDelay
        self.registerRetryAttempts = registerRetryAttempts
    }

    /// The PURE, side-effect-free heal decision — no `self`, no probe call, no
    /// I/O — so a test can exhaust the truth table directly. Heal IFF the
    /// service claims `.enabled` yet the probe found a dead job. Every other
    /// combination (any non-`.enabled` status, or a `.healthy`/`.indeterminate`
    /// probe) returns false; in particular `.indeterminate` NEVER heals.
    public static func shouldHeal(
        status: PTPHelperStatus, probeResult: PTPLivenessProbeResult
    ) -> Bool {
        status == .enabled && probeResult == .zombie
    }

    /// One reconcile pass, safe to call unconditionally at launch.
    ///
    /// Order matters: status is read FIRST and a non-`.enabled` status returns
    /// `.notEnabled` WITHOUT running the probe — there is no zombie to detect
    /// unless the system believes the helper is enabled, and the other states
    /// belong to onboarding. Only when `.enabled` does it run the (bounded)
    /// probe once and branch on ``shouldHeal(status:probeResult:)``.
    public func reconcile() async -> PTPZombieReconcileOutcome {
        let status = helper.status
        guard status == .enabled else { return .notEnabled }

        let probeResult = await probe()
        guard Self.shouldHeal(status: status, probeResult: probeResult) else {
            // Not a zombie: mirror the probe. `.indeterminate` (live daemon,
            // busy ports) explicitly falls here — the contention-safe branch
            // that must never heal.
            return probeResult == .healthy ? .healthy : .indeterminate
        }

        // Zombie confirmed: unregister the stale registration, then re-register
        // to make launchd load a fresh job.
        //
        // LIVE ROOT CAUSE (2026-08-06, signed build): `SMAppService.unregister()`
        // returning means BTM ACCEPTED the teardown, not that it finished. The
        // record teardown and the launchd-side removal drain asynchronously —
        // observed up to ~30s late — and a `register()` accepted mid-teardown
        // ("Register error: 1", then success 0.5s later) creates a DOOMED
        // registration: the still-queued removal later executes against it
        // ("remove succeeded (EINPROGRESS)" in smd's log), SIGTERMs the RUNNING
        // helper mid-session, and deletes the job — so the next launch finds a
        // fresh, REAL zombie and heals again, forever (4 launches → 4 heals,
        // telemetry 2026-08-05T22:30–34Z). A register that lands AFTER the
        // teardown fully drained sticks and KEEPS Login Items approval (proven
        // live: the one surviving heal's job outlived helper idle-exit, app
        // quit, and 25+ minutes). So the heal (1) waits for the drain to be
        // OBSERVABLE — status reads `.notRegistered` — before registering, and
        // refuses to register into an un-drained teardown (that would trade
        // "heal failed" for "heal manufactures the next launch's zombie"), then
        // (2) still retries `register()` with spacing for any residual
        // acceptance race. `unregister()` throwing fails immediately — there is
        // nothing to retry into.
        do {
            try await helper.unregister()
        } catch {
            Telemetry.log(.airplay, "ptp_zombie_heal", [
                "before": Self.telemetryStatus(status),
                "result": "heal_failed",
            ])
            return .healFailed
        }
        var drainPolls = 0
        while helper.status != .notRegistered {
            guard drainPolls < max(1, registerRetryAttempts) else {
                Telemetry.log(.airplay, "ptp_zombie_heal", [
                    "before": Self.telemetryStatus(status),
                    "result": "heal_failed",
                    "drain_polls": String(drainPolls),
                ])
                return .healFailed
            }
            drainPolls += 1
            try? await Task.sleep(nanoseconds: UInt64(registerRetryDelay * 1_000_000_000))
        }
        var registered = false
        var attemptsUsed = 0
        for attempt in 0..<max(1, registerRetryAttempts) {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(registerRetryDelay * 1_000_000_000))
            }
            attemptsUsed = attempt + 1
            do {
                try helper.register()
                registered = true
                break
            } catch {
                continue
            }
        }
        guard registered else {
            Telemetry.log(.airplay, "ptp_zombie_heal", [
                "before": Self.telemetryStatus(status),
                "result": "heal_failed",
                "register_attempts": String(attemptsUsed),
            ])
            return .healFailed
        }

        let newStatus = helper.status
        Telemetry.log(.airplay, "ptp_zombie_heal", [
            "before": Self.telemetryStatus(status),
            "after": Self.telemetryStatus(newStatus),
            "drain_polls": String(drainPolls),
        ])
        return .healed(newStatus)
    }

    /// Stable short tokens for the telemetry line (the enum has no raw value).
    private static func telemetryStatus(_ status: PTPHelperStatus) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .requiresApproval: return "requiresApproval"
        case .enabled: return "enabled"
        case .notFound: return "notFound"
        }
    }

    /// razor: the real probe is an untested-by-design system-integration ceiling
    /// — same posture as ``PTPHelperActivator/touchMachService(named:)`` and
    /// ``PTPClockProbe/isReady()``, which touch a real Mach service / root daemon
    /// and so are exercised live, not in the suite. Everything ABOVE it (the pure
    /// ``shouldHeal(status:probeResult:)`` and ``reconcile()``'s branching over an
    /// injected probe) IS unit-tested. Upgrade path: if this ever needs coverage,
    /// wrap the three raw signals behind a seam and fake them — do not try to
    /// unit-test the live XPC race.
    ///
    /// Races three outcomes and resumes a single continuation AT MOST ONCE
    /// (``ProbeResumeGate``):
    ///  1. the XPC connection is invalidated on its first lookup
    ///     (`XPC_ERROR_CONNECTION_INVALID`) → `.zombie` — launchd does not know
    ///     the `MachServices` name, the unambiguous dead-job signal.
    ///  2. ``PTPClockProbe/isReady()`` becomes true within the deadline
    ///     → `.healthy`.
    ///  3. the deadline elapses with a still-valid connection but no clock
    ///     → `.indeterminate` — legitimate contention, MUST NOT heal.
    ///
    /// SAFETY PROPERTY: ONLY `XPC_ERROR_CONNECTION_INVALID` maps to `.zombie`. A
    /// valid-but-not-ready connection — including `XPC_ERROR_CONNECTION_INTERRUPTED`
    /// or any real reply — is `.indeterminate`, NEVER `.zombie`; healing a merely
    /// busy daemon would tear it down mid-takeover. The connection is held for the
    /// whole race via `withExtendedLifetime`, exactly as `touchMachService` does:
    /// releasing it early would itself invalidate the connection and FORGE a false
    /// `.zombie`. The deadline is deliberately short — this runs at launch.
    public static func realLivenessProbe(
        machServiceName: String = PTPHelperActivator.machServiceName,
        pollInterval: TimeInterval = 0.2,
        timeout: TimeInterval = 1.5
    ) async -> PTPLivenessProbeResult {
        let gate = ProbeResumeGate()
        let queue = DispatchQueue(label: "com.audiout.ptphelper.liveness")
        let connection = xpc_connection_create_mach_service(
            machServiceName, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))

        return await withCheckedContinuation {
            (continuation: CheckedContinuation<PTPLivenessProbeResult, Never>) in
            gate.arm(continuation)

            // (1) zombie signal. `xpc_equal` against the singleton error object
            // is the documented way to test for connection invalidation; every
            // OTHER event (interrupted, a real reply, termination-imminent) is
            // intentionally ignored so it falls through to the deadline below.
            xpc_connection_set_event_handler(connection) { event in
                if xpc_equal(event, XPC_ERROR_CONNECTION_INVALID) {
                    gate.finish(.zombie)
                }
            }
            xpc_connection_resume(connection)
            xpc_connection_send_message(connection, xpc_dictionary_create_empty())

            // (2)/(3) clock-ready vs. deadline, on a detached poller. It also
            // owns the connection's lifetime for the whole race — matching
            // `touchMachService`'s `withExtendedLifetime` — so ARC cannot free
            // it early and manufacture a `.zombie`.
            Task.detached {
                let deadline = Date().addingTimeInterval(max(0, timeout))
                while Date() < deadline {
                    if PTPClockProbe.isReady() { gate.finish(.healthy); break }
                    try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                }
                // No-op if (1) or (2) already resumed; otherwise the valid-but-
                // not-ready verdict.
                gate.finish(.indeterminate)
                withExtendedLifetime(connection) {}
            }
        }
    }
}

/// Single-resume guard for ``PTPHelperReconciler/realLivenessProbe`` — three
/// concurrent producers (the XPC event handler on its own queue, and the
/// clock-poll / deadline arms on a detached task) race to resolve the probe, but
/// a `CheckedContinuation` may be resumed EXACTLY once. `@unchecked Sendable`
/// because the `NSLock` provides the synchronization the compiler cannot see;
/// the `resumed` flag under the lock makes every `finish(_:)` after the first a
/// silent no-op.
private final class ProbeResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PTPLivenessProbeResult, Never>?
    private var resumed = false

    func arm(_ continuation: CheckedContinuation<PTPLivenessProbeResult, Never>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func finish(_ result: PTPLivenessProbeResult) {
        lock.lock()
        guard !resumed, let continuation else { lock.unlock(); return }
        resumed = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: result)
    }
}
