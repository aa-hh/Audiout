// SPDX-License-Identifier: GPL-2.0-or-later
//
// Throwaway prototype (see main.swift). Not shipped, not linked by the app.

import AppKit
import AudiouterSharedUI

/// The two canvases the prototype can wear. The comparison is deliberately
/// narrow: Warm Signal's warm cream canvas versus Circuit UI's muted-white
/// neutrals, with the app's **gold accent held constant across both** — so the
/// only variable on screen is the canvas.
///
/// Only the chrome this target draws itself changes. The embedded production
/// views (device rows, faders, the Groups sidebar, the Settings panes) read
/// `Tokens` and stay Warm Signal in both, which is itself informative: it shows
/// how far a chrome-only swap actually gets you. Circuit's ink and border
/// values are therefore absent below — every piece of body text and every
/// divider on screen belongs to a production view, so nothing here would
/// consume them.
enum MockupTheme: Int, CaseIterable {
    case warmSignal
    case mutedWhite

    var title: String {
        switch self {
        case .warmSignal: return "Warm Signal"
        case .mutedWhite: return "Muted white"
        }
    }

    /// The window/canvas fill. Warm Signal defers to `WarmCanvasView` (gradient
    /// + grain) rather than this flat value — see `SurfaceScreenViewController`.
    var canvas: NSColor {
        switch self {
        case .warmSignal: return Tokens.Color.canvas
        case .mutedWhite: return circuitNeutral(0xFBFBF9)
        }
    }

    /// Raised/subtle surface — the opaque header fill under Reduce Transparency.
    var raised: NSColor {
        switch self {
        case .warmSignal: return Tokens.Color.canvasHi
        case .mutedWhite: return circuitNeutral(0xF5F4ED)
        }
    }

    var secondaryInk: NSColor {
        switch self {
        case .warmSignal: return Tokens.Color.secondaryLabel
        case .mutedWhite: return circuitNeutral(0x706464)
        }
    }

    /// Gold in both themes — the whole point of the comparison is that the
    /// accent does not move while the canvas underneath it does.
    var accent: NSColor { Tokens.Color.gold }

    /// Fill behind the selected tab.
    var tabSelectionFill: NSColor { accent.withAlphaComponent(0.16) }

    /// Tint fed to `NSGlassEffectView`. Warm on both, lighter over the muted
    /// white so the neutral canvas stays neutral; the glass tier itself is
    /// identical in both.
    var glassTint: NSColor {
        switch self {
        case .warmSignal: return accent.withAlphaComponent(0.08)
        case .mutedWhite: return accent.withAlphaComponent(0.05)
        }
    }

    /// `NSVisualEffectView` material for the macOS 14–15 fallback tier.
    var frostMaterial: NSVisualEffectView.Material { .headerView }
}

/// Circuit UI light-theme neutrals, transcribed from
/// `sumup-oss/circuit-ui packages/design-tokens/themes/light.ts`. Neutrals
/// only — Circuit's own accent colors are deliberately not adopted.
///
/// The repo's one-token-module rule (root `AGENTS.md`) forbids raw color
/// literals outside `Tokens`. This target is a deliberate, documented
/// exception: it exists to preview a canvas that is *not* Warm Signal, so it
/// cannot source those values from `Tokens` by definition. Nothing here is
/// linked by the app, and no production file was touched to make it work.
/// Light-only — Circuit's dark theme is a separate file upstream and the
/// prototype does not model it.
private func circuitNeutral(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}
