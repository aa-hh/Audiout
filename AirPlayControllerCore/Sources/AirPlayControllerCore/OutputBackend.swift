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
    /// Any field of a device changed — volume, mute, availability, selection.
    case deviceUpdated(Device)
    /// A cheap RMS level sample (0…1) for the per-device level meter
    /// (`NSLevelIndicator`, display-only — SPEC.md §9). Emitted only for
    /// selected, unmuted devices while "playing."
    case level(id: String, rms: Float)
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
    func setOutputSet(_ ids: Set<String>)
}
