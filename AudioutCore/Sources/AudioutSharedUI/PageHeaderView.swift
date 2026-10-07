// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The band every Speakers, Scenes and Settings page opens with: an icon slot,
/// then the page's title over an optional caption, as one block centred on the
/// icon. The slot accepts an icon well or Settings' bare glyph. The band draws
/// nothing; it exists for its geometry, which
/// `GroupsHeaderParityTests` holds level across the pages, because a sidebar
/// switch between pages whose bands differ reads as the window twitching.
///
/// The title slot takes any view: a plain label on speaker and Main Audio
/// pages, or the editable rename field on the scene editor. That difference
/// in skin is the message — see `GroupsPaneLayout`.
public final class PageHeaderView: NSView {

    let icon: NSView
    /// The title over the caption.
    public let textStack = NSStackView()

    public init(icon: NSView, title: NSView, caption: NSView? = nil) {
        self.icon = icon
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Tokens.Layout.titleSubtitleSpacing
        textStack.setViews([title] + (caption.map { [$0] } ?? []), in: .leading)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon)
        addSubview(textStack)

        // A long title truncates inside the band and never widens the pane.
        // 999 rather than required so that on a pathologically narrow pane the
        // rename field's required minimum width wins, instead of AppKit
        // breaking one of two required constraints at random.
        let textCap = textStack.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor, constant: -GroupsPaneLayout.contentTrailingInset)
        textCap.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: DeviceIconWellView.size),
            icon.heightAnchor.constraint(equalToConstant: DeviceIconWellView.size),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: GroupsPaneLayout.headerPadding),
            icon.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: GroupsPaneLayout.railFreeContentLeadingInset),
            bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: GroupsPaneLayout.headerPadding),

            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor,
                                               constant: GroupsPaneLayout.iconToTitleGap),
            textStack.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            textCap,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The well, the band and the text block, in `view`'s coordinates —
    /// what each page's header-parity test hooks report.
    public func frames(in view: NSView) -> (icon: NSRect, band: NSRect, textBlock: NSRect) {
        view.layoutSubtreeIfNeeded()
        return (icon.convert(icon.bounds, to: view),
                convert(bounds, to: view),
                textStack.convert(textStack.bounds, to: view))
    }
}
