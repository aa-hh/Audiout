// Copyright (c) 2026 ahh. All rights reserved.

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

    /// Dark keeps a graded ladder; LIGHT is one flat near-white ground, and
    /// separation there is carried by ``containerEdge`` below instead of by a
    /// fill step. Both platforms hold the same five light values, so a surface
    /// named `panel` is the same pixel on a Mac and on a phone.
    ///
    /// The flat ground is Alec's decision (2026-08-12), taken on measurements
    /// against a rendered comparison of every alternative — it is not a
    /// correction of anything. A stepped light ladder is the intuitive answer
    /// and it does not survive measurement twice over. Its steps land at
    /// 1.04–1.08:1, under this project's own 1.10:1 surface floor, so it buys
    /// perception without buying separation; and every ink and instrument
    /// measures BEST on the flat near-white and worse on each rung down
    /// (`label2` gives up 0.4 of a contrast point on a stepped canvas, `gold`
    /// falls from 3.67:1 to 3.39:1). To make those steps measure, the ground
    /// has to stop being a near-white ground.
    ///
    /// An edge costs neither, because nothing on this screen is ever drawn ON
    /// an edge — which is what makes it the one lever with slack in it.
    static let canvas   = warm(light: 0xFBFBF9, dark: 0x16130F)
    static let canvasHi = warm(light: 0xFBFBF9, dark: 0x1B1712)
    static let panel    = warm(light: 0xFBFBF9, dark: 0x1D1915)
    static let raised   = warm(light: 0xFBFBF9, dark: 0x241F1A)
    static let well     = warm(light: 0xE8E6DC, dark: 0x100D0A)

    /// The rule INSIDE a container — a row separator, a section-header lead-in
    /// — as opposed to the container's own edge, which is ``containerEdge``.
    /// It carries a real floor where the grounds above carry none: ≥1.25:1
    /// against the surface it divides, the same floor the Mac holds its
    /// divider to. Light `#D0CDC3` measures 1.54:1 against the flat ground and
    /// 1.27:1 against `well`. Anything lighter fails on paper (`#E7E6DF` lands
    /// at 1.21:1 on the ground and 1.00:1 on `well` — an edge nobody can see).
    /// The Mac's hex exactly; nothing about it is iOS-specific.
    static let hairline = warm(light: 0xD0CDC3, dark: 0x3A332B)

    /// A container's OWN outer edge — the resting rim of a halo, a card, a
    /// seat — where ``hairline`` rules that container's interior. Two weights
    /// of one mechanism, and the split is what replaces the light fill ladder:
    /// on a flat ground the edge is the only boundary pixel a surface gets.
    ///
    /// Light `#C4C0B4` measures 1.76:1 against the flat ground and 1.45:1
    /// against `well`, both over the 1.25:1 edge floor, and it clears the
    /// ``hairline`` divider by 1.14:1 — enough to rank the two, short of
    /// reading as two different materials. Dark resolves to `hairline`'s own
    /// value by decision: dark still HAS a fill ladder, and its single
    /// hairline already measures 1.40:1 against `panel` and 1.56:1 against
    /// `well`, at or above where the light edge lands.
    ///
    /// The Mac's `Tokens.Color.containerEdge` carries the same name and the
    /// same two hexes. It also ships an Increase Contrast pair, which this
    /// palette has no layer for — every token here is a light/dark pair only.
    static let containerEdge = warm(light: 0xC4C0B4, dark: 0x3A332B)

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

    /// The signal, as a GRAPHIC — held to the 3:1 control floor against the
    /// tightest ground it draws on, which is `well` (the level arc's own
    /// track), not the flat ground. Light `#A67C1E` measures well 3.04:1,
    /// deckFill 3.58:1, flat ground 3.67:1; the Mac app carries the same hex
    /// at the same ~41.5° hue. For text, see ``goldText``.
    static let gold    = warm(light: 0xA67C1E, dark: 0xE8B84B)

    /// Light-mode `gold` measures 3.04–3.67:1 against every surface it sits on
    /// as text — all fail the 4.5:1 text floor, even though the same hex
    /// clears 3:1 everywhere as a graphic (fader fill, wash, dots), so only
    /// text uses need to move. `#825E0F` clears the floor on all three: `well`
    /// is the tightest at 4.72:1, then deckFill 5.55:1 and the flat ground
    /// 5.70:1, all while staying in the same hue family (41.2°, within a
    /// degree of `gold`). `well` is where the App-routing destination badge
    /// draws it, so that is the surface the value is set from; the headroom
    /// over 4.5 is banked deliberately, the same way ``ring`` banks its own,
    /// so a later move in the light ground cannot drop it back under. Dark is
    /// untouched — dark `gold` already clears 7.4–10.5:1 everywhere. Use this
    /// instead of `gold` for any text, at or below 16 pt, that must read as
    /// gold.
    static let goldText = warm(light: 0x825E0F, dark: 0xE8B84B)

    /// Gold's dim companion, and an instrument in its own right, so it carries
    /// ``gold``'s 3:1 floor rather than being free to fade: light `#9C7E3C`
    /// measures well 3.07:1, deckFill 3.62:1, flat ground 3.71:1 — the Mac's
    /// hex, exactly. A lighter tan reads as "dimmer" and clears
    /// nothing (`#C2A05A` is 2.06:1 on `well`). Pinning both inks just over
    /// 3:1 on the same ground puts their luminances within 0.03 of each other,
    /// so in LIGHT this reads dimmer than `gold` by CHROMA, not by luminance —
    /// a muted brown beside a saturated gold. Dark keeps the luminance
    /// hierarchy. Same trade the Mac makes.
    static let ember   = warm(light: 0x9C7E3C, dark: 0x8A6A2F)
    static let glow    = warm(light: 0xE8B84B, dark: 0xFFD97A)
    /// The connected solid halo and the connecting/reconnecting dashed halo —
    /// a graphic, so it carries the 3:1 control floor against every ground it
    /// draws on, and it is a SHARED instrument, so the light value must clear
    /// that floor on the Mac's ladder too. The tightest ground across both
    /// platforms is `well` `#E8E6DC` (the darkest light surface ⇒ least
    /// contrast for a dark ink), which both platforms now share.
    /// Light `#8B7958` measures well 3.37:1, deckFill 3.97:1, flat ground
    /// 4.08:1 — headroom banked on purpose so a later move in the light
    /// ground cannot drop it back under the floor. Still the same hue-neutral
    /// warm grey (~38.8° at 0.37 saturation); it is chroma, not hue, that
    /// keeps it from reading as
    /// `gold`. The Mac carries this hex exactly. Dark is untouched.
    static let ring    = warm(light: 0x8B7958, dark: 0x8D7D5E)
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
    /// level does not take it: the drag and the in-drag remainder fill both
    /// run on the bare row width, so there is exactly one coordinate for the
    /// value, and the fill's edge and the finger can never disagree about
    /// where it is.
    static let rowGutter: CGFloat = 12

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
    /// (nil → 0, nil → 100) and none while sitting on one — this tick marks
    /// the end of the travel, and it is the STRONGER of the two the finger
    /// gets. The travel itself is ``FaderDetents``, which stays quieter and
    /// stands down at both ends so the stop never arrives twice.
    static func faderRail(_ value: Int, dragging: Bool) -> Int? {
        guard dragging, value == 0 || value == 100 else { return nil }
        return value
    }

    /// The detent clicks a volume drag passes through — the row's dial and the
    /// deck's fader share this one rule, exactly as they share ``faderValue``
    /// and ``faderRail``.
    ///
    /// A mixer's controls click. The row's knob and the deck's fader are drawn
    /// as instruments, and an instrument answers the hand on the way, not only
    /// at the ends — so the finger gets a soft click every ``step`` units and
    /// can set a level by feel without watching the number.
    ///
    /// Three things it deliberately does NOT do:
    ///
    /// - **The rails win.** 0 and 100 are multiples of ``step``, but they
    ///   already have ``faderRail``'s stronger tick. Arriving at a stop must
    ///   not feel like passing a notch, so the detent stays silent there —
    ///   while still recording the position, so leaving a rail doesn't fire
    ///   late.
    /// - **It thins, it never queues.** A fast swipe crosses the whole track
    ///   in a quarter second: 20 detents in 250 ms is 80 clicks a second, and
    ///   anything past roughly 20 blurs into a buzz. Past ``minimumGap`` the
    ///   click is DROPPED, not deferred — a queued click would land after the
    ///   finger had moved on and feel like lag.
    /// - **It counts crossings, not units.** One drag tick that jumps several
    ///   detents is one click, because the hand made one movement.
    ///
    /// ``ticks`` is the `.sensoryFeedback` trigger: it moves only when a click
    /// is owed, so nothing fires outside an active drag.
    struct FaderDetents {
        /// Detent spacing, in volume units. The same 5 the rows' VoiceOver
        /// adjustable action steps by, so "one notch" means one thing whether
        /// it is felt or spoken. Finer (1) is a buzz at any real drag speed;
        /// coarser (10) gives a 100-unit track only ten notches, which is too
        /// few to set a level by.
        static let step = 5

        /// The tick-rate ceiling: 50 ms ≈ 20 clicks a second, the point past
        /// which separate taps stop reading as separate.
        static let minimumGap: Duration = .milliseconds(50)

        /// How hard a detent clicks, against the rails' full-strength light
        /// impact. Same family, a fraction of the force: the two have to be
        /// telling the finger different things. `.selection` — the picker
        /// convention — was the other candidate and is rejected for exactly
        /// this: it is a fixed strength with no defined relationship to the
        /// tick already on this control.
        ///
        /// The number is a thumb's answer, not a derivation — it was set by
        /// dragging on hardware, because a phone in a case transmits less than
        /// a simulator suggests. Two bounds hold it: it must stay under the
        /// rails' 1.0, or a stop and a crossing become the same event; and it
        /// cannot be re-judged anywhere but on a device.
        static let intensity: Double = 0.52

        private var lastDetent: Int?
        private var lastTickedAt: ContinuousClock.Instant?

        /// Every click this control has given the finger. Monotonic on
        /// purpose — a trigger that returned to an earlier value would fire
        /// nothing.
        private(set) var ticks = 0

        init() {}

        /// The gesture's start. Where the finger already is is not a crossing,
        /// and the rate limit starts fresh.
        mutating func begin(at value: Int) {
            lastDetent = value / Self.step
            lastTickedAt = nil
        }

        /// One tick of the drag. Call with the value the finger just landed on.
        mutating func advance(to value: Int, now: ContinuousClock.Instant = .now) {
            let detent = value / Self.step
            defer { lastDetent = detent }
            guard detent != lastDetent else { return }
            guard value != 0, value != 100 else { return }
            if let last = lastTickedAt, now - last < Self.minimumGap { return }
            lastTickedAt = now
            ticks += 1
        }
    }
}

// MARK: - Type primitives

/// The design's micro-label voice: small, semibold, sentence case, in the
/// plain system face. Strings render exactly as authored — no `.textCase`
/// transform, no monospaced design, no tracking. State is carried by tint
/// and weight, not by capitals.
///
/// 11 pt is the HIG floor for any text, and also the default size here, so
/// no call site should pass anything smaller than the default.
///
/// Scales with `@ScaledMetric`, not `.custom("", size:relativeTo:)`: an empty
/// font name has no documented meaning, and nothing verifies it carries
/// weight through Dynamic Type scaling. A plain `@ScaledMetric` point size
/// composed with an explicit `.system(size:weight:)` guarantees it.
struct MicroLabel: ViewModifier {
    @ScaledMetric private var scaledSize: CGFloat

    init(size: CGFloat) {
        self._scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .caption2)
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: scaledSize, weight: .semibold))
    }
}

/// A numeric readout: tabular digits so the number doesn't shuffle as the
/// value changes under a finger — the digits are fixed-width, the face is
/// not. See ``MicroLabel`` for why this scales via `@ScaledMetric` rather
/// than the old empty-name `.custom(...)` hack.
struct Readout: ViewModifier {
    @ScaledMetric private var scaledSize: CGFloat

    init(size: CGFloat) {
        self._scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: scaledSize, weight: .bold))
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
    /// mute button would take a 48 pt row to 64.
    ///
    /// `drawn` is the size the control actually paints, so the padding can be
    /// exactly what the floor needs and no more.
    func hittable(drawn: CGFloat) -> some View {
        let pad = max(0, (WarmSignal.hitTarget - drawn) / 2)
        return padding(pad)
            .contentShape(Rectangle())
            .padding(-pad)
    }

    func microLabel(_ size: CGFloat = 11) -> some View {
        modifier(MicroLabel(size: size))
    }

    func readout(_ size: CGFloat) -> some View { modifier(Readout(size: size)) }

    func glassPanel(cornerRadius: CGFloat, fill: Color = WarmSignal.glass) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, fill: fill))
    }
}

// MARK: - The level

/// The level, as a gold arc around the speaker's own halo ring.
///
/// The ring is already there and already means "live", so the level costs no
/// width, no height and no new object; and a circle is the one denominator
/// that needs no explaining, because its whole is visible at every value. It
/// cannot collide with the name at any level by construction — it is not in
/// the text column at all.
///
/// Track `well` rather than the halo's usual `ring`: a gold arc on `ring`
/// measures 1.11:1 in light, which is no arc at all. On `well` it is 3.04:1
/// light / 10.51:1 dark, over the 3:1 floor in both, and the muted arc's `rim`
/// is 3.33:1 / 4.82:1 on the same track.
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
