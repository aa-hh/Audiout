// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
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

    @Test func panel_isNonRestorableAndNonInteractive() {
        let panel = VolumeHUDPanel()
        // A menu-bar app restores no windows, and a transient readout must
        // never eat a click aimed at whatever is underneath it.
        #expect(panel.isRestorable == false)
        #expect(panel.ignoresMouseEvents)
    }
}
