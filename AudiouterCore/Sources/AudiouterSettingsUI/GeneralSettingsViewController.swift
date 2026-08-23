// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// Settings › **General** pane: "Launch at login" (wired to the
/// `LoginItemManaging` seam), "Reconnect last speakers when Audiouter starts"
/// (`AppSettings.reconnectAtLaunch`, roadmap 050), and a rare-use footer strip
/// with **Setup…** and **About Audiouter…**
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
    private let reconnectHint = SettingsForm.hintLabel()
    private let licenseKeyField = NSTextField()
    private let licenseStatusHint = SettingsForm.hintLabel()
    private let licenseCheckInSwitch = NSSwitch()
    private let licenseHint = SettingsForm.hintLabel()
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
    ///     "Buy Audiouter…" button's purchase page; defaults to `NSWorkspace`,
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
            subtitle: "Open Audiouter automatically when you log in.",
            control: launchSwitch)

        // Reconnect-at-launch (roadmap 050): the opt-in that lets
        // `GroupController.ensureDefaultSelection()` resume the persisted
        // routing set instead of starting on this Mac's speakers only.
        reconnectSwitch.target = self
        reconnectSwitch.action = #selector(reconnectToggled)
        reconnectSwitch.state = settings.reconnectAtLaunch ? .on : .off
        reconnectSwitch.setAccessibilityLabel("Reconnect last speakers when Audiouter starts")
        let reconnectRow = SettingsForm.row(
            title: "Reconnect last speakers when Audiouter starts",
            control: reconnectSwitch)
        // Live hint (spec §5.2) — re-written on every toggle.
        reconnectHint.stringValue = Self.reconnectHintLine(settings.reconnectAtLaunch)

        // License (roadmap 054, Ardour model): entirely optional — the app is
        // fully functional with no key at all. The key persists on edit end
        // (focus loss), the same commit point `GroupEditorViewController`'s
        // rename field uses, via `NSTextFieldDelegate` below.
        licenseKeyField.stringValue = settings.licenseKey ?? ""
        licenseKeyField.placeholderString = "Optional"
        licenseKeyField.isEditable = true
        licenseKeyField.isSelectable = true
        licenseKeyField.delegate = self
        licenseKeyField.setAccessibilityLabel("License key")
        licenseKeyField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let licenseKeyRow = SettingsForm.row(
            title: "License key",
            subtitle: "From your purchase receipt. Optional — Audiouter is fully functional without it.",
            control: licenseKeyField)

        // Check-in consent (``LicenseCheckIn``) — the identified stream
        // (PRODUCT.md Data Collection stream 2), so it defaults off and is
        // never assumed on.
        licenseCheckInSwitch.target = self
        licenseCheckInSwitch.action = #selector(licenseCheckInConsentToggled)
        licenseCheckInSwitch.state = settings.licenseCheckInConsent ? .on : .off
        licenseCheckInSwitch.setAccessibilityLabel("Send license check-ins")
        let licenseConsentRow = SettingsForm.row(
            title: "Send license check-ins",
            control: licenseCheckInSwitch)
        licenseHint.stringValue = "Sends your license key and an install ID so we can count how many "
            + "Macs each license is used on. This is tied to your purchase — it is not anonymous. "
            + "Audiouter runs the same whether this is on or off."

        // Footer strip (roadmap 050): Setup and About are rare-use, so they
        // share one quiet button strip instead of two full title+subtitle rows.
        // "Open Setup…" re-opens the first-run permission-priming window — the
        // way a user re-checks the System Audio / Local Network grants after
        // changing them in System Settings (the flow itself deep-links there).
        // "About Audiouter…" opens the standalone About/Credits window (app
        // identity, GPL license + source link, third-party credits, support) —
        // see the type doc comment for why that content isn't inline here.
        setupButton.title = "Setup…"
        setupButton.bezelStyle = .rounded
        setupButton.controlSize = .small
        setupButton.target = self
        setupButton.action = #selector(runSetupAgainTapped)
        setupButton.setAccessibilityLabel("Open Setup")

        aboutButton.title = "About Audiouter…"
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

        buyButton.title = "Buy Audiouter…"
        buyButton.bezelStyle = .rounded
        buyButton.controlSize = .small
        buyButton.target = self
        buyButton.action = #selector(buyTapped)
        buyButton.setAccessibilityLabel("Buy an Audiouter license")

        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false

        let strip = NSStackView(views: [setupButton, aboutButton, updatesButton, buyButton])
        strip.orientation = .horizontal
        strip.alignment = .centerY
        strip.spacing = 8
        strip.translatesAutoresizingMaskIntoConstraints = false

        view = SettingsForm.paneView(rows: [launchRow, reconnectRow, reconnectHint,
                                             licenseKeyRow, licenseStatusHint,
                                             licenseConsentRow, licenseHint,
                                             hairline, strip])

        refreshLicenseStatus()
    }

    /// What the status line under the key field says, per state — plain words,
    /// no jargon, and never a claim the app is about to stop working. `nil`
    /// means the line is hidden: with no license server this build has nothing
    /// to verify against, so it says nothing at all.
    private static func licenseStatusLine(serverConfigured: Bool,
                                          keyIsEmpty: Bool,
                                          status: LicenseStatus?) -> String? {
        guard serverConfigured else { return nil }
        if keyIsEmpty { return "Unregistered. Buy a license to support Audiouter and get updates." }
        switch status {
        case .active: return "Registered. Thank you."
        case .revoked: return "This key was refunded or revoked. It no longer gets updates."
        case .unknown: return "This key isn’t recognised. Check it against your receipt."
        case .invalid: return "That doesn’t look like an Audiouter key (AUDR-XXXXX-XXXXX-XXXXX-XXXXX)."
        case nil: return "Couldn’t reach the license server — will try again next launch."
        }
    }

    /// Re-read the stored license state into the status line and the Buy
    /// button, then tell the app layer. Every path that can change the state —
    /// the launch build, a committed key, a validator answer — ends here, so
    /// there is one place that decides what the pane shows.
    private func refreshLicenseStatus() {
        let serverConfigured = settings.licenseServerURL != nil
        let key = settings.licenseKey ?? ""
        let status = settings.licenseStatus
        let line = Self.licenseStatusLine(serverConfigured: serverConfigured,
                                          keyIsEmpty: key.isEmpty,
                                          status: status)
        licenseStatusHint.stringValue = line ?? ""
        licenseStatusHint.isHidden = line == nil

        // Buying is offered only where it can work (a server) and only where it
        // would help (no key, or a key the server won’t honour).
        let unregistered = key.isEmpty || status == .unknown || status == .invalid || status == .revoked
        buyButton.isHidden = !(serverConfigured && unregistered && settings.buyURL != nil)

        onLicenseChanged?()
    }

    /// The reconnect-at-launch live hint: what the NEXT launch will do.
    private static func reconnectHintLine(_ enabled: Bool) -> String {
        enabled
            ? "Next launch reconnects the speakers you last used."
            : "Audiouter starts on this Mac's speakers only."
    }

    @objc private func reconnectToggled() {
        let enabled = reconnectSwitch.state == .on
        settings.reconnectAtLaunch = enabled
        reconnectHint.stringValue = Self.reconnectHintLine(enabled)
    }

    @objc private func licenseCheckInConsentToggled() {
        settings.licenseCheckInConsent = licenseCheckInSwitch.state == .on
    }

    /// Persists the license key and asks the server about it. Empty text
    /// clears it (`AppSettings.licenseKey` treats an empty string the same as
    /// any other value it stores — the field's placeholder, not a stored empty
    /// string, is what communicates "unset") and refreshes straight away, since
    /// there is nothing to ask about. A real key refreshes twice: once now
    /// from what is already known, and again when the answer lands.
    private func commitLicenseKey() {
        let text = licenseKeyField.stringValue
        // A different key is an unanswered question: the previous key's
        // verdict must not stand in for it while the server is asked.
        if text != settings.licenseKey { settings.licenseStatus = nil }
        settings.licenseKey = text.isEmpty ? nil : text
        refreshLicenseStatus()
        guard !text.isEmpty else { return }

        let validator = licenseTransport.map { LicenseValidator(settings: settings, transport: $0) }
            ?? LicenseValidator(settings: settings)
        validator.validate { [weak self] _ in
            guard let self else { return }
            // The server may have written back a canonical spelling.
            self.licenseKeyField.stringValue = self.settings.licenseKey ?? ""
            self.refreshLicenseStatus()
        }
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

    /// The license key field's current text.
    public var test_licenseKeyText: String {
        _ = view
        return licenseKeyField.stringValue
    }

    /// Type `text` into the license key field and commit it, the way focus
    /// loss (`controlTextDidEndEditing`) would.
    public func test_setLicenseKey(_ text: String) {
        _ = view
        licenseKeyField.stringValue = text
        commitLicenseKey()
    }

    /// Whether the "Send license check-ins" switch currently reads "on".
    public var test_licenseCheckInConsentIsOn: Bool {
        _ = view
        return licenseCheckInSwitch.state == .on
    }

    /// Drive the "Send license check-ins" switch and run the toggle action.
    public func test_toggleLicenseCheckInConsent(_ on: Bool) {
        _ = view
        licenseCheckInSwitch.state = on ? .on : .off
        licenseCheckInConsentToggled()
    }

    /// The license status line under the key field, or `nil` when it is hidden
    /// (a build with no license server has nothing to verify).
    public var test_licenseStatusText: String? {
        _ = view
        return licenseStatusHint.isHidden ? nil : licenseStatusHint.stringValue
    }

    /// Whether "Buy Audiouter…" is on screen.
    public var test_buyButtonIsVisible: Bool {
        _ = view
        return !buyButton.isHidden
    }

    /// The license check-in hint line's fixed disclosure copy.
    public var test_licenseHint: String {
        _ = view
        return licenseHint.stringValue
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

    /// Invoke "About Audiouter…" as a click would.
    public func test_tapAbout() {
        _ = view
        aboutTapped()
    }
}

// MARK: - NSTextFieldDelegate

extension GeneralSettingsViewController: NSTextFieldDelegate {
    /// Commit the license key when the field loses focus, not just on
    /// Return — the same edit-end commit point `GroupEditorViewController`'s
    /// rename field uses.
    public func controlTextDidEndEditing(_ obj: Notification) {
        commitLicenseKey()
    }
}
