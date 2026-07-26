// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

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
    private let remoteControlOverrideNote = SettingsForm.label("")
    private let setupButton = NSButton()
    private let aboutButton = NSButton()
    private let aboutWindowController: AboutWindowController

    // Remembered iPhones (T24): the per-phone approval list, mounted under
    // the remote-control checkbox — nil when the app layer didn't inject the
    // controller (headless constructions), in which case the section never
    // exists.
    private let approvals: CompanionApprovalController?
    private let phoneListHeading = SettingsForm.label("Remembered iPhones")
    private let phoneListStack = NSStackView()
    private let phoneListContainer = BorderedListView()
    private static let phoneRowHeight: CGFloat = 28

    /// Resolved once at init (the env var, if any, can't change for the life of
    /// this process) — what the checkbox must honestly reflect: the EFFECTIVE
    /// state, not the raw persisted ``AppSettings/allowRemoteControl`` (FIX-C).
    /// When ``AppSettings/RemoteControlResolution/isForced`` the checkbox
    /// renders disabled and ``remoteControlOverrideNote`` explains why.
    private let remoteControlResolution: AppSettings.RemoteControlResolution

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
    ///   - environment: resolves ``AppSettings/RemoteControlResolution`` alongside
    ///     `settings` (the `AUDIOUTER_COMPANION` dev knob); defaults to the real
    ///     process environment, injected as a fixed dictionary in tests.
    ///   - aboutInfo: the About window's bundle-sourced identity; defaults to
    ///     the live app bundle (`AboutInfo.current()`), injected as a fixed
    ///     value in tests so the rendered version string never depends on how
    ///     the test binary was built.
    ///   - openURL: opens the About window's "View Source Code" link; defaults
    ///     to `NSWorkspace`, injected as a recording closure in tests so a
    ///     test run never actually launches a browser.
    ///   - approvals: the per-phone approval model (T24) backing the
    ///     "Remembered iPhones" list; nil (the default) mounts no list at
    ///     all. The pane claims its `onChange` — a prompt answered while
    ///     the window is open must appear in the list live.
    public init(loginItem: LoginItemManaging,
                settings: AppSettings = AppSettings(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                aboutInfo: AboutInfo = .current(),
                openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
                approvals: CompanionApprovalController? = nil) {
        self.loginItem = loginItem
        self.settings = settings
        self.approvals = approvals
        self.remoteControlResolution = AppSettings.resolvedAllowRemoteControlWithSource(
            environment: environment, settings: settings)
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
        // idiom) — no inline title, the row label carries it. Reflects the
        // EFFECTIVE state (`remoteControlResolution.value`), not the raw
        // persisted setting, and is disabled while an override is in force —
        // toggling it must be IMPOSSIBLE, not silently ineffective (FIX-C).
        remoteControlCheckbox.setButtonType(.switch)
        remoteControlCheckbox.title = ""
        remoteControlCheckbox.state = remoteControlResolution.value ? .on : .off
        remoteControlCheckbox.isEnabled = !remoteControlResolution.isForced
        remoteControlCheckbox.target = self
        remoteControlCheckbox.action = #selector(remoteControlToggled)
        remoteControlCheckbox.setAccessibilityLabel("Allow control from iPhone on this network")
        let remoteControlRow = SettingsForm.row(
            title: "Allow control from iPhone on this network",
            subtitle: "Lets the Audiouter companion app on your iPhone see and control this Mac's speakers.",
            control: remoteControlCheckbox)

        // Same idiom as the Audio pane's `AIRPLAY_START_BUFFER_MS` override
        // note: `.warning`-colored caption, wrapping, explicit
        // `preferredMaxLayoutWidth` (an unset one drags the fixed-width pane
        // wider — see `SettingsForm.hintLabel`'s doc comment). Only mounted
        // when an override is actually in force.
        remoteControlOverrideNote.stringValue =
            "Controlled by the \(AppSettings.allowRemoteControlEnvironmentVariableName) "
            + "setting for this launch — the checkbox can't change it."
        remoteControlOverrideNote.font = Tokens.Font.caption
        remoteControlOverrideNote.textColor = Tokens.Color.warning
        remoteControlOverrideNote.lineBreakMode = .byWordWrapping
        remoteControlOverrideNote.maximumNumberOfLines = 0
        remoteControlOverrideNote.preferredMaxLayoutWidth = SettingsForm.contentWidth - 40

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

        var rows = [launchRow, remoteControlRow]
        if remoteControlResolution.isForced {
            rows.append(remoteControlOverrideNote)
        }
        if approvals != nil {
            rows.append(contentsOf: makePhoneListViews())
        }
        rows.append(contentsOf: [setupRow, aboutRow])
        view = SettingsForm.paneView(rows: rows)
        rebuildPhoneList()
        // Claimed here (single-assignment, like the app layer's claims on
        // this pane's own callbacks): a prompt answered or a phone revoked
        // while the window is open repaints the list live.
        approvals?.onChange = { [weak self] in self?.rebuildPhoneList() }
    }

    /// The "Remembered iPhones" section (T24): a caption + bordered
    /// `name · decision · remove` list, the Audio pane's excluded-apps idiom
    /// compacted. Both views are hidden (not unmounted) while the list is
    /// empty, so a first phone appearing mid-session can show up live.
    private func makePhoneListViews() -> [NSView] {
        phoneListHeading.font = Tokens.Font.captionEmphasized
        phoneListHeading.textColor = Tokens.Color.secondaryLabel

        phoneListStack.orientation = .vertical
        phoneListStack.alignment = .leading
        phoneListStack.spacing = 0
        phoneListStack.translatesAutoresizingMaskIntoConstraints = false
        phoneListContainer.translatesAutoresizingMaskIntoConstraints = false
        phoneListContainer.addSubview(phoneListStack)
        NSLayoutConstraint.activate([
            phoneListStack.leadingAnchor.constraint(equalTo: phoneListContainer.leadingAnchor),
            phoneListStack.trailingAnchor.constraint(equalTo: phoneListContainer.trailingAnchor),
            phoneListStack.topAnchor.constraint(equalTo: phoneListContainer.topAnchor, constant: 4),
            phoneListStack.bottomAnchor.constraint(equalTo: phoneListContainer.bottomAnchor, constant: -4),
        ])
        return [phoneListHeading, phoneListContainer]
    }

    /// Repopulate the phone list and republish the pane's size (the same
    /// `preferredContentSize` route the Audio pane's excluded-apps list uses
    /// to reach the window — see `AudioSettingsViewController.rebuildList`).
    private func rebuildPhoneList() {
        guard let approvals, isViewLoaded else { return }
        for row in phoneListStack.arrangedSubviews {
            phoneListStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        let isEmpty = approvals.approvals.isEmpty
        phoneListHeading.isHidden = isEmpty
        phoneListContainer.isHidden = isEmpty
        for approval in approvals.approvals {
            phoneListStack.addArrangedSubview(makePhoneRow(approval))
        }
        for row in phoneListStack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: phoneListStack.widthAnchor).isActive = true
        }
        // (The container itself is width-pinned by `SettingsForm.paneView`,
        // like every other row.)
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: SettingsForm.contentWidth, height: view.fittingSize.height)
    }

    /// One remembered phone: name · Allowed/Denied · ✕. The identity shown is
    /// only the phone's (already truncated) display name — the raw clientID
    /// never reaches UI; it rides the remove button's identifier.
    private func makePhoneRow(_ approval: CompanionApproval) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = SettingsForm.label(approval.lastKnownName)
        nameLabel.lineBreakMode = .byTruncatingTail

        let decisionLabel = SettingsForm.label(approval.decision == .approved ? "Allowed" : "Denied")
        decisionLabel.font = Tokens.Font.caption
        decisionLabel.textColor = approval.decision == .approved
            ? Tokens.Color.secondaryLabel : Tokens.Color.warning

        let remove = NSButton()
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.isBordered = false
        remove.setButtonType(.momentaryChange)
        remove.imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        remove.image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove")?
            .withSymbolConfiguration(config)
        remove.contentTintColor = Tokens.Color.secondaryLabel
        remove.target = self
        remove.action = #selector(revokePhoneTapped(_:))
        remove.identifier = NSUserInterfaceItemIdentifier(approval.clientID)
        remove.setAccessibilityLabel("Remove \(approval.lastKnownName)")

        row.addSubview(nameLabel)
        row.addSubview(decisionLabel)
        row.addSubview(remove)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: Self.phoneRowHeight),
            nameLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: decisionLabel.leadingAnchor, constant: -8),
            decisionLabel.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -8),
            decisionLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            remove.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            remove.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    @objc private func revokePhoneTapped(_ sender: NSButton) {
        guard let clientID = sender.identifier?.rawValue else { return }
        // The controller persists, drops any live client with that identity,
        // and fires onChange — which rebuilds this list.
        approvals?.revoke(clientID: clientID)
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
        // Toggling while overridden must be IMPOSSIBLE, not silently
        // ineffective (FIX-C) — the checkbox is disabled so a real click
        // never reaches here, but a `test_` hook drives the action directly,
        // so the guard lives here too: bounce back to the effective value
        // rather than persisting a setting that can't take effect.
        guard !remoteControlResolution.isForced else {
            remoteControlCheckbox.state = remoteControlResolution.value ? .on : .off
            return
        }
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

    // MARK: Test-support hooks (Companion — T6, FIX-C)

    /// Whether the checkbox currently reads "on" — the EFFECTIVE state
    /// (`remoteControlResolution.value`), not necessarily the raw persisted
    /// `AppSettings.allowRemoteControl` (FIX-C: they can legitimately differ
    /// while an override is in force).
    public var test_allowRemoteControlIsOn: Bool {
        _ = view
        return remoteControlCheckbox.state == .on
    }

    /// Whether the checkbox is currently clickable — `false` while
    /// `AUDIOUTER_COMPANION` (or an explicit override) is in force (FIX-C).
    public var test_allowRemoteControlIsEnabled: Bool {
        _ = view
        return remoteControlCheckbox.isEnabled
    }

    /// The override explanation line's text, or `nil` when no override is in
    /// force (it isn't mounted in the pane at all in that case) — FIX-C.
    public var test_allowRemoteControlOverrideNote: String? {
        _ = view
        return remoteControlResolution.isForced ? remoteControlOverrideNote.stringValue : nil
    }

    /// Drive the checkbox to `on`/`off` and run the same action a real click
    /// would. While overridden this is a no-op on the persisted setting (the
    /// action itself refuses, mirroring the disabled real control) — FIX-C.
    public func test_toggleAllowRemoteControl(_ on: Bool) {
        _ = view
        remoteControlCheckbox.state = on ? .on : .off
        remoteControlToggled()
    }

    // MARK: Test-support hooks (Remembered iPhones — T24)

    /// The rendered phone rows as `(name, decision)` pairs, in list order —
    /// read from the controller the way the rebuild does, after forcing the
    /// same load/rebuild a real show performs.
    public var test_rememberedPhones: [(name: String, decision: String)] {
        _ = view
        return approvals?.approvals.map {
            ($0.lastKnownName, $0.decision == .approved ? "Allowed" : "Denied")
        } ?? []
    }

    /// Whether the list section is currently visible (it hides entirely when
    /// no phone was ever remembered).
    public var test_phoneListIsVisible: Bool {
        _ = view
        return !phoneListContainer.isHidden && phoneListContainer.superview != nil
    }

    /// The number of rendered phone rows (proves the VIEW rebuilt, not just
    /// the model).
    public var test_phoneRowCount: Int {
        _ = view
        return phoneListStack.arrangedSubviews.count
    }

    /// Revoke a phone through the same path its row's ✕ button runs.
    public func test_revokePhone(clientID: String) {
        _ = view
        approvals?.revoke(clientID: clientID)
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
