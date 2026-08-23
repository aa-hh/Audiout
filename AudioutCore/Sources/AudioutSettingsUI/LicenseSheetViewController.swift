// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore

/// The "Enter License…" sheet (Settings › General): the ONLY place a key is
/// typed. The pane itself never shows an editable field — the convention every
/// respected optional-license app follows (Sublime's Help › Enter License,
/// Little Snitch's Registration pane, Panic's license window): entry is a
/// deliberate act behind a button, registered state collapses to a sentence.
///
/// Commit is the Register button ONLY. Cancel discards edits — deliberately
/// unlike the old inline field's commit-on-focus-loss, which could silently
/// store half-typed text. The one exception to "Register commits" is that a
/// key is SAVED even when the server can't be reached: the check is soft
/// (`LicenseValidator`), so "couldn't verify" must never read as "not yours" —
/// the sheet closes and the pane's status line owns the retry story.
///
/// Presented from `GeneralSettingsViewController` with the same
/// strong-reference + `presentAsSheet`-only-when-visible idiom as
/// `MixerWindowController.presentCreateSheet` (headless tests hold the
/// controller and drive it via `test_` hooks; `finish` tolerates being
/// unhosted).
@MainActor
public final class LicenseSheetViewController: NSViewController {

    private let settings: AppSettings
    private let transport: LicenseValidator.Transport?
    private let openURL: (URL) -> Void

    private let keyField = NSTextField()
    private let resultLine = SettingsForm.hintLabel()
    private let buyButton = NSButton()
    private let removeButton = NSButton()
    private let cancelButton = NSButton()
    private let registerButton = NSButton()

    /// Fired exactly once, whatever ends the sheet — Register (verified or
    /// key-saved-unverified), Remove, or Cancel — so the pane re-reads
    /// `AppSettings` unconditionally. Cancel writes nothing; the refresh it
    /// triggers is a harmless no-op repaint.
    public var onComplete: (() -> Void)?

    /// Fired on every `AppSettings` write that does NOT end the sheet — the
    /// synchronous key commit inside Register, and a verdict that keeps the
    /// sheet open (revoked/unknown/invalid) — so the pane behind the sheet
    /// stays truthful instead of holding the previous key's line until close.
    public var onStateChange: (() -> Void)?

    /// The fixed content width — a sheet, not a pane, so it does not borrow
    /// `SettingsForm.contentWidth`; wide enough for a full key plus slop.
    private static let sheetContentWidth: CGFloat = 320

    public init(settings: AppSettings,
                transport: LicenseValidator.Transport?,
                openURL: @escaping (URL) -> Void) {
        self.settings = settings
        self.transport = transport
        self.openURL = openURL
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The one wording for each server verdict, shared with the pane's status
    /// line so the two surfaces can never drift apart. Plain words, and never
    /// a claim the app is about to stop working (the check gates nothing).
    static func statusLine(for status: LicenseStatus) -> String {
        switch status {
        case .active: return "Registered. Thank you for supporting Audiout."
        case .revoked: return "This key was refunded or revoked. It no longer gets updates."
        case .unknown: return "This key isn’t recognised. Check it against your receipt."
        case .invalid: return "That doesn’t look like an Audiout key (AUDT-XXXXX-XXXXX-XXXXX-XXXXX)."
        }
    }

    public override func loadView() {
        let heading = SettingsForm.label("Enter your license key")

        // The honest one-liner about what a key actually does in this model —
        // it never unlocks features, and saying so is the pitch.
        let explainer = SettingsForm.hintLabel(
            "Audiout is fully functional without one. A license funds development and unlocks official downloads and updates.")
        explainer.preferredMaxLayoutWidth = Self.sheetContentWidth

        keyField.stringValue = settings.licenseKey ?? ""
        keyField.placeholderString = "AUDT-XXXXX-XXXXX-XXXXX-XXXXX"
        keyField.setAccessibilityLabel("License key")
        keyField.translatesAutoresizingMaskIntoConstraints = false

        resultLine.isHidden = true
        resultLine.preferredMaxLayoutWidth = Self.sheetContentWidth

        buyButton.title = "Buy Audiout…"
        buyButton.bezelStyle = .rounded
        buyButton.controlSize = .small
        buyButton.target = self
        buyButton.action = #selector(buyTapped)
        buyButton.setAccessibilityLabel("Buy an Audiout license")
        buyButton.isHidden = settings.buyURL == nil

        // Only offered when there is something to remove; a fresh sheet
        // opened from "Enter License…" never shows it.
        removeButton.title = "Remove License…"
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        removeButton.setAccessibilityLabel("Remove the stored license key")
        removeButton.isHidden = (settings.licenseKey ?? "").isEmpty

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        registerButton.title = "Register"
        registerButton.bezelStyle = .rounded
        registerButton.keyEquivalent = "\r"
        registerButton.target = self
        registerButton.action = #selector(registerTapped)
        registerButton.setAccessibilityLabel("Register this license key")

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttonRow = NSStackView(views: [buyButton, removeButton, spacer, cancelButton, registerButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [heading, explainer, keyField, resultLine, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: Self.sheetContentWidth),
            keyField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = container
    }

    @objc private func buyTapped() {
        guard let url = settings.buyURL else { return }
        // Leaves the sheet open: the buyer comes back with a key to paste.
        openURL(url)
    }

    @objc private func removeTapped() {
        // The setter clears the stored verdict with the key (`AppSettings
        // .licenseKey`) — one write, both gone.
        settings.licenseKey = nil
        finish()
    }

    @objc private func cancelTapped() {
        finish()   // no writes — edits in the field are discarded
    }

    @objc private func registerTapped() {
        // Trim so a receipt paste with a stray newline validates clean. No
        // other local normalisation: the server canonicalises case/separators
        // and writes its spelling back (`LicenseValidator`).
        let text = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // Emptying the field is not a removal — that is the explicit
            // button above, never an accidental blank commit.
            show(result: "Enter the key from your purchase receipt.")
            return
        }

        // A different key is an unanswered question: the previous key's
        // verdict must not stand in for it while the server is asked.
        if text != settings.licenseKey { settings.licenseStatus = nil }
        settings.licenseKey = text
        onStateChange?()

        keyField.isEnabled = false
        registerButton.isEnabled = false
        show(result: "Checking…")

        let validator = transport.map { LicenseValidator(settings: settings, transport: $0) }
            ?? LicenseValidator(settings: settings)
        validator.validate { [weak self] result in
            guard let self else { return }
            switch result {
            case .verified(.active):
                self.finish()
            case .verified(let status):
                self.keyField.isEnabled = true
                self.registerButton.isEnabled = true
                self.keyField.stringValue = self.settings.licenseKey ?? ""
                self.show(result: Self.statusLine(for: status))
                self.onStateChange?()
            case .unreachable, .noServer, .noKey:
                // The key is SAVED; there is nothing more the user can do in
                // here. The pane's status line owns the "will try again next
                // launch" story.
                self.finish()
            }
        }
    }

    private func show(result: String) {
        resultLine.stringValue = result
        resultLine.isHidden = false
    }

    /// Dismiss (when actually hosted — headless tests never present) and tell
    /// the pane once.
    private func finish() {
        if presentingViewController != nil { dismiss(nil) }
        onComplete?()
        onComplete = nil
    }

    // MARK: Test-support hooks

    /// Replace the field's text, as typing would.
    public func test_setKeyText(_ text: String) {
        _ = view
        keyField.stringValue = text
    }

    /// Invoke Register as a click would.
    public func test_tapRegister() {
        _ = view
        registerTapped()
    }

    /// Invoke Cancel as a click would.
    public func test_tapCancel() {
        _ = view
        cancelTapped()
    }

    /// Invoke Remove License… as a click would.
    public func test_tapRemove() {
        _ = view
        removeTapped()
    }

    /// The inline result line's text, or `nil` while it is hidden.
    public var test_resultText: String? {
        _ = view
        return resultLine.isHidden ? nil : resultLine.stringValue
    }

    /// Whether Remove License… is offered (only when a key was stored).
    public var test_removeIsVisible: Bool {
        _ = view
        return !removeButton.isHidden
    }
}
