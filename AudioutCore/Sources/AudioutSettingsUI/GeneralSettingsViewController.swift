// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// Settings › **General** pane: "Launch at login" (wired to the
/// `LoginItemManaging` seam), "Reconnect last speakers when Audiout starts"
/// (`AppSettings.reconnectAtLaunch`, roadmap 050), the Touch Bar opt-out, the
/// usage-statistics switch, and a rare-use button row with **Run setup
/// again…**, **About Audiout…** and **Check for Updates…**
/// (app identity/version, GPL license + source link, third-party credits,
/// support contact) — the app's only in-app About/Credits surface, required
/// for GPL attribution before charging money for the app. The About content
/// lives in its own small `AboutWindowController` rather than inline here —
/// its full required content roughly doubles a pane's height (see
/// `AboutView.swift`'s doc comment).
///
/// The switch always reflects the *live* system state (`loginItem.isEnabled`),
/// re-read on every appear — the user can flip the login item in System Settings
/// while our window is closed, and a stored bool would drift.
@MainActor
public final class GeneralSettingsViewController: NSViewController, SettingsReadoutProviding {

    private let loginItem: LoginItemManaging
    private let settings: AppSettings
    private let launchSwitch = NSSwitch()
    private let reconnectSwitch = NSSwitch()
    private let touchBarSwitch = NSSwitch()
    private let consentSwitch = NSSwitch()
    private var consentRow: ListRowView?
    private let loginApprovalButton = NSButton()
    private var loginApprovalRow: NSView?
    // The card the approval row is mounted into and unmounted from (never
    // hidden in place — `NSStackView` keeps a hidden child's last height,
    // AGENTS.md).
    private var card: (container: NSView, box: GroupedSectionView, stack: NSStackView)?
    private let setupButton = NSButton()
    private let aboutButton = NSButton()
    private let updatesButton = NSButton()
    private let aboutWindowController: AboutWindowController

    /// Fired when "Run setup again…" is clicked, so the app can re-present the
    /// first-run onboarding/permission-priming flow. Nil (unset) leaves the
    /// button inert — the app layer wires it in `openSettings`.
    public var onRunSetupAgain: (() -> Void)?

    /// Fired when "Check for Updates…" is clicked. Nil (unset) means this build
    /// has no updater at all — a build run from source or without a Sparkle feed
    /// — and the button is then hidden rather than inert, so nothing offers an
    /// update path that cannot work. The app layer wires it before the view
    /// loads, exactly as it does `onRunSetupAgain`.
    public var onCheckForUpdates: (() -> Void)?

    var onReadoutChanged: (() -> Void)?

    /// - Parameters:
    ///   - settings: backs the reconnect, Touch Bar and usage switches;
    ///     injectable so tests use a throwaway `UserDefaults` suite, never
    ///     `.standard`.
    ///   - aboutInfo: the About window's bundle-sourced identity; defaults to
    ///     the live app bundle (`AboutInfo.current()`), injected as a fixed
    ///     value in tests so the rendered version string never depends on how
    ///     the test binary was built.
    ///   - openURL: opens the About window's "View Source Code…" link;
    ///     defaults to `NSWorkspace`, injected as a recording closure in tests
    ///     so a test run never actually launches a browser.
    public init(loginItem: LoginItemManaging,
                settings: AppSettings = AppSettings(),
                aboutInfo: AboutInfo = .current(),
                openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
                saveDiagnostics: (() -> Void)? = nil) {
        self.loginItem = loginItem
        self.settings = settings
        self.aboutWindowController = AboutWindowController(info: aboutInfo, openURL: openURL,
                                                           saveDiagnostics: saveDiagnostics)
        super.init(nibName: nil, bundle: nil)
        title = "General"
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Readout

    var readoutLines: [String] {
        if loginItem.needsApproval { return ["Needs Login Items approval"] }
        return [loginItem.isEnabled ? "Opens at login" : "Doesn't open at login"]
    }

    var readoutGlyphTint: NSColor {
        loginItem.needsApproval ? Tokens.Color.ring : Tokens.Color.labelCool
    }

    // MARK: Layout

    public override func loadView() {
        let (header, _) = SettingsPane.makeHeader(symbolName: "gearshape", title: "General")

        launchSwitch.target = self
        launchSwitch.action = #selector(launchToggled)
        launchSwitch.setAccessibilityLabel("Launch at login")
        let launchRow = ListRowView(
            title: "Launch at login",
            accessory: launchSwitch)

        // `SMAppService.register()` can succeed into `.requiresApproval` —
        // registered, but inert until the user allows it in System Settings.
        // The switch springs back on its own; this row is the explanation and
        // the shortcut. Unmounted until `syncFromLoginItem()` finds that state.
        loginApprovalButton.title = "Open Login Items…"
        loginApprovalButton.bezelStyle = .rounded
        loginApprovalButton.controlSize = .small
        loginApprovalButton.target = self
        loginApprovalButton.action = #selector(openLoginItemsTapped)
        loginApprovalRow = ListRowView(title: "macOS needs you to allow Audiout in Login Items.",
                                       accessory: loginApprovalButton)

        // Reconnect-at-launch (roadmap 050): the opt-in that lets
        // `GroupController.ensureDefaultSelection()` resume the persisted
        // routing set instead of starting on this Mac's speakers only.
        reconnectSwitch.target = self
        reconnectSwitch.action = #selector(reconnectToggled)
        reconnectSwitch.state = settings.reconnectAtLaunch ? .on : .off
        reconnectSwitch.setAccessibilityLabel("Reconnect last speakers when Audiout starts")
        let reconnectRow = ListRowView(
            title: "Reconnect last speakers when Audiout starts",
            accessory: reconnectSwitch)

        // Anonymous usage analytics — the toggle for what
        // `AppSettings.telemetryEnabled` gates. It shows what is happening now,
        // which before the user has answered is the trial-phase default, not
        // the unset `telemetryOptIn`.
        consentSwitch.target = self
        consentSwitch.action = #selector(consentToggled)
        consentSwitch.state = settings.telemetryEnabled ? .on : .off
        consentSwitch.setAccessibilityLabel("Share anonymous usage statistics")
        let consentRow = ListRowView(
            title: "Share anonymous usage statistics",
            accessory: consentSwitch,
            helpText: Self.consentHintLine(settings.telemetryEnabled))
        self.consentRow = consentRow

        // Touch Bar opt-out — offered ONLY on a Mac that has one, since on
        // every other Mac the setting would name a thing the user cannot see.
        var rows: [NSView] = [launchRow, reconnectRow]
        if TouchBarHardware.isPresent {
            touchBarSwitch.target = self
            touchBarSwitch.action = #selector(touchBarToggled)
            touchBarSwitch.state = settings.touchBarControlsEnabled ? .on : .off
            touchBarSwitch.setAccessibilityLabel("Use Audiout's Touch Bar controls")
            rows.append(ListRowView(
                title: "Use Audiout's Touch Bar controls",
                accessory: touchBarSwitch,
                helpText: "While Audiout is playing to speakers, the Touch Bar volume keys control the speakers instead of the Mac."))
        }
        rows.append(consentRow)
        let card = SettingsPane.makeCard(rows: rows)
        self.card = card

        // Rare-use buttons: "Run setup again…" re-opens the first-run
        // permission-priming window — the way a user re-checks the System
        // Audio / Local Network grants after changing them in System Settings.
        // "About Audiout…" opens the standalone About/Credits window — see the
        // type doc comment for why that content isn't inline here.
        setupButton.title = "Run setup again…"
        setupButton.bezelStyle = .rounded
        setupButton.controlSize = .regular
        setupButton.target = self
        setupButton.action = #selector(runSetupAgainTapped)

        aboutButton.title = "About Audiout…"
        aboutButton.bezelStyle = .rounded
        aboutButton.controlSize = .regular
        aboutButton.target = self
        aboutButton.action = #selector(aboutTapped)

        updatesButton.title = "Check for Updates…"
        updatesButton.bezelStyle = .rounded
        updatesButton.controlSize = .regular
        updatesButton.target = self
        updatesButton.action = #selector(checkForUpdatesTapped)
        updatesButton.isHidden = onCheckForUpdates == nil

        let buttons = NSStackView(views: [setupButton, aboutButton, updatesButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let page = SettingsForm.pageView(content: [header, card.container, buttons])
        (page.subviews.first as? NSStackView)?.setCustomSpacing(14, after: card.container)
        view = page
    }

    @objc private func reconnectToggled() {
        let enabled = reconnectSwitch.state == .on
        settings.reconnectAtLaunch = enabled
        Analytics.capture("settings:reconnect_at_launch_toggled", ["enabled": enabled ? "true" : "false"])
    }

    /// The usage-analytics consent live hint: what sharing does or doesn't do.
    private static func consentHintLine(_ enabled: Bool) -> String {
        enabled
            ? "Anonymous feature counts, speaker timings and crash reports help improve Audiout."
            : "No usage data leaves this Mac."
    }

    @objc private func consentToggled() {
        let enabled = consentSwitch.state == .on
        settings.telemetryOptIn = enabled
        settings.telemetryAsked = true
        Analytics.setConsent(enabled)
        consentRow?.helpText = Self.consentHintLine(enabled)
    }

    @objc private func touchBarToggled() {
        settings.touchBarControlsEnabled = touchBarSwitch.state == .on
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        syncFromLoginItem()
    }

    @objc private func openLoginItemsTapped() { loginItem.openSystemSettingsLoginItems() }

    /// The ONE place the login-item surface is re-read: the switch follows the
    /// live system state, the approval row appears exactly when the system
    /// is holding the registration for the user to allow, and the sidebar
    /// readout follows both.
    private func syncFromLoginItem() {
        launchSwitch.state = loginItem.isEnabled ? .on : .off
        defer { onReadoutChanged?() }
        // Mount/unmount rather than `isHidden`: the stack keeps a hidden
        // child's last height, so the row is only ever in the stack while it
        // has something to say.
        guard let row = loginApprovalRow, let card else { return }
        if loginItem.needsApproval, row.superview == nil {
            card.stack.insertArrangedSubview(row, at: 1) // right under Launch at login
            // `removeFromSuperview` dropped the width pin.
            row.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        } else if !loginItem.needsApproval, row.superview != nil {
            card.stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        card.box.rows = card.stack.arrangedSubviews.filter { !$0.isHidden }
    }

    @objc private func runSetupAgainTapped() { onRunSetupAgain?() }

    @objc private func aboutTapped() { aboutWindowController.show() }

    @objc private func checkForUpdatesTapped() { onCheckForUpdates?() }

    // STABILITY(D4): SMAppService register/status round-trips launchd XPC synchronously on the main thread; see dev/notes/stability-audit-2026-07-18.md
    @objc private func launchToggled() {
        let desired = launchSwitch.state == .on
        do {
            try loginItem.setEnabled(desired)
            Analytics.capture("settings:launch_at_login_toggled", ["enabled": desired ? "true" : "false"])
            // Success is not the same as enabled: `register()` lands in
            // `.requiresApproval` without throwing. One funnel reverts the
            // switch and reveals the explanation together.
            syncFromLoginItem()
        } catch {
            // The system refused (commonly: a loose dev binary that isn't a
            // registered .app). Bounce the switch back to the real state rather
            // than showing a lie, and log for the app layer.
            syncFromLoginItem()
            FileHandle.standardError.write(
                Data("[Audiout] launch-at-login change failed: \(error)\n".utf8))
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

    /// Whether the reconnect-at-launch switch currently reads "on".
    public var test_reconnectAtLaunchIsOn: Bool {
        _ = view
        return reconnectSwitch.state == .on
    }

    /// Drive the reconnect-at-launch switch and run the toggle action
    /// (persists immediately).
    public func test_toggleReconnectAtLaunch(_ on: Bool) {
        _ = view
        reconnectSwitch.state = on ? .on : .off
        reconnectToggled()
    }

    /// Whether the "allow Audiout in Login Items" explanation is on screen.
    public var test_loginApprovalHintIsVisible: Bool {
        _ = view
        return loginApprovalRow?.superview != nil
    }

    /// Invoke "Open Login Items…" as a click would.
    public func test_tapOpenLoginItems() {
        _ = view
        openLoginItemsTapped()
    }

    /// Invoke "Run setup again…" as a click would.
    public func test_tapRunSetupAgain() {
        _ = view
        runSetupAgainTapped()
    }

    /// Whether "Check for Updates…" is on screen (it is hidden in builds with
    /// no updater — see `onCheckForUpdates`).
    public var test_checkForUpdatesIsVisible: Bool {
        _ = view
        return !updatesButton.isHidden
    }

    /// Invoke "Check for Updates…" as a click would.
    public func test_tapCheckForUpdates() {
        _ = view
        checkForUpdatesTapped()
    }

    // MARK: Test-support hooks (About)

    /// The About window controller, so a test can drill into
    /// `AboutViewController`'s own `test_*` hooks without this pane
    /// re-exposing every one of them a second time.
    public var test_about: AboutWindowController { aboutWindowController }

    /// Invoke "About Audiout…" as a click would.
    public func test_tapAbout() {
        _ = view
        aboutTapped()
    }
}
