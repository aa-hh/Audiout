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
/// **As of this module's creation, `Tokens` holds ZERO custom values.** Every
/// `Tokens.Color` case below aliases an existing stock `NSColor` semantic
/// (`.labelColor`, `.controlAccentColor`, …) that call sites already use
/// directly today; every `Tokens.Font case aliases an existing
/// `NSFont.systemFont`/`NSFont.boldSystemFont` pattern and size already in
/// use; `Tokens.Layout` re-exports `PopoverColumnGrid`'s existing constants
/// (which remains the geometry authority — nothing moved); `Tokens.Material`
/// aliases the existing `NSVisualEffectView.Material` cases already applied.
/// Introducing this module is a **zero visual change, zero behavior change**
/// step: it creates the one-import seam future call sites will route
/// through, and the seam through which the warm palette will later be
/// introduced (a later wave), without touching any call site yet.
///
/// Do not add a case here for a color/font/material combination that isn't
/// already used in the codebase — this module documents and centralizes
/// what exists, it does not speculate ahead of real usage.
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
        /// The popover/menu-surface material (`CardView`,
        /// `PopoverPanelViewController`). Alias of
        /// `NSVisualEffectView.Material.menu`.
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
