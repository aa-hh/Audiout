// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
import AudioutSharedUI
@testable import AudioutCore
@testable import AudioutSettingsUI

/// `AudioSettingsViewController.reloadFromSettings()` — the pane's answer to a
/// value changing under it.
///
/// The two controls here are the only settings a REMOTE client can write
/// (`setConnectVolume` / `setStartBufferMs`), and this pane builds its controls
/// once while the surface caches the whole screen for the process's life — so
/// without a reconcile a phone-driven change showed the launch-time value
/// permanently, not merely until the pane was reopened.
@MainActor
@Suite final class AudioSettingsRemoteReloadTests: IsolatedSuite {

    private func makeExcluded() -> ExcludedAppsController {
        ExcludedAppsController(store: ExcludedAppsStore(directory: scratchDir))
    }

    private func makePane(settings: AppSettings,
                          initialMs: Int = 1000,
                          envOverrideMs: Int? = nil) -> AudioSettingsViewController {
        let latency = LatencySettingModel(
            optionsMs: AppSettings.startBufferOptionsMs,
            initialMs: initialMs,
            envOverrideMs: envOverrideMs,
            isStreaming: { false },
            apply: { _ in (reconnected: 0, expected: 0) }
        )
        return AudioSettingsViewController(excluded: makeExcluded(),
                                           runningAppsProvider: { [] },
                                           settings: settings,
                                           latency: latency)
    }

    @Test func aConnectVolumeWrittenElsewhereLandsOnTheNextReload() {
        let settings = AppSettings(defaults: isolatedDefaults)
        settings.connectVolume = 25
        let pane = makePane(settings: settings)
        #expect(pane.test_connectVolumePercent == 25)

        // What the phone's `setConnectVolume` does: writes the setting, with
        // nothing telling this already-built pane about it.
        settings.connectVolume = 70
        #expect(pane.test_connectVolumePercent == 25, "still painting the value it was built with")

        pane.reloadFromSettings()

        #expect(pane.test_connectVolumePercent == 70)
        #expect(pane.test_connectVolumeValueLabel.contains("70"),
                "the trailing readout follows the slider, got \"\(pane.test_connectVolumeValueLabel)\"")
    }

    /// The hint line states the chosen value's consequence, so it is as stale
    /// as the slider until reconciled.
    // Leaving connection-volume or Bluetooth-pause help stale after a settings reload turns this red.
    @Test func theConnectVolumeHintReloadsWithTheSlider() {
        let settings = AppSettings(defaults: isolatedDefaults)
        settings.connectVolume = 20
        settings.btKeepAliveMinutes = 0
        let pane = makePane(settings: settings)
        let before = pane.test_connectVolumeHint

        settings.connectVolume = 95
        settings.btKeepAliveMinutes = AppSettings.btKeepAliveMinuteOptions.first(where: { $0 > 0 }) ?? 0
        pane.reloadFromSettings()

        #expect(pane.test_connectVolumeHint != before, "the hint must not describe the old level")
        func pauseHelp(in view: NSView) -> HelpButton? {
            if let help = view as? HelpButton,
               help.accessibilityLabel() == "Help for Keep Bluetooth speakers streaming during pauses" { return help }
            return view.subviews.lazy.compactMap { pauseHelp(in: $0) }.first
        }
        let help = pauseHelp(in: pane.view)
        #expect(help?.toolTip?.hasPrefix("During pauses up to ") == true)
        #expect(help?.accessibilityHelp() == help?.toolTip)

    }

    @Test func aBufferWrittenElsewhereLandsOnTheNextReload() throws {
        let settings = AppSettings(defaults: isolatedDefaults)
        settings.startBufferMs = 1000
        let pane = makePane(settings: settings, initialMs: 1000)
        // Reading a hook loads the view, which is the state this reconcile is
        // for: an on-screen pane. An unloaded one has no controls to move.
        let titles = pane.test_latencyOptionTitles
        let chosenIndex = try #require(AppSettings.startBufferOptionsMs.firstIndex { $0 != 1000 })
        let chosen = AppSettings.startBufferOptionsMs[chosenIndex]

        settings.startBufferMs = chosen
        pane.reloadFromSettings()

        // Compared against the popup's OWN label for that option — the pane
        // formats with a thousands separator, and pinning a hand-built string
        // here would be testing the formatter, not the reload.
        #expect(pane.test_bufferSelectedTitle == titles[chosenIndex])
        #expect(pane.test_bufferHint.contains(titles[chosenIndex].replacingOccurrences(of: " ms", with: "")),
                "the buffer hint states the applied value, got \"\(pane.test_bufferHint)\"")
    }

    // Reconciling only loaded controls or resetting the applied buffer on first mount turns this red.
    @Test func reloadingAnUnloadedPaneDoesNotBuildIt() throws {
        let settings = AppSettings(defaults: isolatedDefaults)
        settings.startBufferMs = 1000
        let pane = makePane(settings: settings, initialMs: 1500)
        let provider: any SettingsReadoutProviding = pane
        #expect(provider.readoutLines == ["No apps stay on this Mac", "Buffer 1500 ms"],
                "before a reload the readout reports the backend's initial buffer")
        let chosenIndex = try #require(AppSettings.startBufferOptionsMs.firstIndex { $0 != 1000 && $0 != 1500 })
        let chosen = AppSettings.startBufferOptionsMs[chosenIndex]
        settings.startBufferMs = chosen

        pane.reloadFromSettings()

        #expect(!pane.isViewLoaded, "a reconcile must not construct the pane it was asked to refresh")
        #expect(provider.readoutLines == ["No apps stay on this Mac", "Buffer \(chosen) ms"])

        let titles = pane.test_latencyOptionTitles
        #expect(pane.test_bufferSelectedTitle == titles[chosenIndex])
        #expect(pane.test_bufferHint.contains(titles[chosenIndex]),
                "the first-mounted help must describe the reconciled buffer")
        #expect(provider.readoutLines == ["No apps stay on this Mac", "Buffer \(chosen) ms"],
                "constructing the popup must not reset the sidebar value")
    }

    /// Under an env override the popup carries the override as its one item and
    /// is disabled outright; a reload must leave that alone rather than trying
    /// to select a value that isn't offered.
    @Test func anEnvOverriddenBufferPopupIsLeftUntouched() {
        let settings = AppSettings(defaults: isolatedDefaults)
        let pane = makePane(settings: settings, initialMs: 1000, envOverrideMs: 4321)
        let before = pane.test_bufferSelectedTitle

        settings.startBufferMs = AppSettings.startBufferOptionsMs.first ?? 1000
        pane.reloadFromSettings()

        #expect(pane.test_bufferSelectedTitle == before, "the override still names the popup")
        #expect(!pane.test_bufferPopupEnabled, "and it stays disabled")
    }

    /// A pane with no latency model has no popup at all — the reload must not
    /// assume one is there.
    @Test func aPaneWithoutTheAdvancedSectionReloadsTheVolumeAlone() {
        let settings = AppSettings(defaults: isolatedDefaults)
        settings.connectVolume = 30
        let pane = AudioSettingsViewController(excluded: makeExcluded(),
                                               runningAppsProvider: { [] },
                                               settings: settings)
        #expect(!pane.test_hasLatencySection)

        settings.connectVolume = 80
        pane.reloadFromSettings()

        #expect(pane.test_connectVolumePercent == 80)
    }
}
