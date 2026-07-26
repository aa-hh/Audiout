// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudiouterCore
@testable import AudiouterSettingsUI

/// The Advanced › Audio buffer control (PLAN-LATENCY-SETTING.md), driven
/// through the pane's `test_` hooks — same headless discipline as
/// `SettingsWindowControllerTests`. The apply CHOREOGRAPHY (remove-all → set →
/// re-add) is `NativeBackendTests`' job; here we assert the pane's contract:
/// section presence, numeric labels, CTA arming, the apply round-trip, and the
/// env-override disabled state.
@MainActor
@Suite struct AudioSettingsLatencyTests {

    private final class ApplyRecorder {
        var applied: [Int] = []
        var streaming = false
    }

    private func makeExcluded() -> ExcludedAppsController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiouterTests-\(UUID().uuidString)", isDirectory: true)
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

    @Test func noModelMeansNoAdvancedSection() {
        let pane = AudioSettingsViewController(excluded: makeExcluded(), runningAppsProvider: { [] })
        #expect(!pane.test_hasLatencySection)
    }

    @Test func optionsAreNumericMillisecondLabels() {
        let pane = makePane(recorder: ApplyRecorder())
        #expect(pane.test_hasLatencySection)
        let titles = pane.test_latencyOptionTitles
        #expect(titles.count == AppSettings.startBufferOptionsMs.count)
        // Numeric-label contract (localization decision): every item is a bare
        // number + "ms" — no preset names, no embedded delay descriptions.
        for title in titles {
            #expect(title.hasSuffix(" ms"), "expected bare numeric label, got \"\(title)\"")
            #expect(title.rangeOfCharacter(from: .letters.subtracting(CharacterSet(charactersIn: "ms"))) == nil,
                         "no words in option labels, got \"\(title)\"")
        }
    }

    @Test func changingSelectionArmsTheCTAWithContextualTitle() {
        let recorder = ApplyRecorder()
        let pane = makePane(recorder: recorder)

        // Unchanged selection: disarmed "Apply Settings".
        #expect(!pane.test_applyButtonEnabled)
        #expect(pane.test_applyButtonTitle == "Apply Settings")

        // Changed while idle: armed, still "Apply Settings" (instant, no gap).
        pane.test_selectLatencyOption(ms: 1500)
        #expect(pane.test_applyButtonEnabled)
        #expect(pane.test_applyButtonTitle == "Apply Settings")

        // Changed while streaming: armed and warns about the reconnect.
        recorder.streaming = true
        pane.test_selectLatencyOption(ms: 2250)
        #expect(pane.test_applyButtonEnabled)
        #expect(pane.test_applyButtonTitle == "Apply & Reconnect")

        // Back to the applied value: disarmed again.
        pane.test_selectLatencyOption(ms: 1000)
        #expect(!pane.test_applyButtonEnabled)
    }

    @Test func applyRoundTripInvokesModelAndDisarms() async {
        let recorder = ApplyRecorder()
        recorder.streaming = true
        let pane = makePane(recorder: recorder)

        pane.test_selectLatencyOption(ms: 1500)
        await pane.test_apply()

        #expect(recorder.applied == [1500])
        #expect(!pane.test_applyButtonEnabled, "applied value == pending → disarmed")
        #expect(pane.test_bufferPopupEnabled, "popup re-enabled after apply")
        #expect(pane.test_applyStatusText == "Speakers reconnected")

        // A second apply without a new change is a no-op.
        await pane.test_apply()
        #expect(recorder.applied == [1500])
    }

    @Test func applyWhileIdleShowsPlainConfirmation() async {
        let recorder = ApplyRecorder()
        let pane = makePane(recorder: recorder)
        pane.test_selectLatencyOption(ms: 2250)
        await pane.test_apply()
        #expect(recorder.applied == [2250])
        #expect(pane.test_applyStatusText == "Applied")
    }

    @Test func envOverrideRendersDisabled() {
        let pane = makePane(recorder: ApplyRecorder(), envOverrideMs: 750)
        #expect(pane.test_hasLatencySection)
        #expect(!pane.test_bufferPopupEnabled)
        #expect(pane.test_latencyOptionTitles.count == 1, "env mode shows just the env value")
        #expect(!pane.test_applyButtonEnabled, "no armable CTA in env-override mode")
    }

    @Test func windowControllerPassesModelThrough() {
        let suite = "AudiouterTests.\(UUID().uuidString)"
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
        #expect(controller.test_audio.test_hasLatencySection)
        #expect(controller.test_contentFittingSize.height > 100)
    }

    private final class NoopLoginItem: LoginItemManaging {
        var isEnabled: Bool { false }
        func setEnabled(_ newValue: Bool) throws {}
    }
}
