// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The one-surface header, as a REAL window-attached `NSToolbar` (owner
/// decision D1, live build review 2026-08-07 — supersedes the custom
/// `PopoverHeaderView` strip and its three-tier glass/frost/opaque material
/// machinery; the system toolbar provides Liquid Glass on macOS 26+, the older
/// material below, and Reduce Transparency handling on its own):
///
/// - the three screens as three tabs. The CURRENT one shows its name beside
///   its glyph; the other two are icon-only. The tooltips ("Mixer (⌘1)"), the
///   accessibility labels and ⌘1/⌘2/⌘3 still carry all three names as they
///   always did;
/// - Pin as a trailing item, standing OUTSIDE the tabs' capsule.
///
/// **One name at a time, and a capped one** (owner's call, 2026-09-04, third pass:
/// "if I were to click on groups or speakers, then it would expand out to show
/// the name"). Names were on all three items' `title` once (#95, #97) and were
/// removed on 2026-09-03 because three translated labels widened the strip
/// until AppKit swept the tabs into the overflow menu, and primary navigation
/// cannot live behind a chevron. Two things make that impossible here rather
/// than merely unlikely: only the selected tab is ever expanded, so the strip
/// carries ONE name however many languages it is read in; and that name is
/// clamped to `SurfaceToolbarSeat.maxNameWidth` and truncates past it, so no
/// word in any language can push the strip wider than
/// `widestCapsuleWidth` + Pin = 260 pt of the fixed 653 pt surface.
/// `SurfaceToolbarTests.theStripCannotOutgrowTheSurfaceInAnyLanguage` asserts
/// it against a name no translator could produce.
///
/// The name is REVEALED, not faded: the seat itself grows to the right of the
/// glyph and the name is clipped until there is room for it, which is the
/// gesture the owner described. It travels on `FoldAnimator`, the app's one
/// reveal clock — so it opens at the same `Tokens.Motion.collapseRevealDuration`
/// every card body and inserted row does, and Reduce Motion is answered where
/// that driver already answers it: the width settles synchronously, with no
/// frame of travel.
///
/// **The three tabs are ONE capsule** (owner's call, 2026-09-04, second pass). A
/// single `NSToolbarItem` carries a `SurfaceToolbarTabCapsule`: one
/// pill-shaped surface drawn once, with the three tabs as buttons layered over
/// it. The current tab is marked by a soft rounded highlight INSIDE that pill,
/// hover is the same highlight weaker, and an idle tab draws nothing of its
/// own — the grouping macOS 26 uses in its own toolbars. What that replaces:
/// three separate circular seats, one per tab, each its own island.
///
/// **Pin is the standalone button beside the group.** The reference puts such
/// a button outside the pill, optionally behind a thin divider; here a
/// `.flexibleSpace` already throws the full width of the strip between them,
/// so a divider would sit orphaned in the middle of that gap and none is
/// drawn.
///
/// Underneath every pass is the same reason for drawing the strip at all:
/// AppKit draws a BORDERED item's hover state as a circle and its selected
/// state as a rounded square, two shapes for two STATES of one control, and
/// neither shape is settable. Pin wears the same authored highlight as a tab,
/// because half a conversion — bare glyphs beside bordered circles — is what
/// failed live review on 2026-08-30. `SurfaceToolbarSeat` holds every shape,
/// size and wash strength in the strip.
///
/// **REVERSED 2026-09-05: one shape for every STATE, two shapes for the two
/// kinds of ITEM.** Until this review the strip drew one rounded rectangle
/// everywhere, tabs and Pin alike. The owner asked for Pin to be "a circle instead
/// of an oval", so Pin's seat is now square and cut at half its height, while
/// the three tabs keep the stadium they wear inside their shared pill. The
/// 2026-08-30 rule is NOT what changed: every item is still the same authored
/// control drawn by the same cell at the same three weights, which is what
/// "convert the whole strip or none of it" was about. What is no longer true
/// is that one radius fits every item — `SurfaceToolbarSeat.seatCornerRadius`
/// derives it from each seat's own height, so the shapes cannot drift apart.
/// The same review made the capsule as tall as Pin and made the tab highlight
/// concentric with the pill; both fall out of that one rule.
///
/// The `NSToolbar` itself stays: it is the window's one unified title-bar
/// strip, and it supplies the system material and the Reduce Transparency
/// handling that the retired custom header had to hand-build.
///
/// **Four earlier attempts, so none of them comes back:**
/// - an `NSToolbarItemGroup` segmented control drew a hairline between
///   adjacent segments and suppressed the one beside the SELECTED segment, so
///   the divider moved with the selection and no API draws them consistently;
/// - custom-view tabs beside the bordered Pin item left bare glyphs next to
///   bordered circles — two styles in one header, which is why the conversion
///   is all of the strip or none of it;
/// - an authored fill put every cue inside `if #available(macOS 26.0, *)`
///   while the package deploys to 14.2, so macOS 14–25 showed three identical
///   circles and no current screen at all — and the suite stayed green
///   because the seams asserted the intent rather than the pixels. It also
///   had to clear the UNSELECTED capsule, and in dark mode that capsule
///   already sat at the same grey, so the selected tab rendered as the
///   darkest thing in the strip;
/// - three `.space`-separated items, each drawing its own seat, read as three
///   islands rather than one control.
///
/// None of those traps survives here: nothing in `SurfaceToolbarSeat` or
/// `SurfaceToolbarTabCapsule` is behind an availability check; the capsule is
/// one drawn surface and the highlight is painted ON it, never instead of it,
/// so a selected tab can only end up lighter than its ground in dark mode; the
/// capsule's width is derived from the tabs themselves, so the ONE thing that
/// can change it is a tab opening its name, and even that is bounded whatever
/// the name says; and the tests below sample real pixels.
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
    /// The centred wordmark + icon (owner, 2026-09-05).
    static let brandItemIdentifier = NSToolbarItem.Identifier("SurfaceBrand")

    /// The ONE item carrying all three tabs. Three identifiers, one per
    /// screen, is what let the tabs drift apart into three islands; one item
    /// is what makes the capsule a single drawn surface.
    static let tabsItemIdentifier = NSToolbarItem.Identifier("SurfaceTabs")

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

    private var tabsItem: NSToolbarItem?
    private var tabButtons: [SurfaceScreen: SurfaceToolbarSeatButton] = [:]
    private var pinItem: NSToolbarItem?
    /// Pin draws the SAME seat as a tab (owner, 2026-09-05: style Pin
    /// like the tabs, keep it on the right). Cut at half its own height
    /// by `SurfaceToolbarSeat.seatCornerRadius`, and square, so it comes
    /// out a circle. A bordered system item would render as glass ONLY
    /// when no custom view shares the strip — the capsule is one, so a
    /// bordered Pin beside it read as a flat square.
    private var pinButton: SurfaceToolbarSeatButton? {
        pinItem?.view as? SurfaceToolbarSeatButton
    }

    private func tabButton(_ screen: SurfaceScreen) -> SurfaceToolbarSeatButton? {
        tabButtons[screen]
    }



    override init() {
        toolbar = NSToolbar(identifier: "SurfaceToolbar")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        // The brand rides the WINDOW's centre line, not the midpoint of
        // whatever space the tabs and Pin leave between them — those are
        // different points, because the tab group is far wider than Pin
        // (owner, 2026-09-05: the wordmark must be dead centre).
        toolbar.centeredItemIdentifiers = [Self.brandItemIdentifier]
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
    /// `animated` is false only while the strip is being BUILT: the first tab
    /// arrives already named, because the header names the current screen at
    /// all times and there is nothing yet for a reveal to explain.
    private func applySelectionToTabs(animated: Bool = true) {
        for screen in SurfaceScreen.allCases {
            let isCurrent = (screen == selectedScreen)
            tabButton(screen)?.isEngaged = isCurrent
            // The name and the highlight are the same statement about the same
            // tab, set from the same flag in the same pass, so the strip can
            // never name one screen and mark another.
            tabButton(screen)?.setNameRevealed(isCurrent, animated: animated)
        }
    }

    private func applyPinAppearance() {
        guard let pinItem, let pinButton else { return }
        let label = isPinned ? "Unpin" : "Pin"
        pinButton.configure(symbol: Self.resolveSymbol(isPinned ? "pin.fill" : "pin",
                                                       fallbacks: ["pin"],
                                                       accessibilityDescription: label),
                            label: label,
                            toolTip: isPinned ? "Return to the menu bar" : "Pin as a window",
                            isTab: false)
        // Pinned reads as a selected seat — the same weight the current screen
        // wears, because it is the same statement about the same strip.
        pinButton.isEngaged = isPinned
        pinItem.label = label
    }

    // MARK: Actions

    @objc private func tabTapped(_ sender: Any?) {
        guard let view = sender as? NSView,
              let screen = SurfaceScreen.allCases.first(where: { tabButtons[$0] === view })
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
    /// The one capsule the three tabs live in.
    var test_tabCapsule: SurfaceToolbarTabCapsule? {
        tabsItem?.view as? SurfaceToolbarTabCapsule
    }
    /// What VoiceOver is handed for each tab, in tab order. The item's `label`
    /// stops being the spoken name once the item carries a view, so the view
    /// has to carry it.
    var test_tabAccessibilityLabels: [String] {
        SurfaceScreen.allCases.compactMap { tabButton($0)?.accessibilityLabel() }
    }
    /// What the tabs DRAW, in tab order: the current screen's name and two
    /// empty strings. Measured from the seat's own bounds, so a tab that
    /// carries a name it is too narrow to show reads as empty here — which is
    /// exactly what the two idle tabs are.
    var test_tabDrawnNames: [String] {
        SurfaceScreen.allCases.compactMap { screen -> String? in
            guard let tab = tabButton(screen) else { return nil }
            return tab.test_visibleNameWidth > 0 ? tab.test_name : ""
        }
    }
    /// How wide the tabs' capsule asks to be right now.
    var test_capsuleFittingWidth: CGFloat? { test_tabCapsule?.fittingSize.width }
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
    var test_pinItem: NSToolbarItem? { pinItem }
    var test_pinButton: SurfaceToolbarSeatButton? { pinButton }
    var test_brandView: SurfaceBrandView? {
        toolbar.items.compactMap { $0.view as? SurfaceBrandView }.first
    }
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
    /// Whether the strip is exactly the capsule plus Pin, and every clickable
    /// thing in it — the three tabs inside the capsule AND Pin outside it —
    /// wears the one authored control. The 2026-08-30 failure was half the
    /// strip converted.
    var test_everyItemWearsTheSeat: Bool {
        // Every CONTROL in the strip wears the authored seat: the three tabs
        // inside the capsule, and Pin outside it. The brand lockup is the one
        // custom view that is not a seat — it is decorative, not a control.
        let views = toolbar.items.compactMap(\.view)
        guard let capsule = views.compactMap({ $0 as? SurfaceToolbarTabCapsule }).first,
              let pin = pinButton, !pin.isDescendant(of: capsule)
        else { return false }
        let tabs = SurfaceScreen.allCases.compactMap(tabButton)
        return tabs.count == SurfaceScreen.allCases.count
            && tabs.allSatisfy { $0.isDescendant(of: capsule) }
    }
    /// Whether the pin item resolved a symbol image.
    var test_pinItemHasImage: Bool { pinButton?.image != nil }
    var test_pinItemLabel: String? { pinItem?.label }
    /// Fire a tab exactly as a click on it would — a REAL click through the
    /// button's own target/action, not a hand-run selector.
    func test_selectTab(_ screen: SurfaceScreen) {
        tabButton(screen)?.performClick(nil)
    }
    /// Simulate clicking Pin. A bordered item has no view to click, so this
    /// sends the item's own action the way the toolbar would.
    func test_tapPin() { pinButton?.performClick(nil) }
}

// MARK: - NSToolbarDelegate

extension SurfaceToolbarController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Two items and the width of the strip between them. The tabs are ONE
        // item because they are one capsule; letting AppKit space three tab
        // items is what produced three islands, and letting it merge them is
        // what produced a container that reshaped as the selection moved
        // (measured on macOS 26: Mixer gave circle + capsule(2), Groups three
        // circles, Settings capsule(2) + circle). A capsule we draw ourselves
        // has neither behaviour.
        [Self.tabsItemIdentifier, Self.brandItemIdentifier, .flexibleSpace, Self.pinItemIdentifier]
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
        switch itemIdentifier {
        case Self.tabsItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let buttons = SurfaceScreen.allCases.map { screen -> SurfaceToolbarSeatButton in
                let button = SurfaceToolbarSeatButton(
                    frame: NSRect(origin: .zero, size: SurfaceToolbarSeat.size))
                button.target = self
                button.action = #selector(tabTapped(_:))
                button.configure(symbol: Self.resolveSymbol(screen.symbolName,
                                                            fallbacks: screen.fallbackSymbolNames,
                                                            accessibilityDescription: screen.label),
                                 label: screen.label,
                                 // The tooltip stays even though the current
                                 // tab now draws its name: it is where the
                                 // ⌘1/⌘2/⌘3 shortcut is written down (the
                                 // shell panel's key-equivalent seam runs it),
                                 // and it is the only place the two tabs you
                                 // are NOT on can be named.
                                 toolTip: "\(screen.label) (⌘\(screen.keyEquivalent))",
                                 isTab: true)
                tabButtons[screen] = button
                return button
            }
            item.view = SurfaceToolbarTabCapsule(tabs: buttons)
            // Navigation cannot live behind the overflow chevron.
            item.visibilityPriority = .high
            tabsItem = item
            applySelectionToTabs(animated: false)
            return item

        case Self.pinItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            // Pin wears a seat button, `isTab: false`, which draws the circle.
            let button = SurfaceToolbarSeatButton(
                frame: NSRect(origin: .zero, size: SurfaceToolbarSeat.pinSize))
            button.target = self
            button.action = #selector(pinTapped(_:))
            item.view = button
            item.visibilityPriority = .high
            pinItem = item
            applyPinAppearance()
            return item

        case Self.brandItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = SurfaceBrandView()
            // Decorative — never swept into the overflow chevron, never a
            // click target.
            item.visibilityPriority = .high
            return item

        default:
            return nil
        }
    }
}

/// The header's centred brand: the wordmark alone (owner, 2026-09-05).
///
/// WHY NO MARK. The hero render is a portrait drawing — 504 x 796 of painted
/// content in a 1024 square — and the strip is 34 pt tall, so anything that
/// fits vertically paints about 17 pt wide, with its gold halo band at
/// roughly 4 pt. At that size the tweeter, the dust caps and the halo are at
/// or below one device pixel, and the cabinet's own gradient runs from
/// `#3A3E47` to `#16181C`, which straddles both header grounds: whichever
/// ground you pick, one end of the speaker merges into it. That is the
/// "elements just disappear" the owner reported, and no plate fixes it —
/// three were tried (a fixed dark circle, the selected tab's wash, a
/// recessed `well`) and each only moved which half vanished. The mark still
/// greets at 96 pt in `SurfaceSplashView`, which is the size it was drawn
/// for.
///
/// The word does not have that problem: it is text in a semantic ink, so it
/// inverts with the appearance by construction and cannot half-vanish.
///
/// `Tokens.Font.wordmark` is ClashDisplay-Semibold, the one face reserved for
/// setting "Audiout" and nothing else; it falls back to the bold system font
/// when the `.otf` is not registered (every context but the assembled
/// `.app`), so this never draws nothing.
///
/// Decorative — not an accessibility element, because the window already
/// names itself and the tabs speak the current screen.
final class SurfaceBrandView: NSView {
    /// The wordmark's own centre in this view's coordinates — the point that
    /// must sit on the window's centre line. The label IS the view now, so
    /// this is simply the middle; the trailing gutter that used to offset the
    /// lockup went with the mark.
    var test_wordmarkCenterX: CGFloat { wordmarkLabel.frame.midX }
    private let wordmarkLabel = NSTextField(labelWithString: "Audiout")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let wordmark = wordmarkLabel
        wordmark.translatesAutoresizingMaskIntoConstraints = false
        wordmark.font = Tokens.Font.wordmark(size: 17)
        // `label2`, not `label`: the brand names the window, it does not
        // compete with the tab that says which screen you are on.
        wordmark.textColor = Tokens.Color.label2
        wordmark.setAccessibilityElement(false)
        addSubview(wordmark)

        NSLayoutConstraint.activate([
            wordmark.leadingAnchor.constraint(equalTo: leadingAnchor),
            wordmark.trailingAnchor.constraint(equalTo: trailingAnchor),
            wordmark.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: SurfaceToolbarSeat.pinDiameter),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
