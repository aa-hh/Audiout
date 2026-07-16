// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

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

    /// The device/Main-Out icon column.
    public static let iconWidth: CGFloat = 22
    /// The volume/master slider column — one fixed width shared by every row so
    /// the slider column is identical in all three sections.
    public static let sliderWidth: CGFloat = 150
    /// The numeric `%` readout column (right-aligned).
    public static let readoutWidth: CGFloat = 40
    /// The speaker/mute glyph column, sitting **left of the slider** in every row
    /// (per-device mute on device rows, master mute on Main Out and group rows).
    public static let muteWidth: CGFloat = 24
    /// The connection-status slot column (brief §6): spinner / green dot /
    /// warning triangle, sitting between the `%` readout and the trailing
    /// (ENABLED switch) control. Only `DeviceRowView` fills it today, but it's a
    /// column in the shared grid like every other slot so a future row type can
    /// adopt it without re-deriving the trailing anchors.
    public static let statusWidth: CGFloat = 18
    /// The trailing control column, sized to the **widest** trailing control so
    /// the slider column clears it in every row: the Main Out row's named
    /// destination dropdown (task B). The device row's small mute button and the
    /// group row's (empty) slot right-align within this reserved column, so the
    /// slider's trailing edge lands at the same x in all three sections. Kept as
    /// tight as a named dropdown allows so the flexible name column keeps room.
    public static let trailingControlWidth: CGFloat = 116

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
    /// Gap between the `%` readout's trailing edge and the status slot's leading
    /// edge (brief §6) — kept small so the indicator reads as part of the same
    /// row cluster as the readout, not floated toward the switch. This is the
    /// flex-adjacent gap that used to sit directly between the readout and the
    /// trailing control before the status slot was inserted.
    public static let readoutToStatus: CGFloat = 6
    /// Gap between the status slot's trailing edge and the trailing control
    /// (ENABLED switch) it sits left of.
    public static let statusToTrailingControl: CGFloat = 6
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
    /// Distance from the row trailing edge to the **status slot's trailing
    /// edge** (brief §6) — the slot sits immediately left of the trailing
    /// control, at a fixed distance from the row edge like every other column.
    public static var statusTrailing: CGFloat {
        trailingControlTrailing + trailingControlWidth + statusToTrailingControl
    }
    /// Distance from the row trailing edge to the **slider's trailing edge** — the
    /// slider column is fixed-width and fixed here, so it lines up across every
    /// row type. Sized to clear the readout that hangs off it, the status slot,
    /// the min flex slack, and the trailing control.
    public static var sliderTrailing: CGFloat {
        statusTrailing + statusWidth + readoutToStatus
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
    /// Distance from the row trailing edge to the **status slot's center** (brief §6).
    public static var statusCenterFromTrailing: CGFloat { statusTrailing + statusWidth / 2 }
    /// Distance from the row trailing edge to the **trailing-control column's center**.
    public static var trailingControlCenterFromTrailing: CGFloat { trailingControlTrailing + trailingControlWidth / 2 }

    // Every element keeps plain `centerYAnchor` — no per-element optical nudge.
    // (The volume sliders are stock `NSSlider`s as of 2026-07-17; the earlier
    // custom Control-Center slider carried a 1.75pt optical-rise tweak, removed
    // with it when Alec reverted to default macOS slider styling.)
}
