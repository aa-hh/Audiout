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

    // MARK: Leading gutter reserve (Warm Signal v4 §Call-1 — the LEFT SPINE)
    //
    // Warm Signal v4 retires the leading VERTICAL meter column (the meter moves
    // UNDER THE NAME, `meterUnderName*` below) and re-homes the leading gutter as
    // the **membership rail's spine**. Per Alec's clearance refinement the gutter
    // is WIDENED so every node has clear negative space to its right before the
    // icon tile — the spine reads airy, not cramped. The reserve is DERIVED from
    // the rail geometry (`railGutterCenterX` + node radius + `busNodeClearance`)
    // so widening any of those reflows the leading columns consistently. Only the
    // LEADING columns move; VOLUME (slider) and OUTPUT (trailing) columns are
    // trailing-anchored, so their alignment across sections is untouched.

    /// Horizontal negative space between a bus node's right edge and the icon
    /// tile to its right (Alec's clearance refinement) — the node must not crowd
    /// the icon. Also the single knob that widens the whole leading gutter.
    public static let busNodeClearance: CGFloat = 12
    /// The leading gutter reserve: from the plain `leadingInset` to the icon —
    /// wide enough for the rail spine (node radius) plus clear padding to the
    /// icon. Derived, so growing `railGutterCenterX` / `busNodeClearance` reflows
    /// the icon/name columns in lockstep.
    public static var busGutterWidth: CGFloat {
        railGutterCenterX + busNodeDiameter / 2 + busNodeClearance - leadingInset
    }
    /// Leading edge of the first row element (the icon), accounting for
    /// indentation — now reserves the widened rail gutter (`busGutterWidth`), so
    /// every meter/bus row's icon clears the spine with breathing room.
    public static func firstElementLeading(indented: Bool) -> CGFloat {
        (indented ? indentedLeadingInset : leadingInset) + busGutterWidth
    }

    // MARK: Under-name level meter (Warm Signal v4 §Call-1 — meter relocation)
    //
    // The live-level bar moves out of the leading column into the identity
    // cluster, UNDER the device name: a SHORT horizontal bar (spec: "~74 pt
    // wide, 3 pt tall"), left-aligned, row order name / meter / sublabel. It is
    // shown only on armed + unmuted + connected rows (the row gates it). Killing
    // the "two gold bars" confusion (§Call-1): the fader is the only OTHER gold
    // bar, and it lives in the slider column with a thumb — the meter is thin,
    // thumb-less, and in the name cluster.

    /// Width of the under-name live-level meter bar (spec ~74 pt).
    public static let meterUnderNameWidth: CGFloat = 74
    /// Height of the under-name live-level meter bar (spec ~3 pt).
    public static let meterUnderNameHeight: CGFloat = 3

    // MARK: Master strip — the Main Audio meter (Warm Signal v4.1 item 1)
    //
    // The Main Audio row's meter is the terminus the left rail plugs into: same
    // LENGTH as the device meters (`meterUnderNameWidth`, unchanged) but a
    // heavier THICKNESS — thickness alone signifies "master bus," so it still
    // reads as a gauge-sibling of the device meters, not a different species.
    // UNUSED until the master-strip task wires it.

    /// Thickness of the Main Audio master meter bar (spec ~6 pt, vs the device
    /// meters' `meterUnderNameHeight` 3 pt). Length stays `meterUnderNameWidth`.
    /// The meter itself now sits UNDER THE "Main Audio" NAME, exactly where a
    /// device meter sits under its device name (Warm Signal v4.1 CORRECTIONS,
    /// item 1) — thickness alone still signifies "master bus."
    public static let masterMeterThickness: CGFloat = 6
    /// Diameter of the small filled dot marking the rail's ORIGIN at the Main
    /// Audio row's left gutter (Warm Signal v4.1 CORRECTIONS, item 2). The
    /// meter moved under the name and no longer sits in the gutter, so this is
    /// a clean origin point, never a junction fused into the meter.
    /// SUPERSEDED (Warm Signal nitpicks — "rail into the ring"): the rail now
    /// curves up and terminates directly on the Main Audio ring instead of a
    /// bare gutter dot, so this constant is unused in that terminus's drawing;
    /// kept only in case a future non-connecting state needs a bare origin mark.
    public static let busOriginDotDiameter: CGFloat = 5

    // MARK: Main Audio ring — rail terminus (Warm Signal nitpicks)
    //
    // Alec, reviewing the rail-into-ring mock: the Main Audio ring is the
    // rail's TERMINUS, not a peer of the device rows' connection rings — it
    // gets its OWN size/weight (his call, "bespoke since its origin/master"),
    // tuned so the rail's `busLineWidth` stroke and the ring's stroke read as
    // one continuous line where the rail curves into it, matching the
    // `warm-signal-nitpicks` mock's `ringLeftX`/`mr` geometry.

    /// Diameter of the Main Audio ring's visible circle (stroke centerline).
    /// Deliberately its OWN constant, not `haloRingDiameter` — grown slightly
    /// past the device-row ring so the heavier matched stroke doesn't read
    /// cramped against the icon glyph.
    public static let mainAudioRingDiameter: CGFloat = 30
    /// Stroke width of the Main Audio ring while connected — set equal to
    /// `busLineWidth` (the rail's own stroke) so the rail and ring read as ONE
    /// continuous line at their join, not two different-weight strokes
    /// touching. Only the CONNECTED form uses this; connecting/failed keep the
    /// shared `haloRingConnectingStroke`/`haloRingFailedStroke` weights (the
    /// rail's tone already matches those states via `segColor`, and neither
    /// state is the "one continuous line" case this override exists for).
    public static var mainAudioRingConnectedStroke: CGFloat { busLineWidth }
    /// Extra headroom (mirrors `haloBreathingRoomGap`) added to the Main Audio
    /// ring's own host box past `iconWidth`, so the larger `mainAudioRingDiameter`
    /// ring plus its heavier matched stroke has drawing room without crowding
    /// the row's other controls.
    public static let mainAudioRingHostBoxGap: CGFloat = 6
    /// The Main Audio ring's host square diameter once breathing room is
    /// applied — mirrors `haloRingHostBoxDiameter`'s derivation but off the
    /// bespoke `mainAudioRingDiameter`/`mainAudioRingHostBoxGap`.
    public static var mainAudioRingHostBoxDiameter: CGFloat {
        iconWidth + mainAudioRingHostBoxGap * 2
    }
    /// How far the rail's hook-curve bulges LEFT of the ring's own left edge
    /// before curving back in to the gutter column — the "pull away, then
    /// hook back" shape from the `warm-signal-nitpicks` mock's cubic bezier
    /// (`ringLeftX - 10`), so the join reads as a deliberate curve rather than
    /// a straight diagonal jog.
    public static let railRingHookBulge: CGFloat = 10
    /// Vertical drop (from the ring's own center-Y) where the hook-curve's
    /// second control point sits — mirrors the mock's `ringCY + 6`.
    public static let railRingHookControlDrop: CGFloat = 6
    /// Vertical drop (from the ring's own center-Y) where the hook-curve lands
    /// on the gutter column and the ordinary straight rail begins — mirrors
    /// the mock's `ringCY + 16`.
    public static let railRingHookLandingDrop: CGFloat = 16

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
    /// The FEED column's available text width (Warm Signal v4.1 item 3) — the
    /// same physical slot as `trailingControlWidth` (the reserved-but-empty
    /// trailing column on a bus row, since the membership control moved to the
    /// left rail gutter), pulled in slightly so the composite text never
    /// visually touches the row's trailing inset. Drives `DeviceRowView`'s
    /// STATIC "+N" overflow measurement.
    public static let feedColumnWidth: CGFloat = trailingControlWidth - 4

    /// The FEED composite's derived-colour app CHIP (Warm Signal v4.1
    /// CORRECTIONS "FEED needs the colour chip, not just tinted text") — a
    /// small square swatch in `AppTetherColor`'s tone, prefixed onto a
    /// redirected app's name segment. The SAME chip (same size/radius) marks
    /// that app's name in the App Exceptions row so the tether reads at both
    /// ends. Edge length only — never the state-carrying halo ring or meter
    /// (house rule: tether colour lives on FEED/redirect app-name text only).
    public static let feedChipSize: CGFloat = 5
    /// Visual gap between a chip and the app-name text that follows it, baked
    /// into the chip's own attachment width (no separate space glyph) so
    /// stripping the attachment character back out of `attributedStringValue`
    /// never leaves a stray leading space in a test's plain-text read. Kept
    /// tight — the FEED column's `feedColumnWidth` is unchanged by this
    /// task, so a multi-segment composite's existing STATIC "+N" overflow
    /// threshold must not shift just because a chip was added to it (a
    /// two-chip composite like "System · Music · Safari" measured ~119pt of
    /// ~136pt available before chips; each chip's `feedChipSize + feedChipGap`
    /// eats straight into that ~17pt margin).
    public static let feedChipGap: CGFloat = 2
    /// Corner radius of the chip's rounded square — a soft chip, not a bare
    /// square or a full pill (spec reference `v41-fixes.html` `.feed .chip`).
    /// Proportionally small relative to `feedChipSize` (unlike the
    /// reference's 9px/2px ratio) so the chip still reads as a SQUARE at the
    /// compact size the FEED column's tight width budget forces it to.
    public static let feedChipCornerRadius: CGFloat = 1

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
    // in one place. The visible ring circle is `haloRingDiameter` (26 pt, Warm
    // Signal v4.1 item 2), drawn centered in the grown `haloRingHostBoxDiameter`
    // (34 pt) host box rather than the 26 pt `iconWidth` icon box — the host
    // box only gives the ring (and its dashes/glow) drawing headroom past the
    // icon's own frame, it does not itself create the gap (a `CGPath` circle's
    // position/size comes from `haloRingDiameter` alone, independent of the
    // view's own bounds). The gap a viewer sees is against the rendered SF
    // Symbol glyph (which sits inset within the 26 pt icon box, not filling
    // it), and was tuned by rendering + eyeballing per the spec's ~3–4 pt
    // target, landing this constant at 26 pt (up from the original 21 pt,
    // which hugged the glyph at ~1.5–2.5 pt). `haloRingDiameter` is also the
    // size the ≥3:1 `ringConnected` contrast floor is tested at (spec §3.2).
    // The breathing pulse REUSES the `statusDotBreath*` timing constants above
    // (spec §6: "breathing pulse (`statusDotBreathDuration` timing)").

    /// Diameter of the visible connection-ring circle (the stroke centerline).
    /// Warm Signal v4.1 item 2 grew this from the original 21 pt (which hugged
    /// the rendered icon glyph at ~1.5–2.5 pt) to 26 pt, tuned by rendering the
    /// popover-snapshot connection-states fixture and measuring the gap: ~3–4 pt
    /// top/bottom, a little more at the glyph's narrower left/right extent
    /// (icon art varies by device kind, so the gap isn't perfectly uniform by
    /// angle — the ring itself is a uniform circle centered on the icon).
    /// Paired with `haloRingHostBoxDiameter` as the ring's own host box (see
    /// below) so the enlarged ring isn't cramped against the row's other
    /// controls. The contrast floor is tested at this size (spec §3.2).
    public static let haloRingDiameter: CGFloat = 26
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

    /// Extra headroom (Warm Signal v4.1 item 2) added to the halo ring's own
    /// host box past `iconWidth`, on each side, so the enlarged
    /// `haloRingDiameter` (26 pt) ring has drawing room without being cramped
    /// against the row's other controls. Wiring `haloRingHostBoxDiameter` as
    /// the ring's own host box (in place of `iconWidth`) in `DeviceRowView`
    /// and `MainOutRowView`, still centered on the icon, keeps the icon
    /// glyph's own size/position untouched — the halo is purely an overlay,
    /// so only its own box grows.
    public static let haloBreathingRoomGap: CGFloat = 4
    /// The ring's host square diameter once breathing room is applied —
    /// `iconWidth` grown by `haloBreathingRoomGap` on each side. The ring
    /// itself (`haloRingDiameter`) is sized/centered within this larger box
    /// by the consuming task, not by widening `haloRingDiameter` itself.
    public static var haloRingHostBoxDiameter: CGFloat { iconWidth + haloBreathingRoomGap * 2 }

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

    // MARK: Membership bus — the LEFT SPINE (Warm Signal v4 §Call-1)
    //
    // The "bus" is the membership CHECKBOX's DRAWING (spec §4.8: only the drawing
    // moves, the real `NSButton` checkbox stays the control): a filled gold node
    // for a member and a hollow node the line DETOURS around for a non-member.
    // Warm Signal v4 relocates the whole spine from the TRAILING column to the
    // **LEFT gutter** (`railGutterCenterX`, the leading spine), grows the detour
    // arc (skipped nodes get generous berth), and terminates the rail at the
    // LOWEST SELECTED node — rows below it get bare hollow nodes with no rail.
    // Geometry lives here (a future density setting swaps it in one place).
    //
    // COLUMN X: every node sits at exactly `railGutterCenterX` from the row's
    // LEADING edge; toggling changes only FILL and LINE PATH, never position
    // (zero layout shift — R7). The checkbox is re-anchored to this same x so a
    // left-gutter node click still toggles it.

    /// The rail's centreline, measured from the row's LEADING (left) content edge
    /// (spec v4 §Call-1 "≈ 18–20 pt from the popover's left content edge"). Sits
    /// inside the (now widened) leading gutter, LEFT of the icon column, so the
    /// node clears the glyph with `busNodeClearance` of padding.
    public static let railGutterCenterX: CGFloat = 20
    /// Diameter of a bus node (spec §4.1 "~13 pt, matching the `.switch` box").
    public static let busNodeDiameter: CGFloat = 13
    /// Diameter of a SELECTED (on-spine — member/connecting/pending/failed) bus
    /// node, size joining fill as a selection signal (Warm Signal v4.1
    /// CORRECTIONS, item 3 — "selected is bigger," not "others are smaller"):
    /// grown PAST the old 13 pt baseline so selection reads as emphasis. Wired
    /// into `MembershipBusView.nodeRadius(for:)`, which both the node's own
    /// drawing and `BusRailOverlayView`'s gap/arc math read, so rail geometry
    /// always meets the node's true drawn edge.
    public static let busNodeDiameterSelected: CGFloat = 15
    /// Diameter of an UNSELECTED (hollow non-member) bus node — visibly
    /// smaller than `busNodeDiameterSelected` so selection reads via size AND
    /// fill, not fill alone. Raised from 9.5 (Warm Signal v4.1 CORRECTIONS,
    /// item 3 — it read too weak at the old value once selected nodes grew).
    public static let busNodeDiameterUnselected: CGFloat = 11
    /// Stroke width of the bus line (spec §4.1 "~2 pt").
    public static let busLineWidth: CGFloat = 2
    /// Stroke width of the rim ringing a filled node / edging a hollow one.
    public static let busNodeRimWidth: CGFloat = 1.5
    /// The unstroked VERTICAL gap between a node's edge and where the rail line
    /// stops/resumes above and below it (Alec's clearance refinement) — the rail
    /// "meets" a node with breathing room instead of jamming into it, so
    /// consecutive nodes read airy. Applied to the straight through-rail (member /
    /// connecting / pending / failed nodes, which sit ON the spine).
    public static let busNodeRailGap: CGFloat = 3
    /// How far past the node radius the hop-arc bows when the line detours a
    /// HOLLOW non-member node. Warm Signal v4 GREW this (4.5 → 6.5) so a skipped
    /// node gets generous berth (spec §Call-1 "a wider, rounder bypass arc than
    /// v3"). The detour semicircle's radius is `busNodeDiameter/2 + busDetourBulge`;
    /// it bows to the LEADING (panel-edge) side, away from the icon column.
    public static let busDetourBulge: CGFloat = 6.5
    /// Width of the non-interactive bus-overlay column view a row hosts, centered
    /// on `railGutterCenterX`. Wide enough to contain the leading-side hop-arc
    /// (`busNodeDiameter/2 + busDetourBulge` from centre) plus the line width,
    /// without clipping. Spans the full row height so stacked rows' rail segments
    /// read as one continuous line.
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

    // MARK: Warm fader skin (spec §5 slider track/knob look)
    //
    // Geometry for `WarmFaderCell`, the drawing-only skin over the row volume
    // sliders (`DeviceRowView` / `MainOutRowView` / `AppRowView`). Named here
    // per house rule (and the future density setting) even though only the
    // cell reads them.

    /// Height of the recessed fader trough (the flat `well` track). Raised
    /// 4 → 5 pt in the fader-legibility pass (2026-07-22) so the armed
    /// gradient's dim end and the unarmed fill read at a glance — the 4 pt
    /// line was part of why the fader sank into the warm canvas.
    public static let faderTrackHeight: CGFloat = 5
    /// Corner radius of the fader trough (fully rounds the 5 pt track ends).
    public static let faderTrackCornerRadius: CGFloat = 2.5
    /// Width of the rounded-rect fader thumb (replaces the stock circle).
    /// Grown 9×15 → 10×17 in the fader-legibility pass so the handle reads
    /// as a grabbable object at arm's length (alongside the `faderThumb`
    /// token's ≥3:1 fill).
    public static let faderThumbWidth: CGFloat = 10
    /// Height of the rounded-rect fader thumb.
    public static let faderThumbHeight: CGFloat = 17
    /// Corner radius of the fader thumb.
    public static let faderThumbCornerRadius: CGFloat = 4
    /// Alpha the fader's interior drawing (fill/rim/thumb) dims to while the
    /// slider is disabled — matches `selectionDimmedAlpha`'s dim-not-hide idiom.
    public static let faderDisabledAlpha: CGFloat = 0.4

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
