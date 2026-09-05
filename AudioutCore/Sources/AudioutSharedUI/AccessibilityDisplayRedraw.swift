// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

// MARK: - Increase Contrast redraw plumbing

public extension NSView {

    /// Redraws this view whenever the system's accessibility display options
    /// change — Increase Contrast above all.
    ///
    /// Call it once, from the view's initialiser, on any view whose `draw(_:)`
    /// reads `Tokens.Color`.
    ///
    /// Why it is needed at all: the Increase-Contrast variant of every warm
    /// token is chosen inside the token's own colour provider, off
    /// `NSWorkspace.accessibilityDisplayShouldIncreaseContrast`, NOT off the
    /// appearance (`Tokens.swift`'s `warmDynamic`/`scrimDynamic`/
    /// `accentDynamic`). The app also pins its own appearance for the theme
    /// setting, so flipping Increase Contrast in System Settings changes no
    /// view's effective appearance and fires no
    /// `viewDidChangeEffectiveAppearance`. A view that overrides only that
    /// method therefore keeps painting its standard-contrast hexes until some
    /// unrelated repaint happens to come along.
    ///
    /// `viewDidChangeEffectiveAppearance` is still needed for the light/dark
    /// half; this covers the other half. Views that stamp `CGColor`s onto a
    /// `CALayer` need more than a redraw and register their own handler
    /// instead (`DeviceIconWellView`, `HaloRingView`, `LevelMeterView`).
    ///
    /// No matching `removeObserver` — selector-based observation is
    /// auto-unregistered on dealloc (post-10.11 AppKit).
    func redrawOnAccessibilityDisplayChange() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(audioutRedrawForAccessibilityDisplayChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    @objc private func audioutRedrawForAccessibilityDisplayChange() {
        needsDisplay = true
    }
}
