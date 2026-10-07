// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
import AudioutSharedUI
@testable import AudioutWindowUI

@MainActor
@Suite final class RollingCountLabelTests: IsolatedSuite {
    // Animating despite Reduce Motion or delaying the target string turns it red.
    @Test func reduceMotionChangesTheCountAtOnce() {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                            styleMask: [.borderless], backing: .buffered, defer: true)
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
                            styleMask: [.borderless], backing: .buffered, defer: true)
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
                            styleMask: [.borderless], backing: .buffered, defer: true)
        let label = RollingCountLabel(labelWithString: "1 speaker")
        host.contentView?.addSubview(label)
        label.test_reduceMotionOverride = false
        label.roll(to: "1 speaker")
        #expect(!label.test_isRolling)
    }

    // Replacing native cell drawing with attributed-string drawing shifts the count's inset and baseline and turns it red.
    @Test func aRollPreservesNativeTextDrawingAtEveryStage() throws {
        let host = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 100),
                            styleMask: [.borderless], backing: .buffered, defer: true)
        let label = RollingCountLabel(labelWithString: "")
        let reference = RollingCountReferenceLabel(labelWithString: "")
        label.test_reduceMotionOverride = false
        host.contentView?.addSubview(label)
        host.contentView?.addSubview(reference)
        defer { label.test_settleNow() }
        for field in [label, reference] {
            field.font = Tokens.Font.captionDigits
            field.textColor = .black
            field.appearance = NSAppearance(named: .aqua)
            field.lineBreakMode = .byTruncatingTail
        }
        for (old, new, width) in [("1 speaker", "2 speakers", 170),
                                  ("2 speakers", "1 speaker", 170),
                                  ("9 speakers", "10 speakers", 170),
                                  ("10 speakers", "9 speakers", 66)] {
            label.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: 18)
            reference.frame = label.frame
            label.test_settleNow()
            label.stringValue = old
            label.roll(to: new)
            for progress in [CGFloat(0), 0.5, 1] {
                label.test_setProgress(progress)
                reference.parts = [(old, -progress * label.bounds.height),
                                   (new, (1 - progress) * label.bounds.height)]
                #expect(try render(label) == render(reference),
                        "\(old) → \(new), width \(width), progress \(progress)")
            }
            reference.parts = [(new, 0)]
            label.test_settleNow()
            #expect(try render(label) == render(reference))
        }
    }

    // Retaining an earlier target or leaving a display link active after detaching turns it red.
    @Test func repeatedChangesSettleToTheLatestCount() throws {
        let host = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 100),
                            styleMask: [.borderless], backing: .buffered, defer: true)
        let label = RollingCountLabel(labelWithString: "1 speaker")
        label.frame = NSRect(x: 0, y: 0, width: 170, height: 18)
        host.contentView?.addSubview(label)
        label.test_reduceMotionOverride = false
        defer { label.test_settleNow() }
        let original = try render(label)
        label.roll(to: "2 speakers")
        label.test_setProgress(0.5)
        label.roll(to: "10 speakers")
        label.test_setProgress(0.5)
        label.roll(to: "1 speaker")
        #expect(label.stringValue == "1 speaker")
        #expect(label.test_isRolling)
        label.test_settleNow()
        #expect(try render(label) == original)
        label.roll(to: "2 speakers")
        label.test_setProgress(0.5)
        label.removeFromSuperview()
        #expect(!label.test_isRolling)
        #expect(label.stringValue == "2 speakers")
    }

    private func render(_ field: NSTextField) throws -> Data {
        let bitmap = try #require(field.bitmapImageRepForCachingDisplay(in: field.bounds))
        field.cacheDisplay(in: field.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

@MainActor
private final class RollingCountReferenceLabel: NSTextField {
    var parts: [(String, CGFloat)] = []

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        for (text, offset) in parts {
            stringValue = text
            NSGraphicsContext.saveGraphicsState()
            let translation = NSAffineTransform()
            translation.translateX(by: 0, yBy: offset)
            translation.concat()
            super.draw(bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
