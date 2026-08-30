// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// One screen tab in the header: an icon-only button whose SELECTED state is a
/// neutral filled disc behind the glyph.
///
/// Three of these replace the single `NSToolbarItemGroup` the header used to
/// carry (live review 2026-08-29). The group drew the selection natively, but
/// it drew it as a SEGMENTED control — and a segmented control puts a hairline
/// separator between adjacent segments while suppressing the one next to the
/// selected segment. So the strip showed one divider with Mixer selected, none
/// with Groups, one on the other side with Settings: a line that moved when
/// nothing about the tabs had changed. There is no API to draw the separators
/// consistently, so the fix is to stop being one segmented control. Separate
/// toolbar items merge into a single Liquid Glass capsule on macOS 26+ with no
/// separators at all, and the selection is ours to draw.
///
/// The disc is deliberately ``Tokens/Color/engagedChrome`` and NOT the gold
/// family: gold means signal — in the mix, carrying audio — and which screen
/// you are looking at is chrome, not signal. Same reasoning that keeps the
/// mute pill and the row washes neutral.
@MainActor
final class SurfaceTabButton: NSButton {

    /// The screen this tab switches to.
    let screen: SurfaceScreen

    /// Side of the button's square hit box, and so the disc's diameter. Sized
    /// to sit inside the unified strip alongside the bordered Pin/Quit items.
    static let side: CGFloat = 28

    /// Alpha of the selected tab's ``Tokens/Color/engagedChrome`` disc. Sits at
    /// the TOP of that token's documented alpha ladder — level with the mute
    /// pill rather than the row washes — for the reason the ladder gives: a
    /// glyph-scale fill is small, and needs the extra weight to read at all.
    static let selectionWashAlpha: CGFloat = 0.22

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            applySelectionTreatment()
        }
    }

    init(screen: SurfaceScreen, target: AnyObject?, action: Selector) {
        self.screen = screen
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        image = SurfaceToolbarController.resolveSymbol(
            screen.symbolName, fallbacks: screen.fallbackSymbolNames,
            accessibilityDescription: screen.label)
        // The tab names lost their on-screen labels with the icon-only strip;
        // the tooltip and the spoken label are what carry them (plus ⌘1/⌘2/⌘3,
        // which ride the shell panel's key-equivalent seam).
        toolTip = "\(screen.label) (⌘\(screen.keyEquivalent))"
        // A tab is one option out of three, not an independent switch — the
        // role the segmented group used to report, kept by hand so VoiceOver
        // still announces "selected" on the one you are on.
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(screen.label)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.side / 2
        applySelectionTreatment()
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The selected disc is a static `CGColor` on the button's own backing
    /// layer — drawing only, behavior/keyboard/VoiceOver untouched. Same idiom
    /// as the mute pill (`DeviceRowView.updateMuteTint`), including its
    /// consequence: a `CGColor` does not follow the appearance, so this
    /// re-stamps on every light/dark or Increase-Contrast switch.
    private func applySelectionTreatment() {
        contentTintColor = isSelected ? Tokens.Color.engagedChrome : Tokens.Color.secondaryLabel
        setAccessibilityValue(isSelected)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelected
                ? Tokens.Color.engagedChrome.withAlphaComponent(Self.selectionWashAlpha).cgColor
                : nil
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySelectionTreatment()
    }

    /// Whether the selected disc is currently painted (test seam).
    var test_hasSelectionDisc: Bool { layer?.backgroundColor != nil }
}

/// The one-surface header, as a REAL window-attached `NSToolbar` (owner
/// decision D1, live build review 2026-08-07 — supersedes the custom
/// `PopoverHeaderView` strip and its three-tier glass/frost/opaque material
/// machinery; the system toolbar provides Liquid Glass on macOS 26+, the older
/// material below, and Reduce Transparency handling on its own):
///
/// - the three screens as three separate `SurfaceTabButton` items, ICON-ONLY
///   (`toolbar.displayMode = .iconOnly`) and deliberately so: on macOS 26+
///   (reproduced on 27.0) every label-showing display mode spills tab names
///   beside the strip as loose text. The tab names survive the missing labels —
///   per-tab tooltips ("Mixer (⌘1)"), the items' `label`s (VoiceOver and the
///   overflow menu), and ⌘1/⌘2/⌘3;
/// - the brand mark beside "Audiout" as a centered LOCKUP item
///   (`centeredItemIdentifiers`) — the one place the app names itself in the
///   header, both profiles. The mark is decorative; the wordmark is what
///   VoiceOver reads, so the name is spoken once;
/// - Pin and Quit as trailing bordered items.
///
/// **The name's glass capsule is not removable, and stays** (live review
/// 2026-08-29). macOS 26+ draws EVERY toolbar item inside an
/// `NSGlassEffectView` platter — verified by walking the item view's ancestor
/// chain, and `NSToolbarItem` offers no opt-out. Moving the lockup to a
/// titlebar accessory row escapes the platter, and was built and rejected: a
/// second header line costs more than the capsule does. So the capsule stays
/// and the lockup is given room inside it instead — see
/// `lockupHorizontalInset`.
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
/// Lives in AudioutPopoverUI, not the shell: the header names the three
/// screens, and the shell stays content-agnostic.
@MainActor
final class SurfaceToolbarController: NSObject {

    /// Side of the centered brand mark's square box. Sized so the halo's thin
    /// top ring survives the macOS 26/27 Liquid Glass capsule's compositing
    /// (see the lockup builder) while staying inside the unified strip so it
    /// does not grow the toolbar. Alec's "the one constant" — bump it here.
    static let markSide: CGFloat = 22

    /// Padding above and below the brand lockup inside its capsule. Bounded,
    /// not chosen: `markSide + 2 * lockupVerticalInset` must stay within the
    /// unified strip's height, or the strip grows (see `chromeTopInset`).
    static let lockupVerticalInset: CGFloat = 7

    /// Padding at each END of the brand lockup. Deliberately DOUBLE the
    /// vertical (Alec, 2026-08-29): the capsule sizes itself to this stack, so
    /// this inset is the capsule's, and at the vertical value the wordmark sat
    /// close enough to the glass edge to read as a cramped chip rather than a
    /// title. Horizontal is the free axis — widening it costs nothing, while
    /// the vertical one is pinned by the strip.
    static let lockupHorizontalInset: CGFloat = 14

    static let titleItemIdentifier = NSToolbarItem.Identifier("SurfaceTitle")
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

    private var tabButtons: [SurfaceScreen: SurfaceTabButton] = [:]
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
        applySelectionToTabs()
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        applyPinAppearance()
    }

    private func applySelectionToTabs() {
        for (screen, button) in tabButtons {
            button.isSelected = screen == selectedScreen
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
        guard let button = sender as? SurfaceTabButton else { return }
        onSelectScreen?(button.screen)
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
    /// The tabs' labels, in tab order.
    var test_tabLabels: [String] {
        SurfaceScreen.allCases.compactMap { tabButtons[$0]?.screen.label }
    }
    /// Whether every tab resolved a non-nil symbol image.
    var test_allTabImagesResolved: Bool {
        let buttons = SurfaceScreen.allCases.compactMap { tabButtons[$0] }
        return buttons.count == SurfaceScreen.allCases.count && buttons.allSatisfy { $0.image != nil }
    }
    /// The index of the tab currently showing selected, `nil` if none does.
    var test_selectedTabIndex: Int? {
        SurfaceScreen.allCases.first { tabButtons[$0]?.isSelected == true }?.rawValue
    }
    /// Whether exactly the selected tab paints its neutral disc.
    var test_onlySelectedTabHasDisc: Bool {
        SurfaceScreen.allCases.allSatisfy { screen in
            guard let button = tabButtons[screen] else { return false }
            return button.test_hasSelectionDisc == (screen == selectedScreen)
        }
    }
    /// The centered app-name label's text, `nil` if the item never built.
    var test_centeredTitleText: String? { titleLabel?.stringValue }
    /// Whether the centered lockup's brand mark resolved its image.
    var test_centeredMarkHasImage: Bool { markView?.image != nil }
    /// Whether the mark scales DOWN to fit its box (never clipping).
    var test_centeredMarkScalesToFit: Bool { markView?.imageScaling == .scaleProportionallyDown }
    /// The centered lockup's fitting height — must sit within the strip so
    /// nothing clips. `0` when the item never built.
    var test_centeredLockupFittingHeight: CGFloat { markView?.superview?.fittingSize.height ?? 0 }
    /// The horizontal padding the lockup actually applies at each end.
    var test_centeredLockupHorizontalInset: CGFloat {
        (markView?.superview as? NSStackView)?.edgeInsets.left ?? 0
    }
    /// Whether that mark is decorative (the wordmark speaks the name).
    var test_centeredMarkIsDecorative: Bool { markView?.isAccessibilityElement() == false }
    /// Whether the pin/quit items resolved symbol images.
    var test_pinItemHasImage: Bool { pinItem?.image != nil }
    var test_pinItemLabel: String? { pinItem?.label }
    var test_quitItemHasImage: Bool {
        toolbar.items.first { $0.itemIdentifier == Self.quitItemIdentifier }?.image != nil
    }
    /// A tab's live view, for geometry assertions about where the strip sits.
    func test_tabView(for screen: SurfaceScreen) -> NSView? { tabButtons[screen] }
    /// Fire a tab exactly as a click on it would — a REAL click through the
    /// button's own target/action, not a hand-run selector.
    func test_selectTab(_ screen: SurfaceScreen) {
        tabButtons[screen]?.performClick(nil)
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
        SurfaceScreen.allCases.map(Self.tabItemIdentifier(for:))
            + [.flexibleSpace, Self.titleItemIdentifier, .flexibleSpace,
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
            let button = SurfaceTabButton(screen: screen, target: self,
                                          action: #selector(tabTapped(_:)))
            button.isSelected = screen == selectedScreen
            item.view = button
            // The item's own NAME, for the overflow menu and VoiceOver.
            item.label = screen.label
            tabButtons[screen] = button
            return item
        }

        switch itemIdentifier {
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
            // the whole figure renders inside the box.
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
            // The capsule sizes itself to this stack, so these insets ARE the
            // capsule's padding. The two axes are not the same number on
            // purpose — see `lockupHorizontalInset`.
            lockup.edgeInsets = NSEdgeInsets(top: Self.lockupVerticalInset,
                                             left: Self.lockupHorizontalInset,
                                             bottom: Self.lockupVerticalInset,
                                             right: Self.lockupHorizontalInset)
            // TRAP: the halo is a THIN gold ring at the very top of the figure,
            // and on macOS 26/27 the centered item renders inside a Liquid Glass
            // capsule (`NSGlassEffectView`) whose compositing ERASES that ring
            // when the mark is small — the halo has too few pixels at ~16 pt to
            // survive the effect, and its top comes out sliced flat. This is NOT
            // a view-bounds clip (every ancestor is `clipsToBounds = false`) and
            // NOT the image view (a 16 pt retina render off-glass shows the full
            // round halo), so tying the box to the wordmark's ~16 pt height —
            // the smallest the mark can be — was exactly the worst case and left
            // the halo clipped. `Self.markSide` is the smallest box at which the
            // halo survives the glass with margin (verified against real
            // system-rendered captures, 20 pt threshold); it stays well inside
            // the unified strip's height, so the strip does not grow and the
            // measured chrome inset is unchanged. A CONSTANT box (not tied to
            // the label) so the 1024 px image's intrinsic size can never leak
            // into the lockup's fitting height.
            NSLayoutConstraint.activate([
                mark.widthAnchor.constraint(equalToConstant: Self.markSide),
                mark.heightAnchor.constraint(equalToConstant: Self.markSide),
            ])
            item.view = lockup
            // The item's own NAME, for the customization sheet and the
            // overflow menu — the lockup is a view, and an unnamed item shows
            // up as a blank entry there.
            item.label = "Audiout"
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
            // An EXIT shape, not a speaker-power shape: `power` on a panel full
            // of speakers reads as "turn the audio off", which is the one thing
            // this button does not do. (SF Symbols 3 — safe on the macOS 14
            // floor; `power` stays as the fallback.)
            item.image = Self.resolveSymbol("rectangle.portrait.and.arrow.right",
                                            fallbacks: ["power"],
                                            accessibilityDescription: "Quit")
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
