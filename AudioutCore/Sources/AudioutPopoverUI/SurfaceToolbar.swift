// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The one-surface header, as a REAL window-attached `NSToolbar` (owner
/// decision D1, live build review 2026-08-07 — supersedes the custom
/// `PopoverHeaderView` strip and its three-tier glass/frost/opaque material
/// machinery; the system toolbar provides Liquid Glass on macOS 26+, the older
/// material below, and Reduce Transparency handling on its own):
///
/// - the three screens as three tabs, ICON-ONLY, and deliberately so: names
///   were tried on the items' `title` (#95, #97) and removed again (Alec,
///   2026-09-03) because three translated labels would widen the strip until
///   AppKit swept the tabs into the overflow menu, and primary navigation
///   cannot live behind a chevron. Nothing is lost to a reader: the tooltips
///   ("Mixer (⌘1)"), the items' `label`s (VoiceOver and the overflow menu)
///   and ⌘1/⌘2/⌘3 all still carry the names, and none of them costs strip
///   width in any language;
/// - Pin as a trailing item wearing the same control.
///
/// **The strip draws its own chrome** (Alec, 2026-09-04). Every item is an
/// `NSToolbarItem` whose view is a `SurfaceToolbarSeatButton`, and the seat it
/// draws is one rounded rectangle in every state — rest, hover, pressed,
/// selected, and Pin's on/off. What that replaces: AppKit draws a BORDERED
/// item's hover state as a circle and its selected state as a rounded square,
/// two shapes for two states of one control, and neither shape is settable.
/// The strip is converted WHOLE — the tabs and Pin together — because
/// converting only the tabs is what failed live review on 2026-08-30 (three
/// bare glyphs beside two bordered circles, two styles in one header).
/// `SurfaceToolbarSeat` holds the shape, the size and the wash strengths.
///
/// The `NSToolbar` itself stays: it is the window's one unified title-bar
/// strip, and it supplies the system material and the Reduce Transparency
/// handling that the retired custom header had to hand-build.
///
/// **Three earlier attempts, so none of them comes back:**
/// - an `NSToolbarItemGroup` segmented control drew a hairline between
///   adjacent segments and suppressed the one beside the SELECTED segment, so
///   the divider moved with the selection and no API draws them consistently;
/// - custom-view tabs beside the bordered Pin item left bare glyphs next to
///   bordered circles — two styles in one header, which is why the conversion
///   is now all of the strip or none of it;
/// - an authored fill put every cue inside `if #available(macOS 26.0, *)`
///   while the package deploys to 14.2, so macOS 14–25 showed three identical
///   circles and no current screen at all — and the suite stayed green
///   because the seams asserted the intent rather than the pixels. It also
///   had to clear the UNSELECTED capsule, and in dark mode that capsule
///   already sat at the same grey, so the selected tab rendered as the
///   darkest thing in the strip. Neither trap survives here: nothing in
///   `SurfaceToolbarSeat` is behind an availability check, an unselected seat
///   draws nothing for a selected one to clear, and the tests below sample
///   real pixels.
///
/// One toolbar per process: unlike the retired per-screen header instances,
/// the toolbar belongs to the shell WINDOW, so there is nothing to keep in
/// sync across screens — `AppSurfaceController` pushes state into this one
/// object. Selection is HOST-CONFIRMED, same contract as the old header: a
/// click only reports through `onSelectScreen`, and the tabs are re-asserted
/// from the host-confirmed `selectedScreen` afterward, so the strip can never
/// drift from the screen actually shown.
///
/// ⌘1/⌘2/⌘3 do NOT live here: the surface installs them on the shell panel's
/// `keyEquivalentHandler` seam instead.
///
/// Lives in AudioutPopoverUI, not the shell: the header switches the three
/// screens, and the shell stays content-agnostic.
@MainActor
final class SurfaceToolbarController: NSObject {


    static let pinItemIdentifier = NSToolbarItem.Identifier("SurfacePin")

    /// One stable, non-localized identifier per screen.
    static func tabItemIdentifier(for screen: SurfaceScreen) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("SurfaceTab\(screen.rawValue)")
    }

    /// A tab was clicked. The host decides what a selection means; the tabs are
    /// re-asserted from `selectedScreen` after this returns (the host confirms
    /// via `setSelectedScreen`).
    var onSelectScreen: ((SurfaceScreen) -> Void)?
    /// The Pin item was clicked.
    var onTogglePin: (() -> Void)?

    // MARK: State (pushed by the host)

    private(set) var selectedScreen: SurfaceScreen = .mixer
    private(set) var isPinned = false

    let toolbar: NSToolbar

    private var tabItems: [SurfaceScreen: NSToolbarItem] = [:]
    private var pinItem: NSToolbarItem?

    private func tabButton(_ screen: SurfaceScreen) -> SurfaceToolbarSeatButton? {
        tabItems[screen]?.view as? SurfaceToolbarSeatButton
    }

    private var pinButton: SurfaceToolbarSeatButton? {
        pinItem?.view as? SurfaceToolbarSeatButton
    }

    override init() {
        toolbar = NSToolbar(identifier: "SurfaceToolbar")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
    }

    /// Attach to the shell window: the toolbar becomes the window's one header
    /// strip in both manner profiles. `.unified` merges the title-bar area and
    /// the toolbar into a single strip (D1 — no separate title bar ever).
    func attach(to window: NSWindow) {
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    // MARK: State pushed by the host

    func setSelectedScreen(_ screen: SurfaceScreen) {
        selectedScreen = screen
        applySelectionToTabs()
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        applyPinAppearance()
    }

    /// Mark the current screen on the tabs themselves — the seat they draw and
    /// the selection they speak.
    ///
    /// This does NOT set `NSToolbar.selectedItemIdentifier`, and
    /// `toolbarSelectableItemIdentifiers` is deliberately empty: that seam is
    /// what turns AppKit's OWN highlight on, and AppKit's highlight is the
    /// circle-on-hover / rounded-square-on-selection pair this whole change
    /// exists to replace. Leaving it on would have drawn a second seat behind
    /// this one.
    ///
    /// `selectedItemIdentifier` was also what VoiceOver spoke, so taking the
    /// drawing means taking the spoken state: `SurfaceToolbarSeatButton` sets
    /// the radio-button role, the accessibility value and
    /// `isAccessibilitySelected` from the same flag that draws the seat, and
    /// `SurfaceToolbarTests` asserts exactly one tab reports selected.
    private func applySelectionToTabs() {
        for screen in SurfaceScreen.allCases {
            tabButton(screen)?.isEngaged = (screen == selectedScreen)
        }
    }

    private func applyPinAppearance() {
        guard let pinItem, let pinButton else { return }
        let label = isPinned ? "Unpin" : "Pin"
        pinButton.configure(symbol: Self.resolveSymbol(isPinned ? "pin.fill" : "pin",
                                                       fallbacks: ["pin"],
                                                       accessibilityDescription: label),
                            label: label,
                            toolTip: isPinned ? "Unpin — return to the menu bar" : "Pin as a window",
                            isTab: false)
        // Pin's "on" reads as a selected seat — the same weight the current
        // screen wears, because it is the same statement about the same strip.
        pinButton.isEngaged = isPinned
        pinItem.label = label
    }

    // MARK: Actions

    @objc private func tabTapped(_ sender: Any?) {
        guard let view = sender as? NSView,
              let screen = SurfaceScreen.allCases.first(where: { tabItems[$0]?.view === view })
        else { return }
        onSelectScreen?(screen)
        // Host-confirmed: whatever the callback decided (it normally called
        // `setSelectedScreen` synchronously), the strip shows exactly that.
        applySelectionToTabs()
    }

    @objc private func pinTapped(_ sender: Any?) { onTogglePin?() }

    /// Resolve an SF Symbol, falling through `fallbacks` in order so an item
    /// is never glyph-less (the retired header's defense-in-depth idiom; all
    /// primary names are verified present back to the macOS 14 target).
    static func resolveSymbol(_ name: String, fallbacks: [String],
                              accessibilityDescription: String) -> NSImage? {
        for candidate in [name] + fallbacks {
            if let image = NSImage(systemSymbolName: candidate,
                                   accessibilityDescription: accessibilityDescription) {
                return image
            }
        }
        return nil
    }

    // MARK: Test-support hooks

    /// The toolbar's materialized items, in display order.
    var test_itemIdentifiers: [NSToolbarItem.Identifier] { toolbar.items.map(\.itemIdentifier) }
    /// The tabs' names, in tab order — spoken, not drawn.
    var test_tabLabels: [String] {
        SurfaceScreen.allCases.compactMap { tabItems[$0]?.label }
    }
    /// What VoiceOver is handed for each tab, in tab order. The item's `label`
    /// stops being the spoken name once the item carries a view, so the view
    /// has to carry it.
    var test_tabAccessibilityLabels: [String] {
        SurfaceScreen.allCases.compactMap { tabButton($0)?.accessibilityLabel() }
    }
    /// What the tabs DRAW, in tab order — empty strings once they are
    /// icon-only. The guard against a name creeping back onto the strip.
    var test_tabTitles: [String] {
        SurfaceScreen.allCases.compactMap { tabButton($0)?.title }
    }
    /// The tabs' tooltips, in tab order — where the name and shortcut live.
    var test_tabToolTips: [String] {
        SurfaceScreen.allCases.compactMap { tabButton($0)?.toolTip }
    }
    /// Whether every tab resolved a non-nil symbol image.
    var test_allTabImagesResolved: Bool {
        let buttons = SurfaceScreen.allCases.compactMap { tabButton($0) }
        return buttons.count == SurfaceScreen.allCases.count && buttons.allSatisfy { $0.image != nil }
    }
    /// The seat button behind an item, for tests that render real pixels.
    func test_tabButton(_ screen: SurfaceScreen) -> SurfaceToolbarSeatButton? { tabButton(screen) }
    var test_pinButton: SurfaceToolbarSeatButton? { pinButton }
    /// The index of the tab DRAWING the engaged seat, `nil` if none is, more
    /// than one if the strip ever marked two (which `test_engagedTabCount`
    /// catches).
    ///
    /// Reads the tab's own state — what it paints and what it speaks — rather
    /// than the controller's `selectedScreen`, which is the answer the caller
    /// already had. The version this replaced returned `selectedScreen.rawValue`
    /// unconditionally on macOS 14–25, so the suite stayed green while no cue
    /// was drawn at all.
    var test_selectedTabIndex: Int? {
        SurfaceScreen.allCases.first { tabButton($0)?.isEngaged == true }?.rawValue
    }
    var test_engagedTabCount: Int {
        SurfaceScreen.allCases.filter { tabButton($0)?.isEngaged == true }.count
    }
    /// Whether the strip marks EXACTLY the current screen.
    var test_onlySelectedTabIsMarked: Bool {
        test_engagedTabCount == 1 && test_selectedTabIndex == selectedScreen.rawValue
    }
    /// Whether every item in the strip — the three tabs AND Pin — wears the
    /// one seat control. The 2026-08-30 failure was half the strip converted.
    var test_everyItemWearsTheSeat: Bool {
        let views = toolbar.items.compactMap(\.view)
        return views.count == SurfaceScreen.allCases.count + 1
            && views.allSatisfy { $0 is SurfaceToolbarSeatButton }
    }
    /// Whether the pin item resolved a symbol image.
    var test_pinItemHasImage: Bool { pinButton?.image != nil }
    var test_pinItemLabel: String? { pinItem?.label }
    /// Fire a tab exactly as a click on it would — a REAL click through the
    /// button's own target/action, not a hand-run selector.
    func test_selectTab(_ screen: SurfaceScreen) {
        tabButton(screen)?.performClick(nil)
    }
    /// Simulate clicking Pin.
    func test_tapPin() { pinButton?.performClick(nil) }
}

// MARK: - NSToolbarDelegate

extension SurfaceToolbarController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // A `.space` BETWEEN the tabs, and a `.flexibleSpace` before Pin: they
        // had sat one pixel apart, so a click aimed at Pin could quit the app
        // instead. The gaps also keep every seat a discrete rounded rectangle —
        // adjacent items used to MERGE into one shared capsule on macOS 26+,
        // and the container then RESHAPED as the selection moved (Mixer gave
        // circle + capsule(2), Groups gave three circles, Settings gave
        // capsule(2) + circle). That is the wandering geometry the segmented
        // divider was, wearing a different hat.
        Array(SurfaceScreen.allCases.map(Self.tabItemIdentifier(for:))
                .flatMap { [$0, NSToolbarItem.Identifier.space] }.dropLast())
            + [.flexibleSpace,
               Self.pinItemIdentifier]
    }

    /// Deliberately EMPTY. This seam is what turns AppKit's own selection
    /// highlight on, and that highlight is the rounded square whose hover
    /// twin is a circle — the two-shapes-for-one-control defect the seat
    /// replaces. The tabs draw and speak their own selection instead; see
    /// `applySelectionToTabs`.
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let screen = SurfaceScreen.allCases
            .first(where: { Self.tabItemIdentifier(for: $0) == itemIdentifier }) {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = SurfaceToolbarSeatButton(
                frame: NSRect(origin: .zero, size: SurfaceToolbarSeat.size))
            button.target = self
            button.action = #selector(tabTapped(_:))
            button.configure(symbol: Self.resolveSymbol(screen.symbolName,
                                                        fallbacks: screen.fallbackSymbolNames,
                                                        accessibilityDescription: screen.label),
                             label: screen.label,
                             // No drawn name: the tabs are icon-only, so the
                             // name reaches the reader through this tooltip
                             // (which also carries ⌘1/⌘2/⌘3, riding the shell
                             // panel's key-equivalent seam), the accessibility
                             // label, and the shortcut itself.
                             toolTip: "\(screen.label) (⌘\(screen.keyEquivalent))",
                             isTab: true)
            item.view = button
            // The item's own NAME, for the overflow menu.
            item.label = screen.label
            // Navigation cannot live behind the overflow chevron.
            item.visibilityPriority = .high
            tabItems[screen] = item
            applySelectionToTabs()
            return item
        }

        switch itemIdentifier {
        case Self.pinItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = SurfaceToolbarSeatButton(
                frame: NSRect(origin: .zero, size: SurfaceToolbarSeat.size))
            button.target = self
            button.action = #selector(pinTapped(_:))
            item.view = button
            item.visibilityPriority = .high
            pinItem = item
            applyPinAppearance()
            return item

        default:
            return nil
        }
    }
}
