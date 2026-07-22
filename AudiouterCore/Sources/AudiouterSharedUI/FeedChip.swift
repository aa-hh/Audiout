// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The small derived-colour **square chip** both ends of an app→device tether
/// wear (Warm Signal v4.1 CORRECTIONS — "FEED needs the COLOUR CHIP, not just
/// tinted text … matching the chip on that app's redirect dropdown entry, so
/// the tether reads at both ends"): `DeviceRowView`'s FEED column prefixes a
/// redirected app's name segment with one, and `AppRowView` prefixes the same
/// app's own name with the identical chip, both colored via `AppTetherColor`.
///
/// Rendered as an `NSTextAttachment` so it rides inline with the text run it
/// prefixes (composing, measuring, and clipping with the surrounding label for
/// free) rather than as a separate subview needing its own layout pass. The
/// chip's fill color is an `AppTetherColor`-derived, appearance-adaptive
/// `NSColor` resolved AT DRAW TIME (the `NSImage` drawing-handler closure runs
/// on every render, not once at construction) — same "resolve live" discipline
/// as `WarmFaderCell`/`HaloRingView`, so light/dark and Increase Contrast track
/// for free and `cacheDisplay` output stays deterministic for a fixed input.
///
/// A neutral segment (the main-mix "System"/group-name text, or a failure-red
/// error word) never gets a chip — callers only invoke this for a tinted app
/// segment, per the "neutral segments + error words untinted/red" house rule.
enum FeedChip {
    /// One chip-sized attachment string in `color`, sized/gapped from
    /// `PopoverColumnGrid.feedChipSize`/`feedChipGap`/`feedChipCornerRadius`.
    /// The trailing gap is baked into the attachment's own width (transparent
    /// padding to the right of the drawn square) rather than a following space
    /// glyph, so the attachment contributes exactly ONE character
    /// (`NSTextAttachment`'s `\u{FFFC}` object-replacement character) to the
    /// composed string — callers that strip that one character back out (for
    /// a plain-text test read) never have to also trim a stray leading space.
    static func attachmentString(color: NSColor, font: NSFont) -> NSAttributedString {
        let chipSize = PopoverColumnGrid.feedChipSize
        let totalWidth = chipSize + PopoverColumnGrid.feedChipGap
        let image = NSImage(size: NSSize(width: totalWidth, height: chipSize), flipped: false) { _ in
            let chipRect = NSRect(x: 0, y: 0, width: chipSize, height: chipSize)
            let path = NSBezierPath(roundedRect: chipRect,
                                    xRadius: PopoverColumnGrid.feedChipCornerRadius,
                                    yRadius: PopoverColumnGrid.feedChipCornerRadius)
            color.setFill()
            path.fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Vertically center the chip on the font's cap-height, not the full
        // line box, so it optically aligns with the text it prefixes.
        let yOffset = (font.capHeight - chipSize) / 2
        attachment.bounds = CGRect(x: 0, y: yOffset, width: totalWidth, height: chipSize)
        return NSAttributedString(attachment: attachment)
    }

    /// The Unicode object-replacement character AppKit inserts into a label's
    /// plain `string`/`stringValue` for every `NSTextAttachment` — callers
    /// strip this back out when a test hook needs the rendered WORDS only,
    /// without parsing attachment runs itself.
    static let objectReplacementCharacter = "\u{FFFC}"
}
