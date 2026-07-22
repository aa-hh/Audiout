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

    // MARK: Meter column (leading edge, task T-METER)

    /// Width of the volume-meter column, the new leading column on every row.
    public static let meterWidth: CGFloat = 8
    /// Gap from the row's leading inset to the meter column.
    public static let meterToLeading: CGFloat = 8
    /// Leading edge of the first row element (accounting for indentation).
    /// Computed as (indented ? indentedLeadingInset : leadingInset) + meterWidth + meterToLeading.
    public static func firstElementLeading(indented: Bool) -> CGFloat {
        (indented ? indentedLeadingInset : leadingInset) + meterWidth + meterToLeading
    }

    // MARK: Fixed column widths

    /// The device/Main-Out icon column. Bumped 22→26 (2026-07-17) when the
    /// connection-status indicator moved OFF a right-side slot and ONTO the icon
    /// as a corner badge (`StatusDotView`) — a slightly larger glyph gives the
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
    /// tight as a named dropdown allows so the flexible name column keeps room —
    /// sized (116 → 140, Warm Signal C1) so the two longest fixed dropdown
    /// titles, "Follows main output" (the app-row bridge phrase, decision 3) and
    /// the count-free "Selected Devices" (decision m), fit a small-control
    /// `NSPopUpButton` untruncated (measured fitting width 137 pt).
    public static let trailingControlWidth: CGFloat = 140

    // MARK: On-icon status badge (2026-07-17)
    //
    // The connection-status indicator is a small corner dot overlapping the
    // device icon's bottom-right (a notification-badge position), replacing the
    // retired right-side status slot. These are grouped as NAMED CONSTANTS on
    // purpose: a future settings menu will offer compact/normal/large row
    // densities, so the icon + badge sizing must be swappable HERE, in one
    // place, not scattered as magic numbers across `DeviceRowView`/``HaloRingView``.

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

    // MARK: Halo connection ring (Warm Signal v3 §3.2, S1)
    //
    // The ring drawn AROUND the device icon carries the connection lifecycle
    // (`Device.connectionState`), replacing the retired corner connection dot.
    // Geometry lives here (promoted per spec §3.2 "geometry off
    // PopoverColumnGrid") so a future density setting swaps ring + icon sizing
    // in one place. The visible ring circle is `haloRingDiameter` (21 pt) inside
    // the 26 pt `iconWidth` box — the size the ≥3:1 `ringConnected` contrast
    // floor is tested at (spec §3.2). The breathing pulse REUSES the
    // `statusDotBreath*` timing constants above (spec §6: "breathing pulse
    // (`statusDotBreathDuration` timing)").

    /// Diameter of the visible connection-ring circle (the stroke centerline),
    /// inside the `iconWidth` (26 pt) icon box. The contrast floor is tested at
    /// this size (spec §3.2).
    public static let haloRingDiameter: CGFloat = 21
    /// Stroke width of the **connected** solid ring (spec §3.2 ≈1.6 pt).
    public static let haloRingConnectedStroke: CGFloat = 1.6
    /// Stroke width of the **connecting/reconnecting** dashed ring — same weight
    /// as connected; the dashed FORM (not weight) carries "pending" (spec §3.2).
    public static let haloRingConnectingStroke: CGFloat = 1.6
    /// Stroke width of the **failed** solid ring — deliberately heavier than the
    /// connected ring (spec §3.2 ≈1.8 pt) so a failed row wins the scan beside
    /// flickering meters (redundant weight atop the failure hue).
    public static let haloRingFailedStroke: CGFloat = 1.8
    /// Dash segment length for the connecting ring (the "incomplete" form).
    public static let haloRingDashLength: CGFloat = 2.6
    /// Gap length between connecting-ring dashes.
    public static let haloRingDashGap: CGFloat = 2.6

    // MARK: Route-armed corner dot (Warm Signal v3 §3.3, S2)
    //
    // The gold "route armed & held" dot sits at the icon's bottom-right corner
    // — the position the retired connection dot (`StatusDotView`) vacated,
    // placed off the same `statusDotInset` corner pull-in. PURE MODEL STATE,
    // never RMS (spec §3.3 / R3): the meter is the only signal-driven channel.
    // Named here per the density-setting rule, like the halo-ring block above.

    /// Diameter of the lit/socket route-armed dot disc (spec/S2 "6 pt gold
    /// disc" — deliberately smaller than the retired 10 pt connection dot so a
    /// lit dot reads as an indicator, not a beacon; R1's luminance/size cap).
    public static let routeArmedDotDiameter: CGFloat = 6
    /// Blur radius of the lit dot's STATIC `glow` halo (spec §3.3 "subtle
    /// glow" — a resting shadow, not an animation; energy rule intact).
    public static let routeArmedGlowRadius: CGFloat = 3
    /// Opacity of the lit dot's static `glow` halo shadow.
    public static let routeArmedGlowOpacity: Float = 0.55
    /// Duration of the one-shot `ember → gold` bloom when a dot transitions
    /// INTO armed while visible (spec §6 first-light bloom, ≤450 ms ease-out;
    /// instant under Reduce Motion; never fires on initial render).
    public static let routeArmedBloomDuration: CFTimeInterval = 0.45
    /// Side length of the square overlay view hosting the dot — big enough to
    /// contain the disc plus its glow halo without clipping.
    public static let routeArmedDotBoxSize: CGFloat = 14

    // MARK: Membership bus (Warm Signal v3 §4, S-BUS)
    //
    // The "bus" replaces the membership CHECKBOX's DRAWING (spec §4): a continuous
    // vertical line dropping down one fixed column past every device row, with a
    // FILLED gold node on the line for a member and a HOLLOW node the line DETOURS
    // around (a wire-hop arc) for a non-member. Only the drawing changes — the same
    // real `NSButton` checkbox lives underneath (spec §4.8). Geometry is promoted
    // here (spec §4.1 "constants promoted into PopoverColumnGrid") so a future
    // density setting swaps node + column sizing in one place, exactly like the
    // halo-ring block above.
    //
    // COLUMN X: the node column reuses `trailingControlCenterFromTrailing` (the
    // checkbox's real current center, §0.1 / §4.1) — the bus IS the trailing
    // column. Every node sits at exactly that x; toggling changes only FILL and
    // LINE PATH, never position (zero layout shift — R7 / §4.1). No new column.

    /// Diameter of a bus node (spec §4.1 "~13 pt, matching the current `.switch`
    /// checkbox visual box").
    public static let busNodeDiameter: CGFloat = 13
    /// Stroke width of the bus line (spec §4.1 "~2 pt, `ember` token").
    public static let busLineWidth: CGFloat = 2
    /// Stroke width of the ember rim ringing a filled node / edging a hollow one
    /// (spec §4.2 "solid `gold` disc with `ember` rim" / "hollow … with an
    /// `ember`/`hairline` rim").
    public static let busNodeRimWidth: CGFloat = 1.5
    /// How far past the node radius the hop-arc bows outward when the line detours
    /// a HOLLOW node (spec §4.2 "bows outward into a small semicircular hop arc").
    /// The detour semicircle's radius is `busNodeDiameter/2 + busDetourBulge`.
    public static let busDetourBulge: CGFloat = 4.5
    /// Width of the non-interactive bus-overlay column view a row hosts, centered
    /// on the node column x. Wide enough to contain the leading-side hop-arc
    /// (`busNodeDiameter/2 + busDetourBulge` from center) plus the line width,
    /// without clipping. The overlay spans the full row height so stacked rows'
    /// rail segments read as one continuous line.
    public static let busColumnWidth: CGFloat = 30

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

    // MARK: Engaged mute pill (Warm Signal v3 §3.4/§3.5, S3)
    //
    // A muted row's mute button gains a filled accent-tinted PILL behind its
    // (never-slashed — locked decision) speaker glyph: drawing only, on the
    // real `NSButton`'s backing layer; behavior/keyboard/VoiceOver untouched.

    /// Alpha of the engaged pill's accent fill (subtle — config-adjacent, not
    /// a signal; the gold budget governs gold, accent chrome is permitted).
    public static let mutePillFillAlpha: CGFloat = 0.22
    /// Corner radius of the engaged pill (capsule-ish over the `muteWidth`
    /// column's glyph box). Tuned live.
    public static let mutePillCornerRadius: CGFloat = 7

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
