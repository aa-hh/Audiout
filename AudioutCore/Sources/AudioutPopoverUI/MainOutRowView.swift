// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The single **"Main Audio"** row in the popover's System card — styled after
/// macOS Control Center's **Sound module** (SPEC §9, T-U9b). Laid out against the
/// shared popover column grid (task B). Left to right: a leading speaker icon ·
/// name-less flexible zone · a horizontal `NSSlider` (the master volume, stock
/// macOS styling) · a `%` readout · a **named destination dropdown**
/// (`NSPopUpButton`, `pullsDown = false`) as the trailing control.
///
/// (Slim slider track + leading icon are ahh's locked design; T-U10's in-track
/// glyph was reverted.)
///
/// The **named destination dropdown** (task B) SHOWS THE CURRENTLY SELECTED
/// target's title (truncated with "…" if long). It is THE routing control — one
/// place answers "where is my audio going?" — and keeps the two-section menu
/// content (SPEC §9b — separators + headers):
///   §1  "Selected Speakers"      -> `.selectedDevices`
///   §2  each saved scene -> `.group(id)`
/// The current target is checkmarked AND its title is the button's visible label,
/// its accessibility value, and the `test_selectedTitle` hook.
///
/// While the target is a saved GROUP a `GroupIdentityGlowView` lights behind
/// the icon (R2, the iOS "party edge") and the picker names the group — the
/// row still paints no fill of its own.
///
/// Pure UI: every control routes back through ``Delegate`` so the host
/// (`PopoverController`) can drive `GroupController`. The view never talks to a
/// backend directly.
public final class MainOutRowView: NSView {

    public protocol Delegate: AnyObject {
        func mainOutRow(_ row: MainOutRowView, didSelect target: MainOutTarget)
        func mainOutRow(_ row: MainOutRowView, didSetMaster volume: Int)
        func mainOutRow(_ row: MainOutRowView, didSetMuted muted: Bool)
        /// The user asked for the WHOLE MIX's Equalizer — the "Equalizer…"
        /// context-menu item, or a click on this row's icon, which pops the
        /// same menu. The host deep-links to the Groups screen's Main Audio
        /// page; this row edits no tone (owner decision 2026-08-22: EQ never
        /// lives on the Mixer). Default no-op.
        func mainOutRowDidRequestEqualizer(_ row: MainOutRowView)
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
        /// (The host currently passes none: "Selected Speakers" is count-free —
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

    /// Under-name VU meter (task T4a) — the master row gets a LIVE meter (SPEC:
    /// Main Out shares the same level as the device meters for now, until
    /// true per-output metering exists). Warm Signal v4.1 CORRECTIONS, item 1:
    /// it lives UNDER THE "Main Audio" NAME, exactly like a device meter sits
    /// under its device name — same position, same geometry — but THICKER
    /// (`masterMeterThickness`, 6pt vs the device rows' 3pt) to denote the
    /// master bus, so the per-instance `thickness` param is threaded through
    /// instead of the shared default.
    private let meterView = LevelMeterView(thickness: PopoverColumnGrid.masterMeterThickness)
    /// Leading speaker icon (restored — ahh reverted the slider to the original
    /// slim-track design, which does not draw an in-track glyph).
    private let iconView = MenuTriggerImageView()
    /// The magenta identity light a GROUP target gives off, behind the icon.
    private let groupGlowView = GroupIdentityGlowView()
    /// The connection **halo ring** around the Main Out icon (Warm Signal v3
    /// §3.2 Main Out note): reflects the AGGREGATE connection lifecycle of the
    /// active Audio Out target's members — **pending** (dashed breathing) during
    /// a destination-switch handshake so the multi-second gap never reads as
    /// dead/broken (spec §6), **connected** (solid `ringConnected`) once ≥1
    /// member is live, no ring when idle. The host computes the aggregate and
    /// passes it to ``apply(options:current:master:isMuted:connectionState:)``.
    private let haloRingView: HaloRingView = {
        let ring = HaloRingView()
        // Bespoke terminus sizing (Warm Signal nitpicks — Main Audio's ring is
        // the rail's terminus, not a peer of the device rows' rings): matches
        // the rail's own stroke weight so the join reads as one line.
        ring.diameterOverride = PopoverColumnGrid.mainAudioRingDiameter
        ring.connectedStrokeWidthOverride = PopoverColumnGrid.mainAudioRingConnectedStroke
        return ring
    }()
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
    private var isMasterMuted = false
    /// Whether the Main Audio spine is LIVE — the continuous rail overlay reads
    /// this to tone the origin hook AND the member segments below it, gold vs
    /// ember. Live = the armed target (connected ∧ unmuted) **or** the
    /// local-only `restingArmed` case, where audio genuinely plays through the
    /// Mac and no remote handshake exists for `connectionState` to report. Both
    /// carry real audio to a member node, so both must read live: the hook's
    /// corner and the rail leaving it are one stroke, and a truth that covers
    /// only the remote case draws them in two tones.
    private var isSpineLive = false
    /// The System Audio row's item title — **"Main Audio"** (Warm Signal v4
    /// §Call-1), filling the shared name column so it aligns
    /// with the device rows below.
    private let nameLabel = NSTextField(labelWithString: "Main Audio")
    /// The name cluster: **name over meter**, exactly the device-row anatomy
    /// (Warm Signal v4.1 CORRECTIONS, item 1). Left-aligned,
    /// vertically centred in the row; the stack recentres its visible lines,
    /// so no manual name-offset juggling is needed when the meter shows/hides.
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
    /// The membership bus's **origin marker** (Warm Signal v4.1 CORRECTIONS,
    /// item 2): sits at the SAME left-gutter column (`railGutterCenterX`)
    /// the device rows below centre their own bus node on, spanning the row's
    /// full height like a device row's bus column — a clean gutter origin
    /// point that never crosses the icon and never fuses into the meter. It
    /// draws no node of its own (`.origin` is a no-draw state in
    /// `MembershipBusView`); `BusRailOverlayView` reads its live frame (via
    /// `railHookAnchor`) to place the small origin dot and drop the spine.
    /// Rendered in the dormant de-emphasis tint only while the checked set
    /// genuinely DIVERGES from an active group target (spec §4.7 FINAL, S5 —
    /// the derived-identity case keeps full ink; the host resolves it via
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
    /// current target. `master` is Main Out's own stored gain — NOT an average of
    /// the target's members.
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
    /// `restingArmed` (ring-resting-state task) is the host-computed bit
    /// deciding the ring's `.resting` form: true iff the active target's
    /// members are all the local device (non-empty) and unmuted — the
    /// local-only-playback case where a genuine AirPlay handshake never
    /// happens, so `connectionState` correctly falls through to `.off`
    /// (`PopoverController.mainOutConnectionState` is untouched) but the
    /// rail's curve into the ring still needs something to land on. Defaults
    /// to `false` (legacy callers/tests render exactly as before).
    public func apply(options: [Option], current: MainOutTarget, master: Int, isMuted: Bool = false,
                      connectionState: ConnectionState = .off,
                      restingArmed: Bool = false,
                      busOriginDimmed: Bool? = nil) {
        self.options = options
        isMasterMuted = isMuted
        muteButton.state = isMuted ? .on : .off
        updateMuteTint()
        haloRingView.apply(connectionState, restingArmed: restingArmed)

        // Route-armed dot (spec §3.3, Main Out variant): armed = the active
        // target has ≥1 CONNECTED member (the aggregate ring state, which
        // already implies a non-empty target set) ∧ master unmuted. Pure model
        // state — never RMS.
        let isConnected: Bool
        if case .connected = connectionState { isConnected = true } else { isConnected = false }
        let armed = isConnected && !isMuted
        isSpineLive = armed || restingArmed
        // The ring's CONNECTED stroke wears the rail's own SPINE TONE (Warm
        // Signal nitpicks, "rail into the ring"), so the join reads as one
        // continuous line, not a gold line touching a hue-neutral ring. The
        // row hands over the armed STATE only — `HaloRingView` resolves the
        // tone through the same `Tokens.Color.spineTone` the rail overlay
        // uses, at stamp time, so the two cannot drift and the accent dial
        // moves both.
        haloRingView.connectedSpineArmed = armed
        armedDotView.apply(armed: armed)
        // The master fader's engaged (gold) fill reuses the EXACT same armed
        // predicate the dot renders — one armed truth, two instruments.
        faderCell.isRouteArmed = armed
        // The readout agrees with the fill beside it: gold while the master is
        // actually sounding, ember while it only holds a stored level.
        readoutLabel.textColor = armed ? Tokens.Color.goldText : Tokens.Color.emberText
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
        groupGlowView.isHidden = !isGroupTarget

        let menu = destinationPopUp.menu ?? NSMenu()
        menu.removeAllItems()
        selectedTitle = nil
        var currentItem: NSMenuItem?
        var currentButtonTitle: String?
        var sawHeader = false
        for option in options {
            if option.isHeader {
                sawHeader = true
                // A rule above every section but the first, then AppKit's own
                // section header — see the same pair in `AppRowView.addHeader`
                // for why a hand-disabled item cannot stand in for it here.
                if let last = menu.items.last, !last.isSeparatorItem {
                    menu.addItem(.separator())
                }
                menu.addItem(.sectionHeader(title: option.title))
                continue
            }
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            // One step in from the section header above it — see
            // `AppRowView.addEntries` for why the indentation is there and what
            // it trades away. An entry ahead of any header stays flush.
            item.indentationLevel = sawHeader ? 1 : 0
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
            menu.addItem(item)
        }
        destinationPopUp.menu = menu
        // Show the currently selected target as the button's visible title
        // (SoundSource-style named dropdown, task B). The pop-up truncates a long
        // title with a tail ellipsis via its fixed max width + cell line break.
        if let currentItem { destinationPopUp.select(currentItem) }
        // The collapsed button always draws a display-only cell item, never the
        // selected menu item: the item's attributed title pins the words to
        // `label` ink. It also carries a distinct `buttonTitle` when an option
        // sets one, while the open menu keeps the full `title`. Re-set every
        // `apply` so a later selection without an override reverts.
        //
        // The paragraph style is load-bearing: an `attributedTitle` makes the
        // cell ignore its own `lineBreakMode`, so without it a long group name
        // clips mid-word instead of taking the tail ellipsis.
        if let cell = destinationPopUp.cell as? NSPopUpButtonCell {
            let shownTitle = currentButtonTitle ?? selectedTitle ?? ""
            cell.usesItemFromMenu = false
            let displayItem = NSMenuItem(title: shownTitle, action: nil, keyEquivalent: "")
            let truncating = NSMutableParagraphStyle()
            truncating.lineBreakMode = .byTruncatingTail
            displayItem.attributedTitle = NSAttributedString(
                string: shownTitle,
                attributes: [.font: Tokens.Font.caption,
                             .foregroundColor: Tokens.Color.label,
                             .paragraphStyle: truncating])
            cell.menuItem = displayItem
        }

        // The readout is guarded WITH the thumb, not separately: the two show the
        // same number, so letting a master move from elsewhere (the phone, T7)
        // land on the label alone would print that value under the finger still
        // dragging the slider. `masterChanged` keeps the label live during the
        // drag from the drag's own value.
        if !isDraggingMaster {
            slider.integerValue = master
            readoutLabel.stringValue = VolumePercent.label(master)
        }
        configureAccessibility()
    }

    /// Push a live RMS reading to the master meter (task T4a). Main Out shares
    /// the same level feed as the device rows for now. While the master is
    /// muted (S3) an incoming push is coerced to 0 so a straggling RMS event
    /// can never refill the drained master meter.
    public func setLevel(_ rms: Float) {
        meterView.setLevel(isMasterMuted ? 0 : rms)
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
        // One definition of the Main Audio glyph, shared with the Groups
        // screen's Main Audio page: `DeviceIcon.mainAudioSymbolName` owns the
        // owner's `hifispeaker.arrow.forward.fill` and its below-macOS-15
        // fallback, so the two surfaces can never draw different speakers.
        // Match the device rows' glyph sizing (2026-07-17): size the symbol to
        // fill the shared 26pt icon box so the Main Out icon reads at the same
        // scale as the device icons below it (without a config it renders at the
        // small default size and floats in a big box).
        let iconConfig = NSImage.SymbolConfiguration(pointSize: PopoverColumnGrid.iconGlyphPointSize,
                                                     weight: .regular)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.image = NSImage(systemSymbolName: DeviceIcon.mainAudioSymbolName,
                                 accessibilityDescription: "Main Audio")?
            .withSymbolConfiguration(iconConfig)
        // The icon is the visible door to this row's menu. Main Audio always
        // has an Equalizer, so unlike a device row it is armed once, here, and
        // never disarmed.
        iconView.onPress = { [weak self] in self?.presentIconMenu() }
        iconView.setAccessibilityLabel("Main Audio options")
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
        // still toggles and the delegate still fires, while the SYMBOL swaps
        // between its outline and filled squares. The mark used to stay fixed
        // in both states (an earlier call); they reversed that on 2026-09-04 — a
        // mute that changes nothing but its tint reads as no mute at all. This
        // is only the seeded image; `updateMuteTint()` owns both states and
        // re-makes it on every appearance change.
        muteButton.translatesAutoresizingMaskIntoConstraints = false
        muteButton.setButtonType(.pushOnPushOff)
        muteButton.isBordered = false
        muteButton.imagePosition = .imageOnly
        // Unscaled — see ``RowAccessorySymbol/pointSize``.
        muteButton.imageScaling = .scaleNone
        muteButton.image = RowAccessorySymbol.image(
            named: RowAccessorySymbol.muteRest,
            ink: Tokens.Color.label2)
        muteButton.target = self
        muteButton.action = #selector(muteToggled(_:))
        muteButton.setContentHuggingPriority(.required, for: .horizontal)

        readoutLabel.translatesAutoresizingMaskIntoConstraints = false
        readoutLabel.font = Tokens.Font.readout
        readoutLabel.textColor = Tokens.Color.emberText
        readoutLabel.alignment = .right
        readoutLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Named SoundSource-style destination dropdown (task B): a real
        // `NSPopUpButton` (`pullsDown = false`, SPEC §9 "choosing one from a set,
        // shows the current selection"). Its title is the current target, tail-
        // truncated. It carries the same two-section menu populated in `apply`.
        destinationPopUp.translatesAutoresizingMaskIntoConstraints = false
        destinationPopUp.pullsDown = false
        // Bordered, always: a borderless `NSButton` silently discards
        // `drawFocusRingMask`, so keyboard focus on this control would become
        // invisible (the same trap `AlignmentPlateButton` documents). Going
        // borderless was also the only way to tint the arrow — the bezel draws
        // it — so the arrow stays neutral and the group's magenta is carried
        // by the identity glow and the "→ <group>" title instead.
        destinationPopUp.isBordered = true
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

        // Name cluster (v4.1 CORRECTIONS, item 1: name over meter, the
        // device-row anatomy).
        identityStack.translatesAutoresizingMaskIntoConstraints = false
        identityStack.orientation = .vertical
        identityStack.alignment = .leading
        identityStack.spacing = 2
        identityStack.distribution = .fill
        identityStack.addArrangedSubview(nameLabel)
        identityStack.addArrangedSubview(meterView)

        groupGlowView.translatesAutoresizingMaskIntoConstraints = false
        groupGlowView.isHidden = true
        addSubview(groupGlowView)
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
            // The glow is bigger than the 44 pt row, so the row's layer clips
            // 8 pt off its top and bottom — accepted: the leak reads sideways.
            groupGlowView.widthAnchor.constraint(equalToConstant: GroupIdentityGlowView.side),
            groupGlowView.heightAnchor.constraint(equalToConstant: GroupIdentityGlowView.side),
            groupGlowView.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            groupGlowView.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            // Connection halo ring: a box GROWN past the icon box (Warm Signal
            // nitpicks — `mainAudioRingHostBoxDiameter`, the BESPOKE terminus
            // sizing, not the shared `haloRingHostBoxDiameter` device rows
            // use), still centered on it, so the ring floats a breathing-room
            // gap off the glyph without shifting the icon/name/fader column
            // alignment.
            haloRingView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.mainAudioRingHostBoxDiameter),
            haloRingView.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.mainAudioRingHostBoxDiameter),
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

            // Identity cluster ("Main Audio" over the under-name meter, the
            // device-row anatomy — Warm Signal v4.1 CORRECTIONS item 1),
            // centred as a group; yields to the mute glyph so the name
            // truncates. The meter is an arranged subview of this stack (added
            // in `buildSubviews`), so it inherits the SAME position + geometry
            // a device meter gets under its device name — only its own
            // width/height below (thicker: `masterMeterThickness`) differ.
            identityStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                                    constant: PopoverColumnGrid.iconToName),
            identityStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            identityStack.trailingAnchor.constraint(lessThanOrEqualTo: muteButton.leadingAnchor,
                                                    constant: -PopoverColumnGrid.nameToSlider),

            // Master meter's fixed size (v4.1 CORRECTIONS item 1): same LENGTH
            // as a device meter (`meterUnderNameWidth`) but thicker
            // (`masterMeterThickness`, wired via the `LevelMeterView(thickness:)`
            // init above) — thickness alone signifies "master bus." No
            // separate leading/bottom anchors — the stack positions it, exactly
            // like `DeviceRowView` positions its own under-name meter.
            meterView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.meterUnderNameWidth),
            meterView.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.masterMeterThickness),

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

            // Bus origin marker (Warm Signal v4.1 CORRECTIONS, item 2): centred
            // on `railGutterCenterX` in the LEFT gutter, spanning the full row
            // height, exactly like a device row centres its own bus node/column
            // — a clean gutter origin point that never crosses the icon and
            // never reaches into the meter (which sits under the name,
            // clear of the gutter). `MembershipBusView.origin` draws no node
            // of its own; `BusRailOverlayView` reads this view's live frame
            // (via `railHookAnchor`) to place the small origin dot and drop
            // the spine from there.
            busOriginView.centerXAnchor.constraint(
                equalTo: leadingAnchor, constant: PopoverColumnGrid.railGutterCenterX),
            busOriginView.centerYAnchor.constraint(equalTo: centerYAnchor),
            busOriginView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.busColumnWidth),
            busOriginView.heightAnchor.constraint(equalTo: heightAnchor),
        ])
    }

    // MARK: Private Helpers

    /// Updates the mute button for the current state: `.on` draws
    /// ``RowAccessorySymbol/muteEngaged``, the filled square with a
    /// ``Tokens/Color/muted`` enclosure and the marks punched out of it;
    /// `.off` draws
    /// ``RowAccessorySymbol/muteRest``, the outline square in one neutral ink.
    /// Drawing only — behavior, keyboard and VoiceOver untouched. The SAME two
    /// symbols every device row below wears, so the two rows cannot present
    /// one state as two different objects.
    private func updateMuteTint() {
        let engaged = muteButton.state == .on
        // One shape, two inks — see `DeviceRowView.updateMuteTint()`.
        muteButton.image = RowAccessorySymbol.image(
            named: RowAccessorySymbol.muteRest,
            ink: engaged ? Self.engagedInk(in: effectiveAppearance)
                         : Self.restInk(in: effectiveAppearance))
        configureAccessibility()
    }

    /// ``Tokens/Color/muted`` on the enclosing square, the marks punched
    /// through it as transparency. Resolved in this row's own appearance,
    /// because a dynamic `NSColor` would otherwise resolve against whichever
    /// appearance is current when the image is composited.
    private static func engagedInk(in appearance: NSAppearance) -> NSColor {
        var fill = Tokens.Color.muted
        appearance.performAsCurrentDrawingAppearance {
            fill = Tokens.Color.muted.usingColorSpace(.sRGB) ?? fill
        }
        return fill
    }

    /// One neutral ink over the whole outline square.
    private static func restInk(in appearance: NSAppearance) -> NSColor {
        var ink = Tokens.Color.label
        appearance.performAsCurrentDrawingAppearance {
            ink = Tokens.Color.label.usingColorSpace(.sRGB) ?? ink
        }
        return ink
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
        isMasterMuted = sender.state == .on
        updateMuteTint()
        delegate?.mainOutRow(self, didSetMuted: sender.state == .on)
    }

    @objc private func masterChanged(_ sender: NSSlider) {
        // `isDraggingMaster` exists so `apply(...)` won't yank the thumb out from
        // under a live MOUSE drag. Set it from whether a drag is actually in flight,
        // NOT "set on first change, clear only on .leftMouseUp": a keyboard or
        // VoiceOver change arrives as a single event that is never a `.leftMouseUp`,
        // so the old logic set the flag and never cleared it — the thumb then stopped
        // tracking the model forever (stability-audit-2026-07-18 §D4). A keyboard
        // change has no drag in flight, so it leaves the flag false and repaints stay
        // live.
        switch NSApp?.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged:
            isDraggingMaster = true
        default:
            isDraggingMaster = false
        }
        delegate?.mainOutRow(self, didSetMaster: sender.integerValue)
        readoutLabel.stringValue = VolumePercent.label(sender.integerValue)
    }

    // The Main Out row lives INSIDE the System card (T-U8), so it paints no fill
    // of its own — the card provides the module surface.

    // MARK: Accessibility

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Main Audio, master volume \(VolumePercent.spoken(slider.integerValue))")
        // The row's VALUE carries the live signal channels (S2/S3): "muted"
        // for the engaged master-mute pill, "armed" for the lit route-armed
        // dot — the spoken equivalents shipped with the drawing.
        var valueParts: [String] = []
        if isMasterMuted { valueParts.append("muted") }
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
    /// The master percentage the READOUT prints — a separate surface from the
    /// thumb, and the one an off-Mac master move used to overwrite mid-drag.
    public var test_masterReadout: String { readoutLabel.stringValue }
    /// The readout's current ink — gold while the master sounds, ember at rest.
    public var test_masterReadoutColor: NSColor? { readoutLabel.textColor }
    /// The readout's current face.
    public var test_masterReadoutFont: NSFont? { readoutLabel.font }
    /// The attributed string the collapsed pop-up actually renders — pins the
    /// ink and the truncation the plain title cannot show.
    public var test_buttonAttributedTitle: NSAttributedString? {
        (destinationPopUp.cell as? NSPopUpButtonCell)?.menuItem?.attributedTitle
    }
    /// Whether the group identity glow is lit behind the icon.
    public var test_groupGlowVisible: Bool { !groupGlowView.isHidden }
    /// Force the live-drag guard, so tests can pin what `apply(...)` may touch
    /// while the user's finger is down. There is no other way in: the flag is set
    /// from `NSApp.currentEvent`, which is always nil under `swift test`.
    public var test_isDraggingMaster: Bool {
        get { isDraggingMaster }
        set { isDraggingMaster = newValue }
    }
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
    /// The ring's currently STAMPED stroke color (the `CGColor` actually on the
    /// layer) — the ring/rail tone-coupling lock reads this so it compares the
    /// drawn ink, not a re-derived token.
    public var test_ringStrokeColor: NSColor? { haloRingView.test_strokeColor }

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
    /// Whether the master-mute button is drawing its ENGAGED symbol — a
    /// raster comparison against the same symbol built from the same ink,
    /// so the hook reads the drawn image rather than a flag.
    public var test_isMutePillEngaged: Bool {
        guard muteButton.state == .on,
              let drawn = muteButton.image?.tiffRepresentation,
              let reference = RowAccessorySymbol.image(
                named: RowAccessorySymbol.muteRest,
                ink: Self.engagedInk(in: effectiveAppearance))?.tiffRepresentation
        else { return false }
        return drawn == reference
    }
    /// The mute mark's frame — the button, which is the mark now, so a test
    /// can pin this row's control to the same size the device rows below draw.
    public var test_muteSeatFrame: NSRect {
        layoutSubtreeIfNeeded()
        return muteButton.frame
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
        delegate?.mainOutRow(self, didSetMaster: value)
    }

    /// The row's context menu exactly as `menu(for:)` builds it. Tests
    /// dispatch items via `performActionForItem(at:)` (real AppKit menu
    /// dispatch), never the delegate shortcut.
    public func test_contextMenu() -> NSMenu { buildContextMenu() }

    /// A click on the row ICON, through the same builder the live click uses.
    public func test_clickIcon() -> NSMenu? { presentIconMenu() }

    /// The icon's spoken identity as a menu button.
    public var test_iconAXLabel: String? { iconView.accessibilityLabel() }

    // MARK: Context menu — the Equalizer door
    //
    // The device rows' idiom, one item shorter: Main Audio has tone but no
    // Bluetooth alignment. Two ways in, one builder — a right-click anywhere
    // the subviews don't claim (AppKit's `menu(for:)`, so VoiceOver's "show
    // menu" shares the path), and a click on the icon.

    public override func menu(for event: NSEvent) -> NSMenu? {
        buildContextMenu()
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let eq = NSMenuItem(title: "Equalizer…",
                            action: #selector(equalizerMenuItemSelected(_:)),
                            keyEquivalent: "")
        eq.target = self
        menu.addItem(eq)
        return menu
    }

    /// The on-screen `popUp` BLOCKS, so it is `HeadlessRuntime`-gated exactly
    /// like the popover's "+" menu; the built menu is returned either way so
    /// tests dispatch against the very menu a user would see.
    @discardableResult
    private func presentIconMenu() -> NSMenu? {
        let menu = buildContextMenu()
        if !HeadlessRuntime.isActive {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: iconView)
        }
        return menu
    }

    @objc private func equalizerMenuItemSelected(_ sender: NSMenuItem) {
        delegate?.mainOutRowDidRequestEqualizer(self)
    }

    /// A pointing hand over the icon, matching the device rows: the icon is a
    /// door, so it has to look like one.
    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(convert(iconView.bounds, from: iconView), cursor: .pointingHand)
    }
}

// MARK: - Delegate defaults

public extension MainOutRowView.Delegate {
    /// Default no-op — only the popover can deep-link to the Groups screen's
    /// Main Audio page.
    func mainOutRowDidRequestEqualizer(_ row: MainOutRowView) {}
}

// MARK: - Continuous rail origin hook (Warm Signal v4 §Call-1)

extension MainOutRowView: RailHookProviding {
    /// The Main Audio ring's own geometry (Warm Signal nitpicks — "rail into
    /// the ring"): the icon's centre, converted into `view`'s coordinates,
    /// plus the ring's radius (a distance, unaffected by the sibling-view
    /// coordinate conversion) and whether the spine is armed (gold vs ember).
    /// The overlay curves the rail up to meet this ring's left edge directly,
    /// replacing the old bare gutter-dot terminus.
    public func railHookAnchor(in view: NSView) -> (centerY: CGFloat, ringCenterX: CGFloat, ringRadius: CGFloat, gold: Bool)? {
        layoutSubtreeIfNeeded()
        let iconRectInSelf = iconView.convert(iconView.bounds, to: self)
        let iconCenter = convert(NSPoint(x: iconRectInSelf.midX, y: iconRectInSelf.midY), to: view)
        return (iconCenter.y, iconCenter.x, PopoverColumnGrid.mainAudioRingDiameter / 2, isSpineLive)
    }

    /// The rail's bead landed on this row's ring — forward it to the ring, which
    /// owns the bloom (and its Reduce Motion / settled-model contract).
    public func receiveRailPulse() {
        haloRingView.receiveRailPulse()
    }
}
