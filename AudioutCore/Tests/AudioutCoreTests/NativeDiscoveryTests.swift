import Foundation
import Testing
import AirPlayEngine
@testable import AudioutCore

/// Hermetic tests for ``NativeDiscovery`` (T-NB-DISCOVERY-1): an injected
/// ``ServiceBrowsing`` double drives resolve/remove synchronously. No
/// `NWBrowser`, no network, no TCC.
///
/// Covers: appear→update→disappear for an AP2 device and an AP1-only device,
/// descriptor field propagation, AP2/AP1 classification (mirroring the
/// vendored feature-bit gate), the colon-hex id round-trip (never
/// reformatted), and de-dupe of a device advertising both `_airplay._tcp`
/// and `_raop._tcp`.
@Suite struct NativeDiscoveryTests {

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

    /// Self-receiver filter (the owner's call, 2026-08-07): a service announced
    /// under THIS machine's own mDNS hostname — macOS's AirPlay Receiver on the
    /// Mac the app runs on — is dropped before it ever becomes an event, for both
    /// service types, with hostname matching that survives Bonjour's trailing dot
    /// and mDNS case-insensitivity. A same-named service from a DIFFERENT host
    /// (the real second-Mac case) still surfaces. Ordering on the discovery queue
    /// makes the assertion airtight: the self resolves are processed before the
    /// real one, so a single .appeared event proves they produced nothing.
    @Test func selfHostnameServicesAreNeverSurfaced() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser, localHostname: "my-test-mac.local")
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        // This Mac's own receiver: announce form differs by CASE and the
        // trailing dot — both must still match (normalizedHostname).
        var selfService = airplayService(id: "EE:CF:9C:BE:22:88", name: "My Test Mac",
                                         features: ap2Features)
        selfService.hostname = "My-Test-Mac.local."
        browser.resolve(selfService)
        var selfRaop = selfService
        selfRaop.serviceType = .raop
        browser.resolve(selfRaop)

        // A different host — surfaces normally even though everything else about
        // it is ordinary.
        var speaker = airplayService(id: "AA:BB:CC:DD:EE:07", name: "Real Speaker",
                                     features: ap2Features)
        speaker.hostname = "sonos-move.local."
        browser.resolve(speaker)

        let received = events.wait(count: 1)
        guard case .appeared(let device)? = received.first else {
            Issue.record("expected exactly the real speaker's .appeared, got \(received)")
            return
        }
        #expect(device.id == "AA:BB:CC:DD:EE:07",
                "only the non-self host surfaced; the self receiver produced no event")
        #expect(discovery.devices.map(\.id) == ["AA:BB:CC:DD:EE:07"],
                "the self receiver never entered the known set either")
    }

    /// An `_airplay._tcp` resolve with valid AP2 feature bits appears as an
    /// AP2-capable device with descriptor fields propagated verbatim, then a
    /// re-resolve with changed facts fires `.updated`, then removal fires
    /// `.disappeared`.
    @Test func ap2DeviceAppearUpdateDisappear() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()
        #expect(browser.startCount == 1)

        // Appear.
        let service = airplayService(features: ap2Features)
        browser.resolve(service)

        let appeared = events.wait(count: 1)
        guard case .appeared(let device)? = appeared.first else {
            Issue.record("expected .appeared, got \(appeared)")
            return
        }
        #expect(device.id == "AA:BB:CC:DD:EE:01")
        #expect(device.isAirPlay2Supported)
        #expect(device.descriptor.name == "Sonos Move")
        #expect(device.descriptor.address == "192.168.1.10")
        #expect(device.descriptor.port == 7000)
        #expect(device.descriptor.family == .ipv4)
        #expect(device.descriptor.txtRecord["model"] == "S13")
        #expect(device.descriptor.txtRecord["deviceid"] == "AA:BB:CC:DD:EE:01")
        #expect(device.outputID.rawValue == 0xAABBCCDDEE01)

        // Update: same device, changed port (re-resolve with new facts).
        let moved = airplayService(features: ap2Features, port: 7001)
        browser.resolve(moved)
        let updated = events.wait(count: 2)
        guard case .updated(let updatedDevice)? = updated.last else {
            Issue.record("expected .updated, got \(updated)")
            return
        }
        #expect(updatedDevice.descriptor.port == 7001)
        #expect(updatedDevice.id == "AA:BB:CC:DD:EE:01")

        // Disappear.
        browser.remove(RemovedService(serviceType: .airplay, deviceID: "AA:BB:CC:DD:EE:01", name: "Sonos Move"))
        let disappeared = events.wait(count: 3)
        guard case .disappeared(let id, let wasAP2)? = disappeared.last else {
            Issue.record("expected .disappeared, got \(disappeared)")
            return
        }
        #expect(id == "AA:BB:CC:DD:EE:01")
        #expect(wasAP2)

        // Snapshot is empty after disappear.
        #expect(discovery.devices.isEmpty)

        discovery.stop()
        #expect(browser.stopCount == 1)
    }

    // MARK: appear -> update -> disappear (AP1-only)

    /// A `_raop._tcp`-only resolve appears as AP1-only (never AP2), survives a
    /// re-resolve with changed facts as `.updated`, and disappears cleanly.
    @Test func ap1OnlyDeviceAppearUpdateDisappear() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        let service = raopService()
        browser.resolve(service)

        let appeared = events.wait(count: 1)
        guard case .appeared(let device)? = appeared.first else {
            Issue.record("expected .appeared, got \(appeared)")
            return
        }
        #expect(device.id == "AA:BB:CC:DD:EE:99")
        #expect(!device.isAirPlay2Supported, "raop-only device must classify AP1-only")
        #expect(device.descriptor.name == "Old Express")
        #expect(device.descriptor.address == "192.168.1.20")
        #expect(device.descriptor.port == 5000)

        // Update: re-resolve with a changed address.
        let moved = raopService(address: "192.168.1.21")
        browser.resolve(moved)
        let updated = events.wait(count: 2)
        guard case .updated(let updatedDevice)? = updated.last else {
            Issue.record("expected .updated, got \(updated)")
            return
        }
        #expect(updatedDevice.descriptor.address == "192.168.1.21")
        #expect(!updatedDevice.isAirPlay2Supported)

        // Disappear.
        browser.remove(RemovedService(serviceType: .raop, deviceID: "AA:BB:CC:DD:EE:99", name: "Old Express"))
        let disappeared = events.wait(count: 3)
        guard case .disappeared(let id, let wasAP2)? = disappeared.last else {
            Issue.record("expected .disappeared, got \(disappeared)")
            return
        }
        #expect(id == "AA:BB:CC:DD:EE:99")
        #expect(!wasAP2)

        discovery.stop()
    }

    // MARK: Descriptor field assertions

    /// Every descriptor field (name/hostname/address/family/port/txt) is carried
    /// through from the resolved service to the discovered device untouched.
    @Test func descriptorFieldsPropagateVerbatim() {
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
            Issue.record("expected .appeared")
            return
        }
        #expect(device.descriptor.hostname == "sonos-move.local")
        #expect(device.descriptor.family == .ipv6)
        #expect(device.descriptor.address == "fe80::1")
        #expect(device.descriptor.txtRecord == service.txtRecord)

        discovery.stop()
    }

    // MARK: AP2/AP1 classification

    /// A device advertising `_airplay._tcp` but WITHOUT valid AP2 feature bits
    /// (missing audio-support or core-utils-pairing bit) classifies as AP1-only,
    /// not AP2 — the classifier is bit-exact, not "advertises airplay at all."
    @Test func airplayServiceWithoutAP2BitsClassifiesAsAP1Only() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        browser.resolve(airplayService(features: nonAP2Features))

        guard case .appeared(let device)? = events.wait(count: 1).first else {
            Issue.record("expected .appeared")
            return
        }
        #expect(!device.isAirPlay2Supported, "features without AP2 bits must classify AP1-only")

        discovery.stop()
    }

    /// A device advertising `_airplay._tcp` with NO `features` TXT key at all
    /// (missing key, not just missing bits) also classifies AP1-only.
    @Test func airplayServiceMissingFeaturesKeyClassifiesAsAP1Only() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        browser.resolve(airplayService(features: nil))

        guard case .appeared(let device)? = events.wait(count: 1).first else {
            Issue.record("expected .appeared")
            return
        }
        #expect(!device.isAirPlay2Supported)

        discovery.stop()
    }

    /// Direct unit coverage of the classifier (pure/static): a nil airplay
    /// advertisement (raop-only) always classifies AP1-only.
    @Test func classifyNilAirplayIsAP1Only() {
        #expect(!NativeDiscovery.classify(airplay: nil))
    }

    @Test func parseFeaturesSingleHexValue() {
        // Bit 9 set only (no core-utils bit) -> valid parse, not AP2 on its own.
        #expect(NativeDiscovery.parseFeatures("0x00000200") == 0x200)
    }

    @Test func parseFeaturesTwoPartHexValue() {
        let parsed = NativeDiscovery.parseFeatures("0x445F8A00,0x1C340")
        #expect(parsed == UInt64(0x445F8A00) | (UInt64(0x1C340) << 32))
    }

    @Test func parseFeaturesInvalidReturnsNil() {
        #expect(NativeDiscovery.parseFeatures("not-hex") == nil)
    }

    // MARK: Colon-hex id round-trip

    /// The colon-hex `deviceid` TXT value is passed through verbatim — never
    /// re-cased, re-punctuated, or reconstructed from the parsed `OutputID` —
    /// while the `OutputID` itself is the correct parse of the hex value.
    @Test func colonHexIDRoundTripNeverReformatted() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        // Deliberately mixed-case, exact input the test asserts comes back unchanged.
        let rawID = "aA:bB:11:22:Ff:00"
        browser.resolve(airplayService(id: rawID, features: ap2Features))

        guard case .appeared(let device)? = events.wait(count: 1).first else {
            Issue.record("expected .appeared")
            return
        }
        #expect(device.id == rawID, "the colon-hex id must be passed through verbatim, never reformatted")
        #expect(device.descriptor.txtRecord["deviceid"] == rawID)
        #expect(device.outputID.rawValue == UInt64("aAbB1122Ff00", radix: 16)!)

        discovery.stop()
    }

    /// `parseDeviceID` directly: verbatim id string out, correctly parsed OutputID.
    @Test func parseDeviceIDDirect() {
        let parsed = NativeDiscovery.parseDeviceID(["deviceid": "AA:BB:CC:DD:EE:FF"])
        #expect(parsed?.id == "AA:BB:CC:DD:EE:FF")
        #expect(parsed?.outputID.rawValue == 0xAABBCCDDEEFF)
    }

    /// A TXT record with no `deviceid` key at all is dropped (nothing downstream
    /// can key on it) — `parseDeviceID` returns nil and no event fires.
    @Test func missingDeviceIDIsDropped() {
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
        #expect(none, "a resolve without a parseable deviceid must be dropped, not surfaced")

        discovery.stop()
    }

    // MARK: De-dupe of a device advertising both service types

    /// A device that advertises BOTH `_airplay._tcp` and `_raop._tcp` (the common
    /// real-world case for AP2 receivers) is de-duped to ONE `DiscoveredDevice`,
    /// classified AP2 (the airplay advert wins), and only fully disappears once
    /// BOTH adverts are gone. Losing just the airplay side marks it OFFLINE
    /// (`.updated`, `isAvailable == false`) while STAYING AP2 — a real AP2
    /// receiver powering off (its `_raop._tcp` lingers longer than its
    /// `_airplay._tcp`), NOT an AP1 downgrade — not a removal.
    @Test func dedupesDeviceAdvertisingBothServiceTypes() {
        let browser = FakeBrowser()
        // Short grace: asserts the sustained-offline transition, not the debounce.
        let discovery = NativeDiscovery(browser: browser, vanishGrace: 0.05)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        let id = "AA:BB:CC:DD:EE:55"
        browser.resolve(airplayService(id: id, name: "Both", features: ap2Features))
        let firstBatch = events.wait(count: 1)
        guard case .appeared(let first)? = firstBatch.first else {
            Issue.record("expected .appeared")
            return
        }
        #expect(first.isAirPlay2Supported)

        // The same device also resolves on _raop._tcp. Since the rebuilt device
        // (still AP2, airplay descriptor still wins) is unchanged, NO additional
        // event should fire (duplicate-resolve suppression) — still exactly one
        // event total and exactly one device in the snapshot.
        browser.resolve(raopService(id: id, name: "Both"))
        // Give the serial queue a beat to process, then assert no NEW event.
        let stillOne = events.waitCountStaysAt(1, timeout: 0.3)
        #expect(stillOne, "an unchanged rebuild after de-dupe must not emit a spurious event")

        #expect(discovery.devices.count == 1, "one device, not two, despite two service types")
        #expect(discovery.devices.first?.id == id)
        #expect(discovery.devices.first?.isAirPlay2Supported ?? false)

        // Losing the _airplay._tcp advert alone (still has _raop._tcp) marks it
        // OFFLINE via .updated — STAYS AP2 (sticky), becomes unavailable. NOT an
        // AP1 downgrade, NOT a removal.
        browser.remove(RemovedService(serviceType: .airplay, deviceID: id, name: "Both"))
        let flipped = events.wait(count: 2)
        guard case .updated(let updated)? = flipped.last else {
            Issue.record("expected .updated (AP2 offline), got \(flipped)")
            return
        }
        #expect(updated.isAirPlay2Supported, "losing the airplay advert must NOT downgrade a sticky-AP2 device to AP1")
        #expect(!updated.isAvailable, "losing the airplay advert (raop still present) marks a sticky-AP2 device offline")
        #expect(discovery.devices.count == 1, "device must still be present, not removed, after losing only one advert")

        // Now losing the remaining _raop._tcp advert removes it entirely.
        browser.remove(RemovedService(serviceType: .raop, deviceID: id, name: "Both"))
        let gone = events.wait(count: 3)
        guard case .disappeared(let goneID, let wasAP2)? = gone.last else {
            Issue.record("expected .disappeared, got \(gone)")
            return
        }
        #expect(goneID == id)
        #expect(wasAP2, "a sticky-AP2 device is still AP2 when it fully disappears (engine teardown routes on this)")
        #expect(discovery.devices.isEmpty)

        discovery.stop()
    }

    /// A device that resolves `_raop._tcp` FIRST and then gains `_airplay._tcp`
    /// (the opposite order) is still de-duped to one device and flips AP1 -> AP2
    /// via `.updated`.
    @Test func dedupeRaopFirstThenAirplayUpgrade() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        let id = "AA:BB:CC:DD:EE:66"
        browser.resolve(raopService(id: id, name: "Upgrader"))
        guard case .appeared(let first)? = events.wait(count: 1).first else {
            Issue.record("expected .appeared")
            return
        }
        #expect(!first.isAirPlay2Supported)

        browser.resolve(airplayService(id: id, name: "Upgrader", features: ap2Features))
        guard case .updated(let upgraded)? = events.wait(count: 2).last else {
            Issue.record("expected .updated")
            return
        }
        #expect(upgraded.isAirPlay2Supported, "gaining the airplay advert must flip AP1 -> AP2")
        #expect(discovery.devices.count == 1)

        discovery.stop()
    }

    // MARK: Sticky-AP2 (offline vs downgrade)

    /// THE BUG: an AP2 device (advertising both `_airplay._tcp` and `_raop._tcp`)
    /// whose `_airplay._tcp` record times out while `_raop._tcp` lingers — exactly
    /// what a Sonos Move does when powered off — must be reported as OFFLINE
    /// (`isAvailable == false`) while STAYING AP2 (`isAirPlay2Supported == true`),
    /// NOT reclassified AP1-only. It must NOT `.disappeared` (raop still present).
    @Test func ap2LosingAirplayAdvertGoesOfflineNotAP1() {
        let browser = FakeBrowser()
        // Short grace: asserts the sustained-offline transition, not the debounce.
        let discovery = NativeDiscovery(browser: browser, vanishGrace: 0.05)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        let id = "AA:BB:CC:DD:EE:42"
        // Both adverts present → AP2, available.
        browser.resolve(airplayService(id: id, name: "Sonos Move", features: ap2Features))
        browser.resolve(raopService(id: id, name: "Sonos Move"))
        guard case .appeared(let appeared)? = events.wait(count: 1).first else {
            Issue.record("expected .appeared")
            return
        }
        #expect(appeared.isAirPlay2Supported)
        #expect(appeared.isAvailable)

        // Power off: the `_airplay._tcp` record drops first, `_raop._tcp` lingers.
        browser.remove(RemovedService(serviceType: .airplay, deviceID: id, name: "Sonos Move"))
        guard case .updated(let offline)? = events.wait(count: 2).last else {
            Issue.record("expected .updated when the airplay advert drops")
            return
        }
        #expect(offline.isAirPlay2Supported,
                "a sticky-AP2 device must STAY AP2 when it loses its airplay advert — it went offline, it did not downgrade")
        #expect(!offline.isAvailable,
                "losing the airplay advert (raop lingers) means the AP2 device is OFFLINE")
        #expect(discovery.devices.count == 1, "still present (raop lingers), not disappeared")

        discovery.stop()
    }

    /// A sticky-AP2 device that goes offline (airplay advert dropped) and then
    /// comes back (airplay advert re-resolves) returns to available AP2 — the
    /// sticky bit doesn't wedge it permanently offline.
    @Test func ap2OfflineThenBackOnlineRecoversAvailable() {
        let browser = FakeBrowser()
        // Short grace: asserts the sustained-offline transition, not the debounce.
        let discovery = NativeDiscovery(browser: browser, vanishGrace: 0.05)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        let id = "AA:BB:CC:DD:EE:43"
        browser.resolve(airplayService(id: id, name: "Sonos", features: ap2Features))
        browser.resolve(raopService(id: id, name: "Sonos"))
        _ = events.wait(count: 1)

        browser.remove(RemovedService(serviceType: .airplay, deviceID: id, name: "Sonos"))
        guard case .updated(let offline)? = events.wait(count: 2).last else {
            Issue.record("expected offline .updated")
            return
        }
        #expect(!offline.isAvailable)
        #expect(offline.isAirPlay2Supported)

        // Powers back on: airplay advert re-resolves.
        browser.resolve(airplayService(id: id, name: "Sonos", features: ap2Features))
        guard case .updated(let back)? = events.wait(count: 3).last else {
            Issue.record("expected recovery .updated")
            return
        }
        #expect(back.isAirPlay2Supported)
        #expect(back.isAvailable, "an AP2 device that re-advertises airplay is reachable again")

        discovery.stop()
    }

    // MARK: Airplay-advert-loss grace (mDNS churn debounce)

    /// THE FLAPPING BUG: mDNS drops and re-adds a device's `_airplay._tcp` advert
    /// transiently under normal network churn. A drop that heals within the grace
    /// window must NOT be surfaced as an offline (`.vanished`) transition — no
    /// event, and the row stays available — so a transient blip never deselects
    /// the speaker or tears down its live stream. This is the regression guard
    /// for the `connection:failed` (`vanished`) flapping storm.
    @Test func transientAirplayDropWithinGraceEmitsNoVanish() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser, vanishGrace: 0.3)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        let id = "AA:BB:CC:DD:EE:45"
        browser.resolve(airplayService(id: id, name: "Sonos", features: ap2Features))
        browser.resolve(raopService(id: id, name: "Sonos"))
        _ = events.wait(count: 1)

        // The airplay advert blips out, then re-resolves before the grace fires.
        browser.remove(RemovedService(serviceType: .airplay, deviceID: id, name: "Sonos"))
        browser.resolve(airplayService(id: id, name: "Sonos", features: ap2Features))

        // No offline event ever fires (the re-resolve is an unchanged rebuild, so
        // it is suppressed too) and the grace elapses without surfacing anything.
        #expect(events.waitCountStaysAt(1, timeout: 0.6),
                "a transient airplay-advert drop that heals within the grace must not emit a vanish")
        #expect(discovery.devices.first?.isAvailable == true,
                "the row stays available across a transient blip")

        discovery.stop()
    }

    /// A sustained airplay-advert loss (no re-resolve) IS surfaced once the grace
    /// elapses — the debounce delays a real departure, it does not swallow it. And
    /// it fires exactly once, not on a repeat schedule.
    @Test func sustainedAirplayDropAfterGraceEmitsVanishOnce() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser, vanishGrace: 0.05)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        let id = "AA:BB:CC:DD:EE:46"
        browser.resolve(airplayService(id: id, name: "Sonos", features: ap2Features))
        browser.resolve(raopService(id: id, name: "Sonos"))
        _ = events.wait(count: 1)

        browser.remove(RemovedService(serviceType: .airplay, deviceID: id, name: "Sonos"))
        guard case .updated(let offline)? = events.wait(count: 2).last else {
            Issue.record("expected a vanish .updated once the grace elapses")
            return
        }
        #expect(!offline.isAvailable, "a sustained airplay-advert loss surfaces as offline")
        #expect(offline.isAirPlay2Supported, "still sticky-AP2")
        #expect(events.waitCountStaysAt(2, timeout: 0.2), "the vanish fires once, not on a repeat schedule")

        discovery.stop()
    }

    /// A device that fully disappears (loses BOTH adverts) during the airplay
    /// grace window is reported as `.disappeared`, and the pending vanish is
    /// cancelled — no stale offline `.updated` fires afterwards.
    @Test func fullDisappearDuringGraceCancelsPendingVanish() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser, vanishGrace: 0.3)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        let id = "AA:BB:CC:DD:EE:47"
        browser.resolve(airplayService(id: id, name: "Sonos", features: ap2Features))
        browser.resolve(raopService(id: id, name: "Sonos"))
        _ = events.wait(count: 1)

        // Airplay drops (arms the grace), then raop drops too before it fires.
        browser.remove(RemovedService(serviceType: .airplay, deviceID: id, name: "Sonos"))
        browser.remove(RemovedService(serviceType: .raop, deviceID: id, name: "Sonos"))
        guard case .disappeared(let goneID, _)? = events.wait(count: 2).last else {
            Issue.record("expected .disappeared when both adverts are gone")
            return
        }
        #expect(goneID == id)
        #expect(events.waitCountStaysAt(2, timeout: 0.6),
                "the cancelled grace must not fire a stale offline .updated after disappear")
        #expect(discovery.devices.isEmpty)

        discovery.stop()
    }

    /// A genuine raop-only device (NEVER advertised `_airplay._tcp`) stays
    /// AP1-only and available — the sticky mechanism only affects devices that
    /// were EVER AP2. This is the regression guard for the "coming soon" row.
    @Test func genuineAP1OnlyStaysAP1AndAvailable() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        // raop-only from the start, and a re-resolve — never any airplay advert.
        browser.resolve(raopService(id: "AA:BB:CC:DD:EE:44", name: "Old Express"))
        guard case .appeared(let d)? = events.wait(count: 1).first else {
            Issue.record("expected .appeared")
            return
        }
        #expect(!d.isAirPlay2Supported, "a never-AP2 device must classify AP1-only")
        #expect(d.isAvailable, "a genuine AP1-only device is not marked offline by the sticky mechanism")

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
    @Test func raopNameDerivedIDSurfacesAsAP1Only() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        // Instance name is the exact real-world form: 12 hex digits, then "@Name".
        browser.resolve(raopNameDerivedService(name: "6B2E52B73717@Dev Speaker"))

        guard case .appeared(let device)? = events.wait(count: 1).first else {
            Issue.record("expected .appeared for a name-derived raop device (must NOT be dropped)")
            return
        }
        // Derived id canonicalized to uppercase colon-hex.
        #expect(device.id == "6B:2E:52:B7:37:17")
        #expect(device.outputID.rawValue == 0x6B2E52B73717)
        #expect(!device.isAirPlay2Supported, "a raop-only device must classify AP1-only")
        // The engine-facing descriptor keeps the RAW instance name (with the
        // "<12-hex>@" MAC prefix) so the vendored `raop_device_cb` can re-parse
        // the id from it; the human-facing display name is stripped downstream
        // (`NativeBackend.mapDiscovered`), NOT on the descriptor.
        #expect(device.descriptor.name == "6B2E52B73717@Dev Speaker")
        #expect(NativeDiscovery.strippedRaopDisplayName(device.descriptor.name) == "Dev Speaker")
        #expect(device.descriptor.address == "192.168.1.42")

        discovery.stop()
    }

    /// A raop-only instance name that already lacks the MAC@ prefix (no `deviceid`
    /// TXT, so it's dropped by identity — but `strippedRaopDisplayName` itself
    /// must be a no-op on such names) is returned unchanged.
    @Test func strippedRaopDisplayNameLeavesNameWithoutPrefixUnchanged() {
        #expect(NativeDiscovery.strippedRaopDisplayName("Living Room") == "Living Room")
        #expect(NativeDiscovery.strippedRaopDisplayName("Kitchen Speaker") == "Kitchen Speaker")
    }

    /// Direct unit coverage: the MAC@ prefix is stripped only when it is exactly
    /// 12 hex digits followed by "@"; near-miss shapes (too few/many hex digits,
    /// non-hex characters, no "@" at all) pass through unchanged.
    @Test func strippedRaopDisplayNameEdgeCases() {
        #expect(NativeDiscovery.strippedRaopDisplayName("6B2E52B73717@Dev Speaker") == "Dev Speaker")
        #expect(NativeDiscovery.strippedRaopDisplayName("6b2e52b73717@lowercase") == "lowercase")
        #expect(NativeDiscovery.strippedRaopDisplayName("6B2E52B7371@Eleven") == "6B2E52B7371@Eleven")
        #expect(NativeDiscovery.strippedRaopDisplayName("6B2E52B73717AA@Thirteen") == "6B2E52B73717AA@Thirteen")
        #expect(NativeDiscovery.strippedRaopDisplayName("ZZZZ52B73717@NonHex") == "ZZZZ52B73717@NonHex")
        #expect(NativeDiscovery.strippedRaopDisplayName("6B2E52B73717") == "6B2E52B73717")
    }

    /// A raop-only device keeps the RAW MAC-prefixed instance name on its
    /// engine-facing descriptor ("6B2E52B73717@Dev Speaker"), while the derived id
    /// keeps the full MAC in canonical colon-hex form. The human-facing strip
    /// ("Dev Speaker") is applied downstream, NOT on the descriptor.
    @Test func raopOnlyDisplayNameStripsMACPrefix() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        browser.resolve(raopNameDerivedService(name: "6B2E52B73717@Dev Speaker"))

        guard case .appeared(let device)? = events.wait(count: 1).first else {
            Issue.record("expected .appeared")
            return
        }
        #expect(device.descriptor.name == "6B2E52B73717@Dev Speaker",
                "the engine descriptor must keep the RAW MAC-prefixed name")
        #expect(NativeDiscovery.strippedRaopDisplayName(device.descriptor.name) == "Dev Speaker",
                "the MAC@ prefix is stripped only for the human-facing display name")
        #expect(device.id == "6B:2E:52:B7:37:17", "id derivation must still use the full raw name")
        #expect(device.outputID.rawValue == 0x6B2E52B73717)

        discovery.stop()
    }

    /// REGRESSION GUARD (the bug this fix repairs): a `_raop._tcp`-only
    /// `DiscoveredDevice`'s engine-facing `descriptor.name` MUST still carry the
    /// raw "<12-hex>@<display>" instance-name form. The vendored RAOP backend's
    /// `raop_device_cb` (raop.c) derives the device id from that prefix via
    /// `safe_hextou64(name, &id)` — it reads NO `deviceid` TXT key — so a descriptor
    /// name that had been stripped to just "Dev Speaker" would fail id extraction
    /// and the real receiver would silently never register/connect. This also
    /// asserts the SYNC INVARIANT: the hex prefix `raop.c` re-parses equals the
    /// `OutputID` the Swift side already derived from the same instance name.
    @Test func raopOnlyDescriptorKeepsRawHexPrefixForEngineIDParse() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        browser.resolve(raopNameDerivedService(name: "6B2E52B73717@Dev Speaker"))

        guard case .appeared(let device)? = events.wait(count: 1).first else {
            Issue.record("expected .appeared")
            return
        }
        #expect(!device.isAirPlay2Supported, "sanity: this is a raop-only device")

        // (a) The engine descriptor still carries the 12-hex "@" prefix that
        // `raop_device_cb`'s `safe_hextou64` + `strchr(name, '@')` parse.
        let name = device.descriptor.name
        let parts = name.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        #expect(parts.count == 2, "descriptor name must retain the '@' the C backend looks for")
        let hexPrefix = String(parts[0])
        #expect(hexPrefix.count == 12, "descriptor name must retain the 12-hex id prefix")
        #expect(UInt64(hexPrefix, radix: 16) != nil, "the prefix must be hex-parseable like safe_hextou64 does")

        // (b) SYNC INVARIANT: the hex prefix the C side parses equals the OutputID
        // the Swift side derived from the same instance name.
        #expect(UInt64(hexPrefix, radix: 16) == device.outputID.rawValue)
        #expect(device.outputID.rawValue == 0x6B2E52B73717)

        discovery.stop()
    }

    /// A raop-only device whose instance name has NO MAC@ prefix at all (already
    /// human-readable) is left unchanged — nothing to strip.
    @Test func raopOnlyDisplayNameWithoutPrefixUnchanged() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        // No deviceid TXT and no MAC prefix in the name -> dropped by identity,
        // not surfaced. Use the deviceid-TXT raop fixture instead so the device
        // IS surfaced, with a plain (unprefixed) name.
        browser.resolve(raopService(name: "Old Express"))

        guard case .appeared(let device)? = events.wait(count: 1).first else {
            Issue.record("expected .appeared")
            return
        }
        #expect(device.descriptor.name == "Old Express", "a name with no MAC@ prefix must be unchanged")

        discovery.stop()
    }

    /// A device advertising BOTH `_raop._tcp` (MAC-prefixed name) and
    /// `_airplay._tcp` (plain name, deviceid TXT) keeps the `_airplay._tcp` name
    /// verbatim — the airplay name wins and is never subject to the raop strip,
    /// confirmed regardless of which service resolves first.
    @Test func dualAdvertisedKeepsAirplayNameOverRaopPrefixedName() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        let id = "6B:2E:52:B7:37:17"
        // raop first, with a MAC-prefixed name (as real dual-advertising gear does).
        browser.resolve(raopService(id: id, name: "6B2E52B73717@Raop Name"))
        guard case .appeared(let first)? = events.wait(count: 1).first else {
            Issue.record("expected .appeared")
            return
        }
        #expect(first.descriptor.name == "6B2E52B73717@Raop Name",
                "raop-only so far, so the engine descriptor keeps the RAW MAC-prefixed name")

        // Now the airplay advert resolves with a clean name -- it must win.
        browser.resolve(airplayService(id: id, name: "Airplay Name", features: ap2Features))
        guard case .updated(let merged)? = events.wait(count: 2).last else {
            Issue.record("expected .updated")
            return
        }
        #expect(merged.descriptor.name == "Airplay Name", "the airplay name must win over the raop name once both are present")
        #expect(merged.isAirPlay2Supported)
        #expect(discovery.devices.count == 1)

        discovery.stop()
    }

    /// (b) The SAME physical device advertising `_raop._tcp` (name-derived id) and
    /// then `_airplay._tcp` (deviceid TXT in canonical uppercase colon-hex) de-dupes
    /// into ONE device that flips AP1 -> AP2 — regardless of arrival order. The
    /// name-derived canonical form must equal the TXT deviceid form for the merge.
    @Test func nameDerivedRaopThenAirplayTXTDedupesToOneAP2() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        let canonicalID = "6B:2E:52:B7:37:17"
        // raop first, name-derived (no deviceid TXT).
        browser.resolve(raopNameDerivedService(name: "6B2E52B73717@Combo"))
        guard case .appeared(let first)? = events.wait(count: 1).first else {
            Issue.record("expected .appeared")
            return
        }
        #expect(first.id == canonicalID)
        #expect(!first.isAirPlay2Supported)

        // Same device, now on _airplay._tcp with a deviceid TXT that matches the
        // derived canonical form. Must MERGE (one device) and flip to AP2.
        browser.resolve(airplayService(id: canonicalID, name: "Combo", features: ap2Features))
        guard case .updated(let upgraded)? = events.wait(count: 2).last else {
            Issue.record("expected .updated (AP1 -> AP2 merge)")
            return
        }
        #expect(upgraded.id == canonicalID)
        #expect(upgraded.isAirPlay2Supported, "gaining a matching airplay advert must flip to AP2")
        #expect(discovery.devices.count == 1, "name-derived raop + deviceid-TXT airplay must be ONE device")

        discovery.stop()
    }

    /// (b, reversed order) The SAME device advertising `_airplay._tcp` (deviceid
    /// TXT) FIRST and then `_raop._tcp` (name-derived) still de-dupes to one AP2
    /// device — the later name-derived resolve must not spawn a phantom second
    /// device.
    @Test func airplayTXTThenNameDerivedRaopDedupesToOneAP2() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        let canonicalID = "6B:2E:52:B7:37:17"
        browser.resolve(airplayService(id: canonicalID, name: "Combo", features: ap2Features))
        guard case .appeared(let first)? = events.wait(count: 1).first else {
            Issue.record("expected .appeared")
            return
        }
        #expect(first.isAirPlay2Supported)

        // Same device also on _raop._tcp, name-derived. Rebuilt device is unchanged
        // (airplay descriptor still wins, still AP2), so no NEW event should fire.
        browser.resolve(raopNameDerivedService(name: "6B2E52B73717@Combo"))
        let stillOne = events.waitCountStaysAt(1, timeout: 0.3)
        #expect(stillOne, "an unchanged rebuild after name-derived de-dupe must not emit a spurious event")
        #expect(discovery.devices.count == 1, "one device, not two, despite two service types")
        #expect(discovery.devices.first?.id == canonicalID)
        #expect(discovery.devices.first?.isAirPlay2Supported ?? false)

        discovery.stop()
    }

    /// (c) A resolve with NEITHER a `deviceid` TXT NOR a MAC-prefixed instance name
    /// (a bare human-readable name like "Living Room") is dropped — no id can be
    /// keyed on it — and no event fires and nothing crashes.
    @Test func neitherTXTNorNamePrefixIsDroppedNoCrash() {
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
        #expect(none, "a resolve with no derivable id must be dropped, not surfaced")
        #expect(discovery.devices.isEmpty)

        discovery.stop()
    }

    /// (d) A mixed-case hex prefix in the instance name round-trips to the same
    /// canonical uppercase colon-hex id (and correct OutputID) as its uppercase
    /// equivalent — the derivation is case-insensitive on input, canonical on output.
    @Test func mixedCaseNamePrefixRoundTripsToCanonicalUppercase() {
        // Direct derivation unit check: mixed-case in, uppercase colon-hex out.
        let mixed = NativeDiscovery.deriveIDFromInstanceName("6b2e52B73717@Dev Speaker")
        #expect(mixed?.id == "6B:2E:52:B7:37:17")
        #expect(mixed?.outputID.rawValue == 0x6B2E52B73717)

        // A bare name with no "@" but a valid 12-hex body also derives (some
        // stacks omit the "@Name" suffix entirely).
        let bare = NativeDiscovery.deriveIDFromInstanceName("aabbccddeeff")
        #expect(bare?.id == "AA:BB:CC:DD:EE:FF")
        #expect(bare?.outputID.rawValue == 0xAABBCCDDEEFF)

        // Non-hex and wrong-length prefixes derive nothing.
        #expect(NativeDiscovery.deriveIDFromInstanceName("Living Room") == nil)
        #expect(NativeDiscovery.deriveIDFromInstanceName("zzzzzzzzzzzz@X") == nil)
        #expect(NativeDiscovery.deriveIDFromInstanceName("6B2E52B7371@X") == nil) // 11 digits

        // Through the full pipeline: mixed-case name and an uppercase deviceid-TXT
        // airplay advert for the same device merge (canonical forms are identical).
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let events = EventCollector()
        discovery.onEvent = { events.append($0) }
        discovery.start()

        browser.resolve(raopNameDerivedService(name: "6b2e52b73717@Combo"))
        guard case .appeared(let d)? = events.wait(count: 1).first else {
            Issue.record("expected .appeared")
            return
        }
        #expect(d.id == "6B:2E:52:B7:37:17")
        browser.resolve(airplayService(id: "6B:2E:52:B7:37:17", name: "Combo", features: ap2Features))
        _ = events.wait(count: 2)
        #expect(discovery.devices.count == 1, "mixed-case name-derived id must merge with the uppercase TXT id")

        discovery.stop()
    }

    // MARK: Snapshot before any events

    /// `devices` reflects the current known set synchronously (used for first
    /// paint), independent of the event stream.
    @Test func devicesSnapshotReflectsKnownSet() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        discovery.start()

        #expect(discovery.devices.isEmpty)
        browser.resolve(airplayService(features: ap2Features))
        browser.resolve(raopService())

        // Poll the synchronous snapshot (no callback needed) until both land.
        let deadline = Date().addingTimeInterval(2)
        while discovery.devices.count < 2 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(discovery.devices.count == 2)
        #expect(Set(discovery.devices.map(\.id)) == Set(["AA:BB:CC:DD:EE:01", "AA:BB:CC:DD:EE:99"]))

        discovery.stop()
    }

    // MARK: Address-selection policy (NetworkFrameworkBrowser)

    /// The real NWConnection probe race is not unit-testable (needs a live
    /// socket), so the address-acceptance policy is factored into pure statics
    /// on `NetworkFrameworkBrowser` and covered directly here. Root cause this
    /// guards: a probe that raced onto a dual-stack device's IPv6 link-local
    /// address (`fe80::...%en0`) used to be accepted at face value — RTSP
    /// control connects (receiver's LED goes green) but the vendored engine
    /// currently runs with its `ipv6` conffile option OFF, so it can't use
    /// ANY IPv6 address yet (global or link-local) — audio silently never
    /// flows. Policy today: IPv4 only. (Deferred: relax to also accept IPv6
    /// *global* addresses once the engine's ipv6 config is re-enabled and a
    /// real-hardware PTP-over-IPv6 test proves the media/PTP path works.)

    /// IPv4 is the only acceptable family today.
    @Test func ipv4Accepted() {
        #expect(NetworkFrameworkBrowser.isAcceptable(address: "192.168.4.50", family: .ipv4))
        #expect(NetworkFrameworkBrowser.isAcceptable(address: "169.254.1.1", family: .ipv4))
    }

    /// Bare link-local IPv6, no zone suffix — rejected (both by the general
    /// IPv6 ban and by the link-local-specific classifier used for logging).
    @Test func linkLocalIPv6Rejected() {
        #expect(NetworkFrameworkBrowser.isLinkLocalIPv6String("fe80::1"))
        #expect(!NetworkFrameworkBrowser.isAcceptable(address: "fe80::1", family: .ipv6))
    }

    /// The exact address from the live-gated bug report, with a `%en0` zone.
    @Test func linkLocalIPv6WithZoneRejected() {
        let address = "fe80::562a:1bff:fe79:89e%en0"
        #expect(NetworkFrameworkBrowser.isLinkLocalIPv6String(address))
        #expect(!NetworkFrameworkBrowser.isAcceptable(address: address, family: .ipv6))
    }

    /// Uppercase / mixed-case link-local literals are still recognized by the
    /// classifier (used only for the loud "link-local vs global" log message).
    @Test func linkLocalIPv6CaseInsensitive() {
        #expect(NetworkFrameworkBrowser.isLinkLocalIPv6String("FE80::1"))
        #expect(NetworkFrameworkBrowser.isLinkLocalIPv6String("Fe80::562A:1BFF:Fe79:89E%en0"))
    }

    /// The full fe80::/10 block (first hextet 0xFE80...0xFEBF), not just the
    /// literal "fe80" prefix — e.g. "febf::1" is still inside the /10 block.
    @Test func linkLocalIPv6FullTenBitBlock() {
        #expect(NetworkFrameworkBrowser.isLinkLocalIPv6String("febf::1"))
        #expect(NetworkFrameworkBrowser.isLinkLocalIPv6String("fe90::1"))
        // Just outside the /10 block on either side.
        #expect(!NetworkFrameworkBrowser.isLinkLocalIPv6String("fec0::1"))  // site-local (deprecated), not link-local
        #expect(!NetworkFrameworkBrowser.isLinkLocalIPv6String("fe7f::1"))
    }

    /// A global IPv6 address is NOT classified link-local by the classifier...
    @Test func globalIPv6IsNotLinkLocal() {
        #expect(!NetworkFrameworkBrowser.isLinkLocalIPv6String("2001:db8::1"))
    }

    /// ...but the overall acceptance policy still rejects it: the engine can't
    /// use ANY IPv6 yet (its `ipv6` conffile option is off), so "global, not
    /// link-local" isn't enough to be acceptable today.
    @Test func globalIPv6RejectedByPolicyUntilEngineIPv6Enabled() {
        #expect(!NetworkFrameworkBrowser.isAcceptable(address: "2001:db8::1", family: .ipv6))
    }

    /// Dual-stack device scenario: given a link-local IPv6 candidate and an
    /// IPv4 candidate for the same device, the policy must accept IPv4 and
    /// reject the link-local candidate — this is the exact shape of the live
    /// bug (Sonos Move resolved to `fe80::562a:1bff:fe79:89e%en0` while an
    /// IPv4 address, `192.168.4.x`, was available and required for audio).
    @Test func dualStackPrefersIPv4OverLinkLocalIPv6() {
        let ipv4 = "192.168.4.23"
        let linkLocalV6 = "fe80::562a:1bff:fe79:89e%en0"
        #expect(NetworkFrameworkBrowser.isAcceptable(address: ipv4, family: .ipv4))
        #expect(!NetworkFrameworkBrowser.isAcceptable(address: linkLocalV6, family: .ipv6))
    }

    // MARK: B9 — `.failed` recreate backoff (NetworkFrameworkBrowser)

    /// `.failed` is a TERMINAL NWBrowser state — Network.framework does not
    /// restart it, unlike `.waiting` which self-recovers — so
    /// `NetworkFrameworkBrowser` recreates its own browser after `.failed`,
    /// with capped exponential backoff. The actual NWBrowser recreate can't be
    /// exercised headlessly (needs a live socket/Bonjour stack); the schedule
    /// itself is a pure static and is fully covered here.

    /// 1s, 2s, 4s, 8s, 16s, then capped at 30s.
    @Test func backoffScheduleDoubles() {
        #expect(NetworkFrameworkBrowser.nextDelay(afterAttempt: 0) == 1)
        #expect(NetworkFrameworkBrowser.nextDelay(afterAttempt: 1) == 2)
        #expect(NetworkFrameworkBrowser.nextDelay(afterAttempt: 2) == 4)
        #expect(NetworkFrameworkBrowser.nextDelay(afterAttempt: 3) == 8)
        #expect(NetworkFrameworkBrowser.nextDelay(afterAttempt: 4) == 16)
    }

    /// The schedule never exceeds the 30s cap, however many consecutive
    /// failures precede it.
    @Test func backoffScheduleCapsAtThirtySeconds() {
        #expect(NetworkFrameworkBrowser.nextDelay(afterAttempt: 5) == 30)
        #expect(NetworkFrameworkBrowser.nextDelay(afterAttempt: 6) == 30)
        #expect(NetworkFrameworkBrowser.nextDelay(afterAttempt: 20) == 30)
    }

    /// Attempt 0 (no prior failures) is always the 1s floor, never a
    /// zero/negative delay.
    @Test func backoffScheduleFirstAttemptIsOneSecond() {
        #expect(NetworkFrameworkBrowser.nextDelay(afterAttempt: 0) == 1)
    }

    /// `NativeDiscovery` itself must not treat `.failed` as anything but
    /// informational: it never tears down `known` devices on a `.failed`
    /// state-change from its injected browser (the double doesn't recreate
    /// itself — only the real `NetworkFrameworkBrowser` does — but consumer
    /// behavior across the state change must stay sane either way: existing
    /// devices are untouched and later resolves still land normally).
    @Test func failedStateChangeDoesNotDropKnownDevices() {
        let browser = FakeBrowser()
        let discovery = NativeDiscovery(browser: browser)
        let collector = EventCollector()
        discovery.onEvent = { collector.append($0) }
        discovery.start()

        browser.resolve(airplayService(
            id: "AA:BB:CC:DD:EE:01", name: "Kitchen", features: ap2Features))
        collector.wait(count: 1)

        browser.state(.failed("mDNSResponder restarted"))

        // The device must still be present — a transient `.failed` must not
        // spuriously drop it.
        #expect(discovery.devices.count == 1)
        #expect(discovery.devices.first?.id == "AA:BB:CC:DD:EE:01")

        // And a fresh resolve after `.failed` (what a real recreate would
        // eventually deliver) must still flow through as an ordinary update,
        // not be swallowed by any leftover failure state.
        browser.resolve(airplayService(
            id: "AA:BB:CC:DD:EE:02", name: "Living Room", features: ap2Features))
        collector.wait(count: 2)
        #expect(discovery.devices.count == 2)
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
