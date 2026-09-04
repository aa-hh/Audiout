// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
import AudioutCore
@testable import AudioutSharedUI

/// The engaged mute state's two carriers — a SLASHED speaker and the reserved
/// ``Tokens/Color/muted`` hue — asserted as DRAWN, in all four appearances
/// (light/dark x Increase Contrast), plus the fence that keeps the hue to its
/// one consumer.
///
/// Nested into `SerializedSharedState` because every test here drives the
/// process-global `Tokens.test_increaseContrastOverride` seam, the same reason
/// `TokenContrastMatrixTests` is nested.
@MainActor
extension SerializedSharedState {

@Suite final class DeviceRowMutedStateTests: IsolatedSuite {

    deinit { Tokens.test_increaseContrastOverride = nil }

    private static let restSymbol = "speaker.wave.2.fill"
    private static let engagedSymbol = "speaker.slash.fill"

    private func makeDevice(isMuted: Bool) -> Device {
        Device(id: "dev-1", name: "Test Speaker", kind: .homePod,
               isAvailable: true, isMuted: isMuted, connectionState: .connected)
    }

    /// A row settled into one of the four appearance cells. `apply` runs AFTER
    /// the appearance is set, so the layer colour is stamped under it whether
    /// or not a detached view gets `viewDidChangeEffectiveAppearance`.
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

    /// Compare two colours by resolved sRGB components, the idiom the other row
    /// suites use: `Tokens.Color.panel` is a computed property, so each read
    /// builds a fresh dynamic `NSColor` and instance equality proves nothing.
    private func assertSameHue(_ a: NSColor?, _ b: NSColor?, _ message: String,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else {
            Issue.record("nil color: \(message)", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(a.redComponent - b.redComponent) < 0.01, "\(message)", sourceLocation: sourceLocation)
        #expect(abs(a.greenComponent - b.greenComponent) < 0.01, "\(message)", sourceLocation: sourceLocation)
        #expect(abs(a.blueComponent - b.blueComponent) < 0.01, "\(message)", sourceLocation: sourceLocation)
    }

    // MARK: The muted row

    @Test func mutedRowDrawsTheSlashedSpeakerInEveryAppearance() {
        defer { Tokens.test_increaseContrastOverride = nil }
        for (appearanceName, ic) in cells {
            let row = makeRow(muted: true, appearanceName: appearanceName, increaseContrast: ic)
            #expect(row.test_muteGlyphIsSymbol(Self.engagedSymbol),
                    "\(describe(appearanceName, ic)): muted must draw \(Self.engagedSymbol)")
            #expect(!row.test_muteGlyphIsSymbol(Self.restSymbol),
                    "\(describe(appearanceName, ic)): muted must not keep the at-rest speaker")
        }
    }

    @Test func mutedRowFillsThePillWithTheReservedHueInEveryAppearance() {
        defer { Tokens.test_increaseContrastOverride = nil }
        for (appearanceName, ic) in cells {
            let row = makeRow(muted: true, appearanceName: appearanceName, increaseContrast: ic)
            #expect(row.test_isMutePillEngaged, "\(describe(appearanceName, ic)): no pill drawn")
            #expect(row.test_mutePillIsMutedHue,
                    "\(describe(appearanceName, ic)): the pill is not the muted hue at full opacity")
            assertSameHue(row.test_muteTintColor, Tokens.Color.panel,
                          "\(describe(appearanceName, ic)): the glyph is not knocked out in the row's ground tone")
        }
    }

    // MARK: The unmuted row

    @Test func unmutedRowDrawsNeitherTheSlashNorTheHueInAnyAppearance() {
        defer { Tokens.test_increaseContrastOverride = nil }
        for (appearanceName, ic) in cells {
            let row = makeRow(muted: false, appearanceName: appearanceName, increaseContrast: ic)
            #expect(row.test_muteGlyphIsSymbol(Self.restSymbol),
                    "\(describe(appearanceName, ic)): unmuted must draw \(Self.restSymbol)")
            #expect(!row.test_muteGlyphIsSymbol(Self.engagedSymbol),
                    "\(describe(appearanceName, ic)): unmuted must never draw the slash")
            #expect(!row.test_isMutePillEngaged, "\(describe(appearanceName, ic)): unmuted drew a pill")
            #expect(!row.test_mutePillIsMutedHue,
                    "\(describe(appearanceName, ic)): unmuted stamped the muted hue")
            #expect(row.test_muteTintColor === Tokens.Color.label2,
                    "\(describe(appearanceName, ic)): unmuted must stay on the neutral secondary ink")
        }
    }

    /// The pill is the BUTTON's own layer, so its size is the button's frame.
    /// `speaker.slash.fill` and `speaker.wave.2.fill` do not share a bounding
    /// box, and the button carries no height constraint — so the pill would
    /// change size on toggle if the row let the glyph drive it. The state is
    /// carried by the slash and the hue; the mark must not also jump.
    @Test func theButtonDoesNotResizeWhenTheGlyphSlashes() {
        defer { Tokens.test_increaseContrastOverride = nil }
        Tokens.test_increaseContrastOverride = false
        let muted = makeRow(muted: true, appearanceName: .aqua, increaseContrast: false)
        let unmuted = makeRow(muted: false, appearanceName: .aqua, increaseContrast: false)
        for row in [muted, unmuted] { row.layoutSubtreeIfNeeded() }

        let frames = "muted \(muted.test_muteButtonFrame), unmuted \(unmuted.test_muteButtonFrame)"
        #expect(muted.test_muteButtonFrame.size == unmuted.test_muteButtonFrame.size,
                "the engaged pill changed size — \(frames)")
        #expect(abs(muted.test_muteButtonFrame.midY - unmuted.test_muteButtonFrame.midY) <= 0.5,
                "the engaged pill moved off centre — \(frames)")
    }

    // MARK: A live click, not just a host refresh

    @Test func liveClickSwapsBothTheGlyphAndTheFillWithoutWaitingForApply() {
        defer { Tokens.test_increaseContrastOverride = nil }
        Tokens.test_increaseContrastOverride = false
        let row = DeviceRowView(device: makeDevice(isMuted: false))
        row.apply(makeDevice(isMuted: false), selected: true, controllable: true)
        #expect(row.test_muteGlyphIsSymbol(Self.restSymbol))

        row.test_toggleMute(true)
        #expect(row.test_muteGlyphIsSymbol(Self.engagedSymbol), "the click must land the slash immediately")
        #expect(row.test_mutePillIsMutedHue, "the click must land the fill immediately")

        row.test_toggleMute(false)
        #expect(row.test_muteGlyphIsSymbol(Self.restSymbol), "unmuting must put the plain speaker back")
        #expect(!row.test_mutePillIsMutedHue, "unmuting must clear the fill")
    }

    // MARK: The fence

    /// `Tokens.Color.muted` exists for the engaged mute button and nothing
    /// else. A second consumer is a design decision, not a refactor, so it
    /// fails here first.
    @Test func theMutedHueHasExactlyOneConsumerInShippingSource() throws {
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
            where line.contains("Tokens.Color.muted") {
                callSites.append("\(url.lastPathComponent):\(index + 1)")
            }
        }

        #expect(callSites.count == 1 && callSites.first?.hasPrefix("DeviceRowView.swift:") == true,
                "Tokens.Color.muted is reserved for the device row's engaged mute button; found: \(callSites)")
    }
}

} // extension SerializedSharedState
