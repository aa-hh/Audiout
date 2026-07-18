import Foundation

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
    /// which case that state is sticky and survives the removal (the popover
    /// uses this exact call to clean up a failed toggle's membership without
    /// erasing the warning it's showing). Re-adding a `.failed` id is the retry
    /// path and moves it back to `.connecting`
    /// (`dev/notes/p1-connection-status-brief.md` §1/§3).
    func setOutputSet(_ ids: Set<String>)
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
