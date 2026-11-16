// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// A 1 pt divider line in one of the two divider tokens. The caller sizes it.
///
/// `.containerEdge` on `raised`, `well` or bare canvas, where `hairline` is too
/// faint (1.154:1 on dark `raised`); `.hairline` on `panel`. Stock chrome (the
/// sidebar, Settings) keeps the stock `.separator` box instead.
///
/// Drawn in `draw(_:)` rather than stamped into a layer so the token re-resolves
/// on every paint, and subscribed to the Increase Contrast toggle, which fires
/// no appearance change. Never takes a click meant for what it borders.
public final class RuleView: NSView {

    public enum Tone {
        case hairline
        case containerEdge

        var color: NSColor {
            switch self {
            case .hairline: return Tokens.Color.hairline
            case .containerEdge: return Tokens.Color.containerEdge
            }
        }
    }

    public let tone: Tone

    public init(tone: Tone) {
        self.tone = tone
        super.init(frame: .zero)
        setAccessibilityElement(false)
        redrawOnAccessibilityDisplayChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func draw(_ dirtyRect: NSRect) {
        tone.color.setFill()
        bounds.fill()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
