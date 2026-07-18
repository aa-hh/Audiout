// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The **shared column grid** every popover row type lays out against so the
/// volume-slider column and the trailing-control column line up vertically across
/// all three sections — System (`MainOutRowView`), Selected Devices
/// (`DeviceRowView`) and Groups (`GroupRowView`). This vertical consistency is
/// the core of the popover layout overhaul (task B).
///
/// The trick that makes columns line up despite different *leading* controls
/// (a mini switch on device rows, an activate+chevron pair on group rows, a lone
/// icon on the Main Out row) is to anchor the fixed right-hand columns — slider
/// and trailing control — to fixed distances from the row's **trailing** edge,
/// not the leading edge. So no matter what leads a row, the slider's trailing
/// edge and the trailing control sit at the same x in every row. The name label
/// is the flexible column that absorbs the slack and truncates with a tail
/// ellipsis.
///
/// Columns, leading → trailing:
/// ```
/// │ [leading zone] [icon] [name  …  ] [ slider ][ %% ] ···flex··· [status][ ctl ] │
/// ```
/// The `%` readout is NOT trailing-anchored — it hangs immediately off the
/// **slider's** trailing edge (`sliderToReadout` gap), so the number always
/// reads tight against its slider on every slider row (Main Out + device rows),
/// not floated over near the trailing control. The flexible slack now lives
/// BETWEEN the readout and the trailing control instead of in the name column
/// alone; the slider column itself stays a fixed width and a fixed distance from
/// the trailing edge, so everything still lines up across row types. The
/// connection-status slot (brief §6) sits fixed between the readout and the
/// trailing control, same trailing-anchored trick. A row that lacks a given
/// column leaves the slot empty but keeps the same anchors.
public enum PopoverColumnGrid {

    // MARK: Leading edges

    /// Leading inset of the first control in a top-level (non-indented) row.
    public static let leadingInset: CGFloat = 14
    /// Leading inset for a group **member** row so it reads indented under its
    /// group header (SPEC §9 "one indented device row per member").
    public static let indentedLeadingInset: CGFloat = 30
    /// Trailing inset of the last column from the row's trailing edge.
    public static let trailingInset: CGFloat = 14

    // MARK: Fixed column widths

    /// The device/Main-Out icon column. Bumped 22→26 (2026-07-17) when the
    /// connection-status indicator moved OFF a right-side slot and ONTO the icon
    /// as a corner badge (``StatusDotView``) — a slightly larger glyph gives the
    /// badge somewhere to sit without crowding the symbol.
    public static let iconWidth: CGFloat = 26
    /// The volume/master slider column — one fixed width shared by every row so
    /// the slider column is identical in all three sections.
    public static let sliderWidth: CGFloat = 150
    /// The numeric `%` readout column (right-aligned).
    public static let readoutWidth: CGFloat = 40
    /// The speaker/mute glyph column, sitting **left of the slider** in every row
    /// (per-device mute on device rows, master mute on Main Out and group rows).
    public static let muteWidth: CGFloat = 24
    /// The trailing control column, sized to the **widest** trailing control so
    /// the slider column clears it in every row: the Main Out row's named
    /// destination dropdown (task B). The device row's small mute button and the
    /// group row's (empty) slot right-align within this reserved column, so the
    /// slider's trailing edge lands at the same x in all three sections. Kept as
    /// tight as a named dropdown allows so the flexible name column keeps room.
    public static let trailingControlWidth: CGFloat = 116

    // MARK: On-icon status badge (2026-07-17)
    //
    // The connection-status indicator is a small corner dot overlapping the
    // device icon's bottom-right (a notification-badge position), replacing the
    // retired right-side status slot. These are grouped as NAMED CONSTANTS on
    // purpose: a future settings menu will offer compact/normal/large row
    // densities, so the icon + badge sizing must be swappable HERE, in one
    // place, not scattered as magic numbers across `DeviceRowView`/``StatusDotView``.

    /// Diameter of the on-icon status badge (the connection-state dot).
    public static let statusDotDiameter: CGFloat = 10
    /// Width of the punch-out border ringing the badge, drawn in the card/window
    /// background colour so the dot reads as a separate badge over the icon. A
    /// best-effort separator — tuned live later.
    public static let statusDotBorderWidth: CGFloat = 1.5
    /// Duration of one half-cycle of the connecting/reconnecting "breathing"
    /// pulse (opacity + scale), auto-reversed and repeated forever.
    public static let statusDotBreathDuration: CFTimeInterval = 1.6
    /// The breathing pulse's minimum opacity (rises to 1.0).
    public static let statusDotBreathMinOpacity: Float = 0.3
    /// The breathing pulse's minimum scale (grows to 1.0).
    public static let statusDotBreathMinScale: CGFloat = 0.82

    /// SF-Symbol point size for the device icon glyph. Without this the symbol
    /// renders at its small default size and floats in the middle of the 26pt
    /// box (leaving the corner badge stranded in empty padding); sizing it here
    /// fills the box so the glyph's corner ≈ the box corner and the badge sits
    /// ON the symbol (2026-07-17, matching the approved mockup).
    public static let iconGlyphPointSize: CGFloat = 18
    /// How far the badge's center is pulled IN from the icon box's bottom-right
    /// corner so it rides the glyph's corner (a slight overhang) rather than
    /// sitting off in the box padding. Tuned live.
    public static let statusDotInset: CGFloat = 3

    // MARK: Unified row styling — body rows, hover, selection (2026-07-18)
    //
    // Visual tokens shared by `DeviceRowView` and `AppRowView` so both row types
    // present a consistent row height and interactive-state styling (hover wash and
    // selection wash). These named constants unify the row-dimension choices and
    // enable the two row types to render as a cohesive popover list.

    /// The shared body-row height for DeviceRowView and AppRowView, unifying
    /// the previously divergent 42 (device) and 38 (app) heights. Consumers adopt
    /// this constant in a later task.
    public static let bodyRowHeight: CGFloat = 42
    /// Alpha for the unified pointer-hover wash, drawn in
    /// `NSColor.selectedContentBackgroundColor` at this opacity. Shared by
    /// DeviceRowView and AppRowView to establish consistent hover interaction.
    public static let rowHoverWashAlpha: CGFloat = 0.10
    /// Alpha for the accent selection wash, drawn in `NSColor.controlAccentColor`.
    /// Shared by AppRowView's single-selection highlight and DeviceRowView's
    /// mixer-window selection pill.
    public static let rowSelectionWashAlpha: CGFloat = 0.18

    // MARK: Single-selection highlight (AppRowView, 2026-07-17)
    //
    // The Applications card's single-selection model (± footer controls,
    // context-menu remove, Delete/Backspace) needs a selected-row highlight
    // distinct from `DeviceRowView`'s membership/hover pill. Named here per
    // house rule (no magic numbers) even though today only `AppRowView` draws it.

    /// Horizontal/vertical inset of the selection-highlight rounded rect from
    /// the row's bounds — matches `DeviceRowView`'s hover/selection pill inset.
    public static let selectionHighlightInsetX: CGFloat = 5
    public static let selectionHighlightInsetY: CGFloat = 2
    /// Corner radius of the selection-highlight rounded rect.
    public static let selectionHighlightCornerRadius: CGFloat = 7

    // MARK: Applications card ± footer (T3, 2026-07-17)
    //
    // The Applications card footer row hosting the add/remove
    // `NSSegmentedControl` (LOCKED DECISION: replaces the old "+ Add
    // application…" row). Named here per house rule even though only
    // `PopoverController`'s footer row view uses them.

    /// Height of the footer row containing the ± segmented control.
    public static let applicationsFooterRowHeight: CGFloat = 28
    /// Width of the ± segmented control (two equal segments).
    public static let applicationsFooterControlWidth: CGFloat = 50
    /// Height of the ± segmented control.
    public static let applicationsFooterControlHeight: CGFloat = 20

    // MARK: Inter-column gaps

    /// Gap after the icon, before the name.
    public static let iconToName: CGFloat = 9
    /// Gap between the name and the slider column.
    public static let nameToSlider: CGFloat = 12
    /// Gap between the slider's trailing edge and the `%` readout's leading edge
    /// — kept small so the number reads tight against the slider on every slider
    /// row (change 4). Slider rows anchor the readout off `slider.trailingAnchor`
    /// with this constant; the derived `readoutTrailing` below is only for rows
    /// that still trailing-anchor the readout (`GroupRowView`), and is defined so
    /// the two placements coincide.
    public static let sliderToReadout: CGFloat = 6
    /// Gap between the `%` readout's trailing edge and the trailing control
    /// (ENABLED switch) it sits left of — the flexible slack column. The
    /// right-side status slot was retired 2026-07-17 (status moved onto the
    /// icon), so the readout now sits directly before the trailing control again.
    public static let readoutToTrailingControl: CGFloat = 6
    /// Gap between the mute glyph and the slider it sits left of.
    public static let muteToSlider: CGFloat = 6

    // MARK: Derived trailing anchors
    //
    // These are the load-bearing numbers: distances (positive, measured inward)
    // from the row's trailing edge to the trailing edge of each right-hand
    // column. Anchoring off the trailing edge is what makes the columns line up
    // across rows with different leading controls.

    /// Distance from the row trailing edge to the **trailing control's trailing
    /// edge** (i.e. the trailing control's own trailing inset).
    public static var trailingControlTrailing: CGFloat { trailingInset }
    /// Distance from the row trailing edge to the **slider's trailing edge** — the
    /// slider column is fixed-width and fixed here, so it lines up across every
    /// row type. Sized to clear the readout that hangs off it, the min flex
    /// slack, and the trailing control. (The right-side status slot that once sat
    /// between the readout and the trailing control was retired 2026-07-17.)
    public static var sliderTrailing: CGFloat {
        trailingControlTrailing + trailingControlWidth + readoutToTrailingControl
            + readoutWidth + sliderToReadout
    }
    /// Distance from the row trailing edge to the **readout's trailing edge**.
    /// Only used by rows that still trailing-anchor the readout (`GroupRowView`);
    /// slider rows instead anchor it off `slider.trailingAnchor + sliderToReadout`.
    /// Defined as exactly that same x so both placements coincide and the readout
    /// column stays aligned across row types.
    public static var readoutTrailing: CGFloat {
        sliderTrailing - readoutWidth - sliderToReadout
    }

    // MARK: Column-center helpers (for the combined section/column header row)
    //
    // Distances (positive, measured inward from the row trailing edge) to the
    // horizontal *center* of a column, so a header label can be centered over it.

    /// Distance from the row trailing edge to the **slider column's center**.
    public static var sliderCenterFromTrailing: CGFloat { sliderTrailing + sliderWidth / 2 }
    /// Distance from the row trailing edge to the **trailing-control column's center**.
    public static var trailingControlCenterFromTrailing: CGFloat { trailingControlTrailing + trailingControlWidth / 2 }

    // Every element keeps plain `centerYAnchor` — no per-element optical nudge.
    // (The volume sliders are stock `NSSlider`s as of 2026-07-17; the earlier
    // custom Control-Center slider carried a 1.75pt optical-rise tweak, removed
    // with it when ahh reverted to default macOS slider styling.)
}
