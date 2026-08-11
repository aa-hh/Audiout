// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// Why the onboarding window is being presented right now — drives whether the
/// header carries the "a permission got turned off" message.
///
/// `.firstRun` (the default, used by every existing call site) is the plain
/// welcome. `.permissionLost` is used when the app finds — via
/// ``SetupModel/auditRequiredPermissions()`` on reactivate/wake — that one of
/// the three REQUIRED permissions (``RequiredPermission``; Remote Control is
/// deliberately excluded, it's an enhancement not a requirement) was revoked
/// after setup had already completed, and force-reopens this window rather than
/// silently degrading.
public enum OnboardingReason: Equatable, Sendable {
    case firstRun
    case permissionLost([RequiredPermission])
}

/// The Setup window's content: a two-pane screen. LEFT, a fixed column with the
/// hero, the five permission cards asked ONE AT A TIME (``SetupCardView``), and
/// the Done footer. RIGHT, a native-drawn miniature of whatever surface the
/// active card's Allow button is about to raise (``DemoPaneView``).
///
/// A thin renderer over two Core models and holding no permission logic of its
/// own: ``SetupModel`` owns the statuses and the probes, ``SetupFlowModel``
/// owns the sequence, the skip set, the Done gate and the Allow decision table.
/// This class turns those into views and turns clicks back into calls.
///
/// **Setup is a GATE** (owner decision 2026-08-11, reversing "guidance, not a
/// gate"): Done is ABSENT from the view hierarchy — not disabled, not
/// alpha-hidden — until every required permission verifies, and there is no
/// "continue anyway" escape. The ✕ close remains the one ungated exit, and it
/// deliberately doesn't persist completion, so the flow returns next launch.
@MainActor
public final class OnboardingViewController: NSViewController {

    /// Fixed content size. The window is fixed at exactly this (see
    /// ``OnboardingWindowController/present()``), so no step's copy can resize
    /// the window under the user mid-flow — the slack lands in the gap above
    /// the footer instead.
    static let contentWidth: CGFloat = 820
    static let contentHeight: CGFloat = 560
    /// The left column's fixed width; the demo pane takes the rest.
    ///
    /// Sized to the longest earned title ("Audiouter can now hear your Mac's
    /// sound") plus its checkmark: a collapsed strip truncates below about 410,
    /// and the titles are reviewed copy, so the column fits the words rather
    /// than the words fitting the column. The demo's fixed surface still clears
    /// its margins in what's left (`DemoPaneView.surfaceSize`).
    static let leftPaneWidth: CGFloat = 420
    /// Outer margin inside each pane.
    static let paneMargin: CGFloat = 22
    /// Gap from the card stack down to the Done footer — Done belongs to the
    /// stack it completes, not to the bottom of the window.
    static let cardsToFooterGap: CGFloat = 24

    private let model: SetupModel
    private let flow: SetupFlowModel
    private let reason: OnboardingReason
    private let onOpenSettings: (SystemSettingsPane) -> Void
    private let onDone: () -> Void

    /// Called immediately before ANY System Settings destination is opened (a
    /// privacy pane or Login Items). The window controller uses it to drop this
    /// window's `.floating` level, so System Settings can actually come to the
    /// front — see that class for the amended decision.
    public var onWillOpenSystemSettings: (() -> Void)?

    private var cards: [SetupStep: SetupCardView] = [:]
    private var cardStack: NSStackView!
    private var demoPane: DemoPaneView!
    private var subtitleLabel: NSTextField!
    private var footer: NSView!
    private var doneButton: NSButton?

    /// The step whose Allow is in flight — the spinner, and the UI half of the
    /// single-flight rule the flow model enforces.
    private var allowInFlight: SetupStep?

    /// The most recent Allow's work, so a headless press can await exactly what
    /// the real click started (`test_pressCard`) instead of re-implementing it.
    private var allowTask: Task<Void, Never>?

    /// Set by a failed Done verification: the card to snap back to. It overrides
    /// the flow model's own active step, which is anchored to where this
    /// presentation STARTED and so can't reach back to a step that was fine
    /// when the window opened and has since been revoked.
    private var snapBackStep: SetupStep?

    /// Steps already completed at the last repaint — the transition edge the
    /// grant choreography fires on (a repaint that changes nothing must not
    /// re-run it).
    private var completedAtLastRefresh: Set<SetupStep> = []

    /// Polls the silent Accessibility trust read while the window is open, so a
    /// grant made in System Settings shows up even if `AXIsProcessTrusted()` only
    /// flips true a moment after the user returns (a re-focus check alone can miss
    /// that). Stops once granted.
    private var remoteControlPoll: Timer?

    /// Polls the PTP helper's `SMAppService.status` while the window is open, so
    /// approving it in Login Items (System Settings, not this window) is picked
    /// up without needing a re-focus. Stops once `.enabled`.
    private var ptpHelperPoll: Timer?

    public init(model: SetupModel,
                reason: OnboardingReason = .firstRun,
                onOpenSettings: @escaping (SystemSettingsPane) -> Void,
                onDone: @escaping () -> Void) {
        self.model = model
        // Built HERE, at presentation time and before anything can be granted:
        // the flow's start position is fixed at init from the first unmet
        // required step, and building it after a grant would read as a
        // re-entry and open on a different card.
        self.flow = SetupFlowModel(setup: model)
        self.reason = reason
        self.onOpenSettings = onOpenSettings
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    deinit { remoteControlPoll?.invalidate(); ptpHelperPoll?.invalidate() }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Build

    public override func loadView() {
        let background = WarmCanvasView()
        background.translatesAutoresizingMaskIntoConstraints = false

        let leftPane = makeLeftPane()
        let rightPane = makeRightPane()
        background.addSubview(leftPane)
        background.addSubview(rightPane)

        NSLayoutConstraint.activate([
            background.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            background.heightAnchor.constraint(equalToConstant: Self.contentHeight),

            leftPane.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            leftPane.topAnchor.constraint(equalTo: background.topAnchor),
            leftPane.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            leftPane.widthAnchor.constraint(equalToConstant: Self.leftPaneWidth),

            rightPane.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            rightPane.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            rightPane.topAnchor.constraint(equalTo: background.topAnchor),
            rightPane.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        view = background
    }

    /// Hero, card stack, footer — the column that carries every word and every
    /// control.
    private func makeLeftPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()
        cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 6
        cardStack.distribution = .fill
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        for step in SetupFlowModel.steps {
            let card = makeCard(for: step)
            cards[step] = card
            cardStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        }

        footer = makeFooter()

        pane.addSubview(header)
        pane.addSubview(cardStack)
        pane.addSubview(footer)

        let margin = Self.paneMargin
        // Done rides DIRECTLY under the card stack, not at the pane's bottom edge.
        // The window is a FIXED size, so a footer pinned down there strands the
        // complete state's collapsed stack at the top with the button ~250 pt below
        // it across an empty band. The pane's lower slack falls BELOW the footer.
        let cardsToFooter = footer.topAnchor.constraint(equalTo: cardStack.bottomAnchor,
                                                       constant: Self.cardsToFooterGap)
        // Weakest constraint in the column: a step whose copy wraps one line
        // further than expected bends the bottom margin rather than resizing the
        // window under the user or breaking a required constraint.
        let footerAboveBottom = footer.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor,
                                                              constant: -20)
        footerAboveBottom.priority = .defaultLow

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: margin),
            header.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -margin),
            header.topAnchor.constraint(equalTo: pane.topAnchor, constant: margin),

            cardStack.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: margin),
            cardStack.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -margin),
            cardStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            cardsToFooter,

            footer.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: margin),
            footer.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -margin),
            footerAboveBottom,
        ])
        return pane
    }

    /// The demo, centred on a subtly elevated surface.
    private func makeRightPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false
        demoPane = DemoPaneView()
        pane.addSubview(demoPane)
        NSLayoutConstraint.activate([
            demoPane.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: Self.paneMargin),
            demoPane.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -Self.paneMargin),
            demoPane.topAnchor.constraint(equalTo: pane.topAnchor, constant: Self.paneMargin),
            demoPane.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -Self.paneMargin),
        ])
        return pane
    }

    private func makeHeader() -> NSView {
        // Show the app's REAL icon (not a generic glyph) — a stronger first
        // impression for a paid product. Fetched from the running app so it
        // tracks whatever icon ships, with no hardcoded asset name to go stale.
        let tile = NSImageView()
        tile.image = NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
        tile.imageScaling = .scaleProportionallyUpOrDown
        tile.setAccessibilityLabel("Audiouter")
        tile.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Welcome to Audiouter")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false

        // Plain "speakers", never "AirPlay" (spec §5.8, decision m). This one
        // label is also where a `.permissionLost` re-entry says what went off —
        // no separate banner view, so the layout is identical either way.
        subtitleLabel = NSTextField(wrappingLabelWithString: "")
        subtitleLabel.font = Tokens.Font.body
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.preferredMaxLayoutWidth = Self.leftPaneWidth - Self.paneMargin * 2

        let stack = NSStackView(views: [tile, title, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(12, after: tile)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 52),
            tile.heightAnchor.constraint(equalToConstant: 52),
            subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return stack
    }

    /// The Done area. The button itself is NOT built here — it only enters the
    /// hierarchy once the gate opens (see ``refreshDone()``).
    private func makeFooter() -> NSView {
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        // Reserve the button's height so the card stack doesn't shift when Done
        // appears — the gate is about the BUTTON's absence, not about the
        // layout jumping.
        footer.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return footer
    }

    private func makeCard(for step: SetupStep) -> SetupCardView {
        SetupCardView(content: Self.content(for: step),
                      onAllow: { [weak self] in self?.allowTapped(step) },
                      onSkip: { [weak self] in self?.skipTapped(step) },
                      onOpenSettings: { [weak self] in self?.settingsLinkTapped(step) })
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        // Bind as soon as the view exists (not only in `viewWillAppear`, which a
        // headless test/harness never triggers) so a model status change — the
        // async audio probe resolving, the Bluetooth prompt being answered —
        // repaints the cards.
        model.onChange = { [weak self] in self?.refresh() }
        // Register the PTP helper daemon once, at load: unlike the probes,
        // registering shows no system prompt of its own, so it's safe to run
        // unconditionally rather than waiting for a tap.
        model.registerPTPHelper()
        // Reflect real current state up front — without this the Bluetooth card
        // paints undetermined even when the grant is already in place
        // (`bluetoothStatus` starts `.unknown`). Silent: never springs a prompt.
        refreshStatuses()
        refresh(animated: false)
        startRemoteControlPoll()
        startPTPHelperPoll()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        // Re-attach on every open (a reused window) and re-read current status.
        model.onChange = { [weak self] in self?.refresh() }
        refreshStatuses()
        refresh(animated: false)
    }

    /// Re-derive every permission's live status (see ``SetupModel/refreshStatuses()``).
    /// Called on load, on appear, and — via the window controller — whenever the app
    /// regains focus, so returning from System Settings updates the cards to reality.
    /// Safe to call freely: it never springs a prompt on an un-engaged permission.
    public func refreshStatuses() {
        Task { @MainActor in await model.refreshStatuses() }
    }

    /// Poll the silent Accessibility read every ~1.5 s until it's granted, so a
    /// toggle flipped in System Settings lands on the card even without a re-focus.
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
    /// `.enabled`, so approving it in Login Items lands on the card without a
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

    // MARK: Card copy

    /// The per-step card copy. The DETAIL strings are reused verbatim from the
    /// pre-sequential rows: each one is TCC-framing tested (it defuses the OS's
    /// own wording before that prompt appears), so they are not re-written for
    /// the new layout.
    static func content(for step: SetupStep) -> SetupCardContent {
        switch step {
        case .audio:
            return SetupCardContent(
                step: step,
                symbolName: "waveform",
                iconColor: Tokens.Color.permissionSystemAudio,
                activeTitle: "Let Audiouter hear your Mac's sound",
                completedTitle: "Audiouter can now hear your Mac's sound",
                // Outcome-framed reassurance FIRST (spec §5.8 house voice: the
                // OS prompt will say "screen recording", so defuse it here),
                // then the honest heads-up about the confirmation tone the
                // probe really does play.
                detail: "macOS calls this screen recording. Your audio flows "
                    + "straight to your speakers — nothing is stored or sent. "
                    + "Allowing plays a brief tone to confirm it's working.",
                allowTitle: "Allow…",
                isSkippable: false)
        case .localNetwork:
            return SetupCardContent(
                step: step,
                symbolName: "wifi",
                iconColor: Tokens.Color.permissionLocalNetwork,
                activeTitle: "Find the speakers on your Wi\u{2011}Fi",
                // Never used: Local Network's completed title is the found
                // count (`SetupCardContent.title(for:foundSpeakers:)`), because
                // a checkmark for a permission macOS refuses to confirm would
                // be a claim we can't back.
                completedTitle: "Found your speakers",
                // Plain "speakers", never "AirPlay", in onboarding copy (spec
                // §5.8, decision m). U+2011 non-breaking hyphen keeps "Wi‑Fi"
                // from wrapping to an orphan "Fi."
                detail: "Find the speakers on your Wi\u{2011}Fi so they show up "
                    + "in your list.",
                allowTitle: "Allow…",
                isSkippable: false)
        case .bluetooth:
            return SetupCardContent(
                step: step,
                symbolName: "dot.radiowaves.right",
                // razor: Bluetooth SHARES Remote Control's hue rather than
                // minting a fifth `Tokens.Color.permission*` token, which would
                // need authored light/dark/Increase-Contrast values and a
                // measured contrast rationale from the palette owner. The two
                // cards are never adjacent, so the repeat doesn't read as a
                // mistake. Upgrade path: add `permissionBluetooth` to `Tokens`
                // with those three variants and swap this one line.
                iconColor: Tokens.Color.permissionRemoteControl,
                activeTitle: "Let Audiouter use Bluetooth speakers",
                completedTitle: "Audiouter can now use Bluetooth speakers",
                detail: "Keep a Bluetooth speaker in your list while it's "
                    + "switched off, and reconnect it from Audiouter. Without "
                    + "this you can still use one that's already connected.",
                allowTitle: "Allow…",
                isSkippable: true)
        case .speakerSync:
            return SetupCardContent(
                step: step,
                symbolName: "clock.arrow.2.circlepath",
                iconColor: Tokens.Color.permissionSpeakerSync,
                activeTitle: "Keep your speakers in perfect time",
                completedTitle: "Your speakers stay in perfect time",
                detail: "Your speakers play in perfect time by sharing one "
                    + "clock, through a small helper. Approve it once in Login Items.",
                allowTitle: "Open Login Items…",
                isSkippable: false)
        case .remoteControl:
            return SetupCardContent(
                step: step,
                symbolName: "accessibility",
                iconColor: Tokens.Color.permissionRemoteControl,
                activeTitle: "Control playback with your volume keys",
                completedTitle: "Your volume keys control Audiouter",
                // Outcome first, then name the OS's own label for the
                // permission so the System Settings pane is recognisable.
                detail: "Use your volume keys while Audiouter is your output "
                    + "device, and press play or pause on a speaker to control "
                    + "your Mac. macOS calls this Accessibility.",
                allowTitle: "Allow…",
                isSkippable: true)
        }
    }

    // MARK: State

    /// The card that is expanded right now. Normally the flow model's own
    /// answer; a failed Done verification overrides it (see ``snapBackStep``).
    private var displayedActiveStep: SetupStep? {
        if let snapBackStep, !flow.isComplete(snapBackStep) { return snapBackStep }
        return flow.activeStep
    }

    /// Repaint everything from the two models.
    ///
    /// - Parameter animated: `nil` derives it — the grant choreography runs on
    ///   the edge where a step becomes complete, and only on a window that is
    ///   really on screen with Reduce Motion off. Callers pass `false` for the
    ///   initial build and `true`/`canAnimate` for a UI-initiated change (a skip,
    ///   a snap-back) that isn't a grant.
    private func refresh(animated: Bool? = nil) {
        let completedNow = Set(SetupFlowModel.steps.filter { flow.isComplete($0) })
        let newlyCompleted = completedNow.subtracting(completedAtLastRefresh)
        let shouldAnimate = animated ?? (!newlyCompleted.isEmpty && canAnimate)
        completedAtLastRefresh = completedNow

        // A grant lands while the user is looking at System Settings or a TCC
        // prompt — pull ourselves back to the front FIRST, so the rest of the
        // choreography happens somewhere the user can see it.
        if !newlyCompleted.isEmpty { returnToFront() }
        if let snapBackStep, flow.isComplete(snapBackStep) { self.snapBackStep = nil }

        let active = displayedActiveStep
        for step in SetupFlowModel.steps {
            cards[step]?.apply(state(for: step, active: active),
                               // No browse ever runs on an ungated OS (macOS
                               // 14), so there is no count to report there —
                               // nil, where zero means a real browse that saw
                               // nothing.
                               foundSpeakers: model.isLocalNetworkGated ? flow.localNetworkFoundSpeakers : nil,
                               isProbing: isPrompting(step),
                               offersSettingsFallback: offersSettingsFallback(step),
                               hint: hint(for: step),
                               statusCaption: statusCaption(for: step),
                               primaryTitle: primaryTitle(for: step),
                               offersSettingsLink: offersSettingsLink(step),
                               animated: shouldAnimate)
        }
        demoPane.show(step: active, mode: demoMode(for: active),
                      animated: shouldAnimate)
        refreshDone()
        refreshHeaderMessage()
    }

    private func state(for step: SetupStep, active: SetupStep?) -> SetupCardState {
        if step == active { return .active }
        guard flow.isComplete(step) else {
            return flow.skippedSteps.contains(step) ? .skipped : .pending
        }
        // Auto-passed, not granted: this OS has no such permission to give, so
        // the strip says why instead of claiming a grant nobody made.
        if step == .audio, model.audioStatus == .unsupported {
            return .autoPassed(note: "Requires macOS 14.2 or later")
        }
        return .completed
    }

    /// Whether this step's Allow has spent its prompt, so the next click is the
    /// Settings deep link instead (the two-mode Allow). Kept in lockstep with
    /// ``SetupFlowModel/allow(_:)``'s own preflight — the button must not
    /// promise a prompt the model will refuse to fire.
    private func offersSettingsFallback(_ step: SetupStep) -> Bool {
        switch step {
        case .audio:         return model.audioStatus == .denied
        // A PROVEN refusal spends this prompt like any other (the browse would
        // only be refused again). Short of that it is NOT two-mode: the card's
        // prompt IS the browse, so an empty browse keeps its retry and offers
        // the pane beside it (`offersSettingsLink`).
        case .localNetwork:  return model.localNetworkStatus == .denied
        case .bluetooth:     return model.bluetoothStatus == .denied
        // Login Items is Speaker Sync's only mode — its Allow is already the
        // Settings button, so there is no second mode to switch into.
        case .speakerSync:   return false
        // Remote Control's "Open Settings…" re-fires the Accessibility PROMPT
        // (the prompt's own button is the only path that highlights this app in
        // the list); the label changes, the destination doesn't.
        case .remoteControl: return model.remoteControlStatus == .requested
        }
    }

    /// The one extra line the flow ever adds to a card: Local Network can NEVER
    /// prove a denial (no status API), so a browse that found nothing must ask
    /// for a speaker rather than accuse the user of refusing.
    private func hint(for step: SetupStep) -> String? {
        guard localNetworkCameUpEmpty(step) else { return nil }
        return "No speakers found yet. Turn one on, then try again."
    }

    /// Local Network asked and the browse found nothing. The hint tells the user
    /// to turn a speaker on and try again, so SOMETHING has to re-browse — which
    /// is why this card keeps a primary retry instead of flipping to Settings.
    private func localNetworkCameUpEmpty(_ step: SetupStep) -> Bool {
        step == .localNetwork && step == displayedActiveStep
            && model.localNetworkStatus == .requested
    }

    /// The Allow slot's label when it isn't the plain first ask. Only Local
    /// Network has one: same click, same browse, honestly named.
    private func primaryTitle(for step: SetupStep) -> String? {
        localNetworkCameUpEmpty(step) ? "Try Again" : nil
    }

    /// Whether the card shows the demoted "Open Settings…" beside its primary.
    /// Local Network only, and only where that pane exists at all — macOS 14
    /// has no Local Network privacy gate, so there is nowhere to send anyone.
    private func offersSettingsLink(_ step: SetupStep) -> Bool {
        localNetworkCameUpEmpty(step) && model.isLocalNetworkGated
    }

    /// Whether this card is waiting on a prompt or probe it fired — the spinner,
    /// and the inert card-level click target. Bluetooth's wait is the model's to
    /// report: its prompt answers on a callback, so the click returns long before
    /// the user has answered anything.
    private func isPrompting(_ step: SetupStep) -> Bool {
        if allowInFlight == step { return true }
        return step == .bluetooth && model.isPrimingBluetooth
    }

    /// What the card says while it waits. Two phases, and the difference is the
    /// point: ``waitingCaption`` points at the system dialog the user still has
    /// to answer (up to a minute for Local Network — a bare spinner that long
    /// reads as a hang), while the verifying captions cover our own brief
    /// wrap-up AFTER the answer landed. A refusal has no wrap-up: it goes
    /// straight to the denied card. Speaker Sync has nothing to name — its
    /// Login Items approval is a poll, not a prompt of ours.
    private func statusCaption(for step: SetupStep) -> String? {
        if step == .localNetwork {
            switch model.localNetworkPhase {
            case .idle: return isPrompting(step) ? Self.waitingCaption : nil
            case .waitingForAnswer: return Self.waitingCaption
            case .verifying: return "Checking your network\u{2026}"
            }
        }
        guard isPrompting(step) else { return nil }
        switch step {
        case .audio, .bluetooth, .remoteControl: return Self.waitingCaption
        case .speakerSync, .localNetwork: return nil
        }
    }

    /// The one line every unanswered system dialog gets. It names what the user
    /// is waiting ON — themselves, in another window — rather than implying the
    /// app is busy.
    static let waitingCaption = "Waiting for your answer\u{2026}"

    private func demoMode(for step: SetupStep?) -> DemoMode {
        guard let step else { return .settled }
        // Speaker Sync has no prompt at all — Login Items is the only surface
        // it ever shows the user.
        if step == .speakerSync { return .settings }
        // Local Network's prompt is spent once a browse has run, so the pane it
        // now offers is the surface worth showing — even though the primary
        // button stays a retry.
        if offersSettingsLink(step) { return .settings }
        return offersSettingsFallback(step) ? .settings : .prompt
    }

    /// Whether the choreography may run: a real, on-screen window with Reduce
    /// Motion off. Everywhere else every beat is an instant swap, so steady
    /// states (first render, snapshots, headless tests, an occluded window)
    /// render settled.
    private var canAnimate: Bool {
        guard !HeadlessRuntime.isActive,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window = view.window, window.isVisible else { return false }
        return window.occlusionState.contains(.visible)
    }

    /// Pull the window back in front of whatever the user was just in (a TCC
    /// prompt, System Settings) and restore keyboard focus.
    private func returnToFront() {
        // Counted before the headless bail-out: activation itself is invisible
        // to a headless test, but WHETHER to activate is what Local Network's
        // rule decides (see `allowTapped`).
        test_returnToFrontCount += 1
        guard !HeadlessRuntime.isActive else { return }
        NSApp?.activate(ignoringOtherApps: true)
        view.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: The gate

    /// Add or remove Done. It is ABSENT until every required permission
    /// verifies — never present-but-disabled, which reads as "the app is
    /// broken" rather than "there is one more thing to do".
    private func refreshDone() {
        let shouldExist = flow.isDoneAvailable
        if shouldExist, doneButton == nil {
            // The finale CTA (owner copy 2026-08-11): closing setup is what
            // starts the deferred audio engine, so the button names that —
            // and it wears GOLD, the payoff's accent, where the everyday Allow
            // wears the system accent. Ink is measured off the resolved fill
            // (see `ProminentButton.picksInkFromFill`).
            let done = ProminentButton(title: "Start listening", target: self,
                                       action: #selector(doneTapped),
                                       fill: Tokens.Color.gold, picksInkFromFill: true)
            // Constrained directly below (no stack view to do it for us): left
            // on, AutoLayout synthesises size from the zero frame and the
            // button renders as nothing at all.
            done.translatesAutoresizingMaskIntoConstraints = false
            done.controlSize = .large
            // Once Done exists it IS the Return-default; until then Return
            // belongs to the one live Allow (below).
            done.keyEquivalent = "\r"
            doneButton = done
            footer.addSubview(done)
            NSLayoutConstraint.activate([
                done.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
                done.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            ])
            if canAnimate {
                done.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    done.animator().alphaValue = 1
                }
            }
        } else if !shouldExist, let done = doneButton {
            done.removeFromSuperview()
            doneButton = nil
        }
        let active = displayedActiveStep
        for step in SetupFlowModel.steps {
            cards[step]?.setAllowIsReturnDefault(!shouldExist && step == active)
        }
    }

    /// Done re-verifies before finishing: something may have been revoked while
    /// the window sat open. A failure snaps the flow back to the card that came
    /// up short — no sheet, no "continue anyway".
    @objc private func doneTapped() {
        Task { @MainActor in await verifyThenFinish() }
    }

    private func verifyThenFinish() async {
        switch await flow.verifyForDone() {
        case .complete:
            onDone()
        case .unmet(let step):
            snapBackStep = step
            refresh(animated: canAnimate)
        }
    }

    // MARK: Header message

    /// Which message the header subtitle is carrying — tracked as a KIND so the
    /// banner hooks report what is showing instead of inferring it from copy (a
    /// string-compare predicate would call any non-welcome line a warning).
    private enum HeaderMessage { case welcome, complete, permissionLost }
    private var headerMessage: HeaderMessage = .welcome

    /// Pick the ONE header message, in precedence order: the `.permissionLost`
    /// warning while any permission it ORIGINALLY flagged is still missing
    /// (re-worded to the still-missing subset, never expanded to nag about
    /// something it didn't open for) → the completion line while the Done gate
    /// is open → the plain welcome.
    private func refreshHeaderMessage() {
        if case .permissionLost(let originallyUnmet) = reason {
            let notGranted = model.requiredPermissionsNotGranted()
            let stillMissing = originallyUnmet.filter { notGranted.contains($0) }
            if !stillMissing.isEmpty {
                headerMessage = .permissionLost
                subtitleLabel.stringValue = Self.permissionLostText(for: stillMissing)
                subtitleLabel.textColor = Tokens.Color.warning
                return
            }
        }
        if flow.isDoneAvailable {
            headerMessage = .complete
            subtitleLabel.stringValue = Self.completeSubtitle
        } else {
            headerMessage = .welcome
            subtitleLabel.stringValue = Self.welcomeSubtitle
        }
        subtitleLabel.textColor = Tokens.Color.secondaryLabel
    }

    static let welcomeSubtitle = "Play your Mac's sound on the speakers around your home. "
        + "A few one-time permissions, one at a time."

    /// The payoff line once the gate is open (owner copy 2026-08-11 — no
    /// found-speaker count; the owner rejected a number here). Secondary tone,
    /// not gold: 13 pt body text needs 4.5:1, which light gold (3.6:1 on the
    /// light canvas) cannot give — the gold in this moment belongs to the demo
    /// pane's finale and the CTA.
    static let completeSubtitle = "Your Mac's sound can reach every room."

    /// The specific unmet permission(s), named plainly, so the user knows
    /// exactly what to look for below.
    static func permissionLostText(for unmet: [RequiredPermission]) -> String {
        let names = unmet.map(displayName(for:))
        let joined: String
        switch names.count {
        case 0: joined = "a permission"   // shouldn't happen — reason is only built with a non-empty set
        case 1: joined = names[0]
        case 2: joined = "\(names[0]) and \(names[1])"
        default: joined = names.dropLast().joined(separator: ", ") + ", and \(names[names.count - 1])"
        }
        // The PRONOUN has to agree too: with two permissions named, "Re-enable
        // it below" is a broken sentence on screen.
        let isPlural = names.count > 1
        return "Audiouter needs the \(joined) \(isPlural ? "permissions" : "permission"), "
            + "currently turned off. Re-enable \(isPlural ? "them" : "it") below "
            + "so the app can keep working."
    }

    static func displayName(for permission: RequiredPermission) -> String {
        switch permission {
        case .audioCapture: return "System Audio"
        case .localNetwork: return "Local Network"
        // Matches the card's on-screen title (was "PTP helper" — jargon the
        // user never sees anywhere else; spec §5.8's plain-speakers voice).
        case .ptpHelper:    return "Speaker Sync"
        }
    }

    // MARK: Actions

    private func allowTapped(_ step: SetupStep) {
        guard allowInFlight == nil else { return }   // single-flight, UI half
        allowInFlight = step
        refresh(animated: false)                     // spinner in, instantly
        allowTask = Task { @MainActor in
            let result = await flow.allow(step)
            allowInFlight = nil
            applyAllowResult(step, result)
            refresh()
        }
    }

    /// What one Allow click does with its answer — re-front, or open the place
    /// the model named. Shared with ``test_tapAllow(_:)`` so the test hook can
    /// never drift from the real click's rules.
    private func applyAllowResult(_ step: SetupStep, _ result: SetupAllowResult) {
        switch result.destination {
        case .none:
            // A prompt ran (or was refused): the user came back from a system
            // dialog, so take the front again. EXCEPT an UNDECIDED Local
            // Network prime: its window can expire while the real permission
            // alert is still on screen, and reactivating there steals focus
            // mid-dialog and leaves that alert dimmed and unclickable. Both
            // real answers — granted OR denied — mean the dialog was answered,
            // so both take the front back; only `.requested` (nothing answered)
            // leaves it be, and the next natural activation brings the window
            // forward anyway.
            if step != .localNetwork || model.localNetworkStatus != .requested {
                returnToFront()
            }
        case .settingsPane(let pane):
            onWillOpenSystemSettings?()
            onOpenSettings(pane)
        case .loginItems:
            onWillOpenSystemSettings?()
            model.openPTPHelperLoginItems()
        }
    }

    /// The demoted "Open Settings…" beside Local Network's retry. It opens the
    /// pane directly — there is no prompt left to fire, and the flow model's
    /// Allow deliberately re-browses instead of routing here.
    private func settingsLinkTapped(_ step: SetupStep) {
        guard step == .localNetwork else { return }
        onWillOpenSystemSettings?()
        onOpenSettings(.localNetwork)
    }

    private func skipTapped(_ step: SetupStep) {
        flow.skip(step)
        // Skipping is UI-initiated, and `SetupFlowModel` has no change hook of
        // its own, so the repaint is this call site's job.
        refresh(animated: canAnimate)
    }

    // MARK: Test-support hooks

    /// How many times the flow decided to pull the window back to the front.
    /// Local Network's rule — never on a bare probe timeout, because the system
    /// dialog may still be open — has no other headless signal.
    public private(set) var test_returnToFrontCount = 0

    /// The expanded card's step (nil once every step is done or skipped).
    public var test_activeStep: SetupStep? { _ = view; return displayedActiveStep }

    /// Which cards are collapsed — the sequencing invariant: exactly one open.
    public var test_expandedSteps: [SetupStep] {
        _ = view
        return SetupFlowModel.steps.filter { cards[$0]?.test_isBodyCollapsed == false }
    }

    /// The on-screen title of a card, so a test can pin the imperative →
    /// capability rewrite.
    public func test_title(of step: SetupStep) -> String { _ = view; return cards[step]?.test_title ?? "" }

    /// The buttons a card currently offers, in order.
    public func test_buttonTitles(of step: SetupStep) -> [String] {
        _ = view
        return cards[step]?.test_buttonTitles ?? []
    }

    /// Whether a card is showing its earned checkmark.
    public func test_hasCheckmark(_ step: SetupStep) -> Bool { _ = view; return cards[step]?.test_hasCheckmark ?? false }

    /// The note a card shows in place of a checkmark (auto-passed steps).
    public func test_note(of step: SetupStep) -> String? { _ = view; return cards[step]?.test_note }

    /// The extra honest line under a card's copy, if any.
    public func test_hint(of step: SetupStep) -> String? { _ = view; return cards[step]?.test_hint }

    /// Whether a card is showing the in-flight wait (spinner + caption).
    public func test_isProbing(_ step: SetupStep) -> Bool { _ = view; return cards[step]?.test_isProbing ?? false }

    /// What that wait currently SAYS — nil when no wait is on screen.
    public func test_statusCaption(of step: SetupStep) -> String? {
        _ = view
        return cards[step]?.test_statusCaption
    }

    /// Whether a card is showing the LOCK — a step the flow hasn't reached.
    public func test_isLocked(_ step: SetupStep) -> Bool { _ = view; return cards[step]?.test_isLocked ?? false }

    /// Whether a card is drawing the active-step emphasis.
    public func test_isEmphasized(_ step: SetupStep) -> Bool { _ = view; return cards[step]?.test_isEmphasized ?? false }

    /// Whether a click anywhere on this card fires its Allow.
    public func test_isCardClickable(_ step: SetupStep) -> Bool { _ = view; return cards[step]?.test_isCardClickable ?? false }

    /// Whether VoiceOver sees this card as a button, and under what action name.
    public func test_cardIsAccessibilityButton(_ step: SetupStep) -> Bool {
        _ = view
        return cards[step]?.test_accessibilityIsButton ?? false
    }
    public func test_cardAccessibilityAction(_ step: SetupStep) -> String? {
        _ = view
        return cards[step]?.test_accessibilityAction
    }

    /// Press the CARD itself (not its Allow button) and wait for whatever that
    /// starts.
    ///
    /// This drives the card view's REAL press entry
    /// (`accessibilityPerformPress`, the same path `mouseUp` takes) through
    /// `allowTapped` INCLUDING its single-flight guard, and then awaits the work
    /// that press started. It deliberately does not call ``test_tapAllow(_:)``:
    /// a hook that re-implements the dispatch it claims to exercise is how a
    /// real break in row selection stayed hidden once already.
    public func test_pressCard(_ step: SetupStep) async -> Bool {
        _ = view
        guard cards[step]?.test_pressCard() == true else { return false }
        await allowTask?.value
        return true
    }

    /// Whether the card's OWN press action is refused (a locked strip, or one
    /// whose probe is in flight) — the no-jump-ahead and single-flight guards.
    public func test_cardPressIsRefused(_ step: SetupStep) -> Bool {
        _ = view
        guard let card = cards[step] else { return true }
        return !card.test_isCardClickable && card.test_pressCard() == false
    }

    /// Drive a card's Allow exactly as the button does, and wait for it — the
    /// same single-flight bookkeeping and the same ``applyAllowResult(_:_:)``
    /// the real click uses, so the re-front rules can't be true here and false
    /// on screen.
    public func test_tapAllow(_ step: SetupStep) async {
        _ = view
        allowInFlight = step
        let result = await flow.allow(step)
        allowInFlight = nil
        applyAllowResult(step, result)
        refresh()
    }

    /// Drive each step's Allow in order — how the snapshot harness reaches
    /// "card 3 is the active one" without a live prompt.
    public func test_allow(_ steps: [SetupStep]) async {
        for step in steps { await test_tapAllow(step) }
    }

    /// Drive a card's Skip exactly as the button does.
    public func test_tapSkip(_ step: SetupStep) { _ = view; skipTapped(step) }

    /// Whether Done is in the view hierarchy at all — the gate contract is
    /// ABSENT, not disabled, so this is the assertion that matters.
    public var test_doneExists: Bool { _ = view; return doneButton?.superview != nil }

    /// Whether Done is the window's Return-default (it is, the moment it exists).
    public var test_doneIsReturnDefault: Bool { _ = view; return doneButton?.keyEquivalent == "\r" }

    /// The gate button's title (nil while the gate is shut).
    public var test_doneTitle: String? { _ = view; return doneButton?.title }

    /// Whether the gate button is the gold prominent CTA — a `ProminentButton`
    /// carrying the gold fill, not a plain bezel. Compared by RESOLVED sRGB
    /// components: two accesses of a provider-backed token are distinct
    /// `NSColor` instances, and their `isEqual` is not documented to see
    /// through the provider.
    public var test_doneIsGoldProminent: Bool {
        _ = view
        guard let done = doneButton as? ProminentButton else { return false }
        var matches = false
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            matches = done.fill.usingColorSpace(.sRGB) == Tokens.Color.gold.usingColorSpace(.sRGB)
        }
        return matches
    }

    /// Whether the active card's Allow currently owns Return (it does while
    /// Done doesn't exist).
    public func test_allowIsReturnDefault(_ step: SetupStep) -> Bool {
        _ = view
        return cards[step]?.test_allowIsReturnDefault ?? false
    }

    /// Tap Done: re-verifies, then either finishes or snaps back.
    public func test_tapDone() async { _ = view; await verifyThenFinish() }

    /// The step a failed Done verification snapped back to, if any.
    public var test_snapBackStep: SetupStep? { _ = view; return snapBackStep }

    /// Which miniature the demo pane is showing.
    public var test_demoMode: DemoMode { _ = view; return demoPane.test_mode }

    /// Whether the demo's timeline is running (the zero-idle-CPU rule).
    public var test_isDemoAnimating: Bool { _ = view; return demoPane.test_isAnimating }

    /// Whether the demo is offering its Reduce Motion Replay button.
    public var test_demoShowsReplay: Bool { _ = view; return demoPane.test_showsReplay }

    /// Reduce Motion override for the demo pane (`nil` = the live setting).
    public var test_demoReduceMotionOverride: Bool? {
        get { _ = view; return demoPane.test_reduceMotionOverride }
        set { _ = view; demoPane.test_reduceMotionOverride = newValue }
    }

    /// Override for "this pane is allowed to animate" (`nil` = the live
    /// window/headless check). A headless run is never allowed to animate for
    /// real, so this is the only way to reach the motion POLICY — which of the
    /// two branches runs, and whether it loops — without a live window.
    public var test_demoCanAnimateOverride: Bool? {
        get { _ = view; return demoPane.test_canAnimateOverride }
        set { _ = view; demoPane.test_canAnimateOverride = newValue }
    }

    /// Whether the demo's timeline is set to LOOP — false is the Reduce Motion
    /// single play-through.
    public var test_demoIsLooping: Bool { _ = view; return demoPane.test_isLooping }

    /// How many times the settled finale's one-shot actually ran (the
    /// once-only rule — a repaint that changes nothing must never re-fire it).
    public var test_demoCelebrationRunCount: Int { _ = view; return demoPane.test_celebrationRunCount }

    /// Whether the finale's one-shot is spent — played, or skipped without
    /// motion under Reduce Motion. False on an off-window/headless settle, so
    /// the presentation that can show it still gets it.
    public var test_demoCelebrationConsumed: Bool { _ = view; return demoPane.test_celebrationConsumed }

    /// Press the demo's Replay button exactly as the button does.
    public func test_tapReplay() { _ = view; demoPane.test_tapReplay() }

    /// Anything inside the demo that VoiceOver would still reach. The demo is
    /// decorative — the card copy beside it carries every word — so this must be
    /// empty, Replay (outside the mock host) aside.
    public var test_demoAccessibilityElements: [String] {
        _ = view
        return demoPane.test_accessibleDemoDescendants
    }

    /// Whether Replay — a real control — is still reachable.
    public var test_replayIsAccessible: Bool { _ = view; return demoPane.test_replayIsAccessible }

    /// Press the demoted "Open Settings…" link on a card, as the button does.
    public func test_tapSettingsLink(_ step: SetupStep) { _ = view; cards[step]?.test_tapSettingsLink() }

    /// Re-read model status into the cards (the `viewWillAppear` bind, headless).
    public func test_refresh() { _ = view; refresh(animated: false) }

    /// The silent status re-read, AWAITED — `refreshStatuses()` fires a detached
    /// task, so a headless caller that needs the result (Bluetooth and Remote
    /// Control only reach `.granted` through it) has to be able to wait for it.
    public func test_refreshStatuses() async {
        _ = view
        await model.refreshStatuses()
        refresh(animated: false)
    }

    /// The laid-out root view (for offscreen snapshot rendering).
    public var test_rootView: NSView {
        _ = view
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Whether this presentation was opened for a lost permission (the banner's
    /// successor — the message rides the header subtitle now).
    public var test_showsPermissionLostBanner: Bool {
        _ = view
        if case .permissionLost = reason { return true }
        return false
    }

    /// Whether the lost-permission message is currently VISIBLE — distinct from
    /// ``test_showsPermissionLostBanner`` (was one ever warranted) so a test can
    /// assert the message CLEARS once its permission is granted. Reports the
    /// tracked message KIND: the subtitle also carries the completion line, so
    /// "not the welcome copy" is no longer evidence of a warning.
    public var test_permissionLostBannerIsVisible: Bool {
        _ = view
        return headerMessage == .permissionLost
    }

    /// The header subtitle currently on screen (welcome, completion, or the
    /// lost-permission warning).
    public var test_subtitleText: String { _ = view; return subtitleLabel.stringValue }

    /// The lost-permission copy, if it's showing (nil for `.firstRun`, and nil
    /// once it clears).
    public var test_permissionLostBannerText: String? {
        _ = view
        return test_permissionLostBannerIsVisible ? subtitleLabel.stringValue : nil
    }
}
