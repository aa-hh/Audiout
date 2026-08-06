// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterSharedUI

/// The popover's **header bar** (task A) — a borderless toolbar-style strip at
/// the very top of the panel, above the System card, styled per the macOS HIG for
/// borderless title-bar controls (like SoundSource's title-bar icons).
///
/// Layout, left → right:
/// - a **centered title** ("Audiouter", medium ~14pt, label color); and
/// - three right-aligned, stock `NSButton` (`bezelStyle = .accessoryBar` — the
///   system's borderless toolbar-glyph bezel: no outline at rest, a soft
///   rounded-rect highlight on hover/press), image-only icon buttons:
///   1. **Open Groups editor** — a system SF Symbol
///      (`hifispeaker.and.homepod.mini.badge.plus.fill`, template-rendered,
///      verified non-nil at runtime with graceful fallbacks).
///      Opens the mixer window (where group membership editing lives) via the
///      host's existing open-mixer path.
///   2. **Settings** — SF Symbol `gearshape`. Wired to the Settings window
///      by the host's `onOpenSettings` callback.
///   3. **Quit** — SF Symbol `power`, the trailing-most button. Terminates
///      the app via the host's `onQuit` callback.
///
/// The title is *centered* over the whole bar while the buttons float on the
/// trailing edge, so the title stays visually centered regardless of the button
/// cluster width (the buttons overlap the centered title's layout region without
/// shifting it).
///
/// Pure UI: taps route back through callbacks so `PopoverController` wires them to
/// `GroupController` / the app. The view never talks to a backend directly.
@MainActor
final class PopoverHeaderView: NSView {

    /// Square side length of each header icon button (task: header legibility pass,
    /// 2026-07-22). The product owner's complaint was that the three icon
    /// buttons (Groups/Settings/Quit) were hard to parse at a glance; he
    /// suggested "bigger" as the likely fix even with the same glyphs. There is
    /// no macOS HIG number for a borderless *accessoryBar* toolbar-glyph button
    /// specifically (the HIG's 44×44pt minimum target is an iOS/touch figure,
    /// not applicable to a pointer-driven desktop bar). Instead this sizes off
    /// Apple's own first-party borderless-toolbar precedent: Control Center's
    /// module tiles and Music.app's mini-player transport buttons both render
    /// as ~28pt square hit boxes around a glyph that fills roughly half the
    /// box, leaving even, generous padding on all sides. 28pt (up from the
    /// previous 26×22 non-square box) is "slightly larger" per his ask while
    /// staying a compact toolbar control, not a full-size button.
    static let iconButtonSide: CGFloat = 28

    /// Horizontal gap between adjacent header icon buttons. Widened slightly
    /// from the previous 2pt so three now-bigger 28pt squares still read as
    /// discrete buttons rather than a fused strip.
    static let iconButtonSpacing: CGFloat = 6

    /// Inset of the trailing-most button (Quit) from the bar's trailing edge.
    static let iconButtonTrailingInset: CGFloat = 10

    /// Header bar height — compact toolbar strip. Grown from 34 to fit the
    /// larger `iconButtonSide` (28pt) with even vertical padding above and
    /// below the button cluster, matching the "square, evenly padded" ask:
    /// `(barHeight - iconButtonSide) / 2` = 5pt of clearance on top and bottom.
    static let barHeight: CGFloat = 38

    /// Tapped the "Open Groups editor" button — the host opens the mixer window.
    var onOpenGroupsEditor: (() -> Void)?
    /// Tapped Settings — wired to open the Settings window.
    var onOpenSettings: (() -> Void)?
    /// Tapped Quit (far-right header button) — the host terminates the app.
    var onQuit: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Audiouter")
    private let groupsButton = NSButton()
    private let settingsButton = NSButton()
    private let quitButton = NSButton()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: Self.barHeight))
        translatesAutoresizingMaskIntoConstraints = false
        buildSubviews()
        configureAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Build

    private func buildSubviews() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = Tokens.Color.label
        titleLabel.alignment = .center

        configureIconButton(groupsButton,
                            symbol: Self.groupsSymbolName,
                            fallbacks: ["hifispeaker.and.homepod.fill",
                                       "rectangle.3.group", "hifispeaker.2.fill"],
                            accessibilityLabel: "Open Groups editor",
                            action: #selector(groupsTapped))
        configureIconButton(settingsButton,
                            symbol: "gearshape.fill",
                            fallbacks: ["gearshape", "gear"],
                            accessibilityLabel: "Settings",
                            action: #selector(settingsTapped))
        configureIconButton(quitButton,
                            symbol: "power",
                            fallbacks: ["xmark.circle", "escape"],
                            accessibilityLabel: "Quit",
                            action: #selector(quitTapped))

        addSubview(titleLabel)
        addSubview(groupsButton)
        addSubview(settingsButton)
        addSubview(quitButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.barHeight),

            // Centered title over the whole bar.
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Right-aligned icon cluster: groups · settings · quit (quit outermost).
            // Each button is a fixed iconButtonSide×iconButtonSide square (not a
            // wide-short rect) so the glyph reads as evenly padded on all four
            // sides rather than floating off-center in a rectangle.
            quitButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.iconButtonTrailingInset),
            quitButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            quitButton.widthAnchor.constraint(equalToConstant: Self.iconButtonSide),
            quitButton.heightAnchor.constraint(equalToConstant: Self.iconButtonSide),

            settingsButton.trailingAnchor.constraint(equalTo: quitButton.leadingAnchor, constant: -Self.iconButtonSpacing),
            settingsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: Self.iconButtonSide),
            settingsButton.heightAnchor.constraint(equalToConstant: Self.iconButtonSide),

            groupsButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -Self.iconButtonSpacing),
            groupsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            groupsButton.widthAnchor.constraint(equalToConstant: Self.iconButtonSide),
            groupsButton.heightAnchor.constraint(equalToConstant: Self.iconButtonSide),
        ])
    }

    /// The chosen SF Symbol for "audio group" (task A; re-checked in the
    /// header legibility pass, 2026-07-22). `hifispeaker.and.homepod.mini.badge.plus.fill`
    /// depicts multiple speaker devices with an "add" badge — the clearest
    /// "audio groups editor" metaphor of the candidates, but it's macOS-15+
    /// only (resolves nil on this machine's macOS 14). Below macOS 15, the
    /// choice is `hifispeaker.and.homepod.fill` (available back to macOS 14 —
    /// verified on this machine); `rectangle.3.group` then `hifispeaker.2.fill`
    /// remain as further fallbacks, verified non-nil at runtime in
    /// `configureIconButton`, so the button is never blank.
    ///
    /// Re-litigated candidates before keeping this symbol: `rectangle.3.group[.fill]`
    /// is Apple's own glyph for Stage Manager in System Settings, so reusing it
    /// here risks the OPPOSITE problem (a clear glyph that means something else
    /// already); `airplayaudio` reads as "pick a single AirPlay destination"
    /// (the iOS Control Center metaphor), not "edit which devices are grouped
    /// together," which is what this button actually opens (the mixer's group
    /// membership editor); generic grid glyphs (`square.grid.2x2`) carry no
    /// audio meaning at all. Nothing found clearly beats a speaker-with-plus
    /// glyph for "manage speaker groups," so per the product owner's own framing
    /// ("I defer to you... maybe if they were all just bigger... and a hover
    /// tooltip") the fix here is sizing + tooltip, not a symbol swap.
    static let groupsSymbolName = "hifispeaker.and.homepod.mini.badge.plus.fill"

    /// Point size of each header glyph within its `iconButtonSide` square.
    /// 16pt fills roughly half of the 28pt box on each axis (matching the
    /// Control Center / Music.app mini-player proportion this button system is
    /// modeled on, see `iconButtonSide`), leaving visibly even padding instead
    /// of a glyph that nearly touches the button's edge.
    private static let iconGlyphPointSize: CGFloat = 16

    /// Weight applied to every header glyph. `.medium` (up from `.regular`)
    /// reads slightly bolder/larger at a glance without changing the point
    /// size — part of the "make it bigger" fix — and is applied identically
    /// to all three buttons so no one glyph looks heavier than its neighbors.
    private static let iconGlyphWeight: NSFont.Weight = .medium

    /// A stock `NSButton` with `bezelStyle = .accessoryBar` and
    /// `showsBorderOnlyWhileMouseInside = true` — the system's borderless
    /// toolbar-glyph convention (matches the icon buttons already used
    /// elsewhere in this popover, e.g. `GroupRowView`/`DeviceRowView`): no
    /// box at rest, a soft rounded-rect highlight only while the mouse is
    /// over the button. The symbol is rendered with SF Symbols'
    /// **hierarchical** color style (`NSImage.SymbolConfiguration(hierarchicalColor:)`),
    /// which shades the glyph's sub-parts by depth for a less flat, more
    /// "system" look than a single flat tint; verified non-nil at runtime,
    /// falling back through `fallbacks` in order. All three buttons share the
    /// exact same `symbolConfig` (size, weight, color style) and the same
    /// `.scaleProportionallyDown` + fixed square frame, so even though the
    /// three glyphs have different natural aspect ratios (a wide speaker glyph
    /// vs. a roughly round gearshape vs. a roughly round power glyph), they
    /// all render inside the same box at the same visual scale — "matched
    /// proportions" per the product owner's ask.
    ///
    /// `button.toolTip` is set below to the same string passed for VoiceOver
    /// (`accessibilityLabel`) as a complete phrase ("Open Groups editor" /
    /// "Settings" / "Quit"), so a mouse-hover reveals in words exactly what the
    /// icon-only button is unclear about on its own.
    private func configureIconButton(_ button: NSButton,
                                     symbol: String,
                                     fallbacks: [String],
                                     accessibilityLabel: String,
                                     action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .accessoryBar
        button.isBordered = true
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = action

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: Self.iconGlyphPointSize, weight: Self.iconGlyphWeight)
            .applying(.init(hierarchicalColor: Tokens.Color.secondaryLabel))
        for name in [symbol] + fallbacks {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityLabel) {
                if let hierarchical = image.withSymbolConfiguration(symbolConfig) {
                    button.image = hierarchical
                } else {
                    image.isTemplate = true
                    button.image = image
                }
                break
            }
        }
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = accessibilityLabel
    }

    // MARK: Actions

    @objc private func groupsTapped() { onOpenGroupsEditor?() }

    @objc private func settingsTapped() {
        onOpenSettings?()
    }

    @objc private func quitTapped() { onQuit?() }

    // MARK: Accessibility

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Audiouter header")
    }

    // MARK: Test-support hooks

    /// The header title string (task A literal).
    var test_title: String { titleLabel.stringValue }
    /// Whether the Groups-editor button resolved a non-nil system symbol image.
    var test_groupsButtonHasImage: Bool { groupsButton.image != nil }
    /// Whether the Settings button resolved a non-nil system symbol image.
    var test_settingsButtonHasImage: Bool { settingsButton.image != nil }
    /// Whether the Quit button resolved a non-nil system symbol image.
    var test_quitButtonHasImage: Bool { quitButton.image != nil }
    /// Simulate tapping the Groups-editor button.
    func test_tapGroupsEditor() { groupsTapped() }
    /// Simulate tapping the Settings button.
    func test_tapSettings() { settingsTapped() }
    /// Simulate tapping the Quit button.
    func test_tapQuit() { quitTapped() }
    /// The Groups-editor button's hover tooltip text (should be a complete
    /// phrase, not just a one-word label — the whole point of the tooltip fix).
    var test_groupsButtonToolTip: String? { groupsButton.toolTip }
    /// The Settings button's hover tooltip text.
    var test_settingsButtonToolTip: String? { settingsButton.toolTip }
    /// The Quit button's hover tooltip text.
    var test_quitButtonToolTip: String? { quitButton.toolTip }
    /// Rendered frame size of each icon button, forcing layout first. Used to
    /// confirm the buttons are actually square (width == height ==
    /// `iconButtonSide`) after Auto Layout resolves, not just that the
    /// constraints were authored that way.
    func test_iconButtonFrames() -> (groups: NSRect, settings: NSRect, quit: NSRect) {
        layoutSubtreeIfNeeded()
        return (groupsButton.frame, settingsButton.frame, quitButton.frame)
    }
}
