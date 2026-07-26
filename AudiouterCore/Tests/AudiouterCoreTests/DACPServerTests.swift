import Foundation
import Testing
@testable import AudiouterCore

/// Unit tests for the DACP request parsing + volume mapping (speaker-input task,
/// phase 2). Pure — no sockets, no Bonjour. This is the exact wire format an
/// AirPlay receiver sends when the user changes volume ON THE SPEAKER.
@Suite struct DACPServerTests {

    private func request(_ raw: String) -> DACPServer.DACPRequest? {
        DACPServer.parse(Data(raw.utf8))
    }

    // MARK: - setproperty device-volume (the real Sonos volume report)

    @Test func parsesAbsoluteDeviceVolume() {
        let raw = "GET /ctrl-int/1/setproperty?dmcp.device-volume=-16.500000 HTTP/1.1\r\n"
            + "Host: mymac.local.\r\n"
            + "Active-Remote: 460916894\r\n"
            + "\r\n"
        let req = request(raw)
        #expect(req?.command == "setproperty")
        #expect(req?.activeRemote == 460916894)
        #expect(req?.query["dmcp.device-volume"] == "-16.500000")
        #expect(abs((req?.deviceVolumeDb ?? 0) - -16.5) <= 0.0001)
    }

    @Test func muteSentinelParses() {
        let req = request("GET /ctrl-int/1/setproperty?dmcp.device-volume=-144.000000 HTTP/1.1\r\nActive-Remote: 7\r\n\r\n")
        #expect(abs((req?.deviceVolumeDb ?? 0) - -144) <= 0.001)
    }

    // MARK: - other verbs

    @Test func parsesRelativeAndTransportVerbs() {
        #expect(request("GET /ctrl-int/1/volumeup HTTP/1.1\r\nActive-Remote: 5\r\n\r\n")?.command == "volumeup")
        #expect(request("GET /ctrl-int/1/pause HTTP/1.1\r\nActive-Remote: 5\r\n\r\n")?.command == "pause")
        // A non-setproperty verb has no device volume.
        #expect(request("GET /ctrl-int/1/volumeup HTTP/1.1\r\nActive-Remote: 5\r\n\r\n")?.deviceVolumeDb == nil)
    }

    @Test func activeRemoteCaseInsensitiveAndOptional() {
        // Header name casing varies across receivers.
        #expect(request("GET /ctrl-int/1/pause HTTP/1.1\r\nactive-remote: 42\r\n\r\n")?.activeRemote == 42)
        // Missing header → nil token (dispatch will drop it).
        #expect(request("GET /ctrl-int/1/pause HTTP/1.1\r\nHost: x\r\n\r\n")?.activeRemote == nil)
    }

    @Test func nonControlRequestIsRejected() {
        #expect(request("GET /favicon.ico HTTP/1.1\r\n\r\n") == nil)
        #expect(request("") == nil)
    }

    // MARK: - dB → 0…1 level mapping (mirrors the outbound map)

    @Test func volumeLevelMapping() {
        #expect(abs(DACPServer.level(fromDb: -144) - 0) <= 0.0001) // mute
        #expect(abs(DACPServer.level(fromDb: -30) - 0) <= 0.0001)  // min
        #expect(abs(DACPServer.level(fromDb: -15) - 0.5) <= 0.0001) // mid
        #expect(abs(DACPServer.level(fromDb: 0) - 1) <= 0.0001)     // max
        #expect(abs(DACPServer.level(fromDb: 5) - 1) <= 0.0001)     // clamp above
    }
}
