// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The Speakers landing page, behind the sidebar's Speakers plate. It lists no
/// speakers — the sidebar is the speaker list — and shows only the rows that
/// are true right now: whether every speaker has been found, Bluetooth access,
/// speakers the Mac can't find, and Pair. It changes nothing itself; every
/// action is reported out for the host to perform.
@MainActor
public final class SpeakersPageViewController: NSViewController {

    private let library: SpeakerLibraryController
    private let groupController: GroupController

    public var onBluetoothAccess: (() -> Void)?
    public var onPairBluetooth: (() -> Void)?
    /// Forget the speakers the Mac can't find. The host asks first.
    public var onForget: ((Set<String>) -> Void)?

    private var bluetoothAccess: SpeakerBluetoothAccessPresentation?
    private let iconWell = DeviceIconWellView()
    private let titleLabel = NSTextField(labelWithString: "Speakers")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let listWell = GroupedSectionView()
    private let listStack = NSStackView()
    private let spinner = NSProgressIndicator()
    /// The ids the lost-speaker row's Forget button reports.
    private var lostIDs: Set<String> = []

    public init(library: SpeakerLibraryController, groupController: GroupController) {
        self.library = library
        self.groupController = groupController
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        let root = WarmPanelView()
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)

        iconWell.translatesAutoresizingMaskIntoConstraints = false
        iconWell.isEditable = false
        iconWell.iconImageView.image = DeviceIcon.image("hifispeaker.2")
        iconWell.setAccessibilityLabel("Speakers")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Tokens.Font.heading
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = Tokens.Font.caption
        subtitleLabel.textColor = Tokens.Color.label2
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityElement(false)

        // The scene editor's outlined membership list.
        listWell.style = .card
        listWell.contentLeadingInset = ListRowView.leadingInset
        listWell.translatesAutoresizingMaskIntoConstraints = false
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0

        for v in [listWell, iconWell, titleLabel, subtitleLabel, listStack] {
            column.addSubview(v)
        }

        let columnFill = column.trailingAnchor.constraint(
            equalTo: root.trailingAnchor, constant: -GroupsPaneLayout.columnTrailingInset)
        columnFill.priority = .defaultHigh

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: GroupsPaneLayout.columnTopInset),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: GroupsPaneLayout.columnInset),
            column.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor,
                                             constant: -GroupsPaneLayout.columnTrailingInset),
            column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor,
                                           constant: -GroupsPaneLayout.paneBottomInset),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: GroupsPaneLayout.contentMaxWidth),
            columnFill,

            // The same opening as every other page: well, name, one caption.
            iconWell.topAnchor.constraint(equalTo: column.topAnchor, constant: GroupsPaneLayout.headerPadding),
            iconWell.leadingAnchor.constraint(equalTo: column.leadingAnchor,
                                              constant: GroupsPaneLayout.contentLeadingInset),
            iconWell.widthAnchor.constraint(equalToConstant: DeviceIconWellView.size),
            iconWell.heightAnchor.constraint(equalToConstant: DeviceIconWellView.size),
            titleLabel.leadingAnchor.constraint(equalTo: iconWell.trailingAnchor,
                                                constant: GroupsPaneLayout.iconToTitleGap),
            titleLabel.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor,
                                                 constant: -GroupsPaneLayout.contentTrailingInset),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor,
                                                    constant: -GroupsPaneLayout.contentTrailingInset),

            listStack.topAnchor.constraint(equalTo: iconWell.bottomAnchor,
                                           constant: GroupsPaneLayout.headerPadding + GroupsPaneLayout.sectionGap),
            listStack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            listWell.topAnchor.constraint(equalTo: listStack.topAnchor),
            listWell.bottomAnchor.constraint(equalTo: listStack.bottomAnchor),
            listWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            listWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
        ])
        view = root
        reload()
    }

    /// The Bluetooth access state the host read; `nil` hides the row.
    public func setBluetoothAccess(_ presentation: SpeakerBluetoothAccessPresentation?) {
        bluetoothAccess = presentation
        reload()
    }

    /// Rebuild the page from the library and the saved scenes.
    public func reload() {
        guard isViewLoaded else { return }
        let records = library.records
        let n = records.count
        let hidden = records.filter { $0.visibility == .hideWhenNotInUse && !$0.isLocalDevice }.count
        subtitleLabel.stringValue =
            "\(n == 1 ? "1 speaker" : "\(n) speakers"): \(n - hidden) in the Mixer, \(hidden) hidden"

        for row in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        var rows: [NSView] = []

        let speakers = records.filter { !$0.isLocalDevice }
        if speakers.allSatisfy(\.isAvailable) {
            spinner.stopAnimation(nil)
            spinner.removeFromSuperview()
            rows.append(ListRowView(
                glyph: ListRowView.glyph("checkmark.circle.fill", tint: .systemGreen),
                title: n == 1 ? "1 speaker found on your network" : "All \(n) speakers found on your network"))
        } else {
            spinner.startAnimation(nil)
            rows.append(ListRowView(glyph: spinner, title: "Looking for speakers on your network\u{2026}"))
        }

        if let access = bluetoothAccess, let explanation = access.explanation {
            rows.append(ListRowView(
                glyph: ListRowView.glyph(Device.Kind.bluetooth.symbolName),
                title: "Bluetooth access is off", caption: explanation,
                accessory: access.actionTitle.map { makeButton($0, action: #selector(bluetoothAccessTapped(_:))) }))
        }

        lostIDs = Set(speakers.filter { $0.liveDevice == nil }.map(\.id))
        if !lostIDs.isEmpty {
            let k = lostIDs.count
            let m = groupController.groups.filter { !Set($0.memberIDs).isDisjoint(with: lostIDs) }.count
            let caption: String
            switch (k == 1, m) {
            case (true, 0): caption = "It isn\u{2019}t in any scene."
            case (false, 0): caption = "They aren\u{2019}t in any scene."
            case (true, _): caption = "Forgetting it takes it out of \(m == 1 ? "1 scene" : "\(m) scenes")."
            case (false, _): caption = "Forgetting them takes them out of \(m == 1 ? "1 scene" : "\(m) scenes")."
            }
            rows.append(ListRowView(
                glyph: ListRowView.glyph("exclamationmark.triangle", tint: Tokens.Color.failure),
                title: k == 1 ? "1 speaker can\u{2019}t be found" : "\(k) speakers can\u{2019}t be found",
                caption: caption,
                accessory: makeButton(k == 1 ? "Forget 1 speaker\u{2026}" : "Forget \(k) speakers\u{2026}",
                                      action: #selector(forgetTapped(_:)))))
        }

        rows.append(makePairRow())

        for row in rows {
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
        listWell.rows = rows
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    /// The whole row is one borderless button, built like the speaker page's
    /// scene links: the row's text rides on it and passes every click through.
    private func makePairRow() -> NSView {
        let button = NSButton()
        button.cell = GroupRowButtonCell()
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.title = ""
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(pairTapped(_:))
        let title = "Pair Bluetooth speaker\u{2026}"
        let caption = "Opens Bluetooth settings to pair a new speaker."
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(caption)

        let chevron = ClickThroughImageView()
        chevron.image = DeviceIcon.image("chevron.right")
        chevron.contentTintColor = Tokens.Color.label2
        let row = ListRowView(glyph: ListRowView.glyph("plus.circle"), title: title, caption: caption,
                              accessory: chevron)
        row.isClickThrough = true
        button.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            row.topAnchor.constraint(equalTo: button.topAnchor),
            row.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        return button
    }

    @objc private func bluetoothAccessTapped(_ sender: NSButton) { onBluetoothAccess?() }
    @objc private func forgetTapped(_ sender: NSButton) { onForget?(lostIDs) }
    @objc private func pairTapped(_ sender: NSButton) { onPairBluetooth?() }

    // MARK: Test-support hooks

    public var test_subtitleText: String {
        loadViewIfNeeded()
        return subtitleLabel.stringValue
    }

    /// The rows' titles, top to bottom.
    public var test_rowTitles: [String] {
        loadViewIfNeeded()
        return listStack.arrangedSubviews.compactMap { Self.listRow(in: $0)?.titleLabel.stringValue }
    }

    public var test_discoveryShowsSpinner: Bool {
        loadViewIfNeeded()
        return spinner.superview != nil
    }

    public func test_rowButtonTitle(forRowTitled title: String) -> String? {
        rowButton(forRowTitled: title)?.title
    }

    public func test_rowCaption(forRowTitled title: String) -> String? {
        loadViewIfNeeded()
        return listStack.arrangedSubviews.compactMap { Self.listRow(in: $0) }
            .first { $0.titleLabel.stringValue == title }?.caption
    }

    public func test_clickRowButton(forRowTitled title: String) {
        rowButton(forRowTitled: title)?.performClick(nil)
    }

    public func test_clickPairRow() {
        loadViewIfNeeded()
        (listStack.arrangedSubviews.last as? NSButton)?.performClick(nil)
    }

    private func rowButton(forRowTitled title: String) -> NSButton? {
        loadViewIfNeeded()
        return listStack.arrangedSubviews.compactMap { Self.listRow(in: $0) }
            .first { $0.titleLabel.stringValue == title }?.accessory as? NSButton
    }

    /// The list row a stacked view is, or carries (the Pair row's button).
    private static func listRow(in view: NSView) -> ListRowView? {
        view as? ListRowView ?? view.subviews.lazy.compactMap { $0 as? ListRowView }.first
    }
}
