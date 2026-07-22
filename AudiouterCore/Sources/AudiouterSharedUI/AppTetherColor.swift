// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// **Derived app→device "tether colour"** (Warm Signal v4 §Call 2, the
/// `dev/notes/warm-signal-v4-rail-and-tether.md` "Derived-colour name tether").
///
/// A redirect (an app routed to a device) is shown by TINTING the app's NAME —
/// the same warm tint on both endpoints (App Exceptions row + the target
/// device's sublabel) is the tether; no line crosses the panel. This utility
/// is the single, standalone, deterministic source of that tint. It does NOT
/// draw anything and is not yet wired into any row — a later agent consumes the
/// API below to tint names.
///
/// ## What it does
/// 1. **Dominant-hue extraction** — downscale the app icon to a small bitmap,
///    sample every pixel, ignore near-transparent and near-greyscale pixels,
///    and find the dominant *saturated* hue (a hue histogram weighted by
///    `saturation × coverage`, refined by a circular mean around the winning
///    bin). Fully deterministic: fixed raster size, fixed sample order, no RNG,
///    no clock — the same icon always yields the same hue, so snapshot/unit
///    tests stay byte-stable.
/// 2. **Warm-adapt + steer off the reserved bands** — the raw brand hue is
///    desaturated into the warm range, its lightness nudged for legibility on
///    BOTH the warm-dark canvas and the warm-paper light surface, and its hue
///    steered out of the three reserved state bands so a tether can never be
///    read as a state colour (see ``ReservedBand`` below).
/// 3. **Fallback** — an icon with no saturated dominant hue (greyscale marks, or
///    colour-balanced multi-hue marks with no saturated region) returns the
///    neutral link tone ``neutralFallback``.
///
/// ## Governance (root `AGENTS.md` house rule 2 — "all custom colour lives in
/// `Tokens`")
/// This type introduces **no static custom palette value.** Every tinted output
/// is *derived at runtime from the input icon's own pixels* — a computed
/// function, not an authored hex, so it categorically cannot live in `Tokens`.
/// The only fixed anchors it holds are (a) hue-*angle* avoidance windows
/// (``ReservedBand`` — regions of hue space to steer away from, not colours) and
/// (b) saturation/lightness *transform* constants — neither is an `NSColor`
/// literal. The one concrete colour it emits without deriving — the neutral
/// fallback — is delegated to an existing sanctioned `Tokens` token
/// (``neutralFallback``), so no raw hex is minted here. When a dedicated
/// `Tokens.Color.link` token is eventually authored (the reserved-but-unadded
/// `link` case noted in `Tokens.swift`), ``neutralFallback`` should repoint to
/// it.
///
/// ## Appearance adaptivity
/// Each tinted result is an appearance-resolving `NSColor(name:dynamicProvider:)`
/// — the warm-dark / warm-paper / Increase-Contrast lightness+saturation is
/// picked at draw time, exactly the `warmDynamic` precedent in `Tokens.swift`.
/// The *hue* is fixed by the icon (appearance-independent); only its lightness
/// and saturation shift per appearance.
public enum AppTetherColor {

    // MARK: - Public API

    /// The derived tether tint for one app, **cached by `bundleID`**.
    ///
    /// Deterministic per bundle id (a bundle's icon is stable), so the first
    /// call computes and memoises; later calls reuse the result and ignore
    /// `icon`. Pass the app icon (`NSWorkspace`/`NSRunningApplication.icon`); a
    /// `nil` icon yields ``neutralFallback``.
    public static func color(forBundleID bundleID: String, icon: NSImage?) -> NSColor {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[bundleID] { return cached }
        let color = makeColor(deriveTone(from: icon))
        cache[bundleID] = color
        return color
    }

    /// The neutral link tone used when an icon has no saturated dominant hue
    /// (greyscale or colour-balanced marks). Reuses the existing warm-neutral
    /// `Tokens.Color.ringConnected` instrument (a hue-neutral warm-grey that is
    /// already appearance- and Increase-Contrast-adaptive with a documented
    /// contrast rationale) rather than minting a new palette value here — see
    /// the type's Governance note. Repoint to `Tokens.Color.link` once that
    /// token exists.
    public static var neutralFallback: NSColor { Tokens.Color.ringConnected }

    /// Derive tether tints for a set of apps at once, **nudging near-duplicate
    /// hues apart** so two simultaneously-active redirects that share a brand
    /// hue (YouTube/Apple Music both rose, Safari/Chrome both blue) don't read
    /// as the same tether. Processing order is deterministic (sorted by `key`):
    /// the first key at a given hue keeps it, later keys rotate away by at least
    /// `minimumHueSeparation` degrees (re-steered so a nudge never lands back on
    /// a reserved band). Neutral-fallback entries are left as-is (they carry no
    /// brand hue; the name disambiguates them). Does not touch the per-app cache.
    public static func colors(forKeyedIcons keyed: [(key: String, icon: NSImage?)],
                              minimumHueSeparation: CGFloat = defaultMinimumHueSeparation) -> [String: NSColor] {
        var taken: [CGFloat] = []
        var result: [String: NSColor] = [:]
        for entry in keyed.sorted(by: { $0.key < $1.key }) {
            switch deriveTone(from: entry.icon) {
            case .neutral:
                result[entry.key] = neutralFallback
            case .tinted(let tone):
                let nudged = nudgedHue(tone.hue, awayFrom: taken,
                                       minimumSeparation: minimumHueSeparation)
                taken.append(nudged)
                let steered = steer(nudged)
                result[entry.key] = makeColor(.tinted(HueTone(hue: steered.hue,
                                                              sourceSaturation: tone.sourceSaturation,
                                                              goldSteered: steered.goldSteered)))
            }
        }
        return result
    }

    /// Default minimum hue separation (degrees) between two nudged-apart tethers.
    public static let defaultMinimumHueSeparation: CGFloat = 20

    /// Drop the memoised per-bundle results (test isolation / an icon-set
    /// refresh). Derivation is pure, so this only discards a cache.
    public static func clearCache() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache.removeAll()
    }

    // MARK: - Reserved bands (hue-angle avoidance windows, NOT palette colours)

    /// The three regions of hue space a tether is steered out of so it can never
    /// impersonate a Warm Signal state colour. Each band is expressed in hue
    /// *degrees* and anchored to the flagship instrument hues it must avoid; the
    /// window boundaries are fixed constants (determinism requires them to be
    /// independent of the live accent dial, which would otherwise move `gold`).
    public enum ReservedBand {
        /// **Failure-red** (`Tokens.Color.failure` ≈ 5°, brand pure-red 0°): the
        /// window straddling 0° — `[0°,12°) ∪ [350°,360°)`. Pure reds are steered
        /// to the **rose/pink** side (magenta), landing in `[335°,349°]` — always
        /// strictly below 350° so the result provably clears this band.
        case failureRed
        /// **Gold / amber** (`Tokens.Color.gold` ≈ 44°, `Tokens.Color.caution`
        /// ≈ 36° — the signal accent and the meter ceiling): `[28°,68°)`. Oranges
        /// and yellows are steered DOWN into the **terracotta** corridor
        /// `[14°,27°]` and darkened (browner) so they read as earth, not signal.
        case goldAmber

        /// `true` iff `hueDegrees` (any real angle) falls inside this band.
        public func contains(_ hueDegrees: CGFloat) -> Bool {
            let h = AppTetherColor.normalize(hueDegrees)
            switch self {
            case .failureRed: return (h >= 0 && h < failureRedUpper) || (h >= failureRedLower && h < 360)
            case .goldAmber:  return h >= goldLower && h < goldUpper
            }
        }
    }

    // Band boundaries (degrees).
    static let failureRedUpper: CGFloat = 12    // [0, 12)
    static let failureRedLower: CGFloat = 350   // [350, 360)
    static let goldLower: CGFloat = 28          // [28, 68)
    static let goldUpper: CGFloat = 68

    // MARK: - Internal model

    /// A resolved brand hue plus the two facts the warm-adapt needs beyond the
    /// hue itself: the icon's original saturation (vivid marks calm down more
    /// than already-muted ones) and whether the hue had to be steered off the
    /// gold band (steered-off-gold tones are darkened toward brown).
    struct HueTone: Equatable {
        var hue: CGFloat
        var sourceSaturation: CGFloat
        var goldSteered: Bool
    }

    /// The derivation outcome: a brand-derived tint, or the neutral fallback.
    enum TetherTone: Equatable {
        case tinted(HueTone)
        case neutral
    }

    // MARK: - Derivation pipeline

    /// Extract the dominant saturated hue from `icon` and warm-adapt/steer it,
    /// or return `.neutral` when the icon carries no saturated dominant hue.
    static func deriveTone(from icon: NSImage?) -> TetherTone {
        guard let icon, let dominant = dominantHue(of: icon) else { return .neutral }
        let steered = steer(dominant.hue)
        return .tinted(HueTone(hue: steered.hue,
                               sourceSaturation: dominant.saturation,
                               goldSteered: steered.goldSteered))
    }

    /// The dominant saturated hue of an icon, or `nil` if none stands out.
    /// Returns the (circular-mean-refined) hue in degrees plus the mean source
    /// saturation of the winning cluster. Pure/deterministic given the bitmap.
    static func dominantHue(of icon: NSImage) -> (hue: CGFloat, saturation: CGFloat)? {
        guard let samples = sampledPixels(of: icon) else { return nil }

        var binWeight = [CGFloat](repeating: 0, count: hueBinCount)
        var binSin = [CGFloat](repeating: 0, count: hueBinCount)
        var binCos = [CGFloat](repeating: 0, count: hueBinCount)
        var binSat = [CGFloat](repeating: 0, count: hueBinCount)
        var coveredCount: CGFloat = 0
        var saturatedWeight: CGFloat = 0

        for px in samples {
            guard px.alpha >= alphaFloor else { continue }   // near-transparent → ignore
            coveredCount += 1
            guard px.saturation >= saturationFloor,          // near-greyscale → ignore
                  px.brightness >= brightnessFloor           // near-black → hue is noise
            else { continue }
            let weight = px.alpha * px.saturation             // coverage × vividness
            let bin = min(hueBinCount - 1, Int(px.hue / 360 * CGFloat(hueBinCount)))
            let radians = px.hue * .pi / 180
            binWeight[bin] += weight
            binSin[bin] += weight * sin(radians)
            binCos[bin] += weight * cos(radians)
            binSat[bin] += weight * px.saturation
            saturatedWeight += weight
        }

        guard coveredCount > 0, saturatedWeight > 0,
              saturatedWeight / coveredCount >= fallbackCoverageRatio
        else { return nil }   // greyscale / no saturated region → fallback

        // Winning bin, then refine with a circular mean over it and its two
        // neighbours (so a hue near a bin edge isn't quantised to the edge).
        let winner = (0..<hueBinCount).max(by: { binWeight[$0] < binWeight[$1] }) ?? 0
        var sumSin: CGFloat = 0, sumCos: CGFloat = 0, sumWeight: CGFloat = 0, sumSat: CGFloat = 0
        for offset in -1...1 {
            let bin = (winner + offset + hueBinCount) % hueBinCount
            sumSin += binSin[bin]; sumCos += binCos[bin]
            sumWeight += binWeight[bin]; sumSat += binSat[bin]
        }
        guard sumWeight > 0 else { return nil }
        let hue = normalize(atan2(sumSin, sumCos) * 180 / .pi)
        return (hue, sumSat / sumWeight)
    }

    /// Steer a raw hue out of the reserved bands. Returns the safe hue and
    /// whether it was pushed off the gold band (which the brightness map darkens
    /// toward brown). Pure — the deterministic heart of the reserved-band logic.
    static func steer(_ rawHue: CGFloat) -> (hue: CGFloat, goldSteered: Bool) {
        let h = normalize(rawHue)
        if ReservedBand.goldAmber.contains(h) {
            // Map [28,68) → terracotta corridor [27..14] (below the band).
            let f = (h - goldLower) / (goldUpper - goldLower)
            return (terracottaHigh - f * (terracottaHigh - terracottaLow), true)
        }
        if ReservedBand.failureRed.contains(h) {
            // Represent the ±window as an offset from red (0°) in [-10, 12), then
            // map to the rose/pink side [349..335] — always below 350°.
            let off = h >= 180 ? h - 360 : h
            let f = (off + (360 - failureRedLower)) / (failureRedUpper + (360 - failureRedLower))
            return (normalize(roseHigh - f * (roseHigh - roseLow)), false)
        }
        return (h, false)   // blue/green/etc. — foreign to the palette, safe
    }

    /// Rotate `hue` forward until it clears every already-taken hue by at least
    /// `minimumSeparation` (circular), re-steering each candidate so a nudge
    /// never parks on a reserved band. Deterministic; bounded iteration.
    static func nudgedHue(_ hue: CGFloat, awayFrom taken: [CGFloat],
                          minimumSeparation: CGFloat) -> CGFloat {
        func collides(_ candidate: CGFloat) -> Bool {
            taken.contains { circularDistance($0, candidate) < minimumSeparation }
        }
        var candidate = normalize(hue)
        var step = 0
        while collides(candidate) && step < nudgeMaxSteps {
            step += 1
            candidate = steer(normalize(hue) + CGFloat(step) * minimumSeparation).hue
        }
        return candidate
    }

    // MARK: - Warm-adapt (saturation + lightness per appearance)

    /// The (hue, saturation, brightness) a tinted tone resolves to for a given
    /// surface. Pure and global-free (takes explicit `dark`/`increaseContrast`)
    /// so it is directly unit-testable; the live `NSColor` provider calls it
    /// with the resolved appearance flags.
    static func components(for tone: HueTone, dark: Bool, increaseContrast: Bool)
        -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        let fam = family(of: tone.hue)

        // Saturation: calm vivid marks toward the warm range, floor so a muted
        // mark still reads as a tint, extra restraint on the (vivid-reading)
        // cool family, a touch more punch on paper.
        var sat = min(tone.sourceSaturation * saturationScale, saturationCap)
        sat = max(sat, saturationFloorOut)
        sat *= fam.saturationTrim
        if !dark { sat = min(sat + lightSaturationBoost, lightSaturationCap) }

        // Brightness: legible on the warm-dark canvas; darker on warm paper so
        // tinted text carries on a light surface; browner when steered off gold.
        var bright = dark ? fam.darkBrightness : fam.darkBrightness - lightBrightnessDrop
        if tone.goldSteered { bright *= goldSteeredBrightnessScale }

        if increaseContrast {
            if dark { bright += icBrightnessStep; sat += icSaturationStep }
            else { bright -= icBrightnessStep; sat += icSaturationStep }
        }

        // Legibility floor: after every darkening step (warm-paper drop,
        // gold-steer, Increase-Contrast) a tint must still read as a coloured
        // dot, never as black. The darkest stack-ups — a cool-family hue on
        // warm paper (0.66 − 0.28 = 0.38), or a gold-steered warm tone likewise
        // dropped and IC-darkened (~0.33) — would otherwise fall dark enough to
        // vanish into the near-black canvas at the 5pt chip size (see
        // ``minimumLegibleBrightness``). Applied last so it caps the whole chain.
        bright = max(bright, minimumLegibleBrightness)

        // The brightness floor above binds LUMINANCE, but a WCAG luminance
        // ratio is colour-blind by design: a chip can clear it while still
        // reading as a grey/near-black smudge if its CHROMA is low (2026-07-22
        // "still reads almost black" pass — the earlier floor targeted the
        // single darkest hue/appearance combination, not the general muted
        // register every family's `saturationTrim` × `saturationCap` produces).
        // Re-floor saturation here, LAST, same discipline as the brightness
        // floor: see ``minimumChipSaturation``.
        sat = max(sat, minimumChipSaturation)

        return (tone.hue, clamp01(sat), clamp01(bright))
    }

    /// Hue families with their warm-adapt brightness + saturation trim. Warm
    /// hues sit brighter on the dark canvas; cool hues (which read more vivid)
    /// are dimmed and desaturated harder; the yellow-green / purple middle sits
    /// between.
    private enum HueFamily {
        case warm, cool, mid
        var darkBrightness: CGFloat {
            switch self { case .warm: return 0.75; case .cool: return 0.66; case .mid: return 0.70 }
        }
        /// Restraint on the cool/mid families (`mid` nudged 0.90 → 0.88,
        /// 2026-07-22 contrast pass — see the "Warm-adapt shape" tuning
        /// constants below for the bulk of that pass, which raises
        /// `saturationScale`/`saturationCap`/`saturationFloorOut` instead:
        /// this per-family trim was ALREADY the more conservative of the two
        /// levers, so it moves only slightly while the shared scale/cap/floor
        /// do the real work). Warm stays at full punch (it was never the
        /// complaint — see the measured-contrast table in
        /// `AppTetherColorTests.test_measuredContrast_clearsWCAGFloor`).
        var saturationTrim: CGFloat {
            switch self { case .warm: return 1.0; case .cool: return 0.80; case .mid: return 0.88 }
        }
    }

    private static func family(of hue: CGFloat) -> HueFamily {
        let h = normalize(hue)
        if h < 70 || h >= 300 { return .warm }
        if h >= 120 && h < 270 { return .cool }
        return .mid
    }

    // MARK: - NSColor assembly

    static func makeColor(_ tone: TetherTone) -> NSColor {
        switch tone {
        case .neutral:
            return neutralFallback
        case .tinted(let hueTone):
            // Name keyed by the settled tone so equal tones dedupe in AppKit and
            // resolve identically; the provider re-picks lightness/saturation per
            // appearance (warmDynamic precedent), the hue stays fixed.
            let name = NSColor.Name(String(format: "WarmSignal.tether.%.1f.%.2f.%d",
                                           hueTone.hue, hueTone.sourceSaturation,
                                           hueTone.goldSteered ? 1 : 0))
            return NSColor(name: name) { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let ic = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                let c = components(for: hueTone, dark: dark, increaseContrast: ic)
                return srgb(hue: c.hue, saturation: c.saturation, brightness: c.brightness)
            }
        }
    }

    // MARK: - Bitmap sampling

    struct Pixel { let hue: CGFloat; let saturation: CGFloat; let brightness: CGFloat; let alpha: CGFloat }

    /// Downscale `icon` to a fixed sRGB raster and return every pixel as HSBA.
    /// `nil` only if the icon can't be rasterised at all. Deterministic: fixed
    /// size, fixed row-major order.
    static func sampledPixels(of icon: NSImage) -> [Pixel]? {
        let side = rasterSide
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                  from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        var pixels: [Pixel] = []
        pixels.reserveCapacity(side * side)
        for y in 0..<side {
            for x in 0..<side {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                pixels.append(Pixel(hue: color.hueComponent * 360,
                                    saturation: color.saturationComponent,
                                    brightness: color.brightnessComponent,
                                    alpha: color.alphaComponent))
            }
        }
        return pixels
    }

    // MARK: - Small math helpers

    /// Wrap any real angle into `[0, 360)`.
    static func normalize(_ degrees: CGFloat) -> CGFloat {
        let m = degrees.truncatingRemainder(dividingBy: 360)
        return m < 0 ? m + 360 : m
    }

    /// Shortest angular distance between two hues, `0...180`.
    static func circularDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs(normalize(a) - normalize(b))
        return min(d, 360 - d)
    }

    private static func clamp01(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }

    /// HSB → opaque sRGB `NSColor` (input and read-back share the sRGB space, so
    /// a resolved colour's hue round-trips to what was asked for).
    static func srgb(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> NSColor {
        let h = normalize(hue) / 60
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch Int(h) % 6 {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return NSColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: 1)
    }

    // MARK: - Tuning constants (transforms + thresholds — NOT palette colours)

    private static let rasterSide = 24            // downscale target (24×24 = 576 samples)
    private static let hueBinCount = 36           // 10°-wide histogram bins
    static let alphaFloor: CGFloat = 0.25         // below → near-transparent, ignored
    static let saturationFloor: CGFloat = 0.18    // below → near-greyscale, ignored
    private static let brightnessFloor: CGFloat = 0.12  // below → near-black, hue is noise
    static let fallbackCoverageRatio: CGFloat = 0.05    // saturatedWeight/covered below → fallback

    // Steer escape anchors (degrees).
    static let terracottaHigh: CGFloat = 27       // gold-band escape corridor upper
    static let terracottaLow: CGFloat = 14        // …lower
    static let roseHigh: CGFloat = 349            // failure-band escape upper (just below 350)
    static let roseLow: CGFloat = 335             // …lower

    // Warm-adapt shape. RAISED 2026-07-22 ("still reads almost black" pass —
    // the owner's live-build follow-up to the brightness-floor fix above):
    // measuring the OLD constants' output against `Tokens.Color.canvas` in
    // both themes (see `AppTetherColorTests.test_measuredContrast_*`) showed
    // the WCAG *luminance* floor was already clearing 3:1 almost everywhere —
    // the actual complaint is CHROMA, not luminance: `saturationScale`/
    // `saturationCap`/`saturationFloorOut` calmed vivid brand hues into a
    // register desaturated enough to read as a grey/near-black smudge at the
    // chip's tiny size even where the luminance ratio was technically fine.
    // Each constant below is raised so more of the icon's own vividness comes
    // through; `saturationFloorOut` in particular is raised so a
    // LOW-saturation source icon (common: white halos/gradients/highlights
    // pull a real icon's *measured* dominant saturation well below a
    // solid-brand swatch's) still resolves to a genuine colour, not a beige.
    private static let saturationScale: CGFloat = 0.75
    private static let saturationCap: CGFloat = 0.62
    private static let saturationFloorOut: CGFloat = 0.38
    private static let lightSaturationBoost: CGFloat = 0.07
    private static let lightSaturationCap: CGFloat = 0.70
    private static let lightBrightnessDrop: CGFloat = 0.28
    private static let goldSteeredBrightnessScale: CGFloat = 0.88

    /// Floor on the emitted brightness so no derived tint can render dark enough
    /// to merge into the near-black warm-dark canvas (`Tokens.Color.canvas`
    /// ≈ `#16130F`, brightness ≈ 0.09) at the 5pt FEED chip size — the "solid
    /// black chip" a real multi-hue icon can otherwise produce (e.g. a cool
    /// purple/green icon resolved onto warm paper, or a gold-steered orange
    /// dropped + Increase-Contrast-darkened, both bottoming out near 0.30–0.38).
    /// Binds only on those darkest stack-ups; on the dark canvas the family
    /// base brightnesses (0.66–0.75) already sit well above it. Kept strictly
    /// below the lowest DARK-canvas brightness (cool / gold-steered = 0.66) so
    /// the "warm-paper text is darker than dark-canvas text" ordering the
    /// appearance variants rely on still holds, yet high enough that the dimmest
    /// tint is a distinguishable coloured dot rather than a black one. Raised
    /// slightly (0.45 → 0.50, 2026-07-22) alongside the saturation raise above
    /// for a touch more headroom against the measured WCAG floor.
    static let minimumLegibleBrightness: CGFloat = 0.50
    /// Saturation counterpart to `minimumLegibleBrightness` (2026-07-22): a
    /// tint can clear the brightness floor and still look colourless if its
    /// saturation bottoms out low. Applied LAST in `components(for:dark:increaseContrast:)`,
    /// after every desaturating step, so nothing downstream of it can undo it.
    /// Kept below `saturationFloorOut` so it never overrides the ordinary
    /// warm-adapt shape — it only binds on inputs that would otherwise slip
    /// under it (a near-greyscale source hue that still cleared
    /// `AppTetherColor.saturationFloor` to count as "tinted" at all).
    static let minimumChipSaturation: CGFloat = 0.32
    private static let icBrightnessStep: CGFloat = 0.08
    private static let icSaturationStep: CGFloat = 0.05

    private static let nudgeMaxSteps = 24

    // MARK: - Cache

    private static var cache: [String: NSColor] = [:]
    private static let cacheLock = NSLock()
}
