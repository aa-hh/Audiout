// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// A single device row in a **membership checklist** — the group-creation
/// sheet's device list and the group editor's membership pane (design revamp:
/// the Groups window becomes CONFIGURATION-ONLY, so this row only ever edits
/// *membership*, never routing/activation). Composition is stock AppKit: a
/// checkbox `NSButton`, the device's SF Symbol in an `NSImageView` tinted
/// identity-neutral like the sidebar's `makeIconLabel`, and an `NSTextField`
/// name label.
///
/// Deliberately NOT `DeviceRowView` (`../AudioutSharedUI/DeviceRowView.swift`):
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

    /// Which host surface this row is drawn on — the one input that decides
    /// whether it wears the Warm Signal v4 rail/node language or stays a plain
    /// stock checkbox row (Alec, Q6 2026-07-25).
    ///
    /// The row has exactly TWO hosts and they are visually different surfaces:
    /// the Groups editor is a WARM pane (`Tokens.Color.canvas` family), while
    /// "New Group" is a standard AppKit sheet on the system's own white/grey.
    /// `ember` measures ~2.34–2.48:1 on that white — the gold node would be
    /// near-invisible there — so the rail is warm-pane-only and the sheet keeps
    /// plain stock rows. Do NOT warm the Apple sheet, and do NOT introduce a
    /// second, darker gold to make the node survive on white.
    public enum Surface: Equatable {
        /// The Groups window's group editor: invisible checkbox cell + a gold
        /// `MembershipBusView` node, threaded by the pane-level rail overlay.
        case warmPane
        /// The stock "New Group" sheet: an ordinary AppKit checkbox row.
        case systemSheet
    }

    /// Whether this row's rail node renders ARMED (gold — the group is the
    /// active Main Out, audio flows through these members) or idle (`ember` —
    /// pure configuration, nothing moving). Gold means LIVE everywhere in
    /// Audiout, so an editor showing an inactive group must not fill its
    /// member discs gold. Host-set; `.systemSheet` rows have no node and ignore
    /// it.
    public var railArmed: Bool = true {
        didSet { if railArmed != oldValue { updateBus() } }
    }

    /// Fired whenever the user toggles the row's checkbox.
    /// `deviceID`/`isChecked` mirror the row's current state at call time.
    public var onToggle: ((_ deviceID: String, _ isChecked: Bool) -> Void)?

    public private(set) var device: Device
    private var checked: Bool
    private var iconSymbolName: String?
    private let surface: Surface
    /// Whether the pointer is over the row. Stored rather than read back off the
    /// node, because ``setCheckboxEnabled(_:tooltip:)`` has to re-decide whether
    /// that hover may still be SHOWN after the checkbox's enablement changes
    /// under a stationary pointer.
    private var rowHovered = false

    private let checkbox = NSButton()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    /// Small secondary annotation shown only for an unavailable member
    /// ("Unavailable") — never a routing/status claim, just presence.
    private let unavailableLabel = NSTextField(labelWithString: "")

    /// The checkbox's DRAWN skin on `.warmPane` (Warm Signal v4 §Call-1): a
    /// non-interactive node disc centred on the real checkbox. Built for every
    /// row but only mounted on `.warmPane`, so a `.systemSheet` row has no node
    /// in its view tree at all.
    private let busView = MembershipBusView()

    public init(device: Device, checked: Bool, iconSymbolName: String? = nil,
                surface: Surface = .systemSheet) {
        self.device = device
        self.checked = checked
        self.iconSymbolName = iconSymbolName
        self.surface = surface
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: Self.rowHeight))
        // A checked device here is dimmed for exactly one reason — it's
        // physically unavailable, not merely outside some other target — so
        // the rim carries the extra weight the popover's own dimmed member
        // (a configuration divergence, still fully reachable) doesn't need.
        busView.emphasizesDimmedMemberRim = true
        buildSubviews()
        apply(device: device, checked: checked, iconSymbolName: iconSymbolName)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Fixed row height matching the shared row rhythm used elsewhere in the
    /// window (`DeviceRowView.rowHeight` is 42; a checklist row carries no
    /// slider/sublabel, so it can afford to be shorter).
    ///
    /// 28 → 32 (2026-08-12): the WHOLE row is the click target on `.warmPane`
    /// now, and a 28pt target with a 6pt gap read as a cramped list rather
    /// than something to hit. Two budgets follow this number — the editor
    /// pane's fitting height (the fixed surface frame's
    /// `AppSurfaceController.minimumContentSize` floor,
    /// `MembershipRailTests`) and the create sheet's
    /// `GroupCreationSheetController.checklistMaxHeight` — so re-check both if
    /// it moves again.
    public static let rowHeight: CGFloat = 32

    public var deviceID: String { device.id }

    /// Read/write membership state. Setting it updates the checkbox but does
    /// NOT fire `onToggle` — that callback is reserved for user-driven toggles
    /// (real click or `test_toggle()`), never a programmatic model refresh.
    public var isChecked: Bool {
        get { checked }
        set {
            checked = newValue
            checkbox.state = newValue ? .on : .off
            updateCheckboxAccessibilityLabel()
            updateBus()
        }
    }

    // MARK: Build

    private func buildSubviews() {
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        // Warm pane (spec §4.8 "only the DRAWING changes"): swap in the shared
        // no-op-drawing cell BEFORE `setButtonType`, which configures the
        // EXISTING cell in place so the subclass survives it. The checkbox stays
        // a real, focusable, keyboard- and VoiceOver-operable `.switch` button —
        // it simply renders nothing, and `busView`'s node is its visible skin.
        if surface == .warmPane { checkbox.cell = InvisibleSwitchCell() }
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
        iconView.contentTintColor = Tokens.Color.secondaryLabel

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Tokens.Font.body
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        unavailableLabel.translatesAutoresizingMaskIntoConstraints = false
        unavailableLabel.font = Tokens.Font.caption
        unavailableLabel.textColor = Tokens.Color.secondaryLabel
        unavailableLabel.stringValue = "Unavailable"
        unavailableLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(checkbox)
        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(unavailableLabel)

        // Common (surface-independent) geometry: the vertical rhythm and the
        // name/annotation columns are identical on both surfaces.
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),

            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),

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

        switch surface {
        case .warmPane:
            buildWarmPaneLeadingColumns()
        case .systemSheet:
            // Stock rows, byte-identical to the pre-rail layout: the checkbox
            // leads, the icon follows it.
            NSLayoutConstraint.activate([
                checkbox.leadingAnchor.constraint(equalTo: leadingAnchor),
                iconView.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 6),
            ])
        }
    }

    /// The warm pane's leading columns (Warm Signal v4 §Call-1, the LEFT SPINE):
    /// the node — and with it the real checkbox it skins — sits at
    /// `railGutterCenterX` measured from the row's LEADING edge, and the icon
    /// starts at `firstElementLeading`, which reserves that gutter plus
    /// `busNodeClearance` of clear space so the node never crowds the glyph.
    ///
    /// The row's leading edge must line up with the rail overlay's leading edge:
    /// `BusRailOverlayView` draws the spine at the literal `railGutterCenterX`
    /// in its OWN coordinate space, so the host is responsible for pinning the
    /// two to the same x (`GroupEditorViewController`, asserted by
    /// `test_nodeCenterXInOverlaySpace`).
    private func buildWarmPaneLeadingColumns() {
        busView.translatesAutoresizingMaskIntoConstraints = false
        // Added BELOW the checkbox in z-order is not required — the bus view
        // never hit-tests (`MembershipBusView.hitTest` returns nil), so a click
        // anywhere on the node area falls through to the invisible checkbox.
        addSubview(busView)

        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(
                equalTo: leadingAnchor, constant: PopoverColumnGrid.railGutterCenterX),
            iconView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: PopoverColumnGrid.firstElementLeading(indented: false)),

            busView.centerXAnchor.constraint(equalTo: checkbox.centerXAnchor),
            busView.centerYAnchor.constraint(equalTo: centerYAnchor),
            busView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.busColumnWidth),
            busView.heightAnchor.constraint(equalTo: heightAnchor),
        ])
    }

    /// Re-derive the drawn node from the current membership state. The node
    /// vocabulary here is deliberately BINARY — filled gold `.member` when
    /// checked, hollow `.nonMember` when not — because this checklist edits
    /// *membership*, which has no connection/energize states to report (the
    /// popover's `DeviceRowView` owns those). In particular the pinned sole
    /// member (`setCheckboxEnabled(false)`) still renders `.member`: it IS a
    /// member, and `.blocked`'s greyed hollow node would wrongly read as "not
    /// in this group". No-op on `.systemSheet`, which mounts no node at all.
    private func updateBus() {
        guard surface == .warmPane else { return }
        // The node dims with the rest of the row — fill only: an unavailable
        // member keeps its seat and rim on the rail and goes grey where it
        // would be gold, so it still reads as "in this group, not playing".
        busView.apply(node: checked ? .member : .nonMember,
                      dimmed: !device.isAvailable,
                      armed: railArmed)
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

        // CACHED and SHARED — never mutate the returned image; the tint is a
        // view property. The row's own a11y label (below) already speaks the
        // device name, so the glyph carries no description of its own.
        let symbolName = DeviceIcon.resolve(iconSymbolName, default: device.kind.symbolName)
        iconView.image = DeviceIcon.image(symbolName,
                                          pointSize: PopoverColumnGrid.iconGlyphPointSize,
                                          weight: .regular)

        nameLabel.stringValue = device.name
        // ONE unavailable tone, and all three elements take it together. The
        // name, the glyph and the WORD each state the same fact, so splitting
        // them across tones makes the row argue with itself — set one of these
        // three and you have to set all three.
        //
        // `inkTertiary` is authored, ships all four variants, and measures
        // 5.57:1 on `raised`. It is also what the popover's device rows already
        // use for this exact state (`DeviceRowView.showSublabel("Unavailable",
        // …)`), so the two surfaces name the state in one voice.
        //
        // NOT `.disabledControlTextColor`: it is black at 24.7% alpha, so it
        // composites against its ground to 1.80:1 on `raised` — under half the
        // 4.5:1 text floor — and being a system colour it carries no
        // Increase-Contrast variant and no measured floor to fail on.
        //
        // Still fully interactive: an unavailable device stays
        // checkable/uncheckable so an existing member can be removed offline.
        let unavailableTone = Tokens.Color.inkTertiary
        nameLabel.textColor = device.isAvailable ? Tokens.Color.label : unavailableTone
        iconView.contentTintColor = device.isAvailable ? Tokens.Color.secondaryLabel : unavailableTone
        unavailableLabel.textColor = unavailableTone

        unavailableLabel.isHidden = device.isAvailable

        setAccessibilityLabel(
            "\(device.name)\(device.isAvailable ? "" : ", unavailable")")
        updateCheckboxAccessibilityLabel()

        updateBus()
    }

    /// Re-announce the checkbox's VERB from the CURRENT membership state. It
    /// used to be written once in ``apply(device:checked:iconSymbolName:)`` and
    /// never again, so a row toggled in place kept telling VoiceOver to "Add"
    /// a device it had just added. Every path that changes `checked` calls
    /// this.
    private func updateCheckboxAccessibilityLabel() {
        checkbox.setAccessibilityLabel(
            checked ? "Remove \(device.name) from group" : "Add \(device.name) to group")
    }

    /// Enable or disable the membership checkbox, with an optional tooltip
    /// explaining why. Hosts use this to pin the sole remaining member of a
    /// group (a group must keep at least one device). Call AFTER ``apply``,
    /// which re-enables the checkbox as part of a host-driven refresh.
    public func setCheckboxEnabled(_ enabled: Bool, tooltip: String? = nil) {
        checkbox.isEnabled = enabled
        checkbox.toolTip = tooltip
        // VoiceOver does not reliably announce `toolTip`; the "why is this
        // disabled" explanation has to travel as accessibilityHelp too.
        checkbox.setAccessibilityHelp(tooltip)
        // Pinning happens under a stationary pointer (a rebuild after the
        // second-to-last member was unchecked), so a ring already on screen has
        // to be withdrawn here — no `mouseExited` follows.
        applyHoverToNode()
    }

    /// Whether the checkbox is currently interactive (for structural assertions).
    public var test_isCheckboxEnabled: Bool { checkbox.isEnabled }

    /// The checkbox's VoiceOver help text (mirrors the tooltip — the pinned
    /// sole member's "why is this disabled" explanation must be announced too).
    public var test_checkboxAccessibilityHelp: String? { checkbox.accessibilityHelp() }

    /// Whether this row's node renders in the armed (gold) tone; always the
    /// host-set ``railArmed`` value, read back through the drawn node itself.
    public var test_railArmed: Bool {
        surface == .warmPane ? busView.test_armed : railArmed
    }

    // MARK: The whole row is one click target (warm pane only)

    /// On `.warmPane` the row body is the click target, so nothing inside it may
    /// swallow a click: a non-editable `NSTextField` and an `NSImageView` still
    /// hit-test to themselves and consume the mouse, which left the name, the
    /// glyph and the "Unavailable" annotation dead. Collapsing every hit that
    /// isn't the real checkbox onto the row is ONE fix instead of a click
    /// recognizer per label. `.systemSheet` keeps stock hit-testing — its
    /// checkbox is visible and the row is not an affordance.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard surface == .warmPane, let hit else { return hit }
        return hit === checkbox ? hit : self
    }

    /// Swallowed so the matching `mouseUp` is delivered here; the toggle itself
    /// fires on mouse-UP, so dragging off the row cancels it exactly like the
    /// checkbox this row stands in for.
    public override func mouseDown(with event: NSEvent) {
        guard surface == .warmPane, checkbox.isEnabled else {
            return super.mouseDown(with: event)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        guard surface == .warmPane, checkbox.isEnabled,
              bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return super.mouseUp(with: event)
        }
        rowClicked()
    }

    /// A click on the row body, routed through the SAME path the real checkbox
    /// takes — one toggle, one `onToggle`, whichever way the user reached it.
    /// A pinned (disabled) row refuses it, as the checkbox itself would.
    private func rowClicked() {
        guard surface == .warmPane, checkbox.isEnabled else { return }
        performToggle()
    }

    // MARK: Hover (the "this row is clickable" affordance)

    /// One tracking area over the WHOLE row, not just the gutter: now that the
    /// body toggles, the ring has to answer a pointer anywhere on the row.
    /// `.inVisibleRect` keeps the rect live, so no geometry is cached here.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard surface == .warmPane else { return }
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
        // Re-tracking means the row was rebuilt or moved UNDER a stationary
        // pointer (every membership toggle rebuilds this list), and no
        // `mouseEntered`/`mouseExited` follows that — so read the pointer's real
        // position rather than wait for the next move.
        refreshHoverFromPointer()
    }

    private func refreshHoverFromPointer() {
        guard let window else { return setRowHovered(false) }
        setRowHovered(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    public override func mouseEntered(with event: NSEvent) { setRowHovered(true) }
    public override func mouseExited(with event: NSEvent) { setRowHovered(false) }

    private func setRowHovered(_ hovered: Bool) {
        rowHovered = hovered
        applyHoverToNode()
    }

    /// Push the hover into the node — but only from a row whose checkbox is
    /// actually enabled (`../AudioutSharedUI/AGENTS.md`). `MembershipBusView`
    /// refuses a `.blocked` node on its own; a PINNED row here keeps its
    /// `.member` node (it IS a member), so the refusal for that case has to
    /// live in the row, on the checkbox's real enablement.
    private func applyHoverToNode() {
        guard surface == .warmPane else { return }
        busView.setHovered(rowHovered && checkbox.isEnabled)
    }

    // MARK: Actions

    @objc private func checkboxToggled(_ sender: NSButton) {
        checked = sender.state == .on
        updateCheckboxAccessibilityLabel()
        updateBus()
        onToggle?(device.id, checked)
    }

    /// Flip the real control and dispatch its action — the single path every
    /// toggle affordance (checkbox click, row click, test hook) funnels through,
    /// so none of them can grow a second, divergent rule.
    private func performToggle() {
        checkbox.state = checkbox.state == .on ? .off : .on
        checkboxToggled(checkbox)
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
        performToggle()
    }

    /// Simulate a click on the row BODY (not the checkbox) — the same
    /// ``rowClicked()`` a real `mouseUp` reaches, so the surface split and the
    /// disabled-checkbox refusal are exercised, not bypassed.
    public func test_clickRow() {
        rowClicked()
    }

    /// Drive the row's pointer state headlessly — the same path the tracking
    /// area's `mouseEntered`/`mouseExited` take.
    public func test_setHovered(_ hovered: Bool) {
        setRowHovered(hovered)
    }

    /// Whether the node is previewing its post-click size — grown or shrunk
    /// (reads the node's own resolved radii, so it can't drift from the pixels).
    public var test_nodePreviewsClick: Bool {
        surface == .warmPane && busView.test_nodePreviewsClick
    }

    /// The name label's current text (for asserting the row shows the right
    /// device).
    public var test_nameText: String { nameLabel.stringValue }

    /// Whether the row is currently rendered dimmed (unavailable device).
    public var test_isDimmed: Bool { !device.isAvailable }

    /// The surface this row was built for.
    public var test_surface: Surface { surface }

    /// The node rendering currently drawn, or `nil` on `.systemSheet` (which
    /// mounts no node view at all). Reads the same state `draw` reads.
    public var test_busNode: MembershipBusView.Node? {
        surface == .warmPane ? busView.test_node : nil
    }

    /// Whether a node view is mounted in this row's view tree — false for every
    /// `.systemSheet` row (Q6: no node, no rail, no gold on the Apple sheet).
    public var test_hasBusNodeView: Bool { busView.superview === self }

    /// Whether the checkbox wears the invisible-drawing cell (warm pane only).
    /// It is still a real, enabled, keyboard/VoiceOver-operable `NSButton`.
    public var test_hasInvisibleCheckboxSkin: Bool { checkbox.cell is InvisibleSwitchCell }

    /// The node's centre x in the ROW's own coordinates, or `nil` on
    /// `.systemSheet`. Must equal `PopoverColumnGrid.railGutterCenterX`.
    public var test_nodeCenterX: CGFloat? {
        surface == .warmPane ? busView.frame.midX : nil
    }

    /// The checkbox's own VoiceOver label (the membership verb), asserted
    /// unchanged across the surface split.
    public var test_checkboxAccessibilityLabel: String? { checkbox.accessibilityLabel() }
}

// MARK: - Continuous rail contribution (Warm Signal v4 §Call-1)

/// The warm pane's rail is drawn ONCE at pane level (`BusRailOverlayView`), not
/// per row: the row contributes its node kind and the frame the node is centred
/// on. A `.systemSheet` row reports `nil`, so the same type can sit in an
/// overlay's `deviceRows` and contribute nothing.
extension MembershipRowView: RailNodeProviding {
    public var railNode: MembershipBusView.Node? { test_busNode }
    public var railDeviceID: String? { device.id }
    public var railNodeView: NSView { self }
    public var railNodeBounds: NSRect { bounds }
}
