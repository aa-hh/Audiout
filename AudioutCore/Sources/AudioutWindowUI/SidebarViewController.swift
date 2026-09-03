// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// What the user selected in the sidebar. Drives which content pane the screen
/// shows (the pinned Groups row → the card overview; a group → its editor; a
/// device → its detail pane; nothing → auto-select).
public enum SidebarSelection: Equatable, Sendable {
    /// The whole mix — everything the app sends to speakers. One row, no id:
    /// it is a destination, not a device.
    case mainOut
    /// The pinned "Groups" row: the saved-group card overview in the content
    /// pane (direction C — the sidebar itself lists no groups any more).
    case groupsOverview
    /// One saved group's editor. No sidebar row of its own: the overview's
    /// cards set it, and the sidebar highlights the Groups row for it.
    case group(id: String)
    case device(id: String)
}

/// The Groups screen's sidebar (SPEC §9 "Sidebar list": source-list
/// `NSOutlineView`) — **the device fleet, and nothing else** (direction C,
/// `dev/notes/groups-speakers-split-direction-c-brief-2026-08-27.md`).
///
/// Top to bottom: the pinned **Groups** row (the only non-device row — drawn
/// as a raised PLATE with a hairline edge, taller and bolder than the fleet
/// rows, because it is a doorway to the card overview and not one more list
/// item; a trailing chevron says it leads somewhere, and it carries the gold
/// "playing" marker whenever any group is live), then two flat sections,
/// **System Audio** and **Speakers**. Saved groups used to be a third section
/// here; a growing fleet pushed them off the top, so they moved into the
/// content pane as `GroupsOverviewViewController`'s card grid, and their
/// Rename…/Delete Group… menu went with them. What stays anchored to the
/// device list stays: the bottom add bar, its multi-select retitle, Cmd-N, and
/// the speaker row's "New Group from Selection…". Selection is reported
/// through `onSelect`.
///
/// The outline model is still a small tree of reference-typed `Node`s (one
/// level: section header → leaf rows, plus the two pinned root rows) so the
/// `NSOutlineViewDataSource` identity methods are stable across reloads and
/// the source-list header styling (`isGroupItem`) keeps working;
/// `NSOutlineView` with zero-depth leaves is simpler here than switching
/// containers, since header vibrancy/appearance still requires it.
public final class SidebarViewController: NSViewController {

    /// A node in the source-list tree. Reference type so `NSOutlineView` can key
    /// on object identity.
    final class Node {
        enum Payload {
            case header(String)             // "System Audio" / "Speakers" (isGroupItem)
            case groupsOverview             // the pinned "Groups" plate row (root-level leaf)
            case mainOut                    // the one "Main Audio" row (flat leaf row)
            case device(Device)             // a device row (flat leaf row)
        }
        let payload: Payload
        /// Only section headers ever have children now — group/device rows are
        /// always leaves (flat model, no expand/collapse).
        var children: [Node]
        init(_ payload: Payload, children: [Node] = []) {
            self.payload = payload
            self.children = children
        }
    }

    /// Called when the selection changes. `nil` when the selection is cleared
    /// or lands on a non-selectable header row. Reports the *primary* (first)
    /// selected row so the detail pane still follows a single selection; the full
    /// multi-selection is available via ``selectedDeviceIDs``.
    public var onSelect: ((SidebarSelection?) -> Void)?

    /// Called when the user clicks the "+" (new empty group) button at the bottom
    /// of the source list (SPEC.md §9 — manual creation, standard macOS add).
    public var onAddGroup: (() -> Void)?

    /// Called with the device ids a new group should be built from (SPEC.md §9
    /// — "click on speakers and multiselect to create a group"). Three routes
    /// reach it: the "+" button while devices are selected, Cmd-N with the same
    /// selection, and a speaker row's "New Group from Selection…" context item
    /// (which may carry the CLICKED row alone — see `menuNeedsUpdate`).
    public var onNewGroupFromSelection: (([String]) -> Void)?

    /// Resolves per-device icon overrides (set via the icon picker) so sidebar
    /// device rows show the same glyph as the popover/mixer. `nil` (the
    /// default) falls back to `Device.Kind.symbolName` — old behavior.
    public var deviceIconController: DeviceIconController?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton()
    private let warmSurfaceView: SidebarWarmSurfaceView

    /// Top-level nodes (the pinned Groups row, the hairline, then the two
    /// section headers). Rebuilt on `reload`.
    private var roots: [Node] = []

    /// Whether SOME saved group is the active Main Out, captured on `reload` —
    /// drives the small gold "playing" marker on the pinned Groups row. Gold is
    /// the LIVE color (Warm Signal §3.3) and the active group IS live, so this
    /// is the one place the sidebar may use it; with the groups themselves now
    /// in the content pane, this marker is all the sidebar can say about which
    /// one. Pure model state, never audio-driven.
    private var hasLiveGroup = false

    /// Whether a system sidebar material sits behind the warm wash for it to
    /// tint (T7, spec Q4-b). FALSE on every OS since the surface's split
    /// items became plain ones (`MixerWindowController` explains why): with
    /// no `.sidebar` behavior there is no automatic material — not even
    /// macOS 26+'s Liquid Glass — so the wash draws the opaque warm backing
    /// itself, the branch that always shipped below macOS 26. The parameter
    /// stays injectable because both drawing modes are still real and a test
    /// must be able to exercise either one directly.
    public init(rendersOnSystemSidebarMaterial: Bool = false) {
        self.warmSurfaceView = SidebarWarmSurfaceView(rendersOnGlass: rendersOnSystemSidebarMaterial)
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Keyboard focus (A11Y-GROUPS)
    //
    // Live-test finding: pressing Tab did NOTHING anywhere in the Groups
    // window. Root cause, confirmed by inspection: nothing in this window's
    // whole lifecycle — not `MixerWindowController.showWindow()`, not the
    // auto-select on launch, not any child controller — EVER calls
    // `NSWindow.makeFirstResponder(_:)` or sets `initialFirstResponder`
    // (verified: zero hits for either, or for `recalculateKeyViewLoop`,
    // anywhere in `AudioutWindowUI`/`AudioutApp`). A freshly-ordered-front
    // `NSWindow`'s first responder is the WINDOW ITSELF until something
    // explicitly claims it, and even programmatic selection
    // (`outlineView.selectRowIndexes(...)`, used by the auto-select and by
    // `select(_:notify:)`) does NOT promote the outline view to first
    // responder the way a real click does — only `NSTableView`'s own
    // `mouseDown:` does that. So Tab never had a real key view to advance
    // FROM. `viewDidAppear()` only fires once the window is genuinely on
    // screen (never under `swift test`/harness runs — those never order the
    // window front at all, see `HeadlessRuntime` / `../../AGENTS.md`), so
    // seeding here is safe unconditionally and costs nothing headless.
    //
    // The sidebar is the one control ALWAYS present regardless of which
    // content pane is showing (overview/editor/detail), so it's the natural
    // anchor: force AppKit to (re)compute the window's automatic key-view
    // loop (`autorecalculatesKeyViewLoop`, on by default for a window built
    // entirely in code, as this one is — but recalculation is reactive and
    // nothing here ever explicitly nudged it either) and claim first
    // responder for the outline view, the top-leading control.
    //
    // `ContentPaneHostViewController.setContent(_:)` re-seeds the key-view
    // loop after every pane swap (it re-parents the content hierarchy, which
    // invalidates the loop) — the swap-time half of this same fix.
    public override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        window.recalculateKeyViewLoop()
        if window.firstResponder === window {
            window.makeFirstResponder(outlineView)
        }
    }

    /// Put keyboard focus on the row list. The SANCTIONED second
    /// `makeFirstResponder` site (the seed above is the first): the group
    /// editor's Escape used to hand focus to `nil`, which is precisely the
    /// dead-Tab state A11Y-GROUPS fixed, so the host routes it here instead —
    /// the sidebar is the one control present whatever pane is showing.
    public func claimKeyboardFocus() {
        view.window?.makeFirstResponder(outlineView)
    }

    public override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        // Source-list appearance (SPEC §9): the documented modern API is the
        // `style` property (`selectionHighlightStyle = .sourceList` is deprecated
        // since macOS 12 — it points here). This applies the sidebar material,
        // full-width rows, and section-header styling.
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        // Medium row/icon size (design feedback 2026-07-18: `.default` felt
        // visually small next to the detail pane's large header icon).
        // `NSTableView.RowSizeStyle` alone only changes row HEIGHT — the icon
        // column's own width/height constraint (`Self.iconSize` below) still
        // has to be bumped to match, or the taller row just adds empty
        // padding around a still-small glyph.
        outlineView.rowSizeStyle = .medium
        outlineView.autosaveExpandedItems = false
        // Multi-select so the user can cmd/shift-click several speakers and make
        // a group from exactly those (SPEC.md §9). Headers stay non-selectable
        // via `shouldSelectItem`.
        outlineView.allowsMultipleSelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        // Right-click menu: one menu whose items are rebuilt per click, because
        // they depend on the CLICKED row (`menuNeedsUpdate`).
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outlineView.menu = contextMenu
        // No `doubleAction`: the only row that ever had one was a group row
        // (double-click to rename), and groups live on the overview's cards
        // now. A device row's first click already opened its detail pane, so
        // there is nothing left here for a second click to do.

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Bottom add bar with a labeled "New Group…" affordance — the standard
        // macOS source-list add control (SPEC.md §9), styled like Notes'
        // bottom-left "New Folder" button: borderless, system font, glyph +
        // title. Plain: new empty group. With devices selected: new group
        // from that selection.
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .recessed
        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.title = "New Group…"
        addButton.font = Tokens.Font.body
        addButton.target = self
        addButton.action = #selector(addTapped(_:))
        addButton.toolTip = "New Group…"
        addButton.setButtonType(.momentaryPushIn)

        let addBar = NSView()
        addBar.translatesAutoresizingMaskIntoConstraints = false
        addBar.addSubview(addButton)

        let container = SidebarContainerView()
        container.onCommandN = { [weak self] in self?.performAdd() }
        // The warm surface sits BEHIND everything else (glass tint on
        // macOS 26+, opaque warm fallback below) and BENEATH the outline
        // view (T7, spec Q4-b) — added first so it's the bottommost
        // subview, pinned to the container's full bounds so both the row
        // list and the add bar read as one warm surface. Non-interactive
        // (`hitTest` returns nil): it must never swallow a click meant for
        // a sidebar row or the add button.
        warmSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(warmSurfaceView)
        container.addSubview(scrollView)
        container.addSubview(addBar)

        NSLayoutConstraint.activate([
            warmSurfaceView.topAnchor.constraint(equalTo: container.topAnchor),
            warmSurfaceView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            warmSurfaceView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            warmSurfaceView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: addBar.topAnchor),

            addBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            addBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            addBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            addBar.heightAnchor.constraint(equalToConstant: 28),

            addButton.leadingAnchor.constraint(equalTo: addBar.leadingAnchor, constant: 8),
            addButton.centerYAnchor.constraint(equalTo: addBar.centerYAnchor),
            addButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        view = container
    }

    // MARK: Add / new-group actions

    /// The device ids currently selected in the source list (multi-selection),
    /// in row order. Groups/headers are excluded — only device rows count as
    /// group candidates.
    public var selectedDeviceIDs: [String] {
        outlineView.selectedRowIndexes.compactMap { row in
            guard let node = outlineView.item(atRow: row) as? Node,
                  case .device(let d) = node.payload else { return nil }
            return d.id
        }
    }

    @objc private func addTapped(_ sender: NSButton) {
        performAdd()
    }

    /// The single add path — the "+" button and Cmd-N both route here, so the
    /// two can't drift apart on what an empty vs. device selection creates.
    private func performAdd() {
        let selected = selectedDeviceIDs
        if selected.isEmpty {
            onAddGroup?()
        } else {
            onNewGroupFromSelection?(selected)
        }
    }

    /// Retitle the bottom-bar button to say what "+" will actually do — the
    /// multi-select → new-group path used to be completely invisible (nothing
    /// hinted that cmd-clicking speakers changes what the button creates).
    private func updateAddButtonTitle() {
        let count = selectedDeviceIDs.count
        let title = count >= 2 ? "New Group from \(count) Speakers…" : "New Group…"
        guard addButton.title != title else { return }
        addButton.title = title
        addButton.toolTip = title
    }

    // MARK: Context menu
    //
    // It acts on the CLICKED row, which is NOT always a selected one: standard
    // macOS arbitration is that a right-click inside the selection acts on the
    // whole selection and a right-click outside it acts on that row alone.
    // `NSTableView` sets `clickedRow` before it shows its menu, which is why
    // the items are rebuilt per click in `menuNeedsUpdate` rather than
    // assembled once at setup.

    /// The clicked row, injected. A headless run never right-clicks, so
    /// `outlineView.clickedRow` is permanently -1 there — this is the ONLY seam
    /// the menu/double-click hooks take; menu construction and dispatch below
    /// are the real ones.
    private var clickedRowOverride: Int?

    private var clickedNode: Node? {
        let row = clickedRowOverride ?? outlineView.clickedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? Node
    }

    private func contextMenuItem(_ title: String, _ action: Selector, _ represented: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        return item
    }

    /// Build the menu for `node` as if it had just been right-clicked. Shared by
    /// the live `outlineView.menu` path and the test hooks.
    private func contextMenu(clickedNode node: Node?) -> NSMenu {
        let menu = NSMenu()
        clickedRowOverride = node.map { outlineView.row(forItem: $0) } ?? -1
        defer { clickedRowOverride = nil }
        menuNeedsUpdate(menu)
        return menu
    }

    @objc private func newGroupFromSelectionMenuItemSelected(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String] else { return }
        onNewGroupFromSelection?(ids)
    }

    @objc private func newGroupMenuItemSelected(_ sender: NSMenuItem) {
        onAddGroup?()
    }

    // MARK: Model

    /// Rebuild the tree from the current devices and reload. Preserves the
    /// selection by `SidebarSelection` identity where possible.
    ///
    /// `groups` and `activeGroupID` still arrive because the pinned Groups row
    /// reports on them — the row shows the gold "playing" marker whenever one
    /// of the saved groups is the active Main Out — but NO group row is built
    /// any more (direction C): the cards in the content pane are the group
    /// list. Both sections are flat leaf lists, and the Speakers section lists
    /// EVERY device, grouped or not (hiding one here would just make it
    /// unreachable).
    public func reload(groups: [Group], activeGroupID: String?, devices: [Device]) {
        let previous = currentSelection
        hasLiveGroup = activeGroupID.map { id in groups.contains { $0.id == id } } ?? false

        var newRoots: [Node] = []

        // 1. The pinned Groups row — a root-level row rather than a one-item
        //    section: it is a doorway, not a category, and a header over a
        //    single row read as one more list to scan past. Its PLATE drawing
        //    (`PlateRowView`) is what divides it from the fleet below; the
        //    hairline row that used to do that job is gone with it.
        newRoots.append(Node(.groupsOverview))

        // 2. System Audio section — the whole mix, always present and never
        //    tied to a device: it is where the Main Audio page (and its
        //    Equalizer) is reached.
        newRoots.append(Node(.header("System Audio"), children: [Node(.mainOut)]))

        // 3. Speakers section — every device, grouped or not, so it stays
        //    reachable now that membership isn't previewed via expansion.
        if !devices.isEmpty {
            let devicesHeader = Node(.header("Speakers"))
            devicesHeader.children = devices.map { Node(.device($0)) }
            newRoots.append(devicesHeader)
        }

        roots = newRoots
        outlineView.reloadData()
        // Expand section headers so the tree reads as a flat source list.
        for root in roots { outlineView.expandItem(root) }

        // Restore selection if the same target still exists.
        if let previous { select(previous, notify: false) }
        updateAddButtonTitle()
    }

    // MARK: Selection

    /// The current `SidebarSelection`, or nil if nothing selectable is selected.
    public var currentSelection: SidebarSelection? {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? Node else { return nil }
        return selection(for: node)
    }

    private func selection(for node: Node) -> SidebarSelection? {
        switch node.payload {
        case .header: return nil
        case .groupsOverview: return .groupsOverview
        case .mainOut: return .mainOut
        case .device(let d): return .device(id: d.id)
        }
    }

    /// Programmatically select a target. Used to restore selection across reloads
    /// and by the test hooks. `notify` controls whether `onSelect` fires.
    ///
    /// A `.group` target lands on the pinned Groups ROW: the group's editor is
    /// pushed inside the content pane, and the fleet list must not move under
    /// the pointer while it is open (direction C).
    public func select(_ target: SidebarSelection, notify: Bool = true) {
        var target = target
        if case .group = target { target = .groupsOverview }
        // A target that no longer exists CLEARS the highlight. Returning
        // silently (which is what this did) left the old row drawn as selected
        // after the thing it named was deleted elsewhere — the source list
        // claiming a selection the window no longer has.
        guard let node = findNode(matching: target),
              case let row = outlineView.row(forItem: node), row >= 0 else {
            suppressSelectionCallback = !notify
            outlineView.deselectAll(nil)
            suppressSelectionCallback = false
            return
        }
        suppressSelectionCallback = !notify
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelectionCallback = false
    }

    private var suppressSelectionCallback = false

    private func findNode(matching target: SidebarSelection) -> Node? {
        func search(_ nodes: [Node]) -> Node? {
            for node in nodes {
                if selection(for: node) == target { return node }
                if let hit = search(node.children) { return hit }
            }
            return nil
        }
        return search(roots)
    }

    /// The non-selectable section header showing `title` — it carries no
    /// identity, so `findNode(matching:)` can't reach it.
    private func findNode(titled title: String) -> Node? {
        func search(_ nodes: [Node]) -> Node? {
            for node in nodes {
                if case .header(let t) = node.payload, t == title { return node }
                if let hit = search(node.children) { return hit }
            }
            return nil
        }
        return search(roots)
    }

    // MARK: Test-support hooks

    /// The section-header titles in order (["System Audio", "Speakers"]) — the
    /// pinned Groups row and its hairline sit ABOVE them and are not sections.
    public var test_sectionTitles: [String] {
        roots.compactMap { if case .header(let t) = $0.payload { return t } else { return nil } }
    }

    /// True when the pinned "Groups" row is present (it always is).
    public var test_hasGroupsRow: Bool {
        roots.contains { if case .groupsOverview = $0.payload { return true } else { return false } }
    }

    /// Whether the pinned Groups row currently renders the gold "playing"
    /// marker — built through the same delegate path a real reload uses.
    public var test_groupsRowShowsLiveMarker: Bool {
        guard let node = findNode(matching: .groupsOverview),
              let cell = self.outlineView(outlineView, viewFor: nil, item: node)
                  as? IconLabelCellView else { return false }
        return !cell.activeMarkerView.isHidden
    }

    /// Whether the pinned Groups row is the current selection — true while the
    /// overview shows AND while a group's editor is pushed over it.
    public var test_groupsRowIsSelected: Bool { currentSelection == .groupsOverview }

    /// Number of device rows under the "Speakers" header. Lists every device
    /// (grouped or not) since the flat model no longer previews membership
    /// via expansion.
    public var test_deviceRowCount: Int {
        test_deviceRowIDs.count
    }

    /// Device row ids under the "Speakers" header, in DISPLAY order — the
    /// order assertion seam (available first, unavailable at the bottom).
    public var test_deviceRowIDs: [String] {
        roots.first { if case .header("Speakers") = $0.payload { return true } else { return false } }?
            .children.compactMap {
                if case .device(let d) = $0.payload { return d.id } else { return nil }
            } ?? []
    }

    /// Simulate the user clicking a sidebar row (fires `onSelect`).
    public func test_select(_ target: SidebarSelection) {
        select(target, notify: true)
    }

    /// Simulate a multi-selection of device rows (cmd/shift-click), for the
    /// "New Group from Selection" gesture.
    public func test_selectDevices(_ ids: [String]) {
        var indexes = IndexSet()
        for id in ids {
            guard let node = findNode(matching: .device(id: id)) else { continue }
            let row = outlineView.row(forItem: node)
            if row >= 0 { indexes.insert(row) }
        }
        suppressSelectionCallback = true
        outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
        suppressSelectionCallback = false
        updateAddButtonTitle()
    }

    /// The device ids currently multi-selected (for asserts).
    public var test_selectedDeviceIDs: [String] { selectedDeviceIDs }

    /// The bottom-bar add button's current title — "New Group…" plain, "New
    /// Group from N Speakers…" while ≥2 speakers are multi-selected.
    public var test_addButtonTitle: String { addButton.title }

    /// Simulate clicking the "+" button (new empty group, or new-from-selection
    /// when devices are selected).
    public func test_tapAdd() {
        addTapped(addButton)
    }

    /// True when the outline view allows multi-selection (SPEC.md §9).
    public var test_allowsMultipleSelection: Bool { outlineView.allowsMultipleSelection }

    /// Titles of the context menu a right-click on `target`'s row produces —
    /// built through the real `menuNeedsUpdate` path with the clicked row
    /// injected, so clicked-vs-selected arbitration is exercised, not bypassed.
    public func test_contextMenuItems(for target: SidebarSelection) -> [String] {
        contextMenu(clickedNode: findNode(matching: target)).items.map(\.title)
    }

    /// Same, for the rows with no identity — the section headers, which must
    /// come back EMPTY.
    public func test_contextMenuItems(forRowTitled title: String) -> [String] {
        contextMenu(clickedNode: findNode(titled: title)).items.map(\.title)
    }

    /// Right-click `target`, then choose the item titled `title`. Dispatched
    /// through the real `NSMenuItem` target/action (`performActionForItem`),
    /// never a bypass seam. False when that row's menu has no such item.
    @discardableResult
    public func test_clickContextMenuItem(_ title: String, for target: SidebarSelection) -> Bool {
        let menu = contextMenu(clickedNode: findNode(matching: target))
        guard let index = menu.items.firstIndex(where: { $0.title == title }) else { return false }
        menu.performActionForItem(at: index)
        return true
    }

    /// Press Cmd-N in the sidebar — a real `NSEvent` through the real
    /// `performKeyEquivalent` chain. True when the sidebar claimed it.
    @discardableResult
    public func test_performCmdN() -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: .command, timestamp: 0,
                                           windowNumber: 0, context: nil,
                                           characters: "n", charactersIgnoringModifiers: "n",
                                           isARepeat: false, keyCode: 45) else { return false }
        return view.performKeyEquivalent(with: event)
    }

    /// Drive the real `viewDidAppear()` lifecycle override directly (A11Y-GROUPS)
    /// — a headless run never orders the window on screen, so AppKit never calls
    /// this itself; this hook exercises the exact same method a live window
    /// appearing would call.
    public func test_simulateViewDidAppear() { viewDidAppear() }

    /// True when the outline view is the hosting window's current first
    /// responder (A11Y-GROUPS: asserts the Tab-traversal seed in
    /// `viewDidAppear()` actually claimed it).
    public var test_isOutlineViewFirstResponder: Bool {
        view.window?.firstResponder === outlineView
    }

    // MARK: Test-support hooks (T7 — warm sidebar surface, Q4-b)

    /// True on macOS 26+ (per the injected seam): the sidebar's automatic
    /// Liquid Glass is left in place and this is the LOW-ALPHA warm wash
    /// drawn on top of it. Mutually exclusive with
    /// ``test_hasFallbackBacking``.
    public var test_hasTintOverlay: Bool { warmSurfaceView.rendersOnGlass }

    /// True below macOS 26 (per the injected seam): there is no automatic
    /// glass to tint, so this is the OPAQUE warm backing standing in for it.
    /// Mutually exclusive with ``test_hasTintOverlay``.
    public var test_hasFallbackBacking: Bool { !warmSurfaceView.rendersOnGlass }

    /// The alpha the wash actually draws at: the 26+ tint overlay's low
    /// alpha, or 1 on the pre-26 opaque fallback — AND on the glass branch
    /// while Reduce Transparency is on (A1: the wash promotes itself to the
    /// opaque backing).
    public var test_warmSurfaceAlpha: CGFloat { warmSurfaceView.effectiveAlpha }

    /// `nil` = read the live Reduce Transparency setting; tests pin both
    /// sides of the wash's opaque promotion with this.
    public var test_reduceTransparencyOverride: Bool? {
        get { warmSurfaceView.test_reduceTransparencyOverride }
        set { warmSurfaceView.test_reduceTransparencyOverride = newValue }
    }
}

/// A sidebar row cell with two trailing slots: a small gold
/// `speaker.wave.2.fill` "playing" marker, shown ONLY on the pinned Groups row
/// while some saved group is the active Main Out, and a tertiary
/// `chevron.right` saying the row leads somewhere (the Groups row alone). Gold
/// = LIVE (Warm Signal §3.3) and the active group is genuinely live, so this is
/// the sidebar's one sanctioned use of it; `Tokens.Color.gold` is an instrument
/// — it keeps its authored value in every theme.
///
/// Both slots live in an `NSStackView`, which DETACHES hidden arranged
/// subviews: a device row, where both are hidden, gets its full label width
/// back instead of reserving trailing space it never uses ("MacBook Pro
/// Speakers" is already the name this 210 pt sidebar barely fits). Internal
/// (not file-private) so the controller's test hook can read the marker.
final class IconLabelCellView: NSTableCellView {
    /// The trailing marker, hidden by default; `setActiveMarkerVisible` shows it.
    let activeMarkerView: NSImageView = {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                          accessibilityDescription: "Playing now")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        v.image?.isTemplate = true
        v.contentTintColor = Tokens.Color.gold
        v.toolTip = "Playing now"
        v.isHidden = true
        v.setContentHuggingPriority(.required, for: .horizontal)
        return v
    }()

    /// The trailing disclosure chevron — drawing only, and never an AX element:
    /// the row itself is what VoiceOver announces and activates.
    let disclosureView: NSImageView = {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        v.image?.isTemplate = true
        v.contentTintColor = Tokens.Color.inkTertiary
        v.isHidden = true
        v.setAccessibilityElement(false)
        v.setContentHuggingPriority(.required, for: .horizontal)
        return v
    }()

    /// Holds both trailing slots. `detachesHiddenViews` (the default) is what
    /// makes a hidden slot cost zero width.
    let trailingStack: NSStackView = {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }()

    func setActiveMarkerVisible(_ visible: Bool) {
        activeMarkerView.isHidden = !visible
    }

    func setDisclosureVisible(_ visible: Bool) {
        disclosureView.isHidden = !visible
    }
}

/// The pinned Groups row's row view: a raised plate with a hairline edge —
/// `GroupedSectionView`'s `.card` surface vocabulary at row scale, promising
/// the pane of cards the row opens. Drawn (not a layer colour) so the `Tokens`
/// fills re-resolve live per appearance flip and Increase Contrast on every
/// paint, same rule as `HairlineView`.
///
/// **Never two shapes: the plate and the selection take turns.** Selected, the
/// row draws nothing and the source list's own pill stands alone; unselected,
/// the plate stands alone — on the SAME footprint, so the swap doesn't jump.
///
/// TRAP: under `NSTableView.style = .sourceList` that pill is not the row
/// view's to suppress — neither a `drawSelection(in:)` override nor pinning
/// `selectionHighlightStyle` to `.none` stops it (both measured against
/// rendered pixels, 2026-08-27). Drawing the plate at any other inset stacks
/// the two: the pill covers the middle and the plate's corners peek out at
/// both ends as stray arcs. That is the bug this rule exists to prevent.
final class PlateRowView: NSTableRowView {
    /// Plate row height: the `.medium` source-list row plus breathing room, so
    /// the raised fill reads as a surface rather than a selection artifact.
    static let rowHeight: CGFloat = 36
    /// The source list's own selection-pill inset, measured off a rendered
    /// pill. The plate borrows it so the two footprints coincide: matching
    /// shapes are what keep the swap below from jumping.
    private static let selectionInsetX: CGFloat = 10

    /// Half-point inset so the 1 pt stroke lands on whole pixels.
    private var platePath: NSBezierPath {
        let rect = bounds.insetBy(dx: Self.selectionInsetX + 0.5, dy: 0.5)
        let radius = Tokens.Layout.groupedSectionCornerRadius - 2
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        // Selected: the pill IS the plate. Drawing under a shape that already
        // covers this rect only stacks a second rounded rect behind it.
        guard !isSelected else { return }
        let path = platePath
        Tokens.Color.raised.setFill()
        path.fill()
        Tokens.Color.hairline.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// A row view that draws its own background is NOT redisplayed when
    /// selection changes — without this the plate survives under the pill.
    override var isSelected: Bool { didSet { needsDisplay = true } }
}

/// The sidebar's container view. Exists only to catch Cmd-N: key equivalents
/// are dispatched DOWN THE VIEW TREE (the window asks its content view, which
/// asks each subview), not along the responder chain, so an `NSViewController`
/// override would never be called — it has to be a view.
///
/// razor: a view-local key equivalent is the ceiling. The Groups screen is
/// hosted in the menu-bar surface and has no menu bar of its own, so Cmd-N
/// works while the sidebar's tree is in the key window and nowhere else, and
/// no UI can advertise the shortcut. Upgrade path: a real "New Group…" item in
/// the app's main menu, which would both widen the scope and print the ⌘N.
private final class SidebarContainerView: NSView {

    /// Runs the add path (`SidebarViewController.performAdd`). Set at build time.
    var onCommandN: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A FIELD EDITOR wins. Key equivalents are dispatched down the view
        // tree before the responder chain sees the key, so this view claimed
        // ⌘N even while the user was typing in a text field somewhere in the
        // window — swallowing whatever that field's own ⌘N would mean.
        if let textView = window?.firstResponder as? NSTextView, textView.isFieldEditor {
            return super.performKeyEquivalent(with: event)
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "n",
           let handler = onCommandN {
            handler()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - NSMenuDelegate (row context menu)

extension SidebarViewController: NSMenuDelegate {

    /// Rebuilt per right-click: which items exist, and what they act on, both
    /// depend on the clicked row.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Nothing validates these items, so AppKit must not be left to enable
        // them (`autoenablesItems` would disable every one without a validator).
        menu.autoenablesItems = false
        guard let node = clickedNode else { return }
        switch node.payload {
        case .header, .mainOut:
            break   // no identity to act on — an empty menu shows nothing at all
        case .groupsOverview:
            // The overview's one action. Rename…/Delete Group… moved to the
            // cards with the groups themselves.
            menu.addItem(contextMenuItem("New Group…",
                                         #selector(newGroupMenuItemSelected(_:)), ""))
        case .device(let device):
            // Clicked inside the multi-selection → the whole selection; clicked
            // outside it → that one row (macOS arbitration).
            let selected = selectedDeviceIDs
            let ids = selected.contains(device.id) ? selected : [device.id]
            // Say what it will act on. "…from Selection…" named nothing, on
            // the one menu whose target changes with where you clicked; a
            // single id is always the clicked row, so it can be named outright
            // (the bottom bar's retitle already uses the plural form).
            let title = ids.count == 1
                ? "New Group from \u{201C}\(device.name)\u{201D}\u{2026}"
                : "New Group from \(ids.count) Speakers\u{2026}"
            menu.addItem(contextMenuItem(title,
                                         #selector(newGroupFromSelectionMenuItemSelected(_:)), ids))
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return roots.count }
        return node.children.count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return roots[index] }
        return node.children[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node).map { !$0.children.isEmpty } ?? false
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {

    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        if case .header = node.payload { return true }
        return false
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // Section headers aren't selectable (source-list convention).
        return !self.outlineView(outlineView, isGroupItem: item)
    }

    /// The Groups row alone is taller: its plate needs air around the label or
    /// the raised fill reads as a selection artifact, not a surface.
    public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if let node = item as? Node, case .groupsOverview = node.payload {
            return PlateRowView.rowHeight
        }
        return outlineView.rowHeight
    }

    /// The Groups row rides a `PlateRowView` — the raised + hairline "card"
    /// surface vocabulary (`GroupedSectionView`'s `.card`), at row scale. It is
    /// the visual promise of what the row opens: a pane of cards.
    public func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let node = item as? Node, case .groupsOverview = node.payload else { return nil }
        let id = NSUserInterfaceItemIdentifier("groupsPlateRow")
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? PlateRowView {
            return reused
        }
        let row = PlateRowView()
        row.identifier = id
        return row
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        switch node.payload {
        case .header(let title):
            return makeHeaderLabel(title)
        case .groupsOverview:
            return makeIconLabel(symbol: Group.defaultIconSymbolName,
                                 text: "Groups", identifier: "groupsOverview",
                                 showsActiveMarker: hasLiveGroup,
                                 showsDisclosure: true,
                                 emphasized: true)
        case .mainOut:
            return makeIconLabel(symbol: DeviceIcon.mainAudioSymbolName,
                                 text: "Main Audio", identifier: "mainOut")
        case .device(let device):
            let symbol = deviceIconController?.symbolName(for: device) ?? device.kind.symbolName
            return makeIconLabel(symbol: symbol,
                                 text: device.name, identifier: "device",
                                 dimmed: !device.isAvailable)
        }
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        // The add button's title tracks the REAL selection, callback
        // suppression or not — a programmatic restore must retitle it too.
        updateAddButtonTitle()
        guard !suppressSelectionCallback else { return }
        onSelect?(currentSelection)
    }

    // MARK: Cell builders

    /// Section header cell ("Groups" / "Speakers") — a DIFFERENT cell shape
    /// from `makeLabel`/`newCell` on purpose (design feedback 2026-07-18c):
    /// Finder's own sidebar headers sit flush-left with the ICON column
    /// below them, not indented to the item TEXT column, and render slightly
    /// bolder than a plain label. Reusing `newCell`'s icon+text layout (text
    /// anchored past `imageView.trailingAnchor`) was what misaligned this —
    /// headers need their own cell with the text pinned straight to
    /// `cell.leadingAnchor`.
    private func makeHeaderLabel(_ text: String) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("header")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? Self.newHeaderCell(identifier: id)
        cell.textField?.stringValue = text
        return cell
    }

    private static func newHeaderCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        // Matches Finder's own sidebar section-header weight — a plain
        // `NSTextField(labelWithString:)` label reads noticeably thinner.
        textField.font = Tokens.Font.captionEmphasized
        textField.textColor = Tokens.Color.secondaryLabel
        textField.lineBreakMode = .byTruncatingTail
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            // Flush with the ICON column start below it — NOT offset past an
            // icon width like an item row's text (that offset is what made
            // "Speakers" read as indented relative to the device icons under it).
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeIconLabel(symbol: String, text: String, identifier: String,
                               dimmed: Bool = false, showsActiveMarker: Bool = false,
                               showsDisclosure: Bool = false,
                               emphasized: Bool = false) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? IconLabelCellView
            ?? Self.newCell(identifier: id)
        // Only the Groups plate takes the emphasized weight; the fleet rows
        // keep the source list's own font. Reuse-safe without an else branch:
        // cells are pooled per identifier, and "groupsOverview" is the only
        // pool that ever asks for it.
        if emphasized { cell.textField?.font = Tokens.Font.bodyEmphasized }
        cell.imageView?.isHidden = false
        // The icon is DECORATIVE: the text field beside it speaks the row, and
        // a description here made VoiceOver read the name twice (the detail
        // pane's group rows already pass nil for the same reason). CACHED and
        // SHARED — never mutate it; the tint below is a view property.
        //
        // Force flat monochrome rendering (design feedback 2026-07-18: some SF
        // Symbols default to a lighter hierarchical secondary tone, which read
        // as an unwanted "highlight" on the glyph) — a single, controlled dark
        // fill instead, via `.isTemplate` (which `DeviceIcon.image` sets) plus
        // an explicit `contentTintColor`.
        cell.imageView?.image = DeviceIcon.image(symbol)
        cell.imageView?.contentTintColor = dimmed ? Tokens.Color.inkTertiary : Tokens.Color.label
        cell.textField?.stringValue = text
        cell.textField?.textColor = dimmed ? Tokens.Color.inkTertiary : Tokens.Color.label
        cell.setActiveMarkerVisible(showsActiveMarker)
        cell.setDisclosureVisible(showsDisclosure)
        // Both states were COLOUR/GLYPH ONLY: a dimmed row and a gold marker
        // say nothing to VoiceOver. Same words the visible UI uses
        // ("Unavailable" annotation, "Playing now" marker/tooltip). Set on
        // EVERY pass, unconditionally — cells are reused, so a conditional set
        // would leave the previous row's suffix on this one.
        let spoken = text
            + (dimmed ? ", unavailable" : "")
            + (showsActiveMarker ? ", playing now" : "")
        cell.textField?.setAccessibilityLabel(spoken)
        return cell
    }

    /// Icon side length matching the outline view's `.medium` `rowSizeStyle`
    /// (design feedback 2026-07-18: 18pt read as visually small next to the
    /// detail pane's large header icon).
    private static let iconSize: CGFloat = SurfaceLayout.sidebarIconSize

    private static func newCell(identifier: NSUserInterfaceItemIdentifier) -> IconLabelCellView {
        let cell = IconLabelCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.imageView = imageView

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        cell.addSubview(textField)
        cell.textField = textField

        cell.trailingStack.setViews([cell.activeMarkerView, cell.disclosureView], in: .leading)
        cell.addSubview(cell.trailingStack)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: iconSize),
            imageView.heightAnchor.constraint(equalToConstant: iconSize),

            textField.leadingAnchor.constraint(
                equalTo: imageView.trailingAnchor, constant: SurfaceLayout.sidebarIconToLabelGap),
            textField.trailingAnchor.constraint(
                lessThanOrEqualTo: cell.trailingStack.leadingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            cell.trailingStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            cell.trailingStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
