// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterSharedUI

/// The one-surface app's **header strip** (U3, PLAN-ONE-SURFACE-032 "End
/// state" + owner addenda 2026-08-07): the floating controls layer of the
/// single panel that hosts all three screens. Supersedes this view's previous
/// life as the popover's title bar — the old "Open Groups editor" / "Settings"
/// buttons became the switcher's Groups / Settings tabs, and the centered
/// "Audiouter" title is gone (pinned mode's real window title bar carries the
/// app name; the unpinned bubble needs none).
///
/// Layout, left → right:
/// - a leading inset reserving the shell's standard close button, which the
///   window draws as titlebar chrome ON TOP of this strip (without it the
///   button lands on the Mixer tab — prototype-verified);
/// - the **tab-bar switcher**: three icon-over-label tabs (Mixer / Groups /
///   Settings) in the macOS toolbar-tabs idiom, rendered per the owner's
///   Apple Music reference — capsule segments sharing one faint capsule
///   lozenge, the SELECTED segment getting the filled (gold-washed) capsule.
///   ⌘1/⌘2/⌘3 select them from the keyboard (stock `NSButton.keyEquivalent`,
///   so the window's own key-equivalent dispatch does the routing — no event
///   monitor);
/// - trailing: **Pin** (`pin`/`pin.fill`, drives the shell's manner-profile
///   flip through the host) and **Quit**.
///
/// ## Three material tiers (owner addendum — translucent header)
///
/// The strip rides on one of three backgrounds, resolved live:
/// 1. macOS 26+ — `NSGlassEffectView` with the controls row as its
///    `contentView` (NEVER a sibling: the system owns the legibility
///    treatment), corner radius matched to the shell bubble, and a subtle warm
///    tint (gold at `glassTintAlpha` — the prototype's ~8% "read well").
/// 2. macOS 14–15 — `NSVisualEffectView` with `blendingMode = .withinWindow`,
///    frosting the app's own content under the strip. `.behindWindow` is
///    deliberately NOT used: it composites the desktop through the window,
///    which fights the opaque Warm Signal canvas and reads as a different
///    effect entirely.
/// 3. Reduce Transparency (any OS) — opaque warm fill (`canvasHi`) with a
///    bottom hairline. Borders belong ONLY here: Liquid Glass defines its edge
///    by refraction, so the translucent tiers draw NO hard border/hairline.
///
/// Tier 1 vs 2 is decided by the injected `osSupportsGlassHeader` seam (the
/// `SidebarViewController.osSupportsLiquidGlassSidebar` idiom — both branches
/// must be testable on any one machine); tier 3 re-resolves LIVE via
/// `accessibilityDisplayOptionsDidChangeNotification` (the A1 idiom), plus a
/// `test_reduceTransparencyOverride` seam for headless coverage of both sides.
///
/// Pure UI: taps route out through callbacks; the host (`AppSurfaceController`,
/// or `PopoverController` pre-cutover) owns what a tab selection means.
@MainActor
final class PopoverHeaderView: NSView {

    /// Header strip height: a 17pt symbol over an 11pt caption label with
    /// breathing room — close to a stock toolbar-tabs row. Prototype-verified.
    static let barHeight: CGFloat = 52

    /// Leading inset of the tab row, reserving the shell's standard close
    /// button (drawn by the window on top of this strip when unpinned).
    static let closeButtonReserve: CGFloat = 46

    /// The warm tint fed to `NSGlassEffectView` — gold at this alpha read well
    /// in the prototype (~8%); anything stronger overpowers the refraction.
    static let glassTintAlpha: CGFloat = 0.08

    /// Fill of the SELECTED tab's capsule (gold wash). Follows the accent
    /// dial automatically because it derives from `Tokens.Color.gold`.
    static let selectedCapsuleAlpha: CGFloat = 0.16

    /// Fill of the shared group lozenge behind all three tabs — the "one
    /// glass lozenge" of the Apple Music idiom, faint enough to read as a
    /// grouping wash, not a control.
    static let groupLozengeAlpha: CGFloat = 0.05

    /// Square side of the trailing Pin/Quit icon buttons (the popover header's
    /// established 28pt hit box, unchanged from its previous life).
    static let iconButtonSide: CGFloat = 28

    // MARK: Callbacks (host-owned meaning)

    /// A tab was clicked (or ⌘1/⌘2/⌘3 pressed). The host decides what a
    /// selection means; this view does NOT flip its own selection state —
    /// the host confirms via `setSelectedScreen` so header instances on other
    /// screens stay in sync through one path.
    var onSelectScreen: ((SurfaceScreen) -> Void)?
    /// The Pin button was clicked. `nil` (the pre-cutover popover host) makes
    /// the button inert.
    var onTogglePin: (() -> Void)?
    /// The Quit button was clicked.
    var onQuit: (() -> Void)?

    // MARK: State (pushed by the host)

    private(set) var selectedScreen: SurfaceScreen = .mixer
    private(set) var isPinned = false

    // MARK: Views

    private var tabButtons: [SurfaceScreen: NSButton] = [:]
    private var tabCapsules: [SurfaceScreen: CapsuleFillView] = [:]
    private let groupLozenge = CapsuleFillView()
    private let pinButton = NSButton()
    private let quitButton = NSButton()
    /// The controls row, re-hosted FRAME-based (autoresizing) into whichever
    /// material tier `rebuildBackgroundTier()` builds — constraints would
    /// reference a stale superview across the re-host.
    private let row = NSView()
    private var backgroundView: NSView?

    /// Whether THIS OS renders `NSGlassEffectView` (macOS 26+). Injected seam,
    /// same shape as `SidebarViewController.osSupportsLiquidGlassSidebar`:
    /// never read via a bare `#available` on the build path itself, so a test
    /// can exercise the frost fallback on a ≥26 machine and vice versa. The
    /// literal `#available` still guards the actual construction — a forced
    /// `true` on an older OS falls back to frost rather than crashing.
    nonisolated static var osSupportsGlassHeader: Bool {
        if #available(macOS 26.0, *) { return true } else { return false }
    }
    private let osSupportsGlass: Bool

    /// `nil` = read the live `accessibilityDisplayShouldReduceTransparency`.
    /// Tests drive both tiers of the opaque fallback with this.
    var test_reduceTransparencyOverride: Bool? {
        didSet { rebuildBackgroundTier() }
    }

    init(osSupportsGlassHeader: Bool = PopoverHeaderView.osSupportsGlassHeader) {
        self.osSupportsGlass = osSupportsGlassHeader
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: Self.barHeight))
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true
        buildRow()
        rebuildBackgroundTier()
        applySelectionAppearance()
        configureAccessibility()

        // Reduce Transparency (and Increase Contrast) arrive NEITHER through a
        // model push nor `viewDidChangeEffectiveAppearance` — the A1 idiom:
        // observe the workspace notification and re-resolve the tier live.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
        // The accent dial remaps `Tokens.Color.gold` app-internally, which no
        // AppKit appearance pass announces — instruments must repaint on the
        // token module's own notification (AudiouterSharedUI/AGENTS.md).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accentStyleDidChange),
            name: Tokens.accentStyleDidChangeNotification,
            object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Build

    private func buildRow() {
        row.autoresizingMask = [.width, .height]

        let tabStack = NSStackView()
        tabStack.orientation = .horizontal
        tabStack.spacing = 2
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        for screen in SurfaceScreen.allCases {
            tabStack.addArrangedSubview(makeTab(screen))
        }

        // The shared lozenge sits BEHIND the whole tab group (added before the
        // stack so it composites underneath), hugging the group's bounds a
        // touch taller than the buttons — the same ±3pt the selected capsule
        // uses, so the two shapes nest concentrically.
        groupLozenge.translatesAutoresizingMaskIntoConstraints = false
        groupLozenge.fillProvider = { Tokens.Color.label.withAlphaComponent(Self.groupLozengeAlpha) }
        row.addSubview(groupLozenge)
        row.addSubview(tabStack)

        configureTrailing(pinButton, symbol: "pin", accessibilityLabel: "Pin",
                          action: #selector(pinTapped))
        configureTrailing(quitButton, symbol: "power", accessibilityLabel: "Quit",
                          action: #selector(quitTapped))
        quitButton.toolTip = "Quit"
        let trailingStack = NSStackView(views: [pinButton, quitButton])
        trailingStack.orientation = .horizontal
        trailingStack.spacing = 6
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(trailingStack)

        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: row.leadingAnchor,
                                              constant: Self.closeButtonReserve),
            tabStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            groupLozenge.leadingAnchor.constraint(equalTo: tabStack.leadingAnchor),
            groupLozenge.trailingAnchor.constraint(equalTo: tabStack.trailingAnchor),
            groupLozenge.topAnchor.constraint(equalTo: tabStack.topAnchor, constant: -3),
            groupLozenge.bottomAnchor.constraint(equalTo: tabStack.bottomAnchor, constant: 3),

            trailingStack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            trailingStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
    }

    /// One icon-over-label tab: a borderless `NSButton` (17pt symbol above an
    /// 11pt caption) over its own selection capsule. The capsule is a separate
    /// draw-based view rather than button state so the fill re-resolves from
    /// `Tokens` on every repaint (appearance / Increase Contrast / accent dial
    /// all land for free — the layer-stamp trap in AudiouterSharedUI/AGENTS.md).
    private func makeTab(_ screen: SurfaceScreen) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let capsule = CapsuleFillView()
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.fillProvider = { Tokens.Color.gold.withAlphaComponent(Self.selectedCapsuleAlpha) }
        capsule.isFilled = false

        let button = NSButton()
        button.title = screen.label
        button.font = Tokens.Font.captionMedium
        button.image = Self.resolveSymbol(screen.symbolName,
                                          fallbacks: screen.fallbackSymbolNames,
                                          accessibilityDescription: screen.label)
        button.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        button.imagePosition = .imageAbove
        button.imageScaling = .scaleNone
        button.isBordered = false
        button.target = self
        button.action = #selector(tabTapped(_:))
        button.tag = screen.rawValue
        button.translatesAutoresizingMaskIntoConstraints = false
        // ⌘1/⌘2/⌘3: stock key-equivalent dispatch — the window routes the
        // keystroke to the button while the surface is key, no monitor needed.
        button.keyEquivalent = screen.keyEquivalent
        button.keyEquivalentModifierMask = [.command]
        button.setAccessibilityRole(.radioButton)
        button.setAccessibilityLabel(screen.label)
        button.toolTip = "\(screen.label) (⌘\(screen.keyEquivalent))"

        container.addSubview(capsule)
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),

            capsule.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            capsule.topAnchor.constraint(equalTo: container.topAnchor, constant: -3),
            capsule.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: 3),
        ])
        tabButtons[screen] = button
        tabCapsules[screen] = capsule
        return container
    }

    private func configureTrailing(_ button: NSButton, symbol: String,
                                   accessibilityLabel: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = Self.resolveSymbol(symbol, fallbacks: [],
                                          accessibilityDescription: accessibilityLabel)
        button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        button.imagePosition = .imageOnly
        button.title = ""
        button.bezelStyle = .accessoryBar
        button.isBordered = true
        button.showsBorderOnlyWhileMouseInside = true
        button.target = self
        button.action = action
        button.setAccessibilityLabel(accessibilityLabel)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.iconButtonSide),
            button.heightAnchor.constraint(equalToConstant: Self.iconButtonSide),
        ])
    }

    /// Resolve an SF Symbol, falling through `fallbacks` in order so a button
    /// is never blank on an OS missing the first choice (all three tab symbols
    /// are verified present back to the macOS 14 deployment target; the
    /// fallbacks are defense in depth, same idiom as the previous header).
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

    // MARK: Material tiers

    /// Which background the header is currently wearing.
    enum MaterialTier { case glass, frost, opaque }

    private var reduceTransparency: Bool {
        test_reduceTransparencyOverride
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// (Re)build the background for the current tier and re-host `row` inside
    /// it. Runs on init and whenever Reduce Transparency flips.
    private func rebuildBackgroundTier() {
        backgroundView?.removeFromSuperview()
        row.removeFromSuperview()

        let background: NSView
        if reduceTransparency {
            // Tier 3: opaque warm fill + bottom hairline — the ONE tier that
            // draws a border (glass defines its edge by refraction; a stroked
            // edge on the translucent tiers is explicitly out, owner addendum).
            let flat = OpaqueHeaderFillView()
            flat.addSubview(row)
            background = flat
        } else if osSupportsGlass, #available(macOS 26.0, *) {
            // Tier 1: Liquid Glass. Controls as `contentView`, never a
            // sibling — the system needs to own legibility treatments.
            let glass = NSGlassEffectView()
            glass.cornerRadius = Tokens.Layout.panelCornerRadius
            glass.tintColor = Tokens.Color.gold.withAlphaComponent(Self.glassTintAlpha)
            glass.contentView = row
            background = glass
        } else {
            // Tier 2: frost the app's own content scrolling under the strip.
            let frost = NSVisualEffectView()
            frost.material = .headerView
            frost.blendingMode = .withinWindow
            frost.state = .active
            frost.addSubview(row)
            background = frost
        }

        background.autoresizingMask = [.width, .height]
        background.frame = bounds
        addSubview(background)
        row.frame = background.bounds
        backgroundView = background
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        rebuildBackgroundTier()
        applySelectionAppearance()
    }

    /// The accent dial moved (`Tokens.accentStyle`): every gold-derived fill
    /// and tint must repaint. Draw-based views need only invalidation; the
    /// buttons re-apply their tints (which resolve through `Tokens` again).
    @objc private func accentStyleDidChange() {
        applySelectionAppearance()
    }

    // MARK: State pushed by the host

    func setSelectedScreen(_ screen: SurfaceScreen) {
        selectedScreen = screen
        applySelectionAppearance()
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        applySelectionAppearance()
    }

    private func applySelectionAppearance() {
        for (screen, button) in tabButtons {
            let isSelected = screen == selectedScreen
            let tint = isSelected ? Tokens.Color.gold : Tokens.Color.secondaryLabel
            button.contentTintColor = tint
            button.attributedTitle = NSAttributedString(
                string: screen.label,
                attributes: [.font: Tokens.Font.captionMedium, .foregroundColor: tint])
            button.state = isSelected ? .on : .off
            tabCapsules[screen]?.isFilled = isSelected
        }
        pinButton.image = Self.resolveSymbol(isPinned ? "pin.fill" : "pin", fallbacks: ["pin"],
                                             accessibilityDescription: isPinned ? "Unpin" : "Pin")
        pinButton.contentTintColor = isPinned ? Tokens.Color.gold : Tokens.Color.secondaryLabel
        pinButton.setAccessibilityLabel(isPinned ? "Unpin" : "Pin")
        pinButton.toolTip = isPinned ? "Unpin — return to the menu bar"
                                     : "Pin as a window"
        quitButton.contentTintColor = Tokens.Color.secondaryLabel
        groupLozenge.needsDisplay = true
    }

    // MARK: Actions

    @objc private func tabTapped(_ sender: NSButton) {
        guard let screen = SurfaceScreen(rawValue: sender.tag) else { return }
        onSelectScreen?(screen)
    }

    @objc private func pinTapped() { onTogglePin?() }
    @objc private func quitTapped() { onQuit?() }

    // MARK: Accessibility

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Audiouter header")
    }

    // MARK: Test-support hooks

    /// The material tier the header actually resolved to.
    var test_materialTier: MaterialTier {
        switch backgroundView {
        case is OpaqueHeaderFillView: return .opaque
        case is NSVisualEffectView: return .frost
        default: return .glass
        }
    }
    /// Whether every tab resolved a non-nil symbol image.
    var test_allTabImagesResolved: Bool {
        SurfaceScreen.allCases.allSatisfy { tabButtons[$0]?.image != nil }
    }
    /// Whether the Pin / Quit buttons resolved symbol images.
    var test_pinButtonHasImage: Bool { pinButton.image != nil }
    var test_quitButtonHasImage: Bool { quitButton.image != nil }
    /// A tab's key equivalent, for the ⌘1/⌘2/⌘3 wiring assertions.
    func test_tabKeyEquivalent(_ screen: SurfaceScreen) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard let button = tabButtons[screen] else { return nil }
        return (button.keyEquivalent, button.keyEquivalentModifierMask)
    }
    /// Whether a tab currently renders the filled selection capsule.
    func test_isTabCapsuleFilled(_ screen: SurfaceScreen) -> Bool? {
        tabCapsules[screen]?.isFilled
    }
    /// Fire a tab's real target/action, exactly as a click or ⌘-shortcut would.
    func test_selectTab(_ screen: SurfaceScreen) {
        guard let button = tabButtons[screen] else { return }
        tabTapped(button)
    }
    /// Simulate tapping Pin / Quit.
    func test_tapPin() { pinTapped() }
    func test_tapQuit() { quitTapped() }
}

// MARK: - CapsuleFillView

/// A draw-based capsule fill (radius = half its height, so the shape stays a
/// true capsule at any size). Draw-based rather than a stamped layer color so
/// the `Tokens`-derived fill re-resolves every repaint — appearance flips,
/// Increase Contrast, and the accent dial all land without a re-stamp path
/// (the layer-color trap, AudiouterSharedUI/AGENTS.md). Non-interactive.
@MainActor
final class CapsuleFillView: NSView {
    /// Resolves the fill at draw time. A provider, not a stored `NSColor`,
    /// so alpha-derived token fills are re-derived per repaint too.
    var fillProvider: (() -> NSColor)?
    var isFilled = true { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard isFilled, let fill = fillProvider?() else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds,
                     xRadius: bounds.height / 2,
                     yRadius: bounds.height / 2).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - OpaqueHeaderFillView

/// The Reduce-Transparency tier: an opaque warm fill (`canvasHi`) with a 1px
/// bottom hairline — the ONLY header tier that draws a border. `draw(_:)`
/// fills rather than layer colors so both resolve live against the current
/// appearance and Increase Contrast variants.
@MainActor
final class OpaqueHeaderFillView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Tokens.Color.canvasHi.setFill()
        dirtyRect.fill()
        Tokens.Color.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
