import XCTest
@testable import AirPlayControllerCore

final class BackendKindResolutionTests: XCTestCase {

    func testDefaultsToMockWithNoExplicitArgOrEnv() {
        XCTAssertEqual(BackendKind.resolved(explicit: nil, environment: [:]), .mock)
    }

    func testExplicitArgBeatsEnv() {
        let resolved = BackendKind.resolved(
            explicit: .ownTone,
            environment: ["AIRPLAY_BACKEND": "mock"]
        )
        XCTAssertEqual(resolved, .ownTone, "an explicit argument should win over the env var")
    }

    func testEnvVarSelectsOwnTone() {
        let resolved = BackendKind.resolved(explicit: nil, environment: ["AIRPLAY_BACKEND": "owntone"])
        XCTAssertEqual(resolved, .ownTone)
    }

    func testEnvVarIsCaseInsensitive() {
        let resolved = BackendKind.resolved(explicit: nil, environment: ["AIRPLAY_BACKEND": "OwnTone"])
        XCTAssertEqual(resolved, .ownTone)
    }

    func testUnknownEnvValueFallsBackToMock() {
        let resolved = BackendKind.resolved(explicit: nil, environment: ["AIRPLAY_BACKEND": "sonos"])
        XCTAssertEqual(resolved, .mock, "an unrecognized value should fall back to mock, not crash")
    }
}
