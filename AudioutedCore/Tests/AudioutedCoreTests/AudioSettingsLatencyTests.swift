// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudioutedCore
@testable import AudioutedSettingsUI

/// The Advanced › Audio buffer control (PLAN-LATENCY-SETTING.md), driven
/// through the pane's `test_` hooks — same headless discipline as
/// `SettingsWindowControllerTests`. The apply CHOREOGRAPHY (remove-all → set →
/// re-add) is `NativeBackendTests`' job; here we assert the pane's contract:
/// section presence, numeric labels, CTA arming, the apply round-trip, and the
/// env-override disabled state.
@MainActor
final class AudioSettingsLatencyTests: XCTestCase {

    private final class ApplyRecorder {
        var applied: [Int] = []
        var streaming = false
    }

    private func makeExcluded() -> ExcludedAppsController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioutedTests-\(UUID().uuidString)", isDirectory: true)
        return ExcludedAppsController(store: ExcludedAppsStore(directory: dir))
    }

    private func makePane(
        recorder: ApplyRecorder,
        initialMs: Int = 1000,
        envOverrideMs: Int? = nil
    ) -> AudioSettingsViewController {
        let model = LatencySettingModel(
            optionsMs: AppSettings.startBufferOptionsMs,
            initialMs: initialMs,
            envOverrideMs: envOverrideMs,
            isStreaming: { recorder.streaming },
            apply: { ms in recorder.applied.append(ms) }
        )
        return AudioSettingsViewController(
            excluded: makeExcluded(), runningAppsProvider: { [] }, latency: model)
    }

    func testNoModelMeansNoAdvancedSection() {
        let pane = AudioSettingsViewController(excluded: makeExcluded(), runningAppsProvider: { [] })
        XCTAssertFalse(pane.test_hasLatencySection)
    }

    func testOptionsAreNumericMillisecondLabels() {
        let pane = makePane(recorder: ApplyRecorder())
        XCTAssertTrue(pane.test_hasLatencySection)
        let titles = pane.test_latencyOptionTitles
        XCTAssertEqual(titles.count, AppSettings.startBufferOptionsMs.count)
        // Numeric-label contract (localization decision): every item is a bare
        // number + "ms" — no preset names, no embedded delay descriptions.
        for title in titles {
            XCTAssertTrue(title.hasSuffix(" ms"), "expected bare numeric label, got \"\(title)\"")
            XCTAssertNil(title.rangeOfCharacter(from: .letters.subtracting(CharacterSet(charactersIn: "ms"))),
                         "no words in option labels, got \"\(title)\"")
        }
    }

    func testChangingSelectionArmsTheCTAWithContextualTitle() {
        let recorder = ApplyRecorder()
        let pane = makePane(recorder: recorder)

        // Unchanged selection: disarmed plain "Apply".
        XCTAssertFalse(pane.test_applyButtonEnabled)
        XCTAssertEqual(pane.test_applyButtonTitle, "Apply")

        // Changed while idle: armed, still plain "Apply" (instant, no gap).
        pane.test_selectLatencyOption(ms: 1500)
        XCTAssertTrue(pane.test_applyButtonEnabled)
        XCTAssertEqual(pane.test_applyButtonTitle, "Apply")

        // Changed while streaming: armed and warns about the reconnect.
        recorder.streaming = true
        pane.test_selectLatencyOption(ms: 2250)
        XCTAssertTrue(pane.test_applyButtonEnabled)
        XCTAssertEqual(pane.test_applyButtonTitle, "Apply & Reconnect")

        // Back to the applied value: disarmed again.
        pane.test_selectLatencyOption(ms: 1000)
        XCTAssertFalse(pane.test_applyButtonEnabled)
    }

    func testApplyRoundTripInvokesModelAndDisarms() async {
        let recorder = ApplyRecorder()
        recorder.streaming = true
        let pane = makePane(recorder: recorder)

        pane.test_selectLatencyOption(ms: 1500)
        await pane.test_apply()

        XCTAssertEqual(recorder.applied, [1500])
        XCTAssertFalse(pane.test_applyButtonEnabled, "applied value == pending → disarmed")
        XCTAssertTrue(pane.test_bufferPopupEnabled, "popup re-enabled after apply")
        XCTAssertEqual(pane.test_applyStatusText, "Speakers reconnected")

        // A second apply without a new change is a no-op.
        await pane.test_apply()
        XCTAssertEqual(recorder.applied, [1500])
    }

    func testApplyWhileIdleShowsPlainConfirmation() async {
        let recorder = ApplyRecorder()
        let pane = makePane(recorder: recorder)
        pane.test_selectLatencyOption(ms: 2250)
        await pane.test_apply()
        XCTAssertEqual(recorder.applied, [2250])
        XCTAssertEqual(pane.test_applyStatusText, "Applied")
    }

    func testEnvOverrideRendersDisabled() {
        let pane = makePane(recorder: ApplyRecorder(), envOverrideMs: 750)
        XCTAssertTrue(pane.test_hasLatencySection)
        XCTAssertFalse(pane.test_bufferPopupEnabled)
        XCTAssertEqual(pane.test_latencyOptionTitles.count, 1, "env mode shows just the env value")
        XCTAssertFalse(pane.test_applyButtonEnabled, "no armable CTA in env-override mode")
    }

    func testWindowControllerPassesModelThrough() {
        let suite = "AudioutedTests.\(name).\(ObjectIdentifier(self).hashValue)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = LatencySettingModel(
            optionsMs: AppSettings.startBufferOptionsMs, initialMs: 1000,
            envOverrideMs: nil, isStreaming: { false }, apply: { _ in })
        let controller = SettingsWindowController(
            settings: AppSettings(defaults: defaults),
            loginItem: NoopLoginItem(),
            excludedApps: makeExcluded(),
            runningAppsProvider: { [] },
            latency: model)
        XCTAssertTrue(controller.test_audio.test_hasLatencySection)
        XCTAssertGreaterThan(controller.test_contentFittingSize.height, 100)
    }

    private final class NoopLoginItem: LoginItemManaging {
        var isEnabled: Bool { false }
        func setEnabled(_ newValue: Bool) throws {}
    }
}
