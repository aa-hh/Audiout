// SPDX-License-Identifier: GPL-2.0-or-later

import CoreAudio
import Foundation

/// The single process-wide owner of the Mac's default output device identity
/// (`kAudioHardwarePropertyDefaultOutputDevice`) and that device's nominal
/// sample rate (`kAudioDevicePropertyNominalSampleRate`).
///
/// ## Why this exists
/// Nothing owned the shared device rate. Every component that cared installed
/// its OWN pair of HAL property listeners on the SAME system object and the
/// SAME device — two capture coordinators today, a third routing path proposed
/// — each with its own compare-before-rebuild loop-breaker. That shape produced
/// the same bug twice (the storm loop-breaker had to be landed once per
/// coordinator) and is exactly what the external baseline (JUCE, Rogue Amoeba)
/// says to consolidate: *one owning component per shared resource*. This type
/// installs ONE default-device listener and ONE nominal-rate listener for the
/// whole process and fans the result out to N subscribers.
///
/// ## Watcher only — never a writer
/// This type only ever READS the HAL. It never calls
/// `AudioObjectSetPropertyData`, never pins or forces a device rate, and never
/// tears anything down on a subscriber's behalf. Owning the *observation* of the
/// shared rate is the whole job; deciding what to do about a change stays with
/// each subscriber (a tap rebuilds itself). Making this a writer would put it in
/// competition with `LocalPlaybackEngine`'s `setDeviceID`, which is a separate
/// (deliberately out-of-scope) decision.
///
/// ## Per-subscriber granularity is deliberate and load-bearing
/// The expensive, storm-prone part of a notification is the HAL work: the
/// listener registration and the live property reads. Those happen ONCE per
/// notification here. The compare-before-rebuild *decision* is pure and cheap,
/// and it is evaluated **per subscriber, against that subscriber's own tracked
/// device/rate** (``DefaultOutputTracked``, supplied by the subscriber as a
/// closure so it is always read fresh at notification time).
///
/// This is not an accident of the design — it is the property that prevents the
/// original silent-tap-dropout bug. Each tap compares the notified rate against
/// ITS OWN cached format, not against "the device's last known rate." A tap
/// whose format has drifted independently (it was built before the last
/// renegotiation, or its aggregate reconciled to a different rate) must still be
/// told, even when the device's rate looks unchanged from the monitor's point of
/// view. So the monitor deliberately does NOT gate the fan-out on its own
/// last-known snapshot; it gates each delivery on that subscriber's divergence.
/// A subscriber that has not drifted gets nothing, so the loop-breaker still
/// holds and the storm still stays broken.
///
/// ## Threading
/// One private serial queue owns all monitor state and is the queue the HAL
/// delivers both listeners on; subscriber callbacks therefore run on that queue,
/// serially, exactly like the listener blocks they replace.
/// ``subscribe(label:tracked:onChange:)``/``unsubscribe(_:)`` are safe from any
/// thread (subscriber storage has its own lock, and callbacks are invoked off
/// that lock).
public final class DefaultOutputDeviceMonitor: @unchecked Sendable {

    // MARK: - Public value types

    /// A freshly-read view of the default output device. `deviceID` is nil when
    /// the device could not be read at all; `nominalRate` is nil when the rate
    /// read failed or was degenerate. Both nils propagate into the decision
    /// helpers as "changed" (fire), per ``TapRebuildDecision``'s documented rule
    /// that a failed read is not evidence of "no change."
    public struct Snapshot: Sendable, Equatable {
        public let deviceID: AudioObjectID?
        public let nominalRate: Double?

        public init(deviceID: AudioObjectID?, nominalRate: Double?) {
            self.deviceID = deviceID
            self.nominalRate = nominalRate
        }
    }

    /// What a subscriber is currently built on — the values it wants the live
    /// reading compared against. `rate` is an `Int` to match how
    /// `TapFormat.sampleRate` is itself computed (`Int(mSampleRate.rounded())`).
    public struct Tracked: Sendable, Equatable {
        public let deviceID: AudioObjectID
        public let rate: Int

        public init(deviceID: AudioObjectID, rate: Int) {
            self.deviceID = deviceID
            self.rate = rate
        }
    }

    /// Opaque handle returned by ``subscribe(label:tracked:onChange:)``; pass to
    /// ``unsubscribe(_:)``.
    public struct SubscriptionToken: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    // MARK: - Private state (all on `queue` unless noted)

    private let hal: DefaultOutputHAL
    private let queue = DispatchQueue(label: "com.audiout.defaultoutput.monitor")

    /// How long the reading must hold still before subscribers hear about it —
    /// see ``handleNotification()`` for the measured burst this absorbs.
    private let settleWindowSeconds: TimeInterval

    /// Tags `queue` so `runOnQueue(_:)` can tell whether it's already executing
    /// there — see that method's doc for why this matters.
    private static let queueKey = DispatchSpecificKey<Void>()

    /// Run `body` on `queue`, synchronously, exactly once — WITHOUT a nested
    /// `dispatch_sync` if we're already running on `queue`.
    ///
    /// LIVE DEADLOCK (found 2026-07-26): `handleNotification()` runs ON `queue`
    /// (the HAL listener block is installed with `queue:` below) and calls a
    /// diverged subscriber's `onChange` SYNCHRONOUSLY, still on `queue`. A
    /// subscriber's `onChange` can synchronously trigger a tap rebuild whose
    /// completion resubscribes — and `subscribeToDefaultOutput` unconditionally
    /// calls `start()`, which was a bare `queue.sync { ... }`. Calling
    /// `dispatch_sync` on the queue currently executing IS a deadlock; libdispatch
    /// detects this specific case and traps immediately (`SIGTRAP`) rather than
    /// hanging, which is exactly the crash this fixes. `start()`/`stop()`/`current`
    /// all go through this so none of them can reintroduce the same trap.
    private func runOnQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }

    private struct Subscriber {
        let label: String
        let tracked: @Sendable () -> Tracked
        let onChange: @Sendable (Snapshot) -> Void
    }

    /// Subscriber storage — its own lock, because subscribe/unsubscribe arrive
    /// from arbitrary threads and must not block behind a live fan-out.
    private let subscribersLock = NSLock()
    private var subscribers: [UInt64: Subscriber] = [:]
    private var nextSubscriberID: UInt64 = 1

    private var deviceListener: DefaultOutputHALListenerToken?
    private var rateListener: DefaultOutputHALListenerToken?
    /// The device the rate listener is currently registered on — the rate
    /// property lives on the DEVICE object, so an identity change has to move it.
    private var rateListenerDeviceID: AudioObjectID?
    private var latest = Snapshot(deviceID: nil, nominalRate: nil)
    private var started = false

    /// The armed trailing-edge fan-out, replaced by every notification inside the
    /// settle window. Only ever touched on ``queue``.
    private var pendingFanout: DispatchWorkItem?

    /// Whether a notification arrived AFTER this burst's leading-edge delivery, so
    /// the trailing edge still owes subscribers the settled value. Only ever
    /// touched on ``queue``. See ``handleNotification()`` for why the fan-out is
    /// leading + trailing rather than trailing-only.
    private var settleDirty = false

    // MARK: - Lifecycle

    /// - Parameter settleWindow: how long the reading must hold still before the
    ///   fan-out runs. The 1.2s default clears the measured 0.9s Bluetooth
    ///   profile-negotiation burst with margin; pass 0 in tests.
    public init(hal: DefaultOutputHAL, settleWindow: TimeInterval = 1.2) {
        self.hal = hal
        self.settleWindowSeconds = settleWindow
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    /// Live HAL-backed monitor. Gated at 14.2 only because it reuses
    /// ``CoreAudioSystemTap``'s already-tested reads, which carry that
    /// availability; the process-tap API those reads live beside is itself
    /// 14.2+, so no supported capture path predates it.
    @available(macOS 14.2, *)
    public convenience init() {
        self.init(hal: CoreAudioDefaultOutputHAL())
    }

    deinit {
        runOnQueue { removeListeners() }
    }

    /// Take the initial reading and install the two process-wide listeners.
    /// Idempotent — including when called REENTRANTLY from a subscriber's
    /// `onChange` (see ``runOnQueue(_:)``).
    public func start() {
        runOnQueue {
            guard !started else { return }
            started = true
            latest = readLive()
            installDeviceListener()
            installRateListener(for: latest.deviceID)
            Telemetry.log(.captureWS, "default_output_monitor_started", [
                "device": latest.deviceID.map(String.init) ?? "unreadable",
                "rate": latest.nominalRate.map { String(Int($0.rounded())) } ?? "unreadable",
            ])
        }
    }

    /// Remove both listeners. Subscribers stay registered, so a later
    /// ``start()`` resumes delivering to them.
    public func stop() {
        runOnQueue {
            guard started else { return }
            started = false
            pendingFanout?.cancel()
            pendingFanout = nil
            settleDirty = false
            removeListeners()
        }
    }

    /// The most recent reading. Informational (diagnostics/telemetry) — it is
    /// deliberately NOT what the fan-out compares against; see the per-subscriber
    /// note in this type's documentation.
    public var current: Snapshot {
        runOnQueue { latest }
    }

    // MARK: - Subscription

    /// Register for default-output changes.
    ///
    /// - Parameters:
    ///   - label: identifies the subscriber in telemetry.
    ///   - tracked: read fresh at every notification — the device/rate THIS
    ///     subscriber is currently built on. Called on the monitor's queue.
    ///   - onChange: invoked on the monitor's queue only when the live reading
    ///     diverges from this subscriber's own `tracked` values.
    ///
    /// No callback fires at subscription time: a subscriber has just read the
    /// device itself in order to have something to track.
    public func subscribe(
        label: String,
        tracked: @escaping @Sendable () -> Tracked,
        onChange: @escaping @Sendable (Snapshot) -> Void
    ) -> SubscriptionToken {
        subscribersLock.lock()
        defer { subscribersLock.unlock() }
        let id = nextSubscriberID
        nextSubscriberID += 1
        subscribers[id] = Subscriber(label: label, tracked: tracked, onChange: onChange)
        return SubscriptionToken(id: id)
    }

    /// Drop a subscriber. The closures — and anything they capture — are
    /// released here, so a subscriber that unsubscribes in its own teardown
    /// leaves nothing behind.
    public func unsubscribe(_ token: SubscriptionToken) {
        subscribersLock.lock()
        defer { subscribersLock.unlock() }
        subscribers[token.id] = nil
    }

    /// Live subscriber count — for tests/diagnostics.
    var subscriberCount: Int {
        subscribersLock.lock()
        defer { subscribersLock.unlock() }
        return subscribers.count
    }

    // MARK: - Notification handling (on `queue`)

    /// One live read, then a LEADING + trailing-edge-debounced per-subscriber
    /// decision. Both listeners land here.
    ///
    /// ## Why the fan-out coalesces (F-SETTLE)
    /// Measured live: connecting a Sony WH-1000XM3 makes the HAL post FOUR rate
    /// notifications in 0.9s — 44100→16000→44100→16000 — as the macOS Bluetooth
    /// stack negotiates HFP against A2DP. It happens with no app running at all,
    /// so it is not something this process can suppress at the source. Fanning
    /// each one out synchronously cost four full tap-pipeline rebuilds per
    /// connect, and the intermediate readings are transient garbage.
    ///
    /// ## Why LEADING + trailing, not trailing-only
    /// A rate transition SILENCES a process tap the instant it happens — the tap
    /// goes all-zero on a 44.1↔48 renegotiation and only a full rebuild revives
    /// it (see ``PerAppCaptureCoordinator``'s tap-silence note). The kill is the
    /// *transition*, not the resting mismatch. So a pure trailing debounce keyed
    /// on the settled value has a hole: a burst that flaps and RETURNS to the
    /// value a subscriber is built on (48k→44k→48k) nets to "no change" and fires
    /// nothing — yet the 48→44 transition already killed the tap, leaving it
    /// silent forever. To close that, the FIRST notification of a burst delivers
    /// immediately (leading edge): whatever transition started the burst rebuilds
    /// the tap at once, and an ordinary single device switch never eats a settle
    /// window of silence either. Notifications inside the window then coalesce,
    /// and one trailing delivery reconciles to the value that actually stuck.
    ///
    /// The READ stays immediate regardless — ``current`` must never lag, and the
    /// rate listener has to follow an identity change right away or the new
    /// device's renegotiation goes unwatched.
    private func handleNotification() {
        let live = readLive()
        latest = live
        retargetRateListenerIfNeeded(to: live.deviceID)

        if pendingFanout == nil {
            // Leading edge — first notification of a (possibly one-shot) burst.
            deliverToSubscribers()
            settleDirty = false
        } else {
            // Inside the window — coalesce; the trailing edge reconciles.
            settleDirty = true
        }
        scheduleTrailingFanout()
    }

    /// Arm (or re-arm) the trailing delivery one settle window out. It fires only
    /// if a notification landed after the leading delivery (``settleDirty``), so a
    /// lone change does not double-deliver an already-settled value.
    ///
    /// razor: no max-wait cap. A burst that never settles (distinct-value
    /// notifications faster than the window, indefinitely) would starve the
    /// trailing reconcile — but the leading edge already delivered the burst's
    /// first change, and the real self-sustaining storm this codebase hit was
    /// same-value (killed by ``TapRebuildDecision``'s loop-breaker), not
    /// distinct-value. If a distinct-value storm is ever observed, cap here:
    /// deliver at most `maxWait` after the first un-reconciled notification.
    private func scheduleTrailingFanout() {
        pendingFanout?.cancel()
        var item: DispatchWorkItem!
        item = DispatchWorkItem { [weak self] in
            guard let self, !item.isCancelled else { return }
            self.pendingFanout = nil
            guard self.settleDirty else { return }
            self.settleDirty = false
            self.deliverToSubscribers()
        }
        pendingFanout = item
        queue.asyncAfter(deadline: .now() + settleWindowSeconds, execute: item)
    }

    /// The per-subscriber decision and fan-out, one settle window after the last
    /// notification. Reads ``latest`` rather than closing over the snapshot that
    /// armed it, so what lands is the value that settled — never an intermediate
    /// one from inside the burst.
    private func deliverToSubscribers() {
        let live = latest

        subscribersLock.lock()
        let snapshot = Array(subscribers.values)
        subscribersLock.unlock()

        var fired = 0
        for subscriber in snapshot {
            let tracked = subscriber.tracked()
            // Both guards are the SHARED pure decision logic — not re-derived
            // here — evaluated against this subscriber's own tracked values.
            let deviceDiverged = TapRebuildDecision.shouldRebuild(
                currentDeviceID: live.deviceID, trackedDeviceID: tracked.deviceID)
            let rateDiverged = TapRebuildDecision.shouldRebuild(
                currentRate: live.nominalRate, trackedRateInt: tracked.rate)
            guard deviceDiverged || rateDiverged else { continue }
            fired += 1
            subscriber.onChange(live)
        }

        Telemetry.log(.captureWS, "default_output_change", [
            "device": live.deviceID.map(String.init) ?? "unreadable",
            "rate": live.nominalRate.map { String(Int($0.rounded())) } ?? "unreadable",
            "subscribers": "\(snapshot.count)",
            "fired": "\(fired)",
        ])
    }

    /// Collapse the settle window NOW: if a fan-out is armed, cancel its timer
    /// and run it synchronously. Tests only.
    ///
    /// Tests construct the monitor with a settle window long enough that the
    /// real timer can never win, then call this — the same "expose the debounced
    /// entry point so tests need not wait out the timer" seam
    /// ``NativeCaptureCoordinator/handleMembershipChange()`` uses. A plain
    /// `queue.sync {}` drain would NOT work: with a zero window each
    /// notification's work item runs before the next notification's `sync` can
    /// cancel it, so nothing ever coalesces.
    internal func _drainForTesting() {
        queue.sync {
            guard let pending = pendingFanout else { return }
            pending.cancel()
            pendingFanout = nil
            // Same gate the real trailing work item applies: reconcile only if a
            // notification landed after the leading delivery.
            guard settleDirty else { return }
            settleDirty = false
            deliverToSubscribers()
        }
    }

    private func readLive() -> Snapshot {
        guard let deviceID = hal.defaultOutputDeviceID(), deviceID != kAudioObjectUnknown else {
            return Snapshot(deviceID: nil, nominalRate: nil)
        }
        return Snapshot(deviceID: deviceID, nominalRate: hal.nominalSampleRate(of: deviceID))
    }

    // MARK: - Listener plumbing (on `queue`)

    private func installDeviceListener() {
        deviceListener = hal.addListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            queue: queue
        ) { [weak self] in
            self?.handleNotification()
        }
    }

    private func installRateListener(for deviceID: AudioObjectID?) {
        guard let deviceID, deviceID != kAudioObjectUnknown else {
            rateListenerDeviceID = nil
            return
        }
        rateListener = hal.addListener(
            objectID: deviceID,
            selector: kAudioDevicePropertyNominalSampleRate,
            queue: queue
        ) { [weak self] in
            self?.handleNotification()
        }
        rateListenerDeviceID = rateListener == nil ? nil : deviceID
    }

    /// The nominal-rate property is per-device, so a genuine identity change has
    /// to move the single rate listener to the new device — otherwise the
    /// in-place 48↔44.1 renegotiation on the NEW default goes unwatched, which is
    /// the exact silent-tap case defect D names.
    private func retargetRateListenerIfNeeded(to deviceID: AudioObjectID?) {
        guard started, deviceID != rateListenerDeviceID else { return }
        if let rateListener {
            hal.removeListener(rateListener)
            self.rateListener = nil
        }
        rateListenerDeviceID = nil
        installRateListener(for: deviceID)
    }

    private func removeListeners() {
        pendingFanout?.cancel()
        pendingFanout = nil
        if let deviceListener {
            hal.removeListener(deviceListener)
            self.deviceListener = nil
        }
        if let rateListener {
            hal.removeListener(rateListener)
            self.rateListener = nil
        }
        rateListenerDeviceID = nil
    }
}

// MARK: - HAL seam

/// Opaque registration handle a ``DefaultOutputHAL`` hands back so the monitor
/// can remove exactly the listener it added.
public protocol DefaultOutputHALListenerToken: AnyObject, Sendable {}

/// The Core Audio seam ``DefaultOutputDeviceMonitor`` reads and listens through.
/// Injectable so the ownership/fan-out logic is hermetically testable with no
/// live hardware — the same pure/live split ``AudioProcessEnumerating`` uses.
public protocol DefaultOutputHAL: AnyObject, Sendable {
    /// The current default output device, or nil if unreadable.
    func defaultOutputDeviceID() -> AudioObjectID?

    /// `deviceID`'s nominal sample rate, or nil if unreadable/degenerate.
    func nominalSampleRate(of deviceID: AudioObjectID) -> Double?

    /// Install one property listener; `handler` is invoked on `queue`. Returns
    /// nil if the HAL refused the registration.
    func addListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> DefaultOutputHALListenerToken?

    func removeListener(_ token: DefaultOutputHALListenerToken)
}

/// The real HAL. Read-only: property reads plus listener add/remove, never a
/// `AudioObjectSetPropertyData`. Both reads are ``CoreAudioSystemTap``'s
/// existing, already-tested ones rather than fresh copies.
@available(macOS 14.2, *)
public final class CoreAudioDefaultOutputHAL: DefaultOutputHAL {

    /// Holds the exact block that was registered — Core Audio requires the same
    /// block object be passed to remove as to add.
    private final class Registration: DefaultOutputHALListenerToken, @unchecked Sendable {
        let objectID: AudioObjectID
        let selector: AudioObjectPropertySelector
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock

        init(objectID: AudioObjectID, selector: AudioObjectPropertySelector,
             queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) {
            self.objectID = objectID
            self.selector = selector
            self.queue = queue
            self.block = block
        }
    }

    public init() {}

    public func defaultOutputDeviceID() -> AudioObjectID? {
        guard let id = try? CoreAudioSystemTap.defaultOutputDeviceID(),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    public func nominalSampleRate(of deviceID: AudioObjectID) -> Double? {
        CoreAudioSystemTap.readNominalSampleRate(deviceID)
    }

    public func addListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> DefaultOutputHALListenerToken? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let err = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
        guard err == noErr else {
            AudioDiag.log("CoreAudioDefaultOutputHAL.addListener failed (\(selector)): \(err)")
            return nil
        }
        return Registration(objectID: objectID, selector: selector, queue: queue, block: block)
    }

    public func removeListener(_ token: DefaultOutputHALListenerToken) {
        guard let registration = token as? Registration else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: registration.selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let err = AudioObjectRemovePropertyListenerBlock(
            registration.objectID, &address, registration.queue, registration.block)
        if err != noErr {
            AudioDiag.log("CoreAudioDefaultOutputHAL.removeListener failed: \(err)")
        }
    }
}
