import Foundation

/// A single AirPlay output the app can discover and control.
///
/// This is a *value type* on purpose: the backend owns the source of truth and
/// hands out snapshots via ``BackendEvent``. The UI never mutates a `Device`
/// directly — it calls a backend method (`setVolume`, `setMuted`, …) and waits
/// for the echoed update. That keeps the mock and the real (OwnTone) backend
/// behaving identically from the UI's point of view.
public struct Device: Identifiable, Equatable, Sendable {

    /// What kind of receiver this is — drives the SF Symbol and hints at quirks
    /// (e.g. Sonos requires AirPlay-2 PTP timing; see SPEC.md §8 "0b").
    public enum Kind: String, Sendable, CaseIterable {
        case homePod
        case appleTV
        case airportExpress
        case sonos
        case generic          // any other third-party AirPlay receiver

        /// SF Symbol name for the row icon (all are documented AppKit-usable
        /// symbols — see SPEC.md §9 "Device row").
        public var symbolName: String {
            switch self {
            case .homePod:        return "homepod.fill"
            case .appleTV:        return "appletv.fill"
            case .airportExpress: return "wifi.router.fill"
            case .sonos:          return "hifispeaker.fill"
            case .generic:        return "hifispeaker.fill"
            }
        }
    }

    /// Stable identity — the Bonjour service name / device id. Survives a
    /// device dropping off the network and coming back (that's what lets
    /// auto-reconnect rejoin the *same* device to a saved group).
    public let id: String

    public var name: String
    public var kind: Kind

    /// Currently reachable on the network. A dropped device stays in the model
    /// (greyed out) rather than vanishing, so groups keep their membership.
    public var isAvailable: Bool

    /// AirPlay-2 / PTP-capable. `false` means AirPlay-1 only (no perfect sync).
    /// The mock uses this to mirror the real fleet: Sonos = true, the AirPort
    /// Express in the Phase-0 notes = AirPlay-1 only.
    public var supportsAirPlay2: Bool

    // MARK: Control state (0–100 volume model, matching the UI sliders)

    public var volume: Int
    public var isMuted: Bool
    public var isSoloed: Bool

    /// In the current output set (the members of the active group). The pipeline
    /// streams to exactly the selected devices — see SPEC.md §9 interaction model.
    public var isSelected: Bool

    public init(
        id: String,
        name: String,
        kind: Kind,
        isAvailable: Bool = true,
        supportsAirPlay2: Bool = true,
        volume: Int = 50,
        isMuted: Bool = false,
        isSoloed: Bool = false,
        isSelected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isAvailable = isAvailable
        self.supportsAirPlay2 = supportsAirPlay2
        self.volume = volume.clampedToVolume
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.isSelected = isSelected
    }
}

extension Int {
    /// Volumes are always 0–100. Central clamp so no caller can push a slider
    /// out of range (the group-master proportional scaling in the UI can
    /// briefly compute >100 before clamping — SPEC.md §9).
    var clampedToVolume: Int { Swift.min(100, Swift.max(0, self)) }
}
