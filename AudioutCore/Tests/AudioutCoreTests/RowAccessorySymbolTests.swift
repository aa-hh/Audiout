// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudioutSharedUI

/// The guard on the package's FIRST asset catalogue.
///
/// A custom symbol that does not resolve is not a build error and not a crash
/// — the lookup returns `nil` and the control ships as a blank 24 pt hole.
/// The SHIPPING half of that guarantee lives in `make-app.sh`, which compiles
/// the catalogue and FAILS the build when a symbol is missing from the final
/// `Assets.car` (that check has already refused two broken builds). This
/// suite guards the SOURCE half through ``CompiledSymbolFixture``: a renamed
/// `.symbolset`, a malformed template SVG, or a constant that no longer names
/// a real symbolset fails here, in the suite, not at assembly time.
@MainActor
@Suite struct RowAccessorySymbolTests {

    init() {
        if CompiledSymbolFixture.install() == nil {
            Issue.record("the symbol fixture failed to compile — actool or the source catalogue is broken")
        }
    }

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
            RowAccessorySymbol.image(named: $0, ink: .black)?.tiffRepresentation
        }
        #expect(rasters.count == RowAccessorySymbol.allNames.count,
                "at least one symbol failed to render")
        for (i, a) in rasters.enumerated() {
            for b in rasters[(i + 1)...] {
                #expect(a != b, "two of the four symbols rasterise identically")
            }
        }
    }

    /// The engaged treatment is ONE ink with the marks punched through as
    /// transparency (owner, 2026-09-05). Two defects it catches, both of which
    /// shipped: a symbol re-export that loses the erase action, and a drawing
    /// configuration that PAINTS the marks instead of cutting them — a palette
    /// or hierarchical configuration does exactly that, and the result is a
    /// solid square with no glyph in it, no nil and no crash.
    @Test func engagedFillPunchesTheMarksThrough() throws {
        for name in [RowAccessorySymbol.muteEngaged, RowAccessorySymbol.equalizerEngaged] {
            let image = try #require(RowAccessorySymbol.image(named: name, ink: .red))
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            var opaque = 0, holes = 0
            // The middle band of the square, where every mark lives. The
            // square's own corners are outside it, so a hole counted here is
            // a mark and not the rounding at the enclosure's edge.
            for y in (rep.pixelsHigh / 3)...(2 * rep.pixelsHigh / 3) {
                for x in (rep.pixelsWide / 4)...(3 * rep.pixelsWide / 4) {
                    let a = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    if a > 0.9 { opaque += 1 } else if a < 0.1 { holes += 1 }
                }
            }
            #expect(opaque > 0, "\(name): the fill never painted")
            #expect(holes > 0, Comment(rawValue:
                "\(name): no transparent marks inside the square — the punch-through is gone " +
                "(\(opaque) opaque px, \(holes) holes in the mark band)"))
        }
    }

    /// The symbol is the control's whole mark now, so the drawn square has to
    /// sit inside the 24 pt column the row's layout reserves
    /// (``PopoverColumnGrid/eqButtonWidth``) with room to spare — a mark meant
    /// to read as quiet chrome rather than a centerpiece (owner, 2026-09-05)
    /// should sit well clear of that column, not fill it.
    ///
    /// Measured on the INK, not on `image.size`: a symbol's image box carries
    /// empty side bearings, so the box is wider than the square inside it, and
    /// asserting on the box misses how big the mark actually reads (that gap
    /// is what let an earlier tune ship 3 pt smaller than intended). The
    /// buttons clip that bearing rather than scale it.
    @Test func theDrawnSquareFillsItsColumnWithoutOutgrowingIt() throws {
        let image = try #require(
            RowAccessorySymbol.image(named: RowAccessorySymbol.muteEngaged, ink: .black))
        let ink = try #require(inkBounds(image))
        let column = PopoverColumnGrid.eqButtonWidth
        #expect(ink.width <= column && ink.height <= column,
                "the square draws \(ink.size), past its \(column) pt column")
        #expect(ink.width >= 15 && ink.height >= 15,
                "the square draws \(ink.size) — too small to read as the control's mark")
    }

    /// The bounding box of everything `image` actually paints.
    private func inkBounds(_ image: NSImage) -> NSRect? {
        guard let rep = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        else { return nil }
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        var minX = rep.pixelsWide, maxX = -1, minY = rep.pixelsHigh, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return NSRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale,
                      height: CGFloat(maxY - minY + 1) / scale)
    }

    /// Both controls draw at ONE point size, so mute and the Equalizer door
    /// cannot drift apart.
    @Test func bothControlsDrawAtTheSameSize() throws {
        let mute = try #require(
            RowAccessorySymbol.image(named: RowAccessorySymbol.muteEngaged, ink: .black))
        let equalizer = try #require(
            RowAccessorySymbol.image(named: RowAccessorySymbol.equalizerEngaged, ink: .black))
        #expect(abs(mute.size.height - equalizer.size.height) <= 1,
                "mute draws \(mute.size), the door \(equalizer.size)")
    }

}
