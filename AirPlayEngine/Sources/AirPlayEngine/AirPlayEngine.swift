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
import os

/// The engine's configuration, applied to the vendored `conffile` shim before
/// `airplay_init` runs. Strings are retained by the engine for its lifetime
/// (the C side does NOT copy them — build-notes §6 item 3).
public struct EngineConfig: Sendable {
    /// Client name advertised to receivers (`library.name`).
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
    /// The sender-side start buffer in milliseconds — OwnTone's
    /// `general.start_buffer_ms`, served to the vendored sender via the
    /// `outputs_buffer_duration_ms_get()` shim. The sender schedules every
    /// captured sample to play `startBufferMs − 250 ms` after its `pts`
    /// (`airplay.c` `master_session_make`/`timestamp_set`: the receiver is told,
    /// via sync packets, to hold exactly that much audio before playout; the
    /// remaining 250 ms is `AIRPLAY_AUDIO_LATENCY_MS`, the receiver-side minimum
    /// advertised as `latencyMin` in SETUP). This is the DOMINANT deterministic
    /// term of click-to-sound latency AND the receiver's entire jitter/multi-room
    /// buffer — lower it for snappier response, raise it for resilience on lossy
    /// networks. Clamped by the shim to 300...5000 ms (values ≤ 250 would make
    /// the vendored sender reject every session). Applied at `start()`, before
    /// `airplay_init`; changing it later has no effect on live sessions.
    /// Default matches OwnTone's 2250 ms. See docs/latency-analysis.md.
    public var startBufferMs: Int

    /// A per-install stable value that seeds the device id / PTP clock-id hash
    /// (`libhash`), so two installs on one LAN with the same `clientName`
    /// advertise distinct ids (first-light backlog #5.1). Callers should pass
    /// something stable across launches but unique per install — e.g. a
    /// persisted random token or the host UUID (`IOPlatformUUID` /
    /// `gethostuuid`) — NOT a value that changes every run, or the AirPlay
    /// device id / PTP clock id will churn on every launch. Defaults to a
    /// fresh random seed generated once per `EngineConfig` value, so simply
    /// not overriding it still avoids collisions between installs as long as
    /// callers don't re-construct the config with a fresh default each launch.
    public var installSeed: UInt64

    public init(
        clientName: String = "AirPlayEngine",
        userAgent: String = "AirPlayEngine/0.1.0",
        bindAddress: String? = nil,
        enableIPv6: Bool = true,
        timingPort: Int = 0,
        controlPort: Int = 0,
        startBufferMs: Int = 2250,
        installSeed: UInt64 = SystemRandomNumberGenerator.freshInstallSeed()
    ) {
        self.clientName = clientName
        self.userAgent = userAgent
        self.bindAddress = bindAddress
        self.enableIPv6 = enableIPv6
        self.timingPort = timingPort
        self.controlPort = controlPort
        self.startBufferMs = startBufferMs
        self.installSeed = installSeed
    }
}

extension SystemRandomNumberGenerator {
    /// Generates a random 64-bit seed for ``EngineConfig/installSeed``. Not
    /// itself persisted — callers that want stability across relaunches
    /// (the common case) should persist a per-install token themselves (e.g.
    /// in `UserDefaults` or Keychain) and pass it in explicitly; this default
    /// only guarantees two *concurrently constructed* engines won't collide.
    public static func freshInstallSeed() -> UInt64 {
        var rng = SystemRandomNumberGenerator()
        return rng.next()
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
    // C2: the engine thread is (re)created per `start()` — a single Thread can't
    // be restarted — and held in a nonisolated, swappable slot the hot `write`
    // path can read without an actor hop. `nil` before the first start / after
    // stop.
    private nonisolated let engineThreadHolder = EngineThreadHolder()
    private let completions = CompletionRegistry()
    private let stateHub = StateStreamHub()

    private var started = false
    // C2: set BEFORE the first suspension point in `start()`, so two concurrent
    // `start()` calls can't both pass `guard !started` and each spin up a thread
    // (the second `Thread.start()` would abort). Cleared when start finishes or
    // fails.
    private var starting = false

    // B5.1: OutputIDs with an op (addOutput/removeOutput/setVolume) currently
    // in flight, plus the FIFO of tasks waiting to run the next op on that id.
    // A second op on an id awaits the first — belt-and-suspenders with
    // NativeBackend's per-output volume serialization AND the C dispatcher's
    // "one pending callback per device" contract: two overlapping ops on one
    // device would otherwise clobber each other's completion waiter (a permanent
    // hang + a false timeout on the other). Coexists with (never deadlocks) the
    // app-layer guard: every op resolves within the bounded op timeout, so a
    // waiter can block at most that long behind an in-flight op on the same id.
    private var opsInFlight: Set<OutputID> = []
    private var opWaiters: [OutputID: [CheckedContinuation<Void, Never>]] = [:]
    // A nonisolated mirror of `started` the hot write path can read without an
    // actor hop. Kept in lock-step with `started`.
    private nonisolated let startedFlag = AtomicBool(false)
    // A nonisolated mirror of `headlessMode` (T2). `write`/`write(streamId:)`
    // are `nonisolated` so they cannot read the actor-isolated `issueOverride`/
    // `headlessMode` directly (the pattern `applyVolumeOnDevice`/`liveDeviceState`
    // use, since those ARE actor-isolated methods) — this atomic is the same
    // cross-isolation trick as `startedFlag`, letting the hot write path decide
    // "run inline" vs "hand off to the engine thread" without an actor hop.
    // Kept in lock-step with `headlessMode`.
    private nonisolated let headlessFlag = AtomicBool(false)

    // Retained C strings handed to conffile (not copied by the C side).
    private var clientNameC: UnsafeMutablePointer<CChar>?
    private var userAgentC: UnsafeMutablePointer<CChar>?
    private var bindAddressC: UnsafeMutablePointer<CChar>?

    /// Outputs the app has added, by id. The vendored registry owns the actual
    /// `output_device`; we keep just the id and last-known state.
    ///
    /// KEPT IN SYNC WITH OUT-OF-BAND TRANSITIONS (first-light hardening #5 fix):
    /// `startOp` completions are not the only writer. A private subscriber
    /// (`stateReconcileTask`) drains this engine's OWN `makeStateStream()` and
    /// folds every reported transition — INCLUDING the out-of-band ones that
    /// arrive after an op's completion resolved (e.g. a receiver dropping RTSP
    /// flips `.connected -> .failed`) — back into this map. Without that, the
    /// idempotency guard in `addOutput`/`removeOutput` would trust a stale
    /// `.connected`/`.stopped` and silently no-op a recovery that must actually
    /// re-issue `device_start`.
    private var knownOutputs: [OutputID: OutputState] = [:]

    /// Drains this engine's own device-state stream to keep `knownOutputs`
    /// reconciled with out-of-band transitions (see `knownOutputs`). Started by
    /// `start()`/`enterHeadlessTestMode`, cancelled by `stop()`.
    private var stateReconcileTask: Task<Void, Never>?

    /// Placeholder for the synced local Core Audio sink (SPEC §8.1). Not
    /// implemented in T-API-1 — see ``localOutput``.
    private var localOutputEnabled = false

    // Write-cadence deficit/overrun tracker (T-ENG-CADENCE-1, first-light
    // backlog #4). Lives off the actor so the hot `write(pcm:pts:)` path (which
    // is `nonisolated` on purpose, see below) can update it without an actor
    // hop. Diagnostic only — never consulted to gate/throttle a write.
    private nonisolated let cadence = WriteCadenceTracker()

    // Env-gated (AIRPLAY_DEBUG_LATENCY=1) pts-freshness probe for the latency
    // budget (docs/latency-analysis.md). Same off-actor placement and
    // diagnostic-only contract as `cadence`; a disabled probe costs one Bool
    // check per write.
    private nonisolated let latencyProbe: WriteLatencyProbe

    // Test seam (headless verification). When set, `issueOverride` replaces the
    // backend device_* call in startOp: it still arms the REAL C dispatcher
    // waiter (outputs_callback_add + CompletionRegistry) and returns N, but does
    // NOT touch hardware. The test then fires a synthetic outputs_cb +
    // outputs_cb_deferred_run to resume the waiter through the genuine
    // completion path (build-notes §6: exercise the dispatcher's synthetic-
    // completion path with no real event loop/hardware). See
    // Tests/.../AirPlayEngineAPITests.swift.
    private var issueOverride: ((UnsafeMutablePointer<output_device>, Int32) -> Int32)?

    // Per-op completion timeout handed to CompletionRegistry.arm. An armed op
    // whose deferred completion never arrives within this window is resolved by
    // THROWING `.opTimedOut` (see CompletionRegistry.defaultOpTimeout) instead of
    // leaking its continuation forever (toggle-spam session 2026-07-17). Injectable
    // so headless tests can drive the timeout path fast; production uses the
    // default.
    private var opTimeout: TimeInterval = CompletionRegistry.defaultOpTimeout

    // True between `enterHeadlessTestMode()` and a subsequent `stop()`. Lets
    // `stop()` run its dispatcher/completion teardown INLINE (no engine thread,
    // which headless mode never starts) so a teardown-with-op-in-flight test can
    // assert the in-flight continuation is resumed (cancelled) — the same
    // cancellation `uninstall()` performs in production.
    private var headlessMode = false

    // MARK: Init

    public init(config: EngineConfig = EngineConfig()) {
        self.config = config
        self.latencyProbe = WriteLatencyProbe(startBufferMs: config.startBufferMs)
        self.currentStartBufferMs = config.startBufferMs
        // The engine thread is created lazily in start() (C2), not here.
    }

    /// The start buffer currently in force (config value until
    /// ``setStartBufferMs(_:)`` changes it). `applyConfigOnEngineThread` reads
    /// this — not `config.startBufferMs` — so a pre-`start()` set isn't
    /// clobbered when `start()` applies the config.
    private var currentStartBufferMs: Int

    /// Change the sender-side start buffer (ms). Takes effect for the NEXT
    /// stream session: the vendored `master_session_make` reads the value when
    /// a session is created and caches the derived sample count, so live
    /// sessions keep their old buffer until torn down and re-established —
    /// that re-establish dance is `NativeBackend.applyStartBuffer`'s job, not
    /// this method's. The shim clamps to its own 300...5000 range. Also updates
    /// the latency probe so its logged "sender lead" tracks the new value.
    public func setStartBufferMs(_ ms: Int) async {
        currentStartBufferMs = ms
        latencyProbe.updateStartBufferMs(ms)
        // Not started yet (or headless): applyConfigOnEngineThread / the inline
        // test path will serve the stored value at start(); nothing to do now.
        guard started || issueOverride != nil else { return }
        let apply: () -> Void = { outputs_set_buffer_duration_ms(UInt64(max(0, ms))) }
        if issueOverride != nil { apply() }
        else if let t = engineThreadHolder.current { try? await t.run(apply) }
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
        // C2: refuse a re-entrant/concurrent start BEFORE any suspension point.
        // Two concurrent start()s both passing `guard !started` would each call
        // Thread.start() — the second aborts the process.
        guard !started, !starting else { return }
        starting = true
        defer { starting = false }

        // C2: a fresh EngineThread per start — a single OS Thread can't be
        // restarted (Thread.start() on an already-started thread aborts). The
        // previous thread (if any) was torn down and released in stop().
        let engineThread = EngineThread()
        guard engineThread.start(), let base = engineThread.base else {
            throw AirPlayEngineError.engineThreadFailed
        }
        engineThreadHolder.set(engineThread)

        // Everything below touches the C cluster -> must run on the engine thread.
        let initResult: Int32 = try await engineThread.run { [self] in
            // 0. App-side crypto init (libgcrypt + libsodium). pair_ap only
            //    CHECKS initialization (is_initialized, pair.c); without this
            //    every pair_setup_new() fails — gated first-light 2026-07-16.
            if engine_crypto_init() != 0 {
                return -102 // crypto init failed
            }

            // 0b. Mask SIGPIPE process-wide (first-light backlog #2) before any
            //     socket is opened, mirroring OwnTone's main() (main.c:718-732).
            //     Without this, a peer closing its end of an RTSP/data socket
            //     mid-write can kill the process with an unhandled signal.
            engine_mask_sigpipe()

            // 0c. Route libevent's own diagnostics into the engine logger
            //     (first-light hardening #5) before the base does any work, so
            //     an event-base/evrtsp failure is visible in Console/stderr
            //     under L_EVENT instead of libevent's default bare-stderr writer.
            engine_logger_wire_libevent()

            // 1. Set evbase_player BEFORE airplay_init (seam-map §8).
            evbase_player = base

            // 2. Wire the deferred dispatcher event to the base, and install the
            //    completion hook that resumes our async waiters.
            if outputs_dispatcher_init() != 0 {
                return -100 // dispatcher wiring failed
            }
            completions.install()
            stateHub.install() // device-state stream hook (T-ENG-STATESTREAM-1)

            // 3. Apply config via conffile setters (strings NOT copied — retained
            //    on `self` for the engine lifetime).
            applyConfigOnEngineThread()

            // 3b. Bind or attach the PTP daemon BEFORE airplay_init — the third
            //     app-side duty inherited from OwnTone's main() (after gcrypt
            //     init and libevent threading): ptpd_find_or_bind() is the ONLY
            //     privileged step (binds UDP 319/320, needs root), while
            //     airplay_init's ptpd_init() merely finds/starts an already-
            //     bound daemon and otherwise logs "PTP daemon unavailable" and
            //     falls back to NTP — which Sonos refuses (SPEC.md §8 0b).
            //     Non-fatal by design, mirroring OwnTone: NTP-only receivers
            //     still work unprivileged. Gated first-light 2026-07-16.
            _ = ptpd_find_or_bind()

            // 4. Start BOTH sender backends. output_airplay.init == airplay_init,
            //    output_raop.init == raop_init. Each calls mdns_browse for its own
            //    service type, so our shims capture airplay_device_cb AND
            //    raop_device_cb — feedDescriptor's .airplay/.raop branches then both
            //    reach a live backend. Omitting raop_init leaves
            //    airplayengine_raop_device_cb NULL, so every RAOP feed silently
            //    no-ops and addOutput fails `unknownOutput` (first-light 2026-07-19).
            guard let airplayInitFn = output_airplay.`init` else { return -101 }
            let airplayRc = airplayInitFn()
            if airplayRc != 0 { return airplayRc }
            guard let raopInitFn = output_raop.`init` else { return -103 }
            return raopInitFn()
        }

        if initResult != 0 {
            // Roll back the thread; nothing is streaming yet.
            try? await engineThread.run { [self] in
                completions.uninstall()
                stateHub.uninstall()
                outputs_dispatcher_deinit()
                outputs_registry_clear()
            }
            engineThread.stop()
            engineThreadHolder.set(nil)
            freeConfigStrings()
            throw initResult == -100 ? AirPlayEngineError.engineThreadFailed
                : AirPlayEngineError.initFailed
        }

        started = true
        startedFlag.store(true)
        startStateReconcile()
    }

    /// Subscribe this engine to its OWN device-state stream and fold every
    /// reported transition back into `knownOutputs`, so the idempotency guards in
    /// `addOutput`/`removeOutput` never trust a value the stream is documented to
    /// make stale (first-light hardening #5 fix). Ordering is safe: for an armed
    /// op the completion resolves FIRST and then the stream yields the same
    /// transition (STATESTREAM contract), so `startOp`'s own `knownOutputs[id] =
    /// terminal` write and this reconcile converge on the same value; the case
    /// this exists for is the OUT-OF-BAND transition with no armed waiter.
    private func startStateReconcile() {
        guard stateReconcileTask == nil else { return }
        let stream = stateHub.makeStream()
        stateReconcileTask = Task { [weak self] in
            for await (id, state) in stream {
                await self?.reconcileKnownOutput(id: id, state: state)
            }
        }
    }

    /// Fold one reported transition into `knownOutputs`. Only tracks ids the
    /// engine already knows (registered via discovery) — an unknown id is a
    /// transition for a device this engine never added, and must not
    /// spuriously create a `knownOutputs` entry that would let `addOutput`
    /// bypass its `unknownOutput` guard.
    private func reconcileKnownOutput(id: OutputID, state: OutputState) {
        guard knownOutputs[id] != nil else { return }
        knownOutputs[id] = state
    }

    /// Stop the engine: tear down all sessions (`airplay_deinit`), unwire the
    /// dispatcher, break the loop, join the thread. Idempotent.
    public func stop() async {
        // Headless test mode never starts the engine thread, but it DOES install
        // the completion/state hooks and can have an op in flight (a waiter armed
        // in `CompletionRegistry`). Tear those down inline so `uninstall()` still
        // cancels the in-flight continuation — the leaked-continuation / hung-quit
        // path from the 2026-07-17 toggle-spam session is exactly this teardown.
        if headlessMode {
            headlessMode = false
            headlessFlag.store(false)
            issueOverride = nil
            startedFlag.store(false)
            stateReconcileTask?.cancel()
            stateReconcileTask = nil
            completions.uninstall()   // resumes (cancels) every in-flight op continuation
            stateHub.uninstall()
            knownOutputs.removeAll()
            return
        }

        guard started else { return }
        started = false
        startedFlag.store(false)
        stateReconcileTask?.cancel()
        stateReconcileTask = nil

        let engineThread = engineThreadHolder.current
        if let engineThread {
            try? await engineThread.run { [self] in
                if let deinitFn = output_airplay.deinit {
                    deinitFn()
                }
                // Symmetric with raop_init() in start() (step 4).
                if let raopDeinitFn = output_raop.deinit {
                    raopDeinitFn()
                }
                // Symmetric with ptpd_find_or_bind() in start(). NULL-safe:
                // airptp_end() guards a never-bound handle.
                ptpd_deinit()
                completions.uninstall()
                stateHub.uninstall()
                outputs_dispatcher_deinit()
                // C2: airplay_deinit frees the sessions but leaves device->session
                // dangling and never empties device_list — clear the registry so a
                // later start() doesn't inherit stale devices / leaked callback
                // slots. Runs on the engine thread AFTER deinit/uninstall, so the
                // (now teardown-safe) empty registry is what any leftover swept
                // startOp body sees.
                outputs_registry_clear()
                evbase_player = nil
            }
            engineThread.stop()
        }
        engineThreadHolder.set(nil)
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
        // Sender-side start buffer (scheduling lead + receiver jitter buffer).
        // Must land before airplay_init: master_session_make caches the derived
        // output_buffer_samples per master session. The shim clamps to 300...5000.
        // `currentStartBufferMs`, not `config.startBufferMs`: a caller may have
        // set a new value before start() (setStartBufferMs).
        outputs_set_buffer_duration_ms(UInt64(max(0, currentStartBufferMs)))
        // Derive libhash from client name + per-install seed (device id / PTP
        // clock-id seed) so two installs advertising the same clientName on
        // one LAN don't collide (first-light backlog #5.1).
        conffile_set_libhash(Self.hashClientName(config.clientName, seed: config.installSeed))
    }

    private func freeConfigStrings() {
        [clientNameC, userAgentC, bindAddressC].forEach { if let p = $0 { free(p) } }
        clientNameC = nil; userAgentC = nil; bindAddressC = nil
    }

    /// A stable 64-bit hash of the client name mixed with a per-install seed
    /// (FNV-1a over `"<seed-hex>:<clientName>"`), used as `libhash`. Two
    /// installs with the same `clientName` but different `seed` produce
    /// different (non-zero) hashes, avoiding the device-id/PTP-clock-id
    /// collision the fixed-FNV-of-name-only scheme had (first-light backlog
    /// #5.1).
    static func hashClientName(_ s: String, seed: UInt64) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in String(seed, radix: 16).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        hash ^= UInt64(UInt8(ascii: ":"))
        hash = hash &* 0x100000001b3
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

        if let t = engineThreadHolder.current {
            try await t.run { [self] in feedDescriptor(descriptor, appearing: true) }
        }
        if knownOutputs[id] == nil { knownOutputs[id] = .stopped }
        return id
    }

    /// Signal that a previously-discovered device has disappeared (the app's
    /// NWBrowser lost it). Matches on the descriptor's `name` (seam-map §4).
    public func removeDiscovery(_ descriptor: DeviceDescriptor) async {
        guard started else { return }
        if let t = engineThreadHolder.current {
            try? await t.run { [self] in feedDescriptor(descriptor, appearing: false) }
        }
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
                    switch descriptor.kind {
                    case .raop:
                        _ = airplayengine_feed_raop_device(name, host, family, addr, port, kv)
                    case .airplay:
                        _ = airplayengine_feed_device(name, host, family, addr, port, kv)
                    }
                }
            }
        }
    }

    // MARK: - Device-state stream (T-ENG-STATESTREAM-1)

    /// An async stream of device-state transitions, one element per state change
    /// the vendored sender reports for any registered output — INCLUDING the
    /// out-of-band transitions that arrive after an op's completion has already
    /// resolved (e.g. a receiver dropping its RTSP connection flips a `.connected`
    /// output to `.failed`; `addOutput` has long since returned, so the completion
    /// bridge can't see it). No polling: each transition is pushed the moment the
    /// dispatcher drains it on the engine thread.
    ///
    /// Each call returns an independent stream; finishing/cancelling one does not
    /// affect the others. This mirrors `OutputBackend.makeEventStream()` on the
    /// app side — a `NativeBackend` subscribes once and turns each
    /// `(OutputID, OutputState)` into a `deviceUpdated` event.
    ///
    /// Ordering vs. the completion bridge: for an armed op, the completion (which
    /// resolves `addOutput`/`setVolume`/`removeOutput`) fires FIRST, then this
    /// stream yields the same transition — so a subscriber that awaited
    /// `addOutput` and reads the stream sees a consistent picture.
    ///
    /// `nonisolated` so a subscriber can be wired without an actor hop; the hub is
    /// its own synchronized type.
    public nonisolated func makeStateStream() -> AsyncStream<(OutputID, OutputState)> {
        stateHub.makeStream()
    }

    // MARK: - Session lifecycle

    /// Begin streaming to the output with `id`: arm a completion waiter, call
    /// `output_airplay.device_start`, and await the deferred dispatcher
    /// completion (STREAMING / PASSWORD / FAILED). Maps a non-STREAMING terminal
    /// state to a thrown error.
    ///
    /// This is the primitive a future `NativeBackend.addOutput` builds on.
    ///
    /// Equivalent to `addOutput(id, streamId: 0)` — the legacy single-stream
    /// path, unchanged.
    public func addOutput(_ id: OutputID) async throws {
        try await addOutput(id, streamId: 0)
    }

    /// Begin streaming to `id`, bound to `streamId` (T2, per-app multi-stream
    /// routing). Same op as `addOutput(_:)`, but first writes `streamId` onto
    /// the C `output_device.stream_id` field the vendored `session_make` reads
    /// when it creates this device's session (`session->stream_id =
    /// device->stream_id`, T1) — which is what determines which independent
    /// master session (and therefore which content stream, via
    /// `master_session_make`'s `(stream_id, quality, use_ptp)` cache key) this
    /// device's RTP timeline joins. See `docs/VENDORED-DIFFS.md` Entry 2.
    ///
    /// The stream_id write happens BEFORE `device_start` is issued — it MUST
    /// land before `session_make` runs, same ordering constraint `setVolume`
    /// has for `device->volume`. Devices already streaming/connected take the
    /// existing idempotency no-op path (below) and do NOT get re-bound to a
    /// new `streamId` — the session already exists; moving a live device to a
    /// different stream requires `removeOutput` then `addOutput(_:streamId:)`
    /// again (rebinding a live session is out of scope here; T6's job if
    /// needed).
    public func addOutput(_ id: OutputID, streamId: UInt32) async throws {
        try requireStarted()
        guard knownOutputs[id] != nil else { throw AirPlayEngineError.unknownOutput(id) }

        // Idempotency guard (first-light hardening #5): an output already in a
        // live session is a no-op success — don't re-issue device_start, which
        // would arm a second RTSP SETUP against a receiver that's already
        // streaming (the vendored airplay_device_start assumes a fresh device).
        // A caller that saw addOutput succeed and calls it again (e.g. a
        // setOutputSet converge that re-adds an unchanged device) just gets the
        // already-active result back.
        //
        // CRITICAL (hardening #5 fix): consult the LIVE C device state, not the
        // cached `knownOutputs` value. `knownOutputs` is reconciled from the
        // out-of-band state stream asynchronously, so it can still momentarily
        // read `.connected` after the receiver dropped RTSP and the C session
        // flipped to FAILED (`outputs_cb(-1,…)` updated `device->state`). Reading
        // the C device's own `state` on the engine thread closes that race: a
        // failed/stopped session correctly falls through and re-issues
        // device_start to re-establish the RTSP SETUP.
        let liveState = await liveDeviceState(id)
        switch liveState {
        case .streaming, .connected:
            // Keep the cache honest for callers that inspect it.
            knownOutputs[id] = liveState
            return
        default: break
        }

        // T2: bind BEFORE issuing device_start (session_make reads
        // device->stream_id at session-creation time; see the doc comment above).
        await applyStreamIdOnDevice(id: id, streamId: streamId)

        let terminal = try await startOp(id: id) { device, cbId in
            // Dispatch by the device's backend (output_airplay OR output_raop)
            // so a RAOP-typed device runs raop_device_start, not the AP2 sender.
            return outputs_device_start(device, cbId)
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

        // Idempotency guard (first-light hardening #5): stopping an output that
        // isn't in a session is a no-op success. device_stop on an already-idle
        // device would arm a completion the vendored teardown never fires (no
        // active RTSP session to TEARDOWN), so a naive re-stop could hang; skip
        // it and report the already-stopped state.
        //
        // Mirror addOutput: consult the LIVE C device state so a stale cached
        // `.connected` (out-of-band FAILED not yet reconciled) doesn't wrongly
        // drive a stop against an already-torn-down session, and a stale cached
        // `.stopped` doesn't skip a stop the live session still needs.
        let liveState = await liveDeviceState(id)
        if liveState == .stopped { knownOutputs[id] = .stopped; return }

        let terminal = try await startOp(id: id) { device, cbId in
            // TOCTOU guard: a receiver-side RTSP drop can free the session and
            // NULL device->session (shims/outputs.c outputs_device_session_remove)
            // between the liveState check above and this closure running on the
            // engine thread, while the device is still registered (FAILED, not
            // yet .stopped). The vendored airplay_device_stop dereferences
            // device->session unconditionally (`session->callback_id = ...` at
            // offset 8 of NULL) — mirror the null guard airplay_set_volume_one
            // already has in C (airplay.c:1879) here in the Swift host instead of
            // touching vendored C. N<=0 disarms cleanly (~:843-849) and resolves
            // .stopped.
            guard Self.stopSessionIsLive(device) else { return 0 }
            // CRASH GUARD (T5, EXC_BAD_ACCESS SIGSEGV at airplay.c:4271). The
            // idempotency check above reads device->state, but state and
            // device->session can disagree for a window: when a device
            // disappears mid-flight (e.g. a per-app route is torn down while
            // this removeOutput is in progress) session_cleanup zeroes
            // device->session while device->state may still read
            // STREAMING/CONNECTED. `airplay_device_stop` unconditionally does
            // `session = device->session; session->callback_id = …` — a NULL
            // session there dereferences offset 0x8 and crashes the engine
            // thread. A NULL session means there is nothing left to stop, so
            // short-circuit: returning <= 0 makes startOp resolve the op as
            // `.stopped` via its N<=0 contract (no completion promised), exactly
            // the terminal a completed stop would report. This guard runs on the
            // engine thread — the same thread session_cleanup runs on — so it is
            // atomic with respect to the teardown that nulls the session (a check
            // back in removeOutput, on the actor, could still race). This is
            // deliberately NOT applied to addOutput/device_start: `session_make`
            // CREATES the session, so device->session is legitimately NULL before
            // a start and guarding it there would break every connect.
            guard device.pointee.session != nil else { return 0 }
            return outputs_device_stop(device, cbId)
        }
        knownOutputs[id] = terminal
    }

    /// Test seam for the `removeOutput` TOCTOU guard: true iff the vendored C
    /// device still has a live session pointer. `startOp` swaps in
    /// `issueOverride` in headless test mode, so the guard above never runs
    /// under test unless it's extracted like this — exercise it directly
    /// against a registry device instead.
    static func stopSessionIsLive(_ device: UnsafeMutablePointer<output_device>) -> Bool {
        device.pointee.session != nil
    }

    /// Flush any buffered/in-flight audio for `id` — the primitive a future
    /// pause/seek feature builds on (AirPlay FLUSH: RTSP FLUSH re-anchors the
    /// receiver's RTP position so playback can resume from a new point).
    ///
    /// NO-OP SEAM (first-light hardening #5): pause/seek is explicitly OUT OF
    /// SCOPE for this phase, so this deliberately does NOT call the vendored
    /// `output_airplay.device_flush` yet — it only validates the engine/output
    /// state and returns, giving `NativeBackend` and a later pause/seek task a
    /// stable API surface to target without a redesign. When pause/seek lands,
    /// the body becomes a `startOp` over `output_airplay.device_flush` (which
    /// already exists in the vendored sender, `airplay_device_flush`), mirroring
    /// `removeOutput` — including its `stopSessionIsLive` guard, since
    /// `airplay_device_flush` also dereferences device->session unconditionally
    /// (airplay.c:4187). Throws `unknownOutput` if `id` isn't registered so a
    /// caller can't silently flush a device the engine never saw.
    public func flushOutput(_ id: OutputID) async throws {
        try requireStarted()
        guard knownOutputs[id] != nil else { throw AirPlayEngineError.unknownOutput(id) }
        // Intentionally no device_flush issue: seam only (pause/seek deferred).
    }

    /// Set the volume (0.0...1.0) on `id`. Maps onto AirPlay's volume model and
    /// calls `output_airplay.device_volume_set`. Awaits the completion.
    public func setVolume(_ id: OutputID, _ volume: Double) async throws {
        try requireStarted()
        guard knownOutputs[id] != nil else { throw AirPlayEngineError.unknownOutput(id) }

        let clamped = max(0.0, min(1.0, volume))
        // Set device->volume (a 0...100 PERCENT) BEFORE the op, on the engine
        // thread. The vendored airplay_set_volume_one reads it to build
        // SET_PARAMETER, and airplay_volume_from_pct() maps 0..100 -> -30..0 dB.
        // Kept out of the issue closure so it still runs in headless test mode
        // (where the issue closure is overridden).
        await applyVolumeOnDevice(id: id, normalized: clamped)

        let terminal = try await startOp(id: id) { device, cbId in
            return outputs_device_volume_set(device, cbId)
        }
        // Volume completions are non-fatal; record but don't throw on non-stream.
        _ = terminal
    }

    /// Set the C device's `volume` field from a normalized 0...1 value. Engine
    /// thread (or inline in headless mode).
    ///
    /// The vendored airplay.c volume model treats `device->volume` as a 0...100
    /// PERCENT (see the "Volume in [0 - 100]" contract on airplay_set_volume_one
    /// and airplay_volume_from_pct, which maps 0..100 -> -30..0 dB). Earlier this
    /// scaled by `device->max_volume`, but `struct output_device.max_volume` is a
    /// different quantity (a 0..11 ceiling) that this engine never initializes, so
    /// it was always 0 — pinning every request to volume=0 => -30 dB (the quietest
    /// non-muted level), which reads as "no/inaudible sound" on the receiver.
    /// Map the normalized value straight onto the 0..100 percent the C layer wants.
    /// Sentinel: a negative normalized value (used for AirPlay-1 true mute) is passed
    /// through as -1, which raop_volume_from_pct interprets as out-of-range and maps
    /// to -144 dB (true silence).
    private func applyVolumeOnDevice(id: OutputID, normalized: Double) async {
        let apply: () -> Void = {
            guard let device = outputs_device_get(id.rawValue) else { return }
            // For true mute on AirPlay-1, use sentinel value -1 to trigger -144 dB.
            // Otherwise, map normalized 0.0–1.0 to device volume 0–100.
            device.pointee.volume = Int32(normalized < 0 ? -1 : (normalized * 100.0).rounded())
        }
        if issueOverride != nil { apply() }
        else if let t = engineThreadHolder.current { try? await t.run(apply) }
    }

    /// Set the C device's `stream_id` field (T2, per-app multi-stream routing).
    /// Mirrors `applyVolumeOnDevice`'s dispatch: engine thread in production,
    /// inline in headless test mode. MUST run before `device_start` is issued —
    /// see `addOutput(_:streamId:)`.
    private func applyStreamIdOnDevice(id: OutputID, streamId: UInt32) async {
        let apply: () -> Void = {
            guard let device = outputs_device_get(id.rawValue) else { return }
            device.pointee.stream_id = streamId
        }
        if issueOverride != nil { apply() }
        else if let t = engineThreadHolder.current { try? await t.run(apply) }
    }

    /// The LIVE state of the vendored C `output_device` for `id` — read straight
    /// off `device->state`, which `outputs_cb` keeps current (including the
    /// out-of-band `outputs_cb(-1,…)` FAILED after a receiver drops RTSP). This is
    /// the authoritative source the idempotency guards consult, immune to the
    /// async reconcile lag on `knownOutputs`. Runs on the engine thread (or inline
    /// in headless test mode). Returns the last cached state if the C device has
    /// gone (e.g. deregistered), so a caller still gets a sensible value.
    private func liveDeviceState(_ id: OutputID) async -> OutputState {
        let read: () -> OutputState? = {
            guard let device = outputs_device_get(id.rawValue) else { return nil }
            return OutputState(device.pointee.state)
        }
        let live: OutputState?
        if issueOverride != nil { live = read() }
        else if let t = engineThreadHolder.current { live = (try? await t.run(read)) ?? nil }
        else { live = nil }
        return live ?? knownOutputs[id] ?? .stopped
    }

    /// Feed one buffer of interleaved S16LE PCM (44100/16/2) to all active
    /// sessions on the legacy single stream (`stream_id = 0`). Exactly
    /// `write(pcm: pcm, streamId: 0, pts: pts)` — kept as its own overload so
    /// every pre-T2 caller keeps compiling and behaving identically.
    ///
    /// `pts` is the presentation timestamp for the first sample; pass the
    /// capture clock's timestamp for A/V sync.
    ///
    /// `nonisolated` on purpose: the hot audio path must not hop the actor
    /// executor per frame. See `write(pcm:streamId:pts:)` for the full
    /// R-B/engine-thread contract.
    public nonisolated func write(pcm: Data, pts: timespec) {
        write(pcm: pcm, streamId: 0, pts: pts)
    }

    /// Feed one buffer of interleaved S16LE PCM (44100/16/2) tagged with
    /// `streamId` — the per-app multi-stream routing primitive (T2). Devices
    /// bound to the same `streamId` (`addOutput(_:streamId:)`) share the
    /// master session that carries this content; devices on a different
    /// `streamId` never see it — that guard is `airplay_write`'s
    /// `obuf->data[i].stream_id == ams->stream_id` check (T1,
    /// `docs/VENDORED-DIFFS.md` Entry 2). `streamId = 0` is the legacy single
    /// stream and is exactly what `write(pcm:pts:)` uses.
    ///
    /// Equivalent to `write(streams: [(pcm, streamId)], pts: pts)` — see that
    /// overload for the engine-thread/R-B contract and for feeding several
    /// simultaneous streams phase-aligned in one call (T5's mixer / T6's
    /// backend coordination).
    public nonisolated func write(pcm: Data, streamId: UInt32, pts: timespec) {
        write(streams: [(pcm: pcm, streamId: streamId)], pts: pts)
    }

    /// Feed up to `Self.maxSimultaneousStreams` PCM buffers in ONE call, each
    /// tagged with its own `streamId`, sharing a single `output_buffer`/`pts`
    /// (T2). Prefer this over N separate `write(pcm:streamId:pts:)` calls when
    /// several streams are ready in the same tick — the vendored fan-out
    /// (`airplay_write`) processes one shared `pts` per call, so batching keeps
    /// simultaneous streams phase-aligned instead of letting N independently
    /// enqueued closures race onto the engine thread with drifting timestamps.
    /// This is the primitive a future mixer (T5) and `NativeBackend` router
    /// (T6) build on.
    ///
    /// The bytes are copied and handed to the engine thread, which is where the
    /// actual C `airplay_write` runs (R-B: every C entry point goes through
    /// `EngineThread`, never called raw). Fire-and-forget: does not await.
    /// Entries beyond `Self.maxSimultaneousStreams` and empty buffers are
    /// silently dropped (hot path — no error channel).
    ///
    /// `nonisolated` on purpose: the hot audio path must not hop the actor
    /// executor per frame. It copies each `Data` and hands the bytes to the
    /// (thread-safe) engine thread. Reads `startedFlag`/`headlessFlag`
    /// unsynchronized-vs-actor-state (same benign-race rationale as the
    /// original single-stream `write`): a late frame after teardown is simply
    /// enqueued onto a stopping loop (or, in headless mode, run inline) and
    /// dropped/no-op'd.
    public nonisolated func write(streams: [(pcm: Data, streamId: UInt32)], pts: timespec) {
        guard startedFlag.load() else { return }
        let entries = streams.prefix(Self.maxSimultaneousStreams).filter { !$0.pcm.isEmpty }
        guard !entries.isEmpty else { return }

        // Copy each buffer out of its `Data` (which may be reclaimed) into a C
        // buffer the engine thread owns for the duration of the write.
        struct PreparedEntry {
            let cbuf: UnsafeMutablePointer<UInt8>
            let byteCount: Int
            let samples: Int
            let streamId: UInt32
        }
        let bytesPerSample = PCMFormat.airplay.channels * PCMFormat.airplay.bitsPerSample / 8
        let prepared: [PreparedEntry] = entries.map { entry in
            let byteCount = entry.pcm.count
            let cbuf = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
            entry.pcm.copyBytes(to: cbuf, count: byteCount)
            return PreparedEntry(
                cbuf: cbuf,
                byteCount: byteCount,
                samples: byteCount / bytesPerSample,
                streamId: entry.streamId
            )
        }

        // T-ENG-CADENCE-1: record this write's audio-time contribution against
        // the wall clock BEFORE handing off to the engine thread. Keyed off the
        // FIRST entry — the cadence tracker models one write-rate stream; a
        // future task can split per-stream cadence if simultaneous streams stop
        // sharing a nominal rate. Allocation-free, never gates the write below.
        if let first = prepared.first {
            cadence.record(samples: first.samples, sampleRate: PCMFormat.airplay.sampleRate)
        }
        // Latency budget probe (env-gated, diagnostic only): how stale is the
        // pts the producer stamped, measured on the pts's own CLOCK_MONOTONIC
        // domain? Seconds here would mean upstream capture queuing/aggregation;
        // ~10-30 ms is a healthy tap→convert→write pipeline.
        latencyProbe.record(pts: pts)
        let quality = media_quality(
            sample_rate: Int32(PCMFormat.airplay.sampleRate),
            bits_per_sample: Int32(PCMFormat.airplay.bitsPerSample),
            channels: Int32(PCMFormat.airplay.channels),
            bit_rate: 0
        )

        let body: () -> Void = {
            defer { prepared.forEach { $0.cbuf.deallocate() } }
            // Build a stack output_buffer. data[0] is the original (untranscoded)
            // PCM per outputs.h; each session's own ALAC encoder converts it.
            // The C array backing `data` is a tuple in Swift, but it's laid out
            // contiguously identically to the C array, so pointer arithmetic off
            // `&obuf.data.0` reaches data[1], data[2], etc. — the same trick the
            // single-entry path already relied on (index 0 with an implicit
            // zero-terminator at index 1).
            var obuf = output_buffer()
            obuf.pts = pts
            withUnsafeMutablePointer(to: &obuf.data.0) { base in
                for (i, entry) in prepared.enumerated() {
                    let d = base + i
                    d.pointee.quality = quality
                    d.pointee.buffer = entry.cbuf
                    d.pointee.bufsize = entry.byteCount
                    d.pointee.samples = Int32(entry.samples)
                    d.pointee.evbuf = nil
                    d.pointee.stream_id = entry.streamId
                }
            }
            // The slot right after the last real entry stays zeroed (buffer ==
            // NULL): each backend's write loops `for (i; obuf->data[i].buffer; i++)`.
            // outputs_write broadcasts to BOTH backends; each self-filters its own
            // sessions by stream_id/quality, so RAOP and AP2 rooms stay disjoint.
            outputs_write(&obuf)
        }

        // Headless test mode never starts the engine thread (`enterHeadlessTestMode`
        // doc), so `engineThread.enqueue` would silently no-op (its own `guard let
        // base else { return }`) and no test could observe the C fan-out. Mirror
        // the inline-vs-engine-thread split every other op uses
        // (`applyVolumeOnDevice`/`liveDeviceState`/`startOp`) via the nonisolated
        // `headlessFlag` mirror, since this method is `nonisolated` and can't read
        // the actor-isolated `issueOverride` directly. Production (headlessFlag
        // == false) is byte-for-byte the prior dispatch: always `engineThread.enqueue`.
        if headlessFlag.load() {
            body()
        } else {
            // Untracked: an audio frame carries no continuation, so dropping a
            // late one on teardown is correct (and keeps the hot path free of a
            // per-write pending-table op). `current` is nil after stop() — the
            // `startedFlag` guard above already gates that, this just no-ops.
            engineThreadHolder.current?.enqueue(body, tracked: false)
        }
    }

    /// Max simultaneous `output_data` entries one `write(streams:pts:)` call
    /// can carry. Derived from the shim's fixed `output_buffer.data` array
    /// (`OUTPUTS_MAX_QUALITY_SUBSCRIPTIONS` (5) `+ 2` in `shims/outputs.h`: one
    /// slot for the original untranscoded blob the array was originally sized
    /// for, one always-zero terminator) minus 1 further reserved slot so a
    /// zero terminator (`buffer == NULL`) always remains immediately after the
    /// last real entry — `airplay_write` loops `for (i; obuf->data[i].buffer;
    /// i++)` and never sees a `bufsize`/count, only the NULL sentinel.
    static let maxSimultaneousStreams = 6

    // MARK: - Write-cadence diagnostics (T-ENG-CADENCE-1)

    /// A snapshot of the write-cadence deficit/overrun counters (first-light
    /// backlog #4). `nonisolated` — safe to poll from any thread/task without
    /// an actor hop, same rationale as `write` itself.
    public nonisolated func writeCadenceSnapshot() -> WriteCadenceSnapshot {
        cadence.snapshot()
    }

    /// A snapshot of the env-gated pts-freshness probe (`AIRPLAY_DEBUG_LATENCY=1`,
    /// docs/latency-analysis.md). Zeros with `isEnabled == false` when the probe
    /// is off. `nonisolated` for the same reason as `writeCadenceSnapshot()`.
    public nonisolated func writeLatencySnapshot() -> WriteLatencySnapshot {
        latencyProbe.snapshot()
    }

    /// Test/diagnostic seam: reset the cadence counters (e.g. after a known
    /// gap such as a deliberate pause) without recreating the engine.
    func resetWriteCadence() {
        cadence.reset()
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
        // B5.1: serialize ops per OutputID — a second op on the same id awaits the
        // first, so two overlapping ops can never clobber each other's completion
        // waiter (the C dispatcher's "one pending callback per device" contract).
        await acquireOp(id)
        defer { releaseOp(id) }

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
                // Arm with BOTH a normal-delivery resumer and a cancellation
                // resumer. The registry invokes exactly one of them (both remove
                // the waiter under the same lock), so the continuation resumes
                // exactly once: `state in …returning` on a real completion, or
                // `…throwing .engineNotRunning` if `stop()`/uninstall tears the
                // engine down with this op still in flight (no leaked
                // continuation, no hung quit — toggle-spam session 2026-07-17).
                // Arm with THREE resolvers: normal delivery, teardown cancel, and
                // a bounded timeout. The registry invokes exactly one of them
                // (each removes the waiter under the same lock), so the
                // continuation resumes exactly once:
                //   - `state in …returning`             on a real completion,
                //   - `…throwing .engineNotRunning`     if stop()/uninstall tears
                //     the engine down with this op in flight, or
                //   - `…throwing .opTimedOut`           if the receiver's media/PTP
                //     path stalls mid-op so the promised completion never fires
                //     (toggle-spam session 2026-07-17: 177 leaked continuations
                //     during NORMAL running, which the teardown-only cancel missed).
                // NativeBackend maps the thrown failure onto its normal op-failure
                // / recovery path — a timeout is not special-cased there.
                let armed = completions.arm(
                    callbackId: cbId,
                    timeout: opTimeout,
                    onCancel: { cont.resume(throwing: AirPlayEngineError.engineNotRunning) },
                    onTimeout: { [self] in
                        // B5.2: a timed-out op leaves its C slot armed and the
                        // session carrying this callback_id. Clear the slot (else
                        // 64 leaks exhaust outputs_callback_add) and reset the
                        // session's callback_id so a late completion can't resolve
                        // a reused slot's op. Do this BEFORE resuming the awaiter
                        // (in headless the cleanup runs inline/synchronously, so
                        // the slot is free before the next op can arm).
                        scheduleSlotCleanup(callbackId: cbId, id: id)
                        cont.resume(throwing: AirPlayEngineError.opTimedOut)
                    }
                ) { state in
                    cont.resume(returning: state)
                }
                guard armed else {
                    // B5.3: a waiter was already armed for this id (should be
                    // unreachable given per-id serialization). Release the C slot
                    // we just took and fail this op rather than strand it.
                    outputs_callback_remove(device)
                    cont.resume(throwing: AirPlayEngineError.operationRejected)
                    return
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
            } else if let t = engineThreadHolder.current {
                // B4: if the engine thread can't schedule the body (base torn
                // down), fail fast instead of leaking this continuation.
                if !t.enqueue(body) {
                    cont.resume(throwing: AirPlayEngineError.engineNotRunning)
                }
            } else {
                cont.resume(throwing: AirPlayEngineError.engineNotRunning)
            }
        }
    }

    /// B5.1 op-serialization gate: block until no op is in flight for `id`, then
    /// mark this op in flight. Actor-isolated, so the check-and-mark is atomic.
    private func acquireOp(_ id: OutputID) async {
        while opsInFlight.contains(id) {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                opWaiters[id, default: []].append(cont)
            }
        }
        opsInFlight.insert(id)
    }

    /// Release the in-flight op for `id` and wake every waiter (each re-checks the
    /// gate; the actor serializes them so exactly one proceeds).
    private func releaseOp(_ id: OutputID) {
        opsInFlight.remove(id)
        if let waiters = opWaiters.removeValue(forKey: id) {
            for w in waiters { w.resume() }
        }
    }

    /// B5.2: schedule the C-slot cleanup for a timed-out op onto the engine
    /// thread (or inline in headless mode). `nonisolated` because the timeout
    /// fires off-actor on the CompletionRegistry timer queue. Clears the leaked
    /// callback slot and, if the device still has a live session, resets its
    /// `callback_id` so a late completion can't resolve a reused slot's op.
    private nonisolated func scheduleSlotCleanup(callbackId: Int32, id: OutputID) {
        let cleanup: () -> Void = {
            outputs_callback_clear(callbackId)
            if let device = outputs_device_get(id.rawValue),
               device.pointee.session != nil,
               let cbSet = output_airplay.device_cb_set {
                cbSet(device, -1)
            }
        }
        if headlessFlag.load() {
            cleanup()
        } else {
            engineThreadHolder.current?.enqueue(cleanup, tracked: false)
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
        issue: @escaping (UnsafeMutablePointer<output_device>, Int32) -> Int32 = { _, _ in 1 },
        opTimeout: TimeInterval = CompletionRegistry.defaultOpTimeout
    ) {
        issueOverride = issue
        self.opTimeout = opTimeout
        headlessMode = true
        headlessFlag.store(true)
        completions.install() // wire the C completion hook (start() isn't called)
        stateHub.install()    // wire the C device-state hook (T-ENG-STATESTREAM-1)
        // So the hot `write(pcm:pts:)` path's started-guard passes in headless
        // tests (T-ENG-CADENCE-1) without running the real engine thread/init.
        startedFlag.store(true)
        // Reconcile knownOutputs from the state stream (first-light hardening #5
        // fix) — exercised by the headless idempotency-guard test.
        startStateReconcile()
    }

    /// Register a known output (test seam) so addOutput's guard passes, without
    /// running discovery/init. The device must already be in the C registry.
    func registerKnownOutputForTest(_ id: OutputID, state: OutputState = .stopped) {
        knownOutputs[id] = state
    }

    /// The known state of an output (test/inspection).
    func stateOf(_ id: OutputID) -> OutputState? { knownOutputs[id] }

    /// Test-only: whether the completion registry has a waiter armed for
    /// `callbackId`. A headless test fires its synthetic completion only after
    /// this is true, so it can't deliver into the arm-window before the waiter
    /// exists (which would be dropped and hang/time-out the op).
    func hasArmedWaiterForTest(callbackId: Int32) -> Bool {
        completions.hasWaiter(callbackId: callbackId)
    }

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

/// Fans the C device-state hook (`outputs_engine_state`, shims/outputs.c) out to
/// any number of `AsyncStream<(OutputID, OutputState)>` subscribers — the state
/// half of the dispatcher bridge (T-ENG-STATESTREAM-1).
///
/// This is the state-stream counterpart to `CompletionRegistry`: the C hook is a
/// `@convention(c)` pointer that can't capture Swift state, so it targets one
/// process-wide `shared` hub (one engine per process in practice). The hub fires
/// on the engine thread (that's where the deferred drain runs) and yields into
/// each live continuation. `AsyncStream`'s buffer + continuation are themselves
/// thread-safe; we guard the subscriber table with a lock for the rare
/// subscribe/terminate races off the engine thread.
///
/// NB device-state deliveries are advisory and continuous — a slow/paused
/// consumer must never wedge the engine thread — so streams use an
/// `.unbounded` buffer (state notes are tiny and low-rate; see the C ring bound).
final class StateStreamHub: @unchecked Sendable {

    /// The single active hub the C hook reads. Set by `install()`.
    static private(set) var shared: StateStreamHub?

    private var continuations: [UUID: AsyncStream<(OutputID, OutputState)>.Continuation] = [:]
    private let lock = NSLock()

    /// Install this hub as the process-wide target and wire the C hook. Called on
    /// the engine thread right after the dispatcher is initialised (alongside
    /// `CompletionRegistry.install()`).
    func install() {
        StateStreamHub.shared = self
        outputs_engine_state_set({ deviceId, state, _ in
            StateStreamHub.shared?.deliver(deviceId: deviceId, state: state)
        }, nil)
    }

    /// Tear down the hook and finish every live stream (on stop).
    func uninstall() {
        outputs_engine_state_set(nil, nil)
        lock.lock()
        let live = continuations
        continuations.removeAll()
        lock.unlock()
        for (_, c) in live { c.finish() }
        if StateStreamHub.shared === self { StateStreamHub.shared = nil }
    }

    /// A fresh independent stream of `(OutputID, OutputState)` transitions.
    func makeStream() -> AsyncStream<(OutputID, OutputState)> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let key = UUID()
            lock.lock(); continuations[key] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.continuations[key] = nil; self.lock.unlock()
            }
        }
    }

    /// Called by the C hook on the engine thread for every reported transition
    /// (armed op completions AND spent-id out-of-band reports). Maps the C state
    /// and yields `(OutputID, OutputState)` to each live subscriber.
    private func deliver(deviceId: UInt64, state: output_device_state) {
        let mapped = OutputState(state)
        let id = OutputID(rawValue: deviceId)
        lock.lock(); let targets = Array(continuations.values); lock.unlock()
        for c in targets { c.yield((id, mapped)) }
    }
}

/// Write-cadence deficit/overrun tracker (T-ENG-CADENCE-1, first-light
/// backlog #4). Models OwnTone's `player.c` `pb_write_deficit_max`
/// bookkeeping in the neutral Swift layer (no vendored C touched — the write
/// hot path already runs entirely in Swift/`EngineThread.enqueue` before
/// reaching `output_airplay.write`).
///
/// DESIGN: every `write(pcm:pts:)` call carries a fixed amount of audio time
/// (`samples / sampleRate`). Comparing the wall-clock time actually elapsed
/// between two consecutive writes (`CLOCK_MONOTONIC_RAW`, immune to
/// wall-clock adjustment) against that audio-time delta yields a per-write
/// "gap": positive means the caller took LONGER than the audio it just
/// delivered represents (a deficit — the producer is behind, e.g. capture
/// underfeeding/buffer starvation) and negative means it took LESS time (an
/// overrun — bursty/ahead-of-real-time delivery, e.g. catching up after a
/// stall). Deficit and overrun are accumulated into SEPARATE running totals
/// (never let one cancel the other — the plan explicitly wants both surfaced)
/// while `lastGapSeconds` reports the instantaneous value.
///
/// HOT-PATH CONTRACT: `record` is allocation-free — every field is a fixed-
/// size scalar guarded by an `NSLock` (no arrays/dictionaries/closures
/// created), matching the allocation-free requirement for `write(pcm:pts:)`,
/// which already allocates exactly one C buffer per call and nothing else.
/// `record` NEVER throws, blocks the caller beyond the lock, or influences
/// whether the write proceeds — purely diagnostic bookkeeping.
///
/// LOGGING: crossing a coarse threshold (currently >= 250ms of accumulated
/// deficit or overrun since the last log) emits one `os_log` line via the
/// `.default` level so sustained cadence trouble is visible without spamming
/// a log line per write (which, at ~226 writes/sec for 352-sample frames at
/// 44.1kHz, would be prohibitively noisy).
final class WriteCadenceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.airplayengine", category: "write-cadence")

    private var writeCount: UInt64 = 0
    private var deficitSeconds: Double = 0
    private var overrunSeconds: Double = 0
    private var lastGapSeconds: Double = 0
    private var lastWriteMonotonic: Double?

    /// Deficit/overrun accumulated (independently) since the last threshold
    /// log, so repeated small gaps don't each re-trigger a log line.
    private var deficitSinceLog: Double = 0
    private var overrunSinceLog: Double = 0
    private static let logThresholdSeconds: Double = 0.25

    /// Record one write's audio-time contribution against the wall clock.
    /// Called on every `write(pcm:pts:)` invocation, off the actor, possibly
    /// from a producer thread under load — hence the lock rather than actor
    /// isolation (an actor hop is exactly what the hot path must avoid).
    func record(samples: Int, sampleRate: Int) {
        guard samples > 0, sampleRate > 0 else { return }
        let now = Self.monotonicSeconds()
        let audioSeconds = Double(samples) / Double(sampleRate)

        lock.lock()
        writeCount &+= 1
        defer { lock.unlock() }

        guard let last = lastWriteMonotonic else {
            // First write: nothing to compare against yet.
            lastWriteMonotonic = now
            return
        }
        lastWriteMonotonic = now

        let wallElapsed = now - last
        // gap > 0: wall clock ran ahead of the audio delivered (deficit).
        // gap < 0: audio delivered outran the wall clock (overrun/burst).
        let gap = wallElapsed - audioSeconds
        lastGapSeconds = gap

        if gap > 0 {
            deficitSeconds += gap
            deficitSinceLog += gap
        } else if gap < 0 {
            overrunSeconds += -gap
            overrunSinceLog += -gap
        }

        if deficitSinceLog >= Self.logThresholdSeconds {
            let total = deficitSeconds
            deficitSinceLog = 0
            log.notice("write-cadence deficit: +\(gap, format: .fixed(precision: 4))s gap, cumulative \(total, format: .fixed(precision: 3))s")
        } else if overrunSinceLog >= Self.logThresholdSeconds {
            let total = overrunSeconds
            overrunSinceLog = 0
            log.notice("write-cadence overrun: \(gap, format: .fixed(precision: 4))s gap, cumulative \(total, format: .fixed(precision: 3))s")
        }
    }

    /// A consistent snapshot of the counters.
    func snapshot() -> WriteCadenceSnapshot {
        lock.lock(); defer { lock.unlock() }
        return WriteCadenceSnapshot(
            writeCount: writeCount,
            deficitSeconds: deficitSeconds,
            overrunSeconds: overrunSeconds,
            lastGapSeconds: lastGapSeconds
        )
    }

    /// Reset all counters and forget the last-write timestamp (the next
    /// `record` call starts a fresh baseline instead of comparing against a
    /// stale timestamp).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        writeCount = 0
        deficitSeconds = 0
        overrunSeconds = 0
        lastGapSeconds = 0
        lastWriteMonotonic = nil
        deficitSinceLog = 0
        overrunSinceLog = 0
    }

    /// `CLOCK_MONOTONIC_RAW` in seconds — immune to NTP/wall-clock slew,
    /// matching the intent of comparing REAL elapsed producer time (not the
    /// `pts` the caller claims, which is exactly what a broken producer would
    /// get wrong).
    private static func monotonicSeconds() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }
}

/// A consistent snapshot of ``WriteLatencyProbe`` counters (cumulative since
/// engine start / last reset).
public struct WriteLatencySnapshot: Sendable, Equatable {
    /// Writes observed (0 when the probe is disabled — see `isEnabled`).
    public var writeCount: UInt64
    /// Mean pts→now age across all observed writes, in milliseconds.
    public var averagePtsAgeMs: Double
    /// Smallest observed pts→now age, in milliseconds (0 when no writes yet).
    public var minPtsAgeMs: Double
    /// Largest observed pts→now age, in milliseconds (0 when no writes yet).
    public var maxPtsAgeMs: Double
    /// Whether the probe was enabled (`AIRPLAY_DEBUG_LATENCY=1` or injected).
    public var isEnabled: Bool
}

/// Env-gated pts-freshness probe for the click-to-sound latency budget
/// (docs/latency-analysis.md). Measures, per `write(pcm:pts:)`, how far the
/// producer's `pts` lags "now" on `CLOCK_MONOTONIC` — the SAME clock domain the
/// pts is stamped on (`CoreAudioSystemTap.timespec(fromHostTime:)` rebases mach
/// host time onto CLOCK_MONOTONIC) and the same domain the vendored sync path
/// compares against (`timestamp_set`/`packets_sync_send`). NOT
/// `CLOCK_MONOTONIC_RAW` (the cadence tracker's clock): pts age straddles two
/// timestamps on the pts domain, so it must be measured there.
///
/// WHY: total click-to-sound decomposes as
///   pts age (this probe, expect ~10–30 ms)
///   + sender scheduling lead (startBufferMs − 250, deterministic)
///   + receiver-applied latency (the receiver's own choice, ≥ 250 ms)
/// so with this probe's number and a stopwatch measurement, the
/// receiver-applied share falls out by subtraction — the one term we can't
/// observe from the sender side.
///
/// HOT-PATH CONTRACT: mirrors ``WriteCadenceTracker`` — allocation-free scalar
/// updates under an `NSLock`, never gates the write, and a DISABLED probe
/// (the default: enablement is read once from `AIRPLAY_DEBUG_LATENCY`) costs a
/// single Bool check. Logging is rate-limited to one line per `logInterval`
/// (default 5 s), emitted via os_log AND stderr (gated runs watch a terminal).
final class WriteLatencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.airplayengine", category: "latency")
    /// Guarded by `lock` — mutable so `AirPlayEngine.setStartBufferMs` keeps the
    /// logged "sender lead" honest after a runtime change.
    private var startBufferMs: Int
    private let enabled: Bool
    private let logInterval: Double

    // Cumulative (served by snapshot()).
    private var writeCount: UInt64 = 0
    private var sumAgeMs: Double = 0
    private var minAgeMs: Double = .infinity
    private var maxAgeMs: Double = -.infinity

    // Current log window.
    private var windowCount: UInt64 = 0
    private var windowSumMs: Double = 0
    private var windowStart: Double?

    init(
        startBufferMs: Int,
        enabled: Bool = ProcessInfo.processInfo.environment["AIRPLAY_DEBUG_LATENCY"] == "1",
        logInterval: Double = 5.0
    ) {
        self.startBufferMs = startBufferMs
        self.enabled = enabled
        self.logInterval = logInterval
    }

    /// Track a runtime start-buffer change so the logged sender lead stays
    /// accurate. Thread-safe; cheap enough to call from any context.
    func updateStartBufferMs(_ ms: Int) {
        lock.lock()
        startBufferMs = ms
        lock.unlock()
    }

    /// Record one write's pts against CLOCK_MONOTONIC now. No-op when disabled.
    func record(pts: timespec) {
        guard enabled else { return }
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        let nowSeconds = Double(now.tv_sec) + Double(now.tv_nsec) / 1e9
        let ptsSeconds = Double(pts.tv_sec) + Double(pts.tv_nsec) / 1e9
        let ageMs = (nowSeconds - ptsSeconds) * 1000

        lock.lock()
        defer { lock.unlock() }
        writeCount &+= 1
        sumAgeMs += ageMs
        minAgeMs = Swift.min(minAgeMs, ageMs)
        maxAgeMs = Swift.max(maxAgeMs, ageMs)
        windowCount &+= 1
        windowSumMs += ageMs

        guard let start = windowStart else {
            windowStart = nowSeconds
            return
        }
        let elapsed = nowSeconds - start
        guard elapsed >= logInterval, windowCount > 0 else { return }

        let windowAvg = windowSumMs / Double(windowCount)
        let writesPerSec = Double(windowCount) / elapsed
        let senderLeadMs = Double(startBufferMs - 250)
        let predictedSeconds = (senderLeadMs + windowAvg) / 1000
        let line = String(
            format: "latency probe: pts age avg %.1fms (min %.1f / max %.1f cumulative) | %.0f writes/s | "
                + "sender lead %.0fms (start_buffer %dms − 250) | click-to-sound ≈ %.2fs + receiver-applied (≥0.25s)",
            windowAvg, minAgeMs, maxAgeMs, writesPerSec, senderLeadMs, startBufferMs, predictedSeconds)
        log.notice("\(line, privacy: .public)")
        FileHandle.standardError.write(Data((line + "\n").utf8))

        windowCount = 0
        windowSumMs = 0
        windowStart = nowSeconds
    }

    /// A consistent snapshot of the cumulative counters.
    func snapshot() -> WriteLatencySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return WriteLatencySnapshot(
            writeCount: writeCount,
            averagePtsAgeMs: writeCount > 0 ? sumAgeMs / Double(writeCount) : 0,
            minPtsAgeMs: minAgeMs.isFinite ? minAgeMs : 0,
            maxPtsAgeMs: maxAgeMs.isFinite ? maxAgeMs : 0,
            isEnabled: enabled
        )
    }
}
