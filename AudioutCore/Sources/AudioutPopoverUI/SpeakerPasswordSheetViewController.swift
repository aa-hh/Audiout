// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The sheet that asks for a speaker's AirPlay password, or for the code a
/// receiver shows on its screen (`CredentialKind`). Same shape as
/// `LicenseSheetViewController` (Settings): a 320-pt stack, one field, a result
/// line that appears only after a submit, Cancel (Escape) and a gold Connect
/// (Return). The code kind shows four one-digit boxes in place of the field,
/// and the fourth digit submits by itself.
///
/// The sheet stores nothing and connects nothing: `onSubmit` hands the typed
/// password to the host, which stores it and retries the speaker, then calls
/// `showResult` when the attempt fails or dismisses the sheet when it connects.
/// Headless tests hold the controller and drive it through the `test_` hooks.
@MainActor
public final class SpeakerPasswordSheetViewController: NSViewController, NSTextFieldDelegate {

    private static let sheetContentWidth: CGFloat = 320

    /// What the sheet asks for: a password, or the code the receiver shows on its screen.
    public enum CredentialKind { case password, onScreenCode }

    // The phone shows its own copy of these; `CompanionCopyTripwireTests` holds the two in step.
    static let emptyPasswordText = "Enter the speaker's password."
    static let emptyCodeText = "Enter the code on the screen."
    static let connectingText = "Connecting…"
    nonisolated static func headingText(deviceName: String) -> String {
        headingText(deviceName: deviceName, kind: .password)
    }
    nonisolated static func headingText(deviceName: String, kind: CredentialKind) -> String {
        switch kind {
        case .password: return "Enter the password for “\(deviceName)”"
        case .onScreenCode: return "Enter the code shown on “\(deviceName)”"
        }
    }

    private let deviceName: String
    private let kind: CredentialKind
    /// The password kind's field; the code kind never adds it to the view.
    private let passwordField: NSTextField
    /// The code kind's four one-digit boxes; empty for the password kind.
    private let codeBoxes: [NSTextField]
    private var focusedBoxIndex = 0
    /// What each code box held after the last text change was handled.
    private var lastDigits = Array(repeating: "", count: 4)
    private let resultLine = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = NSButton()
    private var connectButton: ProminentButton!

    /// Fired with the trimmed, non-empty password on Connect.
    public var onSubmit: ((String) -> Void)?
    /// Fired on Cancel; the host dismisses the sheet.
    public var onCancel: (() -> Void)?

    public init(deviceName: String, kind: CredentialKind = .password) {
        self.deviceName = deviceName
        self.kind = kind
        passwordField = kind == .password ? NSSecureTextField() : NSTextField()
        codeBoxes = kind == .onScreenCode ? (0..<4).map { _ in NSTextField() } : []
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        let heading = NSTextField(labelWithString: Self.headingText(deviceName: deviceName, kind: kind))
        heading.font = Tokens.Font.bodyEmphasized
        heading.lineBreakMode = .byTruncatingTail

        let entry: NSView
        var entryConstraints: [NSLayoutConstraint] = []
        if kind == .password {
            passwordField.placeholderString = "Password"
            passwordField.setAccessibilityLabel("AirPlay password")
            passwordField.translatesAutoresizingMaskIntoConstraints = false
            passwordField.usesSingleLineMode = true
            passwordField.cell?.isScrollable = true
            entry = passwordField
        } else {
            for (i, box) in codeBoxes.enumerated() {
                box.alignment = .center
                // 22 pt is this row's own size, not a shared voice.
                box.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
                box.usesSingleLineMode = true
                box.delegate = self
                box.translatesAutoresizingMaskIntoConstraints = false
                box.setAccessibilityLabel("digit \(i + 1) of 4")
                entryConstraints += [
                    box.widthAnchor.constraint(equalToConstant: 44),
                    box.heightAnchor.constraint(equalToConstant: 40),
                ]
            }
            let row = NSStackView(views: codeBoxes)
            row.orientation = .horizontal
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            row.setAccessibilityElement(true)
            row.setAccessibilityRole(.group)
            row.setAccessibilityLabel("AirPlay code")
            entry = row
        }

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

        let stack = NSStackView(views: [heading, entry, resultLine, buttonRow])
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
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ] + entryConstraints)
        if kind == .password {
            passwordField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = container
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        if kind == .onScreenCode {
            focusBox(0)
        } else {
            view.window?.makeFirstResponder(passwordField)
        }
    }

    private func focusBox(_ i: Int) {
        focusedBoxIndex = i
        view.window?.makeFirstResponder(codeBoxes[i])
    }

    /// Runs on every text change in a code box and keeps only ASCII digits.
    /// Two digits in a box that held one means the user typed over it with the
    /// caret beside the old digit: the new digit replaces it. Anything else
    /// spreads from the edited box onward, so a pasted code fills every box.
    public func controlTextDidChange(_ obj: Notification) {
        guard let box = obj.object as? NSTextField,
              let i = codeBoxes.firstIndex(where: { $0 === box }) else { return }
        var digits = box.stringValue.filter { $0.isASCII && $0.isNumber }
        let old = lastDigits[i]
        if !old.isEmpty, digits.count == 2, let at = digits.firstIndex(of: Character(old)) {
            digits.remove(at: at)
            box.stringValue = digits
            focusBox(min(i + 1, codeBoxes.count - 1))
        } else {
            box.stringValue = ""
            var last = i - 1
            for (offset, digit) in digits.prefix(codeBoxes.count - i).enumerated() {
                codeBoxes[i + offset].stringValue = String(digit)
                last = i + offset
            }
            focusBox(min(last + 1, codeBoxes.count - 1))
        }
        lastDigits = codeBoxes.map(\.stringValue)
        if codeBoxes.allSatisfy({ !$0.stringValue.isEmpty }) {
            connectTapped()
        }
    }

    /// Delete on an empty box clears the box before it and moves there.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.deleteBackward(_:)),
              let i = codeBoxes.firstIndex(where: { $0 === control }),
              codeBoxes[i].stringValue.isEmpty, i > 0 else { return false }
        codeBoxes[i - 1].stringValue = ""
        lastDigits[i - 1] = ""
        focusBox(i - 1)
        return true
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    @objc private func connectTapped() {
        if kind == .onScreenCode {
            let code = codeBoxes.map(\.stringValue).joined()
            guard code.count == codeBoxes.count else {
                show(result: Self.emptyCodeText)
                return
            }
            codeBoxes.forEach { $0.isEnabled = false }
            connectButton.isEnabled = false
            show(result: Self.connectingText)
            onSubmit?(code)
            return
        }
        let text = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            show(result: kind == .password ? Self.emptyPasswordText : Self.emptyCodeText)
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
        if kind == .onScreenCode {
            codeBoxes.forEach {
                $0.stringValue = ""
                $0.isEnabled = true
            }
            lastDigits = codeBoxes.map(\.stringValue)
            focusBox(0)
        }
    }

    private func show(result: String) {
        resultLine.stringValue = result
        resultLine.isHidden = false
    }

    // MARK: Test-support hooks

    /// Replace the password kind's field text, as typing would.
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

    /// Put `text` in code box `index` and deliver the change, as typing or paste would.
    public func test_typeIntoBox(_ index: Int, _ text: String) {
        _ = view
        codeBoxes[index].stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: codeBoxes[index]))
    }

    /// Press Delete in the focused code box.
    public func test_backspace() {
        _ = view
        _ = control(codeBoxes[focusedBoxIndex], textView: NSTextView(),
                    doCommandBy: #selector(NSResponder.deleteBackward(_:)))
    }

    /// The code boxes' digits, joined.
    public var test_codeDigits: String {
        _ = view
        return codeBoxes.map(\.stringValue).joined()
    }

    /// The code box that holds focus.
    public var test_focusedBoxIndex: Int {
        _ = view
        return focusedBoxIndex
    }
}
