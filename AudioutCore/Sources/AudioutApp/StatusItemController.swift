// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// Owns the menu-bar status item.
///
/// Follows the brief (`dev/notes/p1-menu-brief.md` §4) and SPEC §9 exactly:
/// - never init `NSStatusItem` directly — use `statusItem(withLength:)`;
/// - customize ONLY via `.button` (the item's `.view`/`.title`/`.image` are
///   deprecated);
/// - the button image is an SF Symbol whose `variableValue` tracks master
///   volume (the waves fill with level) in BOTH the idle and streaming states;
/// - **idle/passthrough**: the OUTLINE variant (`speaker.wave.3`);
/// - **actively streaming** (`MenuBarStatus.isStreaming` — anything leaving
///   the Mac by any mechanism, Main Out or a per-app redirect): the FILLED
///   variant (`speaker.wave.3.fill`).
///
/// BOTH states render as a plain TEMPLATE image — that is the macOS
/// menu-bar-status-item convention (see `AudioutSharedUI.StatusItemIcon`'s
/// doc comment for why an accent-colored non-template icon was tried and
/// reverted) — so tint and legibility track the menu bar's light/dark
/// appearance and vibrancy automatically. The idle/streaming distinction is
/// carried entirely by the symbol shape, never by color.
///
/// The idle/streaming decision itself is pure and AppKit-free
/// (`AudioutSharedUI.MenuBarStatus`); the image itself is built by
/// `AudioutSharedUI.StatusItemIcon.make` — this controller only owns the
/// `NSStatusItem`/button plumbing around it.
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
/// SPEC §9 revised: the dropdown is the one-surface panel, so the button's
/// *action* drives it (rather than assigning `.menu`, which would auto-open a
/// menu). The action closure is wired in `onButtonClicked`.
final class StatusItemController {

    private let statusItem: NSStatusItem
    private var masterVolume: Double = 0
    private var isStreaming: Bool = false

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

    /// Update the master-volume level (0…1) the status symbol reflects, then
    /// rebuild the button image with the new `variableValue`. Rebuilding is the
    /// documented way to change an SF Symbol's variable value (brief gotcha #9).
    func updateMasterVolume(_ level: Double) {
        let clamped = min(1, max(0, level))
        guard clamped != masterVolume else { return }
        masterVolume = clamped
        renderButtonImage()
    }

    /// Update the idle/streaming state the status symbol reflects, deciding
    /// via the pure `MenuBarStatus.isStreaming(devices:liveRoutedAppNames:)` —
    /// "anything leaving the Mac by any mechanism," Main Out membership OR a
    /// live per-app redirect, per the resolved design question ("anything
    /// counts," not just Main Out). Rebuilds the button image only on an
    /// actual state change, mirroring `updateMasterVolume`'s guard.
    func updateStreamingState(devices: [Device], liveRoutedAppNames: [String: [String]]) {
        let streaming = MenuBarStatus.isStreaming(devices: devices, liveRoutedAppNames: liveRoutedAppNames)
        guard streaming != isStreaming else { return }
        isStreaming = streaming
        renderButtonImage()
    }

    private func renderButtonImage() {
        guard let button = statusItem.button else { return }
        button.image = StatusItemIcon.make(isStreaming: isStreaming, masterVolume: masterVolume)
        // Opt-in dev disambiguator: when `AUDIOUT_STATUS_LABEL` is set, show it
        // as a text tag beside the icon so a side-by-side test build is visually
        // distinct from an installed copy (identical bundle glyphs otherwise look
        // the same). Inert in normal builds — no env var, no title.
        if let label = ProcessInfo.processInfo.environment["AUDIOUT_STATUS_LABEL"], !label.isEmpty {
            button.title = " \(label)"
            button.imagePosition = .imageLeading
        }
    }
}
