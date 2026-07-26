// SPDX-License-Identifier: GPL-2.0-or-later

import CoreAudio
import Foundation

/// The single process-wide owner of the Mac's default output device identity
/// (`kAudioHardwarePropertyDefaultOutputDevice`) and that device's nominal
/// sample rate (`kAudioDevicePropertyNominalSampleRate`).
///
/// ## Why this exists (architecture review 2026-07-26, defect D)
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
    private let queue = DispatchQueue(label: "com.audiouter.defaultoutput.monitor")

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

    // MARK: - Lifecycle

    public init(hal: DefaultOutputHAL) {
        self.hal = hal
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

    /// One live read, then a per-subscriber decision. Both listeners land here.
    private func handleNotification() {
        let live = readLive()
        latest = live
        retargetRateListenerIfNeeded(to: live.deviceID)

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
