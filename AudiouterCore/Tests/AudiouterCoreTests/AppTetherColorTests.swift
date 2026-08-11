// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
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
@Suite final class AppTetherColorTests: IsolatedSuite {

    override init() {
        super.init()
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

    @Test func determinism_sameIconYieldsIdenticalColorTwice() {
        let icon = solidIcon(0x1DB954)   // Spotify green

        AppTetherColor.clearCache()
        let first = AppTetherColor.color(forBundleID: "com.spotify.client", icon: icon)
        AppTetherColor.clearCache()
        let second = AppTetherColor.color(forBundleID: "com.spotify.client", icon: icon)

        for dark in [true, false] {
            let a = resolvedHSB(first, dark: dark)
            let b = resolvedHSB(second, dark: dark)
            #expect(abs(a.hue - b.hue) <= 0.001, "hue drift (dark=\(dark))")
            #expect(abs(a.saturation - b.saturation) <= 0.001, "sat drift (dark=\(dark))")
            #expect(abs(a.brightness - b.brightness) <= 0.001, "bri drift (dark=\(dark))")
        }
        // The underlying derivation is value-equal too.
        #expect(AppTetherColor.deriveTone(from: icon) == AppTetherColor.deriveTone(from: icon))
    }

    @Test func determinism_gradientIconIsStable() {
        let icon = gradientIcon(0xFF7139, 0xC08457)
        #expect(AppTetherColor.deriveTone(from: icon) == AppTetherColor.deriveTone(from: icon))
    }

    // MARK: (b) Pure red clears the failure-red band

    @Test func pureRed_steersOutOfFailureBand() {
        guard case .tinted(let tone) = AppTetherColor.deriveTone(from: solidIcon(0xFF0000)) else {
            Issue.record("pure red should derive a tint")
            return
        }
        #expect(!(AppTetherColor.ReservedBand.failureRed.contains(tone.hue)), "steered red hue \(tone.hue) still inside the failure band")
        #expect(!(AppTetherColor.ReservedBand.goldAmber.contains(tone.hue)))
        // Landed on the rose/pink (magenta) side.
        #expect(tone.hue >= 325 && tone.hue < 350, "expected rose, got \(tone.hue)")
    }

    // MARK: (c) Pure orange clears the gold/amber band

    @Test func pureOrange_steersOutOfGoldBand() {
        for hex in [UInt32(0xFFA500), 0xFFC000] {   // orange, amber — both inside [28,68)
            guard case .tinted(let tone) = AppTetherColor.deriveTone(from: solidIcon(hex)) else {
                Issue.record("orange should derive a tint")
                return
            }
            #expect(!(AppTetherColor.ReservedBand.goldAmber.contains(tone.hue)), "steered orange hue \(tone.hue) still inside the gold band")
            #expect(!(AppTetherColor.ReservedBand.failureRed.contains(tone.hue)))
            #expect(tone.hue >= AppTetherColor.terracottaLow - 1
                          && tone.hue <= AppTetherColor.terracottaHigh + 1, "expected terracotta corridor, got \(tone.hue)")
        }
    }

    // MARK: (d) Blue stays blue-ish

    @Test func blue_staysBlue() {
        for hex in [UInt32(0x1C9BF0), 0x0000FF] {
            guard case .tinted(let tone) = AppTetherColor.deriveTone(from: solidIcon(hex)) else {
                Issue.record("blue should derive a tint")
                return
            }
            #expect(tone.hue >= 180 && tone.hue <= 270, "blue drifted out of the blue range: \(tone.hue)")
            #expect(!(AppTetherColor.ReservedBand.failureRed.contains(tone.hue)))
            #expect(!(AppTetherColor.ReservedBand.goldAmber.contains(tone.hue)))
        }
    }

    // MARK: (e) Greyscale hits the neutral fallback

    @Test func greyscale_fallsBackToNeutral() {
        for hex in [UInt32(0x808080), 0x2A2A2A, 0xEDEDED] {
            #expect(AppTetherColor.deriveTone(from: solidIcon(hex)) == .neutral, "grey \(String(hex, radix: 16)) should have no dominant hue")
        }
        #expect(AppTetherColor.deriveTone(from: nil) == .neutral)

        // The emitted colour is the neutral link tone.
        let derived = AppTetherColor.color(forBundleID: "com.example.grey", icon: solidIcon(0x808080))
        let expected = AppTetherColor.neutralFallback
        for dark in [true, false] {
            let a = resolvedHSB(derived, dark: dark)
            let b = resolvedHSB(expected, dark: dark)
            #expect(abs(a.hue - b.hue) <= 0.5)
            #expect(abs(a.saturation - b.saturation) <= 0.01)
            #expect(abs(a.brightness - b.brightness) <= 0.01)
        }
    }

    // MARK: (f) The nudge helper separates two identical inputs

    @Test func nudge_separatesTwoIdenticalIcons() {
        let icon = solidIcon(0x1C9BF0)   // Safari blue, twice
        let colors = AppTetherColor.colors(forKeyedIcons: [("a", icon), ("b", icon)])
        let a = resolvedHSB(colors["a"]!, dark: true)
        let b = resolvedHSB(colors["b"]!, dark: true)
        #expect(AppTetherColor.circularDistance(a.hue, b.hue) >= AppTetherColor.defaultMinimumHueSeparation - 1, "identical icons were not nudged apart")
    }

    @Test func nudge_isDeterministicByKey() {
        let icon = solidIcon(0x1C9BF0)
        let first = AppTetherColor.colors(forKeyedIcons: [("a", icon), ("b", icon)])
        let second = AppTetherColor.colors(forKeyedIcons: [("b", icon), ("a", icon)])   // reordered input
        for key in ["a", "b"] {
            let x = resolvedHSB(first[key]!, dark: true)
            let y = resolvedHSB(second[key]!, dark: true)
            #expect(abs(x.hue - y.hue) <= 0.001, "nudge not stable for key \(key)")
        }
    }

    @Test func nudgedHue_avoidsReservedBandsWhenRotating() {
        // A rotation step that would land inside a reserved band must re-steer.
        let taken: [CGFloat] = [200]
        let nudged = AppTetherColor.nudgedHue(200, awayFrom: taken, minimumSeparation: 20)
        #expect(AppTetherColor.circularDistance(200, nudged) >= 19)
        #expect(!(AppTetherColor.ReservedBand.failureRed.contains(nudged)))
        #expect(!(AppTetherColor.ReservedBand.goldAmber.contains(nudged)))
    }

    // MARK: (g) No derived tint ever renders as (near-)black

    /// Regression for the "solid black Firefox chip": the real Firefox icon's
    /// dominant *saturated* hue is the violet globe (~265°, a cool-family hue),
    /// not the orange fox — and a cool hue dropped for the light ground (0.66 −
    /// 0.40 = 0.26), or a gold-steered orange likewise dropped and Increase-Contrast-
    /// darkened (~0.33), used to bottom out dark enough to read as black against
    /// the near-black canvas at the 5pt chip. The legibility floor now caps that.
    @Test func derivedTint_neverDarkerThanLegibilityFloor() {
        // Darkest inputs: a gold-steered orange (warm, steered) and a cool green.
        let orange = AppTetherColor.deriveTone(from: solidIcon(0xFFA500))
        let green  = AppTetherColor.deriveTone(from: solidIcon(0x1DB954))
        for tone in [orange, green] {
            guard case .tinted(let t) = tone else {
                Issue.record("expected a tint")
                return
            }
            for dark in [true, false] {
                for ic in [true, false] {
                    let c = AppTetherColor.components(for: t, dark: dark, increaseContrast: ic)
                    #expect(c.brightness >= AppTetherColor.minimumLegibleBrightness, "tone \(t) below the legibility floor (dark=\(dark), ic=\(ic))")
                }
            }
        }
    }

    /// The floor caps darkness WITHOUT inverting the reserved-band steering it
    /// exists to guarantee: a gold-steered orange stays in the terracotta
    /// corridor and clears both reserved bands even after the brightness cap.
    @Test func legibilityFloor_preservesReservedBandSteering() {
        guard case .tinted(let t) = AppTetherColor.deriveTone(from: solidIcon(0xFFA500)) else {
            Issue.record("orange should derive a tint")
            return
        }
        #expect(t.goldSteered, "0xFFA500 should have gold-steered")
        #expect(!(AppTetherColor.ReservedBand.goldAmber.contains(t.hue)))
        #expect(!(AppTetherColor.ReservedBand.failureRed.contains(t.hue)))
        // Floor binds on the warm-paper variant but leaves the hue untouched.
        let light = AppTetherColor.components(for: t, dark: false, increaseContrast: false)
        #expect(abs(light.brightness - AppTetherColor.minimumLegibleBrightness) <= 0.0001)
        #expect(abs(light.hue - t.hue) <= 0.001)
    }

    // MARK: Appearance variants (light + dark + Increase Contrast)

    @Test func toneHasDistinctLightDarkAndIncreaseContrastVariants() {
        guard case .tinted(let tone) = AppTetherColor.deriveTone(from: solidIcon(0x1DB954)) else {
            Issue.record()
            return
        }
        let dark = AppTetherColor.components(for: tone, dark: true, increaseContrast: false)
        let light = AppTetherColor.components(for: tone, dark: false, increaseContrast: false)
        let darkIC = AppTetherColor.components(for: tone, dark: true, increaseContrast: true)

        // Same hue across appearances; only lightness/saturation move.
        #expect(abs(dark.hue - light.hue) <= 0.001)
        // Text on warm paper is darker than on the warm-dark canvas.
        #expect(light.brightness < dark.brightness)
        // Increase Contrast pushes the dark variant brighter and a touch more saturated.
        #expect(darkIC.brightness > dark.brightness)
        #expect(darkIC.saturation >= dark.saturation)
    }

    // MARK: Sanity — the four canonical brand apps land near the spec swatches

    @Test func canonicalApps_landInWarmNeighbourhoodsAndClearBands() {
        // (input brand hex, expected warm-adapted hue window)
        let cases: [(name: String, hex: UInt32, low: CGFloat, high: CGFloat)] = [
            ("Spotify", 0x1DB954, 128, 165),   // sage green   (~#6FA98C)
            ("YouTube", 0xFF0000, 325, 350),   // rose         (~#C56B72, off failure)
            ("Firefox", 0xFF7139, 12, 28),     // terracotta   (~#C08457, off gold)
            ("Safari",  0x1C9BF0, 185, 215),   // teal         (~#5E93A8)
        ]
        for c in cases {
            guard case .tinted(let tone) = AppTetherColor.deriveTone(from: solidIcon(c.hex)) else {
                Issue.record("\(c.name) should derive a tint")
                return
            }
            #expect(tone.hue >= c.low && tone.hue <= c.high, "\(c.name) hue \(tone.hue) outside [\(c.low),\(c.high)]")
            #expect(!(AppTetherColor.ReservedBand.failureRed.contains(tone.hue)), "\(c.name) landed in the failure band")
            #expect(!(AppTetherColor.ReservedBand.goldAmber.contains(tone.hue)), "\(c.name) landed in the gold band")

            // The warm-adapted output is CALMED (never full brand vividness)
            // but legibly bright AND legibly coloured on the dark canvas —
            // the 2026-07-22 contrast pass raised the ceiling from 0.55 to
            // 0.70 (`saturationCap`) specifically so this no longer reads as
            // a near-grey smudge; see `test_measuredContrast_clearsWCAGFloor`
            // for the actual WCAG numbers this range was picked against.
            let render = AppTetherColor.components(for: tone, dark: true, increaseContrast: false)
            #expect(render.saturation > 0.30 && render.saturation <= 0.70, "\(c.name) saturation \(render.saturation) outside the calmed-but-legible band")
            #expect(render.brightness >= 0.55 && render.brightness <= 0.85, "\(c.name) brightness \(render.brightness) off warm-dark range")
        }
    }

    // MARK: Measured WCAG contrast floor (2026-07-22 "still reads almost
    // black" pass) — the discipline `93a134b` set for the warm fader:
    // compute ACTUAL WCAG relative-luminance contrast ratios rather than
    // eyeballing a brightness number, and assert a real floor.

    /// WCAG 2.x relative luminance of an sRGB color.
    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let c = color.usingColorSpace(.sRGB)!
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    /// WCAG contrast ratio between two sRGB colors, `1...21`.
    private func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let l1 = relativeLuminance(a), l2 = relativeLuminance(b)
        let (hi, lo) = l1 > l2 ? (l1, l2) : (l2, l1)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// The genuine measured floor this pass targets: **>=3:1** against the
    /// chip's OWN-THEME canvas (WCAG 1.4.11 non-text/graphical-object
    /// contrast — this is a small coloured UI mark, not a body of text, so
    /// 3:1 rather than the 4.5:1 text floor is the correct criterion; the
    /// same criterion `93a134b` used for the fader thumb/rim). Checked against
    /// a representative sample of real brand hues spanning all three hue
    /// families (warm/mid/cool) — including a Firefox-purple-style cool hue,
    /// the family the earlier brightness-only floor was built to rescue —
    /// each rendered in ITS OWN theme against ITS OWN canvas token (a
    /// dark-theme chip is never actually drawn against the light canvas, so
    /// only same-theme pairings are asserted), with and without Increase
    /// Contrast.
    @Test func measuredContrast_clearsWCAGFloor() {
        let canvasDark = NSColor(srgbRed: 0x16 / 255.0, green: 0x13 / 255.0, blue: 0x0F / 255.0, alpha: 1)
        let canvasLight = NSColor(srgbRed: 0xFB / 255.0, green: 0xFB / 255.0, blue: 0xF9 / 255.0, alpha: 1)
        let floor: CGFloat = 3.0

        // (name, brand hex) — spans warm (Firefox/Instagram/Chrome), mid
        // (Spotify/Slack), and cool (Safari/Discord) families, plus a
        // synthetic cool-violet standing in for the real Firefox icon's
        // *actual* dominant hue (the globe, ~265°, per the earlier fix's own
        // comment) rather than the brand's marketing orange.
        let apps: [(name: String, hex: UInt32)] = [
            ("Spotify", 0x1DB954), ("YouTube", 0xFF0000), ("Firefox", 0xFF7139),
            ("Safari", 0x1C9BF0), ("Slack", 0x4A154B), ("Discord", 0x5865F2),
            ("Instagram", 0xE1306C), ("Chrome", 0xDB4437),
            ("Firefox-globe (cool violet)", 0x6A2FBF),
        ]

        var worstDark: (name: String, ratio: CGFloat) = ("", .infinity)
        var worstLight: (name: String, ratio: CGFloat) = ("", .infinity)

        for (name, hex) in apps {
            guard case .tinted(let tone) = AppTetherColor.deriveTone(from: solidIcon(hex)) else {
                continue   // a synthetic swatch landing on neutral carries no tint to measure
            }
            for ic in [false, true] {
                let dark = AppTetherColor.components(for: tone, dark: true, increaseContrast: ic)
                let darkColor = AppTetherColor.srgb(hue: dark.hue, saturation: dark.saturation, brightness: dark.brightness)
                let darkRatio = contrastRatio(darkColor, canvasDark)
                #expect(darkRatio >= floor, "\(name) dark ic=\(ic): \(darkRatio):1 vs canvas below the \(floor):1 floor")
                if darkRatio < worstDark.ratio { worstDark = (name, darkRatio) }

                let light = AppTetherColor.components(for: tone, dark: false, increaseContrast: ic)
                let lightColor = AppTetherColor.srgb(hue: light.hue, saturation: light.saturation, brightness: light.brightness)
                let lightRatio = contrastRatio(lightColor, canvasLight)
                #expect(lightRatio >= floor, "\(name) light ic=\(ic): \(lightRatio):1 vs canvas below the \(floor):1 floor")
                if lightRatio < worstLight.ratio { worstLight = (name, lightRatio) }
            }
        }

        // Genuine headroom, not a bare pass — the worst case in each theme
        // should clear the floor with real margin (measured 2026-07-22:
        // worst dark ~3.48:1, a cool-violet hue in the Firefox-globe family
        // the earlier brightness-only floor targeted; worst light ~4.0:1),
        // not sit at 3.0 exactly.
        #expect(worstDark.ratio > 3.4, "worst dark-theme case (\(worstDark.name)) has too little headroom above the floor")
        #expect(worstLight.ratio > 3.9, "worst light-theme case (\(worstLight.name)) has too little headroom above the floor")
    }
}
