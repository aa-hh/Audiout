// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudioutSharedUI

/// Offscreen structural tests for `AppRowView` (PLAN-POPOVER-ROUTING.md task
/// T-6). Neither a headless process nor an offscreen view synthesizes the
/// mouse events a real slider drag / popup pick / button click needs, so —
/// exactly like `PopoverControllerTests` — these drive the `test_*` hooks that
/// call the same delegate methods the real controls call.
@MainActor
@Suite struct AppRowViewTests {

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
            AppRowView.Destination(id: "no-redirect", title: "Follows main output", isLocal: true,
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

    @Test func menuHasExactlyTwoSections() {
        let (row, _) = makeRow()
        let titles = row.test_menuTitles
        #expect(titles.contains("Current Device"), "expected a 'Current Device' header, got \(titles)")
        #expect(titles.contains("AirPlay Devices"), "expected an 'AirPlay Devices' header, got \(titles)")
        // Exactly the two headers + three destination entries, no Groups section.
        #expect(titles.count == 5, "unexpected menu items: \(titles)")
        #expect(!titles.contains { $0.uppercased().contains("GROUP") },
                       "Groups must not appear in the app row's destination menu (decision 4)")
    }

    @Test func menuSectionOrderIsCurrentDeviceThenAirPlayDevices() {
        let (row, _) = makeRow()
        let titles = row.test_menuTitles
        let currentIndex = titles.firstIndex(of: "Current Device")
        let airplayIndex = titles.firstIndex(of: "AirPlay Devices")
        #expect(currentIndex != nil)
        #expect(airplayIndex != nil)
        #expect(currentIndex! < airplayIndex!, "Current Device section must come first")
    }

    @Test func selectedDestinationIsCheckmarked() {
        let (row, _) = makeRow(selected: "device-1")
        #expect(row.test_selectedDestinationID == "device-1")
    }

    // MARK: Three-state menu structure (No Redirect / Current Device / AirPlay Devices)

    /// The standalone entry is first, with no header of its own, followed by
    /// the "Current Device" section, then "AirPlay Devices" — in that order.
    /// Its host-supplied title is the bridge phrase "Follows main output"
    /// (Warm Signal spec 5.1, decision 3 — S6), rendered VERBATIM like every
    /// other entry (host-supplies-copy doctrine).
    @Test func noRedirectEntryLeadsMenuAheadOfBothSections() {
        let (row, _) = makeRowWithThreeStates(selected: "no-redirect")
        let titles = row.test_menuTitles
        #expect(titles.first == "Follows main output",
                "the standalone entry must be first, displayed as the bridge phrase")
        let standaloneIndex = titles.firstIndex(of: "Follows main output")
        let currentDeviceHeaderIndex = titles.firstIndex(of: "Current Device")
        let airplayHeaderIndex = titles.firstIndex(of: "AirPlay Devices")
        #expect(currentDeviceHeaderIndex != nil)
        #expect(airplayHeaderIndex != nil)
        #expect(standaloneIndex! < currentDeviceHeaderIndex!)
        #expect(currentDeviceHeaderIndex! < airplayHeaderIndex!)
        // The standalone entry must not itself land inside either section.
        #expect(!titles[(currentDeviceHeaderIndex! + 1)...].contains("Follows main output"))
    }

    @Test func noRedirectEntrySelectionIsCheckmarked() {
        let (row, _) = makeRowWithThreeStates(selected: "no-redirect")
        #expect(row.test_selectedDestinationID == "no-redirect")
    }

    // MARK: Delegate firing

    @Test func selectingDestinationFiresDelegate() {
        let (row, delegate) = makeRow(selected: "local")
        row.test_selectDestination("device-2")
        #expect(delegate.lastDestination?.appID == "com.example.app")
        #expect(delegate.lastDestination?.destinationID == "device-2")
    }

    @Test func settingVolumeFiresDelegate() {
        let (row, delegate) = makeRow()
        row.test_setVolume(77)
        #expect(delegate.lastVolume?.appID == "com.example.app")
        #expect(delegate.lastVolume?.volume == 77)
        #expect(row.test_volume == 42, "test_setVolume only fires the delegate; a real reapply drives the model")
    }

    @Test func removeFiresDelegate() {
        let (row, delegate) = makeRow()
        row.test_remove()
        #expect(delegate.removedAppID == "com.example.app")
    }

    // MARK: Slider enablement (no destination dims it any more)

    /// Bug T2: "Current Device" is its OWN independent local stream (played on
    /// the Mac's built-in speakers), so its slider is LIVE, not dimmed.
    @Test func sliderNotDimmedWhenDestinationIsCurrentDevice() {
        let (row, _) = makeRow(selected: "local")
        #expect(!row.test_isSliderDimmed,
                       "slider must be live while destination is Current Device (its own local stream)")
    }

    @Test func sliderNotDimmedWhenRedirected() {
        let (row, _) = makeRow(selected: "device-1")
        #expect(!row.test_isSliderDimmed, "slider must be enabled once redirected to an AirPlay device")
    }

    /// "No Redirect" is live too: below 100 the app is intercepted and summed
    /// back into the whole-system mix at that volume, so the slider does something
    /// in every destination state.
    @Test func sliderLiveWhenDestinationIsNoRedirect() {
        let (row, _) = makeRowWithThreeStates(selected: "no-redirect")
        #expect(!row.test_isSliderDimmed,
                "slider must stay live on No Redirect — below 100 the app is levelled in the mix")
    }

    /// Bug T2: with all three states present, "Current Device" keeps a LIVE slider
    /// (its own local stream).
    @Test func sliderNotDimmedWhenDestinationIsExplicitCurrentDeviceAmongThreeStates() {
        let (row, _) = makeRowWithThreeStates(selected: "local")
        #expect(!row.test_isSliderDimmed,
                       "slider must be live for Current Device even with No Redirect present")
    }

    @Test func sliderNotDimmedWhenRedirectedAmongThreeStates() {
        let (row, _) = makeRowWithThreeStates(selected: "device-1")
        #expect(!row.test_isSliderDimmed, "slider must be enabled once redirected to an AirPlay device")
    }

    @Test func sliderAlwaysVisibleRegardlessOfDestination() {
        // LOCKED DECISION 3: the slider is ALWAYS visible — never hidden.
        // `AppRowView` has no isHidden toggle on the slider at all; this asserts
        // both states still report a live volume via the hook.
        let (localRow, _) = makeRow(selected: "local")
        #expect(localRow.test_volume == 42)
        let (redirectedRow, _) = makeRow(selected: "device-1")
        #expect(redirectedRow.test_volume == 42)
    }

    // MARK: Selection (T1 seam)

    @Test func setSelectedTogglesRenderStateWithoutNotifyingDelegate() {
        let (row, delegate) = makeRow()
        #expect(!row.test_isSelected)
        row.test_setSelected(true)
        #expect(row.test_isSelected)
        #expect(delegate.selectRequestedAppID == nil,
                     "test_setSelected is the HOST pushing state in — it must not report a select request")
        row.test_setSelected(false)
        #expect(!row.test_isSelected)
    }

    @Test func applyClearsSelectionLikeHover() {
        let (row, _) = makeRow()
        row.test_setSelected(true)
        #expect(row.test_isSelected)
        row.apply(AppRowView.Configuration(
            appID: "com.example.app", name: "Example App", icon: nil, volume: 50,
            selectedDestinationID: "local", destinations: makeDestinations()
        ))
        #expect(!row.test_isSelected, "a bare apply(_:) must clear selection, matching hover's T-U8 discipline")
    }

    @Test func applyWithIsSelectedReassertsSelectionAtomically() {
        let (row, _) = makeRow()
        row.apply(AppRowView.Configuration(
            appID: "com.example.app", name: "Example App", icon: nil, volume: 50,
            selectedDestinationID: "local", destinations: makeDestinations()
        ), isSelected: true)
        #expect(row.test_isSelected, "apply(_:isSelected:) is the host's rebuild()-survival seam")
    }

    @Test func bodyClickFiresDidRequestSelectAndBecomesFirstResponder() {
        let (row, delegate) = makeRow()
        row.test_simulateBodyClick()
        #expect(delegate.selectRequestedAppID == "com.example.app")
        #expect(delegate.selectRequestCount == 1)
    }

    @Test func bodyClickDeadZoneExcludesSliderAndDestinationPopup() {
        let (row, _) = makeRow()
        // The slider and destination popup are trailing-anchored per
        // `PopoverColumnGrid`, both comfortably right of the icon/name area a
        // real body click lands in. Assert the icon/name point IS selectable
        // and the trailing-anchored slider/popup column IS NOT — the same
        // distinction real subview hit-testing enforces (a real click on
        // either control is consumed by the control and never reaches this
        // view's `mouseDown` override at all).
        let bodyPoint = NSPoint(x: PopoverColumnGrid.leadingInset + 4, y: AppRowView.rowHeight / 2)
        #expect(row.test_pointIsInSelectableDeadZone(bodyPoint),
                     "the icon/name area must be in the select dead-zone")
        let sliderColumnPoint = NSPoint(x: row.bounds.width - PopoverColumnGrid.sliderTrailing - 10,
                                        y: AppRowView.rowHeight / 2)
        #expect(!row.test_pointIsInSelectableDeadZone(sliderColumnPoint),
                       "a click inside the slider's own column must not be in the select dead-zone")
    }

    @Test func sliderClickDoesNotFireDidRequestSelect() {
        let (row, delegate) = makeRow()
        row.test_simulateSliderClick()
        #expect(delegate.selectRequestedAppID == nil,
                     "a click routed to the slider's own frame must never request row selection")
    }

    @Test func removeButtonClickDoesNotAlsoRequestSelect() {
        let (row, delegate) = makeRow()
        row.test_remove()
        #expect(delegate.removedAppID == "com.example.app")
        #expect(delegate.selectRequestedAppID == nil,
                     "the remove path must not also request selection")
    }

    @Test func acceptsFirstResponder() {
        let (row, _) = makeRow()
        #expect(row.acceptsFirstResponder)
    }

    // MARK: Keyboard removal (T6) — Delete/Backspace on the selected row

    @Test func pressDeleteFiresDidRemoveForViaRealKeyPath() {
        let (row, delegate) = makeRow()
        row.test_pressDelete()
        #expect(delegate.removedAppID == "com.example.app",
                       "Delete (forward-delete, keyCode 117) must fire didRemoveFor via the real key path")
    }

    @Test func pressBackspaceFiresDidRemoveForViaRealKeyPath() {
        let (row, delegate) = makeRow()
        row.test_pressBackspace()
        #expect(delegate.removedAppID == "com.example.app",
                       "Backspace (keyCode 51) must fire didRemoveFor via the real key path")
    }

    // MARK: Keyboard selection movement (V14) — Up/Down arrow on the selected row

    @Test func pressUpArrowFiresDidRequestMoveSelectionUpViaRealKeyPath() {
        let (row, delegate) = makeRow()
        row.test_pressUpArrow()
        #expect(delegate.lastMove?.appID == "com.example.app",
                       "Up arrow must fire didRequestMoveSelection via the real key path")
        #expect(delegate.lastMove?.direction == .up)
    }

    @Test func pressDownArrowFiresDidRequestMoveSelectionDownViaRealKeyPath() {
        let (row, delegate) = makeRow()
        row.test_pressDownArrow()
        #expect(delegate.lastMove?.appID == "com.example.app",
                       "Down arrow must fire didRequestMoveSelection via the real key path")
        #expect(delegate.lastMove?.direction == .down)
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

    @Test func legacyDelegateWithoutMoveSelectionCompilesAndNoOps() {
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
        #expect(legacy.removedAppID == "com.example.app",
                       "the default no-op must not interfere with other delegate calls")
    }

    // MARK: Row density unification (V6)

    @Test func rowHeightMatchesUnifiedBodyRowHeight() {
        #expect(AppRowView.rowHeight == PopoverColumnGrid.bodyRowHeight,
                       "AppRowView's density unifies with DeviceRowView per PopoverColumnGrid.bodyRowHeight")
    }

    // MARK: Unified hover/selection wash tokens (V3/V8)

    @Test func noHighlightWhenNeitherSelectedNorHovered() {
        // An unrouted app is not sounding, so it paints no wash of any kind.
        let (row, _) = makeRowWithThreeStates(selected: "no-redirect")
        #expect(row.test_highlightAlpha == nil)
    }

    @Test func selectionWashUsesUnifiedSelectionAlpha() {
        let (row, _) = makeRow()
        row.test_setSelected(true)
        #expect(row.test_highlightAlpha == PopoverColumnGrid.rowSelectionWashAlpha)
    }

    @Test func hoverWashUsesUnifiedHoverAlpha() {
        // Hover is the faintest of the three, so it needs a row that is not
        // sounding to be the wash that shows.
        let (row, _) = makeRowWithThreeStates(selected: "no-redirect")
        row.test_setHovered(true)
        #expect(row.test_highlightAlpha == PopoverColumnGrid.rowHoverWashAlpha)
    }

    @Test func selectionWashTakesPriorityOverHoverWash() {
        let (row, _) = makeRow()
        row.test_setSelected(true)
        row.test_setHovered(true)
        #expect(row.test_highlightAlpha == PopoverColumnGrid.rowSelectionWashAlpha,
                       "selection must win when both selected and hovered")
    }

    @Test func liveWashUsesTheLiveAlphaWhenNeitherSelectedNorHovered() {
        let (row, _) = makeRow(selected: "device-1")
        #expect(row.test_highlightAlpha == PopoverColumnGrid.rowLiveWashAlpha,
                       "a sounding row paints the gold live wash")
    }

    @Test func selectionWashOutranksLiveWash() {
        let (row, _) = makeRow(selected: "device-1")
        row.test_setSelected(true)
        #expect(row.test_highlightAlpha == PopoverColumnGrid.rowSelectionWashAlpha,
                       "keyboard selection must stay visible over a live row (D3)")
    }

    // MARK: Readout colour (V7)

    /// Every destination has a live volume, so the readout never hides — what
    /// changes is whether the route is actually sounding.
    @Test func readoutIsEmberTextWhenDestinationIsNoRedirect() {
        let (row, _) = makeRowWithThreeStates(selected: "no-redirect")
        assertSameHue(row.test_readoutTextColor, Tokens.Color.emberText,
                      "an unrouted app's readout holds a stored level")
    }

    /// An explicit "Current Device" pick IS an exception route with its own
    /// stream (Bug T2), so it counts as sounding under D1's routed ∧ running
    /// predicate — the same one the fader's gold fill already uses.
    @Test func readoutIsGoldTextWhenDestinationIsCurrentDevice() {
        let (row, _) = makeRow(selected: "local")
        assertSameHue(row.test_readoutTextColor, Tokens.Color.goldText,
                      "Current Device is a live exception route")
    }

    @Test func readoutIsGoldTextWhenRedirectedAndRunning() {
        let (row, _) = makeRow(selected: "device-1")
        assertSameHue(row.test_readoutTextColor, Tokens.Color.goldText,
                      "a live redirect's readout is goldText")
    }

    /// Assert two colors resolve to the same sRGB components — `goldText` and
    /// `emberText` are computed `static var`s, so `==` never holds on them.
    private func assertSameHue(_ a: NSColor?, _ b: NSColor?, _ message: String,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else {
            Issue.record("nil color: \(message)", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(a.redComponent - b.redComponent) < 0.01, "\(message)", sourceLocation: sourceLocation)
        #expect(abs(a.greenComponent - b.greenComponent) < 0.01, "\(message)", sourceLocation: sourceLocation)
        #expect(abs(a.blueComponent - b.blueComponent) < 0.01, "\(message)", sourceLocation: sourceLocation)
    }

    // MARK: Destination subtitle microcopy (A3)

    private func makeSubtitledDestinations() -> [AppRowView.Destination] {
        [
            AppRowView.Destination(id: "no-redirect", title: "Follows main output", isLocal: true,
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

    @Test func subtitleSetsToolTipOnDestinationPopUpMenuItem() {
        let (row, _) = makeRowWithSubtitles()
        #expect(row.test_destinationPopUpMenuItem(forDestinationID: "local")?.toolTip == "Plays on this Mac")
        #expect(row.test_destinationPopUpMenuItem(forDestinationID: "no-redirect")?.toolTip == "Plays in the whole-system mix")
    }

    @Test func entryWithoutSubtitleHasNoToolTipOrAttributedTitle() {
        let (row, _) = makeRowWithSubtitles()
        let item = row.test_destinationPopUpMenuItem(forDestinationID: "device-1")
        #expect(item?.toolTip == nil)
        #expect(item?.attributedTitle == nil)
    }

    @Test func destinationPopUpMenuItemKeepsPlainTitleEvenWithSubtitle() {
        // The trailing popup mirrors its SELECTED item's attributedTitle for
        // its own collapsed display, so items feeding it must never get one —
        // otherwise a multi-line title+subtitle would corrupt the popup's own
        // (closed) label.
        let (row, _) = makeRowWithSubtitles()
        let item = row.test_destinationPopUpMenuItem(forDestinationID: "local")
        #expect(item?.attributedTitle == nil,
                     "the popup's own menu items must stay plain-titled")
        #expect(item?.title == "Current Device")
    }

    @Test func routeToContextSubmenuRendersAttributedSubtitle() {
        // The "Route to" context-menu submenu never collapses into a button,
        // so it's free to show the subtitle as a second attributed line.
        let (row, _) = makeRowWithSubtitles()
        let item = row.test_routeToMenuItem(forDestinationID: "local")
        #expect(item?.attributedTitle != nil,
                        "the context menu's Route to submenu may render an attributed subtitle")
        #expect(item?.attributedTitle?.string == "Current Device\nPlays on this Mac")
        #expect(item?.toolTip == "Plays on this Mac")
    }

    @Test func routeToContextSubmenuEntryWithoutSubtitleStaysPlain() {
        let (row, _) = makeRowWithSubtitles()
        let item = row.test_routeToMenuItem(forDestinationID: "device-1")
        #expect(item?.attributedTitle == nil)
        #expect(item?.toolTip == nil)
    }

    // MARK: Output Groups section (decision 4's reversal)

    private func makeGroupDestinations(groupEnabled: Bool = true,
                                       groupSubtitle: String? = "4 speakers")
        -> [AppRowView.Destination] {
        [
            AppRowView.Destination(id: "no-redirect", title: "Follows main output", isLocal: true,
                                   symbolName: nil, isStandalone: true),
            AppRowView.Destination(id: "local", title: "Current Device", isLocal: true,
                                   symbolName: "laptopcomputer"),
            AppRowView.Destination(id: "group-1", title: "Kitchen", isLocal: false,
                                   symbolName: "rectangle.3.group",
                                   subtitle: groupSubtitle,
                                   isGroup: true, isEnabled: groupEnabled,
                                   buttonTitle: "→ Kitchen"),
            AppRowView.Destination(id: "device-1", title: "Living Room", isLocal: false,
                                   symbolName: "airplayaudio"),
        ]
    }

    private func makeRowWithGroups(selected: String = "no-redirect",
                                   groupEnabled: Bool = true) -> (AppRowView, RecordingDelegate) {
        let row = AppRowView()
        let delegate = RecordingDelegate()
        row.delegate = delegate
        row.apply(AppRowView.Configuration(
            appID: "com.example.app", name: "Example App", icon: nil, volume: 42,
            selectedDestinationID: selected,
            destinations: makeGroupDestinations(groupEnabled: groupEnabled)))
        return (row, delegate)
    }

    @Test func groupsGetTheirOwnSectionAheadOfCurrentDeviceAndAirPlayDevices() {
        let (row, _) = makeRowWithGroups()
        let titles = row.test_menuTitles

        #expect(titles.contains("Output Groups"))
        let groupHeader = titles.firstIndex(of: "Output Groups")!
        #expect(groupHeader < titles.firstIndex(of: "Current Device")!)
        #expect(titles.firstIndex(of: "Kitchen")! == groupHeader + 1)
        #expect(titles.firstIndex(of: "Current Device")! < titles.firstIndex(of: "AirPlay Devices")!)
    }

    @Test func aGroupIsNotAlsoListedUnderAirPlayDevices() {
        let (row, _) = makeRowWithGroups()
        #expect(row.test_menuTitles.filter { $0 == "Kitchen" }.count == 1)
    }

    @Test func selectedGroupNamesItselfWithAnArrowOnTheCollapsedButton() {
        let (row, _) = makeRowWithGroups(selected: "group-1")
        #expect(row.test_collapsedDestinationTitle == "→ Kitchen")
        #expect(row.test_destinationPopUpMenuItem(forDestinationID: "group-1")?.title == "Kitchen",
                "the open menu keeps the plain name")
    }

    @Test func aDeviceSelectionLeavesTheCollapsedButtonOnTheMenuTitle() {
        let (row, _) = makeRowWithGroups(selected: "device-1")
        #expect(row.test_collapsedDestinationTitle == "Living Room")
    }

    @Test func groupSubtitleReachesTheMenuItemAsATooltip() {
        let (row, _) = makeRowWithGroups()
        #expect(row.test_destinationPopUpMenuItem(forDestinationID: "group-1")?.toolTip == "4 speakers")
    }

    /// A group with nothing to play on stays listed but can't be picked.
    @Test func anUnusableGroupIsListedButNotPickable() {
        let (row, _) = makeRowWithGroups(groupEnabled: false)
        let item = row.test_destinationPopUpMenuItem(forDestinationID: "group-1")
        #expect(item != nil, "the group must stay visible — it wasn't deleted")
        #expect(item?.isEnabled == false, "greyed out, so the click can't land")
        #expect(row.test_destinationPopUpMenuItem(forDestinationID: "device-1")?.isEnabled == true,
                "an ordinary entry stays pickable")
    }

    @Test func aGroupSelectionReachesTheDelegateAsItsOwnID() {
        let (row, delegate) = makeRowWithGroups()
        row.test_selectDestination("group-1")
        #expect(delegate.lastDestination?.destinationID == "group-1")
    }

    // MARK: Cursor (C3) — pointingHand over the selectable body dead-zone

    @Test func cursorRectsCoverBodyDeadZone() {
        let (row, _) = makeRow()
        let rects = row.test_selectableCursorRects()
        let bodyPoint = NSPoint(x: PopoverColumnGrid.leadingInset + 4, y: AppRowView.rowHeight / 2)
        #expect(rects.contains { $0.contains(bodyPoint) },
                     "the icon/name dead-zone must get the pointingHand cursor")
    }

    @Test func cursorRectsExcludeSliderColumn() {
        let (row, _) = makeRow()
        let rects = row.test_selectableCursorRects()
        let sliderColumnPoint = NSPoint(x: row.bounds.width - PopoverColumnGrid.sliderTrailing - 10,
                                        y: AppRowView.rowHeight / 2)
        #expect(!rects.contains { $0.contains(sliderColumnPoint) },
                       "the slider's own column must not get the row's pointingHand cursor")
    }

    // MARK: Leading VU meter (task T4, mirrors DeviceRowView's showsMeter)

    /// `setLevel` on a meter-enabled row reaches the meter and is readable
    /// back via `test_meterLevel` — mirrors
    /// `DeviceRowConnectionStateTests.testSetLevelOnMeterEnabledRowIsReflectedByTestMeterLevel`.
    @Test func setLevelOnMeterEnabledRowIsReflectedByTestMeterLevel() {
        let row = AppRowView(showsMeter: true)
        row.setLevel(0.42)
        #expect(row.test_meterLevel() == 0.42)
    }

    /// `showsMeter: false` (the default — every existing caller) makes
    /// `setLevel` a no-op and leaves the icon at its unchanged leading
    /// position (the reserved meter-column width the grid already accounts
    /// for via `firstElementLeading(indented:)`).
    @Test func setLevelOnNonMeterRowIsANoOp() {
        let row = AppRowView()
        row.setLevel(0.9)
        #expect(row.test_meterLevel() == 0, "a row built without a meter must never report a live level")
    }

    /// `resetLevel()` zeroes a previously pushed level back to 0.
    @Test func resetLevelZeroesAPushedLevel() {
        let row = AppRowView(showsMeter: true)
        row.setLevel(0.6)
        #expect(row.test_meterLevel() == 0.6)
        row.resetLevel()
        #expect(row.test_meterLevel() == 0, "resetLevel must zero the meter")
    }

    /// `resetLevel()` on a non-meter row stays a no-op (mirrors `setLevel`).
    @Test func resetLevelOnNonMeterRowIsANoOp() {
        let row = AppRowView()
        row.resetLevel()
        #expect(row.test_meterLevel() == 0)
    }

    // MARK: Composed VoiceOver label (A11Y-LABELS)
    //
    // Before this fix the row's accessibility label carried only name +
    // volume — a VoiceOver user could never hear WHERE an app was routed or
    // WHETHER it was actually running, even though both are visible to a
    // sighted user (the destination popup's title, the offline badge).

    @Test func accessibilityLabelIncludesRoutedDestinationWhenRedirected() throws {
        let (row, _) = makeRow(selected: "device-1")
        let label = try #require(row.test_accessibilityLabel)
        #expect(label.contains("Living Room"), "label (\"\(label)\") must name the routed destination")
    }

    @Test func accessibilityLabelIncludesCurrentDeviceWhenNotRedirected() throws {
        let (row, _) = makeRow(selected: "local")
        let label = try #require(row.test_accessibilityLabel)
        #expect(label.contains("Current Device"), "label (\"\(label)\") must name the Current Device destination")
    }

    @Test func accessibilityLabelOmitsNotRunningWhenRunning() throws {
        let row = AppRowView()
        row.apply(AppRowView.Configuration(
            appID: "com.example.app", name: "Example App", icon: nil, volume: 42,
            selectedDestinationID: "local", destinations: makeDestinations(), isRunning: true))
        let label = try #require(row.test_accessibilityLabel)
        #expect(!label.localizedCaseInsensitiveContains("not running"))
    }

    @Test func accessibilityLabelIncludesNotRunningWhenNotRunning() throws {
        let row = AppRowView()
        row.apply(AppRowView.Configuration(
            appID: "com.example.app", name: "Example App", icon: nil, volume: 42,
            selectedDestinationID: "local", destinations: makeDestinations(), isRunning: false))
        let label = try #require(row.test_accessibilityLabel)
        #expect(label.localizedCaseInsensitiveContains("not running"),
                      "label (\"\(label)\") must say the app isn't running")
    }

    @Test func accessibilityLabelStillIncludesNameAndVolume() throws {
        let (row, _) = makeRow(selected: "local")
        let label = try #require(row.test_accessibilityLabel)
        #expect(label.contains("Example App"))
        #expect(label.contains("42"))
    }

    // MARK: APP EXCEPTIONS treatment (Warm Signal S6, spec §5.1/§3.5/§2)

    private func makeThreeStateRow(selected: String, isRunning: Bool) -> AppRowView {
        let row = AppRowView()
        row.apply(AppRowView.Configuration(
            appID: "com.example.app", name: "Example App", icon: nil, volume: 42,
            selectedDestinationID: selected, destinations: makeThreeStateDestinations(),
            isRunning: isRunning))
        return row
    }

    /// The collapsed dropdown always names the destination: the bridge phrase
    /// when unrouted, the device name when routed (spec §5.1, decision 3).
    @Test func collapsedDropdownTitleIsBridgePhraseWhenUnrouted() {
        let row = makeThreeStateRow(selected: "no-redirect", isRunning: true)
        #expect(row.test_collapsedDestinationTitle == "Follows main output")
    }

    @Test func collapsedDropdownTitleIsDeviceNameWhenRouted() {
        let row = makeThreeStateRow(selected: "device-1", isRunning: true)
        #expect(row.test_collapsedDestinationTitle == "Living Room")
    }

    /// A live exception route (routed + running — the liveness proxy until the
    /// confirmed-streaming flag is plumbed in) is the section's bright anchor:
    /// name at FULL label colour (spec §2/§6.3).
    @Test func routedRunningAppNameIsFullLabelColor() {
        let row = makeThreeStateRow(selected: "device-1", isRunning: true)
        #expect(row.test_nameTextColor == .labelColor, "a live exception route's name must be the full-contrast anchor")
        #expect(row.test_idleSuffixColor == nil, "a running route never shows the idle suffix")
    }

    /// An unrouted (follows-main-output) app is not a live exception — its
    /// name sits in the cool idle voice, with no idle suffix.
    @Test func unroutedAppNameIsSecondary() {
        let row = makeThreeStateRow(selected: "no-redirect", isRunning: true)
        #expect(row.test_nameTextColor == Tokens.Color.labelCool)
        #expect(row.test_idleSuffixColor == nil)
        #expect(row.test_nameDisplayText == "Example App")
    }

    /// A routed-but-idle app (route saved, process not running) shows the
    /// spec's " (idle)" suffix (§3.5 `AppName (idle)` pattern) in the cool idle
    /// voice, the name itself cool too, and NO warning badge — idle is a calm
    /// state, not an alert.
    @Test func routedIdleAppShowsTertiaryIdleSuffixAndNoBadge() {
        let row = makeThreeStateRow(selected: "device-1", isRunning: false)
        #expect(row.test_nameDisplayText == "Example App (idle)")
        #expect(row.test_nameTextColor == Tokens.Color.labelCool)
        #expect(row.test_idleSuffixColor == Tokens.Color.labelCool2, "the (idle) suffix must render in the cool idle voice")
        #expect(!(row.test_isOfflineBadgeVisible), "the routed-idle treatment replaces the warning badge")
    }

    /// The unrouted + not-running combination keeps the old warning badge
    /// (there's no enabled-but-quiet slider to explain — it's already dimmed),
    /// and shows no idle suffix.
    @Test func unroutedNotRunningAppKeepsBadgeAndPlainName() {
        let row = makeThreeStateRow(selected: "no-redirect", isRunning: false)
        #expect(row.test_isOfflineBadgeVisible)
        #expect(row.test_nameDisplayText == "Example App")
        #expect(row.test_idleSuffixColor == nil)
    }

    /// S6 item 6: the composed VoiceOver label reads "…, follows main output"
    /// for an unrouted app — the spoken equivalent of the bridge phrase —
    /// never "routed to No Redirect".
    @Test func accessibilityLabelReadsFollowsMainOutputWhenUnrouted() {
        let row = makeThreeStateRow(selected: "no-redirect", isRunning: true)
        let label = try! #require(row.test_accessibilityLabel)
        #expect(label.contains("follows main output"), "label was \"\(label)\"")
        #expect(!(label.contains("routed to")), "an unrouted app is not 'routed to' anywhere")
    }

    /// …and "routed to <device>" when routed, with the clean name (no visual
    /// " (idle)" suffix leaking into speech) plus the discrete "not running"
    /// phrase when idle.
    @Test func accessibilityLabelReadsRoutedToDeviceAndCleanNameWhenIdle() {
        let row = makeThreeStateRow(selected: "device-1", isRunning: false)
        let label = try! #require(row.test_accessibilityLabel)
        #expect(label.contains("routed to Living Room"), "label was \"\(label)\"")
        #expect(!(label.contains("(idle)")), "the visual idle suffix must not leak into the spoken label")
        #expect(label.localizedCaseInsensitiveContains("not running"))
    }
}
