import Foundation
import AirPlayEngine

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

    /// Bundle ID -> running pid, for the exclusion list (T4). AppKit-only
    /// (`NSRunningApplication`), so `AudioutedCore` cannot resolve
    /// this itself (package rule, `AudioutedCore/AGENTS.md`) —
    /// mirrors `PerAppCaptureCoordinator`'s injected `resolvePID` exactly.
    /// Defaults to "nothing resolves," which reproduces today's
    /// always-empty exclusion list until an AppKit-importing layer supplies
    /// the real resolver (T6).
    private let resolvePID: @Sendable (_ bundleID: String) -> pid_t?

    // MARK: State (confined to `queue`)

    private let queue = DispatchQueue(label: "NativeCaptureCoordinator.state")
    private var _state: State = .idle
    private var tap: SystemAudioTap?
    private var converter: PCMConverting?

    /// The live union of routed-away (`.device` destination) and
    /// user-excluded bundle IDs, as last computed by
    /// ``updateRouting(appRoutes:excludedBundleIDs:)``. Confined to `queue`.
    /// Applied to the NEXT tap creation (initial `start()`, a device-change
    /// recreate, or an exclusion-change recreate) — never mutates a tap
    /// that's already running without going through a recreate.
    private var currentExcludedBundleIDs: Set<String> = []

    /// Fired on every state transition so a UI (or a test) can observe the
    /// lifecycle. Called on the coordinator's internal queue.
    public var onStateChange: (@Sendable (State) -> Void)?

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
    ///   - resolvePID: bundle ID -> running pid, for the live exclusion list
    ///     (T4 — apps individually routed elsewhere, or user-excluded via
    ///     Settings, must not double up into the system-wide mix). Defaults
    ///     to "nothing resolves" (today's behavior: an always-empty
    ///     exclusion list) until an AppKit-importing layer wires the real
    ///     resolver (T6).
    ///   - name: a short label used for the private tap/aggregate device name.
    ///   - muteBehavior: `.mutedWhenTapped` (default) silences local playback
    ///     while capturing — matching the native-path intent (audio goes to the
    ///     receivers, not the built-in speakers). `.unmuted` mirrors it locally.
    #if canImport(AudioToolbox)
    public convenience init(
        engine: AirPlayEngine,
        resolvePID: @escaping @Sendable (String) -> pid_t? = { _ in nil },
        name: String = "Audiouted",
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
            resolvePID: resolvePID,
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
        resolvePID: @escaping @Sendable (String) -> pid_t? = { _ in nil },
        muteBehavior: TapMuteBehavior = .mutedWhenTapped
    ) {
        self.makeTap = makeTap
        self.sink = sink
        self.makeConverter = makeConverter
        self.resolvePID = resolvePID
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
        let claim: (proceed: Bool, excludedPIDs: Set<pid_t>) = queue.sync {
            switch _state {
            case .idle, .failed:
                self.transition(to: .creatingTap)
                return (true, resolveExcludedPIDs())
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
            let format = try newTap.createAndStart(muteBehavior: muteBehavior, excludedPIDs: claim.excludedPIDs)
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
        recreateTap()
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

    /// Resolve the live excluded-bundle-ID set to pids via the injected
    /// ``resolvePID`` closure. Best-effort: a bundle ID with no resolvable
    /// running process (not launched, or the AppKit lookup misses) is
    /// silently dropped rather than failing tap creation — the whole-system
    /// tap must still succeed even if one excluded app isn't
    /// pid-resolvable yet. MUST be called while holding `queue`
    /// (`currentExcludedBundleIDs` is queue-confined).
    private func resolveExcludedPIDs() -> Set<pid_t> {   // must hold `queue`
        Set(currentExcludedBundleIDs.compactMap(resolvePID))
    }

    // MARK: Buffer delivery (tap IOProc thread → convert → engine)

    /// Convert one captured buffer to the engine's fixed S16LE/44100/2ch format
    /// and forward it with a `pts` derived from the buffer's own `mHostTime`.
    /// Runs on the tap's delivery thread (the IOProc, in production). Allocation
    /// beyond the converter's own scratch is avoided on this path where practical.
    private func handleBuffer(_ buffer: CapturedBuffer) {
        // Read the converter under the state lock (cheap — a pointer read) but do
        // the actual conversion OUTSIDE it so a slow convert can't stall stop().
        let converter = queue.sync { self.converter }
        guard let converter else { return }

        guard let pcm = converter.convertToAirPlayPCM(buffer) else { return }
        guard !pcm.isEmpty else { return }

        // pts straight off the buffer's capture clock (mHostTime → timespec).
        sink.write(pcm: pcm, pts: buffer.pts)

        // Level pass-through: compute RMS on the CONVERTED S16LE buffer once, for
        // the meter feature (identical for every fanned-out device).
        if let onLevel {
            onLevel(Self.rmsOfS16LE(pcm))
        }
    }

    /// The default output device changed under us (the tap follows it, so its
    /// real format may now differ — e.g. built-in 44100 → USB DAC 48000).
    /// Delegates to ``recreateTap()`` — the same "tear down + recreate while
    /// capturing" machinery T4 reuses for an exclusion-list change.
    private func handleDeviceChange() {
        recreateTap()
    }

    /// Tear the current tap down and recreate it — against the (possibly
    /// new) default output device, and always with the LIVE exclusion pid
    /// set (``resolveExcludedPIDs()``, re-resolved fresh so a stale pid from
    /// before an app relaunch is never carried forward). Shared by two
    /// triggers: ``handleDeviceChange()`` (the tap's own
    /// `onDefaultDeviceChanged`) and ``updateRouting(appRoutes:excludedBundleIDs:)``
    /// (the routed/excluded bundle-ID set changed while capturing). Only
    /// takes effect if currently `.capturing`; a race with a concurrent
    /// `stop()`/failure is a no-op. Surfaced as a fresh `.capturing(format')`
    /// transition, or `.failed` if re-creation fails.
    private func recreateTap() {
        // Under the lock ONLY: check we're still capturing, claim the old tap,
        // and snapshot the current exclusion pids (queue-confined). The blocking
        // Core Audio teardown+recreate then happens OUTSIDE the lock, matching
        // the pattern stop() deliberately adopts ("teardown may block on Core
        // Audio"). Holding `queue` across those HAL calls would head-of-line
        // block the `state` getter, a concurrent stop(), and every buffer's
        // `handleBuffer` (which reads the converter under the same lock).
        // STABILITY(C6): a device change during tap recreation is silently dropped — see dev/notes/stability-audit-2026-07-18.md
        let claim: (proceed: Bool, old: SystemAudioTap?, excludedPIDs: Set<pid_t>) = queue.sync {
            guard case .capturing = _state else { return (false, nil, []) }
            let t = self.tap
            self.tap = nil
            self.converter = nil          // stop forwarding buffers through the dying tap
            self.transition(to: .creatingTap)
            return (true, t, resolveExcludedPIDs())
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
            let format = try newTap.createAndStart(muteBehavior: muteBehavior, excludedPIDs: claim.excludedPIDs)
            try Self.validate(format)
            let orphan: SystemAudioTap? = queue.sync {
                // A stop() may have raced in while we were recreating: don't clobber
                // an idle/stopping state with a fresh capturing one.
                guard case .creatingTap = _state else {
                    // stop() won. Return the just-created tap and tear it down OUTSIDE
                    // this lock: newTap's IO callback (handleBuffer) synchronously
                    // takes `queue`, so teardown() — which blocks on in-flight IO —
                    // would deadlock if run inside queue.sync (the file's one rule:
                    // "teardown OUTSIDE the state lock").
                    return newTap
                }
                self.tap = newTap
                self.converter = makeConverter(format)
                self.transition(to: .capturing(format))
                return nil
            }
            orphan?.teardown()
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
    /// - Parameter excludedPIDs: pids to leave OUT of the whole-system mix
    ///   (T4 — apps individually routed elsewhere, or user-excluded via
    ///   Settings). A pid that can't be translated to a Core Audio process
    ///   object yet is silently skipped rather than failing tap creation —
    ///   see ``CoreAudioSystemTap``'s implementation. Empty = the whole
    ///   system, unchanged from pre-T4 behavior.
    func createAndStart(muteBehavior: TapMuteBehavior, excludedPIDs: Set<pid_t>) throws -> TapFormat

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

    func createAndStart(muteBehavior: TapMuteBehavior, excludedPIDs: Set<pid_t>) throws -> TapFormat {
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

    /// Private serial queue the HAL dispatches the default-output-device listener
    /// block onto. Registering with a `nil` queue lands the block on Core Audio's
    /// internal notification-delivery thread, where the block's blocking tap
    /// teardown+recreate (which itself generates HAL notifications) re-enters the
    /// HAL and can stall or deadlock. Owning the queue moves that work off the
    /// HAL's thread. The SAME queue instance must be handed to both the add and
    /// the remove call — a mismatched queue on remove silently fails to
    /// deregister (mirrors `SystemOutputVolume`'s discipline).
    private let listenerQueue = DispatchQueue(label: "com.audiouted.native.capture.device-listener")

    init(name: String) { self.name = name }

    /// Backstop against leaking a system-wide process tap / aggregate device if
    /// this tap is dropped without an explicit `teardown()` — e.g. a partial
    /// `createAndStart` failure where the caller drops us, or a coordinator
    /// deallocated mid-capture. `teardown()` is idempotent and guards each object
    /// id, so a double teardown is safe.
    deinit { teardown() }

    func createAndStart(muteBehavior: TapMuteBehavior, excludedPIDs: Set<pid_t>) throws -> TapFormat {
        do {
            try createTapAndReadFormat(muteBehavior: muteBehavior, excludedPIDs: excludedPIDs)
            try createAggregate()
            try startIOProc()
            installDefaultDeviceListener()
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

    private func createTapAndReadFormat(muteBehavior: TapMuteBehavior, excludedPIDs: Set<pid_t>) throws {
        // Whole-system stereo mixdown, excluding apps that are individually
        // routed elsewhere or user-excluded (T4 — avoids the double-send bug:
        // a routed app's audio going to its own destination AND leaking into
        // this system mix). Empty exclusion list = the whole system, exactly
        // pre-T4 behavior.
        let excludedProcessObjects = Self.translateExcludedProcessObjects(excludedPIDs)
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcessObjects)
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

    /// Best-effort pid → Core Audio process-object translation for the
    /// exclusion list (T4). Mirrors
    /// `PerAppCaptureCoordinator.CoreAudioProcessTap.translateProcessObject`
    /// (same `kAudioHardwarePropertyTranslatePIDToProcessObject` call) but
    /// folded down to non-throwing + batch: a pid that doesn't resolve yet
    /// (app not launched, or hasn't opened an audio stream) is silently
    /// skipped rather than failing the WHOLE global tap — losing one app's
    /// exclusion for a moment is far better than losing system audio
    /// capture entirely.
    private static func translateExcludedProcessObjects(_ pids: Set<pid_t>) -> [AudioObjectID] {
        guard !pids.isEmpty else { return [] }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var result: [AudioObjectID] = []
        result.reserveCapacity(pids.count)
        for pid in pids {
            var pidQualifier = pid
            var objID: AudioObjectID = kAudioObjectUnknown
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let err = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &pidQualifier,
                &size, &objID)
            if err == noErr, objID != kAudioObjectUnknown {
                result.append(objID)
            }
        }
        return result
    }

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

        var newProcID: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "com.audiouted.native.capture", qos: .userInitiated)

        let err = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, aggregateID, queue
        ) { _, inInputData, inInputTime, _, _ in
            // ---- REALTIME THREAD ----
            let mutablePtr = UnsafeMutablePointer(mutating: inInputData)
            let listPtr = UnsafeMutableAudioBufferListPointer(mutablePtr)
            let bufCount = listPtr.count
            if bufCount == 0 { return }

            // pts from the IOProc's own capture clock (host time → timespec).
            let hostTime = inInputTime.pointee.mHostTime
            let pts = Self.timespec(fromHostTime: hostTime)

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

    // MARK: Teardown (order matters: stop → destroy IOProc → destroy aggregate → destroy tap)

    func teardown() {
        removeDefaultDeviceListener()
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
    /// `CLOCK_MONOTONIC` using a fixed offset sampled once at first use.
    static func timespec(fromHostTime hostTime: UInt64) -> timespec {
        let machNanos = machNanoseconds(fromHostTime: hostTime)
        let monotonicNanos = Int64(machNanos) &+ machToMonotonicOffsetNanos
        let clamped = monotonicNanos < 0 ? 0 : monotonicNanos
        return Darwin.timespec(tv_sec: Int(clamped / 1_000_000_000),
                               tv_nsec: Int(clamped % 1_000_000_000))
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

    /// `CLOCK_MONOTONIC_nanos - mach_absolute_nanos`, sampled ONCE at first use.
    /// Adding it to a mach-time nanosecond value rebases that value onto the
    /// `CLOCK_MONOTONIC` timescale the engine/receiver compare against. Sampled
    /// as a single offset (rather than re-reading both clocks per buffer) so a
    /// captured buffer's `mHostTime` maps to a stable, monotonically-advancing
    /// `CLOCK_MONOTONIC` position — exactly what the sync path needs. Can be
    /// negative (CLOCK_MONOTONIC < mach-absolute when the box has slept), which is
    /// why the arithmetic above is signed.
    private static let machToMonotonicOffsetNanos: Int64 = {
        // Sample both clocks as close together as possible.
        let mach = machNanoseconds(fromHostTime: mach_absolute_time())
        var ts = Darwin.timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        let monotonic = UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
        return Int64(monotonic) &- Int64(mach)
    }()

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
