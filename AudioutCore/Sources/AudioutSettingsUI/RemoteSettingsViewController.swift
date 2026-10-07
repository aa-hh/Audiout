// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// Settings › **Audiout Remote**: the "Allow control from iPhone on this
/// network" switch, the invitation to the iPhone app while it is on, and the
/// remembered iPhones. A build that does not carry the companion
/// (``isOffered`` false) never builds this section at all.
@MainActor
public final class RemoteSettingsViewController: NSViewController, SettingsReadoutProviding {

    private let settings: AppSettings
    private let openURL: (URL) -> Void
    private let remoteControlSwitch = NSSwitch()
    private let remoteControlOverrideNote = SettingsForm.label("")

    // Remembered iPhones (T24): the per-phone approval list — nil when the app
    // layer didn't inject the controller (headless constructions), in which
    // case the section never exists.
    private let approvals: CompanionApprovalController?
    private let phoneListHeading = SettingsPane.makeSectionTitle("Remembered iPhones")
    private var phoneCard: (container: NSView, box: GroupedSectionView, stack: NSStackView)?

    // The switch's card, and the invitation mounted in it directly under the
    // switch (or the override note) only while that switch is on.
    private var remoteCard: (container: NSView, box: GroupedSectionView, stack: NSStackView)?
    private var remoteControlRow: NSView?
    private var overrideNoteRow: NSView?
    private var remoteInviteRow: NSView?
    private var remoteInviteTile: RemoteInviteView?
    private let remoteInviteButton = NSButton()

    /// Resolved once at init (the env var, if any, can't change for the life of
    /// this process) — what the switch must honestly reflect: the EFFECTIVE
    /// state, not the raw persisted ``AppSettings/allowRemoteControl`` (FIX-C).
    /// When ``AppSettings/RemoteControlResolution/isForced`` the switch
    /// renders disabled and ``remoteControlOverrideNote`` explains why.
    private let remoteControlResolution: AppSettings.RemoteControlResolution

    /// Whether this build carries the iPhone companion. The app builds the
    /// section only when it does: an off switch reads as "you could turn this
    /// on", and until Audiout Remote is on the App Store there is nothing to
    /// turn on.
    public var isOffered: Bool { !remoteControlResolution.isUnoffered }

    /// Fired after "Allow control from iPhone on this network" changes and
    /// persists (T6), so the app layer can start/stop the companion server to
    /// match.
    public var onAllowRemoteControlChanged: (() -> Void)?

    var onReadoutChanged: (() -> Void)?

    /// - Parameters:
    ///   - settings: backs the switch; injectable so tests use a throwaway
    ///     `UserDefaults` suite, never `.standard`.
    ///   - environment: resolves ``AppSettings/RemoteControlResolution`` alongside
    ///     `settings` (the `AUDIOUT_COMPANION` dev knob); defaults to the real
    ///     process environment, injected as a fixed dictionary in tests.
    ///   - remoteAppIsOffered: whether this build carries the iPhone companion
    ///     at all; defaults to ``AppSettings/remoteAppIsOffered``.
    ///   - openURL: opens the invitation's page; injected as a recording
    ///     closure in tests so a test run never launches a browser.
    ///   - approvals: the per-phone approval model (T24) backing the
    ///     "Remembered iPhones" list; nil (the default) mounts no list at
    ///     all. The pane claims its `onChange` — a prompt answered while
    ///     the window is open must appear in the list live.
    public init(settings: AppSettings = AppSettings(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                remoteAppIsOffered: Bool = AppSettings.remoteAppIsOffered,
                openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
                approvals: CompanionApprovalController? = nil) {
        self.settings = settings
        self.openURL = openURL
        self.approvals = approvals
        self.remoteControlResolution = AppSettings.resolvedAllowRemoteControlWithSource(
            environment: environment, offered: remoteAppIsOffered, settings: settings)
        super.init(nibName: nil, bundle: nil)
        title = "Audiout Remote"
        // Claimed here, not in `loadView`, so the sidebar's readout follows a
        // prompt answered before this pane was ever shown.
        approvals?.onChange = { [weak self] in
            self?.rebuildPhoneList()
            self?.onReadoutChanged?()
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Readout

    /// The effective switch state: the forced value while an override is in
    /// force, the setting otherwise.
    private var allowsRemoteControl: Bool {
        remoteControlResolution.isForced ? remoteControlResolution.value : settings.allowRemoteControl
    }

    var readoutLines: [String] {
        guard allowsRemoteControl else { return ["Off"] }
        let phones = approvals?.approvals ?? []
        guard !phones.isEmpty else { return ["On · no iPhones yet"] }
        let allowed = phones.filter { $0.decision == .approved }.count
        switch allowed {
        case 0: return ["On · no iPhones allowed"]
        case 1: return ["On · 1 iPhone allowed"]
        default: return ["On · \(allowed) iPhones allowed"]
        }
    }

    var readoutGlyphTint: NSColor { Tokens.Color.labelCool }

    // MARK: Layout

    public override func loadView() {
        let (header, _) = SettingsPane.makeHeader(symbolName: "iphone", title: "Audiout Remote")

        // An `NSSwitch` like every other on/off row in Settings. Reflects the
        // EFFECTIVE state (`remoteControlResolution.value`), not the raw
        // persisted setting, and is disabled while an override is in force —
        // toggling it must be IMPOSSIBLE, not silently ineffective (FIX-C).
        remoteControlSwitch.state = remoteControlResolution.value ? .on : .off
        remoteControlSwitch.isEnabled = !remoteControlResolution.isForced
        remoteControlSwitch.target = self
        remoteControlSwitch.action = #selector(remoteControlToggled)
        remoteControlSwitch.setAccessibilityLabel("Allow control from iPhone on this network")
        let remoteControlRow = ListRowView(
            title: "Allow control from iPhone on this network",
            accessory: remoteControlSwitch,
            helpText: "Lets Audiout Remote on your iPhone control this Mac's speakers "
                + "and measure their timing from the room.")
        self.remoteControlRow = remoteControlRow

        // Same idiom as the Audio pane's `AIRPLAY_START_BUFFER_MS` override
        // note: a plain caption, wrapping, explicit `preferredMaxLayoutWidth`
        // (an unset one drags the fixed-width pane wider — see
        // `SettingsForm.hintLabel`'s doc comment). Only mounted when an
        // override is actually in force.
        remoteControlOverrideNote.stringValue =
            "A launch option is controlling this setting, so the switch can't change it."
        remoteControlOverrideNote.font = Tokens.Font.caption
        remoteControlOverrideNote.textColor = Tokens.Color.label2
        remoteControlOverrideNote.lineBreakMode = .byWordWrapping
        remoteControlOverrideNote.maximumNumberOfLines = 0
        remoteControlOverrideNote.preferredMaxLayoutWidth = SettingsPane.cardLaneWidth

        buildRemoteInviteRow()

        var cardRows: [NSView] = [remoteControlRow]
        if remoteControlResolution.isForced {
            let noteRow = SettingsPane.makeLaneRow(remoteControlOverrideNote)
            overrideNoteRow = noteRow
            cardRows.append(noteRow)
        }
        let card = SettingsPane.makeCard(rows: cardRows)
        remoteCard = card

        var content: [NSView] = [header, card.container]
        if approvals != nil {
            let phones = SettingsPane.makeCard(rows: [])
            phoneCard = phones
            content += [phoneListHeading, phones.container]
        }
        let page = SettingsForm.pageView(content: content)
        if let stack = page.subviews.first as? NSStackView, phoneCard != nil {
            stack.setCustomSpacing(GroupsPaneLayout.sectionGap, after: card.container)
            stack.setCustomSpacing(GroupsPaneLayout.labelToSectionGap, after: phoneListHeading)
        }
        view = page
        rebuildPhoneList()
        applyRemoteInviteVisibility()
    }

    /// "Get Audiout Remote for iPhone": the pane's own invitation, one row
    /// under the switch that enables it. The QR tile is the trailing
    /// control and the address is a stock push button under the title —
    /// every link in Settings is a button, and the button routes through the
    /// injected ``openURL`` so a test never launches a browser.
    private func buildRemoteInviteRow() {
        let title = SettingsForm.label("Get Audiout Remote for iPhone")
        title.font = Tokens.Font.body

        remoteInviteButton.title = "Open \(RemoteInviteView.pageAddress)"
        remoteInviteButton.bezelStyle = .rounded
        remoteInviteButton.controlSize = .small
        remoteInviteButton.target = self
        remoteInviteButton.action = #selector(remoteInviteLinkTapped)
        remoteInviteButton.setContentHuggingPriority(.required, for: .horizontal)

        // The button hugs its title; a bare stack row would stretch it across
        // the column.
        let buttonRow = NSStackView(views: [remoteInviteButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY

        let text = NSStackView(views: [title, buttonRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let tile = RemoteInviteView(tileSide: RemoteInviteView.settingsTileSide)
        remoteInviteTile = tile

        let invitation = NSStackView(views: [text, tile])
        invitation.orientation = .horizontal
        invitation.alignment = .top
        invitation.spacing = 16
        remoteInviteRow = SettingsPane.makeLaneRow(invitation)
    }

    /// Mount or unmount the invitation, and drop its QR once a phone is
    /// remembered. Hidden-in-place for the TILE (a stack collapses an arranged
    /// subview it is told to hide) and mounted/unmounted for the ROW.
    private func applyRemoteInviteVisibility() {
        guard isViewLoaded, let row = remoteInviteRow, let card = remoteCard else { return }
        remoteInviteTile?.isHidden = !(approvals?.approvals.isEmpty ?? true)
        let wanted = remoteControlSwitch.state == .on
        if wanted, row.superview == nil {
            let anchor = overrideNoteRow ?? remoteControlRow
            let after = card.stack.arrangedSubviews.firstIndex(where: { $0 === anchor })
            card.stack.insertArrangedSubview(row, at: (after ?? 0) + 1)
            // `removeFromSuperview` dropped the width pin.
            row.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        } else if !wanted, row.superview != nil {
            card.stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        card.box.rows = card.stack.arrangedSubviews.filter { !$0.isHidden }
    }

    @objc private func remoteInviteLinkTapped() {
        openURL(RemoteInviteView.pageURL)
        Analytics.capture("remote_invite:settings_link_opened")
    }

    /// Repopulate the "Remembered iPhones" card. Its title and card are hidden
    /// in place (not unmounted) while the list is empty, so a first phone
    /// appearing mid-session shows up live.
    private func rebuildPhoneList() {
        guard let approvals, isViewLoaded, let card = phoneCard else { return }
        for row in card.stack.arrangedSubviews {
            card.stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        let isEmpty = approvals.approvals.isEmpty
        phoneListHeading.isHidden = isEmpty
        card.container.isHidden = isEmpty
        // A house with a phone already on file still needs the address for a
        // second one, but not the code taking up the pane.
        applyRemoteInviteVisibility()
        for approval in approvals.approvals {
            let row = makePhoneRow(approval)
            card.stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: card.stack.widthAnchor).isActive = true
        }
        card.box.rows = card.stack.arrangedSubviews.filter { !$0.isHidden }
    }

    /// One remembered phone: name, Allowed/Denied, remove. The identity shown
    /// is only the phone's (already truncated) display name — the raw
    /// clientID never reaches UI; it rides the remove button's identifier.
    private func makePhoneRow(_ approval: CompanionApproval) -> ListRowView {
        let remove = NSButton()
        remove.isBordered = false
        remove.setButtonType(.momentaryChange)
        remove.imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        remove.image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove")?
            .withSymbolConfiguration(config)
        remove.contentTintColor = Tokens.Color.label2
        remove.target = self
        remove.action = #selector(revokePhoneTapped(_:))
        remove.identifier = NSUserInterfaceItemIdentifier(approval.clientID)
        remove.setAccessibilityLabel("Remove \(approval.lastKnownName)")
        return ListRowView(title: approval.lastKnownName,
                           caption: approval.decision == .approved ? "Allowed" : "Denied",
                           accessory: remove)
    }

    @objc private func revokePhoneTapped(_ sender: NSButton) {
        guard let clientID = sender.identifier?.rawValue else { return }
        // The controller persists, drops any live client with that identity,
        // and fires onChange — which rebuilds this list.
        approvals?.revoke(clientID: clientID)
    }

    @objc private func remoteControlToggled() {
        // Toggling while overridden must be IMPOSSIBLE, not silently
        // ineffective (FIX-C) — the switch is disabled so a real click
        // never reaches here, but a `test_` hook drives the action directly,
        // so the guard lives here too: bounce back to the effective value
        // rather than persisting a setting that can't take effect.
        guard !remoteControlResolution.isForced else {
            remoteControlSwitch.state = remoteControlResolution.value ? .on : .off
            return
        }
        settings.allowRemoteControl = remoteControlSwitch.state == .on
        // A Mac that refuses phones must not invite one.
        applyRemoteInviteVisibility()
        onAllowRemoteControlChanged?()
        onReadoutChanged?()
    }

    // MARK: Test-support hooks (Companion — T6, FIX-C)

    /// Whether the switch currently reads "on" — the EFFECTIVE state
    /// (`remoteControlResolution.value`), not necessarily the raw persisted
    /// `AppSettings.allowRemoteControl` (FIX-C: they can legitimately differ
    /// while an override is in force).
    public var test_allowRemoteControlIsOn: Bool {
        _ = view
        return remoteControlSwitch.state == .on
    }

    /// Whether the "Allow control from iPhone" row is in the pane at all.
    public var test_allowRemoteControlRowIsMounted: Bool {
        _ = view
        return remoteControlRow?.superview != nil
    }

    /// Whether the switch is currently clickable — `false` while
    /// `AUDIOUT_COMPANION` (or an explicit override) is in force (FIX-C).
    public var test_allowRemoteControlIsEnabled: Bool {
        _ = view
        return remoteControlSwitch.isEnabled
    }

    /// The override explanation line's text, or `nil` when no override is in
    /// force (it isn't mounted in the pane at all in that case) — FIX-C.
    public var test_allowRemoteControlOverrideNote: String? {
        _ = view
        return remoteControlResolution.isForced ? remoteControlOverrideNote.stringValue : nil
    }

    /// The override note's actual rendered text colour — pins that this is a
    /// plain caption, not the failure/warning red (it names a setting, not a
    /// problem).
    public var test_allowRemoteControlOverrideNoteTextColor: NSColor {
        _ = view
        return remoteControlOverrideNote.textColor ?? .clear
    }

    // MARK: Test-support hooks (Audiout Remote invitation)

    /// Whether the invitation row is in the pane at all. It is mounted, never
    /// hidden in place: a Mac that refuses phones should not invite one.
    public var test_remoteInviteRowIsMounted: Bool {
        _ = view
        return remoteInviteRow?.superview != nil
    }

    /// Whether the QR tile is on screen. It drops once a phone is remembered,
    /// leaving the row its title and button.
    public var test_remoteInviteQRIsVisible: Bool {
        _ = view
        return remoteInviteTile.map { !$0.isHidden } ?? false
    }

    public var test_remoteInviteButtonTitle: String? {
        _ = view
        return remoteInviteButton.title
    }

    /// Click "Open audiout.app/remote" the way a user would — through the
    /// injected `openURL`, so nothing launches a browser.
    public func test_tapRemoteInviteLink() {
        _ = view
        remoteInviteLinkTapped()
    }

    /// Drive the switch to `on`/`off` and run the same action a real click
    /// would. While overridden this is a no-op on the persisted setting (the
    /// action itself refuses, mirroring the disabled real control) — FIX-C.
    public func test_toggleAllowRemoteControl(_ on: Bool) {
        _ = view
        remoteControlSwitch.state = on ? .on : .off
        remoteControlToggled()
    }

    // MARK: Test-support hooks (Remembered iPhones — T24)

    /// The rendered phone rows as `(name, decision)` pairs, in list order —
    /// read from the controller the way the rebuild does, after forcing the
    /// same load/rebuild a real show performs.
    public var test_rememberedPhones: [(name: String, decision: String)] {
        _ = view
        return approvals?.approvals.map {
            ($0.lastKnownName, $0.decision == .approved ? "Allowed" : "Denied")
        } ?? []
    }

    /// Whether the list section is currently visible (it hides entirely when
    /// no phone was ever remembered).
    public var test_phoneListIsVisible: Bool {
        _ = view
        guard let card = phoneCard else { return false }
        return !card.container.isHidden && card.container.superview != nil
    }

    /// The number of rendered phone rows (proves the VIEW rebuilt, not just
    /// the model).
    public var test_phoneRowCount: Int {
        _ = view
        return phoneCard?.stack.arrangedSubviews.count ?? 0
    }

    /// The rendered Allowed/Denied caption's actual text colour at a row
    /// index — pins that a recorded decision is a plain word, not the
    /// failure/warning red, regardless of which way the decision went.
    public func test_phoneRowDecisionTextColor(at index: Int) -> NSColor? {
        _ = view
        guard let rows = phoneCard?.stack.arrangedSubviews, rows.indices.contains(index),
              let row = rows[index] as? ListRowView, let caption = row.caption else { return nil }
        func field(in view: NSView) -> NSTextField? {
            for sub in view.subviews {
                if let label = sub as? NSTextField, label.stringValue == caption { return label }
                if let found = field(in: sub) { return found }
            }
            return nil
        }
        return field(in: row)?.textColor
    }

    /// Revoke a phone through the same path its row's remove button runs.
    public func test_revokePhone(clientID: String) {
        _ = view
        approvals?.revoke(clientID: clientID)
    }
}
