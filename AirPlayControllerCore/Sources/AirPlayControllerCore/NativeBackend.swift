import Foundation
import AirPlayEngine

/// The native ``OutputBackend`` (T-NB-BACKEND-1): the app-visible seam that
/// drives the extracted, in-process ``AirPlayEngine`` (an AirPlay-2 sender) plus
/// an app-owned ``NativeDiscovery`` (`NWBrowser` over `_airplay._tcp` /
/// `_raop._tcp`). It presents the *exact same* `BackendEvent`-driven contract as
/// ``OwnToneBackend`` — the UI never learns which backend it's talking to.
///
/// This is a **fresh implementation of the `OwnToneBackend` pattern, NOT a
/// refactor of it**: the two share a protocol, not an implementation shape. What
/// carries over is the *shape* of state ownership (a `known`/`order` map confined
/// to a serial `stateQueue`, `@unchecked Sendable` honest because of that
/// discipline) and the mute-via-stashed-volume shim
/// (`OwnToneBackend.swift:206-220`). What does NOT carry over: the poll loop,
/// zombie detection, HTTP error handling, and FIFO/library-scan machinery — none
/// of it applies to an in-process engine whose completions ARE ground truth.
///
/// ## Where each fact comes from (there is no `GET /api/outputs` to poll)
/// - **Existence / name / kind / AP2-capability / address**: from ``NativeDiscovery``.
///   Discovery owns the colon-hex-TXT-`id` ⟷ ``OutputID`` mapping; this backend
///   just consumes ``DiscoveredDevice`` and NEVER reformats the id.
/// - **Selection**: the app's own intent, driven by `setOutputSet` and realized
///   as engine `addOutput`/`removeOutput` calls.
/// - **Volume / mute**: app-side. The engine has continuous volume only, so mute
///   is the stashed-volume shim; volume maps the UI's 0–100 int onto the engine's
///   0.0–1.0 contract.
/// - **Post-connection liveness**: `engine.makeStateStream()` — every reported
///   `(OutputID, OutputState)` transition (including out-of-band ones that arrive
///   after an op's completion resolved, e.g. a receiver dropping RTSP) becomes a
///   `deviceUpdated`. No polling.
///
/// ## AirPlay 1 (D6)
/// AP1-only receivers ARE discovered and surfaced (dimmed/disabled in the UI):
/// they're emitted `deviceAdded` with `supportsAirPlay2 = false` and
/// `isAvailable = false`, and are **NEVER** `addOutput`-ed (the engine is an
/// AP2-only sender). The future raop (AP1) sender slots in behind
/// ``AirPlay1Sending`` — see the seam comment at the bottom of this file.
public final class NativeBackend: OutputBackend, @unchecked Sendable {

    // MARK: Injected dependencies (protocols so tests are hermetic)

    private let engine: EngineControlling
    private let discovery: DiscoverySource

    /// The in-process capture pipeline (T-NB-CAPTURE-1). When present (the real
    /// path wired by ``makeBackend(_:)``), the backend starts/stops it alongside
    /// its own lifecycle and plumbs its per-buffer RMS into `BackendEvent.level`.
    /// `nil` in tests and the UI-only smoke path — the backend still drives device
    /// state, there's just no audio pipeline behind it.
    ///
    /// Mirrors how ``OwnToneBackend/captureCoordinator`` connects the OwnTone path:
    /// the backend owns the coordinator's lifecycle, the coordinator owns capture.
    /// The one difference is metering — the native coordinator computes RMS on the
    /// captured buffer (upstream of the engine, per playback-meter-research.md) and
    /// hands it back via `onLevel`; the backend fans it out as `.level` for every
    /// currently-selected, unmuted device.
    public var captureCoordinator: NativeCaptureCoordinator?

    // MARK: State (all confined to `stateQueue`)

    // Same discipline as OwnToneBackend/MockBackend: every mutation of the maps
    // below happens on `stateQueue`; `@unchecked Sendable` is honest because of it.
    private let stateQueue = DispatchQueue(label: "NativeBackend.state")
    private var known: [String: Device] = [:]           // last-known snapshot, by id
    private var order: [String] = []                    // stable discovery order
    private var continuations: [UUID: AsyncStream<BackendEvent>.Continuation] = [:]
    private var started = false

    /// The colon-hex `Device.id` ⟷ ``OutputID`` lookup, populated from discovery.
    /// Kept so `setOutputSet`/`setVolume` can translate the UI's string ids to the
    /// engine handle without reparsing (and without ever reformatting the id).
    private var outputIDs: [String: OutputID] = [:]

    /// The set of AP2 device ids the backend has successfully `addOutput`-ed to the
    /// engine (i.e. is currently streaming to). `setOutputSet` diffs against this to
    /// decide which `addOutput`/`removeOutput` calls to issue.
    private var added: Set<String> = []

    /// The raw set of ids the app most recently *asked* to be selected (via
    /// `setOutputSet`), kept for diagnostics/inspection. The actual per-device
    /// convergence target is `desiredOn` (below), which coalesces rapid flips; this
    /// is just the last whole-set request.
    private var expectedSelected: Set<String> = []

    // MARK: Per-device op serialization + coalescing (toggle-spam converge race)
    //
    // The 2026-07-17 gated session wedged a device with rapid enable/disable spam:
    // every `setOutputSet` spawned a fresh detached converge Task that diffed
    // against `added` (which only reflects COMPLETED ops), so N overlapping tasks
    // each re-issued add/removeOutput for the same device — a storm of duplicate
    // "Adding AirPlay device" re-adds racing slow op completions, ending with the
    // UI locked unavailable while a session kept streaming. The fix: coalesce to
    // the LATEST desired state per device and run at most ONE op in flight per
    // device, issuing the next only after the previous completes.

    /// The LATEST desired on/off state per addable device id (coalescing target).
    /// `setOutputSet` overwrites this; a per-device converge loop chases it. Rapid
    /// intermediate flips are dropped — only the final value is ever acted on.
    private var desiredOn: [String: Bool] = [:]

    /// Device ids with a converge op currently in flight. At most one op per id;
    /// a `setOutputSet` for an id already converging just updates `desiredOn` and
    /// lets the running loop pick up the new target when its current op completes.
    private var converging: Set<String> = []

    /// Device ids parked in a terminal-failure state (the engine NACKed / the add
    /// threw). While parked, converge does NOT keep issuing new sessions for the id
    /// (root cause 5: "converge kept issuing sessions post-failure"). The park is
    /// cleared — making the device re-enableable — on the next discovery update or
    /// engine state-stream transition for the id, or by an explicit user re-toggle
    /// to `on` after the in-flight op settled (root cause 4: no permanent wedge).
    private var failedGate: Set<String> = []

    /// App-side mute (Q4): the engine has no mute field, so mute is realized as
    /// volume 0 with the prior value stashed. Same shim as
    /// `OwnToneBackend.swift:206-220`.
    private var muted: Set<String> = []
    private var stashedVolume: [String: Int] = [:]      // pre-mute volume by id

    private var stateStreamTask: Task<Void, Never>?

    // MARK: Init

    /// Public seam: the real native backend over the in-process ``AirPlayEngine``
    /// and a live ``NativeDiscovery`` (`NWBrowser`). `EngineControlling` /
    /// `DiscoverySource` stay internal-facing (tests inject doubles); no engine or
    /// OwnTone type leaks into the public surface.
    public convenience init(engine: AirPlayEngine, discovery: NativeDiscovery = NativeDiscovery()) {
        self.init(engineControl: EngineAdapter(engine: engine), discoverySource: discovery)
    }

    /// Injectable designated initializer (internal — tests pass a spy engine and an
    /// injected discovery double so the whole backend runs with no engine, network,
    /// or TCC).
    init(engineControl: EngineControlling, discoverySource: DiscoverySource) {
        self.engine = engineControl
        self.discovery = discoverySource
    }

    // MARK: OutputBackend

    public var devices: [Device] {
        stateQueue.sync { order.compactMap { known[$0] } }
    }

    public func makeEventStream() -> AsyncStream<BackendEvent> {
        AsyncStream { continuation in
            let key = UUID()
            stateQueue.async {
                self.continuations[key] = continuation
                // Replay the current snapshot so a late subscriber paints
                // immediately (discovery may already have found devices).
                for id in self.order {
                    if let device = self.known[id] { continuation.yield(.deviceAdded(device)) }
                }
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.stateQueue.async { self.continuations[key] = nil }
            }
        }
    }

    public func start() {
        stateQueue.async {
            guard !self.started else { return }
            self.started = true
        }

        // 1. Wire discovery → the app model + the engine descriptor feed. AP2
        //    devices additionally get fed to `engine.updateDiscovery` so the engine
        //    knows about them (a prerequisite for `addOutput`). AP1 devices are
        //    surfaced but never fed to the engine.
        discovery.onEvent = { [weak self] event in self?.handleDiscovery(event) }

        // 2. Start the engine, THEN discovery. The engine's descriptor feed
        //    (`updateDiscovery`) throws `engineNotRunning` until `start()` resolves,
        //    so we gate the discovery start behind it. Discovery events that arrive
        //    before the engine is up would be lost to the engine, so order matters.
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.start()
            } catch {
                // The engine couldn't start — surface every (as-yet-none) known
                // device unavailable and don't start discovery/capture against a
                // dead engine. A later `start()` after `stop()` retries.
                self.markAllUnavailable()
                return
            }

            // 3. Subscribe the engine's device-state stream: every transition
            //    (armed-op terminal AND out-of-band, e.g. RTSP drop → .failed) maps
            //    to a `deviceUpdated`. This is the native analogue of OwnTone's
            //    zombie detection — but push, not poll.
            self.subscribeStateStream()

            // 4. Now safe to browse: resolved AP2 descriptors will land on a running
            //    engine.
            self.discovery.start()

            // 5. Start the capture pipeline (real path only) and fan its RMS into
            //    `.level` for selected, unmuted devices.
            if let coordinator = self.captureCoordinator {
                coordinator.onLevel = { [weak self] rms in self?.emitLevel(rms) }
                coordinator.start()
            }
        }
    }

    public func stop() {
        // Tear down capture first (stop feeding the engine), then discovery, then
        // the engine itself.
        captureCoordinator?.onLevel = nil
        captureCoordinator?.stop()
        discovery.onEvent = nil
        discovery.stop()

        let engine = self.engine
        Task { await engine.stop() }

        stateQueue.async {
            // stateStreamTask is confined to stateQueue (finding 8): a start()
            // immediately followed by stop() would otherwise race the assignment in
            // subscribeStateStream (which now also runs on stateQueue) against this
            // cancellation, leaving the consumer task running against a torn-down
            // backend or interleaving the two writes.
            self.stateStreamTask?.cancel()
            self.stateStreamTask = nil
            self.started = false
            let ids = self.order
            self.known.removeAll()
            self.order.removeAll()
            self.outputIDs.removeAll()
            self.added.removeAll()
            self.expectedSelected.removeAll()
            self.desiredOn.removeAll()
            self.converging.removeAll()
            self.failedGate.removeAll()
            self.fedDescriptors.removeAll()
            self.muted.removeAll()
            self.stashedVolume.removeAll()
            for id in ids { self.emit(.deviceRemoved(id: id)) }
        }
    }

    public func setVolume(_ volume: Int, for id: String) {
        let clamped = volume.clampedToVolume
        stateQueue.async {
            guard let outputID = self.outputIDs[id] else { return }
            // If the device is muted, remember the desired level; unmute restores
            // it. Otherwise push it now. Optimistically echo so the UI is snappy.
            if self.muted.contains(id) {
                self.stashedVolume[id] = clamped
                self.applyLocal(id) { $0.volume = clamped }
            } else {
                self.applyLocal(id) { $0.volume = clamped }
                self.pushVolume(outputID, engineValue: Self.engineVolume(clamped))
            }
        }
    }

    public func setMuted(_ muted: Bool, for id: String) {
        stateQueue.async {
            guard self.muted.contains(id) != muted else { return }
            guard let outputID = self.outputIDs[id] else { return }
            if muted {
                // Mute = volume 0 with the pre-mute value stashed (shim pattern,
                // OwnToneBackend.swift:206-220).
                self.muted.insert(id)
                if self.stashedVolume[id] == nil { self.stashedVolume[id] = self.known[id]?.volume ?? 0 }
                self.applyLocal(id) { $0.isMuted = true; $0.volume = 0 }
                self.pushVolume(outputID, engineValue: Self.engineVolume(0))
            } else {
                self.muted.remove(id)
                self.applyLocal(id) { $0.isMuted = false }
                self.restoreEffectiveVolume(id, outputID: outputID)
            }
        }
    }

    public func setOutputSet(_ ids: Set<String>) {
        // Record the intent and update the per-device coalescing target under the
        // state lock, then kick a per-device converge loop for anything whose
        // desired state actually changed. Rapid toggle spam collapses here: N
        // flips for one device overwrite `desiredOn[id]` N times but issue at most
        // one op at a time (root cause 1) — intermediate flips are simply dropped.
        let toKick: [(id: String, outputID: OutputID)] = stateQueue.sync {
            self.expectedSelected = ids

            // AP1-only devices are NEVER added (D6): only ids we can actually stream
            // to (known, AP2-capable, with an engine handle) can be desired-on.
            var kicks: [(String, OutputID)] = []
            for id in self.order {
                guard let device = self.known[id], device.supportsAirPlay2,
                      let outputID = self.outputIDs[id] else { continue }
                let wantOn = ids.contains(id)

                // A user re-toggle to ON clears a terminal-failure park so the
                // device is re-enableable after a NACK (root cause 4: no permanent
                // wedge). Toggling OFF a parked device likewise clears the park (the
                // device is being deselected — nothing to retry).
                if self.failedGate.contains(id) { self.failedGate.remove(id) }

                let previous = self.desiredOn[id]
                self.desiredOn[id] = wantOn
                // Kick only if the desired changed AND no loop is already running for
                // this id (a running loop re-reads `desiredOn` when its op settles).
                if previous != wantOn, !self.converging.contains(id) {
                    self.converging.insert(id)
                    kicks.append((id, outputID))
                }
            }
            // Ids that vanished from the model but were desired-on: drop their
            // stale target so a re-appearance starts clean.
            for id in Array(self.desiredOn.keys) where self.known[id] == nil {
                self.desiredOn[id] = nil
            }
            return kicks
        }

        for (id, outputID) in toKick {
            Task { [weak self] in
                guard let self else { return }
                await self.convergeDevice(id: id, outputID: outputID)
            }
        }
    }

    // MARK: Per-device serial converge (best-effort, D4; coalesced, root cause 1)

    /// Drive ONE device toward its latest `desiredOn` target, one engine op at a
    /// time. Re-reads the coalesced target after each op completes, so rapid
    /// toggle spam that flipped the target mid-op converges to the FINAL value with
    /// no overlapping add/removeOutput for the same device.
    ///
    /// Invariant on entry: `converging` already contains `id` (the caller claimed
    /// the slot under `stateQueue`). On exit the slot is released.
    ///
    /// D4 best-effort: a failed op marks the device unavailable + parks it in
    /// `failedGate` (so we don't keep issuing sessions post-failure — root cause 5)
    /// and stops the loop; the park is cleared by a later discovery/state update or
    /// a user re-toggle (root cause 4).
    private func convergeDevice(id: String, outputID: OutputID) async {
        defer {
            // Release the in-flight slot. If the target moved again while we were
            // settling (e.g. a flip arrived after our last op but the slot was still
            // held), re-kick so we chase it — the release + re-check is atomic under
            // stateQueue so a concurrent setOutputSet can't slip a kick past us.
            let requeue: OutputID? = stateQueue.sync {
                self.converging.remove(id)
                guard !self.failedGate.contains(id),
                      let want = self.desiredOn[id],
                      let out = self.outputIDs[id],
                      want != self.added.contains(id) else { return nil }
                self.converging.insert(id)
                return out
            }
            if let requeue {
                Task { [weak self] in await self?.convergeDevice(id: id, outputID: requeue) }
            }
        }

        while true {
            // Snapshot the current op to issue from the coalesced target.
            let step: (want: Bool, descriptor: DeviceDescriptor?)? = stateQueue.sync {
                guard !self.failedGate.contains(id), let want = self.desiredOn[id] else { return nil }
                let isOn = self.added.contains(id)
                guard want != isOn else { return nil } // already at target
                return (want, want ? self.lastDescriptors[id] : nil)
            }
            guard let step else { return } // converged (or parked)

            if step.want {
                do {
                    // Feed the engine's discovery before addOutput ONLY when the
                    // engine doesn't already know this descriptor or it changed
                    // (root cause 2: re-feeding an unchanged descriptor every toggle
                    // caused the duplicate "Adding AirPlay device" storm). The first
                    // feed / a genuinely changed descriptor still closes finding 7's
                    // startup race.
                    if let descriptor = self.descriptorToFeed(id: id) {
                        try await engine.updateDiscovery(descriptor)
                        stateQueue.sync { self.fedDescriptors[id] = descriptor }
                    }
                    try await engine.addOutput(outputID)
                    stateQueue.sync {
                        // An out-of-band `.failed` for this id can arrive on the state
                        // stream between addOutput returning and this post-success
                        // write. `applyEngineState` will have set `failedGate` (device
                        // desired-on) and marked the device unavailable/deselected. Do
                        // NOT clobber that failure by force-selecting a dead session:
                        // if the device was parked in the interim, leave it parked and
                        // don't re-add — the failure the engine just reported wins.
                        guard !self.failedGate.contains(id) else { return }
                        self.added.insert(id)
                        self.applyLocal(id) { $0.isSelected = true; $0.isAvailable = true }
                    }
                } catch {
                    // D4: no rollback of anything else. Mark THIS device
                    // unavailable + deselected and PARK it so the loop stops issuing
                    // new sessions post-failure (root cause 5). Recoverable via a
                    // later discovery/state update or a user re-toggle (root cause 4).
                    stateQueue.sync {
                        self.added.remove(id)
                        self.failedGate.insert(id)
                        self.applyLocal(id) { $0.isSelected = false; $0.isAvailable = false }
                    }
                    return
                }
            } else {
                do {
                    try await engine.removeOutput(outputID)
                    stateQueue.sync {
                        self.added.remove(id)
                        self.applyLocal(id) { $0.isSelected = false }
                    }
                } catch {
                    // Removal failed — best-effort: surface unavailable but do NOT
                    // park (a stuck-on session should still be retryable). Drop it
                    // from `added` so the loop can re-issue the stop on the next pass.
                    stateQueue.sync {
                        self.added.remove(id)
                        self.markUnavailable(id)
                    }
                    return
                }
            }
        }
    }

    /// The descriptor to feed the engine before an addOutput, or `nil` if the
    /// engine already knows an identical descriptor for this id (root cause 2:
    /// avoid the per-toggle re-feed storm). On `stateQueue`-read but callable off
    /// it (reads are snapshotted under `sync`).
    private func descriptorToFeed(id: String) -> DeviceDescriptor? {
        stateQueue.sync {
            guard let current = self.lastDescriptors[id] else { return nil }
            if let fed = self.fedDescriptors[id], Self.descriptorsEqual(fed, current) {
                return nil // engine already has this exact descriptor
            }
            return current
        }
    }

    /// The last descriptor actually fed to the engine per id, so a converge can
    /// skip re-feeding an unchanged descriptor (root cause 2). Cleared when the
    /// device disappears / downgrades (the engine descriptor is removed then too).
    private var fedDescriptors: [String: DeviceDescriptor] = [:]

    /// Structural equality for the descriptor fields the engine's discovery feed
    /// actually consumes (`DeviceDescriptor` isn't `Equatable`). If any of these
    /// changed, the engine's registry entry would differ and a re-feed is warranted.
    static func descriptorsEqual(_ a: DeviceDescriptor, _ b: DeviceDescriptor) -> Bool {
        a.name == b.name && a.hostname == b.hostname && a.address == b.address
            && sameFamily(a.family, b.family) && a.port == b.port && a.txtRecord == b.txtRecord
    }

    /// `AddressFamily` isn't `Equatable` in the engine's public surface (and we
    /// don't own it), so compare the two cases explicitly.
    private static func sameFamily(_ a: AddressFamily, _ b: AddressFamily) -> Bool {
        switch (a, b) {
        case (.ipv4, .ipv4), (.ipv6, .ipv6): return true
        default: return false
        }
    }

    // MARK: Discovery → app model (all on stateQueue)

    private func handleDiscovery(_ event: DiscoveryEvent) {
        switch event {
        case .appeared(let discovered):
            feedEngineIfAP2(discovered, appearing: true)
            stateQueue.async { self.addOrUpdate(discovered) }
        case .updated(let discovered):
            if discovered.isAirPlay2Supported {
                feedEngineIfAP2(discovered, appearing: true)
            } else {
                // AP2 → AP1 downgrade: the device lost its `_airplay._tcp` advert
                // but is still on the network (raop-only). It is NOT `.disappeared`,
                // so the removal path below never runs otherwise — tear down any
                // live engine session/registration so we don't leak a live RTSP/PTP
                // session and a stale engine descriptor while the UI flips it to
                // unavailable. Safe/idempotent if it was never AP2 or never added.
                teardownEngineOutput(id: discovered.id)
                removeEngineDiscovery(id: discovered.id)
            }
            stateQueue.async { self.addOrUpdate(discovered) }
        case .disappeared(let id, let wasAirPlay2Supported):
            if wasAirPlay2Supported {
                teardownEngineOutput(id: id)
                removeEngineDiscovery(id: id)
            }
            stateQueue.async { self.markDisappeared(id) }
        }
    }

    /// Stop and drop any live engine session for `id` (if it was streaming). Used
    /// on an AP2→AP1 downgrade and on disappearance so a device leaving the AP2
    /// world doesn't leak its RTSP/PTP session. Best-effort — a failed removeOutput
    /// is swallowed (the descriptor removal that follows deregisters it anyway).
    private func teardownEngineOutput(id: String) {
        let outputID: OutputID? = stateQueue.sync {
            // A future re-add must re-feed the engine's discovery (the descriptor is
            // being deregistered), so forget the fed memo regardless of add state.
            self.fedDescriptors[id] = nil
            guard self.added.contains(id) else { return nil }
            self.added.remove(id)
            return self.outputIDs[id]
        }
        guard let outputID else { return }
        let engine = self.engine
        Task { try? await engine.removeOutput(outputID) }
    }

    /// Feed an AP2 device into the engine's discovery so it becomes `addOutput`-able.
    /// AP1-only devices are NEVER fed (D6) — the engine is an AP2-only sender.
    ///
    /// This is the DISCOVERY-driven feed (fires on genuine appear/update events,
    /// not per toggle). It records what it fed into `fedDescriptors` so the
    /// converge path's `descriptorToFeed` can skip a redundant re-feed of the exact
    /// same descriptor (root cause 2). Only feeds when the descriptor is new or
    /// changed, so a repeated identical `.updated` doesn't re-add either.
    private func feedEngineIfAP2(_ discovered: DiscoveredDevice, appearing: Bool) {
        guard discovered.isAirPlay2Supported else { return }
        let descriptor = discovered.descriptor
        let id = discovered.id
        let shouldFeed: Bool = stateQueue.sync {
            if let fed = self.fedDescriptors[id], Self.descriptorsEqual(fed, descriptor) {
                return false
            }
            return true
        }
        guard shouldFeed else { return }
        let engine = self.engine
        Task { [weak self] in
            do {
                try await engine.updateDiscovery(descriptor)
                self?.stateQueue.sync { self?.fedDescriptors[id] = descriptor }
            } catch { /* engine not up yet; converge will feed before addOutput */ }
        }
    }

    private func removeEngineDiscovery(id: String) {
        // We only kept the last descriptor on the Device model indirectly; the
        // engine matches removal on the descriptor's name, so rebuild a minimal
        // descriptor from what discovery told us is gone. Discovery already dropped
        // it from its own map, so we reconstruct from our stashed descriptor.
        let descriptor = stateQueue.sync { self.lastDescriptors[id] }
        guard let descriptor else { return }
        let engine = self.engine
        Task { await engine.removeDiscovery(descriptor) }
    }

    /// The last engine descriptor seen per AP2 device id, so a `disappeared` can
    /// call `engine.removeDiscovery` (which matches on the descriptor name).
    private var lastDescriptors: [String: DeviceDescriptor] = [:]

    /// Add a newly-discovered device or fold an update into the existing snapshot.
    /// On `stateQueue`.
    private func addOrUpdate(_ discovered: DiscoveredDevice) {
        let id = discovered.id                        // colon-hex TXT id, verbatim
        self.outputIDs[id] = discovered.outputID
        if discovered.isAirPlay2Supported {
            self.lastDescriptors[id] = discovered.descriptor
            // Availability recovery (root cause 4): a fresh AP2 (re-)resolution is
            // evidence the device is reachable again, so clear any terminal-failure
            // park — the device becomes re-enableable on the next user toggle (or,
            // if it's still desired-on, the loop below re-kicks it).
            self.failedGate.remove(id)
        } else {
            self.lastDescriptors[id] = nil
            // The AP2 advert is gone: the engine descriptor will be removed, so a
            // future re-add must re-feed. Drop the fed-descriptor memo.
            self.fedDescriptors[id] = nil
        }

        let mapped = mapDiscovered(discovered)
        if let existing = known[id] {
            let merged = merge(existing: existing, discovered: mapped)
            if merged != existing {
                known[id] = merged
                emit(.deviceUpdated(merged))
            }
        } else {
            // AP1-only devices (D6): surfaced deviceAdded, isAvailable=false,
            // supportsAirPlay2=false, and NEVER addOutput-ed. mapDiscovered already
            // set those fields; here we just append + emit.
            known[id] = mapped
            order.append(id)
            emit(.deviceAdded(mapped))
        }

        // Availability recovery (root cause 4): if this device is still desired-on
        // but isn't streaming and no op is in flight (e.g. it just recovered from a
        // failure park cleared above, or re-appeared after dropping), re-kick the
        // converge loop so the intended selection is retried without a user toggle.
        if discovered.isAirPlay2Supported,
           self.desiredOn[id] == true,
           !self.added.contains(id),
           !self.converging.contains(id),
           !self.failedGate.contains(id),
           let outputID = self.outputIDs[id] {
            self.converging.insert(id)
            Task { [weak self] in await self?.convergeDevice(id: id, outputID: outputID) }
        }
    }

    /// A device dropped off the network. It stays in the model as unavailable (so a
    /// saved group keeps its membership); it is removed from the streaming set.
    /// On `stateQueue`.
    private func markDisappeared(_ id: String) {
        self.added.remove(id)
        // The engine descriptor is deregistered on disappear; a future re-add must
        // re-feed it. Clear the fed memo so `descriptorToFeed` doesn't skip it.
        self.fedDescriptors[id] = nil
        guard var device = known[id] else { return }
        var changed = false
        if device.isAvailable { device.isAvailable = false; changed = true }
        if device.isSelected { device.isSelected = false; changed = true }
        if changed {
            known[id] = device
            emit(.deviceUpdated(device))
        }
    }

    // MARK: Engine state stream → deviceUpdated (push, no poll)

    private func subscribeStateStream() {
        let stream = engine.makeStateStream()
        let task = Task { [weak self] in
            for await (outputID, state) in stream {
                guard let self else { return }
                self.applyEngineState(outputID: outputID, state: state)
            }
        }
        // Confine stateStreamTask to stateQueue (finding 8). If stop() already ran
        // (started == false), don't stash the task — cancel it right away so a
        // start→stop race can't leave a live consumer against a torn-down backend.
        stateQueue.async {
            if self.started {
                self.stateStreamTask = task
            } else {
                task.cancel()
            }
        }
    }

    /// Fold an out-of-band engine state transition into the model. The stream may
    /// re-report an op's terminal state (the completion bridge resolves the awaited
    /// call FIRST, then the stream yields the same transition — STATE STREAM agent's
    /// contract), so we diff against the last-known device before emitting to
    /// de-dupe. On `stateQueue`.
    private func applyEngineState(outputID: OutputID, state: OutputState) {
        // A good transition (.streaming/.connected) for a device the user has since
        // turned OFF must NOT re-wedge it ON — instead re-kick converge to tear the
        // stale session down. We compute any needed re-kick under the lock and fire
        // it after releasing it (convergeDevice takes the lock itself).
        let rekick: (id: String, outputID: OutputID)? = stateQueue.sync {
            // Find the string id for this engine handle (discovery owns the mapping).
            guard let id = self.outputIDs.first(where: { $0.value == outputID })?.key,
                  var device = self.known[id] else { return nil }

            let before = device
            switch state {
            case .streaming, .connected:
                // Reconcile against the user's latest intent. If the device is
                // desired OFF (a toggle-OFF that raced this queued good transition),
                // do NOT insert `added` / select it — that would re-wedge a device
                // the user just turned off, streaming with no converge scheduled
                // (the state stream is not a converge re-kick site). Instead claim
                // the converging slot (if free) and re-kick so the loop tears the
                // stale session down. If it's already converging, the running loop
                // will chase `desiredOn` when its current op settles — nothing to do.
                if self.desiredOn[id] == false {
                    let out = self.outputIDs[id]
                    if let out, !self.converging.contains(id), self.added.contains(id) {
                        self.converging.insert(id)
                        return (id, out)
                    }
                    return nil
                }
                device.isAvailable = true
                device.isSelected = true
                self.added.insert(id)
                // Recovery (root cause 4): a good transition clears any failure
                // park so the device is re-enableable / stays converged.
                self.failedGate.remove(id)
            case .failed, .passwordRequired:
                // A live session died / needs a PIN we don't have: surface it as
                // unavailable + deselected and drop it from the streaming set. PARK
                // it (root cause 5) so converge doesn't immediately re-issue a
                // session against a receiver that just failed — the park is cleared
                // by the next discovery/good-state transition or a user re-toggle.
                device.isAvailable = false
                device.isSelected = false
                self.added.remove(id)
                if self.desiredOn[id] == true { self.failedGate.insert(id) }
            case .stopped:
                device.isSelected = false
                self.added.remove(id)
            case .startup:
                return nil // non-terminal progress; nothing to render yet
            }
            guard device != before else { return nil }   // de-dupe the completion echo
            self.known[id] = device
            self.emit(.deviceUpdated(device))
            return nil
        }
        if let rekick {
            Task { [weak self] in await self?.convergeDevice(id: rekick.id, outputID: rekick.outputID) }
        }
    }

    // MARK: Mapping + merge

    /// Map a ``DiscoveredDevice`` onto a ``Device``, folding in app-side mute state.
    private func mapDiscovered(_ discovered: DiscoveredDevice) -> Device {
        let id = discovered.id
        let isMuted = muted.contains(id)
        let supportsAP2 = discovered.isAirPlay2Supported
        // AP1-only devices are surfaced but never controllable: available=false
        // (dimmed/disabled in the UI), and NEVER addOutput-ed (D6).
        let isAvailable = supportsAP2
        let baseVolume = known[id]?.volume ?? 50
        return Device(
            id: id,
            name: discovered.descriptor.name,
            kind: Self.kind(for: discovered),
            isAvailable: isAvailable,
            supportsAirPlay2: supportsAP2,
            // If muted app-side, show the stashed (intended) level so the slider
            // doesn't jump to 0 under the user.
            volume: isMuted ? (stashedVolume[id] ?? baseVolume) : baseVolume,
            isMuted: isMuted,
            isSelected: added.contains(id)
        )
    }

    /// Merge a freshly-discovered device with the existing snapshot: take
    /// discovery's truth for name/kind/AP2, but preserve the app-side control state
    /// (volume/mute/selection) and the availability we derive from engine sessions.
    private func merge(existing: Device, discovered: Device) -> Device {
        var result = existing
        result.name = discovered.name
        result.kind = discovered.kind
        result.supportsAirPlay2 = discovered.supportsAirPlay2
        // AP1 devices can never become available; an AP2 device that re-resolved is
        // reachable again (a dropped→returned device comes back available).
        if discovered.supportsAirPlay2 {
            result.isAvailable = true
        } else {
            result.isAvailable = false
            result.isSelected = false
        }
        return result
    }

    /// Heuristic device kind. The TXT `model` key is BETTER signal than a name
    /// substring (`OwnToneBackend.kind` name-sniffs because OwnTone exposes no
    /// model); we prefer it and fall back to the service name.
    static func kind(for discovered: DiscoveredDevice) -> Device.Kind {
        let txt = discovered.descriptor.txtRecord
        let model = (txt["model"] ?? txt["Model"] ?? "").lowercased()
        let name = discovered.descriptor.name.lowercased()
        let hay = model + " " + name
        if hay.contains("homepod") { return .homePod }
        if hay.contains("appletv") || hay.contains("apple tv") || name.contains(" tv") || name.hasSuffix("tv") { return .appleTV }
        if hay.contains("airport") || hay.contains("express") { return .airportExpress }
        if hay.contains("sonos") || hay.contains("move") || hay.contains("roam") { return .sonos }
        return .generic
    }

    // MARK: Volume mapping (UI 0–100 → engine 0.0–1.0)

    /// Map the UI's 0–100 int onto the engine's `setVolume(_:_:)` contract, which
    /// takes a normalized 0.0…1.0 double (the engine then maps 0…1 onto the AirPlay
    /// 0–100 percent → −30…0 dB internally, per `AirPlayEngine.setVolume`). `.level`
    /// / perceptual-curve fidelity is a gated real-hardware A/B (D7), not headless.
    static func engineVolume(_ uiVolume: Int) -> Double {
        Double(uiVolume.clampedToVolume) / 100.0
    }

    /// Push a volume to the engine off-queue (the engine op is async). Failures are
    /// non-fatal (volume completions don't gate anything) — swallowed, the next
    /// state event / user action reconciles.
    private func pushVolume(_ outputID: OutputID, engineValue: Double) {
        let engine = self.engine
        Task { try? await engine.setVolume(outputID, engineValue) }
    }

    // MARK: Local optimistic updates + availability (on stateQueue)

    private func applyLocal(_ id: String, _ change: (inout Device) -> Void) {   // on stateQueue
        guard var device = known[id] else { return }
        let before = device
        change(&device)
        guard device != before else { return }
        known[id] = device
        emit(.deviceUpdated(device))
    }

    private func markUnavailable(_ id: String) {   // on stateQueue
        applyLocal(id) { if $0.isAvailable { $0.isAvailable = false } }
    }

    private func markAllUnavailable() {
        stateQueue.async {
            for id in self.order { self.markUnavailable(id) }
        }
    }

    /// Recompute the effective (wire) volume after an unmute: push the stashed
    /// intended level and echo it locally. Mirrors
    /// `OwnToneBackend.restoreEffectiveVolume`. On `stateQueue`.
    private func restoreEffectiveVolume(_ id: String, outputID: OutputID) {   // on stateQueue
        let intended = stashedVolume[id] ?? known[id]?.volume ?? 0
        stashedVolume[id] = nil
        applyLocal(id) { $0.volume = intended }
        pushVolume(outputID, engineValue: Self.engineVolume(intended))
    }

    // MARK: Level pass-through

    /// Fan a capture-side RMS sample out as `.level` for every currently-selected,
    /// unmuted device (the meter is a property of the captured audio, identical for
    /// every fanned-out device — playback-meter-research.md). On `stateQueue`.
    private func emitLevel(_ rms: Float) {
        stateQueue.async {
            for id in self.order {
                guard let device = self.known[id], device.isSelected, !device.isMuted else { continue }
                self.emit(.level(id: id, rms: rms))
            }
        }
    }

    // MARK: Emit

    private func emit(_ event: BackendEvent) {   // on stateQueue
        for continuation in continuations.values { continuation.yield(event) }
    }
}

// MARK: - Injected seams (engine + discovery, so the backend is hermetic)

/// The slice of ``AirPlayEngine`` ``NativeBackend`` drives. Extracted as a
/// protocol so tests inject a spy that records ops and fires synthetic state
/// transitions with no engine thread, C cluster, or hardware. The real
/// ``AirPlayEngine`` conforms via ``EngineAdapter``.
///
/// Every method mirrors the engine's public surface 1:1 (see `AirPlayEngine.swift`).
protocol EngineControlling: Sendable {
    func start() async throws
    func stop() async
    @discardableResult
    func updateDiscovery(_ descriptor: DeviceDescriptor) async throws -> OutputID
    func removeDiscovery(_ descriptor: DeviceDescriptor) async
    func addOutput(_ id: OutputID) async throws
    func removeOutput(_ id: OutputID) async throws
    func setVolume(_ id: OutputID, _ volume: Double) async throws
    func makeStateStream() -> AsyncStream<(OutputID, OutputState)>
}

/// Adapts the concrete ``AirPlayEngine`` actor to ``EngineControlling``. Thin —
/// every call forwards straight through (the engine's own actor isolation + engine
/// thread do the real serialization).
struct EngineAdapter: EngineControlling {
    let engine: AirPlayEngine

    func start() async throws { try await engine.start() }
    func stop() async { await engine.stop() }
    @discardableResult
    func updateDiscovery(_ descriptor: DeviceDescriptor) async throws -> OutputID {
        try await engine.updateDiscovery(descriptor)
    }
    func removeDiscovery(_ descriptor: DeviceDescriptor) async { await engine.removeDiscovery(descriptor) }
    func addOutput(_ id: OutputID) async throws { try await engine.addOutput(id) }
    func removeOutput(_ id: OutputID) async throws { try await engine.removeOutput(id) }
    func setVolume(_ id: OutputID, _ volume: Double) async throws { try await engine.setVolume(id, volume) }
    func makeStateStream() -> AsyncStream<(OutputID, OutputState)> { engine.makeStateStream() }
}

/// The slice of ``NativeDiscovery`` ``NativeBackend`` drives. Extracted as a
/// protocol so tests feed `DiscoveryEvent`s synchronously with no `NWBrowser`,
/// network, or TCC. The real ``NativeDiscovery`` conforms directly.
protocol DiscoverySource: AnyObject, Sendable {
    var onEvent: (@Sendable (DiscoveryEvent) -> Void)? { get set }
    func start()
    func stop()
}

extension NativeDiscovery: DiscoverySource {}

// MARK: - Seam for the future AirPlay 1 (raop) sender (D6)
//
// AP1-only receivers are DISCOVERED and SURFACED today (dimmed/disabled, per D6),
// but the engine is an AirPlay-2-only sender, so `NativeBackend` NEVER calls
// `engine.addOutput` for them — it emits them `deviceAdded` with
// `supportsAirPlay2 = false` / `isAvailable = false` and leaves them there.
//
// The next iteration (D1: "AP1 (raop.c) sender port: deferred to the NEXT
// iteration, first in line") adds a classic-AirPlay sender. When it lands, it slots
// in behind THIS protocol, parallel to how the AP2 path uses `EngineControlling`:
// `NativeBackend` would hold an optional `AirPlay1Sending`, route AP1 ids in
// `setOutputSet.converge` to it instead of the engine, flip AP1 devices'
// `isAvailable`/`supportsAirPlay2` handling, and fold its own state transitions
// into the same `deviceUpdated` path. The shape below is intentionally identical to
// the AP2 primitives so `converge` can dispatch on device kind without a second
// convergence engine.
//
// NOTE: this is a seam only — there is NO implementation and NO conformance in this
// iteration. It exists so the wiring point is explicit and the next task has a
// contract to fill rather than a redesign.
protocol AirPlay1Sending: Sendable {
    /// Begin streaming to an AP1 receiver, resolved from its colon-hex device id
    /// (the same `Device.id` string the AP2 path keys on — never reformatted).
    func addOutput(deviceID: String, descriptor: DeviceDescriptor) async throws
    /// Stop streaming to an AP1 receiver.
    func removeOutput(deviceID: String) async throws
    /// Set volume 0.0…1.0 on an AP1 receiver (classic AirPlay volume model).
    func setVolume(deviceID: String, _ volume: Double) async throws
}
