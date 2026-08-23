// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterSharedUI
@testable import AudiouterPopoverUI

/// The **alignment-wizard plate skin** (`AlignmentPlateCell`/
/// `AlignmentPlateButton`, wizard-stage v2 spec §3): a drawing-only
/// `NSButtonCell` swap, the same "only the drawing changes" contract
/// `WarmFaderCellTests` covers for the row sliders. This is a state-paint
/// SMOKE pass — determinism, primary-vs-secondary and pressed-vs-rest
/// divergence, the focus-ring mask override, and the AX contract — not a
/// pixel-exact golden comparison (no golden PNGs exist for this cell).
@MainActor
@Suite struct AlignmentPlateCellTests {

    // MARK: Helpers

    private func makeButton(title: String = "Target",
                            keycap: String? = "←",
                            isPrimary: Bool = false,
                            identityTint: NSColor? = nil) -> AlignmentPlateButton {
        let button = AlignmentPlateButton(frame: NSRect(x: 0, y: 0, width: 220, height: 64))
        button.configure(title: title, keycap: keycap, isPrimary: isPrimary, identityTint: identityTint)
        return button
    }

    private func render(_ button: AlignmentPlateButton,
                        appearance: NSAppearance.Name = .aqua) throws -> Data {
        button.appearance = NSAppearance(named: appearance)
        button.layoutSubtreeIfNeeded()
        let rep = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: rep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    // MARK: (a) Determinism — two cacheDisplay renders of the same state are byte-equal

    @Test func renderIsByteDeterministic() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let button = makeButton()
            let first = try render(button, appearance: appearanceName)
            let second = try render(button, appearance: appearanceName)
            #expect(first == second,
                    "\(appearanceName.rawValue): plate drawing must be byte-deterministic under cacheDisplay")
        }
    }

    // MARK: (b) Primary render ≠ secondary render bytes

    @Test func primaryRenderDiffersFromSecondaryRender() throws {
        let primary = try render(makeButton(isPrimary: true))
        let secondary = try render(makeButton(isPrimary: false))
        #expect(primary != secondary,
                "the goldCTA-filled primary plate must render different bytes than a secondary plate")
    }

    // MARK: (c) Pressed render ≠ rest render

    @Test func pressedRenderDiffersFromRestRender() throws {
        let rest = try render(makeButton())
        let pressedButton = makeButton()
        (pressedButton.cell as? AlignmentPlateCell)?.isHighlighted = true
        let pressed = try render(pressedButton)
        #expect(rest != pressed, "isHighlighted must invert the bevel, changing the rendered bytes")
    }

    // MARK: (d) Focus-ring mask override present

    @Test func focusRingMaskOverridePresent() throws {
        let button = makeButton()
        let cell = try #require(button.cell as? AlignmentPlateCell)
        let frame = NSRect(x: 0, y: 0, width: 220, height: 64)

        #expect(cell.focusRingMaskBounds(forFrame: frame, in: button) == frame,
                "the mask bounds are the full plate rect, not a smaller inset")

        // `drawFocusRingMask` must not throw/crash when invoked directly — it
        // fills a rounded-rect mask path into the current graphics context,
        // so route it through an offscreen bitmap rather than asserting on
        // pixels (this cell has no golden image to compare against).
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 220, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        cell.drawFocusRingMask(withFrame: frame, in: button)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: (e) accessibilityHelp set per keycap mapping

    @Test func accessibilityHelpMirrorsKeycap() {
        let cases: [(keycap: String, expected: String)] = [
            ("←", "Press Left Arrow"),
            ("→", "Press Right Arrow"),
            ("SPACE", "Press Space"),
            ("⏎", "Press Return"),
        ]
        for testCase in cases {
            let button = makeButton(keycap: testCase.keycap)
            #expect(button.accessibilityHelp() == testCase.expected,
                    "keycap \(testCase.keycap) must mirror to \"\(testCase.expected)\"")
        }
    }

    // MARK: (f) isBordered / bezelStyle pinned (openradar 29465363)

    @Test func isBorderedTrueAndBezelPushOpenradar29465363() {
        // `isBordered = true` is REQUIRED even though `drawBezel` never calls
        // `super` and fully suppresses the stock bezel's paint — a
        // BORDERLESS button silently discards `drawFocusRingMask` (openradar
        // 29465363), which would kill keyboard-focus visibility on every
        // plate. `bezelStyle` must never regress to the deprecated `.rounded`.
        let button = makeButton()
        #expect(button.isBordered)
        #expect(button.bezelStyle == .push)
    }

    // MARK: (g) Inline chip placement — together bar's title must actually fit

    @Test func inlineChipPlacementFitsTitleOnTogetherBar() throws {
        // The together bar is 400×36 with keycap "SPACE". Its title rect must
        // be at least as wide as the title itself: measuring it off
        // `attributedStringValue` — an `NSButtonCell`'s STATE, "0" — hands
        // the title 4 pt and draws it as "T".
        let frame = NSRect(x: 0, y: 0, width: 400, height: 36)
        let inlineButton = AlignmentPlateButton(frame: frame)
        inlineButton.configure(title: "They sound together", keycap: "SPACE", chipPlacement: .inline)
        let inlineCell = try #require(inlineButton.cell as? AlignmentPlateCell)
        let titleRect = inlineCell.titleRect(forBounds: frame)
        #expect(titleRect.height >= 20,
                "inline placement must leave room for the title, not a bottom chip slot")
        #expect(titleRect.width >= inlineCell.attributedTitle.size().width,
                "the drawn title area (\(titleRect.width) pt) must hold the whole title")
        #expect(titleRect.maxX + 10 + 44 <= frame.maxX,
                "title + gap + chip stay inside the bar")

        let trailingButton = AlignmentPlateButton(frame: frame)
        trailingButton.configure(title: "They sound together", keycap: "SPACE", chipPlacement: .trailing)
        let trailingCell = try #require(trailingButton.cell as? AlignmentPlateCell)
        #expect(trailingCell.titleRect(forBounds: frame).width
                    >= trailingCell.attributedTitle.size().width,
                "trailing placement holds the whole title too")

        let inlineBytes = try render(inlineButton)
        let trailingBytes = try render(trailingButton)
        #expect(inlineBytes != trailingBytes,
                "inline and trailing chip placement must render different bytes")
    }

    // MARK: (h) Geometry — the chip sits at the trailing edge, on the midline

    /// `NSButton.isFlipped` is `true`, so `minY` is the plate's VISUAL TOP and
    /// `maxY` its visual bottom. The keycap chip (spec §3) sits 14 pt in from
    /// the trailing edge, centred on the plate's midline, and the title is
    /// centred in the width to its left; a press pushes the chip visually
    /// DOWN. This renders a real 220×64 trailing plate and locates the chip
    /// by its identity tint — the plate's own rim wears it too, so the scan
    /// is inset past the rim.
    @Test func keycapChipSitsAtTheTrailingEdgeOnTheMidlineAndPressesDown() throws {
        let bounds = NSRect(x: 0, y: 0, width: 220, height: 64)
        let button = makeButton(keycap: "←", identityTint: Self.probeTint)
        #expect(button.isFlipped, "the cell's y-math is written for a FLIPPED control")
        #expect(button.alignmentRectInsets.left == 0 && button.alignmentRectInsets.top == 0,
                "the frame IS the alignment rect — the push bezel's insets made a 220 pt plate draw 234 wide")

        let rest = try tintedCentroid(of: button)
        #expect(rest.x > bounds.width * 0.75,
                "the keycap chip sits at the plate's TRAILING edge (centroid x \(rest.x) of 220)")
        #expect(abs(rest.y - bounds.midY) < 4,
                "the chip is centred on the plate's midline (centroid y \(rest.y) of 64)")

        // …and the title keeps the width to its left, never running into it.
        let cell = try #require(button.cell as? AlignmentPlateCell)
        let titleRect = cell.titleRect(forBounds: bounds)
        #expect(titleRect.minX == bounds.minX && titleRect.height == bounds.height,
                "the title area is the full-height band to the chip's left")
        #expect(titleRect.maxX < rest.x - 11,
                "the title area ends before the chip (\(titleRect.maxX) vs chip centre \(rest.x))")

        // A press pushes the chip visually DOWN — +y in flipped coordinates.
        let pressedButton = makeButton(keycap: "←", identityTint: Self.probeTint)
        (pressedButton.cell as? AlignmentPlateCell)?.isHighlighted = true
        let pressed = try tintedCentroid(of: pressedButton)
        #expect(pressed.y > rest.y,
                "pressing must shift the chip DOWN the screen (rest \(rest.y) pt → pressed \(pressed.y) pt)")
    }

    // MARK: (i) The identity tint's own alpha survives the rim

    @Test func rimKeepsTheHandedTintAlpha() throws {
        // The caller hands the rim's alpha inside the tint (0.45 electric on
        // dark); `withAlphaComponent(1)` on the way to the stroke used to
        // reset it to neon. A half-alpha probe must render a rim that is NOT
        // the full-strength probe colour.
        let button = makeButton(keycap: nil, identityTint: Self.probeTint.withAlphaComponent(0.45))
        button.appearance = NSAppearance(named: .darkAqua)
        button.layoutSubtreeIfNeeded()
        let rep = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: rep)
        // The left rim, mid-height — the rim column lies inside the first pt.
        let pixel = try #require(rep.colorAt(x: 0, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(pixel.redComponent < 0.8,
                "the rim is the tint at 0.45 over the fill, not full-strength (red \(pixel.redComponent))")
        #expect(pixel.redComponent > 0.3, "…but the rim is still there")
    }

    /// A hue no token in the plate's paint comes near, so every strongly
    /// magenta pixel inside the plate belongs to the keycap chip's rim or its
    /// glyph — both of which draw the identity tint.
    private static let probeTint = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)

    /// The centroid, in POINTS from the plate's visual top-left, of the
    /// probe-tint pixels inside the plate. The scan is inset 4 pt on every
    /// side so the plate's OWN rim — which wears the same tint, all the way
    /// round the perimeter — can never pull the centroid toward the middle.
    private func tintedCentroid(of button: AlignmentPlateButton) throws -> CGPoint {
        button.appearance = NSAppearance(named: .aqua)
        button.layoutSubtreeIfNeeded()
        let rep = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / button.bounds.height
        let inset = Int((4 * scale).rounded())
        var weightedX: CGFloat = 0
        var weightedY: CGFloat = 0
        var count: CGFloat = 0
        for y in inset..<(rep.pixelsHigh - inset) {
            for x in inset..<(rep.pixelsWide - inset) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      pixel.alphaComponent > 0.5,
                      pixel.redComponent > 0.5, pixel.blueComponent > 0.5,
                      pixel.greenComponent < 0.35 else { continue }
                weightedX += CGFloat(x)
                weightedY += CGFloat(y)
                count += 1
            }
        }
        #expect(count > 0, "the tinted keycap chip never rendered")
        guard count > 0 else { return CGPoint(x: CGFloat.nan, y: CGFloat.nan) }
        // `colorAt`'s y runs from the TOP of the image down, which is already
        // the plate's own flipped axis.
        return CGPoint(x: (weightedX / count) / scale, y: (weightedY / count) / scale)
    }
}
