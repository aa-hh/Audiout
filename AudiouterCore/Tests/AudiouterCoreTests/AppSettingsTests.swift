// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// `AppSettings` is the scalar half of the persistence split — a thin typed
/// wrapper over `UserDefaults`. These assert the defaults, the round-trip, and
/// forward-compat (an unknown stored value falls back, doesn't trap). A
/// throwaway suite keeps the tests off `.standard`.
@Suite struct AppSettingsTests {

    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        let hash = ObjectIdentifier(AppSettingsTests.self).hashValue
        suiteName = "AudiouterTests.\(UUID().uuidString).\(hash)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func defaultsWhenUnset() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.theme == .system)
        #expect(settings.density == .comfortable)
    }

    @Test func themeRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        settings.theme = .dark
        #expect(settings.theme == .dark)
        // A fresh value over the same store reads the persisted value.
        #expect(AppSettings(defaults: defaults).theme == .dark)
    }

    @Test func densityRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        settings.density = .compact
        #expect(settings.density == .compact)
        #expect(AppSettings(defaults: defaults).density == .compact)
    }

    @Test func unknownStoredValueFallsBack() {
        defaults.set("chartreuse", forKey: "appearance.theme")
        #expect(AppSettings(defaults: defaults).theme == .system)
    }

    // MARK: Audio buffer (PLAN-LATENCY-SETTING.md)

    @Test func startBufferDefaultsWhenUnset() {
        #expect(AppSettings(defaults: defaults).startBufferMs ==
                       AppSettings.defaultStartBufferMs)
    }

    @Test func startBufferRoundTripsEveryOfferedOption() {
        let settings = AppSettings(defaults: defaults)
        for option in AppSettings.startBufferOptionsMs {
            settings.startBufferMs = option
            #expect(AppSettings(defaults: defaults).startBufferMs == option)
        }
    }

    @Test func startBufferUnofferedStoredValueFallsBack() {
        // A value the UI never offers (e.g. written by a newer build with a
        // different option list, or hand-edited defaults) resolves to the
        // default rather than leaking into the popup.
        defaults.set(750, forKey: "audio.startBufferMs")
        #expect(AppSettings(defaults: defaults).startBufferMs ==
                       AppSettings.defaultStartBufferMs)
        defaults.set(-40, forKey: "audio.startBufferMs")
        #expect(AppSettings(defaults: defaults).startBufferMs ==
                       AppSettings.defaultStartBufferMs)
    }

    @Test func startBufferOptionListInvariants() {
        // The default must be offered, the floor is the first option, and the
        // whole list must sit inside the engine shim's accepted 300...5000.
        #expect(AppSettings.startBufferOptionsMs.contains(AppSettings.defaultStartBufferMs))
        #expect(AppSettings.startBufferOptionsMs == AppSettings.startBufferOptionsMs.sorted())
        #expect(AppSettings.startBufferOptionsMs.allSatisfy { (300...5000).contains($0) })
    }

    // MARK: First-run setup (SetupModel)

    @Test func hasCompletedSetupDefaultsFalse() {
        // A fresh install must show setup once, so the unset default is false.
        #expect(!AppSettings(defaults: defaults).hasCompletedSetup)
    }

    @Test func hasCompletedSetupRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        settings.hasCompletedSetup = true
        #expect(settings.hasCompletedSetup)
        #expect(AppSettings(defaults: defaults).hasCompletedSetup)
    }

    // MARK: Wake restore (B6b)

    @Test func wakeRestoreDefaultsToTwoMinutesWhenUnset() {
        // Unset must resolve to the default (2), NOT 0 — 0 is a valid "Never" that
        // `UserDefaults.integer` also returns for a missing key.
        #expect(AppSettings(defaults: defaults).wakeRestoreMinutes ==
                       AppSettings.defaultWakeRestoreMinutes)
        #expect(AppSettings.defaultWakeRestoreMinutes == 2)
    }

    @Test func wakeRestoreRoundTripsEveryOfferedOption() {
        let settings = AppSettings(defaults: defaults)
        for option in AppSettings.wakeRestoreMinuteOptions {
            settings.wakeRestoreMinutes = option
            #expect(AppSettings(defaults: defaults).wakeRestoreMinutes == option)
        }
    }

    @Test func wakeRestoreNeverIsDistinctFromUnset() {
        // Explicitly choosing Never (0) must PERSIST as 0, not be re-defaulted to 2.
        let settings = AppSettings(defaults: defaults)
        settings.wakeRestoreMinutes = 0
        #expect(AppSettings(defaults: defaults).wakeRestoreMinutes == 0)
    }

    @Test func wakeRestoreUnofferedStoredValueFallsBack() {
        defaults.set(3, forKey: "audio.wakeRestoreMinutes")
        #expect(AppSettings(defaults: defaults).wakeRestoreMinutes ==
                       AppSettings.defaultWakeRestoreMinutes)
        defaults.set(-5, forKey: "audio.wakeRestoreMinutes")
        #expect(AppSettings(defaults: defaults).wakeRestoreMinutes ==
                       AppSettings.defaultWakeRestoreMinutes)
    }

    @Test func wakeRestoreOptionListInvariants() {
        // The default must be offered, options ascend, and Never (0) is offered.
        #expect(AppSettings.wakeRestoreMinuteOptions.contains(AppSettings.defaultWakeRestoreMinutes))
        #expect(AppSettings.wakeRestoreMinuteOptions == AppSettings.wakeRestoreMinuteOptions.sorted())
        #expect(AppSettings.wakeRestoreMinuteOptions.first == 0)
    }

    // MARK: Main-out volume

    @Test func mainOutVolumeDefaultsToOneHundredWhenUnset() {
        #expect(AppSettings(defaults: defaults).mainOutVolume == AppSettings.defaultMainOutVolume)
        #expect(AppSettings.defaultMainOutVolume == 100)
    }

    @Test func mainOutVolumeRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        settings.mainOutVolume = 75
        #expect(AppSettings(defaults: defaults).mainOutVolume == 75)

        settings.mainOutVolume = 0
        #expect(AppSettings(defaults: defaults).mainOutVolume == 0)

        settings.mainOutVolume = 100
        #expect(AppSettings(defaults: defaults).mainOutVolume == 100)
    }

    @Test func mainOutVolumeClampsToBounds() {
        let settings = AppSettings(defaults: defaults)
        settings.mainOutVolume = 150
        #expect(AppSettings(defaults: defaults).mainOutVolume == AppSettings.maxMainOutVolume)

        settings.mainOutVolume = -50
        #expect(AppSettings(defaults: defaults).mainOutVolume == AppSettings.minMainOutVolume)
    }

    @Test func mainOutVolumeOutOfRangeStoredValueClamps() {
        // A value outside the valid range (a newer/older build, or hand-edited
        // defaults) resolves to the clamped bound rather than leaking through.
        defaults.set(200, forKey: "audio.mainOutVolume")
        #expect(AppSettings(defaults: defaults).mainOutVolume == AppSettings.maxMainOutVolume)

        defaults.set(-100, forKey: "audio.mainOutVolume")
        #expect(AppSettings(defaults: defaults).mainOutVolume == AppSettings.minMainOutVolume)
    }

    // MARK: Sync offset (T-OFFSET-UI)

    @Test func syncOffsetDefaultsToZeroWhenUnset() {
        #expect(AppSettings(defaults: defaults).syncOffsetMs == AppSettings.defaultSyncOffsetMs)
        #expect(AppSettings.defaultSyncOffsetMs == 0)
    }

    @Test func syncOffsetRoundTripsPositiveAndNegative() {
        let settings = AppSettings(defaults: defaults)
        settings.syncOffsetMs = 120
        #expect(AppSettings(defaults: defaults).syncOffsetMs == 120)

        settings.syncOffsetMs = -75
        #expect(AppSettings(defaults: defaults).syncOffsetMs == -75)
    }

    @Test func syncOffsetExplicitZeroIsDistinctFromUnsetButReadsTheSame() {
        // Explicitly choosing 0 must persist and read back as 0 (same value as
        // unset, but exercised via the write path this time).
        let settings = AppSettings(defaults: defaults)
        settings.syncOffsetMs = 0
        #expect(AppSettings(defaults: defaults).syncOffsetMs == 0)
    }

    @Test func syncOffsetClampsToBounds() {
        let settings = AppSettings(defaults: defaults)
        settings.syncOffsetMs = 10_000
        #expect(AppSettings(defaults: defaults).syncOffsetMs == AppSettings.maxSyncOffsetMs)

        settings.syncOffsetMs = -10_000
        #expect(AppSettings(defaults: defaults).syncOffsetMs == AppSettings.minSyncOffsetMs)
    }

    @Test func syncOffsetOutOfRangeStoredValueFallsBackToClamp() {
        // A value outside the offered range (a newer/older build, or hand-edited
        // defaults) resolves to the clamped bound rather than leaking through.
        defaults.set(9_999, forKey: "audio.syncOffsetMs")
        #expect(AppSettings(defaults: defaults).syncOffsetMs == AppSettings.maxSyncOffsetMs)
        defaults.set(-9_999, forKey: "audio.syncOffsetMs")
        #expect(AppSettings(defaults: defaults).syncOffsetMs == AppSettings.minSyncOffsetMs)
    }

    @Test func syncOffsetBoundsStraddleZero() {
        #expect(AppSettings.minSyncOffsetMs < 0)
        #expect(AppSettings.maxSyncOffsetMs > 0)
        #expect((AppSettings.minSyncOffsetMs...AppSettings.maxSyncOffsetMs).contains(AppSettings.defaultSyncOffsetMs))
    }

    // MARK: Companion — allow remote control (T6)

    @Test func allowRemoteControlDefaultsTrueWhenUnset() {
        // T22 flip: enabled out of the box — the per-phone approval gate is
        // what protects the listener, not the checkbox. Unchecking still
        // stores false and wins (see allowRemoteControlRoundTrips).
        #expect(AppSettings(defaults: defaults).allowRemoteControl)
    }

    @Test func allowRemoteControlRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        settings.allowRemoteControl = true
        #expect(settings.allowRemoteControl)
        #expect(AppSettings(defaults: defaults).allowRemoteControl)

        settings.allowRemoteControl = false
        #expect(!AppSettings(defaults: defaults).allowRemoteControl)
    }

    @Test func resolvedAllowRemoteControlExplicitWins() {
        let settings = AppSettings(defaults: defaults)
        settings.allowRemoteControl = false
        #expect(AppSettings.resolvedAllowRemoteControl(explicit: true, environment: [:], settings: settings))
        #expect(!AppSettings.resolvedAllowRemoteControl(explicit: false, environment: ["AUDIOUTER_COMPANION": "1"], settings: settings))
    }

    @Test func resolvedAllowRemoteControlFallsBackToSettingWhenEnvUnset() {
        let settings = AppSettings(defaults: defaults)
        settings.allowRemoteControl = true
        #expect(AppSettings.resolvedAllowRemoteControl(environment: [:], settings: settings))

        settings.allowRemoteControl = false
        #expect(!AppSettings.resolvedAllowRemoteControl(environment: [:], settings: settings))
    }

    @Test(arguments: [
        ("1", true), ("0", false),
        ("on", true), ("off", false),
        ("ON", true), ("OFF", false),
        ("On", true), ("Off", false),
    ])
    func resolvedAllowRemoteControlEnvMatrix(raw: String, expected: Bool) {
        let settings = AppSettings(defaults: defaults)
        // The setting disagrees with every expected outcome, so a pass proves
        // the env var actually won rather than merely matching the default.
        settings.allowRemoteControl = !expected
        #expect(AppSettings.resolvedAllowRemoteControl(
            environment: ["AUDIOUTER_COMPANION": raw], settings: settings) == expected)
    }

    @Test func resolvedAllowRemoteControlUnrecognizedEnvFallsBackToSetting() {
        // An explicit but garbage value is treated as absent (falls back to
        // the setting), never silently guessed — mirrors BackendKind.resolved.
        let settings = AppSettings(defaults: defaults)
        settings.allowRemoteControl = true
        #expect(AppSettings.resolvedAllowRemoteControl(environment: ["AUDIOUTER_COMPANION": "banana"], settings: settings))

        settings.allowRemoteControl = false
        #expect(!AppSettings.resolvedAllowRemoteControl(environment: ["AUDIOUTER_COMPANION": "banana"], settings: settings))
    }

    // MARK: Companion — resolution source (FIX-C)
    //
    // The Settings › General checkbox must render the EFFECTIVE state and
    // disable itself while an override is in force, rather than showing the
    // raw persisted setting while a different value actually runs — these
    // assert the source-carrying resolver `resolvedAllowRemoteControl` is
    // built on gets every case right.

    @Test func resolutionSourceIsSettingWhenEnvUnset() {
        let settings = AppSettings(defaults: defaults)
        settings.allowRemoteControl = true
        let resolution = AppSettings.resolvedAllowRemoteControlWithSource(environment: [:], settings: settings)
        #expect(resolution == .setting(true))
        #expect(resolution.value)
        #expect(!resolution.isForced)
    }

    @Test(arguments: [
        ("1", true), ("0", false),
        ("on", true), ("off", false),
        ("ON", true), ("OFF", false),
    ])
    func resolutionSourceIsForcedForEveryRecognizedEnvValue(raw: String, expected: Bool) {
        let settings = AppSettings(defaults: defaults)
        // The setting disagrees with every expected outcome, so a pass proves
        // the env var actually won rather than merely matching the default.
        settings.allowRemoteControl = !expected
        let resolution = AppSettings.resolvedAllowRemoteControlWithSource(
            environment: ["AUDIOUTER_COMPANION": raw], settings: settings)
        #expect(resolution == .forced(expected))
        #expect(resolution.value == expected)
        #expect(resolution.isForced)
    }

    @Test func resolutionSourceIsSettingWhenEnvGarbage() {
        // Garbage still falls back to the setting AND reports the source as
        // `.setting` — the checkbox must stay editable, not lock up over a typo.
        let settings = AppSettings(defaults: defaults)
        settings.allowRemoteControl = true
        let resolution = AppSettings.resolvedAllowRemoteControlWithSource(
            environment: ["AUDIOUTER_COMPANION": "banana"], settings: settings)
        #expect(resolution == .setting(true))
        #expect(!resolution.isForced)
    }

    @Test func resolutionSourceIsForcedForExplicit() {
        let settings = AppSettings(defaults: defaults)
        settings.allowRemoteControl = false
        let resolution = AppSettings.resolvedAllowRemoteControlWithSource(
            explicit: true, environment: [:], settings: settings)
        #expect(resolution == .forced(true))
        #expect(resolution.isForced)
    }

    @Test func resolvedAllowRemoteControlAgreesWithSourceVariant() {
        // The plain-Bool convenience must always equal `.value` on the
        // source-carrying resolver — it's implemented in terms of it.
        let settings = AppSettings(defaults: defaults)
        settings.allowRemoteControl = true
        for environment in [[:], ["AUDIOUTER_COMPANION": "off"], ["AUDIOUTER_COMPANION": "garbage"]] as [[String: String]] {
            let plain = AppSettings.resolvedAllowRemoteControl(environment: environment, settings: settings)
            let withSource = AppSettings.resolvedAllowRemoteControlWithSource(environment: environment, settings: settings)
            #expect(plain == withSource.value)
        }
    }
}
