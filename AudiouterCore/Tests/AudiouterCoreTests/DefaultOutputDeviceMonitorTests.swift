import Foundation
import Testing
@testable import AudiouterCore

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

    // MARK: - Tests

    /// A set-to-same-value notification (Core Audio genuinely posts these) must
    /// not reach a subscriber that is already built on that rate — the storm
    /// loop-breaker.
    @Test func noFireWhenNotifiedValueIsUnchanged() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal)
        let recorder = Recorder(deviceID: 42, rate: 48_000)
        recorder.attach(to: monitor)
        monitor.start()

        hal.fire(rateSelector)
        hal.fire(deviceSelector)

        #expect(recorder.received.isEmpty)
    }

    /// A genuine in-place rate renegotiation (device identity UNCHANGED) fires —
    /// the silent-tap case the identity listener alone cannot see.
    @Test func firesOnGenuineRateChange() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal)
        let recorder = Recorder(deviceID: 42, rate: 48_000)
        recorder.attach(to: monitor)
        monitor.start()

        hal.rate = 44_100
        hal.fire(rateSelector)

        #expect(recorder.received.count == 1)
        #expect(recorder.received.first?.nominalRate == 44_100)
        #expect(recorder.received.first?.deviceID == 42)
        #expect(monitor.current.nominalRate == 44_100)
    }

    /// A device-identity change fires too, and re-targets the single rate
    /// listener onto the new device.
    @Test func firesOnDeviceChangeAndRetargetsRateListener() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal)
        let recorder = Recorder(deviceID: 42, rate: 48_000)
        recorder.attach(to: monitor)
        monitor.start()

        hal.deviceID = 99
        hal.fire(deviceSelector)

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
        let monitor = DefaultOutputDeviceMonitor(hal: hal)
        let recorder = Recorder(deviceID: 42, rate: 48_000)
        recorder.attach(to: monitor)
        monitor.start()

        hal.rate = nil
        hal.fire(rateSelector)
        #expect(recorder.received.count == 1)

        hal.deviceID = nil
        hal.fire(deviceSelector)
        #expect(recorder.received.count == 2)
        #expect(recorder.received.last?.deviceID == nil)
    }

    /// N subscribers, ONE listener installation pair — the whole point of the
    /// consolidation.
    @Test func allSubscribersNotifiedFromOneListenerInstallation() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal)
        let recorders = (0..<4).map { _ in Recorder(deviceID: 42, rate: 48_000) }
        for (index, recorder) in recorders.enumerated() { recorder.attach(to: monitor, label: "sub\(index)") }
        monitor.start()

        // One default-device listener + one nominal-rate listener, regardless of N.
        #expect(hal.addCount == 2)
        #expect(monitor.subscriberCount == 4)

        hal.rate = 44_100
        hal.fire(rateSelector)

        #expect(recorders.allSatisfy { $0.received.count == 1 })
    }

    /// Per-subscriber granularity: one subscriber's own format drifted while the
    /// device's rate reads unchanged. It must still be notified, and the
    /// subscribers that did NOT drift must still be spared.
    @Test func onlyTheSubscriberWhoseOwnFormatDriftedIsNotified() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal)
        let aligned = Recorder(deviceID: 42, rate: 48_000)
        let drifted = Recorder(deviceID: 42, rate: 44_100)
        aligned.attach(to: monitor, label: "aligned")
        drifted.attach(to: monitor, label: "drifted")
        monitor.start()

        // Device rate unchanged (48k) from the monitor's own last reading.
        hal.fire(rateSelector)

        #expect(aligned.received.isEmpty)
        #expect(drifted.received.count == 1)
    }

    /// Deregistration is clean: the subscriber stops being called and its
    /// closures (and whatever they captured) are released.
    @Test func unsubscribeStopsDeliveryAndReleasesTheSubscriber() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal)
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
        #expect(kept.received.count == 1)
    }

    /// `stop()` removes both listeners; `start()` is idempotent and does not
    /// stack registrations.
    @Test func stopRemovesBothListenersAndStartIsIdempotent() {
        let hal = FakeHAL()
        let monitor = DefaultOutputDeviceMonitor(hal: hal)
        monitor.start()
        monitor.start()
        #expect(hal.addCount == 2)

        monitor.stop()
        #expect(hal.liveListenerCount == 0)
        #expect(hal.removeCount == 2)
    }
}
