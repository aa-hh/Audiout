import XCTest
import AirPlayEngine
@testable import AirPlayControllerCore

/// Live-LAN discovery tests for ``NativeDiscovery`` (T-NB-DISCOVERY-1).
///
/// EVERY test in this file skips via `XCTSkip` unless the environment variable
/// `AIRPLAY_LIVE_DISCOVERY=1` is set. This is the D7 exception: passive Bonjour
/// discovery scans against the real LAN are allowed during development
/// (browsing is read-only — no root, no PTP, no audio). Not part of the
/// hermetic suite; never runs in CI/headless verification by default.
///
/// Run manually:
///   AIRPLAY_LIVE_DISCOVERY=1 swift test --filter NativeDiscoveryLive
///
/// For full ground-truth coverage (including an AP1-only device), first start
/// exactly one fake speaker:
///   dev/fake-speakers.sh
/// and stop it afterwards:
///   dev/stop-fake-speakers.sh
final class NativeDiscoveryLiveTests: XCTestCase {

    private func requireLiveEnabled() throws {
        guard ProcessInfo.processInfo.environment["AIRPLAY_LIVE_DISCOVERY"] == "1" else {
            throw XCTSkip("Set AIRPLAY_LIVE_DISCOVERY=1 to run live LAN discovery scans (D7 exception).")
        }
    }

    /// Browse the real LAN briefly (using the production `NetworkFrameworkBrowser`)
    /// and assert at least one AP2 device resolves with a well-formed descriptor:
    /// non-empty name, non-empty numeric address, a plausible RTSP port, and a
    /// colon-hex `deviceid` that round-trips to a nonzero `OutputID`.
    func testLiveScanFindsAtLeastOneAP2Device() throws {
        try requireLiveEnabled()

        let discovery = NativeDiscovery() // production NetworkFrameworkBrowser
        let collector = LiveEventCollector()
        discovery.onEvent = { collector.append($0) }
        discovery.start()
        defer { discovery.stop() }

        // Passive browse window. 12s is generous for mDNS resolves to settle
        // (multiple probes/announcements) without hanging the suite.
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if collector.devices().contains(where: { $0.isAirPlay2Supported }) { break }
            Thread.sleep(forTimeInterval: 0.25)
        }

        let devices = collector.devices()
        print("[NativeDiscoveryLiveTests] resolved \(devices.count) device(s):")
        for d in devices {
            print("  - \(d.descriptor.name)  id=\(d.id)  ap2=\(d.isAirPlay2Supported)  " +
                  "addr=\(d.descriptor.address):\(d.descriptor.port)  model=\(d.descriptor.txtRecord["model"] ?? "?")")
        }

        guard let ap2 = devices.first(where: { $0.isAirPlay2Supported }) else {
            XCTFail("""
                No AirPlay-2 device resolved on the LAN within 12s. Expected fleet: \
                Sonos Move / Move 2 / AirPort Express. Ensure they're powered on \
                the same network segment and mDNS multicast isn't blocked (see \
                the sandboxing note in PLAN-PHASE-2B.md T-NB-DISCOVERY-1).
                """)
            return
        }

        XCTAssertFalse(ap2.descriptor.name.isEmpty, "AP2 device must have a non-empty service name")
        XCTAssertFalse(ap2.descriptor.address.isEmpty, "AP2 device must have a resolved numeric address")
        XCTAssertGreaterThan(ap2.descriptor.port, 0, "AP2 device must have a resolved RTSP port")
        XCTAssertFalse(ap2.id.isEmpty, "AP2 device must carry the colon-hex deviceid")
        XCTAssertGreaterThan(ap2.outputID.rawValue, 0, "the parsed OutputID must be nonzero")
        // Colon-hex round-trip sanity: re-parsing the descriptor's own txt yields
        // the identical id string (never reformatted) and the same OutputID.
        let reparsed = NativeDiscovery.parseDeviceID(ap2.descriptor.txtRecord)
        XCTAssertEqual(reparsed?.id, ap2.id)
        XCTAssertEqual(reparsed?.outputID, ap2.outputID)
    }

    /// Snapshot-only variant: gives a longer window and dumps full classification
    /// (AP2 vs AP1-only) for every device seen, for manual eyeballing against the
    /// expected fleet during the T-NB-DISCOVERY-1 live verification pass. Not a
    /// hard assertion beyond "at least one device total resolved" — the AP2-
    /// specific assertion lives in `testLiveScanFindsAtLeastOneAP2Device` above.
    func testLiveScanEnumeratesFullFleet() throws {
        try requireLiveEnabled()

        let discovery = NativeDiscovery()
        let collector = LiveEventCollector()
        discovery.onEvent = { collector.append($0) }
        discovery.start()
        defer { discovery.stop() }

        Thread.sleep(forTimeInterval: 15)

        let devices = collector.devices().sorted { $0.descriptor.name < $1.descriptor.name }
        print("[NativeDiscoveryLiveTests] full fleet snapshot (\(devices.count) device(s)):")
        for d in devices {
            let kind = d.isAirPlay2Supported ? "AP2" : "AP1-only"
            print("  - [\(kind)] \(d.descriptor.name)  id=\(d.id)  " +
                  "addr=\(d.descriptor.address):\(d.descriptor.port)  " +
                  "model=\(d.descriptor.txtRecord["model"] ?? "?")")
        }

        XCTAssertFalse(devices.isEmpty, "expected at least one AirPlay/RAOP device on the LAN")
    }
}

/// Thread-safe collector for live discovery events; exposes a synchronous
/// current-known-devices view built from appear/update/disappear.
private final class LiveEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var known: [String: DiscoveredDevice] = [:]

    func append(_ event: DiscoveryEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .appeared(let d), .updated(let d):
            known[d.id] = d
        case .disappeared(let id, _):
            known[id] = nil
        }
    }

    func devices() -> [DiscoveredDevice] {
        lock.lock(); defer { lock.unlock() }
        return Array(known.values)
    }
}
