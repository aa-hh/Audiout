// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The sheet that asks for a speaker's AirPlay password. Same shape as
/// `LicenseSheetViewController` (Settings): a 320-pt stack, one field, a result
/// line that appears only after a submit, Cancel (Escape) and a gold Connect
/// (Return).
///
/// The sheet stores nothing and connects nothing: `onSubmit` hands the typed
/// password to the host, which stores it and retries the speaker, then calls
/// `showResult` when the attempt fails or dismisses the sheet when it connects.
/// Headless tests hold the controller and drive it through the `test_` hooks.
@MainActor
public final class SpeakerPasswordSheetViewController: NSViewController {

    private static let sheetContentWidth: CGFloat = 320

    // The phone shows its own copy of these; `CompanionCopyTripwireTests` holds the two in step.
    static let emptyPasswordText = "Enter the speaker's password."
    static let connectingText = "Connecting…"
    nonisolated static func headingText(deviceName: String) -> String { "Enter the password for “\(deviceName)”" }

    private let deviceName: String
    private let passwordField = NSSecureTextField()
    private let resultLine = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = NSButton()
    private var connectButton: ProminentButton!

    /// Fired with the trimmed, non-empty password on Connect.
    public var onSubmit: ((String) -> Void)?
    /// Fired on Cancel; the host dismisses the sheet.
    public var onCancel: (() -> Void)?

    public init(deviceName: String) {
        self.deviceName = deviceName
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        let heading = NSTextField(labelWithString: Self.headingText(deviceName: deviceName))
        heading.font = Tokens.Font.bodyEmphasized
        heading.lineBreakMode = .byTruncatingTail

        passwordField.placeholderString = "Password"
        passwordField.setAccessibilityLabel("AirPlay password")
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.usesSingleLineMode = true
        passwordField.cell?.isScrollable = true

        resultLine.font = Tokens.Font.caption
        resultLine.textColor = Tokens.Color.label2
        resultLine.preferredMaxLayoutWidth = Self.sheetContentWidth
        resultLine.isHidden = true

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        connectButton = ProminentButton(title: "Connect", target: self,
                                        action: #selector(connectTapped))
        connectButton.keyEquivalent = "\r"
        connectButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, cancelButton, connectButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [heading, passwordField, resultLine, buttonRow])
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
            heading.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            passwordField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = container
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(passwordField)
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    @objc private func connectTapped() {
        let text = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            show(result: Self.emptyPasswordText)
            return
        }
        passwordField.isEnabled = false
        connectButton.isEnabled = false
        show(result: Self.connectingText)
        onSubmit?(text)
    }

    /// Re-enable the field and Connect and show `text`: the host's answer to a
    /// submit that did not connect.
    public func showResult(_ text: String) {
        _ = view
        passwordField.isEnabled = true
        connectButton.isEnabled = true
        show(result: text)
    }

    private func show(result: String) {
        resultLine.stringValue = result
        resultLine.isHidden = false
    }

    // MARK: Test-support hooks

    /// Replace the field's text, as typing would.
    public func test_setPasswordText(_ text: String) {
        _ = view
        passwordField.stringValue = text
    }

    /// Invoke Connect as a click would.
    public func test_tapConnect() {
        _ = view
        connectTapped()
    }

    /// Invoke Cancel as a click would.
    public func test_tapCancel() {
        _ = view
        cancelTapped()
    }

    /// The result line's text, or `nil` while it is hidden.
    public var test_resultText: String? {
        _ = view
        return resultLine.isHidden ? nil : resultLine.stringValue
    }

    /// The Connect button, for enablement assertions.
    public var test_connectButton: NSButton {
        _ = view
        return connectButton
    }
}
