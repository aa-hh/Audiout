// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// Owns the menu-bar status item.
///
/// Follows the brief (`dev/notes/p1-menu-brief.md` §4) and SPEC §9 exactly:
/// - never init `NSStatusItem` directly — use `statusItem(withLength:)`;
/// - customize ONLY via `.button` (the item's `.view`/`.title`/`.image` are
///   deprecated);
/// - the button image is an SF Symbol `speaker.wave.3.fill` whose `variableValue`
///   tracks master volume (the waves fill with level);
/// - the image is template-rendered so it's correct in a dark/light menu bar.
///
/// Warm Signal v3 §5.5 (decision h) adds two glance rules on top:
/// - a small **routing-active dot** at the glyph's top-trailing corner —
///   present = ≥1 live route (`StatusRoutingIndicator`), absent =
///   passthrough/idle. Because the whole button image stays a TEMPLATE image
///   (alpha-only — menu bar rules; survives Reduce Transparency and both
///   menu-bar appearances for free), the dot is presence/absence only, never
///   a color;
/// - **master-mute drains the volume arc** to the empty `variableValue` state
///   (mirrors the meter-drain rule) so the closed-popover glance never lies
///   "80% and broadcasting" while silent.
/// Both states are also spoken: the image's accessibility description appends
/// "muted" / "routing" so VoiceOver reads what the glance shows.
///
/// SPEC §9 revised (NSMenu → NSPopover): the dropdown is now an `NSPopover`, so
/// the button's *action* toggles the popover (rather than assigning `.menu`,
/// which would auto-open a menu). The action closure is wired in
/// `onButtonClicked`.
final class StatusItemController {

    private let statusItem: NSStatusItem
    private var masterVolume: Double = 0
    private var isMainOutMuted = false
    private var isRoutingLive = false

    /// Invoked when the user clicks the status button — the app toggles the
    /// popover relative to `button`.
    var onButtonClicked: ((NSStatusBarButton) -> Void)?

    /// Supplies the menu to show on a SECONDARY click (right-click or
    /// control-click) of the status button — the discoverable home for Quit,
    /// Settings, and Groups in a menu-bar-only app that has no Dock menu.
    /// Returning `nil` falls back to the ordinary primary-click behavior.
    var secondaryClickMenu: (() -> NSMenu?)?

    init() {
        // Variable length so the button sizes to its content (brief §4).
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        renderButtonImage()
        wireButtonAction()
    }

    /// The status button (for anchoring the popover). Non-nil once the item is
    /// in the menu bar.
    var button: NSStatusBarButton? { statusItem.button }

    private func wireButtonAction() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(buttonClicked(_:))
        // Fire on right-mouse too so a secondary click can raise the context menu
        // instead of toggling the popover.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isSecondary, let menu = secondaryClickMenu?() {
            // Assign the menu just for this click, let AppKit position + track it
            // under the button, then clear it so ordinary clicks keep toggling the
            // popover. This is the documented way to mix a click-action with an
            // on-demand menu on one status item.
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
            return
        }
        onButtonClicked?(sender)
    }

    /// Update everything the status glyph reflects — master volume (0…1) for the
    /// `variableValue` arc, master mute (drains the arc, §5.5), and whether ≥1
    /// route is live (the corner dot) — then rebuild the button image if anything
    /// changed. Rebuilding is the documented way to change an SF Symbol's
    /// variable value (brief gotcha #9); the dot rides the same rebuild.
    func update(masterVolume level: Double, isMainOutMuted muted: Bool, isRoutingLive routing: Bool) {
        let clamped = min(1, max(0, level))
        guard clamped != masterVolume || muted != isMainOutMuted || routing != isRoutingLive else { return }
        masterVolume = clamped
        isMainOutMuted = muted
        isRoutingLive = routing
        renderButtonImage()
    }

    /// The routing dot's geometry, in points. The canvas is always padded for
    /// the dot (present or not) so the status item's width — and the glyph's
    /// position — never shifts as routes come and go.
    private static let dotDiameter: CGFloat = 3.5
    private static let dotPadding: CGFloat = 2

    private func renderButtonImage() {
        guard let button = statusItem.button else { return }
        // Mute drains the arc to the empty variableValue state (§5.5) — the
        // glance must not show "80%" while the target is silent.
        let arcValue = isMainOutMuted ? 0 : masterVolume
        guard let symbol = NSImage(
            systemSymbolName: "speaker.wave.3.fill",
            variableValue: arcValue,
            accessibilityDescription: nil
        ) else {
            button.image = nil
            return
        }
        let symbolSize = symbol.size
        let canvas = NSSize(width: symbolSize.width + Self.dotPadding + Self.dotDiameter / 2,
                            height: symbolSize.height)
        let showDot = isRoutingLive
        let image = NSImage(size: canvas, flipped: false) { rect in
            symbol.draw(in: NSRect(origin: .zero, size: symbolSize))
            if showDot {
                // Alpha-only fill — the whole image is a template, so the system
                // inks it correctly in light/dark menu bars and under Reduce
                // Transparency; the dot is presence/absence, never a color.
                let dotRect = NSRect(x: rect.maxX - Self.dotDiameter,
                                     y: rect.maxY - Self.dotDiameter,
                                     width: Self.dotDiameter,
                                     height: Self.dotDiameter)
                NSColor.black.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }
            return true
        }
        image.isTemplate = true   // correct rendering in dark/light menu bar
        // VoiceOver equivalent of the glance (§5.5): say what the arc + dot show.
        var description = "AirPlay volume"
        if isMainOutMuted { description += ", muted" }
        if isRoutingLive { description += ", routing" }
        image.accessibilityDescription = description
        button.image = image
        // Opt-in dev disambiguator: when `AUDIOUTER_STATUS_LABEL` is set, show it
        // as a text tag beside the icon so a side-by-side test build is visually
        // distinct from an installed copy (identical bundle glyphs otherwise look
        // the same). Inert in normal builds — no env var, no title.
        if let label = ProcessInfo.processInfo.environment["AUDIOUTER_STATUS_LABEL"], !label.isEmpty {
            button.title = " \(label)"
            button.imagePosition = .imageLeading
        }
    }
}
