// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The Audiout **brand mark** — the speaker-with-halo hero render — for use
/// INSIDE the app (About lockup, onboarding header, demo finale).
///
/// This is deliberately NOT the OS app icon. `NSApp.applicationIconImage`
/// resolves the compiled `.icon` bundle (`scripts/Audiout.icon`), whose only
/// job is the Dock/Finder tile; drawing it in-app couples our identity to an
/// OS-owned artifact. The hero render is the identity we control — master in
/// Figma (frame `111:2`), checked in at `scripts/Audiout-Hero-1024.svg`, with
/// the bundled runtime copy under `Resources/`.
///
/// NSImage renders the SVG directly (verified: the gold halo, cabinet, and
/// rings resolve; the `foreignObject` gradient hack does not break the fill).
public enum BrandMark {
    /// The brand mark at its native 1024² proportions. Shared and cached —
    /// size it through the hosting `NSImageView`, or take a `.copy()` before
    /// mutating `size`. `nil` only if the bundled asset is missing.
    public static let image: NSImage? = {
        guard let url = resourceBundle?.url(forResource: "Audiout-Hero-1024", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.accessibilityDescription = "Audiout"
        return image
    }()

    /// Locates SwiftPM's resource bundle for this target, deliberately WITHOUT
    /// `Bundle.module`.
    ///
    /// `Bundle.module`'s generated accessor checks only
    /// `Bundle.main.bundleURL/<name>.bundle` plus the absolute build-directory
    /// path baked in when the binary was COMPILED — and it `fatalError`s rather
    /// than returning nil when neither hits. Inside a shipped `.app` the first
    /// is the `.app` root, where codesign refuses to let the bundle live
    /// ("unsealed contents present in the bundle root"), so only the build path
    /// keeps it alive: fine on the machine that compiled the binary, a hard trap
    /// on launch when the compile happened on the remote build mule.
    ///
    /// So look where the bundle actually ships instead, and degrade to a blank
    /// mark rather than a crash if it is nowhere: `Contents/Resources` of the
    /// enclosing `.app`, the products directory beside a `.xctest` (where the
    /// swift-testing runner finds it — its `Bundle.main` is the toolchain's test
    /// helper, so only the module's own bundle locates anything), and the
    /// directory holding a plain `swift run` binary.
    private static let resourceBundle: Bundle? = {
        let name = "AudioutCore_AudioutSharedUI.bundle"
        let own = Bundle(for: BundleToken.self)
        let roots = [own.resourceURL, own.bundleURL.deletingLastPathComponent(),
                     Bundle.main.resourceURL, Bundle.main.bundleURL]
        return roots.lazy
            .compactMap { $0?.appendingPathComponent(name) }
            .compactMap(Bundle.init(url:))
            .first
    }()

    /// Anchors `Bundle(for:)` to THIS module's binary — a class is the only
    /// thing that API accepts.
    private final class BundleToken {}
}
