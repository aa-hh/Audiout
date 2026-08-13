// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// What the user selected in the sidebar. Drives which detail pane the window
/// shows (a group → its editor; a device → its detail pane; nothing → auto-select).
public enum SidebarSelection: Equatable, Sendable {
    case group(id: String)
    case device(id: String)
}

/// The mixer window's sidebar (SPEC §9 "Sidebar list": source-list
/// `NSOutlineView`).
///
/// Two top-level sections — **Groups** and **Speakers** — exactly the "Groups"
/// / "Speakers" split the editor and creation sheet use, in the documented
/// source-list style (`selectionHighlightStyle = .sourceList`, header rows via
/// `isGroupItem`). Both sections are FLAT: a group row is a single leaf row
/// (icon + name, same icon column as a device row) with no disclosure
/// chevron and no child device rows — previewing a group's members happens in
/// the group editor's own "Speakers" checklist, not by expanding the sidebar
/// row, so nesting here was pure duplication (design review 2026-07-18). The
/// Speakers section draws exactly the devices the host hands it, in the order
/// it hands them over — which speakers those are (a fleet with previously-
/// paired Bluetooth clutter hidden, or all of them) is the host's decision,
/// not this list's. Selection is reported through `onSelect`.
///
/// The outline model is still a small tree of reference-typed `Node`s (one
/// level: section header → leaf rows) so the `NSOutlineViewDataSource`
/// identity methods are stable across reloads and the source-list header
/// styling (`isGroupItem`) keeps working; `NSOutlineView` with zero-depth
/// leaves is simpler here than switching containers, since header
/// vibrancy/appearance still requires it.
public final class SidebarViewController: NSViewController {

    /// A node in the source-list tree. Reference type so `NSOutlineView` can key
    /// on object identity.
    final class Node {
        enum Payload {
            case header(String)             // "Groups" / "Speakers" (isGroupItem)
            case group(Group)               // a saved group (flat leaf row)
            case device(Device)             // a device row (flat leaf row)
            case emptyState(String)         // non-selectable placeholder row (e.g. "No groups yet")
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

    /// Called when the user asks to rename the group with this id — a group
    /// row's "Rename…" context item or a double-click on the row. The sidebar
    /// selects that group first, so the host can put focus straight on the
    /// editor's rename field; it owns no rename UI itself.
    public var onRequestRename: ((String) -> Void)?

    /// Called when the user chooses a group row's "Delete Group…" context item.
    /// Confirmation and the delete itself belong to the host — this only
    /// reports the request.
    public var onRequestDelete: ((String) -> Void)?

    /// Called when the user asks to hide (or unhide) the speaker with this id.
    /// The host owns the hidden set and its persistence; the sidebar only
    /// reports the request and renders whatever comes back on the next
    /// `reload`.
    public var onToggleSpeakerHidden: ((String) -> Void)?

    /// Called when the user picks "Show Hidden Speakers" — the host flips its
    /// transient reveal state and reloads.
    public var onToggleShowHiddenSpeakers: (() -> Void)?

    /// Resolves per-device icon overrides (set via the icon picker) so sidebar
    /// device rows show the same glyph as the popover/mixer. `nil` (the
    /// default) falls back to `Device.Kind.symbolName` — old behavior.
    public var deviceIconController: DeviceIconController?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton()
    private let warmSurfaceView: SidebarWarmSurfaceView

    /// Top-level nodes (the two section headers). Rebuilt on `reload`.
    private var roots: [Node] = []

    /// The active Main Out group's id, captured on `reload` — drives the small
    /// gold "playing" marker on that group's row. Gold is the LIVE color
    /// (Warm Signal §3.3), and the active group IS live, so this is the one
    /// place the sidebar may use it. Pure model state, never audio-driven.
    private var activeGroupID: String?

    /// The hidden speakers among the CURRENT fleet, captured on `reload`. Two
    /// jobs: a row for one of these ids is a revealed hidden row (drawn muted,
    /// and its menu offers "Unhide"), and a non-empty set is what puts the
    /// "Show Hidden Speakers" toggle on the menus at all. The host passes the
    /// hidden ids it can still see, never its whole saved set, so the count in
    /// that title only ever promises rows this list can actually produce.
    private var hiddenDeviceIDs: Set<String> = []

    /// Whether THIS OS renders the sidebar's automatic Liquid Glass (macOS
    /// 26+) — the injected seam T7 needs (spec Q4-b: warm tint on 26+, opaque
    /// warm fallback below). Never read via a bare `#available` on the
    /// drawing path itself; both branches must be exercisable from a test
    /// regardless of the machine the suite runs on (this box is macOS 27, so
    /// without this seam the `< 26` fallback would be untestable here). Same
    /// injection shape as `SetupModel.osGatesLocalNetwork`/`localNetworkGated`
    /// — a static real-OS-value property, injected through a defaulted init
    /// parameter so existing `SidebarViewController()` call sites (e.g.
    /// `MixerWindowController`) are unaffected, and a test can construct
    /// either branch directly.
    public static var osSupportsLiquidGlassSidebar: Bool {
        if #available(macOS 26, *) { return true } else { return false }
    }

    public init(osSupportsLiquidGlassSidebar: Bool = SidebarViewController.osSupportsLiquidGlassSidebar) {
        self.warmSurfaceView = SidebarWarmSurfaceView(rendersOnGlass: osSupportsLiquidGlassSidebar)
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
    // anywhere in `AudiouterWindowUI`/`AudiouterApp`). A freshly-ordered-front
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
    // content pane is showing (editor/detail/empty), so it's the natural
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
        // Double-click a group row = rename. `doubleAction` fires after the
        // single click has already moved the selection.
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked(_:))

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

    // MARK: Context menu / double-click
    //
    // Both act on the CLICKED row, which is NOT always a selected one: standard
    // macOS arbitration is that a right-click inside the selection acts on the
    // whole selection and a right-click outside it acts on that row alone.
    // `NSTableView` sets `clickedRow` before it shows its menu and before
    // `doubleAction` fires, which is why the items are rebuilt per click in
    // `menuNeedsUpdate` rather than assembled once at setup.

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

    @objc private func renameGroupMenuItemSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // Select first: the rename field lives in that group's editor, so the
        // host has nothing to focus until the selection has swapped it in.
        select(.group(id: id), notify: true)
        onRequestRename?(id)
    }

    @objc private func deleteGroupMenuItemSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onRequestDelete?(id)
    }

    @objc private func newGroupFromSelectionMenuItemSelected(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String] else { return }
        onNewGroupFromSelection?(ids)
    }

    @objc private func toggleSpeakerHiddenMenuItemSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onToggleSpeakerHidden?(id)
    }

    @objc private func toggleShowHiddenSpeakersMenuItemSelected(_ sender: NSMenuItem) {
        onToggleShowHiddenSpeakers?()
    }

    /// A device row's double-click does nothing on purpose: the first click
    /// already opened its (read-only) detail pane, so there is nothing further
    /// to open.
    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard let node = clickedNode, case .group(let group) = node.payload else { return }
        onRequestRename?(group.id)
    }

    // MARK: Model

    /// Rebuild the tree from the current groups + devices and reload. Preserves
    /// the selection by `SidebarSelection` identity where possible.
    ///
    /// Both sections are flat leaf lists (design review 2026-07-18): a group
    /// row never carries member-device children, and membership is never
    /// previewed by expansion. `activeGroupID` filters nothing; it marks the
    /// active group's row with the gold "playing" indicator so the user can
    /// tell which group is live without clicking through each one.
    ///
    /// `devices` is exactly the rows to draw — the host decides which speakers
    /// the user has hidden and in what order they come. `hiddenDeviceIDs` is
    /// the hidden ids among the fleet the host knows about, whether or not
    /// their rows are in `devices` right now; see the property.
    public func reload(groups: [Group], activeGroupID: String?, devices: [Device],
                       hiddenDeviceIDs: Set<String> = []) {
        let previous = currentSelection
        self.activeGroupID = activeGroupID
        self.hiddenDeviceIDs = hiddenDeviceIDs

        var newRoots: [Node] = []

        // 1. Groups section — always shown (this window is groups-configuration
        //    only). Zero groups gets a non-selectable "No groups yet"
        //    placeholder row instead of vanishing. Each group is a flat leaf
        //    row (icon + name); members are previewed in the group editor's
        //    own checklist, not here.
        let groupsHeader = Node(.header("Groups"))
        if groups.isEmpty {
            groupsHeader.children = [Node(.emptyState("No groups yet"))]
        } else {
            groupsHeader.children = groups.map { Node(.group($0)) }
        }
        newRoots.append(groupsHeader)

        // 2. Speakers section — whatever the host handed over, grouped or not.
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
        case .header, .emptyState: return nil
        case .group(let g): return .group(id: g.id)
        case .device(let d): return .device(id: d.id)
        }
    }

    /// Programmatically select a target. Used to restore selection across reloads
    /// and by the test hooks. `notify` controls whether `onSelect` fires.
    public func select(_ target: SidebarSelection, notify: Bool = true) {
        guard let node = findNode(matching: target) else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
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

    /// The rows under the "Speakers" header, in row order.
    private var deviceNodes: [Node] {
        roots.first { if case .header("Speakers") = $0.payload { return true } else { return false } }?
            .children ?? []
    }

    /// The non-selectable row (a section header or the "No groups yet"
    /// placeholder) showing `title` — the rows that carry no identity, so
    /// `findNode(matching:)` can't reach them.
    private func findNode(titled title: String) -> Node? {
        func search(_ nodes: [Node]) -> Node? {
            for node in nodes {
                switch node.payload {
                case .header(let t) where t == title: return node
                case .emptyState(let t) where t == title: return node
                default: break
                }
                if let hit = search(node.children) { return hit }
            }
            return nil
        }
        return search(roots)
    }

    // MARK: Test-support hooks

    /// The section-header titles in order (e.g. ["Groups", "Speakers"]).
    public var test_sectionTitles: [String] {
        roots.compactMap { if case .header(let t) = $0.payload { return t } else { return nil } }
    }

    /// True when the "Groups" header's only child is the "No groups yet"
    /// non-selectable placeholder row (i.e. there are zero saved groups).
    public var test_hasGroupsEmptyStateRow: Bool {
        guard let groupsHeader = roots.first(where: {
            if case .header("Groups") = $0.payload { return true } else { return false }
        }) else { return false }
        return groupsHeader.children.contains {
            if case .emptyState = $0.payload { return true } else { return false }
        }
    }

    /// Number of group rows under the "Groups" header (excludes the "no groups
    /// yet" placeholder row). Each is a flat leaf row — no member children.
    public var test_groupRowCount: Int {
        roots.first { if case .header("Groups") = $0.payload { return true } else { return false } }?
            .children.filter {
                if case .group = $0.payload { return true } else { return false }
            }.count ?? 0
    }

    /// Number of device rows under the "Speakers" header.
    public var test_deviceRowCount: Int { deviceNodes.count }

    /// The device ids under the "Speakers" header, in row order.
    public var test_deviceRowIDs: [String] {
        deviceNodes.compactMap {
            if case .device(let device) = $0.payload { return device.id } else { return nil }
        }
    }

    /// True when the device row for `id` renders muted — a speaker that is
    /// unavailable, or a hidden one currently revealed. Built through the same
    /// delegate path a real reload uses.
    public func test_deviceRowIsDimmed(id: String) -> Bool {
        guard let node = findNode(matching: .device(id: id)),
              let cell = self.outlineView(outlineView, viewFor: nil, item: node) as? NSTableCellView
        else { return false }
        return cell.textField?.textColor == .disabledControlTextColor
    }

    /// True when every group row has no expandable children (flat model:
    /// selecting a group opens its editor, it never discloses member rows).
    public var test_groupRowsAreFlat: Bool {
        guard let groupsHeader = roots.first(where: {
            if case .header("Groups") = $0.payload { return true } else { return false }
        }) else { return true }
        return groupsHeader.children.allSatisfy { node in
            if case .group = node.payload { return node.children.isEmpty }
            return true
        }
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

    /// Whether the group row for `id` currently renders the gold "playing"
    /// marker — built through the same delegate path a real reload uses.
    public func test_groupRowShowsActiveMarker(id: String) -> Bool {
        guard let node = findNode(matching: .group(id: id)),
              let cell = self.outlineView(outlineView, viewFor: nil, item: node)
                  as? IconLabelCellView else { return false }
        return !cell.activeMarkerView.isHidden
    }

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

    /// Same, for the rows with no identity — the section headers and the "No
    /// groups yet" placeholder. Both must come back EMPTY.
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

    /// Same, for a row with no identity (the section headers / the "No groups
    /// yet" placeholder).
    @discardableResult
    public func test_clickContextMenuItem(_ title: String, forRowTitled rowTitle: String) -> Bool {
        let menu = contextMenu(clickedNode: findNode(titled: rowTitle))
        guard let index = menu.items.firstIndex(where: { $0.title == title }) else { return false }
        menu.performActionForItem(at: index)
        return true
    }

    /// The `NSControl.StateValue` of the context item titled `title` on
    /// `target`'s row — `.on` while the reveal toggle is active.
    public func test_contextMenuItemState(_ title: String,
                                          for target: SidebarSelection) -> NSControl.StateValue? {
        contextMenu(clickedNode: findNode(matching: target))
            .items.first { $0.title == title }?.state
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

    /// Double-click a row (a group row asks for rename; a device row does
    /// nothing).
    public func test_doubleClick(_ target: SidebarSelection) {
        clickedRowOverride = findNode(matching: target).map { outlineView.row(forItem: $0) } ?? -1
        defer { clickedRowOverride = nil }
        rowDoubleClicked(outlineView)
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

/// A sidebar row cell with a trailing "playing" marker slot: a small gold
/// `speaker.wave.2.fill` glyph shown ONLY on the active Main Out group's row.
/// Gold = LIVE (Warm Signal §3.3) and the active group is genuinely live, so
/// this is the sidebar's one sanctioned use of it. `Tokens.Color.gold` is an
/// instrument — it keeps its authored value in every theme. Internal (not
/// file-private) so the controller's test hook can read the marker.
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

    func setActiveMarkerVisible(_ visible: Bool) {
        activeMarkerView.isHidden = !visible
    }
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
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "n",
           let handler = onCommandN {
            handler()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The Groups window sidebar's warm surface (T7, spec Q4-b): a non-
/// interactive view sitting between the sidebar's system material and the
/// outline view. On macOS 26+ the automatic Liquid Glass sidebar material
/// (applied by `NSSplitViewItem(sidebarWithViewController:)` outside this
/// controller's own view — there is no public API to tint it directly) is
/// left completely alone; this draws a LOW-ALPHA warm wash on top of it.
/// Below macOS 26 there is no glass to tint at all, so this draws the SAME
/// color fully opaque as the sidebar's whole backing. Reduce Transparency
/// promotes the 26+ wash to that same opaque backing too — see
/// ``effectiveAlpha``.
///
/// Deliberately NOT drawn by setting `outlineView.backgroundColor` —
/// `NSTableView.h`'s `NSTableViewStyleSourceList` doc comment states that
/// moving a source-list table's background color off the system "source
/// list" color drops the blur/vibrant selection-highlight style entirely.
/// This view is a separate layer behind the (untouched) outline view instead.
private final class SidebarWarmSurfaceView: NSView {

    /// Whether THIS instance renders atop Apple's automatic glass (true) or
    /// stands in as the opaque fallback (false) — set once at init from the
    /// controller's injected seam value, never re-read live (the OS version
    /// a process runs under doesn't change mid-session).
    let rendersOnGlass: Bool

    /// The 26+ overlay's alpha — a taste dial, to be judged live against
    /// real glass. The plan's original 0.06–0.10 band was ARITHMETICALLY
    /// TOO WEAK to do the job: the sidebar's base grey is a perfectly
    /// neutral `#F0F0F0`, and `sidebarWarmTint` carries a 22-unit red-to-
    /// blue spread, so an 0.08 wash shifts it by ~2 units — invisible. The
    /// warm cast has to be comparable to the content pane's own (`panel`
    /// `#FBF8F2` spreads 9 units), which needs `22 × alpha ≈ 9`, i.e. ~0.4;
    /// 0.30 sits just under that so the sidebar reads warm without
    /// out-warming the pane it sits beside. Chosen deliberately high rather
    /// than low: dialing DOWN from a visible wash is far easier to judge by
    /// eye than nudging up from no perceptible change.
    static let tintAlpha: CGFloat = 0.30

    /// `nil` = read the live `accessibilityDisplayShouldReduceTransparency`.
    /// Tests drive both sides of the opaque promotion with this.
    var test_reduceTransparencyOverride: Bool? {
        didSet { needsDisplay = true }
    }

    /// The alpha ``draw(_:)`` actually uses. On the 26+ glass branch, Reduce
    /// Transparency promotes the wash to the SAME fully-opaque backing the
    /// pre-26 fallback draws — the system flattens its glass underneath, and
    /// a translucent tint over whatever it flattens to would still read as
    /// transparency (A1). The pre-26 branch is already opaque.
    var effectiveAlpha: CGFloat {
        let reduceTransparency = test_reduceTransparencyOverride
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        return (rendersOnGlass && !reduceTransparency) ? Self.tintAlpha : 1
    }

    init(rendersOnGlass: Bool) {
        self.rendersOnGlass = rendersOnGlass
        super.init(frame: .zero)
        wantsLayer = true
        // Reconcile live on a mid-session Reduce Transparency / Increase
        // Contrast toggle (`AudiouterSharedUI/AGENTS.md`'s instrument rule —
        // neither arrives through this view's own lifecycle otherwise).
        // `draw(_:)` re-reads both flags per repaint via `effectiveAlpha`,
        // so the invalidation is all the reconciliation needed.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Never intercepts a click meant for a sidebar row or the add button —
    /// this view exists purely to paint a tint underneath them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isFlipped: Bool { false }

    @objc private func accessibilityDisplayOptionsDidChange() {
        needsDisplay = true
    }

    /// A light/dark appearance flip re-resolves `Tokens.Color.sidebarWarmTint`
    /// (its dynamic provider reads `effectiveAppearance` at draw time), so
    /// this just needs to trigger the repaint.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let base = Tokens.Color.sidebarWarmTint
        let alpha = effectiveAlpha
        let color = alpha < 1 ? base.withAlphaComponent(alpha) : base
        color.setFill()
        bounds.fill()
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
        case .header("Speakers"):
            // The section's own row carries no identity, but it is the one
            // place to get hidden speakers back once the last visible row's
            // menu is out of reach.
            addShowHiddenSpeakersItem(to: menu)
        case .header, .emptyState:
            break   // no identity to act on — an empty menu shows nothing at all
        case .group(let group):
            menu.addItem(contextMenuItem("Rename…",
                                         #selector(renameGroupMenuItemSelected(_:)), group.id))
            // No destructive styling: `NSMenuItem` has no equivalent of
            // `hasDestructiveAction`, and the confirmation the delete goes
            // through is the host's, not this menu's.
            menu.addItem(contextMenuItem("Delete Group…",
                                         #selector(deleteGroupMenuItemSelected(_:)), group.id))
        case .device(let device):
            // Clicked inside the multi-selection → the whole selection; clicked
            // outside it → that one row (macOS arbitration).
            let selected = selectedDeviceIDs
            let ids = selected.contains(device.id) ? selected : [device.id]
            menu.addItem(contextMenuItem("New Group from Selection…",
                                         #selector(newGroupFromSelectionMenuItemSelected(_:)), ids))
            menu.addItem(.separator())
            // Hiding is per-CLICKED-row, never batched over the selection: it
            // is a list-tidying gesture, and one mis-aimed right-click should
            // not empty the section.
            let hidden = hiddenDeviceIDs.contains(device.id)
            menu.addItem(contextMenuItem(hidden ? "Unhide Speaker" : "Hide Speaker",
                                         #selector(toggleSpeakerHiddenMenuItemSelected(_:)), device.id))
            addShowHiddenSpeakersItem(to: menu)
        }
    }

    /// Append the reveal toggle when there is anything to reveal. Its `.on`
    /// state is read off the rows themselves — a hidden speaker with a row is
    /// a speaker currently being shown — so the toggle can't disagree with
    /// what the list is doing.
    private func addShowHiddenSpeakersItem(to menu: NSMenu) {
        guard !hiddenDeviceIDs.isEmpty else { return }
        let item = NSMenuItem(title: "Show Hidden Speakers (\(hiddenDeviceIDs.count))",
                              action: #selector(toggleShowHiddenSpeakersMenuItemSelected(_:)),
                              keyEquivalent: "")
        item.target = self
        item.state = isShowingHiddenSpeakers ? .on : .off
        menu.addItem(item)
    }

    /// True while the Speakers section is drawing rows for hidden speakers.
    private var isShowingHiddenSpeakers: Bool {
        deviceNodes.contains { node in
            guard case .device(let device) = node.payload else { return false }
            return hiddenDeviceIDs.contains(device.id)
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
        // Section headers and the "no groups yet" placeholder aren't selectable
        // (source-list convention; the placeholder carries no identity to select).
        guard let node = item as? Node else { return false }
        if case .emptyState = node.payload { return false }
        return !self.outlineView(outlineView, isGroupItem: item)
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        switch node.payload {
        case .header(let title):
            return makeHeaderLabel(title)
        case .emptyState(let text):
            return makeLabel(text, identifier: "emptyState", secondary: true)
        case .group(let group):
            let symbol = DeviceIcon.resolve(group.iconSymbolName, default: Group.defaultIconSymbolName)
            return makeIconLabel(symbol: symbol,
                                 text: group.name, identifier: "group",
                                 showsActiveMarker: group.id == activeGroupID)
        case .device(let device):
            let symbol = deviceIconController?.symbolName(for: device) ?? device.kind.symbolName
            // A revealed hidden row wears the same muted treatment an
            // unavailable one does — it is present but not part of the list
            // the user chose to keep.
            return makeIconLabel(symbol: symbol,
                                 text: device.name, identifier: "device",
                                 dimmed: !device.isAvailable || hiddenDeviceIDs.contains(device.id))
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

    private func makeLabel(_ text: String, identifier: String, secondary: Bool) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? Self.newCell(identifier: id)
        cell.textField?.stringValue = text
        cell.textField?.textColor = secondary ? Tokens.Color.secondaryLabel : Tokens.Color.label
        cell.imageView?.image = nil
        cell.imageView?.isHidden = true
        return cell
    }

    /// Section header cell ("Groups" / "Speakers") — a DIFFERENT cell shape
    /// from `makeLabel`/`newCell` on purpose (design feedback 2026-07-18c):
    /// Finder's own sidebar headers sit flush-left with the ICON column
    /// below them, not indented to the item TEXT column, and render slightly
    /// bolder than a plain label. Reusing `newCell`'s icon+text layout (text
    /// anchored past `imageView.trailingAnchor`) was what misaligned this —
    /// headers need their own cell with the text pinned straight to
    /// `cell.leadingAnchor`. The empty-state placeholder is NOT a header (it
    /// occupies an ITEM row position under "Groups") and correctly keeps
    /// `makeLabel`/`newCell`'s indentation — do not route it through this.
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
                               dimmed: Bool = false, showsActiveMarker: Bool = false) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? IconLabelCellView
            ?? Self.newCell(identifier: id)
        cell.imageView?.isHidden = false
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        // Force flat monochrome rendering (design feedback 2026-07-18: some SF
        // Symbols default to a lighter hierarchical secondary tone, which read
        // as an unwanted "highlight" on the glyph) — a single, controlled dark
        // fill instead, via `.isTemplate` + an explicit `contentTintColor`.
        image?.isTemplate = true
        cell.imageView?.image = image
        cell.imageView?.contentTintColor = dimmed ? .disabledControlTextColor : Tokens.Color.label
        cell.textField?.stringValue = text
        cell.textField?.textColor = dimmed ? .disabledControlTextColor : Tokens.Color.label
        cell.setActiveMarkerVisible(showsActiveMarker)
        return cell
    }

    /// Icon side length matching the outline view's `.medium` `rowSizeStyle`
    /// (design feedback 2026-07-18: 18pt read as visually small next to the
    /// detail pane's large header icon).
    private static let iconSize: CGFloat = 22

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

        cell.addSubview(cell.activeMarkerView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: iconSize),
            imageView.heightAnchor.constraint(equalToConstant: iconSize),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            textField.trailingAnchor.constraint(
                lessThanOrEqualTo: cell.activeMarkerView.leadingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            cell.activeMarkerView.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            cell.activeMarkerView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
