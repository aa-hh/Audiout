// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
import AudiouterSharedUI
@testable import AudiouterSettingsUI

/// Covers the About/Credits surface reachable from Settings › General ›
/// "About Audiouter…" — the app had no in-app About/license surface before
/// this, a gap for a paid product and a GPL attribution requirement before
/// charging money.
///
/// `AboutInfo.current(bundle:)` takes an injectable `Bundle` precisely so the
/// "read from the bundle, never hardcoded" requirement is provable: point it
/// at a throwaway on-disk fake bundle with known Info.plist values and assert
/// they come back unchanged.
@MainActor
@Suite struct AboutSectionTests {

    private final class FakeLoginItem: LoginItemManaging {
        var isEnabled: Bool = false
        func setEnabled(_ enabled: Bool) throws {}
    }

    /// Builds a real on-disk bundle directory with a hand-written Info.plist
    /// so `Bundle(path:).infoDictionary` reads genuinely dynamic values.
    private func makeFakeBundle(plist: [String: Any]) -> Bundle {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiouterTests-AboutInfo-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try! data.write(to: dir.appendingPathComponent("Info.plist"))
        return Bundle(path: dir.path)!
    }

    // MARK: AboutInfo reads the bundle, never hardcodes

    @Test func aboutInfoReadsVersionAndBuildFromTheBundleNotHardcoded() {
        let fake = makeFakeBundle(plist: [
            "CFBundleShortVersionString": "9.9.9-test",
            "CFBundleVersion": "424242",
            "CFBundleName": "NotAudiouter",
        ])
        let info = AboutInfo.current(bundle: fake)
        #expect(info.version == "9.9.9-test")
        #expect(info.build == "424242")
        #expect(info.appName == "NotAudiouter")
        #expect(info.versionLine == "Version 9.9.9-test (Build 424242)")
    }

    /// A different fake bundle with different values must produce different
    /// output — the strongest proof this isn't a hardcoded string: two
    /// distinct inputs, two distinct outputs.
    @Test func aboutInfoTracksWhicheverBundleItIsGiven() {
        let a = AboutInfo.current(bundle: makeFakeBundle(plist: [
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
        ]))
        let b = AboutInfo.current(bundle: makeFakeBundle(plist: [
            "CFBundleShortVersionString": "2.0", "CFBundleVersion": "2",
        ]))
        #expect(a != b)
        #expect(a.version == "1.0")
        #expect(b.version == "2.0")
    }

    @Test func aboutInfoFallsBackWhenBundleHasNoVersionKeys() {
        // Mirrors a loose `swift build`/`swift run` binary (no Info.plist at
        // all in practice) — must not crash, and must not invent a
        // real-looking version number.
        let empty = makeFakeBundle(plist: [:])
        let info = AboutInfo.current(bundle: empty)
        #expect(info.version == "dev")
        #expect(info.build == "—")
        #expect(info.appName == "Audiouter")
    }

    // MARK: GeneralSettingsViewController → AboutWindowController wiring

    @Test func aboutButtonOpensTheAboutWindowController() {
        let controller = GeneralSettingsViewController(loginItem: FakeLoginItem())
        // Reachability: tapping "About Audiouter…" drives the same window
        // controller `test_about` exposes (headless-safe: `show()` gates its
        // actual on-screen presentation behind `HeadlessRuntime.isActive`).
        controller.test_tapAbout()
        #expect(controller.test_about.window != nil)
    }

    /// A1: About's background effect view carries an opaque cover that stands
    /// in for the blur exactly while Reduce Transparency is on — driven
    /// through the seam because the live accessibility setting isn't
    /// scriptable headlessly (the notification-driven live flip is on the
    /// live checklist).
    @Test func aboutBackgroundGetsAnOpaqueCoverOnlyUnderReduceTransparency() throws {
        let controller = GeneralSettingsViewController(loginItem: FakeLoginItem())
        let about = controller.test_about.test_aboutViewController
        _ = about.view  // force loadView, which builds the background
        let fallback = try #require(about.backgroundFallback)

        fallback.test_reduceTransparencyOverride = false
        #expect(!fallback.test_isCoveringOpaquely)

        fallback.test_reduceTransparencyOverride = true
        #expect(fallback.test_isCoveringOpaquely)
    }

    @Test func aboutWindowShowsTheInjectedVersionLine() {
        let controller = GeneralSettingsViewController(
            loginItem: FakeLoginItem(),
            aboutInfo: AboutInfo(appName: "Audiouter", version: "1.2.3", build: "77"))
        #expect(controller.test_about.test_aboutViewController.test_versionLine == "Version 1.2.3 (Build 77)")
    }

    @Test func aboutWindowShowsGPLLicenseAndThirdPartyCredits() {
        let controller = GeneralSettingsViewController(loginItem: FakeLoginItem())
        let text = controller.test_about.test_aboutViewController.test_thirdPartyNoticesText
        #expect(text.contains("GPL-2.0-or-later"))
        #expect(text.contains("MIT"))
        #expect(text.contains("BSD-2-Clause"))
    }

    @Test func supportContactIsAnUnmistakableTODOPlaceholder() {
        let controller = GeneralSettingsViewController(loginItem: FakeLoginItem())
        #expect(controller.test_about.test_aboutViewController.test_supportContactText.contains("TODO"))
    }

    @Test func sourceCodeLinkIsAnUnmistakablePlaceholderNotAnInventedRealURL() {
        // example.com is the IANA-reserved documentation/placeholder domain
        // (RFC 2606) — asserting on it, not a made-up-looking real domain.
        #expect(AboutLinks.sourceCodePlaceholderURL.host == "example.com")
        #expect(AboutLinks.sourceCodePlaceholderURL.absoluteString.contains("TODO"))
    }

    @Test func viewSourceCodeButtonOpensThePlaceholderURLThroughTheInjectedSeam() {
        var opened: [URL] = []
        let controller = GeneralSettingsViewController(
            loginItem: FakeLoginItem(),
            openURL: { opened.append($0) })
        controller.test_about.test_aboutViewController.test_tapViewSourceCode()
        #expect(opened == [AboutLinks.sourceCodePlaceholderURL])
    }

    // MARK: Doesn't regress the single-screen Settings window's size

    /// The whole point of hosting About in its own window instead of inline
    /// in General: the General pane itself must stay just as compact as
    /// before (one more small button row, not the full About content).
    @Test func generalPaneStaysCompactAboutIsNotInlined() {
        let controller = GeneralSettingsViewController(loginItem: FakeLoginItem())
        controller.view.layoutSubtreeIfNeeded()
        // Four short rows (Launch at login / iPhone control / Setup / About),
        // not the full About content — comfortably under half of what full
        // inlining measured (~1039pt, the change that broke
        // `testContentSizeIsFittedNotDegenerate`'s 750pt regression bound).
        #expect(controller.view.fittingSize.height < 300)
    }

    // MARK: Renders offscreen without crashing, in both appearances

    @Test func aboutWindowRendersOffscreenInLightAndDarkWithoutCrashing() {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let controller = GeneralSettingsViewController(loginItem: FakeLoginItem())
            let rootView = controller.test_about.test_rootView
            rootView.appearance = NSAppearance(named: appearanceName)
            rootView.layoutSubtreeIfNeeded()
            let bounds = rootView.bounds
            #expect(bounds.width > 0)
            #expect(bounds.height > 0)
            let rep = rootView.bitmapImageRepForCachingDisplay(in: bounds)
            #expect(rep != nil, "\(appearanceName.rawValue): could not make a bitmap rep for the About content")
        }
    }
}
