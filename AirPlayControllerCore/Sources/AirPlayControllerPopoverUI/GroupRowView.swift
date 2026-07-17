// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit
import AirPlayControllerCore
import AirPlayControllerSharedUI

/// A saved group's header row in the Control-Center-style popover (SPEC §9
/// revised — "Groups section"). Left to right: an **activate** button (a
/// selectable circle that turns the group's members ON as a preset), a
/// disclosure **chevron**, the group **name**, a numeric master **readout**, and
/// a group-**master slider** shown on EVERY group (SPEC §9 revised — "every
/// group row shows its master consistently, not just the active one").
///
/// **Click anywhere on the row toggles expansion** (SPEC §9 revised — the whole
/// reason for leaving NSMenu). The row is a control surface: a click on empty
/// space (or the name/readout) toggles the group open/closed; the activate
/// button and the master slider are the two sub-controls that handle their own
/// clicks instead of expanding.
///
/// Unlike the old menu row, this lives in an `NSPopover`'s view hierarchy, so it
/// paints a normal selectable background (accent when active) rather than the
/// system menu highlight, and it is a plain `.button`/`.group` for a11y.
public final class GroupRowView: NSView {

    protocol Delegate: AnyObject {
        /// Click anywhere on the header row (SPEC §9 revised).
        func groupRowToggleExpansion(_ row: GroupRowView, groupID: String)
        /// The activate button — turn this group's members ON as a preset.
        func groupRowActivate(_ row: GroupRowView, groupID: String)
        func groupRowBeginMasterDrag(_ row: GroupRowView, groupID: String)
        func groupRow(_ row: GroupRowView, didSetMaster volume: Int, groupID: String)
        func groupRowEndMasterDrag(_ row: GroupRowView, groupID: String)
        func groupRow(_ row: GroupRowView, didSetMuted muted: Bool, groupID: String)
    }

    /// Control-Center row density (matches `DeviceRowView.rowHeight`) so group
    /// headers and device rows share one rhythm inside the card.
    static let rowHeight: CGFloat = 38

    weak var delegate: Delegate?
    private(set) var group: Group

    private var isActive: Bool
    private var isExpanded: Bool
    private var masterVolume: Int

    private let activateButton = NSButton()
    private let chevronButton = NSButton()
    private let nameLabel = NSTextField(labelWithString: "")
    private let readoutLabel = NSTextField(labelWithString: "")
    private let muteButton = NSButton()
    private let masterSlider = NSSlider()
    private var isDraggingMaster = false
    private var isHovered = false

    /// App-local mouse-moved monitor guaranteeing the group header's hover wash
    /// clears even when the pointer leaves into a region with no tracking area
    /// (the last group row before the inter-card gap/footer). Same root fix as
    /// `DeviceRowView`: `NSTrackingArea` only emits `mouseExited` when the pointer
    /// enters another tracked region, so a row with a dead zone below it never
    /// gets one. General to any row, not a last-row special-case.
    private var mouseMovedMonitor: Any?

    init(group: Group, isActive: Bool, isExpanded: Bool, masterVolume: Int, isMuted: Bool = false) {
        self.group = group
        self.isActive = isActive
        self.isExpanded = isExpanded
        self.masterVolume = masterVolume
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: Self.rowHeight))
        autoresizingMask = [.width]
        translatesAutoresizingMaskIntoConstraints = true
        buildSubviews()
        apply(group: group, isActive: isActive, isExpanded: isExpanded, masterVolume: masterVolume, isMuted: isMuted)
        configureAccessibility()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Model

    func apply(group: Group, isActive: Bool, isExpanded: Bool, masterVolume: Int, isMuted: Bool = false) {
        self.group = group
        self.isActive = isActive
        self.isExpanded = isExpanded
        self.masterVolume = masterVolume

        muteButton.state = isMuted ? .on : .off

        nameLabel.stringValue = group.name
        nameLabel.font = isActive ? .boldSystemFont(ofSize: NSFont.systemFontSize)
                                  : .systemFont(ofSize: NSFont.systemFontSize)

        activateButton.image = NSImage(
            systemSymbolName: isActive ? "checkmark.circle.fill" : "circle",
            accessibilityDescription: isActive ? "Group is active" : "Activate group"
        )
        activateButton.contentTintColor = isActive ? .controlAccentColor : .secondaryLabelColor

        chevronButton.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: isExpanded ? "Collapse group" : "Expand group"
        )

        // SPEC §9 revised: the master slider + readout show on EVERY group, not
        // just the active one — a non-active group's master sets its members'
        // preset levels.
        readoutLabel.stringValue = "\(masterVolume)"
        if !isDraggingMaster { masterSlider.integerValue = masterVolume }

        configureAccessibility()
        needsDisplay = true
    }

    // MARK: Build

    private func buildSubviews() {
        wantsLayer = true

        configureIconButton(activateButton, action: #selector(activateClicked(_:)))
        configureIconButton(chevronButton, action: #selector(chevronClicked(_:)))

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        readoutLabel.translatesAutoresizingMaskIntoConstraints = false
        readoutLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        readoutLabel.textColor = .secondaryLabelColor
        readoutLabel.alignment = .right
        readoutLabel.setContentHuggingPriority(.required, for: .horizontal)

        muteButton.translatesAutoresizingMaskIntoConstraints = false
        muteButton.isBordered = false
        muteButton.imagePosition = .imageOnly
        muteButton.setButtonType(.pushOnPushOff)
        muteButton.image = NSImage(
            systemSymbolName: "speaker.wave.2.fill",
            accessibilityDescription: "Mute group")
        muteButton.alternateImage = NSImage(
            systemSymbolName: "speaker.slash.fill",
            accessibilityDescription: "Unmute group")
        muteButton.contentTintColor = .secondaryLabelColor
        muteButton.target = self
        muteButton.action = #selector(muteClicked(_:))
        muteButton.setContentHuggingPriority(.required, for: .horizontal)

        masterSlider.translatesAutoresizingMaskIntoConstraints = false
        masterSlider.minValue = 0
        masterSlider.maxValue = 100
        masterSlider.isContinuous = true
        masterSlider.target = self
        masterSlider.action = #selector(masterChanged(_:))

        addSubview(activateButton)
        addSubview(chevronButton)
        addSubview(nameLabel)
        addSubview(readoutLabel)
        addSubview(muteButton)
        addSubview(masterSlider)

        // Group rows lay out against the SHARED column grid (task B): the
        // activate button + chevron occupy the leading zone (in place of a device
        // row's toggle); the name is the flexible column; the master slider and
        // `%` readout are anchored off the TRAILING edge so they line up exactly
        // with the device-row and Main-Out sliders. Group rows have no trailing
        // control (no mute), so that slot is left empty — but the readout/slider
        // still align because they clear the reserved trailing-control column.
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),

            activateButton.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                    constant: PopoverColumnGrid.leadingInset - 4),
            activateButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            activateButton.widthAnchor.constraint(equalToConstant: 18),

            chevronButton.leadingAnchor.constraint(equalTo: activateButton.trailingAnchor, constant: 4),
            chevronButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronButton.widthAnchor.constraint(equalToConstant: 14),

            nameLabel.leadingAnchor.constraint(equalTo: chevronButton.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Name yields to the mute button (which sits between name and slider)
            // so it truncates instead of pushing the aligned controls out of place.
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: muteButton.leadingAnchor,
                constant: -PopoverColumnGrid.nameToSlider),

            muteButton.trailingAnchor.constraint(
                equalTo: masterSlider.leadingAnchor, constant: -PopoverColumnGrid.muteToSlider),
            muteButton.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.muteWidth),
            muteButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            masterSlider.centerYAnchor.constraint(equalTo: centerYAnchor),
            masterSlider.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.sliderWidth),
            masterSlider.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -PopoverColumnGrid.sliderTrailing),

            readoutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            readoutLabel.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.readoutWidth),
            readoutLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -PopoverColumnGrid.readoutTrailing),
        ])
    }

    private func configureIconButton(_ button: NSButton, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .accessoryBar
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: Row click → expansion (SPEC §9 revised: click anywhere on the row)
    //
    // The activate button, chevron, and master slider are subviews that consume
    // their own clicks (their `hitTest` returns them). A click that lands on the
    // row itself (empty space, name, readout) reaches `mouseDown` here and
    // toggles expansion — "click anywhere on the header row."

    public override func mouseDown(with event: NSEvent) {
        delegate?.groupRowToggleExpansion(self, groupID: group.id)
    }

    // Let the name/readout labels pass clicks through to the row (they are not
    // interactive controls), so clicking the name also toggles expansion.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === nameLabel || hit === readoutLabel { return self }
        return hit
    }

    // MARK: Actions

    @objc private func activateClicked(_ sender: NSButton) {
        delegate?.groupRowActivate(self, groupID: group.id)
    }

    @objc private func chevronClicked(_ sender: NSButton) {
        delegate?.groupRowToggleExpansion(self, groupID: group.id)
    }

    // The mute button consumes its own click (its `hitTest` returns it, so this
    // never falls through to `mouseDown` → expansion).
    @objc private func muteClicked(_ sender: NSButton) {
        delegate?.groupRow(self, didSetMuted: sender.state == .on, groupID: group.id)
    }

    @objc private func masterChanged(_ sender: NSSlider) {
        let event = NSApp.currentEvent
        if !isDraggingMaster {
            isDraggingMaster = true
            delegate?.groupRowBeginMasterDrag(self, groupID: group.id)
        }
        delegate?.groupRow(self, didSetMaster: sender.integerValue, groupID: group.id)
        readoutLabel.stringValue = "\(sender.integerValue)"
        if event?.type == .leftMouseUp {
            isDraggingMaster = false
            delegate?.groupRowEndMasterDrag(self, groupID: group.id)
        }
    }

    // MARK: Hover + background

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    public override func mouseEntered(with event: NSEvent) { setHovered(true) }
    public override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// Set the transient hover flag, repainting only on an actual change.
    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
    }

    /// True iff the pointer is currently inside this row's bounds.
    private func pointerIsInside() -> Bool {
        guard let window = window else { return false }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let local = convert(windowPoint, from: nil)
        return bounds.contains(local)
    }

    /// Reconcile hover from the real pointer position — the general root-cause fix
    /// for a hover that "sticks" on a row with an untracked dead zone below it
    /// (the bottom-most row). `NSTrackingArea` emits `mouseExited` only on a
    /// crossing into another tracked region, which never happens there.
    private func refreshHoverFromPointer() { setHovered(pointerIsInside()) }

    /// Drop any transient hover when the row is (un)mounted so it can't stick as a
    /// stale highlight if the pointer leaves without a matching `mouseExited`
    /// (T-U8), and (un)install the mouse-moved monitor that catches the pointer
    /// leaving into an untracked dead zone.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
        needsDisplay = true
        if window != nil {
            installMouseMovedMonitor()
        } else {
            removeMouseMovedMonitor()
        }
    }

    private func installMouseMovedMonitor() {
        guard mouseMovedMonitor == nil else { return }
        mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.refreshHoverFromPointer()
            return event
        }
    }

    private func removeMouseMovedMonitor() {
        if let monitor = mouseMovedMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMovedMonitor = nil
        }
    }

    deinit { removeMouseMovedMonitor() }

    public override func draw(_ dirtyRect: NSRect) {
        // Active group → a subtle accent wash; hover → the standard row hover.
        let rect = bounds.insetBy(dx: 5, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        if isActive {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            path.fill()
        } else if isHovered {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12).setFill()
            path.fill()
        }
        nameLabel.textColor = .labelColor
        super.draw(dirtyRect)
    }

    // MARK: Accessibility

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let state = isActive ? "active" : "inactive"
        let expanded = isExpanded ? "expanded" : "collapsed"
        setAccessibilityLabel("Group \(group.name), \(state), \(expanded), master volume \(masterVolume) percent")

        activateButton.setAccessibilityLabel(isActive ? "\(group.name) is active" : "Activate \(group.name)")
        chevronButton.setAccessibilityLabel(isExpanded ? "Collapse \(group.name)" : "Expand \(group.name)")
        masterSlider.setAccessibilityRole(.slider)
        masterSlider.setAccessibilityLabel("\(group.name) master volume")
    }

    // MARK: Test-support hooks

    /// The master slider's current integer value (structural assertions).
    public var test_masterSliderValue: Int { masterSlider.integerValue }
    /// Whether the master slider is visible (must be true on EVERY group).
    public var test_masterSliderVisible: Bool { !masterSlider.isHidden }

    /// Whether the group master-mute button is in its muted (on) state.
    var test_isMuted: Bool { muteButton.state == .on }

    /// Whether a transient hover wash is currently active.
    var test_isHovered: Bool { isHovered }

    /// Simulate the pointer entering this row.
    func test_simulateMouseEntered() { setHovered(true) }

    /// Simulate a pointer-move reconcile where the pointer is NO LONGER inside the
    /// row, WITHOUT a `mouseExited:` — the last-row dead-zone case. Hover must
    /// clear. General to any row.
    func test_reconcileHover(pointerInside: Bool) { setHovered(pointerInside) }
}
