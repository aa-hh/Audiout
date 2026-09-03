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
///  - The four `permission*` identity hues, `bluetoothBrand`, `goldCTA`, and
///    gold-on-raised across BOTH dial columns — all swept by
///    `OnboardingPermissionColorTests` (which also covers `.systemAccent`,
///    a dial column this file does not touch at all).
///  - Surface-separation floors (`well`/`panel`/`raised`/`hairline` ratios
///    against EACH OTHER) — `MembershipWellContrastTests`' job; this file
///    only uses those tokens as fixed GROUNDS for a foreground instrument.
///  - `glow`, `dotSocket`, `meterTrack`, `sidebarWarmTint`, and the surface
///    ladder itself (`canvas`/`canvasHi`/`panel`/`raised`/`well`) — each
///    documented as a floor-exempt quiet backdrop in its own Tokens.swift
///    rationale.
///  - The bare `warning`/`destructive`/`info` system-alias tokens — OS-owned
///    values, not this module's hexes to pin. KNOWN failure carried forward:
///    bare `warning` measures ~2.1:1 as a light glyph; its one TEXT consumer
///    moved to `warningText` in this pass (P1's `AudioSettingsViewController`
///    fix), and the remaining glyph consumers belong to other tracks'
///    findings — pinning an OS-owned hex here would be brittle.
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
        /// (`sameGrounds`); `ringConnected`'s own rationale only guarantees
        /// `raised` in dark (P2-4), so it needs a per-appearance list.
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

    /// Exactly one: `faderRim` on light `well` at base (non-IC) contrast —
    /// deliberately just under 3:1 so a 1 px ring "reads as a rim, not a
    /// stripe" on paper (`Tokens.swift`'s own rationale); the IC variant
    /// clears 3.32:1, which is why it is not listed here too.
    private let exceptions: [Exception] = [
        Exception(token: "faderRim", ground: "well", appearance: .aqua, icOn: false),
    ]

    @Test func everyInstrumentClearsItsFloorAcrossAppearanceAndIncreaseContrast() {
        Tokens.accentStyle = .fullGold
        defer { Tokens.test_increaseContrastOverride = nil }

        let canvas = Tokens.Color.canvas
        let panel = Tokens.Color.panel
        let raised = Tokens.Color.raised
        let well = Tokens.Color.well
        let iconSeatFill = Tokens.Color.iconSeatFill
        let feedPillFill = Tokens.Color.feedPillFill
        let scopeGround = Tokens.Color.scopeGround

        let entries: [ContrastEntry] = [
            // TEXT, floor 4.5:1
            ContrastEntry(name: "secondaryLabel", token: Tokens.Color.secondaryLabel, floor: 4.5,
                         groundsFor: sameGrounds([("canvas", canvas), ("panel", panel),
                                                  ("raised", raised), ("well", well)])),
            ContrastEntry(name: "inkSecondary", token: Tokens.Color.inkSecondary, floor: 4.5,
                         groundsFor: sameGrounds([("canvas", canvas), ("panel", panel), ("raised", raised)])),
            ContrastEntry(name: "inkTertiary", token: Tokens.Color.inkTertiary, floor: 4.5,
                         groundsFor: sameGrounds([("canvas", canvas), ("panel", panel), ("well", well),
                                                  ("iconSeatFill", iconSeatFill)])),
            ContrastEntry(name: "warningText", token: Tokens.Color.warningText, floor: 4.5,
                         groundsFor: sameGrounds([("canvas", canvas), ("panel", panel)])),
            ContrastEntry(name: "feedPillText", token: Tokens.Color.feedPillText, floor: 4.5,
                         groundsFor: sameGrounds([("feedPillFill", feedPillFill)])),
            // NON-TEXT, floor 3.0:1
            ContrastEntry(name: "success", token: Tokens.Color.success, floor: 3.0,
                         groundsFor: sameGrounds([("panel", panel), ("raised", raised)])),
            ContrastEntry(name: "failure", token: Tokens.Color.failure, floor: 3.0,
                         groundsFor: sameGrounds([("panel", panel), ("raised", raised)])),
            ContrastEntry(name: "caution", token: Tokens.Color.caution, floor: 3.0,
                         groundsFor: sameGrounds([("canvas", canvas), ("panel", panel)])),
            ContrastEntry(name: "gold", token: Tokens.Color.gold, floor: 3.0,
                         groundsFor: sameGrounds([("panel", panel), ("raised", raised), ("well", well)])),
            ContrastEntry(name: "ember", token: Tokens.Color.ember, floor: 3.0,
                         groundsFor: sameGrounds([("panel", panel), ("raised", raised), ("well", well)])),
            ContrastEntry(name: "ringConnected", token: Tokens.Color.ringConnected, floor: 3.0,
                         groundsFor: { appearance in
                             appearance == .darkAqua
                                 ? [("panel", panel), ("raised", raised)]
                                 : [("panel", panel)]
                         }),
            ContrastEntry(name: "faderThumb", token: Tokens.Color.faderThumb, floor: 3.0,
                         groundsFor: sameGrounds([("canvas", canvas), ("well", well)])),
            ContrastEntry(name: "faderRim", token: Tokens.Color.faderRim, floor: 3.0,
                         groundsFor: sameGrounds([("well", well)])),
            ContrastEntry(name: "railDormant", token: Tokens.Color.railDormant, floor: 3.0,
                         groundsFor: sameGrounds([("canvas", canvas), ("panel", panel), ("raised", raised)])),
            ContrastEntry(name: "nodeUnavailableFill", token: Tokens.Color.nodeUnavailableFill, floor: 3.0,
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
    /// Expected (own measurement, recorded for the record): light `ember`
    /// ~3.29:1 well / ~4.24:1 panel; light `gold` ~3.08:1 well / ~3.97:1
    /// panel.
    @Test func subtleColumnEmberAndGoldClearTheNonTextFloorOnWellAndPanel() {
        Tokens.accentStyle = .subtle
        defer { Tokens.accentStyle = .fullGold }
        let floor: CGFloat = 3.0
        let well = Tokens.Color.well
        let panel = Tokens.Color.panel

        for (name, token) in [("ember", Tokens.Color.ember), ("gold", Tokens.Color.gold)] {
            for (groundName, ground) in [("well", well), ("panel", panel)] {
                let ratio = measuredRatio(token, over: ground, appearanceName: .aqua)
                #expect(ratio >= floor,
                    "\(name)/subtle vs \(groundName) light: \(String(format: "%.2f", ratio)):1 under \(floor):1")
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

    // MARK: - Test C0: the unavailable node's fill stays tellable from its rim

    /// A dimmed membership node keeps its rim in the rail's own tone and swaps
    /// ONLY its disc fill, so the fill-against-rim difference is the entire
    /// "this speaker is unavailable" signal. At 13 pt that reading rides on
    /// the luminance channel: a grey that differs from `gold` in chroma alone
    /// reports nothing at a glance. The fill is its own token rather than
    /// `railDormant` because that value is also the dormant WIRE, which has to
    /// stay QUIET in light while this disc has to go deep. Swept over
    /// appearance x Increase Contrast because both move the rim as well as
    /// the fill — and it lives in this file rather than
    /// `MembershipWellContrastTests` for the IC seam, the same serialization
    /// reason the rest of this suite has.
    ///
    /// `ember` is asserted in LIGHT only. Dark `ember` sits at luminance
    /// 0.159 while the >=3:1 floor on `raised` forbids any fill below 0.143,
    /// so the band beneath it is 1.08:1 wide and nothing clears it — the full
    /// arithmetic, and why the gold gap keeps the budget instead, is on the
    /// token.
    @Test func unavailableNodeFillStaysTellableFromItsRim() {
        Tokens.accentStyle = .fullGold
        defer { Tokens.test_increaseContrastOverride = nil }
        let goldFloor: CGFloat = 2.0
        let emberFloor: CGFloat = 1.45

        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            for icOn in [false, true] {
                Tokens.test_increaseContrastOverride = icOn
                let fill = resolved(Tokens.Color.nodeUnavailableFill, appearanceName: appearance)

                let goldGap = contrastRatio(fill, resolved(Tokens.Color.gold, appearanceName: appearance))
                #expect(goldGap >= goldFloor,
                        Comment(rawValue: "unavailable fill vs its gold rim (\(appearance.rawValue) " +
                        "ic=\(icOn)): \(String(format: "%.2f", goldGap)):1 under \(goldFloor):1 — an " +
                        "unavailable disc and a live one are then the same brightness"))

                #expect(fill.saturationComponent <= 0.25,
                        Comment(rawValue: "unavailable fill saturation \(fill.saturationComponent) " +
                        "(\(appearance.rawValue) ic=\(icOn)) — it must stay a neutral, not become a " +
                        "third instrument hue"))

                guard appearance == .aqua else { continue }
                let emberGap = contrastRatio(fill, resolved(Tokens.Color.ember, appearanceName: appearance))
                #expect(emberGap >= emberFloor,
                        Comment(rawValue: "unavailable fill vs its ember rim (light ic=\(icOn)): " +
                        "\(String(format: "%.2f", emberGap)):1 under \(emberFloor):1"))
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
