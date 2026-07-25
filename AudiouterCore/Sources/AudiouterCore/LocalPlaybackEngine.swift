// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// The seam ``NativeBackend`` drives to play a `.currentDevice`-routed app's
/// audio locally on the Mac's built-in speakers as an INDEPENDENT stream with
/// its own volume (Bug T2). It is the local-playback analogue of
/// ``AppRouteMixer`` + ``EngineControlling``: where the mixer sums per-app
/// captures into AirPlay streams and the engine sends them to a receiver, this
/// takes the SAME per-app captured buffers and renders them to the Mac's own
/// hardware output instead.
///
/// Extracted as a protocol (like ``EngineControlling`` / ``ProcessAudioTap``)
/// so the backend's wiring is assertable with a spy that never touches
/// AVAudioEngine or real audio hardware — the concrete ``LocalPlaybackEngine``
/// conforms with a real `AVAudioEngine`.
///
/// ## Why a SEPARATE playback path from the whole-system mix
/// A `.currentDevice` app is captured by its OWN per-process tap
/// (`.mutedWhenTapped`, so it is silenced at its normal output and excluded from
/// the whole-system AirPlay tap — see `NativeBackend.updateAppRoutes`). Without
/// this engine, that capture would go nowhere and the app would be inaudible.
/// This engine gives it back its sound — but as a stream the user can level
/// independently of everything else, which is the whole point of the
/// `.currentDevice` pick.
///
/// Volume is a normalized 0.0…1.0 `Float` here (the `AVAudioPlayerNode.volume`
/// contract). ``NativeBackend`` maps its 0–100 int onto it, mirroring how it
/// maps onto the engine's 0.0…1.0 `setVolume`.
public protocol LocalPlaybackControlling: AnyObject, Sendable {
    /// Register a per-app player for `bundleID` and start rendering it. Called
    /// once the app's per-app capture reaches `.capturing` (so its real
    /// ``TapFormat`` is known). Idempotent: a second call for an already-added
    /// bundle ID just updates its volume (so a device→currentDevice switch,
    /// whose tap is already capturing, is safe to re-add).
    func addApp(bundleID: String, tapFormat: TapFormat, volume: Float) throws
    /// Stop and drop `bundleID`'s player. Idempotent — a no-op for an unknown
    /// bundle ID.
    func removeApp(bundleID: String)
    /// Set `bundleID`'s per-app volume (0.0…1.0). No-op for an unknown bundle ID.
    func setVolume(_ volume: Float, for bundleID: String)
    /// Render one captured buffer on `bundleID`'s player. Called from the tap's
    /// delivery thread; a no-op for a bundle ID with no player (so it is safe to
    /// fan EVERY per-app buffer here — only `.currentDevice` apps have a player).
    func receive(buffer: CapturedBuffer, for bundleID: String)
    /// Start the underlying audio engine. Idempotent. Started lazily when the
    /// first app is added; safe to call again.
    func start() throws
    /// Stop the audio engine and drop every player.
    func stop()

    /// Fired with one app's raw (PRE-volume) captured RMS (0.0…1.0) while
    /// metering is active — the per-app analogue of the whole-system tap's
    /// `onLevel`. ``NativeBackend`` forwards it as ``BackendEvent/appLevel`` for a
    /// `.currentDevice`-routed app. PRE-volume by product decision (see the
    /// concrete engine): the Current-Device app bar shows what was captured, not
    /// the level the player will render it at. A STORED requirement (not
    /// defaultable via an extension), so every conformer declares it — the
    /// fallback/spy conformers just hold the closure.
    var onAppLevel: (@Sendable (_ bundleID: String, _ rms: Float) -> Void)? { get set }

    /// Gate per-app RMS computation/emission on or off (T3/T-GATE) — independent
    /// of `start()`/`stop()`, mirroring
    /// ``NativeCaptureCoordinator/setMeteringActive(_:)``. Default no-op (below)
    /// so a conformer that doesn't meter compiles unchanged; the concrete
    /// ``LocalPlaybackEngine`` provides the real one.
    func setMeteringActive(_ active: Bool)
}

extension LocalPlaybackControlling {
    /// Default no-op (T3) so a conformer that doesn't meter compiles unchanged;
    /// the concrete ``LocalPlaybackEngine`` overrides it with the real gate.
    public func setMeteringActive(_ active: Bool) {}
}

/// Ways local playback setup can fail.
public enum LocalPlaybackError: Error, Equatable, Sendable {
    /// The tap's ``TapFormat`` couldn't be expressed as an `AVAudioFormat`.
    case unsupportedFormat
    /// The `AVAudioEngine` was not running after a start attempt (e.g. a
    /// device-config change stopped it). Thrown instead of calling
    /// `AVAudioPlayerNode.play()` on a stopped engine, which would abort the
    /// process. Caller treats it as a soft failure — local playback for this app
    /// just doesn't start.
    case engineNotRunning
}

#if canImport(AVFoundation)

/// The concrete ``LocalPlaybackControlling``: an `AVAudioEngine` graph with one
/// ``AVAudioPlayerNode`` per `.currentDevice` app, each connected to the engine's
/// main mixer, playing to the Mac's real default output device — with a loop
/// guard that pins to the built-in speakers when following the default would be
/// unsafe.
///
/// ## Follow the default output — UNLESS following it would loop (R13)
/// A "Current Device" pick means "play here, on the Mac itself." The naive read
/// of that is "the built-in speakers," but that's WRONG when the user is
/// listening on Bluetooth headphones (or a USB DAC, or wired output): pinning to
/// built-in then blasts the app out loud from the speakers while the user hears
/// nothing in their headphones (R13). So the engine FOLLOWS
/// `kAudioHardwarePropertyDefaultOutputDevice` via
/// `outputNode.auAudioUnit.setDeviceID` — the device the user actually chose.
///
/// The one exception is the LOOP GUARD (``resolveTargetDeviceID()`` /
/// ``SystemLocalOutputResolver/isLoopRisk(_:)``): if the current default output
/// is itself an AirPlay-class device (the user is streaming the whole system to
/// Sonos) or one of OUR OWN tap aggregate devices, following it would feed the
/// AirPlay/capture path back into playback in a loop. In that single case the
/// engine falls back to the built-in device (``builtInOutputDeviceID()``); if
/// there is no built-in either, it lets `AVAudioEngine` keep its own default
/// (best effort). "AirPlay-class" = transport type
/// `kAudioDeviceTransportTypeAirPlay`; "our own aggregate" = transport type
/// `kAudioDeviceTransportTypeAggregate` whose name carries one of the prefixes
/// this app builds its aggregates with (``Self/ownAggregateNamePrefixes``). This
/// is the same AirPlay-transport classification the rest of the app filters
/// AirPlay devices by, reused here rather than re-derived.
///
/// This is now consistent with the per-app CAPTURE selector rule (the tap
/// follows `kAudioHardwarePropertyDefaultOutputDevice`, house rule / AGENTS.md):
/// capture follows the real output because that's where the app is playing, and
/// playback follows it too because that's where "Current Device" must be heard —
/// the loop guard is what keeps playback from chasing the default into an AirPlay
/// feedback loop.
///
/// ## Re-resolve on default-output changes (BT connect/disconnect)
/// A HAL listener on `kAudioHardwarePropertyDefaultOutputDevice`
/// (``handleDefaultOutputChange()``) re-resolves the target whenever the default
/// output switches (headphones connect/disconnect). It applies the same
/// compare-before-rebuild discipline the capture coordinator uses for its
/// `(deviceID, nominalRate)` key: an unchanged resolved target does ZERO work —
/// no repoint, no graph rebuild — so a spurious/duplicate notification can't
/// storm the graph. Only a genuinely different resolved device repoints the
/// engine (``repointOutputOnGraphQueue(to:)``), once.
///
/// ## Sample-rate conversion is the engine's job, not ours
/// Each player node is connected to the main mixer using that app's real tap
/// format (often 48000 Hz). When that differs from the built-in device's
/// hardware rate, `AVAudioEngine` inserts the resampler itself at the mixer —
/// so buffers are scheduled verbatim in the tap format with no hand-rolled
/// `AVAudioConverter`, and the engine handles the 48000→hardware rate step.
///
/// ## Threading: a state lock AND a graph queue, never crossed (avoids deadlock)
/// Two kinds of mutable state, guarded two different ways, and the invariant is
/// that they never nest:
///   - `stateLock` guards ONLY the in-memory `nodes` dictionary and the
///     `engineRunning` flag / `configuredTargetDevice` / `repointCount` fields.
///     Every critical section is a few lines of pure Swift memory access — it
///     NEVER makes an `AVAudioEngine`/CoreAudio call and NEVER blocks. Held for
///     microseconds.
///   - `graphQueue` (a serial queue) serializes every BLOCKING AVAudioEngine
///     graph mutation (`engine.start/stop`, `attach/connect/detach`,
///     `player.play/stop`, `configureOutput`, touching `mainMixerNode`).
///     Those calls park until the CoreAudio IO/render threads quiesce.
/// No `stateLock` critical section is ever held across a `graphQueue`/engine
/// call. This is deliberate: `receive(buffer:for:)` runs on the real-time IO
/// callback thread and only ever takes `stateLock` (non-blocking `try()`), so a
/// graph mutation waiting for the IO thread can never be waiting on a lock that
/// the IO thread holds. (The earlier single-lock design deadlocked exactly that
/// way: a mutation held the lock while `engine.start()` parked on the IO thread,
/// which was itself blocked taking the same lock in `receive`.)
///
/// `@unchecked Sendable`: mutable state is guarded by `stateLock`; graph
/// mutation is serialized on `graphQueue`. `AVAudioPlayerNode.scheduleBuffer`
/// is itself thread-safe and runs outside both (on the tap delivery thread).
public final class LocalPlaybackEngine: LocalPlaybackControlling, @unchecked Sendable {

    /// One app's playback node + the formats it uses. `sourceFormat` describes the
    /// raw captured tap buffers; `connectionFormat` is the DEINTERLEAVED standard
    /// format the player node is connected to the mixer with (an
    /// `AVAudioPlayerNode` output bus rejects interleaved formats — see
    /// `addApp`). `converter` bridges the two when they differ (nil = identical,
    /// schedule verbatim).
    private final class AppNode {
        let player: AVAudioPlayerNode
        let sourceFormat: AVAudioFormat
        let connectionFormat: AVAudioFormat
        let converter: AVAudioConverter?
        init(player: AVAudioPlayerNode,
             sourceFormat: AVAudioFormat,
             connectionFormat: AVAudioFormat,
             converter: AVAudioConverter?) {
            self.player = player
            self.sourceFormat = sourceFormat
            self.connectionFormat = connectionFormat
            self.converter = converter
        }
    }

    private let engine = AVAudioEngine()
    /// Guards ONLY `nodes`/`engineRunning`/`configuredTargetDevice`/`repointCount`
    /// — pure in-memory state. NEVER held across an AVAudioEngine/CoreAudio call
    /// (see the class note); every critical section is a few lines and never blocks.
    private let stateLock = NSLock()
    /// Serializes every blocking AVAudioEngine graph mutation off the state lock.
    private let graphQueue = DispatchQueue(label: "com.airplaycontroller.localplayback.graph")
    private var nodes: [String: AppNode] = [:]
    private var engineRunning = false
    /// The device id the engine's output is currently pinned to (or `nil` when no
    /// pin has been applied / it fell through to `AVAudioEngine`'s own default).
    /// This is the **compare-before-rebuild key** for the default-output listener
    /// (``handleDefaultOutputChange()``): a re-resolution that lands the SAME id
    /// does zero graph work, mirroring the capture coordinator's
    /// `(deviceID, nominalRate)` loop-breaker. Guarded by `stateLock`, exactly
    /// like `nodes`/`engineRunning`.
    private var configuredTargetDevice: UInt32?
    /// Count of repoints actually performed (target genuinely changed). Guarded by
    /// `stateLock`; read by tests via ``test_repointCount`` to assert
    /// compare-before-rebuild (one repoint on a real change, zero on an unchanged
    /// target).
    private var repointCount = 0
    /// Resolves + classifies the target output device (follow-with-guard). Injected
    /// so the decision is testable without real Core Audio; production uses
    /// ``SystemLocalOutputResolver``.
    private let outputResolver: LocalOutputResolving
    /// Whether per-app RMS metering should be computed and forwarded via
    /// ``onAppLevel`` (T10 — the Current-Device app-bar meter). Guarded by
    /// `stateLock`, exactly like `nodes`/`engineRunning`/`configuredTargetDevice` —
    /// NO new lock is introduced for metering. `false` until
    /// ``setMeteringActive(_:)`` first flips it on (mirrors
    /// `NativeCaptureCoordinator.meteringActive`: the popover isn't necessarily
    /// visible yet when an app's local player is first added).
    private var meteringActive = false
    /// Token for the `AVAudioEngineConfigurationChange` observer (removed in deinit).
    private var configChangeObserver: NSObjectProtocol?
    /// Serial queue the `kAudioHardwarePropertyDefaultOutputDevice` listener block
    /// fires on (off the HAL's own thread), mirroring
    /// ``NativeCaptureCoordinator``'s `listenerQueue`.
    private let listenerQueue = DispatchQueue(label: "com.airplaycontroller.localplayback.listener")
    /// The default-output-change listener block (removed in deinit). Non-nil only
    /// when the real HAL listener is installed (the production init) — the
    /// injected-resolver test init drives ``handleDefaultOutputChange()`` directly
    /// and installs no HAL listener.
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?

    /// Fired synchronously from ``receive(buffer:for:)`` with one app's raw
    /// captured RMS level (0.0...1.0), while metering is active. PRE-VOLUME by
    /// product decision: computed on the tap's raw captured buffer, never scaled
    /// by `AVAudioPlayerNode.volume` — the Current-Device app bar shows what was
    /// captured, not what the player will render it at. Called on the tap's
    /// delivery thread (same thread as `receive`); keep the handler cheap.
    public var onAppLevel: (@Sendable (_ bundleID: String, _ rms: Float) -> Void)?

    /// Production: follows the real default output (with the loop guard) via
    /// ``SystemLocalOutputResolver`` and installs the live HAL default-output
    /// listener.
    public convenience init() {
        self.init(outputResolver: SystemLocalOutputResolver(), installDefaultOutputListener: true)
    }

    /// Designated init. Tests inject a fake ``LocalOutputResolving`` and leave the
    /// real HAL listener OFF (`installDefaultOutputListener: false`), driving
    /// ``handleDefaultOutputChange()`` directly — so the follow-with-guard +
    /// compare-before-rebuild logic is assertable without touching Core Audio.
    init(outputResolver: LocalOutputResolving, installDefaultOutputListener installListener: Bool = false) {
        self.outputResolver = outputResolver

        // AVAudioEngine STOPS itself on a configuration change — and one fires
        // whenever the CoreAudio device list changes, which our OWN per-app taps
        // do every time one is created or torn down (their aggregate devices come
        // and go), and also whenever the output device's config changes (e.g. the
        // mic engaging voice-processing mode). Apple's contract is to observe this
        // and restart; without it the engine stops after the first churn and every
        // buffer is silently dropped (the "Current Device plays nothing / dies
        // through mic" symptom). Handle it on `graphQueue` so it serializes against
        // add/remove/start/stop.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.graphQueue.async { self?.handleConfigurationChangeOnGraphQueue() }
        }

        if installListener { installDefaultOutputListener() }
    }

    deinit {
        if let configChangeObserver { NotificationCenter.default.removeObserver(configChangeObserver) }
        removeDefaultOutputListener()
    }

    // MARK: Lifecycle

    public func start() throws {
        try graphQueue.sync { try startEngineOnGraphQueue() }
    }

    /// Start the engine (idempotent). MUST run on `graphQueue`; touches the state
    /// lock only for the brief `engineRunning` reads/writes, never across the
    /// blocking `engine.start()`. `engineRunning` is set from the engine's OWN
    /// `isRunning` after the call — pinning the output device (`setDeviceID`) can
    /// fire an async `AVAudioEngineConfigurationChange` that stops the engine
    /// right back, so trusting a bare "start() didn't throw" would leave a stale
    /// `true` and let `play()` hit a stopped engine (an uncatchable abort).
    private func startEngineOnGraphQueue() throws {
        guard !(stateLock.withLock { engineRunning }) else { return }
        configureOutput()
        // Touch the main mixer so it (and its main-mixer→output connection) is
        // instantiated before start; starting with no player inputs is silent
        // and correct — players attach/connect afterward while it runs.
        _ = engine.mainMixerNode
        engine.prepare()
        do {
            try engine.start()
        } catch {
            AudioDiag.log("LPE.start FAILED: \(error)")
            throw error
        }
        stateLock.withLock { engineRunning = engine.isRunning }
        AudioDiag.log("LPE.start done isRunning=\(engine.isRunning) target=\(String(describing: stateLock.withLock { configuredTargetDevice }))")
    }

    /// Recover from an `AVAudioEngineConfigurationChange` (the engine has already
    /// stopped itself). MUST run on `graphQueue`. This is the fix for the "dies
    /// through mic" bug: a config change fires whenever the output device's
    /// configuration changes — classically the mic engaging voice-processing mode,
    /// or the default output switching to BT — and `AVAudioEngine` stops itself,
    /// after which every captured buffer is silently dropped unless we rebuild.
    ///
    /// A config change can COINCIDE with the default output changing, so we first
    /// re-resolve + re-apply the follow-with-guard target device
    /// (``configureOutput()``) and only then rebuild the render graph. A bare
    /// `engine.start()` retry does NOT reliably bring the engine back — the render
    /// graph's connections are invalidated, so `start()` returns without error yet
    /// leaves `isRunning == false` (observed live); ``reestablishGraphOnGraphQueue(_:)``
    /// reconnects every player before restarting.
    private func handleConfigurationChangeOnGraphQueue() {
        let snapshot = stateLock.withLock { nodes }
        guard !snapshot.isEmpty else {
            stateLock.withLock { engineRunning = false }
            return
        }
        AudioDiag.log("LPE.configChange FIRED — engine stopped; re-resolving output + reconnecting \(snapshot.count) player(s)")
        stateLock.withLock { engineRunning = false }
        // Re-resolve + re-apply the target device (the config change may be a
        // default-output switch); updates `configuredTargetDevice` too.
        configureOutput()
        reestablishGraphOnGraphQueue(snapshot)
    }

    /// Reconnect every player to the mixer, restart the engine, and re-`play()`
    /// each player — the shared recovery both the config-change handler and a
    /// device repoint use. MUST run on `graphQueue`. Assumes the caller has already
    /// set `engineRunning = false` (or that the engine is currently stopped).
    private func reestablishGraphOnGraphQueue(_ snapshot: [String: AppNode]) {
        guard !snapshot.isEmpty else {
            stateLock.withLock { engineRunning = false }
            return
        }
        // Re-establish each player→mixer connection (a config change / device
        // switch resets them). Each `connect` is wrapped: a raised NSException
        // (uncatchable by plain Swift `try`/`catch`) would otherwise abort the
        // whole process. Bail on the FIRST failure rather than connecting the rest
        // — `engineRunning` stays `false` and we never reach `engine.start()`/
        // `play()` below, so the partially-reconnected graph is simply never
        // driven; no buffer is scheduled against it (see `receive`'s
        // `engineRunning` gate).
        for (_, node) in snapshot {
            do {
                try catchingObjCException {
                    engine.connect(node.player, to: engine.mainMixerNode, format: node.connectionFormat)
                }
            } catch {
                AudioDiag.log("LPE.reestablish reconnect FAILED: \(error)")
                stateLock.withLock { engineRunning = false }
                return
            }
        }
        _ = engine.mainMixerNode
        engine.prepare()
        do {
            try engine.start()
        } catch {
            AudioDiag.log("LPE.reestablish restart FAILED: \(error)")
            stateLock.withLock { engineRunning = false }
            return
        }
        let running = engine.isRunning
        stateLock.withLock { engineRunning = running }
        guard running else {
            AudioDiag.log("LPE.reestablish restart: engine still not running")
            return
        }
        // Re-play each player (a stopped engine stops its player nodes). Wrapped
        // for the same reason as the reconnect loop above: `play()` raises an
        // NSException (not a Swift error) if the engine turns out not to be
        // running despite `isRunning` having just reported `true` — the same
        // start/stop race the doc comment on `startEngineOnGraphQueue` describes.
        // On a raised exception, flip `engineRunning` back to `false` (the same
        // "leave it false, don't trust an optimistic true" idiom used everywhere
        // else in this class) and bail before playing the rest, rather than leave
        // a mix of playing/non-playing nodes against a since-invalidated graph.
        for (_, node) in snapshot {
            do {
                try catchingObjCException { node.player.play() }
            } catch {
                AudioDiag.log("LPE.reestablish replay FAILED: \(error)")
                stateLock.withLock { engineRunning = false }
                return
            }
        }
        AudioDiag.log("LPE.reestablish recovered — engine running, \(snapshot.count) player(s) replaying")
    }

    public func stop() {
        graphQueue.sync {
            // Snapshot + clear the dict under the state lock, then do the blocking
            // player.stop()/detach outside it.
            let players = stateLock.withLock { () -> [AVAudioPlayerNode] in
                let players = nodes.values.map { $0.player }
                nodes.removeAll()
                return players
            }
            for player in players {
                player.stop()
                engine.detach(player)
            }
            if stateLock.withLock({ engineRunning }) {
                engine.stop()
                stateLock.withLock { engineRunning = false }
            }
        }
    }

    /// Gate per-app RMS computation/emission on or off (T10), mirroring
    /// ``NativeCaptureCoordinator/setMeteringActive(_:)`` for the whole-system
    /// meter. Safe to call from any thread: `meteringActive` is guarded by the
    /// same `stateLock` as `engineRunning`/`configuredTargetDevice` — a brief,
    /// non-blocking write, never a new lock on the RT `receive(buffer:for:)` path.
    public func setMeteringActive(_ active: Bool) {
        stateLock.withLock { meteringActive = active }
    }

    // MARK: Per-app players

    public func addApp(bundleID: String, tapFormat: TapFormat, volume: Float) throws {
        // The whole add sequence is serialized on `graphQueue`, so concurrent
        // add/remove calls can't race the "already present?" / "first app starts
        // the engine" decisions; the state lock is taken only for the brief
        // `nodes` reads/writes within it.
        try graphQueue.sync {
            // Idempotent: a device→currentDevice switch re-adds an app whose tap
            // is already capturing. Just re-level it rather than double-attach a
            // node. (volume is safe to set off the graph queue.)
            if let existing = stateLock.withLock({ nodes[bundleID] }) {
                existing.player.volume = Self.clamp(volume)
                return
            }

            guard let sourceFormat = Self.avFormat(from: tapFormat) else {
                throw LocalPlaybackError.unsupportedFormat
            }
            // The player→mixer connection MUST be a DEINTERLEAVED standard format:
            // an `AVAudioPlayerNode` output bus rejects an interleaved format with
            // a hard, uncatchable Core Audio exception (-10868), which is exactly
            // what crashed the whole app when a per-app tap reported interleaved
            // PCM. `standardFormatWithSampleRate:channels:` is deinterleaved
            // Float32 with a canonical layout — the format the engine is
            // guaranteed to accept for a player/mixer link (taps are always a
            // stereo mixdown, so channel count is 1–2 here, always layout-valid).
            guard let connectionFormat = AVAudioFormat(
                standardFormatWithSampleRate: sourceFormat.sampleRate,
                channels: sourceFormat.channelCount) else {
                throw LocalPlaybackError.unsupportedFormat
            }
            // Bridge raw tap buffers → the connection format only when they differ
            // (e.g. interleaved, or Int16). Same-rate, so this is a pure layout/
            // sample-type conversion with 1:1 frame counts.
            let converter = sourceFormat == connectionFormat
                ? nil
                : AVAudioConverter(from: sourceFormat, to: connectionFormat)

            AudioDiag.log("LPE.addApp bundle=\(bundleID) source=\(sourceFormat.sampleRate)/\(sourceFormat.channelCount)ch il=\(sourceFormat.isInterleaved) conn=\(connectionFormat.sampleRate) needsConv=\(converter != nil)")

            // Attach + connect the player into the graph BEFORE starting the
            // engine (canonical order): a first app builds the full graph while
            // stopped, then start() brings it up with the mixer input already
            // wired; a later app attaches into the already-running graph (also
            // supported). Doing it in this order avoids the fragile
            // start-empty-then-hot-attach path.
            let player = AVAudioPlayerNode()
            engine.attach(player)
            // `connect` raises an NSException (not a Swift error) on a rejected
            // format pairing — the interleaved-connection-format crash this class's
            // header doc already guards against by construction, plus any other
            // format edge case. Roll back exactly like the `engineNotRunning` guard
            // below does for the same freshly-attached player: detach it and fail
            // soft via the same error case, rather than let the exception abort.
            do {
                try catchingObjCException {
                    engine.connect(player, to: engine.mainMixerNode, format: connectionFormat)
                }
            } catch {
                AudioDiag.log("LPE.addApp bundle=\(bundleID) FAILED: connect raised \(error)")
                engine.detach(player)
                throw LocalPlaybackError.engineNotRunning
            }
            player.volume = Self.clamp(volume)

            try startEngineOnGraphQueue()

            // NEVER call `play()` on a stopped engine — `AVAudioPlayerNode.play`
            // asserts `engine->IsRunning()` and aborts the whole process (an
            // uncatchable ObjC exception) if it isn't. If the engine failed to
            // come up (or a config-change stopped it), roll back this node and
            // fail soft: local playback for this app just doesn't start, the app
            // stays alive, and a later route/capture edit retries.
            guard engine.isRunning else {
                AudioDiag.log("LPE.addApp bundle=\(bundleID) FAILED: engine not running after start")
                engine.detach(player)
                throw LocalPlaybackError.engineNotRunning
            }
            AudioDiag.log("LPE.addApp bundle=\(bundleID) OK: engine running, player playing")
            stateLock.withLock {
                nodes[bundleID] = AppNode(
                    player: player, sourceFormat: sourceFormat,
                    connectionFormat: connectionFormat, converter: converter)
            }
            // `play()` asserts the engine is running and raises an NSException
            // (not a Swift error) if the `isRunning` check above raced a
            // just-landed config change — the exact uncatchable-abort the class
            // doc above warns about. On a raised exception, roll back BOTH
            // mutations this call site made: the just-registered `nodes` entry
            // (undoing the `stateLock.withLock` immediately above, since nothing
            // else has claimed it yet) and the attach/connect from above, then
            // fail soft via the same `engineNotRunning` case/detach used there.
            do {
                try catchingObjCException { player.play() }
            } catch {
                AudioDiag.log("LPE.addApp bundle=\(bundleID) FAILED: play() raised \(error)")
                _ = stateLock.withLock { nodes.removeValue(forKey: bundleID) }
                engine.detach(player)
                throw LocalPlaybackError.engineNotRunning
            }
        }
    }

    public func removeApp(bundleID: String) {
        graphQueue.sync {
            guard let node = stateLock.withLock({ nodes.removeValue(forKey: bundleID) }) else { return }
            node.player.stop()
            engine.detach(node.player)
            // Last app out stops the engine so the built-in output isn't held open.
            let (isEmpty, running) = stateLock.withLock { (nodes.isEmpty, engineRunning) }
            if isEmpty, running {
                engine.stop()
                stateLock.withLock { engineRunning = false }
            }
        }
    }

    public func setVolume(_ volume: Float, for bundleID: String) {
        // Snapshot the player under the state lock, set volume outside it
        // (`AVAudioPlayerNode.volume` is safe off the graph queue).
        let player = stateLock.withLock { nodes[bundleID]?.player }
        player?.volume = Self.clamp(volume)
    }

    public func receive(buffer: CapturedBuffer, for bundleID: String) {
        // Real-time IO thread: take the state lock NON-blockingly and snapshot
        // the node PLUS the metering flag together (T10 rides the same try() —
        // no second lock acquisition per buffer), then work outside it. The
        // state lock is only ever held for microseconds (and never across an
        // engine call), so this try() essentially always succeeds; a momentary
        // miss just drops the buffer. scheduleBuffer/makeBuffer are thread-safe
        // and stay outside the lock.
        let node: AppNode?
        let metering: Bool
        if stateLock.try() {
            defer { stateLock.unlock() }
            node = engineRunning ? nodes[bundleID] : nil
            metering = meteringActive
        } else {
            return
        }
        guard let node else {
            if AudioDiag.isEnabled { Self.tickDrop(bundleID) }
            return
        }
        // Per-app RMS metering (T10, Current-Device app bar): PRE-VOLUME by
        // product decision — raw captured level, computed on `buffer` BEFORE any
        // format conversion and never scaled by `node.player.volume`. A cheap
        // add-on skipped ENTIRELY when metering is inactive or nobody is
        // listening — no allocation, no new lock, no change to scheduling below.
        if metering, let onAppLevel {
            onAppLevel(bundleID, NativeCaptureCoordinator.rmsOfFloat32(buffer))
        }
        // Build the raw buffer in the tap's own (source) format, then bridge to
        // the deinterleaved connection format the player node was linked with.
        guard let src = Self.makeBuffer(buffer, format: node.sourceFormat) else { return }
        let pcm: AVAudioPCMBuffer
        if let converter = node.converter {
            guard let out = AVAudioPCMBuffer(
                pcmFormat: node.connectionFormat, frameCapacity: src.frameLength) else { return }
            do {
                try converter.convert(to: out, from: src)
            } catch {
                return
            }
            pcm = out
        } else {
            pcm = src
        }
        // `scheduleBuffer` raises an NSException (not a Swift error) if the
        // player has been detached out from under this call — a real race, since
        // `receive` runs on the RT tap-delivery thread while `removeApp`/`stop`
        // detach on `graphQueue` under a DIFFERENT lock (see the class's
        // threading note: `stateLock`'s non-blocking `try()` above only
        // guarantees `node` was valid at snapshot time, not still valid now).
        // Rather than attempt any graph mutation from the RT thread — which
        // would risk leaving the graph half-connected against a mutation already
        // in flight on `graphQueue` — mirror the `converter.convert` soft-fail
        // just above: drop this one buffer and return untouched. `nodes`/
        // `engineRunning` are left alone; whichever concurrent `graphQueue` call
        // caused this already owns that cleanup.
        do {
            try catchingObjCException {
                node.player.scheduleBuffer(pcm, completionHandler: nil)
            }
        } catch {
            if AudioDiag.isEnabled {
                AudioDiag.log("LPE.receive bundle=\(bundleID) scheduleBuffer raised \(error)")
                Self.tickDrop(bundleID)
            }
            return
        }
        if AudioDiag.isEnabled { Self.tickScheduled(bundleID) }
    }

    // Diagnostic buffer counters (every 100th buffer logged), temporary.
    private static let diagLock = NSLock()
    private nonisolated(unsafe) static var scheduledCounts: [String: Int] = [:]
    private nonisolated(unsafe) static var dropCounts: [String: Int] = [:]
    private static func tickScheduled(_ bundleID: String) {
        diagLock.lock(); let n = (scheduledCounts[bundleID] ?? 0) + 1; scheduledCounts[bundleID] = n; diagLock.unlock()
        if n % 100 == 1 { AudioDiag.log("LPE.receive bundle=\(bundleID) scheduled#\(n)") }
    }
    private static func tickDrop(_ bundleID: String) {
        diagLock.lock(); let n = (dropCounts[bundleID] ?? 0) + 1; dropCounts[bundleID] = n; diagLock.unlock()
        if n % 100 == 1 { AudioDiag.log("LPE.receive bundle=\(bundleID) DROPPED#\(n) (no player / engine stopped)") }
    }

    // MARK: Format bridging (TapFormat/CapturedBuffer ⟷ AVFoundation)

    /// Express a ``TapFormat`` as an `AVAudioFormat` (the player-node connection
    /// format). Real per-app taps are Float32 non-interleaved; the other cases
    /// are best-effort so an unusual tap still plays.
    static func avFormat(from tap: TapFormat) -> AVAudioFormat? {
        let common: AVAudioCommonFormat
        switch (tap.isFloat, tap.bitsPerSample) {
        case (true, 64): common = .pcmFormatFloat64
        case (true, _):  common = .pcmFormatFloat32
        case (false, 16): common = .pcmFormatInt16
        case (false, 32): common = .pcmFormatInt32
        default:          common = .pcmFormatFloat32
        }
        return AVAudioFormat(
            commonFormat: common,
            sampleRate: Double(max(1, tap.sampleRate)),
            channels: AVAudioChannelCount(max(1, tap.channels)),
            interleaved: tap.isInterleaved)
    }

    /// Build an `AVAudioPCMBuffer` in `format` from a raw ``CapturedBuffer``.
    /// Copies each channel's `Data` into the matching `AudioBufferList` buffer
    /// (planar → one per channel; interleaved → the single buffer) — format
    /// agnostic, so it works for Float32/Int16, planar/interleaved alike.
    static func makeBuffer(_ captured: CapturedBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard captured.frameCount > 0,
              let buf = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(captured.frameCount))
        else { return nil }
        // Set the length FIRST so each buffer's mDataByteSize reflects frameCount.
        buf.frameLength = AVAudioFrameCount(captured.frameCount)
        let abl = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
        let n = min(abl.count, captured.channelData.count)
        for i in 0..<n {
            let dst = abl[i]
            guard let dstPtr = dst.mData else { continue }
            captured.channelData[i].withUnsafeBytes { raw in
                guard let src = raw.baseAddress else { return }
                memcpy(dstPtr, src, min(Int(dst.mDataByteSize), raw.count))
            }
        }
        return buf
    }

    private static func clamp(_ volume: Float) -> Float { min(1, max(0, volume)) }

    // MARK: Output device (follow the default, with the loop guard)

    /// The device the engine's output SHOULD be pinned to right now: the real
    /// system default output (BT headphones, USB DAC, wired, built-in…) UNLESS
    /// that default is a loop risk (AirPlay-class or one of our own tap
    /// aggregates), in which case the built-in device (R13 loop guard). `nil` only
    /// when neither can be resolved, so the caller lets `AVAudioEngine` keep its
    /// own default (best effort). Pure — reads through the injected
    /// ``outputResolver`` and does no graph work — so tests assert the
    /// follow-with-guard decision directly. Internal for that reason.
    func resolveTargetDeviceID() -> UInt32? {
        if let def = outputResolver.defaultOutputDevice(), !outputResolver.isLoopRisk(def) {
            return def
        }
        return outputResolver.builtInOutputDevice()
    }

    /// Resolve the follow-with-guard target and pin the engine's output to it,
    /// recording it as the compare-before-rebuild key. MUST run on `graphQueue`
    /// (called from `startEngineOnGraphQueue` and the config-change handler).
    private func configureOutput() {
        let target = resolveTargetDeviceID()
        applyOutputDevice(target)
        stateLock.withLock { configuredTargetDevice = target }
    }

    /// Pin the engine's output node to `target` (best effort: a failed set leaves
    /// the engine on its own default). MUST run on `graphQueue`.
    private func applyOutputDevice(_ target: UInt32?) {
        #if canImport(AudioToolbox)
        guard let target else {
            AudioDiag.log("LPE.configureOutput: NO target device resolved; using engine default")
            return
        }
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(AudioObjectID(target))
            AudioDiag.log("LPE.configureOutput: pinned output to device \(target)")
        } catch {
            AudioDiag.log("LPE.configureOutput: setDeviceID(\(target)) FAILED: \(error)")
        }
        #endif
    }

    /// React to a `kAudioHardwarePropertyDefaultOutputDevice` change (BT connects/
    /// disconnects, the user picks a different output). Re-resolves the
    /// follow-with-guard target and repoints the engine — but ONLY if the resolved
    /// target actually changed. This is the compare-before-rebuild loop-breaker
    /// (mirrors ``NativeCaptureCoordinator/handleNominalSampleRateChanged(deviceID:rate:)``'s
    /// `(deviceID, nominalRate)` key): an unchanged target — a duplicate/spurious
    /// notification, or a switch between two devices that both resolve to the same
    /// guarded built-in — does ZERO graph work. Internal so tests drive it directly
    /// (no HAL listener needed).
    func handleDefaultOutputChange() {
        let newTarget = resolveTargetDeviceID()
        let (changed, running): (Bool, Bool) = stateLock.withLock {
            let changed = newTarget != configuredTargetDevice
            if changed { configuredTargetDevice = newTarget }
            return (changed, engineRunning)
        }
        guard changed else {
            AudioDiag.log("LPE.defaultOutputChange: target unchanged (\(String(describing: newTarget))) — skipping repoint")
            return
        }
        guard running else {
            // Nothing to repoint while stopped; the key is updated so the next
            // start() applies the fresh target.
            AudioDiag.log("LPE.defaultOutputChange: target -> \(String(describing: newTarget)); engine not running — deferring to next start")
            return
        }
        AudioDiag.log("LPE.defaultOutputChange: target -> \(String(describing: newTarget)) — repointing")
        graphQueue.async { [weak self] in self?.repointOutputOnGraphQueue(to: newTarget) }
    }

    /// Apply a new target device to the RUNNING engine and rebuild the render graph
    /// against it. MUST run on `graphQueue`. Counts the repoint (test
    /// observability), stops the graph (mirroring `AVAudioEngine`'s own behavior on
    /// a device change), applies the new device, then re-uses the same
    /// reconnect/restart/replay recovery the config-change path uses.
    private func repointOutputOnGraphQueue(to target: UInt32?) {
        stateLock.withLock { repointCount += 1 }
        let snapshot = stateLock.withLock { nodes }
        // Stop the graph before switching devices, then re-point + rebuild.
        if stateLock.withLock({ engineRunning }) {
            engine.stop()
            stateLock.withLock { engineRunning = false }
        }
        applyOutputDevice(target)
        guard !snapshot.isEmpty else { return }
        reestablishGraphOnGraphQueue(snapshot)
    }

    // MARK: Default-output HAL listener

    /// Install the live `kAudioHardwarePropertyDefaultOutputDevice` listener that
    /// drives ``handleDefaultOutputChange()``. Production only — the injected
    /// (test) init leaves it off and calls the handler directly.
    private func installDefaultOutputListener() {
        #if canImport(AudioToolbox)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultOutputChange()
        }
        self.defaultOutputListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
        #endif
    }

    private func removeDefaultOutputListener() {
        #if canImport(AudioToolbox)
        guard let block = defaultOutputListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
        defaultOutputListenerBlock = nil
        #endif
    }

    #if canImport(AudioToolbox)
    /// The Mac's built-in OUTPUT device: the first enumerated device with an
    /// output stream whose transport type is `kAudioDeviceTransportTypeBuiltIn`,
    /// or `nil` if none exists (an unusual headless/aggregate-only setup), in
    /// which case the caller falls back to the hardware default.
    static func builtInOutputDeviceID() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return nil }
        var devices = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &devices) == noErr else { return nil }

        for device in devices where hasOutputStreams(device) {
            if transportType(device) == kAudioDeviceTransportTypeBuiltIn { return device }
        }
        return nil
    }

    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func transportType(_ device: AudioObjectID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }

    /// The current system default output device, or `nil`. The device the engine
    /// FOLLOWS unless the loop guard rejects it.
    static func defaultOutputDeviceID() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    /// A device's `kAudioObjectPropertyName`, or `nil` (used to recognize our OWN
    /// aggregate devices by name prefix in the loop guard).
    static func deviceName(_ device: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let cf = name else { return nil }
        return cf as String
    }

    /// Name prefixes the app builds its OWN aggregate devices with, so the loop
    /// guard can recognize one if it were ever the default output. Kept in sync
    /// with the creation sites:
    ///   - `"Tap-\(name)"`        — `NativeCaptureCoordinator` (whole-system tap)
    ///   - `"PerAppTap-\(name)-…"`— `PerAppCaptureCoordinator` (per-app tap)
    ///   - `"SetupProbe-Audiouter"`— `AudioCapturePermissionProbe`
    /// (In practice these are created `kAudioAggregateDeviceIsPrivateKey: true`, so
    /// they never surface as a selectable default — this is belt-and-suspenders.)
    static let ownAggregateNamePrefixes = ["PerAppTap-", "Tap-", "SetupProbe-"]

    /// The loop guard: `true` if `device` is UNSAFE for local playback to follow —
    /// an AirPlay-class device (whole system may be streaming to it) or one of our
    /// own tap aggregate devices. "AirPlay-class" is the same
    /// `kAudioDeviceTransportTypeAirPlay` transport the rest of the app filters
    /// AirPlay outputs by; "our own aggregate" is `kAudioDeviceTransportTypeAggregate`
    /// with a name carrying one of ``ownAggregateNamePrefixes``. A `nil` transport
    /// (unreadable) is treated as NOT a loop risk (fall through to following it),
    /// matching best-effort behavior elsewhere.
    static func isLoopRiskDevice(_ device: AudioObjectID) -> Bool {
        guard let transport = transportType(device) else { return false }
        if transport == kAudioDeviceTransportTypeAirPlay { return true }
        if transport == kAudioDeviceTransportTypeAggregate,
           let name = deviceName(device),
           ownAggregateNamePrefixes.contains(where: { name.hasPrefix($0) }) {
            return true
        }
        return false
    }
    #endif
}

/// Resolves + classifies the local engine's target output device (follow the
/// default, with the loop guard). Extracted behind a protocol so the decision is
/// testable with a fake — the concrete ``LocalPlaybackEngine`` never queries Core
/// Audio for this directly.
protocol LocalOutputResolving: Sendable {
    /// The real system default output device, or `nil`.
    func defaultOutputDevice() -> UInt32?
    /// The Mac's built-in output device (the loop-guard fallback), or `nil`.
    func builtInOutputDevice() -> UInt32?
    /// `true` if `device` is unsafe to follow (AirPlay-class or one of our own
    /// aggregates) — the loop guard.
    func isLoopRisk(_ device: UInt32) -> Bool
}

/// Production ``LocalOutputResolving``: reads the live HAL through
/// ``LocalPlaybackEngine``'s Core Audio helpers.
struct SystemLocalOutputResolver: LocalOutputResolving {
    func defaultOutputDevice() -> UInt32? {
        #if canImport(AudioToolbox)
        return LocalPlaybackEngine.defaultOutputDeviceID()
        #else
        return nil
        #endif
    }
    func builtInOutputDevice() -> UInt32? {
        #if canImport(AudioToolbox)
        return LocalPlaybackEngine.builtInOutputDeviceID()
        #else
        return nil
        #endif
    }
    func isLoopRisk(_ device: UInt32) -> Bool {
        #if canImport(AudioToolbox)
        return LocalPlaybackEngine.isLoopRiskDevice(AudioObjectID(device))
        #else
        return false
        #endif
    }
}

// MARK: - Test hooks

extension LocalPlaybackEngine {
    /// Repoints performed since construction (a repoint runs only when the resolved
    /// target genuinely changed) — asserts the compare-before-rebuild guard.
    var test_repointCount: Int { stateLock.withLock { repointCount } }
    /// The device id the output is currently pinned to (the compare-before-rebuild
    /// key).
    var test_configuredTargetDevice: UInt32? { stateLock.withLock { configuredTargetDevice } }
    /// Block until any in-flight `graphQueue` work (an async repoint) has drained.
    func test_flushGraphQueue() { graphQueue.sync {} }
    /// Drive the `AVAudioEngineConfigurationChange` recovery path directly (the
    /// real notification can't be injected hermetically).
    func test_simulateConfigurationChange() {
        graphQueue.sync { handleConfigurationChangeOnGraphQueue() }
    }
}

#else

/// Fallback for platforms without AVFoundation (none ship this package — the
/// floor is macOS 14 — but this keeps the file compiling anywhere). Every call
/// is an inert no-op.
public final class LocalPlaybackEngine: LocalPlaybackControlling, @unchecked Sendable {
    public init() {}
    public var onAppLevel: (@Sendable (_ bundleID: String, _ rms: Float) -> Void)?
    public func addApp(bundleID: String, tapFormat: TapFormat, volume: Float) throws {}
    public func removeApp(bundleID: String) {}
    public func setVolume(_ volume: Float, for bundleID: String) {}
    public func receive(buffer: CapturedBuffer, for bundleID: String) {}
    public func start() throws {}
    public func stop() {}
    public func setMeteringActive(_ active: Bool) {}
}

#endif
