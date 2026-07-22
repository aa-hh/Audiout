// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// **Warm Signal token module — the design-system entry point.**
///
/// GOVERNANCE RULE (locked, design-system-redesign Decision stream): this file
/// is the **only** place a custom (non-semantic) palette value may ever live
/// in this codebase. Every other call site — views, controllers, drawing
/// code across all five UI packages — must reach color, type, layout, and
/// material through `Tokens`, never through a raw literal `NSColor`,
/// `NSFont`, or magic number of its own.
///
/// **At this module's creation, `Tokens` held ZERO custom values.** Every
/// case aliased an existing stock `NSColor`/`NSFont`/`NSVisualEffectView.Material`
/// already in use, and `Tokens.Layout` re-exported `PopoverColumnGrid` (which
/// remains the geometry authority — nothing moved). That zero-custom-value
/// state was the SEAM, not a permanent constraint: **warm-signal-v2** (the
/// popover canvas + card de-nest, `dev/notes/warm-signal-v3.md` §1/§5.1) is
/// the first wave to actually populate `Tokens.Color` with real custom
/// values — the warm surface ladder + hairline (`canvas`, `canvasHi`,
/// `panel`, `raised`, `well`, `hairline`; see the "Warm Signal custom
/// palette" section below). `Tokens.Font`/`Tokens.Layout`/`Tokens.Material`
/// remain pure forwarding aliases; only `Tokens.Color` gains custom cases,
/// and only ones a real call site consumes this same wave. Gold/ember/glow/
/// `ring-connected`/caution/failure/link are deliberately NOT added yet —
/// those are the later S-chain (signal-color) tasks' job, once their call
/// sites exist.
///
/// Do not add a case here for a color/font/material combination that isn't
/// already used (or, for the warm palette, consumed by the very same commit)
/// in the codebase — this module documents and centralizes what exists, it
/// does not speculate ahead of real usage.
public enum Tokens {

    // MARK: - Color

    /// Semantic color aliases. Every case forwards to the exact `NSColor`
    /// class-property the codebase already calls directly (verified via
    /// `git grep -n "NSColor\." AudiouterCore/Sources/{AudiouterOnboardingUI,
    /// AudiouterSharedUI,AudiouterPopoverUI,AudiouterWindowUI,
    /// AudiouterSettingsUI}`). No custom RGB/hex value lives here — only
    /// forwarding. When the warm palette lands in a later wave, it replaces
    /// the right-hand side of these aliases; call sites that already route
    /// through `Tokens.Color` won't need to change.
    public enum Color {
        /// Primary label text. Alias of `NSColor.labelColor`.
        public static var label: NSColor { .labelColor }
        /// Secondary/subordinate label text (subtitles, hints). Alias of
        /// `NSColor.secondaryLabelColor`.
        public static var secondaryLabel: NSColor { .secondaryLabelColor }
        /// De-emphasized label text (sublabels, dimmed inline detail). Alias
        /// of `NSColor.tertiaryLabelColor`.
        public static var tertiaryLabel: NSColor { .tertiaryLabelColor }
        /// The system accent color, used for selection washes and active-state
        /// fills. Alias of `NSColor.controlAccentColor`.
        public static var accent: NSColor { .controlAccentColor }
        /// Hairline/divider strokes. Alias of `NSColor.separatorColor`.
        public static var separator: NSColor { .separatorColor }
        /// Opaque window chrome background (onboarding, Settings, control-panel
        /// backing bubble). Alias of `NSColor.windowBackgroundColor`.
        public static var windowBackground: NSColor { .windowBackgroundColor }
        /// The color a decorative punch-out border is drawn in so a badge
        /// reads as separate from what's behind it (`StatusDotView`). Alias of
        /// `NSColor.underPageBackgroundColor`.
        public static var underPageBackground: NSColor { .underPageBackgroundColor }
        /// Hover/selection wash background for list rows (`GroupRowView`,
        /// `AppRowView`, `DeviceRowView`). Alias of
        /// `NSColor.selectedContentBackgroundColor`.
        public static var selectedContentBackground: NSColor { .selectedContentBackgroundColor }
        /// Faint recessed track fill behind a meter/indicator (`LevelMeterView`'s
        /// track layer). Alias of `NSColor.tertiarySystemFill`.
        public static var tertiarySystemFill: NSColor { .tertiarySystemFill }
        /// The VU-meter fill color. Alias of `NSColor.systemGreen`.
        public static var meterFill: NSColor { .systemGreen }
        /// Destructive/error inline text (e.g. AppRowView's removed-app
        /// strikethrough label). Alias of `NSColor.systemRed`.
        public static var destructive: NSColor { .systemRed }
        /// Warning/failure sublabel and card tint (connection-diagnosis,
        /// onboarding failure card). Alias of `NSColor.systemOrange`.
        public static var warning: NSColor { .systemOrange }
        /// Opaque shadow color for card/panel drop shadows (`CardView`). Alias
        /// of `NSColor.black`.
        public static var shadow: NSColor { .black }
        /// Fully transparent fill, used to make a layer's background see
        /// through to a view behind it (`ControlPanelWindowController`). Alias
        /// of `NSColor.clear`.
        public static var clear: NSColor { .clear }

        // MARK: Warm Signal custom palette (V2, spec §1)
        //
        // The ONE place a custom (non-semantic) RGB value may live, per root
        // AGENTS.md's governance rule ("Every `Tokens.Color` case ships
        // light + dark + Increase Contrast variants with a documented
        // contrast rationale"). V2 (the popover canvas + card de-nest) is
        // the first consumer: the warm surface ladder + hairline from spec
        // §1.1 (dark) / §1.2 (light). `panel`/`raised`/`well` are defined
        // here per the spec's full palette table but are NOT YET painted
        // anywhere — V2's de-nest removes the card's own panel fill rather
        // than adding one; they're reserved for a later wave (ring contrast
        // reference, slider track/well, mute-pill fill). Every case below
        // resolves LIVE via `NSColor(name:dynamicProvider:)` against both
        // the color's `NSAppearance` argument (light/dark) and the CURRENT
        // `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast`
        // value every time AppKit asks for the resolved color — exactly
        // like `NSColor.labelColor` above already behaves for Dark Mode.
        // Never cache a `.cgColor`/`.set()` result outside a live draw or
        // `viewDidChangeEffectiveAppearance` refresh (see `WarmCanvasView`
        // in this target and `CardView`/its hairline sibling in
        // `AudiouterPopoverUI` for the pattern).

        /// The popover/content canvas — darkest rung, gradient base
        /// (§1.1/§1.2). No stated contrast floor (it's a background, not a
        /// foreground instrument), so no separate Increase Contrast value.
        public static var canvas: NSColor {
            warmDynamic(name: "canvas", dark: 0x16130F, light: 0xF4EFE7)
        }
        /// Canvas gradient top (§1.1/§1.2), paired with `canvas` by
        /// `WarmCanvasView`'s vertical gradient. No stated contrast floor.
        public static var canvasHi: NSColor {
            warmDynamic(name: "canvasHi", dark: 0x1B1712, light: 0xF7F3EC)
        }
        /// Card/panel fill — "the reference canvas a ring sits on" (§1). Not
        /// yet painted by any call site in V2 (cards stop drawing their own
        /// fill when de-nested onto the canvas, §5.1); reserved for a later
        /// wave. No stated contrast floor.
        public static var panel: NSColor {
            warmDynamic(name: "panel", dark: 0x1D1915, light: 0xFBF8F2)
        }
        /// Raised well fill (icon well, blocked-checkbox fill, §1). Not yet
        /// painted by any call site in V2 — reserved for a later wave. No
        /// stated contrast floor.
        public static var raised: NSColor {
            warmDynamic(name: "raised", dark: 0x241F1A, light: 0xFFFFFF)
        }
        /// Inset well fill (slider track trough, dropdown fill, §1). Not yet
        /// painted by any call site in V2 — reserved for a later wave. No
        /// stated contrast floor.
        public static var well: NSColor {
            warmDynamic(name: "well", dark: 0x2B2620, light: 0xECE5D8)
        }
        /// 1px section-divider hairline (§5.1 — the ONLY visual separation
        /// between de-nested cards now that they no longer draw their own
        /// material/shadow/rim). CONTRAST RATIONALE: dark carries a
        /// NORMATIVE floor in §1.1 ("≥3:1 vs `panel` only where
        /// load-bearing"). The spec's own literal hex (`#3A332B` on
        /// `panel` `#1D1915`) measures ≈1.40:1 by the WCAG relative-
        /// luminance formula — under floor. Per the spec's own escape valve
        /// ("any token below floor is brightened until it passes", §1) the
        /// Increase Contrast variant is a brightened warm-grey (`#786B5A`,
        /// ≈3.3:1 vs `panel`) rather than the literal spec hex; the BASE
        /// (non-IC) value stays exactly the spec'd hex since re-tuning base
        /// tokens for everyday legibility is the Wave-5 accessibility
        /// sweep's job, not V2's — V2 only has to make Increase Contrast
        /// itself clear the floor. Light's table entry states NO floor
        /// ("—"), but house rule 3 requires every case to ship an IC variant
        /// regardless, so a symmetrical darkened warm-tan (`#9B8768`,
        /// ≈3.25:1 vs light `panel` `#FBF8F2`) is used there too — the
        /// quietest reasonable choice, not a spec requirement.
        public static var hairline: NSColor {
            warmDynamic(name: "hairline", dark: 0x3A332B, darkHighContrast: 0x786B5A,
                       light: 0xE2DACC, lightHighContrast: 0x9B8768)
        }
    }

    // MARK: - Type

    /// Typography aliases. Every case forwards to the exact
    /// `NSFont.systemFont`/`.boldSystemFont`/`.menuFont` call and size the
    /// codebase already uses (verified via `git grep -n "NSFont\."` across
    /// the same five UI packages). No custom font family or arbitrary point
    /// size lives here — only forwarding of patterns already in use.
    public enum Font {
        /// Standard body text at the system's default control size — the most
        /// common label font in the app (row names, headings, form labels).
        /// Alias of `NSFont.systemFont(ofSize: NSFont.systemFontSize)`.
        public static var body: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }
        /// Body text, semibold weight — emphasized headings/titles at the
        /// standard size (e.g. permission-row titles, form section titles).
        public static var bodyEmphasized: NSFont {
            .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        }
        /// Body text, bold — used for an active/selected row name
        /// (`GroupRowView`). Alias of `NSFont.boldSystemFont(ofSize:)`.
        public static var bodyBold: NSFont { .boldSystemFont(ofSize: NSFont.systemFontSize) }
        /// A heading one step up from body (e.g. device-detail/group-editor
        /// name fields, +3pt semibold). Alias of
        /// `NSFont.systemFont(ofSize: NSFont.systemFontSize + 3, weight: .semibold)`.
        public static var heading: NSFont {
            .systemFont(ofSize: NSFont.systemFontSize + 3, weight: .semibold)
        }
        /// A large message title (mixer-window empty state, +2pt regular).
        /// Alias of `NSFont.systemFont(ofSize: NSFont.systemFontSize + 2)`.
        public static var titleLarge: NSFont {
            .systemFont(ofSize: NSFont.systemFontSize + 2)
        }
        /// A message subtitle paired with `titleLarge` (mixer-window empty
        /// state, −1pt regular). Alias of
        /// `NSFont.systemFont(ofSize: NSFont.systemFontSize - 1)`.
        public static var subtitleLarge: NSFont {
            .systemFont(ofSize: NSFont.systemFontSize - 1)
        }
        /// The small system font size — the app's secondary/detail text size
        /// (sublabels, readouts, hints, footers). Alias of
        /// `NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)`.
        public static var caption: NSFont { .systemFont(ofSize: NSFont.smallSystemFontSize) }
        /// Caption text, medium weight (appearance-tile labels, section
        /// sub-headers in the popover header row).
        public static var captionMedium: NSFont {
            .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        }
        /// Caption text, semibold weight (row titles set at the small size —
        /// PTP helper row, credits label, advanced-section labels, sidebar
        /// add-group field).
        public static var captionEmphasized: NSFont {
            .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        }
        /// The stock menu-item font, used where inline attributed text must
        /// match a real `NSMenuItem`'s rendering (`AppRowView`). Alias of
        /// `NSFont.menuFont(ofSize: 0)`.
        public static var menuItem: NSFont { .menuFont(ofSize: 0) }
    }

    // MARK: - Layout

    /// Layout aliases. `PopoverColumnGrid` remains the geometry authority —
    /// it is not moved, renamed, or duplicated. These are forwarding
    /// properties only, so code that wants "the app's layout tokens" has one
    /// import (`Tokens.Layout`) without new call sites needing to know that
    /// the underlying constants still live in `PopoverColumnGrid`.
    public enum Layout {
        /// Alias of `PopoverColumnGrid.leadingInset`.
        public static var leadingInset: CGFloat { PopoverColumnGrid.leadingInset }
        /// Alias of `PopoverColumnGrid.indentedLeadingInset`.
        public static var indentedLeadingInset: CGFloat { PopoverColumnGrid.indentedLeadingInset }
        /// Alias of `PopoverColumnGrid.trailingInset`.
        public static var trailingInset: CGFloat { PopoverColumnGrid.trailingInset }
        /// Alias of `PopoverColumnGrid.iconWidth`.
        public static var iconWidth: CGFloat { PopoverColumnGrid.iconWidth }
        /// Alias of `PopoverColumnGrid.sliderWidth`.
        public static var sliderWidth: CGFloat { PopoverColumnGrid.sliderWidth }
        /// Alias of `PopoverColumnGrid.readoutWidth`.
        public static var readoutWidth: CGFloat { PopoverColumnGrid.readoutWidth }
        /// Alias of `PopoverColumnGrid.muteWidth`.
        public static var muteWidth: CGFloat { PopoverColumnGrid.muteWidth }
        /// Alias of `PopoverColumnGrid.trailingControlWidth`.
        public static var trailingControlWidth: CGFloat { PopoverColumnGrid.trailingControlWidth }
        /// Alias of `PopoverColumnGrid.bodyRowHeight`.
        public static var bodyRowHeight: CGFloat { PopoverColumnGrid.bodyRowHeight }
    }

    // MARK: - Material

    /// `NSVisualEffectView.Material` aliases for the vibrancy materials the
    /// codebase already applies. No custom material or blending mode lives
    /// here — only forwarding.
    public enum Material {
        /// The system menu-surface material. Alias of
        /// `NSVisualEffectView.Material.menu`. UNCONSUMED as of V2: `CardView`
        /// and `PopoverPanelViewController` both used `.menu` directly (not
        /// through this alias) before the warm-signal-v2 de-nest, which
        /// replaced both call sites with the custom-painted warm canvas
        /// (`WarmCanvasView`, spec §5.1) — neither draws any
        /// `NSVisualEffectView` material anymore. Kept as a forwarding alias
        /// per the governance rule's spirit (it still names a real, applied-
        /// elsewhere-in-AppKit system material) but has no current call site;
        /// do not add a NEW consumer without checking this comment is still
        /// accurate.
        public static var popover: NSVisualEffectView.Material { .menu }
        /// Opaque window-chrome material (onboarding background, Settings
        /// window background, About panel). Alias of
        /// `NSVisualEffectView.Material.windowBackground`.
        public static var windowBackground: NSVisualEffectView.Material { .windowBackground }
        /// The source-list sidebar material, applied implicitly by
        /// `NSTabViewItem.sidebar(withViewController:)` in
        /// `SidebarViewController`/`MixerWindowController`. Alias of
        /// `NSVisualEffectView.Material.sidebar`.
        public static var sidebar: NSVisualEffectView.Material { .sidebar }
    }
}

// MARK: - Warm Signal palette internals (private to this file, per the
// governance rule: this is the ONE place a hex/RGB literal is permitted)

/// Builds an appearance- and Increase-Contrast-resolving `NSColor` for a
/// `Tokens.Color` warm-palette case. `name` becomes the `NSColor.Name` (so
/// repeated calls describe the same logical color, matching how
/// `NSColor.labelColor` etc. behave). The returned color re-evaluates the
/// closure every time AppKit resolves it against a drawing context's
/// appearance — never a frozen snapshot — exactly like the semantic aliases
/// above.
private func warmDynamic(name: String,
                          dark: UInt32, darkHighContrast: UInt32? = nil,
                          light: UInt32, lightHighContrast: UInt32? = nil) -> NSColor {
    NSColor(name: NSColor.Name("WarmSignal.\(name)")) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let hex: UInt32
        if isDark {
            hex = increaseContrast ? (darkHighContrast ?? dark) : dark
        } else {
            hex = increaseContrast ? (lightHighContrast ?? light) : light
        }
        return NSColor(warmSignalHex: hex)
    }
}

private extension NSColor {
    /// A literal `0xRRGGBB` → opaque `NSColor`. The only place in the
    /// codebase a hex literal is permitted to become a color.
    convenience init(warmSignalHex hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
