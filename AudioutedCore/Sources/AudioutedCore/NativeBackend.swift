import Foundation
import AudioToolbox
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
///   0.0–1.0 contract. The LOCAL row is the exception on both counts — it is not an
///   engine output at all, so it is driven through ``SystemVolumeControlling``
///   (Core Audio's default output device) and gets REAL hardware mute rather than
///   the shim. That path is also the only two-way one: external changes (media
///   keys, the Sound menu, a default-device switch) flow back as `deviceUpdated`.
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
public final class NativeBackend: OutputBackend, LatencyConfigurable, AppRouteConfiguring, @unchecked Sendable {

    // MARK: Injected dependencies (protocols so tests are hermetic)

    private let engine: EngineControlling
    private let discovery: DiscoverySource

    /// The Mac's own default-output volume/mute. This is the ONLY control path the
    /// local device row (``localDeviceID``) has: the Mac is the thing *sending*
    /// audio, so it is never an engine output, has no ``outputIDs`` entry, and every
    /// engine-shaped control below would silently drop its writes. `setVolume` /
    /// `setMuted` therefore branch on the local id *before* the `outputIDs` guard and
    /// come here instead. See ``SystemVolumeControlling``.
    ///
    /// `var`, not `let`, only because ``SystemVolumeControlling`` is not
    /// class-constrained (a fake can be a struct), so Swift treats
    /// `onExternalChange`'s setter as potentially mutating and requires mutable
    /// storage to assign through the existential. It is assigned exactly once, in
    /// `init`; `start()`/`stop()` mutate only the callback, on the caller's thread —
    /// the same discipline `discovery.onEvent` / `captureCoordinator.onLevel` keep.
    private var systemVolume: SystemVolumeControlling

    /// The in-process capture pipeline (T-NB-CAPTURE-1). When present (the real
    /// path wired by ``makeBackend(_:)``), the backend GATES it on selection
    /// (``reconcileCaptureGate()``) and plumbs its per-buffer RMS into
    /// `BackendEvent.level`. `nil` in tests and the UI-only smoke path — the
    /// backend still drives device state, there's just no audio pipeline behind it.
    ///
    /// Typed as ``CaptureControlling`` rather than the concrete coordinator so the
    /// gate is assertable with no Core Audio tap / TCC prompt;
    /// ``NativeCaptureCoordinator`` conforms, so `makeBackend(_:)` wires the real
    /// one unchanged.
    ///
    /// Mirrors how ``OwnToneBackend/captureCoordinator`` connects the OwnTone path:
    /// the backend owns the coordinator's lifecycle, the coordinator owns capture.
    /// The one difference is metering — the native coordinator computes RMS on the
    /// captured buffer (upstream of the engine, per playback-meter-research.md) and
    /// hands it back via `onLevel`; the backend fans it out as `.level` for every
    /// currently-selected, unmuted device.
    public var captureCoordinator: CaptureControlling?

    /// The local-playback engine (Bug T2): renders every `.currentDevice`-routed
    /// app's per-app capture on the Mac's BUILT-IN speakers as an independent
    /// stream with its own volume. Wired by ``makeBackend(_:)`` (the real
    /// ``LocalPlaybackEngine``); `nil` in tests and the UI-only smoke path (a
    /// `.currentDevice` route is then inert, exactly as an AirPlay route is inert
    /// with no `captureCoordinator`). A spy conforming to
    /// ``LocalPlaybackControlling`` is injected in tests to assert the wiring with
    /// no `AVAudioEngine` or audio hardware.
    ///
    /// Assigned once before ``start()`` (same discipline as `captureCoordinator`);
    /// read on the tap delivery thread via `receive` and on `stateQueue`, never
    /// mutated after wiring, so no synchronization on the reference is needed.
    public var localPlaybackEngine: LocalPlaybackControlling?

    // MARK: Per-app routing (T6)
    //
    // ADDITIVE to the whole-system "Selected Devices" path above. `captureCoordinator`
    // (the whole-system tap) still produces stream_id 0; the two objects below produce
    // the per-app redirect streams (stream_id ≥ 1) that run ALONGSIDE it:
    //   - `perAppCapture` owns one Core Audio process tap per routed bundle ID.
    //   - `routeMixer` turns those per-app buffers into per-destination mixed streams
    //     and derives the device⟷stream topology.
    // The callback graph is wired once in `init`:
    //   perAppCapture.onStateChange → routeMixer.handleStateChange
    //   perAppCapture.onBuffer      → routeMixer.handleBuffer
    //   routeMixer.onDestinationSetsChanged → bind devices to streams + emit .routedApps
    //   routeMixer.onMixedBuffer            → engine.write(pcm:streamId:pts:)
    // `updateAppRoutes(_:excludedBundleIDs:)` is the single external entry point that
    // feeds a fresh routing table in (T7 calls it from AppRoutingController changes).

    /// One process tap per app currently routed to a specific device. `resolvePID`
    /// is injected (Core can't import AppKit / `NSRunningApplication`); it defaults
    /// to "nothing resolves", so until T7 threads a real resolver in, `start` lands
    /// each bundle ID in `.failed(.appNotRunning)` without touching Core Audio.
    private let perAppCapture: PerAppCaptureCoordinator

    /// Combines the per-app captures into per-destination mixed streams and owns the
    /// stable device⟷stream_id topology. Pure computation (no Core Audio/engine).
    private let routeMixer: AppRouteMixer

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
    /// `setOutputSet`). Also the CAPTURE GATE's input (`reconcileCaptureGate`).
    /// The actual per-device convergence target is `desiredOn` (below), which
    /// coalesces rapid flips; this is just the last whole-set request.
    private var expectedSelected: Set<String> = []

    // MARK: Capture gate (BUG: passthrough ran the tap and muted the Mac)
    //
    // The tap is `.mutedWhenTapped` (NativeCaptureCoordinator.swift:122) — it
    // silences the Mac's own speakers while capturing, which is CORRECT while
    // streaming (you don't want local audio playing against delayed AirPlay) and
    // catastrophic otherwise. `start()` used to run it unconditionally, so the
    // app's out-of-the-box passthrough state (Selected Devices == {local Mac},
    // output set EMPTY — GroupController.applyRouting filters the local device
    // out) muted system audio and sent the capture nowhere: total silence.
    //
    // So capture runs ONLY while at least one real AP2 output is selected. The
    // gate keys on INTENT (`expectedSelected`), not availability — see
    // `reconcileCaptureGate`.

    /// Whether the capture coordinator is currently *desired* running. The gate's
    /// last decision, NOT a read of the coordinator's own state machine (which
    /// settles asynchronously on `captureControlQueue`). Confined to `stateQueue`,
    /// so the start/stop decision is serialized with the selection that drives it.
    private var captureRunning = false

    /// Where `coordinator.start()`/`stop()` actually run. They must NOT run on
    /// `stateQueue`: `stop()` tears down a Core Audio tap and MAY BLOCK
    /// (NativeCaptureCoordinator.swift:184, "teardown may block on Core Audio"),
    /// which would head-of-line-block every device update behind it. But their
    /// ORDER must still follow the `stateQueue` decisions exactly, or a stale
    /// `start()` could land after a `stop()` and re-mute the Mac forever. A serial
    /// queue that is only ever enqueued-to from INSIDE a `stateQueue` critical
    /// section gives both: `stateQueue` orders the decisions, this queue replays
    /// them in that same order, off the hot path.
    private let captureControlQueue = DispatchQueue(label: "NativeBackend.captureControl")

    // MARK: Sleep/wake (B6b — all confined to `stateQueue`)
    //
    // Sleep severs the RTSP/PTP sockets. `handleSystemWillSleep()` tears the engine
    // outputs down cleanly (graceful TEARDOWN) but KEEPS `expectedSelected` /
    // `desiredOn` intact, and `handleSystemDidWake()` re-converges them — so a sleep
    // is a transient dropout, never a deselection. Crucially the willSleep teardown
    // emits NO `deviceUpdated`: GroupController's reverse auto-swap (which restores
    // {local} and clears the Selected Devices intent) is event-driven, so emitting
    // nothing means it can't fire.

    /// Whether the backend is currently suspended for system sleep. While true the
    /// capture gate is forced off (`reconcileCaptureGate`) and no converge/discovery
    /// path re-adds an output — `handleSystemDidWake()` is the one thing that clears
    /// it and re-drives convergence.
    private var suspended = false

    /// The wake fallback watchdog's override on the capture gate. When the watchdog
    /// fires (no desired-on device reconnected in time), this flips true and the
    /// gate computes `want == false` even though `expectedSelected` is non-empty —
    /// un-muting the Mac WITHOUT clearing intent. A later reconnect
    /// (`noteWakeReconnect`) clears it and re-reconciles, cleanly re-engaging the gate.
    private var wakeCaptureOverride = false

    /// True between `handleSystemDidWake()` and the first post-wake reconnect (or the
    /// watchdog firing). Gates `noteWakeReconnect` so the reconnect hook is inert
    /// during ordinary operation.
    private var awaitingWakeReconnect = false

    /// The post-wake fallback delay in seconds (Settings › Audio), or `nil` for
    /// "Never". Pushed by the app layer via ``setWakeAudioRestoreDelay(_:)``; read
    /// when arming the watchdog on wake. Confined to `stateQueue`.
    private var wakeAudioRestoreDelay: TimeInterval?

    /// The armed post-wake watchdog, scheduled on `stateQueue`. Cancelled on the
    /// first reconnect, on a new sleep/wake cycle, or on `stop()`.
    private var wakeWatchdog: DispatchWorkItem?

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

    /// Ids currently mid-``applyStartBuffer`` teardown/re-add. A buffer-size change
    /// removes every streaming output and re-adds it through the SAME converge
    /// add-success branch a real (re)connect uses — but it is NOT a reconnect: the
    /// user's in-session volume must survive it (``applyStartBuffer`` re-pushes that
    /// exact level itself). This set is how the shared add path tells the two apart:
    /// while an id is in it, ``connectVolumeSeed(_:outputID:)`` is suppressed, so a
    /// plain buffer change never slams the level back to the system volume. See
    /// ``connectVolumeSeed(_:outputID:)`` for the −30 dB trap the whole seed exists
    /// to avoid.
    private var bufferReAdding: Set<String> = []

    private var stateStreamTask: Task<Void, Never>?

    /// The in-flight engine-teardown Task from the last `stop()` (C1). Stored so
    /// `stopAndWait(timeout:)` can await it on the app's terminate path. Confined to
    /// `stateQueue` like everything else.
    private var engineStopTask: Task<Void, Never>?

    // MARK: Per-app routing state (T6 — all confined to `stateQueue`)

    /// The bundle IDs most recently routed to a specific device (a `.device(id:)`
    /// route). `updateAppRoutes` diffs the new set against this to decide which
    /// per-app captures to `start`/`stop`.
    private var routedBundleIDs: Set<String> = []

    /// The bundle IDs most recently routed to `.currentDevice` (Bug T2): captured
    /// by their own per-app tap (so excluded from the whole-system mix) and played
    /// back locally on the Mac's built-in speakers via ``localPlaybackEngine`` as
    /// an independent stream. `updateAppRoutes` diffs the new set against this.
    /// Kept SEPARATE from `routedBundleIDs`: both drive a per-app tap, but a
    /// device route feeds the ``routeMixer`` → AirPlay, whereas a local route feeds
    /// ``localPlaybackEngine`` → built-in speakers. The per-app CAPTURE is started
    /// for the UNION of the two (the tap is destination-agnostic).
    private var localBundleIDs: Set<String> = []

    /// bundleID → its route's display name, so a `.routedApps` event can carry
    /// human-readable app names. Refreshed on every `updateAppRoutes`.
    private var routeDisplayNames: [String: String] = [:]

    /// deviceID → the per-app `stream_id` it is currently bound to (≥ 1). The live
    /// truth `handleDestinationSetsChanged` diffs against to issue the minimal set
    /// of engine bind/rebind/unbind ops. Distinct from `added` (the legacy
    /// stream_id-0 output set), which this never touches.
    private var streamBindings: [String: UInt32] = [:]

    /// deviceID → the sorted app display names last published via `.routedApps`, so
    /// the event fires only when a device's live app mapping actually changes.
    private var routedAppNames: [String: [String]] = [:]

    /// FIFO chain that serializes the per-app engine bind ops. Each new op awaits
    /// the previous one's completion before running, so a device's stop→re-add on a
    /// stream change can never interleave with a later change's ops. Confined to
    /// `stateQueue` (submitted in decision order under the lock), mirroring how
    /// `captureControlQueue` replays capture-gate decisions in order.
    private var bindTail: Task<Void, Never> = Task {}

    // MARK: Per-app routing edge cases (T8)
    //
    // Three gaps the happy-path T6/T7 build didn't cover:
    //  1. A routed app's PROCESS quits mid-stream. Core Audio never signals this
    //     (a per-process tap on a dead pid doesn't error or EOF) — the only
    //     detection is `NSWorkspace.didTerminateApplicationNotification`, which
    //     Core can't call itself. `handleAppTerminated(bundleID:)` is the AppKit
    //     boundary's forwarding target (mirrors the `resolvePID` injection).
    //  2. The DEVICE a route targets disappears. Already flows end-to-end through
    //     the existing generic pipeline — `AppRoutingController.handleDeviceUnavailable`
    //     (fired from `PopoverController.update(devices:)`, PLAN decision 7) resets
    //     the persisted route to `.noRedirect` and fires `onRoutesDidChange`,
    //     which reaches `updateAppRoutes` below exactly like any other route edit.
    //     No new state needed here — `NativeBackendTests.
    //     testDeviceUnavailableTearsDownBackendCaptureViaAppRoutingController`
    //     proves the two layers stay in sync (T10).
    //  3. A per-app tap FAILS (`.processNotYetAudible` most commonly — routed
    //     before the app started playing audio). `deadBundleIDs` below excludes a
    //     failed bundle ID from the mixer topology so `.routedApps` never claims a
    //     silent app is streaming, and `updateAppRoutes`'s blanket per-route
    //     `perAppCapture.start` retry (below) recovers it the moment ANYTHING else
    //     touches the route table. `.processNotYetAudible` specifically also gets a
    //     few short, bounded timer retries (`scheduleProcessNotYetAudibleRetry`) so
    //     a route made just before pressing play self-heals without the user
    //     touching the UI again — every OTHER failure needs the user to act
    //     (grant permission, update macOS), so only THAT one case is retried blindly.

    /// The full route table `updateAppRoutes` was last called with — kept so a
    /// later app-quit (`handleAppTerminated`) or capture-health change
    /// (`handlePerAppCaptureHealthChange`) can recompute the mixer topology
    /// without the route table having changed (the persisted route survives an
    /// app quit — PLAN §C — so nothing else re-drives `updateAppRoutes` for it).
    private var lastRoutes: [AppRoute] = []

    /// Bundle IDs currently known NOT to be producing audio despite an active
    /// `.device(id:)` route: quit mid-stream (`handleAppTerminated`) or a failed
    /// per-app capture (`handlePerAppCaptureHealthChange`). Excluded from
    /// ``effectiveMixerRoutes()`` so the mixer topology — and therefore
    /// `.routedApps` and the engine stream bindings — only ever reflects apps
    /// actually capturing, never a stale "streaming" claim for one that quit or
    /// never got permission. Cleared the moment the bundle ID stops being routed
    /// at all (`updateAppRoutes`) or starts `.capturing` again (a successful retry).
    private var deadBundleIDs: Set<String> = []

    /// Routed bundle IDs that have reached `.capturing` at least once. Lets a
    /// LATER `.capturing` transition be recognised as a RE-capture — i.e. the
    /// per-app tap was torn down and rebuilt (a sample-rate/device change), which
    /// puts a discontinuity into the input stream. After such a rebuild the
    /// AirPlay RTP session for this app's device(s) is desynced from the receiver
    /// and never self-heals (we keep writing real PCM but the receiver stays
    /// silent), so a re-capture triggers a session reset (rebind). Cleared when
    /// the bundle stops being routed or its capture stops.
    private var everCapturedBundleIDs: Set<String> = []

    /// bundleID → how many bounded `.processNotYetAudible` retries have already
    /// fired (edge case 3). Reset on recovery (`.capturing`) or on losing the
    /// route entirely.
    private var retryCounts: [String: Int] = [:]

    /// bundleID → its in-flight bounded retry, so a second failure while one is
    /// already scheduled replaces rather than stacks it, and a recovery /
    /// de-route can cancel it (best-effort — a `DispatchWorkItem` already
    /// running when cancelled still completes, same D4 tolerance as everywhere
    /// else in this file).
    private var pendingRetries: [String: DispatchWorkItem] = [:]

    /// How long to wait before retrying a `.processNotYetAudible` failure.
    /// `var`-free `let`, injectable only through the designated initializer so
    /// tests can shrink it — production never needs to.
    private let processNotYetAudibleRetryDelay: TimeInterval

    /// How many bounded `.processNotYetAudible` retries to attempt before giving
    /// up and leaving the bundle ID `.failed` (still excluded from the mixer via
    /// `deadBundleIDs`, but no longer automatically retried — the blanket retry
    /// in `updateAppRoutes` can still recover it later if the route table is
    /// touched for any other reason).
    private let processNotYetAudibleMaxRetries: Int

    // MARK: Init

    /// Public seam: the real native backend over the in-process ``AirPlayEngine``
    /// and a live ``NativeDiscovery`` (`NWBrowser`). `EngineControlling` /
    /// `DiscoverySource` stay internal-facing (tests inject doubles); no engine or
    /// OwnTone type leaks into the public surface.
    ///
    /// `resolvePID` maps a bundle ID to the running app's pid (for per-app capture,
    /// T6). It defaults to "nothing resolves" because Core can't import AppKit; the
    /// AppKit-importing layer (T7's `AppDelegate`) threads the real
    /// `NSRunningApplication`-backed resolver in. It flows to BOTH the per-app
    /// capture coordinator (owned here) and the whole-system `NativeCaptureCoordinator`
    /// (wired by `makeBackend`, which uses the same closure).
    public convenience init(
        engine: AirPlayEngine,
        discovery: NativeDiscovery = NativeDiscovery(),
        resolvePID: @escaping @Sendable (String) -> pid_t? = { _ in nil }
    ) {
        self.init(
            engineControl: EngineAdapter(engine: engine),
            discoverySource: discovery,
            resolvePID: resolvePID)
    }

    /// Injectable designated initializer (internal — tests pass a spy engine and an
    /// injected discovery double so the whole backend runs with no engine, network,
    /// or TCC).
    ///
    /// `systemVolume` defaults to the real ``SystemOutputVolume`` so the convenience
    /// init (and `makeBackend`) stay unchanged; tests inject a fake and drive the
    /// local row with no audio hardware in the loop.
    ///
    /// `resolvePID` is threaded into the per-app capture coordinator constructed
    /// here (T6). Its default (`{ _ in nil }`) keeps the per-app path inert for
    /// every existing test: with no pid ever resolving, `perAppCapture.start` fails
    /// fast (`.appNotRunning`) and never opens a Core Audio tap — so the routing
    /// TOPOLOGY (`addOutput(_:streamId:)` bindings + `.routedApps` events), which is
    /// derived purely from the route table, still exercises fully.
    ///
    /// `perAppCapture` is normally built internally from `resolvePID` (production
    /// shape); tests that need to script per-app tap behavior (T8: a quit mid-stream,
    /// a `.processNotYetAudible` failure/recovery) instead construct a
    /// ``PerAppCaptureCoordinator`` over a fake ``ProcessAudioTap`` themselves and
    /// pass it in here, bypassing the real Core Audio path entirely — mirrors how
    /// `engineControl`/`discoverySource` are always doubles in this init.
    /// `processNotYetAudibleRetryDelay`/`processNotYetAudibleMaxRetries` (T8) tune
    /// the bounded retry for a `.processNotYetAudible` capture failure; tests shrink
    /// the delay so the retry doesn't cost real wall-clock seconds.
    init(
        engineControl: EngineControlling,
        discoverySource: DiscoverySource,
        systemVolume: SystemVolumeControlling = SystemOutputVolume(),
        resolvePID: @escaping @Sendable (String) -> pid_t? = { _ in nil },
        injectedPerAppCapture: PerAppCaptureCoordinator? = nil,
        processNotYetAudibleRetryDelay: TimeInterval = 2.0,
        processNotYetAudibleMaxRetries: Int = 5
    ) {
        self.engine = engineControl
        self.discovery = discoverySource
        self.systemVolume = systemVolume
        self.perAppCapture = injectedPerAppCapture ?? PerAppCaptureCoordinator(resolvePID: resolvePID)
        self.routeMixer = AppRouteMixer()
        self.processNotYetAudibleRetryDelay = processNotYetAudibleRetryDelay
        self.processNotYetAudibleMaxRetries = processNotYetAudibleMaxRetries

        // Wire the per-app routing callback graph (T6/T8). All four are set once
        // here, never mutated after, so no `stateQueue` synchronization is needed
        // for the assignment itself; the handlers hop to `stateQueue`/the engine as
        // needed. (`self.` is required from here on for `perAppCapture`/`routeMixer`:
        // both are `let`-bound already, but keeping `self.` makes it unambiguous that
        // these are the STORED properties, not the initializer's `injectedPerAppCapture`
        // parameter.)
        self.perAppCapture.onStateChange = { [weak self] bundleID, state in
            self?.routeMixer.handleStateChange(bundleID: bundleID, state: state)
            self?.handlePerAppCaptureHealthChange(bundleID: bundleID, state: state)
            // Bug T2: a `.currentDevice` app reaching `.capturing` gets its own
            // local player (its `TapFormat` is now known); leaving `.capturing`
            // drops it. A no-op for `.device`-routed apps (guarded on
            // `localBundleIDs`).
            self?.handleLocalCaptureStateChange(bundleID: bundleID, state: state)
        }
        self.perAppCapture.onBuffer = { [weak self] bundleID, buffer in
            // Fan every per-app buffer to BOTH consumers. Each ignores what isn't
            // its own: the mixer drops a buffer for a bundle with no `.device`
            // stream, and the local engine drops one for a bundle with no player —
            // so a `.device` app's audio only reaches the mixer and a
            // `.currentDevice` app's only reaches the local engine, with no shared
            // set read on this hot delivery-thread path.
            if AudioDiag.isEnabled {
                // Report buffer PEAK, not just count: a process tap keeps
                // delivering buffers at full cadence but SILENT (all-zero) after a
                // sample-rate renegotiation — so a count-only meter (the earlier
                // bug) looks healthy while the audio is gone. peak≈0 while the app
                // is audibly playing == the documented silent-buffer condition.
                AudioDiag.tick("perAppBuffer:\(bundleID)", detail: "peak=\(Self.diagFloatPeak(buffer))")
            }
            self?.routeMixer.handleBuffer(bundleID: bundleID, buffer: buffer)
            self?.localPlaybackEngine?.receive(buffer: buffer, for: bundleID)
        }
        routeMixer.onDestinationSetsChanged = { [weak self] sets in
            self?.handleDestinationSetsChanged(sets)
        }
        routeMixer.onMixedBuffer = { [weak self] mixed in
            // `engine.write` is nonisolated + fire-and-forget — safe from the
            // mixer's queue with no hop. streamID is ≥ 1 (0 is the legacy path).
            if AudioDiag.isEnabled {
                // What actually reaches the AirPlay engine for a redirected app.
                // peak≈0 here while the tap peak is non-zero == the mixer/convert
                // path is dropping content; the stream binding (which device this
                // stream is on) tells us if the engine session is still wired.
                AudioDiag.tick("engineWrite:stream\(mixed.streamID)",
                               detail: "s16peak=\(Self.diagS16Peak(mixed.pcm)) frames=\(mixed.frameCount)")
            }
            self?.engine.write(
                pcm: mixed.pcm, streamId: UInt32(mixed.streamID), pts: mixed.pts)
        }
    }

    // MARK: OutputBackend

    // STABILITY(C8): main thread blocks on the state queue for slow work — see dev/notes/stability-audit-2026-07-18.md
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
        // Snapshot the local output's HAL state OFF `stateQueue` (B3): these are
        // blocking Core Audio reads and must not run inside the critical section the
        // main-thread `devices` getter waits on. Lock-free and valid before
        // `systemVolume.start()` (SystemOutputVolume's contract), which is what lets
        // them run here, ahead of the queue hop.
        let localName = Self.currentOutputDeviceName()
        let localVolume = systemVolume.currentVolume()
        let localMuted = systemVolume.currentMuted()
        stateQueue.async {
            guard !self.started else { return }
            self.started = true
            // Surface the Mac's OWN current output device immediately (BUG B), so
            // the popover has a "Current Device" row and GroupController can seed
            // the local-passthrough default the moment `start()` runs — before any
            // AirPlay discovery, and independent of whether the engine comes up.
            // It is NEVER fed to the engine or `addOutput`-ed: it's the local
            // output, not an AirPlay receiver (guarded everywhere by
            // `isLocalDevice` / `supportsAirPlay2 == false`).
            self.surfaceLocalDevice(name: localName, volume: localVolume, muted: localMuted)
        }

        // 1. Wire discovery → the app model + the engine descriptor feed. AP2
        //    devices additionally get fed to `engine.updateDiscovery` so the engine
        //    knows about them (a prerequisite for `addOutput`). AP1 devices are
        //    surfaced but never fed to the engine.
        discovery.onEvent = { [weak self] event in self?.handleDiscovery(event) }

        // 1b. TWO-WAY SYNC for the local row. Its slider/mute ARE the Mac's default
        //     output, so changes made outside this app have to flow back in: the
        //     media keys, the Sound menu, another app — or the default DEVICE itself
        //     switching (speakers → AirPods), which usually means a wholly different
        //     volume/mute pair AND a different name is now in force.
        //
        //     Deliberately wired here on the caller's thread, NOT inside the engine
        //     Task below: the local row must work even if the engine never comes up
        //     (same reason `surfaceLocalDevice` runs unconditionally above). The
        //     helper suppresses echoes of our own writes, so this cannot loop back
        //     against `setVolume`/`setMuted`.
        systemVolume.onExternalChange = { [weak self] volume, muted, defaultDeviceChanged in
            guard let self else { return }
            // A default-device switch reports no name, so re-read it every time: this
            // is the one path that relabels the row. Read it HERE, on the helper's own
            // callback thread, BEFORE hopping to `stateQueue` (B3): it is a blocking
            // Core Audio HAL read, and running it inside the critical section stalls
            // every `stateQueue` waiter — including the main-thread `devices` getter —
            // when coreaudiod is busy (device switches, sleep/wake). An unchanged name
            // is harmless: `applyLocal` suppresses the no-op emit anyway.
            let name = Self.currentOutputDeviceName()
            // Fires on the helper's OWN private serial queue, never main — hop to the
            // queue that owns `known` before touching the model.
            self.stateQueue.async {
                let previousVolume = self.known[Self.localDeviceID]?.volume
                self.applyLocal(Self.localDeviceID) { device in
                    device.name = name
                    // nil = that control is unreadable on this device; leave the last
                    // known value rather than fabricating a 0/false.
                    if let volume { device.volume = volume }
                    if let muted { device.isMuted = muted }
                }

                // 1c. VOLUME-KEY MIRROR. Syncing the row above is necessary but not
                //     sufficient: while streaming, the capture tap MUTES the local
                //     output, so the keys move a slider for a device nobody can hear
                //     while the AirPlay speakers ignore them (ahh, live session
                //     2026-07-17). Republish the change so the routing brain can
                //     mirror it onto whatever is actually playing.
                //
                //     This backend must NOT reach up into `GroupController` — it sits
                //     BELOW the routing brain and knows nothing about Main Out — so it
                //     states the FACT on the event stream and lets `AppDelegate` route
                //     it. Deciding what to do with it is emphatically not this layer's
                //     business; this layer only knows the system volume moved.
                //
                //     Two filters, both load-bearing:
                //     - `!defaultDeviceChanged` — a speakers → AirPods switch also
                //       reports a fresh volume, but that's the NEW device's existing
                //       level, not a gesture. Mirroring it would slam every AirPlay
                //       speaker to whatever the headphones sat at.
                //     - `volume != previousVolume` — `onExternalChange` also fires for
                //       a mute-only change. Mirroring an unmoved volume would be a
                //       no-op write per keypress-that-wasn't; only a real move is news.
                //     Echoes of our OWN writes never arrive here at all —
                //     `SystemOutputVolume` suppresses those by comparing a fresh read
                //     against its last-known state, which is why no flag is needed to
                //     tell the volume keys from our own slider.
                if !defaultDeviceChanged, let volume, volume != previousVolume {
                    self.emit(.systemVolumeChanged(volume: volume))
                }
            }
        }
        systemVolume.start()

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

            // 5. WIRE the capture pipeline's metering (real path only) so its RMS
            //    fans out as `.level` for selected, unmuted devices — but do NOT
            //    start capture here. The tap mutes the Mac's own speakers while it
            //    runs, so starting it unconditionally silenced the default
            //    passthrough state (no AirPlay outputs selected ⇒ captured audio
            //    goes nowhere). Capture is started/stopped by
            //    `reconcileCaptureGate()` off `setOutputSet`, i.e. only while a
            //    real AP2 output is actually selected. `onLevel` is harmless to
            //    wire early: it only fires while the tap is running.
            self.captureCoordinator?.onLevel = { [weak self] rms in self?.emitLevel(rms) }
        }
    }

    public func stop() {
        // Stop delivering levels; the whole-system capture tap itself is torn down by
        // the ORDERED `captureControlQueue` stop below — NOT eagerly here (C1). An
        // eager caller-thread `captureCoordinator?.stop()` did a `queue.sync` + HAL
        // teardown inline, blocking the caller (main, on the quit path) behind
        // coreaudiod and behind any in-flight start; the ordered stop is the
        // documented final word and reaches the same state off the caller thread.
        // Then discovery, then the engine itself.
        captureCoordinator?.onLevel = nil
        // Per-app routing (T6): stop every process tap and drain the mixer. Both are
        // off `stateQueue` (teardown may block on Core Audio), matching the
        // whole-system tap's stop above. Callbacks stay wired — they only fire while
        // captures run, and a later `start()`/`updateAppRoutes` reuses the same graph.
        perAppCapture.stopAll()
        routeMixer.flush()
        // Local playback (Bug T2): stop the built-in-output engine and drop every
        // per-app player. Off `stateQueue` like the taps above (AVAudioEngine
        // teardown); a later `start()`/`updateAppRoutes` re-adds players on demand.
        localPlaybackEngine?.stop()
        discovery.onEvent = nil
        discovery.stop()
        // Drop the local row's two-way sync (the row itself is removed below).
        systemVolume.onExternalChange = nil
        systemVolume.stop()

        // Engine teardown stays fire-and-forget so `stop()` never blocks its caller,
        // but the Task is now STORED (C1) so the app layer can await it via
        // `stopAndWait(timeout:)` on the terminate path — otherwise process exit
        // outruns the RTSP/RTP teardown and the AirPlay sessions are cut un-gracefully.
        let engine = self.engine
        let engineStop = Task { await engine.stop() }

        stateQueue.async {
            self.engineStopTask = engineStop
            // stateStreamTask is confined to stateQueue (finding 8): a start()
            // immediately followed by stop() would otherwise race the assignment in
            // subscribeStateStream (which now also runs on stateQueue) against this
            // cancellation, leaving the consumer task running against a torn-down
            // backend or interleaving the two writes.
            self.stateStreamTask?.cancel()
            self.stateStreamTask = nil
            self.started = false
            // Reset the capture gate: a later start() re-decides from scratch, and
            // capture stays off until a setOutputSet selects a real AP2 output.
            self.captureRunning = false
            // B6b: drop any pending wake watchdog + reset sleep/wake flags so a stop
            // mid-wait can't leave capture wedged off (override) or suspended.
            self.wakeWatchdog?.cancel()
            self.wakeWatchdog = nil
            self.awaitingWakeReconnect = false
            self.wakeCaptureOverride = false
            self.suspended = false
            // `captureControlQueue` gets the last word — and, since the eager
            // caller-thread stop is gone (C1), it is now the ONLY stop. A bare
            // caller-thread stop would be unordered against a start still queued from
            // a just-prior setOutputSet — that start would land after it and leave the
            // tap running (muting the Mac) with the backend torn down. Enqueued from
            // inside this critical section, this stop is ordered after every gate
            // decision that preceded it, so the FIFO's final op is always the stop.
            // Idempotent.
            if let coordinator = self.captureCoordinator {
                self.captureControlQueue.async { coordinator.stop() }
            }
            let ids = self.order
            self.known.removeAll()
            self.order.removeAll()
            self.outputIDs.removeAll()
            self.added.removeAll()
            self.volumeInFlight.removeAll()
            self.volumePending.removeAll()
            self.expectedSelected.removeAll()
            self.desiredOn.removeAll()
            self.converging.removeAll()
            self.failedGate.removeAll()
            self.fedDescriptors.removeAll()
            self.muted.removeAll()
            self.stashedVolume.removeAll()
            // Per-app routing state (T6): reset so a later start() re-decides from a
            // clean slate. The engine sessions themselves are torn down by
            // `engine.stop()` above; cancel the bind FIFO and forget the bindings so
            // the next `updateAppRoutes` re-binds from scratch rather than diffing
            // against stale ids.
            self.bindTail.cancel()
            self.bindTail = Task {}
            self.routedBundleIDs.removeAll()
            self.localBundleIDs.removeAll()
            self.routeDisplayNames.removeAll()
            self.streamBindings.removeAll()
            self.routedAppNames.removeAll()
            // T8 edge-case tracking resets alongside the rest of the per-app state —
            // a later start() begins with no bundle ID considered dead or mid-retry.
            self.lastRoutes.removeAll()
            self.deadBundleIDs.removeAll()
            self.everCapturedBundleIDs.removeAll()
            self.retryCounts.removeAll()
            for work in self.pendingRetries.values { work.cancel() }
            self.pendingRetries.removeAll()
            self.bufferReAdding.removeAll()
            for id in ids { self.emit(.deviceRemoved(id: id)) }
        }
    }

    /// Await the engine teardown that ``stop()`` fired, bounded by `timeout` (C1).
    ///
    /// ``stop()`` kicks engine teardown off as a detached Task so it never blocks its
    /// caller; on a normal app quit that Task can be outrun by process exit, cutting
    /// the AirPlay RTSP/RTP sessions un-gracefully (receivers are left to time the
    /// session out on their own). `applicationShouldTerminate` (T3, a later task —
    /// wired via the ``OutputBackend`` seam) calls this AFTER ``stop()`` to give that
    /// teardown a bounded window to finish gracefully.
    ///
    /// Returns as soon as EITHER the engine teardown completes OR `timeout` elapses,
    /// whichever is first — it never blocks on a wedged engine (coreaudiod / a stuck
    /// RTSP socket must not hang the quit). The detached teardown Task keeps running
    /// regardless; this only bounds how long the caller waits on it. Call after
    /// ``stop()``; a no-op (returns immediately) if no teardown is in flight.
    public func stopAndWait(timeout: Duration) async {
        guard let task = stateQueue.sync(execute: { self.engineStopTask }) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeOnce(continuation)
            // Whichever finishes first resumes; the other resume is swallowed.
            Task { await task.value; gate.resume() }
            Task { try? await Task.sleep(for: timeout); gate.resume() }
        }
    }

    public func setVolume(_ volume: Int, for id: String) {
        let clamped = volume.clampedToVolume
        // The local row is not an engine output — it has no `outputIDs` entry, so the
        // guard below would drop this write on the floor (the reason its slider did
        // nothing). Drive the Mac's own default output device instead.
        if id == Self.localDeviceID {
            // The model update is `stateQueue`'s (it owns `known`); the Core Audio
            // write is NOT — it must never run on the queue every device update is
            // behind. Both orders survive a slider drag: same-thread callers enqueue
            // to `stateQueue` and to the helper's queue in FIFO order.
            stateQueue.async { self.applyLocal(id) { $0.volume = clamped } }
            systemVolume.setVolume(clamped)
            return
        }
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
        // The local row gets REAL hardware mute (`kAudioDevicePropertyMute` on the
        // Mac's default output), deliberately NOT the stashed-volume shim the engine
        // path below uses. The shim exists only because the engine has no mute field;
        // Core Audio has a real one, and a user muting their Mac expects the system
        // mute — so nothing is stashed or restored here, and `self.muted` (the shim's
        // bookkeeping) stays untouched for this id. `Device.isMuted` is the row's
        // only mute state, and `applyLocal` suppresses the emit when it's unchanged.
        if id == Self.localDeviceID {
            stateQueue.async { self.applyLocal(id) { $0.isMuted = muted } }
            systemVolume.setMuted(muted)   // off `stateQueue`, as in `setVolume`
            return
        }
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
        // STABILITY(C8): main thread blocks on the state queue for slow work — see dev/notes/stability-audit-2026-07-18.md
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
                // Connection-status brief §1/§3 semantics (mirrors OwnToneBackend's
                // `setOutputSet`): a device newly desired ON goes `.connecting`
                // immediately, before the engine op resolves, so the UI spinner is
                // immediate. This also clears a sticky `.failed` on retry (the
                // `failedGate` clear above is the routing-side twin of this). A
                // device newly desired OFF drops any in-flight/failed indication
                // back to `.off` right away — NativeBackend has no "sticky failed
                // survives deselect" behavior (its park is cleared on toggle
                // unconditionally, above), so the connection dot follows suit.
                if previous != wantOn {
                    self.setConnectionState(wantOn ? .connecting : .off, for: id)
                }
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

            // Selection is the ONLY thing that moves the capture gate, so this is
            // its one call site. Deliberately NOT called from `applyStartBuffer`:
            // that flaps `desiredOn` internally (remove-all → set → re-add) but
            // never touches `expectedSelected`, and must not stop/restart the tap
            // mid-apply. Runs inside this critical section so the enqueued
            // start/stop order matches the decision order exactly.
            self.reconcileCaptureGate()
            return kicks
        }

        for (id, outputID) in toKick {
            Task { [weak self] in
                guard let self else { return }
                await self.convergeDevice(id: id, outputID: outputID)
            }
        }
    }

    // MARK: Per-app routing (T6 — ADDITIVE to the Selected Devices path above)

    /// Feed the current per-app routing table in. The single external entry point
    /// for per-app redirect (T7 calls this whenever `AppRoutingController.appRoutes`
    /// changes, passing the Settings excluded-apps denylist as `excludedBundleIDs`).
    ///
    /// This is ADDITIVE: it never touches `expectedSelected` / `added` / the capture
    /// gate — the whole-system "Selected Devices" path (stream_id 0) keeps working
    /// exactly as before. On call it:
    ///  1. Recomputes the mixer topology (`routeMixer.updateRoutes`), which fires
    ///     `onDestinationSetsChanged` synchronously iff the distinct app-sets changed
    ///     — that handler binds each destination device to its stream_id and emits
    ///     `.routedApps`.
    ///  2. Starts a per-app capture for each newly-captured bundle ID (routed to a
    ///     `.device` OR to `.currentDevice`) and stops the capture for each app that
    ///     dropped out of BOTH (back to `.noRedirect` / removed). The tap is
    ///     destination-agnostic, so its lifecycle keys on the UNION of the two sets.
    ///  3. For `.currentDevice` apps (Bug T2): renders each on the Mac's built-in
    ///     speakers via ``localPlaybackEngine`` as an independent stream, and adds
    ///     them to the whole-system tap's exclusion set so they don't ALSO play in
    ///     the AirPlay mix.
    ///  4. Syncs the whole-system tap's exclusion set (T4) so individually-routed
    ///     (`.device`) AND `.currentDevice` apps don't double up into the system mix.
    ///
    /// Concurrency: the routed-bundle-ID diff and the display-name refresh happen
    /// under `stateQueue` (serialized against concurrent calls). Everything that can
    /// BLOCK — `perAppCapture.start`/`stop` (Core Audio tap create/teardown), the
    /// `localPlaybackEngine` graph mutations, and the mixer's own queue hop — runs
    /// OUTSIDE `stateQueue`, the same discipline the capture gate keeps for
    /// `captureControlQueue`.
    public func updateAppRoutes(_ routes: [AppRoute], excludedBundleIDs: Set<String> = []) {
        let plan: UpdateRoutesPlan = stateQueue.sync {
            self.lastRoutes = routes
            self.routeDisplayNames = Dictionary(
                routes.map { ($0.bundleID, $0.displayName) }, uniquingKeysWith: { _, new in new })
            let newRouted = Set(routes.compactMap { route -> String? in
                if case .device = route.destination { return route.bundleID }
                return nil
            })
            // Bug T2: apps deliberately pinned to the local Mac ("Current Device").
            let newLocal = Set(routes.compactMap { route -> String? in
                route.destination == .currentDevice ? route.bundleID : nil
            })
            let previousRouted = self.routedBundleIDs
            let previousLocal = self.localBundleIDs
            self.routedBundleIDs = newRouted
            self.localBundleIDs = newLocal

            // T8: a bundle ID that isn't in the route table at all any more (fully
            // de-routed or its app-route removed) forgets any dead/retry tracking —
            // a fresh route later starts clean, not still "dead" from a stale
            // failure against a previous route.
            let stillPresent = Set(routes.map(\.bundleID))
            for bundleID in self.deadBundleIDs where !stillPresent.contains(bundleID) {
                self.deadBundleIDs.remove(bundleID)
            }
            for bundleID in self.retryCounts.keys where !stillPresent.contains(bundleID) {
                self.retryCounts.removeValue(forKey: bundleID)
            }
            for bundleID in self.pendingRetries.keys where !stillPresent.contains(bundleID) {
                self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
            }
            for bundleID in self.everCapturedBundleIDs where !stillPresent.contains(bundleID) {
                self.everCapturedBundleIDs.remove(bundleID)
            }

            // T8: the mixer only ever sees routes for bundle IDs that are actually
            // capturing — a `deadBundleIDs` entry (quit mid-stream, or a per-app tap
            // that's `.failed`) is excluded here so `.routedApps` / the engine stream
            // binding never claim a silent app is streaming.
            let mixerRoutes = routes.filter { !self.deadBundleIDs.contains($0.bundleID) }

            // The per-app tap is destination-agnostic — one tap serves whichever
            // destination the app currently routes to — so its start/stop keys on
            // the UNION of device- and local-routed apps. An app that merely SWITCHES
            // between `.device` and `.currentDevice` stays in both unions and keeps
            // its tap running (only the downstream consumer changes).
            let previousUnion = previousRouted.union(previousLocal)
            let newUnion = newRouted.union(newLocal)
            return UpdateRoutesPlan(
                mixerRoutes: mixerRoutes,
                captureToStart: newUnion.subtracting(previousUnion),
                captureToStop: previousUnion.subtracting(newUnion),
                localRemoved: previousLocal.subtracting(newLocal),
                localRoutes: routes.filter { $0.destination == .currentDevice },
                localExcluded: newLocal)
        }

        // Topology recompute — synchronously fires `onDestinationSetsChanged`
        // (→ `handleDestinationSetsChanged`) if the distinct app-sets changed. Off
        // `stateQueue`: the mixer owns its own serial queue, and the handler re-enters
        // `stateQueue` on its own (we are not holding it here). Kept SYNCHRONOUS: it's
        // pure in-memory topology math (no Core Audio), and it drives the engine
        // stream binding (via async `bindTail` Tasks), so the redirect still starts
        // connecting immediately.
        routeMixer.updateRoutes(plan.mixerRoutes)

        // Everything below BLOCKS on Core Audio / AVAudioEngine (per-app tap
        // create+`AudioDeviceStart`, the AVAudioEngine graph mutation, the
        // whole-system tap recreate). `updateAppRoutes` is called on the MAIN THREAD
        // (a popover destination pick → `onRoutesDidChange`, or an `NSWorkspace`
        // launch/terminate notification), so running these inline froze the UI for
        // the duration of `AudioDeviceStart`'s HAL round-trip. Hand them to the
        // serial `captureControlQueue` (the same queue the whole-system capture gate
        // uses) so they run OFF the main thread and stay ordered against each other
        // and against the gate. `perAppCapture` / `localPlaybackEngine` are each
        // independently thread-safe; `start`/`stop`/`addApp` are idempotent.
        captureControlQueue.async { [weak self] in
            guard let self else { return }

            // Per-app capture lifecycle. `start`/`stop` are idempotent per bundle ID.
            for bundleID in plan.captureToStart { self.perAppCapture.start(bundleID: bundleID) }
            for bundleID in plan.captureToStop { self.perAppCapture.stop(bundleID: bundleID) }

            // Local playback (Bug T2):
            //  - Drop players for apps that left `.currentDevice`.
            //  - (Re)add + re-level every current `.currentDevice` app whose tap is
            //    ALREADY capturing — this covers a `.device`→`.currentDevice` switch,
            //    where the tap keeps running so no fresh `.capturing` transition fires
            //    `handleLocalCaptureStateChange`. `addApp` is idempotent, so overlapping
            //    with that handler (for apps whose tap starts fresh) is harmless.
            for bundleID in plan.localRemoved { self.localPlaybackEngine?.removeApp(bundleID: bundleID) }
            for route in plan.localRoutes {
                if case .capturing(let format) = self.perAppCapture.state(for: route.bundleID) {
                    try? self.localPlaybackEngine?.start()
                    try? self.localPlaybackEngine?.addApp(
                        bundleID: route.bundleID, tapFormat: format,
                        volume: Float(route.volume) / 100.0)
                }
                self.localPlaybackEngine?.setVolume(Float(route.volume) / 100.0, for: route.bundleID)
            }

            // Keep the whole-system tap excluding individually-routed (`.device`) apps,
            // `.currentDevice` apps (Bug T2 — they play via `localPlaybackEngine`, not
            // the AirPlay mix), and user-excluded apps (T4). No-op when no real capture
            // coordinator is wired (tests/UI-smoke).
            self.captureCoordinator?.updateRouting(
                appRoutes: routes, excludedBundleIDs: excludedBundleIDs.union(plan.localExcluded))
        }
    }

    /// The off-`stateQueue` work `updateAppRoutes` computes under the lock and then
    /// executes without it — a named struct so the (now six-field) hand-off stays
    /// readable.
    private struct UpdateRoutesPlan {
        let mixerRoutes: [AppRoute]
        let captureToStart: Set<String>
        let captureToStop: Set<String>
        let localRemoved: Set<String>
        let localRoutes: [AppRoute]
        let localExcluded: Set<String>
    }

    /// React to a per-app capture's state transition for LOCAL (`.currentDevice`)
    /// playback (Bug T2). A no-op unless `bundleID` is currently a `.currentDevice`
    /// route. On `.capturing` (the tap's real `TapFormat` is now known) it starts
    /// the local engine and adds the app's player at its route volume; on any
    /// non-capturing terminal/transitional state it drops the player. Runs off
    /// `stateQueue` (callback context); hops on only to read `localBundleIDs` /
    /// `lastRoutes`. Distinct from `handlePerAppCaptureHealthChange`, which owns the
    /// `.device`/mixer side's dead-bundle tracking.
    private func handleLocalCaptureStateChange(
        bundleID: String, state: PerAppCaptureCoordinator.State
    ) {
        switch state {
        case .capturing(let format):
            let volume: Float? = stateQueue.sync {
                guard self.localBundleIDs.contains(bundleID) else { return nil }
                let vol = self.lastRoutes.first { $0.bundleID == bundleID }?.volume ?? 100
                return Float(vol) / 100.0
            }
            guard let volume else { return }
            try? localPlaybackEngine?.start()
            try? localPlaybackEngine?.addApp(bundleID: bundleID, tapFormat: format, volume: volume)
        case .idle, .stopping, .failed:
            // Capture stopped/failed. Only pull the player while the app is STILL a
            // local route (a capture failure/hiccup, not a de-route): a de-route
            // already removed it from `localBundleIDs` and `updateAppRoutes` dropped
            // the player explicitly, so this skips then — no double-remove, and
            // `removeApp` is idempotent regardless.
            let isLocal = stateQueue.sync { self.localBundleIDs.contains(bundleID) }
            guard isLocal else { return }
            localPlaybackEngine?.removeApp(bundleID: bundleID)
        case .resolvingProcess, .creatingTap:
            // Tap is still starting up — nothing to render yet, nothing to drop.
            break
        }
    }

    /// Set a `.currentDevice`-routed app's LOCAL playback volume (Bug T2). The
    /// low-latency path the popover slider drives directly (mirroring how a
    /// `.device` app's volume rides the route table into the mixer); the same value
    /// also arrives via `updateAppRoutes` from the persisted route edit. Maps the
    /// UI's 0–100 int onto the player node's 0.0…1.0 contract. A no-op for a bundle
    /// ID with no local player (non-`.currentDevice`, or not yet capturing).
    public func setLocalPlaybackVolume(volume: Int, bundleID: String) {
        localPlaybackEngine?.setVolume(Float(volume.clampedToVolume) / 100.0, for: bundleID)
    }

    /// React to a per-app capture's state transition (T8, edge case 3: a
    /// per-process tap fails — most commonly `.processNotYetAudible`, routed
    /// before the app started playing audio — or a previously-dead bundle ID
    /// recovers). Runs off `stateQueue` (callback context from
    /// `PerAppCaptureCoordinator.onStateChange`); hops on only for the mutation.
    ///
    /// `.capturing` clears `deadBundleIDs`/`retryCounts`/`pendingRetries` for the
    /// bundle ID and, if it had been dead, re-includes it in the mixer topology.
    /// `.failed` marks it dead (excluding it from `.routedApps` / the engine stream
    /// binding so a silent app is never claimed as streaming) and, ONLY for
    /// `.processNotYetAudible`, schedules a bounded retry — every other failure
    /// needs the user to act (grant permission, update macOS), so nothing else is
    /// retried blindly.
    private func handlePerAppCaptureHealthChange(
        bundleID: String, state: PerAppCaptureCoordinator.State
    ) {
        switch state {
        case .capturing:
            let (recovered, isRecapture): (Bool, Bool) = stateQueue.sync {
                let wasDead = self.deadBundleIDs.remove(bundleID) != nil
                self.retryCounts.removeValue(forKey: bundleID)
                self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
                // First-ever capture inserts (isRecapture=false); a later capture
                // (tap rebuilt) is already present (isRecapture=true).
                let isRecapture = !self.everCapturedBundleIDs.insert(bundleID).inserted
                return (wasDead, isRecapture)
            }
            if recovered {
                // Was excluded from the topology while dead; re-adding it rebinds
                // the device anyway, so no separate session reset is needed.
                republishMixerTopology()
            } else if isRecapture {
                // The tap was rebuilt with no death in between (a sample-rate
                // change). The topology is unchanged, so the AirPlay session keeps
                // its now-desynced RTP anchor unless we explicitly reset it.
                resetAirPlaySessionForRoutedApp(bundleID: bundleID)
            }

        case .failed(let error):
            let (justDied, shouldRetry, attempt): (Bool, Bool, Int) = stateQueue.sync {
                let justDied = self.deadBundleIDs.insert(bundleID).inserted
                guard self.routedBundleIDs.contains(bundleID),
                      case .processNotYetAudible = error
                else {
                    return (justDied, false, 0)
                }
                let attempt = (self.retryCounts[bundleID] ?? 0) + 1
                self.retryCounts[bundleID] = attempt
                return (justDied, attempt <= self.processNotYetAudibleMaxRetries, attempt)
            }
            if justDied { republishMixerTopology() }
            if shouldRetry {
                scheduleProcessNotYetAudibleRetry(bundleID: bundleID, attempt: attempt)
            }

        case .idle, .resolvingProcess, .creatingTap, .stopping:
            break
        }
    }

    /// Re-run the mixer over the current route table minus dead bundle IDs (T8).
    /// Called whenever `deadBundleIDs` changes OUTSIDE of `updateAppRoutes` itself
    /// (a capture health transition), so the topology — and therefore `.routedApps`
    /// / the engine stream bindings — stays in sync with what's actually capturing.
    private func republishMixerTopology() {
        routeMixer.updateRoutes(effectiveMixerRoutes())
    }

    /// Reset the AirPlay RTP session for every device on `bundleID`'s stream by
    /// rebinding it (removeOutput → addOutput = a fresh RTSP/RTP session with a
    /// clean timeline anchor). Called when a routed app's per-app tap was rebuilt
    /// (a sample-rate/device change), which leaves the receiver desynced and
    /// permanently silent even though real PCM keeps flowing. `streamID(for:)`
    /// reads the mixer's own queue, so it's fetched BEFORE taking `stateQueue`.
    private func resetAirPlaySessionForRoutedApp(bundleID: String) {
        guard let stream = routeMixer.streamID(for: bundleID) else { return }
        let streamU = UInt32(stream)
        stateQueue.sync {
            var ops: [StreamBindOp] = []
            for (deviceID, bound) in self.streamBindings where bound == streamU {
                if let outputID = self.outputIDs[deviceID] {
                    AudioDiag.log("RESET AirPlay session: device=\(deviceID) stream=\(stream) (tap rebuilt)")
                    ops.append(.rebind(outputID, streamU))
                }
            }
            self.enqueueBindOps(ops)
        }
    }

    /// `lastRoutes` filtered to exclude any bundle ID currently in `deadBundleIDs`
    /// (T8). Acquires `stateQueue` itself — call only from OUTSIDE any existing
    /// `stateQueue.sync` block (e.g. not from `updateAppRoutes`'s own critical
    /// section, which computes the equivalent filter inline to avoid a
    /// same-queue deadlock).
    private func effectiveMixerRoutes() -> [AppRoute] {
        stateQueue.sync {
            self.lastRoutes.filter { !self.deadBundleIDs.contains($0.bundleID) }
        }
    }

    /// Schedule one bounded retry of a `.processNotYetAudible` capture failure
    /// (T8, edge case 3) — self-heals a route made just before the app started
    /// playing audio, without the user touching the UI again. Replaces any retry
    /// already pending for this bundle ID. Best-effort (D4): if the route is gone
    /// by the time the timer fires, `perAppCapture.start` fails fast
    /// (`.appNotRunning` or similar) and the failure handler above simply declines
    /// to reschedule (the route no longer being in `routedBundleIDs`).
    private func scheduleProcessNotYetAudibleRetry(bundleID: String, attempt: Int) {
        let work = DispatchWorkItem { [weak self] in
            self?.perAppCapture.start(bundleID: bundleID)
        }
        stateQueue.sync {
            self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
            self.pendingRetries[bundleID] = work
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + processNotYetAudibleRetryDelay, execute: work)
    }

    /// Forward an app-quit notification from the AppKit boundary (T8, edge case 1:
    /// a routed app's process quits mid-stream). `AppDelegate` observes
    /// `NSWorkspace.didTerminateApplicationNotification` and calls this with the
    /// terminated app's bundle ID — Core can't observe AppKit notifications itself,
    /// mirroring the `resolvePID` injection.
    ///
    /// A no-op unless `bundleID` currently has an active `.device(id:)` route: the
    /// PERSISTED route survives the quit (the silent-fallback-to-`.noRedirect`
    /// behavior is reserved for a lost DEVICE, not a quit app — the user may
    /// relaunch the app and expect its route to still apply). Its per-app capture
    /// is stopped, it's marked dead so the mixer topology drops it immediately, and
    /// any pending `.processNotYetAudible` retry is cancelled (retrying a tap for a
    /// pid that no longer exists is pointless).
    public func handleAppTerminated(bundleID: String) {
        let wasRouted: Bool = stateQueue.sync {
            self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
            self.retryCounts.removeValue(forKey: bundleID)
            return self.routedBundleIDs.contains(bundleID)
        }
        guard wasRouted else { return }
        perAppCapture.stop(bundleID: bundleID)
        let justDied: Bool = stateQueue.sync { self.deadBundleIDs.insert(bundleID).inserted }
        if justDied { republishMixerTopology() }
        // Notify the UI that this routed app is no longer running so it can
        // show an offline indicator on the row (T4). The route itself persists
        // (PLAN §C) — only the live streaming state changes.
        stateQueue.async { self.emit(.routedAppRunning(bundleID: bundleID, isRunning: false)) }
    }

    /// React to an app-launch notification forwarded from the AppKit boundary
    /// (T4, bug fix: relaunching a routed app did not restart its capture).
    /// `AppDelegate` observes `NSWorkspace.didLaunchApplicationNotification` and
    /// calls this; Core can't observe AppKit notifications itself, mirroring the
    /// `handleAppTerminated` / `resolvePID` injection pattern.
    ///
    /// Only acts when `bundleID` currently has an active `.device(id:)` route —
    /// a non-routed app launch is silently ignored. On a match it:
    ///  - Clears any dead/retry tracking left over from a prior quit
    ///  - Restarts the per-app Core Audio capture tap (the previous one was
    ///    torn down by `handleAppTerminated` when the process exited)
    ///  - Republishes the mixer topology so `.routedApps` and the engine stream
    ///    binding reflect the restarted app
    ///  - Emits `.routedAppRunning(bundleID:isRunning:true)` so the UI can
    ///    clear any offline indicator it had shown for this app
    public func handleAppLaunched(bundleID: String) {
        let hasRoute: Bool = stateQueue.sync {
            guard self.routedBundleIDs.contains(bundleID) else { return false }
            // Clear any dead/retry state from a prior quit (edge case 1 cleanup).
            self.deadBundleIDs.remove(bundleID)
            self.retryCounts.removeValue(forKey: bundleID)
            self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
            return true
        }
        guard hasRoute else { return }
        // Restart the per-app capture tap for the relaunched process. This is
        // the same call `updateAppRoutes` issues for newly-routed apps; calling
        // it here means a relaunch self-heals without any route-table change.
        perAppCapture.start(bundleID: bundleID)
        // Republish the topology now that the bundle is no longer dead — the
        // mixer will include it in the next `.routedApps` and engine-bind pass.
        republishMixerTopology()
        // Tell the UI the app is live again so it can remove the offline badge.
        stateQueue.async { self.emit(.routedAppRunning(bundleID: bundleID, isRunning: true)) }
    }

    /// One per-app engine binding transition, computed under `stateQueue` and run on
    /// the `bindTail` FIFO. A device moving between streams is a plain stop→re-add
    /// (`.rebind`) — Alec has accepted the brief (~1 s) audible gap, so there is no
    /// gap-hiding machinery here on purpose.
    private enum StreamBindOp {
        case bind(OutputID, UInt32)      // device newly bound to a per-app stream
        case rebind(OutputID, UInt32)    // device moved streams: stop, then re-add
        case unbind(OutputID)            // device left per-app routing: stop
    }

    /// React to a change in the mixer's destination-set topology (T6). Runs on the
    /// mixer's serial queue; hops to `stateQueue` for the whole diff so the binding
    /// state, the `.routedApps` diff, and the `bindTail` submission order are all
    /// serialized against every other `stateQueue` mutation.
    /// Max absolute Float32 sample across a captured buffer's first channel
    /// (diagnostic only; taps deliver Float32). ~0 while an app is audibly
    /// playing is the documented silent-buffer condition.
    private static func diagFloatPeak(_ buffer: CapturedBuffer) -> String {
        guard let data = buffer.channelData.first, data.count >= 4 else { return "n/a" }
        var peak: Float = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let floats = raw.bindMemory(to: Float.self)
            for f in floats { let a = abs(f); if a > peak { peak = a } }
        }
        return String(format: "%.4f", peak)
    }

    /// Max absolute Int16 sample (0…32767) across interleaved S16LE PCM
    /// (diagnostic only) — what the AirPlay engine actually receives per stream.
    private static func diagS16Peak(_ pcm: Data) -> Int {
        guard pcm.count >= 2 else { return 0 }
        var peak: Int16 = 0
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let ints = raw.bindMemory(to: Int16.self)
            for v in ints { let a = v == Int16.min ? Int16.max : abs(v); if a > peak { peak = a } }
        }
        return Int(peak)
    }

    private func handleDestinationSetsChanged(_ sets: [AppRouteMixer.DestinationSet]) {
        stateQueue.sync {
            // --- .routedApps diff (UI signal; independent of device discovery) ---
            var newAppNames: [String: [String]] = [:]
            for set in sets {
                let names = set.bundleIDs
                    .map { self.routeDisplayNames[$0] ?? $0 }
                    .sorted()
                for deviceID in set.deviceIDs { newAppNames[deviceID] = names }
            }
            for (deviceID, names) in newAppNames where self.routedAppNames[deviceID] != names {
                self.emit(.routedApps(deviceID: deviceID, appNames: names))
            }
            for deviceID in self.routedAppNames.keys where newAppNames[deviceID] == nil {
                self.emit(.routedApps(deviceID: deviceID, appNames: []))   // mapping cleared
            }
            self.routedAppNames = newAppNames

            // --- stream binding diff (engine ops; only for discovered devices) ---
            var newBindings: [String: UInt32] = [:]
            for set in sets {
                let stream = UInt32(set.streamID)
                for deviceID in set.deviceIDs where self.outputIDs[deviceID] != nil {
                    newBindings[deviceID] = stream
                }
            }
            var ops: [StreamBindOp] = []
            for (deviceID, stream) in newBindings {
                let outputID = self.outputIDs[deviceID]!
                if let old = self.streamBindings[deviceID] {
                    if old != stream { ops.append(.rebind(outputID, stream)) }
                } else {
                    ops.append(.bind(outputID, stream))
                }
            }
            for (deviceID, _) in self.streamBindings where newBindings[deviceID] == nil {
                if let outputID = self.outputIDs[deviceID] { ops.append(.unbind(outputID)) }
            }
            self.streamBindings = newBindings
            self.enqueueBindOps(ops)
        }
    }

    /// Chain `ops` onto the `bindTail` FIFO in the given order (on `stateQueue`).
    /// Each op awaits its predecessor, so per-app engine ops never overlap — a
    /// device's stop→re-add on a stream change always completes before any later
    /// change's op for the same device begins.
    private func enqueueBindOps(_ ops: [StreamBindOp]) {   // on stateQueue
        guard !ops.isEmpty else { return }
        for op in ops {
            let prev = self.bindTail
            self.bindTail = Task { [weak self] in
                await prev.value
                await self?.performBindOp(op)
            }
        }
    }

    /// Execute one per-app binding op against the engine. Best-effort (D4): a failed
    /// engine op is swallowed — the binding is idempotently re-established on the next
    /// topology change. The engine's `addOutput(_:streamId:)` binds the device's
    /// session to the given master stream (T2).
    private func performBindOp(_ op: StreamBindOp) async {
        switch op {
        case .bind(let outputID, let stream):
            AudioDiag.log("engine BIND output=\(outputID) stream=\(stream)")
            try? await engine.addOutput(outputID, streamId: stream)
        case .rebind(let outputID, let stream):
            AudioDiag.log("engine REBIND output=\(outputID) stream=\(stream)")
            try? await engine.removeOutput(outputID)
            try? await engine.addOutput(outputID, streamId: stream)
        case .unbind(let outputID):
            AudioDiag.log("engine UNBIND output=\(outputID) (AirPlay session torn down)")
            try? await engine.removeOutput(outputID)
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
                    // Snapshot the Mac's output volume OFF `stateQueue` (B3) for the
                    // seed below: the blocking HAL read must not run inside the
                    // critical section. Read here (converge loop's own thread), pass
                    // the value into `connectVolumeSeed`.
                    let systemLevelSnapshot = systemVolume.currentVolume()
                    stateQueue.sync {
                        // An out-of-band `.failed` for this id can arrive on the state
                        // stream between addOutput returning and this post-success
                        // write. `applyEngineState` will have set `failedGate` (device
                        // desired-on) and marked the device unavailable/deselected. Do
                        // NOT clobber that failure by force-selecting a dead session:
                        // if the device was parked in the interim, leave it parked and
                        // don't re-add — the failure the engine just reported wins.
                        guard !self.failedGate.contains(id) else { return }
                        // Seed a real starting volume onto the fresh session so it is
                        // AUDIBLE immediately: the engine's volume field is 0 until an
                        // explicit setVolume, and 0 maps to ≈ −30 dB (silent) — the
                        // −30 dB trap, see `connectVolumeSeed`. Suppressed for an
                        // `applyStartBuffer` re-add (which restores the in-session
                        // level itself), so a plain buffer change never resets volume.
                        //
                        // The seed fires ONLY on the `added` false→true edge — the
                        // moment THIS write actually turns the streaming session on.
                        // That single fact both de-dupes the double-seed race and
                        // guarantees a reseed on every genuine reconnect: the other
                        // add-success site (`applyEngineState`) may observe this same
                        // connect first (the dispatcher mirrors the completion onto
                        // the state stream), but whichever site runs first flips
                        // `added` under `stateQueue` and the second sees `wasAdded ==
                        // true` and skips — so exactly one push per connect. See
                        // `connectVolumeSeed`.
                        let wasAdded = self.added.contains(id)
                        self.added.insert(id)
                        if !wasAdded { self.noteWakeReconnect() }   // B6b: first post-wake reconnect disarms the watchdog
                        let seededVolume = wasAdded ? nil : self.connectVolumeSeed(id, outputID: outputID, systemLevel: systemLevelSnapshot)
                        self.applyLocal(id) {
                            $0.isSelected = true; $0.isAvailable = true
                            if let seededVolume { $0.volume = seededVolume }
                        }
                        // Engine confirmed the add — connecting → connected. (An
                        // interim out-of-band `.failed` already returned above and
                        // left connectionState `.failed` via `applyEngineState`.)
                        self.setConnectionState(.connected, for: id)
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
                        self.enterFailure(id)
                    }
                    return
                }
            } else {
                do {
                    try await engine.removeOutput(outputID)
                    stateQueue.sync {
                        self.added.remove(id)
                        self.applyLocal(id) { $0.isSelected = false }
                        // Confirmed torn down — off is a no-op if `setOutputSet`
                        // already set it eagerly, but covers the case where an
                        // interim event (e.g. a park) had moved it to `.failed`
                        // while this removal was in flight.
                        self.setConnectionState(.off, for: id)
                    }
                } catch {
                    // Removal failed — best-effort: surface unavailable but do NOT
                    // park (a stuck-on session should still be retryable). Drop it
                    // from `added` so the loop can re-issue the stop on the next pass.
                    // Connection state is left alone here (mirrors OwnTone's
                    // `markUnreachable`, which doesn't touch connectionStates on a
                    // non-terminal issue) — the device is still desired off, so the
                    // dot should already read `.off` from `setOutputSet`'s eager set.
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

    // MARK: Current (local) output device (BUG B)
    //
    // The Mac's own default output is surfaced as a Device with
    // `isLocalDevice == true`, `kind == .localMac`, `isAvailable == true`, and
    // `supportsAirPlay2 == false` (mirroring MockBackend's local fixture,
    // MockBackend.swift:457). It is the "Current Device" the popover renders and
    // the target GroupController defaults Selected Devices to on launch
    // (passthrough). Because `supportsAirPlay2 == false` it can never be desired-on
    // in `setOutputSet` (which skips non-AP2 ids) and it is never fed to
    // `engine.updateDiscovery` (only discovery events feed the engine), so it is
    // structurally impossible for the local device to reach the engine.

    /// Stable sentinel id for the Mac's own output. A FIXED id (not the Core Audio
    /// UID) so it: (a) is stable across default-output changes, (b) can never
    /// collide with an AirPlay colon-hex `deviceid`, and (c) matches how
    /// MockBackend keys its local device — the two backends present the local row
    /// identically, so selection/persistence keyed on `Device.id` behaves the same
    /// whichever backend is live. The real discriminator everywhere is
    /// `Device.isLocalDevice`, not this id.
    static let localDeviceID = "local-mac"

    /// Add the current local output device to the model and emit `deviceAdded`.
    /// On `stateQueue`. Idempotent-ish: only appended once per `start()` (cleared
    /// on `stop()` with everything else).
    private func surfaceLocalDevice(name: String, volume: Int?, muted: Bool?) {
        let id = Self.localDeviceID
        guard known[id] == nil else { return }
        let device = Device(
            id: id,
            name: name,
            kind: .localMac,
            isAvailable: true,
            supportsAirPlay2: false,       // mirrors MockBackend's local fixture
            // Seed from the HARDWARE, not a fixture: the row must open showing where
            // the Mac's volume actually is, or the first slider touch would jump it.
            // The reads happen in `start()` BEFORE the `stateQueue` hop (B3) — off the
            // queue so a blocking HAL read can't stall the main-thread `devices`
            // getter — and are passed in here. The fallbacks cover outputs with no
            // readable volume/mute control (many aggregate + digital/HDMI devices),
            // where `nil` means "unreadable".
            volume: volume ?? 65,
            isMuted: muted ?? false,
            isLocalDevice: true
        )
        known[id] = device
        order.append(id)
        emit(.deviceAdded(device))
    }

    /// Best-effort name of the system default output device via Core Audio
    /// (`kAudioHardwarePropertyDefaultOutputDevice` → `kAudioObjectPropertyName`).
    /// Falls back to "This Mac" if any query fails, so the row always has a label.
    ///
    /// Read at `start()` (``surfaceLocalDevice``) and re-read on every
    /// `systemVolume.onExternalChange`, which ``SystemOutputVolume`` fires on a
    /// default-output-device switch (it owns the `kAudioHardwarePropertyDefaultOutputDevice`
    /// listener) — so switching speakers → AirPods relabels the row. The callback
    /// carries no name of its own, hence the re-read there.
    static func currentOutputDeviceName(fallback: String = "This Mac") -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let devErr = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil, &size, &deviceID)
        guard devErr == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return fallback }

        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString? = nil
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        let nameErr = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, ptr)
        }
        guard nameErr == noErr, let cf = name else { return fallback }
        let str = cf as String
        return str.isEmpty ? fallback : str
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
    /// 3. Re-add the same set (re-feeding descriptors + re-pushing volume/mute
    ///    for free) by driving HEAD's per-device converge back to on.
    ///
    /// The teardown/re-add is driven through the SAME serialized `convergeDevice`
    /// loop `setOutputSet` uses (design-doc work item 2: "re-add via existing
    /// converge"), NOT a private direct add/remove loop. What this method adds
    /// on top of plain converge is a HARD BARRIER between the phases: converge
    /// coalesces and its per-device Tasks run concurrently across devices, so a
    /// naive "flip all off then all on" could interleave a re-add ahead of
    /// another device's removal and let the old master session survive. We
    /// therefore await ALL removals (phase 1) before the engine set (phase 2)
    /// before ALL re-adds (phase 3). Because we own the `converging` slot for
    /// each id for the duration, `setOutputSet` calls arriving during the gap
    /// just update `desiredOn`; whichever intent is newest is chased once we
    /// release. Per-device failures keep D4 best-effort semantics (converge
    /// marks the device unavailable + parks it; the rest proceed).
    ///
    /// With nothing streaming, phases 1 and 3 are empty and this reduces to the
    /// engine set — silent/instant.
    public func applyStartBuffer(ms: Int) async {
        // Snapshot the streaming set under the lock and record the new value.
        // (Re-feed + volume/mute restoration are handled by convergeDevice via
        // `lastDescriptors` / `restoreEffectiveVolume`, so we only need the ids.)
        let streaming: [(id: String, outputID: OutputID)] = stateQueue.sync {
            self._startBufferMs = ms
            let items: [(id: String, outputID: OutputID)] = self.added.compactMap { id in
                guard let outputID = self.outputIDs[id] else { return nil }
                return (id, outputID)
            }
            // Mark these ids as an internal buffer re-add for the WHOLE apply, so the
            // shared converge add path (and any engine state-stream event that races
            // it) does NOT reseed their volume from the current system level. This is
            // a buffer-size change, not a user reconnect: each device's in-session
            // level must survive, and the explicit re-push at the end of this method
            // restores it. Without this guard, `connectVolumeSeed` would slam every
            // running device back to the system volume on a plain buffer change.
            // Cleared once the apply has fully settled (below).
            for item in items { self.bufferReAdding.insert(item.id) }
            return items
        }

        // 1. Drive every streaming device OFF via converge and AWAIT completion
        //    (barrier: all removals resolve before the buffer set). Each
        //    convergeDevice runs to quiescence for its id, so on return the
        //    removeOutput has completed.
        await withTaskGroup(of: Void.self) { group in
            for item in streaming {
                group.addTask { [weak self] in
                    await self?.convergeToTarget(id: item.id, outputID: item.outputID, on: false)
                }
            }
        }

        // 2. New buffer value; the next master session picks it up.
        await engine.setStartBufferMs(ms)

        // 3. Re-add the same set via converge (best-effort, D4). Converge
        //    re-feeds the descriptor through its normal add path.
        await withTaskGroup(of: Void.self) { group in
            for item in streaming {
                group.addTask { [weak self] in
                    await self?.convergeToTarget(id: item.id, outputID: item.outputID, on: true)
                }
            }
        }

        // Re-push each device's effective volume (mute = stashed-0) onto the
        // fresh session — the add path doesn't set volume, and the new master
        // session starts at the engine's default. Only for devices that actually
        // came back (a D4 re-add failure left them out of `added`). Awaited (not
        // the fire-and-forget `pushVolume`) so the apply is fully settled on
        // return — the CTA's "Reconnecting…" clears only once everything's live.
        let toPush: [(OutputID, Double)] = stateQueue.sync {
            streaming.compactMap { item in
                guard self.added.contains(item.id) else { return nil }
                let intended = self.stashedVolume[item.id] ?? self.known[item.id]?.volume ?? 0
                let effective = self.muted.contains(item.id) ? 0 : intended
                return (item.outputID, Self.engineVolume(effective))
            }
        }
        for (outputID, value) in toPush {
            try? await engine.setVolume(outputID, value)
        }

        // The apply has fully settled — teardown, buffer set, re-add, and the
        // in-session volume re-push above have all run. Lift the seed suppression so
        // any subsequent REAL (re)connect reseeds from the system volume as usual.
        stateQueue.sync {
            for item in streaming { self.bufferReAdding.remove(item.id) }
        }
    }

    /// Set `desiredOn[id] = target`, claim the (awaited) `converging` slot, then
    /// drive `convergeDevice` to quiescence and AWAIT it — the awaitable
    /// counterpart to `setOutputSet`'s fire-and-forget kick, used by
    /// `applyStartBuffer` to impose its remove-all → set → re-add barrier.
    ///
    /// If another converge already owns the slot for this id, we just publish the
    /// new target (`desiredOn`) and return: the running loop re-reads `desiredOn`
    /// when its current op settles and chases our value, so the target is still
    /// honored — we simply don't double-drive the same id. A parked (`failedGate`)
    /// device stays parked on a teardown (nothing to remove) and is un-parked on a
    /// re-add so it can be retried, mirroring `setOutputSet`.
    private func convergeToTarget(id: String, outputID: OutputID, on target: Bool) async {
        let shouldDrive: Bool = stateQueue.sync {
            if target { self.failedGate.remove(id) } // re-add clears a park (retryable)
            self.desiredOn[id] = target
            // Reflect intent immediately, same as setOutputSet's eager set.
            self.setConnectionState(target ? .connecting : .off, for: id)
            guard !self.converging.contains(id) else { return false }
            self.converging.insert(id)
            return true
        }
        guard shouldDrive else { return }
        await convergeDevice(id: id, outputID: outputID)
    }

    // MARK: Sleep/wake (B6b)

    public func setWakeAudioRestoreDelay(_ delay: TimeInterval?) {
        stateQueue.async { self.wakeAudioRestoreDelay = delay }
    }

    /// Test-only (`@testable`): the raw selection INTENT the app last asked for
    /// (`expectedSelected`) — distinct from `Device.isSelected` (streaming-now).
    /// Lets B6b tests assert intent survives a sleep/wake/watchdog cycle even when a
    /// failed reconnect legitimately deselects the model row.
    var test_expectedSelected: Set<String> { stateQueue.sync { expectedSelected } }

    /// System will sleep: proactively remove every streaming engine output so the
    /// receivers get a clean RTSP TEARDOWN before sleep severs the sockets, while
    /// PRESERVING the selection intent (`expectedSelected` / `desiredOn`) so
    /// ``handleSystemDidWake()`` can re-converge.
    ///
    /// Deliberately NOT routed through `convergeToTarget(on: false)` / a plain
    /// deselect: that sets `desiredOn[id] = false` (clearing per-device intent) and
    /// emits a `deviceUpdated` deselect that GroupController's reverse auto-swap
    /// keys off. We instead clear `added` under the lock (bookkeeping only), issue
    /// the `removeOutput`s off `stateQueue`, and emit NOTHING — so intent survives
    /// and no reverse auto-swap can fire. `applyEngineState` swallows the `.stopped`
    /// echoes these removals produce while `suspended` (below), for the same reason.
    public func handleSystemWillSleep() {
        let toRemove: [(id: String, outputID: OutputID)] = stateQueue.sync {
            guard self.started, !self.suspended else { return [] }
            self.suspended = true
            // Abandon any in-flight wake bookkeeping from a prior cycle.
            self.wakeWatchdog?.cancel()
            self.wakeWatchdog = nil
            self.awaitingWakeReconnect = false
            self.wakeCaptureOverride = false
            // Stop the whole-system tap (ordered on `captureControlQueue`, like every
            // other gate decision) so the Mac isn't left muted by a tap streaming into
            // dead sockets. `expectedSelected` is untouched.
            self.captureRunning = false
            if let coordinator = self.captureCoordinator {
                self.captureControlQueue.async { coordinator.stop() }
            }
            // Snapshot the streaming set, then clear `added` SYNCHRONOUSLY: the engine
            // sessions are about to die on sleep, so the bookkeeping must reflect
            // "torn down" immediately — otherwise a fast wake could see them still
            // `added` and skip the re-add, leaving silence. `desiredOn` is preserved.
            let items: [(String, OutputID)] = self.added.compactMap { id in
                guard let outputID = self.outputIDs[id] else { return nil }
                return (id, outputID)
            }
            self.added.removeAll()
            return items
        }
        for (_, outputID) in toRemove {
            Task { [weak self] in try? await self?.engine.removeOutput(outputID) }
        }
    }

    /// System woke: re-converge every still-desired device (intent survived sleep)
    /// and arm the fallback watchdog. A wake reconnect is a genuine reconnect, so
    /// `convergeDevice`'s add path reseeds the volume as documented (the `added`
    /// false→true edge).
    public func handleSystemDidWake() {
        let toKick: [(id: String, outputID: OutputID)] = stateQueue.sync {
            guard self.started, self.suspended else { return [] }
            self.suspended = false
            self.wakeCaptureOverride = false

            var kicks: [(String, OutputID)] = []
            let desiredIDs = self.order.filter { self.desiredOn[$0] == true }
            for id in desiredIDs {
                guard let outputID = self.outputIDs[id] else { continue }
                // A sleep is not a device failure — clear any park so the re-add isn't
                // gated, mirroring a user re-toggle.
                self.failedGate.remove(id)
                self.setConnectionState(.connecting, for: id)
                if !self.converging.contains(id) {
                    self.converging.insert(id)
                    kicks.append((id, outputID))
                }
            }
            // Re-decide the capture gate now that `suspended` is lifted (re-mute if a
            // streaming selection is still in force).
            self.reconcileCaptureGate()
            // Arm the fallback watchdog only if we're actually waiting on a reconnect.
            self.awaitingWakeReconnect = !desiredIDs.isEmpty
            if self.awaitingWakeReconnect { self.armWakeWatchdog() }
            return kicks
        }
        for (id, outputID) in toKick {
            Task { [weak self] in await self?.convergeDevice(id: id, outputID: outputID) }
        }
        // Discovery nudge: a receiver that changed address / dropped during sleep
        // needs re-resolving. `NativeDiscovery` has no explicit refresh seam today
        // (sibling task B9 makes discovery self-healing) — noted, not forced here.
    }

    /// Called on the `added` false→true edge (both add-success sites) — inert unless
    /// we're waiting on a post-wake reconnect. The first reconnect disarms the
    /// watchdog; if the watchdog had already un-gated capture, this re-engages the
    /// gate (re-muting the Mac for the recovered stream). Intent is never touched.
    /// On `stateQueue`.
    private func noteWakeReconnect() {   // on stateQueue
        guard self.awaitingWakeReconnect else { return }
        self.awaitingWakeReconnect = false
        self.wakeWatchdog?.cancel()
        self.wakeWatchdog = nil
        if self.wakeCaptureOverride {
            self.wakeCaptureOverride = false
            self.reconcileCaptureGate()
        }
    }

    /// Arm the fallback watchdog on `stateQueue`. A `nil`/non-positive delay ("Never")
    /// arms nothing. On `stateQueue`.
    private func armWakeWatchdog() {   // on stateQueue
        self.wakeWatchdog?.cancel()
        self.wakeWatchdog = nil
        guard let delay = self.wakeAudioRestoreDelay, delay > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.fireWakeWatchdog() }
        self.wakeWatchdog = work
        // Scheduled ON `stateQueue`, so the body runs serialized with every other
        // state mutation; a cancel before it fires simply drops it.
        self.stateQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The watchdog fired: no desired-on device reconnected in time. Un-gate capture
    /// so the Mac un-mutes, leaving the selection intent intact — a later reconnect
    /// clears the override (`noteWakeReconnect`) and re-mutes. On `stateQueue`.
    private func fireWakeWatchdog() {   // on stateQueue (scheduled there)
        guard self.awaitingWakeReconnect, self.wakeWatchdog != nil else { return }
        self.wakeWatchdog = nil
        self.awaitingWakeReconnect = false
        self.wakeCaptureOverride = true
        self.reconcileCaptureGate()
    }

    // MARK: Discovery → app model (all on stateQueue)

    private func handleDiscovery(_ event: DiscoveryEvent) {
        switch event {
        case .appeared(let discovered):
            feedEngineIfAP2(discovered, appearing: true)
            stateQueue.async { self.addOrUpdate(discovered) }
        case .updated(let discovered):
            if discovered.isAirPlay2Supported && discovered.isAvailable {
                feedEngineIfAP2(discovered, appearing: true)
            } else {
                // Two cases reach here, both requiring the same engine teardown:
                //
                //  1. A sticky-AP2 device going OFFLINE (`isAirPlay2Supported`
                //     stays true, `isAvailable == false`): it lost its
                //     `_airplay._tcp` advert while its `_raop._tcp` record lingers
                //     — a real AP2 receiver powering off, NOT an AP1 downgrade.
                //     `supportsAirPlay2` STAYS true so the UI shows an unavailable
                //     (retry-on-click) row, never the AP1 "coming soon" popover.
                //
                //  2. A genuine AP1-only device (`isAirPlay2Supported == false`):
                //     never streamable (D6); if it was somehow added, drop it.
                //     (In practice a never-AP2 device is never fed/added, so this
                //     is a no-op belt-and-suspenders.)
                //
                // Either way it is NOT `.disappeared`, so the removal path below
                // never runs otherwise — tear down any live engine session and
                // deregister its descriptor so we don't leak a live RTSP/PTP
                // session. Safe/idempotent if it was never AP2 or never added.
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
        // "Streamable right now" = AP2-capable AND currently reachable. A
        // sticky-AP2 device that went offline (`supportsAirPlay2` true but
        // `isAvailable` false) is NOT streamable right now — treat it like the
        // AP2-advert-gone case (drop the descriptor/fed-memo, don't re-kick),
        // but it KEEPS `supportsAirPlay2 == true` in the model (set in
        // `mapDiscovered`/`merge`) so the UI never shows the AP1 "coming soon"
        // row — it shows an unavailable/retry-on-click row instead.
        let streamableNow = discovered.isAirPlay2Supported && discovered.isAvailable
        if streamableNow {
            self.lastDescriptors[id] = discovered.descriptor
            // Availability recovery (root cause 4): a fresh AP2 (re-)resolution is
            // evidence the device is reachable again, so clear any terminal-failure
            // park — the device becomes re-enableable on the next user toggle (or,
            // if it's still desired-on, the loop below re-kicks it).
            // STABILITY(C7): discovery re-resolve clears the failure gate with no backoff — see dev/notes/stability-audit-2026-07-18.md
            self.failedGate.remove(id)
        } else {
            self.lastDescriptors[id] = nil
            // The AP2 advert is gone (downgrade) or the device went offline: the
            // engine descriptor will be removed, so a future re-add must re-feed.
            // Drop the fed-descriptor memo.
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
        if streamableNow,
           self.desiredOn[id] == true,
           !self.added.contains(id),
           !self.converging.contains(id),
           !self.failedGate.contains(id),
           let outputID = self.outputIDs[id] {
            self.converging.insert(id)
            // STABILITY(C7): discovery re-resolve clears the failure gate with no backoff — see dev/notes/stability-audit-2026-07-18.md
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
        // Brief §1: a sticky `.failed` clears to `.off` only when the device
        // disappears entirely — this is that site (mirrors OwnToneBackend's
        // `.failed → .off` on the poll's removal branch).
        if device.connectionState != .off { device.connectionState = .off; changed = true }
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
        // Snapshot the Mac's output volume OFF `stateQueue` (B3): the
        // `.connected`/`.streaming` branch below reseeds an out-of-band reconnect from
        // it, and the blocking HAL read must not run inside the critical section the
        // main-thread `devices` getter waits on. This runs on the state-stream
        // consumer's own task thread, ahead of the queue hop. Read unconditionally —
        // cheap, and the good-transition branch that consumes it is the common path.
        let systemLevelSnapshot = systemVolume.currentVolume()
        // A good transition (.streaming/.connected) for a device the user has since
        // turned OFF must NOT re-wedge it ON — instead re-kick converge to tear the
        // stale session down. We compute any needed re-kick under the lock and fire
        // it after releasing it (convergeDevice takes the lock itself).
        let rekick: (id: String, outputID: OutputID)? = stateQueue.sync {
            // While suspended for sleep (B6b), swallow every transition: the
            // `handleSystemWillSleep()` removals produce `.stopped` echoes that would
            // otherwise emit a `deviceUpdated` deselect and let GroupController's
            // reverse auto-swap clear the very intent sleep is preserving. Wake
            // re-converges from `desiredOn`, so nothing is lost.
            guard !self.suspended else { return nil }
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
                let wasAdded = self.added.contains(id)
                device.isAvailable = true
                device.isSelected = true
                device.connectionState = .connected
                self.added.insert(id)
                if !wasAdded { self.noteWakeReconnect() }   // B6b: first post-wake reconnect disarms the watchdog
                // Recovery (root cause 4): a good transition clears any failure
                // park so the device is re-enableable / stays converged.
                self.failedGate.remove(id)
                // A (re)connect the engine reported out-of-band — e.g. an
                // auto-recovery it drove itself — never went through convergeDevice's
                // add path, so it too lands at engine volume 0 = ≈ −30 dB (silent).
                // Seed its starting volume here on a genuine new-add (`!wasAdded`).
                // Suppressed during an `applyStartBuffer` re-add so a buffer change
                // whose good-state event races this branch can't reset the level —
                // see `connectVolumeSeed`.
                if !wasAdded, let seededVolume = self.connectVolumeSeed(id, outputID: outputID, systemLevel: systemLevelSnapshot) {
                    device.volume = seededVolume
                }
            case .failed, .passwordRequired:
                // A live session died / needs a PIN we don't have: surface it as
                // unavailable + deselected and drop it from the streaming set. PARK
                // it (root cause 5) so converge doesn't immediately re-issue a
                // session against a receiver that just failed — the park is cleared
                // by the next discovery/good-state transition or a user re-toggle.
                device.isAvailable = false
                device.isSelected = false
                self.added.remove(id)
                if self.desiredOn[id] == true {
                    self.failedGate.insert(id)
                    device.connectionState = .failed(ConnectionFailure(cause: .unknown))
                }
            case .stopped:
                device.isSelected = false
                self.added.remove(id)
                // A stopped session for a device the user hasn't re-desired-off is
                // NOT a failure — it's a clean stop. Only clear a `.connecting` /
                // `.connected` / `.reconnecting` dot to `.off`; leave a sticky
                // `.failed` alone (mirrors the brief's sticky-failed rule — a
                // resting failure isn't overwritten by a plain stop) and leave `.off`
                // alone (no-op).
                if case .failed = device.connectionState {} else {
                    device.connectionState = .off
                }
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
        // Availability rules:
        //  - AP1-only (never AP2): surfaced but never controllable — available=false
        //    (dimmed/disabled "coming soon"), NEVER addOutput-ed (D6).
        //  - AP2 online: available.
        //  - AP2 OFFLINE (sticky-AP2, `discovered.isAvailable == false`): keeps
        //    supportsAP2=true but available=false — surfaced as an unavailable
        //    (retry-on-click) row, NOT the AP1 "coming soon" row.
        let isAvailable = supportsAP2 && discovered.isAvailable
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
        if discovered.supportsAirPlay2 && discovered.isAvailable {
            // An AP2 device that re-resolved is reachable again (a dropped→
            // returned device comes back available).
            result.isAvailable = true
        } else if discovered.supportsAirPlay2 {
            // Sticky-AP2 device that went OFFLINE (lost its `_airplay._tcp`
            // advert; `_raop._tcp` lingers): supportsAirPlay2 STAYS true, but it
            // is unavailable and deselected. `teardownEngineOutput` already
            // stopped any live session before this merge runs. Surface a resting
            // `.failed` dot so it reads as "went away, click to retry" (the
            // existing failed-click path re-attempts on the next user toggle),
            // NOT `.off` (which would look like a clean, deliberate stop).
            result.isAvailable = false
            result.isSelected = false
            result.connectionState = .failed(ConnectionFailure(cause: .unknown))
        } else {
            // Genuine AP1-only device (never AP2). Never routed (D6) and must
            // never show a connecting/failed dot — force the dot to `.off`.
            result.isAvailable = false
            result.isSelected = false
            result.connectionState = .off
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

    /// Ids with a `setVolume` op currently in flight against the engine. Guards
    /// against the general case behind the live Sonos Move regression
    /// (2026-07-17): the vendored C dispatcher's "one pending callback per
    /// device" `outputs_callback_add` contract (shims/outputs.c) means a SECOND
    /// concurrent `setVolume` for the same output clobbers the first's
    /// still-armed waiter — that first waiter's continuation then never gets a
    /// real completion, surfacing as a leaked `SWIFT TASK CONTINUATION MISUSE`
    /// and, once enough pile up, the session dying outright. `connectVolumeSeed`
    /// firing only on the `added` false→true edge closes the double-seed
    /// specifically (both add-success sites racing on ONE connect); this closes the
    /// general fire-and-forget hazard so no caller — a seed, a slider drag, a
    /// mute/unmute — can ever have two `setVolume` calls for the same output in
    /// flight at once, regardless of what raced what.
    private var volumeInFlight: Set<OutputID> = []
    /// The newest value queued behind an in-flight push for an id. Only the
    /// latest matters for volume (unlike add/remove ops), so a burst of pushes
    /// for one id (e.g. a fast slider drag) collapses to at most one extra call
    /// once the in-flight one completes, instead of replaying every
    /// intermediate value.
    private var volumePending: [OutputID: Double] = [:]

    /// Push a volume to the engine off-queue (the engine op is async), serialized
    /// per output id via ``volumeInFlight``/``volumePending`` so at most one
    /// `engine.setVolume` call for a given output is ever in flight concurrently.
    /// Failures are non-fatal (volume completions don't gate anything) —
    /// swallowed, the next state event / user action reconciles. On `stateQueue`.
    private func pushVolume(_ outputID: OutputID, engineValue: Double) {
        guard !volumeInFlight.contains(outputID) else {
            volumePending[outputID] = engineValue
            return
        }
        volumeInFlight.insert(outputID)
        issueVolumePush(outputID, engineValue)
    }

    /// Issue one `setVolume` call and, on completion, either chase the latest
    /// superseding value queued in ``volumePending`` or clear ``volumeInFlight``.
    /// Not on `stateQueue` itself (the engine call is async) — re-enters it only
    /// to touch the two dictionaries, matching every other engine-callback
    /// pattern in this file.
    private func issueVolumePush(_ outputID: OutputID, _ engineValue: Double) {
        let engine = self.engine
        Task { [weak self] in
            try? await engine.setVolume(outputID, engineValue)
            guard let self else { return }
            self.stateQueue.async {
                if let next = self.volumePending.removeValue(forKey: outputID) {
                    self.issueVolumePush(outputID, next)
                } else {
                    self.volumeInFlight.remove(outputID)
                }
            }
        }
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

    // MARK: Connection state (dev/notes/p1-connection-status-brief.md §1)
    //
    // Mirrors OwnToneBackend's `connectionState(of:)`/`setConnectionState(_:for:)`
    // semantics, not its mechanism: there is no poll loop or confirm re-GET here —
    // the engine's completions and state-stream transitions ARE ground truth, so
    // `.connecting → .connected`/`.failed` rides the SAME hooks that already drive
    // `isSelected`/`isAvailable` (converge success/failure, `applyEngineState`,
    // discovery loss) rather than a separate poll-derived stability window. AP1-only
    // devices are never routed (`setOutputSet` skips them entirely, D6) so they never
    // reach these helpers and stay `.off` for their whole lifetime.

    /// Current lifecycle state for an id; absence means `.off`.
    private func connectionState(of id: String) -> ConnectionState {   // on stateQueue
        known[id]?.connectionState ?? .off
    }

    /// Record a transition and echo it through the normal update machinery.
    /// `applyLocal` no-ops (and this is a no-op) for ids not yet discovered.
    private func setConnectionState(_ state: ConnectionState, for id: String) {   // on stateQueue
        guard connectionState(of: id) != state else { return }
        applyLocal(id) { $0.connectionState = state }
    }

    /// Enter the resting `.failed` state (converge add-throw or an out-of-band
    /// `.failed`/`.passwordRequired` from the engine's state stream). NativeBackend
    /// has no diagnostics seam (T3 is OwnTone-only per the brief; the engine's
    /// completion IS the evidence) — always `.unknown`.
    private func enterFailure(_ id: String) {   // on stateQueue
        setConnectionState(.failed(ConnectionFailure(cause: .unknown)), for: id)
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

    /// Seed a just-(re)connected engine output's starting volume from the Mac's
    /// CURRENT system output level. Pushes the level to the engine and returns the
    /// value to display on the model, or `nil` when the seed is suppressed (leave
    /// the model volume untouched). On `stateQueue`.
    ///
    /// ## Why this exists — the −30 dB trap (do NOT delete without reading this)
    /// The engine's per-output volume field is zero-initialized and is only ever set
    /// by an explicit `setVolume`; the AirPlay volume model maps 0 to about −30 dB,
    /// the quietest non-muted level — effectively silent on the receiver
    /// (`AirPlayEngine.swift:650-657`). So a freshly connected output nobody touched
    /// streams INAUDIBLY until the first slider drag. Every real (re)connect must
    /// push a real starting volume; this is that push, called from BOTH add-success
    /// sites (`convergeDevice` and `applyEngineState`).
    ///
    /// Source of the level: ``SystemVolumeControlling/currentVolume()`` — wherever
    /// the Mac's own volume sits right now. When that is unreadable (`nil`), seed 0%:
    /// deliberate silence over a guessed level (product decision), NOT a 65% guess.
    ///
    /// Mute carve-out: a device the user explicitly muted stays effective-0. Seed the
    /// INTENDED level into `stashedVolume` (so a later unmute restores the system
    /// level) and keep the wire at 0 — never un-mute here.
    ///
    /// Suppression: returns `nil` and pushes nothing while `id` is in
    /// ``bufferReAdding``, so ``applyStartBuffer(ms:)``'s internal teardown/re-add —
    /// a buffer-size change, NOT a user reconnect — preserves the device's existing
    /// in-session level instead of resetting it to the system volume.
    ///
    /// ## De-dup rides on the `added` false→true edge, NOT a separate set
    /// This method is reachable from BOTH add-success sites (`convergeDevice` and
    /// `applyEngineState`), and the vendored dispatcher mirrors a normal `addOutput`
    /// completion onto the engine's device-state stream too
    /// (`outputs_cb_deferred_drain` in shims/outputs.c fires the completion hook THEN
    /// the state hook for the same armed report) — so a plain user-initiated connect
    /// reaches both sites, not just the out-of-band auto-recovery case site 2 exists
    /// for. Each caller invokes this ONLY on the `added` false→true transition it
    /// observes: whichever of the two flips `added` first (both under the serial
    /// `stateQueue`) seeds; the other sees `added` already true and never calls in.
    /// That caps the seed at one push per connect episode WITHOUT a separate
    /// membership set to maintain. An earlier design used a `volumeSeeded: Set` that
    /// had to be cleared by hand at every teardown path; a single missed/reordered
    /// clear silently skipped the reseed on a later reconnect (live Move 2 bug,
    /// 2026-07-17: the SECOND reconnect in a session kept the first reconnect's
    /// stale level). Keying on `added` — the connection ground truth that is already
    /// removed at every real teardown — makes that whole class of drift impossible:
    /// there is no second set that can be stuck-set while `added` is clear, so every
    /// genuine reconnect (which necessarily re-flips `added` false→true) reseeds.
    ///
    /// The system-volume HAL read is NOT done here: `systemLevel` is snapshotted by
    /// each caller BEFORE it takes `stateQueue` (B3), so the blocking Core Audio read
    /// never runs inside the critical section that the main-thread `devices` getter
    /// waits on. The value being a few µs staler than the `added` edge is immaterial —
    /// only WHERE the read happens moved, not WHEN the seed fires. `nil` still means
    /// "unreadable" and maps to 0% (deliberate silence, not a guessed level).
    private func connectVolumeSeed(_ id: String, outputID: OutputID, systemLevel: Int?) -> Int? {   // on stateQueue
        guard !bufferReAdding.contains(id) else { return nil }
        let seed = systemLevel ?? 0
        if muted.contains(id) {
            // Keep the mute; only update the level an unmute will restore.
            stashedVolume[id] = seed
            pushVolume(outputID, engineValue: Self.engineVolume(0))
        } else {
            pushVolume(outputID, engineValue: Self.engineVolume(seed))
        }
        return seed
    }

    // MARK: Capture gate

    /// Start/stop capture so the tap runs IF AND ONLY IF at least one real AP2
    /// output is selected. On `stateQueue`, called only from `setOutputSet`.
    ///
    /// ## Why intent, not availability (deliberate)
    /// `want` reads `expectedSelected` — what the user ASKED for — and only checks
    /// `supportsAirPlay2` (never `isAvailable`, `added`, or `converging`). A
    /// selected receiver that transiently drops therefore KEEPS capture running
    /// (the Mac stays muted) until it returns or the user deselects it. That's the
    /// point: a brief dropout must not blast the Mac's speakers mid-song. The
    /// `supportsAirPlay2` check is what excludes the two id classes that can never
    /// stream — the local Mac device (`supportsAirPlay2 == false`, and already
    /// filtered by `GroupController.applyRouting`) and AP1-only receivers (D6) —
    /// so `want` means exactly "an id `setOutputSet` could actually `addOutput`".
    /// An id not yet discovered reads `nil` ⇒ excluded, matching the converge loop
    /// below, which only ever iterates `order` (known devices).
    ///
    /// ## Why the flag flips here but the call runs elsewhere
    /// `captureRunning` is flipped under `stateQueue` (so concurrent
    /// `setOutputSet`s can't both decide "start"), while the possibly-blocking
    /// coordinator call is enqueued on `captureControlQueue` — see that queue's
    /// doc. Enqueuing from inside the caller's critical section is what keeps the
    /// two in step: decisions are serialized by `stateQueue` and replayed in the
    /// same order by a serial queue, so N rapid toggles execute
    /// start/stop/start/… in exactly the decided order and settle on the last one.
    private func reconcileCaptureGate() {   // on stateQueue
        guard let coordinator = captureCoordinator else { return }
        // Two B6b overrides force the tap OFF regardless of selection: while
        // `suspended` (system sleep — nothing to send, and a later didWake re-decides)
        // and while the wake watchdog has un-gated capture (`wakeCaptureOverride` —
        // no receiver came back, so un-mute the Mac). Neither touches the selection
        // intent, so the gate re-engages the moment both clear.
        let want = !suspended && !wakeCaptureOverride
            && expectedSelected.contains { known[$0]?.supportsAirPlay2 == true }
        guard want != captureRunning else { return }   // already at target
        captureRunning = want
        captureControlQueue.async {
            if want { coordinator.start() } else { coordinator.stop() }
        }
    }

    // MARK: Level pass-through

    /// Fan a capture-side RMS sample out as `.level` for every currently-selected,
    /// unmuted device (the meter is a property of the captured audio, identical for
    /// every fanned-out device — playback-meter-research.md). On `stateQueue`.
    // STABILITY(D3): per-buffer level fan-out amplifies every stall — see dev/notes/stability-audit-2026-07-18.md
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

/// One-shot resume guard for a `CheckedContinuation` raced between two Tasks
/// (`stopAndWait`'s teardown-vs-timeout race). Whichever Task calls `resume()`
/// first wins; every later call is a no-op, so the continuation is resumed exactly
/// once no matter which branch finishes first (double-resume would trap).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func resume() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
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
    /// T2 (per-app multi-stream routing engine surface): binds `id`'s session
    /// to `streamId` before starting it — see
    /// ``AirPlayEngine/AirPlayEngine/addOutput(_:streamId:)``. Default forwards
    /// to the single-stream `addOutput(_:)` (i.e. `streamId` 0), so existing
    /// conformers (the `NativeBackendTests` spy) compile unchanged; NOT yet
    /// called anywhere in `NativeBackend` — T6 wires the real per-app routing
    /// decision that picks a non-zero `streamId` and calls this instead.
    func addOutput(_ id: OutputID, streamId: UInt32) async throws
    func removeOutput(_ id: OutputID) async throws
    func setVolume(_ id: OutputID, _ volume: Double) async throws
    func setStartBufferMs(_ ms: Int) async
    /// Feed one finished mixed per-app buffer tagged with its `streamId` (T2/T6).
    /// Nonisolated + fire-and-forget on the real engine, so it is safe to call from
    /// the mixer's queue with no hop. `streamId` is ≥ 1 (0 is the legacy
    /// whole-system path fed by ``CaptureControlling``, not this seam). Default is a
    /// no-op so a conformer that doesn't route per-app streams compiles unchanged.
    func write(pcm: Data, streamId: UInt32, pts: timespec)
    func makeStateStream() -> AsyncStream<(OutputID, OutputState)>
}

extension EngineControlling {
    /// Default: legacy single-stream behavior (`streamId` 0), so a conformer
    /// that predates T2 doesn't need updating. ``EngineAdapter`` overrides this
    /// with the real forwarding call.
    func addOutput(_ id: OutputID, streamId: UInt32) async throws {
        try await addOutput(id)
    }

    /// Default: drop the buffer. ``EngineAdapter`` overrides this to forward to the
    /// real engine; a conformer that never receives per-app mixed audio ignores it.
    func write(pcm: Data, streamId: UInt32, pts: timespec) {}
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
    func addOutput(_ id: OutputID, streamId: UInt32) async throws {
        try await engine.addOutput(id, streamId: streamId)
    }
    func removeOutput(_ id: OutputID) async throws { try await engine.removeOutput(id) }
    func setVolume(_ id: OutputID, _ volume: Double) async throws { try await engine.setVolume(id, volume) }
    func setStartBufferMs(_ ms: Int) async { await engine.setStartBufferMs(ms) }
    func write(pcm: Data, streamId: UInt32, pts: timespec) {
        engine.write(pcm: pcm, streamId: streamId, pts: pts)
    }
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

/// The slice of ``NativeCaptureCoordinator`` ``NativeBackend`` drives. Extracted
/// as a protocol so the capture GATE (`NativeBackend.reconcileCaptureGate`) is
/// assertable with no Core Audio process tap, no TCC prompt, and no engine — the
/// behavior being guarded is "is the tap running right now?", which is exactly
/// what a real tap makes untestable offline. ``NativeCaptureCoordinator`` conforms
/// as-is, so ``makeBackend(_:)`` still wires the concrete coordinator unchanged.
///
/// Public — unlike the internal ``EngineControlling``/``DiscoverySource`` seams —
/// only because ``NativeBackend/captureCoordinator`` is public, and Swift requires
/// a public property's type to be public too.
public protocol CaptureControlling: AnyObject, Sendable {
    /// Fired once per captured buffer with its level in 0.0…1.0, from the tap's
    /// delivery thread. See ``NativeCaptureCoordinator/onLevel``.
    var onLevel: (@Sendable (_ rms: Float) -> Void)? { get set }
    /// Begin capturing system audio. Idempotent.
    ///
    /// The real tap is `.mutedWhenTapped`: while it runs, the Mac's own speakers
    /// are SILENT. Only call it when the captured audio actually has somewhere to
    /// go (`NativeBackend` gates this on a real AP2 output being selected).
    func start()
    /// Stop capturing. Idempotent. MAY BLOCK on Core Audio teardown, so callers
    /// must keep it off `NativeBackend.stateQueue`.
    func stop()

    /// Keep the whole-system tap's exclusion set in sync with the routing table
    /// (T4/T6): individually-routed apps (`.device(id:)` routes) and user-excluded
    /// apps must not double up into the system-wide mix. Default no-op so a fake
    /// that only exercises the capture gate compiles unchanged;
    /// ``NativeCaptureCoordinator`` provides the real implementation.
    func updateRouting(appRoutes: [AppRoute], excludedBundleIDs: Set<String>)
}

extension CaptureControlling {
    func updateRouting(appRoutes: [AppRoute], excludedBundleIDs: Set<String>) {}
}

extension NativeCaptureCoordinator: CaptureControlling {}

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
