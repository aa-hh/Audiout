// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit

/// A single row of the popover's future **Applications** card
/// (PLAN-POPOVER-ROUTING.md §A/§C task T-6): app icon · truncating name ·
/// always-visible `ControlCenterSlider` (dimmed while the app plays on the
/// current device, decision 3) · `%` readout · a trailing "redirect audio to…"
/// `NSPopUpButton` sectioned **Current Device** / **AirPlay Devices** (decision
/// 4 — no Groups section) · a hover-revealed remove (✕) affordance.
///
/// Laid out on the shared ``PopoverColumnGrid`` exactly like `DeviceRowView`,
/// so its slider/trailing-control columns line up with every other row type
/// in the popover.
///
/// Pure UI, like `DeviceRowView`/`MainOutRowView`: every control routes back
/// through ``Delegate`` so the host (`PopoverController`, wired to the new
/// `AppRoutingController` per PLAN task T-8) can persist the change. This view
/// NEVER touches a backend, a store, or (per T-6's isolation requirement) the
/// `AppRoute`/`AppRouteStore` types being built in parallel — it takes only
/// plain values via ``Configuration``.
public final class AppRowView: NSView {

    /// Callbacks for the row's controls. The host maps these onto
    /// `AppRoutingController.setAppVolume`/`setAppRoute`/`removeAppRoute`.
    public protocol Delegate: AnyObject {
        func appRow(_ row: AppRowView, didSetVolume volume: Int, for appID: String)
        /// The user picked a redirect destination from the trailing popup.
        /// `destinationID` is one of the ids passed in ``Configuration/destinations``
        /// (the local "Current Device" entry or an AirPlay device id).
        func appRow(_ row: AppRowView, didSelectDestination destinationID: String, for appID: String)
        /// The user clicked the hover-revealed ✕ to remove this app row entirely.
        func appRow(_ row: AppRowView, didRemoveFor appID: String)
    }

    /// One entry in the destination popup (either the local "Current Device"
    /// row or an AirPlay device). Plain values only (T-6 isolation requirement
    /// — no `AppRoute`/`AppRouteStore` dependency).
    public struct Destination {
        public let id: String
        public let title: String
        public let isLocal: Bool
        public let symbolName: String?
        public init(id: String, title: String, isLocal: Bool, symbolName: String? = nil) {
            self.id = id; self.title = title; self.isLocal = isLocal; self.symbolName = symbolName
        }
    }

    /// The plain-value snapshot the host pushes into ``apply(_:)``.
    public struct Configuration {
        public let appID: String
        public let name: String
        /// The app's icon, supplied by the HOST (`NSWorkspace`/`NSRunningApplication`
        /// live upstream of this view — T-6 forbids this view from touching them).
        public let icon: NSImage?
        public let volume: Int
        /// The currently selected destination id (matches one entry in `destinations`).
        public let selectedDestinationID: String
        /// All destinations to populate the trailing popup with, in display order:
        /// the local "Current Device" entry(ies) first, then AirPlay devices.
        public let destinations: [Destination]
        public init(appID: String, name: String, icon: NSImage?, volume: Int,
                   selectedDestinationID: String, destinations: [Destination]) {
            self.appID = appID
            self.name = name
            self.icon = icon
            self.volume = volume
            self.selectedDestinationID = selectedDestinationID
            self.destinations = destinations
        }
    }

    /// Same comfortable Control-Center row density as `DeviceRowView`, plus the
    /// row must also seat the hover-revealed remove button.
    public static let rowHeight: CGFloat = 38

    public weak var delegate: Delegate?
    public private(set) var appID: String = ""
    private var destinations: [Destination] = []
    /// True iff the selected destination is a local ("Current Device") entry —
    /// LOCKED DECISION 3: the slider stays visible but dims/disables in this
    /// state (the app isn't being redirected anywhere).
    private var isLocal: Bool = true

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let slider = ControlCenterSlider()
    private let readoutLabel = NSTextField(labelWithString: "")
    private let destinationPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Hover-revealed remove affordance (HoverActionButton idiom — a borderless
    /// button that paints its own subtle hover highlight, since `HoverActionButton`
    /// itself lives in the popover UI target and isn't visible from here).
    private let removeButton = RowHoverButton()

    private var isDraggingSlider = false
    /// Transient pointer-hover state, reconciled exactly like `DeviceRowView`'s
    /// sticky-hover fix (PLAN risk 2): cleared on every model refresh and on
    /// re-parenting, backed by an app-local mouse-moved monitor so a hover can
    /// never "stick" after the pointer leaves without a matching `mouseExited`.
    private var isHovered: Bool = false {
        didSet { if isHovered != oldValue { removeButton.isHidden = !isHovered; setNeedsDisplay(bounds) } }
    }
    private var mouseMovedMonitor: Any?

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: Self.rowHeight))
        autoresizingMask = [.width]
        translatesAutoresizingMaskIntoConstraints = true
        buildSubviews()
        configureAccessibility()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Model

    public func apply(_ configuration: Configuration) {
        self.appID = configuration.appID
        self.destinations = configuration.destinations
        self.isLocal = configuration.destinations.first { $0.id == configuration.selectedDestinationID }?.isLocal
            ?? true
        // A model refresh clears any transient hover, matching `DeviceRowView`'s
        // T-U8 fix (PLAN risk 2) — hover is transient, never model-driven.
        self.isHovered = false

        iconView.image = configuration.icon
        nameLabel.stringValue = configuration.name

        if !isDraggingSlider {
            slider.integerValue = configuration.volume
            readoutLabel.stringValue = "\(configuration.volume)%"
        }
        // LOCKED DECISION 3: always visible, dimmed/disabled while local — same
        // dimming approach `DeviceRowView` uses for an unavailable/unselected row.
        slider.isEnabled = !isLocal
        readoutLabel.textColor = isLocal ? .tertiaryLabelColor : .secondaryLabelColor

        rebuildDestinationMenu(selecting: configuration.selectedDestinationID)
        configureAccessibility()
        setNeedsDisplay(bounds)
    }

    private func rebuildDestinationMenu(selecting selectedID: String) {
        let menu = NSMenu()
        var currentItem: NSMenuItem?

        func addHeader(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = NSAttributedString(
                string: title.uppercased(),
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ])
            menu.addItem(item)
        }

        // Two sections only (LOCKED DECISION 4 — no Groups): local entries under
        // "Current Device", then AirPlay devices under "AirPlay Devices". Headers
        // are disabled section titles styled like `MainOutRowView`'s.
        let localEntries = destinations.filter(\.isLocal)
        let deviceEntries = destinations.filter { !$0.isLocal }

        if !localEntries.isEmpty {
            addHeader("Current Device")
            for entry in localEntries {
                let item = menuItem(for: entry, isCurrent: entry.id == selectedID)
                menu.addItem(item)
                if entry.id == selectedID { currentItem = item }
            }
        }
        if !deviceEntries.isEmpty {
            addHeader("AirPlay Devices")
            for entry in deviceEntries {
                let item = menuItem(for: entry, isCurrent: entry.id == selectedID)
                menu.addItem(item)
                if entry.id == selectedID { currentItem = item }
            }
        }

        destinationPopUp.menu = menu
        if let currentItem { destinationPopUp.select(currentItem) }
    }

    private func menuItem(for entry: Destination, isCurrent: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: #selector(destinationChanged(_:)), keyEquivalent: "")
        item.target = self
        item.state = isCurrent ? .on : .off
        item.representedObject = entry.id
        if let symbolName = entry.symbolName {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        }
        return item
    }

    // MARK: Build

    private func buildSubviews() {
        wantsLayer = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .menuFont(ofSize: 0)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minValue = 0
        slider.maxValue = 100
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(volumeChanged(_:))

        readoutLabel.translatesAutoresizingMaskIntoConstraints = false
        readoutLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        readoutLabel.textColor = .secondaryLabelColor
        readoutLabel.alignment = .right
        readoutLabel.setContentHuggingPriority(.required, for: .horizontal)

        destinationPopUp.translatesAutoresizingMaskIntoConstraints = false
        destinationPopUp.pullsDown = false
        destinationPopUp.controlSize = .small
        destinationPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        (destinationPopUp.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        destinationPopUp.setContentHuggingPriority(.required, for: .horizontal)
        destinationPopUp.setContentCompressionResistancePriority(.required, for: .horizontal)

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.isBordered = false
        removeButton.setButtonType(.momentaryChange)
        removeButton.imagePosition = .imageOnly
        let removeConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove")?
            .withSymbolConfiguration(removeConfig)
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.target = self
        removeButton.action = #selector(removeTapped(_:))
        removeButton.isHidden = true

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(slider)
        addSubview(readoutLabel)
        addSubview(destinationPopUp)
        addSubview(removeButton)

        // Laid out against the shared `PopoverColumnGrid` exactly like
        // `DeviceRowView`: icon leads, slider/`%`/trailing popup are anchored off
        // the row's TRAILING edge so they line up with every other row type. The
        // remove ✕ sits in the row's leading margin dead-zone (over the icon,
        // hover-revealed) so it needs no extra reserved column — WIDTH CHECK
        // (PLAN risk 3) below confirms the name column survives at 623pt.
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor,
                                              constant: PopoverColumnGrid.leadingInset),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),
            iconView.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                               constant: PopoverColumnGrid.iconToName),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: slider.leadingAnchor,
                constant: -PopoverColumnGrid.nameToSlider),

            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.sliderWidth),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor,
                                             constant: -PopoverColumnGrid.sliderTrailing),

            readoutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            readoutLabel.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.readoutWidth),
            readoutLabel.leadingAnchor.constraint(
                equalTo: slider.trailingAnchor, constant: PopoverColumnGrid.sliderToReadout),

            destinationPopUp.centerYAnchor.constraint(equalTo: centerYAnchor),
            destinationPopUp.widthAnchor.constraint(
                equalToConstant: PopoverColumnGrid.trailingControlWidth),
            destinationPopUp.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -PopoverColumnGrid.trailingControlTrailing),

            // The ✕ floats over the icon's leading margin (hidden until hover), so
            // it costs no reserved column and doesn't compete with the name for
            // width — the tight budget the width check below is about.
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),
            removeButton.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),
        ])
    }

    // MARK: Actions

    @objc private func volumeChanged(_ sender: NSSlider) {
        isDraggingSlider = true
        let event = NSApp.currentEvent
        if event?.type == .leftMouseUp { isDraggingSlider = false }
        readoutLabel.stringValue = "\(sender.integerValue)%"
        delegate?.appRow(self, didSetVolume: sender.integerValue, for: appID)
    }

    @objc private func destinationChanged(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.appRow(self, didSelectDestination: id, for: appID)
    }

    @objc private func removeTapped(_ sender: NSButton) {
        delegate?.appRow(self, didRemoveFor: appID)
    }

    // MARK: Hover discipline (mirrors DeviceRowView's sticky-hover fix, PLAN risk 2)

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }

    private func pointerIsInside() -> Bool {
        guard let window = window else { return false }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let local = convert(windowPoint, from: nil)
        return bounds.contains(local)
    }

    /// Belt-and-suspenders against a sticky hover, exactly like `DeviceRowView`:
    /// re-parenting (a popover rebuild) clears any transient hover, and an
    /// app-local mouse-moved monitor reconciles hover against the true pointer
    /// position so leaving the row into an untracked dead zone still clears it.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
        if window != nil {
            installMouseMovedMonitor()
        } else {
            removeMouseMovedMonitor()
        }
    }

    private func installMouseMovedMonitor() {
        guard mouseMovedMonitor == nil else { return }
        mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self else { return event }
            self.isHovered = self.pointerIsInside()
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

    // MARK: Accessibility

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(nameLabel.stringValue), volume \(slider.integerValue) percent")
        slider.setAccessibilityRole(.slider)
        slider.setAccessibilityLabel("\(nameLabel.stringValue) volume")
        destinationPopUp.setAccessibilityLabel("\(nameLabel.stringValue) destination")
        removeButton.setAccessibilityLabel("Remove \(nameLabel.stringValue)")
    }

    // MARK: Test-support hooks
    //
    // Neither a headless process nor an offscreen window synthesizes the mouse
    // events a real slider drag / popup selection / button click needs. These
    // drive exactly the same code paths as the real control actions.

    /// Simulate the user dragging this row's slider to `volume`.
    public func test_setVolume(_ volume: Int) {
        delegate?.appRow(self, didSetVolume: volume, for: appID)
    }

    /// Simulate the user picking `destinationID` from the trailing popup.
    public func test_selectDestination(_ destinationID: String) {
        delegate?.appRow(self, didSelectDestination: destinationID, for: appID)
    }

    /// Simulate the user clicking the hover-revealed remove (✕) affordance.
    public func test_remove() {
        delegate?.appRow(self, didRemoveFor: appID)
    }

    /// The currently displayed volume (structural assertions).
    public var test_volume: Int { slider.integerValue }
    /// Whether the volume slider is currently dimmed/disabled (LOCKED DECISION 3
    /// — true iff the destination is "Current device"/local).
    public var test_isSliderDimmed: Bool { !slider.isEnabled }
    /// The full ordered list of titles in the destination menu, including the
    /// two disabled section headers ("CURRENT DEVICE" / "AIRPLAY DEVICES").
    public var test_menuTitles: [String] { destinationPopUp.menu?.items.map(\.title) ?? [] }
    /// The currently checkmarked destination id.
    public var test_selectedDestinationID: String? {
        destinationPopUp.selectedItem?.representedObject as? String
    }
    /// Whether the hover-revealed remove affordance is currently shown.
    public var test_isRemoveButtonVisible: Bool { !removeButton.isHidden }

    /// Simulate the pointer entering this row (as a real `mouseEntered:` would).
    public func test_simulateMouseEntered() { isHovered = true }
    /// Simulate a pointer-move reconcile where the pointer is no longer inside
    /// the row, without AppKit ever delivering `mouseExited:` (the last-row
    /// dead-zone case `DeviceRowView` guards against).
    public func test_reconcileHover(pointerInside: Bool) { isHovered = pointerInside }
}

/// Minimal borderless hover-highlight button used by ``AppRowView``'s remove
/// affordance. `HoverActionButton` (the popover UI's footer-action button)
/// lives in `AirPlayControllerPopoverUI` and isn't visible from
/// `AirPlayControllerSharedUI`, so this is the same hover-reconcile idiom
/// (mouse-moved monitor, not just enter/exit) scoped to this target.
final class RowHoverButton: NSButton {
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var moveMonitor: Any?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = moveMonitor { NSEvent.removeMonitor(m); moveMonitor = nil }
        isHovered = false
        guard window != nil else { return }
        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self, let window = self.window else { return event }
            let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            self.isHovered = self.bounds.contains(point)
            return event
        }
    }

    deinit { if let m = moveMonitor { NSEvent.removeMonitor(m) } }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered && isEnabled {
            let rect = bounds.insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(ovalIn: rect)
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            path.fill()
        }
        super.draw(dirtyRect)
    }
}

// MARK: - AddApplicationRowView

/// A full-width borderless "+ Add application…" row (PLAN decision 6): sits at
/// the bottom of the Applications card body and doubles as the empty state.
/// Hover-highlights per the `HoverActionButton` idiom. Pure UI — the host wires
/// ``onAdd`` to open the running-app picker (T-7, built elsewhere).
public final class AddApplicationRowView: NSView {

    /// Same row height as `AppRowView` so it reads as one more row in the card.
    public static let rowHeight: CGFloat = 30

    /// Called when the user clicks the row.
    public var onAdd: (() -> Void)?

    private let button = RowHoverButton()

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: Self.rowHeight))
        autoresizingMask = [.width]
        translatesAutoresizingMaskIntoConstraints = true
        buildSubviews()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildSubviews() {
        wantsLayer = true

        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.alignment = .left
        button.font = .menuFont(ofSize: 0)
        button.contentTintColor = .secondaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        button.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        button.imagePosition = .imageLeading
        button.title = "Add application…"
        button.target = self
        button.action = #selector(tapped(_:))
        button.setAccessibilityLabel("Add application")

        addSubview(button)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),
            button.leadingAnchor.constraint(equalTo: leadingAnchor,
                                            constant: PopoverColumnGrid.leadingInset),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                             constant: -PopoverColumnGrid.trailingInset),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func tapped(_ sender: NSButton) { onAdd?() }

    /// Simulate the user clicking the row.
    public func test_tap() { onAdd?() }
}
