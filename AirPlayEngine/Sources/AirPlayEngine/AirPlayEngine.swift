// AirPlayEngine — the neutral Swift API over the vendored, license-labeled C
// AirPlay 2 sender cluster (CAirPlayEngine). T-API-1.
//
// This replaces the T-PKG-1/T-BUILD-1 scaffold placeholder with the real
// session API described in build-notes §6 and seam-map §2/§8. Design goals:
//   - One owned engine thread + libevent base (seam-map §8, risk R-B). Every C
//     entry point is marshaled onto it via EngineThread.run/enqueue.
//   - The C async-completion dispatcher (shims/outputs.c) is bridged to
//     async/await via CompletionRegistry (keyed by callback_id).
//   - Discovery is app-owned (Q5): the app feeds resolved DeviceDescriptors;
//     the engine drives the vendored sender's own discovery callback.
//   - Shaped so a future NativeBackend (T-BACKEND-1) can implement the app's
//     OutputBackend protocol on top — addOutput/removeOutput/setVolume/write/
//     stop are the primitives that protocol needs.
//
// SPEC.md §4: no OwnTone naming appears in any public symbol here.
//
// SCOPE (T-API-1): BUILD + HEADLESS TESTS ONLY. This type is complete enough to
// drive a one-device session, but a LIVE session against a real receiver is a
// separate GATED step (needs a receiver, OwnTone stopped for PTP 319/320, and a
// human present). Nothing here opens a socket to a real device on its own; that
// only happens if start()/addOutput() are called against real hardware, which
// the probe CLI guards behind an explicit flag and this task never runs.

import Foundation
import CAirPlayEngine

/// The engine's configuration, applied to the vendored `conffile` shim before
/// `airplay_init` runs. Strings are retained by the engine for its lifetime
/// (the C side does NOT copy them — build-notes §6 item 3).
public struct EngineConfig: Sendable {
    /// Client name advertised to receivers (`library.name`). Also seeds the
    /// device id / PTP clock id via a hash (`libhash`).
    public var clientName: String
    /// The RTSP `User-Agent` string.
    public var userAgent: String
    /// PTP/timing bind address, or nil to bind to any interface.
    public var bindAddress: String?
    /// Whether to advertise/accept IPv6 (needed for link-local PTP peers).
    public var enableIPv6: Bool
    /// Timing service UDP port (0 = ephemeral).
    public var timingPort: Int
    /// Control service UDP port (0 = ephemeral).
    public var controlPort: Int

    public init(
        clientName: String = "AirPlayEngine",
        userAgent: String = "AirPlayEngine/0.1.0",
        bindAddress: String? = nil,
        enableIPv6: Bool = true,
        timingPort: Int = 0,
        controlPort: Int = 0
    ) {
        self.clientName = clientName
        self.userAgent = userAgent
        self.bindAddress = bindAddress
        self.enableIPv6 = enableIPv6
        self.timingPort = timingPort
        self.controlPort = controlPort
    }
}

/// The Swift-facing AirPlay 2 audio sender engine.
///
/// Lifecycle: `init(config:)` -> `start()` (creates the engine thread, wires the
/// dispatcher, runs `airplay_init`) -> feed discovery + drive sessions -> `stop()`.
///
/// Concurrency: this is an `actor` so its Swift-visible state (config strings,
/// known outputs) is serialized; all *C* work is additionally marshaled onto the
/// single engine thread (R-B) by `EngineThread`.
public actor AirPlayEngine {

    // MARK: Stored state

    private let config: EngineConfig
    private let engineThread: EngineThread
    private let completions = CompletionRegistry()

    private var started = false
    // A nonisolated mirror of `started` the hot write path can read without an
    // actor hop. Kept in lock-step with `started`.
    private nonisolated let startedFlag = AtomicBool(false)

    // Retained C strings handed to conffile (not copied by the C side).
    private var clientNameC: UnsafeMutablePointer<CChar>?
    private var userAgentC: UnsafeMutablePointer<CChar>?
    private var bindAddressC: UnsafeMutablePointer<CChar>?

    /// Outputs the app has added, by id. The vendored registry owns the actual
    /// `output_device`; we keep just the id and last-known state.
    private var knownOutputs: [OutputID: OutputState] = [:]

    /// Placeholder for the synced local Core Audio sink (SPEC §8.1). Not
    /// implemented in T-API-1 — see ``localOutput``.
    private var localOutputEnabled = false

    // Test seam (headless verification). When set, `issueOverride` replaces the
    // backend device_* call in startOp: it still arms the REAL C dispatcher
    // waiter (outputs_callback_add + CompletionRegistry) and returns N, but does
    // NOT touch hardware. The test then fires a synthetic outputs_cb +
    // outputs_cb_deferred_run to resume the waiter through the genuine
    // completion path (build-notes §6: exercise the dispatcher's synthetic-
    // completion path with no real event loop/hardware). See
    // Tests/.../AirPlayEngineAPITests.swift.
    private var issueOverride: ((UnsafeMutablePointer<output_device>, Int32) -> Int32)?

    // MARK: Init

    public init(config: EngineConfig = EngineConfig()) {
        self.config = config
        self.engineThread = EngineThread()
    }

    // MARK: Backward-compatible scaffold probe (kept so T-BUILD-1 tests pass)

    /// Link-verification probe retained from the T-BUILD-1 scaffold: calls one
    /// vendored/shimmed C entry point through the module map. Returns the default
    /// start-buffer duration (2250 ms). Kept so `AirPlayEngineScaffoldTests`
    /// stays green after T-API-1.
    public static var scaffoldBufferDurationMs: UInt64 {
        return outputs_buffer_duration_ms_get()
    }

    /// Retained scaffold status string (kept so `AirPlayEngineScaffoldTests`
    /// stays green). Now reflects the T-API-1 milestone.
    public static let scaffoldStatus =
        "T-API-1: Swift session API over CAirPlayEngine (build + headless tests; live session is a separate gated step)"

    // MARK: - Lifecycle

    /// Start the engine: create the engine thread + base, set `evbase_player`,
    /// wire the dispatcher + completion hook, apply config, then run
    /// `airplay_init` (via `output_airplay.init`). Idempotent-safe: throws if
    /// already started or if the thread/base can't be created.
    ///
    /// LIVE-SESSION NOTE: `airplay_init` starts the timing/control UDP services
    /// and `ptpd_init`. Against real hardware this is where PTP 319/320 binding
    /// happens — the gated step. In headless tests this is not called (tests use
    /// the test hook), so no sockets are opened.
    public func start() async throws {
        guard !started else { return }

        guard engineThread.start(), let base = engineThread.base else {
            throw AirPlayEngineError.engineThreadFailed
        }

        // Everything below touches the C cluster -> must run on the engine thread.
        let initResult: Int32 = await engineThread.run { [self] in
            // 1. Set evbase_player BEFORE airplay_init (seam-map §8).
            evbase_player = base

            // 2. Wire the deferred dispatcher event to the base, and install the
            //    completion hook that resumes our async waiters.
            if outputs_dispatcher_init() != 0 {
                return -100 // dispatcher wiring failed
            }
            completions.install()

            // 3. Apply config via conffile setters (strings NOT copied — retained
            //    on `self` for the engine lifetime).
            applyConfigOnEngineThread()

            // 4. Start the backend: output_airplay.init == airplay_init. This also
            //    calls mdns_browse -> our shim captures airplay_device_cb so
            //    discovery-in works afterwards.
            guard let initFn = output_airplay.`init` else { return -101 }
            return initFn()
        }

        if initResult != 0 {
            // Roll back the thread; nothing is streaming yet.
            await engineThread.run { [self] in
                completions.uninstall()
                outputs_dispatcher_deinit()
            }
            engineThread.stop()
            freeConfigStrings()
            throw initResult == -100 ? AirPlayEngineError.engineThreadFailed
                : AirPlayEngineError.initFailed
        }

        started = true
        startedFlag.store(true)
    }

    /// Stop the engine: tear down all sessions (`airplay_deinit`), unwire the
    /// dispatcher, break the loop, join the thread. Idempotent.
    public func stop() async {
        guard started else { return }
        started = false
        startedFlag.store(false)

        await engineThread.run { [self] in
            if let deinitFn = output_airplay.deinit {
                deinitFn()
            }
            completions.uninstall()
            outputs_dispatcher_deinit()
            evbase_player = nil
        }
        engineThread.stop()
        freeConfigStrings()
        knownOutputs.removeAll()
    }

    // MARK: - Config (engine thread)

    private func applyConfigOnEngineThread() {
        clientNameC = strdupC(config.clientName)
        userAgentC = strdupC(config.userAgent)
        bindAddressC = config.bindAddress.map { strdupC($0) }

        conffile_set_library_name(clientNameC)
        conffile_set_user_agent(userAgentC)
        conffile_set_bind_address(bindAddressC) // NULL = any
        conffile_set_ipv6(config.enableIPv6)
        conffile_set_ports(config.timingPort, config.controlPort)
        // Derive a stable libhash from the client name (device id / PTP seed).
        conffile_set_libhash(Self.hashClientName(config.clientName))
    }

    private func freeConfigStrings() {
        [clientNameC, userAgentC, bindAddressC].forEach { if let p = $0 { free(p) } }
        clientNameC = nil; userAgentC = nil; bindAddressC = nil
    }

    /// A stable 64-bit hash of the client name (FNV-1a), used as `libhash`.
    static func hashClientName(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        // Keep it non-zero (the C side asserts a non-zero seed).
        return hash == 0 ? 0x1 : hash
    }

    // MARK: - Discovery IN (app-owned NWBrowser -> engine)

    /// Feed a resolved receiver descriptor into the engine. This drives the
    /// vendored sender's own discovery callback (seam-map §4), which parses the
    /// TXT `deviceid`/`features`, applies the AP2 gate + reconnect heuristic, and
    /// registers the device. Call again with the same descriptor to update it.
    ///
    /// Returns the ``OutputID`` the device was registered under. Throws
    /// `invalidDescriptor` if the descriptor lacks a valid `deviceid`.
    @discardableResult
    public func updateDiscovery(_ descriptor: DeviceDescriptor) async throws -> OutputID {
        try requireStarted()
        guard let id = descriptor.parsedID else { throw AirPlayEngineError.invalidDescriptor }

        await engineThread.run { [self] in feedDescriptor(descriptor, appearing: true) }
        if knownOutputs[id] == nil { knownOutputs[id] = .stopped }
        return id
    }

    /// Signal that a previously-discovered device has disappeared (the app's
    /// NWBrowser lost it). Matches on the descriptor's `name` (seam-map §4).
    public func removeDiscovery(_ descriptor: DeviceDescriptor) async {
        guard started else { return }
        await engineThread.run { [self] in feedDescriptor(descriptor, appearing: false) }
        if let id = descriptor.parsedID { knownOutputs.removeValue(forKey: id) }
    }

    /// Build the C keyval + call the captured discovery callback. Engine thread.
    private func feedDescriptor(_ descriptor: DeviceDescriptor, appearing: Bool) {
        // Build the TXT keyval the sender's features_parse/device_id_colon_parse
        // read. Freed after the (synchronous) callback returns.
        guard let kv = keyval_alloc() else { return }
        defer { keyval_clear(kv); free(kv) }
        for (k, v) in descriptor.txtRecord {
            k.withCString { kc in v.withCString { vc in _ = keyval_add(kv, kc, vc) } }
        }

        let family: Int32 = descriptor.family == .ipv4 ? Int32(AF_INET) : Int32(AF_INET6)
        // port > 0 => appeared/updated; port < 0 => disappeared.
        let port: Int32 = appearing ? Int32(descriptor.port) : -1

        descriptor.name.withCString { name in
            descriptor.hostname.withCString { host in
                descriptor.address.withCString { addr in
                    _ = airplayengine_feed_device(name, host, family, addr, port, kv)
                }
            }
        }
    }

    // MARK: - Session lifecycle

    /// Begin streaming to the output with `id`: arm a completion waiter, call
    /// `output_airplay.device_start`, and await the deferred dispatcher
    /// completion (STREAMING / PASSWORD / FAILED). Maps a non-STREAMING terminal
    /// state to a thrown error.
    ///
    /// This is the primitive a future `NativeBackend.addOutput` builds on.
    public func addOutput(_ id: OutputID) async throws {
        try requireStarted()
        guard knownOutputs[id] != nil else { throw AirPlayEngineError.unknownOutput(id) }

        let terminal = try await startOp(id: id) { device, cbId in
            guard let startFn = output_airplay.device_start else { return -1 }
            return startFn(device, cbId)
        }

        knownOutputs[id] = terminal
        switch terminal {
        case .streaming, .connected: return
        case .passwordRequired:      throw AirPlayEngineError.passwordRequired
        case .failed, .stopped:      throw AirPlayEngineError.sessionFailed
        case .startup:               throw AirPlayEngineError.sessionFailed
        }
    }

    /// Stop streaming to `id`: arm a waiter, call `output_airplay.device_stop`,
    /// await the completion. The device stays registered (re-addable) unless the
    /// dispatcher drops it. Primitive for `NativeBackend.removeOutput`.
    public func removeOutput(_ id: OutputID) async throws {
        try requireStarted()
        guard knownOutputs[id] != nil else { throw AirPlayEngineError.unknownOutput(id) }

        let terminal = try await startOp(id: id) { device, cbId in
            guard let stopFn = output_airplay.device_stop else { return -1 }
            return stopFn(device, cbId)
        }
        knownOutputs[id] = terminal
    }

    /// Set the volume (0.0...1.0) on `id`. Maps onto AirPlay's volume model and
    /// calls `output_airplay.device_volume_set`. Awaits the completion.
    public func setVolume(_ id: OutputID, _ volume: Double) async throws {
        try requireStarted()
        guard knownOutputs[id] != nil else { throw AirPlayEngineError.unknownOutput(id) }

        let clamped = max(0.0, min(1.0, volume))
        // Set device->volume (0...max_volume) BEFORE the op, on the engine thread.
        // The vendored airplay_set_volume_one reads it to build SET_PARAMETER.
        // Kept out of the issue closure so it still runs in headless test mode
        // (where the issue closure is overridden).
        await applyVolumeOnDevice(id: id, normalized: clamped)

        let terminal = try await startOp(id: id) { device, cbId in
            guard let volFn = output_airplay.device_volume_set else { return -1 }
            return volFn(device, cbId)
        }
        // Volume completions are non-fatal; record but don't throw on non-stream.
        _ = terminal
    }

    /// Set the C device's `volume` field from a normalized 0...1 value. Engine
    /// thread (or inline in headless mode).
    private func applyVolumeOnDevice(id: OutputID, normalized: Double) async {
        let apply: () -> Void = {
            guard let device = outputs_device_get(id.rawValue) else { return }
            device.pointee.volume = Int32((Double(device.pointee.max_volume) * normalized).rounded())
        }
        if issueOverride != nil { apply() } else { await engineThread.run(apply) }
    }

    /// Feed one buffer of interleaved S16LE PCM (44100/16/2) to all active
    /// sessions. The bytes are copied onto the engine thread and handed to
    /// `output_airplay.write` there (R-B: write MUST run on the engine thread).
    /// Fire-and-forget (the hot path): does not await.
    ///
    /// `pts` is the presentation timestamp for the first sample; pass the
    /// capture clock's timestamp for A/V sync.
    ///
    /// `nonisolated` on purpose: the hot audio path must not hop the actor
    /// executor per frame. It copies the Data and hands the bytes to the
    /// (thread-safe) engine thread, which is where the actual C `airplay_write`
    /// runs (R-B). It reads `started` unsynchronized — a benign race at teardown
    /// (a late frame is simply enqueued onto a stopping loop and dropped).
    public nonisolated func write(pcm: Data, pts: timespec) {
        guard startedFlag.load() else { return }
        // Copy out of the Data (which may be reclaimed) into a C buffer the
        // engine thread owns for the duration of the write.
        let byteCount = pcm.count
        guard byteCount > 0 else { return }
        let cbuf = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        pcm.copyBytes(to: cbuf, count: byteCount)

        let samples = byteCount / (PCMFormat.airplay.channels * PCMFormat.airplay.bitsPerSample / 8)
        let quality = media_quality(
            sample_rate: Int32(PCMFormat.airplay.sampleRate),
            bits_per_sample: Int32(PCMFormat.airplay.bitsPerSample),
            channels: Int32(PCMFormat.airplay.channels),
            bit_rate: 0
        )

        engineThread.enqueue {
            defer { cbuf.deallocate() }
            guard let writeFn = output_airplay.write else { return }

            // Build a stack output_buffer. data[0] is the original (untranscoded)
            // PCM per outputs.h; the session's own ALAC encoder converts it.
            var obuf = output_buffer()
            obuf.pts = pts
            withUnsafeMutablePointer(to: &obuf.data.0) { d0 in
                d0.pointee.quality = quality
                d0.pointee.buffer = cbuf
                d0.pointee.bufsize = byteCount
                d0.pointee.samples = Int32(samples)
                d0.pointee.evbuf = nil
            }
            // data[1].buffer stays NULL: airplay_write loops `for (i; obuf->data[i].buffer; i++)`.
            writeFn(&obuf)
        }
    }

    // MARK: - localOutput placeholder (SPEC §8.1)

    /// The synced local Core Audio endpoint (SPEC §8.1): a local sink that plays
    /// the same audio in lock-step with the AirPlay receivers. NOT implemented in
    /// T-API-1 — this is the API surface + TODO so a later task can fill it in
    /// without redesigning the engine.
    ///
    /// TODO(later task): implement a Core Audio output unit driven off the same
    /// PTP-derived clock the AirPlay sessions use, so local + remote stay in
    /// sync. For now this only toggles a flag; no audio is produced locally.
    public var localOutput: LocalOutputSink {
        LocalOutputSink(isEnabled: localOutputEnabled)
    }

    /// Enable/disable the (not-yet-implemented) local sink. Records intent only.
    public func setLocalOutputEnabled(_ enabled: Bool) {
        localOutputEnabled = enabled
        // TODO(later task): start/stop the Core Audio unit here.
    }

    // MARK: - Shared op driver (arm -> issue -> await completion)

    /// The common "issue a device_* op and await its single deferred completion"
    /// flow, all on the engine thread. `issue` receives the resolved C device +
    /// the armed callback_id and calls the backend, returning N (the promised
    /// callback count). If N <= 0 no completion is promised and we resolve
    /// immediately (no hang). Bridges to async via CompletionRegistry.
    private func startOp(
        id: OutputID,
        issue: @escaping (UnsafeMutablePointer<output_device>, Int32) -> Int32
    ) async throws -> OutputState {
        // In headless test mode the backend call is replaced by issueOverride and
        // the work runs inline (no engine thread / libevent). Everything else —
        // arming the REAL C dispatcher waiter and resolving through the genuine
        // completion path — is identical to production.
        let effectiveIssue = issueOverride ?? issue

        return try await withCheckedThrowingContinuation { cont in
            let body: () -> Void = { [self] in
                guard let device = outputs_device_get(id.rawValue) else {
                    cont.resume(throwing: AirPlayEngineError.unknownOutput(id)); return
                }
                // Arm a waiter and get the callback_id to hand the backend.
                let cbId = outputs_callback_add(device, Self.noopStatusCb)
                guard cbId >= 0 else {
                    cont.resume(throwing: AirPlayEngineError.operationRejected); return
                }
                completions.arm(callbackId: cbId) { state in
                    cont.resume(returning: state)
                }
                let n = effectiveIssue(device, cbId)
                if n <= 0 {
                    // No callback promised -> no completion will arrive. Disarm
                    // and resolve immediately so we never hang (contract N<=0).
                    completions.disarm(callbackId: cbId)
                    outputs_callback_remove(device)
                    cont.resume(returning: .stopped)
                }
                // n > 0: exactly one deferred completion will resume the waiter.
            }
            if issueOverride != nil {
                body() // headless: run inline, no engine thread required
            } else {
                engineThread.enqueue(body)
            }
        }
    }

    /// A no-op C status callback handed to outputs_callback_add. The async result
    /// is driven by the engine completion hook (CompletionRegistry), so the
    /// status cb itself does nothing — but it must be non-NULL for
    /// outputs_callback_add to accept the registration.
    private static let noopStatusCb: output_status_cb = { _, _ in }

    // MARK: - Helpers

    private func requireStarted() throws {
        // Headless test mode (issueOverride set) is treated as "running" so the
        // session ops exercise the real dispatcher without start()/airplay_init.
        guard started || issueOverride != nil else {
            throw AirPlayEngineError.engineNotRunning
        }
    }

    private func strdupC(_ s: String) -> UnsafeMutablePointer<CChar> {
        return s.withCString { strdup($0) }
    }

    // MARK: - Test seam (headless verification, build-notes §6)

    /// Enter headless test mode. Session ops (`addOutput`/`removeOutput`/
    /// `setVolume`) then run inline (no engine thread) and issue no real backend
    /// call; `issue` returns N (default 1). Tests drive the completion by firing
    /// a synthetic `outputs_cb` + `outputs_cb_deferred_run()` through the REAL C
    /// dispatcher, resuming the awaiting continuation via the genuine completion
    /// hook — proving the arm -> dispatch -> resume bridge without hardware.
    func enterHeadlessTestMode(
        issue: @escaping (UnsafeMutablePointer<output_device>, Int32) -> Int32 = { _, _ in 1 }
    ) {
        issueOverride = issue
        completions.install() // wire the C completion hook (start() isn't called)
    }

    /// Register a known output (test seam) so addOutput's guard passes, without
    /// running discovery/init. The device must already be in the C registry.
    func registerKnownOutputForTest(_ id: OutputID, state: OutputState = .stopped) {
        knownOutputs[id] = state
    }

    /// The known state of an output (test/inspection).
    func stateOf(_ id: OutputID) -> OutputState? { knownOutputs[id] }

    /// Test-only: map C descriptor -> keyval feed WITHOUT the engine thread, so a
    /// headless test can assert descriptor->registry mapping. Returns the id the
    /// vendored discovery callback registered the device under, or nil.
    func feedDescriptorForTest(_ descriptor: DeviceDescriptor) -> OutputID? {
        guard let id = descriptor.parsedID else { return nil }
        feedDescriptor(descriptor, appearing: true)
        knownOutputs[id] = .stopped
        return id
    }
}

/// The synced local Core Audio sink placeholder (SPEC §8.1). Surface only.
public struct LocalOutputSink: Sendable {
    /// Whether the app has asked for local output. Always reflects intent;
    /// actual audio is not produced until the later Core Audio task lands.
    public let isEnabled: Bool
    /// Always false in T-API-1 — the sink is a placeholder.
    public var isImplemented: Bool { false }
}
