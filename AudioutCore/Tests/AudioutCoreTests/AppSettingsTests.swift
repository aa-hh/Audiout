// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// `AppSettings` is the scalar half of the persistence split — a thin typed
/// wrapper over `UserDefaults`. These assert the defaults, the round-trip, and
/// forward-compat (an unknown stored value falls back, doesn't trap). A
/// throwaway store keeps the tests off `.standard`.
@Suite struct AppSettingsTests {

    private let isolation = TestIsolation(owner: "AppSettingsTests")
    private var defaults: UserDefaults { isolation.isolatedDefaults }

    @Test func defaultsWhenUnset() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.theme == .system)
        #expect(settings.reconnectAtLaunch == false)
    }

    @Test func themeRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        settings.theme = .dark
        #expect(settings.theme == .dark)
        // A fresh value over the same store reads the persisted value.
        #expect(AppSettings(defaults: defaults).theme == .dark)
    }

    @Test func reconnectAtLaunchRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        settings.reconnectAtLaunch = true
        #expect(settings.reconnectAtLaunch == true)
        #expect(AppSettings(defaults: defaults).reconnectAtLaunch == true)
    }

    @Test func telemetryOptInRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.telemetryOptIn == false)
        settings.telemetryOptIn = true
        #expect(settings.telemetryOptIn == true)
        #expect(AppSettings(defaults: defaults).telemetryOptIn == true)
    }

    @Test func telemetryAskedRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.telemetryAsked == false)
        settings.telemetryAsked = true
        #expect(settings.telemetryAsked == true)
        #expect(AppSettings(defaults: defaults).telemetryAsked == true)
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

    /// "Tuned or never tuned?" — the question the value alone cannot answer,
    /// and what the SYNC chip's "Not set" readout keys off.
    @Test func isSyncOffsetSetDistinguishesAnExplicitZeroFromUnset() {
        #expect(AppSettings(defaults: defaults).isSyncOffsetSet == false)
        let settings = AppSettings(defaults: defaults)
        settings.syncOffsetMs = 0
        #expect(AppSettings(defaults: defaults).isSyncOffsetSet,
                "a Mac deliberately trimmed to 0 ms is tuned")
    }

    /// The drawer's "Reset alignment" on the Mac's row (roadmap 056): the
    /// entry is DELETED, so the row goes back to "Not set". Writing 0 would
    /// leave it tuned, reading "0 ms" forever.
    @Test func clearSyncOffsetDeletesTheEntryRatherThanWritingZero() {
        let settings = AppSettings(defaults: defaults)
        settings.syncOffsetMs = -75
        settings.clearSyncOffset()
        #expect(AppSettings(defaults: defaults).isSyncOffsetSet == false)
        #expect(AppSettings(defaults: defaults).syncOffsetMs == AppSettings.defaultSyncOffsetMs)
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

    // MARK: Store directory — side-by-side isolation

    @Test func storeDirectoryKeepsTheHistoricalFolderForNonAudioutHosts() {
        // The swift-test host (com.apple.dt.xctest.tool) is not an
        // Audiout-family bundle id, so it must resolve to the historical
        // "Audiout" folder — the no-migration pin. Only a BUNDLE_ID
        // override like com.audiout.Audiout.dev diverges (not
        // constructible from this host; the predicate is exercised by the
        // side-by-side dev-build flow).
        #expect(GroupStore.defaultDirectory.lastPathComponent == "Audiout")
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
        #expect(!AppSettings.resolvedAllowRemoteControl(explicit: false, environment: ["AUDIOUT_COMPANION": "1"], settings: settings))
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
            environment: ["AUDIOUT_COMPANION": raw], settings: settings) == expected)
    }

    @Test func resolvedAllowRemoteControlUnrecognizedEnvFallsBackToSetting() {
        // An explicit but garbage value is treated as absent (falls back to
        // the setting), never silently guessed — mirrors BackendKind.resolved.
        let settings = AppSettings(defaults: defaults)
        settings.allowRemoteControl = true
        #expect(AppSettings.resolvedAllowRemoteControl(environment: ["AUDIOUT_COMPANION": "banana"], settings: settings))

        settings.allowRemoteControl = false
        #expect(!AppSettings.resolvedAllowRemoteControl(environment: ["AUDIOUT_COMPANION": "banana"], settings: settings))
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
            environment: ["AUDIOUT_COMPANION": raw], settings: settings)
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
            environment: ["AUDIOUT_COMPANION": "banana"], settings: settings)
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
        for environment in [[:], ["AUDIOUT_COMPANION": "off"], ["AUDIOUT_COMPANION": "garbage"]] as [[String: String]] {
            let plain = AppSettings.resolvedAllowRemoteControl(environment: environment, settings: settings)
            let withSource = AppSettings.resolvedAllowRemoteControlWithSource(environment: environment, settings: settings)
            #expect(plain == withSource.value)
        }
    }

    // MARK: One-surface pin (U3)

    @Test func surfacePinnedDefaultsFalseAndRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.surfacePinned, "fresh install: the transient bubble")
        settings.surfacePinned = true
        #expect(settings.surfacePinned)
        #expect(AppSettings(defaults: defaults).surfacePinned, "persisted across instances")
        settings.surfacePinned = false
        #expect(!AppSettings(defaults: defaults).surfacePinned)
    }

    @Test func mixerMembershipHintDismissedDefaultsFalseAndRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.mixerMembershipHintDismissed, "fresh install: the hint is still owed")
        settings.mixerMembershipHintDismissed = true
        #expect(settings.mixerMembershipHintDismissed)
        #expect(AppSettings(defaults: defaults).mixerMembershipHintDismissed, "persisted across instances")
        settings.mixerMembershipHintDismissed = false
        #expect(!AppSettings(defaults: defaults).mixerMembershipHintDismissed)
    }

    // MARK: License check-in (roadmap 054)

    @Test func licenseKeyDefaultsNilAndRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.licenseKey == nil)
        settings.licenseKey = "ABCD-1234"
        #expect(settings.licenseKey == "ABCD-1234")
        #expect(AppSettings(defaults: defaults).licenseKey == "ABCD-1234")
        settings.licenseKey = nil
        #expect(AppSettings(defaults: defaults).licenseKey == nil)
    }

    /// The bundle key is what a real build reads; under a test run
    /// `Bundle.main` is the runner, so the honest default here is "no server"
    /// — which IS the free build's state — and the init override is the only
    /// way to get the other one.
    @Test func licenseServerURLIsAbsentByDefaultAndHonoursTheInitOverride() {
        #expect(AppSettings(defaults: defaults).licenseServerURL == nil,
                "no bundle key ⇒ the free build: nothing to validate against")
        let server = URL(string: "https://license.example.com")!
        #expect(AppSettings(defaults: defaults, licenseServerURL: server).licenseServerURL == server)
    }

    @Test func checkInURLDerivesFromTheLicenseServerAndYieldsToAStoredValue() {
        #expect(AppSettings(defaults: defaults).checkInURL == nil, "no server ⇒ no endpoint")

        let derived = AppSettings(defaults: defaults,
                                  licenseServerURL: URL(string: "https://license.example.com")!)
        #expect(derived.checkInURL == URL(string: "https://license.example.com/v1/checkin"))

        derived.checkInURL = URL(string: "https://elsewhere.example.com/checkin")
        #expect(derived.checkInURL == URL(string: "https://elsewhere.example.com/checkin"),
                "an explicitly stored endpoint wins over the derived one")
    }

    /// The check-in and validate calls carry the license key, so a stored
    /// endpoint that is not https is ignored outright — the derived https URL
    /// answers instead of the planted one.
    @Test func aStoredCheckInEndpointMustBeHTTPS() {
        let settings = AppSettings(defaults: defaults,
                                   licenseServerURL: URL(string: "https://license.example.com")!)
        settings.checkInURL = URL(string: "http://evil.example.com/checkin")!
        #expect(settings.checkInURL == URL(string: "https://license.example.com/v1/checkin"),
                "a plain-http endpoint never wins — the derived https one answers")
    }

    /// The one predicate every "is this install registered?" caller reads. A
    /// stored key with no verdict yet is NOT unregistered: the check is soft,
    /// so an unanswered question gets the benefit of the doubt.
    @Test func licenseUnregisteredIsTrueOnlyForNoKeyOrARefusedOne() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.licenseUnregistered, "no key at all")

        settings.licenseKey = "AUDT-AAAAA-BBBBB-CCCCC-DDDDD"
        #expect(settings.licenseStatus == nil)
        #expect(!settings.licenseUnregistered, "a key awaiting an answer is given the benefit of the doubt")

        for refused: LicenseStatus in [.unknown, .invalid, .revoked] {
            settings.licenseStatus = refused
            #expect(settings.licenseUnregistered, Comment(rawValue: "\(refused) is a refusal"))
        }

        settings.licenseStatus = .active
        #expect(!settings.licenseUnregistered)
    }

    @Test func licenseStatusRoundTripsAndIsClearedWithTheKey() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.licenseStatus == nil, "never verified")

        settings.licenseKey = "AUDT-AAAAA-BBBBB-CCCCC-DDDDD"
        settings.licenseStatus = .active
        #expect(AppSettings(defaults: defaults).licenseStatus == .active)

        settings.licenseKey = nil
        #expect(AppSettings(defaults: defaults).licenseStatus == nil,
                "a verdict about a deleted key is a verdict about nothing")
    }

    @Test func licenseMaxMajorRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.licenseMaxMajor == nil, "absent ⇒ nil, never 0")
        settings.licenseMaxMajor = 1
        #expect(AppSettings(defaults: defaults).licenseMaxMajor == 1)
        settings.licenseMaxMajor = nil
        #expect(AppSettings(defaults: defaults).licenseMaxMajor == nil)
    }

    @Test func installIDIsStableAcrossReads() {
        let first = AppSettings(defaults: defaults).installID
        #expect(!first.isEmpty)
        // A fresh value over the same store reads the same persisted id,
        // never regenerating one.
        #expect(AppSettings(defaults: defaults).installID == first)
        #expect(AppSettings(defaults: defaults).installID == first)
    }

    @Test func checkInURLDefaultsNilAndRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        // Absent by default — this is what keeps the check-in client inert.
        #expect(settings.checkInURL == nil)
        settings.checkInURL = URL(string: "https://example.com/checkin")
        #expect(settings.checkInURL == URL(string: "https://example.com/checkin"))
        #expect(AppSettings(defaults: defaults).checkInURL == URL(string: "https://example.com/checkin"))
        settings.checkInURL = nil
        #expect(AppSettings(defaults: defaults).checkInURL == nil)
    }
}
