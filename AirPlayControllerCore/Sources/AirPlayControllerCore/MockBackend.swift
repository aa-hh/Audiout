import Foundation

/// Scripted connect choreography for one device, so `MockBackend` can
/// reproduce every `ConnectionState` (including failures and mid-stream
/// drops) offline and deterministically — the mock is the primary dev rig
/// while real speakers are unavailable (`dev/notes/p1-connection-status-brief.md`
/// §5).
///
/// A script is a sequence of attempts: the Nth time the device is enabled
/// (added to `setOutputSet`) uses `attempts[N-1]`; once the sequence is
/// exhausted the last entry repeats, so a device can be retried indefinitely
/// without needing an unbounded array.
public struct ConnectScript: Sendable {

    /// What happens after one `setOutputSet` enable of the scripted device.
    public enum Attempt: Sendable {
        /// Succeeds: `.connecting` for `after` seconds, then `.connected` +
        /// `isSelected = true`.
        case connect(after: TimeInterval)
        /// Fails outright: `.connecting` for `after` seconds, then
        /// `.failed(failure)` + `isSelected = false` (sticky per §1).
        case fail(after: TimeInterval, ConnectionFailure)
        /// Connects, stays up for a while, then drops mid-stream: `.connecting`
        /// → `.connected` + `isSelected = true` after `connectAfter`, then
        /// `.reconnecting` after `dropAfter` more seconds, finally either
        /// `.connected` again (`recovers == true`) or
        /// `.failed(.droppedMidStream)` + `isSelected = false`.
        case connectThenDrop(connectAfter: TimeInterval, dropAfter: TimeInterval, recovers: Bool)
    }

    /// Nth enable of the device uses `attempts[N-1]`; the last entry repeats
    /// once the sequence is exhausted.
    public var attempts: [Attempt]

    public init(attempts: [Attempt]) {
        self.attempts = attempts
    }
}

/// An `OutputBackend` with no network and no audio — it fabricates a fleet of
/// devices and behaves the way the real one will, so the entire AppKit UI
/// (menu bar, mixer, groups, sliders, mute, level meters) can be built and
/// iterated with no AirPlay speakers anywhere in sight.
///
/// It deliberately imitates the *awkward* parts of reality, not just the happy
/// path: devices trickle in over a second or two (discovery latency), a mixed
/// fleet includes an AirPlay-1-only device (no perfect sync), and — when asked —
/// devices drop off and reappear so the auto-reconnect / greyed-out UI has
/// something to react to. `connectScripts` goes further for connection-status
/// work specifically: it lets individual devices fail, retry, or drop
/// mid-stream on a deterministic schedule (see `ConnectScript`).
public final class MockBackend: OutputBackend, @unchecked Sendable {

    // Everything mutable is touched only on this queue. `@unchecked Sendable`
    // is honest because of that discipline, not in spite of it.
    private let queue = DispatchQueue(label: "MockBackend")

    private let fleet: [Device]                 // full intended list, in order
    private var live: [String: Device] = [:]    // discovered so far
    private var continuations: [UUID: AsyncStream<BackendEvent>.Continuation] = [:]
    private var started = false
    private var tick: UInt64 = 0
    private var levelTimer: DispatchSourceTimer?
    private var dropoutTimer: DispatchSourceTimer?

    private let staggerDiscovery: Bool
    private let emitsLevels: Bool
    private let simulatesDropouts: Bool
    private let connectScripts: [String: ConnectScript]

    /// The ids `setOutputSet` currently expects to be routed to — i.e. what
    /// the caller last asked for, independent of whether a scripted device
    /// has actually finished connecting yet. Lets a repeated `setOutputSet`
    /// call with the same ids be a no-op instead of restarting an in-flight
    /// scripted attempt.
    private var expectedSelected: Set<String> = []

    /// How many times each scripted device has been enabled so far (1-based
    /// index into `ConnectScript.attempts`, clamped to the last entry). Only
    /// devices present in `connectScripts` get an entry.
    private var attemptCounts: [String: Int] = [:]
    /// Generation token per device, bumped whenever its choreography restarts
    /// (re-enable, or a new attempt), so stale `asyncAfter` callbacks from a
    /// superseded attempt become no-ops instead of clobbering newer state.
    private var generations: [String: UInt64] = [:]

    /// Fake start buffer for the `LatencyConfigurable` conformance (on `queue`).
    private var fakeStartBufferMs: Int = AppSettings.defaultStartBufferMs

    /// - Parameters:
    ///   - fleet: the devices to fabricate. Defaults to ``Array/demoFleet``.
    ///   - staggerDiscovery: reveal devices over ~2s instead of all at once,
    ///     so the UI's "populating" state is exercised. Off in tests.
    ///   - emitsLevels: push fake RMS samples for the level meters.
    ///   - simulatesDropouts: periodically drop a device and bring it back, to
    ///     exercise the unavailable/reconnect UI. Off by default (nondeterministic).
    ///   - connectScripts: per-device connect choreography, keyed by device
    ///     id. A device absent from this dict keeps the exact pre-existing
    ///     synchronous behaviour (immediate `.connected`/`.off`) — see
    ///     `setOutputSet`.
    public init(
        fleet: [Device] = .demoFleet,
        staggerDiscovery: Bool = true,
        emitsLevels: Bool = true,
        simulatesDropouts: Bool = false,
        connectScripts: [String: ConnectScript] = [:]
    ) {
        self.fleet = fleet
        self.staggerDiscovery = staggerDiscovery
        self.emitsLevels = emitsLevels
        self.simulatesDropouts = simulatesDropouts
        self.connectScripts = connectScripts
        // Seed `expectedSelected` from the fleet's initial `isSelected` so a
        // device that starts selected (e.g. the demo fleet's Sonos speakers)
        // isn't treated as a fresh, un-expected addition the first time
        // `setOutputSet` is called with it still included.
        self.expectedSelected = Set(fleet.filter(\.isSelected).map(\.id))
    }

    // MARK: OutputBackend

    public var devices: [Device] {
        queue.sync { fleet.compactMap { live[$0.id] } }
    }

    public func makeEventStream() -> AsyncStream<BackendEvent> {
        AsyncStream { continuation in
            let key = UUID()
            queue.async { self.continuations[key] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.continuations[key] = nil }
            }
        }
    }

    public func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true

            for (index, device) in self.fleet.enumerated() {
                let delay = self.staggerDiscovery ? 0.2 + Double(index) * 0.35 : 0
                self.queue.asyncAfter(deadline: .now() + delay) {
                    guard self.started, self.live[device.id] == nil else { return }
                    self.live[device.id] = device
                    self.emit(.deviceAdded(device))
                }
            }

            if self.emitsLevels { self.startLevelTimer() }
            if self.simulatesDropouts { self.startDropoutTimer() }
        }
    }

    public func stop() {
        queue.async {
            self.started = false
            self.levelTimer?.cancel(); self.levelTimer = nil
            self.dropoutTimer?.cancel(); self.dropoutTimer = nil
            let ids = Array(self.live.keys)
            self.live.removeAll()
            for id in ids { self.emit(.deviceRemoved(id: id)) }
        }
    }

    public func setVolume(_ volume: Int, for id: String) {
        mutate(id) { $0.volume = volume.clampedToVolume }
    }

    public func setMuted(_ muted: Bool, for id: String) {
        mutate(id) { $0.isMuted = muted }
    }

    public func setOutputSet(_ ids: Set<String>) {
        queue.async {
            for id in self.fleet.map(\.id) {
                guard let device = self.live[id] else { continue }
                let shouldSelect = ids.contains(id)
                guard self.expectedSelected.contains(id) != shouldSelect else { continue }
                if shouldSelect { self.expectedSelected.insert(id) } else { self.expectedSelected.remove(id) }

                if let script = self.connectScripts[id] {
                    if shouldSelect {
                        self.beginScriptedConnect(id, script: script)
                    } else {
                        self.dropFromExpectedSet(id)
                    }
                } else if shouldSelect {
                    // Un-scripted device: exact pre-existing synchronous
                    // behaviour, now also carrying `.connected` in the same
                    // event (brief §5 back-compat requirement).
                    var updated = device
                    updated.isSelected = true
                    updated.connectionState = .connected
                    self.live[id] = updated
                    self.emit(.deviceUpdated(updated))
                } else {
                    var updated = device
                    updated.isSelected = false
                    updated.connectionState = .off
                    self.live[id] = updated
                    self.emit(.deviceUpdated(updated))
                }
            }
        }
    }

    // MARK: Scripted connect choreography (all run on `queue`)

    /// Remove a device from the expected-selected set. Sticky-failed (§1):
    /// if it's currently `.failed`, that state survives — only the selection
    /// bit clears. Otherwise it goes straight to `.off`.
    private func dropFromExpectedSet(_ id: String) {
        guard var device = live[id] else { return }
        generations[id, default: 0] &+= 1   // cancel any in-flight choreography
        let wasFailed = device.connectionState.isFailed
        device.isSelected = false
        device.connectionState = wasFailed ? device.connectionState : .off
        live[id] = device
        emit(.deviceUpdated(device))
    }

    /// Enable of a scripted device: pick the next attempt (retry advances past
    /// an exhausted script only up to its last entry, which then repeats),
    /// move to `.connecting`, and schedule that attempt's outcome.
    private func beginScriptedConnect(_ id: String, script: ConnectScript) {
        guard var device = live[id] else { return }
        guard !script.attempts.isEmpty else { return }

        let count = attemptCounts[id, default: 0] + 1
        attemptCounts[id] = count
        let attempt = script.attempts[min(count, script.attempts.count) - 1]

        let generation = generations[id, default: 0] &+ 1
        generations[id] = generation

        device.isSelected = false   // stays false until verified, per §5
        device.connectionState = .connecting
        live[id] = device
        emit(.deviceUpdated(device))

        switch attempt {
        case .connect(let after):
            scheduleAfter(after, id: id, generation: generation) { [weak self] in
                self?.completeConnect(id, generation: generation)
            }
        case .fail(let after, let failure):
            scheduleAfter(after, id: id, generation: generation) { [weak self] in
                self?.completeFailure(id, generation: generation, failure: failure)
            }
        case .connectThenDrop(let connectAfter, let dropAfter, let recovers):
            scheduleAfter(connectAfter, id: id, generation: generation) { [weak self] in
                guard let self else { return }
                self.completeConnect(id, generation: generation)
                self.scheduleDrop(id, generation: generation, after: dropAfter, recovers: recovers)
            }
        }
    }

    /// Schedule an `asyncAfter` on `queue` guarded by `id`'s generation token,
    /// so a superseded attempt (re-enable, or a subsequent step in the same
    /// attempt) can't clobber newer state.
    private func scheduleAfter(_ delay: TimeInterval, id: String, generation: UInt64, _ work: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generations[id] == generation else { return }
            work()
        }
    }

    private func completeConnect(_ id: String, generation: UInt64) {
        guard generations[id] == generation, var device = live[id] else { return }
        device.isSelected = true
        device.connectionState = .connected
        live[id] = device
        emit(.deviceUpdated(device))
    }

    private func completeFailure(_ id: String, generation: UInt64, failure: ConnectionFailure) {
        guard generations[id] == generation, var device = live[id] else { return }
        device.isSelected = false
        device.connectionState = .failed(failure)
        live[id] = device
        emit(.deviceUpdated(device))
    }

    /// Mid-stream drop for `connectThenDrop`: go `.reconnecting` for ~1.5s,
    /// then either recover to `.connected` or settle on
    /// `.failed(.droppedMidStream)` per the script.
    private func scheduleDrop(_ id: String, generation: UInt64, after dropAfter: TimeInterval, recovers: Bool) {
        scheduleAfter(dropAfter, id: id, generation: generation) { [weak self] in
            guard let self, var device = self.live[id] else { return }
            device.connectionState = .reconnecting
            self.live[id] = device
            self.emit(.deviceUpdated(device))

            self.scheduleAfter(1.5, id: id, generation: generation) { [weak self] in
                guard let self else { return }
                if recovers {
                    self.completeConnect(id, generation: generation)
                } else {
                    self.completeFailure(id, generation: generation, failure: ConnectionFailure(cause: .droppedMidStream))
                }
            }
        }
    }

    // MARK: Internals (all run on `queue`)

    /// Apply a change to one live device and echo a `deviceUpdated`. No-op if the
    /// device hasn't been discovered yet or the change is a no-op.
    private func mutate(_ id: String, _ change: @escaping (inout Device) -> Void) {
        queue.async {
            guard var device = self.live[id] else { return }
            let before = device
            change(&device)
            guard device != before else { return }
            self.live[id] = device
            self.emit(.deviceUpdated(device))
        }
    }

    private func emit(_ event: BackendEvent) {         // must be on `queue`
        for continuation in continuations.values { continuation.yield(event) }
    }

    private func startLevelTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.emitLevels() }
        timer.resume()
        levelTimer = timer
    }

    private func emitLevels() {
        tick &+= 1
        for device in live.values where device.isPlaying {
            // A gentle wobble around the device's volume so meters look alive.
            let seed = Double(abs(device.id.hashValue) % 1000) / 1000.0
            let phase = Double(tick) * 0.35 + seed * 6.28
            let base = Double(device.volume) / 100.0
            let rms = base * (0.55 + 0.45 * abs(sin(phase)))
            emit(.level(id: device.id, rms: Float(min(1, max(0, rms)))))
        }
    }

    private func startDropoutTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 12, repeating: 18)
        timer.setEventHandler { [weak self] in self?.flapOneDevice() }
        timer.resume()
        dropoutTimer = timer
    }

    /// Take one available device offline, then bring it back after a few seconds.
    private func flapOneDevice() {
        let candidates = live.values.filter { $0.isAvailable }
        guard var device = candidates.min(by: { $0.id < $1.id }) else { return }
        // Deterministic pick (lowest id among available) so behaviour is
        // explainable; the *timing* is the only nondeterministic part.
        if candidates.count > 1 {
            device = candidates.sorted { $0.id < $1.id }[Int(tick) % candidates.count]
        }
        device.isAvailable = false
        live[device.id] = device
        emit(.deviceUpdated(device))

        let id = device.id
        queue.asyncAfter(deadline: .now() + 6) {
            guard var back = self.live[id] else { return }
            back.isAvailable = true
            self.live[id] = back
            self.emit(.deviceUpdated(back))
        }
    }
}

private extension Device {
    /// Would this device be producing sound right now? Mirrors the pipeline:
    /// selected + reachable + not muted.
    var isPlaying: Bool {
        isAvailable && isSelected && !isMuted
    }
}

private extension ConnectionState {
    /// Sticky-failed check (brief §1): a `.failed` device counts as still
    /// "expected" even after `isSelected` reverts to false, so
    /// `setOutputSet` removing its id from the requested set is cleanup, not
    /// a fresh drop.
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

public extension MockBackend {

    /// Name of the env var that selects a `connectScripts` scenario for the
    /// mock, resolved by ``resolveScenarioScripts(environment:)``. Currently
    /// the only recognised value is `"connection-demo"`
    /// (`dev/notes/p1-connection-status-brief.md` §5).
    static let scenarioEnvironmentKey = "AIRPLAY_MOCK_SCENARIO"

    /// `connectScripts` for `AIRPLAY_MOCK_SCENARIO=connection-demo`: a script
    /// per demo-fleet device chosen to demo one interesting outcome each —
    /// a first-attempt failure that a retry fixes, a slow connect, and a
    /// mid-stream drop that doesn't recover. Every other device gets a plain
    /// quick connect so the rest of the fleet still behaves normally.
    static func connectionDemoScripts() -> [String: ConnectScript] {
        [
            // First enable fails (visible/not answering) → warning + panel;
            // retrying (2nd attempt) succeeds — demos the retry path.
            "airport-mixer": ConnectScript(attempts: [
                .fail(after: 1.5, ConnectionFailure(cause: .notResponding)),
                .connect(after: 1.0),
            ]),
            // Long spinner before connecting.
            "sonos-move-2": ConnectScript(attempts: [
                .connect(after: 4.0),
            ]),
            // Connects, then drops mid-stream and stays down — demos
            // reconnecting → failed.
            "office": ConnectScript(attempts: [
                .connectThenDrop(connectAfter: 0.8, dropAfter: 8, recovers: false),
            ]),
        ]
    }

    /// Resolve `connectScripts` from an environment dict (defaulting to the
    /// process environment). `AIRPLAY_MOCK_SCENARIO=connection-demo` selects
    /// ``connectionDemoScripts()``, giving every fleet device not explicitly
    /// listed there a plain quick connect so the whole fleet still finishes
    /// connecting. Any other/missing value returns an empty dict (exact
    /// current behaviour — no scripting).
    static func resolveScenarioScripts(
        fleet: [Device] = .demoFleet,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: ConnectScript] {
        guard environment[scenarioEnvironmentKey] == "connection-demo" else { return [:] }
        var scripts = connectionDemoScripts()
        let fallback = ConnectScript(attempts: [.connect(after: 0.8)])
        for device in fleet where scripts[device.id] == nil {
            scripts[device.id] = fallback
        }
        return scripts
    }
}

public extension Array where Element == Device {
    /// A believable home fleet that covers every icon and both AirPlay
    /// generations. Names/kinds echo the real Phase-0 test gear (2× Sonos Move +
    /// an AirPort Express "Mixer" that is AirPlay-1 only) plus a couple more so
    /// the groups UI has enough to work with.
    static var demoFleet: [Device] {
        [
            // The Mac's own output. Not an AirPlay receiver — it is the
            // MainOutTarget.localSpeakers target (passthrough). Starts unselected
            // (it can't join a mixed Selected-Speakers set pre-engine; SPEC §9).
            Device(id: "local-mac",    name: "MacBook Pro Speakers", kind: .localMac,
                   supportsAirPlay2: false, volume: 65, isLocalDevice: true),
            Device(id: "sonos-move",   name: "Sonos Move",    kind: .sonos,          volume: 40, isSelected: true),
            Device(id: "sonos-move-2", name: "Move 2",        kind: .sonos,          volume: 55, isSelected: true),
            Device(id: "airport-mixer", name: "Mixer",        kind: .airportExpress, supportsAirPlay2: false, volume: 30),
            Device(id: "appletv-lr",   name: "Living Room TV", kind: .appleTV,       volume: 60),
            Device(id: "homepod-bed",  name: "Bedroom HomePod", kind: .homePod,      volume: 25),
            Device(id: "office",       name: "Office",        kind: .generic,        volume: 50),
        ]
    }

    /// `demoFleet` PLUS one extra, explicitly-named AP1-only fixture
    /// (T-UI-AP1-1, PLAN-PHASE-2B D6): discovered but `NativeBackend` never
    /// `addOutput`s it — the popover renders it dimmed/disabled with a
    /// "coming soon" explanation on click. A SEPARATE array (not appended to
    /// `demoFleet` itself) so the many existing hardcoded `count == 7`
    /// assertions elsewhere stay untouched; tests that want the AP1-only row
    /// opt in with this fleet instead.
    static var demoFleetWithAP1Only: [Device] {
        demoFleet + [
            Device(id: "attic-ap1", name: "Attic Speaker", kind: .generic,
                   supportsAirPlay2: false, volume: 20),
        ]
    }
}

// MARK: - LatencyConfigurable (fake — UI development without hardware)

/// A FAKE conformance (PLAN-LATENCY-SETTING.md §3, included by design): the
/// mock has no sender, so "apply" just records the value — plus a ~1 s pause
/// when anything is "streaming" so the Settings pane's reconnecting state is
/// visible/exercisable in the default `AIRPLAY_BACKEND=mock` run. No device
/// events are emitted; the real teardown/re-add choreography belongs to
/// `NativeBackend.applyStartBuffer` and is tested there.
extension MockBackend: LatencyConfigurable {

    public var startBufferMs: Int {
        queue.sync { fakeStartBufferMs }
    }

    public func applyStartBuffer(ms: Int) async {
        let streaming = queue.sync { !expectedSelected.isEmpty }
        if streaming {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        queue.sync { fakeStartBufferMs = ms }
    }
}
