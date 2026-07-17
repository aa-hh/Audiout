// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit

/// The popover's **header bar** (task A) — a borderless toolbar-style strip at
/// the very top of the panel, above the System card, styled per the macOS HIG for
/// borderless title-bar controls (like SoundSource's title-bar icons).
///
/// Layout, left → right:
/// - a **centered title** ("AudioControl", medium ~14pt, label color); and
/// - two right-aligned, stock `NSButton` (`bezelStyle = .smallSquare`),
///   image-only icon buttons:
///   1. **Open Groups editor** — a system SF Symbol
///      (`hifispeaker.and.homepod.mini.badge.plus.fill`, template-rendered,
///      verified non-nil at runtime with graceful fallbacks).
///      Opens the mixer window (where group membership editing lives) via the
///      host's existing open-mixer path.
///   2. **Settings** — SF Symbol `gearshape`. No action yet (a stub with an
///      accessibility label + a real target so it's a live button). See the
///      `// TODO: settings` marker below.
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

    /// Header bar height — compact toolbar strip.
    static let barHeight: CGFloat = 34

    /// Tapped the "Open Groups editor" button — the host opens the mixer window.
    var onOpenGroupsEditor: (() -> Void)?
    /// Tapped Settings — stubbed for now (`// TODO: settings`).
    var onOpenSettings: (() -> Void)?
    /// Tapped Quit (far-right header button) — the host terminates the app. This
    /// replaces the removed footer "Quit" action.
    var onQuit: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "AudioControl")
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
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .labelColor
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
            quitButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            quitButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            quitButton.widthAnchor.constraint(equalToConstant: 26),
            quitButton.heightAnchor.constraint(equalToConstant: 22),

            settingsButton.trailingAnchor.constraint(equalTo: quitButton.leadingAnchor, constant: -2),
            settingsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 26),
            settingsButton.heightAnchor.constraint(equalToConstant: 22),

            groupsButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -2),
            groupsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            groupsButton.widthAnchor.constraint(equalToConstant: 26),
            groupsButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    /// The chosen SF Symbol for "audio group" (task A). `hifispeaker.and.homepod.mini.badge.plus.fill`
    /// depicts multiple speaker devices with an "add" badge — the clearest
    /// "audio groups editor" metaphor of the candidates, but it's macOS-15+
    /// only (resolves nil on this machine's macOS 14). Below macOS 15, Alec's
    /// choice is `hifispeaker.and.homepod.fill` (available back to macOS 14 —
    /// verified on this machine); `rectangle.3.group` then `hifispeaker.2.fill`
    /// remain as further fallbacks, verified non-nil at runtime in
    /// `configureIconButton`, so the button is never blank.
    static let groupsSymbolName = "hifispeaker.and.homepod.mini.badge.plus.fill"

    /// A stock `NSButton` with `bezelStyle = .smallSquare`, image-only SF-Symbol
    /// content (re-derived from branch commit 18e5133, `claude/serene-elion-24763c`).
    /// The symbol is **template-rendered** (system vector, not a bundled raster),
    /// verified non-nil at runtime; if the preferred name fails to resolve it
    /// tries the fallbacks in order.
    private func configureIconButton(_ button: NSButton,
                                     symbol: String,
                                     fallbacks: [String],
                                     accessibilityLabel: String,
                                     action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .smallSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action

        for name in [symbol] + fallbacks {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityLabel) {
                image.isTemplate = true          // system-rendered template vector
                button.image = image
                break
            }
        }
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = accessibilityLabel
    }

    // MARK: Actions

    @objc private func groupsTapped() { onOpenGroupsEditor?() }

    @objc private func settingsTapped() {
        // TODO: settings — no settings surface exists yet. The button is real
        // (target/action + accessibility) so wiring a settings window later is a
        // one-line callback hookup.
        onOpenSettings?()
    }

    @objc private func quitTapped() { onQuit?() }

    // MARK: Accessibility

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("AudioControl header")
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
}
