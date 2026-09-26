import Foundation
import AudioToolbox
import AirPlayEngine
import CastSender

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

    /// Peak level and silence run per content stream since the last call
    /// (mirrors `AirPlayEngine/streamLevelSnapshot()`). Polled with the
    /// scheduling snapshot every ~5 s into the `stream_health` line. Empty by
    /// default so a conformer that predates it compiles unchanged.
    nonisolated func streamLevelSnapshot() -> [StreamLevelSnapshot]
}

extension EngineControlling {
    /// Default: an all-zero (healthy) snapshot, so every existing test double
    /// compiles unchanged. ``EngineAdapter`` overrides this with the real read.
    func writeBacklogSnapshot() -> WriteBacklogSnapshot { WriteBacklogSnapshot() }

    /// Default: no streams, same reason as `writeBacklogSnapshot()`.
    nonisolated func streamLevelSnapshot() -> [StreamLevelSnapshot] { [] }

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
    nonisolated func streamLevelSnapshot() -> [StreamLevelSnapshot] { engine.streamLevelSnapshot() }
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

    /// Stage the calibration sweeps for a PHONE-driven run: same feed and arm
    /// gate as ``stageWizardMicProbe(onStarted:onFinished:)``, but optionally
    /// staggered across two Bluetooth speakers (`downWindowUID`/`upWindowUID`
    /// name which sink hears which sweep), and never handing over to the
    /// by-ear tick grid when it completes. Default no-op;
    /// ``NativeCaptureCoordinator`` provides the real one.
    func stageCompanionMicProbe(staggered: Bool,
                                referenceOnEngine: Bool,
                                downWindowUID: String?,
                                upWindowUID: String?,
                                onStarted: @escaping () -> Void,
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

    /// Attach/detach the leveled-app intercept — the per-app volume path for
    /// apps that are NOT redirected (see ``LeveledAppInjector``). Default no-op;
    /// ``NativeCaptureCoordinator`` provides the real one.
    func setLeveledAppInjector(_ injector: LeveledAppInjector?)

    /// Hand the delivery path a new set of tone stages: the Main Out EQ (applied
    /// before every fan-out) plus one AirPlay write per stream in the plan. Default no-op
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
    /// Default no-op (leveled-app intercept), same posture.
    func setLeveledAppInjector(_ injector: LeveledAppInjector?) {}
    /// Default no-ops (roadmap 056 Part B wizard stimulus), same posture.
    func armWizardTicks() {}
    func setWizardTempo(bpm: Double) {}
    /// Default no-op (roadmap 064 mic probe), same posture.
    func stageWizardMicProbe(onStarted: @escaping () -> Void,
                             onFinished: @escaping () -> Void) {}
    /// Default no-op (the phone-driven sync-calibration run), same posture.
    func stageCompanionMicProbe(staggered: Bool,
                                referenceOnEngine: Bool,
                                downWindowUID: String?,
                                upWindowUID: String?,
                                onStarted: @escaping () -> Void,
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
    /// Drop every per-device sink outside `uids` — see
    /// ``BTSyncedSink/removeDevices(notIn:)``. Same default-no-op posture as
    /// `setTrimMs`.
    func removeDevices(notIn uids: Set<String>)
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
    /// Re-anchor this device's sink if a live trim since its anchor could not
    /// be applied in full — see
    /// ``BTSyncedSink/reanchorIfTrimClamped(forDeviceUID:)``. Called on a
    /// COMMITTED trim only. Same default-no-op posture as `setTrimMs`.
    func reanchorIfTrimClamped(forDeviceUID uid: String)
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
    /// The UIDs per-app routing feeds directly, so the whole-system fan-out
    /// skips them and no speaker hears both mixes. Same default-no-op posture as
    /// `setTrimMs`.
    func setPerAppClaimedUIDs(_ uids: Set<String>)
    /// Feed one per-app mixed stream to exactly `uids`, ignoring the claim set
    /// above. Same default-no-op posture as `setTrimMs`.
    func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec,
                 forDeviceUIDs uids: [String])
    /// Silence keep-alive window (roadmap 085 ticket 04) — see
    /// ``BTSyncedSink/setKeepAliveWindow(nanos:)``. Same default-no-op posture
    /// as `setTrimMs`.
    func setKeepAliveWindow(nanos: Int64)
    /// When the fan-out last rendered real program audio — see
    /// ``BTSyncedSink/lastAudibleRenderNanos()``. Defaults to `nil` ("can't
    /// tell"), which the caller reads as "not in a gap", so lifecycle-only
    /// spies never make a drift correction land as an immediate move.
    func lastAudibleRenderNanos() -> Int64?
}

extension BTSyncedSinkControlling {
    func anchoredDeviceUIDs() -> Set<String>? { nil }
    func setKeepAliveWindow(nanos: Int64) {}
    func lastAudibleRenderNanos() -> Int64? { nil }
    func setTrimMs(_ ms: Double, forDeviceUID uid: String) {}
    func reanchorIfTrimClamped(forDeviceUID uid: String) {}
    func reanchorAll(cause: String) {}
    func setOffsetMs(_ ms: Int, forDeviceUID uid: String) {}
    func setBTOnlyBufferMs(_ ms: Int) {}
    func removeDevices(notIn uids: Set<String>) {}
    func usableTrimRangeMs(forDeviceUID uid: String) -> ClosedRange<Double> {
        -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs
    }
    func setGain(_ gain: Float, forDeviceUID uid: String) {}
    func setEQ(_ eq: DeviceEQ, forDeviceUID uid: String) {}
    func setPerAppClaimedUIDs(_ uids: Set<String>) {}
    func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec,
                 forDeviceUIDs uids: [String]) {}
}

extension BTSyncedSink: BTSyncedSinkControlling {}
