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
    private let remoteControlSwitch = NSSwitch()
    private let remoteControlOverrideNote = SettingsForm.label("")
    private let consentSwitch = NSSwitch()
    private let consentHint = SettingsForm.hintLabel()
    private let licenseStatusHint = SettingsForm.hintLabel()
    private let checkAgainButton = NSButton()
    private let checkInDisclosureHint = SettingsForm.hintLabel(
        "Audiout checks in with the license server once per launch to spot a key "
        + "shared across many machines. It sends your key, a random per-Mac id, and the "
        + "app version. Nothing else.")
    private let enterLicenseButton = NSButton()
    private let loginApprovalButton = NSButton()
    private var loginApprovalRow: NSView?
    // The pane's column stack: the approval row is mounted into and unmounted
    // from it (never hidden in place — `NSStackView` keeps a hidden child's
    // last height, AGENTS.md).
    private weak var paneStack: NSStackView?
    private var licenseStatusRow: NSView?
    private var licenseRow: NSView?
    /// Guards against a second in-flight `LicenseValidator` round trip while
    /// one is already out — the button is disabled too, but appearing re-entry
    /// has no button to disable.
    private var revalidateInFlight = false
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

    // Remembered iPhones (T24): the per-phone approval list, mounted under
    // the remote-control switch — nil when the app layer didn't inject the
    // controller (headless constructions), in which case the section never
    // exists.
    private let approvals: CompanionApprovalController?
    private let phoneListHeading = SettingsForm.label("Remembered iPhones")
    private let phoneListStack = NSStackView()
    private let phoneListContainer = BorderedListView()
    private static let phoneRowHeight: CGFloat = 28

    /// Resolved once at init (the env var, if any, can't change for the life of
    /// this process) — what the switch must honestly reflect: the EFFECTIVE
    /// state, not the raw persisted ``AppSettings/allowRemoteControl`` (FIX-C).
    /// When ``AppSettings/RemoteControlResolution/isForced`` the switch
    /// renders disabled and ``remoteControlOverrideNote`` explains why.
    private let remoteControlResolution: AppSettings.RemoteControlResolution

    /// Fired when "Open Setup…" is clicked, so the app can re-present the
    /// first-run onboarding/permission-priming flow. Nil (unset) leaves the
    /// button inert — the app layer wires it in `openSettings`.
    public var onRunSetupAgain: (() -> Void)?

    /// Fired after "Allow control from iPhone on this network" changes and
    /// persists (T6), so the app layer can start/stop the companion server to
    /// match. Nil (unset) leaves the switch inert beyond persisting the
    /// setting — the app layer claims it in `openSettings`, matching
    /// ``onRunSetupAgain``'s single-assignment idiom.
    public var onAllowRemoteControlChanged: (() -> Void)?

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
    ///   - settings: backs the "Allow control from iPhone" switch; injectable
    ///     so tests use a throwaway `UserDefaults` suite, never `.standard`.
    ///   - environment: resolves ``AppSettings/RemoteControlResolution`` alongside
    ///     `settings` (the `AUDIOUT_COMPANION` dev knob); defaults to the real
    ///     process environment, injected as a fixed dictionary in tests.
    ///   - aboutInfo: the About window's bundle-sourced identity; defaults to
    ///     the live app bundle (`AboutInfo.current()`), injected as a fixed
    ///     value in tests so the rendered version string never depends on how
    ///     the test binary was built.
    ///   - openURL: opens the About window's "View Source Code…" link and the
    ///     "Buy Audiout…" button's purchase page; defaults to `NSWorkspace`,
    ///     injected as a recording closure in tests so a test run never
    ///     actually launches a browser.
    ///   - approvals: the per-phone approval model (T24) backing the
    ///     "Remembered iPhones" list; nil (the default) mounts no list at
    ///     all. The pane claims its `onChange` — a prompt answered while
    ///     the window is open must appear in the list live.
    public init(loginItem: LoginItemManaging,
                settings: AppSettings = AppSettings(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                aboutInfo: AboutInfo = .current(),
                openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
                approvals: CompanionApprovalController? = nil,
                saveDiagnostics: (() -> Void)? = nil) {
        self.loginItem = loginItem
        self.settings = settings
        self.approvals = approvals
        self.remoteControlResolution = AppSettings.resolvedAllowRemoteControlWithSource(
            environment: environment, settings: settings)
        self.openURL = openURL
        self.aboutWindowController = AboutWindowController(info: aboutInfo, openURL: openURL,
                                                           saveDiagnostics: saveDiagnostics)
        super.init(nibName: nil, bundle: nil)
        title = "General"
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// How much of the column a small trailing button in a hint row takes,
    /// including the 8pt gap — the width the hint beside it must wrap against.
    private static let trailingButtonWidth: CGFloat = 96

    public override func loadView() {
        launchSwitch.target = self
        launchSwitch.action = #selector(launchToggled)
        launchSwitch.setAccessibilityLabel("Launch at login")

        let launchRow = SettingsForm.row(
            title: "Launch at login",
            subtitle: "Open Audiout automatically when you log in.",
            control: launchSwitch)

        // `SMAppService.register()` can succeed into `.requiresApproval` —
        // registered, but inert until the user allows it in System Settings.
        // The switch springs back on its own; this row is the explanation and
        // the shortcut. Unmounted until `syncFromLoginItem()` finds that state.
        loginApprovalButton.title = "Open Login Items…"
        loginApprovalButton.bezelStyle = .rounded
        loginApprovalButton.controlSize = .small
        loginApprovalButton.target = self
        loginApprovalButton.action = #selector(openLoginItemsTapped)
        loginApprovalButton.translatesAutoresizingMaskIntoConstraints = false
        loginApprovalButton.setContentHuggingPriority(.required, for: .horizontal)
        loginApprovalButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let approvalHint = SettingsForm.hintLabel("macOS needs you to allow Audiout in Login Items.")
        approvalHint.preferredMaxLayoutWidth =
            SettingsForm.contentWidth - SettingsForm.horizontalPadding * 2 - Self.trailingButtonWidth
        // The column owns the width (the `SettingsForm.row` treatment): the
        // button keeps its size, the text yields.
        approvalHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let approvalRow = NSStackView(views: [approvalHint, loginApprovalButton])
        approvalRow.orientation = .horizontal
        approvalRow.alignment = .firstBaseline
        approvalRow.spacing = 8
        approvalRow.translatesAutoresizingMaskIntoConstraints = false
        loginApprovalRow = approvalRow

        // Reconnect-at-launch (roadmap 050): the opt-in that lets
        // `GroupController.ensureDefaultSelection()` resume the persisted
        // routing set instead of starting on this Mac's speakers only.
        reconnectSwitch.target = self
        reconnectSwitch.action = #selector(reconnectToggled)
        reconnectSwitch.state = settings.reconnectAtLaunch ? .on : .off
        reconnectSwitch.setAccessibilityLabel("Reconnect last speakers when Audiout starts")
        let reconnectRow = SettingsForm.row(
            title: "Reconnect last speakers when Audiout starts",
            subtitleLabel: reconnectHint,
            control: reconnectSwitch)
        // Live hint (spec §5.2) — re-written on every toggle. It is the row's
        // own subtitle, so it sits with its title the way Launch at login's
        // subtitle does instead of hanging a stack row below.
        reconnectHint.stringValue = Self.reconnectHintLine(settings.reconnectAtLaunch)

        // An `NSSwitch` like the four sibling on/off rows in this pane: one
        // control style for parallel on/off settings (launch review). Reflects
        // the EFFECTIVE state (`remoteControlResolution.value`), not the raw
        // persisted setting, and is disabled while an override is in force —
        // toggling it must be IMPOSSIBLE, not silently ineffective (FIX-C).
        remoteControlSwitch.state = remoteControlResolution.value ? .on : .off
        remoteControlSwitch.isEnabled = !remoteControlResolution.isForced
        remoteControlSwitch.target = self
        remoteControlSwitch.action = #selector(remoteControlToggled)
        remoteControlSwitch.setAccessibilityLabel("Allow control from iPhone on this network")
        let remoteControlRow = SettingsForm.row(
            title: "Allow control from iPhone on this network",
            subtitle: "Lets the Audiout companion app on your iPhone see and control this Mac's speakers.",
            control: remoteControlSwitch)

        // Same idiom as the Audio pane's `AIRPLAY_START_BUFFER_MS` override
        // note: `.warning`-colored caption, wrapping, explicit
        // `preferredMaxLayoutWidth` (an unset one drags the fixed-width pane
        // wider — see `SettingsForm.hintLabel`'s doc comment). Only mounted
        // when an override is actually in force.
        remoteControlOverrideNote.stringValue =
            "A launch option is controlling this setting, so the switch can't change it."
        remoteControlOverrideNote.font = Tokens.Font.caption
        remoteControlOverrideNote.textColor = Tokens.Color.label2
        remoteControlOverrideNote.lineBreakMode = .byWordWrapping
        remoteControlOverrideNote.maximumNumberOfLines = 0
        remoteControlOverrideNote.preferredMaxLayoutWidth = SettingsForm.contentWidth - 40

        // Anonymous usage analytics (opt-in, off by default) — the Settings ›
        // General toggle for the consent `AppSettings.telemetryOptIn` gates.
        consentSwitch.target = self
        consentSwitch.action = #selector(consentToggled)
        consentSwitch.state = settings.telemetryOptIn ? .on : .off
        consentSwitch.setAccessibilityLabel("Share anonymous usage statistics")
        let consentRow = SettingsForm.row(
            title: "Share anonymous usage statistics",
            subtitleLabel: consentHint,
            control: consentSwitch)
        consentHint.stringValue = Self.consentHintLine(settings.telemetryOptIn)

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

        buyButton.title = "Buy Audiout…"
        buyButton.bezelStyle = .rounded
        buyButton.target = self
        buyButton.action = #selector(buyTapped)

        let licenseButtons = NSStackView(views: [enterLicenseButton, buyButton])
        licenseButtons.orientation = .horizontal
        licenseButtons.alignment = .centerY
        licenseButtons.spacing = 8
        licenseButtons.translatesAutoresizingMaskIntoConstraints = false
        let licenseKeyRow = SettingsForm.row(title: "License", control: licenseButtons)
        licenseRow = licenseKeyRow

        // The retry the status line promises, made a button instead of a wait
        // for the next launch. Shown only in the one state it can help.
        checkAgainButton.title = "Check again"
        checkAgainButton.bezelStyle = .rounded
        checkAgainButton.controlSize = .small
        checkAgainButton.target = self
        checkAgainButton.action = #selector(checkAgainTapped)
        checkAgainButton.translatesAutoresizingMaskIntoConstraints = false
        checkAgainButton.setContentHuggingPriority(.required, for: .horizontal)
        checkAgainButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        licenseStatusHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let licenseStatusRow = NSStackView(views: [licenseStatusHint, checkAgainButton])
        licenseStatusRow.orientation = .horizontal
        licenseStatusRow.alignment = .firstBaseline
        licenseStatusRow.spacing = 8
        licenseStatusRow.translatesAutoresizingMaskIntoConstraints = false
        self.licenseStatusRow = licenseStatusRow

        // Footer strip (roadmap 050): Setup and About are rare-use, so they
        // share one quiet button strip instead of two full title+subtitle rows.
        // "Open Setup…" re-opens the first-run permission-priming window — the
        // way a user re-checks the System Audio / Local Network grants after
        // changing them in System Settings (the flow itself deep-links there).
        // "About Audiout…" opens the standalone About/Credits window (app
        // identity, GPL license + source link, third-party credits, support) —
        // see the type doc comment for why that content isn't inline here.
        setupButton.title = "Run setup again…"
        setupButton.bezelStyle = .rounded
        setupButton.controlSize = .small
        setupButton.target = self
        setupButton.action = #selector(runSetupAgainTapped)

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
        // One row per line: other tracks append rows here, and a one-per-line
        // array merges cleanly.
        var rows: [NSView] = [
            launchRow,
            reconnectRow,
            remoteControlRow,
        ]
        if remoteControlResolution.isForced {
            rows.append(remoteControlOverrideNote)
        }
        if approvals != nil {
            rows.append(contentsOf: makePhoneListViews())
        }
        if TouchBarHardware.isPresent {
            touchBarSwitch.target = self
            touchBarSwitch.action = #selector(touchBarToggled)
            touchBarSwitch.state = settings.touchBarControlsEnabled ? .on : .off
            touchBarSwitch.setAccessibilityLabel("Use Audiout's Touch Bar controls")
            rows.append(SettingsForm.row(
                title: "Use Audiout's Touch Bar controls",
                subtitle: "While Audiout is playing to speakers, the Touch Bar volume keys control the speakers instead of the Mac.",
                control: touchBarSwitch))
        }
        rows.append(contentsOf: [
            consentRow,
            licenseKeyRow,
            licenseStatusRow,
            checkInDisclosureHint,
            hairline,
            strip,
        ])

        view = SettingsForm.paneView(rows: rows)
        paneStack = launchRow.superview as? NSStackView
        rebuildPhoneList()
        // Claimed here (single-assignment, like the app layer's claims on
        // this pane's own callbacks): a prompt answered or a phone revoked
        // while the window is open repaints the list live.
        approvals?.onChange = { [weak self] in self?.rebuildPhoneList() }

        refreshLicenseStatus()
    }

    /// What the status line under the License row says, per state — plain
    /// words, no jargon, and never a claim the app is about to stop working.
    /// The four server-verdict strings come from
    /// ``LicenseSheetViewController/statusLine(for:)`` so the pane and the
    /// sheet can never drift apart; the two key-side states are the pane's own.
    ///
    /// The no-verdict line leads with the state the user cares about (their key
    /// is safe) rather than with the failure, and promises nothing about when
    /// the retry happens — Check Again sits beside it.
    private static func licenseStatusLine(keyIsEmpty: Bool,
                                          status: LicenseStatus?) -> String {
        if keyIsEmpty {
            // Post-gate truth (2026-08-30): an official build asks for its key
            // at launch, so "fully functional without a license" would lie here.
            return "Unregistered. Audiout keeps working for this session, and asks "
                + "for a license key the next time it opens."
        }
        guard let status else {
            return "Your key is saved. Audiout hasn’t been able to verify it yet."
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
        // The row itself, not just its children: an empty row still costs the
        // stack its spacing. `serverConfigured` is fixed for the pane's life
        // and this first runs before the first layout, so plain `isHidden` is
        // safe here (the row is never shown-then-hidden).
        licenseStatusRow?.isHidden = !serverConfigured

        let key = settings.licenseKey ?? ""
        let status = settings.licenseStatus
        if serverConfigured {
            licenseStatusHint.stringValue = Self.licenseStatusLine(keyIsEmpty: key.isEmpty,
                                                                   status: status)
        }

        // Only where it can do something: a key is stored, and no verdict has
        // ever come back for it.
        let canRetry = serverConfigured && !key.isEmpty && status == nil
        checkAgainButton.isHidden = !canRetry
        // The wrap-width trap (`SettingsForm.hintLabel`): the label must be
        // told the width it will actually get, or it computes its intrinsic
        // height against a line it never gets to use.
        licenseStatusHint.preferredMaxLayoutWidth =
            SettingsForm.contentWidth - SettingsForm.horizontalPadding * 2
            - (canRetry ? Self.trailingButtonWidth : 0)

        // Disclosed exactly when a check-in can actually fire
        // (`LicenseCheckIn.checkInIfNeeded` guards on key + endpoint) — never
        // as a standing claim about a build that never phones home.
        checkInDisclosureHint.isHidden = !(serverConfigured && !key.isEmpty)

        // "Enter License…" before a key exists; "Change…" once one is stored
        // (the sheet then prefills it and offers Remove License…).
        enterLicenseButton.title = key.isEmpty ? "Enter license…" : "Change…"

        // Buying is offered only where it can work (a server) and only where it
        // would help (no key, or a key the server won’t honour).
        buyButton.isHidden = !(serverConfigured && settings.licenseUnregistered && settings.buyURL != nil)

        onLicenseChanged?()
    }

    /// Present the Enter License… sheet (`MixerWindowController
    /// .presentCreateSheet`'s idiom: strong reference always, `presentAsSheet`
    /// only when a visible window can host it — headless tests drive the held
    /// controller's hooks directly).
    @objc private func enterLicenseTapped() {
        // A second click while one is up would replace the held sheet and
        // orphan the presented one.
        guard licenseSheet == nil else { return }
        Analytics.capture("license:enter_sheet_opened")
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

    /// Open the Enter License… sheet pre-filled with `key` and submit it — the
    /// landing point for the purchase flow's `audiout://register?key=…` link.
    /// The user already asked for this by following the link, so the Register
    /// click is not asked for a second time; the sheet is what shows the result.
    /// A sheet already up is re-used rather than replaced.
    public func presentLicenseSheet(registering key: String) {
        enterLicenseTapped()
        licenseSheet?.submit(key: key)
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
        Analytics.capture("settings:reconnect_at_launch_toggled", ["enabled": enabled ? "true" : "false"])
    }

    /// The "Remembered iPhones" section (T24): a caption + bordered
    /// `name · decision · remove` list, the Audio pane's excluded-apps idiom
    /// compacted. Both views are hidden (not unmounted) while the list is
    /// empty, so a first phone appearing mid-session can show up live.
    private func makePhoneListViews() -> [NSView] {
        phoneListHeading.font = Tokens.Font.captionEmphasized
        phoneListHeading.textColor = Tokens.Color.label2

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
            ? Tokens.Color.label2 : Tokens.Color.label2

        let remove = NSButton()
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.isBordered = false
        remove.setButtonType(.momentaryChange)
        remove.imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        remove.image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove")?
            .withSymbolConfiguration(config)
        remove.contentTintColor = Tokens.Color.label2
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

    /// The usage-analytics consent live hint: what sharing does or doesn't do.
    private static func consentHintLine(_ enabled: Bool) -> String {
        enabled
            ? "Anonymous feature counts and crash reports help improve Audiout."
            : "No usage data leaves this Mac."
    }

    @objc private func consentToggled() {
        let enabled = consentSwitch.state == .on
        settings.telemetryOptIn = enabled
        settings.telemetryAsked = true
        Analytics.setConsent(enabled)
        consentHint.stringValue = Self.consentHintLine(enabled)
    }

    @objc private func touchBarToggled() {
        settings.touchBarControlsEnabled = touchBarSwitch.state == .on
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        syncFromLoginItem()
        // The one retry trigger that costs the user nothing: coming back to
        // this pane. Its own guards make it a no-op without a server or a key.
        if settings.licenseStatus == nil { revalidate() }
    }

    /// Re-ask the server about the stored key, then re-display. Chosen over an
    /// `NWPathMonitor` reachability watch: no monitor lifecycle to own in a
    /// session-long controller, and the validator is idempotent (the server
    /// answers 200 for every verdict), so extra calls are harmless.
    private func revalidate() {
        guard !revalidateInFlight,
              settings.licenseServerURL != nil,
              !(settings.licenseKey ?? "").isEmpty else { return }
        revalidateInFlight = true
        checkAgainButton.isEnabled = false
        let validator = licenseTransport.map { LicenseValidator(settings: settings, transport: $0) }
            ?? LicenseValidator(settings: settings)
        validator.validate { [weak self] _ in
            guard let self else { return }
            self.revalidateInFlight = false
            self.checkAgainButton.isEnabled = true
            self.refreshLicenseStatus()
        }
    }

    @objc private func checkAgainTapped() { revalidate() }

    @objc private func openLoginItemsTapped() { loginItem.openSystemSettingsLoginItems() }

    /// The ONE place the login-item surface is re-read: the switch follows the
    /// live system state, and the approval row appears exactly when the system
    /// is holding the registration for the user to allow.
    private func syncFromLoginItem() {
        launchSwitch.state = loginItem.isEnabled ? .on : .off
        // Mount/unmount rather than `isHidden`: the stack keeps a hidden
        // child's last height, so the row is only ever in the stack while it
        // has something to say.
        guard let row = loginApprovalRow, let stack = paneStack else { return }
        if loginItem.needsApproval, row.superview == nil {
            stack.insertArrangedSubview(row, at: 1) // right under Launch at login
            // `removeFromSuperview` dropped the width pin `paneView` gave it.
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else if !loginItem.needsApproval, row.superview != nil {
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
    }

    @objc private func remoteControlToggled() {
        // Toggling while overridden must be IMPOSSIBLE, not silently
        // ineffective (FIX-C) — the switch is disabled so a real click
        // never reaches here, but a `test_` hook drives the action directly,
        // so the guard lives here too: bounce back to the effective value
        // rather than persisting a setting that can't take effect.
        guard !remoteControlResolution.isForced else {
            remoteControlSwitch.state = remoteControlResolution.value ? .on : .off
            return
        }
        settings.allowRemoteControl = remoteControlSwitch.state == .on
        onAllowRemoteControlChanged?()
    }

    @objc private func runSetupAgainTapped() { onRunSetupAgain?() }

    @objc private func aboutTapped() { aboutWindowController.show() }

    @objc private func checkForUpdatesTapped() { onCheckForUpdates?() }

    @objc private func buyTapped() {
        guard let url = settings.buyURL else { return }
        Analytics.capture("license:buy_link_opened", ["source": "settings"])
        openURL(url)
    }

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

    /// Whether "Check Again" is offered beside the status line.
    public var test_checkAgainIsVisible: Bool {
        _ = view
        return !checkAgainButton.isHidden
    }

    /// Invoke "Check Again" as a click would.
    public func test_tapCheckAgain() {
        _ = view
        checkAgainTapped()
    }

    /// The check-in disclosure line, or `nil` while it is hidden.
    public var test_checkInDisclosureText: String? {
        _ = view
        return checkInDisclosureHint.isHidden ? nil : checkInDisclosureHint.stringValue
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

    /// Invoke "Open Setup…" as a click would.
    public func test_tapRunSetupAgain() {
        _ = view
        runSetupAgainTapped()
    }

    // MARK: Test-support hooks (Companion — T6, FIX-C)

    /// Whether the switch currently reads "on" — the EFFECTIVE state
    /// (`remoteControlResolution.value`), not necessarily the raw persisted
    /// `AppSettings.allowRemoteControl` (FIX-C: they can legitimately differ
    /// while an override is in force).
    public var test_allowRemoteControlIsOn: Bool {
        _ = view
        return remoteControlSwitch.state == .on
    }

    /// Whether the switch is currently clickable — `false` while
    /// `AUDIOUT_COMPANION` (or an explicit override) is in force (FIX-C).
    public var test_allowRemoteControlIsEnabled: Bool {
        _ = view
        return remoteControlSwitch.isEnabled
    }

    /// The override explanation line's text, or `nil` when no override is in
    /// force (it isn't mounted in the pane at all in that case) — FIX-C.
    public var test_allowRemoteControlOverrideNote: String? {
        _ = view
        return remoteControlResolution.isForced ? remoteControlOverrideNote.stringValue : nil
    }

    /// The override note's actual rendered text colour — pins that this is a
    /// plain caption, not the failure/warning red (it names a setting, not a
    /// problem).
    public var test_allowRemoteControlOverrideNoteTextColor: NSColor {
        _ = view
        return remoteControlOverrideNote.textColor ?? .clear
    }

    /// Drive the switch to `on`/`off` and run the same action a real click
    /// would. While overridden this is a no-op on the persisted setting (the
    /// action itself refuses, mirroring the disabled real control) — FIX-C.
    public func test_toggleAllowRemoteControl(_ on: Bool) {
        _ = view
        remoteControlSwitch.state = on ? .on : .off
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

    /// The rendered Allowed/Denied caption's actual text colour at a row
    /// index — pins that a recorded decision is a plain word, not the
    /// failure/warning red, regardless of which way the decision went.
    public func test_phoneRowDecisionTextColor(at index: Int) -> NSColor? {
        _ = view
        guard phoneListStack.arrangedSubviews.indices.contains(index) else { return nil }
        let row = phoneListStack.arrangedSubviews[index]
        return row.subviews.compactMap { $0 as? NSTextField }.dropFirst().first?.textColor
    }

    /// Revoke a phone through the same path its row's ✕ button runs.
    public func test_revokePhone(clientID: String) {
        _ = view
        approvals?.revoke(clientID: clientID)
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
