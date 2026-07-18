// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterCore
@testable import AudiouterSettingsUI

/// The Settings › Audio wake-restore control (B6b), driven through the pane's
/// `test_` hooks — same headless discipline as `AudioSettingsLatencyTests`. The
/// watchdog BEHAVIOR (un-gating capture on no-reconnect) is `NativeBackendTests`'
/// job; here we assert the pane's contract: section presence, the option labels
/// (Never / N minute(s)), the initial selection, and that a pick applies through.
@MainActor
final class AudioSettingsWakeRestoreTests: XCTestCase {

    private final class ApplyRecorder { var applied: [Int] = [] }

    private func makeExcluded() -> ExcludedAppsController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiouterTests-\(UUID().uuidString)", isDirectory: true)
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

    func testNoModelMeansNoWakeRestoreSection() {
        let pane = AudioSettingsViewController(excluded: makeExcluded(), runningAppsProvider: { [] })
        XCTAssertFalse(pane.test_hasWakeRestoreSection)
    }

    func testOptionLabels() {
        let pane = makePane(recorder: ApplyRecorder())
        XCTAssertTrue(pane.test_hasWakeRestoreSection)
        XCTAssertEqual(pane.test_wakeRestoreOptionTitles,
                       ["Never", "1 minute", "2 minutes", "5 minutes", "10 minutes"])
    }

    func testInitialSelectionReflectsModel() {
        let pane = makePane(recorder: ApplyRecorder(), initialMinutes: 5)
        XCTAssertEqual(pane.test_wakeRestoreSelectedTitle, "5 minutes")
    }

    func testDefaultInitialSelectionIsTwoMinutes() {
        let pane = makePane(recorder: ApplyRecorder())
        XCTAssertEqual(pane.test_wakeRestoreSelectedTitle, "2 minutes")
    }

    func testPickingAppliesImmediately() {
        let recorder = ApplyRecorder()
        let pane = makePane(recorder: recorder)

        pane.test_selectWakeRestore(minutes: 10)
        XCTAssertEqual(recorder.applied, [10])

        // Never (0) applies too — a distinct, meaningful choice.
        pane.test_selectWakeRestore(minutes: 0)
        XCTAssertEqual(recorder.applied, [10, 0])
    }
}
