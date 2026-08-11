// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterOnboardingUI
@testable import AudiouterSharedUI

/// T3 (colour-return pass, decisions Q1-Q6/NEW-1): the four permission-row
/// identity tokens — `Tokens.Color.permissionSystemAudio` / `permissionLocalNetwork`
/// / `permissionRemoteControl` / `permissionSpeakerSync` — stay mutually
/// DISTINCT in both accent-dial columns (Q1), each clears the same >=3:1
/// own-theme contrast floor every other `Tokens.Color` instrument is held to
/// (T1's written arithmetic, exercised here), the accent dial genuinely MUTES
/// all four in `.subtle` (Q5) while `.systemAccent` leaves them at their
/// authored Full-gold hues and STILL mutually distinct (NEW-1 — the explicit
/// guard against a later regression routing them through `accentDynamic`,
/// which would collapse all four onto the same live-accent-derived value),
/// and the glyph-only decision (Q3) holds end to end: the tile's own FILL
/// never recolours, and each card's glyph keeps its identity hue in every
/// `SetupCardState`.
///
/// Two helpers are ported rather than shared (so those suites stay untouched):
///  - `relativeLuminance`/`contrastRatio` — ported from `AppTetherColorTests`.
///  - `resolved(_:appearanceName:)` — ported from `SettingsAccentAndHintsTests`.
/// `SettingsAccentAndHintsTests.accentDialNeverRemapsFailureCautionOrRing`
/// names `failure`/`caution`/`ringConnected` explicitly — not "every token the
/// dial doesn't touch" — so these four permission tokens (which the dial DOES
/// remap, just not via `accentDynamic`) don't trip it.
///
/// Nested into `SerializedSharedState` alongside `SettingsAccentAndHintsTests`
/// — both mutate the process-global `Tokens.accentStyle` (see the `deinit`
/// below), and running concurrently under swift-testing produced real,
/// reproducible test failures (a concurrent accent-style write racing this
/// suite's color comparisons).
extension SerializedSharedState {

@MainActor
@Suite final class OnboardingPermissionColorTests: IsolatedSuite {

    deinit {
        // `Tokens.accentStyle` is process-global (the live remap seam) —
        // restore the flagship default so no other test in this suite, or a
        // later golden render in this process, inherits a dialed accent.
        // Same discipline as `SettingsAccentAndHintsTests.tearDown`.
        Tokens.accentStyle = .fullGold
    }

    // MARK: - Ported helpers (see file doc comment for provenance)

    /// Resolve `color` to concrete sRGB under an explicit appearance — the
    /// same way AppKit resolves a dynamic provider at draw time. Ported from
    /// `SettingsAccentAndHintsTests` (~lines 89-96).
    private func resolved(_ color: NSColor, appearanceName: NSAppearance.Name) -> NSColor {
        var result = color
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    /// WCAG 2.x relative luminance of an sRGB color. Ported from
    /// `AppTetherColorTests` (~lines 293-300).
    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let c = color.usingColorSpace(.sRGB)!
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    /// WCAG contrast ratio between two sRGB colors, `1...21`. Ported from
    /// `AppTetherColorTests` (~lines 302-307).
    private func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let l1 = relativeLuminance(a), l2 = relativeLuminance(b)
        let (hi, lo) = l1 > l2 ? (l1, l2) : (l2, l1)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Component-wise sRGB comparison with tolerance — the
    /// `ControlPanelBackingViewTests.assertSameHue` idiom, needed here
    /// because comparing two independently-resolved dynamic `NSColor`
    /// instances (or a `layer.backgroundColor`-reconstructed color against a
    /// resolved token) via plain equality is not reliable once either
    /// side has been round-tripped through `CGColor`.
    private func assertSameRGB(_ a: NSColor?, _ b: NSColor?, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else {
            Issue.record("nil or non-convertible color: \(message)")
            return
        }
        #expect(abs(a.redComponent - b.redComponent) <= 0.02, "red: \(message)")
        #expect(abs(a.greenComponent - b.greenComponent) <= 0.02, "green: \(message)")
        #expect(abs(a.blueComponent - b.blueComponent) <= 0.02, "blue: \(message)")
    }

    /// The four permission tokens, named for failure messages. A computed
    /// property (not a stored snapshot) so every call site gets a fresh
    /// access — irrelevant for correctness (each dynamic `NSColor`'s
    /// provider closure re-reads `Tokens.accentStyle` at RESOLUTION time
    /// regardless of when the handle was obtained) but keeps call sites
    /// honest about there being no caching here.
    private var permissionTokens: [(name: String, color: NSColor)] {
        [("permissionSystemAudio", Tokens.Color.permissionSystemAudio),
         ("permissionLocalNetwork", Tokens.Color.permissionLocalNetwork),
         ("permissionRemoteControl", Tokens.Color.permissionRemoteControl),
         ("permissionSpeakerSync", Tokens.Color.permissionSpeakerSync)]
    }

    private func assertMutuallyDistinct(appearance: NSAppearance.Name,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let tokens = permissionTokens.map { (name: $0.name, color: resolved($0.color, appearanceName: appearance)) }
        for i in 0..<tokens.count {
            for j in (i + 1)..<tokens.count {
                #expect(tokens[i].color != tokens[j].color,
                        "\(tokens[i].name) collapsed onto \(tokens[j].name) under \(Tokens.accentStyle)/\(appearance.rawValue)")
            }
        }
    }

    // MARK: 1 — Distinctness in both dial columns (Q1)

    @Test func fourTokensAreMutuallyDistinctInFullGold() {
        Tokens.accentStyle = .fullGold
        assertMutuallyDistinct(appearance: .darkAqua)
        assertMutuallyDistinct(appearance: .aqua)
    }

    @Test func fourTokensAreMutuallyDistinctInSubtle() {
        Tokens.accentStyle = .subtle
        assertMutuallyDistinct(appearance: .darkAqua)
        assertMutuallyDistinct(appearance: .aqua)
    }

    // MARK: 2 — >=3:1 own-theme contrast floor, both dial columns, both appearances

    /// Checked against BOTH `panel` and `raised` (the two own-theme surfaces
    /// T1's doc comments measure against for every one of these four
    /// tokens), across `.fullGold`/`.subtle` and `.darkAqua`/`.aqua` — the
    /// full 4 tokens x 2 columns x 2 appearances x 2 surfaces sweep.
    @Test func contrastFloorClearsInBothDialColumnsBothAppearancesBothSurfaces() {
        let floor: CGFloat = 3.0
        for style: AccentStyle in [.fullGold, .subtle] {
            Tokens.accentStyle = style
            for appearance: NSAppearance.Name in [.darkAqua, .aqua] {
                let panel = resolved(Tokens.Color.panel, appearanceName: appearance)
                let raised = resolved(Tokens.Color.raised, appearanceName: appearance)
                for (name, color) in permissionTokens {
                    let resolvedColor = resolved(color, appearanceName: appearance)
                    let panelRatio = contrastRatio(resolvedColor, panel)
                    let raisedRatio = contrastRatio(resolvedColor, raised)
                    #expect(panelRatio >= floor,
                        "\(name) \(style)/\(appearance.rawValue) vs panel: \(panelRatio):1 under the \(floor):1 floor")
                    #expect(raisedRatio >= floor,
                        "\(name) \(style)/\(appearance.rawValue) vs raised: \(raisedRatio):1 under the \(floor):1 floor")
                }
            }
        }
    }

    // MARK: 3 — the dial genuinely mutes all four in .subtle (Q5)

    @Test func subtleActuallyChangesAllFourFromFullGold() {
        for appearance: NSAppearance.Name in [.darkAqua, .aqua] {
            Tokens.accentStyle = .fullGold
            let full = permissionTokens.map { (name: $0.name, color: resolved($0.color, appearanceName: appearance)) }

            Tokens.accentStyle = .subtle
            let subtle = permissionTokens.map { (name: $0.name, color: resolved($0.color, appearanceName: appearance)) }

            for (fullEntry, subtleEntry) in zip(full, subtle) {
                #expect(fullEntry.color != subtleEntry.color,
                    "\(fullEntry.name)/\(appearance.rawValue): .subtle failed to change the resolved colour from .fullGold — Q5 requires the dial to genuinely mute these four")
            }
        }
    }

    // MARK: 4 — .systemAccent stays at the Full-gold hues AND stays distinct (NEW-1)

    /// The executable guard against a later regression routing these four
    /// through `accentDynamic`'s `.systemAccent` branch (which resolves
    /// `controlAccentColor` scaled by a constant — a value that depends on
    /// the LIVE SYSTEM ACCENT, not on which token asked for it, so all four
    /// would silently collapse onto the same hue the moment a user picks
    /// Follow System).
    @Test func systemAccentStaysAtFullGoldValuesAndStaysDistinct() {
        for appearance: NSAppearance.Name in [.darkAqua, .aqua] {
            Tokens.accentStyle = .fullGold
            let full = permissionTokens.map { (name: $0.name, color: resolved($0.color, appearanceName: appearance)) }

            Tokens.accentStyle = .systemAccent
            let systemAccent = permissionTokens.map { (name: $0.name, color: resolved($0.color, appearanceName: appearance)) }

            for (fullEntry, systemEntry) in zip(full, systemAccent) {
                #expect(fullEntry.color == systemEntry.color,
                    "\(fullEntry.name)/\(appearance.rawValue): .systemAccent must resolve the authored Full column unchanged (NEW-1) — it must NOT remap to the live system accent")
            }
        }

        // Still mutually distinct under .systemAccent (currently the active
        // style from the loop above, both appearances re-checked explicitly).
        Tokens.accentStyle = .systemAccent
        assertMutuallyDistinct(appearance: .darkAqua)
        assertMutuallyDistinct(appearance: .aqua)
    }

    // MARK: 5/6 — the glyph tint is PERMANENT; the tile fill never recolours (Q2/Q3)

    /// Forces a layer-backed, off-window tile through one real display pass:
    /// `updateLayer()` (which paints `test_fillColor`) only runs on an actual
    /// draw, and a freshly constructed view has never been asked to draw.
    /// Pinning `.appearance` first makes the dynamic tokens it paints resolve
    /// deterministically off-window — the same combination
    /// `ControlPanelBackingViewTests`/`WarmFaderCellTests` pin `.appearance`
    /// for, and `AccessibilitySignalSweepTests`'s
    /// `warmCanvasRepaintsOnDisplayOptionsChange` uses
    /// `layer?.displayIfNeeded()` for on an off-window layer-backed view.
    private func settle(_ tile: IconTileView, appearance: NSAppearance.Name) {
        tile.appearance = NSAppearance(named: appearance)
        tile.layoutSubtreeIfNeeded()
        tile.layer?.displayIfNeeded()
    }

    /// The card's glyph tint is its step's identity hue in EVERY
    /// `SetupCardState` — state is carried by the checkmark/lock slot alone.
    /// Driven through the real `SetupCardView.apply(...)`, the same call the
    /// view controller makes, because the tile itself is private to the card.
    @Test func glyphTintIsPermanentAcrossEveryCardState() {
        let states: [SetupCardState] = [.pending, .active, .completed,
                                        .autoPassed(note: "Requires macOS 14.2 or later"),
                                        .skipped]
        for appearance: NSAppearance.Name in [.darkAqua, .aqua] {
            for step in SetupStep.allCases {
                let content = OnboardingViewController.content(for: step)
                let card = SetupCardView(content: content, onAllow: {}, onSkip: {})
                let expected = resolved(content.iconColor, appearanceName: appearance)
                for state in states {
                    card.apply(state, foundSpeakers: nil, isProbing: false,
                               offersSettingsFallback: false, animated: false)
                    assertSameRGB(resolved(card.test_iconTint ?? .clear, appearanceName: appearance), expected,
                        "\(step)/\(state)/\(appearance.rawValue): the glyph tint must stay the card's own iconColor in every state")
                }
            }
        }
    }

    /// Q3, unchanged: the tile's own FILL is the neutral `raised` well — only
    /// the glyph ever carries a permission's colour.
    @Test func tileFillIsAlwaysTheNeutralRaisedWell() {
        for appearance: NSAppearance.Name in [.darkAqua, .aqua] {
            for (name, color) in permissionTokens {
                let tile = IconTileView(symbolName: "waveform", accessibility: name, color: color)
                settle(tile, appearance: appearance)

                assertSameRGB(tile.test_fillColor, resolved(Tokens.Color.raised, appearanceName: appearance),
                             "\(name)/\(appearance.rawValue): tile fill must be the neutral `raised` well")
                // The glyph keeps the caller's token — a dynamic (unresolved)
                // `NSColor`, so it must go through `resolved(_:appearanceName:)`
                // explicitly before `assertSameRGB` resolves it against the
                // process's ambient appearance instead of the one under test.
                assertSameRGB(resolved(tile.test_restingTint ?? .clear, appearanceName: appearance),
                             resolved(color, appearanceName: appearance),
                             "\(name)/\(appearance.rawValue): the glyph tint must be this row's own token")
            }
        }
    }
}

} // extension SerializedSharedState
