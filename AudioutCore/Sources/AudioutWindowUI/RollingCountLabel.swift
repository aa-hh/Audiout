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
        guard test_isRolling else { super.draw(dirtyRect); return }
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        let rect = cell?.titleRect(forBounds: bounds) ?? bounds
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: textColor ?? NSColor.labelColor,
        ]
        NSAttributedString(string: outgoing, attributes: attributes).draw(at:
            NSPoint(x: rect.minX, y: rect.minY - progress * bounds.height))
        NSAttributedString(string: stringValue, attributes: attributes).draw(at:
            NSPoint(x: rect.minX, y: rect.minY + (1 - progress) * bounds.height))
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
}
