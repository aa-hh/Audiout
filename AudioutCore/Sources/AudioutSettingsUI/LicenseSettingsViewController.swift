// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// Settings › **License** (roadmap 054, Ardour model): entirely optional — the
/// app works with no key at all. NO inline key field: entry is a deliberate
/// act behind "Enter license…" (a sheet), the convention every respected
/// optional-license app follows. The pane is one recessed well holding the
/// status sentence and the two buttons, with the check-in disclosure under it.
/// The app builds this section only when there is a licence server
/// (``isAvailable``): a build from source has nothing to verify and nothing
/// to sell.
@MainActor
public final class LicenseSettingsViewController: NSViewController, SettingsReadoutProviding {

    private let settings: AppSettings
    private let openURL: (URL) -> Void
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let checkAgainButton = NSButton()
    private let checkInDisclosureHint = SettingsPane.makeNote(
        "Audiout checks in with the license server once per launch to spot a key "
        + "shared across many machines. It sends your key, a random per-Mac id, and the "
        + "app version. Nothing else.")
    private let enterLicenseButton = NSButton()
    private lazy var buyButton = ProminentButton(title: "Buy Audiout", target: self, action: #selector(buyTapped))
    private var well: NSView?
    private var headerGlyph: NSImageView?
    private var headerCaption: NSTextField?
    /// Guards against a second in-flight `LicenseValidator` round trip while
    /// one is already out — the button is disabled too, but appearing re-entry
    /// has no button to disable.
    private var revalidateInFlight = false
    /// The presented (or headlessly held) Enter License… sheet — strong, the
    /// `MixerWindowController.presentCreateSheet` idiom: headless tests never
    /// present, they hold this and drive its `test_` hooks.
    private var licenseSheet: LicenseSheetViewController?

    /// Whether this build has a licence server, and so a License section.
    public var isAvailable: Bool { settings.licenseServerURL != nil }

    /// Fired at the end of every license status refresh — launch, and every
    /// commit of the key field. The app layer re-reads ``AppSettings`` from it
    /// (the unregistered note, the Sparkle authorization header); nil leaves
    /// this pane's own display the only thing that moves.
    public var onLicenseChanged: (() -> Void)?

    /// The transport ``LicenseValidator`` uses when this pane checks a
    /// freshly-entered key. Nil (unset) is the real network, which is what the
    /// app always wants; tests stub it so a commit never leaves the machine.
    public var licenseTransport: LicenseValidator.Transport?

    var onReadoutChanged: (() -> Void)?

    /// - Parameters:
    ///   - settings: the stored key, verdict, trial dates and server URLs;
    ///     injectable so tests use a throwaway `UserDefaults` suite.
    ///   - openURL: opens the "Buy Audiout" purchase page; injected as a
    ///     recording closure in tests so a test run never launches a browser.
    public init(settings: AppSettings = AppSettings(),
                openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.settings = settings
        self.openURL = openURL
        super.init(nibName: nil, bundle: nil)
        title = "License"
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// How much of the well a small trailing button beside the status takes,
    /// including the 8pt gap — the width the status must wrap against.
    private static let trailingButtonWidth: CGFloat = 96
    /// The well's inner width: the lane minus its 14 pt side padding.
    private static let wellContentWidth: CGFloat = GroupsPaneLayout.railFreeContentWidth - 28

    // MARK: Readout

    private var trialIsActive: Bool {
        if case .active = TrialClock.state(settings: settings) { return true }
        return false
    }

    var readoutLines: [String] {
        let first = Self.readoutFirstLine(settings: settings)
        guard LicenseGate.limitsToOneSpeaker(settings: settings), !trialIsActive else { return [first] }
        return [first, "One speaker at a time"]
    }

    /// `ring` while the user must act; `labelCool` while the licence is fine.
    var readoutGlyphTint: NSColor {
        let first = Self.readoutFirstLine(settings: settings)
        let fine = first == "Registered" || first == "Key saved, not verified" || first.hasPrefix("Trial · ")
        return fine ? Tokens.Color.labelCool : Tokens.Color.ring
    }

    private static func readoutFirstLine(settings: AppSettings) -> String {
        if case .active(let daysLeft, _, _) = TrialClock.state(settings: settings) {
            return LicenseCopy.trialPillText(daysLeft: daysLeft)
        }
        if (settings.licenseKey ?? "").isEmpty { return "Unregistered" }
        if TrialClock.hasEnded(settings: settings), LicenseGate.limitsToOneSpeaker(settings: settings) {
            return "Trial ended"
        }
        guard let status = settings.licenseStatus else { return "Key saved, not verified" }
        switch status {
        case .active: return "Registered"
        case .revoked:
            switch settings.licenseReason {
            case "refund": return "Key refunded"
            case "chargeback": return "Payment reversed"
            default: return "Key revoked"
            }
        case .unknown: return "Key not recognized"
        case .invalid: return "Not an Audiout key"
        }
    }

    // MARK: Layout

    public override func loadView() {
        let (header, glyph) = SettingsPane.makeHeader(symbolName: "key", title: "License",
                                                      caption: Self.readoutFirstLine(settings: settings))
        headerGlyph = glyph
        headerCaption = header.textStack.arrangedSubviews.last as? NSTextField

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = Tokens.Font.body
        statusLabel.textColor = Tokens.Color.label
        statusLabel.maximumNumberOfLines = 0
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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

        let statusRow = NSStackView(views: [statusLabel, checkAgainButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .firstBaseline
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        enterLicenseButton.bezelStyle = .rounded
        enterLicenseButton.target = self
        enterLicenseButton.action = #selector(enterLicenseTapped)

        let buttons = NSStackView(views: [enterLicenseButton, buyButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let wellContent = NSStackView(views: [statusRow, buttons])
        wellContent.orientation = .vertical
        wellContent.alignment = .leading
        wellContent.spacing = 10
        wellContent.translatesAutoresizingMaskIntoConstraints = false

        let box = GroupedSectionView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.style = .well
        box.radiusOverride = Tokens.Layout.Radius.row

        let well = NSView()
        well.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(box)
        well.addSubview(wellContent)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: well.topAnchor),
            box.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            box.bottomAnchor.constraint(equalTo: well.bottomAnchor),
            wellContent.topAnchor.constraint(equalTo: well.topAnchor, constant: 13),
            wellContent.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 14),
            wellContent.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -14),
            wellContent.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -12),
            statusRow.widthAnchor.constraint(equalTo: wellContent.widthAnchor),
        ])
        self.well = well

        let page = SettingsForm.pageView(content: [header, well, checkInDisclosureHint])
        (page.subviews.first as? NSStackView)?.setCustomSpacing(8, after: well)
        view = page

        refreshLicenseStatus()
    }

    /// What the status line says, per state — plain words, no jargon, and
    /// never a claim the app is about to stop working. The four server-verdict
    /// strings come from ``LicenseSheetViewController/statusLine(for:reason:)``
    /// so the pane and the sheet can never drift apart; the two key-side
    /// states are the pane's own.
    ///
    /// The no-verdict line leads with the state the user cares about (their key
    /// is safe) rather than with the failure, and promises nothing about when
    /// the retry happens — Check again sits beside it.
    private static func licenseStatusLine(keyIsEmpty: Bool,
                                          status: LicenseStatus?,
                                          reason: String?) -> String {
        if keyIsEmpty {
            // Since 2026-09-26 an unregistered install is not gated; it runs
            // limited to one speaker (dev/notes/unregistered-mode-spec-2026-09-26.md).
            return "Unregistered. Audiout keeps working, on one speaker at a time, "
                + "until it has a license key."
        }
        guard let status else {
            return "Your key is saved. Audiout hasn’t been able to verify it yet."
        }
        return LicenseSheetViewController.statusLine(for: status, reason: reason)
    }

    /// The line for a limited install, which must agree with the limit:
    /// an ended trial reads the trial sentence whatever verdict is cached (the
    /// server answers one with `revoked`, reason `trial_expired`, and an offline
    /// one keeps `active`), and a refused key names the server's reason, the
    /// popover note's own wording. `nil` defers to the verdict line.
    private func limitedStatusLine() -> String? {
        guard LicenseGate.limitsToOneSpeaker(settings: settings) else { return nil }
        if TrialClock.hasEnded(settings: settings) {
            return "Your trial has ended. Audiout plays on one speaker at a time until you buy."
        }
        guard settings.licenseStatus == .revoked else { return nil }
        return LicenseCopy.oneSpeakerKeyRefusedLine(reason: settings.licenseReason)
    }

    /// Re-read the stored license state into the well, the header and the
    /// sidebar readout, then tell the app layer. Every path that can change
    /// the state — the launch build, the sheet closing, a validator answer —
    /// ends here, so there is one place that decides what the pane shows. A
    /// build with no license server hides the well: it has nothing to verify
    /// and nothing to sell, so it says nothing at all.
    private func refreshLicenseStatus() {
        let serverConfigured = settings.licenseServerURL != nil
        // `serverConfigured` is fixed for the pane's life and this first runs
        // before the first layout, so plain `isHidden` is safe here.
        well?.isHidden = !serverConfigured

        let key = settings.licenseKey ?? ""
        let status = settings.licenseStatus
        if case .active(_, let expiresAt, _) = TrialClock.state(settings: settings) {
            statusLabel.stringValue = "Audiout plays on every speaker until your trial ends on "
                + "\(expiresAt.formatted(.dateTime.day().month(.wide)))."
        } else {
            statusLabel.stringValue = limitedStatusLine()
                ?? Self.licenseStatusLine(keyIsEmpty: key.isEmpty,
                                          status: status,
                                          reason: settings.licenseReason)
        }

        // Only where it can do something: a key is stored, and no verdict has
        // ever come back for it.
        let canRetry = serverConfigured && !key.isEmpty && status == nil
        checkAgainButton.isHidden = !canRetry
        // The wrap-width trap (`SettingsForm.hintLabel`): the label must be
        // told the width it will actually get, or it computes its intrinsic
        // height against a line it never gets to use.
        statusLabel.preferredMaxLayoutWidth =
            Self.wellContentWidth - (canRetry ? Self.trailingButtonWidth : 0)

        // Disclosed exactly when a check-in can actually fire
        // (`LicenseCheckIn.checkInIfNeeded` guards on key + endpoint) — never
        // as a standing claim about a build that never phones home.
        checkInDisclosureHint.isHidden = !(serverConfigured && !key.isEmpty)

        // "Enter license…" before a key of the user's own exists; "Change…"
        // once one is stored (the sheet then prefills it and offers Remove
        // License…).
        let trialActive = trialIsActive
        enterLicenseButton.title = key.isEmpty || trialActive ? "Enter license…" : "Change…"

        // Buying is offered only where it can work (a server and a buy page)
        // and only where it would help (no key, a key the server won’t
        // honour, or a trial that is still running).
        let limited = LicenseGate.limitsToOneSpeaker(settings: settings)
        buyButton.isHidden = !(serverConfigured && settings.buyURL != nil
                               && (limited || settings.licenseUnregistered || trialActive))

        headerCaption?.stringValue = Self.readoutFirstLine(settings: settings)
        headerGlyph?.contentTintColor = readoutGlyphTint
        onReadoutChanged?()
        onLicenseChanged?()
    }

    /// Present the Enter License… sheet (`MixerWindowController
    /// .presentCreateSheet`'s idiom: strong reference always, `presentAsSheet`
    /// only when a visible window can host it — headless tests drive the held
    /// controller's hooks directly).
    @objc private func enterLicenseTapped() {
        presentLicenseSheet(source: "settings")
    }

    /// Open the Enter License… sheet from the Mixer note's "I have a key".
    public func presentLicenseSheetFromNote() {
        presentLicenseSheet(source: "note")
    }

    /// `source` names the door for `license:enter_sheet_opened`.
    private func presentLicenseSheet(source: String) {
        // A second click while one is up would replace the held sheet and
        // orphan the presented one.
        guard licenseSheet == nil else { return }
        Analytics.capture("license:enter_sheet_opened", ["source": source])
        let sheet = LicenseSheetViewController(settings: settings,
                                               transport: licenseTransport)
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

    public override func viewWillAppear() {
        super.viewWillAppear()
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

    @objc private func buyTapped() {
        guard let url = settings.buyURL else { return }
        Analytics.capture("license:buy_link_opened", ["source": "settings"])
        openURL(url)
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

    /// Whether the licence well is on screen (hidden entirely in builds with
    /// no license server).
    public var test_wellIsVisible: Bool {
        _ = view
        return !(well?.isHidden ?? true)
    }

    /// The well's secondary button title — "Enter license…" ↔ "Change…".
    public var test_enterLicenseButtonTitle: String {
        _ = view
        return enterLicenseButton.title
    }

    /// The license status sentence, or `nil` when the well is hidden (a build
    /// with no license server has nothing to verify).
    public var test_licenseStatusText: String? {
        _ = view
        return (well?.isHidden ?? true) ? nil : statusLabel.stringValue
    }

    /// Whether "Buy Audiout" is on screen.
    public var test_buyButtonIsVisible: Bool {
        _ = view
        return !buyButton.isHidden
    }

    /// Whether "Buy Audiout" is the gold call to action.
    public var test_buyButtonIsProminent: Bool {
        _ = view
        return (buyButton as NSButton) is ProminentButton
    }

    /// The header glyph's tint.
    public var test_headerGlyphTint: NSColor {
        _ = view
        return headerGlyph?.contentTintColor ?? .clear
    }

    /// Whether "Check again" is offered beside the status line.
    public var test_checkAgainIsVisible: Bool {
        _ = view
        return !checkAgainButton.isHidden
    }

    /// Invoke "Check again" as a click would.
    public func test_tapCheckAgain() {
        _ = view
        checkAgainTapped()
    }

    /// The check-in disclosure line, or `nil` while it is hidden.
    public var test_checkInDisclosureText: String? {
        _ = view
        return checkInDisclosureHint.isHidden ? nil : checkInDisclosureHint.stringValue
    }
}
