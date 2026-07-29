import Foundation
import AirPlayEngine

#if canImport(CoreAudio)
import CoreAudio
#endif

#if canImport(AudioToolbox)
import AudioToolbox
import AVFoundation
#endif

/// Owns the IN-PROCESS Core Audio capture pipeline for the native path
/// (T-NB-CAPTURE-1): create a system-audio process tap, read its REAL format,
/// convert each captured buffer to the one PCM format the engine accepts
/// (S16LE / 44100 / 2ch — ``AirPlayEngine/PCMFormat/airplay``), and hand it to
/// ``PCMSink/write(pcm:pts:)`` with a per-buffer presentation timestamp taken
/// straight off the IOProc's `AudioTimeStamp.mHostTime`.
///
/// This is the native-path analogue of ``CaptureCoordinator`` — but structurally
/// SIMPLER, not a port: there is no FIFO, no subprocess, no OwnTone library
/// rescan and no `pipe_sample_rate` reconcile. Capture runs inside the app
/// process (D2) so the `pts` comes for free from the tap's own clock and there is
/// zero IPC. The old coordinator's suspend-to-pause / zombie-replay machinery has
/// no equivalent here (nothing to re-kick — a session failure is reported by the
/// engine, not a paused file player).
///
/// ## The Phase-0 config-follows-tap invariant, applied
/// The engine is HARDWIRED to S16LE / 44100 / 2ch — there is no engine "quality"
/// setter (``AirPlayEngine/AirPlayEngine/write(pcm:pts:)`` always tags the buffer
/// as `PCMFormat.airplay`, and the vendored `conffile` shim exposes no rate/format
/// knob). So "config-follows-tap" here means: READ the tap's real ASBD (never
/// assume 48k/2ch/Float), then CONVERT that real format down to the engine's fixed
/// format — resampling only when the tap rate genuinely differs from 44100, and
/// matching channel count / interleaving / sample type as the real ASBD dictates.
/// The tap rate tracks the current default output device, so it is read at tap
/// creation and re-read whenever the default output device changes.
///
/// ## Lifecycle (the state machine — see ``State``)
/// ```
///  idle ──start()──▶ creatingTap ──▶ capturing(TapFormat)
///                                          │
///        (default output device changed)   │ recreate tap w/ new format
///                                          ▼
///                                     capturing(TapFormat')
///  capturing ──stop()──▶ stopping ──▶ idle
///  <any> ── tap-creation failure / device loss ──▶ failed(error)
/// ```
///
/// ## Testability
/// Every external dependency is injected behind a protocol — ``SystemAudioTap``
/// (the Core Audio tap: no TCC, no aggregate device in tests), ``PCMSink`` (the
/// engine's `write`, a spy in tests), and ``PCMConverting`` (the format
/// conversion). Unit tests drive the whole machine hermetically: create → push
/// buffers with advancing `mHostTime` → assert converted-and-forwarded →
/// device-change → stop → error surfaced — WITHOUT a real tap or a real engine.
public final class NativeCaptureCoordinator: @unchecked Sendable {

    // MARK: State machine

    /// The coordinator's observable lifecycle state. A UI can render this
    /// directly ("starting capture…", "audio device changed", "capture failed").
    /// Every error path funnels into `.failed`.
    public enum State: Equatable, Sendable {
        /// Not running. `start()` moves out of here; `stop()` returns here.
        case idle
        /// Creating the process tap + aggregate device (may trigger the TCC
        /// system-audio-recording prompt on first ever run).
        case creatingTap
        /// Steady state: the tap is running and buffers are being converted and
        /// forwarded to the engine. Carries the tap's real captured format.
        case capturing(TapFormat)
        /// Tearing the tap + aggregate device down.
        case stopping
        /// A terminal-until-restart error. `start()` from here resets and retries;
        /// `stop()` from here still cleans up and returns to `.idle`.
        case failed(NativeCaptureError)
    }

    // MARK: Injected dependencies

    private let makeTap: @Sendable () -> SystemAudioTap

    /// Resolves the CURRENT default output device id (a cheap
    /// `kAudioHardwarePropertyDefaultOutputDevice` read), or `nil` when it can't
    /// be read. Used by ``recreateTap(cause:)`` to tell a device-IDENTITY change
    /// (new default != the device the old tap was anchored to) from a same-device
    /// rate rebuild, which is the gate for make-before-break (audio-leak-on-device-
    /// switch fix). Injected so the decision is hermetically testable; defaults to
    /// `{ nil }` (always break-before-make — today's behavior) for tests that don't
    /// exercise it, and is wired to `CoreAudioSystemTap.defaultOutputDeviceID()` at
    /// the one production construction site.
    private let resolveDefaultOutputDeviceID: @Sendable () -> AudioObjectID?

    private let sink: PCMSink
    private let makeConverter: @Sendable (TapFormat) -> PCMConverting
    private let muteBehavior: TapMuteBehavior

    /// Bundle ID -> the FULL set of live Core Audio process objects (main +
    /// every child/helper) for the exclusion list (T4/T-LEAK-FIX). A
    /// multi-process browser (Firefox, Chrome) emits audio from a CHILD
    /// process with no bundle id of its own, so resolving to a single pid
    /// (the old shape) named the silent main process and left the real
    /// audio child leaking into the whole-system mix. `AudioProcessResolver`
    /// itself is pure Core Audio + Darwin, but its `bundleIDForPID` closure
    /// is AppKit-only (`NSRunningApplication`), so `AudiouterCore` cannot
    /// construct the fully-wired resolver itself (package rule,
    /// `AudiouterCore/AGENTS.md`) — mirrors `PerAppCaptureCoordinator`'s
    /// injected resolver exactly. Defaults to a resolver over an empty
    /// enumerator ("nothing resolves"), which reproduces today's
    /// always-empty exclusion list until an AppKit-importing layer supplies
    /// the real one (T6).
    private let processResolver: AudioProcessResolver

    /// T7: the audio I/O workgroup seam. The coordinator owns the LIFECYCLE
    /// (when to join, when to leave, in what order); the seam owns getting each
    /// call onto the thread that may legally perform it.
    ///
    /// Deliberately driven from here rather than from ``NativeBackend``: this
    /// type is the only one that knows when an aggregate device comes into and
    /// goes out of existence, and every one of the join/leave edges is an edge of
    /// THIS state machine (`start` / `stop` / `recreateTap`). `nil` disables the
    /// whole feature (the default for tests that aren't about it).
    private let workgroup: AudioIOWorkgroupJoining?

    /// Test-only opt-out for the W1-T7 Gap 1 process-object-list listener: `false`
    /// skips ever registering the real HAL listener on `start()`, so a hermetic
    /// suite that drives ``handleMembershipChange()``/``handleProcessListChanged()``
    /// directly never touches Core Audio and never has a live listener fire
    /// mid-test. Defaults to `true` — production behavior, unchanged.
    private let installsProcessListListener: Bool

    // MARK: State (confined to `queue`)

    private let queue = DispatchQueue(label: "NativeCaptureCoordinator.state")
    private var _state: State = .idle
    private var tap: SystemAudioTap?
    private var converter: PCMConverting?

    // MARK: The real-time buffer snapshot (T8)

    /// Everything ``handleBuffer(_:)`` needs, frozen into ONE immutable object so
    /// the real-time tap-delivery thread can pick it up with a single reference
    /// read instead of a `queue.sync` (T8 / plan finding F12).
    ///
    /// Immutable by construction: every field is a `let` and the object is never
    /// mutated after `init`. Publishing is therefore a whole-object REFERENCE
    /// SWAP, which is what makes a torn read structurally impossible — the RT
    /// thread can only ever observe a complete, self-consistent set of the four
    /// values, never a half-updated one (the failure mode the plan flags: a
    /// converter pointer read mid-teardown).
    private final class BufferSnapshot {
        let converter: PCMConverting?
        let meteringActive: Bool
        let syncedLocalSink: SyncedLocalPCMSink?
        let syncedLocalBaseResampler: SyncedLocalBaseResampler?

        /// The published value before anything has been started, and the value
        /// every teardown path returns to: no converter, so ``handleBuffer(_:)``
        /// drops the buffer at its first guard.
        static let empty = BufferSnapshot(
            converter: nil, meteringActive: false,
            syncedLocalSink: nil, syncedLocalBaseResampler: nil)

        init(
            converter: PCMConverting?,
            meteringActive: Bool,
            syncedLocalSink: SyncedLocalPCMSink?,
            syncedLocalBaseResampler: SyncedLocalBaseResampler?
        ) {
            self.converter = converter
            self.meteringActive = meteringActive
            self.syncedLocalSink = syncedLocalSink
            self.syncedLocalBaseResampler = syncedLocalBaseResampler
        }
    }

    /// Guards ONLY the `_bufferSnapshot` reference — one pointer read on the RT
    /// side, one pointer write on the publish side, nothing else. NEVER held
    /// across a Core Audio / HAL / converter call, and never held while waiting
    /// on `queue`.
    ///
    /// This is the same shape ``LocalPlaybackEngine`` (and ``SyncedLocalSink``)
    /// already use for exactly this problem: a plain `NSLock` whose critical
    /// sections are a few instructions, taken NON-blockingly (`try()`) from the
    /// real-time thread so a graph/state mutation can never make the audio
    /// thread wait. `queue` — an unqualified, default-QoS serial queue that
    /// `start`/`stop`/`recreateTap`/`updateRouting` all take — is no longer
    /// touched from the RT path at all, which is the whole point: a `queue.sync`
    /// from the IOProc could block behind a lower-priority holder (priority
    /// inversion → audible stutter under load).
    private let snapshotLock = NSLock()

    /// The currently published snapshot. Written only via
    /// ``publishBufferSnapshot()`` (always while holding `queue`, so the
    /// published value is consistent with the queue-confined state it mirrors);
    /// read only by ``handleBuffer(_:)``.
    private var _bufferSnapshot: BufferSnapshot = .empty

    /// STABILITY(C6): set when a rebuild trigger — a default-output-device
    /// change (`handleDeviceChange()`), or an exclusion-list change
    /// (`updateRouting(...)`) — arrives while we're already mid-rebuild
    /// (`.creatingTap`), so it isn't silently dropped. The in-flight
    /// `recreateTap()` replays a fresh rebuild once it lands back in
    /// `.capturing`, coalescing however many were dropped into one retry.
    /// Confined to `queue`, which is also ``TapRebuildCoalescer``'s lock
    /// contract. See dev/notes/stability-audit-2026-07-18.md §C6.
    ///
    /// Single-sourced with `PerAppCaptureCoordinator.Slot.rebuildCoalescer` —
    /// the mechanism used to be written out twice (architecture review
    /// 2026-07-26, defect A).
    private var rebuildCoalescer = TapRebuildCoalescer()

    /// Whether RMS should be computed and handed to `onLevel` (T-GATE). `false`
    /// until ``setMeteringActive(_:)`` first flips it on — the popover isn't shown
    /// yet at coordinator construction, so there's nobody to render a meter for.
    /// Confined to `queue`, same as every other piece of state here.
    private var meteringActive = false

    /// The live union of routed-away (`.device` destination) and
    /// user-excluded bundle IDs, as last computed by
    /// ``updateRouting(appRoutes:excludedBundleIDs:)``. Confined to `queue`.
    /// Applied to the NEXT tap creation (initial `start()`, a device-change
    /// recreate, or an exclusion-change recreate) — never mutates a tap
    /// that's already running without going through a recreate.
    private var currentExcludedBundleIDs: Set<String> = []

    /// T-FANOUT: the delayed local sink to ALSO feed (the "play everywhere" second
    /// consumer), and the pid of the process that RENDERS its output — our own
    /// process, since the sink is an in-process `AVAudioEngine`. Both queue-confined
    /// and set together via ``setSyncedLocalSink(_:renderProcessPID:)``.
    ///
    /// `syncedLocalRenderPID` is resolved to its process object and unioned into
    /// every tap's exclusion set (``resolveExcludedProcessObjectIDs()``) so the
    /// whole-system tap never re-captures the
    /// sink's own delayed output as an echo (plan risk R2 / brief §8). Because the
    /// tap is `.mutedWhenTapped`, excluding our process ALSO keeps that delayed
    /// output audible while the raw system mix stays muted — exactly the intent.
    /// Both `nil` = play-everywhere off: no fan-out and no self-exclude, i.e.
    /// today's behavior.
    private var syncedLocalSink: SyncedLocalPCMSink?
    private var syncedLocalRenderPID: pid_t?

    /// T3 (Part B) base-rate converter for the fan-out: resamples the 44.1 kHz
    /// airplay feed UP to the sink's device-native `renderSampleRate` ONCE before
    /// the ring, so the sink's engine runs at the output device's own rate and
    /// opening it never renegotiates 48↔44.1 kHz (the dropout root cause). Held
    /// here (not in ``fanOutToSyncedLocal``, which is stateless/static) because a
    /// streaming resampler must carry its filter state across delivery buffers —
    /// a fresh one per buffer would click at every boundary. Queue-confined:
    /// created/cleared under `queue` alongside `syncedLocalSink` in
    /// ``setSyncedLocalSink(_:renderProcessPID:)``, republished into the
    /// real-time ``BufferSnapshot`` at the same moment (T8) and read from there
    /// by ``handleBuffer(_:)``, then run only on the single tap-delivery thread.
    /// Deliberately NOT a ``FractionalResampler`` — that stays the sink's ppm
    /// DRIFT corrector at ratio ≈ 1; base conversion is a distinct step here.
    private var syncedLocalBaseResampler: SyncedLocalBaseResampler?

    /// W1-T7 (Gap 1 + Fix 1): the excluded process-OBJECT set the CURRENT live tap
    /// was last built/recreated against — the compare-before-rebuild key for the
    /// two exclusion-refresh entry points that can fire WITHOUT a bundle-ID-union
    /// change: ``refreshExcludedProcessSet(forRelaunchedBundleID:)`` (an excluded
    /// app relaunched) and ``handleMembershipChange()`` (an excluded app spawned or
    /// dropped an audio child mid-session). Because ``resolveExcludedProcessObjectIDs()``
    /// only yields objects for processes that currently HAVE a Core Audio object, an
    /// excluded app going silent→audible on the SAME pid moves this set — so the
    /// object-level compare also catches the "excluded app becomes audible" leak a
    /// bundle-ID-only compare misses. Recorded ONLY on a SUCCESSFUL `.capturing`
    /// commit (initial `start()` or a `recreateTap()`); a failed rebuild never
    /// advances it, so it can't suppress a later needed rebuild. Confined to `queue`.
    private var lastExcludedObjects: Set<AudioObjectID> = []

    // MARK: Live-membership diffing on the exclusion side (W1-T7, Gap 1)
    //
    // Closes the mid-session leak `updateRouting`/`refreshExcludedProcessSet` both
    // miss: an ALREADY-excluded app (a routed-away or user-excluded browser) spawns
    // a new audio child WITHOUT relaunching — that child was never in the exclusion
    // list, so its audio leaks into the whole-system mix until some unrelated rebuild
    // trigger. A system-wide process-object-list listener fires once per process
    // connecting/disconnecting (browsers churn it as tabs open/close), so
    // notifications are DEBOUNCED onto a dedicated serial queue and only the last one
    // in a burst runs the diff; the diff COMPARES-BEFORE-REBUILD against
    // `lastExcludedObjects` so an unchanged resolved object set does ZERO Core Audio
    // work (the CPU-storm loop-breaker). A genuine change recreates the tap as a
    // benign `.exclusionChange` (device/clock unchanged → no AirPlay session reset).

    #if canImport(AudioToolbox)
    /// System-wide "a process's audio object appeared/disappeared" listener.
    /// Registered ONCE, lazily, on the first `start()` and removed in `deinit`
    /// — paired add/remove, no leak (same structural discipline as
    /// ``PerAppCaptureCoordinator``'s resume listener). Touched only on ``queue``.
    private var processListBlock: AudioObjectPropertyListenerBlock?

    /// The one address the block is registered on. A `let` so add and remove
    /// can never drift apart.
    private static let processObjectListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    #endif

    /// Dedicated DEBOUNCED serial queue owning the membership-diff timer.
    /// DISTINCT from ``queue`` on purpose: `handleMembershipChange` reaches into
    /// the state via `queue.sync`, which would deadlock if it were itself
    /// running on `queue`. Mirrors ``PerAppCaptureCoordinator``'s `membershipQueue`.
    private let membershipQueue = DispatchQueue(label: "NativeCaptureCoordinator.membership")
    /// The pending coalesced diff. Confined to ``membershipQueue``. Cancelled and
    /// replaced by each new notification inside the debounce window, so a rapid
    /// spawn/kill/spawn burst collapses to a single diff pass.
    private var membershipDiffWork: DispatchWorkItem?
    /// How long to wait for process-list churn to settle before diffing.
    /// Injectable so tests can shrink it; production default coalesces a burst
    /// of tab open/close notifications into one rebuild.
    private let membershipDebounceInterval: DispatchTimeInterval

    /// Fired on every state transition so a UI (or a test) can observe the
    /// lifecycle. Called on the coordinator's internal queue.
    public var onStateChange: (@Sendable (State) -> Void)?

    /// Fired when the tap was rebuilt specifically because the tapped OUTPUT
    /// DEVICE changed or renegotiated its nominal sample rate
    /// (``handleDeviceChange()``) — the ONLY rebuild that leaves the AirPlay RTP
    /// timeline desynced from its receivers and therefore needs a whole-system
    /// session reset (``NativeBackend`` wires this to
    /// `resetAirPlaySessionForWholeSystem`).
    ///
    /// Deliberately NOT fired for a rebuild caused by an exclusion-set change
    /// (``updateRouting(appRoutes:excludedBundleIDs:)`` /
    /// ``setSyncedLocalSink(_:renderProcessPID:)``) — UNLESS that rebuild is observed
    /// to have re-anchored the clock anyway (the device or nominal rate the new tap
    /// came up on differs from the outgoing tap's), which the cause alone cannot
    /// report: the default output device can move in the window where neither the old
    /// nor the new tap holds a listener. Those are otherwise benign,
    /// backend-initiated parts of NORMAL connect/route setup — in particular,
    /// attaching the synced-local sink adds its render pid to the exclusion set,
    /// which recreates the tap on EVERY Mac+AirPlay connect. The output device and
    /// its clock are unchanged across such a rebuild, so the receivers' timeline
    /// stays intact; firing a session reset there re-established the RTP session
    /// (a full removeOutput→addOutput) on every connect — "connects fast, then a
    /// long silence before audio comes out." Distinguishing the cause (only a
    /// device/rate rebuild resets) is what keeps first-connect latency at the
    /// pre-T2 baseline without reintroducing the dropout the reset was added for.
    /// Called on the coordinator's internal queue, like ``onStateChange``.
    public var onDeviceRateRebuild: (@Sendable () -> Void)?

    /// Fired once per converted buffer with the buffer's peak/RMS level in
    /// 0.0...1.0, so a caller (``NativeBackend``) can plumb it straight into
    /// `BackendEvent.level` without recomputing it. Called from the tap's IOProc
    /// delivery thread — keep the handler cheap and lock-light. (Metering is
    /// upstream of the engine per playback-meter-research.md: it's a property of
    /// the captured audio, identical for every fanned-out device.)
    public var onLevel: (@Sendable (_ rms: Float) -> Void)?

    /// The current state (thread-safe snapshot).
    public var state: State { queue.sync { _state } }

    // MARK: Init

    /// Production initializer: wires the real Core Audio process tap, the engine
    /// as the PCM sink, and the AVAudioConverter-backed format converter.
    ///
    /// - Parameters:
    ///   - engine: the ``AirPlayEngine`` to feed. `write(pcm:pts:)` is the only
    ///     method used (nonisolated, fire-and-forget), so the sink is the engine
    ///     itself via ``AirPlayEngine`` conforming to ``PCMSink``.
    ///   - processResolver: bundle ID -> the full set of live Core Audio
    ///     process objects, for the live exclusion list (T4 — apps
    ///     individually routed elsewhere, or user-excluded via Settings,
    ///     must not double up into the system-wide mix). Defaults to a
    ///     resolver that always resolves to the empty set (today's
    ///     behavior: an always-empty exclusion list) until an
    ///     AppKit-importing layer wires the real one (T6).
    ///   - name: a short label used for the private tap/aggregate device name.
    ///   - muteBehavior: `.mutedWhenTapped` (default) silences local playback
    ///     while capturing — matching the native-path intent (audio goes to the
    ///     receivers, not the built-in speakers). `.unmuted` mirrors it locally.
    #if canImport(AudioToolbox)
    public convenience init(
        engine: AirPlayEngine,
        processResolver: AudioProcessResolver = AudioProcessResolver(enumerator: EmptyAudioProcessEnumerator()),
        name: String = "Audiouter",
        muteBehavior: TapMuteBehavior = .mutedWhenTapped
    ) {
        self.init(
            makeTap: {
                if #available(macOS 14.2, *) {
                    return CoreAudioSystemTap(name: name)
                } else {
                    return UnavailableSystemTap()
                }
            },
            sink: EngineSink(engine: engine),
            makeConverter: { format in AVFormatConverter(from: format) },
            // Make-before-break identity gate (audio-leak-on-device-switch fix): a
            // single default-output-device read. Pre-14.2 has no live capture, so
            // nil (-> break-before-make) is correct there.
            resolveDefaultOutputDeviceID: {
                if #available(macOS 14.2, *) { return try? CoreAudioSystemTap.defaultOutputDeviceID() }
                return nil
            },
            processResolver: processResolver,
            muteBehavior: muteBehavior,
            // T7: the same engine, as the workgroup target. Wired here (the one
            // production construction site, via `OwnToneBackend`) rather than
            // through `NativeBackend`, since the engine is already in hand and
            // every join/leave edge belongs to this coordinator's state machine.
            workgroup: EngineIOWorkgroup(engine: engine)
        )
    }
    #endif

    /// Injectable designated initializer (internal — tests pass fakes for all
    /// three seams so the state machine runs without a real tap or engine).
    /// `processResolver` defaults to a real ``AudioProcessResolver`` (its own
    /// production init), matching this initializer's other real-by-default
    /// seams (`AVFormatConverter` etc. are supplied by the convenience init,
    /// not here — but `processResolver`'s default is safe to share between
    /// both inits since, unlike `makeTap`/`sink`, it touches no Core Audio
    /// TCC-gated capture API, only a plain process-list/tree read).
    init(
        makeTap: @escaping @Sendable () -> SystemAudioTap,
        sink: PCMSink,
        makeConverter: @escaping @Sendable (TapFormat) -> PCMConverting,
        resolveDefaultOutputDeviceID: @escaping @Sendable () -> AudioObjectID? = { nil },
        processResolver: AudioProcessResolver = AudioProcessResolver(enumerator: EmptyAudioProcessEnumerator()),
        muteBehavior: TapMuteBehavior = .mutedWhenTapped,
        workgroup: AudioIOWorkgroupJoining? = nil,
        membershipDebounceInterval: DispatchTimeInterval = .milliseconds(300),
        installsProcessListListener: Bool = true
    ) {
        self.makeTap = makeTap
        self.resolveDefaultOutputDeviceID = resolveDefaultOutputDeviceID
        self.sink = sink
        self.makeConverter = makeConverter
        self.processResolver = processResolver
        self.muteBehavior = muteBehavior
        self.workgroup = workgroup
        self.membershipDebounceInterval = membershipDebounceInterval
        self.installsProcessListListener = installsProcessListListener
    }

    /// Tears down the process-object-list listener installed by the first
    /// `start()` (W1-T7, Gap 1). Symmetric removal — the block captures `self`
    /// weakly, so a block mid-flight holds a strong reference and `deinit` cannot
    /// run concurrently with one (same argument ``PerAppCaptureCoordinator.deinit``
    /// makes). The tap itself is torn down by its own `deinit` backstop. Does NOT
    /// additionally drop workgroup membership here — `stop()` already does that
    /// on every path this coordinator's owner is expected to use, and deinit
    /// running ahead of a `stop()` call is a pre-existing gap in the T7 workgroup
    /// feature, not something this merge should silently paper over.
    deinit {
        #if canImport(AudioToolbox)
        removeProcessListListenerLocked()
        membershipQueue.sync { membershipDiffWork?.cancel(); membershipDiffWork = nil }
        #endif
    }

    // MARK: Public lifecycle (idempotent)

    /// Start capture: create the tap, read its real format, register the delivery
    /// callback + the default-output-device-change callback, and start the IOProc.
    /// Idempotent: `start()` while already creating/capturing is a no-op. `start()`
    /// from `.failed` resets and retries.
    ///
    /// Structured as claim-under-lock / create-off-lock / commit-under-lock — the
    /// same shape `recreateTap()` uses — so the blocking `createAndStart` HAL call
    /// never runs while holding `queue` (which would head-of-line block the `state`
    /// getter and a concurrent `stop()`; since T8 it no longer blocks `handleBuffer`,
    /// which never takes `queue` at all — but the rule stands). A `stop()`
    /// racing in during the off-lock create must WIN: the commit re-checks the state
    /// and, if `stop()` already moved us out of `.creatingTap`, discards the
    /// just-created tap (torn down OUTSIDE the lock, since its IO callback also takes
    /// `queue`).
    public func start() {
        // Claim: only proceed from idle/failed; move to .creatingTap and snapshot
        // the exclusion pids (queue-confined) under a SHORT lock.
        let claim: (proceed: Bool, excludedProcessObjectIDs: Set<AudioObjectID>) = queue.sync {
            #if canImport(AudioToolbox)
            // First start of this coordinator's life arms the system-wide
            // process-object-list listener (idempotent) — the signal that drives
            // live exclusion-membership diffing (W1-T7, Gap 1). Doing it here, not
            // in `init`, keeps a coordinator that never starts from touching the HAL.
            installProcessListListenerLocked()
            #endif
            switch _state {
            case .idle, .failed:
                self.transition(to: .creatingTap)
                return (true, resolveExcludedProcessObjectIDs())
            default:
                return (false, []) // already in flight — idempotent
            }
        }
        guard claim.proceed else { return }

        // Wire callbacks BEFORE creating the tap so no early buffer is dropped.
        let newTap = makeTap()
        newTap.onBuffer = { [weak self] buffer in self?.handleBuffer(buffer) }
        newTap.onDefaultDeviceChanged = { [weak self] in self?.handleDeviceChange() }

        do {
            // Blocking HAL work OUTSIDE the lock.
            let format = try newTap.createAndStart(
                muteBehavior: muteBehavior, excludedProcessObjectIDs: claim.excludedProcessObjectIDs)
            try Self.validate(format)
            let orphan: SystemAudioTap? = queue.sync {
                // A stop() may have raced in while we were creating: don't clobber an
                // idle/stopping state with a fresh capturing one — stop() wins.
                guard case .creatingTap = _state else {
                    return newTap // orphan; tear down OUTSIDE the lock
                }
                self.tap = newTap
                self.converter = makeConverter(format)
                self.publishBufferSnapshot()
                self.lastExcludedObjects = claim.excludedProcessObjectIDs // W1-T7 compare-before-rebuild baseline
                self.transition(to: .capturing(format))
                return nil
            }
            orphan?.teardown()
            // T7 EDGE 1 — join the engine thread to the AGGREGATE's I/O workgroup,
            // now that the aggregate exists and we have actually committed to
            // `.capturing`. Skipped when `orphan != nil`: a racing `stop()` won, the
            // tap we just built is being destroyed, and joining a workgroup we are
            // about to tear down would only have to be unwound again. Fired OFF the
            // state lock, like every other handler call in this file.
            if orphan == nil, let id = newTap.workgroupDeviceID {
                workgroup?.join(deviceID: id)
            }
        } catch {
            // createAndStart may have created the tap/aggregate before failing on a
            // later step; tear it down so we don't leak a system-wide process tap.
            newTap.teardown()
            let mapped: NativeCaptureError = (error as? NativeCaptureError)
                ?? .tapCreationFailed(reason: String(describing: error))
            queue.sync {
                // Only surface the failure if we still own the start (a racing stop()
                // that already reset us to idle/stopping wins).
                guard case .creatingTap = _state else { return }
                self.tap = nil
                self.converter = nil
                self.publishBufferSnapshot()
                self.transition(to: .failed(mapped))
            }
        }
    }

    /// Stop capture: tear the tap + aggregate device down. Idempotent: `stop()`
    /// from `.idle` is a no-op.
    public func stop() {
        let toTearDown: SystemAudioTap? = queue.sync {
            switch _state {
            case .idle:
                return nil
            default:
                let t = self.tap
                self.transition(to: .stopping)
                return t
            }
        }
        // T7: drop the workgroup membership BEFORE the aggregate that published it
        // is destroyed, so the leave is never issued against an object the HAL has
        // already reclaimed. (The shim holds its own +1 on the workgroup, so a late
        // leave would still be memory-safe — but "leave while the thing is alive"
        // is the order the API is specified in, and it costs nothing to keep.)
        // Unconditional: `leave()` is idempotent, so a `stop()` from a state that
        // never joined is a no-op.
        if toTearDown != nil { workgroup?.leave() }
        // Tear down OUTSIDE the state lock (teardown may block on Core Audio).
        toTearDown?.teardown()
        queue.sync {
            self.tap = nil
            self.converter = nil
            self.publishBufferSnapshot()
            self.transition(to: .idle)
        }
    }

    /// Gate RMS computation/emission on or off (T-GATE). Independent of
    /// `start()`/`stop()`: this is the popover-visibility gate, not the capture
    /// gate — the tap may be running (a real AP2 output is selected) while
    /// metering stays off (the popover is closed), and vice versa is harmless
    /// (metering active with the tap idle just means nothing fires yet).
    public func setMeteringActive(_ active: Bool) {
        queue.async {
            self.meteringActive = active
            self.publishBufferSnapshot()
        }
    }

    /// Recompute the live exclusion set for the system-mix tap (T4): every
    /// routed-away bundle ID — `appRoutes` entries whose destination is
    /// `.device(id:)` — UNION every user-excluded bundle ID (Settings ›
    /// Audio's separate opt-out list; composed here rather than merged into
    /// either controller, so the two stores stay independent per
    /// `AppRoutingController`'s own doc comment). Apps left on
    /// `.noRedirect` or `.currentDevice` are NEVER included — they must keep
    /// flowing into the system mix (and into Selected Devices, if active).
    ///
    /// No-op unless the union actually differs from what's currently
    /// applied, so an unrelated call (e.g. re-passing the same routes on an
    /// unrelated tick) never recreates the tap. When it does differ: if a
    /// tap is currently `.capturing`, it's recreated immediately so the new
    /// exclusion list takes effect without waiting for the next device
    /// change; otherwise the new set is simply stored for the next
    /// `start()`.
    ///
    /// A later task (T6) is expected to call this from an AppKit-importing
    /// layer (`NativeBackend`/`AppDelegate`) whenever `AppRoutingController`
    /// or `ExcludedAppsController` mutate.
    public func updateRouting(appRoutes: [AppRoute], excludedBundleIDs: Set<String>) {
        let routedAway = Set(appRoutes.compactMap { route -> String? in
            guard case .device = route.destination else { return nil }
            return route.bundleID
        })
        let union = routedAway.union(excludedBundleIDs)

        let needsRecreate: Bool = queue.sync {
            guard union != currentExcludedBundleIDs else { return false }
            currentExcludedBundleIDs = union
            let capturing: Bool
            if case .capturing = _state { capturing = true } else { capturing = false }
            // Telemetry (T2): the exclusion-list choke point — the only place
            // the live routed/excluded union actually changes. Cleartext
            // bundle IDs are deliberate (PLAN-TELEMETRY-SYSTEM.md Q6): this is
            // exactly what makes "why did the system tap just rebuild" legible.
            Telemetry.log(.captureWS, "exclusion_changed", [
                "excludedCount": "\(union.count)",
                "excluded": union.sorted().joined(separator: ","),
                "recreate": capturing ? "true" : "false",
            ])
            return capturing
        }
        guard needsRecreate else { return }
        // Exclusion-set change only (routed/excluded apps): the tapped output device
        // and its clock are unchanged, so this rebuild does NOT desync the AirPlay
        // receivers — no whole-system session reset (see `onDeviceRateRebuild`).
        recreateTap(cause: .exclusionChange)
    }

    /// Attach (or detach, with `nil`) the delayed local sink fan-out (T-FANOUT),
    /// and the pid of the process that renders its output. Both move together: a
    /// non-nil `sink` turns the fan-out ON and adds `renderProcessPID` to the
    /// whole-system tap's exclusion set so the sink's own delayed audio is never
    /// re-captured as an echo (R2 / brief §8); `nil` turns both off.
    ///
    /// If a tap is currently `.capturing` AND the exclusion pid actually changes,
    /// the tap is recreated immediately so the new exclusion takes effect without
    /// waiting for a device change — mirroring
    /// ``updateRouting(appRoutes:excludedBundleIDs:)``. Otherwise the new pid is
    /// simply applied at the next tap creation. ``NativeBackend`` calls this when
    /// the selection enters/leaves "play everywhere" mode; it supplies the
    /// render-process identity (its own `getpid()`, since the sink renders
    /// in-process).
    public func setSyncedLocalSink(_ sink: SyncedLocalPCMSink?, renderProcessPID: pid_t?) {
        let needsRecreate: Bool = queue.sync {
            self.syncedLocalSink = sink
            // Build the base-rate converter for THIS sink's render rate (read once
            // at sink construction, T3 Part B). A brand-new instance per attach so
            // its streaming filter state starts clean and a rate change between
            // attaches is honored; cleared on detach.
            if let sink {
                self.syncedLocalBaseResampler = SyncedLocalBaseResampler(
                    inputRate: Double(PCMFormat.airplay.sampleRate),
                    outputRate: sink.renderSampleRate,
                    channelCount: PCMFormat.airplay.channels)
            } else {
                self.syncedLocalBaseResampler = nil
            }
            // T8: both fan-out fields moved together above, so republish the RT
            // snapshot HERE — before the early `return false` below, which is
            // taken whenever the exclusion pid is unchanged (detach/re-attach of
            // the same sink) and would otherwise leave the RT path fanning out
            // into the previous sink.
            self.publishBufferSnapshot()
            let newPID: pid_t? = (sink == nil) ? nil : renderProcessPID
            guard newPID != syncedLocalRenderPID else { return false }
            syncedLocalRenderPID = newPID
            if case .capturing = _state { return true }
            return false
        }
        guard needsRecreate else { return }
        // Exclusion-set change only (adding/removing the synced-local sink's own
        // render pid): the tapped output device and its clock are unchanged, so this
        // rebuild does NOT desync the AirPlay receivers — no whole-system session
        // reset. Attaching the sink hits this on EVERY Mac+AirPlay connect; treating
        // it as a rate-renegotiation recapture is what added a redundant RTP
        // re-establish (a long post-connect silence) to every connect. See
        // `onDeviceRateRebuild`.
        recreateTap(cause: .exclusionChange)
    }

    // MARK: Start sequence (on `queue`)

    /// Reject a tap format the converter/aggregate can't safely consume before it
    /// commits to `.capturing`. A non-positive sample rate makes the converter's
    /// resample ratio infinite and its `AVAudioFrameCount` conversion trap; the
    /// real tap's `createTapAndReadFormat` already guards the raw ASBD (incl. NaN,
    /// which can't survive the `Int` narrowing into `TapFormat`), but validating
    /// here also covers an injected/degenerate format and keeps the failure on the
    /// `.failed` state path rather than a crash.
    static func validate(_ format: TapFormat) throws {
        guard format.sampleRate > 0 else {
            throw NativeCaptureError.formatReadFailed(
                reason: "invalid tap sample rate \(format.sampleRate)")
        }
    }

    /// Resolve the live excluded-bundle-ID set to the UNION of every
    /// resolved bundle's FULL Core Audio process-object set (main + every
    /// child/helper) via the injected ``processResolver`` — the fix for the
    /// multi-process leak: a bundle id that resolves to only its silent main
    /// process previously left the real audio-emitting child unexcluded.
    /// Best-effort: a bundle ID with no resolvable process yet (not
    /// launched, or not yet audible) contributes nothing rather than failing
    /// tap creation — the whole-system tap must still succeed even if one
    /// excluded app isn't resolvable yet. MUST be called while holding
    /// `queue` (`currentExcludedBundleIDs` is queue-confined).
    ///
    /// Also unions in the synced local sink's own render process object, by
    /// EXACT pid (``AudioProcessResolver/resolve(pid:)``, no bundle-id
    /// attribution needed since we already know the pid directly) — T-FANOUT
    /// self-exclude (R2): keeps the delayed local sink's own render process out
    /// of the whole-system tap so its output isn't re-captured as an echo, and
    /// (since the tap is `.mutedWhenTapped`) stays audible.
    private func resolveExcludedProcessObjectIDs() -> Set<AudioObjectID> {   // must hold `queue`
        var result = resolveExcludedObjectIDsLoggingAttribution(bundleIDs: currentExcludedBundleIDs)
        if let renderPID = syncedLocalRenderPID {
            result.formUnion(processResolver.resolve(pid: renderPID).map(\.objectID))
        }
        return result
    }

    /// Shared core of both exclusion-resolve call sites
    /// (``resolveExcludedProcessObjectIDs()`` and ``rebuildIfExclusionObjectsChanged()``'s
    /// off-lock resolve): resolves every bundle id in `bundleIDs` via
    /// ``processResolver/resolveWithAttribution(bundleID:)`` and emits ONE
    /// `Telemetry(.captureWS)` line per call — T2, the diagnosability gap the
    /// 2026-07-26 live catch-all-attribution fix left open. `exclusion_changed`
    /// already logs which bundle ids are excluded (INTENT); this logs which
    /// concrete pids each one actually resolved to and via which of the four
    /// attribution layers, so "app X still leaks" is answerable from the log
    /// alone. A bundle id resolving to ZERO processes is called out under
    /// `zeroBundles` — exactly the Spotify-helper leak signature (an excluded
    /// app whose helper the resolver still couldn't attribute reads as empty,
    /// live, before this the only way to see that was manual `ps` correlation).
    /// Cheap: one resolve per bundle id per call, same cost `resolve(bundleID:)`
    /// already paid — this only adds string formatting, never a second HAL walk.
    private func resolveExcludedObjectIDsLoggingAttribution(bundleIDs: Set<String>) -> Set<AudioObjectID> {
        var result: Set<AudioObjectID> = []
        var resolvedEntries: [String] = []
        var zeroBundles: [String] = []
        for bundleID in bundleIDs.sorted() {
            let attributed = processResolver.resolveWithAttribution(bundleID: bundleID)
            if attributed.isEmpty {
                zeroBundles.append(bundleID)
            } else {
                let byPID = attributed.map { "\($0.process.pid):\($0.layer.rawValue)" }.sorted()
                resolvedEntries.append("\(bundleID)=[\(byPID.joined(separator: ","))]")
            }
            result.formUnion(attributed.map(\.process.objectID))
        }
        // Unconditional SELF-exclude — the echo guard, generalized. Any audio
        // THIS process emits must never be re-captured into the whole-system
        // mix: `LocalPlaybackEngine` renders every `.currentDevice` app's
        // stream from THIS process onto the Mac's own output — the very device
        // this tap is anchored to — so without this, a "play on this Mac"
        // exception echoed straight back into the AirPlay mix the moment a
        // receiver was actually live (found live 2026-07-26: Spotify routed to
        // the Mac's speakers audibly replayed on the selected Sonos; earlier
        // sessions never heard it only because either the attribution leak or
        // a dead PTP clock masked it). The synced-local sink's R2 self-exclude
        // (`syncedLocalRenderPID` — the same `getpid()`) covered only the
        // play-everywhere path; this covers every path and makes that union
        // redundant-but-harmless. Resolved fresh per call, never cached: our
        // process object exists in the HAL list only while we are actually
        // rendering, and the process-list membership diff (W1-T7) re-runs this
        // the moment our render starts, so the tap rebuilds with us excluded.
        let selfProcesses = processResolver.resolve(pid: getpid())
        result.formUnion(selfProcesses.map(\.objectID))
        Telemetry.log(.captureWS, "exclusion_resolved", [
            "resolved": resolvedEntries.joined(separator: ";"),
            "zeroBundles": zeroBundles.joined(separator: ","),
            "self": selfProcesses.map { "\($0.pid)" }.sorted().joined(separator: ","),
        ])
        return result
    }

    // MARK: - Live exclusion-membership diffing (W1-T7, Gap 1 / Fix 1)

    /// Re-check an ALREADY-excluded bundle ID's process set after it may have
    /// relaunched or its per-app capture health changed (W1-T7 Fix 1 / R14). A
    /// relaunch gives the app a fresh pid, so the old resolved process object is
    /// gone and the whole-system tap's exclusion list is stale until it's rebuilt
    /// against the new process set. Cheap to call for a bundle ID that turns out
    /// not to be excluded (the `contains` gate no-ops it) or whose resolved object
    /// set is unchanged (the compare-before-rebuild guard no-ops it). Called by
    /// `NativeBackend.handleAppLaunched` / `handlePerAppCaptureHealthChange`.
    public func refreshExcludedProcessSet(forRelaunchedBundleID bundleID: String) {
        let isExcludedAndCapturing: Bool = queue.sync {
            guard case .capturing = _state else { return false }
            return currentExcludedBundleIDs.contains(bundleID)
        }
        guard isExcludedAndCapturing else { return }
        rebuildIfExclusionObjectsChanged()
    }

    /// The compare-before-rebuild core shared by BOTH exclusion-refresh entry
    /// points — ``refreshExcludedProcessSet(forRelaunchedBundleID:)`` (relaunch /
    /// per-app-health triggers, W1-T7 Fix 1) and ``handleMembershipChange()``
    /// (process-list churn, W1-T7 Gap 1). Re-resolves the live excluded set to the
    /// Core Audio process OBJECTS the tap actually excludes and rebuilds ONLY if
    /// that object set differs from the baseline the live tap was built against
    /// (``lastExcludedObjects``) — so an unchanged set (a duplicate notification,
    /// or churn in an unrelated app) does ZERO Core Audio work (the CPU-storm
    /// loop-breaker), while a genuine change (a new audio child appeared inside an
    /// excluded app, one went away, or an excluded app became audible on the same
    /// pid) rebuilds exactly once. The resolve runs OUTSIDE the lock (it enumerates
    /// the HAL); the decision is re-checked under the lock against the CURRENT
    /// `currentExcludedBundleIDs`/`syncedLocalRenderPID` so a racing
    /// `updateRouting`/`setSyncedLocalSink` isn't clobbered. The baseline advances
    /// only on a successful `recreateTap()` commit, so a failed rebuild can't leave
    /// a stale baseline that suppresses a later one. Recreates as a benign
    /// `.exclusionChange` (device/clock unchanged → no AirPlay session reset).
    private func rebuildIfExclusionObjectsChanged() {
        let snapshot: (bundleIDs: Set<String>, renderPID: pid_t?)? = queue.sync {
            guard case .capturing = _state else { return nil }
            return (currentExcludedBundleIDs, syncedLocalRenderPID)
        }
        guard let snapshot else { return }

        // Resolve OUTSIDE the lock (enumerates the HAL) — the same off-lock
        // discipline `recreateTap` keeps for its create.
        var newObjects = resolveExcludedObjectIDsLoggingAttribution(bundleIDs: snapshot.bundleIDs)
        if let renderPID = snapshot.renderPID {
            newObjects.formUnion(processResolver.resolve(pid: renderPID).map(\.objectID))
        }

        let needsRecreate: Bool = queue.sync {
            guard case .capturing = _state else { return false }
            // Inputs unchanged since the snapshot, else a concurrent
            // updateRouting/setSyncedLocalSink already owns the rebuild.
            guard currentExcludedBundleIDs == snapshot.bundleIDs,
                  syncedLocalRenderPID == snapshot.renderPID else { return false }
            guard newObjects != lastExcludedObjects else { return false } // COMPARE-BEFORE-REBUILD
            return true
        }
        guard needsRecreate else { return }
        AudioDiag.log("NativeCapture exclusion objects changed (\(lastExcludedObjects.count) -> \(newObjects.count)) — rebuilding")
        Telemetry.log(.captureWS, "exclusion_membership_changed", ["objectCount": "\(newObjects.count)"])
        recreateTap(cause: .exclusionChange)
    }

    #if canImport(AudioToolbox)
    /// Arm the system-wide process-object-list listener (Gap 1). Idempotent — a
    /// no-op once installed. MUST hold ``queue``. The block is dispatched by the
    /// HAL on an INTERNAL thread (`nil` dispatch queue), NOT on ``queue``: the
    /// handler debounces onto ``membershipQueue`` (which then does `queue.sync`),
    /// so running the block on `queue` would risk the same re-entrancy the per-app
    /// coordinator avoids the same way.
    private func installProcessListListenerLocked() {   // must hold `queue`
        guard installsProcessListListener else { return }
        guard processListBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleProcessListChanged()
        }
        var address = Self.processObjectListAddress
        let err = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
        guard err == noErr else {
            AudioDiag.log("NativeCapture exclusion-membership listener install FAILED (\(err))")
            return
        }
        processListBlock = block
        AudioDiag.log("NativeCapture exclusion-membership listener armed (process-object-list)")
    }

    /// Symmetric removal. MUST hold ``queue`` (or run in `deinit`, where no block
    /// can be concurrently live — see the `deinit` note).
    private func removeProcessListListenerLocked() {
        guard let block = processListBlock else { return }
        var address = Self.processObjectListAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
        processListBlock = nil
    }
    #endif

    /// A process connected to / disconnected from the audio system. Coalesce a
    /// burst of these onto ``membershipQueue`` and diff once settled. Internal
    /// (not `private`) so tests can drive the debounced entry point hermetically —
    /// firing a real `kAudioHardwarePropertyProcessObjectList` notification in CI
    /// isn't possible without live Core Audio churn.
    func handleProcessListChanged() {
        scheduleMembershipDiff()
    }

    /// Coalesce process-list notifications: cancel any pending diff and arm a fresh
    /// one ``membershipDebounceInterval`` out, so a rapid spawn/kill/spawn burst
    /// collapses to a single diff pass. Runs on ``membershipQueue`` (never
    /// ``queue``) so the `queue.sync` inside the diff cannot deadlock.
    private func scheduleMembershipDiff() {
        membershipQueue.async { [weak self] in
            guard let self else { return }
            self.membershipDiffWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.handleMembershipChange() }
            self.membershipDiffWork = work
            self.membershipQueue.asyncAfter(deadline: .now() + self.membershipDebounceInterval, execute: work)
        }
    }

    /// Re-resolve the excluded set and, on a genuine change to the process objects
    /// the tap excludes, recreate it — closing the mid-session leak where an
    /// already-excluded app spawns a new audio child WITHOUT relaunching (W1-T7
    /// Gap 1). Internal (not `private`) so tests can drive a diff pass
    /// deterministically without waiting out the real debounce timer.
    func handleMembershipChange() {
        rebuildIfExclusionObjectsChanged()
    }

    // MARK: Buffer delivery (tap IOProc thread → convert → engine)

    /// Freeze the four queue-confined fields ``handleBuffer(_:)`` needs into a
    /// fresh immutable ``BufferSnapshot`` and swap it into the published slot
    /// (T8). MUST be called while holding `queue` — it reads queue-confined
    /// state — and must be called from EVERY site that mutates any of those four
    /// fields, so the RT path never runs on a stale set.
    ///
    /// The swap itself is a single reference store under `snapshotLock`, held for
    /// those few instructions only. Callers are all non-real-time
    /// (`start`/`stop`/`recreateTap`/`updateRouting`/`setMeteringActive`/
    /// `setSyncedLocalSink`), so their side of the lock is unconstrained; the
    /// constraint lives entirely on the read side.
    private func publishBufferSnapshot() {   // must hold `queue`
        let snapshot = BufferSnapshot(
            converter: converter,
            meteringActive: meteringActive,
            syncedLocalSink: syncedLocalSink,
            syncedLocalBaseResampler: syncedLocalBaseResampler)
        snapshotLock.lock()
        _bufferSnapshot = snapshot
        snapshotLock.unlock()
    }

    /// Convert one captured buffer to the engine's fixed S16LE/44100/2ch format
    /// and forward it with a `pts` derived from the buffer's own `mHostTime`.
    /// Runs on the tap's delivery thread (the IOProc, in production). Allocation
    /// beyond the converter's own scratch is avoided on this path where practical.
    private func handleBuffer(_ buffer: CapturedBuffer) {
        // T8 (plan finding F12): REAL-TIME THREAD — never take `queue` here.
        //
        // This used to be `queue.sync { (converter, meteringActive, sink,
        // resampler) }`, i.e. the audio thread blocking on the same unqualified,
        // default-QoS serial queue that `start`/`stop`/`recreateTap`/
        // `updateRouting` take from ordinary threads: a textbook priority
        // inversion, and one that shows up as audible stutter when the machine is
        // loaded and the queue's current holder isn't scheduled.
        //
        // Instead the four values are published as ONE immutable
        // ``BufferSnapshot`` (see ``publishBufferSnapshot()``) and picked up here
        // with a single non-blocking reference read — the same `try()`-on-the-RT-
        // path shape ``LocalPlaybackEngine/receive(buffer:for:)`` and
        // ``SyncedLocalSink/enqueue(interleavedFrames:frameCount:pts:)`` already
        // use. Because it is a whole-object swap, a torn/half-updated read is
        // structurally impossible: we either see the previous complete set or the
        // next complete one, never a converter from one and a sink from another.
        //
        // A missed `try()` drops this one buffer, exactly as `receive` does. The
        // lock is only ever held for a single pointer store by a non-RT thread,
        // so a miss is vanishingly rare — and dropping one buffer is strictly
        // better than parking the IOProc behind a descheduled writer.
        let snapshot: BufferSnapshot
        if snapshotLock.try() {
            snapshot = _bufferSnapshot
            snapshotLock.unlock()
        } else {
            return
        }
        let metering = snapshot.meteringActive
        let syncedSink = snapshot.syncedLocalSink
        let baseResampler = snapshot.syncedLocalBaseResampler
        guard let converter = snapshot.converter else { return }

        guard let pcm = converter.convertToAirPlayPCM(buffer) else { return }
        guard !pcm.isEmpty else { return }

        // pts straight off the buffer's capture clock (mHostTime → timespec).
        sink.write(pcm: pcm, pts: buffer.pts)

        // T-FANOUT: fan the SAME converted PCM (and its pts) to the delayed local
        // sink — ONE capture, two consumers. Widened to interleaved Float32 and
        // base-resampled from 44.1 kHz UP to the sink's device-native render rate
        // (T3 Part B) so the sink's engine runs at the output device's own rate.
        // Gated exactly like metering below: a nil sink (play-everywhere off), or
        // no base resampler, means no fan-out. The sink's own scheduling holds it
        // phase-aligned with AirPlay; its render process is self-excluded from this
        // tap (``resolveExcludedProcessObjectIDs()``) so this fanned-out audio
        // can't loop back as an echo.
        if let syncedSink, let baseResampler {
            Self.fanOutToSyncedLocal(pcm, pts: buffer.pts, into: syncedSink, resampler: baseResampler)
        }

        // Level pass-through: compute RMS on the CONVERTED S16LE buffer once, for
        // the meter feature (identical for every fanned-out device) — but only
        // while metering is active (T-GATE): the popover is closed, so skip the
        // RMS pass entirely rather than compute a sample nobody reads.
        if metering, let onLevel {
            onLevel(Self.rmsOfS16LE(pcm))
        }
    }

    /// The default output device changed under us (the tap follows it, so its
    /// real format may now differ — e.g. built-in 44100 → USB DAC 48000).
    /// Delegates to ``recreateTap()`` — the same "tear down + recreate while
    /// capturing" machinery T4 reuses for an exclusion-list change. Runs on
    /// the tap's own dedicated `listenerQueue` (non-RT — see
    /// ``CoreAudioSystemTap/listenerQueue``), never the IOProc thread.
    private func handleDeviceChange() {
        Telemetry.log(.captureWS, "device_change", ["trigger": "default_output_changed"])
        // A genuine device/nominal-rate change: the tapped device's clock moved out
        // from under the live RTP sessions, so the rebuild MUST reset the
        // whole-system AirPlay session (see `onDeviceRateRebuild`). This is the one
        // rebuild path that carries `.deviceOrRateChange`.
        recreateTap(cause: .deviceOrRateChange)
    }

    /// Why ``recreateTap(cause:)`` is rebuilding — decides whether the rebuild
    /// needs a whole-system AirPlay session reset (``onDeviceRateRebuild``). A
    /// device/nominal-rate change (``handleDeviceChange()``) moves the tapped
    /// device's clock out from under the live RTP sessions and desyncs the
    /// receivers; an exclusion-set change
    /// (``updateRouting(appRoutes:excludedBundleIDs:)`` /
    /// ``setSyncedLocalSink(_:renderProcessPID:)``) rebuilds the tap but is EXPECTED
    /// to leave the device and its clock — and thus the receivers' timeline —
    /// untouched. "Expected", not guaranteed: ``recreateTap(cause:)`` verifies it
    /// against the tap that actually came up and resets anyway if the clock moved, so
    /// this cause is the default assumption, never the last word.
    enum RebuildCause { case deviceOrRateChange, exclusionChange }

    /// Tear the current tap down and recreate it — against the (possibly
    /// new) default output device, and always with the LIVE exclusion process-
    /// object set (``resolveExcludedProcessObjectIDs()``, re-resolved fresh so a
    /// stale process object from before an app relaunch is never carried
    /// forward). Shared by two
    /// triggers: ``handleDeviceChange()`` (the tap's own
    /// `onDefaultDeviceChanged`) and ``updateRouting(appRoutes:excludedBundleIDs:)``
    /// (the routed/excluded bundle-ID set changed while capturing). Only
    /// takes effect if currently `.capturing`; a race with a concurrent
    /// `stop()`/failure is a no-op. Surfaced as a fresh `.capturing(format')`
    /// transition, or `.failed` if re-creation fails.
    ///
    /// ## Sibling implementation
    /// `PerAppCaptureCoordinator.handleDeviceChange(bundleID:)` runs the SAME
    /// claim-under-lock / teardown-off-the-lock / commit-under-lock shape, per
    /// bundle-ID slot instead of per coordinator. The two are deliberately kept
    /// as separate bodies rather than one parameterized template — see
    /// [TapRebuildLifecycle.swift](TapRebuildLifecycle.swift) for the step-by-step
    /// list of what actually differs and why a shared template would be a
    /// closure sandwich. The parts that are genuinely identical
    /// (``TapRebuildCoalescer``, ``TapReanchor``) DO live there and are used by
    /// both. **A behavioural fix to the choreography here almost certainly
    /// needs the same fix there** — that "same fix, written twice" is exactly
    /// the cost the architecture review priced (2026-07-26, defect A).
    private func recreateTap(cause: RebuildCause) {
        // Under the lock ONLY: check we're still capturing, claim the old tap,
        // and snapshot the current exclusion pids (queue-confined). The blocking
        // Core Audio teardown+recreate then happens OUTSIDE the lock, matching
        // the pattern stop() deliberately adopts ("teardown may block on Core
        // Audio"). Holding `queue` across those HAL calls would head-of-line
        // block the `state` getter and a concurrent stop(). (Before T8 it also
        // head-of-line blocked every buffer's `handleBuffer`, which read the
        // converter under this same lock; it now reads the published
        // `BufferSnapshot` instead and never touches `queue`.)
        // STABILITY(C6): if a rebuild trigger arrives while we're already
        // mid-rebuild (`.creatingTap`), don't drop it — mark it pending so the
        // in-flight rebuild replays a fresh `recreateTap()` once it lands back
        // in `.capturing`. Rapid device/sample-rate bounces (44.1 -> 48 -> 44.1)
        // mean the LAST notification can be the one that would otherwise be
        // dropped, leaving the tap rebuilt against a stale device/rate. See
        // dev/notes/stability-audit-2026-07-18.md §C6.
        let claim: (
            proceed: Bool, old: SystemAudioTap?, excludedProcessObjectIDs: Set<AudioObjectID>,
            previousRate: Int?, previousDeviceID: AudioObjectID?
        ) = queue.sync {
            guard case .capturing(let oldFormat) = _state else {
                if case .creatingTap = _state {
                    rebuildCoalescer.markPending()
                    // Telemetry (T2): STABILITY(C6) coalescing point — a
                    // rebuild trigger arrived while already mid-rebuild, so it
                    // is being deferred/coalesced rather than dropped (see the
                    // "rebuild_replay" line logged once it's replayed below).
                    Telemetry.log(.captureWS, "rebuild_coalesced", ["reason": "already_rebuilding"])
                }
                return (false, nil, [], nil, nil)
            }
            let t = self.tap
            self.tap = nil
            self.converter = nil          // stop forwarding buffers through the dying tap
            self.publishBufferSnapshot()  // ...and make that visible to the RT path NOW
            self.transition(to: .creatingTap)
            // Snapshot what the OUTGOING tap was anchored to, before `teardown()`
            // clears it — the baseline the post-commit compare needs to tell a
            // re-anchor from a like-for-like rebuild.
            return (true, t, resolveExcludedProcessObjectIDs(), oldFormat.sampleRate, t?.tappedDeviceID)
        }
        // Not capturing (racing a stop()/failure): nothing to do.
        guard claim.proceed else { return }
        let old = claim.old

        // T7 EDGE 3, FIRST HALF — LEAVE THE OLD WORKGROUP BEFORE ANYTHING ELSE.
        //
        // The order is leave-then-join and it is not interchangeable. A thread can
        // hold ONE workgroup membership through this API, and `os_workgroup_join`
        // on a thread already in a non-nesting workgroup returns `EALREADY` and
        // joins nothing — and the old aggregate's workgroup and the new one do not
        // nest (they are different devices entirely; the plan measured `EALREADY`
        // for exactly this pair). So a join-then-leave shape would fail to join the
        // NEW aggregate and then drop the old membership, ending with the engine
        // thread in no workgroup at all — silently, since nothing here can observe
        // the join's return code. Leaving first can at worst cost us membership for
        // the duration of the rebuild, which is the same gap the rebuild itself
        // already imposes on the audio path.
        //
        // Placed before `old?.teardown()` for the same reason as in `stop()`: leave
        // while the publishing aggregate is still alive. The leave is delivered to
        // the engine thread, which serializes it ahead of the join below (FIFO), so
        // the ordering survives the hop off this queue.
        if old != nil { workgroup?.leave() }

        // MAKE-BEFORE-BREAK, gated to device-IDENTITY changes (audio-leak-on-device-
        // switch fix). The whole-system tap is `.mutedWhenTapped`: the mute that
        // keeps system audio OFF the local speakers is a property of the LIVE tap's
        // aggregate and engages only once the NEW tap's aggregate auto-starts. Break-
        // before-make tears the old tap down FIRST, so during the new aggregate's
        // create the NEW default device is tapped by nobody — unmuted — and system
        // audio audibly leaks out of it (AirPods drop -> built-in speakers blast).
        //
        // Fix: when the default device IDENTITY changed (new default != the device
        // the old tap was anchored to), build+start the new tap/aggregate — which
        // mutes the NEW device — BEFORE tearing the old one down. The two aggregates
        // then only ever sit on two DIFFERENT devices, which the HAL already runs
        // (4+ concurrent taps normally). This does NOT zero the leak: it removes the
        // old-tap teardown from the window, shrinking it to just the new aggregate's
        // `createAndStart` (during which the new device is briefly untapped/unmuted).
        //
        // A SAME-device rate-only rebuild KEEPS break-before-make: make-before-break
        // there would put two aggregates on ONE physical device mid-rate-
        // renegotiation — a novel/risky HAL config we deliberately avoid (the same-
        // device-rate leak is a documented lower-priority follow-up). Identity comes
        // off a fresh default-output-device read; a nil on either side (old tap had
        // no device, or the read failed) falls back to break-before-make.
        let newDefaultDeviceID = resolveDefaultOutputDeviceID()
        let makeBeforeBreak: Bool = {
            guard let previous = claim.previousDeviceID, let current = newDefaultDeviceID
            else { return false }
            return previous != current
        }()

        // Blocking HAL work OUTSIDE the lock. Break-before-make (same device, or an
        // unknown identity): tear the old tap down first, exactly as before.
        if !makeBeforeBreak { old?.teardown() }
        let newTap = makeTap()
        newTap.onDefaultDeviceChanged = { [weak self] in self?.handleDeviceChange() }
        // Wire delivery BEFORE createAndStart — the real IOProc snapshots `onBuffer`
        // by value at start (`let onBuffer = self.onBuffer`), so a handler assigned
        // AFTER createAndStart is never seen by the running IOProc and the tap
        // delivers nothing forever. An earlier make-before-break "guardrail" deferred
        // this to avoid double-capture during the old/new overlap, but that was both
        // unnecessary and a permanent-silence bug: `handleBuffer` already drops every
        // buffer while `snapshot.converter == nil` (nulled at claim, republished only
        // at commit), so neither tap's delivery reaches the sink until commit — the
        // empty-snapshot gate is the real single-delivery guarantee, on both paths.
        newTap.onBuffer = { [weak self] buffer in self?.handleBuffer(buffer) }

        do {
            let format = try newTap.createAndStart(
                muteBehavior: muteBehavior, excludedProcessObjectIDs: claim.excludedProcessObjectIDs)
            try Self.validate(format)
            // MAKE-BEFORE-BREAK second half: the new aggregate is up and already mutes
            // the NEW device, so tear the OLD device's tap down only now (leak window
            // = just the createAndStart above). Delivery was already wired before the
            // create; the converter gate (above) kept the overlap single-delivery.
            if makeBeforeBreak {
                old?.teardown()
            }
            let commit: (orphan: SystemAudioTap?, replay: Bool) = queue.sync {
                // A stop() may have raced in while we were recreating: don't clobber
                // an idle/stopping state with a fresh capturing one.
                guard case .creatingTap = _state else {
                    // stop() won. Return the just-created tap and tear it down OUTSIDE
                    // this lock: teardown() blocks until in-flight IO quiesces, and a
                    // blocking HAL call under `queue` head-of-line blocks the `state`
                    // getter and every other lifecycle call (the file's one rule:
                    // "teardown OUTSIDE the state lock"). Before T8 it was an outright
                    // DEADLOCK — newTap's IO callback (handleBuffer) synchronously took
                    // `queue` — and while handleBuffer no longer touches `queue` at
                    // all, the rule is unchanged.
                    return (newTap, false)
                }
                self.tap = newTap
                self.converter = makeConverter(format)
                self.publishBufferSnapshot()
                self.lastExcludedObjects = claim.excludedProcessObjectIDs // W1-T7 compare-before-rebuild baseline
                self.transition(to: .capturing(format))
                // STABILITY(C6): a rebuild trigger landed while we were rebuilding —
                // replay it once now that we're capturing again, coalescing however
                // many were dropped into a single retry.
                return (nil, rebuildCoalescer.takePending())
            }
            commit.orphan?.teardown()
            // T7 EDGE 3, SECOND HALF — join the NEW aggregate's workgroup, only once
            // the rebuild has actually committed (`orphan == nil`; a racing `stop()`
            // that won leaves the fresh tap orphaned and there is nothing to join).
            // We are guaranteed to have left the old one above, so this join starts
            // from no membership and cannot return `EALREADY`.
            if commit.orphan == nil, let id = newTap.workgroupDeviceID {
                workgroup?.join(deviceID: id)
            }
            // Fire the whole-system session-reset signal ONLY when this rebuild was
            // caused by a device/nominal-rate change AND actually committed a fresh
            // `.capturing` (orphan == nil; a racing stop() that won leaves `orphan`
            // set and no live session to reset). An exclusion-set rebuild
            // (`.exclusionChange`) leaves the receivers' RTP timeline intact and must
            // NOT reset — that spurious reset was the redundant per-connect RTP
            // re-establish (see `onDeviceRateRebuild`). Fired OFF the lock, matching
            // the "no HAL/handler work under `queue`" discipline the rest of this
            // method keeps.
            //
            // ...OR when the rebuild demonstrably re-anchored the clock anyway,
            // whatever it was nominally for. The cause alone cannot be trusted: the
            // default output device can move inside the window between the old tap's
            // `teardown()` (which takes its device listener with it) and the new tap
            // arming its own. Nobody delivers that notification, so an
            // `.exclusionChange` rebuild — a plain connect, an exclusion toggle —
            // silently comes back up on a DIFFERENT device's clock with the receivers
            // still on the old timeline, and stays silent until some later device/rate
            // event happens to fire a reset. Comparing what the outgoing tap was
            // anchored to against what the incoming one landed on closes that window
            // with a fact instead of an assumption. A tap that doesn't report its
            // device (`nil`) abstains from the identity half, leaving the rate compare.
            let reanchor = TapReanchor(
                previousRate: claim.previousRate, newRate: format.sampleRate,
                previousDeviceID: claim.previousDeviceID, newDeviceID: newTap.tappedDeviceID)
            if commit.orphan == nil, cause == .deviceOrRateChange || reanchor.didReanchor {
                if cause == .exclusionChange {
                    // Worth its own line: an exclusion-cause rebuild that turned out to
                    // re-anchor is exactly the silent-dropout window this compare exists
                    // to catch, and nothing else in the trail would show it.
                    Telemetry.log(.captureWS, "rebuild_reanchored", [
                        "cause": "exclusionChange",
                        "rateMoved": reanchor.rateMoved ? "true" : "false",
                        "deviceMoved": reanchor.deviceMoved ? "true" : "false",
                    ])
                }
                onDeviceRateRebuild?()
            }
            if commit.replay {
                // Telemetry (T2): the coalesced trigger(s) from the branch
                // above are being replayed now that the in-flight rebuild
                // landed back in `.capturing` — see "rebuild_coalesced".
                Telemetry.log(.captureWS, "rebuild_replay", [:])
                // A trigger coalesced while we were mid-rebuild (C6). It may have been
                // a device/rate change, so replay as `.deviceOrRateChange`: a missed
                // reset would reintroduce the dropout, whereas an extra reset here is
                // at worst harmless and this path only fires on rapid device/rate
                // bounces, never on a plain connect (the sink-attach rebuild lands
                // while `.capturing`, not `.creatingTap`, so it is never coalesced).
                recreateTap(cause: .deviceOrRateChange)
            }
        } catch {
            // T7: nothing to unwind here — the old membership was already left at
            // the top of this method and the new aggregate never came up, so there
            // is no join to match. The engine thread simply runs without workgroup
            // membership until the next successful tap creation.
            newTap.teardown()   // createAndStart already tears down internally; idempotent.
            // MAKE-BEFORE-BREAK failure unwind: on this path the old tap is STILL
            // ALIVE (its teardown was deferred until after a successful create), so
            // tear it down too — never leave two taps or a dangling one. On the
            // break-before-make path the old tap was already torn down above; teardown
            // is idempotent, but this stays guarded to keep that path byte-identical.
            if makeBeforeBreak { old?.teardown() }
            let mapped: NativeCaptureError = (error as? NativeCaptureError)
                ?? .tapCreationFailed(reason: String(describing: error))
            queue.sync {
                guard case .creatingTap = _state else { return }
                self.tap = nil
                self.converter = nil
                self.publishBufferSnapshot()
                self.transition(to: .failed(mapped))
            }
        }
    }

    // MARK: Synced-local fan-out (T-FANOUT)

    /// Widen one interleaved S16LE airplay-format buffer (``PCMFormat/airplay`` —
    /// 44100 / 2ch, the exact bytes handed to the engine) to interleaved Float32 in
    /// −1.0…1.0, base-resample it UP to the sink's device-native render rate, and
    /// hand it to the delayed local sink with the capture `pts` (T3 Part B).
    ///
    /// Reuses the engine's already-resampled/channel-matched 44.1 kHz PCM rather
    /// than a second heavy pass off the raw tap buffer: one capture drives both
    /// consumers, plus this cheap integer→float widen and a fixed-ratio resample.
    /// The `resampler` carries the fixed ratio `44100 / renderSampleRate`; when the
    /// output device is itself 44.1 kHz that ratio is 1.0 and the widened samples
    /// pass through bit-for-bit (``SyncedLocalBaseResampler/isIdentity``), so this
    /// stays the same program the AirPlay receivers get — up-sampled only when the
    /// device runs faster (48/88.2/96/176.4/192 kHz).
    ///
    /// The resample is deliberately an INTERPOLATOR (Catmull-Rom), so output frame
    /// 0 equals input frame 0 and output frame `n` samples the input at position
    /// `n · ratio`: it introduces NO whole-sample timeline shift, so the sink can
    /// keep anchoring ring-sample-0 to this `pts` with no base-resample delay term
    /// to fold into `SyncTiming`. Runs on the tap delivery thread; allocation is
    /// the widen scratch plus the resampler's output buffer, matching the existing
    /// per-buffer allocation posture of this path (never the sink's RT render
    /// block, which stays alloc/lock-free).
    static func fanOutToSyncedLocal(
        _ s16le: Data, pts: timespec, into sink: SyncedLocalPCMSink, resampler: SyncedLocalBaseResampler
    ) {
        let channelCount = PCMFormat.airplay.channels
        let sampleCount = s16le.count / MemoryLayout<Int16>.size
        guard channelCount > 0, sampleCount >= channelCount else { return }
        let frameCount = sampleCount / channelCount
        let usableSamples = frameCount * channelCount
        var floats = [Float](repeating: 0, count: usableSamples)
        let scale: Float = 1.0 / 32768.0
        s16le.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<usableSamples {
                floats[i] = Float(Int16(littleEndian: p[i])) * scale
            }
        }

        // Rates equal (44.1 kHz device): pass the widened samples straight through,
        // bit-exact and with no resampler priming lag — mirroring the converter's
        // "resample only when the rate differs from 44100" discipline upstream.
        if resampler.isIdentity {
            floats.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                sink.enqueue(interleavedFrames: base, frameCount: frameCount, pts: pts)
            }
            return
        }

        floats.withUnsafeBufferPointer { inBuf in
            guard let inBase = inBuf.baseAddress else { return }
            let out = resampler.resample(input: inBase, frameCount: frameCount)
            let outFrames = out.count / channelCount
            guard outFrames > 0 else { return }
            out.withUnsafeBufferPointer { outBuf in
                guard let outBase = outBuf.baseAddress else { return }
                sink.enqueue(interleavedFrames: outBase, frameCount: outFrames, pts: pts)
            }
        }
    }

    // MARK: Level metering (RMS on S16LE, pure/testable)

    /// Root-mean-square level of an interleaved S16LE buffer, normalized to
    /// 0.0...1.0. Cheap and allocation-free; runs on the delivery thread.
    static func rmsOfS16LE(_ data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        var sumSquares: Double = 0
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                let v = Double(Int16(littleEndian: p[i])) / 32768.0
                sumSquares += v * v
            }
        }
        return Float((sumSquares / Double(sampleCount)).squareRoot())
    }

    /// Root-mean-square level of a captured tap buffer's RAW Float32 samples,
    /// normalized to 0.0...1.0 (a real tap's Float32 samples are nominally
    /// -1.0...1.0 already, so no scaling is applied beyond squaring). Cheap and
    /// allocation-free — walks each channel's raw bytes directly via
    /// `withUnsafeBytes`/`bindMemory`, no intermediate `Data`/array — matching
    /// `rmsOfS16LE`'s discipline. Used for the per-app (T10) meter, whose taps
    /// (``PerAppCaptureCoordinator``/``LocalPlaybackEngine``) deliver tap-native
    /// Float32, same as the whole-system tap.
    ///
    /// Handles BOTH of ``CapturedBuffer/channelData``'s layouts identically:
    /// planar (one `Data` per channel — `channelData.count > 1`, the common case
    /// for a stereo tap: `isInterleaved == false`) and interleaved
    /// (`channelData.count == 1`, one buffer holding every channel's samples back
    /// to back). Every entry's raw Float32 samples are pooled into one running
    /// sum-of-squares over the TOTAL sample count across all entries — for planar
    /// input that is "all channels combined"; for interleaved input the single
    /// entry already contains every channel's samples, so the same pooling gives
    /// the equivalent combined level. There is no per-entry channel count to
    /// average by (``CapturedBuffer`` does not carry channel count), so this is a
    /// single pooled RMS across every sample the buffer holds, not a per-channel
    /// average — the right combined level for a meter either way.
    static func rmsOfFloat32(_ buffer: CapturedBuffer) -> Float {
        var sumSquares: Double = 0
        var sampleCount = 0
        for data in buffer.channelData {
            let count = data.count / MemoryLayout<Float32>.size
            guard count > 0 else { continue }
            data.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: Float32.self)
                for i in 0..<count {
                    let v = Double(p[i])
                    sumSquares += v * v
                }
            }
            sampleCount += count
        }
        guard sampleCount > 0 else { return 0 }
        return Float((sumSquares / Double(sampleCount)).squareRoot())
    }

    // MARK: Transition helper (on queue)

    private func transition(to newState: State) {   // must hold `queue`
        guard newState != _state else { return }
        let old = _state
        _state = newState
        // Telemetry (T2): non-blocking, formats on this (non-RT, queue-confined)
        // thread and hands off to Telemetry's own serial writer — never called
        // from the IOProc/render path (see `handleBuffer`, which never calls
        // `transition`). Every idle/creatingTap/capturing/stopping/failed move
        // funnels through here, so this one call site covers the whole
        // lifecycle for T2's "captureWS transition" line.
        Telemetry.log(.captureWS, "transition", Self.transitionFields(from: old, to: newState))
        onStateChange?(newState)
    }

    /// Fields for the `captureWS`/`transition` telemetry line above: both
    /// state labels, plus — when available — the tap format the new state
    /// carries (`.capturing`) or the failure reason (`.failed`). Enough for
    /// an agent reading the log cold (no repro, days later) to reconstruct
    /// what happened without cross-referencing the source.
    private static func transitionFields(from old: State, to newState: State) -> [String: String] {
        var fields: [String: String] = [
            "from": stateLabel(old),
            "to": stateLabel(newState),
        ]
        if case .capturing(let format) = newState {
            fields["format"] = "\(format.sampleRate)/\(format.channels)"
        }
        if case .failed(let error) = newState {
            fields["reason"] = String(describing: error)
        }
        return fields
    }

    /// Stable string label for a `State`, used only for the telemetry `from`/
    /// `to` fields above. An exhaustive switch so a future new case is a
    /// compile error here instead of silently logging nothing.
    private static func stateLabel(_ state: State) -> String {
        switch state {
        case .idle: return "idle"
        case .creatingTap: return "creatingTap"
        case .capturing: return "capturing"
        case .stopping: return "stopping"
        case .failed: return "failed"
        }
    }
}

// MARK: - Injected seams (protocols)

/// The real captured format read off the tap's ASBD, in neutral terms (no Core
/// Audio types leak so the state machine is testable). "config-follows-tap" reads
/// this; the converter consumes it.
public struct TapFormat: Equatable, Sendable {
    /// The tap's sample rate in Hz (tracks the default output device — often
    /// 44100 or 48000; NEVER assume).
    public var sampleRate: Int
    /// Channel count of the captured stream.
    public var channels: Int
    /// Bits per (per-channel) sample of the captured stream.
    public var bitsPerSample: Int
    /// Whether the captured samples are floating point (a system tap is typically
    /// Float32) vs signed integer.
    public var isFloat: Bool
    /// Whether the captured buffers are interleaved (false = planar/non-interleaved,
    /// N separate channel buffers, which the tap delivers for a stereo mixdown).
    public var isInterleaved: Bool

    public init(
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int,
        isFloat: Bool,
        isInterleaved: Bool
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.isFloat = isFloat
        self.isInterleaved = isInterleaved
    }
}

/// One buffer delivered by the tap: the raw captured PCM bytes (in the tap's real
/// format, interleaved or planar per ``TapFormat/isInterleaved``) plus the
/// presentation timestamp derived from the IOProc's `AudioTimeStamp.mHostTime`.
///
/// For a planar/non-interleaved tap, `channelData` holds one `Data` per channel;
/// for interleaved it holds a single element. The converter handles both.
public struct CapturedBuffer: Sendable {
    /// One entry per channel for planar; a single entry for interleaved.
    public var channelData: [Data]
    /// Frames per channel in this buffer.
    public var frameCount: Int
    /// Presentation timestamp of the first frame (from the capture clock).
    public var pts: timespec

    public init(channelData: [Data], frameCount: Int, pts: timespec) {
        self.channelData = channelData
        self.frameCount = frameCount
        self.pts = pts
    }
}

/// The mute mode for the tap (mirrors `CATapMuteBehavior` without leaking the
/// Core Audio type). `.mutedWhenTapped` silences local playback while capturing.
public enum TapMuteBehavior: Sendable {
    case unmuted
    case mutedWhenTapped
}

/// A no-op ``AudioProcessEnumerating``: reports no live processes, so an
/// ``AudioProcessResolver`` built on it always resolves every bundle id to the
/// empty set. Backs ``NativeCaptureCoordinator``'s default ``AudioProcessResolver``
/// — "nothing resolves" — until an AppKit-importing layer injects the real,
/// fully-wired one (T6). `public` (not `internal`) because it backs a default
/// argument value in `NativeCaptureCoordinator`'s `public` convenience init.
public struct EmptyAudioProcessEnumerator: AudioProcessEnumerating {
    public init() {}
    public func enumerateProcesses() -> [RawAudioProcess] { [] }
    public func parentPID(of pid: pid_t) -> pid_t? { nil }
}

/// The Core Audio process-tap seam. The production impl (``CoreAudioSystemTap``)
/// drives `CATapDescription` / `AudioHardwareCreateProcessTap` + an aggregate
/// device; tests inject a fake that pushes ``CapturedBuffer``s on demand.
public protocol SystemAudioTap: AnyObject {
    /// Called with each captured buffer, on the delivery (IOProc) thread.
    var onBuffer: (@Sendable (CapturedBuffer) -> Void)? { get set }
    /// Called when the default output device changes (the tap follows it, so its
    /// format may change and it must be recreated).
    var onDefaultDeviceChanged: (@Sendable () -> Void)? { get set }

    /// Create the tap, read its REAL format, build the aggregate device, register
    /// the IOProc, and start it. Returns the tap's real captured format. Throws
    /// ``NativeCaptureError`` on failure (most commonly TCC not granted).
    /// - Parameter excludedProcessObjectIDs: Core Audio process objects to leave
    ///   OUT of the whole-system mix (T4 — apps individually routed elsewhere, or
    ///   user-excluded via Settings). Already resolved to the FULL per-bundle
    ///   process set (main + every child/helper — see
    ///   ``AudioProcessResolver``) by the caller, so no further pid translation
    ///   happens here. Empty = the whole system, unchanged from pre-T4 behavior.
    func createAndStart(muteBehavior: TapMuteBehavior, excludedProcessObjectIDs: Set<AudioObjectID>) throws -> TapFormat

    /// Stop and destroy the IOProc, aggregate device, and tap (in that order).
    /// Idempotent and non-throwing so teardown always completes.
    func teardown()

    /// The `AudioObjectID` whose `kAudioDevicePropertyIOThreadOSWorkgroup`
    /// ('oswg') the engine thread should join (T7) — the AGGREGATE DEVICE this
    /// tap built, and never the default output device it is pinned to. Those two
    /// publish DISTINCT workgroups that do NOT nest (measured during planning:
    /// joining one and then the other returns `EALREADY`), so naming the wrong
    /// one puts the engine thread in a workgroup that has nothing to do with the
    /// cadence actually driving our audio.
    ///
    /// `nil` when there is no live aggregate (not created yet, already torn
    /// down) — the coordinator then simply has nothing to join. Defaulted to
    /// `nil` so a test fake that does not model workgroups needs no
    /// implementation; real hardware behaviour is not assertable hermetically
    /// anyway (plan risk #6).
    var workgroupDeviceID: AudioObjectID? { get }

    /// The output device this tap is currently anchored to, or nil when it isn't
    /// running / can't say. Read by ``NativeCaptureCoordinator`` across a rebuild to
    /// tell whether the tap actually re-anchored onto a DIFFERENT device's clock —
    /// which no rebuild *cause* can be trusted to report, because the default output
    /// device can move inside the window where the old tap is already torn down and
    /// the new one hasn't armed its listener yet. Defaulted to nil so a fake that
    /// doesn't model device identity keeps working (the compare simply abstains).
    var tappedDeviceID: AudioObjectID? { get }
}

public extension SystemAudioTap {
    var workgroupDeviceID: AudioObjectID? { nil }
    var tappedDeviceID: AudioObjectID? { nil }
}

/// The audio I/O workgroup seam (T7). Implemented in production by
/// ``EngineIOWorkgroup`` over ``AirPlayEngine``; a spy in tests records the
/// ORDER and COUNT of calls, which is the only part of workgroup behaviour that
/// can be asserted without real Core Audio (plan risk #6).
///
/// The implementation is responsible for getting the call onto the thread that
/// must perform it — `os_workgroup_join`/`leave` act only on the calling thread,
/// and the coordinator's queues are emphatically not that thread.
public protocol AudioIOWorkgroupJoining: Sendable {
    /// Join the audio-carrying thread to `deviceID`'s I/O workgroup.
    func join(deviceID: AudioObjectID)
    /// Drop that thread's current membership, if any. Idempotent.
    func leave()
}

/// The PCM destination — the engine's `write(pcm:pts:)`. Injected so tests spy on
/// forwarded buffers without a real engine/session.
public protocol PCMSink: Sendable {
    /// Forward one buffer of interleaved S16LE / 44100 / 2ch PCM with its `pts`.
    func write(pcm: Data, pts: timespec)
}

/// Converts a captured buffer (in the tap's real format) to the engine's fixed
/// S16LE / 44100 / 2ch format. Injected so the state machine is testable without
/// AVFoundation. Returns nil if this buffer can't be converted (it is dropped).
public protocol PCMConverting: Sendable {
    func convertToAirPlayPCM(_ buffer: CapturedBuffer) -> Data?
}

/// The delayed-local-sink fan-out target (T-FANOUT). The whole-system tap feeds
/// the SAME captured audio it hands the engine (``PCMSink/write(pcm:pts:)``) to a
/// second consumer conforming to this, so the Mac's own speakers can play a
/// PTP-delayed copy phase-aligned with the AirPlay receivers ("play everywhere").
/// The concrete ``SyncedLocalSink`` conforms; tests inject a spy. Fed interleaved
/// Float32 at the airplay rate/channel-count (44100 / 2ch) — the coordinator
/// widens the already-converted S16LE airplay PCM, keeping the sink about
/// scheduling, not format bridging (see ``SyncedLocalSink/enqueue(interleavedFrames:frameCount:pts:)``).
public protocol SyncedLocalPCMSink: AnyObject, Sendable {
    func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec)

    /// The sink's device-native render rate (Hz). The coordinator base-resamples
    /// the 44.1 kHz airplay feed UP to this once before enqueueing, so the ring —
    /// and the sink's `AVAudioEngine` — run at the output device's own rate and
    /// opening the sink never renegotiates it (plan Part B). Defaulted to the
    /// airplay rate so a test spy that doesn't care about rate conversion (its
    /// feed then passes straight through, ratio 1.0) needn't implement it.
    var renderSampleRate: Double { get }
}

extension SyncedLocalPCMSink {
    var renderSampleRate: Double { Double(PCMFormat.airplay.sampleRate) }
}

/// ``SyncedLocalSink`` already exposes exactly this shape — both the AVFoundation
/// and the inert fallback variant — so conformance is declaration-only.
extension SyncedLocalSink: SyncedLocalPCMSink {}

/// A streaming, fixed-ratio 4-point cubic (Catmull-Rom) resampler for the
/// synced-local fan-out's ONE base-rate conversion: the 44.1 kHz airplay feed →
/// the sink's device-native render rate, done before the ring (T3 Part B).
///
/// Distinct from ``FractionalResampler`` on purpose. That one is the sink's ppm
/// DRIFT corrector — its ratio stays ≈ 1 under a PI loop and it is clamped to
/// [0.5, 2.0], a range base conversion up to 96/176.4/192 kHz would exceed. This
/// one takes a FIXED ratio spanning every real output rate and does no drift
/// work, keeping the two concerns separate (plan: keep the `FractionalResampler`
/// a 1 ± ppm drift corrector only; base conversion must not run through it). The
/// Catmull-Rom kernel is the same math the phase-lock spike validated
/// (`dev/notes/phase-lock-spike-findings.md`).
///
/// Sync-critical interpolator property: at the stream start (`frac == 0`) the
/// cubic collapses to the first input frame, so `output[0] == input[0]` exactly,
/// and thereafter output frame `n` samples the input at position `n · ratio`.
/// There is NO whole-sample group delay to compensate, so the caller anchors
/// ring-sample-0 to the input `pts` unchanged (no `SyncTiming` delay term for the
/// base resample).
///
/// Streaming across delivery buffers: the 4-tap register and the fractional phase
/// carry between ``resample(input:frameCount:)`` calls, so block boundaries are
/// seamless. Single-consumer (the tap delivery thread), like the ring it feeds.
final class SyncedLocalBaseResampler {

    let channelCount: Int
    /// Input frames consumed per output frame = `inputRate / outputRate`.
    let ratio: Double
    /// Input and output rates match → the feed passes through untouched.
    let isIdentity: Bool

    /// 4 taps (`d0..d3`) of `channelCount` interleaved samples each; carries the
    /// interpolation window across buffers.
    private var taps: [Float]
    private var frac: Double = 0
    private var primed = false

    init(inputRate: Double, outputRate: Double, channelCount: Int) {
        let cc = max(1, channelCount)
        self.channelCount = cc
        let inR = (inputRate.isFinite && inputRate > 0) ? inputRate : Double(PCMFormat.airplay.sampleRate)
        let outR = (outputRate.isFinite && outputRate > 0) ? outputRate : inR
        let r = inR / outR
        self.ratio = r
        self.isIdentity = abs(r - 1.0) < 1e-12
        self.taps = [Float](repeating: 0, count: 4 * cc)
    }

    /// Resample `frameCount` interleaved input frames (buffer length ≥
    /// `frameCount · channelCount`) to freshly-returned interleaved output at the
    /// output rate. Empty only when the very first call can't prime — a first
    /// block shorter than the 3-frame lookahead, which real converter blocks never
    /// are (guarded so a pathological tiny first buffer drops rather than traps).
    func resample(input: UnsafePointer<Float>, frameCount: Int) -> [Float] {
        let cc = channelCount
        guard frameCount > 0 else { return [] }
        if isIdentity {
            return Array(UnsafeBufferPointer(start: input, count: frameCount * cc))
        }

        // Upper bound on outputs producible from this block (see class note): the
        // loop always exhausts the input (`break outer`) before hitting this cap,
        // so no input frame is ever dropped; the tail is trimmed after.
        let maxOutFrames = Int((Double(frameCount) / ratio).rounded(.up)) + 4
        var out = [Float](repeating: 0, count: maxOutFrames * cc)
        var produced = 0

        out.withUnsafeMutableBufferPointer { ob in
            guard let obase = ob.baseAddress else { return }
            taps.withUnsafeMutableBufferPointer { tp in
                guard let d0 = tp.baseAddress else { return }
                let d1 = d0 + cc, d2 = d0 + 2 * cc, d3 = d0 + 3 * cc
                var inIdx = 0

                // Prime once: d0 = 0 (implicit pre-start history), d1/d2/d3 = the
                // first three input frames. `output[0]` then collapses to d1 =
                // input[0] at frac 0 — the exact-anchor property.
                if !primed {
                    guard frameCount >= 3 else { return }
                    for ch in 0..<cc {
                        d0[ch] = 0
                        d1[ch] = input[ch]
                        d2[ch] = input[cc + ch]
                        d3[ch] = input[2 * cc + ch]
                    }
                    inIdx = 3
                    frac = 0
                    primed = true
                }

                outer: while produced < maxOutFrames {
                    // Advance the window until frac ∈ [0, 1). If the block runs out
                    // mid-advance, stop and preserve the register + frac for the
                    // next call (seamless resume, no extrapolation past the taps).
                    while frac >= 1.0 {
                        if inIdx >= frameCount { break outer }
                        let src = inIdx * cc
                        for ch in 0..<cc {
                            d0[ch] = d1[ch]; d1[ch] = d2[ch]; d2[ch] = d3[ch]
                            d3[ch] = input[src + ch]
                        }
                        inIdx += 1
                        frac -= 1.0
                    }
                    let f = Float(frac)
                    let dst = obase + produced * cc
                    for ch in 0..<cc {
                        let x0 = d0[ch], x1 = d1[ch], x2 = d2[ch], x3 = d3[ch]
                        let a = -0.5 * x0 + 1.5 * x1 - 1.5 * x2 + 0.5 * x3
                        let b = x0 - 2.5 * x1 + 2.0 * x2 - 0.5 * x3
                        let c = -0.5 * x0 + 0.5 * x2
                        dst[ch] = ((a * f + b) * f + c) * f + x1
                    }
                    produced += 1
                    frac += ratio
                }
            }
        }

        out.removeLast((maxOutFrames - produced) * cc)
        return out
    }
}

/// Every way native capture can fail, shaped so a UI can render an actionable
/// message and the state machine can surface it.
public enum NativeCaptureError: Error, Equatable, Sendable {
    /// The process tap could not be created — on first run this almost always
    /// means the system-audio-recording (TCC) permission has not been granted.
    case tapCreationFailed(reason: String)
    /// The aggregate device pinning the tap to the default output could not be
    /// created (device disappeared mid-setup, or a HAL error).
    case aggregateDeviceFailed(reason: String)
    /// The tap's format could not be read.
    case formatReadFailed(reason: String)
    /// The default output device was lost and could not be replaced (capture
    /// cannot continue).
    case deviceLost(reason: String)
    /// The running macOS version predates the process-tap API entirely (< 14.2),
    /// so capture cannot start no matter what permission is granted. Distinct
    /// from `.tapCreationFailed` — that case is for a tap that COULD exist on
    /// this OS but didn't (usually a TCC denial); this one means the API isn't
    /// present at all, so permission advice would be actively wrong.
    case osUnsupported(minimum: String)

    /// Whether a fresh `start()` is expected to be worth retrying without user
    /// action (T16, E10 — the whole-system-tap `.failed` retry NativeBackend
    /// drives off `onStateChange`). Mirrors `PerAppCaptureError.isRetryable`'s
    /// exact split: every case except `.osUnsupported` describes a plausibly
    /// transient condition (a HAL hiccup building the tap/aggregate, the
    /// default output device disappearing mid-setup, a bad ASBD read) that a
    /// bounded backoff retry can recover from once the transient condition
    /// clears — an OS-version gate never resolves itself no matter how many
    /// times `start()` is retried, so permission advice (or a retry) would be
    /// actively wrong there.
    public var isRetryable: Bool {
        if case .osUnsupported = self { return false }
        return true
    }

    /// A human-readable, UI-renderable description of the failure and its remedy.
    public var userMessage: String {
        switch self {
        case .tapCreationFailed:
            return "Couldn't start audio capture. Grant system-audio recording "
                + "permission in System Settings ▸ Privacy & Security ▸ Screen & "
                + "System Audio Recording, then try again."
        case .aggregateDeviceFailed:
            return "Couldn't set up audio capture for the current output device."
        case .formatReadFailed:
            return "Couldn't read the audio device's format."
        case .deviceLost:
            return "The audio output device was disconnected."
        case .osUnsupported(let minimum):
            return "Audio capture requires macOS \(minimum) or newer. "
                + "Please update macOS to use this feature."
        }
    }
}

// MARK: - Production seams (Core Audio + AVFoundation)
//
// These are compiled only where AudioToolbox is available (macOS). The unit test
// suite exercises the state machine through fakes and never touches them.

#if canImport(AudioToolbox)

/// The engine as a ``PCMSink``: forwards straight to
/// ``AirPlayEngine/AirPlayEngine/write(pcm:pts:)`` (nonisolated, fire-and-forget).
///
/// LIVE BUG (2026-07-26): this is the WHOLE-SYSTEM (stream 0) write path, and it
/// had ZERO backpressure visibility — `NativeBackend.sampleWriteBacklogIfDue()`
/// (the diagnostic that reads `engine.writeBacklogSnapshot()` and logs
/// `write_backlog_drop` when the engine's per-stream backpressure guard actually
/// discards a write) is called ONLY from the per-app mixer's `onMixedBuffer`
/// (stream ≥ 1). A session with no active `.device`-routed app therefore had
/// this diagnostic never fire at all, so a genuine engine-side drop on stream 0
/// was indistinguishable from a healthy stream: no rebuild, no error, no
/// telemetry anywhere — audio simply stopped. `EngineSink` now samples its OWN
/// backlog on the SAME throttled cadence, so stream 0 gets this visibility
/// whether or not any per-app stream exists.
///
/// `final class` (not the original `struct`) so this per-instance counter state
/// is a stored reference, not copied — `EngineSink` is constructed once and held
/// by ``NativeCaptureCoordinator``. `@unchecked Sendable`: `write(pcm:pts:)` runs
/// serially on the tap's IOProc delivery thread (Core Audio never invokes an
/// IOProc concurrently with itself), so the counter needs no lock — the same
/// single-caller discipline this file already uses for e.g.
/// `machToMonotonicOffsetNanos`.
final class EngineSink: PCMSink, @unchecked Sendable {
    let engine: AirPlayEngine
    init(engine: AirPlayEngine) { self.engine = engine }

    /// Sample interval and delta-gating: identical to
    /// `NativeBackend.sampleWriteBacklogIfDue()` — see that doc for why 500 and
    /// why only on a genuine change to `droppedWrites`.
    private static let backlogSampleInterval = 500
    private var backlogSampleCounter = 0
    private var lastReportedDroppedWrites: UInt64 = 0

    /// Write-CADENCE sampling (T-ENG-CADENCE-1, whole-system-dropout
    /// investigation): the mirror image of the backlog counters above, for
    /// `writeCadenceSnapshot()` instead of `writeBacklogSnapshot()`. Its own
    /// independent counter/baseline, same `backlogSampleInterval` — see
    /// `NativeBackend.sampleWriteCadenceIfDue()`'s doc for the shape this
    /// copies and why the per-app mixer's sampler alone couldn't cover this
    /// (stream 0) path.
    private var cadenceSampleCounter = 0
    private var lastReportedCadenceDeficitSeconds: Double = 0
    private var lastReportedCadenceOverrunSeconds: Double = 0

    func write(pcm: Data, pts: timespec) {
        engine.write(pcm: pcm, pts: pts)
        sampleWriteBacklogIfDue()
        sampleWriteCadenceIfDue()
    }

    private func sampleWriteBacklogIfDue() {
        backlogSampleCounter &+= 1
        guard backlogSampleCounter % Self.backlogSampleInterval == 0 else { return }
        let snap = engine.writeBacklogSnapshot()
        guard snap.droppedWrites != lastReportedDroppedWrites else { return }
        let delta = snap.droppedWrites &- lastReportedDroppedWrites
        lastReportedDroppedWrites = snap.droppedWrites
        Telemetry.log(.captureWS, "write_backlog_drop", [
            "path": "wholeSystem",
            "droppedTotal": String(snap.droppedWrites),
            "droppedDelta": String(delta),
            "maxInFlightSeconds": String(format: "%.3f", snap.maxInFlightSeconds),
            "streamsTracked": String(snap.streamsTracked),
        ])
    }

    /// Mirrors `NativeBackend.sampleWriteCadenceIfDue()` exactly (own counter,
    /// own last-reported baseline, same `backlogSampleInterval`, same
    /// deficit-OR-overrun delta-gate) so the whole-system (stream 0) write
    /// path gets the identical `write_cadence_drift` visibility the per-app
    /// mixer path already has — closing the gap D3 flagged: a whole-system-
    /// only session (no active `.device` route) never drove the per-app
    /// sampler's trigger (`onMixedBuffer`) at all. `path: "wholeSystem"`
    /// distinguishes this call site from the per-app one's `path: "perApp"`
    /// in the same event.
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
        Telemetry.log(.captureWS, "write_cadence_drift", [
            "path": "wholeSystem",
            "writeCount": String(snap.writeCount),
            "deficitTotalSeconds": String(format: "%.3f", snap.deficitSeconds),
            "deficitDeltaSeconds": String(format: "%.3f", deficitDelta),
            "overrunTotalSeconds": String(format: "%.3f", snap.overrunSeconds),
            "overrunDeltaSeconds": String(format: "%.3f", overrunDelta),
            "lastGapSeconds": String(format: "%.4f", snap.lastGapSeconds),
        ])
    }
}

/// The engine as the ``AudioIOWorkgroupJoining`` target (T7): both calls hand off
/// to ``AirPlayEngine``, which marshals them onto its engine thread — the thread
/// that actually encodes/encrypts/sends our audio, and therefore the thread whose
/// membership matters. Fire-and-forget, exactly like ``EngineSink``: neither edge
/// is something the capture coordinator can meaningfully wait on or recover from,
/// and a failure degrades us to plain `.userInteractive` QoS rather than breaking
/// capture.
struct EngineIOWorkgroup: AudioIOWorkgroupJoining {
    let engine: AirPlayEngine
    func join(deviceID: AudioObjectID) { engine.joinIOWorkgroup(deviceID: UInt32(deviceID)) }
    func leave() { engine.leaveIOWorkgroup() }
}

/// Stand-in tap for macOS 14.0–14.1, where the process-tap API doesn't exist.
/// `createAndStart` throws immediately, so the coordinator lands in `.failed`
/// with a user-visible message instead of crashing.
final class UnavailableSystemTap: SystemAudioTap, @unchecked Sendable {
    var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
    var onDefaultDeviceChanged: (@Sendable () -> Void)?

    func createAndStart(muteBehavior: TapMuteBehavior, excludedProcessObjectIDs: Set<AudioObjectID>) throws -> TapFormat {
        throw NativeCaptureError.osUnsupported(minimum: "14.2")
    }

    func teardown() {}
}

/// Pure compare-before-rebuild decision for the capture taps' Core Audio property
/// listeners, split out from the live HAL reads so the DECISION — the part that is
/// easy to get subtly wrong and the part that actually breaks the storm — is
/// unit-testable without mocking Core Audio (the same pure/live split
/// ``AppRouteMixer``'s sample math uses). Both ``CoreAudioSystemTap`` and
/// ``PerAppCaptureCoordinator``'s `CoreAudioProcessTap` call these from inside
/// their listener blocks AFTER reading the current device/rate live; the tap
/// rebuilds only when a call returns `true`. The live reads stay a thin,
/// hard-to-unit-test wrapper around this.
///
/// ## The storm these guards break (confirmed by live graph analysis)
/// Every live tap pins its private aggregate to the SAME physical output device,
/// so any one tap's teardown+rebuild can perturb that shared device and re-fire
/// these listeners on every OTHER live tap. Without a changed-value guard each of
/// those no-op notifications triggers a full rebuild, which perturbs the device
/// again — a self-sustaining live-lock (the diagnosed "coreaudiod pinned at high
/// CPU while audio plays"). Comparing the freshly-read value against what the tap
/// is already built on drops the no-op notifications and cuts the feedback loop.
/// This is STRUCTURAL, not a debounce: a debounce alone would still eventually
/// fire on a no-op change.
enum TapRebuildDecision {
    /// Device-identity guard (whole-system + per-app default-device listeners):
    /// rebuild only when the freshly-read default output device differs from the
    /// one the tap is pinned to. A failed live read (`nil`) is treated as "changed"
    /// (returns `true`): a failed read is not evidence of "no change," and the
    /// rebuild path handles a subsequently-failing device resolve via its own error
    /// path — so a `nil` current ID must NOT be treated as equal to a tracked ID
    /// and must NOT suppress the fire.
    static func shouldRebuild(currentDeviceID: AudioObjectID?, trackedDeviceID: AudioObjectID) -> Bool {
        guard let currentDeviceID else { return true }
        return currentDeviceID != trackedDeviceID
    }

    /// Nominal-sample-rate guard (per-app tap only — the whole-system tap has no
    /// rate listener): rebuild only when the tapped device's freshly-read nominal
    /// rate, rounded to `Int` to match how ``TapFormat/sampleRate`` is itself
    /// computed (`Int(mSampleRate.rounded())`), differs from the rate the tap is
    /// currently running at. This deliberately compares the RATE, not device
    /// identity — a silent-tap rate renegotiation happens with the device UID
    /// UNCHANGED, the exact case the identity guard cannot catch, so comparing
    /// identity here would silently reintroduce the silent-tap bug the rate
    /// listener exists to fix. A failed live read (`nil`) is treated as "changed"
    /// (returns `true`), same rule as the device guard.
    static func shouldRebuild(currentRate: Double?, trackedRateInt: Int) -> Bool {
        guard let currentRate else { return true }
        return Int(currentRate.rounded()) != trackedRateInt
    }
}

/// The one process-wide ``DefaultOutputDeviceMonitor`` both capture taps
/// subscribe to (architecture review 2026-07-26, defect D: one owning component
/// per shared resource, instead of every tap installing its own pair of HAL
/// property listeners on the same system object and the same device).
///
/// razor: a lazily-created shared instance rather than constructor injection
/// from `NativeBackend`, because both taps are built by a default factory
/// closure inside their own coordinator — there is no dependency path down from
/// the composition root to reach them. Upgrade path: add a `monitor:` parameter
/// to ``NativeCaptureCoordinator``'s and ``PerAppCaptureCoordinator``'s public
/// inits, thread one instance from `NativeBackend`, and leave this holder as the
/// default argument only. Nothing calls `stop()`: the monitor is watcher-only and
/// process-lifetime by design, and its two listeners cost nothing while idle.
@available(macOS 14.2, *)
enum SharedDefaultOutputMonitor {
    static let instance = DefaultOutputDeviceMonitor()
}

/// The real Core Audio process tap (adapted from `dev/audiocap/TapEngine.swift`,
/// read-only reference). Creates a whole-system stereo-mixdown `CATapDescription`,
/// reads its true ASBD, builds a private aggregate device pinned to the default
/// output device, registers a realtime IOProc, and delivers buffers with a `pts`
/// taken from the IOProc's `AudioTimeStamp.mHostTime`.
///
/// It also subscribes to ``DefaultOutputDeviceMonitor`` so the coordinator can
/// recreate the tap when the default output device changes identity, or when the
/// device this tap is pinned to renegotiates its nominal sample rate in place.
///
/// NOT `kAudioHardwarePropertyDefaultSystemOutputDevice` — that selector names the
/// alert-sound device (System Preferences ▸ Sound ▸ "Play sound effects through"),
/// which is frequently NOT the device actually rendering audio. Pinning the
/// aggregate's sub-device to it silently taps the wrong hardware — the tap reports
/// success and the pipeline runs, but it captures near-silence because nothing
/// deliberately plays through the alert device. This selector was copied verbatim
/// from the `dev/audiocap/TapEngine.swift` reference sample; keep it pinned to
/// `DefaultOutputDevice` (the actual current output) everywhere below.
///
/// `AudioHardwareCreateProcessTap`/`AudioHardwareDestroyProcessTap` are macOS
/// 14.2+ (the package floor is 14.0); on 14.0–14.1 the coordinator gets an
/// ``UnavailableSystemTap`` instead.
@available(macOS 14.2, *)
final class CoreAudioSystemTap: SystemAudioTap, @unchecked Sendable {

    var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
    var onDefaultDeviceChanged: (@Sendable () -> Void)?

    private let name: String
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var format = TapFormat(
        sampleRate: 44100, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
    private var tappedOutputDeviceID: AudioObjectID = kAudioObjectUnknown

    /// The device this tap is anchored to (``SystemAudioTap/tappedDeviceID``), or nil
    /// before `createAndStart` resolved one / after `teardown()` cleared it.
    var tappedDeviceID: AudioObjectID? {
        let id = tappedOutputDeviceID
        return id == kAudioObjectUnknown ? nil : id
    }

    /// The process-wide default-output watcher this tap observes through, and the
    /// handle for its one subscription (nil until `createAndStart`, and again
    /// after `teardown()`).
    private let monitor: DefaultOutputDeviceMonitor
    private var monitorToken: DefaultOutputDeviceMonitor.SubscriptionToken?

    /// D2 telemetry ONLY (whole-system-dropout investigation, see
    /// `aggregate_create`/`aggregate_destroy`): the correlation id for the
    /// CURRENT aggregate, so `teardown()`'s `aggregate_destroy` line can be
    /// matched back to the `aggregate_create` line that made it. Set in
    /// `createAggregate()`, cleared in `teardown()` — mirrors
    /// `tappedOutputDeviceID`'s own set/clear discipline.
    private var lastAggregateUID: String?

    /// D2 telemetry ONLY: the pending ~250ms delayed nominal-rate read for
    /// the CURRENT aggregate, if any (`scheduleDelayedRateTelemetry`).
    /// Cancelled and cleared in `teardown()`, mirroring
    /// `PerAppCaptureCoordinator.membershipDiffWork`'s cancellable-
    /// `DispatchWorkItem` pattern, so a stale read can never fire once this
    /// tap's aggregate is gone and never leaks a work item.
    private var delayedRateTelemetryWork: DispatchWorkItem?

    /// D2 telemetry ONLY: a dedicated queue for the delayed read above —
    /// never the RT IOProc thread, never `NativeCaptureCoordinator`'s own
    /// state queue (which is what calls `createAggregate()`/`teardown()`),
    /// so this diagnostic read can neither block nor be blocked by either.
    private static let telemetryQueue = DispatchQueue(
        label: "com.audiouter.native.capture.telemetry", qos: .utility)

    /// Per-instance mach→CLOCK_MONOTONIC rebase offset (see `timespec(machNanos:offset:)`
    /// below). Resampled once at `startIOProc()` (i.e. every tap create/recreate,
    /// not once per process) and thereafter mutated ONLY from inside the IOProc
    /// block, which Core Audio dispatches serially onto `queue` in `startIOProc()`
    /// — so no lock is needed on this RT-adjacent path, matching this file's
    /// queue-confinement discipline elsewhere.
    private var machToMonotonicOffsetNanos: Int64 = 0

    /// T7: the AGGREGATE device's id, which is the object publishing the I/O
    /// workgroup the engine thread should join — deliberately NOT
    /// `tappedOutputDeviceID`. The default output device publishes a different,
    /// non-nesting workgroup; joining it instead would put the engine thread in the
    /// wrong one and make the (correct) later join return `EALREADY`. Same class of
    /// fact as the `DefaultOutputDevice`-vs-`DefaultSystemOutput` selector this file
    /// documents at length above: easy to "simplify" into the wrong object.
    ///
    /// `nil` before `createAggregate()` succeeds and again after `teardown()`, so a
    /// caller reading it mid-teardown gets "nothing to join" rather than a stale id.
    var workgroupDeviceID: AudioObjectID? {
        aggregateID == kAudioObjectUnknown ? nil : aggregateID
    }

    /// `monitor` defaults to the process-wide ``SharedDefaultOutputMonitor`` —
    /// the parameter exists so the hermetic suite can hand in a monitor built
    /// over a fake HAL.
    init(name: String, monitor: DefaultOutputDeviceMonitor = SharedDefaultOutputMonitor.instance) {
        self.name = name
        self.monitor = monitor
    }

    /// Backstop against leaking a system-wide process tap / aggregate device if
    /// this tap is dropped without an explicit `teardown()` — e.g. a partial
    /// `createAndStart` failure where the caller drops us, or a coordinator
    /// deallocated mid-capture. `teardown()` is idempotent and guards each object
    /// id, so a double teardown is safe.
    deinit { teardown() }

    func createAndStart(muteBehavior: TapMuteBehavior, excludedProcessObjectIDs: Set<AudioObjectID>) throws -> TapFormat {
        // Connect-latency diagnosis: brackets whole-system capture setup (tap +
        // aggregate + IOProc + rate reconciliation) — read alongside NativeBackend's
        // "connect_requested"/"connect_addoutput_*" telemetry to see whether this
        // app's own setup, vs. the AirPlay receiver's negotiation, vs. the sync
        // pre-roll, is where a slow connect's time actually goes.
        Telemetry.log(.captureWS, "create_and_start_begin")
        do {
            try createTapAndReadFormat(muteBehavior: muteBehavior, excludedProcessObjectIDs: excludedProcessObjectIDs)
            try createAggregate()
            try startIOProc()
            // The format read from `kAudioTapPropertyFormat` above was taken on the
            // BARE tap, before it joined the aggregate. The buffers the IOProc
            // actually delivers arrive on the AGGREGATE's clock, which can differ —
            // correct `format`/`asbd` to that real rate NOW, before the converter is
            // ever built from it (see `reconcileFormatWithAggregate`). Ordered after
            // `startIOProc` (aggregate live, rate settled) and before the monitor
            // subscription so its compare-before-rebuild uses the corrected rate.
            reconcileFormatWithAggregate()
            subscribeToDefaultOutput()
        } catch {
            // Any step after the tap/aggregate was created leaves live system
            // objects; tear them down before propagating so we never orphan a
            // process tap or aggregate device on a partial failure.
            teardown()
            throw error
        }
        Telemetry.log(.captureWS, "create_and_start_done", ["rate": "\(format.sampleRate)"])
        return format
    }

    // MARK: Tap creation + ASBD read

    private func createTapAndReadFormat(muteBehavior: TapMuteBehavior, excludedProcessObjectIDs: Set<AudioObjectID>) throws {
        // COLD-PROMPT GUARD (see ``SystemAudioCaptureTCC``): creating the tap is
        // what surfaces the macOS audio-capture prompt. Never do that
        // automatically — only the Setup screen's explicit "Allow…" may. If the
        // grant isn't already in place, refuse so a launch-time capture attempt
        // (a restored AirPlay selection) can't prompt cold.
        let granted = SystemAudioCaptureTCC.isGranted()
        // Telemetry (T2): the gate result itself, both outcomes — runs once
        // per tap creation/recreation, before the IOProc exists, never on the
        // RT delivery thread.
        Telemetry.log(.permission, "gate_check", [
            "site": "NativeCaptureCoordinator",
            "granted": granted ? "true" : "false",
        ])
        guard granted else {
            throw NativeCaptureError.tapCreationFailed(
                reason: "audio capture not authorized — awaiting the Setup grant")
        }
        // Whole-system stereo mixdown, excluding apps that are individually
        // routed elsewhere or user-excluded (T4 — avoids the double-send bug:
        // a routed app's audio going to its own destination AND leaking into
        // this system mix). The caller has already resolved each excluded
        // bundle id to its FULL Core Audio process-object set (main + every
        // child/helper, via ``AudioProcessResolver``) — no pid translation
        // needed here. Empty exclusion set = the whole system, unchanged.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: Array(excludedProcessObjectIDs))
        desc.uuid = UUID()
        desc.muteBehavior = muteBehavior == .mutedWhenTapped ? .mutedWhenTapped : .unmuted
        self.tapDescription = desc

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let err = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard err == noErr else {
            throw NativeCaptureError.tapCreationFailed(reason: "AudioHardwareCreateProcessTap \(err)")
        }
        self.tapID = newTapID

        // Read the ACTUAL format — never assume 48k/2ch (config-follows-tap).
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = AudioStreamBasicDescription()
        let fErr = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard fErr == noErr else {
            throw NativeCaptureError.formatReadFailed(reason: "read kAudioTapPropertyFormat \(fErr)")
        }
        // Guard the sample rate before it reaches `Int(asbd.mSampleRate.rounded())`:
        // a misbehaving driver can hand back NaN/±inf, and `Int(Float.nan)` TRAPS
        // in Swift (mirrors `SystemOutputVolume.volumeInt(fromScalar:)`'s rationale).
        // A zero/negative rate is just as poisonous downstream — it makes the
        // converter's resample ratio infinite and its `AVAudioFrameCount`
        // conversion trap. Fail loud into `.formatReadFailed` instead.
        guard asbd.mSampleRate.isFinite, asbd.mSampleRate > 0 else {
            throw NativeCaptureError.formatReadFailed(
                reason: "invalid tap sample rate \(asbd.mSampleRate)")
        }
        self.asbd = asbd
        self.format = TapFormat(
            sampleRate: Int(asbd.mSampleRate.rounded()),
            channels: Int(asbd.mChannelsPerFrame),
            bitsPerSample: Int(asbd.mBitsPerChannel),
            isFloat: (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
            isInterleaved: (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0)
    }

    private var asbd = AudioStreamBasicDescription()

    private func createAggregate() throws {
        guard let desc = tapDescription else {
            throw NativeCaptureError.aggregateDeviceFailed(reason: "no tap description")
        }
        let outputID: AudioObjectID
        let outputUID: String
        do {
            outputID = try Self.defaultOutputDeviceID()
            outputUID = try Self.readDeviceUID(outputID)
        } catch {
            throw NativeCaptureError.deviceLost(reason: String(describing: error))
        }
        self.tappedOutputDeviceID = outputID
        let aggregateUID = UUID().uuidString
        lastAggregateUID = aggregateUID

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String:          "Tap-\(name)",
            kAudioAggregateDeviceUIDKey as String:           aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String:     true,
            kAudioAggregateDeviceIsStackedKey as String:     false,
            kAudioAggregateDeviceTapAutoStartKey as String:  true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [ kAudioSubDeviceUIDKey as String: outputUID ]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: true,
                    kAudioSubTapUIDKey as String: desc.uuid.uuidString
                ]
            ]
        ]

        // D2 telemetry ONLY (whole-system-dropout investigation): read the
        // sub-device's rate immediately BEFORE the create call below — the
        // other half of the "did our own create flip the rate" comparison
        // `aggregate_create` reports. A read, never a write — cannot itself
        // perturb anything, and cannot slow the create down (no I/O, no wait).
        let rateBeforeCreate = Self.readNominalSampleRate(outputID)

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard err == noErr else {
            throw NativeCaptureError.aggregateDeviceFailed(reason: "AudioHardwareCreateAggregateDevice \(err)")
        }
        self.aggregateID = newAggregateID

        // D2 telemetry ONLY: answers "which of the four live aggregates
        // (whole-system + one per routed app) is this, does its sub-device
        // look like Bluetooth, and does it hand our aggregate an INPUT (mic)
        // stream alongside its output" — the datum that would explain a BT
        // HFP/A2DP profile flap as self-inflicted rather than the headset
        // flapping on its own. Logged once, synchronously, right here —
        // never on the RT IOProc path, which does not exist yet at this
        // point (`startIOProc()` runs after this function returns).
        Telemetry.log(.captureWS, "aggregate_create", [
            "coordinator": name,
            "aggregateUID": aggregateUID,
            "transport": Self.describeTransportType(outputID),
            "inputStreams": Self.describeStreamCount(Self.streamCount(outputID, scope: kAudioObjectPropertyScopeInput)),
            "outputStreams": Self.describeStreamCount(Self.streamCount(outputID, scope: kAudioObjectPropertyScopeOutput)),
            "rateBeforeCreate": Self.describeRate(rateBeforeCreate),
            "rateAfterCreate": Self.describeRate(Self.readNominalSampleRate(outputID)),
        ])
        scheduleDelayedRateTelemetry(deviceID: outputID, aggregateUID: aggregateUID)
    }

    /// D2 telemetry ONLY: the ~250ms-delayed half of `aggregate_create`'s
    /// nominal-rate comparison — the read that would reveal "our own create
    /// call flipped the rate" (a renegotiation that settles shortly AFTER
    /// creation, not synchronously during the API call itself). Deliberately
    /// off `createAggregate()`'s own call stack: this function schedules and
    /// returns immediately, so the 250ms wait can never slow down the create
    /// it's measuring. Runs on `telemetryQueue` — never the RT IOProc thread,
    /// never the coordinator's own state queue. `[weak self]` + the stored,
    /// cancellable `delayedRateTelemetryWork` mirror
    /// `PerAppCaptureCoordinator.membershipDiffWork`'s exact pattern:
    /// `teardown()` cancels it so a stale read can never fire once this tap
    /// is gone, and it can never leak a work item.
    private func scheduleDelayedRateTelemetry(deviceID: AudioObjectID, aggregateUID: String) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Telemetry.log(.captureWS, "aggregate_create_rate_delayed", [
                "coordinator": self.name,
                "aggregateUID": aggregateUID,
                "rateDelayed": Self.describeRate(Self.readNominalSampleRate(deviceID)),
            ])
        }
        delayedRateTelemetryWork = work
        Self.telemetryQueue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    private func startIOProc() throws {
        let channels = Int(asbd.mChannelsPerFrame)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let onBuffer = self.onBuffer

        // Seed the rebase offset fresh for THIS tap instance (not a process-wide
        // one-time sample) — see `machToMonotonicOffsetNanos` doc. This write
        // happens-before `AudioDeviceStart` below, which happens-before the
        // IOProc block below ever runs, so no lock is needed for this initial
        // handoff either.
        self.machToMonotonicOffsetNanos = Self.sampleMachToMonotonicOffsetNanos()

        var newProcID: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "com.audiouter.native.capture", qos: .userInitiated)

        let err = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, aggregateID, queue
        ) { [weak self] _, inInputData, inInputTime, _, _ in
            // ---- REALTIME THREAD ----
            guard let self else { return }
            let mutablePtr = UnsafeMutablePointer(mutating: inInputData)
            let listPtr = UnsafeMutableAudioBufferListPointer(mutablePtr)
            let bufCount = listPtr.count
            if bufCount == 0 { return }

            // pts from the IOProc's own capture clock (host time → timespec).
            // Drift self-heal: if the cached offset has fallen out of step with
            // reality (e.g. the box slept mid-tap), resample it before use —
            // two clock reads, cheap, and confined to this same serial queue so
            // no lock is needed. `machToMonotonicOffsetNanos` is only ever
            // touched from this block after the initial seed in `startIOProc`.
            let hostTime = inInputTime.pointee.mHostTime
            let machNanos = Self.machNanoseconds(fromHostTime: hostTime)
            if Self.shouldResample(
                machNanos: machNanos,
                offset: self.machToMonotonicOffsetNanos,
                monotonicNowNanos: Self.currentMonotonicNanos()
            ) {
                self.machToMonotonicOffsetNanos = Self.sampleMachToMonotonicOffsetNanos()
            }
            let pts = Self.timespec(machNanos: machNanos, offset: self.machToMonotonicOffsetNanos)

            var channelData: [Data] = []
            var frameCount = 0
            if nonInterleaved {
                channelData.reserveCapacity(bufCount)
                for i in 0..<bufCount {
                    let b = listPtr[i]
                    guard let d = b.mData, b.mDataByteSize > 0 else { continue }
                    channelData.append(Data(bytes: d, count: Int(b.mDataByteSize)))
                }
                if let first = channelData.first, bytesPerFrame > 0 {
                    frameCount = first.count / bytesPerFrame
                }
            } else {
                let b = listPtr[0]
                guard let d = b.mData, b.mDataByteSize > 0 else { return }
                channelData = [Data(bytes: d, count: Int(b.mDataByteSize))]
                let frameBytes = max(1, bytesPerFrame)
                frameCount = Int(b.mDataByteSize) / frameBytes
            }
            guard !channelData.isEmpty else { return }
            onBuffer?(CapturedBuffer(channelData: channelData, frameCount: frameCount, pts: pts))
        }
        _ = channels
        guard err == noErr else {
            throw NativeCaptureError.aggregateDeviceFailed(reason: "AudioDeviceCreateIOProcIDWithBlock \(err)")
        }
        self.ioProcID = newProcID

        let startErr = AudioDeviceStart(aggregateID, ioProcID)
        guard startErr == noErr else {
            throw NativeCaptureError.aggregateDeviceFailed(reason: "AudioDeviceStart \(startErr)")
        }
    }

    // MARK: Aggregate-rate reconciliation (converter input-rate correctness)
    //
    // ROOT CAUSE of the single-AirPlay pitch-shift bug. `createTapAndReadFormat`
    // reads `kAudioTapPropertyFormat` off the BARE process tap, before it is placed
    // in the aggregate device. The buffers the IOProc ultimately delivers, however,
    // arrive on the AGGREGATE's clock: the aggregate runs at its main sub-device's
    // nominal rate (the tapped output device) and, with sub-tap drift compensation
    // ON (`kAudioSubTapDriftCompensationKey`, set in `createAggregate`), the tap's
    // audio is sample-rate-converted ONTO that clock. So a tap whose bare-tap format
    // read back 44100 while it sits on a 48000 output device actually delivers
    // 48000-rate frames. The IOProc's frame-count math is rate-INDEPENDENT
    // (`byteSize / bytesPerFrame`), so buffers keep flowing at full cadence — but
    // building the `AVAudioConverter` from the stale 44100 makes it reinterpret
    // every 48000-rate buffer as 44100: a sustained ~8.8% (48000/44100) pitch-UP,
    // exactly the live symptom Alec heard on the simplest single-AirPlay selection.
    // Read the aggregate's REAL nominal rate here — after it exists and its IOProc
    // has started, so it has settled — and correct `format`/`asbd` to it so the
    // converter's assumed input rate can never diverge from what the hardware is
    // actually delivering. The aggregate's nominal rate (not a second
    // `kAudioTapPropertyFormat` re-read) is authoritative precisely because drift
    // compensation resamples the sub-tap ONTO the aggregate clock — that is the
    // cadence the IOProc sees. If the aggregate rate can't be read we keep the
    // pre-aggregate format (no regression vs. the prior behaviour).
    private func reconcileFormatWithAggregate() {
        guard aggregateID != kAudioObjectUnknown else { return }
        let aggregateRate = Self.readNominalSampleRate(aggregateID)
        let reconciled = Self.reconciledFormat(declared: format, aggregateRate: aggregateRate)
        guard reconciled != format else { return }
        Telemetry.log(.captureWS, "format_reconciled", [
            "declaredRate": "\(format.sampleRate)",
            "aggregateRate": "\(reconciled.sampleRate)",
        ])
        self.asbd.mSampleRate = Double(reconciled.sampleRate)
        self.format = reconciled
    }

    /// Correct a pre-aggregate tap ``TapFormat`` against the aggregate device's real
    /// nominal sample rate. Pure so it is unit-testable without a live aggregate
    /// (where the real divergence only exists). Keeps every rate-INDEPENDENT field
    /// (channels / bit-depth / float / interleave — unaffected by drift
    /// compensation, which only resamples); rewrites ONLY the sample rate, and only
    /// when the aggregate rate is readable, valid, and actually different. A
    /// nil/non-finite/≤0 aggregate rate returns `declared` unchanged (trust the
    /// pre-aggregate read over a bad one).
    static func reconciledFormat(declared: TapFormat, aggregateRate: Double?) -> TapFormat {
        guard let aggregateRate, aggregateRate.isFinite, aggregateRate > 0 else { return declared }
        let corrected = Int(aggregateRate.rounded())
        guard corrected > 0, corrected != declared.sampleRate else { return declared }
        return TapFormat(
            sampleRate: corrected,
            channels: declared.channels,
            bitsPerSample: declared.bitsPerSample,
            isFloat: declared.isFloat,
            isInterleaved: declared.isInterleaved)
    }

    /// Compare-before-rebuild loop-breaker for the nominal-sample-rate listener
    /// (mirrors the known (deviceID, nominalRate) compare-before-rebuild idiom from
    /// the CPU/coreaudiod-storm work). Rebuild ONLY when the notified rate actually
    /// differs from the rate the converter is currently built on; a notification
    /// that re-announces the SAME rate (Core Audio posts these for a set-to-same-
    /// value) must not tear down and recreate the tap. An unreadable notified rate
    /// returns `true` — we can't prove it's a no-op, so fall back to the safe
    /// rebuild rather than risk missing a real change. Pure/testable.
    static func shouldRebuildForNominalRate(notifiedRate: Double?, currentEffectiveRate: Int) -> Bool {
        guard let notifiedRate, notifiedRate.isFinite, notifiedRate > 0 else { return true }
        return Int(notifiedRate.rounded()) != currentEffectiveRate
    }

    /// Read a device's current nominal sample rate
    /// (`kAudioDevicePropertyNominalSampleRate`), or nil if unreadable/degenerate.
    /// Used both to reconcile the converter rate against the aggregate and to
    /// compare-before-rebuild inside the rate listener.
    static func readNominalSampleRate(_ deviceID: AudioObjectID) -> Double? {
        guard deviceID != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard err == noErr, rate.isFinite, rate > 0 else { return nil }
        return rate
    }

    // MARK: D2 telemetry helpers (whole-system-dropout investigation)
    //
    // Read-only HAL property probes + string formatters feeding
    // `aggregate_create`/`aggregate_create_rate_delayed`/`aggregate_destroy`
    // above and their `PerAppCaptureCoordinator.CoreAudioProcessTap`
    // counterparts (which call these directly, cross-file, the same way they
    // already call `readNominalSampleRate`/`readDeviceUID`). Every helper
    // degrades to nil/"unreadable" on failure rather than throwing — this is
    // diagnostics-only and must never affect tap creation/teardown.

    /// A device's current transport type (`kAudioDevicePropertyTransportType`)
    /// — e.g. `kAudioDeviceTransportTypeBluetooth`/`.bluetoothLE` vs.
    /// everything else — or nil if unreadable.
    static func readTransportType(_ deviceID: AudioObjectID) -> UInt32? {
        guard deviceID != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        guard err == noErr else { return nil }
        return transport
    }

    /// How many streams `deviceID` exposes in `scope`
    /// (`kAudioObjectPropertyScopeInput`/`.Output`), or nil if unreadable.
    /// This is the key datum the whole-system-dropout investigation needs: a
    /// nonzero INPUT count on the device our aggregate wraps means it is
    /// handing us a MIC stream alongside its speaker — a live candidate for
    /// forcing a Bluetooth headset's HFP/A2DP profile switch.
    static func streamCount(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int? {
        guard deviceID != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let err = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard err == noErr else { return nil }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }

    /// `readTransportType(_:)` rendered as its 4-character code (e.g.
    /// `"blue"`, `"airp"`, `"bltn"`) — the human/greppable form Core Audio's
    /// own `AudioDeviceTransportType` constants are defined in — or
    /// `"unreadable"` on any read failure.
    static func describeTransportType(_ deviceID: AudioObjectID) -> String {
        guard let raw = readTransportType(deviceID) else { return "unreadable" }
        let bytes: [UInt8] = [
            UInt8((raw >> 24) & 0xff), UInt8((raw >> 16) & 0xff),
            UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(raw)
    }

    /// `streamCount(_:scope:)`'s result as a log-ready string, or
    /// `"unreadable"` for `nil`.
    static func describeStreamCount(_ count: Int?) -> String {
        guard let count else { return "unreadable" }
        return String(count)
    }

    /// A `readNominalSampleRate(_:)` result as a whole-Hz log-ready string,
    /// or `"unreadable"` for `nil`.
    static func describeRate(_ rate: Double?) -> String {
        guard let rate else { return "unreadable" }
        return String(Int(rate.rounded()))
    }

    // MARK: Default-output subscription (device identity + nominal sample rate)
    //
    // Both changes this tap must react to used to be two private HAL property
    // listeners installed right here:
    //
    //  * `kAudioHardwarePropertyDefaultOutputDevice` — the system default output
    //    changing identity, so the tap has to re-pin its aggregate; and
    //  * `kAudioDevicePropertyNominalSampleRate` on the tapped device — the
    //    documented process-tap silent-buffer case. A process tap keeps
    //    delivering buffers at full cadence but goes SILENT (all-zero PCM) when
    //    the tapped output device renegotiates its nominal rate (44.1 ↔ 48 kHz)
    //    — classically another app taking the mic and forcing voice-processing
    //    mode, or (synced-local) a local sink opening the built-in speakers at a
    //    different rate. Apple-unresolved (Developer Forums thread 825780); the
    //    only reliable recovery is a FULL teardown + rebuild of tap AND
    //    aggregate, which `handleDeviceChange` performs. The catch is that this
    //    happens with the device's UID UNCHANGED, so the identity listener above
    //    never fires — hence the second, rate-specific one.
    //
    // Both are now observed ONCE for the whole process by
    // ``DefaultOutputDeviceMonitor`` and fanned out to this tap (architecture
    // review 2026-07-26, defect D). The compare-before-rebuild guards did NOT
    // move: the monitor evaluates the SAME pure ``TapRebuildDecision`` per
    // subscriber, against the values `tracked` reports for THIS tap, so
    // `onChange` runs only when this tap's own pinned device or effective rate
    // genuinely diverged. That is what keeps the rebuild storm broken — one
    // tap's own rebuild can perturb the shared device and re-announce these
    // properties on every other live tap, and those no-op announcements must
    // stay no-ops.
    func subscribeToDefaultOutput() {
        monitor.start()
        monitorToken = monitor.subscribe(
            label: "captureWS",
            tracked: { [weak self] in
                // READ LIVE at every notification — never a value snapshotted
                // here at subscribe time. The monitor compares against each
                // subscriber's OWN current device/rate precisely so that a tap
                // whose format drifted independently still gets told even when
                // the device's rate looks unchanged from the monitor's point of
                // view; a captured snapshot would silently reintroduce the
                // silent-tap dropout this whole path exists to fix.
                guard let self else {
                    return DefaultOutputDeviceMonitor.Tracked(
                        deviceID: kAudioObjectUnknown, rate: 0)
                }
                return DefaultOutputDeviceMonitor.Tracked(
                    deviceID: self.tappedOutputDeviceID, rate: self.format.sampleRate)
            },
            onChange: { [weak self] snapshot in
                guard let self else { return }
                // The rebuild below is unconditional: the monitor only delivers
                // here when a guard already said this tap diverged. The two
                // Telemetry events are preserved verbatim from the rate listener
                // this replaced (the live-diagnosis workflow greps them by name)
                // and now distinguish WHICH divergence drove the delivery — a
                // rate change, or a device-identity change at an unchanged rate.
                let rate = self.format.sampleRate
                if Self.shouldRebuildForNominalRate(
                    notifiedRate: snapshot.nominalRate, currentEffectiveRate: rate) {
                    Telemetry.log(.captureWS, "rate_changed_rebuild_triggered", [
                        "oldRate": "\(rate)",
                        "newRate": snapshot.nominalRate.map { String(Int($0.rounded())) } ?? "unreadable",
                    ])
                } else {
                    Telemetry.log(.captureWS, "rate_notification_no_op", ["rate": "\(rate)"])
                }
                self.onDefaultDeviceChanged?()
            })
    }

    private func unsubscribeFromDefaultOutput() {
        guard let token = monitorToken else { return }
        monitor.unsubscribe(token)
        monitorToken = nil
    }

    /// Test seam (hermetic suite only): seed the device/rate a live
    /// `createAndStart` would have resolved, so the monitor subscription can be
    /// exercised without real Core Audio.
    func test_seedTrackedState(deviceID: AudioObjectID, sampleRate: Int) {
        tappedOutputDeviceID = deviceID
        format = TapFormat(
            sampleRate: sampleRate, channels: 2, bitsPerSample: 32,
            isFloat: true, isInterleaved: false)
    }

    // MARK: Teardown (order matters: stop → destroy IOProc → destroy aggregate → destroy tap)

    func teardown() {
        // D2 telemetry ONLY: cancel any pending ~250ms delayed-rate read
        // before anything else, so it can never fire after teardown starts,
        // and snapshot what `aggregate_destroy` below needs to report before
        // the fields it reads from are cleared by this same function.
        delayedRateTelemetryWork?.cancel()
        delayedRateTelemetryWork = nil
        let telemetryDeviceID = tappedOutputDeviceID
        let telemetryAggregateUID = lastAggregateUID

        unsubscribeFromDefaultOutput()
        tappedOutputDeviceID = kAudioObjectUnknown
        if aggregateID != kAudioObjectUnknown, let proc = ioProcID {
            let stopErr = AudioDeviceStop(aggregateID, proc)
            if stopErr != noErr { AudioDiag.log("CoreAudioSystemTap.teardown AudioDeviceStop failed: \(stopErr)") }
            let destroyIOErr = AudioDeviceDestroyIOProcID(aggregateID, proc)
            if destroyIOErr != noErr {
                AudioDiag.log("CoreAudioSystemTap.teardown AudioDeviceDestroyIOProcID failed: \(destroyIOErr)")
            }
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            // D2 telemetry ONLY: same shape as `aggregate_create`, read
            // BEFORE the destroy call below so a reader can compare "at
            // create" vs. "at destroy" for the SAME `aggregateUID`. We never
            // destroy the physical sub-device itself (only our own private
            // aggregate wrapper), so it is still live and readable here.
            Telemetry.log(.captureWS, "aggregate_destroy", [
                "coordinator": name,
                "aggregateUID": telemetryAggregateUID ?? "unreadable",
                "transport": Self.describeTransportType(telemetryDeviceID),
                "inputStreams": Self.describeStreamCount(Self.streamCount(telemetryDeviceID, scope: kAudioObjectPropertyScopeInput)),
                "outputStreams": Self.describeStreamCount(Self.streamCount(telemetryDeviceID, scope: kAudioObjectPropertyScopeOutput)),
                "rate": Self.describeRate(Self.readNominalSampleRate(telemetryDeviceID)),
            ])
            let destroyAggErr = AudioHardwareDestroyAggregateDevice(aggregateID)
            if destroyAggErr != noErr {
                AudioDiag.log("CoreAudioSystemTap.teardown AudioHardwareDestroyAggregateDevice failed: \(destroyAggErr)")
            }
            aggregateID = kAudioObjectUnknown
        }
        lastAggregateUID = nil
        if tapID != kAudioObjectUnknown {
            let destroyTapErr = AudioHardwareDestroyProcessTap(tapID)
            if destroyTapErr != noErr {
                AudioDiag.log("CoreAudioSystemTap.teardown AudioHardwareDestroyProcessTap failed: \(destroyTapErr)")
            }
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: mHostTime → timespec

    /// Convert a Core Audio host time (mach ticks) to a `CLOCK_MONOTONIC`-based
    /// `timespec` presentation timestamp — the timescale
    /// ``AirPlayEngine/AirPlayEngine/write(pcm:pts:)`` actually consumes it on.
    ///
    /// CRITICAL (clock-domain fix): `AudioTimeStamp.mHostTime` is on the
    /// `mach_absolute_time` / `CLOCK_UPTIME_RAW` timescale, which does NOT advance
    /// while the machine is asleep. The engine forwards this pts to the vendored
    /// `timestamp_set()` which stores it as the player clock and compares it
    /// against `clock_gettime(CLOCK_MONOTONIC, …)` (airplay.c sync/progress paths).
    /// On Darwin `CLOCK_MONOTONIC` INCLUDES sleep time, so a raw mach-time pts
    /// trails "now" by the machine's total accumulated sleep since boot — every
    /// sync packet then advertises a position receding into the past and the
    /// receiver schedules nothing (the "Sonos light green, never white, no audio"
    /// failure the engine-probe warns about). We rebase mach time onto
    /// `CLOCK_MONOTONIC` using an offset that is (1) per-tap-instance — reseeded
    /// at every `startIOProc()`, i.e. every tap create/recreate, not sampled once
    /// for the whole process (a process-lifetime offset goes stale across ANY
    /// sleep and silences every reconnect until relaunch) — and (2) self-healed
    /// per buffer via `shouldResample`, which catches a sleep that happens
    /// mid-tap between recreations. `machNanos` and `offset` are handled in
    /// signed `Int64` nanosecond space throughout (`offset` can be negative when
    /// the box has slept), and the final result is clamped at zero.
    static func timespec(machNanos: UInt64, offset: Int64) -> timespec {
        let monotonicNanos = Int64(machNanos) &+ offset
        let clamped = monotonicNanos < 0 ? 0 : monotonicNanos
        return Darwin.timespec(tv_sec: Int(clamped / 1_000_000_000),
                               tv_nsec: Int(clamped % 1_000_000_000))
    }

    /// Test/convenience entry point: derives a fresh offset every call (no
    /// caching), so unlike the production RT path above it can never itself go
    /// stale across a sleep. Production code must go through the instance path
    /// (seeded in `startIOProc`, healed in the IOProc block) instead, since
    /// resampling both clocks on every single call is not something we want to
    /// pay for on every real captured buffer.
    static func timespec(fromHostTime hostTime: UInt64) -> timespec {
        let machNanos = machNanoseconds(fromHostTime: hostTime)
        let offset = sampleMachToMonotonicOffsetNanos()
        return timespec(machNanos: machNanos, offset: offset)
    }

    /// mach host ticks → nanoseconds on the mach-absolute timescale.
    private static func machNanoseconds(fromHostTime hostTime: UInt64) -> UInt64 {
        let timebase = cachedTimebase
        return hostTime &* UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
    }

    /// The mach timebase, read once (it never changes for the life of a process).
    private static let cachedTimebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// Current `CLOCK_MONOTONIC` reading in nanoseconds.
    private static func currentMonotonicNanos() -> UInt64 {
        var ts = Darwin.timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    /// `CLOCK_MONOTONIC_nanos - mach_absolute_nanos`, sampled fresh on each call
    /// by reading both clocks back-to-back. Adding the result to a mach-time
    /// nanosecond value rebases that value onto the `CLOCK_MONOTONIC` timescale
    /// the engine/receiver compare against. Callers cache this (per tap instance,
    /// re-seeded on create/recreate and drift-healed per buffer — see
    /// `timespec(machNanos:offset:)`) rather than calling this on every buffer,
    /// so a captured buffer's `mHostTime` maps to a stable, monotonically-
    /// advancing `CLOCK_MONOTONIC` position. Can be negative (CLOCK_MONOTONIC <
    /// mach-absolute when the box has slept), which is why all offset arithmetic
    /// in this file is signed.
    private static func sampleMachToMonotonicOffsetNanos() -> Int64 {
        // Sample both clocks as close together as possible.
        let mach = machNanoseconds(fromHostTime: mach_absolute_time())
        let monotonic = currentMonotonicNanos()
        return Int64(monotonic) &- Int64(mach)
    }

    /// Drift self-heal decision (finding B6a): true when the cached `offset`
    /// no longer agrees with reality — i.e. `machNanos + offset` (the pts this
    /// buffer would get) has drifted from an actual fresh `CLOCK_MONOTONIC`
    /// reading by more than ~1s. This is exactly what a mid-tap sleep produces
    /// (mach halts, CLOCK_MONOTONIC keeps advancing), and is the seam a caller
    /// resamples `machToMonotonicOffsetNanos` from. Pure/signed so it is testable
    /// without a real clock.
    static func shouldResample(machNanos: UInt64, offset: Int64, monotonicNowNanos: UInt64) -> Bool {
        let predicted = Int64(machNanos) &+ offset
        let diff = predicted &- Int64(monotonicNowNanos)
        return diff.magnitude > 1_000_000_000
    }

    // MARK: Device reads (adapted from CAHelpers.swift)

    static func defaultOutputDeviceID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard err == noErr, deviceID != kAudioObjectUnknown else {
            throw NativeCaptureError.deviceLost(reason: "no default output device (\(err))")
        }
        return deviceID
    }

    static func readDeviceUID(_ deviceID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString? = nil
        let err = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr, let uid = uid else {
            throw NativeCaptureError.deviceLost(reason: "read device UID (\(err))")
        }
        return uid as String
    }
}

/// AVAudioConverter-backed ``PCMConverting``: converts the tap's real format to
/// the engine's fixed S16LE / 44100 / 2ch. Handles rate conversion (resample only
/// when the tap rate ≠ 44100), Float32→Int16, channel matching, and interleaving.
final class AVFormatConverter: PCMConverting, @unchecked Sendable {

    private let sourceFormat: TapFormat
    private let inputAVFormat: AVAudioFormat?
    private let outputAVFormat: AVAudioFormat?
    private let converter: AVAudioConverter?
    private let lock = NSLock()

    init(from format: TapFormat) {
        self.sourceFormat = format

        // Input format from the real tap ASBD.
        var inASBD = AudioStreamBasicDescription()
        inASBD.mSampleRate = Double(format.sampleRate)
        inASBD.mFormatID = kAudioFormatLinearPCM
        inASBD.mChannelsPerFrame = UInt32(max(1, format.channels))
        inASBD.mBitsPerChannel = UInt32(format.bitsPerSample)
        inASBD.mFramesPerPacket = 1
        var inFlags: AudioFormatFlags = kAudioFormatFlagIsPacked
        inFlags |= format.isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
        if !format.isInterleaved { inFlags |= kAudioFormatFlagIsNonInterleaved }
        inASBD.mFormatFlags = inFlags
        let bytesPerSample = UInt32(format.bitsPerSample / 8)
        if format.isInterleaved {
            inASBD.mBytesPerFrame = bytesPerSample * inASBD.mChannelsPerFrame
            inASBD.mBytesPerPacket = inASBD.mBytesPerFrame
        } else {
            inASBD.mBytesPerFrame = bytesPerSample
            inASBD.mBytesPerPacket = bytesPerSample
        }
        self.inputAVFormat = AVAudioFormat(streamDescription: &inASBD)

        // Output = the engine's one accepted format (S16LE / 44100 / 2ch, interleaved).
        let out = PCMFormat.airplay
        self.outputAVFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(out.sampleRate),
            channels: AVAudioChannelCount(out.channels),
            interleaved: true)

        if let i = inputAVFormat, let o = outputAVFormat {
            self.converter = AVAudioConverter(from: i, to: o)
        } else {
            self.converter = nil
        }
    }

    func convertToAirPlayPCM(_ buffer: CapturedBuffer) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let converter, let inFmt = inputAVFormat, let outFmt = outputAVFormat,
              buffer.frameCount > 0 else { return nil }

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt,
                                           frameCapacity: AVAudioFrameCount(buffer.frameCount)) else {
            return nil
        }
        inBuf.frameLength = AVAudioFrameCount(buffer.frameCount)

        // Copy captured bytes into the input buffer (planar → per-channel, interleaved → single).
        if sourceFormat.isInterleaved {
            guard let src = buffer.channelData.first else { return nil }
            let dst = inBuf.audioBufferList.pointee.mBuffers
            copy(src, into: dst.mData, cap: Int(dst.mDataByteSize))
        } else {
            let abl = UnsafeMutableAudioBufferListPointer(inBuf.mutableAudioBufferList)
            for ch in 0..<min(abl.count, buffer.channelData.count) {
                let dst = abl[ch]
                copy(buffer.channelData[ch], into: dst.mData, cap: Int(dst.mDataByteSize))
            }
        }

        // Output capacity sized for the resampled frame count (round up). Guard the
        // input rate: a zero/non-finite `inFmt.sampleRate` makes `ratio` infinite
        // and the `AVAudioFrameCount(...)` conversion below TRAP. The tap-format
        // guard in `createTapAndReadFormat` should prevent this ever being reached,
        // but a converter built from a bad format must fail soft (drop the buffer),
        // never crash the capture thread.
        guard inFmt.sampleRate.isFinite, inFmt.sampleRate > 0,
              outFmt.sampleRate.isFinite else { return nil }
        let ratio = Double(outFmt.sampleRate) / Double(inFmt.sampleRate)
        let outCapacity = AVAudioFrameCount(Double(buffer.frameCount) * ratio) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCapacity) else {
            return nil
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuf, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return inBuf
        }
        guard status != .error, conversionError == nil, outBuf.frameLength > 0 else { return nil }

        // Extract interleaved S16LE bytes.
        let outABL = outBuf.audioBufferList.pointee.mBuffers
        guard let outData = outABL.mData, outABL.mDataByteSize > 0 else { return nil }
        return Data(bytes: outData, count: Int(outABL.mDataByteSize))
    }

    private func copy(_ src: Data, into dst: UnsafeMutableRawPointer?, cap: Int) {
        guard let dst else { return }
        let n = min(src.count, cap)
        src.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(dst, base, n) }
        }
    }
}

#endif
