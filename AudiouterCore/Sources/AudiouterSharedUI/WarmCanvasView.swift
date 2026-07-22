// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The **Warm Signal canvas** (spec `dev/notes/warm-signal-v3.md` §5.1): the
/// single continuous background a de-nested surface's sections sit directly
/// on. Introduced by warm-signal-v2 (the popover canvas + card de-nest) to
/// replace `PopoverPanelViewController`'s old `NSVisualEffectView`
/// (`.menu`, `.behindWindow`) background and `CardView`'s own per-card
/// material/shadow/rim.
///
/// A plain, layer-backed `NSView` with a custom `draw(_:)` — deliberately
/// NOT an `NSVisualEffectView` — so it is **always fully opaque**, in every
/// accessibility mode. That sidesteps the V2 §D accessibility requirement
/// ("under Reduce Transparency the canvas must render fully opaque") rather
/// than satisfying it conditionally: this view was never translucent to
/// begin with, so there's no vibrancy to defeat or fall back from.
///
/// Paints a vertical gradient — `canvasHi` (top) → `canvas` (bottom) — the
/// "gradient ladder" spec §1.1 describes for the dark palette, extended here
/// to light by the same construction since §1.2 doesn't re-state it (the
/// quietest reading of an otherwise-silent section — flagged in the V2
/// report). A faint, fully DETERMINISTIC grain texture (§1.1: "~5% white
/// alpha") glazes the gradient in dark mode only — see `WarmSignalGrain`'s
/// doc comment for the determinism contract this exists to satisfy (V2 §F:
/// snapshots must be byte-identical run-to-run) and the doc comment below
/// for why light mode omits it.
///
/// Both the gradient AND the grain are replaced by the FLAT `canvas` base
/// color (no texture) under Reduce Transparency OR Increase Contrast — V2
/// §D: "the canvas must render fully opaque with adequate contrast" and
/// "grain... must be omitted under Reduce Transparency/Increase Contrast."
public final class WarmCanvasView: NSView {

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var isFlipped: Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let flattenForAccessibility = reduceTransparency || increaseContrast

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if flattenForAccessibility {
            // Flat, fully opaque base color — no gradient, no grain: the
            // most legible, most deterministic surface (§D).
            Tokens.Color.canvas.setFill()
            bounds.fill()
            return
        }

        let top = Tokens.Color.canvasHi.cgColor
        let bottom = Tokens.Color.canvas.cgColor
        if let gradient = CGGradient(colorsSpace: nil, colors: [top, bottom] as CFArray,
                                     locations: [0, 1]) {
            ctx.saveGState()
            ctx.addRect(bounds)
            ctx.clip()
            // Non-flipped view: the visual top edge is maxY.
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: bounds.midX, y: bounds.maxY),
                                   end: CGPoint(x: bounds.midX, y: bounds.minY),
                                   options: [])
            ctx.restoreGState()
        } else {
            Tokens.Color.canvas.setFill()
            bounds.fill()
        }

        // Grain is spec'd (§1.1) only for the dark flagship palette; §1.2
        // (warm paper) doesn't restate it, and white noise over a near-white
        // paper surface reads as dirt/banding rather than texture — the
        // quietest reading of an otherwise-silent section (flagged in the
        // V2 report) is to omit it for light rather than invent a light-mode
        // grain formula the spec never gave.
        if isDark {
            WarmSignalGrain.draw(in: bounds, context: ctx)
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A fully deterministic (NOT random) faint white-noise grain texture (spec
/// §1.1: "~5% white alpha"). The tile is generated ONCE per process from a
/// pure integer hash of pixel coordinates — no `arc4random`,
/// `SystemRandomNumberGenerator`, `Date`, or object-address seeding anywhere
/// in this type — so the exact same pixels come out on every run, every
/// process, every machine. This is what keeps `popover-snapshot`'s PNGs
/// byte-identical across repeated runs (V2 §F hard gate: 3 runs, byte-for-
/// byte equal). A real RNG would reseed per process and break that gate.
enum WarmSignalGrain {
    /// Tile edge, in points. Small and cheap to pattern-fill across a
    /// popover-sized view.
    private static let tileSize = 48

    /// The generated tile. `static let` initializes exactly once per
    /// process (Swift lazy-static semantics), from the pure function below —
    /// deterministic, not merely "usually the same".
    private static let tile: NSImage = makeTile()

    private static func makeTile() -> NSImage {
        let size = tileSize
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                // Pure hash of (x, y) — see the type doc comment. `% 13`
                // spans roughly 0–5% alpha, averaging ~2.5%. The spec's "~5%"
                // ceiling read as coarse carpet at real row density (first
                // V2 eyeball, 2026-07-22); halved so the texture registers as
                // faint tooth, not pattern. Tune live if it disappears on
                // low-DPI panels.
                var h = UInt32(bitPattern: Int32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263))
                h ^= h >> 13
                h = h &* 1_274_126_177
                h ^= h >> 16
                let alpha = UInt8(h % 13)
                let idx = (y * size + x) * 4
                // Premultiplied white: for a pure-white pixel at alpha `a`,
                // premultiplied R == G == B == A == a.
                pixels[idx + 0] = alpha
                pixels[idx + 1] = alpha
                pixels[idx + 2] = alpha
                pixels[idx + 3] = alpha
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: size, height: size,
                                    bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: size * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent)
        else {
            return NSImage(size: NSSize(width: size, height: size))
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    /// Tile-fill `rect`, clipped to it, with the deterministic grain.
    static func draw(in rect: NSRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.clip(to: rect)
        NSColor(patternImage: tile).setFill()
        // Anchor the pattern phase at a fixed point so tiling never depends
        // on the current graphics-context transform — deterministic phase,
        // not "whatever the view's current frame origin happens to be".
        NSGraphicsContext.current?.patternPhase = NSPoint(x: 0, y: 0)
        rect.fill()
        ctx.restoreGState()
    }
}
