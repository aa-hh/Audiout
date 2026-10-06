// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The pieces every Settings pane opens and builds with, so the five panes
/// share the Speakers page's header, cards and lane.
@MainActor
enum SettingsPane {

    /// The page header: a bare glyph in the 48 pt slot (no well), the title,
    /// and an optional caption (the text stack's second view). Returns the
    /// glyph so a pane can re-tint it.
    static func makeHeader(symbolName: String, title: String,
                           caption: String? = nil) -> (header: PageHeaderView, glyph: NSImageView) {
        let slot = NSView()
        let glyph = NSImageView()
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = DeviceIcon.image(symbolName)
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = Tokens.Color.labelCool
        glyph.setAccessibilityElement(false)
        glyph.redrawOnAccessibilityDisplayChange()
        slot.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.topAnchor.constraint(equalTo: slot.topAnchor, constant: 9),
            glyph.leadingAnchor.constraint(equalTo: slot.leadingAnchor, constant: 9),
            glyph.trailingAnchor.constraint(equalTo: slot.trailingAnchor, constant: -9),
            glyph.bottomAnchor.constraint(equalTo: slot.bottomAnchor, constant: -9),
        ])

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Tokens.Font.heading
        titleLabel.textColor = Tokens.Color.label
        titleLabel.setAccessibilityHeading()

        let captionLabel = caption.map { text -> NSTextField in
            let label = NSTextField(labelWithString: text)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = Tokens.Font.caption
            label.textColor = Tokens.Color.labelCool
            return label
        }
        let header = PageHeaderView(icon: slot, title: titleLabel, caption: captionLabel, leadingInset: .railFree)
        return (header, glyph)
    }

    /// A card of rows: a `GroupedSectionView` behind a zero-spacing stack.
    /// A caller that mounts or unmounts rows resets `box.rows` to the stack's
    /// visible arranged rows afterwards.
    static func makeCard(rows: [NSView]) -> (container: NSView, box: GroupedSectionView, stack: NSStackView) {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let box = GroupedSectionView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.style = .card
        box.radiusOverride = Tokens.Layout.Radius.row
        box.contentLeadingInset = ListRowView.leadingInset
        box.contentTrailingInset = ListRowView.trailingInset
        // Added first so it sits behind the rows.
        container.addSubview(box)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: container.topAnchor),
            box.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            box.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: GroupedSectionView.verticalPadding),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -GroupedSectionView.verticalPadding),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        box.rows = stack.arrangedSubviews.filter { !$0.isHidden }
        return (container, box, stack)
    }

    /// The lane inside a card: the page's lane minus the rows' own insets.
    static let cardLaneWidth: CGFloat =
        GroupsPaneLayout.railFreeContentWidth - ListRowView.leadingInset - ListRowView.trailingInset

    /// A card row that is not a `ListRowView`: `content` on the rows' lane,
    /// with a row's 9 pt vertical padding.
    static func makeLaneRow(_ content: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -9),
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: ListRowView.leadingInset),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -ListRowView.trailingInset),
        ])
        return row
    }

    /// A title over a group of cards, in the body voice.
    static func makeSectionTitle(_ string: String) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = Tokens.Font.body
        field.textColor = Tokens.Color.label2
        return field
    }

    /// A wrapping note on the lane. The wrap width is set here: an unset one
    /// reports the unwrapped width and drags the pane wider
    /// (`SettingsForm.hintLabel`).
    static func makeNote(_ string: String) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = Tokens.Font.caption
        field.textColor = Tokens.Color.label2
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = GroupsPaneLayout.railFreeContentWidth
        return field
    }
}
