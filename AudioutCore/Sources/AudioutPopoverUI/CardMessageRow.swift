// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// A card body row that holds a message instead of a speaker or an app: an
/// empty list, a search still running, a missing permission.
///
/// The message is `menuItem` in `label2`, on the name column, one line. Never
/// tertiary: this is live state text explaining why the list is empty, and
/// dimming the explanation of the dimming reads as broken. An optional hint
/// wraps under it in `captionMedium`, also `label2`; the row grows to fit it
/// and is never shorter than a body row. An optional small action button or
/// spinner sits after the message on its line; the spinner is left out under
/// Reduce Motion, where the words alone carry it.
final class CardMessageRow: NSView {

    struct Action {
        let title: String
        let target: AnyObject
        let selector: Selector
    }

    let messageLabel: NSTextField
    private(set) var actionButton: NSButton?

    init(message: String, hint: String? = nil, action: Action? = nil, showsSpinner: Bool = false) {
        messageLabel = NSTextField(labelWithString: message)
        messageLabel.font = Tokens.Font.menuItem
        messageLabel.textColor = Tokens.Color.label2
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.maximumNumberOfLines = 1
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        var line: [NSView] = [messageLabel]
        if let action {
            let button = NSButton(title: action.title, target: action.target, action: action.selector)
            button.bezelStyle = .accessoryBar
            button.controlSize = .small
            button.setAccessibilityLabel(action.title)
            actionButton = button
            line.append(button)
        }
        if showsSpinner, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            line.append(spinner)
        }
        let firstLine = NSStackView(views: line)
        firstLine.orientation = .horizontal
        firstLine.alignment = .centerY
        firstLine.spacing = 8
        firstLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(firstLine)

        let leading = PopoverColumnGrid.nameColumnLeading
        let trailing = -PopoverColumnGrid.trailingInset
        var constraints = [
            firstLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            firstLine.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: trailing),
            heightAnchor.constraint(greaterThanOrEqualToConstant: PopoverColumnGrid.bodyRowHeight),
        ]
        if let hint {
            let hintLabel = NSTextField(wrappingLabelWithString: hint)
            hintLabel.translatesAutoresizingMaskIntoConstraints = false
            hintLabel.font = Tokens.Font.captionMedium
            hintLabel.textColor = Tokens.Color.label2
            hintLabel.isSelectable = false
            hintLabel.preferredMaxLayoutWidth = SurfaceLayout.width - leading + trailing
            addSubview(hintLabel)
            constraints += [
                firstLine.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                hintLabel.topAnchor.constraint(equalTo: firstLine.bottomAnchor,
                                               constant: Tokens.Layout.titleSubtitleSpacing),
                hintLabel.leadingAnchor.constraint(equalTo: firstLine.leadingAnchor),
                hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: trailing),
                hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ]
        } else {
            constraints += [
                heightAnchor.constraint(equalToConstant: PopoverColumnGrid.bodyRowHeight),
                firstLine.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
