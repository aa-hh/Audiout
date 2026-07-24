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
///   - `translatePIDToProcessObject` (`dev/audiocap/Sources/audiocap/CAHelpers.swift`)
///     → `CoreAudioProcessTap.translateProcessObject` below.
/// The aggregate-device / IOProc / teardown-order machinery is reused nearly
/// verbatim from ``NativeCaptureCoordinator``'s `CoreAudioSystemTap` (the
/// per-app tap is just scoped to one process object instead of the whole
/// system) — including its `mHostTime -> CLOCK_MONOTONIC` pts rebase
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
/// ## Bundle ID -> pid resolution stays OUT of Core
/// Step 1 of this task ("resolve the app's current pid via
/// `NSRunningApplication`") needs AppKit (`NSRunningApplication` /
/// `NSWorkspace` live in the AppKit framework). `AudiouterCore` must
/// never import AppKit (package rule, `AudiouterCore/AGENTS.md`), so
/// the resolver is an injected closure (`resolveProcessSet`,
/// ``AppProcessResolver``) rather than a built-in call. Whichever
/// AppKit-importing layer wires this coordinator in supplies a
/// ``ProcessSetResolver`` (bundle ID → the app's full main+children pid set).
///
/// ## Known edge cases (do not "fix" these with speculative logic)
/// - A pid that has never opened an audio stream cannot be translated to a
///   Core Audio process object yet. `translateProcessObject` surfaces this as
///   the distinct, retryable ``PerAppCaptureError/processNotYetAudible(bundleID:)``
///   (not a crash, not lumped in with a generic tap-creation failure) so a
///   caller can retry `start(bundleID:)` once the app starts playing audio.
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
    /// with an extra `.resolvingProcess` step up front (pid lookup happens
    /// before any Core Audio call).
    public enum State: Equatable, Sendable {
        /// Not running (or never started). `start(bundleID:)` moves out;
        /// `stop(bundleID:)` returns here.
        case idle
        /// Resolving the bundle ID to a running pid via the injected resolver.
        case resolvingProcess
        /// Translating the pid to a Core Audio process object and creating the
        /// tap + aggregate device (may trigger the TCC prompt on first ever
        /// run, exactly like the system-wide tap).
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
    /// Bundle ID → the app's full process set (main + audio-playing children),
    /// ordered main-first (W1-T1, ``AppProcessResolver``). W1-T2: the coordinator
    /// taps the WHOLE resolved set per slot (one `CATapDescription` covering every
    /// process object that translates), so a browser or Electron app whose audio
    /// comes from a child process is captured too. W1-T4: live membership
    /// changes (a child spawning/dying mid-stream as browser tabs open/close)
    /// are additionally diffed via the process-object-list listener and applied
    /// to the running tap — debounced and compare-before-rebuild guarded (see
    /// `handleMembershipChange`). Beyond tap-creation time (initial `start`,
    /// `handleDeviceChange` rebuild), the set is re-resolved through this same
    /// closure on every settled process-list change.
    private let resolveProcessSet: AppProcessResolver
    private let muteBehavior: TapMuteBehavior

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
        /// W1-T4: the process set (as a membership set) that this slot's live
        /// tap was last (re)built or updated against. The compare-before-rebuild
        /// key for live-membership diffing — a process-object-list notification
        /// whose re-resolved set for this bundle ID equals this value triggers
        /// ZERO work, so browser-tab churn that doesn't change our app's audible
        /// pid set can't thrash the tap. Recorded on every successful
        /// `.capturing` transition (initial start, device-change rebuild, and
        /// in-place membership update). Set semantics (not `[pid_t]`) so a mere
        /// reorder of the same members is not treated as a change.
        var lastTappedPIDs: Set<pid_t> = []
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

    // MARK: Live-membership diffing (W1-T4)
    //
    // A separate, DEBOUNCED serial queue that owns the membership-diff timer.
    // The process-object-list listener fires once per process connecting/
    // disconnecting — browsers churn this constantly as tabs open/close. Running
    // a full per-slot re-resolve + rebuild on every one of those notifications
    // would reintroduce the very coreaudiod CPU storm the `(deviceID,
    // nominalRate)` compare-before-rebuild elsewhere in this program was written
    // to kill, so notifications are coalesced onto this queue and only the LAST
    // one in a burst actually runs the diff. This queue is DISTINCT from
    // ``queue`` on purpose: `handleMembershipChange` reaches into the state via
    // `queue.sync`, which would deadlock if it were itself running on `queue`.
    private let membershipQueue = DispatchQueue(label: "PerAppCaptureCoordinator.membership")
    /// The pending coalesced diff. Confined to ``membershipQueue``. Cancelled and
    /// replaced by each new notification inside the debounce window, so a rapid
    /// spawn/kill/spawn burst collapses to a single diff pass.
    private var membershipDiffWork: DispatchWorkItem?
    /// How long to wait for the process-list churn to settle before diffing.
    /// Injectable so tests can shrink it; production default coalesces a burst
    /// of tab open/close notifications into one rebuild.
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
    ///   - resolveProcessSet: bundle ID -> the app's process set (main +
    ///     helper/child pids), ordered main-first. Must be supplied by an
    ///     AppKit-importing layer; Core cannot enumerate `NSRunningApplication`
    ///     itself. Empty if no running app matches.
    ///   - name: a short label used for the private tap/aggregate device
    ///     names (one aggregate per active bundle ID, named `"PerAppTap-
    ///     <name>-<bundleID>"`).
    ///   - muteBehavior: `.mutedWhenTapped` (default) silences the tapped
    ///     app's local playback while capturing, matching the routing intent
    ///     (its audio goes to the redirect target, not the built-in speakers).
    #if canImport(AudioToolbox)
    public convenience init(
        resolveProcessSet: @escaping AppProcessResolver,
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
            resolveProcessSet: resolveProcessSet,
            muteBehavior: muteBehavior
        )
    }
    #endif

    /// Injectable designated initializer (internal — tests pass a fake tap
    /// factory and a scripted resolver so the state machine runs without a
    /// real tap, real Core Audio, or a real running app).
    init(
        makeTap: @escaping @Sendable () -> ProcessAudioTap,
        resolveProcessSet: @escaping AppProcessResolver,
        muteBehavior: TapMuteBehavior = .mutedWhenTapped,
        membershipDebounceInterval: DispatchTimeInterval = .milliseconds(300)
    ) {
        self.makeTap = makeTap
        self.resolveProcessSet = resolveProcessSet
        self.muteBehavior = muteBehavior
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

    /// Start capture for `bundleID`: resolve its pid, translate to a Core
    /// Audio process object, create its own tap + aggregate device, and start
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

    private func beginStart(bundleID: String) {
        // W1-T2: resolve the app's full process set and tap ALL of it (main +
        // child/helper processes), not just the main pid — a browser or
        // Electron app that plays audio from a child process would otherwise
        // go silent when routed (R1, R2, R9, R14).
        let pids = resolveProcessSet(bundleID)
        guard !pids.isEmpty else {
            queue.sync {
                guard let slot = slots[bundleID], case .resolvingProcess = slot.state else { return }
                transition(slot, bundleID: bundleID, to: .failed(.appNotRunning(bundleID: bundleID)))
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
            let format = try tap.createAndStart(pids: pids, bundleID: bundleID, muteBehavior: muteBehavior)
            queue.sync {
                guard let slot = slots[bundleID], case .creatingTap = slot.state else {
                    tap.teardown() // a stop() (or a second start()) raced in — don't leak this tap
                    return
                }
                slot.tap = tap
                slot.lastTappedPIDs = Set(pids) // W1-T4 compare-before-rebuild baseline
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
    /// is pinned to it, same as the system-wide tap). Re-resolve the pid
    /// (the app may have relaunched with a new pid since capture started) and
    /// recreate the tap + aggregate against the new device.
    private func handleDeviceChange(bundleID: String) {
        AudioDiag.log("PAC.handleDeviceChange bundle=\(bundleID) FIRED (default output device changed)")
        // STABILITY(C6) (per-app port of NativeCaptureCoordinator's fix sketch,
        // dev/notes/stability-audit-2026-07-18.md §C6): if this notification
        // arrives while the slot is already mid-rebuild (`.creatingTap`), don't
        // drop it — mark it pending so the in-flight rebuild replays a fresh
        // handleDeviceChange once it lands in `.capturing`. Rapid sample-rate
        // bounces (44.1 -> 48 -> 44.1) mean the LAST notification can be the one
        // that would otherwise be dropped, rebuilding against a stale rate.
        let claim: (proceed: Bool, old: ProcessAudioTap?) = queue.sync {
            guard let slot = slots[bundleID] else { return (false, nil) }
            guard case .capturing = slot.state else {
                if case .creatingTap = slot.state {
                    slot.pendingDeviceChange = true
                }
                return (false, nil)
            }
            let old = slot.tap
            slot.tap = nil
            transition(slot, bundleID: bundleID, to: .creatingTap)
            return (true, old)
        }
        guard claim.proceed else {
            AudioDiag.log("PAC.handleDeviceChange bundle=\(bundleID) SKIPPED (not capturing) — coalesced=\(queue.sync { slots[bundleID]?.pendingDeviceChange ?? false })")
            return
        }
        claim.old?.teardown()

        // W1-T2: re-resolve the process set (the app may have relaunched with new
        // pids, or spawned/lost helpers) and tap the full set.
        let pids = resolveProcessSet(bundleID)
        guard !pids.isEmpty else {
            AudioDiag.log("PAC.handleDeviceChange bundle=\(bundleID) FAILED: app not running (pid unresolved)")
            queue.sync {
                guard let slot = slots[bundleID], case .creatingTap = slot.state else { return }
                transition(slot, bundleID: bundleID, to: .failed(.appNotRunning(bundleID: bundleID)))
            }
            return
        }

        let newTap = makeTap()
        newTap.onBuffer = { [weak self] buffer in self?.onBuffer?(bundleID, buffer) }
        newTap.onDefaultDeviceChanged = { [weak self] in self?.handleDeviceChange(bundleID: bundleID) }

        do {
            let format = try newTap.createAndStart(pids: pids, bundleID: bundleID, muteBehavior: muteBehavior)
            AudioDiag.log("PAC.handleDeviceChange bundle=\(bundleID) RECREATED ok, new format \(format.sampleRate)/\(format.channels)ch")
            let replay: Bool = queue.sync {
                guard let slot = slots[bundleID], case .creatingTap = slot.state else {
                    newTap.teardown()
                    return false
                }
                slot.tap = newTap
                slot.lastTappedPIDs = Set(pids) // W1-T4 compare-before-rebuild baseline
                transition(slot, bundleID: bundleID, to: .capturing(format))
                // STABILITY(C6): a device-change notification landed while we were
                // rebuilding — replay it once now that we're capturing again,
                // coalescing however many were dropped into a single retry.
                guard slot.pendingDeviceChange else { return false }
                slot.pendingDeviceChange = false
                return true
            }
            if replay {
                AudioDiag.log("PAC.handleDeviceChange bundle=\(bundleID) replaying coalesced pending device change")
                handleDeviceChange(bundleID: bundleID)
            }
        } catch {
            newTap.teardown()
            let mapped: PerAppCaptureError = (error as? PerAppCaptureError)
                ?? .tapCreationFailed(reason: String(describing: error))
            AudioDiag.log("PAC.handleDeviceChange bundle=\(bundleID) RECREATE FAILED: \(mapped)")
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
    // with `.processNotYetAudible`: the pid exists but has no Core Audio process
    // object yet, so `translateProcessObject` returns `kAudioObjectUnknown`.
    // T2's capped-exponential backoff already re-probes such a slot forever, so
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
        guard processListBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleProcessListChanged()
        }
        var address = Self.processObjectListAddress
        let err = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
        guard err == noErr else {
            AudioDiag.log("PAC resume-listener install FAILED (\(err)) — relying on T2 backoff only")
            return
        }
        processListBlock = block
        AudioDiag.log("PAC resume-listener armed (process-object-list)")
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
    /// `start(bundleID:)` path: if the app has now resumed, its pid finally
    /// translates to a live process object and the tap builds, landing the slot
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
        // — this is a latency path (an app just resumed audio), so it is NOT
        // debounced.
        let toRetry: [String] = queue.sync {
            slots.compactMap { key, slot -> String? in
                guard case .failed(let error) = slot.state, error.isRetryable else { return nil }
                return key
            }
        }
        if !toRetry.isEmpty {
            AudioDiag.log("PAC resume-listener fired — re-driving \(toRetry.count) dead slot(s): \(toRetry)")
            for bundleID in toRetry { start(bundleID: bundleID) }
        }

        // (2) Live-membership diffing (W1-T4): a browser opening/closing a tab
        // spawns/kills an audio child process, changing the pid set an ALREADY
        // capturing slot should be tapping. Coalesce a burst of these onto the
        // membership queue and diff once it settles.
        scheduleMembershipDiff()
    }

    // MARK: - Live-membership diffing (W1-T4)
    //
    // Closes the browser-tab-churn half of R14. W1-T2/T3 resolve + tap the full
    // process set only at tap-CREATION time (initial start, device-change
    // rebuild). But browsers spawn/kill audio children per tab constantly, so a
    // new tab that starts playing AFTER the tap was built would go uncaptured
    // until the next unrelated rebuild trigger. This path listens to the same
    // process-object-list notification the resume self-heal already uses and, on
    // a genuine membership change for a bundle ID we are actively tapping,
    // updates that tap — debounced and guarded by a per-slot
    // `(processSet)` compare-before-rebuild so an unchanged set costs nothing.

    /// Coalesce process-list notifications: cancel any pending diff and arm a
    /// fresh one `membershipDebounceInterval` out. Only the last notification in
    /// a burst survives to run `handleMembershipChange`. Runs on
    /// ``membershipQueue`` (never ``queue``) so `queue.sync` inside the diff
    /// cannot deadlock.
    private func scheduleMembershipDiff() {
        membershipQueue.async { [weak self] in
            guard let self else { return }
            self.membershipDiffWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.handleMembershipChange() }
            self.membershipDiffWork = work
            self.membershipQueue.asyncAfter(deadline: .now() + self.membershipDebounceInterval, execute: work)
        }
    }

    /// Diff every currently-capturing slot's resolved process set against the
    /// set its live tap was last built/updated against. Runs on
    /// ``membershipQueue``. For each slot whose set genuinely changed, apply the
    /// change (in-place update preferred, full recreate as fallback). A slot
    /// whose set is unchanged — the overwhelmingly common case under tab churn —
    /// is skipped with ZERO Core Audio work: this is the regression-prevention
    /// property that keeps browser churn from thrashing coreaudiod.
    ///
    /// Internal (not `private`) purely so tests can drive a diff pass
    /// deterministically without waiting out the real debounce timer. Behavior
    /// is identical to the timer-driven path.
    func handleMembershipChange() {
        // Snapshot the capturing slots' baselines under the state lock, then do
        // the (potentially blocking) resolve + Core Audio work OUTSIDE it.
        let baselines: [(bundleID: String, oldPIDs: Set<pid_t>)] = queue.sync {
            slots.compactMap { key, slot in
                guard case .capturing = slot.state else { return nil }
                return (key, slot.lastTappedPIDs)
            }
        }
        guard !baselines.isEmpty else { return }

        for baseline in baselines {
            let newPIDs = resolveProcessSet(baseline.bundleID)
            let newSet = Set(newPIDs)
            // Empty set = the app fully quit (even its main process is gone). Do
            // NOT churn the slot to `.failed` from here — leave that to the
            // device-change / backoff paths; a transient empty resolve during
            // churn shouldn't tear a healthy slot down.
            guard !newSet.isEmpty else { continue }
            // COMPARE-BEFORE-REBUILD: unchanged membership → zero work.
            guard newSet != baseline.oldPIDs else { continue }
            AudioDiag.log("PAC membership changed for \(baseline.bundleID): \(baseline.oldPIDs.sorted()) -> \(newSet.sorted())")
            applyMembershipChange(bundleID: baseline.bundleID, newPIDs: newPIDs)
        }
    }

    /// Apply a genuine membership change to one slot's live tap. Per the W1-T0
    /// spike (`docs/plans/wave1-tap-update-spike.md`): try an in-place
    /// `kAudioTapPropertyDescription` update first (no audible gap, no aggregate-
    /// device churn); fall back to a full destroy/recreate on any non-zero
    /// OSStatus or unhealthy post-update state. The in-place attempt is
    /// best-effort — the recreate fallback is the proven path.
    private func applyMembershipChange(bundleID: String, newPIDs: [pid_t]) {
        // Claim the live tap under the lock, but only if still capturing (a
        // concurrent stop()/device-change may have moved us on).
        let tap: ProcessAudioTap? = queue.sync {
            guard let slot = slots[bundleID], case .capturing = slot.state else { return nil }
            return slot.tap
        }
        guard let tap else { return }

        if tap.updateProcessSet(pids: newPIDs) {
            // In-place update succeeded: no rebuild, no state transition. Record
            // the new baseline (only if the slot still owns this exact tap — a
            // race with stop()/recreate otherwise).
            queue.sync {
                guard let slot = slots[bundleID], case .capturing = slot.state, slot.tap === tap else { return }
                slot.lastTappedPIDs = Set(newPIDs)
            }
            AudioDiag.log("PAC membership update applied in place for \(bundleID)")
            return
        }

        // Fallback: full teardown + recreate. Reuse the proven device-change
        // machinery — it re-resolves the set itself, tears the old tap down,
        // rebuilds, and records the fresh `lastTappedPIDs` baseline. Exactly one
        // rebuild per genuine change.
        AudioDiag.log("PAC membership in-place update unavailable for \(bundleID) — full recreate")
        handleDeviceChange(bundleID: bundleID)
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
        slot.state = newState
        onStateChange?(bundleID, newState)
    }
}

// MARK: - Injected seam (protocol)

/// The per-process Core Audio tap seam — the ``PerAppCaptureCoordinator``
/// analogue of ``SystemAudioTap``. The production impl (``CoreAudioProcessTap``)
/// scopes a `CATapDescription` to a single translated process object; tests
/// inject a fake that pushes ``CapturedBuffer``s on demand and scripts
/// success/failure without any real Core Audio object.
public protocol ProcessAudioTap: AnyObject {
    /// Called with each captured buffer, on the delivery (IOProc) thread.
    var onBuffer: (@Sendable (CapturedBuffer) -> Void)? { get set }
    /// Called when the default output device changes (the aggregate is
    /// pinned to it, so it must be recreated).
    var onDefaultDeviceChanged: (@Sendable () -> Void)? { get set }

    /// Translate every pid in `pids` (main + children, main-first, W1-T1) to a
    /// Core Audio process object, create a SINGLE tap covering all of them
    /// (`CATapDescription(stereoMixdownOfProcesses:)`), read its REAL format,
    /// build the aggregate device, register the IOProc, and start it. Returns
    /// the tap's real captured format. `bundleID` is passed through only for
    /// error messages/logging — no Core Audio identity is derived from it.
    /// Throws ``PerAppCaptureError``, most commonly
    /// ``PerAppCaptureError/processNotYetAudible(bundleID:)`` (none of `pids`
    /// has opened an audio stream yet — retryable) or `.tapCreationFailed`
    /// (most likely TCC not yet granted).
    func createAndStart(pids: [pid_t], bundleID: String, muteBehavior: TapMuteBehavior) throws -> TapFormat

    /// W1-T4: try to update this LIVE tap's process set in place (no teardown),
    /// via `AudioObjectSetPropertyData(tapID, kAudioTapPropertyDescription, …)`
    /// with a mutated `CATapDescription.processes` array (see the W1-T0 spike,
    /// `docs/plans/wave1-tap-update-spike.md`). Returns `true` if the live tap
    /// now covers exactly `pids` (main-first) and remains healthy; returns
    /// `false` to signal the coordinator must fall back to a full
    /// destroy/recreate — on any non-zero `OSStatus`, an untranslatable main
    /// pid, or an unhealthy post-update format read. Best-effort by contract:
    /// a `false` return is never an error, just "recreate instead".
    func updateProcessSet(pids: [pid_t]) -> Bool

    /// Stop and destroy the IOProc, aggregate device, and tap (in that
    /// order). Idempotent and non-throwing so teardown always completes.
    func teardown()
}

/// Every way per-app capture can fail. Shaped so a UI can render an
/// actionable message and the state machine can decide whether a retry is
/// sensible (``isRetryable``).
public enum PerAppCaptureError: Error, Equatable, Sendable {
    /// `resolveProcessSet` found no running process for this bundle ID (not
    /// launched yet, or quit). Retryable — `start(bundleID:)` again once running.
    case appNotRunning(bundleID: String)
    /// The pid resolved, but Core Audio has no process object for it yet —
    /// it has never opened an audio stream (documented `dev/audiocap` edge
    /// case). Retryable — `start(bundleID:)` again once the app starts
    /// playing audio.
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
// exercises the state machine through a fake ProcessAudioTap and a scripted
// resolveProcessSet closure, and never touches these.

#if canImport(AudioToolbox)

/// Stand-in tap for macOS 14.0–14.1, where the process-tap API doesn't exist.
/// `createAndStart` throws immediately, so the coordinator lands the bundle
/// ID in `.failed(.osUnsupported)` instead of crashing.
final class UnavailableProcessTap: ProcessAudioTap, @unchecked Sendable {
    var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
    var onDefaultDeviceChanged: (@Sendable () -> Void)?

    func createAndStart(pids: [pid_t], bundleID: String, muteBehavior: TapMuteBehavior) throws -> TapFormat {
        throw PerAppCaptureError.osUnsupported(minimum: "14.2")
    }

    /// No live tap exists on this OS, so an in-place update is never possible.
    func updateProcessSet(pids: [pid_t]) -> Bool { false }

    func teardown() {}
}

/// The real per-process Core Audio tap (a disciplined port of
/// `dev/audiocap/Sources/audiocap/TapEngine.swift`'s `stereoMixdownOfProcesses`
/// path + `CAHelpers.swift`'s `translatePIDToProcessObject`, combined with the
/// aggregate-device/IOProc/teardown machinery mirrored from
/// `NativeCaptureCoordinator`'s `CoreAudioSystemTap`). Scopes a
/// `CATapDescription` to exactly one Core Audio process object (translated
/// from a pid), builds a PRIVATE aggregate device pinned to the current
/// default output device, registers a realtime IOProc, and delivers buffers
/// with a `pts` taken from the IOProc's `AudioTimeStamp.mHostTime`.
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
    private var deviceChangeBlock: AudioObjectPropertyListenerBlock?
    /// The physical output device our aggregate is built on. Kept so we can
    /// listen for ITS nominal-sample-rate changes (see `installSampleRateListener`).
    private var tappedOutputDeviceID: AudioObjectID = kAudioObjectUnknown
    private var sampleRateBlock: AudioObjectPropertyListenerBlock?

    init(name: String) { self.name = name }

    /// Backstop against leaking a per-process tap / aggregate device if this
    /// tap is dropped without an explicit `teardown()`. `teardown()` is
    /// idempotent and guards each object id, so a double teardown is safe.
    deinit { teardown() }

    func createAndStart(pids: [pid_t], bundleID: String, muteBehavior: TapMuteBehavior) throws -> TapFormat {
        do {
            try createTapAndReadFormat(pids: pids, bundleID: bundleID, muteBehavior: muteBehavior)
            try createAggregate(bundleID: bundleID)
            try startIOProc()
            installDefaultDeviceListener()
            installSampleRateListener()
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

    private func createTapAndReadFormat(pids: [pid_t], bundleID: String, muteBehavior: TapMuteBehavior) throws {
        // COLD-PROMPT GUARD (see ``SystemAudioCaptureTCC``): creating a process
        // tap is what surfaces the macOS audio-capture prompt. A per-app route
        // restored at launch must NOT trigger that prompt cold — only the Setup
        // screen's explicit "Allow…" may. Refuse until the grant is already in
        // place; the coordinator lands this as a retryable failure and re-attempts
        // once the route is re-applied after the user grants in Setup.
        guard SystemAudioCaptureTCC.isGranted() else {
            throw PerAppCaptureError.tapCreationFailed(
                reason: "audio capture not authorized — awaiting the Setup grant")
        }

        // W1-T2: translate EVERY pid in the resolved set (main + children) to a
        // Core Audio process object and tap all of them at once, so a browser
        // or Electron app whose audio plays from a child process is actually
        // captured. The main pid (pids[0], W1-T1 orders main-first) must
        // translate or we surface the ordinary retryable
        // `.processNotYetAudible`/tap-creation error exactly as before; a
        // child that hasn't opened an audio stream yet (very common — most
        // helper processes never play audio) is silently skipped rather than
        // failing the whole tap.
        guard let mainPid = pids.first else {
            throw PerAppCaptureError.processNotYetAudible(bundleID: bundleID)
        }
        var processObjectIDs = [try Self.translateProcessObject(pid: mainPid, bundleID: bundleID)]
        for childPid in pids.dropFirst() {
            if let objID = try? Self.translateProcessObject(pid: childPid, bundleID: bundleID) {
                processObjectIDs.append(objID)
            }
        }

        // Stereo mixdown of the whole resolved process set (dev/audiocap
        // TapEngine .processes / stereoMixdownOfProcesses path) — the per-app
        // analogue of CoreAudioSystemTap's whole-system CATapDescription.
        let desc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
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
        self.asbd = readASBD
        self.format = TapFormat(
            sampleRate: Int(readASBD.mSampleRate.rounded()),
            channels: Int(readASBD.mChannelsPerFrame),
            bitsPerSample: Int(readASBD.mBitsPerChannel),
            isFloat: (readASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
            isInterleaved: (readASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0)
    }

    /// Port of `dev/audiocap/Sources/audiocap/CAHelpers.swift`'s
    /// `translatePIDToProcessObject`: translate a pid to its Core Audio
    /// process `AudioObjectID` via `kAudioHardwarePropertyTranslatePIDToProcessObject`
    /// on the system object, with the pid passed as the property qualifier.
    /// A pid that exists but has never opened an audio stream has no process
    /// object yet — that is the documented, retryable edge case, surfaced as
    /// `.processNotYetAudible` (NOT a crash, NOT lumped into a generic
    /// tap-creation failure).
    private static func translateProcessObject(pid: pid_t, bundleID: String) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pidQualifier = pid
        var objID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pidQualifier,
            &size, &objID)
        guard err == noErr else {
            throw PerAppCaptureError.tapCreationFailed(
                reason: "translate pid \(pid) (\(bundleID)) -> process object failed (\(err))")
        }
        guard objID != kAudioObjectUnknown else {
            throw PerAppCaptureError.processNotYetAudible(bundleID: bundleID)
        }
        return objID
    }

    // MARK: In-place process-set update (W1-T4)

    /// Push a new process set onto the LIVE tap via `kAudioTapPropertyDescription`
    /// without tearing anything down (W1-T0 spike: that property is documented
    /// settable, `CATapDescription.processes` is `readwrite`). Returns `false` —
    /// signalling the coordinator to fall back to a full recreate — on any of:
    /// no live tap, an untranslatable main pid, a non-zero `OSStatus` from the
    /// set call, or an unhealthy post-update format read. Best-effort by
    /// contract; the recreate fallback is the proven path.
    func updateProcessSet(pids: [pid_t]) -> Bool {
        guard tapID != kAudioObjectUnknown, let desc = tapDescription else { return false }
        guard let mainPid = pids.first,
              let mainObj = try? Self.translateProcessObject(pid: mainPid, bundleID: name) else {
            return false
        }
        var processObjectIDs = [mainObj]
        for childPid in pids.dropFirst() {
            if let objID = try? Self.translateProcessObject(pid: childPid, bundleID: name) {
                processObjectIDs.append(objID)
            }
        }

        // Mutate the description's process list and push it back to the live tap.
        desc.processes = processObjectIDs
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // The property value is the CATapDescription object; Core Audio object-
        // valued properties are passed as a pointer to the (CFTypeRef-sized)
        // object reference.
        var descRef = Unmanaged.passUnretained(desc).toOpaque()
        let size = UInt32(MemoryLayout<UnsafeMutableRawPointer>.size)
        let err = withUnsafePointer(to: &descRef) { ptr -> OSStatus in
            AudioObjectSetPropertyData(tapID, &address, 0, nil, size, ptr)
        }
        guard err == noErr else {
            AudioDiag.log("PAC in-place tap update failed (SetPropertyData \(err)) — will recreate")
            return false
        }

        // Health check: re-read the tap's format. If the tap fell out of a
        // healthy state under the live update, treat it as a failure and let the
        // coordinator recreate rather than trusting a possibly-broken tap.
        var fmtAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var readASBD = AudioStreamBasicDescription()
        let fErr = AudioObjectGetPropertyData(tapID, &fmtAddress, 0, nil, &fmtSize, &readASBD)
        guard fErr == noErr, readASBD.mSampleRate > 0 else {
            AudioDiag.log("PAC in-place tap update health-check failed (format read \(fErr)) — will recreate")
            return false
        }
        return true
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

        var newProcID: AudioDeviceIOProcID?
        let queue = DispatchQueue(
            label: "com.airplaycontroller.native.perapp.\(name)", qos: .userInitiated)

        let err = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, aggregateID, queue
        ) { _, inInputData, inInputTime, _, _ in
            // ---- REALTIME THREAD ----
            let mutablePtr = UnsafeMutablePointer(mutating: inInputData)
            let listPtr = UnsafeMutableAudioBufferListPointer(mutablePtr)
            let bufCount = listPtr.count
            if bufCount == 0 { return }

            // pts from the IOProc's own capture clock, rebased onto
            // CLOCK_MONOTONIC via the shared helper (reused, not duplicated —
            // see the file-level doc comment).
            let hostTime = inInputTime.pointee.mHostTime
            let pts = CoreAudioSystemTap.timespec(fromHostTime: hostTime)

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

    // MARK: Default-device-change listener

    private func installDefaultDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDefaultDeviceChanged?()
        }
        self.deviceChangeBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
    }

    private func removeDefaultDeviceListener() {
        guard let block = deviceChangeBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
        deviceChangeBlock = nil
    }

    // MARK: Nominal-sample-rate listener (documented process-tap silent-buffer fix)
    //
    // A process tap keeps delivering buffers at full cadence but goes SILENT
    // (all-zero PCM) when the tapped output device renegotiates its nominal
    // sample rate (44.1 ↔ 48 kHz) — classically triggered by another app taking
    // the mic and forcing voice-processing mode. This is a known, Apple-
    // unresolved Core Audio behaviour (Developer Forums thread 825780); the only
    // reliable recovery is a FULL teardown + rebuild of the tap AND aggregate,
    // which `handleDeviceChange` already performs. The catch: this rate change
    // happens with the default output device's UID UNCHANGED, so the
    // `kAudioHardwarePropertyDefaultOutputDevice` (identity) listener never fires.
    // Listening for the device's `kAudioDevicePropertyNominalSampleRate` catches
    // it and drives the same rebuild via `onDefaultDeviceChanged`.
    private func installSampleRateListener() {
        guard tappedOutputDeviceID != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            AudioDiag.log("PAC nominal-sample-rate changed on tapped device — triggering rebuild")
            self?.onDefaultDeviceChanged?()
        }
        self.sampleRateBlock = block
        AudioObjectAddPropertyListenerBlock(tappedOutputDeviceID, &address, nil, block)
    }

    private func removeSampleRateListener() {
        guard let block = sampleRateBlock, tappedOutputDeviceID != kAudioObjectUnknown else {
            sampleRateBlock = nil
            return
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(tappedOutputDeviceID, &address, nil, block)
        sampleRateBlock = nil
    }

    // MARK: Teardown (order matters: stop -> destroy IOProc -> destroy aggregate -> destroy tap)

    func teardown() {
        removeDefaultDeviceListener()
        removeSampleRateListener()
        tappedOutputDeviceID = kAudioObjectUnknown
        if aggregateID != kAudioObjectUnknown, let proc = ioProcID {
            _ = AudioDeviceStop(aggregateID, proc)
            _ = AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }
}

#endif
