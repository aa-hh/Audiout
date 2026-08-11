// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import UIKit

/// On-disk cache of per-app icons (PNG, keyed by bundle ID) fetched from the
/// Mac. Lives under `Library/Caches`, not `Application Support`: these icons
/// are re-fetchable from the Mac at any time, the OS is free to reclaim the
/// directory under disk pressure, and — because it's Caches — the system
/// never includes it in an iCloud/iTunes backup, which is exactly right for
/// data that's just a local copy of something the Mac already owns.
@MainActor
@Observable
final class AppIconStore {

    static var defaultDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("AppIcons", isDirectory: true)

    /// Bundle ID (filename minus `.png`) → decoded icon.
    private(set) var images: [String: UIImage] = [:]

    private let directory: URL

    /// razor: reads `directory` synchronously on init. At today's scale
    /// (≤100 addable apps plus routes, ~20 KB per PNG) that's a few
    /// milliseconds on the main actor at launch. Move to an async load if
    /// the cache ever grows to hold hundreds of icons.
    init(directory: URL = AppIconStore.defaultDirectory) {
        self.directory = directory
        var loaded: [String: UIImage] = [:]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.pathExtension == "png" {
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                loaded[url.deletingPathExtension().lastPathComponent] = image
            }
        }
        images = loaded
    }

    /// Looking up through `images` (rather than caching the result
    /// elsewhere) is what makes this observable: a SwiftUI view that reads
    /// `image(for:)` in its body picks up `images` as a dependency, so it
    /// re-renders automatically the moment `store` lands that bundle ID's
    /// icon.
    func image(for bundleID: String) -> UIImage? {
        images[bundleID]
    }

    /// Trust boundary: `bundleID` comes from the Mac over the wire and
    /// becomes a filename here, so anything that isn't a plausible bundle ID
    /// is refused before it touches disk or memory.
    func store(bundleID: String, png: Data) {
        guard !bundleID.isEmpty, bundleID.count <= 128,
              !bundleID.contains("/"), !bundleID.contains(":") else { return }
        guard let image = UIImage(data: png) else { return }

        images[bundleID] = image

        // Best-effort: a failed write just means this icon gets re-fetched
        // next launch (see `missing(from:)`) — never surface I/O errors here.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("\(bundleID).png"))
    }

    /// `bundleIDs` not yet in `images`, in input order, with duplicates
    /// removed.
    ///
    /// razor: no negative caching — a bundle ID whose fetch failed or came
    /// back with no icon is simply asked again next launch, which is cheap.
    /// No eviction cap either: the set this draws from is bounded by what
    /// the Mac reports (≤100 addable apps plus routes), so `images` can't
    /// grow unbounded on its own.
    func missing(from bundleIDs: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for id in bundleIDs where images[id] == nil && !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return result
    }
}
