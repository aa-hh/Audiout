// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudioutWindowUI

@MainActor
@Suite final class RollingCountLabelTests: IsolatedSuite {
    // Animating despite Reduce Motion or delaying the target string turns it red.
    @Test func reduceMotionChangesTheCountAtOnce() {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: true)
        let label = RollingCountLabel(labelWithString: "1 speaker")
        host.contentView?.addSubview(label)
        label.test_reduceMotionOverride = true
        defer { label.test_settleNow() }
        label.roll(to: "2 speakers")
        #expect(label.stringValue == "2 speakers")
        #expect(!label.test_isRolling)
    }

    // Starting a display link without a host window turns it red.
    @Test func anUnhostedCountSettlesAtOnce() {
        let label = RollingCountLabel(labelWithString: "1 speaker")
        label.test_reduceMotionOverride = false
        label.roll(to: "2 speakers")
        #expect(label.stringValue == "2 speakers")
        #expect(!label.test_isRolling)
    }

    // Omitting a hosted roll, delaying its target or failing to settle turns it red.
    @Test func aHostedCountRollsWithItsTargetAlreadyStored() {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: true)
        let label = RollingCountLabel(labelWithString: "1 speaker")
        host.contentView?.addSubview(label)
        label.test_reduceMotionOverride = false
        label.roll(to: "2 speakers")
        #expect(label.stringValue == "2 speakers")
        #expect(label.test_isRolling)
        label.test_settleNow()
        #expect(!label.test_isRolling)
    }

    // Starting an animation for unchanged text turns it red.
    @Test func unchangedTextStartsNothing() {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: true)
        let label = RollingCountLabel(labelWithString: "1 speaker")
        host.contentView?.addSubview(label)
        label.test_reduceMotionOverride = false
        label.roll(to: "1 speaker")
        #expect(!label.test_isRolling)
    }
}
