// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// Unit coverage for `IconPickerViewController` — the compact SF Symbol picker
/// presented as an anchored popover by the group editor, the creation sheet,
/// and the device detail pane (design revamp,
/// `../../Sources/AudioutWindowUI/AGENTS.md`). CONFIGURATION-ONLY: picking a
/// symbol here only ever reports a name string via `onPick`; it never touches
/// a backend or activates anything. These cases build the controller directly
/// and drive it through its `test_*` hooks — a headless run can't synthesize
/// the real grid-tap / search-typing / button-click gestures.
@Suite struct IconPickerTests {

    // MARK: Curated grid

    @Test func curatedSymbolNamesAreAllValid() {
        let picker = IconPickerViewController()
        #expect(!picker.test_curatedSymbolNames.isEmpty)
        for name in picker.test_curatedSymbolNames {
            #expect(DeviceIcon.isValid(name), "\(name) must resolve on this OS — pre-filtered at build time")
        }
    }

    @Test func pickingACuratedNameReportsItViaOnPick() throws {
        let picker = IconPickerViewController()
        let name = try #require(picker.test_curatedSymbolNames.first)
        var wasCalled = false
        var pickedName: String?
        picker.onPick = { wasCalled = true; pickedName = $0 }

        picker.test_pickCurated(name)

        #expect(wasCalled)
        #expect(pickedName == name)
    }

    @Test func pickingANameNotInTheCuratedListIsANoOp() {
        let picker = IconPickerViewController()
        var fired = false
        picker.onPick = { _ in fired = true }

        picker.test_pickCurated("definitely.not.curated.zzz")

        #expect(!fired, "only an actual curated cell tap reports a pick")
    }

    // MARK: Search field — live grid filtering

    @Test func typingASubstringNarrowsTheGridToMatchingCuratedNamesOnly() {
        let picker = IconPickerViewController()
        let fullSet = picker.test_curatedSymbolNames

        picker.test_setSearchText("pod")

        let narrowed = picker.test_curatedSymbolNames
        #expect(!narrowed.isEmpty)
        #expect(narrowed.count < fullSet.count)
        for name in narrowed {
            #expect(name.range(of: "pod", options: .caseInsensitive) != nil, "\(name) should match the substring")
        }
        for name in fullSet where name.range(of: "pod", options: .caseInsensitive) != nil {
            #expect(narrowed.contains(name), "\(name) matches but is missing from the narrowed grid")
        }
    }

    @Test func gridFilteringIsCaseInsensitive() {
        let picker = IconPickerViewController()
        picker.test_setSearchText("POD")
        #expect(!picker.test_curatedSymbolNames.isEmpty)
        #expect(picker.test_curatedSymbolNames == picker.test_curatedSymbolNames.filter {
            $0.range(of: "pod", options: .caseInsensitive) != nil
        })
    }

    @Test func clearingSearchRestoresTheFullCuratedSet() {
        let picker = IconPickerViewController()
        let fullSet = picker.test_curatedSymbolNames

        picker.test_setSearchText("pod")
        #expect(picker.test_curatedSymbolNames != fullSet)

        picker.test_setSearchText("")
        #expect(picker.test_curatedSymbolNames == fullSet)
    }

    @Test func searchWithZeroMatchesShowsAnEmptyGridWithoutCrashing() {
        let picker = IconPickerViewController()
        picker.test_setSearchText("definitely.not.curated.zzz")
        #expect(picker.test_curatedSymbolNames.isEmpty)
    }

    @Test func gridFilteringDoesNotAffectTheExactNamePreviewAndApplyPath() {
        // The narrowed grid and the exact-name preview/Apply gate are
        // independent — a substring that matches multiple curated names
        // (so it's NOT itself a valid, exact SF Symbol name) narrows the
        // grid but leaves Apply disabled, same as before this feature.
        let picker = IconPickerViewController()
        picker.test_setSearchText("pod")
        #expect(!picker.test_curatedSymbolNames.isEmpty)
        #expect(!picker.test_isApplyEnabled)
        #expect(picker.test_previewSymbolName == nil)

        // An exact valid name both narrows the grid to itself/related
        // matches AND enables the preview/Apply path.
        picker.test_setSearchText("airpods")
        #expect(picker.test_curatedSymbolNames.contains("airpods"))
        #expect(picker.test_isApplyEnabled)
        #expect(picker.test_previewSymbolName == "airpods")
    }

    // MARK: Search field validation — Apply gating + live preview

    @Test func applyIsDisabledWithEmptySearchText() {
        let picker = IconPickerViewController()
        picker.test_setSearchText("")
        #expect(!picker.test_isApplyEnabled)
        #expect(picker.test_previewSymbolName == nil)
    }

    @Test func applyIsDisabledForAnInvalidSymbolName() {
        let picker = IconPickerViewController()
        picker.test_setSearchText("definitely.not.a.symbol.zzz")
        #expect(!picker.test_isApplyEnabled)
        #expect(picker.test_previewSymbolName == nil)
    }

    @Test func applyIsEnabledWithPreviewForAValidSymbolName() {
        let picker = IconPickerViewController()
        picker.test_setSearchText("airpods")
        #expect(picker.test_isApplyEnabled)
        #expect(picker.test_previewSymbolName == "airpods")
    }

    @Test func applyIsDisabledForWhitespaceOnlyText() {
        let picker = IconPickerViewController()
        picker.test_setSearchText("   ")
        #expect(!picker.test_isApplyEnabled)
        #expect(picker.test_previewSymbolName == nil)
    }

    @Test func searchTextIsTrimmedBeforeValidating() {
        let picker = IconPickerViewController()
        picker.test_setSearchText("  airpods  ")
        #expect(picker.test_isApplyEnabled)
        #expect(picker.test_previewSymbolName == "airpods")
    }

    @Test func typingInvalidThenValidTextUpdatesStateLive() {
        let picker = IconPickerViewController()
        picker.test_setSearchText("not-a-symbol")
        #expect(!picker.test_isApplyEnabled)

        picker.test_setSearchText("airpods")
        #expect(picker.test_isApplyEnabled)
        #expect(picker.test_previewSymbolName == "airpods")

        picker.test_setSearchText("not-a-symbol-again")
        #expect(!picker.test_isApplyEnabled, "re-validated live on every keystroke, not sticky")
    }

    // MARK: Apply — reports the validated preview name

    @Test func applyReportsThePreviewedSymbolName() {
        let picker = IconPickerViewController()
        var pickedName: String?
        picker.onPick = { pickedName = $0 }
        picker.test_setSearchText("headphones")

        picker.test_apply()

        #expect(pickedName == "headphones")
    }

    @Test func applyIsANoOpWhenDisabled() {
        let picker = IconPickerViewController()
        var fired = false
        picker.onPick = { _ in fired = true }
        picker.test_setSearchText("definitely.not.a.symbol.zzz")

        picker.test_apply()

        #expect(!fired, "Apply no-ops exactly like the disabled real button")
    }

    // MARK: Use default — always available, reports nil

    @Test func useDefaultReportsNilRegardlessOfSearchState() {
        let picker = IconPickerViewController()
        var wasCalled = false
        var pickedName: String? = "unset"
        picker.onPick = { wasCalled = true; pickedName = $0 }
        picker.test_setSearchText("definitely.not.a.symbol.zzz")   // Apply disabled, doesn't matter

        picker.test_useDefault()

        #expect(wasCalled)
        #expect(pickedName == nil)
    }

    // MARK: Configuration is accepted without affecting the compact layout's behavior

    @Test @MainActor func configureDoesNotAffectApplyGatingOrCuratedList() {
        let picker = IconPickerViewController()
        // Force the view to load (a live presentation always does this before
        // showing the popover) so `applyButton.isEnabled` reflects `loadView`'s
        // initial "disabled" state rather than `NSButton`'s un-configured default.
        _ = picker.view
        let curatedBefore = picker.test_curatedSymbolNames
        picker.configure(currentSymbolName: "airpods", defaultSymbolName: "hifispeaker.fill")

        #expect(picker.test_curatedSymbolNames == curatedBefore)
        #expect(!picker.test_isApplyEnabled, "configure() alone doesn't populate the search field")
    }

    // MARK: onPick fires exactly once per use across every path

    @Test func onPickFiresExactlyOnceForACuratedTap() throws {
        let picker = IconPickerViewController()
        var count = 0
        picker.onPick = { _ in count += 1 }
        let name = try #require(picker.test_curatedSymbolNames.first)

        picker.test_pickCurated(name)

        #expect(count == 1)
    }

    @Test func onPickFiresExactlyOnceForUseDefault() {
        let picker = IconPickerViewController()
        var count = 0
        picker.onPick = { _ in count += 1 }

        picker.test_useDefault()

        #expect(count == 1)
    }

    // MARK: Grid cell VoiceOver labels (A11Y-LABELS)

    /// Every curated symbol gets a plain-language label — never the raw SF
    /// Symbol name, which VoiceOver used to read verbatim ("hifispeaker point
    /// 2 fill").
    @Test func everyCuratedSymbolHasAPlainLanguageAccessibilityLabel() {
        for name in DeviceIcon.curated where DeviceIcon.isValid(name) {
            let label = IconPickerViewController.test_accessibilityLabel(forCuratedSymbol: name)
            #expect(!label.isEmpty, "\(name) must have a non-empty label")
            #expect(label != name, "\(name)'s label must not be the raw symbol name")
            #expect(!label.contains("."), "\(name)'s label (\"\(label)\") must read as prose, not a dotted symbol name")
        }
    }

    /// A spot check on a few well-known curated names, guarding against the
    /// mapping silently regressing to the raw-name fallback.
    @Test func knownCuratedSymbolsMapToExpectedPlainLanguageLabels() {
        #expect(IconPickerViewController.test_accessibilityLabel(forCuratedSymbol: "homepod.fill") == "HomePod")
        #expect(IconPickerViewController.test_accessibilityLabel(forCuratedSymbol: "airpodspro") == "AirPods Pro")
        #expect(IconPickerViewController.test_accessibilityLabel(forCuratedSymbol: "laptopcomputer") == "Laptop")
    }

    /// An uncurated/unmapped name still produces a readable (non-crashing,
    /// non-dotted) fallback label rather than silence.
    @Test func unmappedSymbolFallsBackToAHumanizedName() {
        let label = IconPickerViewController.test_accessibilityLabel(forCuratedSymbol: "some.future-symbol")
        #expect(label == "some future symbol")
    }
}
