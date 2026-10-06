// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
@testable import AudioutSharedUI

/// Compiles the repo's own `Symbols.xcassets` into a temporary bundle, once
/// per test process, and points ``RowAccessorySymbol/test_catalogueBundle`` at
/// it — because `swift test` builds no `.app`, so the shipping lookup
/// (`NSImage(named:)` against `Contents/Resources/Assets.car`, produced by
/// `make-app.sh`) has nothing to find under the suite. Without this fixture
/// every pixel assertion on the mute and Equalizer marks would be measuring a
/// nil image.
///
/// The compile is the same `actool` invocation the build script runs, over the
/// same source catalogue, so a symbol that fails HERE fails the shipping build
/// identically — and a malformed symbolset is caught by the first suite that
/// draws one instead of by eyes on a blank control.
enum CompiledSymbolFixture {
    /// The one compile, shared by every suite in the process. `nil` only when
    /// `actool` itself failed; callers `#require` it so that failure is loud.
    nonisolated(unsafe) private static var cached: Bundle??

    @MainActor
    static func install() -> Bundle? {
        if let done = cached { RowAccessorySymbol.test_catalogueBundle = done; return done }
        let bundle = compile()
        cached = .some(bundle)
        RowAccessorySymbol.test_catalogueBundle = bundle
        return bundle
    }

    /// The bounding box of everything `image` actually paints, in points.
    @MainActor
    static func inkBounds(_ image: NSImage) -> NSRect? {
        guard let rep = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        else { return nil }
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        var minX = rep.pixelsWide, maxX = -1, minY = rep.pixelsHigh, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return NSRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale,
                      height: CGFloat(maxY - minY + 1) / scale)
    }

    private static func compile() -> Bundle? {
        // The catalogue lives beside this test target's own sources.
        let here = URL(fileURLWithPath: #filePath)
        let catalogue = here
            .deletingLastPathComponent()   // the file itself -> AudioutCoreTests/
            .deletingLastPathComponent()   // -> Tests/
            .deletingLastPathComponent()   // -> AudioutCore/
            .appendingPathComponent("Sources/AudioutSharedUI/Resources/Symbols.xcassets")
        guard FileManager.default.fileExists(atPath: catalogue.path) else { return nil }

        let root = FileManager.default.temporaryDirectory   // isolation-ok
            .appendingPathComponent("audiout-symbol-fixture-\(ProcessInfo.processInfo.processIdentifier)")
        let resources = root.appendingPathComponent("Contents/Resources")
        try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist = root.appendingPathComponent("Contents/Info.plist")
        try? """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.audiout.symbolfixture</string>\
        <key>CFBundlePackageType</key><string>BNDL</string></dict></plist>
        """.write(to: plist, atomically: true, encoding: .utf8)

        let actool = Process()
        actool.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        actool.arguments = ["actool", catalogue.path,
                            "--compile", resources.path,
                            "--platform", "macosx",
                            "--minimum-deployment-target", "14.2",
                            "--output-format", "human-readable-text"]
        actool.standardOutput = FileHandle.nullDevice
        actool.standardError = FileHandle.nullDevice
        do { try actool.run(); actool.waitUntilExit() } catch { return nil }
        guard actool.terminationStatus == 0,
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("Assets.car").path)
        else { return nil }
        return Bundle(url: root)
    }
}
