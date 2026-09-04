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
    private let touchInterval: TimeInterval
    /// Test-only observation hook, fired synchronously right after each Mach
    /// touch (including the first). `nil` in production. Exists so
    /// `PTPHelperActivationTests` can count touches without a second, parallel
    /// touch seam — the real ``touchMachService(named:)`` still runs every
    /// time; this never replaces it.
    private let onTouch: (@Sendable () -> Void)?
    /// Time source for the deadline/re-touch math below. Defaults to the wall
    /// clock; a test injects a manually-advanced fake (see
    /// `PTPHelperActivationTests`) so "does this loop retouch more than once
    /// before its deadline" is a fact about the LOOP'S ARITHMETIC, not a race
    /// against the shared test suite's scheduler. Real `Date()` has no
    /// business being asked to hold still for a fixed number of real seconds
    /// while ~3,000 other tests are also runnable — that unwinnable race is
    /// what `hangingOpenHitsTheHardTimeout` hit first (2026-08-30) and this
    /// loop hits the same way: given a bad enough scheduling gap, `now()` can
    /// already be past `deadline` the FIRST time this function's Task ever
    /// runs, and no timeout value fixes a race that can lose before it starts.
    private let now: @Sendable () -> Date
    /// Advances `now()` by `pollInterval` and yields. Defaults to a real
    /// sleep; a test injects an instant, deterministic advance so the whole
    /// loop runs at CPU speed with a fake clock instead of racing a real one.
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(
        ptpHelper: PTPHelperManaging = SMAppServicePTPHelper(),
        machServiceName: String = PTPHelperActivator.machServiceName,
        pollInterval: TimeInterval = 0.2,
        touchInterval: TimeInterval = 2.0,
        onTouch: (@Sendable () -> Void)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.ptpHelper = ptpHelper
        self.machServiceName = machServiceName
        self.pollInterval = pollInterval
        self.touchInterval = touchInterval
        self.onTouch = onTouch
        self.now = now
        self.sleep = sleep
    }

    public var willWaitForClock: Bool { ptpHelper.status == .enabled }

    public func activate(timeout: TimeInterval) async -> PTPHelperActivationOutcome {
        let status = ptpHelper.status
        guard status == .enabled else { return .needsApproval(status) }

        // The helper self-exits after its own ~15 s idle window
        // (AUDIOUT_PTP_IDLE_SECS, AirPlayEngine/Sources/ptp-helper/main.c)
        // and shm_unlinks its clock record on the way out — so if it was
        // already idling out right as this call started, ONE touch cannot
        // cover a wait that can run up to `timeout` (up to 10 s at real call
        // sites): the helper exits mid-wait and nothing re-demand-starts it
        // for the rest of it. Re-touch on any poll iteration where the last
        // touch has aged past `touchInterval`, for as long as the deadline
        // allows. Every touch is collected here and held for the WHOLE wait
        // via `withExtendedLifetime` below — releasing any of them early
        // would let ARC invalidate that connection mid-handshake, which is
        // the exact bug `PTPHelperReconciler.realLivenessProbe`'s doc comment
        // warns about: an early release forges a false failure/zombie signal,
        // it doesn't just leak a socket.
        var touches: [xpc_connection_t] = [Self.touchMachService(named: machServiceName)]
        onTouch?()
        var lastTouchAt = now()

        let deadline = now().addingTimeInterval(max(0, timeout))
        while now() < deadline {
            if PTPClockProbe.isReady() { break }
            // razor: fixed 2.0 s re-touch ceiling, not adaptive backoff — well
            // under the helper's own ~15 s idle-exit window, so a flat
            // interval keeps it re-armed with room to spare. Upgrade path:
            // back off the interval if a longer wait ever needs covering
            // more cheaply.
            if now().timeIntervalSince(lastTouchAt) >= touchInterval {
                touches.append(Self.touchMachService(named: machServiceName))
                onTouch?()
                lastTouchAt = now()
            }
            await sleep(pollInterval)
        }
        let ready = PTPClockProbe.isReady()
        withExtendedLifetime(touches) {}
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
        // nothing to retry into. ``unregisterDrainAndReregister(helper:registerRetryDelay:registerRetryAttempts:)``
        // below is this exact sequence, factored out so T9b's self-heal cycle
        // (``PTPHelperSelfHealingActivator``) can reuse it verbatim instead of
        // re-deriving the same landmine-avoidance at a second call site.
        let cycle = await Self.unregisterDrainAndReregister(
            helper: helper,
            registerRetryDelay: registerRetryDelay,
            registerRetryAttempts: registerRetryAttempts)
        switch cycle.outcome {
        case .unregisterThrew:
            Telemetry.log(.airplay, "ptp_zombie_heal", [
                "before": Self.telemetryStatus(status),
                "result": "heal_failed",
            ])
            return .healFailed
        case .drainNeverObserved:
            Telemetry.log(.airplay, "ptp_zombie_heal", [
                "before": Self.telemetryStatus(status),
                "result": "heal_failed",
                "drain_polls": String(cycle.drainPolls),
            ])
            return .healFailed
        case .registerExhausted:
            Telemetry.log(.airplay, "ptp_zombie_heal", [
                "before": Self.telemetryStatus(status),
                "result": "heal_failed",
                "register_attempts": String(cycle.registerAttempts),
            ])
            return .healFailed
        case .registered(let newStatus):
            Telemetry.log(.airplay, "ptp_zombie_heal", [
                "before": Self.telemetryStatus(status),
                "after": Self.telemetryStatus(newStatus),
                "drain_polls": String(cycle.drainPolls),
            ])
            return .healed(newStatus)
        }
    }

    /// Outcome of ``unregisterDrainAndReregister(helper:registerRetryDelay:registerRetryAttempts:)``.
    enum RegistrationCycleOutcome: Equatable {
        case registered(PTPHelperStatus)
        case unregisterThrew
        case drainNeverObserved
        case registerExhausted
    }

    /// The doomed-registration-safe unregister→drain→register sequence — see the
    /// LIVE ROOT CAUSE comment at this function's one call site inside
    /// `reconcile()` for why every step here is load-bearing: registering into
    /// an un-drained teardown lets a queued removal SIGTERM the fresh
    /// registration's own running helper. Shared by `reconcile()`'s zombie heal
    /// and ``PTPHelperSelfHealingActivator``'s repeated-timing-failure cycle —
    /// same daemon, same landmine, one implementation.
    static func unregisterDrainAndReregister(
        helper: PTPHelperManaging,
        registerRetryDelay: TimeInterval,
        registerRetryAttempts: Int
    ) async -> (outcome: RegistrationCycleOutcome, drainPolls: Int, registerAttempts: Int) {
        do {
            try await helper.unregister()
        } catch {
            return (.unregisterThrew, 0, 0)
        }
        var drainPolls = 0
        while helper.status != .notRegistered {
            guard drainPolls < max(1, registerRetryAttempts) else {
                return (.drainNeverObserved, drainPolls, 0)
            }
            drainPolls += 1
            try? await Task.sleep(nanoseconds: UInt64(registerRetryDelay * 1_000_000_000))
        }
        var attemptsUsed = 0
        for attempt in 0..<max(1, registerRetryAttempts) {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(registerRetryDelay * 1_000_000_000))
            }
            attemptsUsed = attempt + 1
            do {
                try helper.register()
                return (.registered(helper.status), drainPolls, attemptsUsed)
            } catch {
                continue
            }
        }
        return (.registerExhausted, drainPolls, attemptsUsed)
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

// MARK: - Self-heal on repeated timing failure (T9b, wedged-helper incident)

/// App-side self-heal for a WEDGED or STALE root PTP helper. Two motivating
/// incidents:
///
/// (2026-08-29, wedged): a wedged root helper held UDP 319/320 for over an
/// hour without servicing them, so every connect attempt failed
/// `.timingPortsUnavailable` for that whole hour with no self-recovery — dead
/// until a human intervened.
///
/// (2026-08-29, alive-but-stale, live hardware test): after a session ended,
/// the helper stayed ALIVE but stale — process running, clock record no
/// longer ready — and a full 14 s activation failed while the app's 2 s
/// re-touches flowed (the touches may even prolong the stale state, since the
/// helper counts them as peer connections). The two-consecutive-failures
/// trigger this wrapper used to require never armed, so recovery only
/// happened ~66 s later by luck: the stale helper finally idle-exited and a
/// re-touch spawned a fresh one that bound instantly. A full-budget
/// `.timingPortsUnavailable` with touches flowing already means one of two
/// things — a stale helper (a cycle heals it) or externally held ports (a
/// cycle changes nothing, so the retry still fails and the caller sees the
/// same banner) — so a cycle is the correct FIRST response to both; there is
/// nothing a second failure would prove that the first one didn't.
///
/// The app cannot kill a root process directly, but `SMAppService` CAN
/// unregister its OWN bundled daemon without a password (launchd then tears
/// the job down) and re-register it — approval for the same bundle id
/// survives, proven live. That teardown+respawn is the only password-free
/// lever against both a wedged and a stale helper, so this wraps a real
/// ``PTPHelperActivating`` and reaches for that lever on the very first
/// failure, before it reaches the user as the orange "clock unavailable"
/// banner.
///
/// Cycles on a SINGLE `activate(timeout:)` call ending
/// `.timingPortsUnavailable` — no streak requirement. The cycle itself is
/// ``PTPHelperReconciler/unregisterDrainAndReregister(helper:registerRetryDelay:registerRetryAttempts:)``
/// — the EXACT doomed-registration-safe sequence `PTPHelperReconciler.reconcile()`
/// uses for its zombie heal (see that function's LIVE ROOT CAUSE doc comment):
/// registering into an un-drained teardown risks a queued removal SIGTERMing
/// the freshly-registered helper mid-session, so this never re-derives its own
/// unregister/register ordering — reusing the proven sequence is what makes the
/// cycle provably safe against that trap. After a successful cycle, one more
/// `activate(timeout:)` runs on the real ``inner`` activator and ITS outcome is
/// what the caller sees — the caller (`NativeBackend.ensurePTPTakeover`) never
/// knows a cycle happened. A cycle that still fails (the externally-held-ports
/// case, where cycling changes nothing) surfaces `.timingPortsUnavailable`
/// exactly as it would have without this wrapper — same orange banner, same
/// Try Again.
///
/// Never starts a cycle while another `activate(timeout:)` call is still
/// awaiting its own clock — a second device's takeover wait can be genuinely
/// mid-flight (multiple devices can connect concurrently), and tearing the
/// shared daemon down under it would sabotage a wait that might still win.
/// That attempt's own failure still surfaces to ITS caller as
/// `.timingPortsUnavailable` with no cycle; the opportunity is deferred, not
/// lost — a later, non-concurrent attempt's own failure is independently
/// eligible to cycle.
///
/// razor: cycle on the first failure, exactly one cycle per rolling `window`
/// (60 s default), never a loop or a retry storm. A wedge or stale helper
/// that recurs inside one window is exactly the "surface failure to the
/// user" case this was asked to preserve, not a reason to widen the ceiling
/// — upgrade path is a product decision, not a bigger number here.
public struct PTPHelperSelfHealingActivator: PTPHelperActivating {
    private let inner: PTPHelperActivating
    private let helper: PTPHelperManaging
    private let window: TimeInterval
    private let registerRetryDelay: TimeInterval
    private let registerRetryAttempts: Int
    private let state = PTPSelfHealState()

    public init(
        inner: PTPHelperActivating = PTPHelperActivator(),
        helper: PTPHelperManaging = SMAppServicePTPHelper(),
        window: TimeInterval = 60,
        registerRetryDelay: TimeInterval = 0.5,
        registerRetryAttempts: Int = 10
    ) {
        self.inner = inner
        self.helper = helper
        self.window = window
        self.registerRetryDelay = registerRetryDelay
        self.registerRetryAttempts = registerRetryAttempts
    }

    public var willWaitForClock: Bool { inner.willWaitForClock }

    public func activate(timeout: TimeInterval) async -> PTPHelperActivationOutcome {
        state.beginAttempt()
        let outcome = await inner.activate(timeout: timeout)
        let othersInFlight = state.endAttempt()

        guard outcome == .timingPortsUnavailable else {
            return outcome
        }

        guard othersInFlight == 0, state.armCycleIfEligible(now: Date(), window: window) else {
            return outcome
        }

        let cycleStart = Date()
        let cycle = await PTPHelperReconciler.unregisterDrainAndReregister(
            helper: helper,
            registerRetryDelay: registerRetryDelay,
            registerRetryAttempts: registerRetryAttempts)

        guard case .registered = cycle.outcome else {
            Telemetry.log(.airplay, "ptp_helper_cycle", [
                "outcome": "cycle_failed",
                "elapsed_ms": "\(Int(Date().timeIntervalSince(cycleStart) * 1000))",
            ])
            return outcome
        }

        state.beginAttempt()
        let retryOutcome = await inner.activate(timeout: timeout)
        _ = state.endAttempt()

        let outcomeName: String
        switch retryOutcome {
        case .ready: outcomeName = "recovered"
        case .timingPortsUnavailable: outcomeName = "still_unavailable"
        case .needsApproval: outcomeName = "needs_approval"
        }
        Telemetry.log(.airplay, "ptp_helper_cycle", [
            "outcome": outcomeName,
            "elapsed_ms": "\(Int(Date().timeIntervalSince(cycleStart) * 1000))",
        ])
        return retryOutcome
    }
}

/// Lock-protected bookkeeping ``PTPHelperSelfHealingActivator`` uses to cap
/// cycling at one per rolling `window` — race-safe against concurrent
/// `activate()` calls from different devices' converge loops (`NativeBackend`
/// holds ONE shared activator instance for its whole lifetime). `@unchecked
/// Sendable` for the same reason as ``ProbeResumeGate``: the `NSLock` is
/// synchronization the compiler can't see.
private final class PTPSelfHealState: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var lastCycleAt: Date?

    /// Call before the wrapped `activate()` await starts.
    func beginAttempt() {
        lock.lock(); inFlight += 1; lock.unlock()
    }

    /// Call right after the wrapped `activate()` await returns. Returns how
    /// many OTHER attempts are still in flight — used to refuse a cycle while
    /// a concurrent takeover wait is mid-flight.
    func endAttempt() -> Int {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1
        return inFlight
    }

    /// True iff this attempt should start a cycle NOW: no cycle has fired
    /// within `window`. Arms the cycle (records `lastCycleAt`) atomically
    /// with the check so two racing callers can never both win.
    func armCycleIfEligible(now: Date, window: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let rateLimitClear = lastCycleAt.map { now.timeIntervalSince($0) > window } ?? true
        guard rateLimitClear else { return false }
        lastCycleAt = now
        return true
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
