// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The one-surface header, as a REAL window-attached `NSToolbar` (owner
/// decision D1, live build review 2026-08-07 — supersedes the custom
/// `PopoverHeaderView` strip and its three-tier glass/frost/opaque material
/// machinery; the system toolbar provides Liquid Glass on macOS 26+, the older
/// material below, and Reduce Transparency handling on its own):
///
/// - the three screens as an `NSToolbarItemGroup` with
///   `selectionMode = .selectOne` — the system draws the capsule selection
///   natively, ICON-ONLY (`toolbar.displayMode = .iconOnly`) and deliberately
///   so: on macOS 26+ (reproduced on 27.0) every label-showing display mode —
///   `.iconAndLabel`, `.labelOnly`, `.default` — builds the group's picker
///   WITHOUT its interactive expanded view, and the strip degrades to an empty
///   glass capsule with the tab names spilled beside it as loose text and all
///   three segments dead: a click lands on an inert placeholder (Pin and Quit,
///   plain items, kept working). The tab names survive the missing labels —
///   per-segment tooltips ("Mixer (⌘1)"), the subitems' `label`s (VoiceOver
///   and the overflow menu), and ⌘1/⌘2/⌘3;
/// - the brand mark beside "Audiout" as a centered LOCKUP item
///   (`centeredItemIdentifiers`) — the one place the app names itself in the
///   header, both profiles. The mark is decorative; the wordmark is what
///   VoiceOver reads, so the name is spoken once;
/// - Pin and Quit as trailing bordered items.
///
/// One toolbar per process: unlike the retired per-screen header instances,
/// the toolbar belongs to the shell WINDOW, so there is nothing to keep in
/// sync across screens — `AppSurfaceController` pushes state into this one
/// object. Selection is HOST-CONFIRMED, same contract as the old header: a
/// click only reports through `onSelectScreen`, and the segmented state is
/// re-asserted from the host-confirmed `selectedScreen` afterward, so the
/// group can never drift from the screen actually shown.
///
/// ⌘1/⌘2/⌘3 do NOT live here: a toolbar item group carries no per-segment key
/// equivalents, so the surface installs them on the shell panel's
/// `keyEquivalentHandler` seam instead.
///
/// Lives in AudioutPopoverUI, not the shell: the toolbar names the three
/// screens, and the shell stays content-agnostic.
@MainActor
final class SurfaceToolbarController: NSObject {

    static let tabsItemIdentifier = NSToolbarItem.Identifier("SurfaceTabs")
    static let titleItemIdentifier = NSToolbarItem.Identifier("SurfaceTitle")
    static let pinItemIdentifier = NSToolbarItem.Identifier("SurfacePin")
    static let quitItemIdentifier = NSToolbarItem.Identifier("SurfaceQuit")

    /// A tab was clicked. The host decides what a selection means; the group's
    /// segmented state is re-asserted from `selectedScreen` after this returns
    /// (the host confirms via `setSelectedScreen`).
    var onSelectScreen: ((SurfaceScreen) -> Void)?
    /// The Pin item was clicked.
    var onTogglePin: (() -> Void)?
    /// The Quit item was clicked.
    var onQuit: (() -> Void)?

    // MARK: State (pushed by the host)

    private(set) var selectedScreen: SurfaceScreen = .mixer
    private(set) var isPinned = false

    let toolbar: NSToolbar

    private var tabsGroup: NSToolbarItemGroup?
    private var pinItem: NSToolbarItem?
    private var titleLabel: NSTextField?
    private var markView: NSImageView?

    override init() {
        toolbar = NSToolbar(identifier: "SurfaceToolbar")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        if #available(macOS 13.0, *) {
            toolbar.centeredItemIdentifiers = [Self.titleItemIdentifier]
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
        tabsGroup?.selectedIndex = screen.rawValue
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        applyPinAppearance()
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

    @objc private func tabsGroupSelected(_ sender: Any?) {
        guard let group = tabsGroup,
              let screen = SurfaceScreen(rawValue: group.selectedIndex) else { return }
        onSelectScreen?(screen)
        // Host-confirmed: whatever the callback decided (it normally called
        // `setSelectedScreen` synchronously), the control shows exactly that.
        group.selectedIndex = selectedScreen.rawValue
    }

    @objc private func pinTapped(_ sender: Any?) { onTogglePin?() }
    @objc private func quitTapped(_ sender: Any?) { onQuit?() }

    /// Resolve an SF Symbol, falling through `fallbacks` in order so an item
    /// is never glyph-less (the retired header's defense-in-depth idiom; all
    /// primary names are verified present back to the macOS 14 target).
    private static func resolveSymbol(_ name: String, fallbacks: [String],
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
    /// The tab group's segment labels, in tab order.
    var test_tabLabels: [String] { tabsGroup?.subitems.map(\.label) ?? [] }
    /// Whether every tab segment resolved a non-nil symbol image.
    var test_allTabImagesResolved: Bool {
        guard let group = tabsGroup, group.subitems.count == SurfaceScreen.allCases.count
        else { return false }
        return group.subitems.allSatisfy { $0.image != nil }
    }
    /// The segment index the group currently shows selected.
    var test_selectedTabIndex: Int? { tabsGroup?.selectedIndex }
    /// The centered app-name label's text, `nil` if the item never built.
    var test_centeredTitleText: String? { titleLabel?.stringValue }
    /// Whether the centered lockup's brand mark resolved its image.
    var test_centeredMarkHasImage: Bool { markView?.image != nil }
    /// Whether the mark scales DOWN to fit its box (never clipping — Task A).
    var test_centeredMarkScalesToFit: Bool { markView?.imageScaling == .scaleProportionallyDown }
    /// The centered lockup's fitting height — must sit within the strip so
    /// nothing clips. `0` when the item never built.
    var test_centeredLockupFittingHeight: CGFloat { markView?.superview?.fittingSize.height ?? 0 }
    /// Whether that mark is decorative (the wordmark speaks the name).
    var test_centeredMarkIsDecorative: Bool { markView?.isAccessibilityElement() == false }
    /// Whether the pin/quit items resolved symbol images.
    var test_pinItemHasImage: Bool { pinItem?.image != nil }
    var test_pinItemLabel: String? { pinItem?.label }
    var test_quitItemHasImage: Bool {
        toolbar.items.first { $0.itemIdentifier == Self.quitItemIdentifier }?.image != nil
    }
    /// Fire a tab exactly as a click on its segment would: flip the segmented
    /// state, then run the group's real action.
    func test_selectTab(_ screen: SurfaceScreen) {
        tabsGroup?.selectedIndex = screen.rawValue
        tabsGroupSelected(tabsGroup)
    }
    /// Simulate clicking Pin / Quit.
    func test_tapPin() { pinTapped(nil) }
    func test_tapQuit() { quitTapped(nil) }
}

// MARK: - NSToolbarDelegate

extension SurfaceToolbarController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.tabsItemIdentifier, .flexibleSpace, Self.titleItemIdentifier,
         .flexibleSpace, Self.pinItemIdentifier, Self.quitItemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.tabsItemIdentifier:
            let screens = SurfaceScreen.allCases
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: screens.map {
                    Self.resolveSymbol($0.symbolName, fallbacks: $0.fallbackSymbolNames,
                                       accessibilityDescription: $0.label) ?? NSImage()
                },
                selectionMode: .selectOne,
                labels: screens.map(\.label),
                target: self,
                action: #selector(tabsGroupSelected(_:)))
            for (index, screen) in screens.enumerated() where index < group.subitems.count {
                group.subitems[index].toolTip = "\(screen.label) (⌘\(screen.keyEquivalent))"
            }
            group.selectedIndex = selectedScreen.rawValue
            tabsGroup = group
            return group

        case Self.titleItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let label = NSTextField(labelWithString: "Audiout")
            label.font = NSFont.titleBarFont(ofSize: NSFont.systemFontSize)
            label.textColor = .labelColor
            label.setAccessibilityRole(.staticText)
            // The brand mark leads the wordmark, one lockup. The image is
            // DECORATIVE — the label beside it already speaks the name, and two
            // elements saying "Audiout" is the name spoken twice.
            let mark = NSImageView()
            mark.image = BrandMark.image
            // Scale the portrait mark DOWN to fit its box, never up past it, so
            // the whole figure renders un-clipped.
            mark.imageScaling = .scaleProportionallyDown
            mark.setAccessibilityElement(false)
            mark.translatesAutoresizingMaskIntoConstraints = false
            let lockup = NSStackView(views: [mark, label])
            lockup.orientation = .horizontal
            lockup.alignment = .centerY
            // 4, not the usual 8: the mark is a PORTRAIT figure inside a square
            // image, so its own transparent margin already contributes ~4 pt of
            // air on the wordmark's side.
            lockup.spacing = 4
            // The mark box is pinned to the wordmark's own height and no taller.
            // The unified strip does NOT grow to fit an oversized custom item,
            // and there is no separate title bar to borrow height from (owner:
            // no separate title bar ever), so a fixed 22 pt box overran the
            // strip's usable height — clipping the mark's top against the strip
            // and the backing bubble's rounded corner. Bounding it to the text
            // the strip already fits keeps the whole lockup inside the strip,
            // centreY, un-clipped. A CONSTANT box (not an equal-height tie to
            // the label) so the 1024 px image's intrinsic size can never leak
            // into the lockup's fitting height; `.scaleProportionallyDown` fits
            // the portrait figure inside it.
            let markSide = ceil(label.fittingSize.height)
            NSLayoutConstraint.activate([
                mark.widthAnchor.constraint(equalToConstant: markSide),
                mark.heightAnchor.constraint(equalToConstant: markSide),
            ])
            item.view = lockup
            item.label = ""
            titleLabel = label
            markView = mark
            return item

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
            item.image = Self.resolveSymbol("power", fallbacks: [],
                                            accessibilityDescription: "Quit")
            item.label = "Quit"
            item.toolTip = "Quit"
            item.target = self
            item.action = #selector(quitTapped(_:))
            return item

        default:
            return nil
        }
    }
}
