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

    /// Generating a fresh seed on every read, or ignoring the store it was
    /// given, turns it red.
    @Test func engineInstallSeedIsStablePerStoreAndDiffersAcrossStores() {
        let first = AppSettings(defaults: defaults).engineInstallSeed
        #expect(first != 0)
        #expect(AppSettings(defaults: defaults).engineInstallSeed == first)
        let other = TestIsolation(owner: "AppSettingsTests.seed")
        #expect(AppSettings(defaults: other.isolatedDefaults).engineInstallSeed != first)
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

    /// `telemetryEnabled` is what gates every send, so each row here is a real
    /// failure: a paid install defaulting ON leaks data nobody agreed to, a
    /// trial install defaulting OFF loses the trial-phase visibility this
    /// default exists for, and an answer the default overrides makes the
    /// Settings toggle a lie.
    @Test(arguments: [
        // key,     trialExpiry, asked, optIn, expected
        (nil,       false,       false, false, true),   // first launch, nothing stored
        ("TRIAL-1", true,        false, false, true),   // trial running, or expired unconverted
        ("PAID-1",  false,       false, false, false),  // paid, not asked yet
        ("PAID-1",  false,       true,  true,  true),   // paid, said yes
        ("TRIAL-1", true,        true,  false, false),  // trial, turned it off in Settings
        (nil,       false,       true,  false, false),  // no key, turned it off in Settings
    ] as [(key: String?, trialExpiry: Bool, asked: Bool, optIn: Bool, expected: Bool)])
    func telemetryEnabledCombinesTheAnswerWithTheTrialDefault(
        row: (key: String?, trialExpiry: Bool, asked: Bool, optIn: Bool, expected: Bool)
    ) {
        let settings = AppSettings(defaults: defaults)
        // Key first: its setter clears every trial field when set to nil.
        settings.licenseKey = row.key
        settings.trialExpiresAt = row.trialExpiry ? Date() : nil
        settings.telemetryAsked = row.asked
        settings.telemetryOptIn = row.optIn

        #expect(settings.telemetryEnabled == row.expected)
    }

    @Test func telemetryConversionAskShownRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.telemetryConversionAskShown == false)
        settings.telemetryConversionAskShown = true
        #expect(AppSettings(defaults: defaults).telemetryConversionAskShown == true)
    }

    @Test func telemetryDailyActiveDayRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.telemetryDailyActiveDay == nil)
        settings.telemetryDailyActiveDay = "2026-09-12"
        #expect(AppSettings(defaults: defaults).telemetryDailyActiveDay == "2026-09-12")
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

    // Turns red if a dev build starts listening on the network before its
    // owner turns the switch on, or the shipping app stops defaulting on.
    @Test func allowRemoteControlDefaultsOffOnlyOnDevBuilds() {
        #expect(AppSettings.defaultAllowRemoteControl(isDevBuild: false))
        #expect(!AppSettings.defaultAllowRemoteControl(isDevBuild: true))
    }

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

    // Turns red if the shipping app (or the test runner) counts as a dev build,
    // which would put the companion switch and a listening server in a release.
    @Test func onlySuffixedBundleIDsAreDevBuilds() {
        #expect(AppSettings.isDevBundleID("com.audiout.Audiout.dev"))
        #expect(AppSettings.isDevBundleID("com.audiout.Audiout.staging"))
        #expect(!AppSettings.isDevBundleID("com.audiout.Audiout"))
        #expect(!AppSettings.isDevBundleID("com.apple.dt.xctest.tool"))
        #expect(!AppSettings.isDevBundleID(nil))
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
        #expect(AppSettings.resolvedAllowRemoteControl(environment: [:], offered: true, settings: settings))

        settings.allowRemoteControl = false
        #expect(!AppSettings.resolvedAllowRemoteControl(environment: [:], offered: true, settings: settings))
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
        #expect(AppSettings.resolvedAllowRemoteControl(environment: ["AUDIOUT_COMPANION": "banana"], offered: true, settings: settings))

        settings.allowRemoteControl = false
        #expect(!AppSettings.resolvedAllowRemoteControl(environment: ["AUDIOUT_COMPANION": "banana"], offered: true, settings: settings))
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
        let resolution = AppSettings.resolvedAllowRemoteControlWithSource(environment: [:], offered: true, settings: settings)
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
            environment: ["AUDIOUT_COMPANION": "banana"], offered: true, settings: settings)
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

    // MARK: Companion - a build that does not carry the phone app
    //
    // `remoteAppIsOffered` is false until Audiout Remote is on the App Store.
    // Every companion surface reads the resolution, so these three pin what
    // that build resolves to.

    @Test func anUnofferedBuildResolvesOffEvenWhenTheSettingSaysOn() {
        // The setting defaults to TRUE, so a build that forgot to consult
        // `offered` would start the companion server and show the Setup
        // window's iPhone card in a release with no phone app to pair with.
        let settings = AppSettings(defaults: defaults)
        settings.allowRemoteControl = true
        let resolution = AppSettings.resolvedAllowRemoteControlWithSource(
            environment: [:], offered: false, settings: settings)
        #expect(resolution == .unoffered)
        #expect(!resolution.value)
    }

    @Test func theEnvOverrideStillWinsOverAnUnofferedBuild() {
        // How a dev build gets the feature back to test against a TestFlight
        // phone. Ordering `offered` above the env var would take that away.
        let settings = AppSettings(defaults: defaults)
        settings.allowRemoteControl = false
        let resolution = AppSettings.resolvedAllowRemoteControlWithSource(
            environment: ["AUDIOUT_COMPANION": "on"], offered: false, settings: settings)
        #expect(resolution == .forced(true))
        #expect(resolution.value)
    }

    @Test func unofferedIsNotForced() {
        // `.forced` mounts Settings' "a launch option is controlling this
        // setting" note. Reporting an unoffered build as forced would blame a
        // launch option nobody passed, and the pane drops the whole row here
        // anyway, so `isUnoffered` is what a caller asks.
        let resolution = AppSettings.RemoteControlResolution.unoffered
        #expect(!resolution.isForced)
        #expect(resolution.isUnoffered)
        #expect(!AppSettings.RemoteControlResolution.setting(false).isUnoffered)
        #expect(!AppSettings.RemoteControlResolution.forced(false).isUnoffered)
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

    /// A bare dictionary standing in for the Keychain, so these tests never touch it.
    /// `failWrites` and `refuseReads` make it refuse every write or read, as a
    /// locked keychain does.
    private final class InMemorySecretStore: SecretStoring {
        var values: [String: String] = [:]
        var failWrites = false
        var refuseReads = false
        func read(_ key: String) -> SecretRead {
            guard !refuseReads else { return .refused }
            return values[key].map(SecretRead.value) ?? .missing
        }
        func write(_ value: String?, for key: String) -> Bool {
            guard !failWrites else { return false }
            values[key] = value
            return true
        }
    }

    /// Turns red if the first read stops moving a key an older build left in
    /// `UserDefaults` into the secret store (leaving it as plain text), or if
    /// clearing the key lets the leftover copy migrate back.
    @Test func aLicenceKeyLeftInDefaultsMovesToTheSecretStoreOnFirstRead() {
        let store = InMemorySecretStore()
        defaults.set("OLD-KEY", forKey: "license.key")
        let settings = AppSettings(defaults: defaults, secrets: store)
        #expect(settings.licenseKey == "OLD-KEY")
        #expect(store.read("license.key") == .value("OLD-KEY"))
        #expect(defaults.string(forKey: "license.key") == nil)
        settings.licenseKey = nil
        #expect(store.read("license.key") == .missing)
        #expect(settings.licenseKey == nil)
    }

    /// Turns red if `readSecret` removes the `UserDefaults` copy after the
    /// secret store refused the migration write, which deletes the only copy
    /// of the licence key, or if a later read stops retrying the move.
    @Test func aRefusedMigrationKeepsTheLicenceKeyInDefaultsAndRetries() {
        let store = InMemorySecretStore()
        store.failWrites = true
        defaults.set("OLD-KEY", forKey: "license.key")
        let settings = AppSettings(defaults: defaults, secrets: store)
        #expect(settings.licenseKey == "OLD-KEY")
        #expect(defaults.string(forKey: "license.key") == "OLD-KEY")
        #expect(AppSettings(defaults: defaults, secrets: store).licenseKey == "OLD-KEY")
        store.failWrites = false
        #expect(settings.licenseKey == "OLD-KEY")
        #expect(store.read("license.key") == .value("OLD-KEY"))
        #expect(defaults.string(forKey: "license.key") == nil)
    }

    /// Turns red if `writeSecret` drops a value the secret store refused
    /// instead of keeping it in `UserDefaults`.
    @Test func aRefusedWriteKeepsTheLicenceKeyReadableFromDefaults() {
        let store = InMemorySecretStore()
        store.failWrites = true
        let settings = AppSettings(defaults: defaults, secrets: store)
        settings.licenseKey = "NEW-KEY"
        #expect(store.read("license.key") == .missing)
        #expect(defaults.string(forKey: "license.key") == "NEW-KEY")
        #expect(settings.licenseKey == "NEW-KEY")
        #expect(AppSettings(defaults: defaults, secrets: store).licenseKey == "NEW-KEY")
    }

    /// Turns red if a read the secret store refused (a locked login keychain)
    /// makes a registered Mac look unregistered, so it plays on one speaker
    /// and sees the first-open gate, or if that read moves or deletes the
    /// copy in `UserDefaults`.
    @Test func aRefusedReadKeepsARegisteredMacRegistered() {
        let store = InMemorySecretStore()
        store.values["license.key"] = "PAID-KEY"
        let settings = AppSettings(defaults: defaults,
                                   licenseServerURL: URL(string: "https://license.example.com")!,
                                   secrets: store)
        settings.licenseStatus = .active
        store.refuseReads = true

        #expect(!LicenseGate.limitsToOneSpeaker(settings: settings))
        #expect(!LicenseGate.shouldPresent(settings: settings, presentation: .auto))

        defaults.set("old-token", forKey: "license.companionToken")
        #expect(settings.companionToken == "old-token")
        #expect(defaults.string(forKey: "license.companionToken") == "old-token",
                "a refused read leaves the defaults copy where it is")
    }

    /// Turns red if `hasLicenseKey` counts every refused read as a stored key,
    /// which makes a Mac that never had one read as registered whenever its
    /// keychain is locked.
    @Test func aRefusedReadWithNoVerdictAndNoDefaultsCopyIsNoKey() {
        let store = InMemorySecretStore()
        store.refuseReads = true
        let settings = AppSettings(defaults: defaults, secrets: store)
        #expect(!settings.hasLicenseKey)
        #expect(settings.licenseUnregistered)
    }

    /// Turns red if a read that finds a value in the secret store ignores the
    /// newer copy a refused write left in `UserDefaults`, which brings back the
    /// key the user replaced, or if that copy is removed before the store has
    /// taken it.
    @Test func aDefaultsCopyLeftByARefusedWriteWinsOverTheStoredKey() {
        let store = InMemorySecretStore()
        store.values["license.key"] = "OLD-KEY"
        defaults.set("NEW-KEY", forKey: "license.key")
        store.failWrites = true
        let settings = AppSettings(defaults: defaults, secrets: store)
        #expect(settings.licenseKey == "NEW-KEY")
        #expect(defaults.string(forKey: "license.key") == "NEW-KEY")
        store.failWrites = false
        #expect(settings.licenseKey == "NEW-KEY")
        #expect(store.read("license.key") == .value("NEW-KEY"))
        #expect(defaults.string(forKey: "license.key") == nil)
    }

    /// Turns red if the companion token skips the migration the licence key gets.
    @Test func companionTokenFollowsTheSameMigration() {
        let store = InMemorySecretStore()
        defaults.set("old-token", forKey: "license.companionToken")
        let settings = AppSettings(defaults: defaults, secrets: store)
        #expect(settings.companionToken == "old-token")
        #expect(store.read("license.companionToken") == .value("old-token"))
        #expect(defaults.string(forKey: "license.companionToken") == nil)
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

    // MARK: The buy URL and the trial id it carries

    private static let buyPage = URL(string: "https://audiout.app/buy")!
    private static let trialKey = "AUDT-AAAAA-BBBBB-CCCCC-DDDDD"
    /// The Buy page as the app opens it: tagged so the site knows the click
    /// came from the app.
    private static let taggedBuyPage = URL(string: "https://audiout.app/buy?s=mac-app")!

    private func buySettings() -> AppSettings {
        AppSettings(defaults: defaults, buyURL: Self.buyPage)
    }

    /// Red if the trial id started riding along for someone who is not on a
    /// trial: a paid key, or a build from source with no purchase page at all.
    @Test func buyURLCarriesNoTrialIDWithoutATrial() {
        let settings = buySettings()
        settings.licenseKey = Self.trialKey
        settings.licenseStatus = .active
        #expect(settings.buyURL == Self.taggedBuyPage)

        #expect(AppSettings(defaults: defaults).buyURL == nil,
                "a build with no purchase page still has none")
    }

    /// Red if the checkout stopped being told which trial it is converting —
    /// the buyer would then have to paste a key by hand.
    @Test func buyURLCarriesTheTrialKeyWhileATrialRuns() {
        let settings = buySettings()
        TrialClock.apply(settings: settings,
                         startedAt: Date(),
                         expiresAt: Date(timeIntervalSinceNow: 9 * 86_400),
                         key: Self.trialKey)
        #expect(settings.buyURL
                == URL(string: "https://audiout.app/buy?s=mac-app&t=\(Self.trialKey)"))
    }

    /// Red if a trial that has not reached the server yet started inventing a
    /// `t` for the checkout to look up.
    @Test func buyURLCarriesNoTrialIDBeforeAKey() {
        let settings = buySettings()
        TrialClock.start(settings: settings)
        #expect(settings.buyURL == Self.taggedBuyPage, "an unregistered trial has no key to send")
    }

    /// Red if an expired trial stopped sending its key — the checkout could no
    /// longer activate that Mac without a pasted key.
    @Test func buyURLCarriesTheTrialIDAfterExpiry() {
        let expired = AppSettings(defaults: isolation.makeDefaults(), buyURL: Self.buyPage)
        TrialClock.apply(settings: expired,
                         startedAt: Date(timeIntervalSinceNow: -20 * 86_400),
                         expiresAt: Date(timeIntervalSinceNow: -6 * 86_400),
                         key: Self.trialKey)
        #expect(expired.buyURL == URL(string: "https://audiout.app/buy?s=mac-app&t=\(Self.trialKey)"))
    }

    /// Red if a converted trial sent its paid key as a trial id.
    @Test func buyURLCarriesNoTrialIDAfterConversion() {
        let converted = AppSettings(defaults: isolation.makeDefaults(), buyURL: Self.buyPage)
        TrialClock.apply(settings: converted,
                         startedAt: Date(timeIntervalSinceNow: -3 * 86_400),
                         expiresAt: Date(timeIntervalSinceNow: 11 * 86_400),
                         key: Self.trialKey)
        converted.trialExpiresAt = nil
        #expect(converted.buyURL == Self.taggedBuyPage)
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
