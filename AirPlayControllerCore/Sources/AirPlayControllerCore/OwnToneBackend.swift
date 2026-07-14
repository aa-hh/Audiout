import Foundation

/// The real ``OutputBackend``: drives OwnTone's JSON API (`:3689`) for the
/// outputs list / selection / volume, and mirrors OwnTone's state into the UI
/// via the same `BackendEvent` stream the mock uses. The UI never learns which
/// backend it's talking to.
///
/// **State sync is poll-primary.** `dev/notes/p1-owntone-api-brief.md` §3 found
/// that OwnTone 29.2's websocket push never fired in 4/4 live runs, so this
/// backend polls `GET /api/outputs` + `GET /api/player` every 1 s, diffs against
/// the last-known snapshot, and emits `deviceAdded`/`deviceUpdated`/
/// `deviceRemoved` on change. The websocket (`:3688`, `notify` subprotocol) is a
/// best-effort accelerant only: if a frame ever arrives it triggers an immediate
/// out-of-band poll, but nothing is gated on it.
///
/// Hard-won invariants from the brief that shape this type:
/// - **Silent select failure** (brief §1/§4): `PUT /api/outputs/set` returns
///   `204` even when the selection didn't stick. After every `setOutputSet` we
///   re-GET and confirm; a mismatch triggers zombie recovery.
/// - **Zombie de-selection** (brief §4): a previously-selected output flipping
///   to `selected:false` on a poll — without the app having asked — is a silent
///   drop. Recovery = re-select once (+ the coordinator's clear→add→play, wired
///   via ``replayHook``); if it still fails, surface the device as unavailable
///   (a device-level error state) and stop retrying.
/// - **Connect-only** (Q7, brief §5): connection-refused → mark everything
///   unavailable, keep polling at a backed-off interval, NEVER start/supervise
///   the server.
///
/// No capture/FIFO here — that's T-C2's `CaptureCoordinator`. The playback
/// (clear→add→play) sequence lives there too; this backend only owns the
/// *re-select* half of zombie recovery and invokes ``replayHook`` (if the
/// coordinator set one) for the play half.
public final class OwnToneBackend: OutputBackend, @unchecked Sendable {

    /// The steady-state poll interval (brief §3 recommends 1 s: fast enough to
    /// catch zombie drops within a UI-imperceptible window, cheap against a
    /// local server).
    private let pollInterval: TimeInterval
    /// The backed-off poll interval used while the engine is unreachable (Q7):
    /// keep polling so recovery is automatic, but don't thrash.
    private let unreachablePollInterval: TimeInterval

    private let client: OwnToneClient
    private let webSocket: OwnToneWebSocketMonitor?

    /// The coordinator (T-C2) sets this to supply the play half of zombie
    /// recovery (clear→add→play). `OwnToneBackend` owns re-*select*; the
    /// coordinator owns re-*play* (brief §4 step 4 — "they must cooperate").
    /// Optional so the backend works standalone (tests, UI-only smoke).
    public var replayHook: (@Sendable () async -> Void)?

    /// The capture pipeline coordinator (T-C2). When present (the real path wired
    /// by ``makeBackend(_:)``), the backend starts/stops it alongside its own
    /// lifecycle and wires ``replayHook`` to the coordinator's `replayPlayback`
    /// so zombie recovery's re-*select* (here) and re-*play* (coordinator)
    /// cooperate. `nil` in tests and the UI-only smoke path — the backend still
    /// drives device state, there's just no audio pipeline behind it.
    public var captureCoordinator: CaptureCoordinator?

    // All mutable state is confined to `stateQueue`. `@unchecked Sendable` is
    // honest because of that discipline (same pattern as MockBackend).
    private let stateQueue = DispatchQueue(label: "OwnToneBackend.state")
    private var known: [String: Device] = [:]           // last-known snapshot, by id
    private var order: [String] = []                    // stable discovery order
    private var continuations: [UUID: AsyncStream<BackendEvent>.Continuation] = [:]
    private var pollTask: Task<Void, Never>?
    private var started = false
    private var reachable = true

    /// The set of ids the app most recently *asked* to be selected (via
    /// `setOutputSet`). Used to distinguish a user-driven deselection from a
    /// silent zombie drop (brief §4 step 2).
    private var expectedSelected: Set<String> = []
    /// Ids we've already tried to recover once this drop; cleared when they come
    /// back. Prevents the infinite-retry loop the brief warns against (§4 step 4).
    private var recovering: Set<String> = []

    /// App-side mute (Q4): OwnTone has no mute field, so mute is realized as
    /// volume 0 with the prior value stashed. Kept here so the `Device` snapshots
    /// the UI sees carry the flag, matching the mock.
    private var muted: Set<String> = []
    private var stashedVolume: [String: Int] = [:]      // pre-mute volume by id

    /// Public seam: the real backend against a live `localhost:3689` OwnTone
    /// with the best-effort `:3688` websocket accelerant and 1 s polling.
    /// (`OwnToneClient` / `OwnToneWebSocketMonitor` are internal by design —
    /// T-C4 keeps the OwnTone name off any public symbol.)
    public convenience init() {
        self.init(client: OwnToneClient(), webSocket: OwnToneWebSocketMonitor())
    }

    /// Injectable designated initializer (internal — tests pass a client backed
    /// by a stubbed `URLProtocol`, a `nil` websocket, and fast poll intervals).
    ///
    /// - Parameters:
    ///   - client: the JSON-API client (stubbed in tests).
    ///   - webSocket: the best-effort accelerant; `nil` disables it (tests don't
    ///     want a real socket).
    ///   - pollInterval / unreachablePollInterval: overridable so tests run the
    ///     poll loop fast.
    init(
        client: OwnToneClient,
        webSocket: OwnToneWebSocketMonitor?,
        pollInterval: TimeInterval = 1.0,
        unreachablePollInterval: TimeInterval = 3.0
    ) {
        self.client = client
        self.webSocket = webSocket
        self.pollInterval = pollInterval
        self.unreachablePollInterval = unreachablePollInterval
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
                // immediately (poll may already have discovered devices).
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
        // Wire + start the capture pipeline (real path only). The coordinator's
        // `replayPlayback` is the play half of zombie recovery; `recoverZombies`
        // calls `replayHook` after re-selecting a dropped output.
        if let coordinator = captureCoordinator {
            replayHook = { [weak coordinator] in await coordinator?.replayPlayback() }
            coordinator.start()
        }

        // The websocket is a pure accelerant: any frame → immediate poll.
        webSocket?.onNotification = { [weak self] in self?.pollNow() }
        webSocket?.start()

        pollTask = Task { [weak self] in
            guard let self else { return }
            // Health-check first (brief §5): if the engine is down at launch,
            // surface unreachable immediately rather than waiting a poll tick.
            do {
                try await self.client.healthCheck()
            } catch {
                self.markUnreachable()
            }
            while !Task.isCancelled {
                await self.pollOnce()
                let interval = self.stateQueue.sync { self.reachable } ? self.pollInterval : self.unreachablePollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        // Tear down the capture pipeline first (SIGINT the child + player/stop)
        // so no paused pipe session lingers (0f-pipe-brief.md:19-20).
        captureCoordinator?.stop()
        webSocket?.onNotification = nil
        webSocket?.stop()
        pollTask?.cancel()
        pollTask = nil
        stateQueue.async {
            self.started = false
            let ids = self.order
            self.known.removeAll()
            self.order.removeAll()
            self.expectedSelected.removeAll()
            self.recovering.removeAll()
            for id in ids { self.emit(.deviceRemoved(id: id)) }
        }
    }

    public func setVolume(_ volume: Int, for id: String) {
        let clamped = volume.clampedToVolume
        stateQueue.async {
            // If the device is muted, remember the desired level; unmute restores
            // it. Otherwise push it now. Optimistically echo so the UI is snappy;
            // the next poll reconciles with OwnTone's truth.
            if self.muted.contains(id) {
                self.stashedVolume[id] = clamped
                self.applyLocal(id) { $0.volume = clamped }
            } else {
                self.applyLocal(id) { $0.volume = clamped }
                Task { try? await self.client.setVolume(clamped, for: id) }
            }
        }
    }

    public func setMuted(_ muted: Bool, for id: String) {
        stateQueue.async {
            guard self.muted.contains(id) != muted else { return }
            if muted {
                self.muted.insert(id)
                if self.stashedVolume[id] == nil { self.stashedVolume[id] = self.known[id]?.volume ?? 0 }
                self.applyLocal(id) { $0.isMuted = true; $0.volume = 0 }
                Task { try? await self.client.setVolume(0, for: id) }
            } else {
                self.muted.remove(id)
                self.applyLocal(id) { $0.isMuted = false }
                self.restoreEffectiveVolume(id)
            }
        }
    }

    public func setOutputSet(_ ids: Set<String>) {
        stateQueue.async {
            self.expectedSelected = ids
            self.recovering.removeAll()
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.setOutputSet(Array(ids))
            } catch {
                // Couldn't even issue the call — let the poll loop reconcile /
                // mark unreachable.
                return
            }
            // brief §1/§4 don't-assume #2: a 204 does not prove selection stuck.
            // Re-GET and confirm; a mismatch is a silent select failure.
            await self.confirmSelectionOrRecover(expected: ids)
        }
    }

    // MARK: Polling + diff (the primary state driver)

    /// Kick an immediate poll out of band (websocket accelerant, or after a
    /// mutating call). Cheap; the main loop keeps ticking regardless.
    private func pollNow() {
        Task { [weak self] in await self?.pollOnce() }
    }

    private func pollOnce() async {
        let outputs: [OwnToneOutput]
        let player: OwnToneClient.PlayerState
        do {
            async let o = client.outputs()
            async let p = client.player()
            outputs = try await o
            player = try await p
        } catch {
            markUnreachable()
            return
        }
        applyPoll(outputs: outputs, player: player)
    }

    /// Diff a fresh poll against the last-known snapshot and emit the deltas.
    /// Also drives zombie detection (expected-selected vs polled-selected).
    private func applyPoll(outputs: [OwnToneOutput], player: OwnToneClient.PlayerState) {
        stateQueue.sync {
            if !self.reachable {
                self.reachable = true
                // Coming back from unreachable: everything re-appears available;
                // the per-output diff below emits the updates.
            }

            let polledIDs = Set(outputs.map(\.id))

            // Removals: known ids absent from this poll.
            for id in self.order where !polledIDs.contains(id) {
                self.known[id] = nil
                self.emit(.deviceRemoved(id: id))
            }
            self.order.removeAll { !polledIDs.contains($0) }

            // Additions + updates.
            var zombieDrops: [String] = []
            for output in outputs {
                let mapped = self.mapOutput(output)
                if let existing = self.known[output.id] {
                    // Detect a silent zombie drop: we expected this selected, the
                    // app didn't deselect it, yet the poll shows it unselected.
                    if self.expectedSelected.contains(output.id),
                       !output.selected,
                       !self.recovering.contains(output.id) {
                        zombieDrops.append(output.id)
                    }
                    let merged = self.merge(existing: existing, polled: mapped)
                    if merged != existing {
                        self.known[output.id] = merged
                        self.emit(.deviceUpdated(merged))
                    }
                } else {
                    self.known[output.id] = mapped
                    self.order.append(output.id)
                    self.emit(.deviceAdded(mapped))
                }
            }

            if !zombieDrops.isEmpty {
                let expected = self.expectedSelected
                let drops = zombieDrops
                for id in drops { self.recovering.insert(id) }
                Task { [weak self] in await self?.recoverZombies(drops, expected: expected) }
            }
        }
    }

    private func markUnreachable() {
        stateQueue.sync {
            guard self.reachable else { return }
            self.reachable = false
            // Q7: surface an unavailable state for every known device and keep
            // polling (the loop will back off). Never touch the server process.
            for id in self.order {
                guard var device = self.known[id], device.isAvailable else { continue }
                device.isAvailable = false
                self.known[id] = device
                self.emit(.deviceUpdated(device))
            }
        }
    }

    // MARK: Selection confirm + zombie recovery

    /// After a `setOutputSet`, re-GET and confirm the selection actually took
    /// (brief §1/§4). If not, treat it as a silent select failure and recover.
    private func confirmSelectionOrRecover(expected: Set<String>) async {
        let outputs: [OwnToneOutput]
        do {
            outputs = try await client.outputs()
        } catch {
            markUnreachable()
            return
        }
        // Fold the fresh read into the model so the UI reflects reality.
        applyPoll(outputs: outputs, player: (try? await client.player()) ?? .init(state: "stop", volume: 0))

        let actuallySelected = Set(outputs.filter(\.selected).map(\.id))
        let missing = expected.subtracting(actuallySelected)
        guard !missing.isEmpty else { return }
        // Silent select failure — recover exactly the missing ids.
        stateQueue.sync { for id in missing { self.recovering.insert(id) } }
        await recoverZombies(Array(missing), expected: expected)
    }

    /// Recovery sequence (brief §4 step 4): re-select the full intended set,
    /// invoke the coordinator's replay (clear→add→play) if wired, then re-GET
    /// once. If the ids still aren't selected, surface a device-level error
    /// (mark unavailable) and STOP — do not loop (brief §4 step 4).
    private func recoverZombies(_ ids: [String], expected: Set<String>) async {
        do {
            try await client.setOutputSet(Array(expected))
        } catch {
            markUnreachable(); return
        }
        // The coordinator owns the play half of recovery; run it if present.
        await replayHook?()

        let outputs: [OwnToneOutput]
        do {
            outputs = try await client.outputs()
        } catch {
            markUnreachable(); return
        }
        applyPoll(outputs: outputs, player: (try? await client.player()) ?? .init(state: "stop", volume: 0))

        let stillSelected = Set(outputs.filter(\.selected).map(\.id))
        let stillMissing = Set(ids).subtracting(stillSelected)

        stateQueue.sync {
            for id in ids {
                if stillMissing.contains(id) {
                    // Recovery failed after one retry → device-level error state.
                    // The only channel we have to the UI is `Device`: mark it
                    // unavailable so it greys out. Stays in `recovering` so we
                    // don't hammer it every poll.
                    if var device = self.known[id], device.isAvailable {
                        device.isAvailable = false
                        self.known[id] = device
                        self.emit(.deviceUpdated(device))
                    }
                } else {
                    // Recovered — clear the guard so a future drop retries.
                    self.recovering.remove(id)
                }
            }
        }
    }

    // MARK: Mapping + merge

    /// Map an OwnTone output object onto a `Device`, folding in app-side
    /// mute state (OwnTone has no such field, Q4).
    private func mapOutput(_ output: OwnToneOutput) -> Device {
        // brief don't-assume #5: type is "AirPlay 1"/"AirPlay 2", prefix-match.
        let isAirPlay = output.type.hasPrefix("AirPlay")
        // "AirPlay 2" (and anything newer) → PTP-capable; "AirPlay 1" → not.
        let supportsAirPlay2 = output.type.hasPrefix("AirPlay 2")
        let isMuted = muted.contains(output.id)
        return Device(
            id: output.id,
            name: output.name,
            kind: kind(for: output, isAirPlay: isAirPlay),
            isAvailable: true,
            supportsAirPlay2: supportsAirPlay2,
            // If muted app-side, the wire volume is 0 but we show the stashed
            // (intended) level so the slider doesn't jump to 0 under the user.
            volume: isMuted ? (stashedVolume[output.id] ?? output.volume) : output.volume,
            isMuted: isMuted,
            isSelected: output.selected
        )
    }

    /// Heuristic device kind from the OwnTone output. OwnTone doesn't expose a
    /// model, so we infer from the name (best-effort — the icon is cosmetic).
    private func kind(for output: OwnToneOutput, isAirPlay: Bool) -> Device.Kind {
        let name = output.name.lowercased()
        if name.contains("homepod") { return .homePod }
        if name.contains("apple tv") || name.contains("appletv") || name.contains(" tv") || name.hasSuffix("tv") { return .appleTV }
        if name.contains("airport") || name.contains("express") { return .airportExpress }
        if name.contains("sonos") { return .sonos }
        return .generic
    }

    /// Merge a freshly-polled device with the existing snapshot, preserving the
    /// app-side flags (mute/availability are ours, not OwnTone's) while taking
    /// OwnTone's truth for name/selection/volume.
    private func merge(existing: Device, polled: Device) -> Device {
        var result = polled
        // Availability is our concept (Q7 unreachable / zombie error state);
        // a successful poll means the device IS reachable, so `polled` (true)
        // wins — that's how recovery from unavailable clears itself.
        result.isMuted = muted.contains(existing.id)
        return result
    }

    // MARK: Local optimistic updates (mute/volume echo)

    private func applyLocal(_ id: String, _ change: (inout Device) -> Void) {   // on stateQueue
        guard var device = known[id] else { return }
        let before = device
        change(&device)
        guard device != before else { return }
        known[id] = device
        emit(.deviceUpdated(device))
    }

    /// Recompute the effective (wire) volume for a device after a mute change:
    /// silent (0) if muted, otherwise the stashed intended level. Pushes to
    /// OwnTone and echoes locally.
    private func restoreEffectiveVolume(_ id: String) {   // on stateQueue
        let silent = muted.contains(id)
        let intended = stashedVolume[id] ?? known[id]?.volume ?? 0
        let target = silent ? 0 : intended
        if !silent { stashedVolume[id] = nil }
        applyLocal(id) { $0.volume = target }
        Task { try? await self.client.setVolume(target, for: id) }
    }

    // MARK: Emit

    private func emit(_ event: BackendEvent) {   // on stateQueue
        for continuation in continuations.values { continuation.yield(event) }
    }
}

// MARK: - Backend selection (unchanged public seam)

/// Which backend the app talks to. Flip this (or drive it from a launch
/// argument / hidden setting) to develop against fabricated devices vs. real
/// hardware without touching any UI code.
public enum BackendKind {
    case mock
    case ownTone

    /// The env var that selects a backend when no explicit argument is given.
    /// Maps onto a future hidden Developer setting in the app (SPEC.md §4 seam).
    public static let environmentVariableName = "AIRPLAY_BACKEND"

    /// Resolve which backend to use, in priority order: an explicit argument
    /// (e.g. a CLI flag already parsed by the caller) → the `AIRPLAY_BACKEND`
    /// env var (`mock` | `owntone`, case-insensitive) → default `.mock`.
    ///
    /// An unrecognized env value is treated as absent: it falls back to
    /// `.mock` and prints one warning to stderr rather than crashing, since
    /// this is a dev convenience knob, not user-facing configuration.
    public static func resolved(
        explicit: BackendKind? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BackendKind {
        if let explicit { return explicit }

        guard let raw = environment[environmentVariableName] else { return .mock }
        switch raw.lowercased() {
        case "mock":    return .mock
        case "owntone": return .ownTone
        default:
            FileHandle.standardError.write(
                Data("warning: unrecognized \(environmentVariableName) value \"\(raw)\" — falling back to mock\n".utf8)
            )
            return .mock
        }
    }
}

/// The one place that knows about concrete backend types. Everything else in
/// the app holds an ``OutputBackend``.
///
/// Pass `nil` (the default) to resolve the backend via
/// ``BackendKind/resolved(explicit:environment:)`` — explicit arg → the
/// `AIRPLAY_BACKEND` env var → `.mock`.
public func makeBackend(_ kind: BackendKind? = nil) -> OutputBackend {
    switch BackendKind.resolved(explicit: kind) {
    case .mock:    return MockBackend()
    case .ownTone:
        let backend = OwnToneBackend()
        // Attach the capture pipeline (T-C2). The coordinator spawns the audiocap
        // subprocess, creates the FIFO in OwnTone's library dir, reconciles the
        // rate, and drives explicit playback. The backend starts/stops it and
        // wires `replayHook` in `start()`. Binary/library paths are the dev
        // defaults; a shipped `.app` would pass the embedded binary's path.
        backend.captureCoordinator = CaptureCoordinator()
        return backend
    }
}
