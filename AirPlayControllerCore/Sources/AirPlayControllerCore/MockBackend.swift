import Foundation

/// An `OutputBackend` with no network and no audio — it fabricates a fleet of
/// devices and behaves the way the real one will, so the entire AppKit UI
/// (menu bar, mixer, groups, sliders, mute, level meters) can be built and
/// iterated with no AirPlay speakers anywhere in sight.
///
/// It deliberately imitates the *awkward* parts of reality, not just the happy
/// path: devices trickle in over a second or two (discovery latency), a mixed
/// fleet includes an AirPlay-1-only device (no perfect sync), and — when asked —
/// devices drop off and reappear so the auto-reconnect / greyed-out UI has
/// something to react to.
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
    private let outputObserver: DefaultOutputObserver?

    /// - Parameters:
    ///   - fleet: the devices to fabricate. Defaults to ``Array/demoFleet``.
    ///   - staggerDiscovery: reveal devices over ~2s instead of all at once,
    ///     so the UI's "populating" state is exercised. Off in tests.
    ///   - emitsLevels: push fake RMS samples for the level meters.
    ///   - simulatesDropouts: periodically drop a device and bring it back, to
    ///     exercise the unavailable/reconnect UI. Off by default (nondeterministic).
    ///   - outputObserver: when provided, tracks the macOS default audio output
    ///     device and renames the local device (`local-mac`) to match reality
    ///     instead of the hardcoded "MacBook Pro Speakers". `nil` by default so
    ///     existing call sites (mainly tests) are unaffected.
    public init(
        fleet: [Device] = .demoFleet,
        staggerDiscovery: Bool = true,
        emitsLevels: Bool = true,
        simulatesDropouts: Bool = false,
        outputObserver: DefaultOutputObserver? = nil
    ) {
        self.fleet = fleet
        self.staggerDiscovery = staggerDiscovery
        self.emitsLevels = emitsLevels
        self.simulatesDropouts = simulatesDropouts
        self.outputObserver = outputObserver
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

            if let observer = self.outputObserver {
                observer.onChange = { [weak self] name in
                    guard let self else { return }
                    self.queue.async { self.updateLocalDeviceName(name) }
                }
                observer.start()
                self.updateLocalDeviceName(observer.currentDeviceName)
            }
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
        outputObserver?.stop()
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
                guard var device = self.live[id] else { continue }
                let shouldSelect = ids.contains(id)
                if device.isSelected != shouldSelect {
                    device.isSelected = shouldSelect
                    self.live[id] = device
                    self.emit(.deviceUpdated(device))
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

    /// Rename the local device (`isLocalDevice == true`) to match the real
    /// macOS default output device. No-op if the local device hasn't been
    /// discovered yet or the name hasn't changed. Must be called on `queue`.
    private func updateLocalDeviceName(_ name: String) {
        guard var device = live.values.first(where: { $0.isLocalDevice }) else { return }
        guard device.name != name else { return }
        device.name = name
        live[device.id] = device
        emit(.deviceUpdated(device))
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
}
