// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
import AudioutCore
@testable import AudioutSharedUI

/// The engaged mute state's two carriers — the FILLED
/// ``RowAccessorySymbol/muteEngaged`` square and the reserved
/// ``Tokens/Color/muted`` hue inside it — asserted as DRAWN, in all four
/// appearances (light/dark x Increase Contrast), plus the fence that keeps
/// the hue to its two consumers.
///
/// Every colour assertion here reads the button's RENDERED pixels
/// (``DeviceRowView/test_muteDrawnInks``) rather than a `contentTintColor` the
/// row just set. The palette is baked into the image now, so the tint property
/// no longer carries the state at all — and a palette handed to the wrong
/// layer would read back correctly from the configuration while painting a
/// white square with coloured marks.
///
/// Nested into `SerializedSharedState` because every test here drives the
/// process-global `Tokens.test_increaseContrastOverride` seam, the same reason
/// `TokenContrastMatrixTests` is nested.
@MainActor
extension SerializedSharedState {

@Suite final class DeviceRowMutedStateTests: IsolatedSuite {

    deinit { Tokens.test_increaseContrastOverride = nil }

    private func makeDevice(isMuted: Bool) -> Device {
        Device(id: "dev-1", name: "Test Speaker", kind: .homePod,
               isAvailable: true, isMuted: isMuted, connectionState: .connected)
    }

    /// A row settled into one of the four appearance cells. `apply` runs AFTER
    /// the appearance is set, so the symbol's palette is resolved under it
    /// whether or not a detached view gets `viewDidChangeEffectiveAppearance`.
    private func makeRow(muted: Bool, appearanceName: NSAppearance.Name,
                         increaseContrast: Bool) -> DeviceRowView {
        Tokens.test_increaseContrastOverride = increaseContrast
        let row = DeviceRowView(device: makeDevice(isMuted: muted))
        row.appearance = NSAppearance(named: appearanceName)
        row.apply(makeDevice(isMuted: muted), selected: true, controllable: true)
        return row
    }

    private let cells: [(NSAppearance.Name, Bool)] = [
        (.aqua, false), (.aqua, true), (.darkAqua, false), (.darkAqua, true),
    ]

    private func describe(_ appearanceName: NSAppearance.Name, _ increaseContrast: Bool) -> String {
        "\(appearanceName.rawValue) increaseContrast=\(increaseContrast)"
    }

    /// `token` as it resolves in `appearanceName` — the value the row bakes
    /// into the symbol's palette, and so the value that must come back out of
    /// the pixels.
    private func resolved(_ token: NSColor, _ appearanceName: NSAppearance.Name) -> NSColor {
        var out = token
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            out = token.usingColorSpace(.sRGB) ?? token
        }
        return out
    }

    private func contains(_ inks: [NSColor], _ wanted: NSColor) -> Bool {
        guard let wanted = wanted.usingColorSpace(.sRGB) else { return false }
        return inks.contains { ink in
            guard let ink = ink.usingColorSpace(.sRGB) else { return false }
            return abs(ink.redComponent - wanted.redComponent) < 0.02
                && abs(ink.greenComponent - wanted.greenComponent) < 0.02
                && abs(ink.blueComponent - wanted.blueComponent) < 0.02
        }
    }

    // MARK: The muted row

    @Test func mutedRowDrawsTheFilledSquareInEveryAppearance() {
        defer { Tokens.test_increaseContrastOverride = nil }
        for (appearanceName, ic) in cells {
            let row = makeRow(muted: true, appearanceName: appearanceName, increaseContrast: ic)
            #expect(row.test_mutePillIsMutedHue,
                    "\(describe(appearanceName, ic)): muted must draw the filled square")
            #expect(!row.test_muteDrawsRestSymbol,
                    "\(describe(appearanceName, ic)): muted must not keep the outline square")
        }
    }

    /// The engaged square is `muted` with WHITE marks knocked out of it, and
    /// both have to come back out of the rendered pixels.
    @Test func mutedRowPaintsTheReservedHueAndWhiteMarksInEveryAppearance() {
        defer { Tokens.test_increaseContrastOverride = nil }
        for (appearanceName, ic) in cells {
            let row = makeRow(muted: true, appearanceName: appearanceName, increaseContrast: ic)
            #expect(row.test_isMutePillEngaged, "\(describe(appearanceName, ic)): no fill drawn")
            let inks = row.test_muteDrawnInks
            #expect(contains(inks, resolved(Tokens.Color.muted, appearanceName)),
                    "\(describe(appearanceName, ic)): the square is not the muted hue — drew \(inks)")
            #expect(contains(inks, .white),
                    "\(describe(appearanceName, ic)): the marks are not white — drew \(inks)")
        }
    }

    /// The single-value rule (Alec, 2026-09-04): an engaged control wears the
    /// SAME fill in light and dark. A future re-tune that splits the hue by
    /// appearance fails here rather than shipping.
    @Test func theEngagedFillIsOneValueInBothAppearances() {
        defer { Tokens.test_increaseContrastOverride = nil }
        Tokens.test_increaseContrastOverride = false
        #expect(contains([resolved(Tokens.Color.muted, .aqua)],
                         resolved(Tokens.Color.muted, .darkAqua)),
                "muted must resolve to one value in both appearances")
    }

    // MARK: The unmuted row

    @Test func unmutedRowDrawsTheOutlineSquareAndNoFillInAnyAppearance() {
        defer { Tokens.test_increaseContrastOverride = nil }
        for (appearanceName, ic) in cells {
            let row = makeRow(muted: false, appearanceName: appearanceName, increaseContrast: ic)
            #expect(row.test_muteDrawsRestSymbol,
                    "\(describe(appearanceName, ic)): unmuted must draw the outline square")
            #expect(!row.test_isMutePillEngaged, "\(describe(appearanceName, ic)): unmuted drew a fill")
            #expect(!row.test_mutePillIsMutedHue,
                    "\(describe(appearanceName, ic)): unmuted painted the muted hue")
            let inks = row.test_muteDrawnInks
            #expect(!contains(inks, resolved(Tokens.Color.muted, appearanceName)),
                    "\(describe(appearanceName, ic)): the muted hue reached the at-rest mark — drew \(inks)")
            #expect(contains(inks, resolved(Tokens.Color.label2, appearanceName)),
                    "\(describe(appearanceName, ic)): at rest must be one neutral ink — drew \(inks)")
        }
    }

    /// The mark must not jump size on toggle. It was two `NSView` seats at a
    /// hand-pinned size for exactly this reason: `speaker.slash.fill` and
    /// `speaker.wave.2.fill` do not share a bounding box, and the button
    /// carries no height constraint, so a fill on the button changed size
    /// every time the glyph slashed. The two custom symbols share one square,
    /// so the size now holds by construction — this is the test that says so.
    @Test func theMarkDoesNotResizeWhenTheStateChanges() {
        defer { Tokens.test_increaseContrastOverride = nil }
        Tokens.test_increaseContrastOverride = false
        let muted = makeRow(muted: true, appearanceName: .aqua, increaseContrast: false)
        let unmuted = makeRow(muted: false, appearanceName: .aqua, increaseContrast: false)

        let frames = "muted \(muted.test_muteSeatFrame), unmuted \(unmuted.test_muteSeatFrame)"
        #expect(muted.test_muteSeatFrame.size == unmuted.test_muteSeatFrame.size,
                "the mark changed size — \(frames)")
        #expect(abs(muted.test_muteSeatFrame.midY - unmuted.test_muteSeatFrame.midY) <= 0.5,
                "the mark moved off centre — \(frames)")

        guard let engagedInk = muted.test_muteMarkInkFrame,
              let restInk = unmuted.test_muteMarkInkFrame else {
            Issue.record("the mute button rendered nothing to measure")
            return
        }
        #expect(abs(engagedInk.width - restInk.width) <= 1,
                "the drawn square changed width on toggle — \(engagedInk) vs \(restInk)")
        #expect(abs(engagedInk.height - restInk.height) <= 1,
                "the drawn square changed height on toggle — \(engagedInk) vs \(restInk)")
    }

    // MARK: A live click, not just a host refresh

    @Test func liveClickSwapsTheSymbolWithoutWaitingForApply() {
        defer { Tokens.test_increaseContrastOverride = nil }
        Tokens.test_increaseContrastOverride = false
        let row = DeviceRowView(device: makeDevice(isMuted: false))
        row.apply(makeDevice(isMuted: false), selected: true, controllable: true)
        #expect(row.test_muteDrawsRestSymbol)

        row.test_toggleMute(true)
        #expect(row.test_mutePillIsMutedHue, "the click must land the fill immediately")

        row.test_toggleMute(false)
        #expect(row.test_muteDrawsRestSymbol, "unmuting must put the outline square back")
        #expect(!row.test_mutePillIsMutedHue, "unmuting must clear the fill")
    }

    // MARK: The fence

    /// `Tokens.Color.muted` exists for the engaged MUTE button and nothing
    /// else. There are two of those — the device row's and the Main Out row's,
    /// which wear one mute language — and a THIRD consumer is a design
    /// decision, not a refactor, so it fails here first.
    @Test func theMutedHueOnlyDressesTheTwoMuteButtons() throws {
        try expectTokenIsFencedTo("Tokens.Color.muted",
                                  ["DeviceRowView.swift", "MainOutRowView.swift"])
    }

    /// `Tokens.Color.equalizer` is fenced the same way, to its one consumer:
    /// the device row's engaged Equalizer door.
    @Test func theEqualizerHueOnlyDressesTheEqualizerDoor() throws {
        try expectTokenIsFencedTo("Tokens.Color.equalizer", ["DeviceRowView.swift"])
    }

    private func expectTokenIsFencedTo(_ token: String, _ expected: Set<String>,
                                       sourceLocation: SourceLocation = #_sourceLocation) throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AudioutCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AudioutCore
            .appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil))

        var callSites: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            // The token's own definition is not a call site.
            guard !url.path.hasSuffix("/Tokens.swift"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(token) {
                callSites.append("\(url.lastPathComponent):\(index + 1)")
            }
        }

        let files = Set(callSites.map { $0.split(separator: ":").first.map(String.init) ?? $0 })
        #expect(files == expected,
                "\(token) is reserved for \(expected.sorted()); found: \(callSites)",
                sourceLocation: sourceLocation)
    }
}

} // extension SerializedSharedState
