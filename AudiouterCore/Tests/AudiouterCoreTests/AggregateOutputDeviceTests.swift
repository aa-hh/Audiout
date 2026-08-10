// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AirPlayEngine
@testable import AudiouterCore

#if canImport(CoreAudio)
import CoreAudio
#endif

// MARK: - Shared fakes (used by both suites below)

/// Scripted double for the whole HAL surface ``AggregateOutputDevice``/
/// `NativeBackend`'s aggregate wiring calls through. Mirrors the real HAL's two
/// independent axes: "what UID resolves to what id right now" (`resolveDeviceID`)
/// and "what aggregate UIDs are currently enumerated" (`aggregateDeviceUIDs`) —
/// `createAggregate`/`destroyAggregate` update both, so a test can observe
/// create→resolve and destroy→gone round-trips exactly like the real HAL would.
/// **Never touches the real HAL** — the whole point of ``AggregateDeviceControlling``
/// existing as a seam.
private final class FakeAggregateControl: AggregateDeviceControlling, @unchecked Sendable {
    private let lock = NSLock()
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    private var resolvable: [String: AudioObjectID]
    private var enumerated: [String]
    private var builtInUID: String?
    private var createResult: AudioObjectID?
    private var destroySucceeds: Bool
    private var setDefaultSucceeds: Bool

    private var resolveCallLog: [String] = []
    private var createCallLog: [(uid: String, name: String, subDeviceUID: String)] = []
    private var destroyCallLog: [AudioObjectID] = []
    private var setDefaultCallLog: [AudioObjectID] = []

    init(
        resolvable: [String: AudioObjectID] = [:],
        enumerated: [String] = [],
        builtInUID: String? = "com.apple.builtin",
        createResult: AudioObjectID? = nil,
        destroySucceeds: Bool = true,
        setDefaultSucceeds: Bool = true
    ) {
        self.resolvable = resolvable
        self.enumerated = enumerated
        self.builtInUID = builtInUID
        self.createResult = createResult
        self.destroySucceeds = destroySucceeds
        self.setDefaultSucceeds = setDefaultSucceeds
    }

    /// Re-scripts what a fresh `resolveDeviceID` returns — simulates the real
    /// HAL handing back a DIFFERENT `AudioObjectID` for the same UID across
    /// resolves (spike-measured instability), so a test can prove a caller
    /// never caches the id.
    func rescriptResolvable(_ new: [String: AudioObjectID]) { locked { resolvable = new } }

    func resolveDeviceID(forUID uid: String) -> AudioObjectID? {
        locked { resolveCallLog.append(uid); return resolvable[uid] }
    }
    func createAggregate(uid: String, name: String, subDeviceUID: String) -> AudioObjectID? {
        locked {
            createCallLog.append((uid, name, subDeviceUID))
            guard let result = createResult else { return nil }
            resolvable[uid] = result
            if !enumerated.contains(uid) { enumerated.append(uid) }
            return result
        }
    }
    func destroyAggregate(_ deviceID: AudioObjectID) -> Bool {
        locked {
            destroyCallLog.append(deviceID)
            guard destroySucceeds else { return false }
            if let uid = resolvable.first(where: { $0.value == deviceID })?.key {
                resolvable.removeValue(forKey: uid)
                enumerated.removeAll { $0 == uid }
            }
            return true
        }
    }
    func aggregateDeviceUIDs() -> [String] { locked { enumerated } }
    func deviceUID(_ deviceID: AudioObjectID) -> String? {
        locked { resolvable.first(where: { $0.value == deviceID })?.key }
    }
    func builtInOutputDeviceUID() -> String? { locked { builtInUID } }
    func setDefaultOutputDevice(_ deviceID: AudioObjectID) -> Bool {
        locked { setDefaultCallLog.append(deviceID); return setDefaultSucceeds }
    }

    // Thread-safe snapshots for assertions.
    var resolveCalls: [String] { locked { resolveCallLog } }
    var createCalls: [(uid: String, name: String, subDeviceUID: String)] { locked { createCallLog } }
    var destroyCalls: [AudioObjectID] { locked { destroyCallLog } }
    var setDefaultCalls: [AudioObjectID] { locked { setDefaultCallLog } }
}

/// A minimal thread-safe box, so a test can script what `NativeBackend`'s
/// injected `currentDefaultOutputUID` provider reports, and change it mid-test
/// (the Mac's default output "changing") with no real HAL read.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}

// MARK: - 1/2. AggregateOutputDevice + EffectiveCaptureDevice (pure logic, no NativeBackend)

/// Hermetic tests for the Wave 3 PUBLIC "Audiouter" aggregate's pure, injectable
/// decision logic: ``AggregateOutputDevice`` (T1) and
/// ``EffectiveCaptureDevice/resolve(default:uidOf:mainSubDeviceOf:)`` (T2). Every
/// test drives a fake ``AggregateDeviceControlling`` — **none may ever construct
/// ``CoreAudioAggregateDeviceControl`` or otherwise reach the HAL**, same
/// discipline as ``DefaultOutputSwitcherTests``.
@Suite struct AggregateOutputDeviceTests {

    // MARK: classifyOffSwitch

    @Test func classifyOffSwitchStillOursWhenUIDMatchesProduct() {
        let device = AggregateOutputDevice(control: FakeAggregateControl())
        #expect(device.classifyOffSwitch(newDefaultUID: AggregateOutputDevice.productUID) == .stillOurs)
    }

    @Test func classifyOffSwitchUserDeselectedForAnyOtherRealDevice() {
        let device = AggregateOutputDevice(control: FakeAggregateControl())
        #expect(device.classifyOffSwitch(newDefaultUID: "com.apple.builtin") == .userDeselected)
    }

    @Test func classifyOffSwitchDeviceVanishedWhenUIDIsNil() {
        let device = AggregateOutputDevice(control: FakeAggregateControl())
        #expect(device.classifyOffSwitch(newDefaultUID: nil) == .deviceVanished)
    }

    /// An empty-string UID is treated the same as `nil` (the guard is
    /// `!newDefaultUID.isEmpty`) — an unreadable/blank read, not a real device.
    @Test func classifyOffSwitchDeviceVanishedWhenUIDIsEmptyString() {
        let device = AggregateOutputDevice(control: FakeAggregateControl())
        #expect(device.classifyOffSwitch(newDefaultUID: "") == .deviceVanished)
    }

    // MARK: sweepOrphans idempotence

    /// Destroys BOTH our own product UID and the spike tool's leftover UID when
    /// both are currently enumerated — idempotent: a second sweep against an
    /// already-clean HAL destroys nothing and reports zero, no error.
    @Test func sweepOrphansDestroysBothKnownUIDsThenIsANoOpOnRerun() {
        let control = FakeAggregateControl(
            resolvable: [
                AggregateOutputDevice.productUID: 501,
                "com.audiouter.spike.aggregate": 777,
            ],
            enumerated: [AggregateOutputDevice.productUID, "com.audiouter.spike.aggregate"])
        let device = AggregateOutputDevice(control: control)

        let firstCount = device.sweepOrphans()
        #expect(firstCount == 2)
        #expect(Set(control.destroyCalls) == Set<AudioObjectID>([501, 777]))

        let secondCount = device.sweepOrphans()
        #expect(secondCount == 0, "a rerun against an already-clean HAL must destroy nothing")
        #expect(control.destroyCalls.count == 2, "no additional destroy calls on the rerun")
    }

    /// An unrelated aggregate (neither our product UID nor the spike tool's) is
    /// left completely alone — the sweep is scoped to exactly the two known
    /// UIDs, never "every aggregate on the system."
    @Test func sweepOrphansLeavesUnrelatedAggregatesAlone() {
        let control = FakeAggregateControl(
            resolvable: ["com.someoneelse.aggregate": 42],
            enumerated: ["com.someoneelse.aggregate"])
        let device = AggregateOutputDevice(control: control)

        #expect(device.sweepOrphans() == 0)
        #expect(control.destroyCalls.isEmpty)
    }

    /// A UID that's enumerated but no longer resolves (a resolve/enumerate race,
    /// or it's already gone) is skipped cleanly — the documented "clean no-op"
    /// race-safety — rather than destroying a bogus id or crashing.
    @Test func sweepOrphansSkipsAUIDThatNoLongerResolves() {
        let control = FakeAggregateControl(
            resolvable: [:],   // enumerated but NOT resolvable — vanished mid-sweep
            enumerated: [AggregateOutputDevice.productUID])
        let device = AggregateOutputDevice(control: control)

        #expect(device.sweepOrphans() == 0)
        #expect(control.destroyCalls.isEmpty)
    }

    // MARK: adoptOrCreate

    /// A resolve HIT adopts the existing device — no create call at all.
    @Test func adoptOrCreateAdoptsAnExistingDeviceWithoutCreating() {
        let control = FakeAggregateControl(resolvable: [AggregateOutputDevice.productUID: 501])
        let device = AggregateOutputDevice(control: control)

        #expect(device.adoptOrCreate() == 501)
        #expect(control.createCalls.isEmpty)
        #expect(control.resolveCalls.contains(AggregateOutputDevice.productUID))
    }

    /// A resolve MISS creates a fresh aggregate wrapping the Mac's CURRENT
    /// built-in output — exactly one create call, with the right UID/name/sub-device.
    @Test func adoptOrCreateCreatesOnAMissWrappingTheBuiltInDevice() {
        let control = FakeAggregateControl(resolvable: [:], builtInUID: "com.apple.builtin", createResult: 909)
        let device = AggregateOutputDevice(control: control)

        #expect(device.adoptOrCreate() == 909)
        #expect(control.createCalls.count == 1)
        #expect(control.createCalls.first?.uid == AggregateOutputDevice.productUID)
        #expect(control.createCalls.first?.name == AggregateOutputDevice.productName)
        #expect(control.createCalls.first?.subDeviceUID == "com.apple.builtin")
    }

    /// No built-in output to wrap (headless/aggregate-only Mac) — `adoptOrCreate`
    /// returns `nil` and never even attempts a create call.
    @Test func adoptOrCreateReturnsNilWithNoBuiltInDeviceAndNeverCreates() {
        let control = FakeAggregateControl(resolvable: [:], builtInUID: nil)
        let device = AggregateOutputDevice(control: control)

        #expect(device.adoptOrCreate() == nil)
        #expect(control.createCalls.isEmpty)
    }

    /// Never caches the id past one call: a device recreated elsewhere between
    /// two calls (spike-measured `AudioObjectID` instability, id 146 → 107
    /// across resolves) is picked up FRESH on the second call via another
    /// `resolveDeviceID`, not a value stashed from the first.
    @Test func adoptOrCreateNeverCachesTheIDAcrossCalls() {
        let control = FakeAggregateControl(resolvable: [:], builtInUID: "com.apple.builtin", createResult: 101)
        let device = AggregateOutputDevice(control: control)

        #expect(device.adoptOrCreate() == 101, "first call: miss then create")

        // Simulate the aggregate having been torn down and recreated by
        // something else under a NEW AudioObjectID.
        control.rescriptResolvable([AggregateOutputDevice.productUID: 202])

        #expect(device.adoptOrCreate() == 202, "second call must resolve fresh, not reuse the first id")
        #expect(control.createCalls.count == 1, "the second call was a HIT — no second create")
    }

    // MARK: EffectiveCaptureDevice.resolve (pure; NativeCaptureCoordinator.swift)

    /// The default output IS our public aggregate and its main sub-device
    /// resolves — capture must pin to the SUB-DEVICE (the aggregate itself
    /// hosts no tap-able stream), not the aggregate id.
    @Test func resolveReturnsMainSubDeviceWhenDefaultIsOurAggregate() {
        let resolved = EffectiveCaptureDevice.resolve(
            default: 10,
            uidOf: { $0 == 10 ? AggregateOutputDevice.productUID : nil },
            mainSubDeviceOf: { $0 == 10 ? 20 : nil })
        #expect(resolved == 20)
    }

    /// A normal (non-aggregate) default device is returned unchanged — identity.
    /// `mainSubDeviceOf` must not even be consulted (short-circuited by the guard).
    @Test func resolveReturnsDefaultUnchangedForANormalDevice() {
        let resolved = EffectiveCaptureDevice.resolve(
            default: 10,
            uidOf: { $0 == 10 ? "com.apple.builtin" : nil },
            mainSubDeviceOf: { _ in fatalError("must not be consulted for a non-aggregate default") })
        #expect(resolved == 10)
    }

    /// The default IS our aggregate, but its main sub-device is unreadable
    /// (`nil`) — falls back to the default UNCHANGED rather than pinning to a
    /// device that doesn't resolve, so both wired call sites agree deterministically.
    @Test func resolveFallsBackToDefaultWhenSubDeviceIsUnreadable() {
        let resolved = EffectiveCaptureDevice.resolve(
            default: 10,
            uidOf: { $0 == 10 ? AggregateOutputDevice.productUID : nil },
            mainSubDeviceOf: { _ in nil })
        #expect(resolved == 10)
    }
}

// MARK: - 3. NativeBackend wiring (T5): activation / off-switch classification / echo-guard

/// These tests need a full (fake-backed) ``NativeBackend`` to drive the
/// activation-seam/off-switch/echo-guard state machine end to end. Nested under
/// ``SerializedSharedState`` for the same reason `NativeBackendTests` is (see
/// `SerializedSharedStateSuite.swift`): starting a real `NativeBackend` fires
/// `Telemetry.log` calls against the process-global sink, which must never
/// interleave with a concurrently-running suite that has installed a test sink
/// via `Telemetry._installTestSink(_:)`.
///
/// No test here ever lets a WRITE reach real hardware: `aggregateControl` and
/// `currentDefaultOutputUID` are always fakes, mirroring how this file's other
/// suite never touches ``CoreAudioAggregateDeviceControl``.
extension SerializedSharedState {

@Suite struct AggregateOutputDeviceWiringTests {

    // MARK: Minimal NativeBackend doubles
    //
    // NativeBackendTests.swift already has richer doubles with the same names,
    // but they're private to that file/suite — these are trimmed to just what
    // T5's aggregate wiring exercises (no discovery events, no engine ops).

    private final class MinimalEngine: EngineControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _addedOutputs: [OutputID] = []
        private var _removedOutputs: [OutputID] = []

        var dacpID: UInt64 { 0 }
        func start() async throws {}
        func stop() async {}
        @discardableResult
        func updateDiscovery(_ descriptor: DeviceDescriptor) async throws -> OutputID { descriptor.parsedID ?? OutputID(rawValue: 0) }
        func removeDiscovery(_ descriptor: DeviceDescriptor) async {}
        func addOutput(_ id: OutputID) async throws { lock.lock(); _addedOutputs.append(id); lock.unlock() }
        // T5: per-app stream bind overload (see the protocol default's doc) —
        // recorded into the SAME `addedOutputs` list; no test in this file
        // exercises per-app routing, so one list is enough.
        func addOutput(_ id: OutputID, streamId: UInt32) async throws { lock.lock(); _addedOutputs.append(id); lock.unlock() }
        func removeOutput(_ id: OutputID) async throws { lock.lock(); _removedOutputs.append(id); lock.unlock() }
        func setVolume(_ id: OutputID, _ volume: Double) async throws {}
        func setStartBufferMs(_ ms: Int) async {}
        func makeStateStream() -> AsyncStream<(OutputID, OutputState)> { AsyncStream { _ in } }
        func makeRemoteEventStream() -> AsyncStream<RemoteEvent> { AsyncStream { _ in } }

        // Thread-safe snapshots for assertions (T5).
        var addedOutputs: [OutputID] { lock.lock(); defer { lock.unlock() }; return _addedOutputs }
        var removedOutputs: [OutputID] { lock.lock(); defer { lock.unlock() }; return _removedOutputs }
    }

    private final class MinimalDiscovery: DiscoverySource, @unchecked Sendable {
        var onEvent: (@Sendable (DiscoveryEvent) -> Void)?
        func start() {}
        func stop() {}
        /// T5: feed a `DiscoveryEvent` synchronously, mirroring
        /// `NativeBackendTests.FakeDiscovery.fire(_:)`.
        func fire(_ event: DiscoveryEvent) { onEvent?(event) }
    }

    private final class MinimalDACPEndpoint: DACPEndpoint, @unchecked Sendable {
        var onVolume: (@Sendable (_ activeRemote: UInt32, _ level: Double) -> Void)?
        var onVolumeStep: (@Sendable (_ activeRemote: UInt32, _ direction: Int) -> Void)?
        func start(dacpID: UInt64) {}
        func stop() {}
    }

    private struct AlwaysReadyPTPHelperActivator: PTPHelperActivating {
        var willWaitForClock: Bool { false }
        func activate(timeout: TimeInterval) async -> PTPHelperActivationOutcome { .ready }
    }

    /// Fakes the Mac's own default-output volume/mute with NO HAL reads/listeners,
    /// and lets a test fire `onExternalChange` on demand to simulate the
    /// default-output DEVICE switching — the only path T5's echo-guard/off-switch
    /// classification reacts to. Trimmed to just that: no volume/mute scripting,
    /// since none of these tests touch the volume-key mirror.
    private final class FakeSystemVolume: SystemVolumeControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _onExternalChange: (@Sendable (Int?, Bool?, Bool) -> Void)?
        func currentVolume() -> Int? { nil }
        func currentMuted() -> Bool? { nil }
        func setVolume(_ volume: Int, didWrite: (@Sendable (Bool) -> Void)?) { didWrite?(true) }
        func setMuted(_ muted: Bool) {}
        var onExternalChange: (@Sendable (Int?, Bool?, Bool) -> Void)? {
            get { lock.lock(); defer { lock.unlock() }; return _onExternalChange }
            set { lock.lock(); _onExternalChange = newValue; lock.unlock() }
        }
        func start() {}
        func stop() {}
        func fireExternalChange(volume: Int?, muted: Bool?, defaultDeviceChanged: Bool) {
            let handler = { lock.lock(); defer { lock.unlock() }; return _onExternalChange }()
            handler?(volume, muted, defaultDeviceChanged)
        }
    }

    private func makeBackend(
        aggregateControl: FakeAggregateControl,
        currentDefaultOutputUIDBox: LockedBox<String?>
    ) -> (NativeBackend, FakeSystemVolume) {
        let systemVolume = FakeSystemVolume()
        let backend = NativeBackend(
            engineControl: MinimalEngine(),
            discoverySource: MinimalDiscovery(),
            dacpEndpoint: MinimalDACPEndpoint(),
            systemVolume: systemVolume,
            ptpHelperActivator: AlwaysReadyPTPHelperActivator(),
            aggregateControl: aggregateControl,
            currentDefaultOutputUID: { currentDefaultOutputUIDBox.get() },
            // D7 (adversarial review, Seamless handoff T3): this suite drives
            // `expectedSelected` non-empty, which arms the handoff watcher
            // (`reconcileHandoffWatcherLocked`, tail of `reconcileAggregateDefault`)
            // — without this override the real default factory would posix_spawn
            // `/usr/bin/log stream` here too. Same fix as `NativeBackendTests`.
            handoffWatcherFactory: { onBlockedAttempt in
                AirPlayHandoffWatcher(spawn: NoOpLogStream(), onBlockedAttempt: onBlockedAttempt)
            })
        return (backend, systemVolume)
    }

    /// Inert `LogStreamSpawning` stand-in (D7) — see `NativeBackendTests`' twin.
    private final class NoOpLogStream: LogStreamSpawning, @unchecked Sendable {
        func start(onLine: @escaping @Sendable (String) -> Void,
                    onTermination: @escaping @Sendable () -> Void) throws {}
        func stop() {}
        var isRunning: Bool { false }
    }

    private actor EventBox {
        private var events: [BackendEvent] = []
        func append(_ e: BackendEvent) -> [BackendEvent] { events.append(e); return events }
        func snapshot() -> [BackendEvent] { events }
    }

    /// Subscribe, run `after` once the subscription is live, then collect
    /// `.routingBlockedNeedsDefault` events (everything else — `.level`, and the
    /// `.deviceAdded(local-mac)` `start()` always surfaces immediately,
    /// irrelevant startup noise for these tests — is ignored) until `predicate`
    /// holds or `timeout` elapses. Fails (via `confirmation`) if `predicate`
    /// never holds.
    private func collect(
        from backend: NativeBackend,
        timeout: Duration = .seconds(2),
        until predicate: @escaping @Sendable ([BackendEvent]) -> Bool,
        after stimulus: @escaping () -> Void
    ) async -> [BackendEvent] {
        let stream = backend.makeEventStream()
        let box = EventBox()
        await confirmation("predicate satisfied") { done in
            let task = Task {
                for await event in stream {
                    guard case .routingBlockedNeedsDefault = event else { continue }
                    let all = await box.append(event)
                    if predicate(all) { done(); break }
                }
            }
            defer { task.cancel() }
            try? await Task.sleep(nanoseconds: 20_000_000)
            stimulus()
            try? await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value }
                group.addTask { try await Task.sleep(for: timeout) }
                try await group.next()
                // Cancel the CONSUMER before the group scope exits. `await
                // task.value` does not respond to the group's own cancelAll — the
                // group exit awaits that child, which awaits `task`, and the
                // `defer { task.cancel() }` above only runs AFTER the group
                // returns. Without this line, any predicate that never fires
                // turned the 2s timeout into a permanent deadlock (found the hard
                // way: it hid a real production bug behind an infinite hang).
                task.cancel()
                group.cancelAll()
            }
        }
        return await box.snapshot()
    }

    /// Collect every `.routingBlockedNeedsDefault` event over a FIXED window
    /// with no predicate — used to assert one did NOT happen (e.g. the
    /// echo-guard: fire a stimulus, prove no such event follows within the
    /// window). Same event filter as ``collect(from:timeout:until:after:)``.
    private func collectQuiescent(
        from backend: NativeBackend,
        duration: Duration = .milliseconds(300),
        after stimulus: @escaping () -> Void
    ) async -> [BackendEvent] {
        let stream = backend.makeEventStream()
        let box = EventBox()
        let task = Task {
            for await event in stream {
                guard case .routingBlockedNeedsDefault = event else { continue }
                _ = await box.append(event)
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        stimulus()
        try? await Task.sleep(for: duration)
        task.cancel()
        return await box.snapshot()
    }

    private func isRoutingBlocked(_ event: BackendEvent, _ expected: Bool) -> Bool {
        if case .routingBlockedNeedsDefault(let blocked) = event { return blocked == expected }
        return false
    }

    // MARK: Tests

    /// ACTIVATION SEAM: the moment routing goes non-empty (`setOutputSet` with a
    /// non-empty set — "actively routing" per the AMBIGUITY note on
    /// `reconcileAggregateDefault`), the backend tries to take the Mac's default
    /// output for the aggregate. When that write fails outright, routing IS
    /// active but the default is NOT ours: `.routingBlockedNeedsDefault(true)`
    /// must be emitted. The default-UID reads `nil` throughout (unreadable),
    /// covering the never-selected/`.deviceVanished` classification.
    @Test func routingBlockedTrueWhenActivationCannotTakeOverAndDefaultIsUnreadable() async {
        let control = FakeAggregateControl(
            resolvable: [AggregateOutputDevice.productUID: 501], setDefaultSucceeds: false)
        let box = LockedBox<String?>(nil)
        let (backend, _) = makeBackend(aggregateControl: control, currentDefaultOutputUIDBox: box)
        backend.start(); defer { backend.stop() }

        let events = await collect(from: backend, until: { events in
            events.contains { self.isRoutingBlocked($0, true) }
        }, after: { backend.setOutputSet(["some-airplay-device"]) })

        #expect(events.contains { self.isRoutingBlocked($0, true) })
        #expect(control.setDefaultCalls.count == 1, "activation must have attempted exactly one write")
    }

    /// A genuine user off-switch (picking a different device directly in Sound
    /// settings while still actively routing) is classified `.userDeselected` and
    /// flips the warning on; the user clicking the popover's "Use Audiouter"
    /// button — the ONE sanctioned re-select (Q6) — re-takes the default and
    /// flips the warning back off. Exercises `evaluateRoutingBlocked`'s
    /// `.userDeselected`/`.stillOurs` pair through the REAL listener wiring.
    @Test func routingBlockedTracksUserDeselectThenAppReselect() async {
        let control = FakeAggregateControl(resolvable: [AggregateOutputDevice.productUID: 501])
        let box = LockedBox<String?>("com.other.speakers")
        let (backend, systemVolume) = makeBackend(aggregateControl: control, currentDefaultOutputUIDBox: box)
        backend.start(); defer { backend.stop() }

        // Activation: routing goes non-empty, the app successfully points the
        // default at the aggregate. Optimistic `false` — already false, no event.
        let activationEvents = await collectQuiescent(from: backend) {
            backend.setOutputSet(["some-airplay-device"])
        }
        #expect(activationEvents.isEmpty)
        #expect(control.setDefaultCalls == [501])

        // The user picks a different device in Sound settings — genuine
        // off-switch while still actively routing.
        box.set("com.airpods.whatever")
        let deselectEvents = await collect(from: backend, until: { events in
            events.contains { self.isRoutingBlocked($0, true) }
        }, after: { systemVolume.fireExternalChange(volume: nil, muted: nil, defaultDeviceChanged: true) })
        #expect(deselectEvents.contains { self.isRoutingBlocked($0, true) }, ".userDeselected must flip the warning on")

        // The user clicks "Use Audiouter" — re-takes the default and
        // optimistically reflects `.stillOurs` immediately.
        let reselectEvents = await collect(from: backend, until: { events in
            events.contains { self.isRoutingBlocked($0, false) }
        }, after: { backend.reselectAggregateAsDefault() })
        #expect(reselectEvents.contains { self.isRoutingBlocked($0, false) }, ".stillOurs must flip the warning back off")
        #expect(control.setDefaultCalls == [501, 501], "activation + re-select both wrote the aggregate")
    }

    /// QUIT-RESTORE GUARD (adversarial review #1): once the app has taken over the
    /// default with the aggregate, `stop()` restores the pre-takeover output ONLY
    /// while the aggregate is STILL the current default. If the user has since
    /// picked a different output in Sound settings, that default is THEIRS —
    /// restoring the stale prior would silently yank them off their choice at quit.
    /// Here the user moves to AirPods mid-session; quitting must NOT write the prior
    /// (built-in) device back. Without the guard, `setDefaultCalls` would gain 601.
    @Test func quitDoesNotRestorePriorWhenUserMovedDefaultAway() async {
        let control = FakeAggregateControl(resolvable: [
            AggregateOutputDevice.productUID: 501,
            "com.builtin.speakers": 601])
        let box = LockedBox<String?>("com.builtin.speakers")
        let (backend, systemVolume) = makeBackend(aggregateControl: control, currentDefaultOutputUIDBox: box)
        backend.start()

        // Activation: captures prior = built-in speakers, takes over with the aggregate.
        _ = await collectQuiescent(from: backend) { backend.setOutputSet(["some-airplay-device"]) }
        #expect(control.setDefaultCalls == [501], "activation points the default at the aggregate")

        // The user picks a DIFFERENT output (AirPods) in Sound settings mid-session.
        box.set("com.airpods.whatever")
        _ = await collect(from: backend, until: { events in
            events.contains { self.isRoutingBlocked($0, true) }
        }, after: { systemVolume.fireExternalChange(volume: nil, muted: nil, defaultDeviceChanged: true) })

        // Quit. The aggregate is no longer the current default, so the prior-default
        // restore must be SKIPPED — 601 (built-in) must never be written.
        backend.stop()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!control.setDefaultCalls.contains(601),
                "stop() must not restore the stale prior default after the user chose another output")
        #expect(control.setDefaultCalls == [501], "only the activation write ever happened")
    }

    /// ECHO-GUARD: the default-device-changed notification that arrives as a
    /// direct RESULT of the backend's OWN successful write must be consumed
    /// silently — never misread as a user off-switch — and the guard must not
    /// get stuck: the VERY NEXT genuine change (a real user off-switch) is still
    /// detected normally.
    @Test func echoOfOwnWriteIsConsumedSilentlyAndDoesNotStickTheGuard() async {
        let control = FakeAggregateControl(resolvable: [AggregateOutputDevice.productUID: 501])
        let box = LockedBox<String?>("com.other.speakers")
        let (backend, systemVolume) = makeBackend(aggregateControl: control, currentDefaultOutputUIDBox: box)
        backend.start(); defer { backend.stop() }

        // Activation takes over the default — issues ONE write, to the aggregate.
        let activationEvents = await collectQuiescent(from: backend) {
            backend.setOutputSet(["some-airplay-device"])
        }
        #expect(activationEvents.isEmpty, "a successful takeover reflects false optimistically — already false, no event")
        #expect(control.setDefaultCalls == [501])

        // The HAL's async echo of OUR OWN write lands (the default-UID read now
        // reports the aggregate — exactly what we just wrote). Must be consumed
        // silently: no event, no re-evaluation thrash.
        box.set(AggregateOutputDevice.productUID)
        let echoEvents = await collectQuiescent(from: backend) {
            systemVolume.fireExternalChange(volume: nil, muted: nil, defaultDeviceChanged: true)
        }
        #expect(echoEvents.isEmpty, "the backend's own default-output write must never surface as a routing-blocked event")

        // The guard must not be stuck "always consuming": the VERY NEXT change —
        // a genuine user off-switch — is still classified normally.
        box.set("com.airpods.whatever")
        let realOffSwitch = await collect(from: backend, until: { events in
            events.contains { self.isRoutingBlocked($0, true) }
        }, after: { systemVolume.fireExternalChange(volume: nil, muted: nil, defaultDeviceChanged: true) })
        #expect(realOffSwitch.contains { self.isRoutingBlocked($0, true) },
                "the guard must fall through to normal evaluation for the next real change")
    }

    /// Edge-triggered: firing the SAME off-switch condition twice in a row must
    /// emit `.routingBlockedNeedsDefault(true)` only ONCE — a repeat of the
    /// current state can never thrash the event stream.
    @Test func routingBlockedNeverThrashesOnRepeatedIdenticalOffSwitch() async {
        let control = FakeAggregateControl(resolvable: [AggregateOutputDevice.productUID: 501])
        let box = LockedBox<String?>("com.other.speakers")
        let (backend, systemVolume) = makeBackend(aggregateControl: control, currentDefaultOutputUIDBox: box)
        backend.start(); defer { backend.stop() }

        _ = await collectQuiescent(from: backend) { backend.setOutputSet(["some-airplay-device"]) }

        box.set("com.airpods.whatever")
        let firstEvents = await collect(from: backend, until: { events in
            events.contains { self.isRoutingBlocked($0, true) }
        }, after: { systemVolume.fireExternalChange(volume: nil, muted: nil, defaultDeviceChanged: true) })
        #expect(firstEvents.filter { if case .routingBlockedNeedsDefault = $0 { return true }; return false }.count == 1)

        // Fire the IDENTICAL condition again — no new event.
        let secondEvents = await collectQuiescent(from: backend) {
            systemVolume.fireExternalChange(volume: nil, muted: nil, defaultDeviceChanged: true)
        }
        #expect(secondEvents.isEmpty, "a repeat of the current routing-blocked state must never re-emit")
    }

    // MARK: - T5: Seamless handoff release/resume, end to end through a real NativeBackend

    /// Records outbound PTP-release calls (D8, `NativeBackend.releaseForHandoff`)
    /// so a test can assert exactly one per handoff release without touching a
    /// real Mach service.
    private final class FakeReleaser: PTPHelperReleasing, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        func release() { lock.lock(); _calls += 1; lock.unlock() }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    }

    /// Scriptable `LogStreamSpawning` double that captures whatever REAL
    /// `AirPlayHandoffWatcher` instance is currently wired to it (via
    /// `start(onLine:onTermination:)`) so a test can push a canned NDJSON line
    /// straight through the production `BlockedAirPlayAttempt.matches` +
    /// rate-limit logic — end to end, never a bypass of the watcher itself.
    /// Shared across every `AirPlayHandoffWatcher` a test's backend creates
    /// (`reconcileHandoffWatcherLocked` makes a fresh one per arm/resume
    /// cycle), so `startCount`/`stopCount` double as the watcher's own
    /// lifecycle trace (T5 case 9).
    private final class FakeLogStream: LogStreamSpawning, @unchecked Sendable {
        private let lock = NSLock()
        private var _onLine: (@Sendable (String) -> Void)?
        private var _startCount = 0
        private var _stopCount = 0
        private var _isRunning = false

        func start(onLine: @escaping @Sendable (String) -> Void,
                    onTermination: @escaping @Sendable () -> Void) throws {
            lock.lock(); _onLine = onLine; _startCount += 1; _isRunning = true; lock.unlock()
        }
        func stop() { lock.lock(); _isRunning = false; _stopCount += 1; lock.unlock() }
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _isRunning }

        var startCount: Int { lock.lock(); defer { lock.unlock() }; return _startCount }
        var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }

        /// Push a canned NDJSON line to whichever watcher is currently attached.
        /// A no-op (matching the real watcher's own silence) if nothing has
        /// ever called `start`.
        func pushLine(_ line: String) {
            let handler = { lock.lock(); defer { lock.unlock() }; return _onLine }()
            handler?(line)
        }
    }

    /// Thread-safe accumulator for `Telemetry._installTestSink(_:)` lines.
    private final class LinesBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
        func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    /// The verified sample line `AirPlayHandoffWatcher`'s `BlockedAirPlayAttempt
    /// .matches` requires (subsystem `com.apple.airplay`, category
    /// `APSNetworkClockPTP`, `kIOReturnExclusiveAccess` in the message) — the
    /// same canned line `AirPlayHandoffWatcherTests` uses.
    private static let blockedAttemptLine =
        #"{"subsystem":"com.apple.airplay","category":"APSNetworkClockPTP","eventMessage":"[0xB198] Failed to add peer: -536870203/0xE00002C5 kIOReturnExclusiveAccess"}"#

    /// A discovered AP2 receiver fixture — mirrors `NativeBackendTests.ap2Device()`.
    private func handoffDevice(id: String = "AA:BB:CC:DD:EE:01", name: String = "Sonos Move") -> DiscoveredDevice {
        let txt = ["deviceid": id, "model": "S13", "features": "0x445F8A00,0x1C340"]
        let (parsedID, outputID) = NativeDiscovery.parseDeviceID(txt)!
        let desc = DeviceDescriptor(name: name, address: "192.168.1.10", family: .ipv4, port: 7000, txtRecord: txt)
        return DiscoveredDevice(id: parsedID, descriptor: desc, outputID: outputID, isAirPlay2Supported: true)
    }

    private func pollUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Extends `makeBackend` with the handoff-specific collaborators (T5): a
    /// real engine/discovery pair (so a device can genuinely converge into
    /// `added` — the release gate's usual arm), a `FakeReleaser`, and a
    /// scriptable `FakeLogStream` wired into a REAL `AirPlayHandoffWatcher` via
    /// `handoffWatcherFactory`. Kept as a SEPARATE helper (not a widened
    /// `makeBackend` return tuple) so the four pre-existing wiring tests above
    /// stay byte-for-byte unchanged.
    private func makeHandoffBackend(
        aggregateControl: FakeAggregateControl,
        currentDefaultOutputUIDBox: LockedBox<String?>,
        releaser: FakeReleaser = FakeReleaser(),
        logStream: FakeLogStream = FakeLogStream()
    ) -> (backend: NativeBackend, systemVolume: FakeSystemVolume, engine: MinimalEngine, discovery: MinimalDiscovery) {
        let systemVolume = FakeSystemVolume()
        let engine = MinimalEngine()
        let discovery = MinimalDiscovery()
        let backend = NativeBackend(
            engineControl: engine,
            discoverySource: discovery,
            dacpEndpoint: MinimalDACPEndpoint(),
            systemVolume: systemVolume,
            ptpHelperActivator: AlwaysReadyPTPHelperActivator(),
            aggregateControl: aggregateControl,
            currentDefaultOutputUID: { currentDefaultOutputUIDBox.get() },
            ptpHelperReleaser: releaser,
            handoffWatcherFactory: { onBlockedAttempt in
                AirPlayHandoffWatcher(spawn: logStream, onBlockedAttempt: onBlockedAttempt)
            })
        return (backend, systemVolume, engine, discovery)
    }

    /// Discover `device`, select it via `setOutputSet`, and wait until it has
    /// GENUINELY converged (`Device.isSelected == true` — house rule: means
    /// "currently in the backend's output set", i.e. `added` is non-empty).
    /// This is the release gate's usual arm (`!added.isEmpty`), reached through
    /// the real discovery → converge path rather than reaching into private
    /// state. Every caller's `FakeAggregateControl` resolves the product UID
    /// with `setDefaultSucceeds` true (the default), so this also performs a
    /// SUCCESSFUL aggregate takeover (`aggregateDefaultActive` becomes true) —
    /// the deselect trigger's extra guard.
    private func armRouting(
        backend: NativeBackend, engine: MinimalEngine, discovery: MinimalDiscovery, device: DiscoveredDevice
    ) async {
        discovery.fire(.appeared(device))
        await pollUntil { backend.devices.contains { $0.id == device.id } }
        backend.setOutputSet([device.id])
        await pollUntil { backend.devices.first { $0.id == device.id }?.isSelected == true }
    }

    /// CASE 1 — deselect releases. Gate arm: `added` (the device genuinely
    /// converged via `armRouting`). Trigger: `releaseForHandoff`'s
    /// `.userDeselected` path (NativeBackend.swift ~1310-1313), which requires
    /// BOTH `!expectedSelected.isEmpty` and `aggregateDefaultActive` — satisfied
    /// here by a SUCCESSFUL takeover (`FakeAggregateControl`'s default
    /// `setDefaultSucceeds: true`).
    @Test func deselectReleasesAfterSuccessfulTakeover() async {
        let control = FakeAggregateControl(resolvable: [AggregateOutputDevice.productUID: 501])
        let box = LockedBox<String?>("com.other.speakers")
        let releaser = FakeReleaser()
        let (backend, systemVolume, engine, discovery) = makeHandoffBackend(
            aggregateControl: control, currentDefaultOutputUIDBox: box, releaser: releaser)
        backend.start(); defer { backend.stop() }

        let device = handoffDevice()
        await armRouting(backend: backend, engine: engine, discovery: discovery, device: device)
        #expect(control.setDefaultCalls == [501], "activation must have taken over the default")

        // Genuine off-switch while still actively routing.
        box.set("com.airpods.whatever")
        let events = await collect(from: backend, until: { events in
            events.contains { self.isRoutingBlocked($0, true) }
        }, after: { systemVolume.fireExternalChange(volume: nil, muted: nil, defaultDeviceChanged: true) })

        #expect(events.contains { self.isRoutingBlocked($0, true) }, ".userDeselected must still flip the warning on")
        await pollUntil { releaser.calls == 1 }
        #expect(releaser.calls == 1, "a genuine off-switch while routing must release the PTP ports exactly once")
        #expect(!engine.removedOutputs.isEmpty, "the converged session must be torn down by the release")
        #expect(backend.test_expectedSelected.contains(device.id),
                "selection INTENT survives the release — it's what lets a resume restore it")
    }

    /// CASE 2 — `.deviceVanished` (a `nil` default-UID read) must NOT release:
    /// `classifyOffSwitch`'s nil guard classifies this distinctly from
    /// `.userDeselected`, and `releaseForHandoff` is only ever called for the
    /// latter. Gate arm: `added` (same `armRouting` convergence as case 1).
    @Test func deviceVanishedDoesNotRelease() async {
        let control = FakeAggregateControl(resolvable: [AggregateOutputDevice.productUID: 501])
        let box = LockedBox<String?>("com.other.speakers")
        let releaser = FakeReleaser()
        let (backend, systemVolume, engine, discovery) = makeHandoffBackend(
            aggregateControl: control, currentDefaultOutputUIDBox: box, releaser: releaser)
        backend.start(); defer { backend.stop() }

        let device = handoffDevice()
        await armRouting(backend: backend, engine: engine, discovery: discovery, device: device)

        box.set(nil)
        let events = await collect(from: backend, until: { events in
            events.contains { self.isRoutingBlocked($0, true) }
        }, after: { systemVolume.fireExternalChange(volume: nil, muted: nil, defaultDeviceChanged: true) })

        #expect(events.contains { self.isRoutingBlocked($0, true) }, "a vanished default still shows the warning — it isn't ours")
        #expect(releaser.calls == 0, "deviceVanished must never release — only userDeselected does")
        #expect(engine.removedOutputs.isEmpty, "no teardown for a vanished (not deselected) default")
    }

    /// CASE 3 — never having taken over the default must not release on
    /// deselect. VARIANT IMPLEMENTED: the aggregate UID never RESOLVES, not a
    /// write failure. Read `pointDefaultAtAggregate` (NativeBackend.swift
    /// ~4473-4488): `aggregateDefaultActive = true` is set the moment
    /// `resolveDeviceID` succeeds, BEFORE the `setDefaultOutputDevice` write is
    /// even attempted — so a write-FAILURE variant (`setDefaultSucceeds: false`
    /// with a resolvable UID) would still leave `aggregateDefaultActive == true`
    /// and the deselect trigger's guard would pass anyway, defeating the point
    /// of this case. Only a failed RESOLVE (the function's very first guard)
    /// leaves `aggregateDefaultActive` false, the actual "we never took over"
    /// state the trigger's guard (line ~1310) checks.
    ///
    /// Because the aggregate never resolves, `evaluateRoutingBlocked()` (called
    /// unconditionally ahead of the deselect-trigger check, line ~1294) already
    /// classifies `blocked = true` DURING activation itself — so the warning is
    /// already on by the time the deselect stimulus fires, and it does NOT
    /// re-emit (edge-triggered `setRoutingBlocked`). This case asserts
    /// quiescence instead of waiting for a fresh event.
    @Test func neverTookOverDoesNotReleaseOnDeselect() async {
        let control = FakeAggregateControl(resolvable: [:])   // productUID never resolves
        let box = LockedBox<String?>("com.other.speakers")
        let releaser = FakeReleaser()
        let (backend, systemVolume, engine, discovery) = makeHandoffBackend(
            aggregateControl: control, currentDefaultOutputUIDBox: box, releaser: releaser)
        backend.start(); defer { backend.stop() }

        let device = handoffDevice()
        await armRouting(backend: backend, engine: engine, discovery: discovery, device: device)
        #expect(control.setDefaultCalls.isEmpty, "an unresolvable aggregate never even attempts the write")

        box.set("com.airpods.whatever")
        let quiescent = await collectQuiescent(from: backend) {
            systemVolume.fireExternalChange(volume: nil, muted: nil, defaultDeviceChanged: true)
        }
        #expect(quiescent.isEmpty, "already blocked since activation (unresolvable aggregate) — no NEW edge to emit")
        #expect(releaser.calls == 0, "never having taken over the default must never release")
        #expect(engine.removedOutputs.isEmpty)
    }

    /// CASE 4 — a blocked-attempt log line releases the PTP ports the same way
    /// a deselect does. Gate arm: `added` (armRouting). Unlike the deselect
    /// trigger, this path (`handleBlockedAirPlayAttempt` → `releaseForHandoff
    /// (reason: "blockedAttempt")`, NativeBackend.swift ~4101-4155) does NOT
    /// check `aggregateDefaultActive` — it releases on any matching line while
    /// the release gate holds. Drives the REAL `AirPlayHandoffWatcher`'s
    /// line-matching + rate-limit logic via `FakeLogStream.pushLine`, not a
    /// direct call to the backend's handler.
    ///
    /// DEVIATION FROM THE SPEC'S "same assertions as case 1": verified
    /// `releaseForHandoff`'s body has NO call to `evaluateRoutingBlocked`/
    /// `setRoutingBlocked` anywhere in it — only a genuine default-device-
    /// change notification reaches those (the `else` arm at ~1294, which a log
    /// line never goes through). So, unlike a deselect, a blocked-attempt
    /// release does NOT itself flip the routing-blocked warning; this case
    /// asserts quiescence on that event instead of waiting for one that never
    /// comes, and keeps the release-mechanics assertions (releaser call,
    /// teardown, telemetry reason) that DO hold.
    @Test func blockedAttemptLineReleases() async {
        let control = FakeAggregateControl(resolvable: [AggregateOutputDevice.productUID: 501])
        let box = LockedBox<String?>("com.other.speakers")
        let releaser = FakeReleaser()
        let logStream = FakeLogStream()
        let (backend, _, engine, discovery) = makeHandoffBackend(
            aggregateControl: control, currentDefaultOutputUIDBox: box, releaser: releaser, logStream: logStream)
        backend.start(); defer { backend.stop() }

        let device = handoffDevice()
        await armRouting(backend: backend, engine: engine, discovery: discovery, device: device)
        await pollUntil { logStream.startCount >= 1 }

        let sink = LinesBox()
        Telemetry._installTestSink { sink.append($0) }
        defer { Telemetry._installTestSink(nil) }

        let quiescent = await collectQuiescent(from: backend) {
            logStream.pushLine(Self.blockedAttemptLine)
        }
        #expect(quiescent.isEmpty, "a blocked-attempt release never touches the routing-blocked warning itself")
        await pollUntil { releaser.calls == 1 }
        #expect(releaser.calls == 1)
        #expect(!engine.removedOutputs.isEmpty)
        #expect(sink.snapshot().contains { $0.contains(#""evt":"handoff_release""#) && $0.contains(#""reason":"blockedAttempt""#) },
                "Telemetry._installTestSink: the release's own log line records the blockedAttempt reason")
    }

    /// CASE 5 — a blocked-attempt line while NOT routing does nothing: with no
    /// `setOutputSet` call, `expectedSelected`/`streamBindings` are both empty,
    /// so `reconcileHandoffWatcherLocked`'s `shouldRun` is false and the watcher
    /// never even starts — `pushLine` is a no-op against an unattached fake.
    @Test func blockedAttemptLineDoesNothingWhenNotRouting() async {
        let control = FakeAggregateControl(resolvable: [AggregateOutputDevice.productUID: 501])
        let box = LockedBox<String?>("com.other.speakers")
        let releaser = FakeReleaser()
        let logStream = FakeLogStream()
        let (backend, _, _, _) = makeHandoffBackend(
            aggregateControl: control, currentDefaultOutputUIDBox: box, releaser: releaser, logStream: logStream)
        backend.start(); defer { backend.stop() }

        let quiescent = await collectQuiescent(from: backend) {
            logStream.pushLine(Self.blockedAttemptLine)
        }
        #expect(quiescent.isEmpty)
        #expect(releaser.calls == 0)
        #expect(logStream.startCount == 0, "the watcher never starts when nothing is routing")
    }

    /// CASE 6 — the popover's "Use Audiouter" button resumes: re-takes the
    /// default (a second write) and re-kicks the whole-system device that a
    /// prior release tore down.
    @Test func buttonResumeRestoresAfterHandoffRelease() async {
        let control = FakeAggregateControl(resolvable: [AggregateOutputDevice.productUID: 501])
        let box = LockedBox<String?>("com.other.speakers")
        let releaser = FakeReleaser()
        let (backend, systemVolume, engine, discovery) = makeHandoffBackend(
            aggregateControl: control, currentDefaultOutputUIDBox: box, releaser: releaser)
        backend.start(); defer { backend.stop() }

        let device = handoffDevice()
        await armRouting(backend: backend, engine: engine, discovery: discovery, device: device)

        box.set("com.airpods.whatever")
        _ = await collect(from: backend, until: { events in
            events.contains { self.isRoutingBlocked($0, true) }
        }, after: { systemVolume.fireExternalChange(volume: nil, muted: nil, defaultDeviceChanged: true) })
        await pollUntil { releaser.calls == 1 }

        let events = await collect(from: backend, until: { events in
            events.contains { self.isRoutingBlocked($0, false) }
        }, after: { backend.reselectAggregateAsDefault() })

        #expect(events.contains { self.isRoutingBlocked($0, false) }, ".stillOurs must flip the warning back off")
        #expect(control.setDefaultCalls == [501, 501], "activation + the button both wrote the aggregate")
        await pollUntil { engine.addedOutputs.filter { $0 == device.outputID }.count >= 2 }
        #expect(engine.addedOutputs.filter { $0 == device.outputID }.count >= 2,
                "the whole-system device is re-kicked (a second addOutput) by the resume")
    }

    /// CASE 7 — the D1 fix: re-picking Audiouter directly in Sound settings (no
    /// button click) resumes identically. The default-device-changed listener's
    /// own `.stillOurs` classification (NativeBackend.swift ~1323-1324) is what
    /// triggers `resumeFromHandoffLocked()` here — NOT `takeOverDefaultAndReflect`
    /// — so, unlike case 6, there is no SECOND `setDefaultOutputDevice` write:
    /// the box simulates the user's own pick having already landed.
    @Test func soundSettingsRepickResumesWithoutTheButton() async {
        let control = FakeAggregateControl(resolvable: [AggregateOutputDevice.productUID: 501])
        let box = LockedBox<String?>("com.other.speakers")
        let releaser = FakeReleaser()
        let (backend, systemVolume, engine, discovery) = makeHandoffBackend(
            aggregateControl: control, currentDefaultOutputUIDBox: box, releaser: releaser)
        backend.start(); defer { backend.stop() }

        let device = handoffDevice()
        await armRouting(backend: backend, engine: engine, discovery: discovery, device: device)

        box.set("com.airpods.whatever")
        _ = await collect(from: backend, until: { events in
            events.contains { self.isRoutingBlocked($0, true) }
        }, after: { systemVolume.fireExternalChange(volume: nil, muted: nil, defaultDeviceChanged: true) })
        await pollUntil { releaser.calls == 1 }

        // NOTE the trap this test caught: the activation write's echo never
        // arrives in this fixture (the deselect above is the next event), so a
        // stale `expectedDefaultWriteUID` would mis-consume this repick as our
        // own echo and skip the D1 resume entirely. The else-arm now disarms the
        // stale pending on any non-matching genuine change.
        box.set(AggregateOutputDevice.productUID)
        let events = await collect(from: backend, until: { events in
            events.contains { self.isRoutingBlocked($0, false) }
        }, after: { systemVolume.fireExternalChange(volume: nil, muted: nil, defaultDeviceChanged: true) })

        #expect(events.contains { self.isRoutingBlocked($0, false) }, "D1: re-picking Audiouter directly must resume too")
        #expect(control.setDefaultCalls == [501], "no second write — the user's own pick is what landed, we never re-wrote it")
        await pollUntil { engine.addedOutputs.filter { $0 == device.outputID }.count >= 2 }
        #expect(engine.addedOutputs.filter { $0 == device.outputID }.count >= 2, "resumed without the button")
    }

    /// CASE 8 — sleep/wake during a handoff release must not silently re-take:
    /// `handleSystemWillSleep` early-returns (`suspended` already true from the
    /// release) and `handleSystemDidWake`'s T3.8-1 guard early-returns (`guard
    /// !self.handoffReleased`) — only a resume affordance may clear
    /// `handoffReleased`.
    @Test func sleepWakeDuringHandoffDoesNotReTake() async {
        let control = FakeAggregateControl(resolvable: [AggregateOutputDevice.productUID: 501])
        let box = LockedBox<String?>("com.other.speakers")
        let releaser = FakeReleaser()
        let (backend, systemVolume, engine, discovery) = makeHandoffBackend(
            aggregateControl: control, currentDefaultOutputUIDBox: box, releaser: releaser)
        backend.start(); defer { backend.stop() }

        let device = handoffDevice()
        await armRouting(backend: backend, engine: engine, discovery: discovery, device: device)

        box.set("com.airpods.whatever")
        _ = await collect(from: backend, until: { events in
            events.contains { self.isRoutingBlocked($0, true) }
        }, after: { systemVolume.fireExternalChange(volume: nil, muted: nil, defaultDeviceChanged: true) })
        await pollUntil { releaser.calls == 1 }

        let addedBefore = engine.addedOutputs.count
        backend.handleSystemWillSleep()
        backend.handleSystemDidWake()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(engine.addedOutputs.count == addedBefore,
                "T3.8-1: a sleep/wake mid-handoff-release must not re-grab the ports — only a resume affordance may")
    }

    /// CASE 9 — watcher lifecycle: started when routing arms, stopped by a
    /// release, restarted by a resume, stopped by `backend.stop()`.
    /// `FakeLogStream.startCount`/`stopCount` trace `AirPlayHandoffWatcher`'s
    /// own `start()`/`stop()` calls (it is a thin pass-through to `spawn`).
    @Test func watcherLifecycleTracksArmReleaseResumeAndStop() async {
        let control = FakeAggregateControl(resolvable: [AggregateOutputDevice.productUID: 501])
        let box = LockedBox<String?>("com.other.speakers")
        let releaser = FakeReleaser()
        let logStream = FakeLogStream()
        let (backend, systemVolume, engine, discovery) = makeHandoffBackend(
            aggregateControl: control, currentDefaultOutputUIDBox: box, releaser: releaser, logStream: logStream)
        backend.start()

        #expect(logStream.startCount == 0, "no routing yet — the watcher must not run")

        let device = handoffDevice()
        await armRouting(backend: backend, engine: engine, discovery: discovery, device: device)
        await pollUntil { logStream.startCount == 1 }
        #expect(logStream.startCount == 1, "routing armed — the watcher starts")

        box.set("com.airpods.whatever")
        _ = await collect(from: backend, until: { events in
            events.contains { self.isRoutingBlocked($0, true) }
        }, after: { systemVolume.fireExternalChange(volume: nil, muted: nil, defaultDeviceChanged: true) })
        await pollUntil { logStream.stopCount == 1 }
        #expect(logStream.stopCount == 1, "the release stops the watcher")

        _ = await collect(from: backend, until: { events in
            events.contains { self.isRoutingBlocked($0, false) }
        }, after: { backend.reselectAggregateAsDefault() })
        await pollUntil { logStream.startCount == 2 }
        #expect(logStream.startCount == 2, "the resume restarts the watcher")

        backend.stop()
        await pollUntil { logStream.stopCount == 2 }
        #expect(logStream.stopCount == 2, "backend.stop() stops the watcher too")
    }

    /// CASE 10 — `stop()` clears handoff state after a release: must not
    /// crash, and force-clears `handoffReleased` + the selection intent so a
    /// fresh `start()` begins clean (NativeBackend.swift ~1538, ~1566).
    @Test func stopClearsHandoffStateAfterARelease() async {
        let control = FakeAggregateControl(resolvable: [AggregateOutputDevice.productUID: 501])
        let box = LockedBox<String?>("com.other.speakers")
        let releaser = FakeReleaser()
        let logStream = FakeLogStream()
        let (backend, systemVolume, engine, discovery) = makeHandoffBackend(
            aggregateControl: control, currentDefaultOutputUIDBox: box, releaser: releaser, logStream: logStream)
        backend.start()

        let device = handoffDevice()
        await armRouting(backend: backend, engine: engine, discovery: discovery, device: device)

        box.set("com.airpods.whatever")
        _ = await collect(from: backend, until: { events in
            events.contains { self.isRoutingBlocked($0, true) }
        }, after: { systemVolume.fireExternalChange(volume: nil, muted: nil, defaultDeviceChanged: true) })
        await pollUntil { releaser.calls == 1 }
        await pollUntil { logStream.stopCount == 1 }   // the release already stopped the watcher

        backend.stop()   // must not crash

        #expect(!backend.test_expectedSelected.contains(device.id),
                "stop() clears the selection intent too — a fresh start() begins clean")
    }
}

} // extension SerializedSharedState

/// The public aggregate is a SYSTEM-WIDE object destroyed by UID on teardown,
/// so its UID must follow the bundle id. Live-found: with one hardcoded UID,
/// quitting a side-by-side test build swept the "Audiouter" output device out
/// of Sound settings while the other copy was still running.
@Suite struct AggregateOutputDeviceIdentityTests {

    @Test func theShippingBundleKeepsItsPersistedUIDAndName() {
        #expect(AggregateOutputDevice.shippingUID == "com.audiouter.Audiouter.aggregate",
                "coreaudiod keys its persisted entry by this exact string — changing it orphans every existing entry")
        #expect(AggregateOutputDevice.shippingBundleID == "com.audiouter.Audiouter")
    }

    /// A side-by-side test build must own a DIFFERENT UID, because
    /// `sweepOrphans()` destroys by UID on teardown — sharing one meant
    /// quitting either copy deleted the other's device.
    @Test func aSideBuildOwnsItsOwnAggregateUID() {
        let sideUID = AggregateOutputDevice.productUID(forBundleID: "com.audiouter.Audiouter.syncv2")
        #expect(sideUID == "com.audiouter.Audiouter.syncv2.aggregate")
        #expect(sideUID != AggregateOutputDevice.shippingUID,
                "a side build must never own the shipping aggregate UID")
    }

    /// An unbundled run (`swift run`) is the same app, so it keeps the
    /// shipping identity rather than inventing a third device.
    @Test func anUnbundledRunKeepsTheShippingUID() {
        #expect(AggregateOutputDevice.productUID(forBundleID: nil)
                == AggregateOutputDevice.shippingUID)
        #expect(AggregateOutputDevice.productUID(forBundleID: "com.audiouter.Audiouter")
                == AggregateOutputDevice.shippingUID)
    }
}
