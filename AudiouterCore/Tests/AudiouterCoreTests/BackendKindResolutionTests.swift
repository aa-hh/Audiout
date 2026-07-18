import XCTest
@testable import AudiouterCore

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

    // MARK: - AIRPLAY_START_BUFFER_MS resolution (env → setting → default)

    /// A throwaway defaults suite so these tests never read `.standard`.
    private func throwawaySettings(startBufferMs: Int? = nil) -> AppSettings {
        let suite = "AudiouterTests.resolution.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        if let ms = startBufferMs { settings.startBufferMs = ms }
        return settings
    }

    func testStartBufferDefaultsWithNoEnvAndNoSetting() {
        XCTAssertEqual(nativeStartBufferMs(environment: [:], settings: throwawaySettings()),
                       AppSettings.defaultStartBufferMs)
    }

    func testStartBufferUsesPersistedSettingWithNoEnv() {
        XCTAssertEqual(
            nativeStartBufferMs(environment: [:], settings: throwawaySettings(startBufferMs: 2250)),
            2250)
    }

    func testStartBufferEnvBeatsSetting() {
        // The env var is a deliberate per-launch dev override — it wins even
        // over an explicit user setting, and may take values the UI doesn't
        // offer (e.g. 500 for the gated floor sweep).
        XCTAssertEqual(
            nativeStartBufferMs(environment: ["AIRPLAY_START_BUFFER_MS": "500"],
                                settings: throwawaySettings(startBufferMs: 2250)),
            500)
        XCTAssertEqual(nativeStartBufferEnvOverrideMs(environment: ["AIRPLAY_START_BUFFER_MS": "500"]), 500)
    }

    func testStartBufferInvalidEnvFallsThroughToSetting() {
        // Out of range or non-numeric behaves like UNSET (one stderr warning):
        // the persisted setting still applies — same dev-knob-not-config
        // policy as AIRPLAY_BACKEND's unknown-value fallback.
        for bad in ["250", "60000", "fast", ""] {
            XCTAssertEqual(
                nativeStartBufferMs(environment: ["AIRPLAY_START_BUFFER_MS": bad],
                                    settings: throwawaySettings(startBufferMs: 1500)),
                1500, "env \"\(bad)\" should be ignored")
            XCTAssertNil(nativeStartBufferEnvOverrideMs(environment: ["AIRPLAY_START_BUFFER_MS": bad]))
        }
        XCTAssertNil(nativeStartBufferEnvOverrideMs(environment: [:]))
    }
}
