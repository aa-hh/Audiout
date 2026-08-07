// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudiouterCore
@testable import AudiouterSettingsUI

/// The Advanced › Audio buffer control (PLAN-LATENCY-SETTING.md; V1 immediate
/// apply, PLAN-ONE-SURFACE-032.md), driven through the pane's `test_` hooks —
/// same headless discipline as `SettingsWindowControllerTests`. The apply
/// CHOREOGRAPHY (remove-all → set → re-add) is `NativeBackendTests`' job; here
/// we assert the pane's contract: section presence, numeric labels, that a
/// popup selection applies exactly once, that reselecting the current value
/// is a no-op, and the env-override disabled state.
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

    @Test func selectingANewValueAppliesExactlyOnce() async {
        let recorder = ApplyRecorder()
        recorder.streaming = true
        let pane = makePane(recorder: recorder)

        await pane.test_selectLatencyOption(ms: 1500)

        #expect(recorder.applied == [1500], "one apply, with the chosen value")
        #expect(pane.test_bufferPopupEnabled, "popup re-enabled after apply")
        #expect(pane.test_applyStatusText == "Speakers reconnected")
    }

    @Test func reselectingTheCurrentValueDoesNotApply() async {
        let recorder = ApplyRecorder()
        let pane = makePane(recorder: recorder, initialMs: 1000)

        // Same value the pane already started on: no apply fires.
        await pane.test_selectLatencyOption(ms: 1000)
        #expect(recorder.applied.isEmpty, "reselecting the current value must not apply")

        // A genuine change still applies normally afterward.
        await pane.test_selectLatencyOption(ms: 1500)
        #expect(recorder.applied == [1500])

        // And the newly-applied value is itself now a no-op reselection.
        await pane.test_selectLatencyOption(ms: 1500)
        #expect(recorder.applied == [1500], "reselecting the just-applied value must not re-apply")
    }

    @Test func applyWhileIdleShowsPlainConfirmation() async {
        let recorder = ApplyRecorder()
        let pane = makePane(recorder: recorder)
        await pane.test_selectLatencyOption(ms: 2250)
        #expect(recorder.applied == [2250])
        #expect(pane.test_applyStatusText == "Applied")
    }

    @Test func hintStatesTheReconnectCost() {
        let pane = makePane(recorder: ApplyRecorder())
        #expect(pane.test_bufferHint.localizedCaseInsensitiveContains("reconnects"),
                      "the hint must state the cost of changing the buffer up front — no CTA left to carry it: \(pane.test_bufferHint)")
    }

    @Test func envOverrideRendersDisabled() {
        let pane = makePane(recorder: ApplyRecorder(), envOverrideMs: 750)
        #expect(pane.test_hasLatencySection)
        #expect(!pane.test_bufferPopupEnabled)
        #expect(pane.test_latencyOptionTitles.count == 1, "env mode shows just the env value")
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
        // `test_contentFittingSize` measures the SELECTED tab, and the Audio
        // tab isn't selected by default (the window always opens on General) —
        // select it first or this asserts General's height, not the Audio
        // pane's.
        controller.test_selectTab(at: 2)
        #expect(controller.test_contentFittingSize.height > 100)
    }

    private final class NoopLoginItem: LoginItemManaging {
        var isEnabled: Bool { false }
        func setEnabled(_ newValue: Bool) throws {}
    }
}
