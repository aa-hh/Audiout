// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

public extension NSTextField {

    /// A sentence explaining the controls beside it: caption type in
    /// `label2`, wrapping to two lines, the second truncating at its tail.
    /// The host gives it a width to wrap against (`preferredMaxLayoutWidth`),
    /// or the label measures itself as one long line.
    static func noteLabel(_ text: String = "") -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Tokens.Font.caption
        label.textColor = Tokens.Color.label2
        label.isSelectable = false
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        return label
    }
}
