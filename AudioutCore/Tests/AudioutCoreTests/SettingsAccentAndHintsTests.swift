// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudioutCore
@testable import AudioutSettingsUI
@testable import AudioutSharedUI

/// W1 (Warm Signal spec §1.3 / §5.2): the Appearance pane's **Accent dial**
/// (persist + live `Tokens.accentStyle` remap + notification) and the Audio
/// pane's **live hint lines** (the "`Buffer: 120 ms — safe for Wi-Fi
/// speakers`" pattern — a hint re-writes on every value change). Headless like
/// every other settings suite: structure and seams via `test_` hooks, never a
/// real window.
///
/// Nested into `SerializedSharedState`: `Tokens.accentStyle` is process-global
/// (see the `deinit` below), and `OnboardingPermissionColorTests` mutates the
/// same global — under swift-testing's in-process concurrency the two suites
/// running at once produced real, reproducible failures (color comparisons
/// racing a concurrent accent-style write), invisible under XCTest's
/// one-process-per-test-method model.
extension SerializedSharedState {

@MainActor
@Suite final class SettingsAccentAndHintsTests: IsolatedSuite {

    private var settings: AppSettings { AppSettings(defaults: isolatedDefaults) }

    deinit {
        // `Tokens.accentStyle` is process-global on purpose (the live remap
        // seam); restore the flagship default so no other test in this suite —
        // or a later golden render in this process — inherits a dialed accent.
        Tokens.accentStyle = .fullGold
    }

    // MARK: AppSettings scalar (UserDefaults idiom)

    @Test func accentStyleDefaultsToFullGold() {
        #expect(settings.accentStyle == .fullGold)
    }

    @Test func accentStyleRoundTripsEveryCase() {
        for style in AccentStyle.allCases {
            settings.accentStyle = style
            #expect(AppSettings(defaults: isolatedDefaults).accentStyle == style)
        }
    }

    @Test func accentStyleUnknownStoredValueFallsBack() {
        isolatedDefaults.set("chartreuse", forKey: "appearance.accentStyle")
        #expect(settings.accentStyle == .fullGold)
    }

    // MARK: Appearance pane — Accent dial

    private func makeAppearancePane() -> AppearanceSettingsViewController {
        AppearanceSettingsViewController(settings: settings)
    }

    @Test func accentDialDefaultsToFullGold() {
        #expect(makeAppearancePane().test_selectedAccentStyle == .fullGold)
    }

    @Test func accentDialInitialisesFromPersistedStyle() {
        settings.accentStyle = .systemAccent
        #expect(makeAppearancePane().test_selectedAccentStyle == .systemAccent)
    }

    @Test func selectingAccentPersistsRemapsAndNotifies() {
        let pane = makeAppearancePane()
        var notified: [AccentStyle] = []
        pane.onAccentChanged = { notified.append($0) }

        pane.test_selectAccentStyle(.subtle)

        #expect(pane.test_selectedAccentStyle == .subtle)
        #expect(settings.accentStyle == .subtle)
        #expect(Tokens.accentStyle == .subtle)
        #expect(notified == [.subtle])
    }

    @Test func accentHintTracksSelection() {
        let pane = makeAppearancePane()
        let fullGoldHint = pane.test_accentHint
        #expect(!fullGoldHint.isEmpty)

        pane.test_selectAccentStyle(.systemAccent)
        let systemHint = pane.test_accentHint
        #expect(!systemHint.isEmpty)
        #expect(systemHint != fullGoldHint, "the hint is LIVE — it must re-write per dial position")
    }

    // MARK: Token remap (spec §1.3 table)

    /// Resolve `color` to concrete sRGB under an explicit appearance (the same
    /// way AppKit resolves a dynamic provider at draw time).
    private func resolved(_ color: NSColor, appearanceName: NSAppearance.Name) -> NSColor {
        var result = color
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    @Test func subtleRemapsGoldAndRemovesGlow() {
        let fullGold = resolved(Tokens.Color.gold, appearanceName: .darkAqua)

        Tokens.accentStyle = .subtle
        let subtleGold = resolved(Tokens.Color.gold, appearanceName: .darkAqua)
        #expect(subtleGold != fullGold, "Subtle must desaturate the gold channel")
        // Spec §1.3: Subtle has NO glow ("no glow shadow") — the token resolves
        // fully clear so every halo/bloom call site goes quiet.
        #expect(resolved(Tokens.Color.glow, appearanceName: .darkAqua).alphaComponent == 0)
    }

    @Test func systemAccentPullsControlAccentIntoGold() {
        Tokens.accentStyle = .systemAccent
        let gold = resolved(Tokens.Color.gold, appearanceName: .darkAqua)
        let accent = resolved(NSColor.controlAccentColor, appearanceName: .darkAqua)
        #expect(abs(gold.redComponent - accent.redComponent) <= 0.001)
        #expect(abs(gold.greenComponent - accent.greenComponent) <= 0.001)
        #expect(abs(gold.blueComponent - accent.blueComponent) <= 0.001)

        // Ember = accent × 0.55 luminance (component-scaled), strictly dimmer.
        let ember = resolved(Tokens.Color.ember, appearanceName: .darkAqua)
        #expect(abs(ember.redComponent - accent.redComponent * 0.55) <= 0.005)
        #expect(abs(ember.greenComponent - accent.greenComponent * 0.55) <= 0.005)
        #expect(abs(ember.blueComponent - accent.blueComponent * 0.55) <= 0.005)
    }

    @Test func accentDialNeverRemapsFailureCautionOrRing() {
        let failure = resolved(Tokens.Color.failure, appearanceName: .darkAqua)
        let caution = resolved(Tokens.Color.caution, appearanceName: .darkAqua)
        let ring = resolved(Tokens.Color.ringConnected, appearanceName: .darkAqua)
        for style in AccentStyle.allCases {
            Tokens.accentStyle = style
            #expect(resolved(Tokens.Color.failure, appearanceName: .darkAqua) == failure)
            #expect(resolved(Tokens.Color.caution, appearanceName: .darkAqua) == caution)
            #expect(resolved(Tokens.Color.ringConnected, appearanceName: .darkAqua) == ring)
        }
    }

    // MARK: Audio pane — live hint lines

    private func makeAudioPane(latency: LatencySettingModel? = nil,
                               wakeRestore: WakeAudioRestoreModel? = nil) -> AudioSettingsViewController {
        let store = ExcludedAppsStore(directory: scratchDir)
        return AudioSettingsViewController(excluded: ExcludedAppsController(store: store),
                                           runningAppsProvider: { [] },
                                           settings: settings,
                                           latency: latency,
                                           wakeRestore: wakeRestore)
    }

    @Test func connectVolumeHintTracksTheSlider() {
        let pane = makeAudioPane()
        pane.test_setConnectVolume(percent: 35)
        #expect(pane.test_connectVolumeHint.contains("35%"),
                      "hint must state the CURRENT value: \(pane.test_connectVolumeHint)")
        let moderate = pane.test_connectVolumeHint

        pane.test_setConnectVolume(percent: 90)
        #expect(pane.test_connectVolumeHint.contains("90%"))
        #expect(pane.test_connectVolumeHint != moderate,
                          "the consequence wording must follow the value band")
    }

    @Test func bufferHintTracksTheSelection() async {
        let latency = LatencySettingModel(optionsMs: AppSettings.startBufferOptionsMs,
                                          initialMs: 1000,
                                          envOverrideMs: nil,
                                          isStreaming: { false },
                                          apply: { _ in (0, 0) })
        let pane = makeAudioPane(latency: latency)
        #expect(pane.test_bufferHint.contains("1,000 ms") || pane.test_bufferHint.contains("1000 ms"),
                      "hint must state the current value: \(pane.test_bufferHint)")
        let initialHint = pane.test_bufferHint

        await pane.test_selectLatencyOption(ms: 2250)
        #expect(pane.test_bufferHint.contains("2,250 ms") || pane.test_bufferHint.contains("2250 ms"))
        #expect(pane.test_bufferHint != initialHint)
    }

    @Test func wakeRestoreHintTracksTheSelection() {
        var applied: [Int] = []
        let model = WakeAudioRestoreModel(minuteOptions: AppSettings.wakeRestoreMinuteOptions,
                                          initialMinutes: 2,
                                          apply: { applied.append($0) })
        let pane = makeAudioPane(wakeRestore: model)
        let initialHint = pane.test_wakeRestoreHint
        #expect(!initialHint.isEmpty)

        pane.test_selectWakeRestore(minutes: 0)
        #expect(pane.test_wakeRestoreHint != initialHint)
        #expect(pane.test_wakeRestoreHint.localizedCaseInsensitiveContains("never"),
                      "the Never position needs its own honest wording: \(pane.test_wakeRestoreHint)")
        #expect(applied == [0])
    }

    // MARK: Audio pane — Advanced disclosure (roadmap 050)

    @Test func advancedDisclosureStartsCollapsedAndRepublishesOnToggle() {
        let latency = LatencySettingModel(optionsMs: AppSettings.startBufferOptionsMs,
                                          initialMs: 1000,
                                          envOverrideMs: nil,
                                          isStreaming: { false },
                                          apply: { _ in (0, 0) })
        let pane = makeAudioPane(latency: latency)
        _ = pane.view
        pane.view.layoutSubtreeIfNeeded()
        #expect(!pane.test_advancedExpanded, "Advanced must ship collapsed")
        let collapsedHeight = pane.preferredContentSize.height

        pane.test_toggleAdvanced()
        #expect(pane.test_advancedExpanded)
        #expect(pane.preferredContentSize.height > collapsedHeight,
                "expanding must republish a taller preferredContentSize")

        let expandedHeight = pane.preferredContentSize.height
        // Collapse via the TITLE, not the triangle — the word "Advanced" is a
        // click target mirroring it.
        pane.test_tapAdvancedTitle()
        #expect(!pane.test_advancedExpanded)
        // Not an exact == against the pre-toggle height: AppKit's rounding
        // grid shifts layout by fractions of a point between passes.
        #expect(pane.preferredContentSize.height < expandedHeight,
                "collapsing must republish a shorter preferredContentSize")
    }

    // MARK: General pane — reconnect-at-launch (roadmap 050)

    private final class StubLoginItem: LoginItemManaging {
        var isEnabled = false
        func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
    }

    @Test func reconnectAtLaunchTogglePersistsAndHintTracks() {
        let pane = GeneralSettingsViewController(loginItem: StubLoginItem(), settings: settings)
        #expect(!pane.test_reconnectAtLaunchIsOn, "defaults off")
        let offHint = pane.test_reconnectHint
        #expect(!offHint.isEmpty)

        pane.test_toggleReconnectAtLaunch(true)
        #expect(AppSettings(defaults: isolatedDefaults).reconnectAtLaunch)
        #expect(pane.test_reconnectHint != offHint)

        pane.test_toggleReconnectAtLaunch(false)
        #expect(!AppSettings(defaults: isolatedDefaults).reconnectAtLaunch)
        #expect(pane.test_reconnectHint == offHint)
    }
}

} // extension SerializedSharedState
