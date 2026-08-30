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
    private let keyField = NSTextField()
    private let gutterLine = NSTextField(wrappingLabelWithString: "")
    private var registerButton: ProminentButton!
    private var resendButton: ProminentButton!
    private let lostKeyButton = NSButton()
    private let buyButton = NSButton()
    private let quitButton = NSButton()
    private var didPass = false

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
    /// without touching the user's real pasteboard.
    public var pasteboardString: () -> String? = { NSPasteboard.general.string(forType: .string) }

    /// The window's fixed content size. Wide enough for the emitters to sit
    /// out near the edges the way the site composes them; the calm-zone masks
    /// in the field keep the middle quiet for the type.
    static let contentSize = NSSize(width: 560, height: 440)

    /// The key column's width — the Settings sheet's 320, the one width a full
    /// key plus slop is known to fit.
    private static let columnWidth: CGFloat = 320

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
        field.translatesAutoresizingMaskIntoConstraints = false

        let mark = NSImageView()
        mark.image = BrandMark.image
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.setAccessibilityElement(false)

        let headline = NSTextField(labelWithString: "Welcome to Audiout")
        headline.font = Tokens.Font.displayLarge
        headline.textColor = Tokens.Color.label
        headline.alignment = .center
        headline.setAccessibilityRole(.staticText)
        headline.setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXHeading"))

        let why = NSTextField(wrappingLabelWithString:
            "It takes one key to open — yours is in your receipt email, starting with AUDT.")
        why.font = Tokens.Font.titleLarge
        why.textColor = Tokens.Color.secondaryLabel
        why.alignment = .center
        why.preferredMaxLayoutWidth = Self.columnWidth

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
        gutterLine.textColor = Tokens.Color.secondaryLabel
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

        lostKeyButton.isBordered = false
        lostKeyButton.controlSize = .regular
        lostKeyButton.target = self
        lostKeyButton.action = #selector(lostKeyTapped)
        setLostKeyTitle("I lost my key")

        buyButton.title = "Don’t have a key? Buy Audiout — €30"
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

        let column = NSStackView(views: [mark, headline, why, keyField, buttonSlot,
                                         gutter, lostKeyButton])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 10
        column.setCustomSpacing(14, after: mark)
        column.setCustomSpacing(6, after: headline)
        column.setCustomSpacing(22, after: why)
        column.setCustomSpacing(12, after: keyField)
        column.setCustomSpacing(14, after: buttonSlot)
        column.setCustomSpacing(6, after: gutter)
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
                                     fill: Tokens.Color.goldCTA,
                                     picksInkFromFill: true,
                                     titleFont: Tokens.Font.heading)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// The quiet tier's one link. `ProminentButton` stamps its own title, so
    /// this one carries its ink itself.
    private func setLostKeyTitle(_ title: String) {
        lostKeyButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: Tokens.Color.secondaryLabel,
                         .font: Tokens.Font.body])
    }

    /// Authored rather than inferred from frames: field, the commit button,
    /// the link, then the two bottom-edge buttons, and back.
    private func applyTabOrder() {
        let commit: NSButton = mode == .resend ? resendButton : registerButton
        keyField.nextKeyView = commit
        commit.nextKeyView = lostKeyButton
        lostKeyButton.nextKeyView = buyButton
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
        offerClipboardKey()
        armQuietLift()
    }

    /// A key sitting on the clipboard is almost always the one from the
    /// receipt the user just opened — so it is OFFERED, filled in and named,
    /// never submitted: the buyer presses Register, this window doesn't.
    private func offerClipboardKey() {
        guard mode == .key, keyField.stringValue.isEmpty else { return }
        let pasted = (pasteboardString() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard pasted.hasPrefix("AUDT-") else { return }
        keyField.stringValue = pasted
        show("From your clipboard")
        updateSceneForText()
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
        show("The checkout is in your browser. Come back with the key — it lands right here.")
    }

    @objc private func quitTapped() {
        NSApp?.terminate(nil)
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
        setLostKeyTitle("Back to your key")
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
        setLostKeyTitle("I lost my key")
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

    /// Invoke the Buy link as a click would.
    public func test_tapBuy() {
        _ = view
        buyTapped()
    }

    /// Arrival, without the on-screen half of `viewDidAppear`.
    public func test_arrive() {
        _ = view
        offerClipboardKey()
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
