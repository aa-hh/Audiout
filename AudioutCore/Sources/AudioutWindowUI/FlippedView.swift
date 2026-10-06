// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// A scroll view's document view that lays out from the TOP, so a page or a
/// checklist shorter than its clip view starts under the title bar instead of
/// sinking to the bottom with dead space above it.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
