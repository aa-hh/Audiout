// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit

/// A borderless footer action button that paints a subtle rounded highlight on
/// hover — the missing hover affordance for the popover's footer actions
/// (Save / Open Mixer / Quit).
///
/// Hover is reconciled against the *actual* pointer position via a local
/// mouse-moved monitor (not just enter/exit events), so it clears even when the
/// pointer leaves without a matching `mouseExited:` — the same robustness fix the
/// device/group rows use for the sticky-highlight bug.
final class HoverActionButton: NSButton {

    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var moveMonitor: Any?

    /// Optional closure-based click handler. When set, the button targets itself
    /// and invokes this on click (convenience for callers that prefer a closure
    /// to a target/action pair, e.g. the section-header "+" accessory). Callers
    /// using an explicit `target`/`action` can ignore this.
    var onClick: (() -> Void)? {
        didSet {
            guard onClick != nil else { return }
            target = self
            action = #selector(handleClick)
        }
    }

    @objc private func handleClick() { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = moveMonitor { NSEvent.removeMonitor(m); moveMonitor = nil }
        isHovered = false
        guard window != nil else { return }
        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self, let window = self.window else { return event }
            let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            self.isHovered = self.bounds.contains(point)
            return event
        }
    }

    deinit { if let m = moveMonitor { NSEvent.removeMonitor(m) } }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered && isEnabled {
            let rect = bounds.insetBy(dx: 4, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            path.fill()
        }
        super.draw(dirtyRect)
    }
}
