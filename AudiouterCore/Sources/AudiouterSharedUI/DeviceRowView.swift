// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// A single device's controls (SPEC §9 "Device row"), hosted by the popover
/// (`PopoverController`) in an `NSStackView` — the "same row component" the
/// SPEC and PLAN-PHASE-1 §D call for: one implementation, one test surface.
///
/// The row's PRIMARY control is a "Selected Devices" membership `NSButton`
/// checkbox (SPEC §9 routing model); volume and a small secondary mute button
/// follow.
///
/// It lives in `AudiouterSharedUI` (not the popover target) so the
/// window target can link it without pulling in the whole dropdown;
/// `PopoverController` (the popover) is its host.
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
        /// The user clicked a greyed (paired-but-disconnected) BLUETOOTH row's
        /// name (BT-UI): "click connects" — the macOS-Bluetooth-menu behavior.
        /// The host maps this to a membership-free reconnect
        /// (`GroupController.requestReconnect` → `OutputBackend.retryOutput`);
        /// it never edits selection. Default no-op for non-BT hosts.
        func deviceRowDidRequestReconnect(_ row: DeviceRowView)
        /// The user changed this Bluetooth row's SYNC trim (BT-OFFSET-UI) —
        /// already clamped to ±`BTSyncTrim.rangeMs`. Fired by the − / +
        /// stepper (`coarseStepMs` steps) and by typing in the value field
        /// (1 ms). Default no-op for hosts without the SYNC column.
        func deviceRow(_ row: DeviceRowView, didSetSyncTrimMs ms: Double, for id: String)
        /// The user toggled this Bluetooth row's align-by-ear tick button
        /// (BT-OFFSET-UI). Default no-op for hosts without the SYNC column.
        func deviceRow(_ row: DeviceRowView, didToggleAlignTick active: Bool, for id: String)
    }

    /// Control-Center row density: comfortable height that seats a mini switch,
    /// icon, a two-line name/status stack, CC slider and mute button with
    /// breathing room in a card (CC rows read ~34–40pt; 38 landed in that band
    /// before the status sublabel — brief §6 sanctions bumping this constant
    /// once a second text line needs the room, which it does: two 10pt lines
    /// plus their line gap don't fit 38pt without crowding the slider/switch).
    /// Sourced from `PopoverColumnGrid.bodyRowHeight` — both row types share
    /// one body-row dimension.
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
    /// deleted). The icon's corner now hosts the gold route-armed dot (§3.3).
    /// See ``HaloRingView``.
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
    /// The single sublabel line under the name (Warm Signal v4.1 item 3 —
    /// re-scoped from the retired routing ladder): carries ONLY state words now.
    /// The one remaining rung is the small-caps MUTED token, shown iff the
    /// device is row-muted (not master-muted) AND neither failed nor
    /// unavailable — see ``resolveSublabel()``. Failed/unavailable and the
    /// routing/redirect composite all moved to ``feedStack`` (the FEED column).
    private let statusLabel = NSTextField(labelWithString: "")
    /// The trailing **FEED** column: a LEFT-ALIGNED row of small bordered
    /// pills (`FeedPillView`, one per visible feed value — the product
    /// owner's ported-verbatim call against the old single packed-string
    /// composite joined by " · "), hosted in a plain horizontal `NSStackView`.
    /// The neutral main-mix segment (``mainMixSourceName``, "System" or the
    /// active group's name) gets a plain pill; one tinted pill per redirected
    /// app (``feedAppNames``) carries the derived-colour `FeedChip` square
    /// INSIDE it, beside the name. A `.failed`/unavailable device OVERRIDES
    /// this with a SINGLE failure-red pill instead ("Couldn't connect" /
    /// "Unavailable"), no chip. Mounted and constrained ONLY on a bus row
    /// (``busActive``) — that's the one host where the trailing control column
    /// (`PopoverColumnGrid.trailingControlWidth`, centered at
    /// `trailingControlCenterFromTrailing`) is otherwise reserved-but-EMPTY
    /// (the membership control moved to the left rail gutter on a bus row), so
    /// there is a free slot to draw into; a non-bus host (mixer window) keeps
    /// its real checkbox there and never mounts this stack. See
    /// ``updateFeedText()``.
    private let feedStack = NSStackView()
    /// The FEED column's main-mix segment text, or `nil` when this row is not
    /// currently a member of the ACTIVE main-mix target (a redirect-only row
    /// can still show app segments alone). "System" for a manual Selected-
    /// Devices member, the active group's name when Main Out targets a saved
    /// group (``apply``'s `mainOutTargetsGroupName`). Recomputed every
    /// `apply`; read by both ``updateFeedText()`` and the VoiceOver feed
    /// clause so the visual and spoken channels can't drift apart.
    private var mainMixSourceName: String?
    /// The FEED column's redirect-app segment list — the CONFIRMED live set
    /// (`liveAppNames`) when non-empty, else the routing INTENT set
    /// (`routedAppNames`), mirroring the retired sublabel's own T9 precedence.
    /// Recomputed every `apply`.
    private var feedAppNames: [String] = []
    /// The host-supplied per-app tether tint (Warm Signal v4.1 CORRECTIONS,
    /// extending T7/item 7): app display name → `AppTetherColor`-derived
    /// color, computed once per bundle id and cached there — this row only
    /// looks names up, it never derives a color itself (it doesn't hold app
    /// icons/bundle ids, only the display names `feedAppNames` carries). Set
    /// every `apply`; read by ``appSegmentColor(for:)``.
    private var appTintColors: [String: NSColor] = [:]
    /// Whether the row's controls currently render the "muted-unconnected"
    /// treatment (v4 §Call-1 + v4.1 item 8): desaturated fader/readout AND —
    /// new in item 8 — dimmed FEED text. Stored (not just a local in
    /// ``apply``) so ``updateFeedText()`` dims the composite the same way
    /// ``faderCell``/``readoutLabel`` already do. Set every `apply`.
    private var controlsMuted = false
    /// `device.connectionState` as of the PREVIOUS `apply`, `nil` before the
    /// first one. Tracked ONLY to detect the item-8 "successful connect" EDGE
    /// (connecting/reconnecting → connected) that triggers ``brightenOnConnect()``
    /// — a pure animation trigger, never read by any model/routing logic.
    private var previousConnectionState: ConnectionState?
    /// The **energize "press-play" pending beat** (Warm Signal v4.1 item 9): a
    /// DRAWING-ONLY flag the host raises on the members of a Main-Audio source
    /// switch that haven't started connecting yet (`connectionState == .off`),
    /// so at the switch instant the rail drops to ember PENDING and those nodes
    /// render hollow-dashed (`MembershipBusView.Node.pending`) BEFORE the
    /// backend reports `.connecting`. It NEVER changes the model — the moment
    /// the device's real `connectionState` leaves `.off` (→ `.connecting`, then
    /// `.member`), that model state supersedes this beat in ``updateBus()``, so
    /// the host can leave the flag raised and the node still hands off cleanly.
    /// Gated OFF under Reduce Motion (the beat is the sweep — "removes the
    /// animation entirely, snap to resolved", spec item 9). Set every `apply`;
    /// defaults off so non-energize callers are byte-for-byte unchanged.
    private var energizePending = false
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

    // MARK: Bluetooth SYNC cluster (BT-OFFSET-UI)

    /// Whether this row carries the SYNC cluster — the popover passes `true`
    /// for `.bluetooth` rows only. The cluster occupies the LEFT portion of
    /// the reserved trailing slot; the FEED pill right-aligns into
    /// `PopoverColumnGrid.btFeedReserveWidth` beside it (feed pill far right,
    /// locked spec). Non-sync rows are byte-for-byte unchanged.
    private let showsSyncControls: Bool
    private let syncMinusButton = NSButton()
    private let syncPlusButton = NSButton()
    /// The editable bare-ms value field: − / + step by
    /// `BTSyncTrim.coarseStepMs`; typing here commits at 1 ms (house rule —
    /// bare numbers with units in numeric controls; the subsection header's
    /// SYNC title + the field's tooltip carry the unit).
    private let syncField = NSTextField()
    /// The align-by-ear toggle (`metronome.fill`, outline fallback).
    private let alignButton = NSButton()
    /// The trim the host last applied (also the revert value for unparseable
    /// typing).
    private var syncTrimMs: Double = 0
    /// Which metronome SF Symbol actually resolved (fill preferred).
    private var alignSymbolName = ""
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
               showsBus: Bool = false, showsSyncControls: Bool = false) {
        self.device = device
        self.indented = indented
        self.showsToggle = showsToggle
        self.paintsSelectionBackground = paintsSelectionBackground
        self.showsMeter = showsMeter
        self.showsBus = showsBus
        self.showsSyncControls = showsSyncControls
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: Self.rowHeight))
        // Fill the host's width, keep a fixed height (brief §2).
        autoresizingMask = [.width]
        translatesAutoresizingMaskIntoConstraints = true
        buildSubviews()
        apply(device)
        configureAccessibility()
        // Item 8/9's motion-gating rule: reconcile a mid-session Reduce
        // Motion toggle by cancelling an in-flight brighten cross-fade (see
        // `accessibilityDisplayOptionsDidChange`). Registered after the
        // above so this instance's `self` is fully initialized first.
        // Selector-based observation needs no matching `removeObserver` —
        // AppKit auto-unregisters on dealloc since 10.11 (same reasoning as
        // `RouteArmedDotView`).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
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
    ///   - mainOutTargetsGroupName: the ACTIVE Main Out target's saved-group
    ///     name when it currently targets a group, else `nil` (targets
    ///     Selected Devices). Drives the FEED column's main-mix segment
    ///     wording (Warm Signal v4.1 item 3): "System" when `nil`, the
    ///     group's name when non-nil — applied ONLY on a row that is a member
    ///     of that active target (`inActiveTarget`); a non-member shows no
    ///     main-mix segment regardless of this value. Defaults to `nil` so
    ///     every existing caller keeps showing "System", unchanged.
    ///   - iconSymbolName: an explicit SF Symbol name override for the icon
    ///     glyph, resolved through ``DeviceIcon/resolve(_:default:)`` (so an
    ///     unknown/invalid name falls back to `device.kind.symbolName`).
    ///     Defaults to `nil`, in which case the row behaves exactly as before —
    ///     `device.kind.symbolName` is used directly. Existing callers all omit
    ///     this, so their behavior is byte-for-byte unchanged.
    ///   - appTintColors: display name → `AppTetherColor`-derived tint for
    ///     every app the HOST currently has a route for (Warm Signal v4.1
    ///     CORRECTIONS, extending T7/item 7) — the same map the host builds
    ///     for the matching App Exceptions row, so both ends of a tether
    ///     agree on the color. Only names appearing in ``feedAppNames`` are
    ///     ever looked up; an unmapped name falls back to
    ///     `AppTetherColor.neutralFallback` (see ``appSegmentColor(for:)``).
    ///     Defaults to empty so a caller that never redirects anything here
    ///     is unaffected.
    public func apply(_ device: Device,
                      selected: Bool,
                      controllable: Bool = false,
                      blocked: Bool = false,
                      blockReason: String? = nil,
                      selectionDimmed: Bool = false,
                      routedAppNames: [String] = [],
                      liveAppNames: [String] = [],
                      appTintColors: [String: NSColor] = [:],
                      masterMuted: Bool = false,
                      inActiveTarget: Bool? = nil,
                      mainOutTargetsGroupName: String? = nil,
                      energizePending: Bool = false,
                      iconSymbolName: String? = nil,
                      syncTrimMs: Double = 0,
                      alignTickActive: Bool = false) {
        self.device = device
        self.isSelectedInSet = selected
        self.isToggleBlocked = blocked
        self.energizePending = energizePending
        self.blockReasonText = blocked ? blockReason : nil
        // Any model refresh (select OR deselect) clears a transient hover so the
        // row can't keep a stale hover wash after the pointer left the popover
        // (T-U8 root-cause fix — hover is transient, selection is model-driven).
        self.isHovered = false

        // Primary membership control: ON iff the device is in the Selected
        // Devices set. Don't fight a live toggle animation. Group-member rows
        // hide the toggle entirely (task C) — membership there is fixed.
        //
        // Enablement is INTENT-derived, not availability-derived (live bug,
        // 2026-08-06): the native backend's failure paths force
        // `isAvailable = false` while the user's selection intent stays true,
        // and an intent control that renders ON but can never be turned OFF is
        // a dead end — every deselect affordance (checkbox hit-test, name
        // click, node click, keyboard/VoiceOver) rides this one flag, so a
        // stuck-`.failed` row was physically un-deselectable. A SELECTED row
        // therefore keeps a live toggle regardless of availability; an
        // unavailable+UNselected row keeps the dead toggle (nothing to drop).
        enableCheckbox.state = selected ? .on : .off
        enableCheckbox.isEnabled = showsToggle && (device.isAvailable || selected) && !blocked
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
        // The icon is ALWAYS neutral: identity only, no
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

        // FEED column (v4.1 item 3): main-mix segment wording — "System" for a
        // manual member, the active group's name for a group-target member;
        // `nil` for a non-member (no main-mix segment; a redirect-only row may
        // still show app segments alone). Stored so `updateFeedText()`/the
        // VoiceOver feed clause share one source of truth.
        self.mainMixSourceName = activeMember ? (mainOutTargetsGroupName ?? "System") : nil
        self.feedAppNames = liveAppNames.isEmpty ? routedAppNames : liveAppNames
        self.appTintColors = appTintColors
        // The fader's engaged (gold) fill reuses the EXACT same predicate the
        // dot renders — one armed truth, two instruments (spec §3.3 / §5).
        faderCell.isRouteArmed = isRouteArmed
        // Muted-unconnected controls (v4 §Call-1 + v4.1 item 8): a
        // connecting/reconnecting or failed device — or an unavailable one —
        // renders its controls muted (desaturated + lower-contrast), "not
        // adjustable right now"; a connected member is full-gold. Drives the
        // fader dim, the readout tint, and (item 8) the FEED composite's dim
        // below. Stored on `self` (not just local) so `updateFeedText()`
        // reads the same value.
        switch device.connectionState {
        case .connecting, .reconnecting, .failed: controlsMuted = true
        case .connected, .off:                    controlsMuted = !device.isAvailable
        }
        faderCell.isMutedControl = controlsMuted

        // Item 8's brighten EDGE — "on successful connect it brightens to
        // full gold/normal": fires ONLY on a connecting/reconnecting →
        // connected transition (off `connectionState` alone, not the broader
        // `controlsMuted`, which also covers unavailable/failed flaps that
        // must NOT brighten). A `.failed` landing fires nothing — spec item 8
        // "on failure it stays muted and the FEED shows the red error"; the
        // red override alone carries that, no animation. Must run BEFORE
        // `resolveSublabel()`/`updateFeedText()`/the bus below actually
        // mutate the drawn state, so the added `CATransition` captures the
        // pre-brighten snapshot to cross-dissolve FROM.
        let wasConnectingOrReconnecting: Bool
        if let previous = previousConnectionState {
            switch previous {
            case .connecting, .reconnecting: wasConnectingOrReconnecting = true
            default: wasConnectingOrReconnecting = false
            }
        } else {
            wasConnectingOrReconnecting = false
        }
        previousConnectionState = device.connectionState
        if wasConnectingOrReconnecting && isConnected {
            brightenOnConnect()
        }

        // Sublabel (state words only, v4.1 item 3) + FEED column (the routing
        // composite / failure override), each with their own single ladder —
        // evaluated here after `device`/`isSelectedInSet`/`isMasterMuted`/
        // `mainMixSourceName`/`feedAppNames` are set so both are unambiguous.
        resolveSublabel()
        updateFeedText()

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

        // Bluetooth SYNC cluster (BT-OFFSET-UI): show the host's trim value;
        // a DISCONNECTED row keeps the saved value visible READ-ONLY (locked
        // spec). Never stomp the field mid-edit — a background repaint while
        // the user types would eat their keystrokes.
        if showsSyncControls {
            self.syncTrimMs = BTSyncTrim.clamp(syncTrimMs)
            if syncField.currentEditor() == nil {
                syncField.stringValue = Self.formattedTrim(self.syncTrimMs)
            }
            let adjustable = device.isAvailable
            syncField.isEditable = adjustable
            syncField.isSelectable = adjustable
            syncField.textColor = adjustable ? Tokens.Color.label : Tokens.Color.tertiaryLabel
            syncMinusButton.isEnabled = adjustable
            syncPlusButton.isEnabled = adjustable
            alignButton.isEnabled = adjustable
            alignButton.state = alignTickActive ? .on : .off
            alignButton.contentTintColor = alignTickActive
                ? Tokens.Color.accent : Tokens.Color.secondaryLabel
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
        var isConnectingNow: Bool {
            switch device.connectionState {
            case .connecting, .reconnecting: return true
            default: return false
            }
        }
        if isToggleBlocked {
            node = .blocked              // §4.6 greyed hollow node
        } else if device.isBluetooth, !device.isAvailable, isConnectingNow {
            // BT reconnect attempt (BT-UI): a greyed row's click starts a
            // baseband reconnect while `isAvailable` is STILL false (the
            // endpoint only appears on success), so without this branch the
            // unavailable arm below would hide the in-flight state the spec's
            // node vocabulary requires ("the node's connecting state during a
            // reconnect attempt"). AirPlay rows never pair `.connecting` with
            // unavailable, so this is BT-scoped on purpose.
            node = .connecting
        } else if !device.isAvailable {
            // Unavailable signature (spec §3.6 matrix): a HOLLOW, tinted node the
            // line detours — an unavailable device is not currently in the mix,
            // whatever its held checkbox state says. The `Unavailable` sublabel +
            // row-level text dim keep it distinct from blocked (R5).
            node = .nonMember
            dim = true
        } else if energizePending, !reduceMotion, case .off = device.connectionState {
            // Energize "press-play" pending beat (v4.1 item 9): a member of a
            // source switch that hasn't started connecting yet renders the
            // hollow ember DASHED pending node ON the spine, instantly, before
            // the backend reports `.connecting`. Guarded to `.off` so the beat
            // never overrides a real in-flight/resolved state — the moment
            // `connectionState` advances, the branches below take over. Reduce
            // Motion drops the beat entirely (the node falls through to its
            // settled member/non-member rendering — "snap to resolved").
            node = .pending
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

    // MARK: Connect-edge brighten (v4.1 item 8)

    /// `CALayer` reserves this EXACT string for a `CATransition` — regardless
    /// of what key you pass to `add(_:forKey:)`, a `CATransition` is always
    /// filed under `"transition"` (verified empirically: a custom key is
    /// silently ignored). `layer.animation(forKey:)`/`removeAnimation(forKey:)`
    /// must use this same reserved key to see/cancel it — a private
    /// project-specific key here would just never match.
    private static let brightenTransitionKey = "transition"

    /// Reduce Motion override seam — mirrors `RouteArmedDotView`/
    /// `HaloRingView`. `nil` (the default) reads the live workspace value; a
    /// test drives BOTH sides of the toggle by setting this then posting the
    /// real `accessibilityDisplayOptionsDidChangeNotification`.
    public var test_reduceMotionOverride: Bool?

    private var reduceMotion: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Live accessibility-display reconcile (item 8/9's shared motion-gating
    /// rule — "Reduce Motion removes the animation entirely"): if Reduce
    /// Motion just turned ON, strip any in-flight brighten cross-fade so the
    /// row lands on its already-settled (model) state instantly instead of
    /// finishing a transition the user asked not to see. Nothing else needs
    /// re-stamping here — every color this row paints is a plain dynamic
    /// `NSColor`/`Tokens.Color`, which AppKit already re-resolves on its own
    /// appearance-change path; only a raw `CALayer` animation (like this one,
    /// or `RouteArmedDotView`'s bloom) needs a manual cancel.
    @objc private func accessibilityDisplayOptionsDidChange() {
        if reduceMotion {
            layer?.removeAnimation(forKey: Self.brightenTransitionKey)
        }
        // Item 9's energize beat is gated on `reduceMotion` inside `updateBus`,
        // but that gate is read at draw-derivation time — a mid-flight Reduce
        // Motion toggle arrives through neither `apply` nor an appearance
        // change, so re-derive the node here so a raised `energizePending`
        // snaps to (or resumes from) its resolved rendering the instant the
        // user flips the setting. Idempotent + cheap; no-op off a bus row.
        updateBus()
    }

    /// One-shot CROSS-FADE from the muted-unconnected treatment to full gold/
    /// normal on a successful connect (v4.1 item 8 — "the per-device
    /// counterpart of the energize beat"). Called from `apply` BEFORE the
    /// rest of that method mutates the row's drawn state (fader fill,
    /// readout tint, FEED dim, bus node, meter reveal), so by the time this
    /// returns the layer already holds a pending transition to
    /// cross-dissolve FROM the pre-brighten snapshot TO whatever `apply`
    /// settles next — the exact "animate over settled presentation layers"
    /// contract `HaloRingView`/`RouteArmedDotView` established: the
    /// transition is self-removing (`isRemovedOnCompletion` default), so a
    /// `cacheDisplay` snapshot taken before or after it plays (never
    /// mid-flight) is byte-identical regardless of capture timing.
    /// No-op off screen (`window == nil` — covers the row's own `init`
    /// apply, which can never be a connect edge anyway) or under Reduce
    /// Motion (a snap to the already-resolved state, matching item 9).
    private func brightenOnConnect() {
        guard window != nil, !reduceMotion else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = PopoverColumnGrid.routeArmedBloomDuration
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(transition, forKey: Self.brightenTransitionKey)
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

    // `apply` drives `HaloRingView.apply(_:)` directly — same idempotent reset,
    // so a repeated `apply` can't leave a stale breathing animation running —
    // and routes every sublabel through `resolveSublabel()`'s ladder (failed =
    // its highest rung).

    /// On a **bus row** the sublabel carries ONLY state words now (Warm Signal
    /// v4.1 item 3 — the routing/failure content that used to live here moved
    /// to the FEED column, ``updateFeedText()``): a ROW-muted (never master-
    /// muted — the Main Out pill carries that) device that is neither failed
    /// nor unavailable shows the small-caps MUTED token alone; every other
    /// state hides the sublabel. A **non-bus row** (mixer window / a generic
    /// caller) has no FEED column to fall back on — it keeps the FULL legacy
    /// ladder (``resolveLegacySublabel()``) so that host doesn't silently lose
    /// failed/unavailable/routing information v4.1 never gave it anywhere else
    /// to go.
    private func resolveSublabel() {
        guard busActive else {
            resolveLegacySublabel()
            return
        }
        if case .failed = device.connectionState {
            hideSublabel()
        } else if !device.isAvailable {
            hideSublabel()
        } else if device.isMuted && !isMasterMuted {
            showMutedSublabel()
        } else {
            hideSublabel()
        }
    }

    /// The pre-v4.1 sublabel precedence ladder (failed → unavailable →
    /// routing[+MUTED] → none), preserved verbatim for a non-bus host. Reuses
    /// ``mainMixSourceName``/``feedAppNames`` (the same precedence-resolved
    /// values the FEED column reads) rather than re-deriving them, so the two
    /// paths can never drift out of agreement on WHAT the current mix/redirect
    /// state is — only on where it's drawn.
    private func resolveLegacySublabel() {
        if case .failed = device.connectionState {
            // Failure-exclusive red (spec §2/§3.5/R8) — paired with the red
            // failed halo ring.
            showSublabel("Couldn't connect", color: Tokens.Color.failure)
        } else if !device.isAvailable {
            showSublabel("Unavailable", color: Tokens.Color.tertiaryLabel)
        } else if let routing = legacyRoutingLine() {
            // S3 (spec §3.5): a ROW-muted device prepends the small-caps MUTED
            // token to its EXISTING feed sublabel — never to a single-line row
            // (this branch only runs when a sublabel already exists, so the
            // row height is untouched — R7 no-reflow, this host only). Master
            // mute adds NO token (matrix §3.6: the Main Out pill carries it).
            if device.isMuted && !isMasterMuted {
                showLegacyMutedSublabel(feeds: routing)
            } else {
                showSublabel(routing, color: Tokens.Color.secondaryLabel)
            }
        } else {
            hideSublabel()
        }
    }

    /// `mainMixSourceName` + `feedAppNames` joined exactly as the retired
    /// routing line used to (`"System · <apps>"`) — the non-bus host's own
    /// composite, kept separate from the FEED column's segment/color
    /// machinery since it renders as plain text on one label.
    private func legacyRoutingLine() -> String? {
        var tokens: [String] = []
        if let mainMixSourceName { tokens.append(mainMixSourceName) }
        tokens.append(contentsOf: feedAppNames)
        guard !tokens.isEmpty else { return nil }
        return tokens.joined(separator: Self.routingTokenSeparator)
    }

    /// Show the sublabel as the standalone small-caps `MUTED` token (spec §2
    /// micro-label voice — SF Mono bold, tracked, uppercase) — the bus-row
    /// case, where the feed list lives in its own column so MUTED needs no
    /// existing line to piggyback on.
    private func showMutedSublabel() {
        statusLabel.isHidden = false
        statusLabel.attributedStringValue = NSAttributedString(
            string: "MUTED",
            attributes: [.font: Tokens.Font.microLabel,
                         .kern: Tokens.Font.microLabelKern,
                         .foregroundColor: Tokens.Color.secondaryLabel])
        statusLabel.textColor = Tokens.Color.secondaryLabel
        applyNameStackLayout(twoLine: true)
    }

    /// Show the sublabel as `MUTED · <feeds>` — the non-bus host's own rung,
    /// unchanged from pre-v4.1: the leading MUTED token in the micro-label
    /// voice with the feed list continuing in the sublabel's own 10 pt voice.
    private func showLegacyMutedSublabel(feeds: String) {
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

    /// Retained as a pure precedence helper for ``test_sourceText(routedAppNames:liveAppNames:)``
    /// only — no production call site reads this anymore (both
    /// ``resolveLegacySublabel()`` and ``updateFeedText()`` read the shared
    /// ``mainMixSourceName``/``feedAppNames`` instead). Kept separate so the T9
    /// live-vs-intent precedence stays covered by its own focused test.
    private func routingLine(routedAppNames: [String], liveAppNames: [String]) -> String? {
        var tokens: [String] = []
        if isSelectedInSet { tokens.append("System") }
        tokens.append(contentsOf: liveAppNames.isEmpty ? routedAppNames : liveAppNames)
        guard !tokens.isEmpty else { return nil }
        return tokens.joined(separator: Self.routingTokenSeparator)
    }

    // MARK: FEED column — per-value bordered pills

    /// Separator used only to JOIN plain-text test reads across pills
    /// (``test_feedText``) — visually the gap between pills is now
    /// `PopoverColumnGrid.feedPillGap`, drawn as space between two bordered
    /// views, not a printed middle-dot glyph. Kept as the same " · " a test
    /// already expects between segment WORDS.
    private static let feedSegmentSeparator = " · "

    /// The one monochrome SF Mono uppercase micro-tag this column ever shows,
    /// prefixed ahead of the FIRST visible pill's own text for a true
    /// protocol exception. AP2 is the default and is never badged (spec item
    /// 3 "attributes/flags").
    private static let ap1FeedTag = "AP1"

    /// Re-derive and push the FEED column's pills from the current device/
    /// mix/redirect state (``mainMixSourceName``/``feedAppNames``, set by
    /// ``apply``). No-op — hides `feedStack` — when this row hosts no FEED
    /// column (`busActive` false: a non-bus host's trailing column is the real
    /// checkbox, not a free slot).
    ///
    /// Precedence (highest first, mirrors ``resolveSublabel()``'s split ladder
    /// but for the FEED half):
    /// 1. `.failed` connection → a SINGLE "Couldn't connect" pill, failure-red
    ///    (spec item 3 "error overrides the feed" — pairs with the red halo
    ///    ring).
    /// 2. else device unavailable → a single "Unavailable" pill, failure-red
    ///    (the spec groups both under "failure-red words").
    /// 3. else ONE PILL PER VALUE: `mainMixSourceName` (when non-nil) followed
    ///    by one pill per `feedAppNames` entry, in order — NEVER collapsed to
    ///    a single reason. Empty (nil main-mix AND no app names) renders no
    ///    pills at all.
    /// Connecting/reconnecting/buffering and muted are DELIBERATELY absent
    /// here (spec item 3) — the halo ring and the mute control/MUTED sublabel
    /// token own those signals; duplicating them would be noise.
    private func updateFeedText() {
        guard busActive else {
            clearFeedPills()
            return
        }
        if case .failed(let failure) = device.connectionState {
            // The failure HEADLINE, not a hardcoded generic (BT-UI locked spec:
            // "failure headline sublabel" — "Connected elsewhere"/"Not paired"
            // must read distinctly; `.unknown` still renders "Couldn't
            // connect", so AirPlay's common case is unchanged). Copy lives on
            // `ConnectionFailure` — single source shared with the panel.
            setFeedText(failure.headline, color: Tokens.Color.failure)
            return
        }
        if !device.isAvailable {
            // A BT reconnect attempt keeps `isAvailable == false` until the
            // endpoint appears — the connecting ring/node carry that state, so
            // don't shout "Unavailable" over an attempt still in flight.
            var isConnectingNow: Bool {
                switch device.connectionState {
                case .connecting, .reconnecting: return true
                default: return false
                }
            }
            if !(device.isBluetooth && isConnectingNow) {
                setFeedText("Unavailable", color: Tokens.Color.failure)
                return
            }
        }
        var segments: [FeedSegment] = []
        // The neutral main-mix segment (spec item 3's own word "carries" the
        // reason) NEVER wears a chip — only a redirected app does (v4.1
        // CORRECTIONS "keep neutral segments … untinted"). Item 8: while the
        // row is in the muted-unconnected treatment, both segment kinds dim —
        // the neutral word drops to `tertiaryLabel`, an app's tether tint
        // desaturates (never discarded outright, so the association still
        // reads once the row brightens back).
        let neutralColor = controlsMuted ? Tokens.Color.tertiaryLabel : Tokens.Color.secondaryLabel
        if let mainMixSourceName { segments.append(.init(text: mainMixSourceName, color: neutralColor, hasChip: false)) }
        for name in feedAppNames {
            var color = appSegmentColor(for: name)
            if controlsMuted { color = color.withAlphaComponent(Self.feedMutedTintAlpha) }
            segments.append(.init(text: name, color: color, hasChip: true))
        }
        let tag = device.supportsAirPlay2 ? nil : Self.ap1FeedTag
        setFeedSegments(segments, tag: tag)
    }

    /// Alpha applied to an app-tint FEED segment while the row is in the
    /// muted-unconnected treatment (v4.1 item 8's "muted feed text") —
    /// desaturates the tether tint rather than discarding it, so the
    /// app↔device association still reads once the row brightens back.
    private static let feedMutedTintAlpha: CGFloat = 0.5

    /// One FEED value: its text, its resolved color, and whether it wears the
    /// derived-colour chip (an app-redirect value does; the neutral main-mix
    /// value never does) — each renders as its own `FeedPillView`.
    private struct FeedSegment {
        let text: String
        let color: NSColor
        let hasChip: Bool
    }

    /// Resolves the tint for one FEED app-name segment (Warm Signal v4.1
    /// CORRECTIONS, extending T7/item 7): the host-supplied ``appTintColors``
    /// map (an `AppTetherColor` tint per bundle id, computed and cached
    /// there), keyed by display name since that's all this row carries for a
    /// feed entry. A name the host never mapped (defensive — every real
    /// caller populates the map from the same routes that produced
    /// `feedAppNames`) falls back to `AppTetherColor.neutralFallback` rather
    /// than the flat `secondaryLabel` a neutral segment uses, so an app
    /// segment always reads as "a specific app," never as the neutral word.
    private func appSegmentColor(for appName: String) -> NSColor {
        appTintColors[appName] ?? AppTetherColor.neutralFallback
    }

    /// Empty `feedStack` and hide it — the "nothing to show at all" case
    /// (non-bus host, or a bus row with no main-mix membership and no
    /// redirects).
    private func clearFeedPills() {
        for view in feedStack.arrangedSubviews {
            feedStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        feedStack.isHidden = true
    }

    /// Render a SINGLE failure-red pill (no tag, no chip) — the "Couldn't
    /// connect" / "Unavailable" rungs.
    private func setFeedText(_ text: String, color: NSColor) {
        let attr = NSAttributedString(
            string: text, attributes: [.font: Tokens.Font.caption, .foregroundColor: color])
        renderFeedPills([(attributedText: attr, isError: true)])
    }

    /// Compose `segments` (main-mix + app tokens, already colored) into ONE
    /// PILL EACH, prefixing `tag` (the AP1 micro-tag) onto the FIRST visible
    /// pill's own text when present, with the spec item 3 STATIC overflow
    /// rule: try showing every value's pill first; if the row of pills
    /// doesn't fit `PopoverColumnGrid.feedColumnWidth`, drop values from the
    /// TAIL one at a time (never cut a pill mid-string) and append a trailing
    /// "+N" pill for the dropped count — no interactive reveal, locked.
    /// Clears the pills when there is nothing to show at all.
    private func setFeedSegments(_ segments: [FeedSegment], tag: String?) {
        guard !segments.isEmpty else {
            clearFeedPills()
            return
        }
        let font = Tokens.Font.caption
        // Item 8: the "+N" overflow pill and the AP1 micro-tag dim in
        // lockstep with the pills they sit beside — the same `controlsMuted`
        // gate ``updateFeedText()`` used to build `segments`.
        let chromeColor = controlsMuted ? Tokens.Color.tertiaryLabel : Tokens.Color.secondaryLabel

        func attributed(_ segment: FeedSegment, prefixTag: Bool) -> NSAttributedString {
            let result = NSMutableAttributedString()
            if prefixTag, let tag {
                result.append(NSAttributedString(string: tag + " ", attributes: [
                    .font: Tokens.Font.microLabel, .kern: Tokens.Font.microLabelKern,
                    .foregroundColor: chromeColor,
                ]))
            }
            // The chip (Warm Signal v4.1 CORRECTIONS "[chip] Music," now
            // living INSIDE the pill beside the name) — an app segment only,
            // never the neutral main-mix segment.
            if segment.hasChip {
                result.append(FeedChip.attachmentString(color: segment.color, font: font))
            }
            result.append(NSAttributedString(string: segment.text, attributes: [.font: font, .foregroundColor: segment.color]))
            return result
        }

        /// A pill's own outer width — the label's ink plus the pill's own
        /// padding — so the STATIC overflow measurement accounts for the
        /// bordered chrome around each value, not just its bare text.
        func pillWidth(_ attr: NSAttributedString) -> CGFloat {
            attr.size().width + PopoverColumnGrid.feedPillHorizontalPadding * 2
        }

        /// The "+N" pill itself, optionally wearing the AP1 tag — used both
        /// as the trailing pill alongside visible value pills and, when even
        /// ONE value pill can't fit beside it, as the composite's SOLE pill.
        func overflowPill(count: Int, prefixTag: Bool) -> NSAttributedString {
            let result = NSMutableAttributedString()
            if prefixTag, let tag {
                result.append(NSAttributedString(string: tag + " ", attributes: [
                    .font: Tokens.Font.microLabel, .kern: Tokens.Font.microLabelKern,
                    .foregroundColor: chromeColor,
                ]))
            }
            result.append(NSAttributedString(string: "+\(count)", attributes: [.font: font, .foregroundColor: chromeColor]))
            return result
        }

        let available = PopoverColumnGrid.feedColumnWidth
        // A lone segment has no overflow GROUP to collapse into — the floor
        // stays "show the one clipped pill" (spec item 3, "a clipped single
        // pill beats showing nothing"). But when there's a genuine overflow
        // group (2+ segments), a value pill plus "+N" can BOTH overflow the
        // column — left-aligned layout then clips the trailing "+N" down to
        // an unreadable sliver instead of the (lower-priority) value pill.
        // In that case drop the value pill too and show a bare "+N" — an
        // accurate, legible count beats a barely-visible fragment of one.
        let minVisibleCount = segments.count > 1 ? 0 : 1

        var visibleCount = segments.count
        var committed: [NSAttributedString] = []
        while true {
            let overflowCount = segments.count - visibleCount
            var trial: [NSAttributedString] = visibleCount > 0
                ? segments.prefix(visibleCount).enumerated().map { index, segment in
                    attributed(segment, prefixTag: index == 0)
                  }
                : []
            if overflowCount > 0 {
                trial.append(overflowPill(count: overflowCount, prefixTag: visibleCount == 0))
            }
            let totalWidth = trial.map(pillWidth).reduce(0, +)
                + CGFloat(max(0, trial.count - 1)) * PopoverColumnGrid.feedPillGap
            if totalWidth <= available || visibleCount == minVisibleCount {
                committed = trial
                break
            }
            visibleCount -= 1
        }
        renderFeedPills(committed.map { (attributedText: $0, isError: false) })
    }

    /// Rebuild `feedStack`'s arranged subviews from `pills` — one
    /// `FeedPillView` per entry, in order. Rebuilding on every `apply` (rather
    /// than diffing/reusing views) keeps this in step with the rest of the
    /// row's "re-derive from model state" discipline and is cheap: a device
    /// row's FEED column holds at most a handful of pills.
    private func renderFeedPills(_ pills: [(attributedText: NSAttributedString, isError: Bool)]) {
        clearFeedPills()
        guard !pills.isEmpty else { return }
        for pill in pills {
            let view = FeedPillView()
            view.configure(attributedText: pill.attributedText, isError: pill.isError)
            feedStack.addArrangedSubview(view)
        }
        feedStack.isHidden = false
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
    /// parameter's doc. The real host (the popover) passes `controllable`
    /// explicitly and never relies on this shim for a live row.
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

        // FEED column: a LEFT-ALIGNED row of bordered `FeedPillView`s, one per
        // visible feed value — `setFeedSegments` pre-measures and drops WHOLE
        // pills from the tail (STATIC "+N" overflow). Unlike the retired
        // plain-text `feedLabel` (which clipped excess CHARACTERS via
        // `.byClipping` when even its single most-important segment still
        // overflowed), a pill's own border/padding chrome isn't
        // compressible, so that same "accept the last candidate even if it
        // still overflows" rung would otherwise let a pill's frame extend
        // PAST this reserved slot — visibly spilling into the row's margin
        // rather than clipping cleanly. `masksToBounds` on the stack's own
        // layer reproduces the old "honest clipping fallback" at the PILL
        // level: an overflowing pill is cut off at the slot's edge instead of
        // drawn past it.
        feedStack.translatesAutoresizingMaskIntoConstraints = false
        feedStack.orientation = .horizontal
        feedStack.alignment = .centerY
        feedStack.distribution = .fill
        feedStack.spacing = PopoverColumnGrid.feedPillGap
        feedStack.isHidden = true
        feedStack.wantsLayer = true
        feedStack.layer?.masksToBounds = true

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
        // FEED column (v4.1 item 3): only a bus row has the free trailing slot.
        if busActive { addSubview(feedStack) }
        // Bluetooth SYNC cluster (BT-OFFSET-UI), sharing that slot's left
        // portion — sync rows re-anchor the FEED pill to the far right below.
        if showsSyncControls {
            configureSyncControls()
            addSubview(syncMinusButton)
            addSubview(syncField)
            addSubview(syncPlusButton)
            addSubview(alignButton)
        }

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
                feedStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            if showsSyncControls {
                // Bluetooth rows (BT-OFFSET-UI): the FEED pill hugs the FAR
                // RIGHT of the slot (`btFeedReserveWidth` — locked spec) so
                // the SYNC cluster can take the slot's left portion; the
                // stack's existing mask clips an overlong pill at the reserve's
                // edge, same honest-clipping fallback as elsewhere.
                constraints.append(contentsOf: [
                    feedStack.trailingAnchor.constraint(
                        equalTo: trailingAnchor,
                        constant: -PopoverColumnGrid.trailingInset),
                    feedStack.widthAnchor.constraint(
                        lessThanOrEqualToConstant: PopoverColumnGrid.btFeedReserveWidth),
                    // The cluster, trailing→leading: align · + · value · −.
                    alignButton.trailingAnchor.constraint(
                        equalTo: trailingAnchor,
                        constant: -PopoverColumnGrid.syncTrailing),
                    alignButton.widthAnchor.constraint(
                        equalToConstant: PopoverColumnGrid.syncAlignButtonWidth),
                    alignButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                    syncPlusButton.trailingAnchor.constraint(
                        equalTo: alignButton.leadingAnchor,
                        constant: -PopoverColumnGrid.syncAlignGap),
                    syncPlusButton.widthAnchor.constraint(
                        equalToConstant: PopoverColumnGrid.syncStepperButtonWidth),
                    syncPlusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                    syncField.trailingAnchor.constraint(
                        equalTo: syncPlusButton.leadingAnchor,
                        constant: -PopoverColumnGrid.syncControlGap),
                    syncField.widthAnchor.constraint(
                        equalToConstant: PopoverColumnGrid.syncValueFieldWidth),
                    syncField.centerYAnchor.constraint(equalTo: centerYAnchor),
                    syncMinusButton.trailingAnchor.constraint(
                        equalTo: syncField.leadingAnchor,
                        constant: -PopoverColumnGrid.syncControlGap),
                    syncMinusButton.widthAnchor.constraint(
                        equalToConstant: PopoverColumnGrid.syncStepperButtonWidth),
                    syncMinusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                ])
            } else {
                // FEED column: the trailing control column is otherwise empty
                // on a bus row (the membership control moved to the left rail
                // gutter above) — draw the pill row there. LEFT-ALIGNED
                // (product owner's call, reverting the old composite's
                // right-alignment): the stack's LEADING edge is pinned to the
                // slot's own leading edge (the same physical slot the header's
                // trailing column label centers over — `trailingControlCenterFromTrailing`
                // — just anchored from its other end), so pills start flush
                // left within the reserved column instead of hugging its
                // trailing edge.
                constraints.append(contentsOf: [
                    feedStack.leadingAnchor.constraint(
                        equalTo: trailingAnchor,
                        constant: -(PopoverColumnGrid.trailingControlTrailing + PopoverColumnGrid.trailingControlWidth)),
                    feedStack.widthAnchor.constraint(
                        lessThanOrEqualToConstant: PopoverColumnGrid.trailingControlWidth),
                ])
            }
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

    // MARK: Bluetooth SYNC cluster (BT-OFFSET-UI)

    /// The align button's hover tooltip — the affordance is a bare glyph, so
    /// the tooltip carries its whole story.
    static let alignTooltip =
        "Play alignment ticks on this speaker and the rest of the group — adjust sync until they land as one"

    private func configureSyncControls() {
        for (button, symbol, label, action) in [
            (syncMinusButton, "minus", "Decrease sync offset", #selector(syncMinusTapped(_:))),
            (syncPlusButton, "plus", "Increase sync offset", #selector(syncPlusTapped(_:))),
        ] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .accessoryBar
            button.isBordered = false
            button.imagePosition = .imageOnly
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(config)
            button.contentTintColor = Tokens.Color.secondaryLabel
            button.setAccessibilityLabel(label)
            button.toolTip = "\(Self.formattedTrim(BTSyncTrim.coarseStepMs)) ms steps — hold ⌥ for \(Self.formattedTrim(BTSyncTrim.fineStepMs)) ms"
            button.target = self
            button.action = action
        }

        syncField.translatesAutoresizingMaskIntoConstraints = false
        syncField.controlSize = .small
        syncField.font = Tokens.Font.caption
        syncField.alignment = .center
        syncField.bezelStyle = .roundedBezel
        syncField.toolTip = "Sync offset in milliseconds — ↑/↓ nudges 1 ms, ⌥↑/↓ 10 ms"
        syncField.setAccessibilityLabel("Sync offset in milliseconds")
        syncField.target = self
        syncField.action = #selector(syncFieldEdited(_:))
        // Return/arrow handling rides the field editor's command dispatch (the
        // NSTextFieldDelegate extension at file end): Return COMMITS and is
        // CONSUMED there — un-consumed, it bubbles past the field and closes
        // the popover with the edit lost (live finding).
        syncField.delegate = self

        alignButton.translatesAutoresizingMaskIntoConstraints = false
        alignButton.bezelStyle = .accessoryBar
        alignButton.setButtonType(.pushOnPushOff)
        alignButton.isBordered = false
        alignButton.imagePosition = .imageOnly
        // `metronome.fill` verified AppKit-resolvable; the outline `metronome`
        // stays as the defensive fallback (locked spec's own contingency).
        for name in ["metronome.fill", "metronome"] {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Align by ear")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)) {
                alignButton.image = image
                alignSymbolName = name
                break
            }
        }
        alignButton.contentTintColor = Tokens.Color.secondaryLabel
        alignButton.toolTip = Self.alignTooltip
        alignButton.setAccessibilityLabel("Align by ear")
        alignButton.setAccessibilityHelp(Self.alignTooltip)
        alignButton.target = self
        alignButton.action = #selector(alignTapped(_:))
    }

    /// Whether ⌥ is held for the current stepper click — the fine-step
    /// modifier. Seam-overridable (`test_optionModifierOverride`) because a
    /// headless `performClick` carries no `NSApp.currentEvent`.
    private var optionIsHeld: Bool {
        test_optionModifierOverride ?? (NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)
    }

    /// Modifier seam for the stepper tests — same idiom as
    /// ``test_reduceMotionOverride``; `nil` (default) reads the live event.
    public var test_optionModifierOverride: Bool?

    @objc private func syncMinusTapped(_ sender: NSButton) {
        commitSyncTrim(syncTrimMs - (optionIsHeld ? BTSyncTrim.fineStepMs : BTSyncTrim.coarseStepMs))
    }

    @objc private func syncPlusTapped(_ sender: NSButton) {
        commitSyncTrim(syncTrimMs + (optionIsHeld ? BTSyncTrim.fineStepMs : BTSyncTrim.coarseStepMs))
    }

    /// Enter/typing commit: parse a signed integer (a trailing "ms" or spaces
    /// are tolerated); unparseable input reverts to the current value. Whole
    /// milliseconds only here — this row's plain field predates the drawer's
    /// decimal ruler (BT-SYNC-DRAWER T4/T5), which is where typed 0.1 ms
    /// input will land; parsing stays `Int` so this row's behavior is
    /// unchanged by the `Double` widening, and the result is just stored
    /// widened.
    @objc private func syncFieldEdited(_ sender: NSTextField) {
        let cleaned = sender.stringValue
            .replacingOccurrences(of: "ms", with: "")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "−", with: "-")   // typography minus
        commitSyncTrim(Int(cleaned).map(Double.init) ?? syncTrimMs)
    }

    private func commitSyncTrim(_ ms: Double) {
        let clamped = BTSyncTrim.clamp(ms)
        syncTrimMs = clamped
        syncField.stringValue = Self.formattedTrim(clamped)
        delegate?.deviceRow(self, didSetSyncTrimMs: clamped, for: device.id)
    }

    /// Bare-integer text for a whole-number ms value — identical to the
    /// pre-widening `Int` display for every value this row's plain stepper
    /// cluster (whole `coarseStepMs`/`fineStepMs` steps) can produce; one
    /// decimal place for anything finer, which only the drawer's 0.1 ms ruler
    /// (BT-SYNC-DRAWER T4+) can ever produce.
    private static func formattedTrim(_ ms: Double) -> String {
        ms.rounded() == ms ? String(Int(ms)) : String(format: "%.1f", ms)
    }

    @objc private func alignTapped(_ sender: NSButton) {
        // `pushOnPushOff` has already flipped the state; land the tint now so
        // the toggle reads immediately, before the host's re-apply echoes it.
        alignButton.contentTintColor = sender.state == .on
            ? Tokens.Color.accent : Tokens.Color.secondaryLabel
        delegate?.deviceRow(self, didToggleAlignTick: sender.state == .on, for: device.id)
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
        // A greyed Bluetooth row's click CONNECTS (BT-UI "click to connect" is
        // the row's ordinary click behavior, never a printed instruction).
        // Ordered before the enabled guard: an unavailable+unselected row's
        // checkbox is disabled, which is exactly the greyed case.
        if device.isBluetooth, !device.isAvailable {
            delegate?.deviceRowDidRequestReconnect(self)
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

    /// The value the slider is actually SHOWING — read from the control, not from
    /// the model that was handed to `apply`. That distinction is the point: it
    /// catches a row whose displayed level has drifted from what was painted.
    public var test_sliderValue: Int { slider.integerValue }

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
    ///
    /// NOTE: this calls the delegate method directly — it does NOT go through
    /// `enableCheckbox`'s real AppKit target/action wiring. That shortcut is
    /// fine for tests that only care about the resulting `SelectionResult`, but
    /// it can't catch a real dispatch regression (the row-selection lesson:
    /// `MainOutRowView.selectionChanged` broke while delegate-shortcut tests
    /// stayed green because AppKit's real sender didn't match what the shortcut
    /// assumed). Use ``test_performEnableClick()`` below when the real dispatch
    /// path itself is what's under test.
    public func test_toggleEnabled(_ on: Bool) {
        delegate?.deviceRow(self, didToggleEnabled: on, for: device.id)
    }

    /// Simulate a REAL user click on the primary "Selected Devices" membership
    /// checkbox via AppKit's own `NSButton.performClick(_:)` — this exercises
    /// the actual `enableCheckbox.target`/`.action` wiring set up in
    /// `buildSubviews()` (`enableToggled(_:)`), the same path a live mouse
    /// click drives, rather than calling the delegate method directly like
    /// ``test_toggleEnabled(_:)`` does. A no-op if the checkbox is currently
    /// disabled (mirrors what a real click would do).
    public func test_performEnableClick() {
        enableCheckbox.performClick(nil)
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
        // Mirrors the real gesture handler's greyed-BT branch (BT-UI).
        if device.isBluetooth, !device.isAvailable {
            delegate?.deviceRowDidRequestReconnect(self)
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
        // `.resting` (ring-resting-state task) is Main Audio-only — a device
        // row's `haloRingView.apply(_:)` call never passes `restingArmed`, so
        // this case is unreachable here; mapped defensively to `.none` (the
        // form `.off` would render without that bit) rather than widening
        // `StatusKind` for a form this view can never actually produce.
        case .resting:     return .none
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

    // MARK: FEED column test hooks

    /// Every `FeedPillView` CURRENTLY arranged in `feedStack`, in left-to-
    /// right order, or `[]` when there's nothing to show / this row hosts no
    /// FEED column at all (a non-bus host).
    private var feedPills: [FeedPillView] {
        guard busActive, !feedStack.isHidden else { return [] }
        return feedStack.arrangedSubviews.compactMap { $0 as? FeedPillView }
    }

    /// The FEED column's current plain-text content, or `nil` when it has
    /// nothing to show. Joins each pill's own text (chip object-replacement
    /// characters already stripped by `FeedPillView.test_text`) with the same
    /// " · " a test already reads between values — including a static
    /// "AP1 " prefix on the first pill, or a trailing "+N" pill, when
    /// present — so a test can assert the rendered WORDS across the whole
    /// pill row without parsing per-pill color runs itself.
    public var test_feedText: String? {
        let pills = feedPills
        guard !pills.isEmpty else { return nil }
        let text = pills.map(\.test_text).joined(separator: Self.feedSegmentSeparator)
        return text.isEmpty ? nil : text
    }

    /// The number of derived-colour chips CURRENTLY rendered across the FEED
    /// column's pills (Warm Signal — chip now lives INSIDE its pill) — one
    /// per app-redirect pill, never for the neutral main-mix pill or an error
    /// override. Reads each pill's own painted attachment run, so a test
    /// asserts what's actually painted.
    public var test_feedChipCount: Int {
        feedPills.filter(\.test_hasChip).count
    }

    /// Whether the FEED column is CURRENTLY rendering the failure-red override
    /// (`Couldn't connect` / `Unavailable`, spec item 3) — reads the (single)
    /// pill's resolved color (an error message is never mixed with normal
    /// pills), so a test can't drift from what's actually painted.
    public var test_feedIsErrorColored: Bool {
        feedPills.first?.test_isErrorColored ?? false
    }

    /// The FEED column's leading pill's CURRENTLY-painted foreground color
    /// (the neutral main-mix pill when not an error override) — item 8's
    /// "muted feed text" dims this from `secondaryLabel` to `tertiaryLabel`
    /// while ``controlsMuted``. Reads what's actually painted, like
    /// ``test_feedIsErrorColored``.
    public var test_feedNeutralColor: NSColor? {
        feedPills.first?.test_leadingRunColor
    }

    /// Whether the row is CURRENTLY rendering the muted-unconnected treatment
    /// (v4 §Call-1 + v4.1 item 8) — the same flag ``faderCell.isMutedControl``
    /// and the FEED dim above both read.
    public var test_controlsMuted: Bool { controlsMuted }

    /// Whether the item-8 connect-edge brighten CROSS-FADE is currently
    /// mid-flight — present on the layer the instant it's added (same idiom
    /// as `RouteArmedDotView.test_isBlooming`: no run loop needed to assert
    /// it fired).
    public var test_isBrightening: Bool {
        layer?.animation(forKey: Self.brightenTransitionKey) != nil
    }

    /// Whether the FEED column is currently showing the static "+N" overflow
    /// suffix (spec item 3 "locked" — capped visible segments, no interactive
    /// reveal).
    public var test_feedHasOverflow: Bool {
        guard let text = test_feedText else { return false }
        return text.range(of: #"\+\d+$"#, options: .regularExpression) != nil
    }

    /// Whether the FEED column is currently prefixed with the monochrome AP1
    /// micro-tag (spec item 3 "attributes/flags" — the one true-exception tag;
    /// AP2 is the default and is never badged).
    public var test_feedHasAP1Tag: Bool { test_feedText?.hasPrefix("\(Self.ap1FeedTag) ") == true }

    /// The color a FEED app-name segment for `appName` currently resolves to —
    /// the seam T7 rewires (``appSegmentColor(for:)``) to `AppTetherColor`.
    /// Exposed so a test can pin today's flat `secondaryLabel` value; T7's swap
    /// then shows up as an intentional, asserted change rather than silent drift.
    public func test_feedAppSegmentColor(for appName: String) -> NSColor {
        appSegmentColor(for: appName)
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

    /// The row's icon tint. Always `.secondaryLabelColor` (the
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

    /// Whether the under-name meter is on screen — the armed predicate's other
    /// instrument, and the half `test_meterLevel()` can't see (a pushed level
    /// on a hidden meter is invisible).
    public var test_meterVisible: Bool { showsMeter && !meterView.isHidden }

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

    // MARK: Bluetooth SYNC cluster (BT-OFFSET-UI) test hooks

    /// Whether this row mounts the SYNC cluster at all.
    public var test_showsSyncControls: Bool { showsSyncControls }

    /// The value field's CURRENTLY displayed text, or `nil` on a non-sync row.
    public var test_syncTrimDisplayed: String? {
        showsSyncControls ? syncField.stringValue : nil
    }

    /// Whether the cluster is currently adjustable (false = the disconnected
    /// row's read-only saved value).
    public var test_syncControlsEnabled: Bool {
        showsSyncControls && syncField.isEditable
            && syncMinusButton.isEnabled && syncPlusButton.isEnabled
    }

    /// Fire the − / + buttons through AppKit's own `performClick` — the real
    /// target/action dispatch, mirroring `test_performEnableClick` (a no-op
    /// while disabled, exactly like a live click).
    public func test_fireSyncMinusClick() { syncMinusButton.performClick(nil) }
    public func test_fireSyncPlusClick() { syncPlusButton.performClick(nil) }

    /// Type into the value field and fire its OWN target/action — the real
    /// Enter-commit dispatch (mirrors `test_fireSliderAction`'s house style).
    public func test_commitSyncField(_ text: String) {
        syncField.stringValue = text
        guard let action = syncField.action,
              let target = syncField.target as? NSObject else { return }
        _ = target.perform(action, with: syncField)
    }

    /// Fire the align-by-ear toggle through `performClick` (real dispatch).
    public func test_fireAlignClick() { alignButton.performClick(nil) }

    /// Whether the align toggle currently reads ON.
    public var test_alignTickOn: Bool { alignButton.state == .on }

    /// Which metronome SF Symbol the align button resolved
    /// ("metronome.fill", or the outline fallback), "" on a non-sync row.
    public var test_alignSymbolName: String { alignSymbolName }

    /// The align button's hover tooltip (locked spec: the glyph must explain
    /// itself on hover).
    public var test_alignTooltip: String? {
        showsSyncControls ? alignButton.toolTip : nil
    }

    /// Whether the host has raised the energize "press-play" pending beat on this
    /// row (item 9) — the drawing-only input, distinct from `test_busNode` which
    /// reads the RESOLVED node (the beat only becomes a `.pending` node while the
    /// device is `.off` AND Reduce Motion is off).
    public var test_energizePending: Bool { energizePending }

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
    /// `CAKeyframeAnimation`.
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
    /// same as `RouteArmedDotView.test_isBlooming`).
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
        // FEED clause (v4.1 item 3): the ONE spoken mention of what's feeding
        // this device — gated `nil` on failed/unavailable (already spoken via
        // `stateClause`'s "couldn't connect", or simply silent for
        // unavailable) so the composed announcement never double-speaks the
        // same fact through two channels.
        let feedClause = feedAccessibilityClause.map { ", \($0)" } ?? ""
        setAccessibilityLabel(
            "\(device.name), \(membership), volume \(device.volume) percent\(stateClause)\(feedClause)")

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

    /// The spoken FEED clause (v4.1 item 3) — the same `mainMixSourceName` +
    /// `feedAppNames` the visual column composes, but joined with a natural
    /// ", " rather than the visual " · " glyph, and NEVER visually truncated
    /// (VoiceOver has no viewport to overflow, so the STATIC "+N" cap is a
    /// screen-only concern). `nil` when there's nothing to say (mirrors the
    /// FEED column's own empty case) or when the connection state already owns
    /// the words (failed/unavailable — `accessibilityStateSuffix` speaks
    /// "couldn't connect"; unavailable stays silent on this channel too, same
    /// as the FEED column itself no longer distinguishing the two visually
    /// beyond color) so the composed announcement never says the same fact
    /// twice.
    private var feedAccessibilityClause: String? {
        guard busActive else { return nil }
        if case .failed = device.connectionState { return nil }
        if !device.isAvailable { return nil }
        var names: [String] = []
        if let mainMixSourceName { names.append(mainMixSourceName) }
        names.append(contentsOf: feedAppNames)
        guard !names.isEmpty else { return nil }
        return "feeding " + names.joined(separator: ", ")
    }

    /// The accessibility-label clause for the current connection state
    /// (brief §6), or `nil` for `.off` — enriches the row label for VoiceOver.
    private var accessibilityStateSuffix: String? {
        // The energize pending node (item 9) is a new VISUAL state, so it ships
        // its spoken equivalent here: a `.off` member flagged for the pending
        // beat speaks "connecting" (the same word the ring/`.connecting` node
        // gets), so a VoiceOver user hears the source switch begin. Under
        // Reduce Motion the beat isn't drawn, so it isn't spoken either.
        if energizePending, !reduceMotion, case .off = device.connectionState {
            return "connecting"
        }
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

// MARK: - SYNC field editing (BT-OFFSET-UI, Return/arrow handling)

extension DeviceRowView: NSTextFieldDelegate {

    /// The field editor's command dispatch for the SYNC value field — the one
    /// seam AppKit routes Return and the arrow keys through while editing.
    ///
    /// - Return COMMITS the typed value and returns `true`: consumed, so the
    ///   key never bubbles past the field (un-consumed it closed the popover
    ///   with the edit lost — live finding).
    /// - ↑/↓ nudge by `fineStepMs` (1 ms — the by-ear granularity); with ⌥ by
    ///   `coarseStepMs`. ⌥-arrows arrive as the PARAGRAPH selectors (Cocoa's
    ///   standard key bindings), so both spellings are handled.
    public func control(_ control: NSControl, textView: NSTextView,
                        doCommandBy commandSelector: Selector) -> Bool {
        guard control === syncField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            syncFieldEdited(syncField)
            return true
        case #selector(NSResponder.moveUp(_:)):
            commitSyncTrim(syncTrimMs + (optionIsHeld ? BTSyncTrim.coarseStepMs : BTSyncTrim.fineStepMs))
            return true
        case #selector(NSResponder.moveDown(_:)):
            commitSyncTrim(syncTrimMs - (optionIsHeld ? BTSyncTrim.coarseStepMs : BTSyncTrim.fineStepMs))
            return true
        case Selector(("moveToBeginningOfParagraph:")):
            commitSyncTrim(syncTrimMs + BTSyncTrim.coarseStepMs)
            return true
        case Selector(("moveToEndOfParagraph:")):
            commitSyncTrim(syncTrimMs - BTSyncTrim.coarseStepMs)
            return true
        default:
            return false
        }
    }

    /// Focus loss (click-away, Tab) commits whatever was typed — an edit must
    /// never silently evaporate because the user clicked another control.
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === syncField else { return }
        syncFieldEdited(syncField)
    }

    // MARK: Test hooks — real dispatch through the exact delegate seam

    /// Set the field's text WITHOUT committing (the "user typed, hasn't
    /// confirmed yet" state the command/end-editing hooks below act on).
    public func test_setSyncFieldText(_ text: String) { syncField.stringValue = text }

    /// Drive `control(_:textView:doCommandBy:)` with the real field — the
    /// identical call the field editor makes for Return/arrows. Returns the
    /// consumed flag (the "popover stays open" mechanism for Return).
    @discardableResult
    public func test_performSyncFieldCommand(_ commandSelector: Selector) -> Bool {
        control(syncField, textView: NSTextView(), doCommandBy: commandSelector)
    }

    /// Drive `controlTextDidEndEditing` with the real field (focus loss).
    public func test_endSyncFieldEditing() {
        controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification, object: syncField))
    }
}

// MARK: - Delegate default (backward-compatible)

public extension DeviceRowView.Delegate {
    /// Default no-op so conformers that predate the routing control (or that
    /// don't host the on/off switch — e.g. narrow test doubles) still compile.
    /// The real host (the popover) overrides this to call
    /// `GroupController.setDeviceSelected`.
    func deviceRow(_ row: DeviceRowView, didToggleEnabled on: Bool, for id: String) {}
    /// Default no-op so non-bus hosts (mixer window, narrow test doubles) needn't
    /// implement the blocked-explanation surfacing (spec §4.6). The popover
    /// overrides this to present the in-place refusal note.
    func deviceRowDidRequestBlockedExplanation(_ row: DeviceRowView) {}
    /// Default no-op — only the popover maps the greyed-BT-row click to a
    /// reconnect (BT-UI).
    func deviceRowDidRequestReconnect(_ row: DeviceRowView) {}
    /// Default no-ops — only the popover hosts the Bluetooth SYNC column
    /// (BT-OFFSET-UI).
    func deviceRow(_ row: DeviceRowView, didSetSyncTrimMs ms: Double, for id: String) {}
    func deviceRow(_ row: DeviceRowView, didToggleAlignTick active: Bool, for id: String) {}
}

// MARK: - Invisible switch cell (spec §4.8)

/// An `NSButtonCell` that draws NOTHING — used by a BUS row's `enableCheckbox`
/// so the checkbox stays a real, focusable, keyboard- and VoiceOver-operable
/// `.switch` button while the ``MembershipBusView`` node is its only visible
/// skin (spec §4.8 "the real NSButton checkbox remains the control underneath …
/// only the DRAWING changes"). It suppresses the cell's own bezel/interior
/// rendering; state, target/action, keyEquivalent handling, and accessibility
/// all come from the un-subclassed `NSButtonCell`/`NSButton` machinery, untouched.
///
/// PUBLIC because the Groups window's `MembershipRowView` wears the same skin on
/// its warm-pane surface — one invisible-cell implementation, not two.
public final class InvisibleSwitchCell: NSButtonCell {
    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {}
    public override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {}

    /// The keyboard focus ring traces the NODE, not the (invisible) switch
    /// glyph's box (spec §4.8): a circle centered on the cell frame — the
    /// checkbox is constrained centered on the node column, so this circle rings
    /// the drawn node with a small breathing gap.
    private func nodeRingRect(for cellFrame: NSRect) -> NSRect {
        let d = PopoverColumnGrid.busNodeDiameter + 4
        return NSRect(x: cellFrame.midX - d / 2, y: cellFrame.midY - d / 2, width: d, height: d)
    }

    public override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect {
        nodeRingRect(for: cellFrame)
    }

    public override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSBezierPath(ovalIn: nodeRingRect(for: cellFrame)).fill()
    }
}
