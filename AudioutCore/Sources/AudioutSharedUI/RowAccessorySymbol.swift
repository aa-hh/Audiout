// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The four custom SF Symbols a device row's two accessory controls draw —
/// mute and the Equalizer door, each in an at-rest and an engaged state.
///
/// They are the app's FIRST custom symbols. Each symbolset in
/// `Resources/Symbols.xcassets` holds one SF Symbols template SVG exported
/// from the SF Symbols app, and `NSImage(named:)` finds them once the
/// catalogue is compiled — never `NSImage(systemSymbolName:)`, which only
/// ever finds Apple's own.
///
/// WHERE THE CATALOGUE COMES FROM. SwiftPM does not compile asset catalogues:
/// a resource rule copies the `.xcassets` DIRECTORY in and every symbol then
/// resolves to nil at runtime with no build error. So the catalogue is
/// EXCLUDED from the target and `scripts/make-app.sh` runs `actool` over it at
/// assembly, landing `Assets.car` in `Contents/Resources` beside the wordmark
/// font — the same route, and the same reason, as that font. The script FAILS
/// the build if any of ``allNames`` is missing from its output, which is a
/// harder guarantee than a unit test: `swift test` builds no `.app`, so these
/// return nil under the suite by design.
///
/// WHY CUSTOM SYMBOLS AND NOT A DRAWN SEAT. Both controls used to say
/// "engaged" with a rounded rectangle painted on a sibling `NSView` behind an
/// ordinary system glyph — `PopoverColumnGrid.engagedSeatSize` at
/// `engagedSeatCornerRadius`, retired 2026-09-04. Two views, two layers, two
/// appearance re-stamps and a size that had to be pinned by hand because an
/// `.accessoryBar` `NSButton` frames larger than its alignment rect. The
/// enclosing square is part of the symbol now, so the mark is ONE image: the
/// `.fill` variant when engaged, the outline variant at rest.
///
/// KNOWN DEFECT — the four templates carry NO USABLE LAYERS. Every rendition
/// in the built `Assets.car` reports `"ColorModel": "Monochrome"`, and a
/// two-colour palette paints the whole mark in the SECOND colour (a
/// three-colour palette paints it all in the third). The same palette code
/// splits an Apple two-layer symbol correctly, so the configuration is right
/// and the assets are the limitation: `speaker.slash.square.fill.svg`'s
/// `LayerTree` has an empty layer 0 with the whole glyph in layer 1, and the
/// slider pair carries no `LayerTree` at all.
///
/// The intended engaged treatment — the enclosing square in the state's hue
/// with the marks inside it in white — therefore does not render. It needs
/// the four symbols re-exported from the SF Symbols app with the enclosure on
/// its own layer. `RowAccessorySymbolTests.paletteLayerZeroIsTheEnclosingSquare`
/// is the check that goes green when that lands.
public enum RowAccessorySymbol {
    /// Mute at rest — the outline square.
    public static let muteRest = "custom.speaker.slash.square"
    /// Mute engaged — the filled square.
    public static let muteEngaged = "custom.speaker.slash.square.fill"
    /// The Equalizer door on a flat curve — the outline square.
    public static let equalizerRest = "custom.slider.horizontal.2.square"
    /// The Equalizer door on a shaped curve — the filled square.
    public static let equalizerEngaged = "custom.slider.horizontal.2.square.fill"

    /// Every name above, for the load test that guards the catalogue.
    public static let allNames = [muteRest, muteEngaged, equalizerRest, equalizerEngaged]

    /// The point size both controls draw at. One value, so mute and the
    /// Equalizer door cannot drift apart — the row's layout reserves each a
    /// 24 pt column (``PopoverColumnGrid/muteWidth`` /
    /// ``PopoverColumnGrid/eqButtonWidth``) with
    /// ``PopoverColumnGrid/eqToMuteGap`` between them, and a glyph that
    /// outgrew its column would eat that gap.
    ///
    /// 18, not the 13 pt the row's other accessory glyphs use: the enclosing
    /// square is now the control's whole mark, so it has to land near the
    /// 22 pt seat it replaces rather than at glyph scale.
    /// `RowAccessorySymbolTests` measures the drawn ink and holds it inside
    /// the 24 pt column.
    public static let pointSize: CGFloat = 18

    /// The raw symbol image, or `nil` when the catalogue did not make it into
    /// the bundle. Callers use ``image(named:palette:)``; this is separate so
    /// the load test can prove the resource resolves without also asserting a
    /// rendering configuration.
    public static func rawImage(named name: String) -> NSImage? {
        // `Bundle.main`, via `NSImage(named:)`: `Bundle.module` does NOT
        // resolve inside an assembled `.app` — SwiftPM's generated accessor
        // looks beside the executable and then at an absolute build path baked
        // in at compile time. `BrandMark` hand-resolves its bundle for the
        // same reason (see `make-app.sh`, the resource-bundle step).
        NSImage(named: name)
    }

    /// The symbol drawn under palette rendering: `palette[0]` on the enclosing
    /// square, `palette[1]` on the marks inside it.
    ///
    /// Pass ONE colour for the at-rest states — a single ink over every layer,
    /// which is what an outline square with no fill wants.
    public static func image(named name: String, palette: [NSColor]) -> NSImage? {
        let configured = rawImage(named: name)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: palette)))
        // A symbol image loaded from a catalogue arrives as a TEMPLATE, and a
        // template is re-tinted by whatever draws it — which throws the palette
        // away and paints the whole mark in one ink. The palette is the state
        // here, so the image has to stop being a template.
        configured?.isTemplate = false
        return configured
    }
}
