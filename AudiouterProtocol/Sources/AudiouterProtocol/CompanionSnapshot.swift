// SPDX-License-Identifier: GPL-2.0-or-later

/// Where Main Out is currently pointed. `MainOutTarget` on the Mac side isn't
/// directly `Codable` (associated value), so this flattens it to `kind` +
/// optional `groupID` — the same idiom as `RoutingStore.State` (kind +
/// `groupID`) in AudiouterCore, not reinvented here.
public struct MainOutState: Codable, Equatable, Sendable {
    /// `"selected"` or `"group"`.
    public var kind: String
    public var groupID: String?

    public init(kind: String, groupID: String? = nil) {
        self.kind = kind
        self.groupID = groupID
    }
}

/// One device row as the phone needs to render it. Note `isMuted` and
/// `isSelected` are the GroupController-level notions (`isMuted`,
/// `isSpeakerSelected`) — NOT `Device.isMuted`/`Device.isSelected` — the Mac
/// side's `CompanionSnapshotBuilder` (T3) is responsible for reading the
/// right source.
public struct DeviceState: Codable, Equatable, Sendable {
    /// A device's live connection status, as the phone needs to render it —
    /// e.g. a failed AirPlay handshake with a headline + a suggested fix and
    /// a "Try again" action (SPEC parity, decision D9).
    public struct ConnectionInfo: Codable, Equatable, Sendable {
        public var state: String
        public var failureHeadline: String?
        public var failureSuggestion: String?

        public init(state: String, failureHeadline: String? = nil, failureSuggestion: String? = nil) {
            self.state = state
            self.failureHeadline = failureHeadline
            self.failureSuggestion = failureSuggestion
        }
    }

    public var id: String
    public var name: String
    /// `Device.Kind.rawValue`.
    public var kind: String
    /// Resolved icon symbol name, including Mac-side icon overrides.
    public var iconSymbolName: String
    public var isAvailable: Bool
    public var supportsAirPlay2: Bool
    public var isLocalDevice: Bool
    public var volume: Int
    public var isMuted: Bool
    public var isSelected: Bool
    public var isMainOutMember: Bool
    public var connection: ConnectionInfo

    public init(
        id: String,
        name: String,
        kind: String,
        iconSymbolName: String,
        isAvailable: Bool,
        supportsAirPlay2: Bool,
        isLocalDevice: Bool,
        volume: Int,
        isMuted: Bool,
        isSelected: Bool,
        isMainOutMember: Bool,
        connection: ConnectionInfo
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.iconSymbolName = iconSymbolName
        self.isAvailable = isAvailable
        self.supportsAirPlay2 = supportsAirPlay2
        self.isLocalDevice = isLocalDevice
        self.volume = volume
        self.isMuted = isMuted
        self.isSelected = isSelected
        self.isMainOutMember = isMainOutMember
        self.connection = connection
    }
}

/// A saved group, as the phone needs to render + edit it.
public struct GroupState: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var memberIDs: [String]
    /// Per-member volume, keyed by `Device.id`.
    public var memberVolumes: [String: Int]
    public var iconSymbolName: String?
    public var isMuted: Bool
    /// Last-known display name per member, keyed by `Device.id` (FIX-B2
    /// finding 7b). Groups can name members that are not currently
    /// discovered — without this the phone's Groups tab could not label an
    /// offline member at all. A member absent from this map has no known
    /// name (never seen this Mac session); render a placeholder. Optional
    /// so a peer built before this field decodes cleanly (additive change,
    /// no protocol break).
    public var memberNames: [String: String]?

    public init(
        id: String,
        name: String,
        memberIDs: [String],
        memberVolumes: [String: Int],
        iconSymbolName: String? = nil,
        isMuted: Bool,
        memberNames: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.memberIDs = memberIDs
        self.memberVolumes = memberVolumes
        self.iconSymbolName = iconSymbolName
        self.isMuted = isMuted
        self.memberNames = memberNames
    }
}

/// One app's per-app routing redirect + volume, as the phone needs to render
/// and edit it. `destinationKind`/`deviceID` mirror `AppRouteDestination`'s
/// flattening in `AppRouteStore` on the Mac side (`.noRedirect` /
/// `.currentDevice` / `.device(id:)`).
public struct AppRouteState: Codable, Equatable, Sendable {
    public var bundleID: String
    public var displayName: String
    /// `"noRedirect"` | `"currentDevice"` | `"device"`.
    public var destinationKind: String
    /// Only non-nil when `destinationKind == "device"`.
    public var deviceID: String?
    public var volume: Int
    public var isRunning: Bool

    public init(
        bundleID: String,
        displayName: String,
        destinationKind: String,
        deviceID: String? = nil,
        volume: Int,
        isRunning: Bool
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.destinationKind = destinationKind
        self.deviceID = deviceID
        self.volume = volume
        self.isRunning = isRunning
    }
}

/// The Mac-authoritative slice of settings the phone can see/change (D10):
/// connect volume + its range, and the audio buffer + the options the phone
/// may pick from. Ranges/options ship in the snapshot (not hardcoded on the
/// phone) so a future change to the Mac's allowed range needs no phone update.
public struct SettingsState: Codable, Equatable, Sendable {
    public var connectVolume: Int
    public var connectVolumeMin: Int
    public var connectVolumeMax: Int
    public var startBufferMs: Int
    public var startBufferOptionsMs: [Int]

    public init(
        connectVolume: Int,
        connectVolumeMin: Int,
        connectVolumeMax: Int,
        startBufferMs: Int,
        startBufferOptionsMs: [Int]
    ) {
        self.connectVolume = connectVolume
        self.connectVolumeMin = connectVolumeMin
        self.connectVolumeMax = connectVolumeMax
        self.startBufferMs = startBufferMs
        self.startBufferOptionsMs = startBufferOptionsMs
    }
}

/// Full app state, sent whole on connect (`welcome`) and again on every
/// change (`state`), coalesced ~50 ms and suppressed when `Equatable`-identical
/// to the last broadcast (`CompanionServer`, T5) — the server is the one
/// source of truth; the phone never computes state itself.
public struct Snapshot: Codable, Equatable, Sendable {
    /// An app the phone can offer to add to per-app routing —
    /// not yet in `appRoutes` because no route has been created for it yet.
    public struct AddableApp: Codable, Equatable, Sendable {
        public var bundleID: String
        public var displayName: String

        public init(bundleID: String, displayName: String) {
            self.bundleID = bundleID
            self.displayName = displayName
        }
    }

    public var serverName: String
    public var devices: [DeviceState]
    public var mainOut: MainOutState
    public var mainOutMasterVolume: Int
    public var mainOutMuted: Bool
    public var groups: [GroupState]
    public var activeGroupID: String?
    public var appRoutes: [AppRouteState]
    /// App names currently routed live to each device, keyed by `Device.id`.
    public var liveRoutedAppNames: [String: [String]]
    public var addableApps: [AddableApp]
    public var localFallbackActive: Bool
    public var takeoverStatus: String?
    /// Whether the macOS system default output is AirPlay-class while the Mac
    /// is actively streaming (double-path/echo risk — the popover's W3-T3
    /// note). FIX-B2 finding 7a: cached Mac-side like `localFallbackActive`.
    /// Optional so a peer built before this field decodes cleanly (additive
    /// change, no protocol break); `nil` means "not reported" — treat as
    /// `false`.
    public var systemDefaultIsAirPlayActive: Bool?
    public var settings: SettingsState

    public init(
        serverName: String,
        devices: [DeviceState],
        mainOut: MainOutState,
        mainOutMasterVolume: Int,
        mainOutMuted: Bool,
        groups: [GroupState],
        activeGroupID: String? = nil,
        appRoutes: [AppRouteState],
        liveRoutedAppNames: [String: [String]],
        addableApps: [AddableApp],
        localFallbackActive: Bool,
        takeoverStatus: String? = nil,
        systemDefaultIsAirPlayActive: Bool? = nil,
        settings: SettingsState
    ) {
        self.serverName = serverName
        self.devices = devices
        self.mainOut = mainOut
        self.mainOutMasterVolume = mainOutMasterVolume
        self.mainOutMuted = mainOutMuted
        self.groups = groups
        self.activeGroupID = activeGroupID
        self.appRoutes = appRoutes
        self.liveRoutedAppNames = liveRoutedAppNames
        self.addableApps = addableApps
        self.localFallbackActive = localFallbackActive
        self.takeoverStatus = takeoverStatus
        self.systemDefaultIsAirPlayActive = systemDefaultIsAirPlayActive
        self.settings = settings
    }
}
