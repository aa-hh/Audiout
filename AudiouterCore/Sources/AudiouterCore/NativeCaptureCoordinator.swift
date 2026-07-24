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

    // MARK: State (confined to `queue`)

    private let queue = DispatchQueue(label: "NativeCaptureCoordinator.state")
    private var _state: State = .idle
    private var tap: SystemAudioTap?
    private var converter: PCMConverting?

    /// STABILITY(C6) (whole-system port of `PerAppCaptureCoordinator`'s
    /// per-slot flag): set when a rebuild trigger — a default-output-device
    /// change (`handleDeviceChange()`), or an exclusion-list change
    /// (`updateRouting(...)`) — arrives while we're already mid-rebuild
    /// (`.creatingTap`), so it isn't silently dropped. The in-flight
    /// `recreateTap()` replays a fresh rebuild once it lands back in
    /// `.capturing`, coalescing however many were dropped into one retry.
    /// Confined to `queue`. See dev/notes/stability-audit-2026-07-18.md §C6.
    private var pendingDeviceChange = false

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
    /// ``setSyncedLocalSink(_:renderProcessPID:)``, snapshotted under `queue` in
    /// ``handleBuffer(_:)``, then run only on the single tap-delivery thread.
    /// Deliberately NOT a ``FractionalResampler`` — that stays the sink's ppm
    /// DRIFT corrector at ratio ≈ 1; base conversion is a distinct step here.
    private var syncedLocalBaseResampler: SyncedLocalBaseResampler?

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
    /// ``setSyncedLocalSink(_:renderProcessPID:)``). Those are benign,
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
            processResolver: processResolver,
            muteBehavior: muteBehavior
        )
    }
    #endif

    /// Injectable designated initializer (internal — tests pass fakes for all
    /// three seams so the state machine runs without a real tap or engine).
    init(
        makeTap: @escaping @Sendable () -> SystemAudioTap,
        sink: PCMSink,
        makeConverter: @escaping @Sendable (TapFormat) -> PCMConverting,
        processResolver: AudioProcessResolver = AudioProcessResolver(enumerator: EmptyAudioProcessEnumerator()),
        muteBehavior: TapMuteBehavior = .mutedWhenTapped
    ) {
        self.makeTap = makeTap
        self.sink = sink
        self.makeConverter = makeConverter
        self.processResolver = processResolver
        self.muteBehavior = muteBehavior
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
    /// getter, a concurrent `stop()`, and every buffer's `handleBuffer`). A `stop()`
    /// racing in during the off-lock create must WIN: the commit re-checks the state
    /// and, if `stop()` already moved us out of `.creatingTap`, discards the
    /// just-created tap (torn down OUTSIDE the lock, since its IO callback also takes
    /// `queue`).
    public func start() {
        // Claim: only proceed from idle/failed; move to .creatingTap and snapshot
        // the exclusion pids (queue-confined) under a SHORT lock.
        let claim: (proceed: Bool, excludedProcessObjectIDs: Set<AudioObjectID>) = queue.sync {
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
                self.transition(to: .capturing(format))
                return nil
            }
            orphan?.teardown()
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
        // Tear down OUTSIDE the state lock (teardown may block on Core Audio).
        toTearDown?.teardown()
        queue.sync {
            self.tap = nil
            self.converter = nil
            self.transition(to: .idle)
        }
    }

    /// Gate RMS computation/emission on or off (T-GATE). Independent of
    /// `start()`/`stop()`: this is the popover-visibility gate, not the capture
    /// gate — the tap may be running (a real AP2 output is selected) while
    /// metering stays off (the popover is closed), and vice versa is harmless
    /// (metering active with the tap idle just means nothing fires yet).
    public func setMeteringActive(_ active: Bool) {
        queue.async { self.meteringActive = active }
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
            if case .capturing = _state { return true }
            return false
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
        var result = currentExcludedBundleIDs.reduce(into: Set<AudioObjectID>()) { result, bundleID in
            result.formUnion(processResolver.resolve(bundleID: bundleID).map(\.objectID))
        }
        if let renderPID = syncedLocalRenderPID {
            result.formUnion(processResolver.resolve(pid: renderPID).map(\.objectID))
        }
        return result
    }

    // MARK: Buffer delivery (tap IOProc thread → convert → engine)

    /// Convert one captured buffer to the engine's fixed S16LE/44100/2ch format
    /// and forward it with a `pts` derived from the buffer's own `mHostTime`.
    /// Runs on the tap's delivery thread (the IOProc, in production). Allocation
    /// beyond the converter's own scratch is avoided on this path where practical.
    private func handleBuffer(_ buffer: CapturedBuffer) {
        // Read the converter under the state lock (cheap — a pointer read) but do
        // the actual conversion OUTSIDE it so a slow convert can't stall stop().
        // `meteringActive` rides along on the same read (T-GATE) — no separate
        // lock acquisition per buffer.
        let (converter, metering, syncedSink, baseResampler) = queue.sync {
            (self.converter, self.meteringActive, self.syncedLocalSink, self.syncedLocalBaseResampler)
        }
        guard let converter else { return }

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
    /// capturing" machinery T4 reuses for an exclusion-list change.
    private func handleDeviceChange() {
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
    /// ``setSyncedLocalSink(_:renderProcessPID:)``) rebuilds the tap but leaves the
    /// device and its clock — and thus the receivers' timeline — untouched.
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
    private func recreateTap(cause: RebuildCause) {
        // Under the lock ONLY: check we're still capturing, claim the old tap,
        // and snapshot the current exclusion pids (queue-confined). The blocking
        // Core Audio teardown+recreate then happens OUTSIDE the lock, matching
        // the pattern stop() deliberately adopts ("teardown may block on Core
        // Audio"). Holding `queue` across those HAL calls would head-of-line
        // block the `state` getter, a concurrent stop(), and every buffer's
        // `handleBuffer` (which reads the converter under the same lock).
        // STABILITY(C6): if a rebuild trigger arrives while we're already
        // mid-rebuild (`.creatingTap`), don't drop it — mark it pending so the
        // in-flight rebuild replays a fresh `recreateTap()` once it lands back
        // in `.capturing`. Rapid device/sample-rate bounces (44.1 -> 48 -> 44.1)
        // mean the LAST notification can be the one that would otherwise be
        // dropped, leaving the tap rebuilt against a stale device/rate. See
        // dev/notes/stability-audit-2026-07-18.md §C6.
        let claim: (proceed: Bool, old: SystemAudioTap?, excludedProcessObjectIDs: Set<AudioObjectID>) = queue.sync {
            guard case .capturing = _state else {
                if case .creatingTap = _state {
                    pendingDeviceChange = true
                }
                return (false, nil, [])
            }
            let t = self.tap
            self.tap = nil
            self.converter = nil          // stop forwarding buffers through the dying tap
            self.transition(to: .creatingTap)
            return (true, t, resolveExcludedProcessObjectIDs())
        }
        // Not capturing (racing a stop()/failure): nothing to do.
        guard claim.proceed else { return }
        let old = claim.old

        // Blocking HAL work OUTSIDE the lock.
        old?.teardown()
        let newTap = makeTap()
        newTap.onBuffer = { [weak self] buffer in self?.handleBuffer(buffer) }
        newTap.onDefaultDeviceChanged = { [weak self] in self?.handleDeviceChange() }

        do {
            let format = try newTap.createAndStart(
                muteBehavior: muteBehavior, excludedProcessObjectIDs: claim.excludedProcessObjectIDs)
            try Self.validate(format)
            let commit: (orphan: SystemAudioTap?, replay: Bool) = queue.sync {
                // A stop() may have raced in while we were recreating: don't clobber
                // an idle/stopping state with a fresh capturing one.
                guard case .creatingTap = _state else {
                    // stop() won. Return the just-created tap and tear it down OUTSIDE
                    // this lock: newTap's IO callback (handleBuffer) synchronously
                    // takes `queue`, so teardown() — which blocks on in-flight IO —
                    // would deadlock if run inside queue.sync (the file's one rule:
                    // "teardown OUTSIDE the state lock").
                    return (newTap, false)
                }
                self.tap = newTap
                self.converter = makeConverter(format)
                self.transition(to: .capturing(format))
                // STABILITY(C6): a rebuild trigger landed while we were rebuilding —
                // replay it once now that we're capturing again, coalescing however
                // many were dropped into a single retry.
                let replay = pendingDeviceChange
                pendingDeviceChange = false
                return (nil, replay)
            }
            commit.orphan?.teardown()
            // Fire the whole-system session-reset signal ONLY when this rebuild was
            // caused by a device/nominal-rate change AND actually committed a fresh
            // `.capturing` (orphan == nil; a racing stop() that won leaves `orphan`
            // set and no live session to reset). An exclusion-set rebuild
            // (`.exclusionChange`) leaves the receivers' RTP timeline intact and must
            // NOT reset — that spurious reset was the redundant per-connect RTP
            // re-establish (see `onDeviceRateRebuild`). Fired OFF the lock, matching
            // the "no HAL/handler work under `queue`" discipline the rest of this
            // method keeps.
            if commit.orphan == nil, cause == .deviceOrRateChange {
                onDeviceRateRebuild?()
            }
            if commit.replay {
                // A trigger coalesced while we were mid-rebuild (C6). It may have been
                // a device/rate change, so replay as `.deviceOrRateChange`: a missed
                // reset would reintroduce the dropout, whereas an extra reset here is
                // at worst harmless and this path only fires on rapid device/rate
                // bounces, never on a plain connect (the sink-attach rebuild lands
                // while `.capturing`, not `.creatingTap`, so it is never coalesced).
                recreateTap(cause: .deviceOrRateChange)
            }
        } catch {
            newTap.teardown()   // createAndStart already tears down internally; idempotent.
            let mapped: NativeCaptureError = (error as? NativeCaptureError)
                ?? .tapCreationFailed(reason: String(describing: error))
            queue.sync {
                guard case .creatingTap = _state else { return }
                self.tap = nil
                self.converter = nil
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
        _state = newState
        onStateChange?(newState)
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
struct EngineSink: PCMSink {
    let engine: AirPlayEngine
    func write(pcm: Data, pts: timespec) { engine.write(pcm: pcm, pts: pts) }
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

/// The real Core Audio process tap (adapted from `dev/audiocap/TapEngine.swift`,
/// read-only reference). Creates a whole-system stereo-mixdown `CATapDescription`,
/// reads its true ASBD, builds a private aggregate device pinned to the default
/// output device, registers a realtime IOProc, and delivers buffers with a `pts`
/// taken from the IOProc's `AudioTimeStamp.mHostTime`.
///
/// It also installs a listener on `kAudioHardwarePropertyDefaultOutputDevice`
/// so the coordinator can recreate the tap when the default output changes.
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
    private var deviceChangeBlock: AudioObjectPropertyListenerBlock?
    private var tappedOutputDeviceID: AudioObjectID = kAudioObjectUnknown
    private var sampleRateBlock: AudioObjectPropertyListenerBlock?

    /// Per-instance mach→CLOCK_MONOTONIC rebase offset (see `timespec(machNanos:offset:)`
    /// below). Resampled once at `startIOProc()` (i.e. every tap create/recreate,
    /// not once per process) and thereafter mutated ONLY from inside the IOProc
    /// block, which Core Audio dispatches serially onto `queue` in `startIOProc()`
    /// — so no lock is needed on this RT-adjacent path, matching this file's
    /// queue-confinement discipline elsewhere.
    private var machToMonotonicOffsetNanos: Int64 = 0

    /// Private serial queue the HAL dispatches the default-output-device listener
    /// block onto. Registering with a `nil` queue lands the block on Core Audio's
    /// internal notification-delivery thread, where the block's blocking tap
    /// teardown+recreate (which itself generates HAL notifications) re-enters the
    /// HAL and can stall or deadlock. Owning the queue moves that work off the
    /// HAL's thread. The SAME queue instance must be handed to both the add and
    /// the remove call — a mismatched queue on remove silently fails to
    /// deregister (mirrors `SystemOutputVolume`'s discipline).
    private let listenerQueue = DispatchQueue(label: "com.audiouter.native.capture.device-listener")

    init(name: String) { self.name = name }

    /// Backstop against leaking a system-wide process tap / aggregate device if
    /// this tap is dropped without an explicit `teardown()` — e.g. a partial
    /// `createAndStart` failure where the caller drops us, or a coordinator
    /// deallocated mid-capture. `teardown()` is idempotent and guards each object
    /// id, so a double teardown is safe.
    deinit { teardown() }

    func createAndStart(muteBehavior: TapMuteBehavior, excludedProcessObjectIDs: Set<AudioObjectID>) throws -> TapFormat {
        // Connect-latency diagnosis (temporary — see AudioDiag): brackets whole-
        // system capture setup (tap + aggregate + IOProc + rate reconciliation) —
        // read alongside NativeBackend's CONNECT logs to see whether this app's own
        // setup, vs. the AirPlay receiver's negotiation, vs. the sync pre-roll, is
        // where a slow connect's time actually goes.
        AudioDiag.log("CAPTURE createAndStart begin")
        do {
            try createTapAndReadFormat(muteBehavior: muteBehavior, excludedProcessObjectIDs: excludedProcessObjectIDs)
            try createAggregate()
            try startIOProc()
            // The format read from `kAudioTapPropertyFormat` above was taken on the
            // BARE tap, before it joined the aggregate. The buffers the IOProc
            // actually delivers arrive on the AGGREGATE's clock, which can differ —
            // correct `format`/`asbd` to that real rate NOW, before the converter is
            // ever built from it (see `reconcileFormatWithAggregate`). Ordered after
            // `startIOProc` (aggregate live, rate settled) and before the listeners
            // so the rate listener's compare-before-rebuild uses the corrected rate.
            reconcileFormatWithAggregate()
            installDefaultDeviceListener()
            installSampleRateListener()
        } catch {
            // Any step after the tap/aggregate was created leaves live system
            // objects; tear them down before propagating so we never orphan a
            // process tap or aggregate device on a partial failure.
            teardown()
            throw error
        }
        AudioDiag.log("CAPTURE createAndStart done, rate=\(format.sampleRate)")
        return format
    }

    // MARK: Tap creation + ASBD read

    private func createTapAndReadFormat(muteBehavior: TapMuteBehavior, excludedProcessObjectIDs: Set<AudioObjectID>) throws {
        // COLD-PROMPT GUARD (see ``SystemAudioCaptureTCC``): creating the tap is
        // what surfaces the macOS audio-capture prompt. Never do that
        // automatically — only the Setup screen's explicit "Allow…" may. If the
        // grant isn't already in place, refuse so a launch-time capture attempt
        // (a restored AirPlay selection) can't prompt cold.
        guard SystemAudioCaptureTCC.isGranted() else {
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

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard err == noErr else {
            throw NativeCaptureError.aggregateDeviceFailed(reason: "AudioHardwareCreateAggregateDevice \(err)")
        }
        self.aggregateID = newAggregateID
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
        AudioDiag.log(
            "System tap: pre-aggregate tap format declared \(format.sampleRate) Hz but the "
            + "aggregate device actually delivers \(reconciled.sampleRate) Hz — correcting the "
            + "converter's input rate to the aggregate's real rate (prevents a sustained pitch shift)")
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
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
    }

    private func removeDefaultDeviceListener() {
        guard let block = deviceChangeBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
        deviceChangeBlock = nil
    }

    // MARK: Nominal-sample-rate listener (documented process-tap silent-buffer fix)
    //
    // A process tap keeps delivering buffers at full cadence but goes SILENT
    // (all-zero PCM) when the tapped output device renegotiates its nominal
    // sample rate (44.1 ↔ 48 kHz) — classically triggered by another app taking
    // the mic and forcing voice-processing mode, or (synced-local) a local sink
    // opening the built-in speakers at a different rate than the tapped device.
    // This is a known, Apple-unresolved Core Audio behaviour (Developer Forums
    // thread 825780); the only reliable recovery is a FULL teardown + rebuild
    // of the tap AND aggregate, which `handleDeviceChange` already performs.
    // The catch: this rate change happens with the default output device's UID
    // UNCHANGED, so the `kAudioHardwarePropertyDefaultOutputDevice` (identity)
    // listener never fires. Listening for the device's
    // `kAudioDevicePropertyNominalSampleRate` catches it and drives the same
    // rebuild via `onDefaultDeviceChanged`. Mirrors
    // `PerAppCaptureCoordinator.installSampleRateListener` — see that file for
    // the fuller writeup — but registers on this class's own `listenerQueue`
    // (not a `nil` queue) for the same off-HAL-thread reason
    // `installDefaultDeviceListener` above documents.
    private func installSampleRateListener() {
        guard tappedOutputDeviceID != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // COMPARE-BEFORE-REBUILD LOOP-BREAKER: read the tapped device's new
            // nominal rate and rebuild ONLY if it actually differs from the rate the
            // converter is currently built on (`format.sampleRate`, already
            // corrected to the aggregate's real rate by `reconcileFormatWithAggregate`
            // before this listener was installed). Core Audio can post this listener
            // for a set-to-same-value; a spurious full teardown+rebuild both burns
            // CPU and risks a rebuild storm, so a no-op notification must stay a
            // no-op. `format` is written ONLY during `createAndStart` (before this
            // listener is installed) and is never mutated afterward for the life of
            // the instance — a real rate change rebuilds a fresh `CoreAudioSystemTap`
            // whose own `createAndStart` re-reads the format — so reading it here off
            // `listenerQueue` is race-free, the same setup-time-immutability the rest
            // of this class relies on for `tappedOutputDeviceID`.
            let notified = Self.readNominalSampleRate(self.tappedOutputDeviceID)
            guard Self.shouldRebuildForNominalRate(
                notifiedRate: notified, currentEffectiveRate: self.format.sampleRate) else {
                AudioDiag.log(
                    "System tap: nominal-rate notification but rate unchanged "
                    + "(\(self.format.sampleRate) Hz) — skipping rebuild")
                return
            }
            AudioDiag.log(
                "System tap: nominal-sample-rate changed on tapped device (now "
                + "\(notified.map { String(Int($0.rounded())) } ?? "unreadable") Hz) — triggering rebuild")
            self.onDefaultDeviceChanged?()
        }
        self.sampleRateBlock = block
        AudioObjectAddPropertyListenerBlock(tappedOutputDeviceID, &address, listenerQueue, block)
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
        AudioObjectRemovePropertyListenerBlock(tappedOutputDeviceID, &address, listenerQueue, block)
        sampleRateBlock = nil
    }

    // MARK: Teardown (order matters: stop → destroy IOProc → destroy aggregate → destroy tap)

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
