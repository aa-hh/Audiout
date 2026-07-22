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
    /// (the Mac can't join a mixed set) — the checkbox is greyed with a tooltip.
    private var isToggleBlocked: Bool = false

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
    private let iconView = NSImageView()
    /// The on-icon connection-status badge (2026-07-17): a small corner dot
    /// overlapping the icon's bottom-right, driven off `device.connectionState`.
    /// Replaced the retired right-side status slot. See ``StatusDotView``.
    private let statusDotView = StatusDotView()
    private let nameLabel = NSTextField(labelWithString: "")
    /// The single sublabel line under the name, driven by a precedence ladder in
    /// ``resolveSublabel(routedAppNames:)``: `.failed` → "Couldn't connect"
    /// (`.systemOrange`); unavailable → "Unavailable" (greyed); else a non-empty
    /// routing set → the routing line ("System · <apps>"); else hidden (the row is
    /// single-line, name centered). All three sublabel kinds reuse this one label.
    private let statusLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    /// Small right-aligned `%` readout sitting immediately right of the slider
    /// (change 4 — a device row now shows its volume number too, tight against
    /// the slider like the Main Out row, on the same shared column).
    private let readoutLabel = NSTextField(labelWithString: "")
    private let muteButton = NSButton()

    /// The leading VU meter (task T-METER/T3), mounted only when `showsMeter`
    /// is true — the mixer window and `GroupRowView` leave it out and stay
    /// visually unchanged. See ``LevelMeterView``.
    private let meterView = LevelMeterView()
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
               paintsSelectionBackground: Bool = true, showsMeter: Bool = false) {
        self.device = device
        self.indented = indented
        self.showsToggle = showsToggle
        self.paintsSelectionBackground = paintsSelectionBackground
        self.showsMeter = showsMeter
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
                      iconSymbolName: String? = nil) {
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
        enableCheckbox.state = selected ? .on : .off
        enableCheckbox.isEnabled = showsToggle && device.isAvailable && !blocked
        enableCheckbox.toolTip = (showsToggle && blocked) ? blockReason : nil
        // A1: dim, don't disable — `isEnabled` above is untouched by
        // `selectionDimmed`, only the alpha is.
        enableCheckbox.alphaValue = selectionDimmed ? Self.selectionDimmedAlpha : 1.0

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

        // On-icon status badge: driven off connectionState. When the device has
        // live per-app routes but is NOT in the whole-system output set, the
        // badge shows a teal routing-active dot (T3) — visually distinct from
        // the streaming-green (.connected) so a redirect-only row is never
        // mistaken for a fully disconnected one.
        let hasLiveRouting = !liveAppNames.isEmpty
        statusDotView.apply(state: device.connectionState, routingActive: hasLiveRouting)
        // Single sublabel precedence ladder (failed → unavailable → routing →
        // none), evaluated here after `device`/`isSelectedInSet` are set so the
        // precedence is unambiguous.
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
        // V7: the `%` readout dims in lockstep with the slider's enabled state —
        // a disabled/unavailable slider reads as fully de-emphasized, not just
        // its track.
        readoutLabel.textColor = slider.isEnabled ? Tokens.Color.secondaryLabel : Tokens.Color.tertiaryLabel

        // The meter can only be showing a live level while the device is an
        // actual selected, unmuted output — otherwise a stale bar could stick
        // (same transient-reset discipline as `isHovered` above).
        let isPlaying = device.isAvailable && isSelectedInSet && !device.isMuted
        if showsMeter && !isPlaying {
            meterView.reset()
            lastMeterLevel = 0
        }

        configureAccessibility()
        setNeedsDisplay(bounds)
    }

    /// Updates the mute button's tint colour for the current `muteButton.state`
    /// (V1) — `.on` (muted) reads as an accent-tinted glyph, `.off` as the
    /// neutral secondary tint. Mirrors `MainOutRowView.updateMuteTint()`: the
    /// glyph itself never changes (no alternate/slash image), only its tint.
    /// Called from `apply` (model refresh) AND `muteToggled` (a live click) so
    /// both paths land the same tint instantly.
    private func updateMuteTint() {
        muteButton.contentTintColor = muteButton.state == .on ? Tokens.Color.accent : Tokens.Color.secondaryLabel
    }

    /// Alpha applied to `enableCheckbox` when `apply(selectionDimmed:)` is true
    /// (A1) — a visual de-emphasis, not a disablement (the checkbox stays
    /// `isEnabled` and interactive at this alpha).
    private static let selectionDimmedAlpha: CGFloat = 0.4

    /// Separator joining routing-line tokens: space, U+00B7 MIDDLE DOT, space.
    private static let routingTokenSeparator = " · "

    // MERGE NOTE (2026-07-17, phase2b ← main): the old `applyConnectionStatus(_:)`
    // (badge + failed-only sublabel) is gone — not dropped, SUPERSEDED. `apply`
    // now drives `StatusDotView.apply(_:)` directly (same idempotent reset, so a
    // repeated `apply` still can't leave a stale breathing animation running) and
    // routes every sublabel through `resolveSublabel(routedAppNames:)`'s ladder,
    // which subsumes the failed-only case as its highest rung.

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
            showSublabel("Couldn't connect", color: Tokens.Color.warning)
        } else if !device.isAvailable {
            showSublabel("Unavailable", color: Tokens.Color.tertiaryLabel)
        } else if let routing = routingLine(routedAppNames: routedAppNames, liveAppNames: liveAppNames) {
            showSublabel(routing, color: Tokens.Color.secondaryLabel)
        } else {
            hideSublabel()
        }
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
    public func setLevel(_ rms: Float) {
        guard showsMeter else { return }
        lastMeterLevel = rms
        meterView.setLevel(rms)
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

    /// The name label's vertical offset off row center. Flipped live by
    /// ``applyNameStackLayout(twoLine:)``: 0 when the row is single-line (name
    /// centered), and a half-line rise when ANY sublabel (failed / unavailable /
    /// routing) is shown so the name + sublabel PAIR is centered instead.
    private var nameCenterYConstraint: NSLayoutConstraint!

    /// Half-line offset used to center the two-line name/sublabel pair whenever a
    /// sublabel is shown. Kept at the value the two-line stack used before the
    /// redesign.
    private static let sublabelNameRise: CGFloat = 7.5

    private func buildSubviews() {
        wantsLayer = true
        // Leading edge of the row's first control (task B shared grid). Members
        // read indented; the toggle (when present) or the icon (when hidden)
        // starts here.
        let leading: CGFloat = indented ? PopoverColumnGrid.indentedLeadingInset
                                        : PopoverColumnGrid.leadingInset

        enableCheckbox.translatesAutoresizingMaskIntoConstraints = false
        enableCheckbox.setButtonType(.switch)       // AppKit checkbox
        enableCheckbox.title = ""                    // no inline title
        enableCheckbox.controlSize = .regular
        enableCheckbox.target = self
        enableCheckbox.action = #selector(enableToggled(_:))
        enableCheckbox.setContentHuggingPriority(.required, for: .horizontal)
        // Group-member rows hide the toggle (task C). Its leading slot is not
        // reused — the row already indents, keeping the icon column aligned.
        enableCheckbox.isHidden = !showsToggle

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        // On-icon status badge: overlaps the icon's bottom-right corner. Not
        // clipped by the icon (added as a row subview, positioned on the icon's
        // corner) so the punch-out border shows around it.
        statusDotView.translatesAutoresizingMaskIntoConstraints = false
        statusDotView.setContentHuggingPriority(.required, for: .horizontal)

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

        addSubview(enableCheckbox)
        if showsMeter { addSubview(meterView) }
        addSubview(iconView)
        addSubview(statusDotView)          // over the icon's corner
        addSubview(nameLabel)
        addSubview(statusLabel)
        addSubview(slider)
        addSubview(readoutLabel)
        addSubview(muteButton)

        // The icon now LEADS the row (task B grid): at `leading` for top-level
        // rows, `indentedLeadingInset` for members — the toggle no longer leads.
        // The mute glyph, slider and trailing "Selected" checkbox are anchored off
        // the TRAILING edge via the shared grid so they line up with every other
        // row type; the `%` readout hangs off the slider's trailing edge (change
        // 4) so the number is tight to the slider on every slider row.
        //
        // The name is SINGLE-LINE and centered by default (2026-07-17); when ANY
        // sublabel (failed / unavailable / routing) is shown, `applyNameStackLayout`
        // raises the name by a half-line so the pair is centered. The right-side
        // status slot was retired — connection status is the on-icon corner dot.
        let nameCenterY = nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        nameCenterYConstraint = nameCenterY

        // The meter (when shown) sits at the row's leading edge; the icon then
        // repoints its leading anchor off the meter's trailing edge instead of
        // `leadingAnchor` directly — together these land the icon at exactly
        // `PopoverColumnGrid.firstElementLeading(indented:)`, matching T1's
        // shared grid contract. When `showsMeter` is false the icon anchors
        // directly to `leadingAnchor` as before — layout is IDENTICAL to today.
        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: Self.rowHeight),
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

            // Sublabel (any kind) sits a half-line under the (raised) name.
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

            // Primary "Selected Devices" checkbox: centered UNDER its "Selected"
            // header — its centerX sits on the trailing-control column center,
            // not the column's trailing edge. The `.switch` NSButton with an
            // empty title is ~18pt square; centerX/centerY handle it (no width
            // constraint needed).
            enableCheckbox.centerXAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -PopoverColumnGrid.trailingControlCenterFromTrailing),
            enableCheckbox.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]

        if showsMeter {
            constraints.append(contentsOf: [
                meterView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
                meterView.centerYAnchor.constraint(equalTo: centerYAnchor),
                meterView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.meterWidth),
                meterView.heightAnchor.constraint(equalToConstant: 22),
                iconView.leadingAnchor.constraint(
                    equalTo: meterView.trailingAnchor, constant: PopoverColumnGrid.meterToLeading),
            ])
        } else {
            constraints.append(iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading))
        }

        NSLayoutConstraint.activate(constraints)
    }

    /// Center the name for a single-line row, or raise it a half-line when ANY
    /// sublabel (failed / unavailable / routing) is showing so the name +
    /// sublabel pair is centered as a group on the icon.
    private func applyNameStackLayout(twoLine: Bool) {
        nameCenterYConstraint.constant = twoLine ? -Self.sublabelNameRise : 0
    }

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
    /// the SAME delegate path as the checkbox itself. A no-op when the checkbox is
    /// disabled (Phase-1 local-mix block, or an unavailable device) — checks the
    /// same conditions `enableCheckbox.isEnabled` uses. For a `.failed` device this
    /// re-enables it (= retry), which is intended.
    @objc private func nameClicked(_ sender: NSClickGestureRecognizer) {
        guard enableCheckbox.isEnabled else { return }
        let flipped = enableCheckbox.state != .on
        enableCheckbox.state = flipped ? .on : .off
        delegate?.deviceRow(self, didToggleEnabled: flipped, for: device.id)
    }

    /// The name/label colour for the current state: menu highlight wins, then a
    /// dropped device greys out, then a blocked toggle (Phase-1 local-mix block)
    /// greys the name too (V12 — the row reads consistently de-emphasized while
    /// its membership control can't be touched), then a not-selected device
    /// de-emphasizes (it's not in the Selected Devices set), then normal.
    private var rowTextColor: NSColor {
        if isInMenu, enclosingMenuItem?.isHighlighted == true { return .selectedMenuItemTextColor }
        if !device.isAvailable { return .disabledControlTextColor }
        if isToggleBlocked { return Tokens.Color.tertiaryLabel }
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
    /// same delegate path). A no-op when the checkbox is disabled, mirroring the
    /// real gesture handler.
    public func test_clickName() {
        guard enableCheckbox.isEnabled else { return }
        let flipped = enableCheckbox.state != .on
        enableCheckbox.state = flipped ? .on : .off
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

    /// The current sublabel's text, or `nil` when hidden. Reports whichever of the
    /// three sublabel kinds is showing (failed "Couldn't connect" / "Unavailable"
    /// / the routing line), since all three flow through the single `statusLabel`.
    public var test_statusText: String? {
        statusLabel.isHidden ? nil : statusLabel.stringValue
    }

    /// The composed routing sublabel string ("System …" joined by " · "), or
    /// `nil` when the routing set is empty — for asserting the routing line in
    /// isolation from the failed/unavailable precedence. `liveAppNames`
    /// defaults to empty so existing intent-only callers are unaffected; pass it
    /// to assert the T9 live-precedence-over-intent behavior. Test hook.
    public func test_sourceText(routedAppNames: [String], liveAppNames: [String] = []) -> String? {
        routingLine(routedAppNames: routedAppNames, liveAppNames: liveAppNames)
    }

    /// Whether the connecting/reconnecting badge's breathing pulse is installed
    /// (on screen + Reduce Motion off). Lets tests assert the animation hook.
    public var test_dotIsPulsing: Bool { statusDotView.test_isBreathing }

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

    /// The `%` readout's current text colour (V7) — dims to `.tertiaryLabelColor`
    /// in lockstep with the slider's disabled state, `.secondaryLabelColor`
    /// otherwise.
    public var test_readoutColor: NSColor? { readoutLabel.textColor }

    /// Whether the volume slider is currently enabled (A5) — stays enabled while
    /// the device is muted (mute ≠ frozen volume); only availability/
    /// controllability/unsupported-ness gate it.
    public var test_isSliderEnabled: Bool { slider.isEnabled }

    /// Whether the "Selected Devices" checkbox is currently rendered dimmed (A1)
    /// — a visual de-emphasis (alpha ~0.4) that does NOT disable the control;
    /// pair with `test_isEnabledOn`/clicking to confirm it's still interactive.
    public var test_isSelectionDimmed: Bool { enableCheckbox.alphaValue < 1.0 }

    /// The device name label's current colour (``rowTextColor``) — asserts the
    /// V12 blocked-name branch (`.tertiaryLabelColor`) alongside the ordinary
    /// available/selected states. `apply` already stamps this, so no `draw(_:)`
    /// call is needed to read it.
    public var test_nameColor: NSColor? { nameLabel.textColor }

    /// Whether the routing-active teal indicator is currently showing on the
    /// icon badge — true when the device has live per-app routes but is not in
    /// the whole-system output set (T3). Delegates to the badge view.
    public var test_isShowingRoutingIndicator: Bool { statusDotView.test_isShowingRoutingDot }

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

    /// C3: a pointing-hand cursor over the NAME label only (its click toggles
    /// membership, ``nameClicked(_:)``) — scoped to `nameLabel.frame`, not the
    /// whole row, so the slider/mute/checkbox keep the standard arrow. Standard
    /// AppKit `resetCursorRects`/`addCursorRect`; no interaction with the hover
    /// `NSTrackingArea` above (cursor rects and tracking areas are independent
    /// AppKit mechanisms).
    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(nameLabel.frame, cursor: .pointingHand)
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
        let membership = isSelectedInSet ? "selected" : "not selected"
        // Connection state reads as a trailing clause (brief §6) — omitted
        // entirely for `.off` so an unrouted row's label is unchanged.
        let state = accessibilityStateSuffix
        let stateClause = state.map { ", \($0)" } ?? ""
        setAccessibilityLabel("\(device.name), \(membership), volume \(device.volume) percent\(stateClause)")

        enableCheckbox.setAccessibilityLabel(
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
