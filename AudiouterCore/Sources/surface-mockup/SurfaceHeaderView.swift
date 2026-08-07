// SPDX-License-Identifier: GPL-2.0-or-later
//
// Throwaway prototype (see main.swift). Not shipped, not linked by the app.

import AppKit
import AudiouterSharedUI

/// Which screen a tab selects.
enum SurfaceTab: Int, CaseIterable {
    case mixer, groups, settings

    var label: String {
        switch self {
        case .mixer: return "Mixer"
        case .groups: return "Groups"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .mixer: return "slider.horizontal.3"
        case .groups: return "hifispeaker.2"
        case .settings: return "gearshape"
        }
    }
}

/// A flat theme-colored fill — the Reduce Transparency tier's background. A
/// `draw(_:)` fill rather than a layer color so the `NSColor` resolves live
/// against the current appearance instead of freezing at assignment.
@MainActor
final class FlatFillView: NSView {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The prototype's floating controls layer: three icon-over-label tabs in the
/// macOS toolbar-tabs idiom, plus Pin and Quit trailing, riding on one of three
/// material tiers (PLAN-ONE-SURFACE-032 "End state", header addendum):
///
/// 1. macOS 26+ — `NSGlassEffectView` with the tab row as its `contentView`
///    (never a sibling; the system owns the legibility treatment).
/// 2. macOS 14–15 — `NSVisualEffectView`, `blendingMode = .withinWindow`, so it
///    frosts the app's own content scrolling under it rather than the desktop.
/// 3. Reduce Transparency, any OS — plain opaque fill from the active theme.
///
/// One instance per screen: the shell sizes content per `NSViewController`
/// instance, so each screen is its own controller and carries its own header.
@MainActor
final class SurfaceHeaderView: NSView {

    /// Header strip height. Prototype value — a 17pt symbol over an 11pt label
    /// with breathing room, close to a stock toolbar-tabs row.
    static let height: CGFloat = 52

    /// Leading inset of the tab row. Reserves the shell's standard close
    /// button, which the window draws as titlebar chrome ON TOP of this view —
    /// without the inset it lands on the Mixer tab.
    private static let closeButtonReserve: CGFloat = 46

    var onSelect: ((SurfaceTab) -> Void)?
    var onTogglePin: (() -> Void)?
    var onQuit: (() -> Void)?

    private var tabButtons: [SurfaceTab: NSButton] = [:]
    private var tabPills: [SurfaceTab: NSBox] = [:]
    private let pinButton = NSButton()
    private let quitButton = NSButton()
    private let row = NSView()
    private var backgroundView: NSView?

    private(set) var selected: SurfaceTab = .mixer
    private(set) var isPinned = false
    private var theme: MockupTheme = .warmSignal

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildControls()
        applyBackground()
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: Content

    /// Builds `row` — the tabs and the trailing Pin/Quit pair. `row` is hosted
    /// FRAME-based (autoresizing) by whichever material tier
    /// `applyBackground()` picks, so it can be re-parented between tiers
    /// without carrying constraints that reference a stale superview.
    private func buildControls() {
        row.autoresizingMask = [.width, .height]

        let tabStack = NSStackView()
        tabStack.orientation = .horizontal
        tabStack.spacing = 2
        tabStack.translatesAutoresizingMaskIntoConstraints = false

        for tab in SurfaceTab.allCases {
            let (container, pill, button) = makeTab(tab)
            tabButtons[tab] = button
            tabPills[tab] = pill
            tabStack.addArrangedSubview(container)
        }

        configureTrailing(pinButton, symbol: "pin", accessibility: "Pin", action: #selector(pinTapped))
        configureTrailing(quitButton, symbol: "power", accessibility: "Quit", action: #selector(quitTapped))

        let trailingStack = NSStackView(views: [pinButton, quitButton])
        trailingStack.orientation = .horizontal
        trailingStack.spacing = 6
        trailingStack.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(tabStack)
        row.addSubview(trailingStack)

        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: row.leadingAnchor,
                                              constant: Self.closeButtonReserve),
            tabStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            trailingStack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            trailingStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
    }

    private func makeTab(_ tab: SurfaceTab) -> (NSView, NSBox, NSButton) {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Selection pill: an `NSBox` rather than a raw layer fill so the tint
        // stays a live `NSColor` and follows appearance changes.
        let pill = NSBox()
        pill.boxType = .custom
        pill.borderWidth = 0
        pill.cornerRadius = 8
        pill.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton()
        button.title = tab.label
        button.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label)
        button.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        button.imagePosition = .imageAbove
        button.imageScaling = .scaleNone
        button.isBordered = false
        button.font = Tokens.Font.captionMedium
        button.target = self
        button.action = #selector(tabTapped(_:))
        button.tag = tab.rawValue
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityRole(.radioButton)

        container.addSubview(pill)
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),

            pill.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pill.topAnchor.constraint(equalTo: container.topAnchor, constant: -3),
            pill.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: 3),
        ])
        return (container, pill, button)
    }

    private func configureTrailing(_ button: NSButton, symbol: String,
                                   accessibility: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        button.imagePosition = .imageOnly
        button.title = ""
        button.bezelStyle = .accessoryBar
        button.showsBorderOnlyWhileMouseInside = true
        button.target = self
        button.action = action
        button.toolTip = accessibility
        button.setAccessibilityLabel(accessibility)
    }

    // MARK: Material tiers

    /// (Re)build the background for the current tier and re-host `row` inside
    /// it. Runs on init and on every theme change — the glass tint is
    /// per-theme, and `tintColor` is simplest to set on a fresh view.
    private func applyBackground() {
        backgroundView?.removeFromSuperview()
        row.removeFromSuperview()

        // `AIRPLAY_MOCKUP_HEADER_TIER=glass|frost|opaque` forces a tier, so all
        // three can be looked at on one machine without changing a system
        // setting. Unset picks the tier the running Mac would really get.
        let forcedTier = ProcessInfo.processInfo.environment["AIRPLAY_MOCKUP_HEADER_TIER"]
        let wantsOpaque = forcedTier == "opaque"
            || (forcedTier == nil && NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        let wantsGlass = forcedTier == "glass" || (forcedTier == nil && !wantsOpaque)

        let background: NSView
        if wantsOpaque {
            let flat = FlatFillView()
            flat.fill = theme.raised
            flat.addSubview(row)
            background = flat
        } else if wantsGlass, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Tokens.Layout.panelCornerRadius
            glass.tintColor = theme.glassTint
            glass.contentView = row
            background = glass
        } else {
            let frost = NSVisualEffectView()
            frost.material = theme.frostMaterial
            // `.withinWindow`, never `.behindWindow`: the surface's canvas is
            // opaque, so compositing the desktop through it reads as a
            // different effect entirely (plan, header tier 2).
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

    /// Which tier this header actually resolved to, for the run's console log.
    var resolvedTierDescription: String {
        switch backgroundView {
        case is FlatFillView: return "opaque fill (Reduce Transparency)"
        case is NSVisualEffectView: return "NSVisualEffectView .withinWindow"
        default: return "NSGlassEffectView"
        }
    }

    // MARK: State

    func setTheme(_ theme: MockupTheme) {
        self.theme = theme
        applyBackground()
        applyTheme()
    }

    func setSelected(_ tab: SurfaceTab) {
        selected = tab
        applyTheme()
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        applyTheme()
    }

    private func applyTheme() {
        for (tab, button) in tabButtons {
            let isSelected = tab == selected
            let tint = isSelected ? theme.accent : theme.secondaryInk
            button.contentTintColor = tint
            button.attributedTitle = NSAttributedString(
                string: tab.label,
                attributes: [.font: Tokens.Font.captionMedium, .foregroundColor: tint])
            tabPills[tab]?.fillColor = isSelected ? theme.tabSelectionFill : Tokens.Color.clear
        }
        pinButton.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin",
                                  accessibilityDescription: "Pin")
        pinButton.contentTintColor = isPinned ? theme.accent : theme.secondaryInk
        quitButton.contentTintColor = theme.secondaryInk
    }

    // MARK: Actions

    @objc private func tabTapped(_ sender: NSButton) {
        guard let tab = SurfaceTab(rawValue: sender.tag) else { return }
        onSelect?(tab)
    }

    @objc private func pinTapped() { onTogglePin?() }
    @objc private func quitTapped() { onQuit?() }
}
