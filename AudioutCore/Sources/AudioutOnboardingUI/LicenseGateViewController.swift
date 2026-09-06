// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The first-open licence gate's content: the emitter field (the marketing
/// site's hero, remapped to gold) filling the window, with the welcome, the
/// key field and the gold Register floating in its calm centre.
///
/// **One surface, and nothing on it ever moves.** Every state — a clipboard
/// offer, a verdict, the checkout wait, the lost-key detour — lands as words in
/// ONE reserved gutter (two lines' height, always there, empty at rest) and as
/// a scene on the field behind it. There is no sheet, no second window and no
/// row that appears and pushes the rest down: the window the buyer types into
/// is the same shape from launch to pass. Any constraint added here must keep
/// that true.
///
/// Register mirrors `LicenseSheetViewController`'s contract exactly — trim, a
/// changed key clears the stored verdict, the key is SAVED even when the
/// server can't be reached — because "couldn't verify" must never read as "not
/// yours", least of all on a window the user cannot get past. The wording for
/// every verdict is `LicenseCopy` (Core), shared with the Settings sheet.
///
/// An `active` verdict is the one authored motion moment: the field surges
/// once, the line thanks the buyer, and the gate hands off. An unreachable
/// server passes the gate too (key saved, verified on a later launch) — a hard
/// gate that bricked an offline Mac would punish exactly the buyer it exists
/// to thank.
@MainActor
public final class LicenseGateViewController: NSViewController, NSTextFieldDelegate {

    private let settings: AppSettings
    private let transport: LicenseValidator.Transport?
    private let openURL: (URL) -> Void
    private let onPassed: () -> Void

    private let field = EmitterFieldView()
    private let headlineLabel = NSTextField(labelWithString: "")
    private let whyLabel = NSTextField(wrappingLabelWithString: "")
    private let keyField = NSTextField()
    private let gutterLine = NSTextField(wrappingLabelWithString: "")
    private var registerButton: ProminentButton!
    private var resendButton: ProminentButton!
    private let pasteKeyButton = NSButton()
    private let lostKeyButton = NSButton()
    private let buyButton = NSButton()
    private let quitButton = NSButton()
    private let trialButton = NSButton()
    private var didPass = false

    /// Where this Mac's trial stood when the gate was built. Read ONCE, in
    /// `loadView`: it decides the headline, the body line and whether the trial
    /// offer exists at all, and none of those may change while the window is
    /// up — the surface's whole contract is that nothing on it moves.
    private var trialState: TrialState = .none

    /// What the shared controls currently mean. The lost-key path MORPHS this
    /// one field and one button rather than opening anything: same geometry,
    /// different question.
    private enum Mode { case key, resend }
    private var mode: Mode = .key
    /// The half-typed key set aside while the resend question borrows the
    /// field, restored verbatim on the way back.
    private var stashedKey = ""

    private var liftTimer: Timer?
    private var didLiftQuietRow = false

    /// Where a pre-filled key may come from, injectable so tests can offer one
    /// without touching the user's real pasteboard. Read when the user clicks
    /// "Paste key", or on arrival only when `pasteboardAccessIsAlwaysAllowed`
    /// says this app may already read the pasteboard without being asked.
    public var pasteboardString: () -> String? = { NSPasteboard.general.string(forType: .string) }

    /// Whether macOS is already set to let this app read the pasteboard
    /// silently. Injectable beside the string seam so a test can pick either
    /// arrival path.
    public var pasteboardAccessIsAlwaysAllowed: () -> Bool = {
        if #available(macOS 15.4, *) {
            return NSPasteboard.general.accessBehavior == .alwaysAllow
        }
        return false
    }

    /// The window's fixed content size. Wide enough for the emitters to sit
    /// out near the edges the way the site composes them; the calm-zone masks
    /// in the field keep the middle quiet for the type.
    static let contentSize = NSSize(width: 560, height: 440)

    /// The key column's width — the Settings sheet's 320, the one width a full
    /// key plus slop is known to fit.
    private static let columnWidth: CGFloat = 320

    /// The gate's trial copy, owner-verbatim from
    /// `dev/notes/trial-spec-2026-09-05.md` § Copy. The expired pair replaces
    /// the welcome; the offer is only ever shown to a Mac that has never
    /// started a trial.
    ///
    /// The spec's caption under the offer — "No card, no email. Every feature.
    /// Buy any time." — is NOT here: at 560 x 440 the column has room for the
    /// button or the caption, not both (`LicenseGateTests`'
    /// `theContentColumnClearsTheBottomButtonRow` measures it). Either the
    /// window grows or the caption borrows the gutter, and both are the
    /// owner's call, not this ticket's.
    private static let expiredHeadline = "Your 14-day trial has ended."
    private static let expiredBody =
        "Buy Audiout for €30, once, and keep everything you set up. "
        + "Your scenes and speaker settings are still here."
    private static let trialTitle = "Try Audiout free for 14 days"

    /// Rest and lifted opacity for the bottom-edge pair. They sit under the
    /// hero's attention and rise ONCE for a user who has sat there without
    /// typing — an offer, not a nag, so it never animates twice.
    ///
    /// Rest was 0.45, which was too quiet to survive contact with a real
    /// screen: "Buy Audiout" is a bordered button, not a filled one, and at
    /// 0.45 over the field it was unreadable — and that is the ONLY route
    /// for someone who arrives without a key. Quiet has to mean subordinate
    /// to the gold Register button, not invisible.
    private static let quietRestAlpha: CGFloat = 0.75
    private static let quietLiftedAlpha: CGFloat = 1.0
    private static let quietLiftDelay: TimeInterval = 20
    private static let quietLiftDuration: TimeInterval = 0.8

    public init(settings: AppSettings,
                transport: LicenseValidator.Transport? = nil,
                openURL: @escaping (URL) -> Void,
                onPassed: @escaping () -> Void) {
        self.settings = settings
        self.transport = transport
        self.openURL = openURL
        self.onPassed = onPassed
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        trialState = TrialClock.state(settings: settings)
        if case .expired = trialState {
            // The gate is only ever built in order to be shown, so building it
            // IS the impression — and it is the one moment a test can reach,
            // since nothing here may put a window on screen.
            Analytics.capture("license:expired_gate_shown")
        }
        field.translatesAutoresizingMaskIntoConstraints = false

        let mark = NSImageView()
        mark.image = BrandMark.image
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.setAccessibilityElement(false)

        // ONLY the product name is set in the wordmark face; the words around
        // it stay system bold. The wordmark run is 25 pt against the line's
        // 24 pt so the two runs share a cap height: measured cap-height ratios
        // are 0.70459 for system bold and 0.670 for ClashDisplay-Semibold, and
        // 24 × 0.70459 / 0.670 = 25.24 pt.
        //
        // Two RUNS of one attributed string rather than two labels: the line is
        // centred, and one string on one baseline is what a centred paragraph
        // style gives for free.
        //
        // Outside an assembled `.app` there is no `.otf` to register, so
        // `Tokens.Font.wordmark(size:)` returns system bold at 25 and the name
        // renders 1 pt taller than the rest of the line. That is the normal
        // path under `swift run`, `swift test` and the snapshot tools.
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let line: NSMutableAttributedString
        if case .expired = trialState {
            // The expired headline names no product, so it has no wordmark run
            // and stays one plain run at the same size.
            line = NSMutableAttributedString(
                string: Self.expiredHeadline,
                attributes: [.font: Tokens.Font.displayLarge,
                             .foregroundColor: Tokens.Color.label])
        } else {
            line = NSMutableAttributedString(
                string: "Welcome to ",
                attributes: [.font: Tokens.Font.displayLarge,
                             .foregroundColor: Tokens.Color.label])
            line.append(NSAttributedString(
                string: "Audiout",
                attributes: [.font: Tokens.Font.wordmark(size: 25),
                             .foregroundColor: Tokens.Color.label]))
        }
        line.addAttribute(.paragraphStyle, value: centred,
                          range: NSRange(location: 0, length: line.length))
        headlineLabel.attributedStringValue = line
        headlineLabel.alignment = .center
        headlineLabel.setAccessibilityRole(.staticText)
        headlineLabel.setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXHeading"))

        if case .expired = trialState {
            whyLabel.stringValue = Self.expiredBody
        } else {
            whyLabel.stringValue =
                "It takes one key to open. Yours is in your receipt email, starting with AUDT."
        }
        whyLabel.font = Tokens.Font.titleLarge
        whyLabel.textColor = Tokens.Color.label2
        whyLabel.alignment = .center
        whyLabel.preferredMaxLayoutWidth = Self.columnWidth

        keyField.stringValue = settings.licenseKey ?? ""
        keyField.placeholderString = LicenseCopy.keyFormatHint
        keyField.setAccessibilityLabel("License key")
        keyField.alignment = .center
        keyField.controlSize = .large
        keyField.font = Tokens.Font.titleLarge
        keyField.delegate = self
        // A key is one line; a pasted receipt fragment with a newline must not
        // wrap the field open (same reasoning as the Settings sheet).
        keyField.usesSingleLineMode = true
        keyField.cell?.isScrollable = true
        keyField.translatesAutoresizingMaskIntoConstraints = false

        registerButton = goldButton(title: "Register", action: #selector(registerTapped))
        resendButton = goldButton(title: "Email my key", action: #selector(resendTapped))
        resendButton.isHidden = true
        registerButton.keyEquivalent = "\r"

        // Both live in one slot so swapping them cannot move anything: the slot
        // keeps the column's width and the button's height whichever is up.
        let buttonSlot = NSView()
        buttonSlot.translatesAutoresizingMaskIntoConstraints = false
        buttonSlot.addSubview(registerButton)
        buttonSlot.addSubview(resendButton)

        gutterLine.font = Tokens.Font.titleLarge
        gutterLine.textColor = Tokens.Color.label2
        gutterLine.alignment = .center
        gutterLine.maximumNumberOfLines = 2
        gutterLine.preferredMaxLayoutWidth = Self.columnWidth
        gutterLine.translatesAutoresizingMaskIntoConstraints = false
        gutterLine.setAccessibilityLabel("Status")

        // The gutter is RESERVED, never conditional: a line appearing must not
        // push the link, the field or the mark by a pixel.
        let gutter = NSView()
        gutter.translatesAutoresizingMaskIntoConstraints = false
        gutter.addSubview(gutterLine)

        pasteKeyButton.isBordered = false
        pasteKeyButton.controlSize = .regular
        pasteKeyButton.target = self
        pasteKeyButton.action = #selector(pasteKeyTapped)
        setPasteKeyEnabled(true)

        lostKeyButton.isBordered = false
        lostKeyButton.controlSize = .regular
        lostKeyButton.target = self
        lostKeyButton.action = #selector(lostKeyTapped)
        setQuietLinkTitle("I lost my key", on: lostKeyButton)

        buyButton.title = "Buy Audiout"
        buyButton.bezelStyle = .rounded
        buyButton.controlSize = .regular
        buyButton.target = self
        buyButton.action = #selector(buyTapped)
        buyButton.isHidden = settings.buyURL == nil
        buyButton.alphaValue = Self.quietRestAlpha
        buyButton.translatesAutoresizingMaskIntoConstraints = false

        quitButton.title = "Quit"
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .regular
        quitButton.target = self
        quitButton.action = #selector(quitTapped)
        // No main menu exists yet at the gate, so ⌘Q needs an explicit home.
        quitButton.keyEquivalent = "q"
        quitButton.keyEquivalentModifierMask = [.command]
        quitButton.alphaValue = Self.quietRestAlpha
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        // The offer for someone who has no key and never had one. Shown ONLY
        // from `.none`: a trial already running, or already spent, has nothing
        // left to offer, and a second one is not a thing this app has. Bordered
        // rather than gold so it reads as the other road out of this window
        // without competing with Register for the eye.
        trialButton.title = Self.trialTitle
        trialButton.bezelStyle = .rounded
        trialButton.controlSize = .large
        trialButton.target = self
        trialButton.action = #selector(trialTapped)
        trialButton.isHidden = trialState != .none
        trialButton.translatesAutoresizingMaskIntoConstraints = false

        let quietLinks = NSStackView(views: [pasteKeyButton, lostKeyButton])
        quietLinks.orientation = .horizontal
        quietLinks.alignment = .centerY
        quietLinks.spacing = 16
        quietLinks.translatesAutoresizingMaskIntoConstraints = false

        // The trial offer is last and DETACHES when hidden (the stack view's
        // default), so a Mac with a trial behind it gets the same column, to
        // the pixel, as one with no trial offer at all.
        let column = NSStackView(views: [mark, headlineLabel, whyLabel, keyField, buttonSlot,
                                         gutter, quietLinks, trialButton])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 10
        column.setCustomSpacing(14, after: mark)
        column.setCustomSpacing(6, after: headlineLabel)
        column.setCustomSpacing(22, after: whyLabel)
        column.setCustomSpacing(12, after: keyField)
        column.setCustomSpacing(14, after: buttonSlot)
        column.setCustomSpacing(6, after: gutter)
        column.setCustomSpacing(14, after: quietLinks)
        column.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(field)
        root.addSubview(column)
        root.addSubview(quitButton)
        root.addSubview(buyButton)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.contentSize.width),
            root.heightAnchor.constraint(equalToConstant: Self.contentSize.height),
            field.topAnchor.constraint(equalTo: root.topAnchor),
            field.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            quitButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            quitButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            buyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            mark.widthAnchor.constraint(equalToConstant: 64),
            mark.heightAnchor.constraint(equalToConstant: 64),
            keyField.widthAnchor.constraint(equalToConstant: Self.columnWidth),
            buttonSlot.widthAnchor.constraint(equalToConstant: Self.columnWidth),
            buttonSlot.heightAnchor.constraint(equalTo: registerButton.heightAnchor),
            registerButton.centerXAnchor.constraint(equalTo: buttonSlot.centerXAnchor),
            registerButton.centerYAnchor.constraint(equalTo: buttonSlot.centerYAnchor),
            resendButton.centerXAnchor.constraint(equalTo: buttonSlot.centerXAnchor),
            resendButton.centerYAnchor.constraint(equalTo: buttonSlot.centerYAnchor),
            gutter.widthAnchor.constraint(equalToConstant: Self.columnWidth),
            gutter.heightAnchor.constraint(equalToConstant: Self.gutterHeight),
            gutterLine.topAnchor.constraint(equalTo: gutter.topAnchor),
            gutterLine.leadingAnchor.constraint(equalTo: gutter.leadingAnchor),
            gutterLine.trailingAnchor.constraint(equalTo: gutter.trailingAnchor),
        ])
        view = root

        applyTabOrder()
        field.setScene(.idle)
    }

    /// Two lines of body text, measured rather than guessed — the gutter's
    /// whole job is to be exactly this tall whatever it holds.
    private static var gutterHeight: CGFloat {
        let font = Tokens.Font.titleLarge
        return ceil((font.ascender - font.descender + font.leading) * 2)
    }

    private func goldButton(title: String, action: Selector) -> ProminentButton {
        let button = ProminentButton(title: title, target: self, action: action,
                                     titleFont: Tokens.Font.heading)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// The quiet tier's two links. `ProminentButton` stamps its own title, so
    /// these carry their ink themselves.
    private func setQuietLinkTitle(_ title: String, on button: NSButton,
                                   ink: NSColor = Tokens.Color.label2) {
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: ink,
                         .font: Tokens.Font.body])
    }

    /// The ink IS the disabled look: an attributed title carries its own
    /// colour, so `isEnabled` alone leaves the link at full strength.
    private func setPasteKeyEnabled(_ enabled: Bool) {
        pasteKeyButton.isEnabled = enabled
        setQuietLinkTitle("Paste key", on: pasteKeyButton,
                          ink: enabled ? Tokens.Color.label2
                                       : Tokens.Color.label3)
    }

    /// Authored rather than inferred from frames: field, the commit button,
    /// the two links, the trial offer where there is one, then the two
    /// bottom-edge buttons, and back.
    private func applyTabOrder() {
        let commit: NSButton = mode == .resend ? resendButton : registerButton
        keyField.nextKeyView = commit
        commit.nextKeyView = pasteKeyButton
        pasteKeyButton.nextKeyView = lostKeyButton
        lostKeyButton.nextKeyView = trialButton.isHidden ? buyButton : trialButton
        trialButton.nextKeyView = buyButton
        buyButton.nextKeyView = quitButton
        quitButton.nextKeyView = keyField
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        field.start()
        arrive()
        // The field is why the window exists — typing starts without a click.
        view.window?.makeFirstResponder(keyField)
    }

    /// Arrival: offer whatever key is already on the clipboard, and start the
    /// clock on the bottom row's one lift.
    private func arrive() {
        offerClipboardKeyOnArrival()
        armQuietLift()
    }

    /// A key sitting on the clipboard is almost always the one from the
    /// receipt the user just opened — so it is OFFERED, filled in and named,
    /// never submitted: the buyer presses Register, this window doesn't.
    ///
    /// Arrival reads the clipboard ONLY where the app is already set to always
    /// allow pasteboard access. On macOS 15.4 and later a read nobody asked
    /// for raises the system paste alert, so reading here unconditionally
    /// would open every launch of the paid build with a permission dialog.
    /// Everywhere else the key arrives through "Paste key" instead.
    private func offerClipboardKeyOnArrival() {
        guard mode == .key, keyField.stringValue.isEmpty,
              pasteboardAccessIsAlwaysAllowed() else { return }
        let pasted = (pasteboardString() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard pasted.hasPrefix("AUDT-") else { return }
        keyField.stringValue = pasted
        show("From your clipboard")
        updateSceneForText()
    }

    /// The clicked read: the click is the gesture macOS wants before an app
    /// reads the clipboard. A paste REPLACES what is in the field, and still
    /// never submits. Nothing happens while the field is locked: a check or a
    /// resend is in flight, and a paste is an edit typing could not make
    /// either.
    @objc private func pasteKeyTapped() {
        guard mode == .key, keyField.isEnabled else { return }
        let pasted = (pasteboardString() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard pasted.hasPrefix("AUDT-") else {
            show("No key on the clipboard. It starts with AUDT-.")
            Analytics.capture("license:key_pasted", ["outcome": "no_key"])
            return
        }
        cancelQuietLift()
        keyField.stringValue = pasted
        show("From your clipboard")
        updateSceneForText()
        view.window?.makeFirstResponder(keyField)
        Analytics.capture("license:key_pasted", ["outcome": "filled"])
    }

    // MARK: The bottom row's one lift

    private func armQuietLift() {
        guard !didLiftQuietRow, keyField.stringValue.isEmpty else { return }
        liftTimer?.invalidate()
        liftTimer = Timer.scheduledTimer(withTimeInterval: Self.quietLiftDelay,
                                         repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.liftQuietRow() }
        }
    }

    private func cancelQuietLift() {
        liftTimer?.invalidate()
        liftTimer = nil
    }

    private func liftQuietRow() {
        cancelQuietLift()
        guard !didLiftQuietRow else { return }
        didLiftQuietRow = true
        let targets = [quitButton, buyButton]
        guard !HeadlessRuntime.isActive,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            targets.forEach { $0.alphaValue = Self.quietLiftedAlpha }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.quietLiftDuration
            targets.forEach { $0.animator().alphaValue = Self.quietLiftedAlpha }
        }
    }

    // MARK: Actions

    @objc private func buyTapped() {
        guard let url = settings.buyURL else { return }
        Analytics.capture("license:buy_link_opened", ["source": "gate"])
        // Leaves the gate open: the buyer comes back with a key to paste, and
        // the window says so rather than sitting blank while they shop.
        openURL(url)
        field.setScene(.waiting)
        show("The checkout is in your browser. Come back with the key, and it lands right here.")
    }

    @objc private func quitTapped() {
        NSApp?.terminate(nil)
    }

    /// Start the trial and get out of the way in the same breath.
    ///
    /// Nothing here waits on the network: the trial's dates are written
    /// locally, and telling the licence server about them is a later, silent
    /// job (`TrialRegistrar`) that runs with the app already open. A start that
    /// blocked on a server would put the one wall this window exists to remove
    /// back in front of a user who has not even seen the app yet.
    @objc private func trialTapped() {
        guard trialState == .none else { return }
        TrialClock.start(settings: settings)
        Analytics.capture("license:trial_started")
        pass(afterBeat: false)
    }

    /// The lost-key detour, both ways: the SAME field and the SAME button ask
    /// the other question, so nothing opens and nothing moves.
    @objc private func lostKeyTapped() {
        mode == .key ? enterResendMode() : restoreKeyMode(keepingLine: false)
    }

    private func enterResendMode() {
        mode = .resend
        stashedKey = keyField.stringValue
        keyField.stringValue = ""
        keyField.placeholderString = "you@example.com"
        keyField.alignment = .natural
        keyField.setAccessibilityLabel("Purchase email address")
        registerButton.isHidden = true
        registerButton.keyEquivalent = ""
        resendButton.isHidden = false
        resendButton.keyEquivalent = "\r"
        setQuietLinkTitle("Back to your key", on: lostKeyButton)
        setPasteKeyEnabled(false)
        show("Enter the email you bought with.")
        applyTabOrder()
        view.window?.makeFirstResponder(keyField)
    }

    /// `keepingLine` is the difference between Back (which clears the gutter)
    /// and a finished resend (whose one neutral line is the whole point).
    private func restoreKeyMode(keepingLine: Bool) {
        mode = .key
        keyField.stringValue = stashedKey
        keyField.placeholderString = LicenseCopy.keyFormatHint
        keyField.alignment = .center
        keyField.setAccessibilityLabel("License key")
        resendButton.isHidden = true
        resendButton.keyEquivalent = ""
        registerButton.isHidden = false
        registerButton.keyEquivalent = "\r"
        setQuietLinkTitle("I lost my key", on: lostKeyButton)
        setPasteKeyEnabled(true)
        if !keepingLine { show("") }
        applyTabOrder()
        updateSceneForText()
    }

    /// Ask the server to email the key again. The answer is deliberately the
    /// same sentence every time — hit, miss, throttled or offline — because a
    /// different one would tell a stranger whether an address bought Audiout.
    @objc private func resendTapped() {
        let email = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, email.contains("@") else {
            show("Enter the email address you bought with.")
            return
        }
        // Never a property: the address is exactly the free text the privacy
        // fence forbids sending (PRODUCT.md "Data Collection").
        Analytics.capture("license:resend_requested")

        keyField.isEnabled = false
        resendButton.isEnabled = false
        let resend = transport.map { LicenseResend(settings: settings, transport: $0) }
            ?? LicenseResend(settings: settings)
        resend.request(email: email) { [weak self] in
            guard let self else { return }
            self.keyField.isEnabled = true
            self.resendButton.isEnabled = true
            self.show("If that address bought Audiout, the key is on its way.")
            self.restoreKeyMode(keepingLine: true)
        }
    }

    @objc private func registerTapped() {
        let text = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            show("Enter the key from your purchase receipt.")
            return
        }

        // A different key is an unanswered question: the previous key's
        // verdict must not stand in for it while the server is asked.
        if text != settings.licenseKey { settings.licenseStatus = nil }
        settings.licenseKey = text

        keyField.isEnabled = false
        registerButton.isEnabled = false
        show("Checking…")
        field.setScene(.checking)

        let validator = transport.map { LicenseValidator(settings: settings, transport: $0) }
            ?? LicenseValidator(settings: settings)
        validator.validate { [weak self] result in
            guard let self else { return }
            let outcome: String
            switch result {
            case .verified(.active): outcome = "active"
            case .verified(let status): outcome = status.rawValue
            case .unreachable: outcome = "unreachable"
            case .noServer: outcome = "no_server"
            case .noKey: outcome = "no_key"
            }
            Analytics.capture("license:key_submitted", ["outcome": outcome, "source": "gate"])
            switch result {
            case .verified(.active):
                self.show(LicenseCopy.statusLine(for: .active))
                self.field.surge(intensity: 1.0)
                self.field.setScene(.farewell)
                self.pass(afterBeat: true)
            case .verified(let status):
                self.keyField.isEnabled = true
                self.registerButton.isEnabled = true
                self.keyField.stringValue = self.settings.licenseKey ?? ""
                self.show(LicenseCopy.statusLine(for: status))
                self.field.setScene(.quiet)
                // A refunded key has one useful answer left, so the offer
                // stops being quiet.
                if status == .revoked { self.promoteBuy() }
                self.view.window?.makeFirstResponder(self.keyField)
                // Reselected, so the retype the user is about to do overwrites
                // rather than appends to a key they already know is wrong.
                self.keyField.currentEditor()?.selectAll(nil)
            case .unreachable, .noServer, .noKey:
                // The key is SAVED and the gate opens: an unreachable server
                // must never lock a buyer out of the thing they paid for. The
                // normal launch validation settles the verdict later.
                self.show("Your key is saved. We'll check it next time you're online.")
                self.field.surge(intensity: 0.5)
                self.pass(afterBeat: true)
            }
        }
    }

    /// The revoked verdict's one promotion: Buy comes up to full strength and
    /// the timed lift is spent, so nothing later dims it back down.
    private func promoteBuy() {
        cancelQuietLift()
        didLiftQuietRow = true
        buyButton.alphaValue = 1
    }

    /// Open the gate exactly once. `afterBeat` holds the window just long
    /// enough for the result line and the field's surge to land — skipped
    /// under Reduce Motion and headless, where there is nothing to watch.
    private func pass(afterBeat: Bool) {
        guard !didPass else { return }
        didPass = true
        cancelQuietLift()
        let animated = afterBeat && !HeadlessRuntime.isActive
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated else { return onPassed() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.onPassed()
        }
    }

    /// Every state's words land here — one label, so VoiceOver has one place
    /// to listen and the layout has one thing to reserve room for.
    private func show(_ line: String) {
        gutterLine.stringValue = line
        guard !line.isEmpty, let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested,
                             userInfo: [.announcement: line,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Editing

    public func controlTextDidChange(_ obj: Notification) {
        // Typing is the answer to every offer on screen: the clipboard
        // caption, a verdict, the checkout wait.
        cancelQuietLift()
        show("")
        updateSceneForText()
    }

    private func updateSceneForText() {
        let text = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            field.setScene(.idle)
        } else if mode == .key, text.count >= LicenseCopy.keyFormatHint.count {
            field.setScene(.armed)
        } else {
            field.setScene(.typing)
        }
    }

    /// Fill the field with `key` and submit it, exactly as a paste followed by
    /// Register would — the landing point for `audiout://register?key=…` while
    /// the gate is up. A submission already in flight drops the link the same
    /// way a second click is dropped.
    public func submit(key: String) {
        _ = view
        // A link arriving mid-detour answers the question the detour was for,
        // so the controls come back to the key first.
        if mode == .resend { restoreKeyMode(keepingLine: false) }
        guard registerButton.isEnabled else { return }
        keyField.stringValue = key
        registerTapped()
    }

    // MARK: Test-support hooks

    /// Replace the field's text, as typing would.
    public func test_setKeyText(_ text: String) {
        _ = view
        keyField.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    /// Invoke the gold button as a click would — whichever question it is
    /// currently asking.
    public func test_tapRegister() {
        _ = view
        mode == .resend ? resendTapped() : registerTapped()
    }

    /// Invoke "I lost my key" / "Back to your key" as a click would.
    public func test_tapLostKey() {
        _ = view
        lostKeyTapped()
    }

    /// Invoke "Paste key" as a click would.
    public func test_tapPasteKey() {
        _ = view
        pasteKeyTapped()
    }

    /// Invoke the Buy link as a click would.
    public func test_tapBuy() {
        _ = view
        buyTapped()
    }

    /// Invoke the trial offer as a click would.
    public func test_tapTrial() {
        _ = view
        trialTapped()
    }

    /// Whether the trial offer is on screen at all.
    public var test_trialIsVisible: Bool {
        _ = view
        return !trialButton.isHidden
    }

    /// The trial button's title, as drawn.
    public var test_trialTitle: String {
        _ = view
        return trialButton.title
    }

    /// The headline, flattened out of its two type runs.
    public var test_headlineText: String {
        _ = view
        return headlineLabel.attributedStringValue.string
    }

    /// The line under the headline.
    public var test_bodyText: String {
        _ = view
        return whyLabel.stringValue
    }

    /// Arrival, without the on-screen half of `viewDidAppear`.
    public func test_arrive() {
        _ = view
        offerClipboardKeyOnArrival()
    }

    /// The gutter's text, or `nil` while it is empty.
    public var test_resultText: String? {
        _ = view
        return gutterLine.stringValue.isEmpty ? nil : gutterLine.stringValue
    }

    /// The gold button's current title — "Register" or "Email my key".
    public var test_commitTitle: String {
        _ = view
        // `ProminentButton` renders through `attributedTitle` (it measures its
        // own ink), so that is where its title actually lives.
        return (mode == .resend ? resendButton : registerButton).attributedTitle.string
    }

    /// The quiet link's current title.
    public var test_lostKeyTitle: String {
        _ = view
        return lostKeyButton.attributedTitle.string
    }

    /// Whether "Paste key" is live. The lost-key detour rests it.
    public var test_pasteKeyIsEnabled: Bool {
        _ = view
        return pasteKeyButton.isEnabled
    }

    /// The key field's placeholder — the other half of the lost-key morph.
    public var test_placeholder: String {
        _ = view
        return keyField.placeholderString ?? ""
    }

    /// The key field's current text (the morph stashes and restores it).
    public var test_keyText: String {
        _ = view
        return keyField.stringValue
    }

    /// Whether "Buy Audiout" is offered (needs a buy URL to point at).
    public var test_buyIsVisible: Bool {
        _ = view
        return !buyButton.isHidden
    }

    /// The Buy link's opacity — quiet at rest, full after a revoked verdict.
    public var test_buyAlpha: CGFloat {
        _ = view
        return buyButton.alphaValue
    }

    /// What the field behind the type is currently doing. Internal on purpose:
    /// `Scene` is module-internal and the tests import `@testable`.
    var test_fieldScene: EmitterFieldView.Scene {
        _ = view
        return field.test_scene
    }

    /// Whether the gate has fired `onPassed` (or is in the beat before it).
    public var test_didPass: Bool { didPass }
}
