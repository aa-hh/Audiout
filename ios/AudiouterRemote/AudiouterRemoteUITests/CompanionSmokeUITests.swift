// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

/// T18 — the one place anything in this app actually gets tapped. Every
/// other iOS test drives view models directly (`RemoteSessionTests`,
/// `DemoMacSessionTests`, …); this is the only test that proves a real
/// touch on a real accessibility label reaches the real view hierarchy —
/// the simulator-control MCP tooling can't drive this Xcode-beta simulator
/// (no SimulatorKit, no `simctl` tap), so XCUITest is the only mechanism
/// left that can.
///
/// Runs entirely in Demo mode (T13's `DemoMacSession`, seeded fleet: "This
/// Mac", "Kitchen HomePod", "Sonos One (Left/Right)", an offline "Office
/// Speaker"; one group "Living Room"; two app routes "Demo Music"/"Demo
/// Browser" plus one addable "Demo Video") — the one path guaranteed to work
/// with no Mac on the CI/simulator network, and the app's own documented way
/// to demo itself without one (`MacListView`'s labeled "Demo system" row).
///
/// Screenshots double as the first draft of the App Store screenshot set
/// (`docs/companion-app-store.md`) — attached to the test report AND copied
/// to a scratch path so they're easy to hand off without opening Xcode's
/// result bundle.
final class CompanionSmokeUITests: XCTestCase {

    private var app: XCUIApplication!

    /// razor: hardcoded to this task's scratch directory rather than an
    /// env-var seam — a UI test writing screenshots somewhere configurable
    /// is speculative generality nobody asked for; if a future task wants a
    /// different destination, add the seam then.
    private let screenshotDir = URL(fileURLWithPath:
        "/private/tmp/claude-501/-Users-alechenderson-Projects-AirPlay-Controller--claude-worktrees-companion-app-research-e89998/89a3b4b1-e210-46bb-a605-d0cb0d7b7bb7/scratchpad/tabs"
    )

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Keep the walkthrough deterministic on a LAN that has a real
        // Audiouter: the app skips ConnectionController.start() entirely
        // (no browsing, no remembered-Mac reconnect). Demo needs neither.
        app.launchArguments += ["-uitest-isolated"]
        app.launch()
        dismissLocalNetworkAlertIfPresent()
        try FileManager.default.createDirectory(at: screenshotDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// First launch on a fresh simulator can raise iOS's Local Network
    /// permission prompt over the app (`MacBrowser` starts Bonjour browsing
    /// from `RootView.task`) — dismiss it if present so it doesn't swallow
    /// the first real tap of the test.
    private func dismissLocalNetworkAlertIfPresent() {
        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else { return }
        for label in ["Allow", "OK"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return
        }
    }

    /// Row/header content in this app is frequently one accessibility
    /// element combining an icon, a name and a status Text (`.combine`
    /// modifiers throughout `UI/`) — matching the full element tree by
    /// substring, rather than an exact static-text label, is what keeps
    /// this test from being coupled to exactly how each view merges its
    /// children.
    /// Scoped by element type on purpose. `descendants(matching: .any)` walks
    /// the WHOLE accessibility tree and ships every element across the XPC
    /// boundary before the predicate is applied here, so its cost grows with
    /// everything on screen rather than with what is being looked for — eight
    /// calls of it were the entire runtime of this test.
    ///
    /// Rows and headers carry `.isButton`; the rest of what this looks for is
    /// plain text. Two narrow queries beat one walk of the tree.
    /// Each query builds its own `NSPredicate`: the type is not `Sendable`, so
    /// reusing one instance across two queries is a strict-concurrency error.
    private func anyElement(containing text: String) -> XCUIElement {
        func match(_ query: XCUIElementQuery) -> XCUIElement {
            query.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        }
        for query in [app.buttons, app.staticTexts, app.otherElements] {
            let element = match(query)
            if element.exists { return element }
        }
        return match(app.otherElements)
    }

    private func attachAndSaveScreenshot(name: String, filename: String) {
        let screenshot = XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let url = screenshotDir.appendingPathComponent(filename)
        do {
            try screenshot.pngRepresentation.write(to: url)
        } catch {
            XCTFail("Failed to save screenshot \(filename) to \(url.path): \(error)")
        }
    }

    // MARK: - Smoke test

    func testDemoModeSmokeAcrossAllTabs() throws {
        let tabBar = app.tabBars.firstMatch
        let connectionTab = tabBar.buttons["Connection"]
        let speakersTab = tabBar.buttons["Speakers"]
        let appsTab = tabBar.buttons["Apps"]
        let groupsTab = tabBar.buttons["Groups"]

        // 1. Lands on the Connection tab, with the "no Mac found" help
        // (EmptyStateView's checklist — shown whether the browser is still
        // looking or has given up, so this doesn't race NWBrowser timing).
        XCTAssertTrue(connectionTab.waitForExistence(timeout: 5), "Connection tab should exist on launch")
        XCTAssertTrue(connectionTab.isSelected, "App should land on the Connection tab")
        XCTAssertTrue(
            anyElement(containing: "Open Audiouter on your Mac").waitForExistence(timeout: 10),
            "Expected the no-Mac-found help checklist on first launch"
        )

        // 2. Tap the labelled Demo system row; assert it connects.
        let demoRow = app.buttons["Demo system"]
        XCTAssertTrue(demoRow.waitForExistence(timeout: 5), "Demo system row should always be visible")
        demoRow.tap()

        XCTAssertTrue(anyElement(containing: "Demo Mac").waitForExistence(timeout: 5),
                      "Demo Mac's server name should appear once demo mode connects")

        // 3. Visit Speakers: assert demo speaker content rendered.
        speakersTab.tap()
        XCTAssertTrue(anyElement(containing: "Kitchen HomePod").waitForExistence(timeout: 5),
                      "Kitchen HomePod (demo fleet) should render as a speaker row")
        attachAndSaveScreenshot(name: "Speakers", filename: "01-speakers.png")

        // Interaction: tap a speaker row to arm it — the row is the control,
        // so its accessibility value is what flips.
        let homePodRow = app.buttons["Kitchen HomePod"]
        XCTAssertTrue(homePodRow.waitForExistence(timeout: 5))
        let beforeToggle = homePodRow.value as? String
        homePodRow.tap()
        let afterToggle = homePodRow.value as? String
        XCTAssertNotEqual(beforeToggle, afterToggle, "Tapping the Kitchen HomePod row should flip it between armed and not armed")

        // 4. Visit Apps: assert a demo app route row rendered.
        appsTab.tap()
        XCTAssertTrue(anyElement(containing: "Demo Music").waitForExistence(timeout: 5),
                      "Demo Music (demo fleet) should render as an app route row")
        attachAndSaveScreenshot(name: "Apps", filename: "02-apps.png")

        // Interaction: open the add-app sheet and cancel. The Apps tab draws
        // its own header (no navigation bar), so the button is found by its
        // accessibility label rather than as a nav-bar descendant.
        app.buttons["Add App"].tap()
        let addAppNavBar = app.navigationBars["Add App"]
        XCTAssertTrue(addAppNavBar.waitForExistence(timeout: 5), "Add App sheet should present")
        addAppNavBar.buttons["Cancel"].tap()
        XCTAssertTrue(anyElement(containing: "Demo Music").waitForExistence(timeout: 5),
                      "Cancelling Add App should return to the unchanged Apps list")
        XCTAssertFalse(anyElement(containing: "Demo Video").exists,
                       "Cancel must not add the pending Demo Video route")

        // 5. Visit Groups: assert a demo group row rendered.
        groupsTab.tap()
        XCTAssertTrue(anyElement(containing: "Living Room").waitForExistence(timeout: 5),
                      "Living Room (demo fleet) should render as a group row")
        attachAndSaveScreenshot(name: "Groups", filename: "03-groups.png")

        // Interaction: open the create-group sheet and cancel.
        app.navigationBars["Groups"].buttons["Add Group"].tap()
        let newGroupNavBar = app.navigationBars["New Group"]
        XCTAssertTrue(newGroupNavBar.waitForExistence(timeout: 5), "New Group sheet should present")
        newGroupNavBar.buttons["Cancel"].tap()
        XCTAssertTrue(anyElement(containing: "Living Room").waitForExistence(timeout: 5),
                      "Cancelling group creation should return to the unchanged Groups list")

        // 6. Visit Connection again: assert Mac Settings / About rows and
        // the connected Demo Mac header render.
        connectionTab.tap()
        XCTAssertTrue(anyElement(containing: "Demo Mac").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Mac Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["About"].waitForExistence(timeout: 5))
        attachAndSaveScreenshot(name: "Connection", filename: "04-connection.png")

        // 7. No crash, and the earlier speaker toggle stuck (it's session
        // state, not view-local state that a tab switch would reset).
        speakersTab.tap()
        let persistedToggle = app.buttons["Kitchen HomePod"].value as? String
        XCTAssertEqual(afterToggle, persistedToggle,
                        "Speaker selection should persist across tab navigation, not reset per view")
    }
}
