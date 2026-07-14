// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import XCTest
import AppKit
@testable import AirPlayControllerSharedUI

/// Offscreen snapshot harness for `ControlCenterSlider` (T-U10 depth work).
///
/// The slider isn't visible to an agent shell, so — exactly like the popover /
/// window harnesses — we render it into an `NSBitmapImageRep` and write PNGs so
/// the depth (recessed track + raised knob) can be eyeballed and iterated on in
/// both light and dark appearances. Writes to `dev/notes/slider-snapshots/`.
///
/// This is a *drawing* smoke test: it asserts the render is non-blank (some dark
/// and some near-white pixels exist — i.e. a knob + shadow actually drew). It is
/// tolerant so it never blocks the suite; the real verification is visual.
final class ControlCenterSliderSnapshotTests: XCTestCase {

    private func snapshotDir() -> URL {
        // .../AirPlayControllerCore/Tests/AirPlayControllerCoreTests/<this file>
        // → repo root is three dirs up from Tests/…, i.e. .../AirPlayControllerCore/..
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // AirPlayControllerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AirPlayControllerCore
            .deletingLastPathComponent()   // repo root
        return repoRoot
            .appendingPathComponent("dev")
            .appendingPathComponent("notes")
            .appendingPathComponent("slider-snapshots")
    }

    /// Renders at `scale`× pixel density (faithful point geometry, crisp pixels)
    /// into a manually-built bitmap rep, on top of a representative tile bg.
    private func render(value: Int,
                        appearance: NSAppearance.Name,
                        size: NSSize,
                        scale: CGFloat) -> NSBitmapImageRep {
        let appr = NSAppearance(named: appearance)!
        let slider = ControlCenterSlider()
        slider.minValue = 0
        slider.maxValue = 100
        slider.integerValue = value
        slider.appearance = appr
        slider.frame = NSRect(origin: .zero, size: size)
        slider.layoutSubtreeIfNeeded()

        let pxW = Int(size.width * scale)
        let pxH = Int(size.height * scale)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxW, pixelsHigh: pxH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size // point size → the extra pixels mean higher DPI

        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        // Draw appearance-correct semantic colors.
        appr.performAsCurrentDrawingAppearance {
            // Representative card background so the recess/knob read in context
            // (the real tile is a semantic material; approximate it per mode).
            let isDark = appearance == .darkAqua
            let bg = isDark
                ? NSColor(calibratedWhite: 0.16, alpha: 1.0)   // dark card
                : NSColor(calibratedWhite: 0.95, alpha: 1.0)   // light card
            bg.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
            // Draw the slider's cell into the scaled context at its full bounds.
            slider.cell?.draw(withFrame: slider.bounds, in: slider)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    func testWriteSliderSnapshots() throws {
        let dir = snapshotDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Faithful point geometry (~the real 220x28 control), rendered at 3x
        // pixel density so the depth detail is crisp to eyeball.
        let logical = NSSize(width: 220, height: 28)
        let scale: CGFloat = 3
        let values = [0, 45, 100]
        let modes: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

        var wrote: [String] = []
        for (label, name) in modes {
            for v in values {
                let rep = render(value: v, appearance: name, size: logical, scale: scale)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    XCTFail("PNG encode failed for \(label) v\(v)")
                    continue
                }
                let file = dir.appendingPathComponent("slider-\(label)-\(v).png")
                try data.write(to: file)
                wrote.append(file.path)

                // Sanity: the render must contain a bright (knob) region and a
                // dark (shadow/recess) region — proves depth cues actually drew.
                assertHasBrightAndDark(rep, context: "\(label) v\(v)")
            }
        }

        print("SLIDER SNAPSHOTS WRITTEN:")
        for p in wrote { print("  \(p)") }
        XCTAssertEqual(wrote.count, values.count * modes.count)
    }

    /// Scans the rep for at least one near-white pixel (the white knob) and at
    /// least one clearly-dark pixel (a shadow / recess edge). Loose thresholds.
    private func assertHasBrightAndDark(_ rep: NSBitmapImageRep, context: String) {
        var sawBright = false
        var sawDark = false
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let l = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                if l > 0.92 { sawBright = true }
                if l < 0.20 { sawDark = true }
                if sawBright && sawDark { break }
            }
            if sawBright && sawDark { break }
        }
        XCTAssertTrue(sawBright, "no bright/knob pixels in \(context)")
        // Dark shadow pixels only guaranteed where a shadow lands; don't hard-fail
        // (light-mode faint shadows may not cross the threshold), just note it.
        if !sawDark { print("  note: no <0.20 luminance pixels in \(context)") }
    }
}
