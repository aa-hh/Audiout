// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit
import AirPlayControllerCore

/// A single device's controls (SPEC §9 "Device row"), shared by BOTH the
/// menu-bar extra's popover dropdown and the full mixer window (both host it in
/// an `NSStackView`). This is the "same row component" the SPEC and
/// PLAN-PHASE-1 §D call for — one implementation, one test surface, identical
/// behaviour in both hosts.
///
/// The row's PRIMARY control is a "send audio here" ON/OFF `NSSwitch` (SPEC §9
/// routing model); volume and a small secondary mute button follow.
///
/// It lives in `AirPlayControllerSharedUI` (not the popover target) so the
/// window target can link it without pulling in the whole dropdown; both
/// `PopoverController` (popover) and `MixerViewController` (window) reuse it.
///
/// The custom-view rules below (`draw`/highlight/tracking) still support the
/// legacy `NSMenuItem` host branch; in the popover and window there is no
/// `enclosingMenuItem`, so the standard control appearance shows through. It
/// follows `dev/notes/p1-menu-brief.md` §2/§5 for the menu-hosted case:
/// - the row owns ALL drawing, so it paints its own menu highlight from
///   `enclosingMenuItem?.isHighlighted` and tracks hover via an
///   `NSTrackingArea` (the menu paints no background behind a custom view);
/// - the slider is `isContinuous = true` so the drag fires throughout and the
///   menu stays open (AppKit delivers `mouseDragged:` to views in menu items);
/// - the row is a **fixed height** — per-item view-frame resize during menu
///   tracking is unsupported (brief gotcha #2);
/// - accessibility roles/labels are set explicitly because the (undrawn) item
///   title won't cover the embedded controls (brief §5).
///
/// **Host awareness.** In a menu the row must paint the system menu-highlight
/// itself (no `NSMenuItem` background behind a custom view); in the window's
/// stack view there is no `enclosingMenuItem`, so it simply paints nothing and
/// lets the standard control appearance show through. The `draw(_:)` /
/// `accessibilityRole` branch on `enclosingMenuItem != nil` — the same view
/// class, correct in both hosts, no per-host subclass.
///
/// The view is pure UI: every control routes back through a `Delegate` so the
/// host controller can call `GroupController`/the backend. The view never talks
/// to a backend directly.
public final class DeviceRowView: NSView {

    /// Callbacks for the row's controls. The host controller implements these
    /// and maps them onto `GroupController` / the backend.
    ///
    /// `didToggleEnabled` is the PRIMARY routing control (SPEC §9 "Interaction /
    /// routing model" — "send audio here" ON/OFF). `didToggleMute` is the small
    /// secondary quick-silence. `didToggleEnabled` has a default no-op so existing
    /// conformers (and tests) that only care about volume/mute still compile.
    public protocol Delegate: AnyObject {
        func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String)
        func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String)
        /// The user flipped the row's primary "send audio here" ON/OFF switch.
        func deviceRow(_ row: DeviceRowView, didToggleEnabled on: Bool, for id: String)
    }

    /// Control-Center row density: comfortable height that seats a mini switch,
    /// icon, a two-line name/status stack, CC slider and mute button with
    /// breathing room in a card (CC rows read ~34–40pt; 38 landed in that band
    /// before the status sublabel — brief §6 sanctions bumping this constant
    /// once a second text line needs the room, which it does: two 10pt lines
    /// plus their line gap don't fit 38pt without crowding the slider/switch).
    public static let rowHeight: CGFloat = 42

    // (See `DeviceRowView.Delegate` extension at file end for the
    // `didToggleEnabled` default no-op.)

    /// Which on-icon status dot the row is currently showing — a structural test
    /// hook (`test_statusKind`) so tests can assert the right badge is visible
    /// without reaching into the private badge subview. Redefined for the
    /// 2026-07-17 on-icon redesign: the four states map directly off
    /// `Device.connectionState`.
    public enum StatusKind: Equatable {
        /// `.off` — the badge is hidden.
        case none
        /// `.connecting` / `.reconnecting` — the breathing neutral dot.
        case connecting
        /// `.connected` — the solid green dot.
        case connected
        /// `.failed` — the solid amber dot.
        case failed
    }

    public weak var delegate: Delegate?
    public private(set) var device: Device

    /// Membership in the "Selected Devices" set (SPEC §9b). This is *composition*,
    /// not routing — the row is "selected" iff the host says so, independent of
    /// whether the backend currently reports the device as an output. The host
    /// passes this in via ``apply(_:selected:blocked:blockReason:)`` because the
    /// set lives in `GroupController`, not on the `Device`.
    public private(set) var isSelectedInSet: Bool = false

    /// True when this row's toggle is disabled by the Phase-1 local-mix block
    /// (the Mac can't join a mixed set) — the switch is greyed with a tooltip.
    private var isToggleBlocked: Bool = false

    /// Transient pointer-hover state (menu-less hosts). Kept SEPARATE from the
    /// model `isSelectedInSet` and always reset in ``apply(_:selected:…)`` and on
    /// re-parenting, so a hover can never "stick" as a stale highlight after the
    /// pointer leaves the popover without a matching `mouseExited` (T-U8 bug).
    private var isHovered: Bool = false

    /// The PRIMARY "Selected Devices" membership `NSSwitch` (SPEC §9b device-row
    /// toggle — Alec prefers toggles, not checkmarks; `NSSwitch`, mini size — HIG
    /// sanctions a mini switch for a single-row per-device setting). Leads the row.
    private let enableSwitch = NSSwitch()
    private let iconView = NSImageView()
    /// The on-icon connection-status badge (2026-07-17): a small corner dot
    /// overlapping the icon's bottom-right, driven off `device.connectionState`.
    /// Replaced the retired right-side status slot. See ``StatusDotView``.
    private let statusDotView = StatusDotView()
    private let nameLabel = NSTextField(labelWithString: "")
    /// Status sublabel under the name — now shown ONLY for `.failed` (2026-07-17):
    /// "Couldn't connect" in `.systemOrange`. Every other state (`.off`,
    /// `.connecting`, `.reconnecting`, `.connected`) is a SINGLE-LINE row with the
    /// name vertically centered; the on-icon dot carries the in-flight/connected
    /// signal there instead.
    private let statusLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    /// Small right-aligned `%` readout sitting immediately right of the slider
    /// (change 4 — a device row now shows its volume number too, tight against
    /// the slider like the Main Out row, on the same shared column).
    private let readoutLabel = NSTextField(labelWithString: "")
    private let muteButton = NSButton()

    /// App-local mouse-moved monitor that guarantees hover clears even when the
    /// pointer leaves the row into a "dead zone" with no sibling tracking area
    /// (the card's bottom padding, the inter-card gap, the footer). This is the
    /// root fix for the last-row sticky-highlight bug: `NSTrackingArea` only
    /// delivers `mouseExited` when the pointer crosses INTO another tracked
    /// region, so the bottom-most row — which has nothing tracked below it —
    /// never gets an exit and its hover flag sticks. The monitor observes pointer
    /// movement anywhere in the app and clears hover as soon as the pointer is
    /// verified outside this row's bounds, for ANY row, not just the last.
    private var mouseMovedMonitor: Any?

    /// Extra leading inset applied to group members so they read as indented
    /// under their group header (SPEC §9 "one indented device row per member").
    private let indented: Bool

    /// Whether the leading "Selected Devices" membership toggle is shown. Group
    /// **member** rows hide it (membership in a group is fixed there — the toggle
    /// is only for the Selected Devices section, task C); its slot stays reserved
    /// for column alignment, filled instead by the indent. Defaults to `true` so
    /// the public API stays back-compatible (Selected-Devices rows keep the
    /// toggle).
    private let showsToggle: Bool

    /// Whether the row paints the accent-wash pill behind a row that's IN the
    /// Selected Devices set. The popover (2026-07-14 — Alec: no longer needed,
    /// the row's accent icon tint + switch state already say "on") passes
    /// `false`; the mixer window keeps it (its rows have no card background to
    /// separate them, so the wash still carries useful row-to-row separation).
    /// Defaults to `true` so existing callers (the mixer window) are unchanged.
    private let paintsSelectionBackground: Bool

    /// True when this row is drawn in the menu (paint the menu highlight);
    /// false in the mixer window (no `enclosingMenuItem` — let standard control
    /// appearance show). Computed live from `enclosingMenuItem` so the same
    /// instance is correct wherever it's parented.
    private var isInMenu: Bool { enclosingMenuItem != nil }

    public init(device: Device, indented: Bool = false, showsToggle: Bool = true,
               paintsSelectionBackground: Bool = true) {
        self.device = device
        self.indented = indented
        self.showsToggle = showsToggle
        self.paintsSelectionBackground = paintsSelectionBackground
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: Self.rowHeight))
        // Fill the host's width, keep a fixed height (brief §2).
        autoresizingMask = [.width]
        translatesAutoresizingMaskIntoConstraints = true
        buildSubviews()
        apply(device)
        configureAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Model

    /// Update the row to a new device snapshot AND its "Selected Devices"
    /// membership (SPEC §9b). The host owns the membership set (it lives in
    /// `GroupController`), so it passes `selected` here rather than the row
    /// reading `device.isSelected` (which is the backend output flag, a different
    /// thing under the Main Out model).
    ///
    /// - Parameters:
    ///   - selected: whether this device is in the Selected Devices set.
    ///   - blocked: whether the membership toggle should be disabled (Phase-1
    ///     local-mix block) — greyed with `blockReason` as a tooltip.
    ///   - blockReason: tooltip text shown when `blocked` is true.
    public func apply(_ device: Device,
                      selected: Bool,
                      blocked: Bool = false,
                      blockReason: String? = nil) {
        self.device = device
        self.isSelectedInSet = selected
        self.isToggleBlocked = blocked
        // Any model refresh (select OR deselect) clears a transient hover so the
        // row can't keep a stale hover wash after the pointer left the popover
        // (T-U8 root-cause fix — hover is transient, selection is model-driven).
        self.isHovered = false

        // Primary membership control: ON iff the device is in the Selected
        // Devices set. Don't fight a live toggle animation. Group-member rows
        // hide the toggle entirely (task C) — membership there is fixed.
        enableSwitch.state = selected ? .on : .off
        enableSwitch.isEnabled = showsToggle && device.isAvailable && !blocked
        enableSwitch.toolTip = (showsToggle && blocked) ? blockReason : nil

        iconView.image = NSImage(
            systemSymbolName: device.kind.symbolName,
            accessibilityDescription: device.name
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: PopoverColumnGrid.iconGlyphPointSize,
                                        weight: .regular)
        )
        // The icon is ALWAYS neutral now (2026-07-17): identity only, no
        // accent-when-selected fill. Selection reads from the switch state; the
        // on-icon corner dot carries the connection status instead.
        iconView.contentTintColor = .secondaryLabelColor
        nameLabel.stringValue = device.name
        nameLabel.textColor = rowTextColor

        applyConnectionStatus(device.connectionState)

        // Don't fight a live drag: only push the model value into the slider
        // when the user isn't dragging it. (The readout is kept live during a
        // drag by the slider action; on a model refresh it shows the model value.)
        if !isDraggingSlider {
            slider.integerValue = device.volume
            readoutLabel.stringValue = "\(device.volume)%"
        }
        // The volume slider + mute are usable whenever the device is a selected,
        // available member (its level composes the Main Out master).
        slider.isEnabled = device.isAvailable && selected && !device.isMuted
        muteButton.isEnabled = device.isAvailable && selected
        muteButton.state = device.isMuted ? .on : .off

        configureAccessibility()
        setNeedsDisplay(bounds)
    }

    /// Drive the on-icon status badge + the (failed-only) sublabel from
    /// `device.connectionState` (2026-07-17 redesign). The badge itself is
    /// idempotent — ``StatusDotView/apply(_:)`` fully resets its layer/animation
    /// each time — so a repeated `apply` (e.g. a re-render after an unrelated
    /// volume change) can never leave a stale breathing animation running under a
    /// since-changed state.
    ///
    /// Only `.failed` is a two-line row: the "Couldn't connect" sublabel appears
    /// there, in `.systemOrange`. Every other state is single-line (sublabel
    /// hidden, name vertically centered).
    private func applyConnectionStatus(_ state: ConnectionState) {
        statusDotView.apply(state)

        if case .failed = state {
            statusLabel.isHidden = false
            statusLabel.stringValue = "Couldn't connect"
            statusLabel.textColor = .systemOrange
            applyNameStackLayout(twoLine: true)
        } else {
            statusLabel.isHidden = true
            statusLabel.stringValue = ""
            applyNameStackLayout(twoLine: false)
        }
    }

    /// Backward-compatible one-arg update (selection derived from the backend
    /// `isSelected` flag). Retained for callers/tests not yet passing explicit
    /// membership; new hosts should use ``apply(_:selected:blocked:blockReason:)``.
    public func apply(_ device: Device) {
        apply(device, selected: device.isSelected)
    }

    // MARK: Build

    private var isDraggingSlider = false

    /// The name label's vertical offset off row center. Flipped live by
    /// ``applyNameStackLayout(twoLine:)``: 0 when the row is single-line (name
    /// centered), and a half-line rise when `.failed` shows its sublabel so the
    /// name + sublabel PAIR is centered instead.
    private var nameCenterYConstraint: NSLayoutConstraint!

    /// Half-line offset used to center the two-line name/sublabel pair on
    /// `.failed`. Kept at the value the two-line stack used before the redesign.
    private static let failedNameRise: CGFloat = 7.5

    private func buildSubviews() {
        wantsLayer = true
        // Leading edge of the row's first control (task B shared grid). Members
        // read indented; the toggle (when present) or the icon (when hidden)
        // starts here.
        let leading: CGFloat = indented ? PopoverColumnGrid.indentedLeadingInset
                                        : PopoverColumnGrid.leadingInset

        enableSwitch.translatesAutoresizingMaskIntoConstraints = false
        enableSwitch.controlSize = .mini            // SPEC §9: mini switch per HIG
        enableSwitch.target = self
        enableSwitch.action = #selector(enableToggled(_:))
        enableSwitch.setContentHuggingPriority(.required, for: .horizontal)
        // Group-member rows hide the toggle (task C). Its leading slot is not
        // reused — the row already indents, keeping the icon column aligned.
        enableSwitch.isHidden = !showsToggle

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        // On-icon status badge: overlaps the icon's bottom-right corner. Not
        // clipped by the icon (added as a row subview, positioned on the icon's
        // corner) so the punch-out border shows around it.
        statusDotView.translatesAutoresizingMaskIntoConstraints = false
        statusDotView.setContentHuggingPriority(.required, for: .horizontal)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .menuFont(ofSize: 0)
        nameLabel.lineBreakMode = .byTruncatingTail   // task B: "…" tail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Status sublabel (2026-07-17): shown ONLY for `.failed` ("Couldn't
        // connect", `.systemOrange`). Small and secondary; `applyConnectionStatus`
        // shows/hides it and `applyNameStackLayout` centers the name accordingly.
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.isHidden = true   // single-line by default until the first `apply`

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minValue = 0
        slider.maxValue = 100
        slider.isContinuous = true            // fire throughout the drag (brief §2)
        slider.target = self
        slider.action = #selector(volumeChanged(_:))

        // `%` readout, right-aligned, small secondary — hangs off the slider's
        // trailing edge (change 4) so the number reads tight against the slider.
        readoutLabel.translatesAutoresizingMaskIntoConstraints = false
        readoutLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        readoutLabel.textColor = .secondaryLabelColor
        readoutLabel.alignment = .right
        readoutLabel.setContentHuggingPriority(.required, for: .horizontal)

        configureAccessoryButton(muteButton, symbol: "speaker.wave.2.fill",
                                  action: #selector(muteToggled(_:)))

        // Name click toggles the ENABLED switch (2026-07-17 convenience — the
        // name is spatially separate on the left, so a gesture scoped to it can't
        // interfere with the slider/mute/%/toggle on the right). The switch stays
        // the authoritative accessibility control; this is a mouse convenience.
        // A `.failed` device re-enables (retries) on click — intended.
        let nameClick = NSClickGestureRecognizer(target: self, action: #selector(nameClicked(_:)))
        nameLabel.addGestureRecognizer(nameClick)

        addSubview(enableSwitch)
        addSubview(iconView)
        addSubview(statusDotView)          // over the icon's corner
        addSubview(nameLabel)
        addSubview(statusLabel)
        addSubview(slider)
        addSubview(readoutLabel)
        addSubview(muteButton)

        // The icon now LEADS the row (task B grid): at `leading` for top-level
        // rows, `indentedLeadingInset` for members — the toggle no longer leads.
        // The mute glyph, slider and trailing "Enabled" control are anchored off
        // the TRAILING edge via the shared grid so they line up with every other
        // row type; the `%` readout hangs off the slider's trailing edge (change
        // 4) so the number is tight to the slider on every slider row.
        //
        // The name is SINGLE-LINE and centered by default (2026-07-17); only the
        // `.failed` state shows a sublabel, at which point `applyNameStackLayout`
        // raises the name by a half-line so the pair is centered. The right-side
        // status slot was retired — connection status is the on-icon corner dot.
        let nameCenterY = nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        nameCenterYConstraint = nameCenterY

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),
            iconView.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),

            // On-icon status badge: sized to the badge diameter, its center
            // pulled IN from the icon's bottom-right corner by `statusDotInset`
            // so it rides the (now box-filling) glyph's corner with a slight
            // overhang, reading as a distinct badge over the symbol rather than
            // floating in the box padding below it.
            statusDotView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.statusDotDiameter),
            statusDotView.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.statusDotDiameter),
            statusDotView.centerXAnchor.constraint(equalTo: iconView.trailingAnchor,
                                                   constant: -PopoverColumnGrid.statusDotInset),
            statusDotView.centerYAnchor.constraint(equalTo: iconView.bottomAnchor,
                                                   constant: -PopoverColumnGrid.statusDotInset),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                               constant: PopoverColumnGrid.iconToName),
            nameCenterY,
            // Name yields to the MUTE glyph now (it sits between name and slider):
            // the name's trailing is a `<=` and the name truncates.
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: muteButton.leadingAnchor,
                constant: -PopoverColumnGrid.iconToName),

            // Sublabel (failed-only) sits a half-line under the (raised) name.
            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            statusLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: muteButton.leadingAnchor,
                constant: -PopoverColumnGrid.iconToName),

            // Mute speaker glyph sits LEFT of the slider (task B grid).
            muteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            muteButton.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.muteWidth),
            muteButton.trailingAnchor.constraint(
                equalTo: slider.leadingAnchor, constant: -PopoverColumnGrid.muteToSlider),

            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.sliderWidth),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor,
                                             constant: -PopoverColumnGrid.sliderTrailing),

            // `%` readout: tight to the right of the slider, fixed-width column.
            readoutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            readoutLabel.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.readoutWidth),
            readoutLabel.leadingAnchor.constraint(
                equalTo: slider.trailingAnchor, constant: PopoverColumnGrid.sliderToReadout),

            // Primary "Selected Devices" toggle: centered UNDER its "ENABLED"
            // header (change 3) — its centerX sits on the trailing-control column
            // center, not the column's trailing edge.
            enableSwitch.centerXAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -PopoverColumnGrid.trailingControlCenterFromTrailing),
            enableSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Center the name for a single-line row, or raise it a half-line when the
    /// `.failed` sublabel is showing so the name + sublabel pair is centered.
    private func applyNameStackLayout(twoLine: Bool) {
        nameCenterYConstraint.constant = twoLine ? -Self.failedNameRise : 0
    }

    private func configureAccessoryButton(_ button: NSButton, symbol: String,
                                          action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .accessoryBar        // SPEC §9 device-row mute
        button.setButtonType(.pushOnPushOff)
        button.isBordered = false
        // Speaker glyph LEFT of the slider: `pushOnPushOff` still toggles the
        // mute STATE (and fires the delegate) on tap, but the glyph itself stays
        // fixed on `symbol` in both states — no alternate/slash image (Alec wants
        // the icon to never change on toggle). Mute state is reflected only via
        // `button.state` and the accessibility label update in `apply`.
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
    }

    // MARK: Actions

    @objc private func volumeChanged(_ sender: NSSlider) {
        // NSSlider continuous drag: mark drag in-progress so a concurrent
        // `deviceUpdated` echo doesn't yank the thumb back under the user.
        isDraggingSlider = true
        let event = NSApp.currentEvent
        if event?.type == .leftMouseUp { isDraggingSlider = false }
        // Keep the `%` readout live through the drag (change 4 — mirrors
        // MainOutRowView), since `apply` won't push the model value mid-drag.
        readoutLabel.stringValue = "\(sender.integerValue)%"
        delegate?.deviceRow(self, didSetVolume: sender.integerValue, for: device.id)
    }

    @objc private func muteToggled(_ sender: NSButton) {
        delegate?.deviceRow(self, didToggleMute: sender.state == .on, for: device.id)
    }

    @objc private func enableToggled(_ sender: NSSwitch) {
        delegate?.deviceRow(self, didToggleEnabled: sender.state == .on, for: device.id)
    }

    /// Clicking the device NAME toggles the ENABLED switch (2026-07-17), firing
    /// the SAME delegate path as the switch itself. A no-op when the switch is
    /// disabled (Phase-1 local-mix block, or an unavailable device) — checks the
    /// same conditions `enableSwitch.isEnabled` uses. For a `.failed` device this
    /// re-enables it (= retry), which is intended.
    @objc private func nameClicked(_ sender: NSClickGestureRecognizer) {
        guard enableSwitch.isEnabled else { return }
        let flipped = enableSwitch.state != .on
        enableSwitch.state = flipped ? .on : .off
        delegate?.deviceRow(self, didToggleEnabled: flipped, for: device.id)
    }

    /// The name/label colour for the current state: menu highlight wins, then a
    /// dropped device greys out, then a not-selected device de-emphasizes (it's
    /// not in the Selected Devices set), then normal.
    private var rowTextColor: NSColor {
        if isInMenu, enclosingMenuItem?.isHighlighted == true { return .selectedMenuItemTextColor }
        if !device.isAvailable { return .disabledControlTextColor }
        return isSelectedInSet ? .labelColor : .secondaryLabelColor
    }

    // MARK: Test-support hooks
    //
    // Neither a headless process nor an off-screen window synthesizes the mouse
    // events a real slider drag / button click needs. These drive exactly the
    // same code paths as the real control actions so harnesses/tests can assert
    // that a row controls its device through the delegate.

    /// Simulate the user dragging this row's slider to `volume`.
    public func test_setVolume(_ volume: Int) {
        delegate?.deviceRow(self, didSetVolume: volume, for: device.id)
    }

    /// Simulate the user toggling this row's mute button.
    public func test_toggleMute(_ muted: Bool) {
        delegate?.deviceRow(self, didToggleMute: muted, for: device.id)
    }

    /// Simulate the user flipping this row's primary "send audio here" switch.
    public func test_toggleEnabled(_ on: Bool) {
        delegate?.deviceRow(self, didToggleEnabled: on, for: device.id)
    }

    /// Simulate the user clicking the device NAME (toggles the ENABLED switch,
    /// same delegate path). A no-op when the switch is disabled, mirroring the
    /// real gesture handler.
    public func test_clickName() {
        guard enableSwitch.isEnabled else { return }
        let flipped = enableSwitch.state != .on
        enableSwitch.state = flipped ? .on : .off
        delegate?.deviceRow(self, didToggleEnabled: flipped, for: device.id)
    }

    /// Which on-icon status dot the row is currently showing — derived from
    /// `device.connectionState` (the single source the badge renders from), so it
    /// can never drift from what's actually on screen.
    public var test_statusKind: StatusKind {
        switch device.connectionState {
        case .off:                        return .none
        case .connecting, .reconnecting:  return .connecting
        case .connected:                  return .connected
        case .failed:                     return .failed
        }
    }

    /// The failed-only sublabel's current text, or `nil` when hidden (every
    /// non-`.failed` state — the row is single-line there).
    public var test_statusText: String? {
        statusLabel.isHidden ? nil : statusLabel.stringValue
    }

    /// Whether the connecting/reconnecting badge's breathing pulse is installed
    /// (on screen + Reduce Motion off). Lets tests assert the animation hook.
    public var test_dotIsPulsing: Bool { statusDotView.test_isBreathing }

    /// The primary ON/OFF switch's current state (for structural assertions).
    public var test_isEnabledOn: Bool { enableSwitch.state == .on }

    /// Whether the primary membership toggle is shown. Group-member rows hide it
    /// (task C); Selected-Devices rows show it.
    public var test_showsToggle: Bool { !enableSwitch.isHidden }

    /// The row's icon tint. Always `.secondaryLabelColor` now (2026-07-17 — the
    /// icon is neutral identity-only; selection reads from the switch, status
    /// from the on-icon dot). Retained for the T-U8 reset test.
    public var test_iconTint: NSColor? { iconView.contentTintColor }

    // MARK: Highlight + hover (brief §2/§5 — menu host only)

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

    /// Set the transient hover flag and repaint only when it actually changes.
    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        setNeedsDisplay(bounds)
    }

    /// True iff the pointer is currently inside this row's bounds. Used by the
    /// mouse-moved monitor to clear a hover the tracking area failed to exit.
    private func pointerIsInside() -> Bool {
        guard let window = window else { return false }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let local = convert(windowPoint, from: nil)
        return bounds.contains(local)
    }

    /// Re-evaluate hover from the *actual* pointer position. This is the general
    /// root-cause fix for a hover that "sticks": the `NSTrackingArea` only emits
    /// `mouseExited` when the pointer crosses into another tracked region, so a
    /// row with a dead zone directly below it (the bottom-most row — under it lie
    /// the card's bottom padding, the inter-card gap and the footer, none of them
    /// tracked) never receives an exit. Driving hover off the real pointer
    /// position makes the highlight clear for ANY row, last or not.
    private func refreshHoverFromPointer() { setHovered(pointerIsInside()) }

    /// Belt-and-suspenders against a sticky hover: whenever the row is added to /
    /// removed from a window (a popover rebuild, scroll, or close), drop any
    /// transient hover so it can't persist as a stale highlight (T-U8), and
    /// (un)install the app-local mouse-moved monitor that guarantees the row
    /// notices the pointer leaving into an untracked dead zone.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
        setNeedsDisplay(bounds)
        if window != nil {
            installMouseMovedMonitor()
        } else {
            removeMouseMovedMonitor()
        }
    }

    private func installMouseMovedMonitor() {
        guard mouseMovedMonitor == nil else { return }
        // `.mouseMoved` fires for pointer movement anywhere in the app; on every
        // move we reconcile hover against the true pointer position, so leaving
        // the row into an untracked region still clears the highlight.
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
        if isInMenu {
            // In a menu the row must paint its own highlight — the menu paints no
            // background behind a custom view (brief §2, gotcha #5).
            if enclosingMenuItem?.isHighlighted == true {
                NSColor.selectedContentBackgroundColor.setFill()
                bounds.fill()
            }
        } else {
            // Menu-less host (popover card / mixer window). A rounded pill behind
            // the row: a subtle accent wash when the device is IN the Selected
            // Devices set (Control Center "on" look), else a fainter hover wash on
            // pointer-over. Both are driven off state that ``apply`` resets, so a
            // deselected row returns to a fully clean background (T-U8 bug fix).
            let rect = bounds.insetBy(dx: 5, dy: 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            if isSelectedInSet && paintsSelectionBackground {
                NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
                path.fill()
            } else if isHovered {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.10).setFill()
                path.fill()
            }
        }
        nameLabel.textColor = rowTextColor
        super.draw(dirtyRect)
    }

    /// Whether the row is currently painting its selected-row background. A
    /// deselected row MUST report `false` — the visual property that encodes the
    /// highlight, asserted by the T-U8 deselect-reset test. Always `false` when
    /// `paintsSelectionBackground` is off (the popover, 2026-07-14).
    public var test_isShowingSelectedBackground: Bool {
        !isInMenu && isSelectedInSet && paintsSelectionBackground
    }
    /// Whether a transient hover wash is currently active (must reset on deselect).
    public var test_isHovered: Bool { isHovered }

    /// Simulate the pointer entering this row (as a real `mouseEntered:` would).
    public func test_simulateMouseEntered() { setHovered(true) }

    /// Simulate a pointer-move reconcile in which the pointer is NO LONGER inside
    /// the row, WITHOUT AppKit ever delivering a `mouseExited:` — exactly the
    /// last-row dead-zone case. The hover must clear anyway. `pointerInside`
    /// stands in for the live pointer-position check the mouse-moved monitor runs
    /// (headless tests can't move a real cursor). General to any row.
    public func test_reconcileHover(pointerInside: Bool) { setHovered(pointerInside) }

    // MARK: Accessibility (brief §5)

    private func configureAccessibility() {
        setAccessibilityElement(true)
        // A menu row is a `.menuItem`; a mixer-window row is a plain grouping.
        setAccessibilityRole(isInMenu ? .menuItem : .group)
        let membership = isSelectedInSet ? "selected" : "not selected"
        // Connection state reads as a trailing clause (brief §6) — omitted
        // entirely for `.off` so an unrouted row's label is unchanged.
        let state = accessibilityStateSuffix
        let stateClause = state.map { ", \($0)" } ?? ""
        setAccessibilityLabel("\(device.name), \(membership), volume \(device.volume) percent\(stateClause)")

        enableSwitch.setAccessibilityLabel(
            isSelectedInSet ? "Remove \(device.name) from Selected Devices"
                            : "Add \(device.name) to Selected Devices")
        slider.setAccessibilityRole(.slider)
        slider.setAccessibilityLabel("\(device.name) volume")
        muteButton.setAccessibilityLabel(device.isMuted ? "Unmute \(device.name)" : "Mute \(device.name)")
        // The name-click is a mouse convenience; the switch stays the
        // authoritative accessibility control. A hint on the name label documents
        // the click for VoiceOver users who land on it.
        nameLabel.setAccessibilityHelp(
            isSelectedInSet ? "Click to remove from Selected Devices"
                            : "Click to add to Selected Devices")
    }

    /// The accessibility-label clause for the current connection state
    /// (brief §6), or `nil` for `.off` — enriches the row label for VoiceOver.
    private var accessibilityStateSuffix: String? {
        switch device.connectionState {
        case .off:           return nil
        case .connecting:    return "connecting"
        case .reconnecting:  return "reconnecting"
        case .connected:     return "connected"
        case .failed:        return "couldn't connect"
        }
    }
}

// MARK: - Delegate default (backward-compatible)

public extension DeviceRowView.Delegate {
    /// Default no-op so conformers that predate the routing control (or that
    /// don't host the on/off switch — e.g. narrow test doubles) still compile.
    /// The real hosts (popover + mixer window) override this to call
    /// `GroupController.setDeviceEnabled`.
    func deviceRow(_ row: DeviceRowView, didToggleEnabled on: Bool, for id: String) {}
}
