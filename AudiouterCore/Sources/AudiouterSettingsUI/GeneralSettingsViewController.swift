// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// Settings › **General** pane. Step 1: a single "Launch at login" switch wired
/// to the `LoginItemManaging` seam. More lands here later (menu-bar icon level,
/// reset), which is why it's a form, not a lone control.
///
/// The switch always reflects the *live* system state (`loginItem.isEnabled`),
/// re-read on every appear — the user can flip the login item in System Settings
/// while our window is closed, and a stored bool would drift.
@MainActor
public final class GeneralSettingsViewController: NSViewController {

    private let loginItem: LoginItemManaging
    private let launchSwitch = NSSwitch()
    private let setupButton = NSButton()

    /// Fired when "Run Setup Again…" is clicked, so the app can re-present the
    /// first-run onboarding/permission-priming flow. Nil (unset) leaves the
    /// button inert — the app layer wires it in `openSettings`.
    public var onRunSetupAgain: (() -> Void)?

    public init(loginItem: LoginItemManaging) {
        self.loginItem = loginItem
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

        // "Run Setup Again…" re-opens the first-run permission-priming window —
        // the way a user re-checks the System Audio / Local Network grants after
        // changing them in System Settings (the flow itself deep-links there).
        setupButton.title = "Run Setup Again…"
        setupButton.bezelStyle = .rounded
        setupButton.target = self
        setupButton.action = #selector(runSetupAgainTapped)
        let setupRow = SettingsForm.row(
            title: "Setup",
            subtitle: "Review what Audiouter needs and re-check permissions.",
            control: setupButton)

        view = SettingsForm.paneView(rows: [launchRow, setupRow])
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

    @objc private func runSetupAgainTapped() { onRunSetupAgain?() }

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

    /// Invoke "Run Setup Again…" as a click would.
    public func test_tapRunSetupAgain() {
        _ = view
        runSetupAgainTapped()
    }
}
