// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudioutSharedUI

/// The guard on the package's FIRST asset catalogue.
///
/// A custom symbol that does not resolve is not a build error and not a crash
/// — `Bundle.module.image(forResource:)` returns `nil`, the button's image is
/// set to `nil`, and the control ships as a blank 24 pt hole. Three separate
/// mistakes produce exactly that and nothing else: dropping the `resources:`
/// entry from `Package.swift`, changing it from `.process` to `.copy` (which
/// skips `actool` and copies the `.xcassets` folder in verbatim), or renaming
/// a `.symbolset` directory without renaming the constant. This suite fails
/// loudly on all three.
@MainActor
@Suite struct RowAccessorySymbolTests {

    @Test func everySymbolResolvesFromTheCatalogue() {
        for name in RowAccessorySymbol.allNames {
            #expect(RowAccessorySymbol.rawImage(named: name) != nil,
                    "\(name) did not resolve — the catalogue is missing, unprocessed, or renamed")
        }
    }

    /// Four names, four distinct images. A `.symbolset` pointing at the wrong
    /// SVG resolves fine and draws the wrong control.
    @Test func theFourSymbolsAreFourDifferentImages() {
        let rasters = RowAccessorySymbol.allNames.compactMap {
            RowAccessorySymbol.image(named: $0, palette: [.black, .white])?.tiffRepresentation
        }
        #expect(rasters.count == RowAccessorySymbol.allNames.count,
                "at least one symbol failed to render under palette rendering")
        for (i, a) in rasters.enumerated() {
            for b in rasters[(i + 1)...] {
                #expect(a != b, "two of the four symbols rasterise identically")
            }
        }
    }

    /// Palette layer 0 is the enclosing square in all four templates, and
    /// every layer above it is the mark inside. A two-colour palette therefore
    /// has to paint MORE square than mark — the assertion that catches a
    /// reversed palette, which draws a white square with coloured marks and
    /// passes every configuration read-back.
    @Test func paletteLayerZeroIsTheEnclosingSquare() throws {
        for name in [RowAccessorySymbol.muteEngaged, RowAccessorySymbol.equalizerEngaged] {
            let image = try #require(
                RowAccessorySymbol.image(named: name, palette: [.red, .green]))
            let counts = opaqueCounts(image)
            let red = counts[hex(.red)] ?? 0
            let green = counts[hex(.green)] ?? 0
            #expect(red > 0 && green > 0, "\(name): a two-colour palette painted one colour")
            #expect(red > green, Comment(rawValue:
                "\(name): palette[0] must be the enclosing square, not the mark " +
                "(square \(red) px, mark \(green) px)"))
        }
    }

    /// A one-colour palette covers every layer, which is what the at-rest
    /// outline squares want. The slider pair carries SEVEN layers, so this is
    /// also the check that the last colour really does repeat.
    @Test func aSingleColourPaletteCoversEveryLayer() throws {
        for name in RowAccessorySymbol.allNames {
            let image = try #require(RowAccessorySymbol.image(named: name, palette: [.red]))
            let counts = opaqueCounts(image)
            #expect(counts.keys.contains(hex(.red)), "\(name): the single palette colour never landed")
            let strays = counts.filter { $0.key != hex(.red) && $0.value > 1 }
            #expect(strays.isEmpty, Comment(rawValue:
                "\(name): a one-colour palette left \(strays.count) other ink(s) — " +
                "the last colour is not repeating over the remaining layers"))
        }
    }

    /// The symbol is the control's whole mark now, so it has to land near the
    /// 22 pt seat it replaced without outgrowing the 24 pt column the row's
    /// layout reserves (``PopoverColumnGrid/eqButtonWidth``) — an overspilling
    /// glyph would eat the 6 pt gap to its neighbour.
    @Test func theDrawnSquareFitsItsColumnAtTheSharedPointSize() throws {
        let image = try #require(
            RowAccessorySymbol.image(named: RowAccessorySymbol.muteEngaged,
                                     palette: [.black, .white]))
        let size = image.size
        #expect(size.width <= PopoverColumnGrid.eqButtonWidth
                    && size.height <= PopoverColumnGrid.eqButtonWidth,
                "the symbol draws \(size), wider than its \(PopoverColumnGrid.eqButtonWidth) pt column")
        #expect(size.height >= 16,
                "the symbol draws \(size) — smaller than the 22 pt seat it replaces")
    }

    /// Both controls draw at ONE point size, so mute and the Equalizer door
    /// cannot drift apart.
    @Test func bothControlsDrawAtTheSameSize() throws {
        let mute = try #require(
            RowAccessorySymbol.image(named: RowAccessorySymbol.muteEngaged, palette: [.black]))
        let equalizer = try #require(
            RowAccessorySymbol.image(named: RowAccessorySymbol.equalizerEngaged, palette: [.black]))
        #expect(abs(mute.size.height - equalizer.size.height) <= 1,
                "mute draws \(mute.size), the door \(equalizer.size)")
    }

    // MARK: Helpers

    private func hex(_ color: NSColor) -> Int {
        guard let c = color.usingColorSpace(.sRGB) else { return -1 }
        return (Int(c.redComponent * 255 + 0.5) << 16)
            | (Int(c.greenComponent * 255 + 0.5) << 8)
            | Int(c.blueComponent * 255 + 0.5)
    }

    /// Every fully opaque pixel in `image`, counted by 8-bit sRGB value.
    private func opaqueCounts(_ image: NSImage) -> [Int: Int] {
        guard let data = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: data) else { return [:] }
        var counts: [Int: Int] = [:]
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      c.alphaComponent > 0.99 else { continue }
                counts[hex(c), default: 0] += 1
            }
        }
        return counts
    }
}
