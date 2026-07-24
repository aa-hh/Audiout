import Foundation

/// A transport command the user pressed on a connected speaker's OWN playback
/// controls (or its companion app), surfaced so the app can drive the Mac's
/// media playback in response. Backend-neutral by design — the native backend
/// maps the engine's own command type onto this so the base ``OutputBackend``
/// seam stays free of engine types (only ``NativeBackend`` emits it).
///
/// macOS exposes a single Play/Pause *toggle* media key, so play and pause both
/// arrive as ``playPause``.
public enum RemoteTransportCommand: Sendable, Equatable {
    case playPause
    case next
    case previous
}

/// Something that happened in the backend that the UI should react to.
///
/// The backend is the source of truth; it pushes these and the UI updates. This
/// is the *only* channel — there is no "read the device list and diff it"
/// path, so the mock and the real backend drive the UI through the exact same
/// events.
public enum BackendEvent: Sendable, Equatable {
    /// A device appeared on the network (or the backend started and is
    /// enumerating what's already there).
    case deviceAdded(Device)
    /// A device dropped off the network. It stays in the model as unavailable;
    /// this signals availability, not deletion.
    case deviceRemoved(id: String)
    /// Any field of a device changed — volume, mute, availability, selection,
    /// or `connectionState`. The latter is how the UI learns about the
    /// connection lifecycle (`.off → .connecting → .connected`, drops into
    /// `.reconnecting`/`.failed`) — there is no separate event for it, it's
    /// just another field on the echoed `Device`
    /// (`dev/notes/p1-connection-status-brief.md` §1/§3). Note the
    /// "sticky-failed" rule: a `.failed` device can be echoed here with
    /// `isSelected = false` (the honest-toggle cleanup removed it from the
    /// expected set) while `connectionState` stays `.failed` — that's
    /// intentional, not a stale event.
    case deviceUpdated(Device)
    /// A cheap RMS level sample (0…1) for the per-device level meter
    /// (`NSLevelIndicator`, display-only — SPEC.md §9). Emitted only for
    /// selected, unmuted devices while "playing."
    case level(id: String, rms: Float)
    /// A cheap RMS level sample (0…1) for one routed app's per-app level meter,
    /// keyed by bundle ID instead of device ID — the per-APP analogue of
    /// ``level``, which is device-keyed. Drives the Applications-row meters
    /// (as opposed to `.level`'s device-row meters).
    case appLevel(bundleID: String, rms: Float)
    /// The Mac's system output volume was changed from **outside this app** —
    /// the volume keys, the Sound menu, another app — while the default output
    /// device stayed put. The one event here that isn't about a `Device`.
    ///
    /// It exists to fix a live-session complaint: the volume keys move the
    /// system output, which IS the local "Current Device" row, but while
    /// streaming the capture tap MUTES that output — so the keys diligently
    /// adjusted a device nobody could hear while the AirPlay speakers actually
    /// playing ignored them. `AppDelegate` forwards this to
    /// ``GroupController/mirrorSystemVolumeToMainOut(_:)``, which mirrors it
    /// onto the Main Out master so the keys drive whatever is really playing.
    ///
    /// Why an event rather than the backend calling the routing brain: the
    /// backend owns the system-volume listener but sits BELOW `GroupController`
    /// and reaches it only through ``OutputBackend``. This is already the
    /// backend→UI push channel and `AppDelegate` is already where backend events
    /// meet app-level controllers, so the fact travels the way every other
    /// backend fact does, and no layer is inverted.
    ///
    /// Only ``NativeBackend`` emits it (it's the only backend that owns a
    /// ``SystemVolumeControlling``); `MockBackend`/`OwnToneBackend` never do.
    /// Guarantees a consumer may rely on:
    /// - **External only.** ``SystemOutputVolume`` suppresses echoes of its own
    ///   writes, so this never fires for a volume *we* set — "volume keys" and
    ///   "user dragged our Current Device slider" are already distinguishable
    ///   with no flag of anyone's own.
    /// - **Not a device switch.** A default-output switch (speakers → AirPods)
    ///   also reports a fresh volume, but that's a different device's
    ///   pre-existing level, not a user gesture; it is filtered out upstream and
    ///   never arrives here. Mirroring it would slam every speaker to whatever
    ///   the headphones happened to be set to.
    /// - **A real move.** Never emitted when the volume didn't actually change
    ///   (e.g. only mute did).
    case systemVolumeChanged(volume: Int)
    /// A routed app's process lifecycle changed — it quit (`isRunning == false`)
    /// or relaunched (`isRunning == true`). Only emitted for apps that currently
    /// have an active `.device(id:)` route in the backend's last route table;
    /// non-routed apps' lifecycle events are silently ignored. The UI uses this
    /// to show or clear an offline indicator on the app's row in the Applications
    /// card (T4). Only ``NativeBackend`` emits it; `MockBackend` and
    /// `OwnToneBackend` never do (they have no per-app capture lifecycle).
    case routedAppRunning(bundleID: String, isRunning: Bool)

    /// The live per-app routing map for one destination device changed (T6):
    /// `appNames` are the display names of the apps whose audio is currently
    /// being streamed to `deviceID` through a per-app redirect, derived from the
    /// mixer's live destination-set → device topology. An empty `appNames` means
    /// no app routes to that device any more (the mapping cleared). Fires only
    /// when the mapping for a device actually changes, so a consumer can treat
    /// each event as the new truth for that one device.
    ///
    /// This is purely a UI signal (T9 renders it in `DeviceRowView`'s routing
    /// sublabel, taking precedence over the intent-based label whenever
    /// non-empty) and never a `Device` field — a redirect target is deliberately
    /// NOT `isSelected`/in the Selected Devices set
    /// (`AudiouterCore/AGENTS.md`), so it can't ride the `deviceUpdated`
    /// echo. Only ``NativeBackend`` emits it organically; `OwnToneBackend` never
    /// does (no per-app streaming). `MockBackend` also never emits it on its own,
    /// but exposes `test_emitRoutedApps(deviceID:appNames:)` so offline
    /// demos/tests can exercise the UI without a real per-app-routing backend.
    case routedApps(deviceID: String, appNames: [String])

    /// The user pressed a transport key (play/pause/next/previous) on a connected
    /// **speaker itself** — the AirPlay reverse event channel reported it. Like
    /// ``systemVolumeChanged(volume:)`` this isn't about a `Device`: transport
    /// targets the Mac's single media session, so `AppDelegate` turns it into a
    /// Mac media key and the frontmost player (Music, Spotify, a browser, …)
    /// responds. Only ``NativeBackend`` emits it.
    case remoteTransport(RemoteTransportCommand)

    /// The generalized silence watchdog (Wave 2, R11) flipped the local-playback
    /// fallback. `active: true` means: the capture gate WANTED to stream to at
    /// least one AirPlay device, but none of the desired devices stayed
    /// `.connected` for the fallback window, so the backend un-gated whole-system
    /// capture — the Mac itself is now audible — **without clearing the user's
    /// selection intent**. `active: false` means a desired device reconnected (or
    /// the intent cleared) and the gate re-engaged: audio has moved back to the
    /// real device(s) and the Mac is muted again.
    ///
    /// This is the *only* signal for the "Speakers unreachable — playing on this
    /// Mac" popover banner; it is not a `Device` field because it's a whole-app
    /// condition, not a per-device one (a dead GROUP has zero connected members,
    /// so no single device could carry it). Only ``NativeBackend`` emits it — it's
    /// the only backend with a real capture gate; `MockBackend`/`OwnToneBackend`
    /// never do.
    case localFallbackActive(Bool)
}

/// The seam between the app and wherever audio actually goes.
///
/// `MockBackend` implements this with fabricated devices for offline UI work;
/// the real implementation (`OwnToneBackend`, a stub for now) will implement
/// the *same* protocol on top of the OwnTone JSON API + AirPlay-2 sender. The
/// UI is written once, against this protocol, and never learns which it's
/// talking to.
public protocol OutputBackend: AnyObject {

    /// Current snapshot of every known device (available or not). Handy for the
    /// first paint before any events arrive.
    var devices: [Device] { get }

    /// Begin discovery / connect. Emits `deviceAdded` for everything found.
    func start()

    /// Stop discovery and tear down any streams.
    func stop()

    /// System is about to sleep (B6b). Proactively disconnect cleanly — stop the
    /// engine outputs/streams so receivers get a graceful RTSP TEARDOWN before the
    /// sockets die — WITHOUT clearing the user's selection intent, so ``handleSystemDidWake()``
    /// can re-converge on wake. Default no-op: only ``NativeBackend`` holds real
    /// streaming sessions; the AppKit layer wires this to
    /// `NSWorkspace.willSleepNotification`.
    func handleSystemWillSleep()

    /// System just woke (B6b). Re-kick convergence for every still-desired device
    /// (intent survived sleep) and arm the wake fallback watchdog
    /// (``setWakeAudioRestoreDelay(_:)``). Default no-op; wired to
    /// `NSWorkspace.didWakeNotification`.
    func handleSystemDidWake()

    /// Configure the post-wake fallback watchdog (B6b, Settings › Audio). `delay`
    /// is in SECONDS; `nil` disables it ("Never"). If, after wake, `delay` elapses
    /// with no desired-on device reconnecting, the backend un-gates whole-system
    /// capture so the Mac's own output un-mutes — WITHOUT clearing the user's
    /// selection intent (a late reconnect re-engages the gate). Default no-op; only
    /// ``NativeBackend`` runs a capture gate/watchdog.
    func setWakeAudioRestoreDelay(_ delay: TimeInterval?)

    /// Await the teardown that ``stop()`` started, bounded by `timeout` (C1). Call
    /// AFTER ``stop()`` on the app's terminate path so graceful stream teardown gets
    /// a bounded window before process exit, rather than being outrun by it. Returns
    /// as soon as teardown completes OR `timeout` elapses — never hangs the quit.
    ///
    /// Default no-op: only ``NativeBackend`` holds real streaming sessions whose
    /// teardown outlives ``stop()``; ``MockBackend``/``OwnToneBackend`` have nothing
    /// to await, so they inherit the empty default and stay unchanged.
    func stopAndWait(timeout: Duration) async

    /// Subscribe to backend events. Each call returns an independent stream;
    /// finishing/cancelling one doesn't affect others. Typically the app makes
    /// one and drives the whole UI from it.
    func makeEventStream() -> AsyncStream<BackendEvent>

    // MARK: Controls (all fire-and-observe: they mutate state and echo a
    // `deviceUpdated` so the UI stays a pure function of backend state)

    func setVolume(_ volume: Int, for id: String)
    func setMuted(_ muted: Bool, for id: String)

    /// Replace the output set with exactly these devices. Activating a saved
    /// group calls this with the group's members — "one active group at a time,"
    /// groups behave like output presets (SPEC.md §9 interaction model).
    ///
    /// Also the entry point for the connection state machine: ids newly in the
    /// set move to `.connecting` (verified later to `.connected`); ids leaving
    /// the set drop to `.off` — **unless** they're currently `.failed`, in
    /// which case that state is sticky and survives the removal.
    ///
    /// Retry (`dev/notes/p1-connection-status-brief.md` §1/§3): re-adding an id
    /// that had been dropped is one way to retry a `.failed` device — but as of
    /// R12/W2-T3, `.failed` no longer drops the id from the desired set at all
    /// (the popover's "Try again" keeps Selected-Devices/group intent through a
    /// failure), so the *ordinary* retry call now arrives here with the id
    /// ALREADY present, unchanged. Conforming backends must still treat that as
    /// a fresh attempt: re-check each requested id's CURRENT `connectionState`
    /// (not just whether membership changed) and re-kick anything `.off` or
    /// `.failed` back to `.connecting`. `OwnToneBackend` does this naturally
    /// (it re-evaluates every id on every call); `NativeBackend`/`MockBackend`
    /// detect the "already desired, still `.failed`" case explicitly.
    func setOutputSet(_ ids: Set<String>)
}

public extension OutputBackend {
    /// Backends with no post-`stop()` teardown to await inherit this no-op.
    func stopAndWait(timeout: Duration) async {}

    /// Backends with no real streaming sessions (mock / OwnTone) have nothing to
    /// disconnect on sleep and no capture gate/watchdog to drive, so they inherit
    /// these no-ops (B6b). Only ``NativeBackend`` overrides them.
    func handleSystemWillSleep() {}
    func handleSystemDidWake() {}
    func setWakeAudioRestoreDelay(_ delay: TimeInterval?) {}
}

/// The optional latency-tuning capability (PLAN-LATENCY-SETTING.md). A backend
/// that can honor the Settings › Audio › Advanced "Audio buffer" control adopts
/// this; the settings pane shows the section only when
/// `backend as? LatencyConfigurable` succeeds, so backends without the concept
/// (`OwnToneBackend` — its buffer belongs to the external server) never render
/// a dead knob. Deliberately NOT part of ``OutputBackend``: the base seam stays
/// capability-free.
public protocol LatencyConfigurable: AnyObject {

    /// The sender start buffer currently in force, in milliseconds. The UI
    /// reads this once when building the pane (it's also the persisted
    /// `AppSettings.startBufferMs` unless an env override won at launch).
    var startBufferMs: Int { get }

    /// Apply a new start buffer. If sessions are streaming this tears them ALL
    /// down, applies the value, and re-establishes the same set (brief audible
    /// gap, ~3–5 s — which is why the UI gates it behind an explicit
    /// "Apply & Reconnect" CTA); when idle it applies silently. Returns when
    /// the re-add pass has completed (per-device failures follow the D4
    /// best-effort rule: marked unavailable, the rest proceed).
    func applyStartBuffer(ms: Int) async
}

/// The optional metering-active capability (T-GATE, playback-meter-research.md).
/// A backend that computes RMS just to feed `.level` adopts this so the work can
/// be switched off while nobody's watching a meter — `PopoverController` flips it
/// on `popoverDidShow`/`popoverDidClose` via `backend as? MeteringControlling`, so
/// a backend without the concept (`OwnToneBackend`) never sees the call.
/// Deliberately NOT part of ``OutputBackend``, mirroring ``LatencyConfigurable``:
/// the base seam stays capability-free.
public protocol MeteringControlling: AnyObject {

    /// Start or stop computing/emitting `.level` samples. `false` (inactive) is
    /// the default until the popover is first shown, and teardown/`stop()` must
    /// leave it `false` again — a closed popover has nobody to render a meter for,
    /// so there's no reason to keep spending a per-buffer RMS pass on it.
    func setMeteringActive(_ active: Bool)
}

/// The optional per-app routing capability (T6/T7). A backend that can stream a
/// routed app's audio to its OWN device — independently of the whole-system output
/// set — adopts this; the app calls ``updateAppRoutes(_:excludedBundleIDs:)``
/// whenever the app-routing table (or the excluded-apps set) changes.
///
/// Deliberately NOT part of ``OutputBackend`` (mirrors ``LatencyConfigurable``):
/// the base seam stays capability-free. Backends without per-app capture
/// (`MockBackend`, `OwnToneBackend`) simply don't conform, so
/// `backend as? AppRouteConfiguring` is nil and the app skips the call — routing an
/// app is then a no-op on those backends rather than a compile-time requirement.
public protocol AppRouteConfiguring: AnyObject {

    /// Reconcile per-app capture + engine bindings with the current route table.
    /// Starts/stops per-app taps, binds engine sessions, and emits `.routedApps`.
    /// `excludedBundleIDs` is the Settings › Audio denylist, forwarded so the
    /// whole-system tap keeps excluding both individually-routed and user-excluded
    /// apps. Must NOT be called while holding any backend-internal lock.
    func updateAppRoutes(_ routes: [AppRoute], excludedBundleIDs: Set<String>)

    /// Forward an app-quit notification (T8). `bundleID`'s process just
    /// terminated — if it currently has an active `.device(id:)` route, its
    /// per-app capture is torn down and it's excluded from the mixer topology
    /// immediately, without waiting for the persisted route table to change (the
    /// route itself survives the quit; only the live streaming state reacts). A
    /// no-op if `bundleID` has no active route. The AppKit layer is the only
    /// caller (observes `NSWorkspace.didTerminateApplicationNotification`) since
    /// Core can't observe that notification itself.
    func handleAppTerminated(bundleID: String)

    /// Forward an app-launch notification (T4). `bundleID`'s process just
    /// started — if it currently has a persisted `.device(id:)` route, this
    /// clears the dead-bundle tracking, restarts its per-app capture, and
    /// republishes the mixer topology so the route becomes live again. A no-op
    /// if `bundleID` has no active `.device(id:)` route. The AppKit layer is
    /// the only caller (observes `NSWorkspace.didLaunchApplicationNotification`).
    /// Default empty body so non-NativeBackend conformers (`MockBackend`,
    /// `OwnToneBackend`) compile without change — they have no per-app capture.
    func handleAppLaunched(bundleID: String)

    /// Set the LOCAL playback volume of a `.currentDevice`-routed app (Bug T2):
    /// an app pinned to "Current Device" is captured and replayed on the Mac's
    /// built-in speakers as an independent stream, and this levels that stream.
    /// The popover slider calls it directly for a low-latency response; the same
    /// value also flows through `updateAppRoutes` from the persisted route edit.
    /// `volume` is the UI's 0–100 int. A no-op for a bundle ID with no live local
    /// stream (non-`.currentDevice`, or not yet capturing). Default empty body so
    /// non-`NativeBackend` conformers compile without change — they have no local
    /// per-app playback.
    func setLocalPlaybackVolume(volume: Int, bundleID: String)
}

extension AppRouteConfiguring {
    /// Default no-op so backends without per-app capture don't need to implement
    /// this. Only `NativeBackend` overrides it with real restart logic.
    public func handleAppLaunched(bundleID: String) {}

    /// Default no-op so backends without local per-app playback don't need to
    /// implement this. Only `NativeBackend` overrides it (drives
    /// ``LocalPlaybackControlling``).
    public func setLocalPlaybackVolume(volume: Int, bundleID: String) {}
}
