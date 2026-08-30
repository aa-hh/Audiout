// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AudioutCore
@testable import AudioutSharedUI

/// Guards the volume HUD's readout — the replacement for the system volume
/// HUD that macOS stops drawing once Audiout is swallowing the keys. The pure
/// `Content` decision is asserted directly; the `show` path is asserted
/// through the panel's view read-back seams, which run in full headlessly
/// (only the actual `orderFront` is gated).
@Suite @MainActor struct VolumeHUDPanelTests {

    @Test func content_muted_saysMutedAndDrainsTheWaves() {
        let content = VolumeHUDPanel.content(volumePercent: 80, isMuted: true)
        #expect(content.symbolName == "speaker.slash.fill")
        #expect(content.variableValue == 0)
        #expect(content.text == "Muted")
    }

    @Test func content_unmuted_carriesThePercentAndTheLevel() {
        let content = VolumeHUDPanel.content(volumePercent: 55, isMuted: false)
        #expect(content.symbolName == "speaker.wave.3.fill")
        #expect(content.variableValue == 0.55)
        #expect(content.text == "55%")
    }

    @Test func show_appliesTheLevelToTheViews() {
        let panel = VolumeHUDPanel()
        panel.show(volumePercent: 80, isMuted: false, on: nil)
        #expect(panel.test_text == "80%")
        #expect(panel.test_symbolName == "speaker.wave.3.fill")
        #expect(panel.test_isShown)
    }

    @Test func show_appliesTheMutedStateToTheViews() {
        let panel = VolumeHUDPanel()
        panel.show(volumePercent: 80, isMuted: true, on: nil)
        #expect(panel.test_text == "Muted")
        #expect(panel.test_symbolName == "speaker.slash.fill")
    }

    /// A keypress landing mid-fade must win: `show()` re-arms the panel, and
    /// the in-flight dismiss it interrupted must not later order it back out.
    @Test func showDuringInFlightDismiss_leavesThePanelShownAtFullOpacity() {
        let panel = VolumeHUDPanel()
        panel.show(volumePercent: 50, isMuted: false, on: nil)
        panel.test_simulateDismiss()
        panel.show(volumePercent: 60, isMuted: false, on: nil)
        #expect(panel.test_isShown)
        #expect(panel.alphaValue == 1)
    }

    @Test func panel_isNonRestorableAndNonInteractive() {
        let panel = VolumeHUDPanel()
        // A menu-bar app restores no windows, and a transient readout must
        // never eat a click aimed at whatever is underneath it.
        #expect(panel.isRestorable == false)
        #expect(panel.ignoresMouseEvents)
    }

    /// One key press must move exactly one segment. The expected sequence is
    /// WALKED from `VolumeStep.next` itself, not hardcoded — the four
    /// transitions `VolumeKeyInterceptionTests` pins (0→6, 6→13, 13→19,
    /// 50→56) are not the whole detent sequence.
    @Test func filledSegments_landsOnAWholeSegmentAtEveryCoarseDetent() {
        var percent = 0
        var expectedSegment = 0.0
        #expect(VolumeHUDPanel.filledSegments(volumePercent: percent, isMuted: false) == expectedSegment)
        for _ in 0..<Int(VolumeStep.coarseDetents) {
            percent = VolumeStep.next(from: percent, up: true, fineStep: false)
            expectedSegment += 1
            #expect(VolumeHUDPanel.filledSegments(volumePercent: percent, isMuted: false) == expectedSegment)
        }
        #expect(percent == 100)
    }

    /// A `⇧⌥` fine step must quarter-fill a segment, not move it proportionally.
    @Test func filledSegments_landsOnAnExactQuarterAtFineDetents() {
        #expect(VolumeHUDPanel.filledSegments(volumePercent: 2, isMuted: false) == 0.25)
        #expect(VolumeHUDPanel.filledSegments(volumePercent: 48, isMuted: false) == 7.75)
        #expect(VolumeHUDPanel.filledSegments(volumePercent: 52, isMuted: false) == 8.25)
    }

    @Test func filledSegments_mutedIsAlwaysZero() {
        #expect(VolumeHUDPanel.filledSegments(volumePercent: 80, isMuted: true) == 0)
    }

    @Test func filledSegments_clampsOutOfRangePercent() {
        #expect(VolumeHUDPanel.filledSegments(volumePercent: -10, isMuted: false) == 0)
        #expect(VolumeHUDPanel.filledSegments(volumePercent: 150, isMuted: false) == VolumeStep.coarseDetents)
    }

    @Test func show_pushesTheRightSegmentCountToTheBar() {
        let panel = VolumeHUDPanel()
        panel.show(volumePercent: 80, isMuted: false, on: nil)
        // 12.75 written out, not re-derived from `filledSegments`: comparing
        // production against the very expression `show` calls can only fail if
        // `show` stops calling it at all.
        #expect(panel.test_filledSegments == 12.75)
    }

    @Test func show_recordsTheSpokenAnnouncement() {
        let panel = VolumeHUDPanel()
        panel.show(volumePercent: 80, isMuted: false, on: nil)
        #expect(panel.test_lastAnnouncement == "Volume 80%")
        panel.show(volumePercent: 80, isMuted: true, on: nil)
        #expect(panel.test_lastAnnouncement == "Volume muted")
    }
}
