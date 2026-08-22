// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterSharedUI

/// The Settings screen's source list: one non-selectable "Settings" header row
/// over one leaf row per section. Deliberately the Groups sidebar's own
/// arrangement — `SurfaceLayout.sidebarWidth` wide, `.sourceList` style,
/// `.medium` rows, the same icon/label cell geometry, the same
/// `SidebarWarmSurfaceView` wash behind it — so the two arrangement screens
/// read as one surface rather than two different sidebars.
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
    /// `rendersOnGlass: false` on every OS: the surface's split items are
    /// plain ones (see `SettingsRootViewController`), so no system sidebar
    /// material sits behind this wash for it to tint — it draws the opaque
    /// warm backing itself.
    private let warmSurfaceView = SidebarWarmSurfaceView(rendersOnGlass: false)
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
        // The warm wash goes in FIRST so it is the bottommost subview, under
        // the untouched outline view (its `hitTest` returns nil, so it can
        // never swallow a row click).
        warmSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(warmSurfaceView)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            warmSurfaceView.topAnchor.constraint(equalTo: container.topAnchor),
            warmSurfaceView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            warmSurfaceView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            warmSurfaceView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

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
        return makeIconLabelCell(symbol: node.symbolName, text: node.title)
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
        textField.textColor = Tokens.Color.secondaryLabel
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

    private func makeIconLabelCell(symbol: String, text: String) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("section")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? Self.newIconLabelCell(identifier: id)
        // Flat monochrome glyphs, as in the Groups sidebar: some SF Symbols
        // default to a lighter hierarchical tone that reads as a highlight.
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        image?.isTemplate = true
        cell.imageView?.image = image
        cell.imageView?.contentTintColor = Tokens.Color.label
        cell.textField?.stringValue = text
        cell.textField?.textColor = Tokens.Color.label
        return cell
    }

    private static func newIconLabelCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
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
            imageView.widthAnchor.constraint(equalToConstant: SurfaceLayout.sidebarIconSize),
            imageView.heightAnchor.constraint(equalToConstant: SurfaceLayout.sidebarIconSize),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor,
                                               constant: SurfaceLayout.sidebarIconToLabelGap),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
