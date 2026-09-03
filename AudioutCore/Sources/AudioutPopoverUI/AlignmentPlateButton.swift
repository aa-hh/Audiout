// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The alignment-wizard's plate control (wizard-stage v2 spec §3): an
/// `NSButton` wearing `AlignmentPlateCell`. Installs the cell FIRST, then
/// configures the control — `WarmFaderCell`/`WarmNameFieldCell`'s house rule
/// (`AudioutSharedUI/AGENTS.md`: "the host swaps the cell in FIRST and
/// configures the field after"), so every subsequent config call lands on
/// the new cell rather than the stock one.
///
/// `isBordered` stays `true` even though `AlignmentPlateCell.drawBezel`
/// never calls `super` and fully replaces the stock bezel's paint: a
/// BORDERLESS button silently discards `drawFocusRingMask` (openradar
/// 29465363), which would kill keyboard-focus visibility on every plate.
/// Keeping the bit set costs nothing visually — the cell owns the pixels
/// either way — and buys back the focus ring.
public final class AlignmentPlateButton: NSButton {

    private let plateCell = AlignmentPlateCell()
    private var hoverTrackingArea: NSTrackingArea?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        cell = plateCell // cell installed FIRST
        setButtonType(.momentaryPushIn)
        bezelStyle = .push // never the deprecated `.rounded`
        isBordered = true // see the type doc — required for the focus ring, not for the stock bezel
        title = ""
    }

    /// The `.push` bezel style carries AppKit's own alignment-rect insets
    /// (~7 pt a side), which Auto Layout applies OUTSIDE the 220×64 the
    /// caller constrains — so the drawn plate was 234×76 and overhung its
    /// row. The cell paints the full frame, so the frame IS the alignment
    /// rect.
    public override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    // MARK: Hover tracking (feeds `AlignmentPlateCell.isHovered`)

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        plateCell.isHovered = true
        needsDisplay = true
    }

    public override func mouseExited(with event: NSEvent) {
        plateCell.isHovered = false
        needsDisplay = true
    }

    // MARK: Configuration

    /// Convenience config API — sets the title, the drawn keycap chip (and
    /// its accessibility mirror), whether this is the screen's ONE primary
    /// (`gold`-filled) plate, the per-side identity tint (`nil` = the neutral
    /// `rim`, spec §2.1), and where the chip sits relative to the
    /// title (`trailing` for every plate but the together bar, which passes
    /// `.inline` — spec §3).
    public func configure(title: String, keycap: String? = nil,
                          isPrimary: Bool = false, identityTint: NSColor? = nil,
                          chipPlacement: AlignmentPlateCell.ChipPlacement = .trailing) {
        self.title = title
        plateCell.keycap = keycap
        plateCell.isPrimary = isPrimary
        plateCell.identityTint = identityTint
        plateCell.chipPlacement = chipPlacement
        setAccessibilityHelp(Self.accessibilityHelp(forKeycap: keycap))
        needsDisplay = true
    }

    /// Mirrors the drawn keycap glyph into the AX hint (spec §3: "the chip
    /// must not be an AX element" — this string is how its meaning still
    /// reaches VoiceOver, spoken as the control's help rather than a second
    /// element).
    private static func accessibilityHelp(forKeycap keycap: String?) -> String? {
        switch keycap {
        case "←": return "Press Left Arrow"
        case "→": return "Press Right Arrow"
        case "SPACE": return "Press Space"
        case "⏎": return "Press Return"
        default: return nil
        }
    }

    // MARK: Test-support hooks

    public var test_isHovered: Bool { plateCell.isHovered }
    public var test_isPrimary: Bool { plateCell.isPrimary }
    public var test_keycap: String? { plateCell.keycap }
    public var test_identityTint: NSColor? { plateCell.identityTint }
}
