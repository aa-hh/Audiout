import Foundation
import Testing
@testable import AudiouterCore

@Suite struct BackendKindResolutionTests {

    @Test func defaultsToNativeWithNoExplicitArgOrEnv() {
        // Mock is opt-in only: a plain launch (no arg, no env) must resolve to
        // the real backend, never fabricated demo speakers.
        #expect(BackendKind.resolved(explicit: nil, environment: [:]) == .native)
    }

    @Test func mockRequiresExplicitEnv() {
        #expect(BackendKind.resolved(explicit: nil, environment: ["AIRPLAY_BACKEND": "mock"]) == .mock)
    }

    @Test func explicitArgBeatsEnv() {
        let resolved = BackendKind.resolved(
            explicit: .ownTone,
            environment: ["AIRPLAY_BACKEND": "mock"]
        )
        #expect(resolved == .ownTone, "an explicit argument should win over the env var")
    }

    @Test func envVarSelectsOwnTone() {
        let resolved = BackendKind.resolved(explicit: nil, environment: ["AIRPLAY_BACKEND": "owntone"])
        #expect(resolved == .ownTone)
    }

    @Test func envVarIsCaseInsensitive() {
        let resolved = BackendKind.resolved(explicit: nil, environment: ["AIRPLAY_BACKEND": "OwnTone"])
        #expect(resolved == .ownTone)
    }

    @Test func unknownEnvValueFallsBackToNative() {
        let resolved = BackendKind.resolved(explicit: nil, environment: ["AIRPLAY_BACKEND": "sonos"])
        #expect(resolved == .native, "an unrecognized value should fall back to the native default, not crash or silently mock")
    }

    @Test func envVarSelectsNative() {
        let resolved = BackendKind.resolved(explicit: nil, environment: ["AIRPLAY_BACKEND": "native"])
        #expect(resolved == .native)
    }

    @Test func envVarForNativeIsCaseInsensitive() {
        let resolved = BackendKind.resolved(explicit: nil, environment: ["AIRPLAY_BACKEND": "Native"])
        #expect(resolved == .native)
    }

    // MARK: - AIRPLAY_START_BUFFER_MS resolution (env → setting → default)

    private let isolation = TestIsolation(owner: "BackendKindResolutionTests")

    /// A throwaway defaults suite so these tests never read `.standard`.
    private func throwawaySettings(startBufferMs: Int? = nil) -> AppSettings {
        let settings = AppSettings(defaults: isolation.makeDefaults())
        if let ms = startBufferMs { settings.startBufferMs = ms }
        return settings
    }

    @Test func startBufferDefaultsWithNoEnvAndNoSetting() {
        #expect(nativeStartBufferMs(environment: [:], settings: throwawaySettings()) ==
                       AppSettings.defaultStartBufferMs)
    }

    @Test func startBufferUsesPersistedSettingWithNoEnv() {
        #expect(
            nativeStartBufferMs(environment: [:], settings: throwawaySettings(startBufferMs: 2250)) ==
            2250)
    }

    @Test func startBufferEnvBeatsSetting() {
        // The env var is a deliberate per-launch dev override — it wins even
        // over an explicit user setting, and may take values the UI doesn't
        // offer (e.g. 500 for the gated floor sweep).
        #expect(
            nativeStartBufferMs(environment: ["AIRPLAY_START_BUFFER_MS": "500"],
                                settings: throwawaySettings(startBufferMs: 2250)) ==
            500)
        #expect(nativeStartBufferEnvOverrideMs(environment: ["AIRPLAY_START_BUFFER_MS": "500"]) == 500)
    }

    @Test func startBufferInvalidEnvFallsThroughToSetting() {
        // Out of range or non-numeric behaves like UNSET (one stderr warning):
        // the persisted setting still applies — same dev-knob-not-config
        // policy as AIRPLAY_BACKEND's unknown-value fallback.
        for bad in ["250", "60000", "fast", ""] {
            #expect(
                nativeStartBufferMs(environment: ["AIRPLAY_START_BUFFER_MS": bad],
                                    settings: throwawaySettings(startBufferMs: 1500)) ==
                1500, "env \"\(bad)\" should be ignored")
            #expect(nativeStartBufferEnvOverrideMs(environment: ["AIRPLAY_START_BUFFER_MS": bad]) == nil)
        }
        #expect(nativeStartBufferEnvOverrideMs(environment: [:]) == nil)
    }
}
