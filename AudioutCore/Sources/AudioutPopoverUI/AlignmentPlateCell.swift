// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The **alignment-wizard plate skin** (wizard-stage v2 spec §3): a
/// DRAWING-ONLY `NSButtonCell` subclass installed on `AlignmentPlateButton` —
/// the target/reference/together/back/stop/proposal/kept/bow-out buttons on
/// the BT alignment wizard's screens. Only `drawBezel`, `titleRect`,
/// `drawTitle`, `drawFocusRingMask`, and `focusRingMaskBounds` are
/// overridden — tracking, keyboard operation, `NSButtonType`, VoiceOver, and
/// target/action all come from the un-subclassed `NSButtonCell`/`NSButton`
/// machinery, untouched (the same "only the DRAWING changes" contract as
/// `WarmFaderCell` over the row sliders and `WarmNameFieldCell` over the
/// rename field, `AudioutSharedUI/AGENTS.md`).
///
/// `drawBezel` never calls `super` — the stock bezel is fully replaced by
/// this cell's own paint. That is exactly why the button installing this
/// cell must keep `isBordered = true`: see `AlignmentPlateButton`'s own doc
/// comment for the openradar reason (29465363 — borderless silently
/// discards `drawFocusRingMask`).
///
/// State paint table (wizard-stage v2 spec §3; lip strengths from the
/// approved mock, which the spec's 0.35 / 0.18 overshot):
/// - **rest** (secondary plate): `raised` fill, a lit top lip (`raised`
///   blended 0.12 toward white), a bottom shade (`shadow` @ 0.30), and a rim
///   in `identityTint` (or `rim` when the caller hands none). Both
///   lips sit one hairline INSIDE the rim.
/// - **hover**: adds `engagedChrome` @ `PopoverColumnGrid.rowHoverWashAlpha`
///   over the rest fill (both primary and secondary).
/// - **pressed** (`isHighlighted`, secondary): inverts the bevel — top
///   `shadow` @ 0.22, bottom lip lit (`raised` blended 0.20 toward white).
/// - **disabled**: the interior (fill/lip/rim/chip) dims to
///   `PopoverColumnGrid.faderDisabledAlpha` — `WarmFaderCell`'s idiom.
/// - **primary**: BRIGHT gold fill + the pinned `inkOnFill` (black) title and
///   chip, wearing the SAME two-edge bevel as a secondary plate in gold's own
///   inks — rest lights the top lip (the fill blended 0.22 toward white) over a
///   `shadow` @ 0.22 bottom, pressed blends the fill 0.18 toward `shadow` and
///   inverts the two lips. Its rim is the fill blended 0.35 toward `shadow`
///   rather than the neutral `rim`. DISABLED primary falls back to the
///   SECONDARY plate's skin entirely — `raised` fill, secondary bevel,
///   neutral rim, dimmed `label` ink (never a faded gold) — so a dead CTA
///   reads as an ordinary dead plate, not a bleached one.
///
/// The keycap chip (spec §3): 22×22 at the control radius for a single glyph
/// ("←"/"→"/"⏎"), 44×20 for "SPACE", set in `Tokens.Font.keycap`, no fill —
/// a rim and a glyph over the plate's own face. `trailing` placement seats it at the
/// plate's trailing edge (14 pt in), vertically centred, and the title is
/// centred in the WHOLE PLATE regardless — the chip overlays the trailing
/// edge without displacing it (owner ruling 2026-08-24; see `titleRect`);
/// `inline` places title + chip as one centred group. Its ink is the
/// `identityTint` at full alpha (the plate rim wears
/// the tint at the alpha the CALLER handed — FULL strength on dark, 0.9 on
/// light; owner ruling 2026-08-23, over spec §2.1's
/// 0.45), `label2` on a neutral plate, and the pinned `inkOnFill`
/// on a primary — the chip shares the title's ink. A 2 pt inner
/// bottom lip (`shadow` @ 0.25) drops to 1 pt and the whole chip shifts
/// down 1 pt while the plate is pressed — a small compression echo of the
/// plate's own press feedback.
///
/// **Every y-coordinate below is written in the control's FLIPPED
/// coordinates**: `NSButton.isFlipped` is `true`, so the plate's VISUAL top
/// edge is `frame.minY` and its visual bottom edge is `frame.maxY` — the
/// opposite of an un-flipped view. Getting that backwards drew the whole skin
/// upside down (lit lip under the plate, keycap chip above the title).
///
/// Identity-tint doctrine (spec §2.1/§2.2): this cell draws whatever
/// `identityTint` it is HANDED — it never resolves light/dark itself, and it
/// never picks per-appearance. The caller (the question screen) passes
/// `wireCore`/`syncSignalDeep` (target) or `ring` (reference, which carries
/// its own light hex); a `nil` tint (the together bar, Back/Stop, proposal/
/// kept/bow-out plates) falls back to the neutral `rim`.
///
/// No drop shadows, no gradients, no textures — every fill/stroke is a flat
/// token color or a blend of two token colors, resolved at DRAW time, so
/// `cacheDisplay` snapshots stay byte-deterministic (the same contract
/// `WarmFaderCell`'s header claims).
public final class AlignmentPlateCell: NSButtonCell {

    // MARK: Chip placement

    /// Where the keycap chip sits relative to the title (spec §3):
    /// `trailing` seats the chip at the trailing edge, vertically centred,
    /// and centres the title in the remaining width (the 220×64 plates'
    /// ←/→/⏎ chips); `inline` renders title + a 10 pt gap + the chip as
    /// ONE horizontally-centered group — the together bar's SPACE chip.
    public enum ChipPlacement {
        case trailing
        case inline
    }

    /// Defaults to `trailing` — every plate except the together bar.
    public var chipPlacement: ChipPlacement = .trailing {
        didSet { if chipPlacement != oldValue { controlView?.needsDisplay = true } }
    }

    // MARK: Inputs

    /// True for the ONE gold-filled plate per screen (Start, Sounds
    /// right, Done, Set it by hand, …) — every other plate on the same
    /// screen stays secondary.
    public var isPrimary: Bool = false {
        didSet { if isPrimary != oldValue { controlView?.needsDisplay = true } }
    }

    /// Pointer-over state. `AlignmentPlateButton`'s own `NSTrackingArea` sets
    /// this and requests a redisplay; the cell itself owns no tracking.
    public var isHovered: Bool = false {
        didSet { if isHovered != oldValue { controlView?.needsDisplay = true } }
    }

    /// The glyph(s) drawn in the bottom keycap chip — "←", "→", "SPACE",
    /// "⏎" — or `nil` for a plate with no key equivalent. The exact same
    /// string also drives `AlignmentPlateButton.accessibilityHelp`, since
    /// the drawn chip must never become an AX element of its own.
    public var keycap: String? {
        didSet { if keycap != oldValue { controlView?.needsDisplay = true } }
    }

    /// The per-side identity hue for the plate's rim AND the keycap chip's
    /// rim/glyph — already resolved by the CALLER for the current appearance
    /// (spec §2.1: the stage draws the tint it is handed, it never picks
    /// one). `nil` draws the neutral `Tokens.Color.rim`.
    public var identityTint: NSColor? {
        didSet { controlView?.needsDisplay = true }
    }

    // MARK: Drawing — drawBezel (NO super call; the stock bezel is fully replaced)

    public override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        let radius = PopoverColumnGrid.alignPlateCornerRadius
        let path = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        let pressed = isHighlighted
        let alpha = interiorAlpha

        // Fill.
        fillColor(pressed: pressed).withAlphaComponent(alpha).setFill()
        path.fill()

        // Hover wash — the one neutral engaged-chrome tone (never a second
        // hue), same as every other hover surface in the app.
        if isHovered && isEnabled {
            NSGraphicsContext.current?.saveGraphicsState()
            path.addClip()
            Tokens.Color.engagedChrome
                .withAlphaComponent(PopoverColumnGrid.rowHoverWashAlpha).setFill()
            path.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // Bevel: BOTH plate kinds wear the same two-edge bevel (rest
        // lit-top/shaded-bottom, pressed inverted) — only the inks differ, so
        // a primary plate is the same physical object in a different
        // material, never a flat sticker beside a bevelled one.
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        drawBevel(in: frame, pressed: pressed, alpha: alpha)
        NSGraphicsContext.current?.restoreGraphicsState()

        // Rim — gold's own darkened edge on a primary plate, so the CTA does
        // not wear a neutral rim over a gold face.
        let rim = usesGoldSkin ? Self.primaryRimColor : (identityTint ?? Tokens.Color.rim)
        // Multiplied, not replaced: the identity tint ARRIVES with its rim
        // alpha (full-strength electric on dark, 0.9 Deep on light), and
        // `withAlphaComponent` alone would reset it to full strength — which
        // would silently un-dim a DISABLED plate's rim.
        Self.dimmed(rim, by: alpha).setStroke()
        let rimPath = NSBezierPath(
            roundedRect: frame.insetBy(dx: Self.hairline / 2, dy: Self.hairline / 2),
            xRadius: radius, yRadius: radius)
        rimPath.lineWidth = Self.hairline
        rimPath.stroke()

        drawKeycapChip(in: frame, pressed: pressed, alpha: alpha)
    }

    /// Rest = lit top lip + shaded bottom; pressed inverts which edge is lit
    /// and which is shaded (spec §3's bevel-invert language). Called from
    /// `drawBezel` already clipped to the path. The primary plate takes the
    /// SAME two edges, lit out of the pinned gold instead of `raised`.
    ///
    /// Flipped control: the VISUAL top edge is `minY`, the visual bottom
    /// `maxY` (see the type doc).
    private func drawBevel(in frame: NSRect, pressed: Bool, alpha: CGFloat) {
        // One hairline INSIDE the rim: on the rim's own row the rim stroke
        // painted over both lips and the bevel measured absent.
        let visualTopRect = NSRect(x: frame.minX, y: frame.minY + Self.hairline,
                                   width: frame.width, height: Self.hairline)
        let visualBottomRect = NSRect(x: frame.minX, y: frame.maxY - 2 * Self.hairline,
                                      width: frame.width, height: Self.hairline)
        let lit = litLipColor(pressed: pressed).withAlphaComponent(alpha)
        let shade = Tokens.Color.shadow.withAlphaComponent(shadeLipAlpha(pressed: pressed) * alpha)
        // Rest: light from above. Pressed: the plate has gone in, so the lit
        // edge is the one now facing up out of the recess.
        (pressed ? shade : lit).setFill()
        visualTopRect.fill()
        (pressed ? lit : shade).setFill()
        visualBottomRect.fill()
    }

    /// The bevel's lit edge. A primary plate lightens the pinned gold (one blend,
    /// rest and pressed alike); a secondary plate lightens `raised`, and its
    /// pressed lip is the shallower of the two blends.
    private func litLipColor(pressed: Bool) -> NSColor {
        if usesGoldSkin {
            let gold = Self.primaryFillColor
            return gold.blended(withFraction: Self.primaryLitBlend, of: .white) ?? gold
        }
        let blend = pressed ? Self.pressedBottomLitBlend : Self.restTopLitBlend
        return Tokens.Color.raised
            .blended(withFraction: blend, of: .white) ?? Tokens.Color.raised
    }

    /// The bevel's shaded edge alpha — one value for the primary plate, the
    /// secondary plate's own rest/pressed pair otherwise.
    private func shadeLipAlpha(pressed: Bool) -> CGFloat {
        if usesGoldSkin { return Self.primaryShadeAlpha }
        return pressed ? Self.pressedTopShadowAlpha : Self.restBottomShadeAlpha
    }

    /// Whether this plate is wearing the gold CTA material. A DISABLED
    /// primary falls back to the secondary plate's skin entirely — fill,
    /// bevel and rim — so a dead CTA reads as an ordinary dead plate rather
    /// than a bleached gold one.
    private var usesGoldSkin: Bool { isPrimary && isEnabled }

    /// The primary plate's rim: the gold fill taken toward `shadow`, so the
    /// edge is gold's own dark end rather than a neutral outline over a gold
    /// face. Measured against the light ground it has to survive: the blend of
    /// Full-gold dark `#E8B84B` lands on `#977831`, 3.9:1 vs the light canvas —
    /// clear of the 3:1 non-text floor, which is what stops a bright plate
    /// dissolving into paper.
    private static var primaryRimColor: NSColor {
        let gold = primaryFillColor
        return gold.blended(withFraction: primaryRimShadowBlend, of: Tokens.Color.shadow) ?? gold
    }

    /// **The primary plate's gold, pinned to ``Tokens/Color/gold``'s
    /// DARK-appearance value in BOTH appearances** (owner ruling 2026-08-24).
    /// Two deliberate departures from what this plate used to draw:
    ///
    /// - The fill is ``Tokens/Color/gold``'s dark hex, never the retired
    ///   deepened CTA gold — a dark mustard, which is what the live build
    ///   read as.
    /// - Not the dynamic value. Resolving live would hand the LIGHT appearance
    ///   `gold`'s own light hex (`#9E761D`, deepened for paper), i.e. two
    ///   different CTAs; the ruling is one gold everywhere, so it is resolved
    ///   once under `.darkAqua` — the same force-resolve idiom
    ///   `AlignmentTokenContrastTests` uses to measure a token under a fixed
    ///   appearance. `gold` is still read from Tokens rather than copied, so
    ///   the accent dial and Increase Contrast both still reach it.
    static var primaryFillColor: NSColor {
        var resolved = Tokens.Color.gold
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            resolved = Tokens.Color.gold.usingColorSpace(.sRGB) ?? resolved
        }
        return resolved
    }

    /// The primary plate's ink, pinned with its fill: ``Tokens/Color/inkOnFill``
    /// goes white under light Increase Contrast, and white on the pinned
    /// `#E8B84B` measures 1.84:1 — the ink has to be resolved under the same
    /// appearance the fill is (10.18:1).
    static var primaryInkColor: NSColor {
        var resolved = Tokens.Color.inkOnFill
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            resolved = Tokens.Color.inkOnFill.usingColorSpace(.sRGB) ?? resolved
        }
        return resolved
    }

    /// The pinned gold (flat, or blended toward `shadow` while pressed) for an
    /// enabled primary plate; `raised` for every secondary plate AND for a
    /// disabled primary — gold never fades, it is simply not the fill
    /// disabled draws with.
    private func fillColor(pressed: Bool) -> NSColor {
        guard usesGoldSkin else { return Tokens.Color.raised }
        let gold = Self.primaryFillColor
        guard pressed else { return gold }
        return gold.blended(withFraction: Self.pressedPrimaryShadowBlend,
                            of: Tokens.Color.shadow) ?? gold
    }

    /// Disabled dims the whole interior (fill/bevel/rim/chip) to
    /// `PopoverColumnGrid.faderDisabledAlpha` — `WarmFaderCell`'s idiom, so a
    /// disabled plate reads exactly like a disabled fader.
    private var interiorAlpha: CGFloat {
        isEnabled ? 1.0 : PopoverColumnGrid.faderDisabledAlpha
    }

    /// `color` at its OWN alpha × `factor`.
    private static func dimmed(_ color: NSColor, by factor: CGFloat) -> NSColor {
        guard factor < 1 else { return color }
        let own = color.usingColorSpace(.sRGB)?.alphaComponent ?? 1
        return color.withAlphaComponent(own * factor)
    }

    // MARK: Drawing — titleRect / drawTitle

    /// **Trailing mode centers the title in the WHOLE PLATE** — the keycap
    /// chip overlays the trailing edge without displacing it (owner ruling
    /// 2026-08-24). It used to hand the title everything to the LEFT of the
    /// chip and centre it in THAT, which put every CTA's word ~23 pt left of
    /// the plate's midline: "Start" and each speaker name visibly sat off
    /// centre while the plate around them was symmetric.
    ///
    /// The reserve is taken off BOTH sides, not just the chip's, which is the
    /// whole trick: an equal inset leaves the box's centre ON the plate's
    /// centre, so the title is genuinely centred AND still cannot reach under
    /// the chip when a long device name truncates. (Handing over the full
    /// bounds would centre just as well but let a long name run beneath the
    /// glyph.) Inline mode instead returns a rect sized
    /// exactly to the title's own width, positioned so title+gap+chip form
    /// one horizontally-centered group across the FULL plate height
    /// (`inlineGroupMinX`) — `drawKeycapChip` lays the chip immediately to
    /// its right using the same math.
    public override func titleRect(forBounds rect: NSRect) -> NSRect {
        guard let chipSize = chipSize else { return rect }
        switch chipPlacement {
        case .trailing:
            let reserve = Self.chipTrailingMargin + chipSize.width + Self.inlineChipGap
            guard rect.width > 2 * reserve else { return rect }
            return rect.insetBy(dx: reserve, dy: 0)
        case .inline:
            let x = inlineGroupMinX(in: rect, chipWidth: chipSize.width)
            return NSRect(x: x, y: rect.minY, width: inlineTitleWidth, height: rect.height)
        }
    }

    /// State color only: primary = the pinned `inkOnFill` (black — the bright
    /// gold fill is far too light to carry white; dimmed `label` when
    /// disabled, never faded gold text on faded gold fill); secondary =
    /// `label` (dimmed when disabled) — the panel's brightest text voice, the
    /// same one device/app names use (`AudioutPopoverUI/AGENTS.md`'s chrome
    /// hierarchy). The inline-chip plate is the together BAR — a quiet
    /// secondary answer that must not own the brightest text — so it speaks
    /// in `label2`.
    private var titleColor: NSColor {
        if isPrimary && isEnabled { return Self.primaryInkColor }
        let ink = chipPlacement == .inline ? Tokens.Color.label2 : Tokens.Color.label
        return ink.withAlphaComponent(interiorAlpha)
    }

    @discardableResult
    public override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect,
                                   in controlView: NSView) -> NSRect {
        let recolored = NSMutableAttributedString(attributedString: title)
        recolored.addAttribute(.foregroundColor, value: titleColor,
                               range: NSRange(location: 0, length: recolored.length))
        return super.drawTitle(recolored, withFrame: frame, in: controlView)
    }

    // MARK: Drawing — focus ring

    public override func focusRingMaskBounds(forFrame cellFrame: NSRect,
                                             in controlView: NSView) -> NSRect {
        cellFrame
    }

    public override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSBezierPath(roundedRect: cellFrame,
                     xRadius: PopoverColumnGrid.alignPlateCornerRadius,
                     yRadius: PopoverColumnGrid.alignPlateCornerRadius).fill()
    }

    // MARK: Keycap chip

    /// The chip's size for the current keycap — `nil` when no keycap is in
    /// use, so `titleRect` returns the bounds untouched.
    private var chipSize: NSSize? {
        guard let keycap, !keycap.isEmpty else { return nil }
        return keycap == Self.spaceKeycap
            ? NSSize(width: Self.chipWideWidth, height: Self.chipWideHeight)
            : NSSize(width: Self.chipNarrowSide, height: Self.chipNarrowSide)
    }

    /// Trailing placement: `chipTrailingMargin` in from the trailing edge,
    /// centred on the plate's midline; a press shifts it visually DOWN
    /// (+y, flipped).
    private func trailingChipRect(in frame: NSRect, size: NSSize, pressed: Bool) -> NSRect {
        var originY = frame.midY - size.height / 2
        if pressed { originY += Self.chipPressedShift }
        return NSRect(x: (frame.maxX - Self.chipTrailingMargin - size.width).rounded(),
                      y: originY.rounded(), width: size.width, height: size.height)
    }

    /// The title's own intrinsic width (inline mode only) — used both to
    /// size `titleRect` and to lay the chip immediately beside it. Measured
    /// off `attributedTitle`: an `NSButtonCell`'s `attributedStringValue` is
    /// its STATE ("0"), which handed the together bar's title 4 pt and
    /// truncated it to "T".
    private var inlineTitleWidth: CGFloat { attributedTitle.size().width.rounded(.up) + 2 }

    /// The horizontally-centered group's origin x (inline mode): title
    /// width + a 10 pt gap + the chip's width, centered in the full frame.
    private func inlineGroupMinX(in frame: NSRect, chipWidth: CGFloat) -> CGFloat {
        let groupWidth = inlineTitleWidth + Self.inlineChipGap + chipWidth
        return (frame.midX - groupWidth / 2).rounded()
    }

    /// The chip's rim and glyph ink: the pinned `inkOnFill` on a gold primary
    /// (it shares the title's ink — a chip drawn in the opposite value would
    /// read as a separate object stuck on the plate), the identity tint at
    /// full alpha, or `label2` on a neutral plate.
    private var chipInk: NSColor {
        if usesGoldSkin { return Self.primaryInkColor }
        return identityTint?.withAlphaComponent(1) ?? Tokens.Color.label2
    }

    private func drawKeycapChip(in frame: NSRect, pressed: Bool, alpha: CGFloat) {
        guard let keycap, let size = chipSize else { return }
        let chipRect: NSRect
        switch chipPlacement {
        case .trailing:
            chipRect = trailingChipRect(in: frame, size: size, pressed: pressed)
        case .inline:
            let groupMinX = inlineGroupMinX(in: frame, chipWidth: size.width)
            var originY = frame.midY - size.height / 2
            if pressed { originY += Self.chipPressedShift }
            chipRect = NSRect(x: (groupMinX + inlineTitleWidth + Self.inlineChipGap).rounded(),
                              y: originY.rounded(),
                              width: size.width, height: size.height)
        }
        let radius = Self.chipCornerRadius
        let chipPath = NSBezierPath(roundedRect: chipRect, xRadius: radius, yRadius: radius)
        let ink = chipInk

        // Inner bottom lip (2 pt rest, 1 pt pressed) — the chip's own small
        // recess, drawn INSIDE the clip so it never bleeds past the corners.
        NSGraphicsContext.current?.saveGraphicsState()
        chipPath.addClip()
        let lipHeight = pressed ? Self.chipLipPressedHeight : Self.chipLipRestHeight
        Tokens.Color.shadow.withAlphaComponent(Self.chipLipAlpha * alpha).setFill()
        // Flipped: the chip's visual bottom edge is `maxY`.
        NSRect(x: chipRect.minX, y: chipRect.maxY - lipHeight,
               width: chipRect.width, height: lipHeight).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        // Rim — the chip's ink, a step quieter than its glyph.
        ink.withAlphaComponent(Self.chipRimAlpha * alpha).setStroke()
        let rimPath = NSBezierPath(
            roundedRect: chipRect.insetBy(dx: Self.hairline / 2, dy: Self.hairline / 2),
            xRadius: radius, yRadius: radius)
        rimPath.lineWidth = Self.hairline
        rimPath.stroke()

        // Glyph — "electric on dark, Deep on light" (spec §2.1): the caller
        // resolved the tint; this is it at full strength.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: keycap, attributes: [
            .font: Tokens.Font.keycap,
            .foregroundColor: ink.withAlphaComponent(alpha),
            .paragraphStyle: paragraph,
        ])
        let textSize = attributed.size()
        let textRect = NSRect(x: (chipRect.midX - textSize.width / 2).rounded(),
                              y: (chipRect.midY - textSize.height / 2).rounded(),
                              width: textSize.width, height: textSize.height)
        attributed.draw(in: textRect)
    }

    // MARK: Geometry / constants

    /// 1 pt in points at 1x — hairline rim/bevel width (`WarmFaderCell`'s
    /// naming idiom).
    private static let hairline: CGFloat = 1
    /// How far the rest state's top lip lightens `raised` toward white —
    /// the approved mock's hairline, not the spec table's 0.35, which read
    /// as a bright wire along the top of every plate.
    private static let restTopLitBlend: CGFloat = 0.12
    /// Alpha of the rest state's bottom shade (`shadow` over `raised`).
    private static let restBottomShadeAlpha: CGFloat = 0.30
    /// Alpha of the pressed state's (inverted) top shade.
    private static let pressedTopShadowAlpha: CGFloat = 0.34
    /// How far the pressed state's (inverted) bottom lip lightens `raised`
    /// toward white.
    private static let pressedBottomLitBlend: CGFloat = 0.08
    /// How far the pressed PRIMARY fill darkens the pinned gold toward `shadow`.
    private static let pressedPrimaryShadowBlend: CGFloat = 0.18
    /// How far the PRIMARY plate's lit lip lightens the pinned gold toward white.
    private static let primaryLitBlend: CGFloat = 0.22
    /// Alpha of the PRIMARY plate's shaded lip.
    private static let primaryShadeAlpha: CGFloat = 0.22
    /// How far the PRIMARY plate's rim darkens the pinned gold toward `shadow`.
    private static let primaryRimShadowBlend: CGFloat = 0.35

    /// The one wide keycap label; every other keycap string draws at the
    /// narrow 22×22 size.
    private static let spaceKeycap = "SPACE"
    private static let chipNarrowSide: CGFloat = 22
    private static let chipWideWidth: CGFloat = 44
    private static let chipWideHeight: CGFloat = 20
    /// The keycap chip's corner radius — the control radius, where iOS puts
    /// chips. On the 22×22 glyph chips that is a rounded square; on the 44×20
    /// "SPACE" chip 10 is exactly half the height, so that one lands on a
    /// capsule. Left alone: it is the same radius, and the wide chip reading
    /// as a key is the point.
    private static let chipCornerRadius: CGFloat = Tokens.Layout.Radius.control
    /// Trailing placement: the chip's inset from the plate's trailing edge.
    private static let chipTrailingMargin: CGFloat = 14
    /// The chip rim's alpha over its glyph ink.
    private static let chipRimAlpha: CGFloat = 0.55
    /// Gap between the title and the chip in `inline` placement (spec §3).
    private static let inlineChipGap: CGFloat = 10
    private static let chipPressedShift: CGFloat = 1
    private static let chipLipRestHeight: CGFloat = 2
    private static let chipLipPressedHeight: CGFloat = 1
    private static let chipLipAlpha: CGFloat = 0.25
}
