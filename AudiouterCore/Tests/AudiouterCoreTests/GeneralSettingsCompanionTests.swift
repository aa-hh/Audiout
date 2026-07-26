// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterSettingsUI

/// FIX-C: the Settings › General "Allow control from iPhone" checkbox must
/// never misrepresent whether the companion LAN server is actually running.
///
/// Before this fix, `GeneralSettingsViewController` rendered and wrote
/// `AppSettings.allowRemoteControl` directly — the RAW persisted bool — while
/// `AppDelegate` started/stopped the server from
/// `AppSettings.resolvedAllowRemoteControl`, which lets `AUDIOUTER_COMPANION`
/// win over that same setting. With the env var set, the checkbox could show
/// OFF on a fresh profile while a LAN server was running, and unchecking it
/// did nothing — a checkbox that lies is the worst kind of security-relevant
/// UI bug. These assert the pane now reflects the EFFECTIVE (resolved) state,
/// disables itself and explains why while an override is in force, and stays
/// exactly as before when no override is present.
@MainActor
@Suite struct GeneralSettingsCompanionTests {

    /// A `LoginItemManaging` fake — never touches real `SMAppService`;
    /// irrelevant to these tests beyond satisfying the initializer.
    private final class FakeLoginItem: LoginItemManaging {
        var isEnabled: Bool = false
        func setEnabled(_ newValue: Bool) throws { isEnabled = newValue }
    }

    private func makeSettings() -> AppSettings {
        let suite = "AudiouterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    private func makePane(settings: AppSettings, environment: [String: String]) -> GeneralSettingsViewController {
        GeneralSettingsViewController(loginItem: FakeLoginItem(), settings: settings, environment: environment)
    }

    // MARK: No override present — unchanged behavior

    @Test func noOverrideReflectsRawSettingAndIsEnabled() {
        let settings = makeSettings()
        settings.allowRemoteControl = true
        let pane = makePane(settings: settings, environment: [:])

        #expect(pane.test_allowRemoteControlIsOn)
        #expect(pane.test_allowRemoteControlIsEnabled)
        #expect(pane.test_allowRemoteControlOverrideNote == nil)
    }

    @Test func noOverrideTogglingWritesTheSettingAndFiresCallback() {
        let settings = makeSettings()
        settings.allowRemoteControl = false
        let pane = makePane(settings: settings, environment: [:])

        var callbackFired = false
        pane.onAllowRemoteControlChanged = { callbackFired = true }

        pane.test_toggleAllowRemoteControl(true)
        #expect(pane.test_allowRemoteControlIsOn)
        #expect(settings.allowRemoteControl)
        #expect(callbackFired)

        callbackFired = false
        pane.test_toggleAllowRemoteControl(false)
        #expect(!pane.test_allowRemoteControlIsOn)
        #expect(!settings.allowRemoteControl)
        #expect(callbackFired)
    }

    @Test func garbageEnvValueBehavesAsNoOverride() {
        // An unrecognized env value falls back to the setting AND must not
        // lock the checkbox — only a RECOGNIZED override may disable it.
        let settings = makeSettings()
        settings.allowRemoteControl = true
        let pane = makePane(settings: settings, environment: ["AUDIOUTER_COMPANION": "banana"])

        #expect(pane.test_allowRemoteControlIsOn)
        #expect(pane.test_allowRemoteControlIsEnabled)
        #expect(pane.test_allowRemoteControlOverrideNote == nil)
    }

    // MARK: Override present — the checkbox must be honest

    @Test func overridePresentReflectsEffectiveValueAndDisables() {
        let settings = makeSettings()
        // The setting says OFF; the env var forces ON. Pre-fix, the checkbox
        // rendered OFF (the raw setting) while the server actually ran.
        settings.allowRemoteControl = false
        let pane = makePane(settings: settings, environment: ["AUDIOUTER_COMPANION": "1"])

        #expect(pane.test_allowRemoteControlIsOn)
        #expect(!pane.test_allowRemoteControlIsEnabled)
        let note = pane.test_allowRemoteControlOverrideNote
        #expect(note != nil)
        #expect(note?.contains("AUDIOUTER_COMPANION") == true)
    }

    @Test func overrideForcedOffAlsoReflectsEffectiveValue() {
        let settings = makeSettings()
        settings.allowRemoteControl = true
        let pane = makePane(settings: settings, environment: ["AUDIOUTER_COMPANION": "off"])

        #expect(!pane.test_allowRemoteControlIsOn)
        #expect(!pane.test_allowRemoteControlIsEnabled)
        #expect(pane.test_allowRemoteControlOverrideNote != nil)
    }

    @Test func overridePresentTogglingIsImpossibleNotSilentlyIneffective() {
        let settings = makeSettings()
        settings.allowRemoteControl = false
        let pane = makePane(settings: settings, environment: ["AUDIOUTER_COMPANION": "1"])

        var callbackFired = false
        pane.onAllowRemoteControlChanged = { callbackFired = true }

        // Attempt to uncheck it, exactly as the (disabled, in the real UI)
        // control's action would run if somehow invoked.
        pane.test_toggleAllowRemoteControl(false)

        // The checkbox bounces back to the effective (forced) value rather
        // than adopting the attempted state, the setting is untouched, and no
        // "changed" callback fires — nothing about reality actually changed.
        #expect(pane.test_allowRemoteControlIsOn)
        #expect(!settings.allowRemoteControl)
        #expect(!callbackFired)
    }
}
