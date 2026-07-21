// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
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
final class AboutSectionTests: XCTestCase {

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

    func testAboutInfoReadsVersionAndBuildFromTheBundleNotHardcoded() {
        let fake = makeFakeBundle(plist: [
            "CFBundleShortVersionString": "9.9.9-test",
            "CFBundleVersion": "424242",
            "CFBundleName": "NotAudiouter",
        ])
        let info = AboutInfo.current(bundle: fake)
        XCTAssertEqual(info.version, "9.9.9-test")
        XCTAssertEqual(info.build, "424242")
        XCTAssertEqual(info.appName, "NotAudiouter")
        XCTAssertEqual(info.versionLine, "Version 9.9.9-test (Build 424242)")
    }

    /// A different fake bundle with different values must produce different
    /// output — the strongest proof this isn't a hardcoded string: two
    /// distinct inputs, two distinct outputs.
    func testAboutInfoTracksWhicheverBundleItIsGiven() {
        let a = AboutInfo.current(bundle: makeFakeBundle(plist: [
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
        ]))
        let b = AboutInfo.current(bundle: makeFakeBundle(plist: [
            "CFBundleShortVersionString": "2.0", "CFBundleVersion": "2",
        ]))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.version, "1.0")
        XCTAssertEqual(b.version, "2.0")
    }

    func testAboutInfoFallsBackWhenBundleHasNoVersionKeys() {
        // Mirrors a loose `swift build`/`swift run` binary (no Info.plist at
        // all in practice) — must not crash, and must not invent a
        // real-looking version number.
        let empty = makeFakeBundle(plist: [:])
        let info = AboutInfo.current(bundle: empty)
        XCTAssertEqual(info.version, "dev")
        XCTAssertEqual(info.build, "—")
        XCTAssertEqual(info.appName, "Audiouter")
    }

    // MARK: GeneralSettingsViewController → AboutWindowController wiring

    func testAboutButtonOpensTheAboutWindowController() {
        let controller = GeneralSettingsViewController(loginItem: FakeLoginItem())
        // Reachability: tapping "About Audiouter…" drives the same window
        // controller `test_about` exposes (headless-safe: `show()` gates its
        // actual on-screen presentation behind `HeadlessRuntime.isActive`).
        controller.test_tapAbout()
        XCTAssertNotNil(controller.test_about.window)
    }

    func testAboutWindowShowsTheInjectedVersionLine() {
        let controller = GeneralSettingsViewController(
            loginItem: FakeLoginItem(),
            aboutInfo: AboutInfo(appName: "Audiouter", version: "1.2.3", build: "77"))
        XCTAssertEqual(controller.test_about.test_aboutViewController.test_versionLine,
                       "Version 1.2.3 (Build 77)")
    }

    func testAboutWindowShowsGPLLicenseAndThirdPartyCredits() {
        let controller = GeneralSettingsViewController(loginItem: FakeLoginItem())
        let text = controller.test_about.test_aboutViewController.test_thirdPartyNoticesText
        XCTAssertTrue(text.contains("GPL-2.0-or-later"))
        XCTAssertTrue(text.contains("MIT"))
        XCTAssertTrue(text.contains("BSD-2-Clause"))
    }

    func testSupportContactIsAnUnmistakableTODOPlaceholder() {
        let controller = GeneralSettingsViewController(loginItem: FakeLoginItem())
        XCTAssertTrue(controller.test_about.test_aboutViewController.test_supportContactText.contains("TODO"))
    }

    func testSourceCodeLinkIsAnUnmistakablePlaceholderNotAnInventedRealURL() {
        // example.com is the IANA-reserved documentation/placeholder domain
        // (RFC 2606) — asserting on it, not a made-up-looking real domain.
        XCTAssertEqual(AboutLinks.sourceCodePlaceholderURL.host, "example.com")
        XCTAssertTrue(AboutLinks.sourceCodePlaceholderURL.absoluteString.contains("TODO"))
    }

    func testViewSourceCodeButtonOpensThePlaceholderURLThroughTheInjectedSeam() {
        var opened: [URL] = []
        let controller = GeneralSettingsViewController(
            loginItem: FakeLoginItem(),
            openURL: { opened.append($0) })
        controller.test_about.test_aboutViewController.test_tapViewSourceCode()
        XCTAssertEqual(opened, [AboutLinks.sourceCodePlaceholderURL])
    }

    // MARK: Doesn't regress the single-screen Settings window's size

    /// The whole point of hosting About in its own window instead of inline
    /// in General: the General pane itself must stay just as compact as
    /// before (one more small button row, not the full About content).
    func testGeneralPaneStaysCompactAboutIsNotInlined() {
        let controller = GeneralSettingsViewController(loginItem: FakeLoginItem())
        controller.view.layoutSubtreeIfNeeded()
        // Three short button rows (Launch at login / Setup / About), not the
        // full About content — comfortably under half of what full inlining
        // measured (~1039pt, the change that broke
        // `testContentSizeIsFittedNotDegenerate`'s 750pt regression bound).
        XCTAssertLessThan(controller.view.fittingSize.height, 250)
    }

    // MARK: Renders offscreen without crashing, in both appearances

    func testAboutWindowRendersOffscreenInLightAndDarkWithoutCrashing() {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let controller = GeneralSettingsViewController(loginItem: FakeLoginItem())
            let rootView = controller.test_about.test_rootView
            rootView.appearance = NSAppearance(named: appearanceName)
            rootView.layoutSubtreeIfNeeded()
            let bounds = rootView.bounds
            XCTAssertGreaterThan(bounds.width, 0)
            XCTAssertGreaterThan(bounds.height, 0)
            let rep = rootView.bitmapImageRepForCachingDisplay(in: bounds)
            XCTAssertNotNil(rep, "\(appearanceName.rawValue): could not make a bitmap rep for the About content")
        }
    }
}
