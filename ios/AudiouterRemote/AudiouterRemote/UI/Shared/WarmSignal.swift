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

    /// The gutter both fader rows keep at each end, for their CONTENT. The
    /// level does not take it: ``LevelLight`` and the drag both run on the
    /// bare row width, so there is exactly one coordinate for the value and
    /// the light's edge, the mark on it and the finger can never disagree
    /// about where it is.
    static let rowGutter: CGFloat = 12

    /// What a row draws around itself while its level is being set. The row
    /// IS the track: outlining the shape that is already there turns the wash
    /// into a partial fill of a visible container — the denominator light
    /// alone cannot give — without a single new object appearing. An outline
    /// rather than a tint on the remainder because `rim` holds 3.53:1 light
    /// and 4.25:1 dark against the lit side, where every remainder tint in the
    /// palette lands between 1.02:1 and 1.84:1 and needs a different token in
    /// each appearance to read at all.
    static let trackRim = rim

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

/// The level, drawn as light: doc:1853's wash, with the light coming FROM the
/// level rather than fading toward it.
///
/// The original gradient ran bright at zero and faint at the value, so the
/// level's own position was the dimmest part of the fill and the whole thing
/// read as a tint that ran out. Reversed, the leading edge is the light
/// source and the glow decays backward from it — which is both what a level
/// looks like and what this identity is called.
///
/// How bright it may get is not a taste question. The row's text sits ON this
/// wash, so the text caps it: a playing row's gold `PLAYING` sub-label
/// measures 4.36–4.46:1 on the flat 0.14 the design shipped, against a 4.5:1
/// floor. So the base stays at 0.05 (4.72:1 for that label, everywhere), and
/// the brightness lives in ``bloom`` — a band held back from the text column
/// entirely, which is what lets it be brighter than the wash has ever been at
/// the point the eye actually needs.
struct LevelLight: View {
    /// 0...1. The wash and the mark take the SAME fraction of the SAME row
    /// width the drag maps to, so the light's edge, the mark on it and the
    /// finger can never disagree about where the value is.
    let fraction: CGFloat
    let width: CGFloat
    let muted: Bool
    let dragging: Bool

    /// The full-height wash, and the only part of the level that passes behind
    /// the row's words. Text-safe at every level: `goldText` on it is 4.72:1,
    /// over the floor wherever the sub-label happens to land — and at 1.09:1
    /// against the ground it is nearly a step the eye cannot find — but only
    /// nearly, and a straight vertical boundary is the one thing a reader can
    /// spot at any contrast. So it does not have one: the last ``fade`` points
    /// ramp to nothing, and the wash simply stops being there. Every crisp
    /// edge in this view lives in the bottom band, under the words.
    private static let base: Double = 0.05
    private static let fade: CGFloat = 28

    /// EVERYTHING WITH A HARD EDGE LIVES BELOW THE TEXT. The bloom and the
    /// mark are the two parts of this view a reader can actually locate, so
    /// both are confined to a band under the sub-label's descender — at every
    /// value, not only the ones that clear the name column. A level mark that
    /// is full-height at 70 and full-height at 34 puts a rule through the
    /// middle of a word at 34, and reads as a broken layout rather than as a
    /// level; a mark that changes shape by value would make two adjacent rows
    /// look like two different components.
    ///
    /// The bloom fades to nothing at the top of its band, so it never has a
    /// horizontal edge of its own to notice, and the mark simply starts below
    /// the halo. Both are measured from the BOTTOM, so one set of numbers
    /// serves the 60 pt device row and the 48 pt drawer row alike.
    private static let bloomBand: CGFloat = 12
    private static let markHeight: CGFloat = 8

    /// The light at the level. Brighter than the wash has ever been at the
    /// point the eye needs it, which it can afford to be precisely because no
    /// text sits on it.
    private static let bloomPeak: Double = 0.22

    /// The mark, and its one change under a finger: it firms up in place
    /// rather than being joined by anything. Nothing new appears on a drag —
    /// the row's own edge becomes visible (``WarmSignal/trackRim``) and the
    /// mark thickens, so the instrument is the row rather than a second object
    /// bolted to it.
    private static let markWidth: CGFloat = 2
    private static let markWidthDragging: CGFloat = 3
    private static let markHeightDragging: CGFloat = 12

    /// A muted speaker keeps its LEVEL and loses its GLOW: the base wash and
    /// the mark hold the value exactly where it was (the mark is `goldText`,
    /// 3.73:1 against canvas, muted or not), and only the bloom — the part
    /// that reads as sound in the room — goes out. Dimming the level itself to
    /// make a point about mute is what took the old muted wash to 1.04:1,
    /// where the value simply vanished.
    private var showsBloom: Bool { !muted }

    private var edge: CGFloat { max(0, min(1, fraction) * width) }

    private var markW: CGFloat { dragging ? Self.markWidthDragging : Self.markWidth }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(LinearGradient(
                    stops: [.init(color: WarmSignal.gold.opacity(Self.base), location: 0),
                            .init(color: WarmSignal.gold.opacity(Self.base),
                                  location: max(0, 1 - Self.fade / max(edge, 1))),
                            .init(color: WarmSignal.gold.opacity(0), location: 1)],
                    startPoint: .leading, endPoint: .trailing))
                .frame(width: edge)
                .frame(maxHeight: .infinity)

            if showsBloom {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [WarmSignal.gold.opacity(0), WarmSignal.gold.opacity(Self.bloomPeak)],
                        startPoint: .leading,
                        endPoint: .trailing))
                    .frame(width: edge, height: Self.bloomBand)
                    .mask(LinearGradient(colors: [.clear, .black],
                                         startPoint: .top, endPoint: .bottom))
            }

            // doc:1854-1856's edge line, as a mark rather than a rule.
            // `goldText` for the reason it always was — on paper a dark mark is
            // what reads: 3.73:1 against canvas at rest, 4.17:1 under a finger.
            // It stands at the bloom's brightest point, so the mark and the
            // light read as one statement rather than two.
            Rectangle()
                .fill(WarmSignal.goldText)
                .frame(width: markW, height: dragging ? Self.markHeightDragging : Self.markHeight)
                .opacity(dragging ? 1 : 0.9)
                .offset(x: max(0, min(width - markW, edge - markW / 2)))
        }
        .accessibilityHidden(true)
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

// MARK: - Level styles (concept sprint)

/// Three ways a row can show its level, switchable live from Settings in a
/// DEBUG build so the choice can be made with a thumb rather than a rebuild.
///
// razor: DEBUG-only chooser for a decision in flight. When one wins, keep that
// case, delete the enum and the picker in `RemoteSettingsView`, and inline it.
enum LevelStyle: String, CaseIterable, Identifiable {
    case light, dial, meter
    var id: String { rawValue }

    /// The words the picker shows. Household, not console — a picker is chrome
    /// but these name the thing being chosen.
    var title: String {
        switch self {
        case .light: return "Light"
        case .dial:  return "Dial"
        case .meter: return "Meter"
        }
    }

    static let storageKey = "debug.levelStyle"

    /// What a fresh install shows. Both `@AppStorage` sites take their default
    /// from here, so the row and the picker cannot disagree about what the app
    /// looks like before anyone has picked anything.
    static let standard: LevelStyle = .dial
}

/// V2 — the level as a gold arc around the speaker's own halo ring.
///
/// The ring is already there and already means "live", so the level costs no
/// width, no height and no new object; and a circle is the one denominator
/// that needs no explaining, because its whole is visible at every value. It
/// cannot collide with the name at any level by construction — it is not in
/// the text column at all.
///
/// Track `well` rather than the halo's usual `ring`: a gold arc on `ring`
/// measures 1.12:1 in light, which is no arc at all. On `well` it is 3.04:1
/// light / 10.51:1 dark, over the 3:1 floor in both, and the muted arc's `rim`
/// is 3.46:1 / 4.82:1 on the same track.
///
/// A KNOB, NOT A FULL CIRCLE, and the routed dot is why: ``DeviceRowView``'s
/// `routedDot` sits on the halo's lower right and is gold too, so any arc that
/// reaches that angle merges with it into one shape at 44 pt. So the arc gets a
/// physical volume knob's travel and a permanent dead zone, and the dead zone
/// is centred on the dot — which puts the dot inside the gap at every value,
/// both stops included.
struct LevelDial: View {
    let fraction: CGFloat
    let muted: Bool
    let dragging: Bool

    /// Where the gap's centre sits, in degrees clockwise from 12 o'clock.
    ///
    /// It is where the dot is: an 11 pt disc, `bottomTrailing` of the 44 pt
    /// halo, offset (1, −2), which puts its centre 17.5 pt right of and 14.5 pt
    /// below the halo's centre — 129.6° round from straight up, or about 4:19
    /// on a clock face.
    static let gapCenter: Double = 129.6

    /// A knob's own convention, turned to face the dot: 7 o'clock to 5 o'clock
    /// is 300° of travel and a 60° dead zone, and here the dead zone lands on
    /// the dot rather than at the bottom. 30° either side of the dot puts each
    /// stop 11.4 pt from its centre — 5.9 pt clear of the disc's outer edge,
    /// 7.4 pt clear of the gold inside it, at 0 and at 100 alike.
    static let travel: Double = 300

    private var lineWidth: CGFloat { dragging ? 3.5 : 2.5 }

    /// The travel, and the lit part of it, as fractions of the whole circle.
    private var span: CGFloat { CGFloat(Self.travel / 360) }
    private var lit: CGFloat { span * max(0, min(1, fraction)) }

    var body: some View {
        ZStack {
            knob(to: span).stroke(WarmSignal.well, style: stroke)
            knob(to: lit).stroke(muted ? WarmSignal.rim : WarmSignal.gold, style: stroke)
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
        .animation(nil, value: fraction)
    }

    private var stroke: StrokeStyle {
        // Butt caps: the fill's end IS the value, and a round cap would put a
        // dot of gold at the min stop even at zero.
        StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
    }

    /// `trim` starts at 3 o'clock and runs clockwise, so the whole path is
    /// turned until its start lands on the knob's min stop — 30° clockwise of
    /// the gap's centre.
    private func knob(to end: CGFloat) -> some Shape {
        Circle()
            .trim(from: 0, to: end)
            .rotation(.degrees(Self.gapCenter + (360 - Self.travel) / 2 - 90))
    }
}

/// V3 — the level as a short meter under the device's name.
///
/// The Mac's popover already draws a per-app volume as a gold underline
/// beneath the app's name, so this is the one variant that is not invented
/// here: it makes the phone and the Mac say the level the same way. It sits
/// inside the content column, tied to the name it belongs to, rather than
/// spanning the row — which is what keeps it from being a strip under the row.
///
/// A FIXED width, not the name's: a mixer is for comparing rows, and a meter
/// whose full scale is "however long this speaker is called" cannot be
/// compared with the one above it.
///
/// Track `meter` with a `goldText` fill is the only pairing in the palette
/// that clears both floors in both grounds at once: fill on track 3.03:1 light
/// / 5.04:1 dark, track against canvas 1.64:1 / 1.99:1 so the remainder is
/// visible at all.
struct LevelMeter: View {
    let fraction: CGFloat
    let muted: Bool
    let dragging: Bool

    static let trackWidth: CGFloat = 120
    private var height: CGFloat { dragging ? 5 : 3 }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(WarmSignal.meter)
            Capsule()
                .fill(muted ? WarmSignal.rim : WarmSignal.goldText)
                .frame(width: max(0, min(1, fraction) * Self.trackWidth))
        }
        .frame(width: Self.trackWidth, height: height)
        .accessibilityHidden(true)
    }
}
