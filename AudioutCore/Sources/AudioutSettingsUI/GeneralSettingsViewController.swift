// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// Settings › **General** pane: "Launch at login" (wired to the
/// `LoginItemManaging` seam), "Reconnect last speakers when Audiout starts"
/// (`AppSettings.reconnectAtLaunch`, roadmap 050), and a rare-use footer strip
/// with **Setup…** and **About Audiout…**
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
    private let reconnectSwitch = NSSwitch()
    private let touchBarSwitch = NSSwitch()
    private let reconnectHint = SettingsForm.hintLabel()
    private let licenseStatusHint = SettingsForm.hintLabel()
    private let enterLicenseButton = NSButton()
    private var licenseRow: NSView?
    /// The presented (or headlessly held) Enter License… sheet — strong, the
    /// `MixerWindowController.presentCreateSheet` idiom: headless tests never
    /// present, they hold this and drive its `test_` hooks.
    private var licenseSheet: LicenseSheetViewController?
    private let setupButton = NSButton()
    private let aboutButton = NSButton()
    private let updatesButton = NSButton()
    private let buyButton = NSButton()
    private let aboutWindowController: AboutWindowController
    private let openURL: (URL) -> Void

    /// Fired when "Open Setup…" is clicked, so the app can re-present the
    /// first-run onboarding/permission-priming flow. Nil (unset) leaves the
    /// button inert — the app layer wires it in `openSettings`.
    public var onRunSetupAgain: (() -> Void)?

    /// Fired at the end of every license status refresh — launch, and every
    /// commit of the key field. The app layer re-reads ``AppSettings`` from it
    /// (the unregistered note, the Sparkle authorization header); nil leaves
    /// this pane's own display the only thing that moves.
    public var onLicenseChanged: (() -> Void)?

    /// The transport ``LicenseValidator`` uses when this pane checks a
    /// freshly-entered key. Nil (unset) is the real network, which is what the
    /// app always wants; tests stub it so a commit never leaves the machine —
    /// same injection shape as ``onRunSetupAgain``.
    public var licenseTransport: LicenseValidator.Transport?

    /// Fired when "Check for Updates…" is clicked. Nil (unset) means this build
    /// has no updater at all — a build run from source or without a Sparkle feed
    /// — and the button is then hidden rather than inert, so nothing offers an
    /// update path that cannot work. The app layer wires it before the view
    /// loads, exactly as it does `onRunSetupAgain`.
    public var onCheckForUpdates: (() -> Void)?

    /// - Parameters:
    ///   - aboutInfo: the About window's bundle-sourced identity; defaults to
    ///     the live app bundle (`AboutInfo.current()`), injected as a fixed
    ///     value in tests so the rendered version string never depends on how
    ///     the test binary was built.
    ///   - openURL: opens the About window's "View Source Code…" link and the
    ///     "Buy Audiout…" button's purchase page; defaults to `NSWorkspace`,
    ///     injected as a recording closure in tests so a test run never
    ///     actually launches a browser.
    public init(loginItem: LoginItemManaging,
                settings: AppSettings = AppSettings(),
                aboutInfo: AboutInfo = .current(),
                openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.loginItem = loginItem
        self.settings = settings
        self.openURL = openURL
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
            subtitle: "Open Audiout automatically when you log in.",
            control: launchSwitch)

        // Reconnect-at-launch (roadmap 050): the opt-in that lets
        // `GroupController.ensureDefaultSelection()` resume the persisted
        // routing set instead of starting on this Mac's speakers only.
        reconnectSwitch.target = self
        reconnectSwitch.action = #selector(reconnectToggled)
        reconnectSwitch.state = settings.reconnectAtLaunch ? .on : .off
        reconnectSwitch.setAccessibilityLabel("Reconnect last speakers when Audiout starts")
        let reconnectRow = SettingsForm.row(
            title: "Reconnect last speakers when Audiout starts",
            control: reconnectSwitch)
        // Live hint (spec §5.2) — re-written on every toggle.
        reconnectHint.stringValue = Self.reconnectHintLine(settings.reconnectAtLaunch)

        // License (roadmap 054, Ardour model): entirely optional — the app is
        // fully functional with no key at all. NO inline key field: entry is a
        // deliberate act behind "Enter License…" (a sheet), the convention
        // every respected optional-license app follows (Sublime, Little
        // Snitch, Panic — surveyed 2026-08-24). The row is a title + two
        // buttons, and the live status line beneath it carries both the state
        // and the honest pitch.
        enterLicenseButton.bezelStyle = .rounded
        enterLicenseButton.target = self
        enterLicenseButton.action = #selector(enterLicenseTapped)
        enterLicenseButton.setAccessibilityLabel("Enter License Key")

        buyButton.title = "Buy Audiout…"
        buyButton.bezelStyle = .rounded
        buyButton.target = self
        buyButton.action = #selector(buyTapped)
        buyButton.setAccessibilityLabel("Buy an Audiout license")

        let licenseButtons = NSStackView(views: [enterLicenseButton, buyButton])
        licenseButtons.orientation = .horizontal
        licenseButtons.alignment = .centerY
        licenseButtons.spacing = 8
        licenseButtons.translatesAutoresizingMaskIntoConstraints = false
        let licenseKeyRow = SettingsForm.row(title: "License", control: licenseButtons)
        licenseRow = licenseKeyRow

        // Footer strip (roadmap 050): Setup and About are rare-use, so they
        // share one quiet button strip instead of two full title+subtitle rows.
        // "Open Setup…" re-opens the first-run permission-priming window — the
        // way a user re-checks the System Audio / Local Network grants after
        // changing them in System Settings (the flow itself deep-links there).
        // "About Audiout…" opens the standalone About/Credits window (app
        // identity, GPL license + source link, third-party credits, support) —
        // see the type doc comment for why that content isn't inline here.
        setupButton.title = "Setup…"
        setupButton.bezelStyle = .rounded
        setupButton.controlSize = .small
        setupButton.target = self
        setupButton.action = #selector(runSetupAgainTapped)
        setupButton.setAccessibilityLabel("Open Setup")

        aboutButton.title = "About Audiout…"
        aboutButton.bezelStyle = .rounded
        aboutButton.controlSize = .small
        aboutButton.target = self
        aboutButton.action = #selector(aboutTapped)

        updatesButton.title = "Check for Updates…"
        updatesButton.bezelStyle = .rounded
        updatesButton.controlSize = .small
        updatesButton.target = self
        updatesButton.action = #selector(checkForUpdatesTapped)
        updatesButton.setAccessibilityLabel("Check for Updates")
        updatesButton.isHidden = onCheckForUpdates == nil

        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false

        let strip = NSStackView(views: [setupButton, aboutButton, updatesButton])
        strip.orientation = .horizontal
        strip.alignment = .centerY
        strip.spacing = 8
        strip.translatesAutoresizingMaskIntoConstraints = false

        // Touch Bar opt-out — offered ONLY on a Mac that has one, since on
        // every other Mac the setting would name a thing the user cannot see.
        var rows: [NSView] = [launchRow, reconnectRow, reconnectHint]
        if TouchBarHardware.isPresent {
            touchBarSwitch.target = self
            touchBarSwitch.action = #selector(touchBarToggled)
            touchBarSwitch.state = settings.touchBarControlsEnabled ? .on : .off
            touchBarSwitch.setAccessibilityLabel("Use Audiout's Touch Bar controls")
            rows.append(SettingsForm.row(
                title: "Use Audiout's Touch Bar controls",
                subtitle: "While Audiout is playing to speakers, show Touch Bar volume controls that work.",
                control: touchBarSwitch))
        }
        rows.append(contentsOf: [licenseKeyRow, licenseStatusHint, hairline, strip])

        view = SettingsForm.paneView(rows: rows)

        refreshLicenseStatus()
    }

    /// What the status line under the License row says, per state — plain
    /// words, no jargon, and never a claim the app is about to stop working.
    /// The four server-verdict strings come from
    /// ``LicenseSheetViewController/statusLine(for:)`` so the pane and the
    /// sheet can never drift apart; the two key-side states are the pane's own.
    private static func licenseStatusLine(keyIsEmpty: Bool,
                                          status: LicenseStatus?) -> String {
        if keyIsEmpty {
            return "Unregistered. Audiout is fully functional without a license — "
                + "buying one funds development and unlocks official downloads and updates."
        }
        guard let status else {
            return "Couldn’t reach the license server — will try again next launch."
        }
        return LicenseSheetViewController.statusLine(for: status)
    }

    /// Re-read the stored license state into the row, then tell the app
    /// layer. Every path that can change the state — the launch build, the
    /// sheet closing, a validator answer — ends here, so there is one place
    /// that decides what the pane shows. A build with no license server hides
    /// the whole License surface: it has nothing to verify and nothing to
    /// sell, so it says nothing at all.
    private func refreshLicenseStatus() {
        let serverConfigured = settings.licenseServerURL != nil
        licenseRow?.isHidden = !serverConfigured
        licenseStatusHint.isHidden = !serverConfigured

        let key = settings.licenseKey ?? ""
        let status = settings.licenseStatus
        if serverConfigured {
            licenseStatusHint.stringValue = Self.licenseStatusLine(keyIsEmpty: key.isEmpty,
                                                                   status: status)
        }

        // "Enter License…" before a key exists; "Change…" once one is stored
        // (the sheet then prefills it and offers Remove License…).
        enterLicenseButton.title = key.isEmpty ? "Enter License…" : "Change…"

        // Buying is offered only where it can work (a server) and only where it
        // would help (no key, or a key the server won’t honour).
        let unregistered = key.isEmpty || status == .unknown || status == .invalid || status == .revoked
        buyButton.isHidden = !(serverConfigured && unregistered && settings.buyURL != nil)

        onLicenseChanged?()
    }

    /// Present the Enter License… sheet (`MixerWindowController
    /// .presentCreateSheet`'s idiom: strong reference always, `presentAsSheet`
    /// only when a visible window can host it — headless tests drive the held
    /// controller's hooks directly).
    @objc private func enterLicenseTapped() {
        let sheet = LicenseSheetViewController(settings: settings,
                                               transport: licenseTransport,
                                               openURL: openURL)
        sheet.onComplete = { [weak self] in
            self?.licenseSheet = nil
            self?.refreshLicenseStatus()
        }
        sheet.onStateChange = { [weak self] in self?.refreshLicenseStatus() }
        licenseSheet = sheet
        if let host = view.window, host.isVisible {
            presentAsSheet(sheet)
        }
    }

    /// The reconnect-at-launch live hint: what the NEXT launch will do.
    private static func reconnectHintLine(_ enabled: Bool) -> String {
        enabled
            ? "Next launch reconnects the speakers you last used."
            : "Audiout starts on this Mac's speakers only."
    }

    @objc private func reconnectToggled() {
        let enabled = reconnectSwitch.state == .on
        settings.reconnectAtLaunch = enabled
        reconnectHint.stringValue = Self.reconnectHintLine(enabled)
    }

    @objc private func touchBarToggled() {
        settings.touchBarControlsEnabled = touchBarSwitch.state == .on
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

    @objc private func aboutTapped() { aboutWindowController.show() }

    @objc private func checkForUpdatesTapped() { onCheckForUpdates?() }

    @objc private func buyTapped() {
        guard let url = settings.buyURL else { return }
        openURL(url)
    }

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

    /// The reconnect-at-launch live hint line (spec §5.2).
    public var test_reconnectHint: String {
        _ = view
        return reconnectHint.stringValue
    }

    // MARK: Test-support hooks (License, roadmap 054)

    /// Register `text` through the REAL sheet path — open the sheet the way
    /// "Enter License…" does (held headlessly), type into its field, click
    /// Register — so what tests prove is the one commit path users have.
    public func test_setLicenseKey(_ text: String) {
        _ = view
        enterLicenseTapped()
        licenseSheet?.test_setKeyText(text)
        licenseSheet?.test_tapRegister()
    }

    /// Remove the stored key through the sheet's Remove License… path.
    public func test_removeLicense() {
        _ = view
        enterLicenseTapped()
        licenseSheet?.test_tapRemove()
    }

    /// Open the Enter License…/Change… sheet as a click would (held
    /// headlessly; drive it via ``test_licenseSheet``).
    public func test_tapEnterLicense() {
        _ = view
        enterLicenseTapped()
    }

    /// The held Enter License… sheet, while one is open (headless runs hold
    /// it without presenting).
    public var test_licenseSheet: LicenseSheetViewController? { licenseSheet }

    /// Whether the License row is on screen (hidden entirely in builds with
    /// no license server).
    public var test_licenseRowIsVisible: Bool {
        _ = view
        return !(licenseRow?.isHidden ?? true)
    }

    /// The row's secondary button title — "Enter License…" ↔ "Change…".
    public var test_enterLicenseButtonTitle: String {
        _ = view
        return enterLicenseButton.title
    }

    /// The license status line under the key field, or `nil` when it is hidden
    /// (a build with no license server has nothing to verify).
    public var test_licenseStatusText: String? {
        _ = view
        return licenseStatusHint.isHidden ? nil : licenseStatusHint.stringValue
    }

    /// Whether "Buy Audiout…" is on screen.
    public var test_buyButtonIsVisible: Bool {
        _ = view
        return !buyButton.isHidden
    }

    /// Invoke "Open Setup…" as a click would.
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
