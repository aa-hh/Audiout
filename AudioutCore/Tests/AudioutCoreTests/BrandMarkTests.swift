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
}
