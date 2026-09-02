import Foundation
import Testing
@testable import AudioutCore

#if canImport(CoreAudio)
import CoreAudio
#endif

/// Hermetic tests for ``DefaultOutputDeviceMonitor``. Every HAL interaction goes
/// through the injected ``DefaultOutputHAL`` seam — no live Core Audio, no real
/// device, no audio played. The fake fires listener handlers on the very queue
/// the monitor handed it (the real HAL's contract), so a `fire()` returns only
/// once the monitor has finished handling the notification.
@Suite struct DefaultOutputDeviceMonitorTests {

    // MARK: - Fake HAL

    private final class FakeHAL: DefaultOutputHAL, @unchecked Sendable {

        private final class Token: DefaultOutputHALListenerToken, @unchecked Sendable {
            let objectID: AudioObjectID
            let selector: AudioObjectPropertySelector
            let queue: DispatchQueue
            let handler: @Sendable () -> Void
            init(objectID: AudioObjectID, selector: AudioObjectPropertySelector,
                 queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
                self.objectID = objectID
                self.selector = selector
                self.queue = queue
                self.handler = handler
            }
        }

        private let lock = NSLock()
        private var _deviceID: AudioObjectID? = 42
        private var _rate: Double? = 48_000
        private var tokens: [ObjectIdentifier: Token] = [:]
        private var _addCount = 0
        private var _removeCount = 0

        var deviceID: AudioObjectID? {
            get { lock.withLock { _deviceID } }
            set { lock.withLock { _deviceID = newValue } }
        }

        var rate: Double? {
            get { lock.withLock { _rate } }
            set { lock.withLock { _rate = newValue } }
        }

        var addCount: Int { lock.withLock { _addCount } }
        var removeCount: Int { lock.withLock { _removeCount } }
        var liveListenerCount: Int { lock.withLock { tokens.count } }

        func defaultOutputDeviceID() -> AudioObjectID? { deviceID }

        func nominalSampleRate(of deviceID: AudioObjectID) -> Double? { rate }

        func addListener(
            objectID: AudioObjectID,
            selector: AudioObjectPropertySelector,
            queue: DispatchQueue,
            handler: @escaping @Sendable () -> Void
        ) -> DefaultOutputHALListenerToken? {
            let token = Token(objectID: objectID, selector: selector, queue: queue, handler: handler)
            lock.withLock {
                _addCount += 1
                tokens[ObjectIdentifier(token)] = token
            }
            return token
        }

        func removeListener(_ token: DefaultOutputHALListenerToken) {
            lock.withLock {
                _removeCount += 1
                tokens[ObjectIdentifier(token as AnyObject)] = nil
            }
        }

        /// Post the listener for `selector`, synchronously on the monitor's own
        /// queue — same delivery contract the real HAL has.
        func fire(_ selector: AudioObjectPropertySelector) {
            let matching = lock.withLock { tokens.values.filter { $0.selector == selector } }
            for token in matching {
                token.queue.sync { token.handler() }
            }
        }
    }

    // MARK: - Helpers

    /// A subscriber recorder: reports a fixed tracked device/rate (mutable, so a
    /// test can drift ONE subscriber independently) and records deliveries.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _tracked: DefaultOutputDeviceMonitor.Tracked
        private var _received: [DefaultOutputDeviceMonitor.Snapshot] = []

        init(deviceID: AudioObjectID = 42, rate: Int = 48_000) {
            _tracked = .init(deviceID: deviceID, rate: rate)
        }

        var tracked: DefaultOutputDeviceMonitor.Tracked {
            get { lock.withLock { _tracked } }
            set { lock.withLock { _tracked = newValue } }
        }

        var received: [DefaultOutputDeviceMonitor.Snapshot] { lock.withLock { _received } }

        func record(_ snapshot: DefaultOutputDeviceMonitor.Snapshot) {
            lock.withLock { _received.append(snapshot) }
        }

        @discardableResult
        func attach(to monitor: DefaultOutputDeviceMonitor, label: String = "test")
            -> DefaultOutputDeviceMonitor.SubscriptionToken {
            monitor.subscribe(label: label, tracked: { self.tracked }, onChange: { self.record($0) })
        }
    }

    private let rateSelector = kAudioDevicePropertyNominalSampleRate
    private let deviceSelector = kAudioHardwarePropertyDefaultOutputDevice

    /// A settle window the real timer can never win inside a test, so fan-out
    /// happens only where a test asks for it via `_drainForTesting()`. Zero would
    /// be worse than useless: each notification's work item would run before the
    /// next notification could cancel it, and nothing would ever coalesce.
    private let testSettleWindow: TimeInterval = 60

    // MARK: - Tests

    /// A set-to-same-value notification (Core Audio genuinely posts these) must
    /// not reach a subscriber that is already built on that rate — the storm
    /// loop-breaker.
    @Test func noFireWhenNotifiedValueIsUnchanged() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        let recorder = Recorder(deviceID: 42, rate: 48_000)
        recorder.attach(to: monitor)
        monitor.start()

        hal.fire(rateSelector)
        hal.fire(deviceSelector)
        monitor._drainForTesting()

        #expect(recorder.received.isEmpty)
    }

    /// A genuine in-place rate renegotiation (device identity UNCHANGED) fires —
    /// the silent-tap case the identity listener alone cannot see.
    @Test func firesOnGenuineRateChange() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        let recorder = Recorder(deviceID: 42, rate: 48_000)
        recorder.attach(to: monitor)
        monitor.start()

        hal.rate = 44_100
        hal.fire(rateSelector)
        monitor._drainForTesting()

        #expect(recorder.received.count == 1)
        #expect(recorder.received.first?.nominalRate == 44_100)
        #expect(recorder.received.first?.deviceID == 42)
        #expect(monitor.current.nominalRate == 44_100)
    }

    /// A device-identity change fires too, and re-targets the single rate
    /// listener onto the new device.
    @Test func firesOnDeviceChangeAndRetargetsRateListener() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        let recorder = Recorder(deviceID: 42, rate: 48_000)
        recorder.attach(to: monitor)
        monitor.start()

        hal.deviceID = 99
        hal.fire(deviceSelector)
        monitor._drainForTesting()

        #expect(recorder.received.count == 1)
        #expect(recorder.received.first?.deviceID == 99)
        // Still exactly two live listeners: the rate one moved, it did not multiply.
        #expect(hal.liveListenerCount == 2)
        #expect(hal.removeCount == 1)
    }

    /// An unreadable read is not evidence of "no change" — it must fire, per
    /// ``TapRebuildDecision``'s documented rule.
    @Test func firesWhenReadIsUnreadable() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        let recorder = Recorder(deviceID: 42, rate: 48_000)
        recorder.attach(to: monitor)
        monitor.start()

        hal.rate = nil
        hal.fire(rateSelector)
        monitor._drainForTesting()
        #expect(recorder.received.count == 1)

        hal.deviceID = nil
        hal.fire(deviceSelector)
        monitor._drainForTesting()
        #expect(recorder.received.count == 2)
        #expect(recorder.received.last?.deviceID == nil)
    }

    /// N subscribers, ONE listener installation pair — the whole point of the
    /// consolidation.
    @Test func allSubscribersNotifiedFromOneListenerInstallation() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        let recorders = (0..<4).map { _ in Recorder(deviceID: 42, rate: 48_000) }
        for (index, recorder) in recorders.enumerated() { recorder.attach(to: monitor, label: "sub\(index)") }
        monitor.start()

        // One default-device listener + one nominal-rate listener, regardless of N.
        #expect(hal.addCount == 2)
        #expect(monitor.subscriberCount == 4)

        hal.rate = 44_100
        hal.fire(rateSelector)
        monitor._drainForTesting()

        #expect(recorders.allSatisfy { $0.received.count == 1 })
    }

    /// Per-subscriber granularity: one subscriber's own format drifted while the
    /// device's rate reads unchanged. It must still be notified, and the
    /// subscribers that did NOT drift must still be spared.
    @Test func onlyTheSubscriberWhoseOwnFormatDriftedIsNotified() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        let aligned = Recorder(deviceID: 42, rate: 48_000)
        let drifted = Recorder(deviceID: 42, rate: 44_100)
        aligned.attach(to: monitor, label: "aligned")
        drifted.attach(to: monitor, label: "drifted")
        monitor.start()

        // Device rate unchanged (48k) from the monitor's own last reading.
        hal.fire(rateSelector)
        monitor._drainForTesting()

        #expect(aligned.received.isEmpty)
        #expect(drifted.received.count == 1)
    }

    /// Deregistration is clean: the subscriber stops being called and its
    /// closures (and whatever they captured) are released.
    @Test func unsubscribeStopsDeliveryAndReleasesTheSubscriber() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        let kept = Recorder(deviceID: 42, rate: 48_000)
        kept.attach(to: monitor, label: "kept")

        weak var weakDropped: Recorder?
        var token: DefaultOutputDeviceMonitor.SubscriptionToken?
        do {
            let dropped = Recorder(deviceID: 42, rate: 48_000)
            weakDropped = dropped
            token = dropped.attach(to: monitor, label: "dropped")
        }
        #expect(weakDropped != nil, "still retained by the monitor's subscriber closure")

        monitor.start()
        monitor.unsubscribe(token!)

        #expect(monitor.subscriberCount == 1)
        #expect(weakDropped == nil, "unsubscribe must release the subscriber's closures")

        hal.rate = 44_100
        hal.fire(rateSelector)
        monitor._drainForTesting()
        #expect(kept.received.count == 1)
    }

    /// `stop()` removes both listeners; `start()` is idempotent and does not
    /// stack registrations.
    @Test func stopRemovesBothListenersAndStartIsIdempotent() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        monitor.start()
        monitor.start()
        #expect(hal.addCount == 2)

        monitor.stop()
        #expect(hal.liveListenerCount == 0)
        #expect(hal.removeCount == 2)
    }

    /// LIVE CRASH (2026-07-26): a real subscriber's `onChange` (a tap rebuild)
    /// resubscribes, and resubscribing unconditionally calls `start()`.
    /// `handleNotification()` — which calls `onChange` — runs ON `queue` (the
    /// fake fires listener handlers on the queue it was handed, matching the
    /// real HAL's contract per this file's header doc), so `start()` here is
    /// REENTRANT: called from a stack already executing on `queue`. Before the
    /// fix this deadlocked `queue.sync` onto itself — which libdispatch detects
    /// and traps on, rather than hanging. This test simply must return.
    @Test func startCalledReentrantlyFromOnChangeDoesNotDeadlock() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        let recorder = Recorder(deviceID: 42, rate: 48_000)
        _ = monitor.subscribe(
            label: "reentrant",
            tracked: { recorder.tracked },
            onChange: { snapshot in
                recorder.record(snapshot)
                monitor.start()  // the exact call subscribeToDefaultOutput makes
            })
        monitor.start()

        hal.deviceID = 99
        hal.fire(deviceSelector)  // must return, not deadlock/trap
        monitor._drainForTesting()

        #expect(recorder.received.count == 1)
        #expect(monitor.current.deviceID == 99)
    }

    // MARK: - Settle window (F-SETTLE)

    /// The BT headset burst collapses to at most TWO deliveries, never
    /// one-per-notification: the first reading above 16 kHz lands at once (the
    /// 16k that opens the burst is a hands-free marker and is held), plus one
    /// trailing reconcile of the settled value. (The Recorder's tracked rate is
    /// fixed at 48k, so both the immediate and the settled reading diverge and
    /// record.)
    @Test func rapidFlapsCollapseToLeadingPlusOneTrailing() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        let recorder = Recorder(deviceID: 42, rate: 48_000)
        recorder.attach(to: monitor)
        monitor.start()

        // Four rapid fires — like the WH-1000XM3 connect sequence.
        hal.rate = 16_000; hal.fire(rateSelector)   // hands-free marker: held, not delivered
        hal.rate = 44_100; hal.fire(rateSelector)   // first reading above 16k: delivers now
        hal.rate = 16_000; hal.fire(rateSelector)   // coalesced
        hal.rate = 44_100; hal.fire(rateSelector)   // coalesced

        // The immediate delivery already landed before any drain, and it is 44.1k.
        #expect(recorder.received.count == 1)
        #expect(recorder.received.first?.nominalRate == 44_100)

        monitor._drainForTesting()

        // Four fires, exactly two deliveries — not four.
        #expect(recorder.received.count == 2)
        #expect(recorder.received.last?.nominalRate == 44_100)
    }

    /// A single isolated change delivers on the LEADING edge — immediately, with
    /// no settle-window wait — so an ordinary device switch never eats a window
    /// of silence, and the trailing edge does not double-deliver it.
    @Test func singleChangeDeliversImmediatelyWithoutWaitingOutTheWindow() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        let recorder = Recorder(deviceID: 42, rate: 48_000)
        recorder.attach(to: monitor)
        monitor.start()

        hal.rate = 44_100
        hal.fire(rateSelector)
        // Delivered already — before any drain, without the 60s window elapsing.
        #expect(recorder.received.count == 1)
        #expect(recorder.received.first?.nominalRate == 44_100)

        monitor._drainForTesting()
        // The trailing reconcile does not re-fire an already-settled value.
        #expect(recorder.received.count == 1)
    }

    /// DEFECT 1 (F-SETTLE review): a rate that flaps and RETURNS to the value a
    /// subscriber is built on (48k→44k→48k) nets to no change — but the 48→44
    /// transition really silenced the tap. A net-value trailing debounce would
    /// deliver nothing and leave it silent forever; the leading edge fires on the
    /// 48→44 transition, so the tap is rebuilt regardless of where the burst ends.
    @Test func flapReturningToTrackedValueStillDeliversViaLeadingEdge() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        let recorder = Recorder(deviceID: 42, rate: 48_000)
        recorder.attach(to: monitor)
        monitor.start()

        hal.rate = 44_100; hal.fire(rateSelector)   // leading: transition off 48k
        hal.rate = 48_000; hal.fire(rateSelector)   // returns to the tracked value
        monitor._drainForTesting()

        // The leading delivery landed — the tap is not left silent. The trailing
        // net value equals the tracked 48k, so no redundant second rebuild.
        #expect(recorder.received.count == 1)
        #expect(recorder.received.first?.nominalRate == 44_100)
    }

    /// `stop()` inside the window cancels the pending TRAILING reconcile — the
    /// leading delivery already ran, but the reconcile must not fire after stop.
    @Test func stopCancelsPendingTrailingDelivery() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        let recorder = Recorder(deviceID: 42, rate: 48_000)
        recorder.attach(to: monitor)
        monitor.start()

        hal.rate = 44_100; hal.fire(rateSelector)   // leading delivery (count 1)
        hal.rate = 16_000; hal.fire(rateSelector)   // arms a trailing reconcile
        #expect(recorder.received.count == 1)

        monitor.stop()                              // cancels the trailing
        monitor._drainForTesting()
        #expect(recorder.received.count == 1)       // trailing never ran
    }

    /// A 16k reading (a headset entering hands-free mode) that returns above 16k
    /// inside the window is withheld, but the RETURN still rebuilds — exactly once.
    ///
    /// The 16k transition has already silenced every tap by the time it is read,
    /// and holding it means no subscriber ever tracked it, so the return diverges
    /// from nothing. Left to the divergence check the flip would fire nothing and
    /// the taps would stay silent for good. The hold's job is to collapse the four
    /// rebuilds a connect burst would otherwise buy down to one, not to zero.
    @Test func lowRateFlapReturningInsideWindowRebuildsOnceOnTheReturn() {
        let hal = FakeHAL()
        hal.rate = 44_100
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        let recorder = Recorder(deviceID: 42, rate: 44_100)
        recorder.attach(to: monitor)
        monitor.start()

        hal.rate = 16_000; hal.fire(rateSelector)
        #expect(recorder.received.isEmpty, "the hands-free dip itself is withheld")
        hal.rate = 44_100; hal.fire(rateSelector)
        #expect(recorder.received.count == 1,
                "the return rebuilds the taps the dip silenced")
        #expect(recorder.received.last?.nominalRate == 44_100)

        monitor._drainForTesting()
        #expect(recorder.received.count == 1, "the trailing edge adds no second rebuild")
        #expect(monitor.current.nominalRate == 44_100)
    }

    /// A 16k reading that outlasts the window is delivered on the trailing edge,
    /// so a genuinely sustained hands-free device is still adopted.
    @Test func sustainedLowRateIsDeliveredOnTheTrailingEdge() {
        let hal = FakeHAL()
        hal.rate = 44_100
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        let recorder = Recorder(deviceID: 42, rate: 44_100)
        recorder.attach(to: monitor)
        monitor.start()

        hal.rate = 16_000; hal.fire(rateSelector); hal.fire(rateSelector)  // second fire: duplicate reading
        #expect(recorder.received.isEmpty)

        monitor._drainForTesting()
        #expect(recorder.received.count == 1)
        #expect(recorder.received.first?.nominalRate == 16_000)
    }

    /// A device-identity change inside a held window is delivered at once, so a
    /// headset disconnect lands on the new default without a 16k rebuild first.
    @Test func deviceChangeDuringHeldLowRateDeliversImmediately() {
        let hal = FakeHAL()
        hal.rate = 44_100
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        let recorder = Recorder(deviceID: 42, rate: 44_100)
        recorder.attach(to: monitor)
        monitor.start()

        hal.rate = 16_000; hal.fire(rateSelector)
        #expect(recorder.received.isEmpty)

        hal.deviceID = 99; hal.fire(deviceSelector)
        #expect(recorder.received.count == 1)
        #expect(recorder.received.first?.deviceID == 99)

        monitor._drainForTesting()
        #expect(recorder.received.count == 1)
    }

    /// Leaving hands-free mode (16k back to 44.1k) is an ordinary rate change and
    /// delivers on the leading edge; only the drop INTO 16k is held.
    @Test func rateRiseOffLowRateDeliversImmediately() {
        let hal = FakeHAL()
        hal.rate = 16_000
        let monitor = DefaultOutputDeviceMonitor(hal: hal, settleWindow: testSettleWindow)
        let recorder = Recorder(deviceID: 42, rate: 16_000)
        recorder.attach(to: monitor)
        monitor.start()

        hal.rate = 44_100; hal.fire(rateSelector)
        #expect(recorder.received.count == 1)
        #expect(recorder.received.first?.nominalRate == 44_100)
    }
}
