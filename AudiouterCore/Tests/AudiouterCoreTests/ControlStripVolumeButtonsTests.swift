// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// §7b of `docs/plans/PLAN-VOLUME-KEY-INTERCEPTION.md` — borrowing the Touch Bar
/// settings the app's own volume control needs, and giving them back.
/// Everything here runs against fakes; **nothing in this file may touch the real
/// `com.apple.controlstrip` / `com.apple.touchbar.agent` domains**, which are
/// live user settings.
@Suite struct ControlStripVolumeButtonsTests {

    private let slider = ControlStripLayout.sliderItem
    private let buttons = ControlStripLayout.buttonGroupItem
    private let mute = ControlStripLayout.muteItem
    private let appMode = ControlStripLayout.appControlsMode
    private let expandedMode = "fullControlStrip"

    // MARK: - The layout transform

    @Test func removesEveryFlavourOfAppleAudioControl() {
        let before = ["com.apple.system.brightness", slider, buttons, mute,
                      "com.apple.system.volume-up", "com.apple.system.volume-down",
                      "com.apple.system.siri"]
        #expect(ControlStripLayout.removingAudioItems(before)
                == ["com.apple.system.brightness", "com.apple.system.siri"])
    }

    /// A removal, never a rewrite — identifiers from a macOS we know nothing
    /// about must survive untouched, in their original positions.
    @Test func preservesUnknownIdentifiersAndTheirOrder() {
        let before = ["com.apple.system.future-widget", slider,
                      "NSTouchBarItemIdentifierFlexibleSpace", "com.apple.system.brightness"]
        #expect(ControlStripLayout.removingAudioItems(before)
                == ["com.apple.system.future-widget",
                    "NSTouchBarItemIdentifierFlexibleSpace", "com.apple.system.brightness"])
    }

    @Test func doesNothingWhenThereIsNoAppleAudioControl() {
        #expect(ControlStripLayout.removingAudioItems(
            ["com.apple.system.brightness", "com.apple.system.siri"]) == nil)
        #expect(ControlStripLayout.removingAudioItems([]) == nil)
    }

    // MARK: - Restore arbitration

    @Test func restoresTheOriginalWhenOurChangeIsStillInPlace() {
        #expect(ControlStripLayout.restoring(
            current: ["a"], weWrote: ["a"], original: ["a", slider]) == ["a", slider])
        #expect(ControlStripLayout.restoring(
            current: appMode, weWrote: appMode, original: expandedMode) == expandedMode)
    }

    /// The user changed that setting themselves while our change was in force.
    /// Theirs is the deliberate one — losing ours is the right trade.
    @Test func declinesToRestoreOverAUserEdit() {
        #expect(ControlStripLayout.restoring(
            current: ["a", "b"], weWrote: ["a"], original: ["a", slider]) == nil)
        #expect(ControlStripLayout.restoring(
            current: "someOtherMode", weWrote: appMode, original: expandedMode) == nil)
    }

    /// A `nil` original mode is a real state — the user had never set one — and
    /// restoring must be able to put `nil` back rather than treating it as
    /// "nothing to do".
    @Test func restoresANilOriginalMode() {
        let restored: String?? = ControlStripLayout.restoring(
            current: appMode, weWrote: appMode, original: String?.none)
        #expect(restored == .some(.none))
    }

    // MARK: - Borrow and hand back

    @Test func borrowsOnGainingOwnershipAndRestoresOnLosingIt() {
        let control = FakeControlStrip(
            layouts: ["MiniCustomized": ["a", slider, "b"]], mode: expandedMode)
        let store = FakeSwapStore()
        let subject = ControlStripVolumeButtons(control: control, store: store)

        subject.apply(weOwnVolume: true)
        #expect(control.layouts["MiniCustomized"] == ["a", "b"], "Apple's dead audio goes")
        #expect(control.mode == appMode, "only App-Controls mode renders a tray item")
        #expect(store.controlStripHoldsChanges)

        subject.apply(weOwnVolume: false)
        #expect(control.layouts["MiniCustomized"] == ["a", slider, "b"])
        #expect(control.mode == expandedMode)
        #expect(!store.controlStripHoldsChanges)
    }

    /// Already in App-Controls mode: the layout still needs cleaning, but the
    /// mode must be left alone so restore doesn't later "put back" a mode the
    /// user never left.
    @Test func leavesAnAlreadyCorrectModeUntouched() {
        let control = FakeControlStrip(layouts: ["MiniCustomized": [slider]], mode: appMode)
        let store = FakeSwapStore()
        let subject = ControlStripVolumeButtons(control: control, store: store)

        subject.apply(weOwnVolume: true)
        #expect(control.modeWrites == 0)
        #expect(store.controlStripWrittenMode == nil)

        subject.apply(weOwnVolume: false)
        #expect(control.mode == appMode)
    }

    /// The mode alone is reason enough to act: an expanded-strip user with no
    /// stored layout still needs the mode switched or our control never renders.
    @Test func borrowsForTheModeEvenWithNoLayoutToClean() {
        let control = FakeControlStrip(layouts: [:], mode: expandedMode)
        let store = FakeSwapStore()
        ControlStripVolumeButtons(control: control, store: store).apply(weOwnVolume: true)

        #expect(control.mode == appMode)
        #expect(store.controlStripHoldsChanges)
    }

    @Test func doesNothingAtAllWhenNothingNeedsChanging() {
        let control = FakeControlStrip(layouts: ["MiniCustomized": ["a"]], mode: appMode)
        let store = FakeSwapStore()
        ControlStripVolumeButtons(control: control, store: store).apply(weOwnVolume: true)

        #expect(control.reloadCount == 0)
        #expect(!store.controlStripHoldsChanges, "nothing borrowed ⇒ nothing to undo")
    }

    @Test func doesNothingWithoutATouchBar() {
        let control = FakeControlStrip(
            layouts: ["MiniCustomized": [slider]], mode: expandedMode, hasTouchBar: false)
        ControlStripVolumeButtons(control: control, store: FakeSwapStore())
            .apply(weOwnVolume: true)

        #expect(control.layouts["MiniCustomized"] == [slider])
        #expect(control.mode == expandedMode)
    }

    /// Re-entering a state we already hold must not overwrite the saved original
    /// with our own value — that would make the original unrecoverable.
    @Test func borrowingTwiceKeepsTheFirstOriginal() {
        let control = FakeControlStrip(layouts: ["MiniCustomized": [slider]], mode: expandedMode)
        let store = FakeSwapStore()
        let subject = ControlStripVolumeButtons(control: control, store: store)

        subject.apply(weOwnVolume: true)
        subject.apply(weOwnVolume: true)

        #expect(store.controlStripOriginalLayouts["MiniCustomized"] == [slider])
        #expect(store.controlStripOriginalMode == expandedMode)
        #expect(control.reloadCount == 1, "the second apply is a no-op, not a second reload")
    }

    // MARK: - Reporting the reload

    /// Reloading ControlStrip destroys every tray registration, including the
    /// caller's. It has to learn that it happened, or our Touch Bar control
    /// appears once and never comes back after an output change — the live bug
    /// this return value exists to fix.
    @Test func reportsWhetherControlStripWasReloaded() {
        let borrowing = FakeControlStrip(
            layouts: ["MiniCustomized": [slider]], mode: expandedMode)
        let subject = ControlStripVolumeButtons(control: borrowing, store: FakeSwapStore())
        #expect(subject.apply(weOwnVolume: true), "borrowing reloads ⇒ caller must re-assert")

        let nothingToDo = FakeControlStrip(layouts: ["MiniCustomized": ["a"]], mode: appMode)
        #expect(!ControlStripVolumeButtons(control: nothingToDo, store: FakeSwapStore())
            .apply(weOwnVolume: true), "no change ⇒ no reload ⇒ nothing to re-assert")
    }

    @Test func restoringReportsItsReloadToo() {
        let control = FakeControlStrip(layouts: ["MiniCustomized": [slider]], mode: expandedMode)
        let store = FakeSwapStore()
        let subject = ControlStripVolumeButtons(control: control, store: store)

        subject.apply(weOwnVolume: true)
        #expect(subject.apply(weOwnVolume: false))
        #expect(!subject.apply(weOwnVolume: false), "nothing held ⇒ no second reload")
    }

    // MARK: - Crash recovery

    /// A crash between borrowing and restoring leaves the latch set. The next
    /// launch must put the user back before anything else — they are otherwise
    /// stranded in a Touch Bar mode they never chose, with nothing explaining it.
    @Test func restoresSettingsStrandedByAPreviousRun() {
        let store = FakeSwapStore()
        store.controlStripOriginalLayouts = ["MiniCustomized": [slider]]
        store.controlStripWrittenLayouts = ["MiniCustomized": []]
        store.controlStripOriginalMode = expandedMode
        store.controlStripWrittenMode = appMode
        store.controlStripHoldsChanges = true
        let control = FakeControlStrip(layouts: ["MiniCustomized": []], mode: appMode)

        ControlStripVolumeButtons(control: control, store: store).restoreIfStale()

        #expect(control.layouts["MiniCustomized"] == [slider])
        #expect(control.mode == expandedMode)
        #expect(!store.controlStripHoldsChanges)
    }

    @Test func staleRestoreIsANoOpWhenWeHoldNothing() {
        let control = FakeControlStrip(layouts: ["MiniCustomized": [slider]], mode: expandedMode)
        ControlStripVolumeButtons(control: control, store: FakeSwapStore()).restoreIfStale()
        #expect(control.reloadCount == 0)
    }
}

// MARK: - Fakes

/// In-memory ``ControlStripControlling``. Never reads or writes a real domain.
private final class FakeControlStrip: ControlStripControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _layouts: [String: [String]]
    private var _mode: String?
    private var _reloadCount = 0
    private var _modeWrites = 0
    let hasTouchBar: Bool

    init(layouts: [String: [String]], mode: String?, hasTouchBar: Bool = true) {
        _layouts = layouts
        _mode = mode
        self.hasTouchBar = hasTouchBar
    }

    var layouts: [String: [String]] { lock.withLock { _layouts } }
    var mode: String? { lock.withLock { _mode } }
    var reloadCount: Int { lock.withLock { _reloadCount } }
    var modeWrites: Int { lock.withLock { _modeWrites } }

    func layout(forKey key: String) -> [String]? { lock.withLock { _layouts[key] } }
    func setLayout(_ items: [String]?, forKey key: String) {
        lock.withLock { _layouts[key] = items }
    }
    var presentationMode: String? { lock.withLock { _mode } }
    func setPresentationMode(_ mode: String?) {
        lock.withLock { _mode = mode; _modeWrites += 1 }
    }
    func reload() { lock.withLock { _reloadCount += 1 } }
}

private final class FakeSwapStore: ControlStripSwapStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var originals: [String: [String]] = [:]
    private var written: [String: [String]] = [:]
    private var originalMode: String?
    private var writtenMode: String?
    private var holds = false

    var controlStripOriginalLayouts: [String: [String]] {
        get { lock.withLock { originals } }
        set { lock.withLock { originals = newValue } }
    }
    var controlStripWrittenLayouts: [String: [String]] {
        get { lock.withLock { written } }
        set { lock.withLock { written = newValue } }
    }
    var controlStripOriginalMode: String? {
        get { lock.withLock { originalMode } }
        set { lock.withLock { originalMode = newValue } }
    }
    var controlStripWrittenMode: String? {
        get { lock.withLock { writtenMode } }
        set { lock.withLock { writtenMode = newValue } }
    }
    var controlStripHoldsChanges: Bool {
        get { lock.withLock { holds } }
        set { lock.withLock { holds = newValue } }
    }
}
