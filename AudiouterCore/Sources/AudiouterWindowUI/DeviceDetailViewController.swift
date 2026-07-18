// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// The read-only device detail pane (design revamp, CONFIGURATION-ONLY —
/// `../../AGENTS.md`): shown in the Groups window's detail area when the
/// sidebar selects a device (wiring that selection up is a separate task).
/// This view controller never activates a group, changes routing, or moves
/// audio — it only ever renders a `Device` snapshot plus which saved groups
/// it belongs to.
///
/// Layout, top to bottom, form column capped to ``contentMaxWidth`` and top-
/// pinned to `safeAreaLayoutGuide` — the same structural pattern
/// `GroupEditorViewController` uses:
/// - a large (``DeviceIconWellView/size``pt) device icon, resolved via an
///   injected `DeviceIconController` + `Device.Kind.symbolName` fallback (the
///   same resolution path `DeviceIcon` uses everywhere else — an override
///   that's gone stale on this OS still falls back to the kind default rather
///   than a blank glyph);
/// - APPROVED CUSTOM ELEMENT (the only one this phase — `../../AGENTS.md`): a
///   Contacts-style hover scrim over that icon (the shared
///   ``DeviceIconWellView``). Hovering shows a translucent full-coverage
///   scrim with a centered white pencil
///   glyph; clicking it presents `IconPickerViewController` as an anchored
///   popover, and picking a symbol (or "use default") writes straight through
///   `DeviceIconController.setSymbolName`/`resetIcon`, instant-apply like the
///   group editor's icon well;
/// - the device name as a title;
/// - a read-only metadata form (secondary-colour captions), sectioned into two
///   groups separated by a thin stock `NSBox` divider: device STATE (Status,
///   Available, Volume, Kind) above the line, MEMBERSHIP ("In groups:" — the
///   saved groups from the injected `GroupController` whose `memberIDs`
///   contain this device) below it;
/// - a minimal, single-line secondary-colour hint ("View-only — control
///   playback from the menu-bar popover.") under the form. Deliberately
///   terse: the fuller "configure here / play in the popover" teaching lives
///   in a footer elsewhere in this window (a sibling task), not restated here.
///
/// No volume slider, no mute, no Selected-Devices toggle, no group-activation
/// control of any kind lives here — that's the popover/mixer's job, not this
/// pane's.
public final class DeviceDetailViewController: NSViewController {

    /// Caps the form's content column width, matching
    /// `GroupEditorViewController.contentMaxWidth`.
    private static let contentMaxWidth: CGFloat = 400

    /// Fixed caption-column width so the five metadata rows line up.
    private static let captionWidth: CGFloat = 90

    private let groupController: GroupController

    /// Resolves/persists the icon override for the shown device. Optional and
    /// nil-tolerant (`../../AGENTS.md`'s "depends on the model, never the
    /// reverse") — without one the icon well still renders the kind default,
    /// it just can't be changed (the edit affordance still shows on hover;
    /// picking always no-ops without a controller to write through).
    public var deviceIconController: DeviceIconController?

    private let iconWell = DeviceIconWellView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let formStack = NSStackView()
    // Text is set at declaration (not in `loadView`) so it's correct even
    // before the view hierarchy is lazily loaded — `refreshUI()` mutates the
    // other labels the same way, independent of `loadView` having run.
    private let hintLabel = NSTextField(labelWithString: DeviceDetailViewController.viewOnlyHint)

    private let statusValueLabel = NSTextField(labelWithString: "")
    private let availableValueLabel = NSTextField(labelWithString: "")
    private let volumeValueLabel = NSTextField(labelWithString: "")
    private let kindValueLabel = NSTextField(labelWithString: "")
    private let groupsValueLabel = NSTextField(labelWithString: "")

    /// The device currently shown, `nil` before the first `show(device:)`.
    private var shownDevice: Device?

    /// Kept alive across a picker session so it can be dismissed/replaced;
    /// `nil` when no picker is currently presented (mirrors
    /// `GroupEditorViewController.iconPickerPopover`).
    private var iconPickerPopover: NSPopover?

    public init(groupController: GroupController) {
        self.groupController = groupController
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        iconWell.translatesAutoresizingMaskIntoConstraints = false
        iconWell.widthAnchor.constraint(equalToConstant: DeviceIconWellView.size).isActive = true
        iconWell.heightAnchor.constraint(equalToConstant: DeviceIconWellView.size).isActive = true
        iconWell.onClick = { [weak self] in
            _ = self?.presentIconPicker()
        }

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 3, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail

        // Two logical groups within one outer stack: device STATE (status,
        // availability, volume, kind) above a thin stock separator, then
        // MEMBERSHIP ("In groups:") below it — the wider inter-group spacing
        // plus the divider is what actually reads as sectioning; the rows
        // within a group keep the tighter spacing they always had.
        let stateStack = NSStackView()
        stateStack.orientation = .vertical
        stateStack.alignment = .leading
        stateStack.spacing = 10
        for (caption, valueLabel) in [
            ("Status", statusValueLabel),
            ("Available", availableValueLabel),
            ("Volume", volumeValueLabel),
            ("Kind", kindValueLabel),
        ] {
            stateStack.addArrangedSubview(makeMetadataRow(caption: caption, valueLabel: valueLabel))
        }

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let membershipRow = makeMetadataRow(caption: "In groups:", valueLabel: groupsValueLabel)

        formStack.translatesAutoresizingMaskIntoConstraints = false
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 18
        for v in [stateStack, divider, membershipRow] { formStack.addArrangedSubview(v) }
        // Stretch the divider to the column's full width — an arranged
        // subview otherwise sizes to its own intrinsic (near-zero) width
        // under `.leading` alignment, drawing an invisible sliver.
        divider.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail

        let container = NSView()
        // The form column: capped to `contentMaxWidth`, leading-aligned, pinned
        // below the safe area — same column idiom `GroupEditorViewController`
        // uses, so everything hangs off the column's edges rather than the
        // container's.
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false

        for v in [iconWell, nameLabel, formStack, hintLabel] { column.addSubview(v) }
        container.addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 20),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentMaxWidth),
            column.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),

            iconWell.topAnchor.constraint(equalTo: column.topAnchor),
            iconWell.centerXAnchor.constraint(equalTo: column.centerXAnchor),

            nameLabel.topAnchor.constraint(equalTo: iconWell.bottomAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: column.trailingAnchor),

            formStack.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 24),
            formStack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            formStack.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),

            hintLabel.topAnchor.constraint(equalTo: formStack.bottomAnchor, constant: 16),
            hintLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])

        view = container
    }

    /// Minimal one-line view-only hint. Deliberately terse — the fuller
    /// "configure here / play in the popover" teaching lives in a footer
    /// elsewhere in this window (a sibling task); this pane only needs to
    /// mark itself as non-interactive.
    private static let viewOnlyHint = "View-only — control playback from the menu-bar popover."

    /// Build one "Caption   Value" row: a fixed-width secondary-colour caption
    /// (so all five rows' values line up in a column) plus the value label.
    private func makeMetadataRow(caption: String, valueLabel: NSTextField) -> NSView {
        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.widthAnchor.constraint(equalToConstant: Self.captionWidth).isActive = true

        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [captionLabel, valueLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        return row
    }

    // MARK: Model

    /// Show the pane for `device`, replacing whatever was shown before.
    public func show(device: Device) {
        shownDevice = device
        refreshUI()
    }

    /// Update the currently-shown fields from a fresher `device` snapshot (a
    /// live volume/connection-state change), without disturbing hover/popover
    /// state. Behaves exactly like `show(device:)` if `device.id` differs —
    /// the sidebar is expected to call `show(device:)` for a new selection,
    /// but this stays correct either way.
    public func refresh(device: Device) {
        shownDevice = device
        refreshUI()
    }

    private func refreshUI() {
        guard let device = shownDevice else { return }
        nameLabel.stringValue = device.name
        statusValueLabel.stringValue = Self.statusText(for: device.connectionState)
        availableValueLabel.stringValue = device.isAvailable ? "Yes" : "No"
        volumeValueLabel.stringValue = "\(device.volume)%"
        kindValueLabel.stringValue = Self.kindText(for: device.kind)
        groupsValueLabel.stringValue = groupMembershipText(for: device)
        refreshIcon()
    }

    /// Plain-word status copy for `state`, matching `DeviceRowView`'s existing
    /// vocabulary (its "Couldn't connect" sublabel / accessibility suffixes)
    /// rather than coining new copy for this pane.
    private static func statusText(for state: ConnectionState) -> String {
        switch state {
        case .off:           return "Not connected"
        case .connecting:    return "Connecting"
        case .reconnecting:  return "Reconnecting"
        case .connected:     return "Connected"
        case .failed:        return "Couldn't connect"
        }
    }

    /// Human word for a device kind. No existing shared mapping for this
    /// (`Device.Kind.symbolName` only maps to a glyph); kept private to this
    /// pane rather than promoted to the model until a second caller needs it.
    private static func kindText(for kind: Device.Kind) -> String {
        switch kind {
        case .localMac:       return "This Mac"
        case .homePod:        return "HomePod"
        case .appleTV:        return "Apple TV"
        case .airportExpress: return "AirPort Express"
        case .sonos:          return "Sonos"
        case .generic:        return "AirPlay Speaker"
        }
    }

    /// "Kitchen, Office" for every saved group whose `memberIDs` contains
    /// `device.id`, in `groupController.groups` order, or "None" when empty.
    private func groupMembershipText(for device: Device) -> String {
        let names = groupController.groups
            .filter { $0.memberIDs.contains(device.id) }
            .map(\.name)
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    /// Resolve and apply the icon for `shownDevice`: the controller's override
    /// when one is set and still valid on this OS, else the kind default —
    /// `DeviceIconController.symbolName(for:)` already does that fallback, so
    /// this only needs its own direct fallback for the no-controller-injected
    /// case.
    private func refreshIcon() {
        guard let device = shownDevice else { return }
        let name = deviceIconController?.symbolName(for: device) ?? device.kind.symbolName
        let image = NSImage(systemSymbolName: name, accessibilityDescription: device.name)
        image?.isTemplate = true
        iconWell.iconImageView.image = image
        iconWell.iconImageView.contentTintColor = .secondaryLabelColor
    }

    // MARK: Icon picker

    /// Build `IconPickerViewController`, configure it against the shown
    /// device's current override + kind default, and present it as an
    /// anchored popover off the icon well — mirrors
    /// `GroupEditorViewController.presentIconPicker(anchoredTo:)`. Presenting
    /// is skipped when the icon well has no window (headless test), but the
    /// picker is still built, configured, wired, and returned so
    /// `test_clickEditIcon()` can drive it without a hosting window.
    @discardableResult
    private func presentIconPicker() -> IconPickerViewController {
        let device = shownDevice
        let defaultName = device?.kind.symbolName ?? ""
        let currentOverride = device.flatMap { deviceIconController?.overrides[$0.id] }

        let picker = IconPickerViewController()
        picker.configure(currentSymbolName: currentOverride, defaultSymbolName: defaultName)
        picker.onPick = { [weak self] name in
            self?.pickIcon(name)
        }
        test_picker = picker

        if iconWell.window != nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = picker
            popover.contentSize = picker.view.fittingSize
            iconPickerPopover = popover
            popover.show(relativeTo: iconWell.bounds, of: iconWell, preferredEdge: .maxY)
        }
        return picker
    }

    /// Persist `name` as the shown device's icon override (`nil` reverts to
    /// the default) through `DeviceIconController`, then refresh the well —
    /// instant-apply, no separate "Save" step. No-op without an injected
    /// controller (nothing to write through) or without a shown device.
    private func pickIcon(_ name: String?) {
        guard let device = shownDevice else { return }
        if let name {
            deviceIconController?.setSymbolName(name, for: device.id)
        } else {
            deviceIconController?.resetIcon(for: device.id)
        }
        refreshIcon()
    }

    // MARK: Test-support hooks
    //
    // No synthesized clicks in headless runs (`../AGENTS.md`) — these drive
    // the same code paths a real UI interaction would.

    /// The id of the device currently shown, `nil` before the first `show`.
    public var test_shownDeviceID: String? { shownDevice?.id }

    /// The metadata form's current visible text, keyed by field (not by its
    /// on-screen caption, so a future copy change doesn't reshape this API).
    public var test_metadataStrings: [String: String] {
        [
            "status": statusValueLabel.stringValue,
            "available": availableValueLabel.stringValue,
            "volume": volumeValueLabel.stringValue,
            "kind": kindValueLabel.stringValue,
        ]
    }

    /// The "In groups:" value text ("None" when the device is in no saved group).
    public var test_groupMembershipText: String { groupsValueLabel.stringValue }

    /// The minimal view-only hint's visible text — asserts it stays a single,
    /// short line rather than restating the fuller footer copy owned
    /// elsewhere in this window.
    public var test_hintText: String { hintLabel.stringValue }

    /// The symbol name currently rendered by the icon well.
    public var test_iconSymbolName: String? {
        guard let device = shownDevice else { return nil }
        return deviceIconController?.symbolName(for: device) ?? device.kind.symbolName
    }

    /// Drive the hover scrim's visibility headlessly (a real `mouseEntered`/
    /// `mouseExited` can't be synthesized in a headless run) so the snapshot
    /// tool can render the hovered state.
    public func test_setOverlayVisible(_ visible: Bool) {
        iconWell.setOverlayVisible(visible)
    }

    /// Simulate clicking the icon well: builds, configures, and returns the
    /// `IconPickerViewController` exactly like a real click (also presenting
    /// it as a popover when there's a real window to anchor to).
    @discardableResult
    public func test_clickEditIcon() -> IconPickerViewController {
        presentIconPicker()
    }

    /// The most recently built icon picker (from a real click or
    /// `test_clickEditIcon()`), retained so a test can keep driving it
    /// (`test_pickCurated`, `test_apply`, …) without needing the popover that
    /// hosts it live.
    public private(set) var test_picker: IconPickerViewController?
}
