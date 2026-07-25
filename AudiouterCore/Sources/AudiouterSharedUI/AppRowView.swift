// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// A single row of the popover's future **Applications** card
/// (PLAN-POPOVER-ROUTING.md §A/§C task T-6): app icon · truncating name ·
/// always-visible `NSSlider` (dimmed while the app plays on the
/// current device, decision 3) · `%` readout · a trailing "redirect audio to…"
/// `NSPopUpButton` sectioned **Current Device** / **AirPlay Devices** (decision
/// 4 — no Groups section). Removal is no longer a per-row hover affordance —
/// it's the Applications card's ± footer segmented control, a "Remove from
/// list" context-menu item, and Delete/Backspace on the selected row, all
/// routed through `Delegate.appRow(_:didRemoveFor:)`.
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
    /// `AppRoutingController.setVolume(_:for:)`/`setDestination(_:for:)`/`removeRoute(bundleID:)`.
    public protocol Delegate: AnyObject {
        func appRow(_ row: AppRowView, didSetVolume volume: Int, for appID: String)
        /// The user picked a redirect destination from the trailing popup.
        /// `destinationID` is one of the ids passed in ``Configuration/destinations``
        /// (the local "Current Device" entry or an AirPlay device id).
        func appRow(_ row: AppRowView, didSelectDestination destinationID: String, for appID: String)
        /// The user removed this app row entirely, via the ± footer's "−"
        /// segment, the row's "Remove from list" context-menu item, or
        /// Delete/Backspace on the selected row — all three paths funnel
        /// through this single call.
        func appRow(_ row: AppRowView, didRemoveFor appID: String)
        /// The user clicked the row body (icon/name/dead-zone — NOT the slider or
        /// destination popup) or right-clicked it, requesting this row become the
        /// list's single selection. The HOST owns "which bundleID is selected" —
        /// this view only reports intent and renders whatever `test_setSelected`/
        /// the next `apply` tells it. The host re-pushes selection into every row
        /// recreated by a `PopoverController.rebuild()`.
        func appRow(_ row: AppRowView, didRequestSelect appID: String)
        /// The user pressed the Up/Down arrow key while this row was the first
        /// responder (dispatched via the `moveUp(_:)`/`moveDown(_:)`
        /// `NSStandardKeyBindingResponding` overrides below — the same
        /// dispatch family as `deleteForward`/`deleteBackward`), requesting the
        /// list's single selection move to the previous/next row. This view has
        /// no notion of "which row is next" — the HOST owns list order — so it
        /// only reports intent; a default no-op is provided below so existing
        /// conformers keep compiling without adopting this.
        func appRow(_ row: AppRowView, didRequestMoveSelection direction: MoveDirection, for appID: String)
    }

    /// Which way `moveUp(_:)`/`moveDown(_:)` requests the selection move.
    public enum MoveDirection: Equatable {
        case up
        case down
    }

    /// One entry in the destination popup: the standalone "No Redirect" entry,
    /// a local "Current Device" row, or an AirPlay device. Plain values only
    /// (T-6 isolation requirement — no `AppRoute`/`AppRouteStore` dependency).
    public struct Destination {
        public let id: String
        public let title: String
        /// True for BOTH the standalone "No Redirect" entry and the "Current
        /// Device" entry — anything meaning "plays locally," which is what
        /// drives the volume slider's dim/disable state. `false` only for an
        /// AirPlay device entry.
        public let isLocal: Bool
        public let symbolName: String?
        /// True for the standalone "No Redirect" entry, and also for a
        /// per-row "Resume → <device>" entry a host may prepend (e.g.
        /// `PopoverController` offering a one-click way back to a device an
        /// app-quit reset cleared) — anything rendered first, with no section
        /// header, above the "Current Device"/"AirPlay Devices" sections (the
        /// default/neutral choice and any "get back to this" shortcut, both
        /// visually distinct from the named sections). Every other entry
        /// (including "Current Device" and a plain device entry) leaves this
        /// `false`.
        public let isStandalone: Bool
        /// Optional secondary line of copy shown under `title` in the
        /// destination menu (e.g. clarifying what "No Redirect" or "Current
        /// Device" means) and as the menu item's tooltip. `nil` renders exactly
        /// as before — a single-line plain title. This view never invents this
        /// copy; the HOST supplies it (a later task passes real strings for the
        /// standalone "No Redirect" and local "Current Device" entries).
        public let subtitle: String?
        public init(id: String, title: String, isLocal: Bool, symbolName: String? = nil,
                   isStandalone: Bool = false, subtitle: String? = nil) {
            self.id = id; self.title = title; self.isLocal = isLocal; self.symbolName = symbolName
            self.isStandalone = isStandalone
            self.subtitle = subtitle
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
        /// Whether the app's process is currently running (T4). When `false`, the
        /// row shows a small offline badge (`exclamationmark.circle`) on the icon
        /// and dims the name, so the user can see the route is saved but inactive.
        /// The row remains fully interactive while offline (they can still change
        /// the route destination). Defaults to `true` so existing callers and
        /// tests that don't pass this field see no behavior change.
        public let isRunning: Bool
        public init(appID: String, name: String, icon: NSImage?, volume: Int,
                   selectedDestinationID: String, destinations: [Destination],
                   isRunning: Bool = true) {
            self.appID = appID
            self.name = name
            self.icon = icon
            self.volume = volume
            self.selectedDestinationID = selectedDestinationID
            self.destinations = destinations
            self.isRunning = isRunning
        }
    }

    /// Shares `DeviceRowView`'s body-row height (`PopoverColumnGrid.bodyRowHeight`)
    /// — a deliberate density unification: this row used to stand alone at 38pt,
    /// now it renders at the same 42pt as every other popover row so the whole
    /// list reads as one cohesive density instead of two interleaved ones.
    public static let rowHeight: CGFloat = PopoverColumnGrid.bodyRowHeight

    public weak var delegate: Delegate?
    public private(set) var appID: String = ""
    private var destinations: [Destination] = []
    /// True iff the selected destination is the standalone "No Redirect" entry
    /// (`isStandalone`) — the neutral/unset state where the app just plays in the
    /// whole-system mix. The slider stays visible but dims/disables ONLY in this
    /// state: an app on "No Redirect" has no independent stream to level. Both
    /// "Current Device" (Bug T2 — its own local built-in-speaker stream) and an
    /// AirPlay device (its own remote stream) DO have an independent volume, so
    /// the slider is live for them.
    private var isNoRedirect: Bool = true

    private let iconView = NSImageView()
    /// Small SF Symbol badge overlaid on the icon when the app is not running
    /// (T4). Hidden by default; shown when `isRunning == false`. Uses
    /// `exclamationmark.circle.fill` with a yellow-ish secondary tint so it
    /// reads as "warning/offline" without being red/alarming — the route is
    /// intact, the app just isn't running.
    private let offlineBadge = NSImageView()

    /// The leading VU meter (task T4), mounted only when `showsMeter` is
    /// true — mirrors `DeviceRowView`'s `LevelMeterView`. No per-app level
    /// signal exists yet (see `AudiouterSharedUI/AGENTS.md`), so nothing
    /// drives this automatically; a future per-stream metering seam calls
    /// ``setLevel(_:)`` directly.
    private let meterView = LevelMeterView()
    /// Whether the leading VU meter column is shown. Defaults to `false` so
    /// every existing caller (today, none pass `true`) sees no layout change.
    private let showsMeter: Bool
    /// The most recently pushed meter level, for ``test_meterLevel()``. `0`
    /// when there's no meter or after a ``resetLevel()``.
    private var lastMeterLevel: Float = 0
    private let nameLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let readoutLabel = NSTextField(labelWithString: "")
    private let destinationPopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    private var isDraggingSlider = false

    /// Single-selection render state (T1 seam). The HOST owns which bundleID is
    /// selected across the whole Applications list — this view only renders
    /// whatever it's told via `apply`'s isSelected flag or `test_setSelected`,
    /// and reports a *request* to select via `Delegate.appRow(_:didRequestSelect:)`
    /// when its body is clicked. Like hover, it is cleared on every `apply` call
    /// site that doesn't explicitly re-assert it (see `apply(_:isSelected:)`).
    private var isSelected: Bool = false {
        didSet { if isSelected != oldValue { setNeedsDisplay(bounds) } }
    }

    /// Transient hover render state, kept SEPARATE from selection so the two
    /// draw in different colours (neutral hover vs accent selection). Reconciled
    /// against the true pointer position (sticky-hover discipline) and cleared
    /// on every `apply` and re-parenting.
    private var isHovered: Bool = false {
        didSet { if isHovered != oldValue { setNeedsDisplay(bounds) } }
    }
    private var hoverMoveMonitor: Any?

    public init(showsMeter: Bool = false) {
        self.showsMeter = showsMeter
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
        // Dim the slider ONLY for the standalone "No Redirect" entry. A missing
        // selection (nothing matched) is treated as "No Redirect" (dimmed), the
        // safe neutral default.
        self.isNoRedirect = configuration.destinations
            .first { $0.id == configuration.selectedDestinationID }?.isStandalone ?? true
        // `apply(_:)` (no selection param) is the "clear like hover used to be"
        // where the caller doesn't care about selection. `PopoverController`
        // (T3) re-asserts selection across a `rebuild()` by calling
        // `apply(_:isSelected:)` or `test_setSelected` right after `apply`.
        self.isSelected = false
        self.isHovered = false

        iconView.image = configuration.icon
        nameLabel.stringValue = configuration.name

        if !isDraggingSlider {
            slider.integerValue = configuration.volume
            readoutLabel.stringValue = "\(configuration.volume)%"
        }
        // Always visible, dimmed/disabled ONLY on "No Redirect" — same dimming
        // approach `DeviceRowView` uses for an unavailable/unselected row. "Current
        // Device" (Bug T2) and AirPlay routes each have their own stream, so the
        // slider is live for them.
        slider.isEnabled = !isNoRedirect
        readoutLabel.textColor = isNoRedirect ? .tertiaryLabelColor : .secondaryLabelColor

        // T4 offline indicator: badge and dimmed icon/name when not running.
        let isRunning = configuration.isRunning
        offlineBadge.isHidden = isRunning
        iconView.alphaValue = isRunning ? 1.0 : 0.5
        nameLabel.textColor = isRunning ? .labelColor : .secondaryLabelColor

        rebuildDestinationMenu(selecting: configuration.selectedDestinationID)
        configureAccessibility()
        setNeedsDisplay(bounds)
    }

    /// Push a live RMS reading into the leading VU meter (task T4). No-op when
    /// `showsMeter` is false. Mirrors `DeviceRowView.setLevel(_:)`.
    public func setLevel(_ rms: Float) {
        guard showsMeter else { return }
        lastMeterLevel = rms
        meterView.setLevel(rms)
    }

    /// Zero the leading VU meter with no animation. No-op when `showsMeter`
    /// is false. Mirrors `DeviceRowView.resetLevel()`.
    public func resetLevel() {
        guard showsMeter else { return }
        meterView.reset()
        lastMeterLevel = 0
    }

    /// Same as `apply(_:)`, but atomically re-asserts selection afterward —
    /// the host's seam for surviving `PopoverController.rebuild()` (which
    /// recreates every row) without a visible deselect/reselect flicker. The
    /// HOST is the source of truth for "which bundleID is selected"; pass the
    /// result of comparing `configuration.appID` against its stored
    /// `selectedAppBundleID`.
    public func apply(_ configuration: Configuration, isSelected: Bool) {
        apply(configuration)
        self.isSelected = isSelected
    }

    private func rebuildDestinationMenu(selecting selectedID: String) {
        // `allowsAttributedSubtitle: false` — this menu is assigned directly to
        // `destinationPopUp`, and `NSPopUpButton` mirrors its SELECTED item's
        // `attributedTitle` for the button's own (collapsed) display. A
        // multi-line title+subtitle there would corrupt the popup's own label,
        // so this instance keeps every item's title plain; the subtitle still
        // reaches the user via `toolTip`.
        let (menu, currentItem) = buildDestinationMenu(
            selecting: selectedID, action: #selector(destinationChanged(_:)),
            allowsAttributedSubtitle: false)
        destinationPopUp.menu = menu
        if let currentItem { destinationPopUp.select(currentItem) }
    }

    /// Shared builder behind both the trailing destination popup and the
    /// context menu's "Route to" submenu (T5) — same structure, same entries,
    /// same checkmark, just a caller-supplied action selector so each host can
    /// route the pick back through `destinationChanged(_:)`.
    ///
    /// Structure: every standalone entry (in `destinations`' own order — the
    /// host may prepend a "Resume → <device>" entry ahead of the fixed "No
    /// Redirect" entry) FIRST, with no header (the default/neutral choice and
    /// any "get back to this" shortcut, visually distinct from every named
    /// section), then a separator, then the same two sections as before
    /// (LOCKED DECISION 4 — no Groups): "Current Device", then "AirPlay
    /// Devices".
    ///
    /// - Parameter allowsAttributedSubtitle: whether an entry's `subtitle`
    ///   (A3) may render as a second attributed line under the title. Pass
    ///   `false` for a menu that gets assigned to an `NSPopUpButton` directly
    ///   (its collapsed button mirrors the selected item's `attributedTitle`);
    ///   a menu-only context (e.g. the context menu's "Route to" submenu,
    ///   which never collapses into a button) can pass `true`.
    private func buildDestinationMenu(
        selecting selectedID: String, action: Selector, allowsAttributedSubtitle: Bool = true
    ) -> (menu: NSMenu, currentItem: NSMenuItem?) {
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

        func addEntries(_ entries: [Destination]) {
            for entry in entries {
                let item = menuItem(
                    for: entry, isCurrent: entry.id == selectedID, action: action,
                    allowsAttributedSubtitle: allowsAttributedSubtitle)
                menu.addItem(item)
                if entry.id == selectedID { currentItem = item }
            }
        }

        // The standalone "No Redirect" entry sits above every section, with no
        // header of its own — it's the neutral default, not a member of
        // either named group.
        let standaloneEntries = destinations.filter(\.isStandalone)
        let localEntries = destinations.filter { $0.isLocal && !$0.isStandalone }
        // `!isStandalone` mirrors `localEntries`'s own exclusion above — without
        // it, a standalone entry that also names a device (e.g. a "Resume →
        // <device>" entry, `isLocal: false`) would render TWICE: once at the
        // top with the other standalone entries, once again down here.
        let deviceEntries = destinations.filter { !$0.isLocal && !$0.isStandalone }

        addEntries(standaloneEntries)
        if !standaloneEntries.isEmpty, !localEntries.isEmpty || !deviceEntries.isEmpty {
            menu.addItem(.separator())
        }
        if !localEntries.isEmpty {
            addHeader("Current Device")
            addEntries(localEntries)
        }
        if !deviceEntries.isEmpty {
            addHeader("AirPlay Devices")
            addEntries(deviceEntries)
        }

        return (menu, currentItem)
    }

    /// - Parameter allowsAttributedSubtitle: see `buildDestinationMenu`'s
    ///   parameter of the same name — `false` keeps `entry.title` as the sole,
    ///   plain title (still setting `toolTip` from `subtitle`); `true` also
    ///   renders `subtitle` as a second attributed line under the title (A3
    ///   destination microcopy).
    private func menuItem(
        for entry: Destination, isCurrent: Bool, action: Selector, allowsAttributedSubtitle: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isCurrent ? .on : .off
        item.representedObject = entry.id
        if let symbolName = entry.symbolName {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        }
        if let subtitle = entry.subtitle {
            item.toolTip = subtitle
            if allowsAttributedSubtitle {
                let attributedTitle = NSMutableAttributedString(
                    string: entry.title,
                    attributes: [.font: NSFont.menuFont(ofSize: 0)])
                attributedTitle.append(NSAttributedString(string: "\n"))
                attributedTitle.append(NSAttributedString(
                    string: subtitle,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
                item.attributedTitle = attributedTitle
            }
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

        // Offline badge (T4): small warning symbol overlaid in the icon's
        // bottom-right corner. Hidden by default; shown when the routed app
        // is not currently running. `.symbolConfiguration` uses the point
        // size that best reads at the icon's 18 pt rendered size.
        let badgeConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemYellow]))
        offlineBadge.image = NSImage(
            systemSymbolName: "exclamationmark.circle.fill",
            accessibilityDescription: "Not running")?
            .withSymbolConfiguration(badgeConfig)
        offlineBadge.translatesAutoresizingMaskIntoConstraints = false
        offlineBadge.isHidden = true   // visible only when !isRunning

        // Leading VU meter (task T4): mounted only when `showsMeter` — no
        // existing caller passes `true` today, so their layout is unaffected.
        // Non-interactive (`LevelMeterView.hitTest` returns nil).
        meterView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        if showsMeter { addSubview(meterView) }
        addSubview(offlineBadge)
        addSubview(nameLabel)
        addSubview(slider)
        addSubview(readoutLabel)
        addSubview(destinationPopUp)

        // Laid out against the shared `PopoverColumnGrid` exactly like
        // `DeviceRowView`: icon leads, slider/`%`/trailing popup are anchored off
        // the row's TRAILING edge so they line up with every other row type.
        // Removal is no longer a floating row control — it's the ± footer
        // segmented control, the row's context menu, and Delete/Backspace, all
        // routed through the same `didRemoveFor(appID:)` delegate call.
        //
        // The meter (when shown) sits at the row's leading edge; the icon then
        // repoints its leading anchor off the meter's trailing edge instead of
        // `firstElementLeading(indented:)` directly — together these land the
        // icon at exactly the same x either way (`firstElementLeading` is
        // defined as leading + meterWidth + meterToLeading), matching
        // `DeviceRowView`'s contract so the icon column never shifts.
        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: Self.rowHeight),

            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),
            iconView.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),

            // Offline badge: pinned to icon's trailing/bottom corner (T4).
            offlineBadge.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 2),
            offlineBadge.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 2),
            offlineBadge.widthAnchor.constraint(equalToConstant: 11),
            offlineBadge.heightAnchor.constraint(equalToConstant: 11),

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
        ]

        if showsMeter {
            constraints.append(contentsOf: [
                meterView.leadingAnchor.constraint(
                    equalTo: leadingAnchor, constant: PopoverColumnGrid.leadingInset),
                meterView.centerYAnchor.constraint(equalTo: centerYAnchor),
                meterView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.meterWidth),
                meterView.heightAnchor.constraint(equalToConstant: 22),
                iconView.leadingAnchor.constraint(
                    equalTo: meterView.trailingAnchor, constant: PopoverColumnGrid.meterToLeading),
            ])
        } else {
            constraints.append(
                iconView.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: PopoverColumnGrid.firstElementLeading(indented: false)))
        }

        NSLayoutConstraint.activate(constraints)
    }

    // MARK: Drawing

    /// Row highlight colour, `nil` when neither selected nor hovered.
    /// Selection and hover use DIFFERENT colours so they read distinctly:
    /// selection is a translucent ACCENT wash; hover is a translucent NEUTRAL
    /// wash (shown only when NOT selected) — both at the unified alphas
    /// `DeviceRowView` shares via `PopoverColumnGrid`, so the two row types
    /// present the same interactive-state styling. Neither uses a fully
    /// opaque system background, which would obscure the row's slider /
    /// readout / destination popup. Factored out of `draw(_:)` so offscreen
    /// tests (which never rasterize `draw(_:)`'s actual pixels) can assert it.
    private var currentHighlightColor: NSColor? {
        if isSelected {
            return NSColor.controlAccentColor.withAlphaComponent(PopoverColumnGrid.rowSelectionWashAlpha)
        } else if isHovered {
            return NSColor.selectedContentBackgroundColor.withAlphaComponent(PopoverColumnGrid.rowHoverWashAlpha)
        } else {
            return nil
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        if let highlight = currentHighlightColor {
            let rect = bounds.insetBy(
                dx: PopoverColumnGrid.selectionHighlightInsetX,
                dy: PopoverColumnGrid.selectionHighlightInsetY)
            let path = NSBezierPath(
                roundedRect: rect,
                xRadius: PopoverColumnGrid.selectionHighlightCornerRadius,
                yRadius: PopoverColumnGrid.selectionHighlightCornerRadius)
            highlight.setFill()
            path.fill()
        }
        super.draw(dirtyRect)
    }

    // MARK: Actions

    // STABILITY(D4): the drag flag clears only when the last change callback coincides with .leftMouseUp — Esc/cancelled drags leave it stuck and the row ignores model updates; see dev/notes/stability-audit-2026-07-18.md
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

    // MARK: Context menu (T5)
    //
    // Right-clicking a row both selects it (via `rightMouseDown`'s existing
    // `requestSelectIfInDeadZone` call, above) AND — regardless of dead-zone,
    // since AppKit calls `menu(for:)` for a right-click landing anywhere in
    // the view that doesn't have its own context menu (the slider/popup do,
    // so this never overrides theirs) — presents this menu: a "Route to"
    // submenu mirroring the trailing destination popup, a separator, then
    // "Remove from list" LAST, styled destructive.

    public override func menu(for event: NSEvent) -> NSMenu? {
        buildContextMenu()
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let routeToItem = NSMenuItem(title: "Route to", action: nil, keyEquivalent: "")
        // This submenu never collapses into a button (unlike `destinationPopUp`),
        // so it's free to render a subtitle as attributed secondary text (A3).
        let (routeToMenu, _) = buildDestinationMenu(
            selecting: currentSelectedDestinationID(), action: #selector(destinationChanged(_:)),
            allowsAttributedSubtitle: true)
        routeToItem.submenu = routeToMenu
        menu.addItem(routeToItem)

        menu.addItem(.separator())

        let removeItem = NSMenuItem(
            title: "", action: #selector(removeFromListMenuItemSelected(_:)), keyEquivalent: "")
        removeItem.target = self
        removeItem.attributedTitle = NSAttributedString(
            string: "Remove from list",
            attributes: [.foregroundColor: NSColor.systemRed])
        menu.addItem(removeItem)

        return menu
    }

    private func currentSelectedDestinationID() -> String {
        destinationPopUp.selectedItem?.representedObject as? String ?? destinations.first?.id ?? ""
    }

    @objc private func removeFromListMenuItemSelected(_ sender: NSMenuItem) {
        delegate?.appRow(self, didRemoveFor: appID)
    }

    // MARK: Selection (T1 seam)
    //
    // `mouseDown`/`rightMouseDown` on the ROW ITSELF only fire when AppKit's hit
    // test doesn't route the click to a more specific subview first — the slider
    // and destination popup are opaque `NSControl`s that consume their own
    // mouseDown, so a click landing on either NEVER reaches here. Only the
    // icon/name/dead-zone area (backed by a plain `NSImageView`/label-style
    // `NSTextField`, neither of which intercepts mouse events) and the row's
    // background fall through to these overrides. The hover-revealed remove
    // button is the one exception living in that dead zone; it's excluded
    // explicitly below so a click on it removes rather than also selecting.

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        true
    }

    public override func mouseDown(with event: NSEvent) {
        requestSelectIfInDeadZone(with: event)
        // Still let NSView's default handling run (e.g. so this becomes first
        // responder via the normal click-to-focus path where applicable).
        super.mouseDown(with: event)
    }

    public override func rightMouseDown(with event: NSEvent) {
        requestSelectIfInDeadZone(with: event)
        super.rightMouseDown(with: event)
    }

    // MARK: Hover tracking (neutral hover wash, distinct from selection)

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor = hoverMoveMonitor { NSEvent.removeMonitor(monitor); hoverMoveMonitor = nil }
        isHovered = false
        guard window != nil else { return }
        // Sticky-hover fix (shared row idiom): a bottom-most row can miss
        // `mouseExited` when the pointer leaves into an untracked dead-zone
        // below the card, so reconcile against the true pointer position.
        // STABILITY(D4): every row installs its own app-wide monitor, churned on each rebuild — any fix should reduce multiplicity/churn only; the monitor pattern itself is deliberate (see this target's AGENTS.md); see dev/notes/stability-audit-2026-07-18.md
        hoverMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self, let window = self.window else { return event }
            let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            self.isHovered = self.bounds.contains(point)
            return event
        }
    }

    deinit {
        if let monitor = hoverMoveMonitor { NSEvent.removeMonitor(monitor) }
    }

    /// Test hooks for the hover wash.
    public func test_setHovered(_ hovered: Bool) { isHovered = hovered }
    public var test_isHovered: Bool { isHovered }

    /// The alpha component of the row-highlight colour `draw(_:)` currently
    /// computes — `nil` when neither selected nor hovered. Distinguishes the
    /// selection wash from the hover wash since their unified alphas
    /// (`PopoverColumnGrid.rowSelectionWashAlpha`/`rowHoverWashAlpha`) differ.
    /// Exposed because offscreen tests can't rasterize `draw(_:)`'s output to
    /// inspect the painted pixels directly.
    public var test_highlightAlpha: CGFloat? { currentHighlightColor?.alphaComponent }

    /// The destination `%` readout's current text colour (V7: tertiary while
    /// "No Redirect", secondary otherwise).
    public var test_readoutTextColor: NSColor? { readoutLabel.textColor }

    /// The row's composed VoiceOver label — name, volume, routing destination,
    /// and "not running" when applicable (`configureAccessibility()`). This
    /// row is a single AX leaf (`setAccessibilityElement(true)`), so this is
    /// the only text a VoiceOver user ever hears for it.
    public var test_accessibilityLabel: String? { accessibilityLabel() }

    /// The cursor-rect regions `resetCursorRects()` marks `.pointingHand`
    /// (C3) — exposed since AppKit doesn't expose a live cursor-rect list and
    /// a headless/offscreen view never receives a real `resetCursorRects()`
    /// call from the window server.
    public func test_selectableCursorRects() -> [NSRect] {
        layoutSubtreeIfNeeded()
        return selectableCursorRects()
    }

    // MARK: Keyboard removal (T6)
    //
    // Delete is a responder-chain accelerator only (house convention — the
    // visible "−" footer segment is the required main-interface affordance).
    // AppKit routes both Delete (forward-delete, keyCode 117) and Backspace
    // (keyCode 51) to the standard `deleteBackward:`/`deleteForward:` action
    // methods on the first responder BEFORE `keyDown` would see them as raw
    // key events on most systems, so both are implemented as those action
    // overrides rather than parsed out of `keyDown` by keyCode. This view is
    // only ever the first responder while it renders `isSelected` (selection
    // and first-responder status are pushed/pulled together everywhere above),
    // so no separate "is anything selected" guard is needed — no selection
    // means this view was never made first responder, so neither override
    // fires from a real key press.

    public override func deleteForward(_ sender: Any?) {
        delegate?.appRow(self, didRemoveFor: appID)
    }

    public override func deleteBackward(_ sender: Any?) {
        delegate?.appRow(self, didRemoveFor: appID)
    }

    // MARK: Keyboard selection movement (V14)
    //
    // Same dispatch family as `deleteForward`/`deleteBackward` above: AppKit
    // routes the Up/Down arrow keys to the standard `moveUp:`/`moveDown:`
    // action methods on the first responder via `NSStandardKeyBindingResponding`
    // BEFORE `keyDown` would see them as raw key events, so these are
    // implemented as those action overrides. This view has no notion of "the
    // previous/next row" — only the HOST (which owns the Applications list
    // order) can resolve that — so these purely forward intent through the
    // delegate; a default no-op conformance means every existing `Delegate`
    // still compiles.

    public override func moveUp(_ sender: Any?) {
        delegate?.appRow(self, didRequestMoveSelection: .up, for: appID)
    }

    public override func moveDown(_ sender: Any?) {
        delegate?.appRow(self, didRequestMoveSelection: .down, for: appID)
    }

    private func requestSelectIfInDeadZone(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        // Belt-and-suspenders alongside AppKit's own hit-testing (which, in a
        // live window, already routes a slider/popup click to that subview's
        // own `mouseDown` and never calls this override at all): explicitly
        // re-check the same dead-zone `NSView.hitTest` effectively enforces,
        // so this stays correct even when driven directly (as the `test_*`
        // hooks below do, offscreen, with no real window to hit-test through).
        guard isInSelectableDeadZone(local) else { return }
        window?.makeFirstResponder(self)
        delegate?.appRow(self, didRequestSelect: appID)
    }

    /// Whether `point` (in the row's own coordinate space) is outside the
    /// slider/destination-popup frames — i.e. the icon/name/background dead
    /// zone a body click must land in to select the row. In a live window
    /// AppKit's own hit-testing already routes a click on either of those
    /// subviews to the subview itself, so this override never even runs;
    /// this check is the belt-and-suspenders that keeps the same guarantee
    /// true when this method is invoked directly (as the
    /// `test_simulateBodyClick`/`test_simulateSliderClick` hooks do, with no
    /// real window to hit-test through).
    private func isInSelectableDeadZone(_ point: NSPoint) -> Bool {
        if slider.frame.contains(point) { return false }
        if destinationPopUp.frame.contains(point) { return false }
        return bounds.contains(point)
    }

    // MARK: Cursor (C3)
    //
    // The selectable body dead-zone (icon/name/background) shows a pointing
    // hand, signalling "clicking here selects this row" — the same region
    // `isInSelectableDeadZone` treats as selectable. The slider and
    // destination popup keep whatever cursor they establish themselves (a
    // subview that never overrides `resetCursorRects` inherits its nearest
    // ancestor's cursor rects, so those frames must be explicitly carved out
    // here rather than trusting AppKit to leave them alone).

    public override func resetCursorRects() {
        super.resetCursorRects()
        for rect in selectableCursorRects() {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    /// The dead-zone split into non-overlapping full-height column strips,
    /// carving out `slider.frame`/`destinationPopUp.frame` — mirrors
    /// `isInSelectableDeadZone`'s x-axis exclusion (a strip's full row height
    /// is a deliberate approximation; the slider/popup don't span the full
    /// row height, so a point directly above/below one at the same x is
    /// selectable per `isInSelectableDeadZone` but not cursor-rect-covered
    /// here — an acceptable trade for a much simpler rect union).
    private func selectableCursorRects() -> [NSRect] {
        let excluded = [slider.frame, destinationPopUp.frame].sorted { $0.minX < $1.minX }
        var rects: [NSRect] = []
        var cursorX = bounds.minX
        for rect in excluded {
            if rect.minX > cursorX {
                rects.append(NSRect(x: cursorX, y: bounds.minY, width: rect.minX - cursorX, height: bounds.height))
            }
            cursorX = max(cursorX, rect.maxX)
        }
        if cursorX < bounds.maxX {
            rects.append(NSRect(x: cursorX, y: bounds.minY, width: bounds.maxX - cursorX, height: bounds.height))
        }
        return rects
    }

    // MARK: Accessibility

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        // Fold routing destination + running status into the row's ONE
        // composed label — `setAccessibilityElement(true)` makes this row a
        // single AX leaf, so a status-only badge/subview (like `offlineBadge`'s
        // own "Not running" image description) is never independently reached
        // by VoiceOver; it must be said here or not at all. Read live view
        // state (`destinationPopUp`'s already-rebuilt selection,
        // `offlineBadge`'s already-set visibility) rather than duplicating it
        // into a second stored flag, same idiom as `DeviceRowView.isInMenu`.
        var label = "\(nameLabel.stringValue), volume \(slider.integerValue) percent"
        if let destinationTitle = destinationPopUp.selectedItem?.title, !destinationTitle.isEmpty {
            label += ", routed to \(destinationTitle)"
        }
        if !offlineBadge.isHidden {
            label += ", not running"
        }
        setAccessibilityLabel(label)

        slider.setAccessibilityRole(.slider)
        slider.setAccessibilityLabel("\(nameLabel.stringValue) volume")
        destinationPopUp.setAccessibilityLabel("\(nameLabel.stringValue) destination")
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

    /// Simulate removal being triggered for this row (± footer "−" segment,
    /// context-menu "Remove from list", or Delete/Backspace) — all three real
    /// paths funnel through this same delegate call.
    public func test_remove() {
        delegate?.appRow(self, didRemoveFor: appID)
    }

    /// The currently displayed volume (structural assertions).
    public var test_volume: Int { slider.integerValue }
    /// Whether the volume slider is currently dimmed/disabled — true iff the
    /// destination is the standalone "No Redirect" entry. "Current Device" (Bug
    /// T2) and AirPlay routes each have an independent stream, so their slider is
    /// live (not dimmed).
    public var test_isSliderDimmed: Bool { !slider.isEnabled }
    /// Whether the offline badge (T4) is currently visible — true when the
    /// routed app's process is not running.
    public var test_isOfflineBadgeVisible: Bool { !offlineBadge.isHidden }
    /// The last level pushed to the leading VU meter via ``setLevel(_:)`` — `0`
    /// when the row has no meter (`showsMeter == false`) or after a
    /// ``resetLevel()``. Mirrors `DeviceRowView.test_meterLevel()`.
    public func test_meterLevel() -> Float { lastMeterLevel }
    /// The full ordered list of titles in the destination menu: the standalone
    /// "No Redirect" entry, a separator (empty title), then the two disabled
    /// section headers ("CURRENT DEVICE" / "AIRPLAY DEVICES") and their entries.
    public var test_menuTitles: [String] { destinationPopUp.menu?.items.map(\.title) ?? [] }
    /// The currently checkmarked destination id.
    public var test_selectedDestinationID: String? {
        destinationPopUp.selectedItem?.representedObject as? String
    }

    // MARK: Test-support hooks — destination subtitle (A3)

    /// The real `NSMenuItem` for `destinationID` in the trailing destination
    /// popup's OWN menu. Exposed so tests can assert its title/attributedTitle
    /// stay plain even when `subtitle` is set — `NSPopUpButton` mirrors its
    /// selected item's `attributedTitle` for its own collapsed display, so this
    /// menu's items must never carry one.
    public func test_destinationPopUpMenuItem(forDestinationID id: String) -> NSMenuItem? {
        destinationPopUp.menu?.items.first { ($0.representedObject as? String) == id }
    }

    /// The real `NSMenuItem` for `destinationID` inside the context menu's
    /// "Route to" submenu (built by `test_contextMenu()`) — this submenu never
    /// collapses into a button, so it's free to carry an attributed
    /// title+subtitle (A3).
    public func test_routeToMenuItem(forDestinationID id: String) -> NSMenuItem? {
        guard let routeToItem = test_contextMenu().items.first, let submenu = routeToItem.submenu else {
            return nil
        }
        return submenu.items.first { ($0.representedObject as? String) == id }
    }
    // MARK: Test-support hooks — context menu (T5)

    /// Build the same context menu a right-click produces: "Route to"
    /// submenu (mirroring the trailing destination popup), a separator, then
    /// "Remove from list" last. Exposed so tests can assert item order/count
    /// and that the remove item's action fires `didRemoveFor` without
    /// needing to synthesize a real right-click.
    public func test_contextMenu() -> NSMenu {
        buildContextMenu()
    }

    /// Simulate choosing "Remove from list" from the context menu built by
    /// `test_contextMenu()` — invokes the menu item's real action, same path
    /// a live click on it takes.
    public func test_selectRemoveFromListMenuItem() {
        guard let removeItem = test_contextMenu().items.last else { return }
        _ = removeItem.target?.perform(removeItem.action, with: removeItem)
    }

    // MARK: Test-support hooks — selection (T1 seam)

    /// Directly set the render-only selection state, bypassing the delegate —
    /// mirrors how the HOST re-pushes `selectedAppBundleID` into a recreated
    /// row after `PopoverController.rebuild()`. Does NOT notify the delegate
    /// (setting selection is the host telling the view, not the view asking).
    public func test_setSelected(_ selected: Bool) { isSelected = selected }
    /// Whether the row is currently rendering the selected-row highlight.
    public var test_isSelected: Bool { isSelected }

    /// Simulate a real click landing on the row's BODY (icon/name/dead-zone,
    /// deliberately away from the slider and destination popup columns).
    /// Constructs a genuine `NSEvent` and calls the real `mouseDown(with:)`
    /// override — exercising the exact path a real click takes (not a direct
    /// delegate call) — so it also proves first-responder promotion. Point
    /// defaults into the icon/name area, away from every control's frame.
    public func test_simulateBodyClick(at point: NSPoint? = nil) {
        layoutSubtreeIfNeeded()
        let target = point ?? NSPoint(x: PopoverColumnGrid.leadingInset + 4, y: AppRowView.rowHeight / 2)
        mouseDown(with: mouseEvent(at: target))
    }

    /// Simulate a real click landing on the volume slider's frame — same
    /// `mouseDown(with:)` entry point as `test_simulateBodyClick`, but at a
    /// point inside `slider.frame`. In a live window a click there is
    /// intercepted by the `NSSlider` subview and never reaches this view's
    /// override at all; this hook proves the same on the row's own override
    /// as a belt-and-suspenders structural check — see
    /// `test_pointIsInSelectableDeadZone` for the point-in-dead-zone rule the
    /// real subview hit-testing enforces.
    public func test_simulateSliderClick() {
        layoutSubtreeIfNeeded()
        mouseDown(with: mouseEvent(at: NSPoint(x: slider.frame.midX, y: slider.frame.midY)))
    }

    /// Whether `point` (in the row's own coordinate space) falls inside a
    /// region that would trigger `didRequestSelect` on a real click — i.e.
    /// outside the slider and destination popup frames, and outside the
    /// remove button when it's visible. Test-hook wrapper around the real
    /// production check `mouseDown`/`rightMouseDown` use (`isInSelectableDeadZone`).
    public func test_pointIsInSelectableDeadZone(_ point: NSPoint) -> Bool {
        layoutSubtreeIfNeeded()
        return isInSelectableDeadZone(point)
    }

    /// Simulate pressing Delete (forward-delete, keyCode 117) on this row via
    /// the real key path: dispatches a synthetic `keyDown` through
    /// `doCommand(by:)`, the same `NSStandardKeyBindingResponding` dispatch
    /// AppKit's own key-binding manager uses to turn a physical Delete key
    /// press into the `deleteForward:` action call — not a direct call to
    /// `deleteForward(_:)` or the delegate. (`interpretKeyEvents` resolves to
    /// this same call in a live window; it's skipped here because it needs a
    /// loaded system key-binding table that isn't guaranteed available
    /// offscreen/headless.)
    public func test_pressDelete() {
        doCommand(by: #selector(NSResponder.deleteForward(_:)))
    }

    /// Simulate pressing Backspace (keyCode 51) on this row via the real key
    /// path — see `test_pressDelete`'s doc for why `doCommand(by:)` is used.
    public func test_pressBackspace() {
        doCommand(by: #selector(NSResponder.deleteBackward(_:)))
    }

    /// Simulate pressing the Up arrow on this row via the real key path —
    /// see `test_pressDelete`'s doc for why `doCommand(by:)` is used. Fires
    /// `Delegate.appRow(_:didRequestMoveSelection:.up:for:)`.
    public func test_pressUpArrow() {
        doCommand(by: #selector(NSResponder.moveUp(_:)))
    }

    /// Simulate pressing the Down arrow on this row via the real key path —
    /// see `test_pressDelete`'s doc for why `doCommand(by:)` is used. Fires
    /// `Delegate.appRow(_:didRequestMoveSelection:.down:for:)`.
    public func test_pressDownArrow() {
        doCommand(by: #selector(NSResponder.moveDown(_:)))
    }

    /// A synthetic left-mouse-down `NSEvent` at `point` in this view's own
    /// coordinate space. Works without a live window — `locationInWindow` is
    /// only ever consumed by this view via `convert(_:from:)`, which degrades
    /// gracefully to identity conversion when `window` is `nil`.
    private func mouseEvent(at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1)!
    }
}

/// Default no-op for `didRequestMoveSelection` so every existing `Delegate`
/// conformer keeps compiling without adopting the new V14 keyboard-move
/// callback. Hosts that want arrow-key selection movement implement it
/// explicitly, same opt-in shape as any other protocol default.
extension AppRowView.Delegate {
    public func appRow(
        _ row: AppRowView, didRequestMoveSelection direction: AppRowView.MoveDirection, for appID: String
    ) {}
}

