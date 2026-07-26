import Foundation

#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// Owns N independent per-PROCESS Core Audio capture taps, one per routed
/// app, keyed by bundle identifier (T3). This is the per-app analogue of
/// ``NativeCaptureCoordinator`` — same state-machine discipline, same
/// injected-seam testability, same converter-free "hand back raw captured
/// buffers with a clock-derived pts" contract — but where that coordinator
/// owns exactly ONE whole-system tap, this one owns a *dictionary* of
/// independent per-bundle-ID taps that can be created and destroyed without
/// disturbing one another.
///
/// ## Port provenance
/// The Core Audio mechanics are a disciplined port of the proven prototype in
/// `dev/audiocap`:
///   - `TapEngine.stereoMixdownOfProcesses` (`dev/audiocap/Sources/audiocap/TapEngine.swift`)
///     → `CoreAudioProcessTap.createTapAndReadFormat` below.
/// Bundle-ID-to-process-object resolution (originally a pid-to-single-object
/// port of `CAHelpers.swift`'s `translatePIDToProcessObject`) now lives in
/// ``AudioProcessResolver``, which resolves the FULL set of process objects a
/// bundle ID owns rather than one. The aggregate-device / IOProc /
/// teardown-order machinery is reused nearly verbatim from
/// ``NativeCaptureCoordinator``'s `CoreAudioSystemTap` (the per-app tap is
/// just scoped to the resolved process objects instead of the whole system)
/// — including its `mHostTime -> CLOCK_MONOTONIC` pts rebase
/// (`CoreAudioSystemTap.timespec(fromHostTime:)`, called directly rather than
/// duplicated) and its device-UID helper (`CoreAudioSystemTap.readDeviceUID`).
///
/// ## One deliberate deviation: the default-device selector
/// `defaultOutputDeviceID()` below reads `kAudioHardwarePropertyDefaultOutputDevice`,
/// NOT `kAudioHardwarePropertyDefaultSystemOutputDevice` (the selector
/// `dev/audiocap` and the current `CoreAudioSystemTap` use). The System
/// selector is the *alert-sound* device, not the device the user actually
/// hears through — copying it verbatim from the audiocap sample is a known,
/// tracked bug (fix pending merge into `NativeCaptureCoordinator` on a
/// separate branch). This is new code, so it uses the correct selector from
/// the start rather than reintroducing the bug.
///
/// ## Bundle ID -> process-object resolution stays OUT of Core
/// Attributing a bare pid (or a nil-bundle-id child process) to a bundle ID
/// needs `NSRunningApplication` in the general case, which lives in AppKit
/// (`AudiouterCore` must never import AppKit — package rule,
/// `AudiouterCore/AGENTS.md`). ``AudioProcessResolver`` isolates that one seam
/// behind its own injected `bundleIDForPID` closure and does the rest itself
/// (enumerating live Core Audio process objects, walking parent pids); this
/// coordinator is handed an already-constructed ``AudioProcessResolver`` and
/// never touches AppKit.
///
/// ## Known edge cases (do not "fix" these with speculative logic)
/// - A bundle ID that resolves to NO live Core Audio process objects — the
///   app isn't running yet, or is running but has never opened an audio
///   stream — surfaces as the distinct, retryable
///   ``PerAppCaptureError/processNotYetAudible(bundleID:)`` (not a crash, not
///   lumped in with a generic tap-creation failure) so a caller can retry
///   `start(bundleID:)` once the app starts playing audio.
///   ``AudioProcessResolver`` cannot distinguish "not running" from "running
///   but silent" — both are an empty resolved set — so both retry the same way.
/// - A denied or never-granted TCC (system-audio-recording) permission
///   yields a *successful* tap that silently delivers all-zero buffers —
///   Core Audio does not report this as an error. This coordinator therefore
///   does NOT attempt to detect "all-zero buffer => permission denied"; that
///   heuristic doesn't belong here (same stance ``NativeCaptureCoordinator``
///   takes). Buffers are forwarded as delivered, verbatim.
///
/// ## Not wired in yet
/// This is a self-contained, independently testable component. Nothing else
/// in the app calls it yet — T4 (excluding routed apps from the system-wide
/// tap) and T5 (the per-app mixer) are the consumers.
public final class PerAppCaptureCoordinator: @unchecked Sendable {

    // MARK: State machine (per bundle ID)

    /// One bundle ID's capture lifecycle. Mirrors ``NativeCaptureCoordinator/State``
    /// with an extra `.resolvingProcess` step up front (process-object
    /// resolution happens before any Core Audio tap call).
    public enum State: Equatable, Sendable {
        /// Not running (or never started). `start(bundleID:)` moves out;
        /// `stop(bundleID:)` returns here.
        case idle
        /// Resolving the bundle ID to its live Core Audio process objects via
        /// the injected ``AudioProcessResolver``.
        case resolvingProcess
        /// Creating the tap (a mixdown of every resolved process object) +
        /// aggregate device (may trigger the TCC prompt on first ever run,
        /// exactly like the system-wide tap).
        case creatingTap
        /// Steady state: the tap is running and buffers are being forwarded.
        /// Carries the tap's real captured format.
        case capturing(TapFormat)
        /// Tearing the tap + aggregate device down.
        case stopping
        /// A terminal-until-retried error. `start(bundleID:)` from here resets
        /// and retries; `stop(bundleID:)` from here still cleans up.
        case failed(PerAppCaptureError)
    }

    // MARK: Injected dependencies

    private let makeTap: @Sendable () -> ProcessAudioTap
    private let processResolver: AudioProcessResolver
    private let muteBehavior: TapMuteBehavior
    /// This instance's short label — the SAME string that names its private
    /// tap/aggregate devices — stamped on every `capturePA` transition as
    /// `coordinator`.
    ///
    /// There is more than ONE live `PerAppCaptureCoordinator` in the app
    /// (`NativeBackend.perAppCapture`, the routing one, and
    /// `NativeBackend.meteringCapture`, the `.unmuted` metering-only one),
    /// both logging `capturePA` transitions for the SAME bundle IDs into the
    /// SAME telemetry stream. Without a discriminator the two interleave into
    /// sequences that look impossible for one state machine — a
    /// `from: capturing` with no preceding `to: capturing`, or a long "gap"
    /// that is really one instance sitting healthily in `.capturing` while the
    /// other churns. That misread cost a live-test session hours (see
    /// `docs/plans/PLAN-LIVE-TEST-HANDOFF-2026-07-25.md`); the field is what
    /// makes the log readable.
    private let name: String
    /// Whether `start(bundleID:)` arms the REAL, live system-wide
    /// ``kAudioHardwarePropertyProcessObjectList`` listener
    /// (``installProcessListListenerLocked()``). Defaults to `true` in the
    /// designated initializer below, so production (and every call site that
    /// predates this seam) is unaffected. Hermetic tests that never want a
    /// registration on the actual system Core Audio object — which notifies
    /// on ANY process anywhere on the machine opening or closing an audio
    /// session, not just bundle IDs this coordinator tracks, and whose
    /// handler re-enters `start(bundleID:)` from an internal HAL thread at an
    /// unpredictable moment — pass `false`. ``handleProcessListChanged()``
    /// stays directly callable either way, so a test can still simulate the
    /// notification deterministically instead of relying on live HAL churn.
    private let installsProcessListListener: Bool

    // MARK: State (confined to `queue`)

    /// Per-bundle-ID mutable state. A reference type so `slotFor(_:)` can hand
    /// back a stable handle that later closures mutate in place without a
    /// second dictionary write.
    private final class Slot {
        var state: State = .idle
        var tap: ProcessAudioTap?
        /// STABILITY(C6) (per-app port): set when a device-change notification
        /// arrives while this slot is mid-rebuild (`.creatingTap`), so it isn't
        /// silently dropped — see `handleDeviceChange(bundleID:)` and
        /// dev/notes/stability-audit-2026-07-18.md §C6.
        var pendingDeviceChange = false
        /// W1-T4: the process-OBJECT set this slot's LIVE tap was last built
        /// against — the per-slot compare-before-rebuild baseline for live
        /// membership diffing (``handleMembershipChange()``). Recorded on each
        /// successful `.capturing` commit; an unchanged resolve does ZERO work.
        var lastTappedProcessObjects: Set<AudioObjectID> = []
    }

    private let queue = DispatchQueue(label: "PerAppCaptureCoordinator.state")
    private var slots: [String: Slot] = [:]

    #if canImport(AudioToolbox)
    /// System-wide "a process's audio object appeared/disappeared" listener (T3
    /// self-heal). Registered ONCE, lazily, on the first `start(bundleID:)` and
    /// removed in `deinit` — paired add/remove, no leak. See
    /// ``installProcessListListenerLocked()`` for why this is the resume signal
    /// and how it re-drives dead slots through the ordinary `start` path.
    ///
    /// Stored (rather than recomputed at removal time) so the exact block handed
    /// to `AudioObjectAddPropertyListenerBlock` is the exact block removed —
    /// structural add/remove symmetry, the same discipline ``SystemOutputVolume``
    /// keeps. Touched only on ``queue``.
    private var processListBlock: AudioObjectPropertyListenerBlock?

    /// The one address we register the above block on. A `let` so add and remove
    /// can never drift apart.
    private static let processObjectListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    #endif

    /// W1-T4 live-membership diffing: a dedicated DEBOUNCED serial queue owning the
    /// diff timer, DISTINCT from ``queue`` (``handleMembershipChange`` reaches into
    /// state via `queue.sync`, which would deadlock if run on `queue`). The same
    /// process-object-list listener that re-drives dead slots (the resume
    /// self-heal) ALSO schedules a debounced diff here so a browser tab spawning a
    /// new audio child mid-session — while its slot is already `.capturing` — is
    /// picked up too, not just a fully-dead slot resuming.
    private let membershipQueue = DispatchQueue(label: "PerAppCaptureCoordinator.membership")
    /// The pending coalesced diff. Confined to ``membershipQueue``; cancelled and
    /// replaced by each notification in the debounce window so a rapid
    /// spawn/kill/spawn burst collapses to one diff pass.
    private var membershipDiffWork: DispatchWorkItem?
    /// How long to wait for process-list churn to settle before diffing.
    /// Injectable so tests can shrink it; production coalesces a burst of tab
    /// open/close notifications into one diff.
    private let membershipDebounceInterval: DispatchTimeInterval

    /// Fired on every per-bundle-ID state transition. Called on the
    /// coordinator's internal queue.
    public var onStateChange: (@Sendable (_ bundleID: String, _ state: State) -> Void)?

    /// Fired once per captured buffer, tagged with the bundle ID it came
    /// from, so a caller (T5's mixer) can tell independent apps' audio apart.
    /// Called from that tap's delivery (IOProc) thread — NOT the `queue.sync`
    /// thread, so concurrent buffers from different apps can arrive on
    /// different threads. Keep the handler cheap and lock-light, same
    /// contract as ``NativeCaptureCoordinator/onLevel``.
    public var onBuffer: (@Sendable (_ bundleID: String, _ buffer: CapturedBuffer) -> Void)?

    /// Bundle IDs currently in `.capturing` — the live set T4 needs to
    /// exclude from the system-wide tap.
    public var capturingBundleIDs: Set<String> {
        queue.sync {
            Set(slots.compactMap { key, slot -> String? in
                if case .capturing = slot.state { return key }
                return nil
            })
        }
    }

    // MARK: Init

    /// Production initializer: wires the real per-process Core Audio tap.
    /// - Parameters:
    ///   - processResolver: resolves a bundle ID to the FULL set of live Core
    ///     Audio process objects it owns (main process + any child/helper
    ///     processes a multi-process app like Firefox emits audio from).
    ///     Already constructed by the caller — its own `bundleIDForPID` seam
    ///     needs `NSRunningApplication`, so an AppKit-importing layer builds
    ///     it; this coordinator only consumes it.
    ///   - name: a short label used for the private tap/aggregate device
    ///     names (one aggregate per active bundle ID, named `"PerAppTap-
    ///     <name>-<bundleID>"`).
    ///   - muteBehavior: `.mutedWhenTapped` (default) silences the tapped
    ///     app's local playback while capturing, matching the routing intent
    ///     (its audio goes to the redirect target, not the built-in speakers).
    #if canImport(AudioToolbox)
    public convenience init(
        processResolver: AudioProcessResolver,
        name: String = "AirPlayController",
        muteBehavior: TapMuteBehavior = .mutedWhenTapped
    ) {
        self.init(
            makeTap: {
                if #available(macOS 14.2, *) {
                    return CoreAudioProcessTap(name: name)
                } else {
                    return UnavailableProcessTap()
                }
            },
            processResolver: processResolver,
            muteBehavior: muteBehavior,
            name: name
        )
    }
    #endif

    /// Injectable designated initializer (internal — tests pass a fake tap
    /// factory and an ``AudioProcessResolver`` built over a fake
    /// ``AudioProcessEnumerating`` so the state machine runs without a real
    /// tap, real Core Audio, or a real running app).
    /// - Parameter installsProcessListListener: see the stored property of
    ///   the same name. Defaults to `true` — production behavior, unchanged.
    init(
        makeTap: @escaping @Sendable () -> ProcessAudioTap,
        processResolver: AudioProcessResolver,
        muteBehavior: TapMuteBehavior = .mutedWhenTapped,
        name: String = "AirPlayController",
        installsProcessListListener: Bool = true,
        membershipDebounceInterval: DispatchTimeInterval = .milliseconds(300)
    ) {
        self.makeTap = makeTap
        self.processResolver = processResolver
        self.muteBehavior = muteBehavior
        self.name = name
        self.installsProcessListListener = installsProcessListListener
        self.membershipDebounceInterval = membershipDebounceInterval
    }

    /// Tears down every still-active tap. A backstop against leaking system
    /// Core Audio objects if the coordinator is deallocated without every
    /// bundle ID having been explicitly `stop(bundleID:)`-ed (each concrete
    /// tap also has its own `deinit`-based backstop).
    deinit {
        #if canImport(AudioToolbox)
        // Symmetric removal of the resume listener installed by the first
        // `start(bundleID:)`. Safe to touch the field directly: the block
        // captures `self` weakly, so a block mid-flight holds a strong reference
        // and `deinit` cannot run concurrently with one (same argument
        // ``SystemOutputVolume.deinit`` makes).
        removeProcessListListenerLocked()
        membershipQueue.sync { membershipDiffWork?.cancel(); membershipDiffWork = nil }
        #endif
        let leftover = queue.sync { slots.values.compactMap { $0.tap } }
        leftover.forEach { $0.teardown() }
    }

    // MARK: Public lifecycle (idempotent, independent per bundle ID)

    /// The current state for `bundleID` (thread-safe snapshot). Bundle IDs
    /// that were never started, or were fully stopped, report `.idle`.
    public func state(for bundleID: String) -> State {
        queue.sync { slots[bundleID]?.state ?? .idle }
    }

    /// Start capture for `bundleID`: resolve its FULL set of live Core Audio
    /// process objects (main + any child/helper processes), create its own
    /// tap + aggregate device as a mixdown of all of them, and start
    /// delivering buffers tagged with this bundle ID. Idempotent per bundle
    /// ID: calling while that bundle ID is already resolving/creating/
    /// capturing is a no-op. Calling from `.failed` resets and retries —
    /// the right response to a retryable error like
    /// ``PerAppCaptureError/processNotYetAudible(bundleID:)``.
    ///
    /// Starting one bundle ID never disturbs any other bundle ID's tap —
    /// each has its own `Slot` and its own tap instance; only the (fast,
    /// non-blocking) state-transition bookkeeping is serialized through
    /// `queue`, never the blocking Core Audio calls themselves.
    public func start(bundleID: String) {
        let claimed: Bool = queue.sync {
            #if canImport(AudioToolbox)
            // First tap of this coordinator's life arms the system-wide resume
            // listener (idempotent). Doing it here, rather than in `init`, keeps a
            // coordinator that never starts a tap from touching the HAL at all.
            installProcessListListenerLocked()
            #endif
            let slot = slotFor(bundleID)
            switch slot.state {
            case .idle, .failed:
                transition(slot, bundleID: bundleID, to: .resolvingProcess)
                return true
            default:
                return false // already in flight — idempotent
            }
        }
        guard claimed else { return }
        beginStart(bundleID: bundleID)
    }

    /// Stop capture for `bundleID`: tear its tap + aggregate device down and
    /// forget it entirely (the slot is removed, not just reset to `.idle`,
    /// so a coordinator that starts/stops many apps over its lifetime never
    /// accumulates unbounded dictionary entries). Idempotent: `stop(bundleID:)`
    /// for a bundle ID that is idle or was never started is a no-op. Does
    /// not affect any other bundle ID's tap.
    public func stop(bundleID: String) {
        let toTearDown: ProcessAudioTap? = queue.sync {
            guard let slot = slots[bundleID] else { return nil }
            if case .idle = slot.state { return nil }
            let t = slot.tap
            transition(slot, bundleID: bundleID, to: .stopping)
            return t
        }
        // Tear down OUTSIDE the state lock (teardown may block on Core Audio),
        // matching NativeCaptureCoordinator.stop()'s discipline.
        toTearDown?.teardown()
        queue.sync {
            guard let slot = slots[bundleID] else { return }
            slot.tap = nil
            transition(slot, bundleID: bundleID, to: .idle)
            slots.removeValue(forKey: bundleID) // clean teardown — no leaked state
        }
    }

    /// Stop every currently-tracked bundle ID's capture.
    public func stopAll() {
        let ids = queue.sync { Array(slots.keys) }
        for id in ids { stop(bundleID: id) }
    }

    // MARK: Start sequence
    //
    // This coordinator must let independent bundle IDs' start/stop calls
    // interleave — so the pattern here is the "claim under the lock, do the
    // blocking work outside it, then commit under the lock" shape
    // NativeCaptureCoordinator also uses (its start() and recreateTap()).
    // Every commit re-checks the slot is still in the state we left it in, so
    // a concurrent stop(bundleID:) racing in during tap creation is handled by
    // tearing the just-created tap back down instead of resurrecting a stopped
    // slot.

    /// Reject a tap format the converter/aggregate can't safely consume before
    /// it commits to `.capturing` — ported verbatim from
    /// `NativeCaptureCoordinator.validate(_:)` (architecture review
    /// 2026-07-26, defect A). A non-positive sample rate makes a downstream
    /// resample ratio infinite and an `AVAudioFrameCount` conversion trap; the
    /// real tap's `createTapAndReadFormat` already guards the raw ASBD, but
    /// validating here also covers an injected/degenerate format and keeps
    /// the failure on the `.failed` state path rather than a crash.
    static func validate(_ format: TapFormat) throws {
        guard format.sampleRate > 0 else {
            throw PerAppCaptureError.formatReadFailed(
                reason: "invalid tap sample rate \(format.sampleRate)")
        }
    }

    private func beginStart(bundleID: String) {
        let processes = processResolver.resolve(bundleID: bundleID)
        guard !processes.isEmpty else {
            queue.sync {
                guard let slot = slots[bundleID], case .resolvingProcess = slot.state else { return }
                transition(slot, bundleID: bundleID, to: .failed(.processNotYetAudible(bundleID: bundleID)))
            }
            return
        }

        let proceed: Bool = queue.sync {
            guard let slot = slots[bundleID], case .resolvingProcess = slot.state else { return false }
            transition(slot, bundleID: bundleID, to: .creatingTap)
            return true
        }
        guard proceed else { return }

        let tap = makeTap()
        tap.onBuffer = { [weak self] buffer in self?.onBuffer?(bundleID, buffer) }
        tap.onDefaultDeviceChanged = { [weak self] in self?.handleDeviceChange(bundleID: bundleID) }

        do {
            let format = try tap.createAndStart(processes: processes, bundleID: bundleID, muteBehavior: muteBehavior)
            try Self.validate(format)
            queue.sync {
                guard let slot = slots[bundleID], case .creatingTap = slot.state else {
                    tap.teardown() // a stop() (or a second start()) raced in — don't leak this tap
                    return
                }
                slot.tap = tap
                slot.lastTappedProcessObjects = Set(processes.map(\.objectID)) // W1-T4 compare-before-rebuild baseline
                transition(slot, bundleID: bundleID, to: .capturing(format))
            }
        } catch {
            tap.teardown()
            let mapped: PerAppCaptureError = (error as? PerAppCaptureError)
                ?? .tapCreationFailed(reason: String(describing: error))
            queue.sync {
                guard let slot = slots[bundleID], case .creatingTap = slot.state else { return }
                slot.tap = nil
                transition(slot, bundleID: bundleID, to: .failed(mapped))
            }
        }
    }

    /// The default output device changed under a capturing tap (its aggregate
    /// is pinned to it, same as the system-wide tap). Re-resolve the bundle
    /// ID's process set (it may have relaunched, or gained/lost child
    /// processes, since capture started) and recreate the tap + aggregate
    /// against the new device.
    private func handleDeviceChange(bundleID: String) {
        Telemetry.log(.capturePA, "device_change_fired", ["bundleID": bundleID])
        // STABILITY(C6) (per-app port of NativeCaptureCoordinator's fix sketch,
        // dev/notes/stability-audit-2026-07-18.md §C6): if this notification
        // arrives while the slot is already mid-rebuild (`.creatingTap`), don't
        // drop it — mark it pending so the in-flight rebuild replays a fresh
        // handleDeviceChange once it lands in `.capturing`. Rapid sample-rate
        // bounces (44.1 -> 48 -> 44.1) mean the LAST notification can be the one
        // that would otherwise be dropped, rebuilding against a stale rate.
        let claim: (proceed: Bool, old: ProcessAudioTap?, oldFormat: TapFormat?) = queue.sync {
            guard let slot = slots[bundleID] else { return (false, nil, nil) }
            guard case .capturing(let oldFormat) = slot.state else {
                if case .creatingTap = slot.state {
                    slot.pendingDeviceChange = true
                }
                return (false, nil, nil)
            }
            let old = slot.tap
            slot.tap = nil
            transition(slot, bundleID: bundleID, to: .creatingTap)
            return (true, old, oldFormat)
        }
        guard claim.proceed else {
            // Pending-rebuild coalescing (STABILITY(C6)): this notification
            // arrived while the slot was already mid-rebuild (or gone) and is
            // being dropped/deferred rather than acted on immediately —
            // `pendingNow` reports whether it was coalesced (the in-flight
            // rebuild will replay it once it lands in `.capturing`, see the
            // "replaying coalesced pending device change" log below) or
            // simply discarded (no slot / not capturing and not rebuilding).
            let pendingNow = queue.sync { slots[bundleID]?.pendingDeviceChange ?? false }
            Telemetry.log(.capturePA, "device_change_coalesced", ["bundleID": bundleID, "pending": String(pendingNow)])
            return
        }
        claim.old?.teardown()

        let processes = processResolver.resolve(bundleID: bundleID)
        guard !processes.isEmpty else {
            // The subsequent .failed(.processNotYetAudible) transition below
            // already carries this reason in its "transition"/"error" telemetry
            // field (see `transition(_:bundleID:to:)`).
            queue.sync {
                guard let slot = slots[bundleID], case .creatingTap = slot.state else { return }
                transition(slot, bundleID: bundleID, to: .failed(.processNotYetAudible(bundleID: bundleID)))
            }
            return
        }

        let newTap = makeTap()
        newTap.onBuffer = { [weak self] buffer in self?.onBuffer?(bundleID, buffer) }
        newTap.onDefaultDeviceChanged = { [weak self] in self?.handleDeviceChange(bundleID: bundleID) }

        do {
            let format = try newTap.createAndStart(processes: processes, bundleID: bundleID, muteBehavior: muteBehavior)
            try Self.validate(format)
            // The subsequent .capturing(format) transition below already carries
            // the new format in its "transition"/"format" telemetry field.
            // The single highest-value event in PLAN-TELEMETRY-SYSTEM.md's T3:
            // the tapped output device silently renegotiating its nominal
            // sample rate (see the "Nominal-sample-rate listener" doc comment
            // on CoreAudioProcessTap below) is exactly what a same-bundle
            // rebuild with a changed rate looks like from here, regardless of
            // which HAL listener (default-device identity vs. nominal-rate)
            // proximately triggered it — so gate on the OBSERVABLE rate delta
            // rather than the cause. (CoreAudioProcessTap.installSampleRateListener
            // below also emits this directly from the real HAL notification,
            // with richer device/rate detail; that site fires only for a
            // genuine rate change but isn't reachable by this hermetic suite —
            // no live Core Audio here — so this coordinator-level emission,
            // testable via the existing FakeProcessTap/fireDeviceChange()
            // seam, is the one exercised by PerAppCaptureCoordinatorTests.)
            if let oldFormat = claim.oldFormat, oldFormat.sampleRate != format.sampleRate {
                Telemetry.log(.capturePA, "rate_rebuild", [
                    "bundleID": bundleID,
                    "oldRate": String(oldFormat.sampleRate),
                    "newRate": String(format.sampleRate),
                ])
            }
            let replay: Bool = queue.sync {
                guard let slot = slots[bundleID], case .creatingTap = slot.state else {
                    newTap.teardown()
                    return false
                }
                slot.tap = newTap
                slot.lastTappedProcessObjects = Set(processes.map(\.objectID)) // W1-T4 compare-before-rebuild baseline
                transition(slot, bundleID: bundleID, to: .capturing(format))
                // STABILITY(C6): a device-change notification landed while we were
                // rebuilding — replay it once now that we're capturing again,
                // coalescing however many were dropped into a single retry.
                guard slot.pendingDeviceChange else { return false }
                slot.pendingDeviceChange = false
                return true
            }
            if replay {
                Telemetry.log(.capturePA, "device_change_replay", ["bundleID": bundleID])
                handleDeviceChange(bundleID: bundleID)
            }
        } catch {
            newTap.teardown()
            let mapped: PerAppCaptureError = (error as? PerAppCaptureError)
                ?? .tapCreationFailed(reason: String(describing: error))
            // The subsequent .failed(mapped) transition below already carries
            // this error in its "transition"/"error" telemetry field.
            queue.sync {
                guard let slot = slots[bundleID], case .creatingTap = slot.state else { return }
                slot.tap = nil
                transition(slot, bundleID: bundleID, to: .failed(mapped))
            }
        }
    }

    // MARK: System-wide resume self-heal (T3)
    //
    // A routed app that was paused (or hadn't yet played audio) fails to tap
    // with `.processNotYetAudible`: `AudioProcessResolver.resolve(bundleID:)`
    // returns an empty set because no Core Audio process object exists for it
    // yet. T2's capped-exponential backoff already re-probes such a slot forever, so
    // correctness is covered — but the backoff can idle up to its 10 s cap
    // between probes, which is a visible lag between "app resumes audio" and
    // "its audio starts flowing to the speaker".
    //
    // The moment a paused app resumes, it (re)connects to the audio system and a
    // process object appears in `kAudioHardwarePropertyProcessObjectList` — a
    // listenable property on the system object (AudioHardware.h: "an array of
    // AudioObjectIDs ... for all client processes currently connected to the
    // system"). Listening for that list changing lets a dead slot self-heal
    // essentially instantly instead of waiting out the backoff.
    //
    // This is a latency optimization layered ON TOP of the backoff, not a
    // replacement: the recovery itself flows through the ordinary `start`
    // path, so it reuses every existing invariant.

    #if canImport(AudioToolbox)
    /// Arm the system-wide process-object-list listener. Idempotent — a no-op
    /// once installed, so calling it from every `start(bundleID:)` costs nothing
    /// after the first. MUST hold ``queue`` (installs the registration state).
    ///
    /// The block is dispatched by the HAL on an **internal** thread (`nil`
    /// dispatch queue), NOT on ``queue`` — deliberately: the handler calls back
    /// into `start(bundleID:)`, which itself does `queue.sync`, so running the
    /// block on `queue` would deadlock. `nil` matches the idiom the per-app
    /// tap's own default-device / sample-rate listeners already use in this
    /// file. Process-list changes are never delivered from the IO context, so
    /// the async-dispatch caveat in AudioHardware.h does not bite.
    private func installProcessListListenerLocked() {
        // Test-only opt-out (see `installsProcessListListener`'s doc comment
        // on the stored property above) — skips ever touching the real HAL
        // for this listener, production behavior unchanged (defaults `true`).
        guard installsProcessListListener else { return }
        guard processListBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleProcessListChanged()
        }
        var address = Self.processObjectListAddress
        let err = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
        guard err == noErr else {
            Telemetry.log(.capturePA, "resume_listener_install_failed", ["err": "\(err)"])
            return
        }
        processListBlock = block
        Telemetry.log(.capturePA, "resume_listener_armed")
    }

    /// Symmetric removal. MUST hold ``queue`` (or run in `deinit`, where no
    /// block can be concurrently live — see the `deinit` note).
    private func removeProcessListListenerLocked() {
        guard let block = processListBlock else { return }
        var address = Self.processObjectListAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
        processListBlock = nil
    }

    /// A process connected to / disconnected from the audio system. Re-drive
    /// every one of OUR dead-but-retryable slots through the ordinary
    /// `start(bundleID:)` path: if the app has now resumed, it finally
    /// resolves to a live process object and the tap builds, landing the slot
    /// in `.capturing` — which fires `onStateChange`, exactly as a successful
    /// backoff retry would, so `NativeBackend` clears `deadBundleIDs` and
    /// republishes the mixer topology through its existing `.capturing` handler.
    /// No parallel recovery path.
    ///
    /// Filtered to our own slots (the wider system-wide churn of unrelated apps
    /// is ignored for free — we only ever look at bundle IDs we route). A slot
    /// still not audible just fails fast back to `.failed`, cheaply.
    ///
    /// ## Single-flighting against T2's backoff
    /// `start(bundleID:)` only claims a slot out of `.idle`/`.failed`; a slot the
    /// backoff already has in flight (`.resolvingProcess`/`.creatingTap`) makes
    /// `start` a no-op, so the listener and the backoff timer can never
    /// double-start or thrash a slot. And when a re-drive succeeds, the eventual
    /// `.capturing` transition is what cancels the pending backoff retry (in
    /// `NativeBackend.handlePerAppCaptureHealthChange`), so the two mechanisms
    /// converge instead of racing.
    /// Internal (not `private`) purely so tests can invoke the resume-listener
    /// dispatch hermetically — firing a real `kAudioHardwarePropertyProcessObjectList`
    /// notification in CI isn't possible without live Core Audio churn. Behavior
    /// is unchanged; this is only an access-level seam.
    func handleProcessListChanged() {
        // (1) Resume self-heal (T3): re-drive dead-but-retryable slots IMMEDIATELY
        // — a latency path (an app just resumed audio), so NOT debounced.
        let toRetry: [String] = queue.sync {
            slots.compactMap { key, slot -> String? in
                guard case .failed(let error) = slot.state, error.isRetryable else { return nil }
                return key
            }
        }
        // NOTE: NOT an early `guard ... else { return }` any more — the membership
        // diff below must run even when no slot needs re-driving.
        if !toRetry.isEmpty {
            Telemetry.log(.capturePA, "resume_listener_fired", [
                "count": "\(toRetry.count)",
                "bundleIDs": toRetry.joined(separator: ","),
            ])
            for bundleID in toRetry { start(bundleID: bundleID) }
        }

        // (2) Live-membership diffing (W1-T4): a browser opening/closing a tab
        // spawns/kills an audio child, changing the process set an ALREADY
        // capturing slot should tap. Coalesce a burst onto `membershipQueue` and
        // diff once it settles. Distinct from (1), which only re-drives DEAD slots.
        scheduleMembershipDiff()
    }

    /// Coalesce process-list notifications: cancel any pending diff and arm a fresh
    /// one ``membershipDebounceInterval`` out, so a rapid spawn/kill/spawn burst
    /// collapses to one diff pass. Runs on ``membershipQueue`` (never ``queue``) so
    /// the `queue.sync` inside the diff cannot deadlock.
    private func scheduleMembershipDiff() {
        membershipQueue.async { [weak self] in
            guard let self else { return }
            self.membershipDiffWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.handleMembershipChange() }
            self.membershipDiffWork = work
            self.membershipQueue.asyncAfter(deadline: .now() + self.membershipDebounceInterval, execute: work)
        }
    }

    /// Diff every currently-capturing slot's resolved process-object set against
    /// the set its live tap was last built against (``Slot/lastTappedProcessObjects``).
    /// For each slot whose set genuinely changed, recreate its tap against the
    /// fresh set via ``handleDeviceChange(bundleID:)`` (the proven rebuild path —
    /// re-resolves + rebuilds + records a fresh baseline). A slot whose set is
    /// unchanged — the overwhelmingly common case under tab churn — is skipped with
    /// ZERO Core Audio work (the CPU-storm loop-breaker). Internal (not private) so
    /// tests can drive a diff pass without waiting out the real debounce timer.
    func handleMembershipChange() {
        // Snapshot each capturing slot's baseline under the lock, then resolve
        // (which enumerates the HAL) OUTSIDE it.
        let baselines: [(bundleID: String, oldObjects: Set<AudioObjectID>)] = queue.sync {
            slots.compactMap { key, slot in
                guard case .capturing = slot.state else { return nil }
                return (key, slot.lastTappedProcessObjects)
            }
        }
        guard !baselines.isEmpty else { return }

        for baseline in baselines {
            let newObjects = Set(processResolver.resolve(bundleID: baseline.bundleID).map(\.objectID))
            // Empty = the app fully quit (even its main process is gone). Do NOT
            // churn a healthy slot to `.failed` from here — leave that to the
            // device-change/backoff paths; a transient empty resolve during churn
            // shouldn't tear a capturing slot down.
            guard !newObjects.isEmpty else { continue }
            // COMPARE-BEFORE-REBUILD: unchanged membership → zero work.
            guard newObjects != baseline.oldObjects else { continue }
            // Re-check under the lock that the slot is still capturing against the
            // SAME baseline (a concurrent stop()/device-change may have moved it, or
            // already rebuilt it) before recreating.
            let stillStale: Bool = queue.sync {
                guard let slot = slots[baseline.bundleID], case .capturing = slot.state else { return false }
                return slot.lastTappedProcessObjects == baseline.oldObjects
            }
            guard stillStale else { continue }
            Telemetry.log(.capturePA, "membership_changed", [
                "bundleID": baseline.bundleID,
                "oldObjectCount": "\(baseline.oldObjects.count)",
                "objectCount": "\(newObjects.count)",
            ])
            // Recreate via the proven device-change machinery: it re-resolves the
            // set itself, tears the old tap down, rebuilds, and records the fresh
            // baseline. Exactly one rebuild per genuine change (this tap has no
            // in-place update path).
            handleDeviceChange(bundleID: baseline.bundleID)
        }
    }
    #endif

    // MARK: Slot + transition helpers (must hold `queue`)

    private func slotFor(_ bundleID: String) -> Slot {
        if let existing = slots[bundleID] { return existing }
        let slot = Slot()
        slots[bundleID] = slot
        return slot
    }

    private func transition(_ slot: Slot, bundleID: String, to newState: State) {
        guard newState != slot.state else { return }
        let previous = slot.state
        slot.state = newState
        var fields = [
            // WHICH coordinator instance — see the `name` property's doc. Two
            // instances share this category; without this field their lines
            // interleave into a sequence no single state machine could produce.
            "coordinator": name,
            "bundleID": bundleID,
            "from": Self.telemetryLabel(for: previous),
            "to": Self.telemetryLabel(for: newState),
        ]
        switch newState {
        case .capturing(let format):
            fields["format"] = "\(format.sampleRate)/\(format.channels)"
        case .failed(let error):
            fields["error"] = String(describing: error)
        default:
            break
        }
        Telemetry.log(.capturePA, "transition", fields)
        onStateChange?(bundleID, newState)
    }

    /// Short, stable label for a `State` case — Telemetry's `from`/`to`
    /// fields (`transition(_:bundleID:to:)` above). Associated values
    /// (format/error detail) are logged as their own fields at that same
    /// call site instead of folded into this label, since a plain
    /// `String(describing:)` of the enum case would bury the case name
    /// inside verbose struct/error output.
    private static func telemetryLabel(for state: State) -> String {
        switch state {
        case .idle: return "idle"
        case .resolvingProcess: return "resolvingProcess"
        case .creatingTap: return "creatingTap"
        case .capturing: return "capturing"
        case .stopping: return "stopping"
        case .failed: return "failed"
        }
    }
}

// MARK: - Injected seam (protocol)

/// The per-process Core Audio tap seam — the ``PerAppCaptureCoordinator``
/// analogue of ``SystemAudioTap``. The production impl (``CoreAudioProcessTap``)
/// scopes a `CATapDescription` to a mixdown of the resolved process objects;
/// tests inject a fake that pushes ``CapturedBuffer``s on demand and scripts
/// success/failure without any real Core Audio object.
public protocol ProcessAudioTap: AnyObject {
    /// Called with each captured buffer, on the delivery (IOProc) thread.
    var onBuffer: (@Sendable (CapturedBuffer) -> Void)? { get set }
    /// Called when the default output device changes (the aggregate is
    /// pinned to it, so it must be recreated).
    var onDefaultDeviceChanged: (@Sendable () -> Void)? { get set }

    /// Create a tap that is a stereo mixdown of every process object in
    /// `processes` (a bundle ID's main process plus any child/helper
    /// processes it emits audio from), read its REAL format, build the
    /// aggregate device, register the IOProc, and start it. Returns the
    /// tap's real captured format. `bundleID` is passed through only for
    /// error messages/logging — no Core Audio identity is derived from it.
    /// `processes` is never empty (an empty resolved set is handled by the
    /// caller before a tap is ever created). Throws ``PerAppCaptureError``,
    /// most commonly `.tapCreationFailed` (most likely TCC not yet granted).
    func createAndStart(processes: Set<AudioProcess>, bundleID: String, muteBehavior: TapMuteBehavior) throws -> TapFormat

    /// Stop and destroy the IOProc, aggregate device, and tap (in that
    /// order). Idempotent and non-throwing so teardown always completes.
    func teardown()
}

/// Every way per-app capture can fail. Shaped so a UI can render an
/// actionable message and the state machine can decide whether a retry is
/// sensible (``isRetryable``).
public enum PerAppCaptureError: Error, Equatable, Sendable {
    /// Not produced by ``PerAppCaptureCoordinator``'s own resolution path —
    /// an empty ``AudioProcessResolver`` result (app not running, or running
    /// but silent) surfaces as `.processNotYetAudible` instead, since the
    /// resolver cannot tell the two apart. Retained in the error taxonomy for
    /// API stability. Retryable — `start(bundleID:)` again once it's running.
    case appNotRunning(bundleID: String)
    /// The bundle ID resolved to NO live Core Audio process objects — the app
    /// isn't running, or is running but has never opened an audio stream
    /// (documented `dev/audiocap` edge case). Retryable — `start(bundleID:)`
    /// again once the app starts playing audio.
    case processNotYetAudible(bundleID: String)
    /// The process tap could not be created — on first run this almost
    /// always means the system-audio-recording (TCC) permission has not been
    /// granted.
    case tapCreationFailed(reason: String)
    /// The aggregate device pinning the tap to the default output could not
    /// be created (device disappeared mid-setup, or a HAL error).
    case aggregateDeviceFailed(reason: String)
    /// The tap's format could not be read.
    case formatReadFailed(reason: String)
    /// The default output device was lost and could not be replaced.
    case deviceLost(reason: String)
    /// The running macOS version predates the process-tap API (< 14.2), so
    /// per-app capture cannot start no matter what permission is granted.
    case osUnsupported(minimum: String)

    /// Whether `start(bundleID:)` is expected to be worth retrying without
    /// user action. Everything except `.osUnsupported` describes a
    /// transient condition (app not running yet, hasn't played audio yet,
    /// device hiccup); an OS-version gate never resolves itself.
    public var isRetryable: Bool {
        if case .osUnsupported = self { return false }
        return true
    }

    /// The exact `reason` the pre-tap TCC gate throws with when
    /// `SystemAudioCaptureTCC.isGranted()` refuses (see `beginStart`'s gate).
    /// A named constant rather than an inline literal so the message stays in
    /// one place — tests match on it, and a silently diverging copy would make
    /// a refusal indistinguishable from a real Core Audio failure in the logs.
    ///
    /// NOTE: nothing recovers a refused bundle automatically, by design. The app
    /// starts empty, per-app `.device` routes are cleared at launch
    /// (`AppRoutingController.clearAllDeviceRoutes()`), and the user re-picks a
    /// destination after granting — at which point the fresh-grant latch in
    /// ``SystemAudioCaptureTCC`` means the new tap is allowed straight away,
    /// with no relaunch.
    public static let notAuthorizedReason = "audio capture not authorized — awaiting the Setup grant"

    /// A human-readable, UI-renderable description of the failure and its
    /// remedy (mirrors ``NativeCaptureError/userMessage``).
    public var userMessage: String {
        switch self {
        case .appNotRunning:
            return "That application isn't currently running."
        case .processNotYetAudible:
            return "Waiting for that application to start playing audio."
        case .tapCreationFailed:
            return "Couldn't start audio capture for that application. Grant system-audio "
                + "recording permission in System Settings ▸ Privacy & Security ▸ Screen & "
                + "System Audio Recording, then try again."
        case .aggregateDeviceFailed:
            return "Couldn't set up audio capture for that application's current output device."
        case .formatReadFailed:
            return "Couldn't read that application's audio format."
        case .deviceLost:
            return "The audio output device was disconnected."
        case .osUnsupported(let minimum):
            return "Per-app audio capture requires macOS \(minimum) or newer. "
                + "Please update macOS to use this feature."
        }
    }
}

// MARK: - Production seam (Core Audio)
//
// Compiled only where AudioToolbox is available (macOS). The unit test suite
// exercises the state machine through a fake ProcessAudioTap and an
// AudioProcessResolver built over a fake AudioProcessEnumerating, and never
// touches these.

#if canImport(AudioToolbox)

/// Stand-in tap for macOS 14.0–14.1, where the process-tap API doesn't exist.
/// `createAndStart` throws immediately, so the coordinator lands the bundle
/// ID in `.failed(.osUnsupported)` instead of crashing.
final class UnavailableProcessTap: ProcessAudioTap, @unchecked Sendable {
    var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
    var onDefaultDeviceChanged: (@Sendable () -> Void)?

    func createAndStart(processes: Set<AudioProcess>, bundleID: String, muteBehavior: TapMuteBehavior) throws -> TapFormat {
        throw PerAppCaptureError.osUnsupported(minimum: "14.2")
    }

    func teardown() {}
}

/// The real per-process Core Audio tap (a disciplined port of
/// `dev/audiocap/Sources/audiocap/TapEngine.swift`'s `stereoMixdownOfProcesses`
/// path, combined with the aggregate-device/IOProc/teardown machinery
/// mirrored from `NativeCaptureCoordinator`'s `CoreAudioSystemTap`). Scopes a
/// `CATapDescription` to a stereo mixdown of every process object the
/// resolved ``AudioProcess`` set carries (a bundle ID's main process plus any
/// child/helper processes it emits audio from), builds a PRIVATE aggregate
/// device pinned to the current default output device, registers a realtime
/// IOProc, and delivers buffers with a `pts` taken from the IOProc's
/// `AudioTimeStamp.mHostTime`.
///
/// One instance = one bundle ID's tap. `PerAppCaptureCoordinator` creates a
/// fresh instance per `start(bundleID:)` call, so N of these coexist
/// independently (N separate `tapID`/`aggregateID`/`ioProcID` triples, N
/// separate private aggregate devices) without interfering with each other.
///
/// `AudioHardwareCreateProcessTap`/`AudioHardwareDestroyProcessTap` are macOS
/// 14.2+ (the package floor is 14.0); on 14.0–14.1 the coordinator gets an
/// ``UnavailableProcessTap`` instead.
@available(macOS 14.2, *)
final class CoreAudioProcessTap: ProcessAudioTap, @unchecked Sendable {

    var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
    var onDefaultDeviceChanged: (@Sendable () -> Void)?

    private let name: String
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var format = TapFormat(
        sampleRate: 44100, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
    private var asbd = AudioStreamBasicDescription()
    /// The physical output device our aggregate is built on. Kept so the monitor
    /// subscription can report ITS identity/rate as what this tap is built on
    /// (see `subscribeToDefaultOutput(bundleID:)`).
    private var tappedOutputDeviceID: AudioObjectID = kAudioObjectUnknown

    /// The process-wide default-output watcher this tap observes through, and the
    /// handle for its one subscription (nil until `createAndStart`, and again
    /// after `teardown()`).
    private let monitor: DefaultOutputDeviceMonitor
    private var monitorToken: DefaultOutputDeviceMonitor.SubscriptionToken?

    /// Per-instance mach→CLOCK_MONOTONIC rebase offset — ported from
    /// `CoreAudioSystemTap.machToMonotonicOffsetNanos` (architecture review
    /// 2026-07-26, defect A: this tap previously called the always-resample
    /// `CoreAudioSystemTap.timespec(fromHostTime:)` on every buffer, which
    /// that helper's own doc comment says production code must avoid — "not
    /// something we want to pay for on every real captured buffer"). Resampled
    /// once at `startIOProc()` (every tap create/recreate, not once per
    /// process) and thereafter mutated ONLY from inside the IOProc block,
    /// which Core Audio dispatches serially onto `queue` in `startIOProc()` —
    /// so no lock is needed on this RT-adjacent path.
    private var machToMonotonicOffsetNanos: Int64 = 0

    /// `monitor` defaults to the process-wide ``SharedDefaultOutputMonitor`` —
    /// the parameter exists so the hermetic suite can hand in a monitor built
    /// over a fake HAL.
    init(name: String, monitor: DefaultOutputDeviceMonitor = SharedDefaultOutputMonitor.instance) {
        self.name = name
        self.monitor = monitor
    }

    /// Backstop against leaking a per-process tap / aggregate device if this
    /// tap is dropped without an explicit `teardown()`. `teardown()` is
    /// idempotent and guards each object id, so a double teardown is safe.
    deinit { teardown() }

    func createAndStart(processes: Set<AudioProcess>, bundleID: String, muteBehavior: TapMuteBehavior) throws -> TapFormat {
        do {
            try createTapAndReadFormat(processes: processes, bundleID: bundleID, muteBehavior: muteBehavior)
            try createAggregate(bundleID: bundleID)
            try startIOProc()
            // Correct the converter's input rate to the aggregate's REAL rate
            // BEFORE the format is returned (the converter is built from it) and
            // before the monitor subscription is made (its compare-before-rebuild
            // guard reads `format.sampleRate`). Mirrors the whole-system tap's
            // ordering exactly — see `reconcileFormatWithAggregate`.
            reconcileFormatWithAggregate(bundleID: bundleID)
            subscribeToDefaultOutput(bundleID: bundleID)
        } catch {
            // Any step after the tap/aggregate was created leaves live system
            // objects; tear them down before propagating so we never orphan a
            // process tap or aggregate device on a partial failure.
            teardown()
            throw error
        }
        return format
    }

    // MARK: Tap creation + ASBD read

    private func createTapAndReadFormat(processes: Set<AudioProcess>, bundleID: String, muteBehavior: TapMuteBehavior) throws {
        // COLD-PROMPT GUARD (see ``SystemAudioCaptureTCC``): creating a process
        // tap is what surfaces the macOS audio-capture prompt. A per-app route
        // restored at launch must NOT trigger that prompt cold — only the Setup
        // screen's explicit "Allow…" may. Refuse until the grant is already in
        // place; the coordinator lands this as a retryable failure and re-attempts
        // once the route is re-applied after the user grants in Setup.
        let granted = SystemAudioCaptureTCC.isGranted()
        Telemetry.log(.capturePA, "gate_check", ["bundleID": bundleID, "granted": String(granted)])
        guard granted else {
            throw PerAppCaptureError.tapCreationFailed(
                reason: PerAppCaptureError.notAuthorizedReason)
        }

        // Stereo mixdown of EVERY resolved process object (dev/audiocap
        // TapEngine .processes / stereoMixdownOfProcesses path) — a
        // multi-process app (Firefox, Chrome) emits audio from a child
        // process with no bundle id of its own, so a single-process tap
        // would silently miss it. `processes` is guaranteed non-empty by
        // the caller (an empty resolved set never reaches tap creation).
        let objectIDs = processes.map(\.objectID)
        let desc = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        desc.uuid = UUID()
        desc.muteBehavior = muteBehavior == .mutedWhenTapped ? .mutedWhenTapped : .unmuted
        self.tapDescription = desc

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let err = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard err == noErr else {
            throw PerAppCaptureError.tapCreationFailed(reason: "AudioHardwareCreateProcessTap \(err)")
        }
        self.tapID = newTapID

        // Read the ACTUAL format — never assume 48k/2ch (config-follows-tap,
        // same discipline as the system-wide tap).
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var readASBD = AudioStreamBasicDescription()
        let fErr = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &readASBD)
        guard fErr == noErr else {
            throw PerAppCaptureError.formatReadFailed(reason: "read kAudioTapPropertyFormat \(fErr)")
        }
        // Guard the sample rate before it reaches `Int(mSampleRate.rounded())`:
        // a misbehaving driver can hand back NaN/±inf, and `Int(Float.nan)`
        // TRAPS in Swift — ported from `NativeCaptureCoordinator.createTapAndReadFormat`'s
        // identical guard (architecture review 2026-07-26, defect A). A
        // zero/negative rate is just as poisonous downstream (infinite resample
        // ratio, trapping `AVAudioFrameCount` conversion); fail loud into
        // `.formatReadFailed` instead.
        guard readASBD.mSampleRate.isFinite, readASBD.mSampleRate > 0 else {
            throw PerAppCaptureError.formatReadFailed(
                reason: "invalid tap sample rate \(readASBD.mSampleRate)")
        }
        self.asbd = readASBD
        self.format = TapFormat(
            sampleRate: Int(readASBD.mSampleRate.rounded()),
            channels: Int(readASBD.mChannelsPerFrame),
            bitsPerSample: Int(readASBD.mBitsPerChannel),
            isFloat: (readASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
            isInterleaved: (readASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0)
    }

    // MARK: Aggregate device

    private func createAggregate(bundleID: String) throws {
        guard let desc = tapDescription else {
            throw PerAppCaptureError.aggregateDeviceFailed(reason: "no tap description")
        }
        let outputID: AudioObjectID
        let outputUID: String
        do {
            outputID = try Self.defaultOutputDeviceID()
            outputUID = try CoreAudioSystemTap.readDeviceUID(outputID)
        } catch {
            throw PerAppCaptureError.deviceLost(reason: String(describing: error))
        }
        self.tappedOutputDeviceID = outputID
        let aggregateUID = UUID().uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String:          "PerAppTap-\(name)-\(bundleID)",
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
                    // MUST equal the CATapDescription's uuid string.
                    kAudioSubTapUIDKey as String: desc.uuid.uuidString
                ]
            ]
        ]

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard err == noErr else {
            throw PerAppCaptureError.aggregateDeviceFailed(reason: "AudioHardwareCreateAggregateDevice \(err)")
        }
        self.aggregateID = newAggregateID
    }

    /// The current default *output* device (what the user actually hears
    /// through) — deliberately `kAudioHardwarePropertyDefaultOutputDevice`,
    /// NOT `kAudioHardwarePropertyDefaultSystemOutputDevice` (the alert-sound
    /// device). See the file-level doc comment on ``PerAppCaptureCoordinator``
    /// for why this selector matters.
    private static func defaultOutputDeviceID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard err == noErr, deviceID != kAudioObjectUnknown else {
            throw PerAppCaptureError.deviceLost(reason: "no default output device (\(err))")
        }
        return deviceID
    }

    // MARK: IOProc

    private func startIOProc() throws {
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let onBuffer = self.onBuffer

        // Seed the rebase offset fresh for THIS tap instance (not a
        // process-wide one-time sample) — see `machToMonotonicOffsetNanos`
        // doc. This write happens-before `AudioDeviceStart` below, which
        // happens-before the IOProc block below ever runs, so no lock is
        // needed for this initial handoff either.
        self.machToMonotonicOffsetNanos = Self.sampleMachToMonotonicOffsetNanos()

        var newProcID: AudioDeviceIOProcID?
        let queue = DispatchQueue(
            label: "com.airplaycontroller.native.perapp.\(name)", qos: .userInitiated)

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
            // Cached, self-healing per-instance offset — ported from
            // `CoreAudioSystemTap`'s identical RT path rather than calling
            // the always-resample `CoreAudioSystemTap.timespec(fromHostTime:)`
            // helper on every buffer (see `machToMonotonicOffsetNanos` doc).
            // Drift self-heal: if the cached offset has fallen out of step
            // with reality (e.g. the box slept mid-tap), resample it before
            // use — two clock reads, cheap, and confined to this same serial
            // queue so no lock is needed. `machToMonotonicOffsetNanos` is
            // only ever touched from this block after the initial seed in
            // `startIOProc`.
            let hostTime = inInputTime.pointee.mHostTime
            let machNanos = Self.machNanoseconds(fromHostTime: hostTime)
            if CoreAudioSystemTap.shouldResample(
                machNanos: machNanos,
                offset: self.machToMonotonicOffsetNanos,
                monotonicNowNanos: Self.currentMonotonicNanos()
            ) {
                self.machToMonotonicOffsetNanos = Self.sampleMachToMonotonicOffsetNanos()
            }
            let pts = CoreAudioSystemTap.timespec(
                machNanos: machNanos, offset: self.machToMonotonicOffsetNanos)

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
        guard err == noErr else {
            throw PerAppCaptureError.aggregateDeviceFailed(reason: "AudioDeviceCreateIOProcIDWithBlock \(err)")
        }
        self.ioProcID = newProcID

        let startErr = AudioDeviceStart(aggregateID, ioProcID)
        guard startErr == noErr else {
            throw PerAppCaptureError.aggregateDeviceFailed(reason: "AudioDeviceStart \(startErr)")
        }
    }

    // MARK: mHostTime → CLOCK_MONOTONIC offset (cached, self-healing)
    //
    // Ported from `CoreAudioSystemTap`'s identical trio (architecture review
    // 2026-07-26, defect A). Duplicated rather than shared because the
    // originals are `private` to that file; `CoreAudioSystemTap.timespec(
    // machNanos:offset:)` and `.shouldResample(...)` — the pure arithmetic —
    // ARE internal and reused directly above, so only the two raw clock reads
    // and the timebase conversion are repeated here.

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

    /// `CLOCK_MONOTONIC_nanos - mach_absolute_nanos`, sampled fresh by reading
    /// both clocks back-to-back. See `machToMonotonicOffsetNanos`'s doc for
    /// why callers cache this instead of calling it on every buffer.
    private static func sampleMachToMonotonicOffsetNanos() -> Int64 {
        // Sample both clocks as close together as possible.
        let mach = machNanoseconds(fromHostTime: mach_absolute_time())
        let monotonic = currentMonotonicNanos()
        return Int64(monotonic) &- Int64(mach)
    }

    // MARK: Default-output subscription (device identity + nominal sample rate)
    //
    // This tap used to install two private HAL property listeners of its own:
    // `kAudioHardwarePropertyDefaultOutputDevice` (the default output changing
    // identity) and `kAudioDevicePropertyNominalSampleRate` on the tapped device
    // (the documented process-tap silent-buffer case — a tap keeps delivering
    // buffers at full cadence but goes SILENT/all-zero when the tapped device
    // renegotiates 44.1 ↔ 48 kHz, classically another app taking the mic and
    // forcing voice-processing mode; Apple-unresolved, Developer Forums thread
    // 825780, and the only reliable recovery is the full teardown+rebuild
    // `handleDeviceChange` performs. It happens with the device's UID UNCHANGED,
    // which is why the identity listener alone could never catch it).
    //
    // Both are now observed ONCE for the whole process by
    // ``DefaultOutputDeviceMonitor`` and fanned out here (architecture review
    // 2026-07-26, defect D). The compare-before-rebuild guards did NOT move: the
    // monitor evaluates the same pure decision per subscriber, against the values
    // `tracked` reports for THIS tap, so `onChange` runs only when this tap's own
    // pinned device or effective rate genuinely diverged — the loop-breaker that
    // stopped the observed per-app rebuild storm still holds.

    /// Best-effort human-readable label for `deviceID`, for the Telemetry
    /// `rate_rebuild` event's `device` field only — never used for any
    /// routing/capture decision. Same `kAudioObjectPropertyName` read
    /// `NativeBackend.currentOutputDeviceName()` uses, scoped to an
    /// already-known device instead of re-resolving the system default (kept
    /// local to this file, rather than calling that composition-root type
    /// directly, to avoid a dependency from this Core Audio tap up into it).
    /// Read-only, never throws — falls back to a numeric label so a lookup
    /// failure can never block logging.
    private static func telemetryDeviceLabel(_ deviceID: AudioObjectID) -> String {
        guard deviceID != kAudioObjectUnknown else { return "unknown" }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr, let cf = name, !(cf as String).isEmpty else { return "device #\(deviceID)" }
        return cf as String
    }

    /// Correct `format`/`asbd` to the AGGREGATE's real nominal rate (the per-app
    /// port of the whole-system tap's identical fix — see
    /// `CoreAudioSystemTap.reconcileFormatWithAggregate`).
    ///
    /// `createTapAndReadFormat` reads `kAudioTapPropertyFormat` off the BARE
    /// process tap, before it joins the aggregate device. With sub-tap drift
    /// compensation on, the aggregate resamples the tap's audio onto ITS OWN
    /// clock (the tapped output device's nominal rate) — so a tap that read back
    /// 44100 pre-aggregate can actually deliver 48000-rate buffers once
    /// aggregated. Building the `AVAudioConverter` from the stale pre-aggregate
    /// rate makes it reinterpret every 48000 buffer as 44100: a sustained ~8.8%
    /// pitch-UP with judder, exactly the live symptom on a per-app redirect.
    ///
    /// This ALSO repairs the rate listener's compare-before-rebuild guard: that
    /// guard compares the notified device rate against `format.sampleRate`, so
    /// while `format` held the unreconciled pre-aggregate rate the two could
    /// never match and EVERY notification rebuilt the tap (the observed per-app
    /// rebuild storm). Reconciling here makes both comparisons apples-to-apples.
    ///
    /// The aggregate's nominal rate (not a second `kAudioTapPropertyFormat`
    /// re-read) is authoritative precisely because drift compensation resamples
    /// the sub-tap ONTO the aggregate clock — that is the cadence the IOProc
    /// sees. If the aggregate rate can't be read we keep the pre-aggregate
    /// format (no regression vs. the prior behaviour).
    private func reconcileFormatWithAggregate(bundleID: String) {
        guard aggregateID != kAudioObjectUnknown else { return }
        let aggregateRate = CoreAudioSystemTap.readNominalSampleRate(aggregateID)
        let reconciled = CoreAudioSystemTap.reconciledFormat(
            declared: format, aggregateRate: aggregateRate)
        guard reconciled != format else { return }
        AudioDiag.log(
            "PAC \(bundleID): pre-aggregate tap format declared \(format.sampleRate) Hz but the "
            + "aggregate device actually delivers \(reconciled.sampleRate) Hz — correcting the "
            + "converter's input rate to the aggregate's real rate (prevents a sustained pitch shift)")
        Telemetry.log(.capturePA, "rate_reconciled", [
            "bundleID": bundleID,
            "declaredRate": String(format.sampleRate),
            "aggregateRate": String(reconciled.sampleRate),
        ])
        self.asbd.mSampleRate = Double(reconciled.sampleRate)
        self.format = reconciled
    }

    func subscribeToDefaultOutput(bundleID: String) {
        monitor.start()
        monitorToken = monitor.subscribe(
            label: "capturePA:\(bundleID)",
            tracked: { [weak self] in
                // READ LIVE at every notification — never a value snapshotted
                // here at subscribe time. The monitor compares against each
                // subscriber's OWN current device/rate precisely so that a tap
                // whose format drifted independently still gets told even when
                // the device's rate looks unchanged from the monitor's point of
                // view. `format.sampleRate` is the right thing to report
                // specifically because `reconcileFormatWithAggregate` already
                // corrected it to the aggregate's real rate at start —
                // reporting the unreconciled pre-aggregate rate would make the
                // guard never match and rebuild on every notification (the
                // observed per-app rebuild storm).
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
                // Never exercised by the hermetic suite (no live Core Audio) —
                // see the coordinator-level emission in
                // `handleDeviceChange(bundleID:)`, which is.
                let rate = self.format.sampleRate
                let device = Self.telemetryDeviceLabel(self.tappedOutputDeviceID)
                if CoreAudioSystemTap.shouldRebuildForNominalRate(
                    notifiedRate: snapshot.nominalRate, currentEffectiveRate: rate) {
                    Telemetry.log(.capturePA, "rate_rebuild", [
                        "bundleID": bundleID,
                        "device": device,
                        "oldRate": String(rate),
                        "newRate": snapshot.nominalRate.map { String(Int($0.rounded())) } ?? "unknown",
                    ])
                } else {
                    Telemetry.log(.capturePA, "rate_notification_skipped", [
                        "bundleID": bundleID,
                        "device": device,
                        "rate": String(rate),
                    ])
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

    // MARK: Teardown (order matters: stop -> destroy IOProc -> destroy aggregate -> destroy tap)

    // Every destroy below is checked and logged rather than discarded: a failing
    // `AudioHardwareDestroyProcessTap`/`…AggregateDevice` is exactly how a live
    // per-app tap leaks a system object, and it used to vanish silently here
    // while the whole-system tap logged the same failures. Log-and-continue —
    // teardown must never stop partway and orphan the objects further down.
    func teardown() {
        unsubscribeFromDefaultOutput()
        tappedOutputDeviceID = kAudioObjectUnknown
        if aggregateID != kAudioObjectUnknown, let proc = ioProcID {
            let stopErr = AudioDeviceStop(aggregateID, proc)
            if stopErr != noErr { AudioDiag.log("CoreAudioProcessTap.teardown AudioDeviceStop failed: \(stopErr)") }
            let destroyIOErr = AudioDeviceDestroyIOProcID(aggregateID, proc)
            if destroyIOErr != noErr {
                AudioDiag.log("CoreAudioProcessTap.teardown AudioDeviceDestroyIOProcID failed: \(destroyIOErr)")
            }
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            let destroyAggErr = AudioHardwareDestroyAggregateDevice(aggregateID)
            if destroyAggErr != noErr {
                AudioDiag.log("CoreAudioProcessTap.teardown AudioHardwareDestroyAggregateDevice failed: \(destroyAggErr)")
            }
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            let destroyTapErr = AudioHardwareDestroyProcessTap(tapID)
            if destroyTapErr != noErr {
                AudioDiag.log("CoreAudioProcessTap.teardown AudioHardwareDestroyProcessTap failed: \(destroyTapErr)")
            }
            tapID = kAudioObjectUnknown
        }
    }
}

#endif
