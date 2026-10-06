// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// What the user selected in the sidebar or the scene cards. Drives which
/// content pane the screen shows (the card overview; a group → its editor; a
/// device → its detail pane; nothing → auto-select).
public enum SidebarSelection: Equatable, Sendable {
    /// The whole mix — everything the app sends to speakers. One row, no id:
    /// it is a destination, not a device.
    case mainOut
    /// The saved-scene card overview. No sidebar row: the sidebar lists
    /// speakers only.
    case groupsOverview
    case speakersOverview
    /// One saved group's editor. No sidebar row of its own: the overview's
    /// cards set it.
    case group(id: String)
    case device(id: String)
}

/// The Groups screen's sidebar (SPEC §9 "Sidebar list": source-list
/// `NSOutlineView`) — **the device fleet, and nothing else** (direction C,
/// `dev/notes/groups-speakers-split-direction-c-brief-2026-08-27.md`).
///
/// Top to bottom: the **System Audio** title over the Main Audio plate, the
/// **Speakers** title over the Overview plate, then the speakers in two
/// groups that ARE the Mixer visibility setting: **Shown in Mixer** and, only
/// when it has rows, **Hidden unless in use** (the one group that folds). A
/// plate is drawn raised with a `containerEdge` edge, taller and bolder than
/// the speaker rows, because it is a doorway to a page and not one more list
/// item. Inside each group the speakers the Mac can reach come first, then an
/// "N unavailable" divider row, then the rest in cool inks: the order says
/// whether a speaker is reachable, never where audio is routed. The row menu
/// and a drag onto the other group's header move a speaker between the
/// groups through `onSetVisibility`; Forget and Command-Delete reach
/// `onForget`. The bottom add bar, its multi-select retitle and Cmd-N stay.
/// Selection is reported through `onSelect`.
///
/// The outline model is a small tree of reference-typed `Node`s (one level:
/// header → rows) that lives for the controller's lifetime: a reload moves,
/// inserts and removes rows instead of rebuilding the tree, so a selection
/// and VoiceOver's place survive it. `NSOutlineView` with zero-depth leaves
/// is simpler here than switching containers, since header
/// vibrancy/appearance still requires it.
public final class SidebarViewController: NSViewController {

    /// A node in the source-list tree. Reference type so `NSOutlineView` can key
    /// on object identity.
    final class Node {
        enum Payload {
            case header(String)             // a section title or a speaker group (isGroupItem)
            case speakersOverview           // the "Overview" plate, under the "Speakers" title
            case mainOut                    // the "Main Audio" plate, under the "System Audio" title
            case device(Device)             // a speaker row
            case divider(Int)               // "N unavailable", above a group's unreachable rows
        }
        var payload: Payload
        /// Only section headers ever have children; every other row is a leaf.
        var children: [Node]
        init(_ payload: Payload, children: [Node] = []) {
            self.payload = payload
            self.children = children
        }
    }

    /// Called when the selection changes. `nil` when the selection is cleared.
    /// Reports the *primary* (first) selected row so the detail pane still
    /// follows a single selection; the full multi-selection is available via
    /// ``selectedDeviceIDs``.
    public var onSelect: ((SidebarSelection?) -> Void)?

    /// Called when the user clicks the "+" (new empty group) button at the bottom
    /// of the source list (SPEC.md §9 — manual creation, standard macOS add).
    public var onAddGroup: (() -> Void)?

    /// Called with the device ids a new group should be built from (SPEC.md §9
    /// — "click on speakers and multiselect to create a group"). Two routes
    /// reach it: the "+" button while devices are selected, and Cmd-N with the
    /// same selection.
    public var onNewGroupFromSelection: (([String]) -> Void)?

    /// Called with the speakers to move and the Mixer visibility they move
    /// to, from the row menu or a drag onto the other group's header.
    public var onSetVisibility: ((Set<String>, SpeakerMixerVisibility) -> Void)?

    /// Called with the speakers to forget, all of them ones the Mac can't find.
    public var onForget: ((Set<String>) -> Void)?

    /// The drag type a speaker row writes: its device id.
    static let speakerPasteboardType = NSPasteboard.PasteboardType("com.audiout.sidebar-speaker-id")

    static let systemAudioTitle = "System Audio"
    static let speakersTitle = "Speakers"
    static let inMixerTitle = "Shown in Mixer"
    static let hiddenTitle = "Hidden unless in use"
    /// The one caption a speaker row can carry: a hidden speaker that is in
    /// use right now, which the Mixer lists until it stops.
    static let inUseWhileHiddenCaption = "Shown while in use"

    /// The two section titles; every other header is a subsection header.
    static func isSectionTitle(_ title: String) -> Bool {
        title == systemAudioTitle || title == speakersTitle
    }

    /// Resolves per-device icon overrides (set via the icon picker) so sidebar
    /// device rows show the same glyph as the popover/mixer. `nil` (the
    /// default) falls back to `Device.Kind.symbolName` — old behavior.
    public var deviceIconController: DeviceIconController?

    private let outlineView = SidebarOutlineView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton()

    /// Top-level nodes: the System Audio title over Main Audio, the Speakers
    /// title over Overview, then the speaker groups. Empty until the first
    /// `reload`.
    private var roots: [Node] = []

    // The nodes every reload keeps. A row keeps its identity across updates,
    // so the outline view can move it and keep it selected.
    private let mainOutNode = Node(.mainOut)
    private let overviewNode = Node(.speakersOverview)
    private let systemAudioHeader = Node(.header(SidebarViewController.systemAudioTitle))
    private let speakersHeader = Node(.header(SidebarViewController.speakersTitle))
    private let shownHeader = Node(.header(SidebarViewController.inMixerTitle))
    private let hiddenHeader = Node(.header(SidebarViewController.hiddenTitle))
    private let shownDivider = Node(.divider(0))
    private let hiddenDivider = Node(.divider(0))
    /// One node per device id, for as long as the id is passed in.
    private var deviceNodes: [String: Node] = [:]

    /// Whether the user folded "Hidden unless in use". Read by `reload`, so
    /// the fold survives every rebuild of the tree.
    private var hiddenGroupCollapsed = false
    private var presentationByID: [String: SpeakerPresentationRecord] = [:]

    public init() {
        super.init(nibName: nil, bundle: nil)
        systemAudioHeader.children = [mainOutNode]
        speakersHeader.children = [overviewNode]
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
    // anywhere in `AudioutWindowUI`/`AudioutApp`). A freshly-ordered-front
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
    // On the Speakers screen the sidebar is the one control ALWAYS present,
    // whichever page shows beside it (the Speakers page, a speaker's page or
    // Main Audio), so it's the natural anchor there: force AppKit to
    // (re)compute the window's automatic key-view
    // loop (`autorecalculatesKeyViewLoop`, off by default for a code-built window;
    // the surface's shell panel turns it on — and recalculation is reactive and
    // nothing here ever explicitly nudged it either) and claim first
    // responder for the outline view, the top-leading control.
    //
    // `ContentPaneHostViewController.setContent(_:)` re-seeds the key-view
    // loop after every pane swap (it re-parents the content hierarchy, which
    // invalidates the loop) — the swap-time half of this same fix.
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
        // A speaker name cut in the middle shows whole on hover.
        outlineView.allowsExpansionToolTips = true
        outlineView.autosaveExpandedItems = false
        // Multi-select so the user can cmd/shift-click several speakers and make
        // a group from exactly those (SPEC.md §9). Headers and dividers stay
        // non-selectable via `selectionIndexesForProposedSelection`.
        outlineView.allowsMultipleSelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        // A speaker row drags onto the other group's header to move it.
        outlineView.registerForDraggedTypes([Self.speakerPasteboardType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        // A click on the ALREADY-selected Overview plate re-reports it; the
        // selection delegate never hears it, the click action does.
        outlineView.target = self
        outlineView.action = #selector(outlineViewClicked(_:))
        // Right-click menu: one menu whose items are rebuilt per click, because
        // they depend on the CLICKED row (`menuNeedsUpdate`).
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outlineView.menu = contextMenu
        outlineView.onCommandDelete = { [weak self] in self?.forgetSelectedSpeakersThatCantBeFound() ?? false }
        // No `doubleAction`: the only row that ever had one was a group row
        // (double-click to rename), and groups live on the overview's cards
        // now. A device row's first click already opened its detail pane, so
        // there is nothing left here for a second click to do.

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // Rows wait to move while the pointer is over the list.
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        scrollView.addTrackingArea(tracking)
        pointerTrackingArea = tracking

        // Bottom add bar with a labeled "Add scene" affordance — the standard
        // macOS source-list add control (SPEC.md §9), styled like Notes'
        // bottom-left "New Folder" button: borderless, system font, glyph +
        // title. Plain: new empty group. With devices selected: new group
        // from that selection.
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .recessed
        addButton.isBordered = false
        // The plus sits on the speaker rows' icon column and the title on
        // their name column: a 26 × 22 image with the glyph centred at x 11.
        let plus = DeviceIcon.image("plus", pointSize: 13, weight: .medium)
        let plusImage = NSImage(size: NSSize(width: 26, height: 22), flipped: false) { rect in
            guard let plus else { return false }
            let size = plus.size
            plus.draw(in: NSRect(x: 11 - size.width / 2, y: (rect.height - size.height) / 2,
                                 width: size.width, height: size.height))
            return true
        }
        plusImage.isTemplate = true
        addButton.image = plusImage
        addButton.imagePosition = .imageLeading
        addButton.title = "Add scene"
        addButton.font = Tokens.Font.body
        addButton.target = self
        addButton.action = #selector(addTapped(_:))
        addButton.toolTip = "Add scene"
        addButton.setButtonType(.momentaryPushIn)

        let addBar = NSView()
        addBar.translatesAutoresizingMaskIntoConstraints = false
        addBar.addSubview(addButton)

        let container = SidebarContainerView()
        container.onCommandN = { [weak self] in self?.performAdd() }
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
        performAdd()
    }

    /// The single add path — the "+" button and Cmd-N both route here, so the
    /// two can't drift apart on what an empty vs. device selection creates.
    private func performAdd() {
        let selected = selectedDeviceIDs
        if selected.isEmpty {
            onAddGroup?()
        } else {
            onNewGroupFromSelection?(selected)
        }
    }

    /// Retitle the bottom-bar button to say what "+" will actually do — the
    /// multi-select → new-group path used to be completely invisible (nothing
    /// hinted that cmd-clicking speakers changes what the button creates).
    private func updateAddButtonTitle() {
        let count = selectedDeviceIDs.count
        let title = count >= 2 ? "Add scene from \(count) speakers…" : "Add scene"
        guard addButton.title != title else { return }
        addButton.title = title
        addButton.toolTip = title
    }

    // MARK: Context menu
    //
    // It acts on the CLICKED row, which is NOT always a selected one: standard
    // macOS arbitration is that a right-click inside the selection acts on the
    // whole selection and a right-click outside it acts on that row alone.
    // `NSTableView` sets `clickedRow` before it shows its menu, which is why
    // the items are rebuilt per click in `menuNeedsUpdate` rather than
    // assembled once at setup.

    /// The clicked row, injected. A headless run never right-clicks, so
    /// `outlineView.clickedRow` is permanently -1 there — this is the ONLY seam
    /// the menu/double-click hooks take; menu construction and dispatch below
    /// are the real ones.
    private var clickedRowOverride: Int?

    private var clickedNode: Node? {
        let row = clickedRowOverride ?? outlineView.clickedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? Node
    }

    private func contextMenuItem(_ title: String, _ action: Selector, _ represented: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        return item
    }

    /// Build the menu for `node` as if it had just been right-clicked. Shared by
    /// the live `outlineView.menu` path and the test hooks.
    private func contextMenu(clickedNode node: Node?) -> NSMenu {
        let menu = NSMenu()
        clickedRowOverride = node.map { outlineView.row(forItem: $0) } ?? -1
        defer { clickedRowOverride = nil }
        menuNeedsUpdate(menu)
        return menu
    }

    @objc private func hideMenuItemSelected(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? Set<String> else { return }
        runOwnGesture { onSetVisibility?(ids, .hideWhenNotInUse) }
    }

    @objc private func showMenuItemSelected(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? Set<String> else { return }
        runOwnGesture { onSetVisibility?(ids, .whenAvailable) }
    }

    /// A checkmark: ticked means Always. Unticks only when every target is
    /// already Always, the way a mixed checkmark item resolves.
    @objc private func keepMenuItemSelected(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? Set<String> else { return }
        let allAlways = ids.allSatisfy { visibility(for: $0) == .always }
        runOwnGesture { onSetVisibility?(ids, allAlways ? .whenAvailable : .always) }
    }

    @objc private func speakerSettingsMenuItemSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        select(.device(id: id), notify: true)
        Analytics.capture("speaker:settings_opened", ["door": "sidebar_menu"])
    }

    @objc private func forgetMenuItemSelected(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? Set<String> else { return }
        runOwnGesture { onForget?(ids) }
    }

    /// The speaker items for `ids`, the clicked row or the selection it sits
    /// in. This Mac is never hidden or forgotten, so it drops out of every
    /// count.
    private func addSpeakerItems(to menu: NSMenu, ids: [String]) {
        let devices = ids.compactMap(device(withID:))
        if devices.count == 1, let device = devices.first {
            if isLocal(device) {
                menu.addItem(contextMenuItem("Speaker settings\u{2026}",
                                             #selector(speakerSettingsMenuItemSelected(_:)), device.id))
                return
            }
            let target: Set<String> = [device.id]
            if isInHiddenGroup(device) {
                menu.addItem(contextMenuItem("Show in Mixer", #selector(showMenuItemSelected(_:)), target))
            } else {
                menu.addItem(contextMenuItem("Hide from Mixer", #selector(hideMenuItemSelected(_:)), target))
                let keep = contextMenuItem("Show even when unavailable",
                                           #selector(keepMenuItemSelected(_:)), target)
                keep.state = visibility(for: device.id) == .always ? .on : .off
                menu.addItem(keep)
            }
            menu.addItem(.separator())
            menu.addItem(contextMenuItem("Speaker settings\u{2026}",
                                         #selector(speakerSettingsMenuItemSelected(_:)), device.id))
            if isCantBeFound(device) {
                menu.addItem(.separator())
                menu.addItem(forgetItem([device]))
            }
            return
        }
        let speakers = devices.filter { !isLocal($0) }
        let shown = speakers.filter { !isInHiddenGroup($0) }
        let hidden = speakers.filter(isInHiddenGroup)
        if !shown.isEmpty {
            menu.addItem(contextMenuItem("Hide \(Self.speakerCount(shown.count)) from Mixer",
                                         #selector(hideMenuItemSelected(_:)), Set(shown.map(\.id))))
        }
        if !hidden.isEmpty {
            menu.addItem(contextMenuItem("Show \(Self.speakerCount(hidden.count)) in Mixer",
                                         #selector(showMenuItemSelected(_:)), Set(hidden.map(\.id))))
        }
        if !shown.isEmpty, hidden.isEmpty {
            let always = shown.filter { visibility(for: $0.id) == .always }.count
            let keep = contextMenuItem("Show even when unavailable",
                                       #selector(keepMenuItemSelected(_:)), Set(shown.map(\.id)))
            keep.state = always == shown.count ? .on : always == 0 ? .off : .mixed
            menu.addItem(keep)
        }
        let lost = speakers.filter(isCantBeFound)
        if !lost.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(forgetItem(lost))
        }
    }

    /// Forget for `lost`. Its ⌘⌫ is display only: a closed context menu's
    /// key equivalents never fire, so the outline view handles the key.
    private func forgetItem(_ lost: [Device]) -> NSMenuItem {
        let item = contextMenuItem(forgetTitle(lost), #selector(forgetMenuItemSelected(_:)), Set(lost.map(\.id)))
        item.keyEquivalent = "\u{8}"
        item.keyEquivalentModifierMask = .command
        return item
    }

    private func forgetTitle(_ lost: [Device]) -> String {
        if lost.count == 1, let device = lost.first {
            return "Forget \u{201C}\(displayName(device))\u{201D}\u{2026}"
        }
        return "Forget \(lost.count) speakers\u{2026}"
    }

    /// Command-Delete: forget the selected speakers that are in the
    /// can't-be-found list. False when none are, so the key goes on to the
    /// outline view.
    private func forgetSelectedSpeakersThatCantBeFound() -> Bool {
        let ids = Set(selectedDeviceIDs).intersection(cantBeFoundIDs)
        guard !ids.isEmpty else { return false }
        runOwnGesture { onForget?(ids) }
        return true
    }

    private static func speakerCount(_ n: Int) -> String {
        n == 1 ? "1 speaker" : "\(n) speakers"
    }

    // MARK: Speaker facts

    private func device(withID id: String) -> Device? {
        guard let node = findNode(matching: .device(id: id)), case .device(let d) = node.payload else { return nil }
        return d
    }

    private func displayName(_ device: Device) -> String {
        presentationByID[device.id]?.displayName ?? device.name
    }

    private func isLocal(_ device: Device) -> Bool {
        presentationByID[device.id]?.isLocalDevice == true || device.isLocalDevice
    }

    private func visibility(for id: String) -> SpeakerMixerVisibility {
        presentationByID[id]?.visibility ?? .whenAvailable
    }

    /// Which group the row sits in IS its visibility: only a hidden setting
    /// puts it in the second group, and This Mac is never hidden.
    private func isInHiddenGroup(_ device: Device) -> Bool {
        visibility(for: device.id) == .hideWhenNotInUse && !isLocal(device)
    }

    /// In the can't-be-found list: the only speakers Forget is offered for.
    private func isCantBeFound(_ device: Device) -> Bool {
        cantBeFoundIDs.contains(device.id)
    }

    private func caption(for device: Device) -> String? {
        guard isInHiddenGroup(device), presentationByID[device.id]?.isVisibleInMixer == true else { return nil }
        return Self.inUseWhileHiddenCaption
    }

    /// How a row names a speaker the Mac can't reach: the second line of its
    /// tooltip, and the suffix of its spoken label.
    private enum UnreachableState {
        case cantBeFound, notConnected, unavailable

        var tooltipLine: String {
            switch self {
            case .cantBeFound: return "Can\u{2019}t be found"
            case .notConnected: return "Not connected"
            case .unavailable: return "Unavailable"
            }
        }

        var spokenSuffix: String {
            switch self {
            case .cantBeFound: return ", can\u{2019}t be found"
            case .notConnected: return ", not connected"
            case .unavailable: return ", unavailable"
            }
        }
    }

    /// Nil when the Mac can reach the speaker and it is not in the
    /// can't-be-found list.
    private func unreachableState(of device: Device) -> UnreachableState? {
        if cantBeFoundIDs.contains(device.id) { return .cantBeFound }
        guard !isReachable(device) else { return nil }
        return isBluetooth(device) ? .notConnected : .unavailable
    }

    private func isBluetooth(_ device: Device) -> Bool {
        guard let record = presentationByID[device.id] else { return device.kind == .bluetooth }
        return record.kind == .bluetooth
    }

    private func isHiddenHeader(_ item: Any?) -> Bool {
        guard let node = item as? Node, case .header(let title) = node.payload else { return false }
        return title == Self.hiddenTitle
    }

    // MARK: Drag between groups

    /// The visibility a drop of `ids` onto the header titled `title` sets, or
    /// nil when none of them would change group (the same header, This Mac,
    /// or a row that isn't a speaker).
    func dropTarget(for ids: Set<String>, ontoHeaderTitled title: String) -> SpeakerMixerVisibility? {
        movers(for: ids, ontoHeaderTitled: title).isEmpty ? nil
            : (title == Self.hiddenTitle ? .hideWhenNotInUse : .whenAvailable)
    }

    /// The dragged speakers that sit in the OTHER group. Only these move: a
    /// speaker already under the header keeps its own setting (an Always
    /// speaker dragged with a hidden one stays Always).
    private func movers(for ids: Set<String>, ontoHeaderTitled title: String) -> Set<String> {
        guard title == Self.inMixerTitle || title == Self.hiddenTitle else { return [] }
        let toHidden = title == Self.hiddenTitle
        return Set(ids.compactMap(device(withID:)).filter {
            !isLocal($0) && isInHiddenGroup($0) != toHidden
        }.map(\.id))
    }

    private func draggedIDs(_ info: NSDraggingInfo) -> Set<String> {
        Set(info.draggingPasteboard.pasteboardItems?.compactMap {
            $0.string(forType: Self.speakerPasteboardType)
        } ?? [])
    }

    // MARK: Model

    /// The ids `reload` was last told can't be found: the only speakers
    /// Forget and Command-Delete reach.
    private var cantBeFoundIDs: Set<String> = []
    /// Whether `reload` was last told to split each group at its divider.
    private var splitsUnreachable = true
    /// The device ids whose row carried the caption when the rows were last
    /// measured.
    private var captionedIDs: Set<String> = []

    /// Bring the tree up to date with the current devices. The first call
    /// builds it; every later one moves, inserts and removes rows in one
    /// update, so rows keep their identity and a selection survives.
    ///
    /// `devices` is every speaker the library knows; the sidebar sorts them
    /// itself into the two groups, This Mac first, then the speakers the Mac
    /// can reach, then (with `splitsUnreachable`) a divider and the rest,
    /// each part by name. `cantBeFoundIDs` is the only set Forget acts on.
    public func reload(devices: [Device], presentationRecords: [SpeakerPresentationRecord] = [],
                       cantBeFoundIDs: Set<String> = [], splitsUnreachable: Bool = true) {
        let soleSelection = soleSelectedSpeaker()
        defer { announceReachabilityChange(since: soleSelection) }
        presentationByID = Dictionary(uniqueKeysWithValues: presentationRecords.map { ($0.id, $0) })
        self.cantBeFoundIDs = cantBeFoundIDs
        self.splitsUnreachable = splitsUnreachable

        // Nothing moves under the user: while held, only what can change in
        // place does, and the rest waits for the hold to end.
        if holdsMoves, !isRunningOwnGesture, !roots.isEmpty {
            heldReload = HeldReload(devices: devices, records: presentationRecords,
                                    cantBeFoundIDs: cantBeFoundIDs, splitsUnreachable: splitsUnreachable)
            applyWhileHeld(devices: devices)
            return
        }
        heldReload = nil

        let sorted = devices.sorted { a, b in
            let aLocal = isLocal(a), bLocal = isLocal(b)
            if aLocal != bLocal { return aLocal }
            let comparison = displayName(a).localizedStandardCompare(displayName(b))
            return comparison == .orderedSame ? a.id < b.id : comparison == .orderedAscending
        }
        var nodes: [String: Node] = [:]
        for device in sorted {
            let node = deviceNodes[device.id] ?? Node(.device(device))
            node.payload = .device(device)
            nodes[device.id] = node
        }
        let shown = arrangedRows(sorted.filter { !isInHiddenGroup($0) }, nodes: nodes, divider: shownDivider)
        let hidden = arrangedRows(sorted.filter(isInHiddenGroup), nodes: nodes, divider: hiddenDivider)
        shownDivider.payload = .divider(shown.underDivider)
        hiddenDivider.payload = .divider(hidden.underDivider)

        // System Audio first: the whole mix, never tied to a device, where the
        // Main Audio page (and its Equalizer) is reached. Then the Speakers
        // title over its Overview plate, then the two groups.
        guard !roots.isEmpty else {
            shownHeader.children = shown.rows
            hiddenHeader.children = hidden.rows
            roots = [systemAudioHeader, speakersHeader, shownHeader] + (hidden.rows.isEmpty ? [] : [hiddenHeader])
            deviceNodes = nodes
            outlineView.reloadData()
            // Expand the headers so the tree reads as a flat source list; the
            // hidden group stays folded when the user folded it.
            for root in roots where !(hiddenGroupCollapsed && isHiddenHeader(root)) {
                outlineView.expandItem(root)
            }
            captionedIDs = currentCaptionedIDs()
            updateAddButtonTitle()
            return
        }

        updatingRows {
            applyStructure(shown: shown.rows, hidden: hidden.rows)
            deviceNodes = nodes
        }
    }

    /// Run `change` with the selection held by identity: the rows may move
    /// under it, and the host hears none of it. Then re-configure the cells
    /// and select the surviving rows again.
    private func updatingRows(_ change: () -> Void) {
        let selected = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? Node }
        suppressSelectionCallback = true
        change()
        refreshCells()
        let rows = IndexSet(selected.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 })
        if rows.isEmpty {
            outlineView.deselectAll(nil)
        } else {
            outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        }
        suppressSelectionCallback = false
        updateAddButtonTitle()
    }

    /// One `beginUpdates`/`endUpdates` pass; inserts and removes fade, and
    /// nothing animates under Reduce Motion or off screen.
    private func performOutlineUpdates(_ body: (NSTableView.AnimationOptions) -> Void) {
        let animated = viewIfLoaded?.window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !animated {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
        }
        outlineView.beginUpdates()
        body(animated ? .effectFade : [])
        outlineView.endUpdates()
        if !animated { NSAnimationContext.endGrouping() }
    }

    // MARK: Holding moves

    /// A reload that arrived while moves were held, applied in full when the
    /// hold ends.
    private struct HeldReload {
        let devices: [Device]
        let records: [SpeakerPresentationRecord]
        let cantBeFoundIDs: Set<String>
        let splitsUnreachable: Bool
    }

    private var heldReload: HeldReload?
    private var pointerTrackingArea: NSTrackingArea?
    private var pointerIsInside = false { didSet { applyHeldReloadIfFree() } }
    private var contextMenuIsOpen = false { didSet { applyHeldReloadIfFree() } }
    private var dragIsRunning = false { didSet { applyHeldReloadIfFree() } }
    /// Set while the sidebar itself calls `onSetVisibility` or `onForget`: the
    /// reload that answers the user's own gesture applies at once.
    private var isRunningOwnGesture = false

    /// Rows wait to move while the pointer is over the list, its menu is
    /// open or a drag is running. No time limit.
    private var holdsMoves: Bool { pointerIsInside || contextMenuIsOpen || dragIsRunning }

    private func applyHeldReloadIfFree() {
        guard !holdsMoves, let held = heldReload else { return }
        reload(devices: held.devices, presentationRecords: held.records,
               cantBeFoundIDs: held.cantBeFoundIDs, splitsUnreachable: held.splitsUnreachable)
    }

    private func runOwnGesture(_ gesture: () -> Void) {
        isRunningOwnGesture = true
        defer { isRunningOwnGesture = false }
        gesture()
    }

    /// The part of a reload that moves no row: payloads and cells, the rows
    /// of ids no longer passed in, and each divider's count of the rows
    /// drawn under it (a divider left with none goes).
    private func applyWhileHeld(devices: [Device]) {
        let passed = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        updatingRows {
            performOutlineUpdates { effect in
                for (group, divider) in [(shownHeader, shownDivider), (hiddenHeader, hiddenDivider)] {
                    for index in group.children.indices.reversed() {
                        guard case .device(let device) = group.children[index].payload else { continue }
                        if let fresh = passed[device.id] {
                            group.children[index].payload = .device(fresh)
                        } else {
                            deviceNodes[device.id] = nil
                            group.children.remove(at: index)
                            outlineView.removeItems(at: IndexSet(integer: index), inParent: group,
                                                    withAnimation: effect)
                        }
                    }
                    guard let at = group.children.firstIndex(where: { $0 === divider }) else { continue }
                    let under = group.children.count - at - 1
                    if under > 0 {
                        divider.payload = .divider(under)
                    } else {
                        group.children.remove(at: at)
                        outlineView.removeItems(at: IndexSet(integer: at), inParent: group, withAnimation: effect)
                    }
                }
            }
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === pointerTrackingArea else { return super.mouseEntered(with: event) }
        pointerIsInside = true
    }

    public override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === pointerTrackingArea else { return super.mouseExited(with: event) }
        pointerIsInside = false
    }

    /// AppKit does not reliably send `mouseExited` when the list leaves its
    /// window, so a pointer resting on it would hold every later reload.
    public override func viewDidDisappear() {
        super.viewDidDisappear()
        pointerIsInside = false
    }

    // MARK: Rows

    /// The only selected row when it is a speaker, with whether the Mac
    /// could reach it.
    private func soleSelectedSpeaker() -> (id: String, wasReachable: Bool)? {
        guard outlineView.selectedRowIndexes.count == 1, let id = selectedDeviceIDs.first,
              let device = device(withID: id) else { return nil }
        return (id, isReachable(device))
    }

    /// One low-priority announcement when the only selected row changed
    /// reachability while the sidebar has focus in the key window. Nothing
    /// else about moves is announced.
    private func announceReachabilityChange(since before: (id: String, wasReachable: Bool)?) {
        guard let before, selectedDeviceIDs == [before.id], let device = device(withID: before.id),
              isReachable(device) != before.wasReachable,
              viewIfLoaded?.window?.isKeyWindow == true,
              outlineView.window?.firstResponder === outlineView else { return }
        let state: String
        switch (isReachable(device), isBluetooth(device)) {
        case (true, true): state = "connected"
        case (true, false): state = "available"
        case (false, true): state = "not connected"
        case (false, false): state = "unavailable"
        }
        NSAccessibility.post(element: outlineView, notification: .announcementRequested,
                             userInfo: [.announcement: "\(displayName(device)), \(state)",
                                        .priority: NSAccessibilityPriorityLevel.low.rawValue])
    }

    /// The Mac can reach it: This Mac, or a speaker that is available or connected.
    private func isReachable(_ device: Device) -> Bool {
        guard let record = presentationByID[device.id] else { return device.isLocalDevice || device.isAvailable }
        return record.isLocalDevice || record.isAvailable
    }

    /// One group's rows, `devices` already in name order: with
    /// `splitsUnreachable`, the reachable ones, then the divider when any
    /// is unreachable, then those; without it, one list and no divider.
    private func arrangedRows(_ devices: [Device], nodes: [String: Node],
                              divider: Node) -> (rows: [Node], underDivider: Int) {
        guard splitsUnreachable else { return (devices.compactMap { nodes[$0.id] }, 0) }
        let reachable = devices.filter(isReachable).compactMap { nodes[$0.id] }
        let unreachable = devices.filter { !isReachable($0) }.compactMap { nodes[$0.id] }
        guard !unreachable.isEmpty else { return (reachable, 0) }
        return (reachable + [divider] + unreachable, unreachable.count)
    }

    /// Turn the two groups into `shown` and `hidden` inside one update,
    /// changing the model before each call: removals first (highest index
    /// first), then the Hidden header if it is needed, then every row moved
    /// or inserted into place, then the Hidden header if it is not.
    private func applyStructure(shown: [Node], hidden: [Node]) {
        let kept = Set((shown + hidden).map { ObjectIdentifier($0) })
        let hiddenWasRoot = roots.last === hiddenHeader

        performOutlineUpdates { effect in
            for group in [shownHeader, hiddenHeader] {
                for index in group.children.indices.reversed()
                where !kept.contains(ObjectIdentifier(group.children[index])) {
                    group.children.remove(at: index)
                    outlineView.removeItems(at: IndexSet(integer: index), inParent: group, withAnimation: effect)
                }
            }
            if !hidden.isEmpty, !hiddenWasRoot {
                roots.append(hiddenHeader)
                outlineView.insertItems(at: IndexSet(integer: roots.count - 1), inParent: nil, withAnimation: effect)
            }
            for (group, target) in [(shownHeader, shown), (hiddenHeader, hidden)] {
                for (index, node) in target.enumerated() {
                    if index < group.children.count, group.children[index] === node { continue }
                    if case let (source, from)? = position(of: node) {
                        source.children.remove(at: from)
                        group.children.insert(node, at: index)
                        outlineView.moveItem(at: from, inParent: source, to: index, inParent: group)
                    } else {
                        group.children.insert(node, at: index)
                        outlineView.insertItems(at: IndexSet(integer: index), inParent: group, withAnimation: effect)
                    }
                }
            }
            if hidden.isEmpty, hiddenWasRoot {
                roots.removeLast()
                outlineView.removeItems(at: IndexSet(integer: roots.count), inParent: nil, withAnimation: effect)
            }
        }

        if !hidden.isEmpty, !hiddenWasRoot, !hiddenGroupCollapsed {
            outlineView.expandItem(hiddenHeader)
        }
    }

    /// The group holding `node`, and its index there.
    private func position(of node: Node) -> (Node, Int)? {
        for group in [shownHeader, hiddenHeader] {
            if let index = group.children.firstIndex(where: { $0 === node }) { return (group, index) }
        }
        return nil
    }

    private func currentCaptionedIDs() -> Set<String> {
        Set(deviceNodes.values.compactMap { node in
            guard case .device(let device) = node.payload, caption(for: device) != nil else { return nil }
            return device.id
        })
    }

    /// Re-run the configuration of every cell the outline view already has,
    /// and re-measure the rows whose caption came or went. Never through
    /// `reloadItem`/`reloadData`, which would rebuild the rows.
    private func refreshCells() {
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? Node,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
            configure(cell, for: node)
        }
        let captioned = currentCaptionedIDs()
        let remeasure = IndexSet(captioned.symmetricDifference(captionedIDs).compactMap {
            deviceNodes[$0].map { outlineView.row(forItem: $0) }
        }.filter { $0 >= 0 })
        captionedIDs = captioned
        if !remeasure.isEmpty { outlineView.noteHeightOfRows(withIndexesChanged: remeasure) }
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
        case .header, .divider: return nil
        case .speakersOverview: return .speakersOverview
        case .mainOut: return .mainOut
        case .device(let d): return .device(id: d.id)
        }
    }

    /// Programmatically select a target. Used to restore selection across reloads
    /// and by the test hooks. `notify` controls whether `onSelect` fires.
    /// A scene target has no row here, so it clears the highlight.
    public func select(_ target: SidebarSelection, notify: Bool = true) {
        // A target that no longer exists CLEARS the highlight. Returning
        // silently (which is what this did) left the old row drawn as selected
        // after the thing it named was deleted elsewhere — the source list
        // claiming a selection the window no longer has.
        guard let node = findNode(matching: target),
              case let row = outlineView.row(forItem: node), row >= 0 else {
            suppressSelectionCallback = !notify
            outlineView.deselectAll(nil)
            suppressSelectionCallback = false
            return
        }
        suppressSelectionCallback = !notify
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelectionCallback = false
    }

    private var suppressSelectionCallback = false

    /// Whether the click now in progress already fired `onSelect` through
    /// `outlineViewSelectionDidChange`. Read and cleared by the click action.
    private var clickChangedSelection = false

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

    /// The non-selectable section header showing `title` — it carries no
    /// identity, so `findNode(matching:)` can't reach it.
    private func findNode(titled title: String) -> Node? {
        func search(_ nodes: [Node]) -> Node? {
            for node in nodes {
                if case .header(let t) = node.payload, t == title { return node }
                if let hit = search(node.children) { return hit }
            }
            return nil
        }
        return search(roots)
    }

    // MARK: Test-support hooks

    func test_deviceCell(id: String) -> IconLabelCellView? {
        guard let node = findNode(matching: .device(id: id)) else { return nil }
        let row = outlineView.row(forItem: node)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? IconLabelCellView else { return nil }
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    /// Every root header's title in order.
    public var test_sectionTitles: [String] {
        roots.compactMap { if case .header(let title) = $0.payload { return title } else { return nil } }
    }

    /// Whether the Overview row is drawn as a plate.
    public var test_speakersRowIsPlate: Bool {
        guard let node = findNode(matching: .speakersOverview) else { return false }
        return self.outlineView(outlineView, rowViewForItem: node) is PlateRowView
    }

    /// The Overview plate's cell, built through the delegate path.
    var test_speakersRowCell: IconLabelCellView? {
        guard let node = findNode(matching: .speakersOverview) else { return nil }
        return self.outlineView(outlineView, viewFor: nil, item: node) as? IconLabelCellView
    }

    /// Number of speaker rows across both groups.
    public var test_deviceRowCount: Int {
        test_deviceRowIDs.count
    }

    /// Speaker row ids across both groups, in DISPLAY order.
    public var test_deviceRowIDs: [String] {
        test_deviceRowIDs(inGroupTitled: Self.inMixerTitle) + test_deviceRowIDs(inGroupTitled: Self.hiddenTitle)
    }

    /// Speaker row ids under one group header, in display order.
    public func test_deviceRowIDs(inGroupTitled title: String) -> [String] {
        findNode(titled: title)?.children.compactMap {
            if case .device(let d) = $0.payload { return d.id } else { return nil }
        } ?? []
    }

    /// A divider row's text.
    static func dividerTitle(_ count: Int) -> String { "\(count) unavailable" }

    /// A row as the hooks name it: a device id, a divider's text, "Overview",
    /// "Main Audio" or a header's title.
    private static func test_rowKey(_ node: Node) -> String? {
        switch node.payload {
        case .device(let device): return device.id
        case .divider(let count): return dividerTitle(count)
        case .speakersOverview: return "Overview"
        case .mainOut: return "Main Audio"
        case .header(let title): return title
        }
    }

    /// The group's children in display order: device ids, a divider as its text.
    func test_groupRows(inGroupTitled title: String) -> [String] {
        findNode(titled: title)?.children.compactMap(Self.test_rowKey) ?? []
    }

    /// The outline's own row height, the one every sidebar height is written against.
    var test_standardRowHeight: CGFloat { outlineView.rowHeight }

    /// Press Command-Delete in the outline view: a real key event through its `keyDown(with:)`.
    func test_pressCommandDelete() {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: .command, timestamp: 0,
                                           windowNumber: 0, context: nil,
                                           characters: "\u{8}", charactersIgnoringModifiers: "\u{8}",
                                           isARepeat: false, keyCode: 51) else { return }
        outlineView.keyDown(with: event)
    }

    /// Press the down (or up) arrow in the outline view: a real key event through its `keyDown(with:)`.
    func test_pressArrow(down: Bool) {
        let character = down ? "\u{F701}" : "\u{F700}"
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: [.function, .numericPad], timestamp: 0,
                                           windowNumber: 0, context: nil,
                                           characters: character, charactersIgnoringModifiers: character,
                                           isARepeat: false, keyCode: down ? 125 : 126) else { return }
        outlineView.keyDown(with: event)
    }

    /// The row view `target`'s row rides, made when it has none yet.
    func test_rowView(for target: SidebarSelection) -> NSTableRowView? {
        guard let node = findNode(matching: target), case let row = outlineView.row(forItem: node),
              row >= 0 else { return nil }
        return outlineView.rowView(atRow: row, makeIfNecessary: true)
    }

    /// The rows the delegate keeps from a proposed selection of `keys`
    /// (`test_groupRows` keys, "Overview" and "Main Audio"), in row order.
    func test_filteredSelection(ofRowKeys keys: [String]) -> [String] {
        var proposed = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? Node,
                  let key = Self.test_rowKey(node), keys.contains(key) else { continue }
            proposed.insert(row)
        }
        let kept = outlineView.delegate?.outlineView?(outlineView, selectionIndexesForProposedSelection: proposed)
            ?? proposed
        return kept.compactMap { (outlineView.item(atRow: $0) as? Node).flatMap(Self.test_rowKey) }
    }

    /// The row's visible caption, nil when the caption is hidden.
    public func test_rowCaption(id: String) -> String? {
        guard let cell = test_deviceCell(id: id), !cell.statusLabel.isHidden else { return nil }
        return cell.statusLabel.stringValue
    }

    /// The row height the delegate gives the speaker's row.
    public func test_rowHeight(id: String) -> CGFloat? {
        findNode(matching: .device(id: id)).map { outlineView(outlineView, heightOfRowByItem: $0) }
    }

    /// The checkmark state of `title` in `target`'s context menu, nil when absent.
    public func test_contextMenuItemState(_ title: String, for target: SidebarSelection) -> NSControl.StateValue? {
        contextMenu(clickedNode: findNode(matching: target)).items.first { $0.title == title }?.state
    }

    public func test_dropTarget(ids: Set<String>, ontoHeaderTitled title: String) -> SpeakerMixerVisibility? {
        dropTarget(for: ids, ontoHeaderTitled: title)
    }

    /// Whether the outline view shows "Hidden unless in use" folded.
    public var test_hiddenGroupCollapsed: Bool {
        guard let node = findNode(titled: Self.hiddenTitle) else { return false }
        return !outlineView.isItemExpanded(node)
    }

    /// Fold the hidden group through the outline view, the path a click on
    /// its Hide control takes.
    public func test_collapseHiddenGroup() {
        guard let node = findNode(titled: Self.hiddenTitle) else { return }
        outlineView.collapseItem(node)
    }

    /// Simulate the user clicking a sidebar row (fires `onSelect`).
    public func test_select(_ target: SidebarSelection) {
        select(target, notify: true)
    }

    /// Simulate a click on the Overview plate — the click ACTION, which is
    /// what fires when the row is already selected and the selection delegate
    /// stays silent. `clickedRow` cannot be set headlessly, so the row is
    /// looked up here and handed to the action's own handler.
    public func test_clickSpeakersRow() {
        guard let node = findNode(matching: .speakersOverview) else { return }
        reselectSpeakersPlate(ifClicked: outlineView.row(forItem: node))
    }

    /// Simulate a multi-selection of device rows (cmd/shift-click), for the
    /// "Add scene from selection" gesture.
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
        updateAddButtonTitle()
    }

    /// The device ids currently multi-selected (for asserts).
    public var test_selectedDeviceIDs: [String] { selectedDeviceIDs }

    /// The bottom-bar add button's current title — "Add scene" plain, "Add
    /// scene from N speakers…" while ≥2 speakers are multi-selected.
    public var test_addButtonTitle: String { addButton.title }

    /// Simulate clicking the "+" button (new empty group, or new-from-selection
    /// when devices are selected).
    public func test_tapAdd() {
        addTapped(addButton)
    }

    /// True when the outline view allows multi-selection (SPEC.md §9).
    public var test_allowsMultipleSelection: Bool { outlineView.allowsMultipleSelection }

    /// Titles of the context menu a right-click on `target`'s row produces —
    /// built through the real `menuNeedsUpdate` path with the clicked row
    /// injected, so clicked-vs-selected arbitration is exercised, not bypassed.
    public func test_contextMenuItems(for target: SidebarSelection) -> [String] {
        contextMenu(clickedNode: findNode(matching: target)).items.map(\.title)
    }

    /// Same, for the rows with no identity — the section headers, which must
    /// come back EMPTY.
    public func test_contextMenuItems(forRowTitled title: String) -> [String] {
        contextMenu(clickedNode: findNode(titled: title)).items.map(\.title)
    }

    /// Right-click `target`, then choose the item titled `title`. Dispatched
    /// through the real `NSMenuItem` target/action (`performActionForItem`),
    /// never a bypass seam. False when that row's menu has no such item.
    @discardableResult
    public func test_clickContextMenuItem(_ title: String, for target: SidebarSelection) -> Bool {
        let menu = contextMenu(clickedNode: findNode(matching: target))
        guard let index = menu.items.firstIndex(where: { $0.title == title }) else { return false }
        menu.performActionForItem(at: index)
        return true
    }

    /// Press Cmd-N in the sidebar — a real `NSEvent` through the real
    /// `performKeyEquivalent` chain. True when the sidebar claimed it.
    @discardableResult
    public func test_performCmdN() -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: .command, timestamp: 0,
                                           windowNumber: 0, context: nil,
                                           characters: "n", charactersIgnoringModifiers: "n",
                                           isARepeat: false, keyCode: 45) else { return false }
        return view.performKeyEquivalent(with: event)
    }

    /// Drive the real `viewDidAppear()` lifecycle override directly (A11Y-GROUPS)
    /// — a headless run never orders the window on screen, so AppKit never calls
    /// this itself; this hook exercises the exact same method a live window
    /// appearing would call.
    public func test_simulateViewDidAppear() { viewDidAppear() }

    /// The pointer entering the list. A synthesized enter event carries no
    /// tracking area, so `mouseEntered(with:)` would ignore it.
    public func test_pointerEntersList() { pointerIsInside = true }

    /// True when the outline view is the hosting window's current first
    /// responder (A11Y-GROUPS: asserts the Tab-traversal seed in
    /// `viewDidAppear()` actually claimed it).
    public var test_isOutlineViewFirstResponder: Bool {
        view.window?.firstResponder === outlineView
    }

}

/// A sidebar row cell: the icon, the name with its optional caption, and a
/// trailing `chevron.right` saying the row leads somewhere (the two plates).
///
/// The chevron lives in an `NSStackView`, which DETACHES hidden arranged
/// subviews: a speaker row, where it is hidden, gets its full label width
/// back instead of reserving trailing space it never uses ("MacBook Pro
/// Speakers" is already the name this 210 pt sidebar barely fits).
///
/// Its inks follow the row's selection: resting inks while unselected, the
/// accent pill's text colour on the focused pill, `label` on the grey one.
/// The grey pill leaves the cell's `backgroundStyle` alone, so the row view
/// (`SidebarRowView`) tells the cell instead.
final class IconLabelCellView: NSTableCellView {
    /// The trailing disclosure chevron — drawing only, and never an AX element:
    /// the row itself is what VoiceOver announces and activates.
    let disclosureView: NSImageView = {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        v.image?.isTemplate = true
        v.contentTintColor = Tokens.Color.labelCool2
        v.isHidden = true
        v.setAccessibilityElement(false)
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.redrawOnAccessibilityDisplayChange()
        return v
    }()

    /// The row's name. Only a speaker row also hands it to the `textField`
    /// outlet, which gives it the source list's font and the expansion
    /// tooltip; a plate keeps its own font.
    let nameLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.redrawOnAccessibilityDisplayChange()
        return label
    }()

    /// The caption under the name. The name's spoken label already says it,
    /// so it is not an accessibility element of its own.
    let statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = Tokens.Font.caption
        label.textColor = Tokens.Color.labelCool
        label.isHidden = true
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityElement(false)
        label.redrawOnAccessibilityDisplayChange()
        return label
    }()

    let labelStack: NSStackView = {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }()

    /// Holds the chevron. `detachesHiddenViews` (the default) is what makes a
    /// hidden chevron cost zero width.
    let trailingStack: NSStackView = {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }()

    /// The name's and the icon's inks while the row is not selected.
    private var restingNameInk = Tokens.Color.label
    private var restingIconInk = Tokens.Color.label

    func setDisclosureVisible(_ visible: Bool) {
        disclosureView.isHidden = !visible
    }

    func setRestingInks(name: NSColor, icon: NSColor) {
        restingNameInk = name
        restingIconInk = icon
    }

    /// Every ink in the cell: the accent pill's text colour on the focused
    /// pill, `label` on the grey one, the resting inks otherwise.
    func applySelectionInks(selected: Bool, emphasized: Bool) {
        let pillInk: NSColor? = selected ? (emphasized ? NSColor.alternateSelectedControlTextColor : Tokens.Color.label) : nil
        nameLabel.textColor = pillInk ?? restingNameInk
        imageView?.contentTintColor = pillInk ?? restingIconInk
        statusLabel.textColor = pillInk ?? Tokens.Color.labelCool
        disclosureView.contentTintColor = pillInk ?? Tokens.Color.labelCool2
    }
}

/// A section title ("System Audio", "Speakers") or a subsection header (the
/// two speaker groups). It owns its label and leaves the `textField` outlet
/// empty: at `.medium` the source list replaces the font of a cell's
/// `textField`, and each level needs its own font.
///
/// The label sits flush with the ICON column below it, not indented to the
/// item TEXT column, the way Finder's own sidebar headers do; its bottom
/// sits 3 pt above the row's, so a taller row adds space above the text.
final class SidebarHeaderCellView: NSTableCellView {
    let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = Tokens.Color.labelCool
        label.lineBreakMode = .byTruncatingTail
        // VoiceOver's heading rotor stops here; the raw value is
        // `kAXHeadingRole`, as the Mixer's headers set it.
        label.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        label.redrawOnAccessibilityDisplayChange()
        return label
    }()

    init(identifier: NSUserInterfaceItemIdentifier, font: NSFont) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = font
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The "N unavailable" row above a group's unreachable speakers: the slashed
/// antenna in the icon column, the count in tabular digits on the name
/// column, and a rule to the row's end. One accessibility element, the label;
/// the glyph and the rule are drawing only. Never selectable.
final class SidebarDividerCellView: NSTableCellView {
    let glyph: NSImageView = {
        let glyph = NSImageView()
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = DeviceIcon.image("antenna.radiowaves.left.and.right.slash", pointSize: 11)
        glyph.contentTintColor = Tokens.Color.labelCool
        glyph.setAccessibilityElement(false)
        glyph.redrawOnAccessibilityDisplayChange()
        return glyph
    }()

    let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Tokens.Font.captionDigits
        label.textColor = Tokens.Color.labelCool
        label.redrawOnAccessibilityDisplayChange()
        return label
    }()

    let rule: NSBox = {
        let rule = NSBox()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.boxType = .separator
        rule.setAccessibilityElement(false)
        return rule
    }()

    /// The glyph's box, the width of a speaker row's icon column.
    private static let glyphBoxWidth: CGFloat = 22

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        addSubview(glyph)
        addSubview(label)
        addSubview(rule)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyph.widthAnchor.constraint(equalToConstant: Self.glyphBoxWidth),
            glyph.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),

            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),

            // Centred on the middle of the digits' x-height.
            rule.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            rule.centerYAnchor.constraint(equalTo: label.firstBaselineAnchor, constant: -3),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A speaker row's row view: it re-inks its cell when the row's selection or
/// emphasis changes, because the grey pill leaves the cell's
/// `backgroundStyle` at `.normal` and the cell alone cannot tell.
class SidebarRowView: NSTableRowView {
    override var isSelected: Bool { didSet { reink() } }
    override var isEmphasized: Bool { didSet { reink() } }

    func reink() {
        // AppKit sets these while it prepares the row, before the cell is
        // added; `view(atColumn:)` raises on a row with no cell yet.
        guard numberOfColumns > 0 else { return }
        (view(atColumn: 0) as? IconLabelCellView)?.applySelectionInks(selected: isSelected, emphasized: isEmphasized)
    }
}

/// A plate's row view (Main Audio, Overview): a plate with a `containerEdge`
/// edge (rule 5: `hairline` never sits on `raised`) —
/// `GroupedSectionView`'s `.card` surface vocabulary at row scale, promising
/// the page the row opens. Light fills with `raised`; dark lifts the ground
/// with `label` at `darkLiftAlpha`, because dark `raised` is darker than the
/// sidebar's own ground and read as sunk. Drawn (not a layer colour) so the
/// `Tokens` fills re-resolve live per appearance flip and Increase Contrast
/// on every paint, same rule as `RuleView`.
///
/// **Never two shapes: the plate and the selection take turns.** Selected, the
/// row draws nothing and the source list's own pill stands alone; unselected,
/// the plate stands alone — on the SAME footprint, so the swap doesn't jump.
///
/// TRAP: under `NSTableView.style = .sourceList` that pill is not the row
/// view's to suppress — neither a `drawSelection(in:)` override nor pinning
/// `selectionHighlightStyle` to `.none` stops it (both measured against
/// rendered pixels, 2026-08-27). Drawing the plate at any other inset stacks
/// the two: the pill covers the middle and the plate's corners peek out at
/// both ends as stray arcs. That is the bug this rule exists to prevent.
final class PlateRowView: SidebarRowView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        redrawOnAccessibilityDisplayChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The dark plate's fill: `label` at this alpha over the sidebar ground.
    static let darkLiftAlpha: CGFloat = 0.05

    /// The source list's own selection-pill inset, measured off a rendered
    /// pill. The plate borrows it so the two footprints coincide: matching
    /// shapes are what keep the swap below from jumping.
    private static let selectionInsetX: CGFloat = 10

    /// Half-point inset so the 1 pt stroke lands on whole pixels.
    private var platePath: NSBezierPath {
        let rect = bounds.insetBy(dx: Self.selectionInsetX + 0.5, dy: 0.5)
        let radius = Tokens.Layout.Radius.control
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        // Selected: the pill IS the plate. Drawing under a shape that already
        // covers this rect only stacks a second rounded rect behind it.
        guard !isSelected else { return }
        let path = platePath
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (isDark ? Tokens.Color.label.withAlphaComponent(Self.darkLiftAlpha) : Tokens.Color.raised).setFill()
        path.fill()
        Tokens.Color.containerEdge.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// A row view that draws its own background is NOT redisplayed when
    /// selection changes — without this the plate survives under the pill.
    override var isSelected: Bool { didSet { needsDisplay = true } }
}

/// The sidebar's container view. Exists only to catch Cmd-N: key equivalents
/// are dispatched DOWN THE VIEW TREE (the window asks its content view, which
/// asks each subview), not along the responder chain, so an `NSViewController`
/// override would never be called — it has to be a view.
///
/// razor: a view-local key equivalent is the ceiling. The Groups screen is
/// hosted in the menu-bar surface and has no menu bar of its own, so Cmd-N
/// works while the sidebar's tree is in the key window and nowhere else, and
/// no UI can advertise the shortcut. Upgrade path: a real "Add scene…" item in
/// the app's main menu, which would both widen the scope and print the ⌘N.
private final class SidebarContainerView: NSView {

    /// Runs the add path (`SidebarViewController.performAdd`). Set at build time.
    var onCommandN: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A FIELD EDITOR wins. Key equivalents are dispatched down the view
        // tree before the responder chain sees the key, so this view claimed
        // ⌘N even while the user was typing in a text field somewhere in the
        // window — swallowing whatever that field's own ⌘N would mean.
        if let textView = window?.firstResponder as? NSTextView, textView.isFieldEditor {
            return super.performKeyEquivalent(with: event)
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "n",
           let handler = onCommandN {
            handler()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The sidebar's outline view. Command-Delete (key code 51 with exactly
/// Command held) asks `onCommandDelete` first; every other key, and a
/// Command-Delete it turns down, goes to the outline view as usual.
private final class SidebarOutlineView: NSOutlineView {
    var onCommandDelete: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           onCommandDelete?() == true {
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - NSMenuDelegate (row context menu)

extension SidebarViewController: NSMenuDelegate {

    /// Rebuilt per right-click: which items exist, and what they act on, both
    /// depend on the clicked row.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Nothing validates these items, so AppKit must not be left to enable
        // them (`autoenablesItems` would disable every one without a validator).
        menu.autoenablesItems = false
        guard let node = clickedNode else { return }
        switch node.payload {
        case .header, .mainOut, .speakersOverview, .divider:
            break   // no identity to act on — an empty menu shows nothing at all
        case .device(let device):
            // Clicked inside the multi-selection → the whole selection; clicked
            // outside it → that one row (macOS arbitration).
            let selected = selectedDeviceIDs
            addSpeakerItems(to: menu, ids: selected.contains(device.id) ? selected : [device.id])
        }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        contextMenuIsOpen = true
    }

    public func menuDidClose(_ menu: NSMenu) {
        contextMenuIsOpen = false
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

    /// A speaker row (not This Mac) drags its device id.
    public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? Node, case .device(let device) = node.payload, !isLocal(device) else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(device.id, forType: Self.speakerPasteboardType)
        return pasteboardItem
    }

    /// The header a drop on `item` lands on: a header itself, or a divider's
    /// group header.
    private func dropHeader(_ item: Any?) -> (node: Node, title: String)? {
        guard var node = item as? Node else { return nil }
        if case .divider = node.payload, let header = outlineView.parent(forItem: node) as? Node { node = header }
        guard case .header(let title) = node.payload else { return nil }
        return (node, title)
    }

    /// Only a group header takes a drop, and only when a dragged speaker
    /// sits in the other group; the drop lands ON the header, never between
    /// rows, because the sidebar sets the order inside a group.
    public func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                            proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard case let (node, title)? = dropHeader(item),
              dropTarget(for: draggedIDs(info), ontoHeaderTitled: title) != nil else { return [] }
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    public func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                            item: Any?, childIndex index: Int) -> Bool {
        guard case let (_, title)? = dropHeader(item) else { return false }
        let ids = draggedIDs(info)
        guard let visibility = dropTarget(for: ids, ontoHeaderTitled: title) else { return false }
        runOwnGesture { onSetVisibility?(movers(for: ids, ontoHeaderTitled: title), visibility) }
        return true
    }

    public func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                            willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        dragIsRunning = true
    }

    public func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                            endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragIsRunning = false
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {

    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        if case .header = node.payload { return true }
        return false
    }

    /// Only "Hidden unless in use" folds: it alone gets the stock hover
    /// Show/Hide control. The first group never folds, so a speaker the
    /// Mixer lists can't vanish from here.
    public func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        isHiddenHeader(item)
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        if isHiddenHeader(notification.userInfo?["NSObject"]) { hiddenGroupCollapsed = true }
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        if isHiddenHeader(notification.userInfo?["NSObject"]) { hiddenGroupCollapsed = false }
    }

    /// AppKit asks this instead of `shouldSelectItem`, for clicks and arrow
    /// keys alike. Headers (source-list convention) and dividers are never
    /// selected, and a range never pulls a plate in: Shift-Up from the first
    /// speaker would otherwise add Overview and switch pages. A click that
    /// leaves nothing keeps the current selection, and AppKit moves an arrow
    /// key on past any row this leaves out.
    public func outlineView(_ outlineView: NSOutlineView,
                            selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        let isRange = proposedSelectionIndexes.count > 1
        let kept = proposedSelectionIndexes.filteredIndexSet { row in
            guard let node = outlineView.item(atRow: row) as? Node else { return true }
            switch node.payload {
            case .header, .divider: return false
            case .speakersOverview, .mainOut: return !isRange
            case .device: return true
            }
        }
        // An empty proposal is the user clearing the selection, not a refused row.
        return kept.isEmpty && !proposedSelectionIndexes.isEmpty ? outlineView.selectedRowIndexes : kept
    }

    public func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?,
                            item: Any) -> String? {
        guard let node = item as? Node else { return nil }
        switch node.payload {
        case .device(let device): return displayName(device)
        case .mainOut: return "Main Audio"
        case .speakersOverview: return "Overview"
        case .header, .divider: return nil
        }
    }

    /// Only the hidden group folds, VoiceOver's disclosure command included.
    public func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        isHiddenHeader(item)
    }

    /// A header's row: its text sits 3 pt above the row's bottom, so the
    /// height sets the gap above it.
    private static let headerHeight: CGFloat = 19
    /// The "Speakers" title's row, 12 pt taller to part it from the Main
    /// Audio plate above.
    private static let speakersTitleHeight: CGFloat = 31
    private static let dividerHeight: CGFloat = 24

    /// Every height is written against the outline's own row height. The
    /// plates are taller than the speaker rows: a plate needs air around the
    /// label or the raised fill reads as a selection artifact, not a surface.
    /// A speaker row is one line, except the one captioned row.
    public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? Node else { return outlineView.rowHeight }
        switch node.payload {
        case .header(let title):
            return title == Self.speakersTitle ? Self.speakersTitleHeight : Self.headerHeight
        case .speakersOverview, .mainOut:
            return outlineView.rowHeight + 8
        case .divider:
            return Self.dividerHeight
        case .device(let device):
            return caption(for: device) == nil ? outlineView.rowHeight : outlineView.rowHeight + 12
        }
    }

    /// Both plates ride a `PlateRowView`, the raised + edged "card" surface
    /// vocabulary (`GroupedSectionView`'s `.card`) at row scale; a speaker row
    /// rides a `SidebarRowView`, which re-inks its cell on selection.
    public func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let node = item as? Node else { return nil }
        switch node.payload {
        case .speakersOverview, .mainOut:
            let id = NSUserInterfaceItemIdentifier("groupsPlateRow")
            if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? PlateRowView { return reused }
            let row = PlateRowView()
            row.identifier = id
            return row
        case .device:
            let id = NSUserInterfaceItemIdentifier("speakerRow")
            if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? SidebarRowView { return reused }
            let row = SidebarRowView()
            row.identifier = id
            return row
        case .header, .divider:
            return nil
        }
    }

    public func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? SidebarRowView)?.reink()
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node, let cell = makeCell(for: node) else { return nil }
        configure(cell, for: node)
        return cell
    }

    /// A cell from `node`'s reuse pool, or a new one. Pools never mix
    /// shapes: each identifier always builds the same kind of cell.
    private func makeCell(for node: Node) -> NSView? {
        switch node.payload {
        case .header(let title):
            // Two pools, so a reused cell never carries the other level's font.
            let isSection = Self.isSectionTitle(title)
            let id = NSUserInterfaceItemIdentifier(isSection ? "sectionHeader" : "subsectionHeader")
            return outlineView.makeView(withIdentifier: id, owner: self) as? SidebarHeaderCellView
                ?? SidebarHeaderCellView(identifier: id,
                                         font: isSection ? Tokens.Font.captionEmphasized : Tokens.Font.captionMedium)
        case .speakersOverview:
            return iconLabelCell(identifier: "speakersOverview", isSpeakerRow: false)
        case .mainOut:
            return iconLabelCell(identifier: "mainOut", isSpeakerRow: false)
        case .device:
            return iconLabelCell(identifier: "device", isSpeakerRow: true)
        case .divider:
            let id = NSUserInterfaceItemIdentifier("divider")
            return outlineView.makeView(withIdentifier: id, owner: self) as? SidebarDividerCellView
                ?? SidebarDividerCellView(identifier: id)
        }
    }

    /// Everything a cell shows for `node`. Runs when the cell is handed out
    /// and again on every in-place update, so it sets every value each time:
    /// a reused cell must never keep the previous row's state.
    private func configure(_ view: NSView, for node: Node) {
        switch node.payload {
        case .header(let title):
            guard let cell = view as? SidebarHeaderCellView else { return }
            cell.label.stringValue = title
            cell.label.setAccessibilityLabel(Self.spokenHeader(title))
        case .speakersOverview:
            guard let cell = view as? IconLabelCellView else { return }
            configurePlate(cell, symbol: "hifispeaker.2", text: "Overview", spoken: "Speakers overview")
        case .mainOut:
            guard let cell = view as? IconLabelCellView else { return }
            configurePlate(cell, symbol: DeviceIcon.mainAudioSymbolName, text: "Main Audio", spoken: "Main Audio")
        case .device(let device):
            guard let cell = view as? IconLabelCellView else { return }
            configureSpeaker(cell, device: device)
        case .divider(let count):
            guard let cell = view as? SidebarDividerCellView else { return }
            cell.label.stringValue = Self.dividerTitle(count)
            cell.label.setAccessibilityLabel(count == 1 ? "1 unavailable speaker" : "\(count) unavailable speakers")
        }
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        // The add button's title tracks the REAL selection, callback
        // suppression or not — a programmatic restore must retitle it too.
        updateAddButtonTitle()
        guard !suppressSelectionCallback else { return }
        // A click that moved the selection has just been reported here; the
        // click action that follows it must not report it a second time
        // (`currentEvent` is the mouse-down for the whole of the click).
        clickChangedSelection = NSApp?.currentEvent?.type == .leftMouseDown
        onSelect?(currentSelection)
    }

    @objc private func outlineViewClicked(_ sender: Any?) {
        reselectSpeakersPlate(ifClicked: outlineView.clickedRow)
    }

    /// The click action's one job: a click on the Overview plate while it is
    /// ALREADY selected re-reports `.speakersOverview`, so the host can
    /// return to the plate's page. Every other click was either reported by
    /// the selection delegate or selects nothing new.
    private func reselectSpeakersPlate(ifClicked row: Int) {
        let alreadyReported = clickChangedSelection
        clickChangedSelection = false
        guard !alreadyReported, row >= 0, row == outlineView.selectedRow,
              currentSelection == .speakersOverview else { return }
        onSelect?(currentSelection)
    }

    // MARK: Cell builders

    /// What VoiceOver says for a header: the two speaker groups name what
    /// they hold.
    private static func spokenHeader(_ title: String) -> String {
        switch title {
        case inMixerTitle: return "Speakers shown in Mixer"
        case hiddenTitle: return "Speakers hidden unless in use"
        default: return title
        }
    }

    private func iconLabelCell(identifier: String, isSpeakerRow: Bool) -> IconLabelCellView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        return outlineView.makeView(withIdentifier: id, owner: self) as? IconLabelCellView
            ?? Self.newCell(identifier: id, isSpeakerRow: isSpeakerRow)
    }

    /// A plate: Main Audio or Overview, a doorway to a page.
    private func configurePlate(_ cell: IconLabelCellView, symbol: String, text: String, spoken: String) {
        cell.imageView?.image = DeviceIcon.image(symbol)
        cell.nameLabel.stringValue = text
        cell.nameLabel.setAccessibilityLabel(spoken)
        cell.statusLabel.stringValue = ""
        cell.statusLabel.isHidden = true
        cell.setDisclosureVisible(true)
        cell.toolTip = nil
        cell.setRestingInks(name: Tokens.Color.label, icon: Tokens.Color.label)
        applyRowInks(to: cell)
    }

    private func configureSpeaker(_ cell: IconLabelCellView, device: Device) {
        let record = presentationByID[device.id]
        let symbol = deviceIconController?.symbolName(for: device) ?? device.kind.symbolName
        let caption = caption(for: device)
        let state = unreachableState(of: device)
        let reachable = isReachable(device)
        // The icon is DECORATIVE: the name beside it speaks the row, and a
        // description here made VoiceOver read the name twice. CACHED and
        // SHARED — never mutate it; the tint is a view property, a single
        // flat ink via `.isTemplate` (which `DeviceIcon.image` sets), because
        // some symbols' hierarchical secondary tone read as a highlight.
        cell.imageView?.image = DeviceIcon.image(record?.kind == nil && record != nil ? "speaker" : symbol)
        cell.nameLabel.stringValue = device.name
        cell.statusLabel.stringValue = caption ?? ""
        cell.statusLabel.isHidden = caption == nil
        cell.setDisclosureVisible(false)
        cell.setRestingInks(name: reachable ? Tokens.Color.label : Tokens.Color.labelCool,
                            icon: reachable ? Tokens.Color.label : Tokens.Color.labelCool2)
        // Order and ink are all the row shows of its state, so the spoken
        // label says it. Set on EVERY pass, unconditionally — cells are
        // reused, so a conditional set would leave the previous row's suffix
        // on this one.
        var spoken = record?.accessibilityIdentity ?? device.name
        if let state { spoken += state.spokenSuffix }
        if caption != nil { spoken += ", shown in the Mixer while in use" }
        cell.nameLabel.setAccessibilityLabel(spoken)
        // A speaker with no saved details adds its id, the only thing that
        // tells two of them apart.
        cell.toolTip = state.map { state in
            ([device.name, state.tooltipLine] + (record?.metadataIsKnown == false ? [device.id] : []))
                .joined(separator: "\n")
        }
        applyRowInks(to: cell)
    }

    /// Ink the cell for its row's selection; a cell with no row yet rests.
    private func applyRowInks(to cell: IconLabelCellView) {
        let row = cell.superview as? NSTableRowView
        cell.applySelectionInks(selected: row?.isSelected == true, emphasized: row?.isEmphasized == true)
    }

    /// Icon side length matching the outline view's `.medium` `rowSizeStyle`
    /// (design feedback 2026-07-18: 18pt read as visually small next to the
    /// detail pane's large header icon).
    private static let iconSize: CGFloat = SurfaceLayout.sidebarIconSize

    /// A speaker row hands its name to the `textField` outlet, which gives it
    /// the source list's font and the expansion tooltip, and cuts a long name
    /// in the middle; a plate keeps `bodyEmphasized` and cuts at the tail.
    private static func newCell(identifier: NSUserInterfaceItemIdentifier, isSpeakerRow: Bool) -> IconLabelCellView {
        let cell = IconLabelCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.redrawOnAccessibilityDisplayChange()
        cell.addSubview(imageView)
        cell.imageView = imageView

        cell.labelStack.setViews([cell.nameLabel, cell.statusLabel], in: .leading)
        cell.addSubview(cell.labelStack)
        if isSpeakerRow {
            cell.nameLabel.lineBreakMode = .byTruncatingMiddle
            cell.textField = cell.nameLabel
        } else {
            cell.nameLabel.font = Tokens.Font.bodyEmphasized
        }

        cell.trailingStack.setViews([cell.disclosureView], in: .leading)
        cell.addSubview(cell.trailingStack)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: iconSize),
            imageView.heightAnchor.constraint(equalToConstant: iconSize),

            cell.labelStack.leadingAnchor.constraint(
                equalTo: imageView.trailingAnchor, constant: SurfaceLayout.sidebarIconToLabelGap),
            cell.labelStack.trailingAnchor.constraint(
                equalTo: cell.trailingStack.leadingAnchor, constant: -6),
            cell.labelStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            cell.trailingStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            cell.trailingStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
