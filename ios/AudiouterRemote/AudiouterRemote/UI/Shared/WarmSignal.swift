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

    static let canvas   = warm(light: 0xFBFBF9, dark: 0x16130F)
    static let canvasHi = warm(light: 0xFBFBF9, dark: 0x1B1712)
    static let panel    = warm(light: 0xFBFBF9, dark: 0x1D1915)
    static let raised   = warm(light: 0xFBFBF9, dark: 0x241F1A)
    static let well     = warm(light: 0xF5F4ED, dark: 0x100D0A)
    static let hairline = warm(light: 0xE7E6DF, dark: 0x3A332B)

    // MARK: Ink

    static let label  = warm(light: 0x1E1C1C, dark: 0xFFFFFF, darkAlpha: 0.92)
    static let label2 = warm(light: 0x706464, dark: 0xFFFFFF, darkAlpha: 0.55)
    static let label3 = warm(light: 0x76716B, dark: 0xFFFFFF, darkAlpha: 0.28)

    // MARK: Signal

    static let gold    = warm(light: 0xA97F1E, dark: 0xE8B84B)
    static let ember   = warm(light: 0xC2A05A, dark: 0x8A6A2F)
    static let glow    = warm(light: 0xE8B84B, dark: 0xFFD97A)
    static let ring    = warm(light: 0xA08C66, dark: 0x8D7D5E)
    static let fail    = warm(light: 0xBB3A2F, dark: 0xD9564A)
    static let caution = warm(light: 0xB3701C, dark: 0xE29A3D)

    // MARK: Instruments

    /// The fader thumb's gradient stops (doc:138 dark, doc:366 light).
    static let thumb    = warm(light: 0x9E8D6B, dark: 0x857762)
    static let thumbLow = warm(light: 0x8A7A62, dark: 0x5F5546)
    static let rim      = warm(light: 0x9E8D6B, dark: 0x6B5F4E)
    static let meter    = warm(light: 0xCBBEA1, dark: 0x4E463A)
    static let pill     = warm(light: 0xD0CDC3, dark: 0x38322B)
    static let socket   = warm(light: 0xE0D8C6, dark: 0x34302A)

    // MARK: Glass

    static let glass     = warm(light: 0xFAF7EE, dark: 0x342D25, lightAlpha: 0.66, darkAlpha: 0.52)
    static let glassEdge = warm(light: 0x1E1C1C, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.11)
    static let glassHi   = warm(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.80, darkAlpha: 0.10)

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
}

// MARK: - Type primitives

/// The design's micro-label voice (doc:36): monospaced, uppercase, tracked out.
/// 9.5 pt is the common size (doc:57, doc:72-73, doc:124, doc:195); the two
/// places that use 9 (doc:126, doc:197) pass it.
struct MicroLabel: ViewModifier {
    let size: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .bold, design: .monospaced))
            .tracking(size * 0.09)
            .textCase(.uppercase)
    }
}

/// A numeric readout: monospaced, tight, so the digits don't shuffle as the
/// value changes under a finger.
struct Readout: ViewModifier {
    let size: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .bold, design: .monospaced))
            .tracking(-0.4)
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
    func microLabel(_ size: CGFloat = 9.5) -> some View { modifier(MicroLabel(size: size)) }

    func readout(_ size: CGFloat) -> some View { modifier(Readout(size: size)) }

    func glassPanel(cornerRadius: CGFloat, fill: Color = WarmSignal.glass) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, fill: fill))
    }
}
