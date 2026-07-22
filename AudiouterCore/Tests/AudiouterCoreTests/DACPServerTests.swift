import XCTest
@testable import AudiouterCore

/// Unit tests for the DACP request parsing + volume mapping (speaker-input task,
/// phase 2). Pure — no sockets, no Bonjour. This is the exact wire format an
/// AirPlay receiver sends when the user changes volume ON THE SPEAKER.
final class DACPServerTests: XCTestCase {

    private func request(_ raw: String) -> DACPServer.DACPRequest? {
        DACPServer.parse(Data(raw.utf8))
    }

    // MARK: - setproperty device-volume (the real Sonos volume report)

    func testParsesAbsoluteDeviceVolume() {
        let raw = "GET /ctrl-int/1/setproperty?dmcp.device-volume=-16.500000 HTTP/1.1\r\n"
            + "Host: mymac.local.\r\n"
            + "Active-Remote: 460916894\r\n"
            + "\r\n"
        let req = request(raw)
        XCTAssertEqual(req?.command, "setproperty")
        XCTAssertEqual(req?.activeRemote, 460916894)
        XCTAssertEqual(req?.query["dmcp.device-volume"], "-16.500000")
        XCTAssertEqual(req?.deviceVolumeDb ?? 0, -16.5, accuracy: 0.0001)
    }

    func testMuteSentinelParses() {
        let req = request("GET /ctrl-int/1/setproperty?dmcp.device-volume=-144.000000 HTTP/1.1\r\nActive-Remote: 7\r\n\r\n")
        XCTAssertEqual(req?.deviceVolumeDb ?? 0, -144, accuracy: 0.001)
    }

    // MARK: - other verbs

    func testParsesRelativeAndTransportVerbs() {
        XCTAssertEqual(request("GET /ctrl-int/1/volumeup HTTP/1.1\r\nActive-Remote: 5\r\n\r\n")?.command, "volumeup")
        XCTAssertEqual(request("GET /ctrl-int/1/pause HTTP/1.1\r\nActive-Remote: 5\r\n\r\n")?.command, "pause")
        // A non-setproperty verb has no device volume.
        XCTAssertNil(request("GET /ctrl-int/1/volumeup HTTP/1.1\r\nActive-Remote: 5\r\n\r\n")?.deviceVolumeDb)
    }

    func testActiveRemoteCaseInsensitiveAndOptional() {
        // Header name casing varies across receivers.
        XCTAssertEqual(request("GET /ctrl-int/1/pause HTTP/1.1\r\nactive-remote: 42\r\n\r\n")?.activeRemote, 42)
        // Missing header → nil token (dispatch will drop it).
        XCTAssertNil(request("GET /ctrl-int/1/pause HTTP/1.1\r\nHost: x\r\n\r\n")?.activeRemote)
    }

    func testNonControlRequestIsRejected() {
        XCTAssertNil(request("GET /favicon.ico HTTP/1.1\r\n\r\n"))
        XCTAssertNil(request(""))
    }

    // MARK: - dB → 0…1 level mapping (mirrors the outbound map)

    func testVolumeLevelMapping() {
        XCTAssertEqual(DACPServer.level(fromDb: -144), 0, accuracy: 0.0001) // mute
        XCTAssertEqual(DACPServer.level(fromDb: -30), 0, accuracy: 0.0001)  // min
        XCTAssertEqual(DACPServer.level(fromDb: -15), 0.5, accuracy: 0.0001) // mid
        XCTAssertEqual(DACPServer.level(fromDb: 0), 1, accuracy: 0.0001)     // max
        XCTAssertEqual(DACPServer.level(fromDb: 5), 1, accuracy: 0.0001)     // clamp above
    }
}
