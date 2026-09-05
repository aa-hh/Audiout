// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
@testable import AudioutSharedUI

/// Regression coverage for the menu-bar status icon's platform-convention bug:
/// a prior version rendered the streaming state with a non-template accent
/// (`NSColor.controlAccentColor`) palette, which went nearly invisible on an
/// accent-matched wallpaper. Menu-bar status items must ALWAYS be template
/// images (see `StatusItemIcon`'s doc comment) — every state, including the
/// custom-drawn emitter-field glyph that replaced the SF Symbol.
@Suite struct StatusItemIconTests {

    @Test func idleIcon_isTemplate() {
        let image = StatusItemIcon.make(state: .idle, masterVolume: 0.5, isMuted: false)
        #expect(image?.isTemplate == true)
    }

    @Test func streamingIcon_isTemplate() {
        let image = StatusItemIcon.make(state: .streaming, masterVolume: 0.5, isMuted: false)
        #expect(image?.isTemplate == true)
    }

    @Test func failureIcon_isTemplate() {
        let image = StatusItemIcon.make(state: .failure, masterVolume: 0.5, isMuted: false)
        #expect(image != nil)
        #expect(image?.isTemplate == true)
    }

    /// The mute drain rule: a master-muted caller passes volume 0, and the
    /// field must collapse to the lone source dot. A crest surviving here
    /// would make the closed-panel glance lie "broadcasting" while silent —
    /// the exact honesty rule the old `variableValue` drain carried.
    @Test func mutedFrame_drainsEveryCrest() {
        let frame = StatusItemFieldFrame(tier: 1.0, volume: 0, solidDot: true)
        #expect(frame.crests.isEmpty)
    }

    /// Level must stay readable in the glyph: the field's reach has to admit
    /// more crests as volume rises, and full volume must show more than one
    /// (a single-ring 100% would collapse the level read to on/off).
    @Test func crestCount_growsWithVolume() {
        let low = StatusItemFieldFrame(tier: 1.0, volume: 0.3, solidDot: true).crests.count
        let mid = StatusItemFieldFrame(tier: 1.0, volume: 0.7, solidDot: true).crests.count
        let high = StatusItemFieldFrame(tier: 1.0, volume: 1.0, solidDot: true).crests.count
        #expect(low >= 1)
        #expect(low < mid)
        #expect(mid <= high)
        #expect(high > 1)
    }

    /// The idle tier dims the field but must never drop the first crest below
    /// the drawing floor at audible volumes — an idle icon with no waves at
    /// 70% volume would read as muted.
    @Test func idleFrame_keepsWavesVisible() {
        let frame = StatusItemFieldFrame(tier: 0.45, volume: 0.7, solidDot: false)
        #expect(!frame.crests.isEmpty)
    }
}
