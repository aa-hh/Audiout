// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
import CoreImage
import AudioutProtocol
@testable import AudioutSharedUI

/// The one invitation to Audiout Remote, and the words the Mac says about
/// where an offset came from.
@MainActor
@Suite struct RemoteInviteViewTests {

    /// Defect this names: the tile renders a code that reads as something
    /// other than the invitation's own page — a truncated URL, a blank tile,
    /// a mirrored draw, or a scale that blurs the modules past reading. A
    /// real QR reader on the DRAWN pixels is the only check that catches all
    /// four; asserting the generator's input catches none of them.
    @Test func everySizeDrawsACodeAScannerReadsBackAsThePage() throws {
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        for side in [RemoteInviteView.settingsTileSide,
                     RemoteInviteView.wizardTileSide,
                     RemoteInviteView.setupTileSide] {
            let view = RemoteInviteView(tileSide: side)
            let data = try #require(view.test_renderTile().tiffRepresentation)
            let image = try #require(CIImage(data: data))
            let decoded = detector.features(in: image)
                .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            #expect(decoded == [RemoteInviteView.pageURLString],
                    "the \(side) pt tile decoded as \(decoded)")
        }
    }

    /// Defect this names: a tile shipped without the address beside it, which
    /// leaves a VoiceOver user and anyone without a camera at a dead end.
    @Test func theAddressIsPrintedUnderTheTileWithNoScheme() {
        let view = RemoteInviteView(tileSide: RemoteInviteView.wizardTileSide)
        #expect(view.test_addressText == "audiout.app/remote")
        #expect(!RemoteInviteView.pageAddress.contains("://"),
                "the printed address carries no scheme")
        #expect(RemoteInviteView.pageURL.absoluteString == RemoteInviteView.pageURLString)
    }

    /// Defect this names: a source string renamed in `audiout-shared` while
    /// the Mac's UI enum keeps the old spelling, so every row silently falls
    /// back to no source at all.
    @Test func everySourceMatchesTheWireVocabulary() {
        #expect(BTOffsetSource.measured.wireValue == AlignmentSource.measured)
        #expect(BTOffsetSource.firstPass.wireValue == AlignmentSource.firstPass)
        #expect(BTOffsetSource.fromLastTime.wireValue == AlignmentSource.fromLastTime)
        #expect(BTOffsetSource.byEar.wireValue == AlignmentSource.byEar)
        #expect(BTOffsetSource(wireValue: AlignmentSource.fromLastTime) == .fromLastTime)
        #expect(BTOffsetSource(wireValue: "somethingNewerMacsSend") == nil)
    }

    /// Defect this names: the over-40 ms notice printing a fraction, or
    /// leading with a minus sign, when the user is being told how far the
    /// number moved.
    @Test func theMovedNoticeSaysTheWholeMillisecondDifference() {
        #expect(BTOffsetSource.movedNotice(byMs: 46.4).hasPrefix("Moved 46 ms since last time."))
        #expect(BTOffsetSource.movedNotice(byMs: -46.4).hasPrefix("Moved 46 ms since last time."))
    }
}
