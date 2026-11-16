// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// A gold text action: a tertiary call to action that must read as a route
/// forward, the Mac's version of the iPhone's `TextAction`. Today only the
/// licence gate's "I have a key" and "Paste key".
///
/// Semibold `bodyEmphasized` in `goldText`, no underline, no bezel; `label3`
/// while disabled. The pointing-hand cursor shows only while it is enabled.
/// `TextLinkButton` stays the quiet, underlined link; this is the one with
/// the highlight colour.
public final class TextActionButton: NSButton {

    /// The visible title. Set this rather than `title`, which would drop the
    /// gold ink.
    public var actionTitle: String {
        didSet { restyle() }
    }

    public override var isEnabled: Bool {
        didSet {
            restyle()
            window?.invalidateCursorRects(for: self)
        }
    }

    public init(title: String, target: AnyObject? = nil, action: Selector? = nil) {
        self.actionTitle = title
        super.init(frame: .zero)
        bezelStyle = .accessoryBar
        isBordered = false
        controlSize = .regular
        self.target = target
        self.action = action
        restyle()
        // `goldText` is on the accent dial: a dial change must reach a button
        // already on screen.
        NotificationCenter.default.addObserver(
            self, selector: #selector(accentStyleChanged),
            name: Tokens.accentStyleDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func accentStyleChanged() { restyle() }

    private func restyle() {
        attributedTitle = NSAttributedString(string: actionTitle, attributes: [
            .font: Tokens.Font.bodyEmphasized,
            .foregroundColor: isEnabled ? Tokens.Color.goldText : Tokens.Color.label3,
        ])
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
