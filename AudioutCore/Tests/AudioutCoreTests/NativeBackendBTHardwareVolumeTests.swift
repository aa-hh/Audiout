import Foundation
import Testing
import AirPlayEngine
@testable import AudioutCore

#if canImport(CoreAudio)
import CoreAudio
#endif

/// BT-HW-VOL: a supported Bluetooth speaker's per-device slider writes the
/// speaker's OWN volume, its device term leaves the software gain product,
/// and the speaker's buttons move the row. Hermetic: a scripted
/// ``BTHardwareVolumeControlling`` fake stands in for the HAL; every other
/// collaborator is the same per-suite double the sibling BT suites keep.
@Suite final class NativeBackendBTHardwareVolumeTests: IsolatedSuite {

    // MARK: Doubles

    private final class FakeBTHardwareVolume: BTHardwareVolumeControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _controllable = true
        private var _readLevel: Int? = 42
        private var _writeSucceeds = true
        private var _writes: [(level: Int, uid: String)] = []
        private var _watches: [String: @Sendable (Int) -> Void] = [:]
        private var _unwatched: [String] = []

        var controllable: Bool {
            get { lock.withLock { _controllable } }
            set { lock.withLock { _controllable = newValue } }
        }
        var readLevel: Int? {
            get { lock.withLock { _readLevel } }
            set { lock.withLock { _readLevel = newValue } }
        }
        var writeSucceeds: Bool {
            get { lock.withLock { _writeSucceeds } }
            set { lock.withLock { _writeSucceeds = newValue } }
        }
        var writes: [(level: Int, uid: String)] { lock.withLock { _writes } }
        var unwatched: [String] { lock.withLock { _unwatched } }
        func hasWatch(_ uid: String) -> Bool { lock.withLock { _watches[uid] != nil } }

        func isControllable(_ deviceID: AudioObjectID) -> Bool { controllable }
        func read(_ deviceID: AudioObjectID) -> Int? { readLevel }
        func write(_ uiLevel: Int, to deviceID: AudioObjectID, uid: String) -> Bool {
            lock.withLock { _writes.append((uiLevel, uid)); return _writeSucceeds }
        }
        func watch(deviceID: AudioObjectID, uid: String,
                   onChange: @escaping @Sendable (Int) -> Void) {
            lock.withLock { _watches[uid] = onChange }
        }
        func unwatch(uid: String) {
            lock.withLock { _watches[uid] = nil; _unwatched.append(uid) }
        }
        /// The speaker's own buttons.
        func fireExternal(_ uid: String, _ level: Int) {
            let handler = lock.withLock { _watches[uid] }
            handler?(level)
        }
    }

    private final class FakeBTEnumerator: BTDeviceEnumerating, @unchecked Sendable {
        private let lock = NSLock()
        private var _onSnapshot: (@Sendable ([BTDeviceSnapshot]) -> Void)?
        var onSnapshot: (@Sendable ([BTDeviceSnapshot]) -> Void)? {
            get { lock.withLock { _onSnapshot } }
            set { lock.withLock { _onSnapshot = newValue } }
        }
        func start() {}
        func stop() {}
        func refresh() {}
        func requestAuthorizationForUserAction() {}
        func fire(_ snapshots: [BTDeviceSnapshot]) { onSnapshot?(snapshots) }
    }

    private final class NoOpEngine: EngineControlling, @unchecked Sendable {
        func start() async throws {}
        func stop() async {}
        func updateDiscovery(_ descriptor: DeviceDescriptor) async throws -> OutputID {
            OutputID(rawValue: 0)
        }
        func removeDiscovery(_ descriptor: DeviceDescriptor) async {}
        func addOutput(_ id: OutputID) async throws {}
        func addOutput(_ id: OutputID, streamId: UInt32) async throws {}
        func removeOutput(_ id: OutputID) async throws {}
        func setVolume(_ id: OutputID, _ volume: Double) async throws {}
        func setStartBufferMs(_ ms: Int) async {}
        func write(pcm: Data, streamId: UInt32, pts: timespec) {}
        func makeStateStream() -> AsyncStream<(OutputID, OutputState)> { AsyncStream { _ in } }
        func makeRemoteEventStream() -> AsyncStream<RemoteEvent> { AsyncStream { _ in } }
        var dacpID: UInt64 { 0 }
        var ptpClockAvailable: Bool { get async { true } }
    }

    private final class NoOpDiscovery: DiscoverySource, @unchecked Sendable {
        var onEvent: (@Sendable (DiscoveryEvent) -> Void)?
        func start() {}
        func stop() {}
    }

    private final class FakeDACPEndpoint: DACPEndpoint, @unchecked Sendable {
        var onVolume: (@Sendable (_ activeRemote: UInt32, _ level: Double) -> Void)?
        var onVolumeStep: (@Sendable (_ activeRemote: UInt32, _ direction: Int) -> Void)?
        func start(dacpID: UInt64) {}
        func stop() {}
    }

    private final class NoOpSystemVolume: SystemVolumeControlling, @unchecked Sendable {
        var onExternalChange: (@Sendable (Int?, Bool?, Bool) -> Void)?
        func currentVolume() -> Int? { nil }
        func currentMuted() -> Bool? { nil }
        func setVolume(_ volume: Int, didWrite: (@Sendable (Bool) -> Void)?) { didWrite?(true) }
        func setMuted(_ muted: Bool) {}
        func setVolume(_ volume: Int, resolvingTarget: @escaping @Sendable () -> AudioObjectID?,
                       didWrite: (@Sendable (Bool) -> Void)?) {
            _ = resolvingTarget()
            didWrite?(true)
        }
        func setMuted(_ muted: Bool, resolvingTarget: @escaping @Sendable () -> AudioObjectID?) {
            _ = resolvingTarget()
        }
        func start() {}
        func stop() {}
    }

    private struct NoOpAggregateControl: AggregateDeviceControlling {
        func resolveDeviceID(forUID uid: String) -> AudioObjectID? { nil }
        func createAggregate(uid: String, name: String, subDeviceUID: String) -> AudioObjectID? { nil }
        func destroyAggregate(_ deviceID: AudioObjectID) -> Bool { false }
        func aggregateDeviceUIDs() -> [String] { [] }
        func deviceUID(_ deviceID: AudioObjectID) -> String? { nil }
        func builtInOutputDeviceUID() -> String? { nil }
        func setDefaultOutputDevice(_ deviceID: AudioObjectID) -> Bool { false }
    }

    /// Gain-recording subset of the sibling suites' `SpyBTSink`.
    private final class SpyBTSink: BTSyncedSinkControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private var _gains: [(gain: Float, uid: String)] = []
        func start() { lock.withLock { _calls.append("start") } }
        func stop() { lock.withLock { _calls.append("stop") } }
        func setDevices(_ specs: [BTSyncedSink.DeviceSpec]) { lock.withLock { _calls.append("setDevices") } }
        func setComposition(_ composition: BTGroupComposition) { lock.withLock { _calls.append("setComposition") } }
        func setTrimMs(_ ms: Double, forDeviceUID uid: String) {}
        func setGain(_ gain: Float, forDeviceUID uid: String) {
            lock.withLock { _calls.append("setGain"); _gains.append((gain: gain, uid: uid)) }
        }
        func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {}
        func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec,
                     forDeviceUIDs uids: [String]) {}
        func setPerAppClaimedUIDs(_ uids: Set<String>) {}
        func renderingDeviceUIDs() -> Set<String> { [] }
        func anchoredDeviceUIDs() -> Set<String>? { nil }
        var calls: [String] { lock.withLock { _calls } }
        func lastGain(for uid: String) -> Float? {
            lock.withLock { _gains.last { $0.uid == uid }?.gain }
        }
    }

    // MARK: Helpers

    private func makeBackend(hardware: FakeBTHardwareVolume,
                             store: BTHardwareVolumeStore? = nil,
                             sdpClaim: (@Sendable (String) -> Bool?)? = nil)
        -> (NativeBackend, FakeBTEnumerator, SpyBTSink) {
        let bt = FakeBTEnumerator()
        let backend = NativeBackend(
            engineControl: NoOpEngine(),
            discoverySource: NoOpDiscovery(),
            btEnumerator: bt,
            btHardwareVolumeStore: store,
            btHardwareVolumeControl: hardware,
            btAbsoluteVolumeClaim: sdpClaim,
            dacpEndpoint: FakeDACPEndpoint(),
            systemVolume: NoOpSystemVolume(),
            aggregateControl: NoOpAggregateControl())
        let sink = SpyBTSink()
        backend.btSyncedSinkFactory = { sink }
        backend.btDeviceIDForUID = { _ in AudioObjectID(777) }
        return (backend, bt, sink)
    }

    private func waitFor(timeout: TimeInterval? = nil,
                         sourceLocation: SourceLocation = #_sourceLocation,
                         _ cond: @escaping () -> Bool) {
        SuiteWait.untilOnRunLoop(timeout: timeout, sourceLocation: sourceLocation, cond)
    }

    private func device(_ backend: NativeBackend, _ id: String) -> Device? {
        backend.devices.first { $0.id == id }
    }

    /// Locked call counter for the `sdpClaim` seam in ``sdpVerdictIsCachedPerDevice``.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private let speaker = BTDeviceSnapshot(
        id: "C4-38-75-0E-BF-4A:output", name: "Move 2", isConnected: true)

    /// Connected speaker folded in, hardware control decided, watch armed.
    private func connect(_ backend: NativeBackend, _ bt: FakeBTEnumerator,
                         _ hardware: FakeBTHardwareVolume,
                         sourceLocation: SourceLocation = #_sourceLocation) {
        backend.start()
        bt.fire([speaker])
        waitFor(sourceLocation: sourceLocation) { hardware.hasWatch(self.speaker.id) }
    }

    // MARK: Tests

    /// Entering control ADOPTS the speaker's current level. The defect this
    /// pins: pushing the app's stored level on connect blasts a speaker
    /// someone turned down physically — the first sync must be a read.
    @Test func enteringControlAdoptsTheSpeakersLevel() {
        let hardware = FakeBTHardwareVolume()
        hardware.readLevel = 42
        let (backend, bt, _) = makeBackend(hardware: hardware)
        defer { backend.stop() }
        connect(backend, bt, hardware)

        waitFor { self.device(backend, self.speaker.id)?.volume == 42 }
        #expect(hardware.writes.isEmpty, "the first sync is a read, never a write")
        #expect(device(backend, speaker.id)?.btHardwareVolumeCapable == true,
                "the row publishes capability so the detail pane can offer the toggle")
    }

    /// A slider drag writes the speaker's own volume, and the sink's software
    /// gain keeps carrying Main ALONE. The defect this pins: composing the
    /// device term in software too would attenuate twice — 30% on the wire
    /// times 30% at the speaker.
    @Test func dragWritesHardwareAndTheDeviceTermLeavesTheSinkGain() {
        let hardware = FakeBTHardwareVolume()
        let (backend, bt, sink) = makeBackend(hardware: hardware)
        defer { backend.stop() }
        connect(backend, bt, hardware)
        backend.setOutputSet([speaker.id])
        waitFor { sink.calls.contains("start") }

        backend.setVolume(30, for: speaker.id)
        waitFor { hardware.writes.contains { $0.level == 30 && $0.uid == self.speaker.id } }
        #expect(device(backend, speaker.id)?.volume == 30)
        #expect(sink.lastGain(for: speaker.id) == 1.0,
                "the software product must carry Main alone — the speaker holds the device term")
    }

    /// A failed hardware write drops the uid to software gain for the session
    /// and re-pushes the level it was owed. The defect this pins: a device
    /// that advertises the property but does not deliver (the recorded vmvc
    /// trap) would otherwise be left with a slider that moves nothing.
    @Test func failedWriteFallsBackToSoftwareGain() {
        let hardware = FakeBTHardwareVolume()
        hardware.writeSucceeds = false
        let (backend, bt, sink) = makeBackend(hardware: hardware)
        defer { backend.stop() }
        connect(backend, bt, hardware)
        backend.setOutputSet([speaker.id])
        waitFor { sink.calls.contains("start") }

        backend.setVolume(30, for: speaker.id)
        waitFor { hardware.unwatched.contains(self.speaker.id) }
        waitFor { sink.lastGain(for: self.speaker.id) == 0.3 }
        #expect(device(backend, speaker.id)?.volume == 30,
                "the drag that exposed the fault still lands, in software")
    }

    /// The speaker's own buttons move the row. The defect this pins: writing
    /// hardware while ignoring device-side changes leaves the slider lying
    /// within minutes of real use.
    @Test func speakerButtonsMoveTheRow() {
        let hardware = FakeBTHardwareVolume()
        let (backend, bt, _) = makeBackend(hardware: hardware)
        defer { backend.stop() }
        connect(backend, bt, hardware)

        hardware.fireExternal(speaker.id, 55)
        waitFor { self.device(backend, self.speaker.id)?.volume == 55 }
    }

    /// While muted (software 0), a device-side change lands in the mute stash;
    /// unmute restores it and settles hardware on it. The defect this pins:
    /// dropping button presses made under mute means unmute snaps the speaker
    /// back to a level the user already moved away from.
    @Test func externalChangeWhileMutedLandsInTheStash() {
        let hardware = FakeBTHardwareVolume()
        let (backend, bt, _) = makeBackend(hardware: hardware)
        defer { backend.stop() }
        connect(backend, bt, hardware)

        backend.setMuted(true, for: speaker.id)
        waitFor { self.device(backend, self.speaker.id)?.isMuted == true }
        hardware.fireExternal(speaker.id, 60)
        backend.setMuted(false, for: speaker.id)
        waitFor { self.device(backend, self.speaker.id)?.volume == 60 }
        waitFor { hardware.writes.contains { $0.level == 60 && $0.uid == self.speaker.id } }
    }

    /// A speaker whose volume property is not settable never enters hardware
    /// control: no first-sync read is applied and drags stay software. The
    /// defect this pins: writing the HAL volume of a device that lacks the
    /// control fails every drag.
    @Test func nonControllableSpeakerStaysOnSoftwareGain() {
        let hardware = FakeBTHardwareVolume()
        hardware.controllable = false
        let (backend, bt, _) = makeBackend(hardware: hardware)
        defer { backend.stop() }
        backend.start()
        bt.fire([speaker])
        waitFor { self.device(backend, self.speaker.id) != nil }

        backend.setVolume(30, for: speaker.id)
        waitFor { self.device(backend, self.speaker.id)?.volume == 30 }
        #expect(hardware.writes.isEmpty)
        #expect(!hardware.hasWatch(speaker.id))
        #expect(device(backend, speaker.id)?.btHardwareVolumeCapable == false,
                "a checked-and-unsupported speaker must read false, so the pane drops the toggle")
    }

    /// A disconnect drops the watch and hardware control; drags on the greyed
    /// row stay software. The defect this pins: a write aimed at a stale
    /// AudioObjectID after a disconnect/rejoin hits the wrong (or no) device.
    @Test func disconnectDropsHardwareControl() {
        let hardware = FakeBTHardwareVolume()
        let (backend, bt, _) = makeBackend(hardware: hardware)
        defer { backend.stop() }
        connect(backend, bt, hardware)

        bt.fire([BTDeviceSnapshot(id: speaker.id, name: speaker.name, isConnected: false)])
        waitFor { hardware.unwatched.contains(self.speaker.id) }

        let writesBefore = hardware.writes.count
        backend.setVolume(25, for: speaker.id)
        waitFor { self.device(backend, self.speaker.id)?.volume == 25 }
        #expect(hardware.writes.count == writesBefore)
    }

    /// A category-2 SDP denial blocks hardware control even though the
    /// property reads settable. The defect this pins: trusting "settable"
    /// alone admits devices whose settable HAL property is a driver's
    /// software-shim volume, not a real hardware fader.
    @Test func sdpCategoryTwoDeniedBlocksHardwareControl() {
        let hardware = FakeBTHardwareVolume()
        hardware.controllable = true
        let (backend, bt, sink) = makeBackend(hardware: hardware, sdpClaim: { _ in false })
        defer { backend.stop() }
        backend.start()
        bt.fire([speaker])
        waitFor { self.device(backend, self.speaker.id)?.btHardwareVolumeCapable == false }

        backend.setOutputSet([speaker.id])
        waitFor { sink.calls.contains("start") }
        backend.setVolume(30, for: speaker.id)
        waitFor { hardware.unwatched.contains(self.speaker.id) }
        waitFor { sink.lastGain(for: self.speaker.id) == 0.3 }
        #expect(device(backend, speaker.id)?.volume == 30)
        #expect(hardware.writes.isEmpty, "a denied claim must never reach the HAL write")
    }

    /// A missing SDP record (`nil`) falls back to the settable-only gate
    /// instead of blocking. The defect this pins: making the SDP read a hard
    /// dependency would block every speaker whose SDP cache is empty, even
    /// ones a real hardware fader.
    @Test func missingSDPRecordFallsBackToSettableGate() {
        let hardware = FakeBTHardwareVolume()
        let (backend, bt, _) = makeBackend(hardware: hardware, sdpClaim: { _ in nil })
        defer { backend.stop() }
        connect(backend, bt, hardware)

        waitFor { self.device(backend, self.speaker.id)?.btHardwareVolumeCapable == true }
        backend.setVolume(30, for: speaker.id)
        waitFor { hardware.writes.contains { $0.level == 30 && $0.uid == self.speaker.id } }
    }

    /// A reconnect reads the cached SDP verdict, not a fresh probe. The
    /// defect this pins: re-reading SDP on every reconnect turns each link
    /// session into an IOBluetooth round trip for a verdict already known.
    @Test func sdpVerdictIsCachedPerDevice() {
        let callCount = CallCounter()
        let hardware = FakeBTHardwareVolume()
        let (backend, bt, _) = makeBackend(hardware: hardware, sdpClaim: { _ in
            callCount.increment()
            return true
        })
        defer { backend.stop() }
        connect(backend, bt, hardware)
        waitFor { hardware.hasWatch(self.speaker.id) }
        waitFor { callCount.value == 1 }
        SuiteWait.settle(0.3)  // let the verdict land in the cache

        // Disconnect clears the probed marker, so only the cache can stop a
        // second probe on the reconnect.
        bt.fire([BTDeviceSnapshot(id: speaker.id, name: speaker.name, isConnected: false)])
        waitFor { hardware.unwatched.contains(self.speaker.id) }
        bt.fire([speaker])
        waitFor { hardware.hasWatch(self.speaker.id) }
        SuiteWait.settle(0.3)  // give a second probe time to run if one was queued

        #expect(callCount.value == 1)
    }
}
