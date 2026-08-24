// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudioutSharedUI

/// Guards that the bundled brand-mark asset (`Resources/Audiout-Hero-1024.svg`)
/// is actually reachable through `Bundle.module` and decodes to a drawable
/// `NSImage`. A missing/unbundled resource fails silently at the call site
/// (a blank lockup), so pin it here.
final class BrandMarkTests: XCTestCase {
    func test_brandMark_loadsFromBundle() throws {
        let image = try XCTUnwrap(BrandMark.image, "brand-mark SVG did not load from Bundle.module")
        XCTAssertEqual(image.size, NSSize(width: 1024, height: 1024))
        XCTAssertFalse(image.representations.isEmpty)
    }
}
