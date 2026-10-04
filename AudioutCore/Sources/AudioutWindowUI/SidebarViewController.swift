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
/// Top to bottom: the flat **System Audio** section, the pinned **Speakers**
/// plate, then the speakers in two groups that ARE the Mixer visibility
/// setting: **In the Mixer** and, only when it has rows, **Hidden unless
/// playing** (the one group that folds). The plate is drawn as a raised PLATE
/// with a `containerEdge` edge, taller and bolder than the speaker rows,
/// because it is a doorway to a page and not one more list item. Each speaker
/// row carries a presence dot (`SidebarPresenceDotView`): it says whether the
/// speaker is on the network, never where audio is routed. The row menu and a
/// drag onto the other group's header move a speaker between the groups
/// through `onSetVisibility`; Forget reaches `onForget`. The bottom add bar,
/// its multi-select retitle and Cmd-N stay. Selection is reported through
/// `onSelect`.
///
/// The outline model is still a small tree of reference-typed `Node`s (one
/// level: section header → leaf rows, plus the two pinned root rows) so the
/// `NSOutlineViewDataSource` identity methods are stable across reloads and
/// the source-list header styling (`isGroupItem`) keeps working;
/// `NSOutlineView` with zero-depth leaves is simpler here than switching
/// containers, since header vibrancy/appearance still requires it.
public final class SidebarViewController: NSViewController {

    /// A node in the source-list tree. Reference type so `NSOutlineView` can key
    /// on object identity.
    final class Node {
        enum Payload {
            case header(String)             // "System Audio" / the two speaker groups (isGroupItem)
            case speakersOverview           // the pinned "Speakers" plate row (root-level leaf)
            case mainOut                    // the one "Main Audio" row (flat leaf row)
            case device(Device)             // a device row (flat leaf row)
        }
        let payload: Payload
        /// Only section headers ever have children; every other row is a leaf.
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
    static let inMixerTitle = "In the Mixer"
    static let hiddenTitle = "Hidden unless playing"
    /// The one caption a speaker row can carry: a hidden speaker that is
    /// playing right now, which the Mixer lists until it stops.
    static let playingWhileHiddenCaption = "In the Mixer while it plays"

    /// Resolves per-device icon overrides (set via the icon picker) so sidebar
    /// device rows show the same glyph as the popover/mixer. `nil` (the
    /// default) falls back to `Device.Kind.symbolName` — old behavior.
    public var deviceIconController: DeviceIconController?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton()

    /// Top-level nodes (the System Audio header, the Speakers plate, then the
    /// speaker groups). Rebuilt on `reload`.
    private var roots: [Node] = []

    /// Whether the user folded "Hidden unless playing". Read by `reload`, so
    /// the fold survives every rebuild of the tree.
    private var hiddenGroupCollapsed = false
    private var presentationByID: [String: SpeakerPresentationRecord] = [:]

    public init() {
        super.init(nibName: nil, bundle: nil)
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
        outlineView.autosaveExpandedItems = false
        // Multi-select so the user can cmd/shift-click several speakers and make
        // a group from exactly those (SPEC.md §9). Headers stay non-selectable
        // via `shouldSelectItem`.
        outlineView.allowsMultipleSelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        // A speaker row drags onto the other group's header to move it.
        outlineView.registerForDraggedTypes([Self.speakerPasteboardType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        // A click on the ALREADY-selected Speakers plate re-reports it; the
        // selection delegate never hears it, the click action does.
        outlineView.target = self
        outlineView.action = #selector(outlineViewClicked(_:))
        // Right-click menu: one menu whose items are rebuilt per click, because
        // they depend on the CLICKED row (`menuNeedsUpdate`).
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outlineView.menu = contextMenu
        // No `doubleAction`: the only row that ever had one was a group row
        // (double-click to rename), and groups live on the overview's cards
        // now. A device row's first click already opened its detail pane, so
        // there is nothing left here for a second click to do.

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Bottom add bar with a labeled "Add scene" affordance — the standard
        // macOS source-list add control (SPEC.md §9), styled like Notes'
        // bottom-left "New Folder" button: borderless, system font, glyph +
        // title. Plain: new empty group. With devices selected: new group
        // from that selection.
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .recessed
        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
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
            addBar.heightAnchor.constraint(equalToConstant: 28),

            addButton.leadingAnchor.constraint(equalTo: addBar.leadingAnchor, constant: 8),
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
        onSetVisibility?(ids, .hideWhenNotInUse)
    }

    @objc private func showMenuItemSelected(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? Set<String> else { return }
        onSetVisibility?(ids, .whenAvailable)
    }

    /// A checkmark: ticked means Always. Unticks only when every target is
    /// already Always, the way a mixed checkmark item resolves.
    @objc private func keepMenuItemSelected(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? Set<String> else { return }
        let allAlways = ids.allSatisfy { visibility(for: $0) == .always }
        onSetVisibility?(ids, allAlways ? .whenAvailable : .always)
    }

    @objc private func speakerSettingsMenuItemSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        select(.device(id: id), notify: true)
        Analytics.capture("speaker:settings_opened", ["door": "sidebar_menu"])
    }

    @objc private func forgetMenuItemSelected(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? Set<String> else { return }
        onForget?(ids)
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
                let keep = contextMenuItem("Keep in Mixer when unavailable",
                                           #selector(keepMenuItemSelected(_:)), target)
                keep.state = visibility(for: device.id) == .always ? .on : .off
                menu.addItem(keep)
            }
            menu.addItem(.separator())
            menu.addItem(contextMenuItem("Speaker settings\u{2026}",
                                         #selector(speakerSettingsMenuItemSelected(_:)), device.id))
            if isLost(device) {
                menu.addItem(.separator())
                menu.addItem(contextMenuItem(forgetTitle([device]), #selector(forgetMenuItemSelected(_:)), target))
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
            let keep = contextMenuItem("Keep in Mixer when unavailable",
                                       #selector(keepMenuItemSelected(_:)), Set(shown.map(\.id)))
            keep.state = always == shown.count ? .on : always == 0 ? .off : .mixed
            menu.addItem(keep)
        }
        let lost = speakers.filter(isLost)
        if !lost.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(contextMenuItem(forgetTitle(lost), #selector(forgetMenuItemSelected(_:)),
                                         Set(lost.map(\.id))))
        }
    }

    private func forgetTitle(_ lost: [Device]) -> String {
        if lost.count == 1, let device = lost.first {
            return "Forget \u{201C}\(displayName(device))\u{201D}\u{2026}"
        }
        return "Forget \(lost.count) speakers\u{2026}"
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

    /// Known to the library but not seen by the Mac at all.
    private func isLost(_ device: Device) -> Bool {
        presentationByID[device.id].map { $0.liveDevice == nil } ?? false
    }

    private func caption(for device: Device) -> String? {
        guard isInHiddenGroup(device), presentationByID[device.id]?.isVisibleInMixer == true else { return nil }
        return Self.playingWhileHiddenCaption
    }

    private func dotState(for device: Device) -> SidebarPresenceDotView.State {
        guard let record = presentationByID[device.id] else { return device.isAvailable ? .found : .away }
        guard record.liveDevice != nil else { return .lost }
        return record.isAvailable ? .found : .away
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

    /// Rebuild the tree from the current devices and reload. Preserves the
    /// selection by `SidebarSelection` identity where possible.
    ///
    /// `devices` is every speaker the library knows; the sidebar sorts them
    /// itself, alphabetically with This Mac first, into the two groups.
    public func reload(devices: [Device], presentationRecords: [SpeakerPresentationRecord] = []) {
        presentationByID = Dictionary(uniqueKeysWithValues: presentationRecords.map { ($0.id, $0) })
        let previous = currentSelection

        let sorted = devices.sorted { a, b in
            let aLocal = isLocal(a), bLocal = isLocal(b)
            if aLocal != bLocal { return aLocal }
            let comparison = displayName(a).localizedStandardCompare(displayName(b))
            return comparison == .orderedSame ? a.id < b.id : comparison == .orderedAscending
        }
        let hidden = sorted.filter(isInHiddenGroup)
        let shown = sorted.filter { !isInHiddenGroup($0) }

        // System Audio first: the whole mix, never tied to a device, where the
        // Main Audio page (and its Equalizer) is reached. Then the Speakers
        // plate, a doorway rather than a category, then the two groups.
        var newRoots = [
            Node(.header(Self.systemAudioTitle), children: [Node(.mainOut)]),
            Node(.speakersOverview),
            Node(.header(Self.inMixerTitle), children: shown.map { Node(.device($0)) }),
        ]
        if !hidden.isEmpty {
            newRoots.append(Node(.header(Self.hiddenTitle), children: hidden.map { Node(.device($0)) }))
        }

        roots = newRoots
        outlineView.reloadData()
        // Expand the headers so the tree reads as a flat source list; the
        // hidden group stays folded when the user folded it.
        for root in roots where !(hiddenGroupCollapsed && isHiddenHeader(root)) {
            outlineView.expandItem(root)
        }

        // Restore selection if the same target still exists.
        if let previous { select(previous, notify: false) }
        updateAddButtonTitle()
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

    /// Every root row's title in order, the Speakers plate included.
    public var test_sectionTitles: [String] {
        roots.compactMap {
            switch $0.payload {
            case .header(let t): return t
            case .speakersOverview: return "Speakers"
            default: return nil
            }
        }
    }

    /// Whether the pinned Speakers row is drawn as a plate.
    public var test_speakersRowIsPlate: Bool {
        guard let node = findNode(matching: .speakersOverview) else { return false }
        return self.outlineView(outlineView, rowViewForItem: node) is PlateRowView
    }

    /// The pinned Speakers row's cell, built through the delegate path.
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

    /// The presence dot the row's cell draws, read off the built cell.
    func test_dotState(id: String) -> SidebarPresenceDotView.State? {
        test_deviceCell(id: id)?.dotView.state
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

    /// Whether the outline view shows "Hidden unless playing" folded.
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

    /// Simulate a click on the Speakers plate — the click ACTION, which is
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

    /// True when the outline view is the hosting window's current first
    /// responder (A11Y-GROUPS: asserts the Tab-traversal seed in
    /// `viewDidAppear()` actually claimed it).
    public var test_isOutlineViewFirstResponder: Bool {
        view.window?.firstResponder === outlineView
    }

}

/// A sidebar row cell: an optional leading presence dot, the icon, the name
/// with its optional caption, and two trailing slots: a small gold
/// `speaker.wave.2.fill` "playing" marker (no row shows it at present) and a
/// tertiary `chevron.right` saying the row leads somewhere (the Speakers
/// plate alone).
///
/// Both slots live in an `NSStackView`, which DETACHES hidden arranged
/// subviews: a device row, where both are hidden, gets its full label width
/// back instead of reserving trailing space it never uses ("MacBook Pro
/// Speakers" is already the name this 210 pt sidebar barely fits). Internal
/// (not file-private) so the controller's test hook can read the marker.
final class IconLabelCellView: NSTableCellView {
    /// The trailing marker, hidden by default; `setActiveMarkerVisible` shows it.
    let activeMarkerView: NSImageView = {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                          accessibilityDescription: "Playing")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        v.image?.isTemplate = true
        v.contentTintColor = Tokens.Color.gold
        v.toolTip = "Playing"
        v.isHidden = true
        v.setContentHuggingPriority(.required, for: .horizontal)
        return v
    }()

    /// The trailing disclosure chevron — drawing only, and never an AX element:
    /// the row itself is what VoiceOver announces and activates.
    let disclosureView: NSImageView = {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        v.image?.isTemplate = true
        v.contentTintColor = Tokens.Color.label3
        v.isHidden = true
        v.setAccessibilityElement(false)
        v.setContentHuggingPriority(.required, for: .horizontal)
        return v
    }()

    /// Holds both trailing slots. `detachesHiddenViews` (the default) is what
    /// makes a hidden slot cost zero width.
    let statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = Tokens.Font.caption
        label.textColor = Tokens.Color.label3
        label.isHidden = true
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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

    let trailingStack: NSStackView = {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }()

    /// The presence dot, leading of the icon. Only cells built with a dot
    /// slot (speaker rows and Main Audio) put it in their hierarchy.
    let dotView = SidebarPresenceDotView()

    func setActiveMarkerVisible(_ visible: Bool) {
        activeMarkerView.isHidden = !visible
    }

    func setDisclosureVisible(_ visible: Bool) {
        disclosureView.isHidden = !visible
    }
}

/// The pinned Speakers row's row view: a `raised` plate with a `containerEdge`
/// edge (rule 5: `hairline` never sits on `raised`) —
/// `GroupedSectionView`'s `.card` surface vocabulary at row scale, promising
/// the pane of cards the row opens. Drawn (not a layer colour) so the `Tokens`
/// fills re-resolve live per appearance flip and Increase Contrast on every
/// paint, same rule as `HairlineView`.
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
final class PlateRowView: NSTableRowView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        redrawOnAccessibilityDisplayChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Plate row height: the `.medium` source-list row plus breathing room, so
    /// the raised fill reads as a surface rather than a selection artifact.
    static let rowHeight: CGFloat = 36
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
        Tokens.Color.raised.setFill()
        path.fill()
        Tokens.Color.containerEdge.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// A row view that draws its own background is NOT redisplayed when
    /// selection changes — without this the plate survives under the pill.
    override var isSelected: Bool { didSet { needsDisplay = true } }
}

/// A speaker row's presence dot: whether the Mac sees the speaker on the
/// network, never where audio is routed. Filled ember = found, hollow ember =
/// away, the Mixer failure pill's glyph = can't be found. Drawing only: the
/// row's spoken label says the same state.
final class SidebarPresenceDotView: NSView {
    enum State: Equatable { case none, found, away, lost }

    static let side: CGFloat = 9

    var state: State = .none {
        didSet { if state != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        redrawOnAccessibilityDisplayChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        switch state {
        case .none:
            return
        case .found:
            Tokens.Color.ember.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        case .away:
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            Tokens.Color.ember.setStroke()
            ring.stroke()
        case .lost:
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Tokens.Color.failure]))
            guard let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }
            let size = image.size
            image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                  width: size.width, height: size.height))
        }
    }
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
        case .header, .mainOut, .speakersOverview:
            break   // no identity to act on — an empty menu shows nothing at all
        case .device(let device):
            // Clicked inside the multi-selection → the whole selection; clicked
            // outside it → that one row (macOS arbitration).
            let selected = selectedDeviceIDs
            addSpeakerItems(to: menu, ids: selected.contains(device.id) ? selected : [device.id])
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

    /// A speaker row (not This Mac) drags its device id.
    public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? Node, case .device(let device) = node.payload, !isLocal(device) else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(device.id, forType: Self.speakerPasteboardType)
        return pasteboardItem
    }

    /// Only a group header takes a drop, and only when a dragged speaker
    /// sits in the other group; the drop lands ON the header, never between
    /// rows, because order inside a group is alphabetical.
    public func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                            proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let node = item as? Node, case .header(let title) = node.payload,
              dropTarget(for: draggedIDs(info), ontoHeaderTitled: title) != nil else { return [] }
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    public func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                            item: Any?, childIndex index: Int) -> Bool {
        guard let node = item as? Node, case .header(let title) = node.payload else { return false }
        let ids = draggedIDs(info)
        guard let visibility = dropTarget(for: ids, ontoHeaderTitled: title) else { return false }
        onSetVisibility?(movers(for: ids, ontoHeaderTitled: title), visibility)
        return true
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {

    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        if case .header = node.payload { return true }
        return false
    }

    /// Only "Hidden unless playing" folds: it alone gets the stock hover
    /// Show/Hide control. The first group never folds, so a speaker the
    /// Mixer lists can't vanish from here.
    public func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCell item: Any) -> Bool {
        isHiddenHeader(item)
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        if isHiddenHeader(notification.userInfo?["NSObject"]) { hiddenGroupCollapsed = true }
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        if isHiddenHeader(notification.userInfo?["NSObject"]) { hiddenGroupCollapsed = false }
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // Section headers aren't selectable (source-list convention).
        return !self.outlineView(outlineView, isGroupItem: item)
    }

    /// The Speakers plate is taller than the speaker rows: a plate needs air
    /// around the label or the raised fill reads as a selection artifact, not
    /// a surface. A speaker row is one line, except the one captioned row.
    public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? Node else { return outlineView.rowHeight }
        switch node.payload {
        case .speakersOverview:
            return PlateRowView.rowHeight
        case .device(let device):
            return caption(for: device) == nil ? outlineView.rowHeight : 40
        case .header, .mainOut:
            return outlineView.rowHeight
        }
    }

    /// The Speakers plate rides a `PlateRowView` — the raised + hairline
    /// "card" surface vocabulary (`GroupedSectionView`'s `.card`), at row
    /// scale.
    public func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let node = item as? Node, case .speakersOverview = node.payload else { return nil }
        let id = NSUserInterfaceItemIdentifier("groupsPlateRow")
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? PlateRowView {
            return reused
        }
        let row = PlateRowView()
        row.identifier = id
        return row
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        switch node.payload {
        case .header(let title):
            return makeHeaderLabel(title)
        case .speakersOverview:
            let cell = makeIconLabel(symbol: "hifispeaker.2",
                                     text: "Speakers", identifier: "speakersOverview",
                                     showsDisclosure: true,
                                     emphasized: true)
            cell.textField?.setAccessibilityLabel("Speakers, manage speakers")
            return cell
        case .mainOut:
            return makeIconLabel(symbol: DeviceIcon.mainAudioSymbolName,
                                 text: "Main Audio", identifier: "mainOut", dot: SidebarPresenceDotView.State.none)
        case .device(let device):
            let symbol = deviceIconController?.symbolName(for: device) ?? device.kind.symbolName
            let record = presentationByID[device.id]
            let cell = makeIconLabel(symbol: record?.kind == nil && record != nil ? "speaker" : symbol,
                                     text: device.name, identifier: "device",
                                     dimmed: record.map { !$0.isAvailable } ?? !device.isAvailable,
                                     dot: dotState(for: device), caption: caption(for: device),
                                     spokenName: record?.accessibilityIdentity)
            cell.toolTip = record?.secondaryText
            return cell
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

    /// The click action's one job: a click on the Speakers plate while it is
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

    /// Section header cell ("System Audio") — a DIFFERENT cell shape
    /// from `makeLabel`/`newCell` on purpose (design feedback 2026-07-18c):
    /// Finder's own sidebar headers sit flush-left with the ICON column
    /// below them, not indented to the item TEXT column, and render slightly
    /// bolder than a plain label. Reusing `newCell`'s icon+text layout (text
    /// anchored past `imageView.trailingAnchor`) was what misaligned this —
    /// headers need their own cell with the text pinned straight to
    /// `cell.leadingAnchor`.
    private func makeHeaderLabel(_ text: String) -> NSTableCellView {
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
        // Matches Finder's own sidebar section-header weight — a plain
        // `NSTextField(labelWithString:)` label reads noticeably thinner.
        textField.font = Tokens.Font.captionEmphasized
        textField.textColor = Tokens.Color.label2
        textField.lineBreakMode = .byTruncatingTail
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            // Flush with the ICON column start below it — NOT offset past an
            // icon width like an item row's text (that offset is what made
            // "Speakers" read as indented relative to the device icons under it).
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// `dot` nil builds a cell with no dot slot (the plate, whose icon stays
    /// at the cell's leading edge); `.none` reserves the slot and draws
    /// nothing (Main Audio). Pools never mix the two: each identifier always
    /// passes the same kind.
    private func makeIconLabel(symbol: String, text: String, identifier: String,
                               dimmed: Bool = false, showsActiveMarker: Bool = false,
                               showsDisclosure: Bool = false,
                               emphasized: Bool = false,
                               dot: SidebarPresenceDotView.State? = nil,
                               caption: String? = nil,
                               spokenName: String? = nil) -> IconLabelCellView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? IconLabelCellView
            ?? Self.newCell(identifier: id, withDot: dot != nil)
        // Only the pinned plate takes the emphasized weight; the speaker rows
        // keep the source list's own font. Reuse-safe without an else branch:
        // cells are pooled per identifier, and "speakersOverview" is the only
        // pool that ever asks for it.
        if emphasized { cell.textField?.font = Tokens.Font.bodyEmphasized }
        cell.imageView?.isHidden = false
        // The icon is DECORATIVE: the text field beside it speaks the row, and
        // a description here made VoiceOver read the name twice (the detail
        // pane's group rows already pass nil for the same reason). CACHED and
        // SHARED — never mutate it; the tint below is a view property.
        //
        // Force flat monochrome rendering (design feedback 2026-07-18: some SF
        // Symbols default to a lighter hierarchical secondary tone, which read
        // as an unwanted "highlight" on the glyph) — a single, controlled dark
        // fill instead, via `.isTemplate` (which `DeviceIcon.image` sets) plus
        // an explicit `contentTintColor`.
        cell.imageView?.image = DeviceIcon.image(symbol)
        cell.imageView?.contentTintColor = dimmed ? Tokens.Color.label3 : Tokens.Color.label
        cell.textField?.stringValue = text
        cell.textField?.textColor = dimmed ? Tokens.Color.label3 : Tokens.Color.label
        cell.statusLabel.stringValue = caption ?? ""
        cell.statusLabel.isHidden = caption == nil
        let dotState = dot ?? SidebarPresenceDotView.State.none
        cell.dotView.state = dotState
        cell.dotView.isHidden = dotState == SidebarPresenceDotView.State.none
        cell.setActiveMarkerVisible(showsActiveMarker)
        cell.setDisclosureVisible(showsDisclosure)
        // The dot is DRAWING ONLY and says nothing to VoiceOver, so the label
        // carries its state. Set on EVERY pass, unconditionally — cells are
        // reused, so a conditional set would leave the previous row's suffix
        // on this one.
        var spoken = spokenName ?? text
        switch dotState {
        case .lost: spoken += ", can\u{2019}t be found"
        case .away: spoken += ", unavailable"
        case .found, .none: break
        }
        if caption != nil { spoken += ", in the Mixer while it plays" }
        cell.textField?.setAccessibilityLabel(spoken)
        return cell
    }

    /// Icon side length matching the outline view's `.medium` `rowSizeStyle`
    /// (design feedback 2026-07-18: 18pt read as visually small next to the
    /// detail pane's large header icon).
    private static let iconSize: CGFloat = SurfaceLayout.sidebarIconSize

    /// Gap between the presence dot and the icon.
    private static let dotToIconGap: CGFloat = 7

    private static func newCell(identifier: NSUserInterfaceItemIdentifier, withDot: Bool) -> IconLabelCellView {
        let cell = IconLabelCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.imageView = imageView

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        cell.labelStack.setViews([textField, cell.statusLabel], in: .leading)
        cell.addSubview(cell.labelStack)
        cell.textField = textField

        cell.trailingStack.setViews([cell.activeMarkerView, cell.disclosureView], in: .leading)
        cell.addSubview(cell.trailingStack)

        if withDot {
            cell.addSubview(cell.dotView)
            NSLayoutConstraint.activate([
                cell.dotView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                cell.dotView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                cell.dotView.widthAnchor.constraint(equalToConstant: SidebarPresenceDotView.side),
                cell.dotView.heightAnchor.constraint(equalToConstant: SidebarPresenceDotView.side),
                imageView.leadingAnchor.constraint(equalTo: cell.dotView.trailingAnchor, constant: dotToIconGap),
            ])
        } else {
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
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
