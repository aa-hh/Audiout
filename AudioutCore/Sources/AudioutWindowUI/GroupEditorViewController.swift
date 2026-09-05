// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The group editor pane (design revamp: the Groups window is
/// CONFIGURATION-ONLY — renaming, membership, and "Delete scene…" live here,
/// but activation/routing never do; that stays in the popover only). This is
/// the absorbed T-U3: the in-menu editable field is impossible (menu item
/// views get no keyboard events — `dev/notes/p1-menu-brief.md` §3), so a real
/// `NSTextField` works fine HERE, in a normal window.
///
/// EDIT-ONLY: this view controller never creates a group. Creation moved to a
/// standard macOS sheet (a parallel task); this editor only ever shows an
/// already-persisted group.
///
/// Layout, top to bottom (HEADER PARITY with `DeviceDetailViewController` —
/// design feedback 2026-07-18: groups and devices share the identical
/// large-icon header, the only difference being that a group's TITLE is
/// editable and a device's is not; every shared number lives in
/// ``GroupsPaneLayout``):
/// - a HEADER SECTION holding the large (``DeviceIconWellView/size``pt) group
///   icon and the group's name SIDE BY SIDE (design review 2026-07-25 — they
///   used to stack, which cost 30 pt of a pane that was overflowing its own
///   window); clicking the icon opens the icon picker. The well carries
///   ``GroupIdentityGlowView`` behind it, the same magenta light this group's
///   overview card shows;
/// - the name itself is an inline rename field: a real `NSTextField` wearing
///   the ``WarmNameFieldCell`` skin (filled, bordered, trailing pencil), which
///   commits on Return/focus loss, reverts on Escape, and restores the previous
///   name when emptied — a Finder rename in a box;
/// - a "Speakers" list of `MembershipRowView` rows, one per candidate device
///   (per HIG — checkboxes for membership, not switches), in a second section;
/// - a "Delete scene…" `NSButton`, with the line that says edits save
///   themselves beside it.
///
/// The two controls that LEAVE the pane share one band above all of that: the
/// quiet "‹ Groups" button on the left and the primary Done/Save on the right.
///
/// Edits write straight through the injected `GroupController`
/// (`saveGroup`/`deleteGroup`): renaming and membership toggles call
/// `saveGroup`; the delete button calls `deleteGroup`. The parent window is
/// notified via `onDidEditGroup` / `onDidDeleteGroup` so it can refresh the
/// sidebar labels + toolbar presets.
///
/// The header icon shows `group.iconSymbolName` (resolved through
/// `DeviceIcon.resolve`, so a stale override still renders the default rather
/// than a blank glyph). Picking a symbol (or "use default") persists instantly
/// through `saveGroup`, exactly like a rename — this window never gates a
/// group edit behind a separate "Save" step. The primary button says so: it
/// reads "Done" until the name field holds text that has not been committed
/// yet, which is the pane's ONE uncommitted state.
public final class GroupEditorViewController: NSViewController {

    /// The continuous membership-rail spine, drawn ONCE for the whole pane on
    /// top of everything else so it reads unbroken where it crosses the header
    /// band and the "Speakers" label's row. Non-interactive.
    ///
    /// ANCHORING TRAP: its leading edge is pinned to the COLUMN's, and the
    /// membership rows' leading edges are pinned there too — that alignment is
    /// load-bearing: `BusRailOverlayView` draws the spine at the literal
    /// `PopoverColumnGrid.railGutterCenterX` in its own coordinate space, while
    /// each row places its node at that same x from the ROW's leading edge. Move
    /// one without the other and the nodes float off the line by exactly the
    /// difference (`test_nodeCenterXInOverlaySpace` is the guard).
    private let railOverlay = BusRailOverlayView()

    private let groupController: GroupController

    /// Resolves/persists per-device icon overrides for `MembershipRowView`
    /// rows. Optional and nil-tolerant (`../../AGENTS.md`'s "depends on the
    /// model, never the reverse" — a host without one still renders default
    /// device glyphs, just no per-device overrides).
    public var deviceIconController: DeviceIconController?

    /// Called after a rename or membership change persisted (refresh sidebar +
    /// toolbar labels in place).
    public var onDidEditGroup: (() -> Void)?
    /// Called after the group was deleted (pop back to the mixer).
    public var onDidDeleteGroup: (() -> Void)?
    /// Called when the user leaves this editor for the group overview — the
    /// "‹ Groups" band, Escape, or ⌘[. The host owns the pane swap; this pane
    /// only reports the request (direction C's in-pane push).
    public var onBack: (() -> Void)?
    /// Called when Escape abandoned a rename, so the host can put keyboard
    /// focus somewhere real (the sidebar's outline view) instead of leaving
    /// the window as its own first responder — see ``cancelRename()``. Escape
    /// while renaming stops HERE (the field editor consumes it); only an
    /// Escape outside a rename reaches the container and fires `onBack`.
    public var onDidCancelRename: (() -> Void)?

    /// The group currently being edited, nil before `show`.
    public private(set) var editingGroupID: String?

    /// Whether the edited group is the active Main Out group. Gold means LIVE
    /// everywhere in Audiout, so an inactive group's editor renders its whole
    /// spine — hook, wire, AND member discs — in the quiet `ember` idle tone.
    ///
    /// The hook and wire follow THIS flag (`railHookAnchor`). The member discs
    /// go one step further and follow the ROUTED truth PER ROW
    /// (``railArmed(for:memberSet:isActiveGroup:)``): saving a speaker into
    /// the active group does not start sending to it, so a row that is checked
    /// but not in the backend's output set fills ember, not gold.
    private var isActiveGroup = false

    /// The "‹ Groups" control at the top of the scrolled document — the way
    /// back to the card overview this editor was pushed from. It rides on the
    /// scroll view roadmap 039 gave the pane: before that there was not a
    /// single spare point of height to put it in.
    ///
    /// A stock `NSButton` the same height as the primary beside it, so the two
    /// read as a matched secondary/primary pair on one band (owner's call,
    /// 2026-09-03). The quiet `.accessoryBar` bezel is what keeps it SECONDARY
    /// next to the primary's `.rounded` one; being a real control, the focus
    /// ring, Space, the pressed state and `accessibilityPerformPress()` are
    /// AppKit's.
    private let backButton = BackButton()
    private let iconWell = DeviceIconWellView()
    /// The group's identity light, mounted behind the well.
    private let iconGlow = GroupIdentityGlowView()
    private let nameField = NSTextField(string: "")
    private let membershipStack = RailRepaintingStackView()
    /// THIS PAGE'S ONE INSTRUMENT, so it is the one `.card` here — a `raised`
    /// fill with a `containerEdge` edge behind the Speakers checklist, plus
    /// the inter-row rules in the same tone. Sits BEHIND `membershipStack` in
    /// z-order.
    /// NAME IS LOAD-BEARING: `GroupsInkTemperatureTests` reaches this stored
    /// property by reflection (the type is internal, the property is private)
    /// to sample the real drawn fill/divider colours.
    private let membershipWell = GroupedSectionView()
    /// The header BAND — `.bare`, so it draws nothing at all (identity is not
    /// an instrument). Kept as a section purely for its GEOMETRY: the rail
    /// climbs out of the list and lands on the icon well inside this band, and
    /// `test_headerSectionFrame` / the badge anchors measure its frame.
    private let headerWell = GroupedSectionView()
    private let deleteButton = NSButton()
    /// The pane's PRIMARY action, at the TOP RIGHT of the form, level with the
    /// "‹ Groups" control it pairs with (owner's call, 2026-09-03). It carries
    /// two titles: "Done" whenever the editor holds nothing uncommitted —
    /// which is almost always, since membership, the icon and a committed
    /// rename each write through immediately — and "Save" while the name field
    /// holds text that has not been committed yet (``hasPendingRename``).
    /// Pressing it on "Save" commits that rename first and then leaves,
    /// exactly as Done does, so no typed name is ever abandoned. No Return key
    /// equivalent — Return belongs to the rename field.
    private let doneButton = NSButton()

    /// The pane's scroll view (roadmap 039) — see the note in ``loadView()``.
    /// Held so the `test_*` seams can measure the document without walking the
    /// view tree.
    private var scrollView: NSScrollView?

    /// The header's "Playing" marker, shown ONLY while the edited group is
    /// the active Main Out — the SAME glyph + wording the sidebar's
    /// `IconLabelCellView` already uses, so one state has one name. It lives
    /// UNDER the rename field, inside the header band: the band's height is
    /// pinned to the icon well (`GroupsHeaderParityTests`), so nothing here may
    /// grow it, and the trailing space beside the field belongs to a name that
    /// can be long.
    ///
    /// HIDDEN AT DECLARATION, never in `loadView`: `showEditor(for:)` calls
    /// ``show(groupID:devices:)`` BEFORE this controller's view is first
    /// embedded, so `loadView` can run afterwards and would wipe the state
    /// `show` just decided (the same ordering trap `WarmNameFieldCell`'s swap
    /// carries below).
    private let playingBadge: NSStackView = {
        let stack = NSStackView()
        stack.isHidden = true
        return stack
    }()

    /// The line that says edits are saved as they are made — nothing on this
    /// pane waits for a button. Every group's editor shows it; an ACTIVE
    /// group's, where "Playing" is on screen while membership is being
    /// edited, adds that nothing playing changes (``show(groupID:devices:)``).
    ///
    /// HEIGHT BUDGET: it sits BESIDE "Delete scene…", centred on it, with no
    /// bottom pin, so it rides inside the button's existing bottom margin and
    /// costs the pane ZERO fitting height. At a seven-device fleet the pane has
    /// no spare points at all — a new band above the button would overflow it
    /// (`MembershipRailTests`).
    ///
    /// Configured at declaration for the same `loadView`-after-`show`
    /// ordering reason as ``playingBadge``.
    private let reassuranceLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: GroupEditorViewController.savedAsYouGo)
        label.font = Tokens.Font.caption
        // `Tokens.Color.label2`: text colours are frozen in this pane
        // (`AGENTS.md`) — the gold in this pair tints the badge's GLYPH only.
        label.textColor = Tokens.Color.label2
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        // It WRAPS into whatever the button leaves rather than pushing the
        // button's own required geometry around.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    /// Floor for the rename field's width. An editable `NSTextField` has NO
    /// intrinsic width, so without this a field whose width is otherwise driven
    /// by its (measured) content can be squeezed to nothing — it rendered
    /// invisible once already (snapshot-caught 2026-07-18). REQUIRED priority,
    /// deliberately: the field may overflow its section by a hair on a
    /// pathologically narrow pane rather than vanish.
    /// The identity glow's mounted side. A 60 pt glow would sit wholly under
    /// the 64 pt opaque well and never be seen, so it is the well plus 16: 40
    /// pt of radius, 8 pt of magenta leaking past the well's edge.
    static let iconGlowSide: CGFloat = DeviceIconWellView.size + 16

    private static let titleFieldMinWidth: CGFloat = 140

    private static let savedAsYouGo = "Changes are saved as you go."
    private static let savedAsYouGoActive =
        "Changes are saved as you go. They don\u{2019}t change what\u{2019}s playing now."

    /// The primary's resting title. Every edit on this pane autosaves, so
    /// there is normally nothing outstanding to save and the button only has
    /// to say how to leave.
    private static let doneTitle = "Done"
    /// …and the title it takes while the name field holds an uncommitted
    /// rename, which is the ONE thing on this pane that is not saved yet.
    private static let saveTitle = "Save"

    /// The top action band's inset from the document's top. The band holds the
    /// two controls that leave this pane, and it needs its own margin from the
    /// toolbar chrome above it (owner's call, 2026-09-03) while still clearing
    /// the icon well below by at least `topBandControlGap`-worth of room —
    /// the back button overlaps the icon well horizontally, so if the band
    /// drops low enough the icon tile draws on top of it. There is no room to
    /// buy that clearance from this constant alone: raising `topBandTopInset`
    /// on its own eats straight into the gap and lands the tile on the button.
    /// So this constant and `GroupsPaneLayout.columnTopInset` move TOGETHER,
    /// by the same amount, whenever the band's margin changes — that keeps the
    /// 8 pt of clearance below the band constant while giving the band more
    /// air above it. HEADER PARITY IS GEOMETRIC (`GroupsHeaderParityTests`
    /// asserts the two panes' real laid-out title frames), so the column must
    /// not move relative to the device detail pane's — moving both constants
    /// together keeps the column pinned to the shared `columnTopInset`, it
    /// just shifts that shared value too.
    private static let topBandTopInset: CGFloat = 12
    /// Smallest gap between the two controls on that band before the back
    /// control has to give way.
    private static let topBandControlGap: CGFloat = 8

    /// The rename field's live width, recomputed from the name it holds
    /// (an editable field has no intrinsic width to hug with, so the hug is
    /// measured by hand). Optional, not required, so the "never wider than its
    /// section" cap wins for a long name and the min-width floor wins for a
    /// short one.
    private var nameFieldWidth: NSLayoutConstraint?

    /// The pointer-hover tracking area over the rename field. The field itself
    /// stays a STOCK `NSTextField` (the skin is a cell — `WarmNameFieldCell`),
    /// so the tracking area is owned here rather than by an `NSTextField`
    /// subclass; `mouseEntered`/`mouseExited` below are its callbacks.
    private var nameFieldTracking: NSTrackingArea?

    /// Kept alive across a picker session so it can be dismissed/replaced;
    /// nil when no picker is currently presented.
    private var iconPickerPopover: NSPopover?

    /// The symbol name last resolved into the icon well's image (mirrors
    /// `iconWellButton.image`, but as the plain string a test can assert
    /// against without relying on `NSImage`'s internal name-tracking).
    private var iconWellSymbolName: String?

    /// Membership rows keyed by device id, so a test can read/drive them.
    private var rowsByID: [String: MembershipRowView] = [:]
    /// The devices currently offered as membership candidates, in order
    /// (available devices, plus unavailable devices only while they remain
    /// members of this group — see ``rebuildCandidates(devices:)``).
    private var candidateDevices: [Device] = []
    /// The full device set last passed to `show`, so membership toggles can
    /// rebuild the candidate list (an unchecked unavailable device drops out).
    private var allDevices: [Device] = []

    public init(groupController: GroupController) {
        self.groupController = groupController
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        iconWell.translatesAutoresizingMaskIntoConstraints = false
        // This pane's well is where the membership rail's origin hook lands, so
        // it wears the ring (gold when active, ember when idle) that the spine
        // terminates into. The device detail pane's well is NOT a rail origin
        // and keeps its neutral resting edge.
        iconWell.isRailOrigin = true
        iconWell.widthAnchor.constraint(equalToConstant: DeviceIconWellView.size).isActive = true
        iconWell.heightAnchor.constraint(equalToConstant: DeviceIconWellView.size).isActive = true
        iconWell.setAccessibilityLabel("Edit scene icon")
        iconWell.onClick = { [weak self] in
            guard let self else { return }
            self.presentIconPicker(anchoredTo: self.iconWell)
        }

        // The inline rename field. STILL A REAL `NSTextField` — first
        // responder, field editor, Return/Escape, selection and VoiceOver all
        // stock; only the DRAWING is ours. The cell swap happens FIRST, before
        // any configuration, so the settings below land on the new cell (the
        // same ordering `MembershipRowView` uses for `InvisibleSwitchCell` and
        // `DeviceRowView` for `WarmFaderCell`).
        // `textCell:`, NOT the bare zero-arg initializer: a plain
        // `WarmNameFieldCell()` defaults its `stringValue` to AppKit's own
        // `NSCell` placeholder ("Field") — invisible as long as `loadView()`
        // runs before `show()` ever sets a real name, but `showEditor(for:)`
        // calls `show()` BEFORE `swapContent(to:)` embeds this controller's
        // view for the first time, so `loadView()` (and this cell swap) can
        // run AFTER `show()` already wrote the group's real name — silently
        // discarding it back to the AppKit default (caught 2026-07-26: every
        // rename-field test that compared against the LITERAL name passed
        // fine on its own, but the two that hardcoded "Downstairs" exposed
        // the mismatch). Carrying the field's current text into the new cell
        // makes the swap correct regardless of which runs first.
        nameField.cell = WarmNameFieldCell(textCell: nameField.stringValue)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = "Scene name"
        nameField.font = Tokens.Font.heading
        nameField.textColor = Tokens.Color.label
        nameField.alignment = .natural   // left-aligned (LTR) to match the column
        nameField.isEditable = true
        nameField.isSelectable = true
        // Bezel-less/background-less: `WarmNameFieldCell` paints the fill and
        // border itself so both re-resolve per appearance on every paint
        // (a bezel would also draw its text visibly off-centre — live-test
        // feedback 2026-07-18).
        nameField.isBordered = false
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.usesSingleLineMode = true
        nameField.lineBreakMode = .byTruncatingTail
        nameField.setAccessibilityLabel("Scene name")
        nameField.target = self
        nameField.action = #selector(nameCommitted(_:))
        nameField.delegate = self
        // Hover is a neutral wash + a pencil step-up, never a geometry change
        // (R7). Owned here because the field is stock — see `nameFieldTracking`.
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                      owner: self, userInfo: nil)
        nameField.addTrackingArea(tracking)
        nameFieldTracking = tracking

        buildPlayingBadge()
        reassuranceLabel.translatesAutoresizingMaskIntoConstraints = false

        let speakersLabel = NSTextField(labelWithString: "Speakers")
        speakersLabel.translatesAutoresizingMaskIntoConstraints = false
        speakersLabel.textColor = Tokens.Color.label2

        membershipStack.translatesAutoresizingMaskIntoConstraints = false
        membershipStack.orientation = .vertical
        membershipStack.alignment = .leading
        membershipStack.spacing = 6

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.title = "Delete scene…"
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped(_:))
        deleteButton.hasDestructiveAction = true

        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.title = Self.doneTitle
        doneButton.setAccessibilityLabel(Self.doneTitle)
        doneButton.bezelStyle = .rounded
        doneButton.target = self
        doneButton.action = #selector(doneTapped(_:))

        // A host that re-invalidates the rail on every layout pass, so the spine
        // always reflects the CURRENT row frames (rebuild, resize, pane swap)
        // with no cached geometry.
        //
        // TWO hooks, deliberately, and neither replaces the other (2026-08-06 —
        // the popover's rail drew displaced by exactly the gap between them):
        // the CONTAINER's `layout()` fires on window resize / pane swap but NOT
        // when only descendants re-lay out inside an unchanged container frame
        // (a checklist row growing or a mid-animation reflow); the membership
        // STACK's fires for its own relayouts but — unlike the popover's card
        // stack, which is pinned to its container's four edges and so covers
        // both cases alone — this stack floats inside the elastic form column,
        // so its `layout()` is not guaranteed to run on every container
        // resize. The popover could DELETE its container hook; here both stay.
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.title = "Scenes"
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        backButton.image?.isTemplate = true
        backButton.imagePosition = .imageLeading
        // QUIET, but still a real bezel: `.accessoryBar` draws a light capsule
        // that reads as a control at rest without competing with the primary's
        // `.rounded` push bezel beside it (checked in both appearances).
        backButton.bezelStyle = .accessoryBar
        backButton.target = self
        backButton.action = #selector(backTapped(_:))
        // The button says "Scenes"; VoiceOver says where it goes.
        backButton.setAccessibilityLabel("Back to Scenes")
        // The one place the shortcut is printed: the screen has no menu bar
        // to list it (see `RailRepaintingView.performKeyEquivalent`).
        backButton.toolTip = "Back to Scenes (\u{2318}[)"

        let container = RailRepaintingView()
        container.railOverlay = railOverlay
        container.membershipWell = membershipWell
        // Escape and ⌘[ are the band's keyboard equivalents. Both have to live
        // on a VIEW: key equivalents are dispatched down the view tree, and
        // `cancelOperation` up the responder chain from whatever is focused —
        // an `NSViewController` override would be called by neither.
        container.onBack = { [weak self] in self?.onBack?() }
        membershipStack.railOverlay = railOverlay
        membershipStack.membershipWell = membershipWell
        // The form column: symmetric margins off the pane, ELASTIC up to
        // `GroupsPaneLayout.contentMaxWidth`. Everything hangs off this
        // column's edges rather than the container's, so both sections and the
        // rail move together.
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false

        // Added FIRST so it sits behind every row (T5: a recessed background +
        // hairline dividers behind the checklist, which otherwise carries no
        // surface at all — measured ~1.06:1 dark / ~1.08:1 light against
        // `panel`, an invisible boundary). Non-interactive (`hitTest` always
        // nil), so it never intercepts a row's click.
        // Both sections span the column's full width (rail gutter included), so
        // their dividers inset by the same gutter reserve every child uses.
        for well in [headerWell, membershipWell] {
            well.translatesAutoresizingMaskIntoConstraints = false
            well.contentLeadingInset = GroupsPaneLayout.contentLeadingInset
            column.addSubview(well)
        }
        // Identity is bare; the checklist is the page's one card.
        headerWell.style = .bare
        for v in [iconGlow, iconWell, nameField, playingBadge, speakersLabel, membershipStack] {
            v.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(v)
        }
        // The pane SCROLLS (roadmap 039, `../AGENTS.md`): the surface frame is
        // FIXED, so a fleet the editor cannot fit used to have to be paid for by
        // raising `AppSurfaceController.minimumContentSize`. It now overflows
        // into the scroller instead. Same recipe as `DeviceDetailViewController`
        // — overlay scrollers + no background so the pane still reads as one
        // warm surface, and a FLIPPED document so the form starts at the TOP
        // rather than bottom-gravitating.
        //
        // Everything the container used to host lives in the DOCUMENT now,
        // including the rail overlay, whose anchoring traps below are unchanged
        // — they just read document space rather than container space.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        for v in [backButton, doneButton, column, deleteButton, reassuranceLabel] {
            document.addSubview(v)
        }
        // Added LAST so the spine composites ON TOP of the header and the rows
        // it passes; non-interactive, so nothing beneath it loses a click.
        railOverlay.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(railOverlay)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        container.addSubview(scrollView)
        self.scrollView = scrollView

        // The column STRETCHES with the pane: this pushes it out to the
        // trailing margin, the required `<=` cap stops it at
        // `contentMaxWidth`, and the required `<=` margin keeps it inside the
        // pane at any width. Without this fill the sections hugged their
        // ~277 pt intrinsic content and left a dead strip beside them.
        let columnFill = column.trailingAnchor.constraint(
            equalTo: document.trailingAnchor, constant: -GroupsPaneLayout.columnTrailingInset)
        columnFill.priority = .defaultHigh

        // The rename field HUGS its name — measured by hand, since an editable
        // `NSTextField` has no intrinsic width to hug with (see
        // ``updateNameFieldWidth()``). Optional, so the cap below wins for a
        // long name and the required floor wins for a short one.
        //
        // PRIORITY IS LOAD-BEARING: below `.defaultLow`, which is where the
        // split view holds its divider. At `.defaultHigh` a long group name was
        // satisfied by growing the whole content pane — the split view happily
        // squeezed the sidebar past its own minimum thickness to give the field
        // the width it asked for. A preference this weak can never move the
        // window's furniture; it only fills space the pane already has.
        let titleWidth = nameField.widthAnchor.constraint(
            equalToConstant: Self.titleFieldMinWidth)
        titleWidth.priority = NSLayoutConstraint.Priority(240)
        nameFieldWidth = titleWidth

        // …and never overflows its section. Priority 999 rather than required:
        // on a pathologically narrow pane the REQUIRED min-width floor wins
        // instead of AppKit breaking one of two required constraints at random
        // (and logging about it).
        let titleCap = nameField.trailingAnchor.constraint(
            lessThanOrEqualTo: headerWell.trailingAnchor,
            constant: -GroupsPaneLayout.contentTrailingInset)
        titleCap.priority = NSLayoutConstraint.Priority(999)

        // The reassurance line takes whatever "Delete scene…" leaves of the
        // row, wrapping into it — an EQUALITY, because a wrapping label needs a
        // definite width to wrap inside. 999 rather than required so a
        // pathologically narrow pane breaks THIS rather than the button's own
        // required geometry.
        let reassuranceTrailing = reassuranceLabel.trailingAnchor.constraint(
            equalTo: column.trailingAnchor, constant: -GroupsPaneLayout.contentTrailingInset)
        reassuranceTrailing.priority = NSLayoutConstraint.Priority(999)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // The document is exactly as wide as the pane and as tall as its
            // content needs — vertical scrolling only, never horizontal.
            document.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            // THE TOP ACTION BAND. It tops the DOCUMENT, not the pane's
            // safe-area guide — the clip view already sits below the title-bar
            // chrome, so the document itself is the correct top reference here.
            // It scrolls WITH the form rather than pinning to the clip view:
            // the form is short enough to scroll only on a large fleet, and a
            // floating band would have to solve its own backdrop against the
            // rows passing under it.
            //
            // Both controls hang off the COLUMN's edges, so they line up with
            // the two sections below them rather than with the pane.
            backButton.topAnchor.constraint(equalTo: document.topAnchor,
                                            constant: Self.topBandTopInset),
            backButton.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            // SAME SIZE as the primary (owner's call, 2026-09-03) — read off
            // the primary's own control metrics rather than a copied number,
            // so a future bezel or control-size change moves both together.
            backButton.heightAnchor.constraint(equalTo: doneButton.heightAnchor),
            backButton.trailingAnchor.constraint(lessThanOrEqualTo: doneButton.leadingAnchor,
                                                 constant: -Self.topBandControlGap),

            doneButton.topAnchor.constraint(equalTo: backButton.topAnchor),
            doneButton.trailingAnchor.constraint(equalTo: column.trailingAnchor),

            // The column keeps the SHARED top inset the two detail panes use,
            // independently of the band above it (see `topBandTopInset`).
            column.topAnchor.constraint(equalTo: document.topAnchor,
                                        constant: GroupsPaneLayout.columnTopInset),
            // SYMMETRIC margins (design review 2026-07-25). The column used to
            // start at the pane's own leading edge, with the whole left margin
            // living inside `contentLeadingInset` — which put the bordered
            // sections flush against the window edge on one side only.
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor,
                                            constant: GroupsPaneLayout.columnInset),
            column.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor,
                                             constant: -GroupsPaneLayout.columnTrailingInset),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: GroupsPaneLayout.contentMaxWidth),
            columnFill,

            // HEADER, SIDE BY SIDE (design review 2026-07-25): icon BESIDE the
            // name, not above it — 30 pt of reclaimed height on a pane that was
            // overflowing its own window. Header parity with
            // `DeviceDetailViewController` is geometric: both panes read the
            // same `GroupsPaneLayout` numbers, so switching sidebar selection
            // never shifts the header (it used to jump ~22.5 pt sideways).
            iconWell.topAnchor.constraint(equalTo: column.topAnchor,
                                          constant: GroupsPaneLayout.headerPadding),
            iconWell.leadingAnchor.constraint(equalTo: column.leadingAnchor,
                                              constant: GroupsPaneLayout.contentLeadingInset),

            iconGlow.centerXAnchor.constraint(equalTo: iconWell.centerXAnchor),
            iconGlow.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
            iconGlow.widthAnchor.constraint(equalToConstant: Self.iconGlowSide),
            iconGlow.heightAnchor.constraint(equalToConstant: Self.iconGlowSide),

            nameField.leadingAnchor.constraint(equalTo: iconWell.trailingAnchor,
                                               constant: GroupsPaneLayout.iconToTitleGap),
            nameField.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
            nameField.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.titleFieldHeight),
            // REQUIRED floor: an editable text field has no intrinsic width, so
            // without this auto layout is free to collapse it to zero (it
            // rendered invisible — snapshot-caught 2026-07-18).
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.titleFieldMinWidth),
            titleWidth,
            titleCap,

            // The "Playing" marker tucks UNDER the name, inside the header
            // band's own padding — it hangs off the field, never off the
            // section's bottom, so the band's pinned height can't follow it.
            playingBadge.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            playingBadge.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 4),

            // Sits BETWEEN the two sections, on bare pane — the gap below the
            // header section's bottom border, above the list section's top.
            speakersLabel.topAnchor.constraint(equalTo: headerWell.bottomAnchor,
                                               constant: GroupsPaneLayout.sectionGap),
            speakersLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor,
                                                   constant: GroupsPaneLayout.contentLeadingInset),

            // The header section: wraps the icon + title, padded off both, and
            // spans the column's full width so the rail lands INSIDE it.
            headerWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            headerWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            headerWell.topAnchor.constraint(equalTo: column.topAnchor),
            headerWell.bottomAnchor.constraint(equalTo: iconWell.bottomAnchor,
                                               constant: GroupsPaneLayout.headerPadding),

            // The ROWS, uniquely, start at the column's own leading edge: each
            // row applies `contentLeadingInset` internally to its icon and
            // places its node in the gutter, so row icons still line up with
            // the header content above them. They FILL the section's width
            // (`buildRows` pins each row to the stack) so a row's trailing
            // annotation lands at the section's own inset edge instead of
            // wherever the widest device name happens to end.
            // The container extends `verticalPadding` ABOVE the first row, so
            // the VISIBLE gap from the "Speakers" label to the container's top
            // border is `labelToSectionGap` and this constraint carries the
            // padding on top of it.
            membershipStack.topAnchor.constraint(
                equalTo: speakersLabel.bottomAnchor,
                constant: GroupsPaneLayout.labelToSectionGap + GroupedSectionView.verticalPadding),
            membershipStack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            membershipStack.trailingAnchor.constraint(
                equalTo: column.trailingAnchor, constant: -GroupsPaneLayout.contentTrailingInset),
            membershipStack.bottomAnchor.constraint(equalTo: column.bottomAnchor),

            // The list section. Spans the column's FULL width, gutter included,
            // so the rail's nodes sit inside it (design review 2026-07-25 —
            // holding the spine outside left it reading as a detached stripe).
            // Padded off the stack's top/bottom so rows breathe.
            membershipWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            membershipWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            membershipWell.topAnchor.constraint(equalTo: membershipStack.topAnchor,
                                                constant: -GroupedSectionView.verticalPadding),
            membershipWell.bottomAnchor.constraint(equalTo: membershipStack.bottomAnchor,
                                                   constant: GroupedSectionView.verticalPadding),

            // ANCHORING TRAP: anchored to the COLUMN, not the container. It
            // used to hang off the container's leading edge, which was the
            // same x only while the column started there too — the moment the
            // column took its own margin the button drifted 14 pt left of
            // everything it belongs under.
            deleteButton.leadingAnchor.constraint(equalTo: column.leadingAnchor,
                                                  constant: GroupsPaneLayout.contentLeadingInset),
            // The grouped-list container extends `verticalPadding` BELOW the
            // last row, so the VISIBLE gap between its bottom border and the
            // button is `actionBandGap` — wider than the gap between sections,
            // so the destructive action reads as its own band.
            deleteButton.topAnchor.constraint(
                equalTo: column.bottomAnchor,
                constant: GroupsPaneLayout.actionBandGap + GroupedSectionView.verticalPadding),
            // `==` against the DOCUMENT (roadmap 039). It used to be `<=`
            // against the pane, because pinning the button to the PANE's bottom
            // made the whole chain above it stretch to reach — the column grew,
            // the row stack (pinned to the column's bottom) grew with it, and
            // the section's bottom padding silently absorbed every spare point
            // of pane height (49.5pt below the last divider against 36.5pt
            // above the first — design review 2026-07-25). A scroll document
            // has no spare height to absorb: it HUGS its content, so this
            // equality is what gives the document its bottom edge, and the
            // slack — when the pane is taller than the content — falls below
            // the document inside the clip view, where nothing is drawn.
            deleteButton.bottomAnchor.constraint(equalTo: document.bottomAnchor,
                                                 constant: -GroupsPaneLayout.paneBottomInset),

            // Beside "Delete scene…", centred on it, with NO bottom pin: the
            // line's overhang rides inside the `paneBottomInset` margin above,
            // so the pane's fitting height is unchanged (see ``reassuranceLabel``).
            reassuranceLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: deleteButton.trailingAnchor, constant: 16),
            reassuranceLabel.centerYAnchor.constraint(equalTo: deleteButton.centerYAnchor),
            reassuranceTrailing,

            // ANCHORING TRAP: the overlay's LEADING edge must coincide with the
            // rows' leading edge (the column's), not the container's — the
            // overlay draws the spine at the literal `railGutterCenterX` in its
            // own space while each row places its node at that x from its own
            // leading edge, so a mismatch floats every node off the line by
            // exactly the difference.
            railOverlay.topAnchor.constraint(equalTo: document.topAnchor),
            railOverlay.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            railOverlay.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            railOverlay.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        view = container
    }

    /// Build the header's "Playing" marker: the sidebar's exact symbol and
    /// wording (`IconLabelCellView`), so the same state can't acquire a second
    /// name. `Tokens.Color.gold` is an INSTRUMENT — it keeps its authored value
    /// in every theme, and it tints the GLYPH only; the caption stays
    /// `Tokens.Color.label2` under this pane's frozen-text-colors rule.
    private func buildPlayingBadge() {
        let glyph = NSImageView()
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                              accessibilityDescription: "Playing")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        glyph.image?.isTemplate = true
        glyph.contentTintColor = Tokens.Color.gold
        // The caption beside it already speaks the words — an AX element here
        // would announce them twice.
        glyph.setAccessibilityElement(false)

        let caption = NSTextField(labelWithString: "Playing")
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.font = Tokens.Font.caption
        caption.textColor = Tokens.Color.label2

        playingBadge.translatesAutoresizingMaskIntoConstraints = false
        playingBadge.orientation = .horizontal
        playingBadge.alignment = .centerY
        playingBadge.spacing = 4
        playingBadge.setViews([glyph, caption], in: .leading)
    }

    // MARK: Model

    /// Show the editor for `groupID`, building the membership row list from
    /// `devices` (every known device is a candidate for an available row; an
    /// unavailable device is offered only while it remains a member — see
    /// ``rebuildCandidates(devices:)``). No-op if the group no longer exists.
    ///
    /// GATED on what the pane actually draws. The host calls this on EVERY
    /// backend event while the screen is visible, and a re-render tears down
    /// and rebuilds every membership row — which threw away clicks, hover and
    /// keyboard focus several times a second during discovery. An unchanged
    /// ``EditorProjection`` means there is nothing to repaint.
    public func show(groupID: String, devices: [Device]) {
        guard let group = groupController.groups.first(where: { $0.id == groupID }) else { return }
        guard editorProjection(for: group, devices: devices) != lastRenderedProjection else {
            // Nothing to repaint, but a later membership toggle
            // (`membershipToggled`) reads `allDevices`/`candidateDevices` to
            // persist a device's CURRENT volume — a volume-only change is
            // correctly invisible to `EditorProjection` (nothing this pane
            // draws shows a volume), but leaving those two stale here let a
            // subsequent check-in persist a volume from before this event.
            // Re-derive them from the fresh snapshot without touching the
            // rows: only the render path may rebuild those.
            allDevices = devices
            candidateDevices = devices
            return
        }
        render(group: group, devices: devices)
    }

    /// Paint the pane from `group` + `devices`, unconditionally. The single
    /// writer of ``lastRenderedProjection`` (recomputed at the end, so a
    /// failure re-render always re-syncs the gate).
    private func render(group: Group, devices: [Device]) {
        // Read BEFORE `editingGroupID` moves: the typing guard below is scoped
        // to the SAME group, and switching the pane to a different group must
        // re-fill the field, or it would show the previous group's half-typed
        // name (a phone-driven edit can force exactly that switch).
        let switchedGroup = editingGroupID != group.id
        editingGroupID = group.id
        allDevices = devices

        // NEVER overwrite a name being typed. The host's refresh arrives on
        // every backend event, and writing `stringValue` while the field
        // editor is up replaced the user's half-typed name mid-keystroke.
        // Everything else below still runs.
        if nameField.currentEditor() == nil || switchedGroup {
            nameField.stringValue = group.name
            updateNameFieldWidth()
        }
        refreshIconWell(group: group)
        // Warm Signal §5.3: the ACTIVE Main Out group's icon well carries the
        // thin gold ring (drawing-only; pure model state from
        // `GroupController.activeGroupID`, never audio-driven — §3.3).
        // VoiceOver equivalent: the well's accessibilityValue mirrors the
        // ring so the state isn't color-only, using the same "Playing"
        // words as the visible badge below.
        let isActive = groupController.activeGroupID == group.id
        isActiveGroup = isActive
        iconWell.isActiveGroup = isActive
        iconWell.setAccessibilityValue(isActive ? "Playing" : "")
        // The ring is colour alone; these two say it in words — the marker
        // states that this group IS playing, and the line answers the question
        // that raises while its membership is being edited. An inactive group
        // moves nothing either way, so its line only says edits are saved.
        playingBadge.isHidden = !isActive
        reassuranceLabel.stringValue = isActive ? Self.savedAsYouGoActive : Self.savedAsYouGo
        // The origin hook's tone follows the same active-group truth the well's
        // gold ring does (`railHookAnchor`), so repaint the rail with it.
        railOverlay.needsDisplay = true
        rebuildCandidates(memberSet: Set(group.memberIDs))
        refreshPrimaryTitle()
        lastRenderedProjection = editorProjection(for: group, devices: devices)
        test_renderCount += 1
    }

    /// Exactly what this pane draws, as one Equatable value — the gate
    /// ``show(groupID:devices:)`` compares. Not a diffing framework: one
    /// struct, one equality check (the same shape `MixerWindowController`
    /// already uses for the sidebar). It may only err toward RENDERING: a
    /// stale projection costs a repaint, a too-clever one drops a real change.
    private struct EditorProjection: Equatable {
        struct Row: Equatable {
            let id: String
            let name: String
            let isAvailable: Bool
            let symbolName: String
            let isMember: Bool
            let railArmed: Bool
        }
        let groupID: String
        let groupName: String
        let iconSymbolName: String
        let isActive: Bool
        let rows: [Row]
    }

    /// The projection the pane's current contents were rendered from.
    private var lastRenderedProjection: EditorProjection?

    private func editorProjection(for group: Group, devices: [Device]) -> EditorProjection {
        let memberSet = Set(group.memberIDs)
        let isActive = groupController.activeGroupID == group.id
        // Every device is a candidate, unavailable ones included (owner's
        // call, 2026-08-28) — same rule as `rebuildCandidates(memberSet:)` and
        // the creation sheet. Rows for unavailable devices render dimmed.
        let candidates = devices
        return EditorProjection(
            groupID: group.id,
            groupName: group.name,
            iconSymbolName: DeviceIcon.resolve(group.iconSymbolName,
                                               default: Group.defaultIconSymbolName),
            isActive: isActive,
            rows: candidates.map { device in
                EditorProjection.Row(
                    id: device.id,
                    name: device.name,
                    isAvailable: device.isAvailable,
                    symbolName: deviceIconController?.symbolName(for: device)
                        ?? device.kind.symbolName,
                    isMember: memberSet.contains(device.id),
                    railArmed: railArmed(for: device, memberSet: memberSet,
                                         isActiveGroup: isActive))
            })
    }

    /// Whether this row's node renders ARMED — "this speaker is receiving the
    /// Main Out feed right now", per row rather than per pane.
    ///
    /// Gold means LIVE, so the truth has to be the ROUTED one: for an
    /// AirPlay/Bluetooth/Cast row that is the backend's own echo
    /// (`Device.isSelected` — in the current output set), and for the Mac's
    /// local sink it is saved Main-Out membership, which for the ACTIVE group
    /// is exactly `memberSet` (`GroupController.isMainOutMember(_:)`). An
    /// inactive group's editor is never armed at all. Editing membership does
    /// not re-route (`saveGroup` is a pure model op), which is why a checked
    /// row can legitimately read idle: saved, not live.
    private func railArmed(for device: Device, memberSet: Set<String>,
                           isActiveGroup: Bool) -> Bool {
        guard isActiveGroup else { return false }
        return device.isLocalDevice ? memberSet.contains(device.id) : device.isSelected
    }

    /// Refresh the header icon's image from `group.iconSymbolName`, resolved
    /// through `DeviceIcon.resolve` so a stale/unrecognized override still
    /// renders the default rather than a blank glyph.
    private func refreshIconWell(group: Group) {
        let symbolName = DeviceIcon.resolve(group.iconSymbolName, default: Group.defaultIconSymbolName)
        iconWellSymbolName = symbolName
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Scene icon")
        image?.isTemplate = true
        iconWell.iconImageView.image = image
    }

    /// Recompute `candidateDevices` from `allDevices` — available devices,
    /// plus any unavailable device still in `memberSet` — and rebuild the
    /// membership rows from that list. Called on `show` and after every
    /// membership toggle, so an unchecked unavailable member disappears.
    ///
    /// REUSES the existing rows whenever the candidate ID SEQUENCE is
    /// unchanged — only the list's membership/labels moved, so refreshing each
    /// row in place keeps the very view instances the pointer, the keyboard
    /// focus and any in-flight click are attached to. A changed sequence (a
    /// device appeared or vanished) still falls through to the full rebuild.
    private func rebuildCandidates(memberSet: Set<String>) {
        // Every device, unavailable ones included (owner's call, 2026-08-28).
        let newCandidates = allDevices
        guard newCandidates.map(\.id) == candidateDevices.map(\.id), !rowsByID.isEmpty else {
            candidateDevices = newCandidates
            buildRows(memberSet: memberSet)
            return
        }
        candidateDevices = newCandidates
        for device in newCandidates {
            guard let row = rowsByID[device.id] else { continue }
            row.apply(device: device,
                      checked: memberSet.contains(device.id),
                      iconSymbolName: deviceIconController?.symbolName(for: device))
            row.railArmed = railArmed(for: device, memberSet: memberSet,
                                      isActiveGroup: isActiveGroup)
            // `apply` re-enables the checkbox but doesn't know about the sole-
            // member pin, so a formerly-pinned row that gained company here
            // (still `apply`'s job, not this loop's) kept its stale "A group
            // needs at least one device…" tooltip/VoiceOver help forever.
            // Clear it for every row; `pinSoleMember` below re-pins the
            // current sole member, if there still is one.
            row.setCheckboxEnabled(true, tooltip: nil)
        }
        // `apply` re-enables the checkbox (visibility policy is the host's
        // job), so the pinning has to run AFTER it, exactly as in `buildRows`.
        pinSoleMember(memberSet: memberSet)
        membershipWell.rows = candidateDevices.compactMap { rowsByID[$0.id] }
        updateRail()
    }

    /// Pin the sole remaining member: a group needs at least one device, so
    /// its last member can't be unchecked here (delete the group instead).
    /// Only one member → that row's checkbox is disabled with an explanation.
    private func pinSoleMember(memberSet: Set<String>) {
        guard memberSet.count == 1, let onlyMemberID = memberSet.first else { return }
        rowsByID[onlyMemberID]?.setCheckboxEnabled(
            false, tooltip: "A scene needs at least one speaker. Use \u{201C}Delete scene\u{2026}\u{201D} to remove it.")
    }

    /// (Re)build the membership row list, checking members of `memberSet`.
    private func buildRows(memberSet: Set<String>) {
        for v in membershipStack.arrangedSubviews { membershipStack.removeArrangedSubview(v); v.removeFromSuperview() }
        rowsByID.removeAll()
        for device in candidateDevices {
            let row = MembershipRowView(
                device: device,
                checked: memberSet.contains(device.id),
                iconSymbolName: deviceIconController?.symbolName(for: device),
                surface: .warmPane)
            row.railArmed = railArmed(for: device, memberSet: memberSet,
                                      isActiveGroup: isActiveGroup)
            row.onToggle = { [weak self] deviceID, isChecked in
                self?.membershipToggled(deviceID: deviceID, isChecked: isChecked)
            }
            rowsByID[device.id] = row
            membershipStack.addArrangedSubview(row)
            // Rows FILL the section (the stack is pinned to both of the
            // column's edges) instead of sizing to their own intrinsic width —
            // otherwise the trailing "Unavailable" annotation lands wherever
            // the widest device name happens to end, and the list reads as a
            // narrow strip inside a wide box.
            row.widthAnchor.constraint(equalTo: membershipStack.widthAnchor).isActive = true
        }
        pinSoleMember(memberSet: memberSet)
        // T5: re-point the well at the CURRENT rows so its hairlines land
        // between whatever's actually in the stack now (a rebuild can add or
        // drop rows — an unchecked unavailable device disappears).
        membershipWell.rows = candidateDevices.compactMap { rowsByID[$0.id] }
        updateRail()
    }

    /// Re-point the pane-level rail at the current rows (Warm Signal v4 §Call-1):
    /// the channel runs from the group icon well down the WHOLE candidate list,
    /// detouring around every unchecked row wherever it sits, while the signal
    /// line inside it reaches only as far as the LOWEST CHECKED row — so the
    /// GOLD's length reads as "how far down this group reaches." The overlay
    /// derives both ends from the rows' node kinds, so this only has to hand it
    /// the current rows. Called after every rebuild — which is also after every
    /// membership toggle, so the signal's end follows the checkboxes.
    private func updateRail() {
        let rows = candidateDevices.compactMap { rowsByID[$0.id] }
        railOverlay.mainOutRow = self
        railOverlay.deviceRows = rows
        railOverlay.needsDisplay = true
    }

    // MARK: Actions

    @objc private func nameCommitted(_ sender: NSTextField) {
        commitRename()
    }

    /// Whether the name field holds text that differs from the group's saved
    /// name. This is the editor's ONE genuinely uncommitted state: a
    /// membership toggle, an icon pick and a committed rename each write
    /// through to the store the moment they happen, so nothing else here can
    /// ever be "unsaved". Trimmed, because ``commitRename()`` trims too — a
    /// name padded with spaces is not a different name.
    private var hasPendingRename: Bool {
        guard let group = editingGroup else { return false }
        return nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != group.name
    }

    /// Re-title the primary from ``hasPendingRename``, carrying the visible
    /// title into the accessibility label so VoiceOver never announces the
    /// other one.
    private func refreshPrimaryTitle() {
        let title = hasPendingRename ? Self.saveTitle : Self.doneTitle
        guard doneButton.title != title else { return }
        doneButton.title = title
        doneButton.setAccessibilityLabel(title)
    }

    /// The group being edited, or `nil` before `show` / after a delete.
    private var editingGroup: Group? {
        guard let editingGroupID else { return nil }
        return groupController.groups.first(where: { $0.id == editingGroupID })
    }

    /// Commit the field's current text as the group's name — driven by Return
    /// (the field's action), by focus loss (`controlTextDidEndEditing`) and by
    /// the primary button while it reads "Save".
    ///
    /// EMPTIED: an all-whitespace name is refused, and the field is put BACK to
    /// the group's real name. It used to be refused silently, leaving a blank
    /// box on screen while the group still had its old name — the UI lied about
    /// what was saved.
    ///
    /// Returns whether the field and the model now AGREE — false only when the
    /// rename was refused with an explanation on screen (a name another group
    /// holds, or a failed save), which is the one case a caller must not leave
    /// the editor on.
    @discardableResult
    private func commitRename() -> Bool {
        guard var group = editingGroup else { return true }
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { restoreNameField(); return true }
        guard trimmed != group.name else { restoreNameField(); return true }
        // TAKEN: two groups with the same name are two rows the sidebar can't
        // tell apart. Refused with an explanation rather than silently
        // suffixed — the same honesty the empty-name refusal above follows.
        // Case-insensitive, but excluding THIS group, so re-casing its own
        // name stays a legal rename.
        guard !isNameTaken(trimmed, excluding: group.id) else {
            restoreNameField()
            test_duplicateNameRefused = true
            presentDuplicateNameAlert(name: trimmed)
            return false
        }
        group.name = trimmed
        guard saveOrReport(group) else { return false }
        Analytics.capture("scene:renamed")
        nameField.stringValue = trimmed
        updateNameFieldWidth()
        refreshPrimaryTitle()
        onDidEditGroup?()
        return true
    }

    /// Persist `group`, REPORTING failure instead of swallowing it (the same
    /// "UI never lies" contract the empty-name rename fix established): on a
    /// throw the pane re-renders from the model — so no checkbox, name, or icon
    /// keeps claiming a state that never saved — and a plain-words alert names
    /// the problem. Returns whether the save took.
    @discardableResult
    private func saveOrReport(_ group: Group) -> Bool {
        do {
            try groupController.saveGroup(group)
            return true
        } catch {
            test_saveFailureReported = true
            // `render` DIRECTLY, not `show`: the projection gate would compare
            // equal (nothing in the model changed — that is the whole point of
            // a failed save) and skip the repaint that puts the controls back
            // to the truth.
            if let group = editingGroup { render(group: group, devices: allDevices) }
            presentPersistFailureAlert(message: "Couldn\u{2019}t save the change.")
            return false
        }
    }

    /// Whether another group already carries `name` (case-insensitively).
    /// `excluding` is the group being renamed, so re-casing its own name is
    /// never a collision with itself.
    private func isNameTaken(_ name: String, excluding id: String?) -> Bool {
        groupController.groups.contains {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// The refusal for a name another group already has — same window-guarded
    /// shape as ``presentPersistFailureAlert(message:)``.
    private func presentDuplicateNameAlert(name: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "That name is already taken."
        alert.informativeText =
            "Another scene is named \u{201C}\(name)\u{201D}. Choose a different name."
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    /// The failure alert both `saveOrReport` and the delete path present — a
    /// sheet when a window hosts the pane, skipped headless (the `test_*`
    /// seams observe the failure instead).
    private func presentPersistFailureAlert(message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "The scene\u{2019}s saved settings couldn\u{2019}t be updated. Try again."
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    /// Put the field back to the group's persisted name and re-measure it —
    /// the shared tail of "you emptied it" and "you pressed Escape".
    private func restoreNameField() {
        guard let group = editingGroup else { return }
        if nameField.stringValue != group.name { nameField.stringValue = group.name }
        updateNameFieldWidth()
        refreshPrimaryTitle()
    }

    /// ESCAPE: discard the in-progress edit and hand focus back, exactly like a
    /// Finder rename. `abortEditing()` is what drops the field editor's pending
    /// text; the restore then guarantees the visible string matches the model
    /// even if the field was showing a half-typed name.
    ///
    /// Focus goes SOMEWHERE REAL. It used to go to `makeFirstResponder(nil)`,
    /// which is the exact dead-Tab state A11Y-GROUPS fixed: the window becomes
    /// its own first responder and Tab has nothing to advance from. The host
    /// wires ``onDidCancelRename`` to the sidebar's outline view, the one
    /// control present whatever pane is showing.
    private func cancelRename() {
        nameField.abortEditing()
        restoreNameField()
        onDidCancelRename?()
    }

    /// Re-measure the rename field around its current text. An editable
    /// `NSTextField` reports NO intrinsic width, so "hug the name, then stop at
    /// the section's edge" has to be measured by hand: this drives the optional
    /// width constraint, and the required floor / 999-priority cap clamp it.
    private func updateNameFieldWidth() {
        guard let nameFieldWidth else { return }
        let text = nameField.stringValue.isEmpty
            ? (nameField.placeholderString ?? "")
            : nameField.stringValue
        let font = nameField.font ?? Tokens.Font.heading
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        // The insets the cell reserves for the leading margin and the trailing
        // pencil, plus a hair of slack so the caret at the end of the string
        // never sits on the truncation edge.
        nameFieldWidth.constant = (measured
            + WarmNameFieldCell.textInsetLeading
            + WarmNameFieldCell.textInsetTrailing
            + 2).rounded(.up)
    }

    /// The rename field's skin, for the hover/pencil state below.
    private var nameFieldCell: WarmNameFieldCell? { nameField.cell as? WarmNameFieldCell }

    /// Hover on the rename field (the tracking area installed in `loadView`;
    /// the field itself stays stock, so this controller owns the callbacks).
    /// DRAWING ONLY — a neutral wash plus the pencil's alpha step-up, no
    /// geometry change (R7).
    public override func mouseEntered(with event: NSEvent) { setNameFieldHovered(true) }
    public override func mouseExited(with event: NSEvent) { setNameFieldHovered(false) }

    private func setNameFieldHovered(_ hovered: Bool) {
        guard let cell = nameFieldCell, cell.isHovered != hovered else { return }
        cell.isHovered = hovered
        nameField.needsDisplay = true
    }

    private func membershipToggled(deviceID: String, isChecked: Bool) {
        guard let editingGroupID,
              var group = groupController.groups.first(where: { $0.id == editingGroupID }) else { return }

        if isChecked {
            if !group.memberIDs.contains(deviceID) {
                group.memberIDs.append(deviceID)
                // Remember the device's current volume for this membership.
                if let device = candidateDevices.first(where: { $0.id == deviceID }) {
                    group.memberVolumes[deviceID] = device.volume
                }
            }
        } else {
            // A group must keep at least one device — refuse to remove the last
            // member (to remove the group entirely, use "Delete scene…"). Revert
            // the checkbox so the row reflects the unchanged membership and bail
            // before persisting an empty group.
            guard group.memberIDs.contains(where: { $0 != deviceID }) else {
                rowsByID[deviceID]?.isChecked = true
                return
            }
            group.memberIDs.removeAll { $0 == deviceID }
            group.memberVolumes[deviceID] = nil
        }
        guard saveOrReport(group) else { return }   // failure re-renders from the model
        Analytics.capture("scene:membership_changed", ["added": isChecked ? "true" : "false"])
        // Rebuild: an unchecked unavailable device drops out of the list.
        rebuildCandidates(memberSet: Set(group.memberIDs))
        onDidEditGroup?()
    }

    /// Build and present `IconPickerViewController` anchored to `anchor`,
    /// wiring its `onPick` to ``pickIcon(_:)``. Guarded on `anchor.window !=
    /// nil` (`PopoverController.presentUnsupportedExplanation`'s pattern) so a
    /// headless test never needs a real `NSWindow` — ``test_pickIcon(_:)``
    /// drives ``pickIcon(_:)`` directly instead.
    private func presentIconPicker(anchoredTo anchor: NSView) {
        guard let editingGroupID,
              let group = groupController.groups.first(where: { $0.id == editingGroupID }) else { return }

        let picker = IconPickerViewController()
        picker.configure(currentSymbolName: group.iconSymbolName, defaultSymbolName: Group.defaultIconSymbolName)
        picker.onPick = { [weak self] name in
            self?.pickIcon(name)
        }

        guard anchor.window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        popover.contentSize = picker.view.fittingSize
        iconPickerPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// Persist `name` as the editing group's icon override (`nil` reverts to
    /// the default) and refresh the well — instant-apply, like a rename.
    private func pickIcon(_ name: String?) {
        guard let editingGroupID,
              var group = groupController.groups.first(where: { $0.id == editingGroupID }) else { return }
        guard group.iconSymbolName != name else { return }
        group.iconSymbolName = name
        guard saveOrReport(group) else { return }   // failure re-renders from the model
        refreshIconWell(group: group)
        onDidEditGroup?()
    }

    /// Put keyboard focus in the rename field with its text selected — the
    /// sidebar's "Rename…" / double-click path, after the host has shown this
    /// editor. First-focus select-all comes from the existing delegate.
    public func focusRenameField() {
        view.window?.makeFirstResponder(nameField)
    }

    /// Run the same confirm-then-delete flow the "Delete scene…" button does —
    /// the sidebar's context-menu "Delete scene…" path.
    public func requestDelete() {
        deleteTapped(deleteButton)
    }

    @objc private func doneTapped(_ sender: NSButton) {
        // While it reads "Save" there is a typed name waiting: commit it FIRST,
        // then leave by the same door Done uses. A refusal (the name is taken,
        // or the save threw) keeps the editor open on the explanation.
        if hasPendingRename, !commitRename() { return }
        onBack?()
    }

    @objc private func backTapped(_ sender: NSButton) {
        onBack?()
    }

    @objc private func deleteTapped(_ sender: NSButton) {
        guard let group = editingGroup else { return }
        guard let window = view.window else {
            // Headless: no window means no confirmation, and deleting the
            // user's group without one is exactly the thing the sheet is
            // there to prevent. `test_confirmDelete()` is the headless path.
            return
        }
        makeDeleteAlert(for: group).beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performDelete(id: group.id)
        }
    }

    /// The delete confirmation (HIG — destructive action). Two sentences,
    /// depending on what deleting this group actually DOES:
    ///
    /// - the ACTIVE group is the Main Out target, so deleting it sends
    ///   playback back to Selected Devices (`GroupController.deleteGroup`
    ///   calls `setMainOut(.selectedDevices)`): a speaker that is also in
    ///   Selected Devices keeps playing, one that is only in this group stops.
    ///   "Deleting a group doesn't change which speakers are playing" is a
    ///   plain lie in that case, and it was the sentence on screen.
    /// - any OTHER group is pure configuration, and the old sentence is true.
    ///
    /// Delete stays the FIRST button (the `.alertFirstButtonReturn` mapping
    /// depends on it) but loses the Return key to Cancel: an accidental Return
    /// on a destructive sheet must not be the destructive answer.
    private func makeDeleteAlert(for group: Group) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(group.name)\u{201D}?"
        alert.informativeText = groupController.activeGroupID == group.id
            ? "This scene is playing. Deleting it switches playback to Selected Speakers; "
              + "speakers that are only in this scene will stop."
            : "Deleting a scene doesn't change which speakers are playing."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert
    }

    // MARK: Test-support hooks

    /// Membership row ids currently checked, in candidate order.
    public var test_checkedDeviceIDs: [String] {
        candidateDevices.map(\.id).filter { rowsByID[$0]?.test_isChecked == true }
    }

    /// All candidate device ids currently offered as membership rows.
    public var test_candidateDeviceIDs: [String] { candidateDevices.map(\.id) }

    /// Whether the membership checkbox for `deviceID` is currently interactive.
    /// The sole remaining member of a group is pinned (disabled) so it can't be
    /// unchecked into an empty group.
    public func test_isMembershipRowEnabled(for deviceID: String) -> Bool {
        rowsByID[deviceID]?.test_isCheckboxEnabled ?? false
    }

    /// The current text in the rename field.
    public var test_nameFieldValue: String { nameField.stringValue }

    /// Simulate typing a new name and committing it (Return / focus loss).
    public func test_rename(to newName: String) {
        nameField.stringValue = newName
        updateNameFieldWidth()
        commitRename()
    }

    /// Simulate pressing RETURN in the rename field — drives the field's real
    /// target/action, the same dispatch AppKit performs, rather than calling
    /// `commitRename` behind its back.
    public func test_commitRenameViaReturn(_ newName: String) {
        nameField.stringValue = newName
        updateNameFieldWidth()
        _ = nameField.target?.perform(nameField.action, with: nameField)
    }

    /// Simulate TYPING `text` into the rename field WITHOUT committing it —
    /// drives the real `controlTextDidChange` delegate path, which is what the
    /// primary's title tracks.
    public func test_typeIntoNameField(_ text: String) {
        nameField.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                          object: nameField))
    }

    /// Simulate the rename field LOSING FOCUS with `newName` typed in it —
    /// drives the real `controlTextDidEndEditing` delegate path.
    public func test_commitRenameViaFocusLoss(_ newName: String) {
        nameField.stringValue = newName
        updateNameFieldWidth()
        controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
                                              object: nameField))
    }

    /// Simulate pressing ESCAPE with `typed` in the rename field — drives the
    /// real `control(_:textView:doCommandBy:)` seam AppKit routes the key
    /// through, with a throwaway field editor stand-in (the implementation
    /// never touches it).
    public func test_cancelRename(after typed: String) {
        nameField.stringValue = typed
        updateNameFieldWidth()
        _ = control(nameField, textView: NSTextView(),
                    doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    }

    /// The rename field's laid-out frame in the pane's own coordinates.
    public var test_titleFieldFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return nameField.convert(nameField.bounds, to: view)
    }

    /// Drive the rename field's hover state headlessly (a real `mouseEntered`
    /// can't be synthesized in a headless run) — the same path the tracking
    /// area's callback takes.
    public func test_setTitleHovered(_ hovered: Bool) { setNameFieldHovered(hovered) }

    /// Whether the rename field is currently drawing its hover wash.
    public var test_isTitleHovered: Bool { nameFieldCell?.isHovered ?? false }

    /// Whether the rename field currently paints its trailing pencil (hidden
    /// while the field is being edited).
    public var test_titleShowsPencil: Bool {
        nameFieldCell?.test_showsPencil(in: nameField) ?? false
    }

    /// Whether the rename field wears the `WarmNameFieldCell` skin while
    /// staying a real, editable, focusable `NSTextField`.
    public var test_titleHasWarmSkin: Bool { nameFieldCell != nil }

    /// The rename field itself, so a test can drive real AppKit editing (a
    /// window + `makeFirstResponder`) instead of a stand-in.
    public var test_titleField: NSTextField { nameField }

    /// Simulate ticking/unticking a membership row for a device.
    public func test_setMembership(_ member: Bool, for deviceID: String) {
        guard let row = rowsByID[deviceID], row.test_isChecked != member else { return }
        row.test_toggle()
    }

    /// The SF Symbol name currently resolved for the icon well's image, or
    /// `nil` if it has none loaded yet (before `show`).
    public var test_iconWellSymbolName: String? { iconWellSymbolName }

    /// True when the identity glow shares the well's parent AND sits below it
    /// in z-order — in front of the opaque well it would be invisible, and the
    /// magenta has to read as light behind the seat.
    public var test_hasIdentityGlow: Bool {
        guard let parent = iconWell.superview,
              iconGlow.superview === parent,
              let glowIndex = parent.subviews.firstIndex(of: iconGlow),
              let wellIndex = parent.subviews.firstIndex(of: iconWell) else { return false }
        return glowIndex < wellIndex
    }

    /// The size the glow is actually laid out at — the gradient scales to its
    /// own bounds, so this is what the magenta's radius follows.
    public var test_identityGlowSide: CGFloat {
        view.layoutSubtreeIfNeeded()
        return iconGlow.frame.width
    }

    /// Simulate picking `name` from the icon picker (`nil` = "use default"),
    /// bypassing the anchored popover — drives the exact same
    /// ``pickIcon(_:)`` path `IconPickerViewController.onPick` would.
    public func test_pickIcon(_ name: String?) {
        pickIcon(name)
    }

    /// Whether the header's gold "Playing" marker is on screen — true for
    /// the active Main Out group's editor only.
    public var test_playingBadgeVisible: Bool { !playingBadge.isHidden }

    /// Whether the reassurance line beside the delete row is on screen.
    public var test_reassuranceVisible: Bool { !reassuranceLabel.isHidden }

    /// The reassurance line's exact wording.
    public var test_reassuranceText: String { reassuranceLabel.stringValue }

    /// Drive a membership row's pointer state headlessly — the node's hover
    /// resize is the row's "this is clickable" affordance now that the whole
    /// row toggles.
    public func test_setRowHovered(_ hovered: Bool, for deviceID: String) {
        rowsByID[deviceID]?.test_setHovered(hovered)
    }

    /// Whether a membership row's node is previewing its post-click size.
    public func test_rowNodePreviewsClick(for deviceID: String) -> Bool {
        rowsByID[deviceID]?.test_nodePreviewsClick ?? false
    }

    /// Simulate a click on a membership row's BODY (not its checkbox) — the
    /// same path a real `mouseUp` on the row takes.
    public func test_clickRow(for deviceID: String) {
        rowsByID[deviceID]?.test_clickRow()
    }

    /// True when "Delete scene…" is currently visible (always true — the
    /// editor is edit-only).
    public var test_deleteButtonVisible: Bool { !deleteButton.isHidden }

    /// The primary button's title — "Done" at rest, "Save" while the name
    /// field holds an uncommitted rename.
    public var test_doneButtonTitle: String { doneButton.title }

    /// What VoiceOver announces for the primary, which must be the title on
    /// screen and never the other one.
    public var test_doneButtonAccessibilityLabel: String? {
        doneButton.accessibilityLabel()
    }

    /// Click the primary — the real button action.
    public func test_done() { doneButton.performClick(nil) }

    /// The primary's laid-out frame in the pane's own coordinates: it tops the
    /// form on the right, level with the way back.
    public var test_doneButtonFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return doneButton.convert(doneButton.bounds, to: view)
    }

    /// The "‹ Groups" control's laid-out frame in the pane's own coordinates —
    /// same height as the primary, at the other end of the same band.
    public var test_backControlFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return backButton.convert(backButton.bounds, to: view)
    }

    /// What VoiceOver calls the way back.
    public var test_backControlAccessibilityLabel: String? {
        backButton.accessibilityLabel()
    }

    /// The way back's tooltip — the one place ⌘[ is printed.
    public var test_backControlToolTip: String? { backButton.toolTip }

    /// Whether the way back can take keyboard focus, so Tab reaches it.
    public var test_backControlAcceptsFocus: Bool { backButton.acceptsFirstResponder }

    /// The delete button's laid-out frame in the pane's own coordinates — it
    /// must line up with the content above it (anchoring trap: it used to hang
    /// off the container, not the column).
    public var test_deleteButtonFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return deleteButton.convert(deleteButton.bounds, to: view)
    }

    /// Delete `id`, reporting failure instead of swallowing it — a failed
    /// delete keeps the editor on the still-existing group rather than popping
    /// to a sidebar that still lists it.
    private func performDelete(id: String) {
        do {
            try groupController.deleteGroup(id: id)
        } catch {
            test_saveFailureReported = true
            presentPersistFailureAlert(message: "Couldn\u{2019}t delete the scene.")
            return
        }
        Analytics.capture("scene:deleted")
        editingGroupID = nil
        onDidDeleteGroup?()
    }

    /// Simulate confirming the delete (bypasses the confirmation sheet).
    public func test_confirmDelete() {
        guard let editingGroupID else { return }
        performDelete(id: editingGroupID)
    }

    /// True once a persistence failure (save or delete) has been reported to
    /// the user instead of swallowed. Headless seam for the failure paths,
    /// which present no sheet without a window.
    public private(set) var test_saveFailureReported = false

    /// True once a rename was refused because another group already had that
    /// name. Headless seam — the explanation is a window-guarded sheet.
    public private(set) var test_duplicateNameRefused = false

    /// The confirmation the "Delete scene…" button would put up right now, or
    /// nil when nothing is being edited. Built through the real
    /// ``makeDeleteAlert(for:)``, so the copy and the button roles under test
    /// are the ones the user sees.
    public func test_makeDeleteAlert() -> NSAlert? {
        editingGroup.map(makeDeleteAlert(for:))
    }

    /// How many times the pane has actually repainted — proves the projection
    /// gate in ``show(groupID:devices:)``: a backend event that changes
    /// nothing this pane draws must leave it unchanged.
    public private(set) var test_renderCount = 0

    /// A membership row view by device id, so a test can prove a refresh
    /// REUSED the instance rather than rebuilding it.
    public func test_membershipRow(for deviceID: String) -> NSView? {
        rowsByID[deviceID]
    }

    /// The rail geometry the overlay would draw from its CURRENT live frames.
    public func test_railPlan() -> RailPlan? {
        view.layoutSubtreeIfNeeded()
        return railOverlay.test_resolvePlan()
    }

    /// Whether a row's rail node renders armed (gold) vs idle (ember) — must
    /// follow the SAME active-group truth as the icon well's ring and the
    /// rail hook, or the pane claims liveness it doesn't have.
    public func test_isRailArmed(for deviceID: String) -> Bool? {
        rowsByID[deviceID]?.test_railArmed
    }

    /// Each candidate row's drawn node, in candidate order.
    public var test_railNodes: [MembershipBusView.Node?] {
        candidateDevices.compactMap { rowsByID[$0.id] }.map(\.railNode)
    }

    /// Where a row's node centre lands in the RAIL OVERLAY's own coordinate
    /// space. The overlay draws the spine at the literal
    /// `PopoverColumnGrid.railGutterCenterX` in that space, so this MUST equal
    /// it — the one invariant that silently breaks if the row's leading edge and
    /// the overlay's leading edge ever stop coinciding.
    public func test_nodeCenterXInOverlaySpace(for deviceID: String) -> CGFloat? {
        guard let row = rowsByID[deviceID], let centerX = row.test_nodeCenterX else { return nil }
        view.layoutSubtreeIfNeeded()
        return railOverlay.convert(NSPoint(x: centerX, y: 0), from: row).x
    }

    /// The rename field's laid-out width — measured around the name it holds
    /// (``updateNameFieldWidth()``), clamped between its required floor and its
    /// section's edge.
    public var test_titleFieldWidth: CGFloat {
        view.layoutSubtreeIfNeeded()
        return nameField.bounds.width
    }

    /// HEADER PARITY hooks — the three numbers that must match
    /// `DeviceDetailViewController`'s identically-named hooks, so switching
    /// sidebar selection never shifts the header (`GroupsHeaderParityTests`).

    /// The icon well's laid-out frame in the pane's own coordinates.
    public var test_headerIconFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return iconWell.convert(iconWell.bounds, to: view)
    }

    /// The title's ALIGNMENT rect in the pane's own coordinates — what auto
    /// layout actually pins, so an editable field and a plain label (whose
    /// alignment insets differ from their frames) can be compared honestly.
    public var test_headerTitleAlignmentFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return nameField.alignmentRect(forFrame: nameField.convert(nameField.bounds, to: view))
    }

    /// The header SECTION's laid-out frame in the pane's own coordinates.
    public var test_headerSectionFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return headerWell.convert(headerWell.bounds, to: view)
    }

    /// T5: the number of rows currently fed to the checklist's recessed
    /// background (`GroupedSectionView.rows`) — mirrors `candidateDevices`
    /// when the well is correctly kept in sync with the row rebuild.
    public var test_membershipWellRowCount: Int { membershipWell.rows.count }

    /// T5: whether the well sits BEHIND the row stack in the column's
    /// z-order (so it can never intercept a row's click).
    public var test_membershipWellIsBehindStack: Bool {
        guard let column = membershipWell.superview,
              let wellIndex = column.subviews.firstIndex(of: membershipWell),
              let stackIndex = column.subviews.firstIndex(of: membershipStack) else { return false }
        return wellIndex < stackIndex
    }

    /// Click "‹ Groups" — the real button action, not `onBack` behind its back.
    public func test_goBack() { backButton.performClick(nil) }

    /// Press ⌘[ in the editor — a real `NSEvent` through the real
    /// `performKeyEquivalent` chain (`test_performCmdN`'s shape). True when the
    /// pane claimed it.
    @discardableResult
    public func test_performBackKeyEquivalent() -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: .command, timestamp: 0,
                                           windowNumber: 0, context: nil,
                                           characters: "[", charactersIgnoringModifiers: "[",
                                           isARepeat: false, keyCode: 33) else { return false }
        return view.performKeyEquivalent(with: event)
    }

    /// True while the pane is wrapped in the scroll view roadmap 039 gave it
    /// (`../AGENTS.md`) — the same seam `DeviceDetailViewController` carries.
    public var test_hasScrollView: Bool { scrollView != nil }

    /// The height the scroll DOCUMENT needs for its content — the editor's real
    /// content height now that the pane's own fitting height is capped by the
    /// scroll view. Overflow past the frame scrolls; it no longer asks the
    /// surface to grow.
    public var test_scrollDocumentHeight: CGFloat {
        view.layoutSubtreeIfNeeded()
        guard let document = scrollView?.documentView else { return 0 }
        return document.fittingSize.height
    }
}

// MARK: - Continuous rail origin hook (Warm Signal v4 §Call-1)

extension GroupEditorViewController: RailHookProviding {
    /// The group's ICON WELL is this pane's origin — the analogue of the
    /// popover's Main Audio ring: the rail curves out of the group tile's left
    /// edge and drops into the gutter, so the members visibly hang off the
    /// group they belong to.
    ///
    /// It briefly hooked the TITLE instead (design review 2026-07-25, when the
    /// icon sat ABOVE the name and the climb from the list past the whole
    /// header read badly). The header is now SIDE BY SIDE: icon and name share
    /// one horizontal band, so hooking the icon hooks the name's line too, and
    /// the hook goes back to the well — a fixed 64 pt tile whose leading edge
    /// sits on the content inset, rather than a field whose width changes with
    /// the name it holds.
    ///
    /// The well is a rounded-rect tile rather than a circle, so the "ring"
    /// reported here is its inscribed circle; only `ringCenterX - ringRadius`
    /// (the left edge) and `centerY` are ever drawn to. `gold` follows the SAME
    /// active-group truth as the well's §5.3 gold ring, so an inactive group's
    /// hook reads in the quiet `ember` idle tone.
    public func railHookAnchor(in view: NSView)
        -> (centerY: CGFloat, ringCenterX: CGFloat, ringRadius: CGFloat, gold: Bool)? {
        guard isViewLoaded, iconWell.superview != nil else { return nil }
        iconWell.layoutSubtreeIfNeeded()
        let center = iconWell.convert(
            NSPoint(x: iconWell.bounds.midX, y: iconWell.bounds.midY), to: view)
        return (center.y, center.x, DeviceIconWellView.size / 2, iconWell.isActiveGroup)
    }

    /// No-op: this pane's origin is the group's rounded-rect ICON WELL, not a
    /// stroked ring, so there is no circumference to bloom. The Groups screen
    /// also never mounts the connect pulse's firing conditions today — if it
    /// ever grows one, the well's §5.3 gold ring is where the acknowledgment
    /// would live.
    public func receiveRailPulse() {}
}

/// The editor pane's container: re-invalidates the rail overlay AND the
/// membership well (T5) on every layout pass so both track the current row
/// frames with no cached geometry. Both
/// draw from settled frames, so `cacheDisplay` snapshots stay deterministic.
/// A flipped document view so the editor scrolls from the TOP rather than
/// bottom-gravitating with dead space above the header. File-scoped on purpose
/// (`DeviceDetailViewController` and `GroupCreationSheetController` each keep
/// their own for the same reason).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class RailRepaintingView: NSView {
    weak var railOverlay: BusRailOverlayView?
    weak var membershipWell: GroupedSectionView?

    /// Leaves this editor for the group overview. Set at build time.
    var onBack: (() -> Void)?

    override func layout() {
        super.layout()
        railOverlay?.needsDisplay = true
        membershipWell?.needsDisplay = true
    }

    /// ⌘[ — the standard macOS "back" key equivalent. Dispatched DOWN the view
    /// tree (the window asks its content view, which asks each subview), not
    /// along the responder chain, so it has to be a view; `SidebarContainerView`
    /// catches Cmd-N the same way.
    ///
    /// razor: view-local, like Cmd-N. The Groups screen is hosted in the
    /// menu-bar surface and has no menu bar of its own, so this works while
    /// the editor is in the key window and nowhere else; only the back band's
    /// tooltip prints the shortcut. Upgrade path: a real "Back" item in the
    /// app's main menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "[",
           let onBack {
            onBack()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ESCAPE. Safe to claim unconditionally: a rename in progress consumes
    /// Escape first, in the field editor's own
    /// `control(_:textView:doCommandBy:)` (it reverts the name), so this only
    /// ever fires when nothing is being edited.
    override func cancelOperation(_ sender: Any?) {
        guard let onBack else { return super.cancelOperation(sender) }
        onBack()
    }
}

// MARK: - Back control

/// The "‹ Groups" control above the identity card. A stock `NSButton`, so the
/// focus ring, the pressed state, `accessibilityPerformPress()` and
/// VoiceOver's button role are AppKit's rather than hand-rolled.
///
/// The one override is `keyDown`: RETURN activates it while it is focused,
/// which AppKit reserves for a window's default button. Safe here because the
/// editor HAS no default button — Return belongs to the rename field, which
/// consumes it while editing. Space is claimed in the same branch, so it
/// works whether or not Full Keyboard Access is on.
private final class BackButton: NSButton {

    /// Focusable whether or not Full Keyboard Access is on, which is where an
    /// `NSButton` normally takes its answer from. The pane's Tab order has to
    /// reach the way out.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn || event.charactersIgnoringModifiers == " " {
            performClick(nil)
            return
        }
        super.keyDown(with: event)
    }
}

/// The checklist stack, carrying the SAME re-invalidation for relayouts that
/// never reach the container's `layout()` — a row growing inside an unchanged
/// container frame (see the two-hooks note in `loadView`; the popover's
/// `RailStackView` is the precedent). Dirtying from `layout()` cannot loop:
/// `needsDisplay` does not invalidate layout.
final class RailRepaintingStackView: NSStackView {
    weak var railOverlay: BusRailOverlayView?
    weak var membershipWell: GroupedSectionView?
    override func layout() {
        super.layout()
        railOverlay?.needsDisplay = true
        membershipWell?.needsDisplay = true
    }
}


// MARK: - NSTextFieldDelegate

extension GroupEditorViewController: NSTextFieldDelegate {
    /// Select the whole name the moment the field takes focus, Finder-style —
    /// a rename usually replaces the name rather than appending to it.
    public func controlTextDidBeginEditing(_ obj: Notification) {
        nameField.currentEditor()?.selectAll(nil)
    }

    /// The field grows with the name as it's typed (see
    /// ``updateNameFieldWidth()``), up to its section's edge, and the primary
    /// starts offering to Save the moment the text stops matching the group.
    public func controlTextDidChange(_ obj: Notification) {
        updateNameFieldWidth()
        refreshPrimaryTitle()
    }

    /// Commit the rename when the field loses focus, not just on Return.
    public func controlTextDidEndEditing(_ obj: Notification) {
        commitRename()
    }

    /// ESCAPE reverts to the pre-edit name. AppKit routes the key through the
    /// field editor as `cancelOperation(_:)`; without this it does nothing at
    /// all here, and a half-typed name sat there until it was committed by
    /// focus loss.
    public func control(_ control: NSControl, textView: NSTextView,
                        doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelRename()
        return true
    }
}
