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
/// audio locally on the Mac's real default output device as an INDEPENDENT
/// stream with its own volume (Bug T2). It is the local-playback analogue of
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
/// main mixer, playing to the Mac's real default output device (with the one
/// anti-feedback guard below).
///
/// ## Follow the real default output — EXCEPT when it's an AirPlay endpoint
/// A "Current Device" pick means "play here, on the Mac itself." The engine pins
/// its output (`outputNode.auAudioUnit.setDeviceID`) to the Mac's REAL current
/// default output — `kAudioHardwarePropertyDefaultOutputDevice`, the same
/// selector the capture side reads (house rule, AGENTS.md) — so a user who has
/// legitimately set Bluetooth headphones or a USB DAC as their Mac's output
/// hears "Current Device" apps on THAT hardware, not wrongly forced onto the
/// built-in speakers. ``resolveLocalOutputDeviceID()`` performs the resolution;
/// ``shouldFollowRealDefault(transportType:)`` is its pure decision.
///
/// The ONE refusal is the genuine feedback-loop case: if that default output is
/// itself an AirPlay endpoint (`kAudioDeviceTransportTypeAirPlay`), the engine
/// does NOT follow it — it falls back to ``builtInOutputDeviceID()`` (exactly
/// today's behavior in that one case). Sending local playback to an AirPlay
/// default would defeat "play here on the Mac" AND could feed the whole-system
/// AirPlay tap in a loop. Any failed read (no default resolvable, unreadable
/// transport type) falls back to built-in too: uncertainty must never let us
/// follow a possibly-AirPlay default into a loop. If neither a followable
/// default nor a built-in device resolves, the engine keeps whatever hardware
/// default `AVAudioEngine` chose (best effort).
///
/// NB — what an AirPlay *default* can (and can't) mean here: this app NEVER sets
/// the system default output device. It only ever TAPS/captures whatever the
/// user or macOS already chose (its own capture aggregates are
/// `kAudioAggregateDeviceIsPrivateKey`, never selectable as a system output; and
/// grep confirms no `AudioObjectSetPropertyData` on the default-output selector
/// anywhere in the package). So an AirPlay *default* observed here can only be a
/// macOS-native AirPlay pick (System Settings ▸ Sound ▸ choosing an AirPlay
/// receiver as output), which macOS supports entirely outside this app — the
/// guard protects against THAT, never against anything this app itself does to
/// the default device (it does nothing).
///
/// ## Known live-behaviour findings (T5 adversarial review, 2026-07-24) — NOT
/// yet resolved; documented so a live tester and future maintainer expect them.
///   - **One extra reconnect ~300 ms after every output-device switch (new to
///     the follow-real-default change).** `pinResolvedOutputDevice()` runs inside
///     config-change recovery and calls `setDeviceID`, which itself posts an
///     `AVAudioEngineConfigurationChange` (this class asserts that behaviour
///     above) -> a second debounced recovery. It SELF-TERMINATES after two cycles
///     (the compare-before-set skips the redundant re-pin), so the cost is one
///     brief audible tick per switch, not a hang -- the same accepted-glitch class
///     as the ~1 s reconnect on a routing-set change. Termination rests on
///     `resolveLocalOutputDeviceID()` eventually agreeing with the
///     `auAudioUnit.deviceID` readback; there is no iteration cap, so a device
///     that persistently fails to apply yet still perturbs could in principle
///     re-pin at ~3 Hz. Not observed; the live test should confirm whether
///     `setDeviceID` posts a config change on real hardware at all (if it does
///     NOT, this finding is moot AND the compare-before-set guards nothing -- one
///     of the two is true).
///   - **No-built-in fallback fails OPEN to an AirPlay default (PRE-EXISTING,
///     not introduced by this change).** On a Mac with NO built-in output
///     (Studio/Pro/headless) whose default IS a macOS-native AirPlay pick:
///     resolve refuses AirPlay -> `builtInOutputDeviceID()` returns nil -> the pin
///     is skipped -> the engine renders to its own unpinned default, which is that
///     AirPlay device -- the very feedback case the guard exists to prevent. The
///     OLD hard-pin-built-in code had the identical "no built-in -> don't pin ->
///     engine on its default" behaviour, so this is a latent pre-existing gap, not
///     a regression. Correct resolution has a PRODUCT component ("play on this
///     Mac" is ill-defined on a Mac with no built-in speaker) -- deferred to a
///     decision + live confirmation, not fixed blind on this fragile path.
///   - Transport-type alone can't detect a VIRTUAL device bridging to AirPlay
///     (BlackHole/Loopback-style, `kAudioDeviceTransportTypeVirtual`, so followed).
///     Real but niche; won't affect a normal Sonos/HomePod test.
///
/// ## Following stays current via the EXISTING config-change recovery path
/// The initial pin happens once, in ``configureOutputDevice()`` (guarded by
/// `configuredDevice`, from `startEngineOnGraphQueue`). To keep "follow the real
/// default" true OVER TIME — e.g. the user unplugs their Bluetooth headphones
/// mid-playback, or flips the System Settings output — the engine re-resolves
/// and re-pins inside ``handleConfigurationChangeOnGraphQueue()``, deliberately
/// NOT via a new device-change listener. This is the minimal correct hook: a
/// device unplug / default-output switch ALREADY fires an
/// `AVAudioEngineConfigurationChange` on its own (that notification is precisely
/// why the recovery path exists and stops the engine), so re-running the
/// resolution there keeps the pin current with zero parallel live-monitoring
/// infrastructure. ``pinResolvedOutputDevice()`` compares-before-setting (like
/// the capture side's ``TapRebuildDecision`` device guard) so a redundant re-pin
/// to the same device can't itself spin a config-change storm.
///
/// This is distinct from the per-app CAPTURE selector rule only in the AirPlay
/// guard: CAPTURE always follows `kAudioHardwarePropertyDefaultOutputDevice`
/// (house rule) because it must tap wherever the app actually plays; PLAYBACK
/// follows the same selector too, but refuses the one AirPlay case above.
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
///     `engineRunning`/`configuredDevice` bool flags. Every critical section is
///     a few lines of pure Swift memory access — it NEVER makes an
///     `AVAudioEngine`/CoreAudio call and NEVER blocks. Held for microseconds.
///   - `graphQueue` (a serial queue) serializes every BLOCKING AVAudioEngine
///     graph mutation (`engine.start/stop`, `attach/connect/detach`,
///     `player.play/stop`, `configureBuiltInOutput`, touching `mainMixerNode`).
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
    /// Guards ONLY `nodes`/`engineRunning`/`configuredDevice` — pure in-memory
    /// state. NEVER held across an AVAudioEngine/CoreAudio call (see the class
    /// note); every critical section is a few lines and never blocks.
    private let stateLock = NSLock()
    /// Serializes every blocking AVAudioEngine graph mutation off the state lock.
    private let graphQueue = DispatchQueue(label: "com.airplaycontroller.localplayback.graph")
    private var nodes: [String: AppNode] = [:]
    private var engineRunning = false
    private var configuredDevice = false
    /// Whether per-app RMS metering should be computed and forwarded via
    /// ``onAppLevel`` (T10 — the Current-Device app-bar meter). Guarded by
    /// `stateLock`, exactly like `nodes`/`engineRunning`/`configuredDevice` — NO
    /// new lock is introduced for metering. `false` until
    /// ``setMeteringActive(_:)`` first flips it on (mirrors
    /// `NativeCaptureCoordinator.meteringActive`: the popover isn't necessarily
    /// visible yet when an app's local player is first added).
    private var meteringActive = false
    /// Test-only counter: how many times the debounced config-change handler has
    /// actually fired — i.e. how many times `handleConfigurationChangeOnGraphQueue()`
    /// ran — incremented in ``scheduleConfigChangeDebounce()`` right before calling
    /// it. Guarded by `stateLock`, exactly like `meteringActive`: read from the
    /// test's own thread via ``test_configChangeHandlerFireCount``, so (unlike
    /// `configChangeDebounceWorkItem` below) it needs real cross-thread safety, not
    /// just graphQueue confinement. Production code never reads it.
    private var configChangeHandlerFireCount = 0
    /// Token for the `AVAudioEngineConfigurationChange` observer (removed in deinit).
    private var configChangeObserver: NSObjectProtocol?
    /// How long to wait, after the LAST `AVAudioEngineConfigurationChange`
    /// notification in a burst, before actually reconnecting (trailing-edge
    /// debounce — see ``scheduleConfigChangeDebounce()``). Redirect churn
    /// (routing/unrouting several apps in quick succession) creates/destroys a
    /// Core Audio tap+aggregate device PER APP, and each one fires its own
    /// notification; un-debounced, N notifications in a burst would drive N
    /// independent full engine stop/reconnect/restart cycles — wasteful, and each
    /// stop/start is audible-glitch risk during active local playback — when one
    /// at the end would do. 300 ms comfortably exceeds the gap between
    /// notifications within one churn burst, while still recovering a single,
    /// isolated config change promptly.
    private static let configChangeDebounceInterval: TimeInterval = 0.3
    /// Pending trailing-edge debounce work item (see `configChangeDebounceInterval`
    /// above). Cancelled and replaced by every new `AVAudioEngineConfigurationChange`
    /// notification in ``scheduleConfigChangeDebounce()``, so only the LAST
    /// notification in a burst actually fires `handleConfigurationChangeOnGraphQueue()`.
    /// Confined to `graphQueue` like `configuredDevice`: only ever touched from
    /// graphQueue-run code, never the RT `receive` thread, so no `stateLock` is
    /// needed here. Cancelled again in `deinit` so a torn-down engine can't fire a
    /// stale reconnect after being deallocated.
    private var configChangeDebounceWorkItem: DispatchWorkItem?

    /// Test seam: if set, `startEngineOnGraphQueue()` calls this instead of
    /// `engine.start()`. Allows tests to force a start failure without mocking
    /// Core Audio. Production code never sets it.
    public var test_startOverride: (() throws -> Void)?

    /// Fired synchronously from ``receive(buffer:for:)`` with one app's raw
    /// captured RMS level (0.0...1.0), while metering is active. PRE-VOLUME by
    /// product decision: computed on the tap's raw captured buffer, never scaled
    /// by `AVAudioPlayerNode.volume` — the Current-Device app bar shows what was
    /// captured, not what the player will render it at. Called on the tap's
    /// delivery thread (same thread as `receive`); keep the handler cheap.
    public var onAppLevel: (@Sendable (_ bundleID: String, _ rms: Float) -> Void)?

    public init() {
        // AVAudioEngine STOPS itself on a configuration change — and one fires
        // whenever the CoreAudio device list changes, which our OWN per-app taps
        // do every time one is created or torn down (their aggregate devices come
        // and go). Apple's contract is to observe this and restart; without it the
        // engine stops after the first tap churn and every buffer is silently
        // dropped (the exact "Current Device plays nothing" symptom). Handle it on
        // `graphQueue` so it serializes against add/remove/start/stop.
        //
        // Redirect churn (routing/unrouting several apps in quick succession) can
        // fire a BURST of these in a row — each one, un-debounced, would drive its
        // own full stop/reconnect/restart cycle. `scheduleConfigChangeDebounce()`
        // trailing-edge debounces the burst into a single reconnect, timed off the
        // LAST notification, so `handleConfigurationChangeOnGraphQueue()` reacts to
        // the settled device list once instead of N times mid-churn.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.graphQueue.async { self?.scheduleConfigChangeDebounce() }
        }
    }

    deinit {
        if let configChangeObserver { NotificationCenter.default.removeObserver(configChangeObserver) }
        // Cancel any pending trailing-edge debounce so a torn-down engine can't
        // fire a stale reconnect attempt on a deallocated instance. Safe to touch
        // `configChangeDebounceWorkItem` directly here without `graphQueue`: like
        // `configChangeObserver` above, no concurrent access is possible once
        // `deinit` has started.
        configChangeDebounceWorkItem?.cancel()
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
        configureOutputDevice()
        // Touch the main mixer so it (and its main-mixer→output connection) is
        // instantiated before start; starting with no player inputs is silent
        // and correct — players attach/connect afterward while it runs.
        _ = engine.mainMixerNode
        engine.prepare()
        do {
            if let testOverride = test_startOverride {
                try testOverride()
            } else {
                try engine.start()
            }
        } catch {
            AudioDiag.log("LPE.start FAILED: \(error)")
            throw error
        }
        stateLock.withLock { engineRunning = engine.isRunning }
        AudioDiag.log("LPE.start done isRunning=\(engine.isRunning) configuredDevice=\(configuredDevice)")
    }

    /// Trailing-edge debounce for the `AVAudioEngineConfigurationChange` observer
    /// installed in `init`: cancel any pending reconnect and schedule a new one
    /// `configChangeDebounceInterval` out. MUST run on `graphQueue` (matches
    /// `configChangeDebounceWorkItem`'s confinement) — called from the observer's
    /// closure, and from ``test_triggerConfigChangeDebounce()`` for tests that
    /// can't synthesize a real notification (the observer is scoped to `object:
    /// engine`, which is private).
    ///
    /// A burst of N calls within the interval collapses into exactly ONE
    /// `handleConfigurationChangeOnGraphQueue()`, timed off the LAST call — so it
    /// reacts once the device list has actually settled, not on the first blip.
    /// This does NOT weaken the single-notification case: each new call only
    /// pushes the SAME pending fire further out, it never starts a second pending
    /// fire or blocks the first from ever landing, so one isolated notification
    /// still recovers after exactly one interval.
    private func scheduleConfigChangeDebounce() {
        configChangeDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.withLock { self.configChangeHandlerFireCount += 1 }
            self.handleConfigurationChangeOnGraphQueue()
        }
        configChangeDebounceWorkItem = work
        graphQueue.asyncAfter(deadline: .now() + Self.configChangeDebounceInterval, execute: work)
    }

    /// Recover from an `AVAudioEngineConfigurationChange` (the engine has already
    /// stopped itself). MUST run on `graphQueue`. A bare `engine.start()` retry
    /// does NOT reliably bring the engine back after a config change — the render
    /// graph's connections are invalidated, so `start()` returns without error yet
    /// leaves `isRunning == false` (observed live). The reliable recovery is to
    /// RECONNECT every player to the mixer (re-establishing the render chain with a
    /// known-good format) BEFORE restarting, then re-`play()` each player.
    private func handleConfigurationChangeOnGraphQueue() {
        let snapshot = stateLock.withLock { nodes }
        guard !snapshot.isEmpty else {
            stateLock.withLock { engineRunning = false }
            return
        }
        AudioDiag.log("LPE.configChange FIRED — engine stopped; reconnecting \(snapshot.count) player(s)")
        stateLock.withLock { engineRunning = false }

        // Re-establish each player→mixer connection (the config change reset them).
        // Each `connect` is wrapped: a raised NSException (uncatchable by plain
        // Swift `try`/`catch`) would otherwise abort the whole process. Bail on
        // the FIRST failure rather than connecting the rest — `engineRunning` is
        // already `false` (set above) and we never reach `engine.start()`/`play()`
        // below, so the partially-reconnected graph is simply never driven; no
        // buffer is scheduled against it (see `receive`'s `engineRunning` gate).
        for (_, node) in snapshot {
            do {
                try catchingObjCException {
                    engine.connect(node.player, to: engine.mainMixerNode, format: node.connectionFormat)
                }
            } catch {
                AudioDiag.log("LPE.configChange reconnect FAILED: \(error)")
                return
            }
        }
        // Re-resolve + re-pin the output device HERE (not via a separate
        // listener): a config change is ALSO how a default-output switch reaches
        // this engine — unplugging Bluetooth headphones, or flipping the System
        // Settings output, fires one on its own — so this recovery path is where
        // "follow the real default" stays current over time. `pinResolvedOutputDevice`
        // compares-before-setting, so a config change that did NOT move the default
        // re-pins to the same device and no-ops, never spinning a storm. See the
        // class doc's "Following stays current…" section.
        pinResolvedOutputDevice()
        _ = engine.mainMixerNode
        engine.prepare()
        do {
            try engine.start()
        } catch {
            AudioDiag.log("LPE.configChange restart FAILED: \(error)")
            return
        }
        let running = engine.isRunning
        stateLock.withLock { engineRunning = running }
        guard running else {
            AudioDiag.log("LPE.configChange restart: engine still not running")
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
                AudioDiag.log("LPE.configChange replay FAILED: \(error)")
                stateLock.withLock { engineRunning = false }
                return
            }
        }
        AudioDiag.log("LPE.configChange recovered — engine running, \(snapshot.count) player(s) replaying")
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
    /// same `stateLock` as `engineRunning`/`configuredDevice` — a brief,
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

            do {
                try startEngineOnGraphQueue()
            } catch {
                AudioDiag.log("LPE.addApp bundle=\(bundleID) FAILED: engine start raised \(error)")
                engine.detach(player)
                throw error
            }

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

    // MARK: Test helpers

    /// Test helper: return the count of nodes currently attached to the engine.
    /// Used to verify no orphaned nodes are left behind on error paths.
    public var test_attachedNodeCount: Int {
        engine.attachedNodes.count
    }

    /// Test seam: fire the same trailing-edge debounce path the real
    /// `AVAudioEngineConfigurationChange` observer uses
    /// (``scheduleConfigChangeDebounce()``), without needing to synthesize a real
    /// notification — the observer is scoped to `object: engine`, which is
    /// private and unreachable from a test target. Safe to call from any thread;
    /// hops onto `graphQueue` itself, exactly like the real observer's closure
    /// does. Production code never calls it.
    public func test_triggerConfigChangeDebounce() {
        graphQueue.async { [weak self] in self?.scheduleConfigChangeDebounce() }
    }

    /// Test seam: how many times the debounced config-change handler has
    /// actually fired (see `configChangeHandlerFireCount`) — used to prove a
    /// burst of notifications collapses into exactly one call.
    public var test_configChangeHandlerFireCount: Int {
        stateLock.withLock { configChangeHandlerFireCount }
    }

    // MARK: Built-in output device

    /// Pin the engine's output device ONCE per engine lifecycle (guarded by
    /// `configuredDevice`) to the Mac's real default output — unless that default
    /// is an AirPlay endpoint, in which case built-in (see the class doc and
    /// ``resolveLocalOutputDeviceID()``). MUST run on `graphQueue` (called from
    /// `startEngineOnGraphQueue`); `configuredDevice` is touched only there. The
    /// ONGOING follow AFTER this initial pin is handled by
    /// ``handleConfigurationChangeOnGraphQueue()``, not here.
    private func configureOutputDevice() {
        guard !configuredDevice else { return }
        configuredDevice = true
        pinResolvedOutputDevice()
    }

    /// Resolve the correct local output device (``resolveLocalOutputDeviceID()``)
    /// and pin the engine's output node to it — but ONLY if it differs from what's
    /// already pinned. The compare-before-set mirrors the capture side's
    /// compare-before-rebuild guard (``TapRebuildDecision``): re-pinning to the
    /// SAME device during config-change recovery could otherwise fire yet another
    /// `AVAudioEngineConfigurationChange` and spin a rebuild storm. MUST run on
    /// `graphQueue` (both call sites — `configureOutputDevice` and the config-change
    /// recovery handler — are graphQueue-confined). Best effort: on any failure it
    /// logs and leaves the engine's current output untouched (the same soft-fail
    /// contract the old built-in-only pin had).
    private func pinResolvedOutputDevice() {
        #if canImport(AudioToolbox)
        guard let deviceID = Self.resolveLocalOutputDeviceID() else {
            AudioDiag.log("LPE.pinResolvedOutputDevice: NO local output device resolved; using engine default")
            return
        }
        guard engine.outputNode.auAudioUnit.deviceID != deviceID else {
            AudioDiag.log("LPE.pinResolvedOutputDevice: already pinned to \(deviceID); no change")
            return
        }
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
            AudioDiag.log("LPE.pinResolvedOutputDevice: pinned to device \(deviceID)")
        } catch {
            AudioDiag.log("LPE.pinResolvedOutputDevice: setDeviceID(\(deviceID)) FAILED: \(error)")
        }
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

    /// Resolve which device local playback should pin to: the Mac's REAL current
    /// default output (``defaultOutputDeviceID()``) UNLESS its transport type is
    /// AirPlay — the one feedback-loop case ``shouldFollowRealDefault(transportType:)``
    /// refuses — in which case fall back to ``builtInOutputDeviceID()``. Every
    /// failed read also falls back to built-in: if the default can't be resolved,
    /// or its transport type can't be read, we must NOT risk following a
    /// possibly-AirPlay default into a loop, and built-in is the safe local
    /// target. This is the function that replaced ``builtInOutputDeviceID()``'s
    /// former role as the sole output pin (Q2, the Bluetooth/USB fix).
    static func resolveLocalOutputDeviceID() -> AudioObjectID? {
        guard let defaultID = defaultOutputDeviceID() else { return builtInOutputDeviceID() }
        guard let transport = transportType(defaultID),
              shouldFollowRealDefault(transportType: transport) else {
            return builtInOutputDeviceID()
        }
        return defaultID
    }

    /// Pure decision (mirrors ``TapRebuildDecision`` in `NativeCaptureCoordinator`):
    /// given a default output device's transport type, should local playback
    /// FOLLOW it? AirPlay (`kAudioDeviceTransportTypeAirPlay`) is the ONLY transport
    /// refused — the genuine feedback-loop case; every real local transport
    /// (built-in, Bluetooth, USB, Thunderbolt, HDMI, aggregate, virtual, unknown, …)
    /// is followed. Kept pure + `static` — no live Core Audio read — so the
    /// follow/fall-back branch is unit-testable directly, without a real default
    /// device or a real AirPlay endpoint (which cannot be synthesized against live
    /// Core Audio in a test).
    static func shouldFollowRealDefault(transportType: UInt32) -> Bool {
        transportType != kAudioDeviceTransportTypeAirPlay
    }

    /// The Mac's REAL current default output device
    /// (`kAudioHardwarePropertyDefaultOutputDevice` off the system object) — the
    /// exact selector `PerAppCaptureCoordinator.defaultOutputDeviceID()` and
    /// `NativeCaptureCoordinator.defaultOutputDeviceID()` read (house rule,
    /// AGENTS.md), mirrored here in this file's optional-returning style (like
    /// ``builtInOutputDeviceID()`` / ``transportType(_:)``). `nil` if it can't be
    /// read. Deliberately NOT `kAudioHardwarePropertyDefaultSystemOutputDevice`
    /// (the alert-sound device) — the same selector rule the capture side keeps.
    static func defaultOutputDeviceID() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
            deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
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
    #endif
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
