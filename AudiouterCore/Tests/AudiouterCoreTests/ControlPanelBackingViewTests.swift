// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterSharedUI

/// Warm Signal §5.4 (W8) — the control-panel shell's bubble fill. The backing
/// bubble (bubble + beak) must paint the warm `canvas` token LIVE in BOTH
/// appearances so shell chrome and the hosted transparent content read as one
/// warm shape, and a mid-session theme flip must repaint — the C3b
/// "half-render" class of bug (a fill frozen at one appearance) must not recur.
@MainActor
final class ControlPanelBackingViewTests: IsolatedTestCase {

    // MARK: Helpers

    private func makeBackingView() -> ControlPanelBackingView {
        ControlPanelBackingView(
            frame: NSRect(x: 0, y: 0,
                          width: 200,
                          height: 120 + ControlPanelBackingView.beakHeight))
    }

    /// Offscreen-render `view` (via the `cacheDisplay` snapshot path — the
    /// same idiom the popover/settings snapshot tools use) and sample the
    /// pixel at the center of its bounds, which lies inside the bubble body.
    private func sampledBubbleCenterColor(of view: ControlPanelBackingView,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) throws -> NSColor {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw XCTSkip("no bitmap rep available in this environment")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let color = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2) else {
            XCTFail("could not sample the rendered bubble", file: file, line: line)
            throw XCTSkip("unsampleable bitmap")
        }
        return color
    }

    /// `Tokens.Color.canvas` resolved under `name` — dynamic tokens resolve
    /// against the CURRENT drawing appearance, so pin it explicitly.
    private func resolvedCanvas(under name: NSAppearance.Name) throws -> NSColor {
        guard let appearance = NSAppearance(named: name) else {
            throw XCTSkip("appearance \(name.rawValue) unavailable")
        }
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = Tokens.Color.canvas.usingColorSpace(.sRGB)
        }
        guard let resolved else { throw XCTSkip("canvas token did not resolve to sRGB") }
        return resolved
    }

    /// The resolved-component comparison idiom from
    /// `DeviceRowConnectionStateTests`/`RouteArmedSignalTests`.
    private func assertSameHue(_ a: NSColor?, _ b: NSColor?, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else {
            return XCTFail("nil color: \(message)", file: file, line: line)
        }
        XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.02, message, file: file, line: line)
        XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.02, message, file: file, line: line)
        XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.02, message, file: file, line: line)
    }

    // MARK: §5.4 — the bubble fill is the warm canvas token, both appearances

    func testBubbleFillIsWarmCanvasInDarkMode() throws {
        let view = makeBackingView()
        view.appearance = NSAppearance(named: .darkAqua)
        let sampled = try sampledBubbleCenterColor(of: view)
        assertSameHue(sampled, try resolvedCanvas(under: .darkAqua),
                      "the bubble body must paint the warm `canvas` token in dark mode")
    }

    func testBubbleFillIsWarmCanvasInLightMode() throws {
        let view = makeBackingView()
        view.appearance = NSAppearance(named: .aqua)
        let sampled = try sampledBubbleCenterColor(of: view)
        assertSameHue(sampled, try resolvedCanvas(under: .aqua),
                      "the bubble body must paint the warm `canvas` token in light mode")
    }

    /// The C3b guard, end-to-end on ONE view instance: render dark, flip the
    /// appearance, render again — the second render must produce the LIGHT
    /// canvas, proving the fill resolves live at every repaint rather than
    /// being frozen at the first appearance seen.
    func testSameViewRepaintsWarmCanvasAfterAppearanceFlip() throws {
        let view = makeBackingView()
        view.appearance = NSAppearance(named: .darkAqua)
        let darkSample = try sampledBubbleCenterColor(of: view)
        assertSameHue(darkSample, try resolvedCanvas(under: .darkAqua),
                      "first render (dark) paints the dark canvas")

        view.appearance = NSAppearance(named: .aqua)
        let lightSample = try sampledBubbleCenterColor(of: view)
        assertSameHue(lightSample, try resolvedCanvas(under: .aqua),
                      "after a theme flip the SAME view must repaint the light canvas — "
                      + "a frozen fill here is the C3b half-render bug")
    }

    /// A live in-window flip reaches the view as `viewDidChangeEffectiveAppearance`,
    /// and a custom `draw(_:)` is NOT re-invoked automatically — the override
    /// must mark the view dirty or the on-screen bubble keeps its stale fill.
    /// The view is hosted in a real (never-shown — headless rule) window, as it
    /// is in the shell's backing window: `needsDisplay` only sticks in-window.
    func testAppearanceChangeMarksViewForRedisplay() {
        let view = makeBackingView()
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.needsDisplay = false
        view.viewDidChangeEffectiveAppearance()
        XCTAssertTrue(view.needsDisplay,
                      "an appearance flip must schedule a repaint of the bubble fill")
    }

    // MARK: §5.4 — hosted content composes over the warm fill

    /// The transparent-content mechanism (`configureContentAppearance`): the
    /// hosted view must stay TRANSPARENT (never an opaque fill of its own) so
    /// the backing bubble's live warm canvas shows through, with corners
    /// rounded to the bubble's radius so the two windows read as one shape.
    func testHostedContentStaysTransparentSoWarmFillShowsThrough() {
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let controller = ControlPanelWindowController(contentViewController: content)

        guard let hosted = controller.window?.contentViewController?.view else {
            return XCTFail("shell should host the content view controller's view")
        }
        XCTAssertTrue(hosted.wantsLayer, "hosted view must be layer-backed for the corner mask")
        XCTAssertEqual(hosted.layer?.backgroundColor?.alpha, 0,
                       "hosted content must stay transparent so the warm bubble fill shows through")
        XCTAssertEqual(hosted.layer?.cornerRadius, ControlPanelBackingView.cornerRadius,
                       "hosted corners must match the bubble so the shell reads as one shape")
        XCTAssertEqual(hosted.layer?.masksToBounds, true)
    }
}
