// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudioutSharedUI

/// No row glyph comes near touching its ring. One point size for every
/// symbol let `radio.fill` (the Bluetooth fallback) and `hifispeaker.2.fill`
/// touch the ring; `DeviceIcon.rowGlyphFits` sizes each symbol so none does.
/// Renders the real `DeviceIcon.rowGlyph` image and measures its farthest ink
/// pixel from the ring's centre. The floor is 1 pt, not the 2 pt design
/// target: SF Symbols art differs between macOS versions (the same glyph
/// measured 2.14 pt on one Mac and 1.99 pt on another), so a 2 pt floor would
/// pass or fail by machine.
@MainActor
@Suite struct RowGlyphClearanceTests {

    private static let scale: CGFloat = 4

    /// Farthest point of ink (alpha > 25 %) from the image centre, in pt.
    private func farthestInk(_ image: NSImage) -> CGFloat? {
        let side = Int(PopoverColumnGrid.iconWidth * Self.scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let c = CGFloat(side) / 2
        var far: CGFloat = 0
        for y in 0..<side {
            for x in 0..<side where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 {
                // Pixel corner farthest from the centre, so the measure never flatters.
                let dx = abs(CGFloat(x) + 0.5 - c) + 0.5
                let dy = abs(CGFloat(y) + 0.5 - c) + 0.5
                far = max(far, (dx * dx + dy * dy).squareRoot())
            }
        }
        return far / Self.scale
    }

    @Test func noRowGlyphTouchesItsRing() throws {
        let names = Set(DeviceIcon.rowGlyphFits.keys).union(DeviceIcon.curated.filter(DeviceIcon.isValid))
        for name in names.sorted() where DeviceIcon.isValid(name) {
            let isMainAudio = name == "hifispeaker.arrow.forward.fill"
            let diameter = isMainAudio ? PopoverColumnGrid.mainAudioRingDiameter : PopoverColumnGrid.haloRingDiameter
            let innerEdge = diameter / 2 - PopoverColumnGrid.ringStrokeWidth / 2
            let image = try #require(DeviceIcon.rowGlyph(name))
            let ink = try #require(farthestInk(image))
            let clearance = innerEdge - ink
            print("row glyph clearance: \(name) \(String(format: "%.2f", clearance)) pt")
            #expect(clearance >= 1.0, "\(name) is \(clearance) pt from its ring's inner edge")
        }
    }
}
