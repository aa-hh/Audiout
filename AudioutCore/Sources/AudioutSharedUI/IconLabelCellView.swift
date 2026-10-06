// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// A sidebar row cell: the icon, the name with its optional caption, and a
/// trailing `chevron.right` saying the row leads somewhere (the two plates).
///
/// The chevron lives in an `NSStackView`, which DETACHES hidden arranged
/// subviews: a speaker row, where it is hidden, gets its full label width
/// back instead of reserving trailing space it never uses ("MacBook Pro
/// Speakers" is already the name this 210 pt sidebar barely fits).
///
/// Its inks follow the row's selection: resting inks while unselected, the
/// accent pill's text colour on the focused pill, `label` on the grey one.
/// The grey pill leaves the cell's `backgroundStyle` alone, so the row view
/// (`SidebarRowView`) tells the cell instead.
public final class IconLabelCellView: NSTableCellView {
    /// The trailing disclosure chevron — drawing only, and never an AX element:
    /// the row itself is what VoiceOver announces and activates.
    let disclosureView: NSImageView = {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        v.image?.isTemplate = true
        v.contentTintColor = Tokens.Color.labelCool2
        v.isHidden = true
        v.setAccessibilityElement(false)
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.redrawOnAccessibilityDisplayChange()
        return v
    }()

    /// The row's name. Only a speaker row also hands it to the `textField`
    /// outlet, which gives it the source list's font and the expansion
    /// tooltip; a plate keeps its own font.
    public let nameLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.redrawOnAccessibilityDisplayChange()
        return label
    }()

    /// The caption under the name. The name's spoken label already says it,
    /// so it is not an accessibility element of its own.
    public let statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = Tokens.Font.caption
        label.textColor = Tokens.Color.labelCool
        label.isHidden = true
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityElement(false)
        label.redrawOnAccessibilityDisplayChange()
        return label
    }()

    let labelStack: NSStackView = {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Tokens.Layout.titleSubtitleSpacing
        return stack
    }()

    /// Holds the chevron. `detachesHiddenViews` (the default) is what makes a
    /// hidden chevron cost zero width.
    let trailingStack: NSStackView = {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }()

    /// The name's and the icon's inks while the row is not selected.
    private var restingNameInk = Tokens.Color.label
    private var restingIconInk = Tokens.Color.label

    public func setDisclosureVisible(_ visible: Bool) {
        disclosureView.isHidden = !visible
    }

    public func setRestingInks(name: NSColor, icon: NSColor) {
        restingNameInk = name
        restingIconInk = icon
    }

    /// Every ink in the cell: the accent pill's text colour on the focused
    /// pill, `label` on the grey one, the resting inks otherwise.
    public func applySelectionInks(selected: Bool, emphasized: Bool) {
        let pillInk: NSColor? = selected ? (emphasized ? NSColor.alternateSelectedControlTextColor : Tokens.Color.label) : nil
        nameLabel.textColor = pillInk ?? restingNameInk
        imageView?.contentTintColor = pillInk ?? restingIconInk
        statusLabel.textColor = pillInk ?? Tokens.Color.labelCool
        disclosureView.contentTintColor = pillInk ?? Tokens.Color.labelCool2
    }

    /// Icon side length matching the outline view's `.medium` `rowSizeStyle`
    /// (design feedback 2026-07-18: 18pt read as visually small next to the
    /// detail pane's large header icon).
    private static let iconSize: CGFloat = SurfaceLayout.sidebarIconSize

    /// A speaker row hands its name to the `textField` outlet, which gives it
    /// the source list's font and the expansion tooltip, and cuts a long name
    /// in the middle; a plate keeps `bodyEmphasized` and cuts at the tail.
    public static func make(identifier: NSUserInterfaceItemIdentifier, isSpeakerRow: Bool) -> IconLabelCellView {
        let cell = IconLabelCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.redrawOnAccessibilityDisplayChange()
        cell.addSubview(imageView)
        cell.imageView = imageView

        cell.labelStack.setViews([cell.nameLabel, cell.statusLabel], in: .leading)
        cell.addSubview(cell.labelStack)
        if isSpeakerRow {
            cell.nameLabel.lineBreakMode = .byTruncatingMiddle
            cell.textField = cell.nameLabel
        } else {
            cell.nameLabel.font = Tokens.Font.bodyEmphasized
        }

        cell.trailingStack.setViews([cell.disclosureView], in: .leading)
        cell.addSubview(cell.trailingStack)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: iconSize),
            imageView.heightAnchor.constraint(equalToConstant: iconSize),

            cell.labelStack.leadingAnchor.constraint(
                equalTo: imageView.trailingAnchor, constant: SurfaceLayout.sidebarIconToLabelGap),
            cell.labelStack.trailingAnchor.constraint(
                equalTo: cell.trailingStack.leadingAnchor, constant: -6),
            cell.labelStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            cell.trailingStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            cell.trailingStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// A speaker row's row view: it re-inks its cell when the row's selection or
/// emphasis changes, because the grey pill leaves the cell's
/// `backgroundStyle` at `.normal` and the cell alone cannot tell.
open class SidebarRowView: NSTableRowView {
    open override var isSelected: Bool { didSet { reink() } }
    open override var isEmphasized: Bool { didSet { reink() } }

    public func reink() {
        // AppKit sets these while it prepares the row, before the cell is
        // added; `view(atColumn:)` raises on a row with no cell yet.
        guard numberOfColumns > 0 else { return }
        (view(atColumn: 0) as? IconLabelCellView)?.applySelectionInks(selected: isSelected, emphasized: isEmphasized)
    }
}
