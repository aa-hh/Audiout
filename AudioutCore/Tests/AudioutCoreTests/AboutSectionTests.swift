// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
import AudioutSharedUI
@testable import AudioutSettingsUI

/// Covers the About/Credits surface reachable from Settings › General ›
/// "About Audiout…" — the app had no in-app About/license surface before
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
            .appendingPathComponent("AudioutTests-AboutInfo-\(UUID().uuidString)", isDirectory: true)
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
            "CFBundleName": "NotAudiout",
        ])
        let info = AboutInfo.current(bundle: fake)
        #expect(info.version == "9.9.9-test")
        #expect(info.build == "424242")
        #expect(info.appName == "NotAudiout")
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
        #expect(info.appName == "Audiout")
    }

    // MARK: GeneralSettingsViewController → AboutWindowController wiring

    @Test func aboutButtonOpensTheAboutWindowController() {
        let controller = GeneralSettingsViewController(loginItem: FakeLoginItem())
        // Reachability: tapping "About Audiout…" drives the same window
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
            aboutInfo: AboutInfo(appName: "Audiout", version: "1.2.3", build: "77"))
        #expect(controller.test_about.test_aboutViewController.test_versionLine == "Version 1.2.3 (Build 77)")
    }

    @Test func aboutWindowShowsGPLLicenseAndThirdPartyCredits() {
        let controller = GeneralSettingsViewController(loginItem: FakeLoginItem())
        let text = controller.test_about.test_aboutViewController.test_thirdPartyNoticesText
        #expect(text.contains("GPL-2.0-or-later"))
        #expect(text.contains("MIT"))
        #expect(text.contains("BSD-2-Clause"))
    }

    /// The permanent fence: About is the surface that discharges the GPL
    /// source-availability obligation and names where to get help, so nothing
    /// it renders may ever be a stand-in again. Values are compile-time
    /// constants, so this holds for every build.
    @Test func aboutShipsRealValuesAndNeverAPlaceholder() {
        let about = GeneralSettingsViewController(loginItem: FakeLoginItem())
            .test_about.test_aboutViewController
        let rendered = [AboutLinks.sourceCodeURL.absoluteString,
                        about.test_supportContactText,
                        about.test_privacyText,
                        AboutCredits.thirdPartyNoticesText]
        for text in rendered {
            #expect(!text.contains("example.com"), Comment(rawValue: "placeholder domain in: \(text)"))
            #expect(!text.contains("TODO"), Comment(rawValue: "placeholder marker in: \(text)"))
        }
        #expect(AboutLinks.sourceCodeURL == URL(string: "https://github.com/aa-hh/Audiout")!)
        #expect(about.test_supportContactText == "Questions or problems? Email support@audiout.app.")
    }

    /// The honest accounting of what leaves this Mac, verbatim.
    @Test func aboutStatesExactlyWhatTheAppSends() {
        let about = GeneralSettingsViewController(loginItem: FakeLoginItem())
            .test_about.test_aboutViewController
        #expect(about.test_privacyText == "Discovery, routing, volume, and playback stay entirely on your network — none of it touches a server, even offline. Audiout’s only outside connections are about your license and updates: a check of your key, a once-per-launch check-in (your key, a random per-Mac id, and the app version — nothing else), and the update check when one runs. A build compiled from source makes none of these.")
    }

    @Test func viewSourceCodeButtonOpensTheRepositoryURLThroughTheInjectedSeam() {
        var opened: [URL] = []
        let controller = GeneralSettingsViewController(
            loginItem: FakeLoginItem(),
            openURL: { opened.append($0) })
        controller.test_about.test_aboutViewController.test_tapViewSourceCode()
        #expect(opened == [URL(string: "https://github.com/aa-hh/Audiout")!])
    }

    // MARK: Doesn't regress the single-screen Settings window's size

    /// The whole point of hosting About in its own window instead of inline
    /// in General: the General pane itself must stay just as compact as
    /// before (one more small button row, not the full About content).
    @Test func generalPaneStaysCompactAboutIsNotInlined() {
        let controller = GeneralSettingsViewController(loginItem: FakeLoginItem())
        controller.view.layoutSubtreeIfNeeded()
        // Launch at login / Reconnect at launch / iPhone control / License
        // key / a status hint / a button row (roadmap 054 added the License
        // row, the companion work the iPhone row; check-ins are unconditional
        // now — no separate consent row, 2026-08-24) — still comfortably
        // under half of what full About inlining measured
        // (~1039pt, the change that broke
        // `testContentSizeIsFittedNotDegenerate`'s 750pt regression bound).
        #expect(controller.view.fittingSize.height < 520)
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
