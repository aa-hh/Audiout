// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit
import AirPlayControllerCore
import AirPlayControllerSharedUI

/// The mixer detail pane (SPEC §9 "Mixer pane": an `NSStackView` of device
/// rows — "same row component as the menu"). Shows one `DeviceRowView` per
/// device in scope: the selected group's members, or all devices when nothing
/// is scoped.
///
/// Every row routes its on/off switch, slider, and mute through this controller
/// into the shared `GroupController`, exactly like the popover's
/// `PopoverController` — the row view is identical, only the host differs.
public final class MixerViewController: NSViewController {

    private let groupController: GroupController

    private let stackView = NSStackView()
    private let scrollView = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "")

    /// Which devices are currently shown, in order, so `refresh` can update rows
    /// in place and a harness/test can assert the mixer's contents.
    private(set) var shownDeviceIDs: [String] = []
    private var rowsByID: [String: DeviceRowView] = [:]

    /// The group whose members are shown, or nil for "all devices".
    private var scopedGroupID: String?

    public init(groupController: GroupController) {
        self.groupController = groupController
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.spacing = 2

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let container = NSView()
        container.addSubview(titleLabel)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -8),
            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        view = container
    }

    // MARK: Model

    /// Show the mixer scoped to `groupID` (nil → all devices), rebuilding rows.
    public func show(groupID: String?, devices: [Device]) {
        scopedGroupID = groupID
        rebuild(devices: devices)
    }

    /// Update the visible rows in place to a new device snapshot (no rebuild
    /// unless the set of shown devices changed).
    public func refresh(devices: [Device]) {
        let target = scopedDevices(devices)
        if target.map(\.id) != shownDeviceIDs {
            rebuild(devices: devices)
        } else {
            for device in target {
                if let row = rowsByID[device.id] { applySelection(to: row, device: device) }
            }
        }
    }

    /// Reflect the device's "Selected Devices" membership (SPEC §9b) on its row,
    /// including the Phase-1 local-mix block on the current device.
    private func applySelection(to row: DeviceRowView, device: Device) {
        let selected = groupController.isSpeakerSelected(device.id)
        let blocked = device.isLocalDevice && !selected && !groupController.canSelectLocalSpeaker(device.id)
        row.apply(device,
                  selected: selected,
                  blocked: blocked,
                  blockReason: blocked ? GroupController.localMixRefusalReason : nil)
    }

    private func rebuild(devices: [Device]) {
        for row in stackView.arrangedSubviews { stackView.removeArrangedSubview(row); row.removeFromSuperview() }
        rowsByID.removeAll()

        let target = scopedDevices(devices)
        shownDeviceIDs = target.map(\.id)

        if let scopedGroupID, let group = groupController.groups.first(where: { $0.id == scopedGroupID }) {
            titleLabel.stringValue = group.name
        } else {
            titleLabel.stringValue = "All Devices"
        }

        for device in target {
            let row = DeviceRowView(device: device)
            row.delegate = self
            rowsByID[device.id] = row
            applySelection(to: row, device: device)
            stackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
        }
    }

    private func scopedDevices(_ devices: [Device]) -> [Device] {
        guard let scopedGroupID,
              let group = groupController.groups.first(where: { $0.id == scopedGroupID }) else {
            return devices
        }
        let byID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        return group.memberIDs.compactMap { byID[$0] }
    }

    // MARK: Test-support hooks

    /// The device ids shown as rows, in order.
    public var test_rowDeviceIDs: [String] { shownDeviceIDs }

    /// The `DeviceRowView` for a device, if shown (drives its slider/mute
    /// through the same delegate path as a real click).
    public func test_row(for id: String) -> DeviceRowView? { rowsByID[id] }
}

// MARK: - DeviceRowView.Delegate

extension MixerViewController: DeviceRowView.Delegate {

    public func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String) {
        groupController.setMemberVolume(volume, for: id)
    }

    public func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {
        groupController.setMuted(muted, for: id)
    }

    public func deviceRow(_ row: DeviceRowView, didToggleEnabled on: Bool, for id: String) {
        // Compose the Selected Devices set (SPEC §9b) — same semantics as the
        // popover. Does not route unless Main Out targets Selected Devices.
        _ = groupController.setDeviceSelected(id, on)
    }
}
