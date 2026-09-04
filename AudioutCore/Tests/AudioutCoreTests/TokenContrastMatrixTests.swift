// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutSharedUI

/// Design-token audit (2026-08-27), finding class "the token passed its own
/// test, the composition was never measured" (P1-1..P1-4, P2-1..P2-4, P2-6,
/// P2-7, P3-2, P3-3): a GENERALIZED contrast matrix over every
/// `Tokens.Color` instrument this pass touched or already carries a stated
/// floor for, swept over appearance x Increase Contrast x (for the two
/// accent-remapped instruments this file checks) the accent dial, so a
/// future hex edit that quietly drops below its own documented floor fails a
/// test instead of merging silently.
///
/// Nested into `SerializedSharedState` (see `SerializedSharedStateSuite.swift`)
/// alongside `OnboardingPermissionColorTests`: both mutate the process-global
/// `Tokens.accentStyle`, and this file additionally mutates the
/// `Tokens.test_increaseContrastOverride` seam — running concurrently with
/// another suite doing the same would be a real, reproducible race.
///
/// DELIBERATE EXCLUSIONS — tokens/pairs this matrix does NOT re-check because
/// another suite already owns them, or because the pairing has no floor to
/// begin with:
///  - The five `permission*` identity hues, `bluetoothBrand`, and
///    gold-on-raised across BOTH dial columns — all swept by
///    `OnboardingPermissionColorTests`.
///  - Surface-separation floors (`well`/`panel`/`raised`/`hairline` ratios
///    against EACH OTHER) — `MembershipWellContrastTests`' job; this file
///    only uses those tokens as fixed GROUNDS for a foreground instrument.
///  - The floor-exempt backdrops `canvas`, `panel`, `raised`, `well`,
///    `liveRow`, `liveRaised`, `glow`, `socket` and `meter` — each documented
///    as a quiet surface in its own Tokens.swift rationale. `socket` is exempt
///    from a GROUND floor only: it is always ringed, and Test D below pins it
///    against the ring. `panel` is likewise exempt as a ground, but Test A
///    holds it to a glyph floor in the one place it is a FOREGROUND: knocked
///    out of the mute pill.
@MainActor
extension SerializedSharedState {

@Suite final class TokenContrastMatrixTests: IsolatedSuite {

    deinit {
        // Both are process-global test seams; restore them unconditionally so
        // no other test in the process inherits a dialed accent or a forced
        // Increase-Contrast reading.
        Tokens.accentStyle = .fullGold
        Tokens.test_increaseContrastOverride = nil
    }

    // MARK: - Ported helpers (see `OnboardingPermissionColorTests` for provenance)

    private func resolved(_ color: NSColor, appearanceName: NSAppearance.Name) -> NSColor {
        var result = color
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let c = color.usingColorSpace(.sRGB)!
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    private func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let l1 = relativeLuminance(a), l2 = relativeLuminance(b)
        let (hi, lo) = l1 > l2 ? (l1, l2) : (l2, l1)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Alpha-composite `fg` over `bg` when `fg` isn't fully opaque — the dark
    /// system `secondaryLabelColor` resolves to a translucent component
    /// color, so measuring its RAW components against a ground understates
    /// (or overstates) the contrast a viewer actually sees. A no-op when
    /// `fg` is already opaque.
    private func composited(_ fg: NSColor, over bg: NSColor) -> NSColor {
        guard let fgSRGB = fg.usingColorSpace(.sRGB), let bgSRGB = bg.usingColorSpace(.sRGB) else { return fg }
        let alpha = fgSRGB.alphaComponent
        guard alpha < 1 else { return fgSRGB }
        func blend(_ f: CGFloat, _ b: CGFloat) -> CGFloat { f * alpha + b * (1 - alpha) }
        return NSColor(srgbRed: blend(fgSRGB.redComponent, bgSRGB.redComponent),
                       green: blend(fgSRGB.greenComponent, bgSRGB.greenComponent),
                       blue: blend(fgSRGB.blueComponent, bgSRGB.blueComponent),
                       alpha: 1)
    }

    /// Resolve `token`/`ground` under `appearanceName` (and whatever
    /// `Tokens.test_increaseContrastOverride`/`Tokens.accentStyle` the caller
    /// already set), composite the token over the ground, and measure.
    private func measuredRatio(_ token: NSColor, over ground: NSColor,
                               appearanceName: NSAppearance.Name) -> CGFloat {
        let resolvedToken = resolved(token, appearanceName: appearanceName)
        let resolvedGround = resolved(ground, appearanceName: appearanceName)
        return contrastRatio(composited(resolvedToken, over: resolvedGround), resolvedGround)
    }

    private func assertColorsDiffer(_ a: NSColor?, _ b: NSColor?, _ message: String,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        guard let aRGB = a?.usingColorSpace(.sRGB), let bRGB = b?.usingColorSpace(.sRGB) else {
            Issue.record("nil or non-convertible color: \(message)", sourceLocation: sourceLocation)
            return
        }
        let differs = abs(aRGB.redComponent - bRGB.redComponent) > 0.01
            || abs(aRGB.greenComponent - bRGB.greenComponent) > 0.01
            || abs(aRGB.blueComponent - bRGB.blueComponent) > 0.01
        #expect(differs, Comment(rawValue: message), sourceLocation: sourceLocation)
    }

    // MARK: - Test A: the matrix

    private struct ContrastEntry {
        let name: String
        let token: NSColor
        let floor: CGFloat
        /// Most entries guarantee the SAME grounds in both appearances
        /// (`sameGrounds`); the closure shape stays so a token whose rationale
        /// guarantees different grounds per appearance can still be listed.
        let groundsFor: (NSAppearance.Name) -> [(String, NSColor)]
    }

    private func sameGrounds(_ grounds: [(String, NSColor)]) -> (NSAppearance.Name) -> [(String, NSColor)] {
        { _ in grounds }
    }

    /// `(token, ground, appearance, icOn)` pairs known to sit under their
    /// floor on purpose, with the reason on file. The list is meant to
    /// self-clean: Test A asserts the OPPOSITE direction for anything listed
    /// here, so a hex re-tune that lifts a listed pair over its floor fails
    /// loudly instead of leaving a stale exception around forever.
    private struct Exception: Equatable {
        let token: String
        let ground: String
        let appearance: NSAppearance.Name
        let icOn: Bool
    }

    /// None today: every entry below clears its own floor in all four
    /// appearance x Increase-Contrast cells. The mechanism stays because a
    /// future authored under-floor case needs it, and Test A's self-cleaning
    /// assertion keeps a listed pair from going stale.
    private let exceptions: [Exception] = []

    @Test func everyInstrumentClearsItsFloorAcrossAppearanceAndIncreaseContrast() {
        Tokens.accentStyle = .fullGold
        defer { Tokens.test_increaseContrastOverride = nil }

        let canvas = Tokens.Color.canvas
        let panel = Tokens.Color.panel
        let raised = Tokens.Color.raised
        let well = Tokens.Color.well
        let scopeGround = Tokens.Color.scopeGround

        let textGrounds: [(String, NSColor)] = [("canvas", canvas), ("panel", panel),
                                                ("raised", raised), ("well", well)]

        // The two WASHED grounds a device row's mute pill also sits on, built
        // the way `DeviceRowView.draw(_:)` builds them: the row's `panel`
        // ground under the gold live wash, or under the neutral hover wash.
        // Neither is a token, so neither can be named as one — they are
        // composited per appearance and handed in as opaque grounds.
        func rowWashGrounds(_ appearanceName: NSAppearance.Name) -> [(String, NSColor)] {
            let ground = resolved(panel, appearanceName: appearanceName)
            func wash(_ token: NSColor, _ alpha: CGFloat) -> NSColor {
                composited(resolved(token, appearanceName: appearanceName)
                            .withAlphaComponent(alpha), over: ground)
            }
            return [("live wash", wash(Tokens.Color.gold, PopoverColumnGrid.rowLiveWashAlpha)),
                    ("hover wash", wash(Tokens.Color.engagedChrome, PopoverColumnGrid.rowHoverWashAlpha))]
        }

        let entries: [ContrastEntry] = [
            // TEXT, floor 4.5:1
            ContrastEntry(name: "label2", token: Tokens.Color.label2, floor: 4.5,
                         groundsFor: sameGrounds(textGrounds)),
            ContrastEntry(name: "label3", token: Tokens.Color.label3, floor: 4.5,
                         groundsFor: sameGrounds(textGrounds)),
            ContrastEntry(name: "labelCool", token: Tokens.Color.labelCool, floor: 4.5,
                         groundsFor: sameGrounds(textGrounds)),
            ContrastEntry(name: "labelCool2", token: Tokens.Color.labelCool2, floor: 4.5,
                         groundsFor: sameGrounds(textGrounds)),
            ContrastEntry(name: "goldText", token: Tokens.Color.goldText, floor: 4.5,
                         groundsFor: sameGrounds(textGrounds)),
            ContrastEntry(name: "emberText", token: Tokens.Color.emberText, floor: 4.5,
                         groundsFor: sameGrounds(textGrounds)),
            // The prominent button's key-window ink, over the only fill it is
            // ever drawn on. Nothing measures this at runtime any more, so the
            // floor is held here.
            ContrastEntry(name: "inkOnFill", token: Tokens.Color.inkOnFill, floor: 4.5,
                         groundsFor: sameGrounds([("gold", Tokens.Color.gold)])),
            // NON-TEXT, floor 3.0:1
            ContrastEntry(name: "failure", token: Tokens.Color.failure, floor: 3.0,
                         groundsFor: sameGrounds([("panel", panel), ("raised", raised)])),
            // `canvas` joined gold's grounds on 2026-09-04. The omission is why
            // the Equalizer door's gold-on-canvas glyph (3.64:1 light, and
            // inverted against its own at-rest grey) was never caught here.
            ContrastEntry(name: "gold", token: Tokens.Color.gold, floor: 3.0,
                         groundsFor: sameGrounds([("canvas", canvas), ("panel", panel),
                                                  ("raised", raised), ("well", well)])),
            ContrastEntry(name: "ember", token: Tokens.Color.ember, floor: 3.0,
                         groundsFor: sameGrounds([("panel", panel), ("raised", raised), ("well", well)])),
            ContrastEntry(name: "ring", token: Tokens.Color.ring, floor: 3.0,
                         groundsFor: sameGrounds([("canvas", canvas), ("panel", panel), ("raised", raised)])),
            // The mute pill is OPAQUE, so it is measured on every ground a
            // device row can put behind it — at rest, live-washed, hovered.
            ContrastEntry(name: "muted", token: Tokens.Color.muted, floor: 3.0,
                         groundsFor: { appearanceName in
                             [("canvas", canvas), ("panel", panel), ("raised", raised)]
                                 + rowWashGrounds(appearanceName)
                         }),
            // `panel` is a BACKDROP everywhere else; on the mute pill it is the
            // ink the slashed glyph is knocked out in, so it carries a glyph
            // floor there and nowhere else.
            ContrastEntry(name: "panel knocked out of muted", token: panel, floor: 4.5,
                         groundsFor: sameGrounds([("muted", Tokens.Color.muted)])),
            ContrastEntry(name: "rim", token: Tokens.Color.rim, floor: 3.0,
                         groundsFor: sameGrounds([("canvas", canvas), ("raised", raised), ("well", well)])),
            ContrastEntry(name: "railDormant", token: Tokens.Color.railDormant, floor: 3.0,
                         groundsFor: sameGrounds([("canvas", canvas), ("panel", panel), ("raised", raised)])),
            ContrastEntry(name: "scopeFlatLine", token: Tokens.Color.scopeFlatLine, floor: 3.0,
                         groundsFor: sameGrounds([("scopeGround", scopeGround)])),
            ContrastEntry(name: "scopeBypassLine", token: Tokens.Color.scopeBypassLine, floor: 3.0,
                         groundsFor: sameGrounds([("scopeGround", scopeGround)])),
        ]

        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            for icOn in [false, true] {
                Tokens.test_increaseContrastOverride = icOn
                for entry in entries {
                    for (groundName, ground) in entry.groundsFor(appearance) {
                        let ratio = measuredRatio(entry.token, over: ground, appearanceName: appearance)
                        let ratioString = String(format: "%.2f", ratio)
                        let isException = exceptions.contains(
                            Exception(token: entry.name, ground: groundName, appearance: appearance, icOn: icOn))
                        if isException {
                            let message = "listed exception \(entry.name)/\(groundName)/\(appearance.rawValue)/ic=\(icOn) " +
                                "now PASSES (\(ratioString):1) — remove it from the exceptions list"
                            #expect(ratio < entry.floor, Comment(rawValue: message))
                        } else {
                            let message = "\(entry.name) vs \(groundName) \(appearance.rawValue) ic=\(icOn): " +
                                "\(ratioString):1 under \(entry.floor):1"
                            #expect(ratio >= entry.floor, Comment(rawValue: message))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Test B: Subtle-column pin (P2-2)

    /// The audit's "extend `MembershipWellContrastTests` to the Subtle
    /// column" — placed here rather than there because dial mutation
    /// requires the serialized suite
    /// (`OnboardingPermissionColorTests.swift:32-36`'s documented reason).
    /// Expected (own measurement, recorded for the record): light `gold`
    /// 3.42:1 well / 3.95:1 panel; light `ember` 5.02:1 well / 5.79:1 panel.
    /// The text companions carry the 4.5:1 floor on the same two grounds:
    /// `goldText` 4.51:1 / 5.21:1, `emberText` 5.02:1 / 5.79:1.
    @Test func subtleColumnEmberAndGoldClearTheNonTextFloorOnWellAndPanel() {
        Tokens.accentStyle = .subtle
        defer { Tokens.accentStyle = .fullGold }
        let well = Tokens.Color.well
        let panel = Tokens.Color.panel
        let grounds: [(String, NSColor)] = [("well", well), ("panel", panel)]

        let nonTextFloor: CGFloat = 3.0
        for (name, token) in [("ember", Tokens.Color.ember), ("gold", Tokens.Color.gold)] {
            for (groundName, ground) in grounds {
                let ratio = measuredRatio(token, over: ground, appearanceName: .aqua)
                #expect(ratio >= nonTextFloor,
                    "\(name)/subtle vs \(groundName) light: \(String(format: "%.2f", ratio)):1 under \(nonTextFloor):1")
            }
        }

        let textFloor: CGFloat = 4.5
        for (name, token) in [("goldText", Tokens.Color.goldText), ("emberText", Tokens.Color.emberText)] {
            for (groundName, ground) in grounds {
                let ratio = measuredRatio(token, over: ground, appearanceName: .aqua)
                #expect(ratio >= textFloor,
                    "\(name)/subtle vs \(groundName) light: \(String(format: "%.2f", ratio)):1 under \(textFloor):1")
            }
        }
    }

    // MARK: - Test B2: Increase Contrast pushes ember away from its ground

    /// Ember's Increase-Contrast variant must sit strictly further from
    /// `panel` than its base in both appearances — darker in light, lighter
    /// in dark — never drifting back toward the ground (or toward `gold`).
    /// Lives here, not in `MembershipWellContrastTests`, because it drives
    /// the process-global `test_increaseContrastOverride` seam (this file's
    /// serialization reason, above).
    @Test func emberIncreaseContrastIsStrictlyFurtherFromPanelThanBase() {
        defer { Tokens.test_increaseContrastOverride = nil }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            Tokens.test_increaseContrastOverride = false
            let base = measuredRatio(Tokens.Color.ember, over: Tokens.Color.panel, appearanceName: appearanceName)
            let baseLuminance = relativeLuminance(resolved(Tokens.Color.ember, appearanceName: appearanceName))
            Tokens.test_increaseContrastOverride = true
            let increased = measuredRatio(Tokens.Color.ember, over: Tokens.Color.panel, appearanceName: appearanceName)
            let increasedLuminance = relativeLuminance(resolved(Tokens.Color.ember, appearanceName: appearanceName))
            #expect(increased > base, Comment(rawValue: "\(appearanceName.rawValue): IC ember \(increased):1 on panel is not past base \(base):1"))
            if appearanceName == .aqua {
                #expect(increasedLuminance < baseLuminance, Comment(rawValue: "light IC ember \(increasedLuminance) is not darker than base \(baseLuminance)"))
            }
        }
    }

    // MARK: - Test D: the unlit seat vs the ring around it

    /// `socket` fills two instruments that are always RINGED — the
    /// route-armed dot on its icon corner, and a dimmed membership node inside
    /// the rail's own rim — so the pairing that decides whether it reads is
    /// seat-vs-ring, not seat-vs-ground. It carries no ground floor by design
    /// (Tokens.swift), so nothing else in this matrix measures it at all.
    ///
    /// 1.4:1 rather than a stock UI floor because both rim tones are dim
    /// companions to gold, not grounds. It is calibrated against the tone that
    /// CANNOT do this job: `railDormant`, the wire's dormancy tone, is held to
    /// 3:1 against the surfaces, and that floor lands it at 1.09:1 from dark
    /// `ember` and 1.09:1 from light `gold` — a ring with no brightness edge
    /// behind it in each appearance. Swept over appearance x Increase Contrast
    /// x dial column because both rim tones are accent-remapped and every
    /// variant moves independently; the tightest cell is Subtle dark `ember`,
    /// 2.08:1.
    @Test func dimmedNodeSeatSeparatesFromBothRimTones() {
        defer {
            Tokens.accentStyle = .fullGold
            Tokens.test_increaseContrastOverride = nil
        }
        let floor: CGFloat = 1.4

        for style in [AccentStyle.fullGold, .subtle] {
            Tokens.accentStyle = style
            for increaseContrast in [false, true] {
                Tokens.test_increaseContrastOverride = increaseContrast
                for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                    let seat = resolved(Tokens.Color.socket, appearanceName: appearanceName)
                    for (rimName, rim) in [("ember", Tokens.Color.ember), ("gold", Tokens.Color.gold)] {
                        let ratio = contrastRatio(seat, resolved(rim, appearanceName: appearanceName))
                        #expect(ratio >= floor, Comment(rawValue:
                            "socket vs \(rimName) (\(style), " +
                            "IC \(increaseContrast), \(appearanceName.rawValue)): " +
                            "\(String(format: "%.2f", ratio)):1 under \(floor):1"))
                    }
                }
            }
        }
    }

    // MARK: - Test C: accent-dial re-stamp (P1-1/P1-2 regression)

    /// Regression guard for the fix in this pass: a layer-color instrument
    /// that stamps a resolved `CGColor` onto a `CALayer` must re-stamp on
    /// `Tokens.accentStyleDidChangeNotification`, or it keeps showing the old
    /// accent until something else happens to redraw it — the live bug
    /// `AGENTS.md` rule 36 documents (the Main Audio ring kept its gold while
    /// the rail it joins had already re-tinted). `LevelMeterView` and
    /// `RouteArmedDotView` had no such observer before this pass.
    @Test func accentDialReStampsLayerColorInstrumentsLive() {
        Tokens.accentStyle = .fullGold
        defer { Tokens.accentStyle = .fullGold }

        let meter = LevelMeterView()
        let meterBefore = meter.test_gradientColors.first
        Tokens.accentStyle = .subtle
        let meterAfter = meter.test_gradientColors.first
        assertColorsDiffer(meterBefore, meterAfter,
            "LevelMeterView's gradient did not re-stamp on an accent-dial change")

        Tokens.accentStyle = .fullGold
        let dot = RouteArmedDotView()
        dot.apply(armed: true)
        let dotBefore = dot.test_fillColor
        Tokens.accentStyle = .subtle
        let dotAfter = dot.test_fillColor
        assertColorsDiffer(dotBefore, dotAfter,
            "RouteArmedDotView's fill did not re-stamp on an accent-dial change")
    }
}

} // extension SerializedSharedState
