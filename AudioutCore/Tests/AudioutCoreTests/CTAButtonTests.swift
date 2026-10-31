// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudioutSharedUI

/// `CTAButton`, the iPhone's gold call-to-action face on the Mac.
@MainActor
@Suite struct CTAButtonTests {

    private final class Receiver: NSObject {
        var fired = 0
        @objc func fire(_ sender: Any?) { fired += 1 }
    }

    /// The button rendered offscreen under `appearance`, read at a point on
    /// the face clear of the title.
    private func facePixel(_ button: CTAButton, _ appearance: NSAppearance.Name) throws -> NSColor {
        button.appearance = NSAppearance(named: appearance)
        let rep = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: rep)
        return try #require(rep.colorAt(x: 8, y: 22)?.usingColorSpace(.sRGB))
    }

    /// Red if the primary's gold stopped being pinned to its dark value, so
    /// light mode drew the paper gold instead of the one gold.
    @Test func thePrimaryDrawsTheSameGoldInLightAndDark() throws {
        let button = CTAButton(title: "Buy Audiout", style: .primary, target: nil, action: nil)
        let cell = try #require(button.cell as? CTAButtonCell)
        let pinned = try #require(ProminentButton.pinnedDark(Tokens.Color.gold).usingColorSpace(.sRGB))
        #expect(cell.fill.usingColorSpace(.sRGB) == pinned)

        let light = try facePixel(button, .aqua)
        let dark = try facePixel(button, .darkAqua)
        for (l, d) in [(light.redComponent, dark.redComponent),
                       (light.greenComponent, dark.greenComponent),
                       (light.blueComponent, dark.blueComponent)] {
            #expect(abs(l - d) < 0.01, "light \(light) and dark \(dark) differ")
        }
        #expect(abs(light.redComponent - pinned.redComponent) < 0.03, "drew \(light), not the gold \(pinned)")
        #expect(abs(light.greenComponent - pinned.greenComponent) < 0.03, "drew \(light), not the gold \(pinned)")
    }

    /// Red if the secondary's edge stopped being `rim` or the primary gained one.
    @Test func theSecondaryEdgeIsTheRim() throws {
        let secondary = CTAButton(title: "Try free for 14 days", style: .secondary, target: nil, action: nil)
        let primary = CTAButton(title: "Buy Audiout", style: .primary, target: nil, action: nil)
        let cell = try #require(secondary.cell as? CTAButtonCell)
        let edge = try #require(cell.edge)
        // `rim` is a fresh dynamic colour on every read, so compare what it
        // resolves to in each appearance.
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            var drawn: NSColor?
            var expected: NSColor?
            try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                drawn = edge.usingColorSpace(.sRGB)
                expected = Tokens.Color.rim.usingColorSpace(.sRGB)
            }
            #expect(drawn != nil && drawn == expected, "\(name): edge \(String(describing: drawn))")
        }
        #expect(try #require(primary.cell as? CTAButtonCell).edge == nil)
    }

    /// Red if the floor moved from 200 x 44 pt, a stock bezel's insets came
    /// back around the face, the face hugged its floor so a width pin could
    /// not stretch it, or the secondary dropped to `body`.
    @Test(arguments: [CTAButton.Style.primary, .secondary])
    func theIntrinsicSizeIsTheiPhones(style: CTAButton.Style) {
        let button = CTAButton(title: "A title", style: style, target: nil, action: nil)
        #expect(button.intrinsicContentSize == NSSize(width: 200, height: 44))
        #expect(button.fittingSize == NSSize(width: 200, height: 44))
        #expect(button.contentHuggingPriority(for: .horizontal) < .required)
        #expect(button.font == Tokens.Font.heading)
    }

    /// Red if the chip stopped drawing on the Return default or its AX help
    /// went missing.
    @Test func theReturnDefaultWearsTheKeycapChip() throws {
        func rendered(_ keyEquivalent: String) throws -> (Data, String?) {
            let button = CTAButton(title: "Buy Audiout", style: .primary, target: nil, action: nil)
            button.keyEquivalent = keyEquivalent
            let rep = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: rep)
            let bytes = try #require(rep.bitmapData)
            return (Data(bytes: bytes, count: rep.bytesPerPlane * rep.numberOfPlanes), button.accessibilityHelp())
        }
        let (withChip, help) = try rendered("\r")
        let (plain, plainHelp) = try rendered("")
        #expect(withChip != plain)
        #expect(help == "Press Return")
        #expect(plainHelp == nil)
    }

    /// Red if the custom cell took over behaviour as well as paint, so a click
    /// (or VoiceOver's press, which is the same call) stopped reaching the action.
    @Test func theCellOnlyDrawsAndTheButtonStillFires() throws {
        let receiver = Receiver()
        let button = CTAButton(title: "Buy Audiout", style: .primary, target: receiver,
                               action: #selector(Receiver.fire(_:)))
        #expect(button.cell is CTAButtonCell)
        button.performClick(nil)
        #expect(receiver.fired == 1)
    }
}
