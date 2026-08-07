// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI
@testable import AudiouterSharedUI

/// **The ring/rail tone coupling.** The membership rail's hook curves up out of
/// the gutter and lands on the Main Audio ring: the two are REQUIRED to read as
/// one continuous line, so the ring's connected stroke and the rail's ink must
/// be the same colour in every state the app can be in. That agreement used to
/// be pure convention — two call sites that each happened to name
/// `Tokens.Color.gold`/`ember` — and the accent dial broke it live: flipping to
/// Follow-System re-tinted the rail (it resolves its tokens inside `draw(_:)`)
/// while the ring kept the old gold (it stamps a resolved `CGColor` onto a
/// `CALayer`, and no accent-dial signal re-stamped it).
///
/// These tests lock BOTH halves of the fix:
///  - the drawn rail ink and the ring's stamped stroke agree for every accent
///    dial position x light/dark x armed/ember — sampled from a real
///    `cacheDisplay` render of `BusRailOverlayView` and from the ring's actual
///    layer colour, never from a re-derived expectation;
///  - a dial change re-tints the ring with NO rebuild and no `apply` — the
///    regression that shipped.
///
/// Nested in `SerializedSharedState` for the same reason
/// `OnboardingPermissionColorTests` is: `Tokens.accentStyle` is a process-global
/// (the live remap seam), and a concurrent write races these colour reads.
extension SerializedSharedState {

@MainActor
@Suite final class RingRailToneLockTests {

    deinit {
        // Restore the flagship default so no later suite (or golden render) in
        // this process inherits a dialed accent.
        Tokens.accentStyle = .fullGold
    }

    private struct TestEnvironmentLimitation: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: Harness

    /// A laid-out Main Audio row + the panel-level rail overlay wired to it,
    /// under an explicit appearance — the real pair, in the real relationship.
    private func makePair(appearanceName: NSAppearance.Name)
        -> (container: NSView, row: MainOutRowView, overlay: BusRailOverlayView) {
        let appearance = NSAppearance(named: appearanceName)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        container.appearance = appearance

        let row = MainOutRowView()
        row.frame = NSRect(x: 0, y: 60, width: 360, height: MainOutRowView.rowHeight)
        container.addSubview(row)

        let overlay = BusRailOverlayView()
        overlay.frame = container.bounds
        container.addSubview(overlay)
        overlay.mainOutRow = row

        container.layoutSubtreeIfNeeded()
        return (container, row, overlay)
    }

    private func apply(_ row: MainOutRowView, armed: Bool) {
        // Armed = connected ∧ unmuted; a muted connected target is the ember
        // half of the same pair (the ring still renders its `.connected` form).
        row.apply(options: [.init(title: "Selected Devices (1)", target: .selectedDevices,
                                  buttonTitle: "Selected (1)")],
                  current: .selectedDevices, master: 50, isMuted: !armed,
                  connectionState: .connected)
        row.layoutSubtreeIfNeeded()
    }

    /// The rail's ACTUAL drawn ink: render the overlay offscreen (the same
    /// `cacheDisplay` idiom `GroupsWindowTextColorLockTests` uses) and take the
    /// most opaque pixel. With no device rows the only thing `drawPlan` paints
    /// is the origin hook — the very curve that has to match the ring — so this
    /// needs no geometry assumptions beyond "the hook is on screen".
    private func sampledRailInk(of overlay: BusRailOverlayView) throws -> NSColor {
        guard let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else {
            throw TestEnvironmentLimitation(description: "no bitmap rep available in this environment")
        }
        overlay.cacheDisplay(in: overlay.bounds, to: rep)
        // The hook's lower end lands ON the gutter column, so a narrow band
        // around `railGutterCenterX` always carries ink — scanning only it
        // keeps this sweep cheap enough to run 20 renders.
        let scale = CGFloat(rep.pixelsWide) / overlay.bounds.width
        let centerX = Int((PopoverColumnGrid.railGutterCenterX * scale).rounded())
        let band = max(0, centerX - 2)...min(rep.pixelsWide - 1, centerX + 2)
        var best: NSColor?
        var bestAlpha: CGFloat = 0
        for y in 0..<rep.pixelsHigh {
            for x in band {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.alphaComponent > bestAlpha {
                    bestAlpha = c.alphaComponent
                    best = c
                }
            }
        }
        guard let best, bestAlpha >= 0.99 else {
            throw TestEnvironmentLimitation(
                description: "the overlay drew no opaque ink (max alpha \(bestAlpha)) — the hook never rendered")
        }
        return best
    }

    /// Resolve a token under an explicit appearance, exactly as AppKit resolves
    /// a dynamic provider at draw time.
    private func resolved(_ color: NSColor, _ appearanceName: NSAppearance.Name) -> NSColor {
        var out = color
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    private func expectSameInk(_ a: NSColor?, _ b: NSColor?, _ message: String) {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else {
            Issue.record("nil or non-convertible colour: \(message)")
            return
        }
        let same = abs(a.redComponent - b.redComponent) <= 0.02
            && abs(a.greenComponent - b.greenComponent) <= 0.02
            && abs(a.blueComponent - b.blueComponent) <= 0.02
        #expect(same, "\(message) — expected \(a), got \(b)")
    }

    // MARK: 1 — the sweep: every dial position x appearance x armed/ember

    /// The whole matrix. For each accent-dial position and each appearance, the
    /// ring's stamped connected stroke must equal the rail's drawn ink — for
    /// the armed (gold) tone AND the unarmed (ember) tone.
    @Test func ringStrokeMatchesRailInkAcrossEveryDialPositionAndAppearance() throws {
        for style in AccentStyle.allCases {
            Tokens.accentStyle = style
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                for armed in [true, false] {
                    let (_, row, overlay) = makePair(appearanceName: appearanceName)
                    apply(row, armed: armed)

                    let plan = try #require(overlay.test_resolvePlan(),
                                            "the overlay must resolve a plan from the laid-out row")
                    #expect(plan.gold == armed,
                            "the rail's own armed bit must track the row's (\(style)/\(appearanceName.rawValue))")

                    let railInk = try sampledRailInk(of: overlay)
                    expectSameInk(railInk, row.test_ringStrokeColor,
                                  "\(style)/\(appearanceName.rawValue)/armed=\(armed): the hook and the ring it lands on must be one colour")

                    // …and both must be THE shared spine tone, not a coincidence.
                    expectSameInk(railInk, resolved(Tokens.Color.spineTone(armed: armed), appearanceName),
                                  "\(style)/\(appearanceName.rawValue)/armed=\(armed): the drawn ink must be Tokens.Color.spineTone")
                }
            }
        }
    }

    // MARK: 2 — the live dial flip: no rebuild, no apply

    /// The shipped regression, exactly: build the pair, then move the dial and
    /// touch NOTHING else. The rail re-resolves on its next draw by
    /// construction; the ring has to re-stamp off the accent broadcast. Against
    /// the unfixed code the ring keeps its first-stamped gold here.
    @Test func aDialFlipRetintsTheRingWithNoRebuild() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for armed in [true, false] {
                Tokens.accentStyle = .fullGold
                let (_, row, overlay) = makePair(appearanceName: appearanceName)
                apply(row, armed: armed)
                let firstInk = try sampledRailInk(of: overlay)
                expectSameInk(firstInk, row.test_ringStrokeColor,
                              "baseline: the pair starts coupled (\(appearanceName.rawValue)/armed=\(armed))")

                for style: AccentStyle in [.systemAccent, .subtle, .fullGold] {
                    Tokens.accentStyle = style      // the ONLY thing that happens
                    overlay.needsDisplay = true     // the rail's own repaint path

                    let ink = try sampledRailInk(of: overlay)
                    expectSameInk(ink, row.test_ringStrokeColor,
                                  "after flipping the dial to \(style) with no rebuild (\(appearanceName.rawValue)/armed=\(armed)), the ring must re-tint with the rail")
                    expectSameInk(ink, resolved(Tokens.Color.spineTone(armed: armed), appearanceName),
                                  "after flipping the dial to \(style), both must be the current spine tone")
                }
            }
        }
    }

    // MARK: 3 — scope guard: the device rows' ring is NOT on the dial

    /// The coupling is the MAIN AUDIO pair only. A device row's ring keeps the
    /// hue-neutral `ringConnected` token, which the dial never remaps — the
    /// a11y plan re-baselines that hex, so it must stay a hex.
    @Test func aDeviceRowRingStaysHueNeutralInEveryDialPosition() {
        let ring = HaloRingView()
        ring.appearance = NSAppearance(named: .darkAqua)
        ring.apply(.connected)                      // no `connectedSpineArmed`
        for style in AccentStyle.allCases {
            Tokens.accentStyle = style      // the broadcast re-stamps it in place
            expectSameInk(resolved(Tokens.Color.ringConnected, .darkAqua), ring.test_strokeColor,
                          "a device row's connected ring must stay ringConnected under \(style)")
        }
    }
}

}
