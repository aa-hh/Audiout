// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterSharedUI

/// The **derived app→device tether colour** (`AppTetherColor`, Warm Signal v4
/// §Call 2). Feeds synthetic solid-colour and gradient icons through the pure
/// derivation and asserts the locked invariants: determinism, the reserved-band
/// steering (pure red clears the failure band, pure orange clears the gold
/// band), blue stays blue, greyscale hits the neutral fallback, and the
/// collision nudge separates two identical inputs — plus a sanity check that the
/// four canonical brand apps land in their warm-adapted neighbourhoods.
@MainActor
final class AppTetherColorTests: IsolatedTestCase {

    override func setUp() {
        super.setUp()
        AppTetherColor.clearCache()
    }

    // MARK: Fixtures

    /// A solid-colour icon built from an sRGB hex (so the sampled hue round-trips
    /// to what the brand ships).
    private func solidIcon(_ hex: UInt32, side: CGFloat = 48) -> NSImage {
        solidIcon(color(hex))
    }

    private func solidIcon(_ fill: NSColor, side: CGFloat = 48) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        fill.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.unlockFocus()
        return image
    }

    /// A two-stop vertical gradient icon (a non-flat input for the determinism
    /// check).
    private func gradientIcon(_ top: UInt32, _ bottom: UInt32, side: CGFloat = 48) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        let gradient = NSGradient(starting: color(top), ending: color(bottom))
        gradient?.draw(in: NSRect(x: 0, y: 0, width: side, height: side), angle: 90)
        image.unlockFocus()
        return image
    }

    private func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Resolve a (possibly dynamic) `NSColor` to sRGB HSB under a fixed
    /// appearance — the deterministic way to read what a tether renders as.
    private func resolvedHSB(_ nsColor: NSColor, dark: Bool)
        -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var out = (hue: CGFloat(0), saturation: CGFloat(0), brightness: CGFloat(0))
        appearance.performAsCurrentDrawingAppearance {
            if let c = nsColor.usingColorSpace(.sRGB) {
                out = (c.hueComponent * 360, c.saturationComponent, c.brightnessComponent)
            }
        }
        return out
    }

    // MARK: (a) Determinism

    func test_determinism_sameIconYieldsIdenticalColorTwice() {
        let icon = solidIcon(0x1DB954)   // Spotify green

        AppTetherColor.clearCache()
        let first = AppTetherColor.color(forBundleID: "com.spotify.client", icon: icon)
        AppTetherColor.clearCache()
        let second = AppTetherColor.color(forBundleID: "com.spotify.client", icon: icon)

        for dark in [true, false] {
            let a = resolvedHSB(first, dark: dark)
            let b = resolvedHSB(second, dark: dark)
            XCTAssertEqual(a.hue, b.hue, accuracy: 0.001, "hue drift (dark=\(dark))")
            XCTAssertEqual(a.saturation, b.saturation, accuracy: 0.001, "sat drift (dark=\(dark))")
            XCTAssertEqual(a.brightness, b.brightness, accuracy: 0.001, "bri drift (dark=\(dark))")
        }
        // The underlying derivation is value-equal too.
        XCTAssertEqual(AppTetherColor.deriveTone(from: icon), AppTetherColor.deriveTone(from: icon))
    }

    func test_determinism_gradientIconIsStable() {
        let icon = gradientIcon(0xFF7139, 0xC08457)
        XCTAssertEqual(AppTetherColor.deriveTone(from: icon), AppTetherColor.deriveTone(from: icon))
    }

    // MARK: (b) Pure red clears the failure-red band

    func test_pureRed_steersOutOfFailureBand() {
        guard case .tinted(let tone) = AppTetherColor.deriveTone(from: solidIcon(0xFF0000)) else {
            return XCTFail("pure red should derive a tint")
        }
        XCTAssertFalse(AppTetherColor.ReservedBand.failureRed.contains(tone.hue),
                       "steered red hue \(tone.hue) still inside the failure band")
        XCTAssertFalse(AppTetherColor.ReservedBand.goldAmber.contains(tone.hue))
        // Landed on the rose/pink (magenta) side.
        XCTAssertTrue(tone.hue >= 325 && tone.hue < 350,
                      "expected rose, got \(tone.hue)")
    }

    // MARK: (c) Pure orange clears the gold/amber band

    func test_pureOrange_steersOutOfGoldBand() {
        for hex in [UInt32(0xFFA500), 0xFFC000] {   // orange, amber — both inside [28,68)
            guard case .tinted(let tone) = AppTetherColor.deriveTone(from: solidIcon(hex)) else {
                return XCTFail("orange should derive a tint")
            }
            XCTAssertFalse(AppTetherColor.ReservedBand.goldAmber.contains(tone.hue),
                           "steered orange hue \(tone.hue) still inside the gold band")
            XCTAssertFalse(AppTetherColor.ReservedBand.failureRed.contains(tone.hue))
            XCTAssertTrue(tone.hue >= AppTetherColor.terracottaLow - 1
                          && tone.hue <= AppTetherColor.terracottaHigh + 1,
                          "expected terracotta corridor, got \(tone.hue)")
        }
    }

    // MARK: (d) Blue stays blue-ish

    func test_blue_staysBlue() {
        for hex in [UInt32(0x1C9BF0), 0x0000FF] {
            guard case .tinted(let tone) = AppTetherColor.deriveTone(from: solidIcon(hex)) else {
                return XCTFail("blue should derive a tint")
            }
            XCTAssertTrue(tone.hue >= 180 && tone.hue <= 270,
                          "blue drifted out of the blue range: \(tone.hue)")
            XCTAssertFalse(AppTetherColor.ReservedBand.failureRed.contains(tone.hue))
            XCTAssertFalse(AppTetherColor.ReservedBand.goldAmber.contains(tone.hue))
        }
    }

    // MARK: (e) Greyscale hits the neutral fallback

    func test_greyscale_fallsBackToNeutral() {
        for hex in [UInt32(0x808080), 0x2A2A2A, 0xEDEDED] {
            XCTAssertEqual(AppTetherColor.deriveTone(from: solidIcon(hex)), .neutral,
                           "grey \(String(hex, radix: 16)) should have no dominant hue")
        }
        XCTAssertEqual(AppTetherColor.deriveTone(from: nil), .neutral)

        // The emitted colour is the neutral link tone.
        let derived = AppTetherColor.color(forBundleID: "com.example.grey", icon: solidIcon(0x808080))
        let expected = AppTetherColor.neutralFallback
        for dark in [true, false] {
            let a = resolvedHSB(derived, dark: dark)
            let b = resolvedHSB(expected, dark: dark)
            XCTAssertEqual(a.hue, b.hue, accuracy: 0.5)
            XCTAssertEqual(a.saturation, b.saturation, accuracy: 0.01)
            XCTAssertEqual(a.brightness, b.brightness, accuracy: 0.01)
        }
    }

    // MARK: (f) The nudge helper separates two identical inputs

    func test_nudge_separatesTwoIdenticalIcons() {
        let icon = solidIcon(0x1C9BF0)   // Safari blue, twice
        let colors = AppTetherColor.colors(forKeyedIcons: [("a", icon), ("b", icon)])
        let a = resolvedHSB(colors["a"]!, dark: true)
        let b = resolvedHSB(colors["b"]!, dark: true)
        XCTAssertGreaterThanOrEqual(AppTetherColor.circularDistance(a.hue, b.hue),
                                    AppTetherColor.defaultMinimumHueSeparation - 1,
                                    "identical icons were not nudged apart")
    }

    func test_nudge_isDeterministicByKey() {
        let icon = solidIcon(0x1C9BF0)
        let first = AppTetherColor.colors(forKeyedIcons: [("a", icon), ("b", icon)])
        let second = AppTetherColor.colors(forKeyedIcons: [("b", icon), ("a", icon)])   // reordered input
        for key in ["a", "b"] {
            let x = resolvedHSB(first[key]!, dark: true)
            let y = resolvedHSB(second[key]!, dark: true)
            XCTAssertEqual(x.hue, y.hue, accuracy: 0.001, "nudge not stable for key \(key)")
        }
    }

    func test_nudgedHue_avoidsReservedBandsWhenRotating() {
        // A rotation step that would land inside a reserved band must re-steer.
        let taken: [CGFloat] = [200]
        let nudged = AppTetherColor.nudgedHue(200, awayFrom: taken, minimumSeparation: 20)
        XCTAssertGreaterThanOrEqual(AppTetherColor.circularDistance(200, nudged), 19)
        XCTAssertFalse(AppTetherColor.ReservedBand.failureRed.contains(nudged))
        XCTAssertFalse(AppTetherColor.ReservedBand.goldAmber.contains(nudged))
    }

    // MARK: (g) No derived tint ever renders as (near-)black

    /// Regression for the "solid black Firefox chip": the real Firefox icon's
    /// dominant *saturated* hue is the violet globe (~265°, a cool-family hue),
    /// not the orange fox — and a cool hue dropped for warm paper (0.66 − 0.28 =
    /// 0.38), or a gold-steered orange likewise dropped and Increase-Contrast-
    /// darkened (~0.33), used to bottom out dark enough to read as black against
    /// the near-black canvas at the 5pt chip. The legibility floor now caps that.
    func test_derivedTint_neverDarkerThanLegibilityFloor() {
        // Darkest inputs: a gold-steered orange (warm, steered) and a cool green.
        let orange = AppTetherColor.deriveTone(from: solidIcon(0xFFA500))
        let green  = AppTetherColor.deriveTone(from: solidIcon(0x1DB954))
        for tone in [orange, green] {
            guard case .tinted(let t) = tone else { return XCTFail("expected a tint") }
            for dark in [true, false] {
                for ic in [true, false] {
                    let c = AppTetherColor.components(for: t, dark: dark, increaseContrast: ic)
                    XCTAssertGreaterThanOrEqual(
                        c.brightness, AppTetherColor.minimumLegibleBrightness,
                        "tone \(t) below the legibility floor (dark=\(dark), ic=\(ic))")
                }
            }
        }
    }

    /// The floor caps darkness WITHOUT inverting the reserved-band steering it
    /// exists to guarantee: a gold-steered orange stays in the terracotta
    /// corridor and clears both reserved bands even after the brightness cap.
    func test_legibilityFloor_preservesReservedBandSteering() {
        guard case .tinted(let t) = AppTetherColor.deriveTone(from: solidIcon(0xFFA500)) else {
            return XCTFail("orange should derive a tint")
        }
        XCTAssertTrue(t.goldSteered, "0xFFA500 should have gold-steered")
        XCTAssertFalse(AppTetherColor.ReservedBand.goldAmber.contains(t.hue))
        XCTAssertFalse(AppTetherColor.ReservedBand.failureRed.contains(t.hue))
        // Floor binds on the warm-paper variant but leaves the hue untouched.
        let light = AppTetherColor.components(for: t, dark: false, increaseContrast: false)
        XCTAssertEqual(light.brightness, AppTetherColor.minimumLegibleBrightness, accuracy: 0.0001)
        XCTAssertEqual(light.hue, t.hue, accuracy: 0.001)
    }

    // MARK: Appearance variants (light + dark + Increase Contrast)

    func test_toneHasDistinctLightDarkAndIncreaseContrastVariants() {
        guard case .tinted(let tone) = AppTetherColor.deriveTone(from: solidIcon(0x1DB954)) else {
            return XCTFail()
        }
        let dark = AppTetherColor.components(for: tone, dark: true, increaseContrast: false)
        let light = AppTetherColor.components(for: tone, dark: false, increaseContrast: false)
        let darkIC = AppTetherColor.components(for: tone, dark: true, increaseContrast: true)

        // Same hue across appearances; only lightness/saturation move.
        XCTAssertEqual(dark.hue, light.hue, accuracy: 0.001)
        // Text on warm paper is darker than on the warm-dark canvas.
        XCTAssertLessThan(light.brightness, dark.brightness)
        // Increase Contrast pushes the dark variant brighter and a touch more saturated.
        XCTAssertGreaterThan(darkIC.brightness, dark.brightness)
        XCTAssertGreaterThanOrEqual(darkIC.saturation, dark.saturation)
    }

    // MARK: Sanity — the four canonical brand apps land near the spec swatches

    func test_canonicalApps_landInWarmNeighbourhoodsAndClearBands() {
        // (input brand hex, expected warm-adapted hue window)
        let cases: [(name: String, hex: UInt32, low: CGFloat, high: CGFloat)] = [
            ("Spotify", 0x1DB954, 128, 165),   // sage green   (~#6FA98C)
            ("YouTube", 0xFF0000, 325, 350),   // rose         (~#C56B72, off failure)
            ("Firefox", 0xFF7139, 12, 28),     // terracotta   (~#C08457, off gold)
            ("Safari",  0x1C9BF0, 185, 215),   // teal         (~#5E93A8)
        ]
        for c in cases {
            guard case .tinted(let tone) = AppTetherColor.deriveTone(from: solidIcon(c.hex)) else {
                return XCTFail("\(c.name) should derive a tint")
            }
            XCTAssertTrue(tone.hue >= c.low && tone.hue <= c.high,
                          "\(c.name) hue \(tone.hue) outside [\(c.low),\(c.high)]")
            XCTAssertFalse(AppTetherColor.ReservedBand.failureRed.contains(tone.hue),
                           "\(c.name) landed in the failure band")
            XCTAssertFalse(AppTetherColor.ReservedBand.goldAmber.contains(tone.hue),
                           "\(c.name) landed in the gold band")

            // The warm-adapted output is desaturated and legibly bright on the
            // dark canvas.
            let render = AppTetherColor.components(for: tone, dark: true, increaseContrast: false)
            XCTAssertLessThanOrEqual(render.saturation, 0.55, "\(c.name) not desaturated")
            XCTAssertTrue(render.brightness >= 0.55 && render.brightness <= 0.85,
                          "\(c.name) brightness \(render.brightness) off warm-dark range")
        }
    }
}
