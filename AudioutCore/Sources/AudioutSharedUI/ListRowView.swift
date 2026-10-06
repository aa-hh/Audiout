// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// One row of the outlined list the speaker page and the Speakers page share:
/// an optional leading glyph, a title with an optional caption under it, and
/// an optional trailing accessory (a button, a pop-up, a spinner, a link
/// stack). Rows are stacked over a ``GroupedSectionView`` in `.card` style,
/// whose inset hairlines start at ``leadingInset`` so they line up with the
/// row's content. The insets are the page's own rail-free lane, so list text
/// lines up with the headings above the list.
public final class ListRowView: NSView {

    public static let leadingInset: CGFloat = GroupsPaneLayout.railFreeContentLeadingInset
    public static let trailingInset: CGFloat = GroupsPaneLayout.contentTrailingInset
    static let verticalPadding: CGFloat = 9
    static let minimumHeight: CGFloat = 44
    private static let glyphSide: CGFloat = 16
    private static let glyphToTextGap: CGFloat = 10
    private static let textToAccessoryGap: CGFloat = 10

    public let titleLabel = NSTextField(labelWithString: "")
    let captionLabel = NSTextField(wrappingLabelWithString: "")
    private let textStack = NSStackView()
    public private(set) var accessory: NSView?
    private let captionSpansRow: Bool

    /// A row that sits inside a button passes every click to it, so the whole
    /// row is one target; its labels then leave the speaking to the button.
    public var isClickThrough = false {
        didSet {
            titleLabel.setAccessibilityElement(!isClickThrough)
            captionLabel.setAccessibilityElement(!isClickThrough)
        }
    }

    public var caption: String? {
        get { captionLabel.isHidden ? nil : captionLabel.stringValue }
        set {
            captionLabel.stringValue = newValue ?? ""
            captionLabel.isHidden = newValue == nil
        }
    }

    /// A decorative 16 pt template glyph for the leading slot.
    public static func glyph(_ symbolName: String, tint: NSColor = Tokens.Color.label2) -> NSImageView {
        let view = NSImageView()
        view.image = DeviceIcon.image(symbolName)
        view.contentTintColor = tint
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityElement(false)
        return view
    }

    /// `captionSpansRow` keeps the title and accessory on one line and runs
    /// the caption the full lane width beneath them, for a row whose
    /// accessory is too wide to leave the caption a readable column.
    public init(glyph: NSView? = nil, title: String, caption: String? = nil, accessory: NSView? = nil,
                captionSpansRow: Bool = false) {
        self.captionSpansRow = captionSpansRow
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Tokens.Font.body
        titleLabel.textColor = Tokens.Color.label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.stringValue = title
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        captionLabel.font = Tokens.Font.caption
        captionLabel.textColor = Tokens.Color.labelCool
        captionLabel.maximumNumberOfLines = 2
        captionLabel.cell?.truncatesLastVisibleLine = true
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.caption = caption

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Tokens.Layout.titleSubtitleSpacing
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)
        if !captionSpansRow { textStack.addArrangedSubview(captionLabel) }
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(textStack)

        var constraints: [NSLayoutConstraint]
        if captionSpansRow {
            // The title line and the caption under it are centred as one block.
            captionLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(captionLabel)
            let block = NSLayoutGuide()
            addLayoutGuide(block)
            constraints = [
                heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight),
                block.topAnchor.constraint(equalTo: textStack.topAnchor),
                block.bottomAnchor.constraint(equalTo: captionLabel.bottomAnchor),
                block.centerYAnchor.constraint(equalTo: centerYAnchor),
                textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Self.verticalPadding),
                captionLabel.topAnchor.constraint(equalTo: textStack.bottomAnchor,
                                                  constant: Tokens.Layout.titleSubtitleSpacing),
                captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
                captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
                captionLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.verticalPadding),
            ]
        } else {
            constraints = [
                heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight),
                textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
                textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Self.verticalPadding),
                textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.verticalPadding),
            ]
        }

        if let glyph {
            glyph.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glyph)
            constraints += [
                glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
                glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
                glyph.widthAnchor.constraint(equalToConstant: Self.glyphSide),
                glyph.heightAnchor.constraint(equalToConstant: Self.glyphSide),
                textStack.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: Self.glyphToTextGap),
            ]
        } else {
            constraints.append(textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset))
        }

        if let accessory {
            self.accessory = accessory
            accessory.translatesAutoresizingMaskIntoConstraints = false
            accessory.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            accessory.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            addSubview(accessory)
            constraints += [
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
                captionSpansRow
                    ? accessory.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor)
                    : accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
                accessory.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Self.verticalPadding),
                accessory.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.verticalPadding),
                textStack.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor,
                                                    constant: -Self.textToAccessoryGap),
            ]
        } else {
            constraints.append(textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                                   constant: -Self.trailingInset))
        }
        // The text column fills what the accessory leaves, so a caption wraps
        // against the row's width rather than its own.
        let fill = textStack.trailingAnchor.constraint(
            equalTo: accessory?.leadingAnchor ?? trailingAnchor,
            constant: accessory == nil ? -Self.trailingInset : -Self.textToAccessoryGap)
        fill.priority = .defaultHigh - 1
        constraints.append(fill)
        // The height above is only a minimum, so a row in a card taller than
        // its rows took the spare height. This pulls it to the least its
        // content allows.
        let shortest = heightAnchor.constraint(equalToConstant: 0)
        shortest.priority = .defaultLow
        constraints.append(shortest)
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        isClickThrough ? nil : super.hitTest(point)
    }

    public override func layout() {
        super.layout()
        // A wrapping caption needs a width to compute its height against.
        let width = captionSpansRow ? captionLabel.frame.width : textStack.frame.width
        if width > 0, captionLabel.preferredMaxLayoutWidth != width {
            captionLabel.preferredMaxLayoutWidth = width
        }
    }
}
