// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

private extension UIColor {
    /// 0xRRGGBB → UIColor. The design's palettes are written as hex (doc:1686-1699).
    convenience init(rgb: UInt32, alpha: CGFloat) {
        self.init(red:   CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >>  8) & 0xFF) / 255,
                  blue:  CGFloat( rgb        & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// One token as a light/dark pair, resolved by the trait collection, so the
/// app follows the system appearance with nothing stored anywhere.
private func warm(light: UInt32,
                  dark: UInt32,
                  lightAlpha: CGFloat = 1,
                  darkAlpha: CGFloat = 1) -> Color {
    Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(rgb: dark, alpha: darkAlpha)
        : UIColor(rgb: light, alpha: lightAlpha) })
}

/// The "Warm Signal" palette and primitives from the iOS design document
/// (`dev/notes/ios-design-system-2a.dc.html`): a warm near-black ground with a
/// gold signal accent in dark, a paper ground with a darker gold in light.
/// Both grounds ship; the appearance follows the system.
///
// razor: appearance follows the system. The design's accent dial and Dark/Light/Auto control (doc:644-671) are deferred — add a preference plus an environment override here when they land.
enum WarmSignal {

    // MARK: Grounds

    /// Four grounds and a well, and in BOTH appearances they are four different
    /// values. The document gives light one paper colour for all of them
    /// (`#FBFBF9` at doc:1693-1699), which leaves the light build with no
    /// elevation at all: a speaker's halo, a panel and the screen behind them
    /// are the same pixel, so instruments float on nothing while dark mode
    /// reads as built.
    ///
    /// The fix is the one paper actually uses, and the one iOS uses for grouped
    /// tables: move the GROUND down rather than pushing surfaces up, so a
    /// raised thing can be paper-white and still lift. The steps are small on
    /// purpose — 1.12:1 from canvas to raised, about what `systemGroupedBackground`
    /// gives a white cell. Elevation you can see is not elevation you notice.
    static let canvas   = warm(light: 0xF4F2EA, dark: 0x16130F)
    static let canvasHi = warm(light: 0xF7F5EF, dark: 0x1B1712)
    static let panel    = warm(light: 0xFCFBF7, dark: 0x1D1915)
    static let raised   = warm(light: 0xFFFFFF, dark: 0x241F1A)
    static let well     = warm(light: 0xEDEAE0, dark: 0x100D0A)
    static let hairline = warm(light: 0xE7E6DF, dark: 0x3A332B)

    // MARK: Ink

    static let label  = warm(light: 0x1E1C1C, dark: 0xFFFFFF, darkAlpha: 0.92)
    static let label2 = warm(light: 0x706464, dark: 0xFFFFFF, darkAlpha: 0.55)

    /// The design's third ink (doc:16) is 28% white on the dark ground, which
    /// measures 1.93:1 — unreadable, and it carries the `IDLE` sub-labels and
    /// both empty-state placeholders. Lifted to the 4.5:1 floor in both grounds
    /// (`#5F5A54` on paper → 6.59:1). The dark alpha was 0.45 (4.47:1 on
    /// `panel` — 0.03 under floor); nudged to 0.47 → 4.76:1 on `panel`.
    /// Deliberately off-spec: the document set a value, not a contrast target.
    static let label3 = warm(light: 0x5F5A54, dark: 0xFFFFFF, darkAlpha: 0.47)

    // MARK: Signal

    static let gold    = warm(light: 0xA97F1E, dark: 0xE8B84B)

    /// Light-mode `gold` measures 3.04–3.53:1 against every surface it sits
    /// on as text (canvas 3.26:1, well 3.04:1, deckFill 3.38:1, panel
    /// 3.53:1) — all fail the 4.5:1 text floor, even though the same hex
    /// clears 3:1 everywhere as a graphic (fader fill, wash, dots), so only
    /// text uses need to move. `#866210` clears 4.5:1 against all four
    /// (well is the tightest: 4.64:1; canvas 4.97:1, deckFill 5.15:1, panel
    /// 5.38:1) while staying in the same hue family. Dark is untouched —
    /// dark `gold` already clears 7.4–10.5:1 everywhere. Use this instead of
    /// `gold` for any text, at or below 16 pt, that must read as gold.
    static let goldText = warm(light: 0x866210, dark: 0xE8B84B)
    static let ember   = warm(light: 0xC2A05A, dark: 0x8A6A2F)
    static let glow    = warm(light: 0xE8B84B, dark: 0xFFD97A)
    static let ring    = warm(light: 0xA08C66, dark: 0x8D7D5E)
    static let fail    = warm(light: 0xBB3A2F, dark: 0xD9564A)
    static let caution = warm(light: 0xB3701C, dark: 0xE29A3D)

    // MARK: Instruments

    /// The fader cap takes ``raised`` and is defined by its rim and its
    /// silhouette. The document draws it as a brass gradient (doc:138,
    /// doc:366), which puts two muted tans against each other: 1.07:1 against
    /// the fill in light, 1.49:1 in dark, where a control needs 3:1.
    static let rim = warm(light: 0x8A7A62, dark: 0x8D7D5E)
    static let meter    = warm(light: 0xCBBEA1, dark: 0x4E463A)
    static let pill     = warm(light: 0xD0CDC3, dark: 0x38322B)
    static let socket   = warm(light: 0xE0D8C6, dark: 0x34302A)

    // MARK: Glass

    /// What the drawer puts between itself and the list it covers. The same
    /// near-black in both appearances on purpose: a scrim is an absence of
    /// light, and the paper ground needs it more than the dark one does.
    static let scrim = Color(UIColor(rgb: 0x080604, alpha: 0.5))

    static let glass     = warm(light: 0xFAF7EE, dark: 0x342D25, lightAlpha: 0.66, darkAlpha: 0.52)
    static let glassEdge = warm(light: 0x1E1C1C, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.11)
    static let glassHi   = warm(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.80, darkAlpha: 0.10)

    // MARK: Metrics

    /// Three corner radii, and nothing between them: small controls, list rows,
    /// floating panels. The screen had eight before, which is what a set of
    /// individually-plausible guesses looks like once they're counted.
    enum Radius {
        static let control: CGFloat = 10
        static let row: CGFloat     = 16
        static let panel: CGFloat   = 26
    }

    /// The 44 pt floor every tappable control is given, however small it draws.
    static let hitTarget: CGFloat = 44

    // MARK: Elevation

    /// One shadow in the whole screen, and it belongs to the Main Out deck,
    /// because that is the only thing genuinely floating over moving content.
    /// Everything else separates with a hairline. A drawn edge is cheaper than
    /// a shadow and does not smear across a paper ground.
    ///
    /// Lighter in light: 0.4 black at 17 pt over `#FBFBF9` reads as a grey
    /// smudge rather than as height.
    static func deckShadow(_ scheme: ColorScheme) -> (color: Color, radius: CGFloat, y: CGFloat) {
        scheme == .dark
            ? (.black.opacity(0.28), 24, -6)
            : (.black.opacity(0.08), 18, -4)
    }

    // MARK: Composites

    /// The screen's ground (doc:52).
    static let canvasGradient = LinearGradient(
        stops: [
            .init(color: canvasHi, location: 0),
            .init(color: canvas,   location: 0.44),
            .init(color: canvas,   location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// The Main Out deck's own warm ground (doc:122 dark, doc:350 light) —
    /// deliberately warmer than ``glass``, never a neutral grey.
    static let deckFill = warm(light: 0xFAF7EE, dark: 0x54483A, lightAlpha: 0.78, darkAlpha: 0.48)

    /// The design's row/deck drag maths (doc:1742, doc:1775): the value captured
    /// at gesture start, plus the fraction of the track the finger has crossed.
    static func faderValue(start: Int, translationWidth: CGFloat, trackWidth: CGFloat) -> Int {
        guard trackWidth > 0 else { return start }
        return min(100, max(0, Int((Double(start) + (translationWidth / trackWidth) * 100).rounded())))
    }

    /// The rail a fader is currently pinned against, or `nil`. All three faders
    /// clamp through ``faderValue(start:translationWidth:trackWidth:)``, so
    /// past either end the value simply stops moving and the finger gets no
    /// answer at all — this is what the boundary tick is triggered off.
    ///
    /// It is a `nil`-able identity rather than a `Bool` so that
    /// `.sensoryFeedback(trigger:)` sees a change on every ARRIVAL at a rail
    /// (nil → 0, nil → 100) and none while sitting on one. Off a rail there is
    /// nothing to feel, which is also why nothing fires for the middle of a
    /// drag: the tick marks the end of the travel, not the travel.
    static func faderRail(_ value: Int, dragging: Bool) -> Int? {
        guard dragging, value == 0 || value == 100 else { return nil }
        return value
    }
}

// MARK: - Type primitives

/// The design's micro-label voice (doc:36): monospaced, uppercase, tracked out.
/// 11 pt is the HIG floor for any text, and also the default size here — the
/// design's own values (doc:57, doc:72-73, doc:124, doc:126, doc:195, doc:197)
/// run 9–9.5 pt, all under that floor, so no call site should pass anything
/// smaller than the default.
///
/// Scales with `@ScaledMetric`, not `.custom("", size:relativeTo:)`: an empty
/// font name has no documented meaning, and nothing verifies it carries
/// weight or the monospaced trait through Dynamic Type scaling. A plain
/// `@ScaledMetric` point size composed with an explicit
/// `.system(size:weight:design:)` guarantees both.
struct MicroLabel: ViewModifier {
    @ScaledMetric private var scaledSize: CGFloat
    private let baseSize: CGFloat

    init(size: CGFloat) {
        self.baseSize = size
        self._scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .caption2)
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: scaledSize, weight: .bold, design: .monospaced))
            // Tracking stays keyed to the base size, not the scaled one: it's
            // a fixed proportion of the label's design size, not something
            // that should itself expand further as the label already grows.
            .tracking(baseSize * 0.09)
            .textCase(.uppercase)
    }
}

/// A numeric readout: monospaced, tight, so the digits don't shuffle as the
/// value changes under a finger. See ``MicroLabel`` for why this scales via
/// `@ScaledMetric` rather than the old empty-name `.custom(...)` hack.
struct Readout: ViewModifier {
    @ScaledMetric private var scaledSize: CGFloat

    init(size: CGFloat) {
        self._scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: scaledSize, weight: .bold, design: .monospaced))
            .tracking(-0.4)
            .monospacedDigit()
    }
}

/// The design's frosted surfaces: a blurred backdrop with a warm translucent
/// tint over it and a hairline edge. The document's 26 px `backdrop-filter`
/// blur is delivered by `.ultraThinMaterial` — there is no blur token.
struct GlassPanel: ViewModifier {
    let cornerRadius: CGFloat
    let fill: Color

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                shape
                    .fill(fill)
                    .background(.ultraThinMaterial, in: shape)
            }
            .overlay {
                shape.strokeBorder(WarmSignal.glassEdge, lineWidth: 0.5)
            }
    }
}

extension View {
    /// Expands the tap area to the 44 pt floor without moving anything: pad
    /// out, claim the padded rect, pad back in. A `minWidth`/`minHeight` frame
    /// would reach the same floor but push its container out with it — a 28 pt
    /// mute button would take its drawer row from 48 pt to 64.
    ///
    /// `drawn` is the size the control actually paints, so the padding can be
    /// exactly what the floor needs and no more.
    func hittable(drawn: CGFloat) -> some View {
        let pad = max(0, (WarmSignal.hitTarget - drawn) / 2)
        return padding(pad)
            .contentShape(Rectangle())
            .padding(-pad)
    }

    func microLabel(_ size: CGFloat = 11) -> some View { modifier(MicroLabel(size: size)) }

    func readout(_ size: CGFloat) -> some View { modifier(Readout(size: size)) }

    func glassPanel(cornerRadius: CGFloat, fill: Color = WarmSignal.glass) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, fill: fill))
    }
}
