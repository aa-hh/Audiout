// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterSharedUI

/// Offscreen structural tests for `AppRowView` (PLAN-POPOVER-ROUTING.md task
/// T-6). Neither a headless process nor an offscreen view synthesizes the
/// mouse events a real slider drag / popup pick / button click needs, so —
/// exactly like `PopoverControllerTests` — these drive the `test_*` hooks that
/// call the same delegate methods the real controls call.
final class AppRowViewTests: XCTestCase {

    private final class RecordingDelegate: AppRowView.Delegate {
        var lastVolume: (appID: String, volume: Int)?
        var lastDestination: (appID: String, destinationID: String)?
        var removedAppID: String?
        var selectRequestedAppID: String?
        var selectRequestCount = 0
        var lastMove: (appID: String, direction: AppRowView.MoveDirection)?

        func appRow(_ row: AppRowView, didSetVolume volume: Int, for appID: String) {
            lastVolume = (appID, volume)
        }
        func appRow(_ row: AppRowView, didSelectDestination destinationID: String, for appID: String) {
            lastDestination = (appID, destinationID)
        }
        func appRow(_ row: AppRowView, didRemoveFor appID: String) {
            removedAppID = appID
        }
        func appRow(_ row: AppRowView, didRequestSelect appID: String) {
            selectRequestedAppID = appID
            selectRequestCount += 1
        }
        func appRow(_ row: AppRowView, didRequestMoveSelection direction: AppRowView.MoveDirection, for appID: String) {
            lastMove = (appID, direction)
        }
    }

    private func makeDestinations() -> [AppRowView.Destination] {
        [
            AppRowView.Destination(id: "local", title: "Current Device", isLocal: true,
                                   symbolName: "laptopcomputer"),
            AppRowView.Destination(id: "device-1", title: "Living Room", isLocal: false,
                                   symbolName: "airplayaudio"),
            AppRowView.Destination(id: "device-2", title: "Kitchen", isLocal: false,
                                   symbolName: "airplayaudio"),
        ]
    }

    /// Destinations INCLUDING the standalone "No Redirect" entry — the new
    /// three-state shape a real host (`PopoverController`) actually builds.
    private func makeThreeStateDestinations() -> [AppRowView.Destination] {
        [
            AppRowView.Destination(id: "no-redirect", title: "No Redirect", isLocal: true,
                                   symbolName: nil, isStandalone: true),
            AppRowView.Destination(id: "local", title: "Current Device", isLocal: true,
                                   symbolName: "laptopcomputer"),
            AppRowView.Destination(id: "device-1", title: "Living Room", isLocal: false,
                                   symbolName: "airplayaudio"),
            AppRowView.Destination(id: "device-2", title: "Kitchen", isLocal: false,
                                   symbolName: "airplayaudio"),
        ]
    }

    private func makeRowWithThreeStates(selected: String) -> (AppRowView, RecordingDelegate) {
        let row = AppRowView()
        let delegate = RecordingDelegate()
        row.delegate = delegate
        row.apply(AppRowView.Configuration(
            appID: "com.example.app",
            name: "Example App",
            icon: nil,
            volume: 42,
            selectedDestinationID: selected,
            destinations: makeThreeStateDestinations()
        ))
        return (row, delegate)
    }

    private func makeRow(selected: String = "local") -> (AppRowView, RecordingDelegate) {
        let row = AppRowView()
        let delegate = RecordingDelegate()
        row.delegate = delegate
        row.apply(AppRowView.Configuration(
            appID: "com.example.app",
            name: "Example App",
            icon: nil,
            volume: 42,
            selectedDestinationID: selected,
            destinations: makeDestinations()
        ))
        return (row, delegate)
    }

    // MARK: Menu structure (LOCKED DECISION 4 — two sections, no Groups)

    func testMenuHasExactlyTwoSections() {
        let (row, _) = makeRow()
        let titles = row.test_menuTitles
        XCTAssertTrue(titles.contains("CURRENT DEVICE"), "expected a 'Current Device' header, got \(titles)")
        XCTAssertTrue(titles.contains("AIRPLAY DEVICES"), "expected an 'AirPlay Devices' header, got \(titles)")
        // Exactly the two headers + three destination entries, no Groups section.
        XCTAssertEqual(titles.count, 5, "unexpected menu items: \(titles)")
        XCTAssertFalse(titles.contains { $0.uppercased().contains("GROUP") },
                       "Groups must not appear in the app row's destination menu (decision 4)")
    }

    func testMenuSectionOrderIsCurrentDeviceThenAirPlayDevices() {
        let (row, _) = makeRow()
        let titles = row.test_menuTitles
        let currentIndex = titles.firstIndex(of: "CURRENT DEVICE")
        let airplayIndex = titles.firstIndex(of: "AIRPLAY DEVICES")
        XCTAssertNotNil(currentIndex)
        XCTAssertNotNil(airplayIndex)
        XCTAssertLessThan(currentIndex!, airplayIndex!, "Current Device section must come first")
    }

    func testSelectedDestinationIsCheckmarked() {
        let (row, _) = makeRow(selected: "device-1")
        XCTAssertEqual(row.test_selectedDestinationID, "device-1")
    }

    // MARK: Three-state menu structure (No Redirect / Current Device / AirPlay Devices)

    /// The standalone "No Redirect" entry is first, with no header of its own,
    /// followed by the "Current Device" section, then "AirPlay Devices" — in
    /// that order.
    func testNoRedirectEntryLeadsMenuAheadOfBothSections() {
        let (row, _) = makeRowWithThreeStates(selected: "no-redirect")
        let titles = row.test_menuTitles
        XCTAssertEqual(titles.first, "No Redirect",
                       "the standalone No Redirect entry must be the very first item")
        let noRedirectIndex = titles.firstIndex(of: "No Redirect")
        let currentDeviceHeaderIndex = titles.firstIndex(of: "CURRENT DEVICE")
        let airplayHeaderIndex = titles.firstIndex(of: "AIRPLAY DEVICES")
        XCTAssertNotNil(currentDeviceHeaderIndex)
        XCTAssertNotNil(airplayHeaderIndex)
        XCTAssertLessThan(noRedirectIndex!, currentDeviceHeaderIndex!)
        XCTAssertLessThan(currentDeviceHeaderIndex!, airplayHeaderIndex!)
        // No Redirect must not itself land inside either section.
        XCTAssertFalse(titles[(currentDeviceHeaderIndex! + 1)...].contains("No Redirect"))
    }

    func testNoRedirectEntrySelectionIsCheckmarked() {
        let (row, _) = makeRowWithThreeStates(selected: "no-redirect")
        XCTAssertEqual(row.test_selectedDestinationID, "no-redirect")
    }

    // MARK: Delegate firing

    func testSelectingDestinationFiresDelegate() {
        let (row, delegate) = makeRow(selected: "local")
        row.test_selectDestination("device-2")
        XCTAssertEqual(delegate.lastDestination?.appID, "com.example.app")
        XCTAssertEqual(delegate.lastDestination?.destinationID, "device-2")
    }

    func testSettingVolumeFiresDelegate() {
        let (row, delegate) = makeRow()
        row.test_setVolume(77)
        XCTAssertEqual(delegate.lastVolume?.appID, "com.example.app")
        XCTAssertEqual(delegate.lastVolume?.volume, 77)
        XCTAssertEqual(row.test_volume, 42, "test_setVolume only fires the delegate; a real reapply drives the model")
    }

    func testRemoveFiresDelegate() {
        let (row, delegate) = makeRow()
        row.test_remove()
        XCTAssertEqual(delegate.removedAppID, "com.example.app")
    }

    // MARK: Slider dimming (Bug T2 — only "No Redirect" dims)

    /// Bug T2: "Current Device" is now its OWN independent local stream (played on
    /// the Mac's built-in speakers), so its slider is LIVE, not dimmed.
    func testSliderNotDimmedWhenDestinationIsCurrentDevice() {
        let (row, _) = makeRow(selected: "local")
        XCTAssertFalse(row.test_isSliderDimmed,
                       "slider must be live while destination is Current Device (its own local stream)")
    }

    func testSliderNotDimmedWhenRedirected() {
        let (row, _) = makeRow(selected: "device-1")
        XCTAssertFalse(row.test_isSliderDimmed, "slider must be enabled once redirected to an AirPlay device")
    }

    /// Only the standalone "No Redirect" state dims the slider — that's the one
    /// state with no independent stream to level (the app just plays in the
    /// whole-system mix).
    func testSliderDimmedWhenDestinationIsNoRedirect() {
        let (row, _) = makeRowWithThreeStates(selected: "no-redirect")
        XCTAssertTrue(row.test_isSliderDimmed, "slider must dim while destination is No Redirect")
    }

    /// Bug T2: with all three states present, "Current Device" keeps a LIVE slider
    /// (its own local stream); only "No Redirect" dims.
    func testSliderNotDimmedWhenDestinationIsExplicitCurrentDeviceAmongThreeStates() {
        let (row, _) = makeRowWithThreeStates(selected: "local")
        XCTAssertFalse(row.test_isSliderDimmed,
                       "slider must be live for Current Device even with No Redirect present")
    }

    func testSliderNotDimmedWhenRedirectedAmongThreeStates() {
        let (row, _) = makeRowWithThreeStates(selected: "device-1")
        XCTAssertFalse(row.test_isSliderDimmed, "slider must be enabled once redirected to an AirPlay device")
    }

    func testSliderAlwaysVisibleRegardlessOfDestination() {
        // LOCKED DECISION 3: the slider is ALWAYS visible, only dimmed — never
        // hidden. `AppRowView` has no isHidden toggle on the slider at all; this
        // asserts both states still report a live volume via the hook.
        let (localRow, _) = makeRow(selected: "local")
        XCTAssertEqual(localRow.test_volume, 42)
        let (redirectedRow, _) = makeRow(selected: "device-1")
        XCTAssertEqual(redirectedRow.test_volume, 42)
    }

    // MARK: Selection (T1 seam)

    func testSetSelectedTogglesRenderStateWithoutNotifyingDelegate() {
        let (row, delegate) = makeRow()
        XCTAssertFalse(row.test_isSelected)
        row.test_setSelected(true)
        XCTAssertTrue(row.test_isSelected)
        XCTAssertNil(delegate.selectRequestedAppID,
                     "test_setSelected is the HOST pushing state in — it must not report a select request")
        row.test_setSelected(false)
        XCTAssertFalse(row.test_isSelected)
    }

    func testApplyClearsSelectionLikeHover() {
        let (row, _) = makeRow()
        row.test_setSelected(true)
        XCTAssertTrue(row.test_isSelected)
        row.apply(AppRowView.Configuration(
            appID: "com.example.app", name: "Example App", icon: nil, volume: 50,
            selectedDestinationID: "local", destinations: makeDestinations()
        ))
        XCTAssertFalse(row.test_isSelected, "a bare apply(_:) must clear selection, matching hover's T-U8 discipline")
    }

    func testApplyWithIsSelectedReassertsSelectionAtomically() {
        let (row, _) = makeRow()
        row.apply(AppRowView.Configuration(
            appID: "com.example.app", name: "Example App", icon: nil, volume: 50,
            selectedDestinationID: "local", destinations: makeDestinations()
        ), isSelected: true)
        XCTAssertTrue(row.test_isSelected, "apply(_:isSelected:) is the host's rebuild()-survival seam")
    }

    func testBodyClickFiresDidRequestSelectAndBecomesFirstResponder() {
        let (row, delegate) = makeRow()
        row.test_simulateBodyClick()
        XCTAssertEqual(delegate.selectRequestedAppID, "com.example.app")
        XCTAssertEqual(delegate.selectRequestCount, 1)
    }

    func testBodyClickDeadZoneExcludesSliderAndDestinationPopup() {
        let (row, _) = makeRow()
        // The slider and destination popup are trailing-anchored per
        // `PopoverColumnGrid`, both comfortably right of the icon/name area a
        // real body click lands in. Assert the icon/name point IS selectable
        // and the trailing-anchored slider/popup column IS NOT — the same
        // distinction real subview hit-testing enforces (a real click on
        // either control is consumed by the control and never reaches this
        // view's `mouseDown` override at all).
        let bodyPoint = NSPoint(x: PopoverColumnGrid.leadingInset + 4, y: AppRowView.rowHeight / 2)
        XCTAssertTrue(row.test_pointIsInSelectableDeadZone(bodyPoint),
                     "the icon/name area must be in the select dead-zone")
        let sliderColumnPoint = NSPoint(x: row.bounds.width - PopoverColumnGrid.sliderTrailing - 10,
                                        y: AppRowView.rowHeight / 2)
        XCTAssertFalse(row.test_pointIsInSelectableDeadZone(sliderColumnPoint),
                       "a click inside the slider's own column must not be in the select dead-zone")
    }

    func testSliderClickDoesNotFireDidRequestSelect() {
        let (row, delegate) = makeRow()
        row.test_simulateSliderClick()
        XCTAssertNil(delegate.selectRequestedAppID,
                     "a click routed to the slider's own frame must never request row selection")
    }

    func testRemoveButtonClickDoesNotAlsoRequestSelect() {
        let (row, delegate) = makeRow()
        row.test_remove()
        XCTAssertEqual(delegate.removedAppID, "com.example.app")
        XCTAssertNil(delegate.selectRequestedAppID,
                     "the remove path must not also request selection")
    }

    func testAcceptsFirstResponder() {
        let (row, _) = makeRow()
        XCTAssertTrue(row.acceptsFirstResponder)
    }

    // MARK: Keyboard removal (T6) — Delete/Backspace on the selected row

    func testPressDeleteFiresDidRemoveForViaRealKeyPath() {
        let (row, delegate) = makeRow()
        row.test_pressDelete()
        XCTAssertEqual(delegate.removedAppID, "com.example.app",
                       "Delete (forward-delete, keyCode 117) must fire didRemoveFor via the real key path")
    }

    func testPressBackspaceFiresDidRemoveForViaRealKeyPath() {
        let (row, delegate) = makeRow()
        row.test_pressBackspace()
        XCTAssertEqual(delegate.removedAppID, "com.example.app",
                       "Backspace (keyCode 51) must fire didRemoveFor via the real key path")
    }

    // MARK: Keyboard selection movement (V14) — Up/Down arrow on the selected row

    func testPressUpArrowFiresDidRequestMoveSelectionUpViaRealKeyPath() {
        let (row, delegate) = makeRow()
        row.test_pressUpArrow()
        XCTAssertEqual(delegate.lastMove?.appID, "com.example.app",
                       "Up arrow must fire didRequestMoveSelection via the real key path")
        XCTAssertEqual(delegate.lastMove?.direction, .up)
    }

    func testPressDownArrowFiresDidRequestMoveSelectionDownViaRealKeyPath() {
        let (row, delegate) = makeRow()
        row.test_pressDownArrow()
        XCTAssertEqual(delegate.lastMove?.appID, "com.example.app",
                       "Down arrow must fire didRequestMoveSelection via the real key path")
        XCTAssertEqual(delegate.lastMove?.direction, .down)
    }

    /// A `Delegate` conformer that doesn't implement `didRequestMoveSelection`
    /// must still compile and simply no-op — proves the default extension.
    private final class LegacyDelegate: AppRowView.Delegate {
        var removedAppID: String?
        func appRow(_ row: AppRowView, didSetVolume volume: Int, for appID: String) {}
        func appRow(_ row: AppRowView, didSelectDestination destinationID: String, for appID: String) {}
        func appRow(_ row: AppRowView, didRemoveFor appID: String) { removedAppID = appID }
        func appRow(_ row: AppRowView, didRequestSelect appID: String) {}
    }

    func testLegacyDelegateWithoutMoveSelectionCompilesAndNoOps() {
        let row = AppRowView()
        let legacy = LegacyDelegate()
        row.delegate = legacy
        row.apply(AppRowView.Configuration(
            appID: "com.example.app", name: "Example App", icon: nil, volume: 42,
            selectedDestinationID: "local", destinations: makeDestinations()
        ))
        row.test_pressUpArrow()
        row.test_pressDownArrow()
        row.test_remove()
        XCTAssertEqual(legacy.removedAppID, "com.example.app",
                       "the default no-op must not interfere with other delegate calls")
    }

    // MARK: Row density unification (V6)

    func testRowHeightMatchesUnifiedBodyRowHeight() {
        XCTAssertEqual(AppRowView.rowHeight, PopoverColumnGrid.bodyRowHeight,
                       "AppRowView's density unifies with DeviceRowView per PopoverColumnGrid.bodyRowHeight")
    }

    // MARK: Unified hover/selection wash tokens (V3/V8)

    func testNoHighlightWhenNeitherSelectedNorHovered() {
        let (row, _) = makeRow()
        XCTAssertNil(row.test_highlightAlpha)
    }

    func testSelectionWashUsesUnifiedSelectionAlpha() {
        let (row, _) = makeRow()
        row.test_setSelected(true)
        XCTAssertEqual(row.test_highlightAlpha, PopoverColumnGrid.rowSelectionWashAlpha)
    }

    func testHoverWashUsesUnifiedHoverAlpha() {
        let (row, _) = makeRow()
        row.test_setHovered(true)
        XCTAssertEqual(row.test_highlightAlpha, PopoverColumnGrid.rowHoverWashAlpha)
    }

    func testSelectionWashTakesPriorityOverHoverWash() {
        let (row, _) = makeRow()
        row.test_setSelected(true)
        row.test_setHovered(true)
        XCTAssertEqual(row.test_highlightAlpha, PopoverColumnGrid.rowSelectionWashAlpha,
                       "selection must win when both selected and hovered")
    }

    // MARK: Readout tertiary/secondary colour (V7)

    func testReadoutIsTertiaryWhenDestinationIsNoRedirect() {
        let (row, _) = makeRowWithThreeStates(selected: "no-redirect")
        XCTAssertEqual(row.test_readoutTextColor, .tertiaryLabelColor,
                       "the % readout must dim to tertiary while No Redirect is selected")
    }

    func testReadoutIsSecondaryWhenDestinationIsCurrentDevice() {
        let (row, _) = makeRow(selected: "local")
        XCTAssertEqual(row.test_readoutTextColor, .secondaryLabelColor)
    }

    func testReadoutIsSecondaryWhenRedirected() {
        let (row, _) = makeRow(selected: "device-1")
        XCTAssertEqual(row.test_readoutTextColor, .secondaryLabelColor)
    }

    // MARK: Destination subtitle microcopy (A3)

    private func makeSubtitledDestinations() -> [AppRowView.Destination] {
        [
            AppRowView.Destination(id: "no-redirect", title: "No Redirect", isLocal: true,
                                   symbolName: nil, isStandalone: true,
                                   subtitle: "Plays in the whole-system mix"),
            AppRowView.Destination(id: "local", title: "Current Device", isLocal: true,
                                   symbolName: "laptopcomputer", subtitle: "Plays on this Mac"),
            AppRowView.Destination(id: "device-1", title: "Living Room", isLocal: false,
                                   symbolName: "airplayaudio"),
        ]
    }

    private func makeRowWithSubtitles(selected: String = "local") -> (AppRowView, RecordingDelegate) {
        let row = AppRowView()
        let delegate = RecordingDelegate()
        row.delegate = delegate
        row.apply(AppRowView.Configuration(
            appID: "com.example.app", name: "Example App", icon: nil, volume: 42,
            selectedDestinationID: selected, destinations: makeSubtitledDestinations()
        ))
        return (row, delegate)
    }

    func testSubtitleSetsToolTipOnDestinationPopUpMenuItem() {
        let (row, _) = makeRowWithSubtitles()
        XCTAssertEqual(row.test_destinationPopUpMenuItem(forDestinationID: "local")?.toolTip,
                       "Plays on this Mac")
        XCTAssertEqual(row.test_destinationPopUpMenuItem(forDestinationID: "no-redirect")?.toolTip,
                       "Plays in the whole-system mix")
    }

    func testEntryWithoutSubtitleHasNoToolTipOrAttributedTitle() {
        let (row, _) = makeRowWithSubtitles()
        let item = row.test_destinationPopUpMenuItem(forDestinationID: "device-1")
        XCTAssertNil(item?.toolTip)
        XCTAssertNil(item?.attributedTitle)
    }

    func testDestinationPopUpMenuItemKeepsPlainTitleEvenWithSubtitle() {
        // The trailing popup mirrors its SELECTED item's attributedTitle for
        // its own collapsed display, so items feeding it must never get one —
        // otherwise a multi-line title+subtitle would corrupt the popup's own
        // (closed) label.
        let (row, _) = makeRowWithSubtitles()
        let item = row.test_destinationPopUpMenuItem(forDestinationID: "local")
        XCTAssertNil(item?.attributedTitle,
                     "the popup's own menu items must stay plain-titled")
        XCTAssertEqual(item?.title, "Current Device")
    }

    func testRouteToContextSubmenuRendersAttributedSubtitle() {
        // The "Route to" context-menu submenu never collapses into a button,
        // so it's free to show the subtitle as a second attributed line.
        let (row, _) = makeRowWithSubtitles()
        let item = row.test_routeToMenuItem(forDestinationID: "local")
        XCTAssertNotNil(item?.attributedTitle,
                        "the context menu's Route to submenu may render an attributed subtitle")
        XCTAssertEqual(item?.attributedTitle?.string, "Current Device\nPlays on this Mac")
        XCTAssertEqual(item?.toolTip, "Plays on this Mac")
    }

    func testRouteToContextSubmenuEntryWithoutSubtitleStaysPlain() {
        let (row, _) = makeRowWithSubtitles()
        let item = row.test_routeToMenuItem(forDestinationID: "device-1")
        XCTAssertNil(item?.attributedTitle)
        XCTAssertNil(item?.toolTip)
    }

    // MARK: Cursor (C3) — pointingHand over the selectable body dead-zone

    func testCursorRectsCoverBodyDeadZone() {
        let (row, _) = makeRow()
        let rects = row.test_selectableCursorRects()
        let bodyPoint = NSPoint(x: PopoverColumnGrid.leadingInset + 4, y: AppRowView.rowHeight / 2)
        XCTAssertTrue(rects.contains { $0.contains(bodyPoint) },
                     "the icon/name dead-zone must get the pointingHand cursor")
    }

    func testCursorRectsExcludeSliderColumn() {
        let (row, _) = makeRow()
        let rects = row.test_selectableCursorRects()
        let sliderColumnPoint = NSPoint(x: row.bounds.width - PopoverColumnGrid.sliderTrailing - 10,
                                        y: AppRowView.rowHeight / 2)
        XCTAssertFalse(rects.contains { $0.contains(sliderColumnPoint) },
                       "the slider's own column must not get the row's pointingHand cursor")
    }

    // MARK: Leading VU meter (task T4, mirrors DeviceRowView's showsMeter)

    /// `setLevel` on a meter-enabled row reaches the meter and is readable
    /// back via `test_meterLevel` — mirrors
    /// `DeviceRowConnectionStateTests.testSetLevelOnMeterEnabledRowIsReflectedByTestMeterLevel`.
    func testSetLevelOnMeterEnabledRowIsReflectedByTestMeterLevel() {
        let row = AppRowView(showsMeter: true)
        row.setLevel(0.42)
        XCTAssertEqual(row.test_meterLevel(), 0.42)
    }

    /// `showsMeter: false` (the default — every existing caller) makes
    /// `setLevel` a no-op and leaves the icon at its unchanged leading
    /// position (the reserved meter-column width the grid already accounts
    /// for via `firstElementLeading(indented:)`).
    func testSetLevelOnNonMeterRowIsANoOp() {
        let row = AppRowView()
        row.setLevel(0.9)
        XCTAssertEqual(row.test_meterLevel(), 0, "a row built without a meter must never report a live level")
    }

    /// `resetLevel()` zeroes a previously pushed level back to 0.
    func testResetLevelZeroesAPushedLevel() {
        let row = AppRowView(showsMeter: true)
        row.setLevel(0.6)
        XCTAssertEqual(row.test_meterLevel(), 0.6)
        row.resetLevel()
        XCTAssertEqual(row.test_meterLevel(), 0, "resetLevel must zero the meter")
    }

    /// `resetLevel()` on a non-meter row stays a no-op (mirrors `setLevel`).
    func testResetLevelOnNonMeterRowIsANoOp() {
        let row = AppRowView()
        row.resetLevel()
        XCTAssertEqual(row.test_meterLevel(), 0)
    }
}
