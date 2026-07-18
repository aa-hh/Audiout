// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// The single-screen first-run onboarding content: a welcome header, the
/// reassurance copy that reframes the OS's "recording" language before any system
/// prompt fires, one row per permission (``PermissionRowView``), and a Done
/// button. A thin renderer over ``SetupModel`` — it holds no permission logic,
/// just binds the model's status to the rows and forwards button taps back to it.
///
/// Sibling in spirit to `SettingsRootViewController`: fixed content width, an
/// opaque appearance-adaptive `NSVisualEffectView` background, and `test_` hooks
/// so a headless harness/test can assert structure without a visible window.
@MainActor
public final class OnboardingViewController: NSViewController {

    /// Fixed content width. Everything (hero, reassurance, permission card,
    /// footer) derives its column width from this, so widening it here widens the
    /// whole screen — used to give the reassurance copy enough room that it no
    /// longer breaks a single word ("through.") onto its own last line, and to
    /// give the permission-row descriptions more breathing room.
    static let contentWidth: CGFloat = 500

    private let model: SetupModel
    private let onOpenSettings: (SystemSettingsPane) -> Void
    private let onDone: () -> Void

    private var audioRow: PermissionRowView!
    private var networkRow: PermissionRowView!
    private var remoteControlRow: PermissionRowView!

    /// Polls the silent Accessibility trust read while the window is open, so a
    /// grant made in System Settings shows up even if `AXIsProcessTrusted()` only
    /// flips true a moment after the user returns (a re-focus check alone can miss
    /// that). Stops once granted. If AX *never* flips true this process (the known
    /// "relaunch to apply" Accessibility behavior), polling can't help — that's what
    /// the AIRPLAY_DEBUG_SETUP log disambiguates.
    private var remoteControlPoll: Timer?

    public init(model: SetupModel,
                onOpenSettings: @escaping (SystemSettingsPane) -> Void,
                onDone: @escaping () -> Void) {
        self.model = model
        self.onOpenSettings = onOpenSettings
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    deinit { remoteControlPoll?.invalidate() }

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
                tileColor: .systemBlue,
                title: "System Audio",
                detail: "Send your Mac's sound to your speakers. Allowing plays "
                    + "a brief tone to confirm it's working.",
                allowButtonTitle: "Allow…"),
            onAllow: { [weak self] in self?.allowAudio() },
            onOpenSettings: { [weak self] in self?.onOpenSettings(.screenAndSystemAudioRecording) })

        networkRow = PermissionRowView(
            content: PermissionRowContent(
                symbolName: "wifi",
                tileColor: .systemIndigo,
                title: "Local Network",
                detail: "Find AirPlay speakers on your Wi-Fi.",
                allowButtonTitle: "Allow…"),
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
                tileColor: .systemPurple,
                title: "Remote Control",
                detail: "Let the speaker's buttons control playback.",
                allowButtonTitle: "Allow…"),
            onAllow: { [weak self] in self?.model.primeRemoteControl() },
            // Re-fire the macOS Accessibility PROMPT rather than deep-linking to the
            // pane: the prompt's own "Open System Settings" button is the one path
            // that scrolls to / highlights Audiouter in the list — a plain deep link
            // can't. (macOS gives no way to highlight an app row via URL.)
            onOpenSettings: { [weak self] in self?.model.primeRemoteControl() })

        let header = makeHeader()
        content.addArrangedSubview(header)
        content.addArrangedSubview(makeReassurance())
        content.addArrangedSubview(makePermissionCard())
        content.addArrangedSubview(makeFooter())
        // A touch more air below the hero than the uniform rhythm.
        content.setCustomSpacing(22, after: header)

        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
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

        card.addSubview(audioRow)
        card.addSubview(separator1)
        card.addSubview(networkRow)
        card.addSubview(separator2)
        card.addSubview(remoteControlRow)

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
            remoteControlRow.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            card.widthAnchor.constraint(equalToConstant: Self.contentWidth - 56),
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
        startRemoteControlPoll()
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
        // An app-icon-style rounded tile (accent fill, white glyph) reads as "an
        // app" far more than a bare glyph — the same first impression macOS's own
        // setup screens open with.
        let tile = IconTileView(symbolName: "airplayaudio",
                                tint: .controlAccentColor,
                                accessibility: "Audiouter",
                                side: 60, pointSize: 30, cornerRadius: 14)

        let title = NSTextField(labelWithString: "Welcome to Audiouter")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.alignment = .center

        let subtitle = NSTextField(labelWithString: "Play your Mac's sound on any AirPlay speaker.")
        subtitle.font = .systemFont(ofSize: NSFont.systemFontSize)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        let stack = NSStackView(views: [tile, title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(14, after: tile)
        return fullWidth(stack)
    }

    private func makeReassurance() -> NSView {
        // The one message this screen exists to land: reframe the OS's "recording"
        // label before the prompt does. Kept to two calm sentences.
        let text = NSTextField(wrappingLabelWithString:
            "Routing audio requires permission to access your Mac's audio stream. "
            + "Nothing is ever saved or recorded; it all streams right through.")
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.textColor = .labelColor
        text.alignment = .center
        text.translatesAutoresizingMaskIntoConstraints = false
        text.preferredMaxLayoutWidth = Self.contentWidth - 56
        return fullWidth(text)
    }

    private func makeFooter() -> NSView {
        // Names the app explicitly: macOS won't let us highlight the row, so the
        // next-best help is telling the user exactly what to look for in the list.
        let note = NSTextField(wrappingLabelWithString:
            "In System Settings, find Audiouter in the list and switch it on.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 2
        note.translatesAutoresizingMaskIntoConstraints = false
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.setContentHuggingPriority(.defaultLow, for: .horizontal)
        note.preferredMaxLayoutWidth = Self.contentWidth - 56 - 96

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
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth - 56).isActive = true
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
            container.widthAnchor.constraint(equalToConstant: Self.contentWidth - 56),
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

    @objc private func doneTapped() { onDone() }

    // MARK: Test-support hooks

    private var doneButton: NSButton?

    public var test_audioRowButtonTitles: [String] { _ = view; return audioRow.test_buttonTitles }
    public var test_networkRowButtonTitles: [String] { _ = view; return networkRow.test_buttonTitles }
    public var test_remoteControlRowButtonTitles: [String] { _ = view; return remoteControlRow.test_buttonTitles }

    /// Drive the model as the audio "Allow…" button would, then await the probe.
    public func test_allowAudio() async { _ = view; await model.requestAudioCapture() }

    /// Drive the model as the network "Allow…" button would, then await the probe.
    public func test_allowNetwork() async { _ = view; await model.primeLocalNetwork() }

    /// Drive the model as the remote-control "Allow…" button would.
    public func test_allowRemoteControl() { _ = view; model.primeRemoteControl() }

    /// Re-read model status into the rows (the `viewWillAppear` bind, headless).
    public func test_refresh() { _ = view; refresh() }

    /// Force the rows to specific statuses (for the snapshot harness, which wants
    /// to render every state without driving real probes). Bypasses the model.
    public func test_applyStatuses(audio: PermissionStatus,
                                   isProbingAudio: Bool,
                                   network: PermissionStatus,
                                   remoteControl: PermissionStatus) {
        _ = view
        audioRow.update(status: audio, isProbing: isProbingAudio)
        networkRow.update(status: network, isProbing: false)
        remoteControlRow.update(status: remoteControl, isProbing: false)
    }

    /// Invoke Done.
    public func test_tapDone() { _ = view; doneTapped() }

    /// The laid-out root view (for offscreen snapshot rendering).
    public var test_rootView: NSView {
        _ = view
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The three rows, for asserting status rendering directly.
    var test_audioRow: PermissionRowView { _ = view; return audioRow }
    var test_networkRow: PermissionRowView { _ = view; return networkRow }
    var test_remoteControlRow: PermissionRowView { _ = view; return remoteControlRow }
}
