// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// An underlined text action: "Enter Password…" on a speaker row, the
/// licence window's quiet links, the note banner's "I have a key".
///
/// The underline is the only control signal. Ink is `label2`, `label3` while
/// disabled (an attributed title carries its own colour, so `isEnabled` alone
/// would leave it at full strength), never gold. The pointing-hand cursor
/// shows only while it is enabled.
public final class TextLinkButton: NSButton {

    public enum Size {
        case body
        case caption

        var font: NSFont {
            switch self {
            case .body: return Tokens.Font.body
            case .caption: return Tokens.Font.caption
            }
        }
    }

    public let size: Size

    /// The visible title. Set this rather than `title`, which would drop the
    /// underline.
    public var linkTitle: String {
        didSet { restyle() }
    }

    public override var isEnabled: Bool {
        didSet {
            restyle()
            window?.invalidateCursorRects(for: self)
        }
    }

    public init(title: String, size: Size = .body, target: AnyObject? = nil, action: Selector? = nil) {
        self.size = size
        self.linkTitle = title
        super.init(frame: .zero)
        bezelStyle = .accessoryBar
        isBordered = false
        controlSize = size == .caption ? .small : .regular
        self.target = target
        self.action = action
        restyle()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func restyle() {
        attributedTitle = NSAttributedString(string: linkTitle, attributes: [
            .font: size.font,
            .foregroundColor: isEnabled ? Tokens.Color.label2 : Tokens.Color.label3,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
