// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit
import AirPlayControllerCore
import AirPlayControllerSharedUI

/// The single **"Main Out"** row in the popover's System card — styled after
/// macOS Control Center's **Sound module** (SPEC §9, T-U9b). Laid out against the
/// shared popover column grid (task B). Left to right: a leading speaker icon ·
/// name-less flexible zone · a Control-Center pill `ControlCenterSlider` (the
/// master volume) · a `%` readout · a **named destination dropdown**
/// (`NSPopUpButton`, `pullsDown = false`) as the trailing control.
///
/// (T-U10 briefly moved the glyph into the slider's track to match a full-height
/// capsule redesign; Alec reverted the slider to its original slim-track design,
/// so the leading icon is back.)
///
/// **REVISED (task B, 2026-07-14) — the circular icon button became a NAMED
/// SoundSource-style dropdown** that SHOWS THE CURRENTLY SELECTED target's title
/// (truncated with "…" if long), replacing the old circular AirPlay button. It is
/// still THE routing control — one place answers "where is my audio going?" — and
/// keeps the exact same two-section menu content (SPEC §9b — separators +
/// headers):
///   §1  "Selected Devices"      -> `.selectedDevices`
///   §2  each saved Output Group -> `.group(id)`
/// The current target is checkmarked AND its title is the button's visible label,
/// its accessibility value, and the `test_selectedTitle` hook.
///
/// Pure UI: every control routes back through ``Delegate`` so the host
/// (`PopoverController`) can drive `GroupController`. The view never talks to a
/// backend directly.
public final class MainOutRowView: NSView {

    public protocol Delegate: AnyObject {
        func mainOutRow(_ row: MainOutRowView, didSelect target: MainOutTarget)
        func mainOutRowBeginMasterDrag(_ row: MainOutRowView)
        func mainOutRow(_ row: MainOutRowView, didSetMaster volume: Int)
        func mainOutRowEndMasterDrag(_ row: MainOutRowView)
        func mainOutRow(_ row: MainOutRowView, didSetMuted muted: Bool)
    }

    /// One option in the selector, kept alongside its menu item so a selection
    /// maps straight back to a `MainOutTarget`.
    public struct Option {
        public let title: String
        public let target: MainOutTarget
        /// A non-selectable section header (disabled, small caps) vs a real choice.
        public let isHeader: Bool
        public init(title: String, target: MainOutTarget = .selectedDevices, isHeader: Bool = false) {
            self.title = title; self.target = target; self.isHeader = isHeader
        }
    }

    /// A touch taller than a device row — this is the module's headline control.
    public static let rowHeight: CGFloat = 44

    public weak var delegate: Delegate?

    /// Leading speaker icon (restored — Alec reverted the slider to the original
    /// slim-track design, which does not draw an in-track glyph).
    private let iconView = NSImageView()
    /// The System row's name — "Audio Out" (2026-07-14), matching SoundSource's
    /// "Output" row and filling the shared name column so it aligns with the
    /// device/group rows below.
    private let nameLabel = NSTextField(labelWithString: "Audio Out")
    private let slider = ControlCenterSlider()
    /// A speaker mute button sitting LEFT of the master slider (mirrors the
    /// per-device mute glyph in `DeviceRowView`). `pushOnPushOff`: `.on` = muted.
    private let muteButton = NSButton()
    private let readoutLabel = NSTextField(labelWithString: "")
    /// The **named** SoundSource-style destination dropdown (task B) — an
    /// `NSPopUpButton` (`pullsDown = false`) whose visible title is the currently
    /// selected target. Replaces the old circular icon button. Owns the
    /// two-section menu directly.
    private let destinationPopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    private var options: [Option] = []
    private var isDraggingMaster = false
    /// The title of the currently-selected (checkmarked) target, mirrored for the
    /// `test_selectedTitle` hook and the button's accessibility value.
    private var selectedTitle: String?

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: Self.rowHeight))
        autoresizingMask = [.width]
        translatesAutoresizingMaskIntoConstraints = true
        buildSubviews()
        configureAccessibility()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Model

    /// Repopulate the selector, set the master slider + readout, and check the
    /// current target. `master` is the proportional master of the current target.
    public func apply(options: [Option], current: MainOutTarget, master: Int, isMuted: Bool = false) {
        self.options = options
        muteButton.state = isMuted ? .on : .off

        let menu = destinationPopUp.menu ?? NSMenu()
        menu.removeAllItems()
        selectedTitle = nil
        var currentItem: NSMenuItem?
        for option in options {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            if option.isHeader {
                item.isEnabled = false
                item.attributedTitle = NSAttributedString(
                    string: option.title.uppercased(),
                    attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                        .foregroundColor: NSColor.tertiaryLabelColor,
                    ])
            } else {
                item.target = self
                item.action = #selector(selectionChanged(_:))
                let isCurrent = option.target == current
                item.state = isCurrent ? .on : .off
                if isCurrent { selectedTitle = option.title; currentItem = item }
            }
            menu.addItem(item)
        }
        destinationPopUp.menu = menu
        // Show the currently selected target as the button's visible title
        // (SoundSource-style named dropdown, task B). The pop-up truncates a long
        // title with a tail ellipsis via its fixed max width + cell line break.
        if let currentItem { destinationPopUp.select(currentItem) }

        if !isDraggingMaster { slider.integerValue = master }
        readoutLabel.stringValue = "\(master)%"
        configureAccessibility()
    }

    // MARK: Build

    private func buildSubviews() {
        wantsLayer = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                                 accessibilityDescription: "Main Out")
        iconView.contentTintColor = .controlAccentColor
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minValue = 0
        slider.maxValue = 100
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(masterChanged(_:))

        // Speaker mute button, LEFT of the master slider (same visual pattern as
        // `DeviceRowView`'s per-device mute): `pushOnPushOff`, image-only,
        // `speaker.wave.2.fill` → `.on`/alternate `speaker.slash.fill` when muted.
        muteButton.translatesAutoresizingMaskIntoConstraints = false
        muteButton.setButtonType(.pushOnPushOff)
        muteButton.isBordered = false
        muteButton.imagePosition = .imageOnly
        let muteConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        muteButton.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                                   accessibilityDescription: "Mute Main Out")?
            .withSymbolConfiguration(muteConfig)
        muteButton.alternateImage = NSImage(systemSymbolName: "speaker.slash.fill",
                                            accessibilityDescription: "Unmute Main Out")?
            .withSymbolConfiguration(muteConfig)
        muteButton.contentTintColor = .secondaryLabelColor
        muteButton.target = self
        muteButton.action = #selector(muteToggled(_:))
        muteButton.setContentHuggingPriority(.required, for: .horizontal)

        readoutLabel.translatesAutoresizingMaskIntoConstraints = false
        readoutLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        readoutLabel.textColor = .secondaryLabelColor
        readoutLabel.alignment = .right
        readoutLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Named SoundSource-style destination dropdown (task B): a real
        // `NSPopUpButton` (`pullsDown = false`, SPEC §9 "choosing one from a set,
        // shows the current selection"). Its title is the current target, tail-
        // truncated. It carries the same two-section menu populated in `apply`.
        destinationPopUp.translatesAutoresizingMaskIntoConstraints = false
        destinationPopUp.pullsDown = false
        destinationPopUp.controlSize = .small
        destinationPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        destinationPopUp.target = self
        destinationPopUp.action = #selector(selectionChanged(_:))
        // Truncate a long target title with a tail ellipsis inside the fixed
        // dropdown width (task B — "truncated with '…' if long").
        (destinationPopUp.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        destinationPopUp.setContentHuggingPriority(.required, for: .horizontal)
        destinationPopUp.setContentCompressionResistancePriority(.required, for: .horizontal)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(muteButton)
        addSubview(slider)
        addSubview(readoutLabel)
        addSubview(destinationPopUp)

        // Laid out against the shared column grid (task B). The icon leads; the
        // slider, `%` readout and the named dropdown (the trailing control) are
        // all anchored off the TRAILING edge so they line up with the device and
        // group rows. The dropdown gets a comfortable fixed width so a named
        // target fits and truncates gracefully.
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor,
                                              constant: PopoverColumnGrid.leadingInset),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),
            iconView.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),

            // "Audio Out" name fills the shared name column, icon → slider.
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                               constant: PopoverColumnGrid.iconToName),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The name column now yields to the mute glyph, which sits between the
            // name and the slider.
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: muteButton.leadingAnchor,
                                                constant: -PopoverColumnGrid.nameToSlider),

            // Speaker mute button, LEFT of the slider.
            muteButton.trailingAnchor.constraint(equalTo: slider.leadingAnchor,
                                                 constant: -PopoverColumnGrid.muteToSlider),
            muteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            muteButton.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.muteWidth),

            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.sliderWidth),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor,
                                             constant: -PopoverColumnGrid.sliderTrailing),

            readoutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            readoutLabel.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.readoutWidth),
            readoutLabel.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                   constant: -PopoverColumnGrid.readoutTrailing),

            destinationPopUp.centerYAnchor.constraint(equalTo: centerYAnchor),
            destinationPopUp.widthAnchor.constraint(
                equalToConstant: PopoverColumnGrid.trailingControlWidth),
            destinationPopUp.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -PopoverColumnGrid.trailingControlTrailing),
        ])
    }

    // MARK: Actions

    @objc private func selectionChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < options.count else { return }
        delegate?.mainOutRow(self, didSelect: options[index].target)
    }

    @objc private func muteToggled(_ sender: NSButton) {
        delegate?.mainOutRow(self, didSetMuted: sender.state == .on)
    }

    @objc private func masterChanged(_ sender: NSSlider) {
        let event = NSApp.currentEvent
        if !isDraggingMaster {
            isDraggingMaster = true
            delegate?.mainOutRowBeginMasterDrag(self)
        }
        delegate?.mainOutRow(self, didSetMaster: sender.integerValue)
        readoutLabel.stringValue = "\(sender.integerValue)%"
        if event?.type == .leftMouseUp {
            isDraggingMaster = false
            delegate?.mainOutRowEndMasterDrag(self)
        }
    }

    // The Main Out row lives INSIDE the System card (T-U8), so it paints no fill
    // of its own — the card provides the module surface.

    // MARK: Accessibility

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Main Out, master volume \(slider.integerValue) percent")
        slider.setAccessibilityRole(.slider)
        slider.setAccessibilityLabel("Main Out master volume")
        destinationPopUp.setAccessibilityLabel("Main Out destination")
        destinationPopUp.setAccessibilityValue(selectedTitle ?? "")
    }

    // MARK: Test-support hooks

    /// The titles currently in the selector menu, in order (incl. headers).
    public var test_optionTitles: [String] { options.map(\.title) }
    /// The selectable (non-header) targets, in order.
    public var test_selectableTargets: [MainOutTarget] { options.filter { !$0.isHeader }.map(\.target) }
    /// The currently shown master value.
    public var test_masterValue: Int { slider.integerValue }
    /// The currently checkmarked selection title (the destination the button shows).
    public var test_selectedTitle: String? { selectedTitle }
    /// Whether the master mute button is currently in its muted (`.on`) state.
    public var test_isMasterMuted: Bool { muteButton.state == .on }

    /// Simulate the user toggling the master mute button.
    public func test_toggleMasterMute() {
        delegate?.mainOutRow(self, didSetMuted: !(muteButton.state == .on))
    }

    /// Simulate the user choosing `target` from the selector.
    public func test_select(_ target: MainOutTarget) {
        delegate?.mainOutRow(self, didSelect: target)
    }

    /// Simulate a master drag to `value`.
    public func test_dragMaster(to value: Int) {
        delegate?.mainOutRowBeginMasterDrag(self)
        delegate?.mainOutRow(self, didSetMaster: value)
        delegate?.mainOutRowEndMasterDrag(self)
    }
}
