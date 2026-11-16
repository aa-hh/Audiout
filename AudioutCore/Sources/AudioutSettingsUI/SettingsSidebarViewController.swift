// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The Settings screen's source list: one non-selectable "Settings" header row
/// over one leaf row per section. Deliberately the Speakers sidebar's own
/// arrangement — `SurfaceLayout.sidebarWidth` wide, `.sourceList` style, its
/// two-line `IconLabelCellView` — so each section row carries a readout of
/// what is set in it under its name.
///
/// What the Groups sidebar has and this deliberately does NOT: an add bar,
/// a context menu, double-click, Cmd-N, multi-selection, an active marker.
/// A settings section list has no such verbs.
@MainActor
final class SettingsSidebarViewController: NSViewController {

    /// One sidebar row's identity, in the order the sections were given.
    private final class Node {
        let title: String
        let symbolName: String
        /// `nil` for the header row — that is what makes it a group item.
        let sectionIndex: Int?
        var children: [Node] = []
        /// What is set in the section, one or two lines under its name.
        var readoutLines: [String] = []
        var glyphTint: NSColor = Tokens.Color.labelCool

        init(title: String, symbolName: String, sectionIndex: Int?) {
            self.title = title
            self.symbolName = symbolName
            self.sectionIndex = sectionIndex
        }
    }

    /// Fired with the selected section's index whenever the REAL outline
    /// selection changes — the root controller swaps its pane from here and
    /// never from a direct call, so a broken selection path can't stay green.
    var onSelect: ((Int) -> Void)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let root: Node

    init(sections: [(title: String, symbolName: String)]) {
        root = Node(title: "Settings", symbolName: "", sectionIndex: nil)
        root.children = sections.enumerated().map { index, section in
            Node(title: section.title, symbolName: section.symbolName, sectionIndex: index)
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        // Same source-list configuration as the Groups sidebar — `style`
        // (not the deprecated `selectionHighlightStyle`) applies the sidebar
        // material, full-width rows and section-header styling.
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .medium
        outlineView.autosaveExpandedItems = false
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = false
        outlineView.dataSource = self
        outlineView.delegate = self

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container

        outlineView.reloadData()
        outlineView.expandItem(root)
    }

    /// The selected section's index, or `nil` while nothing selectable is.
    var selectedIndex: Int? {
        loadViewIfNeeded()
        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? Node else { return nil }
        return node.sectionIndex
    }

    /// Move the REAL outline selection to `index`. `selectRowIndexes` is
    /// silent when that row is already selected (AppKit can auto-select the
    /// first selectable row itself, since empty selection is disallowed), so
    /// that case re-announces explicitly — the root controller's pane swap
    /// only ever runs from `onSelect`.
    func select(index: Int) {
        loadViewIfNeeded()
        guard root.children.indices.contains(index) else { return }
        let row = outlineView.row(forItem: root.children[index])
        guard row >= 0 else { return }
        if outlineView.selectedRow == row {
            onSelect?(index)
        } else {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    /// Show `lines` under section `index`'s name and tint its glyph. A change
    /// in line count re-measures the row at once, with no animation.
    func setReadout(_ lines: [String], glyphTint: NSColor, at index: Int) {
        loadViewIfNeeded()
        guard root.children.indices.contains(index) else { return }
        let node = root.children[index]
        let countChanged = node.readoutLines.count != lines.count
        node.readoutLines = lines
        node.glyphTint = glyphTint
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? IconLabelCellView {
            configure(cell, for: node)
        }
        guard countChanged else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
    }

    /// What VoiceOver says for a section row: the name, then each readout
    /// line, with the readout's own separators spoken as pauses.
    private static func spokenLabel(title: String, lines: [String]) -> String {
        title + lines.map { ", " + $0.replacingOccurrences(of: " · ", with: ", ") }.joined()
    }

    // MARK: Test-support hooks

    func test_readoutLines(at index: Int) -> [String] {
        root.children.indices.contains(index) ? root.children[index].readoutLines : []
    }

    /// The glyph's resting tint, read from a cell built through the delegate.
    func test_glyphTint(at index: Int) -> NSColor {
        test_cell(at: index)?.imageView?.contentTintColor ?? .clear
    }

    func test_rowHeight(at index: Int) -> CGFloat {
        loadViewIfNeeded()
        guard root.children.indices.contains(index) else { return 0 }
        return outlineView(outlineView, heightOfRowByItem: root.children[index])
    }

    func test_spokenLabel(at index: Int) -> String? {
        test_cell(at: index)?.nameLabel.accessibilityLabel()
    }

    /// The actual outline row, materialized by AppKit rather than the delegate.
    func test_rowView(at index: Int) -> NSTableRowView? {
        loadViewIfNeeded()
        guard root.children.indices.contains(index) else { return nil }
        let row = outlineView.row(forItem: root.children[index])
        guard row >= 0 else { return nil }
        return outlineView.rowView(atRow: row, makeIfNecessary: true)
    }

    private func test_cell(at index: Int) -> IconLabelCellView? {
        loadViewIfNeeded()
        guard root.children.indices.contains(index) else { return nil }
        return outlineView(outlineView, viewFor: nil, item: root.children[index]) as? IconLabelCellView
    }
}

// MARK: - NSOutlineViewDataSource

extension SettingsSidebarViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return 1 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return root }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node).map { !$0.children.isEmpty } ?? false
    }
}

// MARK: - NSOutlineViewDelegate

extension SettingsSidebarViewController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Node)?.sectionIndex == nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? Node)?.sectionIndex != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        guard node.sectionIndex != nil else { return makeHeaderCell(node.title) }
        return makeSectionCell(node)
    }

    /// Header rows keep the outline's height; a section row is 40 pt, or 54 pt
    /// with a second readout line.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? Node, node.sectionIndex != nil else { return outlineView.rowHeight }
        return node.readoutLines.count > 1 ? 54 : 40
    }

    /// Section rows ride a `SidebarRowView`, which re-inks the cell when the
    /// row's selection or emphasis changes, as the Speakers sidebar does.
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let node = item as? Node, node.sectionIndex != nil else { return nil }
        let id = NSUserInterfaceItemIdentifier("sectionRow")
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? SidebarRowView { return reused }
        let row = SidebarRowView()
        row.identifier = id
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? SidebarRowView)?.reink()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let index = selectedIndex else { return }
        onSelect?(index)
    }

    // MARK: Cell builders

    /// Header cell shape copied from the Groups sidebar: text pinned straight
    /// to the cell's leading edge (flush with the ICON column below it, not
    /// indented to the item TEXT column) in the slightly bolder caption.
    private func makeHeaderCell(_ text: String) -> NSTableCellView {
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
        textField.font = Tokens.Font.captionEmphasized
        textField.textColor = Tokens.Color.labelCool
        textField.lineBreakMode = .byTruncatingTail
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeSectionCell(_ node: Node) -> IconLabelCellView {
        let id = NSUserInterfaceItemIdentifier("section")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? IconLabelCellView
            ?? IconLabelCellView.make(identifier: id, isSpeakerRow: true)
        configure(cell, for: node)
        return cell
    }

    private func configure(_ cell: IconLabelCellView, for node: Node) {
        cell.imageView?.image = DeviceIcon.image(node.symbolName)
        cell.nameLabel.stringValue = node.title
        cell.nameLabel.setAccessibilityLabel(Self.spokenLabel(title: node.title, lines: node.readoutLines))
        let readout = node.readoutLines.joined(separator: "\n")
        cell.statusLabel.maximumNumberOfLines = 2
        cell.statusLabel.usesSingleLineMode = false
        cell.statusLabel.stringValue = readout
        cell.statusLabel.toolTip = readout.isEmpty ? nil : readout
        cell.statusLabel.isHidden = readout.isEmpty
        cell.setRestingInks(name: Tokens.Color.label, icon: node.glyphTint)
        // A cell with no row yet rests.
        let row = cell.superview as? NSTableRowView
        cell.applySelectionInks(selected: row?.isSelected == true, emphasized: row?.isEmphasized == true)
    }
}
