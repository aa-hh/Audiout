// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterCore
@testable import AudiouterSettingsUI

/// The Advanced › Local speaker sync offset control (T-OFFSET-UI), driven
/// through the pane's `test_` hooks — same headless discipline as
/// `AudioSettingsLatencyTests`. Persistence itself (default/round-trip/clamp) is
/// `AppSettingsTests`' job; here we assert the pane's contract: the section
/// mounts only alongside the Advanced buffer control (the native-backend gate),
/// the value label is a bare "±N ms" (no named preset), and a slider move
/// persists immediately with no CTA.
@MainActor
final class AudioSettingsSyncOffsetTests: XCTestCase {

    private func makeExcluded() -> ExcludedAppsController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiouterTests-\(UUID().uuidString)", isDirectory: true)
        return ExcludedAppsController(store: ExcludedAppsStore(directory: dir))
    }

    private func makeSettings() -> AppSettings {
        let suite = "AudiouterTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    private func makePane(settings: AppSettings, withLatencyModel: Bool = true) -> AudioSettingsViewController {
        let latency: LatencySettingModel? = withLatencyModel
            ? LatencySettingModel(
                optionsMs: AppSettings.startBufferOptionsMs, initialMs: 1000,
                envOverrideMs: nil, isStreaming: { false }, apply: { _ in })
            : nil
        return AudioSettingsViewController(
            excluded: makeExcluded(), runningAppsProvider: { [] }, settings: settings, latency: latency)
    }

    func testNoLatencyModelMeansNoSyncOffsetSection() {
        // Mirrors the Advanced buffer control's own gate — a backend without
        // `LatencyConfigurable` has no `SyncedLocalSink` either, so the offset
        // control (which only feeds that sink) has nothing to do.
        let pane = makePane(settings: makeSettings(), withLatencyModel: false)
        XCTAssertFalse(pane.test_hasSyncOffsetSection)
    }

    func testSectionMountsAlongsideAdvancedBufferControl() {
        let pane = makePane(settings: makeSettings())
        XCTAssertTrue(pane.test_hasLatencySection)
        XCTAssertTrue(pane.test_hasSyncOffsetSection)
    }

    func testInitialValueReflectsPersistedSetting() {
        let settings = makeSettings()
        settings.syncOffsetMs = 60
        let pane = makePane(settings: settings)
        XCTAssertEqual(pane.test_syncOffsetMs, 60)
        XCTAssertEqual(pane.test_syncOffsetValueLabel, "+60 ms")
    }

    func testDefaultsToZeroWhenUnset() {
        let pane = makePane(settings: makeSettings())
        XCTAssertEqual(pane.test_syncOffsetMs, 0)
        XCTAssertEqual(pane.test_syncOffsetValueLabel, "0 ms")
    }

    func testValueLabelIsBareNumberAndUnit() {
        // House rule (numeric localization): bare number + unit, never a named
        // preset with embedded description. Assert the label is exactly a
        // (optional sign) + digits + " ms" — no other letters, no other words.
        let settings = makeSettings()
        let pane = makePane(settings: settings)
        for ms in [0, 1, -1, 50, -50, 500, -500] {
            pane.test_setSyncOffset(ms: ms)
            let label = pane.test_syncOffsetValueLabel
            XCTAssertTrue(label.hasSuffix(" ms"), "expected bare numeric label, got \"\(label)\"")
            let lettersOtherThanMs = label.rangeOfCharacter(from: .letters.subtracting(CharacterSet(charactersIn: "ms")))
            XCTAssertNil(lettersOtherThanMs, "no words in the label, got \"\(label)\"")
        }
    }

    func testMovingTheSliderPersistsImmediately() {
        let settings = makeSettings()
        let pane = makePane(settings: settings)

        pane.test_setSyncOffset(ms: 75)
        XCTAssertEqual(settings.syncOffsetMs, 75, "no CTA — the slider persists on the spot")
        XCTAssertEqual(pane.test_syncOffsetValueLabel, "+75 ms")

        pane.test_setSyncOffset(ms: -40)
        XCTAssertEqual(settings.syncOffsetMs, -40)
        XCTAssertEqual(pane.test_syncOffsetValueLabel, "\u{2212}40 ms")
    }

    func testSliderBoundsMatchAppSettingsRange() {
        let pane = makePane(settings: makeSettings())
        let bounds = pane.test_syncOffsetBounds
        XCTAssertEqual(bounds.min, AppSettings.minSyncOffsetMs)
        XCTAssertEqual(bounds.max, AppSettings.maxSyncOffsetMs)
    }

    func testWindowControllerMountsSyncOffsetSection() {
        // `SettingsWindowController` doesn't currently thread its own `settings`
        // parameter into `AudioSettingsViewController` (pre-existing — the same
        // is true of the connect-volume control; both panes fall back to their
        // own `AppSettings()` default, which is the real store in production,
        // same as every other call site). So this only asserts structural
        // presence via the `latency` gate, mirroring
        // `AudioSettingsLatencyTests.testWindowControllerPassesModelThrough`
        // rather than a value round-trip through this particular path.
        let latency = LatencySettingModel(
            optionsMs: AppSettings.startBufferOptionsMs, initialMs: 1000,
            envOverrideMs: nil, isStreaming: { false }, apply: { _ in })
        let controller = SettingsWindowController(
            settings: makeSettings(),
            loginItem: NoopLoginItem(),
            excludedApps: makeExcluded(),
            runningAppsProvider: { [] },
            latency: latency)
        XCTAssertTrue(controller.test_audio.test_hasSyncOffsetSection)
    }

    private final class NoopLoginItem: LoginItemManaging {
        var isEnabled: Bool { false }
        func setEnabled(_ newValue: Bool) throws {}
    }
}
