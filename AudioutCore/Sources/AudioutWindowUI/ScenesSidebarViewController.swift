// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// Saved scenes beside their configuration page, using the stock source list.
public final class ScenesSidebarViewController: NSViewController {
    public struct SceneRow: Equatable {
        let id: String
        let name: String
        let symbolName: String
        let memberCount: Int
    }

    private final class Node {
        enum Payload { case header, scene(SceneRow), placeholder }
        var payload: Payload
        var children: [Node] = []
        init(_ payload: Payload) { self.payload = payload }
    }

    private let header = Node(.header)
    private var sceneNodes: [String: Node] = [:]
    private var rows: [SceneRow] = []
    private let outlineView = SidebarOutlineView()
    private let scrollView = NSScrollView()
    private lazy var addButton = SidebarViewController.makeAddSceneButton(target: self, action: #selector(addTapped(_:)))
    private var suppressSelectionCallback = false

    public var onSelect: ((String) -> Void)?
    public var onAddScene: (() -> Void)?
    public var onRequestRename: ((String) -> Void)?
    public var onRequestDelete: ((String) -> Void)?

    public override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .medium
        outlineView.allowsExpansionToolTips = true
        outlineView.allowsMultipleSelection = false
        outlineView.dataSource = self
        outlineView.delegate = self
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        outlineView.menu = menu
        outlineView.onCommandDelete = { [weak self] in
            guard let self, let id = self.selectedSceneID else { return false }
            self.onRequestDelete?(id)
            return true
        }
        outlineView.onReturn = { [weak self] in
            guard let self, let id = self.selectedSceneID else { return false }
            self.onRequestRename?(id)
            return true
        }
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let addBar = NSView()
        addBar.translatesAutoresizingMaskIntoConstraints = false
        addBar.addSubview(addButton)
        let container = SidebarContainerView()
        container.onCommandN = { [weak self] in self?.onAddScene?() }
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
            addBar.heightAnchor.constraint(equalToConstant: outlineView.rowHeight),
            addButton.leadingAnchor.constraint(equalTo: addBar.leadingAnchor, constant: 16),
            addButton.centerYAnchor.constraint(equalTo: addBar.centerYAnchor),
            addButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        view = container
        header.children = [Node(.placeholder)]
        outlineView.reloadData()
        outlineView.expandItem(header)
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        window.recalculateKeyViewLoop()
        if window.firstResponder === window { window.makeFirstResponder(outlineView) }
    }

    public func reload(scenes: [SceneRow]) {
        loadViewIfNeeded()
        let sorted = scenes.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
        let selected = selectedSceneID
        let sameIDs = sorted.map(\.id) == rows.map(\.id)
        rows = sorted
        for row in rows {
            if let node = sceneNodes[row.id] { node.payload = .scene(row) }
            else { sceneNodes[row.id] = Node(.scene(row)) }
        }
        sceneNodes = sceneNodes.filter { entry in rows.contains { $0.id == entry.key } }
        if sameIDs {
            for index in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: index) as? Node,
                      case .scene(let row) = node.payload,
                      let cell = outlineView.view(atColumn: 0, row: index, makeIfNecessary: false) as? IconLabelCellView else { continue }
                configure(cell, row: row, fresh: false)
            }
        } else {
            header.children = rows.isEmpty ? [Node(.placeholder)] : rows.compactMap { sceneNodes[$0.id] }
            suppressSelectionCallback = true
            outlineView.reloadData()
            outlineView.expandItem(header)
            if let selected, sceneNodes[selected] != nil { select(sceneID: selected, notify: false) }
            suppressSelectionCallback = false
        }
    }

    private func configure(_ cell: IconLabelCellView, row: SceneRow, fresh: Bool) {
        cell.imageView?.image = DeviceIcon.image(row.symbolName)
        cell.nameLabel.stringValue = row.name
        let caption = row.memberCount == 1 ? "1 speaker" : "\(row.memberCount) speakers"
        if fresh { cell.statusLabel.stringValue = caption } else { cell.statusLabel.roll(to: caption) }
        cell.statusLabel.isHidden = false
        cell.statusLabel.font = Tokens.Font.captionDigits
        cell.setDisclosureVisible(false)
        cell.setRestingInks(name: Tokens.Color.label, icon: Tokens.Color.label)
        cell.nameLabel.setAccessibilityLabel("\(row.name), \(caption)")
        let rowView = cell.superview as? NSTableRowView
        cell.applySelectionInks(selected: rowView?.isSelected == true, emphasized: rowView?.isEmphasized == true)
        if !cell.subviews.contains(where: { $0 is GroupIdentityGlowView }), let glyph = cell.imageView {
            let glow = GroupIdentityGlowView()
            glow.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(glow, positioned: .below, relativeTo: glyph)
            NSLayoutConstraint.activate([
                glow.widthAnchor.constraint(equalToConstant: GroupIdentityGlowView.side),
                glow.heightAnchor.constraint(equalToConstant: GroupIdentityGlowView.side),
                glow.centerXAnchor.constraint(equalTo: glyph.centerXAnchor),
                glow.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            ])
            cell.wantsLayer = true
            cell.layer?.masksToBounds = true
        }
    }

    public var selectedSceneID: String? {
        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? Node,
              case .scene(let row) = node.payload else { return nil }
        return row.id
    }

    public func select(sceneID: String, notify: Bool) {
        guard let node = sceneNodes[sceneID] else { return }
        let index = outlineView.row(forItem: node)
        guard index >= 0 else { return }
        let previous = suppressSelectionCallback
        suppressSelectionCallback = !notify
        outlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        suppressSelectionCallback = previous
    }

    @objc private func addTapped(_ sender: Any?) { onAddScene?() }
    @objc private func renameTapped(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onRequestRename?(id) }
    }
    @objc private func deleteTapped(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onRequestDelete?(id) }
    }

    private func contextMenu(for node: Node?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let node, case .scene(let row) = node.payload else { return menu }
        for (title, action) in [("Rename…", #selector(renameTapped(_:))), ("Delete scene…", #selector(deleteTapped(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = row.id
            menu.addItem(item)
        }
        return menu
    }

    public var test_rowIDs: [String] { rows.map(\.id) }
    func test_rowCell(id: String) -> IconLabelCellView? {
        guard let node = sceneNodes[id] else { return nil }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return nil }
        return outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? IconLabelCellView
    }
    func test_rowCaption(id: String) -> String? { test_rowCell(id: id)?.statusLabel.stringValue }
    func test_setCountReduceMotionOverride(_ value: Bool?, for id: String) {
        test_rowCell(id: id)?.statusLabel.test_reduceMotionOverride = value
    }
    func test_countIsRolling(for id: String) -> Bool { test_rowCell(id: id)?.statusLabel.test_isRolling ?? false }
    func test_settleCount(for id: String) { test_rowCell(id: id)?.statusLabel.test_settleNow() }
    func test_rowView(id: String) -> NSTableRowView? {
        guard let node = sceneNodes[id] else { return nil }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return nil }
        return outlineView.rowView(atRow: row, makeIfNecessary: true)
    }
    public func test_select(sceneID: String) { select(sceneID: sceneID, notify: true) }
    func test_contextMenuItems(for id: String) -> [String] { contextMenu(for: sceneNodes[id]).items.map(\.title) }
    @discardableResult
    func test_clickContextMenuItem(_ title: String, for id: String) -> Bool {
        let menu = contextMenu(for: sceneNodes[id])
        guard let index = menu.items.firstIndex(where: { $0.title == title }) else { return false }
        menu.performActionForItem(at: index)
        return true
    }
    func test_tapAdd() { addButton.performClick(nil) }
    @discardableResult
    func test_performCmdN() -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "n", charactersIgnoringModifiers: "n",
            isARepeat: false, keyCode: 45) else { return false }
        return view.performKeyEquivalent(with: event)
    }
    func test_pressCommandDelete() {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{8}", charactersIgnoringModifiers: "\u{8}",
            isARepeat: false, keyCode: 51) else { return }
        outlineView.keyDown(with: event)
    }
    func test_pressReturn() {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36) else { return }
        outlineView.keyDown(with: event)
    }
    public var test_hasPlaceholderRow: Bool { header.children.contains { if case .placeholder = $0.payload { return true }; return false } }
    func test_glowIsBehindGlyph(id: String) -> Bool {
        guard let cell = test_rowCell(id: id), let glyph = cell.imageView,
              let glowIndex = cell.subviews.firstIndex(where: { $0 is GroupIdentityGlowView }),
              let glyphIndex = cell.subviews.firstIndex(of: glyph) else { return false }
        return glowIndex < glyphIndex
    }
    func test_filteredSelection(ofRows rows: IndexSet) -> IndexSet {
        outlineView(outlineView, selectionIndexesForProposedSelection: rows)
    }
}

extension ScenesSidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? 1 : (item as? Node)?.children.count ?? 0
    }
    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        item == nil ? header : (item as! Node).children[index]
    }
    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node) === header
    }
    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? Node) === header }
    public func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { false }
    public func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }
    public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? Node else { return outlineView.rowHeight }
        switch node.payload {
        case .header: return SidebarViewController.headerHeight
        case .scene: return outlineView.rowHeight + 12
        case .placeholder: return outlineView.rowHeight
        }
    }
    public func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let node = item as? Node, case .scene = node.payload else { return nil }
        return SidebarRowView()
    }
    public func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? SidebarRowView)?.reink()
    }
    public func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection indexes: IndexSet) -> IndexSet {
        var kept = IndexSet()
        for index in indexes {
            if let node = outlineView.item(atRow: index) as? Node, case .scene = node.payload { kept.insert(index) }
        }
        return kept.isEmpty && !rows.isEmpty ? outlineView.selectedRowIndexes : kept
    }
    public func outlineViewSelectionDidChange(_ notification: Notification) {
        if !suppressSelectionCallback, let id = selectedSceneID { onSelect?(id) }
    }
    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        switch node.payload {
        case .header:
            let cell = SidebarHeaderCellView(identifier: NSUserInterfaceItemIdentifier("scenesHeader"), font: Tokens.Font.captionEmphasized)
            cell.label.stringValue = "Scenes"
            return cell
        case .placeholder:
            let cell = SidebarHeaderCellView(identifier: NSUserInterfaceItemIdentifier("scenesPlaceholder"), font: Tokens.Font.caption)
            cell.label.stringValue = "No scenes yet"
            cell.label.setAccessibilityElement(true)
            cell.label.setAccessibilityRole(.staticText)
            return cell
        case .scene(let row):
            let cell = (outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("scene"), owner: self) as? IconLabelCellView)
                ?? SidebarViewController.newCell(identifier: NSUserInterfaceItemIdentifier("scene"), isSpeakerRow: true)
            configure(cell, row: row, fresh: true)
            return cell
        }
    }
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let row = outlineView.clickedRow
        let node = row >= 0 ? outlineView.item(atRow: row) as? Node : nil
        let built = contextMenu(for: node)
        for item in built.items { built.removeItem(item); menu.addItem(item) }
    }
}
