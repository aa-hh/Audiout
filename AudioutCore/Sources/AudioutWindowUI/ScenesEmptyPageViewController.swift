// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The no-scenes page, with the same header and card geometry as Speakers.
public final class ScenesEmptyPageViewController: NSViewController {
    private let iconWell = DeviceIconWellView()
    private let titleLabel = NSTextField(labelWithString: "Scenes")
    private let captionLabel = NSTextField(labelWithString: "No scenes yet")
    private lazy var header = PageHeaderView(icon: iconWell, title: titleLabel, caption: captionLabel)
    private lazy var addButton = ProminentButton(title: "Add scene…", target: self, action: #selector(addTapped(_:)))
    private lazy var row = ListRowView(title: "Add scene…",
        caption: "Pick the speakers that play together. You switch to a scene from Main Audio in the Mixer.",
        accessory: addButton)
    public var onAddScene: (() -> Void)?

    public override func loadView() {
        let root = WarmPanelView()
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        iconWell.isEditable = false
        iconWell.iconImageView.image = DeviceIcon.image(Group.defaultIconSymbolName)
        iconWell.setAccessibilityLabel("Scenes")
        titleLabel.font = Tokens.Font.heading
        titleLabel.setAccessibilityHeading()
        captionLabel.font = Tokens.Font.caption
        captionLabel.textColor = Tokens.Color.labelCool
        let listWell = GroupedSectionView()
        listWell.style = .card
        listWell.radiusOverride = Tokens.Layout.Radius.row
        listWell.contentLeadingInset = ListRowView.leadingInset
        listWell.contentTrailingInset = ListRowView.trailingInset
        listWell.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        for view in [listWell, header, stack] { column.addSubview(view) }
        stack.addArrangedSubview(row)
        listWell.rows = [row]
        let columnFill = column.trailingAnchor.constraint(equalTo: root.trailingAnchor,
            constant: -GroupsPaneLayout.columnTrailingInset)
        columnFill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: GroupsPaneLayout.columnTopInset),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: GroupsPaneLayout.columnInset),
            column.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -GroupsPaneLayout.columnTrailingInset),
            column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -GroupsPaneLayout.paneBottomInset),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: GroupsPaneLayout.contentMaxWidth),
            columnFill,
            header.topAnchor.constraint(equalTo: column.topAnchor),
            header.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: GroupsPaneLayout.sectionGap),
            stack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            listWell.topAnchor.constraint(equalTo: stack.topAnchor),
            listWell.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
            listWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            listWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
    }

    @objc private func addTapped(_ sender: Any?) { onAddScene?() }
    func test_tapAddScene() { addButton.performClick(nil) }
    var test_addButtonIsProminent: Bool { row.accessory is ProminentButton }
    var test_rowTitles: [String] { [row.titleLabel.stringValue] }
    var test_headerFrames: (icon: NSRect, band: NSRect, textBlock: NSRect) {
        loadViewIfNeeded()
        return header.frames(in: view)
    }
}
