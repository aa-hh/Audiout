// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The ONE surface canvas (owner decision 2026-08-07, live build review):
/// a flat, fully opaque fill of `Tokens.Color.panel` — originally the Groups
/// screen's content-pane background (Warm Signal spec §5.3, decision j), now
/// the background every surface screen sits on. The owner picked the Groups
/// pane's flat warm `panel` as the app's one canvas; the Mixer's gradient+grain
/// `WarmCanvasView` and Settings' stock `.windowBackground` material are
/// superseded INSIDE the surface (the Setup window keeps `WarmCanvasView`;
/// About keeps stock chrome — both are their own windows, outside the surface).
///
/// No grain (grain was the popover's density texture, §1.1) and no gradient.
/// A `draw(_:)` override — deliberately NOT a frozen layer color — so the
/// token re-resolves live per appearance flip and Increase Contrast on every
/// paint (`WarmCanvasView`'s pattern; always opaque, so Reduce Transparency
/// needs no fallback branch).
public final class WarmPanelView: NSView {

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func draw(_ dirtyRect: NSRect) {
        Tokens.Color.panel.setFill()
        bounds.fill()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
