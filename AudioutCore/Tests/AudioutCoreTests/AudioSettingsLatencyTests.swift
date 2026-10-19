// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutSettingsUI
@testable import AudioutSharedUI

/// The Advanced › Audio buffer control (PLAN-LATENCY-SETTING.md; V1 immediate
/// apply, PLAN-ONE-SURFACE-032.md), driven through the pane's `test_` hooks —
/// same headless discipline as `SettingsRootViewControllerTests`. The apply
/// CHOREOGRAPHY (remove-all → set → re-add) is `NativeBackendTests`' job; here
/// we assert the pane's contract: section presence, numeric labels, that a
/// popup selection applies exactly once, that reselecting the current value
/// is a no-op, and the env-override disabled state.
@MainActor
@Suite struct AudioSettingsLatencyTests {

    private final class ApplyRecorder {
        var applied: [Int] = []
        var streaming = false
        var beforeResult: (() async -> Void)?
        /// What the backend reports back: how many of the devices that were
        /// streaming actually came back. Defaults to a clean full reconnect.
        var result: (reconnected: Int, expected: Int) = (1, 1)
    }

    private func makeExcluded() -> ExcludedAppsController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioutTests-\(UUID().uuidString)", isDirectory: true)
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
            apply: { ms in
                recorder.applied.append(ms)
                await recorder.beforeResult?()
                return recorder.result
            }
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

    // Keeping feedback mounted before applying or after clearing turns it red.
    @Test func selectingANewValueAppliesExactlyOnce() async throws {
        let recorder = ApplyRecorder()
        recorder.streaming = true
        let pane = makePane(recorder: recorder)

        let card = try advancedCard(in: pane)
        #expect(card.rows.count == 1)
        await pane.test_selectLatencyOption(ms: 1500)

        #expect(card.rows.count == 2)
        #expect(recorder.applied == [1500], "one apply, with the chosen value")
        #expect(pane.test_bufferPopupEnabled, "popup re-enabled after apply")
        #expect(pane.test_applyStatusText == "Speakers reconnected")
        await pane.test_selectLatencyOption(ms: 1500)
        #expect(pane.test_applyStatusText == nil)
        #expect(card.rows.count == 1)
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

    /// The pane must not claim a reconnect it didn't get: the re-add is
    /// best-effort per device, so a speaker that stayed down has to be said out
    /// loud rather than papered over with "Speakers reconnected".
    @Test func partialReconnectSaysSoInsteadOfClaimingSuccess() async throws {
        let recorder = ApplyRecorder()
        recorder.streaming = true
        recorder.result = (reconnected: 1, expected: 2)
        let pane = makePane(recorder: recorder)

        await pane.test_selectLatencyOption(ms: 1500)

        #expect(pane.test_applyStatusText == "Some speakers didn't reconnect. Reconnect them from the Mixer.")
        #expect(try advancedCard(in: pane).rows.count == 2)
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

    @Test func envOverrideRendersDisabled() throws {
        let pane = makePane(recorder: ApplyRecorder(), envOverrideMs: 750)
        #expect(pane.test_hasLatencySection)
        #expect(!pane.test_bufferPopupEnabled)
        #expect(pane.test_latencyOptionTitles.count == 1, "env mode shows just the env value")
        #expect(try advancedCard(in: pane).rows.count == 2, "the launch-option warning remains mounted")
    }

    // Omitting the feedback row while the backend is still reconnecting turns it red.
    @Test func reconnectingMountsFeedbackUntilTheApplyFinishes() async throws {
        let recorder = ApplyRecorder()
        recorder.streaming = true
        let pane = makePane(recorder: recorder)
        let card = try advancedCard(in: pane)
        #expect(card.rows.count == 1)
        var resumeApply: CheckedContinuation<Void, Never>?
        var selection: Task<Void, Never>?
        await withCheckedContinuation { started in
            recorder.beforeResult = {
                await withCheckedContinuation { pending in
                    resumeApply = pending
                    started.resume()
                }
            }
            selection = Task { await pane.test_selectLatencyOption(ms: 1500) }
        }
        #expect(!pane.test_bufferPopupEnabled)
        #expect(pane.test_applyStatusText == "Reconnecting speakers…")
        #expect(card.rows.count == 2)
        resumeApply?.resume()
        await selection?.value
        #expect(pane.test_applyStatusText == "Speakers reconnected")
        #expect(card.rows.count == 2)
        await pane.test_selectLatencyOption(ms: 1500)
        #expect(card.rows.count == 1)
    }

    private func advancedCard(in pane: AudioSettingsViewController) throws -> GroupedSectionView {
        func cards(in view: NSView) -> [GroupedSectionView] {
            (view as? GroupedSectionView).map { [$0] } ?? view.subviews.flatMap { cards(in: $0) }
        }
        return try #require(cards(in: pane.view).first { card in
            card.rows.contains { ($0 as? ListRowView)?.titleLabel.stringValue == "Audio buffer" }
        })
    }

    /// A latency-bearing Audio pane mounted on the root (the surface's
    /// Settings screen): the section renders and the mounted pane has a real
    /// size — i.e. the model survives the assembly the app does in
    /// `AppDelegate.makeSettingsRoot`.
    @Test func rootMeasuresTheLatencyBearingAudioPane() {
        let model = LatencySettingModel(
            optionsMs: AppSettings.startBufferOptionsMs, initialMs: 1000,
            envOverrideMs: nil, isStreaming: { false }, apply: { _ in (0, 0) })
        let audio = AudioSettingsViewController(
            excluded: makeExcluded(), runningAppsProvider: { [] }, latency: model)
        let root = SettingsRootViewController(sections: [
            .init(title: "Audio", symbolName: "speaker.wave.2", viewController: audio),
        ])
        #expect(audio.test_hasLatencySection)
        root.selectSection(at: 0)
        #expect(audio.view.fittingSize.height > 100)
    }
}
