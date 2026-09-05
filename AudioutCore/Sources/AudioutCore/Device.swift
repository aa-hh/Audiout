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
        /// A Google Cast receiver (Chromecast, Nest speaker/display, Android TV)
        /// driven by `CastOutputManager` over the Cast v2 protocol — not an
        /// AirPlay receiver. `id` is the receiver's Bonjour TXT-record `id`;
        /// `supportsAirPlay2` is always `false`, and a Cast id is never
        /// engine-driven (it is the third routing partition, like `.bluetooth`).
        case cast

        /// Whether a device of this kind can ONLY have been found by browsing
        /// the local network over Bonjour — which makes its presence proof that
        /// macOS granted this app Local Network access, established by the app's
        /// own everyday traffic rather than by a separate check.
        ///
        /// That matters because Local Network is the one permission with no
        /// silent read: browsing IS the request, so asking costs a system
        /// prompt (see `AppSettings.localNetworkWasGranted`). A speaker already
        /// on screen answers the question for free.
        ///
        /// `localMac` is this machine's own hardware and `bluetooth` comes from
        /// Core Audio plus the paired list — neither touches the network, so
        /// neither proves anything. Exhaustive on purpose: a new kind has to
        /// state which side it is on.
        public var isDiscoveredOverLocalNetwork: Bool {
            switch self {
            case .homePod, .appleTV, .airportExpress, .sonos, .generic, .cast:
                return true
            case .localMac, .bluetooth:
                return false
            }
        }

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
            // This is the FALLBACK for a Bluetooth row whose name names no
            // product and whose device class is unknown or names a speaker; a
            // recognised product, or a pairing that says it is headphones or
            // car audio, draws its own glyph — see ``Device/symbolName``.
            // Not "hifispeaker.2.fill": that is a stereo PAIR, which drew two
            // cabinets for a set of earbuds (owner's call, 2026-09-04).
            case .bluetooth:      return "radio.fill"
            // SF Symbols has no Cast rune (trademark); the TV-plus-speaker
            // glyph reads as "receiver attached to a screen", which is what a
            // Chromecast/Nest/Android TV target is, and collides with nothing.
            case .cast:           return "tv.and.hifispeaker.fill"
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

    /// A Google Cast receiver. Like Bluetooth, Cast devices are non-local but
    /// never engine-driven — `CastOutputManager` owns them — so AirPlay-only
    /// paths must exclude them by this, never by `supportsAirPlay2` (AP1
    /// receivers share that flag yet ARE engine-driven).
    public var isCast: Bool { kind == .cast }

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

    /// Measured Cast stream lag in whole seconds, non-nil ONLY while a
    /// fixed-volume (feed-gain) Cast receiver is playing — non-nil means
    /// volume/mute are applied inside the audio feed and land ~this many
    /// seconds later. Always `nil` for attenuation receivers, non-Cast
    /// devices, and stopped sessions.
    public var castVolumeLagSeconds: Int?

    /// The Audio/Video MINOR device class this pairing reports in its Class of
    /// Device (`IOBluetoothDevice.deviceClassMinor`, carried here by
    /// ``BTDeviceSnapshot/deviceClassMinor``). `nil` for every non-Bluetooth
    /// kind, and for a Bluetooth row the paired list could not be read for.
    /// Its only job is picking the row glyph — see ``symbolName``.
    public var bluetoothDeviceClassMinor: UInt32?

    /// Product phrases that make a Bluetooth device's model unambiguous, and
    /// the SF Symbol each one earns. MOST SPECIFIC FIRST: the first phrase
    /// found anywhere in the name wins, so "AirPods Pro" and "AirPods Max" can
    /// never fall into the plain "airpods" glyph sitting below them.
    ///
    /// Phrases are matched against the name with everything but letters and
    /// digits removed, because people rename their speakers: the pair this was
    /// written for is called "My AirPods Pro #2". Only the product phrase
    /// is ever matched — Apple does not translate these, while the words the
    /// owner puts around them can be any language.
    ///
    /// Apple and Beats only, because SF Symbols draws no other manufacturer's
    /// headphones. Every symbol here is a real product's own glyph; a phrase
    /// whose best glyph would be a generic cabinet (Beats Pill) is deliberately
    /// absent, so no entry can return an AirPlay kind's glyph and blur the
    /// Bluetooth/AirPlay distinction ``Kind/symbolName`` keeps.
    static let bluetoothProductGlyphs: [(phrase: String, symbol: String)] = [
        ("airpodsmax", "airpodsmax"),
        ("airpodspro", "airpodspro"),
        ("airpods4", "airpods.gen4"),
        ("airpods3", "airpods.gen3"),
        ("airpods", "airpods"),
        ("powerbeatspro", "beats.powerbeatspro"),
        ("powerbeats", "beats.earphones"),
        ("beatsfitpro", "beats.fit.pro"),
        ("beatsstudiobud", "beats.studiobud.right"),
        ("beatsstudio", "beats.headphones"),
        ("beatssolo", "beats.headphones"),
        ("beatsflex", "beats.earphones"),
        ("beatsx", "beats.earphones"),
    ]

    /// The product glyph `name` earns, or `nil` when nothing in it names a
    /// model — which is every device this table does not know, and the reason
    /// the caller still has the device-class routing under it.
    static func bluetoothProductSymbol(forName name: String) -> String? {
        let folded = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return bluetoothProductGlyphs.first { folded.contains($0.phrase) }?.symbol
    }

    /// The SF Symbol for this device's row icon. Everything but Bluetooth is
    /// decided by ``Kind/symbolName`` alone; a Bluetooth pairing also states
    /// what it IS, and headphones drawn as a speaker cabinet was the defect
    /// this exists to fix (owner's call, 2026-09-04).
    ///
    /// Three steps, and a wrong glyph is worse than a generic one, so each
    /// falls through to the next rather than guessing. First the name: when it
    /// carries a product phrase the model is unambiguous and the device gets
    /// that product's own glyph (``bluetoothProductGlyphs``). A product glyph
    /// is the deliberate exception to the rule that Bluetooth rows stay
    /// visually distinct from the AirPlay kinds — it names one real device
    /// rather than a category, so it cannot be mistaken for a category.
    ///
    /// Then the device class. The values are the Audio/Video minor device
    /// classes from the Bluetooth assigned numbers
    /// (`BluetoothAssignedNumbers.h`): headset `0x01`,
    /// hands-free `0x02`, loudspeaker `0x05`, headphones `0x06`, portable
    /// `0x07`, car audio `0x08`, HiFi `0x0a`. Spelled as literals rather than
    /// the `kBluetoothDeviceClassMinorAudio*` constants because this target
    /// must not import IOBluetooth — an ungated IOBluetooth touch kills the
    /// process, so the framework stays behind `BTDeviceEnumerator`'s gate.
    ///
    /// Everything not named here — the speaker classes, an unclassified
    /// pairing, an unreadable paired list — keeps the kind's own neutral
    /// speaker glyph. Both branch glyphs predate macOS 11, so neither needs an
    /// availability check against the 14.2 floor, and every product glyph
    /// resolves on this AppKit (`DeviceBluetoothKindTests`).
    public var symbolName: String {
        guard kind == .bluetooth else { return kind.symbolName }
        if let product = Self.bluetoothProductSymbol(forName: name) { return product }
        guard let minor = bluetoothDeviceClassMinor else { return kind.symbolName }
        switch minor {
        case 0x01, 0x02, 0x06: return "headphones"
        case 0x08:             return "car.fill"
        default:               return kind.symbolName
        }
    }

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
        eqBypassReason: EQBypassReason? = nil,
        castVolumeLagSeconds: Int? = nil,
        bluetoothDeviceClassMinor: UInt32? = nil
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
        self.castVolumeLagSeconds = castVolumeLagSeconds
        self.bluetoothDeviceClassMinor = bluetoothDeviceClassMinor
    }
}

extension Int {
    /// Volumes are always 0–100. Central clamp so no caller can push a slider
    /// out of range (the group-master proportional scaling in the UI can
    /// briefly compute >100 before clamping — SPEC.md §9).
    var clampedToVolume: Int { Swift.min(100, Swift.max(0, self)) }
}
