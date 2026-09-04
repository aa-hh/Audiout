// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutSharedUI

/// Contrast audit (2026-09-04), finding class "no test measures one token
/// composited on another". Every contrast defect found that day came out of
/// this gap: the Equalizer door's active mark measured dimmer than its own
/// at-rest state, failure red set as body text on a washed row, and the
/// alignment wizard's stage bezel getting WORSE under Increase Contrast. The
/// existing suites all measure a token against a token. This one measures a
/// foreground against the ground it is ACTUALLY drawn on, including grounds
/// that only exist as a composite:
///
///  - a wash over another ground (a device row's gold live wash and its
///    neutral hover wash, the Groups card's live wash, a banner's tinted
///    plate),
///  - a colour pinned to one appearance drawn on a surface that resolves in
///    the other (the Equalizer seat's border, the alignment wizard's primary
///    plate).
///
/// TWO assertions per pair, not one. The first is the floor — 4.5:1 for text,
/// 3:1 for a graphical mark or an edge. The second is that **Increase Contrast
/// never LOWERS the ratio**, which is the assertion that actually catches this
/// class: a composite has two halves, and lifting only the half that carries
/// an Increase Contrast variant can move the pair the wrong way.
///
/// Nested into `SerializedSharedState` (see `SerializedSharedStateSuite.swift`)
/// for the same reason `TokenContrastMatrixTests` is: this file drives the
/// process-global `Tokens.test_increaseContrastOverride` seam, and running
/// concurrently with another suite doing the same is a real, reproducible race.
///
/// DELIBERATE EXCLUSIONS — pairs this file does NOT measure, and why:
///  - Anything `TokenContrastMatrixTests` already sweeps, including the mute
///    pill on both row washes and `inkOnFill` on `gold`. That file owns the
///    token-on-token matrix; this one only adds composites it does not carry.
///  - Surface-separation floors — `MembershipWellContrastTests`' job.
///  - The stage plate's own instruments — `AlignmentTokenContrastTests`' job.
///  - Composites whose alpha or blend fraction is `private` to a drawing file
///    (`WarmFaderCell.armedDimEndGoldBlend`, `AlignmentPlateCell`'s rim and
///    chip alphas, `BTAlignmentWizardView.lightRimAlpha`, `AlignmentStageView`'s
///    bezel alphas). Measuring those here means re-typing a number that lives
///    somewhere else, which drifts silently the first time someone re-tunes it.
///    Every alpha used below is read live from `PopoverColumnGrid`, the shared
///    public grid the drawing code itself reads.
@MainActor
extension SerializedSharedState {

@Suite final class CompositedTokenContrastTests: IsolatedSuite {

    deinit {
        // Process-global test seam; restore it unconditionally so no other
        // test in the process inherits a forced Increase-Contrast reading.
        Tokens.test_increaseContrastOverride = nil
    }

    // MARK: - Ported helpers (see `TokenContrastMatrixTests` for provenance)

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

    /// Alpha-composite `fg` over `bg` when `fg` isn't fully opaque, and hand
    /// back an OPAQUE colour. This is the whole point of the file: every
    /// wash below is built by handing a translucent token to this and using
    /// the result as the next thing's ground.
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

    // MARK: - The composited grounds the app actually draws

    /// A device row's ground. The popover mounts every `DeviceRowView` on
    /// `PopoverPanelViewController`'s `WarmPanelView`, which fills `panel`
    /// (`PopoverPanelViewController.swift:230`); `CardView` between them
    /// paints nothing at all (`CardView.swift:79-84`). The Groups screen
    /// mounts no device rows.
    private func rowGround(_ appearanceName: NSAppearance.Name) -> NSColor {
        resolved(Tokens.Color.panel, appearanceName: appearanceName)
    }

    /// The gold wash behind a SOUNDING row, exactly as
    /// `DeviceRowView.draw(_:)` builds it (`DeviceRowView.swift:3095-3097`).
    private func liveWash(over base: NSColor, _ appearanceName: NSAppearance.Name) -> NSColor {
        composited(resolved(Tokens.Color.gold, appearanceName: appearanceName)
                    .withAlphaComponent(PopoverColumnGrid.rowLiveWashAlpha), over: base)
    }

    /// The neutral pointer-hover wash (`DeviceRowView.swift:3098-3100`).
    /// `engagedChrome` is `label`, so this is black or white at the grid's
    /// hover alpha depending on the appearance.
    private func hoverWash(over base: NSColor, _ appearanceName: NSAppearance.Name) -> NSColor {
        composited(resolved(Tokens.Color.engagedChrome, appearanceName: appearanceName)
                    .withAlphaComponent(PopoverColumnGrid.rowHoverWashAlpha), over: base)
    }

    /// A banner's tinted plate: the tier's own token at 12 % over the surface
    /// ground (`SilenceFallbackBannerView.swift:129`,
    /// `SystemAirPlayNoteBannerView.swift:183-185`).
    private func bannerTint(_ tint: NSColor, _ appearanceName: NSAppearance.Name) -> NSColor {
        composited(resolved(tint, appearanceName: appearanceName)
                    .withAlphaComponent(Self.bannerTintAlpha),
                   over: rowGround(appearanceName))
    }

    /// The banner tint alpha. Both banners hard-code 0.12 at their own call
    /// site rather than reading a shared constant, so this is the one number
    /// in the file that is re-typed; it is asserted against nothing else and
    /// exists only to build the ground.
    private static let bannerTintAlpha: CGFloat = 0.12

    // MARK: - The pairs

    /// One foreground measured on one ground, both resolved inside the cell
    /// being swept so that appearance and Increase Contrast reach every token
    /// on both sides of the pair.
    private struct CompositePair {
        let name: String
        /// 4.5:1 where the foreground sets words, 3:1 where it is a graphical
        /// mark or an edge.
        let floor: CGFloat
        let foreground: (NSAppearance.Name) -> NSColor
        let ground: (NSAppearance.Name) -> NSColor
        /// False only where the foreground is `NSColor.labelColor`, whose
        /// Increase Contrast rendering AppKit owns rather than this palette —
        /// asserting a direction there would be pinning someone else's
        /// decision. The floor still applies.
        var checksIncreaseContrastDirection: Bool = true
    }

    /// Pairs where Increase Contrast LOWERS the ratio on purpose, with the
    /// mechanism on file. Both are the same shape: a value pinned to one
    /// appearance sits on a ground that resolves in the other, so Increase
    /// Contrast lifts one half of the pair and not the other. Each still
    /// clears its floor, and the floor assertion below is what holds them.
    ///
    /// The list is self-cleaning: the direction assertion runs in REVERSE for
    /// anything listed, so a re-tune that makes Increase Contrast help again
    /// fails loudly instead of leaving a stale entry here forever.
    private struct IncreaseContrastDrop: Equatable {
        let pair: String
        let appearance: NSAppearance.Name
    }

    private let increaseContrastDrops: [IncreaseContrastDrop] = [
        // The seat's border resolves `inkOnFill` under DARK whatever the row's
        // own appearance is (`DeviceRowView.swift:1017-1024`), so it cannot
        // move; the gold under it brightens with Increase Contrast, closing
        // the gap. 4.94:1 down to 3.57:1 — still clear of the 3:1 edge floor.
        IncreaseContrastDrop(pair: "Equalizer seat border on its gold seat", appearance: .aqua),
    ]

    private func pairs() -> [CompositePair] {
        [
            // MARK: A device row's WASHED grounds
            //
            // Each foreground below is listed against the wash a row can
            // ACTUALLY put behind it. A sounding row wears the gold wash and a
            // hovered row the neutral one, and `draw(_:)` checks `isRouteArmed`
            // FIRST — so a sounding row never also shows the hover wash, and
            // any ink that only appears while a row is silent never sits on
            // the gold one. Pairs that combination cannot produce are left out
            // rather than measured.

            // The subordinate sublabel on a sounding row
            // (`DeviceRowView.swift:1119`, armed branch).
            CompositePair(name: "label2 on the row's live wash", floor: 4.5,
                          foreground: { self.resolved(Tokens.Color.label2, appearanceName: $0) },
                          ground: { self.liveWash(over: self.rowGround($0), $0) }),
            // The same ink on a hovered row — it is also the row's icon tint
            // and its at-rest Equalizer glyph (`DeviceRowView.swift:596`, `:1005`).
            CompositePair(name: "label2 on the row's hover wash", floor: 4.5,
                          foreground: { self.resolved(Tokens.Color.label2, appearanceName: $0) },
                          ground: { self.hoverWash(over: self.rowGround($0), $0) }),
            // A silent row's NAME (`DeviceRowView.swift:2270`, unarmed branch).
            CompositePair(name: "labelCool on the row's hover wash", floor: 4.5,
                          foreground: { self.resolved(Tokens.Color.labelCool, appearanceName: $0) },
                          ground: { self.hoverWash(over: self.rowGround($0), $0) }),
            // A sounding row's NAME (`DeviceRowView.swift:2270`, armed branch).
            // `label` is `NSColor.labelColor`, hence no direction assertion.
            CompositePair(name: "label on the row's live wash", floor: 4.5,
                          foreground: { self.resolved(Tokens.Color.label, appearanceName: $0) },
                          ground: { self.liveWash(over: self.rowGround($0), $0) },
                          checksIncreaseContrastDirection: false),
            // The `%` readout while the row is sounding
            // (`DeviceRowView.swift:736`).
            CompositePair(name: "goldText readout on the row's live wash", floor: 4.5,
                          foreground: { self.resolved(Tokens.Color.goldText, appearanceName: $0) },
                          ground: { self.liveWash(over: self.rowGround($0), $0) }),
            // The Equalizer door's ACTIVE mark: an opaque gold seat
            // (`DeviceRowView.swift:1011`). This is the pairing the original
            // defect hid in — the mark was never measured against a wash, only
            // against the flat surfaces.
            CompositePair(name: "Equalizer gold seat on the row's live wash", floor: 3.0,
                          foreground: { self.resolved(Tokens.Color.gold, appearanceName: $0) },
                          ground: { self.liveWash(over: self.rowGround($0), $0) }),
            // A FEED pill's load-bearing edge, measured on its OUTER side —
            // the wash, not the pill's own `well` fill
            // (`FeedPillView.swift:148`, fill and edge stamped together).
            CompositePair(name: "feed pill rim on the row's live wash", floor: 3.0,
                          foreground: { self.resolved(Tokens.Color.rim, appearanceName: $0) },
                          ground: { self.liveWash(over: self.rowGround($0), $0) }),
            // The pill's fill is OPAQUE `well`, so the wash never reaches the
            // text inside it — the pill's own fill is the ground for every
            // word in the FEED column, error pills included
            // (`DeviceRowView.swift:1247`).
            CompositePair(name: "failure pill text on the pill's well fill", floor: 4.5,
                          foreground: { self.resolved(Tokens.Color.failure, appearanceName: $0) },
                          ground: { self.resolved(Tokens.Color.well, appearanceName: $0) }),

            // MARK: The Groups overview's live CARD
            //
            // The same 12 % gold wash, over `raised` instead of `panel`
            // (`GroupsOverviewViewController.swift:788-793`). Its meta line
            // reads `label2` while live and `labelCool2` while not, so only
            // the live inks are measured on the washed ground.
            CompositePair(name: "label2 on the Groups card's live wash", floor: 4.5,
                          foreground: { self.resolved(Tokens.Color.label2, appearanceName: $0) },
                          ground: { self.liveWash(over: self.resolved(Tokens.Color.raised, appearanceName: $0), $0) }),
            CompositePair(name: "goldText on the Groups card's live wash", floor: 4.5,
                          foreground: { self.resolved(Tokens.Color.goldText, appearanceName: $0) },
                          ground: { self.liveWash(over: self.resolved(Tokens.Color.raised, appearanceName: $0), $0) }),

            // MARK: A banner's TINTED plate
            //
            // Both banners fill their plate with the tier's own token at 12 %
            // and then draw that same token's glyph on top of it — a token on
            // a wash of itself, which nothing measured.
            CompositePair(name: "failure glyph on the failure banner's tint", floor: 3.0,
                          foreground: { self.resolved(Tokens.Color.failure, appearanceName: $0) },
                          ground: { self.bannerTint(Tokens.Color.failure, $0) }),
            CompositePair(name: "banner copy on the failure banner's tint", floor: 4.5,
                          foreground: { self.resolved(Tokens.Color.label, appearanceName: $0) },
                          ground: { self.bannerTint(Tokens.Color.failure, $0) },
                          checksIncreaseContrastDirection: false),
            CompositePair(name: "ring glyph on the note banner's tint", floor: 3.0,
                          foreground: { self.resolved(Tokens.Color.ring, appearanceName: $0) },
                          ground: { self.bannerTint(Tokens.Color.ring, $0) }),
            CompositePair(name: "banner copy on the note banner's tint", floor: 4.5,
                          foreground: { self.resolved(Tokens.Color.label, appearanceName: $0) },
                          ground: { self.bannerTint(Tokens.Color.ring, $0) },
                          checksIncreaseContrastDirection: false),

            // MARK: A colour PINNED to one appearance, on a surface that is not
            //
            // The Equalizer seat's border resolves `inkOnFill` under
            // `.darkAqua` whatever the row's appearance is, because that token
            // turns white under light + Increase Contrast and a white outline
            // on the light canvas is no outline at all
            // (`DeviceRowView.swift:1017-1024`). The gold under it is NOT
            // pinned, so the two halves move independently — the mechanism
            // that broke the wizard's stage bezel, measured here where it
            // still holds.
            CompositePair(name: "Equalizer seat border on its gold seat", floor: 3.0,
                          foreground: { _ in self.resolved(Tokens.Color.inkOnFill, appearanceName: .darkAqua) },
                          ground: { self.resolved(Tokens.Color.gold, appearanceName: $0) }),
            // The alignment wizard's primary plate pins BOTH halves under
            // `.darkAqua` (`AlignmentPlateCell.swift:252-271`), which is what
            // makes it survive light + Increase Contrast. Measured in all four
            // cells so a future un-pinning of either half shows up here.
            CompositePair(name: "primary plate ink on its pinned gold", floor: 4.5,
                          foreground: { _ in self.resolved(Tokens.Color.inkOnFill, appearanceName: .darkAqua) },
                          ground: { _ in self.resolved(Tokens.Color.gold, appearanceName: .darkAqua) }),
        ]
    }

    // MARK: - Test A: every pair clears its floor in all four cells

    @Test func everyCompositedPairClearsItsFloorAcrossAppearanceAndIncreaseContrast() {
        defer { Tokens.test_increaseContrastOverride = nil }

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for increaseContrast in [false, true] {
                Tokens.test_increaseContrastOverride = increaseContrast
                for pair in pairs() {
                    let ground = pair.ground(appearanceName)
                    let foreground = composited(pair.foreground(appearanceName), over: ground)
                    let ratio = contrastRatio(foreground, ground)
                    let cell = "\(appearanceName.rawValue) ic=\(increaseContrast)"
                    let reason = pair.floor >= 4.5
                        ? "it sets words, so it carries the 4.5:1 body floor"
                        : "it is a graphical mark or an edge, so it carries the 3:1 floor"
                    #expect(ratio >= pair.floor, Comment(rawValue:
                        "\(pair.name) — \(cell): \(String(format: "%.2f", ratio)):1 " +
                        "under \(pair.floor):1. Measured on the composited ground the app " +
                        "actually draws, not on a bare token; \(reason)."))
                }
            }
        }
    }

    // MARK: - Test B: Increase Contrast never lowers a composited ratio

    /// The assertion that catches this class of bug. A composite has two
    /// halves and Increase Contrast reaches whichever of them carries a
    /// variant — so lifting the ground while the foreground stands still (or
    /// the reverse) moves the pair the WRONG way, and no floor check on its
    /// own notices until the ratio has already crossed under. The wizard's
    /// stage bezel went 3.47:1 to 2.89:1 exactly this way.
    @Test func increaseContrastNeverLowersACompositedRatio() {
        defer { Tokens.test_increaseContrastOverride = nil }

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for pair in pairs() where pair.checksIncreaseContrastDirection {
                Tokens.test_increaseContrastOverride = false
                let baseGround = pair.ground(appearanceName)
                let base = contrastRatio(composited(pair.foreground(appearanceName), over: baseGround),
                                         baseGround)

                Tokens.test_increaseContrastOverride = true
                let raisedGround = pair.ground(appearanceName)
                let raised = contrastRatio(composited(pair.foreground(appearanceName), over: raisedGround),
                                           raisedGround)

                let baseText = String(format: "%.2f", base)
                let raisedText = String(format: "%.2f", raised)
                let isKnownDrop = increaseContrastDrops.contains(
                    IncreaseContrastDrop(pair: pair.name, appearance: appearanceName))
                if isKnownDrop {
                    #expect(raised < base, Comment(rawValue:
                        "listed Increase-Contrast drop \(pair.name)/\(appearanceName.rawValue) " +
                        "no longer drops (\(baseText):1 to \(raisedText):1) — remove it from " +
                        "`increaseContrastDrops`"))
                } else {
                    #expect(raised >= base, Comment(rawValue:
                        "\(pair.name) — \(appearanceName.rawValue): Increase Contrast LOWERS " +
                        "the ratio, \(baseText):1 to \(raisedText):1. One half of this " +
                        "composite carries an Increase Contrast variant and the other does " +
                        "not, so the mode meant to help is moving the pair toward its floor."))
                }
            }
        }
    }
}

} // extension SerializedSharedState
