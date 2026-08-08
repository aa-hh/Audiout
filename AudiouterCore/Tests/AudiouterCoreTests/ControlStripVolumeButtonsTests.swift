// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// W5 of `docs/plans/PLAN-VOLUME-KEY-INTERCEPTION.md` — the Touch Bar Control
/// Strip swap. Everything here runs against fakes; **nothing in this file may
/// touch the real `com.apple.controlstrip` domain**, which is a live user setting.
@Suite struct ControlStripVolumeButtonsTests {

    private let slider = ControlStripLayout.sliderItem
    private let buttons = ControlStripLayout.buttonGroupItem

    // MARK: - The transform

    @Test func swapsTheSliderForTheButtonGroupInPlace() {
        let before = ["com.apple.system.brightness", slider, "com.apple.system.mute"]
        #expect(ControlStripLayout.swappingSliderForButtons(before)
                == ["com.apple.system.brightness", buttons, "com.apple.system.mute"])
    }

    /// The swap is a substitution, never a rewrite — identifiers from a macOS we
    /// know nothing about have to survive untouched, in their original positions.
    @Test func preservesUnknownIdentifiersAndTheirOrder() {
        let before = ["com.apple.system.future-widget", slider, "NSTouchBarItemIdentifierFlexibleSpace"]
        #expect(ControlStripLayout.swappingSliderForButtons(before)
                == ["com.apple.system.future-widget", buttons, "NSTouchBarItemIdentifierFlexibleSpace"])
    }

    @Test func doesNothingWhenTheUserIsAlreadyOnButtons() {
        #expect(ControlStripLayout.swappingSliderForButtons(["com.apple.system.brightness", buttons]) == nil)
        #expect(ControlStripLayout.swappingSliderForButtons(["com.apple.system.volume-up"]) == nil)
        #expect(ControlStripLayout.swappingSliderForButtons(["com.apple.system.volume-down"]) == nil)
    }

    /// No volume item at all means they removed it deliberately. Adding one back
    /// would be redesigning their Touch Bar, not swapping one control for another.
    @Test func doesNothingWhenThereIsNoVolumeItemToSwap() {
        #expect(ControlStripLayout.swappingSliderForButtons(
            ["com.apple.system.brightness", "com.apple.system.siri"]) == nil)
        #expect(ControlStripLayout.swappingSliderForButtons([]) == nil)
    }

    // MARK: - Restore

    @Test func restoresTheOriginalWhenOurSwapIsStillInPlace() {
        #expect(ControlStripLayout.restoring(
            current: [buttons], weWrote: [buttons], original: [slider]) == [slider])
    }

    /// The user re-customized while our swap was in force. Their choice is the
    /// deliberate one — losing our swap is the right trade, clobbering theirs isn't.
    @Test func declinesToRestoreOverAUserEdit() {
        #expect(ControlStripLayout.restoring(
            current: [buttons, "com.apple.system.siri"],
            weWrote: [buttons],
            original: [slider]) == nil)
    }

    // MARK: - Applying and undoing

    @Test func swapsOnGainingOwnershipAndRestoresOnLosingIt() {
        let control = FakeControlStrip(layouts: ["MiniCustomized": ["a", slider, "b"]])
        let store = FakeSwapStore()
        let subject = ControlStripVolumeButtons(control: control, store: store)

        subject.apply(weOwnVolume: true)
        #expect(control.layouts["MiniCustomized"] == ["a", buttons, "b"])
        #expect(control.reloadCount == 1)
        #expect(store.controlStripOriginalLayouts["MiniCustomized"] == ["a", slider, "b"])

        subject.apply(weOwnVolume: false)
        #expect(control.layouts["MiniCustomized"] == ["a", slider, "b"],
                "losing ownership must hand the user's own layout straight back")
        #expect(store.controlStripOriginalLayouts.isEmpty)
    }

    @Test func swapsBothLayoutsIndependently() {
        let control = FakeControlStrip(layouts: [
            "MiniCustomized": [slider],
            "FullCustomized": ["x", slider],
        ])
        let subject = ControlStripVolumeButtons(control: control, store: FakeSwapStore())

        subject.apply(weOwnVolume: true)
        #expect(control.layouts["MiniCustomized"] == [buttons])
        #expect(control.layouts["FullCustomized"] == ["x", buttons])
    }

    /// A user who never opened Customize Control Strip has no stored layout, and
    /// the factory default lives in ControlStrip's own code where nothing can read
    /// it. Leaving them alone is the documented ceiling — the alternative is
    /// putting a Touch Bar on their Mac that we invented.
    @Test func leavesAnUncustomizedControlStripAlone() {
        let control = FakeControlStrip(layouts: [:])
        let store = FakeSwapStore()
        ControlStripVolumeButtons(control: control, store: store).apply(weOwnVolume: true)

        #expect(control.layouts.isEmpty)
        #expect(control.reloadCount == 0)
        #expect(store.controlStripOriginalLayouts.isEmpty, "nothing swapped ⇒ nothing to undo")
    }

    @Test func doesNothingWithoutATouchBar() {
        let control = FakeControlStrip(layouts: ["MiniCustomized": [slider]], hasTouchBar: false)
        ControlStripVolumeButtons(control: control, store: FakeSwapStore()).apply(weOwnVolume: true)

        #expect(control.layouts["MiniCustomized"] == [slider])
        #expect(control.reloadCount == 0)
    }

    /// Re-entering a state we already hold must not overwrite the saved original
    /// with our own swapped value — that would make the original unrecoverable.
    @Test func swappingTwiceKeepsTheFirstOriginal() {
        let control = FakeControlStrip(layouts: ["MiniCustomized": [slider]])
        let store = FakeSwapStore()
        let subject = ControlStripVolumeButtons(control: control, store: store)

        subject.apply(weOwnVolume: true)
        subject.apply(weOwnVolume: true)

        #expect(store.controlStripOriginalLayouts["MiniCustomized"] == [slider])
        #expect(control.reloadCount == 1, "the second apply is a no-op, not a second ControlStrip kill")
    }

    // MARK: - Crash recovery

    /// A crash between writing the layout and restoring it leaves the marker on
    /// disk. The next launch must put the user back before anything else happens —
    /// otherwise they are stranded on a Touch Bar they never chose.
    @Test func restoresAStaleSwapLeftByAPreviousRun() {
        let store = FakeSwapStore()
        store.controlStripOriginalLayouts = ["MiniCustomized": [slider]]
        store.controlStripWrittenLayouts = ["MiniCustomized": [buttons]]
        let control = FakeControlStrip(layouts: ["MiniCustomized": [buttons]])

        ControlStripVolumeButtons(control: control, store: store).restoreIfStale()

        #expect(control.layouts["MiniCustomized"] == [slider])
        #expect(store.controlStripOriginalLayouts.isEmpty)
    }

    @Test func staleRestoreIsANoOpWhenWeHoldNoSwap() {
        let control = FakeControlStrip(layouts: ["MiniCustomized": [slider]])
        ControlStripVolumeButtons(control: control, store: FakeSwapStore()).restoreIfStale()
        #expect(control.reloadCount == 0)
    }
}

// MARK: - Fakes

/// In-memory ``ControlStripControlling``. Never reads or writes the real
/// preference domain.
private final class FakeControlStrip: ControlStripControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _layouts: [String: [String]]
    private var _reloadCount = 0
    let hasTouchBar: Bool

    init(layouts: [String: [String]], hasTouchBar: Bool = true) {
        _layouts = layouts
        self.hasTouchBar = hasTouchBar
    }

    var layouts: [String: [String]] { lock.withLock { _layouts } }
    var reloadCount: Int { lock.withLock { _reloadCount } }

    func layout(forKey key: String) -> [String]? { lock.withLock { _layouts[key] } }
    func setLayout(_ items: [String]?, forKey key: String) {
        lock.withLock { _layouts[key] = items }
    }
    func reload() { lock.withLock { _reloadCount += 1 } }
}

private final class FakeSwapStore: ControlStripSwapStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var originals: [String: [String]] = [:]
    private var written: [String: [String]] = [:]

    var controlStripOriginalLayouts: [String: [String]] {
        get { lock.withLock { originals } }
        set { lock.withLock { originals = newValue } }
    }
    var controlStripWrittenLayouts: [String: [String]] {
        get { lock.withLock { written } }
        set { lock.withLock { written = newValue } }
    }
}
