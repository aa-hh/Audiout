// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutSettingsUI

/// The Settings › Audio wake-restore control (B6b), driven through the pane's
/// `test_` hooks — same headless discipline as `AudioSettingsLatencyTests`. The
/// watchdog BEHAVIOR (un-gating capture on no-reconnect) is `NativeBackendTests`'
/// job; here we assert the pane's contract: section presence, the option labels
/// (Never / N minute(s)), the initial selection, and that a pick applies through.
@MainActor
@Suite struct AudioSettingsWakeRestoreTests {

    private final class ApplyRecorder { var applied: [Int] = [] }

    private func makeExcluded() -> ExcludedAppsController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioutTests-\(UUID().uuidString)", isDirectory: true)
        return ExcludedAppsController(store: ExcludedAppsStore(directory: dir))
    }

    private func makePane(recorder: ApplyRecorder,
                          initialMinutes: Int = AppSettings.defaultWakeRestoreMinutes) -> AudioSettingsViewController {
        let model = WakeAudioRestoreModel(
            minuteOptions: AppSettings.wakeRestoreMinuteOptions,
            initialMinutes: initialMinutes,
            apply: { minutes in recorder.applied.append(minutes) })
        return AudioSettingsViewController(
            excluded: makeExcluded(), runningAppsProvider: { [] }, wakeRestore: model)
    }

    @Test func noModelMeansNoWakeRestoreSection() {
        let pane = AudioSettingsViewController(excluded: makeExcluded(), runningAppsProvider: { [] })
        #expect(!pane.test_hasWakeRestoreSection)
    }

    @Test func optionLabels() {
        let pane = makePane(recorder: ApplyRecorder())
        #expect(pane.test_hasWakeRestoreSection)
        #expect(pane.test_wakeRestoreOptionTitles ==
                       ["Never", "1 minute", "2 minutes", "5 minutes", "10 minutes"])
    }

    @Test func initialSelectionReflectsModel() {
        let pane = makePane(recorder: ApplyRecorder(), initialMinutes: 5)
        #expect(pane.test_wakeRestoreSelectedTitle == "5 minutes")
    }

    @Test func defaultInitialSelectionIsTwoMinutes() {
        let pane = makePane(recorder: ApplyRecorder())
        #expect(pane.test_wakeRestoreSelectedTitle == "2 minutes")
    }

    @Test func pickingAppliesImmediately() {
        let recorder = ApplyRecorder()
        let pane = makePane(recorder: recorder)

        pane.test_selectWakeRestore(minutes: 10)
        #expect(recorder.applied == [10])

        // Never (0) applies too — a distinct, meaningful choice.
        pane.test_selectWakeRestore(minutes: 0)
        #expect(recorder.applied == [10, 0])
    }
}
