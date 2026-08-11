// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterSharedUI

/// `AppIconCache` — memory → disk → live-fetch resolution, plus the pure
/// `chunk` batching helper. Mirrors `AppTetherColorTests`' shape: point the
/// static cache's directory at this test's `scratchDir` for the duration,
/// restore the real default after.
@MainActor
@Suite final class AppIconCacheTests: IsolatedSuite {

    // Every disk-touching test pins the directory ITSELF as its first act,
    // and NOTHING here ever restores the default: `deinit` is nonisolated
    // and ARC-timed, so a restore there can fire in the MIDDLE of another
    // test's body (observed: it did, intermittently) and silently re-point
    // the static cache at the user's real directory between a test's pin and
    // its read. Leaving the last scratch directory in place is harmless — no
    // other suite reads this cache, and every test in this one pins its own.
    override init() {
        super.init()
        AppIconCache.test_setDirectory(scratchDir)
    }

    /// A real, decodable 128×128 PNG built the same way `AppIconCache`'s own
    /// encoder does, so it's a faithful stand-in for a genuine cached entry.
    private func make128PNG() -> Data {
        let side = AppIconCache.pixelSize
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func unresolvableBundleIDReturnsNilAndWritesNoFile() {
        AppIconCache.test_setDirectory(scratchDir)
        let id = "com.audiouter.test.definitely-not-installed"
        #expect(AppIconCache.pngData(forBundleID: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: scratchDir.appendingPathComponent("\(id).png").path))
    }

    @Test func diskHitReturnsExactlyTheSeededBytes() throws {
        AppIconCache.test_setDirectory(scratchDir)
        let id = "com.audiouter.test.seeded"
        let seeded = make128PNG()
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        try seeded.write(to: scratchDir.appendingPathComponent("\(id).png"))

        #expect(AppIconCache.pngData(forBundleID: id) == seeded)
    }

    @Test func survivesRelaunchAfterMemoryIsCleared() throws {
        let id = "com.audiouter.test.relaunch"
        let seeded = make128PNG()
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        try seeded.write(to: scratchDir.appendingPathComponent("\(id).png"))

        _ = AppIconCache.pngData(forBundleID: id)     // disk hit, populates memory
        AppIconCache.test_setDirectory(scratchDir)    // same dir — clears memory only

        #expect(AppIconCache.pngData(forBundleID: id) == seeded)
    }

    @Test func iconForBundleIDDecodesTheSeededPNGAt128() throws {
        AppIconCache.test_setDirectory(scratchDir)
        let id = "com.audiouter.test.decodes"
        let seeded = make128PNG()
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        try seeded.write(to: scratchDir.appendingPathComponent("\(id).png"))

        let icon = AppIconCache.icon(forBundleID: id)
        #expect(icon?.size.width == CGFloat(AppIconCache.pixelSize))
        #expect(icon?.size.height == CGFloat(AppIconCache.pixelSize))
    }

    @Test func chunkSplitsIntoBatchesOfSizeEightAndEmptyStaysEmpty() {
        let ids = (0..<20).map { "id-\($0)" }
        #expect(AppIconCache.chunk(ids).map(\.count) == [8, 8, 4])
        #expect(AppIconCache.chunk([]).isEmpty)
    }
}
