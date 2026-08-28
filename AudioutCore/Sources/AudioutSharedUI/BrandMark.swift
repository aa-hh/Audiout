// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The resource bundle, resolved WITHOUT trusting `Bundle.module`. When this
/// target is linked into an executable, SwiftPM generates the accessor variant
/// that searches only `Bundle.main.bundleURL` (the .app ROOT — codesign refuses
/// content there) and the absolute `.build` path of the compiling machine, then
/// fatalErrors. `scripts/make-app.sh` ships the bundle in `Contents/Resources`,
/// so look there first; `Bundle.module` stays as the fallback for `swift run`
/// and tests, where the `.build` path is valid.
private let resourceBundle: Bundle = {
    if let url = Bundle.main.resourceURL?
        .appendingPathComponent("AudioutCore_AudioutSharedUI.bundle"),
        let bundle = Bundle(url: url) { return bundle }
    return Bundle.module
}()

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
        guard let url = resourceBundle.url(forResource: "Audiout-Hero-1024", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.accessibilityDescription = "Audiout"
        return image
    }()
}
