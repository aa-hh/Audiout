// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
@testable import AudioutSharedUI

/// Regression coverage for the menu-bar status icon's platform-convention bug:
/// a prior version rendered the streaming state with a non-template accent
/// (`NSColor.controlAccentColor`) palette, which went nearly invisible on an
/// accent-matched wallpaper. Menu-bar status items must ALWAYS be template
/// images (see `StatusItemIcon`'s doc comment) — both idle and streaming.
@Suite struct StatusItemIconTests {

    @Test func idleIcon_isTemplate() {
        let image = StatusItemIcon.make(state: .idle, masterVolume: 0.5, isMuted: false)
        #expect(image?.isTemplate == true)
    }

    @Test func streamingIcon_isTemplate() {
        let image = StatusItemIcon.make(state: .streaming, masterVolume: 0.5, isMuted: false)
        #expect(image?.isTemplate == true)
    }

    /// Non-nil is the real assertion here: it proves the badge symbol
    /// (`speaker.badge.exclamationmark`) actually resolves on the runner's
    /// macOS, so the failure state can never render as a blank menu bar.
    @Test func failureIcon_isTemplate() {
        let image = StatusItemIcon.make(state: .failure, masterVolume: 0.5, isMuted: false)
        #expect(image != nil)
        #expect(image?.isTemplate == true)
    }
}
