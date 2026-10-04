// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// Every kept speaker counted by kind and by whether the Mac can reach it.
/// The Speakers page draws these and `SpeakerSearch` reports them once.
struct SpeakerLibraryCounts: Equatable {
    var airplay = 0, bluetooth = 0, cast = 0, mac = 0, unknown = 0
    /// Speakers other than this Mac: seen and reachable, seen but away, or
    /// not seen at all this launch.
    var found = 0, away = 0, lost = 0
    var total = 0

    init(_ records: [SpeakerPresentationRecord]) {
        total = records.count
        for record in records {
            switch record.kind {
            case nil: unknown += 1
            case .localMac: mac += 1
            case .bluetooth: bluetooth += 1
            case .cast: cast += 1
            case .homePod, .appleTV, .airportExpress, .sonos, .generic: airplay += 1
            }
            guard !record.isLocalDevice else { continue }
            if record.liveDevice == nil { lost += 1 } else if record.isAvailable { found += 1 } else { away += 1 }
        }
    }

    var analyticsProperties: [String: String] {
        ["airplay": String(airplay), "bluetooth": String(bluetooth), "cast": String(cast), "mac": String(mac),
         "unknown": String(unknown), "found": String(found), "away": String(away), "lost": String(lost),
         "total": String(total)]
    }
}

/// Decides, once per launch, when the search for speakers is done: the list
/// of speakers the Mac can see has stopped changing for the quiet window, or
/// the ceiling ran out on a network that never goes quiet. Reaching every
/// speaker is not required. The app builds it at launch, so the counts event
/// fires whether or not anyone opens the Speakers page.
@MainActor
public final class SpeakerSearch {

    /// The quiet window the popover's first open waits on
    /// (`AppSurfaceController.revealQuietWindow`).
    public static let quietWindow: TimeInterval = 0.5
    /// razor: a fixed backstop from the first speaker seen; tune it if a real
    /// network's discovery routinely outlasts it.
    public static let ceiling: TimeInterval = 10

    public private(set) var isDone = false
    public var onDone: (() -> Void)?

    private let library: SpeakerLibraryController
    private let tracker: DiscoverySettleTracker
    private let schedule: (_ delay: TimeInterval, _ fire: @escaping () -> Void) -> Void
    private var ceilingArmed = false

    public init(library: SpeakerLibraryController,
                schedule: @escaping (_ delay: TimeInterval, _ fire: @escaping () -> Void) -> Void = { delay, fire in
                    Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                        MainActor.assumeIsolated { fire() }
                    }
                }) {
        self.library = library
        self.schedule = schedule
        tracker = DiscoverySettleTracker(quietWindow: Self.quietWindow, schedule: schedule)
        tracker.onSettled = { [weak self] in self?.finish() }
    }

    /// Call after every library update. An empty list is not fed: discovery
    /// starts empty, and an empty list would settle before anything arrived.
    public func libraryDidChange() {
        guard !isDone else { return }
        let ids = Set(library.records.filter { $0.liveDevice != nil }.map(\.id))
        guard !ids.isEmpty else { return }
        if !ceilingArmed {
            ceilingArmed = true
            schedule(Self.ceiling) { [weak self] in self?.finish() }
        }
        tracker.note(deviceIDs: ids)
    }

    private func finish() {
        guard !isDone else { return }
        isDone = true
        Analytics.capture("speaker:library_counted", SpeakerLibraryCounts(library.records).analyticsProperties)
        onDone?()
    }
}

/// The Speakers landing page, behind the sidebar's Speakers plate. It lists no
/// speakers (the sidebar is the speaker list). Its caption line is the search
/// result, and one card holds the speakers counted by kind and then only the
/// rows that are true right now: Bluetooth access, speakers the Mac can't
/// find, and Pair. It changes nothing itself; every action is reported out for
/// the host to perform.
@MainActor
public final class SpeakersPageViewController: NSViewController {

    private let library: SpeakerLibraryController
    private let groupController: GroupController

    public var onBluetoothAccess: (() -> Void)?
    public var onPairBluetooth: (() -> Void)?
    /// Forget the speakers the Mac can't find. The host asks first.
    public var onForget: ((Set<String>) -> Void)?

    private var bluetoothAccess: SpeakerBluetoothAccessPresentation?
    /// Whether the host's `SpeakerSearch` has finished. Until then the caption
    /// says it is still looking and the lost-speaker row waits, so a cold
    /// launch never flashes every remembered speaker as lost. Stored only:
    /// the host reloads the page while it is on screen
    /// (`MixerWindowController.setSpeakerSearchDone`).
    public var isSearchDone = false
    private let iconWell = DeviceIconWellView()
    private let titleLabel = NSTextField(labelWithString: "Speakers")
    private let subtitleStack = NSStackView()
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
        subtitleStack.translatesAutoresizingMaskIntoConstraints = false
        subtitleStack.orientation = .horizontal
        subtitleStack.alignment = .centerY
        subtitleStack.spacing = 5
        subtitleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityElement(false)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 12).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 12).isActive = true

        // The scene editor's outlined membership list.
        listWell.style = .card
        listWell.contentLeadingInset = ListRowView.leadingInset
        listWell.translatesAutoresizingMaskIntoConstraints = false
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        // The card ends at its last row; the pane below it stays empty.
        listStack.setHuggingPriority(.defaultHigh, for: .vertical)

        for v in [listWell, iconWell, titleLabel, subtitleStack, listStack] {
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
            subtitleStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleStack.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor,
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

    /// The Bluetooth access state the host read; `nil` hides the row. Stored
    /// only, like ``isSearchDone``.
    public func setBluetoothAccess(_ presentation: SpeakerBluetoothAccessPresentation?) {
        bluetoothAccess = presentation
    }

    /// Rebuild the page from the library and the saved scenes.
    public func reload() {
        guard isViewLoaded else { return }
        let records = library.records
        let counts = SpeakerLibraryCounts(records)
        reloadSubtitle(counts)

        for row in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        var rows: [NSView] = [makeKindsRow(counts)]

        if let access = bluetoothAccess, let explanation = access.explanation {
            rows.append(makeRow(
                glyph: ListRowView.glyph(Device.Kind.bluetooth.symbolName),
                title: "Bluetooth access is off", help: explanation,
                accessory: access.actionTitle.map { makeButton($0, action: #selector(bluetoothAccessTapped(_:))) }))
        }

        let lost = records.filter { !$0.isLocalDevice && $0.liveDevice == nil }
        lostIDs = isSearchDone ? Set(lost.map(\.id)) : []
        if !lostIDs.isEmpty {
            let k = lostIDs.count
            let m = groupController.groups.filter { !Set($0.memberIDs).isDisjoint(with: lostIDs) }.count
            let help: String
            switch (k == 1, m) {
            case (true, 0): help = "It isn\u{2019}t in any scene."
            case (false, 0): help = "They aren\u{2019}t in any scene."
            case (true, _): help = "Forgetting it takes it out of \(m == 1 ? "1 scene" : "\(m) scenes")."
            case (false, _): help = "Forgetting them takes them out of \(m == 1 ? "1 scene" : "\(m) scenes")."
            }
            rows.append(makeRow(
                glyph: ListRowView.glyph("exclamationmark.triangle", tint: Tokens.Color.failure),
                title: k == 1 ? "1 speaker can\u{2019}t be found" : "\(k) speakers can\u{2019}t be found",
                help: help,
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

    /// The caption line under the title is the search result.
    private func reloadSubtitle(_ counts: SpeakerLibraryCounts) {
        for part in subtitleStack.arrangedSubviews {
            subtitleStack.removeArrangedSubview(part)
            part.removeFromSuperview()
        }
        var parts: [NSView] = []
        if !isSearchDone {
            spinner.startAnimation(nil)
            parts = [spinner, captionField("Looking for speakers on your network\u{2026}"), captionField("\u{00B7}"),
                     captionField("\(counts.found + counts.away) found so far")]
        } else {
            spinner.stopAnimation(nil)
            let check = ListRowView.glyph("checkmark.circle.fill", tint: .systemGreen)
            parts = [check]
            if counts.away == 0 && counts.lost == 0 {
                parts.append(captionField(counts.total == 1 ? "1 speaker found" : "All \(counts.total) speakers found"))
            } else {
                parts += [captionField("Done looking"), captionField("\u{00B7}"), presenceDot(.found),
                          captionField("\(counts.found) found")]
                if counts.away > 0 {
                    parts += [captionField("\u{00B7}"), presenceDot(.away), captionField("\(counts.away) away")]
                }
            }
        }
        for part in parts {
            if part is NSImageView {
                part.translatesAutoresizingMaskIntoConstraints = false
                part.widthAnchor.constraint(equalToConstant: 12).isActive = true
                part.heightAnchor.constraint(equalToConstant: 12).isActive = true
            }
            subtitleStack.addArrangedSubview(part)
        }
    }

    private func captionField(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = Tokens.Font.caption
        field.textColor = Tokens.Color.label2
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// The sidebar's own presence dot, drawn small beside its count.
    private func presenceDot(_ state: SidebarPresenceDotView.State) -> SidebarPresenceDotView {
        let dot = SidebarPresenceDotView()
        dot.state = state
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        return dot
    }

    /// The card's first row: a glyph, a count and a label for each kind of
    /// speaker kept, leaving out the kinds with none.
    private func makeKindsRow(_ counts: SpeakerLibraryCounts) -> NSView {
        let kinds: [(symbol: String, count: Int, label: String)] = [
            ("airplayaudio", counts.airplay, "AirPlay"),
            (Device.Kind.bluetooth.symbolName, counts.bluetooth, "Bluetooth"),
            (Device.Kind.cast.symbolName, counts.cast, "Cast"),
            (Device.Kind.localMac.symbolName, counts.mac, "This Mac"),
            ("questionmark.circle", counts.unknown, "Unknown"),
        ].filter { $0.count > 0 }

        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.distribution = .fillEqually
        strip.alignment = .top
        strip.spacing = 0
        strip.translatesAutoresizingMaskIntoConstraints = false
        for kind in kinds {
            let glyph = ListRowView.glyph(kind.symbol)
            glyph.translatesAutoresizingMaskIntoConstraints = false
            glyph.widthAnchor.constraint(equalToConstant: 16).isActive = true
            glyph.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let count = NSTextField(labelWithString: "\(kind.count)")
            count.font = Tokens.Font.heading
            count.textColor = Tokens.Color.label
            count.setAccessibilityElement(false)
            let top = NSStackView(views: [glyph, count])
            top.orientation = .horizontal
            top.alignment = .centerY
            top.spacing = 6
            let label = captionField(kind.label)
            label.setAccessibilityElement(false)
            let item = NSStackView(views: [top, label])
            item.orientation = .vertical
            item.alignment = .leading
            item.spacing = 1
            item.setAccessibilityElement(true)
            item.setAccessibilityRole(.staticText)
            item.setAccessibilityLabel("\(kind.count) \(kind.label)")
            strip.addArrangedSubview(item)
        }

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
            strip.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -11),
            strip.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: ListRowView.leadingInset),
            strip.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
        ])
        return row
    }

    /// A one-line row whose longer sentence is its tooltip and VoiceOver hint.
    private func makeRow(glyph: NSView, title: String, help: String, accessory: NSView?) -> ListRowView {
        let row = ListRowView(glyph: glyph, title: title, accessory: accessory)
        row.toolTip = help
        row.titleLabel.setAccessibilityHelp(help)
        return row
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
        button.toolTip = caption

        let chevron = ClickThroughImageView()
        chevron.image = DeviceIcon.image("chevron.right")
        chevron.contentTintColor = Tokens.Color.label2
        let row = ListRowView(glyph: ListRowView.glyph("plus.circle"), title: title, accessory: chevron)
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

    /// The caption line read left to right, the presence dots drawn as
    /// "\u{25CF}" (found) and "\u{25CB}" (away).
    public var test_subtitleText: String {
        loadViewIfNeeded()
        return subtitleStack.arrangedSubviews.compactMap { part -> String? in
            if let field = part as? NSTextField { return field.stringValue }
            if let dot = part as? SidebarPresenceDotView { return dot.state == .found ? "\u{25CF}" : "\u{25CB}" }
            return nil
        }.joined(separator: " ")
    }

    /// The kinds row's items as VoiceOver reads them, left to right.
    public var test_kinds: [String] {
        loadViewIfNeeded()
        guard let strip = listStack.arrangedSubviews.first?.subviews.first as? NSStackView else { return [] }
        return strip.arrangedSubviews.map { $0.accessibilityLabel() ?? "" }
    }

    /// The card's height and the height its rows need, after laying out the
    /// page at `size`.
    public func test_cardHeights(laidOutAt size: NSSize) -> (card: CGFloat, rows: CGFloat) {
        loadViewIfNeeded()
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        return (listWell.frame.height, listStack.arrangedSubviews.map(\.fittingSize.height).reduce(0, +))
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

    /// The row's tooltip, which is also its VoiceOver hint.
    public func test_rowHelp(forRowTitled title: String) -> String? {
        loadViewIfNeeded()
        return listStack.arrangedSubviews.first { Self.listRow(in: $0)?.titleLabel.stringValue == title }
            .flatMap { $0.toolTip }
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
