import Foundation
import AudioToolbox
import AirPlayEngine
import CastSender

/// The native ``OutputBackend`` (T-NB-BACKEND-1): the app-visible seam that
/// drives the extracted, in-process ``AirPlayEngine`` (an AirPlay-2 sender) plus
/// an app-owned ``NativeDiscovery`` (`NWBrowser` over `_airplay._tcp` /
/// `_raop._tcp`). It presents the same `BackendEvent`-driven contract every
/// ``OutputBackend`` does — the UI never learns which backend it's talking to.
///
/// State ownership: a `known`/`order` map confined to a serial `stateQueue`,
/// which is what makes `@unchecked Sendable` honest here. Mute is a shim — it
/// stores the current level and writes 0, and unmute writes the stored level
/// back. There is no poll loop and no zombie detection: an in-process engine's
/// completions ARE ground truth.
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

public final class NativeBackend: OutputBackend, LatencyConfigurable, MeteringControlling, AppRouteConfiguring, @unchecked Sendable {

    // MARK: Injected dependencies (protocols so tests are hermetic)

    let engine: EngineControlling
    let discovery: DiscoverySource

    /// Bluetooth audio-output enumeration (BT-ENUM): Core Audio BT transport
    /// merged with the IOBluetooth paired list, surfacing `.bluetooth` rows the
    /// same way discovery surfaces AirPlay rows. `nil` (the designated init's
    /// default, so every existing test stays BT-free) means no BT enumeration;
    /// the production convenience init wires the real ``BTDeviceEnumerator``.
    /// BT devices never get an `outputIDs` entry and are never fed to the
    /// engine — structurally unroutable until BT-BACKEND partitions the output
    /// set (plan risk R-partition).
    let btEnumerator: BTDeviceEnumerating?
    /// Wired Core Audio outputs as `.wired` rows; `nil` (the designated init's default) means none.
    let wiredEnumerator: WiredOutputEnumerating?
    /// BT-CONNECT: IOBluetooth connect/disconnect for paired BT speakers.
    /// `nil` under most tests (like `btEnumerator`), which keeps every BT
    /// reconnect path inert unless a fake is injected.
    let btConnectionManager: BTConnectionManaging?

    /// Cast discovery (CAST-ENUM): `_googlecast._tcp` browse surfacing `.cast`
    /// rows through the same `known`/`order`/`emit` flow BT rows use. `nil` (the
    /// designated init's default, so every existing test stays Cast-free) means
    /// no Cast enumeration; the production convenience init wires the real one.
    private let castEnumerator: CastDeviceEnumerating?
    /// CAST-OUT: the per-receiver session manager the selection arm drives.
    /// `nil` under most tests, which keeps every Cast path inert unless a fake
    /// is injected. Cast ids are the THIRD routing partition — never an
    /// `outputIDs` entry, never fed to the engine.
    let castOutputManager: CastOutputControlling?

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
    var systemVolume: SystemVolumeControlling

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
    /// The backend owns the coordinator's lifecycle, the coordinator owns capture.
    /// Metering rides along — the native coordinator computes RMS on the captured
    /// buffer (upstream of the engine, per playback-meter-research.md) and
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
    var syncedLocalSink: SyncedLocalSinkControlling?

    /// Whether "play everywhere" is currently enabled — the last DESIRED decision
    /// made by `setOutputSet`'s synced-local-sink reconciliation. Confined to
    /// `stateQueue` like every other selection-derived flag (`captureRunning`,
    /// `expectedSelected`); the actual attach/start/stop work it triggers runs
    /// on `captureControlQueue`, and only after the T1 settle below fires — so
    /// this flag can be AHEAD of `syncedLocalSinkApplied` during a debounce window.
    var syncedLocalSinkEnabled = false

    // MARK: Synced-local settle debounce (T1/T2)
    //
    // Every Mac select/deselect used to call `applySyncedLocalSinkTransition`
    // directly. On today's main a sink attach no longer rebuilds the whole-system
    // tap (`setSyncedLocalSink` compares exclusion objects before rebuilding), but
    // each applied transition still starts or stops the sink and re-fires its
    // session anchor, and rapid toggling still left the AirPlay receiver desynced
    // and silent while Mac-side capture reported healthy. The fix coalesces a
    // burst into AT MOST ONE real transition on the trailing edge of a quiet
    // window, and re-establishes the receiver session exactly once if the burst
    // actually churned. A normal single toggle collapses to exactly one coalesced
    // decision and NEVER pays that re-sync: reintroducing a redundant RTP
    // re-establish on every ordinary connect is the exact bug a prior fix removed
    // (`dev/notes/synced-local-mixed-selection-dropout-fix.md`).
    //
    // Churn is detected TWO independent ways, because a debounce window must never
    // be the only protection:
    //   1. COALESCED, cadence-dependent: two or more toggle decisions absorbed into
    //      one settle window. Only catches clicking faster than the window.
    //   2. APPLIED-TRANSITION HORIZON, cadence-independent: two or more transitions
    //      this backend actually ran inside a rolling horizon. Catches a cadence
    //      slower than the window but faster than the horizon, where every click
    //      gets its own settle and detector 1 always reads exactly 1.

    /// What the last EXECUTED synced-local transition actually set — the applied
    /// state, distinct from the desired `syncedLocalSinkEnabled` above. The T1
    /// settle only runs a real transition when `desired != applied`, so a burst
    /// that collapses back to its starting point is a true no-op. On `stateQueue`.
    var syncedLocalSinkApplied = false

    /// The pending trailing-edge settle; a newer toggle cancels + reschedules it,
    /// so a burst fires only once, one settle window after the LAST toggle. On
    /// `stateQueue`.
    var pendingSyncedLocalSettle: DispatchWorkItem?

    /// How many distinct synced-local toggle DECISIONS have coalesced into the
    /// currently-pending settle. `>= 2` when the settle fires means genuine churn
    /// (rapid clicking) and arms the one-shot T2 RTP re-sync; exactly `1` is a
    /// normal single toggle and must never trigger it by itself (the horizon below
    /// is the other, cadence-independent arming path). Reset to 0 on each fire.
    /// On `stateQueue`.
    var syncedLocalCoalescedCount = 0

    /// Trailing-edge quiet window for coalescing synced-local toggles. A single
    /// toggle still fires after just this delay (an accepted tradeoff — kept
    /// simple, trailing-edge only, no leading-edge fast path). Injectable only
    /// through the designated initializer (same seam shape as
    /// `rebindRecoveryRetryDelay`) so tests can shrink it; production always gets
    /// the default. The default moved from 0.25 s to 0.5 s because 250 ms sits
    /// under a comfortable sustained click cadence (about 3 per second, about
    /// 330 ms apart), so every click used to land in its own window.
    let syncedLocalSettleWindow: TimeInterval

    /// Monotonic `DispatchTime.now().uptimeNanoseconds` stamps of the synced-local
    /// transitions this backend really applied: appended only past
    /// `fireSyncedLocalSettle`'s desired-versus-applied guard, never per toggle
    /// decision, pruned to `syncedLocalTransitionHorizon` on each append, cleared
    /// by `stop()`. On `stateQueue`.
    var syncedLocalTransitionTimes: [UInt64] = []

    /// Rolling horizon over which two or more real applied transitions count as
    /// churn, arming the one-shot re-sync no matter how the clicks were spaced.
    /// 2 s: its floor is the settle window (a cadence just outside the window
    /// would otherwise slip through the same hole), its ceiling is deliberate
    /// reconsideration, and each transition already trails its click by the
    /// window, so a 2 s gap between transitions is a 2 s gap between clicks.
    /// Injectable through the designated initializer like the window.
    let syncedLocalTransitionHorizon: TimeInterval

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
    var btSink: BTSyncedSinkControlling?

    /// Guards the ``btSink`` REFERENCE only (never the sink's own state — the
    /// sink is internally synchronized).
    let btSinkRefLock = NSLock()

    /// One per-app mixed stream's Bluetooth delivery: the speakers it feeds, the
    /// S16LE→Float bridge's resampler (streaming filter state, hence one per
    /// stream and never shared), and whether that same stream still has an
    /// engine-bound device, i.e. whether the AirPlay write stays.
    ///
    /// The manager is resolved per buffer rather than captured: the map is built
    /// on `stateQueue`, and the manager may not exist until the transition that
    /// build enqueues has run on `captureControlQueue`.
    ///
    /// razor: one adapter per stream, existing only because the sink manager
    /// takes Float frames; it goes away if ``BTSyncedSink`` ever accepts S16LE.
    final class BTPerAppStreamFeed: SyncedLocalPCMSink, @unchecked Sendable {
        let uids: [String]
        let feedsEngine: Bool
        let renderSampleRate: Double
        let resampler: SyncedLocalBaseResampler
        let manager: @Sendable () -> BTSyncedSinkControlling?

        init(uids: [String], feedsEngine: Bool, renderSampleRate: Double,
             manager: @escaping @Sendable () -> BTSyncedSinkControlling?) {
            self.uids = uids
            self.feedsEngine = feedsEngine
            self.renderSampleRate = renderSampleRate
            self.resampler = SyncedLocalBaseResampler(
                inputRate: Double(PCMFormat.airplay.sampleRate),
                outputRate: renderSampleRate,
                channelCount: PCMFormat.airplay.channels)
            self.manager = manager
        }

        func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {
            manager()?.enqueue(interleavedFrames: interleavedFrames, frameCount: frameCount,
                               pts: pts, forDeviceUIDs: uids)
        }
    }

    /// Where each per-app mixed stream is delivered, keyed by `streamID`.
    /// Rebuilt whole by ``rebuildBTPerAppFeedsLocked(_:)`` and read on the
    /// mixer's delivery thread, so it takes its own leaf lock rather than
    /// `stateQueue` (the same posture as ``btSinkRefLock`` above). A stream with
    /// no Bluetooth destination has NO entry, which is what leaves the
    /// AirPlay-only path exactly as it was.
    var btPerAppFeeds: [Int: BTPerAppStreamFeed] = [:]
    let btPerAppFeedsLock = NSLock()

    // MARK: Bluetooth connect lifecycle (BT-LIFECYCLE)

    /// Every BT id currently held at `.connecting`, with the instant its hold
    /// expires. An entry exists ONLY while the row is breathing; the promotion
    /// to `.connected` (or the degrade to `.failed`) removes it. On `stateQueue`.
    var btConnectingDeadlines: [String: Date] = [:]

    /// The armed poll that asks the sink manager which devices have started
    /// rendering. `nil` = nothing is breathing, so nothing is scheduled — the
    /// poll exists only for the duration of a connect. On `stateQueue`.
    var btRenderPollWork: DispatchWorkItem?

    /// How often the hold re-asks. Fast enough that the dot lands with the
    /// first note rather than after it.
    static let btRenderPollInterval: TimeInterval = 0.1

    /// Ceiling on the `.connecting` hold: engine start + the first captured
    /// buffer + the reference delay (at most the AirPlay presentation delay).
    /// Past it the row reads `.failed` — a spinner that never resolves is the
    /// one outcome a connection indicator may never produce. Settable so tests
    /// don't sleep through the real ceiling.
    var btRenderStartTimeout: TimeInterval = 6

    // MARK: Bluetooth per-device sync trim (BT-OFFSET-UI)

    /// Persistence for the per-device SYNC trims. `nil` (most tests) = trims
    /// live for the session only.
    let btTrimStore: BTTrimStore?
    /// Guards ``btTrimsByUID`` alone — read from the UI thread
    /// (``btSyncTrim(forDevice:)``), written by ``setBTSyncTrim(_:forDevice:)``,
    /// and snapshotted by `captureControlQueue` when a sink is (re)armed; a
    /// dedicated lock keeps those reads off `stateQueue` entirely.
    let btTrimLock = NSLock()
    var btTrimsByUID: [String: Double] = [:]   // btTrimLock

    // MARK: Cast per-device by-ear offset (CAST-SYNC)

    /// Persistence for the per-receiver Cast offsets — its own file beside the
    /// Bluetooth trims'. `nil` (most tests) = offsets live for the session only.
    let castOffsetStore: BTTrimStore?
    /// Guards ``castOffsetsByID`` alone, for the same reason ``btTrimLock``
    /// guards its own map: the UI reads it, and `captureControlQueue` reads it
    /// again when a receiver is armed.
    let castOffsetLock = NSLock()
    var castOffsetsByID: [String: Double] = [:]   // castOffsetLock
    /// Each Bluetooth device's MEASURED output latency in ms (roadmap 056 Part
    /// A) — how late the speaker plays on its own, which is what the alignment
    /// wizard now determines. Distinct from the trim: the latency is a
    /// measurement of the hardware, the trim is the user's nudge on top, and
    /// the wizard never rewrites the latter. Same lock, same read/write
    /// pattern, and persisted in the same file's second map.
    var btLatencyMsByUID: [String: Double] = [:]   // btTrimLock
    /// A small counting number per Bluetooth device UID, handed out in order
    /// of first sighting. It is what the release analytics event names a
    /// speaker by: the UID is derived from the MAC address, and the address
    /// space is small enough that even a hash of one is reversible by
    /// enumeration, while an index carries nothing but the order this install
    /// met its speakers in. Same lock and same file as the maps above, its own
    /// third map.
    var btSpeakerIndexByUID: [String: Int] = [:]   // btTrimLock

    // MARK: Bluetooth hardware volume (BT-HW-VOL)

    /// Persistence for the per-device "Control speaker volume" opt-out.
    /// Public because the Groups detail pane owns the toggle and must share
    /// this instance. `nil` (most tests) = every uid reads as enabled.
    public let btHardwareVolumeStore: BTHardwareVolumeStore?
    /// HAL access to a BT speaker's own volume. `nil` (most tests) keeps the
    /// whole BT-HW-VOL path inert: no uid ever enters hardware control.
    let btHardwareVolumeControl: BTHardwareVolumeControlling?
    /// Reads a speaker's cached AVRCP SDP record for the category-2
    /// (absolute-volume) claim — see ``BTAbsoluteVolumeSDP``. `nil` result
    /// (no grant, no record) is NOT a denial: the gate then falls back to the
    /// settable-only check alone, same as before this claim existed.
    let btAbsoluteVolumeClaim: (@Sendable (String) -> Bool?)?
    /// Definitive (`true`/`false`) SDP verdicts, cached for the process
    /// lifetime once a probe returns one. On `stateQueue`.
    var btSDPClaimByUID: [String: Bool] = [:]
    /// UIDs already probed within the current link session, so a `nil`
    /// verdict (no cached record yet) isn't re-queried on every reevaluation;
    /// cleared on disconnect so the next connect retries. On `stateQueue`.
    var btSDPProbedUIDs: Set<String> = []
    /// Runs the SDP claim off `stateQueue` — IOBluetooth may block — and off
    /// `btHardwareWriteQueue`, which is a different, unrelated HAL path.
    let btSDPQueue = DispatchQueue(label: "com.audiout.Audiout.bt-sdp")
    /// UIDs whose per-device slider currently writes hardware volume:
    /// connected, toggle enabled, property settable, no failed write this
    /// session. Their device term leaves ``btSinkGain(forUID:)``'s software
    /// product — the speaker itself holds it. On `stateQueue`.
    var btHardwareControlledUIDs: Set<String> = []
    /// UIDs whose hardware write failed once — advertised-but-not-delivered
    /// (the PLAN-AIRPLAY-COEXISTENCE.md `vmvc` trap). Software gain carries
    /// them for the rest of the session. On `stateQueue`.
    var btHardwareFailedUIDs: Set<String> = []
    /// HAL volume writes leave `stateQueue` the same way the local row's
    /// system-volume writes do: a synchronous HAL set under the state lock
    /// would let a slow coreaudiod stall every backend mutation.
    let btHardwareWriteQueue = DispatchQueue(label: "com.audiout.Audiout.bt-hw-volume")

    // MARK: Companion sync-calibration run (phone-driven)

    /// What the Mac publishes about each Bluetooth speaker's timing — fed the
    /// baseband connect edges from ``finishBTReconnect(id:outcome:)`` and the
    /// alignment instants from the companion apply/commit paths below. Its own
    /// lock; see ``BTSpeakerTiming``.
    ///
    /// `var` for one reason, and assigned exactly once: its store read is a
    /// closure back onto this object, and Swift will not let an initializer
    /// capture `self` until every stored property already has a value. The
    /// placeholder below is replaced at the end of `init` and reports no
    /// stored offset for anything, which is what a backend mid-init knows.
    public private(set) var btSpeakerTiming = BTSpeakerTiming(storedOffsetMs: { _ in nil })

    // MARK: Passive drift tracking (roadmap 085 ticket 05)

    /// The mic-side tracker and the correction applier, or `nil` wherever
    /// nothing wired them — every test, and every UI-only build. Assigned once
    /// by ``attachPassiveDriftTracking(ring:)`` before ``start()``, the same
    /// discipline `captureCoordinator` and the sink factories keep, because the
    /// correlation reference is the capture coordinator's own ring and only the
    /// place that builds the coordinator can hand it over.
    var driftTracker: PassiveDriftTracker?
    /// Readable (not settable) from outside so a test can hand one window's
    /// observations straight to the applier that is really wired to this
    /// backend — the only way to reach ``writeBTDriftLatency(_:forDevice:persist:)``.
    var driftApplier: DriftCorrectionApplier?

    /// The one companion sync-calibration run or fine-tune session in flight,
    /// if any. One at a time by decision — both engage the wizard feed, which
    /// has a single producer, and a second run would replace the first's
    /// staging under it. `btTrimLock`.
    var companionAlignmentRun: CompanionAlignmentRun?
    /// Nil outside an audition; otherwise only these two outputs keep their gain.
    /// All reads and writes are on stateQueue.
    var companionTickParticipants: Set<String>?
    /// Audio callbacks take only btTrimLock for this snapshot, never stateQueue.
    var companionProgramSuppressed = false
    enum CompanionAuditionPhase { case preparing, active, cleaning }
    /// What the engine actually CONFIRMED for one restoration output, and
    /// whether that write succeeded. A push answered `false` because a newer
    /// write superseded it never lands here: it is not this value completing.
    struct CompanionRestoreCompletion { let value: Double; let ok: Bool }
    struct CompanionAuditionLifecycle {
        let id: UUID
        let targetID: String
        let referenceID: String
        let preparationDeadline: Date
        let leaseDeadline: Date
        var phase: CompanionAuditionPhase = .preparing
        var startCompletions: [@Sendable (String?) -> Void]
        var stopCompletions: [@Sendable (String?) -> Void] = []
        /// Every hold this preparation issued and is still waiting on: engine
        /// outputs, the local setter, and each Bluetooth and Cast sink write.
        /// A key is removed ONCE, so a repeat acknowledgement can never stand
        /// in for a hold that has not answered.
        var preparationPending: Set<String> = []
        /// The first output whose hold failed, recorded in the same lock turn
        /// that moves the phase to `.cleaning` — so a success landing after it
        /// cannot start clicks.
        var preparationFailure: String?
        /// `beginCompanionAuditionCleanup` runs exactly once. Separate from
        /// `phase` because a failed preparation marks `.cleaning` under the
        /// lock before the cleanup itself can be scheduled.
        var cleanupStarted = false
        /// The audition's ONE persistence of the by-ear nudge. The ordinary
        /// drain and backend `stop()` race to claim it; only the winner writes,
        /// and a phone Clear claims it to stop either of them writing at all.
        var trimPersistenceClaimed = false
        var cleanupPrepared = false
        var localRestored = false
        var restoreOutputs: [OutputID: String] = [:]
        var restoreCompleted: [OutputID: CompanionRestoreCompletion] = [:]
        /// Fired ONCE per start request, on main, after the reservation is
        /// actually gone. Independent of the one-shot start/stop replies: a
        /// stop that refuses on its four-second timeout does not consume it.
        var releaseCallbacks: [@Sendable () -> Void] = []
        var cleanupDeadline: Date?
    }
    /// The .tick run remains reserved during preparation and restoration.
    var companionAudition: CompanionAuditionLifecycle?
    var companionAuditionPreparationSeconds: TimeInterval = 4
    var companionAuditionLeaseSeconds: TimeInterval = 600
    var companionAuditionStopSeconds: TimeInterval = 4

    /// The device an A/B receipt is playing for, if one is. Its own field
    /// rather than another ``CompanionAlignmentRun/Phase``: a receipt takes no
    /// measurement and holds no trim state, it just plays for four seconds and
    /// puts the room back. It is keyed by DEVICE so a stand-down aimed at some
    /// other speaker cannot end it and strand this one at the receipt's
    /// half-way value. `btTrimLock`.
    var companionDemoTargetUID: String?

    /// The applied latency a target carried BEFORE the companion run's
    /// measurement landed, per UID — the "before" half of the A/B demo
    /// Session-only: a demo is a receipt for a measurement the
    /// user just took, not something to offer a launch later. `btTrimLock`.
    var companionPreMeasurementLatencyMsByUID: [String: Double] = [:]

    // MARK: Tone (per-device + Main Out EQ)

    /// Persistence for the tone settings. `nil` (most tests) = session-only.
    let eqStore: DeviceEQStore?
    /// Every device's tone, whether or not it is currently streaming. On
    /// `stateQueue`. Stored values are NEVER discarded for budget reasons — a
    /// device that can't get its own stream streams flat and says so
    /// (`Device.eqBypassReason`) while keeping what the user dialled in.
    var eqByDeviceID: [String: DeviceEQ] = [:]   // on stateQueue
    /// The whole mix's own tone stage, applied before every fan-out. On `stateQueue`.
    var storedMainOutEQ: DeviceEQ = .flat   // on stateQueue
    /// The whole-system stream each AirPlay device is homed on — deviceID →
    /// stream id. `0` means the device shares the flat stream 0 because the
    /// engine had no stream left when it connected. It OUTLIVES a session that
    /// dies under a still-desired device, so an engine-driven reconnect lands
    /// back on the stream the plan already carries; only a deselect
    /// (``setOutputSet(_:)``'s desire edge) and `stop()` release it. Written only by
    /// ``connectTargetStreamLocked(_:)``, which every whole-system
    /// session-establishing op reads immediately before its engine call.
    /// On `stateQueue`.
    var wholeSystemStreamByDevice: [String: UInt32] = [:]   // on stateQueue
    /// Devices whose `eq_edit` gesture has already been logged, so a drag
    /// writes one line at its first frame and one at its commit rather than one
    /// per mouse-move. On `stateQueue`.
    var eqEditGesturesLogged: Set<String> = []
    /// The last `eq_plan` summary written, so a scrub that republishes the same
    /// plan shape every frame logs once. On `stateQueue`.
    var lastEQPlanLogSummary: String?
    /// The next whole-system stream id to hand out. Monotonic: a released id is
    /// retired for the session and never reused (decision 8). On `stateQueue`.
    var nextWholeSystemStreamID: UInt32 = NativeBackend.wholeSystemStreamIDBase

    /// One published tone stage: the processor the delivery thread is running,
    /// plus the value it was built for.
    ///
    /// Kept so an UNCHANGED stage keeps the very same `EQProcessor` instance
    /// across pushes. A processor carries IIR delay memory, and a fresh one
    /// starts empty — rebuilding every stage on every push put a step
    /// discontinuity (an audible tick) through every other live stream on each
    /// frame of one device's slider drag.
    struct EQProcessorSlot {
        let eq: DeviceEQ
        let processor: EQProcessor
    }
    /// The live per-stream stages, keyed by stream id. On `stateQueue`.
    var eqSlotByStream: [UInt32: EQProcessorSlot] = [:]   // on stateQueue
    /// The live Main Out stage. On `stateQueue`.
    var mainOutEQSlot: EQProcessorSlot?   // on stateQueue

    /// The rate every whole-system `EQProcessor` is built for: the engine's
    /// hardwired PCM format (S16LE / 44100 / 2ch), which the capture
    /// coordinator's converter has already produced by the time the plan runs.
    static let eqSampleRate: Double = 44_100

    /// How many streams the engine can carry at once. Mirrors
    /// `AirPlayEngine.maxSimultaneousStreams`, kept in step by hand because that
    /// constant is internal to the engine package. The shim both derive from
    /// (`OUTPUTS_MAX_QUALITY_SUBSCRIPTIONS` in `shims/outputs.h`) is
    /// engine-owned, not vendored.
    static let engineStreamCapacity = 16

    /// Whole-system stream ids live in the TOP HALF of the `UInt32` space while
    /// `AppRouteMixer` allocates its per-app ids upward from 1, so the two can
    /// never collide and a stream's owner is told by a range test alone.
    static let wholeSystemStreamIDBase: UInt32 = 0x8000_0000

    /// Test seam: a BT `Device.id` (its Core Audio UID) → the live
    /// `AudioObjectID` a per-device sink pins its engine to. `nil` (production)
    /// falls back to `aggregateControl.resolveDeviceID(forUID:)` — the HAL's
    /// own translation. Resolved fresh at each apply, never cached: object ids
    /// go stale across a disconnect/rejoin while UIDs don't.
    var btDeviceIDForUID: (@Sendable (String) -> AudioObjectID?)?

    /// Test seam: a wired output's `AudioObjectID` → its reported Core Audio
    /// output latency in ms, the offset its sink is seeded with when no
    /// measured latency exists. `nil` (production) means
    /// `LocalOutputLatency.measure(deviceID:)`'s `totalMilliseconds`, rounded,
    /// and `nil` when that throws.
    var wiredReportedLatencyMs: (@Sendable (AudioObjectID) -> Int?)?

    /// The last BT decisions `setOutputSet` committed — enable, selected uids,
    /// and group composition — so a routing call that changes none of them
    /// re-applies nothing. All on `stateQueue`; the apply they gate runs on
    /// `captureControlQueue` (the same decide/execute split as the capture
    /// gate, and the same serial queue, so a BT transition can never race a
    /// tap start/stop or a synced-local transition).
    var btSinkEnabled = false
    var btSelectedUIDs: [String] = []
    /// The Bluetooth UIDs the current PER-APP topology feeds, sorted. Held apart
    /// from `btSelectedUIDs` on purpose: it arms the sink manager
    /// (``btArmingLocked()``) but is deliberately absent from
    /// ``btOnlyReferenceMs(latencies:uids:)`` and ``roomDelayLocked()``, so a
    /// per-app destination READS the room's timing and never writes it — one
    /// app's speaker cannot re-anchor every other sink in the house.
    ///
    /// razor: a per-app-only speaker measured slower than the reference then
    /// hits `SyncTiming.totalDelayNanos`'s ≥ 0 clamp and plays late; the upgrade
    /// is to fold these UIDs into the reference, at the cost of re-anchoring
    /// every other BT sink, the Mac's own sink and the AirPlay pre-delay.
    var btPerAppClaimedUIDs: [String] = []
    var btComposition = BTGroupComposition(airPlayPresent: false, macLocalPresent: false)
    /// The BT-only reference timeline currently in force (ms) — the buffer
    /// every BT sink AND the Mac's own sink schedule against when no AirPlay
    /// receiver is in the group. Derived by ``btOnlyReferenceMs(latencies:uids:)``;
    /// on `stateQueue`, which is also where ``localSinkReferenceDelayMs()``
    /// reads it, so the two sides can never disagree about where the timeline is.
    var btReferenceBufferMs = BTSyncedSink.defaultBTOnlyBufferMs
    /// A Bluetooth-target wizard run is under way, so the reference is pinned
    /// wide open (``btWizardReferenceBufferMs``) for the duration. On `stateQueue`.
    var btWizardReferenceRaised = false
    /// Whether the wizard tick is currently on, so a redundant edge costs
    /// nothing — both edges re-anchor every sink, and the panel fires a second
    /// `false` on the terminal screens. Under ``btTrimLock``.
    var btWizardTickActive = false
    /// The last candidate latency pushed per device this run, so a trial's
    /// telemetry can carry the STEP the estimator just took and not only where
    /// it landed. Cleared when the run ends. Under ``btTrimLock``.
    var btWizardLastPreviewMsByUID: [String: Int] = [:]
    /// The wizard's last pushed tempo — the estimator's stage in disguise (the
    /// coarse search ticks far slower than the stimulus blocks), and the only
    /// signal of it that reaches this layer. Under ``btTrimLock``.
    var btWizardTickBPM: Double?
    /// The alignment wizard's first-tick ARM gate (roadmap 056 Part B): the
    /// in-flight poll, on `captureControlQueue` (which owns both sinks).
    var wizardArmPollWork: DispatchWorkItem?   // captureControlQueue
    /// The three arm-gate timings, `var` so a suite can shrink them rather than
    /// sleeping through the production values.
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
    var castRecords: [String: CastDeviceRecord] = [:]
    /// The Cast ids `setOutputSet` last committed (`stateQueue`), sorted, so a
    /// routing call that changes none of them re-applies nothing.
    var castSelectedIDs: [String] = []
    /// Cast ids whose receiver has reported PLAYING (`stateQueue`) — the audible
    /// fact `desiredDeviceAudibleLocked` reads.
    var castPlaying: Set<String> = []
    /// Cast ids with a grace timer running towards `isAvailable = false`
    /// (`stateQueue`), each mapped to the generation that armed it. A browse
    /// that lists the id again drops the entry, which makes the pending timer
    /// inert; the generation additionally makes a stale timer from an EARLIER
    /// absence inert after a reappear/vanish cycle.
    var castAbsenceFlips: [String: Int] = [:]
    var castAbsenceGeneration = 0
    /// Whether the capture fan-out's Cast slot is attached
    /// (`captureControlQueue`), so an already-armed selection change never
    /// re-attaches it.
    var castFeedAttached = false

    // MARK: First-mix alignment offer (W3)

    /// UIDs held silent for the DURATION of a Bluetooth wizard run — every
    /// selected Bluetooth speaker except the target and (when it is itself a
    /// Bluetooth device) the reference. A run is a two-speaker comparison, and
    /// a third speaker ticking at its own trim is the loudest thing in the room
    /// (live run 2026-08-22: the decoy was judged for the whole run). On
    /// `stateQueue`; folded into `btSinkGain` like the intercept's hold, so it
    /// costs no rebuild and cannot fight the user's volume.
    var btWizardHeldUIDs: Set<String> = []   // stateQueue
    /// UIDs the offer already fired for since launch — the once-per-session
    /// guard. The next launch offers again while the speaker stays unmeasured;
    /// a saved trim is the only permanent stop. On `stateQueue`.
    var btAlignmentPromptedUIDs: Set<String> = []   // stateQueue

    // MARK: Per-app routing (T6)
    //
    // ADDITIVE to the whole-system "Selected Speakers" path above. `captureCoordinator`
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
    let perAppCapture: PerAppCaptureCoordinator

    /// Combines the per-app captures into per-destination mixed streams and owns the
    /// stable device⟷stream_id topology. Pure computation (no Core Audio/engine).
    let routeMixer: AppRouteMixer

    /// Sums the per-app captures of LEVELED apps (un-redirected, volume < 100)
    /// back into the whole-system program at their own volume, inside
    /// ``NativeCaptureCoordinator``'s delivery path. Pure computation, like the
    /// mixer; handed to the coordinator in ``start()``.
    let leveledInjector: LeveledAppInjector

    /// A dedicated per-app capture used ONLY to meter listed apps that are NOT
    /// otherwise captured (`.noRedirect`) — the third `.appLevel` source (T3).
    /// Built `.unmuted` (unlike `perAppCapture`, which is `.mutedWhenTapped` for
    /// actual routing) so it never silences an app it's merely measuring; its
    /// buffers become `.appLevel` and NOTHING else — it feeds neither the mixer
    /// nor the engine. Started/stopped by the popover-scoped metering gate
    /// (`setMeteringActive`) + reconciled by `updateAppRoutes`; it NEVER touches
    /// the primary routing coordinator's taps. See the Metering (T3) section.
    let meteringCapture: PerAppCaptureCoordinator

    // MARK: State (all confined to `stateQueue`)

    // Same discipline as MockBackend: every mutation of the maps below happens
    // on `stateQueue`; `@unchecked Sendable` is honest because of it.
    let stateQueue = DispatchQueue(label: "NativeBackend.state")
    var known: [String: Device] = [:]           // last-known snapshot, by id
    var order: [String] = []                    // stable discovery order
    var continuations: [UUID: AsyncStream<BackendEvent>.Continuation] = [:]
    var started = false

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
    var ptpClockAvailable = true

    /// Wakes the on-demand PTP helper and waits, bounded, for its clock
    /// before a connect (T4). Defaults to `PTPHelperSelfHealingActivator`
    /// wrapping the real `PTPHelperActivator` (T9b: a repeated
    /// `.timingPortsUnavailable` streak gets one password-free unregister/
    /// re-register cycle before it reaches the user), so every existing
    /// caller of the designated initializer compiles unchanged; tests inject
    /// a fake.
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

    /// App-side wait must STRICTLY EXCEED the helper's own bind-retry budget
    /// (10 s, `AUDIOUT_PTP_BIND_RETRY_SECS` in `AirPlayEngine/Sources/ptp-helper/main.c`)
    /// plus launchd spawn latency; the app waits `ptpActivationTimeout` seconds total.
    /// If the app's wait equals or is shorter than the helper's budget, the helper's
    /// late successes remain invisible — the app already returned failure. Invariant:
    /// `ptpActivationTimeout > 10 s`. razor: upgrade path is in AirPlayEngine/docs/
    /// when the helper's bind-retry budget changes.
    private static let ptpActivationTimeout: TimeInterval = 14

    /// Debounce delay before the `.takingOver` strip appears. Only genuinely slow
    /// clock waits (those still running after this many seconds) show the banner;
    /// fast resolutions (common on a warm helper, including manual retries) are silent
    /// and never trigger a double panel re-fit. `<= 0` emits synchronously (used by
    /// tests that pin the strip's state-change ordering).
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
    let aggregateControl: AggregateDeviceControlling

    /// Lifecycle owner (adopt-or-create / off-switch classify / orphan sweep) for
    /// the public aggregate — pure decision logic over ``aggregateControl``.
    let publicAggregate: AggregateOutputDevice

    /// Reads the CURRENT system default output device's UID (`nil` if unreadable),
    /// feeding the off-switch classification. Injectable (default the real HAL
    /// read) exactly like ``systemDefaultOutputIsAirPlayClassProvider``, so T6 can
    /// script "the user switched the default away" with no hardware.
    let currentDefaultOutputUIDProvider: @Sendable () -> String?

    /// True once this session has pointed the Mac's default output at the public
    /// aggregate (first activation, or the user's re-select). Gates the one-time
    /// capture of ``priorDefaultUID`` and the quit-time restore. `stateQueue`.
    var aggregateDefaultActive = false

    /// The default output UID in force at the moment we FIRST took over — restored
    /// (by re-resolving it to a live id, never a cached one) on `stop()`/quit
    /// before the aggregate is destroyed. `stateQueue`.
    var priorDefaultUID: String?

    /// Echo-guard for our OWN default-output writes: the UID we just asked the HAL
    /// to make default, pending its `defaultDeviceChanged` echo on
    /// `systemVolume.onExternalChange`. When the listener reports this same UID we
    /// consume it as our own write, NOT a user off-switch — ``SystemOutputVolume``'s
    /// echo suppression covers only its VOLUME writes, not this default-device
    /// write. `stateQueue`.
    var expectedDefaultWriteUID: String?

    /// Last routing-blocked state pushed on the event stream, so the emit is
    /// edge-triggered (idempotent) and can never thrash/loop. `stateQueue`.
    var routingBlockedEmitted = false

    /// The colon-hex `Device.id` ⟷ ``OutputID`` lookup, populated from discovery.
    /// Kept so `setOutputSet`/`setVolume` can translate the UI's string ids to the
    /// engine handle without reparsing (and without ever reformatting the id).
    var outputIDs: [String: OutputID] = [:]

    /// The set of AP2 device ids the backend has successfully `addOutput`-ed to the
    /// engine (i.e. is currently streaming to). `setOutputSet` diffs against this to
    /// decide which `addOutput`/`removeOutput` calls to issue.
    var added: Set<String> = []

    /// The raw set of ids the app most recently *asked* to be selected (via
    /// `setOutputSet`). Also the CAPTURE GATE's input (`reconcileCaptureGate`).
    /// The actual per-device convergence target is `desiredOn` (below), which
    /// coalesces rapid flips; this is just the last whole-set request.
    var expectedSelected: Set<String> = []

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
    var mainOutGain = 100

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
    var lastSeenSystemVolume: Int?

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
    var captureRunning = false

    /// Where `coordinator.start()`/`stop()` actually run. They must NOT run on
    /// `stateQueue`: `stop()` tears down a Core Audio tap and MAY BLOCK
    /// (NativeCaptureCoordinator.swift:184, "teardown may block on Core Audio"),
    /// which would head-of-line-block every device update behind it. But their
    /// ORDER must still follow the `stateQueue` decisions exactly, or a stale
    /// `start()` could land after a `stop()` and re-mute the Mac forever. A serial
    /// queue that is only ever enqueued-to from INSIDE a `stateQueue` critical
    /// section gives both: `stateQueue` orders the decisions, this queue replays
    /// them in that same order, off the hot path.
    let captureControlQueue = DispatchQueue(label: "NativeBackend.captureControl")

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
    var suspended = false

    /// True while we have deliberately handed the PTP ports to macOS: sessions torn
    /// down, selection INTENT preserved. Distinct from `suspended` (which is the
    /// mechanism this reuses) so a sleep/wake cycle can't silently re-take the ports
    /// behind the user's back. `stateQueue`.
    var handoffReleased = false

    /// Whether the default output has genuinely left our aggregate since the current
    /// handoff release began. Arms the D1 ".stillOurs ⇒ resume" trigger: after a
    /// BLOCKED-ATTEMPT release the default never moved (macOS aborts the failed
    /// AirPlay connect before switching), so ".stillOurs" is just the resting state —
    /// resuming on it re-grabs the ports and re-blocks the user's retry (live-found
    /// loop, 2026-08-07). A userDeselected release starts with this `true` (the
    /// deselect IS the departure); a blockedAttempt release starts `false` and it
    /// flips only on an observed genuine departure. `stateQueue`.
    var defaultLeftUsSinceRelease = true

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
    var handoffTeardown: Task<Void, Never>?

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
    var silenceCaptureOverride = false

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
    var systemAirPlayGuardActive = false

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
    var awaitingWakeReconnect = false

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
    let castAbsenceGrace: TimeInterval

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
    var silenceWatchdog: SilenceWatchdogToken?

    /// Injectable timer seam for the silence watchdog so hermetic tests fire the
    /// countdown deterministically. Defaults to a real `DispatchQueue.asyncAfter`
    /// wrapper (see the designated initializer). Never mutated after init.
    private let watchdogScheduler: SilenceWatchdogScheduling

    /// The armed scheduling snapshot polling work item, scheduled on `stateQueue`.
    /// Polls every ~5s while capture is active; cancelled on `stop()` or when
    /// capture goes idle. Used by T2 to bridge scheduling metrics to telemetry.
    var schedulingSnapshotPollWork: DispatchWorkItem?
    /// How many `send_sched` lines THIS backend has logged. Arming is not the
    /// same observable: an arm whose poll then finds capture stopped logs
    /// nothing, so the guard this counts for is "no second line per
    /// capture-start episode". Counting the telemetry itself cannot work — the
    /// sink is process-global and the event carries no backend identity, so
    /// any other still-polling backend in the same test process lands lines in
    /// the counting window.
    var schedulingSnapshotLogCount = 0

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
    var desiredOn: [String: Bool] = [:]

    /// Device ids with a converge op currently in flight. At most one op per id;
    /// a `setOutputSet` for an id already converging just updates `desiredOn` and
    /// lets the running loop pick up the new target when its current op completes.
    var converging: Set<String> = []

    /// Device ids parked in a terminal-failure state (the engine NACKed / the add
    /// threw). While parked, converge does NOT keep issuing new sessions for the id
    /// (root cause 5: "converge kept issuing sessions post-failure"). The park is
    /// cleared — making the device re-enableable — on the next discovery update or
    /// engine state-stream transition for the id, or by an explicit user re-toggle
    /// to `on` after the in-flight op settled (root cause 4: no permanent wedge).
    var failedGate: Set<String> = []

    /// App-side mute (Q4): the engine has no mute field, so mute is realized as
    /// volume 0 with the prior value stashed.
    var muted: Set<String> = []
    var stashedVolume: [String: Int] = [:]      // pre-mute volume by id

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
    var userConnectSeed: Set<String> = []

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
    var routedBundleIDs: Set<String> = []

    /// The bundle IDs most recently routed to `.currentDevice` (Bug T2): captured
    /// by their own per-app tap (so excluded from the whole-system mix) and played
    /// back locally on the Mac's built-in speakers via ``localPlaybackEngine`` as
    /// an independent stream. `updateAppRoutes` diffs the new set against this.
    /// Kept SEPARATE from `routedBundleIDs`: both drive a per-app tap, but a
    /// device route feeds the ``routeMixer`` → AirPlay, whereas a local route feeds
    /// ``localPlaybackEngine`` → built-in speakers. The per-app CAPTURE is started
    /// for the UNION of the two (the tap is destination-agnostic).
    var localBundleIDs: Set<String> = []

    /// The bundle IDs currently LEVELED: apps the user left un-redirected
    /// (`.noRedirect`) but pulled BELOW 100 on the row's volume slider. At
    /// exactly 100 an app is never here — it keeps playing untouched, with no
    /// tap and no exclusion, which is what makes the intercept engage only when
    /// the user actually asks for it.
    ///
    /// Computed from the RAW route table, never the effective one: a `.device`
    /// route DEMOTED to `.noRedirect` (R5 / roadmap 008) must rejoin the system
    /// mix at full volume exactly as before, so a demotion never levels. Excluded
    /// (privacy denylist) apps are never leveled either.
    ///
    /// Like `localBundleIDs` these drive a per-app tap, and the per-app CAPTURE
    /// is started for the union of all three sets.
    var leveledBundleIDs: Set<String> = []


    /// bundleID → its route's display name, so a `.routedApps` event can carry
    /// human-readable app names. Refreshed on every `updateAppRoutes`.
    var routeDisplayNames: [String: String] = [:]

    /// deviceID → the per-app `stream_id` it is currently bound to (≥ 1). The live
    /// truth `handleDestinationSetsChanged` diffs against to issue the minimal set
    /// of engine bind/rebind/unbind ops. Distinct from `added` (the legacy
    /// stream_id-0 output set), which this never touches.
    var streamBindings: [String: UInt32] = [:]

    /// The destination sets `handleDestinationSetsChanged` last ran with, cached so
    /// device DISCOVERY can re-drive the binding for a target that wasn't known yet
    /// when the routes were applied (see the re-drive in `addOrUpdate`). Cached
    /// rather than re-read from `routeMixer.destinationSets` because that accessor
    /// takes the MIXER's queue, and this is read while already holding `stateQueue`
    /// — the cache keeps the discovery path single-queue. Written only inside
    /// `handleDestinationSetsChanged`'s own `stateQueue` critical section.
    var lastDestinationSets: [AppRouteMixer.DestinationSet] = []

    /// Mixed-buffer counter driving the rate-limited write-backlog sampling (see
    /// `sampleWriteBacklogIfDue`). Confined to the mixer's `onMixedBuffer` queue.
    var backlogSampleCounter = 0
    /// Last `droppedWrites` total reported to Telemetry, so the sampler emits only
    /// on change instead of once per sample. Same queue confinement as above.
    var lastReportedDroppedWrites: UInt64 = 0

    /// Mixed-buffer counter driving the rate-limited write-CADENCE sampling
    /// (see `sampleWriteCadenceIfDue`) — its OWN counter, independent of
    /// `backlogSampleCounter` above, mirroring how `EngineSink`'s own backlog
    /// sampler (`NativeCaptureCoordinator.swift`, commit `9965bd9`) keeps its
    /// own counter rather than sharing one across samplers. Confined to the
    /// mixer's `onMixedBuffer` queue.
    var cadenceSampleCounter = 0
    /// Last cumulative deficit/overrun seconds reported to Telemetry, so the
    /// sampler emits only when the cadence has actually degraded further
    /// since the last sample, not once per sample. Same queue confinement.
    var lastReportedCadenceDeficitSeconds: Double = 0
    var lastReportedCadenceOverrunSeconds: Double = 0

    /// deviceID → the sorted app display names last published via `.routedApps`, so
    /// the event fires only when a device's live app mapping actually changes.
    var routedAppNames: [String: [String]] = [:]

    /// FIFO chain that serializes the per-app engine bind ops. Each new op awaits
    /// the previous one's completion before running, so a device's stop→re-add on a
    /// stream change can never interleave with a later change's ops. Confined to
    /// `stateQueue` (submitted in decision order under the lock), mirroring how
    /// `captureControlQueue` replays capture-gate decisions in order.
    var bindTail: Task<Void, Never> = Task {}

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
    var pendingScopeSettles: Set<String> = []

    /// The currently ACTIVE scope conflicts (device id → record): `.device` routes
    /// demoted because whole-system routing claims their target. DIAGNOSTIC ONLY —
    /// written on the engage edge, removed on disengage, cleared in `stop()`,
    /// exposed via ``test_scopeConflict(deviceID:)``; never read by any decision
    /// path (deliberately NOT a third bookkeeping system — the existing maps ARE
    /// the claims).
    var lastScopeConflicts: [String: ScopeConflict] = [:]

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
    var lastRoutes: [AppRoute] = []

    /// The saved groups' resolved per-app-route memberships, as last handed to
    /// `updateAppRoutes` — group id → eligible members and their levels inside
    /// the group. This is what a `.group` route resolves against; it is a
    /// SNAPSHOT of a live reference, replaced wholesale on every push (a group
    /// edit re-pushes it), never merged. On `stateQueue`.
    var lastGroupTargets: [String: GroupRouteTarget] = [:]

    /// Bundle IDs currently known NOT to be producing audio despite an active
    /// `.device(id:)` route: quit mid-stream (`handleAppTerminated`) or a failed
    /// per-app capture (`handlePerAppCaptureHealthChange`). Excluded from
    /// ``effectiveMixerRoutes()`` so the mixer topology — and therefore
    /// `.routedApps` and the engine stream bindings — only ever reflects apps
    /// actually capturing, never a stale "streaming" claim for one that quit or
    /// never got permission. Cleared the moment the bundle ID stops being routed
    /// at all (`updateAppRoutes`) or starts `.capturing` again (a successful retry).
    var deadBundleIDs: Set<String> = []

    /// Routed bundle IDs that have reached `.capturing` at least once. Lets a
    /// LATER `.capturing` transition be recognised as a RE-capture — i.e. the
    /// per-app tap was torn down and rebuilt (a sample-rate/device change), which
    /// puts a discontinuity into the input stream. After such a rebuild the
    /// AirPlay RTP session for this app's device(s) is desynced from the receiver
    /// and never self-heals (we keep writing real PCM but the receiver stays
    /// silent), so a re-capture triggers a session reset (rebind). Cleared when
    /// the bundle stops being routed or its capture stops.
    var everCapturedBundleIDs: Set<String> = []

    /// bundleID → how many `.processNotYetAudible` retries have already fired
    /// (edge case 3). Kept ONLY to grow the capped-exponential backoff delay, not
    /// as a give-up ceiling. Reset on recovery (`.capturing`) or on losing the
    /// route entirely.
    var retryCounts: [String: Int] = [:]

    /// bundleID → its in-flight bounded retry, so a second failure while one is
    /// already scheduled replaces rather than stacks it, and a recovery /
    /// de-route can cancel it (best-effort — a `DispatchWorkItem` already
    /// running when cancelled still completes, same D4 tolerance as everywhere
    /// else in this file).
    var pendingRetries: [String: DispatchWorkItem] = [:]

    /// Base delay before the FIRST `.processNotYetAudible` retry, and the seed of
    /// the capped-exponential backoff (doubled per attempt, capped at
    /// `processNotYetAudibleMaxBackoff`). `var`-free `let`, injectable only through
    /// the designated initializer so tests can shrink it — production never needs to.
    let processNotYetAudibleRetryDelay: TimeInterval

    /// Ceiling for the `.processNotYetAudible` retry backoff. The delay doubles
    /// each attempt (`retryDelay`, ×2, ×2, …) but never exceeds this, so a routed
    /// app that stays paused is re-probed forever on a bounded interval rather than
    /// being permanently given up on. Retries continue as long as the route is
    /// still desired (`routedBundleIDs.contains`); there is no attempt ceiling.
    let processNotYetAudibleMaxBackoff: TimeInterval

    /// deviceID → a monotonically increasing generation token for its in-flight
    /// AirPlay-session rebind recovery (T4). Bumped on every fresh
    /// `resetAirPlaySessionForRoutedApp` for the device, so an older recovery
    /// chain that completes late can tell it has been superseded (its captured
    /// `gen` no longer matches) and bow out — this is what single-flights the
    /// recovery per device. Removed once the recovery succeeds or gives up.
    var rebindRecoveryGen: [String: Int] = [:]

    /// deviceID → its scheduled (backing-off) rebind-recovery retry, so a fresh
    /// reset or a de-route/unbind can cancel a pending attempt rather than let it
    /// thrash a receiver. Best-effort (a work item already running when cancelled
    /// still no-ops via its own guards), same D4 tolerance as `pendingRetries`.
    var pendingRebindRecoveries: [String: DispatchWorkItem] = [:]

    /// How many whole-system-tap `.failed` retries have already fired in a row
    /// (T16, E10) — kept ONLY to grow the capped-exponential backoff delay, not
    /// as a give-up ceiling: unlike the per-app `retryCounts` (keyed per bundle
    /// ID, one entry per routed app), there is exactly ONE whole-system tap, so
    /// this is a single counter. Reset to 0 on recovery (`.capturing`) and on a
    /// deliberate deselect (`reconcileCaptureGate`'s stop branch clears the
    /// pending timer; `stop()` resets the counter alongside it). Confined to
    /// `stateQueue`.
    var captureRetryCount = 0

    /// The whole-system tap's in-flight bounded retry (T16, E10), so a second
    /// `.failed` while one is already scheduled REPLACES rather than stacks it —
    /// the single-flighting requirement — and a recovery (`.capturing`) or a
    /// deliberate deselect can cancel it before it fires. Best-effort (a work
    /// item already running when cancelled still completes, same D4 tolerance as
    /// `pendingRetries`). Confined to `stateQueue`.
    var pendingCaptureRetry: DispatchWorkItem?

    /// Whether a `.captureFailed` note is currently showing in the popover, so
    /// the clear event is emitted exactly once, on the edge that actually
    /// retires the condition (recovery, or capture stopping being desired).
    /// Confined to `stateQueue`.
    var captureFailureNoteActive = false

    /// Base delay before the FIRST whole-system-tap `.failed` retry (T16, E10),
    /// and the seed of its capped-exponential backoff (doubled per attempt,
    /// capped at `captureRetryMaxBackoff`) — mirrors
    /// `processNotYetAudibleRetryDelay`'s shape exactly, but kept as its own
    /// knob since the whole-system tap and the per-app taps are unrelated
    /// subsystems with independently tunable recovery timing. `var`-free `let`,
    /// injectable only through the designated initializer so tests can shrink
    /// it; production never needs to.
    let captureRetryDelay: TimeInterval

    /// Ceiling for the whole-system-tap retry backoff (T16, E10) — mirrors
    /// `processNotYetAudibleMaxBackoff`: the delay doubles each attempt but
    /// never exceeds this, so a tap that stays `.failed` (e.g. the TCC grant
    /// hasn't been (re-)completed yet) is re-probed forever on a bounded
    /// interval rather than being permanently given up on — matching this
    /// file's existing indefinite-retry philosophy for a condition the user,
    /// not a fixed retry count, ultimately resolves.
    let captureRetryMaxBackoff: TimeInterval

    /// The devices whose `converging` slot is held by a WHOLE-SYSTEM rebind
    /// recovery rather than by a `convergeDevice` loop. `converging` is one
    /// serialization domain shared by both (Finding 1), but only the recovery's
    /// hold is ours to drop out-of-band: `handleSystemWillSleep` abandons in-flight
    /// recoveries, and it must release exactly the slots those recoveries claimed —
    /// removing a slot a live `convergeDevice` loop owns would let a second kick
    /// interleave engine ops for the same device. Per-app-scope recoveries never
    /// claim a slot, so they never appear here.
    var rebindConverging: Set<String> = []

    /// Bounded attempt ceiling for the AirPlay-session rebind recovery (T4).
    /// UNLIKE the indefinite `.processNotYetAudible` retry: a rebind that keeps
    /// failing means the receiver is genuinely gone, and infinite
    /// removeOutput/addOutput would thrash a real device — so recovery gives up
    /// loudly after this many attempts and leaves the device in a defined state.
    let maxRebindRecoveryAttempts: Int

    /// Base (and backoff seed) delay before the next rebind-recovery attempt (T4).
    /// Doubled per attempt (`delay × 2^(attempt-1)`). Injectable so tests don't
    /// pay real wall-clock seconds; production never needs to tune it.
    let rebindRecoveryRetryDelay: TimeInterval

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
    var meteringActive = false

    /// The most recent whole-system-tap RMS (stream_id 0) — a device's system
    /// contribution when it is a Selected Device (unmuted). On `stateQueue`.
    var latestSystemRMS: Float = 0

    /// bundleID -> its most recent PRE-volume SOURCE RMS. A redirect target's
    /// meter contribution is the loudest source routed to it (NOT the attenuated
    /// mix), so a low routing-volume slider no longer empties the bar. Cleared on
    /// `stop()`; a stale entry for an un-routed app is simply never aggregated (the
    /// per-device sum reads only currently-`.device`-routed apps). On `stateQueue`.
    var latestAppLevel: [String: Float] = [:]

    /// The excluded-apps denylist last handed to `updateAppRoutes` — retained so
    /// the metering-only target set can subtract it (PRIVACY: an excluded app is
    /// NEVER metered) and re-reconcile when the denylist changes. On `stateQueue`.
    var lastExcludedBundleIDs: Set<String> = []

    /// The bundle IDs that currently have a metering-only tap running — the live
    /// truth `meteringTapDiffLocked()` diffs against. On `stateQueue`.
    var meteringTapTargets: Set<String> = []

    // MARK: Init

    /// Public seam: the real native backend over the in-process ``AirPlayEngine``
    /// and a live ``NativeDiscovery`` (`NWBrowser`). `EngineControlling` /
    /// `DiscoverySource` stay internal-facing (tests inject doubles); no engine
    /// type leaks into the public surface.
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
        processResolver: AudioProcessResolver = AudioProcessResolver(enumerator: EmptyAudioProcessEnumerator())
    ) {
        self.init(
            engineControl: EngineAdapter(engine: engine),
            discoverySource: discovery,
            btEnumerator: BTDeviceEnumerator.production(),
            btConnectionManager: BTConnectionManager(),
            castEnumerator: CastDeviceEnumerator(),
            castOutputManager: CastOutputManager(),
            wiredEnumerator: WiredOutputEnumerator(),
            btTrimStore: BTTrimStore(),
            castOffsetStore: BTTrimStore(fileName: BTTrimStore.castFileName),
            btHardwareVolumeStore: BTHardwareVolumeStore(),
            btHardwareVolumeControl: BTHardwareVolume(),
            btAbsoluteVolumeClaim: { BTAbsoluteVolumeSDP.claim(forUID: $0) },
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
    /// ``EmptyAudioProcessEnumerator``) keeps the per-app path inert for every existing
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
    /// `syncedLocalSettleWindow` and `syncedLocalTransitionHorizon` are test seams
    /// that shrink the synced-local settle timing the same way; every production
    /// call site (the convenience init included) gets the defaults.
    init(
        engineControl: EngineControlling,
        discoverySource: DiscoverySource,
        btEnumerator: BTDeviceEnumerating? = nil,
        btConnectionManager: BTConnectionManaging? = nil,
        castEnumerator: CastDeviceEnumerating? = nil,
        castOutputManager: CastOutputControlling? = nil,
        wiredEnumerator: WiredOutputEnumerating? = nil,
        btTrimStore: BTTrimStore? = nil,
        castOffsetStore: BTTrimStore? = nil,
        btHardwareVolumeStore: BTHardwareVolumeStore? = nil,
        btHardwareVolumeControl: BTHardwareVolumeControlling? = nil,
        btAbsoluteVolumeClaim: (@Sendable (String) -> Bool?)? = nil,
        eqStore: DeviceEQStore? = nil,
        dacpEndpoint: DACPEndpoint = DACPServer(),
        systemVolume: SystemVolumeControlling = SystemOutputVolume(),
        ptpHelperActivator: PTPHelperActivating = PTPHelperSelfHealingActivator(),
        connectVolume: @escaping @Sendable () -> Int = { AppSettings().connectVolume },
        processResolver: AudioProcessResolver = AudioProcessResolver(enumerator: EmptyAudioProcessEnumerator()),
        injectedPerAppCapture: PerAppCaptureCoordinator? = nil,
        injectedMeteringCapture: PerAppCaptureCoordinator? = nil,
        processNotYetAudibleRetryDelay: TimeInterval = 2.0,
        processNotYetAudibleMaxBackoff: TimeInterval = 10.0,
        maxRebindRecoveryAttempts: Int = 3,
        rebindRecoveryRetryDelay: TimeInterval = 0.5,
        syncedLocalSettleWindow: TimeInterval = 0.5,
        syncedLocalTransitionHorizon: TimeInterval = 2.0,
        captureRetryDelay: TimeInterval = 2.0,
        captureRetryMaxBackoff: TimeInterval = 10.0,
        takeoverStripDelay: TimeInterval = 3.0,
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
        self.wiredEnumerator = wiredEnumerator
        self.btTrimStore = btTrimStore
        do {
            if let loaded = try btTrimStore?.load() ?? nil {
                self.btTrimsByUID = loaded.mapValues { BTSyncTrim.clamp($0) }
            }
        } catch {
            StoreRecovery.noteWriteFailure(error)
        }
        do {
            if let latencies = try btTrimStore?.loadLatencies() ?? nil {
                self.btLatencyMsByUID = latencies.mapValues { Swift.max(0, $0) }
            }
        } catch {
            StoreRecovery.noteWriteFailure(error)
        }
        do {
            if let indices = try btTrimStore?.loadSpeakerIndex() ?? nil {
                self.btSpeakerIndexByUID = indices
            }
        } catch {
            StoreRecovery.noteWriteFailure(error)
        }
        self.btHardwareVolumeStore = btHardwareVolumeStore
        self.btHardwareVolumeControl = btHardwareVolumeControl
        self.btAbsoluteVolumeClaim = btAbsoluteVolumeClaim
        self.castOffsetStore = castOffsetStore
        do {
            if let castOffsets = try castOffsetStore?.load() ?? nil {
                self.castOffsetsByID = castOffsets.mapValues {
                    BTSyncTrim.quantise($0, rangeMs: BTSyncTrim.castRangeMs)
                }
            }
        } catch {
            StoreRecovery.noteWriteFailure(error)
        }
        self.eqStore = eqStore
        do {
            if let loaded = try eqStore?.load() ?? nil {
                self.storedMainOutEQ = loaded.mainOut ?? .flat
                self.eqByDeviceID = loaded.devices
            }
        } catch {
            StoreRecovery.noteWriteFailure(error)
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
        self.leveledInjector = LeveledAppInjector()
        self.processNotYetAudibleRetryDelay = processNotYetAudibleRetryDelay
        self.processNotYetAudibleMaxBackoff = processNotYetAudibleMaxBackoff
        self.maxRebindRecoveryAttempts = maxRebindRecoveryAttempts
        self.rebindRecoveryRetryDelay = rebindRecoveryRetryDelay
        self.syncedLocalSettleWindow = syncedLocalSettleWindow
        self.syncedLocalTransitionHorizon = syncedLocalTransitionHorizon
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
            // Same reason as the mixer's: a leveled app's real `TapFormat` is
            // only known on the `.capturing` transition.
            self?.leveledInjector.handleStateChange(bundleID: bundleID, state: state)
            self?.handlePerAppCaptureHealthChange(bundleID: bundleID, state: state)
            // Bug T2: a `.currentDevice` app reaching `.capturing` gets its own
            // local player (its `TapFormat` is now known); leaving `.capturing`
            // drops it. A no-op for `.device`-routed apps (guarded on
            // `localBundleIDs`).
            self?.handleLocalCaptureStateChange(bundleID: bundleID, state: state)
        }
        self.perAppCapture.onBuffer = { [weak self] bundleID, buffer in
            // Fan every per-app buffer to ALL THREE consumers. Each ignores what
            // isn't its own: the mixer drops a buffer for a bundle with no
            // `.device` stream, the local engine drops one for a bundle with no
            // player, and the leveled injector drops one for a bundle that isn't
            // leveled (or while the whole-system capture is off) — so a `.device`
            // app's audio only reaches the mixer, a `.currentDevice` app's only
            // the local engine, and a leveled app's only the injector, with no
            // shared set read on this hot delivery-thread path.
            if AudioDiag.isEnabled {
                // Report buffer PEAK, not just count: a process tap keeps
                // delivering buffers at full cadence but SILENT (all-zero) after a
                // sample-rate renegotiation — so a count-only meter (the earlier
                // bug) looks healthy while the audio is gone. peak≈0 while the app
                // is audibly playing == the documented silent-buffer condition.
                AudioDiag.tick("perAppBuffer:\(bundleID)", detail: "peak=\(Self.diagFloatPeak(buffer))")
            }
            guard let self else { return }
            let suppressed = self.btTrimLock.withLock { self.companionProgramSuppressed }
            let delivered = suppressed
                ? CapturedBuffer(channelData: buffer.channelData.map { Data(count: $0.count) },
                                 frameCount: buffer.frameCount, pts: buffer.pts)
                : buffer
            self.routeMixer.handleBuffer(bundleID: bundleID, buffer: delivered)
            self.leveledInjector.handleBuffer(bundleID: bundleID, buffer: delivered)
            self.localPlaybackEngine?.receive(buffer: delivered, for: bundleID)
        }
        routeMixer.onDestinationSetsChanged = { [weak self] sets in
            self?.handleDestinationSetsChanged(sets)
        }
        routeMixer.onMixedBuffer = { [weak self] mixed in
            guard let self else { return }
            let pcm = self.btTrimLock.withLock { self.companionProgramSuppressed }
                ? Data(count: mixed.pcm.count) : mixed.pcm
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
            // R-partition, per-app half: a stream can span an AirPlay receiver
            // and a Bluetooth speaker, so the two deliveries are ADDITIVE. No
            // entry at all means no Bluetooth on this stream — the engine write
            // then stands alone, as it always has.
            let feed = self.btPerAppFeedsLock.withLock { self.btPerAppFeeds[mixed.streamID] }
            if feed?.feedsEngine ?? true {
                self.engine.write(
                    pcm: pcm, streamId: UInt32(mixed.streamID), pts: mixed.pts)
            }
            if let feed {
                NativeCaptureCoordinator.fanOutToSyncedLocal(
                    pcm, pts: mixed.pts, into: feed, resampler: feed.resampler)
            }
            // BACKPRESSURE VISIBILITY (diagnostic): the engine's write guard can
            // silently DROP audio once a stream's un-drained backlog hits its cap
            // — audible as "dropped milliseconds" that the routing telemetry above
            // can never explain (no rebuild, no reset, nothing logged). Sample the
            // guard's counters here, but RATE-LIMITED and only emitting on CHANGE:
            // this closure runs per mixed buffer (mixer queue, RT-adjacent), and
            // `Telemetry` must never be called at buffer cadence. One cheap
            // counter increment per buffer; a snapshot read + possible log only
            // once every `backlogSampleInterval` buffers.
            self.sampleWriteBacklogIfDue()
            // CADENCE VISIBILITY (T-ENG-CADENCE-1, whole-system-dropout
            // investigation): same rationale and throttling as the backlog
            // sample above, for the engine's write-cadence deficit/overrun
            // counters instead of its backpressure-drop counter, tagged
            // `path: "perApp"` — `EngineSink.write` in
            // `NativeCaptureCoordinator.swift` mirrors this for the whole-system feed
            // (`path: "wholeSystem"`), so this event now has full coverage
            // whether or not any per-app route is active.
            self.sampleWriteCadenceIfDue()
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
        // Per-app meter, source 1/3 continued: a LEVELED app while the
        // whole-system capture runs. Its buffers reach no other metering source
        // (it is out of the `.unmuted` metering tap's target set, and it has no
        // local player while capture runs), so the injector emits the same
        // PRE-volume source RMS the mixer does. Gated on its own `meteringActive`.
        leveledInjector.onAppLevel = { [weak self] bundleID, rms in
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
        // Every stored property has a value by here, which is what lets the
        // read capture `self` at all. The store's own lock is taken inside the
        // closure and never while `BTSpeakerTiming`'s lock is held.
        btSpeakerTiming = BTSpeakerTiming(
            storedOffsetMs: { [weak self] uid in self?.btStoredAlignmentOffsetMs(forDevice: uid) },
            speakerKey: { [weak self] uid in self?.btSpeakerKey(forDevice: uid) ?? "?" },
            deviceClassMinor: { [weak self] uid in self?.btDeviceClassMinor(forDevice: uid) })
        // The detail-pane toggle (BT-HW-VOL): a flip re-decides that uid's
        // write path on `stateQueue`, like every other input to the decision.
        btHardwareVolumeStore?.onChange = { [weak self] uid, _ in
            guard let self else { return }
            self.stateQueue.async { self.reevaluateBTHardwareControlLocked(uid) }
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
            // the popover has a "This Mac" row and GroupController can seed
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
            _ = self.publicAggregate.adoptOrCreate(candidateUID: self.currentDefaultOutputUIDProvider())
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
        if let wiredEnumerator {
            wiredEnumerator.onSnapshot = { [weak self] snapshots in
                self?.stateQueue.async { self?.applyWiredSnapshots(snapshots) }
            }
            wiredEnumerator.start()
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
        // A plug or unplug can take away the device the public aggregate wraps, or
        // bring back the one the user was listening through.
        aggregateControl.observeDeviceList { [weak self] in
            self?.stateQueue.async { self?.reconcileAggregateSubDeviceLocked(reason: "device_list") }
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
            //    to a `deviceUpdated`. A dead session is noticed by push, never
            //    by polling for it.
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

            // Hand the delivery path the leveled-app intercept (the coordinator is
            // assigned before `start()`); it contributes nothing until
            // `updateAppRoutes` levels an app AND the capture gate opens. Enqueued
            // on `captureControlQueue` rather than called inline for the reason
            // `setEQPlan` is: this block holds `stateQueue`, and the setter takes
            // the coordinator's own queue — the queue whose callbacks come back
            // through `stateQueue`.
            if let coordinator = self.captureCoordinator {
                let injector = self.leveledInjector
                self.captureControlQueue.async { coordinator.setLeveledAppInjector(injector) }
            }

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
            // which the process tap keeps delivering buffers but the whole-system
            // AirPlay sessions stay pinned to a now-stale RTP timeline and the
            // receivers go silent forever (Apple-unresolved, Dev Forums 825780). The coordinator
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
        let shuttingAudition = btTrimLock.withLock { () -> (UUID, [@Sendable (String?) -> Void],
                                                            (targetID: String, ms: Double)?)? in
            guard var audition = companionAudition else { return nil }
            audition.phase = .cleaning
            audition.cleanupPrepared = false
            let callbacks = audition.startCompletions + audition.stopCompletions
            audition.startCompletions = []
            audition.stopCompletions = []
            companionAudition = audition
            companionProgramSuppressed = false
            // Shutdown is an ordinary exit: quitting mid-audition must not be
            // the one way to lose what the user nudged by ear. Claimed here,
            // written below with the lock released.
            let persist = claimCompanionAuditionTrimLocked(id: audition.id)
            return (audition.id, callbacks, persist)
        }
        // Before the engine teardown Task below: a value written after the
        // sessions are gone would still be correct, but the store write is what
        // the next launch reads, so it happens while the backend is still whole.
        if let persist = shuttingAudition?.2 {
            setBTSyncTrim(persist.ms, forDevice: persist.targetID, persist: true)
        }
        if shuttingAudition != nil {
            setBTWizardTickActive(false, btTargetDeviceID: nil, btReferenceDeviceID: nil)
            endBTWizardRun()
            DispatchQueue.main.async {
                shuttingAudition?.1.forEach { $0("Audiout is shutting down.") }
            }
        }
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
        // Detach the leveled intercept and stop it accumulating: the taps feeding
        // it are stopped below, and a later `start()` re-attaches it.
        captureCoordinator?.setLeveledAppInjector(nil)
        leveledInjector.setActive(false)
        leveledInjector.updateLeveled([])
        captureCoordinator?.setMeteringActive(false)
        // Metering (T3): leave every metering source switched off (teardown
        // discipline — a closed backend has nobody to render a meter for) and stop
        // every metering-only tap. `meteringCapture.stopAll()` is off `stateQueue`
        // (Core Audio teardown), matching the taps below. The whole-system tap is
        // NOT stopped eagerly here — the ordered `captureControlQueue` stop below is
        // the documented final word (C1: an eager caller-thread stop blocked quit).
        routeMixer.setMeteringActive(false)
        leveledInjector.setMeteringActive(false)
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
        wiredEnumerator?.onSnapshot = nil
        wiredEnumerator?.stop()
        castOutputManager?.onStateChange = nil
        castOutputManager?.onVolumeLagChange = nil
        castOutputManager?.onLeadSample = nil
        // Drop the local row's two-way sync (the row itself is removed below).
        systemVolume.onExternalChange = nil
        systemVolume.stop()
        aggregateControl.stopObservingDeviceList()
        // Stop advertising / listening for DACP (speaker-initiated volume).
        dacpServer.onVolume = nil
        dacpServer.onVolumeStep = nil
        dacpServer.stop()

        // Engine teardown stays fire-and-forget so `stop()` never blocks its caller,
        // but the Task is now STORED (C1) so the app layer can await it via
        // `stopAndWait(timeout:)` on the terminate path — otherwise process exit
        // outruns the RTSP/RTP teardown and the AirPlay sessions are cut un-gracefully.
        let engine = self.engine
        let engineStop = Task {
            await engine.stop()
            if let id = shuttingAudition?.0 {
                // Teardown is the other way the reservation can honestly end:
                // the engine sessions are gone, so no late write can reach a new
                // one. Only now may the lifetime callbacks fire.
                let released = self.btTrimLock.withLock { () -> [@Sendable () -> Void] in
                    guard let current = self.companionAudition, current.id == id else { return [] }
                    self.companionAudition = nil
                    if self.companionAlignmentRun?.id == id { self.companionAlignmentRun = nil }
                    return current.releaseCallbacks
                }
                if !released.isEmpty {
                    DispatchQueue.main.async { released.forEach { $0() } }
                }
            }
        }

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
            // The horizon is per-session: a later start() must not inherit a
            // pre-stop transition and arm the re-sync off it.
            self.syncedLocalTransitionTimes.removeAll()
            // Before this, stop() reset the desired/applied flags below while a
            // running sink stayed attached and started. The disable path is
            // idempotent (a nil or already-stopped sink is a no-op). Enqueued
            // here, ahead of the `coordinator.stop()` enqueue further down, so the
            // FIFO order on `captureControlQueue` is sink disable, coordinator
            // stop, BT disable, Cast disable.
            let gain = self.syncedLocalGain
            self.captureControlQueue.async { [weak self] in
                self?.applySyncedLocalSinkTransition(enable: false, gain: gain)
            }
            self.syncedLocalSinkEnabled = false
            self.syncedLocalSinkApplied = false
            // BT-BACKEND: reset the BT decisions; the disable itself is enqueued
            // below alongside the capture stop, so the FIFO's last BT op is the
            // stop (same ordering argument as the coordinator stop).
            self.btSinkEnabled = false
            self.btSelectedUIDs = []
            self.btPerAppClaimedUIDs = []
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
            // W3: drop the wizard's hold too — the sinks are going away.
            self.btWizardHeldUIDs.removeAll()
            self.companionTickParticipants = nil
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
            self.lastVolumeOutcome.removeAll()
            // Invalidate the write pipeline itself, not just its bookkeeping: a
            // completion still in flight against the torn-down engine would
            // otherwise land on a restarted backend and clear a NEW push's
            // in-flight marker.
            self.volumeGeneration &+= 1
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
            self.leveledBundleIDs.removeAll()
            self.routeDisplayNames.removeAll()
            self.streamBindings.removeAll()
            self.routedAppNames.removeAll()
            // The stream assignment describes engine sessions that are being torn
            // down; the VALUES (`eqByDeviceID`/`storedMainOutEQ`) are the user's
            // settings and stay. `nextWholeSystemStreamID` stays too — a released
            // stream id is retired for the session, never reused (decision 8). The
            // coordinator goes back to byte-identical passthrough.
            self.wholeSystemStreamByDevice.removeAll()
            self.eqSlotByStream.removeAll()
            self.mainOutEQSlot = nil
            // The plan published here bypasses `pushEQPlanLocked`, so its log
            // cache has to be cleared by hand or the next plan that happens to
            // match the pre-stop one is swallowed. Same for a gesture whose
            // commit never arrived: a stale entry would suppress the first
            // frame of the next drag on that device.
            self.lastEQPlanLogSummary = nil
            self.eqEditGesturesLogged.removeAll()
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
                let wrote = self.aggregateControl.setDefaultOutputDevice(priorID)
                // No read-back: `sweepOrphans()` below destroys the aggregate, so
                // there is nothing left to verify the write against.
                Telemetry.log(.airplay, "aggregate_default_restore", [
                    "outcome": wrote ? "wrote" : "write_refused",
                    "target": priorUID, "site": "stop"])
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
            if self.known[id]?.isBluetooth == true || self.known[id]?.isWired == true {
                if self.muted.contains(id) {
                    self.stashedVolume[id] = clamped
                    self.applyLocal(id) { $0.volume = clamped }
                } else {
                    self.applyLocal(id) { $0.volume = clamped }
                    // A hardware-controlled uid's device term lives on the
                    // speaker (BT-HW-VOL); everyone else composes in software.
                    if self.btHardwareControlledUIDs.contains(id) {
                        self.pushBTHardwareVolumeLocked(id, level: clamped)
                    } else {
                        self.pushBTSinkGainLocked(id)
                    }
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
            if self.known[id]?.isBluetooth == true || self.known[id]?.isWired == true {
                if muted {
                    self.muted.insert(id)
                    if self.stashedVolume[id] == nil { self.stashedVolume[id] = self.known[id]?.volume ?? 0 }
                    self.applyLocal(id) { $0.isMuted = true; $0.volume = 0 }
                } else {
                    self.muted.remove(id)
                    let intended = self.stashedVolume[id] ?? self.known[id]?.volume ?? 0
                    self.stashedVolume[id] = nil
                    self.applyLocal(id) { $0.isMuted = false; $0.volume = intended }
                    // Mute never touched the speaker's own level (BT-HW-VOL:
                    // the software 0 is the mute), but the stash may have
                    // moved while muted — a slider drag, or the speaker's own
                    // buttons — so unmute settles hardware on the level owed.
                    if self.btHardwareControlledUIDs.contains(id) {
                        self.pushBTHardwareVolumeLocked(id, level: intended)
                    }
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
                // Mute = volume 0 with the pre-mute value stashed.
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

    /// Where the Main mirror and the local row's mute actually aim: the device our
    /// aggregate wraps, else the Mac's first built-in output, but only while that
    /// aggregate is the current default output.
    ///
    /// The aggregate wraps the output the user was listening through as its sole sub-device
    /// (``AggregateOutputDevice``) and ACCEPTS volume writes while discarding them,
    /// so a write aimed at "whatever is currently default" during a routing session
    /// leaves the real speakers' hardware knob stale — and the user hears the jump
    /// on deselect. The wrapped device is the knob that changes what is heard.
    ///
    /// Deliberately NOT ``weOwnSystemVolume``: that is also true for a real output
    /// with an unreadable volume (HDMI), where writing the built-in would move
    /// speakers nobody is listening to.
    ///
    /// The returned closure captures only the two injected seams — never `self`,
    /// never `stateQueue`-confined state — and is evaluated on
    /// `SystemOutputVolume`'s own write queue.
    func builtInOutputTargetResolver() -> @Sendable () -> AudioObjectID? {
        let control = aggregateControl
        let provider = currentDefaultOutputUIDProvider
        return {
            guard provider() == AggregateOutputDevice.productUID else { return nil }
            let wrapped = control.resolveDeviceID(forUID: AggregateOutputDevice.productUID)
                .flatMap { control.mainSubDeviceUID(ofAggregate: $0) }
            return Self.firstResolvableDevice(uids: [wrapped], using: control)?.id
                ?? Self.firstResolvableDevice(uids: [control.builtInOutputDeviceUID()], using: control)?.id
        }
    }

    /// Push ``syncedLocalGain`` to the delayed local sink (W1's
    /// ``SyncedLocalSink/setGain(_:)``) — `group × the Mac's own fader`, and Main
    /// too while we own the volume. Reads state on `stateQueue`, then
    /// hops to `captureControlQueue`, which owns `syncedLocalSink`. A no-op before
    /// the sink is built — `applySyncedLocalSinkTransition` applies the current gain
    /// as it starts, so a trim made while "play everywhere" was off is not lost.
    func pushSyncedLocalGain() {   // on stateQueue
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
    var syncedLocalGain: Float {   // on stateQueue
        if let companionTickParticipants,
           !companionTickParticipants.contains(Self.localDeviceID) { return 0 }
        let level = known[Self.localDeviceID]?.volume ?? 100
        let main = weOwnSystemVolume ? Double(mainOutGain) / 100.0 : 1.0
        return Float(main * Double(groupGain) / 100.0 * Double(level.clampedToVolume) / 100.0)
    }

    /// One BT device's composed sink gain: `Main × Group × Device` on the UI's
    /// 0–100 scale — the same product `engineVolume(forID:uiVolume:)` forms for
    /// AirPlay outputs, linear because the sink's mixer wants a 0…1 amplitude,
    /// not a dB wire value — forced to 0 while the id is muted (the stash shim)
    /// or held for a wizard run (W3). ONE product, one writer: every gain that
    /// reaches `BTSyncedSinkControlling/setGain(_:forDeviceUID:)` is computed
    /// here, so user volume and the hold can never fight over the knob. Unlike
    /// the Mac's `syncedLocalGain`, Main IS included — a BT sink renders through
    /// its own device, which the Mac's system volume never touches. On
    /// `stateQueue`.
    func btSinkGain(forUID uid: String) -> Float {   // on stateQueue
        if let companionTickParticipants, !companionTickParticipants.contains(uid) { return 0 }
        if btWizardHeldUIDs.contains(uid) || muted.contains(uid) { return 0 }
        // A hardware-controlled uid's device term is on the speaker itself
        // (BT-HW-VOL), so the software product carries Main alone.
        if btHardwareControlledUIDs.contains(uid) { return Float(masterGainFraction) }
        let level = known[uid]?.volume ?? 100
        return Float(masterGainFraction * Double(level.clampedToVolume) / 100.0)
    }

    /// Push one uid's composed gain to the live sink (a no-op before the sink
    /// exists — `applyBTSinkTransition` seeds the same product on arm). Reads on
    /// `stateQueue`, then hops to `captureControlQueue`, which owns `btSink`.
    ///
    /// `completion` fires on `captureControlQueue` once the write has actually
    /// reached the sink. The audition's preparation is the only caller that
    /// passes one: without it the hold was fire-and-forget, and clicks could
    /// start before another speaker's gain had landed — so music burst out of a
    /// speaker that was supposed to be silent for the audition.
    func pushBTSinkGainLocked(_ uid: String,
                                      completion: (@Sendable () -> Void)? = nil) {   // on stateQueue
        let gain = btSinkGain(forUID: uid)
        captureControlQueue.async { [weak self] in
            self?.btSink?.setGain(gain, forDeviceUID: uid)
            completion?()
        }
    }

    /// The composed gain per selected BT uid, snapshotted under `stateQueue` for
    /// a sink transition to apply on `captureControlQueue`. On `stateQueue`.
    func btSinkGains(forUIDs uids: [String]) -> [String: Float] {   // on stateQueue
        Dictionary(uniqueKeysWithValues: uids.map { ($0, btSinkGain(forUID: $0)) })
    }

    /// The wired rows among `uids` — the ones whose sink offset is seeded from
    /// the reported latency. On `stateQueue`.
    func wiredSinkUIDs(forUIDs uids: [String]) -> Set<String> {   // on stateQueue
        Set(uids.filter { known[$0]?.isWired == true })
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
    func ensurePTPTakeover(telemetryDeviceID: String) async -> Bool {
        var switchAwayOutcome: DefaultOutputSwitchOutcome?
        if let defaultOutputSwitcher {
            let takeover = defaultOutputSwitcher.switchAwayFromAirPlay()
            switchAwayOutcome = takeover
            Telemetry.log(.airplay, "takeover_switch_away", [
                "device": telemetryDeviceID, "outcome": "\(takeover)",
            ])
        }
        // Banner-flash fix (2026-08-06): the `.takingOver` strip is DEBOUNCED —
        // armed only after `takeoverStripDelay` of genuine waiting, cancelled if
        // the wait resolves first. Pre-fix the strip mounted synchronously on
        // every attempt that waited at all, so each manual retry-that-fails
        // flashed the blue strip (mount + unmount, two panel re-fits) over the
        // steady-state orange fallback banner. A wait that outlives the delay
        // still mounts it, and the `.timedOut` backstop is unaffected.
        var takingOverArm: DispatchWorkItem?
        let willWaitForClock = ptpHelperActivator.willWaitForClock
        if willWaitForClock {
            if takeoverStripDelay <= 0 {
                stateQueue.sync { self.setTakeoverStatus(.takingOver) }
            } else {
                let arm = DispatchWorkItem { [weak self] in self?.setTakeoverStatus(.takingOver) }
                takingOverArm = arm
                stateQueue.asyncAfter(deadline: .now() + takeoverStripDelay, execute: arm)
            }
        }
        let activationStartUptime = ProcessInfo.processInfo.systemUptime
        let outcome = await ptpHelperActivator.activate(timeout: Self.ptpActivationTimeout)
        let elapsedMs = Int(((ProcessInfo.processInfo.systemUptime - activationStartUptime) * 1000).rounded())
        let outcomeName: String
        switch outcome {
        case .ready: outcomeName = "ready"
        case .needsApproval: outcomeName = "needsApproval"
        case .timingPortsUnavailable: outcomeName = "timingPortsUnavailable"
        }
        Telemetry.log(.airplay, "ptp_activate", [
            "device": telemetryDeviceID,
            "will_wait": willWaitForClock ? "true" : "false",
            "outcome": outcomeName,
            "elapsed_ms": "\(elapsedMs)",
            "switch_away": switchAwayOutcome.map { "\($0)" } ?? "none",
        ])
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
    func replayPendingPerAppBindings(trigger: String) {
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
    func releaseRebindConverging(id: String) -> ConvergeReleaseAction {
        self.rebindConverging.remove(id)
        return self.releaseConvergingAndRequeueIfNeeded(id: id)
    }

    /// What a whole-system slot release asks its (off-lock) caller to do next
    /// (roadmap 008 widened the old bare `OutputID?` requeue): re-kick a converge
    /// for the moved target, and/or replay the cached per-app topology now that
    /// the whole-system domain fully released the device. Losers never WAIT on
    /// the other FIFO — they bow out and are re-driven here, by the releasing
    /// side.
    struct ConvergeReleaseAction {
        /// Re-kick `convergeDevice` (the pre-008 requeue, unchanged).
        var requeue: OutputID?
        /// Call `replayPendingPerAppBindings(trigger: "ws_release")` OFF the
        /// lock: the per-app table still wants this device and its binding was
        /// cleared by a fire-time bow-out.
        var redrivePerApp = false
        static let none = ConvergeReleaseAction(requeue: nil)
    }

    func releaseConvergingAndRequeueIfNeeded(id: String) -> ConvergeReleaseAction {
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

    func convergeDevice(id: String, outputID: OutputID) async {
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
                        Telemetry.fail(.airplay, "airplay:connect_failed",
                                       local: ["device": id],
                                       shared: ["cause": "timingUnavailable"])
                        return
                    }

                    // Connect-latency diagnosis: brackets the real RTSP/negotiate
                    // handshake `addOutput` awaits (device_start through the STREAMING
                    // completion) — the gap between these two events is the AirPlay
                    // receiver's own negotiation time, not anything this app controls.
                    Telemetry.log(.airplay, "connect_addoutput_start", ["device": id, "output": "\(outputID)"])
                    // T7: go through the shared scope-transition call site, not a
                    // bare `addOutput`. If this device is currently carrying a
                    // per-app redirect (a live session on a per-app stream, bound
                    // by the `bindTail` FIFO this loop knows nothing about), a
                    // plain `addOutput` would silently no-op and leave the
                    // whole-system mix written to a stream the device never joined
                    // — selected, shown as connected, inaudible. `bindOutput` asks
                    // the engine which stream the session is really on and MOVES
                    // it to the home stream.
                    //
                    // The home stream is read under the lock right here, one line
                    // before the op: it is this device's for the life of the
                    // session, so every later tone edit is a coefficient swap
                    // rather than a rebind and its ~2 s AirPlay gap.
                    let home = stateQueue.sync { self.connectTargetStreamLocked(id) }
                    try await bindOutput(outputID, toStream: home)
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
                        // Same edge as the volume seed: this device just joined
                        // the streaming set, so the plan has to carry its stream.
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
                    // The engine error rides along locally only: its
                    // description can name the receiver.
                    Telemetry.fail(.airplay, "airplay:connect_failed",
                                   local: ["device": id, "detail": String(describing: error)],
                                   shared: ["cause": "\(cause)"])
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
                    // Connection state is left alone here — a non-terminal issue
                    // never moves it, and the device is still desired off, so the
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
    // MockBackend.swift:457). It is the "This Mac" the popover renders and
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
        // public aggregate, return the name of the device it wraps instead, else
        // the first built-in output's.
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
            let control = CoreAudioAggregateDeviceControl()
            let wrappedID = control.mainSubDeviceUID(ofAggregate: deviceID)
                .flatMap { control.resolveDeviceID(forUID: $0) }
            if let builtInID = wrappedID ?? SystemLocalOutputResolver().builtInOutputDevice() {
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
    var _startBufferMs: Int = 1000

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
    var _castTermMs: Int? { castRoomDelay.termMs }

    /// The room-delay policy (brief §4): the settle gate, the high-water mark
    /// and the `R_max` refusal, kept pure so it can be replayed offline
    /// against recorded lead samples. Confined to `stateQueue`; the only
    /// writers are ``updateCastRoomDelayLocked()`` (the receiver set moved)
    /// and ``applyCastLeadSample(_:_:)`` (a receiver measured itself).
    var castRoomDelay = CastRoomDelay()

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
    func convergeToTarget(id: String, outputID: OutputID, on target: Bool) async {
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
        // The leveled apps lose the program they were being summed into — hand
        // them back to the local engine, exactly as the gate's own false edge does
        // (this path bypasses `reconcileCaptureGate` entirely).
        self.reconcileLeveledConsumersLocked(running: false)
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
        // The live tone stages describe engine sessions that just died, so they
        // die with them — the wake's re-add builds fresh ones. The stream
        // assignment deliberately SURVIVES, unlike in `stop()`: the wake re-add
        // reads it through `connectTargetStreamLocked` and lands each speaker
        // back on the very stream it slept on, so the plan the coordinator
        // re-publishes matches engine truth with no rebind.
        self.eqSlotByStream.removeAll()
        self.mainOutEQSlot = nil
        // Published without `pushEQPlanLocked`, so its log cache is cleared by
        // hand: the wake rebuilds the very same plan, and a stale cache would
        // swallow the first `eq_plan` after the wake — the line a reader wants.
        self.lastEQPlanLogSummary = nil
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
    func reconcileHandoffWatcherLocked() {   // on stateQueue
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
    func reconcileSilenceWatchdog() {   // on stateQueue
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
    func desiredDeviceAudibleLocked(_ id: String) -> Bool {   // on stateQueue
        guard let device = known[id] else { return false }
        if device.isBluetooth || device.isWired { return device.isAvailable }
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
    func clearSilenceOverride() -> Bool {   // on stateQueue
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
    func startSchedulingSnapshotPolling() {   // on stateQueue
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
        // Leveled-intercept health, on the same 5 s cadence: exactly where the
        // leveled path is losing audio. `mix_calls` at 0 means the whole-system
        // tap never asked (nothing is driving the delivery thread); `samples_mixed`
        // at 0 with `buffers_in` climbing means the rings fill but nothing reads
        // them; `dropped_*` names the guard that is eating the buffers.
        let leveled = self.leveledInjector.takeDiagnostics()
        if leveled.mixCalls > 0 || leveled.buffersIn > 0 || leveled.ringCount > 0 {
            Telemetry.log(.captureWS, "leveled_health", [
                "active": leveled.isActive ? "true" : "false",
                "rings": "\(leveled.ringCount)",
                "pending_samples": "\(leveled.pendingSamples)",
                "mix_calls": "\(leveled.mixCalls)",
                "mix_inactive": "\(leveled.mixInactive)",
                "mix_no_rings": "\(leveled.mixNoRings)",
                "samples_mixed": "\(leveled.samplesMixed)",
                "buffers_in": "\(leveled.buffersIn)",
                "dropped_inactive": "\(leveled.droppedInactive)",
                "dropped_not_leveled": "\(leveled.droppedNotLeveled)",
                "dropped_no_converter": "\(leveled.droppedNoConverter)",
                "dropped_convert_failed": "\(leveled.droppedConvertFailed)",
            ])
        }

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

        // One line per content stream: was there SOUND in what we sent? On
        // 2026-09-05 a session read "connected" with packets flowing and no
        // sound, and nothing in the log could tell it from healthy playback.
        // `silent_s` is the field to read first. Device ids stay local.
        let dropped = self.engine.writeBacklogSnapshot().droppedWrites
        for level in self.engine.streamLevelSnapshot() {
            // Which speakers this stream actually serves: the per-app ids bound
            // to it PLUS the ids whose whole-system home it is. Before ticket 04
            // this read `streamBindings` alone, so under one-stream-per-speaker
            // every whole-system line named nobody and the log could not say
            // which speaker a stream belonged to.
            var deviceSet = Set(self.streamBindings.filter { $0.value == level.streamId }.keys)
            deviceSet.formUnion(self.wholeSystemStreamByDevice
                .filter { $0.value == level.streamId && self.added.contains($0.key) }.keys)
            let devices = deviceSet.sorted()
            Telemetry.log(.airplay, "stream_health", [
                "stream": "\(level.streamId)",
                "devices": devices.joined(separator: ","),
                "peak_dbfs": String(format: "%.1f", level.peakDBFS),
                "silent_s": String(format: "%.0f", level.silentSeconds),
                "writes": "\(level.writes)",
                "dropped_writes": "\(dropped)",
            ])
        }

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
    func addOrUpdate(_ discovered: DiscoveredDevice) {
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
    func rerunAppRoutesIfTargeted(_ id: String, wasEligible: Bool) {   // on stateQueue
        let isEligible = isRouteTargetEligibleLocked(id)
        guard isEligible != wasEligible, routesTargetDeviceLocked(id) else { return }
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
    func commitKnownDevice(_ id: String, _ device: Device) {   // on stateQueue
        let wasEligible = isRouteTargetEligibleLocked(id)
        known[id] = device
        emit(.deviceUpdated(device))
        rerunAppRoutesIfTargeted(id, wasEligible: wasEligible)
    }

    /// A device dropped off the network. It stays in the model as unavailable (so a
    /// saved group keeps its membership); it is removed from the streaming set.
    /// On `stateQueue`.
    func markDisappeared(_ id: String) {
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
        // disappears entirely — this is that site.
        if device.connectionState != .off { device.connectionState = .off; changed = true }
        if changed {
            // R5: a vanished device is unreachable, so any route aimed at it stops
            // being an effective redirect and that app rejoins the system mix. The
            // popover ALSO resets such a route (`handleDeviceDisappeared`), but the
            // backend must never depend on a UI layer for its own audibility.
            commitKnownDevice(id, device)
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
    func applyEngineState(outputID: OutputID, state: OutputState) {
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
                // The other `added` false→true site: an out-of-band reconnect
                // brings a device back into the EQ domain, so the plan has to
                // carry its stream again.
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
                    // The ONE event that explains the user-visible "engine state:
                    // failed" — a live AirPlay session dying. It was invisible in
                    // telemetry until now, so a dropped session had to be inferred
                    // from the absence of other events (live debug 2026-08-29,
                    // where that inference cost an afternoon and still landed on
                    // the wrong cause). The device id stays local — same rationale
                    // as `exclusion_changed`, it is what makes "why did it stop"
                    // legible on this Mac — and only the cause shape goes out.
                    Telemetry.fail(.airplay, "airplay:session_failed",
                                   local: ["device": id],
                                   shared: [
                                       "state": "\(state)",
                                       "cause": "\(cause)",
                                       "wasStreaming": wasStreaming ? "true" : "false",
                                   ])
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
    func mapDiscovered(_ discovered: DiscoveredDevice) -> Device {
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
    func merge(existing: Device, discovered: Device) -> Device {
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
    /// substring, so we prefer it and fall back to the service name.
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
    func engineVolume(forID id: String, uiVolume: Int) -> Double {
        if let companionTickParticipants, !companionTickParticipants.contains(id) {
            return known[id]?.supportsAirPlay2 == false ? -1.0 : 0.0
        }
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
    var masterGainFraction: Double {   // on stateQueue
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
    var volumeInFlight: Set<OutputID> = []
    /// The newest value queued behind an in-flight push for an id. Only the
    /// latest matters for volume (unlike add/remove ops), so a burst of pushes
    /// for one id (e.g. a fast slider drag) collapses to at most one extra call
    /// once the in-flight one completes, instead of replaying every
    /// intermediate value.
    var volumePending: [OutputID: (engineValue: Double, id: String, uiLevel: Int?,
                                          completion: (@Sendable (Bool) -> Void)?)] = [:]
    var lastVolumeOutcome: [OutputID: Bool] = [:]
    /// Bumped by ``stop()``. A volume completion carrying an older generation
    /// belongs to a torn-down engine session: its output ids and the in-flight
    /// bookkeeping now belong to a new one, so it must touch nothing.
    private var volumeGeneration = 0

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
    func pushVolume(_ outputID: OutputID, id: String, engineValue: Double, uiLevel: Int?,
                            completion: (@Sendable (Bool) -> Void)? = nil) {
        guard !volumeInFlight.contains(outputID) else {
            let previous = volumePending.updateValue(
                (engineValue, id, uiLevel, completion), forKey: outputID)
            previous?.completion?(false)
            return
        }
        volumeInFlight.insert(outputID)
        issueVolumePush(outputID, id: id, engineValue: engineValue, uiLevel: uiLevel,
                        completion: completion)
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
    func issueVolumePush(_ outputID: OutputID, id: String, engineValue: Double, uiLevel: Int?,
                                 completion: (@Sendable (Bool) -> Void)?) {
        let engine = self.engine
        let generation = volumeGeneration
        Task { [weak self] in
            var failed = false
            do {
                try await engine.setVolume(outputID, engineValue)
            } catch {
                failed = true
            }
            guard let self else { return }
            self.stateQueue.async {
                guard generation == self.volumeGeneration else { return }
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
                    self.issueVolumePush(outputID, id: next.id, engineValue: next.engineValue,
                                         uiLevel: next.uiLevel, completion: next.completion)
                } else {
                    self.volumeInFlight.remove(outputID)
                }
                self.lastVolumeOutcome[outputID] = !failed
                completion?(!failed)
                self.checkCompanionAuditionDrainLocked()
            }
        }
    }

    // MARK: Local optimistic updates + availability (on stateQueue)

    func applyLocal(_ id: String, _ change: (inout Device) -> Void) {   // on stateQueue
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
    // There is no poll loop or confirm re-GET here — the engine's completions
    // and state-stream transitions ARE ground truth, so
    // `.connecting → .connected`/`.failed` rides the SAME hooks that already drive
    // `isSelected`/`isAvailable` (converge success/failure, `applyEngineState`,
    // discovery loss) rather than a separate poll-derived stability window. AP1 and
    // AP2 receivers alike ride these hooks; only the local Mac output (never routed,
    // `setOutputSet` skips it) stays `.off` for its whole lifetime.

    /// Current lifecycle state for an id; absence means `.off`.
    func connectionState(of id: String) -> ConnectionState {   // on stateQueue
        known[id]?.connectionState ?? .off
    }

    /// Record a transition and echo it through the normal update machinery.
    /// `applyLocal` no-ops (and this is a no-op) for ids not yet discovered.
    func setConnectionState(_ state: ConnectionState, for id: String) {   // on stateQueue
        guard connectionState(of: id) != state else { return }
        applyLocal(id) { $0.connectionState = state }
        // Every connection-lifecycle edge can change "is any desired device audible":
        // a `→ .connected` re-engages the gate (clearing a silence fallback), a
        // `→ .failed`/`.off` for the last connected member arms the countdown (R11).
        reconcileSilenceWatchdog()
    }

    /// Enter the resting `.failed` state (converge add-throw or an out-of-band
    /// `.failed`/`.passwordRequired` from the engine's state stream). There is no
    /// separate diagnostics seam — the engine's completion IS the evidence — so
    /// causes come from the evidence already in hand: the converge catch maps `passwordRequired → .authRequired` and
    /// `opTimedOut → .timedOut` and always carries the engine error as `detail`,
    /// the connect-time PTP gate (T4) passes its own `cause`, and anything else
    /// stays `.unknown`. `detail` is what backs "Copy details" in the UI.
    private func enterFailure(_ id: String, cause: ConnectionFailure.Cause = .unknown, detail: String? = nil) {   // on stateQueue
        setConnectionState(.failed(ConnectionFailure(cause: cause, detail: detail)), for: id)
    }

    /// Recompute the effective (wire) volume after an unmute: push the stashed
    /// intended level and echo it locally. On `stateQueue`.
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
    func reconcileCaptureGate() {   // on stateQueue
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
        // A leveled app plays through the injector while the whole-system capture
        // runs and through the local engine while it doesn't — this edge is where
        // it changes hands.
        reconcileLeveledConsumersLocked(running: want)
        // W3-T3: streaming just started or stopped — re-evaluate the double-path
        // guard (it also depends on the system default output, which didn't
        // necessarily change here, but `captureRunning` — the other half of its
        // condition — just did).
        reconcileSystemAirPlayGuard()
        captureControlQueue.async {
            if want { coordinator.start() } else { coordinator.stop() }
        }
    }

    /// Move every LEVELED app between its two renderers on a `captureRunning`
    /// edge: while the whole-system capture runs its audio is summed into the
    /// program by `leveledInjector`, and while it doesn't there IS no program, so
    /// the app renders on the Mac through `localPlaybackEngine` at the same
    /// volume — the pipeline a `.currentDevice` app always uses. Exactly one of
    /// the two is live at a time, or the app would be heard twice.
    ///
    /// Called on `stateQueue` (it reads the leveled set and the route table) but
    /// does its work on `captureControlQueue`, where the local engine's graph
    /// mutations already live and where the gate's own start/stop is ordered.
    private func reconcileLeveledConsumersLocked(running: Bool) {   // on stateQueue
        let leveled = leveledBundleIDs
        let routes = lastRoutes.filter { leveled.contains($0.bundleID) }
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            if running {
                for bundleID in leveled { self.localPlaybackEngine?.removeApp(bundleID: bundleID) }
                self.leveledInjector.setActive(true)
                return
            }
            self.leveledInjector.setActive(false)
            // Same idempotent add-if-capturing shape `updateAppRoutes` uses for
            // `.currentDevice`: a tap that is not capturing yet gets its player
            // from `handleLocalCaptureStateChange` when it lands.
            for route in routes {
                if case .capturing(let format) = self.perAppCapture.state(for: route.bundleID) {
                    do {
                        try self.localPlaybackEngine?.start()
                        try self.localPlaybackEngine?.addApp(
                            bundleID: route.bundleID, tapFormat: format,
                            volume: Float(route.volume) / 100.0)
                    } catch {
                        Telemetry.fail(.localPlayback, "local_playback:start_failed",
                                       local: ["error": "\(error)"], shared: ["site": "leveled"])
                    }
                }
                self.localPlaybackEngine?.setVolume(
                    Float(route.volume) / 100.0, for: route.bundleID)
            }
        }
    }

    /// Display cadence for level emission (D3) — ~25 Hz, above the perception
    /// threshold for a VU meter but far below the ~86/s raw capture-buffer rate.
    let levelEmitIntervalNanos: UInt64 = 40_000_000

    /// What one coalesced meter event is FOR — a device row (`.level`) or an app
    /// row (`.appLevel`). An enum rather than a bare `String` so a bundle id can
    /// never collide with a device id in the shared maps below.
    enum LevelKey: Hashable {
        case device(String)
        case app(String)
    }

    /// Per-key leading-edge timestamp (`DispatchTime.now().uptimeNanoseconds`)
    /// of the last emitted meter event.
    var lastLevelEmitNanos: [LevelKey: UInt64] = [:]
    /// Per-key latest value seen while inside the coalescing window, delivered
    /// by the trailing flush.
    var pendingLevel: [LevelKey: Float] = [:]
    /// Keys with a trailing flush already scheduled, so a burst schedules at most
    /// one `asyncAfter` per key.
    var levelFlushScheduled: Set<LevelKey> = []

    /// The tap's IOProc delivery thread must not enqueue per buffer — a
    /// `stateQueue.async` allocates a block and takes the queue's lock on a
    /// real-time thread. It try-stores into this slot instead (the
    /// `EQProcessor.mailbox` shape: a contended `try()` skips, never blocks),
    /// and `drainSystemRMS` reads it on `stateQueue` at the D3 cadence.
    let systemRMSLock = NSLock()
    var systemRMSSlot: Float = 0      // systemRMSLock
    var systemRMSDirty = false        // systemRMSLock
    /// Whether a drain is already armed, so the chain stays single-flight.
    var levelDrainScheduled = false   // stateQueue

    /// When macOS last used each known BT pairing, keyed by `Device.id`
    /// (``BTDeviceSnapshot/lastUsed``). `Device` deliberately doesn't carry this
    /// yet — it's stashed here so the UI wave can filter/sort the ghost rows a
    /// forever-remembered pairing list produces, whatever surface it picks.
    /// Under its own lock rather than `stateQueue` because the popover reads it
    /// on the OPEN path, and `stateQueue` can be busy behind a converge.
    var btLastUsed: [String: Date] = [:]   // btLastUsedLock

    /// Each known pairing's device class (``BTDeviceSnapshot/deviceClassMinor``),
    /// stashed beside ``btLastUsed`` for the same reason: `known` is
    /// `stateQueue`-confined, and the settle record is assembled from three
    /// other queues, one of which is `stateQueue` itself.
    var btDeviceClassMinorByUID: [String: UInt32] = [:]   // btLastUsedLock

    /// Guards ``btLastUsed`` and ``btDeviceClassMinorByUID`` — see those
    /// properties' notes.
    let btLastUsedLock = NSLock()

    /// The ids the enumerator's LATEST merged list contains — i.e. every BT id
    /// macOS currently knows a pairing (or live endpoint) for. `nil` until the
    /// first snapshot arrives, so "not in the set" is never conflated with
    /// "enumeration hasn't run yet". A known `.bluetooth` row whose id is
    /// absent here has had its pairing record deleted out from under the app
    /// — the `.notPaired` fast-fail in ``retryBTOutput`` keys off this.
    /// On `stateQueue`.
    var btPairedIDs: Set<String>?
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
final class ResumeOnce: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func resume() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
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
