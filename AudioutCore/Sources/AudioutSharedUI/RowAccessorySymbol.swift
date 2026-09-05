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
/// HOW THE ENGAGED STATES PUNCH THROUGH, and why this draws MONOCHROME.
/// In each `.fill` template the marks are not paint — they are erase actions
/// (`-sfsymbols-clear-behind`), so the speaker, the slash and the two sliders
/// cut holes in the enclosing square and the row's own background shows
/// through them. That is the approved look, and it survives only under
/// monochrome rendering.
///
/// A palette configuration destroys it, which is what shipped on 2026-09-04
/// and what the owner saw: palette rendering treats every layer as paintable,
/// so the erase never happens and the marks are PAINTED — in the same ink as
/// the square when the palette holds one colour, which is a blank square.
/// Passing a second colour does not help; it paints the marks in that colour
/// instead of cutting them. So: one ink, monochrome, and the tint is applied
/// through the alpha channel below rather than by a configuration.
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
    /// 20 pt at `.thin` weight (owner, 2026-09-05: too big and too heavy —
    /// "I don't want these to be the centerpiece"). Measured against the same
    /// two references the row already draws: the stroke lands at 0.875 pt,
    /// under the 1 pt `FeedPillView` border, and the drawn square is 17.25 pt
    /// on a side, smaller than the 22 pt seat these symbols replaced. Both are
    /// intentional this time — the mark should read as quiet chrome, not a
    /// focal point.
    ///
    /// `.thin`, not `.regular`: at `.regular` the same square's stroke
    /// measures 1.75 pt, well past any hairline border in the row, which is
    /// what read as "heavy" against the row's own type. `RowAccessorySymbol`
    /// carries no font, so weight is stated directly rather than borrowed —
    /// `.thin` is the SF Symbols weight nearest `NSFont.systemFont`'s own
    /// hairline strokes at small sizes.
    ///
    /// `RowAccessorySymbolTests` measures the drawn INK, not `image.size` —
    /// the image box carries empty side bearings wider than the square itself,
    /// which is why both buttons draw it unscaled (`imageScaling = .scaleNone`)
    /// and clip the bearing rather than let `NSButton` scale the box down.
    public static let pointSize: CGFloat = 20
    /// See ``pointSize``.
    public static let weight: NSFont.Weight = .thin

    /// The raw symbol image, or `nil` when the catalogue did not make it into
    /// the bundle. Callers use ``image(named:ink:)``; this is separate so
    /// the load test can prove the resource resolves without also asserting a
    /// rendering configuration.
    /// Test seam: the suite runs with no `.app`, so `NSImage(named:)` has no
    /// catalogue to find — `swift test` cannot exercise these symbols at all
    /// without it. A pixel test compiles the repo's own `Symbols.xcassets`
    /// into a temporary bundle once (see `CompiledSymbolFixture` in the test
    /// target) and points this here. Never set outside tests.
    nonisolated(unsafe) public static var test_catalogueBundle: Bundle?

    public static func rawImage(named name: String) -> NSImage? {
        if let bundle = test_catalogueBundle {
            return bundle.image(forResource: name)
        }
        // `Bundle.main`, via `NSImage(named:)`: `Bundle.module` does NOT
        // resolve inside an assembled `.app` — SwiftPM's generated accessor
        // looks beside the executable and then at an absolute build path baked
        // in at compile time. `BrandMark` hand-resolves its bundle for the
        // same reason (see `make-app.sh`, the resource-bundle step).
        return NSImage(named: name)
    }

    /// The symbol in one ink, with the `.fill` variants' erased marks left as
    /// transparent holes.
    ///
    /// The tint is painted through the rendered symbol's alpha channel — fill
    /// the bounds with `ink`, then keep only the pixels the symbol covers. A
    /// symbol configuration cannot do this: every colour-carrying
    /// configuration is a palette or hierarchical one, and both paint the
    /// erased marks instead of cutting them (see the type's doc comment).
    public static func image(named name: String, ink: NSColor) -> NSImage? {
        guard let symbol = rawImage(named: name)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
        else { return nil }
        symbol.isTemplate = true

        let tinted = NSImage(size: symbol.size)
        let bounds = NSRect(origin: .zero, size: symbol.size)
        tinted.lockFocus()
        ink.setFill()
        bounds.fill()
        symbol.draw(in: bounds, from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()
        // The ink IS the state here, so the result must not be re-tinted by
        // whatever draws it — an `NSButton` would otherwise repaint a template
        // in the control colour and throw the state away.
        tinted.isTemplate = false
        return tinted
    }
}
