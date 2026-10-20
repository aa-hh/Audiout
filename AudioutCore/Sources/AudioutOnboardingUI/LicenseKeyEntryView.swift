// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The licence gate's key entry: a fixed `AUDT` plate drawn like a box, then
/// four boxes of five characters with a dash before each — the key's own
/// shape, so a buyer copying it by eye can see where they are. The row is
/// 8/10 of the panel's inner width, the plate a fifth of the row.
///
/// Every box is an `NSTextField` drawn by `CodeBoxCell`, and the editing
/// rules follow the AirPlay code sheet's (`SpeakerPasswordSheetViewController`):
/// a full box moves focus on, a paste spreads from the edited box, Delete on
/// an empty box steps back. What a box accepts is the key alphabet, Crockford
/// base32, with `O`, `I` and `L` read as `0`, `1`, `1` the way the licence
/// server forgives them. `onChange` fires after every edit and every `fill`,
/// which is how the gate submits a full key the moment it lands.
@MainActor
final class LicenseKeyEntryView: NSView, NSTextFieldDelegate {

    static let boxCount = 4
    static let groupSize = 5
    /// The row is 8/10 of the panel's inner width (655): the `AUDT` plate takes
    /// a fifth of it, and the four boxes share the rest with one gap size
    /// between every segment, so the key reads as five plates in a line.
    /// 104 + 4 × 16 + 4 × 89 = 524.
    static let plateWidth: CGFloat = 104
    static let boxWidth: CGFloat = 89
    static let boxHeight: CGFloat = 40
    static let dashWidth: CGFloat = 16
    /// Tracking between characters, so five of them read as a group.
    static let kern: CGFloat = 1
    /// The code sheet's 24 pt medium monospaced digits, sized for a group of five.
    static var font: NSFont { .monospacedSystemFont(ofSize: 17, weight: .medium) }

    private nonisolated static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Uppercased, a leading `AUDT` prefix dropped, `O`/`I`/`L` mapped, and
    /// every other character outside the alphabet (dashes, spaces) dropped.
    nonisolated static func normalised(_ text: String) -> String {
        var s = text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("AUDT") { s.removeFirst(4) }
        return String(s.compactMap { c -> Character? in
            switch c {
            case "O": return "0"
            case "I", "L": return "1"
            default: return alphabet.contains(c) ? c : nil
            }
        })
    }

    private let boxes: [NSTextField]
    /// What each box held after the last text change was handled.
    private var lastTexts = Array(repeating: "", count: boxCount)
    private var focusedIndex = 0

    /// Fired after every edit, typed, pasted or filled.
    var onChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        boxes = (0..<Self.boxCount).map { _ in
            let box = NSTextField()
            box.cell = CodeBoxCell(textCell: "")
            return box
        }
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = Self.font
            label.textColor = Tokens.Color.label2
            return label
        }

        // The plate is a box the user cannot type into: same cell, same
        // size family, quieter ink, so the prefix reads as the key's first
        // segment rather than a caption beside it.
        let plate = NSTextField()
        plate.cell = CodeBoxCell(textCell: "AUDT")
        plate.isEditable = false
        plate.isSelectable = false
        plate.font = Self.font
        plate.textColor = Tokens.Color.label2
        plate.alignment = .center
        plate.setAccessibilityLabel("AUDT, the key's prefix")
        var views: [NSView] = [plate]
        var constraints: [NSLayoutConstraint] = [
            plate.widthAnchor.constraint(equalToConstant: Self.plateWidth),
            plate.heightAnchor.constraint(equalToConstant: Self.boxHeight),
        ]
        for (i, box) in boxes.enumerated() {
            box.font = Self.font
            box.textColor = Tokens.Color.label
            box.alignment = .center
            box.usesSingleLineMode = true
            box.delegate = self
            box.setAccessibilityLabel("group \(i + 1) of \(Self.boxCount), five characters")
            let dash = label("–")
            dash.alignment = .center
            dash.setAccessibilityElement(false)
            constraints += [
                dash.widthAnchor.constraint(equalToConstant: Self.dashWidth),
                box.widthAnchor.constraint(equalToConstant: Self.boxWidth),
                box.heightAnchor.constraint(equalToConstant: Self.boxHeight),
            ]
            views += [dash, box]
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        constraints += [
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        NSLayoutConstraint.activate(constraints)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Licence key")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: API

    /// `AUDT-XXXXX-XXXXX-XXXXX-XXXXX` when complete, the partial boxes in the
    /// same shape otherwise, and empty when no box holds anything.
    var keyText: String {
        let texts = boxes.map(\.stringValue)
        guard let last = texts.lastIndex(where: { !$0.isEmpty }) else { return "" }
        return (["AUDT"] + texts[...last]).joined(separator: "-")
    }

    var isComplete: Bool { boxes.allSatisfy { $0.stringValue.count == Self.groupSize } }

    var isEnabled: Bool {
        get { boxes.first?.isEnabled ?? false }
        set { boxes.forEach { $0.isEnabled = newValue } }
    }

    /// Normalise `text` and lay it into the boxes from the first one, then
    /// focus the first box that is not full, or the last when all four are.
    func fill(_ text: String) {
        let chars = Array(Self.normalised(text).prefix(Self.boxCount * Self.groupSize))
        for i in 0..<Self.boxCount {
            setText(i, String(chars.dropFirst(i * Self.groupSize).prefix(Self.groupSize)))
        }
        lastTexts = boxes.map(\.stringValue)
        focusFirstEmpty()
        onChange?()
    }

    func clear() {
        (0..<Self.boxCount).forEach { setText($0, "") }
        lastTexts = boxes.map(\.stringValue)
        onChange?()
    }

    func focusFirstEmpty() {
        focusBox(boxes.firstIndex { $0.stringValue.count < Self.groupSize } ?? Self.boxCount - 1)
    }

    /// Focus box `i` with the caret after its last character and nothing
    /// selected, so typing adds to the group rather than wiping it.
    func focusBox(_ i: Int) {
        focusedIndex = i
        guard let window, window.makeFirstResponder(boxes[i]) else { return }
        let end = boxes[i].stringValue.utf16.count
        boxes[i].currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    /// The first and last boxes, for the gate's authored tab order.
    var firstBox: NSView { boxes[0] }
    var lastBox: NSView { boxes[Self.boxCount - 1] }

    /// Chain the boxes in order and send the last one's Tab to `next`.
    func chainKeyViews(to next: NSView) {
        for i in 0..<Self.boxCount - 1 { boxes[i].nextKeyView = boxes[i + 1] }
        boxes[Self.boxCount - 1].nextKeyView = next
    }

    // MARK: Editing

    /// The box's text with the row's tracking. The field editor keeps its own
    /// copy while a box is edited, so the tracking goes there too.
    private func setText(_ i: Int, _ text: String) {
        let box = boxes[i]
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        box.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: Self.font, .foregroundColor: Tokens.Color.label,
            .kern: Self.kern, .paragraphStyle: paragraph,
        ])
        if let editor = box.currentEditor() as? NSTextView {
            editor.textStorage?.addAttribute(.kern, value: Self.kern,
                                             range: NSRange(location: 0, length: editor.string.utf16.count))
            editor.typingAttributes[.kern] = Self.kern
        }
    }

    /// Up to five characters stay in the edited box, and the fifth arriving
    /// moves focus on. More than five spreads from the edited box onward,
    /// five per box, so a pasted key fills every box.
    func controlTextDidChange(_ obj: Notification) {
        guard let box = obj.object as? NSTextField,
              let i = boxes.firstIndex(where: { $0 === box }) else { return }
        let raw = box.stringValue
        let chars = Self.normalised(raw)
        let caret = box.currentEditor()?.selectedRange.location
        if chars.count <= Self.groupSize {
            setText(i, chars)
            if chars.count == Self.groupSize, lastTexts[i].count < Self.groupSize, i < Self.boxCount - 1 {
                focusBox(i + 1)
            } else if let caret, let editor = box.currentEditor() {
                let at = max(0, min(caret - (raw.utf16.count - chars.utf16.count), chars.utf16.count))
                editor.selectedRange = NSRange(location: at, length: 0)
            }
        } else {
            let spread = Array(chars.prefix((Self.boxCount - i) * Self.groupSize))
            var last = i
            for (offset, start) in stride(from: 0, to: spread.count, by: Self.groupSize).enumerated() {
                last = i + offset
                setText(last, String(spread[start..<min(start + Self.groupSize, spread.count)]))
            }
            let lastIsFull = boxes[last].stringValue.count == Self.groupSize
            focusBox(lastIsFull && last < Self.boxCount - 1 ? last + 1 : last)
        }
        lastTexts = boxes.map(\.stringValue)
        onChange?()
    }

    /// Delete on an empty box moves to the end of the box before it, without
    /// deleting there on the same keystroke.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.deleteBackward(_:)),
              let i = boxes.firstIndex(where: { $0 === control }),
              boxes[i].stringValue.isEmpty, i > 0 else { return false }
        focusBox(i - 1)
        return true
    }

    // MARK: Test-support hooks

    /// Each box's text, in order.
    var test_boxTexts: [String] { boxes.map(\.stringValue) }

    /// The boxes themselves.
    var test_boxes: [NSTextField] { boxes }

    /// The box that holds focus.
    var test_focusedIndex: Int { focusedIndex }

    /// Add `text` to the end of the focused box and deliver the change, as
    /// typing or a paste at the caret would.
    func test_type(_ text: String) {
        let box = boxes[focusedIndex]
        box.stringValue += text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: box))
    }

    /// Press Delete in the focused box.
    func test_backspace() {
        _ = control(boxes[focusedIndex], textView: NSTextView(),
                    doCommandBy: #selector(NSResponder.deleteBackward(_:)))
    }
}
