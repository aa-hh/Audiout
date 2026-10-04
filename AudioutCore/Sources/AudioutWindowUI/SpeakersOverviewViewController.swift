// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// Shared speaker identity and Mixer visibility. These controls never change playback.
@MainActor
public final class SpeakersOverviewViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let library: SpeakerLibraryController
    private let table = SpeakersTableView()
    private let scroll = NSScrollView()
    private let bulkPopup = NSPopUpButton()
    private let bulkStack = NSStackView()
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionButton = NSButton()
    private struct RowProjection: Equatable {
        let id: String
        let name: String
        let kind: Device.Kind?
        let status: SpeakerPresentationStatus
        let visibility: SpeakerMixerVisibility
        let known: Bool
    }
    private var projection: [RowProjection] = []
    private var records: [SpeakerPresentationRecord] = []
    public var onVisibilityChange: (() -> Void)?
    /// The row the user opened; the host selects it in the sidebar.
    public var onOpenSpeaker: ((String) -> Void)?
    public var onBluetoothAccess: (() -> Void)?

    public init(library: SpeakerLibraryController = SpeakerLibraryController(loadPersisted: false)) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        let root = WarmPanelView()
        let title = NSTextField(labelWithString: "Speakers")
        title.font = Tokens.Font.heading
        let explanation = NSTextField(wrappingLabelWithString:
            "Mixer visibility applies across all scenes. Scene membership stays separate.")
        explanation.font = Tokens.Font.caption
        explanation.textColor = Tokens.Color.label2
        let bulkLabel = NSTextField(labelWithString: "Show in Mixer")
        bulkLabel.font = Tokens.Font.caption
        configurePopup(bulkPopup)
        bulkPopup.target = self
        bulkPopup.action = #selector(bulkChanged(_:))
        bulkPopup.setAccessibilityLabel("Show selected speakers in Mixer")
        bulkStack.orientation = .horizontal
        bulkStack.spacing = 8
        bulkStack.setViews([bulkLabel, bulkPopup], in: .leading)
        bulkStack.isHidden = true
        permissionLabel.font = Tokens.Font.caption
        permissionLabel.textColor = Tokens.Color.label2
        permissionButton.bezelStyle = .rounded
        permissionButton.target = self
        permissionButton.action = #selector(accessTapped(_:))
        let permissionStack = NSStackView(views: [permissionLabel, permissionButton])
        permissionStack.orientation = .vertical
        permissionStack.alignment = .leading
        permissionStack.spacing = 6
        permissionLabel.isHidden = true
        permissionButton.isHidden = true
        let header = NSStackView(views: [title, explanation, permissionStack, bulkStack])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = GroupsPaneLayout.labelToSectionGap
        let identity = NSTableColumn(identifier: .init("identity"))
        identity.title = "Speaker"
        identity.width = GroupsPaneLayout.contentMaxWidth - 172
        identity.minWidth = 100
        let visibility = NSTableColumn(identifier: .init("visibility"))
        visibility.title = "Show in Mixer"
        visibility.width = 172
        visibility.minWidth = 172
        visibility.maxWidth = 172
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.addTableColumn(identity)
        table.addTableColumn(visibility)
        table.headerView = NSTableHeaderView()
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = 60
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked(_:))
        table.onOpenSelection = { [weak self] in self?.openSelectedRow() }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        for child in [header, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: GroupsPaneLayout.columnInset),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -GroupsPaneLayout.columnTrailingInset),
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: GroupsPaneLayout.columnTopInset),
            scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: GroupsPaneLayout.sectionGap),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -GroupsPaneLayout.paneBottomInset),
        ])
        view = root
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        fitTableToVisibleWidth()
    }

    private func fitTableToVisibleWidth() {
        let width = scroll.contentView.bounds.width
        guard width > 0, table.tableColumns.count == 2 else { return }
        if abs(table.frame.width - width) > 0.5 {
            table.setFrameSize(NSSize(width: width, height: table.frame.height))
        }
        let identity = table.tableColumns[0]
        let visibility = table.tableColumns[1]
        let identityWidth = max(identity.minWidth, width - visibility.width - table.intercellSpacing.width)
        if abs(identity.width - identityWidth) > 0.5 {
            identity.width = identityWidth
        }
    }

    public func reload() {
        loadViewIfNeeded()
        let selected = selectedIDs
        let next = library.records
        let nextProjection = next.map { RowProjection(id: $0.id, name: $0.displayName, kind: $0.kind,
            status: $0.status, visibility: $0.visibility, known: $0.metadataIsKnown) }
        records = next
        if projection != nextProjection {
            projection = nextProjection
            table.reloadData()
            scroll.layoutSubtreeIfNeeded()
            fitTableToVisibleWidth()
            table.selectRowIndexes(IndexSet(records.indices.filter { selected.contains(records[$0].id) }),
                                   byExtendingSelection: false)
        }
        updateBulk()
    }

    /// The host reads authorization and supplies the matching explanation and action.
    public func setBluetoothAccessExplanation(_ text: String?, actionTitle: String? = nil) {
        loadViewIfNeeded()
        permissionLabel.stringValue = text ?? ""
        permissionLabel.isHidden = text == nil
        permissionButton.title = actionTitle ?? ""
        permissionButton.isHidden = actionTitle == nil
    }

    private var selectedIDs: Set<String> {
        Set(table.selectedRowIndexes.compactMap { records.indices.contains($0) ? records[$0].id : nil })
    }
    private func configurePopup(_ popup: NSPopUpButton) {
        popup.menu?.autoenablesItems = false
        popup.addItems(withTitles: SpeakerMixerVisibility.allCases.map(\.label))
        popup.font = Tokens.Font.body
    }
    private func updateBulk() {
        let selected = records.filter { selectedIDs.contains($0.id) && !$0.isLocalDevice }
        bulkStack.isHidden = selectedIDs.isEmpty
        bulkPopup.isEnabled = !selected.isEmpty
        if bulkPopup.itemTitles.first == "Mixed" { bulkPopup.removeItem(at: 0) }
        let values = Set(selected.map(\.visibility))
        if values.count == 1, let value = values.first { bulkPopup.selectItem(withTitle: value.label) }
        else {
            bulkPopup.insertItem(withTitle: "Mixed", at: 0)
            bulkPopup.item(at: 0)?.isEnabled = false
            bulkPopup.selectItem(at: 0)
        }
    }
    @objc private func accessTapped(_ sender: NSButton) { onBluetoothAccess?() }
    @objc private func individualChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String,
              let record = library.record(for: id), !record.isLocalDevice,
              let value = SpeakerMixerVisibility.allCases.first(where: { $0.label == sender.titleOfSelectedItem }) else { return }
        if library.setVisibility(value, for: id) { onVisibilityChange?() }
        reload()
    }
    @objc private func bulkChanged(_ sender: NSPopUpButton) {
        guard let value = SpeakerMixerVisibility.allCases.first(where: { $0.label == sender.titleOfSelectedItem }) else { return }
        let ids = Set(records.filter { selectedIDs.contains($0.id) && !$0.isLocalDevice }.map(\.id))
        if library.setVisibility(value, for: ids) { onVisibilityChange?() }
        reload()
    }
    public func numberOfRows(in tableView: NSTableView) -> Int { records.count }
    public func tableViewSelectionDidChange(_ notification: Notification) { updateBulk() }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let record = records[row]
        if tableColumn?.identifier.rawValue == "visibility" {
            let popup = NSPopUpButton()
            configurePopup(popup)
            popup.selectItem(withTitle: record.visibility.label)
            popup.isEnabled = !record.isLocalDevice
            popup.itemArray.forEach { $0.representedObject = record.id }
            popup.target = self
            popup.action = #selector(individualChanged(_:))
            popup.setAccessibilityLabel("Show \(record.accessibilityIdentity) in Mixer")
            let cell = NSTableCellView()
            popup.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(popup)
            NSLayoutConstraint.activate([
                popup.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                popup.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                popup.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        let icon = NSImageView()
        icon.image = DeviceIcon.image(record.kind?.symbolName ?? "speaker")
        icon.contentTintColor = Tokens.Color.labelCool
        icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: SurfaceLayout.sidebarIconSize).isActive = true
        let name = NSTextField(labelWithString: record.displayName)
        name.font = Tokens.Font.body
        name.lineBreakMode = .byTruncatingTail
        name.setAccessibilityLabel(record.accessibilityIdentity)
        let transport: String
        switch record.kind {
        case .none: transport = ""
        case .localMac: transport = "This Mac"
        case .bluetooth: transport = "Bluetooth"
        case .cast: transport = "Cast"
        default: transport = "AirPlay"
        }
        let status = NSTextField(labelWithString: transport.isEmpty ? record.status.text : "\(transport) · \(record.status.text)")
        status.font = Tokens.Font.caption
        status.textColor = Tokens.Color.label2
        status.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [name, status])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.setHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chevron = NSImageView()
        chevron.image = DeviceIcon.image("chevron.right")
        chevron.contentTintColor = Tokens.Color.label2
        chevron.setAccessibilityElement(false)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [icon, labels])
        stack.addView(chevron, in: .trailing)
        stack.spacing = GroupsPaneLayout.iconToTitleGap
        stack.alignment = .centerY
        stack.toolTip = record.secondaryText
        return stack
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        if table.clickedRow >= 0 {
            open(row: table.clickedRow)
        } else if table.selectedRowIndexes.count == 1, let row = table.selectedRowIndexes.first {
            open(row: row)
        }
    }

    private func openSelectedRow() {
        guard table.selectedRowIndexes.count == 1, let row = table.selectedRowIndexes.first else { return }
        open(row: row)
    }

    private func open(row: Int) {
        guard records.indices.contains(row) else { return }
        onOpenSpeaker?(records[row].id)
    }

    public var test_recordIDs: [String] { records.map(\.id) }
    public var test_bulkTitle: String? { bulkPopup.titleOfSelectedItem }
    public var test_bulkShown: Bool { !bulkStack.isHidden }
    public func test_select(_ ids: Set<String>) {
        table.selectRowIndexes(IndexSet(records.indices.filter { ids.contains(records[$0].id) }), byExtendingSelection: false)
    }
    public func test_selectAll() { table.selectAll(nil) }
    public func test_openSelection() {
        NSApp.sendAction(table.doubleAction!, to: table.target, from: table)
    }
    public func test_pressReturn() {
        table.keyDown(with: NSEvent.keyEvent(with: .keyDown,
                                             location: .zero,
                                             modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: 0,
                                             context: nil,
                                             characters: "\r",
                                             charactersIgnoringModifiers: "\r",
                                             isARepeat: false,
                                             keyCode: 36)!)
    }
    public func test_identityChevron(id: String) -> NSImageView? {
        guard let row = records.firstIndex(where: { $0.id == id }),
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { return nil }
        cell.layoutSubtreeIfNeeded()
        return (cell as? NSStackView)?.arrangedSubviews.last as? NSImageView
    }
    public var test_visibilityColumnTitle: String? {
        table.headerView == nil ? nil : table.tableColumns.last?.headerCell.stringValue
    }
    public func test_visibilityPopup(id: String) -> NSPopUpButton? {
        guard let row = records.firstIndex(where: { $0.id == id }) else { return nil }
        guard let cell = table.view(atColumn: 1, row: row, makeIfNecessary: true) else { return nil }
        cell.layoutSubtreeIfNeeded()
        return cell.subviews.compactMap { $0 as? NSPopUpButton }.first
    }
    public func test_changeVisibility(_ value: SpeakerMixerVisibility, id: String) {
        guard let popup = test_visibilityPopup(id: id) else { return }
        popup.selectItem(withTitle: value.label)
        NSApp.sendAction(popup.action!, to: popup.target, from: popup)
    }
    public func test_changeBulkVisibility(_ value: SpeakerMixerVisibility) {
        bulkPopup.selectItem(withTitle: value.label)
        NSApp.sendAction(bulkPopup.action!, to: bulkPopup.target, from: bulkPopup)
    }
}

private final class SpeakersTableView: NSTableView {
    var onOpenSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, selectedRowIndexes.count == 1 {
            onOpenSelection?()
            return
        }
        super.keyDown(with: event)
    }
}
