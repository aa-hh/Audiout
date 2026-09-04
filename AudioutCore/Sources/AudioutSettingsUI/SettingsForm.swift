// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// Tiny layout kit shared by the Settings panes so every pane reads as one
/// consistent macOS form: a fixed-width column of `title · optional subtitle`
/// rows with the control right-aligned, standard insets, and a fitting height
/// the pane publishes as its own. Deliberately minimal — panes stay small, so
/// this is a few helpers, not a framework.
enum SettingsForm {

    /// The pane column inside the one fixed surface frame:
    /// `SurfaceLayout.width` minus the section sidebar. The pane host pins the
    /// pane's edges at REQUIRED priority and the pane holds this width at
    /// `.defaultHigh`, so a 1pt split divider can shave it without a conflict
    /// while headless callers (tests, `settings-snapshot`), which have no host
    /// to pin them, still get a definite width.
    static let contentWidth: CGFloat = SurfaceLayout.contentPaneWidth

    /// Standard left/right pane margin — shared by `paneView(rows:)` and
    /// `AudioSettingsViewController.loadView()`'s equivalent hand-rolled
    /// column, which used to retype this same number.
    static let horizontalPadding: CGFloat = 20
    /// Standard top/bottom pane margin — same sharing as `horizontalPadding`.
    static let verticalPadding: CGFloat = 18

    /// A leading-aligned label.
    static func label(_ string: String) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// A **live hint line** (Warm Signal spec §5.2 — "every consequential
    /// control self-explains with a live hint", the `Buffer: 120 ms — safe for
    /// Wi-Fi speakers` pattern): a wrapping caption in the secondary color the
    /// owning pane RE-WRITES whenever its control's value changes, so the
    /// consequence of the current value is always spelled out beneath it.
    /// Styling only — the update-on-change contract is the caller's.
    ///
    /// **`preferredMaxLayoutWidth` is set here, not left to a later layout
    /// pass.** A multi-line `NSTextField` with it unset has no width to wrap
    /// against, so its intrinsic content size reports its natural, UNWRAPPED
    /// single-line width — for a sentence-length hint, wider than a whole
    /// pane. That width is a compression-resistance *preference*, not a
    /// requirement, but it is enough to drag the fixed-`contentWidth` column
    /// (and, once embedded in the real tab window, the window itself) wider
    /// than the 460pt design — confirmed live: the Audio tab's window grew to
    /// 561pt, matching this exact label's unwrapped width, and calling
    /// `setContentSize` back down did not hold, because the label's own
    /// unresolved intrinsic size was what wanted 561 in the first place.
    /// `row(title:subtitle:control:)`'s labels dodge this because
    /// `RowContainerView.layout()` resolves their wrap width on every real
    /// layout pass; a full-bleed hint has no such container, so the value is
    /// pinned here instead — `contentWidth` minus the standard 20pt insets on
    /// each side (`SettingsForm.paneView(rows:)`, and `AudioSettingsViewController
    /// .loadView()`'s equivalent hand-rolled insets), the usable width every
    /// full-bleed line in a pane actually gets.
    static func hintLabel(_ string: String = "") -> NSTextField {
        let field = label(string)
        field.font = Tokens.Font.caption
        field.textColor = Tokens.Color.secondaryLabel
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = contentWidth - horizontalPadding * 2
        return field
    }

    /// A **section header** (roadmap 050 visual pass): semibold caption in the
    /// secondary color, so headers carry real weight separation from body-font
    /// row titles. One helper so every pane's headers match.
    static func sectionHeader(_ string: String) -> NSTextField {
        let field = label(string)
        field.font = Tokens.Font.captionEmphasized
        field.textColor = Tokens.Color.secondaryLabel
        return field
    }

    /// A **value readout** (`35%`, `0 ms` — roadmap 050 visual pass): monospaced
    /// digits on the panel's `well` fill, so live numbers read as instrument and
    /// rhyme with the Mixer. Fixed `width` so the row never shifts as the digit
    /// count changes.
    /// Styles the caller's own `field` (panes keep their stored label for the
    /// re-write-on-change contract) and returns the wrapping well.
    static func readoutWell(_ field: NSTextField, width: CGFloat) -> NSView {
        field.translatesAutoresizingMaskIntoConstraints = false
        // The app's ONE readout voice (`Tokens.Font.syncReadout`, shared with
        // the BT sync drawer's value field) — not a second hand-minted
        // monospaced size that drifts from it.
        field.font = Tokens.Font.syncReadout
        field.textColor = Tokens.Color.secondaryLabel
        field.alignment = .center

        let well = ReadoutWellView()
        well.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(field)
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: width),
            well.heightAnchor.constraint(equalToConstant: 20),
            field.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            field.centerYAnchor.constraint(equalTo: well.centerYAnchor),
        ])
        return well
    }

    /// One form row: a `title` (plus optional wrapping `subtitle` beneath it) on
    /// the leading edge, `control` pinned to the trailing edge and vertically
    /// centred on the title text. The returned view sizes its own height from its
    /// contents.
    static func row(title: String, subtitle: String? = nil, control: NSView) -> NSView {
        var built: NSTextField?
        if let subtitle {
            let sub = label(subtitle)
            sub.font = Tokens.Font.caption
            sub.textColor = Tokens.Color.secondaryLabel
            sub.lineBreakMode = .byWordWrapping
            sub.maximumNumberOfLines = 0
            built = sub
        }
        return row(title: title, subtitleLabel: built, control: control)
    }

    /// The same row, taking the caller's OWN subtitle label — so a pane can keep
    /// a stored `hintLabel` it re-writes on every value change and still have it
    /// sit as the row's subtitle, 2pt under the title.
    /// It resets the label's `preferredMaxLayoutWidth` because the row container
    /// owns that width and re-feeds it on every layout pass.
    static func row(title: String, subtitleLabel: NSTextField?, control: NSView) -> NSView {
        let titleLabel = label(title)
        titleLabel.font = Tokens.Font.body
        // Titles WRAP within the text column instead of truncating: the control
        // owns a fixed trailing column, so a long title (e.g. "Volume when
        // connecting a speaker") flows onto a second line rather than being cut
        // off mid-word. Same treatment the subtitle already gets; the container's
        // layout() feeds both a resolved preferredMaxLayoutWidth.
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 0
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)

        if let subtitleLabel {
            subtitleLabel.preferredMaxLayoutWidth = 0
            subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textStack.addArrangedSubview(subtitleLabel)
        }

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        let container = RowContainerView(titleLabel: titleLabel, subtitleLabel: subtitleLabel, controlView: control)
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

    /// Stack `rows` into a pane view: `width` wide (the shared `contentWidth`
    /// column unless a caller outside the surface frame says otherwise — About
    /// keeps its own window's width), standard 20/18pt insets, full-width rows.
    /// The caller assigns this to `NSViewController.view`; the width lets
    /// `view.fittingSize.height` drive `preferredContentSize`.
    static func paneView(rows: [NSView], width: CGFloat = contentWidth) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        // `.defaultHigh`, not required: the pane host's edge pins own the real
        // width once mounted, and a 1pt split divider must be able to shave
        // this without a constraint conflict.
        let widthConstraint = container.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            widthConstraint,
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontalPadding),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: verticalPadding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -verticalPadding),
        ])
        // Each row fills the column width (a vertical stack sizes arranged views
        // to their intrinsic width otherwise).
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return container
    }
}

/// The value-readout backing: the panel's inset `well` fill in a rounded rect,
/// drawn in `draw(_:)` (not a stamped layer color) so it re-resolves under the
/// current appearance with no manual bookkeeping — same reasoning as
/// `BorderedListView`.
private final class ReadoutWellView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Tokens.Color.well.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
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
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField?
    private let controlView: NSView

    init(titleLabel: NSTextField, subtitleLabel: NSTextField?, controlView: NSView) {
        self.titleLabel = titleLabel
        self.subtitleLabel = subtitleLabel
        self.controlView = controlView
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        // Feed BOTH the title and subtitle a resolved wrap width (bounds minus the
        // control column and gap) so wrapping labels compute their height from the
        // real text-column width, not an earlier too-narrow trial width.
        let available = bounds.width - controlView.frame.width - 16
        if available > 0 {
            titleLabel.preferredMaxLayoutWidth = available
            subtitleLabel?.preferredMaxLayoutWidth = available
        }
        super.layout()
    }
}
