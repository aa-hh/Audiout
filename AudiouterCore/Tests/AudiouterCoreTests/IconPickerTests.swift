// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterSharedUI
@testable import AudiouterWindowUI

/// Unit coverage for `IconPickerViewController` — the compact SF Symbol picker
/// presented as an anchored popover by the group editor, the creation sheet,
/// and the device detail pane (design revamp,
/// `../../Sources/AudiouterWindowUI/AGENTS.md`). CONFIGURATION-ONLY: picking a
/// symbol here only ever reports a name string via `onPick`; it never touches
/// a backend or activates anything. These cases build the controller directly
/// and drive it through its `test_*` hooks — a headless run can't synthesize
/// the real grid-tap / search-typing / button-click gestures.
final class IconPickerTests: XCTestCase {

    // MARK: Curated grid

    func testCuratedSymbolNamesAreAllValid() {
        let picker = IconPickerViewController()
        XCTAssertFalse(picker.test_curatedSymbolNames.isEmpty)
        for name in picker.test_curatedSymbolNames {
            XCTAssertTrue(DeviceIcon.isValid(name), "\(name) must resolve on this OS — pre-filtered at build time")
        }
    }

    func testPickingACuratedNameReportsItViaOnPick() {
        let picker = IconPickerViewController()
        let name = try! XCTUnwrap(picker.test_curatedSymbolNames.first)
        var wasCalled = false
        var pickedName: String?
        picker.onPick = { wasCalled = true; pickedName = $0 }

        picker.test_pickCurated(name)

        XCTAssertTrue(wasCalled)
        XCTAssertEqual(pickedName, name)
    }

    func testPickingANameNotInTheCuratedListIsANoOp() {
        let picker = IconPickerViewController()
        var fired = false
        picker.onPick = { _ in fired = true }

        picker.test_pickCurated("definitely.not.curated.zzz")

        XCTAssertFalse(fired, "only an actual curated cell tap reports a pick")
    }

    // MARK: Search field — live grid filtering

    func testTypingASubstringNarrowsTheGridToMatchingCuratedNamesOnly() {
        let picker = IconPickerViewController()
        let fullSet = picker.test_curatedSymbolNames

        picker.test_setSearchText("pod")

        let narrowed = picker.test_curatedSymbolNames
        XCTAssertFalse(narrowed.isEmpty)
        XCTAssertLessThan(narrowed.count, fullSet.count)
        for name in narrowed {
            XCTAssertTrue(name.range(of: "pod", options: .caseInsensitive) != nil, "\(name) should match the substring")
        }
        for name in fullSet where name.range(of: "pod", options: .caseInsensitive) != nil {
            XCTAssertTrue(narrowed.contains(name), "\(name) matches but is missing from the narrowed grid")
        }
    }

    func testGridFilteringIsCaseInsensitive() {
        let picker = IconPickerViewController()
        picker.test_setSearchText("POD")
        XCTAssertFalse(picker.test_curatedSymbolNames.isEmpty)
        XCTAssertEqual(picker.test_curatedSymbolNames, picker.test_curatedSymbolNames.filter {
            $0.range(of: "pod", options: .caseInsensitive) != nil
        })
    }

    func testClearingSearchRestoresTheFullCuratedSet() {
        let picker = IconPickerViewController()
        let fullSet = picker.test_curatedSymbolNames

        picker.test_setSearchText("pod")
        XCTAssertNotEqual(picker.test_curatedSymbolNames, fullSet)

        picker.test_setSearchText("")
        XCTAssertEqual(picker.test_curatedSymbolNames, fullSet)
    }

    func testSearchWithZeroMatchesShowsAnEmptyGridWithoutCrashing() {
        let picker = IconPickerViewController()
        picker.test_setSearchText("definitely.not.curated.zzz")
        XCTAssertTrue(picker.test_curatedSymbolNames.isEmpty)
    }

    func testGridFilteringDoesNotAffectTheExactNamePreviewAndApplyPath() {
        // The narrowed grid and the exact-name preview/Apply gate are
        // independent — a substring that matches multiple curated names
        // (so it's NOT itself a valid, exact SF Symbol name) narrows the
        // grid but leaves Apply disabled, same as before this feature.
        let picker = IconPickerViewController()
        picker.test_setSearchText("pod")
        XCTAssertFalse(picker.test_curatedSymbolNames.isEmpty)
        XCTAssertFalse(picker.test_isApplyEnabled)
        XCTAssertNil(picker.test_previewSymbolName)

        // An exact valid name both narrows the grid to itself/related
        // matches AND enables the preview/Apply path.
        picker.test_setSearchText("airpods")
        XCTAssertTrue(picker.test_curatedSymbolNames.contains("airpods"))
        XCTAssertTrue(picker.test_isApplyEnabled)
        XCTAssertEqual(picker.test_previewSymbolName, "airpods")
    }

    // MARK: Search field validation — Apply gating + live preview

    func testApplyIsDisabledWithEmptySearchText() {
        let picker = IconPickerViewController()
        picker.test_setSearchText("")
        XCTAssertFalse(picker.test_isApplyEnabled)
        XCTAssertNil(picker.test_previewSymbolName)
    }

    func testApplyIsDisabledForAnInvalidSymbolName() {
        let picker = IconPickerViewController()
        picker.test_setSearchText("definitely.not.a.symbol.zzz")
        XCTAssertFalse(picker.test_isApplyEnabled)
        XCTAssertNil(picker.test_previewSymbolName)
    }

    func testApplyIsEnabledWithPreviewForAValidSymbolName() {
        let picker = IconPickerViewController()
        picker.test_setSearchText("airpods")
        XCTAssertTrue(picker.test_isApplyEnabled)
        XCTAssertEqual(picker.test_previewSymbolName, "airpods")
    }

    func testApplyIsDisabledForWhitespaceOnlyText() {
        let picker = IconPickerViewController()
        picker.test_setSearchText("   ")
        XCTAssertFalse(picker.test_isApplyEnabled)
        XCTAssertNil(picker.test_previewSymbolName)
    }

    func testSearchTextIsTrimmedBeforeValidating() {
        let picker = IconPickerViewController()
        picker.test_setSearchText("  airpods  ")
        XCTAssertTrue(picker.test_isApplyEnabled)
        XCTAssertEqual(picker.test_previewSymbolName, "airpods")
    }

    func testTypingInvalidThenValidTextUpdatesStateLive() {
        let picker = IconPickerViewController()
        picker.test_setSearchText("not-a-symbol")
        XCTAssertFalse(picker.test_isApplyEnabled)

        picker.test_setSearchText("airpods")
        XCTAssertTrue(picker.test_isApplyEnabled)
        XCTAssertEqual(picker.test_previewSymbolName, "airpods")

        picker.test_setSearchText("not-a-symbol-again")
        XCTAssertFalse(picker.test_isApplyEnabled, "re-validated live on every keystroke, not sticky")
    }

    // MARK: Apply — reports the validated preview name

    func testApplyReportsThePreviewedSymbolName() {
        let picker = IconPickerViewController()
        var pickedName: String?
        picker.onPick = { pickedName = $0 }
        picker.test_setSearchText("headphones")

        picker.test_apply()

        XCTAssertEqual(pickedName, "headphones")
    }

    func testApplyIsANoOpWhenDisabled() {
        let picker = IconPickerViewController()
        var fired = false
        picker.onPick = { _ in fired = true }
        picker.test_setSearchText("definitely.not.a.symbol.zzz")

        picker.test_apply()

        XCTAssertFalse(fired, "Apply no-ops exactly like the disabled real button")
    }

    // MARK: Use default — always available, reports nil

    func testUseDefaultReportsNilRegardlessOfSearchState() {
        let picker = IconPickerViewController()
        var wasCalled = false
        var pickedName: String? = "unset"
        picker.onPick = { wasCalled = true; pickedName = $0 }
        picker.test_setSearchText("definitely.not.a.symbol.zzz")   // Apply disabled, doesn't matter

        picker.test_useDefault()

        XCTAssertTrue(wasCalled)
        XCTAssertNil(pickedName)
    }

    // MARK: Configuration is accepted without affecting the compact layout's behavior

    func testConfigureDoesNotAffectApplyGatingOrCuratedList() {
        let picker = IconPickerViewController()
        // Force the view to load (a live presentation always does this before
        // showing the popover) so `applyButton.isEnabled` reflects `loadView`'s
        // initial "disabled" state rather than `NSButton`'s un-configured default.
        _ = picker.view
        let curatedBefore = picker.test_curatedSymbolNames
        picker.configure(currentSymbolName: "airpods", defaultSymbolName: "hifispeaker.fill")

        XCTAssertEqual(picker.test_curatedSymbolNames, curatedBefore)
        XCTAssertFalse(picker.test_isApplyEnabled, "configure() alone doesn't populate the search field")
    }

    // MARK: onPick fires exactly once per use across every path

    func testOnPickFiresExactlyOnceForACuratedTap() {
        let picker = IconPickerViewController()
        var count = 0
        picker.onPick = { _ in count += 1 }
        let name = try! XCTUnwrap(picker.test_curatedSymbolNames.first)

        picker.test_pickCurated(name)

        XCTAssertEqual(count, 1)
    }

    func testOnPickFiresExactlyOnceForUseDefault() {
        let picker = IconPickerViewController()
        var count = 0
        picker.onPick = { _ in count += 1 }

        picker.test_useDefault()

        XCTAssertEqual(count, 1)
    }
}
