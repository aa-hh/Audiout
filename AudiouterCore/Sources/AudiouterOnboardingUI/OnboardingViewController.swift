// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// Why the onboarding window is being presented right now — drives whether the
/// "a permission got turned off" banner renders.
///
/// `.firstRun` (the default, used by every existing call site) is the
/// original screen, unchanged. `.permissionLost` is used when the app finds
/// — via ``SetupModel/auditRequiredPermissions()`` on reactivate/wake — that
/// one of the three REQUIRED permissions (``RequiredPermission``; Remote
/// Control is deliberately excluded, it's an enhancement not a requirement)
/// was revoked after setup had already completed, and force-reopens this
/// window rather than silently degrading.
public enum OnboardingReason: Equatable, Sendable {
    case firstRun
    case permissionLost([RequiredPermission])
}

/// The single-screen first-run onboarding content: a welcome header, the
/// reassurance copy that reframes the OS's "recording" language before any system
/// prompt fires, one row per permission (``PermissionRowView``), and a Done
/// button. A thin renderer over ``SetupModel`` — it holds no permission logic,
/// just binds the model's status to the rows and forwards button taps back to it.
///
/// Sibling in spirit to `SettingsRootViewController`: fixed content width, an
/// opaque appearance-adaptive background (the Warm Signal canvas —
/// `WarmCanvasView`, spec §5.8), and `test_` hooks so a headless harness/test
/// can assert structure without a visible window.
@MainActor
public final class OnboardingViewController: NSViewController {

    /// Fixed content width. Everything (hero, reassurance, permission card,
    /// footer) derives its column width from this, so widening it here widens the
    /// whole screen — used to give the reassurance copy enough room that it no
    /// longer breaks a single word ("through.") onto its own last line, and to
    /// give the permission-row descriptions more breathing room.
    static let contentWidth: CGFloat = 500
    /// `contentWidth` minus the standard outer margin — the width every
    /// full-bleed section (card, reassurance text, footer row) actually gets.
    /// Named once instead of retyping `contentWidth - 56` at every site.
    static let columnWidth: CGFloat = contentWidth - 56

    private let model: SetupModel
    private let reason: OnboardingReason
    private let onOpenSettings: (SystemSettingsPane) -> Void
    private let onDone: () -> Void

    private var audioRow: PermissionRowView!
    private var networkRow: PermissionRowView!
    private var remoteControlRow: PermissionRowView!
    private var ptpHelperRow: PTPHelperRowView!

    /// The `.permissionLost` banner, if this presentation built one (nil for
    /// `.firstRun`). Held for test inspection.
    private var permissionBannerView: NSView?
    private var permissionBannerLabel: NSTextField?

    /// Polls the silent Accessibility trust read while the window is open, so a
    /// grant made in System Settings shows up even if `AXIsProcessTrusted()` only
    /// flips true a moment after the user returns (a re-focus check alone can miss
    /// that). Stops once granted. If AX *never* flips true this process (the known
    /// "relaunch to apply" Accessibility behavior), polling can't help — that's what
    /// the AIRPLAY_DEBUG_SETUP log disambiguates.
    private var remoteControlPoll: Timer?

    /// Polls the PTP helper's `SMAppService.status` while the window is open, so
    /// approving it in Login Items (System Settings, not this window) is picked
    /// up without needing a re-focus. Stops once `.enabled`. Same rationale as
    /// `remoteControlPoll` — see T6/PROGRESS.md for the Developer-ID gating that
    /// keeps this from ever reaching `.enabled` on an ad-hoc-signed build.
    private var ptpHelperPoll: Timer?

    public init(model: SetupModel,
                reason: OnboardingReason = .firstRun,
                onOpenSettings: @escaping (SystemSettingsPane) -> Void,
                onDone: @escaping () -> Void) {
        self.model = model
        self.reason = reason
        self.onOpenSettings = onOpenSettings
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    deinit { remoteControlPoll?.invalidate(); ptpHelperPoll?.invalidate() }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Build

    public override func loadView() {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        content.edgeInsets = NSEdgeInsets(top: 30, left: 28, bottom: 22, right: 28)

        audioRow = PermissionRowView(
            content: PermissionRowContent(
                symbolName: "waveform",
                title: "System Audio",
                // Outcome-framed reassurance FIRST (spec §5.8 house voice: the
                // OS prompt will say "screen recording", so defuse it here),
                // then the honest heads-up about the confirmation tone the
                // probe really does play (AudioCapturePermissionProbe —
                // "the UI warns first" is part of that contract).
                detail: "macOS calls this screen recording. Your audio flows "
                    + "straight to your speakers — nothing is stored or sent. "
                    + "Allowing plays a brief tone to confirm it's working.",
                allowButtonTitle: "Allow…",
                iconColor: Tokens.Color.permissionSystemAudio),
            onAllow: { [weak self] in self?.allowAudio() },
            onOpenSettings: { [weak self] in self?.onOpenSettings(.screenAndSystemAudioRecording) })

        networkRow = PermissionRowView(
            content: PermissionRowContent(
                symbolName: "wifi",
                title: "Local Network",
                // Plain "speakers", never "AirPlay", in onboarding copy (spec
                // §5.8, decision m). U+2011 non-breaking hyphen keeps "Wi‑Fi"
                // from wrapping to an orphan "Fi."
                detail: "Find the speakers on your Wi\u{2011}Fi so they show up "
                    + "in your list.",
                allowButtonTitle: "Allow…",
                iconColor: Tokens.Color.permissionLocalNetwork),
            onAllow: { [weak self] in
                Task { @MainActor in
                    await self?.model.primeLocalNetwork()
                    // The browse may have surfaced the system prompt; pull the
                    // window back to the front like the audio grant does.
                    NSApp.activate(ignoringOtherApps: true)
                    self?.view.window?.makeKeyAndOrderFront(nil)
                }
            },
            onOpenSettings: { [weak self] in self?.onOpenSettings(.localNetwork) })

        // Primed ahead of a not-yet-shipped feature (speaker-side transport
        // controls simulating Mac media keys) — see SetupModel's
        // RemoteControlPriming doc comment. Included now so the grant is already
        // in place once that feature merges, instead of a cold THIRD prompt later.
        remoteControlRow = PermissionRowView(
            content: PermissionRowContent(
                symbolName: "accessibility",
                title: "Remote Control",
                // Outcome first, then name the OS's own label for the
                // permission so the System Settings pane is recognisable.
                detail: "Press play or pause on a speaker and your Mac follows. "
                    + "macOS calls this Accessibility.",
                allowButtonTitle: "Allow…",
                iconColor: Tokens.Color.permissionRemoteControl),
            onAllow: { [weak self] in self?.model.primeRemoteControl() },
            // Re-fire the macOS Accessibility PROMPT rather than deep-linking to the
            // pane: the prompt's own "Open System Settings" button is the one path
            // that scrolls to / highlights Audiouter in the list — a plain deep link
            // can't. (macOS gives no way to highlight an app row via URL.)
            onOpenSettings: { [weak self] in self?.model.primeRemoteControl() })

        // T6: the privileged PTP helper daemon (SMAppService, not a TCC
        // permission) — its own row type/status (see PTPHelperRowView's doc
        // comment) rather than a fourth PermissionStatus case.
        ptpHelperRow = PTPHelperRowView(
            onOpenLoginItems: { [weak self] in self?.model.openPTPHelperLoginItems() })

        // `.permissionLost` gets a banner ABOVE the header; `.firstRun` renders
        // exactly as before (no banner at all).
        if case .permissionLost(let unmet) = reason {
            let banner = makeBanner(unmet: unmet)
            permissionBannerView = banner
            content.addArrangedSubview(banner)
            content.setCustomSpacing(18, after: banner)
        }

        let header = makeHeader()
        content.addArrangedSubview(header)
        content.addArrangedSubview(makeReassurance())
        content.addArrangedSubview(makePermissionCard())
        content.addArrangedSubview(makeFooter())
        // A touch more air below the hero than the uniform rhythm.
        content.setCustomSpacing(22, after: header)

        // The Warm Signal canvas (spec §5.8: "warm canvas + permission
        // tiles"), replacing the old opaque `NSVisualEffectView`
        // window-background material. `WarmCanvasView` is always fully
        // opaque and self-handles Reduce Transparency / Increase Contrast
        // (flat `canvas` fill, no gradient/grain) — see its doc comment.
        let background = WarmCanvasView()
        background.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])
        view = background
    }

    /// The three permission rows wrapped in a single grouped inset card (the
    /// System Settings list look): one rounded, hairline-bordered container with
    /// a text-inset separator between each row.
    private func makePermissionCard() -> NSView {
        let card = RoundedContainerView()

        func textInsetSeparator() -> NSBox {
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            return separator
        }
        let separator1 = textInsetSeparator()
        let separator2 = textInsetSeparator()
        let separator3 = textInsetSeparator()

        card.addSubview(audioRow)
        card.addSubview(separator1)
        card.addSubview(networkRow)
        card.addSubview(separator2)
        card.addSubview(remoteControlRow)
        card.addSubview(separator3)
        card.addSubview(ptpHelperRow)

        // Separators start after the icon tile, aligned with the row text —
        // exactly how System Settings insets its grouped-row dividers.
        let textInset = PermissionRowView.horizontalInset + IconTileView.side + 12
        NSLayoutConstraint.activate([
            audioRow.topAnchor.constraint(equalTo: card.topAnchor),
            audioRow.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            audioRow.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            separator1.topAnchor.constraint(equalTo: audioRow.bottomAnchor),
            separator1.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: textInset),
            separator1.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            networkRow.topAnchor.constraint(equalTo: separator1.bottomAnchor),
            networkRow.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            networkRow.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            separator2.topAnchor.constraint(equalTo: networkRow.bottomAnchor),
            separator2.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: textInset),
            separator2.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            remoteControlRow.topAnchor.constraint(equalTo: separator2.bottomAnchor),
            remoteControlRow.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            remoteControlRow.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            separator3.topAnchor.constraint(equalTo: remoteControlRow.bottomAnchor),
            separator3.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: textInset),
            separator3.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            ptpHelperRow.topAnchor.constraint(equalTo: separator3.bottomAnchor),
            ptpHelperRow.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            ptpHelperRow.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            ptpHelperRow.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            card.widthAnchor.constraint(equalToConstant: Self.columnWidth),
        ])
        return card
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        // Bind as soon as the view exists (not only in `viewWillAppear`, which a
        // headless test/harness never triggers) so a model status change — the
        // async audio probe resolving, the network prime — repaints the rows.
        model.onChange = { [weak self] in self?.refresh() }
        refresh()
        // Reflect real current state up front — surfaces an Accessibility grant the
        // user already had (silent check), without prompting anything untouched.
        refreshStatuses()
        // Register the PTP helper daemon once, at load (T6): unlike the three
        // probes above, registering shows no system prompt of its own, so it's
        // safe to run unconditionally rather than waiting for a tap — see
        // `SetupModel.registerPTPHelper()`'s doc comment.
        model.registerPTPHelper()
        startRemoteControlPoll()
        startPTPHelperPoll()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    /// Poll the silent Accessibility read every ~1.5 s until it's granted, so a
    /// toggle flipped in System Settings lands on the row even without a re-focus.
    private func startRemoteControlPoll() {
        guard remoteControlPoll == nil else { return }
        remoteControlPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.model.refreshRemoteControlStatus()
                if self.model.remoteControlStatus == .granted { timer.invalidate(); self.remoteControlPoll = nil }
            }
        }
    }

    /// Poll the PTP helper's `SMAppService.status` every ~1.5 s until it's
    /// `.enabled`, so approving it in Login Items lands on the row without a
    /// re-focus. Same shape as `startRemoteControlPoll()`.
    private func startPTPHelperPoll() {
        guard ptpHelperPoll == nil else { return }
        ptpHelperPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.model.refreshPTPHelperStatus()
                if self.model.ptpHelperStatus == .enabled { timer.invalidate(); self.ptpHelperPoll = nil }
            }
        }
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        // Re-attach on every open (a reused window) and re-read current status.
        model.onChange = { [weak self] in self?.refresh() }
        refresh()
        refreshStatuses()
    }

    /// Re-derive every permission's live status (see ``SetupModel/refreshStatuses()``).
    /// Called on load, on appear, and — via the window controller — whenever the app
    /// regains focus, so returning from System Settings updates the rows to reality.
    /// Safe to call freely: it never springs a prompt on an un-engaged permission.
    public func refreshStatuses() {
        Task { @MainActor in await model.refreshStatuses() }
    }

    // MARK: Sections

    private func makeHeader() -> NSView {
        // Show the app's REAL icon (not a generic glyph) — a stronger first
        // impression for a paid product. Fetched from the running app so it
        // tracks whatever icon ships, with no hardcoded asset name to go stale.
        let tile = NSImageView()
        tile.image = NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
        tile.imageScaling = .scaleProportionallyUpOrDown
        tile.setAccessibilityLabel("Audiouter")
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 60),
            tile.heightAnchor.constraint(equalToConstant: 60),
        ])

        let title = NSTextField(labelWithString: "Welcome to Audiouter")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.alignment = .center

        // Plain "speakers", never "AirPlay" (spec §5.8, decision m).
        let subtitle = NSTextField(labelWithString: "Play your Mac's sound on the speakers around your home.")
        subtitle.font = Tokens.Font.body
        subtitle.textColor = Tokens.Color.secondaryLabel
        subtitle.alignment = .center

        let stack = NSStackView(views: [tile, title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(14, after: tile)
        return fullWidth(stack)
    }

    /// The `.permissionLost` banner: a stock system-orange inset card (reusing
    /// ``RoundedContainerView``, the same grouped-container look the
    /// permission card below uses) with a warning glyph and copy naming the
    /// specific permission(s) that got turned off. System colors only — no
    /// custom drawing beyond the shared rounded-rect container this screen
    /// already uses.
    private func makeBanner(unmet: [RequiredPermission]) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                             accessibilityDescription: "Warning")
        icon.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        icon.contentTintColor = Tokens.Color.warning
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let text = NSTextField(wrappingLabelWithString: Self.bannerText(for: unmet))
        text.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        text.textColor = Tokens.Color.label
        text.translatesAutoresizingMaskIntoConstraints = false
        text.preferredMaxLayoutWidth = Self.columnWidth - 32 - 16
        permissionBannerLabel = text

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let card = RoundedContainerView(fill: Tokens.Color.warning.withAlphaComponent(0.14),
                                        border: Tokens.Color.warning.withAlphaComponent(0.4))
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            card.widthAnchor.constraint(equalToConstant: Self.columnWidth),
        ])
        return card
    }

    /// The specific unmet permission(s), named plainly, so the user knows
    /// exactly what to look for below without hunting through all three rows.
    private static func bannerText(for unmet: [RequiredPermission]) -> String {
        let names = unmet.map(displayName(for:))
        let joined: String
        switch names.count {
        case 0: joined = "a permission"   // shouldn't happen — reason is only built with a non-empty set
        case 1: joined = names[0]
        case 2: joined = "\(names[0]) and \(names[1])"
        default: joined = names.dropLast().joined(separator: ", ") + ", and \(names[names.count - 1])"
        }
        let plural = names.count > 1 ? "permissions" : "permission"
        return "Audiouter needs the \(joined) \(plural), currently turned off. "
            + "Re-enable it below so the app can keep working."
    }

    private static func displayName(for permission: RequiredPermission) -> String {
        switch permission {
        case .audioCapture: return "System Audio"
        case .localNetwork: return "Local Network"
        // Matches the row's on-screen title (was "PTP helper" — jargon the
        // user never sees anywhere else; spec §5.8's plain-speakers voice).
        case .ptpHelper:    return "Speaker Sync"
        }
    }

    private func makeReassurance() -> NSView {
        // Outcome-framed and calm (spec §5.8 house voice): what saying yes
        // gets you, and how little it asks. The "recording" reframe now lives
        // on the System Audio row itself, right where that prompt fires.
        let text = NSTextField(wrappingLabelWithString:
            "A few one-time permissions let your sound reach every speaker "
            + "in the house. Each one below is a single click.")
        text.font = Tokens.Font.body
        text.textColor = Tokens.Color.label
        text.alignment = .center
        text.translatesAutoresizingMaskIntoConstraints = false
        text.preferredMaxLayoutWidth = Self.columnWidth
        return fullWidth(text)
    }

    private func makeFooter() -> NSView {
        // Names the app explicitly: macOS won't let us highlight the row, so the
        // next-best help is telling the user exactly what to look for in the list.
        let note = NSTextField(wrappingLabelWithString:
            "In System Settings, find Audiouter in the list and switch it on.")
        note.font = Tokens.Font.caption
        note.textColor = Tokens.Color.secondaryLabel
        note.maximumNumberOfLines = 2
        note.translatesAutoresizingMaskIntoConstraints = false
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.setContentHuggingPriority(.defaultLow, for: .horizontal)
        note.preferredMaxLayoutWidth = Self.columnWidth - 96

        // Done is a plain (gray) button, deliberately quieter than the accent
        // "Allow…" CTAs, and NOT the Return-default — we don't want an accidental
        // Return to skip granting. The prominent buttons are the ones to click.
        // `.large` gives the finish action a little more presence than the note.
        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.controlSize = .large
        done.setContentHuggingPriority(.required, for: .horizontal)
        done.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.doneButton = done

        // Horizontal stack (.fill) stretches the low-hugging note to take the slack
        // and pins the high-hugging Done to the trailing edge — note left, Done right.
        let row = NSStackView(views: [note, done])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true
        return row
    }

    /// Wrap a view in a full-content-width container so vertical-stack children
    /// all span the column (and centered content actually centers).
    private func fullWidth(_ inner: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.columnWidth),
            inner.topAnchor.constraint(equalTo: container.topAnchor),
            inner.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            inner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            inner.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
            inner.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    // MARK: State

    private func refresh() {
        audioRow.update(status: model.audioStatus, isProbing: model.isProbingAudio)
        networkRow.update(status: model.localNetworkStatus, isProbing: false)
        remoteControlRow.update(status: model.remoteControlStatus, isProbing: false)
        ptpHelperRow.update(status: model.ptpHelperStatus)
        refreshPermissionLostBanner()
    }

    /// Keep the `.permissionLost` banner honest as the user re-grants: re-word it
    /// to the still-missing subset, and HIDE it once every permission it warned
    /// about is satisfied. Without this the "…currently turned off" warning stayed
    /// up even after the row it named flipped to Allowed. Scoped to the permissions
    /// the banner ORIGINALLY flagged (from `reason`), so granting them clears it
    /// and it never expands to nag about something it didn't open for. No-op for
    /// `.firstRun` — there's no banner (`permissionBannerView` is nil).
    private func refreshPermissionLostBanner() {
        guard let banner = permissionBannerView,
              case .permissionLost(let originallyUnmet) = reason else { return }
        let notGranted = model.requiredPermissionsNotGranted()
        let stillMissing = originallyUnmet.filter { notGranted.contains($0) }
        if !stillMissing.isEmpty {
            permissionBannerLabel?.stringValue = Self.bannerText(for: stillMissing)
        }
        let shouldHide = stillMissing.isEmpty
        guard banner.isHidden != shouldHide else { return }   // only act on a change
        banner.isHidden = shouldHide

        // Re-fit the window so hiding the banner doesn't leave a gap, keeping the
        // title bar fixed (window origin is bottom-left, so shrink from the bottom).
        view.layoutSubtreeIfNeeded()
        guard let window = view.window else { return }
        let target = view.fittingSize
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target
        window.setFrame(frame, display: true, animate: true)
    }

    private func allowAudio() {
        Task { @MainActor in
            await model.requestAudioCapture()
            // The audio grant runs the system TCC prompt, which appears in front
            // of us and (accessory app) makes us resign active while the user
            // answers. When the probe returns, pull our window back to the front
            // and make the app active so the user lands right back on setup
            // instead of staring at whatever was behind it.
            NSApp.activate(ignoringOtherApps: true)
            view.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Finish onboarding — unless a REQUIRED permission
    /// (``SetupModel/requiredPermissionsNotGranted()``) hasn't actually been
    /// granted, in which case ask first rather than silently completing setup
    /// with a gap the user won't discover until something fails later with no
    /// path back. Setup stays "guidance, not a gate"
    /// (``SetupModel/complete()``) — Continue Anyway still finishes; this only
    /// stops the SILENT case.
    @objc private func doneTapped() {
        let notGranted = model.requiredPermissionsNotGranted()
        guard !notGranted.isEmpty else { onDone(); return }
        confirmFinishDespiteUngrantedPermissions(notGranted) { [weak self] continueAnyway in
            if continueAnyway { self?.onDone() }
        }
    }

    /// Ask "continue anyway?" as a sheet on the window when one exists (the
    /// real app always has one here — the Done button is only visible inside
    /// an on-screen window). A headless test has no window to host a sheet
    /// (its completion handler needs the app's run loop, which XCTest doesn't
    /// pump), so it stashes the pending confirmation for
    /// ``test_resolvePendingConfirmation(continueAnyway:)`` to resolve instead
    /// of calling `completion` synchronously.
    private func confirmFinishDespiteUngrantedPermissions(
        _ notGranted: [RequiredPermission],
        completion: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Continue without every permission?"
        alert.informativeText = Self.confirmationText(for: notGranted)
        // "Go Back" first (and thus default/Return-bound) so an accidental
        // Return doesn't skip the very permissions this dialog is warning
        // about — same reasoning as Done itself not being Return-default.
        alert.addButton(withTitle: "Go Back")
        alert.addButton(withTitle: "Continue Anyway")
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertSecondButtonReturn)
            }
        } else {
            test_pendingConfirmation = (notGranted, completion)
        }
    }

    /// The confirmation body, naming the specific ungranted permission(s) —
    /// same "name it plainly" approach as ``bannerText(for:)``.
    private static func confirmationText(for notGranted: [RequiredPermission]) -> String {
        let names = notGranted.map(displayName(for:))
        let joined: String
        switch names.count {
        case 0: joined = "a permission"   // shouldn't happen — only called with a non-empty set
        case 1: joined = names[0]
        case 2: joined = "\(names[0]) and \(names[1])"
        default: joined = names.dropLast().joined(separator: ", ") + ", and \(names[names.count - 1])"
        }
        let plural = names.count > 1 ? "permissions" : "permission"
        return "You haven't granted the \(joined) \(plural). Audiouter may not work "
            + "correctly until it's turned on in System Settings."
    }

    // MARK: Test-support hooks

    private var doneButton: NSButton?

    /// Set (headless only) while `doneTapped()` is waiting on a "continue
    /// anyway?" confirmation that has no real window to host a sheet on.
    /// `nil` once resolved, or whenever Done didn't need to ask at all.
    public private(set) var test_pendingConfirmationPermissions: [RequiredPermission]?
    private var test_pendingConfirmation: (permissions: [RequiredPermission], completion: (Bool) -> Void)? {
        didSet { test_pendingConfirmationPermissions = test_pendingConfirmation?.permissions }
    }

    /// Resolve a pending headless "continue anyway?" confirmation — `true`
    /// simulates clicking Continue Anyway (finishes), `false` simulates Go
    /// Back (does nothing further; Done can be tapped again later). A no-op
    /// if nothing is pending.
    public func test_resolvePendingConfirmation(continueAnyway: Bool) {
        guard let pending = test_pendingConfirmation else { return }
        test_pendingConfirmation = nil
        pending.completion(continueAnyway)
    }

    public var test_audioRowButtonTitles: [String] { _ = view; return audioRow.test_buttonTitles }
    public var test_networkRowButtonTitles: [String] { _ = view; return networkRow.test_buttonTitles }
    public var test_remoteControlRowButtonTitles: [String] { _ = view; return remoteControlRow.test_buttonTitles }
    public var test_ptpHelperRowButtonTitles: [String] { _ = view; return ptpHelperRow.test_buttonTitles }

    /// Drive the model as the audio "Allow…" button would, then await the probe.
    public func test_allowAudio() async { _ = view; await model.requestAudioCapture() }

    /// Drive the model as the network "Allow…" button would, then await the probe.
    public func test_allowNetwork() async { _ = view; await model.primeLocalNetwork() }

    /// Drive the model as the remote-control "Allow…" button would.
    public func test_allowRemoteControl() { _ = view; model.primeRemoteControl() }

    /// Drive the model as the load-time PTP helper registration would.
    public func test_registerPTPHelper() { _ = view; model.registerPTPHelper() }

    /// Re-read model status into the rows (the `viewWillAppear` bind, headless).
    public func test_refresh() { _ = view; refresh() }

    /// Force the rows to specific statuses (for the snapshot harness, which wants
    /// to render every state without driving real probes). Bypasses the model.
    public func test_applyStatuses(audio: PermissionStatus,
                                   isProbingAudio: Bool,
                                   network: PermissionStatus,
                                   remoteControl: PermissionStatus,
                                   ptpHelper: PTPHelperStatus = .enabled) {
        _ = view
        audioRow.update(status: audio, isProbing: isProbingAudio)
        networkRow.update(status: network, isProbing: false)
        remoteControlRow.update(status: remoteControl, isProbing: false)
        ptpHelperRow.update(status: ptpHelper)
    }

    /// Invoke Done. Finishes immediately if every required permission is
    /// granted; otherwise leaves a pending confirmation
    /// (``test_pendingConfirmationPermissions``) rather than finishing.
    public func test_tapDone() { _ = view; doneTapped() }

    /// The laid-out root view (for offscreen snapshot rendering).
    public var test_rootView: NSView {
        _ = view
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The three permission rows, for asserting status rendering directly.
    var test_audioRow: PermissionRowView { _ = view; return audioRow }
    var test_networkRow: PermissionRowView { _ = view; return networkRow }
    var test_remoteControlRow: PermissionRowView { _ = view; return remoteControlRow }
    /// The PTP helper row (its own type — see ``PTPHelperRowView``).
    var test_ptpHelperRow: PTPHelperRowView { _ = view; return ptpHelperRow }

    /// Whether this presentation rendered the `.permissionLost` banner.
    public var test_showsPermissionLostBanner: Bool { _ = view; return permissionBannerView != nil }

    /// Whether the `.permissionLost` banner is currently VISIBLE (built AND not
    /// hidden) — distinct from ``test_showsPermissionLostBanner`` (was one ever
    /// built) so a test can assert the banner CLEARS once its permission is
    /// granted.
    public var test_permissionLostBannerIsVisible: Bool {
        _ = view
        guard let banner = permissionBannerView else { return false }
        return !banner.isHidden
    }

    /// The banner's copy, if shown (nil for `.firstRun`).
    public var test_permissionLostBannerText: String? { _ = view; return permissionBannerLabel?.stringValue }
}
