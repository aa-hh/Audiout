// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// The read-only device detail pane (design revamp, CONFIGURATION-ONLY —
/// `../../AGENTS.md`): shown in the Groups window's detail area when the
/// sidebar selects a device.
/// This view controller never activates a group, changes routing, or moves
/// audio — it only ever renders a `Device` snapshot plus which saved groups
/// it belongs to.
///
/// Layout, top to bottom, in an ELASTIC form column top-pinned to
/// `safeAreaLayoutGuide` — structurally identical to
/// `GroupEditorViewController`, off the same ``GroupsPaneLayout`` numbers:
/// - a HEADER SECTION (``GroupedSectionView``) holding the large
///   (``DeviceIconWellView/size``pt) device icon and the device name SIDE BY
///   SIDE. The icon is resolved via an injected `DeviceIconController` +
///   `Device.Kind.symbolName` fallback (the same resolution path `DeviceIcon`
///   uses everywhere else — an override that's gone stale on this OS still
///   falls back to the kind default rather than a blank glyph);
/// - APPROVED CUSTOM ELEMENT (the only one this phase — `../../AGENTS.md`): the
///   shared ``DeviceIconWellView``'s always-present corner pencil badge.
///   Clicking the well presents `IconPickerViewController` as an anchored
///   popover, and picking a symbol (or "use default") writes straight through
///   `DeviceIconController.setSymbolName`/`resetIcon`, instant-apply like the
///   group editor's icon well;
/// - the device name as a PLAIN LABEL — same geometry as the group editor's
///   title, deliberately different skin. Bordered + pencil means editable; bare
///   means read-only, which is exactly the difference between a group's name
///   (renameable here) and a device's (not);
/// - the read-only metadata in two grouped sections (secondary-colour captions
///   leading, values right-aligned into their own column): device STATE
///   (Status, Available, Volume, Kind) in the first, MEMBERSHIP ("In groups" —
///   the saved groups from the injected `GroupController` whose `memberIDs`
///   contain this device) in the second. The sections' own inset hairlines
///   separate the rows; the old stock `NSBox` divider is gone (it drew a 185 pt
///   rule that stopped a third of the way across the pane);
/// - a minimal, single-line secondary-colour hint ("View-only — control
///   playback from the menu-bar popover.") under the form. Deliberately
///   terse: the fuller "configure here / play in the popover" teaching lives
///   in a footer elsewhere in this window, not restated here.
///
/// No volume slider, no mute, no Selected-Devices toggle, no group-activation
/// control of any kind lives here — that's the popover/mixer's job, not this
/// pane's.
public final class DeviceDetailViewController: NSViewController {

    private let groupController: GroupController

    /// Resolves/persists the icon override for the shown device. Optional and
    /// nil-tolerant (`../../AGENTS.md`'s "depends on the model, never the
    /// reverse") — without one the icon well still renders the kind default,
    /// it just can't be changed (the edit affordance still shows on hover;
    /// picking always no-ops without a controller to write through).
    public var deviceIconController: DeviceIconController?

    private let iconWell = DeviceIconWellView()
    private let nameLabel = NSTextField(labelWithString: "")
    /// The header's own bounded section (icon + name side by side) — the same
    /// shape, at the same geometry, as the group editor's header section.
    private let headerWell = GroupedSectionView()
    /// The device-STATE section (Status / Available / Volume / Kind) and the
    /// MEMBERSHIP section ("In groups"), each a `GroupedSectionView` whose own
    /// inset hairlines separate its rows.
    private let stateWell = GroupedSectionView()
    private let groupsWell = GroupedSectionView()
    private let stateStack = NSStackView()
    private let groupsStack = NSStackView()
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

        // A PLAIN label, deliberately: no fill, no border, no pencil. The
        // decoration IS the message — the group editor's title wears all three
        // because it is renameable, and a device's name is not.
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Tokens.Font.heading
        nameLabel.alignment = .natural   // left-aligned (LTR) to match the form column
        nameLabel.lineBreakMode = .byTruncatingTail
        // A long device name TRUNCATES; it never widens the pane. Without this
        // the label's default compression resistance beats the split view's own
        // divider geometry, and a long name silently squeezes the sidebar past
        // its minimum thickness.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Device STATE (status, availability, volume, kind) in one section,
        // MEMBERSHIP ("In groups") in another — the two bounded sections are
        // what read as sectioning now, replacing the stock `NSBox` rule that
        // used to sit between them and stop a third of the way across the pane.
        stateStack.translatesAutoresizingMaskIntoConstraints = false
        stateStack.orientation = .vertical
        stateStack.alignment = .leading
        stateStack.spacing = 10
        for (caption, valueLabel) in [
            ("Status", statusValueLabel),
            // "On the network", not "Available": next to "Status: Not
            // connected" a bare "Available: Yes" read as a contradiction to a
            // non-specialist ("it's available but not connected?").
            ("On the network", availableValueLabel),
            ("Volume", volumeValueLabel),
            ("Kind", kindValueLabel),
        ] {
            let row = makeMetadataRow(caption: caption, valueLabel: valueLabel)
            stateStack.addArrangedSubview(row)
            // Rows FILL the section, so a right-aligned value lands on the
            // section's own inset edge rather than at the end of its own
            // intrinsic width.
            row.widthAnchor.constraint(equalTo: stateStack.widthAnchor).isActive = true
        }

        groupsStack.translatesAutoresizingMaskIntoConstraints = false
        groupsStack.orientation = .vertical
        groupsStack.alignment = .leading
        groupsStack.spacing = 10
        let membershipRow = makeMetadataRow(caption: "In groups", valueLabel: groupsValueLabel)
        groupsStack.addArrangedSubview(membershipRow)
        membershipRow.widthAnchor.constraint(equalTo: groupsStack.widthAnchor).isActive = true

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = Tokens.Font.caption
        hintLabel.textColor = Tokens.Color.secondaryLabel
        hintLabel.lineBreakMode = .byTruncatingTail
        // A pane-level footnote, not a form row: it spans the column's FULL
        // width (see its constraints) and yields before the pane does. At its
        // intrinsic ~310 pt it is wider than the content lane inside the
        // sections, and a label that refuses to compress forces the whole split
        // view wider than the window — it was squeezing the sidebar past its
        // own minimum thickness.
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let container = NSView()
        // The form column: symmetric margins off the pane, ELASTIC up to
        // `GroupsPaneLayout.contentMaxWidth` — the same column idiom
        // `GroupEditorViewController` uses, off the same constants, so the two
        // panes are interchangeable behind one sidebar.
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false

        // Sections go in FIRST so they sit behind the content they back
        // (non-interactive either way — `GroupedSectionView.hitTest` is nil).
        // The HEADER keeps the full spine-gutter inset so its icon + name stay
        // pinned to the group editor's; the metadata sections below use the
        // rail-free inset, because no rail runs past them and reserving the
        // lane left them looking hollow (design review 2026-07-25).
        headerWell.contentLeadingInset = GroupsPaneLayout.contentLeadingInset
        stateWell.contentLeadingInset = GroupsPaneLayout.railFreeContentLeadingInset
        groupsWell.contentLeadingInset = GroupsPaneLayout.railFreeContentLeadingInset
        for well in [headerWell, stateWell, groupsWell] {
            well.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(well)
        }
        for v in [iconWell, nameLabel, stateStack, groupsStack, hintLabel] { column.addSubview(v) }
        container.addSubview(column)

        // The rows' own hairlines come from the section, which reads their LIVE
        // frames on every draw.
        stateWell.rows = stateStack.arrangedSubviews

        let columnFill = column.trailingAnchor.constraint(
            equalTo: container.trailingAnchor, constant: -GroupsPaneLayout.columnTrailingInset)
        columnFill.priority = .defaultHigh

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor,
                                        constant: GroupsPaneLayout.columnTopInset),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                            constant: GroupsPaneLayout.columnInset),
            column.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                             constant: -GroupsPaneLayout.columnTrailingInset),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: GroupsPaneLayout.contentMaxWidth),
            columnFill,

            // HEADER PARITY (design review 2026-07-25), now GEOMETRIC: every
            // number below comes from `GroupsPaneLayout`, the same source the
            // group editor reads, so the icon well and the title land on the
            // same x and the band is the same height in both panes. They used
            // to sit ~22.5 pt apart, so switching sidebar selection visibly
            // jumped the header sideways. This pane draws no rail, so the
            // reserved gutter simply reads as a wider left margin — the
            // alignment is worth more than reclaiming it.
            headerWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            headerWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            headerWell.topAnchor.constraint(equalTo: column.topAnchor),
            headerWell.bottomAnchor.constraint(equalTo: iconWell.bottomAnchor,
                                               constant: GroupsPaneLayout.headerPadding),

            iconWell.topAnchor.constraint(equalTo: column.topAnchor,
                                          constant: GroupsPaneLayout.headerPadding),
            iconWell.leadingAnchor.constraint(equalTo: column.leadingAnchor,
                                              constant: GroupsPaneLayout.contentLeadingInset),

            nameLabel.leadingAnchor.constraint(equalTo: iconWell.trailingAnchor,
                                               constant: GroupsPaneLayout.iconToTitleGap),
            nameLabel.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerWell.trailingAnchor,
                                                constant: -GroupsPaneLayout.contentTrailingInset),

            stateStack.topAnchor.constraint(equalTo: headerWell.bottomAnchor,
                                            constant: 14 + GroupedSectionView.verticalPadding),
            stateStack.leadingAnchor.constraint(
                equalTo: column.leadingAnchor,
                constant: GroupsPaneLayout.railFreeContentLeadingInset),
            stateStack.trailingAnchor.constraint(
                equalTo: column.trailingAnchor, constant: -GroupsPaneLayout.contentTrailingInset),

            stateWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            stateWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            stateWell.topAnchor.constraint(equalTo: stateStack.topAnchor,
                                           constant: -GroupedSectionView.verticalPadding),
            stateWell.bottomAnchor.constraint(equalTo: stateStack.bottomAnchor,
                                              constant: GroupedSectionView.verticalPadding),

            groupsStack.topAnchor.constraint(equalTo: stateWell.bottomAnchor,
                                             constant: 14 + GroupedSectionView.verticalPadding),
            groupsStack.leadingAnchor.constraint(
                equalTo: column.leadingAnchor,
                constant: GroupsPaneLayout.railFreeContentLeadingInset),
            groupsStack.trailingAnchor.constraint(
                equalTo: column.trailingAnchor, constant: -GroupsPaneLayout.contentTrailingInset),

            groupsWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            groupsWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            groupsWell.topAnchor.constraint(equalTo: groupsStack.topAnchor,
                                            constant: -GroupedSectionView.verticalPadding),
            groupsWell.bottomAnchor.constraint(equalTo: groupsStack.bottomAnchor,
                                               constant: GroupedSectionView.verticalPadding),

            hintLabel.topAnchor.constraint(equalTo: groupsWell.bottomAnchor, constant: 16),
            // The full column, NOT the content lane inside the sections: this
            // is a footnote about the pane, so it reads across it (the same way
            // the window's own footer caption spans the whole pane) and gets
            // the width it needs instead of truncating inside a lane that's
            // 38.5 pt narrower.
            hintLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])

        view = container
    }

    /// Minimal one-line view-only hint. Deliberately terse — the fuller
    /// "configure here / play in the popover" teaching lives in a footer
    /// elsewhere in this window; this pane only needs to
    /// mark itself as non-interactive.
    private static let viewOnlyHint = "View-only — control playback from the menu-bar popover."

    /// Build one "Caption ······ Value" row: a secondary-colour caption on the
    /// leading edge and its value RIGHT-ALIGNED on the trailing edge, so the
    /// values line up in a real column that uses the section's full width.
    /// (They used to hang off a fixed 90 pt caption column, which left them
    /// stranded mid-pane in a window this wide.)
    ///
    /// The row fills its section: the caller pins each row's width to the
    /// stack's, so "trailing" means the section's own inset edge.
    private func makeMetadataRow(caption: String, valueLabel: NSTextField) -> NSView {
        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.textColor = Tokens.Color.secondaryLabel
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.setContentHuggingPriority(.required, for: .horizontal)
        captionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(captionLabel)
        row.addSubview(valueLabel)
        NSLayoutConstraint.activate([
            captionLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            captionLabel.topAnchor.constraint(equalTo: row.topAnchor),
            captionLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            valueLabel.firstBaselineAnchor.constraint(equalTo: captionLabel.firstBaselineAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: captionLabel.trailingAnchor,
                                                constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
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
        case .bluetooth:      return "Bluetooth Speaker"
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
        iconWell.iconImageView.contentTintColor = Tokens.Color.secondaryLabel
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

    /// The "In groups" value text ("None" when the device is in no saved group).
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

    /// HEADER PARITY hooks — the three numbers that must match
    /// `GroupEditorViewController`'s identically-named hooks, so switching
    /// sidebar selection never shifts the header (`GroupsHeaderParityTests`).

    /// The icon well's laid-out frame in the pane's own coordinates.
    public var test_headerIconFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return iconWell.convert(iconWell.bounds, to: view)
    }

    /// The title's ALIGNMENT rect in the pane's own coordinates — what auto
    /// layout actually pins, so a plain label and the editor's editable field
    /// (whose alignment insets differ from their frames) compare honestly.
    public var test_headerTitleAlignmentFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return nameLabel.alignmentRect(forFrame: nameLabel.convert(nameLabel.bounds, to: view))
    }

    /// The header SECTION's laid-out frame in the pane's own coordinates.
    public var test_headerSectionFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return headerWell.convert(headerWell.bounds, to: view)
    }

    /// Leading inset of the metadata rows, measured from their section's own
    /// edge. This pane draws NO rail, so its rows use the tighter
    /// `railFreeContentLeadingInset` rather than reserving the spine's lane —
    /// its HEADER still uses the full inset so the icon + name stay pinned to
    /// the group editor's (design review 2026-07-25).
    public var test_metadataRowInset: CGFloat {
        view.layoutSubtreeIfNeeded()
        let row = stateStack.convert(stateStack.bounds, to: view)
        let section = stateWell.convert(stateWell.bounds, to: view)
        return row.minX - section.minX
    }

    /// The number of `GroupedSectionView` sections this pane draws (header +
    /// state + "In groups") — the detail pane adopts the SAME section shape the
    /// group editor uses, rather than a bare form on the pane.
    public var test_sectionCount: Int {
        view.subviews.flatMap(\.subviews).filter { $0 is GroupedSectionView }.count
    }

    /// True when the pane still mounts a stock `NSBox` separator — it must
    /// not: the sections' own inset hairlines replaced the orphaned 185 pt rule
    /// that stopped a third of the way across the pane.
    public var test_hasBoxDivider: Bool {
        func containsBox(_ v: NSView) -> Bool {
            v is NSBox || v.subviews.contains(where: containsBox)
        }
        return containsBox(view)
    }

    /// The device NAME's own trailing edge vs the value column's, so a test can
    /// assert the metadata values really right-align into the section instead
    /// of hanging off a fixed caption width.
    public var test_valueTrailingX: CGFloat {
        view.layoutSubtreeIfNeeded()
        return statusValueLabel.convert(statusValueLabel.bounds, to: view).maxX
    }

    /// The state section's laid-out frame in the pane's own coordinates.
    public var test_stateSectionFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return stateWell.convert(stateWell.bounds, to: view)
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
