// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudioutSharedUI

/// The magenta identity light behind a group's seat: its core is heavier in
/// dark than on the light ground, it follows Increase Contrast live, it is
/// invisible to the pointer and to VoiceOver, and its falloff is unit-based so
/// one recipe serves every mounted size (the Main Out row at 60, the Groups
/// editor well at 80).
///
/// Nested under `SerializedSharedState` for one reason: the Increase-Contrast
/// test drives `Tokens.test_increaseContrastOverride`, which is process-wide.
extension SerializedSharedState {

@MainActor
@Suite struct GroupIdentityGlowViewTests {

    @Test func coreAlphaIsTwentyTwoDarkTenLight() {
        let view = GroupIdentityGlowView()

        view.appearance = NSAppearance(named: .darkAqua)
        #expect(abs((view.test_coreAlpha ?? -1) - 0.22) <= 0.004)

        view.appearance = NSAppearance(named: .aqua)
        #expect(abs((view.test_coreAlpha ?? -1) - 0.10) <= 0.004)
    }

    /// Increase Contrast is not part of the effective appearance, so only the
    /// workspace observer can catch it — without that, the glow would keep the
    /// standard-contrast magenta after the setting is turned on.
    @Test func coreFollowsIncreaseContrastLive() {
        defer { Tokens.test_increaseContrastOverride = nil }
        let view = GroupIdentityGlowView()
        view.appearance = NSAppearance(named: .aqua)

        Tokens.test_increaseContrastOverride = false
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        let base = view.test_coreColor?.usingColorSpace(.sRGB)

        Tokens.test_increaseContrastOverride = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        let increased = view.test_coreColor?.usingColorSpace(.sRGB)

        guard let base, let increased else {
            Issue.record("no stamped core colour")
            return
        }
        #expect(increased.redComponent != base.redComponent
                    || increased.blueComponent != base.blueComponent,
                "the core must re-resolve when Increase Contrast turns on")

        var expected: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            expected = Tokens.Color.partyRampDeep.usingColorSpace(.sRGB)
        }
        let want = try? #require(expected)
        #expect(abs(increased.redComponent - (want?.redComponent ?? -1)) <= 0.004)
        #expect(abs(increased.greenComponent - (want?.greenComponent ?? -1)) <= 0.004)
        #expect(abs(increased.blueComponent - (want?.blueComponent ?? -1)) <= 0.004)
    }

    @Test func glowIsNeitherHittableNorSpoken() {
        let view = GroupIdentityGlowView(
            frame: NSRect(x: 0, y: 0, width: GroupIdentityGlowView.side,
                          height: GroupIdentityGlowView.side))
        #expect(view.hitTest(NSPoint(x: GroupIdentityGlowView.side / 2,
                                     y: GroupIdentityGlowView.side / 2)) == nil)
        #expect(view.isAccessibilityElement() == false)
    }

    @Test func gradientFollowsTheMountedSize() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let view = GroupIdentityGlowView()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 80),
            view.heightAnchor.constraint(equalToConstant: 80),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        #expect(view.layer is CAGradientLayer)
        #expect(view.layer?.bounds.size == CGSize(width: 80, height: 80))
    }
}

}
