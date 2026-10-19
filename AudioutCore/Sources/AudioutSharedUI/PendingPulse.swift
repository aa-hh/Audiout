// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The breath both Cast pending glows read: the fader thumb in
/// `WarmFaderCell` and the sync drawer's value field in `BTSyncDrawerView`.
/// One curve, so the two cannot drift apart. Pure: time in, strength out.
/// The consumers own the timers that sample it.
///
/// Shape, from the owner's pick on 2026-10-06: a 160 ms ramp in, then a
/// 1.4 s breath that rises quickly (0.35 to 1 in 0.4 s, ease-out) and falls
/// slowly (back in 1.0 s, ease-in-out). When the hold ends the light rises to
/// 1 in 100 ms and goes out in 450 ms. Reduce Motion holds 0.7 and goes out
/// with no fade.
public struct PendingPulse {

    static let floor: CGFloat = 0.35
    static let reducedStrength: CGFloat = 0.7
    static let rampIn: TimeInterval = 0.16
    static let breathRise: TimeInterval = 0.4
    static let breathFall: TimeInterval = 1.0
    static let arrivalRise: TimeInterval = 0.1
    static let arrivalFade: TimeInterval = 0.45
    /// The consumers' repaint rate.
    static let frameInterval: TimeInterval = 1.0 / 30

    /// The breath `elapsed` seconds after the hold started.
    public static func strength(elapsed: TimeInterval, reduceMotion: Bool) -> CGFloat {
        if reduceMotion { return reducedStrength }
        let t = max(0, elapsed)
        let phase = t.truncatingRemainder(dividingBy: breathRise + breathFall)
        let breath: CGFloat
        if phase < breathRise {
            let x = CGFloat(phase / breathRise)
            breath = floor + (1 - floor) * (1 - (1 - x) * (1 - x))
        } else {
            let x = CGFloat((phase - breathRise) / breathFall)
            breath = 1 - (1 - floor) * x * x * (3 - 2 * x)
        }
        return t < rampIn ? breath * CGFloat(t / rampIn) : breath
    }

    /// The arrival `sinceEnd` seconds after the hold ended at strength
    /// `from`, or nil once it has gone out.
    public static func arrival(sinceEnd: TimeInterval, from: CGFloat) -> CGFloat? {
        let t = max(0, sinceEnd)
        if t < arrivalRise {
            return from + (1 - from) * CGFloat(t / arrivalRise)
        }
        let x = (t - arrivalRise) / arrivalFade
        guard x < 1 else { return nil }
        return CGFloat(pow(2, -10 * x))
    }

    private var start: CFTimeInterval?
    private var end: (time: CFTimeInterval, from: CGFloat)?

    public init() {}

    /// Start a hold. A re-arm while already holding keeps the phase.
    public mutating func begin(at now: CFTimeInterval) {
        guard start == nil || end != nil else { return }
        start = now
        end = nil
    }

    /// End the hold: the arrival plays, or under Reduce Motion the light goes
    /// straight out.
    public mutating func finish(at now: CFTimeInterval, reduceMotion: Bool) {
        guard let start, end == nil else { return }
        if reduceMotion {
            self.start = nil
            return
        }
        end = (now, Self.strength(elapsed: now - start, reduceMotion: false))
    }

    /// Whether the hold has ended and its arrival is still playing.
    public var isArriving: Bool { end != nil }

    /// The strength at `now`, or nil when nothing is lit.
    public mutating func value(at now: CFTimeInterval, reduceMotion: Bool) -> CGFloat? {
        guard let start else { return nil }
        guard let end else {
            return Self.strength(elapsed: now - start, reduceMotion: reduceMotion)
        }
        if let lit = Self.arrival(sinceEnd: now - end.time, from: end.from) { return lit }
        self.start = nil
        self.end = nil
        return nil
    }

    // MARK: Colours

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The glow's light, resolved for `appearance`.
    static func light(in appearance: NSAppearance) -> NSColor {
        resolved(in: appearance) { Tokens.Color.pendingGlow }
    }

    /// The number's ink at strength `g`, from ``Tokens/Color/pendingInkDim``
    /// to ``Tokens/Color/goldText``. `nil` (Reduce Motion) holds the dim end.
    static func ink(strength g: CGFloat?, in appearance: NSAppearance) -> NSColor {
        resolved(in: appearance) {
            let dim = Tokens.Color.pendingInkDim
            guard let g else { return dim }
            return dim.blended(withFraction: g, of: Tokens.Color.goldText) ?? Tokens.Color.goldText
        }
    }

    /// Dynamic tokens resolve against the current drawing appearance, so a
    /// blend made outside a draw would pick whichever appearance is current.
    private static func resolved(in appearance: NSAppearance,
                                 _ make: () -> NSColor) -> NSColor {
        var color = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            let made = make()
            color = made.usingColorSpace(.sRGB) ?? made
        }
        return color
    }
}
