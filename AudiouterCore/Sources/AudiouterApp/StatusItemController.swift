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
/// SPEC §9 revised (NSMenu → NSPopover): the dropdown is now an `NSPopover`, so
/// the button's *action* toggles the popover (rather than assigning `.menu`,
/// which would auto-open a menu). The action closure is wired in
/// `onButtonClicked`.
final class StatusItemController {

    private let statusItem: NSStatusItem
    private var masterVolume: Double = 0

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

    private func renderButtonImage() {
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: "speaker.wave.3.fill",
            variableValue: masterVolume,
            accessibilityDescription: "AirPlay volume"
        )
        image?.isTemplate = true   // correct rendering in dark/light menu bar
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
