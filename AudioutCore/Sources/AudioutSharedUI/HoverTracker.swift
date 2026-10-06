// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// Pointer hover for one region of a view: owns that region's `NSTrackingArea`
/// and reports changes through `onHoverChange`.
///
/// Hover is re-read from the real pointer position whenever the area is
/// rebuilt and on every pointer move inside it, not trusted to
/// `mouseEntered`/`mouseExited` alone. An area only reports an exit when the
/// pointer crosses its edge, so a row whose exit lands in an untracked gap
/// below the card, or a row rebuilt or moved under a still pointer, would
/// otherwise keep a stale hover.
///
/// The host calls ``update(active:)`` from `updateTrackingAreas()` and
/// ``setHovered(_:)`` with `false` wherever it drops transient state (a model
/// refresh, a window change).
public final class HoverTracker: NSResponder {

    public private(set) var isHovered = false

    private weak var view: NSView?
    /// The tracked rect in the view's coordinates; `nil` tracks the visible bounds.
    private let rect: (() -> NSRect)?
    private let onHoverChange: (Bool) -> Void
    private var area: NSTrackingArea?

    public init(view: NSView, rect: (() -> NSRect)? = nil,
                onHoverChange: @escaping (Bool) -> Void) {
        self.view = view
        self.rect = rect
        self.onHoverChange = onHoverChange
        super.init()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Rebuilds the tracking area, then re-reads the pointer. With `active`
    /// false the area is removed and hover drops.
    public func update(active: Bool = true) {
        guard let view else { return }
        if let area { view.removeTrackingArea(area) }
        area = nil
        guard active else { return setHovered(false) }
        let newArea: NSTrackingArea
        if let rect {
            // Explicit rect, so no `.inVisibleRect`: that option makes AppKit
            // ignore the rect and track the whole visible bounds.
            newArea = NSTrackingArea(
                rect: rect(),
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp],
                owner: self)
        } else {
            newArea = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                owner: self)
        }
        view.addTrackingArea(newArea)
        area = newArea
        refreshFromPointer()
    }

    /// Sets hover directly; `onHoverChange` fires only on a change.
    public func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        onHoverChange(hovered)
    }

    private func refreshFromPointer() {
        guard let view, let window = view.window else { return setHovered(false) }
        let local = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered((rect?() ?? view.bounds).contains(local))
    }

    public override func mouseEntered(with event: NSEvent) { refreshFromPointer() }
    public override func mouseExited(with event: NSEvent) { setHovered(false) }
    public override func mouseMoved(with event: NSEvent) { refreshFromPointer() }
}
