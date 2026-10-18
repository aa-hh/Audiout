// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The Groups window's CONTENT-PANE grid — the numbers
/// `GroupEditorViewController` and `DeviceDetailViewController` must agree on
/// for the two panes to be interchangeable behind one sidebar.
///
/// **HEADER PARITY IS GEOMETRIC, NOT DECORATIVE.** Switching the sidebar
/// selection between a group and a device swaps the whole content pane; if the
/// header band is a different height, or the name block sits off the icon's
/// centre line, the swap reads as the window twitching. The two panes used to
/// carry hand-copied literals and drifted ~22.5 pt apart (design review
/// 2026-07-25). Every shared number now lives HERE, once, and
/// `GroupsHeaderParityTests` asserts the panes' real laid-out frames still
/// share the band height and the vertical centring. Every page starts its
/// icon at `railFreeContentLeadingInset`, lined up with its headings.
///
/// What is deliberately NOT shared: the SKIN. A group's title is an editable
/// field (filled, bordered, pencil); a device's is a bare label. That
/// difference is the message — see the edit-affordance vocabulary in
/// `AGENTS.md`.
public enum GroupsPaneLayout {

    /// Outer margin from the content pane's leading edge to the form column.
    /// SYMMETRIC with `columnTrailingInset`: the column used to start at the
    /// pane's own edge (the whole margin lived inside `contentLeadingInset`),
    /// which put the bordered sections flush against the window edge on the
    /// left and 16 pt short of it on the right.
    public static let columnInset: CGFloat = PopoverColumnGrid.leadingInset
    /// Outer margin from the form column to the content pane's trailing edge.
    public static let columnTrailingInset: CGFloat = PopoverColumnGrid.trailingInset

    /// Gap from the top of the content pane's SAFE AREA (the window is
    /// `.fullSizeContentView`, so the pane runs under the title bar) to the
    /// header section's top border.
    public static let columnTopInset: CGFloat = 28

    /// Caps the form column's width so the sections don't stretch
    /// edge-to-edge in a very wide window. It is a CAP, not a width: the
    /// column stretches with the pane until it hits this (see
    /// `GroupEditorViewController.loadView`'s high-priority "fill" constraint),
    /// which is what stopped the sections hugging their ~277 pt intrinsic
    /// content and leaving a dead strip to their right.
    ///
    /// **THIS NUMBER SETS THE WHOLE SCREEN'S WIDTH — it is not cosmetic.**
    /// (Probed 2026-08-12 by re-rendering `window-snapshot` at several caps.)
    /// The split view's fitting width is `sidebar + cap + 2 × columnInset`,
    /// so this is DERIVED — never a hand-picked literal — to guarantee that
    /// sum can never exceed the one fixed surface frame:
    /// `SurfaceLayout.contentPaneWidth` (`SurfaceLayout.width` minus
    /// `MixerWindowController`'s pinned sidebar) minus both column margins,
    /// which evaluates to 475. Raise it and the whole screen would ask to
    /// grow past the fixed frame; the sections already fill the pane exactly
    /// here, so there is nothing to gain by doing so.
    public static let contentMaxWidth: CGFloat = SurfaceLayout.contentPaneWidth - columnInset - columnTrailingInset

    /// Where a membership row's glyph starts and the card's dividers begin.
    /// Derived from the popover's grid so the node and glyph spacing agree.
    public static let contentLeadingInset: CGFloat = PopoverColumnGrid.firstElementLeading(indented: false)

    /// Where every page starts its header icon, headings and list text.
    public static let railFreeContentLeadingInset: CGFloat = PopoverColumnGrid.leadingInset
    /// Where content STOPS inside a section, measured from the section's
    /// trailing edge.
    public static let contentTrailingInset: CGFloat = PopoverColumnGrid.trailingInset
    /// The width a note on a rail-free page wraps against: the column cap
    /// minus the content lane's two insets.
    public static let railFreeContentWidth: CGFloat =
        contentMaxWidth - railFreeContentLeadingInset - contentTrailingInset

    /// Inset from the header section's top/bottom borders to the icon well.
    public static let headerPadding: CGFloat = 16
    /// Gap between the icon well and the title beside it.
    public static let iconToTitleGap: CGFloat = 12

    // MARK: The vertical cadence (4 pt base)
    //
    // One rhythm for both panes, tighter WITHIN a group of things than
    // BETWEEN them, so the eye gets the grouping for free: 6 pt inside a
    // section (`GroupedSectionView.verticalPadding`), 20 pt between sections,
    // 22 pt down to the pane's action band. The numbers below are what is
    // VISIBLE on screen; a constraint that pins a section's row STACK rather
    // than its border adds `GroupedSectionView.verticalPadding` on top (the
    // call sites do that explicitly, so the visible value stays readable
    // here).

    /// Visible gap between one section's bottom border and whatever starts the
    /// next block — the following section's top border, or the label titling it.
    public static let sectionGap: CGFloat = 20
    /// Visible gap from a label that TITLES a section ("Speakers") down to that
    /// section's top border. Deliberately far tighter than ``sectionGap``: the
    /// label belongs to the section under it, not to the one above.
    public static let labelToSectionGap: CGFloat = 6
    /// Visible gap from the last section to the pane's ACTION BAND — the
    /// editor's "Delete scene…" + reassurance line, the detail pane's hint.
    /// Wider than ``sectionGap`` so the band reads as leaving the form rather
    /// than as one more section of it.
    public static let actionBandGap: CGFloat = 22
    /// Gap from the action band to the pane's own bottom edge.
    public static let paneBottomInset: CGFloat = 20

    /// Inset between a `.card` section's edge and the instrument inside it —
    /// a scope against a 6 pt edge reads as jammed; 14 matches
    /// `PopoverColumnGrid.leadingInset` / the column margins.
    public static let cardContentInset: CGFloat = 14

    /// The header band's height. SIDE-BY-SIDE (design review 2026-07-25): the
    /// icon and the name share one horizontal band rather than stacking, which
    /// reclaimed 30 pt of a pane that had been overflowing its own window.
    /// Derived from the icon well it wraps, so growing the well grows the band.
    public static var headerBandHeight: CGFloat {
        headerPadding + DeviceIconWellView.size + headerPadding
    }
}
