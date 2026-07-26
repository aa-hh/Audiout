// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// What the user selected in the sidebar. Drives which detail pane the window
/// shows (a group → its editor; a device / nothing → the mixer).
public enum SidebarSelection: Equatable, Sendable {
    case group(id: String)
    case device(id: String)
}

/// The mixer window's sidebar (SPEC §9 "Sidebar list": source-list
/// `NSOutlineView`).
///
/// Two top-level sections — **Groups** and **Devices** — exactly the "Groups"
/// / "Devices" split the menu uses, in the documented source-list style
/// (`selectionHighlightStyle = .sourceList`, header rows via
/// `isGroupItem`). Both sections are FLAT: a group row is a single leaf row
/// (icon + name, same icon column as a device row) with no disclosure
/// chevron and no child device rows — previewing a group's members happens in
/// the group editor's own "Speakers" checklist, not by expanding the sidebar
/// row, so nesting here was pure duplication (design review 2026-07-18). The
/// Devices section lists every device, grouped or not, since membership is no
/// longer previewed via expansion. Selection is reported through `onSelect`.
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
            case header(String)             // "Groups" / "Devices" (isGroupItem)
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

    /// Called when the user chooses "New Group from Selection" (the "+" while
    /// devices are multi-selected, or the context-menu item) — carries the
    /// selected device ids (SPEC.md §9 — "click on speakers and multiselect to
    /// create a group").
    public var onNewGroupFromSelection: (([String]) -> Void)?

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
    // FOLLOW-UP for the next person here: this fixes "nothing is ever
    // tabbable from launch," which is the mechanism a live test would hit
    // immediately on opening the window. It does NOT touch
    // `MixerWindowController.swift` (out of this task's scope — see
    // PROGRESS.md's A11Y-GROUPS entry) or `ContentPaneHostViewController`'s
    // `setContent(_:)` (same file), which swaps the content pane's view
    // hierarchy on every sidebar selection; if a live retest finds Tab still
    // breaks specifically AFTER switching panes, the next place to look is
    // whether that swap needs its own `window.recalculateKeyViewLoop()` call.
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

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Bottom add bar with a labeled "New Group" affordance — the standard
        // macOS source-list add control (SPEC.md §9), styled like Notes'
        // bottom-left "New Folder" button: borderless, system font, glyph +
        // title. Plain: new empty group. With devices selected: new group
        // from that selection.
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .recessed
        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.title = "New Group"
        addButton.font = Tokens.Font.body
        addButton.target = self
        addButton.action = #selector(addTapped(_:))
        addButton.toolTip = "New Group"
        addButton.setButtonType(.momentaryPushIn)

        let addBar = NSView()
        addBar.translatesAutoresizingMaskIntoConstraints = false
        addBar.addSubview(addButton)

        let container = NSView()
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
        let selected = selectedDeviceIDs
        if selected.isEmpty {
            onAddGroup?()
        } else {
            onNewGroupFromSelection?(selected)
        }
    }

    // MARK: Model

    /// Rebuild the tree from the current groups + devices and reload. Preserves
    /// the selection by `SidebarSelection` identity where possible.
    ///
    /// Both sections are flat leaf lists (design review 2026-07-18): a group
    /// row never carries member-device children, and the Devices section lists
    /// EVERY device rather than filtering out members of the active group —
    /// once the sidebar no longer previews membership via expansion, hiding a
    /// device here would just make it unreachable. `activeGroupID` is kept as
    /// a parameter for call-site compatibility but no longer affects this list.
    public func reload(groups: [Group], activeGroupID: String?, devices: [Device]) {
        let previous = currentSelection
        _ = activeGroupID   // no longer used to filter the Devices section

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

        // 2. Devices section — every device, grouped or not, so it stays
        //    reachable now that membership isn't previewed via expansion.
        if !devices.isEmpty {
            let devicesHeader = Node(.header("Devices"))
            devicesHeader.children = devices.map { Node(.device($0)) }
            newRoots.append(devicesHeader)
        }

        roots = newRoots
        outlineView.reloadData()
        // Expand section headers so the tree reads as a flat source list.
        for root in roots { outlineView.expandItem(root) }

        // Restore selection if the same target still exists.
        if let previous { select(previous, notify: false) }
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

    // MARK: Test-support hooks

    /// The section-header titles in order (e.g. ["Groups", "Devices"]).
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

    /// Number of device rows under the "Devices" header. Lists every device
    /// (grouped or not) since the flat model no longer previews membership
    /// via expansion.
    public var test_deviceRowCount: Int {
        roots.first { if case .header("Devices") = $0.payload { return true } else { return false } }?
            .children.count ?? 0
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
    }

    /// The device ids currently multi-selected (for asserts).
    public var test_selectedDeviceIDs: [String] { selectedDeviceIDs }

    /// Simulate clicking the "+" button (new empty group, or new-from-selection
    /// when devices are selected).
    public func test_tapAdd() {
        addTapped(addButton)
    }

    /// True when the outline view allows multi-selection (SPEC.md §9).
    public var test_allowsMultipleSelection: Bool { outlineView.allowsMultipleSelection }

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

    /// The alpha the 26+ tint overlay draws at (0 when this OS renders the
    /// opaque fallback instead — the two never blend, one or the other).
    public var test_warmSurfaceAlpha: CGFloat {
        warmSurfaceView.rendersOnGlass ? SidebarWarmSurfaceView.tintAlpha : 1
    }
}

/// The Groups window sidebar's warm surface (T7, spec Q4-b): a non-
/// interactive view sitting between the sidebar's system material and the
/// outline view. On macOS 26+ the automatic Liquid Glass sidebar material
/// (applied by `NSSplitViewItem(sidebarWithViewController:)` outside this
/// controller's own view — there is no public API to tint it directly) is
/// left completely alone; this draws a LOW-ALPHA warm wash on top of it.
/// Below macOS 26 there is no glass to tint at all, so this draws the SAME
/// color fully opaque as the sidebar's whole backing.
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

    init(rendersOnGlass: Bool) {
        self.rendersOnGlass = rendersOnGlass
        super.init(frame: .zero)
        wantsLayer = true
        // Reconcile live on a mid-session Reduce Transparency / Increase
        // Contrast toggle (`AudiouterSharedUI/AGENTS.md`'s instrument rule —
        // neither arrives through this view's own lifecycle otherwise).
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
        let color = rendersOnGlass ? base.withAlphaComponent(Self.tintAlpha) : base
        color.setFill()
        bounds.fill()
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
                                 text: group.name, identifier: "group")
        case .device(let device):
            let symbol = deviceIconController?.symbolName(for: device) ?? device.kind.symbolName
            return makeIconLabel(symbol: symbol,
                                 text: device.name, identifier: "device",
                                 dimmed: !device.isAvailable)
        }
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
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

    /// Section header cell ("Groups" / "Devices") — a DIFFERENT cell shape
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
            // "Devices" read as indented relative to the device icons under it).
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeIconLabel(symbol: String, text: String, identifier: String, dimmed: Bool = false) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
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
        return cell
    }

    /// Icon side length matching the outline view's `.medium` `rowSizeStyle`
    /// (design feedback 2026-07-18: 18pt read as visually small next to the
    /// detail pane's large header icon).
    private static let iconSize: CGFloat = 22

    private static func newCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
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

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: iconSize),
            imageView.heightAnchor.constraint(equalToConstant: iconSize),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
