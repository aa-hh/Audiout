// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// **App icon cache**, keyed by bundle id, memory-over-disk-over-live-fetch.
///
/// An app icon is expensive to fetch (AppKit/`NSWorkspace` calls) and cheap to
/// render once resolved, so this holds a fixed-size PNG per bundle id in
/// memory for the process's life and on disk across launches. Shape mirrors
/// `AppTetherColor`: a static API over an `NSLock`-guarded static cache — no
/// instance, no injected dependency, because a bundle id's icon is a fact
/// about the installed app, not about any one caller.
public enum AppIconCache {

    /// Fixed raster size every cached PNG is encoded at. 128 balances legibility
    /// in list rows against cache size; a caller wanting a smaller on-screen
    /// icon downsamples the decoded `NSImage`, never re-fetches at a different
    /// size — one PNG per bundle id, always.
    public static let pixelSize = 128

    /// Where cached PNGs live on disk. Defaults to a subfolder of the same
    /// per-bundle-id Application Support directory `GroupStore` already uses
    /// (`defaultDirectory`), so a side-by-side dev build's icon cache stays
    /// separate from the live app's, exactly like groups/routes/approvals.
    public static var directory: URL = defaultDirectoryValue

    private static let defaultDirectoryValue =
        GroupStore.defaultDirectory.appendingPathComponent("app-icons", isDirectory: true)

    /// Test seam: point the cache at a scratch directory and drop the
    /// in-memory map, so a subsequent read is forced through disk rather than
    /// serving whatever a prior call already cached in memory. `nil` restores
    /// the real default directory.
    public static func test_setDirectory(_ url: URL?) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        directory = url ?? defaultDirectoryValue
        memory.removeAll()
    }

    private static var memory: [String: Data] = [:]
    private static let cacheLock = NSLock()

    /// The cached icon's PNG bytes for `bundleID`, or `nil` if the app can't
    /// be found by any lookup. Order: in-memory map, then `<directory>/<id>.png`
    /// on disk (populates memory), then a live fetch (populates memory AND
    /// disk). The whole resolve runs under one lock — matches `AppTetherColor`,
    /// and this isn't the audio thread, so serializing concurrent lookups is
    /// the simple, correct choice over finer-grained locking.
    public static func pngData(forBundleID bundleID: String) -> Data? {
        guard isValidFilename(bundleID) else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cached = memory[bundleID] { return cached }

        let fileURL = directory.appendingPathComponent("\(bundleID).png")
        if let onDisk = try? Data(contentsOf: fileURL) {
            memory[bundleID] = onDisk
            return onDisk
        }

        guard let icon = liveIcon(forBundleID: bundleID),
              let encoded = encodedPNG(from: icon)
        else { return nil }

        memory[bundleID] = encoded
        writeToDisk(encoded, fileURL: fileURL)
        return encoded
    }

    /// Convenience decode of ``pngData(forBundleID:)``.
    public static func icon(forBundleID bundleID: String) -> NSImage? {
        pngData(forBundleID: bundleID).flatMap(NSImage.init(data:))
    }

    /// Drop `bundleID` from memory and delete its cached file, so the next
    /// `pngData` re-derives it (an app reinstalled with a new icon, etc.).
    public static func invalidate(bundleID: String) {
        guard isValidFilename(bundleID) else { return }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        memory.removeValue(forKey: bundleID)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(bundleID).png"))
    }

    /// Split `bundleIDs` into batches of at most `size`, in order.
    /// `size`'s default of 8 is a literal, not an import of
    /// `AudiouterProtocol.CompanionAppIcons.pageSize` — this target has no
    /// dependency on that package — and MUST be kept equal to it; a mismatch
    /// desyncs this cache's batching from the companion protocol's page size.
    public static func chunk(_ bundleIDs: [String], size: Int = 8) -> [[String]] {
        guard !bundleIDs.isEmpty else { return [] }
        return stride(from: 0, to: bundleIDs.count, by: size).map {
            Array(bundleIDs[$0..<Swift.min($0 + size, bundleIDs.count)])
        }
    }

    // MARK: - Live fetch

    /// `NSRunningApplication` first (a launched app's own live icon, including
    /// any per-launch badge), then `NSWorkspace`'s installed-app lookup — the
    /// bug fix this cache exists for: an app that isn't currently running
    /// still has an icon on disk, and `urlForApplication` finds its `.app`
    /// bundle so `icon(forFile:)` can render it.
    private static func liveIcon(forBundleID bundleID: String) -> NSImage? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon {
            return running
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        return nil
    }

    // MARK: - Downscale + encode

    /// Render `icon` into a `pixelSize × pixelSize` PNG via an explicit bitmap
    /// context. MUST NOT go via `tiffRepresentation`/the icon's first
    /// representation — an `NSImage` carries whatever reps macOS handed it,
    /// often a cached 32×32, and grabbing the first one silently ships that
    /// low-res rep instead of a real 128×128 render.
    private static func encodedPNG(from icon: NSImage) -> Data? {
        let side = pixelSize
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Filename guard

    /// Defence in depth: `bundleID` becomes a bare path component below, so it
    /// must never be empty, absurdly long, or contain a path/volume separator.
    private static func isValidFilename(_ bundleID: String) -> Bool {
        !bundleID.isEmpty && bundleID.count <= 128 && !bundleID.contains("/") && !bundleID.contains(":")
    }

    // MARK: - Disk I/O

    /// razor: synchronous on the caller's thread. If a cold Mac ever hitches
    /// here, move the live fetch + this write to a serial background queue —
    /// not needed yet, nothing on this path is realtime/audio. Every failure
    /// is swallowed: an unwritable cache degrades to live-fetch-every-time,
    /// never throws into a UI path.
    private static func writeToDisk(_ data: Data, fileURL: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL)
    }
}
