import Foundation
import Network
import AirPlayEngine

// NativeDiscovery (T-NB-DISCOVERY-1).
//
// The app-owned Bonjour discovery layer for the native path. AirPlayEngine is a
// pure *consumer* of resolved `DeviceDescriptor`s (RESOLVED Q5: "App/Phase-1 owns
// discovery (NWBrowser); the engine takes a fully-resolved output descriptor" —
// the entire mdns.h dependency is cut out of the C core). This is the component
// that produces those descriptors.
//
// It browses BOTH `_airplay._tcp` (AirPlay 2 / buffered) AND `_raop._tcp`
// (classic AirPlay 1 / RAOP). Per D6, AP1-only receivers are DISCOVERED and
// SURFACED (dimmed/disabled in the UI, never `addOutput`-ed) — they are not
// dropped. Classification (AP2-capable vs AP1-only) mirrors the vendored
// sender's own gate exactly (see `NativeDiscovery.classify`) so the two never
// disagree about whether a device can be streamed to.
//
// SPEC.md §4: no OwnTone naming in any public symbol.

// MARK: - Public surface

/// A discovered AirPlay receiver, as seen by the native path.
///
/// Carries the engine's neutral ``DeviceDescriptor`` (name/host/address/family/
/// port + the raw TXT record) plus the two derived facts the backend/UI need:
/// the stable string `id` (the colon-hex `deviceid`, verbatim — NEVER
/// reformatted) and whether the device is AirPlay-2 capable.
public struct DiscoveredDevice: Sendable, Equatable {

    /// Manual `Equatable`: the engine's ``DeviceDescriptor`` is not itself
    /// `Equatable`, so we compare on identity + the derived facts + the
    /// descriptor's stored fields (address/family/port/txt — the things a
    /// re-resolve can change and that should trigger a `.updated` event).
    public static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id &&
        lhs.outputID == rhs.outputID &&
        lhs.isAirPlay2Supported == rhs.isAirPlay2Supported &&
        lhs.isAvailable == rhs.isAvailable &&
        lhs.descriptor.name == rhs.descriptor.name &&
        lhs.descriptor.hostname == rhs.descriptor.hostname &&
        lhs.descriptor.address == rhs.descriptor.address &&
        lhs.descriptor.family == rhs.descriptor.family &&
        lhs.descriptor.port == rhs.descriptor.port &&
        lhs.descriptor.txtRecord == rhs.descriptor.txtRecord
    }
    /// The stable identity used everywhere in the app: the receiver's `deviceid`
    /// TXT value in its original colon-hex MAC form (e.g. `AA:BB:CC:DD:EE:FF`).
    ///
    /// This is passed through verbatim — never re-cased, re-punctuated, or
    /// reconstructed from the parsed ``OutputID``. `Device.id`, every
    /// `OutputBackend` method's `for id:` parameter, and the future raop sender
    /// all key on this exact string. The parsed 64-bit ``OutputID`` (which the
    /// engine wants) is a *derived* handle kept alongside, not the source of
    /// truth for identity. (See the seam brief §3: "never let an internal
    /// numeric id leak into `Device.id` in a lossy/reformatted way.")
    public let id: String

    /// The engine-facing descriptor, ready to hand to
    /// ``AirPlayEngine/updateDiscovery(_:)`` (for AP2 devices). Built from the
    /// `_airplay._tcp` advertisement when the device has one; from `_raop._tcp`
    /// otherwise (AP1-only devices still get a descriptor so the app has their
    /// address/port for the future raop sender, but the engine is never asked to
    /// add them).
    public let descriptor: DeviceDescriptor

    /// The parsed 64-bit engine handle (from the `deviceid` TXT key). Always
    /// present — a service that fails to parse a `deviceid` is not surfaced.
    public let outputID: OutputID

    /// True iff this receiver is AirPlay-2 capable and can be streamed to by the
    /// engine. False for AP1-only receivers (raop-only, or missing the AP2
    /// feature bits), which are surfaced but never `addOutput`-ed (D6). Mirrors
    /// the vendored sender's own AP2 gate exactly (see ``NativeDiscovery/classify``).
    ///
    /// STICKY once true (see ``NativeDiscovery/Entry/hasEverBeenAP2``): a real AP2
    /// device that has EVER advertised `_airplay._tcp` keeps this `true` for the
    /// rest of the session even if that advert later times out. Losing the advert
    /// means the device is going OFFLINE (see ``isAvailable``), NOT that it
    /// downgraded to an AP1-only receiver — a Sonos powering off drops its
    /// `_airplay._tcp` and `_raop._tcp` records SEPARATELY, and the `_raop` one
    /// commonly lingers, which used to spuriously reclassify it AP1-only.
    public let isAirPlay2Supported: Bool

    /// Whether the device is reachable RIGHT NOW. A sticky-AP2 device that lost
    /// its `_airplay._tcp` advert (but still lingers on `_raop._tcp`) is reported
    /// `isAirPlay2Supported == true` with `isAvailable == false` — i.e. an AP2
    /// device that is temporarily OFFLINE, which the backend surfaces as an
    /// unavailable/failed row (retry-on-click), NOT as an AP1 "coming soon" row.
    ///
    /// A genuinely-AP1-only device (never advertised `_airplay._tcp`) is reported
    /// `isAvailable == true` here — the backend derives its own D6 "AP1 is
    /// surfaced-but-unavailable" state from `isAirPlay2Supported == false`
    /// independently; this flag only ever goes `false` for a device that WAS
    /// streamable and has now gone offline.
    public let isAvailable: Bool

    public init(id: String, descriptor: DeviceDescriptor, outputID: OutputID,
                isAirPlay2Supported: Bool, isAvailable: Bool = true) {
        self.id = id
        self.descriptor = descriptor
        self.outputID = outputID
        self.isAirPlay2Supported = isAirPlay2Supported
        self.isAvailable = isAvailable
    }
}

/// A change reported by ``NativeDiscovery`` to its delegate/callbacks.
public enum DiscoveryEvent: Sendable, Equatable {
    /// A device resolved for the first time.
    case appeared(DiscoveredDevice)
    /// An already-known device re-resolved with changed facts (address, port,
    /// TXT, or — notably — gained an `_airplay._tcp` advertisement so it flipped
    /// AP1-only → AP2). The full new snapshot is carried.
    case updated(DiscoveredDevice)
    /// A device dropped off the network. Carries the stable `id` (colon-hex
    /// deviceid) and the `isAirPlay2Supported` flag it last had, so the backend
    /// can route the removal (AP2 → also `removeDiscovery` on the engine) without
    /// a lookup.
    case disappeared(id: String, wasAirPlay2Supported: Bool)
}

// MARK: - Browser seam (for hermetic testing)

/// One AirPlay/RAOP service instance as the browse/resolve layer sees it, before
/// ``NativeDiscovery`` classifies and de-dupes it. Both the real
/// Network.framework-backed browser and the test double speak in these.
public struct ResolvedService: Sendable, Equatable {
    /// Which Bonjour service type this advertisement came from. AP2 receivers
    /// advertise `_airplay._tcp`; classic/AP1 receivers advertise `_raop._tcp`;
    /// AP2 receivers commonly advertise BOTH (which is why we de-dupe by
    /// `deviceid`).
    public enum ServiceType: String, Sendable, Equatable {
        case airplay   // _airplay._tcp
        case raop      // _raop._tcp
    }

    public var serviceType: ServiceType
    /// The Bonjour service instance name.
    public var name: String
    public var hostname: String
    public var address: String
    public var family: AddressFamily
    public var port: Int
    /// The DNS-SD TXT record, verbatim.
    public var txtRecord: [String: String]

    public init(
        serviceType: ServiceType,
        name: String,
        hostname: String = "",
        address: String,
        family: AddressFamily,
        port: Int,
        txtRecord: [String: String]
    ) {
        self.serviceType = serviceType
        self.name = name
        self.hostname = hostname
        self.address = address
        self.family = family
        self.port = port
        self.txtRecord = txtRecord
    }
}

/// The removal signal the browse layer emits. `_raop._tcp` names are decorated
/// with a `deviceid@` prefix by some stacks, so the browse layer reports whatever
/// it knows — the resolved TXT `deviceid` when it has one (preferred), else the
/// service instance name as a fallback correlation key.
public struct RemovedService: Sendable, Equatable {
    public var serviceType: ResolvedService.ServiceType
    /// The colon-hex `deviceid` if the removed advertisement's TXT was cached;
    /// nil if only the instance name is known (browse-only, never resolved).
    public var deviceID: String?
    /// The Bonjour service instance name (always known).
    public var name: String

    public init(serviceType: ResolvedService.ServiceType, deviceID: String?, name: String) {
        self.serviceType = serviceType
        self.deviceID = deviceID
        self.name = name
    }
}

/// The seam ``NativeDiscovery`` sits behind: something that browses one or more
/// Bonjour service types and reports resolves/removals. The production impl
/// (``NetworkFrameworkBrowser``) wraps two `NWBrowser`s; tests inject a double
/// that feeds `ResolvedService`s synchronously with zero network/TCC.
public protocol ServiceBrowsing: AnyObject, Sendable {
    /// Called on each fully-resolved service (name + address + TXT).
    var onResolve: (@Sendable (ResolvedService) -> Void)? { get set }
    /// Called when a service leaves the network.
    var onRemove: (@Sendable (RemovedService) -> Void)? { get set }
    /// Called when the underlying browser hits a terminal `.failed`/`.cancelled`
    /// state (informational — NativeDiscovery logs it; the browser owns retry).
    var onStateChange: (@Sendable (BrowserState) -> Void)? { get set }

    func start()
    func stop()
}

/// Neutral mirror of the browse layer's lifecycle states (`.ready`/`.failed`/
/// `.cancelled` etc.) so the seam doesn't leak Network.framework types.
public enum BrowserState: Sendable, Equatable {
    case setup
    case ready
    case failed(String)   // description of the underlying error
    case cancelled
}

// MARK: - NativeDiscovery

/// Browses `_airplay._tcp` and `_raop._tcp`, classifies each resolved device as
/// AP2-capable or AP1-only, de-dupes devices that advertise both, and reports
/// appear/update/disappear to its `onEvent` callback. Owns the colon-hex TXT id
/// ⟷ ``OutputID`` mapping (both forms are naturally in hand here at resolve time).
///
/// All mutable state is confined to one serial queue (same discipline as
/// `MockBackend`/`OwnToneBackend`); `@unchecked Sendable` is honest because of it.
public final class NativeDiscovery: @unchecked Sendable {

    /// Fires on the discovery queue for every classified change. Set before
    /// `start()`.
    public var onEvent: (@Sendable (DiscoveryEvent) -> Void)?

    private let browser: ServiceBrowsing
    private let queue = DispatchQueue(label: "Audiouted.NativeDiscovery")

    /// Everything known so far, keyed by the stable colon-hex `deviceid`.
    private var known: [String: Entry] = [:]
    private var started = false

    /// Per-device tracking of which service types are currently advertising it,
    /// and the best descriptor seen. De-dupe + AP1↔AP2 transitions live here.
    private struct Entry {
        var device: DiscoveredDevice
        /// The last resolved `_airplay._tcp` service, if any (source of truth for
        /// the AP2 descriptor + classification).
        var airplay: ResolvedService?
        /// The last resolved `_raop._tcp` service, if any (AP1 fallback).
        var raop: ResolvedService?
        /// STICKY: once this device has EVER classified AP2 (advertised
        /// `_airplay._tcp` with the AP2 feature bits), it stays AP2 for the rest
        /// of the session. A real AP2 receiver does NOT downgrade to AP1 at
        /// runtime — losing its `_airplay._tcp` advert means it's going offline,
        /// not that it became an AP1-only device. Set true in `buildDevice`
        /// whenever `classify` returns true; never cleared. Gates the
        /// offline-vs-downgrade decision in `handleRemove`.
        var hasEverBeenAP2: Bool = false
    }

    /// - Parameter browser: the browse layer. Defaults to a real
    ///   Network.framework browser over both service types; tests inject a double.
    public init(browser: ServiceBrowsing? = nil) {
        self.browser = browser ?? NetworkFrameworkBrowser()
        self.browser.onResolve = { [weak self] service in
            guard let self else { return }
            self.queue.async { self.handleResolve(service) }
        }
        self.browser.onRemove = { [weak self] removed in
            guard let self else { return }
            self.queue.async { self.handleRemove(removed) }
        }
        self.browser.onStateChange = { [weak self] state in
            guard let self else { return }
            self.queue.async { self.handleStateChange(state) }
        }
    }

    /// A snapshot of every currently-known device (available or not), for the
    /// first paint before any events arrive.
    public var devices: [DiscoveredDevice] {
        queue.sync { known.values.map(\.device).sorted { $0.id < $1.id } }
    }

    public func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
        }
        browser.start()
    }

    public func stop() {
        browser.stop()
        queue.async {
            self.started = false
            self.known.removeAll()
        }
    }

    // MARK: Resolve / remove handling (all on `queue`)

    private func handleResolve(_ service: ResolvedService) {
        // Every surfaced device MUST have a stable identity (its colon-hex id and
        // the engine's OutputID). Preferred source: the `deviceid` TXT key. But
        // real shairport-sync AP1 receivers (and other DIY/legacy RAOP gear)
        // advertise NO `deviceid` TXT at all — their MAC-derived id lives only as
        // the 12-hex-digit prefix of the Bonjour instance name
        // ("6B2E52B73717@Dev Speaker"). Fall back to that so those devices are
        // surfaced (D6) instead of silently dropped. The fallback produces the
        // SAME canonical colon-hex form the deviceid-TXT path produces, so a
        // device advertising both services still de-dupes into one entry
        // (`known` is keyed on this id; see `handleRemove`'s deviceid correlation).
        guard let (id, outputID) = Self.identity(for: service) else {
            // Neither a `deviceid` TXT nor a MAC-prefixed instance name — nothing
            // downstream can key on it. Drop, but loudly (D6: silent drops are the
            // bug we just fixed). Matches the package's stderr logging idiom.
            let message = "[Audiouted] NativeDiscovery: dropping " +
                "\(service.serviceType.rawValue) service \"\(service.name)\" — no deviceid TXT " +
                "key and no MAC-prefixed instance name to derive an id from\n"
            FileHandle.standardError.write(Data(message.utf8))
            return
        }

        var entry = known[id] ?? Entry(
            device: DiscoveredDevice(id: id, descriptor: Self.descriptor(from: service),
                                     outputID: outputID, isAirPlay2Supported: false),
            airplay: nil, raop: nil
        )

        switch service.serviceType {
        case .airplay: entry.airplay = service
        case .raop:    entry.raop = service
        }

        // Latch the sticky-AP2 bit the moment this device classifies AP2. A
        // resolve always carries a live `_airplay._tcp` advert when it classifies
        // AP2, so the device is reachable now — availability is unconditionally
        // true on the resolve path (only a REMOVE can make a sticky-AP2 device
        // unavailable; see `handleRemove`).
        if Self.classify(airplay: entry.airplay) {
            entry.hasEverBeenAP2 = true
        }

        let rebuilt = Self.buildDevice(
            id: id, outputID: outputID, entry: entry, available: true)
        entry.device = rebuilt

        let previous = known[id]
        known[id] = entry

        // Duplicate-resolve suppression: if the resolved facts didn't actually
        // change, emit nothing (Bonjour re-resolves the same record freely, and
        // IPv4/IPv6 both resolve to the same device — see `preferAddress`).
        if let previous {
            guard previous.device != rebuilt else { return }
            onEvent?(.updated(rebuilt))
        } else {
            onEvent?(.appeared(rebuilt))
        }
    }

    private func handleRemove(_ removed: RemovedService) {
        // Correlate by deviceid when the browse layer resolved it; else by the
        // service instance name against the descriptor we stored.
        let key: String?
        if let did = removed.deviceID, known[did] != nil {
            key = did
        } else {
            key = known.first { entry in
                switch removed.serviceType {
                case .airplay: return entry.value.airplay?.name == removed.name
                case .raop:    return entry.value.raop?.name == removed.name
                }
            }?.key
        }
        guard let id = key, var entry = known[id] else { return }

        // Clear only the service type that departed. A device advertising both
        // must lose BOTH before it disappears — losing its `_airplay._tcp`
        // advert alone marks a sticky-AP2 device OFFLINE (an `.updated` with
        // `isAvailable == false`), it does NOT downgrade it to AP1-only.
        switch removed.serviceType {
        case .airplay: entry.airplay = nil
        case .raop:    entry.raop = nil
        }

        if entry.airplay == nil && entry.raop == nil {
            let wasAP2 = entry.device.isAirPlay2Supported
            known[id] = nil
            onEvent?(.disappeared(id: id, wasAirPlay2Supported: wasAP2))
            return
        }

        // Still advertising on the OTHER service type. Availability is now
        // false iff a sticky-AP2 device just lost its `_airplay._tcp` advert:
        // it's a real AP2 receiver going offline (its `_raop._tcp` record simply
        // lingers longer than the `_airplay._tcp` one when it powers off), so it
        // stays `isAirPlay2Supported == true` but becomes unavailable — the
        // backend tears down any engine session and the UI shows an unavailable
        // (retry-on-click) row, NOT the AP1 "coming soon" popover. A device that
        // was NEVER AP2 (genuine AP1-only) is unaffected and stays available.
        let available = !(entry.hasEverBeenAP2 && entry.airplay == nil)
        let rebuilt = Self.buildDevice(
            id: id, outputID: entry.device.outputID, entry: entry, available: available)
        let before = entry.device
        entry.device = rebuilt
        known[id] = entry
        if rebuilt != before {
            onEvent?(.updated(rebuilt))
        }
    }

    private func handleStateChange(_ state: BrowserState) {
        // Informational only. The browser owns its own retry/lifecycle; we don't
        // tear down `known` on a transient `.failed` (that would spuriously drop
        // every device). `.cancelled` follows an explicit `stop()`, already handled.
    }

    // MARK: Building & classification (pure, static — easy to unit-test)

    /// Rebuild the `DiscoveredDevice` for an entry from whichever service types
    /// currently advertise it. `_airplay._tcp` is preferred as the descriptor
    /// source (it carries the AP2 features/pk the engine needs); `_raop._tcp` is
    /// the AP1 fallback.
    private static func buildDevice(id: String, outputID: OutputID, entry: Entry, available: Bool) -> DiscoveredDevice {
        // Prefer the airplay advertisement for the engine descriptor; fall back
        // to raop so AP1-only devices still carry an address/port.
        let source = entry.airplay ?? entry.raop!
        // AP2 is STICKY: a device that has EVER classified AP2 stays AP2 even
        // after its `_airplay._tcp` advert times out (it's going offline, not
        // downgrading — see `Entry.hasEverBeenAP2`). A device that has never
        // advertised `_airplay._tcp` with the AP2 feature bits stays AP1-only.
        let isAP2 = entry.hasEverBeenAP2 || classify(airplay: entry.airplay)
        // A sticky-AP2 device that has gone offline (lost `_airplay._tcp`, only
        // `_raop._tcp` lingers) keeps its last AP2-sourced descriptor — name,
        // address, port, TXT all stay put — so the row doesn't cosmetically flip
        // to the raop-decorated name just because the device powered off. It's
        // the same physical device at the same address; only availability changed.
        var built: DeviceDescriptor = (entry.hasEverBeenAP2 && entry.airplay == nil)
            ? entry.device.descriptor
            : descriptor(from: source)
        // When the descriptor comes from `_raop._tcp` (no `_airplay._tcp`
        // advertisement to prefer instead), the instance name is often MAC-
        // decorated by the receiver's stack ("6B2E52B73717@Dev Speaker" — see
        // `deriveIDFromInstanceName`'s doc comment). That raw form is only
        // needed for id derivation (which reads `service.name` directly, not
        // this descriptor) and — for AP2 devices — for the engine's own
        // name-keyed device tracking (`AirPlayEngine.feedDescriptor`). A
        // raop-only source is AP1-only by construction (`classify` above) and
        // is therefore NEVER handed to `updateDiscovery`/`removeDiscovery`
        // (`NativeBackend` gates both on `isAirPlay2Supported`), so stripping
        // the prefix here only affects the human-facing name shown in the UI.
        // `_airplay._tcp`-sourced names are untouched.
        if entry.airplay == nil {
            built.name = strippedRaopDisplayName(built.name)
        }
        return DiscoveredDevice(
            id: id,
            descriptor: built,
            outputID: outputID,
            isAirPlay2Supported: isAP2,
            isAvailable: available
        )
    }

    /// Strip a leading "<12 hex digits>@" MAC prefix from a `_raop._tcp`
    /// instance name for display, e.g. "6B2E52B73717@Dev Speaker" → "Dev
    /// Speaker". Names without that exact prefix shape (including bare human
    /// names with no "@" at all) are returned unchanged.
    static func strippedRaopDisplayName(_ name: String) -> String {
        let parts = name.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return name }
        let prefix = parts[0]
        guard prefix.count == 12 else { return name }
        let hexChars = "0123456789abcdefABCDEF"
        guard prefix.allSatisfy({ hexChars.contains($0) }) else { return name }
        return String(parts[1])
    }

    /// Classify AP2-capable vs AP1-only. Mirrors the vendored sender's own gate
    /// (`airplay.c` ~:4031-4052) EXACTLY so discovery and the engine never
    /// disagree: a device is AP2 iff it advertises on `_airplay._tcp` with a
    /// `features` TXT key whose bits include BOTH SupportsAirPlayAudio (bit 9)
    /// AND SupportsCoreUtilsPairingAndEncryption (bit 38 || 43 || 46 || 48).
    /// A raop-only device (`entry.airplay == nil`) is AP1-only by construction —
    /// classic AirPlay never advertises `_airplay._tcp`.
    static func classify(airplay: ResolvedService?) -> Bool {
        guard let airplay else { return false }              // raop-only ⇒ AP1-only
        guard let featuresTxt = airplay.txtRecord["features"] ?? airplay.txtRecord["Features"],
              let features = parseFeatures(featuresTxt)
        else { return false }                                // missing/invalid features ⇒ not AP2

        let supportsAudio = (features >> 9) & 1 == 1                              // bit 9
        let supportsCoreUtils = [38, 43, 46, 48].contains { (features >> $0) & 1 == 1 } // 38||43||46||48
        return supportsAudio && supportsCoreUtils
    }

    /// Parse the AirPlay `features` TXT value into a 64-bit mask. The field is
    /// either a single 32-bit hex value (`0x444F8A00`) or two comma-separated
    /// 32-bit hex values `LOW,HIGH` (`0x445D0A00,0x1C340`) where LOW is the low
    /// 32 bits and HIGH the high 32 bits — matching the vendored
    /// `features_parse` (`airplay.c` ~:3865): it writes the first value into the
    /// low `uint32_t` of a `uint64_t` and the second past the comma into the high
    /// `uint32_t`. We reproduce that bit layout here rather than in C.
    static func parseFeatures(_ text: String) -> UInt64? {
        let parts = text.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let low = parseHex32(parts[0]) else { return nil }
        guard parts.count == 2 else { return UInt64(low) }
        guard let high = parseHex32(parts[1]) else { return nil }
        return UInt64(low) | (UInt64(high) << 32)
    }

    private static func parseHex32<S: StringProtocol>(_ s: S) -> UInt32? {
        var str = s.trimmingCharacters(in: .whitespaces)
        if str.hasPrefix("0x") || str.hasPrefix("0X") { str = String(str.dropFirst(2)) }
        guard !str.isEmpty else { return nil }
        return UInt32(str, radix: 16)
    }

    /// Resolve a service's stable identity, preferring the `deviceid` TXT key and
    /// falling back to the MAC prefix of the Bonjour instance name.
    ///
    /// The TXT path is authoritative and passes the colon-hex string through
    /// verbatim (the canonical form). The instance-name fallback only fires when
    /// there is NO `deviceid` TXT at all (real shairport-sync AP1 receivers, DIY/
    /// legacy RAOP gear) — it derives the id from the 12 hex digits before "@" and
    /// formats it into the SAME canonical colon-hex form the TXT path yields, so a
    /// device that advertises both `_raop._tcp` (name-derived) and `_airplay._tcp`
    /// (deviceid TXT) collapses to one `known` entry regardless of arrival order.
    static func identity(for service: ResolvedService) -> (id: String, outputID: OutputID)? {
        if let fromTxt = parseDeviceID(service.txtRecord) { return fromTxt }
        return deriveIDFromInstanceName(service.name)
    }

    /// Extract the stable colon-hex `deviceid` (verbatim) + its parsed
    /// ``OutputID`` from a TXT record. Returns nil if absent/unparseable.
    static func parseDeviceID(_ txt: [String: String]) -> (id: String, outputID: OutputID)? {
        guard let idStr = txt["deviceid"] ?? txt["DeviceID"] else { return nil }
        let hex = idStr.replacingOccurrences(of: ":", with: "")
        guard let value = UInt64(hex, radix: 16) else { return nil }
        // `idStr` is passed through verbatim — never reformatted.
        return (idStr, OutputID(rawValue: value))
    }

    /// Derive a canonical colon-hex id from a `_raop._tcp` instance name whose
    /// prefix is a MAC address ("6B2E52B73717@Dev Speaker"). Classic RAOP names
    /// carry the 12-hex-digit MAC before the "@"; the human-readable name follows.
    ///
    /// Returns nil unless there are exactly 12 hex digits before an "@" (a bare
    /// human name like "Living Room" has none, and we must not invent an id for
    /// it — the caller drops such services loudly). The derived string is the
    /// CANONICAL form the rest of the code correlates on: uppercased colon-hex
    /// (`6B:2E:52:B7:37:17`), matching the shape AP2 receivers publish in their
    /// `deviceid` TXT — so the raop↔airplay de-dupe (keyed on this id) merges the
    /// two service types for one physical device. Mixed-case input round-trips to
    /// the same canonical output.
    static func deriveIDFromInstanceName(_ name: String) -> (id: String, outputID: OutputID)? {
        // Take everything before the first "@" (the whole name if there is none).
        let prefix = name.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard prefix.count == 12 else { return nil }
        let hexChars = "0123456789abcdefABCDEF"
        guard prefix.allSatisfy({ hexChars.contains($0) }) else { return nil }
        guard let value = UInt64(prefix, radix: 16) else { return nil }

        // Canonicalize to uppercase colon-hex, e.g. "6B:2E:52:B7:37:17". This is
        // the id assigned once and never reformatted thereafter; it is byte-for-
        // byte what a same-device `deviceid` TXT (uppercase colon-hex) parses to.
        let upper = prefix.uppercased()
        var pairs: [String] = []
        var index = upper.startIndex
        while index < upper.endIndex {
            let next = upper.index(index, offsetBy: 2)
            pairs.append(String(upper[index..<next]))
            index = next
        }
        return (pairs.joined(separator: ":"), OutputID(rawValue: value))
    }

    /// Build the engine-facing ``DeviceDescriptor`` from a resolved service.
    private static func descriptor(from service: ResolvedService) -> DeviceDescriptor {
        DeviceDescriptor(
            name: service.name,
            hostname: service.hostname,
            address: service.address,
            family: service.family,
            port: service.port,
            txtRecord: service.txtRecord
        )
    }
}

// MARK: - NetworkFrameworkBrowser (production ServiceBrowsing)

/// The real ``ServiceBrowsing``: two `NWBrowser`s (`_airplay._tcp` and
/// `_raop._tcp`), each resolving instances to address + TXT via an `NWConnection`
/// probe. Passive browsing only — no root, no PTP, no audio (D7 allows this on
/// the live LAN during dev).
///
/// Network.framework hands us the TXT record directly on the browse result
/// (`NWBrowser.Result.metadata`), but NOT the resolved IP/port — those come from
/// establishing a short-lived `NWConnection` to the endpoint and reading its
/// resolved `currentPath.remoteEndpoint`. IPv4 and IPv6 can both resolve for the
/// same instance; ``NativeDiscovery`` de-dupes on `deviceid`, and we prefer the
/// first address that establishes (`preferAddress` below keeps a stable choice).
public final class NetworkFrameworkBrowser: ServiceBrowsing, @unchecked Sendable {

    public var onResolve: (@Sendable (ResolvedService) -> Void)?
    public var onRemove: (@Sendable (RemovedService) -> Void)?
    public var onStateChange: (@Sendable (BrowserState) -> Void)?

    private let queue = DispatchQueue(label: "Audiouted.NetworkFrameworkBrowser")
    private var browsers: [NWBrowser] = []
    /// In-flight resolve probes, keyed so we can cancel on removal.
    private var probes: [String: NWConnection] = [:]
    /// Last-known TXT/name per browse result, so a removal can report the
    /// deviceid even though NWBrowser only hands us the endpoint on the way out.
    private var resultTXT: [String: (name: String, deviceID: String?)] = [:]

    public init() {}

    public func start() {
        queue.async {
            self.makeBrowser(type: "_airplay._tcp", serviceType: .airplay)
            self.makeBrowser(type: "_raop._tcp", serviceType: .raop)
        }
    }

    public func stop() {
        queue.async {
            for b in self.browsers { b.cancel() }
            self.browsers.removeAll()
            for (_, c) in self.probes { c.cancel() }
            self.probes.removeAll()
            self.resultTXT.removeAll()
        }
    }

    // MARK: Browser setup (on `queue`)

    private func makeBrowser(type: String, serviceType: ResolvedService.ServiceType) {
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .setup:      self.onStateChange?(.setup)
            case .ready:      self.onStateChange?(.ready)
            case .cancelled:  self.onStateChange?(.cancelled)
            case .failed(let err): self.onStateChange?(.failed("\(err)"))
            case .waiting(let err): self.onStateChange?(.failed("waiting: \(err)"))
            @unknown default: break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            self.queue.async { self.applyChanges(results: results, changes: changes, serviceType: serviceType) }
        }

        browsers.append(browser)
        browser.start(queue: queue)
    }

    private func applyChanges(results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>, serviceType: ResolvedService.ServiceType) {
        for change in changes {
            switch change {
            case .added(let result):
                resolve(result, serviceType: serviceType)
            case .changed(old: _, new: let result, flags: _):
                resolve(result, serviceType: serviceType)
            case .removed(let result):
                remove(result, serviceType: serviceType)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }

    // MARK: Resolve one browse result → address + TXT (on `queue`)

    /// Probe an endpoint for its resolved address, preferring — and, for now,
    /// requiring — IPv4.
    ///
    /// A single racy `NWConnection` probe over unconstrained `.tcp` params will
    /// happily settle on whatever address the OS establishes first — for a
    /// dual-stack device (AirPlay 2 speakers commonly are) that can be an IPv6
    /// **link-local** address (`fe80::...%en0`). Worse: the vendored engine
    /// currently runs with its `ipv6` conffile option OFF (`conffile.c`:
    /// `.ipv6 = 0`, set during first-light hardening to match OwnTone's
    /// default), so it cannot use ANY IPv6 address, global or link-local, right
    /// now — RTSP control may still connect (the receiver's LED goes green)
    /// while audio silently never flows. See AGENTS/engine first-light notes.
    ///
    /// Fix: probe once with `NWProtocolIP.Options.version` forced to `.v4` so
    /// `currentPath` resolves over IPv4 whenever the device has an IPv4 address
    /// at all. If that IPv4-forced probe fails outright (the device really is
    /// IPv6-only), fall back to an unconstrained probe purely to detect and
    /// loudly surface the IPv6-only device — `resolvedAddress`/`isAcceptable`
    /// still reject the address itself (never hand the engine an address it
    /// can't use), so the device is discovered/visible but not driven, the
    /// same spirit as AP1-only receivers.
    ///
    /// Deferred enhancement: native IPv6 support is gated on (a) turning the
    /// engine's `ipv6` config back on via `conffile_set_ipv6(true)` and (b) a
    /// real-hardware PTP-over-IPv6 gated test proving the media/PTP path
    /// actually works over IPv6. Until both land, IPv6 stays filtered out here
    /// rather than passed through.
    private func resolve(_ result: NWBrowser.Result, serviceType: ResolvedService.ServiceType) {
        guard case let .service(name, type, domain, _) = result.endpoint else { return }
        let txt = Self.txtDictionary(result.metadata)
        let deviceID = txt["deviceid"] ?? txt["DeviceID"]
        let resultKey = "\(serviceType.rawValue)|\(name)|\(type)|\(domain)"
        resultTXT[resultKey] = (name: name, deviceID: deviceID)

        probeIPv4First(endpoint: result.endpoint, resultKey: resultKey, name: name, serviceType: serviceType, txt: txt)
    }

    /// First attempt: force IPv4 on the probe's `NWParameters`. Never sends
    /// data — resolution only.
    private func probeIPv4First(
        endpoint: NWEndpoint,
        resultKey: String,
        name: String,
        serviceType: ResolvedService.ServiceType,
        txt: [String: String]
    ) {
        let params = NWParameters.tcp
        if let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }

        let connection = NWConnection(to: endpoint, using: params)
        probes[resultKey] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.queue.async {
                    if let (address, family, port) = Self.resolvedAddress(connection) {
                        self.onResolve?(ResolvedService(
                            serviceType: serviceType,
                            name: name,
                            hostname: name,
                            address: address,
                            family: family,
                            port: port,
                            txtRecord: txt
                        ))
                    } else {
                        Self.logIPv6Only(connection: connection, name: name)
                    }
                    connection.cancel()
                    self.probes[resultKey] = nil
                }
            case .failed, .cancelled:
                self.queue.async {
                    self.probes[resultKey] = nil
                    // The IPv4-forced probe couldn't establish at all — the
                    // device may be IPv6-only. Fall back to an unconstrained
                    // probe purely to detect that case and log it loudly;
                    // `resolvedAddress` still rejects the resulting IPv6
                    // address (link-local OR global — see the deferred-IPv6
                    // note above), so we never emit an address the engine
                    // can't use.
                    self.probeUnconstrainedFallback(endpoint: endpoint, resultKey: resultKey, name: name, serviceType: serviceType, txt: txt)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Fallback attempt when the IPv4-forced probe fails outright (no IPv4
    /// route at all). Unconstrained by IP version, but `resolvedAddress` still
    /// rejects IPv6 across the board (see the deferred-IPv6 note on
    /// ``probeIPv4First``) — this fallback exists only so an IPv6-only device
    /// is detected and logged loudly rather than the probe just silently
    /// timing out with no explanation.
    private func probeUnconstrainedFallback(
        endpoint: NWEndpoint,
        resultKey: String,
        name: String,
        serviceType: ResolvedService.ServiceType,
        txt: [String: String]
    ) {
        // Don't retry if the result was already removed while the first probe
        // was failing.
        guard resultTXT[resultKey] != nil else { return }

        let connection = NWConnection(to: endpoint, using: .tcp)
        probes[resultKey] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.queue.async {
                    if let (address, family, port) = Self.resolvedAddress(connection) {
                        self.onResolve?(ResolvedService(
                            serviceType: serviceType,
                            name: name,
                            hostname: name,
                            address: address,
                            family: family,
                            port: port,
                            txtRecord: txt
                        ))
                    } else {
                        Self.logIPv6Only(connection: connection, name: name)
                    }
                    connection.cancel()
                    self.probes[resultKey] = nil
                }
            case .failed, .cancelled:
                self.queue.async { self.probes[resultKey] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Loud diagnostic when a probe's resolved address is rejected because
    /// it's IPv6 (the address existed, just wasn't usable) — makes the
    /// otherwise-silent "device is IPv6-only, not surfaced with a usable
    /// address" outcome visible instead of looking like a probe that simply
    /// never resolved. Not gated on link-local specifically: with the engine's
    /// `ipv6` config off, a global IPv6-only address is just as unusable.
    private static func logIPv6Only(connection: NWConnection, name: String) {
        guard case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint,
              case let .ipv6(addr) = host
        else { return }
        let rejected = addressString(addr)
        let kind = isLinkLocalIPv6String(rejected) ? "link-local" : "global"
        let message = "[Audiouted] NativeDiscovery: \"\(name)\" resolved ONLY to an " +
            "IPv6 (\(kind)) address (\(rejected)) — rejecting rather than surfacing it as the " +
            "device's address (native IPv6 is a deferred enhancement: the engine's `ipv6` " +
            "conffile option is currently OFF, so it cannot use ANY IPv6 address yet)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    private func remove(_ result: NWBrowser.Result, serviceType: ResolvedService.ServiceType) {
        guard case let .service(name, type, domain, _) = result.endpoint else { return }
        let resultKey = "\(serviceType.rawValue)|\(name)|\(type)|\(domain)"
        probes[resultKey]?.cancel()
        probes[resultKey] = nil
        let deviceID = resultTXT[resultKey]?.deviceID
        resultTXT[resultKey] = nil
        onRemove?(RemovedService(serviceType: serviceType, deviceID: deviceID, name: name))
    }

    // MARK: NW helpers

    /// Flatten `NWBrowser.Result.Metadata` into a `[String: String]` TXT map.
    private static func txtDictionary(_ metadata: NWBrowser.Result.Metadata) -> [String: String] {
        guard case let .bonjour(record) = metadata else { return [:] }
        return record.dictionary
    }

    /// Read the resolved numeric address + port + family off a ready connection.
    ///
    /// Applies the address-acceptance policy (``isAcceptable(address:family:)``):
    /// an IPv6 result — link-local OR global — is never returned here, even
    /// though the connection itself is `.ready` — the caller
    /// (``resolve(_:serviceType:)``) treats a `nil` as "no usable address" and
    /// the device is surfaced (if at all) without a descriptor the engine can
    /// act on, rather than one that produces a green-LED-no-audio connection.
    private static func resolvedAddress(_ connection: NWConnection) -> (address: String, family: AddressFamily, port: Int)? {
        guard let endpoint = connection.currentPath?.remoteEndpoint else { return nil }
        switch endpoint {
        case let .hostPort(host, port):
            switch host {
            case let .ipv4(addr):
                let address = addressString(addr)
                guard isAcceptable(address: address, family: .ipv4) else { return nil }
                return (address, .ipv4, Int(port.rawValue))
            case let .ipv6(addr):
                let address = addressString(addr)
                guard isAcceptable(address: address, family: .ipv6) else { return nil }
                return (address, .ipv6, Int(port.rawValue))
            case let .name(name, _):
                return (name, .ipv4, Int(port.rawValue))
            @unknown default:
                return nil
            }
        default:
            return nil
        }
    }

    /// The address-selection policy, factored out as a pure/static predicate so
    /// it's unit-testable without a live `NWConnection`.
    ///
    /// Policy: reject IPv6 **entirely**, link-local (`fe80::/10`, commonly
    /// carrying a `%<zone>` scope suffix like `%en0`) or global — only IPv4 is
    /// acceptable. This is stricter than "just reject link-local" because the
    /// vendored engine currently runs with its `ipv6` conffile option OFF
    /// (`conffile.c`: `.ipv6 = 0`), so it cannot use ANY IPv6 address yet, not
    /// just link-local ones. A dual-stack device therefore never gets pinned to
    /// an IPv6 address just because that's what a single racy probe happened to
    /// establish over; combined with the IPv4-forced first probe in
    /// ``probeIPv4First``, a dual-stack device's emitted address is always
    /// IPv4, and an IPv6-only device (global or link-local, no IPv4 at all)
    /// resolves to no usable address (logged loudly, never silently emitted).
    ///
    /// Deferred enhancement: once the engine's `ipv6` config is turned back on
    /// (`conffile_set_ipv6(true)`) and a real-hardware PTP-over-IPv6 gated test
    /// proves the media/PTP path works over IPv6, this policy should relax to
    /// accept IPv6 **global** addresses (still never link-local).
    static func isAcceptable(address: String, family: AddressFamily) -> Bool {
        _ = address // kept in the signature: policy is address-family-based today, but
                     // stays here (rather than taking just `family`) so a future relax to
                     // "IPv4 or global-IPv6" can inspect the literal without a signature change.
        return family == .ipv4
    }

    /// True iff `address` is an IPv6 link-local literal (`fe80::/10`), with or
    /// without a `%<zone>` scope suffix (e.g. `fe80::562a:1bff:fe79:89e%en0`).
    /// Case-insensitive; matches the `fe80`–`febf` first-hextet range that
    /// makes up the `fe80::/10` block.
    static func isLinkLocalIPv6String(_ address: String) -> Bool {
        let unscoped = address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let firstHextet = unscoped.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0].lowercased()
        guard firstHextet.count == 4, let value = UInt16(firstHextet, radix: 16) else {
            // Shorthand forms like "fe80::1" still have a 4-char first hextet
            // ("fe80"); anything that doesn't parse as one isn't a link-local
            // literal we recognize (e.g. a bare IPv4 string never reaches
            // here because `isAcceptable` only applies this check for `.ipv6`).
            return false
        }
        // fe80::/10 spans first hextets 0xFE80...0xFEBF (top 10 bits fixed to
        // 1111 1110 10). Equivalent to `(value & 0xFFC0) == 0xFE80`.
        return (value & 0xFFC0) == 0xFE80
    }

    private static func addressString(_ addr: IPv4Address) -> String {
        addr.rawValue.map(String.init).joined(separator: ".")
    }

    private static func addressString(_ addr: IPv6Address) -> String {
        addr.debugDescription
    }
}
