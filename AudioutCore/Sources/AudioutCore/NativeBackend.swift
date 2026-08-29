import Foundation
import AudioToolbox
import AirPlayEngine
import CastSender

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

    /// Bluetooth audio-output enumeration (BT-ENUM): Core Audio BT transport
    /// merged with the IOBluetooth paired list, surfacing `.bluetooth` rows the
    /// same way discovery surfaces AirPlay rows. `nil` (the designated init's
    /// default, so every existing test stays BT-free) means no BT enumeration;
    /// the production convenience init wires the real ``BTDeviceEnumerator``.
    /// BT devices never get an `outputIDs` entry and are never fed to the
    /// engine — structurally unroutable until BT-BACKEND partitions the output
    /// set (plan risk R-partition).
    private let btEnumerator: BTDeviceEnumerating?
    /// BT-CONNECT: IOBluetooth connect/disconnect for paired BT speakers.
    /// `nil` under most tests (like `btEnumerator`), which keeps every BT
    /// reconnect path inert unless a fake is injected.
    private let btConnectionManager: BTConnectionManaging?

    /// Cast discovery (CAST-ENUM): `_googlecast._tcp` browse surfacing `.cast`
    /// rows through the same `known`/`order`/`emit` flow BT rows use. `nil` (the
    /// designated init's default, so every existing test stays Cast-free) means
    /// no Cast enumeration; the production convenience init wires the real one.
    private let castEnumerator: CastDeviceEnumerating?
    /// CAST-OUT: the per-receiver session manager the selection arm drives.
    /// `nil` under most tests, which keeps every Cast path inert unless a fake
    /// is injected. Cast ids are the THIRD routing partition — never an
    /// `outputIDs` entry, never fed to the engine.
    private let castOutputManager: CastOutputControlling?

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

    /// Supplies whether `id` is currently a member of what Main Out points at —
    /// the Selected Devices set OR the active group's members — the signal
    /// T-BACKEND needs to detect "Mac + ≥1 AirPlay" ("play everywhere"), since
    /// `GroupController` always filters the local device out of the `ids` this
    /// backend's `setOutputSet` receives (the local Mac is never a real engine
    /// output). `GroupController` exposes exactly this via its public
    /// `isMainOutMember(_:)` — NOT `isSpeakerSelected(_:)`, which is blind to
    /// group membership; `AppDelegate` wires it in once both are constructed.
    /// Assigned once, before any selection change —
    /// same discipline as `captureCoordinator`/`localPlaybackEngine` — so no
    /// synchronization is needed on the reference itself. `nil` in tests / the
    /// UI-only smoke path, in which case "play everywhere" never activates
    /// (read as "Mac not selected").
    public var selectedDevicesQuery: ((String) -> Bool)?

    /// Fired at the START of every routing action — the two chokepoints
    /// ``setOutputSet(_:)`` and ``updateAppRoutes(_:excludedBundleIDs:)``, which
    /// between them carry EVERY user action that moves audio (device selection,
    /// group play, Main Out changes via `GroupController.applyRouting()` /
    /// `activateGroup(id:)`, and per-app rerouting). `AppDelegate` wires it to
    /// ``PermissionStateObserver/kick(source:)``, so a user who granted the
    /// system-audio permission mid-session and then simply picked a speaker gets
    /// the grant re-checked at the moment they act, with no timer anywhere.
    ///
    /// Hooked HERE rather than at the four `GroupController` call sites on
    /// purpose: the UI sites miss `activateGroup` reached through
    /// `applyRouting`'s group branch, miss any future caller, and duplicate the
    /// check four ways.
    ///
    /// **MUST NOT BLOCK.** Both chokepoints run on the MAIN THREAD, so anything
    /// synchronous here — above all a helper-process spawn — lands as latency on
    /// a device toggle. The wired implementation only ENQUEUES an asynchronous
    /// resolution, and burst safety for the documented toggle-spam storm (see
    /// "Per-device op serialization + coalescing" below) comes from
    /// ``TCCProbeRunner``'s single-flighting rather than any debounce here.
    /// Assigned once before `start()`, same discipline as `selectedDevicesQuery`.
    public var onRoutingAction: (() -> Void)?

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

    /// Whether "play everywhere" is currently enabled — the last DESIRED decision
    /// made by `setOutputSet`'s synced-local-sink reconciliation. Confined to
    /// `stateQueue` like every other selection-derived flag (`captureRunning`,
    /// `expectedSelected`); the actual attach/start/stop work it triggers runs
    /// on `captureControlQueue`, and only after the T1 settle below fires — so
    /// this flag can be AHEAD of `syncedLocalSinkApplied` during a debounce window.
    private var syncedLocalSinkEnabled = false

    // MARK: Synced-local settle debounce (T1/T2)
    //
    // Every Mac select/deselect calls `applySyncedLocalSinkTransition`, and each
    // attach/detach forces the whole-system tap to rebuild AND re-fires the
    // sink's ~977ms session anchor. RAPID toggling turned that into a storm
    // (~19 tap rebuilds in 2.5s), none of which reset the AirPlay receiver's RTP
    // session (an `.exclusionChange` rebuild deliberately skips that reset), which
    // desyncs/corrupts the receiver → permanent silence. The fix coalesces a burst
    // into AT MOST ONE real transition on the trailing edge of a quiet window, and
    // re-establishes the receiver session exactly once IFF the burst actually
    // churned (≥2 coalesced toggles). A normal single toggle collapses to exactly
    // one coalesced decision and NEVER pays that re-sync — reintroducing a redundant
    // RTP re-establish on every ordinary connect is the exact bug a prior fix
    // removed (`dev/notes/synced-local-mixed-selection-dropout-fix.md`).

    /// What the last EXECUTED synced-local transition actually set — the applied
    /// state, distinct from the desired `syncedLocalSinkEnabled` above. The T1
    /// settle only runs a real transition when `desired != applied`, so a burst
    /// that collapses back to its starting point is a true no-op. On `stateQueue`.
    private var syncedLocalSinkApplied = false

    /// The pending trailing-edge settle; a newer toggle cancels + reschedules it,
    /// so a burst fires only once, 250ms after the LAST toggle. On `stateQueue`.
    private var pendingSyncedLocalSettle: DispatchWorkItem?

    /// How many distinct synced-local toggle DECISIONS have coalesced into the
    /// currently-pending settle. `>= 2` when the settle fires means genuine churn
    /// (rapid clicking) and arms the one-shot T2 RTP re-sync; exactly `1` is a
    /// normal single toggle and must never trigger it. Reset to 0 on each fire.
    /// On `stateQueue`.
    private var syncedLocalCoalescedCount = 0

    /// Trailing-edge quiet window for coalescing synced-local toggles. A single
    /// toggle still fires after just this delay (an accepted tradeoff — kept
    /// simple, trailing-edge only, no leading-edge fast path).
    private static let syncedLocalSettleWindow: TimeInterval = 0.25

    // MARK: Bluetooth outputs — sink-manager lifecycle (BT-BACKEND, R-partition)

    /// Builds the N-instance Bluetooth sink manager the first time a BT output
    /// is selected. `makeBackend(_:)` wires the production closure (a
    /// ``BTSyncedSink`` reading this backend's live start-buffer value — plan
    /// risk R4 forbids a stale copy); tests inject a spy conforming to
    /// ``BTSyncedSinkControlling``. `nil` = BT playback inert (same posture as
    /// a nil `syncedLocalSinkFactory`).
    var btSyncedSinkFactory: (() -> BTSyncedSinkControlling)?

    /// The constructed manager (real or spy), built lazily on first enable and
    /// reused across disable/re-enable. Every USE of the sink is confined to
    /// `captureControlQueue`; the reference itself is guarded by
    /// ``btSinkRefLock`` so the sync drawer can read the sink without waiting
    /// behind a tap rebuild.
    private var btSink: BTSyncedSinkControlling?

    /// Guards the ``btSink`` REFERENCE only (never the sink's own state — the
    /// sink is internally synchronized).
    private let btSinkRefLock = NSLock()

    // MARK: Bluetooth connect lifecycle (BT-LIFECYCLE)

    /// Every BT id currently held at `.connecting`, with the instant its hold
    /// expires. An entry exists ONLY while the row is breathing; the promotion
    /// to `.connected` (or the degrade to `.failed`) removes it. On `stateQueue`.
    private var btConnectingDeadlines: [String: Date] = [:]

    /// The armed poll that asks the sink manager which devices have started
    /// rendering. `nil` = nothing is breathing, so nothing is scheduled — the
    /// poll exists only for the duration of a connect. On `stateQueue`.
    private var btRenderPollWork: DispatchWorkItem?

    /// How often the hold re-asks. Fast enough that the dot lands with the
    /// first note rather than after it.
    private static let btRenderPollInterval: TimeInterval = 0.1

    /// Ceiling on the `.connecting` hold: engine start + the first captured
    /// buffer + the reference delay (at most the AirPlay presentation delay).
    /// Past it the row reads `.failed` — a spinner that never resolves is the
    /// one outcome a connection indicator may never produce. Settable so tests
    /// don't sleep through the real ceiling.
    var btRenderStartTimeout: TimeInterval = 6

    // MARK: Bluetooth per-device sync trim (BT-OFFSET-UI)

    /// Persistence for the per-device SYNC trims. `nil` (most tests) = trims
    /// live for the session only.
    private let btTrimStore: BTTrimStore?
    /// Guards ``btTrimsByUID`` alone — read from the UI thread
    /// (``btSyncTrim(forDevice:)``), written by ``setBTSyncTrim(_:forDevice:)``,
    /// and snapshotted by `captureControlQueue` when a sink is (re)armed; a
    /// dedicated lock keeps those reads off `stateQueue` entirely.
    private let btTrimLock = NSLock()
    private var btTrimsByUID: [String: Double] = [:]   // btTrimLock

    // MARK: Cast per-device by-ear offset (CAST-SYNC)

    /// Persistence for the per-receiver Cast offsets — its own file beside the
    /// Bluetooth trims'. `nil` (most tests) = offsets live for the session only.
    private let castOffsetStore: BTTrimStore?
    /// Guards ``castOffsetsByID`` alone, for the same reason ``btTrimLock``
    /// guards its own map: the UI reads it, and `captureControlQueue` reads it
    /// again when a receiver is armed.
    private let castOffsetLock = NSLock()
    private var castOffsetsByID: [String: Double] = [:]   // castOffsetLock
    /// Each Bluetooth device's MEASURED output latency in ms (roadmap 056 Part
    /// A) — how late the speaker plays on its own, which is what the alignment
    /// wizard now determines. Distinct from the trim: the latency is a
    /// measurement of the hardware, the trim is the user's nudge on top, and
    /// the wizard never rewrites the latter. Same lock, same read/write
    /// pattern, and persisted in the same file's second map.
    private var btLatencyMsByUID: [String: Double] = [:]   // btTrimLock

    // MARK: Tone (per-device + Main Out EQ)

    /// Persistence for the tone settings. `nil` (most tests) = session-only.
    private let eqStore: DeviceEQStore?
    /// Every device's tone, whether or not it is currently streaming. On
    /// `stateQueue`. Stored values are NEVER discarded for budget reasons — a
    /// device that can't get its own stream streams flat and says so
    /// (`Device.eqBypassReason`) while keeping what the user dialled in.
    private var eqByDeviceID: [String: DeviceEQ] = [:]   // on stateQueue
    /// The whole mix's own tone stage, applied before every fan-out. On `stateQueue`.
    private var storedMainOutEQ: DeviceEQ = .flat   // on stateQueue
    /// Which stream id each EQ group owns, remembered across recomputes so
    /// editing a lone device's values swaps coefficients instead of rebinding.
    private var eqAllocator = EQStreamAllocator()   // on stateQueue
    /// The assignment the LAST ``reconcileEQPlan()`` settled on — deviceID → the
    /// whole-system stream it should be bound to (0 = flat/main-only). Diffed to
    /// issue the minimal set of EQ rebinds, and read by ``pushEQPlanLocked()`` so
    /// an uncommitted edit can swap coefficients without recomputing topology.
    private var eqStreamIDByDevice: [String: UInt32] = [:]   // on stateQueue
    /// Devices whose EQ move was refused because a `convergeDevice` loop held
    /// their `converging` slot — the commonest case by far, since the connect
    /// edge that owes the move happens INSIDE that loop. Drained by the slot
    /// release, the same bow-out-and-be-re-driven shape the scope arbiter's
    /// `pendingScopeSettles` uses. On `stateQueue`.
    private var eqRebindDeferred: Set<String> = []   // on stateQueue

    /// One published tone stage: the processor the delivery thread is running,
    /// plus the value it was built for.
    ///
    /// Kept so an UNCHANGED stage keeps the very same `EQProcessor` instance
    /// across pushes. A processor carries IIR delay memory, and a fresh one
    /// starts empty — rebuilding every stage on every push put a step
    /// discontinuity (an audible tick) through every other live stream on each
    /// frame of one device's slider drag.
    private struct EQProcessorSlot {
        let eq: DeviceEQ
        let processor: EQProcessor
    }
    /// The live per-stream stages, keyed by stream id. On `stateQueue`.
    private var eqSlotByStream: [UInt32: EQProcessorSlot] = [:]   // on stateQueue
    /// The live Main Out stage. On `stateQueue`.
    private var mainOutEQSlot: EQProcessorSlot?   // on stateQueue

    /// The rate every whole-system `EQProcessor` is built for: the engine's
    /// hardwired PCM format (S16LE / 44100 / 2ch), which the capture
    /// coordinator's converter has already produced by the time the plan runs.
    private static let eqSampleRate: Double = 44_100

    /// How many streams the engine can carry at once. Mirrors
    /// `AirPlayEngine.maxSimultaneousStreams`, which is internal to that package
    /// (a licensing boundary this file may not widen).
    private static let engineStreamCapacity = 6

    /// Test seam: a BT `Device.id` (its Core Audio UID) → the live
    /// `AudioObjectID` a per-device sink pins its engine to. `nil` (production)
    /// falls back to `aggregateControl.resolveDeviceID(forUID:)` — the HAL's
    /// own translation. Resolved fresh at each apply, never cached: object ids
    /// go stale across a disconnect/rejoin while UIDs don't.
    var btDeviceIDForUID: (@Sendable (String) -> AudioObjectID?)?

    /// The last BT decisions `setOutputSet` committed — enable, selected uids,
    /// and group composition — so a routing call that changes none of them
    /// re-applies nothing. All on `stateQueue`; the apply they gate runs on
    /// `captureControlQueue` (the same decide/execute split as the capture
    /// gate, and the same serial queue, so a BT transition can never race a
    /// tap start/stop or a synced-local transition).
    private var btSinkEnabled = false
    private var btSelectedUIDs: [String] = []
    private var btComposition = BTGroupComposition(airPlayPresent: false, macLocalPresent: false)
    /// The BT-only reference timeline currently in force (ms) — the buffer
    /// every BT sink AND the Mac's own sink schedule against when no AirPlay
    /// receiver is in the group. Derived by ``btOnlyReferenceMs(latencies:uids:)``;
    /// on `stateQueue`, which is also where ``localSinkReferenceDelayMs()``
    /// reads it, so the two sides can never disagree about where the timeline is.
    private var btReferenceBufferMs = BTSyncedSink.defaultBTOnlyBufferMs
    /// A Bluetooth-target wizard run is under way, so the reference is pinned
    /// wide open (``btWizardReferenceBufferMs``) for the duration. On `stateQueue`.
    private var btWizardReferenceRaised = false
    /// Whether the wizard tick is currently on, so a redundant edge costs
    /// nothing — both edges re-anchor every sink, and the panel fires a second
    /// `false` on the terminal screens. Under ``btTrimLock``.
    private var btWizardTickActive = false
    /// The last candidate latency pushed per device this run, so a trial's
    /// telemetry can carry the STEP the estimator just took and not only where
    /// it landed. Cleared when the run ends. Under ``btTrimLock``.
    private var btWizardLastPreviewMsByUID: [String: Int] = [:]
    /// The wizard's last pushed tempo — the estimator's stage in disguise (the
    /// coarse search ticks far slower than the stimulus blocks), and the only
    /// signal of it that reaches this layer. Under ``btTrimLock``.
    private var btWizardTickBPM: Double?
    /// The alignment wizard's first-tick ARM gate (roadmap 056 Part B): the
    /// in-flight poll, on `captureControlQueue` (which owns both sinks).
    var wizardArmPollWork: DispatchWorkItem?   // captureControlQueue
    /// The three arm-gate timings, `var` for the same reason
    /// ``btAlignmentHoldTimeout`` is: a suite shrinks them rather than sleeping
    /// through the production values.
    var wizardArmPollInterval: TimeInterval = 0.1
    /// A floor of bed-only time before the first tick, however fast the sinks
    /// release — the Sonos Move's amplifier needs it (live finding 2026-08-07).
    var wizardArmMinimumBedSeconds: TimeInterval = 1.5
    /// The ceiling: a speaker that never reports rendering must not stall the
    /// run, so past this the ticks arm regardless.
    var wizardArmCeilingSeconds: TimeInterval = 8

    /// The latest browse record per Cast id (`stateQueue`) — kept even when the
    /// receiver drops off the network, because a row that comes back must be
    /// addressable again without waiting for a fresh browse.
    private var castRecords: [String: CastDeviceRecord] = [:]
    /// The Cast ids `setOutputSet` last committed (`stateQueue`), sorted, so a
    /// routing call that changes none of them re-applies nothing.
    private var castSelectedIDs: [String] = []
    /// Cast ids whose receiver has reported PLAYING (`stateQueue`) — the audible
    /// fact `desiredDeviceAudibleLocked` reads.
    private var castPlaying: Set<String> = []
    /// Cast ids with a grace timer running towards `isAvailable = false`
    /// (`stateQueue`), each mapped to the generation that armed it. A browse
    /// that lists the id again drops the entry, which makes the pending timer
    /// inert; the generation additionally makes a stale timer from an EARLIER
    /// absence inert after a reappear/vanish cycle.
    private var castAbsenceFlips: [String: Int] = [:]
    private var castAbsenceGeneration = 0
    /// Whether the capture fan-out's Cast slot is attached
    /// (`captureControlQueue`), so an already-armed selection change never
    /// re-attaches it.
    private var castFeedAttached = false

    // MARK: First-mix alignment intercept (W3)

    /// UIDs whose intercept the user answered "Not now" — FINAL, persisted in
    /// the trim store's envelope, loaded at init. Guarded by `btTrimLock`
    /// alongside the trims (the two records share the trigger predicate).
    private var btAlignmentDismissedUIDs: Set<String> = []   // btTrimLock
    /// UIDs currently HELD SILENT awaiting the card's answer. On `stateQueue`;
    /// applied as a per-device sink gain of 0 on `captureControlQueue`.
    private var btAlignmentHeldUIDs: Set<String> = []   // stateQueue
    /// UIDs held silent for the DURATION of a Bluetooth wizard run — every
    /// selected Bluetooth speaker except the target and (when it is itself a
    /// Bluetooth device) the reference. A run is a two-speaker comparison, and
    /// a third speaker ticking at its own trim is the loudest thing in the room
    /// (live run 2026-08-22: the decoy was judged for the whole run). On
    /// `stateQueue`; folded into `btSinkGain` like the intercept's hold, so it
    /// costs no rebuild and cannot fight the user's volume.
    private var btWizardHeldUIDs: Set<String> = []   // stateQueue
    /// UIDs whose intercept already fired since launch — the once-ever guard's
    /// in-memory half (the persistent half is a trim or dismissal record; an
    /// abandoned, unanswered card leaves no record on purpose). On `stateQueue`.
    private var btAlignmentPromptedUIDs: Set<String> = []   // stateQueue
    /// Safety net: if no UI ever answers (surface never shown, event lost), a
    /// held speaker un-mutes on its own after this long — a silent device with
    /// no visible cause is this repo's most expensive failure shape. Settable
    /// so tests don't wait out the real window.
    var btAlignmentHoldTimeout: TimeInterval = 120
    /// One pending watchdog per held uid. On `stateQueue`.
    private var btAlignmentHoldWatchdogs: [String: DispatchWorkItem] = [:]

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

    /// Whether the last connect attempt found a ready PTP clock (T4,
    /// PLAN-AIRPLAY-COEXISTENCE.md). Confined to `stateQueue` like every other
    /// piece of backend state; `true` before any connect (optimistic — no
    /// receiver has been rejected yet). NOT sourced from `engine.start()`
    /// (superseded): the on-demand helper is never touched at launch (Q1=B),
    /// so that reading is now permanently false and would be misleading.
    /// Instead `convergeDevice` sets this from `ptpHelperActivator`'s own
    /// verdict at the moment it actually gates a connect. Exposed publicly so
    /// the app can surface a degraded "clock unavailable" state (T6 owns the
    /// actual UI); this task only makes the fact observable.
    private var ptpClockAvailable = true

    /// Wakes the on-demand PTP helper and waits, bounded, for its clock
    /// before a connect (T4). Defaults to the real `PTPHelperActivator`, so
    /// every existing caller of the designated initializer compiles
    /// unchanged; tests inject a fake.
    private let ptpHelperActivator: PTPHelperActivating

    /// Fire-and-forget "let go of the PTP ports now" verb (Seamless handoff T2/T3).
    /// Defaults to the real `PTPHelperReleaser`, so every existing caller of the
    /// designated initializer compiles unchanged; tests inject a fake.
    private let ptpHelperReleaser: PTPHelperReleasing

    /// Builds the blocked-AirPlay-attempt watcher (Seamless handoff T1/T3), given
    /// the callback to invoke on a detected blocked attempt. A factory (not a
    /// stored instance) so `releaseForHandoff`/`reconcileHandoffWatcherLocked` can
    /// create/destroy watcher instances across the backend's lifetime; tests inject
    /// one that builds over a fake `LogStreamSpawning`.
    private let handoffWatcherFactory: @Sendable (@escaping @Sendable () -> Void) -> AirPlayHandoffWatcher

    /// Bind-retry budget T2 gives the helper itself (~10 s) plus the connect
    /// click's own switch-away race — matches `AirPlayEngine/Sources/ptp-helper/main.c`'s
    /// default `AUDIOUT_PTP_BIND_RETRY_SECS`.
    private static let ptpActivationTimeout: TimeInterval = 10

    /// How long a clock wait must actually run before the `.takingOver` strip
    /// mounts (banner-flash fix, 2026-08-06): a wait that resolves inside this
    /// window — the common case on a warm helper, including every failed manual
    /// retry — shows NO transient blue strip and causes no double panel re-fit;
    /// the strip only appears when the takeover is genuinely slow. `<= 0` keeps
    /// the old synchronous emit (tests that pin the strip's ordering use that).
    private let takeoverStripDelay: TimeInterval

    /// Frees UDP 319/320 before a connect by moving the Mac's own default
    /// output off an AirPlay receiver (T5). **`nil` = inert**, and that is the
    /// default deliberately: this is the one component in the backend that
    /// writes a system-wide setting a human is currently using, so it is opted
    /// IN by the composition root (`makeBackend`) rather than opted out by
    /// every test — the same shape `syncedLocalSinkFactory` uses, for the same
    /// "must not touch the real machine from a test" reason.
    private let defaultOutputSwitcher: DefaultOutputSwitcher?

    // MARK: Public aggregate device (Wave 3, T5)

    /// The Core Audio operations for the PUBLIC, Sound-settings-visible "Audiout"
    /// aggregate. Injected (default the real HAL control) so T6 can drive the whole
    /// lifecycle with a fake and never move the machine's real default output —
    /// same "no test touches the real machine" discipline as ``defaultOutputSwitcher``.
    /// ``publicAggregate`` is built FROM this exact control, so its
    /// adopt/create/sweep/classify and our own resolve/set-default calls share one
    /// seam. Distinct from the PRIVATE tap-capture aggregate
    /// `NativeCaptureCoordinator.createAggregate()` builds (different UID).
    private let aggregateControl: AggregateDeviceControlling

    /// Lifecycle owner (adopt-or-create / off-switch classify / orphan sweep) for
    /// the public aggregate — pure decision logic over ``aggregateControl``.
    private let publicAggregate: AggregateOutputDevice

    /// Reads the CURRENT system default output device's UID (`nil` if unreadable),
    /// feeding the off-switch classification. Injectable (default the real HAL
    /// read) exactly like ``systemDefaultOutputIsAirPlayClassProvider``, so T6 can
    /// script "the user switched the default away" with no hardware.
    private let currentDefaultOutputUIDProvider: @Sendable () -> String?

    /// True once this session has pointed the Mac's default output at the public
    /// aggregate (first activation, or the user's re-select). Gates the one-time
    /// capture of ``priorDefaultUID`` and the quit-time restore. `stateQueue`.
    private var aggregateDefaultActive = false

    /// The default output UID in force at the moment we FIRST took over — restored
    /// (by re-resolving it to a live id, never a cached one) on `stop()`/quit
    /// before the aggregate is destroyed. `stateQueue`.
    private var priorDefaultUID: String?

    /// Echo-guard for our OWN default-output writes: the UID we just asked the HAL
    /// to make default, pending its `defaultDeviceChanged` echo on
    /// `systemVolume.onExternalChange`. When the listener reports this same UID we
    /// consume it as our own write, NOT a user off-switch — ``SystemOutputVolume``'s
    /// echo suppression covers only its VOLUME writes, not this default-device
    /// write. `stateQueue`.
    private var expectedDefaultWriteUID: String?

    /// Last routing-blocked state pushed on the event stream, so the emit is
    /// edge-triggered (idempotent) and can never thrash/loop. `stateQueue`.
    private var routingBlockedEmitted = false

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

    // MARK: Master gain stages (Main Out × Group — all on `stateQueue`)
    //
    // Main Out is a master GAIN, not a value that rewrites per-device volumes: what
    // reaches a device is `Main × Group × Device`, multiplied on the UI's 0–100
    // scale BEFORE the dB/curve mapping. The product is formed in exactly one place
    // (`engineVolume(forID:uiVolume:)`) and is NEVER STORED — `known[id].volume`
    // stays the user's own setting for that device, forever. Storing the effective
    // value is the corruption this whole design exists to avoid: it would ratchet
    // (each re-push re-attenuating an already-attenuated level) and it would
    // silently overwrite what the user dialled in. Both stages are 100 (identity)
    // until something sets them, so a build that never calls `setMasterGain` behaves
    // exactly as before.

    /// Main Out's master gain, 0–100.
    private var mainOutGain = 100

    /// The active group's master gain, 0–100 — 100 whenever no group is active,
    /// which makes it the identity.
    private var groupGain = 100

    /// The last system output volume this backend has SEEN: seeded from the HAL in
    /// `start()` (a read, never a write) and refreshed on every
    /// `systemVolume.onExternalChange`. Two read-only jobs:
    ///
    /// - it publishes the Mac's current level through ``systemOutputVolume`` so Main
    ///   can adopt it at launch, and
    /// - it is the EMIT BASIS for `.systemVolumeChanged`. That comparison used to be
    ///   against `known[localDeviceID].volume`, which no longer tracks the system at
    ///   all — so the old basis would not only be meaningless, it would SWALLOW the
    ///   event whenever the Mac's own fader happened to equal the new system level.
    ///
    /// **Not an echo memo.** Suppressing echoes of our own writes is
    /// ``SystemOutputVolume/lastKnownVolume``'s job and stays there (one suppression
    /// memo, at the HAL helper); by the time `onExternalChange` fires, an echo has
    /// already been filtered out. This memo only decides whether a change that IS
    /// external is news.
    private var lastSeenSystemVolume: Int?

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
    //
    // T16/E10: the gate's own `want`/`captureRunning` intent is ALSO what the
    // whole-system tap's `.failed` retry gates on — see
    // `handleCaptureCoordinatorStateChange`/`scheduleCaptureRetry`. Before that
    // fix, a transient `.failed` (TCC lost mid-session, a HAL hiccup building
    // the aggregate device) had NO recovery path at all: `captureCoordinator.
    // onStateChange` wasn't wired to anything, so the tap just stayed dead
    // until the user happened to toggle a Selected Device.

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

    // MARK: The Mac's own SYNC trim (roadmap 056 Part 1 — `LocalSyncOffsetControlling`)

    /// A wizard preview offset (ms) overriding the stored setting, or `nil`.
    /// Plain lock rather than a queue: the sink reads it on its own anchor path.
    private let localTrimPreviewLock = NSLock()
    private var localTrimPreviewMs: Double?
    /// The effective offset (ms) the running sink's session was last put onto —
    /// the baseline every live change is a delta from. Confined to
    /// `captureControlQueue`. Seeded from the stored setting because that is what
    /// the sink's own anchor samples through `currentLocalSyncOffsetMs()`; every
    /// later write comes through `LocalSyncOffsetControlling` below, and a
    /// re-anchor re-reads the same live value, so the two stay in step.
    private var lastAppliedLocalOffsetMs = Double(AppSettings().syncOffsetMs)

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

    /// True while we have deliberately handed the PTP ports to macOS: sessions torn
    /// down, selection INTENT preserved. Distinct from `suspended` (which is the
    /// mechanism this reuses) so a sleep/wake cycle can't silently re-take the ports
    /// behind the user's back. `stateQueue`.
    private var handoffReleased = false

    /// Whether the default output has genuinely left our aggregate since the current
    /// handoff release began. Arms the D1 ".stillOurs ⇒ resume" trigger: after a
    /// BLOCKED-ATTEMPT release the default never moved (macOS aborts the failed
    /// AirPlay connect before switching), so ".stillOurs" is just the resting state —
    /// resuming on it re-grabs the ports and re-blocks the user's retry (live-found
    /// loop, 2026-08-07). A userDeselected release starts with this `true` (the
    /// deselect IS the departure); a blockedAttempt release starts `false` and it
    /// flips only on an observed genuine departure. `stateQueue`.
    private var defaultLeftUsSinceRelease = true

    /// The blocked-AirPlay-attempt watcher (Seamless handoff T3) — runs only while
    /// we might plausibly be holding the PTP ports against a real routing intent
    /// (see `reconcileHandoffWatcherLocked`). `stateQueue`.
    private var handoffWatcher: AirPlayHandoffWatcher?

    /// The release's own `engine.removeOutput` teardown, as ONE task (D2, adversarial
    /// review). Resume's `convergeDevice` kicks are unordered against the engine
    /// actor relative to this — a stale removal could otherwise land after the
    /// resumed add and kill the fresh session — so a resume kick awaits this task's
    /// value FIRST (off `stateQueue`) before converging. Cleared by
    /// `resumeFromHandoffLocked()` and `stop()`. `stateQueue`.
    private var handoffTeardown: Task<Void, Never>?

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

    /// The takeover status strip's current state (T6, PLAN-AIRPLAY-COEXISTENCE.md),
    /// or `nil` when there's nothing to explain. Set only from ``setTakeoverStatus(_:)``,
    /// which is the edge-triggered emit point — mirrors ``systemAirPlayGuardActive``'s
    /// discipline so the strip can never strand showing a stale "taking over" state.
    /// Confined to `stateQueue`.
    private var takeoverStatus: TakeoverStatus?

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

    /// How long a Cast row keeps `isAvailable` after a browse stops listing it
    /// (CAST-ENUM). Injectable so tests shrink it; never mutated after init.
    private let castAbsenceGrace: TimeInterval

    /// The default Cast absence grace (seconds). A wired receiver's Bonjour
    /// advert reaches the Mac only intermittently, so ONE browse that omits it
    /// is a blip, not a departure — and a row that greys out reads as disabled
    /// in the popover. A grace TIMER rather than a count of consecutive
    /// omissions: the browse is event-driven (`NWBrowser.browseResultsChanged`),
    /// so nothing guarantees a second browse ever arrives, and a count-based
    /// debounce would leave a departed receiver listed as available forever.
    public static let defaultCastAbsenceGrace: TimeInterval = 3

    /// The armed silence-watchdog countdown. Cancelled when a desired device
    /// reconnects, the intent clears, on a sleep/wake cycle, or on `stop()`.
    private var silenceWatchdog: SilenceWatchdogToken?

    /// Injectable timer seam for the silence watchdog so hermetic tests fire the
    /// countdown deterministically. Defaults to a real `DispatchQueue.asyncAfter`
    /// wrapper (see the designated initializer). Never mutated after init.
    private let watchdogScheduler: SilenceWatchdogScheduling

    /// The armed scheduling snapshot polling work item, scheduled on `stateQueue`.
    /// Polls every ~5s while capture is active; cancelled on `stop()` or when
    /// capture goes idle. Used by T2 to bridge scheduling metrics to telemetry.
    private var schedulingSnapshotPollWork: DispatchWorkItem?
    /// How many `send_sched` lines THIS backend has logged. Arming is not the
    /// same observable: an arm whose poll then finds capture stopped logs
    /// nothing, so the guard this counts for is "no second line per
    /// capture-start episode". Counting the telemetry itself cannot work — the
    /// sink is process-global and the event carries no backend identity, so
    /// any other still-polling backend in the same test process lands lines in
    /// the counting window.
    private var schedulingSnapshotLogCount = 0

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

    /// Ids whose next add-success should take the CONFIGURED CONNECT DEFAULT rather
    /// than the level the device was already streaming at (F-REBIND). Armed by
    /// `setOutputSet` on the user's off→on edge — the one place a connect is
    /// USER-intended — and consumed by ``connectVolumeSeed(_:outputID:)``.
    ///
    /// Everything else that re-issues an `addOutput` for a device the user never
    /// turned off leaves it unarmed. The case this exists for: a Bluetooth headset
    /// connecting makes macOS fire a burst of default-output-device changes, each
    /// rebuilding the whole-system tap, each firing a session rebind
    /// (`resetAirPlaySessionForWholeSystem` → removeOutput → addOutput). The engine's
    /// `.stopped` drops the id from `added`, so the following `.connected` reads
    /// `wasAdded == false` and looks exactly like a fresh connect — which used to
    /// slam a Sonos the user had set to 80% back to the 35% connect default, once per
    /// notification. Intent is the honest discriminator here: `added`/`known` can't
    /// tell the two apart (every discovered device already carries a volume — the
    /// `Device` default is 50), and a window flag keyed on the recovery chain's
    /// lifetime would race the state-stream events that arrive after it clears.
    ///
    /// One-shot token, so neither failure direction can hurt: a missed arm means a
    /// user connect keeps the last level (audible, just not the default), and a
    /// missed consume means the next rebind reseeds (today's behavior). Nothing here
    /// can produce silence — the seed always pushes a level either way. Note this is
    /// the INVERSE of the `volumeSeeded: Set` the seed's doc warns about: that one
    /// suppressed a seed while set and had to be hand-cleared at every teardown,
    /// whereas this one is consumed on use and only ever selects WHICH level is
    /// pushed.
    private var userConnectSeed: Set<String> = []

    private var stateStreamTask: Task<Void, Never>?

    /// Drains the engine's remote-control stream (speaker transport keys). Same
    /// `stateQueue` confinement as ``stateStreamTask``.
    private var remoteEventStreamTask: Task<Void, Never>?

    /// The sender-side DACP endpoint: how a volume change made ON THE SPEAKER
    /// reaches us (the receiver calls this back — see ``DACPServer``). Started in
    /// `start()` with the engine's DACP-ID so its advertised `iTunes_Ctrl_<id>`
    /// matches what the engine tells receivers. Volume travels here, not the RTSP
    /// event channel — confirmed against the AirPlay spec + OwnTone's httpd_dacp.
    /// Injectable behind ``DACPEndpoint`` (same discipline as `discovery`) so the
    /// hermetic suite never binds the real `NWListener`/Bonjour advert — see the
    /// protocol's doc comment.
    private let dacpServer: DACPEndpoint

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

    /// The destination sets `handleDestinationSetsChanged` last ran with, cached so
    /// device DISCOVERY can re-drive the binding for a target that wasn't known yet
    /// when the routes were applied (see the re-drive in `addOrUpdate`). Cached
    /// rather than re-read from `routeMixer.destinationSets` because that accessor
    /// takes the MIXER's queue, and this is read while already holding `stateQueue`
    /// — the cache keeps the discovery path single-queue. Written only inside
    /// `handleDestinationSetsChanged`'s own `stateQueue` critical section.
    private var lastDestinationSets: [AppRouteMixer.DestinationSet] = []

    /// Mixed-buffer counter driving the rate-limited write-backlog sampling (see
    /// `sampleWriteBacklogIfDue`). Confined to the mixer's `onMixedBuffer` queue.
    private var backlogSampleCounter = 0
    /// Last `droppedWrites` total reported to Telemetry, so the sampler emits only
    /// on change instead of once per sample. Same queue confinement as above.
    private var lastReportedDroppedWrites: UInt64 = 0

    /// Mixed-buffer counter driving the rate-limited write-CADENCE sampling
    /// (see `sampleWriteCadenceIfDue`) — its OWN counter, independent of
    /// `backlogSampleCounter` above, mirroring how `EngineSink`'s own backlog
    /// sampler (`NativeCaptureCoordinator.swift`, commit `9965bd9`) keeps its
    /// own counter rather than sharing one across samplers. Confined to the
    /// mixer's `onMixedBuffer` queue.
    private var cadenceSampleCounter = 0
    /// Last cumulative deficit/overrun seconds reported to Telemetry, so the
    /// sampler emits only when the cadence has actually degraded further
    /// since the last sample, not once per sample. Same queue confinement.
    private var lastReportedCadenceDeficitSeconds: Double = 0
    private var lastReportedCadenceOverrunSeconds: Double = 0

    /// deviceID → the sorted app display names last published via `.routedApps`, so
    /// the event fires only when a device's live app mapping actually changes.
    private var routedAppNames: [String: [String]] = [:]

    /// FIFO chain that serializes the per-app engine bind ops. Each new op awaits
    /// the previous one's completion before running, so a device's stop→re-add on a
    /// stream change can never interleave with a later change's ops. Confined to
    /// `stateQueue` (submitted in decision order under the lock), mirroring how
    /// `captureControlQueue` replays capture-gate decisions in order.
    private var bindTail: Task<Void, Never> = Task {}

    // MARK: Scope arbiter (roadmap 008 — whole-system priority, all on `stateQueue`)

    /// Device ids whose `.unbind` op was DEFERRED because a whole-system converge
    /// op was in flight for the device (`performBindOp`'s four-case unbind arm,
    /// case 3): the converge's outcome — success vs park — decides what the right
    /// teardown would have been, and is unknowable while it runs. Consumed on the
    /// whole-system release path (`releaseConvergingAndRequeueIfNeeded`, release
    /// WITHOUT requeue) by re-enqueuing the `.unbind`, whose fire-time
    /// classification then settles it against the post-converge world. A
    /// deferred-op note in the exact species of `pendingRebindRecoveries` — never
    /// an ownership map: a stale entry costs one redundant re-classification that
    /// finds no claim and issues a tolerated no-op removeOutput. Cleared in
    /// `stop()` and by the sleep suspension handler (sleep tears every session
    /// down, so there is nothing left to settle).
    private var pendingScopeSettles: Set<String> = []

    /// The currently ACTIVE scope conflicts (device id → record): `.device` routes
    /// demoted because whole-system routing claims their target. DIAGNOSTIC ONLY —
    /// written on the engage edge, removed on disengage, cleared in `stop()`,
    /// exposed via ``test_scopeConflict(deviceID:)``; never read by any decision
    /// path (deliberately NOT a third bookkeeping system — the existing maps ARE
    /// the claims).
    private var lastScopeConflicts: [String: ScopeConflict] = [:]

    /// A queryable record of one active whole-system-vs-per-app scope conflict
    /// (roadmap 008): the device is whole-system-claimed (a Selected Device) while
    /// the user's route table still `.device`-routes the listed apps to it, so
    /// those routes are demoted (effective `.noRedirect`) for the duration and the
    /// apps play in the whole-system mix instead. The record is removed the moment
    /// the conflict disengages (deselect or route edit). Diagnostic only.
    struct ScopeConflict: Equatable {
        /// Always `"routeDemoted"` while the record exists — restore removes it.
        let stage = "routeDemoted"
        /// The demoted routes' bundle ids, sorted.
        let bundleIDs: [String]
        /// The per-app stream the device was bound to when the conflict engaged,
        /// if any.
        let stream: UInt32?
        let date: Date
    }

    // MARK: Per-app routing edge cases (T8)
    //
    // Three gaps the happy-path T6/T7 build didn't cover:
    //  1. A routed app's PROCESS quits mid-stream. Core Audio never signals this
    //     (a per-process tap on a dead pid doesn't error or EOF) — the only
    //     detection is `NSWorkspace.didTerminateApplicationNotification`, which
    //     Core can't call itself. `handleAppTerminated(bundleID:)` is the AppKit
    //     boundary's forwarding target (mirrors the `processResolver` injection).
    //  2. The DEVICE a route targets disappears ENTIRELY. Flows end-to-end through
    //     the existing generic pipeline — `AppRoutingController.handleDeviceDisappeared`
    //     (fired from `PopoverController.update(devices:)`, PLAN decision 7) resets
    //     the persisted route to `.noRedirect` and fires `onRoutesDidChange`,
    //     which reaches `updateAppRoutes` below exactly like any other route edit.
    //     No new state needed here — `NativeBackendTests.
    //     testDeviceUnavailableTearsDownBackendCaptureViaAppRoutingController`
    //     proves the two layers stay in sync (T10).
    //     Its NARROWER sibling — the target is still discovered but reports
    //     `isAvailable == false` — deliberately does NOT reset the route (R5).
    //     `effectiveAppRoutesLocked` demotes it for the duration instead, so the
    //     app rejoins the whole-system mix while the intent survives, and
    //     `rerunAppRoutesForReachabilityChange` re-engages it on recovery.
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

    /// How many whole-system-tap `.failed` retries have already fired in a row
    /// (T16, E10) — kept ONLY to grow the capped-exponential backoff delay, not
    /// as a give-up ceiling: unlike the per-app `retryCounts` (keyed per bundle
    /// ID, one entry per routed app), there is exactly ONE whole-system tap, so
    /// this is a single counter. Reset to 0 on recovery (`.capturing`) and on a
    /// deliberate deselect (`reconcileCaptureGate`'s stop branch clears the
    /// pending timer; `stop()` resets the counter alongside it). Confined to
    /// `stateQueue`.
    private var captureRetryCount = 0

    /// The whole-system tap's in-flight bounded retry (T16, E10), so a second
    /// `.failed` while one is already scheduled REPLACES rather than stacks it —
    /// the single-flighting requirement — and a recovery (`.capturing`) or a
    /// deliberate deselect can cancel it before it fires. Best-effort (a work
    /// item already running when cancelled still completes, same D4 tolerance as
    /// `pendingRetries`). Confined to `stateQueue`.
    private var pendingCaptureRetry: DispatchWorkItem?

    /// Whether a `.captureFailed` note is currently showing in the popover, so
    /// the clear event is emitted exactly once, on the edge that actually
    /// retires the condition (recovery, or capture stopping being desired).
    /// Confined to `stateQueue`.
    private var captureFailureNoteActive = false

    /// Base delay before the FIRST whole-system-tap `.failed` retry (T16, E10),
    /// and the seed of its capped-exponential backoff (doubled per attempt,
    /// capped at `captureRetryMaxBackoff`) — mirrors
    /// `processNotYetAudibleRetryDelay`'s shape exactly, but kept as its own
    /// knob since the whole-system tap and the per-app taps are unrelated
    /// subsystems with independently tunable recovery timing. `var`-free `let`,
    /// injectable only through the designated initializer so tests can shrink
    /// it; production never needs to.
    private let captureRetryDelay: TimeInterval

    /// Ceiling for the whole-system-tap retry backoff (T16, E10) — mirrors
    /// `processNotYetAudibleMaxBackoff`: the delay doubles each attempt but
    /// never exceeds this, so a tap that stays `.failed` (e.g. the TCC grant
    /// hasn't been (re-)completed yet) is re-probed forever on a bounded
    /// interval rather than being permanently given up on — matching this
    /// file's existing indefinite-retry philosophy for a condition the user,
    /// not a fixed retry count, ultimately resolves.
    private let captureRetryMaxBackoff: TimeInterval

    /// Test-only (`@testable`): whether a `.processNotYetAudible` retry
    /// `DispatchWorkItem` is currently sitting in `pendingRetries` for
    /// `bundleID` — lets a test prove the map doesn't leak a stale reference
    /// past a non-retryable failure.
    func test_hasPendingRetry(bundleID: String) -> Bool {
        stateQueue.sync { pendingRetries[bundleID] != nil }
    }

    /// Test-only (`@testable`): whether a rebind-recovery retry
    /// `DispatchWorkItem` is currently sitting in `pendingRebindRecoveries`
    /// for `deviceID` — lets a test prove the map doesn't leak a stale
    /// reference past a superseding topology-driven `.rebind`.
    func test_hasPendingRebindRecovery(deviceID: String) -> Bool {
        stateQueue.sync { pendingRebindRecoveries[deviceID] != nil }
    }

    /// Test-only (`@testable`): whether a whole-system-tap `.failed` retry
    /// `DispatchWorkItem` (T16, E10) is currently sitting in
    /// `pendingCaptureRetry` — lets a test prove a `.failed` schedules exactly
    /// one in-flight retry (single-flighting) and that it's cancelled on
    /// recovery (`.capturing`) or a deliberate deselect.
    func test_hasPendingCaptureRetry() -> Bool {
        stateQueue.sync { pendingCaptureRetry != nil }
    }

    /// Test-only (`@testable`): whether the scheduling-snapshot poll (T2,
    /// `send_sched` telemetry) currently has a work item scheduled in
    /// `schedulingSnapshotPollWork` — lets a test prove the poll (re-)arms on
    /// the `captureRunning` false→true edge and is cancelled on the true→false
    /// edge, mirroring `test_hasPendingCaptureRetry()` above.
    func test_hasPendingSchedulingPoll() -> Bool {
        stateQueue.sync { schedulingSnapshotPollWork != nil }
    }

    /// Test-only (`@testable`): how many `send_sched` lines this backend has
    /// logged. Proves "selecting a second device while already capturing must
    /// not double the log rate" without reading the telemetry sink, which is
    /// process-global and unattributable — see ``schedulingSnapshotLogCount``.
    func test_schedulingPollLogCount() -> Int {
        stateQueue.sync { schedulingSnapshotLogCount }
    }

    /// Test-only (`@testable`): the whole-system-tap retry attempt counter
    /// (T16, E10) — lets a test prove the backoff actually grows across
    /// consecutive failures (rather than resetting or stacking) and resets to 0
    /// on recovery.
    func test_captureRetryCount() -> Int {
        stateQueue.sync { captureRetryCount }
    }

    /// Test-only (`@testable`): whether `bundleID` is currently recorded in
    /// `everCapturedBundleIDs`. Asserted DIRECTLY (rather than via an
    /// engine-bind side effect) because `resetAirPlaySessionForRoutedApp` —
    /// the consumer of a stale entry here — is a guaranteed no-op via its own
    /// `routeMixer.streamID(for:)` guard when triggered from
    /// `handleAppLaunched`'s synchronous relaunch path (the topology republish
    /// that would bind a stream hasn't run yet), so a test built on engine
    /// binds alone cannot distinguish a fixed `handleAppTerminated` from a
    /// broken one for that path.
    func test_hasEverCaptured(bundleID: String) -> Bool {
        stateQueue.sync { everCapturedBundleIDs.contains(bundleID) }
    }

    /// The devices whose `converging` slot is held by a WHOLE-SYSTEM rebind
    /// recovery rather than by a `convergeDevice` loop. `converging` is one
    /// serialization domain shared by both (Finding 1), but only the recovery's
    /// hold is ours to drop out-of-band: `handleSystemWillSleep` abandons in-flight
    /// recoveries, and it must release exactly the slots those recoveries claimed —
    /// removing a slot a live `convergeDevice` loop owns would let a second kick
    /// interleave engine ops for the same device. Per-app-scope recoveries never
    /// claim a slot, so they never appear here.
    private var rebindConverging: Set<String> = []

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
    ///
    /// This is also where the T5 takeover switch-away is opted in: the real
    /// (HAL-writing) ``DefaultOutputSwitcher`` exists ONLY on this shipping
    /// path, never on the designated initializer's default — see
    /// ``defaultOutputSwitcher``.
    public convenience init(
        engine: AirPlayEngine,
        discovery: NativeDiscovery = NativeDiscovery(),
        processResolver: AudioProcessResolver = AudioProcessResolver(enumerator: NoAudioProcesses())
    ) {
        self.init(
            engineControl: EngineAdapter(engine: engine),
            discoverySource: discovery,
            btEnumerator: BTDeviceEnumerator.production(),
            btConnectionManager: BTConnectionManager(),
            castEnumerator: CastDeviceEnumerator(),
            castOutputManager: CastOutputManager(),
            btTrimStore: BTTrimStore(),
            castOffsetStore: BTTrimStore(fileName: BTTrimStore.castFileName),
            eqStore: DeviceEQStore(),
            processResolver: processResolver,
            defaultOutputSwitcher: DefaultOutputSwitcher())
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
    /// `captureRetryDelay`/`captureRetryMaxBackoff` (T16, E10) tune the equivalent
    /// backoff for the WHOLE-SYSTEM tap's `.failed` retry — a separate knob since
    /// it's an unrelated subsystem; tests shrink it the same way.
    init(
        engineControl: EngineControlling,
        discoverySource: DiscoverySource,
        btEnumerator: BTDeviceEnumerating? = nil,
        btConnectionManager: BTConnectionManaging? = nil,
        castEnumerator: CastDeviceEnumerating? = nil,
        castOutputManager: CastOutputControlling? = nil,
        btTrimStore: BTTrimStore? = nil,
        castOffsetStore: BTTrimStore? = nil,
        eqStore: DeviceEQStore? = nil,
        dacpEndpoint: DACPEndpoint = DACPServer(),
        systemVolume: SystemVolumeControlling = SystemOutputVolume(),
        ptpHelperActivator: PTPHelperActivating = PTPHelperActivator(),
        connectVolume: @escaping @Sendable () -> Int = { AppSettings().connectVolume },
        processResolver: AudioProcessResolver = AudioProcessResolver(enumerator: NoAudioProcesses()),
        injectedPerAppCapture: PerAppCaptureCoordinator? = nil,
        injectedMeteringCapture: PerAppCaptureCoordinator? = nil,
        processNotYetAudibleRetryDelay: TimeInterval = 2.0,
        processNotYetAudibleMaxBackoff: TimeInterval = 10.0,
        maxRebindRecoveryAttempts: Int = 3,
        rebindRecoveryRetryDelay: TimeInterval = 0.5,
        captureRetryDelay: TimeInterval = 2.0,
        captureRetryMaxBackoff: TimeInterval = 10.0,
        takeoverStripDelay: TimeInterval = 0.75,
        watchdogScheduler: SilenceWatchdogScheduling? = nil,
        silenceFallbackDelay: TimeInterval = NativeBackend.defaultSilenceFallbackDelay,
        castAbsenceGrace: TimeInterval = NativeBackend.defaultCastAbsenceGrace,
        systemDefaultOutputIsAirPlayClass: @escaping @Sendable () -> Bool = NativeBackend.currentDefaultOutputIsAirPlayClass,
        defaultOutputSwitcher: DefaultOutputSwitcher? = nil,
        aggregateControl: AggregateDeviceControlling = CoreAudioAggregateDeviceControl(),
        currentDefaultOutputUID: @escaping @Sendable () -> String? = NativeBackend.currentDefaultOutputUID,
        ptpHelperReleaser: PTPHelperReleasing = PTPHelperReleaser(),
        handoffWatcherFactory: @escaping @Sendable (@escaping @Sendable () -> Void) -> AirPlayHandoffWatcher = { AirPlayHandoffWatcher(onBlockedAttempt: $0) }
    ) {
        self.ptpHelperReleaser = ptpHelperReleaser
        self.handoffWatcherFactory = handoffWatcherFactory
        self.defaultOutputSwitcher = defaultOutputSwitcher
        self.aggregateControl = aggregateControl
        // Injectable init keeps the AggregateOutputDevice built from the SAME
        // control we hold, so its pure decisions and our HAL writes never diverge.
        self.publicAggregate = AggregateOutputDevice(control: aggregateControl)
        self.currentDefaultOutputUIDProvider = currentDefaultOutputUID
        // Default the silence-watchdog timer to a real dispatch-queue wrapper. Its
        // scheduled body always hops onto `stateQueue` itself (see `armSilenceWatchdog`),
        // so this queue only needs to time the delay — a plain serial queue is fine.
        self.watchdogScheduler = watchdogScheduler
            ?? DispatchSilenceWatchdogScheduler(queue: DispatchQueue(label: "NativeBackend.silenceWatchdog"))
        self.silenceFallbackDelay = silenceFallbackDelay
        self.castAbsenceGrace = castAbsenceGrace
        self.engine = engineControl
        self.discovery = discoverySource
        self.btEnumerator = btEnumerator
        self.btConnectionManager = btConnectionManager
        self.castEnumerator = castEnumerator
        self.castOutputManager = castOutputManager
        self.btTrimStore = btTrimStore
        if let loaded = (try? btTrimStore?.load()) ?? nil {
            self.btTrimsByUID = loaded.mapValues { BTSyncTrim.clamp($0) }
        }
        if let latencies = (try? btTrimStore?.loadLatencies()) ?? nil {
            self.btLatencyMsByUID = latencies.mapValues { Swift.max(0, $0) }
        }
        if let dismissed = try? btTrimStore?.loadDismissedUIDs() {
            self.btAlignmentDismissedUIDs = dismissed
        }
        self.castOffsetStore = castOffsetStore
        if let castOffsets = (try? castOffsetStore?.load()) ?? nil {
            self.castOffsetsByID = castOffsets.mapValues {
                BTSyncTrim.quantise($0, rangeMs: BTSyncTrim.castRangeMs)
            }
        }
        self.eqStore = eqStore
        if let loaded = (try? eqStore?.load()) ?? nil {
            self.storedMainOutEQ = loaded.mainOut ?? .flat
            self.eqByDeviceID = loaded.devices
        }
        self.dacpServer = dacpEndpoint
        self.systemVolume = systemVolume
        self.ptpHelperActivator = ptpHelperActivator
        self.connectVolumeProvider = connectVolume
        self.systemDefaultOutputIsAirPlayClassProvider = systemDefaultOutputIsAirPlayClass
        self.perAppCapture = injectedPerAppCapture ?? PerAppCaptureCoordinator(processResolver: processResolver)
        // The metering-only tap (T3, third `.appLevel` source): its OWN coordinator,
        // built `.unmuted` and with a distinct aggregate-device name so it never
        // collides with `perAppCapture`. Same injected `processResolver`. Tests can
        // script it via `injectedMeteringCapture` (mirrors `injectedPerAppCapture`).
        self.meteringCapture = injectedMeteringCapture
            ?? PerAppCaptureCoordinator(processResolver: processResolver, name: "AudioutMeter", muteBehavior: .unmuted)
        self.routeMixer = AppRouteMixer()
        self.processNotYetAudibleRetryDelay = processNotYetAudibleRetryDelay
        self.processNotYetAudibleMaxBackoff = processNotYetAudibleMaxBackoff
        self.maxRebindRecoveryAttempts = maxRebindRecoveryAttempts
        self.rebindRecoveryRetryDelay = rebindRecoveryRetryDelay
        self.captureRetryDelay = captureRetryDelay
        self.captureRetryMaxBackoff = captureRetryMaxBackoff
        self.takeoverStripDelay = takeoverStripDelay

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
            // BACKPRESSURE VISIBILITY (diagnostic): the engine's write guard can
            // silently DROP audio once a stream's un-drained backlog hits its cap
            // — audible as "dropped milliseconds" that the routing telemetry above
            // can never explain (no rebuild, no reset, nothing logged). Sample the
            // guard's counters here, but RATE-LIMITED and only emitting on CHANGE:
            // this closure runs per mixed buffer (mixer queue, RT-adjacent), and
            // `Telemetry` must never be called at buffer cadence. One cheap
            // counter increment per buffer; a snapshot read + possible log only
            // once every `backlogSampleInterval` buffers.
            self?.sampleWriteBacklogIfDue()
            // CADENCE VISIBILITY (T-ENG-CADENCE-1, whole-system-dropout
            // investigation): same rationale and throttling as the backlog
            // sample above, for the engine's write-cadence deficit/overrun
            // counters instead of its backpressure-drop counter, tagged
            // `path: "perApp"` — `EngineSink.write` in
            // `NativeCaptureCoordinator.swift` mirrors this for stream 0
            // (`path: "wholeSystem"`), so this event now has full coverage
            // whether or not any per-app route is active.
            self?.sampleWriteCadenceIfDue()
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

    // STABILITY(C8): main thread blocks on the state queue for slow work — see dev/notes/stability-audit-2026-07-18.md
    public var mainOutEQ: DeviceEQ {
        stateQueue.sync { storedMainOutEQ }
    }

    /// Whether the last connect attempt found the PTP helper's clock ready
    /// (T4, PLAN-AIRPLAY-COEXISTENCE.md). `true` before any connect has been
    /// attempted. A connect that finds it `false` is hard-failed (see
    /// `convergeDevice`'s `ptpHelperActivator` check and
    /// `ConnectionFailure.Cause.timingUnavailable`) rather than left
    /// degraded — a PTP-only receiver (Sonos et al, SPEC.md §8 0b) plays
    /// silence with no clock, so a degraded-but-"connected" state would be
    /// worse than an honest failure.
    public var isPTPClockAvailable: Bool {
        stateQueue.sync { ptpClockAvailable }
    }

    /// The Mac's current system output volume, or `nil` when the default output has
    /// no readable volume control. Served from ``lastSeenSystemVolume`` (seeded by
    /// `start()`'s HAL read, kept fresh by `onExternalChange`) rather than a fresh
    /// blocking HAL read, so a main-thread caller never waits on coreaudiod.
    public var systemOutputVolume: Int? {
        stateQueue.sync { lastSeenSystemVolume }
    }

    /// Publish who owns the volume right now (``BackendEvent/systemVolumeOwnershipChanged(_:)``).
    ///
    /// MUST be called on `stateQueue` — it reads `lastSeenSystemVolume`, which is
    /// only ever mutated there. Takes the default-output UID as a parameter
    /// rather than reading it, so callers that already resolved it (the
    /// default-changed path has it in hand) don't pay for a second HAL round trip.
    private func publishVolumeOwnershipLocked(defaultOutputUID: String?) {
        let owned = VolumeOwnership.weOwnVolume(
            defaultOutputUID: defaultOutputUID,
            systemOutputVolume: lastSeenSystemVolume)
        emit(.systemVolumeOwnershipChanged(owned))

        guard owned != weOwnSystemVolume else { return }
        weOwnSystemVolume = owned
        // Main has just moved into or out of the Mac's sink gain, so the gain the
        // sink is holding is now computed by the wrong formula. Nothing else will
        // notice — re-push it here or the Mac keeps playing at the old level until
        // some unrelated change happens to push again.
        pushSyncedLocalGain()
    }

    /// Whether we — not macOS — own the volume, mirroring the last published
    /// ``BackendEvent/systemVolumeOwnershipChanged(_:)``. On `stateQueue`.
    ///
    /// Read by ``syncedLocalGain``: while this is true the Mac's own output sits
    /// behind our aggregate, so the system volume no longer applies Main to it and
    /// Main has to be folded into the sink gain instead.
    private var weOwnSystemVolume = false

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
        // A READ, never a write: this publishes Main's launch value through
        // `systemOutputVolume` (Main ADOPTS the Mac's actual level at launch, with
        // the persisted `AppSettings.mainOutVolume` as the fallback for the `nil`
        // case — an HDMI/aggregate output with no settable volume). Opening the app
        // must not move the user's volume, so nothing is written back here.
        let localVolume = systemVolume.currentVolume()
        let localMuted = systemVolume.currentMuted()
        stateQueue.async {
            guard !self.started else { return }
            self.started = true
            self.lastSeenSystemVolume = localVolume
            // Surface the Mac's OWN current output device immediately (BUG B), so
            // the popover has a "Current Device" row and GroupController can seed
            // the local-passthrough default the moment `start()` runs — before any
            // AirPlay discovery, and independent of whether the engine comes up.
            // It is NEVER fed to the engine or `addOutput`-ed: it's the local
            // output, not an AirPlay receiver (guarded everywhere by
            // `isLocalDevice`, and it has no `outputIDs` entry to add).
            self.surfaceLocalDevice(name: localName, muted: localMuted)

            // Wave 3 T5: make the public "Audiout" aggregate VISIBLE in Sound
            // settings at launch (Q1) — SWEEP any orphan left by a prior crash or
            // the spike tool FIRST (Q3), then adopt-or-create. Deliberately NOT
            // made the Mac's default output here: that happens only once the user
            // actually routes audio through the app (see `reconcileAggregateDefault`).
            // razor: create-only at launch; no default takeover, no volume surface.
            self.publicAggregate.sweepOrphans()
            _ = self.publicAggregate.adoptOrCreate()
            self.aggregateDefaultActive = false
            self.priorDefaultUID = nil
            self.expectedDefaultWriteUID = nil
            self.routingBlockedEmitted = false

            // Seed volume ownership. Without this the only signal is a default-
            // output CHANGE, so an aggregate left as the default by a previous
            // session would never announce itself and the key interceptor would
            // never install — dead volume keys for the whole launch. Safe here and
            // nowhere earlier: `lastSeenSystemVolume` was populated above, so the
            // nil arm of the predicate can't misfire on a launch transient.
            self.publishVolumeOwnershipLocked(
                defaultOutputUID: self.currentDefaultOutputUIDProvider())
        }

        // 1. Wire discovery → the app model + the engine descriptor feed. Every
        //    reachable receiver — AP1 or AP2 — gets fed to `engine.updateDiscovery`
        //    so the engine knows about it (a prerequisite for `addOutput`). Only the
        //    local Mac output is never fed (it isn't a discovered receiver).
        discovery.onEvent = { [weak self] event in self?.handleDiscovery(event) }

        // 1a. Bluetooth outputs (BT-ENUM) flow through the SAME add/update/emit
        //     path as AirPlay rows, from their own enumerator. Started here, not
        //     inside the engine Task below: BT rows don't depend on the AirPlay
        //     engine any more than the local row does.
        if let btEnumerator {
            btEnumerator.onSnapshot = { [weak self] snapshots in
                self?.stateQueue.async { self?.applyBTSnapshots(snapshots) }
            }
            btEnumerator.start()
        }

        // 1a-CONNECT: IOBluetooth connect/disconnect edges re-enumerate right
        //     away — the baseband edge lands before the Core Audio device-list
        //     listener echoes the endpoint appearing/vanishing, so the row's
        //     greyed state moves as fast as the OS knows. TCC-gated inside the
        //     manager (an ungranted IOBluetooth touch kills the process).
        if let btConnectionManager {
            btConnectionManager.onConnectionsChanged = { [weak self] in
                self?.btEnumerator?.refresh()
            }
            // Wave 4: the ~5 s "offer Bluetooth Settings" nudge. Telemetry-only
            // until the UI wave hangs the row affordance off it
            // (`SystemSettingsPane.bluetooth` is the destination).
            btConnectionManager.onFallbackSuggested = { address in
                Telemetry.log(.localPlayback, "bt_connect_fallback_suggested", ["address": address])
            }
            btConnectionManager.startObservingConnections()
        }

        // 1a-CAST: Cast receivers (CAST-ENUM) take the same route as BT rows —
        //     their own browse feeding `applyCastSnapshots` on `stateQueue`, and
        //     the session manager's state changes feeding `applyCastSessionState`
        //     on the same queue, so a row's `.connecting`/`.connected`/`.failed`
        //     is decided in exactly one place.
        if let castEnumerator {
            castEnumerator.onSnapshot = { [weak self] records in
                self?.stateQueue.async { self?.applyCastSnapshots(records) }
            }
            castEnumerator.start()
        }
        if let castOutputManager {
            castOutputManager.onStateChange = { [weak self] id, state in
                self?.stateQueue.async { self?.applyCastSessionState(id, state) }
            }
            castOutputManager.onVolumeLagChange = { [weak self] id, lag in
                self?.stateQueue.async { self?.applyCastVolumeLag(id, lag) }
            }
            castOutputManager.onLeadSample = { [weak self] id, leadMs in
                self?.stateQueue.async { self?.applyCastLeadSample(id, leadMs) }
            }
        }

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
                let previousVolume = self.lastSeenSystemVolume
                // nil = that control is unreadable on this device; leave the last
                // known value rather than fabricating a 0/false.
                if let volume { self.lastSeenSystemVolume = volume }
                self.applyLocal(Self.localDeviceID) { device in
                    device.name = name
                    // `device.volume` is deliberately NOT synced from the system
                    // level any more: the local row is the Mac's OWN fader (a trim
                    // under Main), and Main Out is what owns the Mac's hardware
                    // level. Mute IS still real hardware mute, so it keeps syncing.
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
                //       The basis is `lastSeenSystemVolume` (the last SYSTEM level we
                //       saw), NOT the local row's `Device.volume`: that row no longer
                //       tracks the system, so comparing against it would swallow a
                //       genuine change whenever the Mac's own fader happened to sit
                //       at the new system level, and Main would miss it.
                //     Echoes of our OWN writes never arrive here at all —
                //     `SystemOutputVolume` suppresses those by comparing a fresh read
                //     against its last-known state, which is why no flag is needed to
                //     tell the volume keys from our own slider.
                if !defaultDeviceChanged, let volume, volume != previousVolume {
                    self.emit(.systemVolumeChanged(volume: volume))
                }
                // The volume/media KEYS themselves are not intercepted here, and
                // must not be: the CGEventTap lives in the app target, because a
                // tap needs a run loop and an Accessibility grant that this layer
                // has no business owning. What this file DOES owe it is the gate —
                // `.systemVolumeOwnershipChanged`, published below on every
                // default-output change. See
                // `docs/plans/PLAN-VOLUME-KEY-INTERCEPTION.md`.

                // 1d. W3-T3: the default output device itself may have just BECOME (or
                //     stopped being) AirPlay-class — re-evaluate the double-path guard.
                //     A same-device volume/mute gesture (`defaultDeviceChanged == false`)
                //     can't change the transport type, so skip the query on that far more
                //     frequent path.
                if defaultDeviceChanged {
                    self.reconcileSystemAirPlayGuard()

                    // 1e. Wave 3 T5: the default output DEVICE changed. Read its UID
                    //     once. If it's the echo of our OWN set-default write (to the
                    //     aggregate on activation, or the prior device on restore),
                    //     CONSUME it — `SystemOutputVolume`'s echo suppression covers
                    //     only its own volume writes, not this default-device write, so
                    //     without this the app's own takeover would read as a user
                    //     off-switch. Any other change is a real user action → classify
                    //     it against the aggregate and (re)emit the routing-blocked
                    //     warning for the new steady state.
                    let newDefaultUID = self.currentDefaultOutputUIDProvider()

                    // Volume ownership turns on exactly this UID, so republish it
                    // BEFORE the echo test below. Our own switch to the aggregate
                    // is consumed as an echo down there, but it is precisely the
                    // moment we GAIN ownership — skipping it would leave the keys
                    // dead through the whole takeover we just performed.
                    self.publishVolumeOwnershipLocked(defaultOutputUID: newDefaultUID)

                    // No volume push here any more: the Main mirror now names its
                    // target device instead of writing "whatever is default", so it
                    // does not race this async default switch and there is nothing
                    // left to correct after the fact.
                    if self.expectedDefaultWriteUID == newDefaultUID, newDefaultUID != nil {
                        self.expectedDefaultWriteUID = nil
                    } else {
                        // A genuine change that does NOT match the pending write
                        // proves our echo is no longer the newest state — the HAL
                        // coalesces rapid changes, so the echo of a successful write
                        // can be swallowed entirely by a fast user switch-away. A
                        // STALE pending left armed here would mis-consume the user's
                        // NEXT genuine change back to the aggregate as "our own
                        // echo", silently skipping the D1 resume — permanent silence
                        // in exactly the scenario D1 exists for. Disarm it.
                        self.expectedDefaultWriteUID = nil
                        self.evaluateRoutingBlocked()

                        // Seamless handoff T3.4: the user picked a DIFFERENT default
                        // output in Sound settings while we were routing — that IS
                        // their switch-away intent, so free the PTP ports proactively
                        // rather than waiting for a blocked-attempt log line. A `nil`
                        // UID (`.deviceVanished`) is an unplugged device, not a
                        // handoff, and must NOT trigger this. `aggregateDefaultActive`
                        // (mirrors the same guard `stop()`'s restore uses) is required
                        // too: `classifyOffSwitch` reads "userDeselected" for ANY UID
                        // that isn't our aggregate's, including the Mac's ordinary
                        // default the whole time we never actually won the takeover
                        // (aggregate resolve failed, or — in tests — a no-op aggregate
                        // control) — without this an unrelated default-output change
                        // would read as a handoff and tear down real streaming that was
                        // never routed through our aggregate to begin with.
                        if !self.expectedSelected.isEmpty, self.aggregateDefaultActive,
                           self.publicAggregate.classifyOffSwitch(newDefaultUID: newDefaultUID) == .userDeselected {
                            self.releaseForHandoff(reason: "userDeselected", defaultAlreadyLeftUs: true)
                        }

                        // A blocked-attempt release happens with our aggregate STILL
                        // the default (macOS aborts the failed AirPlay connect before
                        // any switch) — so ".stillOurs" is the default's RESTING
                        // state after that release, not evidence of a re-pick. Arm
                        // the D1 resume only once the default has genuinely LEFT us
                        // post-release; before that, a stray default notification
                        // would instantly resume, re-grab the ports, and re-block the
                        // user's retry — the exact loop this release exists to break
                        // (found live 2026-08-07: fail → bounce-back → re-hold →
                        // fail, forever).
                        if self.handoffReleased,
                           self.publicAggregate.classifyOffSwitch(newDefaultUID: newDefaultUID) == .userDeselected {
                            self.defaultLeftUsSinceRelease = true
                        }

                        // D1 (adversarial review): the user putting us back as
                        // default — by ANY means, not just our own "Use Audiout"
                        // button (`reselectAggregateAsDefault`) — is the resume
                        // intent. Without this, re-picking Audiout directly in
                        // Sound settings while a handoff release is in force clears
                        // the routing-blocked banner (via `evaluateRoutingBlocked`
                        // above) with no way left to un-stick `handoffReleased` /
                        // `suspended` — permanent silence with no affordance.
                        // Gated on `defaultLeftUsSinceRelease` (see above): a
                        // userDeselected release sets it true immediately (the
                        // default provably left us — that's what triggered it), so
                        // the original D1 behavior is unchanged there.
                        if self.handoffReleased, self.defaultLeftUsSinceRelease,
                           self.publicAggregate.classifyOffSwitch(newDefaultUID: newDefaultUID) == .stillOurs {
                            let (kicks, teardown) = self.resumeFromHandoffLocked()
                            for (id, out) in kicks {
                                Task { [weak self] in
                                    await teardown?.value
                                    await self?.convergeDevice(id: id, outputID: out)
                                }
                            }
                        }
                    }
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

            // 2b. (T4, superseded by PLAN-AIRPLAY-COEXISTENCE.md's own T4): this
            //     used to read `engine.ptpClockAvailable` here, right after
            //     `start()`. That reading is now ALWAYS false at this point —
            //     the on-demand helper is never touched at launch (Q1=B), so
            //     nothing has bound yet — which would make `isPTPClockAvailable`
            //     permanently and misleadingly false before the user ever tries
            //     a speaker. `self.ptpClockAvailable` is re-sourced instead from
            //     `convergeDevice`'s own `ptpHelperActivator` check, at the one
            //     moment that actually matters: immediately before a real
            //     connect.

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
            //    `noteSystemRMS` is a try-store into a slot the `stateQueue`
            //    drain reads at the display cadence — this closure runs on the
            //    tap's IOProc delivery thread and must not enqueue per buffer.
            self.captureCoordinator?.onLevel = { [weak self] rms in self?.noteSystemRMS(rms) }

            // WIRE the whole-system tap's state machine (T16, E10) so a
            // `.failed` (TCC lost, the aggregate device torn out from under it,
            // a bad ASBD read) drives a capped-exponential-backoff retry instead
            // of staying dead until the user happens to toggle a Selected
            // Device (the only other path that re-invokes `reconcileCaptureGate`).
            // Harmless to wire this early like `onLevel` — it only fires once
            // `reconcileCaptureGate` has actually started the tap.
            self.captureCoordinator?.onStateChange = { [weak self] state in
                self?.handleCaptureCoordinatorStateChange(state)
            }
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

            // T2: Start the scheduling snapshot polling. Polls while capture is active,
            // logging scheduling metrics to telemetry every ~5s. Runs on stateQueue so
            // it is safe from the realtime audio path.
            self.stateQueue.async { self.startSchedulingSnapshotPolling() }
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
        captureCoordinator?.onStateChange = nil
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
        btEnumerator?.onSnapshot = nil
        btEnumerator?.stop()
        btConnectionManager?.onConnectionsChanged = nil
        btConnectionManager?.stopObservingConnections()
        castEnumerator?.onSnapshot = nil
        castEnumerator?.stop()
        castOutputManager?.onStateChange = nil
        castOutputManager?.onVolumeLagChange = nil
        castOutputManager?.onLeadSample = nil
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
            // T6: a stop mid-takeover-attempt must not strand the strip either —
            // there is no more connect for it to explain.
            self.setTakeoverStatus(nil)
            // T1: drop any pending synced-local settle so a debounced transition
            // can't fire against a torn-down backend after stop(). Independent of
            // the watchdog above — this is the synced-local debounce, not R11.
            self.pendingSyncedLocalSettle?.cancel()
            self.pendingSyncedLocalSettle = nil
            self.syncedLocalCoalescedCount = 0
            self.syncedLocalSinkEnabled = false
            self.syncedLocalSinkApplied = false
            // BT-BACKEND: reset the BT decisions; the disable itself is enqueued
            // below alongside the capture stop, so the FIFO's last BT op is the
            // stop (same ordering argument as the coordinator stop).
            self.btSinkEnabled = false
            self.btSelectedUIDs = []
            self.btComposition = BTGroupComposition(airPlayPresent: false, macLocalPresent: false)
            // CAST-OUT: same shape — reset the decisions here, enqueue the
            // teardown below so the FIFO's last Cast op is the disable.
            self.castSelectedIDs = []
            self.castPlaying = []
            // CAST-SYNC: the room delay goes with them. Publishing the AirPlay
            // line away is enqueued below with the rest of the Cast teardown,
            // so a backend that stops and starts again is back to today's exact
            // bytes; without a term there was never a line to remove.
            let hadCastTerm = self.castRoomDelay.setReceivers([])
            // Drop the pending availability grace timers with them: a flip that
            // lands after stop would grey a row nothing is watching any more.
            self.castAbsenceFlips.removeAll()
            // BT-LIFECYCLE: drop every `.connecting` hold and its poll, so no
            // spinner can outlive the backend that would have resolved it.
            self.btRenderPollWork?.cancel()
            self.btRenderPollWork = nil
            self.btConnectingDeadlines.removeAll()
            // W3: drop the alignment holds too — the sinks are going away.
            for work in self.btAlignmentHoldWatchdogs.values { work.cancel() }
            self.btAlignmentHoldWatchdogs.removeAll()
            self.btAlignmentHeldUIDs.removeAll()
            self.btWizardHeldUIDs.removeAll()
            self.suspended = false
            // Seamless handoff T3.8-3: reset the release flag and stop/nil the
            // watcher so no orphan `log` child survives quit (AppDelegate's quit
            // path calls `stop()`).
            self.handoffReleased = false
            self.defaultLeftUsSinceRelease = true
            self.handoffWatcher?.stop()
            self.handoffWatcher = nil
            // D2 (adversarial review): drop the reference — `engine.stop()` below
            // tears down every session anyway, so there is nothing left for a
            // resume kick (there can be none post-stop) to order itself against.
            self.handoffTeardown = nil
            // T2: stop the scheduling snapshot polling.
            self.schedulingSnapshotPollWork?.cancel()
            self.schedulingSnapshotPollWork = nil
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
            self.captureControlQueue.async { [weak self] in
                self?.applyBTSinkTransition(
                    enable: false, uids: [],
                    composition: BTGroupComposition(airPlayPresent: false, macLocalPresent: false))
            }
            self.captureControlQueue.async { [weak self] in
                self?.applyCastTransition(enable: false, records: [], levels: [:])
                if hadCastTerm { self?.captureCoordinator?.setAirPlayPreDelay(ms: 0) }
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
            // The EQ topology describes engine sessions that are being torn down;
            // the VALUES (`eqByDeviceID`/`storedMainOutEQ`) are the user's settings and
            // stay. The allocator stays too — a released stream id is retired for
            // the session, never reused (decision 8). The coordinator goes back to
            // byte-identical passthrough.
            self.eqStreamIDByDevice.removeAll()
            self.eqRebindDeferred.removeAll()
            self.eqSlotByStream.removeAll()
            self.mainOutEQSlot = nil
            if let coordinator = self.captureCoordinator {
                self.captureControlQueue.async { coordinator.setEQPlan(.passthrough) }
            }
            // T8 edge-case tracking resets alongside the rest of the per-app state —
            // a later start() begins with no bundle ID considered dead or mid-retry.
            self.lastRoutes.removeAll()
            self.deadBundleIDs.removeAll()
            self.everCapturedBundleIDs.removeAll()
            self.retryCounts.removeAll()
            for work in self.pendingRetries.values { work.cancel() }
            self.pendingRetries.removeAll()
            // T16/E10: the whole-system tap's own retry resets alongside the
            // per-app one — a later start() re-decides `reconcileCaptureGate`
            // from a clean slate, with no stale attempt count or dangling timer
            // left over from a failure right before teardown.
            self.pendingCaptureRetry?.cancel()
            self.pendingCaptureRetry = nil
            self.captureRetryCount = 0
            // T4: drop any in-flight AirPlay-session rebind recovery — the engine
            // sessions are torn down by `engine.stop()` above and `bindTail` is
            // cancelled, so a fresh start() re-binds from scratch.
            self.rebindRecoveryGen.removeAll()
            for work in self.pendingRebindRecoveries.values { work.cancel() }
            self.pendingRebindRecoveries.removeAll()
            self.rebindConverging.removeAll()
            self.bufferReAdding.removeAll()
            // Roadmap 008: the scope arbiter's deferred-op notes and diagnostic
            // conflict records reset with the rest — the engine sessions they
            // describe are torn down above.
            self.pendingScopeSettles.removeAll()
            self.lastScopeConflicts.removeAll()
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

            // Wave 3 T5: RESTORE the default output the user had before we took it
            // over, THEN DESTROY the public aggregate (stop/quit teardown). Restore
            // by RE-RESOLVING the captured UID to a live id — never a cached
            // AudioObjectID (unstable across resolves, AggregateOutputDevice.swift
            // header). `expectedSelected` is already cleared above, so any resulting
            // default-device echo classifies as "not routing" (no stale warning).
            // Destroying the aggregate while it's still the default makes macOS fall
            // back on its own, so an unresolvable prior is still safe. `systemVolume
            // .onExternalChange` was already detached at the top of `stop()`, so this
            // write raises no echo to guard against.
            //
            // Guard on the aggregate STILL being the current default. `aggregateDefaultActive`
            // only means "we took it over at some point" — if the user has since picked
            // a different output in Sound settings (e.g. AirPods), the default is theirs,
            // not ours, and `priorDefaultUID` is stale. Restoring then would yank the
            // system output off the user's explicit later choice back to the pre-takeover
            // device. Only restore when we genuinely still own the default; otherwise just
            // destroy our (non-default) aggregate below and leave the user's choice intact.
            if self.aggregateDefaultActive,
               self.currentDefaultOutputUIDProvider() == AggregateOutputDevice.productUID,
               let priorUID = self.priorDefaultUID,
               priorUID != AggregateOutputDevice.productUID,
               let priorID = self.aggregateControl.resolveDeviceID(forUID: priorUID) {
                _ = self.aggregateControl.setDefaultOutputDevice(priorID)
            }
            self.publicAggregate.sweepOrphans()   // destroys the productUID aggregate we own
            self.aggregateDefaultActive = false
            self.priorDefaultUID = nil
            self.expectedDefaultWriteUID = nil
            if self.routingBlockedEmitted {
                self.routingBlockedEmitted = false
                self.emit(.routingBlockedNeedsDefault(false))
            }

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
        // nothing). It needs its own branch.
        if id == Self.localDeviceID {
            // This row is the Mac's OWN fader now, not the system volume: writing
            // hardware here belongs solely to the Main path
            // (`setMasterGain(mirrorToSystemVolume: true)`). What this level DOES
            // drive is the delayed local sink's gain, so trimming the Mac inside a
            // "play everywhere" set levels only the Mac.
            stateQueue.async {
                self.applyLocal(id) { $0.volume = clamped }
                self.pushSyncedLocalGain()
            }
            return
        }
        stateQueue.async {
            // `.bluetooth` ids are the R-partition: no `outputIDs` entry, so the
            // engine guard below would drop the write (the reason a BT slider did
            // nothing). Same stash-under-mute semantics as the engine arm; the
            // push is the composed sink gain instead of an engine volume.
            if self.known[id]?.isBluetooth == true {
                if self.muted.contains(id) {
                    self.stashedVolume[id] = clamped
                    self.applyLocal(id) { $0.volume = clamped }
                } else {
                    self.applyLocal(id) { $0.volume = clamped }
                    self.pushBTSinkGainLocked(id)
                }
                return
            }
            // `.cast` ids are the third partition — no `outputIDs` entry either,
            // same stash-under-mute semantics, and the push is the composed
            // receiver level instead of an engine volume.
            if self.known[id]?.isCast == true {
                if self.muted.contains(id) {
                    self.stashedVolume[id] = clamped
                    self.applyLocal(id) { $0.volume = clamped }
                } else {
                    self.applyLocal(id) { $0.volume = clamped }
                    self.pushCastLevelLocked(id)
                }
                return
            }
            guard let outputID = self.outputIDs[id] else { return }
            // If the device is muted, remember the desired level; unmute restores
            // it. Otherwise push it now. Optimistically echo so the UI is snappy.
            if self.muted.contains(id) {
                self.stashedVolume[id] = clamped
                self.applyLocal(id) { $0.volume = clamped }
            } else {
                self.applyLocal(id) { $0.volume = clamped }
                self.pushVolume(outputID, id: id,
                                engineValue: self.engineVolume(forID: id, uiVolume: clamped),
                                uiLevel: clamped)
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
            // Off `stateQueue`, as in `setVolume`, and aimed at the same device the
            // Main mirror is — see ``builtInOutputTargetResolver()``.
            systemVolume.setMuted(muted, resolvingTarget: builtInOutputTargetResolver())
            return
        }
        stateQueue.async {
            guard self.muted.contains(id) != muted else { return }
            // BT arm: the same stash/restore shim as the engine arm below (the
            // sink has no mute field either) — mute pushes the composed 0,
            // unmute restores the stashed level and pushes its composed gain.
            if self.known[id]?.isBluetooth == true {
                if muted {
                    self.muted.insert(id)
                    if self.stashedVolume[id] == nil { self.stashedVolume[id] = self.known[id]?.volume ?? 0 }
                    self.applyLocal(id) { $0.isMuted = true; $0.volume = 0 }
                } else {
                    self.muted.remove(id)
                    let intended = self.stashedVolume[id] ?? self.known[id]?.volume ?? 0
                    self.stashedVolume[id] = nil
                    self.applyLocal(id) { $0.isMuted = false; $0.volume = intended }
                }
                self.pushBTSinkGainLocked(id)
                return
            }
            // Cast arm: the same stash/restore shim again — a Cast mute is the
            // composed level 0, never the protocol's own muted flag.
            if self.known[id]?.isCast == true {
                if muted {
                    self.muted.insert(id)
                    if self.stashedVolume[id] == nil { self.stashedVolume[id] = self.known[id]?.volume ?? 0 }
                    self.applyLocal(id) { $0.isMuted = true; $0.volume = 0 }
                } else {
                    self.muted.remove(id)
                    let intended = self.stashedVolume[id] ?? self.known[id]?.volume ?? 0
                    self.stashedVolume[id] = nil
                    self.applyLocal(id) { $0.isMuted = false; $0.volume = intended }
                }
                self.pushCastLevelLocked(id)
                return
            }
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
                // `uiLevel: nil` — the fader is at 0 because the device is MUTED,
                // not because of a level the engine confirmed, so a refused mute
                // push must not move it.
                self.pushVolume(outputID, id: id, engineValue: engineValue, uiLevel: nil)
            } else {
                self.muted.remove(id)
                self.applyLocal(id) { $0.isMuted = false }
                self.restoreEffectiveVolume(id, outputID: outputID)
            }
        }
    }

    public func setMasterGain(mainOut: Int, group: Int, mirrorToSystemVolume: Bool) {
        let main = mainOut.clampedToVolume
        let newGroup = group.clampedToVolume
        stateQueue.async {
            guard main != self.mainOutGain || newGroup != self.groupGain else { return }
            let groupChanged = newGroup != self.groupGain
            let mainChanged = main != self.mainOutGain
            self.mainOutGain = main
            self.groupGain = newGroup

            // RE-PUSH, never re-store. `pushVolume` puts the freshly multiplied
            // value on the wire and leaves `known[id].volume` — the user's own
            // setting — untouched. `applyLocal` would overwrite each device's stored
            // level with the effective value (the exact corruption this design
            // exists to avoid) and emit a spurious `deviceUpdated`.
            //
            // No new debounce for a fader drag: `pushVolume`'s existing
            // `volumeInFlight`/`volumePending` coalescing already collapses a burst
            // to at most one extra call per output, latest-wins.
            for (id, outputID) in self.outputIDs where !self.muted.contains(id) {
                // `uiLevel: nil` — gain-only. The fader didn't move, so a refused
                // push must not move it either.
                self.pushVolume(outputID, id: id,
                                engineValue: self.engineVolume(
                                    forID: id, uiVolume: self.known[id]?.volume ?? 0),
                                uiLevel: nil)
            }
            // BT sinks carry the full `Main × Group × Device` product (unlike
            // the Mac's own path below, they never see the system volume), so
            // any master-stage move re-pushes every selected BT uid's composed
            // gain. `pushBTSinkGainLocked` folds mute/hold in as 0, so this
            // can't unmute or blow through a first-mix hold.
            for uid in self.btSelectedUIDs { self.pushBTSinkGainLocked(uid) }
            // Same for every selected Cast id — `castLevel(forID:)` folds mute
            // in as 0, so this can't unmute a receiver either.
            for id in self.castSelectedIDs { self.pushCastLevelLocked(id) }
            // The Mac's own path carries `group × device`, and Main too whenever we
            // own the volume — there it is the ONLY thing applying Main to the Mac,
            // so a Main-only move has to re-push as well. When macOS owns the
            // volume, Main still arrives through the system-volume write instead and
            // only a group change moves this.
            if groupChanged || (mainChanged && self.weOwnSystemVolume) {
                self.pushSyncedLocalGain()
            }
        }
        // The hardware system-volume write is now the Main path's ALONE
        // (`setVolume`'s local branch no longer does it), and only when the caller
        // asked to mirror. Off `stateQueue`, like every other `systemVolume` write —
        // and the target resolver below runs on `SystemOutputVolume`'s own write
        // queue, never here: this is a fader drag taking dozens of writes a second,
        // and resolving the built-in output enumerates every HAL device.
        if mirrorToSystemVolume {
            // Memoise the system level ONLY once the hardware confirms it took the
            // write. `SystemOutputVolume` suppresses the echo of its own writes, so
            // `onExternalChange` never delivers this value back to update the memo
            // for us — but memoising optimistically is worse than not memoising: a
            // readable-but-UNWRITABLE output (some USB DACs) no-ops the write, and
            // the memo would then claim a level the system never reached, so a later
            // genuine external change *to* that level compares equal and is silently
            // dropped. The callback runs on the helper's own queue before any
            // notification the write provoked, so this can't be overtaken by it.
            systemVolume.setVolume(main, resolvingTarget: builtInOutputTargetResolver()) { [weak self] wrote in
                guard let self, wrote else { return }
                self.stateQueue.async { self.lastSeenSystemVolume = main }
            }
        }
    }

    /// Where the Main mirror and the local row's mute actually aim: the Mac's
    /// BUILT-IN output device, but only while our own aggregate is the current
    /// default output.
    ///
    /// The aggregate wraps the built-in as its sole sub-device
    /// (``AggregateOutputDevice``) and ACCEPTS volume writes while discarding them,
    /// so a write aimed at "whatever is currently default" during a routing session
    /// leaves the real speakers' hardware knob stale — and the user hears the jump
    /// on deselect. The built-in is the knob that changes what is heard.
    ///
    /// Deliberately NOT ``weOwnSystemVolume``: that is also true for a real output
    /// with an unreadable volume (HDMI), where writing the built-in would move
    /// speakers nobody is listening to.
    ///
    /// The returned closure captures only the two injected seams — never `self`,
    /// never `stateQueue`-confined state — and is evaluated on
    /// `SystemOutputVolume`'s own write queue.
    private func builtInOutputTargetResolver() -> @Sendable () -> AudioObjectID? {
        let control = aggregateControl
        let provider = currentDefaultOutputUIDProvider
        return {
            guard provider() == AggregateOutputDevice.productUID else { return nil }
            return Self.firstResolvableDevice(
                uids: [control.builtInOutputDeviceUID()], using: control)?.id
        }
    }

    /// Push ``syncedLocalGain`` to the delayed local sink (W1's
    /// ``SyncedLocalSink/setGain(_:)``) — `group × the Mac's own fader`, and Main
    /// too while we own the volume. Reads state on `stateQueue`, then
    /// hops to `captureControlQueue`, which owns `syncedLocalSink`. A no-op before
    /// the sink is built — `applySyncedLocalSinkTransition` applies the current gain
    /// as it starts, so a trim made while "play everywhere" was off is not lost.
    private func pushSyncedLocalGain() {   // on stateQueue
        let gain = syncedLocalGain
        captureControlQueue.async { [weak self] in self?.syncedLocalSink?.setGain(gain) }
    }

    /// `group × the Mac's own fader` as a 0.0…1.0 `Float` — times Main as well
    /// while ``weOwnSystemVolume``. On `stateQueue`.
    ///
    /// Main is normally EXCLUDED because the Mac's system volume already applies it
    /// to that output, so including it would square the master on the Mac path.
    /// That premise dies exactly when we own the volume: the default output is our
    /// aggregate, `setMasterGain`'s mirror write silently no-ops against it, and
    /// nothing else is applying Main to the Mac at all. Without this arm, pulling
    /// Main down would quieten the AirPlay speakers while the Mac's own output
    /// stayed at full — the master control visibly failing on the commonest setup.
    private var syncedLocalGain: Float {   // on stateQueue
        let level = known[Self.localDeviceID]?.volume ?? 100
        let main = weOwnSystemVolume ? Double(mainOutGain) / 100.0 : 1.0
        return Float(main * Double(groupGain) / 100.0 * Double(level.clampedToVolume) / 100.0)
    }

    /// One BT device's composed sink gain: `Main × Group × Device` on the UI's
    /// 0–100 scale — the same product `engineVolume(forID:uiVolume:)` forms for
    /// AirPlay outputs, linear because the sink's mixer wants a 0…1 amplitude,
    /// not a dB wire value — forced to 0 while the id is muted (the stash shim)
    /// or first-mix-held (W3). ONE product, one writer: every gain that reaches
    /// `BTSyncedSinkControlling/setGain(_:forDeviceUID:)` is computed here, so
    /// user volume and the hold can never fight over the knob. Unlike the Mac's
    /// `syncedLocalGain`, Main IS included — a BT sink renders through its own
    /// device, which the Mac's system volume never touches. On `stateQueue`.
    private func btSinkGain(forUID uid: String) -> Float {   // on stateQueue
        if btAlignmentHeldUIDs.contains(uid) || btWizardHeldUIDs.contains(uid)
            || muted.contains(uid) { return 0 }
        let level = known[uid]?.volume ?? 100
        return Float(masterGainFraction * Double(level.clampedToVolume) / 100.0)
    }

    /// Push one uid's composed gain to the live sink (a no-op before the sink
    /// exists — `applyBTSinkTransition` seeds the same product on arm). Reads on
    /// `stateQueue`, then hops to `captureControlQueue`, which owns `btSink`.
    private func pushBTSinkGainLocked(_ uid: String) {   // on stateQueue
        let gain = btSinkGain(forUID: uid)
        captureControlQueue.async { [weak self] in
            self?.btSink?.setGain(gain, forDeviceUID: uid)
        }
    }

    /// The composed gain per selected BT uid, snapshotted under `stateQueue` for
    /// a sink transition to apply on `captureControlQueue`. On `stateQueue`.
    private func btSinkGains(forUIDs uids: [String]) -> [String: Float] {   // on stateQueue
        Dictionary(uniqueKeysWithValues: uids.map { ($0, btSinkGain(forUID: $0)) })
    }

    /// One Cast receiver's composed level: `Main × Group × Device` as 0.0…1.0,
    /// the same product `btSinkGain(forUID:)` forms, forced to 0 while muted.
    /// ONE product, one writer — a Cast receiver's mute IS level 0, never the
    /// protocol's `SET_VOLUME muted` flag, so nothing else can fight over the
    /// knob and no receiver-side mute can outlive the session. On `stateQueue`.
    private func castLevel(forID id: String) -> Double {   // on stateQueue
        if muted.contains(id) { return 0 }
        return masterGainFraction * Double((known[id]?.volume ?? 100).clampedToVolume) / 100.0
    }

    /// Push one Cast id's composed level to the session manager (a no-op before
    /// the channel is live — the manager stores it and sends it on connect).
    /// Reads on `stateQueue`, then hops to `captureControlQueue`, which owns the
    /// manager's transitions. On `stateQueue`.
    private func pushCastLevelLocked(_ id: String) {   // on stateQueue
        let level = castLevel(forID: id)
        captureControlQueue.async { [weak self] in
            self?.castOutputManager?.setLevel(level, forDevice: id)
        }
    }

    // MARK: Tone (per-device + Main Out EQ)

    /// One speaker's tone. `commit == false` is live scrub — the sound changes
    /// immediately but nothing is persisted and, wherever the device's current
    /// stream can already express the edit, no rebind is issued. `commit == true`
    /// is the end of a gesture: persist, then recompute the dedup topology.
    ///
    /// The local Mac row is REJECTED (locked scoping decision: per-device EQ
    /// covers AirPlay and Bluetooth rows only). A Bluetooth id branches to its
    /// sink — its audio never goes through an AirPlay stream, so stream topology
    /// has nothing to say about it.
    public func setEQ(_ eq: DeviceEQ, for id: String, commit: Bool) {
        guard id != Self.localDeviceID else { return }
        stateQueue.async {
            guard self.known[id] != nil else { return }
            self.eqByDeviceID[id] = eq
            self.applyLocal(id) { $0.eq = eq }
            if commit { self.saveEQLocked() }
            if self.known[id]?.isBluetooth == true {
                self.pushBTSinkEQLocked(id)
                return
            }
            // A device outside the EQ domain (not streaming whole-system, or
            // claimed by per-app routing) has nothing in the plan to change, so
            // a scrub touches neither topology nor processors — the value is
            // remembered and the commit applies it. Without this, every frame of
            // a drag on such a row ran a full `reconcileEQPlan`.
            guard commit || self.eqStreamIDByDevice[id] != nil else { return }
            // Decision 9: a sole owner of its own stream just gets fresh
            // coefficients. Anything else — flat↔non-flat, a group merge or
            // split, a device still on stream 0 — needs the topology recomputed,
            // and inherits the rebind's accepted ~1 s gap.
            if commit || !self.eqEditIsExpressibleLocked(id) {
                self.reconcileEQPlan()
            } else {
                self.pushEQPlanLocked()
            }
        }
    }

    /// Main Out's tone: one stage over the whole mix, applied before every
    /// fan-out, so AirPlay, the Mac's own delayed sink and every Bluetooth sink
    /// hear the same shaped program. Never affects stream topology — there is
    /// exactly one main stage no matter how many streams exist.
    public func setMainOutEQ(_ eq: DeviceEQ, commit: Bool) {
        stateQueue.async {
            self.storedMainOutEQ = eq
            if commit { self.saveEQLocked() }
            self.pushEQPlanLocked()
        }
    }

    /// Whether `id`'s current stream can carry a changed value with no rebind:
    /// it owns a real EQ stream, alone. A device on stream 0, or sharing a
    /// stream with others, cannot — changing its values there would change
    /// everyone else's too (decision 9). On `stateQueue`.
    private func eqEditIsExpressibleLocked(_ id: String) -> Bool {   // on stateQueue
        guard let stream = eqStreamIDByDevice[id], stream != 0 else { return false }
        return !eqStreamIDByDevice.contains { $0.key != id && $0.value == stream }
    }

    /// Persist the current tone settings. Committed edits only — a live scrub
    /// must not write a file per slider frame. Flat entries are dropped by the
    /// store itself, so the whole table can be handed over as-is. On `stateQueue`.
    private func saveEQLocked() {   // on stateQueue
        do {
            try eqStore?.save(mainOut: storedMainOutEQ, devices: eqByDeviceID)
        } catch {
            Telemetry.log(.airplay, "eq_save_failed", ["error": "\(error)"])
        }
    }

    /// Recompute which stream every streaming AirPlay device belongs on, publish
    /// the resulting plan, and move any device whose stream changed.
    ///
    /// Triggers (decision 16): a committed `setEQ`, an uncommitted edit its
    /// current stream cannot express, a device reaching OR leaving `added` (a
    /// reconnect always lands on stream 0 first, so its EQ has to be re-applied;
    /// a departure frees a stream for whoever the budget refused, and takes the
    /// departed device's own stream out of the plan), `setOutputSet`, a per-app
    /// destination-set change (which moves the budget), and `stop()`.
    /// On `stateQueue`.
    private func reconcileEQPlan() {   // on stateQueue
        // Only devices with a LIVE stream-0 session can be moved onto an EQ
        // stream. A device claimed by the per-app domain is not ours to rebind
        // (its stream is `streamBindings`'), and it is already counted against
        // the budget below.
        let active = added.filter { streamBindings[$0] == nil }
        let previous = eqStreamIDByDevice
        let result = EQStreamTopology.resolve(
            activeDeviceIDs: active,
            eqByDevice: eqByDeviceID,
            budget: eqBudgetLocked(),
            allocator: eqAllocator)
        eqAllocator = result.allocator

        // Say out loud, per device, whether its stored values are reaching the
        // audio — and when they aren't, WHY, because the two reasons need
        // different sentences. One sweep over everything known, so a device that
        // just left the EQ domain is cleared by the same pass that sets the
        // others. `applyLocal` emits only on a real change.
        for id in Array(known.keys) {   // snapshot: `applyLocal` writes `known`
            let reason: Device.EQBypassReason?
            if result.bypassed.contains(id) {
                // Kept its values, streams flat: more distinct settings than the
                // budget could admit.
                reason = .streamBudget
            } else if streamBindings[id] != nil, !(eqByDeviceID[id] ?? .flat).isFlat {
                // Excluded from the EQ domain above because per-app routing owns
                // this device's session — its audio never passes the whole-system
                // EQ stage, so a stored tone is stored only.
                reason = .perAppRouting
            } else {
                reason = nil
            }
            applyLocal(id) { $0.eqBypassReason = reason }
        }

        // The assignment is only true once the move is actually issued. A move
        // that had to be deferred rolls back to where the device still IS, so the
        // drain's reconcile sees a real change and re-issues it — recording the
        // target eagerly would make the re-drive a no-op and strand the device on
        // the wrong stream.
        var settled = result.streamIDByDevice
        for (id, stream) in result.streamIDByDevice {
            // A device with no previous assignment is on stream 0 in engine
            // truth — a fresh connect, or one this reconcile just discovered.
            let current = previous[id] ?? 0
            guard current != stream else { continue }
            guard let outputID = outputIDs[id],
                  enqueueEQRebindLocked(deviceID: id, outputID: outputID, stream: stream)
            else {
                settled[id] = current
                continue
            }
        }
        eqStreamIDByDevice = settled
        pushEQPlanLocked()
    }

    /// Drop `id` from the whole-system streaming set, reconciling the EQ plan on
    /// a REAL true→false edge — the departure mirror of the `added` false→true
    /// edge, and the only site that owns it.
    ///
    /// A departure changes two things nothing else notices: it frees an EQ
    /// stream, so a device the budget had refused can be admitted and stop
    /// streaming flat; and it takes the departed device's own stream out of the
    /// plan, which otherwise keeps costing a per-buffer copy and filter pass for
    /// audio no output is bound to. `setOutputSet`'s reconcile can't do either —
    /// it runs while the teardown is still in flight, with the device still in
    /// `added`.
    ///
    /// `reconcileEQPlan` moves other devices through `enqueueEQRebindLocked`,
    /// which defers rather than waits when a `converging` slot is held, so this
    /// is safe to call from inside a converge loop. On `stateQueue`.
    /// - Returns: whether `id` was actually in the streaming set.
    @discardableResult
    private func removeFromAddedLocked(_ id: String) -> Bool {   // on stateQueue
        guard added.remove(id) != nil else { return false }
        reconcileEQPlan()
        return true
    }

    /// How many EQ streams may exist beyond stream 0 (decision 10): the engine's
    /// capacity, less stream 0 itself, less every distinct per-app stream
    /// currently bound. Per-app ids are allocated upward from 1 and EQ ids live
    /// in the top half of the space, so the range test tells them apart. On
    /// `stateQueue`.
    private func eqBudgetLocked() -> Int {   // on stateQueue
        let perAppStreams = Set(streamBindings.values.filter { $0 >= 1 && $0 < EQStreamAllocator.idBase })
        return max(0, Self.engineStreamCapacity - 1 - perAppStreams.count)
    }

    /// Publish the CURRENT assignment as a plan for the capture coordinator.
    /// Called for a topology change and for a bare coefficient swap alike — the
    /// assignment map is the same input either way.
    ///
    /// No live stage is ever rebuilt: an unchanged one is carried over
    /// instance-and-all (see ``EQProcessorSlot``) and a changed one is
    /// retargeted in place, because a fresh `EQProcessor` starts with empty IIR
    /// delay memory — a tick on a neighbour, a crackle for the whole drag on the
    /// speaker being edited. Coefficients are built HERE, on `stateQueue`, and
    /// reach the processor through its own mailbox; its filter state stays the
    /// delivery thread's alone and is never read from here. Enqueued on
    /// `captureControlQueue` like every other coordinator call, so a coordinator
    /// callback that hops to `stateQueue` can never deadlock against this.
    /// On `stateQueue`.
    private func pushEQPlanLocked() {   // on stateQueue
        var eqByStream: [UInt32: DeviceEQ] = [:]
        for (id, stream) in eqStreamIDByDevice where stream != 0 {
            eqByStream[stream] = eqByDeviceID[id] ?? .flat
        }
        // A stream that left the plan takes its cached processor with it —
        // nothing will feed it again, and a reused id is a different group.
        eqSlotByStream = eqSlotByStream.filter { eqByStream[$0.key] != nil }

        var streams: [WholeSystemEQPlan.Stream] = [.init(streamID: 0, processor: nil)]
        for (stream, eq) in eqByStream.sorted(by: { $0.key < $1.key }) {
            streams.append(.init(
                streamID: stream,
                processor: Self.processor(reusing: &eqSlotByStream[stream], for: eq)))
        }
        let plan = WholeSystemEQPlan(
            main: Self.processor(reusing: &mainOutEQSlot, for: storedMainOutEQ),
            streams: streams)
        guard let coordinator = captureCoordinator else { return }
        captureControlQueue.async { coordinator.setEQPlan(plan) }
    }

    /// The processor for one tone stage, KEEPING the live instance in every case
    /// where one already exists — unchanged (return it as it stands) or changed
    /// (``EQProcessor/retarget(to:)``, which hands the new coefficients to the
    /// delivery thread and carries the delay memory across). Building a new one
    /// would zero that memory mid-signal: an audible tick on an untouched
    /// speaker, and a crackle for the whole drag on the one being edited.
    ///
    /// A flat value drops the slot and returns `nil`: flat must stay
    /// byte-identical passthrough, never a processor pass. The mirror edge —
    /// flat to shaped — has no live instance to preserve, and zero state is the
    /// right start for a stage that was not running. On `stateQueue`.
    private static func processor(reusing slot: inout EQProcessorSlot?, for eq: DeviceEQ) -> EQProcessor? {
        guard !eq.isFlat else {
            slot = nil
            return nil
        }
        if let existing = slot {
            if existing.eq != eq {
                existing.processor.retarget(to: eq)
                slot = EQProcessorSlot(eq: eq, processor: existing.processor)
            }
            return existing.processor
        }
        let processor = EQProcessor(eq: eq, sampleRate: eqSampleRate)
        slot = EQProcessorSlot(eq: eq, processor: processor)
        return processor
    }

    /// Move one device's live session onto the stream its EQ group owns.
    ///
    /// Claims the per-device `converging` slot exactly as
    /// `resetAirPlaySessionForWholeSystem` does — an EQ rebind is a whole-system
    /// engine op and must never interleave with a concurrent `convergeDevice`
    /// loop for the same device — and records the hold in `rebindConverging` so
    /// the sleep path can release it if the machine goes down mid-move. The op
    /// itself goes through `bindOutput`, the single call site that arbitrates on
    /// the engine's own answer, never a naked `rebindOutput`. On `stateQueue`.
    /// - Returns: whether the move was actually issued. `false` means the slot
    ///   was busy and the device is noted for the release to re-drive.
    private func enqueueEQRebindLocked(   // on stateQueue
        deviceID: String, outputID: OutputID, stream: UInt32
    ) -> Bool {
        guard !converging.contains(deviceID) else {
            // A converge already owns this device's engine ops — including the
            // one whose own `added` edge asked for this move. Never WAIT on the
            // slot (that is the documented FIFO deadlock); note the device and
            // re-drive when the slot is released.
            eqRebindDeferred.insert(deviceID)
            Telemetry.log(.airplay, "eq_rebind_deferred", [
                "device": deviceID, "stream": "\(stream)", "reason": "already_converging",
            ])
            return false
        }
        eqRebindDeferred.remove(deviceID)
        converging.insert(deviceID)
        rebindConverging.insert(deviceID)
        Telemetry.log(.airplay, "eq_rebind", ["device": deviceID, "stream": "\(stream)"])
        let prev = bindTail
        bindTail = Task { [weak self] in
            await prev.value
            guard let self else { return }
            // Re-check under the lock immediately before the engine call: the
            // world may have moved while this op waited its turn in the FIFO
            // (deselected, superseded by a newer assignment, or the sleep path
            // took our slot back).
            let shouldFire: Bool = self.stateQueue.sync {
                self.rebindConverging.contains(deviceID)
                    && !self.suspended
                    && self.added.contains(deviceID)
                    && self.eqStreamIDByDevice[deviceID] == stream
            }
            if shouldFire {
                do {
                    try await self.bindOutput(outputID, toStream: stream)
                } catch {
                    Telemetry.log(.airplay, "eq_rebind_failed", [
                        "device": deviceID, "stream": "\(stream)", "error": "\(error)",
                    ])
                }
            }
            let action: ConvergeReleaseAction = self.stateQueue.sync {
                // Only release a hold we still own — sleep releases every
                // `rebindConverging` slot itself, and a `convergeDevice` loop may
                // have claimed the freed slot since.
                guard self.rebindConverging.contains(deviceID) else { return .none }
                return self.releaseRebindConverging(id: deviceID)
            }
            if action.redrivePerApp { self.replayPendingPerAppBindings(trigger: "ws_release") }
            if let requeue = action.requeue {
                Task { [weak self] in await self?.convergeDevice(id: deviceID, outputID: requeue) }
            }
        }
        return true
    }

    /// Push one Bluetooth device's tone into its sink — a property swap on the
    /// running session, never a rebuild. On `stateQueue`.
    private func pushBTSinkEQLocked(_ uid: String) {   // on stateQueue
        let eq = eqByDeviceID[uid] ?? .flat
        captureControlQueue.async { [weak self] in
            self?.btSink?.setEQ(eq, forDeviceUID: uid)
        }
    }

    /// The tone per selected BT uid, snapshotted under `stateQueue` for a sink
    /// transition to apply on `captureControlQueue` — the same re-push-on-every-arm
    /// discipline the persisted trims get. On `stateQueue`.
    private func btSinkEQs(forUIDs uids: [String]) -> [String: DeviceEQ] {   // on stateQueue
        Dictionary(uniqueKeysWithValues: uids.map { ($0, eqByDeviceID[$0] ?? .flat) })
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
        // T6-rev: the routing-action permission chokepoint. Deliberately BEFORE
        // `stateQueue` is taken — it must never run inside a critical section
        // this method's main-thread `sync` is already blocking on — and
        // contractually non-blocking (see `onRoutingAction`).
        onRoutingAction?()
        // Record the intent and update the per-device coalescing target under the
        // state lock, then kick a per-device converge loop for anything whose
        // desired state actually changed. Rapid toggle spam collapses here: N
        // flips for one device overwrite `desiredOn[id]` N times but issue at most
        // one op at a time (root cause 1) — intermediate flips are simply dropped.
        // STABILITY(C8): main thread blocks on the state queue for slow work — see dev/notes/stability-audit-2026-07-18.md
        let toKick: [(id: String, outputID: OutputID)] = stateQueue.sync {
            // T4: captured BEFORE the overwrite below so the Telemetry line at the
            // end of this critical section can log the actual added/removed diff.
            let previouslySelected = self.expectedSelected
            self.expectedSelected = ids
            // Seamless handoff T3.8-2: an in-app routing action IS the user asking
            // for Audiout back — don't leave `suspended` set from a prior handoff
            // release, which would connect speakers with the capture tap gated off
            // (silent, since `convergeDevice` has no `suspended` guard of its own).
            if self.handoffReleased, !ids.isEmpty {
                self.handoffReleased = false
                self.defaultLeftUsSinceRelease = true
                self.suspended = false
            }
            // Fix C: an explicit (re)selection is a fresh normal-operation context, not
            // a post-wake reconnection — so a stranding from THIS selection falls back
            // on the always-on silence delay, not the wake-restore preference.
            self.awaitingWakeReconnect = false

            // Roadmap 008 (selection-edge replay): a device flipping into or out of
            // the whole-system claim changes route-target ELIGIBILITY exactly like a
            // reachability edge does. If any `.device` route targets a flipped id,
            // replay the (unedited) route table so `effectiveAppRoutesLocked`
            // re-resolves it — select demotes the route (the app audibly rejoins the
            // whole-system mix), deselect restores it, with no route-table edit in
            // either direction. Enqueue-only, same guard shape as
            // `rerunAppRoutesIfTargeted`: `rerunAppRoutesForReachabilityChange` is
            // documented safe to call with `stateQueue` held.
            let claimFlips = previouslySelected.symmetricDifference(ids)
            if !claimFlips.isEmpty, self.lastRoutes.contains(where: {
                if case .device(let deviceID) = $0.destination { return claimFlips.contains(deviceID) }
                return false
            }) {
                self.rerunAppRoutesForReachabilityChange()
            }

            // Only ids we can actually stream to — a known discovered receiver
            // (AP1 or AP2) with an engine handle — can be desired-on. The local Mac
            // is excluded (`isLocalDevice`, and it has no `outputIDs` entry); AP1
            // receivers are NOT excluded any more (they drive through the same
            // engine surface as AP2, `supportsAirPlay2` notwithstanding).
            // `.bluetooth` ids are the OTHER side of the R-partition: they have
            // no `outputIDs` entry either, and the explicit `isBluetooth` guard
            // keeps that structural (a BT id must never reach the AirPlay
            // engine even if it ever acquired a handle) — they drive the BT
            // sink manager below instead. `.cast` ids are the THIRD partition,
            // held to the same guard discipline for the same reason.
            var kicks: [(String, OutputID)] = []
            for id in self.order {
                guard let device = self.known[id], !device.isLocalDevice,
                      !device.isBluetooth,
                      !device.isCast,
                      let outputID = self.outputIDs[id] else { continue }
                let wantOn = ids.contains(id)

                let previous = self.desiredOn[id]
                self.desiredOn[id] = wantOn

                // A genuine MEMBERSHIP EDGE clears a terminal-failure park: a
                // re-toggle to ON is an explicit retry after a NACK (root cause
                // 4: no permanent wedge), and toggling OFF deselects the device
                // (nothing left to retry). A membership-NEUTRAL call must leave
                // a parked id ALONE — this used to be an unconditional clear
                // plus an `isRetryOfFailed` re-kick, which turned EVERY routing
                // call that left the set unchanged (a This-Mac toggle, a
                // Main-Out re-pick, an unrelated selection change) into a full
                // retry of every still-desired `.failed` device, sustaining an
                // autonomous zero-backoff retry storm (live, 2026-08-06). The
                // deliberate same-membership retry ("Try again") now travels
                // its own entry point, `retryOutput(_:)`.
                if previous != wantOn { self.failedGate.remove(id) }

                // Connection-status brief §1/§3 semantics (mirrors OwnToneBackend's
                // `setOutputSet`): a device newly desired ON goes `.connecting`
                // immediately, before the engine op resolves, so the UI spinner is
                // immediate. This also clears a sticky `.failed` on a re-toggle
                // (the `failedGate` clear above is the routing-side twin of
                // this). A device newly desired OFF drops any in-flight/failed
                // indication back to `.off` right away — NativeBackend has no
                // "sticky failed survives deselect" behavior (its park is
                // cleared on any toggle edge, above), so the connection dot
                // follows suit and a deselect genuinely ENDS a failure episode.
                if previous != wantOn {
                    self.setConnectionState(wantOn ? .connecting : .off, for: id)
                }
                // Kick iff the desired state changed AND no loop is already
                // running for this id (a running loop re-reads `desiredOn` when
                // its op settles).
                if previous != wantOn, !self.converging.contains(id) {
                    self.converging.insert(id)
                    kicks.append((id, outputID))
                    // Connect-latency diagnosis: T0 for "click to first audio," read
                    // alongside the "connect_addoutput_*" timestamps in
                    // convergeDevice below.
                    if wantOn {
                        // F-REBIND: the USER asked for this connect, so whichever
                        // add-success site wins the race seeds the configured connect
                        // default. Deliberately only here, not in `convergeToTarget`
                        // (which flaps `desiredOn` for `applyStartBuffer`'s internal
                        // re-add) — see `userConnectSeed`.
                        self.userConnectSeed.insert(id)
                        Telemetry.log(.airplay, "connect_requested", ["device": id])
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
            if wantSyncedLocal != self.syncedLocalSinkEnabled {
                self.syncedLocalSinkEnabled = wantSyncedLocal
                // T1/T2: don't run the attach/detach here — record the desired
                // state and (re)schedule a trailing-edge settle. A burst of rapid
                // on/off toggles collapses to AT MOST one real transition, killing
                // both the tap-rebuild storm and the sink re-anchor storm (both are
                // driven from `applySyncedLocalSinkTransition`).
                self.scheduleSyncedLocalSettleLocked()
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
                // the next `onLevel` drain. Unconditional (not metering-
                // gated), matching that same precedent.
                self.emitCombinedLevel(forDevice: Self.localDeviceID)
            }

            // BT-BACKEND (R-partition): the other half of the partition the
            // engine loop above skipped. Selected `.bluetooth` ids drive the BT
            // sink manager — enable/disable on the empty↔non-empty edge, the
            // per-device set reconciled, and the group composition (BT-REFSEL)
            // recomputed on every selection change (AirPlay joining/leaving a
            // BT-containing selection moves every BT delay to a new reference).
            // Decided here under `stateQueue` like the capture gate and applied
            // on `captureControlQueue`; unchanged decisions enqueue nothing, so
            // unrelated routing traffic never touches the running sinks.
            let btUIDs = ids.filter { self.known[$0]?.isBluetooth == true }.sorted()
            let wantBT = !btUIDs.isEmpty
            // BT-LIFECYCLE: the row's own connect story, the twin of the engine
            // loop's eager `.connecting` above. A newly-selected AVAILABLE BT id
            // breathes until its per-device sink is genuinely audible; a
            // newly-selected UNAVAILABLE one stays `.off` (the greyed "play when
            // up" select — nothing is connecting until it comes back, which the
            // availability edge in `applyBTSnapshots` picks up). A deselect ends
            // any hold at once, but leaves a `.failed` story standing: BT rows
            // offer "Try again" regardless of membership, so the failure the
            // button explains must survive the deselect the loss edge triggers.
            for id in previouslySelected.symmetricDifference(ids)
            where self.known[id]?.isBluetooth == true {
                if ids.contains(id) {
                    if self.known[id]?.isAvailable == true { self.beginBTConnectingLocked(id) }
                } else {
                    self.btConnectingDeadlines[id] = nil
                    if case .failed = self.known[id]?.connectionState {} else {
                        self.setConnectionState(.off, for: id)
                    }
                }
            }
            // CAST-SYNC: the room delay is decided from the SELECTION, ahead
            // of anything launching (brief §4) — a Cast receiver contributes
            // its remembered steady lead (or the measured default) the moment
            // it is selected, so everything else takes its one delay hit now
            // rather than ten seconds into the song.
            let castIDs = ids.filter { self.known[$0]?.isCast == true }.sorted()
            let castSelectionChanged = castIDs != self.castSelectedIDs
            self.castSelectedIDs = castIDs
            let castTermMoved = self.updateCastRoomDelayLocked()

            let composition = BTGroupComposition(
                airPlayPresent: ids.contains {
                    self.known[$0].map {
                        !$0.isBluetooth && !$0.isLocalDevice && !$0.isCast
                    } == true
                },
                macLocalPresent: macSelected,
                castPresent: !castIDs.isEmpty)

            // W3 — the first-mix alignment intercept. The trigger is exactly
            // the locked spec's: a BT id in a MIX (any other member — another
            // AirPlay/BT id, or the Mac itself) with NO saved trim and NO
            // recorded dismissal, at most once per device per session. The
            // device connects and streams normally below but is held at sink
            // gain 0 until the card's answer arrives via
            // `resolveBTAlignmentPrompt` (or the watchdog gives up waiting).
            let mixPresent = ids.count >= 2 || (!ids.isEmpty && macSelected)
            if wantBT, mixPresent {
                let (trims, dismissed) = self.btTrimLock.withLock {
                    (self.btTrimsByUID, self.btAlignmentDismissedUIDs)
                }
                for uid in btUIDs
                where trims[uid] == nil && !dismissed.contains(uid)
                    && !self.btAlignmentPromptedUIDs.contains(uid) {
                    self.btAlignmentPromptedUIDs.insert(uid)
                    self.btAlignmentHeldUIDs.insert(uid)
                    self.scheduleBTAlignmentHoldWatchdogLocked(uid)
                    Telemetry.log(.localPlayback, "bt_first_mix_intercept", ["device": uid])
                    self.emit(.btFirstMixAlignmentPrompt(deviceID: uid))
                }
            }
            // A held id leaving the selection (or the whole BT side emptying)
            // releases its hold — the card is moot once nothing streams there,
            // and the composed-gain push keeps the manager's remembered gain
            // clean for the next, never-again-intercepted select.
            for uid in self.btAlignmentHeldUIDs.subtracting(wantBT ? Set(btUIDs) : []) {
                self.releaseBTAlignmentHoldLocked(uid)
            }
            // Wave-4 delay agreement: a BT-presence flip, or a flip of the
            // timeline BT renders against, moves the LOCAL sink's reference too
            // (`localSinkReferenceDelayMs`), so capture whether the reference
            // input changed before overwriting. macLocalPresent never changes a
            // BT delay (BTReferenceTimeline.delayNanos doc,
            // BTSyncedSink.swift:52-55), so it is deliberately not part of this;
            // a Cast receiver IS, because it authors a presentation timeline
            // exactly as AirPlay does and BT renders against that instead of
            // the Mac's own clock the moment one joins.
            let referenceMoved = wantBT
                && composition.usesPresentationReference
                    != self.btComposition.usesPresentationReference
            let localReferenceMoved = (wantBT != self.btSinkEnabled) || referenceMoved
            if wantBT != self.btSinkEnabled || btUIDs != self.btSelectedUIDs
                || referenceMoved {
                self.btSinkEnabled = wantBT
                self.btSelectedUIDs = btUIDs
                self.btComposition = composition
                let gains = self.btSinkGains(forUIDs: btUIDs)
                // Derived AFTER the new selection is committed — the reference
                // is a function of the selected devices' measured latencies.
                let referenceMs = self.updateBTReferenceBufferLocked()
                let eqs = self.btSinkEQs(forUIDs: btUIDs)
                self.captureControlQueue.async { [weak self] in
                    self?.applyBTSinkTransition(
                        enable: wantBT, uids: btUIDs, composition: composition,
                        gains: gains, eqs: eqs, referenceBufferMs: referenceMs)
                }
                if localReferenceMoved, self.syncedLocalSinkApplied {
                    // Re-anchor the already-running local sink onto the new
                    // reference. Same serial queue as its transitions, so this
                    // can't race an enable/disable for the same sink; the
                    // settle path re-samples the delay on its own when the
                    // local sink is (re)built later.
                    self.captureControlQueue.async { [weak self] in
                        self?.syncedLocalSink?.requestReanchor(cause: "bt_composition_change")
                    }
                }
            }

            // CAST-SYNC (brief §5 ordering): the new room delay reaches every
            // output that has to meet it BEFORE the receiver that set it is
            // launched below — the house is already playing on the new
            // timeline by the time the Cast device starts filling its buffer.
            if castTermMoved {
                self.roomDelayChangedLocked(cause: "cast_selection")
            } else if self._castTermMs != nil {
                // The room did not move, but who has to meet it may have: an
                // AirPlay device joining a Cast room needs the line from its
                // first buffer, and re-publishing the same depth costs nothing.
                self.publishAirPlayPreDelayLocked()
            }

            // CAST-OUT (R-partition, third arm): selected `.cast` ids drive the
            // Cast session manager — same decide-here/apply-on-`captureControlQueue`
            // split as BT, and an unchanged id list enqueues nothing. An empty
            // `castIDs` on an already-empty selection is a no-op.
            //
            // The row's connect story, twin of the BT arm's: a newly-selected
            // AVAILABLE Cast id breathes until its receiver reports PLAYING; a
            // newly-selected UNAVAILABLE one stays `.off`. A deselect ends the
            // hold but leaves a `.failed` story standing, so "Try again" keeps
            // explaining what went wrong.
            for id in previouslySelected.symmetricDifference(ids)
            where self.known[id]?.isCast == true {
                if ids.contains(id) {
                    if self.known[id]?.isAvailable == true {
                        self.setConnectionState(.connecting, for: id)
                    }
                } else {
                    self.castPlaying.remove(id)
                    if case .failed = self.known[id]?.connectionState {} else {
                        self.setConnectionState(.off, for: id)
                    }
                }
            }
            if castSelectionChanged {
                let records = castIDs.compactMap { self.castRecords[$0] }
                let levels = Dictionary(
                    uniqueKeysWithValues: castIDs.map { ($0, self.castLevel(forID: $0)) })
                self.captureControlQueue.async { [weak self] in
                    self?.applyCastTransition(
                        enable: !castIDs.isEmpty, records: records, levels: levels)
                }
            }

            // The selection just moved, so the set of devices an EQ stream can
            // serve moved with it (decision 16). This pass sees INTENT only:
            // devices connecting as a result of this call reconcile again on
            // their own `added` edge, and a DESELECTED device is still in
            // `added` here (its teardown is only being scheduled) — the
            // departure edge is `removeFromAddedLocked`'s to report, not this
            // one's.
            self.reconcileEQPlan()

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

            return kicks
        }

        // Wave 3 T5: the selection intent just changed — reconcile the public
        // aggregate's default-output ownership off it. This is the ACTIVATION SEAM
        // (Q1): the app takes the Mac's default output only when the user actually
        // routes (whole-system selection becomes non-empty), never at launch. It
        // also (re)evaluates the routing-blocked warning for the new steady state.
        // Scheduled `async` (not inside the critical section above) so the HAL
        // default-output write never extends the main-thread `sync` block; still
        // serial on `stateQueue`, so it observes the just-written `expectedSelected`.
        stateQueue.async { self.reconcileAggregateDefault() }

        // The synced-local transition is no longer enqueued here — it fires from
        // the debounced `fireSyncedLocalSettle` (scheduled inside the critical
        // section above via `scheduleSyncedLocalSettleLocked`), so a rapid burst
        // collapses to one transition instead of one per toggle (T1).

        for (id, outputID) in toKick {
            Task { [weak self] in
                guard let self else { return }
                await self.convergeDevice(id: id, outputID: outputID)
            }
        }
    }

    public func retryOutput(_ id: String) {
        // Same routing-action chokepoint discipline as `setOutputSet` (T6-rev):
        // a retry is a user routing gesture, and this must run OUTSIDE the lock.
        onRoutingAction?()
        // BT-RECONNECT: a Bluetooth row's tap-to-reconnect takes a fully
        // separate path — BT ids have no engine OutputID, and their "converge"
        // is a baseband reconnect (`BTConnectionManager`), not an RTSP session.
        if retryBTOutput(id) { return }
        // CAST-OUT: a Cast row's "Try again" re-runs the whole session recipe in
        // the manager — no engine OutputID exists for it either.
        if retryCastOutput(id) { return }
        let kick: OutputID? = stateQueue.sync {
            // Only a still-DESIRED id can be retried — intent lives in
            // `expectedSelected` (what the routing brain last asked for), and a
            // retry never invents membership. An already-`.connected` id has
            // nothing to retry.
            guard self.expectedSelected.contains(id),
                  let device = self.known[id], !device.isLocalDevice,
                  device.connectionState != .connected,
                  let outputID = self.outputIDs[id] else { return nil }
            // THE explicit un-park site for a same-membership retry: `setOutputSet`
            // only clears the park on a genuine membership edge now (storm fix,
            // 2026-08-06), so "Try again" clears it here — for THIS id only.
            self.failedGate.remove(id)
            self.desiredOn[id] = true
            // Eager `.connecting`, mirroring `setOutputSet`'s newly-desired-ON arm:
            // the spinner is immediate, and the fresh `.failed → .connecting` edge
            // is what marks a USER-initiated attempt (a new failure episode) for
            // the popover's diagnosis-panel semantics — the backend's autonomous
            // recovery paths deliberately never produce this edge.
            self.setConnectionState(.connecting, for: id)
            guard !self.converging.contains(id) else { return nil }
            self.converging.insert(id)
            // F-REBIND: the USER asked for this connect, same as a fresh toggle.
            self.userConnectSeed.insert(id)
            Telemetry.log(.airplay, "connect_requested", ["device": id, "trigger": "retry"])
            return outputID
        }
        guard let kick else { return }
        Task { [weak self] in await self?.convergeDevice(id: id, outputID: kick) }
    }

    /// BT-RECONNECT (Wave 4): handle `retryOutput` for a `.bluetooth` id.
    /// Returns `false` for non-BT ids (the AirPlay path below runs instead).
    /// Unlike the AirPlay arm, membership is NOT required — Section D's
    /// tap-to-reconnect applies to any paired row, and a selected id that comes
    /// back re-enters the sink set via the reapply below.
    private func retryBTOutput(_ id: String) -> Bool {
        var address: String?
        let isBT: Bool = stateQueue.sync {
            guard let device = self.known[id], device.isBluetooth else { return false }
            // "Not paired" tier (device-tier decision 2): the id survives in app
            // data but the OS pairing record is gone — the enumerator's merged
            // list is the pairedness truth, so fail FAST here, before any
            // baseband attempt that could only time out ~15 s later. The
            // `.connecting` blip first makes each deliberate click a fresh
            // failure episode for the popover's diagnosis-panel semantics.
            if let paired = self.btPairedIDs, !paired.contains(id) {
                self.setConnectionState(.connecting, for: id)
                self.setConnectionState(.failed(ConnectionFailure(
                    cause: .notPaired, detail: "id absent from the OS paired list")), for: id)
                Telemetry.log(.localPlayback, "bt_connect_not_paired", ["device": id])
                return true
            }
            guard self.btConnectionManager != nil,
                  device.connectionState != .connecting,
                  let mac = BTConnectionManager.macAddress(fromUID: id) else { return true }
            // Eager `.connecting`, mirroring the AirPlay arm: immediate spinner,
            // and the `.failed → .connecting` edge marks a fresh user-initiated
            // attempt for the row's failure-episode semantics.
            self.setConnectionState(.connecting, for: id)
            Telemetry.log(.localPlayback, "bt_connect_requested", ["device": id, "trigger": "retry"])
            address = mac
            return true
        }
        guard isBT else { return false }
        // The enumerator no longer asks for the Bluetooth grant at backend start
        // (setup's own step owns the prompt), so a user reaching for a Bluetooth
        // row is the fallback asker — otherwise someone who skipped that step
        // has no in-app path to the prompt at all, and every attempt below is a
        // silent `.unauthorized`. Once-only, and inert once decided.
        btEnumerator?.requestAuthorizationForUserAction()
        guard let address, let manager = btConnectionManager else { return true }
        Task { [weak self] in
            let outcome = await manager.connect(address: address)
            self?.finishBTReconnect(id: id, outcome: outcome)
        }
        return true
    }

    /// CAST-OUT: handle `retryOutput` for a `.cast` id. Returns `false` for
    /// non-Cast ids (the AirPlay path runs instead). Unlike the BT arm,
    /// membership IS required — nothing streams to an unselected receiver, so a
    /// retry there could only open a session with no audio behind it.
    private func retryCastOutput(_ id: String) -> Bool {
        stateQueue.sync {
            guard self.known[id]?.isCast == true else { return false }
            if self.expectedSelected.contains(id) {
                // Eager `.connecting`, mirroring both arms above: immediate
                // spinner, and the `.failed → .connecting` edge marks a fresh
                // user-initiated attempt for the row's failure-episode semantics.
                self.setConnectionState(.connecting, for: id)
                Telemetry.log(.cast, "cast_connect_requested", ["device": id, "trigger": "retry"])
                self.captureControlQueue.async { [weak self] in
                    self?.castOutputManager?.retry(deviceID: id)
                }
            }
            return true
        }
    }

    /// Fold one `CastOutputManager` session state into the row (CAST-OUT). The
    /// manager knows nothing about rows; this is the only place a Cast session
    /// becomes a `ConnectionState`. On `stateQueue`.
    private func applyCastVolumeLag(_ id: String, _ lagSeconds: Int?) {   // on stateQueue
        guard var device = known[id], device.isCast, device.castVolumeLagSeconds != lagSeconds else { return }
        device.castVolumeLagSeconds = lagSeconds
        commitKnownDevice(id, device)
        Telemetry.log(.cast, "cast_volume_lag", [
            "device": id, "lag": lagSeconds.map(String.init) ?? "nil",
        ])
    }

    private func applyCastSessionState(_ id: String, _ state: CastSessionState) {   // on stateQueue
        guard known[id]?.isCast == true else { return }
        let before = known[id]?.connectionState
        defer {
            // `cast_row_state` on a REAL row change only: a teardown `.idle`, or
            // a late state a "still desired" guard dropped, moves nothing.
            if let device = known[id], device.connectionState != before { logCastRowState(device) }
        }
        switch state {
        case .connecting:
            // Only while still desired: a late `.connecting` from a session
            // being torn down must not resurrect a spinner on a deselected row.
            if expectedSelected.contains(id) { setConnectionState(.connecting, for: id) }
        case .playing:
            // Same "only while still desired" test as `.connecting`: a receiver's
            // first PLAYING can land after a deselect has already written `.off`,
            // and an unguarded write would show a deselected row as connected.
            guard expectedSelected.contains(id) else { break }
            castPlaying.insert(id)
            setConnectionState(.connected, for: id)
        case .failed(let failure):
            castPlaying.remove(id)
            let cause: ConnectionFailure.Cause
            let detail: String?
            switch failure {
            case .timedOut:
                cause = .timedOut
                detail = nil
            case .appUnavailable(let reason):
                cause = .castAppUnavailable
                detail = reason
            case .connectionFailed(let message):
                cause = .castConnectionFailed
                detail = message
            case .dropped(let message):
                cause = .droppedMidStream
                detail = message
            case .noLocalAddress:
                cause = .castConnectionFailed
                detail = "no local IPv4 address"
            }
            setConnectionState(.failed(ConnectionFailure(cause: cause, detail: detail)), for: id)
        case .idle:
            // Teardown acknowledgement only — the row's `.off` was already set
            // by whichever gesture caused the teardown.
            castPlaying.remove(id)
        }
        // CAST-SYNC: a receiver that failed stops holding the room back, and
        // one that came back starts again — both are `R` moving.
        if updateCastRoomDelayLocked() { roomDelayChangedLocked(cause: "cast_session_state") }
    }

    /// CAST-SYNC: recompute which Cast receivers contribute a room-delay term
    /// — every SELECTED one whose session has not failed. Returns whether `R`
    /// moved. On `stateQueue`; the only writer of the policy's receiver set.
    @discardableResult
    private func updateCastRoomDelayLocked() -> Bool {   // on stateQueue
        let contributing = castSelectedIDs.filter { id in
            if case .failed = known[id]?.connectionState { return false }
            return true
        }
        return castRoomDelay.setReceivers(contributing)
    }

    /// CAST-SYNC (brief §4): one lead measurement the session manager judged
    /// trustworthy. Most change nothing — the policy only speaks up when a
    /// receiver settles. On `stateQueue`.
    private func applyCastLeadSample(_ id: String, _ leadMs: Int) {   // on stateQueue
        guard let settlement = castRoomDelay.ingest(leadMs: leadMs, forID: id) else { return }
        Telemetry.log(.cast, "cast_lead_settled", [
            "device": id,
            "lead_ms": String(settlement.leadMs),
            "refused": settlement.refused ? "1" : "0",
            "term_ms": _castTermMs.map(String.init) ?? "nil",
        ])
        guard settlement.termMoved else {
            // The term stayed put, so the ROOM did not move — but this
            // receiver's share of it just did, and it is the only output that
            // needs telling. Pushing the whole room fan-out here would
            // re-anchor every Bluetooth and local sink for a change none of
            // them can see.
            pushCastFeedDelaysLocked()
            return
        }
        roomDelayChangedLocked(cause: "cast_lead")
    }

    /// CAST-SYNC: hand every settled receiver the part of the room delay it
    /// does not already produce by itself. On `stateQueue`.
    ///
    /// Called on BOTH edges that can change a receiver's share: the room delay
    /// moving, and a receiver settling. The second one is easy to miss — a
    /// receiver that settles BELOW the current term leaves `R` alone, so
    /// nothing about the room changed, but that receiver's own share just went
    /// UP by the difference. Live 2026-08-29: a reselect restored a remembered
    /// term of 5916 ms while the receiver settled at 5462, and with this
    /// keyed off the room alone the 454 ms never got inserted — the Cast leg
    /// ran that much ahead of everything else, which is plainly audible.
    private func pushCastFeedDelaysLocked() {   // on stateQueue
        // The per-receiver Cast feed lines are the fourth leg of this fan-out.
        // Each receiver's feed is held back by `room − settledLeadMs`, the part
        // of the room delay it does not already produce by itself. For the
        // furthest-behind receiver — the one that SET the term — that remainder
        // is a few tens of ms; for a SECOND, faster receiver it is seconds, and
        // it is the whole reason this leg exists.
        //
        // Three receivers are deliberately skipped, and in every case the point
        // is that no delay line gets allocated: one still settling has no
        // trustworthy lead to subtract, one refused for exceeding `R_max` plays
        // unsynced by policy, and one whose remainder is zero already meets the
        // room. `setCastRoomDelayMs` hops to the manager's own queue, so this
        // stays a plain call from `stateQueue`.
        let room = roomDelayLocked()
        let refusedIDs = castRoomDelay.refusedIDs
        for id in castSelectedIDs where !refusedIDs.contains(id) {
            guard let settled = castRoomDelay.settledLeadMs(forID: id) else { continue }
            let remainder = room - settled
            guard remainder > 0 else { continue }
            castOutputManager?.setCastRoomDelayMs(remainder, forDeviceID: id)
        }
    }

    /// CAST-SYNC (brief §3): the room delay moved — hand `R` to every output
    /// that has to delay itself to it. On `stateQueue`.
    ///
    /// The Bluetooth sinks and the Mac's own sink read `R` live and re-sample
    /// it whenever they re-anchor, so a nudge is all they need. The AirPlay
    /// feed has no such loop and is held back explicitly, by a line in FRONT
    /// of the engine: the sender reads its start buffer once, at session
    /// creation, and clamps it to 5 s, so it cannot carry seconds of room
    /// delay however it is set.
    ///
    /// A Cast join also flips the BT composition, so those sinks can take this
    /// re-anchor on top of that transition's rebuild — the same hold restarted
    /// a queue hop later, not a second gap.
    private func roomDelayChangedLocked(cause: String) {   // on stateQueue
        let airPlayPreDelayMs = publishAirPlayPreDelayLocked()
        let btRides = btSinkEnabled
        let macRides = syncedLocalSinkApplied
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            if btRides { self.btSink?.reanchorAll(cause: "room_delay_change") }
            if macRides { self.syncedLocalSink?.requestReanchor(cause: "room_delay_change") }
        }
        pushCastFeedDelaysLocked()
        Telemetry.log(.cast, "room_delay_changed", [
            "cause": cause,
            "room_ms": String(roomDelayLocked()),
            "cast_term_ms": _castTermMs.map(String.init) ?? "nil",
            "airplay_pre_ms": String(airPlayPreDelayMs),
        ])
    }

    /// Hold the AirPlay feed back by the part of the room delay the sender does
    /// not already provide, and return what was published. Idempotent — the
    /// same depth twice is one word written on the control thread — so it is
    /// also what a selection change calls when the room did not move but the
    /// devices meeting it did. On `stateQueue`.
    @discardableResult
    private func publishAirPlayPreDelayLocked() -> Int {   // on stateQueue
        // No AirPlay device, no line: nothing would read it, and it is a
        // megabyte and a memcpy per buffer. An output also cannot be delayed by
        // less than nothing — and `0` publishes NO line rather than an empty
        // one, which is the whole bypass: a room that leaves Cast is back to
        // today's exact bytes on the very next buffer.
        //
        // Read from the SELECTION, never from `btComposition`: that memo is
        // only refreshed when the Bluetooth side moves, so in an AirPlay+Cast
        // room with no Bluetooth in it it never becomes true at all.
        let airPlayPresent = expectedSelected.contains { id in
            known[id].map { !$0.isBluetooth && !$0.isLocalDevice && !$0.isCast } == true
        }
        let ms = airPlayPresent ? Swift.max(0, roomDelayLocked() - _startBufferMs) : 0
        captureControlQueue.async { [weak self] in
            self?.captureCoordinator?.setAirPlayPreDelay(ms: ms)
        }
        return ms
    }

    /// Fold one `BTConnectionManager.connect` outcome into the row's
    /// connection state (and, on success, the sink set). Availability itself
    /// still arrives via the enumerator refresh the connect notification fires —
    /// this is the row's lifecycle answer, not a parallel availability source.
    private func finishBTReconnect(id: String, outcome: BTConnectOutcome) {
        stateQueue.async {
            switch outcome {
            case .connected:
                // BT-LIFECYCLE: a baseband connect is not yet audio. A SELECTED
                // id keeps breathing until its sink renders; an UNSELECTED one
                // goes straight to `.off` — nothing will flow to it by design,
                // so a hold there could only spin forever.
                if self.expectedSelected.contains(id) {
                    self.beginBTConnectingLocked(id)
                } else {
                    self.setConnectionState(.off, for: id)
                }
                // Wave-3 known gap, closed: a SELECTED id that just came back
                // re-enters the per-device sink set now, not at the next
                // selection change.
                self.reapplyBTSinkLocked()
            case .unauthorized:
                self.setConnectionState(.failed(ConnectionFailure(
                    cause: .unknown, detail: "Bluetooth permission not granted")), for: id)
            case .failed(let elapsed, let reason):
                // Live-measured classification (bt-spike-findings-2026-08-07):
                // a powered-off speaker holds the OS attempt ~15.4 s (both
                // brands) or hits our 20 s ceiling; a speaker another host
                // holds refuses fast. The slow case reads `.unknown` — headline
                // "Couldn't connect", matching AirPlay's generic failure (Alec,
                // 2026-08-07) — rather than the AirPlay-flavored `.timedOut`.
                let cause: ConnectionFailure.Cause =
                    (reason == "timeout" || elapsed >= 10) ? .unknown : .connectedElsewhere
                self.setConnectionState(.failed(ConnectionFailure(
                    cause: cause,
                    detail: "\(reason) after \(String(format: "%.1f", elapsed))s")), for: id)
            }
        }
    }

    // MARK: BT-only reference timeline (roadmap 056 Part A)

    /// How far past the slowest known speaker the BT-only reference sits. A
    /// speaker can only be fed EARLY by shortening its delay, so the reference
    /// has to be at least its latency; the margin leaves room for the user's
    /// trim on top of a freshly measured device.
    static let btReferenceHeadroomMs = 100
    /// The reference a Bluetooth-target wizard run pins the timeline to. The
    /// latency it is about to measure is unknown by definition, so the search
    /// needs room to reach any plausible A2DP/DSP latency instead of pinning
    /// against a 500 ms floor and bowing out "unreachable".
    ///
    /// 2 s, not the 1.5 s it was: ``btWizardLatencyRangeMs`` now stops one
    /// default BT-only buffer SHORT of the reference (a candidate at the
    /// reference itself is a delay of 0 — the ring seeked dry, silent for the
    /// rest of the session), so the reference has to carry that buffer on top
    /// for the reachable latency span to stay the ~1.5 s the search needs.
    static let btWizardReferenceBufferMs = 2_000

    /// The BT-only reference for a selection: never below the
    /// ``BTSyncedSink/defaultBTOnlyBufferMs`` floor, and always far enough
    /// ahead of the slowest MEASURED latency among the selected devices that
    /// its delay does not hit `SyncTiming.totalDelayNanos`'s ≥ 0 clamp. Devices
    /// with no measurement contribute nothing — an unknown latency is treated
    /// as within the floor until the wizard says otherwise.
    static func btOnlyReferenceMs(latencies: [String: Double], uids: [String]) -> Int {
        let slowest = uids.compactMap { latencies[$0] }.max() ?? 0
        return Swift.max(BTSyncedSink.defaultBTOnlyBufferMs,
                         Int(slowest.rounded()) + btReferenceHeadroomMs)
    }

    /// Recompute the BT-only reference and, if it moved, push it to the sink
    /// manager and re-anchor the Mac's own sink (which rides the same reference
    /// in this composition). Returns the value now in force, so the caller can
    /// hand it straight to ``applyBTSinkTransition(...)``. On `stateQueue`.
    @discardableResult
    private func updateBTReferenceBufferLocked() -> Int {   // on stateQueue
        let latencies = btTrimLock.withLock { btLatencyMsByUID }
        let desired = btWizardReferenceRaised
            ? Self.btWizardReferenceBufferMs
            : Self.btOnlyReferenceMs(latencies: latencies, uids: btSelectedUIDs)
        guard desired != btReferenceBufferMs else { return desired }
        btReferenceBufferMs = desired
        let localRides =
            btSinkEnabled && !btComposition.usesPresentationReference && syncedLocalSinkApplied
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            self.btSink?.setBTOnlyBufferMs(desired)
            // Wave-4 delay agreement: with no AirPlay in the group the Mac's
            // own sink schedules against this same buffer, so a move of the
            // reference is a move for it too.
            if localRides { self.syncedLocalSink?.requestReanchor(cause: "bt_composition_change") }
        }
        return desired
    }

    /// Wave-4 reconnect-reapply: re-run the CURRENT BT sink decision so a
    /// selected device that just (re)appeared resolves a live `AudioObjectID`
    /// and re-enters the per-device set (and one that vanished drops out). The
    /// decision itself is unchanged — only the UID→device resolution is redone,
    /// which `applyBTSinkTransition` performs fresh on every apply. On
    /// `stateQueue`.
    private func reapplyBTSinkLocked() {
        guard btSinkEnabled else { return }
        let uids = btSelectedUIDs
        let composition = btComposition
        let gains = btSinkGains(forUIDs: uids)
        let referenceMs = updateBTReferenceBufferLocked()
        let eqs = btSinkEQs(forUIDs: uids)
        captureControlQueue.async { [weak self] in
            self?.applyBTSinkTransition(
                enable: true, uids: uids, composition: composition, gains: gains,
                eqs: eqs, referenceBufferMs: referenceMs)
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
    ///
    /// `gain` is the `group × Mac's-own-fader` product captured in the SAME
    /// `stateQueue` critical section that decided this transition — applied here so a
    /// trim made while "play everywhere" was off (or before the sink was ever built)
    /// is in force from the first rendered buffer instead of starting at unity.
    private func applySyncedLocalSinkTransition(enable: Bool, gain: Float) {
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
            sink.setGain(gain)
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

    /// T1: record another coalesced synced-local toggle and (re)schedule the
    /// trailing-edge settle. Mirrors `armWakeWatchdog`'s idiom exactly — cancel
    /// the pending `DispatchWorkItem` and re-arm it on `stateQueue`, so the body
    /// runs serialized with every other state mutation and a supersede simply
    /// drops the older one. MUST hold `stateQueue`.
    private func scheduleSyncedLocalSettleLocked() {   // on stateQueue
        self.syncedLocalCoalescedCount += 1
        self.pendingSyncedLocalSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fireSyncedLocalSettle() }
        self.pendingSyncedLocalSettle = work
        // Scheduled ON `stateQueue`, so a newer toggle's cancel (above) before this
        // fires simply drops it — no double-firing, no stale work after a newer
        // decision landed.
        self.stateQueue.asyncAfter(
            deadline: .now() + Self.syncedLocalSettleWindow, execute: work)
    }

    /// T1/T2: the quiet window elapsed — run AT MOST one real transition for the
    /// whole coalesced burst, and re-establish the receiver session exactly once
    /// IFF the burst genuinely churned. On `stateQueue` (scheduled there).
    private func fireSyncedLocalSettle() {   // on stateQueue (scheduled there)
        self.pendingSyncedLocalSettle = nil
        let coalesced = self.syncedLocalCoalescedCount
        self.syncedLocalCoalescedCount = 0
        let desired = self.syncedLocalSinkEnabled
        let gain = self.syncedLocalGain

        // Net no-op: a burst that collapsed back to the currently-applied state
        // (e.g. on→off→on while already on, or on→off while already off) never
        // tore the tap/sink down, so there is NOTHING to apply — and, critically,
        // NOTHING to re-sync. Bailing here keeps the T2 reset off this path.
        guard desired != self.syncedLocalSinkApplied else { return }
        self.syncedLocalSinkApplied = desired

        // Churn = the settle absorbed ≥2 distinct toggle decisions (rapid
        // clicking). A NORMAL single toggle coalesces exactly one decision and
        // MUST NEVER take the reset branch — that redundant RTP re-establish on
        // every ordinary connect is the exact bug a prior fix removed
        // (`dev/notes/synced-local-mixed-selection-dropout-fix.md`). This is the
        // sharpest correctness constraint in the fix.
        let churned = coalesced >= 2

        // Runs on `captureControlQueue` — the same serial queue the capture gate's
        // start/stop is enqueued on — so a tap recreate triggered by
        // `attachSyncedLocalSink` (self-exclude pid change, T-FANOUT) never races a
        // capture-gate start/stop for the same tap.
        self.captureControlQueue.async { [weak self] in
            guard let self else { return }
            self.applySyncedLocalSinkTransition(enable: desired, gain: gain)
            if churned {
                // Rapid toggling drove many tap rebuilds with NO receiver-session
                // reset (an `.exclusionChange` rebuild deliberately skips it),
                // desyncing/corrupting the receiver even while the Mac-side capture
                // reports healthy — the permanent-silence bug. Now that the tap has
                // settled into `desired`, re-establish the session ONCE.
                // `resetAirPlaySessionForWholeSystem` is already single-flighted
                // (per-device `converging` claim + `rebindRecoveryGen`) and
                // ownership-guarded (`stillOwnsRebind`), so this can't fight a
                // concurrent converge or thrash a healthy session.
                Telemetry.log(.airplay, "synced_local_churn_resync", [
                    "coalesced": "\(coalesced)", "desired": "\(desired)",
                ])
                self.resetAirPlaySessionForWholeSystem()
            }
        }
    }

    // MARK: Bluetooth sink transitions (BT-BACKEND)

    /// Execute the BT enable/disable/reconcile `setOutputSet` decided. Must run
    /// on `captureControlQueue` — serial with the capture gate's start/stop and
    /// the synced-local transitions, so nothing here can race a tap rebuild.
    ///
    /// Enable order: composition first (a fresh sink's one-time anchor samples
    /// its delay provider, so the reference must already be right), then the
    /// device set (the manager reconciles and starts new per-device sinks while
    /// armed), then the fan-out attach, then `start()` (idempotent). Disable
    /// mirrors it: stop → drop the per-device sinks (releases their
    /// `AVAudioEngine`s; offsets/trims live in the manager's own tables and
    /// survive) → detach the fan-out.
    ///
    /// No settle debounce, unlike the synced-local transition: attaching the BT
    /// fan-out never rebuilds the tap (`setBTSink` is compare-before-rebuild
    /// and the render pid is our own already-excluded process), so the storm
    /// that debounce exists for cannot start here.
    private func applyBTSinkTransition(
        enable: Bool, uids: [String], composition: BTGroupComposition,
        gains: [String: Float] = [:], eqs: [String: DeviceEQ] = [:],
        referenceBufferMs: Int? = nil
    ) {
        if enable {
            let sink: BTSyncedSinkControlling
            if let existing = btSink {
                sink = existing
            } else if let factory = btSyncedSinkFactory {
                sink = factory()
                btSinkRefLock.withLock { btSink = sink }
            } else {
                return   // no factory wired (tests / UI-only smoke) — inert
            }
            sink.setComposition(composition)
            // The BT-only reference this selection needs (roadmap 056 Part A):
            // pushed with the composition, BEFORE `setDevices` builds any sink,
            // so a fresh sink anchors against the right timeline first time.
            if let referenceBufferMs { sink.setBTOnlyBufferMs(referenceBufferMs) }
            // Persisted SYNC trims (BT-OFFSET-UI), re-pushed on every enable so
            // a sink built after launch — or rebuilt after a reconnect — starts
            // from the saved values. Idempotent: the sink ignores a same-value
            // write, so this never forces a rebuild on its own.
            let (trims, latencies) = btTrimLock.withLock { (btTrimsByUID, btLatencyMsByUID) }
            for (uid, ms) in trims {
                sink.setTrimMs(ms, forDeviceUID: uid)
            }
            // Measured latencies (roadmap 056 Part A), re-pushed for the same
            // reason as the trims: a sink built after launch must start from
            // what the wizard already learned about this speaker, not from 0.
            for (uid, ms) in latencies {
                sink.setOffsetMs(Int(ms.rounded()), forDeviceUID: uid)
            }
            // Composed gains (`btSinkGain`: user volume × masters, 0 while
            // held/muted) land BEFORE the device set, so a sink created by
            // `setDevices` below starts at the user's level — or already muted
            // for a W3 hold (the manager remembers per-UID gains for exactly
            // this ordering), never at a hardcoded 1 or 0.
            for uid in uids {
                sink.setGain(gains[uid] ?? 1, forDeviceUID: uid)
            }
            // Tone, on the same re-push-on-every-arm footing as the trims above:
            // the manager remembers it per uid, so a sink created by `setDevices`
            // below starts already shaped instead of playing a few flat buffers.
            for uid in uids {
                sink.setEQ(eqs[uid] ?? .flat, forDeviceUID: uid)
            }
            // UID → live AudioObjectID, resolved fresh per apply. A uid that no
            // longer resolves (the speaker dropped between selection and apply)
            // contributes no sink; it re-resolves on the next selection change
            // (reconnect-driven re-application is BT-RECONNECT's, Wave 4).
            sink.setDevices(uids.compactMap { uid in
                let deviceID = btDeviceIDForUID?(uid) ?? aggregateControl.resolveDeviceID(forUID: uid)
                return deviceID.map { BTSyncedSink.DeviceSpec(deviceID: $0, uid: uid) }
            })
            attachBTSink(sink)
            sink.start()
        } else {
            guard let sink = btSink else { return }
            sink.stop()
            sink.setDevices([])
            attachBTSink(nil)
        }
    }

    /// Apply one Cast selection decision (CAST-OUT). On `captureControlQueue`,
    /// like ``applyBTSinkTransition(enable:uids:composition:gains:)``, so a Cast
    /// transition can never race a tap start/stop or a BT transition.
    ///
    /// The fan-out slot is attached exactly once per armed stretch — the pid is
    /// our own already-tap-excluded process, so attaching costs no tap rebuild,
    /// but re-attaching on every selection change would still churn the
    /// snapshot for nothing.
    private func applyCastTransition(
        enable: Bool, records: [CastDeviceRecord], levels: [String: Double]
    ) {   // on captureControlQueue
        guard let manager = castOutputManager else { return }
        if enable {
            if !castFeedAttached {
                captureCoordinator?.setCastSink(manager.feed, renderProcessPID: getpid())
                castFeedAttached = true
            }
            manager.setDevices(records)
            // Composed levels land after the device set: a session that has not
            // reached its receiver yet stores the level and pushes it as soon
            // as the channel is live.
            for (id, level) in levels {
                manager.setLevel(level, forDevice: id)
            }
            // CAST-SYNC: an arm re-states every receiver's stored by-ear offset,
            // so reselecting one brings its offset back rather than leaving the
            // delay line at whatever the last armed stretch left there.
            pushStoredCastUserOffsets(forDeviceIDs: records.map(\.id))
        } else {
            manager.setDevices([])
            if castFeedAttached {
                captureCoordinator?.setCastSink(nil, renderProcessPID: nil)
                castFeedAttached = false
            }
        }
    }

    // MARK: First-mix alignment intercept (W3)

    /// Arm (or re-arm) the give-up watchdog for one held uid. On `stateQueue`.
    private func scheduleBTAlignmentHoldWatchdogLocked(_ uid: String) {   // on stateQueue
        btAlignmentHoldWatchdogs[uid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.btAlignmentHeldUIDs.contains(uid) else { return }
            Telemetry.log(.localPlayback, "bt_alignment_hold_timeout", ["device": uid])
            self.releaseBTAlignmentHoldLocked(uid)
        }
        btAlignmentHoldWatchdogs[uid] = work
        stateQueue.asyncAfter(deadline: .now() + btAlignmentHoldTimeout, execute: work)
    }

    /// Drop one uid's hold and un-mute its sink. Records nothing — recording
    /// (a dismissal) is the RESOLVE path's business, not the release's. On
    /// `stateQueue`; idempotent.
    private func releaseBTAlignmentHoldLocked(_ uid: String) {   // on stateQueue
        btAlignmentHoldWatchdogs[uid]?.cancel()
        btAlignmentHoldWatchdogs[uid] = nil
        guard btAlignmentHeldUIDs.remove(uid) != nil else { return }
        // The release pushes the COMPOSED user gain (never a hardcoded 1) —
        // releasing the hold must not blow away the user's volume, and the
        // push (vs merely forgetting the hold) keeps the manager's remembered
        // gain clean for the next select.
        pushBTSinkGainLocked(uid)
    }

    // MARK: Bluetooth connect lifecycle (BT-LIFECYCLE)

    /// Start a selected BT id breathing and arm the watch that ends the hold.
    ///
    /// A BT id has no engine session, so no AirPlay-lifecycle transition can
    /// ever move it off `.off` — this is the ONLY road to `.connected` for a
    /// Bluetooth row, and `.connected` is what lights its armed dot and mounts
    /// its meter. The hold ends on the device's own delay gate opening, not on
    /// its engine starting: the engine is up long before a note comes out, so
    /// promoting on "sink running" would put the dot ahead of the music.
    ///
    /// Callers own the precondition that a connect is even plausible — a
    /// selected-but-unavailable row stays `.off` (nothing is connecting), while
    /// a just-succeeded baseband connect arms regardless of whether the
    /// enumerator snapshot has caught up yet. On `stateQueue`.
    private func beginBTConnectingLocked(_ id: String) {   // on stateQueue
        guard expectedSelected.contains(id), known[id]?.isBluetooth == true else { return }
        setConnectionState(.connecting, for: id)
        btConnectingDeadlines[id] = Date().addingTimeInterval(btRenderStartTimeout)
        scheduleBTRenderPollLocked()
    }

    /// Arm the poll unless one is already in flight (or nothing is breathing).
    /// On `stateQueue`.
    private func scheduleBTRenderPollLocked() {   // on stateQueue
        guard btRenderPollWork == nil, !btConnectingDeadlines.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.pollBTRenderStart() }
        btRenderPollWork = work
        stateQueue.asyncAfter(deadline: .now() + Self.btRenderPollInterval, execute: work)
    }

    /// Read the rendering set off `captureControlQueue` (which owns `btSink`)
    /// and fold it back in on `stateQueue`. On `stateQueue` (scheduled there).
    private func pollBTRenderStart() {   // on stateQueue
        btRenderPollWork = nil
        guard !btConnectingDeadlines.isEmpty else { return }
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            let rendering = self.btSink?.renderingDeviceUIDs() ?? []
            let anchored = self.btSink?.anchoredDeviceUIDs()
            self.stateQueue.async { self.applyBTRenderStart(rendering, anchored: anchored) }
        }
    }

    /// End every hold that has an answer — rendering wins first, then the
    /// ceiling — and re-arm the poll for whatever is still breathing. A row
    /// deselected mid-hold just drops out: the deselect edge already wrote its
    /// own `.off`. On `stateQueue`.
    ///
    /// The ceiling only means FAILURE for a device that was handed audio and
    /// still never started playing it. A device that was handed nothing is
    /// idle, not broken: with the Mac silent the capture fan-out never calls
    /// `enqueue`, so no sink can anchor and none can ever render. Failing on
    /// the ceiling alone reported "no audio started" for a perfectly healthy
    /// speaker selected while paused — the link is up, and it will play the
    /// moment there is anything to play. Whether sound is actually moving is
    /// what the armed dot and the meter are for; the connection state must not
    /// try to answer it too.
    private func applyBTRenderStart(
        _ rendering: Set<String>, anchored: Set<String>?
    ) {   // on stateQueue
        let now = Date()
        for (id, deadline) in btConnectingDeadlines {
            guard expectedSelected.contains(id) else {
                btConnectingDeadlines[id] = nil
                continue
            }
            if rendering.contains(id) {
                btConnectingDeadlines[id] = nil
                setConnectionState(.connected, for: id)
            } else if now >= deadline {
                btConnectingDeadlines[id] = nil
                guard anchored?.contains(id) ?? true else {
                    setConnectionState(.connected, for: id)
                    Telemetry.log(.localPlayback, "bt_render_start_idle", ["device": id])
                    continue
                }
                setConnectionState(.failed(ConnectionFailure(
                    cause: .unknown, detail: "no audio started")), for: id)
                Telemetry.log(.localPlayback, "bt_render_start_timeout", ["device": id])
            }
        }
        scheduleBTRenderPollLocked()
    }

    /// Mirror of `attachSyncedLocalSink` for the BT fan-out: same render-process
    /// identity (the per-device sinks are in-process `AVAudioEngine`s, so their
    /// output is attributed to us), same echo-prevention contract (R-echo).
    private func attachBTSink(_ sink: SyncedLocalPCMSink?) {
        let renderProcessPID: pid_t? = (sink == nil) ? nil : getpid()
        captureCoordinator?.setBTSink(sink, renderProcessPID: renderProcessPID)
    }

    // MARK: Per-app routing (T6 — ADDITIVE to the Selected Devices path above)

    /// Whether a `.device(id:)` route pointed at `id` can actually carry audio
    /// RIGHT NOW: the device is in our discovered snapshot, reports itself
    /// reachable, and has an engine output handle to stream through. On
    /// `stateQueue`.
    ///
    /// This is the whole basis of the effective route table below (R5). A route
    /// aimed at an unreachable receiver is intent, not a live redirect: honouring
    /// it would pull the app out of the whole-system tap and hand its audio to a
    /// stream that goes nowhere, i.e. silence the app. An UNKNOWN id counts as
    /// unreachable, which is also what makes launch safe — persisted routes are
    /// pushed in before discovery has found anything, and each one engages as its
    /// device shows up.
    private func isRouteTargetReachableLocked(_ id: String) -> Bool {   // on stateQueue
        known[id]?.isAvailable == true && outputIDs[id] != nil
    }

    /// Whether whole-system routing (stream 0) CLAIMS `id` at the DECISION layer —
    /// pure selection intent (`expectedSelected`), set atomically in one place
    /// (`setOutputSet`; `activateGroup` funnels through it) and stable across
    /// `applyStartBuffer`'s internal `desiredOn` flap. Roadmap 008 mechanism 1
    /// (demote-at-decision): whole-system always wins a contested device, and the
    /// losing `.device` route reads as effective-`.noRedirect` so the app audibly
    /// rejoins the whole-system mix — the exact semantics R5 already gives an
    /// unreachable target. On `stateQueue`.
    private func isWholeSystemClaimedLocked(_ id: String) -> Bool {   // on stateQueue
        expectedSelected.contains(id)
    }

    /// Whether whole-system routing OPERATIONALLY claims `id` at the EXECUTION
    /// layer: desired on, mid-converge, or holding a live stream-0 session
    /// (`added`). The fire-time gates (roadmap 008 mechanism 2) key on this — not
    /// on intent alone — because their job is precisely the in-flight window
    /// intent cannot see: a deselected device whose teardown `removeOutput` is
    /// still in flight is still whole-system-owned at the engine. On `stateQueue`.
    private func isWholeSystemOperationallyClaimedLocked(_ id: String) -> Bool {   // on stateQueue
        desiredOn[id] == true || converging.contains(id) || added.contains(id)
    }

    /// Reachable AND not whole-system-claimed — the full eligibility test a
    /// `.device` route target must pass to be honored (R5 + roadmap 008). The
    /// reachability helper above stays pure on purpose. On `stateQueue`.
    private func isRouteTargetEligibleLocked(_ id: String) -> Bool {   // on stateQueue
        isRouteTargetReachableLocked(id) && !isWholeSystemClaimedLocked(id)
    }

    /// `routes` with every `.device` route whose target is unreachable right now
    /// demoted to `.noRedirect` — the EFFECTIVE table, which is what all of the
    /// per-app machinery keys off (R5). On `stateQueue`.
    ///
    /// Demoting to `.noRedirect` (rather than dropping the route) is what makes the
    /// app rejoin the system mix: `.noRedirect` is exclusion-equivalent to having no
    /// route at all, so the bundle ID leaves `routedBundleIDs`, its per-app tap
    /// stops, and the whole-system tap stops excluding it — it plays through
    /// whatever the user's current top-level selection outputs to. Deliberately NOT
    /// `.currentDevice`, which would open a private local stream and pin the app to
    /// the Mac instead of following the system.
    ///
    /// The USER's table (`lastRoutes`, and the persisted store above it) is never
    /// rewritten by this — that is the difference between R5 and the old
    /// reset-on-unavailable behavior, and it is what lets
    /// `rerunAppRoutesForReachabilityChange` restore the redirect with no
    /// route-table edit and no user action.
    private func effectiveAppRoutesLocked(_ routes: [AppRoute]) -> [AppRoute] {   // on stateQueue
        // Roadmap 008: demotion now keys on ELIGIBILITY (reachable AND not
        // whole-system-claimed), not bare reachability — a route whose target is a
        // Selected Device is demoted exactly like an unreachable one, so the app
        // rejoins the whole-system mix (which includes the contested device)
        // instead of streaming into the void. Claim demotions additionally keep an
        // edge-triggered, queryable conflict record (loud loser).
        var claimDemotions: [String: [String]] = [:]   // device id → demoted bundle ids
        let mapped = routes.map { route -> AppRoute in
            guard case .device(let id) = route.destination else { return route }
            let claimed = isWholeSystemClaimedLocked(id)
            guard claimed || !isRouteTargetReachableLocked(id) else { return route }
            if claimed { claimDemotions[id, default: []].append(route.bundleID) }
            var demoted = route
            demoted.destination = .noRedirect
            return demoted
        }
        reconcileScopeConflictsLocked(claimDemotions)
        return mapped
    }

    /// Edge-triggered bookkeeping for demote-at-decision (roadmap 008): diff the
    /// whole-system-claim demotions this resolve produced against the active
    /// conflict records, emitting `scope_conflict` telemetry only when a
    /// (device, routes) conflict engages, changes shape, or disengages — repeated
    /// resolves of an unchanged table are silent, so the single-domain op traces
    /// stay byte-identical. On `stateQueue`.
    private func reconcileScopeConflictsLocked(_ demotions: [String: [String]]) {   // on stateQueue
        for (deviceID, bundleIDs) in demotions {
            let sorted = bundleIDs.sorted()
            if lastScopeConflicts[deviceID]?.bundleIDs == sorted { continue }
            lastScopeConflicts[deviceID] = ScopeConflict(
                bundleIDs: sorted, stream: streamBindings[deviceID], date: Date())
            Telemetry.log(.airplay, "scope_conflict", [
                "device": deviceID, "winner": "wholeSystem", "stage": "routeDemoted",
                "bundleIDs": "[" + sorted.joined(separator: ",") + "]",
                "stream": streamBindings[deviceID].map(String.init) ?? "-",
            ])
        }
        for deviceID in lastScopeConflicts.keys where demotions[deviceID] == nil {
            lastScopeConflicts.removeValue(forKey: deviceID)
            Telemetry.log(.airplay, "scope_conflict", [
                "device": deviceID, "winner": "wholeSystem", "stage": "routeRestored",
            ])
        }
    }

    /// Re-push the CURRENT (unedited) route table so `effectiveAppRoutesLocked`
    /// re-resolves it — the recovery half of R5. A redirect target becoming
    /// reachable again must restart that app's per-app tap and put it back in the
    /// whole-system tap's exclusion set with no route-table mutation and no user
    /// action; a target becoming unreachable must do the reverse.
    ///
    /// Safe to call WITH `stateQueue` held (every caller does) because the work is
    /// only ENQUEUED here: `updateAppRoutes` takes `stateQueue` synchronously itself,
    /// so running it inline would deadlock. `captureControlQueue` is the same serial
    /// queue the capture gate uses, which keeps this ordered against the tap
    /// start/stops it causes. Reading the table at EXECUTION time (not capture time)
    /// means a genuine route edit landing in between wins instead of being clobbered
    /// by a stale snapshot.
    private func rerunAppRoutesForReachabilityChange() {
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            let (routes, excluded) = self.stateQueue.sync {
                (self.lastRoutes, self.lastExcludedBundleIDs)
            }
            guard !routes.isEmpty else { return }
            self.updateAppRoutes(routes, excludedBundleIDs: excluded)
        }
    }

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
    /// Every one of those four steps reads the EFFECTIVE table
    /// (``effectiveAppRoutesLocked(_:)``), not the raw one it was handed: a `.device`
    /// route whose target is unreachable right now is treated exactly as
    /// `.noRedirect` for the duration (R5), so the app keeps playing in the system
    /// mix instead of being excluded in favour of a stream that goes nowhere. Only
    /// `lastRoutes` (the user's intent, replayed by
    /// ``rerunAppRoutesForReachabilityChange()``) and the display-name map keep the
    /// raw table. Re-calling this with an unchanged table is therefore MEANINGFUL,
    /// not a no-op — it is how a reachability change is applied.
    ///
    /// Concurrency: the routed-bundle-ID diff and the display-name refresh happen
    /// under `stateQueue` (serialized against concurrent calls). Everything that can
    /// BLOCK — `perAppCapture.start`/`stop` (Core Audio tap create/teardown), the
    /// `localPlaybackEngine` graph mutations, and the mixer's own queue hop — runs
    /// OUTSIDE `stateQueue`, the same discipline the capture gate keeps for
    /// `captureControlQueue`.
    public func updateAppRoutes(_ routes: [AppRoute], excludedBundleIDs: Set<String> = []) {
        // T6-rev: the other routing-action permission chokepoint. Same placement
        // and same non-blocking contract as `setOutputSet`'s — see `onRoutingAction`.
        onRoutingAction?()
        let plan: UpdateRoutesPlan = stateQueue.sync {
            self.lastRoutes = routes
            // Retained so the metering-only target set can subtract it and so a
            // denylist change alone re-reconciles the metering taps (T3, PRIVACY).
            self.lastExcludedBundleIDs = excludedBundleIDs
            self.routeDisplayNames = Dictionary(
                routes.map { ($0.bundleID, $0.displayName) }, uniquingKeysWith: { _, new in new })
            // R5: everything below keys off the EFFECTIVE table — a `.device` route
            // whose target is unreachable right now reads as `.noRedirect`, so the
            // app stays in the whole-system mix rather than being excluded in favour
            // of a stream that can't reach anything.
            let effective = self.effectiveAppRoutesLocked(routes)
            let newRouted = Set(effective.compactMap { route -> String? in
                if case .device = route.destination { return route.bundleID }
                return nil
            })
            // Bug T2: apps deliberately pinned to the local Mac ("Current Device").
            let newLocal = Set(effective.compactMap { route -> String? in
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
            // Bookkeeping-hygiene fix: unlike dead/retry tracking above,
            // `everCapturedBundleIDs` must ALSO forget a bundle that merely
            // drops OUT OF ROUTING while staying `stillPresent` in the table —
            // e.g. a `.device` -> `.noRedirect` -> `.device` toggle (same route
            // row, capture genuinely stops via `captureToStop` below and later
            // restarts fresh). Otherwise the later restart's `.capturing` misreads
            // as a RE-capture (see `everCapturedBundleIDs`'s doc comment) and fires
            // an unneeded `resetAirPlaySessionForRoutedApp`. `newRouted`/`newLocal`
            // are both subsets of `stillPresent`, so "not in either" is a strict
            // superset of the old `!stillPresent` condition — every bundle the old
            // check cleared is still cleared here, plus the toggle case.
            for bundleID in self.everCapturedBundleIDs
            where !newRouted.contains(bundleID) && !newLocal.contains(bundleID) {
                self.everCapturedBundleIDs.remove(bundleID)
            }

            // T8: the mixer only ever sees routes for bundle IDs that are actually
            // capturing — a `deadBundleIDs` entry (quit mid-stream, or a per-app tap
            // that's `.failed`) is excluded here so `.routedApps` / the engine stream
            // binding never claim a silent app is streaming.
            let mixerRoutes = effective.filter { !self.deadBundleIDs.contains($0.bundleID) }

            // The per-app tap is destination-agnostic — one tap serves whichever
            // destination the app currently routes to — so its start/stop keys on
            // the UNION of device- and local-routed apps. An app that merely SWITCHES
            // between `.device` and `.currentDevice` stays in both unions and keeps
            // its tap running (only the downstream consumer changes).
            let previousUnion = previousRouted.union(previousLocal)
            let newUnion = newRouted.union(newLocal)
            // R5: a bundle ID leaving the capture union must ALSO lose any pending
            // `.processNotYetAudible` retry. The T8 cleanup above keys on the RAW
            // table, which a demoted route is still in — so without this, a timer
            // armed while the route was live would fire later and re-`start` the
            // per-app tap for an app that is now supposed to be in the system mix.
            // That tap is `.mutedWhenTapped`: it would silence the app's normal
            // output while feeding a stream nothing is bound to. Re-engaging the
            // route restarts the tap through `captureToStart`, so nothing is lost.
            for bundleID in previousUnion.subtracting(newUnion) {
                self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
                self.retryCounts.removeValue(forKey: bundleID)
            }
            // T3: re-reconcile the metering-only taps against the new route/excluded
            // table (routed/local/excluded were all just updated above). Empty when
            // metering is inactive. NEVER touches the primary `perAppCapture` taps.
            let meteringDiff = self.meteringTapDiffLocked()
            return UpdateRoutesPlan(
                effectiveRoutes: effective,
                mixerRoutes: mixerRoutes,
                captureToStart: newUnion.subtracting(previousUnion),
                captureToStop: previousUnion.subtracting(newUnion),
                localRemoved: previousLocal.subtracting(newLocal),
                localRoutes: effective.filter { $0.destination == .currentDevice },
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
            //
            // R5: the EFFECTIVE table, so an app whose target is unreachable is NOT
            // excluded — that omission is exactly what puts it back in the system mix.
            //
            // OUR OWN render process needs no staging here: the coordinator's
            // exclusion resolve unconditionally self-excludes `getpid()` (the
            // generalized echo guard in `resolveExcludedObjectIDsLoggingAttribution`),
            // which covers `localPlaybackEngine`'s `.currentDevice` render and the
            // synced-local sink alike. An earlier version of this call also handed the
            // coordinator a `.currentDevice`-conditional render pid; with the
            // unconditional guard in place that only bought an extra tap rebuild whose
            // exclusion set was byte-identical to the one already in force.
            self.captureCoordinator?.updateRouting(
                appRoutes: plan.effectiveRoutes,
                excludedBundleIDs: excludedBundleIDs.union(plan.localExcluded))
        }
    }

    /// The off-`stateQueue` work `updateAppRoutes` computes under the lock and then
    /// executes without it — a named struct so the (now six-field) hand-off stays
    /// readable.
    private struct UpdateRoutesPlan {
        /// The route table as it is being ACTED on: the caller's table with every
        /// `.device` route whose target is currently unreachable demoted to
        /// `.noRedirect` (R5). This — not the raw table — is what the whole-system
        /// tap's exclusion set is computed from.
        let effectiveRoutes: [AppRoute]
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
    /// `.capturing` FIRST checks `bundleID` is still actually wanted (present in
    /// `routedBundleIDs` OR `localBundleIDs`) before accepting it — see the
    /// `isOrphan` branch below for why an orphaned capture can land here at all
    /// (a `.processNotYetAudible` retry racing a de-route) and why it must be
    /// stopped rather than accepted. Once accepted, it clears
    /// `deadBundleIDs`/`retryCounts`/`pendingRetries` for the bundle ID and, if it
    /// had been dead, re-includes it in the mixer topology.
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
            let (recovered, isRecapture, isOrphan): (Bool, Bool, Bool) = stateQueue.sync {
                // A capture can land here for a bundle ID nobody wants any more: a
                // `.processNotYetAudible` retry (`scheduleProcessNotYetAudibleRetry`)
                // scheduled BEFORE a de-route can fire AFTER it and SUCCEED — the app
                // started playing audio in the meantime, so `perAppCapture.start`
                // does NOT fail fast the way the retry's doc comment used to
                // (incorrectly) assume. That builds a brand-new coordinator slot
                // that nothing in `updateAppRoutes`'s route-table diff will ever
                // see again. Refuse it here rather than accept it.
                guard self.routedBundleIDs.contains(bundleID) || self.localBundleIDs.contains(bundleID) else {
                    return (false, false, true)
                }
                let wasDead = self.deadBundleIDs.remove(bundleID) != nil
                self.retryCounts.removeValue(forKey: bundleID)
                self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
                // First-ever capture inserts (isRecapture=false); a later capture
                // (tap rebuilt) is already present (isRecapture=true).
                let isRecapture = !self.everCapturedBundleIDs.insert(bundleID).inserted
                return (wasDead, isRecapture, false)
            }
            if isOrphan {
                // Nothing wants this tap any more — stop it rather than leave a
                // live (muted, per `TapMuteBehavior.mutedWhenTapped`) Core Audio
                // tap + private aggregate device + IOProc running in coreaudiod
                // forever for a bundle ID that is neither routed nor local.
                //
                // MUST be dispatched, never called inline: the `onStateChange`
                // callback that reached us fires SYNCHRONOUSLY from inside
                // `PerAppCaptureCoordinator`'s own private serial `queue`
                // (`transition(_:bundleID:to:)`, itself invoked from a
                // `queue.sync { … }` in `beginStart`/`handleDeviceChange`).
                // `PerAppCaptureCoordinator.stop(bundleID:)` ALSO does
                // `queue.sync { … }` on that SAME queue — calling it inline here
                // would recursively `sync` onto a serial queue we are already
                // executing on and deadlock the coordinator (and every per-app
                // capture app-wide) the very first time this race occurs.
                // `captureControlQueue` is the existing convention for
                // Core-Audio-touching work triggered by a route/state change (see
                // the comment above `updateAppRoutes`'s own hand-off to this same
                // queue, a few hundred lines up).
                captureControlQueue.async { [weak self] in
                    self?.perAppCapture.stop(bundleID: bundleID)
                }
                return
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
                    // Bookkeeping-hygiene fix: no retry is being scheduled from
                    // here (either the bundle isn't routed any more, or this is a
                    // NON-retryable failure while it still is) — a `pendingRetries`
                    // entry left over from the retry attempt that just landed here
                    // (or any earlier one) is now stale and must not linger as a
                    // dangling `DispatchWorkItem` reference.
                    self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
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
                    self.emit(.streamHealth(id: deviceID, recovering: true))
                    // T4: the trigger + generation bump for the rebind-recovery
                    // chain `enqueueRebindRecovery` is about to start (attempt 1)
                    // for this device. `scope` is the routed app whose per-app tap
                    // rebuild caused this — the one fact the attempt trail below
                    // can't otherwise carry.
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
                    Telemetry.log(.airplay, "whole_system_rebind_skipped", [
                        "device": deviceID, "reason": "already_converging",
                    ])
                    continue
                }
                self.converging.insert(deviceID)
                self.rebindConverging.insert(deviceID)
                let gen = (self.rebindRecoveryGen[deviceID] ?? 0) + 1
                self.rebindRecoveryGen[deviceID] = gen
                self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
                Telemetry.log(.airplay, "session_reset", [
                    "device": deviceID,
                    "scope": "wholeSystem",
                    "stream": "0",
                    "gen": "\(gen)",
                    "trigger": "recapture",
                    "recovery": "flush_first",
                ])
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
        case .perApp(let stream):
            // Roadmap 008: the WS-claim conjunct. A `.perApp` recovery firing in
            // the demotion-latency window (claim landed, eviction not yet
            // propagated through the mixer topology) still sees its
            // `streamBindings` slot set — without this conjunct it would
            // removeOutput→addOutput(N) and tear down the user's fresh stream-0
            // session. The `.wholeSystem` arm is NOT gated on the claim: it IS
            // the whole-system domain and holds the `converging` slot.
            return self.streamBindings[deviceID] == stream
                && !self.isWholeSystemOperationallyClaimedLocked(deviceID)
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
    /// `maxRebindRecoveryAttempts`, then gives up LOUDLY (a `"gave_up"` Telemetry
    /// outcome below) and
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
    ///
    /// `verifyFirst` (roadmap 008, whole-system scope only) selects the settle
    /// flavor `performBindOp`'s four-case unbind arm uses: read
    /// `engine.boundStreamId` and rebind ≥ 1 → 0, with ZERO engine ops when the
    /// session is already on 0 — instead of the teardown+re-add.
    private func enqueueRebindRecovery(
        deviceID: String, outputID: OutputID, scope: RebindScope, gen: Int, attempt: Int,
        verifyFirst: Bool = false
    ) {   // on stateQueue
        // T4: every call into this function — attempt 1 from
        // `resetAirPlaySessionForRoutedApp`, or a later attempt recursing from the
        // backoff `DispatchWorkItem` below — traces back to a tap-rebuild
        // recapture (the only call site today, so `trigger` is hardcoded rather
        // than threaded as a parameter — keeps this purely additive). Both call
        // sites already hold `stateQueue` (see their own `// on stateQueue`
        // markers), so this is just a format + non-blocking hand-off, same as the
        // other `Telemetry.log` calls already in this chain — no new locking, no
        // new await, no reordering of what follows.
        Telemetry.log(.airplay, "rebind", [
            "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt)",
            "trigger": "recapture", "outcome": "scheduled",
        ])
        let prev = self.bindTail
        self.bindTail = Task { [weak self] in
            await prev.value
            guard let self else { return }
            // Roadmap 008 pre-op gate: the same gen + ownership guard the
            // completion below runs, re-checked BEFORE the engine op. These chain
            // ops execute `performRebindRecovery` directly on `bindTail` — they
            // never pass through `performBindOp`'s fire-time gate — so without
            // this a superseded/ownership-lost chain would still issue its
            // remove/add pair and only THEN notice. On failure, skip the op and
            // fall through with `ok = false`: the completion's own guard takes
            // the terminal `superseded` exit (telemetry + slot release) exactly
            // as it always has. Uncontested chains pass both checks and their op
            // traces are unchanged.
            let preflightOK: Bool = self.stateQueue.sync {
                self.rebindRecoveryGen[deviceID] == gen
                    && self.stillOwnsRebind(deviceID: deviceID, scope: scope)
            }
            let ok = preflightOK
                ? await self.performRebindRecovery(outputID: outputID, scope: scope, verifyFirst: verifyFirst)
                : false
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
            let action: ConvergeReleaseAction = self.stateQueue.sync {
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
                        return self.releaseRebindConverging(id: deviceID)
                    }
                    return .none
                }
                if ok {
                    Telemetry.log(.airplay, "rebind", [
                        "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt)",
                        "trigger": "recapture", "outcome": "succeeded",
                    ])
                    self.rebindRecoveryGen.removeValue(forKey: deviceID)
                    self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
                    self.emit(.streamHealth(id: deviceID, recovering: false))
                    if case .wholeSystem = scope {
                        return self.releaseRebindConverging(id: deviceID)
                    }
                    return .none
                }
                guard attempt < self.maxRebindRecoveryAttempts else {
                    Telemetry.log(.airplay, "rebind", [
                        "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt)",
                        "trigger": "recapture", "outcome": "gave_up",
                    ])
                    self.rebindRecoveryGen.removeValue(forKey: deviceID)
                    self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
                    if case .wholeSystem = scope {
                        return self.releaseRebindConverging(id: deviceID)
                    }
                    return .none
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
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let action: ConvergeReleaseAction = self.stateQueue.sync {
                        // Superseded while waiting out the delay: a newer chain now
                        // owns this device's bookkeeping AND — for whole-system scope —
                        // its `converging` slot, so touch neither. Releasing or
                        // clearing here would pull the newer recovery's state out from
                        // under it.
                        guard self.rebindRecoveryGen[deviceID] == gen else {
                            // T4: the backed-off retry for `attempt + 1` never got
                            // to run. Without this line the trail goes silent after
                            // `retry_scheduled` with no explanation.
                            Telemetry.log(.airplay, "rebind", [
                                "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt + 1)",
                                "trigger": "recapture", "outcome": "superseded",
                                "reason": "gen_superseded_before_retry_fired",
                            ])
                            return .none
                        }
                        // Still the reigning chain, but the device no longer owns this
                        // session (or went away): a TERMINAL exit. The scheduling
                        // attempt deliberately kept the whole-system `converging` slot
                        // held ("still in progress") and nothing else will ever release
                        // it, so release it here like every other terminal exit does.
                        // Skipping this leaked the slot and permanently wedged the
                        // device (see `releaseRebindConverging`); the commonest way in
                        // is a sleep landing during the backoff, which clears `added`
                        // and so fails the ownership re-check below.
                        guard self.stillOwnsRebind(deviceID: deviceID, scope: scope),
                              let out = self.outputIDs[deviceID] else {
                            Telemetry.log(.airplay, "rebind", [
                                "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt + 1)",
                                "trigger": "recapture", "outcome": "superseded",
                                "reason": "state_changed_before_retry_fired",
                            ])
                            self.rebindRecoveryGen.removeValue(forKey: deviceID)
                            self.pendingRebindRecoveries.removeValue(forKey: deviceID)
                            self.emit(.streamHealth(id: deviceID, recovering: false))
                            if case .wholeSystem = scope {
                                return self.releaseRebindConverging(id: deviceID)
                            }
                            return .none
                        }
                        self.enqueueRebindRecovery(
                            deviceID: deviceID, outputID: out, scope: scope,
                            gen: gen, attempt: attempt + 1, verifyFirst: verifyFirst)
                        return .none
                    }
                    if action.redrivePerApp { self.replayPendingPerAppBindings(trigger: "ws_release") }
                    if let requeue = action.requeue {
                        Task { [weak self] in
                            await self?.convergeDevice(id: deviceID, outputID: requeue)
                        }
                    }
                }
                self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
                self.pendingRebindRecoveries[deviceID] = work
                DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
                return .none // still in progress — keep the `converging` slot held
            }
            if action.redrivePerApp { self.replayPendingPerAppBindings(trigger: "ws_release") }
            if let requeue = action.requeue {
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
    private func performRebindRecovery(
        outputID: OutputID, scope: RebindScope, verifyFirst: Bool = false
    ) async -> Bool {
        let label = Self.rebindScopeLabel(scope)
        Telemetry.log(.airplay, "rebind_recover_starting", ["output": "\(outputID)", "scope": label])

        // Roadmap 008 verify-first settle (whole-system only; see `performBindOp`'s
        // four-case unbind arm): arbitrate on ENGINE truth read AFTER the racing op
        // completed. Already on 0 (or no live session at all) → success with ZERO
        // engine ops; astray on a per-app stream (≥ 1, the silent-`.alreadyBound`
        // corruption) → one serialized `rebindOutput` to 0. No PTP gate here: an
        // astray session is a LIVE session, so the clock is already up (the same
        // reasoning the F-REANCHOR flush documents below). A throw feeds this
        // chain's normal backoff/give-up.
        if verifyFirst, case .wholeSystem = scope {
            let device = deviceID(for: outputID) ?? "\(outputID)"
            let live = await engine.boundStreamId(for: outputID)
            guard let live, live != 0 else {
                Telemetry.log(.airplay, "unbind_downgraded", ["device": device, "settled": "noop"])
                return true
            }
            do {
                try await engine.rebindOutput(outputID, toStreamId: 0)
                Telemetry.log(.airplay, "unbind_downgraded", ["device": device, "settled": "rebound"])
                return true
            } catch {
                Telemetry.log(.airplay, "rebind_recover_failed", [
                    "output": "\(outputID)", "scope": label, "error": "\(error)",
                ])
                return false
            }
        }

        // F-REANCHOR (2026-07-26): a tap rebuild's recovery used to be a full
        // removeOutput→addOutput (fresh RTSP/RTP session = the audible Sonos drop the
        // user hears on every headphone mode-change). For whole-system scope, try an
        // RTSP FLUSH re-anchor FIRST instead: it keeps the session alive and only
        // re-syncs the receiver's timeline. Observed to hold on the tested Sonos; not
        // yet proven across receiver models, so this is defended two ways: a flush
        // that DIDN'T issue (returns false — device not streaming / session gone) or
        // that throws falls through to the teardown+rebuild below, and the silence
        // watchdog remains the backstop if an issued flush fails to re-anchor on some
        // receiver. A flush can therefore never silently leave the device dead.
        // razor: whole-system only (that's the reported bug); per-app rebinds keep
        // the teardown path — per-app has no delivery gate for a two-tap overlap.
        if case .wholeSystem = scope {
            do {
                if try await engine.flushOutput(outputID) {
                    // A flush was ACTUALLY issued (re-anchored in place) — done.
                    Telemetry.log(.airplay, "rebind_recover_flush", [
                        "output": "\(outputID)", "scope": label, "outcome": "issued",
                    ])
                    return true
                }
                // flushOutput returned false: the vendored flush no-op'd (device not
                // STREAMING / session gone), so nothing re-anchored. Do NOT report
                // success — fall through to the teardown+re-add, which re-establishes
                // the session. Treating a no-op as success here was a silent-forever
                // regression an adversarial review caught.
                Telemetry.log(.airplay, "rebind_recover_flush", [
                    "output": "\(outputID)", "scope": label, "outcome": "noop_fallback",
                ])
            } catch {
                Telemetry.log(.airplay, "rebind_recover_flush", [
                    "output": "\(outputID)", "scope": label, "outcome": "failed_fallback",
                    "error": "\(error)",
                ])
                // fall through to teardown+rebuild
            }
        }

        // T5+T4 takeover gate, the same one every session-establishing engine op
        // runs behind — and DELIBERATELY only in front of the teardown+re-add
        // below, never the F-REANCHOR flush above it. The flush re-anchors the
        // session that is already up; it establishes nothing, needs no clock, and
        // gating it would have made the cheap in-place recovery inherit the gate's
        // real side effects — a default-output switch-away, the "taking over" strip
        // and a bounded activation wait — on a path whose entire point is to avoid
        // the audible drop a fresh session costs. A re-add is a different animal: a
        // clockless one re-establishes a session that plays silence, so it stays
        // gated. Practically instant mid-session (the clock is already up); on a
        // genuine refusal the `false` return feeds this chain's backoff/give-up.
        guard await ensurePTPTakeover(telemetryDeviceID: deviceID(for: outputID) ?? "\(outputID)") else {
            Telemetry.log(.airplay, "rebind_recover_failed", [
                "output": "\(outputID)", "scope": label, "error": "timingUnavailable",
            ])
            return false
        }

        try? await engine.removeOutput(outputID)
        do {
            switch scope {
            case .perApp(let stream): try await engine.addOutput(outputID, streamId: stream)
            case .wholeSystem:        try await engine.addOutput(outputID)
            }
            return true
        } catch {
            Telemetry.log(.airplay, "rebind_recover_failed", [
                "output": "\(outputID)", "scope": label, "error": "\(error)",
            ])
            return false
        }
    }

    /// `lastRoutes` resolved for the mixer: unreachable-target `.device` routes
    /// demoted (R5, ``effectiveAppRoutesLocked(_:)``), then any bundle ID currently
    /// in `deadBundleIDs` dropped (T8). Acquires `stateQueue` itself — call only
    /// from OUTSIDE any existing `stateQueue.sync` block (e.g. not from
    /// `updateAppRoutes`'s own critical section, which computes the equivalent
    /// inline to avoid a same-queue deadlock).
    private func effectiveMixerRoutes() -> [AppRoute] {
        stateQueue.sync {
            self.effectiveAppRoutesLocked(self.lastRoutes)
                .filter { !self.deadBundleIDs.contains($0.bundleID) }
        }
    }

    /// Schedule the next `.processNotYetAudible` retry with capped-exponential
    /// backoff (T8, edge case 3) — self-heals a route made just before the app
    /// started playing audio, and keeps re-probing an app that stays paused,
    /// without the user touching the UI again. The delay is
    /// `retryDelay × 2^(attempt-1)`, capped at `processNotYetAudibleMaxBackoff`
    /// (e.g. 2 → 4 → 8 → 10 → 10 … forever). Single-flighted: replaces any retry
    /// already pending for this bundle ID (so N `.failed` events never stack N
    /// timers).
    ///
    /// CORRECTED: this was previously documented as best-effort-safe on the
    /// assumption that "if the route is gone by the time the timer fires,
    /// `perAppCapture.start` fails fast (`.appNotRunning` or similar)". That is
    /// FALSE whenever the app has started playing audio by the time this fires —
    /// `start` then SUCCEEDS (lands `.capturing`) even though the route is long
    /// gone, because this closure captures only `bundleID`, never re-checks
    /// `routedBundleIDs`/`localBundleIDs`, and `PerAppCaptureCoordinator.start`
    /// happily builds a brand-new slot from `.idle`. The guard against that
    /// resurrected/orphaned capture lives at the OTHER end instead, where the
    /// outcome is actually known: the `.capturing` case in
    /// `handlePerAppCaptureHealthChange` checks route/local membership before
    /// accepting a capture, and stops (rather than accepts) an orphaned one. This
    /// timer is deliberately left unguarded on the route table.
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

    /// React to the WHOLE-SYSTEM tap's state transition (T16, E10). Before this,
    /// `captureCoordinator.onStateChange` was never wired at all — a `.failed`
    /// tap (TCC lost mid-session, the aggregate device torn out from under it, a
    /// bad ASBD read) stayed dead forever unless the user happened to toggle a
    /// Selected Device afterward (the only other path that re-invokes
    /// `reconcileCaptureGate`, and only because toggling changes `want`). Runs
    /// off `stateQueue` (callback context from
    /// `NativeCaptureCoordinator.onStateChange`, wired in `start()`); hops on
    /// only for the mutation, mirroring `handlePerAppCaptureHealthChange`.
    ///
    /// `.capturing` cancels any pending retry and resets the attempt counter —
    /// recovered. `.failed` schedules an indefinite capped-exponential-backoff
    /// retry (mirrors T8's `.processNotYetAudible` retry exactly) ONLY when BOTH:
    ///   - the error is retryable (`NativeCaptureError.isRetryable` — excludes
    ///     `.osUnsupported`, which no retry can ever fix), and
    ///   - capture is still actually desired (`captureRunning`, the gate's own
    ///     "should the tap be running" intent).
    /// The second guard has no per-app equivalent to reach for: a per-app
    /// capture's stray `.capturing` for a route nobody wants any more is caught
    /// CHEAPLY at that landing site (stopped as an orphan). But there is only
    /// ONE whole-system tap, and it is `.mutedWhenTapped` — blindly restarting
    /// it while `captureRunning` is false (nothing selected, or the user just
    /// deselected everything) would silence the Mac's speakers with the audio
    /// going nowhere, exactly the bug `reconcileCaptureGate`'s own doc comment
    /// describes. So the desired-ness check has to happen before EVER calling
    /// `start()` again, not after.
    private func handleCaptureCoordinatorStateChange(_ state: NativeCaptureCoordinator.State) {
        switch state {
        case .capturing:
            stateQueue.sync {
                self.pendingCaptureRetry?.cancel()
                self.pendingCaptureRetry = nil
                self.captureRetryCount = 0
                if self.captureFailureNoteActive {
                    self.captureFailureNoteActive = false
                    self.emit(.captureFailed(message: nil, retrying: false))
                }
            }

        case .failed(let error):
            let (shouldRetry, attempt): (Bool, Int) = stateQueue.sync {
                let running = self.captureRunning
                let retryable = error.isRetryable
                if running {
                    // The tap is dead while audio is still wanted: every selected
                    // speaker has gone silent behind a row that still reads
                    // "Connected", and no per-device state can say so. A failure
                    // while capture isn't desired is noise — nobody is listening.
                    self.captureFailureNoteActive = true
                    self.emit(.captureFailed(message: error.userMessage, retrying: retryable))
                }
                guard running, retryable else {
                    // Bookkeeping-hygiene fix (mirrors `handlePerAppCaptureHealthChange`):
                    // no retry is being scheduled from here — either capture
                    // isn't desired any more or this is a non-retryable failure
                    // — so a `pendingCaptureRetry` left over from an earlier
                    // attempt is now stale and must not linger as a dangling
                    // `DispatchWorkItem` reference.
                    self.pendingCaptureRetry?.cancel()
                    self.pendingCaptureRetry = nil
                    return (false, 0)
                }
                let attempt = self.captureRetryCount + 1
                self.captureRetryCount = attempt
                return (true, attempt)
            }
            if shouldRetry {
                scheduleCaptureRetry(attempt: attempt)
            }

        case .idle, .creatingTap, .stopping:
            break
        }
    }

    /// Schedule the next whole-system-tap retry with capped-exponential backoff
    /// (T16, E10) — mirrors `scheduleProcessNotYetAudibleRetry`'s exact shape
    /// (`retryDelay × 2^(attempt-1)`, capped at `captureRetryMaxBackoff`, e.g.
    /// 2 → 4 → 8 → 10 → 10 … forever) and its single-flighting (replaces any
    /// retry already pending so N `.failed` events in a row never stack N
    /// timers, and a `stop()`/deselect can cancel it via `pendingCaptureRetry`).
    ///
    /// UNLIKE that retry — which is deliberately left unguarded on the route
    /// table because a resurrected/orphaned per-app capture is caught cheaply
    /// at its OWN `.capturing` landing site — this one RE-CHECKS
    /// `captureRunning` at FIRE time, right before calling `coordinator.start()`.
    /// There is only one whole-system tap, and it is `.mutedWhenTapped`: if
    /// capture was deselected during the backoff wait, blindly starting it here
    /// would mute the Mac's speakers with nowhere for the captured audio to go
    /// — the exact bug `reconcileCaptureGate` exists to prevent, and worse than
    /// an orphaned per-app tap (which only affects one app's exclusion
    /// bookkeeping, not the user's actual listening experience).
    /// `reconcileCaptureGate`'s own `coordinator.stop()` branch already cancels
    /// this timer proactively on a deselect, so this re-check is a defensive
    /// backstop against the (intentionally tolerated, D4-style) race where the
    /// timer is already past that check when the cancel lands.
    private func scheduleCaptureRetry(attempt: Int) {
        let delay = min(
            captureRetryDelay * pow(2.0, Double(attempt - 1)),
            captureRetryMaxBackoff)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let stillWanted: Bool = self.stateQueue.sync { self.captureRunning }
            guard stillWanted, let coordinator = self.captureCoordinator else { return }
            self.captureControlQueue.async { coordinator.start() }
        }
        stateQueue.sync {
            self.pendingCaptureRetry?.cancel()
            self.pendingCaptureRetry = work
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + delay, execute: work)
    }

    /// Forward an app-quit notification from the AppKit boundary (T8, edge case 1:
    /// a routed app's process quits mid-stream; Bug 2: a `.currentDevice`-routed
    /// app's process quits mid-stream). `AppDelegate` observes
    /// `NSWorkspace.didTerminateApplicationNotification` and calls this with the
    /// terminated app's bundle ID — Core can't observe AppKit notifications itself,
    /// mirroring the `processResolver` injection.
    ///
    /// A no-op unless `bundleID` currently has an active `.device(id:)` route OR is
    /// routed `.currentDevice` (Bug 2 fix — was `.device`-only, which meant a
    /// "play on this Mac" app's per-app Core Audio tap was NEVER stopped on quit:
    /// `AppRoutingController.resetDeviceRoute` deliberately never touches
    /// `.currentDevice` — see its doc comment — so no route-table change ever
    /// re-drove `updateAppRoutes` for it either, leaving the tap registered against
    /// a dead pid in coreaudiod forever). Either way the PERSISTED route survives
    /// the quit (the silent-fallback-to-`.noRedirect` behavior is reserved for a
    /// lost DEVICE, not a quit app — the user may relaunch the app and expect its
    /// route/pick to still apply). The per-app capture is stopped, it's marked dead
    /// so the mixer topology drops it immediately (a no-op for a `.currentDevice`
    /// bundle — it was never in the mixer topology to begin with), and any pending
    /// `.processNotYetAudible` retry is cancelled (retrying a tap for a pid that no
    /// longer exists is pointless).
    public func handleAppTerminated(bundleID: String) {
        let wasCaptured: Bool = stateQueue.sync {
            self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
            self.retryCounts.removeValue(forKey: bundleID)
            return self.routedBundleIDs.contains(bundleID) || self.localBundleIDs.contains(bundleID)
        }
        guard wasCaptured else { return }
        perAppCapture.stop(bundleID: bundleID)
        let justDied: Bool = stateQueue.sync {
            // Bookkeeping-hygiene fix: the capture just stopped for real (a
            // quit, not a tap rebuild) — forget the "ever captured" bit so a
            // later relaunch's fresh `.capturing` (`handleAppLaunched`) is
            // recognised as a first capture, not a stale recapture. (In
            // practice `resetAirPlaySessionForRoutedApp` is ALSO a guaranteed
            // no-op for this exact call path today — `handleAppLaunched` calls
            // `perAppCapture.start` synchronously-to-completion BEFORE its own
            // `republishMixerTopology()` runs, so `routeMixer.streamID(for:)`
            // is still nil when `.capturing` lands — but this keeps the
            // invariant this field documents true regardless of that other
            // function's current implementation, and keeps it in sync with
            // `deadBundleIDs`/`retryCounts`/`pendingRetries`, all cleared at
            // this same capture-stop point.)
            self.everCapturedBundleIDs.remove(bundleID)
            return self.deadBundleIDs.insert(bundleID).inserted
        }
        if justDied { republishMixerTopology() }
        // Notify the UI that this routed app is no longer running so it can
        // show an offline indicator on the row (T4). The route itself persists
        // (PLAN §C) — only the live streaming state changes.
        stateQueue.async { self.emit(.routedAppRunning(bundleID: bundleID, isRunning: false)) }
    }

    /// React to an app-launch notification forwarded from the AppKit boundary
    /// (T4, bug fix: relaunching a routed app did not restart its capture; Bug 2:
    /// same fix extended to a relaunched `.currentDevice`-routed app). `AppDelegate`
    /// observes `NSWorkspace.didLaunchApplicationNotification` and calls this; Core
    /// can't observe AppKit notifications itself, mirroring the
    /// `handleAppTerminated` / `processResolver` injection pattern.
    ///
    /// Only acts when `bundleID` currently has an active `.device(id:)` route OR is
    /// routed `.currentDevice` (Bug 2 fix — was `.device`-only, so a "play on this
    /// Mac" app's capture never restarted after `handleAppTerminated` stopped it) —
    /// a non-routed, non-local app launch is silently ignored. On a match it:
    ///  - Clears any dead/retry tracking left over from a prior quit
    ///  - Restarts the per-app Core Audio capture tap (the previous one was
    ///    torn down by `handleAppTerminated` when the process exited)
    ///  - Republishes the mixer topology so `.routedApps` and the engine stream
    ///    binding reflect the restarted app (a no-op for a `.currentDevice`
    ///    bundle — see `resetAirPlaySessionForRoutedApp`'s doc comment; the
    ///    relaunched local player itself comes back through
    ///    `handleLocalCaptureStateChange`'s `.capturing` case once the capture
    ///    below reaches it, not through this republish)
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

        // `localBundleIDs` is ours (synced-local): an app routed to the Mac itself
        // still has a capture slot to revive on relaunch, so it takes this path too.
        let hasRoute: Bool = stateQueue.sync {
            guard self.routedBundleIDs.contains(bundleID) || self.localBundleIDs.contains(bundleID) else { return false }
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

    /// How many mixed buffers between write-backlog samples. At ~44.1 kHz with
    /// typical buffer sizes this is a handful of seconds — frequent enough to
    /// catch a backlog trend, rare enough that neither the snapshot read (which
    /// takes the guard's own lock) nor a Telemetry write ever lands at buffer
    /// cadence on this RT-adjacent queue.
    private static let backlogSampleInterval = 500

    /// Sample the engine's write-backpressure guard every `backlogSampleInterval`
    /// buffers and emit a Telemetry line ONLY when the cumulative dropped-write
    /// count actually moves. Counters are confined to the mixer's callback queue
    /// (this is the sole caller, and `onMixedBuffer` is serialized on that queue),
    /// so no additional lock is needed.
    ///
    /// `dropped > 0` is the definitive signal that audio is being discarded by
    /// backpressure rather than interrupted by a rebuild/reset — the distinction
    /// the routing telemetry cannot make. `maxInFlightSeconds` climbing toward the
    /// cap across samples means the engine thread is draining slower than capture
    /// produces (clock drift / a stalled receiver), which is the underlying
    /// condition the drop is merely the symptom of.
    private func sampleWriteBacklogIfDue() {
        backlogSampleCounter &+= 1
        guard backlogSampleCounter % Self.backlogSampleInterval == 0 else { return }
        let snap = engine.writeBacklogSnapshot()
        guard snap.droppedWrites != lastReportedDroppedWrites else { return }
        let delta = snap.droppedWrites &- lastReportedDroppedWrites
        lastReportedDroppedWrites = snap.droppedWrites
        Telemetry.log(.airplay, "write_backlog_drop", [
            "droppedTotal": String(snap.droppedWrites),
            "droppedDelta": String(delta),
            "maxInFlightSeconds": String(format: "%.3f", snap.maxInFlightSeconds),
            "streamsTracked": String(snap.streamsTracked),
        ])
    }

    /// Sample the engine's write-CADENCE deficit/overrun counters
    /// (T-ENG-CADENCE-1, whole-system-dropout investigation) on the identical
    /// throttled/delta-gated shape as `sampleWriteBacklogIfDue()` above (own
    /// counter, own last-reported baseline, same `backlogSampleInterval` —
    /// reused rather than duplicated as a second constant, since the
    /// instruction behind this sampler is explicitly to reuse that cadence,
    /// not invent a new one). Emits a NEW event, `write_cadence_drift`, only
    /// when the cumulative deficit OR overrun has grown since the last sample
    /// — `writeCadenceSnapshot()` was previously referenced nowhere in
    /// `AudioutCore`, so this is the first time it is ever read outside the
    /// engine's own package.
    ///
    /// `writeCadenceSnapshot()` is engine-wide (fed by every `write` call —
    /// whole-system stream 0 AND per-app streams alike, see
    /// `AirPlayEngine.write(streams:pts:)`), but this sampler's own TRIGGER is
    /// the per-app mixer's buffer arrivals (`onMixedBuffer`, the only
    /// per-buffer-adjacent hook available inside `NativeBackend.swift` — the
    /// whole-system tap writes straight to `EngineSink` in
    /// `NativeCaptureCoordinator.swift`). So a session with no active
    /// `.device` route never fires THIS sampler — the same shape of blind
    /// spot `write_backlog_drop` had for the whole-system path before
    /// `9965bd9` closed it there. `EngineSink.write` (that file) now mirrors
    /// this exact sampler for stream 0, tagged `path: "perApp"` here vs.
    /// `path: "wholeSystem"` there so the two call sites of the same event
    /// stay distinguishable — the discriminator `write_backlog_drop` itself
    /// never got, added here for both so they're symmetrical and greppable.
    private func sampleWriteCadenceIfDue() {
        cadenceSampleCounter &+= 1
        guard cadenceSampleCounter % Self.backlogSampleInterval == 0 else { return }
        let snap = engine.writeCadenceSnapshot()
        guard snap.deficitSeconds != lastReportedCadenceDeficitSeconds
            || snap.overrunSeconds != lastReportedCadenceOverrunSeconds else { return }
        let deficitDelta = snap.deficitSeconds - lastReportedCadenceDeficitSeconds
        let overrunDelta = snap.overrunSeconds - lastReportedCadenceOverrunSeconds
        lastReportedCadenceDeficitSeconds = snap.deficitSeconds
        lastReportedCadenceOverrunSeconds = snap.overrunSeconds
        Telemetry.log(.airplay, "write_cadence_drift", [
            "path": "perApp",
            "writeCount": String(snap.writeCount),
            // THE drift number — deficit and overrun are one-sided sums that
            // both inflate under ordinary jitter; only their difference is real.
            "netDriftTotalSeconds": String(format: "%.3f", snap.netDriftSeconds),
            "netDriftDeltaSeconds": String(format: "%.3f", deficitDelta - overrunDelta),
            "deficitTotalSeconds": String(format: "%.3f", snap.deficitSeconds),
            "deficitDeltaSeconds": String(format: "%.3f", deficitDelta),
            "overrunTotalSeconds": String(format: "%.3f", snap.overrunSeconds),
            "overrunDeltaSeconds": String(format: "%.3f", overrunDelta),
            "lastGapSeconds": String(format: "%.4f", snap.lastGapSeconds),
            // Pauses, sleeps and tap rebuilds — kept out of the drift totals.
            "stalledTotalSeconds": String(format: "%.3f", snap.stalledSeconds),
            "stallCount": String(snap.stallCount),
            // How much of the deficit is the ENGINE's own drop site (writes the
            // backpressure guard refused) rather than a slow producer.
            "refusedWrites": String(snap.refusedWrites),
            "refusedTotalSeconds": String(format: "%.3f", snap.refusedSeconds),
        ])
    }

    private func handleDestinationSetsChanged(_ sets: [AppRouteMixer.DestinationSet]) {
        stateQueue.sync {
            // Remember the topology so a LATER device discovery can re-drive this
            // binding pass for a target that wasn't discovered yet (see
            // `addOrUpdate`'s per-app re-drive).
            self.lastDestinationSets = sets
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
                    if old != stream {
                        ops.append(.rebind(outputID, stream))
                        // Bookkeeping-hygiene fix: this topology-driven rebind
                        // supersedes any pending (explicit-reset) rebind-recovery
                        // retry for the SAME device, exactly like the `.unbind`
                        // loop below already does for a device leaving routing
                        // entirely — otherwise a stale backed-off recovery attempt
                        // can fire later against a device that has already moved
                        // on to a different stream.
                        self.rebindRecoveryGen.removeValue(forKey: deviceID)
                        self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
                    }
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
            // The per-app domain just took (or gave back) stream ids, which is
            // exactly what the EQ budget is computed from (decision 16) — a
            // shrunk budget bypasses the deterministic loser, a grown one
            // re-admits it.
            self.reconcileEQPlan()
            // T3: a device that just lost its per-app stream gets a final combined
            // `.level` (now with a zero stream contribution, so its meter drops to
            // its system contribution — 0 if unselected) so a torn-down stream can't
            // leave a stuck bar. Unconditional (not metering-gated): this is a
            // one-shot CLEAR, exactly what prevents a stale value surviving into a
            // reopened popover.
            for deviceID in unboundDevices { self.emitCombinedLevel(forDevice: deviceID) }
            // D4 (adversarial review): this is the sole `streamBindings` writer, and
            // the handoff watcher's `shouldRun` condition reads `streamBindings` —
            // without this, a per-app-only user (no whole-system selection) never
            // arms the watcher, and the watcher never stops when the last route
            // drops (`reconcileAggregateDefault`'s tail call is unreached with an
            // empty `expectedSelected`).
            self.reconcileHandoffWatcherLocked()
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
    /// op is NOT silently retried here — the binding is idempotently re-established on
    /// the next topology change — but a bind/rebind failure is no longer swallowed
    /// blind: `handleBindFailure` walks the `.routedApps` claim back to empty so the
    /// UI stops asserting a stream that never actually established (dot-truthfulness
    /// fix; deliberately does NOT touch `Device.connectionState` — out of scope here).
    /// The engine's `addOutput(_:streamId:)` binds the device's session to the given
    /// master stream (T2).
    private func performBindOp(_ op: StreamBindOp) async {
        switch op {
        case .bind(let outputID, let stream):
            // The same T5+T4 takeover gate `convergeDevice` runs — a per-app
            // stream is a real AirPlay session and is just as silent without a
            // clock (the ROOT of the redirect-order bug: redirect-first binds
            // used to skip this entirely). `clearBinding` on failure is what
            // lets the clock-recovery replay / discovery re-drive re-issue
            // this op without a topology change.
            guard await ensurePTPTakeover(telemetryDeviceID: deviceID(for: outputID) ?? "\(outputID)") else {
                handleBindFailure(
                    outputID: outputID, stream: stream, op: "bind",
                    error: PTPClockUnavailableError(), clearBinding: true)
                return
            }
            // Roadmap 008 fire-time gate — AFTER the PTP wait (the widest window
            // in the file; a gate before it would re-open the whole window it
            // exists to close), immediately before the engine call.
            guard perAppOpMayFire(outputID: outputID, op: "bind", stream: stream) else { return }
            Telemetry.log(.airplay, "engine_bind", ["output": "\(outputID)", "stream": "\(stream)"])
            do {
                try await bindOutput(outputID, toStream: stream)
            } catch {
                handleBindFailure(outputID: outputID, stream: stream, op: "bind", error: error)
            }
        case .rebind(let outputID, let stream):
            guard await ensurePTPTakeover(telemetryDeviceID: deviceID(for: outputID) ?? "\(outputID)") else {
                handleBindFailure(
                    outputID: outputID, stream: stream, op: "rebind",
                    error: PTPClockUnavailableError(), clearBinding: true)
                return
            }
            guard perAppOpMayFire(outputID: outputID, op: "rebind", stream: stream) else { return }
            Telemetry.log(.airplay, "engine_rebind", ["output": "\(outputID)", "stream": "\(stream)"])
            do {
                try await bindOutput(outputID, toStream: stream, tearDownWhenBindingUnknown: true)
            } catch {
                handleBindFailure(outputID: outputID, stream: stream, op: "rebind", error: error)
            }
        case .unbind(let outputID):
            // Roadmap 008 four-case unbind arm (mechanism 2). A blanket
            // removeOutput under a whole-system claim is the I4 bug (it kills the
            // stream-0 session the user just asked for, while `added` still
            // claims it); a blanket SKIP has two provable failure modes of its
            // own (a stranded astray session after the engine's silent
            // `.alreadyBound` no-op, and a zombie per-app session leaked when the
            // converge parked). Classification runs under `stateQueue`:
            //   1. no operational claim            → removeOutput (today's op);
            //   2. `desiredOn`-only claim (parked) → removeOutput (today's op —
            //      correct teardown of the per-app session; whole-system re-adds
            //      fresh via retry/re-toggle);
            //   3. a converge op is in flight      → defer (`pendingScopeSettles`;
            //      the release side re-drives this exact op);
            //   4. settled stream-0 session owned  → claim the `converging` slot
            //      Finding-1 style and enqueue a VERIFY-FIRST whole-system
            //      recovery: read engine truth after the racing op completed,
            //      rebind astray (≥ 1) → 0, zero engine ops when already 0.
            enum UnbindAction { case remove, deferred, settled }
            let action: UnbindAction = stateQueue.sync {
                guard let id = self.outputIDs.first(where: { $0.value == outputID })?.key else {
                    return .remove   // vanished device: proceed as today (engine tolerates)
                }
                if self.converging.contains(id) {
                    Telemetry.log(.airplay, "unbind_deferred", ["device": id])
                    self.pendingScopeSettles.insert(id)
                    return .deferred
                }
                if self.added.contains(id) {
                    // Case 4 — this IS `resetAirPlaySessionForWholeSystem`'s own
                    // claim shape, reused: slot + gen bump + the shared recovery
                    // chain (its backoff / terminal-exit / slot-release
                    // discipline applies unchanged), with the verify-first
                    // flavor instead of a teardown.
                    self.converging.insert(id)
                    self.rebindConverging.insert(id)
                    let gen = (self.rebindRecoveryGen[id] ?? 0) + 1
                    self.rebindRecoveryGen[id] = gen
                    self.pendingRebindRecoveries.removeValue(forKey: id)?.cancel()
                    Telemetry.log(.airplay, "unbind_downgraded", ["device": id, "settled": "pending"])
                    self.emit(.streamHealth(id: id, recovering: true))
                    self.enqueueRebindRecovery(
                        deviceID: id, outputID: outputID, scope: .wholeSystem,
                        gen: gen, attempt: 1, verifyFirst: true)
                    return .settled
                }
                return .remove   // cases 1 and 2 — byte-identical to today
            }
            guard case .remove = action else { return }
            Telemetry.log(.airplay, "engine_unbind", ["output": "\(outputID)"])
            try? await engine.removeOutput(outputID)
        }
    }

    /// Roadmap 008 fire-time gate for `.bind`/`.rebind`: re-check the whole-system
    /// claim under `stateQueue` immediately before the engine call and BOW OUT
    /// loudly if whole-system operationally owns the device — under a claim,
    /// per-app ops only ever bow out (never move a session), which is what makes
    /// the trailing `.unbind`/settle the deterministic last word. Clearing
    /// `streamBindings` is what lets the re-drives re-issue the op later (the
    /// `handleBindFailure(clearBinding: true)` precedent: both replay paths key on
    /// `streamBindings[id] == nil`). A vanished device (no reverse entry) proceeds
    /// as today. Deliberately NO topology-supersession check here, so the
    /// per-app-only op trace stays byte-identical (within-FIFO ordering already
    /// handles supersession).
    private func perAppOpMayFire(outputID: OutputID, op: String, stream: UInt32) -> Bool {
        stateQueue.sync {
            guard let id = self.outputIDs.first(where: { $0.value == outputID })?.key else { return true }
            guard self.isWholeSystemOperationallyClaimedLocked(id) else { return true }
            let reason = self.converging.contains(id) ? "ws_in_flight" : "ws_claimed"
            Telemetry.log(.airplay, "bind_superseded", [
                "device": id, "op": op, "stream": "\(stream)", "reason": reason,
            ])
            self.streamBindings.removeValue(forKey: id)
            return false
        }
    }

    /// The `Device.id` currently mapped to `outputID`, if any (reverse lookup
    /// of `outputIDs`). Takes `stateQueue` itself — call only off it.
    private func deviceID(for outputID: OutputID) -> String? {
        stateQueue.sync { self.outputIDs.first(where: { $0.value == outputID })?.key }
    }

    /// A per-app bind was refused because no PTP clock is available (the T4
    /// gate said not-ready). Distinct from an engine throw only so telemetry
    /// reads the actual cause.
    private struct PTPClockUnavailableError: Error, CustomStringConvertible {
        var description: String { "timingUnavailable" }
    }

    /// THE single call site that puts a device's engine session onto a stream —
    /// shared by the whole-system converge (`convergeDevice`, stream 0, serialized
    /// by `converging`) and the per-app binding pass (`performBindOp`, stream ≥ 1,
    /// serialized by `bindTail`). T7 / architecture review defect B.
    ///
    /// Those two Swift-side FIFOs are separate and neither knows the other exists,
    /// so a device changing SCOPE — whole-system → per-app, or per-app →
    /// whole-system — crosses the seam between them. The old failure was silent:
    /// `addOutput` no-ops on an already-live session rather than moving it, so the
    /// device kept streaming its old stream while Swift bookkeeping recorded the
    /// new one and audio was written where the device had never joined. `added`
    /// and `streamBindings` never cross-invalidate, so nothing noticed.
    ///
    /// The fix arbitrates on the ENGINE's own answer instead of on either FIFO's
    /// bookkeeping: ask which stream the live session is really on, and if that is
    /// not the stream we want, move it with `rebindOutput` — one op that holds the
    /// engine's per-`OutputID` `opsInFlight` slot across both the stop and the
    /// re-add. That makes the transition atomic from the engine's perspective with
    /// NO new Swift-level lock (a second lock spanning `converging` and `bindTail`
    /// would be a deadlock surface for no extra safety; the engine's per-output
    /// slot is already the one place both paths necessarily meet).
    ///
    /// A live session already on `streamId` needs no engine call at all — that is
    /// the redundant-op window closed rather than merely narrowed.
    ///
    /// `tearDownWhenBindingUnknown` covers the one case the query can't answer: a
    /// `.rebind` against an engine that reports no live binding (or a conformer
    /// that predates the query). Then we keep the historical unconditional
    /// stop-then-re-add, whose tolerated `removeOutput` throw is fine because the
    /// device may simply not be added.
    ///
    /// The accepted ~1 s audible gap on a real move is deliberately kept — there
    /// is no crossfade/pre-buffer machinery here, by decision.
    private func bindOutput(
        _ outputID: OutputID, toStream streamId: UInt32, tearDownWhenBindingUnknown: Bool = false
    ) async throws {
        if let live = await engine.boundStreamId(for: outputID) {
            guard live != streamId else { return }   // engine already owns the stream we want
            Telemetry.log(.airplay, "engine_scope_rebind", [
                "output": "\(outputID)", "from": "\(live)", "to": "\(streamId)",
            ])
            try await engine.rebindOutput(outputID, toStreamId: streamId)
            return
        }
        if tearDownWhenBindingUnknown { try? await engine.removeOutput(outputID) }
        // Stream 0 keeps using the legacy single-stream entry point: it is the exact
        // op `convergeDevice` has always issued, and the per-app seam is reserved for
        // stream ≥ 1 (see `EngineControlling.write(pcm:streamId:pts:)`).
        if streamId == 0 {
            try await engine.addOutput(outputID)
        } else {
            try await engine.addOutput(outputID, streamId: streamId)
        }
    }

    /// A per-app bind/rebind that never actually established an AirPlay session must
    /// not leave the device claiming it streams one — `handleDestinationSetsChanged`
    /// already emitted `.routedApps` with the intended app names purely from mixer
    /// TOPOLOGY, ahead of (and independent of) whether the engine op below it would
    /// succeed. Mirrors exactly the "device just lost its stream" clear that function
    /// emits (`.routedApps(deviceID:, appNames: [])`, then drops the device from
    /// `routedAppNames` so a later successful topology change is free to re-publish it
    /// from scratch) — so a genuinely failed session falls back to the same
    /// truthful, intent-only rendering instead of the teal dot + sublabel lying about
    /// audio that never flowed. Runs on `stateQueue` to serialize against the same
    /// `.routedApps` bookkeeping `handleDestinationSetsChanged` mutates.
    /// `clearBinding` additionally drops the device's recorded `streamBindings`
    /// slot — used ONLY for the PTP-gate refusal, where no engine op ran at
    /// all: clearing it makes the device eligible for the clock-recovery
    /// replay and `addOrUpdate`'s discovery re-drive (both key on
    /// `streamBindings[id] == nil`). An engine-op failure keeps the slot
    /// (default `false`), preserving the existing "next topology change
    /// re-binds idempotently" best-effort semantics.
    private func handleBindFailure(
        outputID: OutputID, stream: UInt32, op: String, error: Error, clearBinding: Bool = false
    ) {
        stateQueue.sync {
            guard let deviceID = self.outputIDs.first(where: { $0.value == outputID })?.key else { return }
            Telemetry.log(.airplay, "bind_failed", [
                "device": deviceID, "op": op, "stream": "\(stream)", "error": "\(error)",
            ])
            if clearBinding { self.streamBindings.removeValue(forKey: deviceID) }
            guard self.routedAppNames[deviceID] != nil else { return }
            self.routedAppNames.removeValue(forKey: deviceID)
            self.emit(.routedApps(deviceID: deviceID, appNames: []))
        }
    }

    // MARK: Connect-time PTP takeover gate (T4+T5, PLAN-AIRPLAY-COEXISTENCE.md)

    /// The one takeover sequence EVERY session-establishing engine op runs
    /// behind — whole-system (`convergeDevice`) and per-app (`performBindOp`,
    /// `performRebindRecovery`) alike. In order:
    ///
    ///  1. T5 switch-away: if the Mac's OWN default output is an AirPlay
    ///     receiver, macOS is holding UDP 319/320 and will neither share them
    ///     nor signal a yield (both measured — the plan's "Known asymmetry").
    ///     It DOES release them ~1-3 s after the default output is switched
    ///     away (G1), so the switch IS the takeover and must precede T4's
    ///     wait — that wait is what races macOS's teardown while the helper
    ///     retries the bind. The routing click is the consent (locked
    ///     decision 2): no dialog. Inert unless the composition root opted in.
    ///  2. T6 strip: `willWaitForClock` is peeked BEFORE `activate` so
    ///     "taking over" only ever shows when a bounded wait genuinely
    ///     starts — never for the (most common) unapproved-helper case, which
    ///     resolves `activate` instantly with no suspension in between.
    ///  3. T4 activation: wake the on-demand helper and wait, bounded, for
    ///     its clock — never at `engine.start()` (Q1=B: woken only by an
    ///     actual routing action, never at launch).
    ///
    /// Returns whether the clock is ready; the caller decides what its own
    /// failure means (whole-system: park + `.timingUnavailable`; per-app:
    /// walk the binding back so a later recovery re-binds).
    ///
    /// This gate originally ran inline in `convergeDevice` ONLY, which made a
    /// per-app redirect ORDER-DEPENDENT: a redirect applied before any
    /// Selected Devices connect (redirect-first, or right after launch) bound
    /// its stream to a clockless receiver — session accepted, audio silent —
    /// while select-then-redirect happened to work because the select had
    /// already woken the helper. Funneling every `addOutput` through here is
    /// what makes the redirect setup order irrelevant. Cheap once the clock
    /// is up: `activate` short-circuits on its first probe.
    ///
    /// On the not-ready → ready EDGE it also replays the cached per-app
    /// topology (``replayPendingPerAppBindings(trigger:)``), so a redirect
    /// that was refused clockless re-binds by itself the moment a later
    /// connect wins the ports — no user re-pick.
    private func ensurePTPTakeover(telemetryDeviceID: String) async -> Bool {
        if let defaultOutputSwitcher {
            let takeover = defaultOutputSwitcher.switchAwayFromAirPlay()
            if takeover != .notAirPlay {
                Telemetry.log(.airplay, "takeover_switch_away", [
                    "device": telemetryDeviceID, "outcome": "\(takeover)",
                ])
            }
        }
        // Banner-flash fix (2026-08-06): the `.takingOver` strip is DEBOUNCED —
        // armed only after `takeoverStripDelay` of genuine waiting, cancelled if
        // the wait resolves first. Pre-fix the strip mounted synchronously on
        // every attempt that waited at all, so each manual retry-that-fails
        // flashed the blue strip (mount + unmount, two panel re-fits) over the
        // steady-state orange fallback banner. A wait that outlives the delay
        // still mounts it, and the `.timedOut` backstop is unaffected.
        var takingOverArm: DispatchWorkItem?
        if ptpHelperActivator.willWaitForClock {
            if takeoverStripDelay <= 0 {
                stateQueue.sync { self.setTakeoverStatus(.takingOver) }
            } else {
                let arm = DispatchWorkItem { [weak self] in self?.setTakeoverStatus(.takingOver) }
                takingOverArm = arm
                stateQueue.asyncAfter(deadline: .now() + takeoverStripDelay, execute: arm)
            }
        }
        let outcome = await ptpHelperActivator.activate(timeout: Self.ptpActivationTimeout)
        let ready = (outcome == .ready)
        let becameAvailable: Bool = stateQueue.sync {
            // Cancel inside the critical section: the arm runs on `stateQueue`
            // too, so past this point it either already fired (a genuinely long
            // wait — the resolved status below supersedes it) or never will.
            takingOverArm?.cancel()
            let was = self.ptpClockAvailable
            self.ptpClockAvailable = ready
            self.setTakeoverStatus(TakeoverStatus.resolved(from: outcome))
            return ready && !was
        }
        if becameAvailable { replayPendingPerAppBindings(trigger: "clock_recovery") }
        return ready
    }

    /// Re-run the cached per-app binding pass for devices the table wants but
    /// whose binding slot is cleared. Two triggers share it (roadmap 008
    /// generalized the clock-recovery-only original): `"clock_recovery"` — the
    /// not-ready → ready PTP edge (a bind refused clockless had its slot cleared
    /// via `handleBindFailure(clearBinding: true)`) — and `"ws_release"` — the
    /// whole-system domain fully released a device whose bind bowed out at fire
    /// time (`perAppOpMayFire` cleared the slot). The guard is the same either
    /// way (`outputIDs != nil && streamBindings == nil`), so the topology diff
    /// re-issues exactly the missing `.bind` ops; devices already bound are
    /// untouched (same stream ⇒ no op) and an ordinary pass never churns the
    /// mixer path. Mirrors `addOrUpdate`'s discovery-time re-drive of the same
    /// pass. Call OFF `stateQueue` only.
    private func replayPendingPerAppBindings(trigger: String) {
        let sets: [AppRouteMixer.DestinationSet] = stateQueue.sync {
            guard self.lastDestinationSets.contains(where: { set in
                set.deviceIDs.contains { self.outputIDs[$0] != nil && self.streamBindings[$0] == nil }
            }) else { return [] }
            return self.lastDestinationSets
        }
        guard !sets.isEmpty else { return }
        if trigger == "clock_recovery" {
            // The pre-008 event name, kept as-is for its existing trigger.
            Telemetry.log(.airplay, "app_route_rebind_on_clock_recovery", [:])
        } else {
            Telemetry.log(.airplay, "per_app_redrive", ["trigger": trigger])
        }
        handleDestinationSetsChanged(sets)
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
    /// and stops the loop; the park is cleared only on a genuine edge (storm fix,
    /// 2026-08-06): a came-back discovery edge (changed descriptor, or reappearing
    /// after a `disappeared`), an engine good-state transition, a membership edge
    /// for this id, or the user's "Try again" (`retryOutput`) — never by a mere
    /// same-descriptor re-announce.
    /// Release the `converging` slot for `id` and, if the coalesced target moved
    /// while the slot was held (a toggle — or a whole-system rebind recovery,
    /// below — landed mid-op), reclaim the slot and return the output id to kick
    /// a fresh `convergeDevice` loop for. Shared by `convergeDevice`'s own defer
    /// AND `enqueueRebindRecovery`'s whole-system completion (Finding 1): both
    /// hold `converging` as the single serialization domain for a device's
    /// engine ops, so both release through the same requeue check. Must run on
    /// `stateQueue`.
    /// Terminal exit for a WHOLE-SYSTEM rebind recovery: forget that the recovery
    /// held `id`'s `converging` slot, then release it through the shared requeue
    /// check. Every terminal exit of the chain goes through here so
    /// `rebindConverging` can never outlive the hold it records — including the
    /// backed-off retry that finds the world moved on before it fired, which used
    /// to `return` without releasing anything and stranded the device: with the
    /// slot leaked, `handleSystemDidWake`'s `!converging.contains(id)` kick and
    /// every later `setOutputSet` skipped it forever, so a selected speaker stayed
    /// silent with no self-recovery until the app was restarted.
    private func releaseRebindConverging(id: String) -> ConvergeReleaseAction {
        self.rebindConverging.remove(id)
        return self.releaseConvergingAndRequeueIfNeeded(id: id)
    }

    /// What a whole-system slot release asks its (off-lock) caller to do next
    /// (roadmap 008 widened the old bare `OutputID?` requeue): re-kick a converge
    /// for the moved target, and/or replay the cached per-app topology now that
    /// the whole-system domain fully released the device. Losers never WAIT on
    /// the other FIFO — they bow out and are re-driven here, by the releasing
    /// side.
    private struct ConvergeReleaseAction {
        /// Re-kick `convergeDevice` (the pre-008 requeue, unchanged).
        var requeue: OutputID?
        /// Call `replayPendingPerAppBindings(trigger: "ws_release")` OFF the
        /// lock: the per-app table still wants this device and its binding was
        /// cleared by a fire-time bow-out.
        var redrivePerApp = false
        static let none = ConvergeReleaseAction(requeue: nil)
    }

    private func releaseConvergingAndRequeueIfNeeded(id: String) -> ConvergeReleaseAction {
        self.converging.remove(id)
        // Never requeue into a suspension. `convergeDevice` has no `suspended` guard
        // of its own, so a slot released mid-sleep would otherwise kick a loop that
        // issues addOutput at engine sessions sleep has already torn down. The slot
        // stays FREE instead, which is exactly what `handleSystemDidWake` needs: it
        // re-kicks every still-desired device that isn't already `converging`.
        // Roadmap 008: the re-drive/settle arms below are ALSO behind this guard —
        // a sleep-window release must re-drive NOTHING (the sessions are dead; the
        // wake re-kick + discovery re-drive are the recovery, and the suspension
        // handler clears `pendingScopeSettles`).
        guard !self.suspended else { return .none }
        if !self.failedGate.contains(id),
           let want = self.desiredOn[id],
           let out = self.outputIDs[id],
           want != self.added.contains(id) {
            self.converging.insert(id)
            // Requeued: a deferred scope settle stays pending and defers to THAT
            // converge's own release — no waiting, bounded by claim transitions.
            return ConvergeReleaseAction(requeue: out)
        }
        // Release WITHOUT requeue (roadmap 008 mechanism 3) — the whole-system
        // domain is fully done with this device for now.
        //
        // 1. Consume a deferred scope settle by RE-ENQUEUING the deferred
        //    `.unbind`: its four-case fire-time classification settles it against
        //    the post-converge world (settled session → verify-first settle;
        //    parked converge → today's teardown of the leaked per-app session; a
        //    NEW claim in the meantime → defers again). One mechanism, no
        //    duplicated settle logic, and every case lands on the arm the design
        //    assigns it. `enqueueBindOps` is on-`stateQueue`-safe (it only
        //    appends Tasks).
        if self.pendingScopeSettles.contains(id) {
            self.pendingScopeSettles.remove(id)
            if let out = self.outputIDs[id] {
                if self.streamBindings[id] == nil {
                    Telemetry.log(.airplay, "unbind_redrive", ["device": id, "trigger": "ws_release"])
                    self.enqueueBindOps([.unbind(out)])
                } else {
                    // Adversarial-review fix (008): the route RE-ENGAGED while the
                    // settle was deferred (deselect → restore replay re-decided a
                    // binding), so the deferred unbind is STALE — re-enqueued, it
                    // would fire FIFO-behind the restored `.bind` with no claim
                    // left (case 1) and removeOutput-kill the user's freshly
                    // re-engaged session; with `streamBindings` set, every replay
                    // guard (`streamBindings == nil`) then skips the device
                    // forever — silent stranding. Any session the settle existed
                    // to tear down is already handled: this release's own converge
                    // tore the engine session down on the way to `added == false`,
                    // and a still-live astray session is moved by the restored
                    // `bindOutput` itself (it reads engine truth). Drop it loudly.
                    // The `streamBindings` read and the restore diff's write are
                    // both under `stateQueue`, so this decision is atomic against
                    // the replay: diff-before-release → drop (the queued bind is
                    // the last word); release-before-diff → the re-enqueued unbind
                    // runs FIFO-ahead of the diff's bind, a tolerated no-op remove.
                    Telemetry.log(.airplay, "unbind_redrive", [
                        "device": id, "trigger": "ws_release",
                        "outcome": "dropped_route_reengaged",
                    ])
                }
            }
        }
        // 1b. Consume a deferred EQ move the same way: the connect edge that owed
        //     it happened INSIDE the converge that just released, so this is the
        //     first moment the device's engine ops are ours to issue.
        //     `reconcileEQPlan` re-derives the target from scratch, so a stale
        //     note can only ever produce a no-op.
        if self.eqRebindDeferred.remove(id) != nil {
            self.reconcileEQPlan()
        }
        // 2. Per-app re-drive: the per-app table still wants this device, its
        //    binding was cleared (a fire-time bow-out), and whole-system no
        //    longer desires it — tell the caller to replay the cached topology
        //    off the lock.
        var action = ConvergeReleaseAction.none
        if self.desiredOn[id] != true,
           self.streamBindings[id] == nil,
           self.lastDestinationSets.contains(where: { $0.deviceIDs.contains(id) }) {
            action.redrivePerApp = true
        }
        return action
    }

    private func convergeDevice(id: String, outputID: OutputID) async {
        defer {
            // Release the in-flight slot. If the target moved again while we were
            // settling (e.g. a flip arrived after our last op but the slot was still
            // held), re-kick so we chase it — the release + re-check is atomic under
            // stateQueue so a concurrent setOutputSet can't slip a kick past us.
            // Roadmap 008: a release without requeue may also re-drive the per-app
            // side (bow-outs whose re-issue this release unblocks) — off the lock.
            let action: ConvergeReleaseAction = stateQueue.sync {
                self.releaseConvergingAndRequeueIfNeeded(id: id)
            }
            if action.redrivePerApp { self.replayPendingPerAppBindings(trigger: "ws_release") }
            if let requeue = action.requeue {
                Task { [weak self] in await self?.convergeDevice(id: id, outputID: requeue) }
            }
        }

        while true {
            // Snapshot the current op to issue from the coalesced target.
            let step: (want: Bool, descriptor: DeviceDescriptor?)? = stateQueue.sync {
                // D6 (adversarial review): a converge already in flight when a
                // sleep/handoff release fires must not complete and silently
                // re-insert into `added` — re-holding the ports (or streaming into
                // dead sockets) mid-suspend with nobody the wiser. The requeue path
                // above already re-kicks once `suspended` lifts (wake or resume), so
                // bailing here costs nothing real work would have survived anyway.
                guard !self.suspended else { return nil }
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

                    // T5+T4 takeover gate (PLAN-AIRPLAY-COEXISTENCE.md), shared
                    // with the per-app bind paths — see ``ensurePTPTakeover``.
                    // A PTP-only receiver (Sonos/HomePod) accepts the session
                    // but plays silence with no clock, so failing the connect
                    // now beats a "connected" row that never makes a sound.
                    guard await ensurePTPTakeover(telemetryDeviceID: id) else {
                        stateQueue.sync {
                            self.removeFromAddedLocked(id)
                            self.failedGate.insert(id)
                            self.applyLocal(id) { $0.isSelected = false; $0.isAvailable = false }
                            self.enterFailure(id, cause: .timingUnavailable)
                        }
                        return
                    }

                    // Connect-latency diagnosis: brackets the real RTSP/negotiate
                    // handshake `addOutput` awaits (device_start through the STREAMING
                    // completion) — the gap between these two events is the AirPlay
                    // receiver's own negotiation time, not anything this app controls.
                    Telemetry.log(.airplay, "connect_addoutput_start", ["device": id, "output": "\(outputID)"])
                    // T7: go through the shared scope-transition call site, not a
                    // bare `addOutput`. If this device is currently carrying a
                    // per-app redirect (a live session on stream ≥ 1, bound by the
                    // `bindTail` FIFO this loop knows nothing about), a plain
                    // `addOutput` would silently no-op and leave the whole-system
                    // mix written to a stream the device never joined — selected,
                    // shown as connected, inaudible. `bindOutput` asks the engine
                    // which stream the session is really on and MOVES it to 0.
                    try await bindOutput(outputID, toStream: 0)
                    Telemetry.log(.airplay, "connect_addoutput_resolved", ["device": id, "output": "\(outputID)"])
                    stateQueue.sync {
                        // Re-verify D6 (post-success half): a converge whose
                        // `addOutput` was in flight when a handoff release (or sleep)
                        // suspended us must NOT land in `added` — it would re-hold the
                        // PTP ports mid-handoff with the capture tap gated off (a live,
                        // silent session macOS still can't bind past). Hand the fresh
                        // session to the teardown chain instead of dropping it
                        // untracked, and bail before any state write.
                        guard !self.suspended else {
                            let engine = self.engine
                            self.handoffTeardown = Task { [prev = self.handoffTeardown] in
                                await prev?.value
                                try? await engine.removeOutput(outputID)
                            }
                            return
                        }
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
                        // true` and skips — so exactly one push per connect. Whether
                        // that push is the connect default or the level the device was
                        // already streaming at is `connectVolumeSeed`'s call, off
                        // `userConnectSeed` (F-REBIND). See `connectVolumeSeed`.
                        let wasAdded = self.added.contains(id)
                        self.added.insert(id)
                        let seededVolume = wasAdded ? nil : self.connectVolumeSeed(id, outputID: outputID)
                        // Same edge, same reason as the volume seed: a fresh
                        // session always lands on stream 0, so a device with a
                        // stored EQ has to be moved onto its group's stream again
                        // (decision 16).
                        if !wasAdded { self.reconcileEQPlan() }
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
                    // new sessions post-failure (root cause 5). The park clears only
                    // on a genuine edge (storm fix, 2026-08-06): a came-back
                    // discovery edge, an engine good-state transition, a membership
                    // edge, or `retryOutput`.
                    //
                    // Cause mapping mirrors `applyEngineState`'s `.passwordRequired`
                    // arm: an auth rejection is the one connect failure with a
                    // known, actionable cause — never flatten it to `.unknown`.
                    // `opTimedOut` is the second: the armed op's completion never
                    // arrived inside the bounded window, which is exactly what
                    // `.timedOut` tells the user. Anything else stays `.unknown` —
                    // a plausible-but-wrong cause is worse than a vague one — but
                    // the raw error always rides along as `detail`.
                    var cause: ConnectionFailure.Cause = .unknown
                    if case AirPlayEngineError.passwordRequired = error { cause = .authRequired }
                    if case AirPlayEngineError.opTimedOut = error { cause = .timedOut }
                    stateQueue.sync {
                        self.removeFromAddedLocked(id)
                        self.failedGate.insert(id)
                        self.applyLocal(id) { $0.isSelected = false; $0.isAvailable = false }
                        self.enterFailure(id, cause: cause, detail: String(describing: error))
                    }
                    return
                }
            } else {
                do {
                    try await engine.removeOutput(outputID)
                    stateQueue.sync {
                        self.removeFromAddedLocked(id)
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
                        self.removeFromAddedLocked(id)
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
    private func surfaceLocalDevice(name: String, muted: Bool?) {
        let id = Self.localDeviceID
        guard known[id] == nil else { return }
        let device = Device(
            id: id,
            name: name,
            kind: .localMac,
            isAvailable: true,
            supportsAirPlay2: false,       // mirrors MockBackend's local fixture
            // UNITY, deliberately NOT the HAL volume read. This row now means "the
            // Mac's own fader" — a trim under Main Out, which is what owns the Mac's
            // hardware level. 100 is the only sensible default: it makes
            // `Main × 100% == Main`, so a user who never trims the Mac hears exactly
            // what Main says. (Main itself adopts the hardware level at launch; see
            // `systemOutputVolume`.)
            volume: 100,
            // Mute still comes from the HARDWARE — the local row's mute IS real
            // hardware mute. The read happens in `start()` BEFORE the `stateQueue`
            // hop (B3), off the queue so a blocking HAL read can't stall the
            // main-thread `devices` getter, and is passed in here; `nil` means the
            // output has no readable mute control (many aggregate/digital devices).
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

        // Guard against self-referential labeling: if the default output is our
        // public aggregate, return the wrapped built-in speaker's name instead.
        // Read the UID inline (the same one-shot HAL read this function already
        // uses for the name) rather than via `CoreAudioSystemTap.readDeviceUID`,
        // which is gated `@available(macOS 14.2, *)` and would raise this
        // function's floor above the package's macOS 14 deployment target.
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString? = nil
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let uidErr = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, ptr)
        }
        if uidErr == noErr, (uid as String?) == AggregateOutputDevice.productUID {
            if let builtInID = SystemLocalOutputResolver().builtInOutputDevice() {
                var builtInNameAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioObjectPropertyName,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                var builtInName: CFString? = nil
                var builtInNameSize = UInt32(MemoryLayout<CFString?>.size)
                let builtInNameErr = withUnsafeMutablePointer(to: &builtInName) { ptr -> OSStatus in
                    AudioObjectGetPropertyData(AudioObjectID(builtInID), &builtInNameAddr, 0, nil, &builtInNameSize, ptr)
                }
                if builtInNameErr == noErr, let cf = builtInName {
                    let str = cf as String
                    return str.isEmpty ? fallback : str
                }
            }
            return fallback
        }

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

    /// The UID of the macOS SYSTEM default output device
    /// (`kAudioHardwarePropertyDefaultOutputDevice`), or `nil` if unreadable — the
    /// production default for ``currentDefaultOutputUIDProvider``, feeding the
    /// public aggregate's off-switch classification (Wave 3 T5). Same two-step HAL
    /// read shape as ``currentDefaultOutputIsAirPlayClass()`` (resolve the default
    /// device, then read one property on it), reused rather than re-derived.
    static func currentDefaultOutputUID() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil, &size, &deviceID) == noErr,
            deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString? = nil
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let uidErr = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, ptr)
        }
        guard uidErr == noErr, let uid else { return nil }
        return uid as String
    }

    // MARK: LatencyConfigurable (PLAN-LATENCY-SETTING.md)

    /// The sender start buffer currently in force (ms). Seeded by
    /// `makeBackend` from the resolved launch value (env → setting → default);
    /// updated by ``applyStartBuffer(ms:)``. Confined to `stateQueue`.
    private var _startBufferMs: Int = 1000

    public var startBufferMs: Int {
        stateQueue.sync { _startBufferMs }
    }

    /// `R` — the room delay (ms): the longest intrinsic delay any active
    /// output has, which every other output then delays itself to (sync
    /// architecture brief §3). One number for the whole room, so the outputs
    /// agree with each other by construction rather than by each deriving its
    /// own reference.
    ///
    /// With no Cast device it is the Wave-4 rule unchanged: a presentation
    /// timeline in the selection (or no BT at all) → the live start-buffer;
    /// BT+Mac without one → the BT-only buffer, the same reference every BT
    /// sink uses, otherwise the Mac would lead each BT speaker by
    /// `startBufferMs − btOnlyBufferMs`. A Cast receiver authors a
    /// presentation timeline exactly as AirPlay does, which is why the branch
    /// asks `usesPresentationReference` rather than about AirPlay alone.
    func roomDelayLocked() -> Int {   // on stateQueue
        let today = (btSinkEnabled && !btComposition.usesPresentationReference)
            ? btReferenceBufferMs : _startBufferMs
        return _castTermMs.map { Swift.max(today, $0) } ?? today
    }

    /// The reference delay (ms) the Mac-local sink renders on (Wave-4 delay
    /// agreement) — the room delay itself: the Mac has no intrinsic delay of
    /// its own to subtract beyond the output latency the sink measures.
    func localSinkReferenceDelayMs() -> Int {
        stateQueue.sync { roomDelayLocked() }
    }

    /// The reference delay (ms) every Bluetooth sink renders on — the AirPlay
    /// start buffer, raised to the Cast term when a Cast receiver is the
    /// furthest-behind output in the room (sync architecture brief §3).
    func btReferenceDelayMs() -> Int {
        stateQueue.sync {
            _castTermMs.map { Swift.max(_startBufferMs, $0) } ?? _startBufferMs
        }
    }

    /// CAST-SYNC: how far behind live the furthest Cast receiver in the mix is
    /// playing (ms), or `nil` when no Cast device is contributing a term — the
    /// `max` reduction's absent operand, and the reason every delay above
    /// reduces to today's number by construction rather than by a flag.
    private var _castTermMs: Int? { castRoomDelay.termMs }

    /// The room-delay policy (brief §4): the settle gate, the high-water mark
    /// and the `R_max` refusal, kept pure so it can be replayed offline
    /// against recorded lead samples. Confined to `stateQueue`; the only
    /// writers are ``updateCastRoomDelayLocked()`` (the receiver set moved)
    /// and ``applyCastLeadSample(_:_:)`` (a receiver measured itself).
    private var castRoomDelay = CastRoomDelay()

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
    @discardableResult
    public func applyStartBuffer(ms: Int) async -> (reconnected: Int, expected: Int) {
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

        // CAST-SYNC (brief §3): the AirPlay share of the room delay is
        // `R − startBufferMs`, so moving the start buffer moves the line in
        // front of the engine by the same amount in the opposite direction.
        // Done HERE, between the teardown and the re-adds, because that is the
        // one moment in this method when nothing is streaming. Guarded on the
        // Cast term for the invariant's sake: with no Cast device there is no
        // line, and this must not be what creates one.
        stateQueue.sync {
            guard _castTermMs != nil else { return }
            roomDelayChangedLocked(cause: "start_buffer")
        }

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
        // Count what actually came back while we're on the queue: the D4 re-add is
        // best-effort, so the caller can only claim "reconnected" for the devices
        // still in `added`.
        let reconnected = stateQueue.sync { () -> Int in
            for item in streaming { self.bufferReAdding.remove(item.id) }
            return streaming.filter { self.added.contains($0.id) }.count
        }
        return (reconnected: reconnected, expected: streaming.count)
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

    /// Test-only (`@testable`): whether the app currently holds the Mac's default
    /// output with its aggregate, and the pre-takeover output it remembers — the
    /// two pieces of state the deselect-to-Mac-only restore turns over.
    var test_aggregateDefaultActive: Bool { stateQueue.sync { aggregateDefaultActive } }
    var test_priorDefaultUID: String? { stateQueue.sync { priorDefaultUID } }

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

    /// Test-only (`@testable`): the active scope-conflict record for `deviceID`
    /// (roadmap 008), or `nil` when no conflict is engaged — a `.device` route
    /// whose target is a Selected Device is demoted for the duration and recorded
    /// here (removed again on deselect/route edit). Diagnostic only; never read by
    /// any decision path.
    func test_scopeConflict(deviceID: String) -> ScopeConflict? {
        stateQueue.sync { lastScopeConflicts[deviceID] }
    }

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
            return self.suspendSessionsKeepingIntentLocked()
        }
        for (_, outputID) in toRemove {
            Task { [weak self] in try? await self?.engine.removeOutput(outputID) }
        }
    }

    /// Tear every streaming engine output down cleanly while PRESERVING the
    /// selection intent (`expectedSelected` / `desiredOn`) — shared critical section
    /// between the sleep path (`handleSystemWillSleep`, which sets `suspended` itself
    /// first) and the AirPlay-handoff release path (`releaseForHandoff`, which sets
    /// `handoffReleased` instead/as well). Extracted from the former (Seamless
    /// handoff T3.2) with no behavior change for the sleep path — callers keep their
    /// own guard + flag flip and just forward the returned removal list. On
    /// `stateQueue`.
    private func suspendSessionsKeepingIntentLocked() -> [(id: String, outputID: OutputID)] {   // on stateQueue
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
        // Abandon any in-flight AirPlay-session rebind recovery, exactly as
        // `stop()` does: the engine sessions are about to die, so completing a
        // rebind — or waking one out of a backoff delay — on the far side of the
        // sleep is meaningless. Clearing the generation supersedes a chain
        // currently awaiting its engine op (it bows out on its own gen check) and
        // cancelling the timers drops the backed-off attempts.
        //
        // Because a cancelled timer never runs, the whole-system `converging` slot
        // those chains were holding has to be released HERE. Leaving it held is
        // what stranded a selected speaker silent after wake with no
        // self-recovery: `handleSystemDidWake` only re-kicks devices that are not
        // already `converging`, so the device was never re-added. Release only the
        // slots `rebindConverging` records — a slot a live `convergeDevice` loop
        // owns is not ours to drop. No requeue here; the wake path issues the
        // re-add for every still-desired device.
        self.rebindRecoveryGen.removeAll()
        for work in self.pendingRebindRecoveries.values { work.cancel() }
        self.pendingRebindRecoveries.removeAll()
        for deviceID in self.rebindConverging {
            self.converging.remove(deviceID)
            self.emit(.streamHealth(id: deviceID, recovering: false))
        }
        self.rebindConverging.removeAll()
        // Roadmap 008 — SLEEP ONLY. Sleep ends every session and the machine is
        // going down, so a deferred unbind must not survive to re-classify against
        // post-wake state.
        //
        // The handoff release deliberately does NOT clear these: unlike sleep it
        // tears down only `added` + `streamBindings`, while its own gate admits a
        // release with devices merely `converging` — so a `.unbind` deferred for a
        // still-converging device is real work that must survive. `suspended`
        // makes the note unconsumable only FOR THE DURATION of the release (that
        // is what deferring means); `resumeFromHandoffLocked` clears `suspended`
        // and re-kicks, and the next `releaseConvergingAndRequeueIfNeeded` for
        // that id re-drives the unbind (telemetry `unbind_redrive`). Clearing here
        // would silently drop it and leak the per-app session.
        if !self.handoffReleased { self.pendingScopeSettles.removeAll() }
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
        // Same discipline as `stop()`: the EQ topology describes engine sessions
        // that just died, so it must die with them. Keeping it would make the
        // wake path's `added` false→true reconcile a NO-OP — the fresh session
        // lands on stream 0, the reconcile recomputes the same stream S, and
        // `current != stream` is false, so no rebind is ever issued and the
        // speaker plays flat forever (a same-value commit can't recover it
        // either) while the coordinator keeps filtering into a stream with no
        // output bound. Clearing it means the reconcile sees `previous[id] ==
        // nil`, reads engine truth (stream 0), and issues the move. The VALUES
        // (`eqByDeviceID`/`storedMainOutEQ`) are the user's settings and stay, as does
        // the allocator (a released id is retired for the session, decision 8).
        self.eqStreamIDByDevice.removeAll()
        self.eqRebindDeferred.removeAll()
        self.eqSlotByStream.removeAll()
        self.mainOutEQSlot = nil
        if let coordinator = self.captureCoordinator {
            self.captureControlQueue.async { coordinator.setEQPlan(.passthrough) }
        }
        return items
    }

    // MARK: Seamless AirPlay handoff (T3) — release-on-deselect + resume

    /// The user's system-output action means macOS wants the timing ports. Tear the
    /// AirPlay sessions down (KEEPING selection intent) and free 319/320 fast, so
    /// their next attempt in Sound settings succeeds. On `stateQueue`.
    /// - Parameter defaultAlreadyLeftUs: whether the system default output has
    ///   ALREADY moved off our aggregate at the moment of this release. True for a
    ///   user deselect (that departure is what triggered it); false for a blocked
    ///   attempt (macOS aborts before switching, so we are still the default).
    ///   Arms `defaultLeftUsSinceRelease` — passed explicitly rather than derived
    ///   from `reason`, which exists only for telemetry and must not carry logic.
    private func releaseForHandoff(reason: String, defaultAlreadyLeftUs: Bool) {   // on stateQueue
        guard self.started, !self.handoffReleased, !self.suspended else { return }
        // The gate below is "do we plausibly hold the ports at all" — a release
        // with nothing streaming/converging would tear down zero sessions and just
        // leave the watcher spinning for no reason; the watcher itself must never
        // fire while this is false.
        //
        // D5 (adversarial review): `converging` is included because
        // `ptpHelperActivator.activate` binds the ports (`convergeDevice`) BEFORE a
        // device lands in `added` — during that connecting window `added` and
        // `streamBindings` are both still empty, so without this a blocked attempt
        // mid-connect would slip through unreleased. Chosen over `ptpClockAvailable`
        // (the last activation's outcome, optimistically `true` before any attempt
        // and not reset on release) because `converging` directly tracks "an engine
        // op that might currently be holding the ports is in flight," which is
        // exactly the condition this gate needs.
        guard !self.added.isEmpty || !self.streamBindings.isEmpty || !self.converging.isEmpty else { return }

        self.handoffReleased = true
        self.defaultLeftUsSinceRelease = defaultAlreadyLeftUs
        self.suspended = true
        let toRemove = self.suspendSessionsKeepingIntentLocked()
        // D3 (adversarial review — corrects the T3.9 answer): a per-app-ONLY target
        // never lands in `added`. `setOutputSet` writes `desiredOn[id] = wantOn` for
        // every id in `order`, including one that's merely discovered, not selected
        // (~1773); `applyEngineState`'s `.streaming`/`.connected` branch then sees
        // `desiredOn[id] == false` for it and takes the "desired OFF" branch instead
        // of inserting into `added` (~4846-4858). So `suspendSessionsKeepingIntentLocked`'s
        // `added`-only removal leaves every per-app session — and its PTP hold —
        // alive, and Option B's `.bind` resume would then no-op against a session
        // the engine still considers live. Tear those down too, but leave
        // `streamBindings` ITSELF intact — Option B's resume rebinds from it.
        let perAppOutputIDs = self.streamBindings.keys.compactMap { self.outputIDs[$0] }
        let allOutputIDs = toRemove.map(\.outputID) + perAppOutputIDs

        self.reconcileHandoffWatcherLocked()

        Telemetry.log(.airplay, "handoff_release", [
            "reason": reason,
            "devices": Self.telemetryDeviceList(Set(toRemove.map(\.id)), known: self.known),
        ])

        // D2 (adversarial review): ONE task for the whole removal, stored so a
        // resume's `convergeDevice` kick can await it first — otherwise a stale
        // `removeOutput` here is unordered against the engine actor relative to the
        // resumed `addOutput` and could land after it, killing the fresh session.
        let engine = self.engine
        self.handoffTeardown = Task {
            for outputID in allOutputIDs { try? await engine.removeOutput(outputID) }
        }
        // D8 (adversarial review): fire-and-forget, but off `stateQueue` — this is a
        // real Mach IPC syscall, and `stateQueue` sits on the main thread's blocking
        // path (the `devices` getter `sync`s on it).
        let releaser = self.ptpHelperReleaser
        DispatchQueue.global().async { releaser.release() }
    }

    /// A blocked macOS AirPlay attempt was observed in the unified log — treat it as
    /// the user's switch-away intent. Called from the watcher's pipe I/O thread.
    private func handleBlockedAirPlayAttempt() {
        stateQueue.async {
            // The watcher firing without a release that follows is otherwise
            // invisible — `releaseForHandoff`'s guards return silently. Logging the
            // inputs makes the REJECTING guard readable straight from telemetry
            // instead of inferred; it earned its keep on 2026-08-07, where
            // `added:0, bindings:0, converging:0` is what proved a blocked attempt
            // had arrived with nothing left to release (roadmap 026, the
            // same-device case). Cheap: fires only on a real blocked attempt.
            Telemetry.log(.airplay, "handoff_blocked_attempt_state", [
                "started": String(self.started),
                "handoffReleased": String(self.handoffReleased),
                "suspended": String(self.suspended),
                "added": String(self.added.count),
                "bindings": String(self.streamBindings.count),
                "converging": String(self.converging.count),
            ])
            self.releaseForHandoff(reason: "blockedAttempt", defaultAlreadyLeftUs: false)
        }
    }

    /// Start/stop the blocked-attempt watcher to match whether we currently have
    /// anything worth protecting. `streamBindings` is deliberately part of the
    /// condition — per-app routes participate in the handoff too. On `stateQueue`.
    private func reconcileHandoffWatcherLocked() {   // on stateQueue
        let shouldRun = self.started && !self.handoffReleased
            && (!self.expectedSelected.isEmpty || !self.streamBindings.isEmpty)
        if shouldRun, self.handoffWatcher == nil {
            let watcher = self.handoffWatcherFactory { [weak self] in
                self?.handleBlockedAirPlayAttempt()
            }
            self.handoffWatcher = watcher
            // D8 (adversarial review): `start()` posix_spawns /usr/bin/log
            // synchronously — publish the instance on `stateQueue` first (so a
            // concurrent reconcile sees it and doesn't double-start), then kick the
            // actual spawn off queue so it can't block the main thread (which
            // `sync`s on `stateQueue` via the `devices` getter).
            // Re-verify D8: identity re-check on the owning queue before the
            // off-queue spawn. Without it, a `stop()`/reconcile-flap landing
            // between the publish above and this block running would be
            // overwritten by `start()` (`running = true`), leaking an orphan
            // `log stream` child nothing references. If the published watcher
            // is no longer current by the time we get here, do nothing.
            DispatchQueue.global().async { [weak self] in
                guard let self,
                      self.stateQueue.sync(execute: { self.handoffWatcher === watcher })
                else { return }
                watcher.start()
            }
        } else if !shouldRun, let watcher = self.handoffWatcher {
            watcher.stop()
            self.handoffWatcher = nil
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
            // Seamless handoff T3.8-1: a sleep/wake during a deliberate handoff
            // release must not silently re-grab the PTP ports and break the macOS
            // session the user just started — only `resumeFromHandoffLocked()`
            // (the user asking for Audiout back) may clear `handoffReleased`.
            guard !self.handoffReleased else { return [] }
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
        let anyAudible = desiredNonLocal.contains { desiredDeviceAudibleLocked($0) }
        let stranded = !suspended && wantsStream && !anyAudible

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

    /// Whether one DESIRED non-local id is audibly carrying audio, for the
    /// stranded test above. AirPlay: a live engine session (`.connected`). A
    /// `.bluetooth` id holds NO engine session, and its `.connected` means
    /// something else entirely (BT-LIFECYCLE: its own sink started rendering) —
    /// it arrives a whole reference delay late, so the engine-lifecycle read
    /// would brand a healthy BT-only selection stranded and un-mute the Mac
    /// mid-playback (R-partition). A BT id's audible fact is its
    /// Core Audio endpoint existing (`isAvailable`) — exactly what its sink
    /// renders through; a selected-but-disconnected BT speaker therefore still
    /// (correctly) counts as silence and falls back to the Mac. On `stateQueue`.
    ///
    /// A `.cast` id is audible once its receiver has REPORTED PLAYING
    /// (`castPlaying` — `isAvailable` would count a receiver that is merely on
    /// the network), and a session that is still `.connecting` counts as NOT
    /// STRANDED rather than audible. The Cast recipe runs connect → launch →
    /// LOAD → PLAY and takes ~10 s on real hardware — a dead heat with
    /// ``defaultSilenceFallbackDelay`` — so reading a starting session as
    /// stranded armed the countdown at select and then stopped the capture tap
    /// the Cast feed is fed from, starving the receiver into a rebuffer stall it
    /// never recovers from (live run 2026-08-22). A genuinely dead receiver is
    /// still caught: the session's own 15 s play deadline reports `.failed`, the
    /// row leaves `.connecting`, and the countdown arms then (R11 intact).
    private func desiredDeviceAudibleLocked(_ id: String) -> Bool {   // on stateQueue
        guard let device = known[id] else { return false }
        if device.isBluetooth { return device.isAvailable }
        if device.isCast {
            return castPlaying.contains(id) || device.connectionState == .connecting
        }
        return device.connectionState == .connected
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
        let anyAudible = desiredNonLocal.contains { desiredDeviceAudibleLocked($0) }
        guard !suspended, !desiredNonLocal.isEmpty, !anyAudible else { return }
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

    // MARK: Public aggregate default-output ownership + routing-blocked warning (Wave 3, T5)

    /// Reconcile the public aggregate's default-output ownership off the current
    /// selection intent, then (re)evaluate the routing-blocked warning. Called
    /// whenever `expectedSelected` changes (the activation seam, Q1).
    ///
    /// AMBIGUITY FLAGGED (Q1): "actively routing" here is defined as
    /// `!expectedSelected.isEmpty` — i.e. WHOLE-SYSTEM routing (≥1 AirPlay output
    /// selected). That is the only path whose audio depends on the aggregate being
    /// the Mac's default: the whole-system tap follows
    /// `kAudioHardwarePropertyDefaultOutputDevice`, so it captures nothing unless
    /// the default is our aggregate. Per-app `.device` redirects tap the app's
    /// PROCESS directly (independent of the default output), so they deliberately
    /// do NOT arm the aggregate takeover or the warning. On `stateQueue`.
    private func reconcileAggregateDefault() {   // on stateQueue
        if !expectedSelected.isEmpty {
            takeOverDefaultAndReflect()
        } else {
            // Not routing: never take the Mac's default output (Q1) — and hand it
            // back whenever it IS our aggregate, however it got there, or the Mac
            // keeps playing through a device that swallows every volume write. The
            // slider and the hardware volume keys then move nothing the user can hear.
            restoreDefaultFromAggregate()
            // The warning is off by definition.
            evaluateRoutingBlocked()
        }
        // Seamless handoff T3.6: `expectedSelected` just settled — re-decide
        // whether the blocked-attempt watcher should be running.
        reconcileHandoffWatcherLocked()
    }

    /// Take the Mac's default output for the aggregate and reflect the resulting
    /// steady state of the routing-blocked warning. Shared by the activation seam
    /// and the user's ``reselectAggregateAsDefault()``.
    ///
    /// On a SUCCESSFUL set-default write we reflect the intended state
    /// (`blocked = false`) OPTIMISTICALLY rather than reading the default straight
    /// back: the HAL default-device change lands asynchronously, so an immediate
    /// read can still return the PRE-write device and emit a transient `true` that
    /// the echo-guard would then leave stuck. The listener's echo settles the real
    /// change, and any genuine later user override re-evaluates to `true`. When no
    /// write was issued (aggregate already default, or unresolvable) we evaluate
    /// normally. On `stateQueue`.
    private func takeOverDefaultAndReflect() {   // on stateQueue
        if pointDefaultAtAggregate() {
            setRoutingBlocked(false)
        } else {
            evaluateRoutingBlocked()
        }
    }

    /// Point the Mac's default output at the public aggregate, capturing the prior
    /// default ONCE (for the quit-time restore) the first time we take over.
    /// Returns `true` iff it issued a SUCCESSFUL set-default write THIS call (so the
    /// caller can reflect the intended state without racing the async change
    /// notification); `false` when the aggregate is already the default or can't be
    /// resolved. The write is echo-guarded via ``expectedDefaultWriteUID`` (set only
    /// on success, so a refused write can't leave a stale guard). Used by both the
    /// activation seam and the user's re-select — both legitimate (app routing vs.
    /// the user's own click); neither is Q2's forbidden PROGRAMMATIC re-select
    /// ("re-select without the user asking"). On `stateQueue`.
    private func pointDefaultAtAggregate() -> Bool {   // on stateQueue
        guard let aggregateID = aggregateControl.resolveDeviceID(forUID: AggregateOutputDevice.productUID) else { return false }
        let current = currentDefaultOutputUIDProvider()
        if !aggregateDefaultActive {
            // Capture what the user had so `stop()` can restore it. Never remember
            // the aggregate itself as the "prior" (we're about to destroy it).
            if let current, current != AggregateOutputDevice.productUID {
                priorDefaultUID = current
            }
            aggregateDefaultActive = true
        }
        guard current != AggregateOutputDevice.productUID else { return false }   // already ours
        guard aggregateControl.setDefaultOutputDevice(aggregateID) else { return false }
        expectedDefaultWriteUID = AggregateOutputDevice.productUID
        return true
    }

    /// First UID in `uids` (nils dropped, order preserved) that `control` can
    /// resolve to a live device id right now.
    ///
    /// Callable from any queue, but EXPENSIVE — `resolveDeviceID(forUID:)` may
    /// enumerate the HAL, and `builtInOutputDeviceUID()` certainly does — so never
    /// run it on the main queue or a fader-drag thread.
    ///
    /// `static` so a resolver closure built from it holds no reference to the
    /// backend and cannot keep it alive.
    private static func firstResolvableDevice(
        uids: [String?], using control: AggregateDeviceControlling
    ) -> (uid: String, id: AudioObjectID)? {
        uids.compactMap { $0 }.lazy.compactMap { uid in
            control.resolveDeviceID(forUID: uid).map { (uid: uid, id: $0) }
        }.first
    }

    /// Give the Mac's default output back to a real device once whole-system
    /// routing goes empty (the user deselected their last AirPlay speaker), leaving
    /// the aggregate itself ALIVE — unlike `stop()`, which restores and then
    /// destroys it. It has to stay: it is the app's entry in Sound settings, and a
    /// re-select takes it over again.
    ///
    /// The ONLY entry condition is that the default output IS our aggregate.
    /// Deliberately NOT also `aggregateDefaultActive`,
    /// the way `stop()`'s restore is: that flag is process-local while the
    /// aggregate's default-ness is system-wide and survives a relaunch, so a
    /// default this process never wrote — left by a previous session, auto-picked
    /// by macOS when the device appeared, or chosen by the user in Sound settings
    /// — would never be handed back, and Mac-only through the aggregate is pure
    /// passthrough with dead volume control. Best-effort like `stop()`'s: nothing
    /// resolvable to restore to leaves the default exactly where it is.
    ///
    /// `priorDefaultUID` is deliberately KEPT (`stop()` clears it). The HAL's
    /// default-device change lands asynchronously, so a fast re-select can still
    /// read the aggregate as the current default and skip
    /// ``pointDefaultAtAggregate()``'s prior-capture — the standing value is then
    /// the only good prior left. On `stateQueue`.
    private func restoreDefaultFromAggregate(attempt: Int = 1) {   // on stateQueue
        guard currentDefaultOutputUIDProvider() == AggregateOutputDevice.productUID else { return }
        // What the user had, else the Mac's built-in output — the same sub-device
        // the aggregate itself wraps, so it is the one target that is still there
        // when the prior device was unplugged mid-session.
        let prior = priorDefaultUID.flatMap { $0 == AggregateOutputDevice.productUID ? nil : $0 }
        guard let target = Self.firstResolvableDevice(
            uids: [prior, aggregateControl.builtInOutputDeviceUID()], using: aggregateControl) else {
            Telemetry.log(.airplay, "aggregate_default_restore", [
                "outcome": "no_target", "prior": prior ?? "none", "attempt": "\(attempt)"])
            return
        }
        // Written inline on `stateQueue`, the same way `pointDefaultAtAggregate()`
        // writes its own default.
        restoreWriteReturned(aggregateControl.setDefaultOutputDevice(target.id),
                             target: target, attempt: attempt)
    }

    /// VOLUME CONTINUITY: bring the device we just handed the default back to up
    /// to Main, or the Mac jumps to whatever level that hardware was left at.
    ///
    /// The Main mirror (``builtInOutputTargetResolver()``) keeps only the BUILT-IN
    /// output in step during a session, so a prior default that was anything else
    /// — AirPods, a USB DAC, external speakers — has been sitting untouched at its
    /// pre-session level the whole time. Addressed by the device id already
    /// resolved here rather than by "whatever is default", because the HAL's switch
    /// lands asynchronously and a resolve-the-default write would still hit the
    /// aggregate, which takes every volume write and applies none. On `stateQueue`.
    private func pushMainToRestoredDevice(_ target: (uid: String, id: AudioObjectID)) {   // on stateQueue
        let main = mainOutGain
        let id = target.id
        // Memoise only on a confirmed write, as `setMasterGain` does — same
        // readable-but-unwritable-output trap.
        systemVolume.setVolume(main, resolvingTarget: { id }) { [weak self] wrote in
            guard let self, wrote else { return }
            self.stateQueue.async { self.lastSeenSystemVolume = main }
        }
    }

    /// How long to wait before reading back whether the restore write actually
    /// moved the default. Not a sleep and not a guess at HAL latency: a write the
    /// HAL ACCEPTS AND IGNORES raises no change notification at all, so there is no
    /// event to wait on and a scheduled read-back is the only way to tell it apart
    /// from one still in flight (the same reason the takeover reflects
    /// optimistically instead of reading straight back).
    private static let restoreLandingCheckDelay: TimeInterval = 0.5

    /// The restore write came back. `true` only means the HAL accepted it — the
    /// documented failure mode in this area is acceptance without effect (root
    /// AGENTS.md: a destroy of the current system output returns `noErr` and does
    /// nothing), so schedule a read-back rather than believing it. On `stateQueue`.
    private func restoreWriteReturned(_ wrote: Bool, target: (uid: String, id: AudioObjectID),
                                      attempt: Int) {   // on stateQueue
        Telemetry.log(.airplay, "aggregate_default_restore", [
            "outcome": wrote ? "wrote" : "write_refused",
            "target": target.uid, "attempt": "\(attempt)"])
        guard wrote else { return }
        // Echo-guard our own write, exactly as the takeover does. This is the ONE
        // write that targets something other than the aggregate; the
        // default-changed handler only clears the guard, it pushes no volume.
        expectedDefaultWriteUID = target.uid
        aggregateDefaultActive = false
        pushMainToRestoredDevice(target)
        stateQueue.asyncAfter(deadline: .now() + Self.restoreLandingCheckDelay) { [weak self] in
            self?.verifyRestoreLanded(target: target, attempt: attempt)
        }
    }

    /// Read the default back: did the write we were told succeeded actually move
    /// it? On `stateQueue`.
    ///
    /// razor: exactly ONE retry. A write ignored twice is a HAL state this app
    /// cannot argue with, and a loop here would fight the user; the telemetry line
    /// is what a live session is meant to leave behind. Upgrade path if the log
    /// ever shows a second attempt landing: schedule off the capture-stopped edge
    /// instead of a fixed delay.
    private func verifyRestoreLanded(target: (uid: String, id: AudioObjectID), attempt: Int) {   // on stateQueue
        let current = currentDefaultOutputUIDProvider()
        guard current == AggregateOutputDevice.productUID else {
            Telemetry.log(.airplay, "aggregate_default_restore", [
                "outcome": "landed", "default": current ?? "unreadable", "attempt": "\(attempt)"])
            return
        }
        Telemetry.log(.airplay, "aggregate_default_restore", [
            "outcome": "did_not_land", "target": target.uid, "attempt": "\(attempt)"])
        // The aggregate is still the Mac's default, so we still hold it whatever
        // the write reported.
        aggregateDefaultActive = true
        expectedDefaultWriteUID = nil
        // A re-select in the meantime is the user asking for the aggregate back —
        // never fight it.
        guard attempt == 1, expectedSelected.isEmpty else { return }
        restoreDefaultFromAggregate(attempt: 2)
    }

    /// Compute the routing-blocked steady state — actively routing AND the current
    /// default output is not our aggregate — and push it. Reuses the pure
    /// ``AggregateOutputDevice/classifyOffSwitch(newDefaultUID:)`` decision. On
    /// `stateQueue`.
    private func evaluateRoutingBlocked() {   // on stateQueue
        let blocked: Bool
        if !expectedSelected.isEmpty {
            let outcome = publicAggregate.classifyOffSwitch(newDefaultUID: currentDefaultOutputUIDProvider())
            blocked = outcome != .stillOurs
        } else {
            blocked = false
        }
        setRoutingBlocked(blocked)
    }

    /// Edge-triggered emit of the routing-blocked warning: a repeat of the current
    /// state is a no-op, so it can never thrash the event stream. On `stateQueue`.
    private func setRoutingBlocked(_ blocked: Bool) {   // on stateQueue
        guard blocked != routingBlockedEmitted else { return }
        routingBlockedEmitted = blocked
        emit(.routingBlockedNeedsDefault(blocked))
    }

    /// USER-INITIATED re-select of the aggregate as the Mac's default output — the
    /// popover's "Use Audiout" warning button (Q6). The user's own click IS their
    /// intent, so this is the one sanctioned re-select and does NOT violate Q2's
    /// "never programmatically re-select." Flips the warning off through the same
    /// echo-guarded path as activation. Public so `AppDelegate` can wire
    /// `PopoverController.onReselectAudiout` to it.
    ///
    /// Seamless handoff T3.7: this is also the resume button — if a handoff release
    /// is in force, put EVERYTHING back (whole-system AND per-app redirects).
    public func reselectAggregateAsDefault() {
        stateQueue.async {
            self.takeOverDefaultAndReflect()
            let (kicks, teardown) = self.resumeFromHandoffLocked()
            for (id, outputID) in kicks {
                Task { [weak self] in
                    // D2 (adversarial review): await the release's own teardown
                    // before converging — otherwise a stale `removeOutput` is
                    // unordered against the engine actor relative to this resumed
                    // `addOutput` and could land after it, killing the fresh session.
                    await teardown?.value
                    await self?.convergeDevice(id: id, outputID: outputID)
                }
            }
        }
    }

    /// Put every session a handoff release tore down back: mirrors
    /// `handleSystemDidWake()`'s re-converge critical section minus the wake-specific
    /// bits (no `awaitingWakeReconnect` — this isn't a wake), plus Option B: also
    /// re-issues every still-recorded per-app stream binding, since a handoff release
    /// tears per-app sessions down too (D3) but leaves `streamBindings` itself
    /// untouched as the record of user intent. On `stateQueue`.
    ///
    /// Returns the release's own teardown task (D2) alongside the kicks so every
    /// caller can await it before converging — see the doc on `handoffTeardown`.
    private func resumeFromHandoffLocked() -> (kicks: [(String, OutputID)], teardown: Task<Void, Never>?) {   // on stateQueue
        guard self.started, self.handoffReleased else { return ([], nil) }
        self.handoffReleased = false
        self.defaultLeftUsSinceRelease = true
        self.suspended = false
        self.clearSilenceOverride()
        let teardown = self.handoffTeardown
        self.handoffTeardown = nil

        var kicks: [(String, OutputID)] = []
        let desiredIDs = self.order.filter { self.desiredOn[$0] == true }
        for id in desiredIDs {
            guard let outputID = self.outputIDs[id] else { continue }
            self.failedGate.remove(id)
            self.setConnectionState(.connecting, for: id)
            if !self.converging.contains(id) {
                self.converging.insert(id)
                kicks.append((id, outputID))
            }
        }

        // Option B: re-issue every per-app redirect too. `streamBindings` still
        // records the user's per-app intent (a handoff release never clears it,
        // only `stop()` does) — reuse the same `.bind` op / `enqueueBindOps` FIFO
        // `performBindOp` normally issues from topology changes.
        var bindOps: [StreamBindOp] = []
        for (deviceID, stream) in self.streamBindings {
            if let outputID = self.outputIDs[deviceID] {
                bindOps.append(.bind(outputID, stream))
            }
        }
        // Re-verify D2 (per-app half): the release folded these same per-app
        // outputs into `handoffTeardown`, and `enqueueBindOps` chains onto
        // `bindTail` with no knowledge of it — a re-bind landing before the old
        // teardown's `removeOutput` would be killed by it moments later. Splice
        // the teardown into the bind FIFO as a barrier so every re-bind runs
        // strictly after the teardown completes (same ordering the whole-system
        // kicks get by awaiting `teardown` directly).
        if !bindOps.isEmpty, let teardown {
            self.bindTail = Task { [prev = self.bindTail] in
                await prev.value
                await teardown.value
            }
        }
        self.enqueueBindOps(bindOps)

        self.reconcileCaptureGate()
        self.reconcileSilenceWatchdog()
        self.reconcileHandoffWatcherLocked()

        Telemetry.log(.airplay, "handoff_resume", ["kicked": String(kicks.count)])
        return (kicks, teardown)
    }

    // MARK: Takeover status strip (T6, PLAN-AIRPLAY-COEXISTENCE.md)

    /// Update the takeover-status strip, edge-triggered exactly like
    /// ``reconcileSystemAirPlayGuard()``/``clearSystemAirPlayGuard()`` above: a
    /// repeat of the current state (including repeated `nil`) is a no-op, so a
    /// caller can call this unconditionally at every step of the T5+T4 sequence
    /// without storming the event stream. Every path that could otherwise leave
    /// the strip stuck — the wait resolving, `stop()` — routes through here, so
    /// it can never strand showing a stale "taking over" state. On `stateQueue`.
    private func setTakeoverStatus(_ status: TakeoverStatus?) {   // on stateQueue
        guard status != takeoverStatus else { return }
        takeoverStatus = status
        emit(.takeoverStatus(status))
    }

    // MARK: Scheduling snapshot polling (T2)

    /// Arm the scheduling snapshot polling on `stateQueue`. Polls while capture is
    /// active (at least one real AirPlay device is selected and capture has started).
    /// On `stateQueue`.
    private func startSchedulingSnapshotPolling() {   // on stateQueue
        self.schedulingSnapshotPollWork?.cancel()
        self.schedulingSnapshotPollWork = nil
        self.pollSchedulingSnapshot()
    }

    /// Poll the engine's scheduling snapshot every ~5s while capture is active,
    /// logging via telemetry. Reschedules itself on `stateQueue` so it continues
    /// until cancelled or capture stops. On `stateQueue` (scheduled there).
    private func pollSchedulingSnapshot() {   // on stateQueue (scheduled there)
        guard self.started, self.captureRunning else { return }

        // Read the snapshot on this thread (it's lock-free, bounded, cheap).
        let snapshot = self.engine.writeSchedulingSnapshot()

        // Format and log the three metric families (each with count, p50/p95/p99/max).
        // Using snake_case to match existing telemetry key conventions in this file.
        self.schedulingSnapshotLogCount &+= 1
        Telemetry.log(.airplay, "send_sched", [
            "wake_count": "\(snapshot.wakeLatency.count)",
            "wake_p50_ms": String(format: "%.1f", snapshot.wakeLatency.p50Ms),
            "wake_p95_ms": String(format: "%.1f", snapshot.wakeLatency.p95Ms),
            "wake_p99_ms": String(format: "%.1f", snapshot.wakeLatency.p99Ms),
            "wake_max_ms": String(format: "%.1f", snapshot.wakeLatency.maxMs),
            "in_cycle_count": "\(snapshot.inCycleWork.count)",
            "in_cycle_p50_ms": String(format: "%.1f", snapshot.inCycleWork.p50Ms),
            "in_cycle_p95_ms": String(format: "%.1f", snapshot.inCycleWork.p95Ms),
            "in_cycle_p99_ms": String(format: "%.1f", snapshot.inCycleWork.p99Ms),
            "in_cycle_max_ms": String(format: "%.1f", snapshot.inCycleWork.maxMs),
            "gap_count": "\(snapshot.interArrivalGap.count)",
            "gap_p50_ms": String(format: "%.1f", snapshot.interArrivalGap.p50Ms),
            "gap_p95_ms": String(format: "%.1f", snapshot.interArrivalGap.p95Ms),
            "gap_p99_ms": String(format: "%.1f", snapshot.interArrivalGap.p99Ms),
            "gap_max_ms": String(format: "%.1f", snapshot.interArrivalGap.maxMs),
        ])

        // Schedule the next poll (~5s). This reschedules on stateQueue, matching the
        // pattern of the wake watchdog above (stateQueue.asyncAfter with a weak self).
        let work = DispatchWorkItem { [weak self] in self?.pollSchedulingSnapshot() }
        self.schedulingSnapshotPollWork = work
        self.stateQueue.asyncAfter(deadline: .now() + 5.0, execute: work)
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
            guard self.removeFromAddedLocked(id) else { return nil }
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
        // R5: sampled BEFORE anything below can change it, so the tail of this
        // method can tell a real reachability EDGE from a repeated `.updated`.
        let wasRouteTargetEligible = isRouteTargetEligibleLocked(id)
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
            // Availability recovery (root cause 4), EDGE-GATED (storm fix,
            // 2026-08-06): clear a terminal-failure park only when this
            // re-resolve is evidence the device actually CAME BACK — no
            // descriptor was on file (first sighting, or back from sticky-AP2
            // offline, which nils the memo) or the announced descriptor CHANGED
            // (the receiver restarted / moved). Reappearing after a
            // `disappeared` keeps the memo (`removeEngineDiscovery` needs it to
            // reconstruct the deregistration) — that case auto-reconnects
            // because `markDisappeared` itself drops the park with the episode,
            // not through this edge check. A dead-but-still-announcing receiver
            // re-resolving the SAME descriptor is NOT evidence of recovery:
            // the old unconditional clear here (STABILITY(C7), "no backoff")
            // plus the `desiredOn` re-kick below re-armed a failed device on
            // every mDNS re-announce, one driver of the autonomous retry
            // storm. The edge IS the backoff; a same-descriptor receiver
            // recovers via its next engine good-state transition
            // (`applyEngineState` clears the park), a user re-toggle, or
            // "Try again" (`retryOutput`).
            let cameBack = self.lastDescriptors[id].map {
                !Self.descriptorsEqual($0, discovered.descriptor)
            } ?? true
            self.lastDescriptors[id] = discovered.descriptor
            if cameBack { self.failedGate.remove(id) }
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
            // STABILITY(C7) resolved (storm fix, 2026-08-06): a parked id keeps
            // its gate across same-descriptor re-resolves (the edge-gated clear
            // above), so this re-kick fires only for a genuine came-back /
            // never-failed device. Deliberately NO eager `.connecting` here —
            // autonomous recovery must not churn the connection state machine
            // (a fresh `.failed → .connecting → .failed` cycle would resurrect
            // a user-dismissed diagnosis panel); success lands `.connected`
            // via the add path, failure leaves the resting `.failed` alone.
            Task { [weak self] in await self?.convergeDevice(id: id, outputID: outputID) }
        }

        // PER-APP redirect recovery (counterpart to the whole-system re-kick
        // above). A redirect TARGET is deliberately NOT in `desiredOn` — T7 keeps
        // app-route targets out of the whole-system output set — so the recovery
        // above can never cover it. Meanwhile `handleDestinationSetsChanged` binds
        // "only for discovered devices": a route restored at LAUNCH is applied
        // ~tens of ms in, long before Bonjour finds the target, so the device was
        // silently dropped from the binding pass with nothing to re-drive it. The
        // app then captured audio that went nowhere — a redirect that stayed
        // SILENT until the user re-picked the destination by hand.
        //
        // So: once a targeted device becomes streamable and engine-registered, if
        // it still has no per-app stream binding, re-run the binding pass with the
        // cached topology. Idempotent for devices already bound (same stream ⇒ no
        // op); the newly-discovered one now passes the `outputIDs != nil` filter
        // and gets its `.bind`.
        if streamableNow,
           self.outputIDs[id] != nil,
           self.streamBindings[id] == nil,
           self.lastDestinationSets.contains(where: { $0.deviceIDs.contains(id) }) {
            let sets = self.lastDestinationSets
            Telemetry.log(.airplay, "app_route_rebind_on_discovery", ["device": id])
            // MUST hop OFF `stateQueue`: we are already inside it here, and
            // `handleDestinationSetsChanged` takes it with `.sync`.
            DispatchQueue.global().async { [weak self] in
                self?.handleDestinationSetsChanged(sets)
            }
        }

        // R5: per-app redirects are the OTHER thing a reachability edge has to
        // recover. The converge re-kick above only chases `desiredOn` (Selected
        // Devices / Main Out); a redirect target is deliberately never in that set
        // (`AudioutCore/AGENTS.md`), so it needs its own replay — which is also
        // what disengages a route whose target just went offline.
        rerunAppRoutesIfTargeted(id, wasEligible: wasRouteTargetEligible)
    }

    /// Replay the per-app route table iff `id`'s ELIGIBILITY (reachable AND not
    /// whole-system-claimed, roadmap 008) actually FLIPPED and some route points
    /// at it (R5). Both guards matter: discovery re-resolves the same device
    /// repeatedly, and a replay per `.updated` event would churn the per-app taps
    /// and the whole-system tap's exclusion set for nothing. Keying on eligibility
    /// (not bare reachability) also suppresses a pointless replay when a CLAIMED
    /// target's reachability flips — the route stays demoted either way. On
    /// `stateQueue` (the replay itself hops off it).
    private func rerunAppRoutesIfTargeted(_ id: String, wasEligible: Bool) {   // on stateQueue
        let isEligible = isRouteTargetEligibleLocked(id)
        guard isEligible != wasEligible,
              lastRoutes.contains(where: { $0.destination == .device(id: id) })
        else { return }
        AudioDiag.log(
            "app routes: redirect target \(id) became \(isEligible ? "ELIGIBLE" : "INELIGIBLE")"
            + " — re-resolving effective routes (route table unchanged)")
        rerunAppRoutesForReachabilityChange()
    }

    /// Commit a changed `Device` snapshot for `id`, emit it, and replay the per-app
    /// route table if this write flipped whether `id` can carry a redirect (R5).
    /// On `stateQueue`.
    ///
    /// Every site that can change `Device.isAvailable` for a DISCOVERED device must
    /// go through here (or sample + replay by hand, as `addOrUpdate` does across its
    /// two branches). Availability does not only move on discovery events: a live
    /// session dying (`applyEngineState`'s `.failed`/`.passwordRequired`) or a
    /// converge add failing (`applyLocal`) drop it too. Miss one of those and the
    /// effective route table goes stale in the direction that HURTS — the app stays
    /// excluded from the whole-system tap while its per-app stream has nowhere to
    /// go, i.e. silence with no user-visible cause.
    private func commitKnownDevice(_ id: String, _ device: Device) {   // on stateQueue
        let wasEligible = isRouteTargetEligibleLocked(id)
        known[id] = device
        emit(.deviceUpdated(device))
        rerunAppRoutesIfTargeted(id, wasEligible: wasEligible)
    }

    /// A device dropped off the network. It stays in the model as unavailable (so a
    /// saved group keeps its membership); it is removed from the streaming set.
    /// On `stateQueue`.
    private func markDisappeared(_ id: String) {
        // Before the `device` copy below is taken, so the reconcile's own
        // `eqBypassReason` writes can't be clobbered by this method's commit.
        self.removeFromAddedLocked(id)
        // The engine descriptor is deregistered on disappear; a future re-add must
        // re-feed it. Clear the fed memo so `descriptorToFeed` doesn't skip it.
        self.fedDescriptors[id] = nil
        // A full disappear ends any failure episode (the state clears to `.off`
        // below), so drop the park with it — a later re-appearance is then a
        // clean `desiredOn`-driven auto-reconnect in `addOrUpdate` even when the
        // receiver comes back announcing the identical descriptor (the edge-gated
        // clear there would not fire for it; this is the drop-off-and-return arm
        // of the storm fix, 2026-08-06). The descriptor memo stays: it's what
        // `removeEngineDiscovery` reconstructs the deregistration from.
        self.failedGate.remove(id)
        guard var device = known[id] else { return }
        var changed = false
        if device.isAvailable { device.isAvailable = false; changed = true }
        if device.isSelected { device.isSelected = false; changed = true }
        // Brief §1: a sticky `.failed` clears to `.off` only when the device
        // disappears entirely — this is that site (mirrors OwnToneBackend's
        // `.failed → .off` on the poll's removal branch).
        if device.connectionState != .off { device.connectionState = .off; changed = true }
        if changed {
            // R5: a vanished device is unreachable, so any route aimed at it stops
            // being an effective redirect and that app rejoins the system mix. The
            // popover ALSO resets such a route (`handleDeviceDisappeared`), but the
            // backend must never depend on a UI layer for its own audibility.
            commitKnownDevice(id, device)
        }
    }

    // MARK: Bluetooth outputs → deviceAdded/deviceUpdated (BT-ENUM)

    /// When macOS last used each known BT pairing, keyed by `Device.id`
    /// (``BTDeviceSnapshot/lastUsed``). `Device` deliberately doesn't carry this
    /// yet — it's stashed here so the UI wave can filter/sort the ghost rows a
    /// forever-remembered pairing list produces, whatever surface it picks.
    /// Under its own lock rather than `stateQueue` because the popover reads it
    /// on the OPEN path, and `stateQueue` can be busy behind a converge.
    private var btLastUsed: [String: Date] = [:]   // btLastUsedLock

    /// Guards ``btLastUsed`` alone — see that property's note.
    private let btLastUsedLock = NSLock()

    /// The ids the enumerator's LATEST merged list contains — i.e. every BT id
    /// macOS currently knows a pairing (or live endpoint) for. `nil` until the
    /// first snapshot arrives, so "not in the set" is never conflated with
    /// "enumeration hasn't run yet". A known `.bluetooth` row whose id is
    /// absent here has had its pairing record deleted out from under the app
    /// — the `.notPaired` fast-fail in ``retryBTOutput`` keys off this.
    /// On `stateQueue`.
    private var btPairedIDs: Set<String>?

    /// The ``btLastUsed`` stash — the ``BTOutputControlling`` read the popover's
    /// Bluetooth-subsection sort uses (ghost pairings sink to the bottom by
    /// recency; sort-only in v1).
    ///
    /// This is on the popover's OPEN path (`deviceSections()` →
    /// `orderedBluetoothDevices`), so it must never wait on `stateQueue`, which
    /// can be seconds deep behind a converge. Its own lock instead — the same
    /// pattern `btSyncTrim(forDevice:)` and the cached system volume use.
    public func lastUsedDatesForBTDevices() -> [String: Date] {
        btLastUsedLock.withLock { btLastUsed }
    }

    /// Fold a full BT enumeration into the model, through the same
    /// `known`/`order`/`emit` flow AirPlay discovery uses. A BT device that
    /// leaves the merged list entirely (unpaired mid-session) goes unavailable
    /// but keeps its row — same greyed-not-vanished contract as
    /// ``markDisappeared``. On `stateQueue`.
    private func applyBTSnapshots(_ snapshots: [BTDeviceSnapshot]) {
        var seen: Set<String> = []
        var desiredAvailabilityMoved = false
        btPairedIDs = Set(snapshots.map(\.id))
        for snapshot in snapshots {
            let id = snapshot.id
            seen.insert(id)
            btLastUsedLock.withLock { btLastUsed[id] = snapshot.lastUsed }
            if let existing = known[id] {
                var updated = existing
                updated.name = snapshot.name
                updated.isAvailable = snapshot.isConnected
                if updated != existing {
                    let availabilityMoved = updated.isAvailable != existing.isAvailable
                    if availabilityMoved, expectedSelected.contains(id) {
                        desiredAvailabilityMoved = true
                    }
                    commitKnownDevice(id, updated)
                    // BT-RECONNECT: the row's lifecycle follows the baseband
                    // fact. A loss while SELECTED is DESELECTED — off =
                    // unselected, truthfully (Alec's call, replacing the old
                    // power-off park): the popover reacts to this exact
                    // availability edge (`PopoverController.update(devices:)`)
                    // and routes it through `GroupController.setDeviceSelected`,
                    // the one selection owner. A return while STILL selected
                    // therefore IS deliberate intent (the greyed-row "play
                    // when up" select) and resumes below.
                    // Sticky-failed: a `.failed` story from a user-initiated
                    // attempt survives a loss until retry or return.
                    if availabilityMoved {
                        if updated.isAvailable {
                            // BT-LIFECYCLE: the endpoint existing is not yet
                            // audio — a selected row breathes until its sink
                            // renders, exactly like a fresh select.
                            if expectedSelected.contains(id) {
                                beginBTConnectingLocked(id)
                            } else {
                                setConnectionState(.off, for: id)
                            }
                        } else {
                            btConnectingDeadlines[id] = nil
                            if case .failed = existing.connectionState {
                                // keep the failure story
                            } else {
                                setConnectionState(.off, for: id)
                            }
                        }
                    }
                }
            } else {
                let device = Device(
                    id: id,
                    name: snapshot.name,
                    kind: .bluetooth,
                    isAvailable: snapshot.isConnected,
                    supportsAirPlay2: false,
                    // Same as the AirPlay row (`mapDiscovered`): the stored tone
                    // shows from the moment the row appears. A BT device's sink
                    // gets the value re-pushed on every arm, so the snapshot and
                    // what is audible agree.
                    eq: eqByDeviceID[id] ?? .flat)
                known[id] = device
                order.append(id)
                emit(.deviceAdded(device))
            }
        }
        for id in order where known[id]?.kind == .bluetooth && !seen.contains(id) {
            guard var device = known[id], device.isAvailable else { continue }
            device.isAvailable = false
            if expectedSelected.contains(id) { desiredAvailabilityMoved = true }
            commitKnownDevice(id, device)
        }
        // BT-BACKEND: a SELECTED BT id's availability is its audible fact for
        // the silence fallback (`desiredDeviceAudibleLocked` — BT ids never
        // reach `.connected`), and this is the only place that fact changes.
        // AirPlay ids get this re-evaluation from their connection-state
        // transitions; without this call a BT speaker powering off mid-play
        // would never arm the fallback, and one reconnecting would never
        // clear it.
        // The reapply (Wave 4) is the other half: a selected id that just
        // (re)appeared resolves a live device and re-enters the sink set
        // without waiting for a selection change — and a vanished one drops.
        if desiredAvailabilityMoved {
            reconcileSilenceWatchdog()
            reapplyBTSinkLocked()
        }
    }

    // MARK: Cast receivers → deviceAdded/deviceUpdated (CAST-ENUM)

    /// Fold one Cast browse snapshot into `known`/`order` (CAST-ENUM), the same
    /// shape `applyBTSnapshots` uses for the BT merged list. On `stateQueue`.
    ///
    /// An id absent from this list has dropped off the network, not been
    /// deleted: the row is kept (unavailable) and its browse record is kept too,
    /// so a receiver that comes back is addressable without a fresh browse. The
    /// connection state is deliberately NOT touched here — the session's own
    /// channel is the truth about whether it is still playing, and a Bonjour
    /// blip is not evidence either way.
    ///
    /// The unavailable flip is DEBOUNCED behind ``castAbsenceGrace``: a wired
    /// receiver advertises intermittently, and greying the row on the first
    /// browse that omits it made the device read as disabled mid-session. A
    /// browse that lists the id again inside the grace cancels the flip.
    private func applyCastSnapshots(_ records: [CastDeviceRecord]) {   // on stateQueue
        for record in records {
            castRecords[record.id] = record
            castAbsenceFlips[record.id] = nil        // back inside the grace: no flip
            if var device = known[record.id] {
                let returned = !device.isAvailable
                device.name = record.friendlyName
                device.isAvailable = true
                if device != known[record.id] { commitKnownDevice(record.id, device) }
                if returned { logCastRowState(device) }
            } else {
                let device = Device(
                    id: record.id, name: record.friendlyName, kind: .cast,
                    isAvailable: true, supportsAirPlay2: false)
                known[record.id] = device
                order.append(record.id)
                emit(.deviceAdded(device))
                logCastRowState(device)
            }
        }
        let present = Set(records.map(\CastDeviceRecord.id))
        for id in order where known[id]?.kind == .cast && !present.contains(id) {
            guard known[id]?.isAvailable == true, castAbsenceFlips[id] == nil else { continue }
            castAbsenceGeneration += 1
            let generation = castAbsenceGeneration
            castAbsenceFlips[id] = generation
            stateQueue.asyncAfter(deadline: .now() + castAbsenceGrace) { [weak self] in
                self?.expireCastAbsence(id, generation)
            }
        }
    }

    /// The grace elapsed with the receiver still missing from the browse — it
    /// really has left the network, so grey the row now. Inert if a later browse
    /// listed the id again (the entry was dropped) or if a newer absence has
    /// since armed its own timer (the generation moved on). On `stateQueue`.
    private func expireCastAbsence(_ id: String, _ generation: Int) {   // on stateQueue
        guard castAbsenceFlips[id] == generation else { return }
        castAbsenceFlips[id] = nil
        guard var device = known[id], device.isCast, device.isAvailable else { return }
        device.isAvailable = false
        commitKnownDevice(id, device)
        logCastRowState(device)
    }

    /// One `cast_row_state` line per Cast availability / connection-state change:
    /// the diagnostic that says whether a row the user saw as "disabled" really
    /// was unavailable, or merely lacked a connection halo. Emitted only from
    /// `stateQueue` (never the capture IOProc), and `Telemetry.log` formats and
    /// hands off to its own queue, so it never blocks a decision.
    private func logCastRowState(_ device: Device) {   // on stateQueue
        Telemetry.log(.cast, "cast_row_state", [
            "device": device.id,
            "isAvailable": device.isAvailable ? "true" : "false",
            "connectionState": Self.castRowConnectionName(device.connectionState),
        ])
    }

    private static func castRowConnectionName(_ state: ConnectionState) -> String {
        switch state {
        case .off: return "off"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reconnecting: return "reconnecting"
        case .failed(let failure): return "failed(\(failure.cause))"
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
            // Set on EITHER `added` edge below and acted on after the commit —
            // `reconcileEQPlan` reads `added`/`known` and may write
            // `eqBypassReason` through `applyLocal`, which the in-flight `device`
            // copy would otherwise clobber. That deferral is why these two arms
            // can't go through `removeFromAddedLocked` like every other
            // departure site.
            var eqNeedsReconcile = false
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
                //
                // F-REBIND: this is the branch a session rebind lands on. The rebind's
                // `removeOutput` makes the engine report `.stopped` (dropping `added`),
                // so its `addOutput` arrives here reading `!wasAdded` — indistinguishable
                // from a fresh connect. `connectVolumeSeed` tells them apart by intent
                // (`userConnectSeed`) and keeps the in-session level for the rebind.
                if !wasAdded, let seededVolume = self.connectVolumeSeed(id, outputID: outputID) {
                    device.volume = seededVolume
                }
                // The other `added` false→true site (decision 16): an
                // out-of-band reconnect re-establishes the session on stream 0,
                // so this device's EQ stream has to be re-claimed.
                eqNeedsReconcile = !wasAdded
            case .failed, .passwordRequired:
                // A live session died / needs a PIN we don't have: surface it as
                // unavailable + deselected and drop it from the streaming set. PARK
                // it (root cause 5) so converge doesn't immediately re-issue a
                // session against a receiver that just failed — the park is cleared
                // only on a genuine edge (storm fix, 2026-08-06): a came-back
                // discovery edge, an engine good-state transition, a membership
                // edge, or `retryOutput` — a same-descriptor re-announce keeps it.
                device.isAvailable = false
                device.isSelected = false
                let wasStreaming = self.added.remove(id) != nil
                eqNeedsReconcile = wasStreaming
                if self.desiredOn[id] == true {
                    self.failedGate.insert(id)
                    // `.passwordRequired` is the one engine failure with a KNOWN,
                    // actionable cause — don't flatten it to `.unknown` (live
                    // 2026-08-06: an auth-blocked receiver was debugged blind
                    // because the panel said "failed for an unknown reason" while
                    // the engine knew it wanted a password). A device that WAS
                    // streaming is the other known shape: a live session dying
                    // out-of-band is precisely "was connected, silently dropped".
                    let cause: ConnectionFailure.Cause =
                        state == .passwordRequired
                            ? .authRequired
                            : (wasStreaming ? .droppedMidStream : .unknown)
                    device.connectionState = .failed(
                        ConnectionFailure(cause: cause, detail: "engine state: \(state)")
                    )
                }
            case .stopped:
                device.isSelected = false
                eqNeedsReconcile = self.added.remove(id) != nil
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
            guard device != before else {
                // The snapshot is unchanged but `added` may still have flipped
                // (every visible field was already at its connected value), and
                // either edge is what owes an EQ reconcile.
                if eqNeedsReconcile { self.reconcileEQPlan() }
                return nil   // de-dupe the completion echo
            }
            // R5: `.failed`/`.passwordRequired` above just made this device
            // unreachable, and `.connected`/`.streaming` just made it reachable —
            // both are per-app redirect edges the discovery path never sees, so this
            // commit (not a bare `known[id] =`) is what replays the route table.
            self.commitKnownDevice(id, device)
            if eqNeedsReconcile { self.reconcileEQPlan() }
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
    /// our own write back arrives equal to the level we last put ON THE WIRE and
    /// dies here, and the −30…0 dB ↔ 0…100 map is linear both ways so a round-trip
    /// is rounding-stable. Swipe bursts are absorbed by ``pushVolume``'s in-flight
    /// coalescing (latest wins), never dropped.
    ///
    /// ## `level` is a WIRE level; `Device.volume` is not (do not conflate them)
    /// The two are the same number only while the master gain is 100. The moment any
    /// gain exists, `level` carries `stored × gain` — so:
    ///
    /// - the loop-breaking guard compares against ``effectiveVolume(of:)``, not the
    ///   stored level. Comparing a wire value against a stored value would mistake
    ///   our OWN reflected write for a knob turn, overwrite the user's setting with
    ///   the attenuated value, and then re-push THAT through the gain again — a
    ///   ratchet toward silence that also destroys what the user dialled in.
    /// - a genuine change is stored with the gain INVERTED, so `known[id].volume`
    ///   stays the user's own setting for that device, exactly as it does on every
    ///   other path.
    ///
    /// A gain of 0 is ignored outright: every device is being sent silence, so a
    /// reported level says nothing about what the user wants, and the inverse is
    /// undefined there anyway.
    private func setSpeakerVolume(id: String, outputID: OutputID, level: Double) {   // on stateQueue
        let gain = masterGainFraction
        guard gain > 0 else { return }
        let wirePct = Int((level * 100).rounded()).clampedToVolume
        let stored = Int((Double(wirePct) / gain).rounded()).clampedToVolume
        if muted.contains(id) {
            // Don't un-mute from a knob turn; record the intended level so a later
            // unmute restores what the user dialed in on the speaker.
            stashedVolume[id] = stored
            return
        }
        guard wirePct != effectiveVolume(of: id) else { return }
        applyLocal(id) { $0.volume = stored }
        // Per-device (AP1 curve or AP2 linear) rather than the AP2-only static map —
        // a pre-existing inconsistency, since every other push here is per-device.
        pushVolume(outputID, id: id,
                   engineValue: engineVolume(forID: id, uiVolume: stored),
                   uiLevel: stored)
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
            let target = (current + direction.signum() * Self.speakerVolumeStep).clampedToVolume
            // Step in the STORED domain (so consecutive presses move the user's own
            // level by a fixed amount, as before) but hand `setSpeakerVolume` a WIRE
            // level, which is its contract — it inverts the gain back out.
            self.setSpeakerVolume(id: id, outputID: match.value,
                                  level: Double(target) * self.masterGainFraction / 100.0)
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
            isSelected: added.contains(id),
            // The stored tone, from the moment the row appears — a speaker the
            // user shaped last week must not show flat until they touch it
            // again. `eqBypassReason` is deliberately left `nil`: both its cases
            // describe a LIVE session, which nothing that isn't streaming yet
            // can have. `reconcileEQPlan` sets it on the `added` edge and clears
            // it when the device stops streaming.
            eq: eqByDeviceID[id] ?? .flat
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
            result.connectionState = .failed(ConnectionFailure(cause: .vanished))
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
        engineVolume(fraction: Double(uiVolume.clampedToVolume) / 100.0)
    }

    /// The same AP2 map taking an already-normalized 0.0…1.0 fraction (the identity,
    /// clamped). Exists so the master gain can be folded in without round-tripping
    /// through an intermediate integer — see ``engineVolume(forID:uiVolume:)``.
    static func engineVolume(fraction: Double) -> Double {
        min(max(fraction, 0.0), 1.0)
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
        engineVolumeAP1(fraction: Double(uiVolume.clampedToVolume) / 100.0)
    }

    /// The AP1 curve taking an already-normalized 0.0…1.0 fraction. The gain-folding
    /// counterpart of ``engineVolume(fraction:)``.
    static func engineVolumeAP1(fraction: Double) -> Double {
        let x = min(max(fraction, 0.0), 1.0)
        let shaped = pow(x, 0.6)                        // mild perceptual taper
        let dB = airPlay1MinVolumeDB * (1.0 - shaped)  // x=1 → 0 dB, x=0 → MIN_DB
        let pct = (dB + 30.0) / 0.3                     // invert the C map → device->volume pct
        return max(0.0, min(1.0, pct / 100.0))
    }

    /// Pick the AP1 perceptual curve or the AP2 linear map by device, **and fold in
    /// the master gain** — this is the ONE place `Main × Group × Device` is formed.
    /// MUST be called on `stateQueue` (reads `known` plus both gain stages). Unknown
    /// id falls back to linear.
    ///
    /// Every real level push routes through here (`setVolume`, `applyStartBuffer`'s
    /// re-push, `restoreEffectiveVolume`, `connectVolumeSeed`, `setSpeakerVolume`,
    /// `setMasterGain`'s re-push), which is why the multiply belongs here and nowhere
    /// else — and why the effective value never needs to be stored to exist.
    ///
    /// Two deliberate properties:
    /// - **Double domain throughout.** The product is built as
    ///   `uiVolume/100 × main/100 × group/100` with no intermediate integer, so
    ///   nothing compounds rounding across the three stages.
    /// - **Before the curve, not after.** The gain scales the UI-domain fraction that
    ///   is then handed to either map, so "Main at 40" means 40% of the fader's travel
    ///   on AP1 and AP2 alike. Applying it after the AP1 curve would instead attenuate
    ///   an already-compressed dB value, and the same Main setting would mean two
    ///   different things on the two protocols.
    private func engineVolume(forID id: String, uiVolume: Int) -> Double {
        let fraction = Double(uiVolume.clampedToVolume) / 100.0 * masterGainFraction
        let isAirPlay2 = known[id]?.supportsAirPlay2 ?? true
        // ZERO MEANS SILENT, from whichever stage produced it — Main, the group, or
        // the device's own fader. Without this an AP1 receiver floors at
        // `airPlay1MinVolumeDB` (−12 dB), which is plainly audible: pulling Main to
        // 0 would duck the room but not silence it. Reuses the true-mute sentinel
        // the mute path already sends (`setMuted`, ~1548) so "muted" and "turned all
        // the way down" reach an AP1 receiver as the same −144 dB, instead of
        // disagreeing by 12 dB.
        //
        // Deliberately EXACT zero, not an epsilon: the inputs are integer percents,
        // so `0/100` is exactly 0.0 and any audible-but-tiny value must still take
        // the curve. And deliberately only the zero case — whether −12 dB is the
        // right floor for the AUDIBLE range is a by-ear question against real
        // hardware (see ``airPlay1MinVolumeDB``), untouched here.
        if fraction == 0 { return isAirPlay2 ? Self.engineVolume(fraction: 0) : -1.0 }
        return isAirPlay2
            ? Self.engineVolume(fraction: fraction)
            : Self.engineVolumeAP1(fraction: fraction)
    }

    /// `Main × Group` as a 0.0…1.0 fraction. On `stateQueue`.
    private var masterGainFraction: Double {   // on stateQueue
        Double(mainOutGain) / 100.0 * Double(groupGain) / 100.0
    }

    /// The wire level currently in force for `id`: the user's stored level scaled by
    /// the master gain, in the UI's 0–100 domain. COMPUTED, never stored — it exists
    /// only to be compared against a level a receiver reports back to us (see
    /// ``setSpeakerVolume(id:outputID:level:)``). On `stateQueue`.
    private func effectiveVolume(of id: String) -> Int {   // on stateQueue
        Int((Double(known[id]?.volume ?? 0) * masterGainFraction).rounded()).clampedToVolume
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
    private var volumePending: [OutputID: (engineValue: Double, id: String, uiLevel: Int?)] = [:]

    /// The last UI-domain level per device id the ENGINE actually acknowledged —
    /// the only level we know a receiver really has. A refused push falls back to
    /// this so the fader shows something true rather than the value that failed.
    /// On `stateQueue`.
    private var confirmedVolume: [String: Int] = [:]

    /// Push a volume to the engine off-queue (the engine op is async), serialized
    /// per output id via ``volumeInFlight``/``volumePending`` so at most one
    /// `engine.setVolume` call for a given output is ever in flight concurrently.
    /// `uiLevel` is the 0–100 level the fader is optimistically showing because of
    /// this push, or `nil` when the push doesn't correspond to a fader position
    /// (a mute's silence push, a master-gain re-push, a seed while muted) — a
    /// throw then re-emits the last confirmed level so the fader never lies about
    /// where a speaker is. On `stateQueue`.
    private func pushVolume(_ outputID: OutputID, id: String, engineValue: Double, uiLevel: Int?) {
        guard !volumeInFlight.contains(outputID) else {
            volumePending[outputID] = (engineValue, id, uiLevel)
            return
        }
        volumeInFlight.insert(outputID)
        issueVolumePush(outputID, id: id, engineValue: engineValue, uiLevel: uiLevel)
    }

    /// Issue one `setVolume` call and, on completion, either chase the latest
    /// superseding value queued in ``volumePending`` or clear ``volumeInFlight``.
    /// Not on `stateQueue` itself (the engine call is async) — re-enters it only
    /// to touch the dictionaries, matching every other engine-callback pattern in
    /// this file.
    ///
    /// The completion is also the ONLY feedback this backend gets about a volume
    /// write (there is no poll loop by design — the engine's completions ARE
    /// ground truth), so it doubles as the fader's bound: success records
    /// ``confirmedVolume``, a throw snaps the model back to it.
    private func issueVolumePush(_ outputID: OutputID, id: String, engineValue: Double, uiLevel: Int?) {
        let engine = self.engine
        Task { [weak self] in
            var failed = false
            do {
                try await engine.setVolume(outputID, engineValue)
            } catch {
                failed = true
            }
            guard let self else { return }
            self.stateQueue.async {
                if let uiLevel {
                    if failed {
                        // Revert only when this push's optimistic echo is still
                        // exactly what the UI shows: a newer user edit (queued
                        // push, a mute, or a level that has since moved on) owns
                        // the fader now and must never be clobbered by a stale
                        // failure. Nor is there anything to say without a level
                        // the engine once acknowledged.
                        if self.volumePending[outputID] == nil,
                           !self.muted.contains(id),
                           self.known[id]?.volume == uiLevel,
                           let confirmed = self.confirmedVolume[id],
                           confirmed != uiLevel {
                            self.applyLocal(id) { $0.volume = confirmed }
                        }
                    } else {
                        self.confirmedVolume[id] = uiLevel
                    }
                }
                if let next = self.volumePending.removeValue(forKey: outputID) {
                    self.issueVolumePush(outputID, id: next.id, engineValue: next.engineValue, uiLevel: next.uiLevel)
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
        // `commitKnownDevice`, not a bare write: `change` may flip `isAvailable`
        // (converge add success/failure, `markUnavailable`), which is a per-app
        // redirect edge the effective route table has to be replayed for (R5).
        commitKnownDevice(id, device)
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
    /// still has no diagnostics seam (T3 is OwnTone-only per the brief; the engine's
    /// completion IS the evidence), so causes come from the evidence already in
    /// hand: the converge catch maps `passwordRequired → .authRequired` and
    /// `opTimedOut → .timedOut` and always carries the engine error as `detail`,
    /// the connect-time PTP gate (T4) passes its own `cause`, and anything else
    /// stays `.unknown`. `detail` is what backs "Copy details" in the UI.
    private func enterFailure(_ id: String, cause: ConnectionFailure.Cause = .unknown, detail: String? = nil) {   // on stateQueue
        setConnectionState(.failed(ConnectionFailure(cause: cause, detail: detail)), for: id)
    }

    /// Recompute the effective (wire) volume after an unmute: push the stashed
    /// intended level and echo it locally. Mirrors
    /// `OwnToneBackend.restoreEffectiveVolume`. On `stateQueue`.
    private func restoreEffectiveVolume(_ id: String, outputID: OutputID) {   // on stateQueue
        let intended = stashedVolume[id] ?? known[id]?.volume ?? 0
        stashedVolume[id] = nil
        applyLocal(id) { $0.volume = intended }
        pushVolume(outputID, id: id,
                   engineValue: engineVolume(forID: id, uiVolume: intended),
                   uiLevel: intended)
    }

    /// Seed a just-(re)connected engine output's starting volume — from the
    /// configured connect-volume default on a connect the user asked for, or from the
    /// level the device was already streaming at on one it didn't (F-REBIND, see
    /// ``userConnectSeed``). Pushes the level to the engine and returns the value to
    /// display on the model, or `nil` when the seed is suppressed (leave the model
    /// volume untouched). On `stateQueue`.
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
    /// Source of the level (G1-N1) for a USER-intended connect: ``connectVolumeProvider``
    /// — the user's configured connect volume (``AppSettings/connectVolume``, default
    /// 35%), NOT the Mac's current system level. An earlier design inherited the system level,
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
    /// On a connect the USER asked for, the seed reads ``connectVolumeProvider``
    /// (a `UserDefaults`-backed `AppSettings` read — cheap, non-blocking, unlike
    /// the old system-volume HAL read) and clamps it to
    /// ``AppSettings/minConnectVolume``…``AppSettings/maxConnectVolume``. That
    /// clamp is the load-bearing safety net for the DEFAULT: even if the setting
    /// or an injected test provider returns 0 or something out of range, the
    /// default that reaches the wire is always audible.
    ///
    /// The clamp does NOT bound the F-REBIND preserve branch: a level the user
    /// dialled in themselves is theirs to keep, INCLUDING a deliberate 0 (an
    /// unmuted device the user set to silence stays silent across a rebind —
    /// re-blasting it to the default on a Bluetooth-connect glitch would be the
    /// worse surprise). So 0/silent IS reachable via preserve — but only when the
    /// user chose it, never as an accidental −30 dB trap: the trap is a *re-made
    /// session sitting at engine 0 because nobody set a level*, and both branches
    /// here always set one.
    private func connectVolumeSeed(_ id: String, outputID: OutputID) -> Int? {   // on stateQueue
        guard !bufferReAdding.contains(id) else { return nil }
        // F-REBIND: the connect default belongs to a connect the USER asked for. An
        // add nobody asked for — the session rebind a tap rebuild fires when macOS
        // changes the default output device — keeps the level the device was already
        // streaming at. Either way a level IS pushed: the re-made session sits at
        // engine volume 0 = the −30 dB trap no matter what re-made it, so returning
        // early here would trade a reset volume for a silent device.
        //
        // `known[id].volume` reads 0 while muted (the stash shim, `setMuted`), so the
        // in-session level comes from `stashedVolume` first — the same read
        // `restoreEffectiveVolume` and `applyStartBuffer` use. A preserved level is
        // NOT re-clamped to the connect range: that clamp bounds the DEFAULT, and a
        // level the user dialled in themselves is theirs to keep.
        let isUserConnect = userConnectSeed.remove(id) != nil
        let seed: Int
        if !isUserConnect, let inSession = stashedVolume[id] ?? known[id]?.volume {
            seed = inSession
        } else {
            seed = min(max(connectVolumeProvider(), AppSettings.minConnectVolume), AppSettings.maxConnectVolume)
        }
        if muted.contains(id) {
            // Keep the mute; only update the level an unmute will restore.
            // Via `engineVolume(forID:)` rather than the static AP2-only map, so a
            // muted AP1 receiver that drops and reconnects comes back TRULY silent
            // (−144 dB) instead of at the curve's −30 dB floor — quietly audible,
            // which is not what "muted" means. `setMuted` already sends the sentinel
            // on this device; this path had been missing it.
            stashedVolume[id] = seed
            pushVolume(outputID, id: id,
                       engineValue: engineVolume(forID: id, uiVolume: 0),
                       uiLevel: nil)
        } else {
            pushVolume(outputID, id: id,
                       engineValue: engineVolume(forID: id, uiVolume: seed),
                       uiLevel: seed)
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
        //
        // (This replaced our branch's `captureGateWantsCaptureLocked()` helper, whose
        // only override was the narrower wake-only `wakeCaptureOverride`; the silence
        // watchdog subsumes it, so the helper had no remaining caller.)
        let want = !suspended && !silenceCaptureOverride
            && expectedSelected.contains { known[$0]?.isLocalDevice == false }
        guard want != captureRunning else { return }   // already at target
        captureRunning = want
        if want {
            // T2 (send_sched dead-code fix, whole-system-dropout investigation):
            // capture just started — (re-)arm the scheduling snapshot poll HERE,
            // on every true edge, not just once at `start()` (before any device
            // is ever selected, when this gate's `want` is always still false —
            // the exact reason `send_sched` never fired in production).
            // `startSchedulingSnapshotPolling()` is idempotent on its own (it
            // cancels any previously-scheduled work item before arming a fresh
            // one), and this call site is additionally guarded by the
            // `want != captureRunning` check above, so a second selection while
            // already capturing never reaches here to re-arm a second time.
            startSchedulingSnapshotPolling()
        } else {
            // T16/E10 hygiene: capture is no longer desired — cancel any
            // pending whole-system-tap retry rather than let it fire later.
            // `scheduleCaptureRetry`'s own fire-time `captureRunning` re-check
            // would also catch this (calling `coordinator.start()` on a tap
            // nobody wants would re-mute the Mac's speakers for nothing — the
            // exact bug this gate exists to prevent), but there's no reason to
            // let a stale timer linger past the moment its outcome is decided.
            pendingCaptureRetry?.cancel()
            pendingCaptureRetry = nil
            // T2: same hygiene for the scheduling poll — capture just stopped,
            // so cancel its pending work item rather than let it fire once more
            // (harmlessly, since `pollSchedulingSnapshot`'s own guard re-checks
            // `captureRunning`) 5s from now.
            schedulingSnapshotPollWork?.cancel()
            schedulingSnapshotPollWork = nil
            // Nothing is routed any more, so a standing capture-failure note is
            // about a tap nobody wants — retire it. For a non-retryable failure
            // (`.osUnsupported`) this edge is the only thing short of a restart
            // that ever clears the note.
            if captureFailureNoteActive {
                captureFailureNoteActive = false
                emit(.captureFailed(message: nil, retrying: false))
            }
        }
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

    /// What one coalesced meter event is FOR — a device row (`.level`) or an app
    /// row (`.appLevel`). An enum rather than a bare `String` so a bundle id can
    /// never collide with a device id in the shared maps below.
    private enum LevelKey: Hashable {
        case device(String)
        case app(String)
    }

    /// Per-key leading-edge timestamp (`DispatchTime.now().uptimeNanoseconds`)
    /// of the last emitted meter event.
    private var lastLevelEmitNanos: [LevelKey: UInt64] = [:]
    /// Per-key latest value seen while inside the coalescing window, delivered
    /// by the trailing flush.
    private var pendingLevel: [LevelKey: Float] = [:]
    /// Keys with a trailing flush already scheduled, so a burst schedules at most
    /// one `asyncAfter` per key.
    private var levelFlushScheduled: Set<LevelKey> = []

    /// The tap's IOProc delivery thread must not enqueue per buffer — a
    /// `stateQueue.async` allocates a block and takes the queue's lock on a
    /// real-time thread. It try-stores into this slot instead (the
    /// `EQProcessor.mailbox` shape: a contended `try()` skips, never blocks),
    /// and `drainSystemRMS` reads it on `stateQueue` at the D3 cadence.
    private let systemRMSLock = NSLock()
    private var systemRMSSlot: Float = 0      // systemRMSLock
    private var systemRMSDirty = false        // systemRMSLock
    /// Whether a drain is already armed, so the chain stays single-flight.
    private var levelDrainScheduled = false   // stateQueue

    /// Record one whole-system-tap RMS sample. Runs on the tap's IOProc delivery
    /// thread, so it does exactly three things and none of them may block: no
    /// allocation, no unbounded lock, no dispatch enqueue. A contended `try()`
    /// DROPS the sample — the next buffer (~8 ms) refreshes it, and the meter
    /// reads at 25 Hz anyway, so a dropped sample is invisible.
    private func noteSystemRMS(_ rms: Float) {   // IOProc delivery thread
        guard systemRMSLock.try() else { return }
        systemRMSSlot = rms
        systemRMSDirty = true
        systemRMSLock.unlock()
    }

    /// Flip the popover-visibility metering gate. Forwards to ALL THREE RMS
    /// sources — the whole-system `captureCoordinator`, the `routeMixer`
    /// (`.device` per-app meter), and the `localPlaybackEngine` (`.currentDevice`
    /// per-app meter) — and drives the metering-only tap lifecycle (the
    /// `.noRedirect` per-app meter): on `true`, start a dedicated `.unmuted` tap
    /// for every currently-eligible listed app; on `false`, stop them all.
    /// `PopoverController` calls this on `surfaceDidShow`/`surfaceDidHide` via
    /// `backend as? MeteringControlling`. The `?` sub-components are `nil` in
    /// tests / the UI-only smoke path (harmless no-ops).
    public func setMeteringActive(_ active: Bool) {
        captureCoordinator?.setMeteringActive(active)
        routeMixer.setMeteringActive(active)
        localPlaybackEngine?.setMeteringActive(active)
        let diff: (start: Set<String>, stop: Set<String>) = stateQueue.sync {
            self.meteringActive = active
            if active {
                // A sample stored while the popover was closed is stale — it must
                // not replay as the first frame on reopen.
                self.systemRMSLock.lock()
                self.systemRMSDirty = false
                self.systemRMSLock.unlock()
                self.scheduleSystemRMSDrainLocked()
            }
            // When inactive the drain chain stops itself on its next fire.
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
    /// for METERING purposes — the fact `drainSystemRMS`/`emitCombinedLevel` need to
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
    /// from the T1-T3 dropout fixes. BLUETOOTH and CAST ids are excluded from the
    /// engine for the same structural reason (`setOutputSet`'s converge loop guards
    /// on `!device.isBluetooth`/`!device.isCast`), so `isSelected` is never true for
    /// either — asking it would leave both bars permanently dark. Each has
    /// its own "rendering now" fact: a BT row's `.connected`, which means that
    /// device's delay gate has opened (`BTDeviceSink.hasStartedRendering`) and is the
    /// same state that arms its dot — NOT `btSelectedUIDs`, which is intent and would
    /// light the bar on a selected-but-silent speaker; and `castPlaying` for a
    /// receiver that has reported PLAYING. Both sinks are handed the identical
    /// captured PCM this RMS was measured from (BT-FANOUT / CAST-FANOUT in
    /// `NativeCaptureCoordinator.deliver`), so reusing it is exact for them too.
    /// TRAP: the bar therefore shows the UNDELAYED source. A BT sync trim moves that
    /// device's own delay line, which sits DOWNSTREAM of this measurement, so
    /// changing a trim changes when the speaker sounds and never when the bar moves;
    /// one system RMS feeds every device's bar and no per-device delay can reach it.
    /// Must run on `stateQueue`, like every caller.
    private func isMeterable(_ device: Device) -> Bool {
        if device.isBluetooth { return device.connectionState == .connected }
        if device.isCast { return castPlaying.contains(device.id) }
        return device.isLocalDevice ? syncedLocalSinkEnabled : device.isSelected
    }

    /// Read whatever `noteSystemRMS` last stored (stream_id 0) and, if it is
    /// new, re-emit the combined `.level` for every device currently streaming it
    /// (``isMeterable``) and unmuted — its system contribution just changed.
    /// Re-arms itself, so the chain runs at `levelEmitIntervalNanos` for as long
    /// as metering is on and stops itself on the first fire after it goes off.
    /// On `stateQueue`.
    private func drainSystemRMS() {   // on stateQueue
        levelDrainScheduled = false
        guard meteringActive else { return }
        systemRMSLock.lock()
        let dirty = systemRMSDirty
        let rms = systemRMSSlot
        systemRMSDirty = false
        systemRMSLock.unlock()
        if dirty {
            latestSystemRMS = rms
            for id in order {
                guard let device = known[id], isMeterable(device), !device.isMuted else { continue }
                emitCombinedLevel(forDevice: id)
            }
        }
        scheduleSystemRMSDrainLocked()
    }

    /// Arm the next drain, single-flight and only while metering is on.
    /// On `stateQueue`.
    private func scheduleSystemRMSDrainLocked() {   // on stateQueue
        guard meteringActive, !levelDrainScheduled else { return }
        levelDrainScheduled = true
        stateQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(levelEmitIntervalNanos))) { [weak self] in
            self?.drainSystemRMS()
        }
    }

    /// Record one app's PRE-volume SOURCE level and fan it out: to the app's own
    /// row (`.appLevel`), and — if the app is `.device`-routed — into the combined
    /// meter of the device it feeds (a redirect target's contribution is the
    /// loudest source routed to it; see `emitCombinedLevel`). Gated on metering.
    /// Callable from any source thread (mixer queue, tap delivery, engine); hops
    /// to `stateQueue`. The `.appLevel` rides the SAME D3 sampler the per-device
    /// `.level` does, keyed by bundle id, so an app row is rate-limited to the
    /// display cadence exactly like a device row.
    private func emitAppLevel(bundleID: String, rms: Float) {
        stateQueue.async {
            guard self.meteringActive else { return }
            self.scheduleLevelEmit(key: .app(bundleID), rms: rms,
                                   now: DispatchTime.now().uptimeNanoseconds)
            self.latestAppLevel[bundleID] = rms
            // The device this app feeds tracks the loudest source routed to it, so
            // re-emit its combined `.level` now that this source level changed.
            // `routedBundleIDs` is the EFFECTIVE routed set (R5): an app whose target
            // is currently unreachable feeds the system mix, not that device, so it
            // must not animate the offline device's meter.
            for route in self.lastRoutes
            where route.bundleID == bundleID && self.routedBundleIDs.contains(bundleID) {
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
        // `routedBundleIDs` is the EFFECTIVE routed set (R5) — a route whose target
        // is unreachable right now contributes to the system mix, not to this
        // device, so it must not keep this device's bar alive while it is offline.
        for route in lastRoutes
        where routedBundleIDs.contains(route.bundleID) && !deadBundleIDs.contains(route.bundleID) {
            if case .device(let deviceID) = route.destination, deviceID == id,
               let level = latestAppLevel[route.bundleID] {
                sourceContribution = max(sourceContribution, level)
            }
        }
        scheduleLevelEmit(key: .device(id), rms: max(systemContribution, sourceContribution),
                          now: DispatchTime.now().uptimeNanoseconds)
    }

    /// The event one coalescer key delivers.
    private func levelEvent(for key: LevelKey, rms: Float) -> BackendEvent {
        switch key {
        case .device(let id): return .level(id: id, rms: rms)
        case .app(let bundleID): return .appLevel(bundleID: bundleID, rms: rms)
        }
    }

    /// Leading-edge/trailing-edge sampler (D3): emits immediately if at least
    /// `levelEmitIntervalNanos` has passed since this key's last emit;
    /// otherwise remembers the latest value and lets an already-scheduled trailing
    /// flush deliver it, so a burst's final value always lands and the meter never
    /// freezes on a stale pre-quiet value. On `stateQueue`.
    private func scheduleLevelEmit(key: LevelKey, rms: Float, now: UInt64) {   // on stateQueue
        if let last = lastLevelEmitNanos[key], now - last < levelEmitIntervalNanos {
            pendingLevel[key] = rms
            guard levelFlushScheduled.insert(key).inserted else { return }
            let remaining = levelEmitIntervalNanos - (now - last)
            stateQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(remaining))) { [weak self] in
                self?.flushPendingLevel(key: key)
            }
            return
        }
        lastLevelEmitNanos[key] = now
        pendingLevel.removeValue(forKey: key)
        emit(levelEvent(for: key, rms: rms))
    }

    /// Trailing flush for `scheduleLevelEmit` — delivers whatever value arrived
    /// last during the coalescing window, if any (a leading-edge emit may have
    /// already cleared it). On `stateQueue`.
    private func flushPendingLevel(key: LevelKey) {   // on stateQueue
        levelFlushScheduled.remove(key)
        guard let rms = pendingLevel.removeValue(forKey: key) else { return }
        lastLevelEmitNanos[key] = DispatchTime.now().uptimeNanoseconds
        emit(levelEvent(for: key, rms: rms))
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
    /// Which stream `id`'s LIVE engine session is actually bound to, or `nil`
    /// when the engine has no live session for it (T7 — see
    /// ``AirPlayEngine/AirPlayEngine/boundStreamId(for:)``). This is the query
    /// the architecture review's defect B says the engine lacked: without it the
    /// Swift side cannot tell "I bound it where I asked" from `addOutput`'s
    /// silent already-live no-op, so a device that never moved streams reads as
    /// routed and is inaudible. Default returns `nil` ("can't tell"), which makes
    /// every pre-T7 conformer fall through to exactly its previous behavior.
    func boundStreamId(for id: OutputID) async -> UInt32?
    /// Move `id`'s live session to `streamId` as ONE engine-serialized op (T7 —
    /// see ``AirPlayEngine/AirPlayEngine/rebindOutput(_:toStreamId:)``). The real
    /// engine holds its per-`OutputID` `opsInFlight` slot across both the stop and
    /// the re-add, so nothing can slip between them and leave the device on a
    /// third stream. Default is the historical stop-then-re-add pair.
    func rebindOutput(_ id: OutputID, toStreamId streamId: UInt32) async throws
    func removeOutput(_ id: OutputID) async throws
    /// Re-anchor `id`'s receiver timeline in place via RTSP FLUSH, WITHOUT tearing
    /// down the session (F-REANCHOR — see ``AirPlayEngine/AirPlayEngine/flushOutput(_:)``).
    /// Returns `true` only if a flush was ACTUALLY issued; `false` means the vendored
    /// flush no-op'd (device not streaming), and the caller MUST fall back to a real
    /// teardown+re-add. Default returns `false` (didn't flush) so a conformer with no
    /// real session safely drives the caller to teardown; ``EngineAdapter`` overrides
    /// it with the real flush.
    func flushOutput(_ id: OutputID) async throws -> Bool
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

    /// Diagnostic snapshot of the engine's write-path backpressure guard (T14):
    /// cumulative writes DROPPED because a stream's un-drained backlog hit the
    /// cap, plus the current worst-case backlog. Read-only and side-effect-free —
    /// it reports what the guard already did, it never gates a write. Surfaced so
    /// a live run can tell "audio is being discarded by backpressure" apart from
    /// "audio is being interrupted by a rebuild/reset", which the routing
    /// telemetry already covers.
    func writeBacklogSnapshot() -> WriteBacklogSnapshot

    /// Snapshot of the write-path scheduling metrics (T1 — mirrors
    /// `AirPlayEngine/writeSchedulingSnapshot()`). Cheap to read from any thread
    /// (lock-free, bounded, small copy). Returns an empty snapshot by default so
    /// a conformer that predates this (e.g., a test spy) compiles unchanged.
    /// Called by T2 polling every ~5s to log to telemetry while capture is active.
    nonisolated func writeSchedulingSnapshot() -> WriteSchedulingSnapshot

    /// Snapshot of the write-cadence deficit/overrun counters (T-ENG-CADENCE-1
    /// — mirrors `AirPlayEngine/writeCadenceSnapshot()`). `nonisolated` and
    /// cheap to read from any thread, same rationale as
    /// `writeSchedulingSnapshot()`. Returns an empty (zeroed) snapshot by
    /// default so a conformer that predates this (e.g., a test spy) compiles
    /// unchanged. Sampled by `sampleWriteCadenceIfDue()` on the per-app
    /// mixer's write path, same throttled/delta-gated cadence as
    /// `writeBacklogSnapshot()`/`write_backlog_drop`.
    nonisolated func writeCadenceSnapshot() -> WriteCadenceSnapshot
}

extension EngineControlling {
    /// Default: an all-zero (healthy) snapshot, so every existing test double
    /// compiles unchanged. ``EngineAdapter`` overrides this with the real read.
    func writeBacklogSnapshot() -> WriteBacklogSnapshot { WriteBacklogSnapshot() }

    /// Default: legacy single-stream behavior (`streamId` 0), so a conformer
    /// that predates T2 doesn't need updating. ``EngineAdapter`` overrides this
    /// with the real forwarding call.
    func addOutput(_ id: OutputID, streamId: UInt32) async throws {
        try await addOutput(id)
    }

    /// Default: "can't tell" (T7). ``EngineAdapter`` overrides this with the real
    /// live-session read; a conformer that predates T7 keeps its previous
    /// behavior, because every caller falls back to the plain add path on `nil`.
    func boundStreamId(for id: OutputID) async -> UInt32? { nil }

    /// Default: the historical stop-then-re-add pair (T7). The tolerated
    /// `removeOutput` throw matches the old inline `.rebind` op — the device may
    /// not currently be added, and a no-op teardown is fine; only the add half
    /// determines success. ``EngineAdapter`` overrides this with the engine's
    /// genuinely serialized primitive.
    func rebindOutput(_ id: OutputID, toStreamId streamId: UInt32) async throws {
        try? await removeOutput(id)
        if streamId == 0 { try await addOutput(id) } else { try await addOutput(id, streamId: streamId) }
    }

    /// Default: `false` — "did not flush" (F-REANCHOR). A conformer with no live
    /// receiver timeline to re-anchor safely drives the caller to the teardown
    /// fallback; ``EngineAdapter`` overrides this to forward to the real engine.
    func flushOutput(_ id: OutputID) async throws -> Bool { false }

    /// Default: drop the buffer. ``EngineAdapter`` overrides this to forward to the
    /// real engine; a conformer that never receives per-app mixed audio ignores it.
    func write(pcm: Data, streamId: UInt32, pts: timespec) {}

    /// Default: healthy (T4). ``EngineAdapter`` overrides this to forward to the
    /// real engine's `ptpClockAvailable`; a conformer that predates T4 (existing
    /// `NativeBackendTests` spies) compiles unchanged and reports "available".
    var ptpClockAvailable: Bool {
        get async { true }
    }

    /// Default: empty snapshot (T1). ``EngineAdapter`` overrides this to forward
    /// to the real engine's `writeSchedulingSnapshot()`; a conformer that
    /// predates T1 (existing `NativeBackendTests` spies) compiles unchanged
    /// and reports no metrics.
    nonisolated func writeSchedulingSnapshot() -> WriteSchedulingSnapshot {
        WriteSchedulingSnapshot()
    }

    /// Default: empty snapshot (T-ENG-CADENCE-1). ``EngineAdapter`` overrides
    /// this to forward to the real engine's `writeCadenceSnapshot()`; a
    /// conformer that predates this (existing `NativeBackendTests` spies)
    /// compiles unchanged and reports no metrics.
    nonisolated func writeCadenceSnapshot() -> WriteCadenceSnapshot {
        WriteCadenceSnapshot()
    }
}

/// Adapts the concrete ``AirPlayEngine`` actor to ``EngineControlling``. Thin —
/// every call forwards straight through (the engine's own actor isolation + engine
/// thread do the real serialization).
struct EngineAdapter: EngineControlling {
    let engine: AirPlayEngine

    func start() async throws { try await engine.start() }
    func stop() async { await engine.stop() }
    /// Real read of the write-path backpressure guard (T14 diagnostic).
    /// `nonisolated` on the engine, so no hop/await is needed here.
    func writeBacklogSnapshot() -> WriteBacklogSnapshot { engine.writeBacklogSnapshot() }
    @discardableResult
    func updateDiscovery(_ descriptor: DeviceDescriptor) async throws -> OutputID {
        try await engine.updateDiscovery(descriptor)
    }
    func removeDiscovery(_ descriptor: DeviceDescriptor) async { await engine.removeDiscovery(descriptor) }
    func addOutput(_ id: OutputID) async throws { try await engine.addOutput(id) }
    func addOutput(_ id: OutputID, streamId: UInt32) async throws {
        try await engine.addOutput(id, streamId: streamId)
    }
    func boundStreamId(for id: OutputID) async -> UInt32? { await engine.boundStreamId(for: id) }
    func rebindOutput(_ id: OutputID, toStreamId streamId: UInt32) async throws {
        try await engine.rebindOutput(id, toStreamId: streamId)
    }
    func removeOutput(_ id: OutputID) async throws { try await engine.removeOutput(id) }
    func flushOutput(_ id: OutputID) async throws -> Bool { try await engine.flushOutput(id) }
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
    nonisolated func writeSchedulingSnapshot() -> WriteSchedulingSnapshot {
        engine.writeSchedulingSnapshot()
    }
    nonisolated func writeCadenceSnapshot() -> WriteCadenceSnapshot {
        engine.writeCadenceSnapshot()
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

/// The slice of ``DACPServer`` ``NativeBackend`` drives. Extracted as a protocol
/// for the same reason as ``DiscoverySource``: the real server's `start(dacpID:)`
/// binds a live `NWListener` and advertises `_dacp._tcp` over Bonjour — a real
/// socket that fires the macOS Local Network permission prompt (once per
/// `swift test --parallel` worker process). Tests inject a no-op double so the
/// hermetic suite opens zero sockets; the volume-report handling itself stays
/// covered via `applyDacpVolume`/`applyDacpVolumeStep` (the exact closures
/// `start()` wires to `onVolume`/`onVolumeStep`) and the pure
/// `DACPServer.parse(_:)`/`level(fromDb:)` statics. The real listener wiring is
/// exercised by the gated live tests only (D7 discipline).
protocol DACPEndpoint: AnyObject, Sendable {
    var onVolume: (@Sendable (_ activeRemote: UInt32, _ level: Double) -> Void)? { get set }
    var onVolumeStep: (@Sendable (_ activeRemote: UInt32, _ direction: Int) -> Void)? { get set }
    func start(dacpID: UInt64)
    func stop()
}

extension DACPServer: DACPEndpoint {}

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
    /// Fired once per state transition (T16, E10 — the whole-system-tap
    /// `.failed` retry) so `NativeBackend` can react to `.failed`/`.capturing`
    /// the same way it already reacts to `PerAppCaptureCoordinator.onStateChange`.
    /// See ``NativeCaptureCoordinator/onStateChange``.
    var onStateChange: (@Sendable (_ state: NativeCaptureCoordinator.State) -> Void)? { get set }

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

    /// Mode-aware align-tick seam (W2): `.wizard` carries the alignment
    /// wizard's shape (long tick budget + keep-alive bed wake preamble) without
    /// exposing the injector's internals through this public protocol. Default
    /// (below) forwards to `setAlignTick(_:)`; ``NativeCaptureCoordinator``
    /// provides the real mode → injector-config mapping.
    func setAlignTickMode(_ mode: AlignTickMode)

    /// Make the wizard's ticks audible (roadmap 056 Part B): the run opens on
    /// bed/silence so every sink can anchor and every amp can wake, and the
    /// backend arms the beat grid once they have. Default no-op;
    /// ``NativeCaptureCoordinator`` provides the real one.
    func armWizardTicks()
    /// Swap the wizard's beat interval mid-run (search stage → blocks stage).
    /// Same default-no-op posture as ``armWizardTicks()``.
    func setWizardTempo(bpm: Double)

    /// Stage the mic-probe calibration sweeps on the live wizard feed
    /// (roadmap 064): the arm gate then starts them in place of the first
    /// tick. Default no-op; ``NativeCaptureCoordinator`` provides the real one.
    func stageWizardMicProbe(onStarted: @escaping () -> Void,
                             onFinished: @escaping () -> Void)

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

    /// Attach/detach the Bluetooth sink-manager fan-out (BT-FANOUT) — same
    /// contract as `setSyncedLocalSink`, one slot per consumer. Default no-op;
    /// ``NativeCaptureCoordinator`` provides the real one.
    func setBTSink(_ sink: SyncedLocalPCMSink?, renderProcessPID: pid_t?)

    /// Attach/detach the Cast fan-out (CAST-FANOUT) — same contract again, and
    /// the converted S16LE goes straight in (no widen/resample). Default no-op;
    /// ``NativeCaptureCoordinator`` provides the real one.
    func setCastSink(_ sink: PCMSink?, renderProcessPID: pid_t?)

    /// CAST-SYNC: hold the AirPlay feed back by `ms` before the engine write,
    /// so a Cast receiver playing seconds behind live can still be the room's
    /// reference. `0` removes the line outright (the bypass is its absence, not
    /// a zero delay). Default no-op; ``NativeCaptureCoordinator`` provides the
    /// real one.
    func setAirPlayPreDelay(ms: Int)

    /// Start/stop the align-by-ear tick mixed into the captured feed
    /// (BT-OFFSET-UI). Default no-op; ``NativeCaptureCoordinator`` provides
    /// the real one.
    func setAlignTick(_ active: Bool)

    /// Hand the delivery path a new set of tone stages: the Main Out EQ (applied
    /// before every fan-out) plus one AirPlay write per EQ stream. Default no-op
    /// so a fake that doesn't exercise EQ compiles unchanged;
    /// ``NativeCaptureCoordinator`` provides the real one. See
    /// ``NativeCaptureCoordinator/setEQPlan(_:)``.
    func setEQPlan(_ plan: WholeSystemEQPlan)
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
    /// Default no-op (BT-FANOUT), same posture.
    func setBTSink(_ sink: SyncedLocalPCMSink?, renderProcessPID: pid_t?) {}
    /// Default no-op (CAST-FANOUT), same posture.
    func setCastSink(_ sink: PCMSink?, renderProcessPID: pid_t?) {}
    /// Default no-op (CAST-SYNC), same posture.
    func setAirPlayPreDelay(ms: Int) {}
    /// Default no-op (BT-OFFSET-UI align tick), same posture.
    func setAlignTick(_ active: Bool) {}
    /// Default no-ops (roadmap 056 Part B wizard stimulus), same posture.
    func armWizardTicks() {}
    func setWizardTempo(bpm: Double) {}
    /// Default no-op (roadmap 064 mic probe), same posture.
    func stageWizardMicProbe(onStarted: @escaping () -> Void,
                             onFinished: @escaping () -> Void) {}
    /// Default no-op (per-device + Main Out EQ), same posture.
    func setEQPlan(_ plan: WholeSystemEQPlan) {}
    /// Default forwards to the flag-only seam so a fake recording plain
    /// `setAlignTick` calls also observes wizard activations (W2).
    func setAlignTickMode(_ mode: AlignTickMode) {
        setAlignTick(mode != .off)
    }
}

extension NativeCaptureCoordinator: CaptureControlling {}

/// Optional backend capability for the Bluetooth device-row UI (BT-UI /
/// BT-OFFSET-UI) — the same `backend as? Capability` pattern as
/// ``MeteringControlling``/``AppRouteConfiguring``: `NativeBackend` is the only
/// conformer; on `MockBackend`/`OwnToneBackend` the cast is `nil` and the
/// popover's Bluetooth affordances degrade gracefully.
public protocol BTOutputControlling: AnyObject {
    /// When macOS last used each known BT pairing, keyed by `Device.id` — the
    /// popover's ghost-pairing sort input (stale pairings to the bottom).
    func lastUsedDatesForBTDevices() -> [String: Date]
    /// Set a device's SYNC trim (ms, snapped to `BTSyncTrim.resolutionMs` and
    /// clamped to ±`BTSyncTrim.rangeMs`): applied live to its `BTSyncedSink`
    /// delay, and written to disk only when `persist` is true.
    ///
    /// `persist: false` is the drawer's live SCRUB (D6): the ruler emits a new
    /// value many times a second while the user drags, and every one of those
    /// must reach the audio path — but writing the JSON store at that rate
    /// would be absurd. The drag's END (and every discrete gesture: a stepper
    /// click, a typed commit, Revert) arrives separately with `persist: true`.
    func setBTSyncTrim(_ ms: Double, forDevice id: String, persist: Bool)
    /// The saved SYNC trim for a device (0 when none) — what a disconnected
    /// row shows read-only, and what the drawer starts from.
    func btSyncTrim(forDevice id: String) -> Double
    /// Whether this device has a trim ENTRY at all — the honest answer to
    /// D10's "tuned or never tuned?", which a value alone cannot give: a
    /// device deliberately tuned to exactly 0.0 ms is tuned, and must not
    /// read "Not set".
    func btHasSyncTrim(forDevice id: String) -> Bool
    /// Delete this device's stored alignment — its measured latency AND its
    /// trim — and put the live sink back on unaligned scheduling (roadmap 056:
    /// the drawer's "Reset alignment"). The entries are REMOVED, never written
    /// as 0: ``btHasSyncTrim(forDevice:)`` answers by existence, so a stored 0
    /// would leave the row reading "0 ms" rather than "Not set".
    func resetBTAlignment(forDevice id: String)
    /// Start/stop the align-by-ear tick in the captured feed (auto-limits to
    /// ~30 s of ticks on its own).
    func setBTAlignTickActive(_ active: Bool)

    // MARK: Alignment wizard (W2)

    /// Push a CANDIDATE trim live to the device's sink — clamped like
    /// ``setBTSyncTrim(_:forDevice:persist:)`` but NEVER persisted and never
    /// entering the stored trim table, so cancel can restore by re-pushing the
    /// store. (A selection change mid-wizard re-pushes stored trims over the
    /// preview; the wizard session re-applies on its next answer, so the stomp
    /// is a beat, not a loss.)
    func setBTWizardTrimPreview(_ ms: Double, forDevice id: String)
    /// End a preview: `keepMs` non-nil persists it (the wizard's Keep, via the
    /// ordinary ``setBTSyncTrim(_:forDevice:persist:)`` path); `nil` restores
    /// the stored trim to the live sink (cancel / Try again / graceful exit).
    func endBTWizardTrimPreview(forDevice id: String, keepMs: Double?)
    /// The wizard's continuous tick run — distinct from the row button's ~30 s
    /// ``setBTAlignTickActive(_:)``. The run OPENS on the keep-alive bed alone
    /// and the backend arms the ticks once every participating sink has
    /// actually released (roadmap 056 Part B) — that is what stops the Mac
    /// ticking on its own while a Bluetooth engine is still coming up.
    ///
    /// `btTargetDeviceID` names the Bluetooth device being measured, or `nil`
    /// for a Mac-target run. A Bluetooth target additionally pins the BT-only
    /// reference wide open (its latency is the unknown the run exists to find);
    /// the `false` edge does NOT lower it again — ``endBTWizardRun()`` does, so
    /// the receipt the user is judging plays on the same timeline the trials
    /// did.
    ///
    /// `btReferenceDeviceID` names the speaker the target is being compared
    /// AGAINST. A run is a two-speaker comparison, so every OTHER selected
    /// Bluetooth speaker is held silent for its duration — one at its own trim
    /// is simply the loudest thing in the room and gets judged instead of the
    /// target (live run 2026-08-22). Pass it whether or not it is a Bluetooth
    /// device; a Mac reference is not in the held set anyway.
    ///
    /// IDEMPOTENT for the tick itself: a redundant edge does nothing at all.
    /// Both edges re-anchor every sink, and the panel's Done button issues a
    /// second `false` after a terminal screen already stopped the tick. The
    /// participant hold is the exception — it is recomputed on every call, so a
    /// reference swapped mid-run comes back off the hold without a tick edge.
    func setBTWizardTickActive(_ active: Bool, btTargetDeviceID: String?,
                               btReferenceDeviceID: String?)
    /// The wizard panel is going away for good — Keep, Discard, Done, ✕,
    /// popover close, target lost. Lowers a Bluetooth run's raised reference
    /// back onto `max(floor, slowest measured latency + headroom)`, by which
    /// point a Keep's own measurement is already in the table, so the move is
    /// ONE composition re-anchor with nothing left to clamp. Idempotent.
    func endBTWizardRun()
    /// The wizard's beat interval, in BPM — the estimator's coarse search ticks
    /// far slower than its stimulus blocks so an unknown latency cannot alias
    /// into an apparent lead.
    func setBTWizardTickTempo(bpm: Double)

    // MARK: Measured latency (roadmap 056 Part A)

    /// A device's measured output latency in ms, or `nil` when the wizard has
    /// never run against it. The Mac is the zero this is measured from.
    func btMeasuredLatencyMs(forDevice id: String) -> Double?
    /// The latency values a wizard run may actually present for this device.
    /// The ceiling stops one default BT-only buffer SHORT of the reference — at
    /// the reference itself the delay is 0, which seeks the ring dry and takes
    /// the speaker silent for the rest of the session. The floor is NEGATIVE
    /// (`−BTSyncTrim.rangeMs`) even though a latency below 0 is not a physical
    /// quantity: without it a fresh speaker (base 0) dead-ends on its first
    /// "target first" answer. Nothing below 0 is ever persisted. Derived
    /// against the reference IN FORCE DURING A RUN (the raised wizard buffer,
    /// or the live AirPlay presentation delay), so it can be asked before the
    /// run starts.
    func btWizardLatencyRangeMs(forDevice id: String) -> ClosedRange<Double>
    /// Push a CANDIDATE latency live to the device's sink — never persisted,
    /// the exact twin of ``setBTWizardTrimPreview(_:forDevice:)`` and equally
    /// rebuild-free.
    func setBTWizardLatencyPreview(_ ms: Double, forDevice id: String, halfWidthMs: Double?)
    /// End a latency preview: `keepMs` non-nil persists it as the device's
    /// measured latency AND zeroes the device's trim (the run suspended it, and
    /// the nudge was a manual stand-in for the latency just measured); `nil`
    /// restores the stored latency and leaves the trim to
    /// ``endBTWizardTrimPreview(forDevice:keepMs:)``.
    func endBTWizardLatencyPreview(forDevice id: String, keepMs: Double?)

    // MARK: Mic probe (roadmap 064)

    /// Stage the one-shot mic-probe sweeps on the live wizard feed: DOWN sweep
    /// to the engine/AirPlay/Mac fan-out, UP sweep to the Bluetooth fan-out.
    /// Call after the wizard tick has been activated
    /// (``setBTWizardTickActive(_:btTargetDeviceID:btReferenceDeviceID:)``);
    /// the existing arm gate then starts the sweeps instead of the first tick,
    /// and the tick grid arms itself when they finish. `onStarted` fires at
    /// the gate opening, `onFinished` when the last sweep frame has entered
    /// the feed; a run torn down early fires neither — the mic session's
    /// timeout is the recovery. Default: no-op (mock/dev backends have no
    /// wizard feed to stage on).
    func stageBTMicProbe(onStarted: @escaping () -> Void, onFinished: @escaping () -> Void)

    // MARK: First-mix intercept (W3)

    /// Answer a ``BackendEvent/btFirstMixAlignmentPrompt(deviceID:)``: release
    /// the hold-silent (all three card actions unmute) and, for "Not now",
    /// record the FINAL per-device dismissal so the intercept never auto-fires
    /// for this device again. Also the abandon path (card torn down without an
    /// answer) with `dismissed: false` — that leaves no record, by design.
    func resolveBTAlignmentPrompt(forDevice id: String, dismissed: Bool)

    /// The usable trim range for a device (D11/T3) — the drawer's ruler and
    /// numeric field hard-stop here instead of at the nominal ±`BTSyncTrim
    /// .rangeMs`, because past this bound `SyncTiming.totalDelayNanos`'s ≥ 0
    /// clamp already eats the change and the readout would be lying.
    ///
    /// LIVE QUERY — the range moves whenever an AirPlay device joins or
    /// leaves the group (the reference term swaps between the fixed BT-only
    /// buffer and the live AirPlay presentation delay), so a conformer must
    /// answer fresh on every call, never from a value cached at some earlier
    /// point (e.g. drawer-open time). The default implementation below
    /// (full ±range) keeps mock/dev builds — which have no BT sink to ask —
    /// working unchanged.
    func btUsableTrimRangeMs(forDevice id: String) -> ClosedRange<Double>
}

extension BTOutputControlling {
    public func btUsableTrimRangeMs(forDevice id: String) -> ClosedRange<Double> {
        -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs
    }

    public func stageBTMicProbe(onStarted: @escaping () -> Void,
                                onFinished: @escaping () -> Void) {}
}

extension NativeBackend: BTOutputControlling {

    public func setBTSyncTrim(_ ms: Double, forDevice id: String, persist: Bool) {
        // Quantise, not merely clamp (T7 §7): the ruler resolves 0.1 ms, so
        // snapping here is what keeps the readout, the ruler and the persisted
        // value from ever disagreeing about what "22.4" means.
        let value = BTSyncTrim.quantise(ms)
        let all: [String: Double] = btTrimLock.withLock {
            btTrimsByUID[id] = value
            return btTrimsByUID
        }
        // The in-memory map updates on a scrub too — only the DISK write is
        // skipped. `btSyncTrim`/`btHasSyncTrim` are read-back seams, and a
        // reader mid-drag should see what the user is hearing.
        if persist {
            do { try btTrimStore?.save(all) } catch { StoreRecovery.noteWriteFailure(error) }
        }
        captureControlQueue.async { [weak self] in
            self?.btSink?.setTrimMs(value, forDeviceUID: id)
        }
    }

    public func btSyncTrim(forDevice id: String) -> Double {
        btTrimLock.withLock { btTrimsByUID[id] ?? 0 }
    }

    public func btHasSyncTrim(forDevice id: String) -> Bool {
        btTrimLock.withLock { btTrimsByUID[id] != nil }
    }

    public func resetBTAlignment(forDevice id: String) {
        btTrimLock.withLock {
            btLatencyMsByUID.removeValue(forKey: id)
            btTrimsByUID.removeValue(forKey: id)
        }
        // ONE read-modify-write of the file for both maps — and a genuine
        // delete, which `save`/`saveLatencies` (whole-map overwrites) could
        // only express by round-tripping the maps back out again.
        do { try btTrimStore?.clearAlignment(deviceUID: id) } catch { StoreRecovery.noteWriteFailure(error) }
        // The reference floor is a function of the slowest KNOWN latency, so
        // dropping one can move it — same ordering as the wizard's Keep: the
        // reference first, then the sink's own two terms, both hops enqueued
        // from `stateQueue` so `captureControlQueue` replays them in order.
        stateQueue.async {
            self.updateBTReferenceBufferLocked()
            self.captureControlQueue.async { [weak self] in
                self?.btSink?.setOffsetMs(0, forDeviceUID: id)
                self?.btSink?.setTrimMs(0, forDeviceUID: id)
            }
        }
    }

    public func setBTAlignTickActive(_ active: Bool) {
        captureCoordinator?.setAlignTick(active)
    }

    public func setBTWizardTrimPreview(_ ms: Double, forDevice id: String) {
        let clamped = BTSyncTrim.clamp(ms)
        captureControlQueue.async { [weak self] in
            self?.btSink?.setTrimMs(clamped, forDeviceUID: id)
        }
    }

    public func endBTWizardTrimPreview(forDevice id: String, keepMs: Double?) {
        if let keepMs {
            setBTSyncTrim(keepMs, forDevice: id, persist: true)
        } else {
            let stored = btSyncTrim(forDevice: id)
            captureControlQueue.async { [weak self] in
                self?.btSink?.setTrimMs(stored, forDeviceUID: id)
            }
        }
    }

    public func setBTWizardTickActive(_ active: Bool, btTargetDeviceID: String?,
                                      btReferenceDeviceID: String?) {
        // NOT edge-guarded, unlike everything below: the host re-pushes a `true`
        // when the user swaps the reference mid-run, and the new reference has
        // to come back off the hold that the old one was exempt from.
        updateBTWizardParticipantHold(
            active: active, targetUID: btTargetDeviceID, referenceUID: btReferenceDeviceID)
        // Idempotent (see the protocol): everything below is an EDGE cost — a
        // tick-mode swap, an arm gate, and a re-anchor of every FIFO sink — so
        // a `false` against an already-stopped tick must be nothing at all.
        let isEdge = btTrimLock.withLock { () -> Bool in
            guard btWizardTickActive != active else { return false }
            btWizardTickActive = active
            return true
        }
        guard isEdge else { return }
        captureCoordinator?.setAlignTickMode(active ? .wizard : .off)
        // The run opens on the search stage's slow beat; the session moves it
        // on when the estimator reaches its blocks.
        if active { captureCoordinator?.setWizardTempo(bpm: AlignmentTickInjector.wizardSearchBPM) }
        // A Bluetooth target's latency is the unknown the run measures, so the
        // reference goes wide open. Only RAISED here: the tick stops at the
        // receipt, and lowering it there would drop the result the user is
        // judging onto a timeline that clamps it. `endBTWizardRun()` owns the
        // way back down.
        if active, btTargetDeviceID != nil {
            stateQueue.async {
                guard !self.btWizardReferenceRaised else { return }
                self.btWizardReferenceRaised = true
                self.updateBTReferenceBufferLocked()
            }
        }
        // The arm gate: bed only until every participating sink is playing.
        let expected = stateQueue.sync { self.btSinkEnabled ? Set(self.btSelectedUIDs) : [] }
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            if active {
                self.beginWizardArmGate(expecting: expected)
            } else {
                self.cancelWizardArmGate()
            }
        }
        // BOTH edges re-anchor every FIFO sink. The wizard swaps the producer of
        // the shared feed, which breaks frame continuity for sinks that anchor
        // once and then run as FIFOs — and after any paused stretch (the case the
        // wizard exists for) their rings have drained anyway, so their idea of
        // where a pts lands is already untrustworthy. Re-anchoring is what makes
        // the measurement, and the playback that follows it, pts-true.
        // `wizard_feed` is deliberately NOT `config_change`: this IS a new
        // timeline context, so Part 3a's anchor carry must not engage.
        captureControlQueue.async { [weak self] in
            self?.syncedLocalSink?.requestReanchor(cause: "wizard_feed")
            self?.btSink?.reanchorAll(cause: "wizard_feed")
        }
    }

    /// Hold every selected Bluetooth speaker that is NOT part of the comparison
    /// silent for the run, and let them all back in when it ends.
    ///
    /// The reference is exempt only when it is itself a Bluetooth device — a
    /// Mac reference renders through a different sink entirely and is not in
    /// this set to begin with, so passing its id costs nothing. Applied through
    /// the ordinary composed-gain seam: no rebuild, no gap, and the wizard's
    /// arm gate (which keys off `hasStartedRendering`) is unaffected because a
    /// gain of 0 is still a released, rendering sink.
    private func updateBTWizardParticipantHold(
        active: Bool, targetUID: String?, referenceUID: String?
    ) {
        stateQueue.async {
            var want: Set<String> = []
            if active, let targetUID {
                want = Set(self.btSelectedUIDs)
                    .subtracting([targetUID, referenceUID].compactMap { $0 })
            }
            let changed = want.symmetricDifference(self.btWizardHeldUIDs)
            guard !changed.isEmpty else { return }
            self.btWizardHeldUIDs = want
            for uid in changed { self.pushBTSinkGainLocked(uid) }
        }
    }

    public func stageBTMicProbe(onStarted: @escaping () -> Void,
                                onFinished: @escaping () -> Void) {
        captureCoordinator?.stageWizardMicProbe(onStarted: onStarted, onFinished: onFinished)
    }

    public func endBTWizardRun() {
        // Belt and braces for the hold: the tick's `false` edge already dropped
        // it, but a run that ends is a run whose participants must all be
        // audible again, whatever route it took to get here.
        updateBTWizardParticipantHold(active: false, targetUID: nil, referenceUID: nil)
        btTrimLock.withLock {
            btWizardLastPreviewMsByUID.removeAll()
            btWizardTickBPM = nil
        }
        stateQueue.async {
            guard self.btWizardReferenceRaised else { return }
            self.btWizardReferenceRaised = false
            self.updateBTReferenceBufferLocked()
        }
    }

    public func resolveBTAlignmentPrompt(forDevice id: String, dismissed: Bool) {
        if dismissed {
            let all: Set<String> = btTrimLock.withLock {
                btAlignmentDismissedUIDs.insert(id)
                return btAlignmentDismissedUIDs
            }
            do { try btTrimStore?.saveDismissedUIDs(all) } catch { StoreRecovery.noteWriteFailure(error) }
            Telemetry.log(.localPlayback, "bt_alignment_prompt_dismissed", ["device": id])
        }
        stateQueue.async { self.releaseBTAlignmentHoldLocked(id) }
    }

    /// The sync drawer asks for this on its own open path, so it must not wait
    /// on `captureControlQueue` — a tap rebuild parked there runs for hundreds
    /// of milliseconds. Only the `btSink` REFERENCE is queue-confined state, so
    /// it is read under ``btSinkRefLock`` and the sink is then asked directly:
    /// the sink synchronizes its own tables, so the call is safe off-queue.
    /// The answer stays a LIVE query per the sink's contract — nothing is
    /// cached here, because the range moves the instant an AirPlay device joins
    /// or leaves the composition.
    public func btUsableTrimRangeMs(forDevice id: String) -> ClosedRange<Double> {
        let sink = btSinkRefLock.withLock { btSink }
        return sink?.usableTrimRangeMs(forDeviceUID: id) ?? (-BTSyncTrim.rangeMs...BTSyncTrim.rangeMs)
    }

    public func setBTWizardTickTempo(bpm: Double) {
        // Stashed as well as pushed: it is the one signal down here that says
        // which estimator stage a trial belongs to (`setBTWizardLatencyPreview`).
        btTrimLock.withLock { btWizardTickBPM = bpm }
        captureCoordinator?.setWizardTempo(bpm: bpm)
    }

    // MARK: Measured latency (roadmap 056 Part A)

    public func btMeasuredLatencyMs(forDevice id: String) -> Double? {
        btTrimLock.withLock { btLatencyMsByUID[id] }
    }

    public func btWizardLatencyRangeMs(forDevice id: String) -> ClosedRange<Double> {
        // Solve the sink's own delay formula (`reference − latency + trim`) for
        // the latencies a trial can actually be judged at. The run SUSPENDS the
        // trim to 0 for its whole duration, so the trim term is gone here too —
        // leaving it in both polluted the measurement (a candidate would be
        // judged at `L + trim`) and, for a trim more negative than the hardware
        // latency, collapsed the range onto 0 and bowed the run out as
        // `.unreachable`.
        //
        // The CEILING is the reference less one default BT-only buffer, not the
        // reference itself: at `latency == reference` the delay is 0, the ring
        // is seeked completely dry, and the speaker is silent for the rest of
        // the session with no way back. Leaving a buffer's worth of content
        // ahead of the read pointer is what keeps every reachable candidate
        // playable.
        //
        // The FLOOR is negative on purpose. A latency below 0 is not a physical
        // quantity and never gets persisted (`endBTWizardLatencyPreview` floors
        // it, as does the session's Keep) — but a run that cannot go below 0
        // dead-ends on the very first answer of a fresh speaker, whose base is
        // 0: "target first" means the latency must come DOWN, the candidate
        // clamps to the same 0, the identical question repeats, and two clicks
        // in the run bows out. The staircase has to be able to REVERSE out of a
        // wrong early answer, so the range gives it somewhere to go.
        let reference = stateQueue.sync { () -> Int in
            btComposition.usesPresentationReference
                ? _startBufferMs : Self.btWizardReferenceBufferMs
        }
        let lower = -BTSyncTrim.rangeMs
        let upper = Double(reference) - Double(BTSyncedSink.defaultBTOnlyBufferMs)
        return lower...Swift.max(lower, upper)
    }

    public func setBTWizardLatencyPreview(_ ms: Double, forDevice id: String,
                                          halfWidthMs: Double? = nil) {
        // NOT floored at 0: see `btWizardLatencyRangeMs` — the run needs to be
        // able to reverse below the base. Keep is where the floor belongs.
        let value = Int(ms.rounded())
        let (previous, bpm) = btTrimLock.withLock { () -> (Int?, Double?) in
            let previous = btWizardLastPreviewMsByUID[id]
            btWizardLastPreviewMsByUID[id] = value
            return (previous, btWizardTickBPM)
        }
        // One line per trial — the run's only record of what the user was
        // actually asked to judge. `captureControlQueue`/`stateQueue` callers
        // only; nothing here runs on the render or tap thread.
        var fields = [
            "uid": id,
            "candidateMs": String(value),
            "deltaMs": String(value - (previous ?? value)),
            // How wide the run is casting, read off the tempo it drives: an
            // uncertain run ticks far slower than one closing in.
            "stage": (bpm ?? BTAlignmentWizardSession.searchTickBPM)
                <= BTAlignmentWizardSession.searchTickBPM ? "search" : "blocks",
        ]
        // How sure the estimator was when it chose this level. Absent rather
        // than zero for a caller that has no posterior behind it.
        if let halfWidthMs { fields["halfWidthMs"] = String(format: "%.1f", halfWidthMs) }
        Telemetry.log(.localPlayback, "wizard_latency_preview", fields)
        captureControlQueue.async { [weak self] in
            self?.btSink?.setOffsetMs(value, forDeviceUID: id)
        }
    }

    public func endBTWizardLatencyPreview(forDevice id: String, keepMs: Double?) {
        if let keepMs {
            let value = Swift.max(0, keepMs.rounded())
            // Keep writes BOTH halves of the delay term. The trim goes to 0
            // because it was a manual stand-in for exactly the latency this run
            // has now measured — carrying it over would double the correction,
            // and the run was judged with it suspended anyway. The nudge starts
            // fresh from the measurement.
            let (latencies, trims): ([String: Double], [String: Double]) = btTrimLock.withLock {
                btLatencyMsByUID[id] = value
                btTrimsByUID[id] = 0
                return (btLatencyMsByUID, btTrimsByUID)
            }
            do {
                try btTrimStore?.saveLatencies(latencies)
                try btTrimStore?.save(trims)
            } catch {
                StoreRecovery.noteWriteFailure(error)
            }
            // The run's receipt, in one line: what was measured and what the
            // nudge was left at — the two halves of the delay term Keep writes,
            // so a live report never has to infer one from the other. UI-thread
            // call site (the popover's Keep), never the render or tap thread.
            Telemetry.log(.localPlayback, "wizard_keep", [
                "uid": id,
                "latencyMs": String(Int(value)),
                "trimMs": "0",
            ])
            // The reference floor is a function of the slowest known latency, so
            // a new measurement can move it — and it must move FIRST: pushing a
            // 640 ms latency against a 500 ms reference drives the delay onto
            // its ≥ 0 clamp for as long as the two disagree. Both hops are
            // enqueued from `stateQueue`, so `captureControlQueue` runs them in
            // that order rather than whichever thread got there first. The
            // reference itself comes back down only at ``endBTWizardRun()``,
            // one hop later, with this measurement already in the table.
            stateQueue.async {
                self.updateBTReferenceBufferLocked()
                self.captureControlQueue.async { [weak self] in
                    self?.btSink?.setOffsetMs(Int(value), forDeviceUID: id)
                    self?.btSink?.setTrimMs(0, forDeviceUID: id)
                }
            }
        } else {
            let stored = Int((btMeasuredLatencyMs(forDevice: id) ?? 0).rounded())
            captureControlQueue.async { [weak self] in
                self?.btSink?.setOffsetMs(stored, forDeviceUID: id)
            }
        }
    }

    // MARK: The wizard's first-tick ARM gate (roadmap 056 Part B)

    /// Start polling for "everyone is playing". Ticks stay off until every
    /// participating sink has opened its delay gate — or the ceiling expires —
    /// so the FIRST audible tick is a true pair on every speaker instead of the
    /// Mac ticking alone while a Bluetooth engine is still coming up (the
    /// engine needs longer than the old fixed 3 s preamble allowed for).
    /// `captureControlQueue`.
    private func beginWizardArmGate(expecting uids: Set<String>) {   // captureControlQueue
        cancelWizardArmGate()
        scheduleWizardArmPoll(started: Date(), expecting: uids)
    }

    /// `captureControlQueue`. Idempotent.
    private func cancelWizardArmGate() {   // captureControlQueue
        wizardArmPollWork?.cancel()
        wizardArmPollWork = nil
    }

    private func scheduleWizardArmPoll(started: Date, expecting uids: Set<String>) {
        let work = DispatchWorkItem { [weak self] in
            self?.pollWizardArmGate(started: started, expecting: uids)
        }
        wizardArmPollWork = work
        captureControlQueue.asyncAfter(
            deadline: .now() + wizardArmPollInterval, execute: work)
    }

    /// One arm-gate poll. `captureControlQueue`, which owns both sinks — and is
    /// not a render or tap thread, so the one telemetry line at the end is
    /// emitted where it belongs.
    private func pollWizardArmGate(started: Date, expecting uids: Set<String>) {
        wizardArmPollWork = nil
        let waited = Date().timeIntervalSince(started)
        let rendering = btSink?.renderingDeviceUIDs() ?? []
        // `true` when there is no local sink at all: nothing to wait for.
        let localReleased = syncedLocalSink?.hasStartedRendering ?? true
        let everyoneReleased = uids.isSubset(of: rendering) && localReleased
        // A minimum stretch of bed regardless (the Sonos Move power-gates its
        // amplifier and swallows the first transients after silence), and a
        // ceiling so a speaker that never releases cannot stall the run.
        let ready = everyoneReleased && waited >= wizardArmMinimumBedSeconds
        guard ready || waited >= wizardArmCeilingSeconds else {
            scheduleWizardArmPoll(started: started, expecting: uids)
            return
        }
        captureCoordinator?.armWizardTicks()
        Telemetry.log(.localPlayback, "wizard_ticks_armed", [
            "waitedMs": String(Int((waited * 1_000).rounded())),
            "released": rendering.sorted().joined(separator: " "),
            "localReleased": localReleased ? "1" : "0",
            "timedOut": ready ? "0" : "1",
        ])
    }
}

/// Optional backend capability for the Mac's OWN device row (roadmap 056 Part
/// 1) — same `backend as? Capability` posture as ``BTOutputControlling``, and
/// `NativeBackend` is again the only conformer. The stored value stays in
/// ``AppSettings/syncOffsetMs`` (one local device — a migration into
/// `BTTrimStore` would buy nothing); this seam is only the LIVE APPLY.
public protocol LocalSyncOffsetControlling: AnyObject {
    /// ``AppSettings/syncOffsetMs`` was just written — bring the running local
    /// sink onto the new value.
    func noteLocalSyncOffsetChanged()
    /// Push a CANDIDATE offset to the live sink without storing it — the
    /// wizard's per-trial preview, the local twin of
    /// ``BTOutputControlling/setBTWizardTrimPreview(_:forDevice:)``.
    func setLocalTrimPreview(_ ms: Double)
    /// End a preview: `keepMs` non-nil writes it to ``AppSettings``; `nil`
    /// drops the override and puts the stored value back on the sink.
    func endLocalTrimPreview(keepMs: Double?)
}

extension NativeBackend: LocalSyncOffsetControlling {

    /// The offset the local sink should be running at right now: a live wizard
    /// preview if one is in flight, else the stored setting. Read on the sink's
    /// own anchor/rebuild path, so it takes a plain lock rather than a queue hop.
    public func currentLocalSyncOffsetMs() -> Int {
        if let preview = localTrimPreviewLock.withLock({ localTrimPreviewMs }) {
            return Int(BTSyncTrim.clamp(preview).rounded())
        }
        return AppSettings().syncOffsetMs
    }

    public func noteLocalSyncOffsetChanged() {
        applyLocalSyncOffsetLive()
    }

    public func setLocalTrimPreview(_ ms: Double) {
        localTrimPreviewLock.withLock { localTrimPreviewMs = BTSyncTrim.clamp(ms) }
        applyLocalSyncOffsetLive()
    }

    public func endLocalTrimPreview(keepMs: Double?) {
        if let keepMs {
            AppSettings().syncOffsetMs = Int(BTSyncTrim.quantise(keepMs))
        }
        localTrimPreviewLock.withLock { localTrimPreviewMs = nil }
        applyLocalSyncOffsetLive()
    }

    /// Move the running local sink onto the current effective offset by handing
    /// it the DELTA since the last one applied — a read-pointer seek in the
    /// sink's delay line, which lands while the music plays. No debounce: a seek
    /// is cheap, so the drawer's 60 ms stepper hold-repeat can have one each and
    /// the control feels live under the finger.
    ///
    /// razor: the Mac's trim now costs a seek, not a session — the one remaining
    /// rebuild is the sink's own fallback when the move is bigger than the ring
    /// can replay (``SyncedLocalSink/applyUserOffsetDelta(ms:)``), which ±500 ms
    /// against a multi-second ring never reaches in practice. Upgrade path if it
    /// ever does: a bigger ring, not a re-anchor.
    private func applyLocalSyncOffsetLive() {
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            // Read ON the queue, so the delta and the apply are one serialized
            // step: a burst of stepper repeats can never land out of order or
            // double-count a value.
            let effective = Double(self.currentLocalSyncOffsetMs())
            let delta = effective - self.lastAppliedLocalOffsetMs
            self.lastAppliedLocalOffsetMs = effective
            guard delta != 0 else { return }
            self.syncedLocalSink?.applyUserOffsetDelta(ms: delta)
        }
    }
}

/// Optional backend capability for a CAST row's SYNC control (CAST-SYNC) —
/// same `backend as? Capability` posture as ``BTOutputControlling``, and
/// `NativeBackend` is again the only conformer.
///
/// The value is the user's BY-EAR offset, in whole milliseconds, ±
/// ``BTSyncTrim/castRangeMs``. It is NOT the receiver's buffer: that is
/// measured on the wire and taken out automatically. This covers only what the
/// protocol cannot see — the receiver's output stage, its DAC, and, when the
/// target is a TV, the HDMI → TV → soundbar chain behind it.
public protocol CastSyncOffsetControlling: AnyObject {
    /// The stored offset for a receiver (0 when none).
    func castUserOffsetMs(forDevice id: String) -> Double
    /// Whether this receiver has an ENTRY at all — the honest answer to "tuned
    /// or never tuned?", which the value alone cannot give: a receiver
    /// deliberately set to 0 ms is tuned, and must not read "Not set".
    func castHasUserOffset(forDevice id: String) -> Bool
    /// Store an offset and apply it to the live Cast feed.
    func setCastUserOffsetMs(_ ms: Double, forDevice id: String)
    /// Delete the stored offset and put the live feed back on no correction.
    /// REMOVED, never written as 0: ``castHasUserOffset(forDevice:)`` answers
    /// by existence, so a stored 0 would leave the row reading "0 ms".
    func clearCastUserOffset(forDevice id: String)
}

extension NativeBackend: CastSyncOffsetControlling {

    public func castUserOffsetMs(forDevice id: String) -> Double {
        castOffsetLock.withLock { castOffsetsByID[id] ?? 0 }
    }

    public func castHasUserOffset(forDevice id: String) -> Bool {
        castOffsetLock.withLock { castOffsetsByID[id] != nil }
    }

    public func setCastUserOffsetMs(_ ms: Double, forDevice id: String) {
        let value = BTSyncTrim.quantise(ms, rangeMs: BTSyncTrim.castRangeMs)
        let all: [String: Double] = castOffsetLock.withLock {
            castOffsetsByID[id] = value
            return castOffsetsByID
        }
        do { try castOffsetStore?.save(all) } catch { StoreRecovery.noteWriteFailure(error) }
        pushCastUserOffset(value, forDevice: id)
    }

    public func clearCastUserOffset(forDevice id: String) {
        let all: [String: Double] = castOffsetLock.withLock {
            castOffsetsByID.removeValue(forKey: id)
            return castOffsetsByID
        }
        do { try castOffsetStore?.save(all) } catch { StoreRecovery.noteWriteFailure(error) }
        pushCastUserOffset(0, forDevice: id)
    }

    /// The one write onto the live feed. The session manager owns the per-device
    /// delay line and applies `max(0, roomDelay + userOffset)`, so this term is
    /// stored beside the controller's automatic one rather than competing with
    /// it — writing the offset never disturbs the room delay, and vice versa.
    /// An id with no session is ignored there (the `setLevel` posture), which is
    /// why an unarmed receiver needs no guard here and picks its value up from
    /// the arm instead.
    private func pushCastUserOffset(_ ms: Double, forDevice id: String) {
        castOutputManager?.setCastUserOffsetMs(Int(ms), forDeviceID: id)
    }

    /// Re-push every armed receiver's stored offset — the Cast twin of the
    /// Bluetooth sinks' arm-time trim replay, so a receiver the user reselects
    /// comes back carrying the offset it was tuned to rather than none.
    func pushStoredCastUserOffsets(forDeviceIDs ids: [String]) {
        let stored = castOffsetLock.withLock { castOffsetsByID }
        for id in ids {
            pushCastUserOffset(stored[id] ?? 0, forDevice: id)
        }
    }
}

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

    /// Level this sink's output by `group × the Mac's own fader` (W1). Main is
    /// deliberately excluded — see ``NativeBackend``'s `pushSyncedLocalGain`.
    func setGain(_ gain: Float)

    /// Wave-4 delay agreement: the reference timeline moved (AirPlay joined or
    /// left a BT-containing selection) — rebuild so the fresh session anchor
    /// re-samples the delay provider. Default no-op (spies).
    func requestReanchor(cause: String)

    /// Roadmap 056 Part 1: the user's sync offset moved by `deltaMs` (positive =
    /// the Mac plays later) — land it on the LIVE session, no rebuild. Same
    /// default-no-op posture as `requestReanchor`.
    func applyUserOffsetDelta(ms deltaMs: Double)

    /// Whether this sink's delay gate has opened — the Mac's half of the
    /// wizard's arm gate, the twin of ``BTSyncedSink/renderingDeviceUIDs()``.
    var hasStartedRendering: Bool { get }
}

extension SyncedLocalSinkControlling {
    /// Default no-op — only the real ``SyncedLocalSink`` re-anchors.
    public func requestReanchor(cause: String) {}

    /// Default no-op — only the real ``SyncedLocalSink`` has a delay line to seek.
    public func applyUserOffsetDelta(ms deltaMs: Double) {}

    /// Default "can't tell", read as nothing-to-wait-for — a lifecycle-only spy
    /// must never hold the wizard's arm gate open to its ceiling.
    public var hasStartedRendering: Bool { true }

    /// Default no-op so a spy that only exercises the enable/disable lifecycle
    /// compiles unchanged; ``SyncedLocalSink`` provides the real one. (Same posture
    /// as ``CaptureControlling``'s defaults above.)
    public func setGain(_ gain: Float) {}
}

extension SyncedLocalSink: SyncedLocalSinkControlling {}

/// The lifecycle surface BT-BACKEND drives on the Bluetooth sink manager: the
/// fan-out feed itself (``SyncedLocalPCMSink``) plus arm/disarm, the selected
/// per-device set, and the group composition (BT-REFSEL). Lets ``NativeBackend``
/// own WHEN Bluetooth playback turns on/off against either the real
/// ``BTSyncedSink`` or a test spy — the exact posture of
/// ``SyncedLocalSinkControlling`` above. Internal on purpose: nothing outside
/// this module constructs one (`makeBackend` wires production; tests are
/// `@testable`).
protocol BTSyncedSinkControlling: SyncedLocalPCMSink {
    func start()
    func stop()
    func setDevices(_ specs: [BTSyncedSink.DeviceSpec])
    func setComposition(_ composition: BTGroupComposition)
    /// The UIDs whose per-device sink is emitting real audio right now — the
    /// signal a Bluetooth row's `.connecting` hold ends on.
    func renderingDeviceUIDs() -> Set<String>
    /// The UIDs handed any captured audio at all — how the hold's ceiling tells
    /// a silent Mac (idle, promote to `.connected`) from a device that got
    /// audio and never played it (a real failure). `nil` means "can't tell",
    /// which the caller reads as anchored: lifecycle-only spies then keep the
    /// old fail-on-ceiling behaviour and their expectations are unchanged.
    func anchoredDeviceUIDs() -> Set<String>?
    /// Per-device signed manual trim (BT-OFFSET-UI/BT-SYNC-DRAWER). Default
    /// no-op so lifecycle-only spies compile unchanged; ``BTSyncedSink``
    /// provides the real one (same-value writes are already guarded there).
    func setTrimMs(_ ms: Double, forDeviceUID uid: String)
    /// The usable trim range for a device (D11/T3) — see
    /// ``BTSyncedSink/usableTrimRangeMs(forDeviceUID:)``. Default returns the
    /// full ±`BTSyncTrim.rangeMs` so lifecycle-only spies compile unchanged;
    /// ``BTSyncedSink`` provides the live one. Unlike the rest of this
    /// protocol, this may be called off `captureControlQueue`, so an
    /// implementation must be internally synchronized (the real sink is).
    func usableTrimRangeMs(forDeviceUID uid: String) -> ClosedRange<Double>
    /// Per-device render gain: the backend's composed
    /// `Main × Group × Device` product, 0 while muted or first-mix-held (W3).
    /// Same default-no-op posture as `setTrimMs`.
    func setGain(_ gain: Float, forDeviceUID uid: String)
    /// Rebuild every live sink under `cause`, so the next captured buffer
    /// re-anchors it. The wizard's feed handoff is the only caller. Same
    /// default-no-op posture as `setTrimMs`.
    func reanchorAll(cause: String)
    /// Per-device MEASURED output latency (roadmap 056 Part A) — see
    /// ``BTSyncedSink/setOffsetMs(_:forDeviceUID:)``. Same default-no-op
    /// posture as `setTrimMs`.
    func setOffsetMs(_ ms: Int, forDeviceUID uid: String)
    /// Move the BT-only reference timeline — see
    /// ``BTSyncedSink/setBTOnlyBufferMs(_:)``. Same posture again.
    func setBTOnlyBufferMs(_ ms: Int)
    /// Per-device tone. A property swap on the running session — never a
    /// rebuild. Same default-no-op posture as `setTrimMs`.
    func setEQ(_ eq: DeviceEQ, forDeviceUID uid: String)
}

extension BTSyncedSinkControlling {
    func anchoredDeviceUIDs() -> Set<String>? { nil }
    func setTrimMs(_ ms: Double, forDeviceUID uid: String) {}
    func reanchorAll(cause: String) {}
    func setOffsetMs(_ ms: Int, forDeviceUID uid: String) {}
    func setBTOnlyBufferMs(_ ms: Int) {}
    func usableTrimRangeMs(forDeviceUID uid: String) -> ClosedRange<Double> {
        -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs
    }
    func setGain(_ gain: Float, forDeviceUID uid: String) {}
    func setEQ(_ eq: DeviceEQ, forDeviceUID uid: String) {}
}

extension BTSyncedSink: BTSyncedSinkControlling {}
