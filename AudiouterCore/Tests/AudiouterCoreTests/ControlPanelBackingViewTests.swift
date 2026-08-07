// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudiouterSharedUI

/// The control-panel shell's bubble fill — since the 2026-08-07 canvas
/// unification the ONE surface canvas, `Tokens.Color.panel` (superseding
/// §5.4's `canvas`). The backing bubble (bubble + beak) must paint it LIVE in
/// BOTH appearances so shell chrome and the hosted transparent content read
/// as one warm shape, and a mid-session theme flip must repaint — the C3b
/// "half-render" class of bug (a fill frozen at one appearance) must not
/// recur.
@MainActor
@Suite final class ControlPanelBackingViewTests: IsolatedSuite {

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
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds), "no bitmap rep available in this environment")
        view.cacheDisplay(in: view.bounds, to: rep)
        let color = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2), "could not sample the rendered bubble")
        return color
    }

    /// `Tokens.Color.panel` resolved under `name` — dynamic tokens resolve
    /// against the CURRENT drawing appearance, so pin it explicitly.
    private func resolvedPanel(under name: NSAppearance.Name) throws -> NSColor {
        let appearance = try #require(NSAppearance(named: name), "appearance \(name.rawValue) unavailable")
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = Tokens.Color.panel.usingColorSpace(.sRGB)
        }
        let result = try #require(resolved, "panel token did not resolve to sRGB")
        return result
    }

    /// The resolved-component comparison idiom from
    /// `DeviceRowConnectionStateTests`/`RouteArmedSignalTests`.
    private func assertSameHue(_ a: NSColor?, _ b: NSColor?, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else {
            Issue.record("nil color: \(message)")
            return
        }
        #expect(abs(a.redComponent - b.redComponent) <= 0.02, "\(message) (red)")
        #expect(abs(a.greenComponent - b.greenComponent) <= 0.02, "\(message) (green)")
        #expect(abs(a.blueComponent - b.blueComponent) <= 0.02, "\(message) (blue)")
    }

    // MARK: The bubble fill is the one surface canvas (`panel`), both appearances

    @Test func bubbleFillIsWarmCanvasInDarkMode() throws {
        let view = makeBackingView()
        view.appearance = NSAppearance(named: .darkAqua)
        let sampled = try sampledBubbleCenterColor(of: view)
        assertSameHue(sampled, try resolvedPanel(under: .darkAqua),
                      "the bubble body must paint the warm `panel` token in dark mode")
    }

    @Test func bubbleFillIsWarmCanvasInLightMode() throws {
        let view = makeBackingView()
        view.appearance = NSAppearance(named: .aqua)
        let sampled = try sampledBubbleCenterColor(of: view)
        assertSameHue(sampled, try resolvedPanel(under: .aqua),
                      "the bubble body must paint the warm `panel` token in light mode")
    }

    /// The C3b guard, end-to-end on ONE view instance: render dark, flip the
    /// appearance, render again — the second render must produce the LIGHT
    /// canvas, proving the fill resolves live at every repaint rather than
    /// being frozen at the first appearance seen.
    @Test func sameViewRepaintsWarmCanvasAfterAppearanceFlip() throws {
        let view = makeBackingView()
        view.appearance = NSAppearance(named: .darkAqua)
        let darkSample = try sampledBubbleCenterColor(of: view)
        assertSameHue(darkSample, try resolvedPanel(under: .darkAqua),
                      "first render (dark) paints the dark panel canvas")

        view.appearance = NSAppearance(named: .aqua)
        let lightSample = try sampledBubbleCenterColor(of: view)
        assertSameHue(lightSample, try resolvedPanel(under: .aqua),
                      "after a theme flip the SAME view must repaint the light panel canvas — a frozen fill here is the C3b half-render bug")
    }

    /// A live in-window flip reaches the view as `viewDidChangeEffectiveAppearance`,
    /// and a custom `draw(_:)` is NOT re-invoked automatically — the override
    /// must mark the view dirty or the on-screen bubble keeps its stale fill.
    /// The view is hosted in a real (never-shown — headless rule) window, as it
    /// is in the shell's backing window: `needsDisplay` only sticks in-window.
    @Test func appearanceChangeMarksViewForRedisplay() {
        let view = makeBackingView()
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.needsDisplay = false
        view.viewDidChangeEffectiveAppearance()
        #expect(view.needsDisplay,
                "an appearance flip must schedule a repaint of the bubble fill")
    }

    // MARK: Hosted content composes over the warm fill

    /// The transparent-content mechanism (`configureContentAppearance`): the
    /// hosted view must stay TRANSPARENT (never an opaque fill of its own) so
    /// the backing bubble's live warm canvas shows through, with corners
    /// rounded to the bubble's radius so the two windows read as one shape.
    @Test func hostedContentStaysTransparentSoWarmFillShowsThrough() {
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let controller = ControlPanelWindowController(contentViewController: content)

        let hosted = try? #require(controller.window?.contentViewController?.view, "shell should host the content view controller's view")
        guard let hosted else { return }
        #expect(hosted.wantsLayer, "hosted view must be layer-backed for the corner mask")
        #expect(hosted.layer?.backgroundColor?.alpha ?? 0 == 0,
                "hosted content must stay transparent so the warm bubble fill shows through")
        #expect(hosted.layer?.cornerRadius == ControlPanelBackingView.cornerRadius,
                "hosted corners must match the bubble so the shell reads as one shape")
        #expect(hosted.layer?.masksToBounds == true)
    }
}
