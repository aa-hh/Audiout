// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The one-surface header, as a REAL window-attached `NSToolbar` (owner
/// decision D1, live build review 2026-08-07 — supersedes the custom
/// `PopoverHeaderView` strip and its three-tier glass/frost/opaque material
/// machinery; the system toolbar provides Liquid Glass on macOS 26+, the older
/// material below, and Reduce Transparency handling on its own):
///
/// - the three screens as three separate BORDERED items — the same control
///   Pin is, so the header carries ONE button style. ICON-ONLY, and
///   deliberately so: names were tried on the items' `title` (#95, #97) and
///   removed again (Alec, 2026-09-03) because three translated labels would
///   widen the strip until AppKit swept the tabs into the overflow menu, and
///   primary navigation cannot live behind a chevron. Nothing is lost to a
///   reader: the tooltips ("Mixer (⌘1)"), the items' `label`s (VoiceOver and
///   the overflow menu) and ⌘1/⌘2/⌘3 all still carry the names, and none of
///   them costs strip width in any language;
/// - Pin as a trailing bordered item (Quit left the strip for the menus).
///
/// **Why the tabs are bordered items and not custom views** (live review
/// 2026-08-30). Killing the `NSToolbarItemGroup` killed the wandering
/// segment divider — a segmented control draws a hairline between adjacent
/// segments and suppresses the one beside the SELECTED segment, so the line
/// moved with the selection and no API draws them consistently. But the group
/// was also the only thing giving the tabs any chrome: replacing it with
/// custom-view items left three bare glyphs beside Pin/Quit's bordered
/// circles — two styles in one header. Bordered items
/// have no separators to draw (they are not one segmented control) AND wear
/// the same circle as Pin and Quit, so the divider stays dead and the header
/// reads as one control set. Selection is `.prominent` — the filled variant of
/// that same circle — and the tabs are `.space`-separated so that fill can
/// never reshape the strip (see `toolbarDefaultItemIdentifiers`).
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

    /// The tabs wear the SAME control as Pin — a bordered toolbar
    /// item — so the header carries one button style rather than three (Alec,
    /// live review 2026-08-30: the custom-view tabs drew no chrome at all,
    /// leaving bare glyphs beside bordered circles and a glass lockup).
    /// Selection is the filled variant of that one control.
    /// Mark the current screen through AppKit's OWN toolbar selection
    /// (`selectedItemIdentifier` + `toolbarSelectableItemIdentifiers`), not an
    /// authored fill.
    ///
    /// This is the Mac idiom and the iOS one differs on purpose: iOS puts
    /// top-level navigation in a tab bar, where the selected tab is a tint and
    /// a filled glyph. macOS has no tab bar at all — Apple's own guidance is
    /// that tab views serve that role — so a toolbar that navigates marks its
    /// place the way AppKit draws it, and AppKit has drawn that highlight
    /// since 10.0.
    ///
    /// What this replaces, and why: every cue used to sit inside
    /// `if #available(macOS 26.0, *)` while the package deploys to 14.2, so
    /// macOS 14–25 showed three identical circles and no current screen — and
    /// the suite reported green, because the seams asserted the intent rather
    /// than the pixels. The authored fill could not be rescued by tuning
    /// either: it has to clear the UNSELECTED capsule, and in dark mode that
    /// capsule already sat at the same grey, so the selected tab rendered as
    /// the darkest thing in the strip — the user's own location reading as an
    /// absence.
    ///
    /// It also carries the accessibility state. `.prominent` is a rendering
    /// property that VoiceOver never speaks; `selectedItemIdentifier` is the
    /// selection AppKit itself exposes.
    private func applySelectionToTabs() {
        toolbar.selectedItemIdentifier = Self.tabItemIdentifier(for: selectedScreen)
    }

    private func applyPinAppearance() {
        guard let pinItem else { return }
        let label = isPinned ? "Unpin" : "Pin"
        pinItem.image = Self.resolveSymbol(isPinned ? "pin.fill" : "pin", fallbacks: ["pin"],
                                           accessibilityDescription: label)
        pinItem.label = label
        pinItem.toolTip = isPinned ? "Return to the menu bar" : "Pin as a window"
    }

    // MARK: Actions

    @objc private func tabTapped(_ sender: Any?) {
        guard let item = sender as? NSToolbarItem,
              let screen = SurfaceScreen.allCases
                  .first(where: { Self.tabItemIdentifier(for: $0) == item.itemIdentifier })
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
    /// What the tabs DRAW, in tab order — empty strings once they are
    /// icon-only. The guard against a name creeping back onto the strip.
    var test_tabTitles: [String] {
        SurfaceScreen.allCases.compactMap { tabItems[$0]?.title }
    }
    /// The tabs' tooltips, in tab order — where the name and shortcut live.
    var test_tabToolTips: [String] {
        SurfaceScreen.allCases.compactMap { tabItems[$0]?.toolTip }
    }
    /// Whether every tab resolved a non-nil symbol image.
    var test_allTabImagesResolved: Bool {
        let items = SurfaceScreen.allCases.compactMap { tabItems[$0] }
        return items.count == SurfaceScreen.allCases.count && items.allSatisfy { $0.image != nil }
    }
    /// The index of the tab the TOOLBAR reports as selected, `nil` if none is.
    ///
    /// Reads `selectedItemIdentifier` — what AppKit actually draws and speaks
    /// — rather than the old `.prominent` check, which was gated on macOS 26
    /// and fell back to returning `selectedScreen.rawValue` unconditionally:
    /// on 14–25 it reported the answer the caller already had, so the suite
    /// stayed green while no cue was drawn at all.
    var test_selectedTabIndex: Int? {
        guard let selected = toolbar.selectedItemIdentifier else { return nil }
        return SurfaceScreen.allCases.first { Self.tabItemIdentifier(for: $0) == selected }?.rawValue
    }
    /// Whether the toolbar marks EXACTLY the current screen, and every tab
    /// still wears the bordered control Pin does.
    var test_onlySelectedTabIsMarked: Bool {
        guard toolbar.selectedItemIdentifier == Self.tabItemIdentifier(for: selectedScreen) else {
            return false
        }
        let items = SurfaceScreen.allCases.compactMap { tabItems[$0] }
        return items.count == SurfaceScreen.allCases.count && items.allSatisfy(\.isBordered)
    }
    /// Whether every tab is bordered — the same control as Pin.
    var test_allTabsAreBordered: Bool {
        let items = SurfaceScreen.allCases.compactMap { tabItems[$0] }
        return items.count == SurfaceScreen.allCases.count && items.allSatisfy(\.isBordered)
    }
    /// Whether Pin is bordered — the control the tabs match.
    var test_pinItemIsBordered: Bool { pinItem?.isBordered == true }
    /// Whether the pin item resolved a symbol image.
    var test_pinItemHasImage: Bool { pinItem?.image != nil }
    var test_pinItemLabel: String? { pinItem?.label }
    /// Fire a tab exactly as a click on it would — a REAL click through the
    /// button's own target/action, not a hand-run selector.
    func test_selectTab(_ screen: SurfaceScreen) {
        guard let item = tabItems[screen] else { return }
        tabTapped(item)
    }
    /// Simulate clicking Pin.
    func test_tapPin() { pinTapped(nil) }
}

// MARK: - NSToolbarDelegate

extension SurfaceToolbarController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // A `.space` BETWEEN the tabs.
        // Load-bearing, not cosmetic (live review 2026-08-30): adjacent
        // bordered items MERGE into one shared capsule on macOS 26+, and
        // `.prominent` then pulls the selected item out of that capsule to
        // avoid tinting its neighbours' background. The container therefore
        // RESHAPED as the selection moved — Mixer gave circle + capsule(2),
        // Groups gave three circles, Settings gave capsule(2) + circle. That is
        // the wandering-geometry bug the segmented divider was, wearing a
        // different hat. Spaced items never merge, so every tab is a discrete
        // circle in every state, matching Pin exactly.
        Array(SurfaceScreen.allCases.map(Self.tabItemIdentifier(for:))
                .flatMap { [$0, NSToolbarItem.Identifier.space] }.dropLast())
            + [.flexibleSpace,
               Self.pinItemIdentifier]
    }

    /// The three screens are the selectable set — this is what turns on
    /// AppKit's selection highlight at all. Without it `selectedItemIdentifier`
    /// is stored and never drawn.
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SurfaceScreen.allCases.map(Self.tabItemIdentifier(for:))
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
            // Bordered: the same control Pin is, so the header has one button
            // style.
            item.isBordered = true
            item.target = self
            item.action = #selector(tabTapped(_:))
            item.image = Self.resolveSymbol(screen.symbolName,
                                            fallbacks: screen.fallbackSymbolNames,
                                            accessibilityDescription: screen.label)
            // The item's own NAME, for the overflow menu and VoiceOver.
            item.label = screen.label
            // No `title`: the tabs are icon-only, so the name reaches the
            // reader through the tooltip (which also carries ⌘1/⌘2/⌘3, riding
            // the shell panel's key-equivalent seam), the `label` above, and
            // the shortcut itself.
            item.toolTip = "\(screen.label) (⌘\(screen.keyEquivalent))"
            tabItems[screen] = item
            applySelectionToTabs()
            return item
        }

        switch itemIdentifier {
        case Self.pinItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.isBordered = true
            item.target = self
            item.action = #selector(pinTapped(_:))
            pinItem = item
            applyPinAppearance()
            return item

        default:
            return nil
        }
    }
}
