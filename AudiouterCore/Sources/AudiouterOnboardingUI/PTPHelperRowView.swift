// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// The onboarding row for the privileged PTP helper daemon (T6,
/// AirPlayEngine/docs/ptp-helper-design.md §2.3) — the root `SMAppService`
/// launchd daemon that owns UDP 319/320 so AirPlay 2 speakers can share one
/// clock. Visually a sibling of ``PermissionRowView`` (same icon-tile + title
/// + detail + trailing-accessory shape, same card padding, reuses its
/// `onboardingRowActionButton`/`onboardingRowStatusLabel` helpers and
/// `IconTileView`), but driven by ``PTPHelperStatus`` rather than
/// ``PermissionStatus`` — this isn't a macOS TCC permission, it's a one-time
/// Login Items approval, with no "Denied" and no probing spinner.
///
/// Unlike the three permission rows, the detail text never changes with
/// status: it states the "why" once, and the trailing accessory alone tracks
/// `.notRegistered` → `.requiresApproval` → `.enabled` (or `.notFound`).
final class PTPHelperRowView: NSView {

    private let onOpenLoginItems: () -> Void

    private var iconTile: IconTileView!
    // "Speaker Sync", not "AirPlay 2 Clock Sync": onboarding copy says plain
    // "speakers", never "AirPlay" (spec §5.8, decision m) — and this name now
    // matches what the permission-lost banner calls it.
    private let titleLabel = NSTextField(labelWithString: "Speaker Sync")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    /// The swappable trailing area (status word ± "Open Login Items…" button).
    private let accessory = NSStackView()

    init(onOpenLoginItems: @escaping () -> Void) {
        self.onOpenLoginItems = onOpenLoginItems
        super.init(frame: .zero)
        build()
        update(status: .notRegistered)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Build

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        iconTile = IconTileView(symbolName: "clock.arrow.2.circlepath",
                                accessibility: "Speaker Sync",
                                color: Tokens.Color.permissionSpeakerSync)
        iconTile.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = Tokens.Font.bodyEmphasized
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.stringValue = "Your speakers play in perfect time by sharing one "
            + "clock, through a small helper. Approve it once in Login Items."
        detailLabel.font = Tokens.Font.caption
        detailLabel.textColor = Tokens.Color.secondaryLabel
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        accessory.orientation = .horizontal
        accessory.alignment = .centerY
        accessory.spacing = 8
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconTile)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(accessory)

        // Same centering trick as `PermissionRowView`: a zero-size guide spanning
        // title+detail so the icon tile and accessory track the whole two-line
        // block's center rather than drifting toward the top when detail wraps.
        let textBlockCenter = NSLayoutGuide()
        addLayoutGuide(textBlockCenter)

        let inset = PermissionRowView.horizontalInset
        let vInset = PermissionRowView.verticalInset
        let textTrailingInset = inset + PermissionRowView.accessoryColumnWidth + PermissionRowView.accessoryGap
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: vInset),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -textTrailingInset),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -textTrailingInset),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vInset),

            textBlockCenter.topAnchor.constraint(equalTo: titleLabel.topAnchor),
            textBlockCenter.bottomAnchor.constraint(equalTo: detailLabel.bottomAnchor),

            iconTile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            iconTile.centerYAnchor.constraint(equalTo: textBlockCenter.centerYAnchor),

            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            accessory.centerYAnchor.constraint(equalTo: textBlockCenter.centerYAnchor),
            accessory.leadingAnchor.constraint(greaterThanOrEqualTo: detailLabel.trailingAnchor,
                                               constant: PermissionRowView.accessoryGap),
        ])
    }

    override func layout() {
        super.layout()
        // See `PermissionRowView.layout()` — feeds the resolved width back into
        // `preferredMaxLayoutWidth` so the wrap height is computed correctly.
        let width = detailLabel.frame.width
        if width > 0, abs(detailLabel.preferredMaxLayoutWidth - width) > 0.5 {
            detailLabel.preferredMaxLayoutWidth = width
            detailLabel.invalidateIntrinsicContentSize()
        }
    }

    // MARK: State

    /// Repaint the trailing accessory for the current PTP helper status.
    func update(status: PTPHelperStatus) {
        lastStatus = status

        // The glyph keeps its tint in every status, same as the permission
        // rows — the "Enabled" chip alone carries the state.

        for v in accessory.arrangedSubviews { accessory.removeArrangedSubview(v); v.removeFromSuperview() }

        switch status {
        case .notRegistered:
            // `SetupModel.registerPTPHelper()` runs automatically at onboarding
            // load (registering shows no system prompt of its own — see
            // `PTPHelperManaging`), so there is nothing to tap here. This is
            // only ever seen transiently, or if registration itself failed.
            accessory.addArrangedSubview(onboardingRowStatusLabel("Setting Up…",
                                                     symbol: "ellipsis.circle",
                                                     tint: .secondaryLabelColor))
        case .requiresApproval:
            // Just the CTA, no separate status word: "Open Login Items…" is
            // already wider than the other rows' buttons, and the fixed
            // accessory column (sized for THEIR narrower status+button pairs —
            // see `PermissionRowView.accessoryColumnWidth`) has no room for
            // both here. Mirrors `PermissionRowView`'s `.unknown` case, which
            // is likewise button-only.
            accessory.addArrangedSubview(onboardingRowActionButton(
                title: "Open Login Items…", prominent: true,
                target: self, action: #selector(openLoginItemsTapped)))
        case .enabled:
            accessory.addArrangedSubview(onboardingRowStatusLabel("Enabled",
                                                     symbol: "checkmark.circle.fill",
                                                     tint: .systemGreen))
        case .notFound:
            // A packaging bug, not a user-fixable state — same posture as
            // `PermissionRowView`'s `.unsupported`: message only, no button.
            accessory.addArrangedSubview(onboardingRowStatusLabel("Not Available",
                                                     symbol: "xmark.circle",
                                                     tint: .secondaryLabelColor))
        }
    }

    // MARK: Actions

    @objc private func openLoginItemsTapped() { onOpenLoginItems() }

    // MARK: Test-support hooks

    private(set) var lastStatus: PTPHelperStatus = .notRegistered

    /// The titles of any buttons currently in the trailing accessory.
    var test_buttonTitles: [String] {
        accessory.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }
    }

    /// Invoke the "Open Login Items…" action as if the button were clicked.
    func test_tapOpenLoginItems() { openLoginItemsTapped() }
}
