import XCTest
import AirPlayEngine
@testable import AirPlayControllerCore

/// Hermetic tests for ``NativeDiscovery`` (T-NB-DISCOVERY-1): an injected
/// ``ServiceBrowsing`` double drives resolve/remove synchronously. No
/// `NWBrowser`, no network, no TCC.
///
/// Covers: appear→update→disappear for an AP2 device and an AP1-only device,
/// descriptor field propagation, AP2/AP1 classification (mirroring the
/// vendored feature-bit gate), the colon-hex id round-trip (never
/// reformatted), and de-dupe of a device advertising both `_airplay._tcp`
/// and `_raop._tcp`.
final class NativeDiscoveryTests: XCTestCase {

    // MARK: Double

    /// A `ServiceBrowsing` double that feeds `ResolvedService`/`RemovedService`
    /// synchronously on whatever thread `resolve`/`remove` is called from.
    /// `NativeDiscovery` immediately re-dispatches onto its own serial queue,
    /// so callers don't need to simulate any particular queue.
    private final class FakeBrowser: ServiceBrowsing, @unchecked Sendable {
        var onResolve: (@Sendable (ResolvedService) -> Void)?
        var onRemove: (@Sendable (RemovedService) -> Void)?
        var onStateChange: (@Sendable (BrowserState) -> Void)?

        private(set) var startCount = 0
        private(set) var stopCount = 0

        func start() { startCount += 1 }
        func stop() { stopCount += 1 }

        func resolve(_ service: ResolvedService) { onResolve?(service) }
        func remove(_ removed: RemovedService) { onRemove?(removed) }
        func state(_ s: BrowserState) { onStateChange?(s) }
    }

    // MARK: Fixtures

    /// AP2 features: SupportsAirPlayAudio (bit 9) + SupportsCoreUtilsPairingAndEncryption
    /// (bit 38). `0x445F8A00` low word (bit9 set) with high word `0x1C340` (bit 38 = bit 6
    /// of the high word = 0x40 -> included in 0x1C340). We just reuse the exact fixture
    /// already proven against the vendored gate in NativeBackendTests.
    private let ap2Features = "0x445F8A00,0x1C340"
    /// Missing the AP2 bits entirely (a bare/legacy features value).
    private let nonAP2Features = "0x00000000"

    private func airplayService(
        id: String = "AA:BB:CC:DD:EE:01",
        name: String = "Sonos Move",
        model: String = "S13",
        features: String? = nil,
        address: String = "192.168.1.10",
        port: Int = 7000
    ) -> ResolvedService {
        var txt = ["deviceid": id, "model": model]
        if let features { txt["features"] = features }
        return ResolvedService(
            serviceType: .airplay,
            name: name,
            hostname: name,
            address: address,
            family: .ipv4,
            port: port,
            txtRecord: txt
        )
    }

    private func raopService(
        id: String = "AA:BB:CC:DD:EE:99",
        name: String = "Old Express",
        model: String = "AirPort4,107",
        address: String = "192.168.1.20",
        port: Int = 5000
    ) -> ResolvedService {
        ResolvedService(
            serviceType: .raop,
            name: name,
            hostname: name,
            address: address,
            family: .ipv4,
            port: port,
            txtRecord: ["deviceid": id, "model": model]
        )
    }

    // MARK: appear -> update -> disappear (AP2)

    /// An `_airplay._tcp` resolve with valid AP2 feature bits appears as an
    /// AP2-capable device with descriptor fields propagated verbatim, then a
    /// re-resolve with changed facts fires `.updated`, then removal fires
    /// `.disappeared`.
    func testAP2DeviceAppearUpdateDisappear() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()
        XCTAssertEqual(browser.startCount, 1)

        // Appear.
        let service = airplayService(features: ap2Features)
        browser.resolve(service)

        let appeared = events.wait(count: 1)
        guard case .appeared(let device)? = appeared.first else {
            return XCTFail("expected .appeared, got \(appeared)")
        }
        XCTAssertEqual(device.id, "AA:BB:CC:DD:EE:01")
        XCTAssertTrue(device.isAirPlay2Supported)
        XCTAssertEqual(device.descriptor.name, "Sonos Move")
        XCTAssertEqual(device.descriptor.address, "192.168.1.10")
        XCTAssertEqual(device.descriptor.port, 7000)
        XCTAssertEqual(device.descriptor.family, .ipv4)
        XCTAssertEqual(device.descriptor.txtRecord["model"], "S13")
        XCTAssertEqual(device.descriptor.txtRecord["deviceid"], "AA:BB:CC:DD:EE:01")
        XCTAssertEqual(device.outputID.rawValue, 0xAABBCCDDEE01)

        // Update: same device, changed port (re-resolve with new facts).
        let moved = airplayService(features: ap2Features, port: 7001)
        browser.resolve(moved)
        let updated = events.wait(count: 2)
        guard case .updated(let updatedDevice)? = updated.last else {
            return XCTFail("expected .updated, got \(updated)")
        }
        XCTAssertEqual(updatedDevice.descriptor.port, 7001)
        XCTAssertEqual(updatedDevice.id, "AA:BB:CC:DD:EE:01")

        // Disappear.
        browser.remove(RemovedService(serviceType: .airplay, deviceID: "AA:BB:CC:DD:EE:01", name: "Sonos Move"))
        let disappeared = events.wait(count: 3)
        guard case .disappeared(let id, let wasAP2)? = disappeared.last else {
            return XCTFail("expected .disappeared, got \(disappeared)")
        }
        XCTAssertEqual(id, "AA:BB:CC:DD:EE:01")
        XCTAssertTrue(wasAP2)

        // Snapshot is empty after disappear.
        XCTAssertTrue(discovery.devices.isEmpty)

        discovery.stop()
        XCTAssertEqual(browser.stopCount, 1)
    }

    // MARK: appear -> update -> disappear (AP1-only)

    /// A `_raop._tcp`-only resolve appears as AP1-only (never AP2), survives a
    /// re-resolve with changed facts as `.updated`, and disappears cleanly.
    func testAP1OnlyDeviceAppearUpdateDisappear() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        let service = raopService()
        browser.resolve(service)

        let appeared = events.wait(count: 1)
        guard case .appeared(let device)? = appeared.first else {
            return XCTFail("expected .appeared, got \(appeared)")
        }
        XCTAssertEqual(device.id, "AA:BB:CC:DD:EE:99")
        XCTAssertFalse(device.isAirPlay2Supported, "raop-only device must classify AP1-only")
        XCTAssertEqual(device.descriptor.name, "Old Express")
        XCTAssertEqual(device.descriptor.address, "192.168.1.20")
        XCTAssertEqual(device.descriptor.port, 5000)

        // Update: re-resolve with a changed address.
        let moved = raopService(address: "192.168.1.21")
        browser.resolve(moved)
        let updated = events.wait(count: 2)
        guard case .updated(let updatedDevice)? = updated.last else {
            return XCTFail("expected .updated, got \(updated)")
        }
        XCTAssertEqual(updatedDevice.descriptor.address, "192.168.1.21")
        XCTAssertFalse(updatedDevice.isAirPlay2Supported)

        // Disappear.
        browser.remove(RemovedService(serviceType: .raop, deviceID: "AA:BB:CC:DD:EE:99", name: "Old Express"))
        let disappeared = events.wait(count: 3)
        guard case .disappeared(let id, let wasAP2)? = disappeared.last else {
            return XCTFail("expected .disappeared, got \(disappeared)")
        }
        XCTAssertEqual(id, "AA:BB:CC:DD:EE:99")
        XCTAssertFalse(wasAP2)

        discovery.stop()
    }

    // MARK: Descriptor field assertions

    /// Every descriptor field (name/hostname/address/family/port/txt) is carried
    /// through from the resolved service to the discovered device untouched.
    func testDescriptorFieldsPropagateVerbatim() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        var service = airplayService(features: ap2Features)
        service.hostname = "sonos-move.local"
        service.family = .ipv6
        service.address = "fe80::1"
        browser.resolve(service)

        guard case .appeared(let device)? = events.wait(count: 1).first else {
            return XCTFail("expected .appeared")
        }
        XCTAssertEqual(device.descriptor.hostname, "sonos-move.local")
        XCTAssertEqual(device.descriptor.family, .ipv6)
        XCTAssertEqual(device.descriptor.address, "fe80::1")
        XCTAssertEqual(device.descriptor.txtRecord, service.txtRecord)

        discovery.stop()
    }

    // MARK: AP2/AP1 classification

    /// A device advertising `_airplay._tcp` but WITHOUT valid AP2 feature bits
    /// (missing audio-support or core-utils-pairing bit) classifies as AP1-only,
    /// not AP2 — the classifier is bit-exact, not "advertises airplay at all."
    func testAirplayServiceWithoutAP2BitsClassifiesAsAP1Only() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        browser.resolve(airplayService(features: nonAP2Features))

        guard case .appeared(let device)? = events.wait(count: 1).first else {
            return XCTFail("expected .appeared")
        }
        XCTAssertFalse(device.isAirPlay2Supported, "features without AP2 bits must classify AP1-only")

        discovery.stop()
    }

    /// A device advertising `_airplay._tcp` with NO `features` TXT key at all
    /// (missing key, not just missing bits) also classifies AP1-only.
    func testAirplayServiceMissingFeaturesKeyClassifiesAsAP1Only() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        browser.resolve(airplayService(features: nil))

        guard case .appeared(let device)? = events.wait(count: 1).first else {
            return XCTFail("expected .appeared")
        }
        XCTAssertFalse(device.isAirPlay2Supported)

        discovery.stop()
    }

    /// Direct unit coverage of the classifier (pure/static): a nil airplay
    /// advertisement (raop-only) always classifies AP1-only.
    func testClassifyNilAirplayIsAP1Only() {
        XCTAssertFalse(NativeDiscovery.classify(airplay: nil))
    }

    func testParseFeaturesSingleHexValue() {
        // Bit 9 set only (no core-utils bit) -> valid parse, not AP2 on its own.
        XCTAssertEqual(NativeDiscovery.parseFeatures("0x00000200"), 0x200)
    }

    func testParseFeaturesTwoPartHexValue() {
        let parsed = NativeDiscovery.parseFeatures("0x445F8A00,0x1C340")
        XCTAssertEqual(parsed, UInt64(0x445F8A00) | (UInt64(0x1C340) << 32))
    }

    func testParseFeaturesInvalidReturnsNil() {
        XCTAssertNil(NativeDiscovery.parseFeatures("not-hex"))
    }

    // MARK: Colon-hex id round-trip

    /// The colon-hex `deviceid` TXT value is passed through verbatim — never
    /// re-cased, re-punctuated, or reconstructed from the parsed `OutputID` —
    /// while the `OutputID` itself is the correct parse of the hex value.
    func testColonHexIDRoundTripNeverReformatted() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        // Deliberately mixed-case, exact input the test asserts comes back unchanged.
        let rawID = "aA:bB:11:22:Ff:00"
        browser.resolve(airplayService(id: rawID, features: ap2Features))

        guard case .appeared(let device)? = events.wait(count: 1).first else {
            return XCTFail("expected .appeared")
        }
        XCTAssertEqual(device.id, rawID, "the colon-hex id must be passed through verbatim, never reformatted")
        XCTAssertEqual(device.descriptor.txtRecord["deviceid"], rawID)
        XCTAssertEqual(device.outputID.rawValue, UInt64("aAbB1122Ff00", radix: 16)!)

        discovery.stop()
    }

    /// `parseDeviceID` directly: verbatim id string out, correctly parsed OutputID.
    func testParseDeviceIDDirect() {
        let parsed = NativeDiscovery.parseDeviceID(["deviceid": "AA:BB:CC:DD:EE:FF"])
        XCTAssertEqual(parsed?.id, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(parsed?.outputID.rawValue, 0xAABBCCDDEEFF)
    }

    /// A TXT record with no `deviceid` key at all is dropped (nothing downstream
    /// can key on it) — `parseDeviceID` returns nil and no event fires.
    func testMissingDeviceIDIsDropped() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        var service = airplayService(features: ap2Features)
        service.txtRecord.removeValue(forKey: "deviceid")
        browser.resolve(service)

        // Give the serial queue a beat, then assert nothing arrived.
        let none = events.waitNone(timeout: 0.3)
        XCTAssertTrue(none, "a resolve without a parseable deviceid must be dropped, not surfaced")

        discovery.stop()
    }

    // MARK: De-dupe of a device advertising both service types

    /// A device that advertises BOTH `_airplay._tcp` and `_raop._tcp` (the common
    /// real-world case for AP2 receivers) is de-duped to ONE `DiscoveredDevice`,
    /// classified AP2 (the airplay advert wins), and only fully disappears once
    /// BOTH adverts are gone — losing just the airplay side flips it to an
    /// `.updated` AP1-only, not a removal.
    func testDedupesDeviceAdvertisingBothServiceTypes() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        let id = "AA:BB:CC:DD:EE:55"
        browser.resolve(airplayService(id: id, name: "Both", features: ap2Features))
        let firstBatch = events.wait(count: 1)
        guard case .appeared(let first)? = firstBatch.first else {
            return XCTFail("expected .appeared")
        }
        XCTAssertTrue(first.isAirPlay2Supported)

        // The same device also resolves on _raop._tcp. Since the rebuilt device
        // (still AP2, airplay descriptor still wins) is unchanged, NO additional
        // event should fire (duplicate-resolve suppression) — still exactly one
        // event total and exactly one device in the snapshot.
        browser.resolve(raopService(id: id, name: "Both"))
        // Give the serial queue a beat to process, then assert no NEW event.
        let stillOne = events.waitCountStaysAt(1, timeout: 0.3)
        XCTAssertTrue(stillOne, "an unchanged rebuild after de-dupe must not emit a spurious event")

        XCTAssertEqual(discovery.devices.count, 1, "one device, not two, despite two service types")
        XCTAssertEqual(discovery.devices.first?.id, id)
        XCTAssertTrue(discovery.devices.first?.isAirPlay2Supported ?? false)

        // Losing the _airplay._tcp advert alone (still has _raop._tcp) flips it to
        // AP1-only via .updated, NOT a removal.
        browser.remove(RemovedService(serviceType: .airplay, deviceID: id, name: "Both"))
        let flipped = events.wait(count: 2)
        guard case .updated(let updated)? = flipped.last else {
            return XCTFail("expected .updated (AP2->AP1 flip), got \(flipped)")
        }
        XCTAssertFalse(updated.isAirPlay2Supported, "losing the airplay advert (raop still present) must flip to AP1-only")
        XCTAssertEqual(discovery.devices.count, 1, "device must still be present, not removed, after losing only one advert")

        // Now losing the remaining _raop._tcp advert removes it entirely.
        browser.remove(RemovedService(serviceType: .raop, deviceID: id, name: "Both"))
        let gone = events.wait(count: 3)
        guard case .disappeared(let goneID, let wasAP2)? = gone.last else {
            return XCTFail("expected .disappeared, got \(gone)")
        }
        XCTAssertEqual(goneID, id)
        XCTAssertFalse(wasAP2, "by the time it fully disappeared it had already flipped to AP1-only")
        XCTAssertTrue(discovery.devices.isEmpty)

        discovery.stop()
    }

    /// A device that resolves `_raop._tcp` FIRST and then gains `_airplay._tcp`
    /// (the opposite order) is still de-duped to one device and flips AP1 -> AP2
    /// via `.updated`.
    func testDedupeRaopFirstThenAirplayUpgrade() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        let id = "AA:BB:CC:DD:EE:66"
        browser.resolve(raopService(id: id, name: "Upgrader"))
        guard case .appeared(let first)? = events.wait(count: 1).first else {
            return XCTFail("expected .appeared")
        }
        XCTAssertFalse(first.isAirPlay2Supported)

        browser.resolve(airplayService(id: id, name: "Upgrader", features: ap2Features))
        guard case .updated(let upgraded)? = events.wait(count: 2).last else {
            return XCTFail("expected .updated")
        }
        XCTAssertTrue(upgraded.isAirPlay2Supported, "gaining the airplay advert must flip AP1 -> AP2")
        XCTAssertEqual(discovery.devices.count, 1)

        discovery.stop()
    }

    // MARK: Instance-name MAC-prefix fallback (no deviceid TXT)

    /// A `_raop._tcp` service that carries a MAC-prefixed instance name
    /// ("6B2E52B73717@Dev Speaker") but NO `deviceid` TXT key — the shape real
    /// shairport-sync AP1 receivers advertise. No TXT deviceid at all.
    private func raopNameDerivedService(
        name: String,
        model: String? = nil,
        address: String = "192.168.1.42",
        port: Int = 5000
    ) -> ResolvedService {
        var txt: [String: String] = [:]
        if let model { txt["model"] = model }
        return ResolvedService(
            serviceType: .raop,
            name: name,
            hostname: name,
            address: address,
            family: .ipv4,
            port: port,
            txtRecord: txt
        )
    }

    /// (a) A raop-only resolve with NO `deviceid` TXT key but a MAC-prefixed
    /// Bonjour instance name is surfaced as AP1-only, with the id DERIVED from the
    /// 12-hex-digit name prefix in canonical uppercase colon-hex — not dropped.
    /// This is the D6-violating bug the fix repairs: real shairport-sync speakers
    /// advertise exactly this TXT shape.
    func testRaopNameDerivedIDSurfacesAsAP1Only() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        // Instance name is the exact real-world form: 12 hex digits, then "@Name".
        browser.resolve(raopNameDerivedService(name: "6B2E52B73717@Dev Speaker"))

        guard case .appeared(let device)? = events.wait(count: 1).first else {
            return XCTFail("expected .appeared for a name-derived raop device (must NOT be dropped)")
        }
        // Derived id canonicalized to uppercase colon-hex.
        XCTAssertEqual(device.id, "6B:2E:52:B7:37:17")
        XCTAssertEqual(device.outputID.rawValue, 0x6B2E52B73717)
        XCTAssertFalse(device.isAirPlay2Supported, "a raop-only device must classify AP1-only")
        // The human-readable name (after the "@") stays the descriptor name.
        XCTAssertEqual(device.descriptor.name, "6B2E52B73717@Dev Speaker")
        XCTAssertEqual(device.descriptor.address, "192.168.1.42")

        discovery.stop()
    }

    /// (b) The SAME physical device advertising `_raop._tcp` (name-derived id) and
    /// then `_airplay._tcp` (deviceid TXT in canonical uppercase colon-hex) de-dupes
    /// into ONE device that flips AP1 -> AP2 — regardless of arrival order. The
    /// name-derived canonical form must equal the TXT deviceid form for the merge.
    func testNameDerivedRaopThenAirplayTXTDedupesToOneAP2() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        let canonicalID = "6B:2E:52:B7:37:17"
        // raop first, name-derived (no deviceid TXT).
        browser.resolve(raopNameDerivedService(name: "6B2E52B73717@Combo"))
        guard case .appeared(let first)? = events.wait(count: 1).first else {
            return XCTFail("expected .appeared")
        }
        XCTAssertEqual(first.id, canonicalID)
        XCTAssertFalse(first.isAirPlay2Supported)

        // Same device, now on _airplay._tcp with a deviceid TXT that matches the
        // derived canonical form. Must MERGE (one device) and flip to AP2.
        browser.resolve(airplayService(id: canonicalID, name: "Combo", features: ap2Features))
        guard case .updated(let upgraded)? = events.wait(count: 2).last else {
            return XCTFail("expected .updated (AP1 -> AP2 merge)")
        }
        XCTAssertEqual(upgraded.id, canonicalID)
        XCTAssertTrue(upgraded.isAirPlay2Supported, "gaining a matching airplay advert must flip to AP2")
        XCTAssertEqual(discovery.devices.count, 1, "name-derived raop + deviceid-TXT airplay must be ONE device")

        discovery.stop()
    }

    /// (b, reversed order) The SAME device advertising `_airplay._tcp` (deviceid
    /// TXT) FIRST and then `_raop._tcp` (name-derived) still de-dupes to one AP2
    /// device — the later name-derived resolve must not spawn a phantom second
    /// device.
    func testAirplayTXTThenNameDerivedRaopDedupesToOneAP2() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        let canonicalID = "6B:2E:52:B7:37:17"
        browser.resolve(airplayService(id: canonicalID, name: "Combo", features: ap2Features))
        guard case .appeared(let first)? = events.wait(count: 1).first else {
            return XCTFail("expected .appeared")
        }
        XCTAssertTrue(first.isAirPlay2Supported)

        // Same device also on _raop._tcp, name-derived. Rebuilt device is unchanged
        // (airplay descriptor still wins, still AP2), so no NEW event should fire.
        browser.resolve(raopNameDerivedService(name: "6B2E52B73717@Combo"))
        let stillOne = events.waitCountStaysAt(1, timeout: 0.3)
        XCTAssertTrue(stillOne, "an unchanged rebuild after name-derived de-dupe must not emit a spurious event")
        XCTAssertEqual(discovery.devices.count, 1, "one device, not two, despite two service types")
        XCTAssertEqual(discovery.devices.first?.id, canonicalID)
        XCTAssertTrue(discovery.devices.first?.isAirPlay2Supported ?? false)

        discovery.stop()
    }

    /// (c) A resolve with NEITHER a `deviceid` TXT NOR a MAC-prefixed instance name
    /// (a bare human-readable name like "Living Room") is dropped — no id can be
    /// keyed on it — and no event fires and nothing crashes.
    func testNeitherTXTNorNamePrefixIsDroppedNoCrash() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        // No deviceid TXT, and the name has no 12-hex-digit MAC prefix.
        browser.resolve(raopNameDerivedService(name: "Living Room"))
        // A name with an "@" but a non-12-hex prefix must also be dropped.
        browser.resolve(raopNameDerivedService(name: "notahexmac@Kitchen"))
        // An "@"-prefixed name whose prefix is the wrong length is dropped too.
        browser.resolve(raopNameDerivedService(name: "6B2E52@Short"))

        let none = events.waitNone(timeout: 0.3)
        XCTAssertTrue(none, "a resolve with no derivable id must be dropped, not surfaced")
        XCTAssertTrue(discovery.devices.isEmpty)

        discovery.stop()
    }

    /// (d) A mixed-case hex prefix in the instance name round-trips to the same
    /// canonical uppercase colon-hex id (and correct OutputID) as its uppercase
    /// equivalent — the derivation is case-insensitive on input, canonical on output.
    func testMixedCaseNamePrefixRoundTripsToCanonicalUppercase() {
        // Direct derivation unit check: mixed-case in, uppercase colon-hex out.
        let mixed = NativeDiscovery.deriveIDFromInstanceName("6b2e52B73717@Dev Speaker")
        XCTAssertEqual(mixed?.id, "6B:2E:52:B7:37:17")
        XCTAssertEqual(mixed?.outputID.rawValue, 0x6B2E52B73717)

        // A bare name with no "@" but a valid 12-hex body also derives (some
        // stacks omit the "@Name" suffix entirely).
        let bare = NativeDiscovery.deriveIDFromInstanceName("aabbccddeeff")
        XCTAssertEqual(bare?.id, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(bare?.outputID.rawValue, 0xAABBCCDDEEFF)

        // Non-hex and wrong-length prefixes derive nothing.
        XCTAssertNil(NativeDiscovery.deriveIDFromInstanceName("Living Room"))
        XCTAssertNil(NativeDiscovery.deriveIDFromInstanceName("zzzzzzzzzzzz@X"))
        XCTAssertNil(NativeDiscovery.deriveIDFromInstanceName("6B2E52B7371@X")) // 11 digits

        // Through the full pipeline: mixed-case name and an uppercase deviceid-TXT
        // airplay advert for the same device merge (canonical forms are identical).
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        browser.resolve(raopNameDerivedService(name: "6b2e52b73717@Combo"))
        guard case .appeared(let d)? = events.wait(count: 1).first else {
            return XCTFail("expected .appeared")
        }
        XCTAssertEqual(d.id, "6B:2E:52:B7:37:17")
        browser.resolve(airplayService(id: "6B:2E:52:B7:37:17", name: "Combo", features: ap2Features))
        _ = events.wait(count: 2)
        XCTAssertEqual(discovery.devices.count, 1, "mixed-case name-derived id must merge with the uppercase TXT id")

        discovery.stop()
    }

    // MARK: Snapshot before any events

    /// `devices` reflects the current known set synchronously (used for first
    /// paint), independent of the event stream.
    func testDevicesSnapshotReflectsKnownSet() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        discovery.start()

        XCTAssertTrue(discovery.devices.isEmpty)
        browser.resolve(airplayService(features: ap2Features))
        browser.resolve(raopService())

        // Poll the synchronous snapshot (no callback needed) until both land.
        let deadline = Date().addingTimeInterval(2)
        while discovery.devices.count < 2 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(discovery.devices.count, 2)
        XCTAssertEqual(Set(discovery.devices.map(\.id)), Set(["AA:BB:CC:DD:EE:01", "AA:BB:CC:DD:EE:99"]))

        discovery.stop()
    }
}

// MARK: - EventCollector

/// Thread-safe collector for `DiscoveryEvent`s fired on `NativeDiscovery`'s
/// private serial queue, with polling waits (no expectation ceremony needed
/// since events are synchronous/fast on the injected double).
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiscoveryEvent] = []

    func append(_ event: DiscoveryEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    private func snapshot() -> [DiscoveryEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    /// Poll until at least `count` events have arrived (or timeout), then
    /// return the snapshot.
    @discardableResult
    func wait(count: Int, timeout: TimeInterval = 3) -> [DiscoveryEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while snapshot().count < count && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        return snapshot()
    }

    /// Assert that no event arrives within `timeout`. Returns true if none did.
    func waitNone(timeout: TimeInterval) -> Bool {
        Thread.sleep(forTimeInterval: timeout)
        return snapshot().isEmpty
    }

    /// Assert the event count stays exactly `count` for the duration of `timeout`
    /// (used to prove a duplicate-resolve/rebuild produced no spurious event).
    func waitCountStaysAt(_ count: Int, timeout: TimeInterval) -> Bool {
        Thread.sleep(forTimeInterval: timeout)
        return snapshot().count == count
    }
}
