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
        let image = StatusItemIcon.make(isStreaming: false, masterVolume: 0.5)
        #expect(image?.isTemplate == true)
    }

    @Test func streamingIcon_isTemplate() {
        let image = StatusItemIcon.make(isStreaming: true, masterVolume: 0.5)
        #expect(image?.isTemplate == true)
    }
}
