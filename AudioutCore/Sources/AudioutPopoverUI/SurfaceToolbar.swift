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
///   Pin and Quit are, so the header carries ONE button style. ICON-ONLY, and
///   deliberately so: names were tried on the items' `title` (#95, #97) and
///   removed again (Alec, 2026-09-03) because three translated labels would
///   widen the strip until AppKit swept the tabs into the overflow menu, and
///   primary navigation cannot live behind a chevron. Nothing is lost to a
///   reader: the tooltips ("Mixer (⌘1)"), the items' `label`s (VoiceOver and
///   the overflow menu) and ⌘1/⌘2/⌘3 all still carry the names, and none of
///   them costs strip width in any language;
/// - Pin and Quit as trailing bordered items.
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

    /// Fill behind the SELECTED tab's glyph. `.prominent` is the only way a
    /// standard toolbar item paints its own background, and it forces the
    /// glyph WHITE in both appearances — so this fill must stay dark enough
    /// for white to read on it in light AND dark mode. That rules out any
    /// SEMANTIC token, which inverts (near-black in light, near-white in
    /// dark) and would put white on white.
    ///
    /// It does NOT rule out an authored pair, and one value is not enough
    /// (live check, 2026-09-03). A single mid-dark neutral reads perfectly in
    /// light mode against the near-white unbordered capsule, and vanishes in
    /// dark mode, where the UNSELECTED capsule is already about this grey —
    /// three identical circles and no way to tell which screen you are on.
    /// The fill has to contrast with its NEIGHBOURS, not just carry white.
    ///
    /// So: darker in dark mode, not lighter. Both values keep a white glyph
    /// legible, and each sits well clear of the unselected capsule in its own
    /// appearance. Still NOT the gold family — gold means signal, and which
    /// screen you are on is chrome.
    static let selectedTabFill = NSColor(name: "selectedTabFill") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.08, alpha: 1)
            : NSColor(white: 0.35, alpha: 1)
    }

    static let pinItemIdentifier = NSToolbarItem.Identifier("SurfacePin")
    static let quitItemIdentifier = NSToolbarItem.Identifier("SurfaceQuit")

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
    /// The Quit item was clicked.
    var onQuit: (() -> Void)?

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
        if #available(macOS 13.0, *) {
        }
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

    /// The tabs wear the SAME control as Pin and Quit — a bordered toolbar
    /// item — so the header carries one button style rather than three (Alec,
    /// live review 2026-08-30: the custom-view tabs drew no chrome at all,
    /// leaving bare glyphs beside bordered circles and a glass lockup).
    /// Selection is the filled variant of that one control.
    private func applySelectionToTabs() {
        for (screen, item) in tabItems {
            let selected = screen == selectedScreen
            if #available(macOS 26.0, *) {
                item.style = selected ? .prominent : .plain
                item.backgroundTintColor = selected ? Self.selectedTabFill : nil
            }
            // Below macOS 26 there is no prominent style, so the glyph tint is
            // the whole cue — harmless to set on 26+, where prominent overrides it.
            item.image = Self.resolveSymbol(screen.symbolName,
                                            fallbacks: screen.fallbackSymbolNames,
                                            accessibilityDescription: screen.label)
        }
    }

    private func applyPinAppearance() {
        guard let pinItem else { return }
        let label = isPinned ? "Unpin" : "Pin"
        pinItem.image = Self.resolveSymbol(isPinned ? "pin.fill" : "pin", fallbacks: ["pin"],
                                           accessibilityDescription: label)
        pinItem.label = label
        pinItem.toolTip = isPinned ? "Unpin — return to the menu bar" : "Pin as a window"
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
    @objc private func quitTapped(_ sender: Any?) { onQuit?() }

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
    /// The index of the tab currently showing selected, `nil` if none does.
    var test_selectedTabIndex: Int? {
        guard #available(macOS 26.0, *) else { return selectedScreen.rawValue }
        return SurfaceScreen.allCases.first { tabItems[$0]?.style == .prominent }?.rawValue
    }
    /// Whether exactly the selected tab wears the filled treatment, and every
    /// tab wears the SAME bordered control Pin and Quit do.
    var test_onlySelectedTabIsFilled: Bool {
        guard #available(macOS 26.0, *) else { return true }
        return SurfaceScreen.allCases.allSatisfy { screen in
            guard let item = tabItems[screen] else { return false }
            let wantsFill = screen == selectedScreen
            return item.isBordered
                && (item.style == .prominent) == wantsFill
                && (item.backgroundTintColor != nil) == wantsFill
        }
    }
    /// Whether every tab is bordered — the same control as Pin and Quit.
    var test_allTabsAreBordered: Bool {
        let items = SurfaceScreen.allCases.compactMap { tabItems[$0] }
        return items.count == SurfaceScreen.allCases.count && items.allSatisfy(\.isBordered)
    }
    /// Whether Pin and Quit are bordered — the control the tabs now match.
    var test_pinItemIsBordered: Bool { pinItem?.isBordered == true }
    var test_quitItemIsBordered: Bool {
        toolbar.items.first { $0.itemIdentifier == Self.quitItemIdentifier }?.isBordered == true
    }
    /// Whether the pin/quit items resolved symbol images.
    var test_pinItemHasImage: Bool { pinItem?.image != nil }
    var test_pinItemLabel: String? { pinItem?.label }
    var test_quitItemHasImage: Bool {
        toolbar.items.first { $0.itemIdentifier == Self.quitItemIdentifier }?.image != nil
    }
    /// The word Quit shows, `nil` if the item never built.
    var test_quitItemTitle: String? {
        toolbar.items.first { $0.itemIdentifier == Self.quitItemIdentifier }?.title
    }
    /// Fire a tab exactly as a click on it would — a REAL click through the
    /// button's own target/action, not a hand-run selector.
    func test_selectTab(_ screen: SurfaceScreen) {
        guard let item = tabItems[screen] else { return }
        tabTapped(item)
    }
    /// Simulate clicking Pin / Quit.
    func test_tapPin() { pinTapped(nil) }
    func test_tapQuit() { quitTapped(nil) }
}

// MARK: - NSToolbarDelegate

extension SurfaceToolbarController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // A fixed `.space` between Pin and Quit: they sat one pixel apart, so a
        // click aimed at Pin could quit the app instead. Least-destructive
        // separation — Quit stays in the toolbar, it just stops being Pin's
        // neighbour.
        // A `.space` BETWEEN the tabs, the same separator Pin and Quit use.
        // Load-bearing, not cosmetic (live review 2026-08-30): adjacent
        // bordered items MERGE into one shared capsule on macOS 26+, and
        // `.prominent` then pulls the selected item out of that capsule to
        // avoid tinting its neighbours' background. The container therefore
        // RESHAPED as the selection moved — Mixer gave circle + capsule(2),
        // Groups gave three circles, Settings gave capsule(2) + circle. That is
        // the wandering-geometry bug the segmented divider was, wearing a
        // different hat. Spaced items never merge, so every tab is a discrete
        // circle in every state, matching Pin and Quit exactly.
        Array(SurfaceScreen.allCases.map(Self.tabItemIdentifier(for:))
                .flatMap { [$0, NSToolbarItem.Identifier.space] }.dropLast())
            + [.flexibleSpace,
               Self.pinItemIdentifier, .space, Self.quitItemIdentifier]
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
            // Bordered: the same control Pin and Quit are, so the header has
            // one button style.
            item.isBordered = true
            item.target = self
            item.action = #selector(tabTapped(_:))
            // The item's own NAME, for the overflow menu and VoiceOver.
            item.label = screen.label
            // No `title`: the tabs are icon-only, so the name reaches the
            // reader through the tooltip (which also carries ⌘1/⌘2/⌘3, riding
            // the shell panel's key-equivalent seam), the `label` above, and
            // the shortcut itself. Quit keeps its word — one short string that
            // no tab strip has to make room for.
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

        case Self.quitItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.isBordered = true
            // The word, not a glyph: the exit-door shape read as "sign out of
            // an account" in the launch review, and `power` on a panel full of
            // speakers reads as "turn the audio off".
            item.title = "Quit"
            item.label = "Quit"
            item.toolTip = "Quit Audiout"
            item.target = self
            item.action = #selector(quitTapped(_:))
            return item

        default:
            return nil
        }
    }
}
