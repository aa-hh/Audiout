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
public final class NativeBackend: OutputBackend, LatencyConfigurable, @unchecked Sendable {

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

    /// The set of ids the app most recently *asked* to be selected (via
    /// `setOutputSet`). The convergence target; `added` chases it best-effort (D4).
    private var expectedSelected: Set<String> = []

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
        // Snapshot the target + the engine handles / AP2-eligibility under the
        // state lock, then converge off-queue via the engine's async ops.
        let plan: (toAdd: [(String, OutputID, DeviceDescriptor?)], toRemove: [(String, OutputID)]) = stateQueue.sync {
            self.expectedSelected = ids

            // AP1-only devices are NEVER added (D6): filter the target to the ids we
            // can actually stream to (known, AP2-capable, with an engine handle).
            let addable = ids.filter { id in
                guard let device = self.known[id] else { return false }
                return device.supportsAirPlay2 && self.outputIDs[id] != nil
            }

            let toAddIDs = addable.subtracting(self.added)
            let toRemoveIDs = self.added.subtracting(addable)

            // Carry the last-known descriptor for each add so converge can (re-)feed
            // the engine's discovery immediately before addOutput — closing the race
            // where the async `updateDiscovery` feed hasn't resolved yet and
            // addOutput would throw `unknownOutput` (finding 7).
            let toAdd = toAddIDs.compactMap { id in
                self.outputIDs[id].map { (id, $0, self.lastDescriptors[id]) }
            }
            let toRemove = toRemoveIDs.compactMap { id in self.outputIDs[id].map { (id, $0) } }
            return (toAdd, toRemove)
        }

        Task { [weak self] in
            guard let self else { return }
            await self.converge(toAdd: plan.toAdd, toRemove: plan.toRemove)
        }
    }

    // MARK: setOutputSet convergence (best-effort, D4)

    /// Diff-and-converge over the engine's per-device `addOutput`/`removeOutput`
    /// primitives (there is no atomic "replace the whole set" like OwnTone's
    /// `outputs/set`). **Best-effort partial failure (D4): apply what succeeds, mark
    /// the failed device unavailable, emit `deviceUpdated` — no rollback.** A group
    /// activation that half-fails leaves an accurate mixed state, which the UI
    /// already tolerates.
    ///
    /// The engine marshals all C calls onto one thread, so issuing these
    /// concurrently is non-blocking but not wall-clock parallel; we issue them
    /// sequentially for a simple, deterministic best-effort story (removals first so
    /// a swap frees the old session before the new one arms).
    private func converge(toAdd: [(id: String, outputID: OutputID, descriptor: DeviceDescriptor?)],
                          toRemove: [(id: String, outputID: OutputID)]) async {
        for (id, outputID) in toRemove {
            do {
                try await engine.removeOutput(outputID)
                stateQueue.sync {
                    self.added.remove(id)
                    self.applyLocal(id) { $0.isSelected = false }
                }
            } catch {
                // Removal failed — best-effort: leave it in `added`/selected (it may
                // still be streaming) and surface it as unavailable so the UI shows
                // the failure rather than a silent wrong state.
                stateQueue.sync { self.markUnavailable(id) }
            }
        }

        for (id, outputID, descriptor) in toAdd {
            do {
                // Feed the engine's discovery immediately before addOutput and await
                // it, so the engine is guaranteed to know this device even if the
                // fire-and-forget `updateDiscovery` from handleDiscovery hasn't
                // resolved yet (finding 7: otherwise addOutput throws unknownOutput
                // and the device is wrongly surfaced as failed). `updateDiscovery` is
                // idempotent — re-feeding an already-known descriptor just updates it.
                if let descriptor { try await engine.updateDiscovery(descriptor) }
                try await engine.addOutput(outputID)
                stateQueue.sync {
                    self.added.insert(id)
                    self.applyLocal(id) {
                        $0.isSelected = true
                        // A successful add proves the device is reachable.
                        $0.isAvailable = true
                    }
                }
            } catch {
                // D4: the add failed — DON'T roll back the ones that succeeded. Mark
                // just this device unavailable + not selected and emit deviceUpdated.
                stateQueue.sync {
                    self.added.remove(id)
                    self.applyLocal(id) { $0.isSelected = false; $0.isAvailable = false }
                }
            }
        }
    }

    // MARK: LatencyConfigurable (PLAN-LATENCY-SETTING.md)

    /// The sender start buffer currently in force (ms). Seeded by
    /// `makeBackend` from the resolved launch value (env → setting → default);
    /// updated by ``applyStartBuffer(ms:)``. Confined to `stateQueue`.
    private var _startBufferMs: Int = 1000

    public var startBufferMs: Int {
        stateQueue.sync { _startBufferMs }
    }

    /// Seed the initial value without triggering an apply (`makeBackend` only —
    /// the engine was just constructed with this same value in its config).
    func seedStartBufferMs(_ ms: Int) {
        stateQueue.sync { _startBufferMs = ms }
    }

    /// Apply a new start buffer at runtime. The vendored sender reads the value
    /// at STREAM-SESSION creation and caches it in the (shared) master session,
    /// so the sequence below is an invariant, not a style choice:
    ///
    /// 1. Remove ALL currently-streaming outputs and AWAIT each removal — if
    ///    even one stays attached, the old master session (old buffer) survives
    ///    and step 3's re-adds would join it, silently keeping the old latency.
    /// 2. Set the new value on the engine (next master session reads it).
    /// 3. Re-add the same set, re-feeding each descriptor first (same
    ///    finding-7 guard as `converge`) and re-pushing each device's effective
    ///    volume (mute = stashed-0, same shim as everywhere else).
    ///
    /// Failures follow D4 best-effort: a device that won't come back is marked
    /// unavailable + deselected and the rest proceed. A concurrent
    /// `setOutputSet` during the gap converges on `expectedSelected` as usual —
    /// worst case the user's newer intent wins, which is the right outcome.
    /// With nothing streaming this reduces to step 2 and is silent/instant.
    public func applyStartBuffer(ms: Int) async {
        // Snapshot the streaming set + per-device control state under the lock.
        let snapshot: [(id: String, outputID: OutputID, descriptor: DeviceDescriptor?,
                        volume: Int, isMuted: Bool)] = stateQueue.sync {
            self._startBufferMs = ms
            return self.added.compactMap { id in
                guard let outputID = self.outputIDs[id] else { return nil }
                let device = self.known[id]
                let stashed = self.stashedVolume[id]
                return (id, outputID, self.lastDescriptors[id],
                        stashed ?? device?.volume ?? 50, self.muted.contains(id))
            }
        }

        // 1. Remove ALL streaming outputs, awaited (see invariant above). A
        // failed removal is treated as removed — the session is torn down on
        // the next engine op either way, and re-adding below re-establishes it.
        for item in snapshot {
            try? await engine.removeOutput(item.outputID)
            stateQueue.sync { self.added.remove(item.id) }
        }

        // 2. New buffer value; the next master session picks it up.
        await engine.setStartBufferMs(ms)

        // 3. Re-add the same set (best-effort, D4), restoring volume/mute.
        for item in snapshot {
            do {
                if let descriptor = item.descriptor {
                    try await engine.updateDiscovery(descriptor)
                }
                try await engine.addOutput(item.outputID)
                stateQueue.sync {
                    self.added.insert(item.id)
                    self.applyLocal(item.id) { $0.isSelected = true; $0.isAvailable = true }
                }
                let effective = item.isMuted ? 0 : item.volume
                try? await engine.setVolume(item.outputID, Self.engineVolume(effective))
            } catch {
                stateQueue.sync {
                    self.added.remove(item.id)
                    self.applyLocal(item.id) { $0.isSelected = false; $0.isAvailable = false }
                }
            }
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
    private func feedEngineIfAP2(_ discovered: DiscoveredDevice, appearing: Bool) {
        guard discovered.isAirPlay2Supported else { return }
        let engine = self.engine
        let descriptor = discovered.descriptor
        Task { try? await engine.updateDiscovery(descriptor) }
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
        } else {
            self.lastDescriptors[id] = nil
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
    }

    /// A device dropped off the network. It stays in the model as unavailable (so a
    /// saved group keeps its membership); it is removed from the streaming set.
    /// On `stateQueue`.
    private func markDisappeared(_ id: String) {
        self.added.remove(id)
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
        stateQueue.sync {
            // Find the string id for this engine handle (discovery owns the mapping).
            guard let id = self.outputIDs.first(where: { $0.value == outputID })?.key,
                  var device = self.known[id] else { return }

            let before = device
            switch state {
            case .streaming, .connected:
                device.isAvailable = true
                device.isSelected = true
                self.added.insert(id)
            case .failed, .passwordRequired:
                // A live session died / needs a PIN we don't have: surface it as
                // unavailable + deselected and drop it from the streaming set.
                device.isAvailable = false
                device.isSelected = false
                self.added.remove(id)
            case .stopped:
                device.isSelected = false
                self.added.remove(id)
            case .startup:
                return // non-terminal progress; nothing to render yet
            }
            guard device != before else { return }   // de-dupe the completion echo
            self.known[id] = device
            self.emit(.deviceUpdated(device))
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
    func setStartBufferMs(_ ms: Int) async
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
    func setStartBufferMs(_ ms: Int) async { await engine.setStartBufferMs(ms) }
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
