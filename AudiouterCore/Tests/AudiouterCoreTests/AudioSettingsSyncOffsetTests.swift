// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
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
@Suite struct AudioSettingsSyncOffsetTests {

    private func makeExcluded() -> ExcludedAppsController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiouterTests-\(UUID().uuidString)", isDirectory: true)
        return ExcludedAppsController(store: ExcludedAppsStore(directory: dir))
    }

    private func makeSettings() -> AppSettings {
        let suite = "AudiouterTests.\(UUID().uuidString)"
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

    @Test func noLatencyModelMeansNoSyncOffsetSection() {
        // Mirrors the Advanced buffer control's own gate — a backend without
        // `LatencyConfigurable` has no `SyncedLocalSink` either, so the offset
        // control (which only feeds that sink) has nothing to do.
        let pane = makePane(settings: makeSettings(), withLatencyModel: false)
        #expect(!pane.test_hasSyncOffsetSection)
    }

    @Test func sectionMountsAlongsideAdvancedBufferControl() {
        let pane = makePane(settings: makeSettings())
        #expect(pane.test_hasLatencySection)
        #expect(pane.test_hasSyncOffsetSection)
    }

    @Test func initialValueReflectsPersistedSetting() {
        let settings = makeSettings()
        settings.syncOffsetMs = 60
        let pane = makePane(settings: settings)
        #expect(pane.test_syncOffsetMs == 60)
        #expect(pane.test_syncOffsetValueLabel == "+60 ms")
    }

    @Test func defaultsToZeroWhenUnset() {
        let pane = makePane(settings: makeSettings())
        #expect(pane.test_syncOffsetMs == 0)
        #expect(pane.test_syncOffsetValueLabel == "0 ms")
    }

    @Test func valueLabelIsBareNumberAndUnit() {
        // House rule (numeric localization): bare number + unit, never a named
        // preset with embedded description. Assert the label is exactly a
        // (optional sign) + digits + " ms" — no other letters, no other words.
        let settings = makeSettings()
        let pane = makePane(settings: settings)
        for ms in [0, 1, -1, 50, -50, 500, -500] {
            pane.test_setSyncOffset(ms: ms)
            let label = pane.test_syncOffsetValueLabel
            #expect(label.hasSuffix(" ms"), "expected bare numeric label, got \"\(label)\"")
            let lettersOtherThanMs = label.rangeOfCharacter(from: .letters.subtracting(CharacterSet(charactersIn: "ms")))
            #expect(lettersOtherThanMs == nil, "no words in the label, got \"\(label)\"")
        }
    }

    @Test func movingTheSliderPersistsImmediately() {
        let settings = makeSettings()
        let pane = makePane(settings: settings)

        pane.test_setSyncOffset(ms: 75)
        #expect(settings.syncOffsetMs == 75, "no CTA — the slider persists on the spot")
        #expect(pane.test_syncOffsetValueLabel == "+75 ms")

        pane.test_setSyncOffset(ms: -40)
        #expect(settings.syncOffsetMs == -40)
        #expect(pane.test_syncOffsetValueLabel == "\u{2212}40 ms")
    }

    @Test func sliderBoundsMatchAppSettingsRange() {
        let pane = makePane(settings: makeSettings())
        let bounds = pane.test_syncOffsetBounds
        #expect(bounds.min == AppSettings.minSyncOffsetMs)
        #expect(bounds.max == AppSettings.maxSyncOffsetMs)
    }

    /// Structural presence via the `latency` gate: a latency-bearing Audio
    /// pane mounts the sync-offset section too, mirroring
    /// `AudioSettingsLatencyTests.rootMeasuresTheLatencyBearingAudioPane`
    /// rather than a value round-trip (the value tests above cover that).
    @Test func latencyBearingPaneMountsSyncOffsetSection() {
        let latency = LatencySettingModel(
            optionsMs: AppSettings.startBufferOptionsMs, initialMs: 1000,
            envOverrideMs: nil, isStreaming: { false }, apply: { _ in })
        let pane = AudioSettingsViewController(
            excluded: makeExcluded(),
            runningAppsProvider: { [] },
            settings: makeSettings(),
            latency: latency)
        #expect(pane.test_hasSyncOffsetSection)
    }
}
