// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudioutSharedUI

/// Guards that the bundled brand-mark asset (`Resources/Audiout-Hero-1024.svg`)
/// is actually reachable through `Bundle.module` and decodes to a drawable
/// `NSImage`. A missing/unbundled resource fails silently at the call site
/// (a blank lockup), so pin it here.
@Suite struct BrandMarkTests {
    @Test func brandMarkLoadsFromBundle() throws {
        let image = try #require(BrandMark.image, "brand-mark SVG did not load from Bundle.module")
        #expect(image.size == NSSize(width: 1024, height: 1024))
        #expect(!image.representations.isEmpty)
    }

    /// The wordmark face is fetched into an assembled `.app` by
    /// `scripts/make-app.sh`, never shipped in git or the SwiftPM resource
    /// bundle — so under `swift test` `Bundle.main` is the XCTest runner and
    /// the lookup finds nothing. The system bold fallback is therefore the
    /// path under test here; the real face can only be checked in a built
    /// `.app`.
    @Test func wordmarkFallsBackToSystemBoldWithoutTheAppBundle() {
        let font = Tokens.Font.wordmark(size: 32)
        #expect(font.fontName == NSFont.boldSystemFont(ofSize: 32).fontName)
        #expect(font.pointSize == 32)
    }
}
