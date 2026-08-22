import Foundation

/// A single AirPlay output the app can discover and control.
///
/// This is a *value type* on purpose: the backend owns the source of truth and
/// hands out snapshots via ``BackendEvent``. The UI never mutates a `Device`
/// directly — it calls a backend method (`setVolume`, `setMuted`, …) and waits
/// for the echoed update. That keeps the mock and the real backends
/// behaving identically from the UI's point of view.
public struct Device: Identifiable, Equatable, Sendable {

    /// What kind of receiver this is — drives the SF Symbol and hints at quirks
    /// (e.g. Sonos requires AirPlay-2 PTP timing; see SPEC.md §8 "0b").
    public enum Kind: String, Sendable, CaseIterable {
        case localMac         // this Mac's own built-in / default output
        case homePod
        case appleTV
        case airportExpress
        case sonos
        case generic          // any other third-party AirPlay receiver
        /// A Bluetooth audio output (A2DP speaker/headphones), enumerated via
        /// Core Audio + the IOBluetooth paired list — not an AirPlay receiver.
        /// `id` is the Core Audio `kAudioDevicePropertyDeviceUID` (derived from
        /// the BT MAC address, so it survives disconnect/rejoin);
        /// `supportsAirPlay2` is always `false` (PLAN-UNIVERSAL-SYNC BT-DEVICE).
        case bluetooth

        /// SF Symbol name for the row icon (all are documented AppKit-usable
        /// symbols — see SPEC.md §9 "Device row").
        public var symbolName: String {
            switch self {
            case .localMac:       return "laptopcomputer"
            case .homePod:        return "homepod.fill"
            case .appleTV:        return "appletv.fill"
            case .airportExpress: return "wifi.router.fill"
            case .sonos:          return "hifispeaker.fill"
            case .generic:        return "hifispeaker.fill"
            // SF Symbols has no Bluetooth rune (trademark); a distinct
            // speaker glyph separates BT rows from the AirPlay kinds above.
            // NOT "speaker.wave.2.fill" — that's the rows' mute-accessory
            // glyph (DeviceRowView/MainOutRowView) and would collide.
            case .bluetooth:      return "hifispeaker.2.fill"
            }
        }
    }

    /// Why a stored EQ is not reaching the audio right now. Both cases keep the
    /// user's values intact; they differ only in what the UI must say.
    public enum EQBypassReason: Equatable, Sendable {
        /// More distinct EQ settings are in play than the engine has streams
        /// for, so this device streams flat (`EQStreamTopology`'s loser).
        case streamBudget
        /// Apps are routed straight to this speaker, so its audio comes from the
        /// per-app mixer and never passes the whole-system EQ stage at all.
        case perAppRouting
    }

    /// Stable identity — the Bonjour service name / device id for AirPlay
    /// receivers; the Core Audio `kAudioDevicePropertyDeviceUID` for
    /// `.bluetooth` devices. Survives a device dropping off (the network or
    /// the BT link) and coming back (that's what lets auto-reconnect rejoin
    /// the *same* device to a saved group).
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

    /// This is the Mac's own output (built-in speakers / whatever the system
    /// default is), NOT an AirPlay receiver. Targeting only this device is
    /// passthrough (SPEC.md §9b). Exactly one device in a fleet should carry
    /// this flag.
    public var isLocalDevice: Bool

    /// A Bluetooth audio output. BT devices are non-local (they mix with
    /// AirPlay in groups) but are never engine-driven — the future `BTSyncedSink`
    /// owns them, so AirPlay-only paths must exclude them by this, never by
    /// `supportsAirPlay2` (AP1 receivers share that flag yet ARE engine-driven).
    public var isBluetooth: Bool { kind == .bluetooth }

    // MARK: Control state (0–100 volume model, matching the UI sliders)

    public var volume: Int
    public var isMuted: Bool

    /// This speaker's own tone settings — one EQ per device, wherever it appears.
    /// Set through `OutputBackend.setEQ(_:for:commit:)` and echoed back like
    /// `volume`; the UI never writes it directly.
    public var eq: DeviceEQ

    /// Why this device's stored EQ is NOT currently audible, or `nil` when it is
    /// applied. The values are untouched either way — this is the only thing
    /// standing between the UI and claiming an inaudible EQ is applied, and the
    /// REASON is carried because the two cases need different sentences.
    public var eqBypassReason: EQBypassReason?

    /// In the backend's current OUTPUT set — i.e. this device is currently being
    /// streamed to. Under the SPEC §9b Main Out model this is decided by the Main
    /// Out target (a group's members, or the AirPlay members of Selected Devices),
    /// NOT by the per-device toggle (which composes the *Selected Devices* set, a
    /// separate thing tracked in `GroupController.selectedDeviceIDs`).
    public var isSelected: Bool

    /// Live connection lifecycle for this device — off/connecting/connected/
    /// reconnecting/failed. The backend is the only writer; see
    /// `ConnectionState` and `dev/notes/p1-connection-status-brief.md` §1 for
    /// the full state machine, including the "sticky-failed" rule (a `.failed`
    /// device stays failed even after it's dropped from the expected-selected
    /// set).
    public var connectionState: ConnectionState

    public init(
        id: String,
        name: String,
        kind: Kind,
        isAvailable: Bool = true,
        supportsAirPlay2: Bool = true,
        volume: Int = 50,
        isMuted: Bool = false,
        isSelected: Bool = false,
        isLocalDevice: Bool = false,
        connectionState: ConnectionState = .off,
        eq: DeviceEQ = .flat,
        eqBypassReason: EQBypassReason? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isAvailable = isAvailable
        self.supportsAirPlay2 = supportsAirPlay2
        self.volume = volume.clampedToVolume
        self.isMuted = isMuted
        self.isSelected = isSelected
        self.isLocalDevice = isLocalDevice
        self.connectionState = connectionState
        self.eq = eq
        self.eqBypassReason = eqBypassReason
    }
}

extension Int {
    /// Volumes are always 0–100. Central clamp so no caller can push a slider
    /// out of range (the group-master proportional scaling in the UI can
    /// briefly compute >100 before clamping — SPEC.md §9).
    var clampedToVolume: Int { Swift.min(100, Swift.max(0, self)) }
}
