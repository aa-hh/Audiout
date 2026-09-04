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
            SurfaceToolbarController.tabItemIdentifier(for: .mixer),
            .space,
            SurfaceToolbarController.tabItemIdentifier(for: .groups),
            .space,
            SurfaceToolbarController.tabItemIdentifier(for: .settings),
            .flexibleSpace,
            SurfaceToolbarController.pinItemIdentifier,
        ], "three spaced tabs lead and Pin trails; Quit left the strip for the menus")
        #expect(window.toolbar === controller.toolbar)
        #expect(window.toolbarStyle == .unified, "D1: unified — the toolbar IS the one header strip")
    }

    @Test func tabsCarryAllThreeScreensWithResolvedGlyphs() {
        let (controller, _) = makeAttached()
        #expect(controller.test_tabLabels == ["Mixer", "Groups", "Settings"])
        #expect(controller.test_allTabImagesResolved,
                "every tab resolved a system SF Symbol")
    }

    /// The tabs are ICON-ONLY (Alec, 2026-09-03). Names on the items' `title`
    /// were tried and removed: translated labels would widen the strip until
    /// AppKit swept the tabs into the overflow menu, and primary navigation
    /// cannot live behind a chevron. The names still reach the reader through
    /// the tooltip, the accessibility label, and ⌘1/⌘2/⌘3 — none of which
    /// costs width.
    @Test func tabsDrawNoNameSoTheStripCannotGrowWithTranslation() {
        let (controller, window) = makeAttached()
        window.layoutIfNeeded()
        // Hoisted out of `#expect`: the macro decomposes the call, and
        // `allSatisfy` is `rethrows`, so the expansion refuses to compile.
        let noTabDrawsAName = controller.test_tabTitles.allSatisfy(\.isEmpty)
        #expect(noTabDrawsAName, "no tab draws a name")
        #expect(controller.test_tabLabels == SurfaceScreen.allCases.map(\.label),
                "but every tab still carries its name for the overflow menu")
        #expect(controller.test_tabAccessibilityLabels == SurfaceScreen.allCases.map(\.label),
                "and VoiceOver is handed it from the view, which is what speaks now")
        #expect(controller.test_tabToolTips == SurfaceScreen.allCases.map { "\($0.label) (⌘\($0.keyEquivalent))" },
                "and the tooltip spells it out with the shortcut")
        #expect(controller.test_allTabImagesResolved,
                "the glyph is what the tab shows")
        #expect(controller.toolbar.displayMode == .iconOnly)
    }

    /// Every seat is fixed-width, and every item asks to stay visible — the
    /// two things that keep the strip out of the overflow chevron.
    @Test func everySeatIsFixedWidthAndAsksToStayOutOfTheOverflowMenu() {
        let (controller, _) = makeAttached()
        for item in controller.toolbar.items {
            guard let view = item.view else { continue }
            // `fittingSize`, not `frame`: the frame is the size the item was
            // CONSTRUCTED with, so reading it back would survive the seat's
            // own width/height constraints being deleted. `fittingSize` is
            // computed from those constraints.
            #expect(view.fittingSize == SurfaceToolbarSeat.size,
                    Comment(rawValue: "\(item.itemIdentifier.rawValue) must be the fixed seat size"))
            #expect(item.visibilityPriority == .high,
                    Comment(rawValue: "\(item.itemIdentifier.rawValue) must not be sweepable into the chevron"))
        }
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
                "the three tabs AND Pin are all SurfaceToolbarSeatButtons — half a conversion is the 2026-08-30 failure")
        // AppKit's circle and rounded square come from the stock button
        // cell's bezel. Every seat installs `SurfaceToolbarSeatCell`, whose
        // `drawBezel` never calls `super`, so that bezel is replaced outright
        // rather than drawn under ours.
        let everySeatOwnsItsBezel = controller.toolbar.items
            .compactMap { $0.view as? SurfaceToolbarSeatButton }
            .allSatisfy { $0.cell is SurfaceToolbarSeatCell }
        #expect(everySeatOwnsItsBezel,
                "no item hands its drawing back to AppKit; the seat is the only chrome in the strip")
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
    @Test func theTabsAreSeparateItemsSoNoSegmentSeparatorCanAppear() {
        let (controller, _) = makeAttached()
        let tabIdentifiers = SurfaceScreen.allCases.map(SurfaceToolbarController.tabItemIdentifier(for:))
        #expect(Set(tabIdentifiers).isSubset(of: Set(controller.test_itemIdentifiers)),
                "each screen is its own toolbar item")
        for identifier in tabIdentifiers {
            let item = controller.toolbar.items.first { $0.itemIdentifier == identifier }
            #expect(item as? NSToolbarItemGroup == nil,
                    "\(identifier.rawValue) must not be a group — a group is the segmented control whose separator moved with the selection")
        }
    }

    /// The selection has to be visible on exactly one tab.
    @Test func onlyTheSelectedTabIsMarked() {
        let (controller, _) = makeAttached()
        #expect(controller.test_onlySelectedTabIsMarked, "Mixer starts selected, alone")

        controller.setSelectedScreen(.settings)

        #expect(controller.test_onlySelectedTabIsMarked, "the seat followed the selection")
        #expect(controller.test_engagedTabCount == 1, "and never two seats at once")
    }

    /// The tabs are `.space`-separated so the strip cannot RESHAPE with the
    /// selection. Adjacent items merged into one shared capsule on macOS 26+,
    /// and the selected item was then pulled out of that capsule — measured
    /// live: Mixer gave circle + capsule(2), Groups gave three circles,
    /// Settings gave capsule(2) + circle. Same wandering geometry the
    /// segmented divider had.
    @Test func theTabsAreSeparatedSoTheStripCannotReshape() {
        let (controller, _) = makeAttached()
        let ids = controller.test_itemIdentifiers
        let tabs = SurfaceScreen.allCases.map(SurfaceToolbarController.tabItemIdentifier(for:))
        for (first, second) in zip(tabs, tabs.dropFirst()) {
            guard let a = ids.firstIndex(of: first), let b = ids.firstIndex(of: second) else {
                Issue.record("a tab item is missing from the toolbar")
                return
            }
            #expect(b == a + 2 && ids[a + 1] == .space,
                    "a .space must sit between \(first.rawValue) and \(second.rawValue)")
        }
    }

    // MARK: The seat's real pixels

    /// Render a seat and hand back its bitmap, or `nil` where this machine
    /// cannot cache a display (the same offscreen `cacheDisplay` path the
    /// snapshot tests use).
    private func render(_ button: SurfaceToolbarSeatButton,
                        appearanceName: NSAppearance.Name) -> NSBitmapImageRep? {
        button.appearance = NSAppearance(named: appearanceName)
        guard let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return nil }
        button.cacheDisplay(in: button.bounds, to: rep)
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

    /// One shape language: hover, selection and press are the SAME rounded
    /// rectangle at different weights. AppKit's bordered item drew a circle on
    /// hover and a rounded square when selected — two shapes for two states of
    /// one control, which is the defect.
    ///
    /// The probes are chosen to pin the radius, not just the outline:
    /// `insideCorner` sits inside a 10 pt corner but OUTSIDE the 13 pt one a
    /// capsule on this 26 pt-tall seat would have, and `outsideCorner` is
    /// clear of any rounded corner at all — so a square, a capsule and a
    /// circle each fail a probe that the drawn shape passes.
    @Test func hoverSelectionAndPressAreOneShapeAtThreeWeights() {
        #expect(SurfaceToolbarSeat.cornerRadius == Tokens.Layout.Radius.control,
                "the seat is the control radius, and the same one in every state")
        let insideCorner = NSPoint(x: 3, y: 3)
        let outsideCorner = NSPoint(x: 0.5, y: 0.5)
        let states: [(name: String, seat: SurfaceToolbarSeatButton)] = [
            ("hover", makeSeat(isHovered: true)),
            ("selected", makeSeat(isEngaged: true)),
            ("pressed", makeSeat(isPressed: true)),
        ]
        for state in states {
            guard let rep = render(state.seat, appearanceName: .darkAqua),
                  let inside = color(rep, atPoint: insideCorner, in: state.seat.bounds),
                  let outside = color(rep, atPoint: outsideCorner, in: state.seat.bounds),
                  let middle = color(rep, atPoint: seatProbe, in: state.seat.bounds) else {
                Issue.record("\(state.name) rendered nothing to sample")
                return
            }
            #expect(middle.alphaComponent > 0.05,
                    Comment(rawValue: "\(state.name) draws a seat at all"))
            #expect(inside.alphaComponent > 0.05,
                    Comment(rawValue: "\(state.name)'s corner is cut at the control radius, not the capsule radius a circle would need"))
            #expect(outside.alphaComponent < 0.05,
                    Comment(rawValue: "\(state.name)'s corner really is rounded — a square seat would paint here"))
        }
    }

    /// Pin wears the same seat, and its "on" reads as selected.
    @Test func pinnedPinDrawsTheSameSeatAsASelectedTab() {
        let (controller, _) = makeAttached()
        guard let pin = controller.test_pinButton else {
            Issue.record("Pin has no seat button")
            return
        }
        #expect(!pin.isEngaged, "unpinned draws no seat, exactly like an idle tab")
        controller.setPinned(true)
        #expect(pin.isEngaged, "pinned wears the selected weight")
        controller.setPinned(false)
        #expect(!pin.isEngaged)
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
