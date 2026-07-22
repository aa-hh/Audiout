// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// The single **"Main Out"** row in the popover's System card — styled after
/// macOS Control Center's **Sound module** (SPEC §9, T-U9b). Laid out against the
/// shared popover column grid (task B). Left to right: a leading speaker icon ·
/// name-less flexible zone · a horizontal `NSSlider` (the master volume, stock
/// macOS styling) · a `%` readout · a **named destination dropdown**
/// (`NSPopUpButton`, `pullsDown = false`) as the trailing control.
///
/// (T-U10 briefly moved the glyph into the slider's track to match a full-height
/// capsule redesign; ahh reverted the slider to its original slim-track design,
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
        /// An optional SHORTER label to show on the collapsed pop-up button when
        /// this option is the current selection, while the open menu keeps the
        /// full `title` — for any title too long for the fixed trailing-control
        /// width. `nil` ⇒ the button shows `title` like every other option.
        /// (The host currently passes none: "Selected Devices" is count-free —
        /// Warm Signal decision m — and the column is sized to fit it.)
        public let buttonTitle: String?
        public init(title: String, target: MainOutTarget = .selectedDevices,
                    isHeader: Bool = false, buttonTitle: String? = nil) {
            self.title = title; self.target = target; self.isHeader = isHeader
            self.buttonTitle = buttonTitle
        }
    }

    /// A touch taller than a device row — this is the module's headline control.
    public static let rowHeight: CGFloat = 44

    public weak var delegate: Delegate?

    /// Leading VU meter (task T4a) — the master row gets a LIVE meter (SPEC:
    /// Main Out shares the same level as the device meters for now, until
    /// true per-output metering exists).
    private let meterView = LevelMeterView()
    /// Leading speaker icon (restored — ahh reverted the slider to the original
    /// slim-track design, which does not draw an in-track glyph).
    private let iconView = NSImageView()
    /// The connection **halo ring** around the Main Out icon (Warm Signal v3
    /// §3.2 Main Out note): reflects the AGGREGATE connection lifecycle of the
    /// active Audio Out target's members — **pending** (dashed breathing) during
    /// a destination-switch handshake so the multi-second gap never reads as
    /// dead/broken (spec §6), **connected** (solid `ringConnected`) once ≥1
    /// member is live, no ring when idle. The host computes the aggregate and
    /// passes it to ``apply(options:current:master:isMuted:connectionState:)``.
    private let haloRingView = HaloRingView()
    /// The **gold route-armed corner dot** on the Main Out icon (Warm Signal
    /// v3 §3.3, S2): lit iff the active target set has a connected member AND
    /// the master is unmuted — the aggregate `.connected` ring state already
    /// implies "target set non-empty ∧ ≥1 member connected", so armed =
    /// `connectionState == .connected ∧ !isMuted`. Pure model state, never RMS
    /// (R3): paused and playing render identically; only the meter differs.
    private let armedDotView = RouteArmedDotView()
    /// Whether the master mute is currently engaged — gates the armed dot and
    /// coerces incoming meter pushes to 0 so the drained master meter stays
    /// down while muted (S3).
    private var isMasterMutedState = false
    /// Whether the Main Audio spine is armed (connected target ∧ unmuted) — the
    /// continuous rail overlay reads this to tone the origin hook gold vs ember.
    private var isArmedState = false
    /// The System Audio row's item title — **"Main Audio"** (Warm Signal v4
    /// §Call-1; was "Audio Out"), filling the shared name column so it aligns
    /// with the device rows below.
    private let nameLabel = NSTextField(labelWithString: "Main Audio")
    /// The vertical identity cluster (Warm Signal v4 §Call-1): **name / meter**,
    /// left-aligned, centred as a group — the under-name meter, same anatomy as
    /// the device rows. The rail's `.origin` hook terminates into this meter.
    private let identityStack = NSStackView()
    private let slider = NSSlider()
    /// The Warm Signal fader skin over the master slider (drawing-only
    /// `NSSliderCell` swap — behavior/keyboard/VoiceOver stay stock): recessed
    /// `well` trough, gold `ember → gold` fill iff the Main Out route is armed
    /// (the same `connected ∧ !muted` predicate the corner dot renders),
    /// rounded-rect `raised` thumb. See ``WarmFaderCell``.
    private let faderCell = WarmFaderCell()
    /// A speaker mute button sitting LEFT of the master slider (mirrors the
    /// per-device mute glyph in `DeviceRowView`). `pushOnPushOff`: `.on` = muted.
    private let muteButton = NSButton()
    private let readoutLabel = NSTextField(labelWithString: "")
    /// The **named** SoundSource-style destination dropdown (task B) — an
    /// `NSPopUpButton` (`pullsDown = false`) whose visible title is the currently
    /// selected target. Replaces the old circular icon button. Owns the
    /// two-section menu directly.
    private let destinationPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The membership bus's **origin stub** (spec §4.1: "the bus starts at the
    /// Audio Out row, at the same column where its destination dropdown sits"):
    /// a short straight rail launching downward out of the dropdown's column
    /// toward the device rows below, so the line visibly begins HERE. Rendered
    /// in the dormant de-emphasis tint only while the checked set genuinely
    /// DIVERGES from an active group target (spec §4.7 FINAL, S5 — the
    /// derived-identity case keeps full ink; the host resolves it via
    /// `apply(busOriginDimmed:)`). Non-interactive (`MembershipBusView.hitTest`
    /// returns nil) and animation-free.
    private let busOriginView = MembershipBusView()

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
    ///
    /// `connectionState` is the AGGREGATE lifecycle of the active target's
    /// members (spec §3.2 Main Out note): `.off` → no ring; `.connecting` /
    /// `.reconnecting` → the dashed pending ring during a destination-switch
    /// handshake (spec §6); `.connected` → the solid connected ring. Defaults to
    /// `.off` so existing callers/tests that omit it render no ring, unchanged.
    ///
    /// `busOriginDimmed` is the host-resolved dormancy of the bus's origin stub
    /// (spec §4.7 FINAL, S5): the popover passes `true` only under a
    /// GENUINELY-DIVERGING group target (checked set ≠ the active group's member
    /// set) — the derived-identity case keeps the origin at full ink. `nil`
    /// (legacy callers/tests) falls back to the transitional any-group-target
    /// derivation.
    public func apply(options: [Option], current: MainOutTarget, master: Int, isMuted: Bool = false,
                      connectionState: ConnectionState = .off,
                      busOriginDimmed: Bool? = nil) {
        self.options = options
        isMasterMutedState = isMuted
        muteButton.state = isMuted ? .on : .off
        updateMuteTint()
        haloRingView.apply(connectionState)

        // Route-armed dot (spec §3.3, Main Out variant): armed = the active
        // target has ≥1 CONNECTED member (the aggregate ring state, which
        // already implies a non-empty target set) ∧ master unmuted. Pure model
        // state — never RMS.
        let isConnected: Bool
        if case .connected = connectionState { isConnected = true } else { isConnected = false }
        let armed = isConnected && !isMuted
        isArmedState = armed
        armedDotView.apply(armed: armed)
        // The master fader's engaged (gold) fill reuses the EXACT same armed
        // predicate the dot renders — one armed truth, two instruments.
        faderCell.isRouteArmed = armed
        // Under-name meter shown only on armed (connected + unmuted) rows (v4
        // §Call-1); hidden it collapses in the identity stack, leaving the name.
        meterView.isHidden = !armed

        // Master mute drains the master meter through the existing decay
        // ballistics (S3 — no new animation machinery; Reduce Motion snaps
        // via the meter's own gate; the meter's zero-at-rest guard makes a
        // repeated muted apply free). Unmuting doesn't refill it here — the
        // next live RMS push does, honestly.
        if isMuted {
            meterView.setLevel(0)
        }

        // Bus origin (spec §4.1/§4.7): the launch stub renders in the dormant
        // de-emphasis tint only when the host says the bus is genuinely
        // diverging from the active group target (S5 — mirrors the device rows'
        // node-tint scoping; the derived-identity case keeps full ink). The stub
        // itself never moves or resizes — only its ink changes. Legacy callers
        // that omit `busOriginDimmed` keep the old any-group-target derivation.
        let isGroupTarget: Bool
        if case .group = current { isGroupTarget = true } else { isGroupTarget = false }
        busOriginView.apply(node: .origin, dimmed: busOriginDimmed ?? isGroupTarget,
                            originGold: armed)

        let menu = destinationPopUp.menu ?? NSMenu()
        menu.removeAllItems()
        selectedTitle = nil
        var currentItem: NSMenuItem?
        var currentButtonTitle: String?
        for option in options {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            if option.isHeader {
                item.isEnabled = false
                item.attributedTitle = NSAttributedString(
                    string: option.title.uppercased(),
                    attributes: [
                        .font: Tokens.Font.captionEmphasized,
                        .foregroundColor: Tokens.Color.tertiaryLabel,
                    ])
            } else {
                item.target = self
                item.action = #selector(selectionChanged(_:))
                item.representedObject = option.target
                let isCurrent = option.target == current
                item.state = isCurrent ? .on : .off
                if isCurrent {
                    selectedTitle = option.title
                    currentItem = item
                    currentButtonTitle = option.buttonTitle
                }
            }
            menu.addItem(item)
        }
        destinationPopUp.menu = menu
        // Show the currently selected target as the button's visible title
        // (SoundSource-style named dropdown, task B). The pop-up truncates a long
        // title with a tail ellipsis via its fixed max width + cell line break.
        if let currentItem { destinationPopUp.select(currentItem) }
        // A distinct `buttonTitle` (when an option carries one) is shown on the
        // COLLAPSED button while the open menu keeps the full `title`.
        // `usesItemFromMenu = false` + a display-only cell item is the documented way
        // to make the button label differ from the selected menu item; re-set every
        // `apply` (both branches) so a later selection without an override reverts.
        if let cell = destinationPopUp.cell as? NSPopUpButtonCell {
            if let currentButtonTitle {
                cell.usesItemFromMenu = false
                cell.menuItem = NSMenuItem(title: currentButtonTitle, action: nil, keyEquivalent: "")
            } else {
                cell.usesItemFromMenu = true
            }
        }

        if !isDraggingMaster { slider.integerValue = master }
        readoutLabel.stringValue = "\(master)%"
        configureAccessibility()
    }

    /// Push a live RMS reading to the master meter (task T4a). Main Out shares
    /// the same level feed as the device rows for now. While the master is
    /// muted (S3) an incoming push is coerced to 0 so a straggling RMS event
    /// can never refill the drained master meter.
    public func setLevel(_ rms: Float) {
        meterView.setLevel(isMasterMutedState ? 0 : rms)
    }

    /// Zero the master meter with no animation (popover-close discipline —
    /// PopoverController calls this so a reopen never shows a stale bar).
    public func resetLevel() {
        meterView.reset()
    }

    // MARK: Build

    private func buildSubviews() {
        wantsLayer = true

        meterView.translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        // ahh's requested icon `hifispeaker.arrow.forward.fill` was introduced in
        // macOS 15 (Sequoia); it returns nil on our macOS 13 target and on macOS 14,
        // so it's listed FIRST — it auto-upgrades to the exact symbol once the OS is
        // new enough. Below macOS 15 `hifispeaker.fill` (always available) is the
        // visible fallback (ahh's choice).
        // Match the device rows' glyph sizing (2026-07-17): size the symbol to
        // fill the shared 26pt icon box so the Main Out icon reads at the same
        // scale as the device icons below it (without a config it renders at the
        // small default size and floats in a big box).
        let iconConfig = NSImage.SymbolConfiguration(pointSize: PopoverColumnGrid.iconGlyphPointSize,
                                                     weight: .regular)
        iconView.imageScaling = .scaleProportionallyDown
        for name in ["hifispeaker.arrow.forward.fill", "hifispeaker.fill"] {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Main Out")?
                .withSymbolConfiguration(iconConfig) {
                iconView.image = image
                break
            }
        }
        // Match device row icon styling (2026-07-17): neutral gray, not accent.
        // Consistency across System and Devices sections — all icons are identity
        // only, connection status lives on the icon as a corner badge.
        iconView.contentTintColor = Tokens.Color.secondaryLabel
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        // Connection halo ring around the Main Out icon (spec §3.2 Main Out note).
        haloRingView.translatesAutoresizingMaskIntoConstraints = false
        haloRingView.setContentHuggingPriority(.required, for: .horizontal)

        // Route-armed corner dot on the Main Out icon (spec §3.3, S2).
        armedDotView.translatesAutoresizingMaskIntoConstraints = false

        slider.translatesAutoresizingMaskIntoConstraints = false
        // Warm fader skin: install the drawing-only cell BEFORE the value/
        // target configuration below (a cell swap resets cell-held state, so
        // everything after re-lands on the new cell). Tracking, keyboard,
        // scroll-wheel, `isContinuous`, and VoiceOver stay stock NSSlider.
        slider.cell = faderCell
        slider.minValue = 0
        slider.maxValue = 100
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(masterChanged(_:))
        // Master slider remains enabled while muted to support immediate volume adjustments (audit A5).
        slider.isEnabled = true

        // Speaker mute button, LEFT of the master slider (same visual pattern as
        // `DeviceRowView`'s per-device mute): `pushOnPushOff` so the mute STATE
        // still toggles and the delegate still fires, but the glyph itself stays
        // fixed on `speaker.wave.2.fill` in both states (no alternate/slash image
        // — ahh wants the icon to never change on toggle). Muted state is shown by
        // tint color only.
        muteButton.translatesAutoresizingMaskIntoConstraints = false
        muteButton.setButtonType(.pushOnPushOff)
        muteButton.isBordered = false
        muteButton.imagePosition = .imageOnly
        let muteConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        muteButton.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                                   accessibilityDescription: "Mute Audio Out")?
            .withSymbolConfiguration(muteConfig)
        muteButton.target = self
        muteButton.action = #selector(muteToggled(_:))
        muteButton.setContentHuggingPriority(.required, for: .horizontal)

        readoutLabel.translatesAutoresizingMaskIntoConstraints = false
        readoutLabel.font = Tokens.Font.caption
        readoutLabel.textColor = Tokens.Color.secondaryLabel
        readoutLabel.alignment = .right
        readoutLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Named SoundSource-style destination dropdown (task B): a real
        // `NSPopUpButton` (`pullsDown = false`, SPEC §9 "choosing one from a set,
        // shows the current selection"). Its title is the current target, tail-
        // truncated. It carries the same two-section menu populated in `apply`.
        destinationPopUp.translatesAutoresizingMaskIntoConstraints = false
        destinationPopUp.pullsDown = false
        destinationPopUp.controlSize = .small
        destinationPopUp.font = Tokens.Font.caption
        // Truncate a long target title with a tail ellipsis inside the fixed
        // dropdown width (task B — "truncated with '…' if long").
        (destinationPopUp.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        destinationPopUp.setContentHuggingPriority(.required, for: .horizontal)
        destinationPopUp.setContentCompressionResistancePriority(.required, for: .horizontal)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Tokens.Font.body
        nameLabel.textColor = Tokens.Color.label
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        busOriginView.translatesAutoresizingMaskIntoConstraints = false

        // Identity cluster (v4 §Call-1): "Main Audio" over the under-name meter.
        identityStack.translatesAutoresizingMaskIntoConstraints = false
        identityStack.orientation = .vertical
        identityStack.alignment = .leading
        identityStack.spacing = 2
        identityStack.distribution = .fill
        identityStack.addArrangedSubview(nameLabel)
        identityStack.addArrangedSubview(meterView)

        addSubview(busOriginView)
        addSubview(iconView)
        addSubview(haloRingView)
        addSubview(armedDotView)
        addSubview(identityStack)
        addSubview(muteButton)
        addSubview(slider)
        addSubview(readoutLabel)
        addSubview(destinationPopUp)

        // Laid out against the shared column grid (task B). The meter leads
        // (task T4a — live master meter, same column the device rows reserve);
        // the icon is repointed off `PopoverColumnGrid.firstElementLeading` so
        // it lines up with the device rows below it. The slider, `%` readout
        // and the named dropdown (the trailing control) are all anchored off
        // the TRAILING edge so they line up with the device and group rows.
        // The dropdown gets a comfortable fixed width so a named target fits
        // and truncates gracefully.
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor,
                                              constant: PopoverColumnGrid.firstElementLeading(indented: false)),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),
            iconView.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),

            // Connection halo ring: a box matching the icon box, centered on it.
            haloRingView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),
            haloRingView.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),
            haloRingView.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            haloRingView.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            // Route-armed dot: the icon box's bottom-right corner, pulled in
            // by `statusDotInset` — same geometry as the device rows (§3.3).
            armedDotView.widthAnchor.constraint(
                equalToConstant: PopoverColumnGrid.routeArmedDotBoxSize),
            armedDotView.heightAnchor.constraint(
                equalToConstant: PopoverColumnGrid.routeArmedDotBoxSize),
            armedDotView.centerXAnchor.constraint(
                equalTo: iconView.trailingAnchor,
                constant: -PopoverColumnGrid.statusDotInset),
            armedDotView.centerYAnchor.constraint(
                equalTo: iconView.bottomAnchor,
                constant: -PopoverColumnGrid.statusDotInset),

            // Identity cluster ("Main Audio" over the under-name meter), centred
            // as a group; yields to the mute glyph so the name truncates.
            identityStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                                    constant: PopoverColumnGrid.iconToName),
            identityStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            identityStack.trailingAnchor.constraint(lessThanOrEqualTo: muteButton.leadingAnchor,
                                                    constant: -PopoverColumnGrid.nameToSlider),

            // The under-name meter's fixed size (v4 §Call-1).
            meterView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.meterUnderNameWidth),
            meterView.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.meterUnderNameHeight),

            // Speaker mute button, LEFT of the slider.
            muteButton.trailingAnchor.constraint(equalTo: slider.leadingAnchor,
                                                 constant: -PopoverColumnGrid.muteToSlider),
            muteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            muteButton.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.muteWidth),

            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.sliderWidth),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor,
                                             constant: -PopoverColumnGrid.sliderTrailing),

            // `%` readout: tight to the right of the slider (change 4), not
            // trailing-anchored — so the number reads against its slider and the
            // flex slack sits between it and the trailing dropdown.
            readoutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            readoutLabel.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.readoutWidth),
            readoutLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor,
                                                  constant: PopoverColumnGrid.sliderToReadout),

            destinationPopUp.centerYAnchor.constraint(equalTo: centerYAnchor),
            destinationPopUp.widthAnchor.constraint(
                equalToConstant: PopoverColumnGrid.trailingControlWidth),
            destinationPopUp.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -PopoverColumnGrid.trailingControlTrailing),

            // Bus origin HOOK (v4 §Call-1): the rail rises at `railGutterCenterX`
            // in the LEFT gutter and turns INTO the under-name meter. The view is
            // framed leading-edge → the identity cluster's leading (= the meter's
            // leading, left-aligned), and top → the cluster's bottom (the meter's
            // band) → row bottom; `MembershipBusView.origin` draws the L from the
            // row bottom up to the top-right corner (the meter's leading edge).
            busOriginView.leadingAnchor.constraint(equalTo: leadingAnchor),
            busOriginView.trailingAnchor.constraint(equalTo: identityStack.leadingAnchor),
            busOriginView.topAnchor.constraint(equalTo: identityStack.bottomAnchor),
            busOriginView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Private Helpers

    /// Updates the mute button's engaged treatment (tint + the S3 filled
    /// accent pill, spec §3.4/§3.5) and accessibility label for the current
    /// state. Drawing-only, on the real `NSButton`'s backing layer — behavior,
    /// keyboard, and VoiceOver untouched; the glyph NEVER swaps to a slash
    /// (locked decision). Mirrors `DeviceRowView.updateMuteTint()`.
    private func updateMuteTint() {
        let engaged = muteButton.state == .on
        muteButton.contentTintColor = engaged ? Tokens.Color.accent : Tokens.Color.secondaryLabel
        muteButton.wantsLayer = true
        muteButton.layer?.cornerRadius = PopoverColumnGrid.mutePillCornerRadius
        effectiveAppearance.performAsCurrentDrawingAppearance {
            muteButton.layer?.backgroundColor = engaged
                ? Tokens.Color.accent.withAlphaComponent(PopoverColumnGrid.mutePillFillAlpha).cgColor
                : nil
        }
        configureAccessibility()
    }

    /// The pill's engaged fill is a static `CGColor` — re-stamp on a live
    /// light/dark or Increase-Contrast switch (ring/dot/bus handle their own).
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMuteTint()
    }

    // MARK: Actions

    @objc private func selectionChanged(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? MainOutTarget else { return }
        delegate?.mainOutRow(self, didSelect: target)
    }

    @objc private func muteToggled(_ sender: NSButton) {
        // AppKit already flipped the pushOnPushOff state; land the engaged
        // treatment (and the "muted" AX value / meter push-gate) instantly on
        // the live click rather than waiting for the host-driven `apply`.
        isMasterMutedState = sender.state == .on
        updateMuteTint()
        delegate?.mainOutRow(self, didSetMuted: sender.state == .on)
    }

    // STABILITY(D4): the drag flag clears only on the .leftMouseUp coincidence — a cancelled drag leaves it stuck and leaves GroupController's drag-ratio cache stale (end-drag never fires); see dev/notes/stability-audit-2026-07-18.md
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
        setAccessibilityLabel("Main Audio, master volume \(slider.integerValue) percent")
        // The row's VALUE carries the live signal channels (S2/S3): "muted"
        // for the engaged master-mute pill, "armed" for the lit route-armed
        // dot — the spoken equivalents shipped with the drawing.
        var valueParts: [String] = []
        if isMasterMutedState { valueParts.append("muted") }
        if armedDotView.test_isLit { valueParts.append("armed") }
        setAccessibilityValue(valueParts.joined(separator: ", "))
        slider.setAccessibilityRole(.slider)
        slider.setAccessibilityLabel("Main Audio master volume")
        muteButton.setAccessibilityLabel(muteButton.state == .on ? "Unmute Main Audio" : "Mute Main Audio")
        destinationPopUp.setAccessibilityLabel("Main Audio destination")
        destinationPopUp.setAccessibilityValue(selectedTitle ?? "")
    }

    // MARK: Test-support hooks

    /// The titles currently in the selector menu, in order (incl. headers).
    public var test_optionTitles: [String] { options.map(\.title) }
    /// The selectable (non-header) targets, in order.
    public var test_selectableTargets: [MainOutTarget] { options.filter { !$0.isHeader }.map(\.target) }
    /// The currently shown master value.
    public var test_masterValue: Int { slider.integerValue }
    /// The currently checkmarked selection title (the full menu title).
    public var test_selectedTitle: String? { selectedTitle }
    /// The label actually shown on the COLLAPSED pop-up button — the current
    /// option's `buttonTitle` when it set one (e.g. "Selected (n)"), else the
    /// full selected title. Lets tests assert the button/menu split (A2). Reads
    /// the display-only cell item when `usesItemFromMenu` is off, exactly what
    /// the button renders.
    public var test_buttonTitle: String? {
        guard let cell = destinationPopUp.cell as? NSPopUpButtonCell else {
            return destinationPopUp.titleOfSelectedItem
        }
        return cell.usesItemFromMenu ? destinationPopUp.titleOfSelectedItem : cell.menuItem?.title
    }
    /// Whether the master mute button is currently in its muted (`.on`) state.
    public var test_isMasterMuted: Bool { muteButton.state == .on }

    /// The bus origin stub's node rendering (always `.origin` — the launch
    /// stub, spec §4.1) — proves the bus starts at the Audio Out row.
    public var test_busOriginNode: MembershipBusView.Node { busOriginView.test_node }
    /// Whether the origin stub renders in the dormant de-emphasis tint (Audio
    /// Out targets a saved group, so the Selected-Devices bus is inactive).
    public var test_busOriginDimmed: Bool { busOriginView.test_dimmed }

    /// The Main Out connection ring's current form (spec §3.2 Main Out note) —
    /// `.none` idle, `.connecting` during a destination-switch handshake,
    /// `.connected` once the active target is live.
    public var test_ringForm: HaloRingView.Form { haloRingView.test_form }
    /// Whether the Main Out ring's pending-handshake breathing pulse is installed.
    public var test_ringIsBreathing: Bool { haloRingView.test_isBreathing }

    /// Whether the Main Out route-armed corner dot is LIT (spec §3.3: active
    /// target has a connected member ∧ master unmuted) — reads the dot view's
    /// rendered state, so it can't drift from the pixels.
    public var test_routeArmed: Bool { armedDotView.test_isLit }

    /// Whether the master fader would render its ENGAGED (gold-gradient) fill
    /// — the cell's own gate, so the test can't drift from the pixels. Must
    /// track `test_routeArmed` (one armed truth, two instruments).
    public var test_isFaderEngaged: Bool { faderCell.test_isEngagedFill }

    /// Whether the master slider is wearing the Warm fader skin (structural).
    public var test_hasWarmFaderSkin: Bool { slider.cell is WarmFaderCell }
    /// The dot's current fill color (resolved) — gold armed / socket dark.
    public var test_dotFillColor: NSColor? { armedDotView.test_fillColor }
    /// Whether the master-mute button is drawing its ENGAGED pill (S3).
    public var test_isMutePillEngaged: Bool {
        muteButton.state == .on && muteButton.layer?.backgroundColor != nil
    }
    /// The row's current VoiceOver VALUE ("muted" / "armed" composition).
    public var test_accessibilityValue: String? { accessibilityValue() as? String }
    /// The master meter's current ballistics TARGET (with
    /// ``test_meterDisplayed``, proves the master-mute DRAIN — target 0 while
    /// the bar is still easing down — vs a hard reset).
    public var test_meterTarget: CGFloat { meterView.test_targetLevel }
    /// The master meter's currently DRAWN level.
    public var test_meterDisplayed: CGFloat { meterView.test_displayedLevel }

    /// Settle the master meter's DRAWN level synchronously (no display link) —
    /// deterministic setup for drain-vs-reset assertions and snapshots.
    public func test_settleMeterDisplayed(_ level: CGFloat) {
        meterView.test_setDisplayedLevel(level)
    }

    /// Simulate the user toggling the master mute button.
    public func test_toggleMasterMute() {
        delegate?.mainOutRow(self, didSetMuted: !(muteButton.state == .on))
    }

    /// Simulate the user choosing `target` from the selector.
    ///
    /// This is a *shortcut* that calls the delegate directly — it deliberately
    /// bypasses AppKit's real menu-item action dispatch. To exercise the genuine
    /// click path (each `NSMenuItem` carries its own target/action, and AppKit
    /// invokes it with the menu item as sender), use ``test_menuItem(for:)`` and
    /// fire its `action` — see `MainOutRowMenuDispatchTests`. A mismatch between
    /// the handler's expected sender type and what AppKit passes is invisible to
    /// this shortcut but breaks real clicks (it silently broke group activation).
    public func test_select(_ target: MainOutTarget) {
        delegate?.mainOutRow(self, didSelect: target)
    }

    /// The real `NSMenuItem` in the destination pop-up whose target is `target`,
    /// or `nil` if no such selectable item exists. Exposes the live menu item —
    /// including its `representedObject`, `target`, and `action` — so tests can
    /// drive the actual AppKit dispatch path rather than the ``test_select``
    /// shortcut. Mirrors `AppRowView.test_destinationPopUpMenuItem(forDestinationID:)`.
    public func test_menuItem(for target: MainOutTarget) -> NSMenuItem? {
        destinationPopUp.menu?.items.first { ($0.representedObject as? MainOutTarget) == target }
    }

    /// The raw `NSMenuItem` whose (plain) title matches `title`, or `nil`. Lets a
    /// test reach a **header** item — which has no target, so `test_menuItem(for:)`
    /// can't find it — to assert it is disabled and inert.
    public func test_menuItem(titled title: String) -> NSMenuItem? {
        destinationPopUp.menu?.items.first { $0.title == title }
    }

    /// Simulate a master drag to `value`.
    public func test_dragMaster(to value: Int) {
        delegate?.mainOutRowBeginMasterDrag(self)
        delegate?.mainOutRow(self, didSetMaster: value)
        delegate?.mainOutRowEndMasterDrag(self)
    }
}

// MARK: - Continuous rail origin hook (Warm Signal v4 §Call-1)

extension MainOutRowView: RailHookProviding {
    /// The origin-hook anchor for the continuous rail overlay: the under-name
    /// meter's leading edge + centre-y (or, when the meter is hidden on an idle
    /// Main Audio, the identity cluster's leading + centre), converted into
    /// `view`'s coordinates, plus whether the spine is armed (gold vs ember).
    public func railHookAnchor(in view: NSView) -> (leadingX: CGFloat, centerY: CGFloat, gold: Bool)? {
        layoutSubtreeIfNeeded()
        let anchorView: NSView = meterView.isHidden ? identityStack : meterView
        let rectInSelf = anchorView.convert(anchorView.bounds, to: self)
        let point = convert(NSPoint(x: rectInSelf.minX, y: rectInSelf.midY), to: view)
        return (point.x, point.y, isArmedState)
    }
}
