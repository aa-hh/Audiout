// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// A single device row in a **membership checklist** — the group-creation
/// sheet's device list and the group editor's membership pane (design revamp:
/// the Groups window becomes CONFIGURATION-ONLY, so this row only ever edits
/// *membership*, never routing/activation). Composition is stock AppKit: a
/// checkbox `NSButton`, the device's SF Symbol in an `NSImageView` tinted
/// identity-neutral like the sidebar's `makeIconLabel`, and an `NSTextField`
/// name label.
///
/// Deliberately NOT `DeviceRowView` (`../AudiouterSharedUI/DeviceRowView.swift`):
/// that row's primary control is "Selected Devices" / live routing membership
/// and it carries a volume slider + mute button + connection-status badge —
/// all routing/activation concerns this window must never expose (activation
/// lives in the popover only, per the revamp). This row's checkbox means
/// "is a member of THIS group", an unrelated set from `GroupController`'s
/// Selected Devices.
///
/// **Visibility policy lives in the hosts, not here.** An unavailable device
/// still renders and is still checkable/uncheckable — a host only includes an
/// unavailable device in its list at all when it is already a member (so the
/// user can see and remove it), never to offer joining an unreachable device.
public final class MembershipRowView: NSView {

    /// Fired whenever the user toggles the row's checkbox.
    /// `deviceID`/`isChecked` mirror the row's current state at call time.
    public var onToggle: ((_ deviceID: String, _ isChecked: Bool) -> Void)?

    public private(set) var device: Device
    private var checked: Bool
    private var iconSymbolName: String?

    private let checkbox = NSButton()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    /// Small secondary annotation shown only for an unavailable member
    /// ("Unavailable") — never a routing/status claim, just presence.
    private let unavailableLabel = NSTextField(labelWithString: "")

    public init(device: Device, checked: Bool, iconSymbolName: String? = nil) {
        self.device = device
        self.checked = checked
        self.iconSymbolName = iconSymbolName
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: Self.rowHeight))
        buildSubviews()
        apply(device: device, checked: checked, iconSymbolName: iconSymbolName)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Fixed row height matching the shared row rhythm used elsewhere in the
    /// window (`DeviceRowView.rowHeight` is 42; a checklist row carries no
    /// slider/sublabel, so it can afford to be shorter).
    public static let rowHeight: CGFloat = 28

    public var deviceID: String { device.id }

    /// Read/write membership state. Setting it updates the checkbox but does
    /// NOT fire `onToggle` — that callback is reserved for user-driven toggles
    /// (real click or `test_toggle()`), never a programmatic model refresh.
    public var isChecked: Bool {
        get { checked }
        set {
            checked = newValue
            checkbox.state = newValue ? .on : .off
        }
    }

    // MARK: Build

    private func buildSubviews() {
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.setButtonType(.switch)   // AppKit checkbox
        checkbox.title = ""                // no inline title — the name label carries it
        checkbox.target = self
        checkbox.action = #selector(checkboxToggled(_:))
        checkbox.setContentHuggingPriority(.required, for: .horizontal)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        // Identity-neutral secondary tint, matching the sidebar's device rows
        // (`SidebarViewController.makeIconLabel`) — no accent-on-membership,
        // since this checklist has no "currently active" concept to show.
        iconView.contentTintColor = .secondaryLabelColor

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        unavailableLabel.translatesAutoresizingMaskIntoConstraints = false
        unavailableLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        unavailableLabel.textColor = .secondaryLabelColor
        unavailableLabel.stringValue = "Unavailable"
        unavailableLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(checkbox)
        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(unavailableLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),

            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),

            iconView.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),
            iconView.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: unavailableLabel.leadingAnchor, constant: -6),

            unavailableLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            unavailableLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: Model

    /// Refresh the row to a new device snapshot and membership state. Doesn't
    /// fire `onToggle` — this is a host-driven refresh, not a user action.
    public func apply(device: Device, checked: Bool, iconSymbolName: String? = nil) {
        self.device = device
        self.checked = checked
        self.iconSymbolName = iconSymbolName

        checkbox.state = checked ? .on : .off
        checkbox.isEnabled = true   // visibility policy is the host's job, not this row's

        let symbolName = DeviceIcon.resolve(iconSymbolName, default: device.kind.symbolName)
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: device.name
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: PopoverColumnGrid.iconGlyphPointSize,
                                        weight: .regular)
        )

        nameLabel.stringValue = device.name
        // Dimmed like the sidebar's unavailable devices — de-emphasized, still
        // fully interactive (an unavailable device stays checkable/uncheckable
        // so an existing member can be removed even while offline).
        nameLabel.textColor = device.isAvailable ? .labelColor : .disabledControlTextColor

        unavailableLabel.isHidden = device.isAvailable

        setAccessibilityLabel(
            "\(device.name)\(device.isAvailable ? "" : ", unavailable")")
        checkbox.setAccessibilityLabel(
            checked ? "Remove \(device.name) from group" : "Add \(device.name) to group")
    }

    // MARK: Actions

    @objc private func checkboxToggled(_ sender: NSButton) {
        checked = sender.state == .on
        onToggle?(device.id, checked)
    }

    // MARK: Test-support hooks
    //
    // No synthesized clicks in headless runs (`../AGENTS.md`) — these drive
    // the same delegate path a real checkbox click would.

    /// The checkbox's current state (for structural assertions).
    public var test_isChecked: Bool { checked }

    /// Simulate the user clicking the row's checkbox — flips the state and
    /// fires `onToggle`, exactly like a real click.
    public func test_toggle() {
        checkbox.state = checkbox.state == .on ? .off : .on
        checkboxToggled(checkbox)
    }

    /// The name label's current text (for asserting the row shows the right
    /// device).
    public var test_nameText: String { nameLabel.stringValue }

    /// Whether the row is currently rendered dimmed (unavailable device).
    public var test_isDimmed: Bool { !device.isAvailable }
}
