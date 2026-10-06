// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
import AudioutSharedUI
@testable import AudioutCore
@testable import AudioutSettingsUI

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
        /// Stands in for `SMAppService`'s `.requiresApproval`: `setEnabled`
        /// succeeds, but the item never actually becomes enabled.
        var approvalRequired = false
        private(set) var setCallCount = 0
        private(set) var openLoginItemsCallCount = 0
        init(enabled: Bool) { self.enabled = enabled }

        var isEnabled: Bool { enabled }
        func setEnabled(_ newValue: Bool) throws {
            setCallCount += 1
            if refuse { throw NSError(domain: "test", code: 1) }
            if approvalRequired { return }
            enabled = newValue
        }

        var needsApproval: Bool { approvalRequired }
        func openSystemSettingsLoginItems() { openLoginItemsCallCount += 1 }
    }

    private let isolation = TestIsolation(owner: "SettingsRootViewControllerTests")

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: isolation.makeDefaults())
    }

    /// An excluded-apps controller over a throwaway temp store (never the real
    /// `~/Library/Application Support`).
    private func makeExcluded() -> ExcludedAppsController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioutTests-\(UUID().uuidString)", isDirectory: true)
        return ExcludedAppsController(store: ExcludedAppsStore(directory: dir))
    }

    /// The panes + root, assembled like the app assembles them, all five
    /// sections built. Returned as a tuple so a test can wire a pane's
    /// callback or drive its hooks directly.
    private func makeRoot(
        settings: AppSettings? = nil,
        loginItem: LoginItemManaging? = nil,
        excluded: ExcludedAppsController? = nil,
        latency: LatencySettingModel? = nil,
        licenseTransport: LicenseValidator.Transport? = nil
    ) -> (root: SettingsRootViewController,
          general: GeneralSettingsViewController,
          remote: RemoteSettingsViewController,
          appearance: AppearanceSettingsViewController,
          audio: AudioSettingsViewController,
          license: LicenseSettingsViewController) {
        let settings = settings ?? makeSettings()
        let general = GeneralSettingsViewController(loginItem: loginItem ?? FakeLoginItem(enabled: false))
        let remote = RemoteSettingsViewController(settings: settings, remoteAppIsOffered: true)
        let appearance = AppearanceSettingsViewController(settings: settings)
        let audio = AudioSettingsViewController(excluded: excluded ?? makeExcluded(),
                                                runningAppsProvider: { [] },
                                                latency: latency)
        let license = LicenseSettingsViewController(settings: settings)
        license.licenseTransport = licenseTransport
        let root = SettingsRootViewController(sections: [
            .init(title: "General", symbolName: "gearshape", viewController: general),
            .init(title: "Audiout Remote", symbolName: "iphone", viewController: remote),
            .init(title: "Appearance", symbolName: "paintpalette", viewController: appearance),
            .init(title: "Audio", symbolName: "speaker.wave.2", viewController: audio),
            .init(title: "License", symbolName: "key", viewController: license),
        ])
        return (root, general, remote, appearance, audio, license)
    }

    /// Whether two inks are the same colour in both appearances. Token inks
    /// are dynamic colours, so two reads of one token need not be the same
    /// object.
    private func sameInk(_ a: NSColor, _ b: NSColor) -> Bool {
        [NSAppearance.Name.aqua, .darkAqua].allSatisfy { name in
            var match = false
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                match = a.usingColorSpace(.sRGB) == b.usingColorSpace(.sRGB)
            }
            return match
        }
    }

    /// D2 (live build review 2026-08-07): Settings sits on the ONE surface
    /// canvas — the flat warm `panel` fill (`WarmPanelView`) the Groups
    /// content pane draws — not the retired stock `.windowBackground`
    /// material. Opaque by construction, so no Reduce Transparency cover is
    /// needed (or present) any more.
    @Test func backgroundIsTheUnifiedWarmPanelCanvas() throws {
        let (root, _, _, _, _, _) = makeRoot()
        _ = root.view  // force viewDidLoad, which builds the background
        let background = try #require(root.test_background)

        #expect(background is WarmPanelView,
                "Settings draws the same flat panel canvas as the Groups content pane")
        #expect(!(background is NSVisualEffectView),
                "the stock material background is retired inside the surface")
    }

    @Test func sectionTitlesInOrder() {
        let (root, _, _, _, _, _) = makeRoot()
        #expect(root.sectionTitles == ["General", "Audiout Remote", "Appearance", "Audio", "License"])
    }

    @Test func runSetupAgainForwardsFromGeneralPane() {
        let (_, general, _, _, _, _) = makeRoot()
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

    // MARK: License soft check (License pane)

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
        let license = LicenseSettingsViewController(settings: makeSettings())
        #expect(license.test_licenseStatusText == nil)
        #expect(!license.test_wellIsVisible, "the whole License surface stays hidden")
        #expect(!license.test_buyButtonIsVisible)
    }

    /// The status line's copy for every state the server can put the app in,
    /// driven through the real commit path with a stubbed transport.
    @Test func licenseStatusLineSpeaksEachState() async {
        let settings = makePaidBuildSettings()
        let transport = StubTransport()
        let license = LicenseSettingsViewController(settings: settings)
        license.licenseTransport = transport.closure

        #expect(license.test_licenseStatusText == "Unregistered. Audiout keeps working, on one speaker at a time, until it has a license key.")
        #expect(license.test_enterLicenseButtonTitle == "Enter license…")

        transport.replies(#"{"status":"active"}"#)
        license.test_setLicenseKey("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(license.test_licenseStatusText == "Registered. Thank you for supporting Audiout.")
        #expect(license.test_enterLicenseButtonTitle == "Change…")

        // A revoked answer limits the install to one speaker, and the line
        // names the server's reason; a reason the app does not know, or none,
        // reads as a plain revocation.
        let revokedLines: [(reason: String?, line: String)] = [
            ("trial_expired", "Your trial has ended. Audiout plays on one speaker at a time until you buy."),
            ("refund", "This key was refunded, so Audiout plays on one speaker at a time."),
            ("chargeback", "This key’s payment was reversed, so Audiout plays on one speaker at a time."),
            ("manual", "This key was revoked, so Audiout plays on one speaker at a time."),
            (nil, "This key was revoked, so Audiout plays on one speaker at a time."),
        ]
        for (reason, line) in revokedLines {
            transport.replies(reason.map { #"{"status":"revoked","reason":"\#($0)"}"# } ?? #"{"status":"revoked"}"#)
            license.test_setLicenseKey("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
            await drainMainQueue()
            #expect(license.test_licenseStatusText == line, Comment(rawValue: "reason \(reason ?? "nil")"))
        }

        transport.replies(#"{"status":"unknown"}"#)
        license.test_setLicenseKey("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(license.test_licenseStatusText == "This key isn’t recognized. Check it against your receipt.")

        transport.replies(#"{"status":"invalid"}"#)
        license.test_setLicenseKey("nonsense")
        await drainMainQueue()
        #expect(license.test_licenseStatusText == "That doesn’t look like an Audiout key (AUDT-XXXXX-XXXXX-XXXXX-XXXXX).")

        // Removing the key (the sheet's explicit button) clears the verdict
        // with it, so the next commit — against a server that never answers —
        // lands on "never verified".
        license.test_removeLicense()
        transport.answer = (nil, nil, URLError(.notConnectedToInternet))
        license.test_setLicenseKey("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(license.test_licenseStatusText == "Your key is saved. Audiout hasn’t been able to verify it yet.")
    }

    /// A different key is an open question, not the old key's answer: while
    /// the server is asked, the line says "couldn't reach", never "Registered".
    @Test func changingTheKeyDropsThePreviousVerdictImmediately() async {
        let settings = makePaidBuildSettings()
        let transport = StubTransport()
        let license = LicenseSettingsViewController(settings: settings)
        license.licenseTransport = transport.closure
        transport.replies(#"{"status":"active"}"#)
        license.test_setLicenseKey("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(license.test_licenseStatusText == "Registered. Thank you for supporting Audiout.")

        transport.answer = (nil, nil, URLError(.notConnectedToInternet))
        license.test_setLicenseKey("AUDT-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ")
        #expect(license.test_licenseStatusText == "Your key is saved. Audiout hasn’t been able to verify it yet.")
        await drainMainQueue()
        #expect(license.test_licenseStatusText == "Your key is saved. Audiout hasn’t been able to verify it yet.")
    }

    /// Buying is offered only where it can work and only where it would help.
    @Test func buyButtonAppearsOnlyWhileUnregistered() async {
        let transport = StubTransport()
        let license = LicenseSettingsViewController(settings: makePaidBuildSettings())
        license.licenseTransport = transport.closure

        #expect(license.test_buyButtonIsVisible, "no key yet ⇒ the offer is the point")

        transport.replies(#"{"status":"active"}"#)
        license.test_setLicenseKey("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(!license.test_buyButtonIsVisible, "a registered build is quiet")

        transport.replies(#"{"status":"revoked"}"#)
        license.test_setLicenseKey("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(license.test_buyButtonIsVisible, "a key the server won’t honour is worth re-buying")
    }

    /// Red if a trial that ran out with an active verdict cached (offline, or
    /// before the launch check answers) hid Buy and called the key active
    /// while the app plays on one speaker.
    @Test func anExpiredTrialWithACachedActiveVerdictShowsBuyAndTheTrialEndedLine() {
        let settings = makePaidBuildSettings()
        settings.licenseKey = "AUDT-AAAAA-BBBBB-CCCCC-DDDDD"
        settings.licenseStatus = .active
        settings.trialStartedAt = Date().addingTimeInterval(-20 * 86_400)
        settings.trialExpiresAt = Date().addingTimeInterval(-6 * 86_400)
        let license = LicenseSettingsViewController(settings: settings)
        #expect(license.test_buyButtonIsVisible)
        #expect(license.test_licenseStatusText
                == "Your trial has ended. Audiout plays on one speaker at a time until you buy.")
    }

    /// Red if Settings told a limited install something untrue: an ended
    /// trial, which the server answers with `revoked` and reason
    /// `trial_expired`, read "refunded or revoked", or a refused key stopped
    /// naming the server's reason the way the popover note does.
    @Test(arguments: [
        ("trial_expired", "Your trial has ended. Audiout plays on one speaker at a time until you buy."),
        ("refund", "This key was refunded, so Audiout plays on one speaker at a time."),
        ("chargeback", "This key\u{2019}s payment was reversed, so Audiout plays on one speaker at a time."),
        (nil, "This key was revoked, so Audiout plays on one speaker at a time."),
    ] as [(String?, String)])
    func aRevokedKeyNamesTheServersReason(reason: String?, expected: String) {
        let settings = makePaidBuildSettings()
        settings.licenseKey = "AUDT-AAAAA-BBBBB-CCCCC-DDDDD"
        settings.licenseStatus = .revoked
        settings.licenseReason = reason
        let license = LicenseSettingsViewController(settings: settings)
        #expect(license.test_licenseStatusText == expected)
    }

    /// The sheet is the ONE commit path, and its edges hold: Cancel discards
    /// typed text (no more silent commit-on-focus-loss), Remove License… is
    /// offered only once a key is stored and clears key + verdict together.
    @Test func licenseSheetCancelDiscardsAndRemoveClears() async {
        let settings = makePaidBuildSettings()
        let transport = StubTransport()
        let license = LicenseSettingsViewController(settings: settings)
        license.licenseTransport = transport.closure
        _ = license.view

        // Cancel: typed text never lands in settings.
        license.test_tapEnterLicense()
        let sheet = license.test_licenseSheet
        #expect(sheet?.test_removeIsVisible == false, "nothing stored yet — nothing to remove")
        sheet?.test_setKeyText("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        sheet?.test_tapCancel()
        #expect(settings.licenseKey == nil, "Cancel writes nothing")
        #expect(license.test_licenseSheet == nil, "the pane lets the sheet go")

        // Register, then Remove through a fresh sheet.
        transport.replies(#"{"status":"active"}"#)
        license.test_setLicenseKey("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(settings.licenseKey != nil)

        license.test_tapEnterLicense()
        #expect(license.test_licenseSheet?.test_removeIsVisible == true)
        license.test_licenseSheet?.test_tapRemove()
        #expect(settings.licenseKey == nil)
        #expect(settings.licenseStatus == nil, "the verdict goes with the key")
        #expect(license.test_enterLicenseButtonTitle == "Enter license…")
    }

    /// The status line promises the key is saved, not that a retry is coming
    /// at some unnamed later launch — so the retry is a button, and it works
    /// in-session: the same pane goes from "not verified" to "Registered"
    /// without a relaunch, and the button leaves once it has nothing to do.
    @Test func checkAgainRevalidatesInSession() async {
        let transport = StubTransport()   // starts unreachable
        let license = LicenseSettingsViewController(settings: makePaidBuildSettings())
        license.licenseTransport = transport.closure

        license.test_setLicenseKey("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(license.test_licenseStatusText == "Your key is saved. Audiout hasn’t been able to verify it yet.")
        #expect(license.test_checkAgainIsVisible)

        transport.replies(#"{"status":"active"}"#)
        license.test_tapCheckAgain()
        await drainMainQueue()
        #expect(license.test_licenseStatusText == "Registered. Thank you for supporting Audiout.")
        #expect(!license.test_checkAgainIsVisible, "nothing left to check")
    }

    /// The other retry trigger, and the one that costs the user nothing:
    /// coming back to the pane re-asks whenever no verdict has ever landed.
    @Test func returningToThePaneRevalidatesAnUnansweredKey() async {
        let transport = StubTransport()   // starts unreachable
        let license = LicenseSettingsViewController(settings: makePaidBuildSettings())
        license.licenseTransport = transport.closure

        license.test_setLicenseKey("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(license.test_licenseStatusText == "Your key is saved. Audiout hasn’t been able to verify it yet.")

        transport.replies(#"{"status":"active"}"#)
        license.viewWillAppear()
        await drainMainQueue()
        #expect(license.test_licenseStatusText == "Registered. Thank you for supporting Audiout.")
    }

    /// The once-per-launch check-in is disclosed where it happens, and ONLY
    /// where it happens: no key means no check-in, so claiming one would be a
    /// lie in the other direction.
    @Test func checkInDisclosureAppearsExactlyWhileAKeyIsStored() async {
        let transport = StubTransport()
        let license = LicenseSettingsViewController(settings: makePaidBuildSettings())
        license.licenseTransport = transport.closure

        #expect(license.test_checkInDisclosureText == nil, "no key ⇒ no check-in to disclose")

        transport.replies(#"{"status":"active"}"#)
        license.test_setLicenseKey("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(license.test_checkInDisclosureText == "Audiout checks in with the license server once per launch to spot a key shared across many machines. It sends your key, a random per-Mac id, and the app version. Nothing else.")

        license.test_removeLicense()
        #expect(license.test_checkInDisclosureText == nil)
    }

    /// A rejected Register writes the key anyway (the commit is deliberate),
    /// so the sheet must offer the way back out — Remove — without a close and
    /// re-open.
    @Test func aRejectedRegisterRevealsRemoveInTheSheet() async {
        let transport = StubTransport()
        let license = LicenseSettingsViewController(settings: makePaidBuildSettings())
        license.licenseTransport = transport.closure
        transport.replies(#"{"status":"unknown"}"#)

        license.test_tapEnterLicense()
        let sheet = license.test_licenseSheet
        sheet?.test_setKeyText("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        sheet?.test_tapRegister()
        await drainMainQueue()

        #expect(license.test_licenseSheet != nil, "a rejected key keeps the sheet open")
        #expect(sheet?.test_resultText == "This key isn’t recognized. Check it against your receipt.")
        #expect(sheet?.test_removeIsVisible == true)
    }

    /// A second `audiout://register` link that arrives while the first key is
    /// still being checked is DROPPED, not stacked: Register is disabled for
    /// exactly that window, and restarting the commit under the answer the user
    /// is waiting for would leave the sheet describing the wrong key.
    @Test func aSecondRegisterLinkDuringTheCheckIsDropped() async {
        /// Records each request and never answers, so the first commit stays in
        /// flight for the whole test.
        final class HeldTransport: @unchecked Sendable {
            private(set) var requests = 0
            var closure: LicenseValidator.Transport {
                { [self] _, _ in requests += 1 }
            }
        }

        let held = HeldTransport()
        let settings = makePaidBuildSettings()
        let license = LicenseSettingsViewController(settings: settings)
        license.licenseTransport = held.closure

        license.presentLicenseSheet(registering: "AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(held.requests == 1)
        #expect(license.test_licenseSheet?.test_resultText == "Checking…")

        license.presentLicenseSheet(registering: "AUDT-EEEEE-FFFFF-GGGGG-HHHHH")
        await drainMainQueue()
        #expect(held.requests == 1, "the second link is dropped while the first is unanswered")
        #expect(settings.licenseKey == "AUDT-AAAAA-BBBBB-CCCCC-DDDDD",
                "the in-flight key stands — the second link never committed")
    }

    /// The owner's 2026-09-26 screenshot: a revoked key shows the longest
    /// verdict sentence AND Remove, and the old one-row strip of four buttons
    /// squeezed Register to "Re" (which button AppKit squeezes is arbitrary
    /// when they tie, so every button is checked). Putting a third button back
    /// in the Cancel/Register row turns this red; so does a result line that
    /// stops wrapping and widens the sheet.
    @Test func revokedKeySheetNeverClipsRegister() async throws {
        let transport = StubTransport()
        let license = LicenseSettingsViewController(settings: makePaidBuildSettings())
        license.licenseTransport = transport.closure
        transport.replies(#"{"status":"revoked"}"#)

        license.test_tapEnterLicense()
        let sheet = try #require(license.test_licenseSheet)
        sheet.test_setKeyText("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        sheet.test_tapRegister()
        await drainMainQueue()
        #expect(sheet.test_removeIsVisible)
        #expect(sheet.test_resultText == LicenseCopy.statusLine(for: .revoked, reason: nil))

        let container = sheet.view
        container.layoutSubtreeIfNeeded()
        let fitting = container.fittingSize
        #expect(abs(fitting.width - 360) <= 1,
                Comment(rawValue: "the sheet must stay 320pt of content plus 20pt insets, got \(fitting.width)"))
        container.setFrameSize(fitting)
        container.layoutSubtreeIfNeeded()

        let register = sheet.test_registerButton
        #expect(register.frame.width >= register.intrinsicContentSize.width - 0.5,
                Comment(rawValue: "Register is \(register.frame.width)pt wide, needs \(register.intrinsicContentSize.width)"))
        let inContainer = register.convert(register.bounds, to: container)
        #expect(container.bounds.insetBy(dx: -0.5, dy: -0.5).contains(inContainer),
                Comment(rawValue: "Register at \(inContainer) falls outside the sheet's \(container.bounds)"))

        func visibleButtons(in view: NSView) -> [NSButton] {
            view.subviews.filter { !$0.isHidden }.flatMap { sub in
                (sub as? NSButton).map { [$0] } ?? visibleButtons(in: sub)
            }
        }
        let buttons = visibleButtons(in: container)
        #expect(buttons.count == 3, "Remove, Cancel, Register")
        for button in buttons {
            #expect(button.frame.width >= button.intrinsicContentSize.width - 0.5,
                    Comment(rawValue: "\(button.title) is \(button.frame.width)pt wide, needs \(button.intrinsicContentSize.width)"))
        }
        let rows = Dictionary(grouping: buttons) { Int(($0.convert($0.bounds, to: container).midY).rounded()) }
        #expect(rows.values.allSatisfy { $0.count <= 2 },
                Comment(rawValue: "no row may hold more than two buttons: \(rows.values.map { $0.map(\.title) })"))
    }

    /// `SMAppService.register()` succeeds into `.requiresApproval` without
    /// throwing, so the switch springs back with nothing said. It must say
    /// something, and offer the one click that fixes it.
    @Test func launchAtLoginNeedingApprovalRevertsAndExplains() {
        let login = FakeLoginItem(enabled: false)
        login.approvalRequired = true
        let general = GeneralSettingsViewController(loginItem: login)

        general.test_toggleLaunchAtLogin(true)
        #expect(!general.test_launchAtLoginIsOn, "the switch must not claim a state macOS is withholding")
        #expect(general.test_loginApprovalHintIsVisible)

        general.test_tapOpenLoginItems()
        #expect(login.openLoginItemsCallCount == 1)
    }

    /// Owner decision (AGENTS.md): Settings always opens on General. A fresh
    /// root starts there by construction; the surface builds/keeps the root
    /// and owns any reset-on-show policy of its own.
    @Test func freshRootStartsOnGeneral() {
        let (root, general, _, _, _, _) = makeRoot()
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
        let (root, general, remote, appearance, audio, license) = makeRoot()
        let panes: [NSViewController] = [general, remote, appearance, audio, license]
        // Comfortably under the OLD single-screen ceiling (previously ~850pt
        // for all three sections combined).
        let oldSingleScreenCeiling: CGFloat = 850
        for index in panes.indices {
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
        let (root, general, remote, appearance, audio, license) = makeRoot()
        let panes: [NSViewController] = [general, remote, appearance, audio, license]
        for index in panes.indices {
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
        let (root, _, _, _, _, _) = makeRoot()
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
        let (root, general, _, _, _, _) = makeRoot()
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

    /// The Login Items approval row is mounted and unmounted, never hidden
    /// in place: an `NSStackView` keeps a hidden child's last height. The
    /// document must return to exactly its pre-approval height.
    @Test func loginApprovalRowGivesItsHeightBack() throws {
        let login = FakeLoginItem(enabled: false)
        let (root, general, _, _, _, _) = makeRoot(loginItem: login)
        root.view.setFrameSize(NSSize(width: SurfaceLayout.width, height: 800))
        general.test_syncFromLoginItem()
        let baseline = root.test_scrollDocumentHeight

        login.approvalRequired = true
        general.test_syncFromLoginItem()
        #expect(general.test_loginApprovalHintIsVisible)
        #expect(root.test_scrollDocumentHeight > baseline,
                Comment(rawValue: "the approval row must add height, was \(baseline), " +
                "now \(root.test_scrollDocumentHeight)"))

        login.approvalRequired = false
        general.test_syncFromLoginItem()
        #expect(!general.test_loginApprovalHintIsVisible)
        #expect(abs(root.test_scrollDocumentHeight - baseline) <= 1,
                Comment(rawValue: "the pane must give the approval row's height back, " +
                "expected \(baseline), got \(root.test_scrollDocumentHeight)"))
    }

    /// A pane that grows at RUNTIME with no section switch
    /// (`AudioSettingsViewController.rebuildList()` when the excluded-apps
    /// list changes) grows the SCROLL DOCUMENT, not the window — the frame is
    /// fixed, so the extra rows become scrollable content.
    @Test func audioPaneGrowthGrowsTheScrollDocument() {
        let (root, _, _, _, audio, _) = makeRoot()
        root.selectSection(at: 3) // Audio
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

    // MARK: Sidebar readouts

    /// Red if the License row's readout stops following the licence state,
    /// or its glyph stops taking `ring` exactly while the user must act.
    @Test func licenseReadoutFollowsEveryState() async {
        let transport = StubTransport()
        let (root, _, _, _, _, license) = makeRoot(settings: makePaidBuildSettings(),
                                                   licenseTransport: transport.closure)
        let limited = "One speaker at a time"

        #expect(root.test_readoutLines(at: 4) == ["Unregistered", limited])
        #expect(sameInk(root.test_glyphTint(at: 4), Tokens.Color.ring))

        transport.replies(#"{"status":"active"}"#)
        license.test_setLicenseKey("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(root.test_readoutLines(at: 4) == ["Registered"])
        #expect(sameInk(root.test_glyphTint(at: 4), Tokens.Color.labelCool))

        let revoked: [(reason: String?, line: String)] = [
            ("refund", "Key refunded"),
            ("chargeback", "Payment reversed"),
            (nil, "Key revoked"),
        ]
        for (reason, line) in revoked {
            transport.replies(reason.map { #"{"status":"revoked","reason":"\#($0)"}"# } ?? #"{"status":"revoked"}"#)
            license.test_setLicenseKey("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
            await drainMainQueue()
            #expect(root.test_readoutLines(at: 4) == [line, limited], Comment(rawValue: "reason \(reason ?? "nil")"))
            #expect(sameInk(root.test_glyphTint(at: 4), Tokens.Color.ring))
        }

        transport.replies(#"{"status":"unknown"}"#)
        license.test_setLicenseKey("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(root.test_readoutLines(at: 4) == ["Key not recognized", limited])
        #expect(sameInk(root.test_glyphTint(at: 4), Tokens.Color.ring))

        transport.replies(#"{"status":"invalid"}"#)
        license.test_setLicenseKey("nonsense")
        await drainMainQueue()
        #expect(root.test_readoutLines(at: 4) == ["Not an Audiout key", limited])
        #expect(sameInk(root.test_glyphTint(at: 4), Tokens.Color.ring))

        license.test_removeLicense()
        transport.answer = (nil, nil, URLError(.notConnectedToInternet))
        license.test_setLicenseKey("AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        await drainMainQueue()
        #expect(root.test_readoutLines(at: 4) == ["Key saved, not verified"])
        #expect(sameInk(root.test_glyphTint(at: 4), Tokens.Color.labelCool))
    }

    /// Red if a running trial stops reading as days left, stops naming the
    /// day it ends, or stops offering Buy Audiout as the gold button.
    @Test func aRunningTrialReadsItsDaysAndOffersGoldBuy() {
        let settings = makePaidBuildSettings()
        let expiresAt = Date().addingTimeInterval(9 * 86_400)
        TrialClock.apply(settings: settings, startedAt: Date().addingTimeInterval(-5 * 86_400),
                         expiresAt: expiresAt, key: "AUDT-AAAAA-BBBBB-CCCCC-DDDDD")
        let (root, _, _, _, _, license) = makeRoot(settings: settings)

        #expect(root.test_readoutLines(at: 4) == ["Trial · 9 days left"])
        #expect(license.test_licenseStatusText == "Audiout plays on every speaker until your trial ends on "
                + "\(expiresAt.formatted(.dateTime.day().month(.wide))).")
        #expect(license.test_enterLicenseButtonTitle == "Enter license…")
        #expect(license.test_buyButtonIsVisible)
        #expect(license.test_buyButtonIsProminent)
    }

    /// Red if the General row's readout stops following the login item,
    /// including the approval macOS is holding.
    @Test func generalReadoutFollowsTheLoginItem() {
        let login = FakeLoginItem(enabled: false)
        let (root, general, _, _, _, _) = makeRoot(loginItem: login)
        #expect(root.test_readoutLines(at: 0) == ["Doesn't open at login"])

        general.test_toggleLaunchAtLogin(true)
        #expect(root.test_readoutLines(at: 0) == ["Opens at login"])
        #expect(sameInk(root.test_glyphTint(at: 0), Tokens.Color.labelCool))

        login.approvalRequired = true
        general.test_toggleLaunchAtLogin(false)
        #expect(root.test_readoutLines(at: 0) == ["Needs Login Items approval"])
        #expect(sameInk(root.test_glyphTint(at: 0), Tokens.Color.ring))
    }

    /// Red if the Audio row stops counting excluded apps, stops naming a
    /// buffer other than the default, or stops growing to two lines for it.
    @Test func audioReadoutCountsAppsAndNamesTheBuffer() async {
        let latency = LatencySettingModel(
            optionsMs: AppSettings.startBufferOptionsMs, initialMs: 1000,
            envOverrideMs: nil, isStreaming: { false }, apply: { _ in (0, 0) })
        let (root, _, _, _, audio, _) = makeRoot(latency: latency)
        #expect(root.test_readoutLines(at: 3) == ["No apps stay on this Mac"])
        #expect(root.test_rowHeight(at: 3) == 40)

        audio.test_addExcluded(bundleID: "us.zoom.xos", displayName: "Zoom")
        #expect(root.test_readoutLines(at: 3) == ["1 app stays on this Mac"])

        await audio.test_selectLatencyOption(ms: 1500)
        #expect(root.test_readoutLines(at: 3) == ["1 app stays on this Mac", "Buffer 1500 ms"])
        #expect(root.test_rowHeight(at: 3) == 54)
        #expect(root.test_spokenLabel(at: 3) == "Audio, 1 app stays on this Mac, Buffer 1500 ms")
    }
}

/// `license:enter_sheet_opened` says which door opened the sheet. Nested under
/// `SerializedSharedState` because `Analytics.install` mutates process-global
/// state — the rule in `SerializedSharedStateSuite.swift`.
extension SerializedSharedState {
    @MainActor
    @Suite struct SettingsRootViewControllerTests_LicenseSheetSource {

        private final class Captured: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [(String, [String: String])] = []
            func append(_ name: String, _ props: [String: String]) {
                lock.withLock { items.append((name, props)) }
            }
            func properties(of event: String) -> [[String: String]] {
                lock.withLock { items.filter { $0.0 == event }.map(\.1) }
            }
        }

        private let isolation = TestIsolation(owner: "SettingsRootViewControllerTests_LicenseSheetSource")

        /// Red if the Settings button and the Mixer note's "I have a key" stop
        /// being told apart, so the funnel cannot say which door sells keys.
        @Test func theSheetReportsWhichDoorOpenedIt() {
            let captured = Captured()
            Analytics.install(Analytics.Sink(capture: { captured.append($0, $1) },
                                             captureError: { _, _ in },
                                             consentChanged: { _ in }), consent: true)
            defer { Analytics.install(nil, consent: false) }

            let settings = AppSettings(defaults: isolation.makeDefaults(),
                                       licenseServerURL: URL(string: "https://license.example.com"))
            let fromButton = LicenseSettingsViewController(settings: settings)
            fromButton.test_tapEnterLicense()
            let fromNote = LicenseSettingsViewController(settings: settings)
            _ = fromNote.view
            fromNote.presentLicenseSheetFromNote()

            #expect(captured.properties(of: "license:enter_sheet_opened")
                    == [["source": "settings"], ["source": "note"]])
        }

        /// Red if the Appearance row's readout stops naming the theme and the
        /// accent dial. Here rather than in the parallel suite because picking
        /// an accent remaps the process-global `Tokens.accentStyle`.
        @Test func appearanceReadoutNamesThemeAndAccent() {
            defer { Tokens.accentStyle = .fullGold }
            let appearance = AppearanceSettingsViewController(
                settings: AppSettings(defaults: isolation.makeDefaults()))
            let root = SettingsRootViewController(sections: [
                .init(title: "Appearance", symbolName: "paintpalette", viewController: appearance),
            ])
            #expect(root.test_readoutLines(at: 0) == ["Match system · Full gold"])

            appearance.test_selectTheme(.dark)
            appearance.test_selectAccentStyle(.subtle)
            #expect(root.test_readoutLines(at: 0) == ["Dark · Subtle"])
        }
    }
}
