// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// A single row of the popover's **Applications** card
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
/// `AppRoute`/`AppRouteStore` types — it takes only
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
    /// a local "Current Device" row, a saved output group, or an AirPlay device.
    /// Plain values only
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
        /// True for a SAVED OUTPUT GROUP entry — listed under its own header
        /// between the standalone entries and "Current Device". `isLocal` is
        /// `false` for these (a group's speakers are AirPlay), so this flag is
        /// what keeps them out of the plain "AirPlay Devices" section.
        public let isGroup: Bool
        /// `false` renders the entry greyed out and unpickable, still naming
        /// what it is and why it can't be picked in its `subtitle` — e.g. a
        /// group with no usable speaker right now. Hiding it instead would make
        /// a group the user saved look as though it had vanished.
        public let isEnabled: Bool
        /// What the COLLAPSED pop-up button reads while this entry is the
        /// selected one, when that should differ from `title` (a group names
        /// itself as "→ Kitchen" on the button, "Kitchen" in the open menu —
        /// the same convention Main Out's own dropdown uses). `nil` keeps the
        /// button showing `title`.
        public let buttonTitle: String?
        public init(id: String, title: String, isLocal: Bool, symbolName: String? = nil,
                   isStandalone: Bool = false, subtitle: String? = nil,
                   isGroup: Bool = false, isEnabled: Bool = true,
                   buttonTitle: String? = nil) {
            self.id = id; self.title = title; self.isLocal = isLocal; self.symbolName = symbolName
            self.isStandalone = isStandalone
            self.subtitle = subtitle
            self.isGroup = isGroup
            self.isEnabled = isEnabled
            self.buttonTitle = buttonTitle
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
        /// icon dims; an unrouted row also shows the offline badge, a routed row
        /// appends the " (idle)" suffix instead.
        /// The row remains fully interactive while offline (they can still change
        /// the route destination). Defaults to `true` so existing callers and
        /// tests that don't pass this field see no behavior change.
        public let isRunning: Bool
        /// This app's `AppTetherColor` tint when it currently redirects to an
        /// AirPlay DEVICE (Warm Signal v4.1 CORRECTIONS, extending item 7's
        /// "wire the same chip onto that app's App Exceptions redirect entry
        /// so the tether reads at both ends") — `nil` for "No Redirect" or
        /// "Current Device" (nothing on a device's own FEED column to match
        /// against). The HOST computes this the same way it computes the
        /// matching `DeviceRowView` FEED chip's color, so both ends agree.
        /// Defaults to `nil` so every existing caller renders exactly as
        /// before (no chip).
        public let tetherColor: NSColor?
        public init(appID: String, name: String, icon: NSImage?, volume: Int,
                   selectedDestinationID: String, destinations: [Destination],
                   isRunning: Bool = true, tetherColor: NSColor? = nil) {
            self.appID = appID
            self.name = name
            self.icon = icon
            self.volume = volume
            self.selectedDestinationID = selectedDestinationID
            self.destinations = destinations
            self.isRunning = isRunning
            self.tetherColor = tetherColor
        }
    }

    /// Shares `DeviceRowView`'s body-row height (`PopoverColumnGrid.bodyRowHeight`)
    /// — a deliberate density unification: one shared height with every other
    /// popover row.
    public static let rowHeight: CGFloat = PopoverColumnGrid.bodyRowHeight

    public weak var delegate: Delegate?
    public private(set) var appID: String = ""
    private var destinations: [Destination] = []
    /// The plain app name from the last `apply(_:)` — kept separately from
    /// `nameLabel` because the label may carry the composed "Name (idle)"
    /// attributed string (spec §3.5's idle suffix) while VoiceOver must hear
    /// the clean name plus discrete state phrases (`configureAccessibility`).
    private var appName: String = ""
    /// Whether the app's process was running at the last `apply(_:)` — stored
    /// (rather than re-derived from `offlineBadge.isHidden`, which the idle
    /// treatment now suppresses for routed rows) so `configureAccessibility`
    /// can always voice "not running" when true state says so.
    private var isRunning: Bool = true
    /// True iff the selected destination is the standalone "No Redirect" entry
    /// (`isStandalone`) — the neutral/unset state where the app just plays in the
    /// whole-system mix. It gates the ARMED fader fill ONLY — which means
    /// "redirected to a stream of its own", not "has a volume". Every
    /// destination has a live volume: below 100 an un-redirected app is
    /// intercepted and summed back into the mix attenuated.
    private var isNoRedirect: Bool = true

    private let iconView = NSImageView()
    /// Small SF Symbol badge overlaid on the icon when the app is not running
    /// (T4). Hidden by default; shown only for an unrouted, not-running row
    /// (routed rows show the " (idle)" suffix instead). Uses
    /// `exclamationmark.circle.fill` with a yellow-ish secondary tint so it
    /// reads as "warning/offline" without being red/alarming — the route is
    /// intact, the app just isn't running.
    private let offlineBadge = NSImageView()

    /// The under-name VU meter (task T4), mounted only when `showsMeter` is
    /// true — mirrors `DeviceRowView`'s `LevelMeterView`. Driven by
    /// `BackendEvent.appLevel` via `PopoverController.updateAppLevel` →
    /// ``setLevel(_:)``.
    private let meterView = LevelMeterView()
    /// Whether the under-name VU meter is shown.
    private let showsMeter: Bool
    /// The most recently pushed meter level, for ``test_meterLevel()``. `0`
    /// when there's no meter or after a ``resetLevel()``.
    private var lastMeterLevel: Float = 0
    private let nameLabel = NSTextField(labelWithString: "")
    /// The vertical identity cluster (Warm Signal v4 §Call-1): **name / meter**,
    /// left-aligned — the under-name meter, same anatomy as the device rows so
    /// the columns line up across sections.
    private let identityStack = NSStackView()
    private let slider = NSSlider()
    /// The Warm Signal fader skin over `slider` (drawing-only `NSSliderCell`
    /// swap — behavior/keyboard/VoiceOver stay stock): recessed `well` trough,
    /// gold `ember → gold` fill iff this app's redirect route is armed — the
    /// app-row armed predicate, routed (destination ≠ standalone) ∧ running
    /// (spec §5.1's app-row gold-dot predicate; this row hosts no corner dot,
    /// so the fader is where the armed state renders) — rounded-rect `raised`
    /// thumb. See ``WarmFaderCell``.
    private let faderCell = WarmFaderCell()
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
        // A missing selection (nothing matched) is treated as "No Redirect", the
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
        self.appName = configuration.name
        self.isRunning = configuration.isRunning

        if !isDraggingSlider {
            slider.integerValue = configuration.volume
            readoutLabel.stringValue = VolumePercent.label(configuration.volume)
        }
        // Live for EVERY destination. "Current Device" (Bug T2) and AirPlay routes
        // each level their own stream; an un-redirected app is intercepted below
        // 100 and summed back into the whole-system mix at that volume, so there
        // is no destination left whose volume does nothing.
        slider.isEnabled = true
        readoutLabel.textColor = Tokens.Color.secondaryLabel
        // Fader armed state (the app-row equivalent of the device rows' §3.3
        // predicate — spec §5.1: routed ∧ running, pure model): the gold fill
        // renders only while the redirect route is live; an unrouted or idle
        // row keeps the neutral warm fill.
        faderCell.isRouteArmed = !isNoRedirect && configuration.isRunning

        // Name treatment (Warm Signal spec §2/§3.5, S6): the name color follows
        // LIVENESS, not mere list presence — a live exception route is the
        // bright anchor of the APP EXCEPTIONS section at full `label`; every
        // non-live name sits at `secondaryLabel`. "Routed" = destination ≠ the
        // standalone follows-main-output sentinel (an explicit Current Device
        // pick IS an exception route with its own stream, Bug T2). LIVENESS
        // PROXY: `Configuration` exposes only `isRunning` (process alive) —
        // the confirmed-streaming signal (`BackendEvent.routedApps` /
        // `liveAppNames`, which `PopoverController.applyRoutedApps` already
        // holds for DEVICE rows) is not plumbed into this view's inputs, so
        // routed ∧ running stands in for "live" until the host passes the real
        // flag.
        //
        // A routed-but-idle app (route saved, process not running) appends the
        // spec's **" (idle)" tertiary suffix** (§3.5's `AppName (idle)`
        // pattern) so an enabled-but-quiet slider always has a visible cause —
        // this REPLACES the old warning-badge treatment for routed rows: idle
        // is a calm, expected state, not an alert (and the badge's yellow
        // reads gold-adjacent, violating the gold-is-signal-only budget).
        let isRouted = !isNoRedirect
        let showsIdleSuffix = isRouted && !isRunning
        // The derived-colour tether CHIP (Warm Signal v4.1 CORRECTIONS,
        // extending item 7): prefixed onto the name ONLY when the host says
        // this app currently redirects to an AirPlay device — the identical
        // chip a matching `DeviceRowView` FEED segment wears, so the tether
        // reads at both ends. Doesn't change the existing liveness-driven
        // TEXT color logic below at all — the chip is a separate, additive
        // glyph, never a substitute for it.
        let chipPrefix: NSAttributedString? = configuration.tetherColor.map {
            FeedChip.attachmentString(color: $0, font: Tokens.Font.menuItem)
        }
        if showsIdleSuffix {
            let truncatingTail = NSMutableParagraphStyle()
            truncatingTail.lineBreakMode = .byTruncatingTail
            let composed = NSMutableAttributedString()
            if let chipPrefix { composed.append(chipPrefix) }
            composed.append(NSAttributedString(
                string: configuration.name,
                attributes: [
                    .font: Tokens.Font.menuItem,
                    .foregroundColor: Tokens.Color.secondaryLabel,
                    .paragraphStyle: truncatingTail,
                ]))
            composed.append(NSAttributedString(
                string: " (idle)",
                attributes: [
                    .font: Tokens.Font.menuItem,
                    .foregroundColor: Tokens.Color.tertiaryLabel,
                    .paragraphStyle: truncatingTail,
                ]))
            nameLabel.attributedStringValue = composed
        } else if let chipPrefix {
            let composed = NSMutableAttributedString(attributedString: chipPrefix)
            composed.append(NSAttributedString(
                string: configuration.name,
                attributes: [
                    .font: Tokens.Font.menuItem,
                    .foregroundColor: (isRouted && isRunning) ? Tokens.Color.label : Tokens.Color.secondaryLabel,
                ]))
            nameLabel.attributedStringValue = composed
        } else {
            nameLabel.stringValue = configuration.name
            nameLabel.font = Tokens.Font.menuItem
            nameLabel.textColor = (isRouted && isRunning)
                ? Tokens.Color.label : Tokens.Color.secondaryLabel
        }

        // The T4 warning badge survives ONLY for an unrouted, not-running row
        // (no idle suffix shows there — an unrouted row's slider is already
        // dimmed, so there is no "enabled but quiet" contradiction to explain).
        // The dimmed icon still marks not-running in both cases.
        offlineBadge.isHidden = isRunning || isRouted
        iconView.alphaValue = isRunning ? 1.0 : 0.5

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
        // A distinct `buttonTitle` shows on the COLLAPSED button while the open
        // menu keeps the full `title`. `usesItemFromMenu = false` + a
        // display-only cell item is the documented way to make the two differ;
        // re-set on every rebuild so a later pick without an override reverts.
        if let cell = destinationPopUp.cell as? NSPopUpButtonCell {
            let buttonTitle = destinations.first { $0.id == selectedID }?.buttonTitle
            if let buttonTitle {
                cell.usesItemFromMenu = false
                cell.menuItem = NSMenuItem(title: buttonTitle, action: nil, keyEquivalent: "")
            } else {
                cell.usesItemFromMenu = true
            }
        }
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
    /// section), then a separator, then three sections: "Output Groups",
    /// "Current Device", "AirPlay Devices".
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
        // Every item's `isEnabled` is decided HERE (headers, and an entry the
        // host marked unpickable). Automatic enabling would hand that decision
        // to the target's own validation and light those items back up — and an
        // `NSPopUpButton` re-points every item's action at its own cell, so
        // withholding the action isn't a way to grey one out either.
        menu.autoenablesItems = false
        var currentItem: NSMenuItem?

        func addHeader(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: Tokens.Font.captionEmphasized,
                    .foregroundColor: Tokens.Color.tertiaryLabel,
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
        let groupEntries = destinations.filter { $0.isGroup && !$0.isStandalone }
        let localEntries = destinations.filter { $0.isLocal && !$0.isStandalone }
        // `!isStandalone` mirrors `localEntries`'s own exclusion above — without
        // it, a standalone entry that also names a device (e.g. a "Resume →
        // <device>" entry, `isLocal: false`) would render TWICE: once at the
        // top with the other standalone entries, once again down here. Groups
        // are excluded for the same reason: they have their own section.
        let deviceEntries = destinations.filter { !$0.isLocal && !$0.isStandalone && !$0.isGroup }

        addEntries(standaloneEntries)
        if !standaloneEntries.isEmpty,
           !groupEntries.isEmpty || !localEntries.isEmpty || !deviceEntries.isEmpty {
            menu.addItem(.separator())
        }
        if !groupEntries.isEmpty {
            addHeader("Output Groups")
            addEntries(groupEntries)
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
    ///
    /// Every entry displays the host-supplied `Destination.title` VERBATIM
    /// (host-supplies-copy doctrine) — the unrouted bridge phrase "Follows
    /// main output" (spec §5.1, decision 3) is the HOST's title for the
    /// standalone entry, not a view-level rewrite.
    private func menuItem(
        for entry: Destination, isCurrent: Bool, action: Selector, allowsAttributedSubtitle: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isCurrent ? .on : .off
        item.representedObject = entry.id
        item.isEnabled = entry.isEnabled
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
                    attributes: [.font: Tokens.Font.menuItem])
                attributedTitle.append(NSAttributedString(string: "\n"))
                attributedTitle.append(NSAttributedString(
                    string: subtitle,
                    attributes: [
                        .font: Tokens.Font.caption,
                        .foregroundColor: Tokens.Color.secondaryLabel,
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
        nameLabel.font = Tokens.Font.menuItem
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
        slider.action = #selector(volumeChanged(_:))

        readoutLabel.translatesAutoresizingMaskIntoConstraints = false
        readoutLabel.font = Tokens.Font.caption
        readoutLabel.textColor = Tokens.Color.secondaryLabel
        readoutLabel.alignment = .right
        readoutLabel.setContentHuggingPriority(.required, for: .horizontal)

        destinationPopUp.translatesAutoresizingMaskIntoConstraints = false
        destinationPopUp.pullsDown = false
        destinationPopUp.controlSize = .small
        destinationPopUp.font = Tokens.Font.caption
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
        offlineBadge.isHidden = true   // visible only for an unrouted, not-running row

        // Under-name VU meter (task T4): mounted only when `showsMeter`.
        // Non-interactive (`LevelMeterView.hitTest` returns nil).
        meterView.translatesAutoresizingMaskIntoConstraints = false

        // Identity cluster (v4 §Call-1): name over the under-name meter, matching
        // the device rows' anatomy so columns line up across sections.
        identityStack.translatesAutoresizingMaskIntoConstraints = false
        identityStack.orientation = .vertical
        identityStack.alignment = .leading
        identityStack.spacing = 2
        identityStack.distribution = .fill
        identityStack.addArrangedSubview(nameLabel)
        if showsMeter { identityStack.addArrangedSubview(meterView) }

        addSubview(iconView)
        addSubview(offlineBadge)
        addSubview(identityStack)
        addSubview(slider)
        addSubview(readoutLabel)
        addSubview(destinationPopUp)

        // Laid out against the shared `PopoverColumnGrid` exactly like
        // `DeviceRowView`: the icon leads at `firstElementLeading` (reserving the
        // left rail gutter so app icons align with device icons); slider / `%` /
        // trailing popup anchor off the row's TRAILING edge. App rows carry no
        // bus node — the gutter is reserved but empty, just as device rows leave
        // the trailing dropdown column empty (column alignment holds).
        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: Self.rowHeight),

            iconView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: PopoverColumnGrid.firstElementLeading(indented: false)),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),
            iconView.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.iconWidth),

            // Offline badge: pinned to icon's trailing/bottom corner (T4).
            offlineBadge.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 2),
            offlineBadge.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 2),
            offlineBadge.widthAnchor.constraint(equalToConstant: 11),
            offlineBadge.heightAnchor.constraint(equalToConstant: 11),

            identityStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                                   constant: PopoverColumnGrid.iconToName),
            identityStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            identityStack.trailingAnchor.constraint(
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
                meterView.widthAnchor.constraint(
                    equalToConstant: PopoverColumnGrid.meterUnderNameWidth),
                meterView.heightAnchor.constraint(
                    equalToConstant: PopoverColumnGrid.meterUnderNameHeight),
            ])
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
            return Tokens.Color.engagedChrome.withAlphaComponent(PopoverColumnGrid.rowSelectionWashAlpha)
        } else if isHovered {
            return Tokens.Color.engagedChrome.withAlphaComponent(PopoverColumnGrid.rowHoverWashAlpha)
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
        let event = NSApp?.currentEvent
        if event?.type == .leftMouseUp { isDraggingSlider = false }
        readoutLabel.stringValue = VolumePercent.label(sender.integerValue)
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
            attributes: [.foregroundColor: Tokens.Color.destructive])
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
    // background fall through to these overrides.

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
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Sticky-hover fix (shared row idiom): a bottom-most row can miss
    /// `mouseExited` when the pointer leaves into an untracked dead-zone below
    /// the card, so reconcile against the true pointer position — fed by the
    /// tracking area's own `.mouseMoved` option (P2-1), not an app-wide
    /// `NSEvent` monitor.
    public override func mouseMoved(with event: NSEvent) {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        isHovered = bounds.contains(point)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
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

    // MARK: Test-support hooks — APP EXCEPTIONS treatment (S6)

    /// The dropdown's collapsed title — must always name the destination:
    /// the bridge phrase "Follows main output" when unrouted (spec §5.1,
    /// decision 3) or the device name when routed.
    public var test_collapsedDestinationTitle: String? {
        guard let cell = destinationPopUp.cell as? NSPopUpButtonCell else {
            return destinationPopUp.titleOfSelectedItem
        }
        // With a `buttonTitle` override in force the button renders the
        // display-only cell item, not the selected menu item.
        return cell.usesItemFromMenu ? destinationPopUp.titleOfSelectedItem : cell.menuItem?.title
    }

    /// The name label's full displayed text — includes the " (idle)" tertiary
    /// suffix when a routed app's process isn't running (spec §3.5 pattern).
    /// Strips a leading tether-chip attachment's object-replacement character
    /// (Warm Signal v4.1 CORRECTIONS), if present, so a test reading WORDS
    /// never has to know a chip exists.
    public var test_nameDisplayText: String {
        nameLabel.stringValue.replacingOccurrences(of: FeedChip.objectReplacementCharacter, with: "")
    }

    /// The colour of the NAME portion of the label (the first character AFTER
    /// any leading tether-chip attachment, when the idle suffix or a chip is
    /// composed, else the label's plain `textColor`): full `label` for a live
    /// exception route — the section's bright anchor — `secondaryLabel`
    /// otherwise. Skipping the chip run (Warm Signal v4.1 CORRECTIONS) keeps
    /// this reading the NAME's own color, not the chip's.
    public var test_nameTextColor: NSColor? {
        let attributed = nameLabel.attributedStringValue
        guard attributed.length > 0 else { return nameLabel.textColor }
        let plain = attributed.string as NSString
        var index = 0
        while index < plain.length, plain.character(at: index) == 0xFFFC { index += 1 }
        guard index < attributed.length else { return nameLabel.textColor }
        if let color = attributed.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor {
            return color
        }
        return nameLabel.textColor
    }

    /// Whether the name label currently wears the leading tether CHIP (Warm
    /// Signal v4.1 CORRECTIONS) — `true` only when the host supplied a
    /// non-nil `Configuration.tetherColor` (this app currently redirects to
    /// an AirPlay device).
    public var test_hasTetherChip: Bool {
        let attributed = nameLabel.attributedStringValue
        guard attributed.length > 0 else { return false }
        return attributed.attribute(.attachment, at: 0, effectiveRange: nil) != nil
    }

    /// The colour of the " (idle)" suffix when present — `nil` when the name
    /// carries no idle suffix. Must be `tertiaryLabel` (spec §3.5 idle voice).
    public var test_idleSuffixColor: NSColor? {
        let attributed = nameLabel.attributedStringValue
        guard attributed.length > 0, attributed.string.hasSuffix("(idle)") else { return nil }
        return attributed.attribute(
            .foregroundColor, at: attributed.length - 1, effectiveRange: nil) as? NSColor
    }

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
        // by VoiceOver; it must be said here or not at all. The stored
        // `appName`/`isRunning` back this (rather than `nameLabel`, which may
        // carry the visual " (idle)" suffix, and `offlineBadge`, which the
        // idle treatment suppresses for routed rows) so VoiceOver hears the
        // clean name plus discrete state phrases regardless of the visual
        // rendering — every visual state above has its spoken equivalent here.
        //
        // Composition (S6 item 6): an UNROUTED app reads "…, follows main
        // output" (the bridge phrase, spec §5.1); a routed app reads
        // "…, routed to <destination>".
        var label = "\(appName), volume \(VolumePercent.spoken(slider.integerValue))"
        if isNoRedirect {
            label += ", follows main output"
        } else if let destinationTitle = destinationPopUp.selectedItem?.title,
                  !destinationTitle.isEmpty {
            label += ", routed to \(destinationTitle)"
        }
        if !isRunning {
            label += ", not running"
        }
        setAccessibilityLabel(label)

        slider.setAccessibilityRole(.slider)
        slider.setAccessibilityLabel("\(appName) volume")
        destinationPopUp.setAccessibilityLabel("\(appName) destination")
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
    /// Whether the volume slider is currently dimmed/disabled. Always false: every
    /// destination — "No Redirect" included — has a volume that does something.
    public var test_isSliderDimmed: Bool { !slider.isEnabled }
    /// Whether the Warm fader would render its ENGAGED (gold-gradient) fill —
    /// the app-row armed predicate (routed ∧ running) ∧ slider enabled, read
    /// from the cell's own gate so the test can't drift from the pixels.
    public var test_isFaderEngaged: Bool { faderCell.test_isEngagedFill }
    /// Whether the slider is wearing the Warm fader skin (structural).
    public var test_hasWarmFaderSkin: Bool { slider.cell is WarmFaderCell }
    /// Whether the offline badge (T4) is currently visible — true when the
    /// routed app's process is not running.
    public var test_isOfflineBadgeVisible: Bool { !offlineBadge.isHidden }
    /// The last level pushed to the leading VU meter via ``setLevel(_:)`` — `0`
    /// when the row has no meter (`showsMeter == false`) or after a
    /// ``resetLevel()``. Mirrors `DeviceRowView.test_meterLevel()`.
    public func test_meterLevel() -> Float { lastMeterLevel }
    /// The full ordered list of titles in the destination menu: the standalone
    /// entry (displayed as the bridge phrase "Follows main output", S6), a
    /// separator (empty title), then the two disabled section headers
    /// ("CURRENT DEVICE" / "AIRPLAY DEVICES") and their entries.
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
    /// outside the slider and destination popup frames. Test-hook wrapper around
    /// the real production check `mouseDown`/`rightMouseDown` use
    /// (`isInSelectableDeadZone`).
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

