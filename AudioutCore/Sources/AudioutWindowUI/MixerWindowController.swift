// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The Scenes and Speakers screens' content controller (one-surface app): a
/// CONFIGURATION-ONLY owner of the scene editor and speaker sidebar plumbing.
/// Viewing or editing a scene or a speaker here NEVER activates it or moves
/// audio — activation lives in the Mixer screen.
///
/// It vends two roots. `scenesContentController` is a footer-bearing
/// `ContentPaneHostViewController` swapped between the saved-scene card
/// overview (`GroupsOverviewViewController`) and the scene editor
/// (`GroupEditorViewController`, pushed in place when a card is opened).
/// `speakersContentController` is an `NSSplitViewController` whose sidebar
/// item is a source-list `NSOutlineView` (`SidebarViewController`, the speaker
/// list) and whose content item is a second host swapped between the Overview
/// (`SpeakersPageViewController`, the sidebar's "Overview" plate), a
/// speaker's page (`DeviceDetailViewController`) and the whole-mix
/// `MainOutDetailViewController` (the sidebar's "Main Audio" row). It owns NO
/// window: the app's `AppSurfaceController` hosts the roots and tells this
/// controller which one is visible via `setVisibleTab(_:)`.
///
/// DEFAULTS: the scenes host starts on the card overview, which draws its own
/// zero-scenes canvas; a deselected sidebar lands on the Speakers page. The
/// content area is never a no-op view.
///
/// Group creation is a standard macOS sheet (`GroupCreationSheetController`)
/// presented over the hosting window; creating a group never activates it
/// either — the caller only selects the resolved group in the sidebar and
/// opens its editor.
///
/// Device icons (per-device SF Symbol overrides) resolve through the injected
/// `DeviceIconController`, shared with the sidebar, editor, creation sheet, and
/// detail pane so every surface renders the same glyph; its `onChange`
/// re-drives `refreshAll()` so a pick anywhere updates everywhere.
///
/// Everything group-related goes through the injected `GroupController`
/// (UI-agnostic, unit-tested in core) — this controller never does mixer math
/// and never calls `activateGroup`. `@MainActor` because it touches AppKit and
/// the non-`Sendable` `GroupController` only on the main thread; the app folds
/// backend events on `MainActor` before calling `update(devices:)`.
///
/// `public` so both the app and the headless `window-harness` / tests can
/// build it against a MockBackend-backed `GroupController` and assert its
/// structure. The create sheet is fully constructible and drivable headless
/// (see the `test_*` hooks).
@MainActor
public final class MixerWindowController {

    /// The UI-agnostic group model shared with the menu. Source of truth for
    /// groups; the screen reads it and writes through it, never around it.
    private let groupController: GroupController
    private let speakerLibrary: SpeakerLibraryController
    private let ownsSpeakerLibrary: Bool

    /// Resolves/persists per-device icon overrides, shared with every child
    /// pane so the sidebar, editor/creation checklists, and the detail pane all
    /// render the same glyph for a device.
    private let deviceIconController: DeviceIconController

    /// Latest device snapshot the app pushed via `update(devices:)`, keyed by id.
    private var devicesByID: [String: Device] = [:]

    /// The device the detail pane is currently showing, so `refreshAll()` can
    /// re-render it from a fresher snapshot (or fall back to the default
    /// content when the device has since disappeared). `nil` when the detail
    /// pane isn't showing.
    private var shownDetailDeviceID: String?

    // Child controllers.
    private let splitViewController = NSSplitViewController()
    private let sidebarViewController: SidebarViewController
    private let editorViewController: GroupEditorViewController
    private let detailViewController: DeviceDetailViewController
    private let mainOutDetailViewController: MainOutDetailViewController
    private let overviewViewController: GroupsOverviewViewController
    private let speakersPageViewController: SpeakersPageViewController

    /// Tone seams, wired by the app to the backend. This controller never
    /// calls a backend itself (`AGENTS.md`) — it only forwards what the two
    /// detail panes report.
    ///
    /// `onSetDeviceEQ` carries (eq, device id, committed); `onSetMainOutEQ`
    /// carries (eq, committed) — no id, it is the whole mix.
    public var onSetDeviceEQ: ((DeviceEQ, String, Bool) -> Void)?
    public var onSetMainOutEQ: ((DeviceEQ, Bool) -> Void)?
    /// Reads the whole mix's current tone when the Main Audio page opens.
    /// Pulled rather than pushed: the value lives on the backend, and this
    /// screen has no event to receive it on.
    public var mainOutEQProvider: (() -> DeviceEQ)?
    /// The device page's "Forget" on its Password row, with the device id.
    public var onForgetAirPlayPassword: ((String) -> Void)?
    /// Asks the host to bring the Scenes screen forward: a scene created from
    /// the Speakers sidebar opens its editor there.
    public var onRequestScenesTab: (() -> Void)?

    /// A selection that arrived before the snapshot carrying its device did —
    /// the popover's "Equalizer…" deep link can name a speaker this screen has
    /// never been told about (it is built lazily, on first open). Held here and
    /// applied at the end of the first `refreshAll()` in which the id exists.
    /// Only `.device` ever pends: `.group` and `.mainOut` resolve immediately
    /// or not at all.
    private var pendingSelection: SidebarSelection?

    /// The Scenes screen's root: the card overview or the editor, above the
    /// persistent footer caption. Never itself swapped; only its child changes.
    private let scenesHost = ContentPaneHostViewController(
        footerText: "Set up scenes here, then switch to the Mixer to play")

    /// The content beside the sidebar: the Speakers page, a speaker's page or
    /// Main Audio. No footer, so the content runs the full height like the
    /// sidebar does.
    private let speakersHost = ContentPaneHostViewController(footerText: nil)

    /// The split's content item — wraps `speakersHost`, which is never itself
    /// swapped; only its inner child changes as the sidebar selection changes.
    private let contentSplitItem: NSSplitViewItem

    /// The sidebar split item, kept so `refreshAll()` can re-assert that it is
    /// expanded. Collapsing it is unrecoverable — see the setup in `init`.
    private let sidebarSplitItem: NSSplitViewItem

    public init(groupController: GroupController,
               deviceIconController: DeviceIconController = DeviceIconController(loadPersisted: false),
               appRouting: AppRoutingController? = nil,
               btHardwareVolumeStore: BTHardwareVolumeStore? = nil,
               settings: AppSettings = AppSettings(),
               speakerLibrary: SpeakerLibraryController? = nil) {
        self.groupController = groupController
        self.ownsSpeakerLibrary = speakerLibrary == nil
        self.speakerLibrary = speakerLibrary ?? SpeakerLibraryController(loadPersisted: false)
        self.deviceIconController = deviceIconController
        self.sidebarViewController = SidebarViewController()
        self.editorViewController = GroupEditorViewController(groupController: groupController)
        self.detailViewController = DeviceDetailViewController(groupController: groupController, settings: settings)
        self.mainOutDetailViewController = MainOutDetailViewController(settings: settings)
        self.overviewViewController = GroupsOverviewViewController(groupController: groupController)
        self.speakersPageViewController = SpeakersPageViewController(library: self.speakerLibrary,
                                                                     groupController: groupController)
        editorViewController.speakerLibrary = self.speakerLibrary
        detailViewController.speakerLibrary = self.speakerLibrary
        overviewViewController.speakerLibrary = self.speakerLibrary

        // Share the one icon controller across every pane so a per-device
        // override picked anywhere renders identically everywhere.
        sidebarViewController.deviceIconController = deviceIconController
        editorViewController.deviceIconController = deviceIconController
        detailViewController.deviceIconController = deviceIconController
        // Nil-tolerant: without a store the detail pane simply hides its
        // "Control speaker volume" slot (see `DeviceDetailViewController`).
        detailViewController.btHardwareVolumeStore = btHardwareVolumeStore
        overviewViewController.deviceIconController = deviceIconController
        overviewViewController.appRouting = appRouting

        // A PLAIN split item, NOT `.sidebar(withViewController:)` — the one
        // thing that keeps the surface's tab strip still. A split item with
        // `.sidebar` behavior anywhere in the window makes AppKit reserve the
        // toolbar's whole leading region for it, so every toolbar item starts
        // at the CONTENT pane's edge instead of the window's for as long as
        // this screen is mounted; the strip jumped ~210pt on every visit here
        // and jumped back on the Mixer (live build, 2026-08-22). Probed on a
        // real on-screen window, this is the ONLY cure: not
        // `allowsFullHeightLayout`, not a tracking separator item, not any
        // `toolbarStyle`, and not un-parenting the split controller — all of
        // those still reserve. The source-list LOOK is unaffected because it
        // never came from here: `SidebarViewController` sets
        // `outlineView.style = .sourceList` itself. What the constructor did
        // supply is the system sidebar material. Nothing stands in for it
        // (C6, 2026-09-03: no wash on either screen): a `.sourceList` outline
        // view paints its OWN opaque background whatever sits behind it, so
        // the sidebar rows read as the system source-list colour, not as this
        // surface's `panel`. Measured dark, that colour is roughly twice as
        // light as `panel`. Unchanged by the deletion — the wash it replaced
        // was opaque too, and behind the same outline view.
        let sidebarItem = NSSplitViewItem(viewController: sidebarViewController)
        // PINNED at `SurfaceLayout.sidebarWidth` — minimum AND maximum,
        // deliberately (2026-08-12). The sidebar's own fitting width is
        // ≥260, and the split view hands an item its fitting width clamped
        // to `maximumThickness`; pinning min == max makes the split's whole
        // fitting width exactly `SurfaceLayout.width` (sidebar +
        // `GroupsPaneLayout.contentMaxWidth` + both column margins), which is
        // what lets it sit inside the one fixed surface frame without
        // widening it. 210, not the old 200 floor: 200 truncated "MacBook
        // Pro Speakers", the longest name every Mac has. The cost is a
        // divider the user can no longer drag; a longer name still
        // truncates, which is what a source list does anyway.
        sidebarItem.minimumThickness = SurfaceLayout.sidebarWidth
        sidebarItem.maximumThickness = SurfaceLayout.sidebarWidth
        // NOT collapsible: a collapse here is a ONE-WAY DOOR. The sidebar is
        // the only way to change selection, and nothing can bring it back —
        // the surface has no toolbar sidebar toggle and no View menu, and this
        // controller is built once and reused for the process lifetime — so a
        // collapsed sidebar strands the user on one group's editor for the
        // rest of the session. `refreshAll()` re-asserts it too: `canCollapse`
        // only refuses the USER's divider drag, and AppKit still auto-collapses
        // a sidebar item laid out narrower than its items' minimums.
        sidebarItem.canCollapse = false
        sidebarSplitItem = sidebarItem

        // The scenes host starts on the overview (empty canvas until the first
        // scene is saved); the speakers host on the Speakers page.
        scenesHost.setContent(overviewViewController)
        speakersHost.setContent(speakersPageViewController)
        contentSplitItem = NSSplitViewItem(viewController: speakersHost)

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentSplitItem)

        // Load the split tree eagerly — the retired window's
        // `contentViewController` assignment used to do this
        // implicitly. The sidebar's outline view must exist before the first
        // `refreshAll()`/auto-select runs, and those run on `update(devices:)`
        // before any host has mounted the content.
        splitViewController.loadViewIfNeeded()

        detailViewController.onVisibilityChange = { [weak self] in self?.refreshAll() }
        // The sidebar's two groups ARE the visibility setting: its menu and
        // drag write through the one library, then every list re-reads it.
        sidebarViewController.onSetVisibility = { [weak self] ids, visibility in
            guard let self else { return }
            if self.speakerLibrary.setVisibility(visibility, for: ids) { self.refreshAll() }
        }
        // Every Forget door runs the same confirm.
        sidebarViewController.onForget = { [weak self] ids in self?.requestForget(ids: ids) }
        speakersPageViewController.onForget = { [weak self] ids in self?.requestForget(ids: ids) }
        detailViewController.onForget = { [weak self] id in self?.requestForget(ids: [id]) }

        // The panes report tone gestures; this controller forwards them
        // untouched to whoever owns the backend.
        detailViewController.onSetEQ = { [weak self] eq, id, committed in
            self?.onSetDeviceEQ?(eq, id, committed)
        }
        detailViewController.onForgetPassword = { [weak self] id in
            self?.onForgetAirPlayPassword?(id)
        }
        mainOutDetailViewController.onSetEQ = { [weak self] eq, committed in
            self?.onSetMainOutEQ?(eq, committed)
        }

        // A membership row on the detail pane NAVIGATES: it selects that group
        // in the sidebar and opens its editor, through the same `select(_:)`
        // path the popover's deep link uses. CONFIG-ONLY — selecting is not
        // activating, so `activeGroupID` is untouched and no audio moves.
        detailViewController.onSelectGroup = { [weak self] groupID in
            self?.select(.group(id: groupID))
            // The editor lives in the scenes host; without the tab switch the
            // click lands on a screen nobody is looking at.
            self?.onRequestScenesTab?()
        }

        // Sidebar selection drives the content pane.
        sidebarViewController.onSelect = { [weak self] selection in
            self?.handleSidebarSelection(selection)
        }
        // "+" with no selection → new-group creation sheet (revamp: standard
        // macOS sheet, PRIMARY path).
        sidebarViewController.onAddGroup = { [weak self] in
            self?.presentCreateSheet(preselected: [])
        }
        // "+" with devices multi-selected → creation sheet pre-populated with
        // exactly those speakers.
        sidebarViewController.onNewGroupFromSelection = { [weak self] deviceIDs in
            self?.presentCreateSheet(preselected: deviceIDs)
        }
        // A card opens its scene's editor as an IN-PANE push in the scenes host.
        overviewViewController.onOpenGroup = { [weak self] groupID in
            self?.showEditor(for: groupID)
        }
        // Both of the overview's "+" doors — the dashed grid tile and the empty
        // canvas's centred one — run the same creation sheet as the sidebar's.
        overviewViewController.onNewGroup = { [weak self] in
            self?.presentCreateSheet(preselected: [])
        }
        // A card's "Rename…": open its editor and drop focus straight into the
        // rename field. (This menu lived on the sidebar's group rows until the
        // groups moved into the pane; the flow is unchanged.)
        overviewViewController.onRequestRename = { [weak self] groupID in
            guard let self else { return }
            self.showEditor(for: groupID)
            self.editorViewController.focusRenameField()
        }
        // A card's "Delete scene…": open the group's editor and run the same
        // confirm-then-delete flow its button does.
        overviewViewController.onRequestDelete = { [weak self] groupID in
            guard let self else { return }
            self.showEditor(for: groupID)
            self.editorViewController.requestDelete()
        }
        // "‹ Scenes" / Escape / ⌘[ pops the editor back to the overview.
        editorViewController.onBack = { [weak self] in
            self?.dismissEditor()
        }
        // The editor's "Delete scene…" falls back to the default content (the
        // overview, now one card lighter).
        editorViewController.onDidDeleteGroup = { [weak self] in
            self?.refreshAll()
            self?.showOverview()
        }
        // Renames / membership edits refresh the sidebar labels in place, AND
        // re-read the card overview: it is a projection of the same model, and
        // the pane it lives on is off screen while the editor is up, so a
        // membership change left its chips and "N speakers" showing the
        // membership from before the edit (live report). Not `refreshAll()` —
        // that re-`show`s the editor mid-edit, which is what this callback is
        // fired from.
        editorViewController.onDidEditGroup = { [weak self] in
            guard let self else { return }
            refreshSidebar()
            overviewViewController.reload(devices: orderedDevices())
        }
        // Build the three swapped panes' view trees HERE rather than on the
        // first swap that shows one. Measured headless with the seven-speaker
        // demo fleet: the first `showDetail` — the Mixer row's "Equalizer…"
        // door — cost 30 ms of view building on the main thread, on top of the
        // 50 ms this controller already costs to construct, and the whole 80 ms
        // landed inside the click ("very juddery", owner, 2026-09-04). This
        // controller is itself built off the click path now
        // (`AppSurfaceController.prewarmScreens`), so moving the panes into it
        // takes them off the click path too.
        for pane in [detailViewController as NSViewController,
                     mainOutDetailViewController,
                     editorViewController, speakersPageViewController] {
            pane.loadViewIfNeeded()
            // Loading the tree is only half of it: the first swap that shows a
            // pane also pays for solving its constraints from nothing. Solving
            // them once here leaves the swap re-solving an already-solved
            // layout at a new width, which measured 8 ms cheaper.
            pane.view.layoutSubtreeIfNeeded()
        }

        // An icon override picked in any pane repaints every surface. Chain onto
        // any existing observer rather than clobbering it — the controller is
        // shared and another owner may already be listening.
        let previousIconChange = deviceIconController.onChange
        deviceIconController.onChange = { [weak self] in
            previousIconChange?()
            self?.refreshAll()
        }
    }

    // MARK: App integration

    /// Test seam: simulate the content being visible so `update(devices:)`
    /// exercises its refresh path headlessly (no real WindowServer window in
    /// `swift test`). Mirrors `PopoverController.test_isShownOverride` exactly
    /// (same B8 problem, same fix shape, one host each).
    public var test_isVisibleOverride = false

    /// The two roots this controller vends.
    public enum Tab: Sendable { case scenes, speakers }

    private var visibleTab: Tab?

    /// Set by the host showing ``scenesContentController`` or
    /// ``speakersContentController`` (nil when it shows neither). Each root
    /// repaints only while it is the tab on screen, so turning a tab on
    /// refreshes it immediately: `update(devices:)` and the Speakers page's
    /// setters kept storing state while it was hidden, so there is always a
    /// current one to catch up to. `PopoverController.surfaceDidShow()` is the
    /// same idea, one host over.
    public func setVisibleTab(_ tab: Tab?) {
        visibleTab = tab
        if tab != nil { refreshAll() }
    }

    /// Whether either root should be treated as visible for refresh-gating
    /// purposes — a host showing one, or the test override. Mirrors
    /// `PopoverController.isEffectivelyShown`.
    private var isEffectivelyVisible: Bool {
        visibleTab != nil || test_isVisibleOverride
    }

    /// Whether `tab`'s root is the one on screen; the test override stands in
    /// for both.
    private func isShowing(_ tab: Tab) -> Bool {
        visibleTab == tab || test_isVisibleOverride
    }

    /// Push the latest device snapshot. Refreshes the sidebar and the visible
    /// content pane (auto-selecting a group if nothing was selected yet) —
    /// but ONLY while a host is showing the content (or the test override is
    /// set): this is called on every backend event for the app's entire
    /// lifetime once the Groups screen has been built once, so skipping the
    /// full rebuild while hidden avoids doing real work (sidebar node-tree
    /// rebuild + `NSOutlineView` reload + content-pane re-render) that nobody
    /// can see (B8, mirrors `PopoverController`'s identical fix for the same
    /// problem). `setVisibleTab(_:)` with a tab still refreshes unconditionally, so
    /// the screen always shows current data the moment it appears.
    public func update(devices: [Device]) {
        devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        if ownsSpeakerLibrary { speakerLibrary.update(liveDevices: devices, groups: groupController.groups) }
        guard isEffectivelyVisible else { return }
        refreshAll()
    }

    /// The Scenes screen's root: the footer-bearing host swapping the card
    /// overview and the editor. Refreshing before handing it off keeps a
    /// freshly-hosted screen correct.
    public var scenesContentController: NSViewController {
        refreshAll(handedOff: .scenes)
        return scenesHost
    }

    /// The Speakers screen's root: the split view, the sidebar full-height
    /// beside the host swapping the Speakers page, a speaker's page and Main
    /// Audio.
    public var speakersContentController: NSViewController {
        refreshAll(handedOff: .speakers)
        return splitViewController
    }

    // MARK: Selection → content pane

    public func refreshSpeakerPresentation() {
        guard isEffectivelyVisible else { return }
        refreshAll()
    }

    /// The Speakers page, for the app's Bluetooth access and Pair wiring.
    public var speakersPage: SpeakersPageViewController { speakersPageViewController }

    /// The app's search: which kinds the Overview may count yet, whether the
    /// sidebar splits at its dividers, and the only speakers Forget reaches.
    /// Handed to the Overview and painted like the access row.
    public var speakerSearch: SpeakerSearch? {
        didSet {
            speakersPageViewController.search = speakerSearch
            reloadSpeakersPageIfShown()
        }
    }

    /// The Speakers page's Bluetooth access row (`nil` hides it). Stored at
    /// once, painted only while the Speakers tab is on screen;
    /// `setVisibleTab(_:)` catches a hidden page up. The sidebar and speaker
    /// page repaint too: access decides whether remembered Bluetooth
    /// speakers are on the search's can't-be-found list.
    public func setSpeakerBluetoothAccess(_ access: SpeakerBluetoothAccessPresentation?) {
        speakersPageViewController.setBluetoothAccess(access)
        refreshSpeakerPresentation()
    }

    private func reloadSpeakersPageIfShown() {
        guard isShowing(.speakers), speakersHost.currentChild === speakersPageViewController else { return }
        speakersPageViewController.reload()
    }

    /// Reads the saved tone of a speaker the Mac can't find; forwarded to the
    /// speaker page, which reads it once per show.
    public var storedDeviceEQ: ((String) -> DeviceEQ?)? {
        get { detailViewController.storedDeviceEQ }
        set { detailViewController.storedDeviceEQ = newValue }
    }

    private func handleSidebarSelection(_ selection: SidebarSelection?) {
        switch selection {
        case .speakersOverview:
            showSpeakersPage()
        case .groupsOverview:
            showOverview()
        case .group(let id):
            // Selecting a scene ONLY shows its editor (rename / membership /
            // delete) in the scenes host; the sidebar is untouched. CONFIG-ONLY:
            // selection never activates the scene or moves audio.
            showEditor(for: id)
        case .device(let id):
            // Selecting a device shows its detail pane. CONFIG-ONLY: this never
            // activates a group, changes routing, or moves audio.
            showDetail(for: id)
        case .mainOut:
            showMainOut()
        case .none:
            showDefaultSpeakersContent()
        }
    }

    /// A deselected sidebar lands on the Speakers page. `.groupsOverview` has
    /// no sidebar row, so selecting it clears the highlight.
    private func showDefaultSpeakersContent() {
        sidebarViewController.select(.groupsOverview, notify: false)
        showSpeakersPage()
    }

    private func showSpeakersPage() {
        shownDetailDeviceID = nil
        speakersPageViewController.reload()
        swapSpeakers(to: speakersPageViewController)
    }

    /// Step back from a group's editor to the card overview: the "‹ Scenes"
    /// band, ⌘[, the Done button and the surface's Escape all land here.
    /// Returns `false` when no editor is showing, so a host's Escape can fall
    /// through to closing the window.
    @discardableResult
    public func dismissEditor() -> Bool {
        guard scenesHost.currentChild === editorViewController else { return false }
        showOverview()
        return true
    }

    /// Show the saved-group card overview, re-read from the current model +
    /// fleet snapshot.
    private func showOverview() {
        overviewViewController.reload(devices: orderedDevices())
        swapScenes(to: overviewViewController)
    }

    /// Show the detail pane for `deviceID` — the page that DESCRIBES and TUNES
    /// that speaker. Falls back to the Speakers page when the library no
    /// longer knows the id (a stale selection, or a forgotten speaker) so the
    /// content area is never left on a speaker that no longer exists.
    private func showDetail(for deviceID: String) {
        guard let record = speakerLibrary.record(for: deviceID) else {
            showDefaultSpeakersContent()
            return
        }
        shownDetailDeviceID = deviceID
        detailViewController.cantBeFoundIDs = speakerSearch?.cantBeFoundIDs ?? []
        detailViewController.show(record: record)
        swapSpeakers(to: detailViewController)
    }

    /// Show the whole-mix page. Nothing to look up — the one thing it renders
    /// is pulled from the app through `mainOutEQProvider` at open time.
    private func showMainOut() {
        shownDetailDeviceID = nil
        mainOutDetailViewController.show(eq: mainOutEQProvider?() ?? .flat)
        swapSpeakers(to: mainOutDetailViewController)
    }

    private func showEditor(for groupID: String) {
        editorViewController.show(groupID: groupID, devices: orderedDevices())
        swapScenes(to: editorViewController)
    }

    /// Select `selection` from OUTSIDE the sidebar — the popover's
    /// "Equalizer…" deep link. Highlights the sidebar row (without re-firing
    /// `onSelect`, which would just call back into here) and shows the pane.
    ///
    /// A device this screen has not been told about yet PENDS rather than
    /// falling back to the default content: the Groups screen is built lazily,
    /// so the very first deep link can easily arrive before its first
    /// `update(devices:)`. The pending selection is applied at the end of the
    /// first `refreshAll()` whose snapshot carries the id.
    public func select(_ selection: SidebarSelection) {
        if case .device(let id) = selection, speakerLibrary.record(for: id) == nil {
            pendingSelection = selection
            return
        }
        pendingSelection = nil
        switch selection {
        case .group, .groupsOverview:
            break   // scenes live in the other tab; the sidebar is untouched
        default:
            sidebarViewController.select(selection, notify: false)
        }
        handleSidebarSelection(selection)
    }

    // MARK: Forget

    /// Ask before forgetting those of `ids` the search lists as can't be
    /// found; nothing else is ever forgotten. Refuses outright when
    /// forgetting would leave a scene with no speaker: deleting that scene is
    /// the user's call, and deleting a scene can move audio, so this flow
    /// never does it.
    private func requestForget(ids: Set<String>) {
        let ids = ids.intersection(speakerSearch?.cantBeFoundIDs ?? [])
        guard !ids.isEmpty else { return }
        guard let window = splitViewController.view.window, !HeadlessRuntime.isActive else {
            // No confirmation means no forget; `test_confirmForget(ids:)` is
            // the headless path.
            return
        }
        let refused = !blockingScenes(for: ids).isEmpty || !routedSpeakers(ids).isEmpty
        makeForgetAlert(ids: ids).beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, !refused else { return }
            self?.performForget(ids: ids)
        }
    }

    private func affectedScenes(for ids: Set<String>) -> [Group] {
        groupController.groups.filter { !Set($0.memberIDs).isDisjoint(with: ids) }
    }

    /// Scenes whose every member is being forgotten: removing them would
    /// leave the scene empty, which `GroupController` refuses.
    private func blockingScenes(for ids: Set<String>) -> [Group] {
        groupController.groups.filter { Set($0.memberIDs).isSubset(of: ids) }
    }

    /// Speakers Main Audio or an app is still set to play on. Core skips
    /// them, so the confirm refuses them in words instead. A recovery lookup
    /// or a Bluetooth reconnect attempt keeps a row visible (`isInUse`) but
    /// never blocks Forget.
    private func routedSpeakers(_ ids: Set<String>) -> [SpeakerPresentationRecord] {
        speakerLibrary.records.filter { ids.contains($0.id) && $0.isRouted }
    }

    /// The confirm, in the shape of the scene editor's delete alert: Forget
    /// first and destructive but off Return, Cancel on Return. A refusal is
    /// one OK button that says which scene to delete first, or which speaker
    /// is still in use.
    private func makeForgetAlert(ids: Set<String>) -> NSAlert {
        let alert = NSAlert()
        let name = ids.count == 1 ? ids.first.map { speakerLibrary.record(for: $0)?.displayName ?? $0 } : nil
        let blocking = blockingScenes(for: ids)
        if !blocking.isEmpty {
            alert.messageText = name.map { "Can\u{2019}t forget \u{201C}\($0)\u{201D}" }
                ?? "Can\u{2019}t forget \(ids.count) speakers"
            let scenes = blocking.map { "\u{201C}\($0.name)\u{201D}" }.joined(separator: ", ")
            alert.informativeText = blocking.count == 1
                ? "Delete \(scenes) first: it has no other speaker."
                : "Delete \(scenes) first: they have no other speaker."
            alert.addButton(withTitle: "OK")
            return alert
        }
        let routed = routedSpeakers(ids)
        if !routed.isEmpty {
            alert.messageText = name.map { "Can\u{2019}t forget \u{201C}\($0)\u{201D}" }
                ?? "Can\u{2019}t forget \(ids.count) speakers"
            let names = routed.map { "\u{201C}\($0.displayName)\u{201D}" }.joined(separator: ", ")
            alert.informativeText = "Main Audio or an app is still set to play on \(names). Change that in the Mixer first."
            alert.addButton(withTitle: "OK")
            return alert
        }
        alert.messageText = name.map { "Forget \u{201C}\($0)\u{201D}?" } ?? "Forget \(ids.count) speakers?"
        let m = affectedScenes(for: ids).count
        let scenes = m == 1 ? "1 scene" : "\(m) scenes"
        let comesBack = "comes back to the speaker list" + (m == 0 ? "." : ", but not to \(m == 1 ? "that scene" : "those scenes").")
        if name != nil {
            let removal = m == 0 ? "It isn\u{2019}t in any scene." : "It will be removed from \(scenes)."
            alert.informativeText = "\(removal) If it turns up again, it \(comesBack)"
        } else {
            // The sidebar's order: Shown in Mixer, then Hidden unless in use, each by name.
            let named = speakerLibrary.records.filter { ids.contains($0.id) && $0.metadataIsKnown }.sorted {
                let aHidden = $0.visibility == .hideWhenNotInUse, bHidden = $1.visibility == .hideWhenNotInUse
                if aHidden != bHidden { return bHidden }
                let comparison = $0.displayName.localizedStandardCompare($1.displayName)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }.map { "\u{201C}\($0.displayName)\u{201D}" }
            let parts: [String]
            if named.count == ids.count, ids.count <= 3 {
                parts = named
            } else {
                let shown = named.prefix(2)
                parts = shown.isEmpty ? [] : shown + ["\(ids.count - shown.count) more"]
            }
            let subject = parts.isEmpty ? "They"
                : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
            let removal = m == 0 ? " aren\u{2019}t in any scene." : " will be removed from \(scenes)."
            alert.informativeText = "\(subject)\(removal) If one turns up again, it \(comesBack)"
        }
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert
    }

    /// A throw from Core (a failed scene write, or a scene that would be
    /// emptied) reports nothing there, so it gets the scene editor's
    /// plain-words alert here. Either way every list re-reads the stores, and
    /// a forgotten speaker whose page is showing falls back to the Speakers
    /// page.
    private func performForget(ids: Set<String>) {
        do {
            try speakerLibrary.forget(ids, scenes: groupController)
        } catch {
            test_forgetFailureReported = true
            GroupEditorViewController.presentPersistFailureAlert(
                message: ids.count == 1 ? "Couldn\u{2019}t forget the speaker." : "Couldn\u{2019}t forget the speakers.",
                over: splitViewController.view.window)
        }
        refreshAll()
    }

    /// Where "Manage speakers…" lands: This Mac's page, else the first
    /// speaker, alphabetical, Shown in Mixer before Hidden unless in use,
    /// else the Speakers page.
    public var firstSpeakerSelection: SidebarSelection {
        let records = speakerLibrary.records
        if let mac = records.first(where: \.isLocalDevice) { return .device(id: mac.id) }
        let byName = records.sorted {
            let comparison = $0.displayName.localizedStandardCompare($1.displayName)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
        let first = byName.first { $0.visibility != .hideWhenNotInUse } ?? byName.first
        return first.map { .device(id: $0.id) } ?? .speakersOverview
    }

    /// Apply a deep link that was waiting for its device to show up. Runs at
    /// the END of `refreshAll()` so it wins over the auto-select rule that ran
    /// earlier in the same pass.
    private func applyPendingSelection() {
        guard case .device(let id)? = pendingSelection, speakerLibrary.record(for: id) != nil else { return }
        let selection = pendingSelection!
        pendingSelection = nil
        sidebarViewController.select(selection, notify: false)
        handleSidebarSelection(selection)
    }

    /// The live group-creation sheet while it's up, so `refreshAll()` can leave
    /// it undisturbed and tests can drive it. `nil` when no sheet is presenting.
    private var createSheetController: GroupCreationSheetController?

    /// Present the standard macOS "Add scene" sheet over the hosting window
    /// (revamp: replaces the old in-pane draft). The name is prefilled with the next
    /// "Scene N"; `preselected` seeds the membership checklist (from a device
    /// multi-selection, or empty). On create: refresh, open the resolved
    /// scene's editor in the scenes host, and ask the host for the Scenes
    /// screen — NO activation, CONFIG-ONLY.
    ///
    /// Fully constructible/drivable headless: the controller is built and its
    /// `onComplete` wired unconditionally, but the actual sheet is only
    /// presented when the hosting window is on screen. Headless tests reach the live
    /// controller via `test_createSheet` and drive `test_commit()`/`test_cancel()`
    /// directly (the controller's `finish` skips `dismiss` when unhosted).
    private func presentCreateSheet(preselected: [String]) {
        let sheet = GroupCreationSheetController(groupController: groupController,
                                                deviceIconController: deviceIconController)
        let devices = orderedDevices()
        sheet.configure(defaultName: suggestedGroupName(preselected: preselected, devices: devices),
                        devices: devices,
                        preselected: Set(preselected))
        sheet.onComplete = { [weak self] result in
            guard let self else { return }
            self.createSheetController = nil
            guard let result else { return }   // cancelled
            self.refreshAll()
            self.showEditor(for: result.group.id)
            self.onRequestScenesTab?()
        }
        createSheetController = sheet
        // Present over whichever root is on screen: the overview's "+" sits in
        // the scenes host, the sidebar's add bar in the split view. Gate on
        // that root's OWN host window (`view.window`): an on-screen host means
        // there's a real sheet parent; headless runs (host never shown, or
        // `HeadlessRuntime`) keep the reference and drive it via the test hooks.
        let presenter: NSViewController = scenesHost.view.window?.isVisible == true ? scenesHost : splitViewController
        if let host = presenter.view.window, host.isVisible, !HeadlessRuntime.isActive {
            presenter.presentAsSheet(sheet)
        }
    }

    /// The name the create sheet prefills. A selection-seeded sheet names the
    /// group after what's in it ("Office + Sonos Move") instead of the
    /// meaningless "Scene N" — the field is auto-focused with the text
    /// selected either way, so keeping the suggestion is one glance and
    /// replacing it is zero extra work.
    private func suggestedGroupName(preselected: [String], devices: [Device]) -> String {
        let names = preselected.compactMap { id in devices.first(where: { $0.id == id })?.name }
        switch names.count {
        case 0:  return groupController.nextDefaultGroupName()
        case 1:  return names[0]
        case 2:  return "\(names[0]) + \(names[1])"
        default: return "\(names[0]) + \(names.count - 1) more"
        }
    }

    /// Swap the child shown inside the scenes host (overview / editor). The
    /// host itself is never swapped, so its footer never moves.
    private func swapScenes(to controller: NSViewController) {
        scenesHost.setContent(controller)
    }

    /// Swap the child beside the sidebar (Speakers page / speaker page / Main
    /// Audio). The split item itself is never swapped.
    private func swapSpeakers(to controller: NSViewController) {
        speakersHost.setContent(controller)
    }

    // MARK: Refresh

    /// Repaint each root that is on screen, plus `handedOff`, the root a
    /// content getter is about to hand its host. A hidden root keeps its
    /// stored state until `setVisibleTab(_:)` shows it.
    private func refreshAll(handedOff: Tab? = nil) {
        // A collapsed sidebar is unrecoverable (see the split-item setup), and
        // `canCollapse` does not stop AppKit collapsing it on its own. This
        // runs on mount and whenever the screen becomes visible — exactly when
        // it has to be whole.
        if sidebarSplitItem.isCollapsed { sidebarSplitItem.isCollapsed = false }

        if ownsSpeakerLibrary { speakerLibrary.update(liveDevices: Array(devicesByID.values), groups: groupController.groups) }
        let devices = orderedDevices()
        // Refresh the visible hosts' current children. The create sheet is a
        // separate presentation (not a content pane) — it is never disturbed
        // here.
        if isShowing(.scenes) || handedOff == .scenes {
            refreshScenes(devices: devices)
        }
        if isShowing(.speakers) || handedOff == .speakers {
            reloadSidebarIfNeeded(devices: devices)
            refreshSpeakers()
        }

        applyPendingSelection()
    }

    private func refreshScenes(devices: [Device]) {
        if scenesHost.currentChild === editorViewController {
            if let id = editorViewController.editingGroupID,
               groupController.groups.contains(where: { $0.id == id }) {
                editorViewController.show(groupID: id, devices: devices)
            } else {
                // The edited scene disappeared (deleted elsewhere) — fall back.
                showOverview()
            }
        } else if scenesHost.currentChild === overviewViewController {
            // The card field is a pure projection of the model + the fleet, so
            // a fresher snapshot just redraws it (a rename, a new scene from
            // the popover's quick-save, a member back online).
            overviewViewController.reload(devices: devices)
        }
    }

    private func refreshSpeakers() {
        let speakersChild = speakersHost.currentChild
        if speakersChild === detailViewController {
            // Re-render the detail pane from the fresher snapshot; if the shown
            // speaker has since disappeared, fall back to the Speakers page.
            if let id = shownDetailDeviceID, let record = speakerLibrary.record(for: id) {
                detailViewController.cantBeFoundIDs = speakerSearch?.cantBeFoundIDs ?? []
                detailViewController.refresh(record: record)
            } else {
                showDefaultSpeakersContent()
            }
        } else if speakersChild === speakersPageViewController {
            speakersPageViewController.reload()
        } else if speakersChild === mainOutDetailViewController {
            // Nothing in a snapshot can invalidate the whole mix, and the page
            // owns its own in-flight tone state now (`MainOutDetailViewController
            // .pendingEdit`) — a per-event re-pull here bought nothing but a
            // `stateQueue.sync` on the main thread for every backend event
            // during a drag. The one legitimate pull is at `showMainOut()`,
            // on open.
        }
    }

    /// Unconditional — callers of this one reach it after a user ACTION
    /// (renaming, deleting, group selection), so the sidebar must always
    /// reflect it immediately. Still records the projection reload gates on,
    /// so the NEXT `update(devices:)` compares against the truth rather than
    /// whatever the last snapshot-driven reload happened to see.
    private func refreshSidebar() {
        let devices = orderedDevices()
        lastSidebarProjection = sidebarProjection(devices: devices)
        sidebarViewController.reload(devices: devices, presentationRecords: speakerLibrary.records,
                                     cantBeFoundIDs: speakerSearch?.cantBeFoundIDs ?? [],
                                     splitsUnreachable: speakerSearch?.isEveryKindKnown ?? true)
        test_sidebarReloadCount += 1
    }

    /// Reload the sidebar only when what its cells actually RENDER changed.
    /// `update(devices:)` fires on every backend event for the app's whole
    /// lifetime, including an EQ-only change that no sidebar cell shows
    /// (SharedUI's device/group cells draw icon, name, membership/active
    /// marker, availability — never a tone value) — comparing this plain
    /// projection instead of rebuilding the node tree unconditionally is what
    /// turns that flood back into a no-op. Not a general diffing framework:
    /// one struct, one equality check.
    private func reloadSidebarIfNeeded(devices: [Device]) {
        let projection = sidebarProjection(devices: devices)
        guard projection != lastSidebarProjection else { return }
        lastSidebarProjection = projection
        sidebarViewController.reload(devices: devices, presentationRecords: speakerLibrary.records,
                                     cantBeFoundIDs: speakerSearch?.cantBeFoundIDs ?? [],
                                     splitsUnreachable: speakerSearch?.isEveryKindKnown ?? true)
        test_sidebarReloadCount += 1
    }

    /// What the sidebar's cells render (`SidebarViewController`'s
    /// device/group row cell), read from the presentation records the cells
    /// read, so a connection that keeps a speaker available after its
    /// discovery entry lapsed still moves and repaints its row. Named as one
    /// Equatable value so a reload can be gated on it changing rather than on
    /// the raw model arrays changing.
    private struct SidebarProjection: Equatable {
        struct DeviceCell: Equatable {
            let id: String
            let name: String
            let kind: Device.Kind
            let isAvailable: Bool
            let iconSymbolName: String
            let visibility: SpeakerMixerVisibility?
            let isInUse: Bool
            let isCantBeFound: Bool
        }
        let devices: [DeviceCell]
        let splitsUnreachable: Bool
    }

    private var lastSidebarProjection: SidebarProjection?

    private func sidebarProjection(devices: [Device]) -> SidebarProjection {
        let cantBeFoundIDs = speakerSearch?.cantBeFoundIDs ?? []
        return SidebarProjection(
            devices: devices.map {
                let record = speakerLibrary.record(for: $0.id)
                return SidebarProjection.DeviceCell(id: $0.id, name: $0.name, kind: $0.kind,
                             isAvailable: record?.isAvailable ?? $0.isAvailable,
                             iconSymbolName: deviceIconController.symbolName(for: $0),
                             visibility: record?.visibility,
                             isInUse: record?.isInUse ?? false,
                             isCantBeFound: cantBeFoundIDs.contains($0.id))
            },
            splitsUnreachable: speakerSearch?.isEveryKindKnown ?? true)
    }

    /// Available speakers first, then the unavailable ones, alphabetical
    /// within each — the editor, the sheet and the overview read this one
    /// order. The sidebar sorts itself.
    private func orderedDevices() -> [Device] {
        speakerLibrary.records.map(\.renderingDevice)
    }

    // MARK: Test-support hooks
    //
    // The content isn't visible to a headless process, and AppKit won't
    // synthesize the clicks/drags a real interaction needs. These mirror exactly
    // what the sidebar / editor actions call, so `window-harness` and the test
    // suites can drive the same paths and assert structure + model state.

    /// The child controllers, for structural assertions.
    public var test_isShowingSpeakersPage: Bool { speakersHost.currentChild === speakersPageViewController }
    public var test_speakersPage: SpeakersPageViewController { speakersPageViewController }
    public var test_sidebar: SidebarViewController { sidebarViewController }
    public var test_editor: GroupEditorViewController { editorViewController }
    public var test_detail: DeviceDetailViewController { detailViewController }
    public var test_mainOutDetail: MainOutDetailViewController { mainOutDetailViewController }
    public var test_overview: GroupsOverviewViewController { overviewViewController }

    /// How many times the sidebar has actually been reloaded — proves the
    /// change-gate in ``reloadSidebarIfNeeded`` : an EQ-only `update(devices:)`
    /// must leave this unchanged, and a real sidebar-visible change must bump
    /// it exactly once.
    public private(set) var test_sidebarReloadCount = 0

    /// True when the editor pane is the visible content (vs detail/empty pane).
    public var test_isShowingEditor: Bool {
        scenesHost.currentChild === editorViewController
    }

    /// True when the speaker page is the content beside the sidebar.
    public var test_isShowingDetail: Bool {
        speakersHost.currentChild === detailViewController
    }

    /// True when the whole-mix Main Audio page is the content beside the sidebar.
    public var test_isShowingMainOut: Bool {
        speakersHost.currentChild === mainOutDetailViewController
    }

    /// The deep link still waiting for the device it names, or nil.
    public var test_pendingSelection: SidebarSelection? { pendingSelection }

    /// True when the saved-scene card overview is the scenes host's content
    /// (its own `test_isShowingEmptyCanvas` says whether it is drawing cards
    /// or the zero-scenes canvas).
    public var test_isShowingScenesOverview: Bool {
        scenesHost.currentChild === overviewViewController
    }

    /// The Forget confirm (or refusal) for `ids`, as `requestForget` builds it.
    public func test_makeForgetAlert(ids: Set<String>) -> NSAlert {
        makeForgetAlert(ids: ids)
    }

    /// The confirm's "Forget" answer, without the sheet.
    public func test_confirmForget(ids: Set<String>) {
        performForget(ids: ids)
    }

    /// True once a failed Forget was reported instead of swallowed. Headless
    /// seam: the alert itself is a window-guarded sheet.
    public private(set) var test_forgetFailureReported = false

    /// Simulate the user selecting a sidebar row (nil = deselect → AUTO-SELECT).
    public func test_select(_ selection: SidebarSelection?) {
        handleSidebarSelection(selection)
    }

    /// Drive the new-group creation path directly (mirrors the sidebar "+" and
    /// the empty pane's button).
    /// Builds and wires the sheet controller; headless it stays unpresented but
    /// fully drivable via `test_createSheet`.
    public func test_presentCreateSheet(preselected: [String]) {
        presentCreateSheet(preselected: preselected)
    }

    /// The live group-creation sheet controller, or nil when none is up — so a
    /// headless test can drive `test_commit()` / `test_cancel()` on it.
    public var test_createSheet: GroupCreationSheetController? {
        createSheetController
    }

    /// True while a group-creation sheet is presenting (or, headless, wired).
    public var test_isPresentingCreateSheet: Bool {
        createSheetController != nil
    }

    /// The persistent footer caption's text (always present, whatever hosts
    /// the content — see `ContentPaneHostViewController`).
    public var test_footerText: String { scenesHost.test_footerText }

    /// The height the persistent footer strip takes out of the screen's
    /// content area, so a test can derive the budget a swapped content pane
    /// actually gets: `screen content height − this`.
    public var test_contentPaneChromeHeight: CGFloat {
        scenesHost.test_chromeHeight
    }
}

// `WarmPanelView` — the flat `Tokens.Color.panel` canvas this screen's content
// pane introduced (Warm Signal §5.3, decision j) — moved to `AudioutSharedUI`
// when the owner picked it as the ONE background every surface screen sits on
// (live build review 2026-08-07). This file keeps using it unchanged.

// MARK: - ContentPaneHostViewController

/// Hosts a swapped content pane plus, when given one, a persistent footer
/// caption pinned beneath it. Two instances: the Scenes screen's root (with
/// the footer) and the Speakers screen's content beside the sidebar (without
/// one). `setContent(_:)` swaps the inner child view controller; this host
/// controller itself is never swapped, so the footer never moves.
final class ContentPaneHostViewController: NSViewController {

    /// Persistent secondary-color caption beneath the content pane, or nil
    /// for a host with none. Pairs with, but doesn't duplicate, the overview's
    /// lighter zero-groups nudge (`GroupsOverviewViewController`'s empty
    /// canvas): the footer is the one full teaching line; that subtitle is a
    /// shorter contextual nudge shown only when there's nothing else on screen.
    private let footerLabel: NSTextField?

    init(footerText: String?) {
        footerLabel = footerText.map { NSTextField(labelWithString: $0) }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The container the swapped child view fills; sits above the footer.
    private let contentContainer = NSView()

    /// Gap between the swapped content pane's bottom and the footer caption.
    private static let footerGap: CGFloat = 6
    /// Gap between the footer caption and the pane's bottom edge.
    private static let footerBottomInset: CGFloat = 8

    /// The currently-hosted child (overview / editor / detail pane), for
    /// structural comparisons. `nil` only before the first `setContent(_:)`.
    private(set) var currentChild: NSViewController?

    override func loadView() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        // Warm Signal §5.3: the CONTENT pane (swapped pane + footer strip)
        // sits on the `panel` canvas; the split view / sidebar / chrome
        // around it stay stock. The root of this host is that canvas.
        let root = WarmPanelView()
        // The seam between the chrome above and this warm pane (design
        // review 2026-07-25). Without it the two surfaces just abut: tolerable
        // in light mode, where both are near-white, but in dark mode the
        // chrome's COOL grey meets the pane's WARM near-black and the join
        // reads muddy rather than deliberate. A hairline makes it an edge on
        // purpose. Scoped to the content pane only — the sidebar runs the full
        // split-view height by design, so a border there would cut across it.
        let titleBarSeam = RuleView(tone: .hairline)
        titleBarSeam.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentContainer)
        var constraints: [NSLayoutConstraint] = []
        if let footerLabel {
            footerLabel.translatesAutoresizingMaskIntoConstraints = false
            footerLabel.font = Tokens.Font.caption
            footerLabel.textColor = Tokens.Color.label2
            footerLabel.alignment = .center
            footerLabel.lineBreakMode = .byTruncatingTail
            root.addSubview(footerLabel)
            constraints += [
                contentContainer.bottomAnchor.constraint(equalTo: footerLabel.topAnchor,
                                                         constant: -Self.footerGap),
                footerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
                footerLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
                footerLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor,
                                                    constant: -Self.footerBottomInset),
            ]
        } else {
            constraints.append(contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor))
        }
        root.addSubview(titleBarSeam)
        NSLayoutConstraint.activate(constraints + [
            // The SAFE-AREA top, not the root's: in a `.fullSizeContentView`
            // host this pane extends UNDER the title bar and a seam at
            // `root.topAnchor` would be hidden behind it; with no overlapping
            // chrome the safe-area top IS the root's top.
            titleBarSeam.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            titleBarSeam.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleBarSeam.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleBarSeam.heightAnchor.constraint(equalToConstant: 1),

            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
    }

    /// How much of this pane's height the persistent footer strip takes,
    /// leaving the rest to the swapped content pane. Derived from the real
    /// caption's fitting height plus the two gaps its constraints use — the
    /// height budget a content pane has to fit inside is
    /// `screen content height − THIS`.
    var test_chromeHeight: CGFloat {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        guard let footerLabel else { return 0 }
        return footerLabel.fittingSize.height + Self.footerGap + Self.footerBottomInset
    }

    /// Swap the hosted child, re-parenting it as a real child controller (not
    /// just a subview) so the responder chain stays correct.
    func setContent(_ child: NSViewController) {
        loadViewIfNeeded()
        guard currentChild !== child else { return }
        if let currentChild {
            currentChild.view.removeFromSuperview()
            currentChild.removeFromParent()
        }
        addChild(child)
        let childView = child.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            childView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            childView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        currentChild = child
        // Re-seed Tab traversal after the swap (closes the KNOWN GAP the
        // A11Y-GROUPS seed left): re-parenting the content pane invalidates
        // the window's automatic key-view loop, and recalculation is reactive
        // — without this nudge Tab could die right after a sidebar selection
        // change. No-op headless (no window).
        view.window?.recalculateKeyViewLoop()
    }

    /// The persistent footer caption's text (structural test hook).
    var test_footerText: String { footerLabel?.stringValue ?? "" }
}

// GroupsEmptyStateViewController is GONE (direction C): the overview's empty
// canvas absorbed it — same copy strings, same centered-block rules. main's
// last tweaks to the class arrived in the merge that deletes it.
