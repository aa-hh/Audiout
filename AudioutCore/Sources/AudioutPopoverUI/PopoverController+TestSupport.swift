// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

extension PopoverController {

    // MARK: Test-support hooks

    public func test_deviceRow(for id: String) -> DeviceRowView? {
        deviceRowsByID[id]
    }

    /// Simulate the panel being opened (T-5): recomputes collapse defaults and
    /// discards this open's manual toggles, exactly like the surface's Mixer
    /// mount path, without needing a real host to show anything.
    public func test_simulateOpen() { rebuildForOpen() }

    // MARK: Running-app picker test hooks (T-7)

    /// The "+ Add application…" picker's current candidate list — every running
    /// app from `runningAppsProvider` except ones that already have a route.
    public func test_availableAppsForPicker() -> [RunningAppInfo] { availableAppsForPicker() }

    /// Simulate picking `bundleID` from the picker (looked up in
    /// `runningAppsProvider()`'s current list for its display name; no-op if
    /// `bundleID` isn't in that list). Drives the same `AppRoutingController
    /// .addRoute` + `rebuild()` path a real menu selection would.
    public func test_pickApp(bundleID: String) {
        guard let app = runningAppsProvider().first(where: { $0.bundleID == bundleID }) else { return }
        pickApp(bundleID: app.bundleID, displayName: app.displayName)
    }

    // MARK: Applications card test hooks (T-8)

    /// Number of `AppRowView`s currently mounted in the Applications card (one per
    /// routed app; excludes the ± footer row).
    public var test_appRowCount: Int { appRowsByBundleID.count }

    /// The `AppRowView` for `bundleID`, or `nil` if that app isn't routed / the
    /// card isn't built (structural + config assertions).
    public func test_appRow(for bundleID: String) -> AppRowView? { appRowsByBundleID[bundleID] }

    /// The ordered bundle ids of the mounted app rows — proves stable
    /// `appRoutes`-order rendering.
    public func test_appRowBundleIDs() -> [String] { appRouting.appRoutes.map(\.bundleID) }

    /// The destination menu titles for `bundleID`'s row (including the disabled
    /// section headers), so tests can assert the "This Mac" / "AirPlay
    /// Speakers" split. `nil` if no such row.
    public func test_appRowDestinationTitles(for bundleID: String) -> [String]? {
        appRowsByBundleID[bundleID]?.test_menuTitles
    }

    /// The glyph `bundleID`'s row offers for one destination — the same
    /// resolved symbol the device rows draw, so a pair of AirPods is
    /// headphones in both places rather than a radio here and headphones
    /// there. `nil` if no such row or destination.
    public func test_appRowDestinationSymbolName(for bundleID: String,
                                                 destinationID: String) -> String? {
        appRowsByBundleID[bundleID]?.test_destinationSymbolName(forDestinationID: destinationID)
    }

    /// The currently selected destination id for `bundleID`'s row (the sentinel
    /// `currentDeviceDestinationID` when local, else a device id). `nil` if no row.
    public func test_appRowSelectedDestinationID(for bundleID: String) -> String? {
        appRowsByBundleID[bundleID]?.test_selectedDestinationID
    }

    /// Whether `bundleID`'s volume slider is dimmed/disabled (decision 3 — true iff
    /// the destination is Current Device/local). `nil` if no row.
    public func test_appRowSliderDimmed(for bundleID: String) -> Bool? {
        appRowsByBundleID[bundleID]?.test_isSliderDimmed
    }

    // MARK: Applications card ± footer test hooks (T3)

    /// The Applications card's current single selection, or `nil` (the HOST's
    /// source of truth — survives `rebuild()`).
    public var test_selectedAppBundleID: String? { selectedAppBundleID }

    /// Whether `bundleID`'s row currently renders the selected-row highlight.
    /// `nil` if no such row.
    public func test_appRowIsSelected(for bundleID: String) -> Bool? {
        appRowsByBundleID[bundleID]?.test_isSelected
    }

    /// Whether the footer's "−" segment is currently enabled (LOCKED DECISION —
    /// disabled iff nothing is selected).
    public var test_applicationsFooterRemoveEnabled: Bool { applicationsFooter.isRemoveEnabled }

    /// Simulate the row's body being clicked, requesting selection — drives
    /// the same `AppRowView.Delegate.appRow(_:didRequestSelect:)` path a real
    /// click takes. No-op if `bundleID` has no row.
    public func test_selectAppRow(bundleID: String) {
        guard let row = appRowsByBundleID[bundleID] else { return }
        appRow(row, didRequestSelect: bundleID)
    }

    /// Simulate tapping the footer's "+" segment — opens the same running-app
    /// picker the header would.
    public func test_tapApplicationsFooterAdd() { applicationsFooter.test_tapAdd() }

    /// Simulate tapping the footer's "−" segment — removes the selected app
    /// (no-op if nothing is selected, matching the real disabled-segment
    /// behavior).
    public func test_tapApplicationsFooterRemove() { applicationsFooter.test_tapRemove() }

    /// Whether the Output Devices card's "+" footer strip is currently mounted
    /// as the LAST row of that card — the assertion surface for the strip's
    /// position (it moved out of the header row, 2026-08-08).
    public var test_devicesFooterIsLastCardRow: Bool {
        panel.test_cardRows(title: Self.outputDevicesCardTitle).last === devicesFooter
    }

    /// Simulate tapping the Output Devices footer's "+" — the same closure a
    /// real click fires (the on-screen `popUp` itself stays headless-gated).
    public func test_tapDevicesFooterAdd() { devicesFooter.test_tapAdd() }

    /// Whether saving the current selection as a group is possible (this backs the
    /// Main Out selector's group-routing entries — a saved group becomes a
    /// destination even though the popover no longer renders a Groups section).
    public var test_saveCurrentSetupEnabled: Bool { canSaveCurrentSetup }

    /// The panel content's extra top inset (the surface seats the card stack
    /// below the window's toolbar strip) — public because `popover-harness`
    /// reads it through the non-testable import.
    public var test_panelContentTopInset: CGFloat { panel.test_contentTopInset }

    /// Count of device rows in the Selected Devices section.
    public var test_deviceSectionRowCount: Int { deviceRowsByID.count }

    // MARK: Empty-state / card-note / accessory test hooks (V11 / A1 / F1)

    /// Whether the Applications card's "No apps routed…" placeholder is currently
    /// mounted (V11).
    public var test_applicationsPlaceholderShown: Bool { applicationsPlaceholderShown }
    /// The Applications card's empty-state copy (§5.9) — pinned so a future
    /// edit can't silently drift from the spec text.
    public static var test_applicationsPlaceholderText: String { applicationsEmptyPlaceholderText }
    /// The card-note texts (`addCardNote`) for `title`, in add order — the A1
    /// dormancy annotation's assertion surface.
    public func test_cardNoteTexts(title: String) -> [String] {
        panel.test_cardNotes(title: title).map(\.stringValue)
    }
    /// The ink `title`'s card header currently carries — gold while the
    /// section is sounding, `label2` while it is silent.
    public func test_cardHeaderTitleColor(title: String) -> NSColor? {
        panel.test_headerTitleColor(title: title)
    }
    /// The tooltips on `title`'s column legends, in creation order.
    public func test_columnTitleToolTips(title: String) -> [String?] {
        panel.test_columnTitleToolTips(title: title)
    }
    /// Each of `title`'s column legends' leading edge, inward from the header
    /// row's trailing edge, in creation order — the assertion surface for a
    /// legend's left-aligned POSITION (e.g. "Source", "Offset").
    public func test_columnTitleLeadingInsets(title: String) -> [CGFloat] {
        panel.test_columnTitleLeadingInsets(title: title)
    }
    /// Whether the header accessory for `title` is enabled (`nil` if none) — F1.
    public func test_cardAccessoryEnabled(title: String) -> Bool? {
        panel.test_accessoryEnabled(title: title)
    }
    /// Fire the header accessory action for `title` the way a real click would
    /// (proves it never triggers the card's collapse) — F1. Returns whether the
    /// card had an accessory to fire.
    @discardableResult
    public func test_fireCardAccessory(title: String) -> Bool {
        panel.test_fireAccessoryAction(title: title)
    }
    /// Whether device row `id`'s Selected checkbox is currently dimmed (A1).
    /// `nil` if no such row.
    public func test_deviceRowSelectionDimmed(id: String) -> Bool? {
        deviceRowsByID[id]?.test_isSelectionDimmed
    }
    /// Whether device row `id` is mid attention-flash (A4). `nil` if no such row.
    public func test_deviceRowFlashing(id: String) -> Bool? {
        deviceRowsByID[id]?.test_isFlashing
    }
    /// The "+ Add application…" picker's menu item titles, including the disabled
    /// "No applications available" placeholder when nothing is available (C6).
    public func test_addApplicationPickerTitles() -> [String] {
        makeAddApplicationMenu().items.map(\.title)
    }
    /// The Main Out row (for selector / master assertions).
    public var test_mainOutRow: MainOutRowView { mainOutRow }

    /// The assembled panel content view (for offscreen snapshot rendering). Forces
    /// its layout before returning so callers get final geometry.
    public var test_panelView: NSView {
        let v = panel.view   // accessing `.view` loads it if needed
        v.layoutSubtreeIfNeeded()
        return v
    }

    /// Exact-fit sizing hooks (T-3). `test_panelFittingSize` is the settled
    /// `fittingSize` the resize primitive publishes; `test_preferredContentSize` is
    /// what the popover actually tracks. After a rebuild they must be equal (no
    /// clipping, no scrollbar).
    public var test_panelFittingSize: NSSize { panel.fittingSizeSettled() }
    public var test_preferredContentSize: NSSize { panel.preferredContentSize }

    // MARK: Collapsible-card test hooks (T-4)

    /// Whether the card titled `title` is currently collapsed (`nil` if no card).
    public func test_isCardCollapsed(title: String) -> Bool? {
        panel.test_isCardCollapsed(title: title)
    }
    /// Toggle the card titled `title` (drives the chevron/title-click path,
    /// including the T-5 transient-state bookkeeping so a later mid-open
    /// `rebuild()` preserves it). Returns the new collapsed state (`nil` if no
    /// card).
    @discardableResult
    public func test_toggleCard(title: String, animated: Bool = false) -> Bool? {
        guard panel.test_isCardCollapsed(title: title) != nil else { return nil }
        toggleCard(title, animated: animated)
        return panel.test_isCardCollapsed(title: title)
    }
    /// The card's laid-out body-clip height — 0 when collapsed (`nil` if no card).
    public func test_cardBodyClipHeight(title: String) -> CGFloat? {
        panel.test_cardBodyClipHeight(title: title)
    }
    /// The card's expanded body height, independent of state (`nil` if no card).
    public func test_cardBodyFittingHeight(title: String) -> CGFloat? {
        panel.test_cardBodyFittingHeight(title: title)
    }
    /// The chevron's current SF Symbol name for `title` (`nil` if not collapsible).
    public func test_cardChevronSymbolName(title: String) -> String? {
        panel.test_cardChevronSymbolName(title: title)
    }
    /// Drive the resize primitive directly (offscreen; no live popover) so tests can
    /// assert the published size equals the content's fitting height.
    public func test_applyExactFitSize() { panel.panelContentDidChangeHeight(animated: false) }

    // MARK: Device-list ceiling hooks (roadmap 039)

    /// Apply the session's content-height limit exactly as the surface does —
    /// including the measure that follows it in `measureSessionContentSize`, which is
    /// the pass that settles the list's clip view over the new ceiling. Without
    /// it the scroll view's own geometry still reads its uncapped height.
    public func test_applyContentHeightLimit(_ maxContentHeight: CGFloat) {
        panel.applyContentHeightLimit(maxContentHeight)
        _ = panel.fittingSizeSettled()
    }
    /// The ceiling the device list currently wears.
    public var test_deviceListCeiling: CGFloat { panel.test_deviceListCeiling }
    /// The device list's scroll view (`nil` before the card is built).
    public var test_deviceListScrollView: NSScrollView? { panel.test_deviceListScrollView }
    /// A card's always-visible header row (the chrome above a scrolling body).
    public func test_cardHeaderRow(title: String) -> NSView? {
        panel.test_cardHeaderRow(title: title)
    }
    /// Drive the keyboard-focus reveal without a window to hold the responder.
    @discardableResult
    public func test_revealFocusedRow(_ responder: NSResponder?) -> Bool {
        panel.revealFocusedRow(responder)
    }

    /// The collapse-reactive rail geometry the overlay resolves from the current
    /// laid-out frames (origin at ring vs collapsed header, the terminus dot, the
    /// visible device stops). Lets the rail-collapse tests assert the drawn shape.
    public func test_railPlan() -> RailPlan? { panel.test_railPlan() }

    /// The panel's rail overlay — lets tests pin its visibility/Reduce Motion
    /// seams and read its pulse counters through the controller boundary.
    public func test_railOverlay() -> BusRailOverlayView { panel.railOverlay }

    /// Select the Main Out destination directly (drives the routing).
    public func test_selectMainOut(_ target: MainOutTarget) {
        groupController?.setMainOut(target)
        rebuild()
    }

    public func test_activate(groupID: String) {
        groupController?.setMainOut(.group(id: groupID))
        rebuild()
    }

    // MARK: Energize test hooks (item 9)

    /// Drive a Main-Audio source switch through the EXACT production delegate
    /// path (`setMainOut` + `beginEnergize` + `rebuild`), so tests exercise the
    /// energize start beat + announcement the live dropdown does — unlike
    /// `test_selectMainOut`, which is the older plain-switch hook.
    public func test_switchMainOut(_ target: MainOutTarget) {
        mainOutRow(mainOutRow, didSelect: target)
    }

    /// The device ids currently carrying the energize pending beat (item 9).
    public var test_energizePendingIDs: Set<String> { energizePendingIDs }

    /// Whether an energize sequence is mid-flight.
    public var test_energizeActive: Bool { energizeActive }

    /// The last VoiceOver announcement posted (energize start/settle, or the
    /// live-removal offer — one channel).
    public var test_lastEnergizeAnnouncement: String? { lastEnergizeAnnouncement }

    /// The device currently offering the transient "Removed — Undo", if any.
    public var test_removalUndoDeviceID: String? { removalUndoDeviceID }

    /// Fire the offer's retirement timer now (headless runs don't wait 5 s).
    public func test_expireRemovalUndo() { expireRemovalUndo() }

    /// The Cast fixed-volume receivers currently holding the pending fader fill.
    public var test_castVolumePendingIDs: Set<String> { castVolumePendingIDs }

    /// Fire a given id's pending-fill retirement timer now (headless runs
    /// don't wait for the measured lag).
    public func test_expireCastVolumePending(for id: String) { expireCastVolumePending(for: id) }

    /// Force a specific pending set + repaint — the snapshot harness stages a
    /// frozen mid-sequence frame with it (bypassing the async connection
    /// progression that a headless MockBackend never plays).
    public func test_setEnergizePending(_ ids: Set<String>) {
        energizePendingIDs = ids
        energizeActive = !ids.isEmpty
        refreshDeviceRows()
    }

    public func test_saveCurrentSetup() { saveCurrentSetup() }

    /// Subsection titles the LAST rebuild actually rendered, in order —
    /// asserts the Bluetooth subsection's hide-when-empty rule (BT-UI).
    public func test_subsectionTitles() -> [String] { renderedSubsectionTitles }

    /// Fire a device-type subsection's collapse click through the panel's own
    /// header gesture recognizer — the real path a click anywhere on the header
    /// row takes. Returns false if `title` isn't a mounted collapsible header.
    @discardableResult
    public func test_fireSubsectionHeaderClick(title: String) -> Bool {
        panel.test_fireHeaderClick(title: title)
    }

    /// Whether the device-type subsection `title` is currently collapsed.
    public func test_isSubsectionCollapsed(title: String) -> Bool {
        isSubsectionCollapsed(title)
    }

    /// The ids the last rebuild actually mounted device rows for, in render
    /// order — the visibility/collapse assertion surface.
    public func test_renderedDeviceIDs() -> [String] { renderedDeviceOrder().map(\.id) }

    /// The Output Devices "+" menu, built exactly as a live click builds it.
    /// Tests dispatch its items via `NSMenu.performActionForItem(at:)` — real
    /// AppKit menu dispatch, per the row-selection lesson (never a bypass seam).
    public func test_outputDevicesPlusMenu() -> NSMenu { makeOutputDevicesPlusMenu() }
    /// The footer "−" menu a real click would pop (headless twin of
    /// `presentOutputDevicesMinusMenu`).
    public func test_outputDevicesMinusMenu() -> NSMenu { makeOutputDevicesMinusMenu() }
    /// Whether the devices footer's "−" segment is enabled.
    public var test_devicesFooterRemoveEnabled: Bool { devicesFooter.isRemoveEnabled }

    /// The device id whose align-by-ear tick is currently running, if any
    /// (BT-OFFSET-UI) — asserts one-at-a-time + the close/auto-stop paths.
    public func test_alignTickDeviceID() -> String? { alignTickDeviceID }

    /// The Bluetooth subsection's rendered row order (BT-UI ghost-pairing
    /// sort), top to bottom; empty when the subsection is hidden.
    public func test_bluetoothRowOrder() -> [String] { renderedBluetoothOrder }

    /// Whether the last rebuild mounted the Bluetooth empty-state Connect row
    /// (BT-LIST).
    public func test_bluetoothConnectRowShown() -> Bool { renderedBTConnectShown }

    /// Whether the last rebuild printed the card header's "Offset" column
    /// title (2026-08-28: the legend lives on the card header line, once —
    /// never on a subsection header).
    public func test_offsetColumnTitleShown() -> Bool { renderedOffsetColumnTitle }

    /// Fire the Bluetooth empty-state Connect button through real AppKit
    /// target/action dispatch (never a bypass seam).
    public func test_fireBluetoothConnectClick() { bluetoothConnectButton?.performClick(nil) }

    /// Whether the mounted Connect row carries its leading glyph — the half of
    /// "reads as clickable" a headless run can actually see.
    public var test_bluetoothConnectRowHasGlyph: Bool { bluetoothConnectButton?.image != nil }

    /// The Connect row's visible title and the label VoiceOver speaks. They
    /// differ on purpose: the subsection header carries "Bluetooth" for the
    /// eye, the accessibility label carries it for the ear.
    public var test_bluetoothConnectRowTitles: (visible: String, spoken: String?)? {
        guard let button = bluetoothConnectButton else { return nil }
        return (button.title, button.accessibilityLabel())
    }

    /// Leading inset of the Connect row's button from its own row's leading
    /// edge — pinned to `firstElementLeading(indented: false)` (where a
    /// device row's ICON sits), not the deeper `nameColumnLeading` (where a
    /// NAME sits), so the "+" reads as one indent step, not two. `nil` if the
    /// row isn't mounted. Force a layout pass first (e.g. via
    /// `test_panelView`) so the frame is current.
    public var test_bluetoothConnectRowLeadingInset: CGFloat? {
        guard let button = bluetoothConnectButton, let wrap = button.superview else { return nil }
        return button.frame.minX - wrap.bounds.minX
    }

    /// The AirPlay empty-state line the last rebuild rendered, `nil` when it
    /// rendered none.
    public var test_speakerSearchStateText: String? { renderedSpeakerSearchText }

    /// Fire the search grace exactly as its timer would.
    public func test_fireSpeakerSearchGrace() { fireSpeakerSearchGrace() }

    /// Simulate flipping a device row's membership switch through its delegate.
    /// Returns the model's `SelectionResult` so tests can assert refusal/auto-swap.
    @discardableResult
    public func test_toggleDeviceEnabled(deviceID: String, on: Bool) -> GroupController.SelectionResult {
        let result = groupController?.setDeviceSelected(deviceID, on) ?? .ok
        handleSelection(result, deviceID: deviceID)
        return result
    }

    public func test_isSpeakerSelected(_ id: String) -> Bool {
        groupController?.isSpeakerSelected(id) ?? false
    }

    public func test_toggleMute(deviceID: String, muted: Bool) {
        groupController?.setMuted(muted, for: deviceID)
    }

    /// The mounted diagnosis panel for a device, or `nil` when closed/absent
    /// (brief §7.3 test hook).
    public func test_diagnosisPanel(for id: String) -> ConnectionDiagnosisView? {
        diagnosisPanelsByID[id]
    }

    /// Simulate clicking "Try again" in the device's open diagnosis panel.
    public func test_tapRetry(for id: String) {
        diagnosisPanelsByID[id]?.test_tapRetry()
    }

    public func test_dragMainOutMaster(to value: Int) {
        groupController?.setMainOutMasterVolume(value)
        refreshMainOutRow()
    }

    public func test_dragMaster(groupID: String, to value: Int) {
        if groupController?.activeGroupID != groupID {
            groupController?.setMainOut(.group(id: groupID))
        }
        groupController?.setMainOutMasterVolume(value)
    }

    // MARK: Sync drawer seams (T7)
    //
    // These drive the SAME `toggleSyncDrawer` the chip's target/action reaches,
    // but they do skip AppKit's own dispatch — a shortcut that has hidden real
    // breaks in this file before. The chip's wiring is pinned separately, by
    // tests that go through `DeviceRowView.test_fireSyncChipClick()`.

    /// - Parameter animated: production always animates; tests pass `false`
    ///   when they need `removeRow`'s deferred detach to happen synchronously
    ///   (an animated removal keeps the row in the tree for the fade, so a
    ///   height assertion taken right after would measure the old content).
    public func test_toggleSyncDrawer(deviceID: String, animated: Bool = false) {
        toggleSyncDrawer(deviceID: deviceID, animated: animated)
    }

    /// The device whose drawer is currently open (the intent), or `nil`.
    public var test_expandedSyncDeviceID: String? { expandedSyncDeviceID }

    /// Whether a drawer view is actually mounted in the row stack.
    public var test_syncDrawerVisible: Bool { mountedSyncDrawerID != nil }

    /// The mounted drawer itself, for driving its real controls; `nil` when
    /// none is open.
    public var test_syncDrawer: BTSyncDrawerView? {
        mountedSyncDrawerID == nil ? nil : syncDrawer
    }

    /// The panel's settled content height — the value pushed into the
    /// popover's `preferredContentSize`. Tests read it to pin the drawer's
    /// exact expand/collapse delta.
    public var test_panelContentHeight: CGFloat { panel.fittingSizeSettled().height }

    // MARK: Test hooks (W3/W4)

    public func test_btAlignmentOfferedIDs() -> Set<String> { btAlignmentOfferedIDs }
    func test_btAlignmentNoteView(_ id: String) -> BTAlignmentNoteView? {
        btAlignmentNoteViews[id]
    }
    func test_btWizardView() -> BTAlignmentWizardView? { btWizardView }
    func test_btWizardSheet() -> AlignmentWizardViewController? { btWizardSheet }
    func test_btWizardSession() -> BTAlignmentWizardSession? { btWizardSession }
    public func test_btWizardIsOpen() -> Bool { btWizardSession != nil }
    public func test_btWizardReferenceID() -> String? { btWizardSession?.reference?.id }
    /// The reference the RUN selected for itself (`nil` when it was already
    /// audible) — the restore's ledger.
    public func test_btWizardEngagedReferenceID() -> String? { btWizardEngagedReferenceID }

    /// Test-only: whether the fallback banner is currently reflected in the panel.
    var test_localFallbackBannerText: String? { panel.test_bannerText }
    /// Test-only: whether the fallback banner currently offers its retry action.
    var test_bannerHasActionButton: Bool { panel.test_bannerHasActionButton }
    /// Test-only: simulate a click on the fallback banner's action button.
    func test_tapBannerAction() { panel.test_tapBannerAction() }
}
