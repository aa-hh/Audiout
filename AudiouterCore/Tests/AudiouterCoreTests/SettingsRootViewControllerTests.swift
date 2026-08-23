// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
import AudiouterSharedUI
@testable import AudiouterCore
@testable import AudiouterSettingsUI

/// The Settings panes aren't visible to a headless test run, so — exactly like
/// `PopoverControllerTests` — these drive `test_` hooks and public seams to
/// assert structure, the hosting contract, and that the panes route their
/// actions through the injected seams (login item, `AppSettings`) rather than
/// the real system.
///
/// The structure under test: a sidebar of sections over ONE pane. Selecting a
/// section swaps that pane, top-aligned inside the host's scroll view. NO size
/// is ever published to a host — the surface frame is fixed, so a pane grows
/// the scroll document, never the window. Panes are assembled the way the app
/// assembles them (`AppDelegate.makeSettingsRoot`): built directly, callbacks
/// wired on the pane itself, mounted on a `SettingsRootViewController`.
@MainActor
@Suite struct SettingsRootViewControllerTests {

    /// A `LoginItemManaging` fake: records the requested state, optionally
    /// refuses (to exercise the revert path) — never touches `SMAppService`.
    private final class FakeLoginItem: LoginItemManaging {
        var enabled: Bool
        var refuse = false
        private(set) var setCallCount = 0
        init(enabled: Bool) { self.enabled = enabled }

        var isEnabled: Bool { enabled }
        func setEnabled(_ newValue: Bool) throws {
            setCallCount += 1
            if refuse { throw NSError(domain: "test", code: 1) }
            enabled = newValue
        }
    }

    private let isolation = TestIsolation(owner: "SettingsRootViewControllerTests")

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: isolation.makeDefaults())
    }

    /// An excluded-apps controller over a throwaway temp store (never the real
    /// `~/Library/Application Support`).
    private func makeExcluded() -> ExcludedAppsController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiouterTests-\(UUID().uuidString)", isDirectory: true)
        return ExcludedAppsController(store: ExcludedAppsStore(directory: dir))
    }

    /// The panes + root, assembled like the app assembles them. Returned as a
    /// tuple so a test can wire a pane's callback or drive its hooks directly.
    private func makeRoot(
        settings: AppSettings? = nil,
        loginItem: LoginItemManaging? = nil,
        excluded: ExcludedAppsController? = nil
    ) -> (root: SettingsRootViewController,
          general: GeneralSettingsViewController,
          appearance: AppearanceSettingsViewController,
          audio: AudioSettingsViewController) {
        let general = GeneralSettingsViewController(loginItem: loginItem ?? FakeLoginItem(enabled: false))
        let appearance = AppearanceSettingsViewController(settings: settings ?? makeSettings())
        let audio = AudioSettingsViewController(excluded: excluded ?? makeExcluded(),
                                                runningAppsProvider: { [] })
        let root = SettingsRootViewController(sections: [
            .init(title: "General", symbolName: "gearshape", viewController: general),
            .init(title: "Appearance", symbolName: "paintpalette", viewController: appearance),
            .init(title: "Audio", symbolName: "speaker.wave.2", viewController: audio),
        ])
        return (root, general, appearance, audio)
    }

    /// D2 (live build review 2026-08-07): Settings sits on the ONE surface
    /// canvas — the flat warm `panel` fill (`WarmPanelView`) the Groups
    /// content pane draws — not the retired stock `.windowBackground`
    /// material. Opaque by construction, so no Reduce Transparency cover is
    /// needed (or present) any more.
    @Test func backgroundIsTheUnifiedWarmPanelCanvas() throws {
        let (root, _, _, _) = makeRoot()
        _ = root.view  // force viewDidLoad, which builds the background
        let background = try #require(root.test_background)

        #expect(background is WarmPanelView,
                "Settings draws the same flat panel canvas as the Groups content pane")
        #expect(!(background is NSVisualEffectView),
                "the stock material background is retired inside the surface")
    }

    @Test func sectionTitlesInOrder() {
        let (root, _, _, _) = makeRoot()
        #expect(root.sectionTitles == ["General", "Appearance", "Audio"])
    }

    @Test func runSetupAgainForwardsFromGeneralPane() {
        let (_, general, _, _) = makeRoot()
        var fired = 0
        general.onRunSetupAgain = { fired += 1 }
        general.test_tapRunSetupAgain()
        #expect(fired == 1, "Open Setup… routes from the General pane out to the app")
    }

    /// Roadmap 054: only a release build carries a Sparkle updater, so an
    /// unwired `onCheckForUpdates` must leave the button off screen rather than
    /// inert — an update affordance that cannot work is worse than none.
    /// The panes are built directly here, NOT through `makeRoot`: mounting a
    /// pane on `SettingsRootViewController` loads its view during that init (the
    /// root measures its fitted size there), and the button's visibility is
    /// decided in `loadView`. The app wires this callback before it builds the
    /// root — `AppDelegate.makeSettingsRoot` — so this is the app's own order.
    @Test func checkForUpdatesIsHiddenWithoutAnUpdaterAndForwardsWithOne() {
        let withoutUpdater = GeneralSettingsViewController(loginItem: FakeLoginItem(enabled: false))
        #expect(!withoutUpdater.test_checkForUpdatesIsVisible,
                "no updater wired ⇒ no Check for Updates… button")

        let withUpdater = GeneralSettingsViewController(loginItem: FakeLoginItem(enabled: false))
        var fired = 0
        withUpdater.onCheckForUpdates = { fired += 1 }
        #expect(withUpdater.test_checkForUpdatesIsVisible)
        withUpdater.test_tapCheckForUpdates()
        #expect(fired == 1, "Check for Updates… routes from the General pane out to the app")
    }

    // MARK: License soft check (General pane)

    private static let licenseServer = URL(string: "https://license.example.com")!
    private static let buyPage = URL(string: "https://audiout.app/buy")!

    /// A settings value shaped like a PAID build: it knows a license server and
    /// a buy page. A build from source has neither, which is the other half of
    /// every assertion below.
    private func makePaidBuildSettings() -> AppSettings {
        AppSettings(defaults: isolation.makeDefaults(),
                    licenseServerURL: Self.licenseServer,
                    buyURL: Self.buyPage)
    }

    /// Answers every validate request with one canned reply.
    private final class StubTransport: @unchecked Sendable {
        var answer: (Data?, URLResponse?, Error?) = (nil, nil, URLError(.notConnectedToInternet))

        func replies(_ json: String) {
            answer = (Data(json.utf8),
                      HTTPURLResponse(url: SettingsRootViewControllerTests.licenseServer,
                                      statusCode: 200, httpVersion: nil, headerFields: nil),
                      nil)
        }

        var closure: LicenseValidator.Transport {
            { [self] _, completion in completion(answer.0, answer.1, answer.2) }
        }
    }

    /// Lets the validator's main-queue completion (and the refresh it drives)
    /// run before the next assertion. FIFO on the main queue is what makes this
    /// deterministic rather than a sleep.
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// A build run from source has no license server, so it has nothing to
    /// verify and nothing to sell — the whole license surface stays silent
    /// rather than telling the user something it cannot know.
    @Test func aBuildWithNoLicenseServerSaysNothingAboutLicensing() {
        let general = GeneralSettingsViewController(loginItem: FakeLoginItem(enabled: false),
                                                    settings: makeSettings())
        #expect(general.test_licenseStatusText == nil)
        #expect(!general.test_buyButtonIsVisible)
    }

    /// The status line's copy for every state the server can put the app in,
    /// driven through the real commit path with a stubbed transport.
    @Test func licenseStatusLineSpeaksEachState() async {
        let settings = makePaidBuildSettings()
        let transport = StubTransport()
        let general = GeneralSettingsViewController(loginItem: FakeLoginItem(enabled: false),
                                                    settings: settings)
        general.licenseTransport = transport.closure

        #expect(general.test_licenseStatusText == "Unregistered. Buy a license to support Audiouter and get updates.")

        transport.replies(#"{"status":"active"}"#)
        general.test_setLicenseKey("AUDR-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(general.test_licenseStatusText == "Registered. Thank you.")

        transport.replies(#"{"status":"revoked"}"#)
        general.test_setLicenseKey("AUDR-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(general.test_licenseStatusText == "This key was refunded or revoked. It no longer gets updates.")

        transport.replies(#"{"status":"unknown"}"#)
        general.test_setLicenseKey("AUDR-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(general.test_licenseStatusText == "This key isn’t recognised. Check it against your receipt.")

        transport.replies(#"{"status":"invalid"}"#)
        general.test_setLicenseKey("nonsense")
        await drainMainQueue()
        #expect(general.test_licenseStatusText == "That doesn’t look like an Audiouter key (AUDR-XXXXX-XXXXX-XXXXX-XXXXX).")

        // Clearing the key clears the verdict with it, so the next commit —
        // against a server that never answers — lands on "never verified".
        general.test_setLicenseKey("")
        transport.answer = (nil, nil, URLError(.notConnectedToInternet))
        general.test_setLicenseKey("AUDR-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(general.test_licenseStatusText == "Couldn’t reach the license server — will try again next launch.")
    }

    /// A different key is an open question, not the old key's answer: while
    /// the server is asked, the line says "couldn't reach", never "Registered".
    @Test func changingTheKeyDropsThePreviousVerdictImmediately() async {
        let settings = makePaidBuildSettings()
        let transport = StubTransport()
        let general = GeneralSettingsViewController(loginItem: FakeLoginItem(enabled: false),
                                                    settings: settings)
        general.licenseTransport = transport.closure
        transport.replies(#"{"status":"active"}"#)
        general.test_setLicenseKey("AUDR-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(general.test_licenseStatusText == "Registered. Thank you.")

        transport.answer = (nil, nil, URLError(.notConnectedToInternet))
        general.test_setLicenseKey("AUDR-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ")
        #expect(general.test_licenseStatusText == "Couldn’t reach the license server — will try again next launch.")
        await drainMainQueue()
        #expect(general.test_licenseStatusText == "Couldn’t reach the license server — will try again next launch.")
    }

    /// Buying is offered only where it can work and only where it would help.
    @Test func buyButtonAppearsOnlyWhileUnregistered() async {
        let transport = StubTransport()
        let general = GeneralSettingsViewController(loginItem: FakeLoginItem(enabled: false),
                                                    settings: makePaidBuildSettings())
        general.licenseTransport = transport.closure

        #expect(general.test_buyButtonIsVisible, "no key yet ⇒ the offer is the point")

        transport.replies(#"{"status":"active"}"#)
        general.test_setLicenseKey("AUDR-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(!general.test_buyButtonIsVisible, "a registered build is quiet")

        transport.replies(#"{"status":"revoked"}"#)
        general.test_setLicenseKey("AUDR-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(general.test_buyButtonIsVisible, "a key the server won’t honour is worth re-buying")
    }

    /// Owner decision (AGENTS.md): Settings always opens on General. A fresh
    /// root starts there by construction; the surface builds/keeps the root
    /// and owns any reset-on-show policy of its own.
    @Test func freshRootStartsOnGeneral() {
        let (root, general, _, _) = makeRoot()
        #expect(root.selectedSectionIndex == 0)
        #expect(root.test_hostedPaneView === general.view)
    }

    /// Per-pane sizing-bug regression test: EACH section's assembled content
    /// must have a real, non-degenerate size (an earlier build opened at an
    /// AppKit fallback size for an empty container). Bounded per pane rather
    /// than one shared range: a single pane collapsing to near-zero, or
    /// ballooning back toward the pre-split single-screen height, should each
    /// fail this.
    @Test func eachPaneHasANonDegenerateSize() {
        let (root, general, appearance, audio) = makeRoot()
        let panes: [NSViewController] = [general, appearance, audio]
        // Comfortably under the OLD single-screen ceiling (previously ~850pt
        // for all three sections combined).
        let oldSingleScreenCeiling: CGFloat = 850
        for index in 0..<3 {
            root.selectSection(at: index)
            let pane = panes[index].view
            pane.layoutSubtreeIfNeeded()
            let size = pane.fittingSize
            // `accuracy` absorbs AppKit's sub-point fitting-size rounding
            // (a device-pixel autolayout artifact, not a real discrepancy).
            #expect(abs(size.width - SettingsForm.contentWidth) <= 1,
                    Comment(rawValue: "section \(index) (\(root.sectionTitles[index])) wants \(size.width)"))
            #expect(size.height > 50,
                    Comment(rawValue: "section \(index) (\(root.sectionTitles[index])) collapsed to near-zero"))
            #expect(size.height < oldSingleScreenCeiling,
                    Comment(rawValue: "section \(index) (\(root.sectionTitles[index])) is still oversized"))
        }
    }

    /// THE structural guard: selecting a section swaps the ONE hosted pane,
    /// and it goes through **real sidebar selection** — `selectSection(at:)`
    /// moves the outline view's selection and the swap arrives back through
    /// the delegate. A `test_` hook that bypassed real AppKit dispatch once
    /// let genuinely broken UI stay green across 78 tests
    /// (`MainOutRowView.selectionChanged`), so the hook drives the real path.
    @Test func selectingASectionSwapsThePaneThroughRealSidebarSelection() {
        let (root, general, appearance, audio) = makeRoot()
        let panes: [NSViewController] = [general, appearance, audio]
        for index in 0..<3 {
            root.selectSection(at: index)
            #expect(root.selectedSectionIndex == index)
            #expect(root.test_hostedPaneView === panes[index].view,
                    Comment(rawValue: "section \(index) (\(root.sectionTitles[index])) never became the hosted pane"))
        }
    }

    /// The sidebar is the Groups screen's own arrangement, at the same pinned
    /// thickness — that is what lets both arrangement screens sit inside the
    /// one fixed surface frame without asking AppKit to widen it. And it must
    /// never collapse: it is the only way to change section, and the surface
    /// has no sidebar toggle and no View menu to bring it back.
    @Test func sidebarIsPinnedToTheGroupsSidebarWidthAndCannotCollapse() {
        let (root, _, _, _) = makeRoot()
        #expect(root.splitViewItems.count == 2)
        let sidebar = root.test_sidebarSplitItem
        #expect(sidebar.minimumThickness == SurfaceLayout.sidebarWidth)
        #expect(sidebar.maximumThickness == SurfaceLayout.sidebarWidth)
        #expect(!sidebar.canCollapse)
        #expect(!sidebar.isCollapsed)
    }

    /// The pane is TOP-ALIGNED inside the host's scroll view and never
    /// stretched to the window: the surface frame is fixed, so a short pane
    /// leaves calm canvas below it rather than being centered or grown, and
    /// the scroll document is exactly as tall as the pane needs.
    @Test func paneIsTopAlignedAndNeverStretched() throws {
        let (root, general, _, _) = makeRoot()
        root.view.setFrameSize(NSSize(width: SurfaceLayout.width, height: 800))
        root.view.layoutSubtreeIfNeeded()

        let pane = try #require(root.test_hostedPaneView)
        #expect(pane === general.view)
        #expect(pane.frame.minY == 0,
                Comment(rawValue: "the pane must start at the document's top, got \(pane.frame.minY)"))
        #expect(abs(pane.frame.height - pane.fittingSize.height) <= 1,
                Comment(rawValue: "the pane must keep its own height in an 800pt-tall host, got " +
                "\(pane.frame.height) for a fitting height of \(pane.fittingSize.height)"))
        #expect(abs(root.test_scrollDocumentHeight - pane.fittingSize.height) <= 1,
                Comment(rawValue: "the scroll document must be exactly as tall as the pane, got " +
                "\(root.test_scrollDocumentHeight)"))
    }

    /// A pane that grows at RUNTIME with no section switch
    /// (`AudioSettingsViewController.rebuildList()` when the excluded-apps
    /// list changes) grows the SCROLL DOCUMENT, not the window — the frame is
    /// fixed, so the extra rows become scrollable content.
    @Test func audioPaneGrowthGrowsTheScrollDocument() {
        let (root, _, _, audio) = makeRoot()
        root.selectSection(at: 2) // Audio
        let before = root.test_scrollDocumentHeight

        audio.test_addExcluded(bundleID: "us.zoom.xos", displayName: "Zoom")

        #expect(root.test_scrollDocumentHeight > before,
                Comment(rawValue: "adding an excluded-app row must grow the scroll document, " +
                "was \(before), now \(root.test_scrollDocumentHeight)"))
    }

    @Test func audioExcludeAndRemoveDrivesTheModelAndNotifies() {
        let excluded = makeExcluded()
        let audio = AudioSettingsViewController(excluded: excluded, runningAppsProvider: { [] })
        var changes = 0
        audio.onChange = { changes += 1 }

        audio.test_addExcluded(bundleID: "us.zoom.xos", displayName: "Zoom")
        #expect(audio.test_excludedBundleIDs == ["us.zoom.xos"])
        #expect(excluded.isExcluded("us.zoom.xos"))
        #expect(changes == 1)

        // Excluding the same app again is a no-op (no duplicate, no extra notify).
        audio.test_addExcluded(bundleID: "us.zoom.xos", displayName: "Zoom")
        #expect(audio.test_excludedBundleIDs == ["us.zoom.xos"])

        audio.test_removeExcluded(bundleID: "us.zoom.xos")
        #expect(audio.test_excludedBundleIDs == [])
        #expect(!excluded.isExcluded("us.zoom.xos"))
    }

    @Test func launchAtLoginReflectsLiveStateOnSync() {
        let login = FakeLoginItem(enabled: true)
        let general = GeneralSettingsViewController(loginItem: login)
        general.test_syncFromLoginItem()
        #expect(general.test_launchAtLoginIsOn)
    }

    @Test func togglingLaunchAtLoginDrivesTheSeam() {
        let login = FakeLoginItem(enabled: false)
        let general = GeneralSettingsViewController(loginItem: login)
        general.test_toggleLaunchAtLogin(true)
        #expect(login.enabled)
        #expect(login.setCallCount == 1)
        #expect(general.test_launchAtLoginIsOn)
    }

    @Test func failedLaunchAtLoginChangeRevertsTheSwitch() {
        let login = FakeLoginItem(enabled: false)
        login.refuse = true
        let general = GeneralSettingsViewController(loginItem: login)
        general.test_toggleLaunchAtLogin(true)
        // The system refused: state stays off and the switch bounces back.
        #expect(!login.enabled)
        #expect(!general.test_launchAtLoginIsOn)
    }

    @Test func selectingThemePersistsAndNotifies() {
        let settings = makeSettings()
        let appearance = AppearanceSettingsViewController(settings: settings)
        var applied: [AppearanceTheme] = []
        appearance.onThemeChanged = { applied.append($0) }

        appearance.test_selectTheme(.dark)
        #expect(appearance.test_selectedTheme == .dark)
        #expect(settings.theme == .dark)
        #expect(applied == [.dark])
    }

    @Test func appearancePaneInitialisesFromPersistedTheme() {
        let settings = makeSettings()
        settings.theme = .light
        let appearance = AppearanceSettingsViewController(settings: settings)
        // `test_selectedTheme` forces the lazy view load, then reads the selection.
        #expect(appearance.test_selectedTheme == .light)
    }

    // MARK: Theme tile VoiceOver selected-state (A11Y-LABELS)

    /// Before this fix all three tiles sounded identical to VoiceOver — only
    /// the currently-selected theme's tile should report itself as AX-selected.
    @Test func onlyTheSelectedThemeTileReportsAccessibilitySelected() {
        let settings = makeSettings()
        settings.theme = .dark
        let appearance = AppearanceSettingsViewController(settings: settings)

        #expect(appearance.test_isTileAccessibilitySelected(.dark))
        #expect(!appearance.test_isTileAccessibilitySelected(.light))
        #expect(!appearance.test_isTileAccessibilitySelected(.system))
    }

    /// Picking a different tile flips the AX-selected state live, so a
    /// VoiceOver user re-querying the picker hears the new selection.
    @Test func tappingATileMovesAccessibilitySelectedStateToIt() {
        let settings = makeSettings()
        let appearance = AppearanceSettingsViewController(settings: settings)

        appearance.test_selectTheme(.light)
        #expect(appearance.test_isTileAccessibilitySelected(.light))
        #expect(!appearance.test_isTileAccessibilitySelected(.dark))

        appearance.test_selectTheme(.dark)
        #expect(appearance.test_isTileAccessibilitySelected(.dark))
        #expect(!appearance.test_isTileAccessibilitySelected(.light))
    }
}
