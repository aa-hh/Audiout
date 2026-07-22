import Foundation
import AirPlayEngine

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
///   via ``replayHook``); if it still fails, the device enters the resting
///   `.failed` connection state and recovery stops. It stays *available* — it
///   answered the poll, so it's on the network; the *session* failed
///   (`dev/notes/p1-connection-status-brief.md` §1).
/// - **Connection lifecycle** (connection-status brief §1/§3): every routed
///   device walks `.off → .connecting → .connected` (confirm re-GET + one
///   stable poll tick), `.reconnecting` on a zombie drop, and a sticky
///   `.failed` once the single recovery attempt or the connecting timeout is
///   exhausted. All transitions live in `connectionStates` on `stateQueue`
///   and reach the UI as ordinary `deviceUpdated` diffs.
/// - **Connect-only** (Q7, brief §5): connection-refused → mark everything
///   unavailable, keep polling at a backed-off interval, NEVER start/supervise
///   the server.
///
/// No capture/FIFO here — that's T-C2's `CaptureCoordinator`. The playback
/// (clear→add→play) sequence lives there too; this backend only owns the
/// *re-select* half of zombie recovery and invokes ``replayHook`` (if the
/// coordinator set one) for the play half.
public final class OwnToneBackend: OutputBackend, @unchecked Sendable {

    /// Sentinel ID for the synthetic local-Mac device (matches MockBackend).
    private static let localMacID = "local-mac"

    /// The steady-state poll interval (brief §3 recommends 1 s: fast enough to
    /// catch zombie drops within a UI-imperceptible window, cheap against a
    /// local server).
    private let pollInterval: TimeInterval
    /// The backed-off poll interval used while the engine is unreachable (Q7):
    /// keep polling so recovery is automatic, but don't thrash.
    private let unreachablePollInterval: TimeInterval
    /// How long `.connecting`/`.reconnecting` may sit unresolved before the
    /// failure flow runs with `.timedOut` (connection-status brief §3 — 10 s).
    private let connectingTimeout: TimeInterval

    private let client: OwnToneClient
    private let webSocket: OwnToneWebSocketMonitor?
    private let outputObserver: DefaultOutputObserver?

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

    /// Investigates *why* an enable failed (connection-status brief §4/§5). On
    /// entering `.failed` the backend reports its immediate best-guess
    /// `ConnectionFailure`, then fires this off in the background; if the
    /// device is still `.failed` when it returns, the diagnosed failure
    /// replaces the guess (and emits again). `nil` (the default) skips
    /// diagnosis — the guess stands. The concrete implementation is wired by
    /// ``makeBackend(_:)``; tests inject fakes. Set before `start()` (same
    /// discipline as ``replayHook``).
    public var diagnostics: ConnectionDiagnosing?

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

    /// Select/confirm/recovery jobs currently in flight, owned so `stop()` can
    /// cancel them — an un-owned task resuming after teardown could otherwise
    /// re-populate `known`/`order` (via its `applyPoll`) and emit
    /// `deviceAdded`/`deviceUpdated` AFTER the `deviceRemoved` sweep. See
    /// ``runOwned(_:)``.
    private var inFlightTasks: [UUID: Task<Void, Never>] = [:]

    /// Per-device connection lifecycle (connection-status brief §1/§3). `.off`
    /// is represented by absence. Folded into every snapshot by `mapOutput`, so
    /// transitions reach the UI as ordinary `deviceUpdated` diffs.
    private var connectionStates: [String: ConnectionState] = [:]
    /// Ids whose selection the confirm re-GET verified, awaiting one more
    /// stable poll tick before `.connecting → .connected` (§1 — a failed
    /// activation can still revert `selected` a moment after the confirm).
    private var pendingStable: Set<String> = []
    /// Live connecting/reconnecting timeouts by id, with a generation token so
    /// a stale timeout (superseded by a newer transition) can never fire even
    /// if `cancel()` loses the race with the sleep ending.
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var timeoutTokens: [String: UUID] = [:]
    /// Latest raw auth flags per id (OwnTone `has_password || requires_auth ||
    /// needs_auth_key`), captured on every poll for `DiagnosisContext`.
    private var authFlags: [String: Bool] = [:]

    /// App-side mute (Q4): OwnTone has no mute field, so mute is realized as
    /// volume 0 with the prior value stashed. Kept here so the `Device` snapshots
    /// the UI sees carry the flag, matching the mock.
    private var muted: Set<String> = []
    private var stashedVolume: [String: Int] = [:]      // pre-mute volume by id

    /// Public seam: the real backend against a live `localhost:3689` OwnTone
    /// with the best-effort `:3688` websocket accelerant and 1 s polling.
    /// (`OwnToneClient` / `OwnToneWebSocketMonitor` are internal by design —
    /// T-C4 keeps the OwnTone name off any public symbol.)
    public convenience init(outputObserver: DefaultOutputObserver? = nil) {
        self.init(client: OwnToneClient(), webSocket: OwnToneWebSocketMonitor(), outputObserver: outputObserver)
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
    ///   - connectingTimeout: how long `.connecting`/`.reconnecting` may sit
    ///     unresolved before failing with `.timedOut` (brief §3 — 10 s;
    ///     tests shrink it).
    init(
        client: OwnToneClient,
        webSocket: OwnToneWebSocketMonitor?,
        outputObserver: DefaultOutputObserver? = nil,
        pollInterval: TimeInterval = 1.0,
        unreachablePollInterval: TimeInterval = 3.0,
        connectingTimeout: TimeInterval = 10.0
    ) {
        self.client = client
        self.webSocket = webSocket
        self.outputObserver = outputObserver
        self.pollInterval = pollInterval
        self.unreachablePollInterval = unreachablePollInterval
        self.connectingTimeout = connectingTimeout
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

            // Inject the synthetic local-Mac device if the observer is present.
            if let observer = self.outputObserver {
                observer.onChange = { [weak self] newName in
                    guard let self else { return }
                    self.stateQueue.async {
                        let id = OwnToneBackend.localMacID
                        guard var device = self.known[id] else { return }
                        device.name = newName
                        self.known[id] = device
                        self.emit(.deviceUpdated(device))
                    }
                }
                observer.start()
                let device = Device(
                    id: OwnToneBackend.localMacID,
                    name: observer.currentDeviceName,
                    kind: .localMac,
                    isAvailable: true,
                    supportsAirPlay2: false,
                    volume: 100,
                    isMuted: false,
                    isSelected: false,
                    isLocalDevice: true
                )
                self.known[OwnToneBackend.localMacID] = device
                self.order.insert(OwnToneBackend.localMacID, at: 0)
                self.emit(.deviceAdded(device))
            }
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
        outputObserver?.onChange = nil
        outputObserver?.stop()
        webSocket?.onNotification = nil
        webSocket?.stop()
        pollTask?.cancel()
        pollTask = nil
        stateQueue.async {
            self.started = false
            // Cancel the in-flight select/confirm/recovery jobs: nothing owned
            // by a dead lifecycle may mutate or emit after teardown. (Their
            // `applyPoll`/state mutations are also `started`-guarded, closing
            // the race where a job already passed its cancellation points.)
            for task in self.inFlightTasks.values { task.cancel() }
            self.inFlightTasks.removeAll()
            let ids = self.order
            self.known.removeAll()
            self.order.removeAll()
            self.expectedSelected.removeAll()
            self.recovering.removeAll()
            // The connection lifecycle dies with the backend: no timeout may
            // fire after stop, and a restart begins from `.off`.
            for id in Array(self.timeoutTasks.keys) { self.cancelConnectionTimeout(id) }
            self.connectionStates.removeAll()
            self.pendingStable.removeAll()
            self.authFlags.removeAll()
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
            let previous = self.expectedSelected
            self.expectedSelected = ids
            self.recovering.removeAll()

            // Ids leaving the set → `.off` — unless `.failed`, which is
            // sticky: the popover drops membership as failure *cleanup*
            // (connection-status brief §7.3), and that cleanup must not erase
            // the warning (§1).
            for id in previous.subtracting(ids) {
                self.pendingStable.remove(id)
                self.cancelConnectionTimeout(id)
                if case .failed = self.connectionState(of: id) { continue }
                self.setConnectionState(.off, for: id)
            }

            // Ids newly enabled — including a `.failed` id re-added, which is
            // the retry path (§1) — go `.connecting` NOW, before the
            // PUT/confirm round-trip below resolves, so the UI spinner is
            // immediate (§3).
            for id in ids {
                switch self.connectionState(of: id) {
                case .off, .failed:
                    self.setConnectionState(.connecting, for: id)
                    self.startConnectionTimeout(id)
                default:
                    break   // already connecting/connected/reconnecting — leave it
                }
            }
        }
        runOwned { [weak self] in
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

    /// Launch an async select/confirm/recovery job the backend *owns*: `stop()`
    /// cancels every registered job, so an in-flight confirm or zombie recovery
    /// can't resurrect devices (or emit) after teardown. Registration and
    /// removal ride `stateQueue`, same as all other mutable state; a job whose
    /// registration lands after `stop()` is cancelled instead of kept.
    private func runOwned(_ operation: @escaping @Sendable () async -> Void) {
        let key = UUID()
        let task = Task { [weak self] in
            await operation()
            self?.stateQueue.async { self?.inFlightTasks[key] = nil }
        }
        stateQueue.async {
            if self.started {
                self.inFlightTasks[key] = task
            } else {
                task.cancel()
            }
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
            // Lifecycle guard: a confirm/recovery re-GET that was in flight
            // when `stop()` tore everything down must not re-populate
            // `known`/`order` — or emit — after the `deviceRemoved` sweep
            // (stop() also cancels the owned jobs; this closes the race where
            // one already passed its cancellation points).
            guard self.started else { return }
            if !self.reachable {
                self.reachable = true
                // Coming back from unreachable: everything re-appears available;
                // the per-output diff below emits the updates.
            }

            let polledIDs = Set(outputs.map(\.id))

            // Removals: known ids absent from this poll. Departure clears every
            // per-id trace — `.failed → .off` happens only here (connection-
            // status brief §1: a failed device keeps its warning until it
            // disappears entirely). The synthetic local-Mac device is skipped:
            // it is not in OwnTone's output list by design, so every poll would
            // otherwise "remove" it.
            for id in self.order where !polledIDs.contains(id) && id != OwnToneBackend.localMacID {
                self.known[id] = nil
                self.connectionStates[id] = nil
                self.pendingStable.remove(id)
                self.authFlags[id] = nil
                self.cancelConnectionTimeout(id)
                self.emit(.deviceRemoved(id: id))
            }
            self.order.removeAll { !polledIDs.contains($0) && $0 != OwnToneBackend.localMacID }

            // Additions + updates.
            var zombieDrops: [String] = []
            for output in outputs {
                // Capture the raw auth flags for `DiagnosisContext` (brief §3).
                self.authFlags[output.id] = output.requiresAnyAuth
                // Stability window (§1): the confirm re-GET said selected, and
                // this poll tick agreeing is what promotes `.connecting →
                // .connected` — set it before `mapOutput` so the promotion
                // rides the same `deviceUpdated` diff.
                if output.selected,
                   self.pendingStable.contains(output.id),
                   self.connectionState(of: output.id) == .connecting {
                    self.pendingStable.remove(output.id)
                    self.cancelConnectionTimeout(output.id)
                    self.connectionStates[output.id] = .connected
                }
                let mapped = self.mapOutput(output)
                if let existing = self.known[output.id] {
                    // Detect a silent zombie drop: this device was verified
                    // connected, the app didn't deselect it, yet the poll shows
                    // it unselected. (The `.connected` gate keeps an id that is
                    // still mid-confirm — `.connecting` — out of here; that
                    // path belongs to `confirmSelectionOrRecover`.)
                    if self.expectedSelected.contains(output.id),
                       !output.selected,
                       !self.recovering.contains(output.id),
                       self.connectionState(of: output.id) == .connected {
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
                for id in drops {
                    self.recovering.insert(id)
                    // Emit `.reconnecting` BEFORE recovery runs so the UI shows
                    // the spinner for the whole attempt (brief §3).
                    self.setConnectionState(.reconnecting, for: id)
                    self.startConnectionTimeout(id)
                }
                self.runOwned { [weak self] in await self?.recoverZombies(drops, expected: expected) }
            }
        }
    }

    private func markUnreachable() {
        stateQueue.sync {
            // `started` guard: an owned job cancelled by `stop()` surfaces the
            // cancellation as a thrown client error — that must not poison the
            // next lifecycle's reachability (or emit) after teardown.
            guard self.started, self.reachable else { return }
            self.reachable = false
            // Engine-unreachable leaves connection states as-is (connection-
            // status brief §1: the greyed whole-list treatment communicates
            // it), but no timeout may fire while the engine is down.
            for id in Array(self.timeoutTasks.keys) { self.cancelConnectionTimeout(id) }
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
        // Confirmed ids stay `.connecting` but are marked pending-stable: the
        // NEXT poll tick still showing them selected is what makes them
        // `.connected` (connection-status brief §1 stability window — a failed
        // activation can revert `selected` a moment after this confirm).
        stateQueue.sync {
            guard self.started else { return }   // stopped mid-confirm — leave the corpse alone
            for id in expected.intersection(actuallySelected)
            where self.connectionState(of: id) == .connecting {
                self.pendingStable.insert(id)
            }
        }
        let missing = expected.subtracting(actuallySelected)
        guard !missing.isEmpty else { return }
        // Silent select failure — recover exactly the missing ids (their state
        // stays `.connecting` for the whole attempt, brief §3).
        stateQueue.sync {
            guard self.started else { return }
            for id in missing { self.recovering.insert(id) }
        }
        await recoverZombies(Array(missing), expected: expected)
    }

    /// Recovery sequence (brief §4 step 4): re-select the full intended set,
    /// invoke the coordinator's replay (clear→add→play) if wired, then re-GET
    /// once. Success → `.connected`. If the ids still aren't selected, enter
    /// the resting `.failed` state and STOP — do not loop (brief §4 step 4).
    /// The device stays *available*: it answered the poll, so it's on the
    /// network — the *session* failed (connection-status brief §1; this
    /// deliberately replaced the old mark-unavailable behaviour).
    private func recoverZombies(_ ids: [String], expected: Set<String>) async {
        do {
            // STABILITY(D5): legacy OwnTone backend - recovery re-PUTs stale expected set — see dev/notes/stability-audit-2026-07-18.md
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
            guard self.started else { return }   // stopped mid-recovery — no post-teardown transitions
            for id in ids {
                if stillMissing.contains(id) {
                    // Recovery failed after one retry → resting `.failed`.
                    // Only fail an unresolved connect/reconnect: the timeout
                    // may have failed it already, or the user may have
                    // disabled the device mid-recovery (`.off`) — both must
                    // stand. Stays in `recovering` so we don't hammer it
                    // every poll.
                    switch self.connectionState(of: id) {
                    case .connecting:
                        self.enterFailure(id, cause: .unknown)
                    case .reconnecting:
                        self.enterFailure(id, cause: .droppedMidStream)
                    default:
                        break
                    }
                } else {
                    // Recovered — clear the guard so a future drop retries.
                    self.recovering.remove(id)
                    switch self.connectionState(of: id) {
                    case .connecting, .reconnecting:
                        self.pendingStable.remove(id)
                        self.cancelConnectionTimeout(id)
                        self.setConnectionState(.connected, for: id)
                    default:
                        break
                    }
                }
            }
        }
    }

    // MARK: Connection state machine (dev/notes/p1-connection-status-brief.md §1/§3)

    /// Current lifecycle state for an id; absence means `.off`.
    private func connectionState(of id: String) -> ConnectionState {   // on stateQueue
        connectionStates[id] ?? .off
    }

    /// Record a transition and echo it through the normal update machinery.
    /// (`applyLocal` no-ops for ids not yet discovered; `mapOutput` folds the
    /// dict in when they are.)
    private func setConnectionState(_ state: ConnectionState, for id: String) {   // on stateQueue
        guard connectionState(of: id) != state else { return }
        connectionStates[id] = (state == .off) ? nil : state
        applyLocal(id) { $0.connectionState = state }
    }

    /// Arm the connecting/reconnecting timeout (brief §3): if the id is still
    /// unresolved when it fires, the failure flow runs with `.timedOut`. The
    /// generation token makes a superseded timeout inert even if `cancel()`
    /// loses the race with the sleep ending.
    private func startConnectionTimeout(_ id: String) {   // on stateQueue
        timeoutTasks[id]?.cancel()
        let token = UUID()
        timeoutTokens[id] = token
        let timeout = connectingTimeout
        timeoutTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.stateQueue.async {
                guard self.timeoutTokens[id] == token else { return }
                switch self.connectionState(of: id) {
                case .connecting, .reconnecting:
                    self.enterFailure(id, cause: .timedOut)
                default:
                    // Resolved without cancelling (shouldn't happen — every
                    // exit cancels) — just clean up the bookkeeping.
                    self.cancelConnectionTimeout(id)
                }
            }
        }
    }

    /// Disarm the timeout for an id. Every state exit does this (brief §3).
    private func cancelConnectionTimeout(_ id: String) {   // on stateQueue
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = nil
        timeoutTokens[id] = nil
    }

    /// The failure flow (brief §3): enter the resting `.failed` with the
    /// backend's immediate best guess, emit, then fire-and-forget diagnosis.
    /// When it returns, the diagnosed failure replaces the guess only if the
    /// device is STILL `.failed` — a retry or removal in the meantime wins.
    private func enterFailure(_ id: String, cause: ConnectionFailure.Cause) {   // on stateQueue
        cancelConnectionTimeout(id)
        pendingStable.remove(id)
        setConnectionState(.failed(ConnectionFailure(cause: cause)), for: id)

        guard let diagnostics else { return }
        let context = DiagnosisContext(
            deviceID: id,
            deviceName: known[id]?.name ?? id,
            requiresAuth: authFlags[id] ?? false,
            priorCause: cause
        )
        Task { [weak self] in
            let diagnosed = await diagnostics.diagnose(context)
            guard let self else { return }
            self.stateQueue.async {
                guard case .failed = self.connectionState(of: id) else { return }
                self.setConnectionState(.failed(diagnosed), for: id)
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
            isSelected: output.selected,
            // The lifecycle dict is the truth (connection-status brief §3);
            // folding it in here is what makes transitions ride the poll diff.
            connectionState: connectionStates[output.id] ?? .off
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
    case native

    /// The env var that selects a backend when no explicit argument is given.
    /// Maps onto a future hidden Developer setting in the app (SPEC.md §4 seam).
    public static let environmentVariableName = "AIRPLAY_BACKEND"

    /// Resolve which backend to use, in priority order: an explicit argument
    /// (e.g. a CLI flag already parsed by the caller) → the `AIRPLAY_BACKEND`
    /// env var (`mock` | `owntone` | `native`, case-insensitive) → default
    /// `.native`.
    ///
    /// `.native` is the default so a plain launch drives real speakers — and so
    /// the native-only onboarding/permission paths run (``SetupModel/shouldPresentOnLaunch(settings:backendKind:)``
    /// and `AppDelegate`'s reactivate/wake permission re-audit both gate on
    /// `.native`). Mock is opt-in ONLY: it requires `AIRPLAY_BACKEND=mock`
    /// explicitly, never as a fallback — a build that can't reach a real backend
    /// must fail loudly, not silently swap in fabricated demo speakers. An
    /// unrecognized env value is treated as absent: it falls back to `.native`
    /// and prints one warning to stderr rather than crashing, since this is a
    /// dev convenience knob, not user-facing configuration.
    public static func resolved(
        explicit: BackendKind? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BackendKind {
        if let explicit { return explicit }

        guard let raw = environment[environmentVariableName] else { return .native }
        switch raw.lowercased() {
        case "mock":    return .mock
        case "owntone": return .ownTone
        case "native":  return .native
        default:
            FileHandle.standardError.write(
                Data("warning: unrecognized \(environmentVariableName) value \"\(raw)\" — falling back to native\n".utf8)
            )
            return .native
        }
    }
}

/// The one place that knows about concrete backend types. Everything else in
/// the app holds an ``OutputBackend``.
///
/// Pass `nil` (the default) to resolve the backend via
/// ``BackendKind/resolved(explicit:environment:)`` — explicit arg → the
/// `AIRPLAY_BACKEND` env var → `.native`.
/// - Parameter resolvePID: bundle ID → running app's pid, for per-app capture
///   (T6/T7). Core can't import AppKit (`NSRunningApplication`), so this is
///   threaded in from the AppKit layer (`AppDelegate`). Defaults to "nothing
///   resolves", which keeps the per-app path inert (no pid ⇒ no tap) for callers
///   that don't supply it — every non-native backend ignores it entirely.
public func makeBackend(
    _ kind: BackendKind? = nil,
    resolvePID: @escaping @Sendable (String) -> pid_t? = { _ in nil }
) -> OutputBackend {
    switch BackendKind.resolved(explicit: kind) {
    case .mock:
        // Scenario scripts (connection-status brief §5): with
        // `AIRPLAY_MOCK_SCENARIO=connection-demo` the mock choreographs
        // failures/retries/mid-stream drops so every ConnectionState is
        // demoable offline; any other/missing value resolves to no scripts
        // (exact pre-existing behaviour). The observer gives the mock's local
        // row the real default-output name instead of a hardcoded one.
        return MockBackend(connectScripts: MockBackend.resolveScenarioScripts(),
                           outputObserver: DefaultOutputObserver())
    case .ownTone:
        let backend = OwnToneBackend(outputObserver: DefaultOutputObserver())
        // Attach the capture pipeline (T-C2). The coordinator spawns the audiocap
        // subprocess, creates the FIFO in OwnTone's library dir, reconciles the
        // rate, and drives explicit playback. The backend starts/stops it and
        // wires `replayHook` in `start()`. Binary/library paths are the dev
        // defaults; a shipped `.app` would pass the embedded binary's path.
        backend.captureCoordinator = CaptureCoordinator()
        // Real failure diagnosis (connection-status brief §4): engine-log scan +
        // Bonjour presence + TCP probe, replacing the backend's first-guess
        // ConnectionFailure once evidence is in. Tests inject fakes instead.
        backend.diagnostics = NetworkConnectionDiagnostics()
        return backend
    case .native:
        // In-process AirPlayEngine + app-owned discovery/capture. See
        // NativeBackend.swift / NativeCaptureCoordinator.swift (T-NB-BACKEND-1,
        // T-NB-CAPTURE-1) for the engine-driven equivalent of the OwnTone path
        // above.
        //
        // startBufferMs: the product runs a LOWER sender-side start buffer than
        // the engine's OwnTone-parity default (2250 ms → ~3.5 s click-to-sound
        // measured on the Sonos fleet, 2026-07-17). 1000 ms cuts the
        // deterministic scheduling lead from 2.0 s to 0.75 s (expected total
        // ≈ 2.2 s) while leaving the receivers a 750 ms jitter/multi-room
        // buffer. Tunable per run via AIRPLAY_START_BUFFER_MS for the gated
        // by-ear verification — see AirPlayEngine/docs/latency-analysis.md.
        let startBufferMs = nativeStartBufferMs()
        let engine = AirPlayEngine(
            config: EngineConfig(startBufferMs: startBufferMs))
        // Bundle ID → running pid, supplied by the caller (T7: `AppDelegate` passes
        // an `NSRunningApplication`-backed resolver; other callers get the "nothing
        // resolves" default). Shared by BOTH the per-app capture (owned by
        // NativeBackend) and the whole-system tap so their exclusion/capture views
        // agree.
        let nativeBackend = NativeBackend(engine: engine, resolvePID: resolvePID)
        nativeBackend.seedStartBufferMs(startBufferMs)
        nativeBackend.captureCoordinator = NativeCaptureCoordinator(
            engine: engine, resolvePID: resolvePID)
        // Bug T2: the local-playback engine renders `.currentDevice`-routed apps on
        // the Mac's built-in speakers as independent, individually-levelable streams.
        nativeBackend.localPlaybackEngine = LocalPlaybackEngine()
        return nativeBackend
    }
}

/// The `AIRPLAY_START_BUFFER_MS` env override, when set AND valid (an integer
/// in the engine shim's accepted 300...5000 range) — the per-launch dev knob,
/// which beats the persisted user setting (a deliberately-set env var is a
/// stronger signal than a stored preference). Returns nil when unset; an
/// invalid value is IGNORED with one stderr warning (behaves like unset — same
/// dev-knob-not-config policy as `AIRPLAY_BACKEND`). Public so the settings
/// pane can render its "overridden for this launch" disabled state.
public func nativeStartBufferEnvOverrideMs(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Int? {
    guard let raw = environment["AIRPLAY_START_BUFFER_MS"] else { return nil }
    guard let ms = Int(raw), (300...5000).contains(ms) else {
        FileHandle.standardError.write(
            Data("warning: AIRPLAY_START_BUFFER_MS \"\(raw)\" is not an integer in 300...5000 — ignoring\n".utf8)
        )
        return nil
    }
    return ms
}

/// The native backend's launch-time start buffer in ms, resolved
/// **env override → persisted setting → default** (PLAN-LATENCY-SETTING.md §3;
/// `AppSettings.startBufferMs` already folds unknown stored values to the
/// default, so this can only return an offered option or a valid env value).
func nativeStartBufferMs(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    settings: AppSettings = AppSettings()
) -> Int {
    nativeStartBufferEnvOverrideMs(environment: environment) ?? settings.startBufferMs
}
