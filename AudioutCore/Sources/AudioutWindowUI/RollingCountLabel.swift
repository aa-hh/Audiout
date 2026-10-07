// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import QuartzCore
import AudioutSharedUI

/// A count caption whose text slides when its value changes.
/// The stored string always holds the target, including during the animation.
final class RollingCountLabel: NSTextField {
    private var outgoing = ""
    private var progress: CGFloat = 1
    private var startTime: CFTimeInterval = 0
    private var link: CADisplayLink?
    var test_reduceMotionOverride: Bool?
    var test_isRolling: Bool { link != nil }

    func roll(to text: String) {
        guard text != stringValue else { return }
        outgoing = stringValue
        stringValue = text
        link?.invalidate()
        link = nil
        guard window != nil,
              !(test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) else {
            test_settleNow()
            return
        }
        progress = 0
        startTime = CACurrentMediaTime()
        let clock = displayLink(target: self, selector: #selector(tick))
        clock.add(to: .main, forMode: .common)
        link = clock
        needsDisplay = true
    }

    @objc private func tick() {
        let t = min(1, max(0, CGFloat((CACurrentMediaTime() - startTime) / Tokens.Motion.collapseRevealDuration)))
        guard t < 1 else { test_settleNow(); return }
        progress = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard test_isRolling,
              let incomingCell = cell,
              let outgoingCell = incomingCell.copy() as? NSCell else {
            super.draw(dirtyRect)
            return
        }
        outgoingCell.stringValue = outgoing
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        drawCell(outgoingCell, offset: -progress * bounds.height)
        drawCell(incomingCell, offset: (1 - progress) * bounds.height)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCell(_ cell: NSCell, offset: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let translation = NSAffineTransform()
        translation.translateX(by: 0, yBy: offset)
        translation.concat()
        cell.draw(withFrame: bounds, in: self)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { test_settleNow() }
    }

    func test_settleNow() {
        progress = 1
        link?.invalidate()
        link = nil
        needsDisplay = true
    }

    func test_setProgress(_ value: CGFloat) {
        progress = value
        needsDisplay = true
    }
}
