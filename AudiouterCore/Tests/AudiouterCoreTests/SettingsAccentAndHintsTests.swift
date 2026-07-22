// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterCore
@testable import AudiouterSettingsUI
@testable import AudiouterSharedUI

/// W1 (Warm Signal spec §1.3 / §5.2): the Appearance pane's **Accent dial**
/// (persist + live `Tokens.accentStyle` remap + notification) and the Audio
/// pane's **live hint lines** (the "`Buffer: 120 ms — safe for Wi-Fi
/// speakers`" pattern — a hint re-writes on every value change). Headless like
/// every other settings suite: structure and seams via `test_` hooks, never a
/// real window.
@MainActor
final class SettingsAccentAndHintsTests: IsolatedTestCase {

    private var settings: AppSettings { AppSettings(defaults: isolatedDefaults) }

    override func tearDown() {
        // `Tokens.accentStyle` is process-global on purpose (the live remap
        // seam); restore the flagship default so no other test in this suite —
        // or a later golden render in this process — inherits a dialed accent.
        Tokens.accentStyle = .fullGold
        super.tearDown()
    }

    // MARK: AppSettings scalar (UserDefaults idiom)

    func testAccentStyleDefaultsToFullGold() {
        XCTAssertEqual(settings.accentStyle, .fullGold)
    }

    func testAccentStyleRoundTripsEveryCase() {
        for style in AccentStyle.allCases {
            settings.accentStyle = style
            XCTAssertEqual(AppSettings(defaults: isolatedDefaults).accentStyle, style)
        }
    }

    func testAccentStyleUnknownStoredValueFallsBack() {
        isolatedDefaults.set("chartreuse", forKey: "appearance.accentStyle")
        XCTAssertEqual(settings.accentStyle, .fullGold)
    }

    // MARK: Appearance pane — Accent dial

    private func makeAppearancePane() -> AppearanceSettingsViewController {
        AppearanceSettingsViewController(settings: settings)
    }

    func testAccentDialDefaultsToFullGold() {
        XCTAssertEqual(makeAppearancePane().test_selectedAccentStyle, .fullGold)
    }

    func testAccentDialInitialisesFromPersistedStyle() {
        settings.accentStyle = .systemAccent
        XCTAssertEqual(makeAppearancePane().test_selectedAccentStyle, .systemAccent)
    }

    func testSelectingAccentPersistsRemapsAndNotifies() {
        let pane = makeAppearancePane()
        var notified: [AccentStyle] = []
        pane.onAccentChanged = { notified.append($0) }

        pane.test_selectAccentStyle(.subtle)

        XCTAssertEqual(pane.test_selectedAccentStyle, .subtle)
        XCTAssertEqual(settings.accentStyle, .subtle)
        XCTAssertEqual(Tokens.accentStyle, .subtle)
        XCTAssertEqual(notified, [.subtle])
    }

    func testAccentHintTracksSelection() {
        let pane = makeAppearancePane()
        let fullGoldHint = pane.test_accentHint
        XCTAssertFalse(fullGoldHint.isEmpty)

        pane.test_selectAccentStyle(.systemAccent)
        let systemHint = pane.test_accentHint
        XCTAssertFalse(systemHint.isEmpty)
        XCTAssertNotEqual(systemHint, fullGoldHint, "the hint is LIVE — it must re-write per dial position")
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

    func testSubtleRemapsGoldAndRemovesGlow() {
        let fullGold = resolved(Tokens.Color.gold, appearanceName: .darkAqua)

        Tokens.accentStyle = .subtle
        let subtleGold = resolved(Tokens.Color.gold, appearanceName: .darkAqua)
        XCTAssertNotEqual(subtleGold, fullGold, "Subtle must desaturate the gold channel")
        // Spec §1.3: Subtle has NO glow ("no glow shadow") — the token resolves
        // fully clear so every halo/bloom call site goes quiet.
        XCTAssertEqual(resolved(Tokens.Color.glow, appearanceName: .darkAqua).alphaComponent, 0)
    }

    func testSystemAccentPullsControlAccentIntoGold() {
        Tokens.accentStyle = .systemAccent
        let gold = resolved(Tokens.Color.gold, appearanceName: .darkAqua)
        let accent = resolved(NSColor.controlAccentColor, appearanceName: .darkAqua)
        XCTAssertEqual(gold.redComponent, accent.redComponent, accuracy: 0.001)
        XCTAssertEqual(gold.greenComponent, accent.greenComponent, accuracy: 0.001)
        XCTAssertEqual(gold.blueComponent, accent.blueComponent, accuracy: 0.001)

        // Ember = accent × 0.55 luminance (component-scaled), strictly dimmer.
        let ember = resolved(Tokens.Color.ember, appearanceName: .darkAqua)
        XCTAssertEqual(ember.redComponent, accent.redComponent * 0.55, accuracy: 0.005)
        XCTAssertEqual(ember.greenComponent, accent.greenComponent * 0.55, accuracy: 0.005)
        XCTAssertEqual(ember.blueComponent, accent.blueComponent * 0.55, accuracy: 0.005)
    }

    func testAccentDialNeverRemapsFailureCautionOrRing() {
        let failure = resolved(Tokens.Color.failure, appearanceName: .darkAqua)
        let caution = resolved(Tokens.Color.caution, appearanceName: .darkAqua)
        let ring = resolved(Tokens.Color.ringConnected, appearanceName: .darkAqua)
        for style in AccentStyle.allCases {
            Tokens.accentStyle = style
            XCTAssertEqual(resolved(Tokens.Color.failure, appearanceName: .darkAqua), failure)
            XCTAssertEqual(resolved(Tokens.Color.caution, appearanceName: .darkAqua), caution)
            XCTAssertEqual(resolved(Tokens.Color.ringConnected, appearanceName: .darkAqua), ring)
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

    func testConnectVolumeHintTracksTheSlider() {
        let pane = makeAudioPane()
        pane.test_setConnectVolume(percent: 35)
        XCTAssertTrue(pane.test_connectVolumeHint.contains("35%"),
                      "hint must state the CURRENT value: \(pane.test_connectVolumeHint)")
        let moderate = pane.test_connectVolumeHint

        pane.test_setConnectVolume(percent: 90)
        XCTAssertTrue(pane.test_connectVolumeHint.contains("90%"))
        XCTAssertNotEqual(pane.test_connectVolumeHint, moderate,
                          "the consequence wording must follow the value band")
    }

    func testBufferHintTracksTheSelection() {
        let latency = LatencySettingModel(optionsMs: AppSettings.startBufferOptionsMs,
                                          initialMs: 1000,
                                          envOverrideMs: nil,
                                          isStreaming: { false },
                                          apply: { _ in })
        let pane = makeAudioPane(latency: latency)
        XCTAssertTrue(pane.test_bufferHint.contains("1,000 ms") || pane.test_bufferHint.contains("1000 ms"),
                      "hint must state the current value: \(pane.test_bufferHint)")
        let initialHint = pane.test_bufferHint

        pane.test_selectLatencyOption(ms: 2250)
        XCTAssertTrue(pane.test_bufferHint.contains("2,250 ms") || pane.test_bufferHint.contains("2250 ms"))
        XCTAssertNotEqual(pane.test_bufferHint, initialHint)
    }

    func testWakeRestoreHintTracksTheSelection() {
        var applied: [Int] = []
        let model = WakeAudioRestoreModel(minuteOptions: AppSettings.wakeRestoreMinuteOptions,
                                          initialMinutes: 2,
                                          apply: { applied.append($0) })
        let pane = makeAudioPane(wakeRestore: model)
        let initialHint = pane.test_wakeRestoreHint
        XCTAssertFalse(initialHint.isEmpty)

        pane.test_selectWakeRestore(minutes: 0)
        XCTAssertNotEqual(pane.test_wakeRestoreHint, initialHint)
        XCTAssertTrue(pane.test_wakeRestoreHint.localizedCaseInsensitiveContains("never"),
                      "the Never position needs its own honest wording: \(pane.test_wakeRestoreHint)")
        XCTAssertEqual(applied, [0])
    }
}
