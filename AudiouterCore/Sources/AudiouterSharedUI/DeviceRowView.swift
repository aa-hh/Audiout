// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// A single device's controls (SPEC §9 "Device row"), shared by BOTH the
/// menu-bar extra's popover dropdown and the full mixer window (both host it in
/// an `NSStackView`). This is the "same row component" the SPEC and
/// PLAN-PHASE-1 §D call for — one implementation, one test surface, identical
/// behaviour in both hosts.
///
/// The row's PRIMARY control is a "Selected Devices" membership `NSButton`
/// checkbox (SPEC §9 routing model); volume and a small secondary mute button
/// follow.
///
/// It lives in `AudiouterSharedUI` (not the popover target) so the
/// window target can link it without pulling in the whole dropdown; both
/// `PopoverController` (the popover) is its host (the window's mixer pane was retired 2026-07-18).
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
        /// The user clicked the BODY of a row whose membership toggle is BLOCKED
        /// (the Phase-1 local-mix block, spec §4.6). The host surfaces the
        /// in-place refusal note (from `GroupController.localMixRefusalReason`) —
        /// the reachable trigger that a disabled control + tooltip alone lacked
        /// (resolves the significant break §8.5). Default no-op so non-bus hosts
        /// (mixer window, tests) are unaffected.
        func deviceRowDidRequestBlockedExplanation(_ row: DeviceRowView)
    }

    /// Control-Center row density: comfortable height that seats a mini switch,
    /// icon, a two-line name/status stack, CC slider and mute button with
    /// breathing room in a card (CC rows read ~34–40pt; 38 landed in that band
    /// before the status sublabel — brief §6 sanctions bumping this constant
    /// once a second text line needs the room, which it does: two 10pt lines
    /// plus their line gap don't fit 38pt without crowding the slider/switch).
    /// Now sourced from `PopoverColumnGrid.bodyRowHeight` (2026-07-18 unification
    /// with `AppRowView`'s row height) rather than a private literal — both row
    /// types share one body-row dimension.
    public static let rowHeight: CGFloat = PopoverColumnGrid.bodyRowHeight

    // (See `DeviceRowView.Delegate` extension at file end for the
    // `didToggleEnabled` default no-op.)

    /// Which connection **halo ring** the row is currently showing — a structural
    /// test hook (`test_statusKind`/`test_ringForm`) so tests can assert the ring
    /// without reaching into the private ring subview. The four states map
    /// directly off `Device.connectionState` (Warm Signal v3 §3.2).
    public enum StatusKind: Equatable {
        /// `.off` — no ring.
        case none
        /// `.connecting` / `.reconnecting` — the dashed breathing ring.
        case connecting
        /// `.connected` — the solid `ringConnected` ring.
        case connected
        /// `.failed` — the solid red `failure` ring.
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
    /// (the Mac can't join a mixed set) — the checkbox is greyed with a tooltip.
    private var isToggleBlocked: Bool = false

    /// The refusal reason accompanying `isToggleBlocked` (spec §4.6), held so the
    /// row can speak it: it rides the row's accessibility HINT (the VoiceOver
    /// equivalent of the body-click refusal note — every visual state ships its
    /// spoken counterpart) as well as the checkbox tooltip. `nil` when not blocked.
    private var blockReasonText: String?

    /// Transient pointer-hover state (menu-less hosts). Kept SEPARATE from the
    /// model `isSelectedInSet` and always reset in ``apply(_:selected:…)`` and on
    /// re-parenting, so a hover can never "stick" as a stale highlight after the
    /// pointer leaves the popover without a matching `mouseExited` (T-U8 bug).
    private var isHovered: Bool = false

    /// The PRIMARY "Selected Devices" membership control (SPEC §9b device-row
    /// toggle). An `NSButton` **checkbox** (`.switch` button type, empty title)
    /// under the "Selected" column header. `.state` is `.on`/`.off`, identical
    /// semantics to the mini switch it replaced — membership in the Selected
    /// Devices set. Named `enableCheckbox`; centered on the trailing-control
    /// column via the shared grid.
    private let enableCheckbox = NSButton()
    /// The **membership bus** node + rail overlay (spec §4), mounted only when
    /// `showsBus` — the drawing-only skin over `enableCheckbox`, which is made
    /// invisible-but-fully-functional (a no-op-drawing cell) underneath it. See
    /// ``MembershipBusView``.
    private let busView = MembershipBusView()
    /// Whether this row draws the membership BUS in place of the checkbox's own
    /// switch drawing (spec §4). The popover's Selected-Devices rows pass `true`;
    /// the mixer window / group-member rows leave it `false` so their rendering is
    /// byte-for-byte unchanged (the checkbox draws its normal switch).
    private let showsBus: Bool
    /// Whether the bus is actually mounted on THIS row: `showsBus` hosts only.
    /// A `showsToggle == false` row (a group-member row — membership is fixed
    /// there) keeps **no bus node** even under a bus host (spec §4.6/§3.6 "Group
    /// member … showsToggle=false rows carry no membership control"), so the bus
    /// never claims a membership the row can't toggle.
    private var busActive: Bool { showsBus && showsToggle }
    /// This row's rail extent (Warm Signal v4 §Call-1) — set by the host via
    /// ``setBusRail(above:below:)`` so the rail runs Main Audio → the LOWEST
    /// SELECTED node and rows below it render BARE (no rail). Structural, not
    /// per-device, so it survives an in-place `apply` repaint. Defaults to a
    /// full through-rail; the host narrows it per its position in the spine.
    private var busRailAbove = true
    private var busRailBelow = true
    /// The current dormant-divergent tint state of the bus node (spec §4.7) —
    /// mirrors `selectionDimmed` for a bus row, where dimming is a node TINT, not
    /// the checkbox alpha (§4.7 "dim via tint … checkbox at full alpha").
    private var busNodeDimmed = false
    private let iconView = NSImageView()
    /// The connection **halo ring** (Warm Signal v3 §3.2, 2026-07-22): a ring
    /// drawn AROUND the icon carrying the connection lifecycle, driven off
    /// `device.connectionState` alone (teal retired — no routing rung on the
    /// ring). Replaced the retired corner connection dot (`StatusDotView`,
    /// deleted). The icon's corner is repurposed for the gold route-armed dot in
    /// a later task (§3.3). See ``HaloRingView``.
    private let haloRingView = HaloRingView()
    /// The **gold route-armed corner dot** (Warm Signal v3 §3.3, S2) at the
    /// icon's bottom-right — the position the retired connection dot vacated.
    /// PURE MODEL STATE, never RMS: lit iff the §3.3 predicate holds (see
    /// `routeArmed(...)` in ``apply``); dark/empty socket otherwise. Paused
    /// and playing render identically here (R3 — only the meter differs).
    private let armedDotView = RouteArmedDotView()
    /// Whether the MASTER (Main Out) mute is currently engaged — folded into
    /// the route-armed predicate (spec §3.3: master mute drains EVERY device
    /// dot) and into the meter's mute-coerce gate. Host-supplied via `apply`.
    private var isMasterMuted = false
    /// Whether the row's live-feed set (`liveAppNames`) was non-empty at the
    /// last `apply` — picks the "playing here" vs "armed" VoiceOver wording.
    private var hasLiveFeeds = false
    /// The armed predicate's last computed value (what the dot renders).
    private var isRouteArmed = false
    private let nameLabel = NSTextField(labelWithString: "")
    /// The single sublabel line under the name, driven by a precedence ladder in
    /// ``resolveSublabel(routedAppNames:)``: `.failed` → "Couldn't connect"
    /// (`failure` red); unavailable → "Unavailable" (greyed); else a non-empty
    /// routing set → the routing line ("System · <apps>"); else hidden (the row is
    /// single-line, name centered). All three sublabel kinds reuse this one label.
    private let statusLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    /// The Warm Signal fader skin over `slider` (drawing-only `NSSliderCell`
    /// swap — behavior/keyboard/VoiceOver stay stock): recessed `well` trough,
    /// gold `ember → gold` fill iff the row is route-armed (the same §3.3
    /// predicate the corner dot renders), rounded-rect `raised` thumb. See
    /// ``WarmFaderCell``.
    private let faderCell = WarmFaderCell()
    /// Small right-aligned `%` readout sitting immediately right of the slider
    /// (change 4 — a device row now shows its volume number too, tight against
    /// the slider like the Main Out row, on the same shared column).
    private let readoutLabel = NSTextField(labelWithString: "")
    private let muteButton = NSButton()

    /// The under-name VU meter (Warm Signal v4 §Call-1), mounted inside the
    /// identity stack only when `showsMeter` — the mixer window and
    /// `GroupRowView` leave it out. Shown (un-hidden) only on armed rows. See
    /// ``LevelMeterView``.
    private let meterView = LevelMeterView()

    /// The vertical identity cluster (Warm Signal v4 §Call-1): row order
    /// **name / meter / sublabel**, left-aligned, centred vertically on the row
    /// as a group. `meterView` (when `showsMeter`) and `statusLabel` toggle their
    /// `isHidden` so the stack recentres the visible lines automatically — this
    /// replaces the old manual `nameCenterYConstraint` half-line juggling.
    private let identityStack = NSStackView()
    /// Whether the leading VU meter column is shown. Defaults to `false` so
    /// the mixer window's existing layout is untouched; only the popover's
    /// Selected Devices rows and Main Out pass `true`.
    private let showsMeter: Bool
    /// The most recently pushed meter level, for ``test_meterLevel()``. `0`
    /// when there's no meter or after a ``LevelMeterView/reset()``.
    private var lastMeterLevel: Float = 0

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
    /// Selected Devices set. The popover (2026-07-14 — ahh: no longer needed,
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
               paintsSelectionBackground: Bool = true, showsMeter: Bool = false,
               showsBus: Bool = false) {
        self.device = device
        self.indented = indented
        self.showsToggle = showsToggle
        self.paintsSelectionBackground = paintsSelectionBackground
        self.showsMeter = showsMeter
        self.showsBus = showsBus
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
    ///   - controllable: enables the volume slider + mute independently of set
    ///     membership (a redirect-only device is controllable but not selected).
    ///     Defaults to `false` — the caller must pass `selected || isRedirectTarget`
    ///     to keep a plain selected device's slider/mute enabled; the default is a
    ///     back-compat footgun for callers that omit it entirely.
    ///   - blocked: whether the membership toggle should be disabled (Phase-1
    ///     local-mix block) — greyed with `blockReason` as a tooltip.
    ///   - blockReason: tooltip text shown when `blocked` is true.
    ///   - selectionDimmed: dims the "Selected Devices" checkbox (alpha ~0.4)
    ///     without disabling it — DECISION: a dimmed row's checkbox stays fully
    ///     interactive; this is a visual de-emphasis only (e.g. a filtered/greyed
    ///     list context), never a disablement. Defaults to `false` so existing
    ///     callers are unaffected.
    ///   - routedAppNames: the bypassed-app display names routed to THIS device
    ///     (the routing set's app tokens only, in stable route order). Does NOT
    ///     include the "System" token — the view synthesizes "System" itself from
    ///     `selected`. This is INTENT (config), not a playback claim — see
    ///     `liveAppNames` below for the confirmed signal. Drives the routing
    ///     sublabel (see the precedence ladder in
    ///     ``resolveSublabel(routedAppNames:liveAppNames:)``).
    ///   - liveAppNames: the app display names CONFIRMED currently streaming to
    ///     THIS device right now (T9 — `BackendEvent.routedApps`, the live
    ///     per-device signal, not just routing intent). When non-empty this
    ///     TAKES PRECEDENCE over `routedAppNames` in the routing sublabel — it's
    ///     the "confirmed" state, so it wins over what's merely configured.
    ///     When empty (nothing confirmed streaming yet — e.g. still connecting,
    ///     or no live backend), the sublabel falls back to `routedAppNames` so
    ///     the row isn't blank while a redirect is pending. Only `NativeBackend`
    ///     ever populates this; `MockBackend`/`OwnToneBackend` leave it empty
    ///     unless a test/demo explicitly injects it.
    ///   - masterMuted: whether the Main Out MASTER mute is engaged (spec
    ///     §3.3): folded into the route-armed predicate so master mute drains
    ///     every device dot — no "four gold lamps on a silent house". Defaults
    ///     to `false` so existing callers are unchanged.
    ///   - inActiveTarget: whether this device is a member of the **active
    ///     Main Out target set** (the Selected Devices set when Main Out =
    ///     Selected Devices, or the routed group's member set when Main Out =
    ///     a saved group — spec §3.3 "membership is evaluated against the
    ///     active target, not the Selected set"). `nil` (every existing
    ///     caller) falls back to `selected`, which is exactly right whenever
    ///     Main Out targets Selected Devices.
    ///   - iconSymbolName: an explicit SF Symbol name override for the icon
    ///     glyph, resolved through ``DeviceIcon/resolve(_:default:)`` (so an
    ///     unknown/invalid name falls back to `device.kind.symbolName`).
    ///     Defaults to `nil`, in which case the row behaves exactly as before —
    ///     `device.kind.symbolName` is used directly. Existing callers all omit
    ///     this, so their behavior is byte-for-byte unchanged.
    public func apply(_ device: Device,
                      selected: Bool,
                      controllable: Bool = false,
                      blocked: Bool = false,
                      blockReason: String? = nil,
                      selectionDimmed: Bool = false,
                      routedAppNames: [String] = [],
                      liveAppNames: [String] = [],
                      masterMuted: Bool = false,
                      inActiveTarget: Bool? = nil,
                      iconSymbolName: String? = nil) {
        self.device = device
        self.isSelectedInSet = selected
        self.isToggleBlocked = blocked
        self.blockReasonText = blocked ? blockReason : nil
        // Any model refresh (select OR deselect) clears a transient hover so the
        // row can't keep a stale hover wash after the pointer left the popover
        // (T-U8 root-cause fix — hover is transient, selection is model-driven).
        self.isHovered = false

        // Primary membership control: ON iff the device is in the Selected
        // Devices set. Don't fight a live toggle animation. Group-member rows
        // hide the toggle entirely (task C) — membership there is fixed.
        enableCheckbox.state = selected ? .on : .off
        enableCheckbox.isEnabled = showsToggle && device.isAvailable && !blocked
        enableCheckbox.toolTip = (showsToggle && blocked) ? blockReason : nil
        // A1: dim, don't disable — `isEnabled` above is untouched by
        // `selectionDimmed`, only the alpha is. EXCEPTION for bus rows (spec §4.7):
        // dimming is a NODE TINT, not the checkbox alpha ("dim via tint … checkbox
        // at full alpha"), so a bus checkbox stays at alpha 1 and the tint rides on
        // `busNodeDimmed` below instead.
        enableCheckbox.alphaValue = (busActive || !selectionDimmed) ? 1.0 : Self.selectionDimmedAlpha
        busNodeDimmed = busActive && selectionDimmed

        // `nil` (every existing caller) resolves straight to the kind default —
        // `DeviceIcon.resolve` short-circuits on a `nil` override — so behavior
        // is unchanged unless a caller passes an explicit override name.
        let resolvedSymbolName = DeviceIcon.resolve(iconSymbolName, default: device.kind.symbolName)
        iconView.image = NSImage(
            systemSymbolName: resolvedSymbolName,
            accessibilityDescription: device.name
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: PopoverColumnGrid.iconGlyphPointSize,
                                        weight: .regular)
        )
        // The icon is ALWAYS neutral now (2026-07-17): identity only, no
        // accent-when-selected fill. Selection reads from the switch state; the
        // on-icon corner dot carries the connection status instead. (This also
        // covers unsupported/AP1 rows — no accent regardless of stale selection.)
        iconView.contentTintColor = Tokens.Color.secondaryLabel
        nameLabel.stringValue = device.name
        nameLabel.textColor = rowTextColor
        alphaValue = 1.0

        // Connection halo ring: driven off `connectionState` ALONE (spec §3.2 /
        // §3.1 — the ring is the connection channel; teal is retired, so a live
        // per-app redirect no longer tints the ring). A redirect-only device
        // reads via its gold route-armed dot + sublabel + bus node, never the
        // ring. `liveAppNames` still feeds the routing sublabel below.
        haloRingView.apply(device.connectionState)

        // Route-armed corner dot (spec §3.3) — the normative predicate,
        // PURE MODEL STATE, NEVER RMS (R3: paused == playing == fresh open;
        // only the meter may differ):
        //
        //   routeArmed = ( inActiveTarget ∧ connected ∧ !rowMuted ∧ !masterMuted )
        //              ∨ ( liveAppNames ≠ ∅ )
        //
        // The per-app `liveAppNames` branch is independent of both mutes
        // (redirect streams bypass the main-out master). Membership is against
        // the ACTIVE target (host-supplied `inActiveTarget`), so a playing
        // group member lights its dot even while its Selected checkbox dims.
        self.isMasterMuted = masterMuted
        self.hasLiveFeeds = !liveAppNames.isEmpty
        let activeMember = inActiveTarget ?? selected
        let isConnected: Bool
        if case .connected = device.connectionState { isConnected = true } else { isConnected = false }
        let mainMixArmed = activeMember && isConnected && !device.isMuted && !masterMuted
        isRouteArmed = mainMixArmed || hasLiveFeeds
        armedDotView.apply(armed: isRouteArmed)
        // The fader's engaged (gold) fill reuses the EXACT same predicate the
        // dot renders — one armed truth, two instruments (spec §3.3 / §5).
        faderCell.isRouteArmed = isRouteArmed
        // Muted-unconnected controls (v4 §Call-1): a connecting/reconnecting or
        // failed device — or an unavailable one — renders its controls muted
        // (desaturated + lower-contrast), "not adjustable right now"; a connected
        // member is full-gold. Drives the fader dim and the readout tint below.
        let controlsMuted: Bool
        switch device.connectionState {
        case .connecting, .reconnecting, .failed: controlsMuted = true
        case .connected, .off:                    controlsMuted = !device.isAvailable
        }
        faderCell.isMutedControl = controlsMuted

        // Single sublabel precedence ladder (failed → unavailable → routing →
        // none), evaluated here after `device`/`isSelectedInSet`/`isMasterMuted`
        // are set so the precedence is unambiguous.
        resolveSublabel(routedAppNames: routedAppNames, liveAppNames: liveAppNames)

        // Don't fight a live drag: only push the model value into the slider
        // when the user isn't dragging it. (The readout is kept live during a
        // drag by the slider action; on a model refresh it shows the model value.)
        if !isDraggingSlider {
            slider.integerValue = device.volume
            readoutLabel.stringValue = "\(device.volume)%"
        }
        // The volume slider + mute are usable whenever the device is available
        // and controllable (selected member OR an app-redirect target) — kept
        // SEPARATE from `selected` so the "System" routing token stays keyed off
        // set membership only.
        //
        // A5: mute ≠ frozen volume — a muted device's slider stays draggable
        // (dropped the old `!device.isMuted` term) so the user can set the level
        // they'll hear the moment they unmute, instead of the slider going dark
        // the instant they mute.
        slider.isEnabled = device.isAvailable && controllable
        muteButton.isEnabled = device.isAvailable && controllable
        muteButton.state = device.isMuted ? .on : .off
        updateMuteTint()
        // V7 + v4 §Call-1: the `%` readout dims in lockstep with the slider's
        // enabled state OR the muted-unconnected state — a disabled / unavailable
        // / connecting / failed row reads as fully de-emphasized.
        readoutLabel.textColor = (slider.isEnabled && !controlsMuted)
            ? Tokens.Color.secondaryLabel : Tokens.Color.tertiaryLabel

        // Under-name meter visibility (v4 §Call-1): the meter is shown ONLY on
        // armed + unmuted + connected rows (the §3.3 armed predicate captures
        // exactly that). Otherwise it is HIDDEN (collapsing in the identity
        // stack, leaving name / sublabel) and drained/reset so a stale bar can't
        // stick — same transient-reset discipline as `isHovered`. HOW it empties
        // matters (S3): when MUTE is the only blocker (the row would be armed if
        // unmuted) the meter DRAINS through the existing decay ballistics; any
        // other cause (deselected, disconnected, unavailable) hard-resets.
        let showMeterNow = showsMeter && isRouteArmed
        if showsMeter { meterView.isHidden = !showMeterNow }
        if showsMeter && !showMeterNow {
            let mutedOnly = device.isAvailable && activeMember && isConnected
            if mutedOnly {
                meterView.setLevel(0)   // ballistic drain (reused decay path)
            } else {
                meterView.reset()
            }
            lastMeterLevel = 0
        }

        // Membership bus (spec §4): re-derive the node from the freshly-applied
        // membership/blocked/dim state. No-op when `showsBus` is false.
        updateBus()

        configureAccessibility()
        setNeedsDisplay(bounds)
    }

    /// Set this row's rail extent (Warm Signal v4 §Call-1) — the host calls this
    /// once per rebuild from the row's position in the spine: `above`/`below`
    /// gate the vertical rail segments so the rail runs Main Audio → the LOWEST
    /// SELECTED node, and a row BELOW that terminus passes `above: false,
    /// below: false` (a bare hollow node with no rail). Structural, so it
    /// survives an in-place `apply` repaint.
    public func setBusRail(above: Bool, below: Bool) {
        busRailAbove = above
        busRailBelow = below
        updateBus()
    }

    /// Convenience for the terminating (lowest selected) node: rail above, none
    /// below. Retained for callers/tests that only distinguish "terminates".
    public func setBusTerminates(_ terminates: Bool) {
        setBusRail(above: true, below: !terminates)
    }

    /// Re-derive and push the bus node rendering from the current membership /
    /// blocked / availability / dim / terminate state (spec §4). No-op when the
    /// row hosts no bus (`busActive` false).
    private func updateBus() {
        guard busActive else { return }
        let node: MembershipBusView.Node
        var dim = busNodeDimmed
        if isToggleBlocked {
            node = .blocked              // §4.6 greyed hollow node
        } else if !device.isAvailable {
            // Unavailable signature (spec §3.6 matrix): a HOLLOW, tinted node the
            // line detours — an unavailable device is not currently in the mix,
            // whatever its held checkbox state says. The `Unavailable` sublabel +
            // row-level text dim keep it distinct from blocked (R5).
            node = .nonMember
            dim = true
        } else if isSelectedInSet {
            // Selected members key their node off the CONNECTION state (v4
            // §Call-1 node vocabulary): connecting/reconnecting → gold dashed;
            // failed → failure-red ring; connected/idle → filled gold.
            switch device.connectionState {
            case .connecting, .reconnecting: node = .connecting
            case .failed:                    node = .failed
            case .connected, .off:           node = .member
            }
        } else {
            node = .nonMember            // §4.4 hollow node, line detours
        }
        // A FAILED member always renders at full failure emphasis regardless of
        // dormancy — never dim its node (the red ring carries it, and the node
        // stays in the spine until an honest toggle-off).
        if case .failed = device.connectionState { dim = false }
        busView.apply(node: node, railAbove: busRailAbove, railBelow: busRailBelow, dimmed: dim)
    }

    /// Updates the mute button's engaged treatment for the current
    /// `muteButton.state` (V1 + S3, spec §3.4/§3.5): `.on` (muted) reads as an
    /// accent-tinted glyph inside a **filled accent pill** (drawing-only, on
    /// the real `NSButton`'s backing layer — behavior/keyboard/VoiceOver
    /// untouched); `.off` reverts to the neutral secondary tint with no pill.
    /// The glyph itself NEVER changes (no alternate/slash image — locked
    /// decision). Mirrors `MainOutRowView.updateMuteTint()`. Called from
    /// `apply` (model refresh) AND `muteToggled` (a live click) so both paths
    /// land the same treatment instantly, and from
    /// `viewDidChangeEffectiveAppearance` (the pill fill is a static CGColor).
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
    }

    /// The pill's engaged fill is a static `CGColor` — re-stamp on a live
    /// light/dark or Increase-Contrast switch (the dot/ring/bus subviews all
    /// handle their own re-resolution).
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMuteTint()
    }

    /// Alpha applied to `enableCheckbox` when `apply(selectionDimmed:)` is true
    /// (A1) — a visual de-emphasis, not a disablement (the checkbox stays
    /// `isEnabled` and interactive at this alpha).
    private static let selectionDimmedAlpha: CGFloat = 0.4

    /// Separator joining routing-line tokens: space, U+00B7 MIDDLE DOT, space.
    private static let routingTokenSeparator = " · "

    // NOTE (2026-07-22, Warm Signal S1): the corner connection dot
    // (`StatusDotView`) is retired; `apply` now drives `HaloRingView.apply(_:)`
    // directly (same idempotent reset, so a repeated `apply` still can't leave a
    // stale breathing animation running) and routes every sublabel through
    // `resolveSublabel(routedAppNames:liveAppNames:)`'s ladder, which subsumes
    // the failed-only case as its highest rung.

    /// Decide the single sublabel line via one precedence ladder (highest first;
    /// exactly one line, or none), then show/hide `statusLabel` and center the
    /// name accordingly. Reuses the single `statusLabel` for all three sublabel
    /// kinds so `test_statusText` reports whichever is showing.
    ///
    /// 1. `.failed` connection → "Couldn't connect" (`.systemOrange`). Highest.
    /// 2. else device unavailable → "Unavailable" (`.tertiaryLabelColor`, greyed).
    /// 3. else routing set non-empty → the routing line (`.secondaryLabelColor`).
    ///    The routing set is non-empty iff selected OR an app-name list (live or
    ///    intent) is non-empty. Tokens: "System" first when selected, then each
    ///    app name in order, joined by `routingTokenSeparator`. The app names
    ///    come from `liveAppNames` (T9's confirmed-streaming signal) when it's
    ///    non-empty, else fall back to `routedAppNames` (routing INTENT/config —
    ///    no "playing"/"active" language on its own). Using `liveAppNames` when
    ///    present is the one case that genuinely IS a playback claim: it only
    ///    ever carries names the backend confirmed are actually streaming there.
    /// 4. else → no sublabel; single-line row (name centered).
    private func resolveSublabel(routedAppNames: [String], liveAppNames: [String]) {
        if case .failed = device.connectionState {
            // Failure-exclusive red (spec §2/§3.5/R8) — paired with the red
            // failed halo ring; supersedes the old systemOrange `warning` tint.
            showSublabel("Couldn't connect", color: Tokens.Color.failure)
        } else if !device.isAvailable {
            showSublabel("Unavailable", color: Tokens.Color.tertiaryLabel)
        } else if let routing = routingLine(routedAppNames: routedAppNames, liveAppNames: liveAppNames) {
            // S3 (spec §3.5): a ROW-muted device prepends the small-caps MUTED
            // token to its EXISTING feed sublabel — never to a single-line row
            // (this branch only runs when a sublabel already exists, so the
            // row height is untouched — R7 no-reflow). Master mute adds NO
            // token (matrix §3.6: the Main Out pill carries it; and since
            // master mute is realized by muting every member, `isMasterMuted`
            // is what distinguishes the two).
            if device.isMuted && !isMasterMuted {
                showMutedSublabel(feeds: routing)
            } else {
                showSublabel(routing, color: Tokens.Color.secondaryLabel)
            }
        } else {
            hideSublabel()
        }
    }

    /// Show the sublabel as `MUTED · <feeds>` (spec §3.5 slot rung 3): the
    /// leading MUTED token in the micro-label voice (spec §2 — SF Mono bold,
    /// tracked, uppercase) with the feed list continuing in the sublabel's own
    /// 10 pt voice. Same single `statusLabel`, same line, same row height.
    private func showMutedSublabel(feeds: String) {
        statusLabel.isHidden = false
        let bodyFont = statusLabel.font ?? .systemFont(ofSize: 10)
        let composed = NSMutableAttributedString(
            string: "MUTED",
            attributes: [.font: Tokens.Font.microLabel,
                         .kern: Tokens.Font.microLabelKern,
                         .foregroundColor: Tokens.Color.secondaryLabel])
        composed.append(NSAttributedString(
            string: Self.routingTokenSeparator + feeds,
            attributes: [.font: bodyFont,
                         .foregroundColor: Tokens.Color.secondaryLabel]))
        statusLabel.attributedStringValue = composed
        statusLabel.textColor = Tokens.Color.secondaryLabel
        applyNameStackLayout(twoLine: true)
    }

    /// The routing line for the current selection + routed apps, or `nil` when
    /// the routing set is empty (not selected AND no app names on either list).
    /// "System" leads when selected, then the effective app-name list in the
    /// given order — `liveAppNames` (confirmed streaming, T9) when non-empty,
    /// else `routedAppNames` (routing intent) as the fallback so a device with a
    /// pending redirect isn't left with no label at all.
    private func routingLine(routedAppNames: [String], liveAppNames: [String]) -> String? {
        var tokens: [String] = []
        if isSelectedInSet { tokens.append("System") }
        tokens.append(contentsOf: liveAppNames.isEmpty ? routedAppNames : liveAppNames)
        guard !tokens.isEmpty else { return nil }
        return tokens.joined(separator: Self.routingTokenSeparator)
    }

    /// Show `statusLabel` with `text`/`color` and raise the name so the name +
    /// sublabel pair is centered as a group on the icon.
    private func showSublabel(_ text: String, color: NSColor) {
        statusLabel.isHidden = false
        statusLabel.stringValue = text
        statusLabel.textColor = color
        applyNameStackLayout(twoLine: true)
    }

    /// Hide `statusLabel` and single-line-center the name.
    private func hideSublabel() {
        statusLabel.isHidden = true
        statusLabel.stringValue = ""
        applyNameStackLayout(twoLine: false)
    }

    /// Push a live RMS reading into the leading VU meter (task T3). No-op when
    /// `showsMeter` is false — the mixer window/`GroupRowView` never call this.
    /// While the row is muted (row OR master — S3), an incoming push is coerced
    /// to 0 so a straggling RMS event can never refill a drained meter: a muted
    /// row's meter stays down until unmute (the decay ballistics still ease any
    /// remaining bar toward 0, so the drain look is preserved).
    public func setLevel(_ rms: Float) {
        guard showsMeter else { return }
        let effective = (device.isMuted || isMasterMuted) ? 0 : rms
        lastMeterLevel = effective
        meterView.setLevel(effective)
    }

    /// Zero the leading VU meter with no animation (popover-close discipline —
    /// PopoverController calls this on every row so a reopen never shows a
    /// stale bar). No-op when `showsMeter` is false.
    public func resetLevel() {
        guard showsMeter else { return }
        meterView.reset()
        lastMeterLevel = 0
    }

    /// Backward-compatible one-arg update (selection derived from the backend
    /// `isSelected` flag). Retained for callers/tests not yet passing explicit
    /// membership; new hosts should use
    /// ``apply(_:selected:controllable:blocked:blockReason:routedAppNames:)``.
    ///
    /// NOTE: this path leaves `controllable` at its `false` default, so the
    /// slider/mute come up DISABLED regardless of `selected` — see that
    /// parameter's doc. Both real hosts (popover + mixer) pass `controllable`
    /// explicitly and never rely on this shim for a live row.
    public func apply(_ device: Device) {
        apply(device, selected: device.isSelected)
    }

    // MARK: Build

    private var isDraggingSlider = false

    private func buildSubviews() {
        wantsLayer = true
        // Leading edge of the row's first control (task B shared grid). Members
        // read indented; the toggle (when present) or the icon (when hidden)
        // starts here.
        let leading: CGFloat = indented ? PopoverColumnGrid.indentedLeadingInset
                                        : PopoverColumnGrid.leadingInset

        enableCheckbox.translatesAutoresizingMaskIntoConstraints = false
        // Bus rows (spec §4): swap in a no-op-drawing cell BEFORE `setButtonType`
        // so the checkbox stays a real, keyboard- and VoiceOver-operable `.switch`
        // button that simply renders nothing — the ``MembershipBusView`` node is
        // its visible skin (§4.8 "only the DRAWING changes"). `setButtonType`
        // configures the existing cell in place, so the subclass survives it.
        if busActive { enableCheckbox.cell = InvisibleSwitchCell() }
        enableCheckbox.setButtonType(.switch)       // AppKit checkbox
        enableCheckbox.title = ""                    // no inline title
        enableCheckbox.controlSize = .regular
        enableCheckbox.target = self
        enableCheckbox.action = #selector(enableToggled(_:))
        enableCheckbox.setContentHuggingPriority(.required, for: .horizontal)

        // Bus node/rail overlay (spec §4): non-interactive, spans the full row
        // height at the node column, drawing this row's node + rail segment. Added
        // BELOW the checkbox in z-order isn't required (it never hit-tests), but it
        // must be present so clicks on the node area still reach the checkbox.
        busView.translatesAutoresizingMaskIntoConstraints = false
        // Group-member rows hide the toggle (task C). Its leading slot is not
        // reused — the row already indents, keeping the icon column aligned.
        enableCheckbox.isHidden = !showsToggle

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        // Connection halo ring: a box the size of the icon, centered on the icon,
        // drawing the ring circle around the glyph. Non-interactive overlay.
        haloRingView.translatesAutoresizingMaskIntoConstraints = false
        haloRingView.setContentHuggingPriority(.required, for: .horizontal)

        // Route-armed corner dot (spec §3.3): a small box riding the icon's
        // bottom-right corner (the retired connection dot's position, off the
        // same `statusDotInset` pull-in). Non-interactive overlay.
        armedDotView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Tokens.Font.menuItem
        nameLabel.lineBreakMode = .byTruncatingTail   // task B: "…" tail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Status sublabel (2026-07-17): one line driven by the precedence ladder
        // (failed / unavailable / routing). Small and secondary; `resolveSublabel`
        // shows/hides it and `applyNameStackLayout` centers the name accordingly.
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = Tokens.Color.secondaryLabel
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.isHidden = true   // single-line by default until the first `apply`

        slider.translatesAutoresizingMaskIntoConstraints = false
        // Warm fader skin: install the drawing-only cell BEFORE the value/
        // target configuration below (a cell swap resets cell-held state, so
        // everything after re-lands on the new cell). Tracking, keyboard,
        // scroll-wheel, `isContinuous`, and VoiceOver stay stock NSSlider.
        slider.cell = faderCell
        slider.minValue = 0
        slider.maxValue = 100
        slider.isContinuous = true            // fire throughout the drag (brief §2)
        slider.target = self
        slider.action = #selector(volumeChanged(_:))

        // `%` readout, right-aligned, small secondary — hangs off the slider's
        // trailing edge (change 4) so the number reads tight against the slider.
        readoutLabel.translatesAutoresizingMaskIntoConstraints = false
        readoutLabel.font = Tokens.Font.caption
        readoutLabel.textColor = Tokens.Color.secondaryLabel
        readoutLabel.alignment = .right
        readoutLabel.setContentHuggingPriority(.required, for: .horizontal)

        configureAccessoryButton(muteButton, symbol: "speaker.wave.2.fill",
                                  action: #selector(muteToggled(_:)))

        // Leading VU meter (task T3): mounted only when `showsMeter` — the
        // mixer window/GroupRowView never pass `true`, so their layout is
        // unaffected. Non-interactive (`LevelMeterView.hitTest` returns nil).
        meterView.translatesAutoresizingMaskIntoConstraints = false

        // Name click toggles the ENABLED checkbox (2026-07-17 convenience — the
        // name is spatially separate on the left, so a gesture scoped to it can't
        // interfere with the slider/mute/%/toggle on the right). The checkbox stays
        // the authoritative accessibility control; this is a mouse convenience.
        // A `.failed` device re-enables (retries) on click — intended.
        let nameClick = NSClickGestureRecognizer(target: self, action: #selector(nameClicked(_:)))
        nameLabel.addGestureRecognizer(nameClick)

        // Identity cluster (v4 §Call-1): name / meter / sublabel in a vertical
        // stack, centred as a group. The meter is present only on `showsMeter`
        // rows (hidden until armed); the sublabel toggles `isHidden` via the
        // precedence ladder — the stack recentres the visible lines automatically.
        identityStack.translatesAutoresizingMaskIntoConstraints = false
        identityStack.orientation = .vertical
        identityStack.alignment = .leading
        identityStack.spacing = 2
        identityStack.distribution = .fill
        identityStack.addArrangedSubview(nameLabel)
        if showsMeter {
            identityStack.addArrangedSubview(meterView)
            meterView.isHidden = true   // shown only on armed rows (gated in `apply`)
        }
        identityStack.addArrangedSubview(statusLabel)

        if busActive { addSubview(busView) }
        addSubview(enableCheckbox)
        addSubview(iconView)
        addSubview(haloRingView)           // ring around the icon glyph
        addSubview(armedDotView)           // gold route-armed dot on its corner
        addSubview(identityStack)
        addSubview(slider)
        addSubview(readoutLabel)
        addSubview(muteButton)

        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: Self.rowHeight),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),
            iconView.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),

            // Connection halo ring: a box GROWN past the icon box (Warm Signal
            // v4.1 item 2 — `haloRingHostBoxDiameter`, not `iconWidth`) so its
            // inscribed `haloRingDiameter` circle floats a breathing-room gap
            // off the glyph rather than hugging it. Still centered on the
            // icon — only the halo's own overlay box grows; the icon/name/
            // fader column alignment is untouched.
            haloRingView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.haloRingHostBoxDiameter),
            haloRingView.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.haloRingHostBoxDiameter),
            haloRingView.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            haloRingView.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            // Route-armed dot: centered on the icon box's bottom-right corner,
            // pulled in by `statusDotInset` (spec §3.3).
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

            // Identity cluster: leading off the icon, centred vertically as a
            // group; its trailing yields to the mute glyph so the name truncates.
            identityStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                                    constant: PopoverColumnGrid.iconToName),
            identityStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            identityStack.trailingAnchor.constraint(
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
        ]

        // The under-name meter's fixed size (v4 §Call-1), when it's in the stack.
        if showsMeter {
            constraints.append(contentsOf: [
                meterView.widthAnchor.constraint(
                    equalToConstant: PopoverColumnGrid.meterUnderNameWidth),
                meterView.heightAnchor.constraint(
                    equalToConstant: PopoverColumnGrid.meterUnderNameHeight),
            ])
        }

        // Membership control + bus spine (v4 §Call-1). On a BUS host the node +
        // its invisible checkbox move to the LEFT gutter (`railGutterCenterX`), so
        // a left-gutter node click still toggles the same checkbox; the bus
        // overlay spans the full row height for the continuous rail (zero layout
        // shift on toggle — R7). On a non-bus host (mixer window / tests) the
        // checkbox stays in the trailing control column, byte-for-byte unchanged.
        if busActive {
            constraints.append(contentsOf: [
                busView.centerXAnchor.constraint(
                    equalTo: leadingAnchor, constant: PopoverColumnGrid.railGutterCenterX),
                busView.centerYAnchor.constraint(equalTo: centerYAnchor),
                busView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.busColumnWidth),
                busView.heightAnchor.constraint(equalTo: heightAnchor),
                enableCheckbox.centerXAnchor.constraint(
                    equalTo: leadingAnchor, constant: PopoverColumnGrid.railGutterCenterX),
                enableCheckbox.centerYAnchor.constraint(equalTo: centerYAnchor),
                // A deterministic hit area over the node (the no-op cell draws
                // nothing; without an explicit size its hit target is undefined).
                enableCheckbox.widthAnchor.constraint(
                    equalToConstant: PopoverColumnGrid.busNodeDiameter + 8),
                enableCheckbox.heightAnchor.constraint(
                    equalToConstant: PopoverColumnGrid.busNodeDiameter + 8),
            ])
        } else {
            constraints.append(contentsOf: [
                enableCheckbox.centerXAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -PopoverColumnGrid.trailingControlCenterFromTrailing),
                enableCheckbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        // Icon leading: at `firstElementLeading` on meter/bus rows (reserving the
        // left rail gutter, unchanged x from the pre-v4 leading-meter layout),
        // else flush at the plain leading inset (mixer-window rows, unchanged).
        if showsMeter {
            constraints.append(iconView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: PopoverColumnGrid.firstElementLeading(indented: indented)))
        } else {
            constraints.append(iconView.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: leading))
        }

        NSLayoutConstraint.activate(constraints)
    }

    /// No-op under the v4 identity stack (Warm Signal §Call-1): the vertical
    /// `identityStack` recentres its visible lines (name / meter / sublabel)
    /// automatically when `statusLabel.isHidden` flips, so no manual half-line
    /// offset is needed. Retained as the single call site the sublabel ladder
    /// already funnels through, in case a later density setting needs it.
    private func applyNameStackLayout(twoLine: Bool) {}

    private func configureAccessoryButton(_ button: NSButton, symbol: String,
                                          action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .accessoryBar        // SPEC §9 device-row mute
        button.setButtonType(.pushOnPushOff)
        button.isBordered = false
        // Speaker glyph LEFT of the slider: `pushOnPushOff` still toggles the
        // mute STATE (and fires the delegate) on tap, but the glyph itself stays
        // fixed on `symbol` in both states — no alternate/slash image (ahh wants
        // the icon to never change on toggle). Mute state is reflected only via
        // `button.state` and the accessibility label update in `apply`.
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        button.imagePosition = .imageOnly
        button.contentTintColor = Tokens.Color.secondaryLabel
        button.target = self
        button.action = action
    }

    // MARK: Actions

    @objc private func volumeChanged(_ sender: NSSlider) {
        // STABILITY(D4): the drag flag clears only when the last change callback coincides with .leftMouseUp — Esc/cancelled drags leave it stuck and the row ignores model updates; see dev/notes/stability-audit-2026-07-18.md
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
        // AppKit has already flipped `sender.state` (pushOnPushOff) by the time
        // the action fires, so this lands the tint instantly on a live click
        // rather than waiting for the next host-driven `apply`.
        updateMuteTint()
        delegate?.deviceRow(self, didToggleMute: sender.state == .on, for: device.id)
    }

    @objc private func enableToggled(_ sender: NSButton) {
        delegate?.deviceRow(self, didToggleEnabled: sender.state == .on, for: device.id)
    }

    /// Clicking the device NAME toggles the ENABLED checkbox (2026-07-17), firing
    /// the SAME delegate path as the checkbox itself. On a BLOCKED row (spec §4.6
    /// — "a click ANYWHERE on the row body / name / node") the click instead
    /// requests the in-place refusal note, so the name is never a dead surface on
    /// the one row whose toggle can't move (S4 — the label consumes the mouseDown,
    /// so the row-body `mouseDown(with:)` branch alone can't cover it). Otherwise
    /// a disabled checkbox (an unavailable device) keeps the click a no-op —
    /// the same conditions `enableCheckbox.isEnabled` uses. For a `.failed`
    /// device this re-enables it (= retry), which is intended.
    @objc private func nameClicked(_ sender: NSClickGestureRecognizer) {
        if isToggleBlocked {
            delegate?.deviceRowDidRequestBlockedExplanation(self)
            return
        }
        guard enableCheckbox.isEnabled else { return }
        let flipped = enableCheckbox.state != .on
        enableCheckbox.state = flipped ? .on : .off
        delegate?.deviceRow(self, didToggleEnabled: flipped, for: device.id)
    }

    /// The name/label colour for the current state: menu highlight wins, then a
    /// dropped device greys out, then a not-selected device de-emphasizes (it's
    /// not in the Selected Devices set), then normal.
    ///
    /// A BLOCKED row deliberately keeps NORMAL text (spec §4.6/§7 R5, S4 —
    /// supersedes the older V12 name-grey): its signature is the distinct greyed
    /// bus node + the body-click refusal note. A row-level text dim here would
    /// blur into the UNAVAILABLE signature (disabled text + "Unavailable"
    /// sublabel + tinted node) — the two "can't" states must never look alike.
    private var rowTextColor: NSColor {
        if isInMenu, enclosingMenuItem?.isHighlighted == true { return .selectedMenuItemTextColor }
        if !device.isAvailable { return .disabledControlTextColor }
        return isSelectedInSet ? Tokens.Color.label : Tokens.Color.secondaryLabel
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

    /// Fire the volume slider's OWN `target`/`action` with the slider as
    /// sender — the exact dispatch AppKit performs during a drag — after
    /// setting its value. Unlike ``test_setVolume(_:)`` (the delegate
    /// shortcut), this proves the control's wiring end-to-end, which matters
    /// since the Warm fader skin swaps the slider's CELL (drawing-only; the
    /// wiring must survive). Mirrors `test_fireCheckboxAction`'s house style.
    public func test_fireSliderAction(settingValueTo value: Int) {
        slider.integerValue = value
        guard let action = slider.action,
              let target = slider.target as? NSObject else { return }
        _ = target.perform(action, with: slider)
    }

    /// The slider's live behavior configuration (continuous / range / type) —
    /// asserts the WarmFaderCell swap left NSSlider behavior stock.
    public var test_sliderConfiguration:
        (isContinuous: Bool, min: Double, max: Double, type: NSSlider.SliderType) {
        (slider.isContinuous, slider.minValue, slider.maxValue, slider.sliderType)
    }

    /// Simulate the user toggling this row's mute button — flips
    /// `muteButton.state` and lands the V1 tint via `updateMuteTint()` exactly
    /// as a real click does (AppKit flips the `pushOnPushOff` state before
    /// `muteToggled(_:)` fires), then drives the same delegate path.
    public func test_toggleMute(_ muted: Bool) {
        muteButton.state = muted ? .on : .off
        updateMuteTint()
        delegate?.deviceRow(self, didToggleMute: muted, for: device.id)
    }

    /// Simulate the user flipping this row's primary "send audio here" switch.
    public func test_toggleEnabled(_ on: Bool) {
        delegate?.deviceRow(self, didToggleEnabled: on, for: device.id)
    }

    /// Simulate the user clicking the device NAME (toggles the ENABLED checkbox,
    /// same delegate path). Mirrors the real gesture handler: on a BLOCKED row it
    /// requests the in-place refusal note (spec §4.6, S4) instead; on any other
    /// disabled checkbox it's a no-op.
    public func test_clickName() {
        if isToggleBlocked {
            delegate?.deviceRowDidRequestBlockedExplanation(self)
            return
        }
        guard enableCheckbox.isEnabled else { return }
        let flipped = enableCheckbox.state != .on
        enableCheckbox.state = flipped ? .on : .off
        delegate?.deviceRow(self, didToggleEnabled: flipped, for: device.id)
    }

    /// Which connection ring the row is currently showing — derived from
    /// `device.connectionState` (the single source the ring renders from), so it
    /// can never drift from what's actually on screen. (Named `statusKind` for
    /// back-compat; it now reports the halo-ring form.)
    public var test_statusKind: StatusKind {
        switch device.connectionState {
        case .off:                        return .none
        case .connecting, .reconnecting:  return .connecting
        case .connected:                  return .connected
        case .failed:                     return .failed
        }
    }

    /// The halo ring's ACTUAL rendered form, read from the ring view (not
    /// re-derived from `connectionState`) — proves the ring is wired to the
    /// state, catching a drive-path regression `test_statusKind` can't.
    public var test_ringForm: StatusKind {
        switch haloRingView.test_form {
        case .none:        return .none
        case .connecting:  return .connecting
        case .connected:   return .connected
        case .failed:      return .failed
        }
    }

    /// The halo ring's current stroke color (resolved against the effective
    /// appearance) — asserts connected (`ringConnected`) vs failed (`failure`)
    /// use distinct hues.
    public var test_ringStrokeColor: NSColor? { haloRingView.test_strokeColor }

    /// The halo ring's current stroke width — asserts the failed ring's heavier
    /// weight (`haloRingFailedStroke`) vs the connected ring.
    public var test_ringLineWidth: CGFloat { haloRingView.test_lineWidth }

    /// Whether the halo ring is currently DASHED — the connecting/reconnecting
    /// "incomplete" form, which survives (static) under Reduce Motion.
    public var test_ringIsDashed: Bool { haloRingView.test_isDashed }

    /// The row's current VoiceOver label — lets tests assert every connection
    /// state has a spoken equivalent (the ring's accessible counterpart, spec
    /// §4.8; absorbs A11Y-DEVICEROW for connection state).
    public var test_accessibilityLabel: String? { accessibilityLabel() }

    /// The current sublabel's text, or `nil` when hidden. Reports whichever of the
    /// three sublabel kinds is showing (failed "Couldn't connect" / "Unavailable"
    /// / the routing line), since all three flow through the single `statusLabel`.
    public var test_statusText: String? {
        statusLabel.isHidden ? nil : statusLabel.stringValue
    }

    /// The sublabel's current text color, or `nil` when hidden — asserts the
    /// failed sublabel uses the failure-exclusive red (R8), paired with the
    /// failed ring.
    public var test_statusColor: NSColor? {
        statusLabel.isHidden ? nil : statusLabel.textColor
    }

    /// The composed routing sublabel string ("System …" joined by " · "), or
    /// `nil` when the routing set is empty — for asserting the routing line in
    /// isolation from the failed/unavailable precedence. `liveAppNames`
    /// defaults to empty so existing intent-only callers are unaffected; pass it
    /// to assert the T9 live-precedence-over-intent behavior. Test hook.
    public func test_sourceText(routedAppNames: [String], liveAppNames: [String] = []) -> String? {
        routingLine(routedAppNames: routedAppNames, liveAppNames: liveAppNames)
    }

    /// Whether the connecting/reconnecting ring's breathing pulse is installed
    /// (on screen + Reduce Motion off). Lets tests assert the animation hook.
    public var test_ringIsBreathing: Bool { haloRingView.test_isBreathing }

    /// The primary ON/OFF checkbox's current state (for structural assertions).
    public var test_isEnabledOn: Bool { enableCheckbox.state == .on }

    /// Whether the primary membership toggle is shown. Group-member rows hide it
    /// (task C); Selected-Devices rows show it.
    public var test_showsToggle: Bool { !enableCheckbox.isHidden }

    /// The last level pushed to the leading VU meter via ``setLevel(_:)`` — `0`
    /// when the row has no meter (`showsMeter == false`) or after a reset
    /// (``apply(_:selected:controllable:blocked:blockReason:routedAppNames:)``
    /// resets it whenever the row isn't a playing output).
    public func test_meterLevel() -> Float { lastMeterLevel }

    /// The row's icon tint. Always `.secondaryLabelColor` now (2026-07-17 — the
    /// icon is neutral identity-only; selection reads from the switch, status
    /// from the on-icon dot). Retained for the T-U8 reset test.
    public var test_iconTint: NSColor? { iconView.contentTintColor }

    /// The mute button's current tint (V1) — `.controlAccentColor` while muted,
    /// `.secondaryLabelColor` otherwise. The glyph itself never changes; only
    /// this tint does.
    public var test_muteTintColor: NSColor? { muteButton.contentTintColor }

    /// Whether the mute button is currently drawing its ENGAGED pill (S3, spec
    /// §3.4/§3.5): `.on` state + the accent pill fill stamped on its layer.
    public var test_isMutePillEngaged: Bool {
        muteButton.state == .on && muteButton.layer?.backgroundColor != nil
    }

    // MARK: Route-armed dot (spec §3.3) test hooks

    /// Whether the gold route-armed corner dot is currently LIT — reads the
    /// dot view's rendered state (the §3.3 predicate's outcome), so it can't
    /// drift from the pixels.
    public var test_routeArmed: Bool { armedDotView.test_isLit }

    /// The dot's current fill color (resolved) — gold when armed, the
    /// dark/empty `dotSocket` otherwise.
    public var test_dotFillColor: NSColor? { armedDotView.test_fillColor }

    /// Whether the lit dot's STATIC glow halo is on (armed only).
    public var test_dotHasGlow: Bool { armedDotView.test_hasGlow }

    /// Whether the one-shot arm bloom is currently mid-flight (fires only on a
    /// transition INTO armed after the first apply, on screen, Reduce Motion
    /// off — spec §6).
    public var test_dotIsBlooming: Bool { armedDotView.test_isBlooming }

    /// The row's current VoiceOver VALUE ("muted" / "armed" / "playing here"
    /// composition) — the spoken equivalent of the dot + mute channels.
    public var test_accessibilityValue: String? { accessibilityValue() as? String }

    /// The row's current VoiceOver HINT (`accessibilityHelp`) — carries the
    /// local-mix refusal reason on a BLOCKED row (spec §4.6, S4), `nil` elsewhere.
    public var test_accessibilityHint: String? { accessibilityHelp() }

    /// The meter's current ballistics TARGET — with ``test_meterDisplayed``,
    /// distinguishes the S3 mute DRAIN (target 0, displayed still easing down)
    /// from a hard reset (both 0 instantly).
    public var test_meterTarget: CGFloat { meterView.test_targetLevel }

    /// The meter's currently DRAWN level.
    public var test_meterDisplayed: CGFloat { meterView.test_displayedLevel }

    /// Settle the meter's DRAWN level synchronously (no display link) — the
    /// deterministic setup step for drain-vs-reset assertions and snapshots.
    public func test_settleMeterDisplayed(_ level: CGFloat) {
        meterView.test_setDisplayedLevel(level)
    }

    /// The `%` readout's current text colour (V7) — dims to `.tertiaryLabelColor`
    /// in lockstep with the slider's disabled state, `.secondaryLabelColor`
    /// otherwise.
    public var test_readoutColor: NSColor? { readoutLabel.textColor }

    /// Whether the Warm fader would render its ENGAGED (gold-gradient) fill —
    /// route-armed ∧ slider enabled, read from the cell's own gate so the test
    /// can't drift from the pixels. Must track `test_routeArmed` whenever the
    /// slider is enabled (one armed truth, two instruments).
    public var test_isFaderEngaged: Bool { faderCell.test_isEngagedFill }

    /// Whether the slider is wearing the Warm fader skin (the drawing-only
    /// `WarmFaderCell` swap) — structural assertion that the skin is installed.
    public var test_hasWarmFaderSkin: Bool { slider.cell is WarmFaderCell }

    /// Whether the volume slider is currently enabled (A5) — stays enabled while
    /// the device is muted (mute ≠ frozen volume); only availability/
    /// controllability/unsupported-ness gate it.
    public var test_isSliderEnabled: Bool { slider.isEnabled }

    /// Whether the "Selected Devices" membership is currently rendered dimmed (A1
    /// / §4.7) — a visual de-emphasis that does NOT disable the control. For a
    /// non-bus row this is the checkbox alpha (~0.4); for a BUS row it's the node
    /// TINT (`busNodeDimmed`), since the bus dims via tint with the checkbox held
    /// at full alpha (§4.7). Pair with `test_isEnabledOn`/clicking to confirm it's
    /// still interactive.
    public var test_isSelectionDimmed: Bool {
        busNodeDimmed || enableCheckbox.alphaValue < 1.0
    }

    // MARK: Membership bus (spec §4) test hooks

    /// The bus node currently drawn (spec §4) — `nil` when this row has no bus
    /// (non-bus host, or a `showsToggle == false` group-member row, which keeps
    /// NO bus node). Reads the same `MembershipBusView` state the drawing reads,
    /// so it can't drift from the pixels.
    public var test_busNode: MembershipBusView.Node? { busActive ? busView.test_node : nil }

    /// Whether the bus draws a rail BELOW this row's node — `false` on the
    /// terminating (lowest selected) node and on a bare node below it (spec v4
    /// §Call-1). `nil` when the row has no bus.
    public var test_busRailBelow: Bool? { busActive ? busView.test_railBelow : nil }

    /// Whether the bus draws a rail ABOVE this row's node — `false` only on a
    /// BARE node below the rail terminus (spec v4 §Call-1 "bare hollow nodes …
    /// no rail through them"). `nil` when the row has no bus.
    public var test_busRailAbove: Bool? { busActive ? busView.test_railAbove : nil }

    /// Whether the bus node is ACTUALLY drawn in the de-emphasis tint — reads
    /// the drawn value (dormant tint, unavailable tint, and the failed-member
    /// never-dim exemption included), unlike `test_isSelectionDimmed` which
    /// reports the host-driven dormancy input. `nil` when the row has no bus.
    public var test_busNodeDimmed: Bool? { busActive ? busView.test_dimmed : nil }

    /// The x-position (in this row's coordinates) of the bus node's center, after
    /// layout — used to prove the node NEVER moves when membership toggles (spec
    /// §4.1 / R7 "zero layout shift"). `nil` when the row has no bus.
    public func test_busNodeCenterX() -> CGFloat? {
        guard busActive else { return nil }
        layoutSubtreeIfNeeded()
        return busView.frame.midX
    }

    /// The membership control's (the node-skinned checkbox's) current VoiceOver
    /// label — asserts the bus node speaks as the SAME real checkbox (spec §4.8:
    /// the node IS the checkbox to VoiceOver; the checked/unchecked value comes
    /// from the un-subclassed `NSButton` state machinery for free).
    public var test_membershipAXLabel: String? { enableCheckbox.accessibilityLabel() }

    /// Drive the REAL checkbox action dispatch (spec §4.8 — the checkbox stays the
    /// control underneath). Mirrors `MainOutRowMenuDispatchTests`' house style:
    /// set the checkbox's state then invoke its OWN `target`/`action` with the
    /// checkbox as sender, exactly as AppKit does on a click — NOT the delegate
    /// shortcut. Proves the node's toggle path is wired end-to-end through the
    /// live control.
    public func test_fireCheckboxAction(settingStateTo on: Bool) {
        enableCheckbox.state = on ? .on : .off
        guard let action = enableCheckbox.action,
              let target = enableCheckbox.target as? NSObject else { return }
        _ = target.perform(action, with: enableCheckbox)
    }

    /// Simulate a click on the BODY of a blocked row (spec §4.6) — runs the exact
    /// production branch `mouseDown(with:)` runs, without synthesizing an event.
    public func test_simulateBlockedBodyClick() { _ = handleBodyMouseDown() }

    /// The device name label's current colour (``rowTextColor``) — asserts the
    /// V12 blocked-name branch (`.tertiaryLabelColor`) alongside the ordinary
    /// available/selected states. `apply` already stamps this, so no `draw(_:)`
    /// call is needed to read it.
    public var test_nameColor: NSColor? { nameLabel.textColor }

    /// Drive the transient hover state through the same private path
    /// `mouseEntered(with:)`/`mouseExited(with:)` use (`setHovered`), since a real
    /// pointer crossing can't be synthesized headlessly. Spec §4.8's snapshot
    /// fixture list requires a HOVERED row render (the neutral wash at
    /// `PopoverColumnGrid.rowHoverWashAlpha`, never gold); note any later
    /// `apply(...)` or window re-attach clears it, exactly like a live hover.
    public func test_setHovered(_ hovered: Bool) { setHovered(hovered) }

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

    /// A click on the BODY of a BLOCKED row (spec §4.6) surfaces the refusal note
    /// — the reachable trigger the disabled checkbox + tooltip alone lacked
    /// (§8.5). A click landing on a live control (slider/mute) is consumed by
    /// that subview and never reaches here; the NAME label also consumes its
    /// clicks but routes a blocked row's to the same request via `nameClicked(_:)`
    /// (S4 — "anywhere on the row body / name / node"); a click on the disabled
    /// checkbox (disabled controls don't hit-test) or the row body lands here. On
    /// a non-blocked row this falls through to the default handling.
    public override func mouseDown(with event: NSEvent) {
        if handleBodyMouseDown() { return }
        super.mouseDown(with: event)
    }

    /// The blocked-body-click branch, factored out so the test hook exercises the
    /// exact production logic without synthesizing an `NSEvent`. Returns `true`
    /// when the click was handled as a blocked-explanation request.
    private func handleBodyMouseDown() -> Bool {
        guard isToggleBlocked else { return false }
        delegate?.deviceRowDidRequestBlockedExplanation(self)
        return true
    }

    /// C3: a pointing-hand cursor over the NAME label only (its click toggles
    /// membership, ``nameClicked(_:)``) — scoped to `nameLabel.frame`, not the
    /// whole row, so the slider/mute/checkbox keep the standard arrow. Standard
    /// AppKit `resetCursorRects`/`addCursorRect`; no interaction with the hover
    /// `NSTrackingArea` above (cursor rects and tracking areas are independent
    /// AppKit mechanisms).
    public override func resetCursorRects() {
        super.resetCursorRects()
        // `nameLabel` lives inside `identityStack` now (v4 §Call-1), so its own
        // frame is in the stack's coordinates — convert to this row's space.
        addCursorRect(convert(nameLabel.bounds, from: nameLabel), cursor: .pointingHand)
    }

    /// Cursor rects are frame-snapshotted by AppKit, not live — re-establish
    /// them whenever layout can have moved `nameLabel` (e.g. the row toggling
    /// between single-line and two-line sublabel layouts shifts the name's
    /// vertical position, though not its rect in this row's fixed-width layout).
    public override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

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
        // STABILITY(D4): every row installs its own app-wide monitor, churned on each rebuild — any fix should reduce multiplicity/churn only; the monitor pattern itself is deliberate (see this target's AGENTS.md); see dev/notes/stability-audit-2026-07-18.md
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
                Tokens.Color.selectedContentBackground.setFill()
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
                Tokens.Color.accent.withAlphaComponent(PopoverColumnGrid.rowSelectionWashAlpha).setFill()
                path.fill()
            } else if isHovered {
                Tokens.Color.selectedContentBackground.withAlphaComponent(PopoverColumnGrid.rowHoverWashAlpha).setFill()
                path.fill()
            }
        }
        nameLabel.textColor = rowTextColor
        super.draw(dirtyRect)
    }

    // MARK: Attention flash (A4)

    /// Dedicated layer for the one-shot attention pulse, inserted at the BOTTOM
    /// of this view's sublayers (same visual position as the `draw(_:)`
    /// hover/selection wash above — behind every subview) so a flash reads as a
    /// background pulse behind the controls, never an opaque cover over them.
    /// Kept entirely separate from `isHovered`/`isSelectedInSet`: animating this
    /// layer never touches those flags or calls `setNeedsDisplay`, so a flash
    /// can never corrupt the persistent hover/selection state (the same
    /// transient-vs-persistent discipline documented on `isHovered` above).
    private lazy var flashLayer: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = Tokens.Color.accent.cgColor
        layer.opacity = 0
        layer.cornerRadius = PopoverColumnGrid.selectionHighlightCornerRadius
        return layer
    }()

    private static let flashAnimationKey = "deviceRow.flash"

    /// Fire a one-shot attention pulse (A4) — e.g. so a host can draw the eye to
    /// a row that just changed for a reason other than the user directly acting
    /// on it. A single opacity keyframe up-and-back over ~0.5s, via
    /// `CAKeyframeAnimation` (mirrors `StatusDotView`'s Core-Animation idiom).
    /// A no-op under Reduce Motion — the row simply never flashes rather than
    /// jumping straight to some static "flashed" look that would itself read as
    /// a persistent state change.
    public func flashRow() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        guard let hostLayer = layer else { return }
        if flashLayer.superlayer == nil {
            hostLayer.insertSublayer(flashLayer, at: 0)
        }
        flashLayer.frame = bounds.insetBy(dx: PopoverColumnGrid.selectionHighlightInsetX,
                                          dy: PopoverColumnGrid.selectionHighlightInsetY)
        flashLayer.opacity = 0

        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 1, 0]
        pulse.keyTimes = [0, 0.4, 1]
        pulse.duration = 0.5
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let layerToClear = flashLayer
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak layerToClear] in
            layerToClear?.removeFromSuperlayer()
        }
        flashLayer.add(pulse, forKey: Self.flashAnimationKey)
        CATransaction.commit()
    }

    /// Whether the attention pulse (A4) is currently mid-flash — lets tests
    /// assert `flashRow()` fired without a real Core Animation run loop pumping
    /// (the animation is present on the layer's model the instant it's added,
    /// same as `StatusDotView.test_isBreathing`).
    public var test_isFlashing: Bool { flashLayer.animation(forKey: Self.flashAnimationKey) != nil }

    /// Simulate a host asking this row to flash (A4 test hook).
    public func test_flashRow() { flashRow() }

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
        // Membership fragment matches the visible control's vocabulary (C2
        // coherence): a BUS row draws mix membership (spec §4) and its checkbox
        // says "Include … in main audio", so the row-level clause speaks the
        // same concept — never two vocabularies ("selected" here, "main audio"
        // on the checkbox) inside one composed announcement. Non-bus hosts
        // (mixer window, group members) keep the checkbox-column phrasing.
        let membership: String
        if busActive {
            membership = isSelectedInSet ? "in main audio" : "not in main audio"
        } else {
            membership = isSelectedInSet ? "selected" : "not selected"
        }
        // Connection state reads as a trailing clause (brief §6) — omitted
        // entirely for `.off` so an unrouted row's label is unchanged.
        let state = accessibilityStateSuffix
        let stateClause = state.map { ", \($0)" } ?? ""
        setAccessibilityLabel("\(device.name), \(membership), volume \(device.volume) percent\(stateClause)")

        // The row's VALUE carries the live signal channels (S2/S3 — every
        // visual state has a spoken equivalent, shipped with the drawing):
        // "muted" for the engaged mute pill / drained meter, and the armed
        // dot's wording — "playing here" when a confirmed live feed lights it,
        // "armed" for the held main-mix route.
        var valueParts: [String] = []
        if device.isMuted || isMasterMuted { valueParts.append("muted") }
        if isRouteArmed { valueParts.append(hasLiveFeeds ? "playing here" : "armed") }
        setAccessibilityValue(valueParts.joined(separator: ", "))

        // Blocked local-mix row (spec §4.6, S4): the refusal reason rides the
        // row's HINT — the spoken equivalent of the body-click refusal note, so
        // the disabled control + tooltip is never the only surfacing for
        // VoiceOver either. `nil` clears it on any non-blocked repaint.
        setAccessibilityHelp(isToggleBlocked ? blockReasonText : nil)

        if busActive {
            // Bus rows (spec §4.8): the node IS the checkbox to VoiceOver. A
            // checkbox's label stays STABLE across toggles — "include … in main
            // audio" — and the checked/unchecked VALUE (from the untouched
            // `NSButton` state machinery) carries the membership, so VoiceOver
            // reads "Include Office in main audio, checked". Activation
            // (Space/click → `enableToggled(_:)`) is unchanged.
            enableCheckbox.setAccessibilityLabel("Include \(device.name) in main audio")
        } else {
            enableCheckbox.setAccessibilityLabel(
                isSelectedInSet ? "Remove \(device.name) from Selected Devices"
                                : "Add \(device.name) to Selected Devices")
        }
        slider.setAccessibilityRole(.slider)
        slider.setAccessibilityLabel("\(device.name) volume")
        muteButton.setAccessibilityLabel(device.isMuted ? "Unmute \(device.name)" : "Mute \(device.name)")
        // The name-click is a mouse convenience; the switch stays the
        // authoritative accessibility control. A hint on the name label documents
        // the click for VoiceOver users who land on it. On a BLOCKED row the
        // name-click surfaces the refusal note instead (spec §4.6), so its hint
        // carries the reason too.
        if isToggleBlocked {
            nameLabel.setAccessibilityHelp(blockReasonText)
        } else {
            nameLabel.setAccessibilityHelp(
                isSelectedInSet ? "Click to remove from Selected Devices"
                                : "Click to add to Selected Devices")
        }
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

// MARK: - Continuous rail contribution (Warm Signal v4 §Call-1)

extension DeviceRowView: RailNodeProviding {
    /// The node this row renders, or `nil` when it hosts no bus.
    public var railNode: MembershipBusView.Node? { busActive ? busView.test_node : nil }
    /// Within the rail span iff it carries a rail above it (false on a bare node
    /// below the terminus).
    public var railHasSpine: Bool { busRailAbove }
    /// Whether the rail continues below this node (false on the terminus).
    public var railBelow: Bool { busRailBelow }
    /// Whether the node renders dimmed (dormant-divergent tint).
    public var railDimmed: Bool { busView.test_dimmed }
    /// The node is centred on the row's own centre-y.
    public var railNodeView: NSView { self }
    public var railNodeBounds: NSRect { bounds }
}

// MARK: - Delegate default (backward-compatible)

public extension DeviceRowView.Delegate {
    /// Default no-op so conformers that predate the routing control (or that
    /// don't host the on/off switch — e.g. narrow test doubles) still compile.
    /// The real hosts (popover + mixer window) override this to call
    /// `GroupController.setDeviceEnabled`.
    func deviceRow(_ row: DeviceRowView, didToggleEnabled on: Bool, for id: String) {}
    /// Default no-op so non-bus hosts (mixer window, narrow test doubles) needn't
    /// implement the blocked-explanation surfacing (spec §4.6). The popover
    /// overrides this to present the in-place refusal note.
    func deviceRowDidRequestBlockedExplanation(_ row: DeviceRowView) {}
}

// MARK: - Invisible switch cell (spec §4.8)

/// An `NSButtonCell` that draws NOTHING — used by a BUS row's `enableCheckbox`
/// so the checkbox stays a real, focusable, keyboard- and VoiceOver-operable
/// `.switch` button while the ``MembershipBusView`` node is its only visible
/// skin (spec §4.8 "the real NSButton checkbox remains the control underneath …
/// only the DRAWING changes"). It suppresses the cell's own bezel/interior
/// rendering; state, target/action, keyEquivalent handling, and accessibility
/// all come from the un-subclassed `NSButtonCell`/`NSButton` machinery, untouched.
private final class InvisibleSwitchCell: NSButtonCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {}
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {}

    /// The keyboard focus ring traces the NODE, not the (invisible) switch
    /// glyph's box (spec §4.8): a circle centered on the cell frame — the
    /// checkbox is constrained centered on the node column, so this circle rings
    /// the drawn node with a small breathing gap.
    private func nodeRingRect(for cellFrame: NSRect) -> NSRect {
        let d = PopoverColumnGrid.busNodeDiameter + 4
        return NSRect(x: cellFrame.midX - d / 2, y: cellFrame.midY - d / 2, width: d, height: d)
    }

    override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect {
        nodeRingRect(for: cellFrame)
    }

    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSBezierPath(ovalIn: nodeRingRect(for: cellFrame)).fill()
    }
}
