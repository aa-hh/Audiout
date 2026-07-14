// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit

/// A tiny, non-interactive header row that labels the popover columns
/// ("Volume", "Enabled") aligned to the shared `PopoverColumnGrid`. Each label
/// is centered over its column by anchoring its horizontal center at a fixed
/// distance inward from the row's trailing edge, matching the grid's
/// trailing-anchored column layout.
///
/// Passing `nil` for a title omits that label entirely (it is never added), so
/// cards that lack an "Enabled" column can still show a "Volume" header aligned
/// to the same slider column.
public final class ColumnHeaderRow: NSView {

    /// Fixed height of the header row.
    public static let rowHeight: CGFloat = 22

    public init(volumeTitle: String? = "Volume", enabledTitle: String? = "Enabled") {
        super.init(frame: .zero)

        autoresizingMask = [.width]
        translatesAutoresizingMaskIntoConstraints = true

        heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true

        if let volumeTitle {
            let volumeLabel = Self.makeLabel(volumeTitle)
            addSubview(volumeLabel)
            NSLayoutConstraint.activate([
                volumeLabel.centerXAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -PopoverColumnGrid.sliderCenterFromTrailing),
                volumeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        if let enabledTitle {
            let enabledLabel = Self.makeLabel(enabledTitle)
            addSubview(enabledLabel)
            NSLayoutConstraint.activate([
                enabledLabel.centerXAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -PopoverColumnGrid.trailingControlCenterFromTrailing),
                enabledLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return label
    }
}
