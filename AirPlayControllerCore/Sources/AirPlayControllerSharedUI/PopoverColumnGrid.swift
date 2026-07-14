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
/// icon on the Main Out row) is to anchor the right-hand columns — slider, %
/// readout, trailing control — to fixed distances from the row's **trailing**
/// edge, not the leading edge. So no matter what leads a row, the slider's
/// trailing edge, the readout, and the trailing control all sit at the same x in
/// every row. The name label is the single flexible column that absorbs the
/// slack and truncates with a tail ellipsis.
///
/// Columns, leading → trailing:
/// ```
/// │ [leading zone] [icon] [name  …  ] [ slider ] [ %% ] [ ctl ] │
/// ```
/// A row that lacks a given column simply leaves the slot empty but keeps the
/// same right-hand anchors, so alignment holds.
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
    /// Gap between the slider and the `%` readout.
    public static let sliderToReadout: CGFloat = 8
    /// Gap between the `%` readout and the trailing control.
    public static let readoutToTrailing: CGFloat = 8
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
    /// Distance from the row trailing edge to the **readout's trailing edge**.
    public static var readoutTrailing: CGFloat {
        trailingInset + trailingControlWidth + readoutToTrailing
    }
    /// Distance from the row trailing edge to the **slider's trailing edge**.
    public static var sliderTrailing: CGFloat {
        readoutTrailing + readoutWidth + sliderToReadout
    }

    // MARK: Column-center helpers (for ColumnHeaderRow)
    //
    // Distances (positive, measured inward from the row trailing edge) to the
    // horizontal *center* of a column, so a header label can be centered over it.

    /// Distance from the row trailing edge to the **slider column's center**.
    public static var sliderCenterFromTrailing: CGFloat { sliderTrailing + sliderWidth / 2 }
    /// Distance from the row trailing edge to the **trailing-control column's center**.
    public static var trailingControlCenterFromTrailing: CGFloat { trailingControlTrailing + trailingControlWidth / 2 }
}
