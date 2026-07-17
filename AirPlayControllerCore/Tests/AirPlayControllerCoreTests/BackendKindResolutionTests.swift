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

    func testEnvVarSelectsNative() {
        let resolved = BackendKind.resolved(explicit: nil, environment: ["AIRPLAY_BACKEND": "native"])
        XCTAssertEqual(resolved, .native)
    }

    func testEnvVarForNativeIsCaseInsensitive() {
        let resolved = BackendKind.resolved(explicit: nil, environment: ["AIRPLAY_BACKEND": "Native"])
        XCTAssertEqual(resolved, .native)
    }

    // MARK: - AIRPLAY_START_BUFFER_MS (native path's sender start buffer)

    func testStartBufferDefaultsTo1000WithNoEnv() {
        XCTAssertEqual(nativeStartBufferMs(environment: [:]), 1000)
    }

    func testStartBufferReadsEnvWithinRange() {
        XCTAssertEqual(nativeStartBufferMs(environment: ["AIRPLAY_START_BUFFER_MS": "2250"]), 2250)
        XCTAssertEqual(nativeStartBufferMs(environment: ["AIRPLAY_START_BUFFER_MS": "300"]), 300)
        XCTAssertEqual(nativeStartBufferMs(environment: ["AIRPLAY_START_BUFFER_MS": "5000"]), 5000)
    }

    func testStartBufferRejectsOutOfRangeAndGarbage() {
        // Out of range or non-numeric → the product default, not a clamp: this
        // is a dev knob, and a typo should behave like "unset" (same policy as
        // AIRPLAY_BACKEND's unknown-value fallback).
        XCTAssertEqual(nativeStartBufferMs(environment: ["AIRPLAY_START_BUFFER_MS": "250"]), 1000)
        XCTAssertEqual(nativeStartBufferMs(environment: ["AIRPLAY_START_BUFFER_MS": "60000"]), 1000)
        XCTAssertEqual(nativeStartBufferMs(environment: ["AIRPLAY_START_BUFFER_MS": "fast"]), 1000)
        XCTAssertEqual(nativeStartBufferMs(environment: ["AIRPLAY_START_BUFFER_MS": ""]), 1000)
    }
}
