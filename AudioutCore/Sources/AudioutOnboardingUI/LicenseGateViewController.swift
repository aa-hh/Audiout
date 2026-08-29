// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The first-open licence gate's content: the emitter field (the marketing
/// site's hero, remapped to gold) filling the window, with the welcome, the
/// key field and the gold Register floating in its calm centre.
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
public final class LicenseGateViewController: NSViewController {

    private let settings: AppSettings
    private let transport: LicenseValidator.Transport?
    private let openURL: (URL) -> Void
    private let onPassed: () -> Void

    private let field = EmitterFieldView()
    private let keyField = NSTextField()
    private let resultLine = NSTextField(wrappingLabelWithString: "")
    private var registerButton: ProminentButton!
    private let buyButton = NSButton()
    private let quitButton = NSButton()
    private var didPass = false

    /// The window's fixed content size. Wide enough for the emitters to sit
    /// out near the edges the way the site composes them; the calm-zone masks
    /// in the field keep the middle quiet for the type.
    static let contentSize = NSSize(width: 560, height: 440)

    /// The key column's width — the Settings sheet's 320, the one width a full
    /// key plus slop is known to fit.
    private static let columnWidth: CGFloat = 320

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
        headline.font = Tokens.Font.display
        headline.textColor = Tokens.Color.label
        headline.alignment = .center
        headline.setAccessibilityRole(.staticText)
        headline.setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXHeading"))

        let why = NSTextField(wrappingLabelWithString:
            "This build is the paid one. Enter the license key from your receipt and everything else is yours.")
        why.font = Tokens.Font.body
        why.textColor = Tokens.Color.secondaryLabel
        why.alignment = .center
        why.preferredMaxLayoutWidth = Self.columnWidth

        keyField.stringValue = settings.licenseKey ?? ""
        keyField.placeholderString = LicenseCopy.keyFormatHint
        keyField.setAccessibilityLabel("License key")
        keyField.alignment = .center
        keyField.controlSize = .large
        // A key is one line; a pasted receipt fragment with a newline must not
        // wrap the field open (same reasoning as the Settings sheet).
        keyField.usesSingleLineMode = true
        keyField.cell?.isScrollable = true
        keyField.translatesAutoresizingMaskIntoConstraints = false

        resultLine.font = Tokens.Font.body
        resultLine.textColor = Tokens.Color.secondaryLabel
        resultLine.alignment = .center
        resultLine.preferredMaxLayoutWidth = Self.columnWidth
        resultLine.isHidden = true

        registerButton = ProminentButton(title: "Register",
                                         target: self, action: #selector(registerTapped),
                                         fill: Tokens.Color.goldCTA,
                                         picksInkFromFill: true,
                                         titleFont: Tokens.Font.bodyEmphasized)
        registerButton.keyEquivalent = "\r"
        registerButton.translatesAutoresizingMaskIntoConstraints = false

        buyButton.title = "Buy Audiout…"
        buyButton.bezelStyle = .rounded
        buyButton.controlSize = .small
        buyButton.target = self
        buyButton.action = #selector(buyTapped)
        buyButton.isHidden = settings.buyURL == nil

        quitButton.title = "Quit"
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        quitButton.target = self
        quitButton.action = #selector(quitTapped)
        // No main menu exists yet at the gate, so ⌘Q needs an explicit home.
        quitButton.keyEquivalent = "q"
        quitButton.keyEquivalentModifierMask = [.command]

        // Buy and Quit live on the window's bottom edge, out of the hero
        // column — stacked under the gold Register they read as a second CTA.
        let quietRow = NSStackView(views: [buyButton, quitButton])
        quietRow.orientation = .horizontal
        quietRow.spacing = 8
        quietRow.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [mark, headline, why, keyField, resultLine,
                                         registerButton])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 10
        column.setCustomSpacing(14, after: mark)
        column.setCustomSpacing(6, after: headline)
        column.setCustomSpacing(22, after: why)
        column.setCustomSpacing(12, after: keyField)
        column.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(field)
        root.addSubview(column)
        root.addSubview(quietRow)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.contentSize.width),
            root.heightAnchor.constraint(equalToConstant: Self.contentSize.height),
            field.topAnchor.constraint(equalTo: root.topAnchor),
            field.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            quietRow.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            quietRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            mark.widthAnchor.constraint(equalToConstant: 96),
            mark.heightAnchor.constraint(equalToConstant: 96),
            keyField.widthAnchor.constraint(equalToConstant: Self.columnWidth),
        ])
        view = root

        keyField.nextKeyView = registerButton
        registerButton.nextKeyView = buyButton
        buyButton.nextKeyView = quitButton
        quitButton.nextKeyView = keyField
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        field.start()
        // The field is why the window exists — typing starts without a click.
        view.window?.makeFirstResponder(keyField)
    }

    // MARK: Actions

    @objc private func buyTapped() {
        guard let url = settings.buyURL else { return }
        Analytics.capture("license:buy_link_opened", ["source": "gate"])
        // Leaves the gate open: the buyer comes back with a key to paste.
        openURL(url)
    }

    @objc private func quitTapped() {
        NSApp?.terminate(nil)
    }

    @objc private func registerTapped() {
        let text = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            show(result: "Enter the key from your purchase receipt.")
            return
        }

        // A different key is an unanswered question: the previous key's
        // verdict must not stand in for it while the server is asked.
        if text != settings.licenseKey { settings.licenseStatus = nil }
        settings.licenseKey = text

        keyField.isEnabled = false
        registerButton.isEnabled = false
        show(result: "Checking…")

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
                self.show(result: LicenseCopy.statusLine(for: .active))
                self.field.surge()
                self.pass(afterBeat: true)
            case .verified(let status):
                self.keyField.isEnabled = true
                self.registerButton.isEnabled = true
                self.keyField.stringValue = self.settings.licenseKey ?? ""
                self.show(result: LicenseCopy.statusLine(for: status))
                self.view.window?.makeFirstResponder(self.keyField)
            case .unreachable, .noServer, .noKey:
                // The key is SAVED and the gate opens: an unreachable server
                // must never lock a buyer out of the thing they paid for. The
                // normal launch validation settles the verdict later.
                self.show(result: "The license server can't be reached right now. "
                    + "Your key is saved and will be checked once you're online.")
                self.pass(afterBeat: true)
            }
        }
    }

    /// Open the gate exactly once. `afterBeat` holds the window just long
    /// enough for the result line and the field's surge to land — skipped
    /// under Reduce Motion and headless, where there is nothing to watch.
    private func pass(afterBeat: Bool) {
        guard !didPass else { return }
        didPass = true
        let animated = afterBeat && !HeadlessRuntime.isActive
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated else { return onPassed() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.onPassed()
        }
    }

    private func show(result: String) {
        resultLine.stringValue = result
        resultLine.isHidden = false
    }

    /// Fill the field with `key` and submit it, exactly as a paste followed by
    /// Register would — the landing point for `audiout://register?key=…` while
    /// the gate is up. A submission already in flight drops the link the same
    /// way a second click is dropped.
    public func submit(key: String) {
        _ = view
        guard registerButton.isEnabled else { return }
        keyField.stringValue = key
        registerTapped()
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

    /// The inline result line's text, or `nil` while it is hidden.
    public var test_resultText: String? {
        _ = view
        return resultLine.isHidden ? nil : resultLine.stringValue
    }

    /// Whether "Buy Audiout…" is offered (needs a buy URL to point at).
    public var test_buyIsVisible: Bool {
        _ = view
        return !buyButton.isHidden
    }

    /// Whether the gate has fired `onPassed` (or is in the beat before it).
    public var test_didPass: Bool { didPass }
}
