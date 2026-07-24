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
/// AP1-only receivers (raop-only from the start — they never advertised
/// `_airplay._tcp`) are driven through the SAME shared engine as AP2: they're
/// discovered, surfaced `isAvailable = true`, fed to `engine.updateDiscovery`,
/// and `addOutput`-ed exactly like AP2 receivers, so volume/mute/select and the
/// per-app `streamId` bindings all flow through the ordinary engine surface. The
/// ONE thing that stays different is `supportsAirPlay2` — it remains `false` for
/// an AP1 receiver because it means "no perfect multi-room sync", which is still
/// true. That flag is no longer an "unsupported" gate; it only advertises the
/// missing-sync fact, and AP1 devices are free to join mixed groups with AP2.

/// A no-op ``AudioProcessEnumerating`` that reports zero live Core Audio process
/// objects — the harmless default ``AudioProcessResolver`` behind both
/// ``PerAppCaptureCoordinator`` and ``NativeCaptureCoordinator`` until an
/// AppKit-importing layer (`AppDelegate`) supplies the real
/// `CoreAudioProcessEnumerator`-backed resolver. Mirrors the old
/// `resolvePID: { _ in nil }` default: no Core Audio call happens, so every
/// existing test that doesn't pass a resolver explicitly stays exactly as inert
/// as before.
public struct NoAudioProcesses: AudioProcessEnumerating {
    public init() {}
    public func enumerateProcesses() -> [RawAudioProcess] { [] }
    public func parentPID(of pid: pid_t) -> pid_t? { nil }
}

public final class NativeBackend: OutputBackend, LatencyConfigurable, MeteringControlling, AppRouteConfiguring, @unchecked Sendable {

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

    /// Supplies the connect-time seed volume (percent) each time a device joins
    /// the output set — read live so a Settings change takes effect on the next
    /// connect with no re-wiring. Production reads ``AppSettings/connectVolume``
    /// (already clamped above 0); ``connectVolumeSeed`` clamps it AGAIN to
    /// ``AppSettings/minConnectVolume``…``AppSettings/maxConnectVolume`` so an
    /// injected test provider can never smuggle 0/silent onto the wire. `@Sendable`
    /// and constructs its own `AppSettings` per call (captures nothing non-Sendable)
    /// so it is safe to invoke from `stateQueue`. See ``connectVolumeSeed``.
    private let connectVolumeProvider: @Sendable () -> Int

    /// Whether the macOS SYSTEM default output device is itself AirPlay-class
    /// (Wave 3 W3-T3) — read live so a mid-session Sound-menu switch is picked up
    /// on the next ``reconcileSystemAirPlayGuard()`` with no re-wiring. Defaults
    /// to the real Core Audio query (``currentDefaultOutputIsAirPlayClass()``);
    /// tests inject a scripted provider so the guard is exercisable with no audio
    /// hardware in the loop. `@Sendable`, safe to invoke from `stateQueue`. See
    /// ``reconcileSystemAirPlayGuard()``.
    private let systemDefaultOutputIsAirPlayClassProvider: @Sendable () -> Bool

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

    /// Supplies whether `id` is currently a member of "Selected Devices" — the
    /// signal T-BACKEND needs to detect "Mac + ≥1 AirPlay" ("play everywhere"),
    /// since `GroupController.applyRouting` always filters the local device out
    /// of the `ids` this backend's `setOutputSet` receives (the local Mac is
    /// never a real engine output). `GroupController` already exposes exactly
    /// this via its public `isSpeakerSelected(_:)`; `AppDelegate` wires it in
    /// once both are constructed. Assigned once, before any selection change —
    /// same discipline as `captureCoordinator`/`localPlaybackEngine` — so no
    /// synchronization is needed on the reference itself. `nil` in tests / the
    /// UI-only smoke path, in which case "play everywhere" never activates
    /// (read as "Mac not selected").
    public var selectedDevicesQuery: ((String) -> Bool)?

    /// Builds the real delayed-local-sink instance the first time "play
    /// everywhere" activates (T-BACKEND). `makeBackend(_:)` wires the production
    /// closure — constructed at 44.1 kHz / 2ch to match the AirPlay engine's own
    /// format, since T-FANOUT feeds the sink the SAME already-converted PCM it
    /// hands the engine rather than running a second resample pass. Tests inject
    /// a spy conforming to ``SyncedLocalSinkControlling``. `nil` in the UI-only
    /// smoke path, in which case "play everywhere" is inert (same posture as a
    /// `nil` `captureCoordinator`).
    public var syncedLocalSinkFactory: (() -> SyncedLocalSinkControlling)?

    /// The constructed sink (real or test spy), built lazily on first enable and
    /// reused across later disable/re-enable cycles rather than rebuilt every
    /// time. Confined to `captureControlQueue` — the same serial queue every
    /// attach/start/stop below runs on.
    private var syncedLocalSink: SyncedLocalSinkControlling?

    /// Whether "play everywhere" is currently enabled — the last decision made
    /// by `setOutputSet`'s synced-local-sink reconciliation. Confined to
    /// `stateQueue` like every other selection-derived flag (`captureRunning`,
    /// `expectedSelected`); the actual attach/start/stop work it triggers runs
    /// on `captureControlQueue`.
    private var syncedLocalSinkEnabled = false

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

    /// One process tap per app currently routed to a specific device. Its
    /// ``AudioProcessResolver`` is injected (Core can't import AppKit /
    /// `NSRunningApplication`); the default resolves nothing, so `start` lands
    /// each bundle ID in `.failed(.appNotRunning)` without touching Core Audio
    /// until an AppKit-importing layer (`AppDelegate`) supplies the real one.
    private let perAppCapture: PerAppCaptureCoordinator

    /// Combines the per-app captures into per-destination mixed streams and owns the
    /// stable device⟷stream_id topology. Pure computation (no Core Audio/engine).
    private let routeMixer: AppRouteMixer

    /// A dedicated per-app capture used ONLY to meter listed apps that are NOT
    /// otherwise captured (`.noRedirect`) — the third `.appLevel` source (T3).
    /// Built `.unmuted` (unlike `perAppCapture`, which is `.mutedWhenTapped` for
    /// actual routing) so it never silences an app it's merely measuring; its
    /// buffers become `.appLevel` and NOTHING else — it feeds neither the mixer
    /// nor the engine. Started/stopped by the popover-scoped metering gate
    /// (`setMeteringActive`) + reconciled by `updateAppRoutes`; it NEVER touches
    /// the primary routing coordinator's taps. See the Metering (T3) section.
    private let meteringCapture: PerAppCaptureCoordinator

    // MARK: State (all confined to `stateQueue`)

    // Same discipline as OwnToneBackend/MockBackend: every mutation of the maps
    // below happens on `stateQueue`; `@unchecked Sendable` is honest because of it.
    private let stateQueue = DispatchQueue(label: "NativeBackend.state")
    private var known: [String: Device] = [:]           // last-known snapshot, by id
    private var order: [String] = []                    // stable discovery order
    private var continuations: [UUID: AsyncStream<BackendEvent>.Continuation] = [:]
    private var started = false

    /// Whether the engine's last `start()` found a PTP clock (T4). Read from
    /// ``EngineControlling/ptpClockAvailable`` once `engine.start()` resolves
    /// and confined to `stateQueue` like every other piece of backend state;
    /// `true` before the first `start()` completes (optimistic, matching the
    /// engine's own pre-start default — see ``AirPlayEngine/ptpClockAvailable``).
    /// Exposed publicly so the app can surface a degraded "clock unavailable"
    /// state (T6 owns the actual UI); this task only makes the fact observable.
    private var ptpClockAvailable = true

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

    // MARK: Sleep/wake + generalized silence watchdog (B6b + Wave 2 W2-T2 / R11 —
    // all confined to `stateQueue`)
    //
    // Sleep severs the RTSP/PTP sockets. `handleSystemWillSleep()` tears the engine
    // outputs down cleanly (graceful TEARDOWN) but KEEPS `expectedSelected` /
    // `desiredOn` intact, and `handleSystemDidWake()` re-converges them — so a sleep
    // is a transient dropout, never a deselection. Crucially the willSleep teardown
    // emits NO `deviceUpdated`: GroupController's reverse auto-swap (which restores
    // {local} and clears the Selected Devices intent) is event-driven, so emitting
    // nothing means it can't fire.
    //
    // The SILENCE WATCHDOG generalizes the original wake-only fallback to EVERY path
    // (Wave 2, closes R11 — a group whose speakers all fail/offline used to leave the
    // Mac muted in total silence forever). The rule is path-agnostic: whenever the
    // capture gate WANTS to stream (a non-local device is desired) but ZERO desired
    // devices are `.connected`, a countdown arms; if it elapses with nothing
    // connected, capture un-gates so the Mac becomes audible — WITHOUT clearing
    // intent — and a banner is shown. Any desired device reconnecting (or the intent
    // clearing) re-engages the gate and clears the banner. Wake-from-sleep is now
    // just one trigger of this: `handleSystemDidWake` re-converges (nothing connected
    // yet) and lets the shared reconcile arm the same countdown.

    /// Whether the backend is currently suspended for system sleep. While true the
    /// capture gate is forced off (`reconcileCaptureGate`) and no converge/discovery
    /// path re-adds an output — `handleSystemDidWake()` is the one thing that clears
    /// it and re-drives convergence.
    private var suspended = false

    /// The silence watchdog's override on the capture gate. When the watchdog fires
    /// (no desired non-local device is `.connected`), this flips true and the gate
    /// computes `want == false` even though `expectedSelected` is non-empty —
    /// un-muting the Mac WITHOUT clearing intent (R11: a dead group falls back to
    /// local playback instead of silence). A later reconnect / intent clear
    /// (`reconcileSilenceWatchdog`) clears it and re-reconciles, re-engaging the gate.
    ///
    /// Fix B (invariant 4, "UI never lies"): every path that clears this back to
    /// false — `reconcileSilenceWatchdog`, `stop`, sleep, wake — MUST go through
    /// ``clearSilenceOverride()`` so the `.localFallbackActive(false)` banner-clear
    /// is emitted on the genuine true→false edge. A bare `= false` here strands the
    /// popover banner "playing on this Mac" forever.
    private var silenceCaptureOverride = false

    /// W3-T3 (System-AirPlay guard, PLAN-RELIABILITY.md Wave 3): whether the
    /// double-path/echo note is currently active — the whole-system capture tap
    /// is actually running (`captureRunning`) AND the macOS SYSTEM default output
    /// is ALSO AirPlay-class. Purely a UI signal: unlike `silenceCaptureOverride`,
    /// setting this never itself changes the capture gate or any audio path.
    ///
    /// Every path that flips this back to false MUST go through
    /// ``clearSystemAirPlayGuard()`` (mirrors Fix B / ``clearSilenceOverride()``)
    /// so `.systemDefaultIsAirPlayActive(false)` is emitted on the genuine
    /// true→false edge and the popover note can never strand ON. Confined to
    /// `stateQueue`.
    private var systemAirPlayGuardActive = false

    /// Fix C (R11): whether we are in the immediate post-wake reconnection window,
    /// set by ``handleSystemDidWake()`` and cleared once a desired device reconnects,
    /// the user re-selects, the watchdog fires, or we sleep/stop. It selects which
    /// delay ``armSilenceWatchdog()`` uses: the user's ``wakeAudioRestoreDelay``
    /// preference while awaiting a wake reconnect, versus the always-on
    /// ``silenceFallbackDelay`` for a dead-group / stranded condition during normal
    /// operation. Confined to `stateQueue`.
    private var awaitingWakeReconnect = false

    /// The POST-WAKE restore delay in seconds (Settings › Audio, B6b), or `nil` for
    /// "Never". Pushed by the app layer via ``setWakeAudioRestoreDelay(_:)``; read by
    /// ``armSilenceWatchdog()`` ONLY while ``awaitingWakeReconnect`` — a separate user
    /// preference for how long to wait after a sleep/wake before un-muting the Mac.
    /// It no longer gates the dead-group/stranded fallback (Fix C): that uses the
    /// always-on ``silenceFallbackDelay`` so "Never" can't reopen R11's indefinite
    /// silence during normal operation. Confined to `stateQueue`.
    private var wakeAudioRestoreDelay: TimeInterval?

    /// Fix C (R11): the ALWAYS-ON silence-fallback delay in seconds for a dead-group /
    /// stranded condition during normal operation — decoupled from the user's
    /// wake-restore preference so it can never be disabled ("Never" only affects the
    /// post-wake window). A short default (``defaultSilenceFallbackDelay``) so a dead
    /// group falls back to local playback within seconds, not the up-to-2-minutes the
    /// wake-restore delay allowed. Injectable so tests shrink it; never mutated after
    /// init.
    private let silenceFallbackDelay: TimeInterval

    /// The default always-on silence-fallback delay (seconds). ~10 s: long enough to
    /// ride out a brief drop/reconnect, short enough that a genuinely dead group
    /// doesn't leave the user in silence (R11). Deliberately fixed (no UI): it is a
    /// safety net, not a preference — the preference is the post-wake
    /// ``wakeAudioRestoreDelay``.
    public static let defaultSilenceFallbackDelay: TimeInterval = 10

    /// The armed silence-watchdog countdown. Cancelled when a desired device
    /// reconnects, the intent clears, on a sleep/wake cycle, or on `stop()`.
    private var silenceWatchdog: SilenceWatchdogToken?

    /// Injectable timer seam for the silence watchdog so hermetic tests fire the
    /// countdown deterministically. Defaults to a real `DispatchQueue.asyncAfter`
    /// wrapper (see the designated initializer). Never mutated after init.
    private let watchdogScheduler: SilenceWatchdogScheduling

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
    /// plain buffer change never slams the level back to the connect default. See
    /// ``connectVolumeSeed(_:outputID:)`` for the −30 dB trap the whole seed exists
    /// to avoid.
    private var bufferReAdding: Set<String> = []

    private var stateStreamTask: Task<Void, Never>?

    /// Drains the engine's remote-control stream (speaker transport keys). Same
    /// `stateQueue` confinement as ``stateStreamTask``.
    private var remoteEventStreamTask: Task<Void, Never>?

    /// The sender-side DACP endpoint: how a volume change made ON THE SPEAKER
    /// reaches us (the receiver calls this back — see ``DACPServer``). Started in
    /// `start()` with the engine's DACP-ID so its advertised `iTunes_Ctrl_<id>`
    /// matches what the engine tells receivers. Volume travels here, not the RTSP
    /// event channel — confirmed against the AirPlay spec + OwnTone's httpd_dacp.
    private let dacpServer = DACPServer()

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
    //     boundary's forwarding target (mirrors the `processResolver` injection).
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

    /// bundleID → how many `.processNotYetAudible` retries have already fired
    /// (edge case 3). Kept ONLY to grow the capped-exponential backoff delay, not
    /// as a give-up ceiling. Reset on recovery (`.capturing`) or on losing the
    /// route entirely.
    private var retryCounts: [String: Int] = [:]

    /// bundleID → its in-flight bounded retry, so a second failure while one is
    /// already scheduled replaces rather than stacks it, and a recovery /
    /// de-route can cancel it (best-effort — a `DispatchWorkItem` already
    /// running when cancelled still completes, same D4 tolerance as everywhere
    /// else in this file).
    private var pendingRetries: [String: DispatchWorkItem] = [:]

    /// Base delay before the FIRST `.processNotYetAudible` retry, and the seed of
    /// the capped-exponential backoff (doubled per attempt, capped at
    /// `processNotYetAudibleMaxBackoff`). `var`-free `let`, injectable only through
    /// the designated initializer so tests can shrink it — production never needs to.
    private let processNotYetAudibleRetryDelay: TimeInterval

    /// Ceiling for the `.processNotYetAudible` retry backoff. The delay doubles
    /// each attempt (`retryDelay`, ×2, ×2, …) but never exceeds this, so a routed
    /// app that stays paused is re-probed forever on a bounded interval rather than
    /// being permanently given up on. Retries continue as long as the route is
    /// still desired (`routedBundleIDs.contains`); there is no attempt ceiling.
    private let processNotYetAudibleMaxBackoff: TimeInterval

    /// deviceID → a monotonically increasing generation token for its in-flight
    /// AirPlay-session rebind recovery (T4). Bumped on every fresh
    /// `resetAirPlaySessionForRoutedApp` for the device, so an older recovery
    /// chain that completes late can tell it has been superseded (its captured
    /// `gen` no longer matches) and bow out — this is what single-flights the
    /// recovery per device. Removed once the recovery succeeds or gives up.
    private var rebindRecoveryGen: [String: Int] = [:]

    /// deviceID → its scheduled (backing-off) rebind-recovery retry, so a fresh
    /// reset or a de-route/unbind can cancel a pending attempt rather than let it
    /// thrash a receiver. Best-effort (a work item already running when cancelled
    /// still no-ops via its own guards), same D4 tolerance as `pendingRetries`.
    private var pendingRebindRecoveries: [String: DispatchWorkItem] = [:]

    /// Bounded attempt ceiling for the AirPlay-session rebind recovery (T4).
    /// UNLIKE the indefinite `.processNotYetAudible` retry: a rebind that keeps
    /// failing means the receiver is genuinely gone, and infinite
    /// removeOutput/addOutput would thrash a real device — so recovery gives up
    /// loudly after this many attempts and leaves the device in a defined state.
    private let maxRebindRecoveryAttempts: Int

    /// Base (and backoff seed) delay before the next rebind-recovery attempt (T4).
    /// Doubled per attempt (`delay × 2^(attempt-1)`). Injectable so tests don't
    /// pay real wall-clock seconds; production never needs to tune it.
    private let rebindRecoveryRetryDelay: TimeInterval

    // MARK: Metering (T3 — three real level sources through the event channel)
    //
    // Replaces the old single whole-system RMS fanned identically to every device.
    // Three real sources now feed the meters, all through the same `BackendEvent`
    // channel, all popover-scoped (gated on `meteringActive`, flipped by
    // `setMeteringActive`):
    //   - Per-device `.level` = MAX(the whole-system-tap RMS iff the device is a
    //     Selected Device + unmuted, the loudest PRE-volume SOURCE level among the
    //     apps `.device`-routed to it). A device fed by both shows the larger
    //     (product decision). Every meter input is a SOURCE/program level — never
    //     scaled by a routing/output volume (ahh: a low slider must not empty a bar).
    //   - Per-app `.appLevel` for EVERY listed app, all PRE-volume source levels,
    //     one source by route kind:
    //       `.device`        -> `routeMixer.onAppLevel`          (pre-volume source)
    //       `.currentDevice` -> `localPlaybackEngine.onAppLevel` (pre-volume, raw)
    //       `.noRedirect`    -> `meteringCapture` (a dedicated `.unmuted` tap)

    /// Whether a meter is currently being shown (popover open). Gates every
    /// `.level`/`.appLevel` emission and the metering-only tap lifecycle;
    /// forwarded to `captureCoordinator`/`routeMixer`/`localPlaybackEngine` (each
    /// gates its own RMS pass on it). Confined to `stateQueue`.
    private var meteringActive = false

    /// The most recent whole-system-tap RMS (stream_id 0) — a device's system
    /// contribution when it is a Selected Device (unmuted). On `stateQueue`.
    private var latestSystemRMS: Float = 0

    /// bundleID -> its most recent PRE-volume SOURCE RMS. A redirect target's
    /// meter contribution is the loudest source routed to it (NOT the attenuated
    /// mix), so a low routing-volume slider no longer empties the bar. Cleared on
    /// `stop()`; a stale entry for an un-routed app is simply never aggregated (the
    /// per-device sum reads only currently-`.device`-routed apps). On `stateQueue`.
    private var latestAppLevel: [String: Float] = [:]

    /// The excluded-apps denylist last handed to `updateAppRoutes` — retained so
    /// the metering-only target set can subtract it (PRIVACY: an excluded app is
    /// NEVER metered) and re-reconcile when the denylist changes. On `stateQueue`.
    private var lastExcludedBundleIDs: Set<String> = []

    /// The bundle IDs that currently have a metering-only tap running — the live
    /// truth `meteringTapDiffLocked()` diffs against. On `stateQueue`.
    private var meteringTapTargets: Set<String> = []

    // MARK: Init

    /// Public seam: the real native backend over the in-process ``AirPlayEngine``
    /// and a live ``NativeDiscovery`` (`NWBrowser`). `EngineControlling` /
    /// `DiscoverySource` stay internal-facing (tests inject doubles); no engine or
    /// OwnTone type leaks into the public surface.
    ///
    /// `processResolver` maps a bundle ID to the FULL set of live Core Audio
    /// process objects it owns — main process plus every child/helper
    /// (media/RDD/utility) process a multi-process browser like Firefox actually
    /// emits audio from (the leak/silence fix). It defaults to a resolver that
    /// resolves nothing because Core can't import AppKit; the AppKit-importing
    /// layer (`AppDelegate`) threads the real `NSRunningApplication`-backed one
    /// in. It flows to BOTH the per-app capture coordinator (owned here) and the
    /// whole-system `NativeCaptureCoordinator` (wired by `makeBackend`, which
    /// uses the same resolver).
    public convenience init(
        engine: AirPlayEngine,
        discovery: NativeDiscovery = NativeDiscovery(),
        processResolver: AudioProcessResolver = AudioProcessResolver(enumerator: NoAudioProcesses())
    ) {
        self.init(
            engineControl: EngineAdapter(engine: engine),
            discoverySource: discovery,
            processResolver: processResolver)
    }

    /// Injectable designated initializer (internal — tests pass a spy engine and an
    /// injected discovery double so the whole backend runs with no engine, network,
    /// or TCC).
    ///
    /// `systemVolume` defaults to the real ``SystemOutputVolume`` so the convenience
    /// init (and `makeBackend`) stay unchanged; tests inject a fake and drive the
    /// local row with no audio hardware in the loop.
    ///
    /// `processResolver` is threaded into the per-app capture coordinator
    /// constructed here. Its default (an ``AudioProcessResolver`` over
    /// ``NoAudioProcesses``) keeps the per-app path inert for every existing
    /// test: with no process ever resolving, `perAppCapture.start` fails fast
    /// (`.appNotRunning`) and never opens a Core Audio tap — so the routing
    /// TOPOLOGY (`addOutput(_:streamId:)` bindings + `.routedApps` events), which is
    /// derived purely from the route table, still exercises fully.
    ///
    /// `perAppCapture` is normally built internally from `processResolver`
    /// (production shape); tests that need to script per-app tap behavior (T8: a
    /// quit mid-stream, a `.processNotYetAudible` failure/recovery) instead
    /// construct a ``PerAppCaptureCoordinator`` over a fake ``ProcessAudioTap``
    /// themselves and pass it in here, bypassing the real Core Audio path
    /// entirely — mirrors how `engineControl`/`discoverySource` are always
    /// doubles in this init. `processNotYetAudibleRetryDelay`/
    /// `processNotYetAudibleMaxBackoff` (T8) tune the capped-exponential retry
    /// for a `.processNotYetAudible` capture failure; tests shrink the delay so
    /// the retry doesn't cost real wall-clock seconds.
    init(
        engineControl: EngineControlling,
        discoverySource: DiscoverySource,
        systemVolume: SystemVolumeControlling = SystemOutputVolume(),
        connectVolume: @escaping @Sendable () -> Int = { AppSettings().connectVolume },
        processResolver: AudioProcessResolver = AudioProcessResolver(enumerator: NoAudioProcesses()),
        injectedPerAppCapture: PerAppCaptureCoordinator? = nil,
        injectedMeteringCapture: PerAppCaptureCoordinator? = nil,
        processNotYetAudibleRetryDelay: TimeInterval = 2.0,
        processNotYetAudibleMaxBackoff: TimeInterval = 10.0,
        maxRebindRecoveryAttempts: Int = 3,
        rebindRecoveryRetryDelay: TimeInterval = 0.5,
        watchdogScheduler: SilenceWatchdogScheduling? = nil,
        silenceFallbackDelay: TimeInterval = NativeBackend.defaultSilenceFallbackDelay,
        systemDefaultOutputIsAirPlayClass: @escaping @Sendable () -> Bool = NativeBackend.currentDefaultOutputIsAirPlayClass
    ) {
        // Default the silence-watchdog timer to a real dispatch-queue wrapper. Its
        // scheduled body always hops onto `stateQueue` itself (see `armSilenceWatchdog`),
        // so this queue only needs to time the delay — a plain serial queue is fine.
        self.watchdogScheduler = watchdogScheduler
            ?? DispatchSilenceWatchdogScheduler(queue: DispatchQueue(label: "NativeBackend.silenceWatchdog"))
        self.silenceFallbackDelay = silenceFallbackDelay
        self.engine = engineControl
        self.discovery = discoverySource
        self.systemVolume = systemVolume
        self.connectVolumeProvider = connectVolume
        self.systemDefaultOutputIsAirPlayClassProvider = systemDefaultOutputIsAirPlayClass
        self.perAppCapture = injectedPerAppCapture ?? PerAppCaptureCoordinator(processResolver: processResolver)
        // The metering-only tap (T3, third `.appLevel` source): its OWN coordinator,
        // built `.unmuted` and with a distinct aggregate-device name so it never
        // collides with `perAppCapture`. Same injected `processResolver`. Tests can
        // script it via `injectedMeteringCapture` (mirrors `injectedPerAppCapture`).
        self.meteringCapture = injectedMeteringCapture
            ?? PerAppCaptureCoordinator(processResolver: processResolver, name: "AudiouterMeter", muteBehavior: .unmuted)
        self.routeMixer = AppRouteMixer()
        self.processNotYetAudibleRetryDelay = processNotYetAudibleRetryDelay
        self.processNotYetAudibleMaxBackoff = processNotYetAudibleMaxBackoff
        self.maxRebindRecoveryAttempts = maxRebindRecoveryAttempts
        self.rebindRecoveryRetryDelay = rebindRecoveryRetryDelay

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
            // The per-device meter is driven by the apps' PRE-volume SOURCE levels
            // (see `emitAppLevel`), NOT this post-volume mixed buffer — so nothing
            // metering-related is read off the mix here.
        }
        // Per-app meter, source 1/3: `.device`-routed apps (PRE-volume SOURCE RMS
        // from the mixer). The mixer gates `onAppLevel` on its OWN `meteringActive`,
        // so this fires only while a meter is shown.
        routeMixer.onAppLevel = { [weak self] bundleID, rms in
            self?.emitAppLevel(bundleID: bundleID, rms: rms)
        }
        // Per-app meter, source 3/3: listed apps with no other capture
        // (`.noRedirect`), metered by the dedicated `.unmuted` `meteringCapture`.
        // Compute the raw Float32 RMS on the delivery thread, then hop to emit
        // (gated on metering — a buffer racing a just-stopped tap is dropped).
        meteringCapture.onBuffer = { [weak self] bundleID, buffer in
            guard let self else { return }
            let rms = NativeCaptureCoordinator.rmsOfFloat32(buffer)
            self.emitAppLevel(bundleID: bundleID, rms: rms)
        }
    }

    // MARK: OutputBackend

    // STABILITY(C8): main thread blocks on the state queue for slow work — see dev/notes/stability-audit-2026-07-18.md
    public var devices: [Device] {
        stateQueue.sync { order.compactMap { known[$0] } }
    }

    /// Whether the engine's last `start()` found a PTP clock (T4). `true`
    /// before the first `start()` resolves. A `false` reading is NOT itself an
    /// error — NTP-only receivers still work — but a PTP-only receiver (Sonos
    /// et al, SPEC.md §8 0b) will fail to stream despite the engine/backend
    /// otherwise looking healthy, so a degraded-state UI (T6) can key off this.
    public var isPTPClockAvailable: Bool {
        stateQueue.sync { ptpClockAvailable }
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
            // `isLocalDevice`, and it has no `outputIDs` entry to add).
            self.surfaceLocalDevice(name: localName, volume: localVolume, muted: localMuted)
        }

        // 1. Wire discovery → the app model + the engine descriptor feed. Every
        //    reachable receiver — AP1 or AP2 — gets fed to `engine.updateDiscovery`
        //    so the engine knows about it (a prerequisite for `addOutput`). Only the
        //    local Mac output is never fed (it isn't a discovered receiver).
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

                // 1d. W3-T3: the default output device itself may have just BECOME (or
                //     stopped being) AirPlay-class — re-evaluate the double-path guard.
                //     A same-device volume/mute gesture (`defaultDeviceChanged == false`)
                //     can't change the transport type, so skip the query on that far more
                //     frequent path.
                if defaultDeviceChanged {
                    self.reconcileSystemAirPlayGuard()
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

            // 2b. T4: capture the engine's PTP clock-availability verdict from
            //     this same `start()` (the ONLY time it's determined — the
            //     engine doesn't re-check mid-session). A `false` reading here
            //     does not stop the app from proceeding (PTP-only receivers
            //     simply won't stream; NTP-only ones are unaffected) — it's
            //     surfaced, not fatal, exactly like the engine's own non-fatal
            //     handling of the same fact.
            let ptpAvailable = await self.engine.ptpClockAvailable
            self.stateQueue.async { self.ptpClockAvailable = ptpAvailable }

            // 3. Subscribe the engine's device-state stream: every transition
            //    (armed-op terminal AND out-of-band, e.g. RTSP drop → .failed) maps
            //    to a `deviceUpdated`. This is the native analogue of OwnTone's
            //    zombie detection — but push, not poll.
            self.subscribeStateStream()

            // 3b. Subscribe the engine's remote-control stream: a user pressing a
            //     transport key ON THE SPEAKER flows in here (→ a Mac media key).
            self.subscribeRemoteEventStream()

            // 3c. Start the DACP endpoint: a user changing the volume ON THE SPEAKER
            //     reaches us here (the receiver calls back over DACP, not the event
            //     channel). Advertise under the SAME id the engine sends receivers,
            //     and route each report to that speaker's slider.
            self.dacpServer.onVolume = { [weak self] token, level in
                self?.applyDacpVolume(activeRemote: token, level: level)
            }
            self.dacpServer.onVolumeStep = { [weak self] token, direction in
                self?.applyDacpVolumeStep(activeRemote: token, direction: direction)
            }
            self.dacpServer.start(dacpID: self.engine.dacpID)

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

            // Whole-system capture health (T2). A nominal-sample-rate renegotiation
            // (opening the Mac's built-in speakers in a Mac+AirPlay synced-local
            // selection flips the tapped device 44.1↔48 kHz) rebuilds the tap, after
            // which the process tap keeps delivering buffers but the stream-0 AirPlay
            // sessions stay pinned to a now-stale RTP timeline and the receivers go
            // silent forever (Apple-unresolved, Dev Forums 825780). The coordinator
            // fires `onDeviceRateRebuild` ONLY for that device/rate-caused rebuild —
            // NOT for a benign exclusion-set rebuild (the synced-local sink attach on
            // every connect, or an app-route change), which leaves the receivers'
            // timeline intact. Resetting on the benign rebuild too (the earlier
            // `.capturing`-count heuristic) fired a redundant removeOutput→addOutput
            // on every Mac+AirPlay connect — "connects fast, then a long silence
            // before audio." Wired here like `onLevel` (the coordinator is assigned
            // before `start()`); it fires from the coordinator's own queue and
            // `resetAirPlaySessionForWholeSystem` hops to `stateQueue` for the mutation.
            self.captureCoordinator?.onDeviceRateRebuild = { [weak self] in
                self?.resetAirPlaySessionForWholeSystem()
            }

            // Per-app meter, source 2/3: `.currentDevice` apps rendered locally.
            // Wired here like `onLevel` (the engine is assigned before `start()`);
            // it only fires while metering is active (the engine gates its own RMS
            // pass) and emits the PRE-volume raw RMS unchanged. Hop to `stateQueue`.
            self.localPlaybackEngine?.onAppLevel = { [weak self] bundleID, rms in
                self?.emitAppLevel(bundleID: bundleID, rms: rms)
            }
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
        // T2: stop observing the whole-system tap's device/rate rebuilds so the
        // ordered `captureControlQueue` stop below (which tears the tap down) can't
        // fire a spurious session reset during teardown.
        captureCoordinator?.onDeviceRateRebuild = nil
        captureCoordinator?.setMeteringActive(false)
        // Metering (T3): leave every metering source switched off (teardown
        // discipline — a closed backend has nobody to render a meter for) and stop
        // every metering-only tap. `meteringCapture.stopAll()` is off `stateQueue`
        // (Core Audio teardown), matching the taps below. The whole-system tap is
        // NOT stopped eagerly here — the ordered `captureControlQueue` stop below is
        // the documented final word (C1: an eager caller-thread stop blocked quit).
        routeMixer.setMeteringActive(false)
        localPlaybackEngine?.onAppLevel = nil
        localPlaybackEngine?.setMeteringActive(false)
        meteringCapture.stopAll()
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
        // Stop advertising / listening for DACP (speaker-initiated volume).
        dacpServer.onVolume = nil
        dacpServer.onVolumeStep = nil
        dacpServer.stop()

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
            self.remoteEventStreamTask?.cancel()
            self.remoteEventStreamTask = nil
            self.started = false
            // Reset the capture gate: a later start() re-decides from scratch, and
            // capture stays off until a setOutputSet selects a real AP2 output.
            self.captureRunning = false
            // B6b / R11: drop any pending silence watchdog + reset sleep/wake flags so
            // a stop mid-wait can't leave capture wedged off (override) or suspended.
            self.silenceWatchdog?.cancel()
            self.silenceWatchdog = nil
            self.awaitingWakeReconnect = false          // Fix C
            self.clearSilenceOverride()                 // Fix B: emit the banner-clear on true→false
            // W3-T3: capture just stopped (above) — clear the double-path guard too,
            // on the true→false edge, so a stop mid-note can't strand the popover note.
            self.clearSystemAirPlayGuard()
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
            // T4: drop any in-flight AirPlay-session rebind recovery — the engine
            // sessions are torn down by `engine.stop()` above and `bindTail` is
            // cancelled, so a fresh start() re-binds from scratch.
            self.rebindRecoveryGen.removeAll()
            for work in self.pendingRebindRecoveries.values { work.cancel() }
            self.pendingRebindRecoveries.removeAll()
            self.bufferReAdding.removeAll()
            // Metering (T3): a later start() re-decides from a clean slate — no
            // stale system/stream RMS, metering off, no metering-only targets.
            self.meteringActive = false
            self.latestSystemRMS = 0
            self.latestAppLevel.removeAll()
            self.lastExcludedBundleIDs.removeAll()
            self.meteringTapTargets.removeAll()
            // T4: a later start() re-determines clock availability from
            // scratch — reset to the same optimistic default `start()` reads
            // before its own engine.start() resolves.
            self.ptpClockAvailable = true
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
                self.pushVolume(outputID, engineValue: self.engineVolume(forID: id, uiVolume: clamped))
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
                // For AirPlay-1 (RAOP) devices, send a sentinel value to trigger true silence (-144 dB).
                // For AirPlay-2, use the standard 0 volume with stashed value.
                let isAirPlay1 = !(self.known[id]?.supportsAirPlay2 ?? true)
                let engineValue = isAirPlay1 ? -1.0 : Self.engineVolume(0)
                self.pushVolume(outputID, engineValue: engineValue)
            } else {
                self.muted.remove(id)
                self.applyLocal(id) { $0.isMuted = false }
                self.restoreEffectiveVolume(id, outputID: outputID)
            }
        }
    }

    /// Renders a set of device ids as `"[Name1,Name2]"` for a Telemetry field —
    /// prefers the human-readable ``Device/name`` when the id is currently known
    /// (falls back to the raw id for a vanished/unknown one), sorted for
    /// deterministic output (Q6: names in cleartext are the point — a local-only
    /// diagnostic file, not uploaded anywhere). Pure formatting over an
    /// already-captured snapshot — takes no lock of its own, so it's safe to call
    /// from inside any existing critical section.
    private static func telemetryDeviceList(_ ids: Set<String>, known: [String: Device]) -> String {
        "[" + ids.sorted().map { known[$0]?.name ?? $0 }.joined(separator: ",") + "]"
    }

    public func setOutputSet(_ ids: Set<String>) {
        // Record the intent and update the per-device coalescing target under the
        // state lock, then kick a per-device converge loop for anything whose
        // desired state actually changed. Rapid toggle spam collapses here: N
        // flips for one device overwrite `desiredOn[id]` N times but issue at most
        // one op at a time (root cause 1) — intermediate flips are simply dropped.
        // STABILITY(C8): main thread blocks on the state queue for slow work — see dev/notes/stability-audit-2026-07-18.md
        let (toKick, syncedLocalTransition): ([(id: String, outputID: OutputID)], Bool?) = stateQueue.sync {
            // T4: captured BEFORE the overwrite below so the Telemetry line at the
            // end of this critical section can log the actual added/removed diff.
            let previouslySelected = self.expectedSelected
            self.expectedSelected = ids
            // Fix C: an explicit (re)selection is a fresh normal-operation context, not
            // a post-wake reconnection — so a stranding from THIS selection falls back
            // on the always-on silence delay, not the wake-restore preference.
            self.awaitingWakeReconnect = false

            // Only ids we can actually stream to — a known discovered receiver
            // (AP1 or AP2) with an engine handle — can be desired-on. The local Mac
            // is excluded (`isLocalDevice`, and it has no `outputIDs` entry); AP1
            // receivers are NOT excluded any more (they drive through the same
            // engine surface as AP2, `supportsAirPlay2` notwithstanding).
            var kicks: [(String, OutputID)] = []
            for id in self.order {
                guard let device = self.known[id], !device.isLocalDevice,
                      let outputID = self.outputIDs[id] else { continue }
                let wantOn = ids.contains(id)

                // A user re-toggle to ON clears a terminal-failure park so the
                // device is re-enableable after a NACK (root cause 4: no permanent
                // wedge). Toggling OFF a parked device likewise clears the park (the
                // device is being deselected — nothing to retry).
                if self.failedGate.contains(id) { self.failedGate.remove(id) }

                let previous = self.desiredOn[id]
                self.desiredOn[id] = wantOn

                // R12/W2-T3: `.failed` no longer drops the id from the desired
                // set (the popover's "Try again" keeps Selected-Devices intent
                // through a failure — it never toggles membership off first), so
                // a retry now arrives here with `wantOn` UNCHANGED (already
                // `true`) rather than as an off→on edge. Detect that case
                // explicitly and treat it as a fresh attempt too — this mirrors
                // OwnToneBackend's `setOutputSet`, which never gated retry on a
                // membership delta in the first place: it re-checks every id's
                // CURRENT `connectionState` on every call and re-kicks anything
                // `.off`/`.failed` regardless of whether that id was already in
                // the requested set.
                var isRetryOfFailed = false
                if wantOn, previous == true, case .failed? = self.known[id]?.connectionState {
                    isRetryOfFailed = true
                }

                // Connection-status brief §1/§3 semantics (mirrors OwnToneBackend's
                // `setOutputSet`): a device newly desired ON goes `.connecting`
                // immediately, before the engine op resolves, so the UI spinner is
                // immediate. This also clears a sticky `.failed` on retry (the
                // `failedGate` clear above is the routing-side twin of this). A
                // device newly desired OFF drops any in-flight/failed indication
                // back to `.off` right away — NativeBackend has no "sticky failed
                // survives deselect" behavior (its park is cleared on toggle
                // unconditionally, above), so the connection dot follows suit.
                if previous != wantOn || isRetryOfFailed {
                    self.setConnectionState(wantOn ? .connecting : .off, for: id)
                }
                // Kick if the desired state changed, OR this is a same-membership
                // retry of a `.failed` device (R12) — AND no loop is already
                // running for this id (a running loop re-reads `desiredOn` when
                // its op settles).
                if (previous != wantOn || isRetryOfFailed), !self.converging.contains(id) {
                    self.converging.insert(id)
                    kicks.append((id, outputID))
                    // Connect-latency diagnosis (temporary — see AudioDiag): T0 for
                    // "click to first audio," read alongside the addOutput
                    // start/resolve timestamps in convergeDevice below.
                    if wantOn {
                        AudioDiag.log("CONNECT requested device=\(id)")
                    }
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
            // Intent changed: re-evaluate the silence watchdog. Selecting a device (or
            // activating a group) with nothing yet `.connected` arms the countdown;
            // deselecting everything (or dropping to a local-only selection) clears any
            // active fallback and cancels the countdown. (R11: a group of dead speakers
            // is exactly "non-local intent, zero connected" the moment it's activated.)
            self.reconcileSilenceWatchdog()

            // T-BACKEND: "play everywhere" is Mac + ≥1 AirPlay device. `ids` here
            // IS the AirPlay-only side of that set (`GroupController` never hands
            // the local device through); the Mac's own membership comes from
            // `selectedDevicesQuery`, wired externally (AppDelegate). Decided in
            // this SAME critical section as the capture gate above so a burst of
            // rapid selection changes settles on the LAST decision only, exactly
            // like `reconcileCaptureGate` — `nil` below means "no change," so a
            // repeat decision (e.g. Mac+AirPlay → Mac+2×AirPlay) never re-kicks
            // the attach/start work.
            let macSelected = self.selectedDevicesQuery?(Self.localDeviceID) ?? false
            let wantSyncedLocal = macSelected && !ids.isEmpty
            var syncedLocalDecision: Bool?
            if wantSyncedLocal != self.syncedLocalSinkEnabled {
                self.syncedLocalSinkEnabled = wantSyncedLocal
                syncedLocalDecision = wantSyncedLocal
                // Metering fix: re-emit the local device's combined `.level`
                // immediately on this transition, mirroring the per-app "a
                // torn-down stream gets a final combined .level" discipline
                // (`updateRoutedSets`'s `unboundDevices` loop, below). Turning
                // OFF must push a zero-system-contribution reading right away —
                // `isMeterable` now returns false for the local device the
                // instant `syncedLocalSinkEnabled` flips, so this is a genuine
                // clear, not a stale nonzero value — so the row's meter can't
                // stick at its last reading after the Mac (or the last AirPlay
                // device) leaves the mix. Turning ON gets its first real
                // reading a whole tap-buffer-interval sooner than waiting for
                // the next `emitLevel` callback. Unconditional (not metering-
                // gated), matching that same precedent.
                self.emitCombinedLevel(forDevice: Self.localDeviceID)
            }

            // T4: log the selection diff + the resulting per-device convergence
            // target. Read-only over state already captured above, then a single
            // non-blocking `Telemetry.log` call (formats + hands off to its own
            // queue, never blocks/calls back) — purely additive, no new locking
            // and no change to the decisions or their order above.
            Telemetry.log(.airplay, "set_output_set", [
                "added": Self.telemetryDeviceList(ids.subtracting(previouslySelected), known: self.known),
                "removed": Self.telemetryDeviceList(previouslySelected.subtracting(ids), known: self.known),
                "desiredOn": Self.telemetryDeviceList(
                    Set(self.order.filter { self.desiredOn[$0] == true }), known: self.known),
            ])

            return (kicks, syncedLocalDecision)
        }

        // Runs on `captureControlQueue` — the same serial queue the capture
        // gate's start/stop above was just enqueued on — so a tap recreate
        // triggered by `attachSyncedLocalSink` (self-exclude pid change, T-FANOUT)
        // never races a capture-gate start/stop for the same tap.
        if let enable = syncedLocalTransition {
            captureControlQueue.async { [weak self] in
                self?.applySyncedLocalSinkTransition(enable: enable)
            }
        }

        for (id, outputID) in toKick {
            Task { [weak self] in
                guard let self else { return }
                await self.convergeDevice(id: id, outputID: outputID)
            }
        }
    }

    /// Execute the "play everywhere" enable/disable transition decided by
    /// `setOutputSet` above (T-BACKEND). Must run on `captureControlQueue`.
    ///
    /// Enable order (plan T-BACKEND): construct-if-needed → attach (wires the
    /// fan-out + tap self-exclude, T-FANOUT) → start → observe lifecycle events
    /// (T-LIFECYCLE then picks up default-device changes / sleep / wake).
    /// Disable is the mirror image — stop → stop observing → detach — so the
    /// sink is fully quiesced before its self-exclude is lifted. Either way, the
    /// whole-system tap's `.mutedWhenTapped` mode (`NativeCaptureCoordinator`'s
    /// default) is what actually keeps the Mac's raw output muted whenever ≥1
    /// AirPlay device is selected (`reconcileCaptureGate`'s `captureRunning`) —
    /// that mechanism is entirely independent of this sink's own on/off state,
    /// so disabling "play everywhere" while AirPlay devices stay selected
    /// correctly leaves the raw system mix muted.
    private func applySyncedLocalSinkTransition(enable: Bool) {
        if enable {
            let sink: SyncedLocalSinkControlling
            if let existing = syncedLocalSink {
                sink = existing
            } else if let factory = syncedLocalSinkFactory {
                sink = factory()
                syncedLocalSink = sink
            } else {
                return   // no factory wired (tests / UI-only smoke) — inert
            }
            attachSyncedLocalSink(sink)
            try? sink.start()
            sink.startObservingLifecycleEvents()
        } else {
            guard let sink = syncedLocalSink else { return }
            sink.stop()
            sink.stopObservingLifecycleEvents()
            attachSyncedLocalSink(nil)
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
            // Retained so the metering-only target set can subtract it and so a
            // denylist change alone re-reconciles the metering taps (T3, PRIVACY).
            self.lastExcludedBundleIDs = excludedBundleIDs
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
            // T3: re-reconcile the metering-only taps against the new route/excluded
            // table (routed/local/excluded were all just updated above). Empty when
            // metering is inactive. NEVER touches the primary `perAppCapture` taps.
            let meteringDiff = self.meteringTapDiffLocked()
            return UpdateRoutesPlan(
                mixerRoutes: mixerRoutes,
                captureToStart: newUnion.subtracting(previousUnion),
                captureToStop: previousUnion.subtracting(newUnion),
                localRemoved: previousLocal.subtracting(newLocal),
                localRoutes: routes.filter { $0.destination == .currentDevice },
                localExcluded: newLocal,
                meteringToStart: meteringDiff.start,
                meteringToStop: meteringDiff.stop)
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

            // Metering-only taps (T3): a SEPARATE coordinator from `perAppCapture`.
            // Stop apps that became routed/local/excluded (or when metering turned
            // off — the diff is empty then), start newly-listed uncaptured apps.
            // Stop-before-start; idempotent per bundle ID.
            for bundleID in plan.meteringToStop { self.meteringCapture.stop(bundleID: bundleID) }
            for bundleID in plan.meteringToStart { self.meteringCapture.start(bundleID: bundleID) }

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
        /// Metering-only tap reconcile (T3): bundle IDs to start/stop a dedicated
        /// `.unmuted` meter tap for (listed, uncaptured, unexcluded apps). Empty
        /// while metering is inactive.
        let meteringToStart: Set<String>
        let meteringToStop: Set<String>
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
    /// `.processNotYetAudible`, schedules an INDEFINITE capped-exponential-backoff
    /// retry that continues as long as the route is still desired — a paused app is
    /// re-probed forever and its `deadBundleIDs` exclusion is temporary (cleared on
    /// the eventual `.capturing`), never a permanent give-up. Every other failure
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
            // W1-T7 (Gap 2, R9): the moment a routed-and-therefore-excluded app
            // becomes audible, its per-app tap reaches `.capturing` here. Until
            // this instant its pid could NOT be translated to a Core Audio
            // process object, so the whole-system tap's exclusion list did not
            // actually exclude it — its audio was double-sent (to its own device
            // AND into the system mix). The system tap doesn't re-resolve on its
            // own for this case (the app's PID set is unchanged, so Gap 1's
            // membership diff correctly finds no change — only the pid's
            // TRANSLATABILITY changed). Force the exclusion re-resolve now, reusing
            // W1-T5's relaunch mechanism: it no-ops unless `bundleID` is actually
            // excluded/routed-away, so it's cheap for a bundle that turns out not
            // to be excluded (a `.currentDevice` app, or metering-only capture).
            captureCoordinator?.refreshExcludedProcessSet(forRelaunchedBundleID: bundleID)

        case .failed(let error):
            let (justDied, shouldRetry, attempt): (Bool, Bool, Int) = stateQueue.sync {
                let justDied = self.deadBundleIDs.insert(bundleID).inserted
                guard self.routedBundleIDs.contains(bundleID),
                      case .processNotYetAudible = error
                else {
                    return (justDied, false, 0)
                }
                // Indefinite retry: as long as the route is still desired (guard
                // above), a paused app is re-probed forever. `retryCounts` is kept
                // ONLY to grow the backoff delay, never as a give-up ceiling — so a
                // routed app is never permanently marked dead for `.processNotYetAudible`.
                let attempt = (self.retryCounts[bundleID] ?? 0) + 1
                self.retryCounts[bundleID] = attempt
                return (justDied, true, attempt)
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
            for (deviceID, bound) in self.streamBindings where bound == streamU {
                if let outputID = self.outputIDs[deviceID] {
                    // Fresh reset → bump the generation (supersedes + cancels any
                    // in-flight recovery for this device) and start attempt 1.
                    let gen = (self.rebindRecoveryGen[deviceID] ?? 0) + 1
                    self.rebindRecoveryGen[deviceID] = gen
                    self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
                    AudioDiag.log("RESET AirPlay session: device=\(deviceID) stream=\(stream) (tap rebuilt)")
                    self.emit(.streamHealth(id: deviceID, recovering: true))
                    // T4: the trigger + generation bump for the rebind-recovery
                    // chain `enqueueRebindRecovery` is about to start (attempt 1)
                    // for this device. `scope` is the routed app whose per-app tap
                    // rebuild caused this — the one fact the attempt trail below
                    // can't otherwise carry. Non-blocking, same critical section as
                    // the `AudioDiag.log` call directly above it.
                    Telemetry.log(.airplay, "session_reset", [
                        "device": deviceID,
                        "scope": bundleID,
                        "stream": "\(stream)",
                        "gen": "\(gen)",
                        "trigger": "recapture",
                    ])
                    self.enqueueRebindRecovery(
                        deviceID: deviceID, outputID: outputID, scope: .perApp(stream: streamU),
                        gen: gen, attempt: 1)
                }
            }
        }
    }

    /// Reset the WHOLE-SYSTEM (stream-0) AirPlay RTP session for every currently
    /// streaming Selected Device by rebinding it (removeOutput → addOutput = a fresh
    /// RTSP/RTP session with a clean timeline anchor) — the stream-0 analogue of
    /// `resetAirPlaySessionForRoutedApp` (T2). Called when the whole-system tap was
    /// rebuilt (a nominal-sample-rate renegotiation), which leaves every receiver on
    /// the whole-system mix desynced and permanently silent even though real PCM
    /// keeps flowing. Iterates `added` (the devices actually streaming stream 0),
    /// not `expectedSelected`/`desiredOn` — only a device with a live engine session
    /// has a session to reset. Runs on `stateQueue`.
    ///
    /// Single-flight: bumps each device's `rebindRecoveryGen` (shared per-deviceID
    /// with the per-app path — a device is either whole-system or per-app, never
    /// both, so one recovery chain per device is exactly right) and cancels any
    /// pending backoff before enqueuing attempt 1. A rapid rate bounce
    /// (44.1→48→44.1) fires this again; the second bump supersedes the first
    /// chain's bookkeeping, so recovery never thrashes.
    private func resetAirPlaySessionForWholeSystem() {
        stateQueue.sync {
            for deviceID in self.added {
                guard let outputID = self.outputIDs[deviceID] else { continue }
                // Finding 1: claim the SAME `converging` slot `convergeDevice`
                // claims for a user-driven select/deselect (see `setOutputSet`'s
                // `!self.converging.contains(id)` gate) so the recovery's
                // removeOutput→addOutput can never interleave with a concurrent
                // convergeDevice op for this device — the two used to be
                // independent serialization domains touching the same OutputID,
                // which could leave the engine streaming a device the backend
                // had already deselected (or silent on a device just selected).
                // If a real convergeDevice is already running for this device,
                // bow out: that loop owns the engine ops right now and will
                // settle the device into whatever state is currently desired —
                // the next topology change re-binds/re-syncs it idempotently.
                guard !self.converging.contains(deviceID) else {
                    AudioDiag.log(
                        "SKIP whole-system rebind: device=\(deviceID) already converging")
                    continue
                }
                self.converging.insert(deviceID)
                let gen = (self.rebindRecoveryGen[deviceID] ?? 0) + 1
                self.rebindRecoveryGen[deviceID] = gen
                self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
                AudioDiag.log("RESET AirPlay session (whole-system): device=\(deviceID) stream=0 (tap rebuilt)")
                self.emit(.streamHealth(id: deviceID, recovering: true))
                self.enqueueRebindRecovery(
                    deviceID: deviceID, outputID: outputID, scope: .wholeSystem,
                    gen: gen, attempt: 1)
            }
        }
    }

    /// Which AirPlay session a rebind-recovery chain is restoring (T2/T4). Both
    /// kinds share `rebindRecoveryGen`/`pendingRebindRecoveries` (keyed by deviceID,
    /// so one device never runs two chains at once) but differ in the engine op they
    /// issue and the "do we still own this device?" ownership check they use to bow
    /// out the moment the device is de-routed/deselected.
    private enum RebindScope: Equatable {
        /// A per-app redirect's dedicated stream (≥ 1). Ownership:
        /// `streamBindings[deviceID] == stream`. Re-added via `addOutput(_:streamId:)`.
        case perApp(stream: UInt32)
        /// The whole-system "Selected Devices" output set (stream 0). Ownership:
        /// `added.contains(deviceID)`. Re-added via the single-stream `addOutput(_:)`
        /// — the exact op `convergeDevice` used to bind it.
        case wholeSystem
    }

    /// Whether `deviceID` still owns the session `scope` describes — the guard both
    /// the completion handler and the backoff re-check use to bow out the moment a
    /// device is de-routed (per-app) or deselected (whole-system). Must hold
    /// `stateQueue`.
    private func stillOwnsRebind(deviceID: String, scope: RebindScope) -> Bool {
        switch scope {
        case .perApp(let stream): return self.streamBindings[deviceID] == stream
        case .wholeSystem:        return self.added.contains(deviceID)
        }
    }

    /// A short label for `scope` used in the recovery diagnostics.
    private static func rebindScopeLabel(_ scope: RebindScope) -> String {
        switch scope {
        case .perApp(let stream): return "stream=\(stream)"
        case .wholeSystem:        return "stream=0 (whole-system)"
        }
    }

    /// Perform ONE rebind (removeOutput → addOutput) for a routed device's AirPlay
    /// session and — UNLIKE the fire-and-forget `enqueueBindOps` — OBSERVE whether
    /// the engine's `addOutput` threw (T4). Chains onto `bindTail` so it stays
    /// serialized against every other per-device engine op (a topology change's
    /// bind/rebind/unbind for the same device never overlaps this). On failure it
    /// reschedules with a small capped-doubling backoff up to
    /// `maxRebindRecoveryAttempts`, then gives up LOUDLY (`AudioDiag.log`) and
    /// leaves the device unbound-in-engine — a receiver that keeps refusing the
    /// rebind is genuinely gone, and infinite removeOutput/addOutput would thrash a
    /// real device; the next topology change re-binds it idempotently anyway.
    ///
    /// Single-flighted per device via `rebindRecoveryGen`: a newer reset bumps the
    /// gen, so this chain — checking its captured `gen` still matches on completion
    /// — bows out the moment it is superseded, or the device stops owning the
    /// session `scope` describes (per-app: `streamBindings[deviceID] != stream`;
    /// whole-system: `!added.contains(deviceID)`, i.e. deselected). Called on
    /// `stateQueue` (the async body hops back onto `stateQueue` only for the
    /// bookkeeping mutation, never holding it across the engine op).
    private func enqueueRebindRecovery(
        deviceID: String, outputID: OutputID, scope: RebindScope, gen: Int, attempt: Int
    ) {   // on stateQueue
        // T4: every call into this function — attempt 1 from
        // `resetAirPlaySessionForRoutedApp`, or a later attempt recursing from the
        // backoff `DispatchWorkItem` below — traces back to a tap-rebuild
        // recapture (the only call site today, so `trigger` is hardcoded rather
        // than threaded as a parameter — keeps this purely additive). Both call
        // sites already hold `stateQueue` (see their own `// on stateQueue`
        // markers), so this is just a format + non-blocking hand-off, same as the
        // `AudioDiag.log` calls already in this chain — no new locking, no new
        // await, no reordering of what follows.
        Telemetry.log(.airplay, "rebind", [
            "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt)",
            "trigger": "recapture", "outcome": "scheduled",
        ])
        let prev = self.bindTail
        self.bindTail = Task { [weak self] in
            await prev.value
            guard let self else { return }
            let ok = await self.performRebindRecovery(outputID: outputID, scope: scope)
            // Finding 1: for whole-system scope, every TERMINAL exit of this chain
            // (bailed-because-superseded/deselected, succeeded, or gave-up) must
            // release the `converging` slot claimed in
            // `resetAirPlaySessionForWholeSystem` — and, mirroring
            // `convergeDevice`'s own defer, immediately re-kick a real
            // `convergeDevice` if the desired state moved while the slot was
            // held (e.g. the user re-selected/deselected mid-recovery). The
            // in-flight backoff-retry path deliberately does NOT release the
            // slot — the recovery chain is still in progress, and releasing
            // early would let a concurrent convergeDevice op interleave with
            // the next attempt's removeOutput/addOutput, reopening the race.
            let requeue: OutputID? = self.stateQueue.sync {
                // Superseded by a newer reset, or the device stopped owning this
                // session (per-app unbind/teardown cleared the binding, or a
                // whole-system deselect dropped it from `added`): we no longer own it.
                guard self.rebindRecoveryGen[deviceID] == gen,
                      self.stillOwnsRebind(deviceID: deviceID, scope: scope) else {
                    // T4: which guard failed — a newer reset already bumped (or an
                    // unbind/deselect cleared) `gen`, or ownership of this device's
                    // session moved elsewhere (a topology change, or — for
                    // whole-system scope — a concurrent convergeDevice claimed it).
                    // Read-only over state already under this `stateQueue.sync`; no
                    // extra locking.
                    let reason = self.rebindRecoveryGen[deviceID] != gen ? "gen_superseded" : "ownership_changed"
                    Telemetry.log(.airplay, "rebind", [
                        "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt)",
                        "trigger": "recapture", "outcome": "superseded", "reason": reason,
                    ])
                    if case .wholeSystem = scope {
                        return self.releaseConvergingAndRequeueIfNeeded(id: deviceID)
                    }
                    return nil
                }
                let label = Self.rebindScopeLabel(scope)
                if ok {
                    Telemetry.log(.airplay, "rebind", [
                        "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt)",
                        "trigger": "recapture", "outcome": "succeeded",
                    ])
                    self.rebindRecoveryGen.removeValue(forKey: deviceID)
                    self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
                    self.emit(.streamHealth(id: deviceID, recovering: false))
                    if case .wholeSystem = scope {
                        return self.releaseConvergingAndRequeueIfNeeded(id: deviceID)
                    }
                    return nil
                }
                guard attempt < self.maxRebindRecoveryAttempts else {
                    Telemetry.log(.airplay, "rebind", [
                        "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt)",
                        "trigger": "recapture", "outcome": "gave_up",
                    ])
                    AudioDiag.log(
                        "RESET AirPlay session GAVE UP after \(attempt) attempts: "
                        + "device=\(deviceID) \(label) — receiver likely gone; "
                        + "left unbound-in-engine (re-binds on next topology change)")
                    self.rebindRecoveryGen.removeValue(forKey: deviceID)
                    self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
                    if case .wholeSystem = scope {
                        return self.releaseConvergingAndRequeueIfNeeded(id: deviceID)
                    }
                    return nil
                }
                let delay = self.rebindRecoveryRetryDelay * pow(2.0, Double(attempt - 1))
                // T4: an explicit 5th outcome beyond the task's four named ones
                // (scheduled/succeeded/gave-up/superseded) — this attempt failed
                // but hasn't hit the ceiling, so a backed-off retry is queued.
                // Without it the trail would jump straight from this attempt's
                // `scheduled` line to the next attempt's, with no record that this
                // one failed or why the next is delayed.
                Telemetry.log(.airplay, "rebind", [
                    "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt)",
                    "trigger": "recapture", "outcome": "retry_scheduled",
                    "delayMs": "\(Int(delay * 1000))",
                ])
                AudioDiag.log(
                    "RESET AirPlay session retry \(attempt + 1)/\(self.maxRebindRecoveryAttempts) "
                    + "in \(delay)s: device=\(deviceID) \(label)")
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.stateQueue.sync {
                        // Re-check under the lock: still the same generation, still
                        // owns this session, device still discovered.
                        guard self.rebindRecoveryGen[deviceID] == gen,
                              self.stillOwnsRebind(deviceID: deviceID, scope: scope),
                              let out = self.outputIDs[deviceID] else {
                            // T4: the backed-off retry for `attempt + 1` never got
                            // to run — state moved on while it was waiting out the
                            // delay. Without this line the trail goes silent after
                            // `retry_scheduled` with no explanation.
                            Telemetry.log(.airplay, "rebind", [
                                "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt + 1)",
                                "trigger": "recapture", "outcome": "superseded",
                                "reason": "state_changed_before_retry_fired",
                            ])
                            return
                        }
                        self.enqueueRebindRecovery(
                            deviceID: deviceID, outputID: out, scope: scope,
                            gen: gen, attempt: attempt + 1)
                    }
                }
                self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
                self.pendingRebindRecoveries[deviceID] = work
                DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
                return nil // still in progress — keep the `converging` slot held
            }
            if let requeue {
                Task { [weak self] in await self?.convergeDevice(id: deviceID, outputID: requeue) }
            }
        }
    }

    /// The observable rebind: stop the device's session then re-add it on the stream
    /// `scope` selects, returning whether the re-add SUCCEEDED (T4). The
    /// `removeOutput` throw is tolerated (the device may not currently be added — a
    /// no-op teardown is fine); only the `addOutput` result determines success, since
    /// that is what actually re-establishes the RTP session with a clean timeline
    /// anchor. Whole-system uses the single-stream `addOutput(_:)` (stream 0, the
    /// exact op `convergeDevice` used); per-app uses `addOutput(_:streamId:)`.
    private func performRebindRecovery(outputID: OutputID, scope: RebindScope) async -> Bool {
        let label = Self.rebindScopeLabel(scope)
        AudioDiag.log("engine REBIND(recover) output=\(outputID) \(label)")
        try? await engine.removeOutput(outputID)
        do {
            switch scope {
            case .perApp(let stream): try await engine.addOutput(outputID, streamId: stream)
            case .wholeSystem:        try await engine.addOutput(outputID)
            }
            return true
        } catch {
            AudioDiag.log(
                "engine REBIND(recover) FAILED output=\(outputID) \(label): \(error)")
            return false
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

    /// Schedule the next `.processNotYetAudible` retry with capped-exponential
    /// backoff (T8, edge case 3) — self-heals a route made just before the app
    /// started playing audio, and keeps re-probing an app that stays paused,
    /// without the user touching the UI again. The delay is
    /// `retryDelay × 2^(attempt-1)`, capped at `processNotYetAudibleMaxBackoff`
    /// (e.g. 2 → 4 → 8 → 10 → 10 … forever). Single-flighted: replaces any retry
    /// already pending for this bundle ID (so N `.failed` events never stack N
    /// timers). Best-effort (D4): if the route is gone by the time the timer fires,
    /// `perAppCapture.start` fails fast (`.appNotRunning` or similar) and the
    /// failure handler above declines to reschedule (route no longer in
    /// `routedBundleIDs`).
    private func scheduleProcessNotYetAudibleRetry(bundleID: String, attempt: Int) {
        let delay = min(
            processNotYetAudibleRetryDelay * pow(2.0, Double(attempt - 1)),
            processNotYetAudibleMaxBackoff)
        let work = DispatchWorkItem { [weak self] in
            self?.perAppCapture.start(bundleID: bundleID)
        }
        stateQueue.sync {
            self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
            self.pendingRetries[bundleID] = work
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + delay, execute: work)
    }

    /// Forward an app-quit notification from the AppKit boundary (T8, edge case 1:
    /// a routed app's process quits mid-stream). `AppDelegate` observes
    /// `NSWorkspace.didTerminateApplicationNotification` and calls this with the
    /// terminated app's bundle ID — Core can't observe AppKit notifications itself,
    /// mirroring the `processResolver` injection.
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
    /// `handleAppTerminated` / `processResolver` injection pattern.
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
        // R14: refresh the whole-system tap's exclusion pids for this bundle ID
        // unconditionally, BEFORE the routed-only early-return below — this is
        // what fixes an EXCLUDED (not routed) app relaunching and leaking back
        // into the system mix, since that case has no route to restart and
        // would otherwise hit `guard hasRoute else { return }` and never touch
        // capture at all. Also covers the ROUTED-app-relaunch half of R14
        // (avoids doubling into the system mix): a `.device`-routed bundle ID
        // is unioned into the same `currentExcludedBundleIDs` set inside
        // `NativeCaptureCoordinator`, so one call handles both cases. The
        // coordinator itself no-ops unless `bundleID` is actually in that set,
        // so this is cheap to call for every app launch, routed or not.
        captureCoordinator?.refreshExcludedProcessSet(forRelaunchedBundleID: bundleID)

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
    /// (`.rebind`) — ahh has accepted the brief (~1 s) audible gap, so there is no
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
            // T4b defensive guard: AirPlay-1 (RAOP) devices are never offered as a
            // per-app routing target in the UI (`supportsAirPlay2 == false` is
            // filtered out of `PopoverController.availableAirPlayDestinations`),
            // but a stale/racing UI state could still hand one down here. Refuse it
            // rather than proceed into `.bind`/`.rebind` — a rebind on an AP1 device
            // re-anchors its clock (no shared timing protocol with AP2) and drifts
            // it out of sync with the rest of a group, and some classic receivers
            // briefly reject the RTSP reconnect. Skip silently (no-op): the device
            // just doesn't get a per-app stream, same as if it were never offered.
            let ap1DeviceIDs = Set(self.known.keys.filter { !(self.known[$0]?.supportsAirPlay2 ?? true) })
            var newBindings: [String: UInt32] = [:]
            for set in sets {
                let stream = UInt32(set.streamID)
                for deviceID in set.deviceIDs
                where self.outputIDs[deviceID] != nil && !ap1DeviceIDs.contains(deviceID) {
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
            var unboundDevices: [String] = []
            for (deviceID, _) in self.streamBindings where newBindings[deviceID] == nil {
                if let outputID = self.outputIDs[deviceID] { ops.append(.unbind(outputID)) }
                unboundDevices.append(deviceID)
                // T4: the device is leaving per-app routing — abandon any pending
                // rebind recovery for it. Bumping the gen also makes any in-flight
                // recovery chain bow out on completion (its captured gen no longer
                // matches), and the unbind op below tears the session down anyway.
                self.rebindRecoveryGen.removeValue(forKey: deviceID)
                self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
            }
            self.streamBindings = newBindings
            self.enqueueBindOps(ops)
            // T3: a device that just lost its per-app stream gets a final combined
            // `.level` (now with a zero stream contribution, so its meter drops to
            // its system contribution — 0 if unselected) so a torn-down stream can't
            // leave a stuck bar. Unconditional (not metering-gated): this is a
            // one-shot CLEAR, exactly what prevents a stale value surviving into a
            // reopened popover.
            for deviceID in unboundDevices { self.emitCombinedLevel(forDevice: deviceID) }
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
    /// Release the `converging` slot for `id` and, if the coalesced target moved
    /// while the slot was held (a toggle — or a whole-system rebind recovery,
    /// below — landed mid-op), reclaim the slot and return the output id to kick
    /// a fresh `convergeDevice` loop for. Shared by `convergeDevice`'s own defer
    /// AND `enqueueRebindRecovery`'s whole-system completion (Finding 1): both
    /// hold `converging` as the single serialization domain for a device's
    /// engine ops, so both release through the same requeue check. Must run on
    /// `stateQueue`.
    private func releaseConvergingAndRequeueIfNeeded(id: String) -> OutputID? {
        self.converging.remove(id)
        guard !self.failedGate.contains(id),
              let want = self.desiredOn[id],
              let out = self.outputIDs[id],
              want != self.added.contains(id) else { return nil }
        self.converging.insert(id)
        return out
    }

    private func convergeDevice(id: String, outputID: OutputID) async {
        defer {
            // Release the in-flight slot. If the target moved again while we were
            // settling (e.g. a flip arrived after our last op but the slot was still
            // held), re-kick so we chase it — the release + re-check is atomic under
            // stateQueue so a concurrent setOutputSet can't slip a kick past us.
            let requeue: OutputID? = stateQueue.sync {
                self.releaseConvergingAndRequeueIfNeeded(id: id)
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
                    // Connect-latency diagnosis (temporary — see AudioDiag): brackets
                    // the real RTSP/negotiate handshake `addOutput` awaits (device_start
                    // through the STREAMING completion) — the gap between these two
                    // lines is the AirPlay receiver's own negotiation time, not
                    // anything this app controls.
                    AudioDiag.log("CONNECT addOutput starting device=\(id) output=\(outputID)")
                    try await engine.addOutput(outputID)
                    AudioDiag.log("CONNECT addOutput RESOLVED (streaming) device=\(id) output=\(outputID)")
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
                        // AUDIBLE immediately AND at a safe, moderate level (not the
                        // Mac's possibly-loud system volume — G1-N1): the engine's
                        // volume field is 0 until an explicit setVolume, and 0 maps to
                        // ≈ −30 dB (silent) — the −30 dB trap, see `connectVolumeSeed`.
                        // Suppressed for an
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
                        let seededVolume = wasAdded ? nil : self.connectVolumeSeed(id, outputID: outputID)
                        self.applyLocal(id) {
                            $0.isSelected = true; $0.isAvailable = true
                            if let seededVolume { $0.volume = seededVolume }
                        }
                        // Engine confirmed the add — connecting → connected. (An
                        // interim out-of-band `.failed` already returned above and
                        // left connectionState `.failed` via `applyEngineState`.) The
                        // `→ .connected` transition drives `reconcileSilenceWatchdog`
                        // (hooked in `setConnectionState`), which disarms/clears any
                        // silence fallback for this genuine reconnect.
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
                        // Finding 2: the device is leaving the whole-system output
                        // set — abandon any pending whole-system rebind recovery for
                        // it, mirroring the per-app precedent (`updateRoutedSets`'s
                        // unbind path above). Not load-bearing on its own (a surviving
                        // retry re-checks `stillOwnsRebind`/`added.contains(id)` and
                        // bows out), but keeps the bookkeeping symmetric and avoids a
                        // dangling scheduled retry outliving the deselect.
                        self.rebindRecoveryGen.removeValue(forKey: id)
                        self.pendingRebindRecoveries.removeValue(forKey: id)?.cancel()
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
    // (passthrough). Because `isLocalDevice == true` (and it has no `outputIDs`
    // entry) it can never be desired-on in `setOutputSet` (which skips the local
    // id) and it is never fed to `engine.updateDiscovery` (only discovery events
    // feed the engine), so it is structurally impossible for the local device to
    // reach the engine. (`supportsAirPlay2 == false` no longer does this work —
    // AP1 receivers share that flag but ARE engine-driven.)

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

    /// Whether the macOS SYSTEM default output device
    /// (`kAudioHardwarePropertyDefaultOutputDevice`) is itself AirPlay-class
    /// (`kAudioDeviceTransportTypeAirPlay`) — i.e. the user pointed the Mac's OWN
    /// Sound output at an AirPlay receiver (Sound menu / System Settings),
    /// independently of this app's Selected Devices (W3-T3, PLAN-RELIABILITY.md
    /// Wave 3 "System-AirPlay guard"). The production default for
    /// ``systemDefaultOutputIsAirPlayClassProvider`` — combined with
    /// `captureRunning` in ``reconcileSystemAirPlayGuard()``, this is the
    /// double-path/echo condition that bullet calls out.
    ///
    /// Same two-step HAL read ``currentOutputDeviceName(fallback:)`` uses
    /// (resolve the default device, then read one property on it) — reused
    /// deliberately rather than re-derived, so there is exactly one place that
    /// resolves "the current default output device". Falls back to `false` on
    /// any query failure: an unreadable transport type is not evidence of a
    /// conflict.
    static func currentDefaultOutputIsAirPlayClass() -> Bool {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let devErr = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil, &size, &deviceID)
        guard devErr == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return false }

        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transportType: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        let transportErr = AudioObjectGetPropertyData(
            deviceID, &transportAddr, 0, nil, &transportSize, &transportType)
        guard transportErr == noErr else { return false }
        return transportType == kAudioDeviceTransportTypeAirPlay
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
            // it) does NOT reseed their volume from the connect default. This is
            // a buffer-size change, not a user reconnect: each device's in-session
            // level must survive, and the explicit re-push at the end of this method
            // restores it. Without this guard, `connectVolumeSeed` would slam every
            // running device back to the connect default on a plain buffer change.
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
                return (item.outputID, self.engineVolume(forID: item.id, uiVolume: effective))
            }
        }
        for (outputID, value) in toPush {
            try? await engine.setVolume(outputID, value)
        }

        // The apply has fully settled — teardown, buffer set, re-add, and the
        // in-session volume re-push above have all run. Lift the seed suppression so
        // any subsequent REAL (re)connect reseeds from the connect default as usual.
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

    /// Test-only (`@testable`): whether the silence watchdog has un-gated capture
    /// (the Mac is audible as a fallback because zero desired devices are connected).
    var test_silenceFallbackActive: Bool { stateQueue.sync { silenceCaptureOverride } }

    /// Test-only (`@testable`): whether a silence-watchdog countdown is currently
    /// armed (awaiting either a reconnect or its own fire).
    var test_silenceWatchdogArmed: Bool { stateQueue.sync { silenceWatchdog != nil } }

    /// Test-only (`@testable`): whether the system-AirPlay double-path/echo note
    /// (W3-T3) is currently active.
    var test_systemAirPlayGuardActive: Bool { stateQueue.sync { systemAirPlayGuardActive } }

    /// Test-only (`@testable`): whether any per-device converge is still in flight —
    /// lets a Fix A test wait until a connect has fully released its `converging`
    /// slot before firing the whole-system tap-recreate reset (which skips a device
    /// still mid-converge, since that device's own fresh add re-anchors it).
    var test_isConverging: Bool { stateQueue.sync { !converging.isEmpty } }

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
            // Abandon any in-flight silence-watchdog bookkeeping from a prior cycle:
            // sleep re-decides everything on wake, and `suspended` already forces the
            // gate off, so a fallback override must not linger across the sleep.
            self.silenceWatchdog?.cancel()
            self.silenceWatchdog = nil
            self.awaitingWakeReconnect = false          // Fix C: sleep ends any post-wake window
            self.clearSilenceOverride()                 // Fix B: emit the banner-clear on true→false
            // Stop the whole-system tap (ordered on `captureControlQueue`, like every
            // other gate decision) so the Mac isn't left muted by a tap streaming into
            // dead sockets. `expectedSelected` is untouched.
            self.captureRunning = false
            // W3-T3: capture just stopped (above) — clear the double-path guard note on
            // the true→false edge, exactly as `stop()` does. Sleep hits neither
            // `reconcileSystemAirPlayGuard`'s else-branch nor `stop()`, so without this
            // the note would strand ON while nothing streams (a UI-truth lie) whenever a
            // narrow wake-with-selection-gone sequence leaves `reconcileCaptureGate` an
            // early-return. Idempotent (no-op/no-emit unless actually active), mirroring
            // the `clearSilenceOverride()` above.
            self.clearSystemAirPlayGuard()
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

    /// System woke: re-converge every still-desired device (intent survived sleep).
    /// A wake reconnect is a genuine reconnect, so `convergeDevice`'s add path
    /// reseeds the volume as documented (the `added` false→true edge). The fallback
    /// watchdog is no longer armed here directly — `reconcileSilenceWatchdog()` (run
    /// as part of re-deciding the capture gate below) arms it because, post-wake,
    /// every desired device is `.connecting` and none is yet `.connected`.
    public func handleSystemDidWake() {
        let toKick: [(id: String, outputID: OutputID)] = stateQueue.sync {
            guard self.started, self.suspended else { return [] }
            self.suspended = false
            self.clearSilenceOverride()                 // Fix B: emit the banner-clear on true→false
            // Fix C: entering the post-wake reconnection window. A stranding evaluated
            // below (every desired device is `.connecting`, none yet `.connected`)
            // therefore arms with the user's wakeAudioRestoreDelay preference; the
            // reconcile's not-stranded branch clears this flag the instant one
            // reconnects (or if there was nothing to reconnect at all).
            self.awaitingWakeReconnect = true

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
            // streaming selection is still in force), then re-evaluate the silence
            // watchdog: with a streaming selection and nothing yet `.connected`, this
            // arms the same countdown the wake path used to arm by hand.
            self.reconcileCaptureGate()
            // R11: the generalized silence watchdog subsumes the old wake-specific
            // watchdog. `awaitingWakeReconnect` was set above; this reconcile arms the
            // countdown with the user's `wakeAudioRestoreDelay` while awaiting a
            // reconnect and clears the flag the instant one reconnects (or if there was
            // nothing to reconnect at all).
            self.reconcileSilenceWatchdog()

            // T4: log the wake re-converge — which still-desired devices are being
            // re-kicked. Only reached past the guard above (a real, in-force
            // suspension being lifted), so this never fires for a stray/duplicate
            // wake notification with nothing to re-converge. Non-blocking, added
            // after every decision above with no reordering.
            Telemetry.log(.airplay, "wake_reconverge", [
                "desiredOn": Self.telemetryDeviceList(Set(desiredIDs), known: self.known),
                "kicked": Self.telemetryDeviceList(Set(kicks.map(\.0)), known: self.known),
            ])
            return kicks
        }
        for (id, outputID) in toKick {
            Task { [weak self] in await self?.convergeDevice(id: id, outputID: outputID) }
        }
        // Discovery nudge: a receiver that changed address / dropped during sleep
        // needs re-resolving. `NativeDiscovery` has no explicit refresh seam today
        // (sibling task B9 makes discovery self-healing) — noted, not forced here.
    }

    // MARK: Generalized silence watchdog (Wave 2 W2-T2, closes R11)

    /// The single evaluation point for the silence fallback, driven from every path
    /// that can change "is any desired device audible": connection-state transitions
    /// (`setConnectionState`), out-of-band engine transitions (`applyEngineState`),
    /// intent changes (`setOutputSet`), and wake (`handleSystemDidWake`). It is the
    /// generalization of the old wake-only `noteWakeReconnect`/`armWakeWatchdog` pair
    /// into one path-agnostic reconcile.
    ///
    /// The condition is "stranded": the capture gate WANTS to stream (at least one
    /// non-local device is in `expectedSelected`) yet ZERO of those desired non-local
    /// devices are `.connected` — and we're not suspended for sleep. Note the
    /// deliberate "zero connected" test, not "any unavailable": a partly-connected
    /// selection is still audible, so it never trips the watchdog.
    ///
    /// - Stranded and not already fallen back → arm the countdown once (a repeat
    ///   stranded evaluation while armed leaves the running countdown alone, so a
    ///   burst of transitions can't keep resetting it).
    /// - Not stranded (a desired device is `.connected`, the intent cleared, or
    ///   we're suspended) → cancel any countdown and, if we had fallen back, clear
    ///   the override, re-engage the capture gate (audio moves back to the device,
    ///   Mac re-mutes) and clear the banner.
    ///
    /// On `stateQueue`.
    private func reconcileSilenceWatchdog() {   // on stateQueue
        let desiredNonLocal = expectedSelected.filter { known[$0]?.isLocalDevice == false }
        let wantsStream = !desiredNonLocal.isEmpty
        let anyConnected = desiredNonLocal.contains { connectionState(of: $0) == .connected }
        let stranded = !suspended && wantsStream && !anyConnected

        if stranded {
            if silenceCaptureOverride { return }        // already audible on this Mac
            if silenceWatchdog == nil { armSilenceWatchdog() }
        } else {
            silenceWatchdog?.cancel()
            silenceWatchdog = nil
            // Fix C: a desired device connected, the intent cleared, or we're
            // suspended — whichever, the post-wake reconnection window is over, so a
            // LATER stranding falls back on the always-on delay, not the wake pref.
            awaitingWakeReconnect = false
            if silenceCaptureOverride {
                // Fix B: clear + emit the banner-clear BEFORE re-reconciling the gate
                // (`reconcileCaptureGate` reads `silenceCaptureOverride`, so it must
                // already be false for the gate to re-engage).
                clearSilenceOverride()
                reconcileCaptureGate()                  // re-mute; stream resumes to device
            }
        }
    }

    /// Fix B: clear the silence-fallback override on a genuine true→false edge and
    /// announce `.localFallbackActive(false)` so the popover retracts its "playing on
    /// this Mac" banner. EVERY path that ends the fallback — reconcile, `stop`, sleep,
    /// wake — routes the clear through here instead of a bare `silenceCaptureOverride
    /// = false`, so the banner can never strand ON (invariant 4: the UI never lies).
    /// Idempotent: a no-op with no emit when the override was already false, so it
    /// never fires a spurious clear. Returns whether it actually cleared. On
    /// `stateQueue`.
    @discardableResult
    private func clearSilenceOverride() -> Bool {   // on stateQueue
        guard silenceCaptureOverride else { return false }
        silenceCaptureOverride = false
        emit(.localFallbackActive(false))
        return true
    }

    /// Arm the silence-watchdog countdown on `stateQueue`. Fix C: the delay is the
    /// user's ``wakeAudioRestoreDelay`` preference ONLY while awaiting a post-wake
    /// reconnect (``awaitingWakeReconnect``), and otherwise the always-on
    /// ``silenceFallbackDelay`` — so a dead-group / stranded condition during normal
    /// operation always falls back within seconds and can never be disabled by a
    /// "Never" wake-restore setting (R11). A `nil`/non-positive wake delay in the
    /// post-wake window still arms nothing ("Never" defers un-muting after a sleep,
    /// exactly as before). The scheduled body hops back onto `stateQueue` so it stays
    /// serialized with every other state mutation. On `stateQueue`.
    private func armSilenceWatchdog() {   // on stateQueue
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
        let chosen: TimeInterval? = awaitingWakeReconnect ? wakeAudioRestoreDelay : silenceFallbackDelay
        guard let delay = chosen, delay > 0 else { return }
        silenceWatchdog = watchdogScheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.stateQueue.async { self.fireSilenceWatchdog() }
        }
    }

    /// The countdown elapsed with no desired device `.connected`: un-gate capture so
    /// the Mac becomes audible, leaving the selection intent intact, and announce the
    /// fallback so the popover shows its banner. A later reconnect / intent clear
    /// re-engages the gate (`reconcileSilenceWatchdog`). The condition is re-checked
    /// here because state may have changed between arming and firing (a cancelled but
    /// already-dispatched fire, or a reconnect that raced this), so a late fire is
    /// inert. On `stateQueue`.
    private func fireSilenceWatchdog() {   // on stateQueue (hopped here by the scheduler body)
        guard silenceWatchdog != nil else { return }   // cancelled but already dispatched
        silenceWatchdog = nil
        // Fix C: the restore decision has been made — the post-wake window is over.
        awaitingWakeReconnect = false
        let desiredNonLocal = expectedSelected.filter { known[$0]?.isLocalDevice == false }
        let anyConnected = desiredNonLocal.contains { connectionState(of: $0) == .connected }
        guard !suspended, !desiredNonLocal.isEmpty, !anyConnected else { return }
        silenceCaptureOverride = true
        reconcileCaptureGate()                          // un-gate → Mac becomes audible
        emit(.localFallbackActive(true))
    }

    // MARK: System-AirPlay guard (Wave 3 W3-T3, PLAN-RELIABILITY.md)
    //
    // "If the user sets an AirPlay device as the *system* default output while we
    // stream, surface a note (double-path audio / echo risk) rather than silently
    // capturing an AirPlay-bound mix." Purely informational — this never touches
    // the capture gate or any audio path, unlike the silence watchdog above.

    /// Re-evaluate the double-path/echo note. Active exactly when BOTH hold:
    /// `captureRunning` (the whole-system capture tap is actually running — we're
    /// streaming a captured mix to at least one AirPlay device) AND the macOS
    /// SYSTEM default output is ALSO AirPlay-class
    /// (``systemDefaultOutputIsAirPlayClassProvider``). Neither alone is a
    /// conflict: not streaming means there's nothing to double up, and a
    /// non-AirPlay system default means there's only one path.
    ///
    /// Mirrors ``reconcileSilenceWatchdog()``'s edge-triggered emit — a repeat
    /// evaluation at unchanged state is a no-op, so a burst of unrelated
    /// `reconcileCaptureGate()` calls can't storm the event stream. Call sites:
    /// the end of `reconcileCaptureGate()` (streaming started/stopped) and the
    /// `systemVolume.onExternalChange` handler's `defaultDeviceChanged` branch
    /// (the system default output itself switched). On `stateQueue`.
    private func reconcileSystemAirPlayGuard() {   // on stateQueue
        let active = captureRunning && systemDefaultOutputIsAirPlayClassProvider()
        if active {
            guard !systemAirPlayGuardActive else { return }
            systemAirPlayGuardActive = true
            emit(.systemDefaultIsAirPlayActive(true))
        } else {
            clearSystemAirPlayGuard()
        }
    }

    /// Clear the guard on a genuine true→false edge, mirroring Fix B's
    /// ``clearSilenceOverride()`` (invariant 4): every path that can end the
    /// condition — a normal reconcile, `stop()` — routes through here rather than
    /// a bare `= false`, so `.systemDefaultIsAirPlayActive(false)` is emitted
    /// exactly once per genuine edge and the popover note can never strand ON.
    /// Idempotent: a no-op with no emit when already false. On `stateQueue`.
    @discardableResult
    private func clearSystemAirPlayGuard() -> Bool {   // on stateQueue
        guard systemAirPlayGuardActive else { return false }
        systemAirPlayGuardActive = false
        emit(.systemDefaultIsAirPlayActive(false))
        return true
    }

    // MARK: Discovery → app model (all on stateQueue)

    private func handleDiscovery(_ event: DiscoveryEvent) {
        switch event {
        case .appeared(let discovered):
            feedEngineIfAvailable(discovered, appearing: true)
            stateQueue.async { self.addOrUpdate(discovered) }
        case .updated(let discovered):
            if discovered.isAvailable {
                feedEngineIfAvailable(discovered, appearing: true)
            } else {
                // A reachable→unreachable transition (AP1 or AP2). In practice this
                // is a sticky-AP2 device going OFFLINE: it lost its `_airplay._tcp`
                // advert while its `_raop._tcp` record lingers — a real AP2 receiver
                // powering off, NOT an AP1 downgrade. `supportsAirPlay2` STAYS true
                // so the UI shows an unavailable (retry-on-click) row, never an AP1
                // row. (A genuine AP1-only receiver reports `isAvailable == true`
                // until it truly disappears, so it does not reach here.)
                //
                // Either way it is NOT `.disappeared`, so the removal path below
                // never runs otherwise — tear down any live engine session and
                // deregister its descriptor so we don't leak a live RTSP/PTP
                // session. Safe/idempotent if it was never added.
                teardownEngineOutput(id: discovered.id)
                removeEngineDiscovery(id: discovered.id)
            }
            stateQueue.async { self.addOrUpdate(discovered) }
        case .disappeared(let id, _):
            // Every receiver we surface — AP1 or AP2 — is now engine-fed and can be
            // `addOutput`-ed, so tear down unconditionally on disappear. Both calls
            // are idempotent no-ops if the id was never added / never fed.
            teardownEngineOutput(id: id)
            removeEngineDiscovery(id: id)
            stateQueue.async { self.markDisappeared(id) }
        }
    }

    /// Stop and drop any live engine session for `id` (if it was streaming). Used
    /// when a receiver goes offline or disappears so it doesn't leak its RTSP/PTP
    /// session. Best-effort — a failed removeOutput is swallowed (the descriptor
    /// removal that follows deregisters it anyway).
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

    /// Feed a reachable receiver into the engine's discovery so it becomes
    /// `addOutput`-able. Both AP1 and AP2 receivers are fed — the shared engine
    /// drives them the same way; only a receiver that is not reachable right now
    /// (a sticky-AP2 device gone offline) is skipped.
    ///
    /// This is the DISCOVERY-driven feed (fires on genuine appear/update events,
    /// not per toggle). It records what it fed into `fedDescriptors` so the
    /// converge path's `descriptorToFeed` can skip a redundant re-feed of the exact
    /// same descriptor (root cause 2). Only feeds when the descriptor is new or
    /// changed, so a repeated identical `.updated` doesn't re-add either.
    private func feedEngineIfAvailable(_ discovered: DiscoveredDevice, appearing: Bool) {
        guard discovered.isAvailable else { return }
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
        // "Streamable right now" = currently reachable (AP1 or AP2 — both drive
        // through the shared engine). A sticky-AP2 device that went offline
        // (`supportsAirPlay2` true but `isAvailable` false) is NOT streamable right
        // now — treat it like the AP2-advert-gone case (drop the descriptor/fed-memo,
        // don't re-kick), but it KEEPS `supportsAirPlay2 == true` in the model (set
        // in `mapDiscovered`/`merge`) so the UI shows an unavailable/retry-on-click
        // row rather than losing its AP2 identity. A genuine AP1 receiver reports
        // `isAvailable == true`, so it IS streamable and its descriptor is kept.
        let streamableNow = discovered.isAvailable
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
            // First sighting: append + emit. mapDiscovered has already set the
            // availability/AP2 fields — an AP1 receiver comes in available and
            // engine-driveable, differing from AP2 only in `supportsAirPlay2`.
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
                // Recovery (root cause 4): a good transition clears any failure
                // park so the device is re-enableable / stays converged.
                self.failedGate.remove(id)
                // A (re)connect the engine reported out-of-band — e.g. an
                // auto-recovery it drove itself — never went through convergeDevice's
                // add path, so it too lands at engine volume 0 = ≈ −30 dB (silent).
                // Seed its starting volume here on a genuine new-add (`!wasAdded`)
                // from the configured connect default (G1-N1), not the system level.
                // Suppressed during an `applyStartBuffer` re-add so a buffer change
                // whose good-state event races this branch can't reset the level —
                // see `connectVolumeSeed`.
                if !wasAdded, let seededVolume = self.connectVolumeSeed(id, outputID: outputID) {
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
            // This out-of-band transition set `connectionState` DIRECTLY on the device
            // (bypassing `setConnectionState`), so drive the silence-watchdog reconcile
            // here too — a `→ .connected` re-engages the gate, a `→ .failed`/`.off`
            // arms the countdown. Runs after the commit so `known[id]` reflects the new
            // state the reconcile reads.
            self.reconcileSilenceWatchdog()
            return nil
        }
        if let rekick {
            Task { [weak self] in await self?.convergeDevice(id: rekick.id, outputID: rekick.outputID) }
        }
    }

    // MARK: Engine remote-control stream → media keys + slider (push, no poll)

    /// Subscribe the engine's remote-control stream (speaker transport keys + the
    /// speaker's own volume). Same start/stop-race discipline as
    /// ``subscribeStateStream()``: the task is stashed (or cancelled) on
    /// `stateQueue` so a start()→stop() can't leak a consumer against a torn-down
    /// backend.
    private func subscribeRemoteEventStream() {
        let stream = engine.makeRemoteEventStream()
        let task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.applyRemoteEvent(event)
            }
        }
        stateQueue.async {
            if self.started {
                self.remoteEventStreamTask = task
            } else {
                task.cancel()
            }
        }
    }

    /// Fold one remote-control event from a speaker into the app.
    private func applyRemoteEvent(_ event: RemoteEvent) {
        switch event {
        case .transport(let command):
            // Transport is global (one Mac media session), so it isn't tied to a
            // device: republish it as a backend event and let `AppDelegate` turn it
            // into a Mac media key (the same layering `systemVolumeChanged` uses).
            stateQueue.async { self.emit(.remoteTransport(command.backendCommand)) }
        case .volume(let outputID, let level):
            applyRemoteVolume(outputID: outputID, level: level)
        }
    }

    /// The speaker changed its OWN volume, as reported over the RTSP event channel
    /// (``RemoteEvent/volume(_:level:)``). Move that device's slider. On `stateQueue`.
    ///
    /// NOTE: in practice AirPlay 2 receivers report volume over DACP, not the event
    /// channel (see ``applyDacpVolume(activeRemote:level:)``), so this path is rarely
    /// exercised — kept so a receiver that DOES use the event channel still works.
    private func applyRemoteVolume(outputID: OutputID, level: Double) {
        stateQueue.async {
            guard let id = self.outputIDs.first(where: { $0.value == outputID })?.key else { return }
            self.setSpeakerVolume(id: id, outputID: outputID, level: level)
        }
    }

    /// The speaker changed its OWN volume, reported over **DACP** (the receiver
    /// called our ``DACPServer`` back — the real path for Sonos et al.). The
    /// `Active-Remote` token is the low 32 bits of the device id (`airplay.c`), so
    /// match it against the known outputs and move that one speaker's slider.
    /// Internal (not private) so the routing is unit-testable without a live socket.
    func applyDacpVolume(activeRemote: UInt32, level: Double) {
        stateQueue.async {
            guard let match = self.outputIDs.first(where: {
                UInt32(truncatingIfNeeded: $0.value.rawValue) == activeRemote
            }) else { return }
            self.setSpeakerVolume(id: match.key, outputID: match.value, level: level)
        }
    }

    /// Shared core for a speaker-initiated volume change (event channel or DACP).
    /// On `stateQueue`.
    ///
    /// A speaker-side control is a REQUEST, not a report: the sender owns AirPlay
    /// volume, so the speaker's audible level only actually moves once we write
    /// the requested value back out (SET_PARAMETER, via ``pushVolume``). The
    /// first live test proved the failure mode of NOT writing back: the Sonos's
    /// own baseline never advanced, so a full swipe on the speaker moved our
    /// slider a few points and every subsequent swipe restarted from the same
    /// stale level. So: move the slider AND push the level to the engine.
    ///
    /// The same-value guard is what keeps this loop-safe: a receiver reflecting
    /// our own write back arrives equal to `known` and dies here, and the
    /// −30…0 dB ↔ 0…100 map is linear both ways so a round-trip is
    /// rounding-stable. Swipe bursts are absorbed by ``pushVolume``'s
    /// in-flight coalescing (latest wins), never dropped.
    private func setSpeakerVolume(id: String, outputID: OutputID, level: Double) {   // on stateQueue
        let pct = Int((level * 100).rounded()).clampedToVolume
        if muted.contains(id) {
            // Don't un-mute from a knob turn; record the intended level so a later
            // unmute restores what the user dialed in on the speaker.
            stashedVolume[id] = pct
            return
        }
        guard pct != known[id]?.volume else { return }
        applyLocal(id) { $0.volume = pct }
        pushVolume(outputID, engineValue: Self.engineVolume(pct))
    }

    /// A relative `volumeup`/`volumedown` DACP verb from the speaker
    /// (`direction` is ±1): step from the level the app currently holds — that
    /// is what makes consecutive presses/swipe-ticks ACCUMULATE instead of
    /// re-basing on a stale value. Step size is a guess pending live-test
    /// calibration (Sonos observed sending absolute `setproperty` instead, so
    /// this is a safety net for receivers that use the relative verbs).
    /// Internal (not private) so the routing is unit-testable without a socket.
    func applyDacpVolumeStep(activeRemote: UInt32, direction: Int) {
        stateQueue.async {
            guard let match = self.outputIDs.first(where: {
                UInt32(truncatingIfNeeded: $0.value.rawValue) == activeRemote
            }) else { return }
            let id = match.key
            let current = self.muted.contains(id)
                ? (self.stashedVolume[id] ?? self.known[id]?.volume ?? 0)
                : (self.known[id]?.volume ?? 0)
            let target = current + direction.signum() * Self.speakerVolumeStep
            self.setSpeakerVolume(id: id, outputID: match.value,
                                  level: Double(target.clampedToVolume) / 100.0)
        }
    }

    /// UI points one relative `volumeup`/`volumedown` verb moves the slider.
    static let speakerVolumeStep = 2

    // MARK: Mapping + merge

    /// Map a ``DiscoveredDevice`` onto a ``Device``, folding in app-side mute state.
    private func mapDiscovered(_ discovered: DiscoveredDevice) -> Device {
        let id = discovered.id
        let isMuted = muted.contains(id)
        let supportsAP2 = discovered.isAirPlay2Supported
        // Availability rules (available == "streamable right now", drives + selects):
        //  - AP1-only (never AP2): reachable and engine-driveable — available=true,
        //    `supportsAirPlay2=false` only advertises the missing multi-room sync.
        //  - AP2 online: available.
        //  - AP2 OFFLINE (sticky-AP2, `discovered.isAvailable == false`): keeps
        //    supportsAP2=true but available=false — surfaced as an unavailable
        //    (retry-on-click) row.
        // Discovery already reports `isAvailable == true` for a live AP1 receiver
        // and `false` only for a sticky-AP2 device gone offline, so this is a direct
        // pass-through of discovery's own reachability fact.
        let isAvailable = discovered.isAvailable
        let baseVolume = known[id]?.volume ?? 50
        return Device(
            id: id,
            // The engine-facing `descriptor.name` is the RAW resolved instance
            // name (for `_raop._tcp` devices it carries the "<12-hex>@" MAC
            // prefix the vendored `raop_device_cb` re-parses for the device id —
            // see `NativeDiscovery.buildDevice`). The user never sees that
            // decoration, so strip it here for the display name. A no-op for
            // AP2/local names, which have no such prefix.
            name: NativeDiscovery.strippedRaopDisplayName(discovered.descriptor.name),
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
        if discovered.isAvailable {
            // A reachable receiver (AP1 or AP2) that re-resolved is streamable
            // again (a dropped→returned device comes back available). Its
            // volume/mute/selection and connection dot are left to the converge
            // path — merge only restores availability.
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
            // An unavailable non-AP2 (AP1) receiver. A live AP1 device reports
            // `isAvailable == true` (first branch) and only reaches here if it has
            // genuinely gone away without a `.disappeared` — treat it as a clean,
            // deliberate stop rather than a retryable failure.
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
        // Match against the human-facing name, not the raw engine descriptor:
        // a `_raop._tcp` descriptor name still carries the "<12-hex>@" MAC prefix
        // (see `NativeDiscovery.buildDevice`), whose hex digits could otherwise
        // pollute the substring heuristics below. No-op for AP2/local names.
        let name = NativeDiscovery.strippedRaopDisplayName(discovered.descriptor.name).lowercased()
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

    /// Perceptual floor for AirPlay-1 (RAOP) receivers, in dB of the AirPlay
    /// −30…0 range. RAOP receivers (shairport-sync's default: software volume
    /// spread across the output device's FULL mixer range, often ~100 dB) stretch
    /// −30…0 across that whole range, so a linear slider's bottom half is
    /// inaudible — the live-observed "cliff at ~50%" (2026-07-22). Compressing the
    /// slider onto [MIN_DB, 0] keeps every position usable. NOT a protocol value:
    /// a perceptual floor to TUNE BY EAR against real hardware (the
    /// `AIRPLAYENGINE_LOG_LEVEL=5` "RAOP volume: … dB on wire" line prints what it
    /// produces). −12 dB is a starting estimate.
    static let airPlay1MinVolumeDB = -12.0

    /// AirPlay-1 volume curve: UI 0–100 → engine normalized 0.0…1.0, remapped so
    /// the C layer's linear map (`airplay_dB = −30 + 0.3·pct`) lands in
    /// [``airPlay1MinVolumeDB``, 0] instead of the full −30…0 — keeping the whole
    /// slider audible on wide-mixer RAOP receivers. AP1 only; AP2/Sonos stays on
    /// the by-ear-verified linear ``engineVolume(_:)``.
    static func engineVolumeAP1(_ uiVolume: Int) -> Double {
        let x = Double(uiVolume.clampedToVolume) / 100.0
        let shaped = pow(x, 0.6)                        // mild perceptual taper
        let dB = airPlay1MinVolumeDB * (1.0 - shaped)  // x=1 → 0 dB, x=0 → MIN_DB
        let pct = (dB + 30.0) / 0.3                     // invert the C map → device->volume pct
        return max(0.0, min(1.0, pct / 100.0))
    }

    /// Pick the AP1 perceptual curve or the AP2 linear map by device. MUST be
    /// called on `stateQueue` (reads `known`). Unknown id falls back to linear.
    private func engineVolume(forID id: String, uiVolume: Int) -> Double {
        (known[id]?.supportsAirPlay2 ?? true)
            ? Self.engineVolume(uiVolume)
            : Self.engineVolumeAP1(uiVolume)
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
    // discovery loss) rather than a separate poll-derived stability window. AP1 and
    // AP2 receivers alike ride these hooks; only the local Mac output (never routed,
    // `setOutputSet` skips it) stays `.off` for its whole lifetime.

    /// Current lifecycle state for an id; absence means `.off`.
    private func connectionState(of id: String) -> ConnectionState {   // on stateQueue
        known[id]?.connectionState ?? .off
    }

    /// Record a transition and echo it through the normal update machinery.
    /// `applyLocal` no-ops (and this is a no-op) for ids not yet discovered.
    private func setConnectionState(_ state: ConnectionState, for id: String) {   // on stateQueue
        guard connectionState(of: id) != state else { return }
        applyLocal(id) { $0.connectionState = state }
        // Every connection-lifecycle edge can change "is any desired device audible":
        // a `→ .connected` re-engages the gate (clearing a silence fallback), a
        // `→ .failed`/`.off` for the last connected member arms the countdown (R11).
        reconcileSilenceWatchdog()
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
        pushVolume(outputID, engineValue: engineVolume(forID: id, uiVolume: intended))
    }

    /// Seed a just-(re)connected engine output's starting volume from the
    /// configured connect-volume default. Pushes the level to the engine and
    /// returns the value to display on the model, or `nil` when the seed is
    /// suppressed (leave the model volume untouched). On `stateQueue`.
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
    /// Source of the level (G1-N1): ``connectVolumeProvider`` — the user's
    /// configured connect volume (``AppSettings/connectVolume``, default 35%), NOT
    /// the Mac's current system level. An earlier design inherited the system level,
    /// but Mac speakers often run loud, so connecting a real AirPlay speaker could
    /// BLAST the user on first connect. A fixed moderate default is predictable and
    /// safe. The value is clamped to ``AppSettings/minConnectVolume``… so the seed
    /// can NEVER be 0/silent — closing the −30 dB trap from the other direction (a
    /// bad/injected provider value can't reach silence either).
    ///
    /// Mute carve-out: a device the user explicitly muted stays effective-0. Seed the
    /// INTENDED level into `stashedVolume` (so a later unmute restores the system
    /// level) and keep the wire at 0 — never un-mute here.
    ///
    /// Suppression: returns `nil` and pushes nothing while `id` is in
    /// ``bufferReAdding``, so ``applyStartBuffer(ms:)``'s internal teardown/re-add —
    /// a buffer-size change, NOT a user reconnect — preserves the device's existing
    /// in-session level instead of resetting it to the connect default.
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
    /// The seed reads ``connectVolumeProvider`` (a `UserDefaults`-backed
    /// `AppSettings` read — cheap, non-blocking, unlike the old system-volume HAL
    /// read) and clamps it to ``AppSettings/minConnectVolume``…
    /// ``AppSettings/maxConnectVolume``. The clamp is the load-bearing safety net:
    /// even if the setting or an injected test provider returns 0 or something out
    /// of range, the value that reaches the wire is always audible — 0/silent is
    /// unreachable.
    private func connectVolumeSeed(_ id: String, outputID: OutputID) -> Int? {   // on stateQueue
        guard !bufferReAdding.contains(id) else { return nil }
        let seed = min(max(connectVolumeProvider(), AppSettings.minConnectVolume), AppSettings.maxConnectVolume)
        if muted.contains(id) {
            // Keep the mute; only update the level an unmute will restore.
            stashedVolume[id] = seed
            pushVolume(outputID, engineValue: Self.engineVolume(0))
        } else {
            pushVolume(outputID, engineValue: engineVolume(forID: id, uiVolume: seed))
        }
        return seed
    }

    // MARK: Capture gate

    /// Start/stop capture so the tap runs IF AND ONLY IF at least one real
    /// receiver output is selected. On `stateQueue`, called only from `setOutputSet`.
    ///
    /// ## Why intent, not availability (deliberate)
    /// `want` reads `expectedSelected` — what the user ASKED for — and only checks
    /// that the id is a discovered receiver (`!isLocalDevice`), never `isAvailable`,
    /// `added`, or `converging`. A selected receiver that transiently drops
    /// therefore KEEPS capture running (the Mac stays muted) until it returns or the
    /// user deselects it. That's the point: a brief dropout must not blast the Mac's
    /// speakers mid-song. The `!isLocalDevice` check excludes the one id class that
    /// can never stream — the local Mac device (already filtered by
    /// `GroupController.applyRouting`, and with no `outputIDs` entry) — while
    /// including both AP1 and AP2 receivers, so `want` means exactly "an id
    /// `setOutputSet` could actually `addOutput`". An id not yet discovered reads
    /// `nil` ⇒ excluded, matching the converge loop below, which only ever iterates
    /// `order` (known devices).
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
        // Two overrides force the tap OFF regardless of selection: while
        // `suspended` (system sleep — nothing to send, and a later didWake re-decides)
        // and while the silence watchdog has un-gated capture (`silenceCaptureOverride`
        // — no desired device is connected, so un-mute the Mac; R11). Neither touches
        // the selection intent, so the gate re-engages the moment both clear.
        let want = !suspended && !silenceCaptureOverride
            && expectedSelected.contains { known[$0]?.isLocalDevice == false }
        guard want != captureRunning else { return }   // already at target
        captureRunning = want
        // W3-T3: streaming just started or stopped — re-evaluate the double-path
        // guard (it also depends on the system default output, which didn't
        // necessarily change here, but `captureRunning` — the other half of its
        // condition — just did).
        reconcileSystemAirPlayGuard()
        captureControlQueue.async {
            if want { coordinator.start() } else { coordinator.stop() }
        }
    }

    // MARK: MeteringControlling (T-GATE / T3) + level coalescing (D3)

    /// Display cadence for level emission (D3) — ~25 Hz, above the perception
    /// threshold for a VU meter but far below the ~86/s raw capture-buffer rate.
    private let levelEmitIntervalNanos: UInt64 = 40_000_000
    /// Per-device leading-edge timestamp (`DispatchTime.now().uptimeNanoseconds`)
    /// of the last emitted `.level` event.
    private var lastLevelEmitNanos: [String: UInt64] = [:]
    /// Per-device latest value seen while inside the coalescing window, delivered
    /// by the trailing flush.
    private var pendingLevel: [String: Float] = [:]
    /// Ids with a trailing flush already scheduled, so a burst schedules at most
    /// one `asyncAfter` per device.
    private var levelFlushScheduled: Set<String> = []

    /// Flip the popover-visibility metering gate. Forwards to ALL THREE RMS
    /// sources — the whole-system `captureCoordinator`, the `routeMixer`
    /// (`.device` per-app meter), and the `localPlaybackEngine` (`.currentDevice`
    /// per-app meter) — and drives the metering-only tap lifecycle (the
    /// `.noRedirect` per-app meter): on `true`, start a dedicated `.unmuted` tap
    /// for every currently-eligible listed app; on `false`, stop them all.
    /// `PopoverController` calls this on `popoverDidShow`/`popoverDidClose` via
    /// `backend as? MeteringControlling`. The `?` sub-components are `nil` in
    /// tests / the UI-only smoke path (harmless no-ops).
    public func setMeteringActive(_ active: Bool) {
        captureCoordinator?.setMeteringActive(active)
        routeMixer.setMeteringActive(active)
        localPlaybackEngine?.setMeteringActive(active)
        let diff: (start: Set<String>, stop: Set<String>) = stateQueue.sync {
            self.meteringActive = active
            return self.meteringTapDiffLocked()
        }
        applyMeteringTapDiff(diff)
    }

    // MARK: Synced local sink (T-FANOUT / "play everywhere")

    /// Attach (or detach, with `nil`) the delayed local sink used in "play
    /// everywhere" mode (T-FANOUT). The whole-system tap fans the SAME captured
    /// audio it sends the AirPlay engine to this sink, which plays a PTP-delayed
    /// copy on the Mac's own speakers phase-aligned with the receivers.
    ///
    /// CRITICAL (R2 / brief §8): the sink renders through THIS app's own
    /// `AVAudioEngine`, so the whole-system tap attributes its output to our
    /// process. We hand the coordinator our own pid (`getpid()`) as the
    /// render-process identity to EXCLUDE from the tap — otherwise the tap
    /// re-captures the delayed output and "play everywhere" becomes "play
    /// everywhere, with a delayed echo of itself." Because the tap is
    /// `.mutedWhenTapped`, excluding our process also leaves the delayed output
    /// audible while the raw system mix stays muted — exactly the intent.
    ///
    /// T-BACKEND drives WHEN this is called (the selection includes the Mac plus
    /// ≥1 AirPlay device); this method just wires the sink + self-exclude through
    /// the capture seam. No-op when no real capture coordinator is wired
    /// (tests / UI-only smoke).
    public func attachSyncedLocalSink(_ sink: SyncedLocalPCMSink?) {
        let renderProcessPID: pid_t? = (sink == nil) ? nil : getpid()
        captureCoordinator?.setSyncedLocalSink(sink, renderProcessPID: renderProcessPID)
    }

    // MARK: Metering-only tap reconcile (T3, `.noRedirect` source)

    /// Compute the metering-only tap start/stop diff and COMMIT the new target set
    /// (`meteringTapTargets`). MUST be called on `stateQueue`.
    ///
    /// Metering-only taps exist ONLY for apps in the Applications list
    /// (`lastRoutes`) that have no other capture — not `.device`-routed (level
    /// comes from the mixer), not `.currentDevice` (from local playback), not
    /// user-excluded (PRIVACY: never metered) — and ONLY while a meter is shown
    /// (`meteringActive`). When metering is off the desired set is empty, so this
    /// also STOPS every metering-only tap.
    private func meteringTapDiffLocked() -> (start: Set<String>, stop: Set<String>) {
        let desired: Set<String> = meteringActive
            ? Set(lastRoutes.map(\.bundleID))
                .subtracting(routedBundleIDs)
                .subtracting(localBundleIDs)
                .subtracting(lastExcludedBundleIDs)
            : []
        let current = meteringTapTargets
        meteringTapTargets = desired
        return (start: desired.subtracting(current), stop: current.subtracting(desired))
    }

    /// Execute a metering-only tap diff on `captureControlQueue` (off `stateQueue`
    /// — a tap start/stop may block on Core Audio), stop-before-start. A no-op when
    /// empty. Used by `setMeteringActive`; `updateAppRoutes` inlines the same ops
    /// into its own `captureControlQueue` hop.
    private func applyMeteringTapDiff(_ diff: (start: Set<String>, stop: Set<String>)) {
        guard !diff.start.isEmpty || !diff.stop.isEmpty else { return }
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            for bundleID in diff.stop { self.meteringCapture.stop(bundleID: bundleID) }
            for bundleID in diff.start { self.meteringCapture.start(bundleID: bundleID) }
        }
    }

    // MARK: Level emission (T3 — combined per-device MAX)

    /// Whether `device` is genuinely streaming the whole-system mix right now,
    /// for METERING purposes — the fact `emitLevel`/`emitCombinedLevel` need to
    /// decide whether `latestSystemRMS` belongs in this device's bar. For every
    /// AirPlay device this is exactly `Device.isSelected` (a live engine
    /// session — see `applyEngineState`/`convergeDevice`). The LOCAL device is
    /// structurally EXCLUDED from that mechanism: `setOutputSet` never adds it
    /// to `ids`/`outputIDs`/`added` (see "MARK: Current (local) output device
    /// (BUG B)" above — it has no engine session at all), so
    /// `known[localDeviceID].isSelected` never becomes true even while the
    /// synced-local sink is genuinely rendering the same mix to the Mac's own
    /// speakers (the "Mac + AirPlay" scenario) — the local row's meter was
    /// permanently silent. Its real "streaming now" fact lives in
    /// `syncedLocalSinkEnabled` instead, flipped by the SAME "Mac + ≥1 AirPlay"
    /// decision in `setOutputSet` that starts/stops the sink — and the sink
    /// renders the identical already-captured PCM this RMS was measured from
    /// (T-FANOUT), so reusing it is exact, not an approximation. This was a
    /// pre-existing gap (the synced-local sink and per-device metering shipped
    /// in separate phases; neither retrofitted the other), not a regression
    /// from the T1-T3 dropout fixes. Must run on `stateQueue`, like every caller.
    private func isMeterable(_ device: Device) -> Bool {
        device.isLocalDevice ? syncedLocalSinkEnabled : device.isSelected
    }

    /// A whole-system-tap RMS sample (stream_id 0). Store it and re-emit the
    /// combined `.level` for every device currently streaming it (``isMeterable``)
    /// and unmuted (its system contribution just changed). On `stateQueue`; gated
    /// on metering (belt-and-suspenders — the coordinator already only fires
    /// `onLevel` while active).
    private func emitLevel(_ rms: Float) {
        stateQueue.async {
            guard self.meteringActive else { return }
            self.latestSystemRMS = rms
            for id in self.order {
                guard let device = self.known[id], self.isMeterable(device), !device.isMuted else { continue }
                self.emitCombinedLevel(forDevice: id)
            }
        }
    }

    /// Record one app's PRE-volume SOURCE level and fan it out: to the app's own
    /// row (`.appLevel`), and — if the app is `.device`-routed — into the combined
    /// meter of the device it feeds (a redirect target's contribution is the
    /// loudest source routed to it; see `emitCombinedLevel`). Gated on metering.
    /// Callable from any source thread (mixer queue, tap delivery, engine); hops
    /// to `stateQueue`. (The `.appLevel` itself is emitted directly, not through the
    /// D3 coalescer, which is per-device `.level` only — app-level coalescing is a
    /// tracked follow-up.)
    private func emitAppLevel(bundleID: String, rms: Float) {
        stateQueue.async {
            guard self.meteringActive else { return }
            self.emit(.appLevel(bundleID: bundleID, rms: rms))
            self.latestAppLevel[bundleID] = rms
            // The device this app feeds tracks the loudest source routed to it, so
            // re-emit its combined `.level` now that this source level changed.
            for route in self.lastRoutes where route.bundleID == bundleID {
                if case .device(let deviceID) = route.destination {
                    self.emitCombinedLevel(forDevice: deviceID)
                }
            }
        }
    }

    /// Emit `.level` for `id` as the MAX of its whole-system contribution
    /// (`latestSystemRMS`, only while ``isMeterable`` + unmuted) and its SOURCE
    /// contribution — the loudest PRE-volume level among the apps `.device`-routed
    /// to it (`latestAppLevel`). A device fed by both shows the larger. Every input
    /// is a source/program level, so no routing/output volume ever attenuates the
    /// bar. Emitted through the D3 coalescer (`scheduleLevelEmit`, ~25 Hz). On
    /// `stateQueue`.
    private func emitCombinedLevel(forDevice id: String) {
        guard let device = known[id] else { return }
        let systemContribution: Float = (isMeterable(device) && !device.isMuted) ? latestSystemRMS : 0
        var sourceContribution: Float = 0
        for route in lastRoutes where !deadBundleIDs.contains(route.bundleID) {
            if case .device(let deviceID) = route.destination, deviceID == id,
               let level = latestAppLevel[route.bundleID] {
                sourceContribution = max(sourceContribution, level)
            }
        }
        scheduleLevelEmit(id: id, rms: max(systemContribution, sourceContribution),
                          now: DispatchTime.now().uptimeNanoseconds)
    }

    /// Leading-edge/trailing-edge sampler (D3): emits immediately if at least
    /// `levelEmitIntervalNanos` has passed since this device's last emit;
    /// otherwise remembers the latest value and lets an already-scheduled trailing
    /// flush deliver it, so a burst's final value always lands and the meter never
    /// freezes on a stale pre-quiet value. On `stateQueue`.
    private func scheduleLevelEmit(id: String, rms: Float, now: UInt64) {   // on stateQueue
        if let last = lastLevelEmitNanos[id], now - last < levelEmitIntervalNanos {
            pendingLevel[id] = rms
            guard levelFlushScheduled.insert(id).inserted else { return }
            let remaining = levelEmitIntervalNanos - (now - last)
            stateQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(remaining))) { [weak self] in
                self?.flushPendingLevel(id: id)
            }
            return
        }
        lastLevelEmitNanos[id] = now
        pendingLevel.removeValue(forKey: id)
        emit(.level(id: id, rms: rms))
    }

    /// Trailing flush for `scheduleLevelEmit` — delivers whatever value arrived
    /// last during the coalescing window, if any (a leading-edge emit may have
    /// already cleared it). On `stateQueue`.
    private func flushPendingLevel(id: String) {   // on stateQueue
        levelFlushScheduled.remove(id)
        guard let rms = pendingLevel.removeValue(forKey: id) else { return }
        lastLevelEmitNanos[id] = DispatchTime.now().uptimeNanoseconds
        emit(.level(id: id, rms: rms))
    }

    // MARK: Emit

    private func emit(_ event: BackendEvent) {   // on stateQueue
        for continuation in continuations.values { continuation.yield(event) }
    }
}

private extension TransportCommand {
    /// Map the engine's transport command onto the backend-neutral one the base
    /// ``OutputBackend`` seam publishes (``RemoteTransportCommand``).
    var backendCommand: RemoteTransportCommand {
        switch self {
        case .playPause: return .playPause
        case .next:      return .next
        case .previous:  return .previous
        }
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
    func makeRemoteEventStream() -> AsyncStream<RemoteEvent>

    /// The DACP-ID the engine advertises to receivers (see ``AirPlayEngine/dacpID``),
    /// so the backend's DACP server can advertise the matching `iTunes_Ctrl_<id>`.
    var dacpID: UInt64 { get }

    /// Whether a PTP clock was available as of the engine's last `start()`
    /// (T4 — mirrors `AirPlayEngine/ptpClockAvailable`). `false` means no
    /// shared root PTP helper was found (the shipped find-only default, T3),
    /// so PTP-only receivers (Sonos et al) will fail to stream even though
    /// the engine itself came up fine (NTP-only receivers are unaffected).
    /// Default `true` so a conformer that predates T4 (any existing
    /// `NativeBackendTests` spy) compiles unchanged and keeps its prior
    /// all-healthy behavior.
    var ptpClockAvailable: Bool { get async }
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

    /// Default: healthy (T4). ``EngineAdapter`` overrides this to forward to the
    /// real engine's `ptpClockAvailable`; a conformer that predates T4 (existing
    /// `NativeBackendTests` spies) compiles unchanged and reports "available".
    var ptpClockAvailable: Bool {
        get async { true }
    }
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
    func makeRemoteEventStream() -> AsyncStream<RemoteEvent> { engine.makeRemoteEventStream() }
    var dacpID: UInt64 { engine.dacpID }
    var ptpClockAvailable: Bool {
        get async { await engine.ptpClockAvailable }
    }
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

    /// Fired when the whole-system tap was rebuilt specifically because the tapped
    /// output device changed or renegotiated its nominal sample rate (T2), so
    /// ``NativeBackend`` can reset the AirPlay RTP sessions that rebuild leaves
    /// desynced. Deliberately NOT fired for a benign exclusion-set rebuild (the
    /// synced-local sink attach on every Mac+AirPlay connect, or an app-route
    /// change) — resetting there added a redundant RTP re-establish to every
    /// connect ("connects fast, then a long silence"). See
    /// ``NativeCaptureCoordinator/onDeviceRateRebuild``. Default get-nil/set-noop
    /// (below) so a fake that only exercises the capture gate compiles unchanged;
    /// ``NativeCaptureCoordinator`` provides the real stored property.
    var onDeviceRateRebuild: (@Sendable () -> Void)? { get set }
    /// Begin capturing system audio. Idempotent.
    ///
    /// The real tap is `.mutedWhenTapped`: while it runs, the Mac's own speakers
    /// are SILENT. Only call it when the captured audio actually has somewhere to
    /// go (`NativeBackend` gates this on a real AP2 output being selected).
    func start()
    /// Stop capturing. Idempotent. MAY BLOCK on Core Audio teardown, so callers
    /// must keep it off `NativeBackend.stateQueue`.
    func stop()
    /// Gate RMS computation/emission on or off (T-GATE) — independent of
    /// `start()`/`stop()`. See ``NativeCaptureCoordinator/setMeteringActive(_:)``.
    func setMeteringActive(_ active: Bool)

    /// Keep the whole-system tap's exclusion set in sync with the routing table
    /// (T4/T6): individually-routed apps (`.device(id:)` routes) and user-excluded
    /// apps must not double up into the system-wide mix. Default no-op so a fake
    /// that only exercises the capture gate compiles unchanged;
    /// ``NativeCaptureCoordinator`` provides the real implementation.
    func updateRouting(appRoutes: [AppRoute], excludedBundleIDs: Set<String>)

    /// Force a re-resolve + rebuild against the LIVE process set for
    /// `bundleID`, if it's currently excluded/routed-away (R14 — relaunch
    /// correctness). See ``NativeCaptureCoordinator/refreshExcludedProcessSet(forRelaunchedBundleID:)``.
    /// Default no-op so a fake that doesn't exercise this path compiles
    /// unchanged; ``NativeCaptureCoordinator`` provides the real implementation.
    func refreshExcludedProcessSet(forRelaunchedBundleID bundleID: String)

    /// Attach/detach the delayed local sink fan-out (T-FANOUT) and the pid of the
    /// process that renders its output. A non-nil sink turns the fan-out on and
    /// adds `renderProcessPID` to the whole-system tap's exclusion set so the
    /// sink's own output isn't re-captured as an echo (R2); `nil` turns both off.
    /// Default no-op so a capture-gate-only fake compiles unchanged;
    /// ``NativeCaptureCoordinator`` provides the real one.
    func setSyncedLocalSink(_ sink: SyncedLocalPCMSink?, renderProcessPID: pid_t?)
}

extension CaptureControlling {
    /// Default no-op (T2) so a fake that doesn't exercise the whole-system tap's
    /// lifecycle compiles unchanged; ``NativeCaptureCoordinator`` provides the real
    /// stored property. A conformer that never fires it (get returns `nil`, set is
    /// dropped) is a faithful stand-in for a test that only drives the capture gate.
    var onDeviceRateRebuild: (@Sendable () -> Void)? {
        get { nil }
        set { }
    }

    /// Default no-op (T-GATE) so a fake that doesn't exercise the metering gate
    /// compiles unchanged; ``NativeCaptureCoordinator`` provides the real one.
    func setMeteringActive(_ active: Bool) {}
    func updateRouting(appRoutes: [AppRoute], excludedBundleIDs: Set<String>) {}
    func refreshExcludedProcessSet(forRelaunchedBundleID bundleID: String) {}
    /// Default no-op (T-FANOUT) so a fake that doesn't exercise the synced-local
    /// sink compiles unchanged; ``NativeCaptureCoordinator`` provides the real one.
    func setSyncedLocalSink(_ sink: SyncedLocalPCMSink?, renderProcessPID: pid_t?) {}
}

extension NativeCaptureCoordinator: CaptureControlling {}

/// The full lifecycle surface T-BACKEND drives on the delayed local sink: the
/// fan-out target itself (``SyncedLocalPCMSink``, T-FANOUT) plus start/stop and
/// the T-LIFECYCLE device-change/sleep-wake observers. Lets ``NativeBackend``
/// own WHEN "play everywhere" (Mac + ≥1 AirPlay device) turns on/off against
/// either the real ``SyncedLocalSink`` or a test spy, with no `AVAudioEngine`
/// in the loop for the enable/disable unit tests.
public protocol SyncedLocalSinkControlling: SyncedLocalPCMSink {
    func start() throws
    func stop()
    func startObservingLifecycleEvents()
    func stopObservingLifecycleEvents()
}

extension SyncedLocalSink: SyncedLocalSinkControlling {}
