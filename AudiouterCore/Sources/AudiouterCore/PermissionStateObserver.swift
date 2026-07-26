// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import CoreFoundation   // CFNotificationCenter — the Darwin `tcc.access.changed` observer

/// Watches for the system-audio TCC grant arriving MID-SESSION and tells the
/// rest of the app the moment it actually has it — the missing half of
/// ``SystemAudioCaptureTCC``'s fresh-verdict latch.
///
/// ## Why this type exists at all
/// A live-instrumented run this session established three facts that, together,
/// make every simpler design wrong:
///  1. `TCCAccessPreflight` is **cached for the lifetime of the calling
///     process**. After the user granted, this process's own read stayed `2`
///     (undetermined) for 177 consecutive ticks over 203 seconds.
///  2. A **freshly spawned helper reads the APP's permission, not its own**:
///     at the grant instant the in-process read was `2` while `tcc-probe`
///     (``TCCProbeRunner``) read `0` (granted) — same app, same second.
///  3. The Darwin notification `com.apple.tcc.access.changed` **does fire** on
///     a grant (observed at the exact second) but **does not refresh the
///     in-process cache** — the reads after it stayed `2`.
///
/// So the notification is the **trigger** and the helper process is the
/// **reader**; neither alone is sufficient. This type is the seam that pairs
/// them: something kicks it (a notification, launch, wake, a routing action, a
/// popover open), it asks ``TCCProbeRunner`` for a fresh out-of-process answer,
/// and on the first `.resolved(.granted)` it records the one-way latch
/// (``SystemAudioCaptureTCC/recordFreshGrant(source:)``) and fires
/// ``onBecameGranted`` exactly once. The latch is what makes
/// `SystemAudioCaptureTCC.isGranted()` — the gate EVERY capture coordinator
/// checks before creating a tap — finally answer `true` in a process whose own
/// TCC read will never move.
///
/// This is a DETECTION problem, not an authorization one: a real process tap
/// captured audio successfully in that same stale process. macOS had already
/// authorized the app; the app just could not tell.
///
/// ## Zero timers, by decision
/// There is no `Timer`, no `DispatchSourceTimer`, and no polling loop anywhere
/// in this file, and none may be added. Every re-check is edge-driven from a
/// real event, and the burst safety that a coalescing timer would otherwise
/// provide comes from ``TCCProbeRunner``'s own single-flighting (a burst of
/// kicks produces AT MOST two helper spawns, however large the burst). Adding a
/// timer here would spawn a helper process on a schedule forever, for the one
/// event that fires at most once per session.
///
/// ## One-way, like the latch it feeds
/// ``onBecameGranted`` fires on the false→true EDGE and never again; after it
/// fires, ``kick(source:)`` is inert. Nothing here ever detects or reports a
/// revocation — that is deliberately left to
/// `AppDelegate.auditRequiredPermissionsIfNeeded`, exactly as
/// ``SystemAudioCaptureTCC/recordFreshGrant(source:)`` documents for the latch
/// itself. Adding a clearing path here would fight that subsystem's cooldown
/// for no benefit.
public final class PermissionStateObserver: @unchecked Sendable {

    /// Fired EXACTLY ONCE, on the transition edge, after
    /// ``SystemAudioCaptureTCC/recordFreshGrant(source:)`` has already been
    /// recorded. Called on an ARBITRARY thread (the helper spawn's completion
    /// thread); a main-thread consumer must hop itself.
    ///
    /// NOTE: production currently sets no handler, deliberately. Nothing
    /// auto-resumes audio when the grant lands — the app starts empty, per-app
    /// `.device` routes are cleared at launch, and the user re-picks a
    /// destination themselves. The LATCH is the whole point of this type: it is
    /// what makes that re-pick work immediately instead of needing a relaunch.
    /// This hook remains as a tested seam for a future consumer that genuinely
    /// needs the edge; do not wire resume behaviour back onto it without
    /// re-opening that product decision.
    public var onBecameGranted: (@Sendable () -> Void)? {
        get { lock.withLock { _onBecameGranted } }
        set { lock.withLock { _onBecameGranted = newValue } }
    }

    // MARK: Injected seams

    /// The out-of-process reader. Single-flighted internally, which is what
    /// makes an unthrottled ``kick(source:)`` from a routing hot path safe —
    /// see the type doc's "Zero timers" section.
    private let probeRunner: TCCProbeRunner

    /// The Darwin notification to observe. Defaults to the real
    /// `com.apple.tcc.access.changed`; injectable ONLY so the test suite can
    /// register for (and post) a private name of its own instead of posting a
    /// real system-wide TCC notification that other processes would act on.
    private let notificationName: String

    /// "Is the grant already known-good?" — the short-circuit that keeps a
    /// routing action from spawning a helper for a question already answered.
    /// Defaults to ``SystemAudioCaptureTCC/isGranted()``, which reads through
    /// the latch, so once the latch is set this costs no TCC call at all.
    private let isAlreadyGranted: @Sendable () -> Bool

    /// How a proven-fresh grant is recorded. Defaults to
    /// ``SystemAudioCaptureTCC/recordFreshGrant(source:)``; injectable so tests
    /// can assert the call without setting a process-wide, deliberately
    /// un-clearable latch in the test runner.
    private let recordFreshGrant: @Sendable (String) -> Void

    // MARK: State

    /// Guards every field below. Touched from the main thread (launch, wake,
    /// routing actions, popover open), from the Darwin notification's delivery
    /// thread, and from the helper spawn's completion thread.
    private let lock = NSLock()
    private var _onBecameGranted: (@Sendable () -> Void)?
    /// Whether ``start()`` has registered the Darwin observer and not yet been
    /// torn down. ``kick(source:)`` is inert while false, so an observer that
    /// was never armed (the app launched already granted) does nothing at all.
    private var armed = false
    /// One-way: set the first time a fresh `.granted` is resolved. Everything
    /// after that is a no-op — this is the "exactly once" in ``onBecameGranted``.
    private var didObserveGrant = false

    /// - Parameters:
    ///   - probeRunner: the fresh-process TCC reader. Tests inject one built
    ///     over a fake ``TCCProbeRunner/SpawnHelper`` so no real `tcc-probe`
    ///     process is ever spawned.
    ///   - notificationName: see the property doc — tests only.
    ///   - isAlreadyGranted: see the property doc.
    ///   - recordFreshGrant: see the property doc.
    public init(
        probeRunner: TCCProbeRunner = TCCProbeRunner(),
        notificationName: String = "com.apple.tcc.access.changed",
        isAlreadyGranted: @escaping @Sendable () -> Bool = { SystemAudioCaptureTCC.isGranted() },
        recordFreshGrant: @escaping @Sendable (String) -> Void = {
            SystemAudioCaptureTCC.recordFreshGrant(source: $0)
        }
    ) {
        self.probeRunner = probeRunner
        self.notificationName = notificationName
        self.isAlreadyGranted = isAlreadyGranted
        self.recordFreshGrant = recordFreshGrant
    }

    deinit {
        // MANDATORY, not hygiene: the registration below hands
        // `CFNotificationCenter` a bare, UNRETAINED pointer to `self`. Leaving
        // it registered past deallocation leaves the notification center
        // holding a dangling pointer it will happily call back into on the next
        // TCC change anywhere on the system.
        stop()
    }

    // MARK: Arming

    /// Arm the observer: register for the Darwin notification and immediately
    /// run one resolution (the LAUNCH trigger). Idempotent — a second call
    /// while already armed neither re-registers nor re-kicks.
    ///
    /// Callers should arm only when the grant is not already in place; an
    /// already-granted app has nothing to detect, and ``kick(source:)`` would
    /// short-circuit on every trigger anyway.
    public func start() {
        let shouldRegister: Bool = lock.withLock {
            guard !armed else { return false }
            armed = true
            return true
        }
        guard shouldRegister else { return }

        // `notify_register_dispatch`/`notify_register_check` are NOT reachable
        // from Swift (there is no module map for `notify.h` without a bridging
        // header — confirmed by trying), so `CFNotificationCenter`'s Darwin
        // center is the path that actually compiles and fires. Same shape as
        // ``TCCBucketDiagnostic``'s registration, which proved this exact call
        // receives the real notification.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            Self.accessChangedCallback,
            notificationName as CFString,
            nil,
            .deliverImmediately)

        Telemetry.log(.permission, "permission_observer_armed", ["name": notificationName])
        kick(source: "launch")
    }

    /// Unregister the Darwin observer. Idempotent, and called from `deinit` —
    /// see the `deinit` comment for why the removal is mandatory rather than
    /// merely tidy. The observer identity passed here is the SAME
    /// `Unmanaged.passUnretained(self).toOpaque()` pointer ``start()``
    /// registered with, per `CFNotificationCenterRemoveObserver`'s contract.
    public func stop() {
        let shouldRemove: Bool = lock.withLock {
            guard armed else { return false }
            armed = false
            return true
        }
        guard shouldRemove else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(rawValue: notificationName as CFString),
            nil)
    }

    // MARK: Kicking

    /// Ask for a fresh, out-of-process re-read. Returns IMMEDIATELY and never
    /// blocks — the helper spawn is entirely asynchronous — which is what makes
    /// this safe to call from the main thread on a routing action (a device
    /// toggle must not pay process-spawn latency).
    ///
    /// Inert in three cases, cheapest first: the grant is already known-good
    /// (``isAlreadyGranted``), the observer was never armed, or the grant edge
    /// has already been observed. A burst of kicks that DOES get through is
    /// absorbed by ``TCCProbeRunner``'s single-flighting, not by any timer here.
    ///
    /// `source` is carried into ``Telemetry`` and into the latch's own `source`
    /// field only, so a later log read can tell WHICH trigger actually caught
    /// the grant.
    public func kick(source: String) {
        // Cheapest check first, and free once the latch is set (the default
        // `isAlreadyGranted` reads through it and never touches TCC then).
        guard !isAlreadyGranted() else { return }
        let shouldResolve: Bool = lock.withLock { armed && !didObserveGrant }
        guard shouldResolve else { return }

        probeRunner.requestResolution { [weak self] result, _ in
            guard let self else { return }
            // ONLY a resolved `.granted` may latch. `.resolved(.denied)`,
            // `.resolved(.undetermined)` and every `.unresolved(...)` reason
            // (no helper in an unpackaged build, a timeout, a broken dlsym
            // path) mean "we still don't know" — collapsing any of them into a
            // verdict is the exact class of bug ``SystemAudioCaptureTCC``
            // exists to prevent, and this type must not reintroduce it.
            guard case .resolved(.granted) = result else { return }
            self.handleFreshGrant(source: source)
        }
    }

    /// The one-shot edge. Both the latch write and ``onBecameGranted`` happen
    /// here, in that order, so a handler that immediately re-drives capture
    /// already sees `SystemAudioCaptureTCC.isGranted() == true`.
    private func handleFreshGrant(source: String) {
        let isEdge: Bool = lock.withLock {
            guard !didObserveGrant else { return false }
            didObserveGrant = true
            return true
        }
        guard isEdge else { return }

        recordFreshGrant("PermissionStateObserver.\(source)")
        Telemetry.log(.permission, "permission_observer_granted", ["source": source])
        let handler = lock.withLock { _onBecameGranted }
        handler?()
    }

    // MARK: Darwin notification plumbing

    /// A bare C function pointer (`CFNotificationCallback`), NOT a capturing
    /// closure — the closure literal below captures nothing from its
    /// environment, which is exactly what lets Swift convert it to
    /// `@convention(c)`. The instance is recovered from the `observer`
    /// argument, which is the `Unmanaged.passUnretained(self).toOpaque()`
    /// pointer ``start()`` registered; `takeUnretainedValue` is correct because
    /// registration does not retain and `deinit` unregisters.
    ///
    /// Darwin notifications are COALESCED and PAYLOAD-FREE: several TCC changes
    /// may arrive as a single callback, and the callback says nothing about
    /// what changed or for which app. That is fine — this is only ever a "go
    /// re-check" kick, and the authoritative answer comes from the helper
    /// spawn. Never assume one callback equals one change.
    private static let accessChangedCallback: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }
        Unmanaged<PermissionStateObserver>.fromOpaque(observer)
            .takeUnretainedValue()
            .kick(source: "tcc_access_changed")
    }

    // MARK: Test seams

    /// Whether the Darwin observer is currently registered. Test-only: a
    /// missing `CFNotificationCenterRemoveObserver` is a dangling-pointer bug
    /// with no other observable symptom until it crashes.
    var test_isArmed: Bool { lock.withLock { armed } }

    /// Whether the grant edge has already been observed (so further kicks are
    /// inert). Test-only.
    var test_didObserveGrant: Bool { lock.withLock { didObserveGrant } }
}
