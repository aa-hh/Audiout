// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// Tiny layout kit shared by the Settings panes so every pane reads as one
/// consistent macOS form: a fixed-width column of `title · optional subtitle`
/// rows with the control right-aligned, standard insets, and a fitting height
/// the tab controller resizes the window to. Deliberately minimal — panes stay
/// small, so this is a few helpers, not a framework.
enum SettingsForm {

    /// Fixed content width for every pane (settings windows don't reflow).
    static let contentWidth: CGFloat = 460

    /// A leading-aligned label.
    static func label(_ string: String) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// One form row: a `title` (plus optional wrapping `subtitle` beneath it) on
    /// the leading edge, `control` pinned to the trailing edge and vertically
    /// centred on the title text. The returned view sizes its own height from its
    /// contents.
    static func row(title: String, subtitle: String? = nil, control: NSView) -> NSView {
        let titleLabel = label(title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)

        var subtitleLabel: NSTextField?
        if let subtitle {
            let sub = label(subtitle)
            sub.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            sub.textColor = .secondaryLabelColor
            sub.lineBreakMode = .byWordWrapping
            sub.maximumNumberOfLines = 0
            sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textStack.addArrangedSubview(sub)
            subtitleLabel = sub
        }

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        let container = RowContainerView(subtitleLabel: subtitleLabel, controlView: control)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(textStack)
        container.addSubview(control)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            textStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),

            control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
        return container
    }

    /// A bold, secondary-colored category label ("General", "Appearance", …) at
    /// `contentWidth`, indented to align with the row content beneath it. Used by
    /// the single-screen `SettingsWindowController` to delineate each merged
    /// section — there's no tab bar to carry that label anymore.
    static func sectionHeaderLabel(_ text: String) -> NSView {
        let title = label(text)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: contentWidth),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: container.topAnchor),
            title.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// A full-width hairline divider between merged sections, inset to match the
    /// row content's horizontal margins.
    static func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: contentWidth),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 1),
        ])
        return container
    }

    /// Stack `rows` into a pane view: fixed `contentWidth`, standard 20/18pt
    /// insets, full-width rows. The caller assigns this to `NSViewController.view`;
    /// the fixed width lets `view.fittingSize.height` drive `preferredContentSize`.
    static func paneView(rows: [NSView]) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: contentWidth),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
        ])
        // Each row fills the column width (a vertical stack sizes arranged views
        // to their intrinsic width otherwise).
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return container
    }
}

/// `SettingsForm.row`'s container. Exists solely to fix a real, reproduced
/// AppKit circularity (2026-07-17 design pass): a wrapping `NSTextField` with
/// `preferredMaxLayoutWidth` left at its default (0) can resolve its intrinsic
/// HEIGHT from an earlier, too-narrow trial WIDTH before the rest of the
/// constraint graph has settled — measured empirically, a 265pt-wide, single-
/// line subtitle collapsed to a 97pt width and wrapped into 4 lines, inflating
/// a 44pt row to 86pt (and the whole General pane to 122pt — the visible
/// "empty gap under Launch at login" ahh flagged). Recomputing
/// `preferredMaxLayoutWidth` from the actually-resolved bounds on every
/// `layout()` call is the documented AppKit fix, and doing it here (not a
/// fixed literal) keeps it correct if a future row uses a wider control than
/// the switch this was diagnosed against.
private final class RowContainerView: NSView {
    private let subtitleLabel: NSTextField?
    private let controlView: NSView

    init(subtitleLabel: NSTextField?, controlView: NSView) {
        self.subtitleLabel = subtitleLabel
        self.controlView = controlView
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        if let subtitleLabel {
            let available = bounds.width - controlView.frame.width - 16
            if available > 0 {
                subtitleLabel.preferredMaxLayoutWidth = available
            }
        }
        super.layout()
    }
}
