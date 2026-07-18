// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit
import AudioutedCore

/// What the user selected in the sidebar. Drives which detail pane the window
/// shows (a group → its editor; a device / nothing → the mixer).
public enum SidebarSelection: Equatable, Sendable {
    case group(id: String)
    case device(id: String)
}

/// The mixer window's sidebar (SPEC §9 "Sidebar list": source-list
/// `NSOutlineView`, "saved groups → member devices, Finder-favorites style").
///
/// Two top-level sections — **Groups** (each saved group, expandable to its
/// member devices) and **Devices** (ungrouped speakers) — exactly the "Groups"
/// / "Devices" split the menu uses, in the documented source-list style
/// (`selectionHighlightStyle = .sourceList`, header rows via
/// `isGroupItem`). Selection is reported through `onSelect`.
///
/// The outline model is a small tree of reference-typed `Node`s so the
/// `NSOutlineViewDataSource` identity methods are stable across reloads.
public final class SidebarViewController: NSViewController {

    /// A node in the source-list tree. Reference type so `NSOutlineView` can key
    /// on object identity.
    final class Node {
        enum Payload {
            case header(String)             // "Groups" / "Devices" (isGroupItem)
            case group(Group)               // a saved group (expandable)
            case device(Device)             // a device row (leaf)
        }
        let payload: Payload
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

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton()

    /// Top-level nodes (the two section headers). Rebuilt on `reload`.
    private var roots: [Node] = []

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        outlineView.rowSizeStyle = .default
        outlineView.autosaveExpandedItems = false
        // Multi-select so the user can cmd/shift-click several speakers and make
        // a group from exactly those (SPEC.md §9). Headers stay non-selectable
        // via `shouldSelectItem`.
        outlineView.allowsMultipleSelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        // Right-click context menu ("New Group from Selection").
        outlineView.menu = makeContextMenu()

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Bottom add bar with a "+" button — the standard macOS source-list add
        // affordance (SPEC.md §9). Plain: new empty group. With devices
        // selected: new group from that selection.
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .smallSquare
        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Group")
        addButton.imagePosition = .imageOnly
        addButton.target = self
        addButton.action = #selector(addTapped(_:))
        addButton.toolTip = "New Group"
        addButton.setButtonType(.momentaryPushIn)

        let addBar = NSView()
        addBar.translatesAutoresizingMaskIntoConstraints = false
        addBar.addSubview(addButton)

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(addBar)

        NSLayoutConstraint.activate([
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
            addButton.widthAnchor.constraint(equalToConstant: 20),
            addButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        view = container
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Group from Selection",
                              action: #selector(newGroupFromSelectionTapped(_:)),
                              keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        menu.delegate = self
        return menu
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

    @objc private func newGroupFromSelectionTapped(_ sender: NSMenuItem) {
        let selected = selectedDeviceIDs
        guard !selected.isEmpty else { return }
        onNewGroupFromSelection?(selected)
    }

    // MARK: Model

    /// Rebuild the tree from the current groups + devices and reload. Preserves
    /// the selection by `SidebarSelection` identity where possible.
    public func reload(groups: [Group], activeGroupID: String?, devices: [Device]) {
        let previous = currentSelection

        let devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })

        var newRoots: [Node] = []

        // 1. Groups section — each group expands to its member devices.
        if !groups.isEmpty {
            let groupsHeader = Node(.header("Groups"))
            for group in groups {
                let groupNode = Node(.group(group))
                groupNode.children = group.memberIDs.compactMap { id in
                    devicesByID[id].map { Node(.device($0)) }
                }
                groupsHeader.children.append(groupNode)
            }
            newRoots.append(groupsHeader)
        }

        // 2. Devices section — devices not in the active group (matches the
        //    menu's "ungrouped" split; falls back to all devices when nothing is
        //    active so every speaker stays reachable).
        let activeMemberIDs = Set(groups.first { $0.id == activeGroupID }?.memberIDs ?? [])
        let ungrouped = devices.filter { !activeMemberIDs.contains($0.id) }
        if !ungrouped.isEmpty {
            let devicesHeader = Node(.header("Devices"))
            devicesHeader.children = ungrouped.map { Node(.device($0)) }
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
        case .header: return nil
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

    /// Number of group rows under the "Groups" header.
    public var test_groupRowCount: Int {
        roots.first { if case .header("Groups") = $0.payload { return true } else { return false } }?
            .children.count ?? 0
    }

    /// Number of device rows under the "Devices" header (ungrouped).
    public var test_ungroupedDeviceRowCount: Int {
        roots.first { if case .header("Devices") = $0.payload { return true } else { return false } }?
            .children.count ?? 0
    }

    /// The member-device ids listed under a given group node in the sidebar.
    public func test_memberIDs(underGroup groupID: String) -> [String] {
        guard let groupNode = findGroupNode(groupID) else { return [] }
        return groupNode.children.compactMap {
            if case .device(let d) = $0.payload { return d.id } else { return nil }
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

    private func findGroupNode(_ groupID: String) -> Node? {
        for root in roots {
            for child in root.children {
                if case .group(let g) = child.payload, g.id == groupID { return child }
            }
        }
        return nil
    }
}

// MARK: - NSMenuDelegate (context menu)

extension SidebarViewController: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        // "New Group from Selection" is only meaningful with ≥1 device selected.
        let hasDevices = !selectedDeviceIDs.isEmpty
        for item in menu.items where item.action == #selector(newGroupFromSelectionTapped(_:)) {
            item.isEnabled = hasDevices
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
        !self.outlineView(outlineView, isGroupItem: item)
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        switch node.payload {
        case .header(let title):
            return makeLabel(title, identifier: "header", secondary: true)
        case .group(let group):
            return makeIconLabel(symbol: "rectangle.3.group",
                                 text: group.name, identifier: "group")
        case .device(let device):
            return makeIconLabel(symbol: device.kind.symbolName,
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
        cell.textField?.textColor = secondary ? .secondaryLabelColor : .labelColor
        cell.imageView?.image = nil
        cell.imageView?.isHidden = true
        return cell
    }

    private func makeIconLabel(symbol: String, text: String, identifier: String, dimmed: Bool = false) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? Self.newCell(identifier: id)
        cell.imageView?.isHidden = false
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        cell.textField?.stringValue = text
        cell.textField?.textColor = dimmed ? .disabledControlTextColor : .labelColor
        return cell
    }

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
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
