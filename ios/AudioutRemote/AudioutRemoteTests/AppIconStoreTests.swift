// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import UIKit
@testable import AudioutRemote

/// `AppIconStore`'s on-disk cache: round-trip, survival across a relaunch
/// (a second store built over the same directory), `missing(from:)`'s
/// ordering/dedup contract, and the bundle-ID trust boundary in `store`.
@Suite struct AppIconStoreTests {

    /// A real, tiny, decodable PNG — `UIImage(data:)` refuses anything that
    /// isn't actual image data, so a hardcoded byte array or empty `Data`
    /// wouldn't exercise `store` the way a Mac-supplied icon does.
    private func tinyPNG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return image.pngData()!
    }

    private func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @MainActor
    @Test func storeThenReadBack() {
        let directory = freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AppIconStore(directory: directory)
        #expect(store.image(for: "com.example.app") == nil)

        store.store(bundleID: "com.example.app", png: tinyPNG())
        #expect(store.image(for: "com.example.app") != nil)
    }

    @MainActor
    @Test func survivesRelaunch() {
        let directory = freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = AppIconStore(directory: directory)
        first.store(bundleID: "com.example.app", png: tinyPNG())

        let second = AppIconStore(directory: directory)
        #expect(second.image(for: "com.example.app") != nil)
    }

    @MainActor
    @Test func missingReturnsOnlyUncachedIDsOrderPreservedDupesRemoved() {
        let directory = freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AppIconStore(directory: directory)
        store.store(bundleID: "cached", png: tinyPNG())

        let result = store.missing(from: ["cached", "b", "a", "b", "cached", "a"])
        #expect(result == ["b", "a"])
    }

    @MainActor
    @Test func keyContainingSlashIsRefusedAndWritesNoFile() {
        let directory = freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AppIconStore(directory: directory)
        store.store(bundleID: "evil/bundle", png: tinyPNG())

        #expect(store.image(for: "evil/bundle") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    @Test func twoHundredCharacterKeyIsRefused() {
        let directory = freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let longKey = String(repeating: "a", count: 200)
        let store = AppIconStore(directory: directory)
        store.store(bundleID: longKey, png: tinyPNG())

        #expect(store.image(for: longKey) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
