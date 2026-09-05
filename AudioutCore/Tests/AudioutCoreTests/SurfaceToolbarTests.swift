// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
import AudioutSharedUI
@testable import AudioutPopoverUI

/// Coverage for `SurfaceToolbarController` — the one-surface header as a real
/// window-attached `NSToolbar` (live-review D1, which retired the custom
/// `PopoverHeaderView` strip and its three-tier material machinery; the
/// system toolbar owns materials and Reduce Transparency now, so no tier
/// seams remain to test). Headless: items are materialized by attaching the
/// toolbar to a never-shown window.
///
/// Since 2026-09-04 the items draw their own seat (`SurfaceToolbarSeat`), so
/// the drawing tests below RENDER a seat and sample its pixels. The version
/// they replace asserted the intent instead — it reported green while macOS
/// 14–25 drew no selection at all, because every cue sat inside
/// `if #available(macOS 26.0, *)`.
@MainActor
@Suite struct SurfaceToolbarTests {

    /// A controller with its toolbar attached (attachment is what makes
    /// AppKit materialize the delegate's items), on a window that never
    /// orders in.
    private func makeAttached() -> (SurfaceToolbarController, NSWindow) {
        let controller = SurfaceToolbarController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SurfaceLayout.width, height: 400),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        controller.attach(to: window)
        return (controller, window)
    }

    // MARK: Items present and ordered

    @Test func attachingMaterializesTheItemsInOrder() {
        let (controller, window) = makeAttached()
        #expect(controller.test_itemIdentifiers == [
            SurfaceToolbarController.tabsItemIdentifier,
            .flexibleSpace,
            SurfaceToolbarController.pinItemIdentifier,
        ], "ONE item carries all three tabs, and Pin trails it outside that capsule")
        #expect(window.toolbar === controller.toolbar)
        #expect(window.toolbarStyle == .unified, "D1: unified — the toolbar IS the one header strip")
    }

    @Test func tabsCarryAllThreeScreensWithResolvedGlyphs() {
        let (controller, _) = makeAttached()
        #expect(controller.test_tabAccessibilityLabels == ["Mixer", "Groups", "Settings"])
        #expect(controller.test_allTabImagesResolved,
                "every tab resolved a system SF Symbol")
    }

    /// The Mixer tab must not draw the equalizer's glyph (Alec, 2026-09-04).
    /// `slider.horizontal.3` is what a device row's equalizer door draws, and
    /// an equalizer is what sliders mean — so the equalizer keeps them and the
    /// tab takes another symbol. Every tab glyph is also distinct from every
    /// other, and each resolves.
    ///
    /// Resolving HERE only proves this machine has the symbol; the 14.2 floor
    /// was checked against CoreGlyphs' `name_availability.plist` by hand
    /// (`waveform` and `waveform.path` are macOS 10.15, `waveform.circle`
    /// 10.15, `hifispeaker.2` and `gearshape` 11.0). The runtime check below
    /// still catches a typo, which is the failure that actually happens.
    @Test func noTabDrawsTheEqualizersGlyphAndNoTwoTabsShareOne() {
        let names = SurfaceScreen.allCases.map(\.symbolName)
        #expect(!names.contains("slider.horizontal.3"),
                "the sliders glyph belongs to the equalizer door, not to a screen tab")
        #expect(Set(names).count == names.count, "no two tabs draw the same glyph")
        for name in names + SurfaceScreen.allCases.flatMap(\.fallbackSymbolNames) {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                    Comment(rawValue: "\(name) must resolve — the package deploys to macOS 14.2"))
        }
    }

    /// EXACTLY ONE name is on the strip, and it is the current screen's (Alec,
    /// 2026-09-04: "if I were to click on groups or speakers, then it would
    /// expand out to show the name"). The two tabs you are not on stay
    /// icon-only, which is what keeps the strip's width independent of how
    /// many words three languages need.
    ///
    /// Measured from what the seats actually let through, not from what they
    /// carry: a tab too narrow to show its name reads as empty here.
    @Test func onlyTheCurrentTabDrawsItsName() {
        let (controller, window) = makeAttached()
        for selected in SurfaceScreen.allCases {
            controller.setSelectedScreen(selected)
            FoldAnimator.shared.test_settleNow()
            window.layoutIfNeeded()
            let expected = SurfaceScreen.allCases.map { $0 == selected ? $0.label : "" }
            #expect(controller.test_tabDrawnNames == expected,
                    Comment(rawValue: "with \(selected.label) showing, the strip draws \(expected)"))
        }
        #expect(controller.test_tabAccessibilityLabels == SurfaceScreen.allCases.map(\.label),
                "all three names still reach VoiceOver, expanded or not")
        #expect(controller.test_tabToolTips == SurfaceScreen.allCases.map { "\($0.label) (⌘\($0.keyEquivalent))" },
                "and the tooltip still spells each one out with its shortcut")
        #expect(controller.test_allTabImagesResolved,
                "the glyph is what an idle tab shows")
        #expect(controller.toolbar.displayMode == .iconOnly)
    }

    /// The expanded tab really is wider on screen than a collapsed one, and
    /// only that one is. Real laid-out frames, not the constraint the reveal
    /// writes into: what fails review is a seat that did not grow.
    @Test func theCurrentTabIsDrawnWiderThanTheOthers() {
        let (controller, window) = makeAttached()
        for selected in SurfaceScreen.allCases {
            controller.setSelectedScreen(selected)
            FoldAnimator.shared.test_settleNow()
            window.layoutIfNeeded()
            guard let current = controller.test_tabButton(selected) else {
                Issue.record("\(selected.label) has no seat button")
                return
            }
            #expect(current.frame.width > SurfaceToolbarSeat.size.width,
                    Comment(rawValue: "\(selected.label) opened — it is \(current.frame.width) pt against a collapsed \(SurfaceToolbarSeat.size.width)"))
            #expect(current.frame.width == SurfaceToolbarSeat.tabWidth(nameWidth: current.nameWidth),
                    Comment(rawValue: "and opened by exactly its own name's width"))
            for other in SurfaceScreen.allCases where other != selected {
                guard let tab = controller.test_tabButton(other) else { continue }
                #expect(tab.frame.width == SurfaceToolbarSeat.size.width,
                        Comment(rawValue: "\(other.label) stayed collapsed at \(tab.frame.width) pt"))
            }
        }
    }

    /// Both items ask to stay visible, Pin never changes size, and the capsule
    /// is exactly the three tabs plus its padding — one of them open.
    @Test func everyItemAsksToStayOutOfTheOverflowMenu() {
        let (controller, _) = makeAttached()
        for item in controller.toolbar.items where item.view != nil {
            #expect(item.visibilityPriority == .high,
                    Comment(rawValue: "\(item.itemIdentifier.rawValue) must not be sweepable into the chevron"))
        }
        #expect(controller.test_pinItem?.visibilityPriority == .high,
                "Pin must not be sweepable into the chevron either")
        guard let mixer = controller.test_tabButton(.mixer) else {
            Issue.record("Mixer has no seat button")
            return
        }
        #expect(controller.test_capsuleFittingWidth
                    == SurfaceToolbarSeat.capsuleWidth(nameWidth: mixer.nameWidth),
                "the capsule is two collapsed tabs, the open one, and its padding")
        #expect(SurfaceToolbarSeat.capsuleSize.width
                    == SurfaceToolbarSeat.size.width * 3 + SurfaceToolbarSeat.capsulePadding * 2,
                "and with every tab collapsed it is exactly three of them plus that padding")
        #expect(SurfaceToolbarSeat.capsuleCornerRadius == SurfaceToolbarSeat.capsuleSize.height / 2,
                "half the height, so the capsule reads as a pill and not a rounded box")
    }

    /// The guard that let names back onto the strip at all. Names were removed
    /// on 2026-09-03 because three translated labels widened it until AppKit
    /// swept the tabs into the overflow menu, and primary navigation cannot
    /// live behind a chevron. Two facts make that impossible now rather than
    /// unlikely: only ONE tab is ever open, and its name is clamped.
    ///
    /// Asserted with a name no translator could produce, so the result does not
    /// depend on how long "Einstellungen" happens to be.
    @Test func theStripCannotOutgrowTheSurfaceInAnyLanguage() {
        #expect(SurfaceToolbarSeat.widestCapsuleWidth + SurfaceToolbarSeat.pinSize.width
                    < SurfaceLayout.width,
                "the widest the capsule can ever be, plus Pin, still fits the fixed surface — \(SurfaceToolbarSeat.widestCapsuleWidth) + \(SurfaceToolbarSeat.pinSize.width) against \(SurfaceLayout.width)")

        let absurd = String(repeating: "Lautsprechergruppen ", count: 20)
        let tab = SurfaceToolbarSeatButton(
            frame: NSRect(origin: .zero, size: SurfaceToolbarSeat.size))
        tab.configure(symbol: nil, label: absurd, toolTip: nil, isTab: true)
        tab.setNameRevealed(true, animated: false)
        #expect(tab.nameWidth == SurfaceToolbarSeat.maxNameWidth,
                "a name past the ceiling is clamped to it, and truncates rather than pushing")
        #expect(tab.test_width == SurfaceToolbarSeat.tabWidth(nameWidth: SurfaceToolbarSeat.maxNameWidth),
                "so the seat opens to the ceiling and no further — \(tab.test_width) pt")

        let capsule = SurfaceToolbarTabCapsule(tabs: [tab] + (0..<2).map { _ in
            SurfaceToolbarSeatButton(frame: NSRect(origin: .zero, size: SurfaceToolbarSeat.size))
        })
        #expect(capsule.fittingSize.width == SurfaceToolbarSeat.widestCapsuleWidth,
                "and the capsule around it stops at its widest — \(capsule.fittingSize.width) pt")
    }

    @Test func pinResolvesItsGlyph() {
        let (controller, _) = makeAttached()
        #expect(controller.test_pinItemHasImage)
    }

    // MARK: One shape language across the whole strip

    /// The defect this replaces (Alec, 2026-09-04): a bordered `NSToolbarItem`
    /// draws its HOVER state as a circle and its SELECTED state as a rounded
    /// square. Neither shape is settable, so the only fix is to draw the strip
    /// ourselves — and to draw ALL of it, because converting only the tabs is
    /// what failed live review on 2026-08-30 (bare glyphs beside bordered
    /// circles).
    @Test func everyItemInTheStripWearsTheSameSeat() {
        let (controller, _) = makeAttached()
        #expect(controller.test_everyItemWearsTheSeat,
                "the three tabs live in the one capsule — three sibling islands is the 2026-08-30 failure")
        // AppKit's circle and rounded square come from the stock button
        // cell's bezel. Every TAB installs `SurfaceToolbarSeatCell`, whose
        // `drawBezel` never calls `super`, so that bezel is replaced outright
        // rather than drawn under ours. Pin is exempt since 2026-09-05: it is
        // a bordered item precisely so the system draws its circle.
        let seats = SurfaceScreen.allCases.compactMap { controller.test_tabButton($0) }
        #expect(seats.count == SurfaceScreen.allCases.count)
        let everySeatOwnsItsBezel = seats.allSatisfy { $0.cell is SurfaceToolbarSeatCell }
        #expect(everySeatOwnsItsBezel,
                "no item hands its drawing back to AppKit; the authored highlight is the only chrome in the strip")
    }

    /// AppKit's own selection highlight must stay OFF: it is the rounded
    /// square whose hover twin is a circle, and leaving it on would draw a
    /// second seat behind the authored one.
    @Test func appKitsOwnSelectionHighlightIsOff() {
        let (controller, _) = makeAttached()
        #expect(controller.toolbarSelectableItemIdentifiers(controller.toolbar).isEmpty,
                "an empty selectable set is what keeps AppKit from drawing its own highlight")
        controller.setSelectedScreen(.groups)
        #expect(controller.toolbar.selectedItemIdentifier == nil,
                "the strip marks itself; nothing is handed to AppKit to draw")
    }

    /// The reason the tabs stopped being one `NSToolbarItemGroup` (live review
    /// 2026-08-29): a segmented control draws a hairline between adjacent
    /// segments and SUPPRESSES the one beside the selected segment, so the
    /// strip showed a divider that moved with the selection — one line with
    /// Mixer selected, none with Groups, one on the far side with Settings.
    /// Separate items cannot draw segment separators at all, so this asserts
    /// the structural fact that makes the dividers impossible.
    @Test func theTabsAreOneAuthoredCapsuleAndNotAToolbarItemGroup() {
        let (controller, _) = makeAttached()
        let item = controller.toolbar.items
            .first { $0.itemIdentifier == SurfaceToolbarController.tabsItemIdentifier }
        #expect(item as? NSToolbarItemGroup == nil,
                "a group is the segmented control whose separator moved with the selection; this capsule is drawn, so no separator exists to move")
        guard let capsule = controller.test_tabCapsule else {
            Issue.record("the tabs item carries no capsule")
            return
        }
        let tabs = SurfaceScreen.allCases.compactMap { controller.test_tabButton($0) }
        #expect(tabs.count == SurfaceScreen.allCases.count)
        for tab in tabs {
            #expect(tab.isDescendant(of: capsule),
                    "every tab lives INSIDE the one capsule — three siblings in the strip is the three-islands failure")
        }
        #expect(controller.test_pinItem?.view == nil,
                "Pin is the standalone bordered item BESIDE the group, never a fourth thing inside it")
    }

    /// The selection has to be visible on exactly one tab.
    @Test func onlyTheSelectedTabIsMarked() {
        let (controller, _) = makeAttached()
        #expect(controller.test_onlySelectedTabIsMarked, "Mixer starts selected, alone")

        controller.setSelectedScreen(.settings)

        #expect(controller.test_onlySelectedTabIsMarked, "the seat followed the selection")
        #expect(controller.test_engagedTabCount == 1, "and never two seats at once")
    }

    /// The capsule's width is the ONLY thing a selection may move, and it moves
    /// it by exactly the open tab's name. AppKit's own grouping on macOS 26+
    /// wandered instead: adjacent items merged into a shared capsule and the
    /// selected item was pulled out of it, so the container's geometry changed
    /// SHAPE with the selection (measured live: Mixer gave circle + capsule(2),
    /// Groups three circles, Settings capsule(2) + circle). Here it is one
    /// drawn surface whose height, order and padding never change.
    @Test func onlyTheOpenNameResizesTheCapsuleAndNothingElseReflows() {
        let (controller, window) = makeAttached()
        guard let capsule = controller.test_tabCapsule else {
            Issue.record("the tabs item carries no capsule")
            return
        }
        window.layoutIfNeeded()
        var heights: Set<CGFloat> = []
        var origins: Set<CGFloat> = []
        for screen in SurfaceScreen.allCases {
            controller.setSelectedScreen(screen)
            FoldAnimator.shared.test_settleNow()
            window.layoutIfNeeded()
            guard let open = controller.test_tabButton(screen) else { continue }
            #expect(capsule.fittingSize.width
                        == SurfaceToolbarSeat.capsuleWidth(nameWidth: open.nameWidth),
                    Comment(rawValue: "with \(screen.label) open the capsule is exactly that name wider — \(capsule.fittingSize.width) pt"))
            heights.insert(capsule.frame.height)
            origins.insert(capsule.frame.minX)
            let order = SurfaceScreen.allCases.compactMap { controller.test_tabButton($0)?.frame.minX }
            #expect(order == order.sorted(),
                    Comment(rawValue: "and the tabs keep their order with \(screen.label) open — \(order)"))
        }
        #expect(heights.count == 1, "the capsule's height never changes — a reveal is horizontal — \(heights)")
        #expect(origins.count == 1, "and it stays anchored to the same edge of the strip — \(origins)")
        #expect(capsule.fittingSize.height == SurfaceToolbarSeat.capsuleSize.height)
    }

    // MARK: The reveal's motion

    /// Reduce Motion means the name is simply THERE — no travel, not a
    /// disabled animation that still moves. The width is at its terminal value
    /// in the caller's own turn, before anything can display an intermediate.
    ///
    /// Travel runs on `FoldAnimator`, the app's one reveal clock, so this is
    /// the same synchronous-terminal contract every other clip in the app has.
    @Test func reduceMotionOpensTheNameWithNoTravel() {
        defer {
            FoldAnimator.shared.test_reduceMotionOverride = nil
            FoldAnimator.shared.test_settleNow()
        }
        FoldAnimator.shared.test_reduceMotionOverride = true
        let (controller, _) = makeAttached()

        controller.setSelectedScreen(.groups)

        guard let groups = controller.test_tabButton(.groups),
              let mixer = controller.test_tabButton(.mixer) else {
            Issue.record("the tabs have no seat buttons")
            return
        }
        #expect(groups.test_width == SurfaceToolbarSeat.tabWidth(nameWidth: groups.nameWidth),
                "Groups is fully open already — \(groups.test_width) pt")
        #expect(mixer.test_width == SurfaceToolbarSeat.size.width,
                "and Mixer is fully closed already — \(mixer.test_width) pt")
        #expect(!FoldAnimator.shared.isFolding, "nothing is left travelling")
    }

    /// Without Reduce Motion the name is REVEALED: the seat is still near its
    /// closed width when the click returns and reaches the open one only once
    /// the clock has run. Sampled off the seat's live width, so a version that
    /// only asked for an animation would fail here.
    @Test func withoutReduceMotionTheNameTravelsOpen() {
        defer {
            FoldAnimator.shared.test_reduceMotionOverride = nil
            FoldAnimator.shared.test_settleNow()
        }
        FoldAnimator.shared.test_reduceMotionOverride = false
        let (controller, _) = makeAttached()

        controller.setSelectedScreen(.settings)

        guard let settings = controller.test_tabButton(.settings) else {
            Issue.record("Settings has no seat button")
            return
        }
        let open = SurfaceToolbarSeat.tabWidth(nameWidth: settings.nameWidth)
        #expect(settings.test_width < open,
                "the seat has not jumped to its open width — \(settings.test_width) of \(open) pt")
        #expect(FoldAnimator.shared.isFolding, "it is travelling there")

        FoldAnimator.shared.test_settleNow()

        #expect(settings.test_width == open, "and arrives")
        #expect(controller.test_tabButton(.mixer)?.test_width == SurfaceToolbarSeat.size.width,
                "with Mixer closed again in the same travel")
    }

    /// Opening a name must not touch what VoiceOver is handed. The visible name
    /// is the SAME string the tab already speaks, and it is excluded from the
    /// accessibility tree, so nothing is said twice and nothing contradicts the
    /// spoken selection.
    @Test func openingTheNameLeavesTheSpokenSelectionAlone() {
        let (controller, window) = makeAttached()
        for selected in SurfaceScreen.allCases {
            controller.setSelectedScreen(selected)
            FoldAnimator.shared.test_settleNow()
            window.layoutIfNeeded()
            #expect(controller.test_onlySelectedTabIsMarked,
                    Comment(rawValue: "with \(selected.label) open, exactly it is marked"))
            for screen in SurfaceScreen.allCases {
                guard let tab = controller.test_tabButton(screen) else { continue }
                #expect(tab.isAccessibilitySelected() == (screen == selected),
                        Comment(rawValue: "\(screen.label)'s spoken selection is unchanged by the reveal"))
                #expect(tab.accessibilityLabel() == screen.label)
                #expect(tab.test_name == screen.label,
                        Comment(rawValue: "\(screen.label) draws the same name it speaks — never a second wording"))
                let labels = tab.subviews.compactMap { $0.isAccessibilityElement() ? $0 : nil }
                #expect(labels.isEmpty,
                        Comment(rawValue: "and the drawn name is not an accessibility element of its own, so \(screen.label) is never spoken twice"))
            }
        }
    }

    // MARK: The seat's real pixels

    /// Render a seat and hand back its bitmap, or `nil` where this machine
    /// cannot cache a display (the same offscreen `cacheDisplay` path the
    /// snapshot tests use).
    private func render(_ view: NSView,
                        appearanceName: NSAppearance.Name) -> NSBitmapImageRep? {
        view.appearance = NSAppearance(named: appearanceName)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The colour at a point given in the seat's own POINTS, scaled to
    /// whatever pixel density the rep came back at.
    private func color(_ rep: NSBitmapImageRep, atPoint point: NSPoint,
                       in bounds: NSRect) -> NSColor? {
        let scale = CGFloat(rep.pixelsWide) / bounds.width
        let x = min(rep.pixelsWide - 1, max(0, Int(point.x * scale)))
        let y = min(rep.pixelsHigh - 1, max(0, Int(point.y * scale)))
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    private func makeSeat(isEngaged: Bool = false, isHovered: Bool = false,
                          isPressed: Bool = false) -> SurfaceToolbarSeatButton {
        let button = SurfaceToolbarSeatButton(
            frame: NSRect(origin: .zero, size: SurfaceToolbarSeat.size))
        button.configure(symbol: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings"),
                         label: "Settings", toolTip: nil, isTab: true)
        button.isEngaged = isEngaged
        button.isHovered = isHovered
        button.test_isPressed = isPressed
        return button
    }

    /// A point clear of the glyph, on the seat's own left shoulder.
    private var seatProbe: NSPoint { NSPoint(x: 3, y: SurfaceToolbarSeat.size.height / 2) }

    /// The cue that failed review twice: no selection at all on macOS 14–25,
    /// because every state sat behind `if #available(macOS 26.0, *)`.
    /// `fillAlpha` is a plain function of the four state flags with no
    /// version in it, so what it returns here is what macOS 14.2 draws.
    @Test func everyStateHasAWeightAndTheLadderRises() {
        #expect(SurfaceToolbarSeat.fillAlpha(isEngaged: false, isHovered: false,
                                             isPressed: false, increaseContrast: false) == nil,
                "rest draws no seat")
        guard let hover = SurfaceToolbarSeat.fillAlpha(isEngaged: false, isHovered: true,
                                                       isPressed: false, increaseContrast: false),
              let engaged = SurfaceToolbarSeat.fillAlpha(isEngaged: true, isHovered: false,
                                                         isPressed: false, increaseContrast: false),
              let pressed = SurfaceToolbarSeat.fillAlpha(isEngaged: false, isHovered: false,
                                                         isPressed: true, increaseContrast: false) else {
            Issue.record("hover, selection and press must each draw a seat")
            return
        }
        #expect(hover < engaged, "the current screen outweighs the pointer")
        #expect(engaged < pressed, "and a press outweighs both, wherever it lands")
        // The three weights are the mixer's own (`rowHoverWashAlpha`,
        // `rowSelectionWashAlpha`, `mutePillFillAlpha`). Reading each back
        // here would only restate the `return` that produced it; what carries
        // information is the ORDER above, and that a rest seat draws nothing.
    }

    /// Increase Contrast is read LIVE on every draw (the app never snapshots
    /// the flag), and it lifts the whole ladder by one factor so the three
    /// weights keep their spacing instead of collapsing together.
    @Test func increaseContrastStrengthensEverySeatWithoutFlatteningTheLadder() {
        let states: [(engaged: Bool, hovered: Bool, pressed: Bool)] =
            [(false, true, false), (true, false, false), (false, false, true)]
        var lifted: [CGFloat] = []
        for state in states {
            guard let normal = SurfaceToolbarSeat.fillAlpha(isEngaged: state.engaged,
                                                            isHovered: state.hovered,
                                                            isPressed: state.pressed,
                                                            increaseContrast: false),
                  let high = SurfaceToolbarSeat.fillAlpha(isEngaged: state.engaged,
                                                          isHovered: state.hovered,
                                                          isPressed: state.pressed,
                                                          increaseContrast: true) else {
                Issue.record("every drawn state must answer in both contrast settings")
                return
            }
            #expect(high > normal, "Increase Contrast strengthens the seat")
            lifted.append(high)
        }
        #expect(lifted == lifted.sorted(), "and the rungs keep their order")
        #expect(Set(lifted).count == lifted.count, "and stay distinct from each other")
    }

    /// The seat must be VISIBLE, and in dark mode it must be LIGHTER than the
    /// strip. The authored fill this replaces got that backwards: it had to
    /// clear the unselected capsule, which already sat at the same grey, so
    /// the user's own location rendered as the darkest thing in the header.
    /// A rest seat draws nothing, so there is no capsule left to clear.
    @Test func theSelectedSeatPaintsAndLeansTheRightWayInBothAppearances() {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let rest = makeSeat()
            let engaged = makeSeat(isEngaged: true)
            guard let restRep = render(rest, appearanceName: appearanceName),
                  let engagedRep = render(engaged, appearanceName: appearanceName),
                  let restPixel = color(restRep, atPoint: seatProbe, in: rest.bounds),
                  let engagedPixel = color(engagedRep, atPoint: seatProbe, in: engaged.bounds) else {
                Issue.record("no bitmap rep under \(appearanceName.rawValue) — nothing was sampled")
                return
            }
            #expect(restPixel.alphaComponent < 0.01,
                    Comment(rawValue: "an idle tab paints no seat under \(appearanceName.rawValue)"))
            #expect(engagedPixel.alphaComponent > 0.05,
                    Comment(rawValue: "the current screen paints a real seat under \(appearanceName.rawValue) — this is the cue that was missing on macOS 14–25"))
            // The seat is drawn on a TRANSPARENT ground here, so its own
            // brightness only restates the token it is painted in. What the
            // eye judges is the seat COMPOSITED over the strip, so composite
            // it and require a visible separation from that ground. `panel`
            // stands in for the title bar's system material, which has no
            // token of its own.
            guard let ground = groundColor(appearanceName),
                  let composited = composite(engagedPixel, over: ground) else {
                Issue.record("could not resolve the strip's ground under \(appearanceName.rawValue)")
                return
            }
            let separation = composited.brightnessComponent - ground.brightnessComponent
            let numbers = "seat \(composited.brightnessComponent), ground \(ground.brightnessComponent)"
            if appearanceName == .darkAqua {
                #expect(separation > 0.04,
                        Comment(rawValue: "in dark the seat washes the strip LIGHTER, and visibly — \(numbers)"))
            } else {
                #expect(separation < -0.04,
                        Comment(rawValue: "in light the seat washes the flat ground darker, and visibly — \(numbers)"))
            }
        }
    }

    /// The ground the header strip sits on, resolved in `appearanceName`.
    private func groundColor(_ appearanceName: NSAppearance.Name) -> NSColor? {
        var resolved: NSColor?
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            resolved = Tokens.Color.panel.usingColorSpace(.sRGB)
        }
        return resolved
    }

    /// `top` painted over `bottom` at `top`'s own alpha — source-over, done by
    /// hand so the seat can be judged against the strip it lands on.
    private func composite(_ top: NSColor, over bottom: NSColor) -> NSColor? {
        guard let top = top.usingColorSpace(.sRGB), let bottom = bottom.usingColorSpace(.sRGB) else {
            return nil
        }
        let alpha = top.alphaComponent
        func mix(_ t: CGFloat, _ b: CGFloat) -> CGFloat { t * alpha + b * (1 - alpha) }
        return NSColor(srgbRed: mix(top.redComponent, bottom.redComponent),
                       green: mix(top.greenComponent, bottom.greenComponent),
                       blue: mix(top.blueComponent, bottom.blueComponent),
                       alpha: 1)
    }

    /// One shape per STATE: hover, selection and press are the SAME outline at
    /// three weights. AppKit's bordered item drew a circle on hover and a
    /// rounded square when selected — two shapes for two states of one
    /// control, which is the defect the authored seat exists to fix.
    ///
    /// What is NOT one shape any more is the two kinds of item: Pin is a
    /// circle and a tab is a stadium (Alec, 2026-09-05). Both come out of one
    /// rule — every seat is cut at half its own height — so this asserts the
    /// rule and the two tests below assert each shape's real pixels.
    ///
    /// The probes pin the tab's radius rather than just its outline. On a
    /// 28 pt-tall seat, `(3, 3)` lies inside a 10 pt corner but outside a
    /// 14 pt one, so the previous radius fails here; `outsideCorner` is clear
    /// of any rounded corner at all, so a square seat fails too.
    @Test func hoverSelectionAndPressAreOneShapeAtThreeWeights() {
        #expect(SurfaceToolbarSeat.seatCornerRadius(forHeight: SurfaceToolbarSeat.size.height)
                    == SurfaceToolbarSeat.size.height / 2,
                "a seat is cut at half its own height, whatever that height is")
        let insideOldCorner = NSPoint(x: 3, y: 3)
        let outsideCorner = NSPoint(x: 0.5, y: 0.5)
        let states: [(name: String, seat: SurfaceToolbarSeatButton)] = [
            ("hover", makeSeat(isHovered: true)),
            ("selected", makeSeat(isEngaged: true)),
            ("pressed", makeSeat(isPressed: true)),
        ]
        for state in states {
            guard let rep = render(state.seat, appearanceName: .darkAqua),
                  let oldCorner = color(rep, atPoint: insideOldCorner, in: state.seat.bounds),
                  let outside = color(rep, atPoint: outsideCorner, in: state.seat.bounds),
                  let middle = color(rep, atPoint: seatProbe, in: state.seat.bounds) else {
                Issue.record("\(state.name) rendered nothing to sample")
                return
            }
            #expect(middle.alphaComponent > 0.05,
                    Comment(rawValue: "\(state.name) draws a seat at all"))
            #expect(oldCorner.alphaComponent < 0.05,
                    Comment(rawValue: "\(state.name)'s corner is cut at half the seat's height (14 pt), not at the 10 pt that left an uneven gap against the pill"))
            #expect(outside.alphaComponent < 0.05,
                    Comment(rawValue: "\(state.name)'s corner really is rounded — a square seat would paint here"))
        }
    }

    /// Pin is a TRUE CIRCLE (Alec, 2026-09-05: "make the pin button a circle
    /// instead of an oval", then "so so so close" against the rounded square
    /// still on screen). The shape is the SYSTEM'S, and the only way to ask
    /// for it is a bordered item with no custom view: macOS 26 draws exactly
    /// that as a glass circle, and `NSToolbarItem` exposes no shape, corner
    /// radius or bezel to set on anything else.
    ///
    /// So this asserts the configuration rather than pixels. Drawing our own
    /// seat inside the item is what produced the oval — the system's wrapper
    /// sat around it, and no probe of our bitmap could ever have seen that.
    /// A custom view returning here is that regression.
    @Test func pinIsTheBorderedItemMacOSDrawsAsACircle() {
        let (controller, _) = makeAttached()
        guard let pin = controller.test_pinItem else {
            Issue.record("the strip carries no Pin item")
            return
        }
        #expect(pin.view == nil,
                "a custom view puts our own seat inside the system's wrapper — the oval")
        #expect(pin.isBordered,
                "bordered is the one configuration macOS draws as a circle")
        #expect(pin.image != nil, "and the glyph is the item's, not a subview's")
    }

    /// Pinned state reads off the SYMBOL, because a bordered item's chrome
    /// belongs to the system and cannot carry our engaged wash.
    @Test func pinShowsItsStateThroughTheGlyph() {
        let (controller, _) = makeAttached()
        // Compared as PIXELS: a symbol image loaded by name reports no `name()`
        // to read back, so anything less would pass on two nils.
        let unpinned = controller.test_pinItem?.image?.tiffRepresentation
        controller.setPinned(true)
        let pinned = controller.test_pinItem?.image?.tiffRepresentation
        #expect(unpinned != nil && pinned != nil, "both states must resolve a glyph")
        #expect(pinned != unpinned, "the glyph has to change between the two states")
        #expect(controller.test_pinItem?.label == "Unpin")
    }

    // MARK: The capsule's real pixels

    /// A laid-out capsule with the three tabs in the given states. The tabs
    /// carry NO glyph: what these tests sample is the capsule's own surface
    /// and the highlight over it, and a symbol's ink would land in the probes.
    private func makeCapsule(engaged: SurfaceScreen? = nil,
                             hovered: SurfaceScreen? = nil) -> SurfaceToolbarTabCapsule {
        let tabs = SurfaceScreen.allCases.map { screen -> SurfaceToolbarSeatButton in
            let tab = SurfaceToolbarSeatButton(
                frame: NSRect(origin: .zero, size: SurfaceToolbarSeat.size))
            tab.configure(symbol: nil, label: screen.label, toolTip: nil, isTab: true)
            tab.isEngaged = (screen == engaged)
            tab.isHovered = (screen == hovered)
            return tab
        }
        let capsule = SurfaceToolbarTabCapsule(tabs: tabs)
        // Auto Layout needs a host to lay the capsule out in; the capsule's
        // own constraints then give it its fixed size.
        let host = NSView(frame: NSRect(origin: .zero, size: SurfaceToolbarSeat.capsuleSize))
        host.addSubview(capsule)
        NSLayoutConstraint.activate([
            capsule.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            capsule.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        return capsule
    }

    /// The horizontal middle of tab `index`, at the capsule's mid-height.
    private func tabProbe(_ index: Int) -> NSPoint {
        NSPoint(x: SurfaceToolbarSeat.capsulePadding
                    + SurfaceToolbarSeat.size.width * (CGFloat(index) + 0.5),
                y: SurfaceToolbarSeat.capsuleSize.height / 2)
    }

    /// ONE continuous capsule, not three islands (Alec, 2026-09-04). With
    /// nothing selected or hovered, the same wash must be present at every
    /// point across the capsule — the middle of each tab, both seams between
    /// them, and the ends past the outer tabs. Three separate seats would
    /// leave the seams and the ends empty, which is exactly what the rejected
    /// version looked like.
    @Test func theCapsuleIsOneUnbrokenSurfaceBehindAllThreeTabs() {
        let capsule = makeCapsule()
        let midHeight = SurfaceToolbarSeat.capsuleSize.height / 2
        let seam = SurfaceToolbarSeat.capsulePadding + SurfaceToolbarSeat.size.width
        let probes: [(String, NSPoint)] = [
            // 2.5 pt in from each end: clear of the 1 pt edge stroke and of
            // what its anti-aliasing bleeds inward.
            ("the left end, past Mixer", NSPoint(x: 2.5, y: midHeight)),
            ("Mixer", tabProbe(0)),
            ("the Mixer/Groups seam", NSPoint(x: seam, y: midHeight)),
            ("Groups", tabProbe(1)),
            ("the Groups/Settings seam", NSPoint(x: seam + SurfaceToolbarSeat.size.width, y: midHeight)),
            ("Settings", tabProbe(2)),
            ("the right end, past Settings",
             NSPoint(x: SurfaceToolbarSeat.capsuleSize.width - 2.5, y: midHeight)),
        ]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let rep = render(capsule, appearanceName: appearanceName) else {
                Issue.record("no bitmap rep under \(appearanceName.rawValue)")
                return
            }
            var sampled: [CGFloat] = []
            for (name, point) in probes {
                guard let pixel = color(rep, atPoint: point, in: capsule.bounds) else {
                    Issue.record("nothing sampled at \(name)")
                    return
                }
                #expect(pixel.alphaComponent > 0.02,
                        Comment(rawValue: "the capsule paints at \(name) under \(appearanceName.rawValue) — a gap here is the three-islands failure"))
                sampled.append(pixel.alphaComponent)
            }
            let spread = (sampled.max() ?? 0) - (sampled.min() ?? 0)
            #expect(spread < 0.01,
                    Comment(rawValue: "and paints the SAME under \(appearanceName.rawValue) all the way across — \(sampled)"))
        }
        // A pill, so its corner is cut far harder than a rounded box's.
        guard let rep = render(capsule, appearanceName: .darkAqua),
              let corner = color(rep, atPoint: NSPoint(x: 1.5, y: 1.5), in: capsule.bounds) else {
            Issue.record("nothing sampled at the capsule's corner")
            return
        }
        #expect(corner.alphaComponent < 0.02,
                "the capsule's corner is cut at half its height — a rounded box would still paint here")
    }

    /// The selected tab's highlight lives INSIDE the shared capsule and must
    /// read as a lift OFF it: lighter than the capsule in dark, darker in
    /// light, with hover the same shape at a weaker weight. An earlier attempt
    /// had to CLEAR an unselected capsule that already sat at the same grey,
    /// so in dark mode the user's own location rendered as the darkest thing
    /// on the strip. Here the highlight is painted ON the capsule, so it can
    /// only move away from it.
    @Test func theSelectedHighlightLiftsOffTheCapsuleAndHoverSitsBetween() {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            // Groups selected, Settings hovered, Mixer idle: one render
            // carries all three weights over the same capsule.
            let capsule = makeCapsule(engaged: .groups, hovered: .settings)
            guard let rep = render(capsule, appearanceName: appearanceName),
                  let ground = groundColor(appearanceName),
                  let idle = color(rep, atPoint: tabProbe(0), in: capsule.bounds),
                  let selected = color(rep, atPoint: tabProbe(1), in: capsule.bounds),
                  let hovered = color(rep, atPoint: tabProbe(2), in: capsule.bounds),
                  let idleOnStrip = composite(idle, over: ground),
                  let selectedOnStrip = composite(selected, over: ground),
                  let hoveredOnStrip = composite(hovered, over: ground) else {
                Issue.record("nothing sampled under \(appearanceName.rawValue)")
                return
            }
            let capsuleLevel = idleOnStrip.brightnessComponent
            let hoverLevel = hoveredOnStrip.brightnessComponent
            let selectedLevel = selectedOnStrip.brightnessComponent
            let numbers = "capsule \(capsuleLevel), hover \(hoverLevel), selected \(selectedLevel), strip \(ground.brightnessComponent)"
            if appearanceName == .darkAqua {
                #expect(selectedLevel > capsuleLevel + 0.04,
                        Comment(rawValue: "in dark the current screen is LIGHTER than the capsule, and visibly — \(numbers)"))
                #expect(hoverLevel > capsuleLevel && hoverLevel < selectedLevel,
                        Comment(rawValue: "and hover is the same lift, weaker — \(numbers)"))
            } else {
                #expect(selectedLevel < capsuleLevel - 0.04,
                        Comment(rawValue: "in light the current screen is darker than the capsule, and visibly — \(numbers)"))
                #expect(hoverLevel < capsuleLevel && hoverLevel > selectedLevel,
                        Comment(rawValue: "and hover is the same wash, weaker — \(numbers)"))
            }
        }
    }

    /// The strip is ONE height: the capsule is exactly as tall as Pin (Alec,
    /// 2026-09-05, "make the component slightly bigger to meet the same height
    /// as the pin button"). It was 32 pt against a 26 pt Pin before.
    ///
    /// A tab's height is DERIVED from that, and the arithmetic below is the
    /// whole reason the highlight can be concentric: a seat cut at half its own
    /// height lands on `capsuleCornerRadius - capsulePadding` only while the
    /// tab is the capsule minus its padding.
    @Test func theCapsuleAndPinAreTheSameHeightAndTheTabRadiusFollowsFromIt() {
        #expect(SurfaceToolbarSeat.capsuleSize.height == SurfaceToolbarSeat.pinSize.height,
                "the pill and Pin stand the same height — \(SurfaceToolbarSeat.capsuleSize.height) against \(SurfaceToolbarSeat.pinSize.height)")
        #expect(SurfaceToolbarSeat.size.height
                    == SurfaceToolbarSeat.capsuleSize.height - SurfaceToolbarSeat.capsulePadding * 2,
                "a tab is the capsule minus the padding above and below it")
        #expect(SurfaceToolbarSeat.seatCornerRadius(forHeight: SurfaceToolbarSeat.size.height)
                    == SurfaceToolbarSeat.capsuleCornerRadius - SurfaceToolbarSeat.capsulePadding,
                "which is what makes a tab's radius concentric with the pill — \(SurfaceToolbarSeat.seatCornerRadius(forHeight: SurfaceToolbarSeat.size.height)) against \(SurfaceToolbarSeat.capsuleCornerRadius) - \(SurfaceToolbarSeat.capsulePadding)")
    }

    /// "The highlight does not perfectly conform with the border" (Alec,
    /// 2026-09-05). Measured, not eyeballed: concentric rounded rectangles put
    /// the inner boundary the SAME distance from the outer one at every angle,
    /// so this walks the capsule's left end cap and requires exactly that.
    ///
    /// The leftmost tab is the one selected, so its highlight sits against the
    /// pill's rounded end — the place the uneven gap showed. Both arcs are
    /// struck from the same centre when the geometry is right: the capsule's
    /// is `(capsuleCornerRadius, height/2)` and the highlight's is
    /// `(capsulePadding + tabHeight/2, height/2)`, which are the same point
    /// once `tabHeight/2 == capsuleCornerRadius - capsulePadding`.
    ///
    /// The outer ring is what fails on the old geometry. With the highlight cut
    /// at 10 pt instead of 14, its corner bulged toward the pill: the probe at
    /// 135° lands 9.3 pt from that corner's centre, inside a 10 pt round, so
    /// the highlight still painted where it must now be clear.
    ///
    /// The tabs are collapsed here. The selected tab is expanded in the running
    /// strip, but only its RIGHT end moves — the left end cap this measures is
    /// the same arc either way.
    @Test func theSelectedHighlightIsConcentricWithTheCapsulesBorder() {
        let capsule = makeCapsule(engaged: .mixer)
        let radius = SurfaceToolbarSeat.seatCornerRadius(
            forHeight: SurfaceToolbarSeat.size.height)
        let centre = NSPoint(x: SurfaceToolbarSeat.capsuleCornerRadius,
                             y: SurfaceToolbarSeat.capsuleSize.height / 2)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let rep = render(capsule, appearanceName: appearanceName),
                  // The bare pill, sampled under an idle tab: what a point
                  // OUTSIDE the highlight but inside the capsule must match.
                  let bare = color(rep, atPoint: tabProbe(2), in: capsule.bounds) else {
                Issue.record("nothing sampled under \(appearanceName.rawValue)")
                return
            }
            var insides: [CGFloat] = []
            // The left-facing half of the cap, clear of the seams top and
            // bottom where the highlight's two end caps meet.
            for degrees in stride(from: 100, through: 260, by: 20) {
                let radians = CGFloat(degrees) * .pi / 180
                func probe(_ distance: CGFloat) -> NSColor? {
                    color(rep,
                          atPoint: NSPoint(x: centre.x + cos(radians) * distance,
                                           y: centre.y + sin(radians) * distance),
                          in: capsule.bounds)
                }
                guard let inside = probe(radius - 2), let outside = probe(radius + 1) else {
                    Issue.record("nothing sampled at \(degrees)° under \(appearanceName.rawValue)")
                    return
                }
                #expect(inside.alphaComponent > bare.alphaComponent + 0.05,
                        Comment(rawValue: "the highlight paints 2 pt inside its edge at \(degrees)° under \(appearanceName.rawValue) — \(inside.alphaComponent) against the bare pill's \(bare.alphaComponent)"))
                #expect(abs(outside.alphaComponent - bare.alphaComponent) < 0.02,
                        Comment(rawValue: "and 1 pt outside it there is only the bare pill at \(degrees)° under \(appearanceName.rawValue) — \(outside.alphaComponent) against \(bare.alphaComponent); a 10 pt corner would still paint here"))
                insides.append(inside.alphaComponent)
            }
            let spread = (insides.max() ?? 0) - (insides.min() ?? 0)
            #expect(spread < 0.02,
                    Comment(rawValue: "and the highlight sits at one constant distance from the pill's own arc all the way round under \(appearanceName.rawValue) — \(insides)"))
        }
    }

    /// The capsule's own wash stays under the hover rung, in every
    /// accessibility setting — otherwise a hovered tab would stop separating
    /// from the surface it sits on. Increase Contrast lifts the capsule by the
    /// same factor as the highlights; Reduce Transparency answers with a
    /// heavier edge instead, which is what keeps the gap open.
    @Test func theCapsuleStaysUnderTheHoverWeightInEveryAccessibilitySetting() {
        for increaseContrast in [false, true] {
            guard let hover = SurfaceToolbarSeat.fillAlpha(isEngaged: false, isHovered: true,
                                                           isPressed: false,
                                                           increaseContrast: increaseContrast) else {
                Issue.record("hover must draw a highlight")
                return
            }
            let capsule = SurfaceToolbarSeat.capsuleFillAlpha(increaseContrast: increaseContrast)
            #expect(capsule > 0, "the capsule always paints — it is the surface all three tabs share")
            #expect(capsule < hover,
                    Comment(rawValue: "capsule \(capsule) must stay under hover \(hover) with Increase Contrast \(increaseContrast)"))
        }
        #expect(SurfaceToolbarSeat.capsuleFillAlpha(increaseContrast: true)
                    > SurfaceToolbarSeat.capsuleFillAlpha(increaseContrast: false),
                "Increase Contrast strengthens the capsule too, so the whole strip keeps its spacing")
        #expect(SurfaceToolbarSeat.capsuleEdgeColor(reduceTransparency: true)
                    != SurfaceToolbarSeat.capsuleEdgeColor(reduceTransparency: false),
                "Reduce Transparency swaps the capsule's edge for the heavier one — the strip's material goes flat, so the pill has to carry itself")
    }

    // MARK: The spoken selection

    /// `NSToolbar.selectedItemIdentifier` is what VoiceOver used to speak, so
    /// taking over the drawing means taking over the spoken state too. Losing
    /// it is a regression that has already failed review once.
    @Test func exactlyTheSelectedTabReportsSelectedToAccessibility() {
        let (controller, _) = makeAttached()
        for selected in SurfaceScreen.allCases {
            controller.setSelectedScreen(selected)
            for screen in SurfaceScreen.allCases {
                guard let button = controller.test_tabButton(screen) else {
                    Issue.record("\(screen.label) has no seat button")
                    return
                }
                let shouldBeSelected = screen == selected
                #expect(button.isAccessibilitySelected() == shouldBeSelected,
                        Comment(rawValue: "with \(selected.label) showing, \(screen.label) must report selected == \(shouldBeSelected)"))
                #expect((button.accessibilityValue() as? NSNumber)?.boolValue == shouldBeSelected,
                        Comment(rawValue: "\(screen.label)'s accessibility value is what VoiceOver speaks for a radio button"))
                #expect(button.accessibilityRole() == .radioButton,
                        Comment(rawValue: "\(screen.label) is one of three, exactly one on"))
                #expect(button.accessibilityLabel() == screen.label,
                        Comment(rawValue: "\(screen.label) speaks its name"))
            }
        }
    }

    // MARK: Selection — host-confirmed round trip

    @Test func tabTapsReportTheScreenButDoNotSelfSelect() {
        // The host owns selection, same contract as the retired header: a tap
        // fires the callback with the right screen, and with no confirming
        // `setSelectedScreen` the tabs snap back to the confirmed selection.
        // `test_selectTab` is a REAL `performClick` through the button's own
        // target/action, so this proves the click path as well as the contract.
        let (controller, _) = makeAttached()
        var reported: [SurfaceScreen] = []
        controller.onSelectScreen = { reported.append($0) }

        controller.test_selectTab(.groups)
        controller.test_selectTab(.settings)

        #expect(reported == [.groups, .settings])
        #expect(controller.selectedScreen == .mixer, "selection unchanged until the host confirms")
        #expect(controller.test_selectedTabIndex == SurfaceScreen.mixer.rawValue,
                "the tabs snapped back to the host-confirmed screen")
    }

    @Test func hostConfirmedSelectionMovesTheSeat() {
        let (controller, _) = makeAttached()
        #expect(controller.test_selectedTabIndex == SurfaceScreen.mixer.rawValue,
                "Mixer starts selected")

        controller.setSelectedScreen(.settings)

        #expect(controller.selectedScreen == .settings)
        #expect(controller.test_selectedTabIndex == SurfaceScreen.settings.rawValue)
    }

    @Test func aConfirmingHostKeepsTheTappedTab() {
        // The live wiring: the host's callback calls setSelectedScreen
        // synchronously, so the tapped tab stays.
        let (controller, _) = makeAttached()
        controller.onSelectScreen = { controller.setSelectedScreen($0) }

        controller.test_selectTab(.groups)

        #expect(controller.selectedScreen == .groups)
        #expect(controller.test_selectedTabIndex == SurfaceScreen.groups.rawValue)
    }

    // MARK: Pin

    @Test func pinFiresItsCallback() {
        let (controller, _) = makeAttached()
        var pinned = false
        controller.onTogglePin = { pinned = true }

        controller.test_tapPin()

        #expect(pinned)
    }

    @Test func pinItemReflectsThePinnedState() {
        let (controller, _) = makeAttached()
        #expect(!controller.isPinned)
        #expect(controller.test_pinItemLabel == "Pin")

        controller.setPinned(true)
        #expect(controller.isPinned)
        #expect(controller.test_pinItemLabel == "Unpin")
        #expect(controller.test_pinItemHasImage, "pin.fill resolved for the pinned state")

        controller.setPinned(false)
        #expect(controller.test_pinItemLabel == "Pin")
    }
}
