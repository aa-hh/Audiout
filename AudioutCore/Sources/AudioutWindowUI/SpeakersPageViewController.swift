// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// Every kept speaker counted by kind and by whether the Mac can reach it.
/// `SpeakerSearch` reports these once, as `speaker:library_counted`'s properties.
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

/// The Overview's five counts and its total. This Mac counts as This Mac
/// whether or not it can play; any other speaker counts under its kind only
/// while the Mac can reach it, and as Unavailable otherwise, a speaker with
/// no saved kind included. Unavailable therefore equals the rows under the
/// sidebar's dividers.
struct SpeakerOverviewCounts: Equatable {
    var airplay = 0, bluetooth = 0, cast = 0, mac = 0, unavailable = 0
    var total = 0

    init(_ records: [SpeakerPresentationRecord]) {
        total = records.count
        for record in records {
            if record.isLocalDevice { mac += 1; continue }
            guard record.isAvailable, let kind = record.kind else { unavailable += 1; continue }
            switch kind {
            case .homePod, .appleTV, .airportExpress, .sonos, .generic: airplay += 1
            case .bluetooth: bluetooth += 1
            case .cast: cast += 1
            case .localMac: mac += 1
            }
        }
    }
}

/// Decides, once per launch, when the search for speakers is done: the list
/// of speakers the Mac can see has stopped changing for the quiet window, or
/// the ceiling ran out on a network that never goes quiet. Reaching every
/// speaker is not required. The app builds it at launch, so the counts event
/// fires whether or not anyone opens the Speakers page.
///
/// Separately, it decides when each kind's count on the Overview is known
/// (``knownKinds``) and which speakers can't be found (``cantBeFoundIDs``),
/// from its start: the first non-empty list or the page's first appearance.
/// `isDone` and `onDone` keep meaning the counts event alone.
@MainActor
public final class SpeakerSearch {

    public enum Kind: CaseIterable { case airplay, bluetooth, cast, thisMac }

    /// The quiet window the popover's first open waits on
    /// (`AppSurfaceController.revealQuietWindow`).
    public static let quietWindow: TimeInterval = 0.5
    /// AirPlay and Cast speakers answer a second or more after the rest:
    /// an AirPlay speaker is listed only once a test connection opens, and
    /// Bonjour waits at least 1 s before asking again.
    public static let networkQuietWindow: TimeInterval = 2.0
    /// razor: a fixed backstop, armed from the first speaker seen for the
    /// counts event and from `start()` for the can't-be-found hold; tune it if a
    /// real network's discovery routinely outlasts it.
    public static let ceiling: TimeInterval = 10

    public private(set) var isDone = false
    public var onDone: (() -> Void)?

    /// The kinds whose Overview count is final. Grows only; every kind is in
    /// it by ``ceiling`` after the start.
    public private(set) var knownKinds: Set<Kind> = []
    public var isEveryKindKnown: Bool { knownKinds.count == Kind.allCases.count }
    /// Read when ``cantBeFoundIDs`` is: paired Bluetooth speakers macOS won't
    /// list without access are not lost.
    public var isBluetoothAccessGranted: () -> Bool = { true }
    /// Read when ``cantBeFoundIDs`` is: with Local Network denied the Mac can't
    /// look for network speakers at all.
    public var isLocalNetworkDenied: () -> Bool = { false }
    /// Fired when ``knownKinds`` grows, when the can't-be-found hold lifts, and
    /// when a library update changes ``cantBeFoundIDs``.
    public var onChange: (() -> Void)?

    private let library: SpeakerLibraryController
    private let tracker: DiscoverySettleTracker
    private let schedule: (_ delay: TimeInterval, _ fire: @escaping () -> Void) -> Void
    private var ceilingArmed = false
    /// One tracker per kind that discovery delivers over time; empty until the start.
    private var kindTrackers: [Kind: DiscoverySettleTracker] = [:]
    private var isHoldLifted = false
    /// Some AirPlay or Cast speaker has had a live device this launch, so the
    /// network is answering. Without it, Wi-Fi off looks like every speaker gone.
    private var hasHeardTheNetwork = false

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

    /// The remembered speakers that have not appeared since launch: empty
    /// until ``ceiling`` after the start, and never a Bluetooth speaker
    /// without access or a network speaker while the network can't answer.
    public var cantBeFoundIDs: Set<String> {
        guard isHoldLifted else { return [] }
        let bluetoothCounts = isBluetoothAccessGranted()
        let networkCounts = hasHeardTheNetwork && !isLocalNetworkDenied()
        return Set(library.records.filter { record in
            guard !record.isLocalDevice, record.liveDevice == nil else { return false }
            if record.kind == .bluetooth { return bluetoothCounts }
            if record.kind?.isDiscoveredOverLocalNetwork ?? true { return networkCounts }
            return true
        }.map(\.id))
    }

    /// Call after every library update. An empty list is not fed to the
    /// counts event: discovery starts empty, and an empty list would settle
    /// before anything arrived.
    public func libraryDidChange() {
        let listBefore = cantBeFoundIDs
        let records = library.records
        let ids = Set(records.filter { $0.liveDevice != nil }.map(\.id))
        if !isDone, !ids.isEmpty {
            if !ceilingArmed {
                ceilingArmed = true
                schedule(Self.ceiling) { [weak self] in self?.finish() }
            }
            tracker.note(deviceIDs: ids)
        }
        if !ids.isEmpty { start() }
        guard !kindTrackers.isEmpty else { return }

        let before = knownKinds.count
        let live = records.filter { $0.liveDevice != nil }
        for (kind, kindTracker) in kindTrackers {
            kindTracker.note(deviceIDs: Set(live.filter { Self.trackedKind(of: $0.kind) == kind }.map(\.id)))
        }
        if live.contains(where: \.isLocalDevice) { knownKinds.insert(.thisMac) }
        if live.contains(where: { $0.kind?.isDiscoveredOverLocalNetwork == true }) { hasHeardTheNetwork = true }
        if knownKinds.count > before || cantBeFoundIDs != listBefore { onChange?() }
    }

    /// The Overview appeared; the search starts here if no speaker has yet.
    public func pageDidAppear() {
        start()
    }

    private func start() {
        guard kindTrackers.isEmpty else { return }
        for (kind, window) in [(Kind.bluetooth, Self.quietWindow), (.airplay, Self.networkQuietWindow),
                               (.cast, Self.networkQuietWindow)] {
            let kindTracker = DiscoverySettleTracker(quietWindow: window, schedule: schedule)
            kindTracker.onSettled = { [weak self] in
                guard let self, knownKinds.insert(kind).inserted else { return }
                onChange?()
            }
            kindTrackers[kind] = kindTracker
            kindTracker.start()
        }
        schedule(Self.ceiling) { [weak self] in
            guard let self else { return }
            knownKinds = Set(Kind.allCases)
            isHoldLifted = true
            onChange?()
        }
    }

    private static func trackedKind(of kind: Device.Kind?) -> Kind? {
        switch kind {
        case .homePod?, .appleTV?, .airportExpress?, .sonos?, .generic?: return .airplay
        case .bluetooth?: return .bluetooth
        case .cast?: return .cast
        case .localMac?, nil: return nil
        }
    }

    private func finish() {
        guard !isDone else { return }
        isDone = true
        Analytics.capture("speaker:library_counted", SpeakerLibraryCounts(library.records).analyticsProperties)
        onDone?()
    }
}

/// The Speakers overview, behind the sidebar's Overview plate. It lists no
/// speakers (the sidebar is the speaker list). Its caption is the total, and
/// one card holds the speakers counted by kind and then only the rows that
/// are true right now: speakers that can't be found, Local Network and
/// Bluetooth access, and Pair. It changes nothing itself; every action is
/// reported out for the host to perform.
@MainActor
public final class SpeakersPageViewController: NSViewController {

    private let library: SpeakerLibraryController
    private let groupController: GroupController

    public var onBluetoothAccess: (() -> Void)?
    public var onPairBluetooth: (() -> Void)?
    /// Forget the speakers the Mac can't find. The host asks first.
    public var onForget: ((Set<String>) -> Void)?
    public var onLocalNetworkAccess: (() -> Void)?
    public var search: SpeakerSearch?

    private var bluetoothAccess: SpeakerBluetoothAccessPresentation?
    private let iconWell = DeviceIconWellView()
    private let titleLabel = NSTextField(labelWithString: "Overview")
    /// The total, or nothing beside the placeholder while a kind is unknown.
    private let captionField = NSTextField(labelWithString: "")
    /// The same opening as the speaker page: well, name, one caption, on the
    /// rail-free inset so the well lines up with the list's text below it.
    private lazy var header = PageHeaderView(iconWell: iconWell, title: titleLabel,
                                             caption: captionField, leadingInset: .railFree)
    private let headerPlaceholder = CountPlaceholderView(size: NSSize(width: 14, height: 8), radius: 2.5)
    private let listWell = GroupedSectionView()
    private let listStack = NSStackView()
    /// AirPlay, Bluetooth, Cast, This Mac, then Unavailable.
    private let tiles = [
        CountTileView(symbol: "airplayaudio", label: "AirPlay", help: "AirPlay speakers on your network right now.",
                      liveInk: Tokens.Color.speakersAccent, sentence: CountTileView.kindSentence("AirPlay")),
        CountTileView(symbol: Device.Kind.bluetooth.symbolName, label: "Bluetooth",
                      help: "Bluetooth speakers connected to this Mac right now.",
                      liveInk: Tokens.Color.speakersAccent, sentence: CountTileView.kindSentence("Bluetooth")),
        CountTileView(symbol: Device.Kind.cast.symbolName, label: "Cast", help: "Cast speakers on your network right now.",
                      liveInk: Tokens.Color.speakersAccent, sentence: CountTileView.kindSentence("Cast")),
        CountTileView(symbol: Device.Kind.localMac.symbolName, label: "This Mac", help: "This Mac\u{2019}s own output.",
                      liveInk: Tokens.Color.speakersAccent, sentence: { count in
                          guard let count else { return "This Mac, still looking" }
                          return count > 0 ? "This Mac, available" : "This Mac, unavailable"
                      }),
        CountTileView(symbol: "antenna.radiowaves.left.and.right.slash", label: "Unavailable",
                      help: "Speakers your Mac can\u{2019}t reach right now, and Bluetooth speakers that aren\u{2019}t connected.",
                      contentInset: 13, liveInk: Tokens.Color.label, sentence: { count in
                          switch count {
                          case nil: return "Unavailable, still looking"
                          case 0?: return "No speakers unavailable"
                          case 1?: return "1 speaker unavailable"
                          case let n?: return "\(n) speakers unavailable"
                          }
                      }),
    ]
    // The card's rows, built once and shown, hidden and retitled in place, so
    // an update never takes a button (or the focus on it) away.
    private lazy var forgetButton = makeButton("", action: #selector(forgetTapped(_:)))
    private lazy var cantBeFoundRow = ListRowView(
        glyph: ListRowView.glyph("questionmark.circle", tint: Tokens.Color.labelCool2), title: "",
        accessory: forgetButton)
    private lazy var localNetworkRow = makeRow(
        glyph: ListRowView.glyph("wifi", tint: Tokens.Color.labelCool2), title: "Local Network access is off",
        help: "Allow Local Network access in System Settings to see AirPlay and Cast speakers.",
        accessory: makeButton("Open Privacy Settings\u{2026}", action: #selector(localNetworkTapped(_:))))
    private lazy var bluetoothButton = makeButton("", action: #selector(bluetoothAccessTapped(_:)))
    private lazy var bluetoothRow = ListRowView(
        glyph: ListRowView.glyph(Device.Kind.bluetooth.symbolName, tint: Tokens.Color.labelCool2),
        title: "Bluetooth access is off", accessory: bluetoothButton)
    /// Set by `viewDidAppear`, cleared by `viewDidDisappear`.
    private var isOnScreen = false
    /// The one clock every placeholder's highlight runs on.
    private var shimmerBase: CFTimeInterval?
    /// The page last showed the search still looking, on screen.
    private var wasLookingOnScreen = false

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

        iconWell.isEditable = false
        iconWell.iconImageView.image = DeviceIcon.image("hifispeaker.2")
        iconWell.setAccessibilityLabel("Speakers")
        titleLabel.font = Tokens.Font.heading
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityHeading()
        captionField.textColor = Tokens.Color.labelCool
        captionField.lineBreakMode = .byTruncatingTail
        captionField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The scene editor's outlined membership list.
        listWell.style = .card
        listWell.contentLeadingInset = ListRowView.leadingInset
        listWell.contentTrailingInset = ListRowView.trailingInset
        listWell.translatesAutoresizingMaskIntoConstraints = false
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        // The card ends at its last row; the pane below it stays empty.
        listStack.setHuggingPriority(.defaultHigh, for: .vertical)

        for v in [listWell, header, headerPlaceholder, listStack] {
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

            header.topAnchor.constraint(equalTo: column.topAnchor),
            header.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            headerPlaceholder.leadingAnchor.constraint(equalTo: captionField.leadingAnchor),
            headerPlaceholder.centerYAnchor.constraint(equalTo: captionField.centerYAnchor),

            listStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: GroupsPaneLayout.sectionGap),
            listStack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            listWell.topAnchor.constraint(equalTo: listStack.topAnchor),
            listWell.bottomAnchor.constraint(equalTo: listStack.bottomAnchor),
            listWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            listWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
        ])
        for row in [makeKindsRow(), cantBeFoundRow, localNetworkRow, bluetoothRow, makePairRow()] {
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
        view = root
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        reload()
    }

    /// The Bluetooth access state the host read; `nil` hides the row. Stored
    /// only: the host reloads the page while it is on screen.
    public func setBluetoothAccess(_ presentation: SpeakerBluetoothAccessPresentation?) {
        bluetoothAccess = presentation
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        isOnScreen = true
        wasLookingOnScreen = !(search?.isEveryKindKnown ?? true)
        search?.pageDidAppear()
        updateShimmer()
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        isOnScreen = false
        wasLookingOnScreen = false
        placeholders.forEach { $0.stopShimmer() }
    }

    /// Reduce Motion swaps the placeholders for dashes, and back.
    @objc private func accessibilityDisplayChanged() { reload() }

    private var placeholders: [CountPlaceholderView] { [headerPlaceholder] + tiles.map(\.placeholder) }

    /// One highlight crosses every shown placeholder, header first, then the
    /// strip, on one shared clock. Hidden placeholders lose theirs.
    private func updateShimmer() {
        placeholders.filter(\.isHidden).forEach { $0.stopShimmer() }
        let shown = placeholders.filter { !$0.isHidden }
        guard isOnScreen, !shown.isEmpty else { return }
        view.layoutSubtreeIfNeeded()
        let base = shimmerBase ?? CACurrentMediaTime()
        shimmerBase = base
        for placeholder in shown {
            placeholder.startShimmer(x: placeholder.convert(NSPoint.zero, to: view).x,
                                     pageWidth: view.bounds.width, beginTime: base)
        }
    }

    /// Spoken once, when the last kind becomes known while the page is
    /// watched in the key window.
    private func announceIfFinished() {
        let isEveryKindKnown = search?.isEveryKindKnown ?? true
        if wasLookingOnScreen, isEveryKindKnown, isOnScreen, let window = view.window,
           window.isKeyWindow, window.isVisible {
            NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
                .announcement: "Finished looking for speakers.",
                .priority: NSAccessibilityPriorityLevel.low.rawValue,
            ])
        }
        wasLookingOnScreen = isOnScreen && !isEveryKindKnown
    }

    private var isReduceMotionOn: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Update the page in place from the library, the search and the saved
    /// scenes. Nothing is rebuilt, so focus and VoiceOver's place survive.
    public func reload() {
        guard isViewLoaded else { return }
        let records = library.records
        let counts = SpeakerOverviewCounts(records)
        let reduceMotion = isReduceMotionOn
        let animate = view.window?.isVisible == true
        reloadHeader(total: counts.total, isKnown: search?.isEveryKindKnown ?? true,
                     reduceMotion: reduceMotion, animate: animate)
        reloadTiles(counts, reduceMotion: reduceMotion, animate: animate)
        reloadRows(counts)
        updateShimmer()
        announceIfFinished()
    }

    /// Shows only the rows that are true, in the card's fixed order: can't be
    /// found, Local Network, Bluetooth, Pair.
    private func reloadRows(_ counts: SpeakerOverviewCounts) {
        let ids = search?.cantBeFoundIDs ?? []
        cantBeFoundRow.isHidden = ids.isEmpty
        if !ids.isEmpty {
            let k = ids.count, u = counts.unavailable
            let m = groupController.groups.filter { !Set($0.memberIDs).isDisjoint(with: ids) }.count
            let appeared: String
            if k == u {
                appeared = k == 1 ? "It hasn\u{2019}t appeared since Audiout opened."
                                  : "They haven\u{2019}t appeared since Audiout opened."
            } else {
                appeared = "\(k) of the \(u) unavailable speakers \(k == 1 ? "hasn\u{2019}t" : "haven\u{2019}t") appeared since Audiout opened."
            }
            let scenes: String
            switch (k == 1, m) {
            case (true, 0): scenes = "It isn\u{2019}t in any scene."
            case (false, 0): scenes = "They aren\u{2019}t in any scene."
            case (true, _): scenes = "Forgetting it takes it out of \(m == 1 ? "1 scene" : "\(m) scenes")."
            case (false, _): scenes = "Forgetting them takes them out of \(m == 1 ? "1 scene" : "\(m) scenes")."
            }
            cantBeFoundRow.titleLabel.stringValue = k == 1 ? "1 speaker can\u{2019}t be found"
                                                           : "\(k) speakers can\u{2019}t be found"
            setHelp(appeared + " " + scenes, on: cantBeFoundRow)
            forgetButton.title = k == 1 ? "Forget 1 speaker\u{2026}" : "Forget \(k) speakers\u{2026}"
        }

        localNetworkRow.isHidden = search?.isLocalNetworkDenied() != true

        let explanation = bluetoothAccess?.explanation
        bluetoothRow.isHidden = explanation == nil
        if let explanation {
            setHelp(explanation, on: bluetoothRow)
            bluetoothButton.title = bluetoothAccess?.actionTitle ?? ""
            bluetoothButton.isHidden = bluetoothAccess?.actionTitle == nil
        }
        listWell.rows = visibleRows
    }

    private var visibleRows: [NSView] { listStack.arrangedSubviews.filter { !$0.isHidden } }

    /// The caption under the title: the total once every kind is known;
    /// until then the placeholder alone, or the words under Reduce Motion.
    private func reloadHeader(total: Int, isKnown: Bool, reduceMotion: Bool, animate: Bool) {
        guard isKnown else {
            captionField.font = reduceMotion ? Tokens.Font.caption : Tokens.Font.captionDigits
            captionField.stringValue = reduceMotion ? "Looking for speakers\u{2026}" : ""
            captionField.setAccessibilityValue("Looking for speakers")
            headerPlaceholder.isHidden = reduceMotion
            headerPlaceholder.alphaValue = 1
            return
        }
        let text = total == 0 ? "No speakers" : total == 1 ? "1 speaker" : "\(total) speakers"
        let arrives = captionField.stringValue != text
        captionField.font = Tokens.Font.captionDigits
        captionField.stringValue = text
        captionField.setAccessibilityValue(text)
        if arrives { reveal(captionField, hiding: headerPlaceholder, animate: animate) }
    }

    /// The card's first row: "Available" over the four kind tiles, then
    /// Unavailable behind a rule. Counts share one baseline, labels another.
    private func makeKindsRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel("Speaker counts")

        let available = NSTextField(labelWithString: "Available")
        available.font = Tokens.Font.captionEmphasized
        available.textColor = Tokens.Color.speakersAccent
        available.setAccessibilityHeading()
        let availableRule = makeRule()
        let kindTiles = NSStackView(views: Array(tiles.prefix(4)))
        kindTiles.orientation = .horizontal
        kindTiles.distribution = .fillEqually
        kindTiles.alignment = .top
        kindTiles.spacing = 0
        let unavailable = tiles[4]
        let unavailableRule = makeRule()
        for v in [available, availableRule, kindTiles, unavailable, unavailableRule] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }

        // Unavailable hugs its content at its minimum, below the labels'
        // resistance, so a long translation widens it before truncating.
        let hug = unavailable.widthAnchor.constraint(equalToConstant: Self.unavailableMinWidth)
        hug.priority = .defaultHigh - 10
        let top: CGFloat = 12, bottom: CGFloat = 11
        NSLayoutConstraint.activate([
            available.topAnchor.constraint(equalTo: row.topAnchor, constant: top),
            available.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: ListRowView.leadingInset),
            availableRule.leadingAnchor.constraint(equalTo: available.trailingAnchor, constant: 8),
            availableRule.trailingAnchor.constraint(equalTo: kindTiles.trailingAnchor, constant: -12),
            availableRule.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            availableRule.heightAnchor.constraint(equalToConstant: 1),
            availableRule.centerYAnchor.constraint(equalTo: available.firstBaselineAnchor, constant: -3),
            kindTiles.topAnchor.constraint(equalTo: available.bottomAnchor, constant: 4),
            kindTiles.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: ListRowView.leadingInset),
            kindTiles.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -bottom),
            unavailable.leadingAnchor.constraint(equalTo: kindTiles.trailingAnchor),
            unavailable.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            unavailable.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.unavailableMinWidth),
            unavailable.widthAnchor.constraint(lessThanOrEqualToConstant: 126),
            hug,
            unavailableRule.leadingAnchor.constraint(equalTo: unavailable.leadingAnchor),
            unavailableRule.widthAnchor.constraint(equalToConstant: 1),
            unavailableRule.topAnchor.constraint(equalTo: row.topAnchor, constant: top + 2),
            unavailableRule.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -bottom - 2),
        ] + tiles.dropFirst().map {
            $0.countField.firstBaselineAnchor.constraint(equalTo: tiles[0].countField.firstBaselineAnchor)
        } + tiles.prefix(4).map {
            $0.widthAnchor.constraint(greaterThanOrEqualToConstant: 62)
        })
        return row
    }

    private static let unavailableMinWidth: CGFloat = 77.4

    /// A 1 pt `containerEdge` rule; `hairline` is too faint on `raised`.
    private func makeRule() -> NSBox {
        let rule = NSBox()
        rule.boxType = .custom
        rule.titlePosition = .noTitle
        rule.borderWidth = 0
        rule.fillColor = Tokens.Color.containerEdge
        rule.redrawOnAccessibilityDisplayChange()
        rule.setAccessibilityElement(false)
        return rule
    }

    /// Each tile's count, or nil while its kind is still being looked for.
    private func reloadTiles(_ counts: SpeakerOverviewCounts, reduceMotion: Bool, animate: Bool) {
        let known = search?.knownKinds ?? Set(SpeakerSearch.Kind.allCases)
        let values: [Int?] = [
            known.contains(.airplay) ? counts.airplay : nil,
            known.contains(.bluetooth) ? counts.bluetooth : nil,
            known.contains(.cast) ? counts.cast : nil,
            known.contains(.thisMac) ? counts.mac : nil,
            search?.isEveryKindKnown ?? true ? counts.unavailable : nil,
        ]
        for (tile, value) in zip(tiles, values) {
            tile.apply(value, reduceMotion: reduceMotion, animate: animate)
        }
    }

    /// A one-line row whose longer sentence is its tooltip and VoiceOver hint.
    private func makeRow(glyph: NSView, title: String, help: String, accessory: NSView?) -> ListRowView {
        let row = ListRowView(glyph: glyph, title: title, accessory: accessory)
        setHelp(help, on: row)
        return row
    }

    private func setHelp(_ help: String, on row: ListRowView) {
        row.toolTip = help
        row.titleLabel.setAccessibilityHelp(help)
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
        chevron.contentTintColor = Tokens.Color.labelCool2
        let row = ListRowView(glyph: ListRowView.glyph("plus.circle", tint: Tokens.Color.speakersAccent),
                              title: title, accessory: chevron)
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
    @objc private func forgetTapped(_ sender: NSButton) { onForget?(search?.cantBeFoundIDs ?? []) }
    @objc private func localNetworkTapped(_ sender: NSButton) { onLocalNetworkAccess?() }
    @objc private func pairTapped(_ sender: NSButton) { onPairBluetooth?() }

    // MARK: Test-support hooks

    public var test_reduceMotionOverride: Bool?
    /// The header's well, band and text block, in the page's own coordinates.
    public var test_headerFrames: (icon: NSRect, band: NSRect, textBlock: NSRect) {
        loadViewIfNeeded()
        return header.frames(in: view)
    }
    /// Where the card's first list row starts its content (its glyph, or its
    /// title when it has none), measured from the card's own edge.
    public var test_listRowContentInset: CGFloat? {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        guard let row = visibleRows.lazy.compactMap(Self.listRow(in:)).first,
              let lead = row.subviews.filter({ !$0.isHidden })
                .map({ $0.alignmentRect(forFrame: $0.convert($0.bounds, to: view)).minX }).min()
        else { return nil }
        return lead - listWell.convert(listWell.bounds, to: view).minX
    }
    /// The caption under the title as drawn; empty while the placeholder stands alone.
    public var test_headerCaption: String {
        loadViewIfNeeded()
        return captionField.stringValue
    }
    /// Each count tile's spoken sentence, left to right.
    public var test_tileValues: [String] {
        loadViewIfNeeded()
        return tiles.map { $0.accessibilityValue() as? String ?? "" }
    }
    /// Placeholders standing in for a count or the total right now.
    public var test_placeholderCount: Int {
        loadViewIfNeeded()
        return placeholders.filter { !$0.isHidden }.count
    }
    /// The can't-be-found row's Forget button as the card holds it now.
    public var test_forgetButton: NSButton? {
        loadViewIfNeeded()
        return listStack.arrangedSubviews.lazy.compactMap { Self.listRow(in: $0)?.accessory as? NSButton }
            .first { $0.action == #selector(self.forgetTapped(_:)) }
    }

    /// The card's height and the height its rows need, after laying out the
    /// page at `size`.
    public func test_cardHeights(laidOutAt size: NSSize) -> (card: CGFloat, rows: CGFloat) {
        loadViewIfNeeded()
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        return (listWell.frame.height, visibleRows.map(\.fittingSize.height).reduce(0, +))
    }

    /// The shown row's height as laid out and the height its content needs.
    public func test_rowHeights(forRowTitled title: String) -> (frame: CGFloat, fitting: CGFloat)? {
        loadViewIfNeeded()
        return visibleRows.first { Self.listRow(in: $0)?.titleLabel.stringValue == title }
            .map { ($0.frame.height, $0.fittingSize.height) }
    }

    /// The shown rows' titles, top to bottom.
    public var test_rowTitles: [String] {
        loadViewIfNeeded()
        return visibleRows.compactMap { Self.listRow(in: $0)?.titleLabel.stringValue }
    }

    public func test_rowButtonTitle(forRowTitled title: String) -> String? {
        rowButton(forRowTitled: title)?.title
    }

    /// The row's tooltip, which is also its VoiceOver hint.
    public func test_rowHelp(forRowTitled title: String) -> String? {
        loadViewIfNeeded()
        return visibleRows.first { Self.listRow(in: $0)?.titleLabel.stringValue == title }
            .flatMap { $0.toolTip }
    }

    public func test_clickRowButton(forRowTitled title: String) {
        rowButton(forRowTitled: title)?.performClick(nil)
    }

    public func test_clickPairRow() {
        loadViewIfNeeded()
        (visibleRows.last as? NSButton)?.performClick(nil)
    }

    private func rowButton(forRowTitled title: String) -> NSButton? {
        loadViewIfNeeded()
        return visibleRows.compactMap { Self.listRow(in: $0) }
            .first { $0.titleLabel.stringValue == title }?.accessory as? NSButton
    }

    /// The list row a stacked view is, or carries (the Pair row's button).
    private static func listRow(in view: NSView) -> ListRowView? {
        view as? ListRowView ?? view.subviews.lazy.compactMap { $0 as? ListRowView }.first
    }
}

/// One count on the Overview's strip: a glyph, the count and its label, with
/// the count's placeholder over an invisible "00" while the count is
/// unknown, so the line never changes height when the number lands. One
/// spoken element whose value is the tile's sentence.
@MainActor
private final class CountTileView: NSView {

    let countField = NSTextField(labelWithString: "00")
    let placeholder = CountPlaceholderView(size: NSSize(width: 20, height: 12), radius: 3)
    private let liveInk: NSColor
    private let sentence: (Int?) -> String
    private enum Shown { case nothing, unknown, count(Int) }
    private var shown = Shown.nothing

    /// "4 AirPlay speakers available", "No Cast speakers available",
    /// "AirPlay, still looking".
    static func kindSentence(_ kind: String) -> (Int?) -> String {
        { count in
            switch count {
            case nil: return "\(kind), still looking"
            case 0?: return "No \(kind) speakers available"
            case 1?: return "1 \(kind) speaker available"
            case let n?: return "\(n) \(kind) speakers available"
            }
        }
    }

    init(symbol: String, label: String, help: String, contentInset: CGFloat = 0, liveInk: NSColor,
         sentence: @escaping (Int?) -> String) {
        self.liveInk = liveInk
        self.sentence = sentence
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let glyph = ListRowView.glyph(symbol, tint: Tokens.Color.labelCool2)
        countField.font = Tokens.Font.headingDigits
        countField.setAccessibilityElement(false)
        let labelField = NSTextField(labelWithString: label)
        labelField.font = Tokens.Font.caption
        labelField.textColor = Tokens.Color.labelCool
        labelField.lineBreakMode = .byTruncatingTail
        labelField.setAccessibilityElement(false)
        for v in [glyph, countField, labelField, placeholder] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentInset),
            glyph.widthAnchor.constraint(equalToConstant: 16),
            glyph.heightAnchor.constraint(equalToConstant: 16),
            glyph.centerYAnchor.constraint(equalTo: countField.centerYAnchor),
            countField.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
            countField.topAnchor.constraint(equalTo: topAnchor),
            countField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            labelField.leadingAnchor.constraint(equalTo: glyph.leadingAnchor),
            labelField.firstBaselineAnchor.constraint(equalTo: countField.firstBaselineAnchor, constant: 15),
            labelField.bottomAnchor.constraint(equalTo: bottomAnchor),
            labelField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            placeholder.leadingAnchor.constraint(equalTo: countField.leadingAnchor),
            placeholder.centerYAnchor.constraint(equalTo: countField.centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityHelp(help)
        toolTip = help
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `count`, or the unknown state while it is nil.
    func apply(_ count: Int?, reduceMotion: Bool, animate: Bool) {
        setAccessibilityValue(sentence(count))
        guard let count else {
            placeholder.isHidden = reduceMotion
            placeholder.alphaValue = 1
            countField.stringValue = reduceMotion ? "\u{2013}" : "00"
            countField.textColor = Tokens.Color.labelCool2
            countField.alphaValue = reduceMotion ? 1 : 0
            shown = .unknown
            return
        }
        countField.stringValue = "\(count)"
        countField.textColor = count > 0 ? liveInk : Tokens.Color.labelCool2
        let before = shown
        shown = .count(count)
        switch before {
        case .nothing:
            countField.alphaValue = 1
            placeholder.isHidden = true
        case .unknown:
            reveal(countField, hiding: placeholder, animate: animate) { [weak self] in
                guard let self else { return }
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
        case .count(let old):
            if old != count { reveal(countField, hiding: nil, animate: animate) }
        }
    }
}

/// Brings `field` in over 0.18 s, or at once when `animate` is false, fading
/// `placeholder` out with it; the placeholder then hides and loses its
/// highlight. Nothing moves and no number counts up.
@MainActor
private func reveal(_ field: NSTextField, hiding placeholder: CountPlaceholderView?, animate: Bool,
                    then done: (() -> Void)? = nil) {
    let finish = {
        placeholder?.isHidden = true
        placeholder?.stopShimmer()
        done?()
    }
    guard animate else {
        field.alphaValue = 1
        placeholder?.alphaValue = 0
        finish()
        return
    }
    field.alphaValue = 0
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        field.animator().alphaValue = 1
        placeholder?.animator().alphaValue = 0
    }, completionHandler: { MainActor.assumeIsolated { finish() } })
}

/// A count's stand-in while its kind is still being looked for: a rounded
/// `meter` bar that a moving highlight crosses. The highlight's colours are
/// stamped onto a layer, so they are re-stamped by hand on an appearance or
/// Increase Contrast change; `meter` has Increase Contrast values and that
/// flip fires no appearance change.
@MainActor
private final class CountPlaceholderView: NSView {

    private static let shimmerKey = "shimmer"
    private static let highlightWidth: CGFloat = 44
    private let radius: CGFloat
    private let highlight = CAGradientLayer()

    init(size: NSSize, radius: CGFloat) {
        self.radius = radius
        super.init(frame: NSRect(origin: .zero, size: size))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        highlight.anchorPoint = CGPoint(x: 0, y: 0.5)
        highlight.startPoint = CGPoint(x: 0, y: 0.5)
        highlight.endPoint = CGPoint(x: 1, y: 0.5)
        highlight.bounds = CGRect(x: 0, y: 0, width: Self.highlightWidth, height: size.height)
        highlight.position = CGPoint(x: -Self.highlightWidth, y: size.height / 2)
        layer?.addSublayer(highlight)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
        ])
        setAccessibilityElement(false)
        redrawOnAccessibilityDisplayChange()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        stampHighlight()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        Tokens.Color.meter.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        stampHighlight()
    }

    @objc private func accessibilityDisplayChanged() { stampHighlight() }

    private func stampHighlight() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let meter = Tokens.Color.meter.usingColorSpace(.sRGB) ?? Tokens.Color.meter
            let peak = meter.blended(withFraction: isDark ? 0.30 : 0.70, of: .white) ?? meter
            // Clear as the peak colour at zero alpha, so the edges fade without a grey fringe.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlight.colors = [peak.withAlphaComponent(0).cgColor, peak.cgColor, peak.withAlphaComponent(0).cgColor]
            CATransaction.commit()
        }
    }

    /// Runs the highlight across the page: from 44 pt before the page's
    /// leading edge to `pageWidth` in 1.1 s, then a 0.5 s rest. `x` is this
    /// placeholder's leading edge in the page, so every placeholder shows the
    /// same light passing.
    func startShimmer(x: CGFloat, pageWidth: CGFloat, beginTime: CFTimeInterval) {
        guard highlight.animation(forKey: Self.shimmerKey) == nil else { return }
        let move = CAKeyframeAnimation(keyPath: "position.x")
        move.values = [-Self.highlightWidth - x, pageWidth - x, pageWidth - x]
        move.keyTimes = [0, 0.6875, 1]
        move.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.45, 0, 0.55, 1),
                                CAMediaTimingFunction(name: .linear)]
        move.duration = 1.6
        move.repeatCount = .infinity
        move.beginTime = highlight.convertTime(beginTime, from: nil)
        highlight.add(move, forKey: Self.shimmerKey)
    }

    func stopShimmer() {
        highlight.removeAnimation(forKey: Self.shimmerKey)
    }
}
