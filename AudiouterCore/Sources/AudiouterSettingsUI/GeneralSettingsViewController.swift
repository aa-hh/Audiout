// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// Settings › **General** pane. Step 1: a single "Launch at login" switch wired
/// to the `LoginItemManaging` seam. Also the entry point to **About Audiouter…**
/// (app identity/version, GPL license + source link, third-party credits,
/// support contact) — the app's only in-app About/Credits surface, required
/// for GPL attribution before charging money for the app. The About content
/// lives in its own small `AboutWindowController` rather than inline here —
/// its full required content roughly doubles a pane's height, which would
/// break the single-screen Settings window's fixed/scrolling-free design (see
/// `AboutView.swift`'s doc comment).
///
/// The switch always reflects the *live* system state (`loginItem.isEnabled`),
/// re-read on every appear — the user can flip the login item in System Settings
/// while our window is closed, and a stored bool would drift.
@MainActor
public final class GeneralSettingsViewController: NSViewController {

    private let loginItem: LoginItemManaging
    private let settings: AppSettings
    private let launchSwitch = NSSwitch()
    private let remoteControlCheckbox = NSButton()
    private let setupButton = NSButton()
    private let aboutButton = NSButton()
    private let aboutWindowController: AboutWindowController

    /// Fired when "Check Permissions…" is clicked, so the app can re-present the
    /// first-run onboarding/permission-priming flow. Nil (unset) leaves the
    /// button inert — the app layer wires it in `openSettings`.
    public var onRunSetupAgain: (() -> Void)?

    /// Fired after "Allow control from iPhone on this network" changes and
    /// persists (T6), so the app layer can start/stop the companion server to
    /// match. Nil (unset) leaves the checkbox inert beyond persisting the
    /// setting — the app layer claims it in `openSettings`, matching
    /// ``onRunSetupAgain``'s single-assignment idiom.
    public var onAllowRemoteControlChanged: (() -> Void)?

    /// - Parameters:
    ///   - settings: backs the "Allow control from iPhone" checkbox; injectable
    ///     so tests use a throwaway `UserDefaults` suite, never `.standard`.
    ///   - aboutInfo: the About window's bundle-sourced identity; defaults to
    ///     the live app bundle (`AboutInfo.current()`), injected as a fixed
    ///     value in tests so the rendered version string never depends on how
    ///     the test binary was built.
    ///   - openURL: opens the About window's "View Source Code" link; defaults
    ///     to `NSWorkspace`, injected as a recording closure in tests so a
    ///     test run never actually launches a browser.
    public init(loginItem: LoginItemManaging,
                settings: AppSettings = AppSettings(),
                aboutInfo: AboutInfo = .current(),
                openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.loginItem = loginItem
        self.settings = settings
        self.aboutWindowController = AboutWindowController(info: aboutInfo, openURL: openURL)
        super.init(nibName: nil, bundle: nil)
        title = "General"
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        launchSwitch.target = self
        launchSwitch.action = #selector(launchToggled)
        launchSwitch.setAccessibilityLabel("Launch at login")

        let launchRow = SettingsForm.row(
            title: "Launch at login",
            subtitle: "Open Audiouter automatically when you log in.",
            control: launchSwitch)

        // AppKit checkbox (matches DeviceRowView/MembershipRowView's boolean
        // idiom) — no inline title, the row label carries it.
        remoteControlCheckbox.setButtonType(.switch)
        remoteControlCheckbox.title = ""
        remoteControlCheckbox.state = settings.allowRemoteControl ? .on : .off
        remoteControlCheckbox.target = self
        remoteControlCheckbox.action = #selector(remoteControlToggled)
        remoteControlCheckbox.setAccessibilityLabel("Allow control from iPhone on this network")
        let remoteControlRow = SettingsForm.row(
            title: "Allow control from iPhone on this network",
            subtitle: "Lets the Audiouter companion app on your iPhone see and control this Mac's speakers.",
            control: remoteControlCheckbox)

        // "Check Permissions…" re-opens the first-run permission-priming window —
        // the way a user re-checks the System Audio / Local Network grants after
        // changing them in System Settings (the flow itself deep-links there).
        setupButton.title = "Check Permissions…"
        setupButton.bezelStyle = .rounded
        setupButton.target = self
        setupButton.action = #selector(runSetupAgainTapped)
        let setupRow = SettingsForm.row(
            title: "Setup",
            subtitle: "Verify that required permissions are granted.",
            control: setupButton)

        // "About Audiouter…" opens the standalone About/Credits window (app
        // identity, GPL license + source link, third-party credits, support) —
        // see the type doc comment for why that content isn't inline here.
        aboutButton.title = "About Audiouter…"
        aboutButton.bezelStyle = .rounded
        aboutButton.target = self
        aboutButton.action = #selector(aboutTapped)
        let aboutRow = SettingsForm.row(
            title: "About",
            subtitle: "Version, license, and third-party credits.",
            control: aboutButton)

        view = SettingsForm.paneView(rows: [launchRow, remoteControlRow, setupRow, aboutRow])
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: SettingsForm.contentWidth, height: view.fittingSize.height)
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        syncFromLoginItem()
    }

    private func syncFromLoginItem() {
        launchSwitch.state = loginItem.isEnabled ? .on : .off
    }

    @objc private func remoteControlToggled() {
        settings.allowRemoteControl = remoteControlCheckbox.state == .on
        onAllowRemoteControlChanged?()
    }

    @objc private func runSetupAgainTapped() { onRunSetupAgain?() }

    @objc private func aboutTapped() { aboutWindowController.show() }

    // STABILITY(D4): SMAppService register/status round-trips launchd XPC synchronously on the main thread; see dev/notes/stability-audit-2026-07-18.md
    @objc private func launchToggled() {
        let desired = launchSwitch.state == .on
        do {
            try loginItem.setEnabled(desired)
        } catch {
            // The system refused (commonly: a loose dev binary that isn't a
            // registered .app). Bounce the switch back to the real state rather
            // than showing a lie, and log for the app layer.
            syncFromLoginItem()
            FileHandle.standardError.write(
                Data("[Audiouter] launch-at-login change failed: \(error)\n".utf8))
        }
    }

    // MARK: Test-support hooks

    /// Whether the switch currently reads "on".
    public var test_launchAtLoginIsOn: Bool { launchSwitch.state == .on }

    /// Re-read the live login-item state into the switch (the `viewWillAppear`
    /// sync, without a real window).
    public func test_syncFromLoginItem() {
        _ = view
        syncFromLoginItem()
    }

    /// Drive the switch to `on` and run the same action a real toggle would.
    public func test_toggleLaunchAtLogin(_ on: Bool) {
        _ = view
        launchSwitch.state = on ? .on : .off
        launchToggled()
    }

    /// Invoke "Check Permissions…" as a click would.
    public func test_tapRunSetupAgain() {
        _ = view
        runSetupAgainTapped()
    }

    // MARK: Test-support hooks (Companion — T6)

    /// Whether the checkbox currently reads "on".
    public var test_allowRemoteControlIsOn: Bool {
        _ = view
        return remoteControlCheckbox.state == .on
    }

    /// Drive the checkbox to `on`/`off` and run the same action a real click would.
    public func test_toggleAllowRemoteControl(_ on: Bool) {
        _ = view
        remoteControlCheckbox.state = on ? .on : .off
        remoteControlToggled()
    }

    // MARK: Test-support hooks (About)

    /// The About window controller, so a test can drill into
    /// `AboutViewController`'s own `test_*` hooks without this pane
    /// re-exposing every one of them a second time (mirrors
    /// `SettingsWindowController.test_general` etc.).
    public var test_about: AboutWindowController { aboutWindowController }

    /// Invoke "About Audiouter…" as a click would.
    public func test_tapAbout() {
        _ = view
        aboutTapped()
    }
}
